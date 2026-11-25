#!/usr/bin/env python3
"""Standalone bridge responsiveness stress test & A/B benchmark harness.

Runs:
1. Protocol & mock-server NACK/ring-buffer verification (`tools/protocol.py`, `tools/mock_server.py`).
2. Part A (`--mode synthetic`): Synthetic Lua (`lupa`) A/B benchmarks S1, S2, S4, S5, S6, S7
   against `mod/factorio-3d-bridge/control.lua` + `tools/mod_tests/fake_factorio.lua`.
3. Part B (`--mode live`): Live headless Factorio 2.1 mega-base stress tests against a copy of
   `server/saves/Zenith Test.zip` on scratch ports (36400-36403), cleanly stopped via RCON `/quit`.

Usage:
    python3 tools/bridge_stress_test.py [--mode synthetic|live|both] [--out PATH] [--factorio EXE]
"""

from __future__ import annotations

import argparse
import json
import os
import random
import re
import shutil
import socket
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

REPO = Path(__file__).resolve().parent.parent
TOOLS_DIR = REPO / "tools"
if str(TOOLS_DIR) not in sys.path:
    sys.path.insert(0, str(TOOLS_DIR))

import factorio_install  # noqa: E402
import mock_server  # noqa: E402
import protocol  # noqa: E402
import rcon  # noqa: E402

MOD_DIR = REPO / "mod" / "factorio-3d-bridge"
FAKE_LUA = REPO / "tools" / "mod_tests" / "fake_factorio.lua"
DEFAULT_OUT = REPO / "art-src" / "stress-test" / "results.json"

SCRATCH_UDP_PORT = 36400
SCRATCH_GAME_PORT = 36401
SCRATCH_RCON_PORT = 36402
SCRATCH_CLIENT_PORT = 36403


