#!/usr/bin/env python3
"""Checks the bridge against a running headless Factorio, the way the Godot client uses it.

    powershell -ExecutionPolicy Bypass -File server\\run-server.ps1     (or server/run-headless.sh)
    python3 tools/live_check.py

Close the Godot client first: this binds the client's port (34201). It plays the client over
UDP (handshake, chunks, walking, building (turning, fast-replace, rails, quality), rotating,
mining, items on belts and on the ground, fluids, wires and power, blueprints and planners,
circuits, the map, logistics, trains, combat, vehicles, inventory slots, quickbar, crafting, research, machine
screens) and uses RCON (tools/rcon.py) for what the protocol can't show: the datagram size limit, table_to_json on an
empty table, whether world.record copes with every entity type, and how long a chunk snapshot
takes.

Every message received is checked with tools/protocol.py. Commands starting with /c run Lua in
the mod's own state (`/c __factorio-3d-bridge__ ...`), which disables achievements for the save.

A second server instance on other ports (run-server.ps1 -UdpPort/-RconPort):
    python3 tools/live_check.py --factorio-port 34210 --client-port 34211 --rcon-port 34298
`--binary`: every hello asks for binary frames (`bin`), read as the client reads them (docs/PROTOCOL.md);
`--only platforms` runs just the handshake and the space platform checks (needs Space Age);
`--only pickup` F taking items off belts and the ground (`pku`), after an INFO line on Factorio's own picking_state;
`--only ride` riding a rocket up to a platform's hub and a cargo pod down (`ride`, `land`);
`--only collectors` asteroid collectors' arms (`acol`: arm count, speed, filters, caught chunks);
`--only space` Space Age's screens (a silo launching a new platform's starter pack, the hub's
schedule and requests, landing pad, collector, module effects, quality);
`--only save` the handshake and taking over a loaded save's player (use a copy of the save:
the player's things move onto the bridge's character); `--only input` slot clicks and transfers (move, xfer, fast on belts and labs) against 2.1.23's own rules; `--only ui` the handshake and the UI parity checks (drop, fast transfer, settings, flip, clipboard,
Alt-mode, chat, statistics, inserter / splitter / switch / turret / chest bar screens); `--only gear`
the character's gear (armour grid, equipment commands and switches, the character tab, players, a
tank's grid, death and respawn; use a copy of a save: the character dies); `--only planners`
the blueprint and planner checks (exchange strings, the libraries, undo, super-forced building);
`--only circuits` the wire tools and every entity's circuit and own settings (combinators in full, lamps, speakers, pumps,
turrets, display panels); `--only build` tiles, capsules, the rail planner (its extension table too) and what drag building sends;
`--only info` the handshake and the information windows: alerts, Factoriopedia, the logistic
networks window, statistics (build counts, pollution, graphs) and technology details (best on a
copy of a busy save, which has networks, trains and research to show)); `--only alerts` the alerts the mod works out (turret
without ammo, attack, destruction, a ghost without material); `--only multi` a second client on
the same server; `--only logic` the logic, train and vehicle windows' data (always on, descriptions,
an inserter's hand, burner bars, rail signals, a stop's trains, a locomotive's name and colour, a
wagon's limit, a car's guns); `--only machines` Factorio's production windows (machine_info.lua: recipe details, the
chooser's groups, productivity, burners, drills, temperature, labs, a requester's settings);
`--only turrets` turret states (`ts`: every turret, a tank and a spidertron aiming and firing at biters);
`--only enemies` enemies' attacks (`en`) and the decals round nests; `--only mapinfo` the hover panel's beacon effects (`hinfo`) and `terr`'s surface; `--only console` the client's console
(Lua commands with its prelude over RCON, `cmd`, and /cheat, which researches everything); `--only remote` the 3D remote view leaving out moving things no radar sees (`cov`); `--only remnants` what destroyed buildings leave (extra.rm) and
linked belts' ends; `--only barrier` the error barrier (barrier.lua): a tick step and an event handler
made to fail, the game and the other steps going on (`--server-log` points at the server's
factorio-current.log when it isn't server/data's); `--only research` research finishing (`rdone`: a
technology researched by script named once, an infinite one by the level it finished); `--only join` a world
Zenith made (L13; run it on a fresh map nobody joined): freeplay's crash site turned off through its 2.1 interface,
and a hello's `pn` kept, claiming nobody when no player has that name (a player joining can't be played headless:
test_bridge.py does that against the fake API); `--only underclear` an underground pair built over belts mining the belts
between (M2: a plain run, a side-loaded one kept, pipes-to-ground over pipes, the switch off), after an INFO line on what
a script's own create_entity{fast_replace, character} does to the run; `--only vehitems` vehicles (N2: Ctrl+click into a
car, tank, spidertron, locomotive and cargo wagon and out of them; N3: the vehicle's `guns`, `gun` and `vammo` while
driving, and a printed line on whether `shoot` fires the vehicle's gun; N4: `repair` on a car and a cargo wagon);
`--only pipeend` the pipes and belts beside what the bridge's character mines (no event raised) sent again with
their new shapes: a run's ends, a corner, a T losing its branch, a cross an arm, pipes-to-ground, a pump and a tank
going, belts straightened and curved, a pipe `die`d and one a robot takes, `/f3d-perf mined_neighbours off`; walls and
heat pipes only their `del` (the client joins them).
`--only steps` the character's steps from the prototypes (`steps`:
every part, every tile, silent only where the player can't walk, the files in the install, again on a resync and a
reconnect).
`--only enemysight` a diagnostic, not in the full run: do idle biters notice the bridge's player-less character walking up
(three small biters left idle 60 tiles off, approached to 20 and 8 tiles), one shot at one of them, a small worm approached
inside its range, and the two candidate fixes tried by hand (a wander command with distraction by_enemy; a distraction
command to attack the character), then the nearest nest the map made, with the bridge's fix (/f3d-perf enemy_sight)
off and on: its biters attack the approaching character only with it on, the whole nest at once, held about 40 s while
it stands and dropping off gradually, and chasing it 150 tiles away (a real player's measured behaviour); prints raw
numbers (commands, distances, ticks, damage) per step. Steps 2-5 run with the fix off.
`--only enemysightfix` steps 1 and 6 alone. Run them on a fresh map: they destroy the enemies within 200 tiles of the spot,
and step 6 runs the game fast (speed 10) for up to 5 minutes until the nest owns 8 idle biters.
`--only link` the add-on link (`ext`, link.lua) with the fixture mod tools/mod_tests/fixtures/zenith-link-test in the
server's mods: an echo there and back, `who` naming this client's character, the caps on a flood both ways and on a
message over 4 KB, a bad channel dropped, a second client answered alone and its coming and going raised. Run it
twice, the server restarted on the saved game in between (`/server-save`, then run-server.ps1 -Save), so the second
run checks the mod's on_load path: the bridge's event ids made again on loading.
`--only sprint` the Sprint add-on's Factorio mod (addons-src/sprint/mod/zenith-sprint, with the fixture mod above, both in
the server's mods) played as the add-on would: on, held, off, the 90-tick time-out, a client dropping mid-sprint, another
mod's change to the running speed surviving; then garbage `ext`, a stranger's port and an `ext` before the welcome.
"""

