<#
.SYNOPSIS
NVIDIA DLSS's window test (FSR 4 plan, step 7): Zenith's patched Godot on Direct3D 12 with its debug layer, drawing
through ZenithDlssUpscaler (Zenith's own Streamline build, the owner's own nvngx_dlss.dll), checked for zero
debug-layer errors, pictures that aren't black, no network connection from the program or anything it starts, and
no NVIDIA updater (nvngx_update.exe) started.

.DESCRIPTION
Exports tools/godot/hook_test with tools/godot/dlss_test on top (a tiny project, not Zenith) with the patched template
from tools/godot/build_template.ps1 and the upscalers DLL (client/native/upscalers/build.bat, built with Streamline's
headers), puts the DLSS files in the export's vendor/nvidia, then runs it: in a window (unless -HeadlessOnly), muted,
with --gpu-validation (the D3D12 debug layer) and its own log. dlss_test.gd draws Bilinear at 1.0, then DLSS at 1.0
(DLAA), at 0.67 (Quality) and 0.5 (Performance) with motion, then lets go and shuts Streamline down.

vendor/nvidia gets:
  - sl.interposer.dll, sl.common.dll, sl.dlss.dll and zenith-sl-manifest.txt from -Streamline (by default the main
    checkout's git-ignored art-src/vendor-runtimes/streamline-built, made by tools/dlss/build_streamline.ps1);
  - nvngx_dlss.dll from -NgxDll (by default art-src/vendor-runtimes/nvidia/nvngx_dlss.dll): NVIDIA's own DLSS, which
    the owner downloads: github.com/NVIDIA/DLSS, release v310.9.16 (released with Streamline v2.14.16), file
    lib/Windows_x86_64/rel/nvngx_dlss.dll (tools/dlss/README.md).

While it runs, a watcher looks every 0.25 s at the TCP connections and UDP endpoints of the program and every
process under it, and at every process started on the PC: any connection to an address that isn't this PC, any
child process, or any nvngx_update.exe fails the test (an nvngx_update.exe whose parent isn't ours is reported too,
since NVIDIA's driver may run its own). A connection that opens and closes between two looks can be missed; for a
full capture run Windows' pktmon as administrator alongside (-Pktmon).

Opens a window for about a minute: run it only when nobody is using the PC. Needs an NVIDIA RTX card, and Windows'
optional feature "Graphics Tools" for the debug layer (d3d12SDKLayers.dll).

    powershell -ExecutionPolicy Bypass -File tools\godot\dlss_window_test.ps1 -Godot <Godot 4.7.2 editor exe>
        [-Template <windows_release_x86_64.exe>] [-Streamline <dir>] [-NgxDll <nvngx_dlss.dll>] [-Out <dir>]
        [-Frames 120] [-JitterFlip | -JitterFlipY] [-DirectBarriers] [-Pktmon] [-HeadlessOnly]

-JitterFlip / -JitterFlipY hand DLSS the jitter negated (if the pictures shimmer); -DirectBarriers tries the second
way of handing Godot's enhanced-barrier layouts over (--dlss-barriers=direct) if the COMMON bridge shows layer errors.
Exit 0 when every check passed; the result is <Out>\result.json (with the watcher's findings in network.json), the
log <Out>\godot.log, the pictures <Out>\dlss_*.png.
#>
param(
	[string]$Godot = $env:GODOT,
	[string]$Template = "",
	[string]$Streamline = "",
	[string]$NgxDll = "",
	[string]$Out = "",
	[int]$Frames = 120,
	[switch]$JitterFlip,
	[switch]$JitterFlipY,
	[switch]$DirectBarriers,
	[switch]$Pktmon,
	[int]$TimeoutSec = 300,
	[switch]$HeadlessOnly
)
$ErrorActionPreference = "Stop"

$Repo = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$Main = Split-Path -Parent (git -C $Repo rev-parse --path-format=absolute --git-common-dir)
if (-not $Template) { $Template = Join-Path $Main "art-src\godot-build\out\4.7.2\windows_release_x86_64.exe" }
if (-not $Out) { $Out = Join-Path $Main "art-src\dlss-window-test" }
if (-not $Streamline) { $Streamline = Join-Path $Main "art-src\vendor-runtimes\streamline-built" }
if (-not $NgxDll) { $NgxDll = Join-Path $Main "art-src\vendor-runtimes\nvidia\nvngx_dlss.dll" }
$SlFiles = @("sl.interposer.dll", "sl.common.dll", "sl.dlss.dll", "zenith-sl-manifest.txt")
foreach ($f in $SlFiles) {
	if (-not (Test-Path (Join-Path $Streamline $f))) { throw "missing: $Streamline\$f (tools\dlss\build_streamline.ps1, or -Streamline)" }
}
if (-not (Test-Path $NgxDll)) {
	throw "missing: $NgxDll (NVIDIA's nvngx_dlss.dll from github.com/NVIDIA/DLSS, lib/Windows_x86_64/rel/; or -NgxDll)"
}
$Dll = Join-Path $Repo "client\native\bin\upscalers.windows.template_release.x86_64.dll"
foreach ($f in @($Godot, $Template, $Dll)) {
	if (-not $f -or -not (Test-Path $f)) { throw "missing: '$f' (-Godot <editor exe>, -Template, client\native\upscalers\build.bat)" }
}
$free = try { (Get-Counter '\Memory\Available MBytes' -ErrorAction Stop).CounterSamples[0].CookedValue / 1024 } catch { 99 }
if ($free -lt 8) { throw ("{0:N1} GB RAM free, the test wants 8" -f $free) }
if (-not $HeadlessOnly -and -not (Test-Path (Join-Path $env:WINDIR "System32\d3d12SDKLayers.dll"))) {
	Write-Warning "d3d12SDKLayers.dll not found: install Windows' optional feature 'Graphics Tools' for the D3D12 debug layer"
}

# 1. A fresh copy of the test project with the DLL and the patched template.
$proj = Join-Path $Out "project"
$export = Join-Path $Out "export"
if (Test-Path $proj) { Remove-Item $proj -Recurse -Force }  # plain files only, made by this script
if (Test-Path $export) { Remove-Item $export -Recurse -Force }
New-Item -ItemType Directory -Force $proj, $export, (Join-Path $proj "bin") | Out-Null
Get-ChildItem (Join-Path $PSScriptRoot "hook_test") -File | Copy-Item -Destination $proj
Get-ChildItem (Join-Path $PSScriptRoot "dlss_test") -File | Copy-Item -Destination $proj -Force  # its project.godot wins
Copy-Item $Dll (Join-Path $proj "bin")
$presets = Join-Path $proj "export_presets.cfg"
$tpl = $Template.Replace("\", "/")
$text = (Get-Content $presets -Raw) -replace '(?m)^custom_template/release=""', "custom_template/release=`"$tpl`""
[IO.File]::WriteAllText($presets, $text, (New-Object Text.UTF8Encoding $false))  # no BOM: Godot's reader rejects one
Remove-Item (Join-Path $Out "result.json"), (Join-Path $Out "network.json"), (Join-Path $Out "godot.log") -ErrorAction SilentlyContinue

function Invoke-Godot([string]$exe, [string[]]$argv, [string]$log) {
	$p = Start-Process $exe -ArgumentList $argv -PassThru -NoNewWindow
	$null = $p.Handle
	if (-not $p.WaitForExit($TimeoutSec * 1000)) {
		Stop-Process -Id $p.Id -Force  # only the process this script started
		throw "timed out after $TimeoutSec s: $exe (log $log)"
	}
	return $p.ExitCode
}

# 2. Import and export with the editor, headless; then vendor/nvidia beside the program.
$elog = Join-Path $Out "export.log"
$null = Invoke-Godot $Godot @("--headless", "--audio-driver", "Dummy", "--log-file", "`"$elog`"", "--path", "`"$proj`"", "--import") $elog
$exe = Join-Path $export "DlssTest.exe"
$code = Invoke-Godot $Godot @("--headless", "--audio-driver", "Dummy", "--log-file", "`"$elog`"", "--path", "`"$proj`"",
	"--export-release", "`"Windows Desktop`"", "`"$exe`"") $elog
if ($code -or -not (Test-Path $exe)) { throw "export failed (exit $code), log $elog" }
if (-not (Test-Path (Join-Path $export "upscalers.windows.template_release.x86_64.dll"))) {
	Copy-Item $Dll $export  # the export normally copies it beside the program
}
$nvidia = Join-Path $export "vendor\nvidia"
New-Item -ItemType Directory -Force $nvidia | Out-Null
foreach ($f in $SlFiles) { Copy-Item (Join-Path $Streamline $f) $nvidia }
Copy-Item $NgxDll (Join-Path $nvidia "nvngx_dlss.dll")
$ngxVersion = (Get-Item (Join-Path $nvidia "nvngx_dlss.dll")).VersionInfo.FileVersion
$ngxSig = Get-AuthenticodeSignature (Join-Path $nvidia "nvngx_dlss.dll")
Write-Host ("nvngx_dlss.dll {0}, signature {1} ({2})" -f $ngxVersion, $ngxSig.Status, $ngxSig.SignerCertificate.Subject)

# 3. Run it, watching its network and the processes it starts.
$log = Join-Path $Out "godot.log"
$argv = @("--audio-driver", "Dummy", "--log-file", "`"$log`"")
if ($HeadlessOnly) { $argv = @("--headless") + $argv }
else { $argv += @("--rendering-driver", "d3d12", "--gpu-validation") }
$argv += @("--", "--out=`"$Out`"", "--frames=$Frames")
if ($JitterFlip) { $argv += "--dlss-jitter=flip" } elseif ($JitterFlipY) { $argv += "--dlss-jitter=flip-y" }
if ($DirectBarriers) { $argv += "--dlss-barriers=direct" }

$pktmonFile = Join-Path $Out "pktmon.etl"
if ($Pktmon) {
	pktmon start --capture --pkt-size 0 --file-name "$pktmonFile" | Out-Null
	if ($LASTEXITCODE) { Write-Warning "pktmon didn't start (run as administrator)"; $Pktmon = $false }
}
$sourceId = "ZenithDlssProcessStart"
Register-WmiEvent -Query "SELECT * FROM __InstanceCreationEvent WITHIN 0.5 WHERE TargetInstance ISA 'Win32_Process'" -SourceIdentifier $sourceId | Out-Null
$connections = @{}
$children = @{}
$updaters = @{}
function Test-Local([string]$addr) {
	return $addr -match '^(127\.|0\.0\.0\.0|::1?$|::$|::ffff:127\.)' -or $addr -eq "*"
}
$p = Start-Process $exe -ArgumentList $argv -PassThru -NoNewWindow
$null = $p.Handle
$deadline = (Get-Date).AddSeconds($TimeoutSec)
$tree = @{ [int]$p.Id = "DlssTest.exe" }
try {
	while (-not $p.HasExited) {
		if ((Get-Date) -gt $deadline) {
			Stop-Process -Id $p.Id -Force  # only the process this script started
			throw "timed out after $TimeoutSec s: $exe (log $log)"
		}
		# Processes started since the last look: ours (parent in our tree) and any updater anywhere.
		foreach ($e in @(Get-Event -SourceIdentifier $sourceId -ErrorAction SilentlyContinue)) {
			$t = $e.SourceEventArgs.NewEvent.TargetInstance
			$name = [string]$t.Name
			$procId = [int]$t.ProcessId
			$parent = [int]$t.ParentProcessId
			if ($tree.ContainsKey($parent)) {
				$tree[$procId] = $name
				$children["$procId"] = "$name (parent $parent): $($t.CommandLine)"
			}
			if ($name -ieq "nvngx_update.exe") {
				$updaters["$procId"] = "parent $parent$(if ($tree.ContainsKey($parent)) { ' (ours)' } else { '' }): $($t.CommandLine)"
			}
			Remove-Event -EventIdentifier $e.EventIdentifier
		}
		foreach ($procId in @($tree.Keys)) {
			foreach ($c in @(Get-NetTCPConnection -OwningProcess $procId -ErrorAction SilentlyContinue)) {
				if ($c.State -ne "Listen" -and $c.State -ne "Bound" -and -not (Test-Local $c.RemoteAddress)) {
					$connections["tcp $($tree[$procId]) -> $($c.RemoteAddress):$($c.RemotePort)"] = [string]$c.State
				}
			}
			foreach ($u in @(Get-NetUDPEndpoint -OwningProcess $procId -ErrorAction SilentlyContinue)) {
				if (-not (Test-Local $u.LocalAddress)) {
					$connections["udp $($tree[$procId]) on $($u.LocalAddress):$($u.LocalPort)"] = "bound"
				}
			}
		}
		Start-Sleep -Milliseconds 250
	}
	$code = $p.ExitCode
} finally {
	Unregister-Event -SourceIdentifier $sourceId -ErrorAction SilentlyContinue
	Remove-Event -SourceIdentifier $sourceId -ErrorAction SilentlyContinue
	if ($Pktmon) { pktmon stop | Out-Null }
}
$oursUpdaters = @($updaters.Values | Where-Object { $_ -match '\(ours\)' })
@{
	connections = $connections; children = $children; updaters = $updaters
	pktmon = $(if ($Pktmon) { $pktmonFile } else { "" })
} | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $Out "network.json") -Encoding utf8

# 4. Verdict: dlss_test.gd's checks, no D3D12 debug-layer errors, no network, no child process, no updater of ours.
$resultFile = Join-Path $Out "result.json"
if (-not (Test-Path $resultFile)) { throw "no result.json (exit $code), log $log" }
$result = Get-Content $resultFile -Raw | ConvertFrom-Json
$lines = if (Test-Path $log) { Get-Content $log } else { @() }
$layerErrors = @($lines | Where-Object { $_ -match "^ERROR: .*Message Id Number" })
$layerWarnings = @($lines | Where-Object { $_ -match "^WARNING: .*Message Id Number" })
$errors = @($lines | Where-Object { $_ -match "^(ERROR|SCRIPT ERROR):" })
$slMessages = @($lines | Where-Object { $_ -match "^NVIDIA DLSS" })
$presentMissing = @($slMessages | Where-Object { $_ -match "presentCommon|Present.*not observed" })
Write-Host ("driver {0}, adapter {1}, Streamline headers {2}, runtime '{3}', DLSS {4}, passed {5}" -f $result.driver, $result.adapter,
	$result.built_with_sl, $result.runtime_problem, $result.dlss_file_version, $result.passed)
$slMessages | Select-Object -First 15 | ForEach-Object { Write-Host "  $_" }
Write-Host ("D3D12 debug layer: {0} error(s), {1} warning(s); {2} error line(s) in all" -f $layerErrors.Count, $layerWarnings.Count, $errors.Count)
Write-Host ("network: {0} connection(s)/endpoint(s); {1} child process(es); nvngx_update.exe: {2} ours, {3} in all" -f $connections.Count,
	$children.Count, $oursUpdaters.Count, $updaters.Count)
$connections.Keys | ForEach-Object { Write-Host "  $_ ($($connections[$_]))" }
$children.Values | ForEach-Object { Write-Host "  child: $_" }
$updaters.Values | ForEach-Object { Write-Host "  nvngx_update.exe: $_" }
foreach ($f in $result.failed) { Write-Host "  failed: $f" }
$layerErrors | Select-Object -First 10 | ForEach-Object { Write-Host "  $_" }
$ok = $result.passed -and $layerErrors.Count -eq 0 -and $code -eq 0 -and $connections.Count -eq 0 -and $children.Count -eq 0 `
	-and $oursUpdaters.Count -eq 0 -and $presentMissing.Count -eq 0
if ($updaters.Count -gt $oursUpdaters.Count) { Write-Warning "an nvngx_update.exe ran that Zenith didn't start (NVIDIA's driver?): see network.json" }
if ($presentMissing.Count) { Write-Host "  Streamline says its per-frame present wasn't seen: slHookPresent didn't do its job" }
if ($HeadlessOnly) { $ok = $result.built_with_sl -and $result.runtime_problem -eq "" -and $result.headless -and $connections.Count -eq 0 -and $children.Count -eq 0 }
if (-not $HeadlessOnly -and -not $result.validation) { Write-Warning "--gpu-validation was not seen by the program" }
if ($ok) { Write-Host "PASS ($Out)"; exit 0 } else { Write-Host "FAIL ($Out)"; exit 1 }
