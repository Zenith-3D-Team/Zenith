"""Differential live checks of the circuit network UI against the game's own behaviour (bughunt circ2).

  decider   a decider combinator's condition, set through `set_cb` as the client sends it, against what the game's combinator
            does with the same inputs; the client's `condition_holds` (the green behind a holding condition) is run on the
            very `gui.sig` the game sent. The cases are written to E:/Zenith-scratch/hunt/decider_live_cases.json (and the
            committed copy client/tests/fixtures/decider_live_cases.json is what the UI test replays).
  arith     every operation the client offers is one the game takes, and computes it the way it should
  wires     whether the game lets a wire reach (LuaWireConnector.can_wire_reach) against the client's own reach rule
            (wire_tool.gd: the entities' centres no further apart than the shorter reach)
  picker    the signals the client's chooser lists against the game's virtual signals and non-hidden items
"""
from __future__ import annotations

import itertools
import json
import os
import pathlib
import re

from . import live_lib

REPO = pathlib.Path(__file__).resolve().parents[2]
CASES = pathlib.Path(os.environ.get("CIRCDIFF_CASES", "E:/Zenith-scratch/hunt/decider_live_cases.json"))
V = lambda n: {"type": "virtual", "name": n}
I = lambda n: {"type": "item", "name": n}


def _lua(code):
    return live_lib.mod_lua(code.replace("\n", " "))


def check_circuit_diff(c, hello):
    back = _lua("local p = storage.f3d.puppet.position rcon.print(p.x .. ' ' .. p.y)")
    if not live_lib.clean_spot(c, hello, half=16):
        live_lib.report(False, "circdiff: no clean spot found", live_lib.SPOT_WHY)
        return
    _lua('local f = storage.f3d.puppet.force for _, t in pairs({ "electronics", "circuit-network" }) do '
         'if f.technologies[t] then f.technologies[t].researched = true end end rcon.print("ok")')
    x, y = c.me["x"] / 256, c.me["y"] / 256
    only = {k for k in os.environ.get("CIRCDIFF_ONLY", "").split(",") if k}
    for name, fn in (("decider", _decider), ("arith", _arith), ("wires", _wires), ("picker", _picker), ("accept", _accept), ("behav", _behaviour)):
        if only and name not in only:
            continue
        fn(c, hello, x, y)
    if len(back.split()) == 2:
        bx, by = (float(v) for v in back.split())
        _lua(f"storage.f3d.puppet.teleport({{ {bx}, {by} }})")
        live_lib.watch_around(c, hello, bx, by)


def _power(x, y):
    """A powered patch: four substations on an energy interface."""
    return _lua(f"""
local c = storage.f3d.puppet local s = c.surface local f = c.force
local subs = {{}}
for _, p in pairs({{ {{ -5, -5 }}, {{ 5, -5 }}, {{ -5, 5 }}, {{ 5, 5 }} }}) do
  subs[#subs + 1] = s.create_entity({{ name = 'substation', position = {{ {x} + p[1], {y} + p[2] }}, force = f }}) end
local eei = s.create_entity({{ name = 'electric-energy-interface', position = {{ {x} + 0.5 + 0, {y} + 0.5 + 0 }}, force = f }})
eei.electric_buffer_size = 1e9 eei.power_production = 1e9 / 60 eei.energy = 1e9
for i = 2, #subs do subs[1].get_wire_connector(defines.wire_connector_id.pole_copper, true).connect_to(subs[i].get_wire_connector(defines.wire_connector_id.pole_copper, true), false) end
subs[2].get_wire_connector(defines.wire_connector_id.pole_copper, true).connect_to(subs[4].get_wire_connector(defines.wire_connector_id.pole_copper, true), false)
rcon.print(#subs .. ' ' .. tostring(eei and eei.valid))""")


# --- decider ---------------------------------------------------------------------------------------------------
INT_MAX = 2147483647
CONFIGS = [  # (red, green): signal name -> count
    ({}, {}),
    ({"signal-A": 5}, {}),
    ({"signal-A": 5, "signal-B": 3}, {}),
    ({"signal-A": 5}, {"signal-A": 3}),
    ({"signal-A": -4, "signal-B": 7}, {"signal-B": -7}),
    ({}, {"signal-A": 5, "signal-C": 10}),
    ({"signal-A": INT_MAX}, {"signal-A": 1}),
    ({"signal-A": 4, "signal-B": 4, "iron-plate": 100}, {"signal-B": 1}),
]
FIRSTS = [V("signal-A"), V("signal-each"), V("signal-anything"), V("signal-everything"), V("signal-C"), I("iron-plate")]
SECONDS = [("const", 0), ("const", 4), ("const", -4), ("sig", V("signal-B")), ("sig", V("signal-C"))]
CMPS = [">", "<", "=", "≥", "≤", "≠"]


