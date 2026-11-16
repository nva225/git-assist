import AppKit
import SwiftUI

struct MainView: View {
    @ObservedObject var model: MainViewModel
    @ObservedObject var store: PRStore
    @ObservedObject var settings = Settings.shared
    var openPreferences: () -> Void

    private static let topAnchor = "results-top"

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ZStack(alignment: .topLeading) {
                results
                if !model.suggestions.isEmpty {
                    SuggestionList(model: model)
                        .padding(.leading, 40)
                        .padding(.top, 2)
                }
            }
            Divider()
            footer
        }
        .frame(minWidth: 640, minHeight: 420)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                QueryField(model: model)
                    .frame(height: 22)
                if !model.query.isEmpty {
                    Button {
                        model.setQuery("")
                        model.focusSearch(selectAll: false)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12)))

            Picker("", selection: $model.mode) {
                ForEach(ListMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .disabled(model.isSearching)
            .help(model.isSearching ? "Search always covers every cached PR"
                  : "Open PRs; all of yours and your team's including merged; or newest activity first (⇥ / ⇧⇥ to switch)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Results

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Color.clear.frame(height: 0).id(Self.topAnchor)
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(model.sections) { section in
                        Section {
                            ForEach(section.rows) { row in
                                if section.splitsClosed, row.id == section.firstClosedID {
                                    ClosedDivider()
                                }
                                PRRowView(row: row, selected: model.selection == row.id, needles: model.needles,
                                          now: store.now) { url in
                                    model.selection = row.id
                                    model.open(row.pr, url: url)
                                }
                                .id(row.id)
                                Divider().padding(.leading, 48)
                            }
                        } header: {
                            SectionHeader(section: section)
                        }
                    }
                    if model.sections.isEmpty { emptyState }
                }
                // A fresh list per result set: rows reused across sets could keep a previous search's
                // snippets and highlights.
                .id(model.resultsVersion)
            }
            .onChange(of: model.selection) { _, selection in
                if let selection { withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(selection) } }
            }
            .onChange(of: model.queryVersion) { _, _ in
                proxy.scrollTo(Self.topAnchor, anchor: .top)
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 8) {
            if case .error(let message) = store.status, store.viewer == nil {
                Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.orange)
                Text("Can't reach GitHub").font(.headline)
                Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            } else if store.viewer == nil || !store.loaded {
                ProgressView()
                Text("Connecting to GitHub…").foregroundStyle(.secondary)
            } else if settings.repos.isEmpty {
                RepoPicker(store: store)
            } else if model.isSearching {
                Image(systemName: "magnifyingglass").font(.largeTitle).foregroundStyle(.tertiary)
                Text("No PRs match").font(.headline)
                if store.backfillProgress != nil {
                    Text("History is still being indexed, so older PRs may be missing.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            } else {
                Image(systemName: "checkmark.circle").font(.largeTitle).foregroundStyle(.green)
                Text(model.mode == .open ? "Nothing open involves you" : "Nothing involves you yet")
                    .font(.headline)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
        .padding(.horizontal, 40)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            statusText
            Spacer()
            Button {
                store.syncNow()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Sync now (⌘R)")
            .disabled(store.status == .syncing)
            Button(action: openPreferences) {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Preferences (⌘,)")
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private var statusText: some View {
        HStack(spacing: 6) {
            switch store.status {
            case .syncing:
                ProgressView().controlSize(.mini)
                Text("Syncing…")
            case .error(let message):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message).lineLimit(1).truncationMode(.tail)
            case .idle:
                if let lastSync = store.lastSync {
                    Text("Synced \(Format.age(lastSync, now: store.now))")
                }
            }
            Text("·")
            Text("\(store.prs.count.formatted()) PRs cached")
            if let progress = store.backfillProgress {
                Text("·")
                Text("indexing history \(progress.done.formatted())/\(progress.total.formatted())")
            }
        }
    }
}

// MARK: - Pieces

private struct SectionHeader: View {
    let section: ResultSection
    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(section.color).frame(width: 8, height: 8)
            Text(section.title.uppercased())
                .font(.system(size: 11, weight: .bold))
                .tracking(0.6)
            Text(countLabel)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var countLabel: String {
        let total = section.total ?? section.rows.count
        return total > section.rows.count ? "\(section.rows.count) of \(total.formatted())" : "\(total)"
    }
}

private struct ClosedDivider: View {
    var body: some View {
        HStack(spacing: 8) {
            Text("MERGED & CLOSED")
                .font(.system(size: 9.5, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(.tertiary)
            Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 1)
        }
        .padding(.leading, 48)
        .padding(.trailing, 14)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }
}

extension ResultSection {
    var firstClosedID: String? { rows.first { $0.pr.state != .open }?.id }
}

private struct SuggestionList: View {
    @ObservedObject var model: MainViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(model.suggestions.enumerated()), id: \.element.id) { index, suggestion in
                HStack(spacing: 12) {
                    Text(suggestion.label)
                        .font(.system(size: 13, design: .monospaced))
                    Spacer(minLength: 8)
                    Text(suggestion.detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(index == model.suggestionIndex ? Color.accentColor.opacity(0.22) : .clear)
                .contentShape(Rectangle())
                .onTapGesture { model.accept(suggestion) }
            }
            Text("⇥ complete   ↑↓ choose   esc hide")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
        }
        .padding(.vertical, 4)
        .frame(width: 400, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
        )
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12)))
    }
}

