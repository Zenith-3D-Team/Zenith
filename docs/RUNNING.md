# Running Zenith

Three pieces run on the same computer:

1. **Factorio**, usually headless with no window, runs the actual game.
2. The **factorio-3d-bridge** mod (`mod/`) inside it streams the world over localhost UDP and
   moves a character on the client's behalf.
3. The **Godot client** (`client/`) draws the world in 3D and sends your input back.

You need Godot 4.4 or newer and Factorio 2.1 (the mod is marked for 2.1, and 2.1 won't load 2.0 mods). Python 3.9+ is only needed for the
mock server and the tests.

## Start here: the client's menu

Start the client (`godot --path client`, or F5 in the editor). Like Factorio, it opens on a main
menu over a live 3D scene (a recorded corner of the mock's factory, `client/data/menu_world.json`,
made by `tools/record_menu_world.py`):

- **Continue** loads the server save played last.
- **Single player**:
  - **New game** opens Factorio's map generator: name, preset (all nine of
    `base/prototypes/map-gen-presets.lua`), seed, and the tabs **Resources** (frequency, size and
    richness of every resource, with the planet it appears on: Nauvis and, with Space Age on, Vulcanus,
    Gleba, Fulgora, Aquilo), **Terrain** (map type normal / lakes / island, starting area, water,
    trees, rocks and the planets' terrain controls as scale and coverage, cliffs' frequency and
    continuity, Nauvis moisture and terrain type), **Enemy** (bases, peaceful mode, no enemies,
    expansion, evolution) and **Advanced** (map size, pollution, technology price, spoiling rate,
    asteroids, or a map exchange string instead of all of it). "[modified]" and Reset show and undo
    changes from the preset. **Preview** asks Factorio itself (`--generate-map-preview`) for the
    picked planet, about 15 s. Play writes `map-presets/create-gen.json` and `create-map.json` in
    the server's data folder and runs `factorio.exe --create` with them, so every option shapes the
    real map. The last choices are remembered.
  - **Load game**: the server's saves (`server/saves/*.zip`) and your own Factorio saves
    (`%APPDATA%\Factorio\saves`, with their preview picture; loading one copies it into
    `server/saves` first, the original is never touched), with the date last played and size.
    Folders show first, in brackets as in Factorio: a click goes in, `[..]` back up.
    **Load** (or double-click) starts headless Factorio on the save and connects to it; **Delete**
    moves a server save to the recycle bin (after asking).
  - **Single-player (hybrid)**: how to set up your own game, and a Connect button. Hybrid mode is
    new: it has been played once (see below).
- **Multiplayer**:
  - **Host new game** / **Host saved game**: name, description, port (34197), password, player limit
    and LAN visibility, then the map generator or a save. The server is bound to every network
    address on that port, so friends join with normal Factorio (Connect to address); the 3D client
    plays as the bridge's character. RCON and the bridge stay on 127.0.0.1.
  - **Connect to address**: `host:port` of a bridge that is already running (a server started by
    hand, `server/run-server.ps1`, or the mock: `127.0.0.1:34200`). Joining a normal Factorio
    server isn't possible: the bridge only talks to a client on the same computer.
- **Settings**: as in Factorio, a list of pages (Graphics, Controls, Sounds, Interface, Other, Mod settings, then ours: Camera, Factorio install, and Add-ons, which opens the Add-ons menu), each opening alone with Back and Confirm; every option is wired to what it changes:
  - **Graphics**: a **Preset** (Low, Medium, High, Ultra, or Custom once anything differs; it sets
    shadows, SSAO (on in High and Ultra), contact shading (on in every preset), level of detail, the view, entity, belt
    and decorative distances, decorative density, 3D grass and clouds together; High is the defaults) and **For this PC** (Recommended: the preset
    this PC should hold at a steady 60 UPS and 60 FPS, from its CPU threads and graphics card; in a
    game it measures six seconds first; it also turns on Hold the game at 60 UPS and smooth belt
    items, and sets merged materials below); full
    screen (windowed, borderless, exclusive), resolution (windowed: the window's size; in full
    screen the size the world is drawn at, scaled up to fill the monitor undistorted, with the
    interface sharp and laid out as at that size, up to the monitor's own), preferred screen,
    minimize on focus loss, VSync, FPS limit, game render scaling (50% to 200%, multiplying the
    resolution), view distance (2 to 50 chunks round the
    camera, default 10; its value shows yellow past 10 and red past 20, since what is drawn grows with
    its square; past 14 chunks the ground is drawn simpler, a quad per 4x4 tiles; a bridge mod from before
    square subscriptions (no welcome `sq`) streams at most 625 chunks, so with one the view past 12 is the
    nearest 625, a circle about 14 chunks round; Factorio only has ground where its map is generated), entity distance (32 to 256 tiles, default 192; the server's "Max
    live-update radius" caps it), belt item distance (0 off to 640 tiles, default 160: items on
    belts drawn that far, moving near the character and standing still on their lanes past
    that), moving belt items (Automatic, the default, or 1,000 to 24,000 items, or Unlimited: the
    most items, and a little for each lane, the server sends moving an update, from the character
    outwards; further out they stand still; Automatic follows the frames' room, the game's speed and
    what the reading costs the server, which each update reports (`bi` w), keeping it within about
    1,500 work units a tick; Unlimited moves every item within the belt item distance), hold the game at
    60 UPS (on; see Troubleshooting), give the server the CPU first (on; `--server-first=off`: with the
    server on this PC, connected to 127.0.0.1, the client's process runs at below-normal priority from the
    welcome on, so Factorio's tick gets a core first whenever every core is busy; measured on a 4-core PC
    at a busy base, the join's first 75 s ran the game at 34 UPS median at normal priority and 56 below,
    steady 59-60 either way, the client's frame rate unchanged; Windows sets it with wmic, elsewhere
    renice), smoke and particles, Items in 3D (Icons only, up to 20,000
    or All, default All: how many belt items are 3D models, nearest the character first, the rest
    their icons; Icons only draws every item as its icon, on the ground and in hands too), clouds,
    decoratives, decorative density and distance (64 to 320 tiles, default 192), 3D grass (off, 30
    tiles still, 40 or 50 tiles with wind; default 40; see Decoratives). Models always wear each
    part's colour from Factorio's sprites (the projected-sprite model look is gone). Smooth belt items (belt items
    read in one tick every update, so they follow curves) and item icons are no longer shown and
    stay on; Hold the game at 60 UPS still eases smooth belt items off under load. **Advanced:**
    anti-aliasing (Off, FXAA, SMAA, TAA, MSAA 2x/4x/8x; default SMAA, the sharp one; TAA softens moving
    belts; under a look that draws full-screen passes, such as the Cinematic shaders, the MSAA choices are
    greyed out and a saved MSAA is switched to SMAA in the settings (at the start, or when such a look
    comes on, with a message), since the passes read a depth MSAA averages at every edge; a look's TAA
    still runs over it), shadows (off,
    low, medium, high, ultra: the sun's shadow map is fitted to the ground in view, one map from
    the angled view and Godot's splits when the view reaches the horizon; Low one 2048 map out to
    80 tiles, Medium 4096 to 110, High 4096 to 150, Ultra 8192 to 200,
    `scripts/world/sun_shadows.gd`), shadow distance (Automatic, the Shadows quality's 80 to 200
    tiles, or 60 to 400 tiles from the camera), level of detail (low, medium, high: how soon far models and
    their shadows are drawn simpler: 4, 4 and 1 pixels of error), merge far buildings (on: past
    128 tiles from the camera, or the shadow distance if further, and 40 tiles from the character,
    each chunk's buildings are one simplified mesh with no moving parts, which casts their
    shadows; trees, ore and nests keep their own; `scripts/world/far_chunks.gd`), animate modded
    buildings (off by default, and turned off once in settings saved before: still pictures, less
    memory; on: a mod's building drawn with its own Factorio picture runs its moving part while it
    works), merged materials (off: each model drawn as one surface with one material, fewer draws and
    less render CPU for a little more GPU time; after a restart; `-- --merged-materials` or
    `--no-merged-materials` override it; Recommended turns it on for a big desktop GPU whose frames
    the CPU holds up, the presets leave it), Ambient occlusion (SSAO, tuned to Factorio's tight corner shading: radius 0.7 tiles, no detail pass, half
    size, half its effect on direct light, faded out 60-140 tiles away; on by default and in High and Ultra, off in Low and Medium, about 0.7 ms of
    GPU at a busy base on a desktop card; turned off once in settings saved before it was retuned), Contact shading
    (on: the dark rim on the ground round each building's foot that Factorio's sprites have, faint under chests,
    none under belts, rails, walls, pipes and trees, a broad patch under drills, labs, radars and centrifuges;
    contact_shade.gd, one draw per chunk), render on a separate thread (off: Godot's experimental mode, after a
    restart).
    **Accessibility:** brightness, contrast, saturation and Factorio's colour filters
    (protanopia, deuteranopia, tritanopia and their corrections, over the whole window).
  - **Sound**: master, game effects and its parts (walking, environment = machines and vehicles,
    weapons, explosions, enemies), music and GUI effects, each with a mute box; preferred output
    device; machine sounds at once.
  - **Controls**: Factorio's groups and names, a primary and an alternative binding per control, with
    Shift / Ctrl / Alt; right click clears, clashing bindings are red; mouse and fixed keys are
    listed greyed. `client/scripts/menu/controls_info.gd` says where an action goes.
  - **Interface**: under Factorio's headings: show minimap, control hints (F1; the help panel is off
    by default and hides while a window is open), Alt-mode and its inserter, pump and machine arrows (Factorio's defaults: inserters off), smart belt building, lock belt building to a straight line, UI scale, tooltip delay, the entity tooltip,
    show mods' windows (off: mods' windows aren't drawn in Zenith for now, as their layout and
    buttons don't match Factorio's yet; use them in Factorio with Ctrl+F9), click mods' buttons in
    Factorio (with mods' windows shown: on, pressing a mod's button in Zenith clicks it in your own
    Factorio window, hybrid on Windows; off, it says to use Factorio), chat message delay; then the
    client's own: shortcut bar, research, alerts, debug line (F4), the minimap's size, zoom and
    tags, and the map view's switches.
  - **Other**: the server's autosave interval and slots and verbose logging (written into the
    `server-settings.json` the menu puts in the server's data folder; from the next start), and
    minimise Factorio in Zenith (on: Ctrl+F9 from Factorio minimises its window while Zenith
    shows the game).
  - **Mod settings**: the bridge mod's map settings, changed over RCON in a game started from the menu.
  - **Camera**: the view a game starts in (Angled view, Factorio's view or First person), the
    angled view's projection (Perspective or Orthographic; Factorio's view, F6, is always
    orthographic), the map's remote view's projection (F7 switches the view in use and keeps it),
    the furthest zoom (60-400 tiles, 140 by default), how far the view zoomed in from the map zooms
    out before the map comes back (80-480 tiles, 240 by default), mouse sensitivity, invert mouse look,
    camera follows the hills (off: over an add-on's hills the camera stays level and only first
    person rides them).
  - **Factorio install**: path to `factorio.exe` (or its folder; empty finds it), the server's
    data and saves folders, the first port servers use.
- **Mods**: base, the DLC and the mods in the server's mods folder, with versions and on/off boxes,
  written to the server's `mods/mod-list.json` (Space Age brings Quality and Elevated rails along;
  the bridge is always on). The map generator leaves Space Age's planets out while it is off.
- **About**: versions, licences and Factorio's own credits from your install.
- **Exit**.

