"""Differential live checks of research and the Bonuses window against the game (bughunt research2).

  queue    the research queue as the technology screen drives it: queue a technology with missing prerequisites (the
           chain goes in order), cancel one in the middle (what depends on it leaves the queue too, as Factorio's screen
           does), cancel the current research, a trigger technology is refused, a researched one is refused
  bonuses  every force modifier the Bonuses window lists comes back in `bonus` with the game's own value, the
           character's ones (walking speed, build distance, trash slots, follower robots) included
"""
from __future__ import annotations

from . import live_lib

F = "storage.f3d.puppet.force"


def _lua(code):
    return live_lib.mod_lua(code.replace("\n", " "))


def _queue(c, hello):
    msgs = c.pump(0.6, every=hello)
    rs = live_lib.of_type(msgs, "rs")
    return rs[-1] if rs else None


def check_research_diff(c, hello):
    c.pump(1.0, every=hello)
    _tree(c, hello)
    _recipes(c, hello)
    _bonuses(c, hello)
    _queue_checks(c, hello)


def _bonuses(c, hello):
    fields = {
        "character_running_speed_modifier": 0.25, "character_build_distance_bonus": 3, "character_item_drop_distance_bonus": 2,
        "character_resource_reach_distance_bonus": 4, "character_item_pickup_distance_bonus": 1, "character_loot_pickup_distance_bonus": 5,
        "character_trash_slot_count": 10, "maximum_following_robot_count": 7, "character_reach_distance_bonus": 6,
        "manual_crafting_speed_modifier": 0.5, "inserter_stack_size_bonus": 2, "laboratory_speed_modifier": 0.2,
    }

    before = {}
    for k in fields:
        before[k] = _lua(f"rcon.print(tostring({F}.{k}))")
    for k, v in fields.items():
        _lua(f"{F}.{k} = {v} rcon.print('')")
    c.send({"t": "bonuses"})
    msgs = c.pump(1.0, every=hello, until=lambda m: m.get("t") == "bonus")
    got = {r[0]: r[1] for m in live_lib.of_type(msgs, "bonus") for r in m["l"]}
    for k, v in fields.items():
        live_lib.report(abs(got.get(k, -999) - v) < 0.002, f"bonuses: {k} reaches the Bonuses window with the game's value", f"want {v} got {got.get(k)}")
    for k, v in before.items():
        _lua(f"{F}.{k} = {v if v not in ('nil', '') else 0} rcon.print('')")


def _queue_checks(c, hello):
    # every trigger technology done, every other one open, so a chain of science technologies is what is missing
    _lua(f"local f = {F} f.research_queue = {{}} for _, t in pairs(f.technologies) do if t.enabled and not t.prototype.hidden then "
         "t.researched = t.prototype.research_trigger ~= nil end end rcon.print('')")
    c.pump(0.5, every=hello)
    c.send({"t": "research", "name": "automation-2"})
    got = c.pump(0.8, every=hello)
    for m in got:
        if m.get("t") == "msg":
            print("INFO research msg:", m.get("text"))
    q = _lua(f"local out = {{}} for _, t in pairs({F}.research_queue) do out[#out+1] = t.name end rcon.print(table.concat(out, ','))")
    live_lib.report(q.endswith("automation-2") and "," in q, "research: a technology with missing prerequisites queues them first, in order", q)
    names = q.split(",")
    if len(names) >= 3:
        # cancel the middle one: what depends on it must go as well
        mid = names[1]
        c.send({"t": "research_cancel", "name": mid})
        c.pump(0.6, every=hello)
        after = _lua(f"local out = {{}} for _, t in pairs({F}.research_queue) do out[#out+1] = t.name end rcon.print(table.concat(out, ','))").split(",")
        ok = mid not in after and "automation-2" not in after
        live_lib.report(ok, "research: cancelling a queued technology takes what depends on it off the queue (Factorio's screen)", f"{q} -> {','.join(after)}")
    c.send({"t": "research_cancel", "name": names[0]})
    c.pump(0.6, every=hello)
    cur = _lua(f"rcon.print({F}.current_research and {F}.current_research.name or '-')")
    qq = _lua(f"local out = {{}} for _, t in pairs({F}.research_queue) do out[#out+1] = t.name end rcon.print(table.concat(out, ','))")
    live_lib.report(cur not in qq.split(",")[1:] and (names[0] not in qq.split(",")),
                    "research: cancelling the current research drops it, and the next one in the queue is not left without its prerequisite",
                    f"current {cur}, queue {qq}")
    # a trigger technology is refused
    trig = _lua(f"for n, t in pairs({F}.technologies) do if t.prototype.research_trigger and t.enabled and not t.researched then rcon.print(n) return end end rcon.print('-')")
    if trig != "-":
        c.send({"t": "research", "name": trig})
        c.pump(0.6, every=hello)
        inq = _lua(f"local out = false for _, t in pairs({F}.research_queue) do if t.name == '{trig}' then out = true end end rcon.print(tostring(out))")
        live_lib.report(inq == "false", "research: a trigger technology is never queued", trig)
    _lua(f"{F}.research_queue = {{}} rcon.print('')")


