import Foundation

/// Where a PR lands in the default (no query) list.
enum Bucket: Int, CaseIterable, Comparable {
    case needsReview, mine, commented, approved, mentioned, team

    static func < (a: Bucket, b: Bucket) -> Bool { a.rawValue < b.rawValue }

    var title: String {
        switch self {
        case .needsReview: "Needs my review"
        case .mine: "My PRs"
        case .commented: "I've commented"
        case .approved: "I've approved"
        case .mentioned: "Mentioned or assigned"
        case .team: "Other team PRs"
        }
    }
}

struct Deadline {
    enum Level: Int, Comparable {
        case ok, warn, overdue
        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    /// Business seconds since the request.
    let elapsed: TimeInterval
    /// Business seconds until the deadline (negative once overdue).
    let remaining: TimeInterval
    let level: Level

    var label: String {
        remaining > 0 ? "\(Format.duration(remaining)) left" : "overdue \(Format.duration(-remaining))"
    }
}

/// How the viewer relates to one PR, derived fresh from the cached data.
struct Involvement {
    var isMine = false
    /// Mine only through commits, not authorship.
    var isCoAuthored = false
    var isRequested = false
    var needsReview = false
    var requestedAt: Date?
    var requestedBy: String?
    var approved = false
    var approvalStale = false
    var changesRequested = false
    var commented = false
    var mentioned = false
    var assigned = false
    var myLastActivity: Date?
    var newSinceMine = 0
    var newCommitsSinceMine = false
    var approvers: [String] = []
    var changesRequestedBy: [String] = []
    var deadline: Deadline?
    var bucket: Bucket?
    /// The bucket ignoring open/closed, for recent mode. Team PRs land here too.
    var recentBucket: Bucket?

    init(_ pr: PullRequest, me: String, lastSeen: Date?, now: Date = Date(), doc: SearchDoc? = nil,
         settings: Settings = .shared) {
        isMine = pr.isOwned(by: me)
        isCoAuthored = isMine && !pr.author.sameLogin(me)

        let myReviews = pr.reviews.filter { $0.author.sameLogin(me) }
        let myComments = pr.comments.filter { $0.author.sameLogin(me) }
        myLastActivity = (myReviews.map(\.submittedAt) + myComments.map(\.createdAt)).max()
        commented = !myReviews.isEmpty || !myComments.isEmpty

        // Each reviewer's standing verdict is their latest approve / request-changes / dismissal.
        var verdicts: [String: Review] = [:]
        for review in pr.reviews where review.state != .commented {
            verdicts[review.author.lowercased()] = review
        }
        let mine = verdicts[me.lowercased()]
        approved = mine?.state == .approved
        changesRequested = mine?.state == .changesRequested
        if approved, let oid = mine?.commitOid { approvalStale = oid != pr.headOid }
        if !isMine, let lastReviewed = myReviews.last?.commitOid { newCommitsSinceMine = lastReviewed != pr.headOid }
        let others = verdicts.values.filter { !$0.author.sameLogin(pr.author) }
        approvers = others.filter { $0.state == .approved }.map(\.author).sorted()
        changesRequestedBy = others.filter { $0.state == .changesRequested }.map(\.author).sorted()

        // Closed PRs can keep stale requests forever; they're not waiting on anyone.
        isRequested = pr.state == .open && pr.requestedReviewers.contains { $0.sameLogin(me) }
        if isRequested {
            let request = pr.reviewRequests.last { $0.reviewer.sameLogin(me) }
            var start = request?.at ?? pr.createdAt
            if let ready = pr.readyForReviewAt, ready > start { start = ready }
            requestedAt = start
            requestedBy = request?.requestedBy
            let responded = myLastActivity.map { $0 > start } ?? false
            needsReview = !responded && !pr.isDraft
            if needsReview {
                let day: TimeInterval = 86_400
                let elapsed = BusinessTime.seconds(from: start, to: now)
                let level: Deadline.Level = elapsed >= settings.dueDays * day ? .overdue
                    : elapsed >= settings.warnDays * day ? .warn : .ok
                deadline = Deadline(elapsed: elapsed, remaining: settings.dueDays * day - elapsed, level: level)
            }
        }

        if !isMine {
            let handle = "@" + me
            if let doc {
                let needle = Needle(handle)
                mentioned = doc.body.contains(needle)
                    || pr.comments.indices.contains { !pr.comments[$0].author.sameLogin(me) && doc.comments[$0].contains(needle) }
            } else {
                func mentions(_ text: String) -> Bool { text.range(of: handle, options: .caseInsensitive) != nil }
                mentioned = mentions(pr.body) || pr.comments.contains { !$0.author.sameLogin(me) && mentions($0.body) }
            }
        }
        assigned = pr.assignees.contains { $0.sameLogin(me) }

        // "New" means activity from others since whichever is later: your own last word, or when you last opened it.
        let baseline = [myLastActivity, lastSeen].compactMap { $0 }.max()
        if let baseline, pr.state == .open, isMine || commented {
            newSinceMine = pr.comments.filter { !$0.author.sameLogin(me) && $0.createdAt > baseline }.count
                + pr.reviews.filter { !$0.author.sameLogin(me) && $0.state != .commented && $0.submittedAt > baseline }.count
        }

        recentBucket = Self.bucket(pr, self, settings: settings)
        bucket = pr.state == .open ? recentBucket : nil
    }

    private static func bucket(_ pr: PullRequest, _ inv: Involvement, settings: Settings) -> Bucket? {
        guard pr.state != .open || !pr.isDraft || settings.showDrafts else { return nil }
        if inv.isMine { return .mine }
        if inv.needsReview { return .needsReview }
        if inv.approved { return .approved }
        if inv.commented { return .commented }
        if inv.mentioned || inv.assigned || inv.isRequested { return .mentioned }
        return settings.isTeamAuthor(pr.author) ? .team : nil
    }
}

enum BusinessTime {
    /// Seconds between two dates that fall on weekdays, in the local calendar.
    static func seconds(from start: Date, to end: Date, calendar: Calendar = .current) -> TimeInterval {
        guard end > start else { return 0 }
        var total: TimeInterval = 0
        var cursor = start
        while cursor < end {
            let nextDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: cursor)) ?? end
            let segmentEnd = min(nextDay, end)
            if !calendar.isDateInWeekend(cursor) { total += segmentEnd.timeIntervalSince(cursor) }
            cursor = segmentEnd
        }
        return total
    }
}

enum Format {
    /// "45m", "6h", "1d 4h".
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(max(minutes, 1))m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        let days = hours / 24, rest = hours % 24
        return rest == 0 ? "\(days)d" : "\(days)d \(rest)h"
    }

    /// "just now", "5m", "3h", "2d", "Mar 4".
    static func age(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "just now" }
        if seconds < 3_600 { return "\(Int(seconds / 60))m" }
        if seconds < 86_400 { return "\(Int(seconds / 3_600))h" }
        if seconds < 86_400 * 30 { return "\(Int(seconds / 86_400))d" }
        let style = Date.FormatStyle.dateTime.month(.abbreviated).day()
        return Calendar.current.isDate(date, equalTo: now, toGranularity: .year)
            ? date.formatted(style) : date.formatted(style.year())
    }
}
