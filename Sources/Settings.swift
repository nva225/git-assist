import AppKit
import Carbon.HIToolbox
import Combine

enum ListMode: String, CaseIterable, Codable, Identifiable {
    case open, all, recent
    var id: String { rawValue }
    var title: String {
        switch self {
        case .open: "Open"
        case .all: "All"
        case .recent: "Recent"
        }
    }
    /// The next mode over, wrapping; Tab and ⇧Tab walk the toggle with this.
    func step(_ delta: Int) -> ListMode {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + delta + all.count) % all.count]
    }
}

struct CategoryPrefs: Codable, Equatable {
    var enabled = true
    var autoHide = false
}

/// User preferences, persisted to UserDefaults as JSON so every value round-trips the same way.
final class Settings: ObservableObject {
    static let shared = Settings()

    @Published var repos: [String] { didSet { store(repos, "repos") } }
    /// The team. Fills "Other team PRs" in All and Recent modes and ranks author suggestions; empty means everyone.
    @Published var authors: [String] { didSet { store(authors, "authors") } }
    @Published var authorsSeeded: Bool { didSet { store(authorsSeeded, "authorsSeeded") } }
    @Published var pollSeconds: Int { didSet { store(pollSeconds, "pollSeconds") } }
    @Published var showDrafts: Bool { didSet { store(showDrafts, "showDrafts") } }
    @Published var listMode: ListMode { didSet { store(listMode, "listMode") } }
    /// Closed and merged rows per section in All mode, under the open ones.
    @Published var recentLimit: Int { didSet { store(recentLimit, "recentLimit") } }

    @Published var hotkeyKeyCode: UInt32 { didSet { store(hotkeyKeyCode, "hotkeyKeyCode") } }
    @Published var hotkeyModifiers: UInt32 { didSet { store(hotkeyModifiers, "hotkeyModifiers") } }
    @Published var hotkeyDisplay: String { didSet { store(hotkeyDisplay, "hotkeyDisplay") } }

    @Published var categories: [String: CategoryPrefs] { didSet { store(categories, "categories") } }
    @Published var fadeDelay: Double { didSet { store(fadeDelay, "fadeDelay") } }
    @Published var fadedOpacity: Double { didSet { store(fadedOpacity, "fadedOpacity") } }
    @Published var autoHideDelay: Double { didSet { store(autoHideDelay, "autoHideDelay") } }
    @Published var playSound: Bool { didSet { store(playSound, "playSound") } }

    /// Review deadline, in business days (weekends don't count) from when you were requested.
    @Published var warnDays: Double { didSet { store(warnDays, "warnDays") } }
    @Published var dueDays: Double { didSet { store(dueDays, "dueDays") } }

    private init() {
        // Empty until chosen: the main window opens with a picker on first launch.
        repos = Self.load("repos", [])
        authors = Self.load("authors", [])
        authorsSeeded = Self.load("authorsSeeded", false)
        pollSeconds = Self.load("pollSeconds", 60)
        showDrafts = Self.load("showDrafts", false)
        listMode = Self.load("listMode", .open)
        recentLimit = Self.load("recentLimit", 10)
        hotkeyKeyCode = Self.load("hotkeyKeyCode", UInt32(kVK_ANSI_G))
        hotkeyModifiers = Self.load("hotkeyModifiers", UInt32(controlKey | optionKey))
        hotkeyDisplay = Self.load("hotkeyDisplay", "⌃⌥G")
        categories = Self.load("categories", [:])
        fadeDelay = Self.load("fadeDelay", 8)
        fadedOpacity = Self.load("fadedOpacity", 0.35)
        autoHideDelay = Self.load("autoHideDelay", 12)
        playSound = Self.load("playSound", false)
        warnDays = Self.load("warnDays", 1)
        dueDays = Self.load("dueDays", 2)
    }

    func prefs(_ category: PopupCategory) -> CategoryPrefs {
        categories[category.rawValue] ?? CategoryPrefs()
    }

    func setPrefs(_ category: PopupCategory, _ prefs: CategoryPrefs) {
        categories[category.rawValue] = prefs
    }

    func isTeamAuthor(_ login: String) -> Bool {
        authors.isEmpty || authors.contains { $0.sameLogin(login) }
    }

    private static func load<T: Decodable>(_ key: String, _ fallback: T) -> T {
        guard let data = UserDefaults.standard.data(forKey: key),
              let value = try? JSONDecoder().decode(T.self, from: data) else { return fallback }
        return value
    }

    private func store<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
