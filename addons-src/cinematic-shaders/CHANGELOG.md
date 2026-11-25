# Cinematic shaders: changes

Newest first. Versions before 0.4.5 are summarised from Zenith's history.

## 0.6.2

Lightning no longer whites out the sky (`shaders/cinematic_grade.gdshader`).

- A weather flash lit every cloud with a fixed 0.75-0.8, twenty times a stormy night's cloud; the look's
  exposure, AgX and film curve made the whole sky white. Now the clouds, and Zenith's sky behind them,
  brighten in proportion to their own light (about 2-4x at night), capped; Flash brightness still scales
  it. `--cinematic-flash=old` brings back 0.6.1's flash.

## 0.6.1 (with Zenith 0.2.3)

HDR-safe sharpening and night signal colours (`shaders/cinematic_grade.gdshader`).

- Normalized clarity and sharpening by local luminance with HDR-spike halo suppression so bright
  sub-pixel emitters (rail signals, water glints, fire) no longer carve dark ringing boxes into dark
  night rails and terrain.
- Preserved vivid hues on bright self-lit pixels during night/blue hour (`emissive_keep`) instead of
  desaturating them toward cold sky blue.

Headless shader checks only; not yet seen in a window.

## 0.6.0 (with Zenith 0.2.3)

Volumetric 3D clouds.

