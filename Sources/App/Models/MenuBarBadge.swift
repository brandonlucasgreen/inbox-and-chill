import Foundation

/// What the menu bar shows next to the icon.
///
/// Two independent counters, either of which can be switched off in Settings:
/// the **total** still in the queue, and the **high-signal** subset — the
/// things where someone specifically wants you. Shown together they read
/// `6 • 2`.
///
/// High signal is always a subset of the total, so a zero total means a zero
/// high signal, and both mean a bare icon. That is the whole point of the
/// queue: empty looks empty.
struct MenuBarBadge: Equatable, Sendable {
    var showsTotal: Bool
    var showsHighSignal: Bool

    static let `default` = MenuBarBadge(showsTotal: true, showsHighSignal: true)

    /// The badge string, or `nil` for a clean icon.
    ///
    /// A zero counter is dropped rather than printed: with both switched on
    /// and nothing high-signal waiting, `6` says more than `6 • 0`.
    func text(total: Int, highSignal: Int) -> String? {
        let leading = showsTotal && total > 0 ? "\(total)" : nil
        let trailing = showsHighSignal && highSignal > 0 ? "\(highSignal)" : nil
        switch (leading, trailing) {
        case let (lead?, trail?): return "\(lead) • \(trail)"
        case let (lead?, nil): return lead
        case let (nil, trail?): return trail
        case (nil, nil): return nil
        }
    }
}
