-- A Factorio mod that talks to a Zenith add-on through the bridge (link.lua), for live_check.py
-- --only link and the mock (tools/mock_link.py plays the same verbs). On its channel,
-- "zenith-link-test[/topic]":
--   {echo = x}   answered with {echo = x}
--   {who = 1}    answered with {client, player_index, unit}: the client, its player, its character
--   {flood = n}  sends n messages back; how many the bridge took is in linktest.get's `flood`
--   {big = 1}    sends one over 4 KB; the bridge's answer is in linktest.get's `big`
--   {boom = 1}   fails with an error (what a companion's own bug does to the bridge: live_check --only sprint)
-- remote.call("linktest", "get") returns its counts as JSON, for RCON.
--
-- As every such mod must: the event ids come from the bridge in on_init and on_load (they aren't
-- saved), the handlers are registered whenever the bridge is there, and storage changes only in them.

local came_by = "main chunk"  -- module-local, only reported: how this load started

local function bridge()
  local z = remote.interfaces["zenith"]
  return z and z.on_message and z.on_client
end

local function on_message(e)
  storage.n = (storage.n or 0) + 1
  local d = e.data
  if type(d) ~= "table" then
    return
  end
  if d.echo ~= nil then
    remote.call("zenith", "send", e.client, e.channel, { echo = d.echo })
  elseif d.who then
    local c = remote.call("zenith", "character", e.client)
    remote.call("zenith", "send", e.client, e.channel,
      { client = e.client, player_index = e.player_index or 0, unit = c and c.valid and c.unit_number or 0 })
  elseif type(d.flood) == "number" then
    local ok = 0
    for i = 1, math.min(math.floor(d.flood), 1000) do
      if remote.call("zenith", "send", e.client, e.channel, { i = i }) then
        ok = ok + 1
      end
    end
    storage.flood = ok
  elseif d.boom then
    error("linktest: boom, as asked")
  elseif d.big then
    local sent, why = remote.call("zenith", "send", e.client, e.channel, string.rep("b", 5000))
    storage.big = sent and "sent" or why
  end
end

local function on_client(e)
  storage.clients = storage.clients or {}
  table.insert(storage.clients, { client = e.client, joined = e.joined })
  while #storage.clients > 20 do
    table.remove(storage.clients, 1)
  end
end

local function register()
  if bridge() then
    script.on_event(remote.call("zenith", "on_message"), on_message)
    script.on_event(remote.call("zenith", "on_client"), on_client)
  end
end

script.on_init(function()
  came_by = "on_init"
  register()
end)
script.on_load(function()
  came_by = "on_load"
  register()
end)

remote.add_interface("linktest", {
  get = function()
    return helpers.table_to_json({ came_by = came_by, n = storage.n or 0, flood = storage.flood or -1,
      big = storage.big or "", clients = storage.clients or {}, link = bridge() and remote.call("zenith", "link") or 0 })
  end,
  reset = function()
    storage.n, storage.flood, storage.big, storage.clients = 0, -1, "", {}
  end,
})