- New 3D cloud raymarcher (`sky_clouds_volumetric` in `shaders/cinematic_grade.gdshader`): pairs the `1024 x 1024`
  weather/cloud-type field (`cloud_field.gdshader`'s alpha channel) with two seamless `32 x 32 x 32` 3D Worley
  shape and detail volumes (`ImageTexture3D`), raymarched through a curved-horizon shell (`210-390` tiles)
  with adaptive empty-space skipping, Interleaved Gradient Noise dithering, 4-step sun self-shadowing,
  Beer-Powder multiple scattering, dual-lobe Henyey-Greenstein silver linings, ambient sky-bounce undersides,
  and aerial perspective fading toward the horizon.
- Syncs with Zenith's volumetric smog and God rays through `looks.cloud_source()`.
- New settings under Picture: "Volumetric clouds" (on by default; off brings back 0.5.3's lighter flat cloud
  layer, or pass `--volumetric-clouds=off`) and "Cloud quality" (`Low` 18 steps, `Medium` 28 steps, `High` 40 steps).

Headless tests only; not yet seen in a window.

## 0.5.3 (with Zenith 0.2.3)

Tuned default ambient occlusion.

- SSAO defaults updated to radius 1.7, intensity 2.45, and power 2.0 (was 1.75 / 1.75 / 1.6 in 0.5.2 and
  1.4 / 1.5 / 1.6 before), used both by default on indirect light and with "Occlusion in sunlight too" on.
- "Occlusion in sunlight too" stays off by default.

## 0.5.2 (with Zenith 0.2.3)

Ambient occlusion where light says it goes: on the shade.

- Ambient occlusion darkens indirect light (the sky's, the shade) and only a little of the sun's (`ssao_light_affect`
  0.15; Zenith's own looks 0.85), and models' and the ground's own occlusion no longer darkens their sunlit sides
  (look key `ao_direct` 0). Sunlit walls no longer go grey in corners; the shade at a machine's foot stays.
- The clouds drawn in the sky follow the debug menu's Sun and Ambient energy (Zenith's `look_scene_light`): at 0 and 0 they
  are dark like the rest of the sky.
- Radius 1.75 and strength 1.75 (were 1.4 and 1.5), a little wider and stronger, since it now acts on the shade alone.
- Bounce light (SSIL) stays off by default, on its own switch.
- New setting, off: "Occlusion in sunlight too" gives 0.5.1's occlusion back. On a Zenith without `ao_direct` the key is
  ignored: models' own occlusion still darkens their sunlit sides there.

## 0.5.1 (with Zenith 0.2.3)

Models show a lit side and a shaded one again.

- The sun that crosses the sky now stands in the north-west at noon (`sun_noon_yaw` -135), the side Factorio's
  sprites are lit from, and rises in the east and sets in the west across the north. Zenith's own noon sun stood
  high behind the default view, so every side of a model the camera sees was lit: the modeller's stone and ore
  rocks (full metal, so mostly the reflection of a light that also follows the sun) drew flat and bright, where
  the Factorio look, its sun held in the west, shows them a lit side and a shaded one. Shadows now fall towards
  the bottom right of the screen at noon, as Factorio's do.
- The same with "Sunrise and sunset" at 0 (the sun that fades without setting).
- New setting, on: "Noon sun from the north-west". Off gives the sun before 0.5.1. "The sun crosses the sky"
  off holds the sun where the Factorio look has it, as before.
- On a Zenith without `sun_noon_yaw` the key is ignored: the old noon sun.

## 0.5.0 (with Zenith 0.2.3)

Steadier, sharper shadows by default.

- "Soft shadows" (on by default) now gives wider, even shadow edges (`shadow_edge` 0.04 tiles, twice
  Zenith's Factorio edge) instead of a sun 1.4 degrees wide. That sun turned on Godot's contact-hardening
  shadows (PCSS), whose blocker search with few taps left holes in thin shadows (wires, a pole's
  lattice), a grain that slid over the ground as the camera moved, and stair-steps where things touch
  the ground.
- New, off by default: "Shadows soften with distance" brings those shadows back, at a "Sun size" of 0.5
  degrees (the real sun's; 0.1-1.4, 1.4 being the old look). Zenith gives them a shorter, denser search
  (24 + 24 taps on Shadows: High and Ultra, a pancake of 8 tiles); still grainy below High, smoothest
  with temporal anti-aliasing.
- Needs add-on API 1.7 (Zenith 0.2.3 or later), which added `shadow_edge`.

Not yet seen in a window.

## 0.4.5 (with Zenith 0.2.1)

The same picture for less GPU time.

- The clouds' pattern is drawn once into a texture when the add-on starts (`shaders/cloud_field.gdshader`,
  1024 x 1024 at 16 bits a channel, about 8 MB of video memory), and the grade reads it: one texture read
  where it worked out the noise before, up to 48 sines and cosines for a pixel of cloud shadow on the
  ground and about 150 noise calls for a pixel of sky. The pattern now repeats every 1,800 tiles or so; it
  is the same kind of noise at the same sizes, but the clouds are new shapes (the old noise couldn't be
  made to repeat as it was). Most saved in first person or with a low camera, where the sky is in view;
  from above the clouds measured 0.13-0.25 ms at 4K before.
  Ported to numpy, the two cover the sky and ground alike (17.8% of the ground's shadow layer against
  16.9%, 36.2% of the sky's widest layer against 35.5%) and the field wraps without a seam.
- The grade skips reads that changed nothing: the far softening where nothing is softened (from above,
  nearly the whole screen), and the colour fringe's two extra reads where red and blue would land less
  than a quarter of a pixel from green (the middle of the screen).
- With Zenith 0.2.1: the look's temporal anti-aliasing (off by default) runs in place of SMAA instead of
  over it (SMAA under it measured 0.37-0.40 ms at 4K), and Zenith draws the grade before any ground
  clutter that shares its render priority (some flat clutter near the map's origin was drawn first and
  then covered by it).

Not yet seen in a window: the clouds by day, at dusk and at night, and the fringe at the screen's edges.

## Before

- 0.4.4: ambient occlusion lighter (intensity 2.2 -> 1.5), bounce light (SSIL) its own option, off by
  default; with ambient occlusion off the grade no longer makes Godot's depth pre-pass write normals.
- 0.4.3: on a space platform the grade leaves the black backdrop and its stars alone.
- 0.4.2: the grade reads the screen finite and never darkens a pixel below a quarter of itself (black
  boxes round sun glints on Aquilo's and Gleba's water).
- 0.4.1: no clouds or cloud shadows on space platforms.
- 0.4.0: a real sunrise and sunset: exposure, sky-lit ambient, fog, shadows and the grade keyed to the
  sun, dawn mist, clouds that catch the light, a blue hour; one Sunrise and sunset slider.
- 0.3.0: the look owns its clouds, TAA and roughness limiter (add-on API 1.4).
- 0.2.2: a roughness floor of 0.55; TAA off by default (shader-animated inserter arms and belts flickered
  under it).
- 0.2.1: the roughness limiter while the look is on, bloom capped per pixel, calmer bounce light.
- 0.2.0: the add-on is the look; sharpening faded with distance; clouds in the sky and their shadows.
- First version with Zenith's shader API (add-on API 1.3).
