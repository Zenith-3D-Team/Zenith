"""Deleting a folder that holds links never deletes the links' targets (tools/safe_delete.py and its users).

Builds a temp target folder and a temp "server data" folder whose mods/ links to it (a junction on Windows,
the way server/run-server.ps1 and the menu link the bridge mod; a symlink elsewhere), runs each cleanup and
checks the target still has its files. All in a temp folder; nothing of the repo or the player's is touched.
"""
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

TOOLS = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(TOOLS))
import safe_delete  # noqa: E402

WINDOWS = os.name == "nt"
failures = []


def check(name, ok, detail=""):
    print(("ok   " if ok else "FAIL ") + name + (f": {detail}" if detail and not ok else ""), flush=True)
    if not ok:
        failures.append(name)


def link(at: pathlib.Path, to: pathlib.Path):
    at.parent.mkdir(parents=True, exist_ok=True)
    if WINDOWS:
        subprocess.run(["cmd", "/c", "mklink", "/J", str(at), str(to)], check=True, capture_output=True)
    else:
        os.symlink(to, at, target_is_directory=True)
    assert safe_delete.is_link(at), at


def make_target(base: pathlib.Path, name="target") -> pathlib.Path:
    t = base / name
    (t / "scripts").mkdir(parents=True)
    (t / "control.lua").write_text("-- control\n", encoding="utf-8")
    (t / "scripts" / "belt_sim.lua").write_text("-- belts\n", encoding="utf-8")
    return t


def intact(t: pathlib.Path) -> bool:
    return (t / "control.lua").is_file() and (t / "scripts" / "belt_sim.lua").is_file()


def main():
    with tempfile.TemporaryDirectory(prefix="zenith-safe-delete-") as tmp:
        base = pathlib.Path(tmp)

        # 1. A data folder with a linked mod (and one link deeper down), deleted whole.
        t = make_target(base, "t1")
        data = base / "data1"
        (data / "saves").mkdir(parents=True)
        (data / "saves" / "a.zip").write_bytes(b"zip")
        link(data / "mods" / "factorio-3d-bridge", t)
        link(data / "deep" / "er" / "again", t)
        safe_delete.remove_tree(data)
        check("remove_tree: the folder is gone", not os.path.lexists(data))
        check("remove_tree: the linked target keeps its files", intact(t))

        # 2. The path itself is the link.
        t = make_target(base, "t2")
        lk = base / "lk2"
        link(lk, t)
        safe_delete.remove_tree(lk)
        check("remove_tree on a link: the link is gone", not os.path.lexists(lk))
        check("remove_tree on a link: the target keeps its files", intact(t))

        # 3. A broken link (its target moved or deleted) is removed too.
        t = make_target(base, "t3")
        lk = base / "lk3"
        link(lk, t)
        shutil.rmtree(t)
        safe_delete.remove_link(lk)
        check("remove_link on a broken link", not os.path.lexists(lk))

        # 4. belt_view_check.sync_mod in a worktree whose server mod is a link to another checkout's mod
        #    with other contents: it must replace the link with a copy, not empty the other checkout.
        import belt_view_check  # noqa: E402
        other = make_target(base, "other-checkout-mod")
        wt = base / "wt"
        src = wt / "mod" / "factorio-3d-bridge"
        src.mkdir(parents=True)
        (src / "control.lua").write_text("-- the worktree's own\n", encoding="utf-8")
        dst = wt / "server" / "data" / "mods" / "factorio-3d-bridge"
        link(dst, other)
        belt_view_check.sync_mod(wt)
        check("sync_mod: the other checkout's mod keeps its files", intact(other)
              and (other / "control.lua").read_text(encoding="utf-8") == "-- control\n")
        check("sync_mod: the server mod is now a real copy of the worktree's",
              not safe_delete.is_link(dst) and (dst / "control.lua").read_text(encoding="utf-8") == "-- the worktree's own\n")

        if WINDOWS:
            # 5. server/run-server.ps1's and the menu's (server_launcher.gd _unlink) way: rmdir without /s.
            t = make_target(base, "t5")
            lk = base / "data5" / "mods" / "factorio-3d-bridge"
            link(lk, t)
            subprocess.run(["cmd", "/c", "rmdir", str(lk)], capture_output=True)
            check("cmd rmdir (no /s) removes the junction only", not os.path.lexists(lk) and intact(t))

            # 6. The safe pattern for moving folders off a drive: robocopy /MOVE with /XJ skips junctions.
            if shutil.which("robocopy"):
                t = make_target(base, "t6")
                srcdir = base / "move-src"
                (srcdir / "clips").mkdir(parents=True)
                (srcdir / "clips" / "a.mp4").write_bytes(b"x")
                link(srcdir / "srv" / "mods" / "factorio-3d-bridge", t)
                r = subprocess.run(["robocopy", str(srcdir), str(base / "move-dst"), "/MOVE", "/E", "/XJ",
                                    "/R:0", "/W:0", "/NFL", "/NDL", "/NP"], capture_output=True)
                check("robocopy /MOVE /XJ: the junction's target keeps its files", intact(t), f"exit {r.returncode}")
                check("robocopy /MOVE /XJ: the rest moved", (base / "move-dst" / "clips" / "a.mp4").is_file())
                # The junction stays behind in the source: remove it as a link before deleting that folder.
                safe_delete.remove_tree(srcdir)
                check("then remove_tree on what is left keeps the target", intact(t) and not srcdir.exists())

    print(f"{'FAILED: ' + ', '.join(failures) if failures else 'all passed'}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
