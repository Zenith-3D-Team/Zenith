## Clicks in Factorio's own window, for mods' windows drawn in Zenith (mod_gui.gd): a mod only hears
## a real click in Factorio (no script can raise on_gui_click), so in hybrid, where the player's
## Factorio window is open, a click on a mod's button in Zenith is sent there, at the place
## Factorio has that button. Windows only: a PowerShell helper kept running (starting one per click
## would take a second), told "<mode> <x> <y>" per click in Factorio's client pixels (real ones: the
## helper is DPI-aware, or with display scaling Windows hands it scaled ones and the click misses):
##   focus  Factorio comes to the front for the click, the real mouse clicks there, Zenith comes
##          back and the pointer goes back where it was (a minimised Factorio is shown first)
##   post   window messages to Factorio's window, Zenith staying in front: Factorio 2.1.24 ignores
##          them (checked with Informatron), kept for trying other versions
## It answers one line per click: ok, none (no Factorio window), or an error. mod_gui.gd reads the
## answers every frame while clicks wait (poll): unread, they would fill the helper's output pipe
## after a hundred clicks or so and block it.

const HELPER := """
Add-Type @'
using System; using System.Runtime.InteropServices;
public static class ZC {
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
  [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, int dx, int dy, uint d, UIntPtr e);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
}
'@
# Real pixels: with display scaling Windows would hand this process scaled ones.
[ZC]::SetProcessDPIAware() | Out-Null
while ($true) {
  $line = [Console]::In.ReadLine()
  if ($line -eq $null) { break }
  try {
    $a = $line.Split(' ')
    $p = Get-Process factorio -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
    if (-not $p) { [Console]::Out.WriteLine('none'); [Console]::Out.Flush(); continue }
    $h = $p.MainWindowHandle; $x = [int]$a[1]; $y = [int]$a[2]
    $me = [ZC]::GetForegroundWindow()
    $was_min = [ZC]::IsIconic($h)
    if ($was_min) { [ZC]::ShowWindow($h, 4) | Out-Null; Start-Sleep -Milliseconds 400 }
    if ($a[0] -eq 'post') {
      $l = [IntPtr](($y -shl 16) -bor ($x -band 0xFFFF))
      [ZC]::PostMessage($h, 0x200, [IntPtr]0, $l) | Out-Null
      Start-Sleep -Milliseconds 40
      [ZC]::PostMessage($h, 0x201, [IntPtr]1, $l) | Out-Null
      Start-Sleep -Milliseconds 40
      [ZC]::PostMessage($h, 0x202, [IntPtr]0, $l) | Out-Null
    } else {
      $pt = New-Object ZC+POINT; $pt.X = $x; $pt.Y = $y
      [ZC]::ClientToScreen($h, [ref]$pt) | Out-Null
      $old = New-Object ZC+POINT; [ZC]::GetCursorPos([ref]$old) | Out-Null
      [ZC]::SetForegroundWindow($h) | Out-Null
      Start-Sleep -Milliseconds 120
      [ZC]::SetCursorPos($pt.X, $pt.Y) | Out-Null
      Start-Sleep -Milliseconds 60
      [ZC]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero)
      Start-Sleep -Milliseconds 40
      [ZC]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero)
      Start-Sleep -Milliseconds 120
      [ZC]::SetForegroundWindow($me) | Out-Null
      [ZC]::SetCursorPos($old.X, $old.Y) | Out-Null
    }
    # Minimised again if it was (Ctrl+F9 leaves it so), without taking the front from Zenith.
    if ($was_min) { Start-Sleep -Milliseconds 150; [ZC]::ShowWindow($h, 7) | Out-Null }
    Start-Sleep -Milliseconds 100
    $fpid = [uint32]0; [ZC]::GetWindowThreadProcessId([ZC]::GetForegroundWindow(), [ref]$fpid) | Out-Null
    $back = if ($fpid -eq $p.Id) { 'factorio' } else { 'other' }
    [Console]::Out.WriteLine("ok front=$back minimised=$([ZC]::IsIconic($h))")
  } catch { [Console]::Out.WriteLine('error ' + $_) }
  [Console]::Out.Flush()
}
"""

static var _pipe: Dictionary = {}
## Clicks sent that the helper hasn't answered yet.
static var waiting := 0
## Its latest answers, oldest first (the last 16), for probes.
static var heard := PackedStringArray()


static func available() -> bool:
	return OS.get_name() == "Windows"


static func _start() -> bool:
	if not _pipe.is_empty() and OS.is_process_running(int(_pipe.get("pid", -1))):
		return true
	var path := OS.get_user_data_dir().path_join("factorio_clicks.ps1")
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(HELPER)
	f.close()
	_pipe = OS.execute_with_pipe("powershell.exe", ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", path], false)
	return not _pipe.is_empty()


## Clicks at `at` in Factorio's window (its client pixels); `mode` "post" or "focus".
static func click(at: Vector2, mode := "focus") -> bool:
	if not available() or not _start():
		return false
	var io: FileAccess = _pipe.get("stdio")
	if io == null:
		return false
	io.store_line("%s %d %d" % [mode, roundi(at.x), roundi(at.y)])
	io.flush()
	waiting += 1
	return true


## The answers that have come since ("ok front=factorio|other minimised=True|False", "none" or
## "error ..." a click); "error ..." too when the helper has gone with clicks unanswered.
static func poll() -> PackedStringArray:
	var out := PackedStringArray()
	if waiting <= 0 or _pipe.is_empty():
		return out
	if not OS.is_process_running(int(_pipe.get("pid", -1))):
		waiting = 0
		_pipe = {}
		out.append("error the click helper ended")
	else:
		var io: FileAccess = _pipe.get("stdio")
		# The pipe is non-blocking (execute_with_pipe's blocking false): an empty line means nothing more yet.
		for _i in 64:
			if io == null:
				break
			var line := io.get_line()
			if line == "":
				break
			out.append(line)
			waiting = maxi(0, waiting - 1)
	heard.append_array(out)
	if heard.size() > 16:
		heard = heard.slice(heard.size() - 16)
	return out


## Ends the helper (mod_gui.gd leaving the tree, the client quitting).
static func stop() -> void:
	waiting = 0
	if not _pipe.is_empty():
		OS.kill(int(_pipe.get("pid", -1)))
		_pipe = {}
