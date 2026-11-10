# Zenith: player's guide

Zenith lets you play Factorio in 3D, with an angled camera close to your character. Factorio itself still runs the game: a small mod (the **bridge**) streams the world to
the **Zenith client**, a separate program that draws it in 3D and sends your keys and clicks
back. Everything stays on your computer.

This guide is for playing. [RUNNING.md](RUNNING.md) has every detail (all controls, settings and
command-line options); [ARCHITECTURE.md](../ARCHITECTURE.md) is for people working on it.

## What you need

- **Factorio 2.1** (Space Age is optional). Your own copy: the client reads Factorio's graphics,
  sounds, fonts and names from your install and never copies them.
- **Zenith itself:** the download (`Zenith-<version>-windows.zip`, or `-linux`), or this
  repository with [Godot 4.4 or newer](https://godotengine.org/download).
- Windows or Linux. The client and Factorio must run on the same computer.

## Installing

**From the download** (the easy way):

1. Unpack the zip anywhere you can write to (your Documents, say): it is one folder with
   `Zenith.exe` (on Linux `Zenith.x86_64`), the bridge mod in `mod/` and the server scripts in
   `server/`. Your Zenith worlds and the servers' data are kept in Zenith's user folder, with its
   settings (`%APPDATA%\Godot\app_userdata\Zenith` on Windows, `~/.local/share/godot/app_userdata/Zenith`
   on Linux), so a new version unpacked anywhere finds them. A version unpacked over an older
   one brings that one's `server/saves` and server mods over by itself, once.
2. Start `Zenith.exe`. That's all: when you start a game from its menu, it runs Factorio in the
   background with the bridge mod and connects by itself. If it can't find Factorio, set
   Factorio's folder in Settings → Factorio install. (The Linux download hasn't been tried yet.)

**From the repository** (to change it, or on a system the download doesn't cover):

1. Start the client once with `godot --headless --path client --import` so Godot imports the
   models, then `godot --path client`. `python3 tools/release/package.py` builds the download.
2. The menu uses the mod in `mod/` the same way.

**Playing in your own Factorio window** (single-player "hybrid" mode, or joining someone's
server) needs the bridge mod in Factorio's own `mods` folder: get *Zenith Bridge* from the mod
portal (Factorio: Mods → Install), or put `factorio-3d-bridge_<version>.zip` there (built with
`python3 tools/release/build_mod_zip.py`). Factorio must also open its UDP port for the bridge:
add `--enable-lua-udp 34200` to its command line (Steam: Properties → Launch options). Without it
the mod does nothing. Hybrid mode works (it has been played side by side with Factorio's
window, and with mods), but it has been tried less than a server.

## First game

Start the client. Its main menu works like Factorio's:

- **Single player → New game** makes a map with Factorio's map generator and starts it (a
  headless Factorio runs in the background; the client connects by itself).
- **Single player → Load game** continues one of your saves. Your original save is copied first,
  never changed. Saves in folders show as `[folder]`: click one to go in, `[..]` to go back up.
- **Multiplayer → Host new game** (or **Host saved game**) starts a server friends can join with
  normal Factorio, while you play in 3D.
- **Multiplayer → Connect to address** joins a bridge that is already running, for example
  `127.0.0.1:34200`.

Leaving a game asks whether to save; the server the client started stops with it, even if the
client crashes.

The first time, Settings → Factorio install lets you point the client at your Factorio install if
it wasn't found (Steam installs usually are).

## Playing

Factorio's keys work as in Factorio: WASD walks, the right mouse button mines, E opens your
inventory (or closes the window that is open), the left mouse builds what you hold or, with
nothing held, opens the building under the mouse, R rotates, Q
picks up the item under the mouse (pipette), T is the technology screen, M the map, 1–0 the
quickbar, Enter gets in and out of vehicles, Esc closes windows or opens the game menu. The game
starts in the angled view, and the camera is yours to move:

