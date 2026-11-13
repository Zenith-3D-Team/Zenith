extends Node
## The performance test's game side (perf_test.gd drives it; docs/PERFORMANCE-TEST.md): a fixed map
## on a headless Factorio, the same test base built over RCON every time, and for each test Zenith
## started again as a child process of this one, measured by its own stutter probe.
##
## Kept apart from the player's things: everything lives in user://perf-tests/work (the server's
## write-data folder, its mods folder holding only the bridge, the map), and each test's Zenith gets
## its own user folder there (APPDATA and the XDG folders pointed at it for that process, as
## tests/test_env.gd does), with a settings.cfg of the test's preset. The player's settings, saves,
## add-ons and Factorio mods are never read or written.
##
## The test's map: seed 123456 from Factorio's own example settings, no enemies, no pollution,
## always noon. Its base, north-west of the character where the angled camera looks: 12 belt loops
## and an 8-loop bus full of items, 36 assemblers with inserters, a roboport with 50 robots flying.
## Each test: the character back at the start, Zenith full screen at the screen's resolution with
## sound off, --stutter-probe on the route ("stand" or the laps, "fast") and --probe-trace, which
## has the bridge write its cost per tick into Factorio's log as f3dtrace lines.

const ServerLauncher := preload("res://scripts/menu/server_launcher.gd")
const Paths := preload("res://scripts/menu/paths.gd")
const MapGen := preload("res://scripts/menu/map_gen.gd")
const StutterProbe := preload("res://scripts/debug/stutter_probe.gd")

const SEED := 123456
## Free ports from here up, away from the menu's servers (34500) and the docs' (34197-34200).
const PORT_BASE := 35700
## How long past its route a test's Zenith may run before it is stopped (loading, the warm-up).
const CLIENT_GRACE := 240.0
const TRACE_WAIT_MSEC := 30000
const LUA_TIMEOUT_MSEC := 60000
## The stutter probe's summary keys the results keep.
const PROBE_KEYS := ["frames", "p50", "p99", "worst", "over16", "over33", "over50", "gpu_p50", "gpu_p99", "render_cpu_p50",
	"process_p50", "process_p99", "draw_calls_p50", "primitives_p50"]
## The items in the twelve belt loops.
const LOOP_ITEMS := ["iron-plate", "copper-plate", "iron-gear-wheel", "electronic-circuit", "coal", "stone", "steel-plate",
	"copper-cable", "iron-ore", "copper-ore", "plastic-bar", "stone-brick"]
## The server: nobody joins, nothing saves or pauses by itself.
const SERVER_SETTINGS := {
	"name": "Zenith performance test", "description": "", "tags": [], "max_players": 0,
	"visibility": {"public": false, "lan": false}, "require_user_verification": false,
	"allow_commands": "admins-only", "autosave_interval": 0, "autosave_slots": 1, "afk_autokick_interval": 0,
	"auto_pause": false, "auto_pause_when_players_connect": false, "only_admins_can_pause_the_game": true,
	"autosave_only_on_server": true, "non_blocking_saving": false,
}

## user://perf-tests/work, as a full path.
var work := ""
var error := ""
## What the results file says about the game: factorio (version), space_age, buildings.
var info := {}
var launcher: ServerLauncher
var _exe := ""
var _child := -1
var _client_port := 0
var _cancelled := false


func _init() -> void:
	name = "PerfGame"
	work = ProjectSettings.globalize_path("user://perf-tests/work")


