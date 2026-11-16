import Foundation

private struct RepoMeta: Codable {
    var initialized = false
    var lastPoll: Date?
    var lastFullRefresh: Date?
    var lastArchiveCheck: Date?
    var backfillCursor: String?
    var backfillDone = false
    var backfillTotal: Int?
    /// Bumped when PRs gain a field worth re-fetching history for; a stale value re-runs the backfill.
    var historyVersion: Int?
}

private struct StoreMeta: Codable {
    static let currentSchema = 2
    var schema = StoreMeta.currentSchema
    var viewer: String?
    var repos: [String: RepoMeta] = [:]
    var lastSeen: [String: Date] = [:]
    var notifiedDeadlines: Set<String> = []
    var recentEvents: [ActivityEvent] = []
}

/// The local cache of every PR in the watched repos, kept current by polling GitHub.
///
/// Open PRs: each poll lists open PRs with their `updatedAt` and refetches only the ones that moved,
/// plus a full refresh every few minutes in case GitHub didn't bump `updatedAt`. Closed history is
/// backfilled once in the background (resumable), then kept fresh from the recently-updated list.
@MainActor
final class PRStore: ObservableObject {
    enum Status: Equatable {
        case idle, syncing
        case error(String)
    }

    @Published private(set) var prs: [String: PullRequest] = [:]
    @Published private(set) var viewer: String?
    @Published private(set) var status: Status = .idle
    @Published private(set) var lastSync: Date?
    @Published private(set) var loaded = false
    @Published private(set) var recentEvents: [ActivityEvent] = []
    @Published private(set) var lastSeen: [String: Date] = [:]
    @Published private(set) var backfillProgress: (done: Int, total: Int)?
    /// Ticks every minute so deadline labels stay current.
    @Published private(set) var now = Date()

    private(set) var docs: [String: SearchDoc] = [:]
    /// Logins seen as authors or commenters, with how often, for search suggestions.
    private(set) var loginCounts: [String: Int] = [:]
    private(set) var labels: Set<String> = []

    var onEvents: (([ActivityEvent]) -> Void)?

    private let client = GitHubClient()
    private var meta = StoreMeta()
    private var dirtyShards = Set<String>()
    private var saveScheduled = false
    private var syncing = false
    private var pollTask: Task<Void, Never>?
    private var backfillTask: Task<Void, Never>?
    private var clock: Timer?
    private let directory: URL
    private let writeQueue = DispatchQueue(label: "git-assist.cache-writes", qos: .utility)

