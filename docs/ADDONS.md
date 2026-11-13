# Writing add-ons for Zenith

An add-on is a small program that runs inside Zenith, the 3D view for Factorio, and adds to what
the client does: a camera for filming, an overlay, a window of your own. It is written in
GDScript, Godot's scripting language, and gets one object from Zenith, the add-on API, through
which it reads what the client knows of the game and changes what the client shows.

**Nothing an add-on does changes the game.** The API only reads the client's own copy of the
world and moves the camera, the interface and what is drawn. Everyone else in the game sees
nothing of it, and Factorio's simulation is untouched.

The [Cinematic camera](https://github.com/unjustodin/Zenith-Cinematic-Camera) add-on (free
camera, timelapses, tracking shots, paths, idle mode, a recorder camera filming in the background,
screenshots at full detail) is the worked example: everything below is what it uses.

Recording a viewport of your own: Godot's movie writer (`--write-movie`) only films the whole
window at a fixed rate from start-up, so an add-on records its own `SubViewport` instead: draw it
only when a frame is due (`UPDATE_ONCE`), copy it back without waiting
(`RenderingDevice.texture_get_data_async` on the viewport's texture: `get_image()` waits for the
graphics card, 13-20 ms a 1080p frame), and encode on worker threads. The Cinematic camera's
`scripts/recorder.gd` and `scripts/avi_writer.gd` (a Motion-JPEG `.avi`) show how.

## Installing an add-on

An add-on is a folder with an `addon.json` in it, or a `.zip` of that folder. Put the folder or
the zip in one of these places:

| Where | For |
|---|---|
| `%APPDATA%\Godot\app_userdata\Zenith\addons\` (Windows), `~/.local/share/godot/app_userdata/Zenith/addons/` (Linux) | Your own add-ons, kept across Zenith updates |
| `addons\` beside `Zenith.exe` | Add-ons that come with a copy of Zenith |
| `--addons=<folder>` on the command line | Development: an add-on's own folder or zip, or a folder of add-ons (several, separated by commas) |

A zip is used as it is, without unpacking it by hand: `addon.json` at the zip's root or one
folder down (as Factorio's mod zips: `my-addon_1.0.0.zip` holding `my-addon/addon.json`). Zenith
unpacks it into `user://addons-cache/<id>/` when it starts the add-on, again only when the zip
changes, so the add-on's relative preloads work as they do from a folder. A broken zip, or one
without an `addon.json`, is listed with the reason. When an add-on with the same id is found
twice (a folder and a zip, two zips), the newer version is used (a folder on a tie, and one given
with `--addons` always), and its page in the Add-ons menu names the copy left out.

Zenith looks for add-ons when it starts. The **Add-ons** menu (the main menu, the game menu Esc
opens, and Settings) lists them, each with its version, whether it's on and the reason when one
couldn't load; clicking one opens its page: its switch (it applies at once, in a game too), its
settings (`api.settings`, API 1.1), the options it builds itself (`api.ui.set_options`) and its
keys. The main menu's **Mods** window lists them too, under *Zenith add-ons*. An add-on given with
`--addons` is always on, and takes the place of an installed one with the same id.