| Input | Camera |
|---|---|
| Mouse wheel | Zoom |
| Middle mouse drag | Turn around the character and tilt |
| , and . | Turn 90° |
| Page Up / Page Down | Tilt |
| F6 | Factorio's own view from above, and back |
| F5 | First person, and back |
| F7 | Perspective or orthographic, for the view you're in (the map's remote view or the normal one) |

The right mouse button mines whatever is under it, trains, wagons, cars, tanks and spidertrons
too: they go into your inventory with what is inside them (fuel, cargo), and the rails stay.

Alt (or the ALT button on the shortcut bar) is Factorio's Alt-mode: every machine you can see
shows what it makes or lets through (recipes, inserter, splitter and filter chest filters), however
big the base, and the moment it comes into view. As in Factorio, machines also show arrows where
fluids go in and out (the connections their recipe uses), pumps the way they pump, and a recycler
the side it drops onto; inserters' pickup and drop arrows are off by default (Settings → Interface
→ Alt-mode turns each kind on or off, as Factorio's Interface settings do).

Hovering a building shows Factorio's entity info on the right: its status, recipe, modules and
beacons, and for powered buildings "Consumes electricity" with the Electricity bar; hovering a
roboport draws lines to the roboports it is linked to. On a space platform (and in the map view of
one) Factorio's platform panel under the minimap says where it is stopped or what it is travelling
between, its speed and mass, and on board has **Drop to a planet**.

