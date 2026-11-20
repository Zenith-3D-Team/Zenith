-- Research for Factorio's technology screen: every technology with its prerequisites, cost and
-- state, the current research with its progress and queue, and commands to queue or cancel.
--
-- The tree is resent when research finishes or is undone (a flag in storage set from the events),
-- so it stays deterministic. What finished goes to the client as `rdone`, for Factorio's chime,
-- its console line and the research panel's "finished" (K23).

local transport = require("scripts.transport")
local puppet = require("scripts.puppet")
local crafting = require("scripts.crafting")
local pedia = require("scripts.pedia")
local planners = require("scripts.planners")
local budget = require("scripts.budget")
local perf = require("scripts.perf")

local M = {}

local STATUS_INTERVAL = 60
local TECHS_PER_MESSAGE = 40
-- A message's records stay under MESSAGE_BYTES, and one record under RECORD_BYTES: a datagram holds
-- 65,507 bytes and the transport joins messages into datagrams of up to 60,000. A recycling
-- technology with thousands of modded recipes is one record of 103-187 KB (textplates, Space
-- Exploration with Space Age), which was dropped and lost its 40 neighbours with it; its effects
-- are cut to fit and the record says how many were left out.
local MESSAGE_BYTES = 40000
local RECORD_BYTES = 30000

local function force()
  local c = puppet.get()
  return c and c.force or game.forces.player
end

local function shown(tech)
  local ok, hidden = pcall(function() return tech.prototype.hidden end)
  return not (ok and hidden) and (tech.enabled or tech.visible_when_disabled)
end

-- 0 locked (a prerequisite is missing), 1 available, 2 researched.
local function state(tech)
  if tech.researched then
    return 2
  end
  for _, pre in pairs(tech.prerequisites) do
    if not pre.researched then
      return 0
    end
  end
  return 1
end

-- Technologies unlocked by doing something (crafting, mining, launching) instead of science
-- packs name the trigger type here (2.x).
local function trigger(tech)
  local ok, t = pcall(function() return tech.prototype.research_trigger end)
  return ok and t and t.type or ""
end

local function read(obj, key)
  local ok, v = pcall(function() return obj[key] end)
  return ok and v or nil
end

-- [name, order, prerequisites, ingredients [[name, amount], ...], unit count, seconds per unit,
--  state, trigger, effects [[type, recipe or modifier target, value], ...], level, max level (-1
--  infinite), trigger detail [type, target, count] or [], saved progress (thousandths), count
--  formula or "", essential (1: shown with "Show only essential technologies", else 0),
--  effects left out to keep the record small (only when some were)]
local INFINITE = 4294967295

