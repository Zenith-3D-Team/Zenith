# Bridge test slice 03_research_circuits_map.py (lines 3605-5898 of original test_bridge.py)
# --- research ---------------------------------------------------------------------------------------
lua.eval("function() storage.f3d.techs_dirty = true end")()
tick(2)
techs = {r[0]: r for m in of_type(take(), "techs") for r in m["l"]}
check(set(techs) == {"automation", "logistics", "steel-processing"}, f"techs: every shown technology: {sorted(techs)}")
check(techs.get("logistics", [0] * 8)[2:8] == [["automation"], [["automation-science-pack", 1]], 10, 10, 0, ""]
      and techs["automation"][6] == 1 and techs["steel-processing"][6] == 2,
      f"techs: prerequisites, cost, time, state (locked/available/researched): {techs.get('logistics')}")
check(len(techs.get("automation", [])) == 15 and techs["automation"][8] == [["unlock-recipe", "iron-gear-wheel", 0]]
      and techs["automation"][9:] == [1, 1, [], 0, "", 1] and techs["logistics"][14] == 0,
      f"techs: effects, level, max level, trigger detail, saved progress, formula, essential: {techs.get('automation')}")
send({"t": "research", "name": "automation"})
send({"t": "research", "name": "logistics"})
send({"t": "research", "name": "secret"})
tick(2)
msgs = take()
rs = of_type(msgs, "rs")
check(rs and rs[-1]["cur"] == "automation" and rs[-1]["q"] == ["automation", "logistics"],
      f"research starts one and queues the next (the queue's first is the current research, as Factorio's): {rs[-1:]}")
check(any(m["text"] == "Can't research secret" for m in of_type(msgs, "msg")), "hidden technologies can't be researched")
g.game.forces.player.research_progress = 0.4
send({"t": "research_cancel", "name": "logistics"})
tick(2)
rs = of_type(take(), "rs")
check(rs and rs[-1]["q"] == ["automation"] and rs[-1]["pr"] == 400, f"research_cancel takes it off the queue: {rs[-1:]}")
send({"t": "research_cancel", "name": "automation"})
tick(4)
msgs = take()
rs = of_type(msgs, "rs")
check(rs and rs[-1]["cur"] == "", "and stops the current research")
saved = {r[0]: r[12] for m in of_type(msgs, "techs") for r in m["l"]}
check(saved.get("automation") == 400, f"a stopped research's saved progress goes to the client (techs again): {saved}")
g.game.forces.player.technologies.automation.researched = True
finished_at = g.game.tick
F["raise"]("on_research_finished", lua.table_from({"research": g.game.forces.player.technologies.automation}))
tick(1)
first = take()
tick(5)
msgs = first + take()
techs = {r[0]: r[6] for m in of_type(msgs, "techs") for r in m["l"]}
check(techs.get("automation") == 2 and techs.get("logistics") == 1, f"finished research resends the tree: {techs}")
# K23: `rdone` names what finished, once (reliable), the research after it right behind (`rs`).
done = of_type(msgs, "rdone")
check(len(done) == 1 and done[0]["l"] == [["automation", 0]] and "n" not in done[0] and done[0]["tick"] == finished_at,
      f"research completed: one rdone naming the technology (level 0: it has one), its tick: {done}")
check(of_type(first, "rdone") and of_type(first, "rs") and first.index(of_type(first, "rs")[0]) > first.index(done[0]),
      f"and the research status after it in the same tick: {[m['t'] for m in first]}")
check(not [m for m in of_type(msgs, "msg") if "automation" in m.get("text", "")], "no msg as well (the client says it)")
g.game.forces.player.technologies.automation.researched = False
# Several in one tick are one message (Factorio's chime plays once for them); an infinite technology
# names the level it finished (its `level` is the next one by then); another force's research isn't
# the character's; past 100, `n` counts the rest.
lua.execute("""
local f = game.forces.player
local proto = setmetatable({ level = 3, max_level = 4294967295, hidden = false }, { __index = function(_, k) error("LuaTechnologyPrototype doesn't contain key " .. tostring(k), 2) end })
local function tech(name, force, level, researched, p)
  return setmetatable({ name = name, force = force, level = level, researched = researched, prototype = p },
    { __index = function(_, k) error("LuaTechnology doesn't contain key " .. tostring(k), 2) end })
end
storage.k23 = {
  tech("mining-productivity-3", f, 8, false, proto),
  tech("logistics", f, 1, true, f.technologies.logistics.prototype),
  tech("automation", game.forces.enemy, 1, true, f.technologies.automation.prototype),
}
""")
take()
for t in lua.eval("storage.k23").values():
    F["raise"]("on_research_finished", lua.table_from({"research": t}))
tick(1)
done = of_type(take(), "rdone")
check(len(done) == 1 and done[0]["l"] == [["mining-productivity-3", 7], ["logistics", 0]],
      f"rdone: one message a tick, an infinite level by the one finished, not another force's: {done}")
for _ in range(105):
    F["raise"]("on_research_finished", lua.table_from({"research": g.storage.k23[2]}))
tick(1)
done = of_type(take(), "rdone")
check(len(done) == 1 and len(done[0]["l"]) == 100 and done[0].get("n") == 5, f"rdone: 100 named, n the rest: {[(len(m['l']), m.get('n')) for m in done]}")
g.storage.k23 = None
tick(4)
take()
# L12: a technology whose prerequisites aren't all researched is queued after the missing ones, in order, as
# Factorio's technology screen does: 2.1.24's add_research alone refuses it, and refuses trigger technologies and an
# eighth in the queue (measured in real headless 2.1.24; the fake does the same). The owner's case: Plastics being
# researched, Advanced circuits queued behind it.
lua.execute("""
local f = game.forces.player
local T = f.technologies
local function proto(trigger)
  return { hidden = false, essential = false, effects = {}, level = 1, max_level = 1, research_trigger = trigger }
end
local function add(name, pres, trigger)
  local p = {}
  for _, n in ipairs(pres) do p[n] = T[n] end
  T[name] = F.make_tech(name, p, { prototype = proto(trigger), force = f })
  prototypes.technology[name] = T[name].prototype
end
f.research_queue = {}
add("l12-plastics", { "logistics" })
add("l12-circuits", { "l12-plastics", "automation" })
add("l12-oil", {}, { type = "mine-entity", entity = "crude-oil" })
add("l12-gas", { "l12-oil" })
add("l12-d1", {}) add("l12-d2", { "l12-d1" }) add("l12-d3", { "l12-d2" }) add("l12-d4", { "l12-d3" })
""")
take()
send({"t": "research", "name": "l12-plastics"})
tick(2)
rs = of_type(take(), "rs")
check(rs and rs[-1]["cur"] == "automation" and rs[-1]["q"] == ["automation", "logistics", "l12-plastics"],
      f"research of a locked technology: its missing prerequisites queued first, in order, then it: {rs[-1:]}")
send({"t": "research", "name": "l12-circuits"})
tick(2)
rs = of_type(take(), "rs")
check(rs and rs[-1]["q"] == ["automation", "logistics", "l12-plastics", "l12-circuits"],
      f"one whose prerequisites are queued goes behind them (Advanced circuits behind Plastics): {rs[-1:]}")
send({"t": "research", "name": "l12-gas"})
tick(2)
msgs = take()
rs = of_type(msgs, "rs")
check(rs and rs[-1]["q"] == ["automation", "logistics", "l12-plastics", "l12-circuits"]
      and any(m["text"] == "Can't research l12-gas yet: l12-oil is unlocked by doing its task" for m in of_type(msgs, "msg")),
      f"a trigger technology on the way: nothing queued, and why: {rs[-1:]}, {[m['text'] for m in of_type(msgs, 'msg')]}")
send({"t": "research", "name": "l12-d4"})
tick(2)
msgs = take()
rs = of_type(msgs, "rs")
check(rs and rs[-1]["q"] == ["automation", "logistics", "l12-plastics", "l12-circuits"]
      and any(m["text"] == "Research queue full: l12-d4 needs 3 more queued first" for m in of_type(msgs, "msg")),
      f"a chain past the queue's 7: what was queued for it comes off again: {rs[-1:]}, {[m['text'] for m in of_type(msgs, 'msg')]}")
g.storage.f3d_perf = lua.table_from({"research_chain": False})
lua.execute("game.forces.player.research_queue = {}")
send({"t": "research", "name": "l12-plastics"})
tick(2)
msgs = take()
rs = of_type(msgs, "rs")
check(rs and rs[-1]["q"] == [] and any(m["text"] == "Can't research l12-plastics yet" for m in of_type(msgs, "msg")),
      f"/f3d-perf research_chain off: add_research alone, refused as before: {rs[-1:]}")
g.storage.f3d_perf = None
lua.execute("""
local f = game.forces.player
f.research_queue = {}
for _, n in ipairs({ "l12-plastics", "l12-circuits", "l12-oil", "l12-gas", "l12-d1", "l12-d2", "l12-d3", "l12-d4" }) do
  f.technologies[n] = nil
  prototypes.technology[n] = nil
end
storage.f3d.techs_dirty = true
""")
tick(4)
take()
# A technology unlocking thousands of recipes (Space Exploration's recycling, 3,253) made one record
# of 187 KB, past a datagram, and its whole message was lost: the record keeps what fits under 30 KB
# and says how many it left out, and every message stays under 40 KB, `parts` growing to count them.
lua.execute("""
local p = game.forces.player.technologies.logistics.prototype
local many = {}
for i = 1, 3500 do many[i] = { type = "unlock-recipe", recipe = "a-rather-long-modded-recycling-recipe-" .. i } end
rawset(p, "effects", many)
""")
g.storage.f3d.techs_dirty = True
tick(4)
msgs = of_type(take(), "techs")
sizes = [len(json.dumps(m)) for m in msgs]
recs = {r[0]: r for m in msgs for r in m["l"]}
big = recs.get("logistics")
check(msgs and max(sizes) < 45000 and all(m["part"] < m["parts"] for m in msgs[:-1]) and msgs[-1]["part"] == msgs[-1]["parts"]
      and [m["part"] for m in msgs] == list(range(1, len(msgs) + 1)),
      f"techs: every message under the limit, parts counted to the last: {[(m['part'], m['parts']) for m in msgs]} {sizes}")
check(big is not None and len(big) == 16 and len(big[8]) + big[15] == 3500 and len(json.dumps(big)) < 31000 and "automation" in recs,
      f"techs: a giant record keeps what fits and says how many effects it left out: {big and (len(big), len(big[8]), big[15:])}")
lua.execute('rawset(game.forces.player.technologies.logistics.prototype, "effects", {})')
g.storage.f3d.techs_dirty = True
tick(4)
take()
# A job saved by an older bridge mid-send (part/parts, no block) is started over, not an error.
lua.execute('storage.f3d.techs_job = { names = { "automation" }, part = 1, parts = 3 }')
tick(4)
msgs = of_type(take(), "techs")
check(msgs and msgs[-1]["part"] == msgs[-1]["parts"] and g.storage.f3d.techs_job is None,
      f"techs: an older bridge's job in a save sends the tree again: {[(m['part'], m['parts']) for m in msgs]}")

# --- fast-replace, rails, rolling stock, quality ----------------------------------------------------
send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
take()
inv = puppet.get_main_inventory()
belts = inv.get_item_count("transport-belt")
spot = {"x": new_belt[2], "y": new_belt[3]}  # the belt built and turned south above
send({"t": "build", "item": "transport-belt", "d": 4, **spot})
tick(2)
msgs = take()
upd = of_type(msgs, "upd")
check(upd and upd[-1]["e"][4] == 4 and not of_type(msgs, "add") and inv.get_item_count("transport-belt") == belts,
      f"building a belt over the same belt turns it, for free: {upd[-1:]}")
send({"t": "build", "item": "transport-belt", "d": 4, **spot})
tick(2)
msgs = take()
check(not (of_type(msgs, "upd") or of_type(msgs, "add") or of_type(msgs, "msg")), "and over itself facing the same way does nothing")
puppet.insert(lua.table_from({"name": "fast-transport-belt", "count": 2}))
send({"t": "build", "item": "fast-transport-belt", "d": 4, **spot})
tick(2)
msgs = take()
dels, adds = of_type(msgs, "del"), of_type(msgs, "add")
check(dels and dels[0]["u"] == new_belt[0] and adds and adds[0]["e"][1] == eid["fast-transport-belt"] and adds[0]["e"][2:5] == [spot["x"], spot["y"], 4],
      f"a faster belt fast-replaces it: del then add: {dels[:1]} {adds[:1]}")
check(inv.get_item_count("fast-transport-belt") == 1 and inv.get_item_count("transport-belt") == belts + 1,
      "the fast belt is used and the old belt comes back")
# J9: a splitter stands on the tile edge between the two belts it covers: it lands where the cursor
# snaps it (the nearest tile corner across, the tile along), replacing both, each sent gone and given back.
j9_belts = [spawn("transport-belt", 1.5, 7.5, force="player"), spawn("transport-belt", 2.5, 7.5, force="player")]
j9_units = sorted(b.unit_number for b in j9_belts)
belts = inv.get_item_count("transport-belt")
puppet.insert(lua.table_from({"name": "splitter", "count": 1}))
send({"t": "build", "item": "splitter", "x": fixed(1.9), "y": fixed(7.7), "d": 0})
tick(2)
msgs = take()
adds = [a["e"] for a in of_type(msgs, "add") if a["e"][1] == eid["splitter"]]
check(sorted(d["u"] for d in of_type(msgs, "del")) == j9_units and adds and adds[0][2:5] == [fixed(2), fixed(7.5), 0]
      and inv.get_item_count("transport-belt") == belts + 2,
      f"J9: a splitter over two belts replaces both where it was aimed: {adds[:1]}, dels {[d['u'] for d in of_type(msgs, 'del')]}")
# J9: at negative coordinates the same rule (floor): a point a hair left of the tile middle at -3.5 (the client
# sends it rounded down, -897) is the tile edge at -4; the middle itself (-896, what a client cutting towards zero
# sent for that point) is the edge at -3, one tile over.
puppet.insert(lua.table_from({"name": "splitter", "count": 2}))
j9_home = {"x": puppet.position.x, "y": puppet.position.y}
puppet.teleport(lua.table_from({"x": -3.5, "y": -20.5}))
for j9_x, j9_y in ((-897, fixed(-22.3)), (-896, fixed(-24.3))):
    send({"t": "build", "item": "splitter", "x": j9_x, "y": j9_y, "d": 0})
    tick(2)
take()
puppet.teleport(lua.table_from(j9_home))
# (Read from the game: the client doesn't watch that chunk, so no `add` comes.)
j9_at = sorted(([e.position.x, e.position.y] for e in F.surface.entities.values() if e.name == "splitter" and e.position.y < -20),
               key=lambda p: -p[1])
check(j9_at == [[-4, -22.5], [-3, -24.5]],
      f"J9: left of zero a splitter sent a hair under a tile's middle stands on the edge below it, the middle itself on the edge above: {j9_at}")
for e in list(F.surface.entities.values()):
    if e.name == "splitter":
        e.destroy()
take()

# M2: an underground pair the character builds over a run of belts mines the belts between (and their items)
# into the character, as Factorio's player build does ("Any belts in between the entrance and exit of the
# underground belt will be mined automatically"); pipes-to-ground over pipes the same. Only a plain run: every
# tile between a belt the pair's way, straight, fed by nothing from the side (a pipe with no connection off the
# line); anything else and none go. The ends' own belts and their items come back too.
m2_x0 = math.floor(puppet.position.x)
m2_y0 = math.floor(puppet.position.y) + 8


M2_TYPES = ("transport-belt", "underground-belt", "pipe", "pipe-to-ground")


def m2_clear():
    for e in list(F.surface.entities.values()):
        p = e.position
        if e.valid and e.type in M2_TYPES and m2_x0 - 1 <= p.x <= m2_x0 + 8 and m2_y0 - 2 <= p.y <= m2_y0 + 2:
            e.destroy()
    take()


def m2_row(dy, name="transport-belt", n=7, d=4, items=False):
    row = [spawn(name, m2_x0 + i + 0.5, m2_y0 + dy + 0.5, force="player", direction=d) for i in range(n)]
    if items:
        for i, b in enumerate(row):
            F.put_on_belt(b, 1, "iron-plate", 0.5, 9000 + 10 * dy + i)
    return row


def m2_pair(dy, item="underground-belt", d_in=4, d_out=4, at=(0, 5)):
    puppet.insert(lua.table_from({"name": item, "count": 2}))
    for x, d in zip(at, (d_in, d_out)):
        send({"t": "build", "item": item, "x": fixed(m2_x0 + x + 0.5), "y": fixed(m2_y0 + dy + 0.5), "d": d})
    tick(2)
    return take()


m2_clear()
row = m2_row(0, items=True)
beside = m2_row(1)  # the next line over, the same way: not the pair's
middle = {b.unit_number for b in row[1:5]}
ends = {row[0].unit_number, row[5].unit_number}
belts0, plates0 = inv.get_item_count("transport-belt"), inv.get_item_count("iron-plate")
msgs = m2_pair(0)
pair = [e for e in F.surface.entities.values() if e.valid and e.name == "underground-belt" and e.position.y == m2_y0 + 0.5]
mnd = {m["u"]: m for m in of_type(msgs, "mnd")}
check(len(pair) == 2 and all(not b.valid for b in row[1:6]) and row[6].valid and all(b.valid for b in beside),
      f"M2: an underground pair over a run mines the belts between, the line beside and the belt after it stay: "
      f"{[b.valid for b in row]} {[b.valid for b in beside]}")
check(set(mnd) == middle and all(m["g"] == 1 and ["transport-belt", 1] in m["l"] and ["iron-plate", 1] in m["l"]
                                 for m in mnd.values()),
      f"M2: each belt between is said at once (`mnd`), gone, its belt and its item to the character: {sorted(mnd)}")
check({d["u"] for d in of_type(msgs, "del")} >= middle | ends,
      f"M2: their `del`s, and the ends' replaced belts': {[d['u'] for d in of_type(msgs, 'del')]}")
check(inv.get_item_count("transport-belt") == belts0 + 6 and inv.get_item_count("iron-plate") == plates0 + 6
      and inv.get_item_count("underground-belt") == 0,
      f"M2: the four between and the two the ends replaced come back with their six plates: "
      f"belts +{inv.get_item_count('transport-belt') - belts0}, plates +{inv.get_item_count('iron-plate') - plates0}")
inv_k = [m["k"] for m in of_type(msgs, "inv")]
check(bool(inv_k), f"M2: the inventory is sent at once with them: {inv_k}")

