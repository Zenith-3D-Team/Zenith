# Immersive Weather: changes

Newest first. Versions before 0.3.2 are in Zenith's history.

## 0.3.5

Softer rain and wind (`sounds/`, `scripts/weather_audio.gd`, `main.gd`).

- The three rain loops and the two wind loops are tilted down from about 1.5 kHz (-6 dB at 4 kHz, -11 dB
  at 8 kHz and above), a little body kept at 300-600 Hz, and set so every loop's peaks are at -6.5 dB or
  lower (they were at -1.3 to -4.9 dB), made circularly so the loops stay seamless, and encoded at Vorbis
  quality 7 (about 224 kbps, they were 82-112 kbps).
- Setting **Audio > Rain and wind tone** (Soft / Original) and `--weather-sounds=original` play the files as
  first bundled (`sounds/original/`).
- The generated storm wind (0.3.2) is unchanged: its roar is under 500 Hz and its rush under 2.6 kHz.

## 0.3.4

Vehicle puddle splashes, terrain puddle wakes, procedural splash audio, and driver-seat shudder (`scripts/weather_puddles.gd`, `shaders/vehicle_splashes.gdshader`, `scripts/puddle_audio.gd`, `scripts/weather_lightning.gd`, `main.gd`).

- Cars, tanks, and spidertrons driving through puddles kick up 3D splash sheets, droplets, and mist, emit expanding directional terrain puddle wakes/ripples via `api.weather.add_puddle_ripple`, and kick up rear spray mist on wet ground at speed.
- Procedural stereo wet-spray loop and heavy/light water impact one-shots synthesized at game start on a worker thread (no audio files) and played on the Effects bus.
- Subtle driver-seat impact shudder on puddle entry combined with thunder camera rumble via `weather_lightning.gd`.
- New settings under **Wet Surfaces & Puddles** (`vehicle_puddle_splashes_enabled`, `vehicle_puddle_splash_strength`, `vehicle_puddle_rumble_enabled`) and **Audio** (`vehicle_puddle_audio_enabled`); `--puddle-splashes=off` disables vehicle splashes and terrain wakes for a run.

## 0.3.3

Weather on a cue (`scripts/weather_director.gd`, `main.gd`).

- `--weather-timeline=<file>`: a JSON timeline of weathers from the scene's cue (README, "Weather
  timeline"): `before` until the cue, then each entry's weather over its `over` seconds of game time,
  with the add-on's own transitions (clouds, wind, rain, wetness coming on as in a natural change). It
  overrides the Weather cycle setting while given; without it nothing changes.
- The cue can come from the game while running (Zenith's add-on API 1.92: a mod's
  `remote.call("zenith", "set_cue", tick)`); a strike list places itself again from a new cue, and
  waits for one while a timeline is loaded (before, it counted from the first tick it saw).

## 0.3.2

Storm wind sounds like a storm (`scripts/storm_wind.gd`, `scripts/weather_audio.gd`).

- The storms' wind was one 18 s whistle loop ("WE Heavy Wind Whistle 7"): a third-octave band round
  540 Hz held a quarter of its sound, 5% of it under 150 Hz, the same in both ears, 4 dB of movement,
  the same gusts every 18 s, pitched up with the wind. Now overcast skies, rain and storms play a broad
  roar (noise made at the start on a worker thread, about 0.2 s, no files) with gusts at random times
  and heights driving its loudness and a moving band of "whoosh"; left and right differ; the whistle is
  only a quiet layer at the top of the strongest gusts. Gentle breezes are as before.
- Setting **Audio > Storm wind** (New / Classic) and `--weather-wind=old` bring back 0.3.1's loop.
