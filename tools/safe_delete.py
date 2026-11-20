"""Deleting a folder that may hold links, without ever deleting what a link points to.

A server or Factorio data folder links the repo's mod in (server/run-server.ps1 and the menu make
`mods/factorio-3d-bridge` a Windows junction to `mod/factorio-3d-bridge`), and scratch folders may link
Factorio's own user folder. A delete that follows such a link empties its target: the main checkout's
mod and the owner's %APPDATA%/Factorio were emptied that way once (a `robocopy /MOVE` without /XJ).

pathlib's is_symlink() is False for a junction, so `if p.is_symlink(): ... else: shutil.rmtree(p)` takes
the wrong branch on Windows. Use these instead:

    remove_link(p)  removes the link itself (os.rmdir/os.unlink), never its target
    remove_tree(p)  removes a folder: every link inside it goes first as a link, then the rest

The same rule outside Python: PowerShell `[System.IO.Directory]::Delete(link)` or `cmd /c rmdir link`
(no /s) on the link; robocopy /MOVE or /MIR only with /XJ; never PowerShell 5.1's
`Remove-Item -Recurse` on a folder that may hold a junction.
"""
import os
import shutil
import stat


def is_link(path) -> bool:
    """True for a symlink or a Windows junction (any reparse-point folder), broken or not."""
    path = os.fspath(path)
    if os.path.islink(path):
        return True
    if hasattr(os.path, "isjunction") and os.path.isjunction(path):
        return True
    try:
        st = os.lstat(path)
    except OSError:
        return False
    return bool(getattr(st, "st_file_attributes", 0) & getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0))


def remove_link(path) -> None:
    """Removes a symlink or junction itself; its target is not touched."""
    path = os.fspath(path)
    if not is_link(path):
        raise ValueError(f"not a link: {path}")
    try:
        os.unlink(path)  # a file symlink, or any symlink outside Windows
    except (IsADirectoryError, PermissionError, OSError):
        os.rmdir(path)  # a junction or directory symlink on Windows: rmdir removes the link only


def remove_tree(path) -> None:
    """Deletes `path` (a folder, a file or a link) and everything under it, removing every link found as a
    link first so nothing is ever deleted through one. A missing path is fine."""
    path = os.fspath(path)
    if is_link(path):
        remove_link(path)
        return
    if not os.path.exists(path):
        return
    if not os.path.isdir(path):
        os.remove(path)
        return
    for root, dirs, files in os.walk(path, topdown=True, followlinks=False):
        for name in list(dirs):
            full = os.path.join(root, name)
            if is_link(full):
                remove_link(full)
                dirs.remove(name)  # never walk into it
        for name in files:
            full = os.path.join(root, name)
            if is_link(full):
                remove_link(full)
    shutil.rmtree(path)