## The map, the server and the base. False with `error`. `say` takes (text, fraction).
func prepare(say: Callable) -> bool:
	error = ""
	_exe = Paths.factorio_exe()
	if _exe == "" or not FileAccess.file_exists(_exe):
		error = "Factorio wasn't found%s. Set factorio.exe in Settings > Factorio." % (" at " + _exe if _exe != "" else "")
		return false
	var installed := Paths.factorio_version(_exe)
	if installed != "" and _older(installed, "2.1.0"):
		error = "Zenith needs Factorio 2.1; this is %s." % installed
		return false
	for dir in ["factorio/saves", "runs", "appdata"]:
		DirAccess.make_dir_recursive_absolute(work.path_join(dir))
	for f in DirAccess.get_files_at(work.path_join("runs")):
		DirAccess.remove_absolute(work.path_join("runs").path_join(f))
	launcher = ServerLauncher.new()
	launcher.name = "PerfServer"
	launcher.data_dir = work.path_join("factorio")
	launcher.player_mods = false
	launcher.port_base = PORT_BASE
	launcher.server_settings_extra = SERVER_SETTINGS
	launcher.progress.connect(func(text: String, fraction: float) -> void: say.call(text, 0.02 + 0.1 * fraction))
	add_child(launcher)

	say.call("Making the test map…", 0.02)
	var map := work.path_join("factorio/saves/perf-test.zip")
	if FileAccess.file_exists(map):
		DirAccess.remove_absolute(map)
	if not await launcher.create_map(map, map_settings(_exe), str(SEED)) or _cancelled:
		error = "Factorio couldn't make the test map.\n" + launcher.error if not _cancelled else "cancelled"
		return false
	say.call("Starting Factorio in the background…", 0.08)
	if not await launcher.start(map) or _cancelled:
		error = "Factorio didn't start.\n" + launcher.error if not _cancelled else "cancelled"
		return false
	_client_port = launcher.client_port
	var text := FileAccess.get_file_as_string(launcher.log_path())
	var m := RegEx.create_from_string("Factorio (\\d+\\.\\d+\\.\\d+)").search(text)
	info["factorio"] = m.get_string(1) if m != null else (installed if installed != "" else "?")
	info["space_age"] = text.contains("Loading mod space-age")
	# The first command only warns that achievements go off.
	await _rcon("/sc rcon.print('ok')")
	await _rcon("/sc rcon.print('ok')")

	say.call("Building the test base…", 0.1)
	var built: Array[String] = []
	for step in base_steps():
		if _cancelled:
			error = "cancelled"
			return false
		var reply := await lua(step)
		built.append(reply)
		if reply.contains("Cannot execute command") or reply.contains("Error"):
			_write(work.path_join("base.txt"), "\n".join(built))
			error = "Building the test base failed: " + reply
			return false
	info["buildings"] = (await lua("rcon.print(game.surfaces.nauvis.count_entities_filtered({ area = { { -100, -90 }, { 3, 3 } }, force = 'player' }))")).strip_edges()
	_write(work.path_join("base.txt"), "\n".join(built))
	await get_tree().create_timer(5.0).timeout  # the belts and robots under way
	return not _cancelled


