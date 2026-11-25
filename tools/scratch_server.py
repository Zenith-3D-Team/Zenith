#!/usr/bin/env python3
"""Reusable scratch headless Factorio server helper for tests and tools.

Manages an isolated temporary Factorio data directory, links the bridge mod
via a Windows junction (or POSIX symlink), binds strictly to 127.0.0.1, provides
an RCON command/shutdown helper, and cleans up all links and trees strictly
through ``tools/safe_delete.py`` (never ``shutil.rmtree`` on a path that may
contain a junction).

Python 3.9+ standard library only.
"""
from __future__ import annotations

import os
import pathlib
import re
import secrets
import shutil
import socket
import string
import subprocess
import sys
import tempfile
import time
from typing import Sequence

_TOOLS_DIR = pathlib.Path(__file__).resolve().parent
if str(_TOOLS_DIR) not in sys.path:
    sys.path.insert(0, str(_TOOLS_DIR))

import rcon  # noqa: E402
import safe_delete  # noqa: E402

REPO = _TOOLS_DIR.parent
DEFAULT_MOD_DIR = REPO / "mod" / "factorio-3d-bridge"
DEFAULT_SERVER_SETTINGS = REPO / "server" / "server-settings.json"
LOCALHOST = "127.0.0.1"


def find_factorio(explicit: str | os.PathLike[str] | None = None) -> pathlib.Path | None:
    """Locate the Factorio executable from an explicit path, env, or standard installs."""
    candidates: list[pathlib.Path] = []
    if explicit:
        candidates.append(pathlib.Path(explicit))
    env_bin = os.environ.get("FACTORIO_BIN")
    if env_bin:
        candidates.append(pathlib.Path(env_bin))

    if os.name == "nt":
        try:
            import winreg

            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, r"Software\Valve\Steam") as key:
                steam_path, _ = winreg.QueryValueEx(key, "SteamPath")
            vdf = pathlib.Path(steam_path) / "steamapps" / "libraryfolders.vdf"
            if vdf.is_file():
                text = vdf.read_text(encoding="utf-8", errors="replace")
                for m in re.finditer(r'"path"\s+"([^"]+)"', text):
                    lib = pathlib.Path(m.group(1).replace("\\\\", "\\"))
                    candidates.append(lib / "steamapps" / "common" / "Factorio" / "bin" / "x64" / "factorio.exe")
        except OSError:
            pass
        candidates.append(pathlib.Path(r"C:\Program Files\Factorio\bin\x64\factorio.exe"))
    else:
        which = shutil.which("factorio")
        if which:
            candidates.append(pathlib.Path(which))
        candidates.extend([
            pathlib.Path("/opt/factorio/bin/x64/factorio"),
            pathlib.Path.home() / "factorio" / "bin" / "x64" / "factorio",
        ])

    for cand in candidates:
        if cand.is_file():
            return cand.resolve()
    return None


def link_mod(link_path: pathlib.Path, target_path: pathlib.Path) -> None:
    """Create a Windows junction or POSIX symlink at ``link_path`` -> ``target_path``."""
    link_path.parent.mkdir(parents=True, exist_ok=True)
    if safe_delete.is_link(link_path):
        safe_delete.remove_link(link_path)
    elif link_path.exists():
        safe_delete.remove_tree(link_path)

    if os.name == "nt":
        res = subprocess.run(
            ["cmd", "/c", "mklink", "/J", str(link_path), str(target_path)],
            capture_output=True,
            text=True,
        )
        if res.returncode != 0:
            raise OSError(f"mklink /J failed ({res.returncode}): {res.stderr.strip() or res.stdout.strip()}")
    else:
        os.symlink(target_path, link_path, target_is_directory=True)


def _random_password(length: int = 24) -> str:
    alphabet = string.ascii_lowercase + string.digits
    return "".join(secrets.choice(alphabet) for _ in range(length))