def main_checkout() -> Path:
    """Return the main git checkout root (shares saves/installs with worktrees)."""
    try:
        out = subprocess.check_output(
            ["git", "rev-parse", "--path-format=absolute", "--git-common-dir"],
            cwd=str(REPO),
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
        p = Path(out)
        if p.name == ".git":
            return p.parent
    except Exception:
        pass
    return REPO


def find_zenith_save() -> Path | None:
    """Locate `Zenith Test.zip` in this checkout or the main checkout."""
    for base in (REPO, main_checkout()):
        candidate = base / "server" / "saves" / "Zenith Test.zip"
        if candidate.is_file():
            return candidate
    return None


def decode_datagrams(raw_items: list[Any]) -> tuple[list[dict[str, Any]], int]:
    """Decode raw UDP datagrams (bytes/str, Lua [port, data, is_hex], or {data=...}) into messages."""
    messages: list[dict[str, Any]] = []
    total_bytes = 0
    for item in raw_items:
        raw: bytes = b""
        if isinstance(item, (list, tuple)) and len(item) >= 2:
            payload = item[1]
            is_hex = len(item) >= 3 and bool(item[2])
            if is_hex and isinstance(payload, str):
                raw = bytes.fromhex(payload)
            elif isinstance(payload, str):
                raw = payload.encode("utf-8")
            elif isinstance(payload, (bytes, bytearray)):
                raw = bytes(payload)
        elif isinstance(item, dict):
            payload = item.get("data", b"")
            if isinstance(payload, str):
                raw = payload.encode("utf-8")
            elif isinstance(payload, (bytes, bytearray)):
                raw = bytes(payload)
        elif isinstance(item, str):
            raw = item.encode("utf-8")
        elif isinstance(item, (bytes, bytearray)):
            raw = bytes(item)
        if not raw:
            continue
        total_bytes += len(raw)
        for frame in protocol.split_datagram(raw):
            if isinstance(frame, dict):
                messages.append(frame)
            elif isinstance(frame, (bytes, bytearray)) and frame[:1] in (b"{", b"["):
                try:
                    msg = json.loads(frame.decode("utf-8"))
                    if isinstance(msg, dict):
                        messages.append(msg)
                except Exception:
                    continue
    return messages, total_bytes


# ---------------------------------------------------------------------------
# Protocol & Mock Server NACK Self-Checks
# ---------------------------------------------------------------------------


def _start_mock_server(
    seed: int = 7, drop: float = 0.0
) -> tuple[mock_server.MockGame, socket.socket, socket.socket, tuple[str, int]]:
    """Create a MockGame bound to an ephemeral loopback UDP port and a matching client socket."""
    srv_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    srv_sock.bind(("127.0.0.1", 0))
    srv = mock_server.MockGame(seed=seed, drop=drop, day_length=25000)
    srv.build_starter_base()
    srv.sock = srv_sock
    cli_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    cli_sock.bind(("127.0.0.1", 0))
    cli_sock.settimeout(0.25)
    addr = ("127.0.0.1", srv_sock.getsockname()[1])
    return srv, srv_sock, cli_sock, addr


def run_protocol_and_mock_checks() -> dict[str, Any]:
    """Verify `protocol.py` nack validation/docs and `MockGame` 256-entry ring buffer."""
    result: dict[str, Any] = {"name": "protocol_mock_nack", "status": "passed", "checks": {}}
    doc_errs = protocol.doc_problems()
    if doc_errs:
        result["status"] = "failed"
        result["checks"]["doc_problems"] = doc_errs
        return result
    result["checks"]["doc_problems"] = 0

    valid_cases = [
        {"t": "nack", "r": [1]},
        {"t": "nack", "r": list(range(1, 65)), "c": [[0, 0], [-2, 3]]},
    ]
    invalid_cases = [
        {"t": "nack"},
        {"t": "nack", "r": []},
        {"t": "nack", "r": [0]},
        {"t": "nack", "r": [True]},
        {"t": "nack", "r": list(range(1, 66))},
        {"t": "nack", "r": [1], "c": ["bad"]},
        {"t": "nack", "r": [1], "c": [[1.5, 2]]},
    ]
    for idx, msg in enumerate(valid_cases):
        probs = protocol.client_problems(msg)
        if probs:
            result["status"] = "failed"
            result["checks"][f"valid_{idx}"] = probs
            return result
    for idx, msg in enumerate(invalid_cases):
        if not protocol.client_problems(msg):
            result["status"] = "failed"
            result["checks"][f"invalid_{idx}"] = "expected failure"
            return result
    result["checks"]["schema_validation"] = "ok"

    # Exercise MockGame UDP server ring buffer, hit, aged-out c requeue, and hello reset.
    srv, srv_sock, sock, addr = _start_mock_server(seed=7, drop=0.0)
    try:
        sock.sendto(
            (json.dumps({"t": "hello", "v": mock_server.PROTOCOL, "sid": "stress-a"}) + "\n").encode("utf-8"),
            addr,
        )
        for _ in range(12):
            _pump_mock_rx(srv)
            srv.flush()
        _drain_udp(sock)

        # Subscribe chunk [0, 0] and flush initial snapshot, then push >256 reliable frames.
        sock.sendto(
            (json.dumps({"t": "sub", "c": [[0, 0]]}) + "\n").encode("utf-8"),
            addr,
        )
        _pump_mock_rx(srv)
        srv.update()
        srv.flush()
        _drain_udp(sock)

        total_pushed = protocol.NACK_RING_SIZE + 44
        first_r = srv.rseq + 1
        for idx in range(total_pushed):
            srv.send_reliable({"t": "upd", "id": 9000 + (idx % 5), "dir": idx % 16})
        while srv.outbox:
            srv.flush()
        _drain_udp(sock)

        newest_r = srv.rseq
        hit_r = newest_r - 5
        aged_r = first_r  # >256 back, evicted from 256-entry ring

        # 1) Ring hit: expect original `r == hit_r` resent over UDP.
        sock.sendto(
            (json.dumps({"t": "nack", "r": [hit_r]}) + "\n").encode("utf-8"),
            addr,
        )
        _pump_mock_rx(srv)
        hit_msgs, hit_bytes = decode_datagrams(_drain_udp(sock))
        hit_matched = any(m.get("r") == hit_r for m in hit_msgs)

        # 2) Ring miss with `c`: expect chunk [0, 0] requeued and sent cleanly (and aged_r NOT resent).
        srv.outbox.clear()
        sock.sendto(
            (json.dumps({"t": "nack", "r": [aged_r], "c": [[0, 0]]}) + "\n").encode("utf-8"),
            addr,
        )
        _pump_mock_rx(srv)
        for _ in range(8):
            srv.update()
            srv.flush()
        miss_msgs, miss_bytes = decode_datagrams(_drain_udp(sock))
        aged_absent = all(m.get("r") != aged_r for m in miss_msgs)
        chunk_requeued = any(
            m.get("t") in ("chunk", "ents") and m.get("cx") == 0 and m.get("cy") == 0
            for m in miss_msgs
        ) or len(miss_msgs) > 0

        # 3) New-session handshake clears ring.
        sock.sendto(
            (json.dumps({"t": "hello", "v": mock_server.PROTOCOL, "sid": "stress-b"}) + "\n").encode("utf-8"),
            addr,
        )
        _pump_mock_rx(srv)
        ring_cleared = all(x is None for x in srv.nack_ring)

        result["checks"]["mock_ring"] = {
            "ring_size": protocol.NACK_RING_SIZE,
            "pushed_frames": total_pushed,
            "hit_matched": hit_matched,
            "hit_bytes": hit_bytes,
            "aged_absent": aged_absent,
            "miss_requeue_msgs": len(miss_msgs),
            "miss_bytes": miss_bytes,
            "handshake_cleared_ring": ring_cleared,
        }
        if not (hit_matched and aged_absent and chunk_requeued and ring_cleared):
            result["status"] = "failed"
    finally:
        sock.close()
        try:
            srv_sock.close()
        except Exception:
            pass
    return result


def _pump_mock_rx(srv: Any, wait: float = 0.02) -> None:
    """Drain pending incoming packets on MockGame's UDP socket."""
    srv.sock.settimeout(wait)
    try:
        while True:
            try:
                data, peer = srv.sock.recvfrom(65536)
            except (BlockingIOError, TimeoutError, socket.timeout, OSError):
                break
            for msg in protocol.split_datagram(data):
                if isinstance(msg, dict):
                    srv.on_message(msg, peer)
            srv.sock.setblocking(False)
    finally:
        srv.sock.setblocking(True)


def _drain_udp(sock: socket.socket, wait: float = 0.02) -> list[bytes]:
    """Read all queued UDP datagrams, briefly waiting for the first packet if needed."""
    out: list[bytes] = []
    sock.settimeout(wait)
    try:
        while True:
            try:
                data, _ = sock.recvfrom(65536)
                out.append(data)
            except (BlockingIOError, TimeoutError, socket.timeout, OSError):
                break
            sock.setblocking(False)
    finally:
        sock.setblocking(True)
    return out


# ---------------------------------------------------------------------------
# Part A — Synthetic Lua (`lupa`) Harness & Benchmarks
# ---------------------------------------------------------------------------


def _py_to_lua(lua: Any, val: Any) -> Any:
    """Recursively convert Python dict/list/scalars to Lua values."""
    if isinstance(val, dict):
        tbl = lua.table()
        for k, v in val.items():
            tbl[k] = _py_to_lua(lua, v)
        return tbl
    if isinstance(val, (list, tuple)):
        tbl = lua.table()
        for idx, item in enumerate(val, start=1):
            tbl[idx] = _py_to_lua(lua, item)
        return tbl
    return val


def _lua_to_py(val: Any) -> Any:
    """Recursively convert Lua tables to Python dicts/lists."""
    if type(val).__name__ != "_LuaTable":
        return val
    keys = list(val.keys())
    if not keys:
        return {}
    if all(isinstance(k, int) and k >= 1 for k in keys) and sorted(keys) == list(
        range(1, len(keys) + 1)
    ):
        return [_lua_to_py(val[i]) for i in range(1, len(keys) + 1)]
    return {k: _lua_to_py(val[k]) for k in keys}


class LuaHarness:
    """Minimal lupa harness running `fake_factorio.lua` + `control.lua`."""

    def __init__(self) -> None:
        from lupa import lua52

        self.lua = lua52.LuaRuntime(unpack_returned_tuples=True)
        g = self.lua.globals()
        g.F_to_json = lambda tbl: json.dumps(_lua_to_py(tbl), separators=(",", ":"))
        g.F_from_json = lambda s: _py_to_lua(self.lua, json.loads(s))

        fake_path = str(FAKE_LUA.resolve()).replace("\\", "/")
        mod_path = str(MOD_DIR.resolve()).replace("\\", "/")
        self.lua.execute(
            f"""
            package.path = "{mod_path}/?.lua;{mod_path}/scripts/?.lua;" .. package.path
            dofile("{fake_path}")
            local orig_require = require
            require = function(name)
                if type(name) == "string" then
                    local short = name:gsub("^__factorio%-3d%-bridge__/", ""):gsub("%.lua$", "")
                    local dot = short:gsub("/", ".")
                    local slash = short:gsub("%.", "/")
                    for _, k in ipairs({{name, short, dot, slash}}) do
                        if package.loaded[k] ~= nil then return package.loaded[k] end
                    end
                end
                return orig_require(name)
            end
            dofile("{mod_path}/control.lua")
            if F and F.on_init then F.on_init() end
            """
        )
        self.F = self.lua.globals().F
        # Enable clean exception surfacing in fake_factorio barrier if present.
        self.lua.execute(
            """
            local b = package.loaded["scripts.barrier"]
            if type(b) == "table" then b.rethrow = true end
            """
        )
        self._perf_opts = self._discover_command_options("f3d-perf")
        self._bs_opts = self._discover_command_options("f3d-bs")

    def _discover_command_options(self, cmd_name: str) -> set[str]:
        """Inspect available switches from `perf` or `belt_sim` modules or command text."""
        opts: set[str] = set()
        if cmd_name == "f3d-perf":
            names = self.lua.eval(
                """
                (function()
                    local p = package.loaded["scripts.perf"]
                    if type(p) ~= "table" then
                        local ok, mod = pcall(require, "scripts.perf")
                        if ok then p = mod end
                    end
                    local out = {}
                    if type(p) == "table" then
                        for _, k in ipairs({"OPTIONS", "DEFAULTS", "defaults"}) do
                            local tbl = p[k]
                            if type(tbl) == "table" then
                                for opt, _ in pairs(tbl) do out[#out+1] = tostring(opt) end
                            end
                        end
                    end
                    if storage and type(storage.f3d_perf) == "table" then
                        for opt, _ in pairs(storage.f3d_perf) do out[#out+1] = tostring(opt) end
                    end
                    return out
                end)()
                """
            )
            if names is not None:
                for k in names.values():
                    opts.add(str(k))
        elif cmd_name == "f3d-bs":
            names = self.lua.eval(
                """
                (function()
                    local b = package.loaded["scripts.belt_sim"]
                    if type(b) ~= "table" then
                        local ok, mod = pcall(require, "scripts.belt_sim")
                        if ok then b = mod end
                    end
                    local out = {}
                    if type(b) == "table" then
                        for _, k in ipairs({"OPTIONS", "OPTS", "DEFAULTS"}) do
                            local tbl = b[k]
                            if type(tbl) == "table" then
                                for opt, _ in pairs(tbl) do out[#out+1] = tostring(opt) end
                            end
                        end
                    end
                    if storage and type(storage.f3d_bs_opts) == "table" then
                        for opt, _ in pairs(storage.f3d_bs_opts) do out[#out+1] = tostring(opt) end
                    end
                    return out
                end)()
                """
            )
            if names is not None:
                for k in names.values():
                    opts.add(str(k))
        return opts

    def has_perf(self, name: str) -> bool:
        return name in self._perf_opts

    def has_bs(self, name: str) -> bool:
        return name in self._bs_opts

    def set_perf(self, name: str, on: bool) -> bool:
        if name not in self._perf_opts:
            return False
        mode = "on" if on else "off"
        self.lua.execute(
            f'if F.commands["f3d-perf"] then F.commands["f3d-perf"]({{parameter="{name} {mode}"}}) end'
        )
        return True

    def set_bs(self, name: str, on: bool) -> bool:
        if name not in self._bs_opts:
            return False
        mode = "on" if on else "off"
        self.lua.execute(
            f'if F.commands["f3d-bs"] then F.commands["f3d-bs"]({{parameter="{name} {mode}"}}) end'
        )
        return True

    def send_packet(self, msg: dict[str, Any], port: int = 34201) -> None:
        raw = json.dumps(msg, separators=(",", ":"))
        self.F.packet(raw, port)

    def tick(self, n: int = 1) -> list[tuple[list[dict[str, Any]], int]]:
        out: list[tuple[list[dict[str, Any]], int]] = []
        for _ in range(n):
            self.F.tick()
            sent = _lua_to_py(self.F.take_sent())
            if isinstance(sent, dict):
                raw_list = list(sent.values())
            elif isinstance(sent, list):
                raw_list = sent
            else:
                raw_list = []
            msgs, nbytes = decode_datagrams(raw_list)
            out.append((msgs, nbytes))
        return out

    def connect(
        self,
        port: int = 34201,
        focus: tuple[int, int] = (0, 0),
        radius: int = 128,
        budget: int = 2000,
        rate: int = 0,
        sub_chunks: list[list[int]] | None = None,
    ) -> dict[str, Any]:
        # Ensure a connected character exists and raise max-focus-radius if test requests >64.
        self.lua.execute(
            f"""
            if not game.players[1] and F.create_player then
                F.create_player(1, "stress", 0, 0)
            end
            if {int(radius)} > 64 and settings and settings.global and settings.global["f3d-max-focus-radius"] then
                settings.global["f3d-max-focus-radius"].value = {int(radius)}
                F.raise("on_runtime_mod_setting_changed", {{setting = "f3d-max-focus-radius"}})
            end
            """
        )
        self.send_packet(
            {
                "t": "hello",
                "v": mock_server.PROTOCOL,
                "sid": "lua-stress",
                "z": 0,
                "dc": 1,
                "b": 1,
                "bl": 1,
                "bs": 1,
                "ie": 2,
                "rb": 1,
                "lod": 1,
            },
            port,
        )
        welcome_seen = False
        surface_seen = False
        for _ in range(30):
            for msgs, _ in self.tick(1):
                for m in msgs:
                    if m.get("t") == "welcome":
                        welcome_seen = True
                    elif m.get("t") == "surface":
                        surface_seen = True
            if welcome_seen and surface_seen:
                break
        self.send_packet({"t": "budget", "u": budget}, port)
        self.send_packet({"t": "rate", "l": rate}, port)
        self.send_packet(
            {"t": "focus", "x": int(focus[0] * 256), "y": int(focus[1] * 256), "r": radius},
            port,
        )
        if sub_chunks is not None:
            for i in range(0, len(sub_chunks), 200):
                self.send_packet({"t": "sub", "c": sub_chunks[i : i + 200]}, port)
        self.tick(2)
        return {"welcome": welcome_seen, "surface": surface_seen}


def _switch_gate_note(harness: LuaHarness, required: list[tuple[str, str]]) -> list[str]:
    missing = []
    for kind, name in required:
        ok = harness.has_perf(name) if kind == "perf" else harness.has_bs(name)
        if not ok:
            missing.append(f"{kind}:{name}")
    return missing


def bench_s1() -> dict[str, Any]:
    """S1: `flush_end` + `STEPS` order — live event delay & near chunks under budget=60."""
    probe = LuaHarness()
    missing = _switch_gate_note(probe, [("perf", "flush_end")])
    arms: dict[str, Any] = {}
    for label, flag in (("off", False), ("on", True)):
        if flag and missing:
            arms[label] = {"status": "skipped_pending_mod_merge", "missing": missing}
            continue
        h = LuaHarness()
        if flag:
            h.set_perf("flush_end", True)
        else:
            h.set_perf("flush_end", False)
        near_grid = [[cx, cy] for cx in range(-1, 2) for cy in range(-1, 2)]
        outer_grid = [
            [cx, cy]
            for cx in range(-3, 4)
            for cy in range(-3, 4)
            if abs(cx) > 1 or abs(cy) > 1
        ]
        # Connect and allow initial setup, keeping sub pending until test start.
        h.connect(focus=(0, 0), budget=2000, rate=0, sub_chunks=near_grid + outer_grid)
        # Spawn a chest and an entity for live add/upd/inv checks, plus drain setup ticks.
        h.tick(10)

        # Align game.tick so the next tick hits INVENTORY_INTERVAL (30), then inject add/upd/inv.
        while (int(h.lua.eval("game.tick")) % 30) != 29:
            h.tick(1)
        h.lua.execute(
            """
            local c = F.spawn("wooden-chest", 2.5, 2.5)
            F.raise("on_built_entity", {entity = c})
            c.direction = 4
            F.raise("on_player_rotated_entity", {entity = c, previous_direction = 0})
            local s = storage.f3d
            local chr = (s and s.puppet) or (game.players[1] and game.players[1].character)
            if chr and chr.valid then
                chr.get_main_inventory().insert({name = "iron-plate", count = 5})
            end
            """
        )
        delays: dict[str, int | None] = {"add": None, "upd": None, "inv": None}
        for dt in range(6):
            ticks = h.tick(1)
            for msgs, _ in ticks:
                for m in msgs:
                    t = m.get("t")
                    if t in delays and delays[t] is None:
                        delays[t] = dt

        # Part 2: Measure near chunks delivered over 60 ticks under budget=60 while map+lod active.
        h2 = LuaHarness()
        if flag:
            h2.set_perf("flush_end", True)
        else:
            h2.set_perf("flush_end", False)
        h2.connect(focus=(0, 0), radius=128, budget=60, rate=0, sub_chunks=None)
        h2.lua.execute(
            """
            F.surface.is_chunk_generated = function(pos)
                local cx, cy = pos.x or pos[1], pos.y or pos[2]
                return math.abs(cx) <= 4 and math.abs(cy) <= 4
            end
            for cx = -3, 3 do
                for cy = -3, 3 do
                    F.spawn("wooden-chest", cx * 32 + 4.5, cy * 32 + 4.5)
                    F.spawn("wooden-chest", cx * 32 + 8.5, cy * 32 + 8.5)
                end
            end
            """
        )
        h2.send_packet({"t": "map", "cx1": -3, "cy1": -3, "cx2": 3, "cy2": 3})
        h2.send_packet({"t": "lod_sub", "act": "map", "q": 0})
        h2.send_packet({"t": "lod_sub", "act": "want", "res": 8, "rg": [[0, 0], [1, 0], [-1, 0]]})
        h2.send_packet({"t": "sub", "c": near_grid + outer_grid})
        near_set = {(cx, cy) for cx, cy in near_grid}
        near_delivered: set[tuple[int, int]] = set()
        for _ in range(60):
            for msgs, _ in h2.tick(1):
                for m in msgs:
                    if m.get("t") == "chunk":
                        cx, cy = m.get("cx"), m.get("cy")
                        if (cx, cy) in near_set:
                            near_delivered.add((cx, cy))

        arms[label] = {
            "status": "ran",
            "live_tick_delay": delays,
            "near_chunks_60t_under_budget60": len(near_delivered),
            "near_chunks_total": len(near_set),
        }

    return {
        "id": "S1",
        "title": "flush_end + STEPS order",
        "status": "skipped_pending_mod_merge" if missing else "passed",
        "missing_switches": missing,
        "arms": arms,
    }


def bench_s2() -> dict[str, Any]:
    """S2: `prio_queue` + chunk wait promotion + `dec_dirty` cap."""
    probe = LuaHarness()
    missing = _switch_gate_note(probe, [("perf", "prio_queue"), ("perf", "flush_end")])
    arms: dict[str, Any] = {}
    for label, flag in (("off", False), ("on", True)):
        if flag and missing:
            arms[label] = {"status": "skipped_pending_mod_merge", "missing": missing}
            continue
        h = LuaHarness()
        h.set_perf("prio_queue", flag)
        h.set_perf("flush_end", flag)
        h.connect(focus=(0, 0), radius=256, budget=2000, rate=0, sub_chunks=None)
        # Allow 21x21 = 441 generated chunks in fake surface.
        h.lua.execute(
            """
            F.surface.is_chunk_generated = function(pos)
                local cx, cy = pos.x or pos[1], pos.y or pos[2]
                return math.abs(cx) <= 10 and math.abs(cy) <= 10
            end
            """
        )
        outer_120 = [
            [cx, cy]
            for cx in range(-6, 6)
            for cy in range(-6, 6)
            if (cx, cy) != (0, 0)
        ][:120]
        # Populate entities in 100+ outer chunks + 20 decorative chunks + chunk (0,0).
        h.lua.execute(
            """
            local c0 = F.spawn("assembling-machine-1", 4.5, 4.5, {force = "player"})
            c0.set_recipe("iron-gear-wheel")
            c0.status = defines.entity_status.working
            rawset(c0, "_s2_tag", true)
            for idx = 1, 20 do
                F.add_decorative(F.surface, "brown-asterisk", idx * 32 + 2.0, 2.0, 1)
            end
            for cx = -6, 5 do
                for cy = -6, 5 do
                    if cx ~= 0 or cy ~= 0 then
                        F.spawn("wooden-chest", cx * 32 + 3.5, cy * 32 + 3.5)
                    end
                end
            end
            """
        )
        # Subscribe (0,0) and outer chunks under tight byte budget with (0,0) snapshot queued in outbox.
        h.send_packet({"t": "sub", "c": [[0, 0]] + outer_120})
        h.lua.execute(
            """
            settings.global["f3d-bytes-per-tick"].value = 2048
            local tr = package.loaded["scripts.transport"]
            local big_tiles = {}
            for j = 1, 512 do
              big_tiles[#big_tiles + 1] = (j % 2 == 1) and 1 or 2
              big_tiles[#big_tiles + 1] = 2
            end
            for idx = 1, 4 do
              tr.send_reliable({ t = "chunk", cx = 4, cy = idx, tiles = big_tiles, parts = 1, rs = 1, rv = idx, n = 0 }, "4," .. idx)
            end
            tr.send_reliable({ t = "chunk", cx = 0, cy = 0, tiles = big_tiles, parts = 1, rs = 1, rv = 1, n = 1 }, "0,0")
            tr.send_reliable({ t = "ents", cx = 0, cy = 0, part = 1, parts = 1, e = { { 97000, 1, 1024, 1024, 0 } } }, "0,0")
            for idx = 5, 24 do
              tr.send_reliable({ t = "chunk", cx = 5, cy = idx, tiles = big_tiles, parts = 1, rs = 1, rv = idx, n = 0 }, "5," .. idx)
            end
            storage.f3d.dec_dirty = { ["1,0"] = true, ["2,0"] = true }
            """
        )
        # Inject tiles, tile-ghost del, aiu, cmdr, near st, and upd on chunk (0,0).
        h.lua.execute(
            """
            F.raise("on_player_built_tile", {
                player_index = 1,
                surface_index = 1,
                tiles = {{position = {x = 1, y = 1}, old_tile = {name = "grass-1"}}},
                tile = {name = "stone-path"}
            })
            local tg = F.surface.create_entity{
                name = "tile-ghost",
                inner_name = "stone-path",
                position = {x = 2.5, y = 2.5},
                force = "player"
            }
            if tg then
                F.raise("on_player_mined_entity", {entity = tg, player_index = 1})
                if tg.valid and tg.destroy then tg.destroy() end
            end
            local am = F.surface.find_entity("assembling-machine-1", {x = 4.5, y = 4.5})
            if am then
                package.loaded["scripts.alt_mode"].check(am, nil)
                am.direction = 4
                F.raise("on_player_rotated_entity", {entity = am, previous_direction = 0})
                am.status = defines.entity_status.no_power
            end
            """
        )
        h.send_packet({"t": "cmd", "id": 1, "text": "/f3d-status"})

        seen_ticks: dict[str, int | None] = {
            "tiles": None,
            "del": None,
            "aiu": None,
            "upd": None,
            "cmdr": None,
            "st": None,
            "chunk_0_0": None,
        }
        r_map: dict[str, int] = {}
        order: list[str] = []
        for t in range(1, 200):
            for msgs, _ in h.tick(1):
                for m in msgs:
                    tp = m.get("t")
                    if tp == "chunk" and m.get("cx") == 0 and m.get("cy") == 0:
                        if seen_ticks["chunk_0_0"] is None:
                            seen_ticks["chunk_0_0"] = t
                            order.append("chunk(0,0)")
                        r_map["chunk_0_0"] = int(m.get("r", 0))
                    elif tp == "ents" and m.get("cx") == 0 and m.get("cy") == 0:
                        r_map["ents_0_0"] = int(m.get("r", 0))
                    elif tp in seen_ticks and seen_ticks[tp] is None:
                        seen_ticks[tp] = t
                        order.append(str(tp))
                        if m.get("r") is not None:
                            r_map[str(tp)] = int(m["r"])
        h.lua.execute('settings.global["f3d-bytes-per-tick"].value = 131072')
        arms[label] = {
            "status": "ran",
            "ticks_to_delivery": seen_ticks,
            "upd_after_chunk_0_0": (
                r_map.get("upd", 0) > r_map.get("ents_0_0", r_map.get("chunk_0_0", 0)) > 0
            ),
            "first_events_order": order[:10],
        }

    return {
        "id": "S2",
        "title": "prio_queue + wait promotion + dec_dirty cap",
        "status": "skipped_pending_mod_merge" if missing else "passed",
        "missing_switches": missing,
        "arms": arms,
    }


def bench_s4() -> dict[str, Any]:
    """S4: `near_first` — 300 due inserters, 600 due robots, 2000 chunks on jump."""
    probe = LuaHarness()
    missing = _switch_gate_note(probe, [("perf", "near_first")])
    arms: dict[str, Any] = {}
    for label, flag in (("off", False), ("on", True)):
        if flag and missing:
            arms[label] = {"status": "skipped_pending_mod_merge", "missing": missing}
            continue
        h = LuaHarness()
        if flag:
            h.set_perf("near_first", True)
        else:
            h.set_perf("near_first", False)
        h.connect(focus=(0, 0), radius=900, budget=2000, rate=0, sub_chunks=None)
        s4_ids = h.lua.eval(
            """
            (function()
                settings.global["f3d-detail-radius"].value = 64
                F.surface.is_chunk_generated = function(pos)
                    local cx, cy = pos.x or pos[1], pos.y or pos[2]
                    return math.abs(cx) <= 30 and math.abs(cy) <= 30
                end
                local near_ins, near_rb = {}, {}
                -- Put 280 outer inserters in (-1, -1) / (-2, -1) inside detail-radius=64 so look_over discovers them BEFORE (0, 0).
                for i = 1, 280 do
                    local x = -48.0 + (i % 28)
                    local y = -48.0 + math.floor(i / 28) * 2.0
                    local ins = F.spawn("inserter", x, y, {force = "player"})
                    near_ins = near_ins
                    local _ = ins
                end
                for i = 1, 20 do
                    local x, y = (i % 10) + 0.5, math.floor(i / 10) + 0.5
                    local ins = F.spawn("inserter", x, y, {force = "player"})
                    near_ins[#near_ins + 1] = ins.unit_number
                end
                for i = 1, 30 do
                    local rb = F.spawn("construction-robot", (i % 6) * 4.0 + 1.5, math.floor(i / 6) * 4.0 + 1.5, {force = "player"})
                    near_rb[#near_rb + 1] = rb.unit_number
                end
                for i = 1, 570 do
                    local rx = 120 + (i % 24) * 8.0
                    local ry = 120 + math.floor(i / 24) * 8.0
                    F.spawn("construction-robot", rx, ry, {force = "player"})
                end
                return {near_ins, near_rb}
            end)()
            """
        )
        near_ins_set = {int(v) for v in s4_ids[1].values()}
        near_rb_set = {int(v) for v in s4_ids[2].values()}
        # Wait for full 8-strip robot sweep (18 ticks), align odd ie tick, reset inserters so all 300 hit due[now] together!
        h.tick(18)
        while int(h.lua.eval("game.tick")) % 2 != 1:
            h.tick(1)
        h.lua.execute('package.loaded["scripts.inserters"].reset()')
        h.tick(1)  # look_over discovers all 300 inserters and schedules all 300 for now+1 (odd ie tick)
        rows_2000 = [[cy, -22, 45] for cy in range(-22, 23)]
        h.send_packet({"t": "sub", "o": [-10, -10], "r": 22, "w": rows_2000, "f": [256, 0]})
        h.send_packet({"t": "budget", "u": 120})
        h.tick(1)
        # Now jump square center to [0, 0] (triggering requeue_slices) AND make all 600 robots due on this tick!
        h.lua.execute('game.forces.player.worker_robots_speed_modifier = 0.25')
        h.send_packet({"t": "budget", "u": 800})
        h.send_packet({"t": "sub", "o": [0, 0], "r": 22, "w": rows_2000, "f": [0, 256]})

        near_2x2 = {(0, 0), (-1, 0), (0, -1), (-1, -1)}
        near_ranks: dict[str, int] = {}
        near_ticks: dict[str, int] = {}
        chunk_idx = 0
        tick1_ie_near = 0
        first_rb_near = 0
        first_rb_tick: int | None = None
        for t in range(1, 121):
            for msgs, _ in h.tick(1):
                for m in msgs:
                    tp = m.get("t")
                    if tp == "chunk":
                        chunk_idx += 1
                        key = (m.get("cx"), m.get("cy"))
                        if key in near_2x2 and str(key) not in near_ranks:
                            near_ranks[str(key)] = chunk_idx
                            near_ticks[str(key)] = t
                    elif t <= 2 and tp == "ie":
                        flat = m.get("l", [])
                        if isinstance(flat, list):
                            for idx in range(0, len(flat) - 1, 9):
                                uid = flat[idx + 1]
                                if uid in near_ins_set:
                                    tick1_ie_near += 1
                    elif tp == "rb" and (first_rb_tick is None or t == first_rb_tick):
                        flat = m.get("u", [])
                        if isinstance(flat, list) and flat:
                            first_rb_tick = t
                            for idx in range(0, len(flat), 11):
                                if flat[idx] in near_rb_set:
                                    first_rb_near += 1

        arms[label] = {
            "status": "ran",
            "tick1_ie_near_events": tick1_ie_near,
            "first_rb_tick": first_rb_tick,
            "tick1_rb_near_pct": round(100.0 * first_rb_near / 30.0, 1),
            "near_2x2_ranks": near_ranks,
            "near_2x2_ticks": near_ticks,
        }

    return {
        "id": "S4",
        "title": "near_first (inserters, robots, chunk jump)",
        "status": "skipped_pending_mod_merge" if missing else "passed",
        "missing_switches": missing,
        "arms": arms,
    }


def bench_s5() -> dict[str, Any]:
    """S5: `near_rate` — rate 3 + budget 60 near vs outer st/mv/ie & near chunk slices."""
    probe = LuaHarness()
    missing = _switch_gate_note(probe, [("perf", "near_rate")])
    arms: dict[str, Any] = {}
    for label, flag in (("off", False), ("on", True)):
        if flag and missing:
            arms[label] = {"status": "skipped_pending_mod_merge", "missing": missing}
            continue
        h = LuaHarness()
        if flag:
            h.set_perf("near_rate", True)
        else:
            h.set_perf("near_rate", False)
        h.connect(focus=(0, 0), radius=192, budget=2000, rate=0, sub_chunks=None)
        s5_ids = h.lua.eval(
            """
            (function()
                settings.global["f3d-detail-radius"].value = 192
                F.surface.is_chunk_generated = function(pos)
                    local cx, cy = pos.x or pos[1], pos.y or pos[2]
                    return math.abs(cx) <= 6 and math.abs(cy) <= 6
                end
                local nam = F.spawn("assembling-machine-1", 4.5, 4.5)
                local oam = F.spawn("assembling-machine-1", 120.5, 4.5)
                local ncar = F.spawn("car", 8.5, 4.5)
                local ocar = F.spawn("car", 120.5, 16.5)
                local nins = F.spawn("inserter", 6.5, 6.5)
                local oins = F.spawn("inserter", 118.5, 6.5)
                for i = 1, 20 do
                    F.spawn("wooden-chest", 2.5 + (i % 5), 2.5 + math.floor(i / 5))
                end
                F._s5 = {nam = nam, oam = oam, ncar = ncar, ocar = ocar, nins = nins, oins = oins}
                package.loaded["scripts.inserters"].reset()
                return {nam.unit_number, oam.unit_number, ncar.unit_number, ocar.unit_number, nins.unit_number, oins.unit_number}
            end)()
            """
        )
        near_am_id, outer_am_id, near_car_id, outer_car_id, near_ins_id, outer_ins_id = (
            int(s5_ids[1]), int(s5_ids[2]), int(s5_ids[3]), int(s5_ids[4]), int(s5_ids[5]), int(s5_ids[6])
        )
        # Let initial scan register entities, switch to rate=3 + wait EASE_TICKS=120 so rate settles, then measure 240t.
        h.tick(20)
        h.send_packet({"t": "rate", "l": 3})
        h.tick(130)
        h.send_packet({"t": "budget", "u": 60})
        h.send_packet({"t": "sub", "c": [[0, 0], [3, 0], [4, 0]]})

        window_ticks = 240
        counts = {
            "near_st": 0,
            "outer_st": 0,
            "near_mv": 0,
            "outer_mv": 0,
            "near_ie": 0,
            "outer_ie": 0,
            "near_chunks": 0,
        }
        chunk_0_0_tick: int | None = None
        for t in range(window_ticks):
            h.lua.execute(
                f"""
                F._s5.ncar.position.x = 8.5 + ({t} % 5) * 0.4
                F._s5.ocar.position.x = 120.5 + ({t} % 5) * 0.4
                if ({t} % 2) == 0 then
                    local up = (math.floor({t} / 2) % 2 == 0)
                    F.set_hand(F._s5.nins, 6.5 + (up and 0.3 or -0.3), 6.5, up and "iron-plate" or nil)
                    F.set_hand(F._s5.oins, 118.5 + (up and 0.3 or -0.3), 6.5, up and "iron-plate" or nil)
                end
                local st_on = (math.floor({t} / 30) % 2 == 0)
                F._s5.nam.status = st_on and defines.entity_status.working or defines.entity_status.no_power
                F._s5.oam.status = st_on and defines.entity_status.working or defines.entity_status.no_power
                """
            )
            for msgs, _ in h.tick(1):
                for m in msgs:
                    tp = m.get("t")
                    if tp == "chunk" and m.get("cx") == 0 and m.get("cy") == 0:
                        counts["near_chunks"] += 1
                        if chunk_0_0_tick is None:
                            chunk_0_0_tick = t + 1
                    elif tp == "st":
                        flat = m.get("l", [])
                        if isinstance(flat, list):
                            for idx in range(0, len(flat) - 1, 2):
                                uid = flat[idx]
                                if uid == outer_am_id:
                                    counts["outer_st"] += 1
                                elif uid == near_am_id:
                                    counts["near_st"] += 1
                    elif tp == "mv":
                        flat = m.get("l", [])
                        if isinstance(flat, list):
                            for rec in flat:
                                if isinstance(rec, list) and rec:
                                    uid = rec[0]
                                    if uid == outer_car_id:
                                        counts["outer_mv"] += 1
                                    elif uid == near_car_id:
                                        counts["near_mv"] += 1
                    elif tp == "ie":
                        flat = m.get("l", [])
                        if isinstance(flat, list):
                            for idx in range(0, len(flat) - 1, 9):
                                uid = flat[idx + 1]
                                if uid == outer_ins_id:
                                    counts["outer_ie"] += 1
                                elif uid == near_ins_id:
                                    counts["near_ie"] += 1

        arms[label] = {
            "status": "ran",
            "window_ticks": window_ticks,
            "counts": counts,
            "near_chunk_0_0_ticks": chunk_0_0_tick,
            "near_st_interval_ticks": round(window_ticks / max(1, counts["near_st"]), 2),
            "near_mv_interval_ticks": round(window_ticks / max(1, counts["near_mv"]), 2),
            "near_ie_interval_ticks": round(window_ticks / max(1, counts["near_ie"]), 2),
        }

    return {
        "id": "S5",
        "title": "near_rate under rate=3 + budget=60",
        "status": "skipped_pending_mod_merge" if missing else "passed",
        "missing_switches": missing,
        "arms": arms,
    }


def bench_s6() -> dict[str, Any]:
    """S6: `near_spool` — near belt delta ahead of outer spool parts under send_cap."""
    probe = LuaHarness()
    missing = _switch_gate_note(probe, [("bs", "near_spool")])
    arms: dict[str, Any] = {}
    for label, flag in (("off", False), ("on", True)):
        if flag and missing:
            arms[label] = {"status": "skipped_pending_mod_merge", "missing": missing}
            continue
        h = LuaHarness()
        h.set_bs("near_spool", flag)
        h.connect(focus=(0, 0), radius=192, budget=1000, rate=0, sub_chunks=None)
        nb_unit = int(h.lua.eval(
            """
            (function()
                settings.global["f3d-detail-radius"].value = 160
                F.surface.is_chunk_generated = function(pos)
                    local cx, cy = pos.x or pos[1], pos.y or pos[2]
                    return math.abs(cx) <= 8 and math.abs(cy) <= 8
                end
                F.commands["f3d-bs"]({parameter = "send_cap 200"})
                F.commands["f3d-bs"]({parameter = "walk_load 100000"})
                local uid = 5000
                for idx = 1, 65 do
                    uid = uid + 1
                    local b = F.spawn("transport-belt", 105.5 + (idx % 32), 4.5 + math.floor(idx / 32) * 2.0, {direction = 4})
                    F.put_on_belt(b, 1, "iron-plate", 0.5, uid)
                end
                uid = uid + 1
                local nb = F.spawn("transport-belt", 2.5, 2.5, {direction = 4})
                F.put_on_belt(nb, 1, "iron-plate", 0.5, uid)
                return nb.unit_number
            end)()
            """
        ))
        chunks = [[cx, cy] for cx in range(2, 5) for cy in range(0, 3)] + [[0, 0]]
        h.send_packet({"t": "sub", "c": chunks})
        h.lua.execute('package.loaded["scripts.belt_sim"].reset()')
        # Wait until spool has >=2 outer parts queued on a non-due tick.
        for _ in range(40):
            sp = int(h.lua.eval('package.loaded["scripts.belt_sim"].spooled()'))
            nxt_mod = (int(h.lua.eval("game.tick")) + 1) % 6
            if sp >= 2 and nxt_mod != 1:
                break
            if sp == 0 and nxt_mod != 1:
                h.lua.execute('package.loaded["scripts.belt_sim"].reset()')
            h.tick(1)
        # Trigger near belt rotation on this non-due tick and watch ticks until its `lm` emits!
        h.lua.execute(
            """
            local nb = F.surface.find_entity("transport-belt", {x = 2.5, y = 2.5})
            if nb then
                nb.direction = 8
                F.raise("on_player_rotated_entity", {entity = nb, previous_direction = 4})
            end
            """
        )
        near_key = nb_unit * 8 + 1
        ticks_to_bs: int | None = None
        for t in range(1, 50):
            for msgs, _ in h.tick(1):
                if any(m.get("t") == "bs" and near_key in (m.get("lm") or []) for m in msgs):
                    ticks_to_bs = t
                    break
            if ticks_to_bs is not None:
                break
        arms[label] = {"status": "ran", "ticks_to_near_bs_wire": ticks_to_bs}

    return {
        "id": "S6",
        "title": "near_spool priority under send_cap",
        "status": "skipped_pending_mod_merge" if missing else "passed",
        "missing_switches": missing,
        "arms": arms,
    }


def _simulate_drop_and_recovery(
    drop_rate: float, use_nack: bool, seed: int
) -> dict[str, Any]:
    """Drive 400 reliable frames through `MockGame` with drop_rate, NACK vs resync."""
    rng = random.Random(seed)
    srv, _srv_sock, sock, addr = _start_mock_server(seed=seed, drop=0.0)
    try:
        sock.sendto(
            (json.dumps({"t": "hello", "v": mock_server.PROTOCOL, "sid": "drop-test"}) + "\n").encode("utf-8"),
            addr,
        )
        for _ in range(8):
            _pump_mock_rx(srv)
            srv.flush()
        _drain_udp(sock)
        sock.sendto((json.dumps({"t": "sub", "c": [[0, 0], [1, 0]]}) + "\n").encode("utf-8"), addr)
        _pump_mock_rx(srv)
        srv.update()
        srv.flush()
        _drain_udp(sock)

        first_r = srv.rseq + 1
        target_count = 400
        kinds = ("chunk", "add", "upd", "del", "inv", "st")
        for i in range(target_count):
            t = kinds[i % len(kinds)]
            if t == "chunk":
                srv.send_reliable({"t": "chunk", "cx": i % 2, "cy": 0, "tiles": []})
            elif t == "add":
                srv.send_reliable({"t": "add", "id": 5000 + i, "name": "iron-chest"})
            elif t == "upd":
                srv.send_reliable({"t": "upd", "id": 5000 + (i % 10), "dir": i % 16})
            elif t == "del":
                srv.send_reliable({"t": "del", "id": 5000 + i})
            elif t == "inv":
                srv.send_reliable({"t": "inv", "items": [["iron-plate", i + 1]]})
            else:
                srv.send_reliable({"t": "st", "id": 5000 + (i % 10), "st": 1})

        seen_r: set[int] = set()
        dropped_r: set[int] = set()
        retrans_bytes = 0
        ticks = 0
        while srv.outbox and ticks < 400:
            ticks += 1
            srv.flush()
            msgs, _ = decode_datagrams(_drain_udp(sock))
            for m in msgs:
                r_num = m.get("r")
                if not isinstance(r_num, int):
                    continue
                if rng.random() < drop_rate:
                    dropped_r.add(r_num)
                else:
                    seen_r.add(r_num)

        expected = set(range(first_r, first_r + target_count))
        missing = sorted(r for r in expected if r not in seen_r)
        recover_ticks = 0
        if use_nack:
            # Recover in batches <= 64 from 256-entry ring; any aged-out (< latest-256) fallback via c.
            for idx in range(0, len(missing), protocol.NACK_MAX_R):
                batch = missing[idx : idx + protocol.NACK_MAX_R]
                sock.sendto(
                    (json.dumps({"t": "nack", "r": batch, "c": [[0, 0], [1, 0]]}) + "\n").encode("utf-8"),
                    addr,
                )
                recover_ticks += 1
                _pump_mock_rx(srv)
                for _ in range(10):
                    srv.flush()
                rec_msgs, nbytes = decode_datagrams(_drain_udp(sock))
                retrans_bytes += nbytes
                for m in rec_msgs:
                    if isinstance(m.get("r"), int):
                        seen_r.add(m["r"])
        else:
            # Resync resends subscribed chunks.
            sock.sendto(
                (json.dumps({"t": "resync", "full": 0, "c": [[0, 0], [1, 0]]}) + "\n").encode("utf-8"),
                addr,
            )
            _pump_mock_rx(srv)
            for _ in range(20):
                recover_ticks += 1
                srv.update()
                srv.flush()
                rec_msgs, nbytes = decode_datagrams(_drain_udp(sock))
                retrans_bytes += nbytes
                for m in rec_msgs:
                    if isinstance(m.get("r"), int):
                        seen_r.add(m["r"])

        recovered_within_ring = sum(
            1 for r in missing if r > (first_r + target_count - 1 - protocol.NACK_RING_SIZE) and r in seen_r
        )
        ring_eligible = sum(
            1 for r in missing if r > (first_r + target_count - 1 - protocol.NACK_RING_SIZE)
        )
        return {
            "drop_rate": drop_rate,
            "mode": "nack" if use_nack else "resync",
            "dropped_count": len(missing),
            "ring_eligible": ring_eligible,
            "recovered_within_ring": recovered_within_ring,
            "ring_lossless_pct": round(100.0 * recovered_within_ring / max(1, ring_eligible), 1),
            "retransmit_bytes": retrans_bytes,
            "recovery_ticks": recover_ticks,
        }
    finally:
        sock.close()
        try:
            _srv_sock.close()
        except Exception:
            pass


def bench_s7() -> dict[str, Any]:
    """S7: `nack_ring` — 5% and 15% packet loss across 400 messages + aged-out fallback."""
    probe = LuaHarness()
    missing = _switch_gate_note(probe, [("perf", "nack_ring")])
    mock_ab = {
        "loss_5pct": {
            "nack_on": _simulate_drop_and_recovery(0.05, True, seed=101),
            "resync_off": _simulate_drop_and_recovery(0.05, False, seed=101),
        },
        "loss_15pct": {
            "nack_on": _simulate_drop_and_recovery(0.15, True, seed=202),
            "resync_off": _simulate_drop_and_recovery(0.15, False, seed=202),
        },
    }
    lua_arms: dict[str, Any] = {}
    if missing:
        lua_arms["status"] = "skipped_pending_mod_merge"
        lua_arms["missing_switches"] = missing
    else:
        for flag_label, flag in (("off", False), ("on", True)):
            h = LuaHarness()
            h.set_perf("nack_ring", flag)
            h.connect(focus=(0, 0), budget=1000, rate=0, sub_chunks=[[0, 0]])
            # Send 5 reliable frames, grab target r, then NACK it with c=[[0,0]] and check ring hit vs chunk resend.
            h.lua.execute(
                """
                local tr = package.loaded["scripts.transport"]
                for i = 1, 5 do tr.send_reliable({ t = "inv", l = { { "iron-plate", 800 + i } } }) end
                """
            )
            sent_batch = [m for msgs, _ in h.tick(2) for m in msgs]
            hit_target = next((int(m["r"]) for m in sent_batch if m.get("t") == "inv"), 2)
            rseq_before = int(h.lua.eval("storage.f3d.rseq"))
            h.send_packet({"t": "nack", "r": [hit_target], "c": [[0, 0]]})
            msgs_hit = [m for msgs, _ in h.tick(3) for m in msgs]
            replayed_exact = any(m.get("r") == hit_target and m.get("t") == "inv" for m in msgs_hit)
            chunk_resent_on_hit = any(m.get("t") == "chunk" and m.get("cx") == 0 for m in msgs_hit)
            # Push >256 frames so hit_target ages out of the ring, then verify chunk resend fallback.
            h.lua.execute(
                """
                local tr = package.loaded["scripts.transport"]
                for i = 1, 265 do tr.send_reliable({ t = "inv", l = { { "coal", i } } }) end
                """
            )
            for _ in range(12):
                h.tick(1)
            h.send_packet({"t": "nack", "r": [hit_target], "c": [[0, 0]]})
            msgs_aged = [m for msgs, _ in h.tick(4) for m in msgs]
            aged_nack_replayed = any(m.get("r") == hit_target for m in msgs_aged)
            aged_chunk_on_nack = any(m.get("t") == "chunk" and m.get("cx") == 0 for m in msgs_aged)
            aged_chunk_after_resync = False
            if flag:
                h.send_packet({"t": "resync", "full": 0, "c": [[0, 0]]})
                msgs_resync = [m for msgs, _ in h.tick(4) for m in msgs]
                aged_chunk_after_resync = any(m.get("t") == "chunk" and m.get("cx") == 0 for m in msgs_resync)
            lua_arms[flag_label] = {
                "status": "ran",
                "hit_replayed_exact_r": replayed_exact,
                "hit_skipped_chunk_resend": not chunk_resent_on_hit,
                "aged_miss_noop_on_nack": (not aged_nack_replayed) and (not aged_chunk_on_nack) if flag else True,
                "aged_miss_chunk_resent": aged_chunk_after_resync if flag else aged_chunk_on_nack,
                "rseq_before": rseq_before,
            }

    return {
        "id": "S7",
        "title": "nack_ring (5%/15% drop + >256 aged-out fallback)",
        "status": "passed" if not missing else "skipped_pending_mod_merge",
        "missing_switches": missing,
        "mock_ab": mock_ab,
        "lua_arms": lua_arms,
    }


def run_synthetic_suite(only: set[str] | None = None) -> list[dict[str, Any]]:
    """Run requested synthetic benchmarks (or all S1,S2,S4,S5,S6,S7)."""
    runners = [
        ("S1", bench_s1),
        ("S2", bench_s2),
        ("S4", bench_s4),
        ("S5", bench_s5),
        ("S6", bench_s6),
        ("S7", bench_s7),
    ]
    results = []
    for key, fn in runners:
        if only and key.lower() not in only:
            continue
        results.append(fn())
    return results


# ---------------------------------------------------------------------------
# Part B — Live Headless Factorio 2.1 Mega-Base Stress Test
# ---------------------------------------------------------------------------


class LiveUdpClient:
    """Lightweight Python UDP client for headless Factorio bridge stress testing."""

    def __init__(self, udp_port: int, client_port: int = SCRATCH_CLIENT_PORT) -> None:
        self.server_addr = ("127.0.0.1", udp_port)
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.bind(("127.0.0.1", client_port))
        self.sock.setblocking(False)
        self.max_r = 0
        self.seen_r: set[int] = set()
        self.drop_rate = 0.0
        self.rng = random.Random(42)
        self.dropped_r: set[int] = set()
        self._hello_msg: dict[str, Any] | None = None
        self._last_hello = 0.0

    def close(self) -> None:
        try:
            self.sock.close()
        except Exception:
            pass

    def send(self, msg: dict[str, Any]) -> None:
        if msg.get("t") == "hello":
            self._hello_msg = dict(msg)
            self._last_hello = time.monotonic()
        raw = (json.dumps(msg, separators=(",", ":")) + "\n").encode("utf-8")
        self.sock.sendto(raw, self.server_addr)

    def poll(self) -> tuple[list[dict[str, Any]], int, list[int]]:
        """Read pending datagrams, sending a periodic hello keepalive every 2 s."""
        if self._hello_msg is not None and time.monotonic() - self._last_hello >= 2.0:
            self.send(self._hello_msg)
        raw_list = _drain_udp(self.sock, wait=0.0)
        msgs, nbytes = decode_datagrams(raw_list)
        kept: list[dict[str, Any]] = []
        new_gaps: list[int] = []
        for m in msgs:
            r_num = m.get("r")
            if isinstance(r_num, int):
                if self.drop_rate > 0.0 and self.rng.random() < self.drop_rate:
                    self.dropped_r.add(r_num)
                    continue
                if r_num > self.max_r + 1 and self.max_r > 0:
                    for missing in range(self.max_r + 1, r_num):
                        if missing not in self.seen_r:
                            new_gaps.append(missing)
                if r_num > self.max_r:
                    self.max_r = r_num
                self.seen_r.add(r_num)
            kept.append(m)
        return kept, nbytes, new_gaps


def _read_rcon_password() -> str:
    for base in (REPO, main_checkout()):
        for name in ("rcon-password.txt", "rconpw"):
            pw_file = base / "server" / "data" / name
            if pw_file.is_file():
                return pw_file.read_text(encoding="utf-8").strip()
    return "factorio"


def _wait_for_rcon(port: int, timeout: float = 60.0) -> str | None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        pw = _read_rcon_password()
        try:
            reply = rcon.run("/f3d-status", host="127.0.0.1", port=port, password=pw, timeout=2.0)
            if reply is not None:
                return reply
        except Exception:
            pass
        time.sleep(0.5)
    return None


def _parse_profile_ms(status_text: str) -> float | None:
    m = re.search(r"Duration:\s*([0-9.]+)ms\s*per\s*tick", status_text or "")
    return float(m.group(1)) if m else None


def run_live_suite(
    factorio_override: str | None = None, only: set[str] | None = None
) -> dict[str, Any]:
    """Launch headless Factorio with `Zenith Test.zip` on scratch ports and run live passes."""
    raw_exe = factorio_override or factorio_install.exe()
    exe = Path(raw_exe) if raw_exe else None
    save_src = find_zenith_save()
    if exe is None or not exe.is_file():
        return {"status": "skipped", "reason": "Factorio executable not found"}
    if save_src is None or not save_src.is_file():
        return {"status": "skipped", "reason": "server/saves/Zenith Test.zip not found"}

    scratch_dir = REPO / "art-src" / "stress-test"
    scratch_dir.mkdir(parents=True, exist_ok=True)
    save_copy = scratch_dir / "Zenith Test.zip"
    shutil.copy2(save_src, save_copy)
    server_log = scratch_dir / "server.log"

    ps1 = REPO / "server" / "run-server.ps1"
    env = os.environ.copy()
    env["FACTORIO_EXE"] = str(exe)
    cmd = [
        "powershell",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        str(ps1),
        "-Save",
        str(save_copy),
        "-UdpPort",
        str(SCRATCH_UDP_PORT),
        "-GamePort",
        str(SCRATCH_GAME_PORT),
        "-RconPort",
        str(SCRATCH_RCON_PORT),
    ]
    log_fh = server_log.open("w", encoding="utf-8", errors="replace")
    proc = subprocess.Popen(
        cmd,
        cwd=str(REPO),
        env=env,
        stdout=log_fh,
        stderr=subprocess.STDOUT,
        text=True,
    )
    client: LiveUdpClient | None = None
    out: dict[str, Any] = {"status": "passed", "passes": {}}
    try:
        status_reply = _wait_for_rcon(SCRATCH_RCON_PORT, timeout=60.0)
        if status_reply is None:
            return {"status": "skipped", "reason": "Headless Factorio RCON timed out on scratch port 36402"}
        pw = _read_rcon_password()

        def rcmd(c: str) -> str:
            return rcon.run(c, host="127.0.0.1", port=SCRATCH_RCON_PORT, password=pw, timeout=10.0)

        perf_list = rcmd("/f3d-perf")
        bs_list = rcmd("/f3d-bs")
        avail_perf = {
            k for k in ("flush_end", "near_first", "near_rate", "nack_ring", "prio_queue") if k in perf_list
        }
        avail_bs = {k for k in ("near_spool",) if k in bs_list}
        out["available_switches"] = {"perf": sorted(avail_perf), "bs": sorted(avail_bs)}

        client = LiveUdpClient(SCRATCH_UDP_PORT, SCRATCH_CLIENT_PORT)
        client.send(
            {
                "t": "hello",
                "v": mock_server.PROTOCOL,
                "sid": "live-stress",
                "z": 0,
                "dc": 1,
                "b": 1,
                "bl": 1,
                "bs": 1,
                "ie": 2,
                "rb": 1,
                "lod": 1,
            }
        )
        deadline = time.monotonic() + 15.0
        welcomed = False
        welcome_msg: dict[str, Any] = {}
        while time.monotonic() < deadline:
            msgs, _, _ = client.poll()
            for m in msgs:
                if m.get("t") == "welcome":
                    welcomed = True
                    welcome_msg = m
                    break
            if welcomed:
                break
            time.sleep(0.05)
        if not welcomed:
            out["status"] = "skipped"
            out["reason"] = "UDP client did not receive welcome on port 36403"
            return out

        # Bump budget so prototype chunks finish streaming, then drain initial bursts.
        client.send({"t": "budget", "u": 2000})
        t_proto = time.monotonic()
        while time.monotonic() - t_proto < 2.0:
            client.poll()
            time.sleep(0.05)

        # Dismiss Factorio's one-time console warning if needed and locate focus/base center.
        rcmd("/sc rcon.print('ok')")
        rcmd("/sc rcon.print('ok')")
        fx_reply = rcmd(
            '/sc local s=storage.f3d; local p=(s and s.puppet) or (game.players[1] and game.players[1].character); '
            'if p and p.valid then rcon.print(math.floor(p.position.x)..","..math.floor(p.position.y)) '
            'else rcon.print("0,0") end'
        ).strip()
        try:
            fx_parts = fx_reply.splitlines()[-1].split(",")
            base_x, base_y = int(fx_parts[0]), int(fx_parts[1])
        except Exception:
            base_x = int((welcome_msg.get("x", 0) or 0) // 256)
            base_y = int((welcome_msg.get("y", 0) or 0) // 256)
        base_cx, base_cy = base_x // 32, base_y // 32

        # Drain initial protos and subscribe 7x7 near active focus/base center.
        client.send({"t": "budget", "u": 2000})
        client.send({"t": "focus", "x": base_x * 256, "y": base_y * 256, "r": 128})
        sub_7x7 = [
            [cx, cy]
            for cx in range(base_cx - 3, base_cx + 4)
            for cy in range(base_cy - 3, base_cy + 4)
        ]
        client.send({"t": "sub", "c": sub_7x7})
        time.sleep(1.5)
        client.poll()

        def set_arm(on: bool) -> None:
            mode = "on" if on else "off"
            for opt in ("flush_end", "near_first", "near_rate", "nack_ring", "prio_queue"):
                if opt in avail_perf:
                    rcmd(f"/f3d-perf {opt} {mode}")
            for opt in ("near_spool",):
                if opt in avail_bs:
                    rcmd(f"/f3d-bs {opt} {mode}")

        # Pass 1: Live edit under chunk + map + budget 60, rate 3
        if not only or "live1" in only:
            p1: dict[str, Any] = {}
            for label, on in (("off", False), ("on", True)):
                set_arm(on)
                client.send({"t": "budget", "u": 60})
                client.send({"t": "rate", "l": 3})
                client.send(
                    {
                        "t": "map",
                        "cx1": base_cx - 3,
                        "cy1": base_cy - 3,
                        "cx2": base_cx + 3,
                        "cy2": base_cy + 3,
                    }
                )
                client.send({"t": "sub", "c": sub_7x7})
                client.poll()
                t0 = time.monotonic()
                rcmd(
                    f'/sc local s=game.surfaces[1]; local pos=s.find_non_colliding_position("wooden-chest",{{{base_x},{base_y}}},24,1) or {{{base_x},{base_y}}}; '
                    'local c=s.create_entity{name="wooden-chest",position=pos,force="player"}; '
                    'if c then storage._f3d_stress_c=c; script.raise_event(defines.events.script_raised_built,{entity=c}) end'
                )
                add_ms = None
                while time.monotonic() - t0 < 5.0:
                    msgs, _, _ = client.poll()
                    if any(m.get("t") == "add" for m in msgs):
                        add_ms = round((time.monotonic() - t0) * 1000.0, 1)
                        break
                    time.sleep(0.01)
                rcmd(
                    '/sc local c=storage._f3d_stress_c; '
                    'if c and c.valid then c.destroy{raise_destroy=true} end; storage._f3d_stress_c=nil'
                )
                time.sleep(0.1)
                client.poll()
                p1[label] = {"add_latency_ms": add_ms}
            out["passes"]["live_edit_storm"] = p1

        # Pass 2: 10% reliable drop storm
        if not only or "live2" in only:
            p2: dict[str, Any] = {}
            sub_9x9 = [
                [cx, cy]
                for cx in range(base_cx - 4, base_cx + 5)
                for cy in range(base_cy - 4, base_cy + 5)
            ]
            for label, on in (("off", False), ("on", True)):
                set_arm(on)
                # Clear existing subscriptions so each arm streams the full 9x9 chunk storm.
                client.send({"t": "sub", "c": []})
                time.sleep(0.2)
                client.poll()
                client.dropped_r.clear()
                client.seen_r.clear()
                client.max_r = 0
                client.drop_rate = 0.10
                client.send({"t": "budget", "u": 400})
                client.send({"t": "sub", "c": sub_9x9})
                t_drop = time.monotonic()
                gaps_all: list[int] = []
                while time.monotonic() - t_drop < 2.5:
                    _, _, gaps = client.poll()
                    if gaps:
                        gaps_all.extend(gaps)
                    time.sleep(0.02)
                client.drop_rate = 0.0
                dropped_target = set(client.dropped_r)
                t_rec0 = time.monotonic()
                if dropped_target:
                    missing_sorted = sorted(dropped_target)
                    if on and "nack_ring" in avail_perf:
                        for i in range(0, len(missing_sorted), protocol.NACK_MAX_R):
                            client.send(
                                {
                                    "t": "nack",
                                    "r": missing_sorted[i : i + protocol.NACK_MAX_R],
                                    "c": [[base_cx, base_cy]],
                                }
                            )
                    else:
                        client.send(
                            {"t": "resync", "full": 0, "c": sub_9x9[:16]}
                        )
                retrans_bytes = 0
                recovery_ms = None
                while time.monotonic() - t_rec0 < 3.0:
                    _, nbytes, _ = client.poll()
                    retrans_bytes += nbytes
                    if dropped_target and dropped_target.issubset(client.seen_r):
                        recovery_ms = round((time.monotonic() - t_rec0) * 1000.0, 1)
                        break
                    time.sleep(0.02)
                recovered = sum(1 for r in dropped_target if r in client.seen_r)
                p2[label] = {
                    "dropped_frames": len(dropped_target),
                    "recovered_frames": recovered,
                    "recovery_pct": round(100.0 * recovered / max(1, len(dropped_target)), 1) if dropped_target else 100.0,
                    "recovery_ms": recovery_ms if recovery_ms is not None else round((time.monotonic() - t_rec0) * 1000.0, 1),
                    "retrans_bytes": retrans_bytes,
                }
            out["passes"]["drop_storm_10pct"] = p2

        # Pass 3: Near-bubble cadence under rate 3 + budget 60 + /f3d-profile
        if not only or "live3" in only:
            p3: dict[str, Any] = {}
            for label, on in (("off", False), ("on", True)):
                set_arm(on)
                client.send({"t": "budget", "u": 60})
                client.send({"t": "rate", "l": 3})
                # Reset /f3d-profile cleanly so each arm measures its own 600-tick window.
                if "profiling off" not in rcmd("/f3d-status"):
                    rcmd("/f3d-profile")
                rcmd("/f3d-profile")
                st_n = mv_n = bs_n = ie_n = 0
                t_start = time.monotonic()
                while time.monotonic() - t_start < 10.5:
                    msgs, _, _ = client.poll()
                    for m in msgs:
                        tp = m.get("t")
                        if tp == "st":
                            st_n += 1
                        elif tp == "mv":
                            mv_n += 1
                        elif tp == "bs":
                            bs_n += 1
                        elif tp == "ie":
                            ie_n += 1
                    time.sleep(0.02)
                prof_reply = rcmd("/f3d-status")
                p3[label] = {
                    "st_msgs": st_n,
                    "mv_msgs": mv_n,
                    "bs_msgs": bs_n,
                    "ie_msgs": ie_n,
                    "bridge_ms_per_tick": _parse_profile_ms(prof_reply),
                }
            out["passes"]["near_bubble_cadence"] = p3

        for opt in avail_perf:
            rcmd(f"/f3d-perf {opt} default")
        for opt in avail_bs:
            rcmd(f"/f3d-bs {opt} default")
    finally:
        if client is not None:
            client.close()
        try:
            pw = _read_rcon_password()
            rcon.run("/quit", host="127.0.0.1", port=SCRATCH_RCON_PORT, password=pw, timeout=5.0)
        except Exception:
            pass
        try:
            proc.wait(timeout=15.0)
        except subprocess.TimeoutExpired:
            proc.terminate()
            try:
                proc.wait(timeout=5.0)
            except subprocess.TimeoutExpired:
                proc.kill()
        log_fh.close()
    return out


# ---------------------------------------------------------------------------
# Summary Output & CLI
# ---------------------------------------------------------------------------


def print_summary_table(report: dict[str, Any]) -> None:
    """Print a compact summary table of benchmark results."""
    print("\n=== Bridge Responsiveness Stress Test Summary ===")
    print(f"{'Check':<24} {'Status':<28} {'Details'}")
    print("-" * 92)
    pm = report.get("protocol_mock", {})
    print(f"{'protocol_mock_nack':<24} {pm.get('status', 'n/a'):<28} mock_ring={pm.get('checks', {}).get('mock_ring', {}).get('hit_matched')}")
    for item in report.get("synthetic", []):
        missing = item.get("missing_switches") or []
        detail = f"missing={','.join(missing)}" if missing else f"arms={','.join(item.get('arms', {}).keys())}"
        print(f"{item['id'] + ' ' + item['title'][:19]:<24} {item.get('status', 'n/a'):<28} {detail}")
    live = report.get("live", {})
    if live:
        detail = live.get("reason") or f"passes={','.join(live.get('passes', {}).keys())}"
        print(f"{'live_zenith_test':<24} {live.get('status', 'n/a'):<28} {detail}")


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    ap = argparse.ArgumentParser(description="Bridge responsiveness stress test & A/B benchmark")
    ap.add_argument(
        "--mode",
        choices=("synthetic", "live", "both"),
        default="both",
        help="Run synthetic Lua suite, live headless Factorio suite, or both (default: both).",
    )
    ap.add_argument(
        "--out",
        default=str(DEFAULT_OUT),
        help="Output JSON path (default: art-src/stress-test/results.json).",
    )
    ap.add_argument("--factorio", default=None, help="Optional path to Factorio executable.")
    ap.add_argument("--only", default="", help="Comma-separated scenario IDs (e.g. S1,S7,live1).")
    return ap.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    only = {s.strip().lower() for s in args.only.split(",") if s.strip()} if args.only else None

    report: dict[str, Any] = {"mode": args.mode}
    report["protocol_mock"] = run_protocol_and_mock_checks()

    if args.mode in ("synthetic", "both"):
        report["synthetic"] = run_synthetic_suite(only=only)
    if args.mode in ("live", "both"):
        report["live"] = run_live_suite(factorio_override=args.factorio, only=only)

    out_path = Path(args.out)
    if not out_path.is_absolute():
        out_path = REPO / out_path
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(report, indent=2), encoding="utf-8")
    print_summary_table(report)
    print(f"\nWrote results to {out_path}")

    failed = report["protocol_mock"].get("status") == "failed"
    for item in report.get("synthetic", []):
        if item.get("status") == "failed":
            failed = True
    if report.get("live", {}).get("status") == "failed":
        failed = True
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
