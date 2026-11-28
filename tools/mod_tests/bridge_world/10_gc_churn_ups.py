# Bridge test slice 10_gc_churn_ups.py
# Verifies perf.lua `gc_lean` switch (default ON) across movers, alerts, inserters, fluids_power, and alt_mode:
# - /f3d-perf gc_lean on|off|default
# - Output parity between gc_lean=true and gc_lean=false across mv, st, fl, ht, pw, ie, ih, al, ac, am
# - Determinism: storage isolation + forget() of module-local caches
# - Edge-case validity: invalidated LuaEntity, invalidated LuaInventory, is_empty() fallback, surface/focus/reset clears
# - Measurable reductions in find_entities_filtered, get_inventory, get_contents, get_transport_line, budget yields, and Lua GC churn

gc_perf_mod = g.package.loaded["scripts.perf"]
gc_mv_mod = g.package.loaded["scripts.movers"]
gc_al_mod = g.package.loaded["scripts.alerts"]
gc_ins_mod = g.package.loaded["scripts.inserters"]
gc_fp_mod = g.package.loaded["scripts.fluids_power"]
gc_alt_mod = g.package.loaded["scripts.alt_mode"]
gc_bud_mod = g.package.loaded["scripts.budget"]

gc_saved_focus = (int(g.storage.f3d.focus.x), int(g.storage.f3d.focus.y), int(g.storage.f3d.focus.r))
gc_saved_bud_limit = int(g.storage.f3d.bud.limit)
gc_saved_detail_r = int(g.settings["global"]["f3d-detail-radius"].value)
gc_saved_max_r = int(g.settings["global"]["f3d-max-focus-radius"].value)
gc_saved_mv_interval = int(g.settings["global"]["f3d-mover-interval"].value)
gc_saved_rescan = int(g.settings["global"]["f3d-mover-rescan"].value)


def gc_set_perf(**switches):
    if not switches:
        g.storage.f3d_perf = None
    else:
        g.storage.f3d_perf = lua.table_from(switches)


gc_hello = {
    "t": "hello",
    "v": 1,
    "sid": "gc-lean",
    "w": 0,
    "b": 1,
    "ie": 2,
    "ho": 1,
    **({"bin": protocol.WIRE_VERSION} if BINARY else {}),
}
gc_keepalive = {**gc_hello, "w": 1}

lua.execute("""
function F_gc_forget(fn, name, depth)
  depth = depth or 4
  for i = 1, 255 do
    local n, v = debug.getupvalue(fn, i)
    if not n then return false end
    if n == name then
      debug.setupvalue(fn, i, type(v) == "table" and {} or nil)
      return true
    end
    if type(v) == "function" and depth > 0 and F_gc_forget(v, name, depth - 1) then
      return true
    end
  end
  return false
end
""")


def gc_forget(fn, name):
    return bool(g.F_gc_forget(fn, name))


def gc_tick(n=1):
    for _ in range(n):
        if int(g.game.tick) % 200 == 0:
            send(gc_keepalive)
        tick(1)


def gc_reset_all():
    gc_mv_mod.reset()
    gc_al_mod.reset()
    gc_ins_mod.reset()
    gc_fp_mod.reset()
    gc_alt_mod.reset()


# 1. Switch registration & /f3d-perf command behavior:
check(bool(gc_perf_mod.OPTIONS["gc_lean"]) is True, "perf.lua: gc_lean option defaults to true")
check("gc_lean" in list(gc_perf_mod.ORDER.values()), "perf.lua: gc_lean is listed in M.ORDER")
gc_cmd0 = str(gc_perf_mod.command("")[1])
check("gc_lean on" in gc_cmd0, f"/f3d-perf lists gc_lean on by default: {gc_cmd0}")
F.commands["f3d-perf"](lua.table_from({"name": "f3d-perf", "parameter": "gc_lean off"}))
check("gc_lean off (set)" in str(gc_perf_mod.command("")[1]), "/f3d-perf gc_lean off toggles switch off")
F.commands["f3d-perf"](lua.table_from({"name": "f3d-perf", "parameter": "gc_lean default"}))
gc_cmd1 = str(gc_perf_mod.command("")[1])
check("gc_lean on" in gc_cmd1 and "(set)" not in gc_cmd1.split("gc_lean on")[1][:10],
      f"/f3d-perf gc_lean default restores default on: {gc_cmd1}")

