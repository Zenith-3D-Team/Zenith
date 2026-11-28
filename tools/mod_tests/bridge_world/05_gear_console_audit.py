# Bridge test slice 05_gear_console_audit.py (lines 8191-9376 of original test_bridge.py)
# --- the character's gear: armour grid, toggles, character info, players, death ----------------------
grid = F.make_grid(10, 10)
puppet.grid = grid
main = puppet.get_main_inventory()
main.insert(lua.table_from({"name": "energy-shield-equipment", "count": 2}))
main.insert(lua.table_from({"name": "exoskeleton-equipment", "count": 1}))
main.insert(lua.table_from({"name": "battery-equipment", "count": 1}))
gear_slots = {main[i].name: i for i in range(1, 81) if main[i].valid_for_read}
# As after a handshake: everything once.
g.storage.f3d.eq_sent = lua.table_from({})
g.storage.f3d.info_sig = None
g.storage.f3d.pl_sig = None
tick(61)
msgs = take()
eqs = [m for m in of_type(msgs, "eq") if m["kind"] == "char"]
check(eqs and eqs[-1]["w"] == 10 and eqs[-1]["h"] == 10 and eqs[-1]["l"] == [] and eqs[-1]["u"] == puppet.unit_number,
      f"eq: the character's empty 10x10 armour grid: {eqs[-1:]}")
veh = [m for m in of_type(msgs, "eq") if m["kind"] == "veh"]
check(veh and veh[-1]["w"] == 0 and veh[-1]["u"] == 0, f"eq: no vehicle grid: {veh[-1:]}")
cinfo = of_type(msgs, "cinfo")
check(cinfo and cinfo[-1]["reach"] == 100 and cinfo[-1]["craft"] == 1000 and cinfo[-1]["slots"] == 80 and cinfo[-1]["hp"] == 250,
      f"cinfo: reach, crafting speed, slots and health: {cinfo[-1:]}")
check(cinfo and cinfo[-1].get("mwf") == 0, f"cinfo: the force can't mine with fluid yet on a new map (mwf 0): {cinfo[-1:]}")
g.game.forces.player.mining_with_fluid = True
g.storage.f3d.info_sig = None  # (sent on the next tick, not waiting for its once-a-second round)
tick(1)
cinfo2 = of_type(take(), "cinfo")
check(cinfo2 and cinfo2[-1].get("mwf") == 1, f"cinfo: once it can (Uranium mining researched), mwf 1: {cinfo2[-1:]}")
g.game.forces.player.mining_with_fluid = False
pl = of_type(msgs, "pl")
check(pl and pl[-1]["me"] == 0 and pl[-1]["u"] == puppet.unit_number, f"pl: the bridge's own character plays no player: {pl[-1:]}")
send({"t": "eq_put", "kind": "char", "fi": gear_slots["energy-shield-equipment"], "x": 2, "y": 0})
send({"t": "eq_put", "kind": "char", "fi": gear_slots["exoskeleton-equipment"]})  # Shift+click: the first place it fits
send({"t": "eq_put", "kind": "char", "fi": gear_slots["energy-shield-equipment"], "x": 3, "y": 1})  # overlaps the first
send({"t": "eq_put", "kind": "char", "fi": gear_slots["battery-equipment"], "x": 9, "y": 9})  # doesn't fit at the edge
tick(1)
msgs = take()
placed = sorted((e.name, e.position.x, e.position.y) for e in grid.equipment.values())
check(placed == [("energy-shield-equipment", 2, 0), ("exoskeleton-equipment", 0, 0)],
      f"eq_put: at a position, Shift+click in the first place it fits, refusals where it overlaps or sticks out: {placed}")
check(main.get_item_count("energy-shield-equipment") == 1 and main.get_item_count("exoskeleton-equipment") == 0
      and main.get_item_count("battery-equipment") == 1, "eq_put takes one from the inventory slot only when it was placed")
check(texts(msgs).count("No room for that in the grid") == 2, f"refusals say so: {texts(msgs)}")
eqs = [m for m in of_type(msgs, "eq") if m["kind"] == "char"]
rec = {r[0]: r for r in (eqs[-1]["l"] if eqs else [])}
check(eqs and rec.get("energy-shield-equipment", [])[:6] == ["energy-shield-equipment", 2, 0, 2, 2, "normal"]
      and rec["energy-shield-equipment"][8:10] == [25, 50] and eqs[-1]["msh"] == 50 and eqs[-1]["sh"] == 25
      and eqs[-1]["mv"] == 300 and eqs[-1]["mvon"] == 1 and eqs[-1]["rb"] == 1,
      f"eq is sent at once after a change, with shields, movement bonus and the roboport switch: {eqs[-1:]}")
mes = of_type(msgs, "me") or of_type((tick(2), take())[1], "me")
check(mes and mes[-1].get("sd") == 25 and mes[-1].get("msd") == 50, f"me carries the armour's shields: {mes[-1:]}")
send({"t": "eq_move", "kind": "char", "x": 3, "y": 1, "tx": 6, "ty": 6})
send({"t": "eq_move", "kind": "char", "x": 0, "y": 0, "tx": 5, "ty": 5})  # onto the shield
tick(1)
placed = sorted((e.name, e.position.x, e.position.y) for e in grid.equipment.values())
check(placed == [("energy-shield-equipment", 6, 6), ("exoskeleton-equipment", 0, 0)],
      f"eq_move: by any cell of it, refused where it overlaps: {placed}")
empty = next(i for i in range(1, 81) if not main[i].valid_for_read)
send({"t": "eq_take", "kind": "char", "x": 7, "y": 7, "ti": empty})
tick(1)
check(len(grid.equipment) == 1 and main[empty].valid_for_read and main[empty].name == "energy-shield-equipment",
      "eq_take: by any cell, into the slot asked for")
send({"t": "eq_toggle", "what": "roboport", "on": 0})
send({"t": "eq_toggle", "what": "movement", "on": 0})
tick(1)
eqs = [m for m in of_type(take(), "eq") if m["kind"] == "char"]
check(not puppet.allow_dispatching_robots and grid.inhibit_movement_bonus and eqs and eqs[-1]["rb"] == 0 and eqs[-1]["mvon"] == 0
      and eqs[-1]["mv"] == 0, f"eq_toggle: Alt+F turns the personal roboport off, Alt+E the exoskeletons: {eqs[-1:]}")
send({"t": "eq_toggle", "what": "movement", "on": 1})
tick(1)
take()
car = F.spawn("car", puppet.position.x + 2, puppet.position.y, lua.table_from({"force": "player"}))
car.grid = F.make_grid(4, 4)
send(open_cmd(car))
tick(31)
veh = [m for m in of_type(take(), "eq") if m["kind"] == "veh"]
check(veh and veh[-1]["u"] == car.unit_number and veh[-1]["w"] == 4, f"eq: the open car's grid: {veh[-1:]}")
send({"t": "eq_put", "kind": "veh", "u": car.unit_number, "fi": gear_slots["battery-equipment"], "x": 0, "y": 0})
tick(1)
check(len(car.grid.equipment) == 1 and main.get_item_count("battery-equipment") == 0, "eq_put into a vehicle's grid")
send({"t": "close"})
tick(1)
take()
# Death: the bridge's own character waits out the respawn time, then comes back at the spawn.
dead_unit = puppet.unit_number
puppet.teleport(lua.table_from({"x": 30, "y": 30}))
F["raise"]("on_entity_died", lua.table_from({"entity": puppet}))
puppet.destroy()
tick(30)
msgs = take()
dead = of_type(msgs, "dead")
check(dead and 560 <= dead[-1]["left"] <= 600 and dead[-1]["x"] == fixed(30) and not of_type(msgs, "me") and not of_type(msgs, "welcome"),
      f"dead: while dead the client hears how long until the respawn, and where it died: {dead[-1:]}")
send({"t": "respawn"})
for _ in range(5):
    send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
    tick(100)
check(not (g.storage.f3d.puppet and g.storage.f3d.puppet.valid), "Respawn before the time is up does nothing")
take()
send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
tick(80)
msgs = take()
new = g.storage.f3d.puppet
welcome = of_type(msgs, "welcome")
check(new and new.valid and new.unit_number != dead_unit and new.position.x == 0 and new.position.y == 0
      and welcome and welcome[-1]["u"] == new.unit_number, "after the respawn time a new character at the spawn, with a welcome")
check(g.storage.f3d.respawn is None and g.storage.f3d.death is None, "and the death is forgotten")
new_main = new.get_main_inventory()
new_guns = new.get_inventory(g.defines.inventory.character_guns)
new_ammo = new.get_inventory(g.defines.inventory.character_ammo)
check(new_main.get_item_count("iron-plate") == 0 and new_main.get_item_count("burner-mining-drill") == 0
      and new_main.get_item_count("stone-furnace") == 0 and new_main.get_item_count("wood") == 0
      and new_guns.get_item_count("pistol") + new_main.get_item_count("pistol") == 1
      and new_ammo.get_item_count("firearm-magazine") + new_main.get_item_count("firearm-magazine") == 10,
      "the respawned character gets freeplay's respawn items (a pistol, 10 magazines), not the new player's kit")
new.insert(lua.table_from({"name": "iron-plate", "count": 8}))  # (the takeover below carries it over)
puppet = new

# --- taking over a save's character (a single-player save on a server) -----------------------------
def player_console(parameter):
    before = len(F.printed)
    F.commands["f3d-player"](lua.table_from({"name": "f3d-player", "parameter": parameter}))
    return [str(p) for p in list(F.printed.values())[before:]]


owner = F.make_offline_player(1, "owner", 20.5, 5.5)
owner.get_main_inventory().insert(lua.table_from({"name": "iron-gear-wheel", "count": 20}))
owner.get_main_inventory().set_filter(5, "wood")
# Filters keep their quality (2.1: a name alone means normal only): a rare item, and any quality.
owner.get_main_inventory().set_filter(6, lua.table_from({"name": "iron-plate", "quality": "rare", "comparator": "="}))
owner.get_main_inventory().set_filter(7, lua.table_from({"name": "coal"}))
owner.get_inventory(g.defines.inventory.character_armor).insert(lua.table_from({"name": "light-armor", "count": 1}))
owner.get_requester_point().add_section("Main").filters = lua.table_from(
    [{"value": {"type": "item", "name": "iron-plate", "quality": "normal", "comparator": "="}, "min": 100}], recursive=True)
