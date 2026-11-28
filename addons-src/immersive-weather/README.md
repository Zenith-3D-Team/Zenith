# Immersive Weather

Dynamic Nauvis-only weather add-on for Zenith (requires Add-on API `1.8`).

## Included features (version 0.3.5)

- **12 Nauvis weather states** (7 dry/sky + 3 rain + 2 thunderstorms) with smooth transitions and natural progression:
  - **Open Skies** — cloudless deep-blue sky, full crisp sun, brightest stars at night, calm breeze.
  - **Sunny** — scattered high wisps, bright sunlight, gentle breeze.
  - **Fair** — classic drifting cumulus clouds, balanced cloud shadows and god rays.
  - **Partly Cloudy** — heavier broken cloud cover, shifting sunbeams, stronger breeze.
  - **Hazy Sun** — warm sunlit atmospheric haze, softer shadows, light distance mist.
  - **Overcast** — thick grey-white cloud deck, diffuse lighting, softened shadows, steady wind.
  - **Heavy Overcast** — dark brooding ceiling, low sun contrast, denser mist, gusty wind.
  - **Light Drizzle** — fine light rain under a grey ceiling; surfaces dampen and the first small puddles form.
  - **Steady Rain** — steady rainfall, dark soft-lit sky, wet ground and models, spreading puddles with ripples.
  - **Heavy Downpour** — dense gusty rain, dim stormy light, soaked surfaces and large rippling puddles.
  - **Thunderstorm** — dark stormy sky, heavy rain, cloud-to-ground 3D lightning bolts, sheet flashes, speed-of-sound delayed thunder, and optional subtle rumble.
  - **Severe Thunderstorm** — intense tempest with frequent multi-fork lightning strikes, bright storm-lit clouds, howling gusts, and heavy rain.
- **Wet surfaces & puddles:** Rain soaks terrain and models over ~30-60 s, then puddles collect; when it stops, surfaces dry over the **Drying time** setting (default 4 min, faster in bright sun) while puddles linger longest. Wetness and puddles persist per save.
- **Vehicle puddle splashes & wakes:** Cars, tanks, and spidertrons driving through puddles kick up 3D splash sheets, droplets, and spray mist, trigger expanding directional terrain puddle wakes/ripples, play synthesized procedural spray and puddle impact sounds on the Effects bus, and add subtle driver-seat impact shudder (wet ground without puddles kicks up rear spray mist at speed; disableable with `--puddle-splashes=off`).
- **3D rain, splashes & lightning:** GPU-driven rain volume and surface splashes plus visual-only forked 3D lightning bolts, pooled local strike lighting, cloud/ambient flashes, and speed-of-sound delayed thunder cracks and rolls (zero Factorio damage).
- **Nauvis-only gating:** Automatically disables on Vulcanus, Fulgora, Gleba, Aquilo, and space platforms, and restores cleanly when switching back to Nauvis.
- **Storm wind:** overcast skies, rain and storms get a broad wind roar made at start (no files), with gusts at random times and heights that never repeat the same way; the old whistle loop is only a quiet layer at the top of the strongest gusts (**Audio > Storm wind**: New / Classic, or `--weather-wind=old`).
- **Bundled wind, rain & thunder audio (rain and wind softened in 0.3.5; **Audio > Rain and wind tone** or `--weather-sounds=original` brings the files back as recorded):** Seamless wind and rain ambient loops plus 8 thunder cracks and distant rolls from **Weather Elements** by Helton Yan (CC BY 4.0 — see [CREDITS.md](CREDITS.md)). Optionally uses Factorio Space Age's own rain and thunder sounds from your install when enabled.
- **Weather Control Panel:** Press `Alt+F9` (rebindable in **Settings -> Controls**) to inspect weather, lock any state, trigger instant/smooth transitions, click **Dry now**, or trigger a manual lightning **Strike**.

## Settings overview

Find these under **Settings -> Add-ons -> Immersive Weather**:

- **Weather Cycle:** mode (Dynamic/Locked), locked weather, weather duration, transition time, drying time, allow hazy / overcast / rain / thunderstorms.
- **Sky & Atmosphere:** cloud strength, lighting mood, fog & mist, wind strength.
- **Rain Effects:** rain on/off, rain density and visibility, ground splashes and splash density.
- **Wet Surfaces & Puddles:** wet ground / models, wetness strength, wet darkening, ground and model puddles (amount, size, reflectivity), rain ripples, vehicle puddle splashes, vehicle splash strength, and vehicle puddle impact shudder.
- **Thunderstorms & Lightning:** lightning on/off, 3D lightning bolts on/off, strike frequency, flash brightness (`0` disables bright full-sky flashes for photosensitivity comfort), optional camera thunder rumble + strength, and a strike list file (below).
- **Audio:** master, wind, rain, and thunder volumes, storm wind (New roar with gusts / Classic whistle loop), vehicle puddle audio (wet spray and puddle impacts on the Effects bus), plus an opt-in to use Factorio Space Age's rain/thunder sounds from your own install (falls back to the bundled Weather Elements audio; see [CREDITS.md](CREDITS.md)).