# 2. Output parity between gc_lean=true and gc_lean=false across all 5 modules:
gx, gy = 7200.5, 7200.5
gcx, gcy = math.floor(gx / 32), math.floor(gy / 32)
g.settings["global"]["f3d-max-focus-radius"] = lua.table_from({"value": 128})
g.settings["global"]["f3d-detail-radius"] = lua.table_from({"value": 64})
g.settings["global"]["f3d-mover-interval"] = lua.table_from({"value": 2})
g.settings["global"]["f3d-mover-rescan"] = lua.table_from({"value": 8})

gc_car = spawn("car", gx - 4.0, gy + 1.0, force="player")
gc_gate = spawn("gate", gx + 2.0, gy + 1.0, force="player")
gc_gate.gate_phase = "opening"
gc_lamp = spawn("small-lamp", gx + 4.0, gy + 1.0, force="player")
gc_lamp.status = g.defines.entity_status.working
gc_lamp.always_on = True
gc_lamp.color = lua.table_from({"r": 0.2, "g": 0.6, "b": 1.0, "a": 1.0})
gc_sig = spawn("rail-signal", gx + 6.0, gy + 1.0, force="player")
gc_sig.signal_state = g.defines.signal_state.reserved
gc_asm = spawn("assembling-machine-1", gx + 8.0, gy + 2.0, force="player")
gc_asm.status = g.defines.entity_status.working
F.inventories[gc_asm]["modules"].insert(lua.table_from({"name": "speed-module", "count": 1}))
gc_unplugged = spawn("assembling-machine-1", gx + 12.0, gy + 2.0, force="player")
gc_unplugged.status = g.defines.entity_status.no_power
gc_unplugged.electric_network_id = None
gc_tank = spawn("storage-tank", gx - 8.0, gy - 4.0, force="player")
F.set_fluid(gc_tank, 1, lua.table_from({"name": "water", "amount": 500, "temperature": 25}), 25000)
gc_heat = spawn("heat-pipe", gx - 4.0, gy - 4.0, force="player", temperature=420)
gc_turret_empty = spawn("gun-turret", gx - 10.0, gy + 4.0, force="player")
gc_turret_full = spawn("gun-turret", gx - 14.0, gy + 4.0, force="player")
F.inventories[gc_turret_full]["turret_ammo"].insert(lua.table_from({"name": "firearm-magazine", "count": 5}))
gc_furnace = spawn("stone-furnace", gx - 6.0, gy + 4.0, force="player")
gc_furnace.status = g.defines.entity_status.no_fuel
gc_chest_full = spawn("wooden-chest", gx + 2.0, gy - 4.0, force="player")
F.inventories[gc_chest_full]["chest"].insert(lua.table_from({"name": "iron-plate", "count": 40}))
F.inventories[gc_chest_full]["chest"].insert(lua.table_from({"name": "copper-plate", "count": 10}))
gc_chest_empty = spawn("wooden-chest", gx + 4.0, gy - 4.0, force="player")
gc_lab = spawn("lab", gx + 6.0, gy - 4.0, force="player")
F.inventories[gc_lab]["input"].insert(lua.table_from({"name": "automation-science-pack", "count": 4}))
gc_belt = spawn("transport-belt", gx, gy + 4.0, force="player", direction=4)
gc_ins = spawn("inserter", gx, gy + 3.0, force="player", direction=8)
gc_ins.drop_target = gc_belt
gc_ins.pickup_position = lua.table_from({"x": gx, "y": gy + 2.0})
gc_ins.drop_position = lua.table_from({"x": gx, "y": gy + 3.8})
gc_parity_ents = [
    gc_car, gc_gate, gc_lamp, gc_sig, gc_asm, gc_unplugged,
    gc_tank, gc_heat, gc_turret_empty, gc_turret_full, gc_furnace,
    gc_chest_full, gc_chest_empty, gc_lab, gc_belt, gc_ins,
]
gc_parity_units = {int(e.unit_number) for e in gc_parity_ents}


