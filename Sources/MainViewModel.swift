import AppKit
import Combine
import SwiftUI

struct ResultRow: Identifiable {
    var id: String { pr.key }
    let pr: PullRequest
    let inv: Involvement?
    let snippets: [Snippet]
}

struct ResultSection: Identifiable {
    let id: String
    let title: String
    let color: Color
    let rows: [ResultRow]
    /// How many matched before the recent-mode cap; equals rows.count when uncapped.
    var total: Int? = nil
    /// Open rows come first; a labeled divider marks where the closed and merged ones start.
    var splitsClosed = false
}

extension Bucket {
    var color: Color {
        switch self {
        case .needsReview: .orange
        case .mine: .purple
        case .commented: .blue
        case .approved: .green
        case .mentioned: .teal
        case .team: .gray
        }
    }
}

@MainActor
final class MainViewModel: ObservableObject {
    let store: PRStore

    @Published private(set) var query = ""
    @Published private(set) var editVersion = 0
    @Published private(set) var suggestions: [Suggestion] = []
    @Published private(set) var suggestionIndex = 0
    @Published private(set) var sections: [ResultSection] = []
    @Published private(set) var needles: [String] = []
    @Published private(set) var isSearching = false
    @Published var selection: String?
    /// Bumps whenever the query or mode changes, so the list can jump back to the top.
    @Published private(set) var queryVersion = 0
    /// Bumps on every recompute; rows key on it so none outlive the result set they came from.
    @Published private(set) var resultsVersion = 0
    @Published var mode: ListMode {
        didSet {
            Settings.shared.listMode = mode
            queryChanged()
        }
    }

    private(set) var cursor = 0
    private var suggestionRange: Range<String.Index>?
    private var suggestionsDismissed = false
    private var choseSuggestion = false
    private var recomputeScheduled = false
    private var cancellables = Set<AnyCancellable>()

    weak var field: NSTextField?
    var onClose: (() -> Void)?

    init(store: PRStore) {
        self.store = store
        mode = Settings.shared.listMode
        store.objectWillChange
            .sink { [weak self] _ in self?.scheduleRecompute() }
            .store(in: &cancellables)
        Settings.shared.objectWillChange
            .sink { [weak self] _ in self?.scheduleRecompute() }
            .store(in: &cancellables)
        recompute()
    }

    var rows: [ResultRow] { sections.flatMap(\.rows) }

    // MARK: - Field events

    func textChanged(_ text: String, cursor: Int) {
        query = text
        self.cursor = cursor
        suggestionsDismissed = false
        refreshSuggestions()
        queryChanged()
    }

    /// A new query or mode is a new list: drop the old highlight (it may be far off-screen) and start from the top.
    private func queryChanged() {
        selection = nil
        queryVersion += 1
        scheduleRecompute()
    }

    func cursorMoved(to cursor: Int) {
        guard cursor != self.cursor else { return }
        self.cursor = cursor
        refreshSuggestions()
    }

    func handle(_ command: FieldCommand) -> Bool {
        switch command {
        case .tab:
            if !suggestions.isEmpty {
                accept(suggestions[suggestionIndex])
            } else if !isSearching {
                mode = mode.step(1)
            }
            return true
        case .backtab:
            if !isSearching { mode = mode.step(-1) }
            return true
        case .down:
            if !suggestions.isEmpty {
                suggestionIndex = min(suggestionIndex + 1, suggestions.count - 1)
                choseSuggestion = true
            } else {
                moveSelection(1)
            }
            return true
        case .up:
            if !suggestions.isEmpty {
                suggestionIndex = max(suggestionIndex - 1, 0)
                choseSuggestion = true
            } else {
                moveSelection(-1)
            }
            return true
        case .enter:
            if !suggestions.isEmpty, choseSuggestion {
                accept(suggestions[suggestionIndex])
            } else if let row = rows.first(where: { $0.id == selection }) ?? rows.first {
                open(row.pr)
            }
            return true
        case .escape:
            if !suggestions.isEmpty {
                suggestionsDismissed = true
                clearSuggestions()
            } else if !query.isEmpty {
                setQuery("")
            } else {
                onClose?()
            }
            return true
        }
    }

