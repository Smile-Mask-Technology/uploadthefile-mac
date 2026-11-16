# Menu bar (status item) icons

Template images for the `NSStatusItem` button, plus the app icon, all drawn from the website's real logo
geometry: the logo's SVG paths, gradients and the busy `lift` loop timing are in
`scripts/make-menubar-icons.swift`. Nothing here is hand-drawn; if the logo changes, update the path strings
there and regenerate.

## The design

The mark in one colour: the arrow is a solid shape with the hexagonal hole of the real logo (so the blue arrow
becomes a black "ring" around the box), the isometric box sits in the hole and its three faces
(top, left, right) are separated by gaps instead of colour. Hole and box are scaled slightly (hole 0.95, box 0.90
about the box centre) so the ring is about 1.5 pt and the gaps about 0.8 pt: that is what survives at 18 pt tall.
Canvas is 20 x 20 pt, glyph 17 pt tall, shifted 0.5 pt down so the lifted arrow of `dropTarget` has headroom.

| State | Look |
| --- | --- |
| `idle` (signed in) | solid arrow ring + faceted box |
| `signedOut` | same shapes as outlines only (1.1 pt line, no fill): visibly quieter, no colour or alpha involved |
| `dropTarget` | arrow lifted 34 logo units (about 1.8 pt) so the ring's base opens, box lid drawn open (outline only): "ready to receive" |
| `busy-01 ... busy-12` | the arrow rises from behind the box, rests, lifts away and fades, clipped by the mark like on the website |

## Files

For every name below there are three files: `MenuBarIcon-<name>.pdf` (vector, 20 x 20 pt), `MenuBarIcon-<name>.png`
(20 x 20 px, @1x) and `MenuBarIcon-<name>@2x.png` (40 x 40 px).

- `MenuBarIcon-idle`, `MenuBarIcon-signedOut`, `MenuBarIcon-dropTarget`
- `MenuBarIcon-busy-01` ... `MenuBarIcon-busy-12`

Everything is pure black on transparent (the busy fade uses alpha only), so the system can tint it for light,
dark and highlighted menu bars. In the app: `image.isTemplate = true`, `image.size = NSSize(width: 20, height: 20)`,
and `button.imageScaling = .scaleNone` so AppKit does not shrink it. Prefer the PDFs; the PNGs are fallbacks.

## Busy animation

12 frames, **12 fps**, loop length 1.0 s, play `busy-01 ... busy-12` in order and repeat. Frames 1-5 rise (ease-out),
6-7 rest, 8-12 lift off with a fade. Same three beats and travel distances as the web `loop` (arrow from 150 below to
rest to 90 above, same clip), re-timed for 12 fps: the web curve (1.5 s, strong ease-out) would finish its rise within
two frames and read as a blink. For Reduce Motion show `idle` (or alternate `idle` / `busy-12` slowly).

## Regenerate

From the repo root (`uploadthefile-mac/`):

    swiftc -O scripts/make-menubar-icons.swift -o build/make-menubar-icons && build/make-menubar-icons

This rewrites `Resources/MenuBarIcons/*`, `Resources/AppIcon.icns` (via `iconutil`, iconset in
`build/AppIcon.iconset`) and the review sheets in `build/icon-review/` (gitignored): `menubar-review.png` (states at
real size 1x/2x on light and dark strips, next to the SF Symbol `square.and.arrow.up`, with zoomed copies),
`menubar-busy-review.png`, `menubar-context.png` (in a menu bar next to system symbols), `variants.png` and
`tuning.png` (the design exploration), `appicon-review.png`. The run also loads every PDF back through `NSImage` and
checks size and that all ink is pure black.

## App icon

`Resources/AppIcon.icns`: the full-colour mark (brand gradients, white lid band, arrow edge line) on a near-white
cool tile (824 pt rounded square inside 1024, standard margin and drop shadow), no text. `scripts/build-app.sh`
already uses it when present; `scripts/make-icon.swift` (the placeholder) is then unused.