class ScratchServer:
    """Context-managed headless Factorio server bound strictly to 127.0.0.1."""

    def __init__(
        self,
        *,
        factorio_bin: str | os.PathLike[str] | None = None,
        save_path: str | os.PathLike[str] | None = None,
        udp_port: int = 34210,
        game_port: int = 34199,
        rcon_port: int = 34298,
        rcon_password: str | None = None,
        seed: int = 0,
        mod_dir: pathlib.Path = DEFAULT_MOD_DIR,
        extra_mods: Sequence[pathlib.Path] = (),
        server_settings: pathlib.Path | None = DEFAULT_SERVER_SETTINGS,
        keep_data: bool = False,
    ) -> None:
        resolved = find_factorio(factorio_bin)
        if resolved is None:
            raise FileNotFoundError("Factorio executable not found; pass factorio_bin or set FACTORIO_BIN")
        self.factorio_bin = resolved
        self.udp_port = int(udp_port)
        self.game_port = int(game_port)
        self.rcon_port = int(rcon_port)
        self.rcon_password = rcon_password or _random_password()
        self.seed = int(seed)
        self.mod_dir = pathlib.Path(mod_dir).resolve()
        self.extra_mods = [pathlib.Path(m).resolve() for m in extra_mods]
        self.server_settings = server_settings
        self.keep_data = keep_data

        self.data_dir = pathlib.Path(tempfile.mkdtemp(prefix="zenith-scratch-server-"))
        self.mods_dir = self.data_dir / "mods"
        self.saves_dir = self.data_dir / "saves"
        self.config_ini = self.data_dir / "config.ini"
        self.password_file = self.data_dir / "rcon-password.txt"
        self.save_path = pathlib.Path(save_path) if save_path else (self.saves_dir / "scratch.zip")
        self.proc: subprocess.Popen[bytes] | None = None

    def prepare(self) -> None:
        """Create temp directories, config.ini, mod junctions, and map if needed."""
        self.mods_dir.mkdir(parents=True, exist_ok=True)
        self.saves_dir.mkdir(parents=True, exist_ok=True)
        self.save_path.parent.mkdir(parents=True, exist_ok=True)

        read_data = (self.factorio_bin.parent.parent.parent / "data").resolve()
        self.config_ini.write_text(
            f"[path]\nread-data={read_data}\nwrite-data={self.data_dir}\n",
            encoding="ascii",
        )
        self.password_file.write_text(self.rcon_password, encoding="ascii")

        link_mod(self.mods_dir / self.mod_dir.name, self.mod_dir)
        for extra in self.extra_mods:
            link_mod(self.mods_dir / extra.name, extra)

        if not self.save_path.is_file():
            cmd = [
                str(self.factorio_bin),
                "--config", str(self.config_ini),
                "--mod-directory", str(self.mods_dir),
                "--create", str(self.save_path),
            ]
            if self.seed != 0:
                cmd.extend(["--map-gen-seed", str(self.seed)])
            subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)

    def start(self, wait_timeout: float = 30.0) -> None:
        """Prepare the scratch workspace and launch the headless server on 127.0.0.1."""
        if self.proc is not None and self.proc.poll() is None:
            return
        self.prepare()
        cmd = [
            str(self.factorio_bin),
            "--config", str(self.config_ini),
            "--mod-directory", str(self.mods_dir),
            "--start-server", str(self.save_path),
            "--enable-lua-udp", str(self.udp_port),
            "--port", str(self.game_port),
            "--bind", LOCALHOST,
            "--rcon-bind", f"{LOCALHOST}:{self.rcon_port}",
            "--rcon-password", self.rcon_password,
        ]
        if self.server_settings and self.server_settings.is_file():
            cmd.extend(["--server-settings", str(self.server_settings)])

        log_path = self.data_dir / "stdout.log"
        log_file = log_path.open("wb")
        try:
            self.proc = subprocess.Popen(cmd, stdout=log_file, stderr=subprocess.STDOUT)
        finally:
            log_file.close()

        if wait_timeout > 0 and not self.wait_ready(timeout=wait_timeout):
            self.stop()
            raise TimeoutError(f"ScratchServer RCON on {LOCALHOST}:{self.rcon_port} did not become ready")

    def wait_ready(self, timeout: float = 30.0) -> bool:
        """Poll localhost RCON until the server accepts commands or exits."""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self.proc is not None and self.proc.poll() is not None:
                return False
            try:
                with socket.create_connection((LOCALHOST, self.rcon_port), timeout=0.5):
                    pass
                self.rcon("/f3d-status", timeout=2.0)
                return True
            except (OSError, ConnectionError):
                time.sleep(0.25)
        return False

    def rcon(self, command: str, timeout: float = 5.0) -> str:
        """Send an RCON command to this scratch server on 127.0.0.1."""
        return rcon.run(
            command,
            host=LOCALHOST,
            port=self.rcon_port,
            password=self.rcon_password,
            timeout=timeout,
        )

    def stop(self, timeout: float = 10.0) -> None:
        """Gracefully shut down via RCON /quit, falling back to terminate/kill."""
        proc = self.proc
        if proc is None:
            return
        if proc.poll() is None:
            try:
                self.rcon("/quit", timeout=3.0)
                proc.wait(timeout=timeout)
            except Exception:
                proc.terminate()
                try:
                    proc.wait(timeout=5.0)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait(timeout=5.0)
        self.proc = None

    def cleanup(self) -> None:
        """Stop the server and safely remove the scratch data tree (junction-safe)."""
        self.stop()
        if not self.keep_data and self.data_dir.exists():
            safe_delete.remove_tree(self.data_dir)

    def __enter__(self) -> ScratchServer:
        self.start()
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        self.cleanup()