owner.set_quick_bar_slot(1, 1, "transport-belt")
old_puppet = puppet
lines = player_console("")
check(any("owner, not connected" in l for l in lines), f"/f3d-player lists the save's players: {lines}")
lines = player_console("owner")
stand_in = g.storage.f3d.puppet
check(stand_in != old_puppet and not old_puppet.valid and stand_in.position.x == 20.5 and stand_in.position.y == 5.5
      and g.storage.f3d.held_for == 1 and any("(playing as)" in l for l in lines),
      f"/f3d-player owner: a stand-in where the owner's character was, the old bridge character gone: {lines}")
tick(2)
msgs = take()
welcome = of_type(msgs, "welcome")
check(welcome and welcome[-1]["u"] == stand_in.unit_number and welcome[-1]["x"] == fixed(20.5),
      "a new handshake names the stand-in")
tick(60)
msgs += take()
main = stand_in.get_main_inventory()
check(main.get_item_count("iron-gear-wheel") == 20 and owner.get_main_inventory().get_item_count("iron-gear-wheel") == 0,
      "the owner's inventory moved onto the stand-in")
check(main.get_filter(5) is not None and main.get_filter(5)["name"] == "wood", "slot filters moved too")
f6, f7 = main.get_filter(6), main.get_filter(7)
check(f6 is not None and f6["name"] == "iron-plate" and f6["quality"] == "rare" and f7 is not None and f7["name"] == "coal"
      and f7["quality"] is None and owner.get_main_inventory().get_filter(6) is None,
      f"slot filters keep their quality, and any quality stays any: {dict(f6) if f6 else f6}, {dict(f7) if f7 else f7}")
armor = stand_in.get_inventory(g.defines.inventory.character_armor)
check(armor[1].valid_for_read and armor[1].name == "light-armor", "the armour moved")
check(main.get_item_count("iron-plate") >= 1, "what the old bridge character carried was kept")
clog = of_type(msgs, "clog")
check(clog and ["iron-plate", 100, -1] in clog[-1]["l"], f"the owner's logistic requests (a group section) are the stand-in's: {clog}")
qb = of_type(msgs, "qb")
check(qb and qb[-1]["l"][0] == "transport-belt", "the quickbar is the owner's")
send({"t": "set_char_requests", "l": [["iron-plate", 150, -1], ["iron-gear-wheel", 10, -1]]})
tick(1)
point = stand_in.get_requester_point()
groups = [s.group for s in point.sections.values()]
main_group = F.logistic_groups["Main"]
check(len(main_group) == 1 and main_group[1].min == 150 and groups == ["Main", ""] and point.get_section(2).filters[1].value.name == "iron-gear-wheel",
      f"editing the requests keeps each in its section, new ones in a section of their own ({groups})")
take()
# The owner joins with the real game: everything goes back, and the bridge plays their character.
real = spawn("character", 30.5, 5.5, force="player")
F.connect_player(owner, real)
tick(2)
msgs = take()
check(g.storage.f3d.puppet.unit_number == real.unit_number and not stand_in.valid and g.storage.f3d.held_for is None
      and real.get_main_inventory().get_item_count("iron-gear-wheel") == 20 and real.position.x == 20.5,
      "when the owner joins, their things move back onto their character, which stands where the stand-in was")
welcome = of_type(msgs, "welcome")
check(welcome and welcome[-1]["u"] == real.unit_number, "and the client plays it")
# The Zenith button in the real game's top-left mod buttons (zenith_button.lua), added when the
# player joins: clicking it does what Ctrl+F9 does there.
zbtn = g.game.get_player(1).gui.top["mod_gui_top_frame"]["mod_gui_inner_frame"]["f3d-zenith-button"]
check(zbtn is not None and zbtn.sprite == "f3d-zenith-gear" and zbtn.style.name == "mod_gui_button",
      "the Zenith button is in the player's top-left mod buttons, with the gear logo")
take()
F["raise"]("on_gui_click", lua.table_from({"player_index": 1, "element": zbtn}))
check(of_type(take(), "raise"), "clicking it brings the client to the front, as Ctrl+F9 does (raise)")
# C7: "Show in Zenith" in the real game brings the client playing that player to the front.
F.handlers["f3d-show-3d"](lua.table_from({"player_index": 1, "input_name": "f3d-show-3d"}))
check(of_type(take(), "raise"), "Ctrl+F9 in the real game tells the client to come to the front (raise)")
g.storage.f3d.client.raised = None  # a live Zenith's next hello clears it
# With no Zenith playing them, it asks the launcher beside Factorio (port 34209) to start one,
# from the pressing player's own machine.
kept_client = g.storage.f3d.client
g.storage.f3d.client = None
F.handlers["f3d-show-3d"](lua.table_from({"player_index": 1, "input_name": "f3d-show-3d"}))
launch = [json.loads(item[2]) for item in F.take_sent().values() if item[1] == 34209]
g.storage.f3d.client = kept_client
check(len(launch) == 1 and launch[0]["t"] == "launch",
      f"Ctrl+F9 with no client connected asks Zenith's launcher on 34209 to start Zenith ({launch})")
# The owner's bug: with no launcher running nothing answered and nothing showed. Two seconds
# without its `launching` opens the bridge's window saying what to set up.
screen = g.game.get_player(1).gui.screen
check(screen["f3d-launch-help"] is None, "no help window while the launcher still has time to answer")
tick(121)
help_win = screen["f3d-launch-help"]
kids = list(help_win.children.values()) if help_win is not None else []
field = [k.text for k in kids if k.type == "textfield"]
captions = [str(k.caption[1]) for k in kids if k.type == "label"]
check(help_win is not None and help_win.auto_centered and len(field) == 2 and "Zenith-3D-Team/Zenith/releases" in field[0]
      and "factorio-with-zenith.ps1" in field[1] and "%command%" in field[1]
      and "f3d-launch.step1" in captions and "f3d-launch.step2" in captions,
      f"no answer from the launcher: both steps, Zenith's download page and the launch options line to copy ({captions})")
close = [k for k in kids if k.type == "button"]
F["raise"]("on_gui_click", lua.table_from({"player_index": 1, "element": close[0]}))
check(screen["f3d-launch-help"] is None and not help_win.valid, "its Close button closes it")
take()
# The launcher answers from its own port: no window. A packet from any other port isn't it.
g.storage.f3d.client = None
F.handlers["f3d-show-3d"](lua.table_from({"player_index": 1, "input_name": "f3d-show-3d"}))
F.take_sent()
F.packet('{"t":"launching"}', 34199, 1)
F.packet('{"t":"launching"}', 34209, 1)
g.storage.f3d.client = kept_client
tick(121)
check(screen["f3d-launch-help"] is None and not g.storage.f3d.launch_wait[1],
      "the launcher's `launching` from 34209 clears the wait: no window")
check(any("f3d-launch.starting" in str(p) for p in F.printed.values()),
      "and the player is told Zenith is on its way (it takes a while to start and join)")
# The launcher is there but has no Zenith to start (never opened on this PC, or moved): the game
# says so, with only the step that is missing.
take()
g.storage.f3d.client = None
F.handlers["f3d-show-3d"](lua.table_from({"player_index": 1, "input_name": "f3d-show-3d"}))
F.take_sent()
F.packet('{"t":"launching","need":"zenith","moved":1}', 34209, 1)
g.storage.f3d.client = kept_client
help_win = screen["f3d-launch-help"]
kids = list(help_win.children.values()) if help_win is not None else []
field = [k.text for k in kids if k.type == "textfield"]
captions = [str(k.caption[1]) for k in kids if k.type == "label"]
check(help_win is not None and "f3d-launch.step1-moved" in captions and "f3d-launch.step2-done" in captions
      and len(field) == 1 and "releases" in field[0],
      f"the launcher has no Zenith to start (moved): the window says so at once, the launch options step done ({captions})")
help_win.destroy()
# The owner's bug: on a loaded save the key did nothing for a while, because the save keeps the
# client it was saved with and the bridge raised that gone client until the timeout. A client not
# heard from in 3 s isn't raised: the launcher is asked instead.
take()
F.take_sent()
seen = kept_client.last_seen
kept_client.last_seen = g.game.tick - 400
F.handlers["f3d-show-3d"](lua.table_from({"player_index": 1, "input_name": "f3d-show-3d"}))
launch = [json.loads(item[2]) for item in F.take_sent().values() if item[1] == 34209]
check(launch and not of_type(take(), "raise"),
      "a client from the save, silent for seconds, isn't raised: the launcher is asked to start Zenith")
kept_client.last_seen = seen
g.storage.f3d.launch_wait = None
take()
# The owner's bug, again: a save made while Zenith was connected keeps its client heard a moment
# before the save's tick, and the tick goes on from there, so it looked fresh after loading. In
# single-player a loaded game raises nobody until the client says hello after the load.
was_mp = F.multiplayer
F.multiplayer = False
F.take_sent()
kept_client.last_seen = g.game.tick
F.on_load()
F.handlers["f3d-show-3d"](lua.table_from({"player_index": 1, "input_name": "f3d-show-3d"}))
launch = [json.loads(item[2]) for item in F.take_sent().values() if item[1] == 34209]
check(launch and not of_type(take(), "raise"),
      "a save's client heard just before the save isn't raised after loading it: the launcher is asked")
g.storage.f3d.launch_wait = None
send({"t": "hello", "v": 1, "sid": kept_client.sid, "w": 1}, kept_client.port)
tick(1)
take()
F.handlers["f3d-show-3d"](lua.table_from({"player_index": 1, "input_name": "f3d-show-3d"}))
check(of_type(take(), "raise"), "once that Zenith says hello after the load, the key raises it")
check(any("f3d-launch.raising" in str(p) for p in F.printed.values()),
      "and the player is told it is switching to Zenith")
