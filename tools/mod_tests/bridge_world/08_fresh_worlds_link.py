# Bridge test slice 08_fresh_worlds_link.py (lines 12843-13465 of original test_bridge.py)


def same(a, b):
    # (Lua objects through lupa compare as Python objects: entities by their unit numbers.)
    return a is not None and b is not None and a.valid and b.valid and a.unit_number == b.unit_number


def perf_cmd(parameter):
    F.commands["f3d-perf"](lua.table_from({"name": "f3d-perf", "parameter": parameter}))


def item_count(c, name):
    n = c.get_main_inventory().get_item_count(name)
    for inv in (g.defines.inventory.character_guns, g.defines.inventory.character_ammo):
        n += c.get_inventory(inv).get_item_count(name)
    return n


def kit_counts(c):
    return {n: item_count(c, n) for n in ("iron-plate", "wood", "pistol", "firearm-magazine", "burner-mining-drill", "stone-furnace")}


# The owner's video: a new game made in Zenith's menu, Zenith playing it on the headless server.
fresh_world()
zen_hello = {"t": "hello", "v": 1, "sid": "z1", "w": 1, "pn": "zen"}
send(zen_hello)
tick(4)
take()
own = g.storage.f3d.puppet
check(own and own.valid and same(g.storage.f3d.own_character, own) and not g.storage.f3d.owner_index,
      "L13: on a new server game the bridge plays its own character")
check(F.freeplay.disable_crashsite is True and not F.freeplay.init_ran,
      f"L13: freeplay is told not to make its crash site, before anyone joined ({F.freeplay.disable_crashsite})")
check(g.storage.f3d.client.pn == "zen", "L13: the hello's pn (this Zenith's Factorio account) is kept with the client")
own.teleport(lua.table_from({"x": 40.5, "y": 12.5}))
own.get_main_inventory().insert(lua.table_from({"name": "iron-gear-wheel", "count": 30}))
own.get_inventory(g.defines.inventory.character_armor).insert(lua.table_from({"name": "light-armor", "count": 1}))
send({"t": "qb_set", "i": 1, "item": "transport-belt"})
tick(1)
before_kit = kit_counts(own)
own_unit = own.unit_number
take()
# A stranger joins first: a character of their own, with freeplay's kit; the bridge keeps its own.
stranger, stranger_char = F.create_player(2, "stranger", 0.5, 0.5)
send(zen_hello)
tick(2)
check(same(g.storage.f3d.puppet, own) and same(stranger.character, stranger_char) and stranger_char.valid
      and not g.storage.f3d.owner_index and kit_counts(stranger_char)["iron-plate"] == 8,
      "L13: a stranger who joins gets a character of their own (and freeplay's kit); the bridge keeps playing its own")
check(F.freeplay.crash_sites == 0 and F.freeplay.init_ran,
      f"L13: freeplay's first player made no crash site in the base ({F.freeplay.crash_sites})")
take()
# The owner presses Ctrl+F9: their Factorio joins as "zen" (the name the hello said).
zen, fresh = F.create_player(3, "zen", 0.5, 0.5)
fresh.insert(lua.table_from({"name": "coal", "count": 5}))  # what another mod gave a new player
check(g.storage.f3d.owner_index == 3 and g.storage.f3d.zenith_owner == 3, "L13: the player of the hello's name is claimed on joining")
tick(2)
msgs = take()
check(same(zen.character, own) and same(g.storage.f3d.puppet, own) and own.valid and own.unit_number == own_unit
      and own.position.x == 40.5 and own.position.y == 12.5 and own.player.index == 3,
      "L13: they take over the character Zenith was playing, where it was (the same entity)")
check(not fresh.valid, "L13: the character the game gave them on joining is gone")
check(own.get_main_inventory().get_item_count("iron-gear-wheel") == 30
      and own.get_inventory(g.defines.inventory.character_armor)[1].valid_for_read,
      "L13: with Zenith's inventory and armour")
check(kit_counts(own) == before_kit, f"L13: and no second starting kit ({before_kit} -> {kit_counts(own)})")
check(own.get_main_inventory().get_item_count("coal") == 5, "L13: what else the new character had comes along")
qb = zen.get_quick_bar_slot(1, 1)
check(qb is not None and qb.filter.name == "transport-belt", "L13: Zenith's quickbar becomes the player's")
check(not of_type(msgs, "welcome") and g.storage.f3d.held_for is None and g.storage.f3d.own_character is None,
      "L13: the client goes on with the same character (no new handshake)")