def _tree(c, hello):
    """The technology list the client gets against the game's own: the same shown set, and per technology the
    state, unit count, unit time, ingredients, prerequisites, level and max level."""
    _lua("storage.f3d.techs_dirty = true rcon.print('')")
    msgs = c.pump(4.0, every=hello)
    recs = {r[0]: r for m in live_lib.of_type(msgs, "techs") for r in m["l"]}
    want = _lua(f"local out = {{}} for n, t in pairs({F}.technologies) do local p = t.prototype if not p.hidden and (t.enabled or t.visible_when_disabled) then out[#out+1] = n end end table.sort(out) rcon.print(#out)")
    live_lib.report(len(recs) == int(want or 0) and len(recs) > 0, "techs: the client's list has exactly the technologies the game shows", f"{len(recs)} vs {want}")
    bad = []
    for name in sorted(recs)[::3]:
        r = recs[name]
        out = _lua(f"local t = {F}.technologies['{name}'] local pre = {{}} for n in pairs(t.prerequisites) do pre[#pre+1] = n end table.sort(pre) "
                   "local ing = {} for _, i in pairs(t.research_unit_ingredients) do ing[#ing+1] = i.name .. '=' .. i.amount end table.sort(ing) "
                   "local st = t.researched and 2 or 1 if not t.researched then for _, p in pairs(t.prerequisites) do if not p.researched then st = 0 end end end "
                   "rcon.print(table.concat({ st, t.research_unit_count, t.research_unit_energy / 60, table.concat(pre, ','), table.concat(ing, ',') }, '|'))")
        mine = "|".join([str(r[6]), str(r[4]), str(r[5]), ",".join(r[2]), ",".join(sorted(f"{i[0]}={i[1]}" for i in r[3]))])
        norm = lambda v: v.replace(".0|", "|")
        if mine != out and norm(mine) != norm(out):
            bad.append((name, mine, out))
    live_lib.report(not bad, "techs: state, unit count, unit time, ingredients and prerequisites match the game's", str(bad[:3]))


def _recipes(c, hello):
    """The crafting panel's recipes (`rdet`) are the force's enabled, visible recipes the character can craft by hand,
    before and after a technology that unlocks hand-craftable recipes is researched / undone."""
    tech = _lua(f"for n, t in pairs({F}.technologies) do if t.enabled and not t.researched and not t.prototype.research_trigger then "
                "for _, e in pairs(t.prototype.effects or {}) do if e.type == 'unlock-recipe' and prototypes.recipe[e.recipe] "
                f"and (function() local p = prototypes.recipe[e.recipe] local ok, c = pcall(function() return p.category end) if ok then return c == 'crafting' end for _, k in pairs(p.categories) do if k == 'crafting' then return true end end return false end)() and not {F}.recipes[e.recipe].enabled then rcon.print(n .. ' ' .. e.recipe) return end end end end rcon.print('-')").split()
    if len(tech) != 2:
        print("INFO research: no technology with a hand-craftable recipe left to unlock")
        return
    name, recipe = tech

    def listed():
        _lua("storage.f3d.rdet_sig = nil storage.f3d.craftable_sig = nil rcon.print('')")
        msgs = c.pump(2.0, every=hello)
        return {r[0] for m in live_lib.of_type(msgs, "rdet") for r in m["l"]}

    before = listed()
    _lua(f"{F}.technologies['{name}'].researched = true rcon.print('')")
    after = listed()
    live_lib.report(recipe not in before and recipe in after, f"recipes: {recipe} is in the crafting panel once {name} is researched, not before", f"{len(before)} -> {len(after)}")
    _lua(f"{F}.technologies['{name}'].researched = false rcon.print('')")
    gone = listed()
    live_lib.report(recipe not in gone, f"recipes: and gone again when {name} is undone", "")