# A raised Zenith that never answers (closed, hung) is taken for gone: the player is told and the
# launcher asked, so the key never looks dead.
F.take_sent()
old_sid = kept_client.sid
g.storage.f3d.client.raised.tick = g.game.tick - 100  # pressed 100 ticks ago,
g.storage.f3d.client.last_seen = g.game.tick - 101  # and not heard from since
tick(1)
launch = [json.loads(item[2]) for item in F.take_sent().values() if item[1] == 34209]
g.storage.f3d.client.last_seen = g.game.tick
check(launch and g.storage.f3d.client is not None and g.storage.f3d.client.raised is None
      and any("f3d-launch.raise-lost" in str(p) for p in F.printed.values()),
      "a raised Zenith silent for 1.5 s isn't waited for: the player is told and the launcher asked")
g.storage.f3d.launch_wait = None
send({"t": "hello", "v": 1, "sid": old_sid, "w": 1}, kept_client.port)
tick(1)
take()
F.multiplayer = was_mp
take()
# Each player's row says what armour their character wears (the client draws its look).
g.storage.f3d.pl_sig = None
tick(60)
pl = of_type(take(), "pl")
rows = {r[1]: r for r in (pl[-1]["l"] if pl else [])}
check(len(rows.get("owner", [])) == 12 and rows["owner"][11] == "light-armor",
      f"pl: a player's row ends with their character's armour: {pl[-1:]}")
# Leave the harness as before for the single-player checks.
F.players[1] = None
F.players_by[1] = None
F.players_by["owner"] = None
puppet = real

# --- the client's console: cmd / cmdr, and the zenith remote interface -------------------------
send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
tick(1)
take()


def console(text, cid):
    send({"t": "cmd", "id": cid, "text": text})
    tick(1)
    replies = [m for m in of_type(take(), "cmdr") if m["id"] == cid]
    return replies[-1] if replies else None


r = console("/version", 1)
check(r and r["l"] == ["2.1.23"] and "ok" not in r, f"cmd /version: the bridge answers with cmdr: {r}")
r = console("/seed", 2)
check(r and r["l"] == ["123456789"], f"cmd /seed: {r}")
r = console("/time", 3)
check(r and r["l"] == ["1 hour, 2 minutes and 5 seconds"], f"cmd /time in Factorio's words: {r}")
r = console("/evolution", 4)
check(r and "Evolution factor: 0.2500. (Time 60%) (Pollution 20%) (Spawner kills 20%)" in r["l"][0], f"cmd /evolution: {r}")
r = console("/evolution nowhere", 53)
check(r and r["l"] == ['Surface "nowhere" does not exist.'], f"cmd /evolution with an unknown surface says so, not the character's: {r}")
r = console("/players", 5)
check(r and r["l"][0].startswith("Players ("), f"cmd /players: {r}")
r = console("/players online count", 51)
check(r and len(r["l"]) == 1 and r["l"][0].startswith("Online players ("), f"cmd /players online count: header only, 'Online players (n):': {r}")
r = console("/players c", 52)
check(r and len(r["l"]) == 1 and r["l"][0].startswith("Players ("), f"cmd /players c: the count only: {r}")
r = console("/f3d-status", 6)
check(r and any(str(l).startswith("[Zenith] client on port") for l in r["l"]), f"cmd /f3d-status: its lines come back, not to RCON: {r}")
# With /f3d-profile on its lines carry profilers, which can't go into a JSON message: text only.
F.commands["f3d-profile"](lua.table_from({"name": "f3d-profile"}))
prof = lua.eval('package.loaded["scripts.profile"]')
for _ in range(600):
    prof.run("probe", lambda: None)
    prof.end_tick()
r = console("/f3d-status", 61)
check(r and all(isinstance(l, str) for l in r["l"]) and "print only in Factorio" in r["l"][-1],
      f"cmd /f3d-status with profiling on: text only, the profiler's times left to Factorio's console: {r and r['l'][-2:]}")
F.commands["f3d-profile"](lua.table_from({"name": "f3d-profile"}))
r = console("/no-such-command", 7)
check(r and r.get("ok") == 0 and r["l"] == [], f"cmd: an unknown command answers ok = 0: {r}")
r = console("/c game.print(1)", 8)
check(r and r.get("ok") == 0, "cmd: Lua is never run from a packet")
F.researched_all = False
r = console("/cheat", 9)
zenith = F.remote["zenith"]
owner = zenith.player() or g.package.loaded["scripts.puppet"].held_for()
check(F.researched_all and r and r["l"][0] == "Researched every technology"
      and (r["l"][1] == "Cheat mode on for " + owner.name if owner else "crafting still takes time" in r["l"][1]),
      f"cmd /cheat: research, and cheat mode for the character's player (none for the bridge's own): {r}")
r = console("/cheat all", 10)
check(r and r["l"][-1].startswith("Gave the character ") and not r["l"][-1].startswith("Gave the character 0 "), f"cmd /cheat all gives the kit: {r}")
r = console("/cheat nowhere", 11)
check(r and r["l"] == ["No planet or platform called nowhere"], f"cmd /cheat <unknown place>: {r}")
check(same(zenith.character(), g.storage.f3d.puppet) and zenith.name() == (owner.name if owner else None),
      "remote zenith: the client's character, and the name of its player")
# Inputs: what anything on localhost could send to Zenith's console.
before = len(g.game.forces.player.platforms)
r = console("/f3d-platform new", 12)
check(r and "not from Zenith's" in r["l"][-1] and len(g.game.forces.player.platforms) == before,
      f"inputs: /f3d-platform new from Zenith's console makes no platform: {r}")
F.server_saved = False
r = console("/server-save", 13)
first_save = F.server_saved
F.server_saved = False
r2 = console("/server-save", 14)
check(first_save and not F.server_saved and r2 and "once a minute" in r2["l"][-1],
      f"inputs: /server-save from the client saves at most once a minute: {r} {r2}")
r = console("/f3d-profile trace 99999999999", 15)
check(r and "for 36000 ticks" in r["l"][-1], f"inputs: a profile trace is ten minutes at most: {r}")
g.package.loaded["scripts.profile"].trace(0)
# Owner's rule: in a multiplayer game console commands are for admins. A packet that came in on a
# player's machine is that player's; the server's own machine (player_index 0) is the server's.
guest = F.make_offline_player(9, "guest", 0, 0)


def console_from(text, cid, who):
    F.packet(json.dumps({"t": "cmd", "id": cid, "text": text}), CLIENT_PORT, who)
    tick(1)
    replies = [m for m in of_type(take(), "cmdr") if m["id"] == cid]
    return replies[-1] if replies else None


ADMINS_ONLY = ["Console commands are for admins in a multiplayer game"]
r = console_from("/version", 16, 9)
r_cheat = console_from("/cheat all", 17, 9)
r_none = console_from("/version", 18, 42)
guest.admin = True
r_admin = console_from("/version", 19, 9)
guest.admin = False
check(r and r["l"] == ADMINS_ONLY and r_cheat and r_cheat["l"] == ADMINS_ONLY and r_none and r_none["l"] == ADMINS_ONLY,
      f"multiplayer: a player who isn't an admin (or no player) runs no console command from Zenith: {r} {r_cheat} {r_none}")
check(r_admin and r_admin["l"] == ["2.1.23"], f"multiplayer: an admin's command runs: {r_admin}")
check(r.get("na") == 1 and "na" not in r_admin, f"multiplayer: a refused command says so (na), for the debug menu's greyed controls: {r}")
r_debug = console_from("/f3d-debug speed 4", 21, 9)
check(r_debug and r_debug.get("na") == 1 and "dbg" not in r_debug and g.game.speed == 1,
      f"multiplayer: /f3d-debug from a player who isn't an admin changes nothing: {r_debug}")
# The debug menu's /f3d-debug: time of day, the cycle, speed, pause, teleport; every reply has the state.
r = console("/f3d-debug", 22)
check(r and r.get("dbg", {}).get("sp") == 1 and r["dbg"]["s"] == "nauvis" and "x" in r["dbg"] and "sx" in r["dbg"],
      f"/f3d-debug: the state comes back as dbg: {r}")
r = console("/f3d-debug daytime 1.25", 23)
check(abs(g.game.surfaces[1].daytime - 0.25) < 1e-9 and r["dbg"]["dt"] == 0.25, f"/f3d-debug daytime wraps into 0-1: {r}")
r = console("/f3d-debug freeze on", 24)
check(g.game.surfaces[1].freeze_daytime and r["dbg"]["fz"] == 1, f"/f3d-debug freeze on: {r}")
console("/f3d-debug freeze off", 25)
r = console("/f3d-debug speed 100", 26)
check(g.game.speed == 16 and r["dbg"]["sp"] == 16, f"/f3d-debug speed is held to 16x at most: {r}")
r = console("/f3d-debug speed nan", 27)
check(g.game.speed == 16 and "1 is normal" in r["l"][0], f"/f3d-debug speed: not a number changes nothing: {r}")
console("/f3d-debug speed 1", 28)
r = console("/f3d-debug pause on", 29)
check(g.game.tick_paused and r["dbg"]["pa"] == 1, f"/f3d-debug pause on: {r}")
console("/f3d-debug pause off", 30)
check(not g.game.tick_paused, "/f3d-debug pause off")
# A screenshot's hold: the slowest speed (the bridge still ticks), the speed before back on `hold off`,
# and by itself after 30 ticks if the client never says.
console("/f3d-debug speed 2", 33)
r = console("/f3d-debug hold on", 34)
check(g.game.speed == 0.01 and r["dbg"]["hd"] == 1 and r["dbg"]["sp"] == 0.01, f"/f3d-debug hold on: the slowest speed: {r}")
r = console("/f3d-debug hold on", 35)
check(g.game.speed == 0.01 and r["dbg"]["hd"] == 1, "a second hold on keeps the speed from before")
r = console("/f3d-debug hold off", 36)
check(g.game.speed == 2 and r["dbg"]["hd"] == 0, f"/f3d-debug hold off: the speed before is back: {r}")
console("/f3d-debug hold on", 37)
tick(31)
check(g.game.speed == 2 and not g.storage.f3d_hold, "a hold nobody lets go of ends by itself after 30 ticks")
console("/f3d-debug hold on", 38)
console("/f3d-debug speed 3", 39)
tick(1)
check(g.game.speed == 3 and not g.storage.f3d_hold, "a speed set during the hold is kept, and the hold ends")
g.game.tick_paused = True
r = console("/f3d-debug hold on", 40)
g.game.tick_paused = False
check(g.game.speed == 3 and not g.storage.f3d_hold and r["dbg"]["hd"] == 0, f"a paused game isn't held (it stays paused): {r}")
console("/f3d-debug speed 1", 41)
c = g.storage.f3d.puppet
home = (c.position.x, c.position.y)
r = console("/f3d-debug teleport 20 -5", 31)
check(abs(c.position.x - 20) < 1 and abs(c.position.y + 5) < 1 and r["dbg"]["x"] == round(c.position.x * 256),
      f"/f3d-debug teleport moves the character: {r} {c.position.x},{c.position.y}")