## One test: [look, preset, route]. The row's numbers ({} with `error` set when the game went).
func run_test(n: int, test: Array, child_settings: Dictionary) -> Dictionary:
	var look := str(test[0])
	var preset := str(test[1])
	var route := str(test[2])
	var started := Time.get_ticks_msec()
	var env := child_env()
	var user_dir: String = with_env(env, func() -> String: return OS.get_user_data_dir())
	DirAccess.make_dir_recursive_absolute(user_dir.path_join("logs"))
	var cfg := ConfigFile.new()
	for section in child_settings:
		for key in child_settings[section]:
			cfg.set_value(section, key, child_settings[section][key])
	cfg.save(user_dir.path_join("settings.cfg"))
	# The character back where it stands for every test, facing the base.
	await lua("for _, c in pairs(game.surfaces.nauvis.find_entities_filtered({ type = 'character' })) do c.walking_state = { walking = false, direction = defines.direction.north } c.teleport({ 0, 0 }) end rcon.print('ok')")
	var log_file := launcher.log_path()
	var offset := _size(log_file)
	_client_port = ServerLauncher.free_udp_port(_client_port + 1)
	var probe := work.path_join("runs/test%d-%s-%s-%s.json" % [n + 1, look, preset, route])
	var seconds := route_seconds(route)
	var ticks := int(seconds * 60.0)
	var args := PackedStringArray()
	if not OS.has_feature("template"):
		args.append_array(["--path", ProjectSettings.globalize_path("res://")])
	args.append_array(["--audio-driver", "Dummy", "--", "--factorio-port=%d" % launcher.udp_port, "--port=%d" % _client_port,
		"--stutter-probe=%s@%s" % [probe, route], "--probe-trace=%d" % ticks])
	_child = with_env(env, func() -> int: return OS.create_process(OS.get_executable_path(), args))
	var row := {}
	if _child <= 0:
		_child = -1
		error = "Zenith couldn't start itself for the test."
		return {}
	print("perf test: test %d (%s, %s, %s) in Zenith pid %d" % [n + 1, look, preset, route, _child])
	while OS.is_process_running(_child):
		await get_tree().create_timer(0.5).timeout
		if _cancelled:
			_end_child()
			error = "cancelled"
			return {}
		if not launcher.is_running():
			_end_child()
			error = "Factorio stopped during a test.\n" + launcher._log_errors(0)
			return {}
		if Time.get_ticks_msec() - started > (seconds + CLIENT_GRACE) * 1000.0:
			_end_child()
			row["note"] = "Zenith ran past its time and was stopped"
			break
	_child = -1
	var godot_log := user_dir.path_join("logs/godot.log")
	if FileAccess.file_exists(godot_log):
		DirAccess.copy_absolute(godot_log, probe.get_basename() + ".log")
	if FileAccess.file_exists(probe):
		row.merge(probe_numbers(FileAccess.get_file_as_string(probe)))
	# The bridge's cost per tick and the game's speed, from its trace of the walk.
	var wait := Time.get_ticks_msec()
	var text := ""
	while true:
		await get_tree().create_timer(2.0).timeout
		text = _read_from(log_file, offset)
		if RegEx.create_from_string("f3dtrace \\d+ TOTAL").search_all(text).size() >= ticks or Time.get_ticks_msec() - wait > TRACE_WAIT_MSEC or _cancelled:
			break
	row.merge(trace_numbers(text))
	row["seconds"] = (Time.get_ticks_msec() - started) / 1000.0
	return row


## Stops at once: the test's Zenith, Factorio making the map, or the server still starting (their
## waits then end and report "cancelled").
func cancel() -> void:
	_cancelled = true
	_end_child()
	if launcher != null:
		if launcher._helper_pid > 0 and OS.is_process_running(launcher._helper_pid):
			OS.kill(launcher._helper_pid)
		launcher.kill_now()


## The server stopped (no save: the map is made again each run) and anything else this started.
func stop() -> void:
	_end_child()
	if launcher != null:
		await launcher.stop(false)


func _exit_tree() -> void:
	_end_child()  # the launcher, a child of this, ends the server in its own _exit_tree


func _end_child() -> void:
	if _child > 0 and OS.is_process_running(_child):
		OS.kill(_child)
	_child = -1


# --- the map and the base ------------------------------------------------------------------------

## Factorio's own example settings with no enemies and no pollution (trees stay as they are).
static func map_settings(exe: String) -> Dictionary:
	var gen := MapGen._example(exe, "map-gen-settings.example.json")
	var map := MapGen._example(exe, "map-settings.example.json")
	gen["peaceful_mode"] = true
	var controls = gen.get("autoplace_controls")
	if controls is Dictionary and controls.get("enemy-base") is Dictionary:
		controls["enemy-base"]["frequency"] = 0
		controls["enemy-base"]["size"] = 0
	for key in ["pollution", "enemy_evolution", "enemy_expansion"]:
		if map.get(key) is Dictionary:
			map[key]["enabled"] = false
	return {"gen": gen, "map": map}


