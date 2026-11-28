<#
.SYNOPSIS
AMD FSR's window test (FSR 4 plan, step 4): Zenith's patched Godot on Direct3D 12 with its debug layer, drawing
through ZenithFsrUpscaler (AMD FSR 3.1 by default, AMD's signed DLLs in vendor/amd), checked for zero debug-layer
errors and pictures that aren't black.

.DESCRIPTION
Exports tools/godot/hook_test with tools/godot/fsr_test on top (a tiny project, not Zenith) with the patched
template from tools/godot/build_template.ps1 and the upscalers DLL (client/native/upscalers/build.bat, built with
AMD's SDK headers), puts AMD's DLLs and license.md in the export's vendor/amd (from -Vendor, by default the main
checkout's git-ignored art-src/vendor-runtimes/amd), then runs it: in a window (unless -HeadlessOnly), muted, with
--gpu-validation (the D3D12 debug layer) and its own log. fsr_test.gd draws Bilinear at 1.0, then AMD FSR at 1.0,
at 0.5, at 0.5 with motion, then lets go.

Opens a window for about a minute: run it only when nobody is using the PC. Needs Windows' optional feature
"Graphics Tools" for the debug layer (d3d12SDKLayers.dll).

    powershell -ExecutionPolicy Bypass -File tools\godot\fsr_window_test.ps1 -Godot <Godot 4.7.2 editor exe>
        [-Template <windows_release_x86_64.exe>] [-Vendor <dir with AMD's DLLs>] [-Out <dir>] [-Frames 120]
        [-Version 3.1|4.1] [-FsrDebug] [-DirectBarriers] [-HeadlessOnly]

-FsrDebug turns on AMD's own input checks (messages in the log); -DirectBarriers tries the second way of handing
Godot's enhanced-barrier layouts to AMD (--fsr-barriers=direct) if the default COMMON bridge shows layer errors.
Exit 0 when every check passed; the result is <Out>esult.json, the log <Out>\godot.log, the pictures
<Out>\fsr_*.png.
#>
param(
	[string]$Godot = $env:GODOT,
	[string]$Template = "",
	[string]$Out = "",
	[int]$Frames = 120,
	[string]$Vendor = "",
	[string]$Version = "3.1",
	[switch]$FsrDebug,
	[switch]$DirectBarriers,
	[int]$TimeoutSec = 240,
	[switch]$HeadlessOnly
)
$ErrorActionPreference = "Stop"

$Repo = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$Main = Split-Path -Parent (git -C $Repo rev-parse --path-format=absolute --git-common-dir)
if (-not $Template) { $Template = Join-Path $Main "art-src\godot-build\out\4.7.2\windows_release_x86_64.exe" }
if (-not $Out) { $Out = Join-Path $Main "art-src\fsr-window-test" }
if (-not $Vendor) { $Vendor = Join-Path $Main "art-src\vendor-runtimes\amd" }
$AmdFiles = @("amd_fidelityfx_loader_dx12.dll", "amd_fidelityfx_upscaler_dx12.dll", "license.md")
foreach ($f in $AmdFiles) {
	if (-not (Test-Path (Join-Path $Vendor $f))) { throw "missing: $Vendor\$f (tools/release/fetch_vendor_runtimes.py, or -Vendor)" }
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
Get-ChildItem (Join-Path $PSScriptRoot "fsr_test") -File | Copy-Item -Destination $proj -Force  # its project.godot wins
Copy-Item $Dll (Join-Path $proj "bin")
$presets = Join-Path $proj "export_presets.cfg"
$tpl = $Template.Replace("\", "/")
$text = (Get-Content $presets -Raw) -replace '(?m)^custom_template/release=""', "custom_template/release=`"$tpl`""
[IO.File]::WriteAllText($presets, $text, (New-Object Text.UTF8Encoding $false))  # no BOM: Godot's reader rejects one
Remove-Item (Join-Path $Out "result.json"), (Join-Path $Out "godot.log") -ErrorAction SilentlyContinue

function Invoke-Godot([string]$exe, [string[]]$argv, [string]$log) {
	$p = Start-Process $exe -ArgumentList $argv -PassThru -NoNewWindow
	$null = $p.Handle
	if (-not $p.WaitForExit($TimeoutSec * 1000)) {
		Stop-Process -Id $p.Id -Force  # only the process this script started
		throw "timed out after $TimeoutSec s: $exe (log $log)"
	}
	return $p.ExitCode
}

# 2. Import and export with the editor, headless.
$elog = Join-Path $Out "export.log"
$null = Invoke-Godot $Godot @("--headless", "--audio-driver", "Dummy", "--log-file", "`"$elog`"", "--path", "`"$proj`"", "--import") $elog
$exe = Join-Path $export "FsrTest.exe"
$code = Invoke-Godot $Godot @("--headless", "--audio-driver", "Dummy", "--log-file", "`"$elog`"", "--path", "`"$proj`"",
	"--export-release", "`"Windows Desktop`"", "`"$exe`"") $elog
if ($code -or -not (Test-Path $exe)) { throw "export failed (exit $code), log $elog" }
if (-not (Test-Path (Join-Path $export "upscalers.windows.template_release.x86_64.dll"))) {
	Copy-Item $Dll $export  # the export normally copies it beside the program
}
$amd = Join-Path $export "vendor\amd"
New-Item -ItemType Directory -Force $amd | Out-Null
foreach ($f in $AmdFiles) { Copy-Item (Join-Path $Vendor $f) $amd }

# 3. Run it.
$log = Join-Path $Out "godot.log"
$argv = @("--audio-driver", "Dummy", "--log-file", "`"$log`"")
if ($HeadlessOnly) { $argv = @("--headless") + $argv }
else { $argv += @("--rendering-driver", "d3d12", "--gpu-validation") }
$argv += @("--", "--out=`"$Out`"", "--frames=$Frames", "--version=$Version")
if ($FsrDebug) { $argv += "--fsr-debug" }
if ($DirectBarriers) { $argv += "--fsr-barriers=direct" }
$code = Invoke-Godot $exe $argv $log

# 4. Verdict: fsr_test.gd's checks, and no D3D12 debug-layer errors in the log.
$resultFile = Join-Path $Out "result.json"
if (-not (Test-Path $resultFile)) { throw "no result.json (exit $code), log $log" }
$result = Get-Content $resultFile -Raw | ConvertFrom-Json
$lines = if (Test-Path $log) { Get-Content $log } else { @() }
$layerErrors = @($lines | Where-Object { $_ -match "^ERROR: .*Message Id Number" })
$layerWarnings = @($lines | Where-Object { $_ -match "^WARNING: .*Message Id Number" })
$errors = @($lines | Where-Object { $_ -match "^(ERROR|SCRIPT ERROR):" })
Write-Host ("driver {0}, SDK {1}, runtime '{2}' ({3}), available {4}, made {5}, passed {6}" -f $result.driver, $result.built_with_sdk,
	$result.runtime_problem, $result.runtime_file_version, $result.available, $result.stats_1_0.version_created, $result.passed)
$amdMessages = @($lines | Where-Object { $_ -match "^AMD FSR" })
$amdMessages | Select-Object -First 10 | ForEach-Object { Write-Host "  $_" }
Write-Host ("D3D12 debug layer: {0} error(s), {1} warning(s); {2} error line(s) in all" -f $layerErrors.Count, $layerWarnings.Count, $errors.Count)
foreach ($f in $result.failed) { Write-Host "  failed: $f" }
$layerErrors | Select-Object -First 10 | ForEach-Object { Write-Host "  $_" }
$ok = $result.passed -and $layerErrors.Count -eq 0 -and $code -eq 0
if ($HeadlessOnly) { $ok = $result.built_with_sdk -and $result.runtime_problem -eq "" -and $result.headless }
if (-not $HeadlessOnly -and -not $result.validation) { Write-Warning "--gpu-validation was not seen by the program" }
if ($ok) { Write-Host "PASS ($Out)"; exit 0 } else { Write-Host "FAIL ($Out)"; exit 1 }