# Not a plain run: nothing between goes (the ends are still built over their belts).
m2_cases = {}
m2_clear()
side = m2_row(0)
feeder = spawn("transport-belt", m2_x0 + 2.5, m2_y0 - 0.5, force="player", direction=8)
F.link_belts(feeder, side[2])
m2_pair(0)
m2_cases["a belt fed from the side"] = [b.valid for b in side[1:5]]
m2_clear()
back = m2_row(0)
back[3].direction = 12
m2_pair(0)
m2_cases["a belt the other way"] = [b.valid for i, b in enumerate(back[1:5]) if i != 2]
m2_clear()
gap = m2_row(0)
gap[2].destroy()
m2_pair(0)
m2_cases["a gap"] = [b.valid for b in (gap[1], gap[3], gap[4])]
m2_clear()
bent = m2_row(0)
F.entity_data(bent[2]).belt_shape = "left"
m2_pair(0)
m2_cases["a curve"] = [b.valid for b in bent[1:5]]
m2_clear()
west = m2_row(0, d=12)
m2_pair(0)  # the pair goes east under belts going west
m2_cases["belts going the other way"] = [b.valid for b in west[1:5]]
for name, kept in m2_cases.items():
    check(all(kept), f"M2: {name} between keeps the run: {kept}")

# Pipes-to-ground over pipes: the same, and a branch keeps them.
m2_clear()
pipes = m2_row(0, name="pipe")
pipes0 = inv.get_item_count("pipe")
msgs = m2_pair(0, item="pipe-to-ground", d_in=12, d_out=4)
ptg = [e for e in F.surface.entities.values() if e.valid and e.name == "pipe-to-ground"]
check(len(ptg) == 2 and all(not p.valid for p in pipes[:6]) and pipes[6].valid
      and inv.get_item_count("pipe") == pipes0 + 6 and inv.get_item_count("pipe-to-ground") == 0
      and {m["u"] for m in of_type(msgs, "mnd")} == {p.unit_number for p in pipes[1:5]},
      f"M2: a pipe-to-ground pair over pipes mines the pipes between: {[p.valid for p in pipes]}, "
      f"pipes +{inv.get_item_count('pipe') - pipes0}")
m2_clear()
pipes = m2_row(0, name="pipe")
spawn("pipe", m2_x0 + 3.5, m2_y0 - 0.5, force="player")
m2_pair(0, item="pipe-to-ground", d_in=12, d_out=4)
check(all(p.valid for p in pipes[1:5]), f"M2: a pipe with a branch between keeps the pipes: {[p.valid for p in pipes]}")

# A full inventory: mined anyway, the rest spilled at the character's feet, as Factorio's build spills it.
m2_clear()
row = m2_row(0, items=True)
spilled0 = len(F.spilled)
F.inventory_space = 3
m2_pair(0)
F.inventory_space = float("inf")
check(all(not b.valid for b in row[1:5]) and len(F.spilled) > spilled0,
      f"M2: a full inventory still mines the run, the rest spilled: {len(F.spilled) - spilled0} stacks")

# /f3d-perf under_clear off: as before (the run stays, an end's items deleted with its belt).
m2_clear()
row = m2_row(0, items=True)
g.storage.f3d_perf = lua.table_from({"under_clear": False})  # (set_perf, below)
plates0 = inv.get_item_count("iron-plate")
msgs = m2_pair(0)
g.storage.f3d_perf = None
check(all(b.valid for b in row[1:5]) and not of_type(msgs, "mnd") and inv.get_item_count("iron-plate") == plates0,
      f"M2: under_clear off: the belts between stay and no `mnd`, as before: {[b.valid for b in row]}")
m2_clear()

puppet.insert(lua.table_from({"name": "rail", "count": 3}))
send({"t": "build", "item": "rail", "x": int(4.2 * 256), "y": int(3.7 * 256), "d": 0})
tick(2)
adds = of_type(take(), "add")
check(adds and adds[0]["e"][1] == eid["straight-rail"] and adds[0]["e"][2:4] == [5 * 256, 3 * 256],
      f"rail (a 2.x rail planner) builds a straight rail on the two-tile grid: {adds[:1]}")
puppet.insert(lua.table_from({"name": "locomotive", "count": 2}))
send({"t": "build", "item": "locomotive", "x": int(5.4 * 256), "y": int(3.8 * 256), "d": 12})
send({"t": "build", "item": "locomotive", "x": int(-6 * 256), "y": int(-6 * 256), "d": 0})
tick(2)
msgs = take()
locos = [e for e in F.surface.entities.values() if e.name == "locomotive"]
check(len(locos) == 1 and (locos[0].position.x, locos[0].position.y, locos[0].direction) == (5, 3, 0),
      "rolling stock goes onto the nearest rail, along it")
check(any(m["text"] == "Rolling stock goes on rails" for m in of_type(msgs, "msg")), "and not where there is no rail")
# Issue #13: a rolling stock ghost is sent facing its way (its orientation: its direction reads
# north), and when it goes (robots build the train, which is a mover and never `add`ed) its del.
locos[0].destroy()
tick(2)
take()
send({"t": "build", "item": "locomotive", "x": int(5.4 * 256), "y": int(3.8 * 256), "d": 8, "ghost": 1})
tick(2)
stock_ghosts = [m["e"] for m in of_type(take(), "add") if m["e"][1] == eid["entity-ghost"]]
check(len(stock_ghosts) == 1 and stock_ghosts[0][5].get("gh") == eid["locomotive"] and stock_ghosts[0][4] == 8,
      f"#13: a locomotive ghost is sent facing its orientation (south), not its direction: {stock_ghosts}")
stock_ghost = next(e for e in F.surface.entities.values() if e.name == "entity-ghost" and e.ghost_name == "locomotive")
stock_ghost.revive()  # what a construction robot does, raising on_robot_built_entity for a mover
tick(2)
msgs = take()
built = [e for e in F.surface.entities.values() if e.name == "locomotive"]
check(stock_ghosts and any(d["u"] == stock_ghosts[0][0] for d in of_type(msgs, "del")) and len(built) == 1
      and built[0].direction == 8, f"#13: the train built from the ghost sends the ghost's del: {of_type(msgs, 'del')}")

inv.remove(lua.table_from({"name": "transport-belt", "count": 999}))
puppet.insert(lua.table_from({"name": "transport-belt", "count": 2, "quality": "rare"}))
puppet.insert(lua.table_from({"name": "transport-belt", "count": 1}))
send({"t": "build", "item": "transport-belt", "x": int(0.5 * 256), "y": int(7.5 * 256), "d": 0, "q": "rare"})
send({"t": "build", "item": "transport-belt", "x": int(1.5 * 256), "y": int(7.5 * 256), "d": 0})
send({"t": "build", "item": "transport-belt", "x": int(2.5 * 256), "y": int(7.5 * 256), "d": 0})
tick(2)
adds = [m["e"] for m in of_type(take(), "add")]
check([a[5].get("q") for a in adds] == ["rare", None, "rare"],
      f"q picks the stack's quality; without it normal comes first, then what there is: {[a[5] for a in adds]}")
contents = {(it["name"], it["quality"]): it["count"] for it in inv.get_contents().values() if it["name"] == "transport-belt"}
check(not contents, f"each build used its own stack: {contents}")
for e in list(F.surface.entities.values()):
    if e.name in ("locomotive", "straight-rail") or (e.name == "transport-belt" and e.position.y == 7.5):
        e.destroy()

# --- tiles, capsules, the rail planner ----------------------------------------------------------
send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
take()
puppet.insert(lua.table_from({"name": "concrete", "count": 5}))
puppet.insert(lua.table_from({"name": "stone-brick", "count": 1}))
F.surface.set_tile(4, 3, "stone-path")
send({"t": "tile", "item": "concrete", "x": fixed(4.6), "y": fixed(3.6), "n": 2})
tick(2)
msgs = take()
flat = [v for m in of_type(msgs, "tiles") for v in m["l"]]
laid = {(flat[i], flat[i + 1]): flat[i + 2] for i in range(0, len(flat), 3)}
check(laid == {(x, y): tid["concrete"] for x in (4, 5) for y in (3, 4)} and inv.get_item_count("concrete") == 1
      and inv.get_item_count("stone-brick") == 2,
      f"tile: a 2x2 brush on the nearest corner, one concrete each, the stone path under it comes back: {laid}")
send({"t": "tile", "item": "concrete", "x": fixed(-45.5), "y": fixed(0.5), "n": 1})
send({"t": "tile", "item": "concrete", "x": fixed(4.5), "y": fixed(3.5), "n": 1})
tick(2)
check(not of_type(take(), "tiles") and inv.get_item_count("concrete") == 1, "not on water (its condition), nor on itself")
send({"t": "tile", "item": "concrete", "x": fixed(8.5), "y": fixed(12.5), "n": 3, "ghost": 1})
tick(2)
ghosts = [m["e"] for m in of_type(take(), "add") if m["e"][1] == eid["tile-ghost"]]
check(len(ghosts) == 9 and all(g[5].get("tg") == tid["concrete"] for g in ghosts) and inv.get_item_count("concrete") == 1,
      f"ghost: tile ghosts for the robots (extra.tg), no items: {ghosts[:1]}")
send({"t": "tile_mine", "x": fixed(4.5), "y": fixed(3.5), "n": 1})
send({"t": "tile_mine", "x": fixed(8.5), "y": fixed(12.5), "n": 3})
tick(2)
msgs = take()
flat = [v for m in of_type(msgs, "tiles") for v in m["l"]]
check(flat == [4, 3, tid["grass-1"]] and inv.get_item_count("concrete") == 2 and len(of_type(msgs, "del")) == 9,
      f"tile_mine: the tile back into the inventory (LuaControl.mine_tile), tile ghosts removed: {flat}")
for e in list(F.surface.entities.values()):
    if e.type == "tile-ghost":
        e.destroy()

puppet.insert(lua.table_from({"name": "grenade", "count": 2}))
send({"t": "throw", "item": "grenade", "x": fixed(puppet.position.x + 5), "y": fixed(puppet.position.y)})
send({"t": "throw", "item": "grenade", "x": fixed(puppet.position.x + 30), "y": fixed(puppet.position.y)})
tick(2)
msgs = take()
check(len(F.capsules) == 1 and F.capsules[1].name == "grenade" and inv.get_item_count("grenade") == 1
      and any(m["text"] == "Out of range" for m in of_type(msgs, "msg")),
      "throw: LuaItemStack.use_capsule at the target in range (one used), not out of range")
puppet.insert(lua.table_from({"name": "cliff-explosives", "count": 1}))
send({"t": "throw", "item": "cliff-explosives", "x": fixed(puppet.position.x + 3), "y": fixed(puppet.position.y)})
tick(2)
check(len(F.capsules) == 1 and any(m["text"] == "No cliff there" for m in of_type(take(), "msg")),
      "cliff explosives need a cliff in their radius")

inv.remove(lua.table_from({"name": "rail", "count": 999}))
puppet.insert(lua.table_from({"name": "rail", "count": 3}))
px, py = puppet.position.x, puppet.position.y
rx, ry = math.floor(px / 2) * 2 + 1, math.floor(py / 2) * 2 + 1
path = [["straight-rail", fixed(rx), fixed(ry + 6), 0], ["curved-rail-a", fixed(rx), fixed(ry + 9), 8],
        ["straight-rail", fixed(rx), fixed(ry + 24), 0]]
send({"t": "rails", "item": "rail", "l": path})
tick(2)
msgs = take()
adds = [m["e"] for m in of_type(msgs, "add")]
got = sorted((a[1], a[5].get("gh") if len(a) > 5 else None) for a in adds)
check(got == sorted([(eid["straight-rail"], None), (eid["entity-ghost"], eid["curved-rail-a"]), (eid["entity-ghost"], eid["straight-rail"])])
      and inv.get_item_count("rail") == 2 and any("2 rail pieces placed as ghosts" in m["text"] for m in of_type(msgs, "msg")),
      f"rails: the planner's pieces in order, ghosts where rails run out (a curve costs 3) or out of reach: {got}")
send({"t": "rails", "item": "rail", "l": [["assembling-machine-1", fixed(rx), fixed(ry), 0]]})
tick(2)
check(any(m["text"] == "Can't build that with rail" for m in of_type(take(), "msg")), "and nothing the planner can't build")
for e in list(F.surface.entities.values()):
    if e.type in ("straight-rail", "curved-rail-a") or (e.type == "entity-ghost" and e.ghost_name in ("straight-rail", "curved-rail-a")):
        e.destroy()

# --- fluids, wires, power ------------------------------------------------------------------------
send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
take()
pole_a = spawn("small-electric-pole", 14.5, 5.5, force="player")
pole_b = spawn("small-electric-pole", 18.5, 5.5, force="player")
F.connect(pole_a, pole_b, g.defines.wire_type.copper)
F.connect(pole_a, pole_b, g.defines.wire_type.red)
pipe = spawn("pipe", 12.5, 6.5, force="player")
F.set_fluid(pipe, 1, lua.table_from({"name": "water", "amount": 80, "temperature": 15}))
send({"t": "resync", "full": 0, "c": [[0, 0]]})
tick(60)
msgs = take()
recs = {r[0]: r for m in of_type(msgs, "ents") for r in m["e"]}
check(recs.get(pole_a.unit_number, [None] * 6)[5:] == [{"w": [pole_b.unit_number], "r": [pole_b.unit_number]}],
      f"pole records carry their copper and red wires by unit number: {recs.get(pole_a.unit_number)}")
fl = [m["l"] for m in of_type(msgs, "fl")]
check(fl and [pipe.unit_number, 1, fid["water"], 80, 100, 15] == fl[-1][fl[-1].index(pipe.unit_number):fl[-1].index(pipe.unit_number) + 6],
      f"fl: fluid in a pipe near the camera (box, fluid, amount, capacity, temperature): {fl[-1:]}")
power_asm = spawn("assembling-machine-1", 16.5, 9.5, force="player")
power_asm.status = g.defines.entity_status.no_power
tick(60)
pw = [m["l"] for m in of_type(take(), "pw")]
check(pw and pw[-1][pw[-1].index(power_asm.unit_number) + 1] == 0, f"pw: a machine without power: {pw[-1:]}")
power_asm.status = g.defines.entity_status.low_power
tick(60)
pw = [m["l"] for m in of_type(take(), "pw")]
check(pw and pw[-1][pw[-1].index(power_asm.unit_number) + 1] == 1, "pw: and with low power")
power_asm.status = g.defines.entity_status.working
F.set_fluid(power_asm, 1, lua.table_from({"name": "water", "amount": 50}), 200)
power_asm.energy = 500
puppet.position = lua.table_from({"x": 14, "y": 8})
send(open_cmd(power_asm))
tick(60)
msgs = take()
pw = [m["l"] for m in of_type(msgs, "pw")]
check(pw and power_asm.unit_number not in pw[-1][::2], "a powered machine drops out of pw")
gui = guis(msgs, power_asm)
check(gui and gui[-1].get("fb") == [["water", 50, 200, 15]] and gui[-1].get("status") == "working" and gui[-1].get("pw") == 500,
      f"gui: fluid boxes, status and how full the power buffer is: {gui[-1:]}")
send({"t": "close"})
puppet.position = lua.table_from({"x": 0, "y": 0})
for e in (pole_a, pole_b, pipe, power_asm):
    e.destroy()
tick(2)
take()

# --- blueprints, ghosts, planners -----------------------------------------------------------------
send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
take()
F.blueprint = lua.table_from([{"name": "transport-belt", "x": 0, "y": 0}, {"name": "wooden-chest", "x": 1, "y": 0}], recursive=True)
for name in ("blueprint", "deconstruction-planner", "upgrade-planner"):
    puppet.insert(lua.table_from({"name": name, "count": 1}))
inv = puppet.get_main_inventory()
size = lua.eval("function(t) return #t end")(inv)  # Python's len() skips the __len metamethod
slot = {name: next(i for i in range(1, size + 1) if inv[i].valid_for_read and inv[i].name == name)
        for name in ("blueprint", "deconstruction-planner", "upgrade-planner", "wood")}
send({"t": "blueprint", "i": slot["blueprint"], "x": int(1.5 * 256), "y": int(8.5 * 256), "d": 0})
send({"t": "blueprint", "i": slot["wood"], "x": 0, "y": 0, "d": 0})
tick(2)
msgs = take()
ghosts = [m["e"] for m in of_type(msgs, "add") if m["e"][1] == eid["entity-ghost"]]
check(sorted((g[2], g[3], g[5].get("gh")) for g in ghosts) == [(384, 2176, eid["transport-belt"]), (640, 2176, eid["wooden-chest"])],
      f"blueprint places ghosts, sent as static entities with the entity they stand for: {ghosts}")
check(any(m["text"] == "That isn't a blueprint" for m in of_type(msgs, "msg")), "a slot without a blueprint is refused")
check(F.last_build_mode == 1, "a blueprint without bm is placed forced, as older clients expect")
for bm, mode in ((0, 0), (1, 1), (2, 2)):
    send({"t": "blueprint", "i": slot["blueprint"], "x": int(1.5 * 256), "y": int(30.5 * 256), "d": 0, "bm": bm})
    tick(1)
    check(F.last_build_mode == mode, f"bm {bm}: build_mode {mode} (click normal, Shift forced, Ctrl+Shift super-forced)")
for e in list(F.surface.entities.values()):
    if e.position.y == 30.5:
        e.destroy()
take()
belt_ghost = next(g for g in ghosts if g[5]["gh"] == eid["transport-belt"])
puppet.insert(lua.table_from({"name": "transport-belt", "count": 1}))
belts = inv.get_item_count("transport-belt")
# Plates lying where the belt goes: 2.1's revive picks them up and returns them as
# array[ItemWithQualityCount], which the bridge read as name -> count and threw on.
spawn("item-on-ground", belt_ghost[2] / 256, belt_ghost[3] / 256, stack={"name": "iron-plate", "count": 3})
plates = inv.get_item_count("iron-plate")
send({"t": "build", "item": "transport-belt", "x": belt_ghost[2], "y": belt_ghost[3], "d": 0})
tick(2)
msgs = take()
check(any(d["u"] == belt_ghost[0] for d in of_type(msgs, "del")) and any(a["e"][1] == eid["transport-belt"] and a["e"][2:4] == belt_ghost[2:4] for a in of_type(msgs, "add"))
      and inv.get_item_count("transport-belt") == belts - 1, "building over a ghost revives it: the ghost's del, the belt's add")