## The base's Lua, one RCON command each (the lines are joined, so no "--" comments in them).
static func base_steps() -> Array[String]:
	var steps: Array[String] = [GROUND, CLEAR]
	for top in [-76, -69, -62]:
		steps.append(PRELUDE + ASSEMBLERS.replace("$TOP", str(top)))
	for i in LOOP_ITEMS.size():
		steps.append(PRELUDE + LOOP.replace("$ITEM", LOOP_ITEMS[i]).replace("$I", str(i)))
	steps.append(PRELUDE + BUS)
	steps.append(PRELUDE + ROBOTS)
	return steps


## Lua in the game's own state.
func lua(code: String) -> String:
	var lines := PackedStringArray()
	for line in code.split("\n"):
		lines.append(line.strip_edges())
	return await _rcon("/sc " + " ".join(lines))


func _rcon(command: String) -> String:
	if launcher == null or not launcher.rcon.is_open():
		return "Error: RCON isn't connected"
	return (await launcher.rcon.run(get_tree(), command, LUA_TIMEOUT_MSEC)).strip_edges()


const PRELUDE := """local s = game.surfaces.nauvis local f = game.forces.player local made = 0
local E, S, W, N = defines.direction.east, defines.direction.south, defines.direction.west, defines.direction.north
local function mk(spec) spec.force = f spec.raise_built = true local e = s.create_entity(spec) if e then made = made + 1 end return e end
local function ins(name, x, y, tx, ty, d) local e = mk({ name = name, position = { x, y }, direction = d })
  if e then local p = e.drop_position if (p.x - tx) ^ 2 + (p.y - ty) ^ 2 > 0.5 then e.direction = (d + 8) % 16 end end return e end
local function eei(x, y) local e = mk({ name = "electric-energy-interface", position = { x, y } })
  if e then e.power_production = 1e9 / 60 e.electric_buffer_size = 1e9 end return e end
local function fill(belts, item) local n = 0 for _, b in pairs(belts) do if b then for l = 1, 2 do local line = b.get_transport_line(l)
  for p = 0, 0.75, 0.25 do if line.insert_at(p, { name = item, count = 1 }) then n = n + 1 end end end end end return n end
"""

## Noon for ever, the force running at exoskeleton speed (the laps), the ground made.
const GROUND := """local s = game.surfaces.nauvis
s.freeze_daytime = true s.daytime = 0
game.forces.player.character_running_speed_modifier = 2.4
game.map_settings.pollution.enabled = false
game.map_settings.enemy_expansion.enabled = false
s.request_to_generate_chunks({ 0, 0 }, 8)
s.force_generate_chunk_requests()
rcon.print("ground")"""

## The base's ground and the laps' path cleared of trees, rocks and cliffs, water filled.
const CLEAR := """local s = game.surfaces.nauvis
local areas = { { { -100, -90 }, { 3, 3 } }, { { -4, -4 }, { 160, 4 } }, { { 149, -97 }, { 157, 97 } }, { { -157, 88 }, { 157, 97 } },
  { { -157, -97 }, { -149, 97 } }, { { -157, -97 }, { 157, -88 } } }
local water = {}
for name, t in pairs(prototypes.tile) do if t.collision_mask.layers["water_tile"] then water[#water + 1] = name end end
local n, w = 0, 0
for _, a in pairs(areas) do
  for _, e in pairs(s.find_entities_filtered({ area = a, type = { "tree", "simple-entity", "cliff", "fish", "simple-entity-with-owner", "container" } })) do e.destroy() n = n + 1 end
  local tiles = {}
  for _, t in pairs(s.find_tiles_filtered({ area = a, name = water })) do tiles[#tiles + 1] = { name = "landfill", position = t.position } end
  w = w + #tiles
  if #tiles > 0 then s.set_tiles(tiles) end
end
rcon.print(n .. " cleared, " .. w .. " water tiles filled")"""