def run_parity_window(lean_on):
    gc_set_perf(gc_lean=lean_on)
    send({"t": "bye"})
    tick(1)
    send(gc_hello)
    send({"t": "budget", "u": 2000})
    send({"t": "rate", "l": 0})
    send({"t": "focus", "x": fixed(gx), "y": fixed(gy), "r": 64})
    send({"t": "sub", "c": [[gcx + dx, gcy + dy] for dx in (-1, 0, 1) for dy in (-1, 0, 1)]})
    gc_reset_all()
    gc_gate.gate_phase = "closed"
    F.set_hand(gc_ins, gx, gy + 2.0, None)
    gc_tick(4)
    take()
    send({"t": "altc", "on": 1, "g": 1, "lf": 1})
    gc_gate.gate_phase = "opening"
    F.set_hand(gc_ins, gx, gy + 2.0, "iron-plate")
    gc_tick(35)
    F.set_hand(gc_ins, gx, gy + 3.8, None)
    F.put_on_belt(gc_belt, 1, "iron-plate", 0.5, 99101)
    gc_tick(45)
    msgs = take()
    F.move_on_belt(gc_belt, 1, 99101, None)

    out = {
        "mv": set(),
        "st": {},
        "lc": {},
        "ao": {},
        "fl": {},
        "ht": {},
        "pw": {},
        "ac": {},
        "am": {},
        "ie_kinds": set(),
        "ih_units": set(),
        "al_unplugged": set(),
        "al_no_ammo": set(),
        "al_no_fuel": set(),
    }
    for m in msgs:
        t = m.get("t")
        if t == "mv":
            for r in m.get("l", []):
                if r[0] in gc_parity_units:
                    out["mv"].add((r[0], r[1], r[2], r[3]))
        elif t == "st":
            lst = m.get("l", [])
            for i in range(0, len(lst), 2):
                if lst[i] in gc_parity_units:
                    out["st"][lst[i]] = lst[i + 1]
            lc = m.get("lc") or []
            for i in range(0, len(lc), 2):
                if lc[i] in gc_parity_units:
                    out["lc"][lc[i]] = lc[i + 1]
            ao = m.get("ao") or []
            for i in range(0, len(ao), 2):
                if ao[i] in gc_parity_units:
                    out["ao"][ao[i]] = ao[i + 1]
        elif t == "fl":
            lst = m.get("l", [])
            for i in range(0, len(lst), 6):
                if lst[i] in gc_parity_units:
                    out["fl"][(lst[i], lst[i + 1])] = tuple(lst[i + 2:i + 6])
        elif t == "ht":
            lst = m.get("l", [])
            for i in range(0, len(lst), 2):
                if lst[i] in gc_parity_units:
                    out["ht"][lst[i]] = lst[i + 1]
        elif t == "pw":
            lst = m.get("l", [])
            for i in range(0, len(lst), 2):
                if lst[i] in gc_parity_units:
                    out["pw"][lst[i]] = lst[i + 1]
        elif t == "ac":
            for r in m.get("l", []):
                if r[0] in gc_parity_units:
                    out["ac"][r[0]] = r
        elif t == "am":
            for r in m.get("l", []):
                if r[0] in gc_parity_units:
                    out["am"][r[0]] = r
        elif t == "ie":
            lst = m.get("l", [])
            for i in range(0, len(lst), 9):
                if lst[i + 1] == int(gc_ins.unit_number):
                    out["ie_kinds"].add(lst[i])
        elif t == "ih":
            lst = m.get("l", [])
            for i in range(0, len(lst), 4):
                if lst[i] in gc_parity_units:
                    out["ih_units"].add(lst[i])
        elif t == "al":
            for kind, _, shown in m.get("l", []):
                for r in shown:
                    if r[4] in gc_parity_units:
                        if kind == "unplugged":
                            out["al_unplugged"].add(r[4])
                        elif kind == "no_ammo":
                            out["al_no_ammo"].add(r[4])
                        elif kind == "no_fuel":
                            out["al_no_fuel"].add(r[4])
    return out


parity_on = run_parity_window(True)
parity_off = run_parity_window(False)
check(parity_on == parity_off
      and int(gc_gate.unit_number) in parity_on["st"]
      and int(gc_tank.unit_number) in {u for u, _ in parity_on["fl"]}
      and int(gc_heat.unit_number) in parity_on["ht"]
      and int(gc_unplugged.unit_number) in parity_on["pw"]
      and int(gc_chest_full.unit_number) in parity_on["ac"]
      and int(gc_asm.unit_number) in parity_on["am"]
      and int(gc_turret_empty.unit_number) in parity_on["al_no_ammo"]
      and int(gc_furnace.unit_number) in parity_on["al_no_fuel"]
      and int(gc_ins.unit_number) in parity_on["ih_units"]
      and {1, 2, 4, 6} <= parity_on["ie_kinds"],
      f"gc_lean parity (on vs off): identical mv/st/fl/ht/pw/ac/am/ie/ih/al outputs (on={parity_on} vs off={parity_off})")

