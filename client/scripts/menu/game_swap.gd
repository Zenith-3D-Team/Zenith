extends RefCounted
## Swapping between the 3D client and the normal game, on the same running world: one key
## here ("Show in Factorio", Ctrl+F9) brings Factorio's window to the front, or starts Factorio
## joined to the server this client started; the mod's own key in Factorio (the same Ctrl+F9,
## "Show in Zenith") sends `raise` back, and the client comes to the front. Nothing reloads: the
## server keeps running, and while the player is in the real game the bridge drives their character
## (puppet.lua), so both windows show the same character.
##
## Windows refuses SetForegroundWindow to a process that isn't in front, so a hidden PowerShell
## does it with the usual Alt-key tap first.

const Paths := preload("res://scripts/menu/paths.gd")

const FOCUS_PS := """param([int]$Id, [string]$Name)
Add-Type @'
using System; using System.Runtime.InteropServices;
public class ZenithWin {
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern void keybd_event(byte b, byte s, uint f, UIntPtr e);
}
'@
if ($Id -gt 0) { $p = Get-Process -Id $Id -ErrorAction SilentlyContinue }
else { $p = Get-Process -Name $Name -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1 }
if (-not $p -or $p.MainWindowHandle -eq 0) { exit 2 }
$h = $p.MainWindowHandle
if ([ZenithWin]::IsIconic($h)) { [ZenithWin]::ShowWindow($h, 9) | Out-Null }
[ZenithWin]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero)
[ZenithWin]::SetForegroundWindow($h) | Out-Null
[ZenithWin]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero)
exit 0
"""

## Minimises Factorio's window (to spare its drawing while Zenith shows the game). Started and
## not waited for: PowerShell takes a few hundred milliseconds to start.
const MINIMIZE_PS := """Add-Type @'
using System; using System.Runtime.InteropServices;
public class ZenithMin { [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c); }
'@
Start-Sleep -Milliseconds 300
Get-Process -Name factorio -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } |
	ForEach-Object { [ZenithMin]::ShowWindow($_.MainWindowHandle, 6) | Out-Null }
"""

## The Factorio this client started to join its server, if it's still running.
static var _game_pid := -1


## Brings Factorio's window forward, or starts Factorio joined to `game_port` (the server this
## client started; 0 when the client connected to a game it didn't start). Returns a line for the
## HUD's message.
static func show_factorio(game_port: int) -> String:
	var started := _game_pid > 0 and OS.is_process_running(_game_pid)
	if _focus(_game_pid if started else 0, "factorio") == 0:
		return ""
	if started:
		return "Factorio is running: switch to its window"  # never a second one (no wmctrl off Windows)
	if game_port <= 0:
		return "No Factorio window to show: start Factorio and join this game (or play it in single-player with --enable-lua-udp)"
	var exe := Paths.factorio_exe()
	if exe == "" or not FileAccess.file_exists(exe):
		return "Factorio wasn't found: set its folder in Settings → Factorio"
	_game_pid = OS.create_process(exe, ["--mp-connect", "127.0.0.1:%d" % game_port])
	if _game_pid <= 0:
		_game_pid = -1
		return "Couldn't start Factorio"
	return "Starting Factorio, joining this game: Ctrl+F9 there comes back to 3D"


## The mod's `raise`: the player pressed "Show in Zenith" in the real game. Factorio's window is
## minimised after, unless the player turned that off (Settings → Other).
static func show_client(minimize_game := true) -> void:
	if DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_MINIMIZED:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_move_to_foreground()
	_focus(OS.get_process_id(), "")
	if minimize_game:
		minimize_factorio()


## Factorio's window minimised (Windows only), without waiting.
static func minimize_factorio() -> void:
	if OS.get_name() != "Windows":
		return
	var script := _script_file("minimize_factorio.ps1", MINIMIZE_PS)
	if script != "":
		OS.create_process("powershell.exe", ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
			"-WindowStyle", "Hidden", "-File", script.replace("/", "\\")])