    func accept(_ suggestion: Suggestion) {
        guard let range = suggestionRange else { return }
        var replacement = suggestion.replacement
        var skip = 0
        // Don't double up the space when completing a word that already has one after it.
        if replacement.hasSuffix(" "), range.upperBound < query.endIndex, query[range.upperBound] == " " {
            replacement.removeLast()
            skip = 1
        }
        let start = range.lowerBound.utf16Offset(in: query)
        var text = query
        text.replaceSubrange(range, with: replacement)
        query = text
        cursor = start + replacement.utf16.count + skip
        editVersion += 1
        refreshSuggestions()
        queryChanged()
        focusSearch(selectAll: false)
    }

    func setQuery(_ text: String) {
        query = text
        cursor = text.utf16.count
        editVersion += 1
        clearSuggestions()
        queryChanged()
    }

    func focusSearch(selectAll: Bool) {
        guard let field, let window = field.window else { return }
        if window.firstResponder !== field.currentEditor() { window.makeFirstResponder(field) }
        if let editor = field.currentEditor() {
            editor.selectedRange = selectAll ? NSRange(location: 0, length: field.stringValue.utf16.count)
                : NSRange(location: cursor, length: 0)
        }
    }

    private func refreshSuggestions() {
        guard !suggestionsDismissed,
              let set = Search.suggestions(for: query, cursor: cursor, store: store) else {
            clearSuggestions()
            return
        }
        // A finished value (author:alice followed by a space) needs no prompt.
        if set.items.count == 1, set.range.upperBound < query.endIndex,
           String(query[set.range]) + " " == set.items[0].replacement {
            clearSuggestions()
            return
        }
        if set.items != suggestions {
            suggestionIndex = 0
            choseSuggestion = false
        }
        suggestions = set.items
        suggestionRange = set.range
    }

    private func clearSuggestions() {
        suggestions = []
        suggestionRange = nil
        suggestionIndex = 0
        choseSuggestion = false
    }

    // MARK: - Results

    func moveSelection(_ delta: Int) {
        let rows = self.rows
        guard !rows.isEmpty else { return }
        let current = rows.firstIndex { $0.id == selection } ?? (delta > 0 ? -1 : rows.count)
        selection = rows[min(max(current + delta, 0), rows.count - 1)].id
    }

    func open(_ pr: PullRequest, url: String? = nil) {
        if let target = URL(string: url ?? pr.url) { NSWorkspace.shared.open(target) }
        store.markSeen(pr.key)
    }

    private func scheduleRecompute() {
        guard !recomputeScheduled else { return }
        recomputeScheduled = true
        // objectWillChange fires before the change lands, so read on the next turn.
        DispatchQueue.main.async { [weak self] in
            self?.recomputeScheduled = false
            self?.recompute()
        }
    }

    private func recompute() {
        guard let me = store.viewer else {
            sections = []
            return
        }
        let parsed = ParsedQuery(query, me: me)
        needles = parsed.needles
        isSearching = !parsed.isEmpty

        if parsed.isEmpty, mode == .recent {
            sections = recentActivity()
        } else if parsed.isEmpty {
            let recent = mode == .all
            var groups: [Bucket: [ResultRow]] = [:]
            for pr in store.prs.values where recent || pr.state == .open {
                guard let inv = store.involvement(pr),
                      let bucket = recent ? inv.recentBucket : inv.bucket,
                      recent || bucket != .team else { continue }
                groups[bucket, default: []].append(ResultRow(pr: pr, inv: inv, snippets: []))
            }
            let limit = Settings.shared.recentLimit
            sections = Bucket.allCases.compactMap { bucket in
                guard let rows = groups[bucket], !rows.isEmpty else { return nil }
                let sorted = Self.sorted(rows, bucket)
                guard recent else {
                    return ResultSection(id: "\(bucket)", title: bucket.title, color: bucket.color, rows: sorted)
                }
                // Open PRs always show; the cap only trims the history below them.
                let open = sorted.filter { $0.pr.state == .open }
                let closed = sorted.filter { $0.pr.state != .open }
                return ResultSection(id: "\(bucket)", title: bucket.title, color: bucket.color,
                                     rows: open + closed.prefix(limit), total: rows.count, splitsClosed: true)
            }
        } else {
            let hits = Search.run(parsed, store: store).map { ResultRow(pr: $0.pr, inv: $0.inv, snippets: $0.snippets) }
            let open = hits.filter { $0.pr.state == .open }
            let closed = hits.filter { $0.pr.state != .open }
            sections = [
                ResultSection(id: "open", title: "Open", color: .green, rows: open),
                ResultSection(id: "closed", title: "Closed & merged", color: .purple, rows: closed),
            ].filter { !$0.rows.isEmpty }
        }

        if let selection, !rows.contains(where: { $0.id == selection }) { self.selection = nil }
        resultsVersion += 1
    }

