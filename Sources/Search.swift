import Foundation

/// Lowercased UTF-8 bytes, searched with memmem: several times faster than String.contains, which
/// walks grapheme clusters.
struct LowerText: Sendable {
    let bytes: [UInt8]

    init(_ text: String) { bytes = Array(text.lowercased().utf8) }

    func contains(_ needle: Needle) -> Bool {
        let n = needle.bytes
        guard !n.isEmpty else { return true }
        guard bytes.count >= n.count else { return false }
        return bytes.withUnsafeBytes { haystack in
            n.withUnsafeBytes { memmem(haystack.baseAddress, haystack.count, $0.baseAddress, $0.count) != nil }
        }
    }
}

struct Needle {
    let bytes: [UInt8]
    init(_ text: String) { bytes = Array(text.lowercased().utf8) }
}

/// Lowercased text for one PR, kept alongside the cache so searching never re-lowercases.
struct SearchDoc: Sendable {
    let title: LowerText
    let body: LowerText
    let branch: LowerText
    /// Aligned with `PullRequest.comments`.
    let comments: [LowerText]

    init(_ pr: PullRequest) {
        title = LowerText(pr.title)
        body = LowerText(pr.body)
        branch = LowerText(pr.branch)
        comments = pr.comments.map { LowerText($0.body) }
    }
}

enum Qualifier: String, CaseIterable {
    case author, commenter, comment, title, body, reviewer
    case approvedBy = "approved-by"
    case involves, label, branch
    case `is`

    var hint: String {
        switch self {
        case .author: "Opened the PR"
        case .commenter: "Commented on or reviewed it"
        case .comment: "Text in a comment (pairs with commenter:)"
        case .title: "Text in the title"
        case .body: "Text in the description"
        case .reviewer: "Requested as, or acted as, reviewer"
        case .approvedBy: "Approved it"
        case .involves: "Author, reviewer, commenter, assignee, or @-mentioned"
        case .label: "Has this label"
        case .branch: "Branch name contains"
        case .is: "State, or how you're involved"
        }
    }

    var takesLogin: Bool {
        switch self {
        case .author, .commenter, .reviewer, .approvedBy, .involves: true
        default: false
        }
    }
}

extension String {
    /// Login qualifiers take partial logins: author:ali finds AliceSmith.
    func matchesLogin(_ partial: String) -> Bool { range(of: partial, options: .caseInsensitive) != nil }
}

struct SearchFilter {
    let qualifier: Qualifier
    let value: String
    let negated: Bool
}

struct ParsedQuery {
    var terms: [(text: String, negated: Bool)] = []
    var filters: [SearchFilter] = []

    var isEmpty: Bool { terms.isEmpty && filters.isEmpty }

    /// What to highlight in results.
    var needles: [String] {
        terms.filter { !$0.negated }.map(\.text)
            + filters.filter { !$0.negated && [.comment, .title, .body].contains($0.qualifier) }.map(\.value)
    }

    init(_ text: String, me: String) {
        for token in Search.tokenize(text) {
            var word = token.text
            var negated = false
            if word.hasPrefix("-"), word.count > 1 {
                negated = true
                word.removeFirst()
            }
            if let colon = word.firstIndex(of: ":"), let qualifier = Qualifier(rawValue: word[..<colon].lowercased()) {
                var value = Search.unquote(String(word[word.index(after: colon)...]))
                guard !value.isEmpty else { continue }
                value = qualifier.takesLogin ? Search.resolveLogin(value, me: me) : value.lowercased()
                filters.append(SearchFilter(qualifier: qualifier, value: value, negated: negated))
            } else {
                let value = Search.unquote(word).lowercased()
                if !value.isEmpty { terms.append((value, negated)) }
            }
        }
    }
}

struct Snippet: Hashable {
    let author: String
    let text: String
    let url: String
    let date: Date
}

struct SearchHit {
    let pr: PullRequest
    let inv: Involvement?
    let snippets: [Snippet]
}

struct Suggestion: Identifiable, Hashable {
    var id: String { replacement }
    let label: String
    let detail: String
    let replacement: String
}

struct SuggestionSet {
    let range: Range<String.Index>
    let items: [Suggestion]
}

@MainActor
enum Search {
    static let isValues: [(String, String)] = [
        ("open", "Open PRs"),
        ("closed", "Closed without merging"),
        ("merged", "Merged"),
        ("draft", "Drafts"),
        ("all", "Any state"),
        ("mine", "You opened it"),
        ("needs-review", "Waiting on your review"),
        ("requested", "You're a requested reviewer"),
        ("approved", "You approved it"),
        ("commented", "You commented or reviewed"),
        ("overdue", "Past the review deadline"),
        ("mentioned", "Mentions or assigns you"),
    ]

    // MARK: - Running a query

