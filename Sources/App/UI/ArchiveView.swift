import AppKit
import SwiftData
import SwiftUI

/// In-panel archive: done items from the last 90 days (§2.1.6), searchable,
/// each restorable back into the active queue.
///
/// It owns its own query rather than being handed the panel's. The archive
/// is where nearly every item ends up — over a thousand after two days of
/// real use — and the panel was fetching all of them on every render just to
/// filter them back out. Querying here means they are fetched only while
/// this view is actually on screen.
struct ArchiveView: View {
    @Query(
        filter: #Predicate<Item> { $0.doneAt != nil },
        sort: \Item.doneAt, order: .reverse)
    private var items: [Item]

    let index: SourceIndex
    var restore: (Item) -> Void
    var complete: (Item) -> Void
    var open: (Item) -> Void
    var onClose: () -> Void

    @State private var search = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if matches.isEmpty {
                VStack(spacing: 4) {
                    Spacer()
                    Image(systemName: "archivebox")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                    Text(
                        search.isEmpty
                            ? "Nothing archived yet"
                            : "No archived items match “\(search)”")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(matches) { item in
                            ArchiveRow(
                                item: item, display: index.display(for: item),
                                restore: { restore(item) },
                                complete: { complete(item) },
                                open: { open(item) })
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Button(action: onClose) {
                Label("Queue", systemImage: "chevron.left")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .help("Back to the queue")
            .accessibilityLabel("Back to the queue")

            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                TextField("Search archive", text: $search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .accessibilityLabel("Search archive")
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(.quaternary))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    /// Retention is enforced here as well as by the purge: an item that is
    /// past the cutoff but not yet swept shouldn't reappear in the archive.
    private var retained: [Item] {
        let cutoff = TriagePolicy.purgeCutoff()
        return items.filter { ($0.doneAt ?? .distantPast) >= cutoff }
    }

    private var matches: [Item] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return retained }
        return retained.filter { item in
            [
                item.title, item.snippet ?? "", item.actorName ?? "",
                index.display(for: item).name,
            ]
            .contains { $0.lowercased().contains(query) }
        }
    }
}

private struct ArchiveRow: View {
    let item: Item
    let display: SourceDisplay
    var restore: () -> Void
    var complete: () -> Void
    var open: () -> Void

    @Environment(AppState.self) private var appState
    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: display.systemImage)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.system(size: 12)).lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button("Restore", action: restore)
                .font(.system(size: 11))
                .buttonStyle(.borderless)
                .opacity(isHovering ? 1 : 0.55)
                .help("Restore to the active queue")
                .accessibilityLabel("Restore \(item.title)")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isHovering ? AnyShapeStyle(.quaternary)
                    : AnyShapeStyle(Color.clear)))
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Open", action: open)
            Button("Restore", action: restore)
            // A dismissed reminder is still an open task, so finishing it from
            // the archive has to be possible — otherwise pressing E costs you
            // the ability to ever tick it off from this app.
            if appState.canComplete(item) {
                Button(appState.completeVerb(for: item).menu, action: complete)
            }
            Button("Copy") {
                PanelPasteboard.copy(title: item.title, url: item.url)
            }
        }
    }

    private var subtitle: String {
        var text = display.name
        if let done = item.doneAt {
            text += " · done \(PanelFormat.relative(done)) ago"
        }
        switch item.doneReason {
        case Store.DoneReason.remote: text += " · cleared by source"
        // The distinction Brandon asked for, made visible: dismissing a
        // reminder leaves it open in Reminders, and the archive is the only
        // place that can still say which of the two happened.
        case Store.DoneReason.completed: text += " · completed"
        default: break
        }
        return text
    }
}