g.storage.f3d.pl_sig = None
tick(60)
pl = of_type(take(), "pl")
check(pl and pl[-1]["me"] == 3 and pl[-1]["u"] == own_unit, f"L13: the players list says the client plays that player: {pl[-1:]}")
send(zen_hello)
tick(1)
take()
F.handlers["f3d-show-3d"](lua.table_from({"player_index": 3, "input_name": "f3d-show-3d"}))
check(of_type(take(), "raise"), "L13: Ctrl+F9 in their Factorio brings Zenith to the front again (raise)")
g.storage.f3d.client.raised = None
F.handlers["f3d-show-3d"](lua.table_from({"player_index": 2, "input_name": "f3d-show-3d"}))
sent = [(item[1], json.loads(item[2].split("\n")[0])) for item in F.take_sent().values()]
check(not any(m.get("t") == "raise" for _, m in sent) and any(port == 34209 for port, _ in sent),
      f"L13: the stranger's Ctrl+F9 doesn't (their own launcher is asked to start a Zenith): {sent}")
g.storage.f3d.launch_wait = None
check(same(stranger.character, stranger_char) and stranger_char.valid, "L13: the stranger keeps their character")
# They leave: the bridge stands in for them where they were, with their things, as for a save's player.
own.teleport(lua.table_from({"x": 44.5, "y": 14.5}))
F.disconnect_player(zen)
send(zen_hello)
tick(2)
msgs = take()
stand_in = g.storage.f3d.puppet
check(stand_in and stand_in.valid and stand_in.unit_number != own_unit and g.storage.f3d.held_for == 3
      and stand_in.position.x == 44.5 and stand_in.position.y == 14.5,
      "L13: when they leave, the bridge stands in for them where they left")
check(stand_in and stand_in.get_main_inventory().get_item_count("iron-gear-wheel") == 30
      and stand_in.get_inventory(g.defines.inventory.character_armor)[1].valid_for_read,
      "L13: holding their things")
welcome = of_type(msgs, "welcome")
check(welcome and welcome[-1]["u"] == stand_in.unit_number, "L13: and the client plays the stand-in")
# Back from Factorio: their own character returns and takes it all back.
back = spawn("character", 44.5, 14.5, force="player")
F.connect_player(zen, back)
send(zen_hello)
tick(2)
check(same(g.storage.f3d.puppet, back) and not stand_in.valid and g.storage.f3d.held_for is None
      and back.get_main_inventory().get_item_count("iron-gear-wheel") == 30,
      "L13: when they come back their character takes it all back, and the client plays it")
take()
# Should 2.1 keep a logged-off character's LuaEntity valid, the bridge leaves it alone: it isn't the bridge's.
kept = F.disconnect_player(zen, True)
send(zen_hello)
tick(2)
take()
check(kept.valid and not same(g.storage.f3d.puppet, kept) and g.storage.f3d.held_for == 3,
      "L13: a logged-off character that stays valid isn't emptied or removed: the bridge stands in beside it")
F.connect_player(zen, kept)
send(zen_hello)
tick(2)
take()
check(same(g.storage.f3d.puppet, kept) and kept.get_main_inventory().get_item_count("iron-gear-wheel") == 30,
      "L13: and it takes the things back when they return")

# Factorio joined before Zenith connected: the hello's name finds them already in the game.
fresh_world()
send({"t": "hello", "v": 1, "sid": "z2", "w": 1})
tick(4)
own = g.storage.f3d.puppet
own.teleport(lua.table_from({"x": 30.5, "y": 8.5}))
own_unit = own.unit_number
send({"t": "bye"})
tick(1)
take()
zen, mine = F.create_player(1, "zen", 0.5, 0.5)
tick(120)
check(same(zen.character, mine) and not g.storage.f3d.owner_index, "L13: with no Zenith connected a player joining isn't claimed")
send({"t": "hello", "v": 1, "sid": "z3", "w": 1, "pn": "zen"})
tick(4)
take()
check(g.storage.f3d.owner_index == 1 and same(zen.character, own) and own.valid and own.unit_number == own_unit
      and own.position.x == 30.5 and not mine.valid,
      "L13: Zenith's hello naming them claims them then: they take over its character")
check(own.get_main_inventory().get_item_count("pistol") + own.get_inventory(g.defines.inventory.character_guns).get_item_count("pistol") == 2,
      "L13: claimed later, what their own character held (freeplay's kit too) all comes along")

# The switches off (`/f3d-perf zenith_join off`, `no_crash_site off`): as before L13.
fresh_world()
perf_cmd("zenith_join off")
perf_cmd("no_crash_site off")
send(zen_hello)
tick(4)
take()
own = g.storage.f3d.puppet
check(F.freeplay.disable_crashsite is None, "L13 off: freeplay's crash site left to freeplay")
zen, mine = F.create_player(1, "zen", 0.5, 0.5)
send(zen_hello)
tick(2)
take()
check(F.freeplay.crash_sites == 1 and same(zen.character, mine) and same(g.storage.f3d.puppet, own) and not g.storage.f3d.owner_index,
      "L13 off: the first player gets freeplay's crash site and a character of their own, as before")