r = console("/f3d-debug teleport 1e99 0", 32)
check("tiles on the character's surface" in r["l"][0], f"/f3d-debug teleport refuses wild numbers: {r}")
c.teleport(lua.table_from({"x": home[0], "y": home[1]}))
check(console("/version", 20)["l"] == ["2.1.23"], "multiplayer: from the server's own machine the bridge's character's commands run")
# The mod's own commands typed into Factorio's console by a player who isn't an admin.
F.printed = lua.table_from([])
rate_before = g.storage.f3d.rate
F.commands["f3d-rate"](lua.table_from({"name": "f3d-rate", "player_index": 9, "parameter": "3"}))
said = list(F.printed.values())
check(any("/f3d-rate is for admins in a multiplayer game" in str(x) for x in said) and g.storage.f3d.rate == rate_before,
      f"multiplayer: the mod's own commands in Factorio's console are for admins: {said}")

# --- single-player (hybrid) mode -----------------------------------------------------------------
F.multiplayer = False
player = F.make_player(puppet)
player.set_quick_bar_slot(1, 3, "iron-plate")
send({"t": "hello", "v": 1, "sid": "sp", "w": 0})
tick(4)  # a new client starts with the default work budget
msgs = take()
check(of_type(msgs, "welcome"), "single-player handshake works (send_udp without for_player)")
check(g.storage.f3d.bud.limit == 300, "a new client doesn't keep the budget the last one set")
qb = of_type(msgs, "qb")
check(qb and qb[-1]["l"][2] == "iron-plate", "hybrid: the quickbar is the player's own")
send({"t": "qb_set", "i": 12, "item": "transport-belt"})
send({"t": "qb_page", "p": 3})
tick(1)
qb = of_type(take(), "qb")
check(F.quickbar[12] == "transport-belt" and player.get_active_quick_bar_page(1) == 3 and qb and qb[-1]["l"][11] == "transport-belt"
      and qb[-1]["p"] == 3, "hybrid: qb_set and qb_page change the player's quickbar")
send({"t": "qb_set", "i": 12, "item": ""})
tick(1)
check(F.quickbar[12] is None, "hybrid: and qb_set \"\" clears a slot")
player.set_quick_bar_slot(1, 5, "wood")
tick(31)
qb = of_type(take(), "qb")
check(qb and qb[-1]["l"][4] == "wood", "hybrid: a change made in the Factorio window is sent")
F.chart_requests = lua.table_from([])
tick(121)
take()
check(len(F.chart_requests) == 0, "hybrid: the bridge doesn't chart (the player does)")
F.charted["0,0"] = True
chest = spawn("wooden-chest", puppet.position.x + 2, puppet.position.y + 1, force="player")
check(same(F.remote["zenith"].player(), player) and F.remote["zenith"].name() == player.name,
      "hybrid: remote zenith's player is the player (game.player in the client's Lua commands)")
send({"t": "cmd", "id": 20, "text": "/cheat"})
tick(1)
take()
check(F.cheat_mode is True, "hybrid: /cheat turns the player's cheat mode on")
send({"t": "cmd", "id": 21, "text": "/cheat off"})
tick(1)
take()
check(F.cheat_mode is False, "hybrid: /cheat off turns it off")
lines = selftest(player_index=1)
check(lines and all(l.startswith("PLAYER ") for l in lines) and any("PASS the player's quickbar can be read and written" in l for l in lines)
      and any("PASS character.player is the player playing it" in l for l in lines) and not any("FAIL" in l for l in lines),
      f"/f3d-selftest in single-player, answered in the game's console: {lines}")
check(F.quickbar[100] is None, "the self-test puts the quickbar slot it borrowed back")
chest.destroy()

# Mods' windows (mod_gui.lua): a mod's window on the real player's screen is sent as a tree, again
# when it changes, and its id leaves the list when the mod closes it.
take()
window = F.player_gui.screen.add(lua.table_from({"type": "frame", "name": "informatron_main", "caption": lua.table_from(["informatron.title"]),
                                                 "direction": "vertical", "location": lua.table_from({"x": 120, "y": 80})}))
window.add(lua.table_from({"type": "label", "name": "text_1", "caption": "Hello from a mod"}))
grid = window.add(lua.table_from({"type": "table", "name": "grid", "column_count": 2}))
grid.add(lua.table_from({"type": "sprite-button", "name": "b1", "sprite": "item/iron-plate", "number": 12}))
F.player_gui.top.add(lua.table_from({"type": "sprite-button", "name": "informatron_button", "sprite": "informatron"}))
tick(31)
mg = of_type(take(), "mgui")
by_root = {m["l"][0]["r"]: m["l"][0] for m in mg if m["l"]}
win = by_root.get("screen", {})
check(win.get("i") == window.index and win.get("at") == [120, 80] and "mod" not in win
      and win["e"]["t"] == "frame" and win["e"]["c"] == ["informatron.title"] and win["e"]["d"] == "vertical"
      and win["e"]["a"][0]["c"] == "Hello from a mod" and win["e"]["a"][1]["cc"] == 2
      and win["e"]["a"][1]["a"][0]["sp"] == "item/iron-plate" and win["e"]["a"][1]["a"][0]["nu"] == 12
      and by_root.get("top", {}).get("e", {}).get("sp") == "informatron" and sorted(mg[-1]["ids"]) == sorted([window.index, by_root["top"]["i"]]),
      f"mgui: a mod's window and top button are sent as trees, with where they are: {mg}")
window.children[1].caption = "Changed"
tick(30)
mg = of_type(take(), "mgui")
check(len(mg) == 1 and mg[0]["l"][0]["i"] == window.index and mg[0]["l"][0]["e"]["a"][0]["c"] == "Changed",
      f"mgui: only the window that changed is sent again: {mg}")
tick(30)
check(not of_type(take(), "mgui"), "mgui: nothing is sent while nothing changes")
window.destroy()
tick(30)
mg = of_type(take(), "mgui")
check(mg and mg[-1]["ids"] == [by_root["top"]["i"]] and mg[-1]["l"] == [], f"mgui: a closed window leaves the list: {mg}")
# A client not drawing mods' windows (hello mg 0) costs no server time: they aren't read or sent.
# One that doesn't say gets them, as older clients always did.
lua.execute("""
function F_watch_top()
  local real = F.player_gui.top
  F_top_reads = 0
  F.player_gui.top = setmetatable({}, { __index = function(_, k) F_top_reads = F_top_reads + 1; return real[k] end })
  return function() F.player_gui.top = real end
end
""")
unwatch = g.F_watch_top()
send({"t": "hello", "v": 1, "sid": "sp", "w": 1, "mg": 0})
tick(31)
off = of_type(take(), "mgui")
check(off and off[-1]["ids"] == [] and off[-1]["l"] == [] and g.F_top_reads == 0,
      f"mgui: a client saying mg 0 is told its windows are gone, and they aren't read: {off} ({g.F_top_reads} reads)")
tick(61)
check(not of_type(take(), "mgui") and g.F_top_reads == 0, f"mgui: and then nothing is read or sent ({g.F_top_reads} reads)")
unwatch()
send({"t": "hello", "v": 1, "sid": "sp", "w": 1, "mg": 1})
tick(31)
check([m for m in of_type(take(), "mgui") if m["l"] and m["l"][0]["i"] == by_root["top"]["i"]], "mgui: turned on (mg 1), the windows are sent again")
send({"t": "hello", "v": 1, "sid": "sp", "w": 1, "mg": 0})
tick(31)
take()
send({"t": "hello", "v": 1, "sid": "sp", "w": 1})
tick(31)
check([m for m in of_type(take(), "mgui") if m["l"] and m["l"][0]["i"] == by_root["top"]["i"]], "mgui: a hello without mg gets them, as before")

# Informatron's buttons (mod_gui.lua PRESSERS): the bridge presses them through Informatron's remote
# interface (owner: clicking its window from Zenith missed nearly every time), and its page text wraps
# where Factorio wraps it.
opened_pages = []
def open_page(d):
    opened_pages.append((d["player_index"], d["interface"], d["page_name"]))
    para.caption = "Page " + d["page_name"]


F.remote["informatron"] = lua.table_from({"informatron_open_to_page": open_page})
info = F.player_gui.screen.add(lua.table_from({"type": "frame", "name": "informatron", "direction": "vertical"}))
info.get_mod = lambda *a: "informatron"
menu_b = info.add(lua.table_from({"type": "button", "name": "menu-informatron", "caption": "Informatron",
                                  "tags": lua.table_from({"root": "informatron", "interface": "informatron", "page_name": "informatron"})}))
menu_b.get_mod = lambda *a: "informatron"
close_b = info.add(lua.table_from({"type": "sprite-button", "name": "close", "sprite": "utility/close",
                                   "tags": lua.table_from({"root": "informatron", "action": "close-gui"})}))
