<#
.SYNOPSIS
Headless check of Zenith's Streamline build: slInit loads our unsigned plugins by the manifest, refuses a plugin the
manifest doesn't list, and starts no process (no nvngx_update.exe) and no network connection.

.DESCRIPTION
Builds tools/dlss/sl_init_probe.cpp with MSVC (Streamline's MIT headers from -Headers, by default the main checkout's
git-ignored art-src/vendor-runtimes/streamline/v2.14.16/include) into -Out, then runs it twice under a watcher:
  1. on a copy of -Streamline (tools/dlss/build_streamline.ps1's output): must load DLSS's plugin;
  2. on a copy whose manifest has a wrong SHA-256 for sl.dlss.dll: must refuse it (DLSS not loaded).
The watcher looks every 0.25 s at the probe's TCP connections and UDP endpoints and at every process started on the
PC: a connection to another machine, a child process, or an nvngx_update.exe started by the probe fails the check.
No window, no device: slInit only (NVIDIA's own Streamline starts its updater right there, in slInit).
Seen on an RTX 5080 (driver 32.0.16.2101): our build starts nothing itself, but when the DLSS plugin starts,
Streamline asks NGX for DLSS's requirements (NVSDK_NGX_D3D12_GetFeatureRequirements) and NVIDIA's driver NGX runtime
then starts nvngx_update.exe -api update ... -bootstrap with the probe as parent: this check fails on that.

    powershell -ExecutionPolicy Bypass -File tools\dlss\sl_init_probe.ps1 [-Streamline <dir>] [-Out <dir>]
#>
param(
	[string]$Streamline = "",
	[string]$Headers = "",
	[string]$Out = "",
	[int]$TimeoutSec = 60
)
$ErrorActionPreference = "Stop"

$Repo = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$Main = Split-Path -Parent (git -C $Repo rev-parse --path-format=absolute --git-common-dir)
if (-not $Streamline) { $Streamline = Join-Path $Main "art-src\vendor-runtimes\streamline-built" }
if (-not $Headers) { $Headers = Join-Path $Main "art-src\vendor-runtimes\streamline\v2.14.16\include" }
if (-not $Out) { $Out = Join-Path $Main "art-src\streamline-build\probe" }
$SlFiles = @("sl.interposer.dll", "sl.common.dll", "sl.dlss.dll", "zenith-sl-manifest.txt")
foreach ($f in $SlFiles) { if (-not (Test-Path (Join-Path $Streamline $f))) { throw "missing $Streamline\$f" } }
if (-not (Test-Path (Join-Path $Headers "sl.h"))) { throw "missing Streamline headers in $Headers" }
New-Item -ItemType Directory -Force $Out | Out-Null

# 1. Build the probe.
$vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
$vs = (& $vswhere -latest -products * -property installationPath | Select-Object -First 1)
$vcvars = Join-Path $vs "VC\Auxiliary\Build\vcvars64.bat"
$exe = Join-Path $Out "sl_init_probe.exe"
$src = Join-Path $PSScriptRoot "sl_init_probe.cpp"
$env:PATH = "$(Split-Path $vswhere);$env:PATH"  # vcvars looks for vswhere
cmd /d /c "call `"$vcvars`" >nul && cl /nologo /std:c++20 /EHsc /O2 /MD /I `"$Headers`" `"$src`" /Fo`"$Out\\`" /Fe`"$exe`" /link /nologo" | Out-Host
if ($LASTEXITCODE -or -not (Test-Path $exe)) { throw "probe build failed" }

function Test-Local([string]$addr) { return $addr -match '^(127\.|0\.0\.0\.0|::1?$|::$|::ffff:127\.)' -or $addr -eq "*" }

# 2. Run it on a folder under the watcher.
function Invoke-Probe([string]$dir, [string]$name) {
	$log = Join-Path $Out "$name.log"
	$sourceId = "ZenithSlProbe$name"
	Register-WmiEvent -Query "SELECT * FROM __InstanceCreationEvent WITHIN 0.5 WHERE TargetInstance ISA 'Win32_Process'" -SourceIdentifier $sourceId | Out-Null
	$connections = @{}; $children = @{}; $updaters = @{}
	try {
		$p = Start-Process $exe -ArgumentList "`"$dir`"" -PassThru -NoNewWindow -RedirectStandardOutput $log -RedirectStandardError "$log.err"
		$null = $p.Handle
		$tree = @{ [int]$p.Id = "sl_init_probe.exe" }
		$deadline = (Get-Date).AddSeconds($TimeoutSec)
		$last = $false
		while ($true) {
			$done = $p.HasExited
			foreach ($e in @(Get-Event -SourceIdentifier $sourceId -ErrorAction SilentlyContinue)) {
				$t = $e.SourceEventArgs.NewEvent.TargetInstance
				$parent = [int]$t.ParentProcessId
				if ($tree.ContainsKey($parent)) { $tree[[int]$t.ProcessId] = [string]$t.Name; $children["$($t.ProcessId)"] = "$($t.Name): $($t.CommandLine)" }
				if ([string]$t.Name -ieq "nvngx_update.exe") { $updaters["$($t.ProcessId)"] = "parent $parent$(if ($tree.ContainsKey($parent)) { ' (ours)' }): $($t.CommandLine)" }
				Remove-Event -EventIdentifier $e.EventIdentifier
			}
			foreach ($procId in @($tree.Keys)) {
				foreach ($c in @(Get-NetTCPConnection -OwningProcess $procId -ErrorAction SilentlyContinue)) {
					if ($c.State -ne "Listen" -and $c.State -ne "Bound" -and -not (Test-Local $c.RemoteAddress)) { $connections["tcp $($tree[$procId]) ($procId) -> $($c.RemoteAddress):$($c.RemotePort)"] = [string]$c.State }
				}
				foreach ($u in @(Get-NetUDPEndpoint -OwningProcess $procId -ErrorAction SilentlyContinue)) {
					if (-not (Test-Local $u.LocalAddress)) { $connections["udp $($tree[$procId]) ($procId) on $($u.LocalAddress):$($u.LocalPort)"] = "bound" }
				}
			}
			if ($done) { if ($last) { break }; $last = $true; Start-Sleep -Milliseconds 1000; continue }  # one more look for late events
			if ((Get-Date) -gt $deadline) { Stop-Process -Id $p.Id -Force; throw "probe timed out" }  # only our probe
			Start-Sleep -Milliseconds 250
		}
	} finally {
		Unregister-Event -SourceIdentifier $sourceId -ErrorAction SilentlyContinue
		Remove-Event -SourceIdentifier $sourceId -ErrorAction SilentlyContinue
	}
	$text = Get-Content $log -Raw
	return [pscustomobject]@{
		name = $name; exit = $p.ExitCode; ok_line = ($text -match "probe: OK"); log = $log
		connections = @($connections.Keys); children = @($children.Values); updaters = @($updaters.Values)
		ota_never = ($text -match "OTA'd plugins are never loaded"); plugins = ([regex]::Matches($text, "Loaded plugin")).Count
	}
}

# 3. Our build as it is, then with sl.dlss.dll's line in the manifest made wrong.
$good = Join-Path $Out "good"; $bad = Join-Path $Out "bad-manifest"
foreach ($d in @($good, $bad)) {
	if (Test-Path $d) { Get-ChildItem $d -File | Remove-Item -Force } else { New-Item -ItemType Directory $d | Out-Null }
	foreach ($f in $SlFiles) { Copy-Item (Join-Path $Streamline $f) $d }
}
$m = Join-Path $bad "zenith-sl-manifest.txt"
(Get-Content $m) | ForEach-Object { if ($_ -match '^[0-9a-f]{64}  sl\.dlss\.dll$') { ("0" * 64) + "  sl.dlss.dll" } else { $_ } } | Set-Content $m -Encoding ascii

$r1 = Invoke-Probe $good "good"
$r2 = Invoke-Probe $bad "bad-manifest"
$results = @($r1, $r2)
$results | ConvertTo-Json -Depth 3 | Set-Content (Join-Path $Out "probe.json") -Encoding utf8
foreach ($r in $results) {
	Write-Host ("{0}: exit {1}, 'Loaded plugin' x{2}, OTA plugins never loaded: {3}, connections {4}, child processes {5}, nvngx_update.exe {6}" -f $r.name, $r.exit,
		$r.plugins, $r.ota_never, $r.connections.Count, $r.children.Count, $r.updaters.Count)
	$r.connections + $r.updaters | Select-Object -Unique | Select-Object -First 8 | ForEach-Object { Write-Host "  $_" }
}
$ok = $r1.exit -eq 0 -and $r1.ok_line -and $r2.exit -ne 0 -and -not $r2.ok_line
foreach ($r in $results) { $ok = $ok -and $r.connections.Count -eq 0 -and $r.children.Count -eq 0 -and @($r.updaters | Where-Object { $_ -match 'ours' }).Count -eq 0 }
if ($ok) { Write-Host "PASS ($Out)"; exit 0 } else { Write-Host "FAIL ($Out)"; exit 1 }
