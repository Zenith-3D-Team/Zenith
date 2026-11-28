# Bridge test slice 11_two_peer_determinism.py
# Multiplayer determinism (rel-031-fix2, M1 + N3): every peer replays the same ticks and packets, so
# what the bridge writes in `storage` must depend only on storage and events. A peer that joins
# mid-game loads storage from the save but none of the modules' local state (caches, lists).
#
# Here peer A plays with Alt-mode on; at tick k a second module set (peer B: control.lua and every
# script loaded anew, so all module locals are fresh) starts from a deep copy of A's storage. Both
# then run the same ticks and packets in lockstep over the same fake world, and their storage must
# stay identical (deep compare, LuaObjects by identity). Before the fix, alt_mode's gc_lean cache
# wiped `altc.lc_meta` on B only (and B's repopulated list was in another order), and
# fluids_power/movers set a storage `dirty` flag from a module-local list holding a destroyed entity.
# (rel-031-fix3) Entities made with no event after B starts (a mod's create_entity without raise_built):
# movers' and fluids_power's scan lists were module state that B searched afresh (finding them) while
# A kept its older list until the next rescan; those lists are now in storage too.
#
# Limits: both peers get pairs/next in key order (below), so module-local keyed tables iterate the same
# on both: an order-dependent storage write from one of those would be hidden here (none known:
# inv_cache is only pruned, the others are arrays or single-key). Both peers share one fake world, and
# A ticks first each tick.

fresh_world()