close_b.get_mod = lambda *a: "informatron"
other_b = info.add(lua.table_from({"type": "button", "name": "other", "caption": "Not Informatron's"}))
slide = info.add(lua.table_from({"type": "slider", "name": "slide", "slider_value": 3}))
slide.get_slider_minimum = lambda *a: 1
slide.get_slider_maximum = lambda *a: 10
slide.get_slider_value_step = lambda *a: 1
field = info.add(lua.table_from({"type": "textfield", "name": "field", "text": "ab"}))
box = info.add(lua.table_from({"type": "checkbox", "name": "box", "state": False, "caption": "Tick"}))
radio = info.add(lua.table_from({"type": "radiobutton", "name": "radio", "state": False}))
drop = info.add(lua.table_from({"type": "drop-down", "name": "drop", "items": lua.table_from(["a", "b", "c"]), "selected_index": 1}))
sw = info.add(lua.table_from({"type": "switch", "name": "sw", "switch_state": "left", "allow_none_state": False}))
pick = info.add(lua.table_from({"type": "choose-elem-button", "name": "pick", "elem_type": "signal", "elem_value": lua.table_from({"type": "virtual", "name": "signal-A"})}))
para = info.add(lua.table_from({"type": "label", "name": "para", "caption": "A long paragraph"}))
para.style.single_line = False
para.style.maximal_width = 888
info.style.minimal_height = 800
info.style.maximal_height = 800
menu_b.style.horizontally_stretchable = True
g.game.get_player(1).opened = info
tick(31)
mg = [m for m in of_type(take(), "mgui") if m["l"] and m["l"][0]["i"] == info.index]
kids = {k["n"]: k for k in mg[-1]["l"][0]["e"]["a"]} if mg else {}
check(kids.get("menu-informatron", {}).get("ck") is True and kids.get("close", {}).get("ck") is True and "ck" not in kids.get("other", {})
      and kids["menu-informatron"].get("ix") == menu_b.index,
      f"mgui: Informatron's tagged buttons are marked ck with their index, another mod's button isn't: {kids}")
check(kids.get("slide", {}).get("v") == 3 and kids["slide"].get("mn") == 1 and kids["slide"].get("mx") == 10,
      f"mgui: a slider carries its value and range: {kids.get('slide')}")
check(kids.get("para", {}).get("ml") is True and kids["para"].get("mw") == 888, f"mgui: a label Factorio wraps carries ml and mw: {kids.get('para')}")
check(mg[-1]["l"][0]["e"].get("sz") == [0, 0, 800, 800] and kids["menu-informatron"].get("hs") is True and "sz" not in kids.get("other", {}),
      f"mgui: style sizes (sz) and stretching (hs) as Factorio lays the window out: {mg[-1]['l'][0]['e'].get('sz')}")
# What the player does to a mod's textfield, checkbox, drop-down or slider in Zenith (`mset`): set on the
# element, as a click would, and raised as the bridge's own events (a script can't raise Factorio's) with
# Factorio's field names, for a mod that listens (remote zenith gui_events).
lua.execute("""GUIEV = {}
for name, id in pairs(remote.call("zenith", "gui_events")) do
  F.companion_on(id, function(e) GUIEV[#GUIEV + 1] = { name = name, element = e.element, player_index = e.player_index, text = e.text, state = e.state, selected_index = e.selected_index, value = e.value, switch_state = e.switch_state, element_value = e.element_value } end)
end""")
guiev = lambda: [dict(e) for e in lua.eval("GUIEV").values()]
ev_names = sorted(dict(F.remote["zenith"].gui_events()).keys())
check(ev_names == ["on_gui_checked_state_changed", "on_gui_elem_changed", "on_gui_selection_state_changed", "on_gui_switch_state_changed", "on_gui_text_changed", "on_gui_value_changed"],
      f"mset: the zenith interface names the events: {ev_names}")
send({"t": "mset", "ix": field.index, "v": "abc"})
tick(1)
ev = guiev()
check(field.text == "abc" and len(ev) == 1 and ev[0]["name"] == "on_gui_text_changed" and ev[0]["text"] == "abc"
      and ev[0]["player_index"] == 1 and ev[0]["element"].index == field.index,
      f"mset: typing in a textfield sets its text and raises on_gui_text_changed (element, player_index, text): {field.text} {ev}")
check(any(m["l"] and m["l"][0]["i"] == info.index for m in of_type(take(), "mgui")), "mset: the window is read again at once, so the client sees the mod's value")
send({"t": "mset", "ix": box.index, "v": True})
send({"t": "mset", "ix": radio.index, "v": True})
send({"t": "mset", "ix": radio.index, "v": False})  # a click never switches a radio button off
tick(1)
ev = guiev()[1:]
check(box.state is True and radio.state is True and [e["name"] for e in ev] == ["on_gui_checked_state_changed"] * 2
      and ev[0]["state"] is True and ev[0]["element"].index == box.index and ev[1]["element"].index == radio.index,
      f"mset: a checkbox and a radio button are checked (on_gui_checked_state_changed with state), a radio never unchecked: {box.state} {radio.state} {ev}")
send({"t": "mset", "ix": box.index, "v": False})
send({"t": "mset", "ix": drop.index, "v": 3})
send({"t": "mset", "ix": drop.index, "v": 4})  # past the items
send({"t": "mset", "ix": drop.index, "v": 0})
send({"t": "mset", "ix": slide.index, "v": 7.4})
send({"t": "mset", "ix": slide.index, "v": 99})  # past the maximum: clamped
tick(1)
ev = guiev()[3:]
check(box.state is False and drop.selected_index == 3 and slide.slider_value == 10
      and [e["name"] for e in ev] == ["on_gui_checked_state_changed", "on_gui_selection_state_changed", "on_gui_value_changed", "on_gui_value_changed"]
      and ev[1]["selected_index"] == 3 and ev[2]["value"] == 7 and ev[3]["value"] == 10,
      f"mset: a drop-down's index within its items (else refused), a slider's value at its step and within its range: {drop.selected_index} {slide.slider_value} {ev}")
send({"t": "mset", "ix": sw.index, "v": "right"})
send({"t": "mset", "ix": sw.index, "v": "none"})  # not allowed without allow_none_state
send({"t": "mset", "ix": sw.index, "v": "middle"})
tick(1)
ev = guiev()[7:]
check(sw.switch_state == "right" and len(ev) == 1 and ev[0]["name"] == "on_gui_switch_state_changed" and ev[0]["switch_state"] == "right",
      f"mset: a switch goes to left or right (none only with allow_none_state), raising on_gui_switch_state_changed: {sw.switch_state} {ev}")
mg = [m for m in of_type(take(), "mgui") if m["l"] and m["l"][0]["i"] == info.index]
pk = {k["n"]: k for k in mg[-1]["l"][0]["e"]["a"]}["pick"] if mg else {}
check(pk.get("ev") == "signal-A" and pk.get("evt") == "virtual" and pk.get("et") == "signal", f"mgui: a choose-elem-button's signal keeps its type: {pk}")
send({"t": "mset", "ix": pick.index, "v": {"type": "item", "name": "iron-plate"}})
send({"t": "mset", "ix": pick.index, "v": 12})  # not a value
tick(1)
ev = guiev()[8:]
check(len(ev) == 1 and ev[0]["name"] == "on_gui_elem_changed" and ev[0]["element_value"]["name"] == "iron-plate" and ev[0]["element_value"]["type"] == "item"
      and pick.elem_value["name"] == "iron-plate", f"mset: a choose-elem-button's picked signal is set, with on_gui_elem_changed (element_value): {ev}")
send({"t": "mset", "ix": pick.index, "v": False})
tick(1)
ev = guiev()[9:]
check(len(ev) == 1 and ev[0].get("element_value") is None and pick.elem_value is None, f"mset: right click clears it: {ev}")
n_ev = len(guiev())
send({"t": "mset", "ix": field.index, "v": 5})  # the wrong kind of value
send({"t": "mset", "ix": para.index, "v": "x"})  # a label can't be set
send({"t": "mset", "ix": 987654, "v": "x"})  # no such element
field.enabled = False
send({"t": "mset", "ix": field.index, "v": "nope"})
field.enabled = True
tick(1)
check(len(guiev()) == n_ev and field.text == "abc", f"mset: wrong values, other elements, unknown or disabled ones change and raise nothing: {len(guiev())} {field.text}")
send({"t": "mpress", "ix": menu_b.index})
tick(1)
check(opened_pages == [(1, "informatron", "informatron")], f"mpress on a menu button opens its page through Informatron's interface: {opened_pages}")
check(any(m["l"] and m["l"][0]["i"] == info.index for m in of_type(take(), "mgui")), "mpress: the windows are read again on the next tick")
send({"t": "mpress", "ix": other_b.index})
tick(1)
check(len(opened_pages) == 1, "mpress on a button no presser knows does nothing")
send({"t": "mpress", "ix": close_b.index})
tick(1)
check(g.game.get_player(1).opened is None, "mpress on Informatron's close button clears player.opened (Informatron closes on on_gui_closed)")
take()
wm = F.player_gui.screen.add(lua.table_from({"type": "frame", "name": "se_watermark_string_frame", "ignored_by_interaction": True}))
wm.add(lua.table_from({"type": "label", "name": "se_watermark_string_label", "caption": "SE 0.7.64 T602"}))
tick(31)
wmsg = [m for m in of_type(take(), "mgui") if m["l"] and m["l"][0]["i"] == wm.index]
check(wmsg and wmsg[-1]["l"][0]["e"].get("ig") is True, f"mgui: a frame clicks go through (Space Exploration's watermark) carries ig: {wmsg[-1:]}")
wm.destroy()
g.game.get_player(1).opened = None
info.destroy()
del F.remote["informatron"]
tick(31)
take()

# --- acting as the player (as_player.lua): other mods get the player events -----------------------
px, py = math.floor(puppet.position.x) + 4, math.floor(puppet.position.y) - 3


def belts_at(x, y):
    return list(puppet.surface.find_entities_filtered(lua.table_from({"name": "transport-belt", "position": lua.table_from({"x": x, "y": y})})).values())


puppet.insert(lua.table_from({"name": "transport-belt", "count": 3}))
F.player_events = lua.table_from([])
send({"t": "build", "item": "transport-belt", "x": fixed(px + 0.5), "y": fixed(py + 0.5), "d": 4})
tick(2)
take()
built = belts_at(px + 0.5, py + 0.5)
check("on_built_entity" in list(F.player_events.values()) and len(built) == 1,
      f"as player: a build goes through the player's cursor and raises on_built_entity: {list(F.player_events.values())}")
check(not player.cursor_stack.valid_for_read and puppet.get_main_inventory().get_item_count("transport-belt") >= 2,
      "as player: the cursor is empty again and the rest is back in the inventory")
# Flipped (m = 1): checked without `mirror`, which can_build_from_cursor doesn't take (the fake throws
# on it, and the old code took that error message for a yes), built with it.
def free_at(x, y):
    return not list(puppet.surface.find_entities_filtered(lua.table_from({"position": lua.table_from({"x": x, "y": y})})).values())


