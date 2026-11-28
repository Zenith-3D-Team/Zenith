<#
.SYNOPSIS
Headless proof that Zenith loads and asks nothing of NVIDIA's DLSS (Streamline, NGX) before the player's OK for
NVIDIA's updater (alt/dlss-s7c), and that the same start with the OK does load Streamline (so the check can see it).

.DESCRIPTION
Starts Zenith headless and muted (no window, --audio-driver Dummy) on -Godot (Zenith's own build, which has the
engine hook) with --vendor-dir pointing at a folder holding nvidia/ (Zenith's Streamline build and NVIDIA's
nvngx_dlss.dll) and --upscaler=dlss, on a fresh settings file of its own (--settings-file; the player's is never
read), twice:
  1. no OK (the default): must load no sl.*.dll / nvngx*.dll / _nvngx.dll, start no nvngx_update.exe, and log
     "NVIDIA DLSS waits for the player's OK";
  2. --dlss-consent=yes: Streamline's sl.interposer.dll must be loaded (headless there is no device, so no slInit).
A watcher looks every 0.2 s at the Godot process's loaded modules and at every nvngx_update.exe on the PC (new ones,
with their parent). Never blocks, renames or touches NVIDIA's updater or driver. Logs and results go in -Out.

    powershell -ExecutionPolicy Bypass -File tools\dlss\consent_proof.ps1 -Godot <godot.exe> [-VendorDir <dir>] [-Out <dir>]
#>
param(
	[Parameter(Mandatory = $true)][string]$Godot,
	[string]$VendorDir = "",
	[string]$Out = "",
	[int]$QuitAfterFrames = 600,
	[int]$TimeoutSec = 180
)
$ErrorActionPreference = "Stop"

$Repo = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$Main = Split-Path -Parent (git -C $Repo rev-parse --path-format=absolute --git-common-dir)
if (-not $VendorDir) { $VendorDir = Join-Path $Main "art-src\vendor-runtimes" }
if (-not $Out) { $Out = Join-Path $Main "art-src\dlss-consent-proof" }
New-Item -ItemType Directory -Force $Out | Out-Null
foreach ($f in @("sl.interposer.dll", "sl.common.dll", "sl.dlss.dll", "zenith-sl-manifest.txt", "nvngx_dlss.dll")) {
	if (-not (Test-Path (Join-Path $VendorDir "nvidia\$f"))) { throw "missing $VendorDir\nvidia\$f" }
}
$Client = Join-Path $Repo "client"
$NvPattern = '^(sl\.(interposer|common|dlss)|nvngx_dlss|_nvngx|nvngx)\.dll$'

function Invoke-Run([string]$Name, [string[]]$Extra) {
	$settings = Join-Path $Out "$Name-settings.cfg"
	Remove-Item -LiteralPath $settings -ErrorAction SilentlyContinue
	$log = Join-Path $Out "$Name.log"
	$vendor = $VendorDir.Replace("\", "/")
	$argList = @("--headless", "--audio-driver", "Dummy", "--path", "`"$Client`"", "--log-file", "`"$log`"",
		"--quit-after", "$QuitAfterFrames", "--", "`"--vendor-dir=$vendor`"", "--upscaler=dlss",
		"`"--settings-file=$settings`"") + $Extra
	$before = @{}
	Get-CimInstance Win32_Process -Filter "Name='nvngx_update.exe'" | ForEach-Object { $before[$_.ProcessId] = $true }
	$p = Start-Process -FilePath $Godot -ArgumentList $argList -PassThru -WindowStyle Hidden `
		-RedirectStandardOutput (Join-Path $Out "$Name.out.txt") -RedirectStandardError (Join-Path $Out "$Name.err.txt")
	$modules = @{}
	$updaters = @{}
	$deadline = (Get-Date).AddSeconds($TimeoutSec)
	while (-not $p.HasExited -and (Get-Date) -lt $deadline) {
		try {
			(Get-Process -Id $p.Id -ErrorAction Stop).Modules | Where-Object { $_.ModuleName -match $NvPattern } |
				ForEach-Object { $modules[$_.ModuleName.ToLower()] = $_.FileName }
		} catch {}
		Get-CimInstance Win32_Process -Filter "Name='nvngx_update.exe'" | Where-Object { -not $before.ContainsKey($_.ProcessId) } |
			ForEach-Object { $updaters[$_.ProcessId] = "parent $($_.ParentProcessId) $($_.CommandLine)" }
		Start-Sleep -Milliseconds 200
	}
	$timedOut = -not $p.HasExited
	if ($timedOut) { Stop-Process -Id $p.Id }  # only the Godot this script started, by its PID
	$waits = [bool](Select-String -LiteralPath $log -Pattern "NVIDIA DLSS waits for the player's OK" -Quiet)
	$r = [ordered]@{
		run = $Name; pid = $p.Id; timed_out = $timedOut
		nvidia_modules = @($modules.Keys | Sort-Object)
		nvngx_update_started = @($updaters.Values)
		ours_parent = @($updaters.Values | Where-Object { $_ -match "^parent $($p.Id) " }).Count
		log_says_waits = $waits
	}
	return $r
}

$no = Invoke-Run "no-consent" @()
$yes = Invoke-Run "with-consent" @("--dlss-consent=yes")
$pass = (-not $no.timed_out) -and $no.nvidia_modules.Count -eq 0 -and $no.nvngx_update_started.Count -eq 0 -and $no.log_says_waits `
	-and (-not $yes.timed_out) -and ($yes.nvidia_modules -contains "sl.interposer.dll")
$result = [ordered]@{ pass = $pass; godot = (Split-Path -Leaf $Godot); no_consent = $no; with_consent = $yes }
$result | ConvertTo-Json -Depth 4 | Set-Content -Encoding utf8 (Join-Path $Out "result.json")
$result | ConvertTo-Json -Depth 4
if ($pass) { "PASS: nothing of NVIDIA's loaded or started before the OK; Streamline loads with it" } else { "FAIL (see $Out)" }
exit ([int](-not $pass))