check(inv.get_item_count("iron-plate") == plates + 3 and not any("Bridge error" in m["text"] for m in of_type(msgs, "msg")),
      f"what the revived belt collided with (2.1: an array of ItemWithQualityCount) goes to the character: "
      f"{inv.get_item_count('iron-plate') - plates} plates, {[m['text'] for m in of_type(msgs, 'msg')]}")
belt_real = next(e for e in F.surface.entities.values() if e.name == "transport-belt" and e.position.y == 8.5)
area = {"x1": 0, "y1": 8 * 256, "x2": 3 * 256, "y2": 9 * 256}
chest_ghost = next(g for g in ghosts if g[5]["gh"] == eid["wooden-chest"])
send({"t": "decon", "i": 0, **area})
tick(2)
msgs = take()
upd = [m["e"] for m in of_type(msgs, "upd") if m["e"][0] == belt_real.unit_number]
check(upd and upd[-1][5].get("d") == 1, f"decon without a planner marks the area; the record says so: {upd[-1:]}")
# Owner's #20: Factorio deletes the ghosts in the area with no event, so the client must be told.
check(any(d["u"] == chest_ghost[0] for d in of_type(msgs, "del")), f"decon (Alt+D) removes the ghosts in the area and sends their del: {of_type(msgs, 'del')}")
send({"t": "decon", "i": slot["deconstruction-planner"], "cancel": 1, **area})
tick(2)
upd = [m["e"] for m in of_type(take(), "upd") if m["e"][0] == belt_real.unit_number]
check(upd and "d" not in upd[-1][5], "a deconstruction planner's cancel unmarks it")
F.upgrades = lua.table_from({"transport-belt": "fast-transport-belt"})
send({"t": "upgrade", "i": slot["upgrade-planner"], **area})
tick(2)
upd = [m["e"] for m in of_type(take(), "upd") if m["e"][0] == belt_real.unit_number]
check(upd and upd[-1][5].get("up") == eid["fast-transport-belt"], f"upgrade marks it with its target: {upd[-1:]}")
send({"t": "upgrade", "i": slot["upgrade-planner"], "cancel": 1, **area})
send({"t": "upgrade", "i": slot["wood"], **area})
tick(2)
msgs = take()
check(any("up" not in m["e"][5] for m in of_type(msgs, "upd") if m["e"][0] == belt_real.unit_number), "cancelling the upgrade unmarks it")
check(any(m["text"] == "That isn't an upgrade planner" for m in of_type(msgs, "msg")), "a slot without an upgrade planner is refused")
# Downgrade (right-drag): the planner's mappings the other way round.
up = inv[slot["upgrade-planner"]]
up.set_mapper(1, "from", lua.table_from({"type": "entity", "name": "transport-belt"}))
up.set_mapper(1, "to", lua.table_from({"type": "entity", "name": "fast-transport-belt"}))
fast = spawn("fast-transport-belt", 0.5, 8.5)
take()
send({"t": "upgrade", "i": slot["upgrade-planner"], "down": 1, **area})
tick(2)
msgs = take()
upd = [m["e"] for m in of_type(msgs, "upd") if m["e"][0] == fast.unit_number]
check(upd and upd[-1][5].get("up") == eid["transport-belt"], f"down: 1 marks by the reversed mappings (fast belt -> belt): {upd[-1:]}")
check(not any(m["e"][0] == belt_real.unit_number and m["e"][5].get("up") for m in of_type(msgs, "upd")), "and not the plain belt")
check(up.mapper_count == 1 and up.get_mapper(1, "from").name == "transport-belt", "the planner itself keeps its mappings")
send({"t": "upgrade", "i": slot["upgrade-planner"], "cancel": 1, **area})
tick(2)
take()
# bp_del: the planner window's delete button destroys the planner; anything else stays.
puppet.insert(lua.table_from({"name": "blueprint-book", "count": 1}))
spare = next(i for i in range(1, size + 1) if inv[i].valid_for_read and inv[i].name == "blueprint-book")
# Owner's #13: the icons a book was given are drawn over it in the inventory, so they go with `slots`.
inv[spare].preview_icons = lua.eval('{{signal = {type = "virtual", name = "signal-A"}, index = 2}, {signal = {name = "iron-plate"}, index = 1}}')
tick(31)
ic = [m.get("ic") for m in of_type(take(), "slots")]
check(ic and [spare, [["item", "iron-plate"], ["virtual", "signal-A"]]] in (ic[-1] or []),
      f"slots carries a book's icons in their order (ic): {ic[-1:]}")
send({"t": "bp_del", "i": spare})
send({"t": "bp_del", "i": slot["wood"]})
tick(1)
check(not inv[spare].valid_for_read and inv[slot["wood"]].valid_for_read, "bp_del destroys a planner, not other items")
for e in list(F.surface.entities.values()):
    if e.position.y == 8.5 and e.position.x < 3:
        e.destroy()

# --- exchange strings, the library, undo, super-forced build, qualities -------------------------
take()
g.package.loaded["scripts.planners"].send_initial()  # sent at every handshake
tick(1)
quals = of_type(take(), "quals")
check(quals and [q[0] for q in quals[-1]["l"]] == ["normal", "uncommon", "rare", "epic", "legendary"]
      and quals[-1]["l"][2][2] == 1 and quals[-1]["l"][3][2] == 0,
      f"quals lists the qualities in order, unlocked ones marked, without quality-unknown: {quals[-1:]}")
inv[slot["blueprint"]].import_stack("0FAKE|blueprint|Belt and chest|transport-belt,wooden-chest")
send({"t": "bp_get", "q": 7, "i": slot["blueprint"]})
tick(2)
bp = of_type(take(), "bp")
check(len(bp) == 1 and bp[0]["q"] == 7 and bp[0]["s"].startswith("0FAKE|blueprint|Belt and chest") and bp[0]["item"] == "blueprint",
      f"bp_get exports the blueprint as its string: {bp}")
send({"t": "bp_get", "q": 8, "i": slot["wood"]})
tick(2)
bp = of_type(take(), "bp")
check(bp and bp[0]["s"] == "" and bp[0].get("err"), f"bp_get on something else says so: {bp}")
long_label = "x" * 40000
inv[slot["blueprint"]].import_stack("0FAKE|blueprint|" + long_label + "|transport-belt")
send({"t": "bp_get", "q": 9, "i": slot["blueprint"]})
tick(2)
bp = of_type(take(), "bp")
check(len(bp) == 3 and [m["part"] for m in bp] == [1, 2, 3] and all(m["parts"] == 3 for m in bp)
      and "".join(m["s"] for m in bp) == "0FAKE|blueprint|" + long_label + "|transport-belt",
      "a long string comes in parts that join up again")
inv[slot["blueprint"]].import_stack("0FAKE|blueprint|Belt and chest|transport-belt,wooden-chest")
# bp_set: a new one in the inventory, in parts; the cursor's library stack (-1)
data = "0FAKE|blueprint|From the library|transport-belt,wooden-chest"
send({"t": "bp_set", "q": 3, "i": 0, "id": 41, "part": 2, "parts": 2, "d": data[20:]})
send({"t": "bp_set", "q": 3, "i": 0, "id": 41, "part": 1, "parts": 2, "d": data[:20]})
tick(2)
ok = of_type(take(), "bp_ok")
check(ok and ok[-1]["q"] == 3 and ok[-1]["item"] == "blueprint" and inv[ok[-1]["i"]].valid_for_read
      and inv[ok[-1]["i"]].export_stack().startswith("0FAKE|blueprint|From the library"),
      f"bp_set in parts makes a new blueprint in the inventory and says which slot: {ok}")
send({"t": "bp_set", "q": 4, "i": slot["wood"], "s": data})
send({"t": "bp_set", "q": 5, "i": 0, "s": "not a blueprint string"})
tick(2)
msgs = take()
check(not of_type(msgs, "bp_ok") and any(m["text"] == "That slot holds something else" for m in of_type(msgs, "msg"))
      and any("can import" in m["text"] for m in of_type(msgs, "msg")), "bp_set refuses another item's slot and a bad string")
send({"t": "bp_set", "q": 6, "i": -1, "s": data})
tick(2)
ok = of_type(take(), "bp_ok")
check(ok and ok[-1]["i"] == -1 and g.storage.f3d.lib_cursor[1].valid_for_read, f"bp_set -1 fills the library stack in the cursor: {ok}")
send({"t": "blueprint", "i": -1, "x": fixed(2.5), "y": fixed(26.5), "d": 0})
tick(2)
msgs = take()
placed = [m["e"] for m in of_type(msgs, "add") if m["e"][1] == eid["entity-ghost"]]
hist = of_type(msgs, "hist")
check(len(placed) == 2 and hist and hist[-1]["what"] == "blueprint", f"the cursor's library blueprint places ghosts, remembered for undo: {hist}")
send({"t": "undo", "h": hist[-1]["h"] if hist else 0})
tick(2)
dels = [m["u"] for m in of_type(take(), "del")]
check(sorted(dels) == sorted(p[0] for p in placed), f"undo takes the placed ghosts away: {dels}")
send({"t": "redo", "h": hist[-1]["h"] if hist else 0})
tick(2)
again = [m["e"] for m in of_type(take(), "add") if m["e"][1] == eid["entity-ghost"]]
check(len(again) == 2, "redo places them again")
# m: 1, a held blueprint flipped: a mirrored copy is placed; the blueprint itself stays as it was.
lib = g.storage.f3d.lib_cursor[1]
lib.set_blueprint_entities(lua.table_from([
    {"entity_number": 1, "name": "transport-belt", "position": {"x": -1.5, "y": 0.5}, "direction": 4},
    {"entity_number": 2, "name": "assembling-machine-1", "position": {"x": 2.5, "y": 0.5}},
], recursive=True))
send({"t": "blueprint", "i": -1, "x": fixed(40.5), "y": fixed(40.5), "d": 0, "m": 1})
tick(2)
take()
built = {b.name: b for b in F.last_built.values()}
belt_b, asm_b2 = built.get("transport-belt"), built.get("assembling-machine-1")
check(belt_b and belt_b.position.x == 1.5 and belt_b.direction == 12 and asm_b2 and asm_b2.position.x == -2.5 and asm_b2.mirror is True,
      "m: 1 places the blueprint mirrored: x negated, east becomes west, the assembler's mirror flag set")
check(lib.get_blueprint_entities()[1].position.x == -1.5, "and the held blueprint itself is unchanged")
for e in list(F.surface.entities.values()):
    if e.position.y == 40.5 or e.position.y == 41.5 or e.position.y == 39.5:
        e.destroy()
take()
send({"t": "undo", "h": 99999})
tick(2)
check(any(m["text"] == "That can no longer be undone" for m in of_type(take(), "msg")), "an unknown undo entry is refused")
# Deconstruction marks: undo removes exactly the marks that action added.
chest_a = spawn("wooden-chest", 40.5, 40.5, force="player")
chest_b = spawn("wooden-chest", 41.5, 40.5, force="player")
chest_b.order_deconstruction("player")
send({"t": "decon", "i": 0, "x1": fixed(40), "y1": fixed(40), "x2": fixed(42), "y2": fixed(41)})
tick(2)
hist = of_type(take(), "hist")
check(hist and hist[-1]["what"] == "deconstruction" and F.decon_marks[chest_a] is True, f"decon is remembered: {hist}")
send({"t": "undo", "h": hist[-1]["h"] if hist else 0})
tick(2)
check(F.decon_marks[chest_a] is None and F.decon_marks[chest_b] is True, "undo removes its own marks and keeps the older one")
send({"t": "redo", "h": hist[-1]["h"] if hist else 0})
tick(2)
check(F.decon_marks[chest_a] is True, "redo marks it again")
send({"t": "decon", "i": 0, "cancel": 1, "x1": fixed(40), "y1": fixed(40), "x2": fixed(42), "y2": fixed(41)})
tick(2)
hist = of_type(take(), "hist")
check(hist and hist[-1]["what"] == "cancel deconstruction" and F.decon_marks[chest_b] is None, "cancelling is remembered too")
send({"t": "undo", "h": hist[-1]["h"] if hist else 0})
tick(2)
check(F.decon_marks[chest_a] is True and F.decon_marks[chest_b] is True, "undoing a cancel puts the marks back")
# Upgrade marks
belt_u = spawn("transport-belt", 44.5, 40.5, force="player")
send({"t": "upgrade", "i": slot["upgrade-planner"], "x1": fixed(44), "y1": fixed(40), "x2": fixed(45), "y2": fixed(41)})
tick(2)
hist = of_type(take(), "hist")
check(hist and hist[-1]["what"] == "upgrade" and F.upgrade_marks[belt_u] is not None, "upgrade is remembered")
send({"t": "undo", "h": hist[-1]["h"] if hist else 0})
tick(2)
check(F.upgrade_marks[belt_u] is None, "undo cancels the upgrade")
send({"t": "redo", "h": hist[-1]["h"] if hist else 0})
tick(2)
check(F.upgrade_marks[belt_u] is not None and F.upgrade_marks[belt_u].name == "fast-transport-belt", "redo marks the upgrade again, to the same target")
# Rotation
d0 = belt_u.direction
send({"t": "rotate", "u": belt_u.unit_number, "p": eid["transport-belt"], "x": fixed(44.5), "y": fixed(40.5), "rev": 0})
tick(2)
hist = of_type(take(), "hist")
check(hist and hist[-1]["what"] == "rotation" and belt_u.direction == (d0 + 4) % 16, "a rotation is remembered")
send({"t": "undo", "h": hist[-1]["h"] if hist else 0})
tick(2)
check(belt_u.direction == d0, "undo turns it back")
# Super-forced build (Ctrl+Shift+click): a ghost through a one-entity blueprint
puppet.insert(lua.table_from({"name": "wooden-chest", "count": 1}))
send({"t": "build", "item": "wooden-chest", "x": fixed(10.5), "y": fixed(26.5), "d": 0, "ghost": 1, "sf": 1})
tick(2)
msgs = take()
sf = [m["e"] for m in of_type(msgs, "add") if m["e"][1] == eid["entity-ghost"] and m["e"][5].get("gh") == eid["wooden-chest"]]
check(sf and sf[0][2:4] == [fixed(10.5), fixed(26.5)] and of_type(msgs, "hist"), f"super-forced build places a ghost there, undoably: {sf}")
# The game's and an offline player's libraries
F.game_blueprints[1] = F.make_record("blueprint", "Smelting", "0FAKE|blueprint|Smelting|stone-furnace")
F.game_blueprints[2] = F.make_record("blueprint-book", "Trains", "0FAKE|blueprint-book|Trains|")
send({"t": "bp_lib"})
tick(2)
bpl = of_type(take(), "bpl")
check(bpl and bpl[0]["src"] == "game" and bpl[0]["l"][0][:3] == [1, "blueprint", "Smelting"] and bpl[0]["l"][1][1] == "blueprint-book"
      and bpl[0]["l"][0][3] == [["item", "transport-belt"]], f"bp_lib lists the game's library: {bpl}")
send({"t": "bp_rec", "q": 11, "src": "game", "ix": 1})
tick(2)
bp = of_type(take(), "bp")
check(bp and bp[0]["s"] == "0FAKE|blueprint|Smelting|stone-furnace" and bp[0]["src"] == "game" and bp[0]["ix"] == 1,
      f"bp_rec sends a record's string: {bp}")
send({"t": "bp_rec", "q": 12, "src": "game", "ix": 2, "to": -1})
tick(2)
ok = of_type(take(), "bp_ok")
check(ok and ok[-1]["i"] == -1 and ok[-1]["item"] == "blueprint-book", f"bp_rec with to = -1 takes it into the cursor: {ok}")
send({"t": "bp_page", "i": -1, "a": 2})
tick(2)
check(g.storage.f3d.lib_cursor[1].active_index == 2, "bp_page picks the book's page")
send({"t": "bp_rec", "q": 13, "src": "player", "ix": 1})
tick(2)
bp = of_type(take(), "bp")
check(bp and bp[0]["s"] == "" and bp[0].get("err"), "without a player taken over there is no player library")
for e in (chest_a, chest_b, belt_u):
    e.destroy()
for e in list(F.surface.entities.values()):
    if e.type == "entity-ghost" and e.position.y == 26.5:
        e.destroy()
take()

# --- circuit network ------------------------------------------------------------------------------
send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
take()
ids = g.defines.wire_connector_id
arith = spawn("arithmetic-combinator", 4.5, 3.0, force="player")
const = spawn("constant-combinator", 6.5, 3.5, force="player")
F.signals[arith] = lua.table_from({ids.circuit_red: [{"signal": {"type": "item", "name": "iron-plate"}, "count": 40}]}, recursive=True)
send(open_cmd(arith))
tick(2)
gui = guis(take(), arith)
check(gui and gui[-1]["kind"] == "combinator" and gui[-1]["cb"].get("operation") == "*" and gui[-1]["cb"].get("second_constant") == 2,
      f"an arithmetic combinator opens with its parameters: {gui[-1:]}")
check(gui and gui[-1].get("sig") == {"r": [["item", "iron-plate", 40]], "g": []}, f"and the signals on its networks: {gui[-1:]}")
params = dict(gui[-1]["cb"]) if gui else {}
params["operation"] = "+"
send({"t": "set_cb", "u": arith.unit_number, "cb": params})
tick(2)
gui = guis(take(), arith)
check(gui and gui[-1]["cb"]["operation"] == "+" and arith.get_control_behavior().parameters.operation == "+",
      "set_cb writes the parameters back")
send(open_cmd(const))
send({"t": "set_cb", "u": const.unit_number, "cb": {"enabled": True, "signals": [["item", "iron-plate", 5], ["virtual", "signal-A", -3]]}})
tick(2)
gui = guis(take(), const)
check(gui and gui[-1]["cb"]["enabled"] is True and gui[-1]["cb"]["signals"] == [["item", "iron-plate", 5], ["virtual", "signal-A", -3]],
      f"a constant combinator's signals are set and read back: {gui[-1:]}")
# Sections: a second one, inactive with a multiplier; then back to one (the extra is removed).
two = [{"g": "", "on": 1, "m": 1, "s": [["item", "iron-plate", 5]]}, {"g": "", "on": 0, "m": 2, "s": [["virtual", "signal-B", 7, "rare"]]}]
send({"t": "set_cb", "u": const.unit_number, "cb": {"enabled": True, "sections": two}})
tick(2)
gui = guis(take(), const)
check(gui and gui[-1]["cb"]["sections"] == two and gui[-1]["cb"]["signals"] == [["item", "iron-plate", 5]],
      f"constant combinator sections (add_section, active, multiplier, quality) read back: {gui[-1:]}")