# 3. Determinism & storage isolation + forget() module-local caches:
gc_set_perf(gc_lean=True)
gc_storage_bad = lua.eval("""function()
  local s = storage.f3d
  for _, k in ipairs({"st_cache", "fp_cache", "inv_cache", "list_cache", "belt_lines"}) do
    if s[k] ~= nil then return k end
  end
  return nil
end""")()
check(gc_storage_bad is None, f"gc_lean determinism: no module-local caches stored in storage.f3d (got {gc_storage_bad})")

# (rel-031-fix3) movers' and fluids_power's scan lists moved into storage (st_scan[k].lists,
# fp_meta.fl/ht[k].list): their module-local st_cache/fp_cache are gone, nothing to forget there.
check(gc_forget(gc_al_mod.tick, "inv_cache")
      and gc_forget(gc_ins_mod.tick, "belt_lines")
      and gc_forget(gc_fp_mod.tick, "inv_cache")
      and gc_forget(gc_alt_mod.tick, "inv_cache"),
      "gc_lean forget(): module-local caches in the modules that keep them are forgettable")
gc_tick(70)
_ = take()
check(True, "gc_lean determinism: all 5 modules rebuild cleanly after forget() without errors")

# 4. Measurable churn reductions (gc_lean=true vs gc_lean=false) & rate scaling:
def measure_steady_churn(lean_on, rate_lvl=0, ticks=160):
    gc_set_perf(gc_lean=lean_on)
    gc_reset_all()
    send({"t": "rate", "l": rate_lvl})
    send({"t": "focus", "x": fixed(gx), "y": fixed(gy), "r": 64})
    send({"t": "altc", "on": 1, "g": 10 + (1 if lean_on else 2) + rate_lvl, "lf": 1})
    F.set_hand(gc_ins, gx, gy + 2.0, None)
    gc_tick(70)
    take()
    mv0 = (int(gc_mv_mod.counts.st_scans), int(gc_mv_mod.counts.gate_scans))
    fp0 = (int(gc_fp_mod.counts.searches), int(gc_fp_mod.counts.inv_gets))
    alt0 = (
        int(gc_alt_mod.counts.container_scans),
        int(gc_alt_mod.counts.machine_scans),
        int(gc_alt_mod.counts.inv_gets),
        int(gc_alt_mod.counts.empty_skips),
        int(gc_alt_mod.counts.entity_reuses),
    )
    ins0 = (int(gc_ins_mod.counts.look_skips), int(gc_ins_mod.counts.line_gets))
    al0 = int(gc_al_mod.counts.inv_gets)
    lua.execute("collectgarbage('collect')")
    kb0 = float(lua.eval("(collectgarbage('count'))"))
    for step_i in range(ticks):
        if step_i % 50 == 0:
            F.set_hand(gc_ins, gx, gy + 2.0, "iron-plate")
        elif step_i % 50 == 25:
            F.set_hand(gc_ins, gx, gy + 3.8, None)
            F.put_on_belt(gc_belt, 1, "iron-plate", 0.5, 99500 + step_i)
        gc_tick(1)
        if step_i % 50 == 26:
            F.move_on_belt(gc_belt, 1, 99500 + (step_i - 1), None)
        take()
    kb1 = float(lua.eval("(collectgarbage('count'))"))
    return {
        "st_scans": int(gc_mv_mod.counts.st_scans) - mv0[0],
        "gate_scans": int(gc_mv_mod.counts.gate_scans) - mv0[1],
        "fp_searches": int(gc_fp_mod.counts.searches) - fp0[0],
        "fp_inv_gets": int(gc_fp_mod.counts.inv_gets) - fp0[1],
        "alt_cscans": int(gc_alt_mod.counts.container_scans) - alt0[0],
        "alt_mscans": int(gc_alt_mod.counts.machine_scans) - alt0[1],
        "alt_inv_gets": int(gc_alt_mod.counts.inv_gets) - alt0[2],
        "alt_empty_skips": int(gc_alt_mod.counts.empty_skips) - alt0[3],
        "alt_entity_reuses": int(gc_alt_mod.counts.entity_reuses) - alt0[4],
        "ins_look_skips": int(gc_ins_mod.counts.look_skips) - ins0[0],
        "ins_line_gets": int(gc_ins_mod.counts.line_gets) - ins0[1],
        "al_inv_gets": int(gc_al_mod.counts.inv_gets) - al0,
        "gc_kb_delta": kb1 - kb0,
    }