# Should the game refuse to hand the character over, the old way: its things onto theirs, where it was.
perf_cmd("zenith_join default")
own.teleport(lua.table_from({"x": 25.5, "y": 6.5}))
own.get_main_inventory().insert(lua.table_from({"name": "iron-gear-wheel", "count": 7}))
own_at = (25.5, 6.5)
F.refuse_set_controller = True
send(dict(zen_hello, pn="zen2"))
tick(1)
zen2, mine2 = F.create_player(2, "zen2", 0.5, 0.5)
send(dict(zen_hello, pn="zen2"))
tick(2)
msgs = take()
check(same(g.storage.f3d.puppet, mine2) and not own.valid and (mine2.position.x, mine2.position.y) == own_at
      and mine2.get_main_inventory().get_item_count("iron-gear-wheel") == 7 and of_type(msgs, "welcome"),
      "L13: set_controller refused: the bridge's character's things move onto theirs, where it stood, and the client plays it")
F.refuse_set_controller = False

# Single-player with the mod: its player was created before any client, freeplay's intro is its own.
fresh_world(multiplayer=False)
sp_char = spawn("character", 0.5, 0.5, force="player")
F.make_player(sp_char)
send({"t": "hello", "v": 1, "sid": "s9", "w": 1, "pn": "player"})
tick(4)
take()
check(F.freeplay.disable_crashsite is None and not g.package.loaded["scripts.takeover"].no_crash_site(),
      "L13: single-player keeps freeplay's intro (the bridge never turns its crash site off there)")
check(same(g.storage.f3d.puppet, sp_char) and not g.storage.f3d.zenith_owner, "L13: and its player plays as before")

# Step 5 task 3a: the steps' list comes again with a full resync and with a client's new hello (a reconnect).
lua.eval("function() storage.f3d.resync_tick = -1000000 end")()
take()
send({"t": "resync", "full": 1})
tick(6)
again = steps_of(take())
tick(130)  # a welcome goes again at most every 2 s
send({"t": "hello", "v": 1, "sid": "steps-again", "w": 0})
tick(6)
rehello = steps_of(take())
# (A new world here: ids may differ, so the lists are compared by the sounds they point at.)
def step_shape(lists):
    return {k: sorted(r[1:] for r in v) for k, v in lists.items()}


check(again[1] == st_sounds and step_shape(again[2]) == step_shape(st_lists) and rehello[1] == st_sounds
      and step_shape(rehello[2]) == step_shape(st_lists) and len(again[0]) == len(st_parts) == len(rehello[0]),
      f"steps: sent again whole on a full resync and a reconnect: {len(again[0])} and {len(rehello[0])} parts")
# --- the link between add-ons and their mods (link.lua, `ext`) ------------------------------------
# A fake companion mod: it listens to the bridge's events, answers `echo` and `who`, and notes clients.
fresh_world(multiplayer=True)
g.script.active_mods["zenith-link-test"] = "0.1.0"
LINK_CH = "zenith-link-test"
lua.execute("""
LINK = {msgs = {}, clients = {}, sends = {}, first = {}}
F.companion_on(remote.call("zenith", "on_message"), function(e)
  table.insert(LINK.msgs, e)
  local d = e.data
  if type(d) == "table" and d.echo ~= nil then
    local ok, why = remote.call("zenith", "send", e.client, e.channel, {echo = d.echo})
    table.insert(LINK.sends, {ok = ok, why = why})
  elseif type(d) == "table" and d.who then
    local c = remote.call("zenith", "character", e.client)
    -- (Called from the handler: the first client's state is storage.f3d, never another's swapped in.)
    table.insert(LINK.first, storage.f3d.client.port)
    remote.call("zenith", "send", e.client, e.channel, {unit = c and c.unit_number or 0, p = e.player_index or 0})
  end
end)
F.companion_on(remote.call("zenith", "on_client"), function(e) table.insert(LINK.clients, e) end)
""")
LINK = g.LINK
ev_msg, ev_client = F.remote.zenith.on_message(), F.remote.zenith.on_client()
check(isinstance(ev_msg, int) and isinstance(ev_client, int) and ev_msg != ev_client and F.remote.zenith.link() == 1,
      f"link: the interface hands out two generated event ids and its version ({ev_msg}, {ev_client})")


def ext(d, ch=LINK_CH, port=CLIENT_PORT, machine=0, **more):
    F.packet(json.dumps({"t": "ext", "ch": ch, "d": d, **more}), port, machine)


def link_count():
    return len(list(LINK.msgs.values()))


