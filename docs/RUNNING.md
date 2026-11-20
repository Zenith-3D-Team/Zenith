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
menu over a live 3D scene (`client/data/menu_world.json`: since 0.2.2 a snapshot recorded for Zenith
in a vanilla Space Age game with the Esc menu's **Use this view as the menu backdrop**, shown from its
saved camera view; made from the snapshot by `tools/make_menu_backdrop.py`, which checks every
prototype name against vanilla Factorio's `--dump-data`, drops any other mod's, leaves out the save's
name and the time, and names train stops "Train stop"; it also checks the recipes, items and fluids entities
name (Alt-mode's `ai`, `fc`), leaves out the chunks' decoded `_tiles` and delta-codes `ih` (`z` 1), which
change nothing drawn. The 0.2.2 default is the owner's Space Age factory, 4,775 entities, 1.55 MB of
JSON (370 KB gzipped in the downloads' zips). `-- --menu-backdrop-camera=drift` gives it the
slow drifting camera of before. The mock's factory it showed before, recorded by
`tools/record_menu_world.py`, is now the backdrop tests' messages, `client/tests/data/mock_menu_world.json`):

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
    steady 59-60 either way, the client's frame rate unchanged; Windows sets it with a hidden
    PowerShell, `(Get-Process -Id <pid>).PriorityClass`, not waited for, and the log says what Windows
    reports once it answers, or why it couldn't (wmic, used before, is gone from current Windows 11:
    the setting did nothing there and the log said it had; off puts back the class the client had,
    AboveNormal on the 0.2.0 baseline's PC); elsewhere renice), smoke and particles, Items in 3D (Icons only, up to 20,000
    or All, default All: how many belt items are 3D models, nearest the character first, the rest
    their icons; Icons only draws every item as its icon, on the ground and in hands too), clouds,
    decoratives, decorative density and distance (64 to 320 tiles, default 192), 3D grass (off, 30
    tiles still, 40 or 50 tiles with wind; default 40; see Decoratives). Models always wear each
    part's colour from Factorio's sprites (the projected-sprite model look is gone). Smooth belt items (belt items
    read in one tick every update, so they follow curves) and item icons are no longer shown and
    stay on (Hold the game at 60 UPS has no step for smooth belt items; only an add-on's lighter updates ease it). **Advanced:**
    anti-aliasing (Off, FXAA, SMAA, TAA, MSAA 2x/4x/8x; default SMAA, the sharp one; TAA softens moving
    belts; under a look that draws full-screen passes, such as the Cinematic shaders, the MSAA choices are
    greyed out and a saved MSAA is switched to SMAA in the settings (at the start, or when such a look
    comes on, with a message), since the passes read a depth MSAA averages at every edge; a look's TAA
    runs in SMAA's place while it is on, FXAA with it), shadows (off,
    low, medium, high, ultra: the sun's shadow map is fitted to the ground in view, one map from
    the angled view and Godot's splits when the view reaches the horizon; Low one 2048 map out to
    80 tiles, Medium 4096 to 110, High 4096 to 150, Ultra 8192 to 200; the soft filter Godot's Soft
    Very Low on Low, Soft Low on Medium, Soft High (16 taps) on High and Ultra, its blur fitted to the
    map so a shadow's edge is about 0.02 tiles wide on the ground at every zoom, as Factorio's sprites
    draw it, never under a texel; `scripts/world/sun_shadows.gd`), shadow distance (Automatic, the Shadows quality's 80 to 200
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
    GPU at a busy base on a desktop card; `--ssao=off` (or `=on`) for one run, the command line wins; turned off once in settings saved before it was retuned), Contact shading
    (on: the dark rim on the ground round each building's foot that Factorio's sprites have, faint under chests,
    none under belts, rails, walls, pipes and trees, a faint patch under drills, labs, radars and centrifuges,
    kept to their footprint; contact_shade.gd, one draw per chunk), render on a separate thread (off: Godot's experimental mode, after a
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
    client's own: shortcut bar, research, alerts, debug line (its key named when bound: F4 in dev builds), the minimap's size, zoom and
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
    out before the map comes back (80-480 tiles, 240 by default), mouse sensitivity, invert mouse look.
    (Camera follows the hills is gone: the camera is always on the character, on an add-on's hills too.)
  - **Factorio install**: path to `factorio.exe` (or its folder; empty finds it), the server's
    data and saves folders, the first port servers use.
- **Mods**: base, the DLC and the mods in the server's mods folder, with versions and on/off boxes,
  written to the server's `mods/mod-list.json` (Space Age brings Quality and Elevated rails along;
  the bridge is always on). The map generator leaves Space Age's planets out while it is off.
- **Menu backdrop** (after Model packs): what the menu shows behind it, Zenith's own factory or one of
  the snapshots recorded in games (the Esc menu's **Use this view as the menu backdrop**:
  `client/scripts/menu/backdrop_recorder.gd` sends `resync` `full: 0`, keeps the 5 x 5 chunks round
  the camera's spot and 8 s of `mv`/`bs`/`ih`/`gi` with the handshake's prototypes, the player's own
  character left out, and writes a new file in `user://backdrops/` each time (since 0.2.2;
  `client/scripts/menu/backdrop_list.gd`), named by the time it was taken (`backdrop-YYYYMMDD-HHMMSS.json.gz`,
  nothing typed in a file name): Godot's compressed file, gzip,
  `{"v": 1, "center", "camera", "puppet", "save", "name", "taken", "messages"}`, 3 x 3 chunks past 8 MB of
  JSON, and a still picture (no live updates, a log line) if 3 x 3 is still over; the resync sent once
  more if no chunk of the square comes in 2.5 s, as the bridge ignores one within 2 s of the last;
  nothing written if the chunks don't come in 30 s. The live kinds are cut to the square as they come
  (`cut_live`: movers, hands and ground items by position, `st` by its entity's chunk, belt lanes by
  their `lm` middle point, a lane's lists together, a kept lane going on into one outside marked as
  leading out, `lm` next -1 or minus the key, as the bridge marks its own edge); the file is made and
  written on a WorkerThreadPool task, `done`/`failed` given by the next `advance()` after it ends).
  `menu_background.gd` draws it with the
  same replay loop as `menu_world.json` (the default, the same kind of file), the camera at the saved
  view turning 3 degrees either way.
  The window lists Default and the saved ones, newest first, the one shown marked ("In use", greyed):
  each saved one's name (the save it came from and the date and time; edited in place, Enter or leaving
  the box keeps it, kept in `user://backdrops/backdrops.cfg` and, as recorded, in the file), **Use** and
  **Delete** (asks first, Factorio's red confirm; deletes the file for good; the one in use goes back to
  Default). **Open folder** opens `user://backdrops/` in the file manager (`OS.shell_open`); a snapshot
  dropped there is listed by the `name` (else `save`) inside it. **Choose from a world…** opens Load game.
  `[interface] backdrop` holds `default` or the id (the file's name without `.json.gz`) in use; `snapshot`,
  the setting before 0.2.2, still names `user://menu-backdrop.json.gz`, which is moved into the folder
  once, at the menu or the window (named from its `save`, "Saved backdrop" without one; in use if it was;
  a copy that couldn't remove the old file notes its time and size and isn't made again). The background
  is made again on a change, and when the Model packs window closes with the packs changed.
  `-- --menu-backdrop=default` shows the built-in world whatever the setting; a missing, unreadable,
  other-version or chunk-less file does too (one log line; the window marks Default then and says the
  file can't be read). `-- --menu-backdrop-save=overwrite` brings back one file, overwritten: a new
  recording replaces the one in use (with Default in use it still adds one).
  The Esc menu's button is greyed (and a press refused, "the game is still loading") until the 5 x 5
  chunks round the view are drawn after the join, or 20 s into the game (a view at the map's edge),
  checked again 4 times a second while the Esc menu stays open;
  `-- --backdrop-wait=off` lets it record at once, as before. The progress box's Cancel goes grey once
  the file is being written (the bar at its end): the write can't be stopped then. Saving it logs each step of its end
  (`backdrop: done 1/3`..`3/3`); setting `[interface] backdrop` in a game applies nothing there
  (`main.gd` MENU_ONLY_SETTINGS: it used to apply every game setting again).
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

`server/data/mods/factorio-3d-bridge` is a junction to the repo's `mod/factorio-3d-bridge`: a delete or move
that follows it empties the repo's mod. Remove the link alone first (`cmd /c rmdir <link>` without /s, or
`[System.IO.Directory]::Delete(<link>)`); never PowerShell 5.1's `Remove-Item -Recurse` on a folder holding
it, and robocopy `/MOVE` or `/MIR` only with `/XJ`. Python tools delete such folders with
`tools/safe_delete.py`'s `remove_tree` (tested by `tools/test_safe_delete.py`).

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
`dist/Zenith-<version>-dev-<platform>.zip`, a development build for testers. A dev export
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

**A modeller's models in the download:** `--models <folder>` zips the `.glb` and `.gltf` files at
that folder's top and in its `items/` folder (as `items/<name>`, where Zenith finds a pack's items; and any
`.bin` or textures a `.gltf` points at), stored as they are, into the
download's `models/Zenith.zip` beside the program, with a `pack.json` (name "Zenith", author
Vasillo, the licence line saying his permission and that they aren't under Zenith's GPL, the model
drawn as its picture) and a README.txt saying the same; the models folder's README.txt gets a note too.
Zenith reads that folder at start-up, as in a checkout, and the zip is a model pack that goes on top of
the built-in ones the first time, so the download shows Vasillo's models with no option set; the Model
packs window moves it or turns it off, and `-- --no-custom-models` leaves it out. Development
builds carry Vasillo's models this way (his permission; CREDITS.md): `--channel dev --models <his
models>`. Public builds leave it out unless the owner says otherwise. `--models <folder>
--zenith-zip <out.zip>` (or its old name `--default-zip`) writes that zip alone and builds nothing
else: how a source build gets its `models/Zenith.zip`. The pack was called Default (`Default.zip`)
before: Zenith reads an old `Default.zip` as the Zenith pack (left out when a `Zenith.zip` is beside
it), and settings.cfg's `order`, `off` and `choices` and user://building_models.cfg's choices saved
with `zip:Default.zip` as Zenith's (model_packs.gd `canonical_id`).

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
`--alt-icons` puts a row north of the start for Alt-mode's modules and science packs (K1, K2): an assembling
machine 3 with four modules, a lab with seven packs and two modules, an electric mining drill with three and a
beacon with two (drawn only with the mouse on it, as Factorio 2.1); `--start 14,-9` stands next to them.
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

**A world made in Zenith, joined from Factorio** (L13). A map Zenith's menu made has no player of its
own, so the bridge plays its own character there. When you then join that server from Factorio (Ctrl+F9
starts Factorio with `--mp-connect` to it, or Multiplayer → Connect to address), you take that
character over: where it is, its inventory, armour, guns, logistic requests, crafting queue and the
vehicle it sits in, the same character the client goes on playing, and Zenith's quickbar becomes
yours; the character the game gave you on joining is emptied into it (without freeplay's starting kit,
which you had already) and removed. From then on you are that world's player here, as a save's player
is: when you leave, the bridge stands in for you where you left, and when you come back your character
takes it all back. The bridge knows it is you by name: Zenith's hello says the account your PC's Factorio
plays under (`pn`, from `player-data.json`'s `service-username` in Factorio's write-data folder,
`%APPDATA%\Factorio` or beside a zip install; `--factorio-player=<name>` overrides it, empty for none).
Anyone else who joins gets a character of their own, as before; a save's player (or a `/f3d-player`
choice) keeps the character, only the first client's character is handed over, and a player of that
name already in the game when Zenith connects is claimed then. When Zenith can't find the name it
says so as Ctrl+F9 starts Factorio, which then joins as a player of its own.

Freeplay makes its crash site (the crashed ship, its fires and the intro's cutscene, with the time set
to dusk) when its first player is created: on a world made in Zenith that was the first time anyone
joined from Factorio, and the ship came down in the base round the spawn and set it burning. So when
the bridge plays its own character on a server whose freeplay hasn't started yet (no player was ever
created), it tells freeplay not to, through freeplay's own remote interface (`set_disable_crashsite`,
as mods do from on_init; logged as "freeplay's crash site is off"). Nothing on the map changes; a map
whose intro already ran is left alone, and single-player, which creates its player before any client
connects, keeps its intro. `/f3d-perf zenith_join off` and `/f3d-perf no_crash_site off` put each back
as before (`tools/live_check.py --only join` checks the crash site and `pn` against a fresh server).

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
not at all by default (`/f3d-bs own_rate` and `period_max`, below: `period_max 0` stretches them to 12 ticks at level 3, as before). Hold the game at 60 UPS sets both; `/f3d-rate 0-3` sets the level by hand, `/f3d-rate <0-3> hold` holds it against the clients' `rate` commands until `/f3d-rate free` (measuring one level). While
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
item distance, which shrinks the square the bridge reads; its Moving belt items steps, 3000 and 1500, are the
belt cap, which a `bs` client's square ignores under `full_area`, so the governor skips them: `--ups-updates-steps=on`
takes them again). `period_max` (6, the detail interval: never stretched; 0: rate.lua's 12 ticks at level 3, as
before): the longest period `bs` is stretched to (measured at -62,-26: 6 ticks at level 3 cost 1-2.5 ms a tick of
bridge and about 1 UPS, and kept phantoms under the 2% gate in 4 of 5 runs where 12 ticks did in 1 of 6; visible the
same: "Update rates at the owner's belts", below).
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

The 0.2.1 hotfix's belt housekeeping (the bridge performance plan's change 3; each on by default, off: as before):
`quiet_first` (a watched belt whose lanes are all quiet is passed over before its `valid` is read: one call per
watched belt per update less; one gone without an event is dropped when its check comes up), `watch_nosort` (the
watched belts' order made with number sorts of their scan indices, no Lua comparator, and only when the watched
set, a spot or the scan changed, not whenever any belt loaded; the actors' list walked to its length at the round's
start instead of copied), `scan_step` (a new scan once the focus moved max(1, r / 32) tiles, 11 at 352, instead of
every tile; the square's middle lags the character by as much, its far edge alone), `far_load_cap` (first loads of
belts past `walk_near` get 400 units a tick unless the tick's work budget is three quarters unused, instead of half
the budget: the far edge on laps; only once the client's square has been loaded whole, so a join, a resync or a new
surface loads at the full share: capped from the join on, a cached join's belts finished loading at 23-27 s instead
of 9.6, with no better UPS meanwhile). Measured on the owner's base (art-src/perf-plans/after.md): the bridge's
belt part about as before settled, `bs.load` on laps 1.3-1.5 -> 1.07 ms.

**Performance switches** (`scripts/perf.lua`, the 0.2.1 hotfix): `/f3d-perf` (console or RCON, no restart) lists
them; `/f3d-perf <name> on|off|default` sets one for every client (kept in the save), the old behaviour back when
off. All on by default. `chunk_text`: chunk snapshots (`chunk`, `ents`, `dec`) are written as JSON text in the
snapshot's own slices, under the work budget, instead of `helpers.table_to_json` in the outbox's flush (which cost
0.3-0.5 ms a KB outside the budget: 1.4-2 ms a tick while chunks streamed on the owner's base, 40-65 ms ticks in
photo mode); the same messages on the wire, except that an empty list is `[]` instead of `{}`. `far_lanes`: a
belt-simulating client gets no far lane icons read where its square covers them: none at all once the square
reaches the far distance (the client's belt item distance is its far one, so every chunk once loaded), and chunks
wholly past the far distance from the square's middle aren't read for a margin. `wire_strips`: the look for wires
changed without an event (another player's hand, a blueprint pasted over poles, a script) reads the focus square in
8 strips, one every 30 ticks, so such a wire shows within 4 s instead of half a second (the whole square was 13.5 ms,
up to 49, twice a second); the client's own wire tools send theirs at once. `lightning_planets`: lightning is looked
for every 12 ticks only on planets whose prototype has it (Fulgora; the data stage lists them in the `zenith-planets`
mod-data), elsewhere every 300 ticks, for a script's `execute_lightning`. `states_near`: machine states within 64
tiles of the focus every 30 ticks as before, the rest of the focus square a quarter a round, so a machine further out
starts or stops its animation up to 2 s late. `requeue_slices`: a chunk queue of more than 512 put in a new order
(the view turned, the middle moved) by a job over the next ticks, 1,024 chunks a tick under the chunks' share of the
work budget, chunks still taken in the old order meanwhile, instead of all at once in the packet handler. Without a
switch, the chunk queue is taken from its head (`table.remove(queue, 1)` shifted the whole queue for each chunk:
60 us with 10,201 queued) and compacted every 1,024, and the chunks told as kept likewise. Not measured in the game
yet: the Lua tests check each against the old behaviour.

The round after the hotfix (the bridge performance plan's changes 8-15), also `/f3d-perf` switches unless said:
`records_by_prototype` (on): a chunk record takes its prototype's type and id from a table made once a name instead
of reading `entity.type` five or six times, and natural entities (trees, rocks, ore, cliffs, fish) read only their
deconstruction mark, not their quality, upgrade and wires; the records are the same. `alerts_quiet` (on): the alerts
pass, which looks for the force's machines without power, fuel or ammo through every surface 32 chunks a tick, passes
over a chunk where it found none (a quarter of a chunk's price) until something is built, mined or changed there or
every tenth pass, and steps once a tick whatever the number of clients (its results are the same for all; with
clients of different forces the first one's). `one_search` (on): cargo pods (`cp`), spiders (`legs`), rolling stock
(`tr`) and enemy units (`en`) come from the movers' search of the focus square, which finds them anyway, by kind, not
from a search each of the same square (3-4 ms each on the owner's base); worms, which don't move, are searched every 300
ticks. How many of each the movers' search found goes into storage on its tick, so what those jobs keep there is the
same on every peer. A pod or train appearing with nothing else changed shows with the movers' next search (8-32 ticks
later) unless a rocket launch or a cargo pod setting off or arriving (their events) brings that search forward; a new
worm shows within 300 ticks. `/f3d-bs two_call` (on by default; `/f3d-bs two_call off` for the four-call check every
time, kept in the save, and a save that never set it takes the default): a watched lane's check
reads its item count and its front item's place first and takes it as unchanged when both are as last seen, the
four-call check (stacks, back item) only when either differs and every fourth check anyway; not for lanes leading out
of the square or fed from outside it. What it adds to the check's blind spots: a stack count or the back item changing
with the count and the front the same, seen up to three checks late. Measured on the owner's base: 0.35 ms of bridge a
tick less settled, and as many of the game's items drawn at -62,-26 (97.8% visible, 1.2% phantoms). `/f3d-bs far_tier`
(off by default: no gain at 352 tiles on the owner's base, 40% more asks, a worse p99; it changes
when far belts are read), with `far_ring <tiles>` (96) and `far_units <belt units>` (1200; under 1 ms a tick at 6-tick
updates): the watched belts and the inserters and drills using belts within `far_ring` of the focus are checked every
update as before; those further out are checked in turn by a cursor that carries on where the last update stopped,
`far_units` an update (each at most once an update), an actor just before its belt so one that acted gets its belt read
in the same pass. Far watches skip downstream tail catch-up and `read_runs`, and `bre` asked groups run nearest-first
by scan index so `extra_units` stay near the character. The whole square stays loaded and simulated; every read still names its own tick, so a far input spot
read every second to fifth update reaches the client that much later (an inserter's drop 200 tiles away up to half a
second instead of 0.1 s). The far list is made again when the scan changes, else at most every 16 updates for one scan.
The plan's estimate: 0.9-1.4 ms a tick at the owner's settings; not measured.
`/f3d-bs target_spots` (on; off: as before): an inserter's or drill's belt is its pickup or drop target when the game
has one set and alive, else the belt on the tile of its pickup or drop spot. In 2.1 a drill has no `drop_target` until it
first puts something out (a replaced target stays a dead entity until then), and the bridge reads a chunk's targets
once and keeps them, so a drill placed before its belt, or a belt laid or replaced under a running drill, was never an
input spot: its belt wasn't watched and its items reached the client only when a drift check happened on one and the
client asked again (the owner's fresh world: on a copy of a new map, a drill feeding a 30-tile belt, 17-22% of the
game's items drawn on the 8 tiles nearest the drill, 85-88% over the belt; with 650 ms main-thread hitches every 2.5 s
0-10% of the moving items, 71-73% over the belt). An actor still without a target at an end is looked at again every
300 ticks, so one whose belt comes without an event (and a scan to find that belt) is found too.
`/f3d-bs built_now` (on; off: as before, K16, K22): a belt built, turned, replaced or removed is worked out on the next
tick, not at the next round's scan of the whole square. One built inside the square is loaded there and then (`lm`, `sl`,
read on that tick, in the next update), the loaded belts round it read again with it (its feeders and what it feeds, an
underground's other end, those within 7.5 tiles), a removed one's lanes leave (`dl`) in the next update, and a loaded
belt under a new one whose entity is gone is dropped (a fast-replace raises nothing for the old belt). Up to 2,400 belt
units a tick (`belt_sim.built_units`); the rest the next tick or the round's queue. Before, a new belt waited for the
round's start, any scan in progress and a scan of its own, each reading at most two chunks a tick whose lists had
expired (empty ones too): offline (the mod in Lua against the fake API, a belt built every 257 ticks), at a belt item
distance of 320 a new belt's `lm` came 9-200 ticks after it was built (half of them past 55), at 640 up to 550, and the
line it extended stood in Zenith meanwhile; on, 1-6 ticks at both, its read on the build's tick. Also on with it: a belt
loaded again after an event reads its lines' lengths again (a belt turned into a curve kept its straight lengths for the
catch-up and the packed checks). `/f3d-perf mined_tell` (on; off: as before, K22): what a player-less character mines
(a headless server; Factorio raises no event then) is told to what listens, as on_player_mined_entity does for a
player, so the belt simulation drops a mined belt's lanes the next tick and reads the belts round it; before, they
stayed until a check of that belt came round (seconds for a belt nothing watched) and its neighbours were never read
again for it.
`/f3d-perf zenith_join` and `/f3d-perf no_crash_site` (on; off: as before, L13): the player who joins with this
Zenith's Factorio takes over its character, and freeplay's crash site stays away from a world the bridge played before
anyone joined it (see "A world made in Zenith, joined from Factorio" above).
`/f3d-bs lane_next` (on; off: as before, E31): each lane's `lm` next says whether that lane leads out of what is sent,
from the belt its own items go on into (a splitter's output lanes each by their half's belt, found by where they end;
an underground entrance's hidden lines by its exit), and is sent again, with the lane's items read on that tick, when
that changes: when the belt it feeds loads (no longer negative) and when that belt leaves the square (negative, in the
update whose `dl` says so). A lane read twice in one tick sends its meta with the second read too, and reloads a round
didn't get to wait for the next round. Each drift check, lane leading out and watched belt checked also looks at its
lanes' next against what the client was told (counted in `/f3d-bs counts` as `next_fix`; `next_sent` counts the
changes sent where they happened). Before (the second PC, at the end of the owner's bus west of -62,-26): a belt
loading read its feeders' lanes again without their meta, so their -1 stayed though their next was sent (first loads
chain at most 4 rings out, so a line going outwards had every fourth ring loaded before its next, and the square's edge
did the same at every step walked); a belt leaving had its feeders' -1 sent only with the next round's reload, the
lanes saying 0 meanwhile with nothing after them (the client stopped their front items at the end: jumps); a reload
after a catch-up's read of the same lane in the tick lost its `lm` (a curve straightened by a belt built behind it kept
its curve in Zenith); a splitter with one half's belt not loaded had all four output lanes -1. Offline only (the mod in
Lua against the fake API, test_bridge.py's E31 section): not yet run against real Factorio.

`/f3d-bs ins_driven` (off until measured live; off: as before, the owner's idea): a belt watched for its inserters
alone (an inserter's pickup or drop belt, the belt behind a pickup belt: not a drill's drop belt, a splitter, a loader
or a loader's neighbour, nor a belt with a circuit connection, which keep their watch) gets no look every update. When
an inserter's own check (every update, its hand's count; the bridge's reads, not inserters.lua's `ie`, so the same on
every peer) finds the hand fuller, its pickup belt and the belt behind are read, and when it finds it emptier, its drop
belt is read. "Read" here means: each lane in full, except a lane holding items that stands as its last read left it, plus
the belts they feed as far as an item can have gone since the hand's check before. Then the belt is watched as before
for `ins_window` updates (20; 0: not) or until it settles, so the reads while the hole closes up and the settled read
still come; Zenith's packed-lane lattice takes a lane's motion and phase from those reads. Such belts get drift checks
(`pc`) as unwatched ones do. An inserter at one is checked every update, not backed off. `/f3d-bs ins_ho` (on; only
under `ins_driven`): a put by an inserter within the detail radius of the focus, for a client whose hello says `ie` and
`ho`, isn't read at all: the client got the item itself (`ie` PLACED). Needs `inputs_first`; off under `checkpoints`.
`/f3d-bs counts` shows `ins_takes`, `ins_puts`, `ins_told`, `ins_reads`, `ins_window`. Measured offline only, on four
line-end scenes (tools/belt_line_end.py, in which every belt is an inserter's; tests/belt_bs_replay.gd `--ie-wire=0`
and tools/belt_jumps.py): the bridge's belt work 30-39 -> 14-24 units a tick (39-54% less), lane reads 53-71 -> 14-28 a
second; the client's simulation by id 99.86-100% (99.99-100% off), the game's items drawn as often (98.8-99.6%), phantoms
0.06-0.14% -> 0.15-0.21%. Without the window (`ins_window 0`) the work fell 62-73% but the lattice drew pickup belts
from the read just after a take (the hole still open): 0.5-0.7 points fewer items seen. On the owner's base the share
of the belt watch on inserters' belts is unknown: measure there before turning it on (`tools/belt_truth.py`,
`tools/live_check.py`'s belt sections, `/f3d-profile`'s `bs.watch` and `bs.actor` at -62,-26).
`/f3d-bs quiet_pc` (on; off: as before, every unwatched lane drift-checked each turn, about every 32 updates near, 64
and 128 further out): an unwatched belt whose drift checks keep agreeing, nothing touching it, has each next check twice
as far off, up to `/f3d-bs quiet_pc_max` ticks (3600, a minute, near and far: the owner's safety limit; 0: every turn).
Any touch puts it back to every turn: a full read of one of its lanes (a `bre`, a packed run's read, a tail, a settle
read, a reload after building, mining or rotating near it), a watched belt behind it that changed or was put on (as
far as its tails reach, read or not), a wired belt behind it switched on or off, a splitter behind it set again (pasted,
its window closed, Zenith's own screen). Kept in each belt's record in storage, by game.tick: the same on every peer.
Offline (two 10-minute quiet 70-belt turbo lines, flowing and stop-and-go, no rereads answered): drift checks' numbers
125,360 -> 8,100 (94% fewer), the bridge's belt work 1.05 M -> 0.70 M and 0.60 M units (33% and 43% less), the client
exactly the game's (100.00% in place, 0 items off) both ways. `/f3d-bs reads` says why lanes were read in full since
loading, by cause, watched belts' and the rest's (`load`, `reload`, `next`, `exits`, `catch`, `run`, `tail`, `settle`,
`settled`, `watched`, `asked`, `ins`, `edge`), with the drift checks made (`pc`), passed over (`pc_quiet`) and the
belts woken; the same counts are in `/f3d-bs counts` as `rw_<cause>` and `ru_<cause>`.
`dec_distance` (on): Zenith's hello says how far it draws decoratives (`dd`, Settings > Graphics > Decorative distance,
320 under a screenshot's full detail), and a chunk's decoratives are sent only while the chunk is within that and 64
tiles of the square's middle; the rest are held and sent once the middle brings them inside or the distance grows. At
view distance 50 that leaves out most chunks' decoratives (a fifth to a third of a snapshot's work and bytes). A bridge
before it, or the switch off, sends every chunk's. `chart_same` (on): every minimap or map chart carries a stamp of what
its picture was made from (the chunk's change and entity counts, the resolution); Zenith names the stamps of the
pictures it holds when it asks again (every 5 s for the minimap), and an unchanged chunk is answered `same` with only
its live parts (pollution, signals, robots), not its picture; the bridge keeps a picture until something changed in
the chunk, not 30 s. Old clients get pictures as before.

Three switches for the ninth play-test list's delays, each on (off: as before). `status_near`: Factorio's warnings
over a turret out of ammo, a machine out of fuel and a drill with nothing left to mine (its resources-depleted icon)
round the focus come from the once-a-second power read, as the unplugged icon has since J5, not only from the alerts'
pass (every 10-40 s, several seconds long on a big base); a turret or burner built or removed is read again the next
tick, and after the character moves items (a machine screen's slots, Ctrl+click, Z) the buildings in its reach are
read again 2 and 20 ticks later. `mined_now`: whatever the character finishes mining is said at once (`mnd`: gone or
not, the items it got), outside the reliable outbox where the `del` waits behind chunk snapshots, and the inventory is
sent then too; Zenith takes the entity away and flies the items to the character on it. `put_lanes`: a belt the
character puts items on or takes them off (Z, Ctrl+click) has its lanes read in the next belt update, as Zenith's own
`bre` asks, instead of waiting for the lane's drift check (every 32 updates, several seconds).

`/f3d-perf drop_put` (on; the owner: "holding Z on a belt to place items takes a while to show up"): an item Zenith's
Z puts on a belt is told at once as an inserter's put is (`ie` kind 6 with no inserter, unit 0: its lane, place and
unique id; for a client whose hello says `ho`), and the belt's drift checks come every turn again (`quiet_pc`'s
wake), on top of `put_lanes`' read, which can wait behind other asked lanes. Factorio's own Z onto a belt in the game
window (hybrid) wakes the belt and reads its lanes, if Factorio raises `on_player_dropped_item_into_entity` for a
belt (not checked). Off: the lanes' read alone, as before. Zenith's side, `--belt-drop-show-now` (on; off: as
before): the dropped item shows at once, standing where it lands on the nearest lane drawn, until the drawn clock
(about half a second behind the game) reaches the bridge's put; the simulated item shows there from then. One the
bridge doesn't confirm (out of reach, the belt full there, an older bridge, `--inserter-handoff=off`) goes after
1.5 s.

`/f3d-perf belt_pickup` (on; issue #18): F takes the items on belts too, as Factorio's "Pick up items" does: every item
within the character's item pickup distance (plus half a tile, measured from the character's middle to each item), on
the ground or on a belt's visible lanes, the nearest first, up to 16 a tick (all in range in practice). An item on a belt
goes into the character as its stack (quality and freshness kept) and off its lane; the lane is read before and after,
so what the bridge says is what the game did, and anything the lane wouldn't give up comes back out of the character.
It says what it took at once (`pku`): Zenith hides an item taken off the ground, takes one off its simulated belt on the
game's tick through the same take as an inserter's pick (belt_items.gd `ie`, with no inserter; so with
`--inserter-handoff=off` it leaves only with the lane's next read), and flies each kind to the character with the item's
own pick sound. The lanes are read again in the next belt update (`put_lanes`) and the inventory is sent at once, at most
every 6 ticks while F keeps taking. Off: the ground only, two a tick, as before.
`/f3d-perf pickup_stop` (on; the owner: F "seems to pickup for almost a second after you let go"): Zenith sends
`pickup_stop` as F is let go (also over a window, and when a text box takes the keyboard) and the bridge ends the
pickup then; off, the stop is ignored and a pickup runs on 30 ticks after the last `pickup` (sent every 0.15 s while F
is held), as before and as for clients that never send it. Zenith's side: `--pickup-stop=off` sends no stop. And
`--pickup-hide-now=off`: a belt item F took left the drawn belt only when the drawn clock, about half a second behind
the game, reached the take (its icon already flying); on (the default) the items a `pku` names, by the game's ids, hide
in the belt layer's next job, and a packed lane the lattice draws gets the take's hole from the drawn tick (where the
item was then) instead of the take's own tick.
One for the tenth list, on (off: the chests alone). `alt_machines`: while the client has Alt-mode on, the machines
whose prototype has module slots (assemblers, furnaces, silos, drills, labs, beacons) and the labs in the focus square
are read in the chests' rounds (J6) for the modules and science packs Alt-mode draws over them (`am`, K1, K2): 3 work
units a machine under the work budget, after the chests, each round sending only those that changed. Nothing is read
while Alt-mode is off.
`alt_ammo_fuel` (K1's leftover), on: with `alt_machines`, the ammo turrets and locomotives in the focus square are read
in the same rounds for the ammo and fuel Alt-mode draws over them, one icon a filled slot, where Factorio's prototypes
put them (2.1's gun turret lists its ammo a quarter tile up, its locomotive its fuel three a row; a turret without an
entry, as Space Age's rocket and railgun turrets, gets Factorio's defaults). Off: machines and labs alone, as before.
Cargo wagons (owner: "i do want to see items in cargo wagons"): the same rounds read each wagon's four most-stacked kinds
(most first, no counts, as a chest's) and the client draws them in one row over it, following it as it moves; a
locomotive's fuel is off by default (the client's `--loco-fuel-icons=on` sends `lf` 1 with `altc` and draws it again).
The client's `--alt-ammo-fuel=off` draws none of the three whatever the bridge sends. Fluid wagons show nothing.
One for the eleventh list, on (off: as before). `research_chain` (L12): Zenith's `research` of a technology whose prerequisites aren't all researched or queued queues the missing ones first, all the way down, each after its own (by order), then the technology, as Factorio's technology screen does: 2.1.24's LuaForce.add_research alone refuses it, and refuses a trigger technology and an eighth in the queue (measured in real headless 2.1.24). When one of the missing is a trigger technology nothing is queued and the bridge says which; when the queue can't hold them all, what it queued comes off again ("Research queue full"). Off: add_research alone, as before.

Two more for the eleventh list, on. `fluid_icons` (L10): a crafting machine with a fluid recipe carries its connections and
the fluid each takes or gives (2.1 makes its fluid storages from the recipe, each filtered to its fluid: an oil refinery
on basic oil processing has two) in its record and in `aiu` (`fc`), for the arrows and fluid icons Factorio draws on a
machine hovered or in Alt-mode; off: none sent, the client draws the prototype's arrows without icons. `pipe_alerts`
(L11): a pipeline over Factorio's extent limit (UtilityConstants' default_pipeline_extent, 320 tiles; status
pipeline_overextended on every pipe of it) is an alert, `al` `pipeline`, one entity a fluid segment (the one nearest the
line 320 tiles in from the segment's far edge, where a pump would split it, as the icon stood in the owner's video): the
alerts' pass reads pipes, pipes to ground and storage tanks too (a quarter of a machine's cost each), and a pipe-type
entity or pump built, removed or turned on the focus surface has the pipelines round it read the tick after (`al` at
once when that changes). Off: no such alert, the pass as before.

One for the twelfth list, on. `under_clear` (M2): an underground belt or pipe-to-ground the character builds that
completes a pair mines what lies between its ends into the character, as Factorio's player build does (its tips and
tricks, "Fast replace belt & underground belt": "Any belts in between the entrance and exit of the underground belt
will be mined automatically. This fast replace feature also applies to pipe and pipe-to-ground"): only a plain run,
every tile between a belt going the pair's way, straight and fed by nothing from the side (a pipe connected to nothing
off the line), all of them or none (a gap, a curve, a belt the other way, a side-load, a splitter or a ghost keeps them;
building over another underground, an upgrade, never clears). A script's create_entity doesn't do it, with or without
`character` (measured in 2.1.24), so the bridge mines them itself (building.lua clear_between): each with what it
holds into the character, forced (what doesn't fit spilled, as Factorio spills it), said at once (`mnd`, then the
reliable `del`), the inventory sent once after them. And an underground fast-replacing a belt (a pipe-to-ground a
pipe) is built with `character`, so the belt and the items on it go to the character, where `spill = false` deleted the
items. Off: both as before (the belts between stay, a replaced end's items gone). Hybrid single-player with a free
cursor builds as the player, where Factorio does it itself. Ghosts and blueprints are the game's (unchanged).
`python tools/live_check.py --only underclear` checks it against the real game. The client marks the belts that will go
and hides them as the build is sent (`--underground-clear=off`, below in the controls). A drag that places both ends
hides them with the exit's build too, though the entrance's `add` hasn't come yet: the pieces just sent count as
standing until the world has them or the game has moved on without them, for the build and for the cursor's marks and
its entrance or exit model (`--underground-clear-sent=off`: only what the world has, so such a run goes when the
game's `mnd` comes, a tick later, as before).

Two for the thirteenth list's vehicles, on. `fast_take` (N2): an empty hand's Ctrl+click never takes an entity's fuel.
In 2.1 defines.inventory.fuel and chest are both 1, and a locomotive's and a burner drill's get_output_inventory is
their fuel slot (read in 2.1.24), so the bridge checks each inventory against the entity's own fuel inventory and falls
back by type (a chest's, a car's or spidertron's trunk, a wagon's cargo); off: as before, when a locomotive, boiler,
burner inserter or burner drill gave up its fuel. `vehicle_ammo` (N3): in an armed vehicle `me` `sh` and "Out of ammo"
follow the vehicle's selected gun's ammo (the game fires it for the driver); off: the character's, as before. A
vehicle's shots come in `ts` as before (turrets.gd draws them), not as `shot`. `--only vehitems` checks both.

A pipe's end after one beside it is mined, on. `mined_neighbours`: what the bridge's player-less character mines (a
headless server's; Factorio raises no event for it) has the pipes and belts beside it read again the tick after and
sent (`upd`), as a player's mining has them (tracker.lua neighbours_change): the pipe left at a run's end becomes its
ending piece, a belt beside a mined one its new shape. Off: as before, their records kept the side to what was mined
(the run's last pipe drawn as a straight, open at its end in FUE5's kit, until something else changed it). The client
also takes the side towards a mined pipe off its neighbours the moment the `mnd` or `del` comes, for any bridge
(world.gd `_unlink_pipes`); `--pipe-end=old`: its neighbours wait for the bridge, as before.

Enemies seeing the character, on. `enemy_sight`: a headless server's character has no player, and in 2.1.24 a nest's
own idle biters ignored it from 50 tiles to 1 until it shot (loose biters and worms saw it), where a real player's
woke them. Every half second the bridge does what the engine was measured doing for a real player's character
(enemy_sight.lua): a sleeping enemy unit (no distraction, no attack of its own, in no unit group) within its own
prototype's vision distance of such a character gets the distraction a sighting gives (attack the character,
`by_enemy`), and so does every sleeping unit of its nest (the units whose own spawner is in the cluster, its spawner and
the spawners within 15 tiles of it; a neighbouring nest's units stay asleep, and a new unit of a nest woken lately is
given alone); while the character stands they are kept on it, each for its own hold (spread by unit number: about half
gone by 8-10 s, the bridge's re-giving over by 15 s, then the engine's own tail keeps a few on it, as measured for a real
player's), and while it moves every one of them within its vision of it is kept on it, with no
give-up distance. Out of vision nothing wakes; worms need nothing (they shoot it on their own). Nothing is done for a
character with a player (hybrid single-player, a claimed L13 player: the engine sees those), in a vehicle, on a
peaceful or no-enemies surface. Cost: one `find_units` over the largest unit vision's square every 30 ticks, and one spawner
search plus one more `find_units` per nest woken (at most 4 a pass). Off: nothing done, as before.
`python tools/live_check.py --only enemysightfix` checks it against the real game (fresh map only: it clears the enemies
round its spot and runs the game fast for up to 5 minutes).

### Oil, resources and pipelines (the eleventh list)

- Hovering a resource (L6) shows its amount now (`hinfo` `ra`; the record's until the bridge answers), an infinite
  one's yield (its amount over its normal amount: crude oil's 100% at 300,000), the fluid mining it needs and the drills
  that mine it (Factoriopedia's page). On the map (zoomed out) a resource patch under the mouse is outlined in white and
  the entity info shows its total, an oil field's combined yield ("Crude oil combined yield 292%"), as Factorio's map
  view: the bridge sums the patch the tick it is asked (`rpatch`; resources within the prototype's
  resource_patch_search_radius of each other, 3 tiles, crude oil 12; at most 10,000 of them, about 5 microseconds each in
  2.1.24, then "at least"), once the mouse has rested 0.12 s on a tile outside the patch shown. `--map-resource-info=off`:
  none on the map.
- A held drill (L8) is red where its mining area holds no resource it mines ("Pumpjack can only be built on resources",
  "... cannot mine this resource" over ore), the well it would pump is outlined green and the wells round the cursor
  white (Factorio's highlight for crude oil and Space Age's fluid resources); its output arrow shows (an old bridge's `fo`
  hid every drill's), and no arrow in a pumpjack's middle. `--resource-hints=off`: as before. Over uranium ore (any
  resource needing fluid to be mined: the bridge's `rf`) it follows Factorio 2.1.24's rule: an electric drill (a fluid
  input) is red with "Uranium mining not researched." until the force can mine with fluid (`cinfo` mwf; even with other
  ore beside it), and the bridge refuses it in the same words; a burner drill can't mine it ("... cannot mine this
  resource" over uranium alone). `--fluid-mining-hints=off`: uranium counts as any ore in the preview, as before (the
  game still refuses it). A held pipe's preview
  joins the pipes beside it, a pipe to ground facing it and a machine's connection pointing at its tile (it was always the
  lone pipe); `--held-pipe-joins=off`: the lone pipe. FUE5's pumpjack is mirrored across its diagonal
  (`tools/models/fue5_pumpjack.py`), its outlet at Factorio's output (FUE5's was the mirror image); no switch (the old
  file is in git's history).
- A crafting machine's connections (L10) show the fluid each takes or gives, an icon on the connection's tile beside its
  arrow, hovered and in Alt-mode (with "Show machine arrows"); from the record's `fc`. `--fluid-icons=off`: the
  prototype's arrows without icons.
- A pipeline over the extent limit (L11): Factorio's red fluid icon blinks over one of its entities and the alert bar
  says "Pipeline has been overextended."; hovering a pipe, pipe to ground or storage tank shows "Pipeline overextended"
  (its status, red) and "Pipeline extent: 333/320" (`hinfo` `pl`, `ox`). `/f3d-perf pipe_alerts off`: no alert.
- Factorio 2.1's fluid pipeline visualization (N9, `scripts/player/pipeline_marks.gd`): hovering a pipe, pipe to ground
  or storage tank marks each joint of its pipeline with Factorio's both-ways chevron (and an underground pair's run with
  its dashes; the pictures from the install's core/graphics/fluid-visualization/, plain drawn ones without it), tinted
  to the fluid in it, white when empty, red when the pipeline is overextended (the hovered pipe's `hinfo` `ox`, or an
  `al` `pipeline` alert on one of its entities); hovering a pump, boiler or machine, the pipelines on its connections;
  with a fluid entity held, in Alt-mode, every pipeline within two chunks of the cursor (a frame where nothing changed
  costs only a look at the chunks it read). The pipeline is found in the client from the records (`pc`, underground pairs, a tank's `eprops`
  fluid boxes), stopping at pumps and machines, at most 4,000 entities, a slice a frame. Settings > Interface >
  Visualization: "Show fluid pipeline visualization" and "Show fluid pipeline visualization when selected" (Factorio's
  names, on by default, read from its config.ini as the other interface settings). `--pipeline-vis=off`: nothing drawn,
  as before. The mock's line at -24..-13, -17.5 stands for an overextended one (`pl` [340, 320], `ox`, its alert).
- The alert sound: Factorio's beep (its utility sound alert_destroyed, from the install, at half volume) when the
  bridge's alerts gain something destroyed (Factorio's changelog: the beep "only when something is destroyed, not by
  something damaged"). A turret running out of ammunition makes no sound (the owner's choice; Factorio's own beeps once,
  "only sounds once right when the ammo is used up"): `--alert-sounds=ammo` brings that beep back as before. One beep
  however many at once, none for the alerts already there when Zenith joins, none for a kind ticked Muted or Disabled
  in the Alerts configuration (Muted did nothing before). `--alert-sounds=off`: silent, as before. Factorio's own repeat while buildings keep falling isn't measured: here every update with a new one beeps,
  a second apart at most.
- Alerts on the minimap and the map view: the alert bar's alerts (the kinds the bar shows, its 40 nearest of each
  kind, the ones on the surface shown) drawn as Factorio's own alert icons at the minimap's and the map view's tag size,
  destroyed over attack over turret fire over the rest, blinking as the icons over the entities do (a 1 s period, on
  55%; the steady kinds steady). Client only, from the bridge's `al`: nothing more is asked of the bridge.
  `--minimap-alerts=off`: neither view draws them, as before.

### The client's UDP socket (lost datagrams)

Every datagram the bridge sends a client whose hello says `dq` (Zenith does) ends with a `dg` line numbering
it (docs/PROTOCOL.md, Transport), so the client counts the datagrams the OS dropped: `Bridge.loss`
(`datagrams`, `lost`, `unnumbered`), the debug line's "datagrams lost", and `--udp-trace=<file>` (a JSON line
per datagram read: when, its number, bytes, tick, message types). With `/f3d-profile trace` on, the bridge
logs every datagram too (`f3ddg <tick> <n> <bytes> <types>`), and `tools/udp_loss_check.py --bridge-log
factorio-current.log --client udp.jsonl [--stream stream.jsonl]` reports the loss by message type, size and
burst position, the ticks' bursts, and the `bs` updates' tick gaps split by the announced period `p`.

What that found (the udp round, docs/SESSION-LOG.md): the "18% of datagrams lost" at -62,-26 read off the
`bs` updates' 12-tick gaps was mostly the bridge's rate level 3 pacing `bs` at p=12 (148 of 177 12-tick gaps
announced; `rate.lua`). The real loss was 3.3% of datagrams in an 8-minute run there (128 of 3,897) and 18%
at -272,-14 (730 of 4,018) with another agent's Python tools running beside the game: not the tick's burst
(0 of the lost came when their tick had sent over 64 KB; 99% were their tick's only datagram) but the client's
I/O thread going unscheduled: at normal priority on a 4-core PC with the game, the belt jobs and the parsing
thread, it stalled 49 / 89 times for over 100 ms (up to 0.6 / 1.3 s), and Windows keeps 64 KB of unread
datagrams per socket (Godot's `PacketPeerUDP.bind` size is only Godot's own ring; the OS buffer stays the
default, `tests/udp_burst_test.gd`): every stall filled it (the drain after it read 44-135 KB) and lost all
that came until the next read, 1-48 consecutive ticks' datagrams, every message type alike (`bs` parts and
whole updates, `ih`, `mv`, `me`, chunks, ...). `OS.delay_usec(1000)`, the thread's sleep, is 2 ms on Windows.

The fix, in the C++ extension (client/native, `UdpSocketNative`) and bridge.gd:
- `--udp-socket=native|godot` (native, the default when the extension is loaded): a socket whose OS
  receive buffer is `--udp-rcvbuf=<bytes>` (8 MB: tens of seconds of the bridge's traffic), read with
  `wait()` (select) so the I/O thread wakes as a datagram arrives. `godot`: PacketPeerUDP as before.
- `--udp-io-priority=high|normal` (high): the I/O thread at Thread.PRIORITY_HIGH, so an arrival gets it the CPU.
Measured live (one run each, the same harness): datagrams lost 128 of 3,897 (3.3%) -> 0 of 4,085 at -62,-26 and
730 of 4,018 (18%) -> 0 of 4,344 at -272,-14; `bs` updates lost whole 8 / 35 -> 0 / 0, parts missing 10 / 48 ->
1 / 1 (the capture's last update, cut by the stop); the I/O thread still went 50-540 ms without reading 93-106 times
a run (the game's own pauses count in that too) and the 8 MB held everything. Belts: visible / phantoms 96.1% /
2.6% -> 96.2% / 2.3% at -62,-26 (rate level 3 both times; the reference 96.2 / 1.9 is within the spread, still FAIL
there) and 97.3% / 1.0% -> 97.5% / 0.8% at -272,-14 (PASS both). The arms at -62,-26 (tools/inserter_check.py): the
drawn hand's moving error 0.37 -> 0.23 tile mean (p90 0.85 -> 0.43), swing coverage 74% -> 88%. The synthetic burst
(tests/udp_burst_test.gd --socket=native against a sender of 12 x 60 KB a tick back to back): 0 lost, against 3 of 6 x
30 KB with PacketPeerUDP.

### Update rates at the owner's belts (the belt-rate round)

Why the belts at -62,-26 sit at 96.1-96.3% visible / 1.9-2.6% phantoms under Hold 60 UPS (the target 97% / 2%)
while -272,-14 passes, measured live (tools/belt_view_check.py, `--record 60`, by day, 3-4 runs a cell at -62,-26; the
bridge profiled with `/f3d-profile`, the level held with `/f3d-rate <l> hold`, the `bs` period capped with
`/f3d-bs period_max 6`; the run folders under E:\Zenith-scratch\rate):

- **The 12-tick `bs` period is not the gap.** With `bs` at 12 ticks (rate level 3, as the governor reaches it in the
  scored window): live visible 96.1-96.3%, phantoms 1.9-2.3% (4 runs). With `bs` held at 6 ticks at level 3
  (`period_max 6`): 96.2-96.3% / 1.7-2.4% (3 runs). At level 2 held (6 ticks, the tier-3 jobs at their full rate):
  96.3% / 1.8%. Hold 60 UPS off (level 0, everything at its full rate): 96.4% / 1.6%. Visible is the same in every
  cell; phantoms lean a few tenths towards the faster updates, inside the spot's spread (1.6-2.6% over all runs).
  The remaining 0.7-0.9% of visible is the belt simulation's own accuracy at this bus (the splitter balancers: the
  replay diagnostic is 76%); -272,-14 passes at level 2 (97.6% / 0.8%, 6-tick updates there either way).
- **What the 12 ticks cost and save.** At level 3 `belt_items` 4.0-4.7 ms a tick at 12 ticks against 5.3-6.0 at 6
  (`bs.watch` 2.0-2.3 -> 3.0-3.2, `bs.bre` 0.8-0.9 either way), the bridge whole 8.7-9.8 against 10.0-11.6 ms,
  UPS 47.9-48.6 against 46.3-48.5 while scored. Level 2 held: the bridge 12.3 ms (movers 0.77 against 0.3-0.6,
  planets 0.9, tracker 0.24), UPS 45.1. Hold 60 UPS off: 16.8 ms (movers 2.1, transport 3.0, world 1.2, map 1.0 +
  0.9), UPS 36.3. The stretch goes (`period_max` 6 by default): over all the runs, 6-tick updates kept phantoms
  under the 2% gate in 4 of 5 (1.7, 1.7, 1.7, 1.8, 2.4) where 12-tick ones did in 1 of 6 (1.9, 2.1, 2.3, 2.3, 2.3,
  2.6), for 1-2.5 ms a tick of bridge and about 1 UPS here; `period_max 0` is the knob for a server that needs them.
- **Why the game runs at 46-48 UPS while scored.** The game's own update on Zenith Test is ~2.9 ms a tick (the
  server alone at `game.speed` 8 ran 345 UPS, its main thread 0.84 of a core). With the client at -62,-26 the
  bridge's Lua is 8.7-11.6 ms a tick (steady, after the first load: `bs.watch` 2-3.4, `bs.bre` 0.8-1.0, `transport`
  1.4-1.8 (the datagrams: about a millisecond each), `planets` 0.5-0.9, `alerts` 0.6, `map` + `map.strip` 1.0,
  `world` 0.5, `movers` 0.3-2.1 by level), Factorio's main thread 0.85-0.92 of a core (compute-bound, not starved:
  ~3 game + ~10 bridge + ~4 of its own round a modded tick), the client 1.9-2.2 cores and the machine's 4 cores
  87-91% busy. And the recording itself: record.py reads the square's belts over RCON every 60 ticks inside the
  game's tick, so every run shows 55-58 UPS in the 20 s before the recording and 45-49 while scored (-272,-14: 56
  -> 38). Without the recorder the game runs 55-60 at level 2-3 here, and holds 60 at ~8 ms of bridge (once `far`
  96 shrinks the square, ~100 s after joining; the scored window, 60-80 s in, sits on the ladder's way down).
- **What changed.** (1) The governor's ladder (ups_governor.gd STEPS) skips its `updates` steps (Moving belt items
  3000, 1500: `bfar` m, the belt cap): the client simulates its belts and the bridge's square ignores the cap
  (`full_area`), so they bought nothing and cost 5 s each before `far` 96 shrank the square; `--ups-updates-steps=on`
  takes them again (for a bridge with `/f3d-bs full_area off`). (2) The alerts' pass over the force's machines
  (alerts.lua, 0.6 ms a tick here: it fills its 600-tick interval on this save) is a rate job (`al`, tier 2): at
  levels 2 and 3 a pass starts 2 and 4 times less often (alerts show 20-40 s late instead of 10). (3) `/f3d-rate
  <0-3> hold` holds a level against the clients' `rate` commands until `/f3d-rate free` (measuring); `/f3d-bs
  period_max <ticks>` caps the `bs` period (6, the default: never stretched; 0: rate.lua's 12). After, with
  (1), (2) and 6 ticks: 96.3% / 1.7% and 96.3% / 1.7% at -62,-26 (before, the UDP round at 12 ticks: 96.1% / 2.6%
  and 96.2% / 2.3%), UPS 48.5 and 46.5 while scored (46.5 and 47.3), the bridge 10.0-11.6 ms a tick; 97.6% / 0.8%
  at -272,-14 (97.3-97.5% / 0.8-1.0%; level 2 there, 6-tick updates either way). Still FAIL at -62,-26 on visible.

### The belt gap at -62,-26 (the belt-accuracy round)

What the 3.7% of unseen game items (and the 1.7% phantoms) at -62,-26 were, from the belt-rate round's recorded
runs re-scored offline with every game item-tick and drawn record tagged (the same matching as section L):

- 1.99% of the game's item-ticks lie on recorded lanes past the screenshots' bounds: record.py records every belt
  whose collision box touches the recorded ground, so lanes along the edge reach up to a tile past it; the scorer
  counts their items but drops every drawn record outside the bounds before matching. 99.8% of them have a record
  of the right item within 0.15 tile at the game's place, outside the shot. A scoring artifact (the gate is the
  owner's): visible as gated 96.3%, inside the bounds 98.2%, counting those drawn right outside the shot 98.3%.
- 1.73% missed inside the bounds: 1.41% on lattice lanes (splitter lanes 0.73%: one item in ten there; straight
  0.30%, undergrounds 0.19%, curves 0.12%; a drawn slot within 0.15 tile but taken by another game item 1.03%,
  the nearest slot 0.15-0.3 tile off 0.37%), 0.33% on the lanes the simulation draws itself (one in seven of their
  items). Phantoms: lattice slots with no game item 1.39% of the drawn, the simulation's own records 0.35%
  (items taken meanwhile, items on another lane). Flat over the 20 recorded ticks, and mostly on lanes read long
  ago: the lattice's phase, not corrections.
- The phase (see `--belt-draw-lattice-world`, `--belt-draw-lattice-standing` above): with the game's own phase
  on every lattice lane the same dump scores 97.5% / 99.5% inside / 0.48% phantoms (the ceiling of phase fixes);
  the rest is the simulation's lanes that aren't full.

Measured with the two switches on, the same captures replayed offline (tests/belt_bs_replay.gd --every-tick with
`--belt-draw-dump`, scored as section L; scratch replay_score.py): -62,-26 96.42% visible / 98.34% inside / 1.68%
phantoms -> 97.11% / 99.08% / 0.99% (world all alone 96.78 / 1.22, standing obs alone 96.71 / 1.40); -272,-14
97.59% / 99.22% / 0.80% -> 98.10% / 99.75% / 0.37%. Live (Hold 60 UPS, `--record 60`, by day, 6-tick `bs`):
-62,-26 96.3% / 1.7% (the rate round's two 6-tick runs) -> 96.9% / 1.5%, 97.0% / 1.3%, 96.9% / 1.3% (three runs; inside
the bounds 98.2% -> 98.8-98.9%; the game at 46-49 UPS while scored, rate level 2-3; still FAIL on visible as gated: the gap left is the
2.0% past the bounds); -272,-14 97.6% / 0.8% -> 97.7% / 0.4% (inside 99.2% -> 99.7%), PASS. Run folders under
E:\Zenith-scratch\acc.

Found on the way: since de96093f every headless test preloading belt_items.gd (tests/belt_bs_replay.gd, so
belt_view_check's own replay, section 0) ran with belt_items.gd's statics unset (moment_hold.gd named the Bridge
autoload, a compile error outside the scene): the "replay diagnostic" of 74-76% at -62,-26 was that, not the
simulation (fixed: the autoload looked up by path). And on Godot 4.7 `hash(int)` changed, so every item's turn
drawn by the C++ paths differed from the GDScript paths' (tools/belt_draw_diff.py showed millions of differences
in the turn alone); `hash_int` follows 4.7's hash_one_uint64 now.

### Watching with the normal game

The server also accepts regular Factorio clients on `127.0.0.1:34197` (Multiplayer → Connect to
address; a server the menu started uses the free game port it picked, 34501 or so, or the port
you host on). You get your own character next to the 3D client's, with all the normal GUIs.

**Ctrl+F9** (Show in Factorio) in the client brings Factorio's window to the front, or starts
Factorio joined to the server the client started. While you play there, the bridge drives your
player's character, so both windows show the same one. On a world made in Zenith you join as the
character Zenith was playing (L13, "A world made in Zenith, joined from Factorio" above). The mod adds the same key in Factorio
("Show in Zenith"), which brings the client back and minimises Factorio (Settings → Other →
Minimise Factorio in Zenith turns that off). Checked with a real Factorio 2.1.24 window in
single-player: a minimised Factorio keeps running the game at 60 UPS.

**Modded saves from the menu.** Opening a save from Zenith's menu starts its server with the save's
mods and those turned on in Zenith's Mods window, as Factorio adds the mods turned on to a save it
loads: every mod in your Factorio mods folder (beside Factorio's saves) is linked into the server's mods
folder (hard links for zips, junctions for folders), the mod list starts from everything off,
`factorio --sync-mods <save>` turns on the save's mods at its versions (and its startup settings into
mod-settings.dat: checked in 2.1.24), then the Mods window's mods the save hasn't are turned on at the
folder's highest version, with the mods they need and recommend (2.1's `+`), and the bridge is turned
on again. Load game's **Sync mods with save** (Factorio's words) leaves the Mods window's out: exactly
the save's mods. A Mods-window mod that would stop the server is left out and named in the game (one
that clashes with a mod running, `!` either way, as Space Exploration with Space Age; one needing a mod
the folder hasn't); Space Age and its DLC follow the save, the Mods window's choice of them is for new
games. A mod the save needs that isn't in your folder stops the start with Factorio's list of what is
missing. The Mods window's choices are kept in `<server data>/zenith-mods.json`, apart from
`mods/mod-list.json`, which the launcher writes before each start (a new game: the choices with what
they need, every other mod in the folder off). Before, each load rewrote mod-list.json to the save's
mods, so mods turned on in the Mods window were dropped at the next load (a save made without them
never got them); `--load-mods=save` brings that back for loads (exactly the save's mods every time; new
games still take the Mods window's). A server folder from before takes as the player's only the mods
turned on in mod-list.json without a version (ticked since the last load: `--sync-mods` gives every mod
it turns on its version).

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

A client that quits without saying goodbye (a crash, killed from the Task Manager) is kept for the
bridge's 10 s timeout. If its Zenith starts again meanwhile, from another port (the old one not
free yet, or another client on it), the bridge takes it for the same client and gives it back its
character where it stood, instead of a new one at the spawn: a hello from a new port takes the place
of a client not heard from for 4 s or more (a live Zenith says hello every second). One heard
within the last 1.5 s is alive, and the new port is a second client beside it; in between, the new
hello waits a second for the next. A Zenith frozen for over 4 s while another joins loses its place
to it and gets a character of its own when it answers again.

## Server on another PC

Factorio's Lua UDP (`--enable-lua-udp`) listens only on 127.0.0.1, so the bridge mod can only talk to
a Zenith on the server's own PC (GitHub issue #20). To keep the game's CPU off the PC you play on, run
the headless server on another PC with a small relay beside it, `server/relay.py`: Zenith connects to
the relay over the network, and the relay talks to the bridge on 127.0.0.1 as an ordinary local client.
It is plain Python 3 (3.8 or newer, standard library only), so it runs wherever the server runs: Linux,
Windows, macOS.

1. **On the server PC**, start the headless server as usual: `server/run-headless.sh [save.zip]` on
   Linux, `powershell -ExecutionPolicy Bypass -File server\run-server.ps1 [-Save x]` on Windows. The
   bridge listens on UDP 127.0.0.1:34200, which nothing else can reach.
2. **On the same PC**, start the relay (in a second terminal, or `&`/`nohup` on Linux):
   ```
   python3 server/relay.py                      # TCP 34200 on every interface, local-network addresses only
   python3 server/relay.py --rcon-port 34198    # also lets Zenith pause the game (RCON, below)
   ```
   It prints the address to type into Zenith ("in Zenith: Play > Connect to address > 192.168.1.20:34200")
   and logs every Zenith that connects, comes back or leaves, and anything it refuses.
3. **Open TCP port 34200** in the server PC's firewall, for your network only. Windows (as administrator):
   `New-NetFirewallRule -DisplayName "Zenith relay" -Direction Inbound -Protocol TCP -LocalPort 34200 -RemoteAddress LocalSubnet -Action Allow`.
   Linux with ufw: `sudo ufw allow from 192.168.1.0/24 to any port 34200 proto tcp`. Never forward the
   port from your router to the internet (see "Who may connect").
4. **In Zenith** on your PC: Play > Connect to address > `192.168.1.20:34200` (the server PC's address;
   a name like `server.local` works too, and the port can be left out when it is 34200). Or start
   Zenith with `-- --factorio-host=192.168.1.20` (and `--factorio-port=` for another relay port). An
   address other than this PC always goes through a relay; `--relay` makes Zenith use one even at
   127.0.0.1, for trying it on one PC.

`python3 tools/relay_check.py --relay 192.168.1.20:34200 --reconnect` from your PC checks the whole way
without Zenith: the handshake, the chunks round the character, a dropped connection coming back.

**How it works.** For each Zenith the relay opens a UDP socket of its own on 127.0.0.1 and passes every
datagram between it and the bridge unchanged, both ways: the bridge tells clients apart by the port a
hello came from, so each Zenith is a client of its own (up to 8, each with its own character, as in
"Several 3D clients on one server"). Over the network each datagram travels as a frame on a TCP
connection (docs/PROTOCOL.md, "Over the network"). A Zenith whose connection drops (Wi-Fi, a cable, the
relay's `--timeout`) connects again within a quarter of a second, and the relay gives its session (the
hello's `sid`) its old port back, so the bridge sees nothing change; the datagrams lost meanwhile are
asked for again like any other gap. A Zenith that is gone for good is dropped by the bridge after its
10 s timeout as usual, and its port is let go after `--keep` (30 s). A restarted relay knows no ports:
Zenith comes back from a new one, and the bridge gives it its character back once the old port has
been silent 4 s (a new handshake, the world sent again).

**Why TCP, not UDP.** The bridge fills its datagrams up to 60 KB, because each `send_udp` costs the game
about a millisecond whatever its size. Across a network a 60 KB datagram travels as about 40 IP
fragments, and losing any one of them loses the whole datagram: a chunk snapshot, a tick's belts. Wi-Fi
loses fragments often, and the receiving PC's socket buffer overflows on a tick's burst. The protocol
would heal each loss (a gap, a resync), but only by sending the chunks again, so a lossy link would keep
resending the world. Asking for smaller datagrams instead would cost the server a millisecond more per
datagram. TCP resends only the lost segment, paces the stream to what the link takes and never
fragments; on a local network its delay is well under a frame. When Zenith falls behind (a slow link, a
long load), the relay holds up to `--max-buffer` (8 MB) for it and then drops whole datagrams, which
the protocol treats as lost, as it would over UDP. Commands go the other way on the same connection.

**Who may connect.** By default only local-network addresses: 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16,
169.254.0.0/16, this PC, and IPv6's private and link-local ranges. `--allow` replaces that with your own
list (`--allow 192.168.1.0/24 --allow 10.8.0.5`, or comma separated; `lan` for the default ranges, so a
VPN can be added: `--allow lan --allow 100.64.0.0/10` for Tailscale). The relay has no password: a
Zenith through it counts as one on the server's own PC, so it plays on your server and may use console
commands (`/cheat`, the bridge's `/f3d-*`) without being an admin (Lua itself never runs from a packet).
Allow only PCs you trust, and never `--allow any` on a PC the internet can reach.

**What works differently with the server elsewhere:**

- **The menu's own server** (Single player, Host) runs on this PC as before; a server on another PC is
  started there, as above.
- **Ctrl+F9** (Show in Factorio) brings forward a Factorio window on this PC, if you joined the server
  with one (Multiplayer > Connect to address, the server's game port, 34197); it can't start one for you
  and says so. The server's launcher (`server/factorio-with-zenith.ps1`, "Show in Zenith" with no Zenith
  connected) only starts a Zenith on the server's PC.
- **RCON** (pausing from the debug menu, a screenshot's pause): start the relay with `--rcon-port 34198`
  (the scripts' RCON port, still bound to 127.0.0.1 there) and give the RCON password in Connect to
  address (the server's `server/data/rcon-password.txt`; Zenith doesn't save it). Zenith then opens RCON
  through the relay, on the same TCP port. Without it Zenith says pausing needs RCON. Saving and loading
  from Zenith's Esc menu stay for the menu's own server.
- **Give the server the CPU first** (Settings > Graphics) does nothing: the server takes nothing from
  this PC's cores.
- **Factorio's own graphics and sounds** come from the Factorio install on Zenith's PC, as always, so
  that PC needs Factorio (the same version as the server).
- **Other mods' graphics** are read from this PC's copies of the mods: Factorio's own mods folder
  (`%APPDATA%\Factorio\mods`, `~/.factorio/mods`), or a copy of the server's mods folder named with
  `--factorio-mods=<folder>`. When the server runs mods this PC doesn't have, Zenith says which once a
  game (and its log lists the folders it looked in); what they add is drawn without their graphics.
- **The relay on Linux** asks for an 8 MB UDP receive buffer; when the OS gives less than 1 MB it says
  so (a busy base's burst could overflow it): `sudo sysctl -w net.core.rmem_max=8388608` raises the cap.

The relay's options: `--port` (TCP for Zenith, 34200), `--host` (the address to listen on; `::` for IPv6
too), `--bridge-port` (the server's `--enable-lua-udp` port, 34200), `--allow`, `--rcon-port` (0: off),
`--max-clients` (8), `--timeout` (30 s of silence closes a connection; Zenith says hello every second),
`--keep` (30 s), `--max-buffer` (8 MB), `--log FILE`, `-v` (also each connection as it opens and each port as it is let go).

Checked on one PC only: the relay's own test (`tools/test_relay.py`), the mock behind the relay losing
5% of its packets, Zenith headless through the relay to the mock and to real headless Factorio 2.1.24
(the world loaded, the link dropped and made again, the relay restarted), and RCON through the relay.
Two real PCs, Wi-Fi and the bandwidth a busy base needs haven't been tried yet.

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

These are Zenith's built-in defaults: Factorio 2.0's, with Map on Tab (or M), Next weapon on C and Shoot
selected on Shift+Space as Wube's changelog has them since 2.0. With Factorio's `config.ini` found, Factorio's own keys replace them: the
ones you changed in Factorio's Settings → Controls, and Factorio's defaults for the rest (the `; ` lines
Factorio writes there, right for your Factorio version and keyboard layout), so both answer the same
keys (Settings → Controls → "Use the keys set in Factorio"; a binding changed in Zenith's Settings still
wins). Mouse bindings set in Factorio aren't used. Keys are matched with exactly their modifiers, so
Shift+Space doesn't also shoot at enemies, Ctrl+Keypad + doesn't grow the tile area, Ctrl+Shift+Z
doesn't undo and Ctrl+F (search) and Alt+F (the personal roboport) don't pick up (`--pickup-exact=off`: F
picks up with any modifier held too, as before; F pressed under Ctrl or Alt starts picking only when pressed
again after they are let go); G, Factorio 2.1's key for both the rail layer and getting in (its alternative), changes the
rail layer with rails in hand and gets in otherwise.
Following Factorio 2.1 takes away keys Zenith 0.2.2 had beyond Factorio's: 2.1's default lines leave the
arrow keys, the console's alternative and Keypad Enter unbound (and give getting in G as its alternative), so
the arrows don't walk or pan the map and `/` doesn't open the console. Settings → Controls → "Zenith 0.2.2's
keys" (saved; `--keys-defaults=old` turns it on for one run) brings back exactly 0.2.2's keys: the built-in
defaults Map on M, Next weapon on Tab and Shoot selected on C (1.1's), and of `config.ini` only the controls
you changed in Factorio, not its `; ` default lines, so the arrows walk and pan the map, `/` opens the console
and Keypad Enter gets in again. "Copy keys from Factorio" follows it, and its message says which it used.
Zenith finds `config.ini` where the install's `config-path.cfg` says (`%APPDATA%\Factorio\config` for
Steam and the installer, the install's own `config` folder for the zip, or a folder of your own), and
reads it at start, when its window comes back from another (a key changed in Factorio meanwhile is
followed; `--factorio-keys-refresh=off`: at start only) and when the switch is turned. Coming back
looks only at the file's modified time (in the few seconds after config.ini was written it also compares
the text's length and hash, as a write in the same second leaves the time as it was); Zenith looks for the install again when Settings → Factorio
install or `--factorio=` changed, or (with none found) at most once a minute. Rebinding one
slot in Zenith leaves the other following Factorio's (saved as `default`). **Copy keys from Factorio**
(Settings → Controls, issue #26) looks for the install afresh, drops the bindings changed in Zenith for
every control Factorio has (each then follows Factorio's changed key, else Factorio's default),
switches "Use the keys set in Factorio" on and shows what was copied, what wasn't and why (mouse
buttons and the wheel, controller bindings, controls Zenith has no key for) and the file it read,
keys named as Factorio names them ("`", "Page Up", "Numpad +"). Zenith's own controls (camera, views)
keep theirs; the message lists any copied key one of them also has (camera tilt's Page Up and Page
Down, and in dev builds the debug line's F4 and the debug menu's Control + F12), as both then act.

| Input | Action |
|---|---|
| WASD (or a gamepad's left stick; the arrows too with "Zenith 0.2.2's keys" on or Factorio's keys off) | Walk, relative to the camera, at any angle (the bridge steers Factorio's 8-way character to follow it). The stick walks only on a gamepad Godot recognises, once it has been seen centred: pedals, wheels and throttles are left alone |
| Right mouse (hold) | Mine what's under the cursor; a train, wagon, car, tank or spidertron under it first (issue #10: not the rail beneath), with what is inside it; an item lying on the ground (over ore, under belts and buildings) is picked up at once. While it mines the character stands, as in Factorio: walking goes on once mining stops. What is mined follows the cursor as Factorio's selection does (J26): a new target starts again from nothing, the cursor off it keeps its progress, and with the button held a walk goes on over nothing and stops on the next thing under the cursor, so walking along a line of belts with the cursor on it mines every belt in turn. Out of reach it says "Out of reach" and doesn't swing, no sound or sparks, as Factorio (issue #24; `--mine-reach-check=off`: the swing played anyway, as before) |
| Enter (or G; Keypad Enter instead of G with "Zenith 0.2.2's keys" on or Factorio's keys off) | Get into the nearest vehicle (car, tank, train, spidertron) or out of it |
| Spidertron remote (shortcut bar) | Drag: select spidertrons · Shift+drag: add · right-drag: remove · click: send them there · Shift+click: queue a waypoint |
| WASD in a vehicle | W accelerate, S reverse, A/D steer (relative to the vehicle) |
| F (hold) | Pick up items next to the character, lying on the ground or on belts (as Factorio's "Pick up items": everything within the character's item pickup distance, the nearest first), each flying to the character with its sound; not with Ctrl or Alt held, Ctrl+F and Alt+F being search and the personal roboport, as in Factorio |
| Space (hold) | Shoot at enemies near the character (the game picks the target) |
| Shift+Space (hold) | Shoot at the cursor (C with "Zenith 0.2.2's keys") |
| C | Switch to the next gun (or click a gun in the weapon slots left of the quickbar; Tab with "Zenith 0.2.2's keys") |
| E | Open the character window (the inventory on the left; on the right Factorio's Crafting and Logistics tabs, Logistics once the character's logistics are researched), whatever is under the mouse. With any window open, E closes it. The main inventory sorts itself as Factorio's does: whenever it changes while no window shows it, and when the window closes (not while the hand holds one of its stacks) |
| Esc | Close the open window, machine screen, map view, chooser or remote view; with none open, the Game menu (Resume, Load game, Save game, Save as, Settings, Exit; Players when others play too). With the mouse resting on something whose tooltip shows (a button, an item's slot), Esc still does this at once: Godot spends an Esc on hiding its tooltip, so Zenith sends the key again (`--esc-tooltip=old`: the first Esc only hides the tooltip, as before) |
| T | The technology screen: the research in progress and queue, the selected technology (cost, time, prerequisites) with Start research / Add to queue / Cancel, and the tree on the right. It opens on the research in progress; with none, on the technology looked at last while it is still to be researched, else the first available one, the list of technologies at its top (L9; `--research-open=last` opens on the one looked at last even when researched, as before); the tree scrolled to it. A Factoriopedia link opens it on its technology. Start research / Add to queue on a technology whose prerequisites aren't researched queues the missing ones first, in order, then it, as Factorio's screen does (L12, its tooltip names them); it is greyed when one of them is unlocked by doing its task (Factorio queues no trigger technology) or the queue's seven can't hold them all (`--research-chain=off` greys it whenever a prerequisite isn't researched, as before). Such a technology, one Start research can queue, is orange in the list, the tree, the details and the queue (Factorio's conditionally available slot; red stays for one a trigger technology is on the way to, and with `--research-chain=off` nothing is orange); `--research-orange=factorio` draws only Factorio's own orange ones, whose prerequisites are all researched or queued. A recipe among the Effects has Factorio's recipe tooltip (its ingredients, crafting time, products and Total raw, then the item's lines; nothing red), as do the Unlocks recipes on a technology's Factoriopedia page (M3; `--research-effect-tips=old`: the name and "Unlocked by this technology", as before). The screen covers the HUD, Zenith's Show in Factorio button with it, as Factorio's covers its mod buttons (M4: the gear sat on "Research queue"; every window now draws over the button, `--mod-button=over` keeps it on top as before). T, E, Esc or × closes it. A lab's window follows the research too: its box names the research in progress with its share, and after one finished with none started since says Factorio's "<name> finished. Press T." with that technology's icon and a full bar (`--lab-finished=old`: "No research in progress. Press T." as before) |
| Tab or M (M only with "Zenith 0.2.2's keys") | The map view: the charted map over the whole window (north up) with your character's arrow, the map tags and trains. Drag (left or middle mouse) or the movement keys (WASD, the arrows with "Zenith 0.2.2's keys" on or Factorio's keys off, or as rebound) move it (Shift: faster), the wheel zooms about the mouse. Right click: on a tag, edit or delete it; on a ghost, remove it; elsewhere, create a tag there (icon, name, Confirm). Double click also creates or edits a tag. Tab, M or Esc closes it (Esc closes the tag dialog first). The game keeps running underneath, and the character doesn't walk while it is open |
| Minimap (top right) | The charted map around the character (in the map view or remote view, around what that looks at), north up, with tags and trains. Click it to open the map; the wheel or its + / − buttons zoom it |
| Click a stack (inventory or machine) | Pick it up into the cursor, as in Factorio (right click: half). The cursor shows its icon and count; its slot shows Factorio's hand. Over the world, where the held building's ghost shows, the count alone is drawn by the pointer, as Factorio does (L7; `--cursor-count=old`: none there), counting down at once as you build (the builds sent and not yet gone from the inventory shown are taken off). The quickbar's count and the inventory's slots count those builds out at once too, and get them back if the game refuses one (L2; `--slot-counts=report`: they wait for the bridge's inventory report, up to half a second, as before) |
| With a stack in the cursor, click a slot | Put it there (a different item swaps, so the other stack is now in the cursor); right click drops one; click its own slot, or Q, to put it back. Left mouse in the world builds it (only stacks from the inventory) |
| Shift+click a stack | Move it between the inventory and the open machine (Ctrl+click: all of that item) |
| Click a recipe | Hand-craft one (right click: five, Shift: as many as possible). Hover for ingredients (red, as have/need, only where neither held nor hand-craftable from what is held), time, products and Total raw (red where fewer are held). An assembler's recipe chooser has the same tooltip, nothing red |
| Crafting queue (bottom left) | Each queued craft with its count; the first fills with Factorio's orange pie. Click cancels one, right click five, Shift+click the whole entry. Longer than its row, it ends in "+N": hover it for the rest (opening upwards), click it to keep them open and cancel crafts there |
| 1 – 0 | Hold the item pinned to that quickbar slot (again: put it away): one stack of it from the inventory, the biggest, its slot marked with Factorio's hand and the cursor counting that stack, as Factorio's cursor holds one stack; building, Z, tiles and capsules use that stack up (the client names its slot, `hs`), then the next stack of the item comes into the hand (of the same quality first), Q puts it back, a click on a slot puts it down (L7; `--hand-stack=all`: the item with no stack in particular and all of it counted at the cursor, as before). With none in the inventory, a ghost cursor of what it builds. With the character window open: pin the hovered item, or the held one, to that slot |
| Click a quickbar slot | Hold its item; with an item held, pin that item there. Right click clears the slot. Inventory items can also be dragged onto it |
| Left mouse (hold and drag) | Build the held item along the way, as Factorio drags: belts go along the held belt's line, each facing the held way, forward with it and backwards against it (J25: a line can be built from its end), nothing off the line or going back over it; R while dragging turns the line at its last belt towards the cursor and builds out to it (with Smart belt building, Settings → Interface, an obstacle or a crossing belt is jumped with undergrounds, the entrance upstream either way; with Lock belt building to straight line off, belts follow the cursor round corners instead); pipes go in a line (pipes-to-ground over obstacles), walls follow the cursor's path round corners and in any shape, a diagonal filled as a joined staircase (N5; the line lock is the belts' alone, as in Factorio; `--wall-drag=line`: along one line, as before), poles at their wire reach, anything else one footprint after another; a faster belt dragged over a line replaces it. Its ghost is green where it can go (a splitter or underground over belts, a pipe-to-ground over pipes replaces them), red where it can't (none left, beyond the 10-tile build reach, something in the way). None left counts the builds just sent that haven't left the inventory shown yet (the bridge reports the inventory up to half a second after a build), so a drag stops, and shows nothing, past what the hand holds, as Factorio places nothing then (L2; `--build-spend=off`: the inventory shown alone, as before, when a fast drag went on past it and the game took the extra buildings away again). What a build spends is judged by the bridge's own reach (the build distance plus 1.5 tiles, to the building's middle): a small building up to a tile past the cursor's reach has a red ghost and is still built, and counts (`--build-spend-reach=cursor`: by the cursor's reach, as before, when a drag begun there sent one or two too many). Holding an electric pole tints the supply areas of the poles round the cursor and its own in Factorio's blue; hovering a pole shows its own. Holding an underground belt or pipe-to-ground shows Factorio's underground connection to the piece it would join (yellow on the tiles between) and, green, the furthest its exit may go; past that the connection turns red, too far to connect; with nothing to join, the furthest tile its exit could go (J24). Over a plain run of belts (pipes) the tiles between show Factorio's underground_remove_belts instead, red-orange corner brackets and the yellow arrow (pipes without it): building it mines them (the bridge's `under_clear`), and Zenith hides them as the build is sent, back if the game keeps them (M2; `--underground-clear=off`: neither, as before; `--underground-clear-sent=off`: a drag's pair hides its run only when the game answers). Over a window the mouse only works the window: nothing behind it is hovered, built or mined. Where a click lands (J9): the cursor's point is sent rounded down to 1/256 tile, so the bridge snaps it to the grid exactly where the preview stood (Factorio's rule: an odd size on the tile's middle, an even one, a splitter across, on the nearest tile edge; real 2.1.24's own create_entity snaps the same in every direction). Cut towards zero, as before (`--build-wire=truncate`), a point less than 1/256 tile under a tile's edge or middle at negative coordinates was built one tile over; the tile brush's point too |
| Holding a blueprint, left click | Place its ghosts there (shown under the mouse first; robots build them; building the item over its ghost fills it in yourself). Ctrl+Shift+click: super-forced (trees and rocks in the way are marked). A book places its active page; Shift+mouse wheel picks the page |
| Holding a deconstruction or upgrade planner, left drag | Mark the area (Shift: cancel the marks). What it will take is highlighted in its colour while dragging |
| B | Blueprint library: My blueprints (kept by the client in `user://blueprint-library.json`), the save's Game blueprints and, when the bridge plays the save's own player, that player's library. Click takes one into the cursor, right click opens it (books open in place), drag moves it or drops it into a book, Del deletes; Import string takes a string copied from Factorio or a website; New book / planner buttons |
| Right click a blueprint, book or planner in the inventory | Its window: label, icons, description; a blueprint's components (click one to take it out), what it includes, snap to grid and absolute snapping; a book's pages; a deconstruction planner's filters, whitelist / blacklist, trees and rocks only, tile mode; an upgrade planner's from → to rows. Save writes it back; Export string copies Factorio's string |
| Ctrl+mouse wheel | The held item's quality (the qualities your force has) |
| Ctrl+Shift+left | Super-forced build: a ghost, and what stands in the way is marked for deconstruction |
| Holding tiles (stone brick, concrete, landfill, foundation...) | The brush shows at the cursor (green, red where the tile can't go, blue as ghosts with Shift). Left mouse paints, right mouse mines placed tiles back; Numpad + / - change the tile area; R turns hazard concrete |
| Holding rails | Click a rail end, or anywhere along a line to fork a new one off it, to start the rail planner there: the path of straight and curved rails to the cursor shows, click (or drag from the end) builds it and carries on from its end; ghosts where your rails run out. Alt+R (while holding rails; otherwise it gives red wire): rail layer (a ramp up, elevated rails with supports). Right click lets go |
| Holding grenades, cliff explosives, capsules | The throw range and blast show; left click throws at the cursor (hold to keep throwing). Fish heal you |
| R / Shift+R | Rotate the held item (rails by 45°), or the hovered entity: an underground belt turns with its other end, both swapping entrance and exit, as Factorio turns a pair (J23). While dragging belts it bends the line (see Left mouse). Building the same belt over a belt turns it; a faster belt (or anything that fast-replaces) replaces it |
| Left mouse with nothing held | Open the hovered building's screen (chests, assemblers, furnaces, labs, drills, boilers...) beside your inventory: its name, status (Working, No ingredients, No fuel, No power...), energy, slots and fluid boxes. E, Esc or its × closes it |
| Recipe slot in an assembler's screen | Click to pick its recipe from the grid below; right click clears it. Items it was holding come back to you |
| Q | Put the held item (the cursor stack) away; with nothing held over an entity, a train, wagon or vehicle, the pipette: hold its item, turned the same way (a ghost cursor when you have none) |
| Z (hold) | Drop one of the held item: into the machine or chest under the mouse, onto a belt, or on the ground |
| Shift+left click | Holding an item: build a ghost of it for robots. Holding nothing: paste the settings copied with Shift+right click (recipe, filters, requests, combinator settings) |
| Ctrl+left / Ctrl+right click an entity | Fast transfer: the held stack (half) into it, or with nothing held its output (half) into your inventory. When the held stack empties, the next stack of the item comes into the hand |
| H / V | Flip the item being built, or the entity under the mouse (machines with fluid boxes) |
| Alt | Alt-mode: recipe and filter icons over every machine in view (they come with the buildings, issue #9; an idle furnace keeps its last recipe's, J2), over each chest the kinds it holds most of, up to four (the bridge reads the chests round the focus about once a second while Alt-mode is on, J6), over machines the modules in them, over labs their science packs, over ammo turrets their ammo and over locomotives their fuel, in rows where Factorio puts them (its prototypes' icons_positioning; a beacon's only with the mouse on it; read in the same rounds, K1, K2; `--alt-ammo-fuel=off`: no ammo or fuel, as before), each machine's own icon shifted and scaled by its icon_draw_specification (`--alt-icon-spec=off`: centred at one size, as before), where icons overlap the one nearest the camera drawn in front (a north-south line of assemblers' recipes in the angled view, a lab's lower row of packs over its upper, a turret's ammo over the lab behind it; in the angled view, F6 and first person; `--alt-icon-order=old`: in the order found, a farther icon over a nearer one as before), Factorio's fluid arrows on machines and pumps and a recycler's output arrow, inserters' arrows when chosen in Settings → Interface (kept between games); it toggles when Alt is let go, unless Alt was held for an Alt+click |
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
| ` (or / with "Zenith 0.2.2's keys" on or Factorio's keys off) | Chat (a line starting with / is a console command, run over RCON when this client started the server) |
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
| F6 | Jump to Factorio's own view (north up, from above at Factorio's angle and default zoom); again to go back. Zooming, turning or tilting out of it gives the normal view its own projection back (Settings > Camera), and F6 snaps to Factorio's view again (L1; `--f6-leave=old`: it stayed orthographic) |
| F5 | First person: see through the character's eyes, mouse looks, aim with the crosshair; F5 again to go back. The mouse is freed while a window is open. The crosshair acts on what it is on (K7): the nearest entity its line of sight meets (each Factorio selection box raised to its model's height, standing on the hills), within 64 tiles, before the ground; only with nothing in the way does the ground under it decide. Hovering, mining, opening, rotating, Ctrl+click, Z and the wire tools take that entity; a held building goes just out from the side looked at (on a top, where the crosshair is). The bridge still refuses what is out of reach. `--fp-pick=ground` picks from the ground point as before |
| F7 | Perspective or orthographic for the view in use, switching what is on screen: in first person first person's, in the map's remote view the map's projection, elsewhere the normal view's (in Factorio's view, F6, the view goes perspective where it stands, out of Factorio's view, and F6 snaps back to it; L1); kept in Settings > Camera. `--f6-leave=old`: in Factorio's view it changed only the normal view's setting, used on leaving it |
| F1 | Show or hide the help panel (off by default): every control under the key bound to it now (rebound in Settings → Controls, or Factorio's own keys), grouped (moving and camera, fighting, building, blueprints and wires, inventory, windows, the map, Zenith's own), then each add-on's while it is on; the debug menu only in dev builds. When the window is too short for it, the mouse wheel over it scrolls it |
| F4 (dev builds) | Show or hide the debug line (tick, chunks, entities, packets, the game's UPS, FPS). Public builds give it no key by default (issue #26: many players have F4 on a Factorio control, Factoriopedia's alternative or their own); it stays in Settings → Controls (Miscellaneous, Debug line) to bind, and a key bound there is kept in either build |
| Alt+L / Alt+F / Alt+E | Personal logistic requests, the personal roboport, exoskeletons on or off (also on the shortcut bar) |
| Ctrl+= / Ctrl+- / Ctrl+0 | UI scale up, down, back to automatic |
| Ctrl+F12 | The debug menu (dev builds only, see "The debug menu" below) |
| Add-ons' keys | Each add-on's own, listed under it in Settings → Controls and in F1's help while it is on. The bundled Cinematic camera: F8 free camera, Shift+F8 its window, Ctrl+F8 idle mode, Alt+F8 camera mode, Ctrl+Shift+F8 record, F11 hide the interface, F12 screenshot; while its camera flies, WASD, E/Space and Q/Ctrl, = and -, O orbit, T follow, N next, V placement, K add a path point, P play the path, B letterbox |

Client command-line options go after `--` (Godot: Project → Project Settings → Run, or the
command line): `--factorio-port=34200 --port=34201 --models=/path/to/glb/folder
--factorio-data=/path/to/Factorio/data`.

**Model packs** (client/scripts/world/model_packs.gd): every model comes from a pack, each a set of
models found by file name (`<prototype-name>.glb` or `.gltf`). Three are built in
(`client/assets/models/packs/`: FUE5, Wube3DP and Placeholders, 481 models in all); the
`models` folder beside Zenith (the checkout's root, or beside Zenith.exe) holds any number more: the
files at its top ("Loose models"), each folder in it (models anywhere inside) and each `.zip` in it,
read as it is (a download's `models/Zenith.zip`, Vasillo's models, is one). A zip is unpacked once
into `user://model-packs/<zip name>-<size>-<modified>/` on a worker thread at start-up
(ModelLibrary's `ready()` says no until it is in, the join's loading screen counts it), again only
when the zip changes; copies of zips changed or gone are removed at the next start. **Copies of
Factorio's files** (`client/scripts/world/pack_check.gd`, the owner's rule): a pack holding any file
over 1 KB that is a byte-for-byte copy of one in the install's `data/` folder isn't loaded at all, its
card red in the Model packs window ("Show the files" lists them), one warning line in the log. Every
pack is checked but the Factorio pack and Wube3DP; there is no switch to turn it off. A pack's file is
compared first with the install's file at the same Factorio path (`sounds/<mod>/...`, `icons/...`, a
`<mod>/` or `__mod__/` folder in its path), then with the install's files of the same size, by SHA-256.
The install's sizes are listed once, on the model packs' worker, into `user://pack-check/install.json`
(again when base's version, `base/info.json`'s modified time or the data folder's changes; it keeps the
hashes it took). Each pack's answer is kept in `user://pack-check/packs.json` by its id, its stamp (a
zip's size and modified time; a folder's file paths and modified times; a built-in pack's file paths and
Zenith's version) and the install's, so an unchanged pack takes its answer at start-up (about 3 ms for
the built-in packs) and a new or changed one waits, not in use and its card saying "Checking for copies
of Factorio's files…", until the worker has checked it (a first run against a full Space Age install:
about 1.3 s on the worker, FUE5 and Placeholders included). Without an install nothing is compared: the
packs load at once, the window's details saying so. Delete `user://pack-check/` to check every pack
again (a built-in pack's model edited in place in a checkout keeps its answer until then). One order decides,
the higher pack winning where two have a model of one name (settings.cfg `[model_packs]` `order` and
`off`, by id: `builtin:<folder>`, `loose`, `dir:<folder>`, `zip:<file>`): a new pack of the models
folder goes on top, on; a built-in one not saved yet goes under the folder's, so by default, from the
top (the owner's order), Default (when there is one), FUE5, Wube3DP, Placeholders. Placeholders is
always last and always on. With that order the seven models FUE5 and Wube3DP both have
(electric-mining-drill, iron-chest, small-electric-pole, steel-chest, steel-furnace, stone-furnace,
wooden-chest) are FUE5's, as all 39 were before the packs; Wube3DP's stay in their pack.
`choices` (family -> pack id) takes a model family (a prototype's model with its direction, curve, piece, shape, richness and pose variants; ModelPacks.family)
from that pack whatever the order: each variant it has, a tier it has only the base of as the base
recoloured, the variants it lacks from the order. The Model packs window
(client/scripts/menu/model_packs_window.gd: the main menu and the Esc menu; not in Settings) sets all three and applies them at
once (ModelLibrary `apply_packs`, `apply_choices`; world.gd `models_changed` builds the chunks drawing
those models again); trains, robots, creatures and inserter arms keep theirs until a restart. A
building window's Model button (model_chooser.gd) draws that one building from a pack of its own,
kept per save and unit number in `user://building_models.cfg` (building_models.gd, forgotten on the
building's `del`), or sets its family's choice; client only, no protocol change. The hover panel (entity
info) shows the pack drawing the building as a small picture at the right of its title bar (N8: the
pack's own picture as its row in the window has it; nothing for an entity no pack nor Factorio's card
draws), its tooltip "Model: <pack>" and its credit; a click opens the Model packs window on that pack
with the building's family shown. The panel holds its building while the mouse is on it, or for up to
0.6 s while the mouse heads straight for it from the building, so the picture can be reached.
`--entity-info-pack=off`: no picture, the panel follows the mouse as before. A zip that isn't one,
or one whose entries can't be read (a damaged file, or another compression than deflate), is left out
with a warning in the log. The start-up log says
`[models] N model(s) from M packs, the higher winning: <pack> (<where>, <count>), ...`, then the packs
off or being unpacked and the models a higher pack covers; the dev build's debug menu (Tests > Model
packs) lists each model's pack. `--models=<dir>` adds one more pack (a folder, searched the same way)
on top for that run, which only fills in entities no other pack has a model for; `--models-first`
lets it win over every pack. `--no-custom-models` leaves the models folder's packs out; the built-in
ones stay (`--models=` still applies).
A modeller's textured belts, curves, splitters and undergrounds show their return run: the belt
coming back under the rollers, its texture running the other way at the belt's speed, seen through
the frame between the rollers and where it rolls over a line's end pieces (client/scripts/world/belt_return.gd:
the inner side of the return the model carries, or its top run mirrored under it). Only at full
detail; not in the shadows, the levels of detail or far chunks. `--belt-return=off` draws none, as before.
The space under the top run (the return strip, the rollers) is shaded as a covered space: darker ambient, direct light and fill (the shader's belt_cover, belt_return.gd `cover`; the rails and the top run are not). `--belt-cover=off` is the look before.
The same belts' side plates are closed at their ends: Vasillo's build each plate as a box open at both
ends, and where a line ends or starts, or at a splitter's or underground's open side, the ground showed
through the hole (L3). Each small upright hole in a belt-family model (a closed loop of edges only one
triangle uses, at most 0.25 tiles, flat) gets a cap facing out, wearing the plate's material and UVs,
added to the model's arrays once as it is read (client/scripts/world/belt_caps.gd), so the levels of
detail and shadows have it too. Zenith's own, Wube's and FUE5's belts are closed: nothing is added to
them. `--belt-caps=off` leaves the holes, as before.
`--addons=<folder>[,<folder>...]` loads add-ons from those folders (an add-on's own folder or a
folder of add-ons), always on, ahead of installed ones with the same id ([ADDONS.md](ADDONS.md)); while one is
given, Ctrl+Shift+F5 (Settings → Controls, "Reload the add-ons given with --addons") reloads them from disk, as does
the Reload button on an add-on's page. `--addons-dev` puts Reload on every switched-on add-on's page.
`--addon-reload=off` brings back the old behaviour: no Reload or key, and switching an add-on off and on keeps
the code first loaded (a restart reads changes). Script errors in an add-on's files are listed on its page in
the Add-ons window (and a refused entry script says its line); `--addon-errors=off` leaves them in the log only.
An add-on's `dependencies` (other add-ons, and Factorio mods per game; [ADDONS.md](ADDONS.md#dependencies-17)) are
checked when it starts and set the order add-ons start in; `--addon-requires=off` loads them without checking, in the
order found, as before. `--camera=factorio`, `--camera=first-person` or
`--camera=<yaw>,<pitch>,<distance>[,ortho]` start in that view instead of the Camera setting's
(`--camera=0,48,14,ortho` is close to Factorio's own; a distance past Furthest zoom is kept for that run). The character's body
is the middle of the screen in every view (the angled view at any zoom and tilt, orthographic, Factorio's view), where it is
drawn: on an add-on's hills, flying in mech armour. Across the ground the camera stays on it; up and down it glides a little
(about 0.1 s at the default zoom, quicker zoomed in) so the hills' small kinks don't jolt it; a jump (another target, the
remote view left) glides over. Where a hill would come between the camera and the character it tilts up over it and eases
back after (an orthographic view stands back along its axis instead, so Factorio's view keeps its 48 degrees; issue #17).
`--camera-focus=off` puts the camera as it was before, to compare: at the feet, level over the hills, trailing a little. `--fp-pick=ground` makes first person pick what is under the point its crosshair's ray meets the ground, as before K7, instead of the entity the ray meets first. `--shot-note=old` leaves a screenshot's "Screenshot saved" note unshown when the shot was taken with the interface hidden (F11), as before L15; by default it waits and shows, with Open folder, when the interface comes back. `--screenshot=<file.png>[@seconds]` saves
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
side, and hovering an entity with fluid or a power problem lists it by the cursor. A machine no pole
reaches shows Factorio's unplugged icon within about a second round the camera (the bridge's
once-a-second power read there, and the tick after a pole or an electric machine is built or
removed; J5); further away it comes with the alerts' slower pass. The entity info
panel on the right (Settings → Interface → Entity tooltip on the side) shows the hovered entity as
Factorio does: its status (No power, Low power...), recipe, a crafting machine's ingredients and
products a second at its speed with its modules, beacons and productivity (J15), modules, the
beacons reaching it and their effects (a beacon: its modules and the machines it reaches), and for a powered building
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
has no model of, the mod's own picture on a card facing Factorio's camera (docs/MOD-GRAPHICS-PLAN.md).
The bridge lists every prototype's graphics at the data stage and sends the list once per set of
mods (`gfx`, docs/PROTOCOL.md); the client keeps it in `user://mod-graphics/` and reads the pictures
from the mods themselves, never copying them: the server's mods folder (`server/data/mods`, which
the menu's servers use), then your own (`%APPDATA%\Factorio\mods`, `~/.factorio/mods`), then a
portable install's, or `--factorio-mods=<folder>[;<folder>...]` first. Mods may be folders or zips;
the version the game runs is picked when a folder holds several. Load game on a modded save links
your own mods folder's mods into the server's and runs Factorio's `--sync-mods` on the save, so the
server runs the save's mods at its versions, adds the mods turned on in the Mods window (unless Sync
mods with save is ticked; "Modded saves from the menu" above), then turns the bridge on; a mod missing
there (or there at another version) is named with its version, since Factorio, with no mod portal login
on the server, says only "unknown error". Their machines' pictures move while
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
footsteps by ground (grass, sand, dirt, concrete, belts, rails, ore), mining hits (each thing's own
mining sound from its prototype: rocks' and the stone patch's stone, Space Age's plants and ice; trees
and plants wood, ore, rocks and fish Factorio's ore sound; a building has no mining sound of its own or
mining particles in Factorio, so its swing is silent and sparkless until it comes off with its mined sound,
M1; `--building-swing=ore` gives buildings the ore sound and sparks, as before; nothing swings at
something out of reach, issue #24: ore past the character's resource reach, anything else past its
reach, each plus the bridge's 1.5 tiles to the target's middle, from `cinfo`, else Factorio's 2.7 and
10; the bridge's refusal stops a swing: "Out of reach" on the held target until the character moves, "Can't mine that" on that target, "This needs a mining drill" or "a pump or drill" on every entity of that kind until the button is let go;
`--mine-reach-check=off` swings at whatever is clicked, as before), building,
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
pack_sounds=true ; sounds from model packs (their sounds/ folders)
[graphics]
effects=true    ; smoke, dust, flashes, explosions
```

Command-line options (after `--`) override the file for that run: `--volume=0.5` (master),
`--sfx-volume=`, `--music-volume=0.3` (turns the soundtrack on), `--ui-volume=`, `--mute`,
`--max-voices=8`, `--no-fx` (no smoke or explosions), `--pack-sounds=off` (no sounds from model
packs, as Settings → Sound's "Sounds from model packs" off, `[sound] pack_sounds`), `--mod-sounds=off`
(a mod's own sound files, its mining and repair sounds, aren't read from its folder or zip: the
defaults play, as before), `--steps=table` (the character's steps from Zenith's name table, as before 0.2.3,
instead of each tile's, rail's, resource's and plant's own `walking_sound` that the bridge sends in `steps`; no
silent tiles and no rustling plants), `--addon-sounds=off` (add-ons' `api.sound.replace` and `mute` are ignored:
Zenith's own sounds play; an add-on's own `play` still works). For debugging, `--sfx-log` prints every
sound started (and `step/grass replaced by <add-on>` or `muted by` when an add-on decided it) and, every
5 s, how many voices are busy, and `--fx-demo` plays the character
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
Mods window lists them with a switch each (saved in the settings file's `[addons]` section) and
why one wasn't loaded (a newer add-on API than this Zenith's, a broken `addon.json`, an entry
script with an error). The log says which started. Their keys show in
Settings → Controls under each add-on's name; their data is kept in `user://addons-data/<id>/`.
An add-on with the camera turns the player's controls off until it hands it back; Zenith takes it
back itself for a ride to a space platform.

An add-on is a program running with the player's rights, so one nobody switched yet is off until it is
switched on (the switch is the consent). A download's own add-ons start as its `addons/bundled.json`
says (the Cinematic camera and shaders on, Terrain Elevation off); `--addons` ones are always on. On
the first start with this rule, a settings file an earlier Zenith wrote keeps every add-on found then
on, as it was (saved as on, once; `[meta] addons_off_by_default` marks it done, and a fresh settings
file starts with it, so nothing found later is turned on that way). `--addons-default=on` brings back
the old rule: an add-on nobody switched is on.

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

Two full-screen passes are drawn only when they can show something (0.2.1): the cloud shadows' (and
haze's) pass is hidden while it would draw nothing, at night on a planet without haze; and the smog's
(Settings → Graphics → Smog, `scripts/world/pollution.gd`) only while a chunk it can read for the
camera holds smog: the chunks between the camera and where the screen's corners meet the ground,
and one round them (with the horizon in view, any chunk the bridge sent).

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
  colour from the air it crosses and a blue hour after it, each planet in its own colours
  (docs/SUNRISE-SUNSET-PLAN.md). Its clouds (0.4.5) read their pattern from a texture the add-on
  colour from the air it crosses and a blue hour after it, each planet in its own colours.
  From 0.5.1 its noon sun stands in the north-west, the side Factorio's sprites are lit from, rising in the
  east and setting in the west across the north (the look's `sun_noon_yaw`), so models show the camera a lit
  side and a shaded one; Zenith's own noon sun, high behind the default view, lit every side the camera sees
  and drew the modeller's rocks flat. Its setting "Noon sun from the north-west" off gives the old sun back.
  Its clouds (0.4.5) read their pattern from a texture the add-on
  draws once when it starts (`shaders/cloud_field.gdshader`, a 1024 x 1024 viewport of 16-bit floats,
  the pattern repeating every 1,800 tiles or so) instead of working the noise out on every pixel and
  every step of the sky's march.

A look's passes are drawn before anything else of their render priority (whatever the camera's
distance from the world's origin, where their quad sits). They read Godot's one copy of the screen,
taken before the transparent pass, so blended things drawn after them (smoke, ghosts, icons, and the
flat ground clutter and raised grass, which are blended) keep their own colours: under the Cinematic
look they get neither its grade nor its cloud shadows.

The Factorio look's ground has no sunset (Factorio's has none); from low down its sky shows the sun
going down, restrained, while the light stays where Factorio's shadows fall.
`--sky=<planet>@<daytime>` holds a time of day with Factorio's darkness for it, for screenshots.

`--look=<id>` uses a look for one run (`factorio`, `classic`, `cinematic-shaders/cinematic`);
`--look-file=<file.json>` adds looks from a JSON file, for trying values without an add-on.

A modeller's metallic-roughness picture's metal is drawn as paint: at 0.1 of it, the share part colours
and textures without such a picture get (`factorio_material.gdshaderinc`, the global
`f3d_look_texture_metal`), as far merged chunks already drew it. In full, metal shows only the sky's
reflection, which Zenith keeps dim and blue, so those models read dark and blue. The old drawing is kept:
Settings > Graphics > Metal on textured models, Full, as before (`[graphics] texture_metal="full"`), or
`--texture-metal=full` for one run (`=paint`, or a share 0-1). The command line wins over the setting, and
the setting over the look's `texture_metal` key (looks.gd, default 0.1). The menu and the model preview
draw 0.1 (project.godot). No built-in pack has such a picture (model_textures_test.gd checks it), so the
built-in models look the same either way.

Per-model shading: pack.json's `"shading_models": {"transport-belt": "factorio", "iron-ore-*": "pbr"}` (prototype
names, `*` wildcards; `"pbr"` or `"factorio"`) sets single models over the pack's `"shading"` (model_packs.gd
`model_shading()`, read by `pbr(path)`, so the world, belt items, far chunks, inserter hands, item models, the Model
packs preview and the menu backdrop all follow). An exact name beats a pattern (the first that fits, in file order);
`<name>-<n>` variants follow their base unless named; an `items/` copy follows the same name. Built-in packs ignore
it; `--pack-shading=factorio` still draws every model Factorio's.

Packs' own shading (0.2.2): a pack whose pack.json says `"shading": "pbr"` (model_packs.gd `shading()`;
Vasillo's, written by `tools/models/fix_pack.py` from `fixes/vasillo.json`'s `pack_json`) has its materials
drawn as their files say (`factorio_material.gdshaderinc` `modeller_tex`, set by model_library.gd
`_factorio` on the materials Load marks `PACK_PBR_META`): no `part_light` balance on its pictures but the
look's `texture_light` ((1, 1) by default, Cinematic too), Godot's SPECULAR 0.5, its own roughness and metal
(metal at the look's `texture_metal` share), its occlusion picture as ambient occlusion only
(the baked vertex occlusion keeping its 0.3 share of direct light), and a normal-map frame right whichever way `dFdy` runs. Its pictured items take the
same lit path (`item_pbr.gdshaderinc`, in item.gdshader and belt_lane_model.gdshader; the Model packs preview
draws the file's own material), and far chunks bake it the same way (far_chunks.gd: no part colour share,
`texture_light` baked in by the vertex's facing; a bake made under the other setting is redone when next
merged). Since pbr-standard step 2 that is every material of such a pack, not only those with a base colour
picture: one without draws its factors as the file says (pc 1, no part colours, no weathering, metal at the same
share), and is never merged into another's row (model_library.gd `Load.textured`); far chunks bake its factor the
same way. This is decided when the model loads (with packs' own shading on then; a change in Settings reaches
these when they next load). `--pbr-untextured=off` keeps 0.2.2's: only pictured materials, the rest by Zenith's
material classes. Since pbr-standard step 3 such a pack's metal is drawn in full (the look's `pbr_metal`, 1 by
default; the global `f3d_look_pbr_metal`, used in place of `texture_metal` on its materials and items) and
reflects a neutral surrounding instead of the planet's blue sky: `shaders/pbr_env.gdshaderinc` writes Godot's
`RADIANCE` (which replaces the sky's sample before its BRDF, energy compensation and specular occlusion), an
upper half of the ambient plus the look's `pbr_env` (0.45 by default) of the sun, as sky.gd and the look light
the moment, a lower half at 0.45 of it, blended over a width growing with roughness (looks.gd `pbr_env_now`, the
global `f3d_pbr_env`, linear; its alpha is the switch). The menu and the model preview reflect the Factorio
look's noon value (`Looks.PBR_ENV_REST`, project.godot). The preview's pictured items, a StandardMaterial3D,
draw their metal at the same share and reflect the preview's own sky. `--pbr-env=off` reflects the sky as before,
`--pbr-env=<0-2>` sets the sun's share for one run, `--pbr-metal=0.1` (or `=paint`) draws metal as 0.2.2 did with Settings' "As paint" (the default; 0.2.2 drew it at 1 on "Full, as before", so `=full` for those players);
`--pbr-env=off --pbr-metal=0.1 --pbr-untextured=off` together are 0.2.2's drawing of a pbr pack. Built-in packs
never write `RADIANCE`. Far chunks still draw a pbr pack's metal as paint.
Since pbr-light-balance such a pack is lit by direction, so the sun decides its light and shaded sides: its share of
the look's fill light from the camera is the look's `pbr_fill` (0.3 by default) and of the ambient `pbr_ambient` (1),
the ambient comes through Godot's `IRRADIANCE` from the sky above to 0.35 of it below, and the neutral reflection's
sun share comes from a broad lobe towards the sun (none from straight opposite) over the same sky-to-ground ambient
(`shaders/pbr_env.gdshaderinc`; the globals `f3d_pbr_light` (on, fill share, ambient share), `f3d_pbr_sky` (the
ambient, linear) and `f3d_pbr_sun` (towards the sun), looks.gd `pbr_light_now`, set each frame). On buildings,
items and belt items; far chunks keep the flat balance. Measured lit-to-shaded in the Factorio look at noon
(ui_test.gd `_pbr_light`, a window, `--pbr-light-models=<pack folder> --pbr-light-shots=<dir>`): a matte sphere
2.16 -> 4.54, the modeller's drill 1.63 -> 4.69, his rock 1.08 -> 2.90. `--pbr-light=flat` gives the flat balance
back for one run (the fill and ambient in full, the reflection the same all round); the menu and the model preview
are always flat (no sun there). In a dev build the debug menu's Lighting tab has sliders for these numbers (fill, ambient,
the reflection's k, the sun lobe 2.8, the downward ambient 0.35, the metal share, flat/directional), live, nothing saved, with Reset and
"Copy values" (prints them to the log; global `f3d_pbr_tune`, looks.gd `pbr_tune`). Below them the same tab moves, live and unsaved, SSAO and SSIL (on/off, radius, intensity, power, detail, light affect, horizon, sharpness), the contact shading's strength and rim and patch widths, the sun's energy, shadow softness and biases, and the ambient energy: each shows what the game has now (a look or a quality change still moves it) until dragged, then is kept over the look each frame (looks.gd `light_tune`) until its Reset. A pbr pack's extra light follows the sun and ambient these sliders set (looks.gd reads its globals after them): the neutral reflection's sun lobe and sky parts and the ambient by direction from the sun's and the ambient's energy and colour now, the fill (`model_fill` x `pbr_fill`) by the ambient's energy over the game's (`f3d_pbr_light.w`), so at sun 0 and ambient 0 a pbr model is black but for its emission and lamps; untouched, nothing changes. `--pbr-light-scene=off` reads them before the sliders as before (the sliders then don't reach a pbr model's extra light). Built-in packs are always `factorio`,
No model gets a camera fill any more (owner: every model, tree, item, belt item and far chunk lit by the scene's sun and ambient alone, so at sun 0 and ambient 0 everything is black but emission, lamps and the UI): the look's `model_fill` (the Factorio look's 1.1) is off by default. `--model-fill=on` brings the look's own back for one run (0.2.2's, faded by night), `--model-fill=<number>` puts that fill on every look, `=off` none; the Lighting tab's Camera fill slider (from 0) sets it live. Whatever fill there is follows the ambient slider (now over the game's), and the sky's own colour, haze and clouds follow the ambient slider and its sun the sun slider (planet_sky.gdshader `scene_light`; `--pbr-light-scene=off` leaves both as before).
as is a pack without the key. The old drawing everywhere:
Settings > Graphics > Advanced > Packs' own shading, Factorio's everywhere (`[graphics] pack_shading="factorio"`),
or `--pack-shading=factorio` for one run (`=pack` the other way); the command line wins over the setting.
They set the global `f3d_pack_shading` (looks.gd `apply_pack_shading`: at the app's start and whenever the
setting changes, from main.gd, game or not, so the menu's model preview follows; in a game also in `settle()`
and when the game's look goes; project.godot's default is 1).

Since lighting-fixes step 1 the scene's light is the only light: the sun, and one lighting environment that every
material takes its ambient light and reflections from (buildings of every pack, items, belts, ground, trees, water,
far chunks). It lives in the sky's cubemap: in a game `planet_sky.gdshader` draws, in its `AT_CUBEMAP_PASS` only, an
upper half of the ambient (sky.gd's colour times the energy the look and time of day give, linear), a lower half of the
ground's albedo (look key `env_ground`, `Looks.LIGHT_ENV_GROUND` 0.25/0.23/0.19) times the sun on flat ground plus that
ambient, and a soft horizon; optionally a wide glow towards the sun (`env_glow`, none by default). The camera still sees
the planet's sky as before. Godot's ambient is held on that sky (`ambient_light_source` SKY, contribution 1,
`reflected_light_source` SKY) each frame while a look is on, the look's own values coming back when it goes; a look that
asks for sky ambient (Cinematic at twilight, 0.5) gets that share of the drawn sky in the upper half. The cubemap is 64
(32 before) and still updated a little each frame (incremental). In space the lower half is half the ambient. Night
vision's lifted ambient reaches it (main.gd puts it again after). "pbr" packs' own `RADIANCE`/`IRRADIANCE` terms
(`pbr_env.gdshaderinc`, below) step back (global `f3d_light_env` 1); the menu and the Model packs preview keep them.
`--light-env=shader` gives 0.2.2's light for one run: a constant ambient colour, the planet's sky in reflections,
"pbr" packs' own terms, the looks' 0.2.2 ambient (`looks.gd put_light_env`, `light_env_switch`). Measured in a
window with ui_test.gd `_light_env_window` (`--light-env-models=<pack folder> --light-env-shots=<dir>`).

Since lighting-fixes step 2 the shade is lit by the scene's ambient, not per pack: a look's `ambient_energy_lit` is its
ambient multiplier by day under the lighting environment, moving to its `ambient_energy` by night (nights as before):
the Factorio look 0.7 (0.36), so flat ground is about 4-5:1 between sun and shadow as Factorio's own ground is
(measured at noon, ui_test `_light_env_window`: 6.0:1 on screen before, 3.87 with 0.8, so 0.7); Cinematic 0.9 (0.42):
5.85:1 sun to ambient in scene light (11.4 before), 8.7:1 on screen (15.6 before).
`--light-env=shader` keeps 0.2.2's ambient with 0.2.2's light.

Since lighting-fixes step 4 a look's `roughness_min` (Cinematic's 0.55) holds only built-in packs and icon-coloured
items: a "pbr" pack's surfaces and a modeller's item models keep the roughness their files give (the globals
`f3d_look_roughness_min` and `f3d_look_roughness_min_pbr`, 0; Godot's roughness limiter and Cinematic's bloom
luminance cap still damp the sparkle). `--pbr-rough=floor` puts the look's floor on them too (0.2.2's on buildings).
The sun's highlight (`light_specular`) is 0.5 in the Factorio look (0.25 before) and 1.0 in Cinematic (0.6 before);
`--sun-specular=<0-2>` sets it under every look for one run (`=0.25` with the Factorio look is 0.2.2's).

Since lighting-fixes step 5 (Cinematic shaders 0.5.2, defaults updated in 0.5.3) the Cinematic look's ambient occlusion
acts on indirect light: `ssao_light_affect` 0.15 (Zenith's own looks 0.85) and the look key `ao_direct` 0, which
scales the models' and the ground's own occlusion share on direct light (global `f3d_look_ao_direct`:
factorio_material's `AO_LIGHT_AFFECT`, terrain's `ssao_on_sunlight`; 1, as before, in every other look); radius 1.7,
intensity 2.45 and power 2.0 (1.75, 1.75 and 1.6 in 0.5.2; 1.4, 1.5 and 1.6 before), SSIL off by default as before.
The add-on's setting "Occlusion in sunlight too" (off by default) also enables occlusion in direct sunlight.

Since lighting-fixes step 6 the Model packs preview (and the in-game model chooser's) and the main menu's backdrop are
lit as a game is: the Factorio look at noon on Nauvis (`looks.gd noon_rig`: sky.gd's noon sun and ambient times the
look's, its held sun, ambient_energy_lit and tint, the lighting environment drawn into the sky's cubemap for ambient and
reflections, linear tonemapping at 0.9, the sun highlight 0.5; `put_noon_rig`), and with no game on the globals
`f3d_light_env` 1 and `f3d_look_ground_specular` the look's (`put_idle_globals`), and the look's fill light (step 3,
`put_noon_fill`) from the camera's side. The preview's corner's lamp button gives the studio light before (a key from the upper left, a fill, a grey sky in
reflections, filmic) while the window is open; `--preview-light=studio` makes that the default for the preview and gives
the menu's backdrop its late-afternoon light (filmic, colour ambient) as before.

Since lighting-fixes step 3 the Factorio look has a fill light (look key `fill_light`, 0.35): a second DirectionalLight3D
(`looks.gd fill_light`, made in `attach`) with no shadow, the sun's colour, a low highlight (0.25), from behind the
camera 35 degrees up and 20 to its right (it follows the camera's turn), faded out by night, none in space, on
everything but the ground: terrain and water, flat decoratives and their grass are on `Visuals.GROUND_LAYER`
(render layer 17), which its cull mask leaves out, so the ground's light and shadows stay the sun's and the ambient's
while what stands on it has its shaded fronts lifted, as Factorio's sprites are rendered with a fill. Other looks have
none. `--fill-light=off` gives the look without it (the light before), `--fill-light=<0-4>` that energy under every
look. The camera fill on model materials (`model_fill`, `--model-fill`) is unchanged and still off by default.
Measured in a window (ui_test `_light_env_window`, Nauvis noon): flat ground 4.43:1 lit to shadow with or without it
(the ground's light unchanged to 4 digits); the built-in assembler 7.59:1 without, 4.10 with 0.35 (3.51 with 0.5);
Vasillo's drill 3.32, 2.69; iron ore 4.61, 2.65.

The standard PBR reference set: `tools/models/make_pbr_reference.py` writes `client/tests/fixtures/pbr_ref/`
(39 one-tile spheres, plates and a tube, one glTF material input each: metal and roughness as factors and as
pictures, a tinted base colour, normal maps, occlusion at two strengths, emission, alpha, samplers, a texture
transform, a second UV set, vertex colours; a `.gdignore` keeps them out of Godot's import). model_textures_test.gd
`_pbr_reference` loads each as a "pbr" pack's model and checks the shader parameters it sets, and pins what Godot's
glTF reader does (no occlusion strength; a texture transform read for the base colour only). In a window,
two ui_test.gd sections (`-- --pbr-ref-shots=<dir>` saves the pictures): `--only=_pbr_look`, metal against paint
spheres in the Factorio look, which prints the parity k ("parity k"), and `--only=_pbr_reference`, the strict
pass, which draws each file by Zenith and by Godot's own StandardMaterial3D at the same place (fill 0, metal in
full, the neutral reflection off; mean within 2%, no block over 5% apart, the known differences listed in
`PBR_REF_DIFFERS`); `-- --pbr-ref-rows=alpha_mask,normal_east` draws only those rows. Godot's side is given the
MikkTSpace tangents glTF asks for (Godot's runtime glTF reader leaves a file without tangents with one fallback
tangent, so its normal maps leant the same way whichever way the UVs ran; headless, `_pbr_reference` checks that).
Each section takes about 6 frames a picture after 30 to settle, and prints its time and frame rate.

A "pbr" pack's cut-out material (glTF MASK, Blender's Alpha Clip) that its file marks single-sided (doubleSided
false, Backface Culling on in Blender) drops its back faces and their shadows, as Godot's own material does
(`clip_one_side` in `factorio_material.gdshaderinc`); a double-sided one, and every other pack's cut-outs, draw
both sides as before. `--pack-shading=factorio` turns it off with the rest of packs' own shading.

A pack whose belt is narrower than Factorio's can say how far in its items ride: pack.json `"belt_lane_offset"`
(tiles from the belt's centre line; absent: Factorio's 0.234; never wider than that). Items on belts that pack's
belt model draws are drawn on lanes moved in to it, each lane towards the centre line (straights, curves,
undergrounds, splitters, the packed lanes, the far lanes' icons);
the belt simulation's positions are untouched. Vasillo's belts say 0.21 (rails 0.375 out, a plate turned 0.35 rad
reaches 0.16 sideways). `--belt-lane-offset=<tiles>` overrides the pack for one run.
`"belt_item_height"` is the height of the belt surface the items rest on (absent: the belt model's top plus 0.02, 0.03
for the far lanes); an item model's lowest point sits on it. Vasillo's belt surface tops out at 0.25 on every
belt, curve, underground and splitter. `--belt-item-height=<tiles>` overrides the pack for one run.

The character's flashlight at night (avatar.gd) is Factorio's cone: its own picture
(`core/graphics/light-cone.png` from the install, or one drawn to its measure without one), 25 tiles
long from a tile ahead of the character, fading out, landed on the ground through a spot light 10
tiles over the character. Nothing casts that spot's shadow (its shadow stays on only because Godot
projects a spot's picture through the shadow's matrix), so buildings don't stop the beam, as none
stops Factorio's light, and its shadow pass draws nothing. In first person it turns to where the
crosshair looks, whichever way the body faces. `--flashlight=old` brings back 0.2.1's: a spot 3
tiles up whose shadows the buildings cast, so its beam ended at the next building. The Compatibility
renderer, which draws no projected pictures, always has the old one.

The belt step-up (avatar.gd, owner: "doesn't move camera or actual player position, just a visual
thing"): standing on a belt, underground belt, splitter, loader or linked belt (the belt family of
Factorio's walk-over types, stand_height.gd's BELTS), the character's body is drawn on its top (the
model's, else its placeholder's: 0.15 tiles for a belt), at most 0.3 tiles up (avatar.gd STAND_MAX: a
splitter's or a tall loader frame's top isn't stood on); pipes-to-ground, heat pipes and rails are walked
past at ground level. Eased up in about 0.1 s and down a touch
slower. Drawn only: `position`, reach and every command stay the game's, and the camera never follows
it (the first-person eye and the angled view's centre follow only add-on lifts set with `camera`).
The body, shadow, lantern, health bar, muzzle, flames and step sound follow it. The stand height is
looked up only when the drawn position moves (at most once a frame), never standing still.
**Graphics → Step onto belts** (on) turns it off; `--belt-step=off` turns it off for a run whatever the
setting says.

Add-ons' camera modifiers (add-on API 1.7, `api.camera.set_modifier`: a bob, sway, shake or FOV kick,
summed and capped, drawn on the angled view, Factorio's view and first person only; walking, reach and
picks' range never follow them) are off for a run with `--camera-modifiers=off`: the camera as without
any. An add-on's `take({"input": false, "aim": "center"})` aims building, mining and the hover at the
middle of the screen, as first person does.

A lit lamp's light (lamp_lights.gd) reaches 14 tiles with a soft fall-off (Godot's omni attenuation
0.5): the ground is lit to about 11 tiles at a tenth of the lamp's foot, twice the old light's 5
(range 7, attenuation 1); a coloured lamp's reaches 8 (4 of 7 as before). Factorio's lamp light is
40 tiles across, a tenth of its middle at about 16 tiles. `--lamp-radius=old` brings back the old reach.

Cars, tanks and spidertrons have their own headlights (vehicle_lights.gd), Factorio's oriented
`light`s from base's prototypes: the car two cones 0.6 tiles either side and 14 ahead in a warm
yellow, the tank two 0.1 either side, a little splayed and brighter, the spidertron four of different
sizes and splays and a round light. Each is the flashlight's cone, scaled to its size and placed
where Factorio shifts it, so a car's two overlap into a beam about twice as bright and a little wider
than the character's. They shine at night (above darkness 0.3) on the vehicle the character drives
or rides in (the bridge doesn't say who drives the others), and meanwhile the character's lantern
and flashlight are out, as Factorio draws nothing of a character in a vehicle. `--vehicle-lights=off`
puts back the old way: no vehicle lights, the character's flashlight shining out of the vehicle.

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

## Trees and rocks

Nauvis's trees grow in Factorio's variations (`client/scripts/world/nature_looks.gd`, from
`client/data/nature_looks.json`, which `tools/models/nature/tree_looks.py` measures from the
sprites in your install): each tree picks one of its prototype's 8 to 12 pictures by Factorio's own
weights, by where it stands, and its model is scaled to that picture's height and width (the young
ones about 70% of the tallest), or, for the two fallen ones six types have (about 1 tree in 87),
laid on the ground at the picture's length. Each tree takes one of its prototype's leaf colours,
as Factorio tints its trees. Rocks take the size of one of their 16 to 20 pictures. The bridge
doesn't send which picture Factorio drew, so a given tree may differ from Factorio's; the mix is the
same.

With a Factorio install, the leaf cards wear patches of the tree's own leaves picture (a 4 x 4
atlas made on a worker thread, about 60 ms a tree type), its leaves' light and shade over the
model's own lighting; bark and rock take the grain of their own pictures, read along the three
axes in the model's space (one 64 x 64 layer each in a texture array, `f3d_nature_grain`). Without
an install the shader cuts its own leaves and the materials stay plain, as before.

Switches (client, after `--`): `--nature-looks=off` (one shape and colour per prototype, +-10%, no
grain or atlas, as before), `--leaf-atlas=off` (the shader's own leaves), `--nature-grain=off`.
`python tools/models/nature/raster.py out.png tree-05:atlas big-rock:atlas` draws a model beside its
sprite from Factorio's camera in plain Python (no Blender, no window; `NAME@k` places a variation
as the client does), for looking at shape and colour; the client's own look needs a screenshot.

## Creatures' skins

Enemies wear Factorio's colours from their sprites (`tools/models/creature_skin.py`,
`tools/models/space_skin.py`, `client/scripts/world/creature_models.gd`). Worms, Nauvis's spawners and
Gleba's wriggler keep Factorio's one mask layer per vertex, which each tier's tint colours; where the
mask doesn't reach (a worm's head and mouth, a spawner's egg sacs, much of a dead worm) the skin tool
writes white, which the shader reads as no mask, so those parts keep the sprite's own colour. Factorio
draws no glow on its enemies: a demolisher's lava is painted bright in its sprite, so its model's lava
shines by its own colour, 0.4 of it (`PAINT_GLOW`): about the sprite's brightness by day, not dark on
its shaded side; the crust over it doesn't glow. `--creature-glow=old` (client, after `--`) brings back
0.2.1's look: the unmasked parts in the tier's colour four times over (lime, cyan, red on worms, red and
orange spots on spawners) and the lava at its model's 2.5 times red.

## Chunk streaming: the view's direction, the area cache

(I18, owner: "direction based chunk culling and faster stream in time; maybe we cache everything in an
area".) Not run in a window or measured yet: only the mod, mock and protocol tests ran.

- **Direction.** The client works out the view's direction (where the camera looks on the ground,
  turned towards where the character moves; none looking straight down, as in Factorio's own view) in
  eight steps, and asks for the chunks of its square in that order: a chunk behind the view counts as
  further away, straight behind as twice its distance (world.gd `prio_order`). The bridge orders its
  queue the same way (`sub` `f`), and the client builds dirty chunks and meshes ground in that order,
  hidden chunks last. A screenshot's cover keeps its own order (no direction while it loads).
- **Hidden behind the camera** (client/scripts/world/behind_cull.gd): chunks of the square outside the
  camera's view laid on the ground (grown by 64 tiles, more at the far end), outside the ground whose
  shadows can fall into the view, and more than two chunks from the character are hidden, their nodes
  kept as they are: turning back shows them again the same frame, nothing rebuilt. Off in the remote
  view, while chunks are held, while a screenshot loads, under full detail, in VR, and while another
  camera draws the world (a train's view, the train overview, an add-on's screenshot view).
  `-- --no-behind-cull` turns it off; `-- --behind-cull-hide=all` hides every off-view chunk in the same
  frame instead of slicing off-view hides across frames (`HIDE_PER_FRAME`).
- **Faster.** The bridge starts up to 4 chunk snapshots a tick (the Chunk snapshots per tick setting
  is the least) while the work budget has room; each further one only while its slices fit the
  chunks' share of the tick, so the UPS governor's budget still bounds it. Moving, the client asks
  for 12 chunks at a time (8 before) and asks for more once half of them are drawn, not only every
  0.15 s.
- **The area cache.** Chunks that leave the square stay built and drawn, as they last were (the bridge
  no longer updates them), up to 4 chunks past it, at most 600 (fewer at long view distances, under
  the same total as held chunks), the least recently left going first and those hidden behind the
  camera before those in view. The bridge tells the client (hello `lv`, message `kept`) the change and
  entity counts each chunk had when it left, if nothing changed there since; walking back, such a chunk
  is asked for at once with those counts and stays drawn, and the bridge's `same` needs nothing rebuilt.
  Further out the cache of chunks' messages (1,500 chunks, now also at most about 192 MB, least
  recently used first) answers as before; a chunk that got changes (`add`, `del`, `upd`, `tiles`)
  while it was in view is no longer offered from its old messages (the bridge would refuse them), but
  is confirmed by `kept` when nothing changed.
- **Letting go after a screenshot** (L14). A shot zoomed far out (F12, `api.view.screenshot`,
  `--full-shot`) loads every chunk its camera sees, thousands; when it ends the view's own subscription
  goes out at the next step and the rest are let go. An unloaded chunk is now hidden first, farthest from
  the focus first, as many a frame as the unload slice (frame_budget.gd `unload`, 1.5 ms) holds, and its
  records and nodes go after it as before; before, each stayed drawn until its records had gone, 2-3
  chunks a frame, so the renderer kept drawing thousands of chunks at full detail for half a minute.
  Their clutter (decoratives.gd's sweep every 2 s) is dropped and freed 1 ms a frame each, hidden as it is
  dropped; the sweep's one frame had dropped 4,000 chunks' (30 ms) and queued their 32,000 nodes to be
  freed together (95-100 ms). `-- --unload-hide=off` keeps the chunks drawn until their records have gone
  and drops the clutter in the sweep's frame, as before. And Hold the game at
  60 UPS takes no step while full detail is on (the shot's slow ticks, the bridge in photo mode and the
  game held for the picture, had taken its whole ladder, FPS limit 45 and view distance 5 included, which
  came into force the moment the shot ended and came back a step every 5 s); it judges afresh 10 s after.
  `-- --governor-full-detail=judge` judges the shot's ticks as before. The bridge side was already spread:
  the chunks dropped are noted and told as `kept` 16 a tick (world.lua `kept_step`; the mock does the
  same now, where it counted all 4,000 at once and stalled past the client's timeout).
  `--stutter-probe=<out.json>@shot` measures it (below): headless against the mock's `--busy` base, a
  4,708-chunk shot letting go of about 4,300, the 10 s after it went from 447 frames (45 FPS under the
  governor's limit for 16 s; 40 over 33 ms, 1 over 50 ms, the worst 117 ms) to 601 (6 over 33 ms, 1 over 50,
  the worst 53 ms), and the chunks let go were all hidden 0.3 s after it instead of 28 s.

## Mod settings

In a game the client's menu started: the client's Settings → Mod settings, sent over RCON at once.
In Factorio: Settings → Mod settings → Map. On a headless server started by hand, set them from
the server console or RCON, for example `/c settings.global["f3d-chunks-per-tick"] = {value = 2}`.

| Setting | Default | |
|---|---|---|
| Surface to stream | nauvis | Where the server's character lives |
| Chunk snapshots per tick | 1 | The least started a tick: up to 4 are while the work budget has room (I18). Only chunks that must be read count: chunks the client kept (answered `same`) and ungenerated ones (`none`) don't wait for it, so going back to a surface (a Factorissimo building's door, a platform and back) takes a few ticks |
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
  Your settings stay as they are; the debug line says what it holds back. Otherwise `/f3d-profile`, then `/f3d-status`, shows which module costs most: lower "Belt
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

### Test runs' Godot logs (not the player's)

Zenith's own Godot log is `user://logs/godot.log` (`%APPDATA%\Godot\app_userdata\Zenith\logs\`), with the
last 5 kept: each start renames the last log aside, so test runs there would push a player's log (a freeze's,
say) out. Godot opens that file before any script runs, so every test and tool that starts Godot passes
`--log-file <absolute path>` instead (a relative path is read from the user folder):

- `tools/check.py`: `art-src/check-logs/<check>.godot.log` in the main checkout (`--all --logs <folder>`: there);
  its import pass `import.godot.log`. CI's ui job: `ci-logs/`.
- belt_view_check, belt_walk_check, bench/compare_builds, bench/hybrid_cost, models/review, ui_reference/ours,
  look/factorio_reference: `godot.log` (or `<name>.godot.log`) in the run's own output folder;
  live_check's pipeline predictor a temp folder; quit_soak `%TEMP%\zenith-quit-soak\godot.log`;
  release/package.py's import and export `art-src/release-logs/`.
- `python tools/test_godot_logs.py` (in `check.py --all godot`) runs one test as check.py does and checks the
  player's logs folder is unchanged and the run's log written. Another Godot started beside it (a game, a
  tool without `--log-file`) can rotate the folder too and fail it: run it again.

Starting Godot by hand for a test or probe: add `--log-file <your run folder>/godot.log` before the `--`.

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
- **Updates** (client/scripts/debug/update_overlay.gd, shaders/update_flash.gdshader): where and when
  the bridge updates the world. Each kind, ticked on its own, outlines on the ground what its messages
  touched as they arrive, in its own colour, fading over a second, drawn over buildings and on Terrain
  Elevation's hills; a legend at the left lists the kinds on with their updates a second. Chunks:
  snapshots (`chunk`, `ents`), kept chunks (`same`, `kept`), tiles, decoratives (`dec`), far belt icons
  (`bfar`). Entities, by footprint: `add`, `del`, `upd`, `mnd`, machine states (`st`). Belts, by lane:
  loaded (`bs` lm), read (sl, ew, sh), dropped (dl), drift checks (pc), asked for again (`bre`), and
  takes and hand-offs (`ie` picks and drops at belts, kind 6 puts, F's `pku`). Moving things: `mv`,
  inserter hands (`ih`, `ie`), items on the ground (`gi`), each spot at most 4 times a second. Fluids,
  heat and power (`fl`, `ht`, `pw`), new alerts (`al`), Alt-mode rounds (`ac`, `am`, `aiu`). Three
  states instead of flashes: the subscription (the square, the chunks still to come in the order asked
  for, those on their way, the view's direction), how each lane round the focus is drawn (the
  simulation's items, the lattice, far icons, nothing), and the lattice against the simulation: a
  packed lane the lattice draws standing while the simulation moves its items (the frozen lanes;
  pulsing once held half a second) or sliding while they stand. With every kind off there is no node,
  no handler and no per-frame work; on, one MultiMesh per kind, an instance written only when its flash
  is drawn (at most 512 a kind a frame), the states worked out a few times a second within 64 tiles of
  the focus (belt_items.gd's `debug_tap`, after each belt job, when no job runs).
- **Simulation**: the belt items' fixes (belt_items.gd `LIVE`) off and on while playing, to compare: Early stop
  (`--belt-draw-early-stop`), Longer lead (`--belt-sim-ahead=auto` with `--belt-draw-lead-lag`; off: a fixed lead,
  24 ticks or the command line's N), Rescue seen (`--belt-sim-rescue-seen`), Early changes (`--belt-draw-early`),
  Take past the edge (`--belt-sim-take-edge`), Open lattice ends (`--belt-draw-lattice-open`), Clean handover
  (`--belt-draw-handover`), Shut edge ends (`--belt-draw-edge-shut`) and Items keep their turn (`--belt-draw-turn-id`;
  items already drawn take theirs at their next change). Each box starts as the command line set it ("started on/off", and
  "changed" once flipped); a change waits for the next belt job's start (the main thread, no job running: a running
  job never sees a switch change under it), into the job's statics and the simulation's own switches, belt_sim.gd
  and BeltSimNative alike. Nothing is saved. Left out, as they need a restart: `--belt-sim-take-first` and
  `--belt-sim-take-line` (the simulation queues takes and reads for them, left waiting if flipped), the lattice and
  its creep (a lane sliding at its share isn't unwound), and the C++ twins themselves.

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
threshold 4`, `lod lines 0` (levels of detail and SSAO in every real line), `relief off` (the ground's
bumps), `shadow distance 60`, `arms|items|wires|movers|terrain no shadow` and others (see
`_set_variant`). `--probe-ab=3` measures each variant three times between two "base" steps, which
cancels the graphics card's drift (compare each with the bases beside it), `--probe-timing=2,4`
sets the seconds to settle and to measure, `--probe-stay` leaves the client running after the summary
(a harness that takes screenshots after the route ends it), `--probe-warmup=30` waits longer and until no chunk is
left to build, `--probe-shots=<dir>` saves a screenshot of each step. Each step's medians (frame,
GPU, render CPU, draw calls and triangles of the view and of the shadow passes, casting chunks)
are printed and kept in the JSON's `variants`. `--legacy-render` starts with the shadows and levels
of detail from before sun_shadows.gd, for a whole run. `--soft-shadow-atlas=4096` caps the sun's shadow map at 4096 while the
sun has an angular size (a look's soft shadows, the Cinematic look's): Ultra's 8192 map then stays at
4096 under the look (measured at 4K on the owner's desktop: 1.5 ms less at Ultra under the Cinematic look,
a still the same; nothing at Low and High, whose maps are 4096 or smaller). It is off by default (the
quality's own map, `0` or `off`): close up on the character the soft shadows' edges came out stair-stepped. The variant `soft shadow atlas <size>` sets it for one step (`soft
shadow atlas 0` against `base` under the Cinematic look at Ultra; without soft shadows it changes nothing).
`--shadow-fit=old` fits the sun's shadow map as before the shadows' stability work: whether the view
"reaches far" (Godot's cascades) was judged by the ladder's distance, never under 32 tiles, so zoomed in
the ordinary angled view got cascades (two splits on Low and Medium, half the texels on one axis; four on
High, a hard seam by the character); the ground was measured at y = 0 under a camera riding Terrain
Elevation's hills, so walking over hills flipped the mode or the distance step and every shadow moved;
and the split fractions were set in one-map mode too. Now the far test uses what the view needs (its
furthest ground over the fade, at most the cap) or the horizon in view, the ground is measured from the
height where the screen's centre meets the hills (the furthest 1.5 tiles under it, so valleys keep their
shadows), the shortest distance is 12 tiles and the fractions are set only when there are splits. At a
1920 x 1080 picture, pitch 50, High's 4096 map: zoom 6 one map over 13.8 tiles (about 185 texels a tile;
the old fit four splits to 32 tiles), zoom 15 27.8 tiles (91, was 32 tiles and 79), zoom 30 unchanged
(55.8, 45). Factorio's orthographic view keeps its fixed cascades either way.
`--shadow-filter=old` puts back the soft filters from before the shadows' steps 2-3: Soft Low (4 taps)
on Medium, High and Ultra with fixed blurs (High 0.6 texels), and a look's sun size (the Cinematic look's
1.4 degrees, Godot's PCSS) passed straight to the sun with a 20-tile pancake. Under the Cinematic look
the old picture also needs the add-on's "Shadows soften with distance" on and its "Sun size" at 1.4: the
add-on (0.5.0) hands a sun size of 0 otherwise, so the switch alone gives the old filter without PCSS. Now the blur follows the
map's texels a tile: the edge's radius on the ground (0.02 tiles, a look's `shadow_edge`; 0.04 under
the Cinematic look's Soft shadows) times the nearest split's texels a tile, clamped between one texel and
the filter's own radius (1.5 to 4 texels); Low keeps blur 1.0. A look's sun size (PCSS) is only used when
it asks for one (the Cinematic look's Shadows soften with distance, at its Sun size of 0.5): then blur
1.0, Soft High's 24 + 24 taps on High and Ultra, and a pancake of 8 tiles, which keeps the blocker search
small and dense (`--shadow-pancake=<tiles>` sets it). Anti-aliasing is unchanged: no screen-space AA
(FXAA, SMAA) cleans shadow noise; only TAA and FSR2 average it, and both ghost on belts and inserter
arms, so the filter is made to leave none. `--sun-step=<degrees>` (measuring only; 0, the default, is
smooth) holds the sun's light until it has moved more than that many degrees, then jumps: the shadow map
rests in between; the sky's sun and the passes stay smooth. The stutter probe's variants `sun size
<degrees>` (0.5: PCSS on), `pancake <tiles>` (PCSS's), `blur <x>` (a fixed blur, 0 fitted) and `edge
<tiles>` set these for one step, beside `soft <quality>` (`hard`, `very_low` ... `ultra`; the fitted blur
is worked out for that filter's radius, so the edge on the ground keeps its width).
`@join` measures the join itself: it stands 90 s from the world being ready (pass `--probe-warmup=0`
so the first load's frames are in), notes when the view was fully drawn (the `JOIN` line: chunks,
terrain and models settled, the belts' first load done) and with `--probe-stay` keeps the client
running after writing the file, so `tools/belt_view_check.py --client-arg=--stutter-probe=<out>@join
--client-arg=--probe-warmup=0 --client-arg=--probe-stay` scores the same run. `python
tools/join_hitches.py out.json [--windows] [--md]` then gives frame-time percentiles, the frames over 25
and 50 ms and what each hitch was spent on (the biggest script subtree, world.gd's part of it, the
renderer's draw with the pipelines it compiled, or the wait for the GPU). belt_view_check's
`--godot-arg=--gpu-profile` passes Godot its own flag so the probe also gets the render steps' times.
`@shot` (L14) takes the camera up (`--probe-shot-camera=<height>,<pitch>[,hand]`, default 250 tiles at 22
degrees: past the horizon, about 4,700 of the mock's chunks; `hand` gives the camera back to the player's
view when the shot ends) and a screenshot as the Cinematic camera's F12 does, framed as 1920 x 1080 and
written to the run's own user folder, then stands 10 s (`--probe-shot-after=<s>`): the shot's frames are
the `shot` phase, the `walk` phase is the frames after it, and an `AFTER SHOT second N` line for each second
gives the worst frame, those over 50 ms, the chunks still to free and how many of them are still drawn
(`q_free_drawn`), and the parts that took most (`pre_process` and `after_process`: the frame's time before
the first and after the last `_process`, coroutines, deferred calls, freed nodes, physics and the draw).
`@pan` moves the camera fast while the character stands (the owner's stutter when the camera moves
quickly): 3 s still, the view spun round at 240 degrees a second for 6 s, 2 s still, zoomed all the way out
and back in over 6 s, 2 s still, then the camera taken over as a free camera and flown 360 tiles east at 60
tiles a second and back (12 s), given back, 5 s still. Split the frames by leg with their cumulative times
(3, 9, 11, 17, 19, 31, 36 s). Headless it shows the main thread only; the decorative sheets' bakes
(`decor_sheet_baker.gd`) run only with a GPU, and pipeline compiles only show in a window.
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
`-- --st-slice=on|off` (on): a machine states message (`st`) of more than 64 states waits in world.gd and is applied
over the next frames within the frame budget's `states` slice (2 ms, 0.3 ms floor; the whole slice when more than
one waits), in the order the messages came, so a unit ends with the latest state sent; the lamps' colours and Always
on in it apply at once. A small one with nothing waiting applies at once. Off: every `st` applied whole as it is
handled, as before (a busy base's 1,600 states took 10-25 ms, a dropped frame each time).
`-- --ih-apply=quick|old` (quick): an inserter hand update (`ih`) binds an arm to its record again only when the
record, its direction, position or pack, or the models in use changed; a new arm looks for a belt at its pickup
only among what stands within a tile (a busy chunk's every record was looked up, 0.3 ms an arm); its place in the
preplan queue is a flag. Old: as before. What is drawn is the same either way.
Belts are the last thing culled (the owner: "id like the belt logic to be high priority on what gets culled for
performance it is integral to the games feel"); each of these has its switch, the old way back when off:
- `--belt-messages-first=on|off` (on): the belt simulation's updates (`bs`) are handed to the belt layer as they are
  read, before every other message waiting and outside the messages' slice (a few µs each: belt_items.gd queues them
  for its job). Behind a `welcome` or `surface` still waiting (both start the belts over), and behind belt messages
  already queued after one, they keep their place. Off: in the one queue with the chunks, decoratives and the rest,
  so a backlog (a hitch, a burst of chunks) left the belts drawn from updates seconds old. The inserters' events
  (`ie`) stay in order: routed first too, an inserter built during a backlog got its events before its `add` and
  was drawn at the map's origin for half a second, then a tile or two off for its first swings. A belt built during
  a backlog can show its items a moment before the belt itself.
- `--frame-budget-belts=first|off` (first): the far belt icons' slice (belt_lanes.gd, `lanes`) ranks with the
  messages and has a 0.5 ms floor, so under a tight frame the near chunks' builds, terrain, models, shadows,
  levels of detail, decoratives, wires and far merging wait before it; off: priority 6 with no floor, as before.
- `--governor-belts-last=on|off` (on): Hold the game at 60 UPS cuts the belt item distance (`far` 96, 64, 32) only
  after every other step, the view distance and the FPS cap included; off: STEPS' order, `far` 96 at the seventh
  step, as before.
- `--night-vision-fx=off`: no night vision feedback: no sound as it turns on or off (the equipment's own
  activate / deactivate sound, read from the prototype in the player's Factorio install), no icon over the
  shortcut bar and no green edge on the screen. Without it Settings > Interface > Night vision indicator and
  Night vision screen edge (`interface/night_vision_indicator`, `interface/night_vision_edge`, both on) turn the
  two visuals off one by one; the sound follows the Game effects volume.
- `--perf-warning=off`: starts with the performance warning hidden (until Settings > Interface > Performance
  warnings, saved as `interface/perf_warning`, on by default, or the debug menu's row of the same name is changed).
  Both switches show it off meanwhile, without saving that, so one click turns it on.
  It is Factorio's warning triangle at the top left, right of the Show in Factorio button (in its place while that is
  hidden): shown while Hold the game at 60 UPS holds settings back, with how many, and 10 s after the last comes back;
  hover lists them, a click opens the log (perf_log.gd: 200 entries, cleared with each game, the PC's time of day,
  from -> to and why, Copy). The work budget's cut under 300, Automatic moving belt items under half its start (6,000)
  and the bridge's own belt square cut are logged too, without lighting the icon. Off, the log still fills.
- `/f3d-perf belts_last` (on): the far belt lanes' rounds slow only at rate level 3, as the belt simulation's
  updates (which `period_max` 6 never stretches); off: 2, 4 and 8 times apart at levels 1-3, as before.
- `--message-catchup=on|off` (on): while the oldest message waiting in the bridge's queue (bridge.gd
  `_drain`) has waited longer than `--message-catchup-msec=N` (250) since its datagram was read, the
  messages get their own slice (4 ms) whatever the pool has left. `off`: as before. Why: with the pool
  at its 3 ms floor (the frame's other scripts at 9 ms or more: loading or walking a big base) the
  messages got 2 ms a frame, backlog or not (the doubled slice past 300 waiting is capped by the pool
  too), about 3.2 ms used with the last message's overrun. Since the merge of main's 0.2.0 work
  (68f61e5f; not narrowed further) a frame at -62,-26 draws 11 M primitives instead of 5-6 M and waits
  on the GPU (19-20 ms, 12-15 before): the warm-up runs at ~41 fps instead of 48-54, so those 2 ms a
  frame came to ~138 ms of messages a second, under what the bridge sends there while the client loads
  and stands. The queue grew through the whole 85 s warm-up and drained only well into the walk (the
  recorder slows the game to 25-29 UPS), and every chunk asked for meanwhile was answered behind it.
  The join runs on 68f61e5f (load-hitches' base) already had 1,650-2,800 waiting; the inserter events
  with the samples (`ie` and `ih` both, the hand-off's default) and the datagrams no longer lost took
  it to 4,300-4,700. Measured live (tools/belt_walk_check.py, route fast at -62,-26, Hold 60 UPS; the
  probe's new `STUTTER messages waiting` line and per-frame `q_messages_ms`), off (5 runs) -> on (3):
  messages waiting in the warm-up p50 3,000-3,300 / most 4,300-4,700 -> 35-44 / 171-419, the oldest
  15.6 s behind at p50 (27 s most) -> 0.22-0.26 s (0.8-2.1 s most); chunks wanted to drawn while walking
  p50 31-144 s -> 1.5-2.2 s, never drawn 107-164 -> 0-13; belts visible while walking 54-76% -> 99.0-99.2%,
  phantoms on the recorded lanes 0.8-1.0% -> 0.8-0.9% (the report's total counts lanes past the recorded
  area too, 13-16% when the walk goes further than the recording planned for). Standing (belt_view_check,
  `--record 60`, 2 runs each) unchanged: -62,-26 96.8-96.9% / 1.0-1.1% (before 96.8% / 1.2-1.4%), -272,-14
  98.0% / 0.4% (97.6% / 0.4%), 0 datagrams lost. Cost: the warm-up's frame p50 20.4-21.1 -> 21.9-22.3 ms
  (messages 135-141 -> 167-178 ms a second; the slice raised in 1,730-2,270 frames of ~7,200), frames
  over 33 ms in it 176-222 -> 225-265; walking, p50 19.2-20.5 -> 20.1-21.6 ms and frames over 33 ms 82-103
  -> 147-176, which is the walk's chunk streaming now happening (700-920 chunks drawn instead of 190-260;
  world.gd's own time in those frames 0.47 -> 1.1-1.6 s), the raised slice in only 30-44 of them. The p99
  of chunks wanted to drawn (100-120 s, on and off) is chunks wanted since the warm-up at rings 6-10 of the
  square and drawn once the walk reaches them; the 11-12 builds had none of those. `--frame-budget=separate`
  drains the queue too (most 373-410) but costs every frame (warm-up 34 fps, frames over 33 ms walking
  262-318); dropping the inserter events (`--inserter-handoff=off`) only shortened it (most 3,100-3,500,
  chunks p50 26-45 s).
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
- The once-a-join frames of 100-180 ms the first 3 s of a join at -62,-26 had left (feature/load-hitches;
  the probe names each part: `w_mv_*` movers, `w_dc_*` decoratives, `w_ic_*` item kinds, `w_rb_*` robot
  batches, `w_ta_*` terrain applies, `w_gs_*` settings applied; `join_hitches.py` attributes them):
  - `--governor-apply=held` (the default; `all` as before): a UPS governor step applies only the knobs it
    holds (view radius, belt distances and cap, entity radius, map refresh, update rate, fps). It used to
    apply every setting again (`_apply_game_settings`: the look, environment, shadows, SSAO, clouds,
    contact shading over every chunk, the models' quality), which on a join was a 2.5 s frame when the
    governor stepped down at 36 s, and after each step a frame of 60-300 ms in the renderer with 70-160
    pipelines compiled again and the shadow atlas (51 MB) made again. Before: 805 pipelines compiled in
    the join's 90 s, 186 of them at draw time; after: 108-130, 20-28 at draw time.
  - `--movers-dress-usec=N` (1500; 0 = all at once, as before): movers whose model has just come
    (robots, rolling stock) are dressed for at most N µs a frame, at least one a frame. Their frame was
    150-180 ms; most of it is the first robot's batch (the robot shader's first use, see the warm-up),
    the rest the hundreds after it, now spread.
  - `--decor-texture-thread=on` (the default; off as before): a decorative's atlas goes on the GPU on the
    worker thread that read its pictures, not when a chunk's clutter is put in. What remained of the
    115-140 ms clutter frame was the kinds' materials' first use of the decorative shaders (the
    warm-up). The texture travels on the KindData with the atlas, so main's race fix (each drawing made
    once per KindData and kept on it, decor_test) holds with it on or off.
  - `--decor-parallel-load=off`: holds `_kind_mutex` across decorative picture loading (one worker at a
    time, blocking main-thread `index()` swaps) instead of per-decorative locks and lock-free `index()`
    preparation.
  - `--terrain-upload-thread=on` (the default; off as before): the terrain Texture2DArray (every layer
    again whenever new ground arrives, 20-40 layers of 1.4 MB) is made on a worker thread; a tile stays
    unknown until the array with its layer is in use. The 90-100 ms `terrain polled` frame is gone; the
    first textured chunk's surfaces (`w_ta_surfaces`) then took 89 ms once instead (the terrain shader's
    first use with that layout; the warm-up takes that away too). Since the merge with main's 0.2.1 hotfix
    (`--terrain-layers`, below) the array has room: a new kind of ground is written into its own layer on
    the main thread (`update_layer`, 2-3 ms) and its tile is known at once; only a new array (the first, or
    one grown when the room is full, or every time with `--terrain-layers=rebuild`) is made on the worker,
    its tiles unknown until it is in use. Off: that new array is made on the main thread.
  - `--item-dress-usec=N` (0, off): item kinds whose model or icon has come dressed for at most N µs a
    frame. Tried at 1500 for the 60-95 ms frame the first kinds made: no gain (a kind's dress was the
    frame: its shader's first use), and belt_items.gd writes every item again each time a kind is
    dressed, so trickling them made the belts' first load take 72 s instead of 22-23.
  - `--warm-shaders=loaded|all|off` (loaded): shader_warmup.gd uses the world's shaders once while the
    client starts (1.7 s before the menu or the connection): each on a tiny box and a one-instance
    MultiMesh for four frames, the ground's layout with the terrain and water materials. A shader's
    variants compile on worker threads from when it is loaded, and the first material using it waits
    for them (on this 4-core PC, with the server, the belt worker and the join's own jobs on those
    threads, that wait was the 53 ms of the first item kind, the 120 ms of the first robot, the 100-115
    ms of the first chunk's clutter, the 59 ms of the character, the 89 ms of the first textured
    ground). Warmed, every one of those is under 3 ms; the join had 88-107 frames over 33 ms, 4-9 over
    100 ms, none of the named ones left (two runs; against 102-132, 8-13 and the named ones at 130-310 ms
    without; the frames left are the renderer's own, belt_items.gd's, chunk builds). `loaded` takes the shaders the
    scripts have loaded (all 35 spatial ones here, as the world's scripts preload them), `all` every
    spatial shader in res://shaders. The first run with the warm-up on had the worker threads busy for
    half a minute into the join (the models, clutter and terrain came 29 s late, the belts' first load
    took 80 s): its new pipelines (every shader on a MultiMesh) compiled in the background and went into
    Godot's pipeline cache; the runs after found them there. Not settled whether that was the cache's
    first fill or another process on the PC. With main's `--pipeline-warm` (pipeline_warm.gd, below) both
    run and don't overlap: this warm-up is the shaders' own compile, once while the client starts, on a
    box's vertex layout and the ground's; pipeline_warm.gd warms each model's own (shader, vertex layout)
    pipelines far under the world as the model arrives, and its keys are those layouts, so the two don't
    compile the same pipelines and neither holds the other's instances. The join's "Preparing models and shaders"
    screen (`--join-warm`) waits only on pipeline_warm.gd's.
  - Still there, measured and named: the renderer's own frames in the first 15 s (40-160 ms, no
    pipelines compiled; the probe can't see into the renderer), `MultiMesh.mesh =` on a kind with
    instances (7-27 ms, `w_ic_d_mesh`), the first chunk's MultiMeshes (50 ms, `c_us_build_apply`), a
    model's levels of detail finished in one go (up to 50-107 ms, `w_lods`), message handling (`before`,
    30-70 ms: the `welcome`, `ih`, `mv` and `bs` messages over 8 ms each are listed in the probe's
    STUTTER lines). The belts' first load (`bs ld` done) varied from 22 to 89 s between runs of one and
    the same setting here (the belt worker's jobs fewer and longer in the slow ones), so a first-load
    time from one run says little; the belts' live visible and phantoms were 96.1-96.2% and 2.3-2.6% in
    every run, before and after.

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
- `--belt-sim-ahead=N` (`auto`; was 24, and 1 before `--belt-draw-early`): the simulation runs N ticks past the drawn
  tick, what it says happens after that tick waiting for the next job. 0: stepped to the drawn tick, so items a
  read moved or put on a lane on that tick are drawn from their old records until the next job. `auto` (the
  default): at least 24, and at least the last job gap and 6 ticks (E46: a 24-tick lead under a 30-tick job gap
  left the stops and starts of the gap's last ticks to a job late, drawn a job's travel off); never past the
  newest update, as before, so it needs the drawn clock far enough behind the game (`--belt-draw-lead-lag`).
  `--belt-sim-ahead=24` is the lead as before.
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
- `--belt-sim-take-first=off`: an inserter's take (`ie`, `--inserter-handoff`) and the bridge's read of its lane
  are applied in the order they came, as before. The bridge sends `bs` before `ie` in a tick, and the mod sees a
  pick at its check, up to a tick or two after the hand closed, so the read of the pickup lane on the take's tick
  often came first: it found the taken item missing behind its own items (or the lane empty) and pushed it back
  out of the lane as one the simulation had run on into it (`_rescue`): the taken item stood again at the start
  of the belt, the items behind it pushed back with it, and the take then found the lane read and did nothing
  (owner, K9). On (the default): a read first makes the takes queued for its belt up to 3 ticks on, of the items
  it hasn't on its lane (each take's own choice, nearest its hand), gone on the take's tick; a take that comes
  after a read as of its tick takes the item that read moved instead (the items behind it stay where the read
  put them then). The character's F pickups off belts go the same way (takes with no inserter). Both alike
  (`take_first`; belt_sim_native_test.gd's `take before read` pass, the UI test's `_belt_take`).
- `--belt-sim-take-line=off`: as before, what the bridge sent was applied in the order it came, tick by tick,
  and a take took the item nearest the hand. The bridge sends an update's lane reads before the tick's hand
  events, so on a take's own tick the reads came first; the read of the lane behind the pickup lane found its
  items a step on (the line closing the hole) and moved the packed run in front with them, the taken item too,
  across the belt's edge; the take then found its belt read and the item no longer on it, and did nothing. The
  item stayed, the line behind it a gap out, and every later read of that line moved long runs a whole gap one
  way or the other (a quarter tile, dozens of items at once, a line's front items past its end) until they
  agreed again (owner, K19: "belt items all of a sudden jump around", an inserter taking from a line backed
  up to its end). On (the default): what is queued is applied by tick, a tick's takes before its reads; and a
  take takes the item its belt's next read hasn't when that read has come already (the bridge reads a hand's
  belt when it sees the hand changed), the nearest the hand otherwise: a pick stamped two or three ticks after
  the hand closed carries the hand's place that far into its swing, nearer the neighbour. Both alike
  (`take_line`; belt_sim_native_test.gd's `take at a line's end` pass, the UI test's `_belt_line_end`).
  `tools/belt_line_end.py` makes the scene (a line that ends, backed up, inserters taking from it) and plays
  the bridge offline; `tests/belt_bs_replay.gd --every-tick --ie-wire=0 --sim-dump= --belt-draw-dump=` replays
  it with the hands' events reaching the job as on the wire (the capture's own order hands them over an
  update early, which hid the fault), and `tools/belt_jumps.py` counts what jumps: the simulation's items
  against the game's, and what is drawn tick by tick (things appearing or vanishing off their motion, game
  items unseen, phantoms). Its `--hands-radius R` sets the bridge's f3d-detail-radius so only the inserters within
  R tiles of the focus send `ie` (live: those past the hands radius send none), the rest seen only in the bridge's
  lane reads: `--belts 40 --queue 36 --take 25 --feed 6 --ticks 2400 --hands-radius 4`, replayed with
  `--view=-4,4,52,13` and scored by `tools/belt_quirks.py --every 30`, draws stop-and-go lanes standing (E46).
- `--belt-sim-take-edge=off`: a take looks for its item on its belt's own lanes only, as before. A take made
  late (the hand's `ie` pick comes a few ticks after the hand closed) at a belt's front edge found nothing:
  the simulation had run the item on over the edge onto the next belt. The read of that belt's lane, without
  it, then put it back at the lane's entry (read_conserve: the game's hasn't arrived yet), where it stood in
  for nothing and joined the queue's tail. On the line-end scene (`tools/belt_line_end.py`, seed 1) item 168,
  taken at tick 102455, lived on for 372 ticks and left the items behind it a gap off. On (the default): the
  take looks that far past its belt's front edge too, on the line running on from it, as far as the lanes ran
  since the take's tick (and TAKE_LEAD's three ticks of slack), and among what a read of the lane ahead
  moved back to its entry when the reads came an update before the pick. On that scene, both twins alike: item 168 gone
  on its tick, simulated items the game hasn't 328 -> 80 (item-updates), drawn phantoms 0.12% -> 0.04%
  (`tools/belt_jumps.py`; things appearing or vanishing off their motion 282 -> 266), `tools/belt_quirks.py`
  phantoms 10 -> 3 item-s and jumps 3 -> 0. `take_edge`; belt_sim_native_test.gd's `take at a belt's front
  edge` pass.
- `--belt-sim-rescue-seen=off`: a read put every simulated item it hasn't, behind its own items (or all of them
  when it has none), back out of its lane behind it as one the game's has yet to reach, as before. Past the
  bridge's hands radius no `ie` comes, so an item an inserter took was put back by each read without it and lived
  on as a phantom (the line-end scene with `--hands-radius 4`: item 305, taken over b36, pushed back by four empty
  reads of b36 and b35, joined the queue's tail for good). On (the default): an item isn't put back into a lane read
  as of that read's tick or later without it (the whole update's reads count, a pickup belt's and its feeder's
  either way round), nor further back than a gap behind where the bridge last read it, nor a third time with no
  read listing it in between (RESCUE_STRIKES); it goes. A take that comes late still finds it (`_take_rescued`).
  On that scene, off / on (and `--belt-sim-read-conserve=off` for comparison): `tools/belt_quirks.py --every 30`
  phantoms 7.93 / 1.86% (1.77%), missing 0.69 / 0.75% (0.77%), jumps 403 / 57 (36); simulated items the game
  hasn't 1206 / 166 item-updates (158). The control without `--hands-radius` is unchanged (0.72%, 0.50%, 36).
  `rescue_seen`; belt_sim_native_test.gd's `rescue seen` pass and a synthetic world with it off. Not behind the
  switch (a fix either way, both twins): a read listing one unique id twice keeps the first only, and a late take
  takes a rescued item only if it is still on a line (`_take_rescued`'s `_uid_line` guard); before, such an item
  could be taken and handed out twice. So `=off` is the old rescue, not the old code exactly.
- `--belt-sim-ug-guard=off`: an underground's hidden tunnel lane the bridge sends no next for (`lm` next 0: an
  entrance with no exit) links by geometry like a belt, as before: with no entrance at its end it side-loaded onto
  the straight belt beside its exit. On s272_out an express underground's tunnel (lane 35360348) fed a turbo belt
  half a tile west: items the game held at the entrance ran 14 tiles down that belt and stood at its end as
  phantoms, taken back by each read of the entrance and let go again. On (the default): a tunnel's geometric next
  is only another underground's visible half, a tunnel never side-loads, and an entrance whose tunnel leads
  nowhere ends at its own end (the game's items stand there). Zoomed out at -272,-14 (owner's settings) phantoms
  1.38% -> 0.76% of the game's items in view (on the item lanes 12,895 -> 6,575 item-s), missing 0.28% -> 0.26%,
  counted jumps 525 -> 421 a second. Both alike (`ug_guard`; belt_sim_native_test.gd's `underground tunnel with
  no next` pass).
  A tunnel the bridge names an exit for (`lm` next the exit's line, or minus it when the exit is outside what is
  sent) leads on whether its exit is loaded or not: its items go into the tunnel and stand at its end or leave by
  the out edge, as the game's do. (Till fix/ug-guard-edge it led on only with the exit loaded: an entrance whose
  exit was outside the square was a dead end, its items held at the entrance; belt_sim_replay.gd on the default
  fixture 0.879% off on `underground hidden`.) The dead end is for next 0 alone (an underground with no exit),
  and only where the lanes' next says so (`next_named`, on): belt_sim_replay.gd's recordings carry no `lm` next
  (a tunnel's 0 there says nothing), so it runs with `next_named` off, 0.000%. Zoomed out at -272,-14 (owner's
  settings) phantoms 1.32% off -> 0.72% on, missing 0.25% -> 0.23%, jumps 475 -> 375 a second. Both alike
  (belt_sim_native_test.gd's `underground's named exit`: exit later, exit outside, exit not loaded, next unknown).
- `--belt-sim-hold=off`: the bridge's `sh` ignored. On (the default): a splitter's input the bridge found as
  its last read left it is put back so and held (its items don't cross into the outputs) until its next
  read (`hold_input`). Both alike (`hold_inputs`).
- `--belt-sim-split-wake=off`: splitters let an item through whenever the belt rules say. On (the default):
  a splitter side that let an item through one or two ticks ago (three, while its other output moves) takes
  its turn before the belts that start moving this tick, as the game's update order does: an output that
  stood last tick and has room only once its items moved on this tick takes nothing from it that tick
  (docs/BELT-RULES.md section 6). Both alike (`split_wake`).
- `--belt-sim-dead-walls=on` (off by default: as before): a lane that leads nowhere in the simulation (no next by
  geometry, none named, not side-loading, not a splitter's input) though the bridge didn't say it leads out of
  what is sent (`lm` next 0) is walled as such a lane is (`set_wall`) by a read that finds its front item where
  the read before did: the game's front stood there, short of the lane's end, behind an item on a belt that
  isn't sent; any other read of it takes the walls away (its front runs to its end, `EDGE_STOP`, as before). At
  -62,-26 the bridge sent a bus's last belts (165697 .. 165721, lm next 0) without the belt they feed, and
  marked 165737 next -1 though 165729 was sent: the simulation pulled the front up to the lane's end, each read
  put the packed line back a fraction of a gap and the line behind ran on again. Offline (the restart capture,
  `tests/belt_bs_replay.gd --every-tick=60 --job-every=30`, `tools/belt_quirks.py`) items jumping over half a
  tile 193 -> 39 a second, phantoms 1.69 -> 1.14%. Off by default: the bridge's `/f3d-bs lane_next` fixes the
  marks themselves. Both alike (`dead_walls`; belt_sim_walls_test).
- `--belt-early-bs=off`: `bs` parts that come before the world is ready (the bridge's welcome done, the
  prototypes known) are dropped, as before. On (the default): they are held (up to 4,096) and handed to the
  belt layer in order once it is. The bridge loads lanes from the hello on and sends each lane's meta (`lm`)
  once, when it loads it: a dropped part's lanes were read and checked from then on but never placed (two
  of five captures at -62,-26: a turbo underground and curve beside the character empty for the whole run).
- `--belt-sim-ask-unknown=off`: a lane read (`sl`) or checked (`pc`) whose meta never came is left out, as
  before. On (the default): it is asked for again (`bre`, at most every 3 s), which the bridge answers with
  its meta, as docs/PROTOCOL.md's `bre` says. Covers updates lost on the way too (UDP): a capture at
  -272,-14 lost three updates during the first load and with them 187 lanes' meta.
- `--belt-sim-removed-now=off`: a belt Zenith takes away keeps its lanes and items until the bridge's `dl`, as
  before (K22: "breaking a belt with items shows the 3d items in the world for a while": the `dl` came with a later
  update, and a dropped lane's items then stood up to 40 jobs for far icons that never come inside the square). On
  (the default): main.gd tells the belt layer of every belt removed (`mnd` with the entity gone, `del`) and built
  (`add`); the next job takes a removed belt's lanes out of the simulation and its items out of the drawing and the
  lattice, gone at the drawn tick (an item whose motion changes within the simulation's lead goes when the drawn
  clock reaches that change, at most 24 ticks), and passes over the bridge's reads and checks of those lanes still on
  their way (10 s, or until their `dl`). A belt built on its tile before that job (a fast-replace: `add` and `del`
  together) keeps them: the bridge's `bs` hands the items to the new lanes. Both simulations alike, both records
  paths (the UI test's `_belt_removed`).
- `--belt-sim-replace-at=off`: a lane the bridge drops (`dl`) goes the moment its update comes, as before. On (the
  default, with `--belt-sim-read-apply`): one dropped in the update that brings a lane of the same place (exit and
  entry: a belt fast-replaced, yellow by red, say) goes at that lane's read tick, as the simulation gets there, so the
  game's items, which stay on the belt, carry on onto the new lanes. Before, the update came a few ticks ahead of the
  simulation: the replaced belt's items left it then and came back on the new lanes at their read (in the UI test, 4
  frames gone). Both simulations alike (only when `drop_lane` is called changes).
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
- `--belt-draw-view-ground=off`: the camera's ground view for `--belt-draw-view` is cut 160 tiles along
  each corner ray from the camera, as before. On (the default): each ray is followed to the ground however
  far it goes, and the view is cut to the simulated square instead, since no simulated item lies outside
  it. Zoomed out (the camera 140 tiles back at 40 degrees, the owner's screenshot), the cut view ended
  about 31 tiles north of the character while the screen showed 112 tiles. The belts in between are inside
  the square, where lane icons are left out (`far_lanes` or not), so they were drawn empty: the mid-range
  gap. Live at -62,-26 with belt_distance 128, item_models_max 20500 and view_radius 10, the game's items
  on screen within 128 tiles with neither an item nor an icon went from 6.25% (12.4% at 64-96 tiles, 46%
  at 96-128) to 0.09%; `/f3d-perf far_lanes off` didn't fill it (icons 0.0-0.1% inside 96 tiles).
- `--belt-draw-view-lead=on`: the job's view is stretched ahead of the camera's own motion, as far as it goes in
  two jobs' time (48 tiles at most). Off (the default): as before. Walking close up at -62,-26 (camera 12 tiles
  out) the screen's leading edge ran past the records planned for it in two runs of three: 1.65% and 2.37% of the
  game's items on screen had neither an item nor an icon, against 0.02% in the third. With the lead on it was
  0.12% and 0.04%, but a job had 14-22% more records and more counted jumps (32 -> 58 and 30 -> 49 a second; the
  walk check's phantoms 0.7% -> 1.3% and 0.7% -> 0.8%). Left off until the gap is caught again.
- `--belt-lanes-dump=<file>` (a diagnostic): the lane icons as made and dropped, the icon shader's square
  and distance, and the camera's whole ground view every 250 ms (with the frame rate), for
  `tools/belt_quirks.py`'s gaps by distance (items, icons or neither).
- `--belt-draw-dump-parks=off`: the draw dump leaves out a parked item's record going (`--belt-draw-view`: an
  item whose motion can't show is parked and its slot hidden), as before. Its readers (belt_view_check.py's
  DrawState: the live score, belt_quirks.py, belt_jumps.py) kept drawing the record the GPU had hidden,
  standing where its motion ended, and counted the next record a jump. On (the default): a park is dumped as
  the record's going. Both drawing paths alike (belt_draw_diff.py; the twins' going lists equal job by job on
  a replay with a drifting view). Walking close up at -62,-26 the counted jumps went from 38.7 to 32.4 a second.
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
  piles do (texel 3: the slot from the copy, its step k, the kind's pile step; each copy turned PILE_TURN
  more than the one under it, cards and blocks too). The shader reads the slot's texel 3 for a copy, so
  copies slide with their slot and aren't hidden by the lattice's mask.
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
- `--belt-draw-lattice-settle=off`: as before, a standing lattice took its lane's new speed at once. A take
  from a backed-up line moves every item behind it one gap on, and they stand again: a row of one kind a
  whole gap on is the same picture, but each lane's lattice went to the map's phase (up to 0.125 tile from
  where it stood), slid for an update or two, stopped wherever that left it and was set again at the lane's
  next read or check, so the whole line behind the hand jumped an eighth of a tile twice at every take (K19).
  On (the default): a standing lane takes a new speed only once the simulation has had it moving for more
  than two gaps' time (16 ticks on a yellow belt: a line that really flows); its standing phase is the
  simulation's standing front item's (a read made mid-way through the closing gave a phase part of a gap out
  until the next); a lane that comes to be drawn while it moves waits as long (drawn from the simulation
  meanwhile); and the hole a take leaves in a standing lane closes once the drawn clock is a gap's time past
  the take (it stayed open for as long as the lane stood full). belt_lattice.gd and BeltLatticeNative alike
  (`tools/belt_draw_diff.py`: 0 differences). Measured on `tools/belt_line_end.py`'s scene with
  `tools/belt_jumps.py` (3,000 ticks, 81 takes, both K19 switches): things drawn that appeared or vanished off
  their motion 2,253 -> 343, the most in one tick 135 -> 8.
  With per-item turns (`--belt-draw-lattice-turns`) a lane that starts or stops keeps each item's turn;
  through a one-gap closing the lattice stands, so each place keeps its turn.
- `--belt-draw-lattice-creep=on` (off by default: as before, a standing lattice lane moves only when the simulation's front
  item on it moves (and, with settle, only after two gaps' time of steady motion). On a creeping lane (an
  inserter's pickup belt, a merge, a line behind them: its items move up a gap and stand, again and again) the
  front item waits at the exit while the items behind it close up, so the whole lane was drawn standing for
  seconds while the game's items moved on (the owner: "items on belts sometimes hold in place for like 10
  seconds or groups of items")). On: each drawn lane keeps a running share of the time most of
  the simulation's items on it move (`lane_fronts(keys, 1)` in both simulations: the speed most of a lane's
  items move at), over 2 s (CREEP_TAU 120 ticks, in 1/1024: integers, so both twins agree); a standing lane
  whose share passes 25% slides on from where it is drawn at that share of the belt's speed, below 10% it
  slides on to the simulation's standing front's phase and stands there (no jump either way), and once the
  simulation has it moving steadily for four gaps' time the usual rules take the belt's speed. A single
  take's closing (K19's case) stays under the threshold: on `tools/belt_line_end.py`'s scene
  `tools/belt_jumps.py` counts the same 282 things appearing or vanishing off their motion with it on as
  off. belt_lattice.gd and BeltLatticeNative alike (`tools/belt_draw_diff.py`: 0 differences). Off by default:
  live at -62,-26 with 57 pickup inserters stopped over the settle and restarted while recorded
  (`tools/belt_quirks.py`, 30 s at 2 Hz), lanes drawn standing while the game's items moved fell from 23.2%
  of the item-seconds in view to 2.7% (spans of 8 s or more 1721 -> 378, tools' holds count), but the
  simulation moves many lanes the game holds (into splitters, between reads), and those slid: lanes drawn
  sliding while the game's stood 4.2% -> 16.5%, lattice hops 478 -> 1610 a second, visible 97.1 -> 96.4%,
  phantoms 1.7 -> 1.8%. Before it can be on it wants a test that a lane's items really flow through it (its
  front item changing to new ones, or the bridge's reads showing the game's lane moving).
- `--belt-draw-lattice-creep=flow` (off by default; `on`: by the share above): a lane creeps by
  the net distance its items go on past its exit. `lane_fronts(keys, 2)` (both simulations: as 1, with the front
  item's unique id, its low 31 bits, for the count) gives each drawn lane's front item each update; one the lane
  hasn't had in front (of its last 16) is a gap on, one it had a read putting the items back, a gap back for each
  front since. The running rate (1/256 a tick in 1/1024, over 120 ticks) at 300 or more has a standing lane slide
  on from where it is drawn at that rate (at least 1/256 a tick), under 100 on to the simulation's standing
  front's phase and stand. Its new motion starts at the drawn clock's tick where it is drawn then (set at the
  simulation's tick, the lattice jumped by the change of speed times the drawn clock's lag: lattice hops 1178 ->
  486 a second offline). A lane the simulation has none on stands where it is drawn (creeping: at once; at the
  simulation's speed: after 30 ticks; it went on as it was for good). A lane at the simulation's speed for 120
  ticks whose net rate is under 1000 (about a gap in 16 ticks) stands and takes the simulation's speed again
  only with that rate: the simulation runs on lanes the game holds, and at -62,-26 the lines into a balancer
  let go and were read back again and again, the same fronts coming back with each read. Offline, the restart
  capture replayed at the live cadence (`tests/belt_bs_replay.gd --every-tick=60 --job-every=30`,
  `tools/belt_quirks.py`): lanes drawn standing while the game's moved 3.2% (settle alone 19.1%, the share 2.7%),
  sliding while the game's stood 3.2% (4.7%, 17.3%), frozen spans of 5 s or more 0 (133), hops 420 a second
  (538), jumps as settle's; but phantoms 3.0% (1.7%) and missing 2.2% (0.8%): a creeping lattice's phase lies
  between the game's stop-and-go rest positions, so at a lane's ends a slot and an item go unmatched while it
  creeps. belt_lattice.gd and BeltLatticeNative alike (`creep_flow`, `set_creep_flow`; `tools/belt_draw_diff.py` on
  the restart capture with it on: 207 jobs, 3.96M records, 0 differences). Live, off (the default) against flow,
  `tools/belt_quirks.py` in the client's own view: standing at -62,-26 (Hold 60 UPS, 20 s) lanes drawn standing
  while the game's moved 28.9 -> 1.7%, spans of 8 s or more 303 -> 0, sliding 2.3 -> 2.5%, hops 664 -> 561 a
  second, jumps 66 -> 44 a second, but belt_view_check's visible 97.1 -> 95.7% and phantoms 1.0 -> 2.4%; at
  -272,-14 frozen 5.1 -> 0.3%, spans of 8 s 10 -> 0, sliding 1.3 -> 1.7%, visible 98.0 -> 97.8%, phantoms 0.3 ->
  0.7%; zoomed out at -62,-26 with the owner's settings (Cinematic, shadows ultra, belt distance 128, 20500
  models, view radius 10, camera 0,40,140) frozen 21.6 -> 0.9%, spans of 8 s 138 -> 0, sliding 2.2 -> 4.1%,
  phantoms 1.1 -> 2.3%, hops 2061 -> 1574 a second; the restart test (57 pickup inserters off over the settle,
  on 6 s into 30 s): frozen 22.0 -> 2.0%, spans of 8 s or more 1285 -> 5 (the holds count), sliding 5.1 -> 3.9%, hops 1481 -> 828 a
  second, jumps 27 -> 36 a second, visible 97.2 -> 95.7%, phantoms 0.7 -> 2.3%. What flow leaves unmatched at -62,-26 is near: of the game's items on lattice
  lanes with no drawn item matched, 99.9% have one of their kind within 0.25 tile (33% within 0.1), of the
  slots matched to nothing 95% lie within 0.25 tile of a game item on their lane (the one-to-one match within
  0.15 counts them; the picture shows a packed lane a fraction of a gap off). K19's line-end scene: 282 things
  appearing or vanishing off their motion by default, 593 with flow; the extra 311 are lattice slots at lane
  ends (a creeping lane's slot leaving its end with the next lane standing), 0.1-0.3 tile from the nearest of
  their kind the tick before (the default's 282 have a median of 0.25 tile, 96 over 0.4).
- `--belt-draw-lattice-creep=step` (off by default; `off` and `flow` unchanged; E46): a standing lane steps
  instead of creeping. It stays at the game's rest phase (settle, standing_obs) and stays a standing lane for the
  mask (flow masked a creeping lane end to end, hiding the simulation's standing items past its ends). Each new
  front item on it (`lane_fronts(keys, 2)`, the history flow keeps) queues a one-gap slide at the belt's speed
  through close's slide (`slide_at`, `slide_v`, `slide_more`, at most 4 queued), timed to the tick the items moved:
  from the new front's place while it moves, else half way between the last update and a slide's time before this
  one. Several takes since the last update: while the new front still moves from more than a gap behind its rest
  phase, a slide for each gap behind (at most 5, back to back); once the closing is over by the update, one, as the
  front's place no longer tells and its id doesn't say how many items left between (the simulation's lane fronts
  give only the front item; a count of items leaving each lane would need both simulations to keep one). Picture
  and phase are the same either way (a lattice repeats every gap); a missed gap is a slide not drawn and the items'
  turns a step behind until the lane is written again. On the scenes below no front was ever seen more than a gap
  behind (232 moving fronts on the taker-every-12 one), so the numbers are as before the count. A front a read put
  back drops the slides not yet written. A net rate (flow's) of half the belt's speed or
  more leaves the lane to the usual rules, which take the simulation's speed; a curve whose length isn't a whole
  number of gaps stands, as close has it. A take close slid the lanes behind for (an `ie` hand) isn't slid again
  when their fronts change, nor the other way round (a balance per lane, matched within 90 ticks). Offline on
  K19's line-end scene (`tools/belt_line_end.py --belts 40 --queue 36 --take 25 --feed 6 --ticks 2400`, the replay
  at `--every-tick=60 --job-every=30 --ie-wire=0 --view=-4,4,52,13`, `tools/belt_quirks.py --every 30`), off /
  flow / step: with `--hands-radius 4` frozen 4.66 / 0.39 / 0.27%, frozen spans of 2 s or more 9 / 0 / 0, missing
  0.69 / 1.63 / 0.70%, phantoms 7.95 / 8.20 / 7.96%, hops 139 / 22 / 47; with `--taker-every 12 --hands-radius 4`
  frozen 11.98 / 0.16 / 0.53%, missing 0.31 / 0.92 / 0.36%, phantoms 2.01 / 2.19 / 2.05%, hops 487 / 14 / 146; every
  take sending `ie` (no `--hands-radius`) frozen 0.16 / 2.89 / 0.09%, spans 0 / 2 / 0, missing 0.50 / 1.25 / 0.47%,
  phantoms 0.72 / 0.88 / 0.71%. The cost: lattice lanes drawn sliding while the game's items stood, 0 / 0 / 1.50%
  and 0 / 0 / 4.82% on the hands-radius scenes (0.75 / 0.05 / 0.58% with every `ie`): the simulation learns of a
  take past the hands radius from the bridge's reads, so its fronts change late (slides a median 7 ticks after
  the game's items moved, a tenth over 23), and it runs on lanes the game holds. Owing a gap for each front a
  read put back, so the simulation running on again slides nothing, was measured and left out: on the
  taker-every-12 scene sliding 4.82 -> 3.47% but frozen 0.53 -> 1.43% (the game's own moves owed too). Both
  lattices alike (`creep_step`, `set_creep_step`; `tools/belt_draw_diff.py` 0 differences on all three scenes in
  every mode). Not run live yet (-62,-26, -272,-14). The UI test's `_belt_step_creep`.
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
- `--belt-draw-early-stop=off`: as before. A moving item's record runs on to its line's end (the simulation's
  reach), and a stop after the drawn tick it runs into (it catches up with the item in front) waited for the
  next job: the item was drawn running past the stop and pulled back a job's travel then (E46: batches of 20
  and more items on long straight runs whose front flows in bursts, up to 500 a second zoomed out). On (the
  default): `_apply_early` cuts the record to end where the stop is (the stop itself still waits for its tick;
  both records paths, the same arithmetic). The UI test's `_belt_early_stop`.
- `--belt-draw-lead-lag=N` (60): with `--belt-sim-ahead=auto`, the drawn clock is held up to N ticks further
  behind the game than before so the lead fits under the newest update: its margin is at least two job gaps and
  7 ticks where it was 1.5 job gaps and 1. That is half a job gap and 6 ticks more lag: a job gap of 10 ticks
  +11 ticks (0.18 s), 20 +16 (0.27 s), 30 +21 (0.35 s), so the owner's ~35 ticks live becomes about 51. Items
  on belts are drawn that much later than the game has them (the rest of the world isn't). `0`: the lag as
  before (the lead then reaches only about half a job gap past the drawn tick, so early stop alone does the
  work); a smaller N caps the extra lag. Measured on `tools/belt_bursts.py`'s scenes (turbo, 70 belts, the
  lattice off, a job every 30 ticks), jumps a second (tools/belt_quirks.py --every 30): `--mode out` 305.8 as
  before, 174.8 with early stop, 84.1 with the lead and its lag; `--mode take` 131.1, 98.9, 69.7 (the replay's
  `--every-tick` lag 19 for the old margin, 40 for the new one; at the replays' usual lag 60, out 286.6 -> 92.3 ->
  0 and take 129.3 -> 101.0 -> 101.0, take's rest a read shifting a standing run). The replay's lag swept with
  both on: out 84.1 at 40, 39.8 at 46, 0 at 52 and 60; take 69.7, 102.4, 100.2, 101.0. Out's rest at 40 is what
  the bridge's reads tell the simulation late (the front starting off the square), not the lead: a lag of about
  a job gap and 22 ticks clears it, which this margin (a job gap and 13) doesn't reach. Game items seen and
  phantoms (tools/belt_jumps.py) as before on both scenes (out 98.18% / 0.03% before, 98.23% / 0.01% both; take
  98.49% / 0.24%, 98.48% / 0.09%); the line-end scenes (belt_line_end.py, and `--hands-radius 4` with
  `--every-tick=60 --job-every=30`) jumps 0 -> 0 and 10.2 -> 9.6 a second, seen and phantoms unchanged.
  `python tools/belt_ring.py --out <dir> [--puts 10,17] [--watch 5,12]` makes a moving ring the same way (replayed with
  `--replay-bre` so the client's re-reads are answered, as the bridge answers them live).
  `python tools/belt_bursts.py --out <dir> --mode out|take [--tier turbo]` makes the scenes (its header says how
  to replay and score them).
- `--belt-draw-lattice-world=straight`: as before, only straight lanes and undergrounds' visible halves take the
  map's phase while moving; curves and splitters slide at the simulation's front item's phase. `all` (the
  default): every lattice lane does. Any phase draws a full lane within 0.125 tile of the game's items, but
  where two lanes' lattices meet (a splitter's inputs overlap its outputs by the 51 buffer: an input's exit sits
  0.2 tile into the output half, and the game holds an input item and an output item at the same spot there; a
  curve's last slot reaches past its entry) their phases must agree, or the check's one-to-one matching leaves a
  game item without a slot and a slot without an item. On a backed-up balancer the simulation's front is a tick
  or two off the game's (32-64 at turbo speed), and a lane once moving was never re-phased on a speed change: at
  -62,-26 one game item in ten on splitter lanes had no slot within 0.15 tile and 7% of the slots there were
  phantoms (scratch decompose.py over the belt-rate round's recorded runs).
- `--belt-draw-lattice-standing=world`: as before, a standing lattice (the simulation's front on the lane
  standing, or none there) takes the map's phase on straight lanes and the simulation's front's on others. `obs`
  (the default): the bridge's last read or check of the lane (`sl`, `pc`: its front item's position mod 64), where
  the game last showed its items; set again when a new read or check differs. A standing lane's items are exactly
  there until it moves; the map's phase was up to 0.125 tile off (a run backed up at phase 32 sits at the check's
  limit, and the greedy matching then takes a neighbour's slot), and a standing lattice at a high phase has one
  slot fewer than the lane's items. A lane stopping keeps the phase it was drawn at until its next read or check.
  Emulated on the recorded dump (the slots re-placed and re-scored): as drawn 96.35% visible / 1.68% phantoms,
  the map's phase on every moving lane 96.75% / 1.25%, with the observed phase on standing lanes 96.86% / 1.13%,
  the game's own phase on every lattice lane (the ceiling) 97.51% / 0.48%. Measured: see "The belt gap at
  -62,-26" below. Both twins (belt_lattice.gd, BeltLatticeNative) take both switches alike.
- `--belt-draw-lattice-native=off`: the lattice made in GDScript (`belt_lattice.gd`), as before. On (the
  default when the C++ library is loaded and the simulation is `BeltSimNative`): `BeltLatticeNative`
  (`client/native/belt_sim/src/belt_lattice_native.cpp`), belt_lattice.gd function for function, writes the
  same records (`tools/belt_draw_diff.py`: 0 differences between the two on a capture; the dump's `lat_native`
  says which ran). At -62,-26 the GDScript lattice cost 25-70 ms a job (half a second when the view moved and
  every lane was planned again, so walking paid it every few steps); the C++ one 1-3 ms.
- `--belt-draw-lattice-turns=slot`: every lattice slot keeps a turn of its own, as before K14 (owner: "items
  change their orientation as they move on the belts"): a slot slides one gap and wraps back while the slot
  ahead takes its item on, so an item seen sliding along took the next slot's turn every quarter tile. On
  (`item`, the default): each drawn item keeps one turn. A lane's slot k holds who its item is (texel 2 x:
  the lane's `who` + k, texel 2 y: its run's seed, texel 3 z 2) and the shader adds the periods slid since
  the record's clock and hashes both into the turn (belt_path.gdshaderinc `belt_lattice_turn`, item_cards.gd
  `lattice_turn`: the same range as every item's turn and the same pile rule). A lane written again (a new
  speed, its phase made again, its piles) keeps who its items are, each new slot taking the nearest old
  item's as both are drawn when the update is first drawn (`Job.fold_tick`: the drawn clock runs behind the
  simulation, so a lane that stops is drawn jumping by its speed times that lag); a new lane takes them from the drawn lane its items go on into or come from (so an item keeps its
  turn from belt to belt, round corners too), else from the map along its exit's direction. No per-frame CPU
  work; both twins alike (the UI test's `_belt_lattice_turns` compares them). An item still takes a new turn
  where it passes between a lattice lane and one drawn from the simulation (whose items turn by their unique
  ids), and once round a closed loop where the run's identity meets itself.
- `--belt-draw-lattice-mask=ends`: as before, a lattice lane marks the mask's cells along its centre line from end
  to end, so where its entry's point lies on a cell's edge (a lane going west or north) the cell it marks is the
  lane behind's first one: that lane's front item, standing at its exit (line position 0), was hidden while that
  lane was drawn from the simulation (the owner's playtest, K19: an inserter's take from a backed-up line gives its
  lane up for the simulation's items, and that lane's front item was gone from view until it was a lattice again;
  in `tools/belt_build_mine.py`'s mine scene the items standing at the front of each belt of the queue behind the
  gap). On (the default): a standing lane's entry point is taken a 64th of a tile inside it. Its exit's point
  still marks the cell past it (a lane going east or south: the lane ahead's last one), and a moving lane marks end
  to end: with every cell past either end left unmarked, the restart capture at -62,-26 (below) had 2.15% phantoms
  against 1.73% (the simulation's items just past a lattice's exit, where its slots draw the game's). A lane that
  starts or stops moving is marked again. Both twins (`_mark`), and tools/belt_view_check.py's `lane_cells`
  (`BVC_MASK=ends` scores a run made the old way).
- `--belt-draw-lattice-mask=entry`: as before (the default above), a lane's exit point marks the cell past it on a
  lane going east or south (the lane ahead's last cell) and a moving lane's entry point the cell past it on a lane
  going west or north (the lane behind's first). Where that lane is drawn from the simulation (a take's lane given
  up, a lane short of full) its items vanished in that cell as they went through it: a one-item gap fixed at the
  belts' join while the line moved, gone once it stood and was a lattice again (the owner: "after pulling items off
  a full backed up belt these gaps appear and items move past but the gap remains in the spot until it stops
  again"). On (the default, `own`): every lane's ends are taken a 64th of a tile inside it, moving or standing, so a
  lane marks its own cells only. Offline (`tools/belt_bursts.py --mode take --tier yellow --belts 40 --ticks 1300
  --f --takers 2 --takers-from 10 --period 15 --take-window 100,900 --release 300,700`, replayed as below at
  `--job-every=30`): going east (`--east`) 1.16% of the game's item-ticks undrawn against 0.76% (the join's cell
  had 27 items in turn go through it undrawn), phantoms the same but for the run's own exit (items on the
  unrecorded gate belt now shown); going west 0.57% against 0.42%, phantoms the same. Both twins (`_mark`),
  `BVC_MASK=standing` scores a run made with `entry`.
- `--belt-draw-lattice-open=off`: as before, a moving lattice lane marks all its own cells whatever draws the lanes
  beside it. A moving lattice has the map's phase and a line's items whatever phase their history gave them (up to
  0.125 tile apart); where the lane ahead is drawn from the simulation (read short of full: a gap of 67 or more, a
  line fed by inserters or a merge) the game's item at the lattice's exit, its slot already wrapped to the entry (the
  lattice ahead), was hidden by the mask until it crossed: every item vanished for a few ticks at the join, a gap
  standing in the moving line (the owner: "they don't just move in unison"). Likewise at the entry of a lattice
  behind the items, where no lattice feeds it. On (the default, with `--belt-draw-lattice-mask=own`): a moving lane
  more than 4/256 ahead of the simulation's front item leaves its exit's cell unmarked when the lane ahead isn't a
  lattice at its speed, one behind it its entry's cell when none feeds it; the simulation's item shows there beside
  the slots (at most the phases' difference apart, an overlap rather than a gap). A lane in step keeps its cells.
  Offline (`tools/belt_bursts.py --mode out --open 99999,99999 --shut 1,1 --feed --feed-loose 0.1 --tier yellow
  --belts 40 --ticks 2400`, replayed as below): the game's item-ticks undrawn mid-run (belts 2-38) 0.40% against
  0.03% (going east, `--east`: 0.38% against 0.02%); belt_quirks' phantoms 1.36% against 4.01% (the overlaps: a slot
  and the item it stands for both drawn in the open cell), and on a tightly packed line (no `--feed-loose`) 0.19%
  against 1.77% at the run's two ends. Both twins (`_open_ends`, `_mark`; the dump's ids column 7 says a lattice
  lane's open ends, which tools/belt_view_check.py's `lane_cells` follows). In the debug menu's Simulation tab.
- `--belt-draw-handover=old`: as before, with the lattice's open ends (above), the open cell's slot and the
  simulation's item there were both drawn, up to 0.125 tile apart (phantoms 1.36% -> 4.01%). On (the default): the
  slot whose gap reaches into an open end's cell hides while its item is the simulation's to draw there: at an exit
  from where its item comes into the cell, at an entry until its item has left it (the phases' difference at the
  simulation's front item, 3/256 more for a line's items a little off one another; the slot record's texel 3 y,
  read by belt_path.gdshaderinc, belt_view_check and `drawn_lattice`). Offline, the open-ends scene above: belt_quirks'
  phantoms 4.01% -> 2.36% (east 4.11% -> 2.54%; tightly packed 1.77% -> 1.32%), missing 0.39% -> 0.40%, undrawn
  mid-run 0.03% either way; the take scenes unchanged. Both twins, in the debug menu's Simulation tab ("Clean
  handover").
- `--belt-draw-turn-id=old`: as before, a lattice lane's items were who its neighbour's or the map's formula said and
  a simulated item turned by its unique id, so an item changed its turn where a lattice lane met one drawn from the
  simulation. On (the default): the simulation numbers each item along its run when it first comes into a line (one
  behind the item ahead; belt_sim.gd `_num`, BeltSimNative alike, take_changes()' `num`, lane_fronts speed_of 3), a
  simulated item turns by its number (belt_items.gd and BeltDrawNative), and a lattice lane is seeded from the
  simulation's front item on it when written, and again once moving in step for 2 s when its items' numbers have run
  ahead of its slots (not a standing lane, which settle stands behind its run on purpose, nor a ring). Offline, turn
  changes (a game item's drawn turn differing from the tick before): belt_bursts --feed --feed-loose 0.1 5098 -> 2150
  (at a lattice/simulation join 4342 -> 233), east 4551 -> 1790 (4120 -> 157), the take scenes' joins 317-1300 -> 8-22;
  phantoms, missing and undrawn unchanged by it. Both twins, in the Simulation tab ("Items keep their turn").
- `--belt-draw-edge-shut=off`: as before, a moving lattice lane leading nowhere loaded (the square's edge) opened its
  exit like one beside a lane drawn from the simulation, so the simulation's items stopped at its end as a guess
  (EDGE_STOP) showed there, stacked, while the game's ran on. On (the default): an exit opens only where its items go
  on (BeltSim.leads_on: into a lane, a side-load, a splitter). Offline: loose-fed phantoms 2.36% -> 1.56% (most were at
  the run's exit), tight 1.32% -> 0.19%, east 2.54% -> 2.42%; missing 0.40% -> 0.51% and 0.03% -> 0.19% (the game's
  item at the very edge, its slot wrapped a few 256ths early), undrawn unchanged. In the Simulation tab ("Shut edge
  ends").
- `--belt-draw-lattice-close=off`: as before, the lanes behind a take's hole in a standing lane stood while the
  game's line closed it up (with settle, a gap on is the same picture), and the take's lane, given up for the
  simulation's items at the bridge's read, slid alone (the owner, K19: "the items dont slide forward as a group to
  fill the space instead the back item moves into the next one and the front item moves out of the static to
  fill"). On (the default, with settle): a take on a standing lane (or one not drawn) has every drawn standing lane
  behind it (`feeds`, its straight run back) slide one gap from the take's tick at its belt's speed and stand
  again, each slot the item that was behind it (who + 1), as the game's packed line closes up; the take's lane is
  given up for the simulation's items at once. A slide is each slot's record as a moving lattice's with its clock
  held within [the take's tick, a period after] (texel 1 w the start, texel 1 y the periods: 1;
  belt_path.gdshaderinc, belt_items.gd and BeltLatticeNative `drawn_lattice`, tools/belt_view_check.py), so it
  stands before and after wherever the drawn clock is when it is written. While a lane slides its phase isn't
  checked (a read of it mid-way through the closing, the UI test's, put it standing at the read's place and the
  slide was lost). A lane whose standing slots aren't a moving lane's (a curve whose length isn't a whole number of
  gaps) stands as before; a second take while a lane slides closes after the first (`CLOSE_MORE` more at most); a
  take on a lane while it slides hides the slot that holds the hole as the slots wrap. The UI test's
  `_belt_line_end` checks it (the lanes behind drawn 0.117 tile off their places mid-way, back on them after).
- `--belt-draw-lattice-sim-full=off`: as before, a moving lane stays a lattice while the bridge's last read or
  check found it full: a belt mined out of a packed moving line left the belts in front drawn full and moving until
  the bridge's next drift check (the owner, K22: "the belt in front stays full as it moves forward instead of
  emptying immediately few seconds later it shows the empty spaces"). On (the default): for `FED_GONE_TICKS` (30 s)
  after a belt behind a lane was removed (belt_items.gd `_feed_gone`: a lane dropped two tiles or more inside the
  bridge's square, or a belt Zenith removes; the lanes it led into, on along their run to a splitter), a moving
  lane the simulation has items on but fewer than a full lane's is given up (its full forgotten until the bridge's
  next read or check says so again). Only there: the simulation is often short of the game on packed lanes (what
  the lattice draws them for), and a lane fed from outside what is sent empties in it between the bridge's reads;
  with every lane the simulation had short given up, the restart capture had 6.1% of the game's items in view
  missing (0.8%), and the far end of `tools/belt_build_mine.py --source` flapped every 24 ticks.
- `--belt-draw-lattice-tail=off`: as before, a moving lane a packed block had filled stayed a lattice after the
  block's tail had passed it, till the bridge's next read or check (on a ring with a packed block going round,
  `tools/belt_ring.py`, the lanes it left were drawn full about 100 ticks more). On (the default): a moving lane the
  simulation has short of full, or any lane it has no items on, is given up when the simulation's line behind its
  entry holds nothing for two gaps on lanes it knows all that feeds (`BeltSim.lane_tails`: not a lane fed from outside
  what is sent, the square's edge, a side-load or a splitter, where the simulation empties between reads).
- `--belt-draw-lead-max=N` (32): the most ticks a job's lead is (how far ahead a record that ends is made again, and
  how far a path across its end reaches); 8 as before. A busy client's jobs (every 30 ticks) had their lead held at
  8, so an item whose record ended at a curve stood there up to 22 ticks and jumped on (the ring: 20 jumps a second).
  `tests/belt_bs_replay.gd` sets each job's lead as the client does from `--job-every` (`--job-lead=N` to fix it;
  before, it was always 2).
- `--belt-draw-lattice-start=off`: as before, with settle a standing lane takes a new speed only once the
  simulation has had it moving for two gaps' time, then from the map's phase: a belt built at a backed-up line's
  end had the line's packed belts stand for 16 ticks (yellow) while their items ran on onto it (drawn from the
  simulation there), each belt's front slot left standing at its exit and a gap opening behind the new belt's items
  (the owner, K16: "there is a bit of a gap between the new belt items and the previous also leaves some ghosts at
  the end where it is pulling forward from for a few seconds"). On (the default, with settle): a drawn lane whose
  next lane is new (the simulation's `links_ver` changed and its `next_of` with it: a belt built in front of it)
  lets its straight run back go for `RELEASE_TICKS`: each standing lane of it the simulation then has moving starts
  at once, from where it stands, on the tick its items started (its record's clock held there before, texel 1 w).
  Other starts wait as settle has them, from the map's phase (every start from where it stands cost the restart
  capture 0.4% more missing and as many phantoms: its neighbours keep the map's phase).
  `--belt-draw-lattice-start=stops` (off by default): a moving lane the simulation has standing also goes on to the
  tick its lattice comes to the standing front's phase and stands there (its clock held after: texel 1 y the
  periods from its start), standing in the lane's state once the drawn clock is there; moving again before that, on
  from the tick its items went on. On the restart capture lanes drawn standing while the game's moved 19.0 ->
  13.4% of the item-seconds in view, frozen spans of 2 s or more 1546 -> 927, lattice hops 554 -> 264 a second,
  but sliding while the game's stood 4.9 -> 7.2%, phantoms 2.15 -> 2.34% and missing 0.83 -> 1.04% (the
  simulation runs on lanes the game holds, which the stop at once, ahead of the drawn clock, hid).
  Measured offline, the four switches together against all four off (each scored with its own mask; both twins
  alike, `tools/belt_draw_diff.py` 0 differences on each scene and on the restart capture):
  `tools/belt_line_end.py` (K19, seed 1, 3,600 ticks, 63 takes): game items seen 99.35% -> 99.99%, things
  appearing or vanishing off their motion 266 -> 164 (`tools/belt_jumps.py`), missing 0.65 -> 0.01% of the
  item-seconds (`tools/belt_quirks.py`; on the take's lane 13.6 -> 0.3%); `tools/belt_build_mine.py --scene
  extend` (K16, a belt built at the end of a line backed up 16 belts, another 120 ticks on): seen 98.97 -> 99.98%,
  appearing or vanishing 91 -> 82; `--scene mine` (a belt mined out of a moving line, not packed): seen 95.54 ->
  99.91%; `--scene mine --source --spacing 64` (K22, a packed moving line): phantoms 2.06 -> 0.16% of what is drawn
  (44 a tick at the worst, the belts in front drawn full -> 25 at the mine), seen 99.84 -> 99.67% (the belts given
  up beside moving lattices, whose cell past the exit hides the item just past it). The restart capture at -62,-26
  (`tests/belt_bs_replay.gd --every-tick=60 --job-every=30`, `tools/belt_quirks.py`): all four on as the old way within noise: lanes
  drawn standing while the game's moved 19.2 -> 19.0% of the item-seconds in view, sliding 4.7 -> 4.9% (the
  closings' slides), phantoms 1.72 -> 1.73%, missing 0.84 -> 0.84%, holes 0.29 -> 0.28%. Live (Hold 60 UPS,
  tools/belt_view_check.py, tools/belt_walk_check.py): -62,-26 97.2% visible / 0.9% phantoms, -272,-14 98.1% /
  0.3%, walking at -62,-26 99.4% / 0.8% (before: 97.1 / 0.9, 97.7-98.0 / 0.3, 99.3-99.4 / 0.8-0.9).

The 0.2.1 performance hotfix's switches (art-src/perf-plans/belt-sim.md section 6; all client-only, both records
paths alike). Its counters go into belt_items.gd's `stats`, so the stutter probe's `join.belt_stats` shows them:
`later` (changes waiting after the last job; `later_max` the most), `waiting` (items with changes waiting, with
`--belt-draw-later-tick`), `early_tries` and `early` (early tries and takes, summed), `drained` (items whose
waiting changes a job looked at), `ask_view` / `ask_lat` / `ask_out` / `ask_unknown` (lanes asked for again,
`bre`, by why: a failing check in view, on a lattice lane, out of the planned view, meta never come) and
`ask_held` (failing checks not asked for, for their interval), `slots` (item slots in use, piles' copies too) and
`slots_hidden` (of them, the slots of items whose motion lies on lattice lanes all along: hidden by the mask in
every frame), `parked_view` / `parked_lat` (parked items by why), `lat_lanes` and `lat_slots` (the lattice's lanes
and slots), `lat_parks` / `lat_unparks`. The slot and parked counts are taken every 16th job (on the GDScript path
only while a probe runs or with `--belt-draw-dump`); the dump's job lines carry them too (`asks`, `gauges`).
- `--belt-draw-later-tick=off`: the changes that take effect after the drawn tick wait in one list, as before,
  every one looked at and tried early (`--belt-draw-early`) every job, with a hash set made from nothing each
  time: half the worker's time at the owner's base (about 35,000 waiting, 34 jobs a second). On (the default):
  kept by item and filed by the tick they take effect at (`belt_draw_native.cpp` `_drain_due`, belt_items.gd's
  twin). A job takes the items whose first waiting change is due, and tries early again only an item that
  changed since its first was tried (its record planned, parked, unparked; a start waiting for the item's own
  tick, once the drawn tick is there), or every waiting item when the lanes' links may have moved (a lane's meta
  changed or one dropped, a relink since the last job or one pending: an early take walks the lanes ahead). Any
  other try would fail as the last did, so the takes are the list's, item by item, and the records the same
  (`tests/belt_bs_replay.gd` on three offline captures, both twins, off and on: 0 differences in
  `tools/belt_draw_diff.py`). The simulations' new `links_ver` and `links_pending()` tell the drawing when links
  moved; the coalescing map is kept between jobs; both twins take the items in order of their ids, so they hand
  out slots alike. Offline (at most about 5,000 changes waiting, against about 35,000 at the owner's base) early
  tries fell 55% and the C++ job's applying 17%; the GDScript twin's applying rose 28% there (its fallback may
  want it off).
- `--belt-draw-skip-same=off`: every job is given a fresh copy of the kinds' looks and a fresh list of the far
  icons' chunks (`belt_lanes.gd built_chunks()`, a dictionary of every far chunk, which the C++ side made into a
  set again), the far icons are handed the square every result (every icon material's parameters set), and
  `f3d_belt_lattice_on` set every result, as before. On (the default): each only when it changed
  (`belt_lanes.gd chunks_ver`, belt_items.gd's own count of its looks' changes); the native records keep the
  last ones given.
- `--belt-draw-small-pages=off`: the records' pages (`f3d_belt_records`, `f3d_belt_lattice`) are 16 rows of
  1,024 texels (256 KB, 4,096 records) and the texture array starts with one, doubling as the first load grows
  it (each doubling makes the array again: every page uploaded, a 1.5-3 ms frame), as before. On (the default):
  4 rows (64 KB, 1,024 records), 8 at the start. One record written sends its whole page up, a copy on the worker
  and `update_layer` on the main thread (about 22 pages a job standing at the owner's base, 186 MB a second at
  256 KB). `belt_path.gdshaderinc` takes a page's size from the texture's, so both work.
- `--belt-draw-park-lattice=on`: an item whose motion lies on lanes the lattice draws all along (its place and
  its reach ahead: how far lattice lanes go on past its lane's exit, worked out when the lattice's lanes change)
  is parked as an item out of view is: its motion kept, no slot, no record, nothing for the GPU (the mask hid it
  in every frame of that motion). The lattice is updated before the records now and gives its lanes added and
  removed; items on a lane that leaves the lattice are planned again from their motion in the same job, and
  those on a lane dropped from the square stand where they are for the far icons' hand-over, so a belt is never
  bare. An item whose motion runs off the lattice's lanes stays drawn and masked as before (it shows the moment
  it glides out). Quality marks (`position_of`) of a parked one come from its motion. Off (the default): as
  before. Offline it wrote 45-96% fewer records (the replay's three captures, a drifting view on one), both twins
  alike; live on the owner's base it is worth 1.0 ms of GPU but drew 3.7% phantoms at -62,-26 (the gate is 2%;
  1.3-1.4% off): items handed back from parking land in the wrong place for a while. Off until that is fixed.
- `--belt-sim-ask=view` (the default): lanes asked for again (`bre`) by what shows: a lane the lattice draws only
  when its check's count is wrong (the simulations now say per failing check whether the count differed,
  `mismatch_n`), at most every 30 s (front, back and ids drifting on a full lane are what the lattice ignores; such
  a lane is asked for the moment it leaves the lattice), a lane outside the planned view every 12 s, doubling to 60
  s while it keeps failing and back to 3 s once the view reaches it; a lane in view the lattice doesn't draw every
  3 s as before. `--belt-sim-ask=all`: every failing lane every 3 s, as before. (art-src/perf-plans/belt-sim.md B1:
  735 asks a second standing at the owner's base, 1,100-1,200 on laps; bridge.md's change 10 on the client's
  side.) Offline (`--replay-bre`) the simulation's own score by place fell, but live it held: at -62,-26 97.9%
  of the game's items drawn and 1.1% phantoms (`all`: 97.6-97.7%, 1.3-1.5%), at -272,-14 98.4% and 0.6% (the
  same), with 45-75% fewer lanes asked, the client's belt job 15-25% cheaper and the bridge's `bs.bre` 0.3 ms
  lighter (art-src/perf-plans/after.md 6).
- `--belt-sim-ask-near=off`: a job's asks in the simulation's order. On (the default): nearest the middle of
  the view first (the square's middle with no camera); the bridge reads asked lanes in the order asked, at
  most `bre_cap` (192) an update, so the near ones are read first when it can't read them all.
Inserter arms (client/scripts/world/inserter_arms.gd; the mod samples every hand's position and held
item every 6 ticks, `ih`):
- `--inserter-arms-clock=belt|wall` (belt): with `belt` the arms are drawn at the game tick the belt items
  are drawn at (belt_items.gd's drawn tick; the arms' own game clock two updates behind when no belts are
  drawn), each arm keeping its last seconds of `ih` samples by tick and the hand played between the two
  samples round the drawn tick as Factorio moves it (inserter_swing.gd: a turn and a stretch at the
  prototype's speeds, `eprops` rs/es times quality, out to the pickup and drop points, `eprops` ip/id turned
  by the direction, waits only there, the item changing hands as the hand leaves an end; a belt pickup
  solved for where and when the hand met the item). So a fast inserter's whole 12-tick swing shows and
  the hand closes on a belt item the tick the belt loses it. `wall`: as before, each arm gliding on the
  wall clock from an update's arrival towards the newest sample (about 10 ticks behind the game, the
  swings cut short at both ends, and 30-90 ticks ahead of the belts at -62,-26). Measured live (tools/inserter_check.py, Hold 60 UPS, by day, 20 s), wall -> belt: the drawn hand's error against the game's hand at the tick it stands for, while the hand moves, 0.26 -> 0.13 tile at -272,-14 and 0.67 -> 0.12-0.14 at -62,-26; drawn swings covering 76% -> 98% and 55% -> 97-98% of the true arc, reaching both ends 8% -> 95% and 1% -> 80%; at a belt pickup, when the belts' drawn tick reaches the take, the hand 1.1-1.3 -> 0.27-0.36 tile from the take spot and holding the item 35-65% -> 74-87% of the time (92-99% within 6 ticks); the arms' tick 13-39 ticks ahead of the belts' -> 0. Cost: 0.9/1.1 -> 1.1/1.3 ms a frame on average with 55/93 arms (the plans every 6 ticks; p90 1.5/1.1 -> 2.7/2.4 ms); the bridge's `inserters` step and `ih` bytes unchanged (0.08-0.10 ms a tick, 16-18 bytes a hand). Belts unchanged (visible 97.5-97.6% / 96.1-96.3%, phantoms 0.9% / 2.0-2.2%). At -62,-26 the client loses ~18% of the bridge's datagrams (`bs` too): a lost `ih` update makes a 12-tick pair, where a half-circle turn's side is a guess.
- `--inserter-events=off|items|on` (off): with `on` (and the belt clock) the hello asks the mod for `ie`: what each
  hand did as it happened (inserters.lua: picked {tick, count, item, where}, dropped {tick, remaining,
  where}, a status change, a position now and then and once or twice mid-swing, gone; docs/PROTOCOL.md)
  instead of the `ih` samples every 6 ticks. The mod keeps the square's inserters by chunk (searched once,
  again when something is built or removed there or every 600 ticks) and checks each hand (held count
  and status, two cheap reads) when something can have happened: on its way, at the tick its speeds say
  it arrives, so the pick and drop ticks come out exact; at a belt every tick (`/f3d-ih chase 2` for
  every other); waiting at a chest or machine less and less often, up to every 30 ticks (`/f3d-ih idle`);
  without power or disabled every 6 ticks with its position (the client then draws it from the positions
  as samples); at most 48 hands a tick (`/f3d-ih budget`), a record saying how many ticks late it may be
  when a check waited. Each record goes in the next 3 messages, 2 ticks apart (`/f3d-ih repeat`,
  `every`), so a lost datagram loses none. The client plays the swing from the last event at or before
  the drawn tick (inserter_swing.gd plan_events): a hand that took goes to the drop at its speeds and
  waits there until it dropped, one that dropped goes back and reaches for the item it takes next where
  it took it (so a bulk hand shows its first item at the grab, and the sweep's side comes from the
  mid-swing positions, not a guess); an uncertain pick is dated back by the exact drop after it.
  `/f3d-ih events on|off|auto` sends events to any client, to none, or as the hello says (auto);
  `/f3d-ih samples on|off|auto` the same for `ih` (auto: unless events go); `/f3d-ih` says what is sent,
  the hands' states and the checks a tick; `/f3d-ih reset` forgets the cache. Nothing of this is in
  `storage` (the cache and each hand's state are module-local: they only decide what is read and sent,
  so peers whose tables differ don't desync; after a load every hand is synced again within a tick).
  `items`: the hello asks for both (`ie` 2): the swing is drawn from the samples as before (they follow
  the game's hand, which is the item as drawn, lifted mid-swing, which the events can't) and the held
  item alone follows the events: it appears and vanishes at the game's own pick and drop ticks when the
  mod saw them exactly. `off`: the samples as before (an older mod, the menu's recorded stream and
  `wall` use them too).
  Measured live (tools/inserter_check.py, Hold 60 UPS, 20 s, the same runs as the belt numbers; `off`
  -> `on` -> `items`): at -272,-14 the drawn hand's error against the game's hand while it moves 0.12 ->
  0.48 -> 0.12 tile (the game's `held_stack_position` is the item as drawn, lifted ~0.5 tile mid-swing,
  which the samples follow and the events' straight legs can't; the event path's sweep side is also
  wrong in a share of cycles: p90 1.3), swings covering 98% -> 72% -> 98% of the arc, the hand holding
  the item at the frame the belts' drawn tick reaches a belt pickup 75% -> 100% -> 62% (96-100% within 6
  ticks either way), the drawn item appearing or vanishing within a tick of the game's count change 71%
  -> 74% -> 54%; at -62,-26 (the client losing ~18% of datagrams there) 0.15 -> 0.67 -> 0.12, 96% -> 90% ->
  96%, 77% -> 89% -> 45%, 50% -> 40% -> 33%. The bridge's records themselves: 70-84% at the exact tick,
  75-89% within one, 5-6 of 330-820 changes missed; the rest late by the wait between checks at a chest
  (up to 29 ticks). Cost: the bridge's `inserters` step 0.10/0.09 -> 0.17/0.20 -> 0.17/0.27 ms a tick
  (16-26 hand checks a tick), bytes 173/128 -> 89/115 -> 224/289 a tick, the client's arms 1.1/1.5 ->
  1.2/2.1 -> 1.0/1.6 ms a frame. Belts unchanged (97.2-97.6% / 0.78-0.84%, 96.2-96.3% / 1.7-2.2%). So
  `off` stays the default: the events are exact where the hand is checked every tick or two (belts) and
  robust to lost datagrams, but drawn alone they lose the lifted look and a share of the sides, and with
  the samples they cost more than they add yet (step 4: the belt item handed to the hand at the event's
  tick is what they are for).
- `--inserter-handoff=on|off` (on): the belt item an inserter takes leaves the drawn belt as the drawn hand
  closes on it, and the one it puts appears where and when the hand lets go (owner: "have them picking up the
  items in the animation"). The hello asks for `ie` (as `items` when `--inserter-events` is off: the pose from
  the samples, the held item from the events) and `ho` 1, for which the mod adds a `placed` record to each drop
  onto a belt: the item's unique_id, lane and line position, read off the belt at that check (inserters.lua;
  docs/PROTOCOL.md `ie` kind 6). belt_items.gd hands each pick from a belt to its simulation as a take on the
  event's tick (BeltSim.take_at, both twins: the items of the kind nearest the hand on the belt's lanes, as
  many as the pick added, within 0.625 tile; not when a read of those lanes as of that tick came first), each
  placed record as a put (put_at: that uid on its lane then). The taken item is gone on the take's tick; its
  record hides from that tick (texel 3 w, the shader), guessed ahead by BeltSim.peek_take when the event comes
  before the simulation reaches its tick (a guess the take didn't make is shown again); a put item is made a
  job early and hidden till its tick (w negative); a lane drawn as a lattice gets the hole the take leaves
  (belt_lattice.gd hole, both twins: the slot's texel 3 x), until the bridge's read makes it the simulation's
  again. The arms are steered onto the item's drawn place over the last 4 ticks before the grab (or the put's
  place before the drop) and eased back over 3. The bridge's lane reads stay the correction: a wrong guess (the
  game kept the item) comes back with the next read, a put the read already holds is left as it is.
  `--inserter-handoff-slack=N` (3): the simulation is stepped at most N ticks short of the newest update so
  the events for those ticks are in (no measurable gain at -62,-26; kept for slow links).
  `--inserter-handoff-margin=N` (0): the drawn clock held N more jobs behind the game, so the job that learns
  of a take is drawn before its tick: at -62,-26 with 1, the hand from the item at the grab 0.22 (p90 0.41)
  tile instead of 0.49 (1.69), the item leaving within a tick of the hand closing 58% instead of 51% (p90 4 ticks
  instead of 9), drops 48% instead of 27%; the belts drawn ~25 ticks behind the game instead of 6-14.
  Measured live (tools/inserter_check.py section 7 with the run's --belt-draw-dump; Hold 60 UPS, by day, 20 s;
  off -> on, 2-3 runs at -62,-26, 1 at -272,-14): at a pickup from a belt, the drawn hand from the item at the
  drawn moment it leaves the belt 1.2-1.5 -> 0.45-0.55 tile on average (p50 0.8-1.4 -> 0.07-0.20; -272,-14 1.42 ->
  0.38, p50 1.35 -> 0.06), the item leaving 19-32 ticks after the hand closed -> about a tick (p50 0.9-1.3, 44-51%
  within a tick; -272,-14 6.6 -> 0.9, 59%); at a drop onto a belt, the item appearing 10-20 -> 1.4-3.1 ticks
  after the hand opened (p50), the hand 1.5-1.8 -> 0.4-0.8 tile from it. The client's takes: 93-95% confirmed
  by the bridge's next read of the belt (the rest the read put right); puts 99.7-100% found by uid in the next
  read. Belts held: -62,-26 visible 96.7-96.9% / phantoms 1.0-1.3% (off this round 96.7-97.0% / 1.7-2.1%),
  -272,-14 98.0% / 0.36% (98.0% / 0.43%). Cost: the bridge's `inserters` step 0.11-0.12 -> 0.28-0.31 ms a tick at
  -62,-26, 0.09 -> 0.24 at -272,-14 (the events with the samples, as `items`, and the drop belt's lines read at
  each drop); the arms 1.8-1.9 -> 1.8-2.1 ms a frame; the hand's error against the game's unchanged (0.14 tile
  moving). `off`: as before (the read's diff takes the item off up to a job after the read, 0-6 ticks after the
  take, wherever the simulation has carried it by then).
- `--inserter-grip=on|off` (on): the item a hand carries is drawn in its grip, from the pick to the drop (owner,
  K8: a modeller's rigged inserter closed its pincers until they met, through the item, which they hid). A rig's
  pincers close onto the item's sides (`ModelRig.HELD_HALF`, 0.1 tile either side of the plane between them:
  item models are 0.2-0.27 across) and the item's middle is at the grip, half way along them; Wube's arm (Zenith's
  own inserters) reaches the hand's place with its claw's middle (the wrist did, the claw ending 0.15-0.3 tiles
  past it), the item between its fingers; a model turned with the hand, an icon card keeping its slight turn;
  the grip no lower than 0.03 tile over where belt items are drawn (a modeller's belts are taller: Vasillo's tops
  at 0.25). `off`: the item's base at a rig's grip or 0.14 below the wrist, the pincers meeting, as before.
  Checked by model_textures_test.gd (`-- --rig=<a modeller's inserter.glb>` for theirs) and
  inserter_events_test.gd (a rig fed a pick and a drop as `ie`, drawn frame by frame).
- `--inserter-rest-arms=on|off` (on): an inserter the bridge sends no hand for draws its arm at rest, the hand
  empty over its pickup (Factorio's idle hand waits there). The bridge sends hands only within
  `f3d-detail-radius` of the focus (24 tiles by default, at most 64), and no model carries an arm, so every
  inserter past it stood without one (owner, K12). Three plain boxes in the arm's paint (`ARM_TINTS`, else the
  prototype's colour), riding the hills, every resting arm in one MultiMesh without shadows (36 triangles an
  arm); worked out per chunk when its entities change (at most 0.3 ms a frame) or one of its inserters' live
  arms comes or goes (at once, so no arm is drawn twice or missing), put together at most every 0.25 s, never
  per frame. `off`: none, as before. Not measured on a big base; checked by inserter_events_test.gd.
- `--heat-glow=heat|always` (heat): a heat pipe model's glow (FUE5's heat pipes' copper) follows its temperature,
  the bridge's `ht` (fluids_power.gd): lit from 350 °C (Factorio's heat pipe minimum_glow_temperature, where its
  heated pictures start), easing on and off, dark below it and where no temperature is heard (past the bridge's
  fluids radius). On or off, not brighter with more heat. `always`: lit all the time, as any glowing model without a
  state. Headless only (anim.gd STATE_HEAT), not seen in a window.
- `--inserter-glow=hand|always` (hand): an inserter model's glow (a modeller's lit burner, Vasillo's
  burner-inserter.glb) follows its hand: lit while the arm is drawn turning or reaching and for 30 game ticks
  after (the short waits at its ends), dark while it waits for items or room and wherever no live arm is drawn
  (past the bridge's hands radius the arm rests). Factorio's burner inserter burns fuel only as its hand moves
  (energy_per_movement and energy_per_rotation, no drain); its own burner has no light (light_flicker black)
  and its picture no fire. The bridge sends no `st` for inserters, so their glow counted as always working
  (owner, L4: "the burner stays lit while it's idle"). `always`: lit all the time, as before. Checked by
  inserter_events_test.gd; not seen in a window.
- `--burner-fx=on|off` (on): while a burner inserter whose model has a glowing burner (Vasillo's; the built-in
  packs' have none) is lit by that rule, its glow breathes like coals (0.75 to 1.15 of its level, three slow
  sines in the model shader, `glow_heat`, each inserter out of phase by where it stands), a thin wisp of
  Factorio's light smoke (the smoke sheet, light-smoke's colour) leaves its grille about every 2.5 s within 30
  tiles of the listener, and Factorio's burning-fire loop (base/sound/fire-1.ogg, fire-flame-on-tree's working
  sound) crackles quietly, the nearest 3 at once (scripts/fx/burner_fx.gd). The same in the Model packs window's
  preview: Play animation breathes and smokes, the speaker plays the crackle. The owner's addition: Factorio's
  own burner inserter has none of it. `off`: a steady glow, no smoke or sound, as before.
- `--inserter-arms-trace=<file>`: a JSON line per frame with every drawn hand (unit, x, y, held item),
  the game tick the arms stand for, the belts' drawn tick and the frame's arm cost; with the bridge's
  `/f3d-ih trace [ticks] [radius]` (every hand near the focus each tick into
  server/data/script-output/f3d-ih-trace.jsonl, off by default) `python tools/inserter_check.py --bridge
  f3d-ih-trace.jsonl --client arms.jsonl` reports the hand position error at the tick the arms stand for,
  swing coverage (how much of each true swing the drawn one covers, whether it reaches both ends), the
  arm against the belts' timing at each belt pickup, the drawn hand's item changes against the game's
  held count changes in ticks (every inserter), the bridge's `ie` records' ticks against the true changes
  (the trace writes each event it made), and the cost (client ms a frame, the bridge's `inserters` ms a
  tick, `ih`/`ie` bytes, hand checks a tick). `godot --headless --path client -s
  res://tests/inserter_swing_test.gd` checks the swing model offline against a game-moved hand,
  `res://tests/inserter_events_test.gd` the swing from events and the arms layer fed `ie` messages (a
  third lost, two swapped, an uncertain pick dated back), `res://tests/inserter_arms_replay.gd --
  --trace=<f3d-ih-trace.jsonl> [--events] [--lose=0.18]` the layer against a real trace, fed samples or
  the events the bridge would make of it.

`godot --headless --path client -s res://tests/belt_bs_replay.gd -- --stream=bs.jsonl --truth=rec.json
--drawn-check --every-tick [toggles]` replays a capture (`--belt-capture=bs.jsonl`) with a job a tick as
the client runs them (`--binary`: each part written as a binary frame and read back first, as from a bridge
sending binary; the replay must come out the same) and says, every recorded tick, how far each simulated item is drawn from where the
simulation has it, by cause (`--drawn-explain=N` examples, `--trace=UID` one item). Without a camera every
item is in view; `--view=x,z,w,h` gives the ground view the records are planned for, moved `--view-drift=dx`
tiles east a job, so items park and are planned again as it goes. (A capture made offline with
`tools/bs_offline.py` from a recording serves too.) Experiments: `--oracle-at=TICK` reads every recorded lane
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
`--every-tick=60 --job-every=30` runs a job every 30 ticks with the updates since the last, the drawn clock 60
ticks behind them, as a live client with `--belt-draw-dump` on a busy base does (its jobs 30-40 ticks apart):
`tools/belt_quirks.py` on such a replay of a live capture (the dump's job lines made into a
`draw.bin.apply.jsonl`) came within a point of the live run's frozen and sliding shares. `--sim-dump-near` (with
`--sim-dump`) writes the simulation's items at its first tick at or after each recorded tick (a recording made
every 30 ticks seldom has the simulation's own ticks, which the plain dump needs); `--fronts-trace=K1,K2,...`
prints each job's `lane_fronts` of those lanes (front, its speed, most items' speed, count).

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

The 0.2.1 hotfix's main-thread fixes (art-src/perf-plans/client-cpu.md), each on by default and
behind a switch that puts back what was there before, for comparing:
- `--terrain-layers=rebuild`: the ground's texture array is made again from every picture loaded
  whenever a new kind of ground's picture is ready, as before (56-114 ms once 35-45 kinds are in).
  On: the array is made with room for 48 layers (grown 16 at a time; 4 when the pictures aren't
  compressed) and a new picture is written into its own layer (`update_layer`).
  An exported game can't compress them: Godot 4.7.2's export templates have no texture compressor
  (etcpak's S3TC and ETC are editor-only, CVTT's BPTC and Betsy only in templates built with their
  options; checked with the release template, every mode `ERR_UNAVAILABLE`), so it no longer asks
  (each try logged `"_image_compress_bc_func" is null`) and keeps each picture as RGBA8, the format
  Godot's renderer turned the old RGB8 into on every upload (2.8 ms a picture on the main thread). The
  cost: 11.2 MB a kind of ground on the GPU and in RAM, against 1.4 MB compressed; a base's 35-45
  kinds about 0.5 GB of each, against 70 and 60 MB. The log says so once ("Terrain textures: the
  ground's pictures are kept uncompressed").
- `--lod-pass=every-frame`: models' levels of detail are looked at in every chunk every frame (past
  1,700 chunks the 12 rings round the focus and 1,500 more a frame), as before. On: the two rings
  round the camera every frame, each band of rings further out only once the camera moved 3% of the
  band's distance (or the zoom, the window or the levels changed), within the frame budget's `lods`
  slice; standing still, nothing. Chunks shown again behind the camera switch without a cross-fade.
- `--lod-slice=off`: disables per-chunk ring slicing and the per-frame MultiMesh switch cap
  (`LOD_SWITCH_CAP`) in the banded LOD pass, switching a whole ring in one frame as before.
- `--lod-cpu-copy=off`: reads `MultiMesh.buffer` back from the RenderingServer on LOD cross-fades
  instead of building the fade copy from CPU-cached instance data.
- `--textured-lod=legacy`: restores the fixed `[64, 32]` px switch sizes and `[0.3, 0.15]`
  triangle floors for textured models instead of the triangle-density ladder and 7% third tier on
  dense models.
- `--tree-lod=off`: disables card-level view LODs on trees, keeping full leaf cards at every distance as before.
- `--far-trees=off`: keeps trees and plants as MultiMeshes in far chunks instead of merging their trunks and crowns.
- `--icons-later=off`: the entity info panel (the hover panel) reads an icon that isn't cached yet at once,
  on the main thread, as before. On (`Kit.icon_into`): read on a worker thread and filled in a frame or
  a few later, so the camera sweeping new kinds under a still cursor never waits for a file (13-15 ms
  frames on a cold disk).
- `--decor-sheet=off`: keeps flat decoratives as separate per-kind MultiMeshInstance3Ds per chunk instead of baking them into one chunk sheet (`decor_sheet_baker.gd`).
- `--decor-sheet-compress=on`: S3TC block-compresses baked decorative chunk sheets in editor builds (off by default to avoid `Image.compress` stalling `WorkerThreadPool`; export builds always skip compression).
- `--build-parts=each`: a chunk is built again on each `ents` part of its snapshot, as before. On:
  once its last part is in (or 0.5 s after the snapshot started, a part lost meanwhile).
- `--build-apply-deadline=off`: a chunk's build fills all its MultiMeshes in one go once its records
  are read, as before. On: it stops at the frame's deadline between models too.
- `--kept-replay=inline`: a kept chunk (`same`) is replayed inside that one message, as before. On:
  its kept messages go to the front of Bridge's queue and are handled within the message slice.
- `--frame-budget-measure=godot`: the frame budget's pool is worked out from Godot's
  `Performance.TIME_PROCESS`, as before. That is the slowest whole process step of the last second,
  the renderer's sync and draw included (Godot 4.7.2's main.cpp), so the pool sat at its 3 ms floor
  on a big base. On: the frame's other scripts are measured from the first sliced system's ask to
  the last script of the frame (a node world.gd adds at the last process priority). The stutter
  probe's frames carry both (`fb_other` in µs, `time_process` in ms).

- `--pipeline-warm=off`: a model is drawn as soon as it is made, as before, and Godot compiles its
  pipelines inside the first frame that draws it (0.2-0.9 s frames on a cold shader cache). On (not
  headless; `--pipeline-warm=on` forces it there): a model whose surfaces bring a shader and vertex
  format not met yet first stands far under the world as a one-instance MultiMesh, out of every view,
  where Godot builds its surface cache and compiles its pipelines on worker threads, and chunks leave
  it out for 300 ms and 3 frames meanwhile (`--pipeline-warm=<msec>` sets the 300), as they do while
  a model is read. Its levels of detail and shadow stand-in are warmed the same way once made.
  Each save's models are kept by name (user://seen-models/<save id>.json) and asked for at the
  welcome. The probe's frames carry Godot's five pipeline counters apart (`pl_draw`: the ones a draw
  waited for; `pl_surface`, `pl_spec`, `pl_mesh`, `pl_canvas`) and `warming`.
- `--join-warm=off`: the join's loading screen goes once 9 chunks are loaded (or 6 s), as before. On:
  it then stays, "Preparing models and shaders", while the chunks within two of the character aren't
  built with every model or pipelines are compiling, at most 25 s after the world is ready; models are
  read on all but two of the processor's threads meanwhile (3 in play).

- `--decode-thread=off`: map charts' pictures (`chart`) and chunks' tiles (`chunk`) are decoded on the
  main thread when handled, as before. On: on the bridge's parsing thread as each message is read
  (client/scripts/net/message_decode.gd); a message with fields of the wrong kind is left as it came.
- `--binary-messages=off`: the hello leaves `bin` out and the bridge sends everything as JSON text, as before.
  On (the default): the bridge sends binary frames (docs/PROTOCOL.md, "Binary frames"; wire_decode.gd reads
  them), the movers (`mv`) written with `string.pack` instead of as text (about 40 ns a number in the game
  against 290-670), and from wire version 2 the belts (`bs`, each lane key as unit number and line) and far lanes
  (`bfar`) too, their lists kept as numbers rather than text; everything else as its JSON text inside a frame.
  From wire version 3 the chunk snapshots (`chunk` tiles, `ents` records with their extras as a JSON tail), the
  machine states (`st`) and the inserter hands (`ih`) too; the snapshot jobs then keep numbers, not text. A
  client of an older version gets the newer kinds as text, and a hello that lowers it while binary chunk
  snapshots wait starts the stream over. `--belt-capture` writes a binary `bs` part as its JSON,
  so captures and the tools reading them are the same either way. The map setting **Binary messages to
  Zenith** (`f3d-binary-messages`, on) turns it off from the bridge's side, from the client's next hello (a
  second). `/f3d-selftest` says which a client gets; `tools/live_check.py --binary` checks a live server with it.

Not behind a switch: the graphics list's last part is merged and written to the cache on a worker
thread, and a new list's clutter is built again a slice a frame nearest the focus first (with the
chunks whose ground rules changed); the hover panel builds its JSON key only when the record, its
`extra`, health, states or the `hinfo` answer changed; the stutter probe's chunk latency looks only
at chunks that arrived (and the strips the square gained or lost), and Input's parts are timed under
it (`w_in_pick`, `w_in_mover`, `w_in_panel`, `w_in_highlights`).

### Graphics savings in 0.2.1 and their switches

The 0.2.1 hotfix's GPU changes (art-src/perf-plans/graphics.md, items 2, 3, 5, 8, 9, 10 and 11). Each
one that changes what is drawn has a switch that puts it back as 0.2.0 had it, for comparing in two
runs side by side; the stutter probe's `relief off` and `lod lines <n>` variants price two of them
in one running client.

- **Empty decorative pixels** (shaders/decorative_flat.gdshader): a flat decorative's pixel with no
  alpha is discarded right after the atlas read, before the mask's read and the lighting. Nothing
  changes on screen; no switch.
- **Levels of detail on at most 1440 lines** (model_lods.gd `max_lines`): the models' levels
  (world.gd), Godot's own levels (the shadow stand-ins, creatures: Viewport.mesh_lod_threshold is
  scaled by the window's lines over it, again when the window changes size) and SSAO's fade
  (ao_zoom.gd) count a picture taller than 1440 lines (Level of detail High and Medium; 1080 on Low)
  as that tall, so 4K switches where 1440p does. The contact rims stay in real pixels.
  `--lod-lines=<n>` counts on n lines whatever the setting; `--lod-lines=0` counts every real line,
  as 0.2.0. The stutter probe's `lod lines 0` (or any n) does the same for one variant.
- **Alpha Blend materials that can't be see-through** (model_textures.gd `solid_blend`): a BLEND
  material whose base colour alpha is 1, whose picture has no alpha channel or only opaque pixels,
  and that doesn't glow, loads as a solid material. Vasillo's belt surface is one: the top of every
  belt, splitter and underground leaves the transparent pass and gets the depth pre-pass, SSAO and
  contact shading. `--opaque-blend=off` keeps every BLEND material see-through.
- **Belt surfaces with see-through pictures are cut out, not blended** (model_textures.gd `clip_belt`):
  a BLEND belt surface (belt_return.gd `is_surface`) whose picture has transparent pixels (Vasillo's new
  belts: notched plate corners) loads as Alpha Clip at 0.5 and is drawn with factorio_material_clip.
  Blended, it wrote no depth and the return run, drawn in the same draw, painted its backward chevrons
  over the top ("chevrons pointing both ways"). `--belt-surface-blend=on` keeps it blended, as before
  0.2.2. Also, the return's triangles now come first in that draw (belt_return.gd `joined`), so even a
  blended surface draws its top run last; `--belt-return-first=off` puts them after, as before.
- **Emission as the glTF file says** (model_textures.gd `emission_strict`): a material glows only by its
  `emissiveFactor` (absent means none, glTF's default) and only when its emission picture isn't black on
  every pixel. Godot's reader turned emission on, white, for any emission picture, and Zenith drew such a
  material as lighting up at work, a see-through one as a plume that is gone at rest: Vasillo's export
  wires a black emission picture with no factor into 30 see-through materials, so his new pipes, ores,
  plates and drill bodies were invisible unless working ("none of the new models show up in the
  viewer"). The glow that is drawn is the picture x the factor x the strength
  (KHR_materials_emissive_strength). `--emission-strict=off` reads them as before 0.2.2.
- **A modeller's glow dims only itself at rest** (model_library.gd `glow_keeps_albedo`): a glowing
  material from a modeller's pack without an emission picture (Vasillo's drill's `Light`: a factor, no
  picture) goes dark at rest by its glow alone; its base colour is the same idle and working (Zenith's
  own fire boxes and lamps still dim theirs to 30%, as Factorio's do; a material with its own emission
  picture already didn't). `--idle-dims-glow-paint=on` dims it as before 0.2.2.
- **Nearly opaque Alpha Blend is cut out** (model_textures.gd `clip_blend`, the general case of
  `clip_belt`): a modeller's BLEND material whose base colour alpha is 1 and whose picture is opaque on
  95% or more of its pixels (Vasillo's drill: 0.1-0.3% of pixels a little see-through) loads as Alpha
  Clip at 0.5, so its parts sort and get the depth pre-pass; real glass (pipe-alt's `Glass`, 0.6 alpha
  everywhere) stays blended, and built-in packs are unchanged. `--blend-clip=off` keeps it blended.
- **Ore as scattered rocks** (model_library.gd `ore_rocks`, chunk_view.gd `_scatter_ore`): a pack with numbered
  ore models (`iron-ore-1.glb`, `-2`, ..., `copper-ore-N`, `coal-N`, `stone-N`, `uranium-ore-N`) or a plain
  `<ore>.glb` under 0.6 tiles on its larger side draws each ore tile as rocks by Factorio's eight richness stages
  (`ORE_STAGES`: from 150, 400, 1300, 2900, 5500, 9500 and 15000 ore; uranium's own 100, 270, 870, 1930, 3670, 6330,
  10000): 3, 5, 6, 7, 8, 10, 12 or 14 rocks, sized 1.1, 1.2, 1.35, 1.5, 1.6, 1.7, 1.8 or 1.9 times their 0.8-1.2
  jitter, poorest to richest, so they hide about as much ground as Factorio's ore pictures (22% to 96%). From a hash
  of the tile, in the chunk's MultiMesh per rock model, filled rank by rank: a far
  chunk (far_chunks.gd) shows every tile's first rock by the MultiMeshes' visible count, without a build.
  `--ore-scatter=auto` (default) as said; `--ore-scatter=on` scatters any plain ore model too, and a pack whose
  pack.json says `"ore_scatter": false`; `--ore-scatter=off`: one model a tile, as before 0.2.2.
  `--ore-look=old`: a "pbr" pack's ore rocks drawn as any model (Burley diffuse, the file's occlusion picture on ambient)
  instead of as belt ore is (Lambert, no occlusion: factorio_material_ore.gdshader).
  `--ore-density=classic`: 0.2.2's first scattering, 2, 4 or 6 rocks (under 400, from 400, from 2900; uranium 270
  and 1930) at their 0.8-1.2 size. A 60 x 60 patch draws 24,212 rocks near (classic 15,416; far 3,600 either way).
- **Window pipes** (model_library.gd `pipe_window`, world.gd `extra.pw`): a straight pipe where its floored x
  plus floored y is even is drawn with `pipe-straight-vertical-window` / `-horizontal-window` when the pack
  drawing its straight has that model (Factorio's window on every second pipe). `--pipe-windows=off`: none.
- **A mining drill's fluid part** (model_library.gd `wet_model`, chunk_view.gd `_add_wet`): `<drill>-wet.glb`
  drawn over a drill whose record's `fa` has bit 1 (the bridge sends it for a drill over a resource that needs
  fluid), if the drill's pack has it; a chunk is drawn again when that bit changes. `--drill-wet=off`: never.
- **Pipe covers** (pipe_covers.gd, world.gd `_cover`, chunk_view.gd `_add_covers`): Factorio's `pipe_covers`. Each
  fluid connection of a machine (the prototype's `eprops` fb) with nothing connected to it (no pipe whose `pc`
  reaches back, no pipe to ground facing it, no machine with a connection back) gets a cover from the pack that
  draws the machine: its `pipe-cover.glb`, else the cap of its pipe kit (`pipe-ending-down` less
  `pipe-straight-vertical`: Vasillo's pipe-cap, so his wet drill's open pipe ends are closed). A drill's show while
  it takes fluid (`fa` bit 1), a crafting machine's those its recipe uses, the rest all of theirs. Worked out again
  when a pipe or machine is built or removed next to it. Packs with neither model (the built-in ones) draw none.
  `--pipe-covers=off`: none.
- **Contact shading's patch under big machines** (contact_shade.gd `PATCH_EDGE`, `collect`'s footprint): the
  faint patch under drills, labs, radars, centrifuges, pumpjacks, refineries and reactors has its feet clamped
  to the building's tiles and fades out 0.1 tiles past them, its ring as wide as the rim's (0.27). It used to
  fade over 0.5 tiles past a foot that on a drill reaches the tile edge: a dark band all round every drill
  (31-35% dark at the tile edge, 14-16% 0.1 tiles out, 7% at 0.2; now 10-28%, 1-5%, 0%), where Factorio's
  drill has none past its body. `--contact-patch=wide`: as before.
  The clamp moves the patch alone: the rim stays round the model's real feet, so a machine whose base overhangs
  its tiles (Wube3DP's electric drill by 0.11 tiles, Vasillo's by 0.08, the placeholder burner drills) keeps its
  rim on that side instead of having it pushed under the model (such a foot gets a rim ring and a patch ring).
  `--contact-rim=clamped`: one clamped ring a foot, as the drill-border fix first had it.
  Under the foot the rim and patch fade out over 0.05 tiles (contact_shade.gd `INNER_FADE`, the shader's
  `inner_fade`), gone before the ring's hole. They were drawn at full darkness from the foot's box in to the hole
  and cut off there: hidden under a solid base, but where a body doesn't fill its feet's box (Wube3DP's electric
  drill between its rear legs, 0.38 tiles deep) a dark band with a sharp inner edge lay on the ground past the body.
  `--contact-inner=hard`: as before.
- **Contact shading shaped by each model** (contact_shade.gd `mask_of`, `commit_mask`; the shader's mask mode): the
  rings follow boxes, and a box was dark where the model has no part (Vasillo's electric drill: dark patches beside
  its body between the legs; the burner drill: a dark oval off one leg; an underground belt and a curve: dark ground
  under the hood and outside the curve). Each model's contact map is now made from its own mesh once, on the loader's
  worker thread: its triangles (moving parts in their rest pose) within 0.25 tiles of its lowest vertex, seen from
  above, the lower the darker, turned into the distance to that contact over a 64 x 64 mask (its contact plus 0.3
  tiles). The masks share one R8 atlas (16 a row, grown as needed, 4 KB each; the same mask twice shares a slot) and
  the rings' shader, profile, strengths, speckle and neighbour halving; one quad per building, turned and mirrored
  as it is, on a MultiMesh under the chunk's ring node (`ContactMasks`). Belts, pipes and walls (by file name) also
  get a joined variant, carried straight to the half-tile line their contact reaches and cut there, so a run's
  tiles meet in one rim with no bead at the joints (a run's open end has no rim round it). Models with no mask keep
  the rings: a mod's picture card, files named as rails, trees, rocks, ores, vehicles and the like (no shading
  anyway), and a full atlas (4096 masks). Cost, all 636 built-in and Vasillo's models: 480 masks in 6.5 s of loader
  time (about 13 ms each, a third of their load), 2.9 MB of atlas. `--contact-shape=box`: the rings for all, as
  before, and no masks made.
- **Contact shading under items** (item_cards.gd `contact`, `_with_contact`; shaders/item_contact.gdshader): items
  on belts and on the ground get the buildings' soft dark rim on what is under them (the belt's surface between
  its rails, or the ground), round their look's footprint (an icon card's middle 60%), as strong as the rim
  (`rim_dark` times 0.8) and as wide (`rim_falloff`): the debug menu's Contact strength and rim width move both,
  Settings > Graphics > Contact shading shows or hides both, and it fades out at far zoom as they do. A kind's
  mesh is a copy of its look with one more surface, a box round the footprint from 0.2 tiles under the item's base
  to just over it, drawn by the kind's own MultiMesh in the alpha pass as a decal: it reads the opaque scene's
  depth (already copied each frame for the cloud shadows) and darkens what lies below the base outside the
  footprint, so it follows the items on the GPU and costs one instanced draw a kind and the box's pixels, nothing
  a frame on the CPU; a pile's copies and inserters' hands have none. `--belt-item-contact=off`: no box (as
  before); `=flip`: on and off every 10 s, for `--item-bench`, which says the share of frames they were on.
- **Variants of every model, item model and icon** (model_packs.gd `variant_base`, `variants_in`; model_library.gd
  `pick_variant`): `<name>-1`, `-2`, ... and `<name>` are variants of `<name>` (not a numbered Factorio prototype:
  `assembling-machine-2`), one entry in the Model packs window; each placed entity and ground item draws one picked
  by a hash of its position (`extra.zv`, set in world.gd), an icon one picked by its name. A pack.json's
  `"aliases": {"coal-ore": "coal"}` reads its files under Factorio's names. Ores as before (scattered rocks).
  Items on belts draw theirs too (`items/stone-1..3`): a simulated item the one who it is picks, its number along
  its run as for its turn (item_cards.gd `lattice_variant`), kept while it travels and across re-reads; a packed
  lane's slots the same in the shader (`belt_lattice_variant`: a lattice kind per variant over the same records,
  each drawing its variant's slots); far lanes' icons by their place; an inserter's hand one per thing it takes.
  `--model-variants=off`: always the plain model (the window still groups them), items everywhere included.
- **Which packs have an ore** (model_packs.gd `provides`): a pack with only an ore's numbered rocks
  (`iron-ore-1`...), or its `-rich`/`-sparse` stages, provides that ore: listed on the ore's card in the
  Model packs window, drawing it when it is the order's first with it (model_library.gd
  `ore_scatter_names`) or chosen for it, the card tagged in use then. One rule for all three.
- **A modeller's item pictures** (item_models.gd `material_for`): an item model whose surfaces share a
  base-colour picture is drawn with it, by one material per item model kept with its mesh and shared by
  every instance (item_cards.gd's MultiMeshes on belts, the ground and in hands; belt_lanes.gd's far
  belts; the Model packs preview), the picture times the vertex colours, without the 0.75 exposure the
  icon-coloured items get. Built-in items (vertex colours, no picture) keep the one shared material.
  `--item-pictures=off`: pictures left out, every item model by its colours alone (as before 0.2.2).
- **A modeller's item drawn with its file's own materials** (item_models.gd `own_look`, `dressed`): an item
  model whose materials have more than one shared picture draws (pictures that differ between its
  surfaces or on only some, glow, see-through parts, or roughness, metal or normal pictures in a pack that
  isn't "pbr") keeps them, one material per surface, as
  its buildings do: base colour and its picture, roughness and metal with their picture, normal map,
  emission and alpha (item_own.gdshader for items on the ground, near belts and in hands; far belts'
  belt_lane_model.gdshader `own`; the Model packs preview with the file's materials), whatever the pack's
  shading and with or without pack.json, its pictures made ready as a building's (model_textures.gd
  `prepare`). See-through (glTF Alpha Blend) parts are blended at the file's alpha in the transparent pass, as
  buildings' glass is (item_own_blend.gdshader, belt_lane_model_blend.gdshader; the item's other parts stay in the
  opaque MultiMesh pass; with a depth pre-pass, as Godot draws glTF's Alpha Blend in the preview, so a one-surface
  flask's opaque pixels still write depth and cast shadow and only its glass blends; several see-through parts in one item blend smallest first,
  so a liquid shows inside its glass); `--item-glass=dither` dithers them in the opaque pass instead (stippled,
  more see-through), as the first 0.2.2 drawing did. Only one picture shared by
  every surface was drawn before, so a model of several materials (Vasillo's science pack) came out plain
  grey. `--item-materials=old`: as before.
- **Items already drawn follow the packs** (item_models.gd `generation`): when an item's model file changes
  with the packs' order, switches or choices, the item kinds drawn with the old one (item_cards.gd: on the
  ground, near belts, in hands; belt_lanes.gd's far belts) are made again with the new file. Checked only
  when the packs change (an int compare a frame otherwise). `--item-kinds-follow=off`: they keep the model
  they were first drawn with until a restart or a surface change (as before 0.2.2).
- **Baked animation played as the file says** (model_skin.gd, factorio_material.gdshaderinc `anim_baked`): a
  modeller's action is sampled at its own key rate (the closest two keys of any channel), 30 to 60 frames a second,
  up to 4096 frames (Vasillo's 35 s electric drill: 2101 frames at 60 a second, its bones' texture 2.7 MB against
  0.66 MB, the same again kept on the CPU for its bounds; it bakes in about 1.9 s on a worker instead of 0.4).
  Between two frames a bone whose axes turn more than about 30 degrees is shown at the nearer frame instead of
  mixing the two matrices, which shrank it (his fans to 57% of their width, the bit to 22%); slower bones are
  mixed as before. Not behind the switch, a plain error: a bone with uneven scale is posed rotate x scale as glTF
  says (the burner drill's counterweight arm sat 7 cm off). `--baked-anim=old`: 30 frames a second, at most 512,
  always mixed, as before 0.2.2.
- **Pictures shared between models** (model_textures.gd): a picture is made into a texture once, found
  by an MD5 of its bytes in the .glb (and failing that a hash of its decoded pixels), whatever model
  brings it; Vasillo's 39 models carry 188 textures of 48 pictures. A picture drawn crisp (NEAREST) is
  kept apart from its smooth use. `--share-textures=off`: every model its own copies.
- **Belt items' shadows** (item_cards.gd `BELT_LAYER`, avatar.gd, sun_shadows.gd): items on belts are
  on render layer 19, which the character's lantern and flashlight leave out of their shadow casters
  (the sun still has them); they cast within 0 / 30 / 45 / 60 tiles of the camera on Shadows Low /
  Medium / High / Ultra (was 30 / 45 / 60 / 80). `--item-light-shadows=on` puts them back in the
  lights' shadows.
- **The leaf cut's pollution hash** (factorio_material.gdshaderinc `leaf_cut`): only where pollution has
  made leaves fall. No switch.
- **The ground's relief** (terrain.gdshader): the three extra reads of the tile picture for its bumps
  and crevices fade out from 1.5 to 3 texels a pixel, where the mipmaps have already flattened them,
  and aren't made past that; off altogether at Level of detail Low. `--relief-fade=off` keeps them at
  every distance, `--ground-relief=on|off` forces them whatever the setting; the probe's `relief off`.
- **Matte ground and plants** (terrain_textures.gd `SURFACES`, terrain.gdshader, decorative_grass.gdshaderinc): each
  ground tile family has its own roughness and specular (concrete 0.9 / 0.1, refined 0.88 / 0.12, stone path 0.92 /
  0.08, landfill and natural ground 0.95 / 0.05, platform foundations and ice a little smoother), carried per tile in
  the mesh's CUSTOM1.w; never metal. Grass, carpet clumps and flat decoratives: specular 0.05, roughness 1. Godot's
  Fresnel brings most of a low sun's highlight back at grazing angles unless the specular is tiny, so with the sun low
  behind the scene paving glared pale and back-lit grass turned white. `--ground-rough=off` gives the ground 0.2.2's
  values (natural 1.0 / 0.15, floors 0.8 / 0.3), `--grass-backlight=old` the plants' (specular 0.5, carpet roughness
Trees (and rocks with grain): `--tree-sheen=old` (also `--grass-backlight=old`) keeps the 0.2.2 specular 0.5-0.2; default is matte (0.05, roughness 1). `--night-vision-fx=old` keeps night vision's first look (ambient lift 1.4, edge 0.42).
  0.9). The debug menu's Lighting tab: "Ground roughness" adds to every tile's.
- **Far merging no further than 192 tiles** (far_chunks.gd `MERGE_CAP`): a long Shadow distance no
  longer pushes the merge out past 192 tiles (at 400 nothing in view was merged zoomed out).
  `--far-merge-cap=<tiles>` sets the cap, 0 none (as 0.2.0).

## The native belt simulation (optional)

The client runs Factorio's belts itself (`client/scripts/world/belt_sim.gd`). The same simulation in
C++, `BeltSimNative` (`client/native/belt_sim/src/`), is a GDExtension that gives the same results item
for item, several times faster; `belt_items.gd` uses it whenever it is loaded and belt_sim.gd otherwise.
The same library holds `BeltDrawNative` (`belt_draw_native.cpp`): belt_items.gd's job from the
simulation's changes to the GPU records (`--belt-draw-native`, above), the same records as the GDScript
path (`tools/belt_draw_diff.py`).
The Windows library, `client/native/bin/belt_sim.windows.template_release.x86_64.dll`, is committed, so
nothing needs building to use it. Without it (other platforms, or the file deleted) everything runs on
belt_sim.gd and Godot's own UDP socket; the tests pass either way. The library holds `UdpSocketNative` too
(bridge.gd's socket, `--udp-socket`).

`--belt-sim-native=off` runs belt_sim.gd with the library loaded (its drawing and lattice in GDScript
too). If Zenith ever dies inside the library (an access violation, exit code 3221225477, with no
backtrace: a loop side-loading onto itself on Aquilo did that), the same spot under belt_sim.gd stops with
a script error and a GDScript backtrace naming the line, which points at the C++ function of the same name.

Godot doesn't load it at start-up: `client/scripts/native_library.gd` does, the first time Bridge or
belt_items.gd asks, and only where the `.gdextension` names a library for this platform and the file is
there. Godot itself loads every `.gdextension` its editor finds, and a `.gdextension` can't make a
platform's library optional: on Linux, macOS and ARM64 every run printed three `ERROR` lines ("No
GDExtension library found for current OS and architecture"). So `client/native/.gdignore` hides the folder
from the editor, the start-up line says `Native library: loaded`, or `none for linux.x86_64, belt_sim.gd
instead`, and nothing needs importing first. An exported game has the `.gdextension` and the DLL beside
its program (`tools/release/package.py` copies them; Godot's export no longer sees them). A checkout whose
`client/.godot/extension_list.cfg` still names it, from before, has Godot load it as before until its next
import, which removes the list.

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

The DLL goes out in the downloads, so it carries no path of the PC it was built on: SConstruct links with
`/PDBALTPATH:%_PDB%` (the `.pdb`'s file name alone, not its full path) and compiles godot-cpp and our own
source with `/d1trimfile:<client\native>\` (and the folder holding `godot_cpp=`), which cuts that folder off
the `__FILE__` names godot-cpp's error macros keep (`godot-cpp\src\core\memory.cpp` is left). A godot-cpp
built before that flag is built again once. Before committing a new DLL, scan it for drive paths, ASCII and
UTF-16 (none may be left).

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

## Commands for models, releases and the UI reference

Moved here from AGENTS.md's command list, which keeps the tests and the everyday commands.

```bash
# 3D models (client/assets/models/README.md): rebuild, check, re-import, optional preview
blender --background --factory-startup --python tools/models/build.py -- [names...]
python3 tools/models/wube.py [names...]  # convert Wube's printable models from art-src/wube/
python3 tools/models/fue5.py [names...]  # convert FUE5's models from art-src/fue5/raw/ (--score: overlap, ours and theirs;
                                         # --fix-imports after `godot --import` keeps their textures embedded)
python3 tools/models/check.py [names...]  # <name> or <pack>/<name> (fue5/stone-furnace); none: all 481
python3 tools/models/fix_pack.py <export> <copy> [--fixes tools/models/fixes/vasillo.json]  # a modeller's export fixed into a copy (names, items/, origin, pipe shapes and endings, emission and blend modes by the picture's alpha); the list is data
python3 tools/models/sprite_projection.py  # after adding a model with a Factorio sprite
python3 tools/models/part_colors.py [names...]  # and each part's colour from the sprite, into the .glb (after any rebuild)
python3 tools/models/review.py [names...]    # owner review shots in the client (art-src/shots/<name>/, needs a window)
godot --headless --path client --import     # commit the new .glb.import files too
blender --background --factory-startup --python tools/models/preview.py -- out.png [names...]

# releases, benches and the network's cost
python3 tools/net_cost.py [--port 34200] # bytes and messages per type the client gets (mock busy base, or a server)
python3 tools/release/build_mod_zip.py  # dist/factorio-3d-bridge_<version>.zip for the mod portal (uploads nothing)
python3 tools/bench/compare_builds.py --before v0.1.2 --after v0.1.3   # every update: the same laps and standing test
                                        # on both builds, a copy of Zenith Test, runs taking turns -> art-src/bench/*/table.md
python3 tools/bench/hybrid_cost.py      # what hybrid costs against a server, the same test (adds and removes steam_appid.txt)
python3 tools/release/package.py        # dist/Zenith-<version>-windows.zip: the exported client, mod and server scripts (needs Godot's export templates)
                                        # --platform linux, or linux-arm64 / windows-arm64 / macos (unsupported), all;
                                        # --channel dev for a development build (Zenith-<version>-dev-*.zip, with the testing tools)
python3 tools/release/thumbnail.py      # redraws the mod's thumbnail.png

# Factorio's own UI as the reference (windowed Factorio on a copy of the owner's save; pictures in the
# main checkout's git-ignored art-src/ui_reference/), ours the same way against the mock
# (mock_server.py --port 35310 --reach 200 --machine-gallery), then the side-by-side page; differences: docs/UI-DIFFERENCES.md
python3 tools/ui_reference/capture.py [--only names] [--fresh]
python3 tools/ui_reference/ours.py --factorio-port 35310 --port 35311 [names...]
python3 tools/ui_reference/compare.py

# compare every model with Factorio's sprite (needs Blender and a Factorio install); writes the
# git-ignored art-src/compare/index.html, tagged Wube 3D release / sprite reference / old placeholder
python3 tools/models/gallery.py [names...]
```

## Tests

One command runs them, the same way CI does, and ends with a table of what passed (Windows and Linux;
it finds the venv's Python and Godot by itself, `$GODOT` to pick one):

```
python tools/check.py --all          # the fast suites: the Lua ones, the mock's, gdparse, the models' check, the relay (~1 min)
python tools/check.py --all godot    # the headless Godot tests CI's ui job runs (~1-2 min, no window)
python tools/check.py --all both     # both
python tools/check.py                # only the checks for what changed against main (retries a failure once)
```

`--all` runs each suite once (a failure is a failure, no retry), keeps each one's whole output in
`art-src/check-logs/` (`--logs <folder>`) and prints the first failing line of each in the table.
CI's tests and ui jobs run exactly these commands; on GitHub the table goes to the run's summary and
each failure is an annotation naming the check. The suites one by one:

```
python3 -m venv .venv && .venv/bin/pip install "lupa==2.*" "gdtoolkit==4.*"   # once (Windows: .venv\Scripts\pip)
.venv/bin/python tools/mod_tests/test_bridge.py   # the mod, against a fake Factorio API
.venv/bin/python tools/mod_tests/test_data_stage.py   # the mod's data stage (the graphics list)
.venv/bin/python tools/mod_tests/test_fuzz.py     # the mod against malformed, truncated, out-of-order packets
.venv/bin/python tools/mod_tests/test_binary.py   # binary frames (`bin`) decode as their JSON does
python3 tools/test_mock_server.py                 # the mock server, over real UDP
python3 tools/test_mock_fuzz.py                   # the mock, fuzzed the same way
python3 tools/test_relay.py                       # the relay for a server on another PC, and the mock behind it
.venv/bin/gdparse $(find client -name '*.gd') >/dev/null || echo "FAIL"
python3 tools/models/check.py                     # after model changes: name, footprint, origin, triangle budget (all 481)
godot --headless --path client res://tests/ui_test.tscn   # the UI's input paths; exits 1 on failure
godot --headless --path client res://tests/addon_test.tscn   # add-ons: loading, keys, the camera, data
godot --headless --path client res://tests/bridge_fuzz_test.tscn   # the client's packet parsing, fuzzed
godot --headless --path client res://tests/decor_test.tscn   # decoratives
godot --headless --path client res://tests/vr_test.tscn      # VR panel and session without a headset
godot --headless --path client -s res://tests/model_load_test.gd   # after model changes: every model loads the same both ways
godot --headless --path client -s res://tests/mod_files_test.gd    # mods' files and the graphics list
godot --headless --path client -s res://tests/model_packs_test.gd  # model packs: built in, loose, folders, zips, order, off, choices
godot --headless --path client -s res://tests/nature_looks_test.gd # trees' variations, colours, leaf atlas, rock and bark grain
godot --headless --path client -s res://tests/sound_decode_test.gd # sound decodes on workers never wait for a lock the main thread holds (packs', add-ons', mods' and steps' sounds too); at most 2 at once; clear_cache() waits for them
godot --headless --path client -s res://tests/sound_cache_test.gd  # one decode per sound and loop flag, clear_cache() mid-flight, quitting with decodes in flight
godot --headless --path client -s res://tests/safe_delete_test.gd  # add-ons' and model packs' folder deletes never go through a junction or symlink
```

CI (`.github/workflows/tests.yml`) runs all of these on every push, and `tools/live_check.py`
and `tools/busy_base.py` against Factorio's Linux headless build (seed 123456, 2.1.23). Each job has a
time limit, a new push to a branch cancels the run still going on it, a failed job uploads its logs
(the suites' outputs, `live_check.log`, the server's log) as an artifact, and `tools/ci_summary.py`
puts the live and busy jobs' result line and failing checks in the run's summary.

What the checks rely on, so they pass on every run (they failed on the public repo from 0.1.2 to 0.2.0):
the Lua suites don't depend on `pairs` order (Lua 5.2 seeds its string hash per process: 100 runs of
test_bridge.py in a row pass); the UI test's sections each run alone (`-- --only=<section>`) and leave no
control bound behind (a check at the end of every run); live_check's walks start from a cleared spot,
the railgun turret is checked against its own target, a tick-paused game is resumed over RCON before
the bridge's answer is expected (a paused game runs no mod code), and checks of what the bridge sends
on its own schedule (far belt lanes, wires a script changed: the bridge looks for those in 8 strips,
within 4 s) wait for it, up to a limit, instead of a fixed second.

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