lua.execute(r"""
-- Factorio's Lua iterates tables in an order every peer shares, a loaded save's too; stock Lua's
-- depends on each table's history, so a copy iterates otherwise. Both peers here get pairs/next in
-- key order (loaded before either peer's modules, which may keep them as locals).
local raw_next = next
local function kcmp(a, b)
  local ta, tb = type(a), type(b)
  if ta ~= tb then
    return ta < tb
  end
  if ta == "number" or ta == "string" then
    return a < b
  end
  if ta == "boolean" then
    return (not a) and b
  end
  return tostring(a) < tostring(b)
end
local function sorted_keys(t)
  local ks = {}
  for k in raw_next, t do
    ks[#ks + 1] = k
  end
  table.sort(ks, kcmp)
  return ks
end
function next(t, k)
  if raw_next(t) == nil then
    return nil
  end
  local ks = sorted_keys(t)
  local i = 0
  if k ~= nil then
    for j = 1, #ks do
      if rawequal(ks[j], k) then
        i = j
        break
      end
    end
  end
  local nk = ks[i + 1]
  if nk == nil then
    return nil
  end
  return nk, rawget(t, nk)
end
function pairs(t)
  local mt = getmetatable(t)
  if mt and mt.__pairs then
    return mt.__pairs(t)
  end
  local ks = sorted_keys(t)
  local i = 0
  return function()
    while true do
      i = i + 1
      local k = ks[i]
      if k == nil then
        return nil
      end
      local v = rawget(t, k)
      if v ~= nil then
        return k, v
      end
    end
  end, t, nil
end

-- A second set of the bridge's modules, as a joining peer has them: control.lua run again with every
-- scripts.* module loaded fresh. Returns its handlers and modules; peer A's are put back.
function F_load_peer(control_path)
  local saved = {}
  for k, v in pairs(package.loaded) do
    if type(k) == "string" and k:sub(1, 8) == "scripts." then
      saved[k] = v
    end
  end
  for k in pairs(saved) do
    package.loaded[k] = nil
  end
  local function req(name)
    local v = package.loaded[name]
    if v ~= nil then
      return v
    end
    for _, searcher in ipairs(package.searchers) do
      local loader, extra = searcher(name)
      if type(loader) == "function" then
        local r = loader(name, extra)
        if package.loaded[name] == nil then
          package.loaded[name] = r == nil and true or r
        end
        return package.loaded[name]
      end
    end
    error("F_load_peer: no module " .. tostring(name))
  end
  local old_require = require
  local old_handlers, old_on_init, old_on_load, old_on_config = F.handlers, F.on_init, F.on_load, F.on_config
  local old_commands, old_command, old_zenith = F.commands, F.command, F.remote.zenith
  F.handlers, F.commands, F.remote.zenith = {}, {}, nil
  require = req
  assert(loadfile(control_path))()
  require = old_require
  local peer = { handlers = F.handlers, on_load = F.on_load, loaded = {} }
  for k, v in pairs(package.loaded) do
    if type(k) == "string" and k:sub(1, 8) == "scripts." then
      peer.loaded[k] = v
    end
  end
  peer.loaded["scripts.barrier"].rethrow = true
  for k in pairs(peer.loaded) do
    package.loaded[k] = saved[k]
  end
  F.handlers, F.on_init, F.on_load, F.on_config = old_handlers, old_on_init, old_on_load, old_on_config
  F.commands, F.command, F.remote.zenith = old_commands, old_command, old_zenith
  return peer
end

-- Storage copied as a save/load would: plain tables anew (shared ones stay shared), LuaObjects kept.
local function is_object(v)
  return type(v) == "table" and getmetatable(v) ~= nil
end
function F_deep_copy(v, memo)
  memo = memo or {}
  if type(v) ~= "table" or is_object(v) then
    return v
  end
  if memo[v] then
    return memo[v]
  end
  local out = {}
  memo[v] = out
  for k, x in pairs(v) do
    out[F_deep_copy(k, memo)] = F_deep_copy(x, memo)
  end
  return out
end

-- Every leaf of storage as "path = value" lines, sorted (LuaObjects by identity).
local function key_str(k)
  if is_object(k) then
    return "<obj " .. tostring(k) .. ">"
  elseif type(k) == "number" then
    return string.format("%.17g", k)
  end
  return type(k) .. ":" .. tostring(k)
end
local function val_str(v)
  if is_object(v) then
    return "<obj " .. tostring(v) .. ">"
  elseif type(v) == "number" then
    return string.format("%.17g", v)
  end
  return type(v) .. ":" .. tostring(v)
end
function F_flatten(root)
  local lines = {}
  local stack = {}
  local function walk(t, path)
    if stack[t] then
      lines[#lines + 1] = path .. " = <cycle>"
      return
    end
    stack[t] = true
    local any = false
    for k, v in pairs(t) do
      any = true
      local p = path .. "/" .. key_str(k)
      if type(v) == "table" and not is_object(v) then
        walk(v, p)
      else
        lines[#lines + 1] = p .. " = " .. val_str(v)
      end
    end
    if not any then
      lines[#lines + 1] = path .. " = {}"
    end
    stack[t] = nil
  end
  walk(root, "")
  table.sort(lines)
  return table.concat(lines, "\n")
end

-- Both peers: one game tick of the shared world, then A's and B's on_tick, each with its own storage.
local function raise_on(handlers, id, data)
  local f = handlers[id]
  if f then
    data.name = id
    data.tick = game.tick
    f(data)
  end
end
function F_two_tick(peer_a, peer_b)
  game.tick = game.tick + 1
  local queue = F.destroyed_queue
  F.destroyed_queue = {}
  for _, p in ipairs({ peer_a, peer_b }) do
    storage = p.storage
    for _, n in ipairs(queue) do
      raise_on(p.handlers, defines.events.on_object_destroyed, { registration_number = n, useful_id = 0, type = 1 })
    end
    raise_on(p.handlers, defines.events.on_tick, {})
    p.storage = storage
  end
  storage = peer_a.storage
end
function F_two_packet(peer_a, peer_b, payload, port)
  for _, p in ipairs({ peer_a, peer_b }) do
    storage = p.storage
    raise_on(p.handlers, defines.events.on_udp_packet_received, { payload = payload, source_port = port, player_index = 0 })
    p.storage = storage
  end
  storage = peer_a.storage
end
""")

# Peer A: the bridge's modules loaded anew after the ordered pairs/next, playing from on_init's storage.
control_path = str(MOD / "control.lua")
peer_a = g.F_load_peer(control_path)
F.handlers = peer_a.handlers
peer_a.on_load()

tp_x, tp_y = 4000.5, 4000.5
tp_cx, tp_cy = math.floor(tp_x / 32), math.floor(tp_y / 32)
tp_hello = {"t": "hello", "v": 1, "sid": "two-peer", "w": 0, "b": 1, "ie": 2, "ho": 1}
tp_keepalive = {**tp_hello, "w": 1}
send(tp_hello)
send({"t": "budget", "u": 2000})
send({"t": "focus", "x": fixed(tp_x), "y": fixed(tp_y), "r": 64})
send({"t": "sub", "c": [[tp_cx + dx, tp_cy + dy] for dx in (-1, 0, 1) for dy in (-1, 0, 1)]})
tick(4)
take()

tp_chests = []
for i in range(12):
    c = spawn("wooden-chest", tp_x - 20.0 + 3.0 * i, tp_y - 6.0, force="player")
    F.inventories[c]["chest"].insert(lua.table_from({"name": "iron-plate" if i % 2 else "copper-plate", "count": 5 + i}))
    tp_chests.append(c)
