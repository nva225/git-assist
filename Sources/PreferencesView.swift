import AppKit
import ServiceManagement
import SwiftUI

struct PreferencesView: View {
    @ObservedObject var store: PRStore
    let popups: PopupCenter

    var body: some View {
        TabView {
            GeneralPane(store: store)
                .tabItem { Label("General", systemImage: "gearshape") }
            TeamPane(store: store)
                .tabItem { Label("Team", systemImage: "person.3") }
            PopupsPane(popups: popups)
                .tabItem { Label("Popups", systemImage: "rectangle.stack") }
            DeadlinePane()
                .tabItem { Label("Deadline", systemImage: "hourglass") }
        }
        .frame(width: 560, height: 520)
    }
}

private struct GeneralPane: View {
    @ObservedObject var store: PRStore
    @ObservedObject var settings = Settings.shared
    @State private var newRepo = ""
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var confirmReset = false

    var body: some View {
        Form {
            Section("Repositories") {
                ForEach(settings.repos, id: \.self) { repo in
                    HStack {
                        Text(repo).font(.system(.body, design: .monospaced))
                        Spacer()
                        Button(role: .destructive) {
                            settings.repos.removeAll { $0 == repo }
                        } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("owner/name", text: $newRepo)
                        .onSubmit(addRepo)
                    Button("Add", action: addRepo)
                        .disabled(RepoRef(newRepo) == nil)
                }
            }
            Section("Sync") {
                Picker("Check GitHub every", selection: $settings.pollSeconds) {
                    Text("30 seconds").tag(30)
                    Text("1 minute").tag(60)
                    Text("2 minutes").tag(120)
                    Text("5 minutes").tag(300)
                }
                Picker("All mode shows", selection: $settings.recentLimit) {
                    ForEach(5...20, id: \.self) { Text("\($0) merged / closed per section").tag($0) }
                }
                Toggle("Include drafts in the default list", isOn: $settings.showDrafts)
                LabeledContent("Signed in as") {
                    Text(store.viewer ?? "—").foregroundStyle(.secondary)
                }
                LabeledContent("Cache") {
                    HStack {
                        Text("\(store.prs.count.formatted()) PRs").foregroundStyle(.secondary)
                        Button("Rebuild…") { confirmReset = true }
                    }
                }
            }
            Section("App") {
                LabeledContent("Open window shortcut") { HotkeyRecorder() }
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Throw away the local cache and re-download everything?", isPresented: $confirmReset) {
            Button("Rebuild Cache", role: .destructive) { store.resetCache() }
        } message: {
            Text("History indexing starts over and takes a few minutes. Preferences are kept.")
        }
    }

    private func addRepo() {
        guard let repo = RepoRef(newRepo), !settings.repos.contains(repo.full) else { return }
        settings.repos.append(repo.full)
        newRepo = ""
        store.syncNow()
    }
}

private struct TeamPane: View {
    @ObservedObject var store: PRStore
    @ObservedObject var settings = Settings.shared
    @State private var newAuthor = ""

    var body: some View {
        Form {
            Section {
                if settings.authors.isEmpty {
                    Text("No team set: All and Recent list every author under Other team PRs.")
                        .foregroundStyle(.secondary)
                }
                ForEach(settings.authors, id: \.self) { author in
                    HStack {
                        Text(author)
                        if let count = recentCounts[author.lowercased()] {
                            Text("\(count) PRs in 90 days").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            settings.authors.removeAll { $0 == author }
                        } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("GitHub login", text: $newAuthor)
                        .onSubmit { add(newAuthor) }
                    Button("Add") { add(newAuthor) }
                        .disabled(newAuthor.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Team authors")
            } footer: {
                Text("Fills \"Other team PRs\" in All and Recent and comes first in author: suggestions. PRs that involve you always show.")
            }
            if !suggested.isEmpty {
                Section("Recent authors not on the team") {
                    ForEach(suggested, id: \.0) { login, count in
                        HStack {
                            Text(login)
                            Text("\(count) PRs").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button { add(login) } label: { Image(systemName: "plus.circle") }
                                .buttonStyle(.borderless)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var recentCounts: [String: Int] {
        let since = Date().addingTimeInterval(-90 * 86_400)
        var counts: [String: Int] = [:]
        for pr in store.prs.values where pr.createdAt > since { counts[pr.author.lowercased(), default: 0] += 1 }
        return counts
    }

    private var suggested: [(String, Int)] {
        let since = Date().addingTimeInterval(-90 * 86_400)
        var counts: [String: (String, Int)] = [:]
        for pr in store.prs.values where pr.createdAt > since && pr.authorIsBot != true && pr.author != "ghost" {
            let key = pr.author.lowercased()
            counts[key] = (pr.author, (counts[key]?.1 ?? 0) + 1)
        }
        return counts.values
            .filter { login, _ in !settings.authors.contains { $0.sameLogin(login) } }
            .sorted { $0.1 > $1.1 }
    }

    private func add(_ login: String) {
        let trimmed = login.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "@", with: "")
        guard !trimmed.isEmpty, !settings.authors.contains(where: { $0.sameLogin(trimmed) }) else { return }
        settings.authors.append(trimmed)
        settings.authors.sort { $0.lowercased() < $1.lowercased() }
        newAuthor = ""
    }
}

private struct PopupsPane: View {
    let popups: PopupCenter
    @ObservedObject var settings = Settings.shared

    var body: some View {
        Form {
            Section("Show a popup for") {
                ForEach(PopupCategory.allCases) { category in
                    let prefs = Binding(get: { settings.prefs(category) }, set: { settings.setPrefs(category, $0) })
                    HStack(alignment: .firstTextBaseline) {
                        Toggle(isOn: prefs.enabled) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(category.title)
                                Text(category.detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Toggle("Auto-hide", isOn: prefs.autoHide)
                            .toggleStyle(.checkbox)
                            .disabled(!prefs.wrappedValue.enabled)
                    }
                }
            }
            Section("Behavior") {
                LabeledContent("Fade and stack after") {
                    Stepper("\(Int(settings.fadeDelay)) seconds", value: $settings.fadeDelay, in: 2...60, step: 1)
                }
                LabeledContent("Faded opacity") {
                    Slider(value: $settings.fadedOpacity, in: 0.1...0.9)
                        .frame(width: 180)
                }
                LabeledContent("Auto-hide after") {
                    Stepper("\(Int(settings.autoHideDelay)) seconds", value: $settings.autoHideDelay, in: 3...120, step: 1)
                }
                Toggle("Play a sound", isOn: $settings.playSound)
            }
            Section {
                HStack {
                    Button("Show Test Popups") { popups.post(TestPopups.make()) }
                    Button("Dismiss All") { popups.dismissAll() }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct DeadlinePane: View {
    @ObservedObject var settings = Settings.shared

    var body: some View {
        Form {
            Section {
                LabeledContent("Warn after") {
                    Stepper(days(settings.warnDays), value: $settings.warnDays, in: 0.25...10, step: 0.25)
                }
                LabeledContent("Due after") {
                    Stepper(days(settings.dueDays), value: $settings.dueDays, in: 0.5...10, step: 0.25)
                }
            } header: {
                Text("Review deadline")
            } footer: {
                Text("Counted in business days from when you were requested (or re-requested, or the PR left draft). Saturdays and Sundays don't count. Commenting or reviewing stops the clock.")
            }
        }
        .formStyle(.grouped)
    }

    private func days(_ value: Double) -> String {
        let text = value.formatted(.number.precision(.fractionLength(0...2)))
        return value == 1 ? "1 business day" : "\(text) business days"
    }
}

private struct HotkeyRecorder: View {
    @ObservedObject var settings = Settings.shared
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button(recording ? "Press a shortcut…" : settings.hotkeyDisplay) {
            recording ? stop() : start()
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {  // Esc cancels
                stop()
                return nil
            }
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard !flags.isDisjoint(with: [.command, .option, .control]),
                  let key = event.charactersIgnoringModifiers, !key.isEmpty else { return nil }
            settings.hotkeyKeyCode = UInt32(event.keyCode)
            settings.hotkeyModifiers = GlobalHotkey.carbonModifiers(flags)
            settings.hotkeyDisplay = GlobalHotkey.display(flags, key: key)
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
    }
}

enum TestPopups {
    static func make() -> [ActivityEvent] {
        let now = Date()
        func event(_ kind: ActivityKind, _ pr: Int, _ title: String, _ actor: String, _ snippet: String, ago: TimeInterval)
            -> ActivityEvent {
            ActivityEvent(id: "test-\(kind.rawValue)-\(UUID().uuidString)", kind: kind, prKey: "test#\(pr)",
                          prNumber: pr, prTitle: title, prURL: "https://github.com", actor: actor,
                          snippet: snippet, url: "https://github.com", date: now.addingTimeInterval(-ago))
        }
        return [
            event(.approved, 9001, "Example: tighten the upload retry loop", "octocat", "LGTM, nice cleanup", ago: 20),
            event(.commented, 9001, "Example: tighten the upload retry loop", "hubot", "Could we cap retries at 3?", ago: 60),
            event(.reviewRequested, 9002, "Example: migrate audit trigger", "monalisa", "", ago: 5),
            event(.overdue, 9003, "Example: consolidate the two Next.js apps", "octocat", "overdue 2h · requested by monalisa", ago: 0),
        ]
    }
}
