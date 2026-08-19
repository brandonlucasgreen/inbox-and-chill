# Vendored brand assets

## Microsoft Fluent Emoji — "Victory hand"

The app icon and both menu bar glyphs are derived from Microsoft's Fluent Emoji.

- **Source:** <https://github.com/microsoft/fluentui-emoji>
- **Asset path:** `assets/Victory hand/Default/`
- **Licence:** MIT — see [LICENSE-fluent-emoji](LICENSE-fluent-emoji)

| File | Fluent variant | Used for |
|---|---|---|
| `victory_hand_flat_default.svg` | Flat | App icon, and the solid menu bar glyph |
| `victory_hand_high_contrast_default.svg` | High Contrast | The hollow menu bar glyph |
| `victory_hand_color_default.svg` | Color | Kept for reference; not shipped |

The Color variant was rejected: its skin gradient turns pink against the plum ground and
muddies below 32px. Flat holds its shape all the way down to 16px.

### How the shipped art is derived

- **App icon** — the Flat SVG inlined into [`../icon.svg`](../icon.svg) at 640/1024 on the
  plum ground, then rasterised into the app icon set.
- **Solid menu bar glyph** — the Flat SVG with every fill collapsed to a single colour,
  which unions its `#D67D00` detail strokes into the `#FFC83D` body and leaves a clean
  silhouette. macOS template images are a single alpha mask, so a multi-colour emoji can
  never be used directly.
- **Hollow menu bar glyph** — the High Contrast SVG as-is. It is already a single colour
  (`#212121`) with no white knockouts, so its alpha channel is the line art.

### Why not IconScout, Twemoji, or Apple's emoji

IconScout's free Digital Licence forbids using an asset "as part of a trademark, design
mark, business name, service mark, or logo" and forbids redistribution with source files —
both fatal for an app icon in a repo headed for open source. Twemoji is CC-BY, so it would
need attribution in the app itself. Apple Color Emoji is proprietary and cannot be a
template image. MIT was the clean option.
