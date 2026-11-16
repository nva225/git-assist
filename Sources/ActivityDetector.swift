import Foundation

/// Compares a PR's previous snapshot with a fresh fetch and reports what's new for popups.
enum ActivityDetector {
    /// `cutoff` keeps a PR seen for the first time from replaying its whole history, and keeps a long
    /// absence from flooding the screen.
    static func events(old: PullRequest?, new pr: PullRequest, me: String, cutoff: Date) -> [ActivityEvent] {
        let known = Set((old?.comments.map(\.id) ?? []) + (old?.reviews.map(\.id) ?? []))
        func fresh(_ id: String, _ date: Date) -> Bool { !known.contains(id) && date > cutoff }
        func event(_ kind: ActivityKind, id: String, actor: String, snippet: String = "", url: String? = nil,
                   date: Date) -> ActivityEvent {
            ActivityEvent(id: "\(kind.rawValue):\(id)", kind: kind, prKey: pr.key, prNumber: pr.number,
                          prTitle: pr.title, prURL: pr.url, actor: actor, snippet: TextClean.oneLine(snippet),
                          url: url ?? pr.url, date: date)
        }

        var out: [ActivityEvent] = []
        let others = pr.comments.filter { !$0.author.sameLogin(me) && fresh($0.id, $0.createdAt) }

        if pr.isOwned(by: me) {
            var reviewIDs = Set<String>()
            for review in pr.reviews where !review.author.sameLogin(me) && fresh(review.id, review.submittedAt) {
                let kind: ActivityKind
                switch review.state {
                case .approved: kind = .approved
                case .changesRequested: kind = .changesRequested
                default: continue
                }
                reviewIDs.insert(review.id)
                let body = pr.comments.first { $0.id == review.id }?.body ?? ""
                out.append(event(kind, id: review.id, actor: review.author, snippet: body, url: review.url,
                                 date: review.submittedAt))
            }
            for comment in others where !reviewIDs.contains(comment.id) {
                out.append(event(.commented, id: comment.id, actor: comment.author, snippet: comment.body,
                                 url: comment.url, date: comment.createdAt))
            }
            return out
        }

        let requestedNow = pr.requestedReviewers.contains { $0.sameLogin(me) }
        let requestedBefore = old?.requestedReviewers.contains { $0.sameLogin(me) } ?? false
        if requestedNow, !requestedBefore, !pr.isDraft {
            let request = pr.reviewRequests.last { $0.reviewer.sameLogin(me) }
            let at = request?.at ?? Date()
            if old != nil || at > cutoff {
                out.append(event(.reviewRequested, id: "\(pr.key)@\(Int(at.timeIntervalSince1970))",
                                 actor: request?.requestedBy ?? pr.author, snippet: pr.title, date: at))
            }
        }

        // Replies only make sense once you'd already taken part before this fetch.
        guard let old, old.comments.contains(where: { $0.author.sameLogin(me) })
                || old.reviews.contains(where: { $0.author.sameLogin(me) }) else { return out }
        for comment in others {
            out.append(event(.reply, id: comment.id, actor: comment.author, snippet: comment.body,
                             url: comment.url, date: comment.createdAt))
        }
        if !old.headOid.isEmpty, old.headOid != pr.headOid, !pr.isDraft {
            out.append(event(.newCommits, id: pr.headOid, actor: pr.author,
                             snippet: "\(pr.branch) is now at \(pr.headOid.prefix(7))",
                             url: pr.url + "/files", date: pr.updatedAt))
        }
        return out
    }
}

enum TextClean {
    private static let tag = try! NSRegularExpression(pattern: "<[^>]*>")
    private static let image = try! NSRegularExpression(pattern: "!\\[[^\\]]*\\]\\([^)]*\\)")
    private static let link = try! NSRegularExpression(pattern: "\\[([^\\]]+)\\]\\([^)]*\\)")
    private static let marks = try! NSRegularExpression(pattern: "(\\*\\*|__|`{1,3}|^#+\\s*|^>\\s*)",
                                                        options: .anchorsMatchLines)
    private static let space = try! NSRegularExpression(pattern: "\\s+")

    /// Markdown/HTML down to a single line of readable text.
    static func oneLine(_ text: String) -> String {
        var s = text
        s = replace(image, in: s, with: " ")
        s = replace(tag, in: s, with: " ")
        s = replace(link, in: s, with: "$1")
        s = replace(marks, in: s, with: "")
        s = replace(space, in: s, with: " ")
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// A window of `oneLine(text)` around the first needle found, with ellipses where it was cut.
    static func excerpt(_ text: String, around needles: [String], radius: Int = 80) -> String {
        let plain = oneLine(text)
        guard let hit = needles.lazy.compactMap({ plain.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) }).first else {
            return plain.count > radius * 2 ? String(plain.prefix(radius * 2)) + "…" : plain
        }
        let start = plain.index(hit.lowerBound, offsetBy: -radius / 2, limitedBy: plain.startIndex) ?? plain.startIndex
        let end = plain.index(hit.upperBound, offsetBy: radius * 3 / 2, limitedBy: plain.endIndex) ?? plain.endIndex
        return (start > plain.startIndex ? "…" : "") + plain[start..<end] + (end < plain.endIndex ? "…" : "")
    }

    private static func replace(_ regex: NSRegularExpression, in s: String, with template: String) -> String {
        regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }
}
