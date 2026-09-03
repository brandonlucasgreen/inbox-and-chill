import SwiftUI

/// What marking currently means, while any row is marked.
///
/// This bar is what makes bulk mode legible, and that is load-bearing rather
/// than decorative: the keyboard verbs act on the marks while it is up, so it
/// has to name the count, the verbs and the way out. Without it, E would act
/// on invisible state — which is the exact objection that kept the triage
/// keys away from the marks in the first build.
///
/// Its own view, rather than a `@ViewBuilder` property on `PanelView`, so
/// that it — and not the panel — is what re-renders when a mark toggles.
struct MarksBar: View {
    /// The snooze popover's owner when the marks, not a row, are the target.
    static let snoozeTarget = "marks:snooze"

    @Environment(AppState.self) private var appState
    @Environment(PanelMarks.self) private var marks
    /// Every item in the queue; the bar filters it to the marked rows itself.
    let items: [Item]
    @Binding var snoozeTargetUID: String?
    var onGroup: () -> Void

    var body: some View {
        let live = marks.live(in: items)
        if !live.isEmpty {
            let allSeen = live.allSatisfy(\.isSeen)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    MarkBox(isMarked: true, size: 12)
                    Text(
                        live.count == 1
                            ? "1 row marked" : "\(live.count) rows marked")
                        .font(.system(size: 11, weight: .semibold))
                    Spacer(minLength: 0)
                    bulkButton("Dismiss", "E") {
                        appState.markDone(live)
                        marks.clear()
                    }
                    bulkButton("Snooze", "S") {
                        snoozeTargetUID = Self.snoozeTarget
                    }
                    bulkButton(allSeen ? "Unread" : "Read", "U") {
                        appState.setSeen(live, seen: !allSeen)
                        marks.clear()
                    }
                    bulkButton("Group", "G") { onGroup() }
                    Button {
                        marks.clear()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                            .frame(width: 18, height: 18)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Clear marks (Esc)")
                    .accessibilityLabel("Clear marks")
                }
                Text("These keys act on all \(live.count) — Space or ⇧↑↓ mark more, Esc clears.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color.accentColor.opacity(0.10))
            .popover(isPresented: snoozeBinding, arrowEdge: .top) {
                SnoozePopover(title: "\(live.count) marked rows") { date in
                    snoozeTargetUID = nil
                    appState.snooze(live, until: date)
                    marks.clear()
                }
            }
            Divider()
        }
    }

    private func bulkButton(
        _ title: String, _ key: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(title).font(.system(size: 11))
                KeyCap(key)
            }
            .padding(.horizontal, 3)
            .frame(height: 20)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("\(title) every marked row (\(key))")
    }

    private var snoozeBinding: Binding<Bool> {
        Binding(
            get: { snoozeTargetUID == Self.snoozeTarget },
            set: { if !$0 { snoozeTargetUID = nil } })
    }
}
