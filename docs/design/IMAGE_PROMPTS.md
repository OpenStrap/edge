# Edge "Volt": image generation sheet

For you (the human), not Claude Code. Generate these, export them as **PNG with
a transparent background** (Claude Code converts them to WebP and makes
@1x/@2x/@3x in Phase 6), and drop them into `edge/assets/images/` with
**exactly** these filenames.

## The house style (paste this at the start of every prompt)

> Studio product render, matte soft-touch black material, single large soft key
> light from top-left, very subtle electric lime (#B1F002) rim light on the right
> edge, gentle contact shadow, isolated on a fully transparent background,
> centred, generous empty margin around the object, photoreal 3D, high detail,
> calm premium wellness-tech aesthetic, no text, no logos, no brand marks, no
> people, no hands.

Rules that keep the set consistent:

- **Same camera:** 3/4 view from slightly above (about 20°), 50 mm look.
- **Same light:** key top-left, lime rim on the right. Never coloured
  backgrounds. The app paints the background (aurora) behind the art.
- **Same material family:** matte black + one accent material at most (brushed
  graphite or frosted glass).
- **No logos, ever.** Generic devices only. The app is independent of WHOOP,
  Oura, Garmin and others, and their marks can't appear.
- Square canvas, **2048 × 2048**, object filling about 70% of the frame.

## Asset slots

| # | Filename | Where it's used | Subject prompt (after the house style) |
|---|---|---|---|
| 1 | `art_band_hero.png` | Welcome, pairing step 3, Devices | A screenless fitness strap: a rounded rectangular matte black sensor pod on a woven black knit band, the band curving into a loose loop, one small glowing lime LED pill on the top face. 3/4 view. |
| 2 | `art_band_side.png` | Pairing step 1 (wake / charge) | The same strap pod seen in side profile, band flat, with a slim matte black charging puck clipped on top, a tiny lime charging light. |
| 3 | `art_band_top.png` | Pairing step 2 (connecting) | The same strap, viewed straight down from above, band forming a circle around the pod, perfectly centred (the app draws a lime arc around it). |
| 4 | `art_ring.png` | Device picker | A smooth matte black smart ring with a faint brushed graphite inner surface, standing upright, slight tilt. |
| 5 | `art_watch.png` | Device picker | A minimalist round smartwatch with a blank black screen and a black sport band, no numbers or UI on the screen. |
| 6 | `art_chest_strap.png` | Device picker (HR sensors) | A slim matte black chest heart-rate strap, sensor module centred, elastic band curving away. |
| 7 | `art_workout.png` | Activity › Start a session (replaces the workout mascot) | A matte black kettlebell with a brushed graphite handle, slight lime rim light, tilted 10°. |
| 8 | `art_wellness.png` | Wellness › Breathe (replaces the wellness mascot) | Three smooth balanced matte black river stones stacked, the top one frosted glass with a soft inner sage-green (#9FD4B4) glow. |
| 9 | `art_sleep.png` | Sleep empty/intro states | A matte black crescent moon object resting on its curve, frosted inner edge with a soft lavender (#A99BFF) glow. |
| 10 | `art_food.png` | Nutrition intro | A matte black ceramic bowl, empty, with a single frosted-glass sphere inside giving off a soft amber (#FFB547) glow. |
| 11 | `art_heart.png` | Health intro / ECG intro | An abstract smooth heart-shaped matte black stone with a thin rose (#FF7A9A) glowing seam running across it. |
| 12 | `grain.png` | Aurora tile texture (tiled) | **Not a render.** A 512 × 512 seamless monochrome film-grain noise tile, mid-grey, very fine. Many generators struggle with this. If yours does, skip it and Claude Code will generate it in code. |

## Optional

- **App icon refresh** (`icon.png`, 1024 × 1024, not transparent): "A bold
  geometric italic letter E built from three parallel rounded slanted bars,
  electric lime #B1F002 on near-black #0F1014, flat vector, centred, no
  gradient, app-icon safe margins." If you change it, also give Claude Code an
  adaptive foreground (`assets/launcher/icon_adaptive.png`, same mark on
  transparent, 1024 × 1024 with 33% padding).

## Checklist before handing to Claude Code

- [ ] Transparent background (check it in a viewer; no white halo)
- [ ] No logos, text, or brand-recognisable product shapes
- [ ] Same camera angle and light direction across 1–11
- [ ] Filenames exactly as above
