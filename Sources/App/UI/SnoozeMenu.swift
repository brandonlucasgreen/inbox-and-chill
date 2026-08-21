import SwiftUI

/// The locked snooze presets (§2.1.5). All dates come from
/// `Calendar.current`, so DST and locale week starts behave.
enum SnoozePreset: String, CaseIterable, Identifiable, Sendable {
    case laterToday
    case thisEvening
    case tomorrowMorning
    case nextMonday

    var id: String { rawValue }

    var title: String {
        switch self {
        case .laterToday: return "Later Today"
        case .thisEvening: return "This Evening"
        case .tomorrowMorning: return "Tomorrow Morning"
        case .nextMonday: return "Next Monday"
        }
    }

    var detail: String {
        switch self {
        case .laterToday: return "+3h"
        case .thisEvening: return "6pm"
        case .tomorrowMorning: return "9am"
        case .nextMonday: return "9am"
        }
    }

    var systemImage: String {
        switch self {
        case .laterToday: return "clock"
        case .thisEvening: return "moon"
        case .tomorrowMorning: return "sunrise"
        case .nextMonday: return "calendar"
        }
    }

    func date(from now: Date = .now, calendar: Calendar = .current) -> Date {
        switch self {
        case .laterToday:
            return now.addingTimeInterval(3 * 3600)
        case .thisEvening:
            let evening = calendar.date(
                bySettingHour: 18, minute: 0, second: 0, of: now)
            if let evening, evening > now { return evening }
            return now.addingTimeInterval(4 * 3600)
        case .tomorrowMorning:
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: now)
                ?? now.addingTimeInterval(86_400)
            return calendar.date(
                bySettingHour: 9, minute: 0, second: 0, of: tomorrow)
                ?? tomorrow
        case .nextMonday:
            var components = DateComponents()
            components.weekday = 2  // Monday, Gregorian
            components.hour = 9
            components.minute = 0
            let startOfTomorrow = calendar.date(
                byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
                ?? now
            return calendar.nextDate(
                after: startOfTomorrow, matching: components,
                matchingPolicy: .nextTime)
                ?? now.addingTimeInterval(7 * 86_400)
        }
    }
}

/// The hover row's "Snooze ▾" control. Presets apply immediately; "Pick
/// Date…" hands off to the row's popover.
struct SnoozeMenu: View {
    var apply: (Date) -> Void
    var pickDate: () -> Void

    var body: some View {
        Menu {
            ForEach(SnoozePreset.allCases) { preset in
                Button("\(preset.title) (\(preset.detail))") {
                    apply(preset.date())
                }
            }
            Divider()
            Button("Pick Date…") { pickDate() }
        } label: {
            HStack(spacing: 2) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 11))
                KeyCap("S")
            }
            .padding(.horizontal, 2)
            .frame(height: 22)
            .contentShape(.rect)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Snooze (S)")
        .accessibilityLabel("Snooze")
    }
}

/// Popover shown by the S key and by "Pick Date…": the same four presets as
/// a keyboard-reachable list, plus a date picker for anything else.
struct SnoozePopover: View {
    let title: String
    var apply: (Date) -> Void
    @State private var customDate = SnoozePreset.tomorrowMorning.date()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Snooze \(title)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            ForEach(SnoozePreset.allCases) { preset in
                Button {
                    apply(preset.date())
                } label: {
                    Label {
                        HStack {
                            Text(preset.title)
                            Spacer(minLength: 8)
                            Text(PanelFormat.until(preset.date()))
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: preset.systemImage)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .help("Snooze until \(PanelFormat.full(preset.date()))")
            }
            Divider()
            DatePicker(
                "Pick Date", selection: $customDate,
                displayedComponents: [.date, .hourAndMinute])
                .datePickerStyle(.compact)
                .labelsHidden()
            Button("Snooze Until Then") { apply(customDate) }
                .help("Snooze until \(PanelFormat.full(customDate))")
        }
        .padding(12)
        .frame(width: 260)
    }
}
