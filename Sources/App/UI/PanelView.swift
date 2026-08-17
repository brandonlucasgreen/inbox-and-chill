import SwiftData
import SwiftUI

/// The menu bar panel. M0 stub: functional list + triage verbs, minimal
/// styling. Fleshed out in the UI wave (sections, keyboard nav, filters).
struct PanelView: View {
    @Environment(AppState.self) private var appState
    @Query(sort: \Item.occurredAt, order: .reverse) private var items: [Item]

    private var pinned: [Item] { items.filter { $0.isPinned && !$0.isDone } }
    private var active: [Item] {
        items.filter { $0.isActive && !$0.isPinned }
    }
    private var snoozed: [Item] { items.filter(\.isSnoozed) }

    var body: some View {
        VStack(spacing: 0) {
            List {
                if !pinned.isEmpty {
                    Section("Pinned") {
                        ForEach(pinned) { ItemRow(item: $0) }
                    }
                }
                ForEach(groupedBySource(active), id: \.0) { kind, group in
                    Section(kind.capitalized) {
                        ForEach(group) { ItemRow(item: $0) }
                    }
                }
                if !snoozed.isEmpty {
                    Section("Snoozed") {
                        ForEach(snoozed) { ItemRow(item: $0) }
                    }
                }
            }
            .listStyle(.sidebar)
            footer
        }
        .frame(width: 380, height: 480)
    }

    private var footer: some View {
        HStack {
            Button("Refresh") {
                Task { await appState.engine.refreshNow() }
            }
            Spacer()
            SettingsLink { Image(systemName: "gearshape") }
        }
        .padding(8)
    }

    private func groupedBySource(_ items: [Item]) -> [(String, [Item])] {
        Dictionary(grouping: items, by: \.sourceKind)
            .sorted { $0.key < $1.key }
    }
}

struct ItemRow: View {
    @Environment(AppState.self) private var appState
    let item: Item

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.title).lineLimit(1)
            if let snippet = item.snippet {
                Text(snippet).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { appState.open(item) }
        .contextMenu {
            Button("Open") { appState.open(item) }
            Button("Done") { appState.markDone(item) }
            Button("Snooze 3 Hours") {
                appState.snooze(item, until: .now.addingTimeInterval(3 * 3600))
            }
            Button(item.isPinned ? "Unpin" : "Pin") {
                appState.togglePin(item)
            }
        }
    }
}
