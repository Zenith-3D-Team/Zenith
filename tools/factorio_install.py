"""Where Factorio is installed, for the tools: the install folder (the one with data/ and bin/) and
its executable, found the way server/run-server.ps1 finds them.

FACTORIO, when set, is the install folder (a path to the executable inside it works too); else
every Steam library (Steam's own folder from the registry or the usual places, and the libraries
its libraryfolders.vdf lists), then the standalone installer's folders. Standard library only, so
Blender's Python can import it:

    sys.path.append(<repo>/tools)
    import factorio_install
    root = factorio_install.install()      # the folder, or Steam's default one when none is found
    exe = factorio_install.exe()           # <root>/bin/x64/factorio.exe (factorio on Linux)
"""
import os
import re

STEAM_DEFAULT = r"C:\Program Files (x86)\Steam\steamapps\common\Factorio"


def _steam_roots():
    roots = []
    if os.name == "nt":
        try:
            import winreg
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, r"Software\Valve\Steam") as key:
                roots.append(os.path.normpath(winreg.QueryValueEx(key, "SteamPath")[0]))
        except OSError:
            pass
        roots.append(r"C:\Program Files (x86)\Steam")
    else:
        roots += [os.path.expanduser("~/.steam/steam"), os.path.expanduser("~/.local/share/Steam"),
                  os.path.expanduser("~/Library/Application Support/Steam")]
    return roots


def _steam_libraries():
    libs = []
    for root in _steam_roots():
        libs.append(root)
        try:
            with open(os.path.join(root, "steamapps", "libraryfolders.vdf"), encoding="utf-8", errors="ignore") as f:
                libs += [p.replace("\\\\", "\\") for p in re.findall(r'"path"\s+"([^"]+)"', f.read())]
        except OSError:
            pass
    unique = []
    for lib in libs:
        if os.path.normcase(lib) not in [os.path.normcase(u) for u in unique]:
            unique.append(lib)
    return unique


def _folder_of(path):
    """An install folder from FACTORIO: the folder itself, or the one holding bin/x64/<executable>."""
    if os.path.isfile(path):
        return os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(path))))
    return path


def candidates():
    """Every folder looked in, in order."""
    out = [os.path.join(lib, "steamapps", "common", "Factorio") for lib in _steam_libraries()]
    out += [r"C:\Program Files\Factorio", os.path.expanduser("~/factorio"), "/Applications/factorio.app/Contents",
            os.path.expanduser("~/Library/Application Support/Steam/steamapps/common/Factorio/factorio.app/Contents")]
    return out


def find():
    """The install folder, or None. FACTORIO is taken as it is; the others need a data/base folder."""
    env = os.environ.get("FACTORIO")
    if env:
        return _folder_of(env)
    for folder in candidates():
        if os.path.isdir(os.path.join(folder, "data", "base")):
            return folder
    return None


def install():
    """The install folder, or Steam's default one when none is found (whatever reads it then fails
    with a missing file, as the tools did before they looked)."""
    return find() or STEAM_DEFAULT


def exe(folder=None):
    """The game's executable in `folder` (by default install())."""
    folder = folder or install()
    for rel in (("bin", "x64", "factorio.exe"), ("bin", "x64", "factorio"), ("MacOS", "factorio")):
        path = os.path.join(folder, *rel)
        if os.path.isfile(path):
            return path
    return os.path.join(folder, "bin", "x64", "factorio.exe" if os.name == "nt" else "factorio")


if __name__ == "__main__":
    print(install())
    print(exe())
