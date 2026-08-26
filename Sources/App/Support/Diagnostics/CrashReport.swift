import Foundation

/// One crash, as read out of a macOS `.ips` report.
///
/// Everything here comes from the file the OS already wrote; the app installs
/// no signal handler of its own. See `CrashReportFile` for why, and for the
/// shape of the file this is decoded from.
struct CrashReport: Sendable, Equatable, Codable {
    /// The report file this came from, so the pane can reveal it in Finder.
    var fileName: String
    var date: Date
    /// Marketing version of the build that crashed — often *not* the version
    /// running now, which is exactly why it is recorded.
    var appVersion: String
    var buildVersion: String
    var osVersion: String
    var procName: String
    var bundleID: String?
    /// `EXC_BAD_ACCESS`, `EXC_CRASH`, …
    var exceptionType: String?
    /// `SIGSEGV`, `SIGABRT`, …
    var signal: String?
    /// `KERN_INVALID_ADDRESS at 0x0000000000000010`
    var subtype: String?
    /// dyld's one-line summary, e.g. "Library missing".
    var terminationIndicator: String?
    /// `DYLD`, `SIGNAL`, `CODESIGNING`… Decides whether the indicator above
    /// is worth reading: `SIGNAL` only ever restates the signal.
    var terminationNamespace: String?
    /// The process that killed us, when another one did. The difference
    /// between "the app crashed" and "something shut it down" — and the two
    /// need entirely different investigations.
    var terminatedByProcess: String?
    /// The sentences dyld or the runtime attached. For a missing-library
    /// crash this is the whole story and the backtrace is noise — the OS
    /// itself says "terminated at launch; ignore backtrace".
    var terminationReasons: [String]
    var faultingThreadIndex: Int
    var frames: [Frame]

    struct Frame: Sendable, Equatable, Codable {
        var index: Int
        var image: String
        var symbol: String?
        var symbolLocation: Int
        var address: UInt64
    }
}