fx_, fy_ = next((px + 0.5 + dx, py + 0.5 + dy) for dy in (-1, -2, 1, 2) for dx in (0, -1, -2) if free_at(px + 0.5 + dx, py + 0.5 + dy))
F.player_events = lua.table_from([])
send({"t": "build", "item": "transport-belt", "x": fixed(fx_), "y": fixed(fy_), "d": 4, "m": 1})
tick(2)
take()
check("on_built_entity" in list(F.player_events.values()) and len(belts_at(fx_, fy_)) == 1
      and not player.cursor_stack.valid_for_read,
      f"as player: a flipped build is checked and built through the cursor: {list(F.player_events.values())}")
belt = built[0] if built else None
if belt:
    send({"t": "rotate", "u": belt.unit_number, "p": eid["transport-belt"], "x": fixed(belt.position.x), "y": fixed(belt.position.y)})
    tick(2)
    take()
    check("on_player_rotated_entity" in list(F.player_events.values()) and belt.direction == 8,
          "as player: rotating raises on_player_rotated_entity")
box = spawn("wooden-chest", px + 2, py, force="player")
send(open_cmd(box))
tick(2)
take()
check(same(player.opened, box) and "on_gui_opened" in list(F.player_events.values()),
      "as player: opening a machine sets the player's opened (on_gui_opened)")
send({"t": "close"})
tick(2)
take()
check(player.opened is None and "on_gui_closed" in list(F.player_events.values()), "as player: closing it closes the player's (on_gui_closed)")
if belt:
    for _ in range(6):
        send({"t": "mine", "u": belt.unit_number, "p": eid["transport-belt"], "x": fixed(belt.position.x), "y": fixed(belt.position.y)})
        tick(10)
    take()
    check("on_player_mined_entity" in list(F.player_events.values()) and not belt.valid,
          "as player: mining goes through the player (on_player_mined_entity)")
    send({"t": "mine_stop"})
box.destroy()
g.settings["global"]["f3d-act-as-player"]["value"] = False
F.player_events = lua.table_from([])
send({"t": "build", "item": "transport-belt", "x": fixed(px + 0.5), "y": fixed(py + 2.5), "d": 4})
tick(2)
take()
check(len(belts_at(px + 0.5, py + 2.5)) == 1 and len(F.player_events) == 0,
      "f3d-act-as-player off: the bridge builds by script again, no player events")
g.settings["global"]["f3d-act-as-player"]["value"] = True

check(radar_list[far_radar_unit] is None, "a gone radar leaves storage on M.tick's prune tick")

# A linked belt bends the belt beside it like any belt: building one sends that belt's record again.
bent = belts_at(px + 0.5, py + 2.5)[0]
send({"t": "sub", "c": [[math.floor(bent.position.x / 32), math.floor(bent.position.y / 32)]]})
tick(10)
take()
linked = spawn("linked-belt", px + 1.5, py + 2.5, force="player", linked_belt_type="output")
F["raise"]("script_raised_built", lua.table_from({"entity": linked}))
tick(1)
check(any(m["e"][0] == bent.unit_number for m in of_type(take(), "upd")),
      "a linked belt built beside a belt updates that belt (its shape may bend)")

# --- inputs: numbers and sizes from a packet -------------------------------------------------------
# tonumber("1e999") is inf, so a packet can carry one as a string; the tick isn't under pcall.
send({"t": "hello", "v": 1, "sid": "sp", "w": 1})
c = g.storage.f3d.puppet
for d in ("1e999", 1e300):
    send({"t": "walk", "d": d})
    try:
        tick(2)
        walked = True
    except Exception as err:  # the game would stop: the error is in on_tick
        walked = False
        print("walk tick error:", str(err).splitlines()[0])
    check(walked and not c.walking_state.walking,
          f"inputs: walk with d {d} stops instead of writing a NaN or huge direction in the tick")
send({"t": "walk", "d": -1})
old_focus = {"x": int(g.storage.f3d.focus.x * 256), "y": int(g.storage.f3d.focus.y * 256), "r": int(g.storage.f3d.focus.r)}
send({"t": "focus", "x": "1e999", "y": -1e300, "r": 32})
f = g.storage.f3d.focus
check(abs(f.x) <= 1000000 and abs(f.y) <= 1000000 and f.x == f.x,
      f"inputs: a focus far off the map is clamped to its edge: {f.x}, {f.y}")
send({"t": "focus", **old_focus})
send({"t": "shoot", "m": 1, "x": "1e999", "y": 0})
try:
    tick(2)
    shot = True
except Exception as err:
    shot = False
    print("shoot tick error:", err)
sh = g.storage.f3d.shooting
check(shot and sh and abs(sh.x) <= 1000000, f"inputs: an aim point off the map is clamped before the tick shoots at it")
send({"t": "shoot", "m": -1})
tick(1)
old_subs = [[int(v) for v in k.split(",")] for k in g.storage.f3d.subs.keys()]
send({"t": "sub", "c": [[1e300, 0], ["1e999", 1], [0, 2e9], [0, 0]], "h": [[1, 1e300, 0, 1, 1]]})
keys = list(g.storage.f3d.subs.keys())
check(keys == ["0,0"], f"inputs: chunks off the map aren't subscribed (the tick would read them): {keys}")
send({"t": "resync", "c": [[1e300, 0]]})
try:
    tick(3)
    subbed = True
except Exception as err:
    subbed = False
    print("sub tick error:", err)
check(subbed, "inputs: and the tick goes on")
send({"t": "sub", "c": old_subs})
take()
# Planners and copy over the whole map are refused: they read every entity in the area in one tick.
big = {"i": 0, "x1": -10 ** 9, "y1": -10 ** 9, "x2": 10 ** 9, "y2": 10 ** 9}
send({"t": "decon", **big})
send({"t": "copy", **big})
tick(1)
said = texts(take())
check(said.count("That area is too big (at most 2048 by 2048 tiles)") == 2,
      f"inputs: decon and copy over the whole map are refused: {said}")
# A long thin drag (a rail line, panning the remote view) is far longer than 2048 a side but small.
send({"t": "decon", "i": 0, "x1": 0, "y1": 0, "x2": 20000 * 256, "y2": 8 * 256})
tick(1)
said = texts(take())
check(not any("too big" in s for s in said), f"inputs: a long thin planner drag goes through: {said}")
# A blueprint string's parts are the client's 8000 characters at most: an upload can't hold 4096
# whole datagrams in storage.
send({"t": "bp_set", "q": 1, "i": 0, "id": 7, "part": 1, "parts": 4096, "d": "x" * 9000})
check(g.storage.f3d.bp_up is None, "inputs: a bp_set part longer than 8192 characters isn't kept")
send({"t": "bp_set", "q": 1, "i": 0, "id": 7, "part": 1, "parts": 2, "d": "x" * 8000})
check(g.storage.f3d.bp_up is not None and g.storage.f3d.bp_up.got == 1, "inputs: one of 8000 is")
g.storage.f3d.bp_up = None
# Clients that come and go with a new session id each time don't park a character each, forever.
F.multiplayer = True
send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
tick(1)
units = set()
for i in range(40):
    send({"t": "hello", "v": 1, "sid": f"churn{i}", "w": 0}, port=PORT_B)
    tick(1)
    st = g.storage.f3d_extra[PORT_B]
    if st and st.puppet:
        units.add(st.puppet.unit_number)
    send({"t": "bye"}, port=PORT_B)
    tick(1)
sync_r(take_by_port())
parked = len(list(g.storage.f3d_parked.keys()))
check(parked <= 16 and len(units) <= 17,
      f"inputs: 40 clients coming and going park 16 characters at most ({parked}) and make {len(units)}, not 40")

# --- tick-cost audit: storage that grew without bound -------------------------------------------
send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
tick(2)
take()
s = g.storage.f3d
B.set(lua.table_from({"u": 300}))
fxa, fya = s.focus.x, s.focus.y
# A creature hurt near the focus and never killed there (it walked off, a script removed it) kept
# its hit cue in storage: cues older than their interval go.
hurt_biter = spawn("small-biter", fxa + 3, fya + 3, force="enemy")
F["raise"]("on_entity_damaged", lua.table_from({"entity": hurt_biter, "force": g.game.forces.player, "final_damage_amount": 1}))
check(s.hit_fx_ticks[hurt_biter.unit_number] is not None, "a hit near the focus keeps its cue's tick")
hurt_biter.destroy()
tick(20)
check(s.hit_fx_ticks[hurt_biter.unit_number] is None, "hit cues older than their interval are forgotten (they only went on a death)")
# Turrets: a firing cue older than its interval goes, and a turret gone between a sweep and the
# next search (the search runs first in its tick) is no longer kept in turret_last until a handshake.
gone_turret = spawn("gun-turret", fxa + 5, fya + 5, force="player")
gone_turret.shooting_target = None
F["raise"]("on_entity_damaged", lua.table_from({"entity": hurt_biter.valid and hurt_biter or spawn("small-biter", fxa + 6, fya + 6, force="enemy"),
                                                "cause": gone_turret, "force": g.game.forces.player, "final_damage_amount": 1}))
check(s.turret_fire_ticks[gone_turret.unit_number] is not None, "a turret's hit keeps its firing cue's tick")
tick(1)
while g.game.tick % 60 != 0:  # past a search (tick % 60 == 0),
    tick(1)
while g.game.tick % 60 != 59:  # to the last sweep before the next
    tick(1)
check(s.turret_last[gone_turret.unit_number] is not None, "the turret is kept for the sweep's shot count")
gone_turret.destroy()
tick(8)
take()
check(s.turret_last[gone_turret.unit_number] is None, "a turret gone before the next search is dropped from turret_last")
check(s.turret_fire_ticks[gone_turret.unit_number] is None, "firing cues older than their interval are forgotten")
# With no client connected, a fluid entity removed (robots mining pipes on a server) was queued in
# storage until the next client's handshake.
send({"t": "bye"})
tick(1)
take()
far_pipe = spawn("pipe", fxa + 9.5, fya + 9.5, force="player")
for _ in range(5):
    F["raise"]("script_raised_destroy", lua.table_from({"entity": far_pipe}))