local function record(tech)
  local pre = {}
  for name in pairs(tech.prerequisites) do
    pre[#pre + 1] = name
  end
  table.sort(pre)
  local ingredients = {}
  for _, ing in pairs(tech.research_unit_ingredients) do
    ingredients[#ingredients + 1] = { ing.name, ing.amount }
  end
  local proto = tech.prototype
  local okfx, effects = pcall(pedia.effects_of, proto)
  local max_level = read(proto, "max_level") or 1
  return {
    tech.name, tech.order, pre, ingredients, tech.research_unit_count, tech.research_unit_energy / 60,
    state(tech), trigger(tech), okfx and effects or {}, read(tech, "level") or 1,
    max_level >= INFINITE and -1 or max_level, pedia.trigger_of(proto) or {},
    math.floor((read(tech, "saved_progress") or 0) * 1000 + 0.5), read(proto, "research_unit_count_formula") or "",
    read(proto, "essential") and 1 or 0,
  }
end

-- The whole tree is about 300 records on Space Age and took 36 ms in one tick on the owner's save,
-- so it is sent a part a tick under the work budget (budget.lua): the names in storage.f3d.techs_job,
-- each part read when it is sent. The client gathers the parts whatever tick they come in.
local TECH_PRICE = 6   -- units per technology record (measured 60-300 us each on the owner's save)

local function start_techs()
  local names = {}
  for _, tech in pairs(force().technologies) do
    if shown(tech) then
      names[#names + 1] = tech.name
    end
  end
  table.sort(names)
  storage.f3d.techs_job = { names = names, block = 1, blocks = math.max(1, math.ceil(#names / TECHS_PER_MESSAGE)), sent = 0 }
end

-- A record that would be over RECORD_BYTES keeps as many effects as fit, and says how many it left out.
local function fit(rec)
  local size = #helpers.table_to_json(rec)
  if size <= RECORD_BYTES then
    return rec, size
  end
  local effects = rec[9]
  local per = math.max(1, (size - 64) / math.max(1, #effects))
  local keep = math.max(0, math.floor((RECORD_BYTES - (size - per * #effects)) / per) - 1)
  local kept = {}
  for i = 1, math.min(keep, #effects) do
    kept[i] = effects[i]
  end
  rec[9] = kept
  rec[16] = #effects - #kept
  return rec, #helpers.table_to_json(rec)
end

-- Sends parts while the budget lasts; true when the last one went.
local function send_tech_parts()
  local s = storage.f3d
  local job = s.techs_job
  local techs = force().technologies
  while job.block <= job.blocks do
    if not budget.can(TECHS_PER_MESSAGE * TECH_PRICE, "techs", 0.5) then
      return false
    end
    budget.spend(TECHS_PER_MESSAGE * TECH_PRICE, "techs")
    -- A block of names, as messages of up to MESSAGE_BYTES. The client gathers until a message's
    -- part reaches its parts, so `parts` counts the messages sent, this block's and one per block
    -- left: it grows when a block needs more than one, and only the very last message reaches it.
    local messages, slice, bytes = {}, {}, 0
    for i = (job.block - 1) * TECHS_PER_MESSAGE + 1, math.min(job.block * TECHS_PER_MESSAGE, #job.names) do
      local tech = techs[job.names[i]]
      if tech then
        local rec, size = fit(record(tech))
        if #slice > 0 and bytes + size > MESSAGE_BYTES then
          messages[#messages + 1] = slice
          slice, bytes = {}, 0
        end
        slice[#slice + 1] = rec
        bytes = bytes + size + 1
      end
    end
    messages[#messages + 1] = slice
    local parts = job.sent + #messages + (job.blocks - job.block)
    for _, l in ipairs(messages) do
      job.sent = job.sent + 1
      transport.send_reliable({ t = "techs", part = job.sent, parts = parts, l = l })
    end
    job.block = job.block + 1
  end
  s.techs_job = nil
  return true
end

function M.queue_length()
  local job = storage.f3d.techs_job
  return job and job.block and (job.blocks - job.block + 1) or 0
end
budget.register_queue("techs", M.queue_length)

local function queue_names(f)
  local names = {}
  local ok, queue = pcall(function() return f.research_queue end)
  for _, tech in pairs(ok and queue or {}) do
    names[#names + 1] = type(tech) == "string" and tech or tech.name
  end
  return names
end

-- What is being researched now (or ""), its progress, and the queue.
local function send_status()
  local f = force()
  local current = f.current_research
  transport.send_now({
    t = "rs",
    cur = current and current.name or "",
    pr = current and math.floor(f.research_progress * 1000 + 0.5) or 0,
    q = queue_names(f),
  })
end

---------------------------------------------------------------------------------------------
-- Commands

-- What 2.1.24's add_research takes at most (measured in real headless 2.1.24: the eighth is refused); only
-- for the message saying why one was refused.
local QUEUE_MAX = 7

-- The technologies a technology waits for that are neither researched nor queued, all the way down, each
-- after its own (prerequisites by their order, then name): what has to be queued before it (L12).
local function missing_prerequisites(f, tech)
  local have = {}
  for _, n in ipairs(queue_names(f)) do
    have[n] = true
  end
  local current = f.current_research
  if current then
    have[current.name] = true
  end
  local out = {}
  local function visit(t)
    local pres = {}
    for _, pre in pairs(t.prerequisites) do
      pres[#pres + 1] = pre
    end
    table.sort(pres, function(a, b)
      if a.order ~= b.order then
        return a.order < b.order
      end
      return a.name < b.name
    end)
    for _, pre in ipairs(pres) do
      if not (pre.researched or have[pre.name]) then
        have[pre.name] = true
        visit(pre)
        out[#out + 1] = pre
      end
    end
  end
  visit(tech)
  return out
end

-- Starts researching a technology, or adds it to the end of the queue. Factorio's add_research takes one
-- only once its prerequisites are researched or queued before it, and never a trigger technology (one
-- unlocked by doing its task); its technology screen queues what is missing first. So does this (L12,
-- `/f3d-perf research_chain`): the missing prerequisites in order, then the technology, or nothing at all
-- if one of them can't be queued.
function M.research(cmd)
  local f = force()
  local name = type(cmd.name) == "string" and cmd.name or ""
  local tech = f.technologies[name]
  if not (tech and shown(tech) and tech.enabled and not tech.researched) then
    return puppet.message("Can't research " .. name)
  end
  local need = perf.on("research_chain") and missing_prerequisites(f, tech) or {}
  for _, pre in ipairs(need) do
    if trigger(pre) ~= "" or not pre.enabled then
      puppet.message("Can't research " .. name .. " yet: " .. pre.name
        .. (pre.enabled and " is unlocked by doing its task" or " isn't available"))
      return send_status()
    end
  end
  local before = queue_names(f)
  need[#need + 1] = tech
  for i, t in ipairs(need) do
    if not f.add_research(t) then
      local full = #queue_names(f) >= QUEUE_MAX
      if i > 1 then
        -- What this command queued comes off again (the first in the queue is the current research).
        f.research_queue = before
      end
      if full then
        puppet.message(#need > 1 and ("Research queue full: " .. name .. " needs " .. (#need - 1) .. " more queued first")
          or "Research queue full")
      else
        puppet.message("Can't research " .. name .. " yet")
      end
      break
    end
  end
  send_status()
end

-- Takes a technology off the queue, or stops it if it is the current research.
function M.research_cancel(cmd)
  local f = force()
  local name = type(cmd.name) == "string" and cmd.name or ""
  local current = f.current_research
  if current and current.name == name then
    f.cancel_current_research()
    -- Its progress is now the technology's saved progress, which only `techs` carries (the
    -- window's "researched before it was stopped").
    storage.f3d.techs_dirty = true
  else
    local keep = {}
    for _, queued in ipairs(queue_names(f)) do
      if queued ~= name then
        keep[#keep + 1] = queued
      end
    end
    pcall(function() f.research_queue = keep end)
  end
  send_status()
end

---------------------------------------------------------------------------------------------
-- Events

-- What finished, for the client's chime and notice (K23): `rdone`, one message for the technologies
-- of the character's force finished in a tick (Factorio plays its research_completed sound once when
-- several finish on the same tick, 2.0.34), naming at most DONE_MAX (a /cheat researches hundreds).
local DONE_MAX = 100

-- The level a levelled technology (an infinite one, or one of several levels) has just finished, 0 for
-- one of a single level, whose name says it. LuaTechnology.level is the level being researched, so
-- once one is done it is already the next, unless that was the last.
local function finished_level(tech)
  local proto = tech.prototype
  local first = read(proto, "level") or 1
  local max_level = read(proto, "max_level") or first
  if max_level <= first then
    return 0
  end
  local level = read(tech, "level") or first
  return tech.researched and level or math.max(first, level - 1)
end

-- Joins the tick's `rdone` while it is still waiting in the outbox (reliable: a lost one would lose
-- the chime), else starts one. Only the outbox is read, so every peer joins the same way.
local function note_finished(tech)
  local s = storage.f3d
  local open = s.outbox_tail >= s.outbox_head and s.outbox[s.outbox_tail] or nil
  if not (open and open.t == "rdone" and open.tick == game.tick) then
    open = { t = "rdone", l = {}, tick = game.tick }
    transport.send_reliable(open)
  end
  if #open.l < DONE_MAX then
    open.l[#open.l + 1] = { tech.name, finished_level(tech) }
  else
    open.n = (open.n or 0) + 1
  end
  -- The research after it, the next tick (`rs` waited for the tree, or a second).
  s.research_status_due = true
end

-- Research finished or was undone: the tree, and what can be hand-crafted, need sending again.
function M.on_research_changed(event)
  storage.f3d.techs_dirty = true
  crafting.invalidate()
  local tech = event.research
  if event.name == defines.events.on_research_finished and tech and storage.f3d.client
      and tech.force.name == force().name then
    note_finished(tech)
  end
end

function M.register()
  script.on_event({
    defines.events.on_research_finished,
    defines.events.on_research_reversed,
  }, M.on_research_changed)
end

function M.tick()
  local s = storage.f3d
  -- A save made while an older bridge was sending the tree keeps its job as `part`/`parts`: start
  -- the tree over rather than stop the game on the missing `block`.
  if s.techs_job and not s.techs_job.block then
    s.techs_job = nil
    s.techs_dirty = true
  end
  if s.research_status_due then
    s.research_status_due = nil
    send_status()
  end
  if s.techs_dirty and not s.techs_job then
    s.techs_dirty = nil
    start_techs()
  end
  if s.techs_job then
    if send_tech_parts() then
      send_status()
      -- Research can unlock qualities: `quals` again.
      planners.send_initial()
    end
  elseif (game.tick + 37) % STATUS_INTERVAL == 0 then
    send_status()
  end
end

-- A new client gets the whole tree.
function M.send_initial()
  storage.f3d.techs_dirty = true
  storage.f3d.techs_job = nil
end

return M