    /// How many PRs Recent mode lists.
    private static let recentRows = 40

    /// PRs from the All set, newest activity first, grouped by day, each with its latest two happenings.
    private func recentActivity() -> [ResultSection] {
        let pushes = Dictionary(grouping: store.recentEvents.filter { $0.kind == .newCommits }, by: \.prKey)
        var latest: [(pr: PullRequest, inv: Involvement, date: Date)] = []
        for pr in store.prs.values {
            guard let inv = store.involvement(pr), inv.recentBucket != nil else { continue }
            var date = max(pr.createdAt, pr.readyForReviewAt ?? .distantPast, pr.mergedAt ?? pr.closedAt ?? .distantPast)
            for comment in pr.comments where comment.createdAt > date { date = comment.createdAt }
            for review in pr.reviews where review.submittedAt > date { date = review.submittedAt }
            for push in pushes[pr.key] ?? [] where push.date > date { date = push.date }
            latest.append((pr, inv, date))
        }
        latest.sort { $0.date > $1.date }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: store.now)
        let days: [(id: String, title: String, from: Date)] = [
            ("today", "Today", today),
            ("yesterday", "Yesterday", calendar.date(byAdding: .day, value: -1, to: today)!),
            ("week", "Earlier this week", calendar.date(byAdding: .day, value: -6, to: today)!),
            ("older", "Older", .distantPast),
        ]
        var groups: [String: [ResultRow]] = [:]
        for item in latest.prefix(Self.recentRows) {
            let day = days.first { item.date >= $0.from }!
            let row = ResultRow(pr: item.pr, inv: item.inv, snippets: Self.happenings(item.pr, pushes: pushes[item.pr.key] ?? []))
            groups[day.id, default: []].append(row)
        }
        return days.compactMap { day in
            guard let rows = groups[day.id] else { return nil }
            return ResultSection(id: day.id, title: day.title, color: .blue, rows: rows)
        }
    }

    /// The latest two things that happened on a PR, as clickable lines.
    private static func happenings(_ pr: PullRequest, pushes: [ActivityEvent]) -> [Snippet] {
        var items: [Snippet] = []
        let verdicts = Dictionary(pr.reviews.filter { $0.state == .approved || $0.state == .changesRequested }
            .map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for review in verdicts.values {
            let body = pr.comments.first { $0.id == review.id }.map { TextClean.excerpt($0.body, around: []) } ?? ""
            let verb = review.state == .approved ? "approved" : "requested changes"
            items.append(Snippet(author: review.author, text: body.isEmpty ? verb : "\(verb): \(body)",
                                 url: review.url, date: review.submittedAt))
        }
        for comment in pr.comments where verdicts[comment.id] == nil {
            let text = TextClean.excerpt(comment.body, around: [])
            guard !text.isEmpty else { continue }
            items.append(Snippet(author: comment.author, text: text, url: comment.url, date: comment.createdAt))
        }
        for push in pushes {
            items.append(Snippet(author: push.actor, text: "pushed new commits", url: push.url, date: push.date))
        }
        if let merged = pr.mergedAt {
            items.append(Snippet(author: "", text: "Merged", url: pr.url, date: merged))
        } else if let closed = pr.closedAt {
            items.append(Snippet(author: "", text: "Closed", url: pr.url, date: closed))
        }
        if let ready = pr.readyForReviewAt {
            items.append(Snippet(author: pr.author, text: "marked it ready for review", url: pr.url, date: ready))
        }
        items.append(Snippet(author: pr.author, text: "opened this PR", url: pr.url, date: pr.createdAt))
        return Array(items.sorted { $0.date > $1.date }.prefix(2))
    }

    private static func sorted(_ rows: [ResultRow], _ bucket: Bucket) -> [ResultRow] {
        rows.sorted { a, b in
            switch bucket {
            case .needsReview:
                return (a.inv?.deadline?.remaining ?? 0) < (b.inv?.deadline?.remaining ?? 0)
            case .commented, .mine:
                let an = (a.inv?.newSinceMine ?? 0) > 0, bn = (b.inv?.newSinceMine ?? 0) > 0
                if an != bn { return an }
            case .approved:
                let astale = a.inv?.approvalStale ?? false, bstale = b.inv?.approvalStale ?? false
                if astale != bstale { return astale }
            default:
                break
            }
            return a.pr.updatedAt > b.pr.updatedAt
        }
    }
}
