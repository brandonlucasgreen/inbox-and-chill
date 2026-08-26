import Foundation

/// One thing that went wrong, durably.
///
/// The app already computes a sentence for every failure it knows about —
/// `ConnectorStatus.error`, `hookProblems`, `launchAtLoginError`,
/// `UpdateController.lastFailure`, `JournalWriter.explain`. Until now those
/// sentences lived only in memory and only until Settings closed. A `Problem`
/// is that same sentence, written down.
struct Problem: Sendable, Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var date: Date
    var category: AppLog.Category
    /// The source this is about, when it is about one.
    var sourceID: String?
    /// How that source is named in Settings, so the pane needn't look it up.
    var sourceLabel: String?
    /// The sentence the user reads. Already written for a human — these are
    /// re-used, not re-worded.
    var summary: String
    /// Anything longer: an underlying error, a status code, a script message.
    var detail: String?

    /// What counts as "the same problem happening again". Used to keep a
    /// connector that fails every 30 seconds from filling the log with one
    /// sentence ten thousand times.
    var fingerprint: String {
        "\(category.rawValue)|\(sourceID ?? "")|\(summary)"
    }
}

/// The durable error log: a bounded JSONL file next to the store.
///
/// Deliberately *not* a second way for the app to fail. `record` is a tee off
/// strings the app already produced — it changes no control flow and returns
/// nothing anyone waits on. What it must not do is fail silently (rule 5), so
/// a write that goes wrong sets `writeProblem`, and the Diagnostics pane
/// prints that instead of an empty and reassuring list.
///
/// The line rendering and parsing are `nonisolated static` and pure (rule 6),
/// following `JournalWriter.line(for:)` — the actor exists only to serialise
/// the file IO.
actor ProblemLog {
    static let shared = ProblemLog()

    /// `~/Library/Application Support/InboxAndChill/diagnostics.log`.
    static var defaultURL: URL {
        URL.applicationSupportDirectory
            .appending(path: "InboxAndChill/diagnostics.log")
    }

    /// Rotate at 1 MB and keep one previous file. At ~200 bytes a line that
    /// is roughly 5,000 problems — far more history than anyone reads, and
    /// small enough to paste into an issue.
    static let maxBytes = 1_000_000
    static let recentLimit = 50

    /// A repeat of the same problem inside this window is dropped. A poll
    /// loop failing on a bad token emits every 30s; without this the log is
    /// one sentence and no history.
    static let repeatWindow: TimeInterval = 15 * 60

    private let url: URL
    private var lastSeen: [String: Date] = [:]

    /// Why the log itself is not being written, or nil. Read by the pane.
    private(set) var writeProblem: String?

    init(url: URL = ProblemLog.defaultURL) {
        self.url = url
    }

    // MARK: Writing

    /// Records a problem, unless the same one was recorded moments ago.
    func record(_ problem: Problem) {
        if let previous = lastSeen[problem.fingerprint],
           problem.date.timeIntervalSince(previous) < Self.repeatWindow {
            return
        }
        lastSeen[problem.fingerprint] = problem.date

        guard let line = Self.line(for: problem) else {
            writeProblem = "A problem couldn't be encoded for the log: \(problem.summary)"
            return
        }
        do {
            try rotateIfNeeded()
            try append(line)
            writeProblem = nil
        } catch {
            // Not `try?`. If the diagnostics log cannot be written, that is
            // itself a fact the user needs, because everything else in the
            // pane is about to look empty for the wrong reason.
            writeProblem = "Couldn't write the diagnostics log at "
                + "\(url.path(percentEncoded: false)): \(error.localizedDescription)"
        }
    }

    /// Convenience for the common shape.
    func record(
        _ category: AppLog.Category,
        _ summary: String,
        sourceID: String? = nil,
        sourceLabel: String? = nil,
        detail: String? = nil,
        at date: Date = Date()
    ) {
        record(Problem(
            date: date, category: category, sourceID: sourceID,
            sourceLabel: sourceLabel, summary: summary, detail: detail))
    }

    private func append(_ line: String) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: url, options: .atomic)
        }
    }

    private func rotateIfNeeded() throws {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path))
            .flatMap { $0[.size] as? Int } ?? 0
        guard size > Self.maxBytes else { return }
        let previous = url.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: previous)
        try FileManager.default.moveItem(at: url, to: previous)
    }

    // MARK: Reading

    /// The most recent problems, newest first, across the current file and
    /// the rotated one.
    func recent(limit: Int = ProblemLog.recentLimit) -> [Problem] {
        var text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        if text.count < 4096,
           let older = try? String(
            contentsOf: url.appendingPathExtension("1"), encoding: .utf8) {
            text = older + text
        }
        return Self.problems(fromJSONL: text)
            .sorted { $0.date > $1.date }
            .prefix(limit)
            .map { $0 }
    }

    func currentWriteProblem() -> String? { writeProblem }

    var fileURL: URL { url }

    // MARK: Pure helpers (rule 6)

    /// One JSONL line, or nil if the problem cannot be encoded.
    nonisolated static func line(for problem: Problem) -> String? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // Sorted keys so a diff of two log files is readable, and so the
        // tests can assert on a line rather than on a decoded round trip.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(problem) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Parses a JSONL log, skipping lines it cannot read.
    ///
    /// A single corrupt line — a half-written record from a crash mid-append
    /// — must not cost the whole history, which is why this is lenient by
    /// design rather than by accident.
    nonisolated static func problems(fromJSONL text: String) -> [Problem] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n").compactMap { line in
            try? decoder.decode(Problem.self, from: Data(line.utf8))
        }
    }
}

extension ProblemLog {
    /// Fire-and-forget recording from anywhere, including the MainActor.
    ///
    /// The call sites for this are failure paths that already do their real
    /// job — set a red status, show a sentence — and this must not change how
    /// any of them behave. So it is deliberately not `await`ed, returns
    /// nothing, and cannot throw. The one thing it *does* report is its own
    /// failure to write, via `writeProblem` (rule 5).
    nonisolated static func note(
        _ category: AppLog.Category,
        _ summary: String,
        sourceID: String? = nil,
        sourceLabel: String? = nil,
        detail: String? = nil
    ) {
        Task {
            await ProblemLog.shared.record(
                category, summary, sourceID: sourceID,
                sourceLabel: sourceLabel, detail: detail)
        }
    }
}