def _decider_cases():
    cases = []
    for first, cmp, (kind, val) in itertools.product(FIRSTS, CMPS, SECONDS):
        cond = {"first_signal": first, "comparator": cmp}
        cond.update({"constant": val} if kind == "const" else {"second_signal": val})
        cases.append(cond)
    for first, cmp, const, nets in itertools.product(FIRSTS[:4], (">", "="), (0, 4), ({"red": True, "green": False}, {"red": False, "green": True})):
        cases.append({"first_signal": first, "comparator": cmp, "constant": const, "first_signal_networks": nets})
    for first, cmp, nets in itertools.product(FIRSTS[:3], ("<", "="), ({"red": True, "green": False}, {"red": False, "green": True})):
        cases.append({"first_signal": first, "comparator": cmp, "second_signal": V("signal-B"), "second_signal_networks": nets})
    return cases


def _decider(c, hello, x, y):
    fx = lambda v: int(round(v * 256))
    print("INFO circdiff:", _power(x, y))
    out = _lua(f"""
local c = storage.f3d.puppet local s = c.surface local f = c.force local ids = defines.wire_connector_id
local function mk(n, dx, dy, d) return s.create_entity({{ name = n, position = {{ {x} + dx, {y} + dy }}, direction = d, force = f, raise_built = true }}) end
local red, green, sink = mk('constant-combinator', -1.5, -2.5, 0), mk('constant-combinator', -0.5, -2.5, 0), mk('constant-combinator', 1.5, 1.5, 0)
local dec = mk('decider-combinator', 0.5, 0, 0)
red.get_wire_connector(ids.circuit_red, true).connect_to(dec.get_wire_connector(ids.combinator_input_red, true), false)
green.get_wire_connector(ids.circuit_green, true).connect_to(dec.get_wire_connector(ids.combinator_input_green, true), false)
dec.get_wire_connector(ids.combinator_output_red, true).connect_to(sink.get_wire_connector(ids.circuit_red, true), false)
red.get_or_create_control_behavior() green.get_or_create_control_behavior() sink.get_or_create_control_behavior()
storage.circdiff = {{ red = red.unit_number, green = green.unit_number, sink = sink.unit_number, dec = dec.unit_number }}
rcon.print(red.unit_number .. ' ' .. green.unit_number .. ' ' .. sink.unit_number .. ' ' .. dec.unit_number .. ' ' .. dec.position.x .. ' ' .. dec.position.y)""")
    v = out.split()
    if len(v) != 6:
        live_lib.report(False, "decider: building the test circuit", out)
        return
    unit, dx, dy = int(v[3]), float(v[4]), float(v[5])
    find = ("local function ent(u) for _, e in pairs(storage.f3d.puppet.surface.find_entities_filtered({ force = storage.f3d.puppet.force, "
            "position = { %s, %s }, radius = 8 })) do if e.unit_number == u then return e end end end" % (x, y))

    def set_inputs(red, green):
        def filters(d):
            return "{" + ",".join("{ value = { type = '%s', name = '%s', quality = 'normal', comparator = '=' }, min = %d }" % (
                "item" if n == "iron-plate" else "virtual", n, n_) for n, n_ in d.items()) + "}"
        _lua(f"{find} local r, g = ent({v[0]}), ent({v[1]}) for _, p in pairs({{ {{ r, {filters(red)} }}, {{ g, {filters(green)} }} }}) do "
             f"local b = p[1].get_control_behavior() local sec = b.get_section(1) or b.add_section() sec.filters = p[2] end rcon.print('ok')")

    def sink_out():
        return _lua(f"{find} local e = ent({v[2]}) local o = {{}} for _, sg in pairs(e.get_signals(defines.wire_connector_id.circuit_red) or {{}}) do "
                    f"o[#o + 1] = sg.signal.name .. '=' .. sg.count end table.sort(o) rcon.print(table.concat(o, ','))")

    c.send({"t": "open", "u": unit, "p": c.proto_id("decider-combinator"), "x": fx(dx), "y": fx(dy)})
    c.pump(0.5, every=hello)
    outputs = [{"signal": V("signal-O"), "copy_count_from_input": False, "constant": 1}]
    cases = _decider_cases()
    record, configs = [], []
    for ci, (red, green) in enumerate(CONFIGS):
        set_inputs(red, green)
        c.send({"t": "set_cb", "u": unit, "cb": {"conditions": [cases[0]], "outputs": outputs}})
        msgs = c.pump(0.6, every=hello)
        g = [m for m in live_lib.of_type(msgs, "gui") if m.get("u") == unit]
        sig = (g[-1].get("sig") if g else None)
        if sig is None:
            c.send({"t": "open", "u": unit, "p": c.proto_id("decider-combinator"), "x": fx(dx), "y": fx(dy)})
            g = [m for m in c.pump(0.6, every=hello) if m.get("t") == "gui" and m.get("u") == unit]
            sig = g[-1].get("sig") if g else {}
        sig = sig or {}
        for cond in cases:
            c.send({"t": "set_cb", "u": unit, "cb": {"conditions": [cond], "outputs": outputs}})
            c.pump(0.1, every=hello)
            got = sink_out()
            holds = any(p.startswith("signal-O=") and not p.endswith("=0") for p in got.split(","))
            record.append({"c": cond, "i": ci, "g": holds})
        configs.append({"red": red, "green": green, "sig": sig})
    CASES.parent.mkdir(parents=True, exist_ok=True)
    CASES.write_text(json.dumps({"configs": configs, "cases": record}, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    live_lib.report(len(record) == len(CONFIGS) * len(cases), f"decider: {len(record)} condition cases recorded for the UI test", str(CASES))
    live_lib.report(any(r["g"] for r in record) and any(not r["g"] for r in record), "decider: the game's combinator answers both ways",
                    f"{sum(1 for r in record if r['g'])} true")
    nosig = sum(1 for k in configs if not k["sig"].get("r") and not k["sig"].get("g") and (k["red"] or k["green"]))
    live_lib.report(nosig == 0, "decider: gui.sig carries the input signals of every config the combinator had", f"{nosig} cases without")


# --- arithmetic ------------------------------------------------------------------------------------------------
def _arith(c, hello, x, y):
    src = (REPO / "client/scripts/ui/factorio/entity_panels.gd").read_text(encoding="utf-8")
    ops = json.loads(re.search(r"const ARITHMETIC_OPS := (\[.*?\])", src).group(1))
    print("INFO circdiff:", _power(x, y))
    out = _lua(f"""
local c = storage.f3d.puppet local s = c.surface local f = c.force local ids = defines.wire_connector_id
local function mk(n, dx, dy, d) return s.create_entity({{ name = n, position = {{ {x} + dx, {y} + dy }}, direction = d, force = f, raise_built = true }}) end
local red, sink = mk('constant-combinator', -1.5, -2.5, 0), mk('constant-combinator', 1.5, 1.5, 0)
local ar = mk('arithmetic-combinator', 0.5, 0, 0)
red.get_wire_connector(ids.circuit_red, true).connect_to(ar.get_wire_connector(ids.combinator_input_red, true), false)
ar.get_wire_connector(ids.combinator_output_red, true).connect_to(sink.get_wire_connector(ids.circuit_red, true), false)
local b = red.get_or_create_control_behavior() local sec = b.get_section(1) or b.add_section()
sec.filters = {{ {{ value = {{ type = 'virtual', name = 'signal-A', quality = 'normal', comparator = '=' }}, min = 20 }}, {{ value = {{ type = 'virtual', name = 'signal-B', quality = 'normal', comparator = '=' }}, min = -7 }} }}
sink.get_or_create_control_behavior()
rcon.print(ar.unit_number .. ' ' .. sink.unit_number .. ' ' .. ar.position.x .. ' ' .. ar.position.y)""")
    v = out.split()
    if len(v) != 4:
        live_lib.report(False, "arith: building the test circuit", out)
        return
    unit = int(v[0])
    fx = lambda q: int(round(float(q) * 256))
    c.send({"t": "open", "u": unit, "p": c.proto_id("arithmetic-combinator"), "x": fx(v[2]), "y": fx(v[3])})
    c.pump(0.5, every=hello)
    find = ("local function ent(u) for _, e in pairs(storage.f3d.puppet.surface.find_entities_filtered({ force = storage.f3d.puppet.force, "
            "position = { %s, %s }, radius = 8 })) do if e.unit_number == u then return e end end end" % (x, y))
    expect = {"*": -140, "/": -2, "+": 13, "-": 27, "%": 6, "^": None, "<<": None, ">>": None, "AND": 20 & -7, "OR": 20 | -7, "XOR": 20 ^ -7}
    bad = []
    for op in ops:
        c.send({"t": "set_cb", "u": unit, "cb": {"first_signal": V("signal-A"), "second_signal": V("signal-B"), "operation": op,
                                                 "output_signal": V("signal-O")}})
        c.pump(0.15, every=hello)
        got = _lua(f"{find} local e = ent({v[1]}) local o = {{}} for _, sg in pairs(e.get_signals(defines.wire_connector_id.circuit_red) or {{}}) do "
                   f"o[#o + 1] = sg.signal.name .. '=' .. sg.count end table.sort(o) rcon.print(table.concat(o, ','))")
        want = expect.get(op)
        if want is not None and f"signal-O={want}" not in got.split(","):
            bad.append(f"{op}: {got}")
        elif want is None and "signal-O=" not in got and op not in ("^", "<<", ">>"):
            bad.append(f"{op}: {got}")
    live_lib.report(not bad, f"arithmetic: the game computes each of the client's {len(ops)} operations as Factorio defines them", "; ".join(bad)[:300])
    # Every operation the game takes is one the client offers.
    game_ops = _lua("local o = {} for k in pairs(defines.control_behavior) do end rcon.print('x')")
    c.send({"t": "close"})


# --- wires -----------------------------------------------------------------------------------------------------
# (entity, entity, wire): "c" red / green, "w" copper
PAIRS = [(n, n, "c") for n in ("constant-combinator", "small-lamp", "assembling-machine-1", "fast-inserter", "decider-combinator", "oil-refinery",
                               "storage-tank", "gun-turret", "roboport", "chemical-plant", "rail-signal", "steel-furnace", "wooden-chest")] + [
    ("small-electric-pole", "small-lamp", "c"), ("medium-electric-pole", "constant-combinator", "c"), ("substation", "decider-combinator", "c"),
    ("big-electric-pole", "assembling-machine-1", "c"), ("small-electric-pole", "medium-electric-pole", "c"),
    ("small-electric-pole", "small-electric-pole", "w"), ("small-electric-pole", "medium-electric-pole", "w"), ("big-electric-pole", "small-electric-pole", "w"),
    ("substation", "big-electric-pole", "w"), ("medium-electric-pole", "medium-electric-pole", "w"), ("substation", "substation", "w"),
    ("small-electric-pole", "power-switch", "w"), ("big-electric-pole", "power-switch", "w")]


def _wires(c, hello, x, y):
    pairs = ", ".join("{ '%s', '%s', '%s' }" % p for p in PAIRS)
    out = _lua(f"""
local c = storage.f3d.puppet local s = c.surface local f = c.force local ids = defines.wire_connector_id
local o = {{}}
local function rid(e, kind, other)
  if kind == 'w' then if e.type == 'power-switch' then return ids.power_switch_left_copper end return ids.pole_copper end
  if e.type:find('combinator') and e.type ~= 'constant-combinator' then return ids.combinator_input_red end
  return ids.circuit_red end
local function slack(n) local b = prototypes.entity[n].selection_box return math.sqrt((b.right_bottom.x - b.left_top.x) ^ 2 + (b.right_bottom.y - b.left_top.y) ^ 2) / 2 end
local function reach(n, kind)
  local p = prototypes.entity[n]
  local w = select(2, pcall(function() return p.get_max_wire_distance() end))
  local cw = select(2, pcall(function() return p.get_max_circuit_wire_distance() end))
  w = type(w) == 'number' and w or 0 cw = type(cw) == 'number' and cw or 0
  if kind == 'w' then return w > 0 and w or cw end
  return cw > 0 and cw or w end
for _, pr in pairs({{ {pairs} }}) do
  local na, nb, kind = pr[1], pr[2], pr[3]
  local lim = math.min(reach(na, kind), reach(nb, kind))
  if reach(na, kind) <= 0 or reach(nb, kind) <= 0 then lim = math.max(reach(na, kind), reach(nb, kind)) end
  local a = s.create_entity({{ name = na, position = {{ {x}, {y} - 12 }}, force = f }})
  if a then
    for _, d in pairs({{ 3, 4, 5, 6, 7, 8, 8.5, 9, 9.5, 10, 10.5, 11, 12, 14, 16, 18, 20, 24, 30, 34 }}) do
      if d <= lim + 6 then
      for _, ang in pairs({{ 0, 1, 2 }}) do
        local dx, dy = d, 0
        if ang == 1 then dx, dy = 0, d elseif ang == 2 then dx, dy = d * 0.7071, d * 0.7071 end
        local b = s.create_entity({{ name = nb, position = {{ a.position.x + dx, a.position.y + dy }}, force = f }})
        if b then
          local ca, cb = a.get_wire_connector(rid(a, kind), true), b.get_wire_connector(rid(b, kind), true)
          local dist = math.sqrt((a.position.x - b.position.x) ^ 2 + (a.position.y - b.position.y) ^ 2)
          if ca and cb then o[#o + 1] = na .. '+' .. nb .. kind .. ' ' .. string.format('%.2f', dist) .. ' ' .. tostring(ca.can_wire_reach(cb)) .. ' ' .. string.format('%.1f', math.floor(lim * 10 + 0.5) / 10) .. ' ' .. string.format('%.2f', slack(na) + slack(nb))
          else o[#o + 1] = na .. '+' .. nb .. kind .. ' ' .. string.format('%.2f', dist) .. ' noconn 0' end
          b.destroy()
        end
      end
      end
    end
    a.destroy()
  else o[#o + 1] = na .. '+' .. nb .. kind .. ' nobuild' end
end
rcon.print(table.concat(o, ';'))""")
    rows = [r.split() for r in out.split(";") if r]
    refused, loose, noconn, nobuild, cw, maxacc = [], [], set(), set(), {}, {}
    for r in rows:
        if len(r) not in (4, 5):
            nobuild.add(r[0])
            continue
        n, dist, reach, limit = r[0], float(r[1]), r[2], float(r[3])
        slack = float(r[4]) if len(r) == 5 else 0.0
        if reach == "noconn":
            noconn.add(n)
            continue
        reach = reach == "true"
        client_ok = limit <= 0 or dist <= limit + 0.01 + slack
        cw[n] = limit
        if reach:
            maxacc[n] = max(maxacc.get(n, 0), dist)
        if reach and not client_ok:
            refused.append(f"{n} {dist}")
        elif client_ok and not reach:
            loose.append(f"{n} {dist}")
    print("INFO circdiff: furthest wire the game took (centre to centre), by reach:", {n: (maxacc.get(n), cw[n]) for n in cw})
    print("INFO circdiff: reach", cw, "no connector:", sorted(noconn), "not built:", sorted(nobuild))
    live_lib.report(not refused, "wires: a wire the game would connect is never refused by the client's reach rule (centres no further than the reach plus the entities' half diagonals)",
                    f"{len(refused)} refused: {sorted(set(r.split()[0] for r in refused))}; e.g. {refused[:8]}")
    print(f"INFO circdiff: {len(loose)} placements the client passes on and the game refuses (its message then): {sorted(set(r.split()[0] for r in loose))[:6]}")


# --- picker ----------------------------------------------------------------------------------------------------
def _picker(c, hello, x, y):
    src = (REPO / "client/scripts/ui/factorio/item_picker.gd").read_text(encoding="utf-8")
    block = re.search(r"const VIRTUAL_GROUPS := \[(.*?)\n\]", src, re.S).group(1)
    client_virtual = re.findall(r'"([^"]+)"', block)
    game_order = _lua("local o = {} for n, p in pairs(prototypes.virtual_signal) do if not p.hidden and p.subgroup and p.subgroup.group.name == 'signals' then "
                      "o[#o + 1] = { n, p.subgroup.order, p.order } end end table.sort(o, function(a, b) if a[2] ~= b[2] then return a[2] < b[2] end return a[3] < b[3] end) "
                      "local l = {} for _, e in pairs(o) do l[#l + 1] = e[1] end rcon.print(table.concat(l, ' '))").split()
    live_lib.report(set(game_order) <= set(client_virtual), "picker: every virtual signal on the game's Signals tab is in the client's chooser",
                    f"{len(set(game_order) - set(client_virtual))} missing of {len(game_order)}: {sorted(set(game_order) - set(client_virtual))[:12]}")
    live_lib.report(set(client_virtual) <= set(game_order), "picker: no virtual signal the game doesn't list", str(sorted(set(client_virtual) - set(game_order))))
    live_lib.report(game_order == client_virtual, "picker: the signals are in the game's order (subgroup order, then prototype order)",
                    f"first difference at {next((i for i, (a, b) in enumerate(zip(game_order, client_virtual)) if a != b), None)}")
    hidden = set(_lua("local o = {} for n, p in pairs(prototypes.item) do if p.hidden then o[#o + 1] = n end end rcon.print(table.concat(o, ' '))").split())
    listed = set(re.findall(r'"([^"]+)"', re.search(r"const HIDDEN_ITEMS := \[(.*?)\]", src, re.S).group(1))) | set(
        re.findall(r'"([^"]+)"', re.search(r"const HIDDEN := \[(.*?)\]", src, re.S).group(1)))
    live_lib.report(hidden <= listed, "picker: the chooser leaves out every hidden item of the game", f"shown but hidden in the game: {sorted(hidden - listed)}")


# --- which special signals each place takes ----------------------------------------------------------------------
def _accept(c, hello, x, y):
    """What the game accepts for signal slots: the chooser should not offer a signal the game refuses (Each, Anything and Everything
    are not for a constant combinator, a lamp's colour signal...). Prints the matrix; fails where the client's chooser offers a
    signal a slot refuses (every slot offers all of them)."""
    out = _lua(f"""
local c = storage.f3d.puppet local s = c.surface local f = c.force local o = {{}}
local specials = {{ 'signal-each', 'signal-anything', 'signal-everything', 'signal-A', 'signal-info' }}
local function mk(n, dx, dy, d) return s.create_entity({{ name = n, position = {{ {x} + dx, {y} + dy }}, direction = d or 0, force = f }}) end
local function try(label, fn) for _, sg in pairs(specials) do local ok = pcall(fn, {{ type = 'virtual', name = sg }}) if not ok then o[#o + 1] = label .. ' refuses ' .. sg end end end
local ar, dec, cc, lamp, ins, pump, belt = mk('arithmetic-combinator', -8, -6), mk('decider-combinator', -4, -6), mk('constant-combinator', 0, -6), mk('small-lamp', 4, -6), mk('fast-inserter', 8, -6), mk('pump', -8, 6, 0), mk('transport-belt', 0, 6)
try('arith.first', function(g) ar.get_or_create_control_behavior().parameters = {{ first_signal = g, second_constant = 1, operation = '+', output_signal = {{ type = 'virtual', name = 'signal-A' }} }} end)
try('arith.second', function(g) ar.get_or_create_control_behavior().parameters = {{ first_constant = 1, second_signal = g, operation = '+', output_signal = {{ type = 'virtual', name = 'signal-A' }} }} end)
try('arith.output', function(g) ar.get_or_create_control_behavior().parameters = {{ first_signal = {{ type = 'virtual', name = 'signal-each' }}, second_constant = 1, operation = '+', output_signal = g }} end)
try('decider.first', function(g) dec.get_or_create_control_behavior().parameters = {{ conditions = {{ {{ first_signal = g, comparator = '<', constant = 1 }} }}, outputs = {{}} }} end)
try('decider.second', function(g) dec.get_or_create_control_behavior().parameters = {{ conditions = {{ {{ first_signal = {{ type = 'virtual', name = 'signal-A' }}, comparator = '<', second_signal = g }} }}, outputs = {{}} }} end)
try('decider.output', function(g) dec.get_or_create_control_behavior().parameters = {{ conditions = {{}}, outputs = {{ {{ signal = g, copy_count_from_input = true }} }} }} end)
try('constant', function(g) local b = cc.get_or_create_control_behavior() local sec = b.get_section(1) or b.add_section() sec.filters = {{ {{ value = {{ type = g.type, name = g.name, quality = 'normal', comparator = '=' }}, min = 1 }} }} end)
try('condition.first', function(g) lamp.get_or_create_control_behavior().circuit_condition = {{ first_signal = g, comparator = '<', constant = 1 }} end)
try('condition.second', function(g) lamp.get_or_create_control_behavior().circuit_condition = {{ first_signal = {{ type = 'virtual', name = 'signal-A' }}, comparator = '<', second_signal = g }} end)
try('lamp.red_signal', function(g) lamp.get_or_create_control_behavior().red_signal = g end)
try('inserter.stack_signal', function(g) ins.get_or_create_control_behavior().circuit_stack_control_signal = g end)
for _, big in pairs({{ 2147483647, 2147483648, 99999999999 }}) do
  local okc = pcall(function() lamp.get_or_create_control_behavior().circuit_condition = {{ first_signal = {{ type = 'virtual', name = 'signal-A' }}, comparator = '<', constant = big }} end)
  local oka = pcall(function() ar.get_or_create_control_behavior().parameters = {{ first_constant = big, second_constant = 1, operation = '+', output_signal = {{ type = 'virtual', name = 'signal-A' }} }} end)
  local okk = pcall(function() local b = cc.get_or_create_control_behavior() local sec = b.get_section(1) or b.add_section() sec.filters = {{ {{ value = {{ type = 'virtual', name = 'signal-A', quality = 'normal', comparator = '=' }}, min = big }} }} end)
  o[#o + 1] = string.format('range %d: condition %s arithmetic %s constant %s', big, tostring(okc), tostring(oka), tostring(okk))
end
for _, e in pairs({{ ar, dec, cc, lamp, ins, pump, belt }}) do if e then e.destroy() end end
rcon.print(table.concat(o, ';'))""")
    refused = [r for r in out.split(";") if " refuses " in r]
    ranges = [r for r in out.split(";") if r.startswith("range ")]
    print("INFO circdiff: slots that refuse a special signal (the client's chooser offers Anything / Everything / Each only where the game takes them):", refused)
    # The client's choosers: a combinator's operands (Each only), a second signal and a constant combinator's (plain), the rest every signal.
    offered = {"arith.first": {"signal-each"}, "arith.second": {"signal-each"}, "arith.output": {"signal-each"}, "decider.second": set(), "constant": set()}
    wrong = [r for r in refused if r.split(" refuses ")[1] in offered.get(r.split(" refuses ")[0], {"signal-each", "signal-anything", "signal-everything"})
             ]
    live_lib.report(not wrong, "chooser: no slot offers a signal the game refuses for it", "; ".join(wrong)[:600])
    live_lib.report(any(r.startswith("range 2147483647") and r.count("true") == 3 for r in ranges) and all(r.count("false") == 3 for r in ranges if not r.startswith("range 2147483647")),
                    "values: the game takes +-2147483647 and refuses more, so the client's boxes clamp to 32 bits", "; ".join(ranges))


# --- entities obeying what set_cc wrote -----------------------------------------------------------------------------
def _behaviour(c, hello, x, y):
    """A lamp, an inserter and a pump with an enable condition on a wire from a constant combinator, a belt reading its contents
    (hold) and a constant combinator turned off: written through `wire` and `set_cc` / `set_cb` as the client sends them."""
    print("INFO circdiff:", _power(x, y))
    fx = lambda v: int(round(v * 256))
    out = _lua(f"""
local c = storage.f3d.puppet local s = c.surface local f = c.force
local function mk(n, dx, dy, d) local e = s.create_entity({{ name = n, position = {{ {x} + dx, {y} + dy }}, direction = d or 0, force = f, raise_built = true }}) return e end
local k, lamp, ins, belt = mk('constant-combinator', -3.5, -3.5), mk('small-lamp', -1.5, -3.5), mk('inserter', 0.5, -3.5, 0), mk('transport-belt', 2.5, -3.5, 4)
local chest = mk('wooden-chest', 0.5, -4.5)
local b = k.get_or_create_control_behavior() local sec = b.get_section(1) or b.add_section()
sec.filters = {{ {{ value = {{ type = 'virtual', name = 'signal-A', quality = 'normal', comparator = '=' }}, min = 5 }} }}
belt.get_transport_line(1).insert_at_back({{ name = 'iron-plate', count = 1 }})
local o = {{}}
for _, e in pairs({{ k, lamp, ins, belt }}) do o[#o + 1] = e.unit_number .. ' ' .. e.position.x .. ' ' .. e.position.y end
rcon.print(table.concat(o, ' '))""")
    v = out.split()
    if len(v) != 12:
        live_lib.report(False, "behaviour: building", out[:300])
        return
    ents = {n: (int(v[3 * i]), float(v[3 * i + 1]), float(v[3 * i + 2]), p) for i, (n, p) in enumerate(
        (("k", "constant-combinator"), ("lamp", "small-lamp"), ("ins", "inserter"), ("belt", "transport-belt")))}
    ref = lambda n: {"u": ents[n][0], "p": c.proto_id(ents[n][3]), "x": fx(ents[n][1]), "y": fx(ents[n][2]), "mx": fx(ents[n][1]), "my": fx(ents[n][2])}
    find = ("local function ent(u) for _, e in pairs(storage.f3d.puppet.surface.find_entities_filtered({ force = storage.f3d.puppet.force, "
            "position = { %s, %s }, radius = 12 })) do if e.unit_number == u then return e end end end" % (x, y))
    for n in ("lamp", "ins", "belt"):
        c.send({"t": "wire", "k": "r", "a": ref("k"), "b": ref(n)})
    c.pump(0.6, every=hello)
    nets = _lua(f"{find} local o = {{}} for _, u in pairs({{ {ents['lamp'][0]}, {ents['ins'][0]}, {ents['belt'][0]} }}) do local n = ent(u).get_circuit_network(defines.wire_connector_id.circuit_red) o[#o + 1] = tostring(n and n.network_id) end rcon.print(table.concat(o, ' '))")
    live_lib.report("nil" not in nets.split(), "behaviour: the bridge's red wires put a lamp, an inserter and a belt on the constant combinator's network", nets)

    def cond(first, cmp, **rest):
        return dict({"first_signal": first, "comparator": cmp}, **rest)

    def status(n):
        return _lua(f"{find} local e = ent({ents[n][0]}) rcon.print(e.status == defines.entity_status.disabled_by_control_behavior and 'disabled' or 'on')")
    bad = []
    cases = [(cond(V("signal-A"), ">", constant=3), "on"), (cond(V("signal-A"), ">", constant=5), "disabled"), (cond(V("signal-A"), "≥", constant=5), "on"),
             (cond(V("signal-A"), "≤", constant=4), "disabled"), (cond(V("signal-A"), "≠", constant=5), "disabled"),
             (cond(V("signal-A"), "=", constant=5), "on"), (cond(V("signal-B"), "=", constant=0), "on"),
             (cond(V("signal-A"), ">", second_signal=V("signal-B")), "on"), (cond(V("signal-anything"), ">", constant=4), "on"),
             (cond(V("signal-everything"), "<", constant=4), "disabled"), (cond(V("signal-everything"), "<", constant=40), "on")]
    for n in ("lamp", "ins"):
        c.send({"t": "open", **{k: ref(n)[k] for k in ("u", "p", "x", "y")}})
        c.pump(0.4, every=hello)
        for cd, want in cases:
            c.send({"t": "set_cc", "u": ents[n][0], "f": {"circuit_enable_disable": 1, "circuit_condition": cd}})
            c.pump(0.35, every=hello)
            got = status(n)
            if got != want:
                bad.append(f"{n} {cd['first_signal']['name']} {cd['comparator']} {cd.get('constant', cd.get('second_signal', {}).get('name'))}: {got} not {want}")
    live_lib.report(not bad, "behaviour: a lamp's and an inserter's enable condition set through set_cc turns it off and on as the game's rules say", "; ".join(bad)[:500])
    # A belt reading its contents: hold puts the iron plate on the network.
    c.send({"t": "open", **{k: ref("belt")[k] for k in ("u", "p", "x", "y")}})
    c.pump(0.4, every=hello)
    c.send({"t": "set_cc", "u": ents["belt"][0], "f": {"read_contents": 1, "read_contents_mode": "hold"}})
    c.pump(0.5, every=hello)
    got = _lua(f"{find} local e = ent({ents['belt'][0]}) local o = {{}} for _, sg in pairs(e.get_signals(defines.wire_connector_id.circuit_red) or {{}}) do o[#o + 1] = sg.signal.name .. '=' .. sg.count end table.sort(o) rcon.print(table.concat(o, ','))")
    live_lib.report("iron-plate=1" in got, "behaviour: a belt set to read its contents (hold) puts them on the wire", got)
    c.send({"t": "close"})
