<#
.SYNOPSIS
The upscaler hook's window test (FSR 4 plan, step 2): Zenith's patched Godot on Direct3D 12 with its debug
layer, drawing through the do-nothing native upscaler (ZenithHookUpscaler), checked for zero debug-layer
errors and a picture that isn't black.

.DESCRIPTION
Exports tools/godot/hook_test (a tiny project, not Zenith) with the patched template from
tools/godot/build_template.ps1 and the upscalers DLL (client/native/upscalers/build.bat), then runs it:
in a window (unless -HeadlessOnly), muted, with --gpu-validation (the D3D12 debug layer) and its own log.
hook_test.gd draws Bilinear at scale 1.0, then the hook at 1.0 (must match) and at 0.5, then lets go.

Opens a window for about half a minute: run it only when nobody is using the PC. Needs Windows' optional
feature "Graphics Tools" for the debug layer (d3d12SDKLayers.dll); without it Godot can't start D3D12 with
--gpu-validation and the test says so.

    powershell -ExecutionPolicy Bypass -File tools\godot\hook_window_test.ps1 -Godot <Godot 4.7.2 editor exe>
        [-Template <windows_release_x86_64.exe>] [-Out <dir>] [-Frames 120] [-HeadlessOnly]

Exit 0 when every check passed; the result is <Out>\result.json, the log <Out>\godot.log, the pictures
<Out>\hook_*.png.
#>
param(
	[string]$Godot = $env:GODOT,
	[string]$Template = "",
	[string]$Out = "",
	[int]$Frames = 120,
	[int]$TimeoutSec = 240,
	[switch]$HeadlessOnly
)
$ErrorActionPreference = "Stop"

$Repo = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$Main = Split-Path -Parent (git -C $Repo rev-parse --path-format=absolute --git-common-dir)
if (-not $Template) { $Template = Join-Path $Main "art-src\godot-build\out\4.7.2\windows_release_x86_64.exe" }
if (-not $Out) { $Out = Join-Path $Main "art-src\hook-window-test" }
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
$exe = Join-Path $export "HookTest.exe"
$code = Invoke-Godot $Godot @("--headless", "--audio-driver", "Dummy", "--log-file", "`"$elog`"", "--path", "`"$proj`"",
	"--export-release", "`"Windows Desktop`"", "`"$exe`"") $elog
if ($code -or -not (Test-Path $exe)) { throw "export failed (exit $code), log $elog" }
if (-not (Test-Path (Join-Path $export "upscalers.windows.template_release.x86_64.dll"))) {
	Copy-Item $Dll $export  # the export normally copies it beside the program
}

# 3. Run it.
$log = Join-Path $Out "godot.log"
$argv = @("--audio-driver", "Dummy", "--log-file", "`"$log`"")
if ($HeadlessOnly) { $argv = @("--headless") + $argv }
else { $argv += @("--rendering-driver", "d3d12", "--gpu-validation") }
$argv += @("--", "--out=`"$Out`"", "--frames=$Frames")
$code = Invoke-Godot $exe $argv $log

# 4. Verdict: hook_test.gd's checks, and no D3D12 debug-layer errors in the log.
$resultFile = Join-Path $Out "result.json"
if (-not (Test-Path $resultFile)) { throw "no result.json (exit $code), log $log" }
$result = Get-Content $resultFile -Raw | ConvertFrom-Json
$lines = if (Test-Path $log) { Get-Content $log } else { @() }
$layerErrors = @($lines | Where-Object { $_ -match "^ERROR: .*Message Id Number" })
$layerWarnings = @($lines | Where-Object { $_ -match "^WARNING: .*Message Id Number" })
$errors = @($lines | Where-Object { $_ -match "^(ERROR|SCRIPT ERROR):" })
Write-Host ("driver {0}, hook in build {1}, active {2}, passed {3}" -f $result.driver, $result.hook_in_build, $result.hook_active, $result.passed)
Write-Host ("D3D12 debug layer: {0} error(s), {1} warning(s); {2} error line(s) in all" -f $layerErrors.Count, $layerWarnings.Count, $errors.Count)
foreach ($f in $result.failed) { Write-Host "  failed: $f" }
$layerErrors | Select-Object -First 10 | ForEach-Object { Write-Host "  $_" }
$ok = $result.passed -and $layerErrors.Count -eq 0 -and $code -eq 0
if ($HeadlessOnly) { $ok = $result.hook_in_build -and $result.headless }
if (-not $HeadlessOnly -and -not $result.validation) { Write-Warning "--gpu-validation was not seen by the program" }
if ($ok) { Write-Host "PASS ($Out)"; exit 0 } else { Write-Host "FAIL ($Out)"; exit 1 }
