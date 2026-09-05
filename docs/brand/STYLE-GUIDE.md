# Inbox & Chill — Style Guide

The app is a menu bar triage queue. The brand should feel like the app: quiet,
warm, keyboard-first, and honest about being a small personal tool. Nothing here
should read as enterprise software or as a startup launch.

This guide is derived from what already exists across bgreen.lol, Unstream, and
Social Sindy rather than invented alongside them. Where a value came from one of
those properties, it says so.

---

## Mark

Microsoft's Fluent Emoji **victory hand** — ✌️ — Flat variant, on a plum rounded square.
Not a hand-drawn interpretation: the actual emoji, so the icon reads as the thing people
already know rather than as a logo of it.

- **Source:** [Fluent Emoji](https://github.com/microsoft/fluentui-emoji), MIT licensed
- **Vendored:** `docs/brand/vendor/` — see its [README](vendor/README.md) for provenance,
  licence, and how each shipped file is derived
- **Composition:** [icon.svg](icon.svg). Rendered sizes live in
  `Sources/App/Resources/Assets.xcassets/AppIcon.appiconset/`

**Why a hand and not a tray.** The tray is what the app *does*; the peace sign is what it's
*for*. Every competitor in this space signals volume and urgency. This one signals that
you're allowed to be done.

**Construction.** 1024×1024 canvas, rounded square 824×824 inset at (100,100) with a 185.4
corner radius — Apple's macOS icon grid. The emoji is placed in a 640×640 box centred on
the canvas, i.e. `translate(192,192) scale(20)` from its native 32×32 viewBox.

**Rules**

- Use the **Flat** variant. The Color variant's skin gradient turns pink against the plum
  and muddies below 32px; Flat holds its shape to 16px.
- Don't recolor the hand. It ships in Fluent's own `#FFC83D` / `#D67D00`.
- Don't rotate, skew, or re-draw it. If it needs to change, change the *ground*.
- Minimum size 16px. Below that, use the wordmark instead.
- Clear space: 10% of the icon's width on all sides — already built into the 824-in-1024
  inset, so don't crop the artwork out of the square.
- Keep the MIT licence file shipped alongside it in any distribution.

### Menu bar glyph

Two states, both **template images** — a single alpha mask that macOS tints for the light
or dark menu bar. Never ship them colored.

| State | Asset | Derived from |
|---|---|---|
| Queue empty | `MenuBarPeaceOutline` | Fluent **High Contrast**, used as-is — already one color, so its alpha is the line art |
| Something waiting | `MenuBarPeace` | Fluent **Flat** with every fill collapsed to one color, unioning its detail strokes into a silhouette |

Sources: [menubar-solid.svg](menubar-solid.svg), [menubar-outline.svg](menubar-outline.svg),
shipped at @1x (18pt) and @2x.

A multi-color emoji can never be a menu bar glyph directly — a template image carries no
color of its own, only coverage. That constraint is why the solid state has to be flattened
rather than simply scaled down.

---

## Palette

Dark blue ground, light beige text, one warm amber note. Decided 2026-09-04,
replacing the plum-and-cream scheme the guide carried from launch: Brandon
asked for *"chill, dark blue / light beige calm color scheme"* and chose this
from three rendered directions. The amber is unchanged and still the only
saturated color in the system — it marks the thing you're meant to look at,
and nothing else.

The icon still carries its plum square and Fluent's own yellow (`#FFC83D`).
That is deliberate for now: the mark's rules say change the *ground* if
anything, and re-grounding the icon in navy is a separate decision, not a
side effect of this one.

### Light

| Token | Value | Use |
|---|---|---|
| `--ground` | `#F3EDE1` | Page background |
| `--raised` | `#FAF6EE` | Cards, panels |
| `--text` | `#0E1A2B` | Body text |
| `--text-dim` | `#5C6573` | Secondary text |
| `--border` | `#E1D8C6` | Dividers, input borders |
| `--accent` | `#0E1A2B` | Primary buttons, headings |
| `--warm` | `#E8A33D` | The one warm note — badges, highlights |
| `--link` | `#1F4E8C` | Links |

### Dark

| Token | Value | Use |
|---|---|---|
| `--ground` | `#0E1A2B` | Page background |
| `--raised` | `#16263B` | Cards, panels |
| `--text` | `#F1E9D8` | Body text |
| `--text-dim` | `#B9AF9B` | Secondary text |
| `--border` | `#25364D` | Dividers, input borders |
| `--accent` | `#E8A33D` | Primary buttons |
| `--warm` | `#E8A33D` | Same warm note |
| `--link` | `#9DB4D8` | Links |

Declare both under `color-scheme: light dark` and let the OS pick. No toggle —
none of the other properties have one.

**Amber discipline.** If two things on a screen are amber, one of them is wrong.
It is not a body-text color, not a link color, and not a background wash.

---

## Typography

- **Display:** [Syne](https://fonts.google.com/specimen/Syne), SemiBold. A
  genuinely wide sans with some swagger — the *"cool looking wide sans serif"*
  Brandon asked for. Headlines only.
- **Text:** [Space Grotesk](https://fonts.google.com/specimen/Space+Grotesk),
  Regular for body and Medium for emphasis and buttons.
- **Fallback:** `system-ui`; in the app, SF Pro Expanded stands in for Syne.
- **Code / keys:** `ui-monospace, SFMono-Regular, Menlo`
- **Body:** `clamp(1rem, 0.96rem + 0.22vi, 1.125rem)`, line-height 1.5–1.6
- **Headlines:** 600 weight, normal tracking (Syne is already wide — do not
  letter-space it), `text-wrap: balance`
- **Case:** sentence case in prose and headings. Don't lowercase headings.

Both faces are **SIL Open Font License 1.1**: free to bundle, embed and sell
*with* software, never sold by themselves, licence text shipped alongside.
Neither declares a Reserved Font Name. In the app they live in
`Sources/App/Resources/Fonts/` beside `OFL-Syne.txt` and
`OFL-SpaceGrotesk.txt`, registered at launch via `ATSApplicationFontsPath`;
`scripts/verify-bundle.sh` checks all four files are in a built bundle. On
the web, load them from Google Fonts:

```html
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Syne:wght@500;600;700&family=Space+Grotesk:wght@400;500;600&display=swap">
```

Keyboard shortcuts are a core feature, so style them properly: render `⌘P`,
`E`, `S` in the mono stack inside a bordered `kbd`, never as plain text.

SN Pro, the previous face, is retired from this brand. bgreen.lol and Social
Sindy keep using it; that is those sites' call.

---

## Geometry & motion

- **Pill controls:** `border-radius: 100vmax` on buttons and inputs (Sindy)
- **Panels:** `1.25rem`
- **Small radius:** `0.625rem` on selects and chips
- **Motion:** `150ms cubic-bezier(0.22, 1, 0.36, 1)`, on hover and active state
  changes only. No scroll animation, no entrance animation, no parallax.
- **Depth:** optional — Sindy's "sticker edge" card shadow (two soft ambient
  layers over a solid 8px offset) is the house shadow if the page needs one.

In the macOS app, none of this applies: use stock AppKit/SwiftUI chrome —
**with one exception, the first-launch welcome window.** It is the only moment
the app introduces itself, and it carries the brand outright: navy ground in
both appearances, beige text, Syne headline, Space Grotesk body, the amber
capsule button, and the app icon as its hero (`Sources/App/UI/Brand.swift`,
`WelcomeWindowView`). Nothing else in the app should copy it. The one in-app
rule that does carry over everywhere is that **focus and selection are
neutral, not system blue** — a tonal `Color.primary` step over hover, plus a
selection-only hairline. System blue reads as an alert rather than a cursor.

---

## Density

Roomy over dense, in the app and on the web.

- Tap/click targets ≥ 24pt
- Body type 13–14pt in-app
- Grouped, scrolling forms in sheets — never a layout that clips at the bottom

---

## Voice

Written the way Brandon writes on bgreen.lol: first person, plain, specific, and
unwilling to oversell.

**Do**

- Write in first person. "I built this because…" not "Inbox & Chill was built…"
- Lead with the concrete thing it does, not the feeling it gives you.
- Use real numbers when you have them. "1,199 GitHub notifications" beats
  "a lot of noise."
- Name the tradeoff out loud. "This is pre-release. Expect rough edges."
- Say what it *isn't*. The triage-queue-not-a-client distinction is the whole
  product; lead with it rather than burying it.
- Em-dashes for asides. Short declaratives. The occasional self-deprecating
  aside is on-brand.

**Don't**

- No hype verbs: supercharge, revolutionize, unlock, 10x, effortlessly.
- No productivity moralizing. The app doesn't think you're lazy, and the copy
  shouldn't imply you should be doing more.
- No fake scale. One person made this for himself; don't write "we."
- No urgency or FOMO. It's an app about *not* being urgent.
- No feature lists where a sentence would do.

**Tone check.** If a line would look out of place in a post on bgreen.lol, it's
wrong for the landing page.

---

## Naming

- The app is **Inbox & Chill** — ampersand, both words capitalized, no hyphen.
- The CLI is `inchill`, lowercase, always in mono.
- Bundle ID `lol.bgreen.inboxandchill`.
- Don't abbreviate to "I&C."
