import AppKit
import SwiftUI

struct PopupCard: Identifiable, Codable {
    let id: String  // PR key: one card per PR
    var prNumber: Int
    var prTitle: String
    var prURL: String
    var events: [ActivityEvent]  // newest first
    var bumpedAt: Date

    var lead: ActivityEvent {
        events.min { ($0.kind.priority, -$0.date.timeIntervalSince1970) < ($1.kind.priority, -$1.date.timeIntervalSince1970) }!
    }

    /// "+2 comments · 1 approval" for everything besides the headline.
    var summary: String? {
        let rest = events.filter { $0.id != lead.id }
        guard !rest.isEmpty else { return nil }
        var counts: [(String, Int)] = []
        for event in rest {
            if let i = counts.firstIndex(where: { $0.0 == event.summaryNoun }) {
                counts[i].1 += 1
            } else {
                counts.append((event.summaryNoun, 1))
            }
        }
        return "+ " + counts.map { noun, n in
            n == 1 || noun.hasSuffix("requested") ? "\(n) \(noun)" : "\(n) \(noun)s"
        }.joined(separator: " · ")
    }

    var autoHides: Bool {
        events.allSatisfy { Settings.shared.prefs($0.kind.category).autoHide }
    }
}

/// Top-of-screen popups: one borderless panel per PR, stacked down from the top center of whichever
/// screen holds the focused window. They stay until dismissed. Once the stack sits untouched for a while
/// it fades and collapses into a deck behind the newest card; hovering fans it back out.
@MainActor
final class PopupCenter: ObservableObject {
    /// Saved on every change: popups are like unread mail and survive restarts until clicked or dismissed.
    @Published private(set) var cards: [PopupCard] = [] {
        didSet { save() }
    }
    @Published private(set) var collapsed = false
    /// While set and in the future, popups are hidden; new activity still collects into the stack quietly.
    @Published private(set) var snoozedUntil: Date? {
        didSet { UserDefaults.standard.set(snoozedUntil?.timeIntervalSince1970, forKey: "snoozedUntil") }
    }
    var onOpen: ((String, String) -> Void)?  // (PR key, URL)

    var isSnoozed: Bool { snoozedUntil.map { $0 > Date() } ?? false }

    static let snoozeChoices: [(label: String, minutes: Int)] = [("15m", 15), ("1h", 60), ("2h", 120)]

    private struct Slot {
        let panel: PopupPanel
        let host: FirstMouseHostingView<PopupCardView>
    }

    private var slots: [String: Slot] = [:]
    private var snoozePanel: PopupPanel?
    private var snoozeBarHost: FirstMouseHostingView<SnoozeBarView>?
    private static let snoozeBarID = "snooze-bar"
    private var hovered = Set<String>()
    private var idleSince = Date()
    private var screen: NSScreen?
    private var timer: Timer?