## A row of 12 assemblers making gears: infinity chest, inserter, assembler, fast inserter, a chest that empties itself.
const ASSEMBLERS := """if $TOP == -76 then eei(-69, -80) end
for i = 0, 11 do
  local x = -66 + i * 5 local y = $TOP
  local chest = mk({ name = "infinity-chest", position = { x + 1.5, y + 0.5 } })
  if chest then chest.set_infinity_container_filter(1, { name = "iron-plate", count = 100, index = 1 }) end
  ins("inserter", x + 1.5, y + 1.5, x + 1.5, y + 2.5, S)
  local a = mk({ name = "assembling-machine-2", position = { x + 1.5, y + 3.5 } })
  if a then a.set_recipe("iron-gear-wheel") end
  ins("fast-inserter", x + 1.5, y + 5.5, x + 1.5, y + 6.5, S)
  local sink = mk({ name = "infinity-chest", position = { x + 1.5, y + 6.5 } })
  if sink then sink.remove_unfiltered_items = true end
  if i % 3 == 0 then mk({ name = "substation", position = { x + 4, y + 1 } }) end
end
rcon.print(made)"""

## A belt loop, 60 long, full of items that keep going round.
const LOOP := """local y = -45 + $I * 3 local x0 = -66 local L = 60 local belts = {}
for x = 0, L - 1 do
  belts[#belts + 1] = mk({ name = "transport-belt", position = { x0 + x + 0.5, y + 0.5 }, direction = x == L - 1 and S or E })
  belts[#belts + 1] = mk({ name = "transport-belt", position = { x0 + x + 0.5, y + 1.5 }, direction = x == 0 and N or W })
end
rcon.print(made .. " " .. fill(belts, "$ITEM"))"""

## A main bus to the west: eight loops of two lanes, 60 long.
const BUS := """local items = { "iron-plate", "copper-plate", "iron-gear-wheel", "electronic-circuit", "coal", "stone", "steel-plate", "copper-cable" }
local x0, y0, L = -90, -80, 60 local n = 0
for p = 0, 7 do
  local x = x0 + 2 * p local belts = {}
  for y = 0, L - 1 do
    belts[#belts + 1] = mk({ name = "transport-belt", position = { x + 0.5, y0 + y + 0.5 }, direction = y == 0 and E or N })
    belts[#belts + 1] = mk({ name = "transport-belt", position = { x + 1.5, y0 + y + 0.5 }, direction = y == L - 1 and W or S })
  end
  n = n + fill(belts, items[p + 1])
end
rcon.print(made .. " " .. n)"""

## A roboport whose 50 robots carry plates from a provider chest to a requester all the time.
const ROBOTS := """eei(-61, -3)
mk({ name = "substation", position = { -66, -7 } })
mk({ name = "substation", position = { -51, -7 } })
local port = mk({ name = "roboport", position = { -56, -5 } })
if port then port.get_inventory(defines.inventory.roboport_robot).insert({ name = "logistic-robot", count = 50 }) end
local src = mk({ name = "infinity-chest", position = { -65.5, -4.5 } })
if src then src.set_infinity_container_filter(1, { name = "iron-plate", count = 100, index = 1 }) end
ins("fast-inserter", -64.5, -4.5, -63.5, -4.5, E)
mk({ name = "passive-provider-chest", position = { -63.5, -4.5 } })
local req = mk({ name = "requester-chest", position = { -45.5, -4.5 } })
local ok = req and pcall(function()
  local sec = req.get_logistic_sections().add_section()
  sec.filters = { { value = { type = "item", name = "iron-plate", quality = "normal", comparator = "=" }, min = 200 } }
end)
ins("fast-inserter", -44.5, -4.5, -43.5, -4.5, E)
local sink = mk({ name = "infinity-chest", position = { -43.5, -4.5 } })
if sink then sink.remove_unfiltered_items = true end
rcon.print(made .. (ok and " request set" or " no request"))"""


# --- each test's Zenith ---------------------------------------------------------------------------

