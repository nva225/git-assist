import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var store: PRStore!
    private var popups: PopupCenter!
    private var mainWindow: MainWindowController!
    private var preferences: PreferencesWindowController!
    private let hotkey = GlobalHotkey()
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        store = PRStore()
        popups = PopupCenter()
        preferences = PreferencesWindowController(store: store, popups: popups)
        mainWindow = MainWindowController(store: store, openPreferences: { [weak self] in self?.preferences.show() })

        store.onEvents = { [weak self] events in self?.popups.post(events) }
        popups.onOpen = { [weak self] key, _ in self?.store.markSeen(key) }

        setUpMainMenu()
        setUpStatusItem()
        registerHotkey()

        let settings = Settings.shared
        Publishers.CombineLatest(settings.$hotkeyKeyCode, settings.$hotkeyModifiers)
            .dropFirst()
            .debounce(for: .milliseconds(50), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.registerHotkey() }
            .store(in: &cancellables)
        settings.$repos
            .dropFirst()
            .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.store.syncNow() }
            .store(in: &cancellables)
        store.objectWillChange
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.updateBadge() }
            .store(in: &cancellables)
        popups.$snoozedUntil
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateBadge() }
            .store(in: &cancellables)

        store.start()
        if CommandLine.arguments.contains("--show") || settings.repos.isEmpty { mainWindow.show() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.saveNow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        mainWindow.show()
        return false
    }

    private func registerHotkey() {
        let settings = Settings.shared
        hotkey.register(keyCode: settings.hotkeyKeyCode, modifiers: settings.hotkeyModifiers) { [weak self] in
            MainActor.assumeIsolated { self?.mainWindow.toggle() }
        }
    }

    // MARK: - Menu bar item

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "arrow.triangle.pull", accessibilityDescription: "Git Assist")
        statusItem.button?.imagePosition = .imageLeading
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateBadge()
    }

    /// Count of PRs waiting on your review; red once any is past the deadline.
    private func updateBadge() {
        guard let button = statusItem?.button else { return }
        button.image = NSImage(systemSymbolName: popups.isSnoozed ? "moon.zzz.fill" : "arrow.triangle.pull",
                               accessibilityDescription: popups.isSnoozed ? "Git Assist (popups snoozed)" : "Git Assist")
        let waiting = waitingOnMe()
        let overdue = waiting.contains { $0.1.deadline?.level == .overdue }
        let newOnMine = store.prs.values.contains { pr in
            pr.state == .open && (store.involvement(pr).map { $0.isMine && $0.newSinceMine > 0 } ?? false)
        }
        var text = waiting.isEmpty ? "" : " \(waiting.count)"
        if newOnMine { text += " •" }
        button.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: overdue ? .bold : .regular),
            .foregroundColor: overdue ? NSColor.systemRed : NSColor.labelColor,
        ])
    }

    private func waitingOnMe() -> [(PullRequest, Involvement)] {
        store.prs.values.compactMap { pr -> (PullRequest, Involvement)? in
            guard pr.state == .open, let inv = store.involvement(pr), inv.needsReview else { return nil }
            return (pr, inv)
        }.sorted { ($0.1.deadline?.remaining ?? 0) < ($1.1.deadline?.remaining ?? 0) }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(item("Open Git Assist", #selector(openMain), key: ""))
        menu.items.last?.toolTip = Settings.shared.hotkeyDisplay
        menu.addItem(.separator())

        let waiting = waitingOnMe()
        menu.addItem(header(waiting.isEmpty ? "Nothing waiting on your review" : "Waiting on your review"))
        for (pr, inv) in waiting.prefix(12) {
            let title = "#\(pr.number)  \(truncate(pr.title, 52))   \(inv.deadline?.label ?? "")"
            let menuItem = item(title, #selector(openURL(_:)))
            menuItem.representedObject = [pr.key, pr.url]
            if inv.deadline?.level == .overdue {
                menuItem.image = NSImage(systemSymbolName: "alarm.fill", accessibilityDescription: "Overdue")
            }
            menu.addItem(menuItem)
        }

        if !store.recentEvents.isEmpty {
            menu.addItem(.separator())
            let recent = NSMenuItem(title: "Recent Activity", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for event in store.recentEvents.prefix(20) {
                let menuItem = item("\(event.headline) · #\(event.prNumber)   \(Format.age(event.date))", #selector(openURL(_:)))
                menuItem.representedObject = [event.prKey, event.url]
                menuItem.image = NSImage(systemSymbolName: event.kind.symbol, accessibilityDescription: nil)
                menuItem.toolTip = event.prTitle
                submenu.addItem(menuItem)
            }
            recent.submenu = submenu
            menu.addItem(recent)
        }

        menu.addItem(.separator())
        menu.addItem(header(statusLine()))
        menu.addItem(item("Sync Now", #selector(syncNow)))
        if let until = popups.snoozedUntil, popups.isSnoozed {
            let waiting = popups.cards.isEmpty ? "" : " · \(popups.cards.count) waiting"
            menu.addItem(header("Popups snoozed until \(until.formatted(date: .omitted, time: .shortened))\(waiting)"))
            menu.addItem(item("Resume Popups", #selector(resumePopups)))
        } else {
            let snooze = NSMenuItem(title: "Snooze Popups", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for choice in PopupCenter.snoozeChoices {
                let choiceItem = item(choice.minutes < 60 ? "\(choice.minutes) minutes"
                                      : choice.minutes == 60 ? "1 hour" : "\(choice.minutes / 60) hours",
                                      #selector(snoozePopups(_:)))
                choiceItem.tag = choice.minutes
                submenu.addItem(choiceItem)
            }
            snooze.submenu = submenu
            menu.addItem(snooze)
        }
        if !popups.cards.isEmpty { menu.addItem(item("Dismiss All Popups", #selector(dismissPopups))) }
        menu.addItem(.separator())
        menu.addItem(item("Preferences…", #selector(openPreferences), key: ","))
        menu.addItem(item("Quit Git Assist", #selector(quit), key: "q"))
    }

    private func statusLine() -> String {
        var parts: [String] = []
        switch store.status {
        case .syncing: parts.append("Syncing…")
        case .error(let message): parts.append("Error: \(truncate(message, 60))")
        case .idle: if let last = store.lastSync { parts.append("Synced \(Format.age(last))") }
        }
        if let progress = store.backfillProgress { parts.append("history \(progress.done)/\(progress.total)") }
        return parts.joined(separator: " · ")
    }

    private func truncate(_ s: String, _ n: Int) -> String { s.count > n ? String(s.prefix(n - 1)) + "…" : s }

    private func header(_ title: String) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        menuItem.isEnabled = false
        return menuItem
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: key)
        menuItem.target = self
        return menuItem
    }

    // MARK: - App menu (so ⌘C/⌘V/⌘W work in the windows)

    private func setUpMainMenu() {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(item("Preferences…", #selector(openPreferences), key: ","))
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Git Assist", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(item("Quit Git Assist", #selector(quit), key: "q"))
        main.addItem(submenu("Git Assist", appMenu))

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenu("Edit", edit))

        let view = NSMenu(title: "View")
        view.addItem(item("Sync Now", #selector(syncNow), key: "r"))
        main.addItem(submenu("View", view))

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        main.addItem(submenu("Window", window))

        NSApp.mainMenu = main
    }

    private func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        menu.title = title
        menuItem.submenu = menu
        return menuItem
    }

    // MARK: - Actions

    @objc private func openMain() { mainWindow.show() }
    @objc private func openPreferences() { preferences.show() }
    @objc private func syncNow() { store.syncNow() }
    @objc private func dismissPopups() { popups.dismissAll() }
    @objc private func resumePopups() { popups.resume() }
    @objc private func snoozePopups(_ sender: NSMenuItem) { popups.snooze(minutes: sender.tag) }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func openURL(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [String], pair.count == 2,
              let url = URL(string: pair[1]) else { return }
        NSWorkspace.shared.open(url)
        store.markSeen(pair[0])
    }
}