send({"t": "hello", "v": 1, "sid": "lk", "w": 0})
tick(3)
msgs = take()
welcome = of_type(msgs, "welcome")
check(welcome and welcome[0].get("ext") == 1, f"link: the welcome says ext 1: {welcome[:1] and welcome[0].get('ext')}")
joins = [to_py(e) for e in LINK.clients.values()]
check(len(joins) == 1 and joins[0]["client"] == CLIENT_PORT and joins[0]["joined"] is True,
      f"link: a client's first hello raises on_client (joined): {joins}")
check(same(F.remote.zenith.character(), g.storage.f3d.puppet) and same(F.remote.zenith.character(CLIENT_PORT), g.storage.f3d.puppet)
      and F.remote.zenith.character(CLIENT_PORT + 99) is None,
      "link: character() as before, character(client) that client's, nil for no such client")
ext({"echo": "hi"}, machine=3)
tick(1)
got = to_py(LINK.msgs[1])
check(got and got["client"] == CLIENT_PORT and got["channel"] == LINK_CH and got["data"] == {"echo": "hi"} and got["machine"] == 3
      and got["name"] == ev_msg,
      f"link: an `ext` arrives as the event with client, channel, data and the machine it came in on: {got}")
replies = of_type(take(), "ext")
check(replies and replies[-1]["ch"] == LINK_CH and replies[-1]["d"] == {"echo": "hi"} and isinstance(replies[-1].get("k"), int),
      f"link: the mod's send reaches the client as `ext` (stamped with the tick): {replies}")
ext("a string", ch=LINK_CH + "/state/x")
ext([1, 2, 3])
tick(1)
check(link_count() == 3 and to_py(LINK.msgs[2])["channel"] == LINK_CH + "/state/x" and to_py(LINK.msgs[3])["data"] == [1, 2, 3],
      f"link: topics after the mod's name, strings and lists as data: {[to_py(m) for m in LINK.msgs.values()][1:]}")
before = link_count()
ext({"echo": 1}, ch="not-in-this-game")
ext({"echo": 1}, ch="bad channel")
ext({"echo": 1}, ch=5)
ext({"echo": 1}, ch="")
ext({"echo": 1}, ch=LINK_CH + "/" + "x" * 130)
ext({"echo": 1}, ch=LINK_CH + "/a\nb")
ext({"echo": 1}, ch="/" + LINK_CH)
F.packet(json.dumps({"t": "ext", "ch": LINK_CH}), CLIENT_PORT)  # no d
ext("x" * 4100)  # over 4 KB
ext({"echo": 1}, port=40000)  # not a connected client
tick(1)
check(link_count() == before and not of_type(take(), "ext"),
      f"link: refused, nothing raised: a mod not in the game, bad channels, no data, over 4 KB, another port ({link_count() - before})")
check(not any("Bridge error" in str(m) for m in g.F.printed.values()), "link: and none of it an error")
tick(60)
for i in range(70):
    ext({"n": i})
tick(1)
take()
check(link_count() - before == 60, f"link: a client's flood is capped at 60 messages per 60 ticks ({link_count() - before})")
tick(60)
ext({"n": 70})
tick(1)
check(link_count() - before == 61, "link: and the window opens again 60 ticks later")
before = link_count()
for i in range(10):
    ext("y" * 3900)
tick(1)
check(link_count() - before == 8, f"link: and at 32 KB per 60 ticks ({link_count() - before} of 10 near-4 KB messages)")
tick(61)
take()
results = lua.eval("""function(port)
  local out = {}
  for i = 1, 70 do
    out[#out + 1] = select(1, remote.call("zenith", "send", port, "zenith-link-test", {i = i})) and 1 or 0
  end
  local _, big = remote.call("zenith", "send", port, "zenith-link-test", string.rep("z", 4100))
  local _, chan = remote.call("zenith", "send", port, "no spaces", 1)
  local _, who = remote.call("zenith", "send", 1, "zenith-link-test", 1)
  local _, many = remote.call("zenith", "send", port, "zenith-link-test", 1)
  local _, nan = remote.call("zenith", "send", port, "zenith-link-test", 0/0)
  return {sum = out, big = big, chan = chan, who = who, many = many, nan = nan}
end""")(CLIENT_PORT)
sent_ok = sum(results.sum.values())
tick(1)
outs = of_type(take(), "ext")
check(sent_ok == 60 and len(outs) == 60 and results.many == "too many",
      f"link: send is capped at 60 a client per 60 ticks too ({sent_ok} true, {len(outs)} sent, then {results.many})")
check(results.big == "too big" and results.chan == "bad channel" and results.who == "no such client" and results.nan == "bad data",
      f"link: send refuses too big, a bad channel, no such client, data that isn't JSON: {results.big}, {results.chan}, {results.who}, {results.nan}")