## Weather timeline (weather on a cue)

For a filmed scene the weather can follow a timeline from the scene's cue instead of the Weather
cycle setting: give a JSON file with `--weather-timeline=<file>` on Zenith's command line (a relative
path is read from the add-on's folder). The cue is `api.world.cue_tick()`: a cue the game sets while
running (a Factorio mod's `remote.call("zenith", "set_cue", game.tick)`, add-on API 1.92), else
`--cue-tick=<game tick>`.

```json
{"before": "fair", "timeline": [
	{"at": 0, "weather": "thunderstorm", "over": 6}
]}
```

- `before`: the weather until the cue (and while there is none), set at once, dry as that weather is.
  Without it, the first entry's weather.
- Each entry: `at` game ticks after the cue (60 a second at normal speed), `weather` a preset's id
  (`open_skies`, `sunny`, `fair`, `partly_cloudy`, `hazy_sun`, `overcast`, `heavy_overcast`,
  `light_drizzle`, `steady_rain`, `heavy_downpour`, `thunderstorm`, `severe_thunderstorm`), `over` the
  change's seconds of game time (0 at once). The change blends clouds, light, wind, rain and storm as
  the add-on's own transitions do; wetness and puddles come on with the rain as they always do.
- Timed on the game's tick: a paused or slowed game holds the change, every take matches; the tick
  going back before the cue (the save loaded again) sets `before` again; a client joining late shows
  the change as it is by then. An entry starting while the last is still changing snaps that one to
  its nearer end first.
- While a timeline is given it decides the weather (the Weather cycle and the panel's choices are
  overridden; the status says "Timeline"); without the file nothing changes. Timed strikes work
  beside it, and while a timeline is loaded a strike list waits for the cue rather than counting from
  the first tick. An example: [timeline-example.json](timeline-example.json).

## Timed strikes (a strike list)

For a filmed scene that has to look the same on every take, strikes can be timed on the **game's
tick** instead of falling at random. Give a JSON file with `--weather-strikes=<file>` on Zenith's
command line, or in the **Strike list (file)** setting (the command line wins; a relative path is
read from the add-on's folder). The scene's start is the cue tick, `--cue-tick=<game tick>` (read by
every add-on through `api.world.cue_tick()`, add-on API 1.91; the list's own `"cue_tick"` is used
when there is no `--cue-tick`, else the tick the list first sees, with a line in the log).

```json
{"strikes": [
	{"tick": 300, "x": 18, "y": 6, "kind": "bolt", "strength": 1.3, "seed": 7},
	{"tick": 600, "x": -60, "y": 35, "kind": "sheet"}
]}
```

- `tick`: game ticks after the cue tick (60 a second at normal speed). `x`, `y`: the map tile, as
  Factorio's (x east, y south). `kind`: `bolt` (default) or `sheet` (a cloud flash, no bolt).
  `strength` (optional, 0 to 2, default 1): scales the flash and the thunder. `seed` (optional,
  default the entry's place in the list): the bolt's shape; the same seed draws the same bolt.
  A bare array of entries works too. An example: [strikes-example.json](strikes-example.json).
- A strike fires when the game reaches its tick, so a paused or slowed game holds or slows them.
  Entries already past when the list first sees the game are skipped; one more than 2 s of ticks
  late (a jump) is skipped, not fired. Loading the save again (the tick goes back) plays the list
  again from there, for another take.
- While a list is loaded, random strikes are off, and listed strikes fire whatever the weather (lock
  a storm for rain and clouds). Thunder's delay follows the strike's distance to the camera.
- Photosensitivity settings still apply: lightning off fires nothing, bolts off turns bolts into
  sheet flashes, flash brightness scales them. Without a list nothing changes.
- Needs Zenith with add-on API 1.91 (`api.world.tick`); an older Zenith keeps the random storm and
  says so in the log.

## Changes

See [CHANGELOG.md](CHANGELOG.md).

## Running in development

```bash
godot --path client -- --addons=addons-src/immersive-weather
```
