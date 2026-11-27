import SwiftUI

struct MirroredAppsPane: View {
    @StateObject private var store = BlockedApps.shared
    @State private var query: String = ""
    @State private var confirmClearSeen: Bool = false

    var body: some View {
        PaneContainer("Mirrored Apps",
                      subtitle: "Turn off any app you don't want mirrored to this Mac.") {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    controlsCard
                    listArea
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 18)
            }
        }
        .confirmationDialog(
            "Clear seen apps list?",
            isPresented: $confirmClearSeen,
            titleVisibility: .visible
        ) {
            Button("Clear seen", role: .destructive) { store.clearSeen() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Apps will reappear as they send new notifications. Your existing mute choices remain saved.")
        }
    }

    private var controlsCard: some View {
        Card {
            HStack(spacing: 10) {
                TextField("Search app name or package", text: $query)
                    .textFieldStyle(.roundedBorder)
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Clear search")
                    .accessibilityLabel("Clear search")
                }
                if !store.seen.isEmpty {
                    Button("Clear seen", role: .destructive) { confirmClearSeen = true }
                }
            }
        }
    }

    @ViewBuilder
    private var listArea: some View {
        if store.seen.isEmpty {
            ContentUnavailableView(
                "No apps seen yet",
                systemImage: "bell.slash",
                description: Text("Apps appear here the first time they send a notification from your phone.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.top, 28)
        } else if filtered.isEmpty {
            ContentUnavailableView(
                "No matches",
                systemImage: "magnifyingglass",
                description: Text("No apps match \"\(query)\".")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.top, 28)
        } else {
            Card {
                VStack(spacing: 0) {
                    ForEach(Array(filtered.enumerated()), id: \.element.id) { idx, app in
                        appRow(app)
                        if idx < filtered.count - 1 { Divider() }
                    }
                }
            }
        }
    }

    private func appRow(_ app: BlockedApps.SeenApp) -> some View {
        Toggle(isOn: bindingFor(app)) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor.opacity(0.14))
                    .frame(width: 32, height: 32)
                    .overlay(
                        Text(app.name.prefix(1).uppercased())
                            .font(.headline)
                            .foregroundStyle(Color.accentColor)
                    )
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name).font(.body)
                    Text(app.pkg).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .toggleStyle(.switch)
        .padding(.vertical, 6)
    }

    private var filtered: [BlockedApps.SeenApp] {
        let base = store.seen.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        guard !query.isEmpty else { return base }
        let q = query.lowercased()
        return base.filter { $0.name.lowercased().contains(q) || $0.pkg.lowercased().contains(q) }
    }

    private func bindingFor(_ app: BlockedApps.SeenApp) -> Binding<Bool> {
        Binding(
            get: { !store.isBlocked(app.pkg) },
            set: { enabled in store.setBlocked(app.pkg, blocked: !enabled) }
        )
    }
}
