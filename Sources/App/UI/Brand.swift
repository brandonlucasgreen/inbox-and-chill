import AppKit
import SwiftUI

/// The brand, as the app itself can draw it.
///
/// Almost every surface in the app is stock AppKit and SwiftUI chrome, on
/// purpose (`docs/brand/STYLE-GUIDE.md`, "In the macOS app"). One surface is
/// not: the first-launch welcome window, which is the only moment the app
/// gets to introduce itself, and which Brandon asked to carry the brand —
/// *"chill, dark blue / light beige calm color scheme, a cool looking wide
/// sans serif font"* (2026-09-04). He picked this palette and these faces
/// from three rendered directions, and the style guide was updated to match
/// in the same change, so this file and that document should agree.
///
/// Two typefaces ship in the bundle under `Resources/Fonts/`, registered by
/// AppKit at launch via `ATSApplicationFontsPath`: **Syne** for display and
/// **Space Grotesk** for text, both SIL OFL 1.1 with the licence beside
/// them. Every lookup here falls back to the system face, so a missing or
/// misregistered font degrades to SF rather than to nothing — but
/// `verify-bundle.sh` checks the folder and a test asks for the faces by
/// name, so the fallback is a safety net and not the shipped state.
enum Brand {
    // MARK: Palette (dark blue and beige, one warm note)

    static let navy = Color(hex: 0x0E1A2B)
    static let navyRaised = Color(hex: 0x16263B)
    static let beige = Color(hex: 0xF1E9D8)
    static let beigeDim = Color(hex: 0xB9AF9B)
    static let beigeFaint = Color(hex: 0x7F7868)
    /// The one warm note. If two things on a screen are amber, one is wrong.
    static let amber = Color(hex: 0xE8A33D)

    static let navyNSColor = NSColor(srgbRed: 0x0E / 255, green: 0x1A / 255, blue: 0x2B / 255, alpha: 1)

    // MARK: Type

    /// PostScript names as the bundled variable fonts expose their named
    /// instances — read back from `NSFontManager` after registration on
    /// 2026-09-04, not guessed. Space Grotesk's instances carry a `Light_`
    /// prefix that is an artefact of how its variable file names them.
    static let displayFaces = ["Syne-SemiBold", "Syne-Bold", "Syne-Medium"]
    static let textFaces = ["SpaceGrotesk-Light_Regular", "SpaceGrotesk-Regular"]
    static let textEmphasisFaces = ["SpaceGrotesk-Light_Medium", "SpaceGrotesk-Light_Bold", "SpaceGrotesk-Medium"]

    /// The first face that is actually registered, or nil. Pure over the
    /// list AppKit reports, so the choice is testable without a font file.
    nonisolated static func firstAvailable(_ preferred: [String], in available: Set<String>) -> String? {
        preferred.first { available.contains($0) }
    }

    /// Wide display face; SF Pro Expanded when Syne is not registered.
    static func display(_ size: CGFloat) -> Font {
        if let name = firstAvailable(displayFaces, in: registeredFaces),
            let font = NSFont(name: name, size: size)
        {
            return Font(font)
        }
        return Font(NSFont.systemFont(ofSize: size, weight: .semibold, width: .expanded))
    }

    static func text(_ size: CGFloat, emphasis: Bool = false) -> Font {
        let faces = emphasis ? textEmphasisFaces : textFaces
        if let name = firstAvailable(faces, in: registeredFaces),
            let font = NSFont(name: name, size: size)
        {
            return Font(font)
        }
        return Font(NSFont.systemFont(ofSize: size, weight: emphasis ? .semibold : .regular))
    }

    private static var registeredFaces: Set<String> {
        Set(NSFontManager.shared.availableFonts)
    }

    /// The house tagline — the About pane's byline and the welcome window's
    /// subhead. `docs/brand/COPY.md` says the landing page matches it, so
    /// change all of them together or none.
    static let tagline = "Everything waiting on you, in one queue, nice & chilled."
}

extension Color {
    /// `Color(hex: 0xRRGGBB)`, sRGB.
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255)
    }
}

/// The capsule button the welcome uses: amber ground, navy label, and a
/// press state that darkens rather than tints — the guide's pill control.
struct BrandCapsuleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Brand.text(14, emphasis: true))
            .foregroundStyle(Brand.navy)
            .padding(.horizontal, 22)
            .padding(.vertical, 11)
            .background(Capsule().fill(Brand.amber.opacity(configuration.isPressed ? 0.82 : 1)))
            .contentShape(Capsule())
    }
}