send({"t": "set_cb", "u": const.unit_number, "cb": {"enabled": False, "sections": two[:1]}})
tick(2)
gui = guis(take(), const)
check(gui and len(gui[-1]["cb"]["sections"]) == 1 and gui[-1]["cb"]["enabled"] is False, f"remove_section drops the extra one: {gui[-1:]}")
send({"t": "set_cb", "u": const.unit_number, "cb": "nonsense"})
tick(2)
check(any(m["text"] == "That isn't a combinator" for m in of_type(take(), "msg")), "bad settings are refused")
send({"t": "close"})

# Wire tools: red wire from the constant combinator to the arithmetic one's input, again to undo.
def wire_end(entity, dx=0.0, dy=0.0):
    p = entity.position
    return {"u": entity.unit_number, "p": eid[entity.name], "x": fixed(p.x), "y": fixed(p.y),
            "mx": fixed(p.x + dx), "my": fixed(p.y + dy)}


send({"t": "wire", "k": "r", "a": wire_end(const), "b": wire_end(arith, 0, 0.4)})
tick(2)
msgs = take()
red = arith.get_wire_connector(ids.combinator_input_red, False)
check(red.is_connected_to(const.get_wire_connector(ids.circuit_red, False)), "wire: a red wire connects two combinators (connect_to)")
check({m["e"][0] for m in of_type(msgs, "upd")} >= {arith.unit_number, const.unit_number}
      and arith.unit_number in of_type(msgs, "upd")[-1]["e"][5].get("r", []) + [m["e"][5].get("r", [0])[0] for m in of_type(msgs, "upd")],
      f"and both ends are sent again with their wires: {of_type(msgs, 'upd')}")
send({"t": "wire", "k": "r", "a": wire_end(const), "b": wire_end(arith, 0, 0.4)})
tick(2)
take()
check(not red.is_connected_to(const.get_wire_connector(ids.circuit_red, False)), "wire: the same pair again disconnects them")
send({"t": "wire", "k": "w", "a": wire_end(const), "b": wire_end(arith)})
tick(2)
check(any("Copper wire" in m["text"] for m in of_type(take(), "msg")), "copper wire on combinators is refused")
pole_a = spawn("small-electric-pole", -2.5, 4.5, force="player")
pole_b = spawn("small-electric-pole", 3.5, 4.5, force="player")
pole_far = spawn("small-electric-pole", 6.5, -4.5, force="player")
send({"t": "wire", "k": "w", "a": wire_end(pole_a), "b": wire_end(pole_b)})
tick(2)
take()
copper = pole_a.get_wire_connector(ids.pole_copper, False)
check(copper.is_connected_to(pole_b.get_wire_connector(ids.pole_copper, False)), "copper wire connects two poles")
F.wire_reach = 7.5
send({"t": "wire", "k": "w", "a": wire_end(pole_a), "b": wire_end(pole_far)})
tick(2)
check(any(m["text"] == "Wire can't reach that far" for m in of_type(take(), "msg")), "a wire that can't reach is refused (can_wire_reach)")
send({"t": "wire_clear", **{k: v for k, v in wire_end(pole_a).items() if k in ("u", "p", "x", "y")}})
tick(2)
msgs = take()
check(len(copper.connections) == 0 and len(pole_b.get_wire_connector(ids.pole_copper, False).connections) == 0,
      "wire_clear removes a pole's copper cables (disconnect_all)")
check(any(m["e"][0] == pole_b.unit_number for m in of_type(msgs, "upd")), "and the pole at the other end is sent again")

# Circuit settings (gui.cc / set_cc): an inserter's enable condition and read modes.
ins_c = spawn("inserter", 2.5, 6.5, force="player")
F.networks[ins_c] = lua.table_from({ids.circuit_red: lua.table_from({"network_id": 12})})
send(open_cmd(ins_c))
tick(2)
gui = guis(take(), ins_c)
cc = gui[-1].get("cc") if gui else None
check(cc and cc["o"] == "inserter" and cc["w"] == 1 and cc["nets"] == {"r": 12, "g": 0}
      and cc["f"].get("circuit_hand_read_mode") == "hold" and cc["f"].get("circuit_enable_disable") == 0,
      f"gui.cc: an inserter's circuit settings, wired to network 12: {cc}")
send({"t": "set_cc", "u": ins_c.unit_number, "f": {
    "circuit_enable_disable": 1, "circuit_condition": {"first_signal": {"type": "item", "name": "iron-plate"}, "comparator": ">", "constant": 50},
    "circuit_hand_read_mode": "pulse", "circuit_read_hand_contents": 1, "circuit_set_stack_size": 1,
    "circuit_stack_control_signal": {"type": "virtual", "name": "signal-S"}, "not_a_field": 1}})
tick(2)
gui = guis(take(), ins_c)
f = gui[-1]["cc"]["f"] if gui else {}
check(f.get("circuit_enable_disable") == 1 and f.get("circuit_condition", {}).get("first_signal") == {"type": "item", "name": "iron-plate"}
      and f["circuit_condition"].get("constant") == 50 and f.get("circuit_hand_read_mode") == "pulse"
      and f.get("circuit_stack_control_signal") == {"type": "virtual", "name": "signal-S"}, f"set_cc writes the behaviour's fields: {f}")
send({"t": "set_cc", "u": ins_c.unit_number, "f": {"circuit_stack_control_signal": {}}})
tick(2)
gui = guis(take(), ins_c)
check(gui and gui[-1]["cc"]["f"].get("circuit_stack_control_signal") in ({}, []), "an empty signal clears it")

# A lamp's colour and its circuit colour settings.
lamp_c = spawn("small-lamp", 4.5, 6.5, force="player")
send(open_cmd(lamp_c))
tick(2)
gui = guis(take(), lamp_c)
check(gui and gui[-1].get("col") == [255, 255, 255] and gui[-1]["cc"]["o"] == "lamp" and gui[-1]["cc"]["w"] == 0,
      f"a lamp opens with its colour and circuit settings: {gui[-1:]}")
send({"t": "set_color", "u": lamp_c.unit_number, "c": [255, 64, 0]})
send({"t": "set_cc", "u": lamp_c.unit_number, "f": {"use_colors": 1, "color_mode": "components", "red_signal": {"type": "virtual", "name": "signal-R"}}})
tick(2)
gui = guis(take(), lamp_c)
check(gui and gui[-1]["col"] == [255, 64, 0] and gui[-1]["cc"]["f"].get("use_colors") == 1 and gui[-1]["cc"]["f"].get("color_mode") == "components",
      f"set_color and the lamp's colour mode: {gui[-1:]}")
check(gui and gui[-1].get("ao") == 0, f"a lamp sends Always on: {gui[-1:]}")
send({"t": "set_lamp", "u": lamp_c.unit_number, "ao": 1})
tick(2)
gui = guis(take(), lamp_c)
check(gui and gui[-1].get("ao") == 1 and lamp_c.always_on, f"set_lamp turns Always on on: {gui[-1:]}")

# A rail signal opens (status only); a combinator sends and takes its description.
rsig = spawn("rail-signal", 6.5, 6.5, force="player")
send(open_cmd(rsig))
tick(2)
check(bool(guis(take(), rsig)), "a rail signal opens a window")
rod = spawn("lightning-rod", 5.5, 8.5, force="player")
send(open_cmd(rod))
tick(2)
msgs = take()
check(not guis(msgs, rod) and not [m for m in of_type(msgs, "msg") if "open" in m["text"]],
      "a lightning rod opens no window and says nothing, as in 2.1.23")
rod.destroy()
desc_c = spawn("constant-combinator", 3.5, 7.5, force="player")
send(open_cmd(desc_c))
tick(2)
gui = guis(take(), desc_c)
check(gui and gui[-1].get("desc") == "", f"a combinator sends its description: {gui[-1:]}")
send({"t": "set_desc", "u": desc_c.unit_number, "text": "Outpost"})
tick(2)
gui = guis(take(), desc_c)
check(gui and gui[-1].get("desc") == "Outpost" and desc_c.combinator_description == "Outpost", f"set_desc: {gui[-1:]}")
send({"t": "close"})
tick(1)
take()
for e in (rsig, desc_c):
    e.destroy()

# Turret priority targets.
tur_c = spawn("gun-turret", -4.0, 7.0, force="player")
send(open_cmd(tur_c))
send({"t": "set_targets", "u": tur_c.unit_number, "l": ["small-biter", "nonsense"], "ign": 1})
tick(2)
gui = guis(take(), tur_c)
check(gui and gui[-1].get("tgt") == {"l": ["small-biter"], "ign": 1}, f"set_targets: priority targets and ignore the rest: {gui[-1:]}")
send({"t": "set_targets", "u": tur_c.unit_number, "l": []})
tick(2)
gui = guis(take(), tur_c)
check(gui and gui[-1]["tgt"]["l"] in ([], {}), f"and clears them (set_priority_target without an entity): {gui[-1:]}")
send({"t": "close"})
for e in (arith, const, pole_a, pole_b, pole_far, ins_c, lamp_c, tur_c):
    e.destroy()
tick(2)
take()

# Spidertrons (entity_ui.lua veh, set_vehicle; spiders.lua spider_go / spider_q), artillery's auto
# targeting (art, set_artillery), a storage tank's pipeline and flush (pl, flush), a train's group.
spider = spawn("spidertron", -3.0, 4.0, force="player")
send(open_cmd(spider))
tick(2)
gui = guis(take(), spider)
check(gui and gui[-1].get("kind") == "vehicle" and gui[-1].get("veh") == {"grid": 0, "lbl": "", "at": [1, 0]} and gui[-1].get("col") == [255, 128, 0],
      f"a spidertron opens with its name, auto targeting and colour: {gui[-1:]}")
send({"t": "set_vehicle", "u": spider.unit_number, "lbl": "Spidey", "wi": 1})
send({"t": "set_color", "u": spider.unit_number, "c": [0, 0, 255]})
tick(2)
gui = guis(take(), spider)
check(gui and gui[-1]["veh"] == {"grid": 0, "lbl": "Spidey", "at": [1, 1]} and gui[-1]["col"] == [0, 0, 255] and spider.entity_label == "Spidey",
      f"set_vehicle names it and turns targeting with a gunner on; set_color colours it: {gui[-1:]}")
send({"t": "close"})
send({"t": "spider_go", "l": [spider.unit_number, 999999], "x": fixed(20), "y": fixed(-5)})
tick(1)
spd = of_type(take(), "spd")
check(spd and spd[-1]["l"] == [[spider.unit_number, [[fixed(20), fixed(-5)]]]], f"spider_go sends it there (autopilot_destination): {spd[-1:]}")
send({"t": "spider_go", "l": [spider.unit_number], "x": fixed(25), "y": fixed(-5), "q": 1})
send({"t": "spider_q", "l": [spider.unit_number]})
tick(1)
spd = of_type(take(), "spd")
check(spd and spd[-1]["l"][0][1] == [[fixed(20), fixed(-5)], [fixed(25), fixed(-5)]], f"Shift queues a waypoint (add_autopilot_destination): {spd[-1:]}")
send({"t": "spider_go", "l": [spider.unit_number], "x": fixed(1), "y": fixed(1)})
tick(1)
spd = of_type(take(), "spd")
check(spd and spd[-1]["l"][0][1] == [[fixed(1), fixed(1)]], f"a plain click replaces the queue: {spd[-1:]}")
spider.destroy()
art = spawn("artillery-turret", -8.5, 4.5, force="player")
send(open_cmd(art))
tick(2)
gui = guis(take(), art)
check(gui and gui[-1].get("art") == 1, f"artillery sends its auto targeting: {gui[-1:]}")
send({"t": "set_artillery", "u": art.unit_number, "on": 0})
tick(2)
gui = guis(take(), art)
check(gui and gui[-1].get("art") == 0 and art.artillery_auto_targeting is False, f"set_artillery turns it off: {gui[-1:]}")
send({"t": "close"})
art.destroy()
tank = spawn("storage-tank", -3.5, 8.5, force="player")
F.set_fluid(tank, 1, lua.table_from({"name": "crude-oil", "amount": 2000}), 25000)
F.segments[tank] = lua.table_from({"fluid": lua.table_from({"name": "crude-oil", "amount": 6000}), "capacity": 40000})
send(open_cmd(tank))
tick(2)
gui = guis(take(), tank)
check(gui and gui[-1].get("pl") == ["crude-oil", 6000, 40000], f"a storage tank sends its pipeline's contents (get_fluid_segment_fluid): {gui[-1:]}")
send({"t": "flush", "u": tank.unit_number, "pipe": 0})
tick(2)
gui = guis(take(), tank)
check(tank.get_fluid(1) is None, f"flush empties the tank (remove_fluid): {gui[-1:]}")
send({"t": "flush", "u": tank.unit_number, "pipe": 1})
tick(2)
gui = guis(take(), tank)
check(gui and gui[-1].get("pl") == ["", 0, 25000], f"flush with pipe 1 empties the pipeline (clear_fluid_segment_fluid): {gui[-1:]}")
send({"t": "close"})
tank.destroy()
tick(2)
take()

# --- map: charts and tags -------------------------------------------------------------------------
send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
take()
F.charted["0,0"] = True
g.storage.f3d.explored = None  # what the character charted itself, tested below
wall = spawn("stone-wall", 28.5, 28.5, force="player")
ore = spawn("iron-ore", 29.5, 28.5, amount=100)
send({"t": "map", "cx1": 0, "cy1": 0, "cx2": 1, "cy2": 0, "res": 2})
tick(2)
msgs = take()
charts = {(m["cx"], m["cy"]): m for m in of_type(msgs, "chart")}
c00 = charts.get((0, 0))
check(c00 and c00["n"] == 16 and len(c00["px"]) == 256, f"a charted chunk comes as 16 x 16 pixels at 2 tiles each: {c00}")
check(charts.get((1, 0), {}).get("n") == 0, "a chunk not charted yet says so (n = 0)")
check(c00 and c00["pal"][c00["px"][14 * 16 + 14]] == [204, 217, 204],
      "a wall without a map colour gets Factorio's wall colour, over the ore under it")
check(c00 and [51, 128, 26] in c00["pal"], "tiles are drawn in their map colour")
check(of_type(msgs, "tags") and of_type(msgs, "tags")[-1]["l"] in ([], {}), "a map request sends the tags (none yet)")
send({"t": "map", "cx1": 0, "cy1": 0, "cx2": 0, "cy2": 0, "res": 3})
tick(1)
c00 = [m for m in of_type(take(), "chart") if (m["cx"], m["cy"]) == (0, 0)]
check(c00 and c00[0]["n"] == 8, "an unknown resolution falls back to 4 tiles per pixel")
send({"t": "map", "cx1": -100, "cy1": -100, "cx2": 100, "cy2": 100, "res": 32})
tick(1)
check(len(g.storage.f3d.map.queue) <= 1024, "a huge request is cut to the 1024 chunks nearest its centre")
send({"t": "map", "cx1": 0, "cy1": 0, "cx2": 0, "cy2": 0, "res": 32})
tick(2)
c00 = [m for m in of_type(take(), "chart") if (m["cx"], m["cy"]) == (0, 0)]
check(c00 and c00[0]["n"] == 1 and len(c00[0]["px"]) == 1, "32 tiles per pixel is one pixel per chunk")
wall.destroy()
ore.destroy()