## How to start this client, for the launcher beside Factorio (server/factorio-with-zenith.ps1):
## Ctrl+F9 in a Factorio with no Zenith connected starts what was run last. Written at start-up.
static func write_launch_info() -> void:
	if not _played_here():
		return
	install_launcher()
	var args: Array = []
	if not OS.has_feature("template"):
		args = ["--path", ProjectSettings.globalize_path("res://")]  # an editor build runs the project
	var info := {"exe": OS.get_executable_path(), "args": args,
		"dir": OS.get_executable_path().get_base_dir(), "pid": OS.get_process_id()}
	var f := FileAccess.open("user://launch.json", FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(info, "  "))


## Only a Zenith someone plays: test and probe runs (headless, muted with the dummy audio driver)
## and session worktrees' copies would leave Ctrl+F9 starting them instead.
static func _played_here() -> bool:
	var cmd := OS.get_cmdline_args()
	var i := cmd.find("--audio-driver")
	var muted := i >= 0 and i + 1 < cmd.size() and cmd[i + 1] == "Dummy"
	return not (DisplayServer.get_name() == "headless" or muted or ProjectSettings.globalize_path("res://").contains("/.claude/worktrees/"))


## Where Zenith keeps the launcher for Factorio's launch options: the same folder on every PC
## (C:\ProgramData\Zenith), so the line is the same for everyone and Factorio's help window and
## Settings > Other give it whole. Windows only ("" elsewhere).
static func launcher_path() -> String:
	if OS.get_name() != "Windows":
		return ""
	var base := OS.get_environment("ProgramData")
	if base == "":
		base = "C:\\ProgramData"
	return base + "\\Zenith\\factorio-with-zenith.ps1"


## Factorio's Steam launch options for Ctrl+F9 in Factorio: the launcher, then Factorio's own command.
static func launch_options() -> String:
	var script := launcher_path()
	if script == "":
		script = Paths.repo_dir().path_join("server/factorio-with-zenith.ps1")
	return "powershell -ExecutionPolicy Bypass -WindowStyle Hidden -File \"%s\" %%command%%" % script


## Copies this Zenith's launcher (server/factorio-with-zenith.ps1 beside it) to launcher_path()
## when it differs: a new version brings its own, and the launch options never change.
static func install_launcher() -> void:
	var dest := launcher_path()
	var src := Paths.repo_dir().path_join("server/factorio-with-zenith.ps1")
	if dest == "" or not FileAccess.file_exists(src):
		return
	var text := FileAccess.get_file_as_string(src)
	if FileAccess.file_exists(dest) and FileAccess.get_file_as_string(dest) == text:
		return
	DirAccess.make_dir_recursive_absolute(dest.get_base_dir())
	var f := FileAccess.open(dest, FileAccess.WRITE)
	if f != null:
		f.store_string(text)


static func _script_file(file_name: String, text: String) -> String:
	var script := OS.get_user_data_dir().path_join(file_name)
	if not FileAccess.file_exists(script) or FileAccess.get_file_as_string(script) != text:
		var f := FileAccess.open(script, FileAccess.WRITE)
		if f == null:
			return ""
		f.store_string(text)
		f.close()
	return script


## 0 when the window came forward. Off Windows the window is found by its class name with wmctrl,
## whatever the process.
static func _focus(pid: int, process_name: String) -> int:
	if OS.get_name() != "Windows":
		if process_name == "":
			return 1
		var out: Array = []
		return OS.execute("sh", ["-c", "command -v wmctrl >/dev/null && wmctrl -x -a %s" % process_name], out)
	var script := _script_file("focus_window.ps1", FOCUS_PS)
	if script == "":
		return 1
	var args := ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden",
		"-File", script.replace("/", "\\"), "-Id", str(pid), "-Name", process_name if process_name != "" else "none"]
	var out: Array = []
	return OS.execute("powershell.exe", args, out)