from __future__ import annotations

import argparse
import pathlib
import sys

TOOLS = pathlib.Path(__file__).resolve().parent
if str(TOOLS) not in sys.path:
    sys.path.insert(0, str(TOOLS))

import protocol  # noqa: E402
import rcon  # noqa: E402
from live import (  # noqa: E402
    building_and_planners,
    combat_and_enemies,
    core_suite,
    live_lib,
    machines_and_vehicles,
    player_and_ui,
    space_and_planets,
    world_and_multi,
)
from live.building_and_planners import (  # noqa: E402
    PIPE_STEPS,
    bp_record,
    bp_reply,
    bp_string,
    check_alt,
    check_alt_machines,
    check_alt_stock,
    check_belt_switch,
    check_build_tools,
    check_flips,
    check_pipe_end,
    check_pipe_vis,
    check_planner_modes,
    check_planners,
    check_splitter_snap,
    check_under_clear,
    client_own_pipelines,
    client_pipelines,
    game_tiles,
    rail_path,
)
from live.combat_and_enemies import (  # noqa: E402
    car_compare,
    check_enemies,
    check_enemy_sight,
    check_turrets,
    check_weapons,
    fix_compare,
)
from live.live_lib import (  # noqa: E402
    BINARY,
    CLIENT_PORT,
    FACTORIO_PORT,
    GODOT,
    MOD,
    SECOND_CLIENT_PORT,
    SERVER_LOG,
    SPOT_WHY,
    SURFACE_WAIT,
    WATCH_PENDING,
    Client,
    clean_spot,
    clear_enemies,
    destroy_units,
    handshake,
    inv_count,
    mod_lua,
    of_type,
    report,
    report_step_errors,
    results,
    watch_around,
)
from live.machines_and_vehicles import (  # noqa: E402
    check_circuits,
    check_logic,
    check_machines,
    check_map_info,
    check_mine_vehicles,
    check_remote_view,
    check_repair,
    check_states,
    check_vehicle_items,
    check_vehicles,
)
from live.player_and_ui import (  # noqa: E402
    check_build_marks,
    check_gear,
    check_hand_stack,
    check_hud,
    check_info,
    check_input,
    check_pickup,
    check_research,
    check_triggers,
    check_ui_parity,
    check_walk,
    eq_of,
)
from live.space_and_planets import (  # noqa: E402
    check_collectors,
    check_planets,
    check_platforms,
    check_ride,
    check_space,
)
from live.world_and_multi import (  # noqa: E402
    SAVE_SUMMARY,
    check_alerts,
    check_as_player,
    check_barrier,
    check_cliffs,
    check_console,
    check_decoratives,
    check_join,
    check_link,
    check_mod_graphics,
    check_multi,
    check_remnants,
    check_save,
    check_sprint,
    check_steps,
    handshake_msgs,
    link_get,
    lua_command,
    server_log,
    step_errors,
    steps_parts,
)