tick(1)
check(len(g.storage.f3d.pipe_refresh) == 0, f"no pipe refresh is queued without a client: {len(g.storage.f3d.pipe_refresh)}")
far_pipe.destroy()
send({"t": "hello", "v": 1, "sid": "s9", "w": 1})
tick(10)
take()
# Items on the ground, enemies and robots' cargo (rate.lua jobs with a slack) learn what they cost
# from what they read, as the other slack jobs do; they stayed at their first guess.
s = g.storage.f3d
B.set(lua.table_from({"u": 300}))
for i in range(30):
    spawn("small-biter", s.focus.x + 2 + i * 0.3, s.focus.y - 4, force="enemy")
tick(130)
take()
cost = to_py(g.storage.f3d.bud.cost)
check(cost.get("en", 10) != 10 and "en" in cost and "gi" in cost and "rc" in cost,
      f"en, gi and rc learn their cost from what they read: {cost}")

# --- jobs saved by an older bridge (last, so the ticks they take shift no section above) ---------
send({"t": "hello", "v": 1, "sid": "old-saves", "w": 1, "z": 1, "bl": 1})
tick(6)
take()
send({"t": "gfx", "fp": "00c0ffee12345678"})
tick(2)
gfx_parts = sorted(m["part"] for m in of_type(take(), "gfx") if m.get("fp") == "00c0ffee12345678")
check(gfx_parts == [1, 2], f"gfx: the parts of the list asked for: {gfx_parts}")
# A queue saved with other mods than the game has now (its list's fingerprint changed) would send
# the new list's parts under the old fingerprint, which the client keeps: it is dropped.
lua.execute('storage.f3d.gfx = { fp = "0123456789abcdef", n = 2, l = { 1, 2 }, at = 1 }')
tick(2)
check(not of_type(take(), "gfx") and g.storage.f3d.gfx is None, "gfx: a queue for another list (mods changed since) is dropped")
# A bridge before 0.1.2 (0.1.1, the public release) saved its round of belt items without ring_keys
# or count. The save's client is served until it times out, and if that client says hello again
# (with `bl`) its lanes are kept at once: reading the old round mid-ring indexed nil every tick,
# which stops the game. It is started over.
focus = g.storage.f3d.focus
old_belt = spawn("transport-belt", math.floor(focus.x) + 3.5, math.floor(focus.y) + 2.5, force="player", direction=4)
F.put_on_belt(old_belt, 1, "iron-plate", 0.3, 9900)
g.OLD_BELT = old_belt
lua.execute("""
local f, now = storage.f3d.focus, game.tick
storage.f3d.bi = { m = 1, dues = 0, work = 0, last = now - 3, round = {
  start = now - 2, si = OLD_BELT.surface.index, fx = f.x, fy = f.y, r = 24, target = now + 3, band = 0,
  belts = { OLD_BELT }, rings = { 0 }, i = 1, ring = 0, ring_items = 0, items = 0, units = 0 } }
OLD_BELT = nil
""")
try:
    tick(24)
    old_ok = True
except Exception as err:  # in Factorio the mod's error stops the game, and again every tick
    old_ok = False
    print("old round:", err)
old_by_k, _ = bi_items(take())
old_items = {u for items in old_by_k.values() for u in items}
check(old_ok and 9900 in old_items, f"bi: a round saved by a bridge before 0.1.2 starts over, not an error every tick: {sorted(old_items)}")
old_belt.destroy()

# Back from another surface (Factorissimo's buildings) the client offers its whole view: answers
# that need no reading (same, none) don't wait for f3d-chunks-per-tick, only a chunk to read does.
send({"t": "sub", "c": [[30, 30]]})
tick(4)
take()
send({"t": "sub", "c": [[0, 0]]})
tick(10)
kept = [m for m in of_type(take(), "chunk") if (m["cx"], m["cy"]) == (0, 0)]
send({"t": "sub", "c": [[31, 30]]})
tick(4)
take()
check(kept and kept[0].get("rv") is not None, f"a chunk to keep: {kept}")
if kept:
    offer = [kept[0]["rs"], 0, 0, kept[0]["rv"], kept[0]["n"]]
    send({"t": "sub", "c": [[0, 0], [40, 40], [41, 40], [42, 40], [1, 0], [43, 40]], "h": [offer]})
    tick(4)  # one chunk read a tick (f3d-chunks-per-tick 1): six chunks one by one took 6 ticks or more
    quick = {(m["cx"], m["cy"]): m for m in of_type(take(), "chunk")}
    check(quick.get((0, 0), {}).get("same") is not None and all(quick.get((x, 40), {}).get("none") for x in (40, 41, 42, 43))
          and quick.get((1, 0), {}).get("tiles"),
          f"a kept chunk and ungenerated ones don't wait behind the one chunk read: {sorted(quick)}")

# A belt runs all the time: only one a network switches off stands still, and only one with a wire
# or a logistic condition is looked at (belt_switch.lua), `st` state 5, 0 running again.
send({"t": "hello", "v": 1, "sid": "old-saves", "w": 1, "z": 1, "bl": 1})
wired_belt = spawn("transport-belt", 14.5, 16.5, force="player")
plain_belt = spawn("transport-belt", 15.5, 16.5, force="player")
logistic_belt = spawn("transport-belt", 16.5, 16.5, force="player")
belt_const = spawn("constant-combinator", 14.5, 18.5, force="player")
wired_belt.get_wire_connector(ids.circuit_red, True).connect_to(belt_const.get_wire_connector(ids.circuit_red, True))
logistic_belt.get_or_create_control_behavior().connect_to_logistic_network = True
for e in (wired_belt, plain_belt, logistic_belt, belt_const):
    F["raise"]("script_raised_built", lua.table_from({"entity": e}))
tick(2)
take()
watched = g.storage.f3d.beltw
check(watched and watched[wired_belt.unit_number] and watched[logistic_belt.unit_number] and not watched[plain_belt.unit_number],
      "a belt with a wire or a logistic condition is watched, a plain one isn't")


def belt_rows(ticks=35):
    tick(ticks)
    send({"t": "hello", "v": 1, "sid": "old-saves", "w": 1, "z": 1, "bl": 1})
    rows = [v for m in of_type(take(), "st") for v in m["l"]]
    return dict(zip(rows[0::2], rows[1::2]))


quiet = belt_rows()
check(wired_belt.unit_number not in quiet and plain_belt.unit_number not in quiet, f"belts running say nothing: {quiet}")
wired_belt.status = g.defines.entity_status.disabled_by_control_behavior
logistic_belt.status = g.defines.entity_status.disabled_by_control_behavior
rows = belt_rows()
check(rows.get(wired_belt.unit_number) == 5 and rows.get(logistic_belt.unit_number) == 5 and plain_belt.unit_number not in rows,
      f"switched off: st 5 for the belts that went off: {rows}")
rows = belt_rows()
check(wired_belt.unit_number not in rows, f"and only once: {rows}")
retold = {}
for _ in range(20):
    retold.update(belt_rows())
check(retold.get(wired_belt.unit_number) == 5, f"told again now and then, for a client that forgot: {retold}")
wired_belt.status = g.defines.entity_status.working
rows = belt_rows()
check(rows.get(wired_belt.unit_number) == 0, f"running again: st 0: {rows}")
logistic_belt.get_control_behavior().connect_to_logistic_network = False
F["raise"]("script_raised_built", lua.table_from({"entity": logistic_belt}))
tick(1)
rows = belt_rows(1)
check(rows.get(logistic_belt.unit_number) == 0 and not g.storage.f3d.beltw[logistic_belt.unit_number],
      f"a belt off that nothing can switch off any more is told it runs, and forgotten: {rows}")
# A wire added with no event: the combinator's next look finds it, and the belt at its end is watched.
late_belt = spawn("transport-belt", 17.5, 16.5, force="player")
F["raise"]("script_raised_built", lua.table_from({"entity": late_belt}))
tick(2)
check(not g.storage.f3d.beltw[late_belt.unit_number], "a belt with no wire yet isn't watched")
late_belt.get_wire_connector(ids.circuit_red, True).connect_to(belt_const.get_wire_connector(ids.circuit_red, True))
send({"t": "hello", "v": 1, "sid": "old-saves", "w": 1, "z": 1, "bl": 1})
# (Within a round of the wire look's strips, 8 x 30 ticks: /f3d-perf wire_strips.)
for _ in range(300):
    tick(1)
    if g.storage.f3d.beltw[late_belt.unit_number]:
        break
check(g.storage.f3d.beltw[late_belt.unit_number], "a wire put on it later, with no event, is noticed from its combinator")
take()
late_belt.destroy()
wired_belt.destroy()
plain_belt.destroy()
logistic_belt.destroy()
belt_const.destroy()
send({"t": "hello", "v": 1, "sid": "old-saves", "w": 1, "z": 1, "bl": 1})
tick(70)
check(next(iter(g.storage.f3d.beltw.items()), None) is None, "a watched belt gone is forgotten after a round")
take()

# Where a silo's rocket is, for the doors and its rise (H16).
_pp = puppet.position
silo_p = spawn("rocket-silo", _pp.x + 14.5, _pp.y + 0.5, force="player")
_rss = g.defines.rocket_silo_status
_states = []
for _status in (_rss.doors_opening, _rss.rocket_rising, _rss.rocket_ready, _rss.doors_closing, _rss.building_rocket):
    silo_p.rocket_silo_status = _status
    tick(61)
    _sent = [m["l"] for m in of_type(take(), "st")]
    _states.append(next((l[i + 1] for l in _sent for i in range(0, len(l), 2) if l[i] == silo_p.unit_number), None))
check(_states == [2, 3, 4, 5, 1], f"a silo's st says where its rocket is: doors opening 2, rising 3, up 4, closing 5, building 1: {_states}")
silo_p.destroy()

# A save made with another version of the bridge keeps its clients and their half-done jobs, in that
# version's shape: on loading it they are dropped, so the next hello starts clean. What belongs to
# the game stays.
PORT_OLD = 34277
F.multiplayer = True
send({"t": "hello", "v": 1, "sid": "old-bridge", "w": 1, "z": 1, "bl": 1})
send({"t": "hello", "v": 1, "sid": "old-extra", "w": 0}, port=PORT_OLD)
tick(3)
F.take_sent()
st = g.storage.f3d
old_unit, extra_unit = st.puppet.unit_number, g.storage.f3d_extra[PORT_OLD].puppet.unit_number
st.techs_job = "half a job from an older bridge"
st.bi = lua.table_from({"round": {"si": 1}})
st.hs_stage = 2
st.quickbar = lua.table_from({"page": 3, "sel": 0, "items": {}})
F.on_config(lua.table_from({"mod_changes": {"another-mod": {"old_version": "1.0.0", "new_version": "1.1.0"}}}, recursive=True))
check(st.client is not None and st.techs_job is not None and g.storage.f3d_extra[PORT_OLD] is not None,
      "another mod's update leaves the bridge's clients and jobs alone")