Every setting is in one file, `user://settings.cfg`
(`%APPDATA%\Godot\app_userdata\Zenith\settings.cfg`; sections graphics, sound, interface, map,
controls, camera, factorio, alerts, new_game). The older `ui.cfg` and `audio.cfg` are read into it
once and then left alone. Settings from the project's old name (`app_userdata\Factorio 3D`) are
copied over once. The settings you changed in Factorio's own Settings window are the defaults
(`client/scripts/menu/factorio_settings.gd`, read from Factorio's `config.ini` at start-up, the
file the #14 keys come from): the volumes, v-sync, full screen, clouds, smoke and particles,
decoratives, colour filter, UI scale, belt building, alt-mode arrows, the minimap, the autosave
interval and the language of item names. A setting changed in Zenith still wins and its Default
goes back to Factorio's; Settings → Factorio install → "Use the settings set in Factorio" turns
it off. Settings left at Factorio's default (comments in `config.ini`) keep Zenith's. With
`--settings-file` it is off unless `--factorio-config=<file>` names one. Most settings apply
at once, the UI scale too (Settings → Interface, or Factorio's keys Ctrl+= / Ctrl+- / Ctrl+0 in
the game and the menus; "Automatic" follows the window's height as it's resized). The UI is built
at the scale it started with and scaled from there, so after a big change text is a little softer
until the next start. `-- --model-look=palette` draws the models in their own palette colours, for
comparing. `-- --settings-file=user://other.cfg`
uses another file (tests and screenshots).

Starting a save runs Factorio exactly as `server/run-server.ps1` does (same `server/data` write-data
folder, mod junction, `--enable-lua-udp`, RCON on 127.0.0.1 with the password in
`server/data/rcon-password.txt`), but on free ports from 34500 up (Settings → Factorio → First port for servers; UDP, game port, RCON, then the
client's own port), so servers started by hand keep theirs. A progress window shows Creating map →
Starting server → Loading map → Connecting → Loading world; Cancel stops it. Errors (Factorio not
found, map creation failed, the server stopping, no free ports, another Factorio using
`server/data`) come up as a message with the relevant lines of `server/data/factorio-current.log`.

In the game, **Esc** (with no window open) opens Factorio's "Game menu": Resume, **Load game** (asks to save, then the saves), **Save game** (RCON
`/server-save`), **Save as** (a name or an existing save to overwrite: `/server-save <name>` writes
it in the data folder's `saves`, then it is copied into the saves folder; the game goes on in its
own save, as on a Factorio server), Settings, Players (with other players in the game), and the red
**Exit** at the bottom: **Exit to menu** or **Quit game**. Leaving asks whether to save: "Save
and exit" stops the server with `/quit` (Factorio saves as it quits), "Don't save" ends the process.
Closing the window saves and stops the server too. If the client crashes or is ended from the Task
Manager, a small watchdog started with the server stops it a few seconds later (without saving:
Factorio's last autosave is what's left). A bridge you only connected to keeps running.

The console (` or /) runs Factorio's commands wherever they can run (`/help` lists them in these
groups; Tab completes a command's name, Up and Down go back through what you typed):
- **In the client:** `/help`, `/clear`, `/color`, `/shout`, `/ignore`, `/unignore`, `/ignores`, `/permissions`.
- **By the bridge**, with or without RCON: `/cheat` (researches everything; `all` also gives power
  armour MK2, equipment and robots; `off`; a planet or platform name moves the character there),
  the `/f3d-*` commands; and, without RCON, `/version`, `/seed`, `/time`, `/evolution`, `/players`,
  `/admins`, `/server-save`. Cheat mode itself is a player's setting: the bridge's own character on
  a map nobody has joined gets the research and the kit but still crafts at the normal speed.
  In a multiplayer game these are for admins: a player who joined the server and plays through
  Zenith on their own machine must be an admin, and so must one typing the mod's `/f3d-*` commands
  into Factorio's console. A Zenith on the server's own machine always may (the server's console
  and RCON are there too).
- **Over RCON** (a server the menu started): Lua (`/c`, `/sc`, `/mc`) and the server's commands
  (`/kick`, `/ban`, `/promote`, `/whisper`, `/config get`, ...). In Lua, `game.player` is the player
  whose character the client plays; on a map nobody has joined it stands for the bridge's own
  character (`game.player.insert{...}`, `.surface`, `.position` work; player-only fields say so).
  `game.print` and `game.player.print` answer in the console, and so do Lua errors. Lua never goes
  through the bridge's UDP: anything on the machine can send UDP, and Lua is for admins.
- **In Factorio itself:** `/editor`, `/screenshot`, `/reply`, `/open`, `/admin`, `/alerts`, the tips
  commands and the others that need a player's game window: the console says to press Ctrl+F9
  (Show in Factorio), which opens the same game in Factorio, and type it there.

Options that only make sense in a game skip the menu and connect straight to
`127.0.0.1:<--factorio-port, 34200>` as before: `--factorio-port`, `--port`, `--open`, `--ui...`,
`--camera=...`, `--fx-demo`, `--no-menu`. The manual ways below still work.

Menu options for tests and screenshots (after `--`):
`--menu=worlds|new[:tab]|host|connect|hybrid|single|multi|mods|about|settings[:tab]|progress` opens
that page (`--menu-preview` makes the map generator ask for its preview), `--menu=esc` opens the
in-game menu once in a game and `--menu=save-as` its Save as window; `--menu-launch=<save>`,
`--menu-new=<name>[:<preset or last>[:<seed>]]`, `--menu-host=<save>[:<port>]` and
`--menu-connect=<host:port>` start a game as the buttons would; `--menu-save-after=<s>` (with
`--menu-save-as=<name>`: Save as), `--menu-exit-after=<s>` and `--menu-quit-after-exit` save, return
to the menu (saving and stopping the server) and quit. `--factorio=<exe>`, `--server-data=<dir>`,
`--saves-dir=<dir>` and `--port-base=<port>` keep a test away from the normal folders and ports.

### The download

`python3 tools/release/package.py` (`--platform windows|linux|linux-arm64|windows-arm64|macos`, or
`supported`, `unsupported`, `all`) exports the client with Godot and writes
`dist/Zenith-<version>-<platform>.zip`. It needs Godot's export templates for the editor's version.
The zip holds one folder: `Zenith.exe` (Linux: `Zenith.x86_64`, marked executable), the bridge mod
in `mod/factorio-3d-bridge`, the server scripts in `server/`, the licence, credits, this project's
player's guide and `START HERE.txt`. The exported client finds `mod/` and `server/` next to its own
executable (on macOS next to `Zenith.app`). Its servers' data and saves are kept in Zenith's user
folder instead, beside `settings.cfg` (`%APPDATA%\Godot\app_userdata\Zenith\server-data` and
`...\saves` on Windows), so an update, unpacked into a new folder, finds them; a checkout keeps
using `server/data` and `server/saves`, where `run-server.ps1` and the tools look. The first start
of such a build copies what an older one kept in `server/saves` and `server/data/mods` beside it
(saves, the server's own mods, `mod-list.json`, `mod-settings.dat`) while the user folder has
none, and the bridge mod's link in the server's mods is made again at every start, so it always
points at this version's mod. Settings → Factorio install's folders still override both. Windows and Linux are the supported downloads; the Linux build has
not been run yet.

**Unsupported downloads (owner's label):** `linux-arm64` (issue #8), `windows-arm64` and `macos`
are built the same way, never run by anyone, and named `...-unsupported.zip` with an
`UNSUPPORTED.txt` inside saying so. Linux ARM64 (`Zenith.arm64`, textures packed for desktop graphics
only, as ARM64 desktops' GPUs read them; a Raspberry Pi's can't): Factorio has no Linux ARM64 build, so it has to run under an x86-64 emulator such as
Box64 or FEX-Emu, with Settings -> Factorio install pointing at it. Windows ARM64: Zenith runs
natively, Factorio's x64 build through Windows' emulation. macOS: a universal `Zenith.app` (Apple
Silicon and Intel; package.py imports the textures for ARM too for that export alone and puts the
project back after), exported on Windows with only an ad-hoc signature and no notarization, so macOS
asks to be told to open it (right-click > Open, or `xattr -dr com.apple.quarantine Zenith.app`);
Factorio's own macOS build is found in Steam or /Applications.

**Build channels (owner: public downloads carry no testing tools; development builds do).**
`--channel public` (the default) is the release on the public repo; `--channel dev` builds
`dist/Zenith-<version>-dev-<platform>.zip` a development build for testers. A dev export
carries Godot's custom feature tag `zenith_dev`: package.py adds it to that platform's export preset
for the export alone and puts `client/export_presets.cfg` back after, so the presets stay one list.
`Settings.dev_tools()` (client/scripts/menu/settings.gd) is the one switch everything asks: true in
a dev export and when running from source (the editor, `godot --path client`; `-- --public-build`
shows what players get), false in a public export. Public builds hide the main menu's Performance
test and `--perf-test`, the debug menu with its Ctrl+F12 binding, and its overlays; the code stays in.
A dev zip also has PERFORMANCE-TEST.md, the docs' dev-build parts (USER-GUIDE.md and ADDONS.md
mark them `<!-- dev -->` ... `<!-- /dev -->`, cut from a public zip's copies) and a line in
`START HERE.txt` saying it is a development build. The probes on the command line (`--stutter-probe`,
`--ups-probe`, `--ups-overlay` and the rest below) and the bridge's `/f3d-debug` stay in both.
A feature tag rather than a marker file beside the program: the build itself says what it is, so
there is no file to lose when unpacking, to copy into a public download, or to read at start.

**A modeller's models in the download:** `--models <folder>` copies the `.glb` and `.gltf` files at
that folder's top (and any `.bin` or textures a `.gltf` points at) into the download's `models/`
folder beside the program, and adds a note to its README.txt that they are a modeller's, used with
permission. Zenith reads that folder at start-up, as in a checkout, and a model there replaces its
own of the same name, so the download shows them with no option set (`-- --no-custom-models` leaves
them out). The 0.2.0 downloads carry Vasillo's models this way (his permission; CREDITS.md):
`--models <his models>`.

`python3 tools/release/build_mod_zip.py` builds just the mod
(`dist/factorio-3d-bridge_<version>.zip`) for Factorio's own mods folder.

## Quick start without Factorio (mock server)

```
python3 tools/mock_server.py
```

Then open `client/project.godot` in Godot, press **F5** and use Play → Connect to address
(`127.0.0.1:34200`), or start the client with `-- --factorio-port=34200` to skip the menu. The mock generates a world with
lakes, forests, ore, a small factory, a train, a car, robots and biters, so the client can be
worked on without the game. `--day-length 1200` makes a day last 20 seconds instead of seven
minutes, to see night fall. The chest, assemblers, furnaces and lab open as machine screens with
made-up contents; `--start 5,-1` starts the character next to an assembler (`4,9`: the chest).
`--belt-field 24x16 --start=24,-8` adds a block of full belts (about 3,000 items of 24 types)
to watch the client draw items on belts; the client's `--item-bench` prints frame times and the
belt items' own time every 5 s, and `--item-models=off` draws icons instead of 3D models for
comparing. With `--belts-off 16 --belt-tiers` the field's columns are bare yellow, red, blue
and green belts in blocks of four, every other one stopping and starting, for watching their
surfaces (chevrons spaced as Factorio's: yellow every half tile, red and blue one a tile, turbo
every other tile). Fast belts are smeared over one 60 fps frame's travel so they don't strobe (none
while TAA is on, which blends frames itself, and none on screenshots); the client's
`--no-belt-smear` draws them without it, for comparing. `--item-showcase --start=-20.5,7.5` lays one of every item that has a 3D model on the
ground in a grid. (Much bigger fields don't help: Windows keeps only ~64 KB of a burst of UDP,
about 3,000 items per update.)

## Headless Factorio (the main setup)

The server runs your save with no window and nobody logged in. The 3D client plays your own
character, as follows.

**Your save's character.** On a server a player who isn't connected has their character "logged
off": Factorio takes it out of the world, so nothing can walk or mine with it, but their inventory,
armour, guns, ammo, trash, logistic requests, crafting queue and quickbar stay with the player. So
the bridge stands in for them: its character appears where theirs was (on whatever planet or
platform) and their things move onto it; their quickbar is the client's. When that player joins the
server with the real game, everything moves back onto their character, which stands where the
stand-in was, and the client plays that character from then on. If the stand-in dies, its things
are in its corpse, as with any death, and a new stand-in starts where the player was.

Whose character: the player who was online last (in a save played alone, its owner). On a save with
several players, pick one with `/f3d-player <name>` (on the server console or RCON;
`/f3d-player` lists them) or the map setting "Player to play as" (`f3d-player`); `/f3d-player none`
gives everything back and plays the bridge's own character. A new map nobody has joined gets the
bridge's own character with freeplay's starter kit, as before.

**Linux** (the headless build is a free download):

```
server/download-headless.sh      # once
server/run-headless.sh           # new map in server/saves/world.zip, or load it
server/run-headless.sh ~/my-base.zip
```

**Windows** (uses your installed game; no window opens):

```
powershell -ExecutionPolicy Bypass -File server\run-server.ps1
powershell -ExecutionPolicy Bypass -File server\run-server.ps1 -Save C:\path\to\my-base.zip
```

The script finds the game in any Steam library (or `C:\Program Files\Factorio`). Pass
`-Factorio C:\path\to\factorio.exe` to use another copy. `factorio.exe` is a windowed program,
so the script returns while the server keeps running in the background; stop it with
`python tools\rcon.py /quit` or Task Manager.

Both scripts:

- keep the server's config, logs and mods in `server/data/`, apart from your normal game, so
  the two can run at the same time;
- link `mod/factorio-3d-bridge` into the server's mods, so edits apply on the next restart;
- start the server with `--enable-lua-udp 34200`, `auto_pause` off, and bound to 127.0.0.1.

Then start the client and use Play → Connect to address (`127.0.0.1:34200`), or start it with
`-- --factorio-port=34200`. The status line in the top-left corner shows the connection. (Or let the
menu start the server for you: Play → Load.)

`/f3d-status` shows whether a client is connected, how many chunks are subscribed, and where
the character is, and starts with any step of the bridge that failed (`ERROR: step ...`, also in
`factorio-current.log`): one failing step no longer stops the game (`tools/live_check.py --only barrier`
fails one on purpose to check that). Both scripts enable RCON on 127.0.0.1:34198 with a random password in
`server/data/rcon-password.txt`, so console commands work from another terminal:

```
python3 tools/rcon.py /f3d-status
python3 tools/live_check.py     # plays the client over UDP: walking, building, mining, machine screens
```

`live_check.py` needs the Godot client closed (it uses the client's port) and gives the
bridge's character a few chests and inserters to build with. For a second server on other ports
(`run-server.ps1 -UdpPort 34210 -GamePort 34297 -RconPort 34298`), pass the same ports:
`live_check.py --factorio-port 34210 --client-port 34211 --rcon-port 34298`; `--only platforms`
runs just the space platform checks. `--only save` checks a loaded save (use a copy: it moves the
player's things back and forth): the stand-in's inventory, armour, guns, requests, quickbar,
logistic chests, the map's other surfaces, remote ghosts, and the trains overview, a train's and a
stop's window data, interrupts and temporary stops on a real train. `--only enemies` spawns
biters by a wall, a worm and a spawner next to the character and checks that their attacks arrive
(`en`) and that the spawner's and worm's decals reach a client that asks for decoratives.

### Space platforms (Space Age)

You get to a platform as in Factorio: build a rocket silo, let it make a rocket, and with a platform
in orbit open the silo (or press Enter beside it) and click **Ride** by the platform. The character
walks into the rocket and the client follows the real launch (`launch_rocket` with the character, the
game's own timing: about 8 s on the pad, 20 s climbing), fades out high in the sky and in again in
space, where the cargo pod comes down onto the platform's hub and docks. The character then sits in
the hub, as a player does: no avatar, the view stays round the platform (WASD moves it, Esc on the
hub opens the menu), building places ghosts and the platform's buildings open from there. Factorio's
platform panel (under the minimap, or beside it on a short window) shows whenever the view is on a
platform: on board, in the remote view of one, and in the right column of the map view and the space
map. Stopped it reads "Stopped at Nauvis" with the planet's icon (and, ours alone, the next stop of
its schedule); travelling, the planet it left, a bar with the distance come and the planet it goes
to; then its speed and mass. On board it has **Drop to a planet**: pick a planet, and a cargo pod
takes the character down to the force's landing pad there (or beside the spawn) once the platform is
stopped over it; the red cross cancels. Where the platform goes and its pause are set in its hub's
screen, as in Factorio. Input to the world is locked during the rides; the world is reloaded for each
new surface and the inventory comes along.

To get a platform without building a rocket, on the server console or over RCON:

```
python3 tools/rcon.py /f3d-platform new        # build one in orbit (starter pack applied)
python3 tools/rcon.py /f3d-platform board 1    # put the character on platform 1 (a teleport, for tests)
python3 tools/rcon.py /f3d-platform leave      # back down to the planet below (or: leave nauvis)
python3 tools/rcon.py /f3d-platform            # list the platforms
```

The mock can show every turret, a tank and a spidertron aiming and firing at its biters:
`tools/mock_server.py --turrets --start 69,40` (`tools/mock_turrets.py`, Factorio's rotation
speeds and cooldowns; they do no damage).

The mock has the other planets too: `tools/mock_server.py --planet vulcanus` (or `fulgora`, `gleba`,
`aquilo`) starts on a small surface with its tiles, a few buildings and its data (a crawling
demolisher, lightning on rods, growing yumako and a pentapod, frozen inserters), and `land` from
the platform goes down to whichever planet it is stopped at.
The mock has a platform too (`tools/mock_server.py --platform` starts on it), and the client's
`-- --plat-board=1@5` boards platform 1 after 5 seconds (0 goes back down), for screenshots. The
mock flies `ride` and `land` on a shortened timeline. `-- --ride=1@8` rides the nearest silo's rocket
to platform 1 after 8 seconds and `-- --land=50` goes back down at 50 s, without clicking;
`live_check.py --only ride` checks both against a real server.

Space Age's screens open like any machine's: the platform hub (the platform, its schedule with
interrupts, its requests from planets), a rocket silo (parts, automatic launch, **Launch** to a
platform in orbit), cargo landing pads and bays, asteroid collectors. **Space map** (at the top of
the remote view's Surfaces panel, the map's surface switcher) shows the solar system, the routes and their
asteroid danger, and the platforms; click a planet or platform to look at it, and **New platform**
makes one over this planet that waits for a starter pack (put one in a rocket silo's rocket and
the game launches it). In the mock a silo and a landing pad stand west and north of the start;
`--auto-launch` launches the silo's rocket whenever it is ready (a rocket rising, then a cargo pod
coming down on the pad), and the client's `-- --ui=space` opens the space map after 3 seconds.

### What the bridge costs

`/f3d-profile` turns per-module timing on (and off); after 10 s `/f3d-status` lists each module's
average script time per tick (`transport`, `world` (chunk snapshots), `movers`, `belt_items`,
`inserters`, ...). To try it on a busy base, `python3 tools/busy_base.py` builds one next to the
bridge's character on a test save (loops of belts full of moving plates, a block of assemblers
fed by inserters, power), profiles for 12 s and prints the report; `--clear` removes it again.
`--big` adds a main bus, a train, a robot network and a block of walls (20,000+ entities), and
`--measure out.json` connects a client of its own instead of needing one: it records each
module's time, the game's UPS with and without the bridge serving, chunk snapshot time, bytes per
second by message type and a call-by-call breakdown of reading belt items. CI's `busy` job runs
`--big --measure` against `tools/busy_budget.json` and fails when the bridge costs more than
twice the budget. On CI's runners the bridge costs about 6 ms per tick with 3,700 belt items in
view, nearly all of it `belt_items`; the game keeps 60 UPS. On a laptop with `--big` (about 25,000
entities) and the windowed client connected it costs about 15 ms a tick. For a client that says
`bl` in its hello (Zenith does; `busy_base.py --measure`'s own client doesn't), a belt lane whose
item count and front and back items haven't moved isn't read or sent again: on the owner's save
at its busiest belts that took `belt_items` from 12-15 to about 5 ms a tick. (A full belt that
flows moves whole item gaps between some checks and would look unchanged, so every other update
is read a tick early, and a check that can't tell reads the lane in full.) If a module is expensive, the "Belt item, ground item and inserter radius" and "update interval"
settings below are the first things to turn down.

Two things keep the bridge from making a slow tick. **The work budget** (`scripts/budget.lua`):
everything that can be big (chunk snapshots, map charts, the handshake, another planet's remote
view, Factoriopedia, statistics, the trains on the map, hover info) is done in slices, paid from
300 work units a tick by default (about one entity read each); the client may change it
(`budget`, 50 to 20000) and hears once a second how it is used (`wb`, docs/PROTOCOL.md "Work
budget"). **Update rates** (`scripts/rate.lua`): at `rate` level 1 to 3 the costliest periodic
updates (belt items, far lanes, movers, then machine states, enemies, plants and spawners, then
fluids, trains, turrets, inserter hands) come less often, each level doubling their interval; the character's own
updates never slow. A `bs` client's belt updates (reads of the input spots, not glided positions) slow
only at level 3 and only to 12 ticks (`/f3d-bs own_rate`, below). Hold the game at 60 UPS sets both; `/f3d-rate 0-3` sets the level by hand. While
the bridge makes its first load of the belts (joining, a jump: `bs` with `ld` while the square loaded is
under 3/4 of the belt item distance) and 3 s after, Hold 60 UPS takes no step and keeps the budget at 150
or more; the load done, the budget is back at its default (ups_governor.gd).

**Belt simulation switches** (`scripts/belt_sim.lua`, a `bs` client): `/f3d-bs` (console or RCON, no
restart) lists them; `/f3d-bs <name> on|off|default` sets one for every client (kept in the save), the
old behaviour back when off. `feed_edges`: lanes fed from outside what is sent are checked on every
update's tick, never quiet, and sent whenever they changed. `full_area`: every belt within the client's
belt item distance is simulated (off: its Belt updates cap and the entity distance bound the square, as
before). `inputs_first`: inserters and drills that use belts are checked themselves (their hands, their
mining progress) and wake their belts; input spots come before the other checks, the accuracy reads
outside the steady limit. `line_rereads`: lanes asked for again (`bre`) are read in groups on one tick
with their packed runs. `/f3d-bs bound <share>`: the share of the work budget the belts' work a tick may
take before the square is cut from the outside (default 0.6; 0: never cut). What they cost at 160 tiles:
`actor_backoff` (inserters whose hand stood for 4 checks are checked every other update, drills about when
their progress comes round), `drift_far` (drift checks half as often from 48 tiles, a quarter as often from
96), `bre_cap <lanes>` (at most that many asked lanes read an update, in the order asked, the rest
waiting their turn, at most 2,048; default 192, 0: all), `quiet_backoff` (watched lanes standing for 6 and 12 checks are checked 2 and 4 times
less often), `pc_ids` (every packed lane's drift check carries its front and back items' ids, `pu`,
outside the accuracy extras' share: off, only while that share has room, which at 160 tiles was 61 of
85,080 packed checks, so a packed lane the client had a whole gap or more off by its ids never showed;
off by default, as it changed nothing measured), `hold_inputs` (a splitter's input found at its check as the
client's last read of it left it, a packed one by its front and back items' ids too, is sent in `sh`: the
client puts it back so and holds its items there, not crossing into the outputs, until its next read; the
game's own update order holds a backed-up balancer's input a tick or more where the belt rules let its item
go, and a watched lane is sent only when the game's changes, so the client's balancers drained where the
game's stood). The others on by default. `area square|trace` (the owner's design; default square): with
`trace` the bridge loads only the belts within `trace_near` tiles of the focus (default 48: what the
player sees at the normal zoom, about 107 x 60 tiles), the belts feeding them traced back to their
origins (at most `trace_hops` belts back, default 200; an origin is a belt nothing loaded feeds, whose
inserters and drills are the input checkpoints) and the belts they feed `trace_down` belts on (default 8;
where a line is cut its exit lane's wall is watched every update, `ew`). Belts within the belt item
distance that don't feed what is seen aren't loaded (their far lane icons stay); `fr` is then the near
square, and the far lanes leave out the traced belts beyond it. `checkpoints` (off by default): the lanes
where our copy of the belt rules is known to go a tick from the game's (a splitter's inputs, a lane an
inserter takes from, an underground entrance an inserter drops on) are checked every update, never
quiet, packed ones by their ids. `crossings sim|game` (default `sim`): with `game` every splitter's output
lanes (lines 5-8, a lane splitter's 3-4) are checked on every update, never quiet, packed ones by their ids,
and read (`sl`) whenever anything but an even flow happened, so each crossing reaches the client within an
update of the game making it; measured offline on the 80 x 80 recording at -62,-26 (docs/BELT-SIM-PLAN.md,
the cross round) reads of the outputs every 6 ticks made the simulation worse than running the splitters
itself, so `sim` stays the default. With `/f3d-profile`, `/f3d-status` also lists the belt simulation's parts
quiet, packed ones by their ids. `own_rate` (on): the updates follow their own rate job (`bs` in
rate.lua: tier 3, at most 12 ticks), so the client's `rate` levels 1-2 (Hold 60 UPS's first steps) leave
them every 6 ticks and level 3 doubles them once; every update is a read of every input spot, so a
longer period is a staler bus, not a smoother glide (off: the glided belt items' job `bi`, 12, 24, 48
ticks at levels 1-3, as before, which under Hold 60 UPS left the owner's bus with gaps along every lane).
Hold 60 UPS then buys its UPS from the steps after `rate` (the minimap, the entity distance, the belt
item distance, which shrinks the square the bridge reads; TODO: its Moving belt items steps, 3000 and
1500, are the belt cap, which a `bs` client's square ignores under `full_area`, so they buy nothing there).
Measured live at -62,-26 (Hold 60 UPS on, `--record 60`, 2 runs each): before, updates of 24-48 ticks at
rate 2-3, live visible 78-80%, phantoms 7-8%, the copper and iron buses mostly empty with streaks; with
`own_rate`, 12-tick updates at rate 3, live visible 79-81%, phantoms 8-10%, the buses mostly full with
scattered gaps (the score doesn't tell the pictures apart). The game ran at 30-50 UPS in every run with
the client's ~1 s jobs up, so the governor reached level 3 either way. `drift_watched` (off): on, watched belts' lanes (an inserter's or
drill's belt, the belt behind a pickup belt, a splitter, a loader, a wired belt) get drift checks (`pc`) in
the same turns as the rest, their own checks' quiet timing left as it was; off, as before, they had none:
a watched lane is sent only when the game's changes, so one the client got wrong while the game's stood
(a backed-up bus) stayed wrong. On the every-tick capture at -62,-26, 2.0% of the game's items were holes
on lanes that never got a drift check, 0.6% on lanes not read for 400 ticks or more. Off by default: on that
recording through the offline harness (600 ticks after a fast first load, `bre` answered) it sent a third
more drift checks and asks for nothing measurable (by place 95.42% on, 95.49% off; phantoms 2.21 / 2.17%). With `/f3d-profile`, `/f3d-status` also lists the belt simulation's parts
the client's ~1 s jobs up, so the governor reached level 3 either way. `walk_load` (units a tick, default 1200; 0 or off: as before) and `walk_near` (tiles, default 96): while the
square every belt of which is loaded (`fr`) reaches less than `walk_near` tiles from the focus (walking,
a jump: the view isn't all loaded), first loads get at least `walk_load` work units a tick instead of their
share of the work budget, which at Hold 60 UPS's budget floor is LOAD_MIN (400). Walking laps at
-62,-26 at the character's own speed, the bridge loaded about 14 lanes a tick: along the bus the loaded
square fell to 4-8 tiles round the character and the view showed a third of the bus's items
(tools/belt_walk_check.py, docs/BELT-SIM-PLAN.md's walk round); with `walk_load` 1200, 2 runs each,
visible while walking went from 65.0 / 87.2% to 91.2 / 93.6%, phantoms 2.1-2.2% on recorded lanes either way,
for about 0.5 ms a tick more while walking. Standing with the square loaded it changes nothing. `send_cap` (bytes a
tick, default 30000; 0 or off: as before): an update's parts (about 28 KB each) are sent over the ticks after its
due tick, about `send_cap` bytes a tick and one part at least, oldest update first, each part still stamped with its
update's tick (`k`), instead of all on the due tick; under a cap below 30000 the parts are made smaller with it
(about cap / 7.5 numbers), so a tick's bytes stay near the cap. Windows gives the client's UDP socket 64 KB: of three or more
parts sent in one tick the client lost the last ones whenever it hadn't read between them (0.1-1% of parts in
every join at -62,-26, always an update's last parts, lanes that then waited for their next read or a `bre`), and
the due tick carried the whole text cost (`bse.text`, 7-16 ms a due tick at 6 ticks). The spool is module-local:
only what is sent depends on it. Measured at -62,-26 (perfbridge round, 2 runs each, the join's first 90 s traced):
ticks sending over 64 KB 280 / 303 -> 6 / 9, `bs.emit` ticks over 20 ms 40 / 47 -> 3 / 5, the bridge's worst tick
130 / 130 -> 104 / 91 ms; lost parts 0.34 / 0.17% -> 0.67 / 0.05% (the client's I/O thread, polling every 1 ms at
below-normal priority, still misses two ticks' datagrams now and then), game UPS unchanged (median 40-44 either
way: the bridge's steady cost and the client beside it). With `/f3d-profile`, `/f3d-status` also lists the belt simulation's parts
(`bs.watch` watched belts, `bs.feed`/`bs.edge` lanes fed from outside and leading out, `bs.actor`
inserters and drills, `bs.drift`, `bs.bre`, `bs.load` first loads, `bs.scan`, `bs.queue` the update's
queue, `bs.emit` the message text; `bsq.*`, `bse.*` their pieces), each inside `belt_items`.
`extra_spread` (on; the perfbridge2 round): the reads made for accuracy alone (`extra_units`, 2,000 work units an
update: the packed runs round lanes the client asked for again, the tails of changed watched belts, the reads round
a settled one) are spread over the update's ticks, twice an even share (2 * 2000 / (period - 1)) a tick at most, the
rest of the steady queue waiting a tick (never on the due tick); off, they land wherever their step comes, which for
the asked lanes' runs was all on the round's first tick (`bs.bre` 6-11 ms there at -62,-26, the update's worst tick
after the due one; at an even share the asked groups took a tick apiece and held the watched belts' checks back to the
due tick). The same round made the bridge cheaper without a switch: the parts' numbers are written as text where they
are read, so a part's text is one `table.concat` a range instead of a loop in Lua over every number (most of
`bse.text`, 9-10 ms an update at -62,-26: 1.3 -> 0.4 ms a tick live); each lane's meta is kept for its re-sends (`bre`,
reloads); a lane of one item is read by its totals (one call instead of four); the lines' lengths are cached; the
movers' list is written as text with each mover's prototype id read once a search (a send of ~150 movers was 6.6 ms,
`helpers.table_to_json` and five calls a mover); the belts' scan reads at most two fresh chunks a tick once a scan
exists (`bs.scan` 30-85 ms on one tick when the chunk lists expired together). Measured at -62,-26 (the perfbridge2 round, docs/BELT-SIM-PLAN.md: the join's first 90 s traced, 2 runs each): the
bridge 13.1 / 12.0 -> 11.5 / 12.3 ms a tick median, p90 31 / 30 -> 26 / 26.5; the join's first 10 s 23.4 / 22.6 ->
18.6 / 18.4 ms median, ticks over 16.7 ms there 423 / 432 -> 353 / 333 of 600; game UPS median 40.8 / 43.0 -> 45.3 /
45.8, p10 31 -> 35.5; `bse.text` 1.3 -> 0.45 ms a tick, movers 2.0 -> 1.0-1.2; live visible 95.9% either way, phantoms
2.4-2.6% -> 2.0-2.8%.

### Watching with the normal game

The server also accepts regular Factorio clients on `127.0.0.1:34197` (Multiplayer → Connect to
address; a server the menu started uses the free game port it picked, 34501 or so, or the port
you host on). You get your own character next to the 3D client's, with all the normal GUIs.

**Ctrl+F9** (Show in Factorio) in the client brings Factorio's window to the front, or starts
Factorio joined to the server the client started. While you play there, the bridge drives your
player's character, so both windows show the same one. The mod adds the same key in Factorio
("Show in Zenith"), which brings the client back and minimises Factorio (Settings → Other →
Minimise Factorio in Zenith turns that off). Checked with a real Factorio 2.1.24 window in
single-player: a minimised Factorio keeps running the game at 60 UPS.

**Modded saves from the menu.** Opening a save from Zenith's menu starts its server with the save's
mods: every mod in your Factorio mods folder (beside Factorio's saves) is linked into the server's mods
folder (hard links for zips, junctions for folders), the mod list starts from everything off, and
`factorio --sync-mods <save>` turns on the save's mods at its versions; the bridge is then turned on
again. A mod the save needs that isn't in your folder stops the start with Factorio's list of what is
missing.

**Starting Zenith from Factorio.** Start Factorio through `server/factorio-with-zenith.ps1` and
Ctrl+F9 in the game starts Zenith when none is connected: Zenith joins that game, comes to the
front and minimises Factorio. With Steam, set Factorio's launch options (Properties → General) to

```
powershell -ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\ProgramData\Zenith\factorio-with-zenith.ps1" %command%
```

the same line on every PC: each time Zenith starts it puts its launcher (`server/factorio-with-zenith.ps1`,
in every download) in `C:\ProgramData\Zenith`, updating it with each version (add `--enable-lua-udp <port>` after `%command%` for a port other than 34200). The script opens
the bridge's port, listens on 127.0.0.1:34209 while Factorio runs, and starts whatever Zenith ran
last on this PC (Zenith writes how to start it to `launch.json` in its user folder each time it
starts, so run it once first). Factorio's opening cutscene holds keys back: Ctrl+F9 works once
it has ended (Tab skips it). Settings → Other → Copy launch options puts that line on the clipboard.
Open Zenith before setting the line: until Zenith has put the launcher there, Steam can't start
Factorio with it. The script answers the bridge (`launching`). If nothing answers within 0.75 s
(Factorio wasn't started with the launch options), the bridge's window in the game lists the two
steps with boxes to copy from: get Zenith (the releases page) and open it once, then the launch
options line. If the script answers but has no Zenith to start (never opened on this PC, or moved
or removed since), the window shows only the first step. A player who has the bridge from the mod
portal and no Zenith gets the same window. Each step is logged to `factorio-current.log` as a
`[Zenith] Show in Zenith` line. If Zenith is already open (its menu), the script brings it to the
front.

### Several 3D clients on one server

Start a second client on the same machine and connect it to the same server: it binds the next
free UDP port (34202, 34203, ... up to 34208) and gets a character of its own. Each client sees
the others walking around. `/f3d-status` lists them. Single-player plays one character, so there
the newest client takes over instead.

## Single-player (hybrid mode)

**New.** I've played it once, side by side with Factorio's window, on Factorio 2.1.24:
`send_udp` and `recv_udp` work without a player argument in single-player. It hasn't been tried
much beyond that, so the headless server above is still the main setup.

The 3D client can also drive your own character in a normal single-player game:

1. Copy or link `mod/factorio-3d-bridge` into your mods folder (`%APPDATA%\Factorio\mods` on
   Windows, `~/.factorio/mods` on Linux).
2. Add `--enable-lua-udp 34200` to Factorio's launch options (Steam: Properties → Launch Options).
3. Load a save, then start the client and use Single player → Single-player (hybrid) → Connect
   (`127.0.0.1:34200`).

Inventory, crafting and machine GUIs work in the Factorio window as usual; the 3D client's own
machine screens work too.

The 3D client's quickbar is your character's own (both windows show the same one). The bridge
doesn't chart the map around you here; your player does. To check that the bridge's calls work
on your own character, type `/f3d-selftest` in the game's console (`~`): it prints one PASS or FAIL
line per check (reach, selecting an aim target, the quickbar, charting, sending to the client) and
puts back what it borrowed. On a server the same command answers over RCON
(`python3 tools/rcon.py /f3d-selftest`).

## Client controls

These are the defaults. The keys you changed in Factorio's own Settings → Controls (its `config.ini`)
replace them, so both answer the same keys (Settings → Controls → "Use the keys set in Factorio";
a binding changed in Zenith's Settings still wins). Mouse bindings set in Factorio aren't used.

| Input | Action |
|---|---|
| WASD / arrows (or a gamepad's left stick) | Walk, relative to the camera, at any angle (the bridge steers Factorio's 8-way character to follow it). The stick walks only on a gamepad Godot recognises, once it has been seen centred: pedals, wheels and throttles are left alone |
| Right mouse (hold) | Mine what's under the cursor; a train, wagon, car, tank or spidertron under it first (issue #10: not the rail beneath), with what is inside it |
| Enter | Get into the nearest vehicle (car, tank, train, spidertron) or out of it |
| Spidertron remote (shortcut bar) | Drag: select spidertrons · Shift+drag: add · right-drag: remove · click: send them there · Shift+click: queue a waypoint |
| WASD in a vehicle | W accelerate, S reverse, A/D steer (relative to the vehicle) |
| F (hold) | Pick up items lying on the ground next to the character |
| Space (hold) | Shoot at enemies near the character (the game picks the target) |
| C (hold) | Shoot at the cursor |
| Tab | Switch to the next gun (or click a gun in the weapon slots left of the quickbar) |
| E | Open the character window (inventory and armour/weapons/ammo on the left, hand-crafting on the right), whatever is under the mouse. With any window open, E closes it |
| Esc | Close the open window, machine screen, map view, chooser or remote view; with none open, the Game menu (Resume, Load game, Save game, Save as, Settings, Exit; Players when others play too) |
| T | The technology screen: the research in progress and queue, the selected technology (cost, time, prerequisites) with Start research / Add to queue / Cancel, and the tree on the right. T, E, Esc or × closes it |
| M | The map view: the charted map over the whole window (north up) with your character's arrow, the map tags and trains. Drag (left or middle mouse) or the movement keys (WASD/arrows, or as rebound) move it (Shift: faster), the wheel zooms about the mouse. Right click: on a tag, edit or delete it; on a ghost, remove it; elsewhere, create a tag there (icon, name, Confirm). Double click also creates or edits a tag. M or Esc closes it (Esc closes the tag dialog first). The game keeps running underneath, and the character doesn't walk while it is open |
| Minimap (top right) | The charted map around the character (in the map view or remote view, around what that looks at), north up, with tags and trains. Click it to open the map; the wheel or its + / − buttons zoom it |
| Click a stack (inventory or machine) | Pick it up into the cursor, as in Factorio (right click: half). The cursor shows its icon and count; its slot shows Factorio's hand |
| With a stack in the cursor, click a slot | Put it there (a different item swaps, so the other stack is now in the cursor); right click drops one; click its own slot, or Q, to put it back. Left mouse in the world builds it (only stacks from the inventory) |
| Shift+click a stack | Move it between the inventory and the open machine (Ctrl+click: all of that item) |
| Click a recipe | Hand-craft one (right click: five, Shift: as many as possible). Hover for ingredients (red where short), time and products |
| Crafting queue (bottom left) | Each queued craft with its count; the first fills with Factorio's orange pie. Click cancels one, right click five, Shift+click the whole entry |
| 1 – 0 | Hold the item pinned to that quickbar slot (again: put it away). With the character window open: pin the hovered item, or the held one, to that slot |
| Click a quickbar slot | Hold its item; with an item held, pin that item there. Right click clears the slot. Inventory items can also be dragged onto it |
| Left mouse (hold and drag) | Build the held item along the way, as Factorio drags: belts follow the cursor and turn corners (with Smart belt building, Settings → Interface, an obstacle or a crossing belt is jumped with undergrounds), pipes go in a line (pipes-to-ground over obstacles), poles at their wire reach, anything else one footprint after another; a faster belt dragged over a line replaces it. Its ghost is green where it can go, red where it can't (none left, beyond the 10-tile build reach, something in the way). Over a window the mouse only works the window: nothing behind it is hovered, built or mined |
| Holding a blueprint, left click | Place its ghosts there (shown under the mouse first; robots build them; building the item over its ghost fills it in yourself). Ctrl+Shift+click: super-forced (trees and rocks in the way are marked). A book places its active page; Shift+mouse wheel picks the page |
| Holding a deconstruction or upgrade planner, left drag | Mark the area (Shift: cancel the marks). What it will take is highlighted in its colour while dragging |
| B | Blueprint library: My blueprints (kept by the client in `user://blueprint-library.json`), the save's Game blueprints and, when the bridge plays the save's own player, that player's library. Click takes one into the cursor, right click opens it (books open in place), drag moves it or drops it into a book, Del deletes; Import string takes a string copied from Factorio or a website; New book / planner buttons |
| Right click a blueprint, book or planner in the inventory | Its window: label, icons, description; a blueprint's components (click one to take it out), what it includes, snap to grid and absolute snapping; a book's pages; a deconstruction planner's filters, whitelist / blacklist, trees and rocks only, tile mode; an upgrade planner's from → to rows. Save writes it back; Export string copies Factorio's string |
| Ctrl+mouse wheel | The held item's quality (the qualities your force has) |
| Ctrl+Shift+left | Super-forced build: a ghost, and what stands in the way is marked for deconstruction |
| Holding tiles (stone brick, concrete, landfill, foundation...) | The brush shows at the cursor (green, red where the tile can't go, blue as ghosts with Shift). Left mouse paints, right mouse mines placed tiles back; Numpad + / - change the tile area; R turns hazard concrete |
| Holding rails | Click a rail end, or anywhere along a line to fork a new one off it, to start the rail planner there: the path of straight and curved rails to the cursor shows, click (or drag from the end) builds it and carries on from its end; ghosts where your rails run out. Alt+R (while holding rails; otherwise it gives red wire): rail layer (a ramp up, elevated rails with supports). Right click lets go |
| Holding grenades, cliff explosives, capsules | The throw range and blast show; left click throws at the cursor (hold to keep throwing). Fish heal you |
| R / Shift+R | Rotate the held item (rails by 45°), or the hovered entity. Building the same belt over a belt turns it; a faster belt (or anything that fast-replaces) replaces it |
| Left mouse with nothing held | Open the hovered building's screen (chests, assemblers, furnaces, labs, drills, boilers...) beside your inventory: its name, status (Working, No ingredients, No fuel, No power...), energy, slots and fluid boxes. E, Esc or its × closes it |
| Recipe slot in an assembler's screen | Click to pick its recipe from the grid below; right click clears it. Items it was holding come back to you |
| Q | Put the held item (the cursor stack) away; with nothing held over an entity, a train, wagon or vehicle, the pipette: hold its item, turned the same way (a ghost cursor when you have none) |
| Z (hold) | Drop one of the held item: into the machine or chest under the mouse, onto a belt, or on the ground |
| Shift+left click | Holding an item: build a ghost of it for robots. Holding nothing: paste the settings copied with Shift+right click (recipe, filters, requests, combinator settings) |
| Ctrl+left / Ctrl+right click an entity | Fast transfer: the held stack (half) into it, or with nothing held its output (half) into your inventory |
| H / V | Flip the item being built, or the entity under the mouse (machines with fluid boxes) |
| Alt | Alt-mode: recipe and filter icons over every machine in view (they come with the buildings, issue #9), Factorio's fluid arrows on machines and pumps and a recycler's output arrow, inserters' arrows when chosen in Settings → Interface (kept between games); it toggles when Alt is let go, unless Alt was held for an Alt+click |
| Alt+click | Factoriopedia's page of the thing under the mouse (in the world, or a slot or technology in a window) |
| F2 | Factoriopedia |
| L | Logistic networks: every network of the force, its robots and items |
| Ctrl+C / Ctrl+X, drag | Copy or cut an area to the clipboard; then left click pastes it (R turns it), right click puts the tool away. Ctrl+V pastes the clipboard again |
| Ctrl+Z / Ctrl+Y | Undo / redo your own building (marks it for deconstruction) and mining (puts a ghost back), blueprints placed, planner marks, pasted settings and rotations |
| Alt+B / Alt+D / Alt+U, drag | A new blueprint of the area in your inventory (its window opens) / mark the area for deconstruction (Shift: cancel) / the upgrade planner (a new one if you have none) |
| Alt+R / Alt+G / Alt+C (or the shortcut bar) | Red, green or copper wire: click an entity, then another to connect them (the same pair again disconnects them); the wire then hangs from the second, so a row is wired click by click. The hanging wire is drawn to the mouse with a ring for its reach (grey past it). Click a combinator's front (output) or back (input) half, a power switch's left or right side. Right click lets go of the wire, again puts the tool away |
| Shift+click a pole | Remove its copper cables |
| Open anything on a circuit network | Its circuit connection (enable/disable condition, read modes, set recipe / filters / stack size...) and logistic connection settings; combinators in full (decider conditions with and/or and red/green inputs, outputs; every selector mode; constant combinator sections); lamp and train stop colour, speaker, pump filter, turret priority targets, display panel messages |
| P / K | Production statistics (items, fluids, pollution, building counts; this surface or all; Factorio's graphs: click a row's box to draw it) / kill statistics, over Factorio's 8 time scales |
| ` or / | Chat (a line starting with / is a console command, run over RCON when this client started the server) |
| Ctrl+F | Search the crafting recipes |
| Shift+1 – 0, X | Show quickbar page 1–10, swap the two quickbar rows |
| Middle click an inventory slot | Filter it to its item (or the held one); again clears it |
| Click a car or wagon | Open it: fuel, trunk, ammo, cargo; a train's window has Factorio's schedule (every wait condition, and/or), interrupts, Go to station now (a temporary stop), the whole train's cargo and fuel, and a camera above it. A train stop's: name, limit, priority, circuit settings |
| Map: zoom in past the closest zoom | Remote view there (in Factorio's angle, F6's view), on any surface the map shows: WASD moves it, Esc or M goes back to the character, and zooming back out goes to the map there. Ground no working radar, roboport (its construction area) or the character sees lies under a dark fog, with nothing moving there |
| Ctrl+F9 | Show in Factorio: bring Factorio's window to the front on the same game (or start it joined to the server the client started) |
| , / . | Turn the camera 90° |
| Middle-mouse drag | Turn the camera freely (left/right) and tilt it (up/down) |
| Page Up / Page Down | Tilt the camera |
| Mouse wheel | Zoom |
| F6 | Jump to Factorio's own view (north up, from above at Factorio's angle and default zoom); again to go back |
| F5 | First person: see through the character's eyes, mouse looks, aim with the crosshair; F5 again to go back. The mouse is freed while a window is open |
| F7 | Perspective or orthographic for the view in use: in the map's remote view it changes the map's projection, elsewhere the normal view's (in Factorio's view, F6, used on leaving it); kept in Settings > Camera |
| F1 | Show or hide the help panel (off by default): every control under the key bound to it now (rebound in Settings → Controls, or Factorio's own keys), grouped (moving and camera, fighting, building, blueprints and wires, inventory, windows, the map, Zenith's own), then each add-on's while it is on; the debug menu only in dev builds. When the window is too short for it, the mouse wheel over it scrolls it |
| F4 | Show or hide the debug line (tick, chunks, entities, packets, the game's UPS, FPS) |
| Alt+L / Alt+F / Alt+E | Personal logistic requests, the personal roboport, exoskeletons on or off (also on the shortcut bar) |
| Ctrl+= / Ctrl+- / Ctrl+0 | UI scale up, down, back to automatic |
| Ctrl+F12 | The debug menu (dev builds only, see "The debug menu" below) |
| Add-ons' keys | Each add-on's own, listed under it in Settings → Controls and in F1's help while it is on. The bundled Cinematic camera: F8 free camera, Shift+F8 its window, Ctrl+F8 idle mode, Alt+F8 camera mode, Ctrl+Shift+F8 record, F11 hide the interface, F12 screenshot; while its camera flies, WASD, E/Space and Q/Ctrl, = and -, O orbit, T follow, N next, V placement, K add a path point, P play the path, B letterbox |

Client command-line options go after `--` (Godot: Project → Project Settings → Run, or the
command line): `--factorio-port=34200 --port=34201 --models=/path/to/glb/folder
--factorio-data=/path/to/Factorio/data`. `--models=` only fills in entities without a model of
their own; add `--models-first` to let the folder's models replace the built-in ones. Without `--models=`, the
`models` folder beside Zenith (the checkout's root, or beside Zenith.exe) is used that way when it
holds any; `--no-custom-models` leaves it out.
`--addons=<folder>[,<folder>...]` loads add-ons from those folders (an add-on's own folder or a
folder of add-ons), always on, ahead of installed ones with the same id ([ADDONS.md](ADDONS.md)). `--camera=factorio`, `--camera=first-person` or
`--camera=<yaw>,<pitch>,<distance>[,ortho]` start in that view instead of the Camera setting's
(`--camera=0,48,14,ortho` is close to Factorio's own; a distance past Furthest zoom is kept for that run). `--screenshot=<file.png>[@seconds]` saves
the window once (default after 10 s; needs a window, which keeps the project's size and mode;
`--scale-like-full-screen` does full screen's Resolution sums with that window as the monitor). `--full-shot=<file.png or folder>[@seconds][,<width>x<height>]`
takes one the way the Cinematic camera's F12 does (`api.view.screenshot`: the moment held, full detail, the view's chunks, the game held for the picture), default after 10 s. `--open=<unit>` opens that entity's machine screen once
it has loaded (for screenshots and debugging). Also for screenshots: `--ui=inventory` opens the
character window at start, `--ui-sample` feeds sample recipe details (crafting tabs, ingredients)
through the hooks the mod's full UI data will use and pins a few quickbar items,
`--ui=research` opens the technology screen, `--ui-hold=<item>` picks up that item's first stack after 4 s,
`--ui-craft=<recipe>:<n>` hand-crafts after 3 s (to see the queue), `--ui-hover=<x>,<y>` keeps the mouse
there from 5 s on (tooltips, the cursor stack, the build ghost), `--ui-hover-unit=<unit>` keeps it over that entity
wherever it is drawn (its entity info), `--ui-press=<node name>` clicks that
button or slot after 7 s (popups: `SecondOperand`, `Signals`, `ChangeGroup`), `--map` opens the map view at start
(`--map-zoom=<GUI pixels per tile>`, 0.25 to 8; `--map-tag=<x>,<y>,<icon item>,<text>` adds a tag
after 3 s; `--map-edit=<x>,<y>` opens the tag dialog at that window point after 5 s), and `--ui-scale=1.25`
overrides the UI scale (by default 100% up to a 1080-line window, then in steps of 25%, like
Factorio's automatic scale: 150% at 2880x1659). `--alt-mode`, `--stats=<item|fluid|kill>`,
`--chat=<text>` and `--remote=<x>,<y>` turn on Alt-mode, open statistics (also `pollution`,
`build`), say a line, or look somewhere in remote view after 3 s. `--ui=networks` opens the logistic
networks window, `--pedia=<kind>:<name>` Factoriopedia on a page after 4 s (`item:assembling-machine-2`,
`technology:mining-productivity-3`), `--research=<technology>` selects one in the technology screen.

The inventory, crafting, quickbar, weapon slots, crafting queue, technology screen and machine
screens are drawn with Factorio's own GUI graphics, fonts and names (technology icons, status
dots, the hand, empty-slot pictures, locale files), read from your install like the item icons (`core/graphics/gui-new.png`, laid out as
`core/prototypes/style.lua` does, and `core/fonts`); nothing of the game's is copied into this
repo. Without an install they fall back to flat panels in Factorio's colours. The quickbar is kept
by the client (in Godot's `user://quickbar.cfg`) until the mod sends one.

Networks and ghosts are drawn like Factorio's: copper wires sag between the poles' insulators (red
and green circuit wires beside them), a machine with no power blinks Factorio's red lightning icon
(one tile wide; low power has no icon, as in Factorio: it only slows machines), lamps without power
stay dark, storage tanks show their level in the fluid's colour through a window on their south
side, and hovering an entity with fluid or a power problem lists it by the cursor. The entity info
panel on the right (Settings → Interface → Entity tooltip on the side) shows the hovered entity as
Factorio does: its status (No power, Low power...), recipe, modules, the beacons reaching it and
their effects (a beacon: its modules and the machines it reaches), and for a powered building
Factorio's "Consumes electricity" (Max. and Min. consumption and the Electricity bar from its
buffer). Hovering a roboport draws orange lines to the roboports it is linked to; holding one
draws the links round where it would go. Ghosts are the entity in translucent blue-white; entities
marked for deconstruction get the red cross, for upgrade the green arrow. The icons come from your
install's `core/graphics` (plain coloured discs without one).

Items on belts and on the ground are drawn as cards with the item's icon, read from your Factorio install (the
client looks beside the factorio.exe set in Settings → Factorio first, then the usual Steam and
standalone locations; `--factorio-data` points it at the `data` folder otherwise). The install is
found once at start-up: after changing that setting, restart Zenith (Settings and the main menu say so). Without icons, items are small coloured blocks. The headless build
has no graphics, so it can't supply icons.

### Modded games

A modded game shows each mod's own icons, ground, decoratives, names and, for buildings Zenith
has no model of, the mod's own picture on a card facing Factorio's camera.
The bridge lists every prototype's graphics at the data stage and sends the list once per set of
mods (`gfx`, docs/PROTOCOL.md); the client keeps it in `user://mod-graphics/` and reads the pictures
from the mods themselves, never copying them: the server's mods folder (`server/data/mods`, which
the menu's servers use), then your own (`%APPDATA%\Factorio\mods`, `~/.factorio/mods`), then a
portable install's, or `--factorio-mods=<folder>[;<folder>...]` first. Mods may be folders or zips;
the version the game runs is picked when a folder holds several. Load game on a modded save links
your own mods folder's mods into the server's and runs Factorio's `--sync-mods` on the save, so the
server runs exactly the save's mods at its versions, then turns the bridge on; a mod missing there
(or there at another version) is named with its version, since Factorio, with no mod portal login on
the server, says only "unknown error". Their machines' pictures move while
they work (16 frames of each loop, when Settings > Graphics > Animate modded buildings is on; off by default). What
isn't drawn yet: those cards' working lights at night, and a mod that changes graphics in its own `data-final-fixes`
after the bridge's (its list is made before) shows the earlier pictures.

The ground uses Factorio's own tile pictures from the same install: `base/prototypes/tile/tiles.lua`
(and Space Age's) say which picture, variant sizes, weights and layer each tile has, and the
pictures come from `*/graphics/terrain/`. Each tile shows one of Factorio's 1x1, 2x2 or 4x4
variants, picked per position the way the game does, so fields don't look tiled; higher tiles
(by Factorio's layer order: grass over dirt over sand, floors over ground) spread over their
lower neighbours with a ragged edge like Factorio's transitions; concrete and other floors keep
crisp edges. Water uses Factorio's water pictures with deep and shallow water blending, and the
coast wanders off the tile grid with a wet rim instead of square banks. Pictures are loaded the
first time a tile type appears (the console prints `Terrain: <tile> ...`). Without an install,
or with `--plain-terrain`, the ground is the map colours with procedural detail.

### The map and the minimap

The map and minimap show what your force has charted, drawn by the mod like Factorio's map (tile
colours, then ore, trees and rocks, then buildings in their map colours; see "Map" in
docs/PROTOCOL.md). The mod sends at most 2 tiles per pixel and 4 chunks a tick, so the client asks
only for what is on screen, a 32 x 32 chunk block at a time from the middle out, asks again every
4 s (minimap) or 6 s (map view) for the same area, and skips ground it knows is uncharted except
at the edge of charted ground and in a full pass once a minute. The mod keeps a chunk's picture
for 30 s while as many entities stand in it and nothing was built, mined, rotated or destroyed there,
and (the perfbridge2 round) trusts the count itself for 20 s after it was made unless such an event
came, so a refresh of a kept chunk reads nothing but its pollution and signals; its robot dots come
from the movers' last search of the live-update area where that covers the chunk (a chunk outside it
is searched as before). A change no event tells of (a tree dying) shows within 20 s. Every 30 s, when it is idle, the
minimap also asks for the area the map view opens on, so the map opens filled in. Uncharted ground
is black, and charted ground no working radar (or the character) sees is dimmed, as on Factorio's
map. In Zenith roboports reveal too (Factorio's don't): ground whose chunk has its middle in a
roboport's construction area counts as seen, on the map, the minimap and in the 3D remote view.
The bridge's character has no player, so the mod charts around it itself while a client is
connected. While the map view is open the minimap shows what the map looks at, and in the 3D
remote view what that looks at, as in Factorio.

Over the chart, the map view draws what Factorio's map view settings switch (Factorio's grid of
icon buttons under the side menu, lit orange when on; also in Settings → Interface): tags, electric
networks (poles' supply areas and their copper wires), logistic networks (roboports' logistic and
construction areas), turret coverage, train stop names, worker robots, rail signal states, recipe
icons and pollution. Trains are drawn live in their own colours where radars see them. The mod sends them with each chunk's chart (`ov`, see
docs/PROTOCOL.md "Map"); the minimap, as Factorio's, draws none of them (only trains, train stops'
markers and tags). The logistic layer shows every roboport
on the surface, not only those on the charts loaded: the client asks the mod for the whole list
(`mrp`) every 10 s while a map or the remote view needs it. Overlapping areas read as one region,
as on Factorio's map.