The downloads come with three of Zenith's own add-ons in their `addons/` folder: the
[Cinematic camera](https://github.com/unjustodin/Zenith-Cinematic-Camera/releases), switched on, the
Cinematic shaders (the Cinematic look), switched on, and
[Terrain Elevation](https://github.com/unjustodin/Terrain-Elevation/releases), switched off until you
turn it on in the Add-ons menu. `addons/bundled.json` holds those first states (`{"id": true}`);
once you switch an add-on yourself, your choice is kept instead.

An add-on's keys are on its page of the Add-ons menu and in **Settings → Controls**, under the
add-on's name, and are rebound there like Zenith's own.

## The folder

To share an add-on, zip its folder: `my-addon_<version>.zip`, holding `my-addon/` (or the files
at the zip's root).

```
my-addon/
  addon.json
  main.gd          the entry script
  scripts/...      anything else it needs
```

`addon.json`:

```json
{
	"id": "my-addon",
	"name": "My add-on",
	"version": "1.0.0",
	"api": 1,
	"entry": "main.gd",
	"author": "you",
	"description": "One line for the Mods window."
}
```

| Field | |
|---|---|
| `id` | Lower case letters, digits, `-` and `_`. Names the add-on's keys, data folder and node |
| `name`, `version`, `description`, `author` | Shown in the Add-ons menu, the Mods window and Settings → Controls |
| `api` | The add-on API it was written for: `1` (any 1.x), or `1.1` to `1.6` (needs the additions marked with that level below). Zenith refuses an add-on that needs a newer API than it has, and says so in the Add-ons menu: update Zenith |
| `entry` | The entry script, a `.gd` file in the folder |

This page describes add-on API **1.6**: version 1 with additions that keep every 1.0 add-on
working. The additions are marked *(1.1)* to *(1.6)*. An add-on that wants to run on a Zenith with 1.0 too
asks for `"api": 1` and checks before using them:

```gdscript
if api.get("level") != null and api.level >= 1.1:
	api.settings.add("distance", "number", 60.0, "Distance", {"min": 10, "max": 300, "unit": "tiles"})
```

## The entry script

The entry script extends `Node`. Zenith adds it to the scene when the add-on starts and calls
`addon_start(api)`; when the player switches the add-on off it calls `addon_stop()` (if there is
one) and frees the node. Everything set up through the API (the camera, keys, windows, requests)
is undone by Zenith then, so `addon_stop` only needs to save the add-on's own state.

```gdscript
extends Node

var api


func addon_start(a) -> void:
	api = a
	api.keys.add("hello", "Say hello", [KEY_F10])


func _unhandled_input(event: InputEvent) -> void:
	if api.keys.pressed(event, "hello"):
		var me: Dictionary = api.world.character()
		api.ui.message("Hello from %s" % str(me.get("position", "the menu")))
```

The node gets `_process`, `_input` and `_unhandled_input` as any node does, and gets input before
Zenith's own controls and menus. Add-ons start at Zenith's start-up, before any game: listen to
`api.game_started` and `api.game_ended`, and check `api.in_game()`.

A few GDScript notes:

- Don't use `class_name`: scripts loaded from outside Zenith's own project can't rely on Godot's
  global class list. Load your other scripts with a path relative to the script doing it
  (`const Orbit := preload("scripts/orbit.gd")`) or with `api.load_script("scripts/orbit.gd")`.
- Zenith's own scripts can be preloaded by their `res://` paths, but only the API below is
  promised to stay the same within an API version.
- Don't infer a type from a Variant (`var x := api.world.trains()` is an error): write the type
  (`var x: Array = ...`) or leave it out (`var x = ...`).

## The API

`api` has these parts. Positions are Godot's: `x` east and `z` south, in tiles, `y` up; Factorio's
`(x, y)` is `(x, z)` here and the ground is at `y = 0`.

| | |
|---|---|
| `api.version` | The add-on API this Zenith offers (1) |
| `api.level` | *(1.1)* The exact level, with the additions within the version (1.2). Absent on 1.0 |
| `api.zenith_version` | Zenith's version, for messages |
| `api.id`, `api.name`, `api.addon_version`, `api.dir` | From your `addon.json`, and the add-on's folder |
| `api.in_game()` | A game is on |
| `api.game_started`, `api.game_ended` | Signals |
| `api.note(text)` | A line in Zenith's log, marked with the add-on's id |
| `api.load_script(path)` | One of the add-on's own scripts, by its path in its folder |

### Camera: `api.camera`

One add-on has the camera at a time. While it does, the player's own view (the angled view,
Factorio's view, first person, the zoom) is kept as it was, and comes back exactly so.

| | |
|---|---|
| `take(options = {})` | Takes the camera; false when it can't now (no game, another add-on has it, a ride to a space platform, VR). Options: `"input"` (default `true`: the player's controls are off and the character stops; your `"camera"` keys work), `"focus"` (`"camera"`, the default: the world loads round the ground in the middle of the picture; `"character"`: round the character) |
| `release()` | Back to the player's view |
| `has()`, `has_input()` | Whether this add-on has it, and the player's controls are off |
| `node()` | The `Camera3D` itself while you have it (else null): set its `global_transform`, `fov`, `projection`, `size`, `near`, `far`, `attributes` (depth of field). All of it is put back on release |
| `set_transform(t)`, `look_from(eye, at)` | Where it is and where it looks |
| `transform()`, `fov()` | The camera now (also while the player has it: where to start a shot from) |
| `player_view()`, `player_fov()`, `player_orthographic()` | Where the player's own view would put the camera now: glide there before `release()` for a seamless hand-back |
| `set_focus(point)` | Where the world loads and live data is asked for (a `Vector2` in tiles), or `null` for take()'s choice |
| `focus()` | The point the world is loaded round now |
| `capture_mouse(on)`, `mouse_captured()` | The mouse hidden and captured (its motion arrives as `InputEventMouseMotion.relative`, for mouse look) while you have the camera; Zenith gives it back while a window or menu is open |
| `ground_point(screen_pos)`, `center_ground()` | The ground under a point of the screen, or its middle (`null` above the horizon) |
| `lost` | Signal: Zenith took the camera back (a ride to a platform started, the game ended) |

The world is only loaded and sent round one point. A camera far from the character makes Zenith
load the world there (the bridge sends what is near the focus), so flying far is fine; but
anything you read through `api.world` is what is near the focus.

### Keys: `api.keys`

| | |
|---|---|
| `add(name, label, keys = [], context = "global")` | A control in Settings → Controls under your add-on's name. `keys`: up to two defaults, as key codes with modifier masks (`KEY_F8 \| KEY_MASK_SHIFT`) or names (`"Shift+F8"`). Returns the input action's name |
| `pressed(event, name)`, `released(event, name)` | The event pressed or let go of the control |
| `held(name)` | It is held down now |
| `text(name)` | Its keys for hints: `"F8"`, `"W / Up"` |
| `conflicts(name)` | Other controls sharing one of its keys where both work |
| `action_of(name)` | Its input action, for `Input` |

Where a control works (`context`):

- `"global"`: always in a game. Its defaults mustn't be any of Zenith's keys or another add-on's
  global keys: a default that is already taken is left unbound (the log says so), so an add-on
  can't take a key from the player. They can still bind it in Settings → Controls (it shows red).
- `"camera"`: only while your add-on has the camera with the player's controls off. These may
  share keys with Zenith's controls (WASD to fly), and Zenith doesn't see those keys meanwhile
  (E flies up instead of opening the inventory).<!-- dev --> They rest while Zenith's debug menu
  (Ctrl+F12, in development builds) is open, still kept from Zenith; the mouse is shown for the
  menu, over your captured or hidden mouse and a hidden interface, and goes back as you had it when
  the menu closes.<!-- /dev -->

Neither works while the player types in a text box or Zenith's menu is open. A control is
pressed when its modifiers are held; more modifiers held only count against it when another of
your controls has exactly those (so Shift+= still counts as `=`, but Shift+F8 isn't F8 when
Shift+F8 is a control of its own).

### The world, read-only: `api.world`

What the client knows of the game: buildings in the chunks drawn round the focus, moving things
and trains within the entity distance of it (Settings → Graphics), the players. Every function
returns copies.

| | |
|---|---|
| `character()` | The client's own character: `{unit, position, forward, vehicle, visible}` (`{}` outside a game) |
| `movers(types = [])` | Moving things of these prototype types (all when empty): `[{unit, type, name, position, forward}]`. Types: `locomotive`, `cargo-wagon`, `fluid-wagon`, `artillery-wagon`, `car`, `spider-vehicle`, `character` (other players), `logistic-robot`, `construction-robot`, `combat-robot`, `unit` (biters, spitters), `spider-unit`, `rocket-silo-rocket`, `cargo-pod` |
| `mover(unit)` | One of them, or `{}` when it's gone or too far |
| `trains()` | `[{id, state, manual, speed (tiles a tick, negative backwards), station (the stop's unit, 0 none), destination, carriages (units, front first)}]` |
| `train_of(unit)` | The train a carriage belongs to |
| `players()` | `[{index, name, connected, color, unit, surface, me}]` |
| `rockets()` | Rockets climbing from their silos now, as drawn: `[Vector3]` |
| `chunks()` | The chunks drawn now (`Vector2i`, 32 tiles each) |
| `entities_in_chunk(chunk, types = [])` | Its buildings, trees, rocks...: `[{unit, name, type, position (Vector2), direction (0-15), working (true, false, or null)}]` |
| `entities_near(point, radius, types = [])` | The same round a ground point |
| `focus()` | The point the world is loaded round |
| `hold_chunks(on)` *(1.6)* | While on, chunks the camera leaves aren't unloaded: the world keeps everything already drawn, as the bridge last sent it (it no longer updates chunks out of the view), and the chunks round the new focus still come. For a screenshot or a film of a long flight. Capped by memory: at most 1,600 chunks held past the view (a 40 x 40 square, about 1,300 tiles across), and fewer once the computer has under 1 GB of memory free; past either the held chunks farthest from the focus go first, and Zenith's log says so once. Held while any add-on asks; switching the add-on off lets them go |
| `holding_chunks()`, `held_chunks()` *(1.6)* | Chunks are held now (by any add-on); how many are held past the view |
| `daytime()`, `darkness()` | The time of day as drawn (0 noon, 0.5 midnight) and how dark it is (0 to 0.85) |
| `planet()`, `on_platform()` | The planet shown, and whether it's a space platform |

A chunk can hold thousands of entities: spread big searches over several frames.

### Events: `api.events`

Worked out by the client from what the bridge already sends; nothing extra is asked of the game.

| Signal | |
|---|---|
| `train_departed(train_id, stop_unit, position)`, `train_arrived(...)` | A train near the focus left a stop or arrived at one |
| `rocket_launched(silo_unit, position)` | A launch was ordered on the surface shown (it lifts off a few seconds later) |
| `fight_started(position, size)`, `fight_ended(position)` | Enemies started attacking, or turrets firing, where nothing had for 10 s; the fight ended after 10 s of quiet |
| `platform_departed(platform, location)`, `platform_arrived(platform, location)` | A space platform left a planet or arrived at one |
| `player_joined(name)`, `player_left(name)` | |

`recent(seconds = 60)` lists the last events, newest first, each `{kind, time, age, position, ...}`
with the signal's values by name; `fights()` the fights going on, `[{position, since, size}]`.

### What is shown: `api.view`

| | |
|---|---|
| `hide_interface(on)`, `interface_hidden()` | Zenith's interface, its icons over entities (alerts, no power) and the cursor hidden for a clean shot, including ones that appear later. Your windows hide too; your overlay layer stays |
| `save_frame(path, viewport = null)` | The window (or a viewport of yours) saved as a PNG, written on a worker thread so a frame every few seconds costs the game little. `path`: `user://...` or a full path; folders are made |
| `frames_pending()` | Frames still being written |
| `world_3d()` | The 3D world, for a `SubViewport` and `Camera3D` of your own (a second shot drawn off screen) |
| `keep_drawing(min_fps)` | *(1.1)* For an add-on recording in the background: Zenith isn't minimised when its window loses focus (a minimised window draws nothing, not even your viewport), and *Hold the game at 60 UPS* never caps the frame rate under `min_fps` (the player's own cap still stands). `0` gives it back; switching the add-on off does too. Zenith keeps drawing behind other windows by itself |
| `keeping_drawing()` | *(1.1)* |
| `hold_daytime(t)`, `daytime_held()` | The time of day as drawn held still (0 noon, 0.25 dusk, 0.5 midnight); negative lets it run. The game's own time runs on |
| `screen_size()` | |
| `full_detail(on)` *(1.6)* | Everything drawn at its most until turned off (below). Nothing is saved: the player's settings come back as they were. It costs frames and the game's time while it lasts: for a shot, not to play with |
| `full_detail_on()`, `full_detail_settled()` *(1.6)* | It is on (for any add-on); everything it asked for is drawn in the camera's view, for an add-on that takes its own pictures with `save_frame`. Chunks count only in the view (grown by 8 tiles), and one that hasn't arrived stops counting once the bridge has sent no new chunk for 3 s (it sends them as its work budget allows; one it never sends would hold the shot to its timeout); chunks off the view keep arriving after |
| `screenshot(path = null, options = {})` *(1.6)* | A screenshot: hides the interface (as `hide_interface`, and add-ons' own layers and Zenith's debug menu too), turns full detail on and waits until everything is drawn, takes the picture, puts the interface back and writes a PNG on a worker thread. Returns the file's path at once (`""` while another is being taken, or without a game). `path`: a `.png` file, a folder, or `null`: `zenith-<n>.png` in the player's Pictures folder, in `Zenith` (`%USERPROFILE%\Pictures\Zenith\` on Windows; `user://screenshots/` where the system has no Pictures folder), the next free number. Zenith shows *Screenshot saved* with an *Open folder* button. The picture is of the moment it was asked for: until it is taken Zenith's own view of time stands still (moving things, robots, trains, vehicles, creatures, the character, belt items, inserter hands, machines' moving parts, shots and effects, the time of day; the bridge's updates of them wait and are caught up after, in order), while the game runs on so the bridge can send the view's chunks, which are drawn as they come. Not held: animations the shaders run on their own clock (water, clouds and their shadows, grass in the wind, belts' surfaces, robots' and creatures' idle motion, smoke and lights pulsing); in a still picture they only make it a few seconds later there. Options: `folder` (where, when `path` is null), `size` (a `Vector2i`, or `[width, height]`: the picture's size in pixels, up to 16384 each way, e.g. `Vector2i(7680, 4320)` for 8K; a size other than the window's is drawn again off screen from a copy of the camera with the window's anti-aliasing, TAA (given 16 frames to settle), level of detail, shadows and filtering, the world's environment, sky and look passes, at that size whatever the window's render scale. The window's height is framed: a picture of another shape than the window shows more or less at the sides, as games do at a fixed resolution. MSAA is stepped down where its samples would take over 1.5 GB of video memory (4x at 8K), and if the picture can't be drawn it is tried without MSAA, then the window is taken), `scale` (1 to 4: that many times the window's size, when there's no `size`; 1), `full_detail` (true), `hide_interface` (true), `overlays` (false: your own layers are hidden too), `timeout` (seconds to wait for full detail at most; past it the picture is taken as it is and the log says what was still drawing in the view. Without it Zenith waits while things still come: the picture is taken as it is once nothing new has come for 20 s (no chunk arrived, nothing fewer left to draw), or after 5 minutes. What it waits for is fixed when it starts: the chunks in the camera's view, out to the bridge's largest square, nearest the camera first; the chunks already loaded there stay, and the camera or the character moving meanwhile changes nothing. The progress says how many of them are still to come (a count that only goes down), with a bar that only moves forward and, once it can tell, about how long is left. Chunks are asked for 256 at a time and the bridge is put in photo mode meanwhile (more chunks read a tick, within a work budget kept to what holds the game near 60 UPS); a view zoomed far out can still take a minute or more. A chunk the bridge never sends stops counting once every chunk has been asked for, none has arrived for 5 s and its work report has no chunks queued (15 s without a report); while it waits, Zenith's main thread may take frames of up to 50 ms so the wider view fills faster), `pause` (true: the Factorio game is held while the picture is taken and let go after it, unless the player had paused it already. It is held through the bridge (`/f3d-debug hold`): Factorio's slowest game speed, 0.01, rather than a tick pause, so the bridge still ticks (about once every 1.7 s), reads the client and puts the speed back; this works in single-player (hybrid) as well as on servers. It is held once the bridge has sent the chunks in view, since a held game sends hardly any, and moving things hold still at the game's last positions. Where the console's rule refuses (multiplayer, not an admin) the picture is taken with the game running and the log says why. The game is let go after the picture, when it is cancelled or fails, when the game ends, at the latest `timeout` (5 minutes without one) + 15 s after holding, and by the bridge itself 30 game ticks (about 50 s) after the hold if the client never says) |
| `screenshot_busy()` *(1.6)* | One is being taken. Meanwhile Zenith shows its progress at the bottom of the screen (never in the picture), holds the camera where it was when the shot began (whoever moves it; an add-on with its own camera should leave it alone too while this is true), keeps the mouse from Zenith's camera and menus and the player's controls off, and Esc cancels it |
| `screenshot_cancel()` *(1.6)* | Stops the one being taken: the game let go, full detail and the interface back, nothing written. False when none is being taken |
| `screenshot_cancelled(path)` *(1.6)* | Signal: a screenshot was cancelled (`screenshot_cancel` or Esc) |
| `screenshot_saved(path, ok)` *(1.6)* | Signal: the PNG was written (or couldn't be) |

**Full detail** *(1.6)* lifts every draw distance and limit for as long as it is on (Zenith's
`scripts/world/full_detail.gd`):

- Settings → Graphics at the tops of their sliders, held without being saved: view distance (at
  least 20 chunks; the player's own when it is longer, so nothing already drawn goes), entity distance (256 tiles: moving things and
  machine states), belt item distance (640 tiles) and belt updates (Unlimited), Items in 3D (every
  item a model), decoratives on at full density out to 320 tiles, 3D grass *Far*, the shadow
  distance (1,000 tiles), Level of detail *High*, and far chunks not merged (every loaded chunk drawn
  whole).
- Every model at its own full level wherever it is, switched without the level-of-detail fade;
  Godot's own LODs off (the viewport's `mesh_lod_threshold` 0); belts without their far stand-ins;
  ground clutter drawn whole out to its distance instead of thinning past 80 tiles.
- Lights: every lit lamp glows (up to 65,536) and the nearest 448 have a real light (48 otherwise;
  448 stays under Godot's 512 clustered lights in view); furnace fires and lab glows out to 400 tiles
  with 48 lights (40 tiles and 16 otherwise). Lights keep the shadows they have (lamps cast none).
- *Hold the game at 60 UPS* and add-ons' lighter updates (`api.updates`) hold nothing back.
- The camera's far plane at least 6,000 tiles, and the 3D resolution at least the window's.

A screenshot also asks for every chunk its camera sees, not only those within the view distance of
the focus: a view zoomed far out or over the horizon reaches past it. The bridge takes one square of
chunks, up to 101 x 101 (50 chunks each way), so the square is fitted round the view distance's and
the camera's view, or round the camera's view alone (its part nearest the camera) when both don't
fit; within it only chunks in the view distance or in the picture are asked for, so none behind the
camera hold up the ones in it. Past that square the ground ends.

Settled means: at least a second since it came on (the bridge sends the wider distances' moving
things, belt items and chunks over its next updates), then ten frames in a row with every chunk asked
for subscribed and drawn (ground meshed, none part-built, no level cross-fading), no model being read
or simplified, decoratives and 3D grass built, belt items' models read and the lamps refreshed.

### Windows and messages: `api.ui`

Windows look like the rest of Zenith (Factorio's frames, title bars, buttons, sliders, from the
player's own install). Their title bar drags them; the × and Esc close them.

| | |
|---|---|
| `window(title)` | A new window, hidden: `{frame, box, close}`. Put its content in `box` |
| `show(frame, on = true)`, `toggle(frame)`, `is_open(frame)` | |
| `layer()` | A `CanvasLayer` of your own over the world (letterbox bars, a recording mark); it stays when the interface hides |
| `message(text)` | A message over the quickbar, as Zenith's own |
| `typing()`, `menu_open()`, `windows_open()` | The player is typing; Zenith's menu is open; a window is open |
| `set_options(builder)` | Options you build yourself, under *More options* on your page of the Add-ons menu and in the Mods window: `builder` is called with an empty `VBoxContainer`. For plain values, `api.settings` (1.1) is simpler |
| `label`, `heading`, `note`, `button`, `checkbox`, `slider`, `dropdown`, `textbox`, `row` | Controls in Zenith's style (see `client/scripts/addons/addon_ui.gd`) |
| `kit`, `menu_kit` | Zenith's UI kits, for anything else |

### Settings: `api.settings` *(1.1)*

Settings you declare are shown on your page of the Add-ons menu, with your keys, each with a
*Default* button. Their values are kept for you in Zenith's settings file (a section of its own
per add-on) across games and updates.

| | |
|---|---|
| `add(id, type, default, label, options = {})` | Declares a setting and returns its value now (kept, else the default). Types: `"bool"`; `"number"` (`min`, `max`, `step` (1 by default; with a whole-number default and step the value comes back as an int), `unit`); `"choice"` (`choices`: `[[label, value], ...]`); `"text"` (`placeholder`). Any type: `section` (a heading on the page), `note` (its tooltip) |
| `value(id)`, `values()` | The value now; all of them as `{id: value}` |
| `set_value(id, value, persist = true)` | Changes it (numbers kept in range and on the step, a choice only to one of its values) |
| `reset(id)`, `is_default(id)` | |
| `list()` | The declarations, in order |
| `changed(id, value)` | Signal: a value changed (on the page, or by `set_value`/`reset`) |

```gdscript
var distance = api.settings.add("distance", "number", 60.0, "Distance", {"min": 10, "max": 300, "unit": "tiles", "section": "Shot"})
api.settings.changed.connect(func(id, v): if id == "distance": distance = v)
```

### Hills: `api.terrain` *(1.2)*

Heights under the flat Factorio world, drawn only. Factorio stays flat; Zenith lifts everything it
draws by the height under it (the ground, every model, belts and their items, ghosts, wires,
icons, effects), and the mouse's ground point and the camera follow. The
[Terrain Elevation](https://github.com/unjustodin/Terrain-Elevation) add-on is the example.

| | |
|---|---|
| `set_heights(image, origin, tiles_per_texel)` | The heights: an `Image` (`FORMAT_RF`, heights in tiles), its first texel's corner at world `origin` (`Vector2`: x, z), each texel that many tiles square. Bilinear between texel centres, 0 outside: fade the edges yourself. One field for the whole client; the last add-on to set it wins |
| `clear()` | Flat again (only your own field). Done for you when the add-on is switched off or the game ends |
| `is_on()`, `area()` | A field is drawn; the square it covers (`Rect2`, tiles) |
| `height_at(x, z)` | The height drawn under a point |
| `chunk_kinds(chunk)` | A drawn chunk's 32 x 32 tiles as kinds (0 land, 1 water, 2 empty space), row by row from its north-west corner; empty when not loaded. A loop on the main thread: a few chunks a frame |
| `cliffs_in_chunk(chunk)` | Its cliffs: `[{position, orientation}]`, Factorio's orientation (`"west-to-east"`: from the middle of one edge of the 4 x 4 cell to another, the high ground on its left) |
| `buildings_in_chunk(chunk)` | Its buildings, for levelling the ground under them: `[[centre, half size], ...]` (Vector2 tiles; a building turned east or west has its sides swapped). Not trees, rocks, ore, cliffs, units or ghosts |
| `take_changed_chunks()` | The chunks whose buildings came, went or changed since the last call (a chunk loaded late, a building placed or mined); the first call starts watching |

### Looks and shaders: `api.shaders` *(1.3)*

A **look** is how the world is lit, tonemapped and coloured. Zenith has two: *Factorio* (the
default, matched to Factorio's own pictures: its shadows' angle, unwashed colours, Factorio's
colour lookup for each planet and time of day) and *Classic Zenith*. An add-on adds its own, and
the player picks it in Settings → Graphics → Look. A **pass** is a full-screen spatial shader that
reads the solid scene and draws over it; a look can carry its own, and `add_pass` shows one over
whichever look is on. Drawn only: nothing here changes the game. The
[Cinematic shaders](../addons-src/cinematic-shaders) add-on is the example.

| | |
|---|---|
| `add_look(id, look)` | Adds a look (or replaces your own of that id). Name it `"<your id>/<name>"`. False when the id is someone else's |
| `remove_look(id)` | Takes one of yours away (the Factorio look comes back if it was on) |
| `use_look(id)` | Puts a look on, as if picked in Settings (kept for the next start). Your own look remembers the one it replaced, which comes back when your add-on is switched off |
| `current_look()`, `looks()` | The look in use; every look as `[[name, id], ...]` |
| `add_pass(shader, params = {}, order = 0)` | A pass over every look, in every game until removed: a `Shader` or a path (relative: in your folder). Its id, or 0 when it isn't a spatial shader |
| `set_parameter(pass_id, name, value)` | One of your passes' uniforms; with id 0, of every pass of the look in use (when it is yours) |
| `remove_pass(pass_id)` | |
| `sun()` *(1.5)* | The sun now: `{elevation (degrees), height (its sine), twilight (0-1, what the look asked for), morning, direction (towards the sun), color, ambient, fog}`; empty without a game |

Everything goes when the add-on is switched off. A look is a Dictionary; every key is optional:

| Key | |
|---|---|
| `name`, `description` | For the Look setting's list and its tooltip |
| `tonemap`, `exposure`, `white` | `Environment.TONE_MAPPER_*` (the Factorio look uses linear, which keeps Factorio's colours; AgX and filmic roll highlights off), its exposure and white point |
| `sun_energy`, `ambient_energy` | Multipliers on the planet's sun and ambient light for the time of day |
| `ambient_tint`, `ambient_tint_amount` | A `Color` the ambient light moves towards, and how far (0-1) |
| `sun_angle` | `Vector2(pitch, yaw)` in degrees: the sun held there, as Factorio's shadows never move (`Vector2(-42, -112)`: shadows to the east, as Factorio's). Leave it out for a sun that crosses the sky |
| `factorio_lut` | `true`: Factorio's own colour lookup for the planet and time of day, from the player's install |
| `roughness_min` | 0-1: no model's surface shinier than this |
| `roughness_limiter` *(1.4)* | `Vector2(amount, limit)`: Godot's screen-space roughness limiter while the look is on |
| `taa` *(1.4)* | `true`: temporal anti-aliasing while the look is on, whatever the player's setting; theirs comes back after |
| `own_clouds` *(1.4)* | `false`: Zenith's own clouds are off while the look is on (for a look that draws its own) |
| `twilight` *(1.5)* | 0-1: how much of a real sunrise and sunset the look gets: Zenith's sun that sets in the west with a light that follows it down to 14 degrees, its colour through the air, an ambient light that goes through golden and blue hours, each planet's own colours. Absent or 0: the sun that never sets |
| `sky_twilight` *(1.5)* | 0-1: the same for the sky alone (the Factorio look holds its light still and lets the sun set in the sky, restrained). Absent: as `twilight` |
| `at_twilight`, `at_dawn` *(1.5)* | `{environment: {}, sun: {}, params: {}}`: values of those properties, sun properties and pass uniforms the look moves towards as the sun nears the horizon, by how near it is (`at_dawn` in the morning, over `at_twilight`'s). Numbers and colours only; `environment` may name any `Environment` property, `tonemap_exposure` too |
| `fog_from_sky` *(1.5)* | 0-1: how far the fog's colour takes the sky's on the sun's side at twilight |
| `environment` | `{Environment property: value}` while the look is on: `glow_*`, `ssao_*`, `ssil_*`, `fog_*`, `adjustment_*`, `reflected_light_source`... Put back when the look goes |
| `sun` | Sun properties: `light_angular_distance` (soft shadows), `shadow_opacity`, `light_specular`, `light_indirect_energy`, `shadow_bias`, `shadow_normal_bias` |
| `passes` | `[{shader, params, order}]`, drawn in order. While a look with passes is on (or any `add_pass` pass), the player's MSAA runs as SMAA and Settings greys MSAA out: Godot resolves the depth a pass reads by averaging each pixel's samples, so with MSAA every silhouette reads a depth between the two sides. Decided when Zenith starts; a look switched on in a running game changes it at the next start |

A pass includes `res://shaders/look_pass.gdshaderinc` and writes only `fragment()`:

```glsl
shader_type spatial;
#include "res://shaders/look_pass.gdshaderinc"
uniform float strength = 0.5;
void fragment() {
	vec3 c = scene_color(SCREEN_UV);            // linear, may go over 1
	ALBEDO = mix(c, vec3(luma(c)), strength);   // what goes on screen instead
}
```

The include gives `scene_color(uv)`, `scene_color_blurred(uv, mip)` (a soft copy, for local
contrast or bloom of your own), `scene_depth_raw(uv)`, `scene_distance(uv, INV_PROJECTION_MATRIX)`
(tiles from the camera), `scene_normal_roughness(uv)` (only with `#define LOOK_PASS_NORMALS` before the
`#include`: a pass that so much as declares the scene's normals makes Godot's depth pre-pass write
every pixel's normal and roughness, as SSAO does, about half a millisecond of GPU at a busy base),
`luma`, `to_srgb`, `to_linear`, and the
uniforms `look_daytime` (0 noon, 0.5 midnight), `look_night` (0-1) and, *(1.5)*, `look_sun_height`
(the sine of its elevation), `look_twilight` (0-1), `look_morning` (1 past midnight), `look_sun_dir`
(towards the sun), `look_sun_color` and `look_ambient_color`, and `look_space` (1 on a space platform: no
clouds or weather there), which Zenith sets every frame. A pass runs in Godot's transparent pass, before every other see-through thing, and reads
the solid scene as it was then: Godot copies the screen once a frame, so every pass reads the same
picture, and smoke, ghosts and icons drawn after it aren't graded. Put several effects in one
pass. Colours are linear HDR; tonemapping and Factorio's colour lookup come after. Each pass costs
a full-screen read and write; `scene_color_blurred` reads mipmaps Godot makes anyway.

### Lighter updates: `api.updates`

While something long runs (a timelapse left for hours), an add-on can ask the bridge to send less,
so the game keeps its speed. The request lowers the player's own settings while it stands; Zenith's
*Hold the game at 60 UPS* still lowers them further when the game runs slow, and wins where both
ask.

| | |
|---|---|
| `request(knobs)` | `rate` (0-3: moving things, belt items, machine states sent less often), `entity` (tiles with moving things), `near` (tiles within which items on belts may move), `far` (tiles with items on belts at all), `updates` (the most belt items sent moving an update; API 1.1 clients get it too), `view` (chunks drawn), `map` (how many times longer the minimap waits). Leave out what you don't need |
| `clear()`, `current()` | |
| `governor_status()` | What *Hold the game at 60 UPS* holds back now |

### Data: `api.storage`

JSON files in Zenith's user data: one set per save, and one for every save.

| | |
|---|---|
| `read(name = "data")`, `write(data, name = "data")` | The current save's data (`{}` before any). Under `user://addons-data/<id>/saves/<save>/<name>.json` |
| `read_global(name = "settings")`, `write_global(data, ...)` | For every save: `user://addons-data/<id>/<name>.json` |
| `save_key()` | The save's name for a game started from Zenith's menu, else the bridge's address |
| `folder()` | Your data folder (for files of your own, such as saved frames) |

Values are plain JSON: numbers (they come back as floats), strings, booleans, arrays and
dictionaries. Store a `Vector3` as `[x, y, z]`.

## Good manners

- Leave the camera, the keys and the mouse alone unless the player asked (a key, a button).
- Work in small steps: `_process` runs every frame, and anything slow there is a stutter.
- Say what your keys are (`api.keys.text`) rather than naming them in your text: the player may
  have rebound them.
- Keep your add-on's own files inside its folder and its data in `api.storage`.

## Licence

Zenith is GPL-3.0, with an exception for add-ons: an add-on that works with Zenith only through
this API may use any licence you like ([LICENSING.md](../LICENSING.md)). One that copies Zenith's
own code into it is under the GPL.

## Testing

Run Zenith from its project with your add-on's folder:

```
godot --path client -- --addons=C:/my-addon
```

Zenith's log (the console it was started from) says which add-ons started, which were refused
and why, and the add-on's own `api.note` lines. Script errors show there too, with the line. The
project's own add-on test (`client/tests/addon_test.tscn`) loads a small add-on from
`client/tests/addon_fixtures/` and is a compact example of each part of the API.