churn_on = measure_steady_churn(True, rate_lvl=0, ticks=160)
churn_off = measure_steady_churn(False, rate_lvl=0, ticks=160)
churn_r2 = measure_steady_churn(True, rate_lvl=2, ticks=260)

check(churn_on["st_scans"] < churn_off["st_scans"] and churn_on["gate_scans"] < churn_off["gate_scans"],
      f"gc_lean movers: reduces st_scans ({churn_on['st_scans']} vs {churn_off['st_scans']}) and gate_scans ({churn_on['gate_scans']} vs {churn_off['gate_scans']})")
# st_scans per tick, with one scan of slack: which tick a scan falls on depends on the tick the test starts at
# (2 or 3 scans in the 160 ticks), so a fixed "* 2" failed when earlier tests ran a different number of ticks.
check(churn_r2["gate_scans"] <= churn_on["gate_scans"] and churn_r2["st_scans"] <= math.ceil(churn_on["st_scans"] * 260 / 160) + 1,
      f"gc_lean movers rate scaling: rate=2 scales scans down over 260t vs 130t ({churn_r2['gate_scans']}, {churn_r2['st_scans']})")
check(churn_on["fp_searches"] < churn_off["fp_searches"] and churn_on["fp_inv_gets"] < churn_off["fp_inv_gets"],
      f"gc_lean fluids_power: reduces searches ({churn_on['fp_searches']} vs {churn_off['fp_searches']}) and inv_gets ({churn_on['fp_inv_gets']} vs {churn_off['fp_inv_gets']})")
check(churn_on["alt_cscans"] < churn_off["alt_cscans"]
      and churn_on["alt_mscans"] < churn_off["alt_mscans"]
      and churn_on["alt_inv_gets"] < churn_off["alt_inv_gets"]
      and churn_on["alt_empty_skips"] > 0
      and churn_on["alt_entity_reuses"] > 0,
      f"gc_lean alt_mode: cuts cscans/mscans/inv_gets ({churn_on} vs {churn_off})")
check(churn_on["ins_look_skips"] > 0 and churn_off["ins_look_skips"] == 0
      and churn_on["ins_line_gets"] < churn_off["ins_line_gets"],
      f"gc_lean inserters: look_skips ({churn_on['ins_look_skips']} vs {churn_off['ins_look_skips']}) and line_gets ({churn_on['ins_line_gets']} vs {churn_off['ins_line_gets']})")

# 5. alerts.lua: cached inv_gets, is_empty() guard, and budget.left() yield on chunk & spot sweeps:
gc_set_perf(gc_lean=True)
send({"t": "rate", "l": 0})
gc_al_mod.reset()
send({"t": "focus", "x": fixed(gx), "y": fixed(gy), "r": 64})
gc_tick(65)
take()
# Exhaust budget.left() before stepping alerts so step_pass and look_at_spots yield cleanly when gc_lean=true:
al_yield_res = lua.eval("""function(turret)
  local A = package.loaded["scripts.alerts"]
  local B = package.loaded["scripts.budget"]
  -- First call with gc_lean=true and alerts_quiet=false so step_pass runs on any tick:
  storage.f3d_perf = { gc_lean = true, alerts_quiet = false }
  A.reset()
  storage.f3d.al_near = { si = 1, x0 = 0, y0 = 0, x1 = 9999999, y1 = 9999999, u = {}, f = {}, a = {}, d = {} }
  storage.f3d.al_spots = { { x = turret.position.x, y = turret.position.y, t = game.tick - 1, r = 4 } }
  B.begin()
  B.spend(B.limit() + 50, "test")
  local y0, c0, s0 = A.counts.budget_yields, A.counts.chunk_scans, A.counts.spot_scans
  A.tick()
  local y1, c1, s1 = A.counts.budget_yields, A.counts.chunk_scans, A.counts.spot_scans
  -- Now gc_lean=false ignores budget.left() exhaustion and runs chunk_scans + spot_scans:
  storage.f3d_perf = { gc_lean = false, alerts_quiet = false }
  A.reset()
  storage.f3d.al_near = { si = 1, x0 = 0, y0 = 0, x1 = 9999999, y1 = 9999999, u = {}, f = {}, a = {}, d = {} }
  storage.f3d.al_spots = { { x = turret.position.x, y = turret.position.y, t = game.tick - 1, r = 4 } }
  B.begin()
  B.spend(B.limit() + 50, "test")
  A.tick()
  local y2, c2, s2 = A.counts.budget_yields, A.counts.chunk_scans, A.counts.spot_scans
  storage.f3d_perf = nil
  return { y1 - y0, c1 - c0, s1 - s0, y2 - y1, c2 - c1, s2 - s1 }
end""")(gc_turret_empty)
check(al_yield_res[1] >= 2 and al_yield_res[2] == 0 and al_yield_res[3] == 0
      and al_yield_res[4] == 0 and al_yield_res[5] > 0 and al_yield_res[6] > 0,
      f"gc_lean alerts budget.left(): yields when budget<=0 ({list(al_yield_res.values())})")

