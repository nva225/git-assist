import Foundation

enum GitHubError: LocalizedError {
    case noToken(String)
    case http(Int, String)
    case graphQL(String)

    var errorDescription: String? {
        switch self {
        case .noToken(let message): "Couldn't get a GitHub token from `gh auth token`: \(message)"
        case .http(let code, let message): "GitHub HTTP \(code): \(message)"
        case .graphQL(let message): "GitHub: \(message)"
        }
    }
}

struct RepoRef {
    let owner: String
    let name: String
    let full: String

    init?(_ full: String) {
        let parts = full.split(separator: "/").map { String($0).trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        owner = parts[0]
        name = parts[1]
        self.full = "\(owner)/\(name)"
    }

    var variables: [String: Any] { ["owner": owner, "name": name] }
}

struct PRStamp: Decodable {
    let number: Int
    let updatedAt: Date
}

struct ClosedPage {
    let prs: [PullRequest]
    let totalCount: Int
    let endCursor: String?
    let hasNextPage: Bool
}

struct RateLimit: Decodable {
    let remaining: Int
    let resetAt: Date
}

/// GraphQL client authenticated with the gh CLI's token.
@MainActor
final class GitHubClient {
    private var token: String?
    private let session = URLSession(configuration: .ephemeral)
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
    private(set) var rateLimit: RateLimit?

    // MARK: - Queries

    func viewerLogin() async throws -> String {
        struct Payload: GQLData { struct Viewer: Decodable { let login: String }; let viewer: Viewer; let rateLimit: RateLimit? }
        let data: Payload = try await run("query { viewer { login } \(Self.rateField) }")
        return data.viewer.login
    }

    /// Repos the viewer has recently opened, reviewed, or pushed to, then their own, most recent first.
    func suggestedRepos() async throws -> [String] {
        struct Repo: Decodable { let nameWithOwner: String }
        struct Payload: GQLData {
            struct Viewer: Decodable { let repositoriesContributedTo: Nodes<Repo>; let repositories: Nodes<Repo> }
            let viewer: Viewer
            let rateLimit: RateLimit?
        }
        let query = """
        query {
          viewer {
            repositoriesContributedTo(first: 30, includeUserRepositories: true,
                                      contributionTypes: [PULL_REQUEST, PULL_REQUEST_REVIEW, COMMIT],
                                      orderBy: {field: PUSHED_AT, direction: DESC}) { nodes { nameWithOwner } }
            repositories(first: 15, ownerAffiliations: [OWNER, COLLABORATOR, ORGANIZATION_MEMBER],
                         orderBy: {field: PUSHED_AT, direction: DESC}) { nodes { nameWithOwner } }
          }
          \(Self.rateField)
        }
        """
        let data: Payload = try await run(query)
        var seen = Set<String>()
        return (data.viewer.repositoriesContributedTo.items + data.viewer.repositories.items)
            .map(\.nameWithOwner)
            .filter { seen.insert($0.lowercased()).inserted }
            .prefix(20)
            .map { $0 }
    }

    func openStamps(_ repo: RepoRef) async throws -> [PRStamp] {
        try await stamps(repo, states: "OPEN")
    }

    func recentlyUpdatedClosedStamps(_ repo: RepoRef) async throws -> [PRStamp] {
        try await stamps(repo, states: "[CLOSED, MERGED]", first: 25)
    }

    private func stamps(_ repo: RepoRef, states: String, first: Int = 100) async throws -> [PRStamp] {
        struct Payload: GQLData {
            struct Repo: Decodable { let pullRequests: Nodes<PRStamp> }
            let repository: Repo?
            let rateLimit: RateLimit?
        }
        let query = """
        query($owner: String!, $name: String!) {
          repository(owner: $owner, name: $name) {
            pullRequests(states: \(states), first: \(first), orderBy: {field: UPDATED_AT, direction: DESC}) {
              nodes { number updatedAt }
            }
          }
          \(Self.rateField)
        }
        """
        let data: Payload = try await run(query, repo.variables)
        guard let repository = data.repository else { throw GitHubError.graphQL("repository \(repo.full) not found") }
        return repository.pullRequests.items
    }

    /// Full details for specific PRs, ten at a time via aliases.
    func details(_ repo: RepoRef, numbers: [Int]) async throws -> [PullRequest] {
        struct Payload: GQLData {
            let repository: [String: RawPR?]?
            let rateLimit: RateLimit?
        }
        var result: [PullRequest] = []
        for start in stride(from: 0, to: numbers.count, by: 10) {
            let batch = numbers[start..<min(start + 10, numbers.count)]
            let fields = batch.map { "p\($0): pullRequest(number: \($0)) { ...PRFields }" }.joined(separator: "\n")
            let query = """
            query($owner: String!, $name: String!) {
              repository(owner: $owner, name: $name) {
                \(fields)
              }
              \(Self.rateField)
            }
            \(Self.prFragment)
            """
            let data: Payload = try await run(query, repo.variables)
            for case let raw? in (data.repository ?? [:]).values {
                result.append(raw.model(repo: repo.full))
            }
        }
        return result
    }