## The environment a test's Zenith runs in: its user folder (user://) inside the work folder. On
## Windows that follows APPDATA, on Linux XDG_DATA_HOME, on macOS HOME.
func child_env() -> Dictionary:
	var root := work.path_join("appdata")
	var env := {"APPDATA": root.replace("/", "\\") if OS.get_name() == "Windows" else root, "XDG_DATA_HOME": root, "XDG_CONFIG_HOME": root}
	if OS.get_name() != "Windows":
		env["HOME"] = root
	return env


## Calls `f` with these environment variables set, then puts them back: a process started in `f`
## keeps them, and this one goes on as before.
static func with_env(vars: Dictionary, f: Callable) -> Variant:
	var before := {}
	for key in vars:
		before[key] = OS.get_environment(key) if OS.has_environment(key) else null
		OS.set_environment(key, str(vars[key]))
	var out: Variant = f.call()
	for key in before:
		if before[key] == null:
			OS.unset_environment(key)
		else:
			OS.set_environment(key, str(before[key]))
	return out


## How long a stutter probe route walks, in seconds.
static func route_seconds(route: String) -> float:
	var s := 0.0
	for leg in StutterProbe.ROUTES.get(route, []):
		s += float(leg[1])
	return s


## The stutter probe's summary of the walk.
static func probe_numbers(json: String) -> Dictionary:
	var out := {}
	var parsed = JSON.parse_string(json)
	if not parsed is Dictionary or not parsed.get("summary") is Dictionary or not parsed["summary"].get("walk") is Dictionary:
		return out
	var walk: Dictionary = parsed["summary"]["walk"]
	for key in PROBE_KEYS:
		if walk.get(key) is float or walk.get(key) is int:
			out[key] = float(walk[key])
	return out


## The bridge's time per tick (average, slowest 1%, worst) and the game's UPS, from the f3dtrace
## lines of Factorio's log: ticks where the client was served (belt items or movers sent).
static func trace_numbers(text: String) -> Dictionary:
	var out := {}
	var bridge := {}
	var stamps := {}
	var served := {}
	var re := RegEx.create_from_string("(?m)^\\s*([0-9.]+) [^\\r\\n]*?f3dtrace (\\d+) (bridge|belt_items|movers) Duration: ([0-9.]+) ?ms")
	for m in re.search_all(text):
		var t := int(m.get_string(2))
		stamps[t] = float(m.get_string(1))
		if m.get_string(3) == "bridge":
			bridge[t] = float(m.get_string(4))
		else:
			served[t] = true
	var ticks: Array = served.keys().filter(func(t: int) -> bool: return bridge.has(t))
	ticks.sort()
	if ticks.size() <= 10:
		return out
	var costs: Array = ticks.map(func(t: int) -> float: return bridge[t])
	costs.sort()
	var total := 0.0
	for c in costs:
		total += c
	out["bridge_avg"] = total / costs.size()
	out["bridge_p99"] = costs[mini(costs.size() - 1, ceili(0.99 * costs.size()) - 1)]
	out["bridge_worst"] = costs[-1]
	var span: float = stamps[ticks[-1]] - stamps[ticks[0]]
	if span > 0.0:
		out["ups"] = (int(ticks[-1]) - int(ticks[0])) / span
	return out


static func _older(version: String, than: String) -> bool:
	var a := version.split(".")
	var b := than.split(".")
	for i in mini(a.size(), b.size()):
		if int(a[i]) != int(b[i]):
			return int(a[i]) < int(b[i])
	return a.size() < b.size()


static func _size(path: String) -> int:
	var f := FileAccess.open(path, FileAccess.READ)
	return f.get_length() if f != null else 0


## What a file (Factorio's log, still being written) holds past `offset`.
static func _read_from(path: String, offset: int) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null or f.get_length() <= offset:
		return ""
	f.seek(offset)
	return f.get_buffer(f.get_length() - offset).get_string_from_utf8()


static func _write(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_string(text + "\n")