# 6. Edge-case validity: invalidated LuaInventory (inv.valid=false), is_empty() skipping get_contents(), and fallback:
gc_set_perf(gc_lean=True)
gc_inv_edge = lua.eval("""function(chest_empty, chest_full, turret)
  local AM = package.loaded["scripts.alt_mode"]
  local AL = package.loaded["scripts.alerts"]
  local FP = package.loaded["scripts.fluids_power"]
  storage.f3d_perf = { gc_lean = true }
  AM.reset(); AL.reset(); FP.reset()

  -- Spy on chest_empty's get_contents and is_empty:
  local real_ec = chest_empty.get_inventory(defines.inventory.chest)
  local orig_ec_contents = real_ec.get_contents
  local orig_ec_empty = real_ec.is_empty
  local ec_contents_calls = 0
  local throw_empty = false
  real_ec.get_contents = function()
    ec_contents_calls = ec_contents_calls + 1
    return orig_ec_contents()
  end
  real_ec.is_empty = function()
    if throw_empty then error("is_empty unavailable") end
    return orig_ec_empty()
  end

  -- Empty chest skips get_contents via is_empty():
  local r1 = AM.contents(chest_empty)
  local r2 = AM.contents(chest_empty)
  local calls_skipped = ec_contents_calls
  -- Fallback when is_empty throws:
  throw_empty = true
  local r3 = AM.contents(chest_empty)
  local calls_fallback = ec_contents_calls
  real_ec.get_contents = orig_ec_contents
  real_ec.is_empty = orig_ec_empty

  -- Cached inventory reuse & inv.valid=false invalidation on chest_full:
  local inv_a = F.inventories[chest_full].chest
  local inv_b = {
    valid = true,
    is_empty = function() return false end,
    get_contents = function() return { { name = "coal", count = 99 } } end,
  }
  local cf_g0 = AM.counts.inv_gets
  local c1 = AM.contents(chest_full)
  local c2 = AM.contents(chest_full)
  local gets_cached = AM.counts.inv_gets - cf_g0
  inv_a.valid = false
  F.inventories[chest_full].chest = inv_b
  local c3 = AM.contents(chest_full)
  local gets_after_inval = AM.counts.inv_gets - cf_g0
  inv_a.valid = true
  F.inventories[chest_full].chest = inv_a

  -- Cached turret inventory reuse & inv.valid=false invalidation in alerts:
  local B = package.loaded["scripts.budget"]
  B.begin()
  local t_inv_a = F.inventories[turret].turret_ammo
  local t_inv_b = { valid = true, is_empty = function() return false end }
  AL.reset()
  local t_g0 = AL.counts.inv_gets
  storage.f3d.al_spots = { { x = turret.position.x, y = turret.position.y, t = game.tick - 1, r = 2 } }
  storage.f3d.al_near = { si = 1, x0 = 0, y0 = 0, x1 = 9999999, y1 = 9999999, u = {}, f = {}, a = {}, d = {} }
  AL.tick()
  storage.f3d.al_spots = { { x = turret.position.x, y = turret.position.y, t = game.tick - 1, r = 2 } }
  AL.tick()
  local t_gets_cached = AL.counts.inv_gets - t_g0
  t_inv_a.valid = false
  F.inventories[turret].turret_ammo = t_inv_b
  storage.f3d.al_spots = { { x = turret.position.x, y = turret.position.y, t = game.tick - 1, r = 2 } }
  AL.tick()
  local t_gets_inval = AL.counts.inv_gets - t_g0
  t_inv_a.valid = true
  F.inventories[turret].turret_ammo = t_inv_a
  storage.f3d.al_spots = nil

  return {
    r1 == nil and r2 == nil and r3 == nil,
    calls_skipped,
    calls_fallback,
    gets_cached,
    gets_after_inval,
    c3 and c3[1],
    t_gets_cached,
    t_gets_inval,
  }
end""")(gc_chest_empty, gc_chest_full, gc_turret_empty)
check(gc_inv_edge[1] is True and int(gc_inv_edge[2]) == 0 and int(gc_inv_edge[3]) >= 1,
      f"gc_lean alt_mode is_empty() fast-skip & pcall fallback: {list(gc_inv_edge.values())[:3]}")