    /// One page of closed and merged PRs, newest first, for the history backfill.
    func closedPage(_ repo: RepoRef, after cursor: String?, first: Int) async throws -> ClosedPage {
        struct Payload: GQLData {
            struct PageInfo: Decodable { let hasNextPage: Bool; let endCursor: String? }
            struct Connection: Decodable { let totalCount: Int; let pageInfo: PageInfo; let nodes: [RawPR?]? }
            struct Repo: Decodable { let pullRequests: Connection }
            let repository: Repo?
            let rateLimit: RateLimit?
        }
        let query = """
        query($owner: String!, $name: String!, $after: String) {
          repository(owner: $owner, name: $name) {
            pullRequests(states: [CLOSED, MERGED], first: \(first), after: $after, orderBy: {field: CREATED_AT, direction: DESC}) {
              totalCount
              pageInfo { hasNextPage endCursor }
              nodes { ...PRFields }
            }
          }
          \(Self.rateField)
        }
        \(Self.prFragment)
        """
        var variables = repo.variables
        variables["after"] = cursor ?? NSNull()
        let data: Payload = try await run(query, variables)
        guard let connection = data.repository?.pullRequests else {
            throw GitHubError.graphQL("repository \(repo.full) not found")
        }
        return ClosedPage(
            prs: (connection.nodes ?? []).compactMap { $0?.model(repo: repo.full) },
            totalCount: connection.totalCount,
            endCursor: connection.pageInfo.endCursor,
            hasNextPage: connection.pageInfo.hasNextPage
        )
    }

    // MARK: - Transport

    private func run<T: GQLData>(_ query: String, _ variables: [String: Any] = [:]) async throws -> T {
        let token = try await currentToken()
        var request = URLRequest(url: URL(string: "https://api.github.com/graphql")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])

        let (body, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 {
            self.token = nil
            throw GitHubError.http(401, "token rejected — try `gh auth login`")
        }
        guard status == 200 else {
            throw GitHubError.http(status, String(decoding: body.prefix(300), as: UTF8.self))
        }
        let envelope = try decoder.decode(Envelope<T>.self, from: body)
        guard let data = envelope.data else {
            throw GitHubError.graphQL(envelope.errors?.first?.message ?? "empty response")
        }
        if let rate = data.rateLimit { rateLimit = rate }
        return data
    }

    private func currentToken() async throws -> String {
        if let token { return token }
        let fetched = try await Task.detached { try GitHubClient.readGhToken() }.value
        token = fetched
        return fetched
    }

    /// GUI apps don't get the shell's PATH, so look for gh where Homebrew puts it, then fall back to a login shell.
    nonisolated static func readGhToken() throws -> String {
        let process = Process()
        let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
        if let gh = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            process.executableURL = URL(fileURLWithPath: gh)
            process.arguments = ["auth", "token"]
        } else {
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", "gh auth token"]
        }
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch { throw GitHubError.noToken(error.localizedDescription) }
        process.waitUntilExit()
        let token = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0, !token.isEmpty else {
            let message = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw GitHubError.noToken(message.isEmpty ? "exit \(process.terminationStatus)" : message)
        }
        return token
    }

    private static let rateField = "rateLimit { remaining resetAt }"

    private static let prFragment = """
    fragment PRFields on PullRequest {
      number title body url state isDraft createdAt updatedAt closedAt mergedAt
      headRefName headRefOid additions deletions
      author { login __typename }
      labels(first: 20) { nodes { name } }
      assignees(first: 10) { nodes { login } }
      commits(last: 50) { nodes { commit { author { user { login } } } } }
      reviewRequests(first: 20) { nodes { requestedReviewer { __typename ... on User { login } ... on Team { slug } } } }
      reviews(first: 100) { nodes { id author { login __typename } state body submittedAt url commit { oid } } }
      comments(first: 100) { nodes { id author { login __typename } body createdAt url } }
      reviewThreads(first: 50) { nodes { comments(first: 30) { nodes { id author { login __typename } body createdAt url path } } } }
      timelineItems(last: 30, itemTypes: [REVIEW_REQUESTED_EVENT, READY_FOR_REVIEW_EVENT]) {
        nodes {
          __typename
          ... on ReviewRequestedEvent { createdAt actor { login } requestedReviewer { __typename ... on User { login } } }
          ... on ReadyForReviewEvent { createdAt }
        }
      }
    }
    """
}

// MARK: - Wire format

protocol GQLData: Decodable {
    var rateLimit: RateLimit? { get }
}

private struct Envelope<T: Decodable>: Decodable {
    struct Message: Decodable { let message: String }
    let data: T?
    let errors: [Message]?
}

struct Nodes<T: Decodable>: Decodable {
    let nodes: [T?]?
    var items: [T] { (nodes ?? []).compactMap { $0 } }
}