**Other surfaces.** The map view's top-left panel lists the planets that have a surface and your
space platforms (Factorio's surface switcher); clicking one shows that surface's map and tags (tags
added there go on that surface). A planet's map centres on your cargo landing pad there (its middle
when there is none), a platform's on its hub. Closing the map goes back to the character's surface. Zooming in past the closest zoom on another surface opens the remote view
there: the mod streams that surface's world until the remote view ends.

**Building from the map.** Zooming in past the closest zoom goes to remote view (the camera moves,
the character stays). There, as in Factorio 2.0, whatever you place is a ghost for the robots,
blueprints and the copy / paste tools place ghosts, the deconstruction and upgrade planners mark
areas, and right-click (mining) marks the entity under the mouse for deconstruction. All of it only
on ground the force has charted ("You can't build in an uncharted area"), and on another surface
too. On a platform only what the platform can build is placed: nothing over empty space, nothing
its gravity forbids (both red in the preview). Mining by hand, picking up, shooting, dropping, fast
transfers, wires and throwing wait until you are back with the character. Buildings where radars
or roboports see open from the remote view for their settings; their items stay out of reach. Holding a module and
clicking a building or ghost asks for it (an item request, brought by robots or a platform's hub;
within reach it goes straight in), and so does clicking a module slot of a screen opened from the
remote view; right click on that slot takes the request back.

