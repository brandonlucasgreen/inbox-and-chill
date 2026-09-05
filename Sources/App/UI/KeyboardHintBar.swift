import SwiftUI

/// The keyboard verbs, said once to someone who has never seen them.
///
/// The panel is keyboard-first and nothing on it says so: the hover buttons
/// show on a row you point at, and the footer's tooltips need a hover too.
/// A first-time user reads the queue with the mouse and never learns that
/// `E` exists. This bar names the five keys worth knowing on a newcomer's
/// first few opens, and goes away for good when dismissed or after those
/// opens — the same lesson as `MarksBar`: a key with no visible affordance
/// is a key nobody has (CLAUDE.md, "a keyboard-only gesture has no
/// discoverability at all").
///
/// The policy is pure so the count and the dismissal are pinned by tests.
enum KeyboardHints {
    /// How many panel opens with a non-empty queue the bar shows for.
    static let showForOpens = 3
    static let opensKey = "panel.keyHints.opens"
    static let dismissedKey = "panel.keyHints.dismissed"

    /// Shown while the queue has rows, the user has not dismissed it, and
    /// the panel has opened with rows fewer than `showForOpens` times.
    nonisolated static func shouldShow(
        opensSoFar: Int, dismissed: Bool, queueIsEmpty: Bool
    ) -> Bool {
        !dismissed && !queueIsEmpty && opensSoFar <= showForOpens
    }

    /// The bar's one sentence. Keys named in the order a triage happens.
    static let hints: [(key: String, verb: String)] = [
        ("↑↓", "move"), ("⏎", "open"), ("E", "done"), ("S", "snooze"), ("D", "whole message"),
    ]
}

struct KeyboardHintBar: View {
    var onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "keyboard")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("It's all on the keyboard")
                    .font(.system(size: 11, weight: .semibold))
                Spacer(minLength: 0)
                Button("Got it") { onDismiss() }
                    .font(.system(size: 11))
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Hide these tips")
            }
            HStack(spacing: 10) {
                ForEach(KeyboardHints.hints, id: \.key) { hint in
                    HStack(spacing: 4) {
                        Text(hint.key)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(
                                RoundedRectangle(cornerRadius: 3)
                                    .strokeBorder(Color.primary.opacity(0.18)))
                        Text(hint.verb)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.accentColor.opacity(0.10))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Keyboard tips: arrows move, return opens, E done, S snooze, D shows the whole message")
    }
}