    static func run(_ query: ParsedQuery, store: PRStore, limit: Int = 200) -> [SearchHit] {
        let commenters = query.filters.filter { $0.qualifier == .commenter && !$0.negated }.map(\.value)
        var matches: [(pr: PullRequest, inv: Involvement??, score: Int, comments: [Int])] = []

        let termNeedles = query.terms.map { Needle($0.text) }
        let filterNeedles = query.filters.map { Needle($0.value) }

        for pr in store.prs.values {
            guard let doc = store.docs[pr.key] else { continue }
            // Only is: filters need this up front; otherwise it's computed for the rows shown.
            var cachedInv: Involvement??
            func involvement() -> Involvement? {
                if cachedInv == nil { cachedInv = .some(store.involvement(pr)) }
                return cachedInv!
            }

            var score = 0
            var commentHits: [Int] = []
            var ok = true

            for (ti, term) in query.terms.enumerated() {
                let t = term.text, n = termNeedles[ti]
                var s = 0
                if let number = Int(t.hasPrefix("#") ? String(t.dropFirst()) : t), number == pr.number { s = 50 }
                if doc.title.contains(n) { s = max(s, 10) }
                if doc.branch.contains(n) { s = max(s, 5) }
                if pr.author.lowercased().contains(t) { s = max(s, 4) }
                if doc.body.contains(n) { s = max(s, 3) }
                let inComments = doc.comments.indices.filter { doc.comments[$0].contains(n) }
                if !inComments.isEmpty { s = max(s, 1) }
                if (s > 0) == term.negated {
                    ok = false
                    break
                }
                if !term.negated {
                    score += s
                    commentHits += inComments
                }
            }
            guard ok else { continue }

            for (fi, filter) in query.filters.enumerated() {
                let v = filter.value, n = filterNeedles[fi]
                let pass: Bool
                switch filter.qualifier {
                case .author:
                    pass = pr.author.matchesLogin(v)
                case .commenter:
                    pass = pr.comments.contains { $0.author.matchesLogin(v) } || pr.reviews.contains { $0.author.matchesLogin(v) }
                case .comment:
                    let hits = doc.comments.indices.filter { i in
                        doc.comments[i].contains(n)
                            && (commenters.isEmpty || commenters.contains { pr.comments[i].author.matchesLogin($0) })
                    }
                    pass = !hits.isEmpty
                    if pass, !filter.negated {
                        commentHits += hits
                        score += 2
                    }
                case .title:
                    pass = doc.title.contains(n)
                case .body:
                    pass = doc.body.contains(n)
                case .branch:
                    pass = doc.branch.contains(n)
                case .label:
                    pass = pr.labels.contains { $0.caseInsensitiveCompare(v) == .orderedSame }
                case .reviewer:
                    pass = pr.requestedReviewers.contains { $0.matchesLogin(v) } || pr.reviews.contains { $0.author.matchesLogin(v) }
                case .approvedBy:
                    pass = pr.reviews.contains { $0.state == .approved && $0.author.matchesLogin(v) }
                case .involves:
                    let handle = Needle("@" + v)
                    pass = pr.author.matchesLogin(v)
                        || pr.comments.contains { $0.author.matchesLogin(v) }
                        || pr.reviews.contains { $0.author.matchesLogin(v) }
                        || pr.requestedReviewers.contains { $0.matchesLogin(v) }
                        || pr.assignees.contains { $0.matchesLogin(v) }
                        || doc.body.contains(handle)
                        || doc.comments.contains { $0.contains(handle) }
                case .is:
                    pass = matchesIs(v, pr, involvement)
                }
                if pass == filter.negated {
                    ok = false
                    break
                }
            }
            guard ok else { continue }
            matches.append((pr, cachedInv, score, commentHits))
        }

        matches.sort { a, b in
            let aOpen = a.pr.state == .open, bOpen = b.pr.state == .open
            if aOpen != bOpen { return aOpen }
            if a.score != b.score { return a.score > b.score }
            return a.pr.updatedAt > b.pr.updatedAt
        }

        // Snippets only for what's shown: the excerpt step is the expensive part.
        let needles = query.needles
        return matches.prefix(limit).map { match in
            let ordered = Array(Set(match.comments)).sorted { i, j in
                let ci = match.pr.comments[i], cj = match.pr.comments[j]
                let pi = commenters.contains { ci.author.matchesLogin($0) }
                let pj = commenters.contains { cj.author.matchesLogin($0) }
                if pi != pj { return pi }
                return ci.createdAt > cj.createdAt
            }
            let snippets = ordered.prefix(2).map { i -> Snippet in
                let comment = match.pr.comments[i]
                return Snippet(author: comment.author, text: TextClean.excerpt(comment.body, around: needles),
                               url: comment.url, date: comment.createdAt)
            }
            return SearchHit(pr: match.pr, inv: match.inv ?? store.involvement(match.pr), snippets: snippets)
        }
    }