def parse_args():
    global FACTORIO_PORT, CLIENT_PORT, SECOND_CLIENT_PORT, SERVER_LOG, GODOT, BINARY
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--factorio-port", type=int, default=FACTORIO_PORT, help="the server's --enable-lua-udp port")
    parser.add_argument("--client-port", type=int, default=CLIENT_PORT, help="the port this binds, as the client would")
    parser.add_argument("--rcon-port", type=int, default=rcon.PORT)
    parser.add_argument("--godot", help="the Godot binary for pipevis's run of the client's own rule (default: $GODOT, godot on PATH)")
    parser.add_argument("--rcon-password", help="default: server/data/rcon-password.txt")
    parser.add_argument("--second-client-port", type=int, default=0, help="the two-client check's second client (default: the client port + 1)")
    parser.add_argument("--server-log", help="the server's factorio-current.log, for the barrier check (default: server/data's, "
                                             "when it is this server's)")
    parser.add_argument("--only", choices=["platforms", "planets", "space", "ride", "collectors", "ui", "input", "cliffs", "save", "gear", "planners", "circuits", "build", "info",
                                           "alerts", "multi", "remnants", "machines", "logic", "vehicles", "hud", "turrets", "weapons", "enemies", "console", "remote", "walk", "pickup", "states", "repair", "mapinfo", "triggers", "minevehicles", "alt", "asplayer", "modgfx", "beltswitch", "barrier", "research", "join", "underclear", "vehitems", "pipeend", "pipevis", "link", "sprint", "steps", "enemysight", "enemysightfix"], help="run just these checks after the handshake")
    parser.add_argument("--binary", action="store_true", help="every hello asks for binary frames (bin): the checks read "
                        "them as the client does (protocol.py), and the end says how many datagrams came binary")
    args = parser.parse_args()
    BINARY = live_lib.BINARY = args.binary
    FACTORIO_PORT = live_lib.FACTORIO_PORT = args.factorio_port
    CLIENT_PORT = live_lib.CLIENT_PORT = args.client_port
    rcon.PORT = args.rcon_port
    GODOT = live_lib.GODOT = args.godot
    rcon.PASSWORD = args.rcon_password
    SECOND_CLIENT_PORT = live_lib.SECOND_CLIENT_PORT = args.second_client_port
    SERVER_LOG = live_lib.SERVER_LOG = args.server_log
    return args