struct PRRowView: View {
    let row: ResultRow
    let selected: Bool
    let needles: [String]
    let now: Date
    let open: (String?) -> Void
    @State private var hovering = false
    /// The comment line under the pointer, which opens its own link instead of the PR's.
    @State private var hoveredSnippet: Snippet?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            StatusGlyph(pr: row.pr, inv: row.inv)
            VStack(alignment: .leading, spacing: 4) {
                titleLine
                ChipLine(pr: row.pr, inv: row.inv, now: now)
                // No spacing: each line's hover area reaches halfway into the gap, so moving between
                // lines never passes over the row (which would flash the title underline).
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(row.snippets, id: \.self) { snippet in
                        SnippetLine(snippet: snippet, needles: needles, now: now, hovered: hoveredSnippet == snippet)
                            .onHover { inside in
                                if inside { hoveredSnippet = snippet } else if hoveredSnippet == snippet { hoveredSnippet = nil }
                            }
                            .onTapGesture { open(snippet.url) }
                    }
                }
                .padding(.vertical, -SnippetLine.hitSlop)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(selected ? Color.accentColor.opacity(0.16) : hovering ? Color.primary.opacity(0.05) : .clear)
        .opacity(selected || hovering ? 1 : row.pr.state != .open ? 0.5 : row.inv?.bucket == .approved ? 0.7 : 1)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { open(nil) }
        .contextMenu {
            Button("Open in Browser") { open(nil) }
            Button("Open Files Changed") { open(row.pr.url + "/files") }
            Divider()
            Button("Copy Link") { copy(row.pr.url) }
            Button("Copy Branch Name") { copy(row.pr.branch) }
        }
    }

    private var titleLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(highlighted(row.pr.title, needles))
                .font(.system(size: 13.5, weight: row.pr.state == .open ? .medium : .regular))
                .underline(hovering && hoveredSnippet == nil)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let deadline = row.inv?.deadline {
                DeadlineBadge(deadline: deadline)
            } else {
                Text(Format.age(row.pr.updatedAt, now: now))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .help("Last updated")
            }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct StatusGlyph: View {
    let pr: PullRequest
    let inv: Involvement?

    var body: some View {
        let (symbol, color) = style
        ZStack {
            Circle().fill(color.opacity(0.16))
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(color)
        }
        .frame(width: 24, height: 24)
        .padding(.top, 1)
    }

    /// Color is the PR's state, as on GitHub (open green, merged purple, closed red); the shape says
    /// how you're involved while it's open.
    private var style: (String, Color) {
        if pr.state == .merged { return ("arrow.triangle.merge", .purple) }
        if pr.state == .closed { return ("xmark", .red) }
        switch inv?.bucket {
        case .needsReview: return ("eyes", .green)
        case .mine: return ("person.fill", .green)
        case .commented: return ("text.bubble.fill", .green)
        case .approved: return ("checkmark.seal.fill", .green)
        case .mentioned: return ("at", .green)
        default: return ("arrow.triangle.pull", .green)
        }
    }
}

private struct DeadlineBadge: View {
    let deadline: Deadline

    var body: some View {
        let color: Color = deadline.level == .overdue ? .red : deadline.level == .warn ? .orange : .secondary
        Text(deadline.label)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(deadline.level == .overdue ? .white : color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(deadline.level == .overdue ? Color.red : color.opacity(0.15)))
            .help("Business days since you were requested; weekends don't count")
    }
}

private struct Chip: View {
    let text: String
    var symbol: String?
    var color: Color = .secondary
    var filled = false

    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .bold)) }
            Text(text).font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(filled ? .white : color)
        .padding(.horizontal, 6)
        .padding(.vertical, 1.5)
        .background(Capsule().fill(filled ? color : color.opacity(0.13)))
    }
}

private struct ChipLine: View {
    let pr: PullRequest
    let inv: Involvement?
    let now: Date

