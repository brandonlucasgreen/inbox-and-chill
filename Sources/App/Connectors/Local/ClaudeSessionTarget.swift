import AppKit
import Foundation
import os

/// Where a Claude Code item should actually open.
///
/// The hook used to post `file://<cwd>` and nothing else, so ⏎ on "Claude
/// needs your input" opened Finder — the one place the session definitely
/// isn't. `inchill claude-hook` now records where the session is running
/// (`LocalListener.SessionOrigin`) and this decides what to do with that.
///
/// Two live cases, and a fallback that is still the folder:
///
/// - **The Claude desktop app** exports `CLAUDE_CODE_HOST_SESSION_ID`, the id
///   its own UI addresses a session by, and registers `claude://` — so
///   `claude://local_sessions/<id>` navigates straight to the live session.
/// - **A terminal** gives the hook a controlling terminal, and both
///   Terminal.app and iTerm2 expose the `tty` of every tab to AppleScript, so
///   the exact tab can be selected and raised.
///
/// **Never `claude://resume?session=<cli id>`**, which is the other route
/// Claude.app publishes: it *imports the transcript as a new desktop session*
/// (verified 2026-08-19 — it logged "importing CLI session", warmed a fresh
/// `local_…` session and started a shell). For a session that is still
/// running that means a duplicate, not a jump to the original.
enum ClaudeSessionTarget: Equatable {
    /// A live session in the Claude desktop app.
    case desktopSession(id: String)
    /// A terminal tab, identified by the tty the session holds.
    case terminalTab(bundleID: String?, tty: String)
    /// Nothing better than the item's own URL was recorded.
    case folder

    // MARK: - Deciding

    /// Reads what the hook recorded on the item.
    ///
    /// Pure, and deliberately conservative: a payload that isn't a
    /// `SessionOrigin` (every other connector puts its own thing there)
    /// decodes to nil and lands on `.folder`.
    nonisolated static func target(payload: Data?) -> ClaudeSessionTarget {
        guard let payload,
            let origin = try? JSONDecoder().decode(
                LocalListener.SessionOrigin.self, from: payload)
        else { return .folder }
        return target(origin: origin)
    }

    nonisolated static func target(origin: LocalListener.SessionOrigin) -> ClaudeSessionTarget {
        // The desktop id wins when both exist: a desktop session can also
        // carry a tty (its own shell), and the session lives in the app.
        if let host = origin.host?.trimmingCharacters(in: .whitespaces), !host.isEmpty,
            isValidSessionID(host)
        {
            return .desktopSession(id: host)
        }
        if let tty = origin.tty?.trimmingCharacters(in: .whitespaces), isValidTTY(tty) {
            return .terminalTab(bundleID: origin.bundleID, tty: tty)
        }
        return .folder
    }

    /// `local_<uuid>` or a bare uuid — Claude.app rejects anything else, and
    /// validating here keeps the id out of a URL if it is something odd.
    nonisolated static func isValidSessionID(_ id: String) -> Bool {
        let body = id.hasPrefix("local_") ? String(id.dropFirst("local_".count)) : id
        guard body.count == 36 else { return false }
        return UUID(uuidString: body) != nil
    }

    /// A device path and nothing else. The tty is interpolated into an
    /// AppleScript string literal, so this is the only thing standing between
    /// a hostile `origin` and script injection — hence a strict allowlist
    /// rather than escaping.
    nonisolated static func isValidTTY(_ tty: String) -> Bool {
        // `/dev/tty` itself is the generic controlling-terminal device, not a
        // terminal: every process has one and it matches no tab.
        guard tty != "/dev/tty" else { return false }
        guard tty.hasPrefix("/dev/tty") || tty.hasPrefix("/dev/pts/") else { return false }
        guard tty.count <= 32 else { return false }
        let rest = tty.dropFirst("/dev/".count)
        return rest.allSatisfy { $0.isLetter || $0.isNumber || $0 == "/" }
    }

    // MARK: - Building the jump

    /// `claude://local_sessions/<id>`.
    nonisolated static func desktopURL(sessionID: String) -> URL? {
        guard isValidSessionID(sessionID) else { return nil }
        return URL(string: "claude://local_sessions/\(sessionID)")
    }

    static let terminalBundleID = "com.apple.Terminal"
    static let iTermBundleID = "com.googlecode.iterm2"

