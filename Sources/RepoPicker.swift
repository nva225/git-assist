import SwiftUI

/// First-run choice of which repositories to watch, suggested from where you've recently worked.
struct RepoPicker: View {
    @ObservedObject var store: PRStore
    @ObservedObject var settings = Settings.shared
    @State private var suggestions: [String] = []
    @State private var chosen: Set<String> = []
    @State private var loading = true
    @State private var error: String?
    @State private var typed = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Which repositories should Git Assist watch?").font(.headline)
            Text("Suggested from the repos you've recently opened PRs in, reviewed, or pushed to. You can change this later in Preferences → General.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if loading {
                ProgressView().controlSize(.small)
            } else if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(suggestions, id: \.self) { repo in
                    Toggle(isOn: binding(repo)) {
                        Text(repo).font(.system(.body, design: .monospaced))
                    }
                    .toggleStyle(.checkbox)
                }
            }

            HStack {
                TextField("Another repo: owner/name", text: $typed)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addTyped)
                Button("Add", action: addTyped).disabled(RepoRef(typed) == nil)
            }

            HStack {
                Spacer()
                Button(chosen.count == 1 ? "Watch 1 repository" : "Watch \(chosen.count) repositories") {
                    settings.repos = suggestions.filter(chosen.contains)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(chosen.isEmpty)
            }
        }
        .frame(maxWidth: 460, alignment: .leading)
        .task { await load() }
    }

    private func binding(_ repo: String) -> Binding<Bool> {
        Binding(get: { chosen.contains(repo) },
                set: { on in if on { chosen.insert(repo) } else { chosen.remove(repo) } })
    }

    private func addTyped() {
        guard let repo = RepoRef(typed)?.full else { return }
        if !suggestions.contains(repo) { suggestions.insert(repo, at: 0) }
        chosen.insert(repo)
        typed = ""
    }

    private func load() async {
        defer { loading = false }
        do {
            let found = try await store.suggestedRepos()
            suggestions = (suggestions + found).reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
            // The most recent one is usually the right one; preselect it so it's a single click.
            if chosen.isEmpty, let first = found.first { chosen.insert(first) }
        } catch {
            self.error = "Couldn't load suggestions: \(error.localizedDescription). Type a repo below."
        }
    }
}