    static let width: CGFloat = 440
    static let maxPeeks = 3
    private static let gap: CGFloat = 8
    /// How much of each card behind the front one shows below it in the deck.
    private static let peek: CGFloat = 7

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        let saved = UserDefaults.standard.double(forKey: "snoozedUntil")
        if saved > Date().timeIntervalSince1970 { snoozedUntil = Date(timeIntervalSince1970: saved) }
        restore()
    }

    // MARK: - Snooze

    func snooze(minutes: Int) {
        snoozedUntil = Date().addingTimeInterval(TimeInterval(minutes * 60))
        hovered.removeAll()
        layout()
    }

    func resume() {
        guard snoozedUntil != nil else { return }
        snoozedUntil = nil
        screen = Self.focusedScreen()
        idleSince = Date()
        setCollapsed(false, relayout: false)
        layout()
    }

    // MARK: - Persistence

    private static let file: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("GitAssist/popups.json")

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(cards) else { return }
        try? FileManager.default.createDirectory(at: Self.file.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: Self.file, options: .atomic)
    }

    private func restore() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: Self.file),
              let saved = try? decoder.decode([PopupCard].self, from: data), !saved.isEmpty else { return }
        // Fresh clocks: restored popups show fully, then stack up after the usual idle time.
        cards = saved.map { card in
            var card = card
            card.bumpedAt = Date()
            return card
        }
        screen = Self.focusedScreen()
        idleSince = Date()
        sync()
    }

    func post(_ events: [ActivityEvent]) {
        let settings = Settings.shared
        let wanted = events.filter { settings.prefs($0.kind.category).enabled }
        guard !wanted.isEmpty else { return }

        for event in wanted.sorted(by: { $0.date < $1.date }) {
            if let i = cards.firstIndex(where: { $0.id == event.prKey }) {
                var card = cards.remove(at: i)
                if !card.events.contains(where: { $0.id == event.id }) { card.events.insert(event, at: 0) }
                card.prTitle = event.prTitle
                card.bumpedAt = Date()
                cards.insert(card, at: 0)
            } else {
                cards.insert(PopupCard(id: event.prKey, prNumber: event.prNumber, prTitle: event.prTitle,
                                       prURL: event.prURL, events: [event], bumpedAt: Date()), at: 0)
            }
        }
        if settings.playSound, !isSnoozed { NSSound(named: "Glass")?.play() }
        screen = Self.focusedScreen()
        idleSince = Date()
        setCollapsed(false, relayout: false)
        sync()
    }

    func dismiss(_ id: String) {
        cards.removeAll { $0.id == id }
        hovered.remove(id)
        if cards.isEmpty { setCollapsed(false, relayout: false) }
        sync()
    }

    func dismissAll() {
        cards.removeAll()
        hovered.removeAll()
        setCollapsed(false, relayout: false)
        sync()
    }

    func open(_ id: String) {
        guard let card = cards.first(where: { $0.id == id }) else { return }
        let target = card.events.count == 1 ? card.lead.url : card.prURL
        if let url = URL(string: target) { NSWorkspace.shared.open(url) }
        onOpen?(card.id, target)
        dismiss(id)
    }

    func setHovered(_ id: String, _ isHovered: Bool) {
        if isHovered {
            hovered.insert(id)
            setCollapsed(false, relayout: true)
        } else {
            hovered.remove(id)
            idleSince = Date()  // the idle clock restarts once the mouse leaves
        }
    }

    // MARK: - Timing

    private func tick() {
        let settings = Settings.shared
        let now = Date()
        if let until = snoozedUntil {
            if until <= now { resume() } else { return }
        }
        let expired = Set(cards.filter { card in
            !hovered.contains(card.id) && card.autoHides && now.timeIntervalSince(card.bumpedAt) > settings.autoHideDelay
        }.map(\.id))
        if !expired.isEmpty {
            cards.removeAll { expired.contains($0.id) }
            sync()
        }
        if !cards.isEmpty, hovered.isEmpty, now.timeIntervalSince(idleSince) > settings.fadeDelay {
            setCollapsed(true, relayout: true)
        }
    }

    private func setCollapsed(_ value: Bool, relayout: Bool) {
        guard collapsed != value else { return }
        withAnimation(.easeInOut(duration: value ? 0.4 : 0.25)) { collapsed = value }
        if relayout { layout() }
    }

    // MARK: - Panels

    private func sync() {
        let ids = Set(cards.map(\.id))
        for (id, slot) in slots where !ids.contains(id) {
            slots[id] = nil
            let panel = slot.panel
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.2
                panel.animator().alphaValue = 0
            }, completionHandler: {
                panel.orderOut(nil)
            })
        }
        for card in cards where slots[card.id] == nil {
            let host = FirstMouseHostingView(rootView: PopupCardView(center: self, id: card.id))
            // Intrinsic size only: it's what fittingSize measures. (The min/max options would make SwiftUI
            // size the window, but the host isn't the window's content view, so there's nothing to fight.)
            host.sizingOptions = [.intrinsicContentSize]
            let id = card.id
            host.onHover = { [weak self] hovering in self?.setHovered(id, hovering) }
            let panel = PopupPanel(host: host)
            panel.alphaValue = 0
            slots[card.id] = Slot(panel: panel, host: host)
        }
        // Let SwiftUI lay out the updated cards before measuring them.
        DispatchQueue.main.async { [weak self] in self?.layout() }
    }

    /// Expanded: cards in a column. Collapsed: every card tucked behind the front one, each showing a
    /// sliver of its bottom edge. The front card is in the same place either way.
    private func layout() {
        if isSnoozed || cards.isEmpty {
            let panels = slots.values.map(\.panel) + [snoozePanel].compactMap { $0 }
            for panel in panels where panel.isVisible {
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.2
                    panel.animator().alphaValue = 0
                }, completionHandler: {
                    panel.orderOut(nil)
                })
            }
            return
        }
        guard let screen = screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let x = (visible.midX - Self.width / 2).rounded()
        let heights = cards.map { card in slots[card.id].map { ceil($0.host.fittingSize.height) } ?? 0 }
        let top = (visible.maxY - 10).rounded()
        let frontBottom = top - heights[0]
        var nextTop = top

        for (i, card) in cards.enumerated() {
            guard let slot = slots[card.id] else { continue }
            let full = heights[i]
            slot.host.frame = NSRect(x: 0, y: 0, width: Self.width, height: full)
            let frame: NSRect
            let alpha: CGFloat
            if collapsed {
                let depth = CGFloat(min(i, Self.maxPeeks))
                // Never taller than the front card plus its sliver, so nothing pokes out above the deck.
                let height = min(full, heights[0] + depth * Self.peek)
                frame = NSRect(x: x, y: frontBottom - depth * Self.peek, width: Self.width, height: height)
                alpha = i > Self.maxPeeks ? 0 : Settings.shared.fadedOpacity
            } else {
                frame = NSRect(x: x, y: nextTop - full, width: Self.width, height: full)
                nextTop -= full + Self.gap
                alpha = 1
            }
            move(slot.panel, to: frame, alpha: alpha)
        }
        // Back to front, so the newest card sits on top of the deck.
        for card in cards.reversed() { slots[card.id]?.panel.orderFrontRegardless() }
        layoutSnoozeBar(below: nextTop, centerX: visible.midX)
    }

    /// The snooze pill sits under the expanded column and steps out of the way while the deck is collapsed.
    private func layoutSnoozeBar(below top: CGFloat, centerX: CGFloat) {
        if snoozePanel == nil {
            let host = FirstMouseHostingView(rootView: SnoozeBarView(center: self))
            host.sizingOptions = [.intrinsicContentSize]
            host.onHover = { [weak self] hovering in self?.setHovered(Self.snoozeBarID, hovering) }
            let panel = PopupPanel(host: host)
            panel.alphaValue = 0
            snoozePanel = panel
            snoozeBarHost = host
        }
        guard let panel = snoozePanel, let host = snoozeBarHost else { return }
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        let frame = NSRect(x: (centerX - size.width / 2).rounded(), y: (top - size.height).rounded(),
                           width: ceil(size.width), height: ceil(size.height))
        if collapsed {
            panel.ignoresMouseEvents = true
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.25
                panel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    if self?.collapsed ?? true { panel.orderOut(nil) }
                }
            })
        } else {
            panel.ignoresMouseEvents = false
            panel.orderFrontRegardless()
            move(panel, to: frame, alpha: 1)
        }
    }

    private func move(_ panel: PopupPanel, to frame: NSRect, alpha: CGFloat) {
        let collapsing = collapsed
        if !panel.isVisible { panel.setFrame(frame.offsetBy(dx: 0, dy: 16), display: false) }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = collapsing ? 0.4 : 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(frame, display: true)
        }, completionHandler: {
            panel.invalidateShadow()
        })
        NSAnimationContext.runAnimationGroup { context in
            context.duration = collapsing ? 1.0 : 0.15
            panel.animator().alphaValue = alpha
        }
    }

    /// The screen holding the frontmost app's frontmost window — not whichever screen has the menu bar.
    static func focusedScreen() -> NSScreen {
        let screens = NSScreen.screens
        if let app = NSWorkspace.shared.frontmostApplication,
           let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]],
           let primary = screens.first {
            for info in windows {
                guard (info[kCGWindowOwnerPID as String] as? pid_t) == app.processIdentifier,
                      (info[kCGWindowLayer as String] as? Int) == 0,
                      let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                      let bounds = CGRect(dictionaryRepresentation: boundsDict),
                      bounds.width > 50, bounds.height > 50 else { continue }
                // Window bounds are top-left based from the primary screen; NSScreen frames are bottom-left.
                let center = NSPoint(x: bounds.midX, y: primary.frame.maxY - bounds.midY)
                if let screen = screens.first(where: { $0.frame.contains(center) }) { return screen }
            }
        }
        let mouse = NSEvent.mouseLocation
        return screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? screens[0]
    }
}

