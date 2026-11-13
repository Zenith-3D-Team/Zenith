# Cinematic shaders (a Zenith add-on)

A look for [Zenith](../../README.md) that trades Factorio's flat, even picture for a filmic one with
more depth and detail. Needs Zenith's add-on API 1.5 (`api.shaders`, docs/ADDONS.md).

- AgX tonemapping and a film contrast curve: highlights roll off instead of clipping
- bloom: lamps, fire, lasers and molten metal glow
- soft shadows (the sun's angular size), from a sun that crosses the sky
- a real sunrise and sunset: the sun reddens as it sinks and sets in the west, shadows grow long, a
  blue hour follows, and the exposure, haze, shadows and grade all follow the sun's height; dawn has
  its own mist. Each planet has its own colours. One slider, Sunrise and sunset, sets how much
- ambient occlusion (SSAO) in corners and under machines; bounce light (SSIL) as its own option,
  off by default
- the sky's reflection on metal
- depth haze that grows with distance
- temporal anti-aliasing as an option (off by default: it softens moving belts), so far detail doesn't shimmer as the camera moves
  (your own anti-aliasing setting comes back when the add-on is off). MSAA is off while the look is on:
  Zenith draws SMAA in its place, since the grade pass reads a depth MSAA blurs at every edge (from the
  next start, when the add-on is switched on in a running game)
- one grade pass (`shaders/cinematic_grade.gdshader`): local contrast and sharpening on what the
  camera looks at, faded out with distance (where they made fine detail shimmer), the far distance
  softened a little, saturation and vibrance, cool shadows and warm highlights, a soft vignette, a
  touch of chromatic aberration at the edges and fine film grain
- Factorio's own colour lookup for each planet and time of day stays on
- on a space platform, space stays near black with sharp stars: no haze (Zenith turns fog off in
  space for every look), and the grade neither softens nor adds local contrast to the backdrop

## Installing

Put this folder (or a zip of it) in Zenith's `addons` folder and switch it on in the Add-ons menu:
the add-on is the look, so the world is drawn with it while it is on, and switching it off brings
back Zenith's Factorio look (which has no settings of its own). Its page in the Add-ons menu has its
sliders: grade strength, bloom, depth haze, softening the far distance, vignette, film grain,
temporal anti-aliasing, ambient occlusion, bounce light, soft shadows, whether the sun moves, and how
strong sunrise and sunset are.

It costs GPU time: ambient occlusion most (about 1-1.5 ms a frame on a desktop graphics card at a
busy base: Godot's depth pre-pass then writes every pixel's normal), bounce light about as much again
(off by default; for Ultra-class cards), then bloom, the grade pass (one full-screen read and write)
and the haze. Turn ambient occlusion off on its page first if the frame rate drops.
