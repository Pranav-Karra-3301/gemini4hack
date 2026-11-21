# Heliocam landing: type + layout system (use exactly these)

Font: **Google Sans Flex** only. Colours: text `#EEF3FF`, muted `rgba(238,243,255,.68)`, faint `.45`,
accent violet `#9A7CF6`, ink `#070910`.

## Type scale (CSS custom properties; use `clamp` as written)
| Token | Use | Size | Weight | Tracking | Line height | Colour |
|---|---|---|---|---|---|---|
| `--t-display` | hero wordmark, "Gemini 4" | `clamp(88px, 11vw, 168px)` | 700 | -0.045em | 0.88 | text |
| `--t-h2` | section headline | `clamp(40px, 4.6vw, 68px)` | 650 | -0.03em | 1.02 | text |
| `--t-h3` | sub-heading in a section | `clamp(22px, 1.9vw, 28px)` | 600 | -0.015em | 1.2 | text |
| `--t-eyebrow` | chapter label ("01 · Live coaching") | `13px` | 600 | +0.12em, UPPERCASE | 1 | violet `#9A7CF6` |
| `--t-lede` | the line under a headline | `clamp(18px, 1.5vw, 21px)` | 400 | -0.005em | 1.5 | muted |
| `--t-step-num` | step number "01" | `13px` | 600 | +0.08em | 1 | violet |
| `--t-step` | step text | `17px` | 500 | -0.005em | 1.4 | text |
| `--t-small` | footer, credits | `13px` | 400 | 0 | 1.5 | faint |

Rules: max **one** h2 per section; the lede is ≤ 2 lines (`max-width: 34ch`); steps are ≤ 6 words; no
all-caps except the eyebrow; no mono, serif, dotted or dashed rules.

## Vertical rhythm (8px base)
eyebrow → h2 **16px** · h2 → lede **20px** · lede → steps **40px** · between steps **16px** ·
step number → step text **12px** (number above the text) · section padding `clamp(96px, 14vh, 168px)` top and
bottom · the hero is exactly `100svh`.

## Grid
- Container `max-width: 1280px; margin-inline: auto; padding-inline: clamp(20px, 5vw, 64px)`.
- 12 columns, 24px gutters. The text column spans **5** columns and the media spans **7**.
- Sections alternate media right / left, but **all text starts on the same column line** within its column.
  The eyebrow, h2, lede and steps share one left edge.
- Mobile (< 768px): a single column: text first, then the media; type tokens clamp down automatically.

## Steps component
A vertical list. Each item is the number (`--t-step-num`) over the text (`--t-step`). The active step (synced to
the video) is text 100% with a 2px violet bar at its left; inactive steps are at 45%. The transition is 240ms ease-out.

## Palette (v2, user: "too much purple")
- Ground ink `#070910`; surfaces `#0D1016`; text frost `#EEF3FF`; muted `.68`; faint `.45`.
- **Halftone and dither art is MONOCHROME**: warm white dots `#EDE8E0` at varied opacity on ink. No violet fields.
- **Gemini blue `#4C8DFF`** marks only what the AI does: region boxes, the scan line, the fader glow, the coach edge.
- **Violet `#9A7CF6`** appears only in the logo mark and favicon (and at most as a 1-dot accent). Eyebrows switch to
  frost at 55%, not violet.
- Mic red `#E5484D` only on the mic.

## Page structure (v3)
1. Hero: wordmark + phone (live coaching).
2. Coaches you live: the phone viewfinder demo.
3. **Sees in depth** (real data): photo → Depth Pro depth map → depth contours → 3D (scroll-driven).
4. **Edits with you** (real data): masks appear → Gemini moves faders → the photo relights live (before/after).
5. Just talk: voice (must be fully visible; nothing overlaps it).
6. **Powered by Gemini 4**: Gemini's real reading of a frame (regions, labels, light direction, then the suggestion).
7. Footer: wordmark, the two apps, credits. Ends cleanly on ink.