**Trains.** The side menu's Trains button, or "All trains" in a train's or stop's window, opens
Factorio's trains overview: Trains, Stations and Groups tabs, and a card for every train of the
force with a live view of it from above, its state, carriages and cargo; clicking a card looks at
the train in remote view.

The map's options are in the `[map]` section of `user://settings.cfg`;
`client/scripts/ui/ui_settings.gd` gives them limits and a `changed` signal
(`UiSettings.shared().set_value("map/minimap", false)`):

```
[map]
minimap=true        ; show the minimap
minimap_size=240    ; its side in Factorio GUI pixels (times the UI scale), 120 to 480
minimap_zoom=1.0    ; GUI pixels per tile, 0.25 to 4 (Shift + wheel over the minimap changes it)
minimap_tags=true   ; tags on the minimap
show_tags=true      ; the map view's switches (the map view only): show_tags, show_electric,
show_turrets=false  ; show_logistic, show_turrets, show_stops, show_robots, show_signals,
                    ; show_recipes, show_pollution (off by default)
```

### Sound and effects

The client plays Factorio's own sounds and draws its smoke, explosions and flashes, read from your
install at runtime like the icons (`data/base/sound`, `data/core/sound`, and sprite sheets in
`data/base/graphics/entity`); nothing of the game's is copied into this repo. Working machines
near the camera hum with their prototype's `working_sound` (assemblers, furnaces, drills, boilers,
steam engines, labs, pumps, radars...; at most 12 at once, nearest and loudest first, at most 3
of the same sound), and cars and trains have engine sounds while they move. The character has
footsteps by ground (grass, sand, dirt, concrete, belts, rails, ore), mining hits, building,
rotating and mined-out sounds, gunshots, and biters call and die. Burner furnaces, boilers and
burner drills smoke while they work, steam engines steam, shots flash at the muzzle and where they
land, and things that die explode and leave a scorch mark and a burnt remnant for a while. Biters
and spitters collapse into their corpse, which lies in a blood puddle for Factorio's 15 minutes;
worms leave theirs too. Without an install the client is silent and the effects are plain soft blobs.