private struct RawActor: Decodable {
    let login: String
    let __typename: String?
    var isBot: Bool { __typename == "Bot" }
}

private struct RawLogin: Decodable { let login: String }
private struct RawLabel: Decodable { let name: String }
private struct RawCommit: Decodable { let oid: String }

private struct RawReviewer: Decodable {
    let __typename: String
    let login: String?
    let slug: String?
}

private struct RawReviewRequest: Decodable { let requestedReviewer: RawReviewer? }

/// commit.author.user is null when the commit email isn't tied to a GitHub account.
private struct RawPRCommit: Decodable {
    struct Commit: Decodable {
        struct Author: Decodable { let user: RawLogin? }
        let author: Author?
    }
    let commit: Commit

    var login: String? { commit.author?.user?.login }
}

private struct RawReview: Decodable {
    let id: String
    let author: RawActor?
    let state: String
    let body: String?
    let submittedAt: Date?
    let url: String
    let commit: RawCommit?
}

private struct RawComment: Decodable {
    let id: String
    let author: RawActor?
    let body: String
    let createdAt: Date
    let url: String
    let path: String?
}

private struct RawThread: Decodable { let comments: Nodes<RawComment> }

private struct RawTimelineItem: Decodable {
    let __typename: String
    let createdAt: Date?
    let actor: RawLogin?
    let requestedReviewer: RawReviewer?
}

private struct RawPR: Decodable {
    let number: Int
    let title: String
    let body: String
    let url: String
    let state: String
    let isDraft: Bool
    let createdAt: Date
    let updatedAt: Date
    let closedAt: Date?
    let mergedAt: Date?
    let headRefName: String
    let headRefOid: String
    let additions: Int
    let deletions: Int
    let author: RawActor?
    let labels: Nodes<RawLabel>
    let assignees: Nodes<RawLogin>
    let commits: Nodes<RawPRCommit>
    let reviewRequests: Nodes<RawReviewRequest>
    let reviews: Nodes<RawReview>
    let comments: Nodes<RawComment>
    let reviewThreads: Nodes<RawThread>
    let timelineItems: Nodes<RawTimelineItem>

    func model(repo: String) -> PullRequest {
        let humanReviews = reviews.items.filter { !($0.author?.isBot ?? false) && $0.state != "PENDING" }

        var allComments: [Comment] = []
        func add(_ raw: RawComment, _ kind: CommentKind) {
            guard let author = raw.author, !author.isBot else { return }
            allComments.append(Comment(id: raw.id, author: author.login, kind: kind, body: raw.body,
                                       createdAt: raw.createdAt, url: raw.url, path: raw.path))
        }
        comments.items.forEach { add($0, .conversation) }
        reviewThreads.items.forEach { thread in thread.comments.items.forEach { add($0, .inline) } }
        for review in humanReviews {
            guard let body = review.body, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let at = review.submittedAt, let author = review.author else { continue }
            allComments.append(Comment(id: review.id, author: author.login, kind: .review, body: body,
                                       createdAt: at, url: review.url, path: nil))
        }
        allComments.sort { $0.createdAt < $1.createdAt }

        let requests = reviewRequests.items.compactMap(\.requestedReviewer)
        let timeline = timelineItems.items

        return PullRequest(
            repo: repo,
            number: number,
            title: title,
            body: body,
            url: url,
            state: PRState(rawValue: state) ?? .open,
            isDraft: isDraft,
            createdAt: createdAt,
            updatedAt: updatedAt,
            closedAt: closedAt,
            mergedAt: mergedAt,
            branch: headRefName,
            headOid: headRefOid,
            additions: additions,
            deletions: deletions,
            author: author?.login ?? "ghost",
            authorIsBot: author?.isBot ?? false,
            committers: Array(Set(commits.items.compactMap(\.login))).sorted(),
            labels: labels.items.map(\.name),
            assignees: assignees.items.map(\.login),
            requestedReviewers: requests.compactMap { $0.__typename == "User" ? $0.login : nil },
            requestedTeams: requests.compactMap(\.slug),
            reviews: humanReviews.compactMap { raw in
                guard let state = ReviewState(rawValue: raw.state), let at = raw.submittedAt else { return nil }
                return Review(id: raw.id, author: raw.author?.login ?? "ghost", state: state,
                              submittedAt: at, url: raw.url, commitOid: raw.commit?.oid)
            }.sorted { $0.submittedAt < $1.submittedAt },
            comments: allComments,
            reviewRequests: timeline.compactMap { item in
                guard item.__typename == "ReviewRequestedEvent", let at = item.createdAt,
                      let reviewer = item.requestedReviewer?.login else { return nil }
                return ReviewRequest(reviewer: reviewer, requestedBy: item.actor?.login, at: at)
            },
            readyForReviewAt: timeline.last { $0.__typename == "ReadyForReviewEvent" }?.createdAt
        )
    }
}
