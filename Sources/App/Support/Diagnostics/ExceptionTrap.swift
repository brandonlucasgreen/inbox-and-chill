import Foundation

/// An Objective-C exception that killed the app.
struct UncaughtException: Codable, Sendable, Equatable {
    var date: Date
    var name: String
    var reason: String
    var callStack: [String]
}

/// Catches the one thing the OS crash report describes poorly.
///
/// A `.ips` for an Objective-C exception shows the abort path — `objc_exception_throw`,
/// `__cxa_throw`, `abort` — and the *reason* string, the sentence that names
/// the bug, is not reliably in it. `NSSetUncaughtExceptionHandler` runs while
/// that string still exists.
///
/// This app raises them for real rather than hypothetically: `PanelToggler`
/// reaches a private `statusItem` selector on `NSStatusBarWindow` by KVC, and
/// `AppState` does key-path work against AppKit. Both are `NSException`
/// territory, and both are guarded — but a guard that is wrong once is exactly
/// the case worth having the reason for.
///
/// This is **not** a crash handler. It does not catch signals, Swift runtime
/// traps (`fatalError`, a nil force-unwrap, an out-of-range index) or memory
/// faults — the OS report covers all of those, better than an in-process
/// handler could. It fills one gap, and the harvester still does the work.
enum ExceptionTrap {
    static var defaultURL: URL {
        URL.applicationSupportDirectory
            .appending(path: "InboxAndChill/last-exception.json")
    }

    /// Installs the handler, chaining to whatever was there before.
    ///
    /// Chaining matters: Sparkle and AppKit both install handlers in some
    /// configurations, and replacing one outright would silence it. Ours runs
    /// first and then hands on.
    static func install(url: URL = ExceptionTrap.defaultURL) {
        guard !isInstalled else { return }
        isInstalled = true
        destination = url
        previousHandler = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler { exception in
            ExceptionTrap.write(exception)
            ExceptionTrap.previousHandler?(exception)
        }
    }

    /// Reads a recorded exception and deletes it, so it is reported once.
    static func takePrevious(url: URL = ExceptionTrap.defaultURL) -> UncaughtException? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        defer { try? FileManager.default.removeItem(at: url) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(UncaughtException.self, from: data)
    }

    /// How this reads in the pane and the export.
    nonisolated static func summary(_ exception: UncaughtException) -> String {
        exception.reason.isEmpty
            ? exception.name
            : "\(exception.name): \(exception.reason)"
    }

    // MARK: The handler itself

    // The handler is a C function pointer and captures nothing, so its state
    // has to be global. `nonisolated(unsafe)` is honest about that: these are
    // written once during launch, before any exception can be thrown, and
    // read on a thread that is already on its way to dying.
    private nonisolated(unsafe) static var previousHandler:
        (@convention(c) (NSException) -> Void)?
    private nonisolated(unsafe) static var destination: URL?
    private nonisolated(unsafe) static var isInstalled = false

    private static func write(_ exception: NSException) {
        guard let destination else { return }
        let record = UncaughtException(
            date: Date(),
            name: exception.name.rawValue,
            reason: exception.reason ?? "",
            // The exception's own stack when it has one; the current stack
            // otherwise. `callStackSymbols` is already symbolicated.
            callStack: exception.callStackSymbols.isEmpty
                ? Thread.callStackSymbols
                : exception.callStackSymbols)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(record) else { return }
        try? FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        // One synchronous write with no locking and no logging. Everything
        // this does happens on a process that is already terminating, so the
        // only useful design goal is "finish before we're killed".
        try? data.write(to: destination, options: .atomic)
    }
}