Volumes are in the `[sound]` section of `user://settings.cfg` (Settings → Sound):

```
[sound]
master=0.8      ; everything
effects=1.0     ; game effects: the five below and everything else in the world
walking=1.0     ; footsteps          environment=1.0 ; machines and vehicles
weapons=1.0     ; shots              explosions=1.0  ; explosions
enemies=1.0     ; biters
ambient=1.0     ; wind and the planet's background sounds
music=0.0       ; Factorio's soundtrack (the planet's own tracks), off by default
ui=1.0          ; window clicks
walking_on=true ; <name>_on=false mutes that slider
max_voices=12   ; machine and vehicle loops playing at once
output_device="Default"
[graphics]
effects=true    ; smoke, dust, flashes, explosions
```

Command-line options (after `--`) override the file for that run: `--volume=0.5` (master),
`--sfx-volume=`, `--music-volume=0.3` (turns the soundtrack on), `--ui-volume=`, `--mute`,
`--max-voices=8`, `--no-fx` (no smoke or explosions). For debugging, `--sfx-log` prints every
sound started and, every 5 s, how many voices are busy, and `--fx-demo` plays the character
through a short script (walk, mine, build, rotate, shoot, then a staged explosion; `--fx-demo=space`
shoots at enemies instead) so sounds and effects can be checked without input. The UI plays
Factorio's GUI sounds through `Sfx.play_ui("gui-click")` (`client/scripts/fx/sfx.gd`).

Sounds follow Factorio's own rules, read from its prototypes (`client/scripts/fx/sound_bank.gd`):
each sound's volume, variations and pitch range; `audible_distance_modifier` and the attenuation
curve over the audible distance (40 tiles, heard from the middle of the view, quieter zoomed out);
`aggregation` (at most `max_count` of one sound at once, the rest dropped or quieter); working
sounds limited to `max_sounds_per_prototype` per kind of machine, faded in and out over the
prototype's `fade_in_ticks`/`fade_out_ticks`, with idle and activate/deactivate sounds; a limit per
category with `priority`; a limiter on the master output so nothing clips. Each planet plays its
`persistent_ambient_sounds` (ambience and wind crossfaded by zoom, the occasional distant sound)
and its own music (`client/scripts/fx/ambience.gd`). The engine's own constants (audible distance,
default curve, category limits) aren't in the data and are chosen by ear. `--fx-demo=stress` adds
ten volleys of 30 biter deaths, 8 explosions and 12 shots, to measure with `--sfx-log` (which also
prints the most voices at once, peaks per bus and sounds started over the same file).

What weapons fire is drawn from Factorio's own prototypes and sheets
(`client/scripts/fx/weapon_fx.gd`, data in `client/data/weapon_fx.json` from
`tools/weapon_fx_index.py`): each shot's muzzle flash, bullet hit and shell casing at the gun's own
rate; rockets with their smoke trail and light, shotgun pellets, cannon and artillery shells,
grenades and capsules on their arc, flamethrower streams, tesla and laser beams, the railgun's beam;
every explosion prototype's animation, scorch marks, fires with burnt patches, poison and slowdown
clouds, and each entity's dying explosion. A headless server doesn't make the explosions Factorio
marks "only when visible" (muzzle flashes, bullet hits, a rocket's explosion), so the client plays
them itself. `--weapons-demo` fires the character's three guns in turn and throws a grenade and a
poison capsule, printing what it drew; against the mock use
`tools/mock_server.py --guns shotgun,rocket-launcher,flamethrower` (the mock's version is
`tools/mock_shots.py`), against a server give the character guns first.

## Add-ons

Add-ons ([ADDONS.md](ADDONS.md)) are folders with an `addon.json`, found at start-up in
`user://addons` (on Windows `%APPDATA%\Godot\app_userdata\Zenith\addons`), in `addons/` beside
the executable (in a checkout, the repo's root), and in any `--addons=<folder>`. The main menu's
Mods window lists them with a switch each (saved in the settings file's `[addons]` section, on
when absent) and why one wasn't loaded (a newer add-on API than this Zenith's, a broken
`addon.json`, an entry script with an error). The log says which started. Their keys show in
Settings → Controls under each add-on's name; their data is kept in `user://addons-data/<id>/`.
An add-on with the camera turns the player's controls off until it hands it back; Zenith takes it
back itself for a ride to a space platform.

## VR (experimental)

The client can draw the game in a VR headset through OpenXR: SteamVR (Index, Vive, Quest over
Link), Meta Quest Link or Air Link, Windows Mixed Reality. It runs on the PC next to Factorio (the
bridge is localhost-only), so a standalone headset streams from the PC. Start the headset's
runtime, then:

    godot --path client --xr-mode on -- --vr --factorio-port=34200               # tabletop
    godot --path client --xr-mode on -- --vr=first-person --factorio-port=34200  # first person
    ... --vr --vr-hand=left                                                      # left-handed

(`--factorio-port` connects at once; the menu is only on the desktop window. Without
`--xr-mode on`, or without a headset, `--vr` only prints a warning and the game runs as usual.)

**Tabletop** (the default) works like a map editor: the factory is a model on a table at waist
height in front of you. Grab it with a grip and drag it around; grab with both grips to move,
zoom (pull your hands apart or together) and turn it in one go. The chunks and live data (belts,
trains, robots) follow the table's centre, so you can look over the whole base while your
character stays where it is; clicking the other stick puts the table back on your character at
your height. **First person:** you stand where your character stands, a tile to a metre.

| | Pointer hand (right; `--vr-hand=left` swaps) | Other hand |
|---|---|---|
| Trigger | Left click: build, open, select (hold to drag-build) | Shift, while held |
| A / X | Right click: mine, cancel (hold to keep mining) | Character screen (E) |
| B / Y | Rotate (R) | Show the HUD panel in front of you, or hide it |
| Stick | Tabletop: turn the table 45° (left/right), zoom (up/down). First person: turn 30°. On the panel: scroll | Walk, the way you look |
| Stick press | Pipette (Q) | Tabletop: the table back on your character |
| Grip | Grab the table | Grab the table (both grips: move, zoom, turn) |
| Menu | | Esc |

The laser from the pointer hand is the mouse: where it meets the ground is where you build and
mine, and on the HUD panel (Factorio's windows, quickbar, minimap) it clicks like the mouse. The
desktop keyboard keeps working.

Not done yet: the main menu and the in-game Esc menu stay on the desktop window, Alt-mode labels
aren't placed on the panel, first person has no movement prediction (you feel the bridge's
delay) and no comfort options (vignette, smooth turn). Nothing of this has been tried in a
headset yet.

## Sky and clouds

Each planet has its own sky (`client/scripts/world/sky.gd`): a gradient with the sun, stars at night
and clouds, following the game's time of day. Clouds use Factorio's own cloud noise from the
install (`core/graphics/clouds-noise.png`, a generated noise without one) and cast soft shadows
that drift over the ground, as Factorio's do on Nauvis, Gleba and Fulgora (opacity 0.25, from the
planets' `surface_render_parameters`). Vulcanus and Gleba have a coloured haze (Factorio's fog),
Aquilo a cold one; Fulgora's nights have lightning flashes. Settings → Graphics → Clouds turns
clouds, shadows and haze off (`[graphics] clouds=false`); `--clean-shot` and `--review-shots` do too.
`--sky=<planet>[@<daytime>]` shows another planet's sky and holds the time of day (0 noon, 0.5
midnight), for screenshots against the mock: `--sky=fulgora@0.45`.

## Looks

Settings → Graphics → **Look** (`[graphics] look`) sets how the world is lit, tonemapped and
coloured (`client/scripts/world/looks.gd`):

- **Factorio** (the default): matched to Factorio's own picture of the same scene
  (`tools/look/factorio_reference.py`). Linear tonemapping; the sun held where Factorio's shadows
  fall (east and a little south), its shadows as dark as Factorio's; no sky reflection on the
  ground or grass (it was what washed the colours out); a fill light from the camera's side on
  models, as Factorio's sprites are lit; and Factorio's own colour lookup for each planet and time
  of day, read from the install (`core/graphics/color_luts`, `space-age/graphics/lut`; Nauvis by day
  is Factorio's identity, its darkening at night left to Zenith's light so lamps still light).
- **Classic Zenith**: the look before 0.1.3 (filmic tonemapping, the sun crossing the sky).
- Add-ons' looks (`api.shaders`, docs/ADDONS.md), such as the Cinematic shaders add-on
  (`addons-src/cinematic-shaders`), whose sun really sets: it sinks in the west with long shadows, a
  colour from the air it crosses and a blue hour after it, each planet in its own colours.

The Factorio look's ground has no sunset (Factorio's has none); from low down its sky shows the sun
going down, restrained, while the light stays where Factorio's shadows fall.
`--sky=<planet>@<daytime>` holds a time of day with Factorio's darkness for it, for screenshots.

`--look=<id>` uses a look for one run (`factorio`, `classic`, `cinematic-shaders/cinematic`);
`--look-file=<file.json>` adds looks from a JSON file, for trying values without an add-on.