# Two clients: each message names its own client, and an answer reaches only it.
tick(61)
take()
send({"t": "hello", "v": 1, "sid": "lk", "w": 1})  # the first client still there
send({"t": "hello", "v": 1, "sid": "lk2", "w": 0}, port=PORT_B)
tick(3)
take_by_port()
joins = [to_py(e) for e in LINK.clients.values()]
check(len(joins) == 2 and joins[1]["client"] == PORT_B and joins[1]["joined"] is True, f"link: a second client joins: {joins}")
b_puppet = g.storage.f3d_extra[PORT_B].puppet
ext({"who": 1}, port=PORT_B)
tick(1)
by = take_by_port()
got = to_py(LINK.msgs[link_count()])
b_ext, a_ext = of_type(by.get(PORT_B, []), "ext"), of_type(by.get(CLIENT_PORT, []), "ext")
check(got["client"] == PORT_B and b_ext and b_ext[-1]["d"]["unit"] == b_puppet.unit_number and not a_ext,
      f"link: the second client's message names it; character(client) is its character; the answer goes to it alone: {b_ext}, {a_ext}")
check(list(LINK.first.values()) == [CLIENT_PORT], f"link: a mod's handler runs with the first client's state in place: {list(LINK.first.values())}")
listed = to_py(F.remote.zenith.clients())
check([c["client"] for c in listed] == [CLIENT_PORT, PORT_B], f"link: clients() lists both, the first first: {listed}")
check(F.remote.zenith.send(PORT_B, LINK_CH, lua.table_from({"to": "b"})), "link: send to the second client")
tick(1)
by = take_by_port()
check(of_type(by.get(PORT_B, []), "ext") and not of_type(by.get(CLIENT_PORT, []), "ext"), "link: reaches only it")
# set_cue(tick): a filmed scene's cue from a mod while running, to every client and in later welcomes.
cue_at = g.game.tick + 30
check(F.remote.zenith.set_cue(cue_at) == cue_at and g.storage.f3d_cue == cue_at, f"cue: set_cue keeps the tick in storage ({g.storage.f3d_cue})")
tick(1)
by = take_by_port()
cue_a, cue_b = of_type(by.get(CLIENT_PORT, []), "cue"), of_type(by.get(PORT_B, []), "cue")
check(cue_a and cue_b and cue_a[-1]["c"] == cue_at == cue_b[-1]["c"] and "r" in cue_a[-1],
      f"cue: a reliable `cue` reaches both clients: {cue_a} {cue_b}")
send({"t": "resync", "full": 1})
tick(3)
w = of_type(take_by_port().get(CLIENT_PORT, []), "welcome")
check(w and w[0].get("cue") == cue_at, f"cue: a later welcome carries it: {w[:1] and w[0].get('cue')}")
check(F.remote.zenith.set_cue(-5) == -1 and g.storage.f3d_cue is None and F.remote.zenith.set_cue(None) == -1
      and F.remote.zenith.set_cue("x") == -1, "cue: nil, a negative or a non-number clears it (-1)")
tick(1)
cleared = of_type(take_by_port().get(PORT_B, []), "cue")
check(cleared and cleared[-1]["c"] == -1, f"cue: the clearing reaches the clients as c -1: {cleared}")
tick(130)  # a welcome goes again at most every 2 s
take_by_port()
send({"t": "resync", "full": 1})
tick(3)
w = of_type(take_by_port().get(CLIENT_PORT, []), "welcome")
check(w and "cue" not in w[0], "cue: and a welcome without one has no cue")
send({"t": "bye"}, port=PORT_B)
tick(1)
joins = [to_py(e) for e in LINK.clients.values()]
check(len(joins) == 3 and joins[2]["client"] == PORT_B and joins[2]["joined"] is False, f"link: a goodbye raises on_client (left): {joins}")
check(F.remote.zenith.send(PORT_B, LINK_CH, 1) == (False, "no such client"), "link: and send to it is refused")
# A client that times out leaves too (raised after the tick's clients are served).
tick(700)
joins = [to_py(e) for e in LINK.clients.values()]
check(joins[-1]["client"] == CLIENT_PORT and joins[-1]["joined"] is False, f"link: a client timing out raises on_client (left): {joins[-1]}")
check(len(list(LINK.sends.values())) >= 1 and all(s.ok for s in LINK.sends.values()), "link: the echoes were sent")