# The work budget (budget.lua): a busy chunk's chart and snapshot are read in slices over several
# ticks, and no tick spends more than the budget; `budget` sets it (clamped), `wb` reports it.
start_tick = g.game.tick
send({"t": "budget", "u": 400})
tick(1)
check(g.storage.f3d.bud.limit == 400, f"budget sets the work budget: {g.storage.f3d.bud.limit}")
F.charted["-3,3"] = True
dense = [spawn("stone-wall", -95.5 + i % 32, 96.5 + i // 32, force="player") for i in range(1000)]
take()
send({"t": "map", "cx1": -3, "cy1": 3, "cx2": -3, "cy2": 3, "res": 2})
used, got, ticks = [], None, 0
while got is None and ticks < 40:
    tick(1)
    ticks += 1
    used.append(g.storage.f3d.bud.used)
    got = next((m for m in of_type(take(), "chart") if (m["cx"], m["cy"]) == (-3, 3)), None)
check(got and got["n"] == 16 and sum(1 for p in got["px"] if got["pal"][p] == [204, 217, 204]) == 256,
      f"a chart read in strips still has every wall: {got and got['pal']}")
check(ticks >= 4 and max(used) <= 400, f"a 1000-entity chart takes several ticks, none over the budget: {ticks} ticks, {used}")
old_subs = [[int(c[1]), int(c[2])] for c in g.storage.f3d.subs.values()]
send({"t": "sub", "c": old_subs + [[-3, 3]]})
used, ents, head, ticks = [], [], None, 0
while not (head and len(ents) == head.get("parts", -1)) and ticks < 200:
    tick(1)
    ticks += 1
    used.append(g.storage.f3d.bud.used)
    msgs = take()
    head = next((m for m in of_type(msgs, "chunk") if (m["cx"], m["cy"]) == (-3, 3)), head)
    ents += [m for m in of_type(msgs, "ents") if (m["cx"], m["cy"]) == (-3, 3)]
records = [rec for m in ents for rec in m["e"]]
check(head and len(records) == 1000, f"a snapshot read in strips has every entity once: {len(records)} {head}")
check(max(used) <= 400, f"no tick of the snapshot over the budget: {max(used)}")
send({"t": "sub", "c": old_subs})
for e in dense:
    e.destroy()
for u, want in ((5, 50), (10 ** 9, 20000), ("x", 20000), (500, 500)):
    send({"t": "budget", "u": u})
    tick(1)
    check(g.storage.f3d.bud.limit == want, f"budget {u!r} -> {want}: {g.storage.f3d.bud.limit}")
tick(60)
wb = of_type(take(), "wb")
check(wb and wb[-1]["b"] == 500 and wb[-1]["n"] == 60 and {"chunks", "map", "reqs", "radars", "techs"} <= set(wb[-1]["q"]),
      f"wb once a second: the budget, the units used and the queues: {wb[-1:]}")
# Periodic jobs share the tick (budget.admit): one waits while the tick already holds more than
# PERIODIC budgets' worth, runs once its slack runs out, and its expected cost follows what it read.
B = g.package.loaded["scripts.budget"]
B.set(lua.table_from({"u": 300}))
B.begin()
B.commit(560, "bi")
check(not B.admit("probe", 100), "a periodic job waits when the tick is full")
check(B.admit("probe", 100, True), "and runs when its slack is out")
B.learn("probe", 200)
check(B.estimate("probe") == 200, f"its first run sets what it is expected to cost: {B.estimate('probe')}")
B.learn("probe", 100)
check(B.estimate("probe") == 170, f"and later runs move it there: {B.estimate('probe')}")
B.begin()
B.commit(100, "bi")
check(B.admit("probe", 100) and B.left() == 300, "on a light tick it runs, and the queues keep their whole budget")
B.begin()
B.commit(50, "bi")
g.storage.f3d.bud.cost["huge"] = 5000
check(B.admit("huge", 0), "a job dearer than a whole tick runs on a tick that holds little")
B.set(lua.table_from({"u": 500}))
# The movers' search while the focus moves: again after SCAN_MOVE tiles, through the budget; at once
# after a jump.
fx0, fy0, fr0 = g.storage.f3d.focus.x, g.storage.f3d.focus.y, g.storage.f3d.focus.r
def focus_at(x):
    send({"t": "focus", "x": fixed(x), "y": fixed(fy0), "r": fr0})
focus_at(fx0)
tick(20)
# Line up just after a periodic search (every SCAN_TICKS, 8), so the two ticks below can't reach the
# next one whatever tick this part starts on (a test added earlier shifted it onto one).
last = g.storage.f3d.mv_scan.tick
for _ in range(20):
    tick(1)
    if g.storage.f3d.mv_scan.tick != last:
        break
first = g.storage.f3d.mv_scan.tick
focus_at(fx0 + 1)
tick(2)
check(g.storage.f3d.mv_scan.tick == first, "a step of the focus doesn't search the movers' area again")
focus_at(fx0 + 60)
tick(3)
check(g.storage.f3d.mv_scan.tick > first and g.storage.f3d.mv_scan.x == fx0 + 60,
      f"a jump searches it at once: {g.storage.f3d.mv_scan.x} for {fx0 + 60}")
# perfbridge2: while searches keep finding the same movers the ticks between them double, up to the
# f3d-mover-rescan setting (8: every 8 ticks, as before); a search that finds anything else goes back to 8.
g.settings["global"]["f3d-mover-rescan"] = lua.table_from({"value": 32})
movers_mod = g.package.loaded["scripts.movers"]
movers_mod.reset()
every, gaps, last = [], [], None
for _ in range(140):
    tick(1)
    t = int(g.storage.f3d.mv_scan.tick)
    if t != last:
        if last is not None:
            gaps.append(t - last)
        every.append(int(g.storage.f3d.mv_scan.every))
        last = t
check(every[:4] == [8, 16, 32, 32] and gaps[:3] == [8, 16, 32] and max(gaps) <= 32,
      f"movers: searches finding the same movers come 8, 16, then 32 ticks apart (f3d-mover-rescan 32): every {every[:5]}, gaps {gaps[:5]}")
newcomer = spawn("car", fx0 + 20, fy0 + 10, force="player")
for _ in range(40):
    tick(1)
    if int(g.storage.f3d.mv_scan.tick) != last:
        break
check(int(g.storage.f3d.mv_scan.every) == 8 and any(rec[0] == newcomer.unit_number for m in of_type(take(), "mv") for rec in m["l"]),
      f"movers: a search that finds a new mover sends it and puts the searches back to every 8 ticks: {g.storage.f3d.mv_scan.every}")
newcomer.destroy()
g.settings["global"]["f3d-mover-rescan"] = lua.table_from({"value": 8})
movers_mod.reset()
last = None
every = set()
for _ in range(40):
    tick(1)
    if g.storage.f3d.mv_scan:
        every.add(int(g.storage.f3d.mv_scan.every))
check(every == {8}, f"movers: f3d-mover-rescan 8 searches every 8 ticks, as before: {every}")
# Multiplayer: what sending the movers charges the tick (budget.commit, which decides which periodic
# jobs run) is the search's count in storage, not the module-local list: a peer that loaded since
# finds its own, later, which may hold a mover more.
# (Just after a search, so the ticks below reach no other.)
last = g.storage.f3d.mv_scan.tick
for _ in range(20):
    tick(1)
    if g.storage.f3d.mv_scan.tick != last:
        break
scan_tick = g.storage.f3d.mv_scan.tick
late_cars = [spawn("car", fx0 + 62, fy0 + dy, force="player") for dy in (0, 3)]
tick(1)
while int(g.game.tick) % 2 != 1:  # the movers' ticks (rate.lua's phase 1 at a 2-tick interval)
    tick(1)
mv_host = g.storage.f3d.bud.jobs.mv
check(forget(movers_mod.tick, "scans"), "the movers' module-local list can be forgotten (a peer that loaded since)")
tick(2)
mv_joined = g.storage.f3d.bud.jobs.mv
check(g.storage.f3d.mv_scan.tick == scan_tick and mv_host == mv_joined,
      f"mv: a send is charged the same on a peer whose own list has two cars more: {mv_host} and {mv_joined}")
mv_n = g.storage.f3d.mv_scan.n
check(mv_n is not None and mv_host == math.floor(mv_n * 0.5),
      f"mv: by the search's count in storage: {mv_host} for {g.storage.f3d.mv_scan.n} movers")
for e in late_cars:
    e.destroy()
focus_at(fx0)
tick(3)
# Every job with a slack says what it read, so its cost is learned and its charge cleared: enemies,
# items on the ground and robots' cargo stayed at their first guess.
for job in ("en", "gi", "rc"):
    g.storage.f3d.bud.cost[job] = None
tick(130)
learned = {job: g.storage.f3d.bud.cost[job] for job in ("en", "gi", "rc")}
check(None not in learned.values() and not any(g.storage.f3d.bud.charged[job] for job in learned),
      f"enemies, ground items and robots' cargo learn what they cost and clear their charge: {learned}")
# The checks below count on the tick staying in step: on to a whole number of 600 ticks.
pad = -(g.game.tick - start_tick) % 600
while pad > 0:
    send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
    tick(min(pad, 100))
    pad -= min(pad, 100)
take()

# D5: a chart is kept while its chunk looks the same, and made again once something is built there.
keep = spawn("stone-wall", 28.5, 28.5, force="player")
send({"t": "map", "cx1": 0, "cy1": 0, "cx2": 0, "cy2": 0, "res": 2})
tick(2)
take()
keep.destroy()
chest = spawn("wooden-chest", 28.5, 28.5, force="player")  # as many entities, and no event
send({"t": "map", "cx1": 0, "cy1": 0, "cx2": 0, "cy2": 0, "res": 2})
tick(2)
kept = [m for m in of_type(take(), "chart") if (m["cx"], m["cy"]) == (0, 0)]
check(kept and kept[0]["pal"][kept[0]["px"][14 * 16 + 14]] == [204, 217, 204],
      "a chunk with as many entities and no event since is sent from its kept chart (D5)")
F["raise"]("script_raised_built", lua.table_from({"entity": chest}))
take()
send({"t": "map", "cx1": 0, "cy1": 0, "cx2": 0, "cy2": 0, "res": 2})
tick(2)
redone = [m for m in of_type(take(), "chart") if (m["cx"], m["cy"]) == (0, 0)]
check(redone and redone[0]["pal"][redone[0]["px"][14 * 16 + 14]] != [204, 217, 204],
      "... and charted again once something is built in it")
chest.destroy()
# perfbridge2: a chart younger than map.chart_trust ticks of a chunk nothing was built, mined or destroyed in
# since (an event) is trusted: its entities aren't counted again (the count was most of a minimap refresh's
# cost). The counts live in storage.f3d_charts, forgotten by the events, so every peer slices the job alike.
counted = []
lua.execute("""
local surface = game.surfaces[1]
F.real_count = surface.count_entities_filtered
-- (Only the charts' counts, made at a chart job's first step; world.lua's snapshots count the same way.)
rawset(surface, "count_entities_filtered", function(f)
  local m = storage.f3d and storage.f3d.map
  if m and m.job and m.job.step == -1 then
    F.counted = (F.counted or 0) + 1
  end
  return F.real_count(f)
end)
""")
def map_count_calls(res=2):
    g.F.counted = 0
    send({"t": "map", "cx1": 0, "cy1": 0, "cx2": 0, "cy2": 0, "res": res})
    tick(2)
    take()
    return int(g.F.counted)
g.storage.f3d_charts = None  # (the charts above remembered theirs)
first_count = map_count_calls()
trusted = map_count_calls()
rec = g.storage.f3d_charts and g.storage.f3d_charts[f"1,0,0,2"]
check(first_count == 1 and trusted == 0 and rec is not None and rec[3] == "player",
      f"map: a chunk's entity count is remembered in storage and trusted for a young chart: {first_count}, {trusted}, {rec and list(rec.values())}")
quiet_chest = spawn("wooden-chest", 28.5, 28.5, force="player")
F["raise"]("script_raised_built", lua.table_from({"entity": quiet_chest}))
check(g.storage.f3d_charts["1,0,0,2"] is None and map_count_calls() == 1, "map: something built in the chunk forgets the trusted count, and it is counted again")
g.package.loaded["scripts.map"].chart_trust = 0
check(map_count_calls() == 1, "map: chart_trust 0 counts every time, as before")
g.package.loaded["scripts.map"].chart_trust = 1200
quiet_chest.destroy()
lua.execute('rawset(game.surfaces[1], "count_entities_filtered", F.real_count)')

# The map view's layers ride with the chart: poles, turrets, roboports, stops, signals, robots.
layer_ents = [spawn("small-electric-pole", 20.5, 20.5, force="player"), spawn("gun-turret", 22, 22, force="player"),
              spawn("roboport", 26, 26, force="player"), spawn("train-stop", 16, 16, force="player", backer_name="Iron"),
              spawn("rail-signal", 12.5, 12.5, force="player"), spawn("construction-robot", 10.5, 10.5, force="player"),
              spawn("gun-turret", 6, 6, force="enemy"), spawn("small-electric-pole", 40.5, 20.5, force="player")]
# (The overlay's robots are the movers' last search's (perfbridge2): search again now.)
movers_mod.reset()
tick(2)
send({"t": "map", "cx1": 0, "cy1": 0, "cx2": 0, "cy2": 0, "res": 4})
tick(2)
c00 = [m for m in of_type(take(), "chart") if (m["cx"], m["cy"]) == (0, 0)]
ov = sorted(c00[0].get("ov", []), key=lambda r: r[0]) if c00 else []
check(["e", fixed(20.5), fixed(20.5), 2.5] in ov, f"a pole comes with its supply radius: {ov}")
check(["t", fixed(22), fixed(22), 18] in ov, "a turret with its range")
check(["l", fixed(26), fixed(26), 25, 55] in ov, "a roboport with its logistic and construction radius")
check(["s", fixed(16), fixed(16), "Iron"] in ov, "a train stop with its name")
check(["g", fixed(12.5), fixed(12.5), 1] in ov, "a rail signal with its state")
check(["b", fixed(10.5), fixed(10.5)] in ov, "a worker robot")
check(len(ov) == 6, "nothing of other forces, nothing from the next chunk")
# Owner's C10: the copper wires between poles, each once.
wired = spawn("small-electric-pole", 25.5, 20.5, force="player")
# (Built: its event forgets the chunk's chart and trusted count, as in the game; the fake's spawn is silent.)
F["raise"]("script_raised_built", lua.table_from({"entity": wired}))
layer_ents[0].get_wire_connector(5, True).connect_to(wired.get_wire_connector(5, True))
send({"t": "map", "cx1": 0, "cy1": 0, "cx2": 0, "cy2": 0, "res": 4})
tick(2)
c00 = [m for m in of_type(take(), "chart") if (m["cx"], m["cy"]) == (0, 0)]
wires = [r for r in (c00[0].get("ov", []) if c00 else []) if r[0] == "w"]
check(wires == [["w", fixed(20.5), fixed(20.5), fixed(25.5), fixed(20.5)]], f"a copper wire between two poles, once (C10): {wires}")
layer_ents.append(wired)
for e in layer_ents:
    e.destroy()

# Owner's C12: a chart carries its chunk's pollution.
F.pollution = lua.eval('{["0,0"] = 1234.4}')
send({"t": "map", "cx1": 0, "cy1": 0, "cx2": 1, "cy2": 0, "res": 32})
tick(2)
pols = {(m["cx"], m["cy"]): m.get("pol") for m in of_type(take(), "chart")}
check(pols.get((0, 0)) == 1234 and pols.get((1, 0)) is None, f"charts carry their chunk's pollution (pol), none where there is none: {pols}")
F.pollution = lua.eval("{}")

# Owner's I15: the chunks' pollution round the focus, every 300 ticks (pollution.lua), for trees, lakes and smog.
pol_focus = g.storage.f3d.focus
pol_cx, pol_cy = math.floor(pol_focus.x / 32), math.floor(pol_focus.y / 32)
F.pollution = lua.eval('{["%d,%d"] = 250.4, ["%d,%d"] = 12}' % (pol_cx, pol_cy, pol_cx + 1, pol_cy))
take()


def pol_wait():
    # 600 ticks, saying hello as the padding above does, so the client isn't timed out meanwhile.
    for _ in range(6):
        send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
        tick(100)


pol_wait()
pol = of_type(take(), "pol")
pol_w = pol[-1]["w"] if pol else 0
pol_n = (pol_w - 1) // 2
pol_l = pol[-1]["l"] if pol and pol_w > 0 else []
check(pol and pol_w > 0 and pol[-1]["cx"] == pol_cx - pol_n and pol[-1]["cy"] == pol_cy - pol_n and pol[-1]["md"] == 60
      and pol_l[pol_n * pol_w + pol_n] == 250 and pol_l[pol_n * pol_w + pol_n + 1] == 12 and sum(pol_l) == 262,
      f"pol: the chunks' pollution round the focus, row by row, with the tree damage threshold: {pol[-1:]}")
F.pollution = lua.eval("{}")
pol_wait()
pol = of_type(take(), "pol")
check(pol and pol[-1]["w"] == 0 and "l" not in pol[-1], f"pol: none left round the focus sends an empty square: {pol[-1:]}")

# Distant Horizon LOD (lod.lua, world.lua lod_revs, map.chunk_charted):
# 1. hello / welcome capability negotiation.
dh_old_subs = [[int(c[1]), int(c[2])] for c in g.storage.f3d.subs.values()]
lua.execute("F_dh_orig_c = {}; for k, v in pairs(F.charted) do F_dh_orig_c[k] = v end")
send({"t": "hello", "v": 1, "sid": "dh-nolod", "w": 0})
tick(1)
wel_nolod = of_type(take(), "welcome")
check(wel_nolod and "lod" not in wel_nolod[-1] and not g.storage.f3d.client.lod,
      f"dh: welcome omits lod when hello didn't ask: {wel_nolod[-1:]}")
send({"t": "hello", "v": 1, "sid": "s1", "w": 0, "lod": 1})
tick(10)
wel_lod = of_type(take(), "welcome")
check(wel_lod and wel_lod[-1].get("lod") == 1 and g.storage.f3d.client.lod == True,
      f"dh: welcome carries lod=1 when hello asked: {wel_lod[-1:]}")
send({"t": "hello", "v": 1, "sid": "s1", "w": 1, "lod": "bad"})
tick(1)
check(not g.storage.f3d.client.lod, "dh: bad hello.lod does not enable lod")
send({"t": "hello", "v": 1, "sid": "s1", "w": 1, "lod": 1})
tick(60)
wb_lod = of_type(take(), "wb")
check(wb_lod and "lod" in wb_lod[-1]["q"], f"dh: budget queue 'lod' reported in wb: {wb_lod[-1:]}")

# 2. world.lua region revision bumps & REGION = 16.
W_MOD = g.package.loaded["scripts.world"]
check(int(W_MOD.REGION) == 16, f"dh: world.REGION is 16: {W_MOD.REGION}")
r00_0 = int(W_MOD.region_rev(1, 0, 0))
rn1_0 = int(W_MOD.region_rev(1, -1, -1))
W_MOD.bump(1, lua.table_from({"x": 16, "y": 16}))
check(int(W_MOD.region_rev(1, 0, 0)) == r00_0 + 1 and int(W_MOD.region_rev(1, -1, -1)) == rn1_0,
      "dh: world.bump increments only touched region away from border")
W_MOD.bump(1, lua.table_from({"x": 0.5, "y": 0.5}))
check(int(W_MOD.region_rev(1, 0, 0)) == r00_0 + 2 and int(W_MOD.region_rev(1, -1, -1)) == rn1_0 + 1
      and int(W_MOD.all_region_revs(1)["0,0"]) == r00_0 + 2,
      "dh: chunk-corner bump increments each touched region once")

# 3. lod_sub map / revs / uncharted omission / invalid surface / empty charted map.
F.charted["-3,-3"] = None
if g.storage.f3d.explored and g.storage.f3d.explored[1] and g.storage.f3d.explored[1][-3]:
    saved_exp_n3 = g.storage.f3d.explored[1][-3][-3]
    g.storage.f3d.explored[1][-3][-3] = None
else:
    saved_exp_n3 = None
F.charted["0,0"] = True
F.charted["1,0"] = True
F.charted["-1,0"] = True
take()
send({"t": "lod_sub", "si": 1, "q": 41, "act": "map"})
tick(2)
msgs = take()
lodms = of_type(msgs, "lodm")
lodrs = of_type(msgs, "lodr")
charted_got = {(int(r[0]) + i, int(r[1])) for m in lodms for row in m["w"]
               for j in range(1, len(row), 2) for i in range(row[j + 1])
               for r in [(row[j], row[0])]}
check(lodms and lodms[0]["q"] == 41 and lodms[0]["part"] == 1 and {(0, 0), (1, 0), (-1, 0)} <= charted_got
      and (-3, -3) not in charted_got,
      f"dh: lodm returns charted chunks sorted without uncharted ones: {len(charted_got)}")
flat_r = [v for m in lodrs for v in m["l"]]
triples_r = {(flat_r[i], flat_r[i + 1]): flat_r[i + 2] for i in range(0, len(flat_r), 3)}
check(lodrs and lodrs[0]["q"] == 41 and triples_r.get((0, 0)) == r00_0 + 2 and triples_r.get((-1, -1)) == rn1_0 + 1
      and all(v > 0 for v in triples_r.values()),
      f"dh: map lodr returns all non-zero region revs: {triples_r}")
send({"t": "lod_sub", "si": 999, "q": 42, "act": "map"})
tick(2)
check(not of_type(take(), "lodm"), "dh: unknown surface si is ignored cleanly")
send({"t": "lod_sub", "q": 43, "act": "map"})
tick(2)
fallback_m = of_type(take(), "lodm")
check(fallback_m and fallback_m[-1]["si"] == 1 and fallback_m[-1]["q"] == 43, "dh: missing si falls back to world.surface()")

# A save loaded (or a peer joining) mid-scan has the job in storage but no module-local iterator. The scan
# must not reset storage from that module state: rows already in `storage` stay, the new iterator skips the
# `job.scanned` chunks they cover, and the lodm that follows is the same on every peer. (-3,-3) is uncharted, so
# only the stored partial row can put it in the answer; the old code wiped the rows and lost it.
take()
lua.execute("""
  storage.f3d.lod.map_job = { si = 1, q = 45, rows = { [-3] = { -3 } }, scanned = 3, pages = nil, rev_pages = nil, idx = 1, rev_idx = 1 }
""")
tick(2)
resumed = of_type(take(), "lodm")
resumed_got = {(int(r[0]) + i, int(r[1])) for m in resumed for row in m["w"]
               for j in range(1, len(row), 2) for i in range(row[j + 1])
               for r in [(row[j], row[0])]}
check(resumed and resumed[0]["q"] == 45 and (-3, -3) in resumed_got and {(0, 0), (1, 0), (-1, 0)} <= resumed_got
      and g.storage.f3d.lod.map_job is None,
      f"dh: a map scan resumed without its module iterator keeps the rows in storage (save/load mid-scan): {sorted(resumed_got)[:6]}")

# A resume with a large `scanned` skips its covered chunks a slice a tick: no tick makes more iterator
# calls than the scan budget (MAP_SCAN_PER_TICK, 1024), and the job still finishes with the same lodm.
take()
lua.execute("""
  F_skip_calls, F_skip_max = 0, 0
  F_skip_orig = game.get_surface(1).get_chunks
  game.get_surface(1).get_chunks = function()
    local i = 0
    return function()
      i = i + 1
      F_skip_calls = F_skip_calls + 1
      if i > 5000 then return nil end
      return { x = 200 + i % 100, y = 200 + math.floor(i / 100) }
    end
  end
  storage.f3d.lod.map_job = { si = 1, q = 46, rows = {}, scanned = 3500, pages = nil, rev_pages = nil, idx = 1, rev_idx = 1 }
""")
skip_max = 0
for _ in range(12):
    lua.execute("F_skip_calls = 0")
    tick(1)
    skip_max = max(skip_max, int(lua.eval("F_skip_calls")))
skip_done = of_type(take(), "lodm")
lua.execute("game.get_surface(1).get_chunks = F_skip_orig; F_skip_orig = nil")
check(skip_max <= 1024 and skip_done and skip_done[0]["q"] == 46 and g.storage.f3d.lod.map_job is None,
      f"dh: a resumed scan with scanned=3500 skips in slices (max iterator calls per tick {skip_max} <= 1024) and finishes")

# Empty charted set produces 1 part with w == [].
lua.execute("F_dh_saved_c, F_dh_saved_e = F.charted, storage.f3d.explored; F.charted = {}; storage.f3d.explored = nil")
send({"t": "lod_sub", "si": 1, "q": 44, "act": "map"})
tick(2)
empty_m = of_type(take(), "lodm")
check(len(empty_m) == 1 and empty_m[0]["part"] == 1 and empty_m[0]["parts"] == 1 and empty_m[0]["w"] == [],
      f"dh: empty charted surface yields 1 lodm part with w=[]: {empty_m}")
lua.execute("F.charted, storage.f3d.explored = F_dh_saved_c, F_dh_saved_e; F_dh_saved_c, F_dh_saved_e = nil, nil")

# 4. revs checks mismatch filtering and exact match empty answer.
r00_cur = int(W_MOD.region_rev(1, 0, 0))
rn1_cur = int(W_MOD.region_rev(1, -1, -1))
send({"t": "lod_sub", "si": 1, "q": 51, "act": "revs", "rg": [[0, 0, r00_cur], [-1, -1, 0], [5, 5, 0]]})
tick(1)
rev_diff = of_type(take(), "lodr")
check(len(rev_diff) == 1 and rev_diff[0]["q"] == 51 and rev_diff[0]["l"] == [-1, -1, rn1_cur],
      f"dh: revs returns only differing regions: {rev_diff}")
send({"t": "lod_sub", "si": 1, "q": 52, "act": "revs", "rg": [[0, 0, r00_cur], [-1, -1, rn1_cur], [5, 5, 0]]})
tick(1)
rev_same = of_type(take(), "lodr")
check(len(rev_same) == 1 and rev_same[0]["q"] == 52 and rev_same[0]["l"] == [],
      f"dh: revs returns empty list when all match: {rev_same}")

# Pagination under ~30 KB when many non-zero region revs exist:
lua.execute("""
F_dh_saved_revs = storage.f3d.lod_revs[1]
storage.f3d.lod_revs[1] = {}
for i = 1, 2600 do
  storage.f3d.lod_revs[1][(i + 100) .. ",200"] = 1000000 + i
end
""")
send({"t": "lod_sub", "si": 1, "q": 53, "act": "map"})
tick(3)
paged_lodr = of_type(take(), "lodr")
check(len(paged_lodr) >= 2 and sum(len(m["l"]) for m in paged_lodr) == 2600 * 3
      and all(len(json.dumps(m, separators=(",", ":"))) < 30000 for m in paged_lodr),
      f"dh: large lodr paginates across multiple packets under 30 KB: {len(paged_lodr)} parts")
lua.execute("storage.f3d.lod_revs[1] = F_dh_saved_revs; F_dh_saved_revs = nil")

# 5. on_chunk_charted & on_chunk_deleted events bump region_rev and invalidate cached map state.
g.storage.f3d.lod.map_dirty = False
F["raise"]("on_chunk_charted", lua.table_from({"surface_index": 1, "position": {"x": 2, "y": 3}, "force": g.game.forces.player}, recursive=True))
check(int(W_MOD.region_rev(1, 0, 0)) == r00_cur + 1 and g.storage.f3d.lod.map_dirty is True,
      "dh: on_chunk_charted bumps region rev and invalidates map state")
r10_before = int(W_MOD.region_rev(1, 1, 0))
F["raise"]("on_chunk_deleted", lua.table_from({"surface_index": 1, "positions": [{"x": 16, "y": 0}, {"x": 17, "y": 0}]}, recursive=True))
check(int(W_MOD.region_rev(1, 1, 0)) == r10_before + 1,
      "dh: on_chunk_deleted deduplicates and bumps region rev")
take()

# 6. want sampling across all 5 resolutions, flags (density/glow/cat), uncharted/ungenerated none, zero generate calls.
F.chunk_generate_requests = 0
dh_ents = [
    spawn("small-lamp", 3.5, 3.5, force="player"),
    spawn("stone-furnace", 11.0, 3.0, force="player"),
    spawn("tree-01", 19.5, 3.5, force="neutral"),
    spawn("iron-ore", 27.5, 3.5, force="neutral"),
    spawn("transport-belt", 3.5, 11.5, force="player"),
    spawn("assembling-machine-1", 11.5, 11.5, force="player"),
]
def expand_lod_cells(msg):
    n = 32 // msg["res"]
    tiles, ents = [], []
    tl, el = msg["tl"], msg["el"]
    for i in range(0, len(tl), 2):
        tiles.extend([tl[i]] * tl[i + 1])
    for i in range(0, len(el), 3):
        ents.extend([(el[i], el[i + 1])] * el[i + 2])
    check(len(tiles) == n * n and len(ents) == n * n, f"dh: res {msg['res']} expands to {n*n} cells")
    return n, tiles, ents

for res_v in (32, 16, 8, 4, 2):
    send({"t": "lod_sub", "si": 1, "res": res_v, "act": "want", "c": [[0, 0], [-3, -3], [9, 9]]})
    got_lods = {}
    for _ in range(30):
        tick(1)
        for m in of_type(take(), "lod"):
            got_lods[(m["cx"], m["cy"], m["res"])] = m
        if len(got_lods) >= 3:
            break
    check((-3, -3, res_v) in got_lods and got_lods[(-3, -3, res_v)].get("none") == 1,
          f"dh: uncharted generated chunk returns none=1 at res {res_v}")
    check((9, 9, res_v) in got_lods and got_lods[(9, 9, res_v)].get("none") == 1,
          f"dh: ungenerated chunk returns none=1 at res {res_v}")
    m0 = got_lods.get((0, 0, res_v))
    check(m0 and "none" not in m0, f"dh: chunk (0,0) sampled at res {res_v}")
    if m0 and "none" not in m0:
        n, tiles, ents = expand_lod_cells(m0)
        if res_v == 8:
            lamp_p, lamp_f = ents[0 * n + 0]
            tree_p, tree_f = ents[0 * n + 2]
            ore_p, ore_f = ents[0 * n + 3]
            check(lamp_p > 0 and ((lamp_f >> 4) & 3) == 3 and ((lamp_f >> 6) & 3) == 1 and (lamp_f & 15) >= 1,
                  f"dh: res=8 macro cell picks lamp with glow=3 cat=1: {(lamp_p, lamp_f)}")
            check(tree_p > 0 and ((tree_f >> 6) & 3) == 2, f"dh: res=8 macro cell picks tree cat=2: {(tree_p, tree_f)}")
            check(ore_p > 0 and ((ore_f >> 6) & 3) == 3, f"dh: res=8 macro cell picks ore cat=3: {(ore_p, ore_f)}")
        elif res_v == 2:
            lp, lf = ents[1 * n + 1]
            ap, af = ents[5 * n + 5]
            bp, bf = ents[5 * n + 1]
            check(lp > 0 and ((lf >> 4) & 3) == 3 and ((lf >> 6) & 3) == 1, f"dh: res=2 fine cell lamp glow=3: {(lp, lf)}")
            check(ap > 0 and ((af >> 6) & 3) == 1 and (af & 15) >= 10, f"dh: res=2 fine cell assembler dense: {(ap, af)}")
            check(bp > 0 and ((bf >> 6) & 3) == 3, f"dh: res=2 fine cell belt cat=3: {(bp, bf)}")

# Empty charted chunk fast exit (pick an empty chunk in -3..3):
empty_cx, empty_cy = lua.eval("""function()
  local s = game.surfaces[1]
  local ex = package.loaded["scripts.registry"].excluded_types()
  for cy = 2, 3 do
    for cx = 2, 3 do
      local n = s.count_entities_filtered({area = {{cx*32, cy*32}, {cx*32+32, cy*32+32}}, type = ex, invert = true, limit = 1})
      if n == 0 then return cx, cy end
    end
  end
  return nil, nil
end""")()
check(empty_cx is not None, "dh: found an empty chunk in test map")
F.charted[f"{empty_cx},{empty_cy}"] = True
send({"t": "lod_sub", "si": 1, "res": 8, "act": "want", "c": [[empty_cx, empty_cy]]})
tick(2)
m_empty = [m for m in of_type(take(), "lod") if (m["cx"], m["cy"]) == (empty_cx, empty_cy)]
check(m_empty and m_empty[0]["el"] == [0, 0, 16], f"dh: empty charted chunk produces single empty el RLE: {m_empty}")

# Fish filtering, rail vs signal priority, and restricted night glow (Step 1):
ex0, ey0 = empty_cx * 32, empty_cy * 32
reg_ents = [
    spawn("fish", ex0 + 2.0, ey0 + 2.0, force="neutral"),
    spawn("straight-rail", ex0 + 18.0, ey0 + 17.5, force="player"),
    spawn("rail-signal", ex0 + 18.0, ey0 + 17.5, force="player"),
    spawn("rail-signal", ex0 + 21.5, ey0 + 17.5, force="player"),
    spawn("assembling-machine-1", ex0 + 25.5, ey0 + 17.5, force="player"),
    spawn("laser-turret", ex0 + 29.5, ey0 + 17.5, force="player"),
    spawn("beacon", ex0 + 17.5, ey0 + 25.5, force="player"),
    spawn("stone-furnace", ex0 + 5.5, ey0 + 25.5, force="player"),
    spawn("nuclear-reactor", ex0 + 26.0, ey0 + 26.0, force="player"),
    spawn("small-lamp", ex0 + 1.5, ey0 + 25.5, force="player"),
]
send({"t": "lod_sub", "si": 1, "res": 16, "act": "want", "c": [[empty_cx, empty_cy]]})
tick(3)
m_r16 = [m for m in of_type(take(), "lod") if (m["cx"], m["cy"], m["res"]) == (empty_cx, empty_cy, 16)]
check(m_r16 and expand_lod_cells(m_r16[0])[2][0][0] == 0, f"dh: fish skipped in res=16 macro LOD: {m_r16}")
send({"t": "lod_sub", "si": 1, "res": 4, "act": "want", "c": [[empty_cx, empty_cy]]})
m_r4 = None
for _ in range(20):
    tick(1)
    for m in of_type(take(), "lod"):
        if (m["cx"], m["cy"], m["res"]) == (empty_cx, empty_cy, 4):
            m_r4 = m
    if m_r4:
        break
check(m_r4 is not None, "dh: res=4 regression chunk sampled")
if m_r4 is not None:
    _, _, e4 = expand_lod_cells(m_r4)
    check(e4[0][0] == 0, f"dh: fish skipped in res=4 fine LOD: {e4[0]}")
    check(e4[4 * 8 + 4][0] == pid["straight-rail"] and ((e4[4 * 8 + 4][1] >> 4) & 3) == 0,
          f"dh: straight-rail beats rail-signal with glow=0: {e4[4 * 8 + 4]}")
    check(e4[4 * 8 + 5][0] == pid["rail-signal"] and ((e4[4 * 8 + 5][1] >> 4) & 3) == 0,
          f"dh: rail-signal glow=0: {e4[4 * 8 + 5]}")
    check(e4[4 * 8 + 6][0] == pid["assembling-machine-1"] and ((e4[4 * 8 + 6][1] >> 4) & 3) == 0,
          f"dh: assembling-machine glow=0: {e4[4 * 8 + 6]}")
    check(e4[4 * 8 + 7][0] == pid["laser-turret"] and ((e4[4 * 8 + 7][1] >> 4) & 3) == 0,
          f"dh: electric-turret glow=0: {e4[4 * 8 + 7]}")
    check(e4[6 * 8 + 4][0] == pid["beacon"] and ((e4[6 * 8 + 4][1] >> 4) & 3) == 0,
          f"dh: beacon glow=0: {e4[6 * 8 + 4]}")
    check(e4[6 * 8 + 1][0] == pid["stone-furnace"] and ((e4[6 * 8 + 1][1] >> 4) & 3) == 1,
          f"dh: stone-furnace glow=1: {e4[6 * 8 + 1]}")
    check(e4[6 * 8 + 6][0] == pid["nuclear-reactor"] and ((e4[6 * 8 + 6][1] >> 4) & 3) == 2,
          f"dh: nuclear-reactor glow=2: {e4[6 * 8 + 6]}")
    check(e4[6 * 8 + 0][0] == pid["small-lamp"] and ((e4[6 * 8 + 0][1] >> 4) & 3) == 3,
          f"dh: small-lamp glow=3: {e4[6 * 8 + 0]}")
for e in reg_ents:
    e.destroy()
tick(1)
take()

# Fine strip slicing under budget on dense chunk (-2, 0) + stop & replace:
F.charted["-2,0"] = True
dense_lod = [spawn("stone-wall", -63.5 + (i % 16) * 2, 0.5 + (i // 16) * 2, force="player") for i in range(180)]
send({"t": "budget", "u": 60})
tick(1)
take()
send({"t": "lod_sub", "si": 1, "res": 2, "act": "want", "c": [[-2, 0], [1, 0], [0, 0]]})
got_dense = None
ticks_dense = 0
while got_dense is None and ticks_dense < 40:
    tick(1)
    ticks_dense += 1
    for m in of_type(take(), "lod"):
        if (m["cx"], m["cy"]) == (-2, 0):
            got_dense = m
check(got_dense and ticks_dense >= 2 and sum(got_dense["el"][2::3]) == 256,
      f"dh: dense res=2 chunk slices over multiple ticks under budget: {ticks_dense} ticks")
send({"t": "lod_sub", "act": "stop"})
tick(5)
check(not of_type(take(), "lod") and g.package.loaded["scripts.lod"].queue_length() == 0,
      "dh: stop clears pending LOD queue and active job")
send({"t": "budget", "u": 500})
tick(1)

# Malformed lod_sub fuzz resilience & request_to_generate_chunks == 0:
bad_huge_c = [[i, 0] for i in range(300)]
for bad in (
    {"t": "lod_sub", "act": "bogus"},
    {"t": "lod_sub", "act": "revs", "si": "nan", "rg": "bad"},
    {"t": "lod_sub", "act": "revs", "rg": [["x", 0, 1], [10**9, 0, 1], [0, 0, "nan"]]},
    {"t": "lod_sub", "act": "want", "res": 7, "c": [["nan", 0], bad_huge_c[0]]},
    {"t": "lod_sub", "act": "want", "res": 32, "c": bad_huge_c},
):
    send(bad)
check(len(g.storage.f3d.lod.queue) <= 256, "dh: want list capped at 256 chunks")
send({"t": "lod_sub", "act": "stop"})
tick(2)
take()
check(int(F.chunk_generate_requests or 0) == 0, f"dh: request_to_generate_chunks never called ({F.chunk_generate_requests})")

# 7. Multi-page lodm pagination (>30 KB row-runs), res=4 strip slicing, low-budget non-starvation, and bye reset:
lua.execute("""
F_dh_saved_get_chunks = game.surfaces[1].get_chunks
F_dh_saved_charted = F.charted
local big_chunks = {}
local big_charted = {}
for cy = -300, 299 do
  for cx = 0, 20, 2 do
    big_chunks[#big_chunks + 1] = { x = cx, y = cy }
    big_charted[cx .. "," .. cy] = true
  end
end
F.charted = big_charted
game.surfaces[1].get_chunks = function()
  local i = 0
  return function()
    i = i + 1
    return big_chunks[i]
  end
end
""")
send({"t": "lod_sub", "si": 1, "q": 61, "act": "map"})
paged_lodms = []
for _ in range(10):
    tick(1)
    paged_lodms.extend(of_type(take(), "lodm"))
    if paged_lodms and len({m["part"] for m in paged_lodms}) >= paged_lodms[0]["parts"]:
        break
check(len(paged_lodms) >= 2 and paged_lodms[0]["parts"] >= 2
      and all(len(json.dumps(m, separators=(",", ":"))) < 30000 for m in paged_lodms)
      and sorted(m["part"] for m in paged_lodms) == list(range(1, paged_lodms[0]["parts"] + 1)),
      f"dh: large lodm paginates cleanly across {len(paged_lodms)} parts under 30 KB")
lua.execute("game.surfaces[1].get_chunks = F_dh_saved_get_chunks; F.charted = F_dh_saved_charted; F_dh_saved_get_chunks = nil; F_dh_saved_charted = nil")

# res=4 multi-strip slicing + determinism check across repeated wants + low-budget non-starvation:
F.charted["-2,0"] = True
extra_r4_walls = [spawn("stone-wall", -63.0 + (i % 16) * 2, 1.5 + (i // 16) * 2, force="player") for i in range(160)]
send({"t": "budget", "u": 50})
tick(1)
take()
send({"t": "lod_sub", "si": 1, "res": 4, "act": "want", "c": [[-2, 0]]})
got_r4_1 = None
ticks_r4 = 0
while got_r4_1 is None and ticks_r4 < 40:
    tick(1)
    ticks_r4 += 1
    for m in of_type(take(), "lod"):
        if (m["cx"], m["cy"], m["res"]) == (-2, 0, 4):
            got_r4_1 = m
send({"t": "lod_sub", "si": 1, "res": 4, "act": "want", "c": [[-2, 0]]})
got_r4_2 = None
for _ in range(40):
    tick(1)
    for m in of_type(take(), "lod"):
        if (m["cx"], m["cy"], m["res"]) == (-2, 0, 4):
            got_r4_2 = m
    if got_r4_2 is not None:
        break
for e in extra_r4_walls:
    e.destroy()
check(got_r4_1 is not None and got_r4_2 is not None and ticks_r4 >= 2
      and got_r4_1["tl"] == got_r4_2["tl"] and got_r4_1["el"] == got_r4_2["el"]
      and sum(got_r4_1["el"][2::3]) == 64,
      f"dh: res=4 strip slicing is deterministic and finishes at budget=50 ({ticks_r4} ticks)")

# bye resets active LOD queue/job without erasing world.lod_revs:
rev_before_bye = int(W_MOD.region_rev(1, 0, 0))
send({"t": "lod_sub", "si": 1, "res": 2, "act": "want", "c": [[-2, 0], [0, 0]]})
tick(1)
send({"t": "bye"})
tick(1)
check(g.package.loaded["scripts.lod"].queue_length() == 0 and int(W_MOD.region_rev(1, 0, 0)) == rev_before_bye,
      "dh: bye clears pending LOD state while preserving world.lod_revs")
send({"t": "hello", "v": 1, "sid": "s1", "w": 0, "lod": 1})
tick(10)
take()
send({"t": "budget", "u": 500})
tick(1)

# 8. lod chunk includes optional pol + pollution.lua covers view_radius+4 and sweeps distant charted chunks via pols:
F.pollution[f"{empty_cx},{empty_cy}"] = 240.0
send({"t": "lod_sub", "si": 1, "res": 32, "act": "want", "c": [[empty_cx, empty_cy]]})
tick(3)
lod_pol_msgs = [m for m in of_type(take(), "lod") if (m["cx"], m["cy"]) == (empty_cx, empty_cy) and "none" not in m]
check(lod_pol_msgs and lod_pol_msgs[-1].get("pol") == 240,
      f"dh: lod chunk carries optional pol when chunk has pollution: {lod_pol_msgs}")
F.pollution[f"{empty_cx},{empty_cy}"] = 0.0
send({"t": "lod_sub", "si": 1, "res": 32, "act": "want", "c": [[empty_cx, empty_cy]]})
tick(3)
lod_clean_msgs = [m for m in of_type(take(), "lod") if (m["cx"], m["cy"]) == (empty_cx, empty_cy) and "none" not in m]
check(lod_clean_msgs and "pol" not in lod_clean_msgs[-1],
      f"dh: lod chunk omits pol when chunk pollution is 0: {lod_clean_msgs}")

send({"t": "sub", "o": [0, 0], "r": 16, "w": []})
send({"t": "focus", "x": 16, "y": 16, "r": 192})
lua.execute("""
F_pol_saved_chunks = game.surfaces[1].get_chunks
F_pol_saved_charted = F.charted
local c_list = { { x = 0, y = 0 }, { x = 30, y = 0 } }
F.charted = { ["0,0"] = true, ["30,0"] = true }
game.surfaces[1].get_chunks = function()
  local i = 0
  return function()
    i = i + 1
    return c_list[i]
  end
end
package.loaded["scripts.pollution"].reset()
""")
F.pollution["0,0"] = 100.0
F.pollution["30,0"] = 320.0
pol_seen, pols_seen = [], []
for _ in range(70):
    tick(1)
    for m in take():
        if m.get("t") == "pol":
            pol_seen.append(m)
        elif m.get("t") == "pols":
            pols_seen.append(m)
check(pol_seen and pol_seen[-1].get("w", 0) >= 41,
      f"pol: sends promptly after reset and covers view_radius+4 (w={pol_seen[-1].get('w') if pol_seen else 0})")
check(pols_seen and pols_seen[-1].get("l") == [30, 0, 320],
      f"pols: background sweep reports distant polluted charted chunk outside live pol square: {pols_seen}")
F.pollution["30,0"] = 0.0
pols_clear = []
for _ in range(70):
    tick(1)
    pols_clear.extend(of_type(take(), "pols"))
check(pols_clear and pols_clear[-1].get("l") == [30, 0, 0],
      f"pols: background sweep sends explicit 0 when distant chunk clears: {pols_clear}")
F.pollution = lua.eval("{}")
lua.execute("game.surfaces[1].get_chunks = F_pol_saved_chunks; F.charted = F_pol_saved_charted; F_pol_saved_chunks = nil; F_pol_saved_charted = nil")

for e in dh_ents + dense_lod:
    e.destroy()
lua.execute("F.charted = F_dh_orig_c; F_dh_orig_c = nil")
if saved_exp_n3 is not None:
    g.storage.f3d.explored[1][-3][-3] = saved_exp_n3
send({"t": "sub", "c": dh_old_subs})
tick(10)
take()

# Owner's #4: Vulcanus' demolisher territories, as their chunks, so the client draws the red borders.
F.territories = lua.eval("{{{x = 1, y = 2}, {x = 2, y = 2}}, {{x = -5, y = 0}}}")
g.package.loaded["scripts.planets"].territories_soon()
tick(1)
terr = of_type(take(), "terr")
check(terr and terr[-1]["parts"] == 1 and terr[-1]["l"] == [[1, 2, 2, 2], [-5, 0]] and terr[-1].get("si") == 1,
      f"terr: every territory's chunks, with the surface they are on (G20): {terr[-1:]}")
# I16: a territory whose demolisher was killed is cleared: left out, and counted in `c`.
F.cleared_territories = lua.eval("{[1] = true}")
g.package.loaded["scripts.planets"].territories_soon()
tick(1)
terr = of_type(take(), "terr")
check(terr and terr[-1]["l"] == [[-5, 0]] and terr[-1].get("c") == 1,
      f"terr leaves out a territory whose demolisher is dead, so its border goes (I16): {terr[-1:]}")
F.cleared_territories = lua.eval("{}")
F.territories = lua.eval("{}")
g.package.loaded["scripts.planets"].territories_soon()
tick(1)
terr = of_type(take(), "terr")
check(terr and terr[-1]["l"] == [], "a surface without territories sends an empty list (it clears them)")

# Owner's #22: right-click on the map removes the ghost there (and says so), else nothing.
map_ghost = spawn("entity-ghost", 7.5, 6.5, inner_name="wooden-chest", force="player")
gu = map_ghost.unit_number
send({"t": "unghost", "q": 7, "x": fixed(7.6), "y": fixed(6.4)})
tick(1)
msgs = take()
check(not map_ghost.valid and [m["n"] for m in of_type(msgs, "unghost")] == [1] and any(d["u"] == gu for d in of_type(msgs, "del")),
      f"unghost removes the ghost under the click and sends its del: {of_type(msgs, 'unghost')}")
send({"t": "unghost", "q": 8, "x": fixed(30.5), "y": fixed(30.5)})
tick(1)
check([(m["q"], m["n"]) for m in of_type(take(), "unghost")] == [(8, 0)], "no ghost there: n = 0, so the client adds a tag")
send({"t": "tag_add", "x": 5 * 256, "y": 6 * 256, "text": "base", "icon": ["item", "iron-plate"]})
tick(1)
tags = of_type(take(), "tags")
check(tags and tags[-1]["l"] == [[1, 5 * 256, 6 * 256, "base", "item", "iron-plate"]], f"tag_add puts a tag on the map: {tags[-1:]}")
send({"t": "tag_add", "x": 50 * 256, "y": 0, "text": "far"})
tick(1)
check(any("Can't put a tag there" in m["text"] for m in of_type(take(), "msg")), "a tag where the map isn't charted is refused")
F["raise"]("on_chart_tag_modified", lua.table_from({}))
tick(1)
check(of_type(take(), "tags"), "the tags are sent again when they change in the game")
send({"t": "tag_del", "id": 1})
tick(1)
tags = of_type(take(), "tags")
check(tags and tags[-1]["l"] in ([], {}), "tag_del removes it")

px, py = g.storage.f3d.puppet.position.x, g.storage.f3d.puppet.position.y
F.chart_requests = lua.table_from([])
tick(121)
take()
reqs = list(F.chart_requests.values())
check(reqs and reqs[0][1][1] + 96 == px and reqs[0][2][2] - 96 == py,
      "the force charts around a player-less character every 2 seconds")
# A headless server with nobody connected never carries those requests out: the chunks the
# character was near count as charted anyway.
send({"t": "map", "cx1": 1, "cy1": 0, "cx2": 1, "cy2": 0, "res": 32})
tick(1)
c10 = [m for m in of_type(take(), "chart") if (m["cx"], m["cy"]) == (1, 0)]
check(c10 and c10[0]["n"] == 1 and not F.charted["1,0"],
      f"a chunk the character has been near is charted even if the game never charted it: {c10}")
# The map's surface switcher: the surfaces it can show, and charts of a surface by index.
g.storage.f3d.surfs_sig = None
tick(1)
while g.game.tick % 300:
    tick(1)
tick(1)
surfs = of_type(take(), "surfs")
check(surfs and [1, "nauvis", "nauvis", "", 0] in surfs[-1]["l"], f"the surfaces the map can show are sent when they change: {surfs}")
send({"t": "hello", "v": 1, "sid": "s1", "w": 1})  # keep-alive: the waits above add up past the timeout
other = F.make_surface(50, "f3d-other")
g.storage.f3d.surfs_sig = None
tick(1)
while g.game.tick % 300:
    tick(1)
tick(1)
surfs = of_type(take(), "surfs")
check(surfs and surfs[-1]["l"][-1] == [50, "f3d-other", "", "", 0], f"a surface that is no planet nor platform comes last (Factorio's Other): {surfs[-1:]}")
F.game_surfaces[50] = None
send({"t": "map", "cx1": 0, "cy1": 0, "cx2": 0, "cy2": 0, "res": 32, "si": 1})
tick(2)
msgs = take()
c00 = [m for m in of_type(msgs, "chart") if (m["cx"], m["cy"]) == (0, 0)]
check(c00 and c00[0]["si"] == 1 and of_type(msgs, "tags") and of_type(msgs, "tags")[-1]["si"] == 1,
      "a map request names its surface (si), and its charts and tags say which surface they are")
send({"t": "map", "cx1": 0, "cy1": 0, "cx2": 0, "cy2": 0, "res": 32, "si": 99})
tick(2)
c00 = [m for m in of_type(take(), "chart") if (m["cx"], m["cy"]) == (0, 0)]
check(c00 and c00[0]["si"] == 1, "an unknown surface falls back to the character's")
# Remote building: ghosts only where the map is charted, as in the game.
send({"t": "build", "item": "assembling-machine-1", "x": 5000 * 256, "y": 5000 * 256, "d": 0, "ghost": 1})
tick(1)
msgs = take()
check(any("uncharted" in m["text"] for m in of_type(msgs, "msg")), "a ghost far away on uncharted ground is refused")

# --- trains: stops, train state, schedules, wagons --------------------------------------------------
send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
take()
px, py = g.storage.f3d.puppet.position.x, g.storage.f3d.puppet.position.y
stop = spawn("train-stop", px + 3, py + 3, force="player", backer_name="Iron")
stop.color = lua.table_from({"r": 1, "g": 0.5, "b": 0, "a": 1})
F["raise"]("script_raised_built", lua.table_from({"entity": stop}))
tick(1)
adds = [m["e"] for m in of_type(take(), "add") if m["e"][0] == stop.unit_number]
check(adds and adds[0][5].get("n") == "Iron", f"a train stop's record has its name: {adds}")
check(adds and adds[0][5].get("col") == [255, 128, 0], f"and the colour given to it, 0-255 (H21): {adds}")
stop.color = lua.table_from({"r": 0, "g": 0, "b": 1, "a": 1})
F["raise"]("on_entity_color_changed", lua.table_from({"entity": stop}))
tick(1)
upds = [m["e"] for m in of_type(take(), "upd") if m["e"][0] == stop.unit_number]
check(upds and upds[0][5].get("col") == [0, 0, 255], f"a repainted stop sends its new colour (H21): {upds}")
loco2 = spawn("locomotive", px + 6, py + 1, force="player")
wagon = spawn("cargo-wagon", px + 6, py + 8, force="player")
rail = spawn("straight-rail", px + 20, py, force="player")
train = F.couple(loco2, wagon)
td = F.train_data[train]
td.state = g.defines.train_state.wait_station
td.station = stop
td.path_end_stop = stop
td.speed = 0.25
tick(31)  # trains are looked at once every 30 ticks, on a phase of their own
tr = [r for m in of_type(take(), "tr") for r in m["l"] if r[0] == train.id]
check(tr and tr[-1] == [train.id, "wait_station", 0, 250, stop.unit_number, "Iron", [loco2.unit_number, wagon.unit_number]],
      f"tr: a train's state, speed, stop, destination and carriages: {tr[-1:]}")

# D11: the map draws trains live; the client asks with `mtr` while a map is open.
send({"t": "mtr"})
tick(1)
mtr = of_type(take(), "mtr")
cars = mtr[-1]["l"] if mtr else []
check(mtr and mtr[-1]["parts"] == 1 and len(cars) == 12 and cars[0] == fixed(px + 6) and cars[1] == fixed(py + 1)
      and cars[3] > cars[4] > 0 and cars[5] == 0xEB1200 and cars[11] == 0x9A9A9A,
      f"mtr: each carriage's place, turn, size and map colour: {mtr[-1:]}")
send({"t": "mtr"})
tick(1)
check(not of_type(take(), "mtr"), "mtr: asks closer together than a third of a second are ignored")
# D12: only what radars (or the character) see: a train far away shows once a radar covers it, and
# the first part lists the working radars (cov) so the map dims the rest.
far_loco = spawn("locomotive", px + 400, py + 1, force="player")
tick(25)
send({"t": "mtr"})
tick(1)
m1 = of_type(take(), "mtr")
far_radar = spawn("radar", px + 420, py + 20, force="player")
F["raise"]("script_raised_built", lua.table_from({"entity": far_radar}))
tick(301)
send({"t": "mtr"})
tick(1)
m2 = of_type(take(), "mtr")
fx_far = fixed(px + 400)
check(m1 and fx_far not in m1[-1]["l"][0::6] and m1[-1].get("cov") in ([], {}),
      f"mtr: a train no radar covers isn't sent, and no radars means an empty cov: {m1[-1:]}")
rcx, rcy = math.floor((px + 420) / 32), math.floor((py + 20) / 32)
check(m2 and fx_far in m2[-1]["l"][0::6] and m2[-1].get("cov") == [rcx, rcy, 3],
      f"mtr: a working radar's chunks show their trains, and cov lists it: {m2[-1:]}")
# H13: the map's logistic layer shows every roboport on the surface (`mrp`), read from the force's
# logistic networks' cells rather than the charts the client loaded; a personal roboport's cell isn't one.
rp_near = spawn("roboport", px + 30, py + 30, force="player")
rp_far = spawn("roboport", px + 900, py - 700, force="player")
F.lnets = lua.table_from({"nauvis": lua.table_from([
    F.make_network(3, lua.table_from([0, 0, 0, 0]), lua.table(),
                   lua.table_from([F.make_cell(rp_near, 25, 55), F.make_cell(rp_far, 25, 55)])),
    F.make_network(4, lua.table_from([0, 0, 0, 0]), lua.table(), lua.table_from([F.make_cell(far_loco, 0, 10)]))])})
send({"t": "mrp", "q": 5})
tick(2)
rp = of_type(take(), "mrp")
check(rp and rp[-1].get("last") == 1 and rp[-1].get("q") == 5 and rp[-1].get("si") == 1
      and rp[-1].get("l") == [fixed(px + 30), fixed(py + 30), fixed(25), fixed(55), fixed(px + 900), fixed(py - 700), fixed(25), fixed(55)],
      f"mrp: every roboport of the surface's networks with its logistic and construction radius: {rp[-1:]}")
send({"t": "mrp", "q": 6})
tick(2)
check(not of_type(take(), "mrp"), "mrp: asks within a second for the same surface are ignored")
send({"t": "hello", "v": 1, "sid": "s1", "w": 1})  # keep-alive: the waits here add up past the timeout
# Ground in a roboport's construction area counts as seen, like a radar's (H13): the map's trains
# there, the remote view's movers and buildings to open; a mobile cell (a personal roboport) doesn't.
# Chunks are seen by their centres: these are chunk centres inside (in_x, in_x2) and past (out_x) the
# far roboport's construction square (55 tiles round px + 900, py - 700).
rx, ry = px + 900, py - 700
mid_y = math.floor(ry / 32) * 32 + 16
in_x, in_x2 = math.floor((rx + 30) / 32) * 32 + 16, math.floor((rx - 30) / 32) * 32 + 16
out_x = math.floor((rx + 90) / 32) * 32 + 16
rp_loco = spawn("locomotive", rx, ry + 10, force="player")
mobile_car = spawn("car", px - 900, py + 700, force="player")
mobile_loco = spawn("locomotive", px - 900, py + 690, force="player")
F.lnets["nauvis"][3] = F.make_network(5, lua.table_from([0, 0, 0, 0]), lua.table(),
                                      lua.table_from([F.make_cell(mobile_car, 15, 30)]))
tick(21)
send({"t": "mtr"})
tick(1)
mt = of_type(take(), "mtr")
mt_x = mt[-1]["l"][0::6] if mt else []
check(mt and fixed(rx) in mt_x and fixed(px - 900) not in mt_x,
      f"mtr: a train in a roboport's construction area is shown, one by a personal roboport isn't: {mt_x}")
rp_asm = spawn("assembling-machine-1", in_x + 0.5, mid_y + 0.5, force="player")
far_asm2 = spawn("assembling-machine-1", out_x + 0.5, mid_y + 0.5, force="player")
send(dict(open_cmd(rp_asm), rv=1))
tick(2)
check(bool(guis(take(), rp_asm)), "rv: a building in a roboport's construction area opens from the remote view (D10)")
send(dict(open_cmd(far_asm2), rv=1))
tick(2)
check(not guis(take(), far_asm2), "rv: one past the construction area doesn't")
send({"t": "close"})
rp_car = spawn("car", in_x2, mid_y)
past_car = spawn("car", out_x, mid_y)
send({"t": "focus", "x": fixed(rx), "y": fixed(ry), "r": 128, "rv": 1})
tick(61)
rp_units = {rec[0] for rec in decode_records(last_frame(take(), "mv"))}
check(rp_car.unit_number in rp_units and past_car.unit_number not in rp_units,
      f"remote view: a mover in a roboport's construction area is sent, one past it isn't: {sorted(rp_units)}")
send({"t": "focus", "x": fixed(px), "y": fixed(py), "r": 32})
tick(2)
take()
for e in (rp_loco, mobile_car, mobile_loco, rp_asm, far_asm2, rp_car, past_car):
    e.destroy()
tick(91)  # 180 ticks in all here: the checks further on wait for ticks on a phase of their own
F.lnets = lua.table()
send({"t": "hello", "v": 1, "sid": "s1", "w": 1})  # keep-alive
send({"t": "mrp", "q": 7})
tick(2)
rp = of_type(take(), "mrp")
check(rp and rp[-1].get("q") == 7 and rp[-1].get("last") == 1 and rp[-1].get("l") in ([], {}),
      f"mrp: no networks, an empty last part: {rp[-1:]}")
# H23: switching the map to a planet centres on the force's landing pad there (`lpad`).
pad = spawn("cargo-landing-pad", px + 60, py - 40, force="player")
F["raise"]("script_raised_built", lua.table_from({"entity": pad}))
send({"t": "lpad", "si": 1, "q": 11})
tick(2)
lp = of_type(take(), "lpad")
check(lp and lp[-1].get("q") == 11 and lp[-1].get("si") == 1 and lp[-1].get("x") == fixed(px + 60) and lp[-1].get("y") == fixed(py - 40),
      f"lpad: the landing pad's position on that surface: {lp[-1:]}")
send({"t": "lpad", "si": 999, "q": 12})
tick(2)
lp = of_type(take(), "lpad")
check(lp and lp[-1].get("q") == 12 and "x" not in lp[-1], f"lpad: no such surface, no position: {lp[-1:]}")
pad.destroy()
# The 3D remote view (focus rv = 1) sends moving things only where radars or the character see,
# and `cov` about once a second; the normal view sends everything.
seen_car = spawn("car", px + 450, py + 30)  # the radar at px + 420 reveals 3 chunks round its own
unseen_car = spawn("car", px + 555, py + 30)
send({"t": "focus", "x": fixed(px + 500), "y": fixed(py), "r": 64, "rv": 1})
tick(61)
rv_msgs = take()
rv_units = {rec[0] for rec in decode_records(last_frame(rv_msgs, "mv"))}
covs = of_type(rv_msgs, "cov")
check(seen_car.unit_number in rv_units and unseen_car.unit_number not in rv_units,
      f"remote view: a mover a radar sees is sent, one no radar sees isn't: {sorted(rv_units)}")
check(covs and covs[-1]["l"] == [rcx, rcy, 3] and covs[-1]["x"] == fixed(px) and covs[-1]["cr"] == 96 and covs[-1]["si"] == 1,
      f"remote view: cov lists the radars and the character's place and radius: {covs[-1:]}")
# Multiplayer: the filter keeps radars' statuses a second (module-local), which suits what is sent;
# belt items' rounds keep the belts they found in storage, so they ask for the game as it is now.
map_mod = g.package.loaded["scripts.map"]
rv_belt = spawn("transport-belt", px + 505.5, py + 0.5, force="player", direction=4)
F.put_on_belt(rv_belt, 1, "iron-plate", 0.5, 6101)


def bi_uids(msgs):
    out = set()
    for m in of_type(msgs, "bi"):
        l, prev = m["l"], [0, 0, 0, 0]
        for i in range(0, len(l), 4):
            prev = [a + b for a, b in zip(prev, l[i:i + 4])] if m.get("z") else l[i:i + 4]
            out.add(prev[0])
    return out


tick(30)
before_off = bi_uids(take())
far_radar.status = g.defines.entity_status.no_power
tick(1)
exact_now = map_mod.view_filter(True)(px + 505, py)
tick(18)
off_msgs = take()
last_k = max((m["k"] for m in of_type(off_msgs, "bi")), default=None)
# (The first update after carries an item it no longer reads on once, where it would be.)
after_off = bi_uids([m for m in off_msgs if m.get("k") == last_k])
far_radar.status = g.defines.entity_status.working
check(6101 in before_off and exact_now is False and last_k is not None and 6101 not in after_off,
      f"remote view: belt items' rounds follow the radar's status as it is now (exact filter): before {6101 in before_off}, "
      f"exact {exact_now}, after {6101 in after_off}")
rv_belt.destroy()
send({"t": "focus", "x": fixed(px + 500), "y": fixed(py), "r": 64})
tick(61)
plain_msgs = take()
plain_units = {rec[0] for rec in decode_records(last_frame(plain_msgs, "mv"))}
check({seen_car.unit_number, unseen_car.unit_number} <= plain_units and not of_type(plain_msgs, "cov"),
      f"outside the remote view every mover is sent and no cov: {sorted(plain_units)}")
send({"t": "focus", "x": fixed(px), "y": fixed(py), "r": 32, "rv": 1})
tick(4)
near_units = {rec[0] for rec in decode_records(last_frame(take(), "mv"))}
check({loco2.unit_number, wagon.unit_number} <= near_units,
      f"remote view round the character: nothing is left out (the train beside it): {sorted(near_units)}")
send({"t": "focus", "x": fixed(px), "y": fixed(py), "r": 32})
seen_car.destroy()
unseen_car.destroy()
far_loco.destroy()
# The radars' coverage is read where a module-local cache decides (radar_coverage), so reading it
# leaves storage alone: a gone radar stays listed until M.tick prunes the lists on a tick of its own
# (checked at the end). A peer joining mid-game, its cache empty, would otherwise change storage.
far_radar_unit = far_radar.unit_number
far_radar.destroy()
radar_list = g.storage.f3d_radars[1].list
g.package.loaded["scripts.map"].covered(puppet.surface, puppet.force, lua.table_from({"x": px + 420, "y": py + 20}))
check(radar_list[far_radar_unit] is not None, "reading the radars' coverage leaves a gone radar in storage")

send(open_cmd(loco2))
tick(2)
gui = guis(take(), loco2)
check(gui and gui[-1]["kind"] == "train" and gui[-1]["tr"]["id"] == train.id and gui[-1]["tr"]["station"] == "Iron"
      and gui[-1]["tr"]["sched"]["records"] in ([], {}), f"a locomotive opens as a train with an empty schedule: {gui[-1:]}")
records = [{"station": "Iron", "wait_conditions": [{"type": "time", "compare_type": "or", "ticks": 300}]},
           {"rail": [fixed(px + 20), fixed(py)], "temporary": True}]
send({"t": "set_schedule", "u": loco2.unit_number, "records": records})
send({"t": "train_go", "u": loco2.unit_number, "i": 2})
send({"t": "train_mode", "u": loco2.unit_number, "auto": 0})
tick(2)
gui = guis(take(), loco2)
sched = gui[-1]["tr"]["sched"] if gui else {}
check(sched.get("records") == records and sched.get("current") == 2,
      f"set_schedule and train_go: records (a temporary stop's rail as a position) and the current one: {sched}")
check(train.manual_mode is True and gui[-1]["tr"]["manual"] == 1, "train_mode 0 is manual")
send({"t": "train_mode", "u": loco2.unit_number, "auto": 1})
send({"t": "set_schedule", "u": loco2.unit_number, "records": [{"wait_conditions": []}]})
send({"t": "set_stop", "u": loco2.unit_number, "name": "x"})
tick(2)
said = texts(take())
check(train.manual_mode is False, "train_mode 1 is automatic")
interrupts = [{"name": "Refuel", "conditions": [{"type": "fuel_item_count_any", "compare_type": "and",
               "condition": {"first_signal": {"type": "item", "name": "coal"}, "comparator": "<", "constant": 5}}],
               "targets": [{"station": "Iron", "wait_conditions": [{"type": "inactivity", "compare_type": "and", "ticks": 120}]}],
               "inside_interrupt": False}]
send({"t": "set_interrupts", "u": loco2.unit_number, "interrupts": interrupts})
send({"t": "train_temp", "u": loco2.unit_number, "station": "Iron"})
tick(2)
gui = guis(take(), loco2)
tri = gui[-1]["tr"] if gui else {}
sched = tri.get("sched", {})
check(sched.get("interrupts") == interrupts, f"set_interrupts: the interrupts come back in the same shape: {sched.get('interrupts')}")
check(len(sched.get("records", [])) == 3 and sched["records"][sched["current"] - 1].get("temporary") is True
      and sched["records"][sched["current"] - 1]["station"] == "Iron", f"train_temp: a temporary stop after the current one, and it goes there: {sched}")
check(tri.get("stops") == ["Iron"] and tri.get("pos") == [fixed(loco2.position.x), fixed(loco2.position.y)] and tri.get("fuel") in ([], {}),
      f"a train's screen lists the force's stops, the front's position and the fuel: {tri}")
send({"t": "trains_list"})
tick(1)
got = take()
trl = [r for m in of_type(got, "trl") for r in m["l"]]
mine = [r for r in trl if r[0] == train.id]
check(mine and mine[0][3] == "Iron" and mine[0][5] == 2 and mine[0][6] == loco2.unit_number, f"trains_list: every train of the force (trl): {trl}")
send({"t": "train_mode_id", "id": train.id, "auto": 0})
tick(1)
check(train.manual_mode is True and of_type(take(), "trl"), "train_mode_id switches a train from the overview")
# Inputs: a burst of switches lists the trains once (queued as trains_list), not once a packet.
for i in range(40):
    send({"t": "train_mode_id", "id": train.id, "auto": i % 2})
tick(1)
lists = [m for m in of_type(take(), "trl") if m["part"] == 1]
check(len(lists) == 1, f"inputs: 40 train_mode_id in a tick answer with one trains overview, not 40: {len(lists)}")
# Train groups: "Change train group" joins one (gc: trains in it, groups: the force's), Ctrl renames them all.
other = spawn("locomotive", px - 30, py + 30, force="player")
other.train.group = "Copper"
send({"t": "set_train_group", "u": loco2.unit_number, "g": "Copper"})
tick(2)
gui = guis(take(), loco2)
tri = gui[-1]["tr"] if gui else {}
check(train.group == "Copper" and tri.get("sched", {}).get("group") == "Copper" and tri.get("gc") == 2 and ["Copper", 2] in tri.get("groups", []),
      f"set_train_group: the train joins the group; gc counts its trains: {tri.get('gc')} {tri.get('groups')}")
send({"t": "set_train_group", "u": loco2.unit_number, "g": "Copper ore", "all": 1})
tick(2)
gui = guis(take(), loco2)
tri = gui[-1]["tr"] if gui else {}
check(train.group == "Copper ore" and other.train.group == "Copper ore" and ["Copper ore", 2] in tri.get("groups", [])
      and not any(g[0] == "Copper" for g in tri.get("groups", [])),
      f"and with all 1 renames the whole group: {tri.get('groups')}")
send({"t": "set_train_group", "u": loco2.unit_number, "g": ""})
tick(2)
gui = guis(take(), loco2)
check(train.group == "" and gui and gui[-1]["tr"].get("gc") is None, "an empty name leaves the group")
other.destroy()
send({"t": "train_mode_id", "id": train.id, "auto": 1})
tick(1)
take()
check(any(t.startswith("Can't set the schedule") for t in said) and "That isn't a train stop" in said,
      f"a bad schedule and a stop command on a train are refused: {said}")

F.inventories[wagon].cargo.insert(lua.table_from({"name": "iron-plate", "count": 80}))
send(open_cmd(wagon))
tick(2)
gui = guis(take(), wagon)
check(gui and gui[-1]["kind"] == "train" and gui[-1]["inv"].get("cargo") == [["iron-plate", 80]] and len(gui[-1]["slots"]["cargo"]) == 40,
      f"a cargo wagon shows its cargo: {gui[-1:]}")
check(gui and gui[-1]["tr"].get("cargo") == [["iron-plate", 80]], "and the whole train's cargo")

send(open_cmd(stop))
tick(2)
gui = guis(take(), stop)
st = gui[-1]["stop"] if gui else {}
check(gui and gui[-1]["kind"] == "stop" and st.get("name") == "Iron" and st.get("limit") == -1 and st.get("count") == 0
      and st.get("pri") == 50 and st.get("cb", {}).get("wired") == 0 and st.get("cb", {}).get("send") == 1, f"a train stop's screen (send to train is on by default): {gui[-1:]}")
send({"t": "set_stop", "u": stop.unit_number, "pri": 80, "cb": {"en": 1, "cond": {"first_signal": {"type": "item", "name": "iron-plate"},
      "comparator": ">", "constant": 10}, "limit": 1, "limit_sig": {"type": "virtual", "name": "signal-L"}, "read": 1}})
tick(2)
st = guis(take(), stop)[-1]["stop"]
cb = st["cb"]
check(stop.train_stop_priority == 80 and st["pri"] == 80 and cb["en"] == 1 and cb["cond"]["constant"] == 10
      and cb["cond"]["first_signal"]["name"] == "iron-plate" and cb["limit"] == 1 and cb["limit_sig"]["name"] == "signal-L" and cb["read"] == 1,
      f"set_stop sets the priority and the circuit settings: {st}")
send({"t": "set_stop", "u": stop.unit_number, "name": "Copper", "limit": 2})
tick(2)
msgs = take()
gui = guis(msgs, stop)
upds = [m["e"] for m in of_type(msgs, "upd") if m["e"][0] == stop.unit_number]
check(stop.backer_name == "Copper" and stop.trains_limit == 2 and gui and gui[-1]["stop"]["limit"] == 2, "set_stop renames and limits")
check(upds and upds[-1][5].get("n") == "Copper", "and the stop's record follows")
send({"t": "set_stop", "u": stop.unit_number, "limit": -1})
tick(2)
check(stop.trains_limit is None, "limit -1 removes the limit")
stop.trains_limit = 4294967295  # how 2.1 reads a stop without a limit
tick(31)
gui = guis(take(), stop)
check(gui and gui[-1]["stop"]["limit"] == -1, f"2.1's no-limit value (uint32 max) is sent as -1: {gui[-1:]}")
stop.trains_limit = None
F["raise"]("on_entity_renamed", lua.table_from({"entity": stop}))
tick(1)
check([m for m in of_type(take(), "upd") if m["e"][0] == stop.unit_number], "a rename in the game updates the record")
send({"t": "close"})
for e in (stop, loco2, wagon, rail):
    e.destroy()
tick(2)
take()

# --- network data: pipe connections, unplugged machines, heat, wires added later --------------------
send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
take()
p1 = spawn("pipe", 20.5, 25.5, force="player")
F["raise"]("script_raised_built", lua.table_from({"entity": p1}))
p2 = spawn("pipe", 21.5, 25.5, force="player")
F["raise"]("script_raised_built", lua.table_from({"entity": p2}))
tick(1)
msgs = take()
p2_add = [m["e"] for m in of_type(msgs, "add") if m["e"][0] == p2.unit_number]
p1_upd = [m["e"] for m in of_type(msgs, "upd") if m["e"][0] == p1.unit_number]
check(p2_add and p2_add[0][5].get("pc") == 8, f"a pipe's record says which sides connect (8 = west): {p2_add}")
check(p1_upd and p1_upd[-1][5].get("pc") == 2, f"building a pipe updates the pipe it joins (2 = east): {p1_upd}")
F["raise"]("script_raised_destroy", lua.table_from({"entity": p2}))
p2.destroy()
tick(2)
p1_upd = [m["e"] for m in of_type(take(), "upd") if m["e"][0] == p1.unit_number]
check(p1_upd and p1_upd[-1][5].get("pc") == 0, f"and removing it updates it again: {p1_upd}")

lamp2 = spawn("small-lamp", 22.5, 27.5, force="player")
lamp2.status = g.defines.entity_status.not_plugged_in_electric_network
# 2.1 says no_power for a consumer out of reach of every pole; it has no electric network then.
lamp3 = spawn("small-lamp", 21.5, 27.5, force="player")
lamp3.status = g.defines.entity_status.no_power
lamp3.electric_network_id = None
hot = spawn("heat-pipe", 12.5, 12.5, force="player", temperature=512.4)
# (The whole square's look every half second, as before the 0.2.1 hotfix: /f3d-perf wire_strips off. The
# strips are checked at the end.)
g.storage.f3d_perf = lua.table_from({"wire_strips": False})
pa = spawn("small-electric-pole", 24.5, 28.5, force="player")
pb = spawn("small-electric-pole", 27.5, 28.5, force="player")
for e in (pa, pb):
    F["raise"]("script_raised_built", lua.table_from({"entity": e}))
tick(1)
take()
while g.game.tick % 60:
    tick(1)
msgs = take()
pw = [v for m in of_type(msgs, "pw") for v in m["l"]]
check([lamp2.unit_number, 2] in [pw[i:i + 2] for i in range(0, len(pw), 2)], f"pw: 2 for a machine not connected to any pole: {pw}")
check([lamp3.unit_number, 2] in [pw[i:i + 2] for i in range(0, len(pw), 2)], f"pw: 2 for no_power without an electric network (2.1): {pw}")
ht = [v for m in of_type(msgs, "ht") for v in m["l"]]
check(ht == [hot.unit_number, 512], f"ht: a heat pipe's temperature: {ht}")
F.connect(pa, pb, g.defines.wire_type.copper)
tick(31)
upds = {m["e"][0]: m["e"] for m in of_type(take(), "upd")}
check(upds.get(pa.unit_number, [0] * 6)[5].get("w") == [pb.unit_number] and pb.unit_number in upds,
      f"a wire added between two existing poles updates both within half a second: {upds}")
g.storage.f3d_perf = None
for e in (p1, lamp2, lamp3, hot, pa, pb):
    e.destroy()
tick(2)
take()