`python tools/look/factorio_reference.py [--looks factorio,classic]` makes a map, has a Factorio
window save its picture of a small scene at noon, takes Zenith's of the same place in Factorio's
view (F6) once per look on a headless server with the bridge (Zenith's default settings), and
compares the ground's colour, saturation and contrast (git-ignored `art-src/look/`). It adds and
removes a `steam_appid.txt` beside factorio.exe for the run, as `hybrid_cost.py` does.

## Decoratives

Grass, flowers, small rocks and decals lie on the ground as in Factorio, with the pictures from
your install (which picture each has is in `client/data/decoratives.json`, written by
`tools/decor_index.py` from `factorio --dump-data`; CI regenerates it and prints it when it
differs). Gleba's plants, corals and icebergs (Factorio's "object" layer) stand up as cards.
Settings → Graphics → Decoratives turns them off (`[graphics] decoratives=false`; the client then
stops asking for them, `dc` in the hello), and Decorative density draws a share of them (the
same ones each time). They are drawn round the character (or the remote view's point) out to
Decorative distance (64 to 320 tiles, default 192): all of them to 80 tiles, then half, then a
quarter past 136. The bridge sends a chunk's decoratives again when a tile is placed or mined in
it or something is built there; ones another mod's script removes stay drawn until the chunk's
next refresh.

Settings → Graphics → 3D grass raises grass and low plants near the character (off in the Low
preset): the same pictures on a small grid, tufts arching from their root and bushes rising where
the picture is thick, no shadows of their own, the flat picture left under them as their shadow.
Carpets (the wide patches of short blades most of a Nauvis meadow is) stand up as clumps of blades:
crossed cards, each a half-tile piece of the patch's own picture where it has plant, about half a
tile tall, cut out with alpha to coverage, bent by gusts from a drifting noise texture; further from
the character fewer stand. From Factorio's angle they cover what the picture shows; they fade back
into the flat picture over the range's last 10 tiles and as the camera zooms out. A chunk raises at
most 106,496 triangles' worth, tufts and bushes first and carpets from what is left: a real Nauvis
meadow (600 to 1,400 decoratives a chunk) raises nearly all of them. `-- --grass-stats` prints what it takes every
5 seconds, with the frame's GPU time and triangles.

When the camera isn't Zenith's own view round the character (an add-on's camera such as the
Cinematic camera's F8, first person, the remote view), the camera drawing leads instead
(client/scripts/world/view_priority.gd): 3D grass is centred half its range ahead of the nearest
ground the camera sees, gliding as the camera turns and fading down and up again across a jump
longer than the range; and Items in 3D's cap counts only the belt items in the camera's view (3
tiles' margin at its edges), nearest the camera first, the rest drawn as icons (both records paths,
GDScript and BeltDrawNative; the lattice's packed lanes are icons under any cap, as before). The bridge's
square of belt items already follows an add-on's shot (its focus), so nothing more is asked for.

## Mod settings

In a game the client's menu started: the client's Settings → Mod settings, sent over RCON at once.
In Factorio: Settings → Mod settings → Map. On a headless server started by hand, set them from
the server console or RCON, for example `/c settings.global["f3d-chunks-per-tick"] = {value = 2}`.

| Setting | Default | |
|---|---|---|
| Surface to stream | nauvis | Where the server's character lives |
| Chunk snapshots per tick | 1 | Faster world loading vs. script time per tick. Only chunks that must be read count: chunks the client kept (answered `same`) and ungenerated ones (`none`) don't wait for it, so going back to a surface (a Factorissimo building's door, a platform and back) takes a few ticks |
| Bytes sent per tick | 32768 | Caps queued world data per tick. While a screenshot loads its view (photo mode, `photo` in PROTOCOL.md) the bridge sends 4 times this and starts up to 8 chunk snapshots a tick, whatever the setting above |
| Max live-update radius | 192 | Movers and machine states beyond this aren't sent; caps the client's "Entity distance" (Settings → Graphics, default 192). A save keeps the value it had; on a server raise it with `/c settings.global["f3d-max-focus-radius"] = {value = 192}` |
| Moving entity update interval | 2 | Ticks between mover updates |
| Longest wait between searches for moving entities | 32 | The search of the live-update area for movers (6-12 ms every 8 ticks on the owner's save, finding the same few each time: 99% of what movers cost at -62,-26) waits twice as long each time it finds the same movers (by count and unit numbers), up to this many ticks; a search that finds anything else puts them back to every 8 ticks. A mover that appears while nothing else changed (a robot leaving its roboport, a train entering the area) shows up to that many ticks late; the minimap's robot dots come from the same search. 8: every 8 ticks, as before |
| Belt item, ground item and inserter radius | 24 | Items on the ground, inserter hands, fluids, heat, robots' cargo and plants' growth within this many tiles of the camera are sent; 0 turns them off. Items on belts go as far as the client's Belt item distance (Settings → Graphics), which Zenith always sends; this radius is used for them only by clients that don't. Lower it if a dense base costs too much script time |
| Belt item and inserter update interval | 6 | Ticks between updates; the client glides items and arms in between |
| Spread the bridge's periodic jobs | on | The hand-craftable counts (230 recipes, 45-80 ms on one tick whenever the inventory changed, about every 1.5 s on the owner's save), the machine states' search (every animated machine within the focus radius, 20-66 ms twice a second) and the planets' idle looks for spider legs and cargo pods (two area searches, 10-19 ms on the same 30th tick as the counts) run in slices over several ticks (32 recipes a tick; the area in 4 strips, one a tick) and on ticks of their own. The perfbridge round's trace at -62,-26 found these the bridge's biggest single-tick spikes after the belt updates' due tick. Off: as before |
| Starter kit | on | Freeplay items for the bridge's own character |
| Player to play as | (empty) | Whose character the client plays on a server; empty: the player who was online last. `/f3d-player` changes it while the game runs |
| Act as the player for other mods | on | When the client plays a player's own character (single-player, or the player to play as while they're connected), building, mining, rotating, pasting settings and opening machines go through that player, so other mods get Factorio's own player events (`on_built_entity`, `on_player_mined_entity`, `on_gui_opened`...) and Factorio's own reach and placement rules apply. The bridge's own character (no player) always acts by script |

## Troubleshooting

- **"Waiting for Factorio on 127.0.0.1:34200"**: Factorio isn't running with
  `--enable-lua-udp 34200`, or the mod isn't enabled. Check `server/data/factorio-current.log`
  for `factorio-3d-bridge` and for "UDP is unavailable".
- **"Can't open UDP port 34201"**: the client tries 34202 to 34208 by itself, so all nine are
  taken: close other clients (or the mock server's test).
- **"Incompatible Factorio version"**: the mod is marked for 2.1. A 2.0 game won't load it;
  change `factorio_version` in `info.json` to "2.0" to try (untested).
- **Server exits with "Can't bind socket: Error code 10013"** (Windows): another program has
  one of the ports. `Get-NetTCPConnection -LocalPort 34198` / `Get-NetUDPEndpoint` shows who.
- **Stutter while the world loads**: lower "Chunk snapshots per tick", or the client's "View
  distance" and "Entity distance" (Settings → Graphics).
- **The game runs slowly with the client connected on a big base**: what the client asks for
  (every item on belts near you, far belt lanes, moving things within the entity distance, new
  chunks, the minimap's charts) is worked out in the game's tick. Settings → Graphics → Hold the
  game at 60 UPS (on by default) steps in while the game runs under 57 UPS, one step every few
  seconds: first the bridge sends its costliest updates less often and the minimap refreshes less
  (`rate` 1 to 3: the world may glide further, the game keeps its speed), then the entity, belt
  and view distances go below your settings (floors 64 tiles, 8, 32, 5 chunks), then a 45 FPS cap; it gives a step back after 30 s at 60. It also keeps
  the bridge's work budget to the room the game has, so a big request doesn't make a slow tick.
  Your settings stay as they are; the F4 line says what it holds back. Otherwise `/f3d-profile`, then `/f3d-status`, shows which module costs most: lower "Belt
  item, ground item and inserter radius", or the client's "Moving belt items", "Belt item distance"
  and "Entity distance". `python tools/ups_probe.py --port <rcon> --seconds 30 --profile`
  measures the server's UPS and the bridge's cost; `-- --ups-probe=out.json[@walk]` lowers each
  of the client's knobs in turn and prints the UPS each buys (`@governed=<s>` logs the governor).
- **No icons, flat-coloured ground, no sound**: the client didn't find your Factorio install.
  Set it in Settings → Factorio install, or pass `--factorio-data=<Factorio>/data`.
- **Hybrid single-player doesn't connect**: check that Factorio was started with
  `--enable-lua-udp 34200`, that a game is loaded (the port opens then), and that the bridge mod
  is enabled in Factorio's own mods folder; `/f3d-selftest` in Factorio's console checks the
  rest. Hybrid mode has only been played once, so a server (Single player → New game or Load
  game) is the safer choice.
- **Low frame rate on a busy base or in a forest**: Settings → Graphics → Preset sets shadows,
  level of detail, the distances and clouds together (High is the defaults; Low also halves the
  shadow detail and the distances). Ambient occlusion is off in every preset: turned on (Graphics →
  Ambient occlusion, WIP) it costs about 6-7 ms of GPU a frame at a busy base. After that most of the
  GPU's time in a dense view goes to belts near the camera, trees' leaves and shadows.
- **Crashes, a hang on quitting or flickering with Render on a separate thread**: that mode
  (Godot's own, experimental, off by default) measured no faster here and can hang on quitting.
  Untick Settings → Graphics → Render on a separate thread and restart (it is written to
  `user://engine.cfg`), or start once with `--render-thread safe` before the `--`.

### The debug menu (Ctrl+F12)

In a game, **Ctrl+F12** (Settings → Controls → Miscellaneous → Debug menu) opens Zenith's debug
menu (client/scripts/ui/factorio/debug_menu.gd). Only dev builds have it (`Settings.dev_tools()`,
"Build channels" under The download): a public download has no key for it, in Settings → Controls or anywhere,
and it never opens, so neither do its overlays and probes. Esc stops a running benchmark, then closes the report, then the menu. It opens over an add-on's
camera (the Cinematic camera's F8) and over a hidden interface (F11) too: it has its own layer,
which the add-on host leaves shown, the mouse shows while it is open (and is captured or hidden again
as the add-on had it when it closes), and add-ons' camera keys rest meanwhile, so typing in its boxes
doesn't fly the camera; their other keys (F8, F11) still work.

- **Time**: the time of day (slider; Dawn, Noon, Sunset, Night), freezing the day/night cycle, the
  game's speed (0.25x to 4x or a number, held to 0.05-16x) and pausing. These change the real game
  through the bridge's `/f3d-debug` (console.lua; `surface.daytime`, `freeze_daytime`,
  `game.speed`, `game.tick_paused` on the character's surface). They follow the console's rule: in
  a multiplayer game only an admin (or a Zenith on the server's own machine) may, and otherwise the
  controls are greyed with the reason. A bridge older than the client says so too. The slider reads
  as a clock, midnight at both ends and noon in the middle (Factorio's own daytime counts from noon:
  0 noon, 0.5 midnight). A paused game runs no mod code, so the bridge neither reads nor sends
  until it resumes (real 2.1.24): Pause is offered only where Zenith can resume, over RCON (a
  server its menu started), as a screenshot's pause does (`client/scripts/net/game_pause.gd`); it
  pauses through `/f3d-debug pause on`, holds the connection's timeout off, greys the other
  controls meanwhile, and Resume runs `/sc game.tick_paused = false` over RCON. In single-player
  (hybrid) and on a server started elsewhere Pause is greyed with that reason: pause in Factorio
  itself (Ctrl+F9). Answers are read as their datagram arrives, ahead of the messages waiting
  their turn, and one that comes late is still taken; when none comes in 5 s the menu says what
  the link shows (not connected, nothing sent for a while: paused or stalled, or sending but not
  answering: an older mod or one far behind sending the world).
- **Benchmarks** (client/scripts/debug/bench_runner.gd), run in the game being played: standing
  still 30 s (the stutter probe's `stand`), two laps at the character's speed (its `fast`, the laps
  of `tools/bench/compare_builds.py`), a 30 s camera flyover 100 tiles round the character, and a
  zoom out to the furthest zoom and back. Each ends in a report window: frame time p50, p99 and
  worst, frames over 16.7 and 33 ms, FPS, GPU and render CPU time, scripts, draw calls, triangles,
  the game's UPS, the bridge's time per tick by module, and what ran (version, graphics preset,
  look, resolution and the settings that weigh most), each against the last run of the same
  benchmark. Copy puts it on the clipboard, Save to file writes it as text and JSON to
  `user://benchmarks/`. The bridge's cost needs RCON (its profiler prints only in Factorio): with a
  server the menu started it turns `/f3d-profile` on for the run and reads `/f3d-status`; in
  single-player the report says so. GPU times aren't measured with Render on a separate thread.
- **Tests**: the bridge's `/f3d-selftest` and `/f3d-status`; overlays (the UPS overlay, a
  frame-time graph, counters of draw calls, triangles, nodes, chunks, movers, belt items and 3D
  grass, chunk borders); the probes below run in the game without quitting (terrain streaming,
  robots in view, belt items' cost, flicker frames into `user://debug/flicker`); the effects demo;
  redrawing the loaded chunks; and moving the character to its spawn, the map's centre, 500 tiles
  east or back (`/f3d-debug teleport`, the same rule as Time).

### The performance test (main menu)

The main menu's **Performance test** (or `-- --perf-test[=quick|default|extensive]`; with a mode
it runs at once and quits at the end, exit code 0, 2 when a test gave no numbers, 1 when it
stopped) is the testers' benchmark, the same on every PC (docs/PERFORMANCE-TEST.md is
its guide). Dev builds only: a public download has no button, and `--perf-test` prints that it is
for dev builds and quits with exit code 3. client/scripts/menu/perf_test.gd picks the tests (Quick: the Factorio look at High,
standing and laps; Default adds the Cinematic look; Extensive adds Low and Ultra and runs Default
twice) and writes the results; perf_game.gd does the rest from inside Zenith, no scripts:

- a new map in `user://perf-tests/work/factorio` (the server's own write-data folder, its mods
  folder holding only the bridge): seed 123456 from Factorio's example settings, peaceful, no enemy
  bases, no pollution, evolution or expansion (server_launcher.gd's `data_dir`, `player_mods`
  false, `port_base` 35700, its own server settings: no autosave, no pause);
- the test base built over RCON, the earlier script's Lua unchanged (2,603 buildings: 12 belt loops and an 8-loop bus full of items, 36 assemblers, a roboport with 50 robots,
  north-west of the character), noon frozen, exoskeleton running speed;
- each test in a fresh Zenith started as a child process with APPDATA (XDG folders, HOME) pointed
  at `user://perf-tests/work/appdata`, so its user folder, settings.cfg (the preset, borderless
  full screen, vsync off, no FPS cap, Hold 60 UPS off, sound off, the Cinematic shaders add-on for
  the Cinematic look), logs and add-ons are its own: `--stutter-probe=<file>@stand|fast` and
  `--probe-trace`, its walk summary and the bridge's f3dtrace lines read back as the earlier
  script did;
- `user://perf-tests/Zenith-perf-<version>-<mode>.txt`: the PC from Godot's own calls (processor
  name and thread count, memory, adapter, vendor and driver, rendering driver and method, the
  primary screen's size and refresh rate, the system), Factorio's version and Space Age, how it
  ran, a table per test and a CSV block. The menu shows each test's report in the debug menu's
  report window, against the last run of the mode (`user://perf-tests/last.json`).

While it runs the menu's own window drops to 10 FPS with nothing 3D behind it. Esc or Cancel stops
it, and closing Zenith stops the test's Zenith and the server before quitting.

### Measuring the client

`-- --stutter-probe=<out.json>[@route]` (client/scripts/debug/stutter_probe.gd) records every
frame's time and what ran in it, then quits: `@busy` walks through the mock's `--busy` base,
`@fast` runs two laps of a loop round where the character joined (on the owner's save its
exoskeletons make that 30-40 tiles a second), `@stand` stays put, `@variants` with `--probe-variants` (or `--probe-variants=ssao off,trees
hidden`) prices render settings and hides models one kind at a time and lists the models in view.
Variants combine with `+`; `fit [quality] atlas=4096 splits=1 ...` tries sun_shadows.gd's fitting
with other settings, `legacy render` the shadows and levels of detail from before it, `lod
threshold 4`, `shadow distance 60`, `arms|items|wires|movers|terrain no shadow` and others (see
`_set_variant`). `--probe-ab=3` measures each variant three times between two "base" steps, which
cancels the graphics card's drift (compare each with the bases beside it), `--probe-timing=2,4`
sets the seconds to settle and to measure, `--probe-stay` leaves the client running after the summary
(a harness that takes screenshots after the route ends it), `--probe-warmup=30` waits longer and until no chunk is
left to build, `--probe-shots=<dir>` saves a screenshot of each step. Each step's medians (frame,
GPU, render CPU, draw calls and triangles of the view and of the shadow passes, casting chunks)
are printed and kept in the JSON's `variants`. `--legacy-render` starts with the shadows and levels
of detail from before sun_shadows.gd, for a whole run.
`@join` measures the join itself: it stands 90 s from the world being ready (pass `--probe-warmup=0`
so the first load's frames are in), notes when the view was fully drawn (the `JOIN` line: chunks,
terrain and models settled, the belts' first load done) and with `--probe-stay` keeps the client
running after writing the file, so `tools/belt_view_check.py --client-arg=--stutter-probe=<out>@join
--client-arg=--probe-warmup=0 --client-arg=--probe-stay` scores the same run. `python
tools/join_hitches.py out.json [--windows] [--md]` then gives frame-time percentiles, the frames over 25
and 50 ms and what each hitch was spent on (the biggest script subtree, world.gd's part of it, the
renderer's draw with the pipelines it compiled, or the wait for the GPU). belt_view_check's
`--godot-arg=--gpu-profile` passes Godot its own flag so the probe also gets the render steps' times.
With the separate render thread the renderer's own times are only read with
`--probe-render-times` (each read waits for that thread). `--belt-items-sync` handles belt items on
the main thread instead of a worker, for comparing. `--no-belt-stand-ins` draws every belt whole
(belts drawn under 20 pixels a tile are otherwise light stand-ins, belt_lods.gd), for comparing.
`--far-merge-from=<tiles>` merges far chunks' buildings from that distance instead of about four
chunks (far_chunks.gd), for screenshots of merged buildings up close.
Each frame also records the sliced systems' books (`fb`: each one's µs used, granted and work
waiting, frame_budget.gd), the chunks wanted round the focus but not drawn yet (`q_undrawn`, and
`q_near_undrawn` within two chunks), and at the end the time from a chunk being wanted to its
buildings being drawn. `python tools/moving_summary.py run.json ... --systems` summarises runs: the
whole frame, the main thread's own work (the frame less the draw's wait for the GPU) and the GPU,
p50 / p99 / worst, the speed walked, the sliced work and chunk latency, and per system how often it
used its whole slice.

The main thread's sliced work (messages, chunk builds, terrain, models, unloading, shadows, the
pick index, clutter, far belt icons, wires, far merging) shares one allowance a frame
(frame_budget.gd): what is left under 16.7 ms (or the FPS cap) after the frame's other work, 3-6 ms,
handed out by priority, with a floor for the near work. `-- --frame-budget=separate` gives every
system its own slice as before, for comparing.
The probe's frames also record chunk streaming's queues: `q_unasked` (chunks wanted round the
focus but not asked for yet), `q_partial` (builds stopped part-way), `q_shadow` (chunks whose
shadow settings are still to be set) and `q_free`, `q_free_records` (unloaded chunks still to go).

Hitches while joining (the first 90 s), each behind a switch defaulting to what measured better:
- `--lods-finish-usec=N` (2000): models' levels of detail finished on worker threads are shown
  (the stand-in's surface made, the model's levels made as meshes of their own) for at most N µs a
  frame, at least one a frame; 0 shows every finished one at once, as before (a second-long frame
  on the owner's save, several big models at once, while other processes loaded the PC; on a quiet
  PC no frame's finishes took over 5 ms either way, and the joins with 2000 were as good or better).
- `--belt-capture-thread=on`: `--belt-capture` writes each `bs` message on a thread of its own, which
  takes JSON.stringify of a first load's 28 KB updates (2-3 ms each, 5.5 s over a join) off the main
  thread; off (the default) writes them inline. On this 4-core PC the thread made the join worse:
  50-59 frames over 33 ms, the worst belt job 1.3-2.2 s and the first load done at 69-89 s, against
  30-37, 0.77-0.88 s and 53-57 s inline (joins at -62,-26: three with the thread, two inline, and a
  third inline one with --gpu-profile agrees).
- belt_view_check's `--godot-arg=--gpu-profile` is for the render steps' times, not for counting
  hitches: Godot prints its GPU profile every second and those frames stall 400-750 ms (84 in a
  110 s join at -62,-26, shown as `present`).
- The simulation's event queue (lane reads, checks, holds queued for later ticks) is kept by tick
  (belt_sim.gd and BeltSimNative `_apply_queue`): only the due ticks are taken, where every queued
  event used to be scanned and moved each tick. Same order as before (by seq), so no switch:
  belt_sim_native_test shows 0 differences. The probe's `sim_queue_usec` counts applying the queued
  reads as well, which is most of it: 25.3 s over a 90 s join at -62,-26 before, 23.2-23.8 s after.
- `--screenshot` frames are marked in the probe's frames (`shot`): the read-back and PNG encode stall
  that frame about half a second, so `join_hitches.py` leaves them out (`--keep-shots` keeps them).

Items on belts are run by the client's own copy of Factorio's belt rules (client/scripts/world/belt_sim.gd,
docs/BELT-SIM-PLAN.md; the bridge sends `bs`). A bridge mod from before `bs` (0.1.4 or older, say a copy
left in Factorio's own mods folder for hybrid games, or another player's server) still sends `bi`, which this
client no longer draws: the belts near you stand empty, and the client says so once in its message line
("The bridge mod ... is older than this Zenith"); update the mod. Its replay test checks it against a recording of the game
(`python tools/belt_sim/record.py`): `godot --headless --path client -s res://tests/belt_sim_replay.gd --
[rec.json] [--bench] [--tile=N]` starts from the recording's first tick, steps on by itself given only what
the game put on and took off, and counts the items that aren't where the game has them (the default
fixture must have none); `tools/belt_sim/sim.py rec.json --mode free` is the reference it agrees with.
`-s res://tests/belt_sim_bench.gd -- --items=80000` times it on a synthetic world.

How the simulation's items are drawn has toggles, all on by default, so the drawing as it was can be
compared (the client reads them at start-up, `-- --belt-sim-ahead=0` and so on; `tests/belt_bs_replay.gd`
takes the same):
- `--belt-sim-ahead=N` (24; was 1 before `--belt-draw-early`): the simulation runs N ticks past the drawn tick, what it says happens after
  that tick waiting for the next job. 0: stepped to the drawn tick, so items a read moved or put on a lane
  on that tick are drawn from their old records until the next job.
- `--belt-draw-gone-order=off`: a job applies every change, then removes every item gone in its ticks (an
  item dropped and put back in one job stays undrawn till its next change); on, both in the
  simulation's order (`take_changes()`'s `gone_tick`, `gone_at`).
- `--belt-draw-lead=off`: a record that ends is made again only once it has ended (the item stands at
  its end till the next job), and an item past its lane's back end is hidden until its record ends; on,
  made again a little before, by a path across where it ends that shows it exactly where it comes onto
  a lane or out of the ground.
- `--belt-draw-head-move=off`: the simulation's changes say the step a head item was given (items
  waiting at a splitter or side-load were drawn moving on) and items leaving a line aren't emitted. Both
  belt_sim.gd and BeltSimNative honour it (`head_move`); the rules don't change.
- `--belt-sim-read-apply=off`: reads applied as before this round. On (the default): a lane's meta
  (`lm`) takes effect at the tick of its first read in the update (`set_lane_at`), not when the message
  comes, so the line behind a lane loaded in that update doesn't run on into it, empty, until its read;
  a read never leaves an item past its line's back end:
  what its packed run, the items it pushes back out of its lane and those it spaces out leave there is
  carried back onto the feeder's line (a splitter output's: the input on that side with more room, the
  side's turns put back), its items behind going back a gap as needed, up to 8 lines (`_carry_back`;
  where it can't, they go); and a read of a splitter's output with an item the simulation sent into the
  side's other output (or on along it) sets that side's output turn too. Both belt_sim.gd and
  BeltSimNative honour it (`read_bound`).
- `--belt-sim-read-conserve=off`: reads drop what they don't have as before. On (the default): a read
  takes off only the items its lane had between the read's own (taken); those behind the read's items
  in the line's order (all, when none of them is in the line) go out of the lane behind it, those ahead
  out of it in front, in order (`_rescue`); what that leaves past a back end is carried back up to 32
  lines, never onto a splitter input nothing feeds. Both alike (`read_conserve`).
- `--belt-sim-read-forward=off`: the items a read leaves past its line's front (the read lane is the line's
  first: a splitter's input, a lane whose next is another line, and the read hasn't them) go, as before. On
  (the default): they are carried on into the line they went on into in the game: across a splitter into
  the output its turn (or priority, or filter) says where there is room, else the other, the side's turns
  moving on as for a crossing; into a plain next lane behind its hindmost item (`_carry_forward`). Where
  the lane leads out of what is sent, or nothing has room, they go, as before. Against the every-tick
  recording at -62,-26 such drops were 47% of the items reads took off that the game still had (an `sh`
  hold keeps a splitter input's items while the game crosses them; the read then finds them ahead of its
  own), and a hole in a packed bus stays until the lane is read again. Replayed on that capture (every tick,
  by place within 0.15 tile on recorded lanes): 88.6% -> 91.3%, phantoms 3.3% -> 3.2%, items lost while the
  game still had them 4,042 -> 2,913 in 600 ticks. Both alike (`read_forward`).