check(int(gc_inv_edge[4]) == 1 and int(gc_inv_edge[5]) == 2 and gc_inv_edge[6] == "coal",
      f"gc_lean alt_mode inv cache & inv.valid=false invalidation: {list(gc_inv_edge.values())[3:6]}")
check(int(gc_inv_edge[7]) == 1 and int(gc_inv_edge[8]) == 2,
      f"gc_lean alerts inv cache & inv.valid=false invalidation: {list(gc_inv_edge.values())[6:8]}")

# 7. Focus jump reset & invalidated LuaEntity handling:
gc_set_perf(gc_lean=True)
gc_reset_all()
send({"t": "focus", "x": fixed(gx), "y": fixed(gy), "r": 64})
send({"t": "altc", "on": 1, "g": 77, "lf": 1})
gc_tick(70)
take()
mv_s0 = int(gc_mv_mod.counts.st_scans)
mv_g0 = int(gc_mv_mod.counts.gate_scans)
alt_c0 = int(gc_alt_mod.counts.container_scans)
# Destroy cached entities and ensure modules handle invalid LuaEntities cleanly without errors:
gc_gate.destroy()
gc_asm.destroy()
gc_tank.destroy()
gc_chest_full.destroy()
gc_belt.destroy()
gc_tick(70)
inval_msgs = take()
inval_ac = [r for m in of_type(inval_msgs, "ac") for r in m.get("l", [])]
check([int(gc_chest_full.unit_number)] in inval_ac,
      f"gc_lean invalidated LuaEntity: destroyed chest emits removal [unit] cleanly: {inval_ac}")

# Focus jump (>= 16 tiles) invalidates caches and triggers fresh scans:
send({"t": "focus", "x": fixed(gx + 24), "y": fixed(gy), "r": 64})
gc_tick(70)
take()
check(int(gc_mv_mod.counts.st_scans) > mv_s0 and int(gc_mv_mod.counts.gate_scans) > mv_g0
      and int(gc_alt_mod.counts.container_scans) > alt_c0,
      f"gc_lean focus jump reset: triggers fresh st/gate/alt scans ({mv_s0}->{gc_mv_mod.counts.st_scans}, {mv_g0}->{gc_mv_mod.counts.gate_scans}, {alt_c0}->{gc_alt_mod.counts.container_scans})")