    private static let fullRefreshInterval: TimeInterval = 5 * 60
    private static let archiveCheckInterval: TimeInterval = 15 * 60
    private static let historyVersion = 2

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = support.appendingPathComponent("GitAssist", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory.appendingPathComponent("prs"),
                                                 withIntermediateDirectories: true)
    }

    var rateRemaining: Int? { client.rateLimit?.remaining }

    func suggestedRepos() async throws -> [String] { try await client.suggestedRepos() }

    func start() {
        Task {
            await load()
            restartPolling()
            clock = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.now = Date()
                    self?.checkDeadlines()
                }
            }
        }
    }

    func syncNow() {
        guard !syncing else { return }
        restartPolling()
    }

    func markSeen(_ key: String) {
        lastSeen[key] = Date()
        scheduleSave()
    }

    /// Wipes the cache and starts over from scratch (keeps preferences).
    func resetCache() {
        pollTask?.cancel()
        backfillTask?.cancel()
        prs = [:]
        docs = [:]
        loginCounts = [:]
        labels = []
        meta = StoreMeta()
        lastSeen = [:]
        recentEvents = []
        backfillProgress = nil
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("prs"))
        try? FileManager.default.createDirectory(at: directory.appendingPathComponent("prs"),
                                                 withIntermediateDirectories: true)
        saveNow()
        restartPolling()
    }

    func involvement(_ pr: PullRequest) -> Involvement? {
        guard let viewer else { return nil }
        return Involvement(pr, me: viewer, lastSeen: lastSeen[pr.key], now: now, doc: docs[pr.key])
    }

    // MARK: - Polling

    private func restartPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.syncOnce()
                let seconds = max(Settings.shared.pollSeconds, 15)
                try? await Task.sleep(for: .seconds(seconds))
            }
        }
    }

    private func syncOnce() async {
        guard !syncing else { return }
        syncing = true
        defer { syncing = false }
        status = .syncing
        do {
            if viewer == nil {
                viewer = try await client.viewerLogin()
                meta.viewer = viewer
            }
            for repo in Settings.shared.repos.compactMap(RepoRef.init) {
                try await syncOpen(repo)
            }
            lastSync = Date()
            status = .idle
            now = Date()
            checkDeadlines()
            seedAuthorsIfNeeded()
            scheduleSave()
            startBackfillIfNeeded()
        } catch is CancellationError {
            status = .idle
        } catch let error as URLError where error.code == .cancelled {
            status = .idle
        } catch {
            status = .error(error.localizedDescription)
        }
    }

    private func syncOpen(_ repo: RepoRef) async throws {
        var repoMeta = meta.repos[repo.full] ?? RepoMeta()
        let stamps = try await client.openStamps(repo)
        let openNumbers = Set(stamps.map(\.number))
        let full = repoMeta.lastFullRefresh.map { Date().timeIntervalSince($0) > Self.fullRefreshInterval } ?? true

        var numbers = stamps.filter { stamp in
            full || prs[key(repo, stamp.number)]?.updatedAt != stamp.updatedAt
        }.map(\.number)
        // Cached as open but gone from the list: merged or closed since.
        numbers += prs.values
            .filter { $0.repo == repo.full && $0.state == .open && !openNumbers.contains($0.number) }
            .map(\.number)

        if !numbers.isEmpty {
            let fetched = try await client.details(repo, numbers: numbers)
            let cutoff = (repoMeta.lastPoll ?? Date()).addingTimeInterval(-120)
            apply(fetched, emit: repoMeta.initialized, newPRCutoff: cutoff, baselineSeen: true)
        }

        if repoMeta.backfillDone,
           repoMeta.lastArchiveCheck.map({ Date().timeIntervalSince($0) > Self.archiveCheckInterval }) ?? true {
            let closed = try await client.recentlyUpdatedClosedStamps(repo)
            let changed = closed.filter { prs[key(repo, $0.number)]?.updatedAt != $0.updatedAt }.map(\.number)
            if !changed.isEmpty {
                apply(try await client.details(repo, numbers: changed), emit: false, newPRCutoff: Date(),
                      baselineSeen: false)
            }
            repoMeta.lastArchiveCheck = Date()
        }

        if full { repoMeta.lastFullRefresh = Date() }
        repoMeta.initialized = true
        repoMeta.lastPoll = Date()
        meta.repos[repo.full] = repoMeta
    }

    private func key(_ repo: RepoRef, _ number: Int) -> String { "\(repo.full)#\(number)" }

    /// Folds fetched PRs into the cache, reporting new activity when `emit` is set.
    private func apply(_ fetched: [PullRequest], emit: Bool, newPRCutoff: Date, baselineSeen: Bool) {
        guard !fetched.isEmpty else { return }
        var updated = prs
        var events: [ActivityEvent] = []
        let floor = Date().addingTimeInterval(-3 * 86_400)
        for pr in fetched {
            let old = updated[pr.key]
            if emit, let viewer {
                let cutoff = old == nil ? newPRCutoff : floor
                events += ActivityDetector.events(old: old, new: pr, me: viewer, cutoff: cutoff)
            }
            if old == nil, baselineSeen, pr.state == .open, lastSeen[pr.key] == nil {
                lastSeen[pr.key] = Date()
            }
            if let old { unindex(old) }
            updated[pr.key] = pr
            index(pr)
            dirtyShards.insert(shardName(pr))
        }
        prs = updated
        emitEvents(events)
        scheduleSave()
    }

    private func emitEvents(_ events: [ActivityEvent]) {
        guard !events.isEmpty else { return }
        let sorted = events.sorted { $0.date > $1.date }
        recentEvents = Array((sorted + recentEvents).prefix(60))
        onEvents?(sorted)
    }

    private func checkDeadlines() {
        guard let viewer else { return }
        var events: [ActivityEvent] = []
        for pr in prs.values where pr.state == .open {
            let inv = Involvement(pr, me: viewer, lastSeen: nil, now: now, doc: docs[pr.key])
            guard let deadline = inv.deadline, deadline.level > .ok, let start = inv.requestedAt else { continue }
            let stamp = "\(pr.key)|\(Int(start.timeIntervalSince1970))"
            let warnNew = meta.notifiedDeadlines.insert(stamp + "|warn").inserted
            var kind: ActivityKind?
            if deadline.level == .overdue {
                if meta.notifiedDeadlines.insert(stamp + "|overdue").inserted { kind = .overdue }
            } else if warnNew {
                kind = .dueSoon
            }
            guard let kind else { continue }
            let by = inv.requestedBy.map { " · requested by \($0)" } ?? ""
            events.append(ActivityEvent(
                id: "\(kind.rawValue):\(stamp)", kind: kind, prKey: pr.key, prNumber: pr.number,
                prTitle: pr.title, prURL: pr.url, actor: pr.author,
                snippet: "\(deadline.label)\(by)", url: pr.url, date: Date()))
        }
        if !events.isEmpty { scheduleSave() }
        emitEvents(events)
    }

    /// The first time enough history is cached, start the team list from everyone who opened a PR lately.
    private func seedAuthorsIfNeeded() {
        let settings = Settings.shared
        guard !settings.authorsSeeded, settings.authors.isEmpty else { return }
        let since = Date().addingTimeInterval(-60 * 86_400)
        let haveHistory = meta.repos.values.contains { $0.backfillDone }
            || prs.values.contains { $0.createdAt < since }
        guard haveHistory else { return }
        var counts: [String: Int] = [:]
        for pr in prs.values where pr.createdAt > since && pr.authorIsBot == false && pr.author != "ghost"
            && !(viewer.map(pr.author.sameLogin) ?? false) {
            counts[pr.author, default: 0] += 1
        }
        settings.authors = counts.keys.sorted { $0.lowercased() < $1.lowercased() }
        settings.authorsSeeded = true
    }

    // MARK: - History backfill

    private func startBackfillIfNeeded() {
        guard backfillTask == nil,
              Settings.shared.repos.contains(where: { !(meta.repos[$0]?.backfillDone ?? false) }) else { return }
        backfillTask = Task { [weak self] in
            await self?.runBackfill()
            self?.backfillTask = nil
        }
    }

    private func runBackfill() async {
        for repo in Settings.shared.repos.compactMap(RepoRef.init) {
            var pageSize = 20
            while !Task.isCancelled, !(meta.repos[repo.full]?.backfillDone ?? false) {
                do {
                    if let rate = client.rateLimit, rate.remaining < 400 {
                        try await Task.sleep(for: .seconds(max(rate.resetAt.timeIntervalSinceNow, 60)))
                    }
                    var repoMeta = meta.repos[repo.full] ?? RepoMeta()
                    let page = try await client.closedPage(repo, after: repoMeta.backfillCursor, first: pageSize)
                    apply(page.prs, emit: false, newPRCutoff: Date(), baselineSeen: false)
                    repoMeta = meta.repos[repo.full] ?? repoMeta
                    repoMeta.backfillCursor = page.endCursor
                    repoMeta.backfillTotal = page.totalCount
                    repoMeta.backfillDone = !page.hasNextPage
                    repoMeta.historyVersion = Self.historyVersion
                    meta.repos[repo.full] = repoMeta
                    updateBackfillProgress()
                    seedAuthorsIfNeeded()
                    pageSize = min(pageSize + 5, 20)
                    try await Task.sleep(for: .milliseconds(250))
                } catch is CancellationError {
                    return
                } catch {
                    // Heavy pages time out on GitHub's side; shrink and retry, then back off.
                    if pageSize > 5 {
                        pageSize = max(pageSize / 2, 5)
                    } else {
                        try? await Task.sleep(for: .seconds(60))
                    }
                }
            }
        }
        updateBackfillProgress()
    }

    private func updateBackfillProgress() {
        let pending = Settings.shared.repos.compactMap { meta.repos[$0] }.filter { !$0.backfillDone }
        guard !pending.isEmpty else {
            backfillProgress = nil
            return
        }
        let total = pending.compactMap(\.backfillTotal).reduce(0, +)
        let done = prs.values.filter { $0.state != .open }.count
        backfillProgress = (min(done, total), total)
    }

    // MARK: - Search index

    private func index(_ pr: PullRequest) {
        docs[pr.key] = SearchDoc(pr)
        loginCounts[pr.author, default: 0] += 3
        for comment in pr.comments { loginCounts[comment.author, default: 0] += 1 }
        labels.formUnion(pr.labels)
    }

    private func unindex(_ pr: PullRequest) {
        loginCounts[pr.author, default: 0] -= 3
        for comment in pr.comments { loginCounts[comment.author, default: 0] -= 1 }
    }

    // MARK: - Persistence

    private func shardName(_ pr: PullRequest) -> String {
        "\(pr.repo.replacingOccurrences(of: "/", with: "__"))_\(pr.number / 100).json"
    }

    func load() async {
        let directory = self.directory
        let (loadedPRs, loadedMeta) = await Task.detached(priority: .userInitiated) { () -> ([PullRequest], StoreMeta?) in
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let meta = (try? Data(contentsOf: directory.appendingPathComponent("meta.json")))
                .flatMap { try? decoder.decode(StoreMeta.self, from: $0) }
            guard let meta, meta.schema == StoreMeta.currentSchema else { return ([], nil) }
            let files = (try? FileManager.default.contentsOfDirectory(
                at: directory.appendingPathComponent("prs"), includingPropertiesForKeys: nil)) ?? []
            var all: [PullRequest] = []
            for file in files where file.pathExtension == "json" {
                if let data = try? Data(contentsOf: file),
                   let list = try? decoder.decode([PullRequest].self, from: data) {
                    all += list
                }
            }
            return (all, meta)
        }.value

        if var loadedMeta {
            // History fetched before a newer field (v2: commit authors) gets fetched again in the background.
            for (repo, repoMeta) in loadedMeta.repos where (repoMeta.historyVersion ?? 1) < Self.historyVersion {
                var updated = repoMeta
                updated.backfillDone = false
                updated.backfillCursor = nil
                updated.historyVersion = Self.historyVersion
                updated.lastFullRefresh = nil
                loadedMeta.repos[repo] = updated
            }
            meta = loadedMeta
            viewer = loadedMeta.viewer
            lastSeen = loadedMeta.lastSeen
            recentEvents = loadedMeta.recentEvents
            // Installs from before the repo picker never saved a list; keep watching what's cached.
            if Settings.shared.repos.isEmpty, UserDefaults.standard.object(forKey: "repos") == nil,
               !loadedMeta.repos.isEmpty {
                Settings.shared.repos = loadedMeta.repos.keys.sorted()
            }
        }
        var byKey: [String: PullRequest] = [:]
        for pr in loadedPRs {
            byKey[pr.key] = pr
            index(pr)
        }
        prs = byKey
        loaded = true
        updateBackfillProgress()
    }

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            MainActor.assumeIsolated { self?.saveNow() }
        }
    }

    func saveNow() {
        saveScheduled = false
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var writes: [(URL, Data)] = []

        if !dirtyShards.isEmpty {
            let shards = Dictionary(grouping: prs.values.filter { dirtyShards.contains(shardName($0)) },
                                    by: shardName)
            for (name, list) in shards {
                if let data = try? encoder.encode(list.sorted { $0.number < $1.number }) {
                    writes.append((directory.appendingPathComponent("prs/\(name)"), data))
                }
            }
            dirtyShards.removeAll()
        }

        meta.viewer = viewer
        meta.lastSeen = lastSeen
        meta.recentEvents = recentEvents
        if let data = try? encoder.encode(meta) {
            writes.append((directory.appendingPathComponent("meta.json"), data))
        }
        writeQueue.async {
            for (url, data) in writes { try? data.write(to: url, options: .atomic) }
        }
    }
}