- `--belt-sim-shift-keep=off`: a read's packed-run shift goes on past an item outside the lane that the
  shift would bring into it where the read hasn't it, and that item goes, as before. On (the default): the
  run's shift ends at that item, which stays where the simulation had it (`_shift_packed`): against the
  every-tick recording at -62,-26, 81% of such items were still on the belts, ahead of or behind the lane
  (814 of the 4,042 items reads took off in 600 ticks that the game still had). Replayed with read_forward:
  91.3% -> 92.3% by place, but phantoms 3.2% -> 3.9% (kept items the game has elsewhere). Both alike
  (`shift_keep`).
- `--belt-sim-read-skip-same=off`: a read (`sl`) that finds the lane exactly as the simulation has it (every
  item at its place, none else) is applied all the same, as before: the line rebuilt and every item's record
  written again. On (the default): it is skipped, its items only noted fresh for the tick (`read_skip_same`,
  both twins alike). Offline on the lattice run's capture at -62,-26, 51% of the bridge's reads were such, and
  applying reads was 80% of the simulation's time (2.7 of 3.4 ms a tick; stepping 0.7).
- `--belt-sim-hold=off`: the bridge's `sh` ignored. On (the default): a splitter's input the bridge found as
  its last read left it is put back so and held (its items don't cross into the outputs) until its next
  read (`hold_input`). Both alike (`hold_inputs`).
- `--belt-sim-split-wake=off`: splitters let an item through whenever the belt rules say. On (the default):
  a splitter side that let an item through one or two ticks ago (three, while its other output moves) takes
  its turn before the belts that start moving this tick, as the game's update order does: an output that
  stood last tick and has room only once its items moved on this tick takes nothing from it that tick
  (docs/BELT-RULES.md section 6). Both alike (`split_wake`).
- `--belt-early-bs=off`: `bs` parts that come before the world is ready (the bridge's welcome done, the
  prototypes known) are dropped, as before. On (the default): they are held (up to 4,096) and handed to the
  belt layer in order once it is. The bridge loads lanes from the hello on and sends each lane's meta (`lm`)
  once, when it loads it: a dropped part's lanes were read and checked from then on but never placed (two
  of five captures at -62,-26: a turbo underground and curve beside the character empty for the whole run).
- `--belt-sim-ask-unknown=off`: a lane read (`sl`) or checked (`pc`) whose meta never came is left out, as
  before. On (the default): it is asked for again (`bre`, at most every 3 s), which the bridge answers with
  its meta, as docs/PROTOCOL.md's `bre` says. Covers updates lost on the way too (UDP): a capture at
  -272,-14 lost three updates during the first load and with them 187 lanes' meta.
- `--belt-draw-coalesce=off`: every change the simulation emitted in a job's ticks is made into a record,
  one after another, as before. On (the default): only an item's last change at or before the drawn tick
  is; the earlier ones would be overwritten before anything is drawn. Live at -62,-26 a job that had
  fallen 258 ticks behind applied 806,000 changes for 65,000 items (twelve an item) in 8.6 of its 11.4 s.
- `--belt-draw-view=off`: every item gets a record wherever it is, as before. On (the default): an item
  whose motion can't show on screen (its record would lie 4 tiles and its reach outside the camera's
  ground view: the four corner rays met with the items' height, cut 160 tiles out) is parked, its motion
  kept but no slot and no record, until a change or the camera brings it in (the view the records were
  planned for is kept 10 tiles wider than the camera's, so panning a little doesn't plan every parked
  item again). At -62,-26 the camera sees about a tenth of the 160-tile square the client simulates.
- `--belt-draw-margin=N` (120): the most ticks the drawn clock is held behind the game's clock for the
  jobs (the margin grows to 1.5 jobs' ticks, from 2). 30 as before: a job longer than 20 ticks (-62,-26's
  take about a second) then ended past the drawn clock and its records were drawn stale, items standing at
  their ends while the game's went on. 120: at most two seconds behind, the records fresh when drawn.
- `--belt-job-high=off`: belt items' job goes to Godot's worker pool as a low-priority task, as before.
  On (the default): a high-priority one. Low-priority tasks get a share of the pool's threads (0.3 of
  them: one on a 4-thread PC), and the belt job queued there behind models' levels of detail,
  decoratives, terrain and far chunks; after main's heavier levels of detail and decoratives came in, a
  job's result came about twice its own time late, each job stepped 80-110 ticks and the drawn clock sat
  at the 120-tick margin. Live, Hold 60 UPS, `--record 60`, by day: -62,-26 off a job cycle of 1.6-1.95 s
  (33-46 jobs a run, margin 120), on 0.33-0.41 s (167-211 jobs, margin 39-56), visible 95.7-95.8% /
  95.8-95.9% and phantoms 2.7% / 2.6-2.7% either way; -272,-14 off 1.6 s (40 jobs), on 0.16 s (383 jobs,
  margin 20), PASS both ways (97.5%, 0.9 / 0.8%).
- `--belt-draw-dump=<file>`: what each job writes for the GPU, as written: a JSON line per job (its
  cost by part, ticks stepped, the updates it took, changes, records, whether it skipped), then the
  records of the items it wrote (uid, item, count, lane, pos, t0, v, reach as int64; the 16 floats of
  each record as the GPU gets them), the uids gone and the paths' texture when it was made again; the
  main thread writes `<file>.apply.jsonl` with when each job's result was drawn, where the drawn clock
  was then and how late. tools/belt_view_check.py scores it against the game (below). It costs about
  0.1 ms a job plus the write of the items' records (a few ms for an update's job).
- `--belt-draw-native=off`: a job's records are planned and written in GDScript, as before. On (the
  default, when the extension is loaded and the simulation is BeltSimNative): `BeltDrawNative`
  (`client/native/belt_sim/src/belt_draw_native.cpp`) does it, from the simulation's changes to the
  records' pages, item for item as belt_items.gd's Job does, down to the float32 roundings
  (`python tools/belt_draw_diff.py gd.bin native.bin` compares two dumps of the same capture, from
  `tests/belt_bs_replay.gd --belt-draw-dump=<file>` with the switch off and on: 0 differences; add
  `--cap=N` for an Items in 3D cap of N, and `--cam=x,z` for a drifting camera leading it, so both paths'
  camera-led caps are compared too). Live at
  -62,-26 a job took about a second in GDScript, 80% of it planning and writing 60-100k records.
- `--belt-draw-pile=off`: each copy of a pile (a stack on a belt, up to four in one place) gets a full
  record of its own, written again whenever its item moves, as before. On (the default): a pile is one
  record, the item's; each copy's record points at it (texel 3: slots to the item, its step k, the kind's
  pile step) and holds the copy's own turn (texel 2), written once when the copy gets its slot, and the
  shader (belt_path.gdshaderinc) lifts the copy by k. At -62,-26 86% of the items are stacks of four.
  Both paths (GDScript and native) take the switch.