# --- the link's determinism (testing agent): every storage write on the link's path inside an event ---
# Multiplayer: every peer must end each event with the same storage, and nothing between events may change
# it (a remote.call outside an event, a list carried over to the next event and lost in a save). Each
# event handler is wrapped: storage's fingerprint is taken when it returns and compared when the next one
# starts, and link.lua's list of events to raise must be empty when it returns. A companion mod's handler
# notes which event it ran in and sends from inside it.
fresh_world(multiplayer=True)
g.script.active_mods["zenith-link-test"] = "0.1.0"
lua.execute(r"""
DET = {outside = 0, left_pending = 0, events = 0, ran_in = {}, sent = {}}
local function fp(v, seen, out)
  local t = type(v)
  if t ~= "table" then
    out[#out + 1] = t .. ":" .. tostring(v)
    return
  end
  if getmetatable(v) ~= nil then  -- a LuaObject (the fake's strict tables)
    local ok, u = pcall(function() return v.unit_number end)
    out[#out + 1] = "obj:" .. tostring(ok and u or "?")
    return
  end
  if seen[v] then
    out[#out + 1] = "seen:" .. seen[v]
    return
  end
  seen.n = (seen.n or 0) + 1
  seen[v] = seen.n
  local keys = {}
  for k in pairs(v) do
    keys[#keys + 1] = k
  end
  table.sort(keys, function(a, b) return type(a) .. tostring(a) < type(b) .. tostring(b) end)
  out[#out + 1] = "{"
  for _, k in ipairs(keys) do
    fp(k, seen, out)
    out[#out + 1] = "="
    fp(v[k], seen, out)
  end
  out[#out + 1] = "}"
end
function DET.fingerprint()
  local out = {}
  fp(storage, {}, out)
  return table.concat(out, ",")
end
local link = package.loaded["scripts.link"]
local function pending_count()
  local i = 1
  while true do
    local name, val = debug.getupvalue(link.raise, i)
    if not name then
      return -1
    elseif name == "pending" then
      return #val
    end
    i = i + 1
  end
end
DET.pending_count = pending_count
local function wrap(fn, name)
  return function(...)
    if DET.after and DET.fingerprint() ~= DET.after then
      DET.outside = DET.outside + 1
    end
    DET.in_event = name
    fn(...)
    DET.in_event = nil
    DET.events = DET.events + 1
    if pending_count() ~= 0 then
      DET.left_pending = DET.left_pending + 1
    end
    DET.after = DET.fingerprint()
  end
end
for _, name in ipairs({"on_tick", "on_udp_packet_received"}) do
  local id = defines.events[name]
  F.handlers[id] = wrap(F.handlers[id], name)
end
F.on_config = wrap(F.on_config, "on_configuration_changed")
F.companion_on(remote.call("zenith", "on_message"), function(e)
  table.insert(DET.ran_in, "msg:" .. tostring(DET.in_event))
  storage.companion_n = (storage.companion_n or 0) + 1  -- the companion's own write, inside the event
  local ok, why = remote.call("zenith", "send", e.client, e.channel, {echo = e.data})
  table.insert(DET.sent, ok and "ok" or why)
end)
F.companion_on(remote.call("zenith", "on_client"), function(e)
  table.insert(DET.ran_in, (e.joined and "join:" or "left:") .. tostring(DET.in_event))
end)
""")
DET = g.DET
check(DET.pending_count() == 0, f"link determinism: the guard finds link.lua's list of events to raise ({DET.pending_count()})")
send({"t": "hello", "v": 1, "sid": "det", "w": 0})
tick(5)
take()
check(g.storage.f3d.link is None, "link cost while unused: no link state in storage before a first ext")
# A read from outside any event (a companion's on_load, RCON) changes nothing.
DET.after = DET.fingerprint()
F.remote.zenith.link(), F.remote.zenith.on_message(), F.remote.zenith.on_client(), F.remote.zenith.clients()
F.remote.zenith.character(CLIENT_PORT), F.remote.zenith.player(CLIENT_PORT), F.remote.zenith.name(CLIENT_PORT)
F.remote.zenith.character(CLIENT_PORT + 99)
check(DET.fingerprint() == DET.after, "link determinism: the interface's reads outside an event leave storage alone")
for i in range(5):
    F.packet(json.dumps({"t": "ext", "ch": "zenith-link-test", "d": {"i": i}}), CLIENT_PORT)
F.packet("{not json", CLIENT_PORT)
F.packet(json.dumps({"t": "ext", "ch": "zenith-link-test/x", "d": None}), CLIENT_PORT)
tick(2)
check(g.storage.f3d.link is not None and g.storage.f3d.link.i == 5, f"link determinism: the caps' counters live in storage ({g.storage.f3d.link and g.storage.f3d.link.i})")
send({"t": "hello", "v": 1, "sid": "det2", "w": 0}, port=PORT_B)
tick(3)
F.packet(json.dumps({"t": "ext", "ch": "zenith-link-test", "d": "b"}), PORT_B)
tick(1)
check(g.storage.f3d_extra[PORT_B].link is not None and g.storage.f3d_extra[PORT_B].link.i == 1,
      "link determinism: a second client's counters in its own state in storage")