final class PopupPanel: NSPanel {
    init(host: NSView) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: PopupCenter.width, height: 80),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true

        // The card is pinned to the bottom of a clipping container, so when the deck shortens a window
        // only the card's top is cut, and that part is hidden behind the card in front.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: PopupCenter.width, height: 80))
        container.wantsLayer = true
        container.layer?.masksToBounds = true
        host.autoresizingMask = [.maxYMargin]
        container.addSubview(host)
        contentView = container
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Lets the very first click on an inactive popup count, instead of only focusing it, and reports hover
/// even though the panel never becomes key (SwiftUI's onHover can't be relied on there).
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    var onHover: ((Bool) -> Void)?
    private var tracking: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHover?(false)
    }
}

extension ActivityKind {
    var color: Color {
        switch self {
        case .approved: .green
        case .changesRequested: .red
        case .commented: .blue
        case .reviewRequested: .orange
        case .reply: .teal
        case .newCommits: .indigo
        case .dueSoon: .orange
        case .overdue: .red
        }
    }
}

struct PopupCardView: View {
    @ObservedObject var center: PopupCenter
    let id: String

    var body: some View {
        if let index = center.cards.firstIndex(where: { $0.id == id }) {
            // 0 is the front card; cards behind it in the deck narrow a little per level.
            let depth = center.collapsed ? min(index, PopupCenter.maxPeeks) : 0
            let more = center.collapsed && index == 0 ? center.cards.count - 1 : 0
            content(center.cards[index], depth: depth, more: more)
                .scaleEffect(1 - 0.045 * CGFloat(depth), anchor: .bottom)
                .animation(.easeInOut(duration: center.collapsed ? 0.4 : 0.25), value: depth)
        }
    }