    private static func matchesIs(_ value: String, _ pr: PullRequest, _ involvement: () -> Involvement?) -> Bool {
        switch value {
        case "open": return pr.state == .open
        case "closed": return pr.state == .closed
        case "merged": return pr.state == .merged
        case "draft": return pr.isDraft
        case "all": return true
        default: break
        }
        guard let inv = involvement() else { return false }
        switch value {
        case "mine": return inv.isMine
        case "needs-review": return inv.needsReview
        case "requested": return inv.isRequested
        case "approved": return inv.approved
        case "commented": return inv.commented
        case "overdue": return inv.deadline?.level == .overdue
        case "mentioned": return inv.mentioned || inv.assigned
        default: return true
        }
    }

    // MARK: - Autocomplete

    /// Suggestions for the word under the cursor (a UTF-16 offset, as AppKit reports it): qualifier
    /// names, or values once a qualifier is typed.
    static func suggestions(for text: String, cursor: Int, store: PRStore) -> SuggestionSet? {
        let cursorIndex = String.Index(utf16Offset: min(max(cursor, 0), text.utf16.count), in: text)
        var start = cursorIndex
        while start > text.startIndex, !text[text.index(before: start)].isWhitespace {
            start = text.index(before: start)
        }
        var end = cursorIndex
        while end < text.endIndex, !text[end].isWhitespace { end = text.index(after: end) }

        let typed = String(text[start..<cursorIndex])
        guard !typed.isEmpty else { return nil }
        let negated = typed.hasPrefix("-")
        let core = negated ? String(typed.dropFirst()) : typed
        let sign = negated ? "-" : ""
        guard !core.isEmpty else { return nil }

        var items: [Suggestion] = []
        if let colon = core.firstIndex(of: ":") {
            guard let qualifier = Qualifier(rawValue: core[..<colon].lowercased()) else { return nil }
            let partial = unquote(String(core[core.index(after: colon)...])).lowercased()
            let candidates: [(String, String)]
            if qualifier.takesLogin {
                candidates = loginCandidates(store)
            } else if qualifier == .is {
                candidates = isValues
            } else if qualifier == .label {
                candidates = store.labels.sorted().map { ($0, "") }
            } else {
                return nil
            }
            items = rank(candidates, by: partial, anywhere: qualifier != .is).prefix(10).map { value, detail in
                let quoted = value.contains(" ") ? "\"\(value)\"" : value
                return Suggestion(label: "\(qualifier.rawValue):\(value)", detail: detail,
                                  replacement: "\(sign)\(qualifier.rawValue):\(quoted) ")
            }
        } else {
            let partial = core.lowercased()
            items = Qualifier.allCases.filter { $0.rawValue.hasPrefix(partial) }.map {
                Suggestion(label: "\($0.rawValue):", detail: $0.hint, replacement: "\(sign)\($0.rawValue):")
            }
        }
        return items.isEmpty ? nil : SuggestionSet(range: start..<end, items: items)
    }

    /// "me" first, then the configured team, then everyone else seen, busiest first.
    private static func loginCandidates(_ store: PRStore) -> [(String, String)] {
        var seen = Set<String>()
        var out: [(String, String)] = []
        func add(_ login: String, _ detail: String) {
            if seen.insert(login.lowercased()).inserted { out.append((login, detail)) }
        }
        add("me", store.viewer.map { "you (\($0))" } ?? "you")
        if let viewer = store.viewer { seen.insert(viewer.lowercased()) }
        for author in Settings.shared.authors.sorted(by: { $0.lowercased() < $1.lowercased() }) { add(author, "team") }
        for (login, count) in store.loginCounts.sorted(by: { $0.value > $1.value }) where count > 0 && login != "ghost" {
            add(login, "")
        }
        return out
    }

    private static func rank(_ candidates: [(String, String)], by partial: String, anywhere: Bool) -> [(String, String)] {
        guard !partial.isEmpty else { return candidates }
        let prefix = candidates.filter { $0.0.lowercased().hasPrefix(partial) }
        guard anywhere else { return prefix }
        let inside = candidates.filter { !$0.0.lowercased().hasPrefix(partial) && $0.0.lowercased().contains(partial) }
        return prefix + inside
    }

    // MARK: - Helpers

    nonisolated static func tokenize(_ s: String) -> [(text: String, range: Range<String.Index>)] {
        var tokens: [(String, Range<String.Index>)] = []
        var i = s.startIndex
        while i < s.endIndex {
            while i < s.endIndex, s[i].isWhitespace { i = s.index(after: i) }
            guard i < s.endIndex else { break }
            let start = i
            var inQuote = false
            while i < s.endIndex, inQuote || !s[i].isWhitespace {
                if s[i] == "\"" { inQuote.toggle() }
                i = s.index(after: i)
            }
            tokens.append((String(s[start..<i]), start..<i))
        }
        return tokens
    }

    nonisolated static func unquote(_ s: String) -> String {
        s.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    nonisolated static func resolveLogin(_ value: String, me: String) -> String {
        let login = value.hasPrefix("@") ? String(value.dropFirst()) : value
        return login.lowercased() == "me" ? me : login
    }
}