- `--belt-draw-lattice=off`: every lane drawn from the simulation, as before. On (the default): a lane
  the bridge's last read (`sl`) found full of one kind, while its drift checks (`pc`) since say it is still
  full, is drawn as a lattice (`client/scripts/world/belt_lattice.gd`): its item every 0.25 tile, each slot
  cycling within its own gap of the lane at the speed of the simulation's front item on the lane (the
  record's texel 3 holds the period and the shader takes the drawn clock modulo it; a new speed must hold
  two checks in a row), and the simulation's own items on it are hidden by a mask of those lanes' centre
  lines (`f3d_belt_mask`, 4 cells a tile); they stay simulated, and show again as they leave the lane.
  Items sit 0.25 tile apart, so a full lane drawn at any phase has each game item within 0.125 tile of a
  drawn one: the owner's concession, a lane the game has packed is drawn packed. A straight lane's phase
  is the map's (a function of its exit's place and the tick, so a run's lanes agree); curves and splitters
  take the simulation's front item's. `--belt-draw-lattice=sim`: every lane the simulation's phase (the
  first build). The lattice is made in GDScript after either records path, with its own records
  (`f3d_belt_lattice`) and MultiMeshes, so both paths draw it alike (`tools/belt_draw_diff.py`: 0
  differences). (Full: as many items as whole gaps fit in the lane, every gap at most 66/256; lanes under
  the ground, loaders, linked belts and lanes longer than 4 tiles keep the simulation's items.) Live at
  -62,-26 (Hold 60 UPS, `--record 60`, by day): off 87.6% visible, 4.2% phantoms; `sim` 94.5 / 91.9%,
  3.5 / 3.6%; on 95.7 / 95.2%, 2.4 / 2.5% (inside the screenshots' bounds 97.7 / 97.1%). At -272,-14:
  97.0 / 97.1%, 1.3% (PASS). docs/BELT-SIM-PLAN.md, the lattice section.
- `--belt-draw-lattice-pile=off`: every lattice slot one item, whatever the lane's stacks (the lattice's
  first build: a bus of stacks of four drawn flat, owner: "nothing shows as stacked items any more"). On
  (the default): a lattice lane's slots are piles as high as the stacks its last read (`sl`) found most
  often, each slot its record and a copy per step above it pointing at the slot's record as the items'
  piles do (texel 3: the slot from the copy, its step k, the kind's pile step; texel 2 its own turn,
  PILE_TURN more each from the slot's yaw, cards and blocks too). The shader reads the slot's texel 3 for a
  copy, so copies slide with their slot and aren't hidden by the lattice's mask.
- `--belt-draw-lattice-unison=off`: the lattice as first built: a slice of the drawn lanes has its speed
  checked against the simulation's each job, and a lane takes a new speed only at two checks in a row.
  So when a backed-up run started moving its lanes changed speed jobs apart, and at each lane boundary the
  sliding lane's slots opened and closed a gap of up to 0.25 tile against the standing neighbour (the
  owner's "shimmer of small gaps"), while at the run's ends the simulation's own items moved away from the
  standing lattice for two jobs. On (the default): every drawn lane is checked every job and a new speed
  is taken at once, so a run's lanes change in the same job as the simulation's records; the map's phase
  keeps their lattices in step. `tools/belt_unison_check.py` measures it (an every-tick recording and the
  client's `--belt-draw-dump`): the largest deviation of the drawn spacing from 0.25 tile on lanes the game
  has full, and the share of such lane-ticks showing a gap, overall, in the 30 ticks after a full lane
  starts moving, and on full lanes moving (a loop).
- `--belt-draw-early=off`: as before, every change the simulation emits for a tick after the drawn tick
  waits for the next job (its record would show the item at its new place before its time). On (the
  default): a change the records can take without showing anything early is taken now: a start of an item
  whose record stands where the change starts from (a record standing there till t0, then moving, is just
  what the item does), or a continuation of a moving item's record (it reaches the change's lane and place
  at the change's tick at the same speed: a line's end, a closed loop's cut, where the simulation's lines
  hand an item on): the record is made again from where the item is now, across the end, through the
  lanes ahead. Held, such an item was drawn standing at the cut until the next job's result was drawn:
  at -62,-26 a job is about 26 ticks, so on a full closed loop items bunched at the cut and jumped 0.8
  tile, and a run starting between jobs stood and then jumped. With it the simulation is stepped
  `--belt-sim-ahead` 24 ticks past the drawn tick (was 1; never past the newest update), so such changes
  are known in time. Both paths (GDScript and native) take the switch. Live at -62,-26 (Hold 60 UPS,
  `--record 60`, by day): 96.2% visible, 1.9-2.0% phantoms with ahead 64 or 24 (the lattice alone: 95.2-95.7%,
  2.4-2.5%); lattice lanes of a run drawn sliding against a standing neighbour 1.0% of adjacent pairs a job
  (11.8-12.2% before). A job cost 505 ms with ahead 64 (the simulation stepping ahead and 122k held changes
  re-scanned a job) and 426 ms with 24, against about 300 before.
- `--belt-draw-lattice-native=off`: the lattice made in GDScript (`belt_lattice.gd`), as before. On (the
  default when the C++ library is loaded and the simulation is `BeltSimNative`): `BeltLatticeNative`
  (`client/native/belt_sim/src/belt_lattice_native.cpp`), belt_lattice.gd function for function, writes the
  same records (`tools/belt_draw_diff.py`: 0 differences between the two on a capture; the dump's `lat_native`
  says which ran). At -62,-26 the GDScript lattice cost 25-70 ms a job (half a second when the view moved and
  every lane was planned again, so walking paid it every few steps); the C++ one 1-3 ms.
`godot --headless --path client -s res://tests/belt_bs_replay.gd -- --stream=bs.jsonl --truth=rec.json
--drawn-check --every-tick [toggles]` replays a capture (`--belt-capture=bs.jsonl`) with a job a tick as
the client runs them and says, every recorded tick, how far each simulated item is drawn from where the
simulation has it, by cause (`--drawn-explain=N` examples, `--trace=UID` one item). Experiments: `--oracle-at=TICK` reads every recorded lane
at the first recorded tick at or after TICK (the simulation starts from the game's state there),
`--reads-after=none` then applies no lane reads (the simulation alone), `--persist` says per update
how many of the items the game had then are still exact, within 0.15 tile, on another lane or missing
(with belt_sim.gd, only lanes whose items go on into recorded lanes alone); `--read-probe` (belt_sim.gd)
compares each read with the simulation just before it, by distance and lane kind, and says what reads
took off and whether the game still had it on the next recorded tick. `--replay-bre` answers the job's
own `bre` from the recording two updates on, as the replay always did before; off by default, since a
live capture already holds the bridge's answers to the live client's asks (answering again read lanes
the live client never got: -62,-26 replayed 91.9% visible with it, 87.5% without). `--hold-emu` makes the bridge's `sh` from the recording (a
recorded splitter input whose items at an update are its last read's), `--confirm-emu=split|all` reads such
lanes again (splitters' lanes, or all) as their last read had them at every update: what those would do.

To measure where the client draws items against a running server: `python tools/belt_path_check.py
layout --rcon-port <port>` builds a test row per belt tier (both curves, a splitter, an underground,
side-loading, packed rows), `record --out truth.json` records every item's place each tick, and
`check truth.json drawn.json [--within x0,y0,x1,y1]` compares where the client drew them with
`-- --belt-path-probe=drawn.json@20` (records 20 s after 10 s, prints belt items' main-thread and worker
time, then quits): by unique id, and by place (each drawn item's distance from the nearest game item
at that tick, p50 and p99, the share drawn with no game item within 0.15 tile, and the share of the
game's items with none drawn within 0.15).

Whether a build's belts look right over the whole view, in one command: `python tools/belt_view_check.py
--worktree <checkout> --ports <udp>,<game>,<rcon> [--at x,y] [--size 64] [--seconds 10] [--settle 40]
[--settle-max 180] [--first-bs 60] [--settings automatic|unlimited] [--hold60 on|off] [--record
updates|tick] [--camera top|free|<yaw,pitch,dist[,ortho]>] [--stand-in] [--reuse-server] [--shots <dir>]
[--json <out>] [--lock <file>] [--keep <dir>] [--replay every-tick|update] [--replay-arg=<arg>] [--tail-wait 30]
[--record-bounds view|square] [--draw-dump on|off] [--client-arg=<arg>] [--client-setting=<key>=<value>]`. It starts that checkout's server on a copy of its `server/saves/zt.zip`
(the mod copied into its server folder first), puts the character at `--at`, runs its windowed client
with `--belt-capture`, a settings file of its own (Hold the game at 60 UPS on, the owner's default;
`--hold60 off` is a diagnostic; `--client-setting` adds a line to its [graphics], as the settings file writes it,
such as `grass_3d="off"`, for a diagnostic) and the camera pinned (`--camera top`: the client's
`--camera=0,85,<size/0.65>,ortho`, straight down, north up, `--size` tiles high, so a branch's and
main's screenshots frame the same ground; `free` leaves the client's own). It counts the client as
joined at the capture's first `bs` line (FAIL after `--first-bs` seconds with none), waits until the
capture's last update has no `ld` (the first load is done) and at least `--settle` seconds have gone
(FAIL "first load didn't finish" after `--settle-max`; the capture is read as the client's file buffer
writes it), records the game's belts over a `--size` square round the character
(`tools/belt_sim/record.py --sample updates`: only the ticks the bridge sends an update on, all the
replay compares; `--record tick` reads every lane every tick as before, which loads the server enough
that Hold 60 UPS slows the bridge's updates), saves the client's view every 10 s, waits (up to `--tail-wait` s) for the capture to reach the
recording's last tick (the client's capture can trail the game by seconds; a capture that still ends
first is compared only as far as its updates go, and the report's head says so), stops everything and
replays the capture through that build's belt_items.gd (`tests/belt_bs_replay.gd --view-dump
--drawn-check --every-tick`: a job a tick with the drawn clock behind the updates, as the client runs
them; `--replay update` runs a job an update at its tick as before, which puts items the records draw
on another lane than the simulation's that the client never shows, so the drawn kinds aren't gated
then; `--replay-arg` passes the drawing's toggles on). The game's belts are recorded over the screenshots'
whole ground (`--record-bounds view`, the default: the pinned camera's bounds, 107 x 60 tiles at --size
60; `square` records the --size square only, as before), and the client runs with `--belt-draw-dump`
(`--draw-dump off` leaves it out): the report's section L scores what the client itself drew, the
records in effect when its drawn clock showed each recorded tick, placed as the shader places them,
against the game's items in those bounds (visible by place, one to one by item name within 0.15 tile;
phantoms; by id; by id on packed lanes, reported only: a packed lane of one kind looks the same whichever
of its items is where, the owner's concession "a lane the game has packed is drawn packed";
`--gate-by-id on` makes it a gate again, under 90% failing), with the client's own pace (jobs with updates and their ms, updates
merged into one job, results drawn late, how far the drawn clock was behind the newest update). PASS
needs live visible >= 97%, live phantoms <= 2% and coverage >= 98% (and packed lanes by id >= 90% with
`--gate-by-id on`); the
replay's score (section 0) is a diagnostic then: replay against game separates the bridge and the
simulation, live against replay the client not keeping up. `--client-arg=<arg>` (repeatable) passes a
switch to the client only (`--client-arg=--belt-draw-coalesce=off` for the client as it was). Reading
every lane on every update tick (`--record updates`) slows the server to 12-30 UPS, which gives the
client several times the wall time a tick it has in play: `--record 60` (every 60th tick, 10 rows) keeps
the game near 60 UPS; the report's head says the game's pace while recording. The report's head gives the run's pace: the updates' `p` (ticks between updates) while
compared and before, when `ld` last showed, the bridge's rate level (/f3d-status) at the recording's
start and end, Hold 60 UPS (and whether that is the default), the client, whether the server was
started or reused, and how the recorder sampled (with `--analyze`, from status.txt, settings.cfg and
run.json beside the stream, or `--status`, `--settings-file`) and how the replay ran. The headline
(0.) is what the owner sees: every game item in the square on a lane that shows (not an underground's
hidden lines 3-4) matched one to one with a simulated item of the same item name on the same lane
within 0.15 tile, at every compared update ("visible"); the simulated items on those lanes with no game
item matched ("phantoms"); "holes", runs of two or more game items in a row along a lane with no match;
the misses with some other simulated item there (another kind, or one already taken); kept on the deep
lanes (4 or more back to an unsimulated feeder, or none) over every update; and what the records draw
on another lane than the simulation's. The view dump gives each item's kind (the game's by the
recording's `names`, the simulation's by the `sl` that set it: the bridge's item ids, matched to names
by the items both have, or the recording's for the `bre` answers the replay makes up). Then, as
diagnostics: lanes simulated by ring round the
character; items kept by how many lanes back the nearest unsimulated feeder is, lane by lane (min(sim,
game) per lane summed, so a lane with too many doesn't make up for a hole on another); items by id
(right, off, other lane, missing, extra) at the first, middle and last update; what the records draw
against the simulation (other lane, standing where the simulation moves); and the headline by id, the
share of every game item in the square whose own id is simulated on its lane within 0.15 tile (beside
it the same by place, any simulated item within 0.15 tile, which a packed lane nearly always has, so it
is not a gate, and how many of the last update's by-place hits are another item; by id, an item on
another lane of a balancer looks the same when another of its kind takes its place, so none of the by-id
numbers is a gate). PASS needs visible >= 97%, phantoms <= 2%, the deep lanes keeping >= 98%, 98% of
lanes simulated, and (every tick) at most 0.05% of the item-frames drawn by the records on another lane
than the simulation's; the exit code is 1 on FAIL. Beside the report,
`lane_map.png` (copied to `--shots` too): the recorded lanes from above at the last update, each
coloured right, right and empty, off, on another lane, hole (missing) or not simulated, over the same
ground and at the same size as the pinned camera's screenshots. `--stand-in` runs `tools/belt_bench.py
--bs --capture` instead of Zenith (no Godot, no screenshots: for bridge-only runs; `--stand-in-cap`,
`--stand-in-near` are its `bfar`). `--reuse-server` keeps the server running on its save copy after the
run and uses it again next time (the character teleported to the new spot), restarting it only when the
worktree's mod changed (copied in again); `--stop-server` stops it. `--main <checkout>` runs the same
spot on a checkout without `bs` for screenshots side by side (with `--reuse-server` on the ports + 10);
`--analyze --stream <bs.jsonl> --truth <rec.json>` reports on a capture already made. A run takes the
server's ~4 GB: `--lock` waits for that file to be free (polled every 5 s) and holds it while a run's
server and client are live (a kept server idles without it). `python tools/test_belt_view_check.py`
tests the report, the lane map, the camera's ground, the lock and record.py's `--sample` on made-up
data.

`tools/belt_sim/record.py --sample` picks the ticks it records: `tick` (every tick, the default, which
sim.py and belt_sim_replay need), `updates` (the ticks the bridge's `bi` job ran, read through a
remote interface, `f3d_rec`, it adds to the bridge mod's Lua state for the recording) or `N[@phase]`
(every N'th tick where tick % N == phase, phase 1 by default: the bridge's `bi` ticks at every rate
level with its default interval of 6). Its rows are appended to the script-output file as they are
made; the recording has the same keys as before plus `sample`, `rows` and, with `updates`,
`bridge_ticks`.

Factorio's belt rules, measured in the running game: `python tools/belt_rules.py --rcon-port <port>
all` (or `lengths speed gap line sideload splitter inserter`) builds small rows on a lab surface of its
own (`zenith-belt-rules`) and records their lanes every tick; docs/BELT-RULES.md has the results.

What items on belts cost the bridge, without the windowed client: `python3 tools/belt_bench.py
--udp-port 34200 --teleport -272,-16 --seconds 40 --json out.json` against a running server (on a
copy of a save: it uses `/c`) connects a stand-in client that asks for belt items as Zenith does
(the High distances by default: `--near 160`, `--cap 6000`, `--units` for Smooth belt items),
`--groups` to say `bg` too, `--runs` to say `br` (straight runs moved by the client). It warms up for
`--warmup` seconds (20 by default) and then records the bridge's per-module times, the game's UPS,
the bytes of each message type, how far moving items reached (`bi` fr: mean, min, max) and
belt_items.lua's counts per update (lanes checked, held, read in full, held as groups, plain lanes
not checked and read, far lanes held, far icon chunks skipped, items read). Its docstring has the
usage.

#### The other probes and debug options

The client's other probes (client/scripts/debug/, each file's header has the details). Each runs
after the `--`, writes its file or prints its lines, and quits when done; run them windowed
against the mock or your own server unless said.

- `--robot-probe=<out.json>[@seconds]`: stands still and records what each frame costs with the
  movers in view (frame, movers' script time, draw calls, GPU); with the mock's `--robots N`.
  `--robot-nodes` draws robots a node each, as before robot_swarm.gd, for comparing.
- `--ao-probe=<out.txt>[@seconds]`: after 20 s (or the seconds given) lists every model MultiMesh
  drawn: instances, shadow casting, visibility, triangles, bounds, per surface whether its baked
  occlusion (COLOR) and second UV map reached it and their mean, the material's `vertex_data` and
  `ao_strength`, and the contact rims' feet (`feet=`); also the sun's shadow settings, the environment's
  SSAO and ao_zoom.gd's reading. It doesn't quit, except with `--ao-probe-shots`: then it saves the
  window with each kind of occlusion off in turn (`<out>-all.png`, `-no-ssao`, `-no-contact`,
  `-no-baked`, `-none`, and `-all-again` for what moves between two pictures anyway), each after the
  picture settles, with the GPU's frame time and SSAO's state in `<out>-shots.txt`, and quits.
  `--ao-probe-ab=<bias>,<normal bias>` saves the window before and after setting the
  sun's shadow biases (`<out>-a.png`, `<out>-b.png`), `--ao-probe-bias=` holds them there, and
  `--ao-probe-own-shadows` makes every model cast its own shadow with the stand-ins hidden.
  `--aa-probe-shots` (with `--ao-probe=`) saves the window under each anti-aliasing choice in turn
  (`<out>-aa-off.png`, `-fxaa`, `-smaa`, `-taa`, `-msaa4`, `-off-again`), the setting held unsaved and
  applied as Settings does, with what the window then has in `<out>-aa.txt`, and quits.
- `--settings-probe=<folder>[@seconds]`: after 25 s (or the seconds given) changes every row of the
  Settings window the way a player does (a dropdown's item picked, a box ticked, a slider let go),
  reads back what each should change in the running game and in the settings file, saves a picture
  before and after the visible ones, goes through each add-on's own settings (did the add-on hear,
  how much the picture moved), and writes `<folder>/report.txt` (PASS / FAIL / NOTE). Each setting is
  put back afterwards. `--settings-probe-restart` then writes a set of non-default values for the next
  start, which `--settings-probe-verify` reads back in the game (`<folder>/verify.txt`). Use a user
  folder and `--settings-file=` of the probe's own: it changes the window's size and mode.
- `--settings-scroll-to=<control name>` (with `--menu=settings:<tab>`): that setting scrolled into
  view, for screenshots (`graphics-antialiasing`).
- `--glide-probe=<out.json>[@seconds]`: goes through the bridge's `rate` levels 0 to 3 (30 s each)
  and reports, per kind of mover and for belt items, the speed and how often they stall or jump.
- `--soak-probe=<out.json>[@minutes]`: a long session (30 minutes): walks a square, opens windows,
  builds and mines a wooden chest, and samples memory, objects, frame times, the bridge's gaps and
  resyncs and the server's UPS.
- `--predict-probe=<out.json>[@builds]`: builds a wooden chest beside the character over and over
  and times each click to the game's chest drawn (what scripts/world/predicted.gd hides).
- `--quit-probe=<seconds>`: quits after that long without the exit guard, so a hang on quitting
  stays visible; `python tools/quit_soak.py` starts and quits the client many times with it.
- `--flicker-probe=<folder>[@degrees a frame]`: saves frames while the camera turns slowly;
  `@pan` moves Factorio's view one pixel a frame instead. `python tools/flicker_count.py` (`--pan`)
  counts the pixels that change and change back.
- `--terrain-probe`: every 5 s prints how long chunks waited for their tiles and their ground, and
  how long chunks near the focus were holes.
- `--mod-click-probe=<name>[,<name>...]`: presses mods' buttons in Zenith's copies of their windows
  and logs the windows before and after (no names: lists the buttons); `--mod-click-probe-quit`
  quits after the last.
- With `--stutter-probe`: `--probe-trace=<ticks>` has the bridge log each module's time per tick
  (`f3dtrace` lines in Factorio's log) once the walk starts, asked through the console so
  single-player needs no RCON; `--probe-fine` keeps subtrees over 0.005 ms, not only over 0.1.
- Screenshots of models and animations: `--review-shots=<dir>[@seconds]` (what
  tools/models/review.py starts) with `--review-box=<w>,<d>,<h>`, `--review-aim=<height>`,
  `--review-views=<a,b,...>` and `--review-fly=<path.json>` (a camera flight);
  `--anim-shots=<dir>@<start>,<count>,<step>` saves `count` frames `step` seconds apart
  (`--anim-hud` keeps the HUD), with `--anim-pose=<run|mine|aim|...>` holding the character in one
  animation (also `walk`, `exo`, `back`, `stop`, and in mech armour `hover`, `fly` and `flyloop`:
  take-off, hovering and landing every 4 s), `--anim-rate=<x>` playing it at x times its speed (0.1
  to step through a loop, as each screenshot takes longer than a frame) and `--worm-state=<0|1|2>`
  every worm folded, up or attacking. The mock's `--fly loop|walk` (with `--armor mech-armor`) makes
  the character fly at Factorio's own rates, on a timer or while walking.
- For screenshots and comparing: `--far-merge-from=<tiles>` merges far chunks' buildings from that
  distance (under 40 tiles, up close too); `--rail-from=<x>,<y>` starts the rail planner there once
  rails are held; `--map-surface=<index>` shows that surface on the map after 6 s and
  `--remote-surface=<index>` its world in the remote view; `--update-rate=<0-3>` asks the bridge
  for that `rate` level from the start; `--factorio-locale=<code>` uses that language's names
  instead of Factorio's setting.
- `--from-factorio` is what server/factorio-with-zenith.ps1 passes when Ctrl+F9 in Factorio starts
  Zenith: it comes to the front once joined and minimises Factorio (Settings → Other).

Two more measurements against a running server, without the windowed client (their docstrings
have the usage): `python tools/alt_cost.py` streams the chunks round a spot and measures what
Alt-mode costs the bridge, off and on; `python tools/request_spikes.py` sends the client's requests
one at a time while the bridge traces every tick, and reports the slowest tick round each.

## The native belt simulation (optional)

The client runs Factorio's belts itself (`client/scripts/world/belt_sim.gd`). The same simulation in
C++, `BeltSimNative` (`client/native/belt_sim/src/`), is a GDExtension that gives the same results item
for item, several times faster; `belt_items.gd` uses it whenever it is loaded and belt_sim.gd otherwise.
The same library holds `BeltDrawNative` (`belt_draw_native.cpp`): belt_items.gd's job from the
simulation's changes to the GPU records (`--belt-draw-native`, above), the same records as the GDScript
path (`tools/belt_draw_diff.py`).
The Windows library, `client/native/bin/belt_sim.windows.template_release.x86_64.dll`, is committed, so
nothing needs building to use it. Without it (other platforms, or the file deleted) Godot prints three
`ERROR` lines at start-up ("GDExtension dynamic library not found: 'res://native/belt_sim.gdextension'"),
and everything runs on belt_sim.gd; the tests pass either way.

`--belt-sim-native=off` runs belt_sim.gd with the library loaded (its drawing and lattice in GDScript
too). If Zenith ever dies inside the library (an access violation, exit code 3221225477, with no
backtrace: a loop side-loading onto itself on Aquilo did that), the same spot under belt_sim.gd stops with
a script error and a GDScript backtrace naming the line, which points at the C++ function of the same name.

Godot loads an extension only once it is listed in `client/.godot/extension_list.cfg`, which an import
writes: on a fresh checkout run `godot --headless --path client --import` once, or the client and the tests
run on belt_sim.gd (`belt_sim_native_test.gd` then says "BeltSimNative isn't loaded" and skips).

To build it again after changing `belt_sim_native.cpp` (Windows, MSVC Build Tools 2022 or newer, Python):

```
git clone --depth 1 -b 4.5 https://github.com/godotengine/godot-cpp client/native/godot-cpp   # once (git-ignored)
python -m pip install scons                                                                  # once
client\native\belt_sim\build.bat                                                             # vcvars64 + scons; the first build takes ~10 minutes
client\native\belt_sim\build.bat godot_cpp=E:/other-worktree/client/native/godot-cpp               # a godot-cpp built elsewhere (6.5 GB built)
```

The first build takes ~15 minutes (godot-cpp, with link-time code generation); after a change to our own
source about 2. Symbols and a link map (`.pdb`, `.map`, git-ignored) are written beside the DLL: Godot's
crash backtraces give `belt_sim...dll+<offset>`, which the map turns into a function.

A change to belt_sim.gd's rules must be made in `belt_sim_native.cpp` too (it follows the GDScript
function by function, down to belt_sim.gd's own slips: see the test's header). Check them:

```
godot --headless --path client -s res://tests/belt_sim_native_test.gd   # both step for step: PASS, 0 differences
godot --headless --path client -s res://tests/belt_sim_replay.gd -- --native   # or --gd: 73,185 right, 0 wrong
godot --headless --path client -s res://tests/belt_sim_bench.gd -- --native    # or --gd: the cost a tick
```

On the desktop (i5-6600K), replaying `main_belts.json` (Zenith Test's main belts, 12,800 items, the
game's oracle at the square's edges): belt_sim.gd 4.4 ms a tick, BeltSimNative 0.17; six copies side by
side (77,000 items) 23.4 against 0.86 ms; the synthetic bench's 80,000 items (loops and backed-up runs) 17.9 against 0.16 ms. In
belt_items.gd's job (`tests/belt_bs_perf.gd`, `--gd` for belt_sim.gd) on a captured stream: 3.0 against 0.08 ms a tick.

## Tests

```
python3 -m venv .venv && .venv/bin/pip install lupa "gdtoolkit==4.*"   # once (Windows: .venv\Scripts\pip)
.venv/bin/python tools/mod_tests/test_bridge.py   # the mod, against a fake Factorio API
.venv/bin/python tools/mod_tests/test_data_stage.py   # the mod's data stage (the graphics list)
.venv/bin/python tools/mod_tests/test_fuzz.py     # the mod against malformed, truncated, out-of-order packets
python3 tools/test_mock_server.py                 # the mock server, over real UDP
python3 tools/test_mock_fuzz.py                   # the mock, fuzzed the same way
.venv/bin/gdparse $(find client -name '*.gd') >/dev/null || echo "FAIL"
python3 tools/models/check.py                     # after model changes: name, footprint, origin, triangle budget
godot --headless --path client res://tests/ui_test.tscn   # the UI's input paths; exits 1 on failure
godot --headless --path client res://tests/addon_test.tscn   # add-ons: loading, keys, the camera, data
godot --headless --path client res://tests/bridge_fuzz_test.tscn   # the client's packet parsing, fuzzed
godot --headless --path client res://tests/decor_test.tscn   # decoratives
godot --headless --path client res://tests/vr_test.tscn      # VR panel and session without a headset
godot --headless --path client -s res://tests/model_load_test.gd   # after model changes: every model loads the same both ways
godot --headless --path client -s res://tests/mod_files_test.gd    # mods' files and the graphics list
```

CI (`.github/workflows/tests.yml`) runs all of these on every push, and `tools/live_check.py`
and `tools/busy_base.py` against Factorio's Linux headless build.

`test_bridge.py` and `test_mock_server.py` check every message against the protocol (`tools/protocol.py`). `lupa` embeds Lua
5.2, the version Factorio uses. `tools/live_check.py` (above) checks the mod in real Factorio.

## Not done yet

- Fluid in pipes and machine windows (Factorio's pipe windows; the mod sends the fluids, the hover
  line shows them, storage tanks show their level), glowing heat pipes (the hover line shows the
  temperature), the "not connected" power icon (the hover line says so). Items in machines.
- Space platforms: flying up to or past a planet needs smoothing; the rocket silo's launch needs an
  overhaul. Train and platform schedules don't look and feel quite like Factorio's yet.
- Train stops are drawn in their model's colour, not the one given to them (trains wear theirs).
- Models: the electromagnetic plant and the electric furnace need work, pentapods' shells have no
  models, and several of FUE5's models haven't got their moving parts or glow back (the roboport's
  doors, the pump's pistons, the pumpjack's beam, the reactor's, lab's and beacon's glow). Ground
  clutter has no 3D foliage.
- Forests are the graphics card's biggest cost on High.
- Tips and tricks has no pictures (Factorio's tips are simulations the client can't play).
- A mod's buildings without a model are their picture on a card: animated at 16 frames of each
  loop, no working lights at night; a mod that changes graphics in its own `data-final-fixes` after the bridge's shows the
  earlier pictures.
- Hybrid single-player has been played only a little (on Factorio 2.1.24). Starting Zenith from
  Factorio's Ctrl+F9 needs Factorio started through `server/factorio-with-zenith.ps1`, on Windows.