    var body: some View {
        HStack(spacing: 6) {
            Text("#\(String(pr.number))")
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(pr.author)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
            stateChip
            if let inv { involvementChips(inv) }
            if !pr.comments.isEmpty {
                Chip(text: "\(pr.comments.count)", symbol: "bubble.left")
                    .help("\(pr.comments.count) comments")
            }
            Text("+\(pr.additions)").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.green.opacity(0.85))
            Text("−\(pr.deletions)").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.red.opacity(0.85))
        }
        .lineLimit(1)
    }

    @ViewBuilder
    private var stateChip: some View {
        switch pr.state {
        case .merged: Chip(text: "Merged", symbol: "arrow.triangle.merge", color: .purple)
        case .closed: Chip(text: "Closed", symbol: "xmark", color: .red)
        case .open: if pr.isDraft { Chip(text: "Draft", symbol: "pencil", color: .gray) }
        }
    }

    @ViewBuilder
    private func involvementChips(_ inv: Involvement) -> some View {
        if inv.isMine {
            if inv.isCoAuthored {
                Chip(text: "your commits", symbol: "arrow.triangle.branch", color: .purple)
                    .help("Opened by \(pr.author), but you've pushed commits to it")
            }
            if !inv.approvers.isEmpty {
                Chip(text: "\(inv.approvers.count)", symbol: "checkmark", color: .green)
                    .help("Approved by " + inv.approvers.joined(separator: ", "))
            }
            if !inv.changesRequestedBy.isEmpty {
                Chip(text: "\(inv.changesRequestedBy.count)", symbol: "exclamationmark.octagon", color: .red)
                    .help("Changes requested by " + inv.changesRequestedBy.joined(separator: ", "))
            }
            if !pr.requestedReviewers.isEmpty {
                Text("waiting on " + pr.requestedReviewers.joined(separator: ", "))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        } else {
            if inv.needsReview, let at = inv.requestedAt {
                Chip(text: "requested \(Format.age(at, now: now))" + (inv.requestedBy.map { " by \($0)" } ?? ""),
                     symbol: "eyes", color: .orange)
            }
            if inv.approved {
                Chip(text: inv.approvalStale ? "You approved · new commits" : "You approved",
                     symbol: "checkmark.seal.fill", color: inv.approvalStale ? .orange : .green)
            } else if inv.changesRequested {
                Chip(text: "You requested changes", symbol: "exclamationmark.octagon", color: .red)
            } else if inv.commented, let last = inv.myLastActivity {
                Chip(text: "You commented \(Format.age(last, now: now))", symbol: "text.bubble", color: .blue)
            }
            if inv.newCommitsSinceMine, !inv.approvalStale {
                Chip(text: "New commits", symbol: "arrow.triangle.branch", color: .indigo)
            }
            if !inv.approvers.isEmpty {
                Chip(text: "\(inv.approvers.count)", symbol: "checkmark", color: .green)
                    .help("Approved by " + inv.approvers.joined(separator: ", "))
            }
            if inv.mentioned || inv.assigned {
                Chip(text: inv.assigned ? "Assigned" : "Mentioned", symbol: "at", color: .teal)
            }
        }
        if inv.newSinceMine > 0 {
            Chip(text: "\(inv.newSinceMine) new", symbol: "sparkle", color: .blue, filled: true)
                .help("Comments or reviews since your last comment or since you last opened it")
        }
    }
}

private struct SnippetLine: View {
    let snippet: Snippet
    let needles: [String]
    let now: Date
    var hovered = false

    /// Invisible hover/click margin above and below the drawn highlight.
    static let hitSlop: CGFloat = 2

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "text.quote")
                .font(.system(size: 10))
                .foregroundStyle(hovered ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
            (snippet.author.isEmpty ? Text(highlighted(snippet.text, needles))
                 : Text("\(Text(snippet.author).fontWeight(.semibold))  \(Text(highlighted(snippet.text, needles)))"))
                .font(.system(size: 12))
                .foregroundStyle(hovered ? .primary : .secondary)
                .lineLimit(2)
            Spacer(minLength: 4)
            Text(Format.age(snippet.date, now: now))
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
            // Always laid out, only shown on hover, so nothing shifts under the pointer.
            Image(systemName: "arrow.up.right.square")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .opacity(hovered ? 1 : 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(hovered ? 0.13 : 0)))
        .padding(.leading, -4)
        .padding(.vertical, Self.hitSlop)
        .contentShape(Rectangle())
        .help(snippet.url.contains("#") ? "Open this comment on GitHub" : "Open the PR on GitHub")
    }
}

func highlighted(_ text: String, _ needles: [String]) -> AttributedString {
    var attributed = AttributedString(text)
    for needle in needles where !needle.isEmpty {
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let found = text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive],
                                     range: searchStart..<text.endIndex) {
            if let range = Range(found, in: attributed) {
                attributed[range].backgroundColor = Color.yellow.opacity(0.38)
            }
            searchStart = found.upperBound
        }
    }
    return attributed
}