tp_asm = spawn("assembling-machine-1", tp_x + 6.0, tp_y + 4.0, force="player")
tp_asm.status = g.defines.entity_status.working
F.inventories[tp_asm]["modules"].insert(lua.table_from({"name": "speed-module", "count": 1}))
tp_lab = spawn("lab", tp_x - 6.0, tp_y + 4.0, force="player")
F.inventories[tp_lab]["input"].insert(lua.table_from({"name": "automation-science-pack", "count": 3}))
tp_tanks = []
for i in range(3):
    t = spawn("storage-tank", tp_x - 12.0 + 5.0 * i, tp_y + 10.0, force="player")
    F.set_fluid(t, 1, lua.table_from({"name": "water", "amount": 400 + 100 * i, "temperature": 25}), 25000)
    tp_tanks.append(t)
tp_lamps = []
for i in range(3):
    lp = spawn("small-lamp", tp_x + 10.0 + 2.0 * i, tp_y - 10.0, force="player")
    lp.status = g.defines.entity_status.working
    lp.always_on = True
    lp.color = lua.table_from({"r": 0.2, "g": 0.6, "b": 1.0, "a": 1.0})
    tp_lamps.append(lp)
send({"t": "altc", "on": 1, "g": 1, "lf": 1})


def tp_run_a(n):
    for _ in range(n):
        if int(g.game.tick) % 200 == 0:
            send(tp_keepalive)
        tick(1)
    take()


tp_run_a(400)
lc_meta = g.storage.f3d.altc and g.storage.f3d.altc.lc_meta
check(lc_meta is not None, "two peers: peer A has Alt-mode's cached list (altc.lc_meta) before B joins")

# Gone without an event (a script's destroy, no raise_destroy): A's module-local lists still hold them.
tp_chests[3].destroy()
tp_tanks[1].destroy()
tp_lamps[1].destroy()

peer_b = g.F_load_peer(control_path)
peer_a.storage = g.storage
peer_b.storage = g.F_deep_copy(g.storage)
peer_b.on_load()
check(g.F_flatten(peer_a.storage) == g.F_flatten(peer_b.storage), "two peers: B starts from an exact copy of A's storage")

# (rel-031-fix3) Made with no event after B starts (create_entity without raise_built): the tracker never
# marks a list dirty, so both peers must keep walking the list storage remembers until the next rescan.
tp_new_lamp = spawn("small-lamp", tp_x + 16.0, tp_y - 10.0, force="player")
tp_new_lamp.status = g.defines.entity_status.working
tp_new_asm = spawn("assembling-machine-1", tp_x + 14.0, tp_y + 4.0, force="player")
tp_new_asm.status = g.defines.entity_status.working
tp_new_tank = spawn("storage-tank", tp_x + 8.0, tp_y + 10.0, force="player")
F.set_fluid(tp_new_tank, 1, lua.table_from({"name": "water", "amount": 900, "temperature": 25}), 25000)


def tp_diff(a_text, b_text, at):
    a_lines, b_lines = set(a_text.split("\n")), set(b_text.split("\n"))
    only_a = sorted(a_lines - b_lines)[:6]
    only_b = sorted(b_lines - a_lines)[:6]
    return f"tick {at}: only in A {only_a}; only in B {only_b}"


tp_first_diff = None
tp_moved = False
for step in range(600):
    if int(g.game.tick) % 200 == 0:
        g.F_two_packet(peer_a, peer_b, json.dumps(tp_keepalive), CLIENT_PORT)
    if step == 300 and not tp_moved:
        # The player walks a little (inside the reuse distance) and Alt-mode is still on.
        tp_moved = True
        g.F_two_packet(peer_a, peer_b, json.dumps({"t": "focus", "x": fixed(tp_x + 3), "y": fixed(tp_y), "r": 64}), CLIENT_PORT)
    if step == 450:
        # Another chest's contents change (no event): both read the same world.
        F.inventories[tp_chests[5]]["chest"].insert(lua.table_from({"name": "coal", "count": 50}))
    g.F_two_tick(peer_a, peer_b)
    if step % 10 == 9 or step == 599:
        a_text, b_text = g.F_flatten(peer_a.storage), g.F_flatten(peer_b.storage)
        if a_text != b_text:
            tp_first_diff = tp_diff(a_text, b_text, int(g.game.tick))
            break
F.take_sent()
check(tp_first_diff is None,
      f"two peers: a joiner's storage stays identical to the host's over 600 ticks with Alt-mode on (M1, N3): {tp_first_diff}")
tp_altc = peer_b.storage.f3d.altc
check(tp_altc is not None and tp_altc.lc_meta is not None and tp_altc.lc_meta.list is not None,
      "two peers: the joiner keeps Alt-mode's cached list, kept in storage (altc.lc_meta.list)")
