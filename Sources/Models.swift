import Foundation

enum PRState: String, Codable, Sendable {
    case open = "OPEN", closed = "CLOSED", merged = "MERGED"
}

enum ReviewState: String, Codable, Sendable {
    case approved = "APPROVED"
    case changesRequested = "CHANGES_REQUESTED"
    case commented = "COMMENTED"
    case dismissed = "DISMISSED"
    case pending = "PENDING"
}

struct Review: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var author: String
    var state: ReviewState
    var submittedAt: Date
    var url: String
    var commitOid: String?
}

enum CommentKind: String, Codable, Sendable {
    case conversation  // the PR's main thread
    case inline        // attached to a line of the diff
    case review        // the summary text of a submitted review
}

struct Comment: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var author: String
    var kind: CommentKind
    var body: String
    var createdAt: Date
    var url: String
    var path: String?
}

struct ReviewRequest: Codable, Hashable, Sendable {
    var reviewer: String
    var requestedBy: String?
    var at: Date
}

/// Everything git-assist keeps about one PR. Bot comments and reviews are dropped at fetch time.
struct PullRequest: Codable, Identifiable, Sendable {
    var repo: String
    var number: Int
    var title: String
    var body: String
    var url: String
    var state: PRState
    var isDraft: Bool
    var createdAt: Date
    var updatedAt: Date
    var closedAt: Date?
    var mergedAt: Date?
    var branch: String
    var headOid: String
    var additions: Int
    var deletions: Int
    var author: String
    var authorIsBot: Bool?
    /// GitHub logins behind the PR's last 50 commits. Optional so caches from before it still load.
    var committers: [String]?
    var labels: [String]
    var assignees: [String]
    var requestedReviewers: [String]
    var requestedTeams: [String]
    var reviews: [Review]
    var comments: [Comment]
    var reviewRequests: [ReviewRequest]
    var readyForReviewAt: Date?

    var id: String { key }
    var key: String { "\(repo)#\(number)" }

    /// Pushed commits to someone else's PR (say, fixing up a dependabot bump).
    func hasCommits(by login: String) -> Bool {
        committers?.contains { $0.sameLogin(login) } ?? false
    }

    /// Yours if you opened it or have commits on it; either way approvals and comments are news for you.
    func isOwned(by login: String) -> Bool { author.sameLogin(login) || hasCommits(by: login) }
}

extension String {
    /// GitHub logins are case-insensitive ASCII; comparing bytes keeps this cheap enough to call
    /// thousands of times per search.
    func sameLogin(_ other: String) -> Bool {
        let a = utf8, b = other.utf8
        guard a.count == b.count else { return false }
        return zip(a, b).allSatisfy { x, y in
            x == y || (x | 0x20 == y | 0x20 && (97...122).contains(x | 0x20))
        }
    }
}

// MARK: - Activity (what popups are made of)

enum PopupCategory: String, CaseIterable, Codable, Identifiable {
    case approvals, comments, reviewRequests, replies, deadlines

    var id: String { rawValue }

    var title: String {
        switch self {
        case .approvals: "Approvals on my PRs"
        case .comments: "Comments on my PRs"
        case .reviewRequests: "Review requested of me"
        case .replies: "Replies where I commented"
        case .deadlines: "Review deadlines"
        }
    }

    var detail: String {
        switch self {
        case .approvals: "Someone approves or requests changes on a PR you opened."
        case .comments: "New conversation, inline, or review comments on your PRs."
        case .reviewRequests: "You're added (or re-added) as a reviewer."
        case .replies: "New comments or commits on a PR you've commented on or approved."
        case .deadlines: "A requested review passes the warning mark, then the deadline."
        }
    }
}

enum ActivityKind: String, Codable {
    case approved, changesRequested, commented, reviewRequested, reply, newCommits, dueSoon, overdue

    var category: PopupCategory {
        switch self {
        case .approved, .changesRequested: .approvals
        case .commented: .comments
        case .reviewRequested: .reviewRequests
        case .reply, .newCommits: .replies
        case .dueSoon, .overdue: .deadlines
        }
    }

    /// Lower is more important; the most important event headlines a popup.
    var priority: Int {
        switch self {
        case .changesRequested: 0
        case .approved: 1
        case .overdue: 2
        case .reviewRequested: 3
        case .dueSoon: 4
        case .commented: 5
        case .reply: 6
        case .newCommits: 7
        }
    }

    var symbol: String {
        switch self {
        case .approved: "checkmark.seal.fill"
        case .changesRequested: "exclamationmark.octagon.fill"
        case .commented: "text.bubble.fill"
        case .reviewRequested: "eyes"
        case .reply: "arrowshape.turn.up.left.fill"
        case .newCommits: "arrow.triangle.branch"
        case .dueSoon: "hourglass"
        case .overdue: "alarm.fill"
        }
    }
}

struct ActivityEvent: Codable, Identifiable, Hashable {
    var id: String
    var kind: ActivityKind
    var prKey: String
    var prNumber: Int
    var prTitle: String
    var prURL: String
    var actor: String
    var snippet: String
    var url: String
    var date: Date

    var headline: String {
        switch kind {
        case .approved: "\(actor) approved your PR"
        case .changesRequested: "\(actor) requested changes"
        case .commented: "\(actor) commented on your PR"
        case .reviewRequested: "\(actor) requested your review"
        case .reply: "\(actor) replied"
        case .newCommits: "\(actor) pushed new commits"
        case .dueSoon: "Review due soon"
        case .overdue: "Review overdue"
        }
    }

    /// Short noun for the "+2 comments · approved" summary line.
    var summaryNoun: String {
        switch kind {
        case .approved: "approval"
        case .changesRequested: "changes requested"
        case .commented, .reply: "comment"
        case .reviewRequested: "review request"
        case .newCommits: "push"
        case .dueSoon, .overdue: "deadline"
        }
    }
}