send({"t": "bye"}, port=PORT_B)
tick(700)  # the first client times out
F.on_config(lua.table_from({"mod_changes": {"factorio-3d-bridge": {"old_version": "0.1.1", "new_version": "0.1.3"}}}, recursive=True))
ran_in = list(DET.ran_in.values())
sent = list(DET.sent.values())
check(DET.outside == 0, f"link determinism: no storage write between events ({DET.outside} events found storage changed since the last)")
check(DET.left_pending == 0, f"link determinism: the list of events to raise is empty after every event ({DET.left_pending} of {DET.events})")
check(ran_in.count("msg:on_udp_packet_received") == 6 and all(r.split(":")[1] != "nil" for r in ran_in),
      f"link determinism: every companion handler ran inside an event: {ran_in}")
check("join:on_udp_packet_received" in ran_in and ran_in.count("left:on_udp_packet_received") == 1 and "left:on_tick" in ran_in,
      f"link determinism: joins in the hello's packet, a goodbye in its packet, a time-out in on_tick: {ran_in}")
check(sent == ["ok"] * 6, f"link determinism: a companion's send from inside its handler: {sent}")
# The guard itself: a write between events is caught.
before = DET.outside
g.storage.f3d.det_probe = 1
tick(1)
check(DET.outside == before + 1, "link determinism: (the guard catches a storage write made between events)")
g.storage.f3d.det_probe = None

# --- the link: a companion mod's error, the handshake, the bridge's own name, on_configuration_changed ---
# A companion handler that throws is the companion's error, caught per event: the game goes on, the
# error is logged naming the mod and sent back to the add-on (`ext` with `err`), the other events in
# the same raise still arrive, and 10 errors within a minute close the channel for that client's session.
fresh_world(multiplayer=True)
g.script.active_mods["zenith-link-test"] = "0.1.0"
lua.execute("""
ERR = {msgs = {}, clients = {}, boom_client = false}
F.companion_on(remote.call("zenith", "on_message"), function(e)
  if type(e.data) == "table" and e.data.boom then
    error("boom " .. tostring(e.data.boom))
  end
  table.insert(ERR.msgs, e.data)
end)
F.companion_on(remote.call("zenith", "on_client"), function(e)
  if ERR.boom_client and e.client == ERR.boom_client then
    error("on_client boom")
  end
  table.insert(ERR.clients, e)
end)
""")
ERR = g.ERR
LINK_MOD = g.package.loaded["scripts.link"]
send({"t": "hello", "v": 1, "sid": "er", "w": 0})
# An `ext` before the client's handshake is done is dropped.
ext({"early": 1})
check(len(list(ERR.msgs.values())) == 0 and g.F.printed is not None, "link: an `ext` before the client's handshake is done is dropped")
tick(5)
take()
ext({"ok": 1}, ch="factorio-3d-bridge")
ext({"ok": 1}, ch="factorio-3d-bridge/x")
tick(1)
check(len(list(ERR.msgs.values())) == 0 and LINK_MOD.channel_mod("factorio-3d-bridge") is None,
      "link: the bridge's own name isn't a channel")
check(F.remote.zenith.send(CLIENT_PORT, "factorio-3d-bridge", 1) == (False, "bad channel"), "link: nor for a mod's send")


def err_lines():
    return [str(m) for m in g.F.printed.values() if "handler failed" in str(m)]


# Three events in one raise, the middle one failing: the first and the third arrive.
logged_before = len(err_lines())
lua.eval("""function(port, ch)
  local link = package.loaded["scripts.link"]
  link.from_packet({payload = "{}", player_index = 0})
  link.receive({ch = ch, d = {n = 1}}, port)
  link.receive({ch = ch, d = {boom = 1}}, port)
  link.receive({ch = ch, d = {n = 3}}, port)
  link.raise()
end""")(CLIENT_PORT, LINK_CH)
got = [to_py(d) for d in ERR.msgs.values()]
check(got == [{"n": 1}, {"n": 3}], f"link: a companion's error loses none of the other events in that raise: {got}")
lines = err_lines()
check(len(lines) == logged_before + 1 and "zenith-link-test" in lines[-1] and "channel " + LINK_CH in lines[-1] and "boom 1" in lines[-1],
      f"link: the error is logged naming the mod and the channel: {lines[-1:]}")
errs = [m for m in of_type(take(), "ext") if "err" in m]
check(len(errs) == 1 and errs[0]["ch"] == LINK_CH and "boom 1" in errs[0]["err"] and "d" not in errs[0],
      f"link: and sent back to the add-on on its channel as `ext` with `err`: {errs}")
check(not any("Bridge error" in str(m) for m in g.F.printed.values()), "link: a companion's error isn't the bridge's")
# From a packet: the game goes on (the test runs with barrier.rethrow on: nothing reached the barrier).
for i in range(2, 10):
    ext({"boom": i})
    tick(1)
