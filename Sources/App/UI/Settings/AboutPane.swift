import AppKit
import SwiftUI

/// About: what this is, who made it, and how to chip in.
///
/// A menu bar app has no app menu, so there is no "About Inbox & Chill" item
/// for macOS to hang a standard about window off. Settings is the only place
/// this can live.
struct AboutPane: View {
    var body: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 16) {
                    // Read the icon straight out of the asset catalogue.
                    // `NSApp.applicationIconImage` answers from the LaunchServices
                    // icon cache, which keeps serving the previous artwork when the
                    // bundle path and identifier stay put and only the art changes.
                    Image(nsImage: NSImage(named: "AppIcon") ?? NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 72, height: 72)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Inbox & Chill")
                            .font(.system(size: 20, weight: .semibold))
                        Text(Self.versionLine)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Text("Everything waiting on you, in one queue, nice & chilled.")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 4)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 6)
            }

            Section("Made by") {
                LabeledContent("Brandon Lucas Green") {
                    Link("bgreen.lol", destination: URL(string: "https://bgreen.lol")!)
                }
                LabeledContent("Also mine") {
                    Link("unstream.stream", destination: URL(string: "https://unstream.stream")!)
                }
                LabeledContent("Also mine") {
                    Link("socialsindy.com", destination: URL(string: "https://socialsindy.com")!)
                }
                LabeledContent("Found a bug, or want to say hi?") {
                    Link("hi@bgreen.lol", destination: URL(string: "mailto:hi@bgreen.lol")!)
                }
            }

            Section("Thanks") {
                LabeledContent("Keyboard shortcut recording") {
                    Link(
                        "KeyboardShortcuts by Sindre Sorhus (MIT)",
                        destination: URL(string: "https://github.com/sindresorhus/KeyboardShortcuts")!)
                }
                LabeledContent("In-app updates") {
                    Link(
                        "Sparkle (MIT)",
                        destination: URL(string: "https://sparkle-project.org")!)
                }
                // The icon is Fluent's artwork, not ours, and its licence asks
                // to travel with it. docs/brand/vendor/ carries the licence
                // text; this is the credit a user can actually see.
                LabeledContent("App icon") {
                    Link(
                        "Fluent Emoji by Microsoft (MIT)",
                        destination: URL(string: "https://github.com/microsoft/fluentui-emoji")!)
                }
            }
        }
        .formStyle(.grouped)
    }

    /// "Version 0.1.0 (12)" — falls back gracefully if either key is missing,
    /// which is what a plain `xcodebuild` with no version set will hand us.
    static var versionLine: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String
        switch (short, build) {
        case let (short?, build?): return "Version \(short) (\(build))"
        case let (short?, nil): return "Version \(short)"
        default: return "Pre-release build"
        }
    }
}