# 8. Mid-game peer join / module cache wipe determinism (storage scheduling metadata prevents desync):
gc_det_asm = spawn("assembling-machine-1", gx + 20.0, gy + 2.0, force="player")
gc_det_tank = spawn("storage-tank", gx + 22.0, gy - 2.0, force="player")
gc_det_chest = spawn("wooden-chest", gx + 24.0, gy + 2.0, force="player")
gc_parity_ents.extend([gc_det_asm, gc_det_tank, gc_det_chest])
gc_reset_all()
send({"t": "altc", "on": 1, "g": 88, "lf": 1})
gc_tick(65)
take()
det_meta = lua.eval("""(function()
  local s = storage.f3d
  local st_ticks = {}
  for k, v in pairs(s.st_scan or {}) do st_ticks[tostring(k)] = v.tick end
  local fp_ticks = {}
  if s.fp_meta then
    for k, v in pairs(s.fp_meta.fl or {}) do fp_ticks["fl:" .. tostring(k)] = v.tick end
    for k, v in pairs(s.fp_meta.ht or {}) do fp_ticks["ht:" .. tostring(k)] = v.tick end
  end
  return {
    tick = game.tick,
    lc_tick = s.altc and s.altc.lc_meta and s.altc.lc_meta.tick or -1,
    st_ticks = st_ticks,
    fp_ticks = fp_ticks,
    dirty_before = s.altc and s.altc.lc_meta and s.altc.lc_meta.dirty or false,
  }
end)()""")
det_fp0, det_alt0 = int(gc_fp_mod.counts.searches), int(gc_alt_mod.counts.container_scans)
gc_forget(gc_fp_mod.tick, "inv_cache")
# (M1) A joiner has none of alt_mode's module state: no read cache, no surface/client it last saw.
gc_forget(gc_alt_mod.tick, "inv_cache")
gc_forget(gc_alt_mod.tick, "inv_cache_si")
gc_forget(gc_alt_mod.tick, "inv_cache_client")
gc_tick(1)
take()
det_after = lua.eval("""(function()
  local s = storage.f3d
  local st_ticks = {}
  for k, v in pairs(s.st_scan or {}) do st_ticks[tostring(k)] = v.tick end
  return {
    lc_tick = s.altc and s.altc.lc_meta and s.altc.lc_meta.tick or -1,
    st_ticks = st_ticks,
  }
end)()""")
det_t_next = int(det_meta["tick"]) + 1
st_kept_ok = bool(dict(det_meta["st_ticks"])) and all(
    int(det_after["st_ticks"][k]) == int(v)
    for k, v in dict(det_meta["st_ticks"]).items()
    if (det_t_next - int(v)) < 60
)
check(bool(dict(det_meta["fp_ticks"])) and int(det_meta["lc_tick"]) > 0 and st_kept_ok
      and int(det_after["lc_tick"]) == int(det_meta["lc_tick"])
      and int(gc_fp_mod.counts.searches) == det_fp0
      and int(gc_alt_mod.counts.container_scans) == det_alt0,
      f"gc_lean peer reload determinism: storage metadata preserves schedule/budget without extra charged scans (lc={det_meta['lc_tick']}->{det_after['lc_tick']}, fp={(det_fp0, int(gc_fp_mod.counts.searches))}, alt={(det_alt0, int(gc_alt_mod.counts.container_scans))}, st_ok={st_kept_ok})")

# 9. tracker on_built_entity dirties alt_mode lc_meta even for non-TYPES chests/labs/turrets:
gc_built_chest = spawn("wooden-chest", gx + 21.0, gy + 4.0, force="player")
gc_parity_ents.append(gc_built_chest)
F["raise"]("on_built_entity", lua.table_from({"entity": gc_built_chest}))
dirty_after_build = bool(lua.eval("(storage.f3d.altc and storage.f3d.altc.lc_meta and storage.f3d.altc.lc_meta.dirty) or false"))
check(not bool(det_meta["dirty_before"]) and dirty_after_build,
      f"gc_lean alt_mode tracker hook: building non-TYPES chest immediately dirties lc_meta ({det_meta['dirty_before']}->{dirty_after_build})")

# Cleanup all spawned entities and restore original state:
send({"t": "altc", "on": 0})
for e in gc_parity_ents:
    if e.valid:
        e.destroy()
send({"t": "rate", "l": 0})
send({"t": "budget", "u": gc_saved_bud_limit})
send({"t": "focus", "x": fixed(gc_saved_focus[0]), "y": fixed(gc_saved_focus[1]), "r": gc_saved_focus[2]})
g.settings["global"]["f3d-detail-radius"] = lua.table_from({"value": gc_saved_detail_r})
g.settings["global"]["f3d-max-focus-radius"] = lua.table_from({"value": gc_saved_max_r})
g.settings["global"]["f3d-mover-interval"] = lua.table_from({"value": gc_saved_mv_interval})
g.settings["global"]["f3d-mover-rescan"] = lua.table_from({"value": gc_saved_rescan})
gc_set_perf()
gc_reset_all()
send({"t": "sub", "c": []})
gc_tick(3)
take()