Settings → Controls lists and rebinds everything. F1 shows the help, F4 a status line (the
game's UPS beside the frame rate, and what Hold the game at 60 UPS holds back). Ctrl+F9
opens the same game in Factorio itself, and Ctrl+F9 there comes back, minimising Factorio to save
its drawing. Started through `server/factorio-with-zenith.ps1` (RUNNING.md says how to set it as
Steam's launch options), Factorio's Ctrl+F9 (or the Zenith gear among its top-left mod buttons) also starts Zenith when it isn't running (Settings → Other → Copy launch options gives the line for Steam; open Zenith once before setting it). When it can't start Zenith, Factorio shows a window saying what is missing: Zenith itself (with its download page), the launch options (with the line to copy), or both. Windows move by dragging their title bars.

Playing through Factorio (hybrid single-player, or joined to the server as yourself), mods'
windows show in Zenith too, and on Windows their buttons work: see Playing with mods below.

## Playing with mods

The game Zenith shows is real Factorio, so every mod runs exactly as it does in Factorio: its
recipes, machines, planets and scripts all work. What differs is what Zenith can draw and what
the mod can see of you.

### Two ways to play a modded game

- **On a server** (Single player → New game or Load game, or Multiplayer → Host): Factorio runs
  in the background with no window, and Zenith's bridge plays a character of its own. Add mods
  in the main menu's **Mods** window, which lists the server's mods folder: put the mods' zips in
  `%APPDATA%\Godot\app_userdata\Zenith\server-data\mods` (the download) or `server/data/mods`
  (from the repository), tick them, and start the game. **Load game** on a save made with mods
  starts it with exactly those mods: Zenith links the mods from your own Factorio mods folder
  (`%APPDATA%\Factorio\mods`) into the server's, and Factorio turns on the save's mods at the save's
  versions. If one is missing there, or there at another version, Zenith names it: start the save in
  Factorio once (it downloads them), or put that mod in your mods folder. This is the cheapest way
  to play, and the one most tested.
- **Hybrid** (Single player → Single-player (hybrid)): you start your own Factorio with your own
  mods and save, with the Zenith Bridge mod and `--enable-lua-udp 34200` in its launch options,
  and Zenith connects to it and plays *your* character. Both windows show the same game; Ctrl+F9
  swaps between them and minimises Factorio. Joining a server as yourself with normal Factorio
  while Zenith plays your character works the same way.

### What works where

| Kind of mod | Examples | On a server | Hybrid |
|---|---|---|---|
| New items, buildings, planets, recipes | Space Exploration, Krastorio 2 | Yes | Yes |
| Mods that change the game's rules or data | Squeak Through, bigger stacks | Yes | Yes |
| Mods that give *players* a bonus | Far Reach | No: the bridge's character isn't a player | Yes |
| Mods that react to what *a player* does | auto-filling, build logging | Partly: they see buildings appear, not who built them | Yes |
| Mods with their own windows | Informatron, Factory Planner, Helmod | Use Factorio (Ctrl+F9) | Use Factorio (Ctrl+F9): not drawn in Zenith for now |
| Mods' own hotkeys, text fields, dropdowns | most mods with a window | Use Factorio (Ctrl+F9) | Use Factorio (Ctrl+F9) |

- **Graphics:** a mod's own icons, ground, plants and rocks, and names in your language are drawn
  from the mod's files, read from the server's mods folder and your own Factorio mods folder.
  Its buildings have no 3D model, so Zenith shows the mod's own picture of them on a card that
  faces Factorio's camera (still pictures; Settings > Graphics > Animate modded buildings, off by default, runs their loops while they work). Only Factorio's and Space Age's buildings
  have 3D models.
- **Mods' windows aren't drawn in Zenith for now** (Settings > Interface > Show mods' windows, off):
  their layout and buttons don't match Factorio's yet. Use them in Factorio: Ctrl+F9, or the Factorio
  button at Zenith's top left, swaps to the same game in Factorio's window, and the Zenith button (the
  gear) among Factorio's top-left mod buttons, or Ctrl+F9 there, comes back. With the setting on:
- **Mods' windows** in Zenith show what the mod shows, as it changes, and long text wraps where
  Factorio wraps it. A mod only hears clicks made in Factorio itself (no script can fake one), so:
  - **Informatron's** buttons (its menu pages, close, and its top button) are pressed by the bridge
    through Informatron's own script interface: they always work, on a server too.
  - **Any other mod's** buttons, in hybrid on Windows, are clicked in your Factorio window: Factorio
    comes to the front for a moment, the button is clicked there, and Zenith comes back (a
    minimised Factorio is minimised again). Zenith's copy of a window doesn't have the mod's own
    sizes, so a click often lands beside the button; use Ctrl+F9 when it does. Typing in a mod's
    text fields and picking from its dropdowns needs Factorio too.
  Settings → Interface → Click mods' buttons in Factorio turns the clicking off, and then such a
  button says to use Ctrl+F9.
- **Map setting "Act as the player for other mods"** (on by default): in hybrid, building,
  mining, rotating, pasting settings and opening machines go through your player, so other mods
  see them as yours and Factorio's own reach rules (with Far Reach's bonus) apply.

Tried so far: Space Exploration's mod pack (graphics, and its save loaded from the menu), and Far
Reach and Informatron in hybrid.
The rest of the table follows from how each kind of mod works and hasn't been tried with every
mod; if one doesn't behave as it says, Report a bug in the main menu.

### Which to choose

- **Use a server** for content mods (new items, buildings, planets) and for the best speed. Your
  own save can be loaded too: the bridge takes over its character.
- **Use hybrid** when a mod needs a real player: player bonuses (Far Reach), mods that track who
  did what, or mods whose windows you use often (they're used in Factorio's window: Ctrl+F9 swaps
  to it and back, and with a server there is no Factorio window to swap to). Also when you want to
  drop into Factorio itself now and then.

### What hybrid costs

Factorio keeps its own window while you play in Zenith, and draws it unless it is minimised (Ctrl+F9
minimises it for you). Measured with the same test on a big base, standing at its busiest belts:

| | Server | Hybrid | Hybrid, Factorio minimised |
|---|---:|---:|---:|
| Game speed | 59.3 UPS | 58.8 UPS | 57.9 UPS |
| Zenith frame time, middle | 6.3 ms | 6.5 ms | 6.4 ms |
| Zenith frame time, slowest 1% | 11.7 ms | 11.8 ms | 11.8 ms |
| Zenith frames over 16.7 ms (per 75 s) | 1.5 | 5 | 4.5 |

So hybrid cost about 1 UPS and a few more slow frames there, and minimising Factorio made no
difference in this test. On a PC with less to spare it can cost more, since Factorio's window
competes with Zenith for the processor and the graphics card: if the game slows down in hybrid,
minimise Factorio or play on a server. Hybrid single-player takes one Zenith; a server takes up
to 8.

## Settings worth knowing

- **Graphics → View distance** (chunks drawn around you) and **Entity distance** (how far moving
  things and machine states are streamed). Lower them if the game stutters.
- **Graphics → Level of detail**: how soon far-away models are drawn simpler.
- **Graphics → Merge far buildings** (on): past about four chunks from the camera (and away from
  your character), each chunk's buildings are drawn as one simplified mesh with no moving parts,
  which costs far fewer draws when the camera is pulled back over a big base. Trees, ore and nests
  keep their own models. Off draws every building in full however far it is.
- **Graphics → Preset** (Low, Medium, High, Ultra) sets shadows, level of detail, the distances,
  Moving belt items, decorative density and clouds together, and turns ambient occlusion off; **Shadows** alone (Off to Ultra) sets how far and how sharp
  the sun's shadows are.
- **Graphics → Merged materials (may help when CPU-bound)** (off): each model is drawn as one
  surface with one material instead of one per material, so the renderer has far fewer draws to
  send, at the cost of a little more GPU time. Try it if your graphics card idles while the frame
  rate is low. Takes effect after a restart. Recommended turns it on for a big desktop graphics card
  when the game measures the CPU holding the frames up.
- **Graphics → Recommended**: picks the preset this PC holds at a steady 60 UPS and 60 FPS (from its
  CPU and graphics card), with Hold the game at 60 UPS on, and Merged
  materials as above. Pressed in a game,
  it measures for six seconds first and goes a preset lower if the game or the frames fall short.
- **Graphics → Hold the game at 60 UPS** (on): when the game runs slow on a big base, the client
  asks the bridge for less for a while (shorter distances, fewer minimap refreshes, then a lower
  frame rate) and gives it back when the game recovers. Your settings stay as they are; F4 shows
  what is held back.
- **Graphics → items on belts**, three settings: **Belt item distance**, how far items on belts are
  drawn; **Moving belt items**, how many of them move (Automatic raises and lowers it with the room
  the frames, the game and the server's tick have; counted from the character outwards: past those, out
  to the distance, they stand still on their lanes); and **Items in 3D**, how many are 3D models,
  nearest first, the rest icons (All: every one, far belts too; Icons only: Factorio's icons
  everywhere, on the ground and in hands too). A stack inserter's stacks are drawn as piles, as
  Factorio draws them.
- **Camera → View when a game starts** (Angled view, Factorio's view or First person) and
  **Projection** (the angled view in perspective or orthographic), **Projection on the map** (the
  remote view you zoom into from the map; F7 switches whichever view you're in) and **Furthest
  zoom** (how far the wheel zooms out, 60 to 400 tiles; 140 by default) and **Zoom out to the map at**
  (how far the view you zoomed into from the map zooms out before the map comes back, 80 to 480 tiles;
  240 by default). **Camera follows the hills** (off): with a hills add-on such as Terrain
  Elevation, the camera stays level as you walk and only first person rides the hills; on, it
  rises and falls with the ground under the character.
- **Interface → UI scale**, and Ctrl+= / Ctrl+- / Ctrl+0 while playing.
- **The bridge's own settings** are in Factorio's Mod settings (Map tab), or Settings → Mod
  settings in a game the menu started: how much it sends per tick, how far moving things are
  streamed, which player the client plays as on a server.

## Add-ons

Add-ons add to what Zenith does, for example the [Cinematic camera](https://github.com/unjustodin/Zenith-Cinematic-Camera) for filming your
base (its keys and modes are in its own guide there). One is a
folder or a .zip of it (no need to unpack it): put it in Zenith's add-ons folder, `%APPDATA%\Godot\app_userdata\Zenith\addons\` on
Windows (or an `addons` folder beside `Zenith.exe`), and start Zenith. The **Add-ons** menu (on
the main menu, in the game menu that Esc opens, and at the bottom of Settings) lists every add-on
found with its version, whether it's on, and why it couldn't load (for example one that needs a
newer Zenith). Click one for its page: its switch, its settings (changed there at once, in a game
too, and kept for next time) and its keys, rebound as in Settings → Controls (click, press the
key; right click clears). With two copies of one add-on (a folder and a zip, say), the newer
version is used and its page says so. The Mods window lists them as well. Add-ons can move the camera and
change what is shown, never the game itself. Writing one: [ADDONS.md](ADDONS.md).

The download already has two in its `addons` folder: the Cinematic camera, switched on, and
[Terrain Elevation](https://github.com/unjustodin/Terrain-Elevation) (hills under the world),
switched off: turn it on in the Add-ons menu. Newer versions are on each add-on's releases page.

An add-on that records in the background (the Cinematic camera's recorder) keeps Zenith drawing
while its window is behind Factorio's: Zenith isn't minimised when it loses focus while it
records. Don't minimise Zenith yourself while recording: a minimised window draws nothing, so
nothing is recorded meanwhile.

## Several players

- **With friends in normal Factorio**: host a multiplayer game from the client's menu; they join
  the server with Factorio as usual and see your character.
- **Several 3D players**: on a server (headless or hosted), more 3D clients on the same computer
  connect to the same bridge. Each gets its own character; they see each other walking around.
- **Console commands in a multiplayer game** (`/cheat`, `/f3d-player` and the rest, from Zenith's
  console or the bridge's `/f3d-*` commands in Factorio's) are for admins. A player playing through
  Zenith on their own machine needs to be an admin (`/promote` them); Zenith on the server's own
  computer always may.
- **Single-player (hybrid)**: start Factorio normally with `--enable-lua-udp 34200` and connect
  the client (Single player → Single-player (hybrid) → Connect). It plays your own character; both
  windows show the same game. It has been tried less than a server: if it doesn't work, use
  Single player → New game or Load game instead.

## When something goes wrong

| Problem | What to try |
|---|---|
| "Waiting for Factorio on 127.0.0.1:34200" | Is Factorio running with `--enable-lua-udp 34200`, and the bridge mod enabled? In Factorio's console, `/f3d-status` says whether a client is connected |
| A game from the menu doesn't start | The message shows the lines of Factorio's log that matter. Check Settings → Factorio install, and that no other Factorio uses the same server data folder |
| "Can't open UDP port 34201" | Other programs have it and 34202–34208, which the client tries by itself. Close other clients |
| No item icons, flat-coloured ground, no sound | The client didn't find your Factorio install: set it in Settings → Factorio install |
| The game stutters on a big base | Try Settings → Graphics → Recommended, or a lower Preset; keep Hold the game at 60 UPS on; lower View distance, Entity distance, Moving belt items and Items in 3D |
| Something else | `/f3d-selftest` in Factorio's console checks the bridge in your game; RUNNING.md's Troubleshooting section has more |

To report a bug, use **Report a bug** in the main menu or the Esc menu. It packs Zenith's recent logs and the server's into one zip, then opens GitHub's bug report page (with your versions filled in) and the folder holding the zip. Drag the zip into the report. The logs may show your user name in file paths.

Zenith is a fan project, not made or endorsed by Wube Software. Factorio is theirs.