    /// AppleScript that selects the tab holding `tty` and raises it,
    /// returning whether it found one.
    ///
    /// nil for any terminal without a scriptable tab model (Ghostty, WezTerm,
    /// Alacritty, kitty …) — those get their app activated instead, which is
    /// as far as this can honestly go.
    nonisolated static func focusScript(bundleID: String?, tty: String) -> String? {
        guard isValidTTY(tty) else { return nil }
        switch bundleID {
        case terminalBundleID:
            return """
                set matched to false
                tell application "Terminal"
                    repeat with w in windows
                        repeat with t in tabs of w
                            if tty of t is "\(tty)" then
                                set selected of t to true
                                set index of w to 1
                                set matched to true
                            end if
                        end repeat
                    end repeat
                    if matched then activate
                end tell
                return matched
                """
        case iTermBundleID:
            return """
                set matched to false
                tell application "iTerm2"
                    repeat with w in windows
                        repeat with t in tabs of w
                            repeat with s in sessions of t
                                if tty of s is "\(tty)" then
                                    select w
                                    select t
                                    select s
                                    set matched to true
                                end if
                            end repeat
                        end repeat
                    end repeat
                    if matched then activate
                end tell
                return matched
                """
        default:
            return nil
        }
    }

    /// What to tell the user when macOS refuses the AppleEvent.
    ///
    /// -1743 is "not authorised": the user said No to the Automation prompt,
    /// or has never been asked because the app was replaced. Silence here
    /// would look exactly like a session that had closed.
    nonisolated static func explain(appleScriptError code: Int, terminal: String) -> String {
        switch code {
        case -1743:
            return
                "macOS won't let Inbox & Chill bring \(terminal) to the front. Allow it under System Settings → Privacy & Security → Automation → Inbox & Chill, or the item will keep opening its folder instead."
        case -600, -609:
            return "\(terminal) isn't running any more, so its session opened as a folder instead."
        default:
            return
                "Couldn't bring \(terminal) to the front (AppleScript error \(code)); opened the folder instead."
        }
    }

    static let systemSettingsAutomationURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!
}

/// Runs a `ClaudeSessionTarget`. Split from the decision so every rule above
/// stays testable without a terminal, a desktop app, or an AppleEvent.
@MainActor
enum ClaudeSessionOpener {
    private static let log = AppLog.logger(.claudeSession)

    /// What happened, so the caller can't accidentally treat "no session
    /// recorded" and "macOS refused" the same way.
    enum Outcome: Equatable {
        /// The session was reached; the caller does nothing more.
        case reached
        /// Open the item's own URL instead. The string, when present, is a
        /// problem to put in front of the user — reaching neither the
        /// session nor an explanation is the one outcome this must not have.
        case fallBack(problem: String?)
    }

    static func reveal(_ target: ClaudeSessionTarget) -> Outcome {
        switch target {
        case .folder:
            return .fallBack(problem: nil)  // No session recorded.

        case .desktopSession(let id):
            guard let url = ClaudeSessionTarget.desktopURL(sessionID: id) else {
                return .fallBack(problem: nil)
            }
            guard NSWorkspace.shared.urlForApplication(toOpen: url) != nil else {
                // No Claude desktop app on this Mac (a shared build, a
                // teammate): the folder is genuinely the best there is.
                return .fallBack(problem: nil)
            }
            NSWorkspace.shared.open(url)
            return .reached

        case .terminalTab(let bundleID, let tty):
            let name = terminalName(bundleID: bundleID)
            guard let bundleID, let app = runningApp(bundleID: bundleID) else {
                // The terminal has quit; so has the session inside it.
                return .fallBack(problem: nil)
            }
            guard let script = ClaudeSessionTarget.focusScript(bundleID: bundleID, tty: tty) else {
                // A terminal we can't script a tab in. Fronting it is honest
                // and still better than Finder.
                app.activate()
                return .reached
            }
            var error: NSDictionary?
            let result = NSAppleScript(source: script)?.executeAndReturnError(&error)
            if let error {
                let code = (error[NSAppleScript.errorNumber] as? Int) ?? 0
                log.error("focus failed for \(name, privacy: .public): \(code, privacy: .public)")
                return .fallBack(
                    problem: ClaudeSessionTarget.explain(appleScriptError: code, terminal: name))
            }
            guard result?.booleanValue == true else {
                // Scripted fine, found no such tab: that session's window is
                // gone. Not a failure worth a message.
                return .fallBack(problem: nil)
            }
            return .reached
        }
    }

    private static func runningApp(bundleID: String) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    }

    private static func terminalName(bundleID: String?) -> String {
        switch bundleID {
        case ClaudeSessionTarget.terminalBundleID: return "Terminal"
        case ClaudeSessionTarget.iTermBundleID: return "iTerm"
        default: return "your terminal"
        }
    }
}
