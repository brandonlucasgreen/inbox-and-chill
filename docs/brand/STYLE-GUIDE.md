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

Plum ground, cream text, one warm amber note. The amber is the only saturated
color in the system and it should stay rare — it marks the thing you're meant to
look at, and nothing else.

The plum descends from bgreen.lol's `--accent` (`#200220`); the amber is the
same warm note that Social Sindy's mark carries against its cool chrome; the
cream is Unstream's light ground (`#f5f4f0`).

The icon itself carries Fluent's own yellow (`#FFC83D`) rather than `--warm`. They are
neighbours, not twins — don't "correct" either one to match the other. `--warm` is the UI
token; the emoji's yellow belongs to the emoji.

### Light

| Token | Value | Use |
|---|---|---|
| `--ground` | `#F7F5F0` | Page background |
| `--raised` | `#FFFFFF` | Cards, panels |
| `--text` | `#200220` | Body text |
| `--text-dim` | `#6E5F6E` | Secondary text |
| `--border` | `#E2DCD4` | Dividers, input borders |
| `--accent` | `#2A0B2A` | Primary buttons, headings |
| `--warm` | `#E8A33D` | The one warm note — badges, highlights |
| `--link` | `#1565C0` | Links (bgreen.lol's link color) |

### Dark

| Token | Value | Use |
|---|---|---|
| `--ground` | `#190118` | Page background |
| `--raised` | `#2A0B2A` | Cards, panels |
| `--text` | `#F5F4F0` | Body text |
| `--text-dim` | `#B3A6B3` | Secondary text |
| `--border` | `#3A203A` | Dividers, input borders |
| `--accent` | `#E8A33D` | Primary buttons |
| `--warm` | `#E8A33D` | Same warm note |
| `--link` | `#8E93AE` | Links (bgreen.lol's dark link color) |

Declare both under `color-scheme: light dark` and let the OS pick. No toggle —
none of the other properties have one.

**Amber discipline.** If two things on a screen are amber, one of them is wrong.
It is not a body-text color, not a link color, and not a background wash.

---

## Typography

- **Typeface:** [SN Pro](https://fonts.google.com/specimen/SN+Pro), with
  `system-ui` fallback. Same as bgreen.lol and Social Sindy.
- **Body:** `clamp(1rem, 0.96rem + 0.22vi, 1.125rem)`, line-height 1.5–1.6
- **Headlines:** 500 weight, `-0.025em` tracking, `text-wrap: balance`
- **Code / keys:** `ui-monospace, SFMono-Regular, Menlo`
- **Case:** sentence case in prose and headings. bgreen.lol's nav is lowercase;
  that's a site-nav mannerism, not a brand-wide rule — don't lowercase headings.

Keyboard shortcuts are a core feature, so style them properly: render `⌘P`,
`E`, `S` in the mono stack inside a bordered `kbd`, never as plain text.

---

## Geometry & motion

- **Pill controls:** `border-radius: 100vmax` on buttons and inputs (Sindy)
- **Panels:** `1.25rem`
- **Small radius:** `0.625rem` on selects and chips
- **Motion:** `150ms cubic-bezier(0.22, 1, 0.36, 1)`, on hover and active state
  changes only. No scroll animation, no entrance animation, no parallax.
- **Depth:** optional — Sindy's "sticker edge" card shadow (two soft ambient
  layers over a solid 8px offset) is the house shadow if the page needs one.

In the macOS app, none of this applies: use stock AppKit/SwiftUI chrome. The one
in-app rule that carries over is that **focus and selection are neutral, not
system blue** — a tonal `Color.primary` step over hover, plus a selection-only
hairline. System blue reads as an alert rather than a cursor.

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