F.on_config(lua.table_from({"mod_changes": {"factorio-3d-bridge": {"old_version": "0.1.3", "new_version": "0.1.3"}}}, recursive=True))
check(st.client is not None and st.techs_job is not None, "the same version of the bridge leaves them alone")
F.on_config(lua.table_from({"mod_changes": {"factorio-3d-bridge": {"old_version": "0.1.1", "new_version": "0.1.3"}}}, recursive=True))
check(st.client is None and st.techs_job is None and st.bi is None and st.hs_stage is None,
      f"a new version of the bridge drops the save's client and half-done jobs: {st.client} {st.techs_job} {st.bi} {st.hs_stage}")
check(st.puppet.unit_number == old_unit and st.quickbar.page == 3 and st.outbox is not None and st.subs is not None,
      "and keeps the character and the quickbar, with the tables every client needs")
check(len(g.storage.f3d_extra) == 0 and g.storage.f3d_parked["old-extra"].unit_number == extra_unit,
      f"other clients are dropped too, their characters waiting for them: {len(g.storage.f3d_extra)}")
tick(5)
check(not list(F.take_sent().values()), "nothing is sent until a client says hello")
send({"t": "hello", "v": 1, "sid": "old-bridge", "w": 1, "z": 1, "bl": 1})
tick(2)
fresh = take()
welcomes = of_type(fresh, "welcome")
check(welcomes and welcomes[0]["r"] == 1, f"the client's next hello gets a fresh handshake, numbered from 1: {welcomes}")
F.multiplayer = False

# The barrier round each step (barrier.lua): a step that fails stops only itself, says so in the log
# and /f3d-status, runs once a tick whether or not it is being profiled, and writes nothing of its
# own to storage.
lua.execute("""
function F_upvalue(fn, name, depth)
  depth = depth or 4
  for i = 1, 255 do
    local n, v = debug.getupvalue(fn, i)
    if not n then
      return nil
    end
    if n == name then
      return v
    end
    if type(v) == "function" and depth > 0 then
      local found = F_upvalue(v, name, depth - 1)
      if found ~= nil then
        return found
      end
    end
  end
end
function F_fail_step(name)
  for _, step in ipairs(F_upvalue(F.handlers[defines.events.on_tick], "STEPS")) do
    if step[1] == name then
      local before = step[2]
      F_step_calls = 0
      step[2] = function()
        F_step_calls = F_step_calls + 1
        storage.f3d.half_done = (storage.f3d.half_done or 0) + 1
        error("boom in the step")
      end
      return function() step[2] = before end
    end
  end
end
function F_fail_event(name)
  local wrapper = F.handlers[defines.events[name]]
  for i = 1, 255 do
    local n, v = debug.getupvalue(wrapper, i)
    if not n then
      return nil
    end
    if n == "handler" then
      debug.setupvalue(wrapper, i, function() error("boom in the event") end)
      return function() debug.setupvalue(wrapper, i, v) end
    end
  end
end
""")
barrier = lua.eval('package.loaded["scripts.barrier"]')
barrier.rethrow = False
send({"t": "hello", "v": 1, "sid": "old-bridge", "w": 1, "z": 1, "bl": 1})
tick(20)
take()
F.printed = lua.table()
st = g.storage.f3d
restore_step = g.F_fail_step("tracker")
send({"t": "hello", "v": 1, "sid": "old-bridge", "w": 1, "z": 1, "bl": 1})
tick(30)
msgs = take()
logs = [str(p) for p in F.printed.values()]
errors = [p for p in logs if "ERROR in step 'tracker'" in p]
check(g.F_step_calls == 30 and st.half_done == 30,
      f"a failing step runs once a tick, and what it wrote before failing stays: {g.F_step_calls} {st.half_done}")
check(g.storage.f3d.client.port == CLIENT_PORT and of_type(msgs, "me"), "the game goes on: the steps after it still run for the client")
check(len(errors) == 1 and "boom in the step" in errors[0] and "tick" in errors[0],
      f"a failing step is logged with its name and error, once for the first 600 ticks: {errors}")
check(any("Bridge error in tracker" in m.get("text", "") for m in of_type(msgs, "msg")), "and the client is told")
keys_before = (set(g.storage.keys()), set(st.keys()))
barrier.call("direct", lua.eval('function() error("boom") end'))
check((set(g.storage.keys()), set(st.keys())) == keys_before, "the barrier adds nothing to storage")
take()
F.printed = lua.table()
F.command(lua.table_from({"name": "f3d-status"}))
status = [str(p) for p in F.printed.values()]
check(any("ERROR: step 'tracker' failed 30 time(s)" in p and "boom in the step" in p for p in status),
      f"/f3d-status lists a failing step: {status[:3]}")
F.printed = lua.table()
for _ in range(11):
    send({"t": "hello", "v": 1, "sid": "old-bridge", "w": 1, "z": 1, "bl": 1})
    tick(60)
take()
errors = [str(p) for p in F.printed.values() if "ERROR in step 'tracker'" in str(p)]
check(len(errors) == 1 and "more times" in errors[0], f"it keeps being logged, at most every 600 ticks: {errors}")
# Under /f3d-profile and a trace at once: still once a tick.
g.F_step_calls = 0
profile_mod = lua.eval('package.loaded["scripts.profile"]')
F.commands["f3d-profile"](lua.table_from({"name": "f3d-profile"}))
profile_mod.trace(3)
send({"t": "hello", "v": 1, "sid": "old-bridge", "w": 1, "z": 1, "bl": 1})
tick(3)
profile_mod.trace(0)
F.commands["f3d-profile"](lua.table_from({"name": "f3d-profile"}))
check(g.F_step_calls == 3, f"profiling and tracing don't run a failing step twice: {g.F_step_calls} calls in 3 ticks")
restore_step()
st.half_done = None
# An event handler: the same wall, whichever client it is for.
restore_event = g.F_fail_event("on_built_entity")
F.printed = lua.table()
F["raise"]("on_built_entity", lua.table_from({}))
check(any("ERROR in step 'on_built_entity'" in str(p) and "boom in the event" in str(p) for p in F.printed.values()),
      f"a failing event handler is caught and logged by its event's name: {list(F.printed.values())}")
restore_event()
# live_check's barrier check forgets the steps it failed on purpose; the others stay listed.
barrier.forget("on_built_entity")
barrier.forget("never-failed")
F.printed = lua.table()
F.command(lua.table_from({"name": "f3d-status"}))
listed = set(re.findall(r"ERROR: step '([^']+)'", " ".join(str(p) for p in F.printed.values())))
check(listed == {"tracker", "direct"}, f"barrier.forget drops one step from /f3d-status and keeps the rest: {listed}")
barrier.rethrow = True
take()

# --- changes made without events -----------------------------------------------------------
# A script's create_entity without raise_built and destroy() without raise_destroy raise no event:
# the chunks near the client are counted in turn (world.lua count_check), and one whose count
# changed unseen is sent again (trees cleared by a script stayed drawn, filming the B-roll).
send({"t": "sub", "c": []})
tick(2)
send({"t": "sub", "c": [[0, 0], [1, 0]]})
tick(40)
take()
quiet = spawn("tree-01", 40.5, 9.5)
tick(16)
resent = [m for m in take() if m["t"] in ("chunk", "ents") and (m["cx"], m["cy"]) == (1, 0)]
check(any(m["t"] == "chunk" and m.get("tiles") for m in resent)
      and any(rec[1] == eid["tree-01"] and rec[2] == fixed(40.5) for m in resent if m["t"] == "ents" for rec in m["e"]),
      f"a tree made by a script without an event: its chunk is counted and sent again with it: {[m['t'] for m in resent]}")
quiet.destroy()
tick(16)
resent = [m for m in take() if m["t"] in ("chunk", "ents") and (m["cx"], m["cy"]) == (1, 0)]
check(any(m["t"] == "chunk" for m in resent)
      and not any(rec[1] == eid["tree-01"] for m in resent if m["t"] == "ents" for rec in m["e"]),
      f"and destroyed without raise_destroy: its chunk is sent again without it: {[m['t'] for m in resent]}")
# (world.lua's refresh sends one subscribed chunk every 300 ticks whatever its count: a window over one
# of its ticks may hold that chunk, whatever tick the tests before have left the game at.)
count_from = int(lua.eval("game.tick"))
tick(40)
refreshed = any(t % 300 == 0 for t in range(count_from + 1, count_from + 41))
held_chunks = [m for m in take() if m["t"] == "chunk"]
check(len(held_chunks) <= (1 if refreshed else 0), f"a chunk whose count holds isn't sent again: {len(held_chunks)} (a refresh tick in the window: {refreshed})")
built = spawn("tree-01", 41.5, 9.5)
F["raise"]("script_raised_built", lua.table_from({"entity": built}))


def refresh_in(ticks):
    """Runs `ticks` ticks; whether one of them was the 300-tick refresh, which sends a chunk whatever
    its count (these checks failed whenever a test before them moved the game's tick onto one)."""
    start = int(lua.eval("game.tick"))
    tick(ticks)
    return any(t % 300 == 0 for t in range(start + 1, start + ticks + 1))


refreshed = refresh_in(16)
after_event = take()
check(of_type(after_event, "add") and len(of_type(after_event, "chunk")) <= (1 if refreshed else 0),
      f"an entity made with an event is sent as `add`, and the count starts again from there (no resend; a refresh tick: {refreshed})")
F["raise"]("script_raised_destroy", lua.table_from({"entity": built}))
built.destroy()
refreshed = refresh_in(16)
after_event = take()
check(of_type(after_event, "del") and len(of_type(after_event, "chunk")) <= (1 if refreshed else 0),
      f"and removed with one, as `del`, no resend (a refresh tick: {refreshed})")

