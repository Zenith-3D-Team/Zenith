"""Differential live checks of the logistics windows against the real game (bughunt logi2): the five logistic
chests' screens (mode, requests, storage filter, trash unrequested, request from buffers, the network's
contents and robot counts), request edits as the client sends them against what the game then holds, the
character's personal logistics and the logistic networks window's lists against LuaLogisticNetwork.
Run: python tools/live_check.py --only logidiff"""
from __future__ import annotations

from . import live_lib

CHESTS = ["passive-provider-chest", "active-provider-chest", "storage-chest", "buffer-chest", "requester-chest"]
MODES = {"passive-provider-chest": "passive-provider", "active-provider-chest": "active-provider", "storage-chest": "storage",
         "buffer-chest": "buffer", "requester-chest": "requester"}


def check_logistics_diff(c, hello):
    if not live_lib.clean_spot(c, hello):
        live_lib.report(False, "logidiff: no clean spot found", live_lib.SPOT_WHY)
        return
    x, y = c.me["x"] / 256, c.me["y"] / 256
    fx = lambda v: int(round(v * 256))
    lua = lambda code: live_lib.mod_lua(code.replace("\n", " "))
    out = lua(f"""
local c = storage.f3d.puppet local s = c.surface local f = c.force
storage.f3d_logidiff = {{}}
storage.f3d_logidiff_char = f.character_logistic_requests
f.character_logistic_requests = true
local function mk(n, dx, dy) local e = s.create_entity({{ name = n, position = {{ {x} + dx, {y} + dy }}, force = f, raise_built = true }}) if e then storage.f3d_logidiff[#storage.f3d_logidiff + 1] = e end return e end
local port = mk('roboport', -7, 7)
mk('electric-energy-interface', -12, 7)
mk('substation', -7, 3)
port.get_inventory(defines.inventory.roboport_robot).insert({{ name = 'logistic-robot', count = 3 }})
port.get_inventory(defines.inventory.roboport_robot).insert({{ name = 'construction-robot', count = 2 }})
local res = {{}}
local dx = -4.5
for _, n in ipairs({{ 'passive-provider-chest', 'active-provider-chest', 'storage-chest', 'buffer-chest', 'requester-chest' }}) do
  local e = mk(n, dx, 6.5) dx = dx + 2
  res[#res + 1] = n .. '=' .. e.unit_number .. ':' .. e.position.x .. ':' .. e.position.y
end
rcon.print(port.unit_number .. ' ' .. table.concat(res, ' '))""")
    parts = out.split()
    if len(parts) != 6:
        live_lib.report(False, "logidiff: building the network", out)
        return
    chests = {}
    for p in parts[1:]:
        n, rest = p.split("=")
        u, ex, ey = rest.split(":")
        chests[n] = (int(u), float(ex), float(ey))
    c.pump(2.0, every=hello)

    def screen(name):
        u, ex, ey = chests[name]
        c.send({"t": "close"})
        c.pump(0.15, every=hello)
        c.send({"t": "open", "u": u, "p": c.proto_id(name), "x": fx(ex), "y": fx(ey)})
        g = [m for m in c.pump(0.5, every=hello) if m.get("t") == "gui" and m.get("u") == u]
        return g[-1] if g else {}

    def entity(u):
        return (f"(function() local c = storage.f3d.puppet for _, e in pairs(c.surface.find_entities_filtered({{ position = c.position, radius = 40, force = c.force }})) do "
                f"if e.unit_number == {u} then return e end end end)()")

    def filters_of(name):
        """Every section's filters as the game holds them: 'section:item:min:max;...'."""
        return lua(f"local e = {entity(chests[name][0])} local out = {{}} for i, sec in ipairs(e.get_logistic_sections().sections) do "
                   "for _, fl in pairs(sec.filters) do out[#out + 1] = i .. ':' .. fl.value.name .. ':' .. (fl.min or 'nil') .. ':' .. (fl.max or 'nil') end end "
                   "rcon.print(table.concat(out, ';'))")

    # 1. Each chest's screen against its prototype and the network.
    for name in CHESTS:
        g = screen(name)
        lg = g.get("lg", {})
        live_lib.report(lg.get("mode") == MODES[name], f"logidiff {name}: the screen's mode", str(lg)[:200])
        has_trash = len((g.get("slots") or {}).get("trash") or []) > 0
        want_trash = name in ("buffer-chest", "requester-chest")
        live_lib.report(has_trash == want_trash, f"logidiff {name}: trash slots only on buffer and requester chests", str(list((g.get("slots") or {}).keys())))
        lc = g.get("lc")
        live_lib.report((lc is not None) == want_trash, f"logidiff {name}: lc (sections, trash unrequested) only for requester and buffer", str(lc)[:200])
        if name == "requester-chest":
            live_lib.report(lc and "rb" in lc, "logidiff requester-chest: Request from buffer chests offered", str(lc)[:200])
        if name == "buffer-chest":
            live_lib.report(lc and "rb" not in lc, "logidiff buffer-chest: no Request from buffer chests", str(lc)[:200])
        net = lg.get("net") or {}
        truth = lua(f"local n = {entity(chests[name][0])}.logistic_network rcon.print(n.network_id .. ' ' .. n.available_logistic_robots .. ' ' .. n.all_logistic_robots .. ' ' .. n.available_construction_robots .. ' ' .. n.all_construction_robots)").split()
        got = [net.get("id"), (net.get("log") or [0, 0])[1], (net.get("con") or [0, 0])[1]]
        truth = [truth[0], truth[2], truth[4]]  # the available ones move with the robots' jobs
        live_lib.report([str(v) for v in got] == truth, f"logidiff {name}: network id and robot counts", f"{got} vs {truth}")
    # contents
    lua(f"local e = {entity(chests['storage-chest'][0])} e.insert({{ name = 'iron-plate', count = 40 }}) "
        f"{entity(chests['passive-provider-chest'][0])}.insert({{ name = 'iron-plate', count = 10 }}) "
        f"{entity(chests['requester-chest'][0])}.insert({{ name = 'copper-plate', count = 7 }})")
    c.pump(0.3, every=hello)
    g = screen("storage-chest")
    items = {i[0]: i[1] for i in g.get("lg", {}).get("net", {}).get("items", [])}
    truth = lua(f"local out = {{}} for _, e in pairs({entity(chests['storage-chest'][0])}.logistic_network.get_contents()) do out[#out + 1] = e.name .. '=' .. e.count end table.sort(out) rcon.print(table.concat(out, ','))")
    live_lib.report(",".join(sorted(f"{k}={v}" for k, v in items.items())) == truth, "logidiff: the network's items are get_contents", f"{items} vs {truth}")

    # 2. Request edits.
    u, ex, ey = chests["requester-chest"]
    cases = [
        ("min over max raises max", [["iron-plate", 100, 50]], "1:iron-plate:100:100"),
        ("max 0", [["iron-plate", 0, 0]], "1:iron-plate:0:0"),
        ("no max", [["iron-plate", 10, -1]], "1:iron-plate:10:nil"),
        ("two items", [["iron-plate", 10, -1], ["copper-plate", 5, 20]], "1:iron-plate:10:nil;1:copper-plate:5:20"),
        ("duplicate item merged", [["iron-plate", 10, -1], ["iron-plate", 20, -1]], "1:iron-plate:20:nil"),
        ("unknown item ignored", [["no-such-item", 10, -1], ["coal", 1, -1]], "1:coal:1:nil"),
        ("a fluid ignored", [["water", 10, -1]], ""),
        ("cleared", [], ""),
    ]
    for label, lst, want in cases:
        screen("requester-chest")
        c.send({"t": "set_requests", "u": u, "l": lst})
        c.pump(0.3, every=hello)
        got = filters_of("requester-chest")
        live_lib.report(got == want, f"logidiff requests: {label}", f"{got!r} vs {want!r}")
    # what the screen shows afterwards is what the game holds
    c.send({"t": "set_requests", "u": u, "l": [["iron-plate", 12, 30]]})
    g = screen("requester-chest")
    secs = (g.get("lc") or {}).get("sec", [])
    live_lib.report(secs and secs[0].get("f") and secs[0]["f"][0][0] == "iron-plate" and secs[0]["f"][0][2:4] == [12, 30],
                    "logidiff requests: the section's filter the screen shows", str(secs)[:300])
    live_lib.report(g.get("lg", {}).get("requests") == [["iron-plate", 12, 30]], "logidiff requests: lg.requests", str(g.get("lg", {}).get("requests")))

    # 3. Storage filter.
    su = chests["storage-chest"][0]
    screen("storage-chest")
    for item, want in (("iron-plate", "iron-plate"), ("water", "iron-plate"), ("no-such", "iron-plate"), ("", "")):
        c.send({"t": "set_storage_filter", "u": su, "item": item})
        c.pump(0.3, every=hello)
        got = lua(f"local f = {entity(su)}.get_filter(1) rcon.print(f and (type(f) == 'string' and f or f.name.name or f.name) or '')")
        live_lib.report(got == want, f"logidiff storage filter {item!r}", f"{got!r} vs {want!r}")

    # 4. Trash unrequested / request from buffers on each type.
    for name in ("requester-chest", "buffer-chest"):
        cu = chests[name][0]
        screen(name)
        c.send({"t": "set_chest_logistics", "u": cu, "tu": 1, "rb": 1})
        g = screen(name)
        lc = g.get("lc", {})
        tru = lua(f"local e = {entity(cu)} rcon.print(tostring(e.get_logistic_point(defines.logistic_member_index.logistic_container).trash_not_requested) .. ' ' .. tostring(e.request_from_buffers))").split()
        live_lib.report(lc.get("tu") == 1 and tru[0] == "true", f"logidiff {name}: trash unrequested", f"{lc} vs {tru}")
        if name == "requester-chest":
            live_lib.report(lc.get("rb") == 1 and tru[1] == "true", f"logidiff {name}: request from buffer chests", f"{lc} vs {tru}")
        c.send({"t": "set_chest_logistics", "u": cu, "tu": 0, "rb": 0})
        g = screen(name)
        live_lib.report(g.get("lc", {}).get("tu") == 0, f"logidiff {name}: trash unrequested off again", str(g.get("lc")))

    # 5. Sections on a chest.
    screen("requester-chest")
    c.send({"t": "set_requests", "u": u, "l": []})
    c.send({"t": "set_section", "u": u, "i": 0, "g": "", "f": [["coal", "normal", 5, 15, "", -1]]})
    c.pump(0.4, every=hello)
    n_secs = int(lua(f"rcon.print(#{entity(u)}.get_logistic_sections().sections)"))
    g = screen("requester-chest")
    live_lib.report(n_secs == len((g.get("lc") or {}).get("sec", [])), "logidiff sections: count shown = the game's", f"{n_secs} vs {(g.get('lc') or {}).get('sec')}")
    c.send({"t": "set_section", "u": u, "i": n_secs, "on": 0})
    c.pump(0.3, every=hello)
    g = screen("requester-chest")
    reqs = g.get("lg", {}).get("requests")
    live_lib.report(reqs in ([], {}), "logidiff sections: an inactive section's requests aren't listed", str(reqs))
    c.send({"t": "set_section", "u": u, "i": n_secs, "on": 1, "m": 3})
    c.pump(0.3, every=hello)
    mult = lua(f"rcon.print({entity(u)}.get_logistic_sections().sections[{n_secs}].multiplier)")
    live_lib.report(mult == "3", "logidiff sections: multiplier", mult)
    c.send({"t": "set_section", "u": u, "i": n_secs, "del": 1})
    c.send({"t": "set_section", "u": u, "i": 9, "del": 1})
    c.pump(0.3, every=hello)

    # 6. The character's personal logistics.
    c.send({"t": "set_char_requests", "l": []})
    c.pump(0.3, every=hello)

    def clog_after(msg):
        c.send(msg)
        got = live_lib.of_type(c.pump(0.7, every=hello), "clog")
        return got[-1] if got else {}

    def point_filters():
        return lua("local p = storage.f3d.puppet.get_requester_point() local out = {} for i, sec in ipairs(p.sections) do "
                   "for _, fl in pairs(sec.filters) do out[#out + 1] = i .. ':' .. fl.value.name .. ':' .. (fl.min or 'nil') .. ':' .. (fl.max or 'nil') end end "
                   "rcon.print(table.concat(out, ';'))")

    for label, lst, want in (
        ("a request", [["coal", 10, 20]], "1:coal:10:20"),
        ("min over max", [["coal", 30, 20]], "1:coal:30:30"),
        ("max 0 (trash all)", [["coal", 0, 0]], "1:coal:0:0"),
        ("cleared", [], ""),
    ):
        m = clog_after({"t": "set_char_requests", "l": lst})
        got = point_filters()
        live_lib.report(got == want, f"logidiff character requests: {label}", f"{got!r} vs {want!r} clog {m.get('l')}")
    m = clog_after({"t": "set_char_requests", "l": [["coal", 10, -1]], "on": 0, "trash": 1})
    en = lua("local p = storage.f3d.puppet.get_requester_point() rcon.print(tostring(p.enabled) .. ' ' .. tostring(p.trash_not_requested))")
    live_lib.report(en == "false true" and m.get("on") == 0 and m.get("trash") == 1, "logidiff character: personal logistics off, trash unrequested on", f"{en} vs {m.get('on')} {m.get('trash')}")
    m = clog_after({"t": "set_char_requests", "on": 1, "trash": 0})
    live_lib.report(m.get("on") == 1 and m.get("trash") == 0, "logidiff character: switches back", str(m)[:200])
    # sections: add, group, off, delete; l lists only the active ones' requests
    m = clog_after({"t": "set_section", "u": 0, "i": 0, "f": [["iron-plate", "normal", 5, 9, "", -1]]})
    n = int(lua("rcon.print(#storage.f3d.puppet.get_requester_point().sections)"))
    live_lib.report(len(m.get("sec", [])) == n, "logidiff character sections: count", f"{n} vs {len(m.get('sec', []))}")
    live_lib.report(["iron-plate", 5, 9] in m.get("l", []) and ["coal", 10, -1] in m.get("l", []), "logidiff character: l holds every active section's requests", str(m.get("l")))
    m = clog_after({"t": "set_section", "u": 0, "i": n, "on": 0})
    live_lib.report(["iron-plate", 5, 9] not in m.get("l", []) and ["coal", 10, -1] in m.get("l", []), "logidiff character: an inactive section's requests leave l", str(m.get("l")))
    m = clog_after({"t": "set_section", "u": 0, "i": n, "del": 1})
    live_lib.report(len(m.get("sec", [])) == n - 1, "logidiff character sections: delete", str(len(m.get("sec", []))))
    m = clog_after({"t": "set_char_requests", "l": []})
    # deleting the last section: the game's rule
    left = int(lua("rcon.print(#storage.f3d.puppet.get_requester_point().sections)"))
    m = clog_after({"t": "set_section", "u": 0, "i": 1, "del": 1})
    after = int(lua("rcon.print(#storage.f3d.puppet.get_requester_point().sections)"))
    live_lib.report(len(m.get("sec", [])) == after, "logidiff character sections: shown count = the game's after deleting section 1", f"{left} -> {after}, shown {len(m.get('sec', []))}")

    # 7. The logistic networks window's lists against LuaLogisticNetwork.
    c.send({"t": "lnets"})
    nets = live_lib.of_type(c.pump(0.8, every=hello), "lnets")
    rows = {r[0]: r for r in (nets[-1]["l"] if nets else [])}
    truth = lua("local out = {} for sname, list in pairs(storage.f3d.puppet.force.logistic_networks) do for _, n in pairs(list) do "
                "out[#out + 1] = n.network_id .. ':' .. n.all_logistic_robots .. ':' .. n.all_construction_robots .. ':' .. #n.cells .. ':' .. #n.storages .. ':' .. #n.providers .. ':' .. #n.requesters end end "
                "rcon.print(table.concat(out, ' '))")
    want = {int(v.split(':')[0]): [int(i) for i in v.split(':')] for v in truth.split()}
    ok = bool(rows) and set(rows) == set(want) and all(
        [rows[k][3][1], rows[k][4][1], rows[k][5], rows[k][6], rows[k][7], rows[k][8]] == want[k][1:] for k in want)
    live_lib.report(ok, "logidiff lnets: every network's robots, cells, storages, providers, requesters", f"{rows} vs {want}")
    mine = chests["storage-chest"]
    nid = int(lua(f"rcon.print({entity(mine[0])}.logistic_network.network_id)"))
    c.send({"t": "lnet", "id": nid})
    one = live_lib.of_type(c.pump(0.8, every=hello), "lnet")
    items = {i[0]: i[1] for i in (one[-1].get("items", []) if one else [])}
    tr = lua(f"local out = {{}} for _, e in pairs({entity(mine[0])}.logistic_network.get_contents()) do out[#out + 1] = e.name .. '=' .. e.count end table.sort(out) rcon.print(table.concat(out, ','))")
    live_lib.report(bool(one) and one[-1].get("found") == 1 and ",".join(sorted(f"{k}={v}" for k, v in items.items())) == tr,
                    "logidiff lnet: the items are the network's get_contents", f"{items} vs {tr}")

    # 8. The roboport's screen.
    c.send({"t": "close"})
    c.pump(0.2, every=hello)
    pu = int(parts[0])
    prx = lua(f"local e = {entity(pu)} rcon.print(e.position.x .. ' ' .. e.position.y)").split()
    c.send({"t": "open", "u": pu, "p": c.proto_id("roboport"), "x": fx(float(prx[0])), "y": fx(float(prx[1]))})
    g = [m for m in c.pump(0.6, every=hello) if m.get("t") == "gui" and m.get("u") == pu]
    g = g[-1] if g else {}
    st = lua(f"local e = {entity(pu)} for k, v in pairs(defines.entity_status) do if v == e.status then rcon.print(k) end end")
    live_lib.report(g.get("status") == st, "logidiff roboport: status is the game's", f"{g.get('status')} vs {st}")
    robots = {s[0]: s[1] for s in (g.get("slots") or {}).get("robots", []) if s}
    live_lib.report(robots.get("logistic-robot", 0) >= 3 and robots.get("construction-robot", 0) >= 2, "logidiff roboport: robot slots", str(robots))

    # 9. Odd inputs: nothing crashes, nothing half-written.
    screen("requester-chest")
    c.send({"t": "set_requests", "u": u, "l": [["iron-plate", 10, 20]]})
    c.pump(0.3, every=hello)
    before = filters_of("requester-chest")
    junk = [
        ("a huge min leaves the list as it was", [["iron-plate", 10 ** 12, -1]], before),
        ("float and string counts are floored", [["iron-plate", "7.9", 8.2]], "1:iron-plate:7:8"),
        ("a negative min is 0", [["iron-plate", -5, -1]], "1:iron-plate:0:nil"),
        ("an unknown quality is normal", [["iron-plate", 5, -1, "no-such-quality"]], "1:iron-plate:5:nil"),
    ]
    for label, lst, want in junk:
        c.send({"t": "set_requests", "u": u, "l": lst})
        c.pump(0.3, every=hello)
        got = filters_of("requester-chest")
        live_lib.report(got == want, f"logidiff odd input: {label}", f"{got!r} vs {want!r}")
    c.send({"t": "set_requests", "u": u, "l": "nope"})
    c.send({"t": "set_section", "u": u, "i": "x", "f": "y"})
    c.send({"t": "set_section", "u": u, "i": 1.5, "on": 5, "m": -2})
    c.send({"t": "set_section", "u": u, "i": 1, "g": "x" * 300})
    c.send({"t": "set_section", "u": u, "i": 1, "f": [["iron-plate", "normal", 10 ** 12, -1, "", -1]]})
    c.pump(0.5, every=hello)
    live_lib.report(filters_of("requester-chest") == "1:iron-plate:5:nil", "logidiff odd input: malformed sections change nothing", filters_of("requester-chest"))
    c.send({"t": "close"})
    c.pump(0.2, every=hello)
    lua("for _, e in pairs(storage.f3d_logidiff or {}) do if e.valid then e.destroy() end end storage.f3d_logidiff = nil "
        "if storage.f3d_logidiff_char ~= nil then storage.f3d.puppet.force.character_logistic_requests = storage.f3d_logidiff_char end")
    c.pump(0.3, every=hello)
