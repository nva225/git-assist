import AppKit
import SwiftUI

@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    let model: MainViewModel
    private let store: PRStore
    private let openPreferences: () -> Void
    private var window: NSWindow?

    init(store: PRStore, openPreferences: @escaping () -> Void) {
        self.store = store
        self.openPreferences = openPreferences
        model = MainViewModel(store: store)
        super.init()
        model.onClose = { [weak self] in self?.window?.orderOut(nil) }
    }

    var isKey: Bool { (window?.isKeyWindow ?? false) && NSApp.isActive }

    func toggle() {
        if isKey { window?.orderOut(nil) } else { show() }
    }

    func show() {
        // Ask before activating: once we're frontmost, the "focused" screen is wherever our window was.
        let target = PopupCenter.focusedScreen()
        let window = self.window ?? makeWindow()
        if window.screen != target {
            let visible = target.visibleFrame
            let size = window.frame.size
            window.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2,
                                          y: visible.midY - size.height / 2 + visible.height * 0.05))
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        model.focusSearch(selectAll: true)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 660),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Git Assist"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: MainView(model: model, store: store,
                                                              openPreferences: openPreferences))
        window.center()
        window.setFrameAutosaveName("GitAssistMain")
        self.window = window
        return window
    }
}

@MainActor
final class PreferencesWindowController {
    private var window: NSWindow?
    private let store: PRStore
    private let popups: PopupCenter

    init(store: PRStore, popups: PopupCenter) {
        self.store = store
        self.popups = popups
    }

    func show() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Git Assist Preferences"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: PreferencesView(store: store, popups: popups))
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