def _finish(c=None):
    if c is not None:
        report(not c.invalid, "every message passes tools/protocol.py", str(c.invalid[:3]))
    report_step_errors()
    print(f"\n{live_lib.results.count(True)} passed, {live_lib.results.count(False)} failed")
    sys.exit(0 if all(live_lib.results) else 1)


def main():
    args = parse_args()
    print("RCON:", rcon.run("/f3d-status").replace("\n", " | "))
    # The first /c in a save only warns that it disables achievements; get that out of the way.
    rcon.run("/c rcon.print('ok')")
    c = Client(live_lib.FACTORIO_PORT, live_lib.CLIENT_PORT)

    if args.only == "steps":
        check_steps(c, None)
        _finish(c)

    if args.only in ("modgfx", "link"):
        welcome = handshake(c)
        if welcome:
            hello = (1.0, {"t": "hello", "v": 1, "sid": c.sid, "w": 1})
            c.pump(1.0, every=hello)
            if args.only == "modgfx":
                check_mod_graphics(c, hello, welcome[0])
            else:
                check_link(c, hello, welcome[0])
            _finish(c)
        _finish()

    only_checks = {
        "platforms": check_platforms,
        "planets": check_planets,
        "space": check_space,
        "ride": check_ride,
        "collectors": check_collectors,
        "sprint": check_sprint,
        "console": lambda cl, h: check_console(cl, h, cheat=True),
        "cliffs": check_cliffs,
        "save": check_save,
        "gear": check_gear,
        "build": check_build_tools,
        "alerts": check_alerts,
        "multi": check_multi,
        "remnants": check_remnants,
        "turrets": check_turrets,
        "weapons": check_weapons,
        "enemies": check_enemies,
        "remote": check_remote_view,
        "walk": check_walk,
        "pickup": check_pickup,
        "states": check_states,
        "repair": check_repair,
        "mapinfo": check_map_info,
        "triggers": check_triggers,
        "minevehicles": check_mine_vehicles,
        "alt": check_alt,
        "beltswitch": check_belt_switch,
        "asplayer": check_as_player,
        "barrier": check_barrier,
        "research": check_research,
        "join": check_join,
        "underclear": check_under_clear,
        "pipeend": check_pipe_end,
        "vehitems": check_vehicle_items,
        "pipevis": check_pipe_vis,
        "enemysight": check_enemy_sight,
        "enemysightfix": lambda cl, h: check_enemy_sight(cl, h, nest_only=True),
        "ui": check_ui_parity,
        "input": check_input,
        "planners": check_planners,
        "circuits": check_circuits,
        "info": check_info,
        "machines": check_machines,
        "logic": check_logic,
        "vehicles": check_vehicles,
        "hud": check_hud,
    }
    if args.only:
        if handshake(c):
            hello = (1.0, {"t": "hello", "v": 1, "sid": c.sid, "w": 1})
            c.pump(1.0, every=hello)
            only_checks[args.only](c, hello)
            _finish(c)
        _finish()

    hello = core_suite.run_handshake_and_world(c)
    core_suite.run_rcon_and_tail(c, hello)
    _finish()


if __name__ == "__main__":
    main()