errs = [m for m in of_type(take(), "ext") if "err" in m]
check(len(errs) == 8 and not any("closed" in m["err"] for m in errs), f"link: 9 errors, each sent back, the channel still open ({len(errs)})")
ext({"n": 4})
tick(1)
check(to_py(list(ERR.msgs.values())[-1]) == {"n": 4}, "link: and still raised after 9 errors")
check(len(err_lines()) == 5, f"link: only the first few errors are logged in full ({len(err_lines())})")
ext({"boom": 10})
tick(1)
errs = [m for m in of_type(take(), "ext") if "err" in m]
check(len(errs) == 2 and "boom 10" in errs[0]["err"] and "closed after repeated errors" in errs[1]["err"] and errs[1]["ch"] == LINK_CH,
      f"link: the 10th error within a minute closes the channel, and the add-on hears so: {errs}")
check(any("is closed after repeated errors" in str(m) and LINK_CH in str(m) for m in g.F.printed.values()), "link: said in the log too")
check(g.storage.f3d.link_closed and g.storage.f3d.link_closed[LINK_CH], "link: the closed channel is in the client's state in storage")
n_before = len(list(ERR.msgs.values()))
ext({"n": 5})
ext({"boom": 11})
tick(1)
check(len(list(ERR.msgs.values())) == n_before and not of_type(take(), "ext"), "link: a closed channel's messages are dropped, quietly")
ext({"n": 6}, ch=LINK_CH + "/other")
tick(1)
check(to_py(list(ERR.msgs.values())[-1]) == {"n": 6}, "link: another channel of the same mod still works")
# A long error's text is trimmed to 1000 bytes at a character's start (é is two bytes in UTF-8).
lua.execute("""F.companion_on(remote.call("zenith", "on_message"), function(e)
  if e.data == "long" then error(string.rep("\\195\\169", 900), 0) end
end)""")
take()
ext("long", ch=LINK_CH + "/long")
tick(1)
long_err = [m for m in of_type(take(), "ext") if "err" in m]
check(len(long_err) == 1 and long_err[0]["err"].endswith("...") and set(long_err[0]["err"][:-3]) == {"é"}
      and len(long_err[0]["err"].encode("utf-8")) <= 1000, f"link: a long error trimmed at a character: {[len(m['err']) for m in long_err]}")
# Spread out: 9 errors, a minute, then a 10th: the count starts over.
for i in range(9):
    ext({"boom": i}, ch=LINK_CH + "/slow")
    tick(1)
take()
for _ in range(12):  # a minute, the client saying hello as it does
    tick(300)
    send({"t": "hello", "v": 1, "sid": "er", "w": 1})
take()
ext({"boom": 99}, ch=LINK_CH + "/slow")
tick(1)
slow = [m for m in of_type(take(), "ext") if "err" in m]
check(len(slow) == 1 and "boom 99" in slow[0]["err"] and not (g.storage.f3d.link_closed and g.storage.f3d.link_closed[LINK_CH + "/slow"]),
      f"link: 10 errors spread over more than a minute don't close it: {slow}")
# The client's next session opens it again.
send({"t": "bye"})
tick(1)
send({"t": "hello", "v": 1, "sid": "er2", "w": 0})
tick(5)
take()
ext({"n": 7})
tick(1)
check(to_py(list(ERR.msgs.values())[-1]) == {"n": 7}, "link: the client's next session opens it again")

# on_configuration_changed: the clients a new bridge dropped are raised on the first tick after it,
# not inside it (a companion's on_configuration_changed runs after the bridge's), from storage, the
# failing one losing none of the others.
send({"t": "hello", "v": 1, "sid": "er3", "w": 0}, port=PORT_B)
tick(5)
take_by_port()
left_before = [to_py(e) for e in ERR.clients.values() if not e.joined]
ERR.boom_client = CLIENT_PORT
F.on_config(lua.table_from({"mod_changes": {"factorio-3d-bridge": {"old_version": "0.1.1", "new_version": "0.1.3"}}}, recursive=True))
left_now = [to_py(e) for e in ERR.clients.values() if not e.joined]
later = g.storage.f3d_link_later
check(left_now == left_before and later is not None and len(list(later.values())) == 2,
      f"link: on_configuration_changed raises nothing; its clients' leaving waits in storage ({left_now[len(left_before):]})")
tick(1)
left_now = [to_py(e) for e in ERR.clients.values() if not e.joined]
check(g.storage.f3d_link_later is None and [e["client"] for e in left_now[len(left_before):]] == [PORT_B],
      f"link: raised on the first tick; the one whose handler failed loses none of the others: {left_now[len(left_before):]}")
ERR.boom_client = False