    private func content(_ card: PopupCard, depth: Int, more: Int) -> some View {
        let lead = card.lead
        let color = lead.kind.color
        return HStack(spacing: 0) {
            Rectangle().fill(color).frame(width: 5)
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle().fill(color.opacity(0.18))
                    Image(systemName: lead.kind.symbol)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(color)
                }
                .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(lead.headline)
                            .font(.system(size: 13.5, weight: .semibold))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        if more > 0 {
                            Text("\(more) more")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.primary.opacity(0.08)))
                                .transition(.opacity)
                        }
                        TimelineView(.periodic(from: .now, by: 30)) { context in
                            Text(Format.age(lead.date, now: context.date))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text("#\(String(card.prNumber))  \(card.prTitle)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if !lead.snippet.isEmpty, lead.kind != .reviewRequested {
                        Text(lead.snippet)
                            .font(.system(size: 12))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let summary = card.summary {
                        Text(summary)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(color)
                    }
                }
                .padding(.trailing, 22)
            }
            .padding(.vertical, 11)
            .padding(.leading, 12)
            .padding(.trailing, 10)
            // Behind the front card only the shell shows; text would bleed through the faded front card.
            .opacity(depth > 0 ? 0 : 1)
        }
        .frame(width: PopupCenter.width, alignment: .leading)
        .background(.regularMaterial)
        .background(color.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(color.opacity(0.35), lineWidth: 1)
        )
        .overlay(alignment: .topTrailing) {
            Button {
                center.dismiss(id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(6)
            .help("Dismiss")
            .opacity(depth > 0 ? 0 : 1)
        }
        .contentShape(Rectangle())
        .onTapGesture { center.open(id) }
        .help("Open in browser")
    }
}

struct SnoozeBarView: View {
    let center: PopupCenter

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "moon.zzz.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.indigo)
            Text("Snooze")
                .font(.system(size: 12, weight: .semibold))
                .padding(.trailing, 2)
            ForEach(PopupCenter.snoozeChoices, id: \.minutes) { choice in
                SnoozeChoiceButton(label: choice.label) { center.snooze(minutes: choice.minutes) }
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 5)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12)))
        .help("Hide all popups for a while; new activity waits quietly")
    }
}

private struct SnoozeChoiceButton: View {
    let label: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(hovering ? Color.white : Color.primary)
                .frame(minWidth: 30)
                .padding(.vertical, 3)
                .background(Capsule().fill(hovering ? Color.indigo : Color.primary.opacity(0.08)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
