# Cross-PC benchmark runner for Zenith 0.2.2 vs 0.3.0 across all graphics presets and looks.
# Runs identically on Windows PowerShell 5.1+ with zero external tools (no Python, Git, or Godot
# required when benchmarking packaged Zenith builds).
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\bench\run_matrix.ps1 `
#     -Build022 C:\Zenith-0.2.2-windows -Build030 C:\Zenith-0.3.0-windows -Save C:\Saves\ZenithTest.zip

param(
  [string]$Save = "",
  [string]$Build022 = "",
  [string]$Build030 = "",
  # More builds, each "label=path" (a folder or .zip), for example -Build "0.1.0=D:\Zenith-0.1.0-windows.zip","0.2.1=...".
  # Labels are versions: 0.3.0 and later get the new-style settings, earlier ones 0.2.2's. Builds before 0.1.4 have no
  # Cinematic look and no "bus" route: their Cinematic tests are skipped and "bus" runs their own laps route ("fast").
  # Extra client arguments for one build go after a "|": -Build "0.3.1-nounload=<path to the build>|--unload-fast=off"
  # (several, space-separated, are passed to that build's client after its other user args). A label only has to start
  # with a version (0.3.1-nounload counts as 0.3.0+) and stays its own column in results and reports.
  [string[]]$Build = @(),
  # Each case this many times, interleaved across builds (ids get _r1.._rN when above 1); the report shows each case's
  # median with its min-max spread, so a few ms of difference can be told from noise.
  [int]$Repeat = 1,
  [string]$Godot = "",
  [string]$Factorio = "",
  [string]$OutDir = "",
  [string]$PcName = $env:COMPUTERNAME,
  [ValidateSet("native", "matched")][string]$Mode = "native",
  [string[]]$Versions = @("0.2.2", "0.3.0"),
  [string[]]$Presets = @("low", "medium", "high", "ultra"),
  [string[]]$Looks = @("factorio", "cinematic"),
  [string[]]$Routes = @("stand", "bus"),
  [string]$Resolution = "",
  [int]$PortBase = 36300,
  [int]$Warmup = 15,
  [int]$ClientTimeoutSec = 360,
  [switch]$AltMode,
  [switch]$NoResume,
  [switch]$NoInterleave,
  [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$Inv = [System.Globalization.CultureInfo]::InvariantCulture
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# Canonical preset definitions per version for native and matched modes.
$Presets022Native = @{
  "low"    = @{ "shadows" = "low";    "ssao" = $false; "lod_quality" = "low";    "view_radius" = 5;  "entity_radius" = 96;  "belt_updates" = 2000; "belt_distance" = 64;  "decorative_distance" = 96;  "decorative_density" = 0.5;  "grass_3d" = "off";    "clouds" = $false; "contact_shading" = $true }
  "medium" = @{ "shadows" = "medium"; "ssao" = $false; "lod_quality" = "medium"; "view_radius" = 7;  "entity_radius" = 128; "belt_updates" = 4000; "belt_distance" = 96;  "decorative_distance" = 128; "decorative_density" = 0.75; "grass_3d" = "short";  "clouds" = $true;  "contact_shading" = $true }
  "high"   = @{ "shadows" = "high";   "ssao" = $true;  "lod_quality" = "medium"; "view_radius" = 10; "entity_radius" = 192; "belt_updates" = -1;   "belt_distance" = 160; "decorative_distance" = 192; "decorative_density" = 1.0;  "grass_3d" = "normal"; "clouds" = $true;  "contact_shading" = $true }
  "ultra"  = @{ "shadows" = "ultra";  "ssao" = $true;  "lod_quality" = "high";   "view_radius" = 14; "entity_radius" = 256; "belt_updates" = -1;   "belt_distance" = 320; "decorative_distance" = 256; "decorative_density" = 1.0;  "grass_3d" = "far";    "clouds" = $true;  "contact_shading" = $true }
}

$Presets030Native = @{
  "low"    = @{ "shadows" = "low";    "ssao" = $false; "lod_quality" = "low";    "view_radius" = 5;  "entity_radius" = 96;  "belt_updates" = 2000; "belt_distance" = 64;  "decorative_distance" = 96;  "decorative_density" = 0.5;  "grass_3d" = "off";    "clouds" = $false; "contact_shading" = $true; "god_rays" = 0.0 }
  "medium" = @{ "shadows" = "medium"; "ssao" = $false; "lod_quality" = "medium"; "view_radius" = 7;  "entity_radius" = 128; "belt_updates" = 4000; "belt_distance" = 96;  "decorative_distance" = 128; "decorative_density" = 0.75; "grass_3d" = "short";  "clouds" = $true;  "contact_shading" = $true; "god_rays" = 0.25 }
  "high"   = @{ "shadows" = "high";   "ssao" = $true;  "lod_quality" = "medium"; "view_radius" = 4;  "entity_radius" = 128; "belt_updates" = -1;   "belt_distance" = 128; "decorative_distance" = 192; "decorative_density" = 1.0;  "grass_3d" = "normal"; "clouds" = $true;  "contact_shading" = $true; "god_rays" = 0.5 }
  "ultra"  = @{ "shadows" = "ultra";  "ssao" = $true;  "lod_quality" = "high";   "view_radius" = 14; "entity_radius" = 256; "belt_updates" = -1;   "belt_distance" = 320; "decorative_distance" = 256; "decorative_density" = 1.0;  "grass_3d" = "far";    "clouds" = $true;  "contact_shading" = $true; "god_rays" = 0.5 }
}

$PresetsMatched = $Presets022Native

function ConvertTo-VersionKey {
  param([string]$V)
  $m = [regex]::Match($V, '(\d+)\.(\d+)\.(\d+)')
  if ($m.Success) { return [version]("{0}.{1}.{2}" -f $m.Groups[1].Value, $m.Groups[2].Value, $m.Groups[3].Value) }
  return [version]"999.0.0"
}
# 0.3.0 and later: render scale, FSR 2.2 and the distant horizon in native mode, and 0.3.0's presets.
function Test-NewStyle { param([string]$V) return (ConvertTo-VersionKey $V) -ge [version]"0.3.0" }
# The Cinematic shaders add-on and the probe's "bus" route arrived in 0.1.4.
function Test-HasBusAndCinematic { param([string]$V) return (ConvertTo-VersionKey $V) -ge [version]"0.1.4" }

function Write-Utf8NoBom {
  param([string]$Path, [string]$Content)
  $parent = Split-Path $Path -Parent
  if ($parent -and -not (Test-Path $parent)) {
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
  }
  [System.IO.File]::WriteAllText($Path, $Content, $Utf8NoBom)
}

function Format-CfgValue {
  param($Val)
  if ($Val -is [bool]) {
    if ($Val) { return "true" } else { return "false" }
  }
  if ($Val -is [int] -or $Val -is [long]) {
    return ([long]$Val).ToString($Inv)
  }
  if ($Val -is [double] -or $Val -is [float] -or $Val -is [decimal]) {
    $d = [double]$Val
    $s = $d.ToString("0.######", $Inv)
    if ($s.IndexOf(".") -lt 0) { $s = $s + ".0" }
    return $s
  }
  $escaped = ([string]$Val).Replace("\", "\\").Replace('"', '\"')
  return '"' + $escaped + '"'
}

function Format-InvNum {
  param($Val, [int]$Decimals = 2)
  if ($null -eq $Val) { return "" }
  $d = [double]$Val
  if ([double]::IsNaN($d) -or [double]::IsInfinity($d)) { return "" }
  if ($Decimals -le 0) {
    return ([math]::Round($d)).ToString("0", $Inv)
  }
  $fmt = "0." + ("0" * $Decimals)
  return $d.ToString($fmt, $Inv)
}

function Format-WinArg {
  param([string]$Arg)
  if ($Arg -eq "") { return '""' }
  if ($Arg -notmatch '[\s"]') { return $Arg }
  $escaped = $Arg.Replace('"', '\"')
  return '"' + $escaped + '"'
}

function Format-WinArgsLine {
  param([string[]]$ArgList)
  $parts = @()
  foreach ($a in $ArgList) {
    $parts += (Format-WinArg $a)
  }
  return ($parts -join " ")
}

function Get-Percentile {
  param([double[]]$Values, [double]$P)
  if ($null -eq $Values -or $Values.Count -eq 0) { return $null }
  $sorted = @($Values | Sort-Object)
  $idx = [int][math]::Ceiling($P * $sorted.Count) - 1
  if ($idx -lt 0) { $idx = 0 }
  if ($idx -ge $sorted.Count) { $idx = $sorted.Count - 1 }
  return [double]$sorted[$idx]
}

function Escape-CsvCell {
  param([string]$Text)
  if ($null -eq $Text) { return "" }
  if ($Text -match '[,"\r\n]') {
    return '"' + $Text.Replace('"', '""') + '"'
  }
  return $Text
}

function Test-UdpPortFree {
  param([int]$Port)
  $udp = $null
  try {
    $ep = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Loopback, $Port)
    $udp = New-Object System.Net.Sockets.UdpClient($ep)
    return $true
  } catch {
    return $false
  } finally {
    if ($null -ne $udp) { $udp.Close() }
  }
}

function Read-ExactBytes {
  param($Stream, [int]$Count)
  $buf = New-Object byte[] $Count
  $offset = 0
  while ($offset -lt $Count) {
    $n = $Stream.Read($buf, $offset, $Count - $offset)
    if ($n -le 0) { throw "RCON connection closed unexpectedly" }
    $offset += $n
  }
  return $buf
}

function New-RconPacketBytes {
  param([int32]$ReqId, [int32]$Kind, [string]$Body)
  $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
  $payloadLen = 4 + 4 + $bodyBytes.Length + 2
  $out = New-Object byte[] (4 + $payloadLen)
  [Array]::Copy([BitConverter]::GetBytes([int32]$payloadLen), 0, $out, 0, 4)
  [Array]::Copy([BitConverter]::GetBytes([int32]$ReqId), 0, $out, 4, 4)
  [Array]::Copy([BitConverter]::GetBytes([int32]$Kind), 0, $out, 8, 4)
  if ($bodyBytes.Length -gt 0) {
    [Array]::Copy($bodyBytes, 0, $out, 12, $bodyBytes.Length)
  }
  return $out
}

function Read-RconPacket {
  param($Stream)
  $lenBytes = Read-ExactBytes $Stream 4
  $size = [BitConverter]::ToInt32($lenBytes, 0)
  if ($size -lt 10 -or $size -gt 1048576) {
    throw "Invalid RCON packet length: $size"
  }
  $data = Read-ExactBytes $Stream $size
  $reqId = [BitConverter]::ToInt32($data, 0)
  $kind = [BitConverter]::ToInt32($data, 4)
  $bodyLen = $size - 10
  $body = ""
  if ($bodyLen -gt 0) {
    $body = [System.Text.Encoding]::UTF8.GetString($data, 8, $bodyLen)
  }
  return @{ "req_id" = $reqId; "kind" = $kind; "body" = $body }
}

function Send-FactorioRcon {
  param(
    [string]$HostAddr = "127.0.0.1",
    [int]$Port,
    [string]$Password,
    [string]$Command,
    [int]$TimeoutMs = 5000
  )
  $client = New-Object System.Net.Sockets.TcpClient
  try {
    $iar = $client.BeginConnect($HostAddr, $Port, $null, $null)
    if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) {
      throw "RCON connect timeout on $HostAddr`:$Port"
    }
    $client.EndConnect($iar)
    $client.ReceiveTimeout = $TimeoutMs
    $client.SendTimeout = $TimeoutMs
    $stream = $client.GetStream()
    $auth = New-RconPacketBytes 1 3 $Password
    $stream.Write($auth, 0, $auth.Length)
    $stream.Flush()
    while ($true) {
      $pkt = Read-RconPacket $stream
      if ($pkt.kind -eq 2) {
        if ($pkt.req_id -eq -1) { throw "RCON password rejected" }
        break
      }
    }
    $exec = New-RconPacketBytes 2 2 $Command
    $stream.Write($exec, 0, $exec.Length)
    $stream.Flush()
    $reply = Read-RconPacket $stream
    return $reply.body
  } finally {
    $client.Close()
  }
}

function Find-DefaultBuildPath {
  param([string]$Version)
  $patterns = @("Zenith-$Version*", "Zenith*$Version*")
  $searchRoots = @($PSScriptRoot, (Get-Location).Path)
  foreach ($root in $searchRoots) {
    foreach ($pat in $patterns) {
      $dirs = @(Get-ChildItem -Path $root -Directory -Filter $pat -ErrorAction SilentlyContinue | Sort-Object Name)
      foreach ($d in $dirs) {
        if (Test-Path (Join-Path $d.FullName "Zenith.exe")) { return $d.FullName }
      }
    }
    foreach ($pat in $patterns) {
      $zips = @(Get-ChildItem -Path $root -File -Filter ($pat + ".zip") -ErrorAction SilentlyContinue | Sort-Object Name)
      if ($zips.Count -gt 0) { return $zips[0].FullName }
    }
  }
  $repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
  if ($Version -eq "0.3.0" -and (Test-Path (Join-Path $repoRoot "client\project.godot"))) {
    return $repoRoot
  }
  return ""
}

function Resolve-ZenithBuild {
  param([string]$Version, [string]$Spec, [string]$WorkBuildsDir, [string]$GodotExe, [switch]$NoExtract)
  $chosen = $Spec
  if ($chosen -eq "") {
    $chosen = Find-DefaultBuildPath -Version $Version
  }
  if ($chosen -eq "") {
    throw "Could not find Zenith $Version build. Pass -Build022 / -Build030."
  }
  if (-not (Test-Path $chosen)) {
    throw "Zenith $Version path does not exist: $chosen"
  }
  $resolved = (Resolve-Path $chosen).Path
  $item = Get-Item $resolved
  $buildDir = $resolved
  $sourceSpec = $resolved

  if (-not $item.PSIsContainer) {
    if ($item.Extension.ToLowerInvariant() -ne ".zip") {
      throw "Zenith $Version path must be a folder or .zip: $resolved"
    }
    if ($NoExtract) {
      return [ordered]@{
        "version"    = $Version
        "kind"       = "zip-pending"
        "spec"       = $sourceSpec
        "dir"        = $resolved
        "exe"        = ""
        "server_dir" = ""
        "addon_arg"  = ""
      }
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $dest = Join-Path $WorkBuildsDir $item.BaseName
    $stampFile = Join-Path $dest ".bench-extracted.txt"
    $stamp = "$($item.Length)-$($item.LastWriteTimeUtc.Ticks)"
    $needExtract = $true
    if ((Test-Path $stampFile) -and ((Get-Content -Raw $stampFile).Trim() -eq $stamp)) {
      $needExtract = $false
    }
    if ($needExtract) {
      if (Test-Path $dest) {
        Remove-Item -Path $dest -Recurse -Force
      }
      New-Item -ItemType Directory -Force -Path $dest | Out-Null
      Write-Host "Extracting $resolved -> $dest ..."
      [System.IO.Compression.ZipFile]::ExtractToDirectory($resolved, $dest)
      Write-Utf8NoBom -Path $stampFile -Content $stamp
    }
    if (Test-Path (Join-Path $dest "Zenith.exe")) {
      $buildDir = $dest
    } else {
      $inner = Get-ChildItem -Path $dest -Directory | Where-Object { Test-Path (Join-Path $_.FullName "Zenith.exe") } | Select-Object -First 1
      if ($null -eq $inner) {
        throw "Extracted zip $resolved does not contain Zenith.exe"
      }
      $buildDir = $inner.FullName
    }
  }

  $exePath = Join-Path $buildDir "Zenith.exe"
  $projPath = Join-Path $buildDir "client\project.godot"
  $kind = ""
  $clientExe = ""
  if (Test-Path $exePath) {
    $kind = "packaged"
    $clientExe = $exePath
  } elseif (Test-Path $projPath) {
    $kind = "checkout"
    if ($GodotExe -ne "") {
      if (-not (Test-Path $GodotExe)) { throw "Specified -Godot not found: $GodotExe" }
      $clientExe = (Resolve-Path $GodotExe).Path
    } else {
      $cmd = Get-Command godot -ErrorAction SilentlyContinue
      if ($null -eq $cmd) {
        throw "Zenith $Version is a source checkout ($buildDir); pass -Godot <path-to-godot.exe>."
      }
      $clientExe = $cmd.Source
    }
  } else {
    throw "Directory is neither a packaged Zenith build (Zenith.exe) nor a checkout (client\project.godot): $buildDir"
  }

  $serverDir = Join-Path $buildDir "server"
  if (-not (Test-Path (Join-Path $serverDir "run-server.ps1"))) {
    throw "Missing server\run-server.ps1 under $buildDir"
  }

  # Detect whether Cinematic Shaders is bundled or must be supplied from addons-src.
  $addonArg = ""
  $bundledAddons = Join-Path $buildDir "addons"
  $hasBundledCinematic = $false
  if (Test-Path $bundledAddons) {
    $matches = @(Get-ChildItem -Path $bundledAddons -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "cinematic-shaders*" })
    if ($matches.Count -gt 0) { $hasBundledCinematic = $true }
  }
  if (-not $hasBundledCinematic) {
    $srcAddon = Join-Path $buildDir "addons-src\cinematic-shaders"
    if (Test-Path (Join-Path $srcAddon "addon.json")) {
      $addonArg = "--addons=" + $srcAddon
    }
  }

  return [ordered]@{
    "version"    = $Version
    "kind"       = $kind
    "spec"       = $sourceSpec
    "dir"        = $buildDir
    "exe"        = $clientExe
    "server_dir" = $serverDir
    "addon_arg"  = $addonArg
  }
}

function Resolve-SaveFile {
  param([string]$Spec)
  if ($Spec -ne "") {
    if (-not (Test-Path $Spec)) { throw "Save file not found: $Spec" }
    return (Resolve-Path $Spec).Path
  }
  $candidates = @(
    (Join-Path $PSScriptRoot "Zenith Test.zip"),
    (Join-Path (Get-Location).Path "Zenith Test.zip"),
    (Join-Path $env:APPDATA "Factorio\saves\Zenith Test.zip")
  )
  foreach ($c in $candidates) {
    if (Test-Path $c) { return (Resolve-Path $c).Path }
  }
  throw "Could not find save file. Pass -Save <path-to-save.zip>."
}

function Get-PcInfo {
  $cpu = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
  $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue | Select-Object -First 1
  $gpus = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue)
  $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue | Select-Object -First 1

  $gpuChosen = $null
  foreach ($g in $gpus) {
    $n = [string]$g.Name
    if ($n -match "NVIDIA|GeForce|RTX|GTX|Radeon RX|Arc ") {
      $gpuChosen = $g
      break
    }
  }
  if ($null -eq $gpuChosen -and $gpus.Count -gt 0) {
    $gpuChosen = $gpus[0]
  }

  $screenStr = "?"
  if ($null -ne $gpuChosen -and $gpuChosen.CurrentHorizontalResolution -gt 0 -and $gpuChosen.CurrentVerticalResolution -gt 0) {
    $hz = if ($gpuChosen.CurrentRefreshRate -gt 0) { "$($gpuChosen.CurrentRefreshRate) Hz" } else { "? Hz" }
    $screenStr = "$($gpuChosen.CurrentHorizontalResolution)x$($gpuChosen.CurrentVerticalResolution) @ $hz"
  }

  $ramGb = if ($null -ne $cs -and $cs.TotalPhysicalMemory -gt 0) {
    [math]::Round([double]$cs.TotalPhysicalMemory / 1073741824.0)
  } else { 0 }

  $cpuName = if ($null -ne $cpu) { ([string]$cpu.Name).Trim() } else { "?" }
  $threads = if ($null -ne $cpu) { [int]$cpu.NumberOfLogicalProcessors } else { 0 }
  $gpuName = if ($null -ne $gpuChosen) { ([string]$gpuChosen.Name).Trim() } else { "?" }
  $gpuDriver = if ($null -ne $gpuChosen) { ([string]$gpuChosen.DriverVersion).Trim() } else { "?" }
  $osName = if ($null -ne $os) { "$([string]$os.Caption) ($([string]$os.Version))".Trim() } else { "?" }

  return [ordered]@{
    "pc_name"     = $PcName
    "cpu"         = $cpuName
    "cpu_threads" = $threads
    "ram_gb"      = [int]$ramGb
    "gpu"         = $gpuName
    "gpu_driver"  = $gpuDriver
    "screen"      = $screenStr
    "os"          = $osName
  }
}

function Build-TestSettingsText {
  param(
    [string]$Version,
    [string]$Preset,
    [string]$Look,
    [string]$BenchMode,
    [string]$TargetResolution,
    [bool]$UseAltMode
  )
  if ($BenchMode -eq "matched") {
    $presetMap = $PresetsMatched
  } elseif (-not (Test-NewStyle $Version)) {
    $presetMap = $Presets022Native
  } else {
    $presetMap = $Presets030Native
  }
  $p = $presetMap[$Preset]
  if ($null -eq $p) { throw "Unknown preset '$Preset' for version '$Version' ($BenchMode)" }

  $graphics = [ordered]@{
    "window_mode"          = "borderless"
    "resolution"           = $TargetResolution
    "screen"               = -1
    "minimize_on_focus_loss" = $false
    "vsync"                = $false
    "fps_cap"              = 0
    "antialiasing"         = "smaa"
    "look"                 = "factorio"
    "look_before"          = "factorio"
    "hold_ups"             = $false
    "render_thread"        = $false
    "merged_materials"     = $false
    "merge_far"            = $true
    "far_lights"           = $true
    "decoratives"          = $true
    "effects"              = $true
    "item_icons"           = $true
    "item_models_max"      = 20500
    "belt_smooth"          = $true
    "brightness"           = 1.0
    "contrast"             = 1.0
  }

  if ($BenchMode -eq "native" -and (Test-NewStyle $Version)) {
    $graphics["render_scale"]            = 0.8
    $graphics["upscaler"]                = "fsr2"
    $graphics["upscaler_sharpness"]      = 0.575
    $graphics["distant_horizon"]         = 96
    $graphics["distant_horizon_manual"]  = $true
    $graphics["distant_horizon_quality"] = "medium"
    $graphics["distant_horizon_dropoff"] = "balanced"
    $graphics["distant_horizon_glow"]    = $true
    $graphics["distant_horizon_shots"]   = $true
    $graphics["chunk_disk_cache"]        = $true
    $graphics["saturation"]              = 1.25
  } else {
    $graphics["render_scale"]            = 1.0
    $graphics["saturation"]              = 1.0
    if (Test-NewStyle $Version) {
      $graphics["upscaler"]                = "fsr1"
      $graphics["upscaler_sharpness"]      = 0.575
      $graphics["distant_horizon"]         = 0
      $graphics["distant_horizon_manual"]  = $true
      $graphics["god_rays"]                = 0.0
      $graphics["chunk_disk_cache"]        = $true
    }
  }

  foreach ($k in ($p.Keys | Sort-Object)) {
    $graphics[$k] = $p[$k]
  }
  if ($BenchMode -eq "matched" -and $graphics.Contains("god_rays")) {
    $graphics["god_rays"] = 0.0
  }

  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add("[meta]")
  $lines.Add("ssao_off=true")
  $lines.Add("belt_auto=true")
  $lines.Add("mod_anim_off=true")
  $lines.Add("full_screen_resolution=true")
  $lines.Add("grass_preset=true")
  $lines.Add("addons_off_by_default=true")
  $lines.Add("migrated=true")
  $lines.Add("dual_distance_migrated=true")
  $lines.Add("")
  $lines.Add("[graphics]")
  foreach ($k in $graphics.Keys) {
    $lines.Add("$k=$(Format-CfgValue $graphics[$k])")
  }
  $lines.Add("")
  $lines.Add("[sound]")
  $lines.Add("master=0.0")
  $lines.Add("")
  $lines.Add("[interface]")
  $lines.Add("show_help=false")
  $lines.Add("debug_overlay=false")
  $lines.Add("alt_mode=$(Format-CfgValue $UseAltMode)")
  $lines.Add("")
  $lines.Add("[factorio]")
  $lines.Add("use_factorio_keys=false")
  $lines.Add("use_factorio_settings=false")
  $lines.Add("")
  $lines.Add("[addons]")
  $cinematicOn = ($Look -eq "cinematic")
  $lines.Add("cinematic-shaders=$(Format-CfgValue $cinematicOn)")
  $lines.Add("cinematic-camera=false")
  $lines.Add("terrain-elevation=false")
  $lines.Add("immersive-weather=false")
  $lines.Add("")
  return ($lines -join "`n")
}

function Stop-BuildServer {
  param($Build, [int]$RconPort)
  $serverData = Join-Path $Build.server_dir "data"
  $pwFile = Join-Path $serverData "rcon-password.txt"
  if (Test-Path $pwFile) {
    try {
      $pw = (Get-Content -Raw $pwFile).Trim()
      if ($pw -ne "") {
        $null = Send-FactorioRcon -Port $RconPort -Password $pw -Command "/quit" -TimeoutMs 3000
      }
    } catch {
      # Server might not be running yet; fall through cleanly.
    }
  }
  Start-Sleep -Seconds 4
  $procs = @(Get-CimInstance Win32_Process -Filter "Name='factorio.exe'" -ErrorAction SilentlyContinue | Where-Object {
    $_.CommandLine -and $_.CommandLine -like "*$serverData*"
  })
  foreach ($pr in $procs) {
    try {
      Stop-Process -Id $pr.ProcessId -Force -ErrorAction SilentlyContinue
    } catch {}
  }
  if ($procs.Count -gt 0) {
    Start-Sleep -Seconds 2
  }
}

function Start-BuildServer {
  param($Build, [string]$SrcSave, [string]$ScratchSave, [int]$UdpPort, [int]$GamePort, [int]$RconPort, [string]$FactorioExe)
  $serverData = Join-Path $Build.server_dir "data"
  $logFile = Join-Path $serverData "factorio-current.log"
  if (Test-Path $logFile) {
    Remove-Item -Path $logFile -Force -ErrorAction SilentlyContinue
  }
  $scratchParent = Split-Path $ScratchSave -Parent
  if (-not (Test-Path $scratchParent)) {
    New-Item -ItemType Directory -Force -Path $scratchParent | Out-Null
  }
  Copy-Item -Path $SrcSave -Destination $ScratchSave -Force

  $runServerPs1 = Join-Path $Build.server_dir "run-server.ps1"
  $psArgs = @(
    "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $runServerPs1,
    "-Save", $ScratchSave,
    "-UdpPort", "$UdpPort",
    "-GamePort", "$GamePort",
    "-RconPort", "$RconPort"
  )
  if ($FactorioExe -ne "") {
    $psArgs += @("-Factorio", $FactorioExe)
  }

  $launcherProc = Start-Process -FilePath "powershell.exe" -ArgumentList (Format-WinArgsLine $psArgs) -WindowStyle Hidden -PassThru
  $deadline = (Get-Date).AddSeconds(180)
  while ((Get-Date) -lt $deadline) {
    if (Test-Path $logFile) {
      # Factorio keeps its log open for writing: ReadAllText's read-only share is refused while it runs.
      $text = ""
      try {
        $fs = [System.IO.File]::Open($logFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $sr = New-Object System.IO.StreamReader($fs)
        $text = $sr.ReadToEnd()
        $sr.Close()
      } catch { $text = "" }
      if ($text -match "Opening socket" -and $text -match "Starting RCON") {
        Start-Sleep -Seconds 3
        $fVer = "?"
        $mVer = [regex]::Match($text, "Factorio\s+(\d+\.\d+\.\d+)")
        if ($mVer.Success) { $fVer = $mVer.Groups[1].Value }
        $hasSa = ($text -match "Loading mod space-age")
        return @{ "factorio_version" = $fVer; "space_age" = $hasSa }
      }
    }
    if ($launcherProc.HasExited -and $launcherProc.ExitCode -ne 0) {
      throw "run-server.ps1 exited with code $($launcherProc.ExitCode); check $logFile"
    }
    Start-Sleep -Seconds 2
  }
  throw "Headless Factorio failed to open socket/RCON within 180 s; see $logFile"
}

function Parse-TestMetrics {
  param(
    [string]$RunDir,
    [string]$TestId,
    [hashtable]$Meta,
    [int]$ClientExitCode,
    [double]$DurationSec
  )
  $probePath = Join-Path $RunDir "probe.json"
  $godotLog = Join-Path $RunDir "godot.log"
  $factorioLog = Join-Path $RunDir "factorio.log"

  $row = [ordered]@{
    "id"              = $TestId
    "version"         = $Meta.version
    "preset"          = $Meta.preset
    "look"            = $Meta.look
    "route"           = $Meta.route
    "run"             = $(if ($Meta.ContainsKey("run")) { [int]$Meta.run } else { 1 })
    "mode"            = $Meta.mode
    "ok"              = $false
    "error"           = ""
    "frames"          = $null
    "fps_p50"         = $null
    "p50"             = $null
    "p99"             = $null
    "worst"           = $null
    "over16"          = $null
    "over33"          = $null
    "over50"          = $null
    "gpu_p50"         = $null
    "gpu_p99"         = $null
    "render_cpu_p50"  = $null
    "process_p50"     = $null
    "process_p99"     = $null
    "draw_calls_p50"  = $null
    "primitives_p50"  = $null
    "load_p50"        = $null
    "load_worst"      = $null
    "ups"             = $null
    "bridge_avg"      = $null
    "bridge_p99"      = $null
    "bridge_worst"    = $null
    "bridge_over_16"  = $null
    "belt_items_avg"  = $null
    "belt_items_p99"  = $null
    "served_ticks"    = 0
    "godot_errors"    = 0
    "script_errors"   = 0
    "seconds"         = [math]::Round($DurationSec, 1)
  }

  if (Test-Path $godotLog) {
    $errCount = 0
    $scrCount = 0
    foreach ($line in [System.IO.File]::ReadLines($godotLog)) {
      if ($line -match "SCRIPT ERROR" -or $line -match "ERROR:") {
        $errCount += 1
        if ($line -match "SCRIPT ERROR") { $scrCount += 1 }
      }
    }
    $row["godot_errors"] = $errCount
    $row["script_errors"] = $scrCount
  }

  if ($ClientExitCode -ne 0) {
    $row["error"] = "Client exited with code $ClientExitCode"
  } elseif (-not (Test-Path $probePath)) {
    $row["error"] = "Missing probe.json"
  } else {
    $probe = (Get-Content -Raw $probePath) | ConvertFrom-Json
    $walk = $probe.summary.walk
    $load = $probe.summary.load
    if ($null -ne $walk -and $null -ne $walk.p50) {
      $p50 = [double]$walk.p50
      $row["frames"]         = [int]$walk.frames
      $row["p50"]            = [math]::Round($p50, 3)
      $row["fps_p50"]        = if ($p50 -gt 0.0) { [math]::Round(1000.0 / $p50, 1) } else { $null }
      $row["p99"]            = [math]::Round([double]$walk.p99, 3)
      $row["worst"]          = [math]::Round([double]$walk.worst, 3)
      $row["over16"]         = [int]$walk.over16
      $row["over33"]         = [int]$walk.over33
      $row["over50"]         = [int]$walk.over50
      $row["gpu_p50"]        = if ([double]$walk.gpu_p50 -ge 0) { [math]::Round([double]$walk.gpu_p50, 2) } else { $null }
      $row["gpu_p99"]        = if ([double]$walk.gpu_p99 -ge 0) { [math]::Round([double]$walk.gpu_p99, 2) } else { $null }
      $row["render_cpu_p50"] = if ([double]$walk.render_cpu_p50 -ge 0) { [math]::Round([double]$walk.render_cpu_p50, 2) } else { $null }
      $row["process_p50"]    = [math]::Round([double]$walk.process_p50, 2)
      $row["process_p99"]    = [math]::Round([double]$walk.process_p99, 2)
      $row["draw_calls_p50"] = [int]$walk.draw_calls_p50
      $row["primitives_p50"] = [int64]$walk.primitives_p50
      if ($null -ne $load) {
        $row["load_p50"]   = [math]::Round([double]$load.p50, 3)
        $row["load_worst"] = [math]::Round([double]$load.worst, 3)
      }
      $row["ok"] = $true
    } else {
      $row["error"] = "probe.json missing summary.walk"
    }
  }

  if (Test-Path $factorioLog) {
    $ticks = @{}
    $stamps = @{}
    $rx = New-Object System.Text.RegularExpressions.Regex('^\s*([\d.]+)\s+.*f3dtrace\s+(\d+)\s+(\S+)\s+Duration:\s*([\d.]+)\s*ms')
    foreach ($line in [System.IO.File]::ReadLines($factorioLog)) {
      $m = $rx.Match($line)
      if ($m.Success) {
        $ts = [double]::Parse($m.Groups[1].Value, $Inv)
        $tk = [int64]$m.Groups[2].Value
        $mod = $m.Groups[3].Value
        $dur = [double]::Parse($m.Groups[4].Value, $Inv)
        if (-not $ticks.ContainsKey($tk)) { $ticks[$tk] = @{} }
        $ticks[$tk][$mod] = $dur
        $stamps[$tk] = $ts
      }
    }
    $served = New-Object System.Collections.Generic.List[int64]
    foreach ($tk in ($ticks.Keys | Sort-Object)) {
      $d = $ticks[$tk]
      if ($d.ContainsKey("belt_items") -or $d.ContainsKey("movers")) {
        $served.Add($tk)
      }
    }
    $row["served_ticks"] = $served.Count
    if ($served.Count -gt 0) {
      $bridgeVals = New-Object System.Collections.Generic.List[double]
      $beltVals = New-Object System.Collections.Generic.List[double]
      $over16 = 0
      foreach ($tk in $served) {
        $d = $ticks[$tk]
        $bv = if ($d.ContainsKey("bridge")) { [double]$d["bridge"] } else { 0.0 }
        $bridgeVals.Add($bv)
        if ($bv -gt 16.7) { $over16 += 1 }
        $iv = if ($d.ContainsKey("belt_items")) { [double]$d["belt_items"] } else { 0.0 }
        $beltVals.Add($iv)
      }
      $minT = $served[0]
      $maxT = $served[$served.Count - 1]
      $span = [double]$stamps[$maxT] - [double]$stamps[$minT]
      if ($served.Count -gt 1 -and $span -gt 0.0) {
        $row["ups"] = [math]::Round(($maxT - $minT) / $span, 2)
      }
      $bArr = $bridgeVals.ToArray()
      $iArr = $beltVals.ToArray()
      $row["bridge_avg"] = [math]::Round((($bArr | Measure-Object -Average).Average), 3)
      $row["bridge_p99"] = [math]::Round((Get-Percentile $bArr 0.99), 3)
      $row["bridge_worst"] = [math]::Round((($bArr | Measure-Object -Maximum).Maximum), 3)
      $row["bridge_over_16"] = $over16
      $row["belt_items_avg"] = [math]::Round((($iArr | Measure-Object -Average).Average), 3)
      $row["belt_items_p99"] = [math]::Round((Get-Percentile $iArr 0.99), 3)
    }
  }

  return $row
}

function Write-ModeOutputs {
  param([string]$ModeDir, [hashtable]$PcInfo, [hashtable]$RunConfig, [object[]]$Rows)
  $payload = [ordered]@{
    "schema_version" = 1
    "pc_info"        = $PcInfo
    "run_config"     = $RunConfig
    "tests"          = @($Rows)
  }
  $jsonPath = Join-Path $ModeDir "results.json"
  Write-Utf8NoBom -Path $jsonPath -Content ($payload | ConvertTo-Json -Depth 10)

  # CSV
  $cols = @("pc_name", "mode", "version", "run", "preset", "look", "route", "ok", "fps_p50", "p50", "p99", "worst",
    "over16", "over33", "over50", "frames", "gpu_p50", "gpu_p99", "render_cpu_p50", "process_p50", "process_p99",
    "draw_calls_p50", "primitives_p50", "load_p50", "load_worst", "ups", "bridge_avg", "bridge_p99",
    "bridge_worst", "bridge_over_16", "belt_items_avg", "belt_items_p99", "served_ticks", "godot_errors",
    "script_errors", "seconds", "error")
  $csvLines = New-Object System.Collections.Generic.List[string]
  $csvLines.Add(($cols -join ","))
  foreach ($r in $Rows) {
    $cells = New-Object System.Collections.Generic.List[string]
    foreach ($c in $cols) {
      if ($c -eq "pc_name") {
        $cells.Add((Escape-CsvCell $PcInfo.pc_name))
        continue
      }
      $v = $r[$c]
      if ($null -eq $v) {
        $cells.Add("")
      } elseif ($v -is [bool]) {
        $cells.Add((Format-CfgValue $v))
      } elseif ($v -is [double] -or $v -is [float] -or $v -is [decimal]) {
        $cells.Add(([double]$v).ToString("0.###", $Inv))
      } elseif ($v -is [int] -or $v -is [int64] -or $v -is [long]) {
        $cells.Add(([int64]$v).ToString($Inv))
      } else {
        $cells.Add((Escape-CsvCell ([string]$v)))
      }
    }
    $csvLines.Add(($cells -join ","))
  }
  Write-Utf8NoBom -Path (Join-Path $ModeDir "results.csv") -Content ($csvLines -join "`n")

  # Markdown report
  $md = New-Object System.Collections.Generic.List[string]
  $md.Add("# Zenith Cross-PC Benchmark Report - $($PcInfo.pc_name) ($($RunConfig.mode) mode)")
  $md.Add("")
  $md.Add("- **PC:** $($PcInfo.pc_name) | **CPU:** $($PcInfo.cpu) ($($PcInfo.cpu_threads) threads) | **RAM:** $($PcInfo.ram_gb) GB")
  $md.Add("- **GPU:** $($PcInfo.gpu) (driver $($PcInfo.gpu_driver)) | **Screen:** $($PcInfo.screen) | **OS:** $($PcInfo.os)")
  $md.Add("- **Factorio:** $($RunConfig.factorio_version) (Space Age: $($RunConfig.space_age)) | **Save SHA-12:** ``$($RunConfig.save_sha12)``")
  $md.Add("- **Options:** mode=``$($RunConfig.mode)``, resolution=``$(if ($RunConfig.resolution -ne '') { $RunConfig.resolution } else { 'native' })``, alt_mode=``$($RunConfig.alt_mode)``, warmup=$($RunConfig.warmup)s")
  $md.Add("")

  # One row per case: with repeats, the median of each metric over the ok runs (spread kept for the table below).
  $groups = [ordered]@{}
  foreach ($r in $Rows) {
    $k = "$($r.version)|$($r.preset)|$($r.look)|$($r.route)"
    if (-not $groups.Contains($k)) { $groups[$k] = New-Object System.Collections.Generic.List[object] }
    $groups[$k].Add($r)
  }
  $metricKeys = @("fps_p50", "p50", "p99", "worst", "over16", "over33", "over50", "gpu_p50", "gpu_p99", "render_cpu_p50",
    "process_p50", "process_p99", "draw_calls_p50", "ups", "bridge_avg", "bridge_p99")
  $lookup = @{}
  $medRows = New-Object System.Collections.Generic.List[object]
  foreach ($k in $groups.Keys) {
    $g = $groups[$k]
    $okRows = @($g | Where-Object { $_.ok })
    if ($okRows.Count -le 1) { $m = $(if ($okRows.Count -eq 1) { $okRows[0] } else { $g[0] }) }
    else {
      $m = [ordered]@{}
      foreach ($prop in $okRows[0].Keys) { $m[$prop] = $okRows[0][$prop] }
      foreach ($mk in $metricKeys) {
        $vals = @($okRows | Where-Object { $null -ne $_[$mk] } | ForEach-Object { [double]$_[$mk] })
        if ($vals.Count -gt 0) { $m[$mk] = [math]::Round((Get-Percentile $vals 0.5), 3) }
      }
    }
    $lookup[$k] = $m
    $medRows.Add([pscustomobject]@{ "key" = $k; "row" = $m; "runs" = $g.Count; "ok_runs" = $okRows.Count; "ok_rows" = $okRows })
  }

  $presentVersions = @($Versions)
  if ($presentVersions -contains "0.2.2" -and $presentVersions -contains "0.3.0") {
    $md.Add("## 0.2.2 vs 0.3.0 Side-by-Side")
    $md.Add("")
    foreach ($rt in $Routes) {
      $md.Add("### Route: ``$rt``")
      $md.Add("")
      $md.Add("| Preset | Look | 0.2.2 FPS (p50) | 0.3.0 FPS (p50) | FPS Delta | 0.2.2 p99 | 0.3.0 p99 | 0.2.2 GPU p50 | 0.3.0 GPU p50 | 0.2.2 UPS | 0.3.0 UPS | 0.2.2 Bridge | 0.3.0 Bridge |")
      $md.Add("|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
      foreach ($pr in $Presets) {
        foreach ($lk in $Looks) {
          $a = $lookup["0.2.2|$pr|$lk|$rt"]
          $b = $lookup["0.3.0|$pr|$lk|$rt"]
          $fpsA = if ($a -and $a.ok) { "$(Format-InvNum $a.fps_p50 1) ($(Format-InvNum $a.p50 1) ms)" } else { "n/a" }
          $fpsB = if ($b -and $b.ok) { "$(Format-InvNum $b.fps_p50 1) ($(Format-InvNum $b.p50 1) ms)" } else { "n/a" }
          $delta = "n/a"
          if ($a -and $b -and $a.ok -and $b.ok -and $a.fps_p50 -gt 0) {
            $pct = (([double]$b.fps_p50 - [double]$a.fps_p50) / [double]$a.fps_p50) * 100.0
            $sign = if ($pct -ge 0) { "+" } else { "" }
            $delta = "$sign$(Format-InvNum $pct 1)%"
          }
          $p99A = if ($a -and $a.ok) { "$(Format-InvNum $a.p99 1) ms" } else { "n/a" }
          $p99B = if ($b -and $b.ok) { "$(Format-InvNum $b.p99 1) ms" } else { "n/a" }
          $gpuA = if ($a -and $a.ok -and $null -ne $a.gpu_p50) { "$(Format-InvNum $a.gpu_p50 2) ms" } else { "n/a" }
          $gpuB = if ($b -and $b.ok -and $null -ne $b.gpu_p50) { "$(Format-InvNum $b.gpu_p50 2) ms" } else { "n/a" }
          $upsA = if ($a -and $null -ne $a.ups) { Format-InvNum $a.ups 1 } else { "n/a" }
          $upsB = if ($b -and $null -ne $b.ups) { Format-InvNum $b.ups 1 } else { "n/a" }
          $brA  = if ($a -and $null -ne $a.bridge_avg) { "$(Format-InvNum $a.bridge_avg 2) ms" } else { "n/a" }
          $brB  = if ($b -and $null -ne $b.bridge_avg) { "$(Format-InvNum $b.bridge_avg 2) ms" } else { "n/a" }
          $md.Add("| $pr | $lk | $fpsA | $fpsB | $delta | $p99A | $p99B | $gpuA | $gpuB | $upsA | $upsB | $brA | $brB |")
        }
      }
      $md.Add("")
    }
  }

  if ($RunConfig.repeat -gt 1) {
    $md.Add("## Median per case (min-max over the runs)")
    $md.Add("")
    $md.Add("| Version | Preset | Look | Route | Runs ok | p50 ms | p99 ms | >33 ms frames | GPU p50 | Draws p50 | Bridge p99 |")
    $md.Add("|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|")
    function Format-Spread {
      param($Med, [object[]]$OkRows, [string]$Key, [int]$Dec)
      if ($null -eq $Med[$Key]) { return "n/a" }
      $vals = @($OkRows | Where-Object { $null -ne $_[$Key] } | ForEach-Object { [double]$_[$Key] })
      if ($vals.Count -lt 2) { return (Format-InvNum $Med[$Key] $Dec) }
      $mn = ($vals | Measure-Object -Minimum).Minimum
      $mx = ($vals | Measure-Object -Maximum).Maximum
      return "$(Format-InvNum $Med[$Key] $Dec) ($(Format-InvNum $mn $Dec)-$(Format-InvNum $mx $Dec))"
    }
    foreach ($e in $medRows) {
      $p = $e.key -split '\|'
      $r = $e.row
      $md.Add("| $($p[0]) | $($p[1]) | $($p[2]) | $($p[3]) | $($e.ok_runs)/$($e.runs) | $(Format-Spread $r $e.ok_rows 'p50' 1) | $(Format-Spread $r $e.ok_rows 'p99' 1) | $(Format-Spread $r $e.ok_rows 'over33' 0) | $(Format-Spread $r $e.ok_rows 'gpu_p50' 2) | $(Format-Spread $r $e.ok_rows 'draw_calls_p50' 0) | $(Format-Spread $r $e.ok_rows 'bridge_p99' 2) |")
    }
    $md.Add("")
  }

  $md.Add("## All Runs")
  $md.Add("")
  $md.Add("| ID | Version | Preset | Look | Route | OK | FPS | p50 ms | p99 ms | Worst ms | >16.7 / >33 | GPU p50 | Draws p50 | UPS | Bridge avg/p99 | Errors |")
  $md.Add("|---|---|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
  foreach ($r in $Rows) {
    $okStr = if ($r.ok) { "ok" } else { "FAIL ($($r.error))" }
    $overStr = if ($null -ne $r.over16) { "$($r.over16) / $($r.over33)" } else { "n/a" }
    $brStr = if ($null -ne $r.bridge_avg) { "$(Format-InvNum $r.bridge_avg 2) / $(Format-InvNum $r.bridge_p99 2)" } else { "n/a" }
    $md.Add("| $($r.id) | $($r.version) | $($r.preset) | $($r.look) | $($r.route) | $okStr | $(Format-InvNum $r.fps_p50 1) | $(Format-InvNum $r.p50 1) | $(Format-InvNum $r.p99 1) | $(Format-InvNum $r.worst 1) | $overStr | $(Format-InvNum $r.gpu_p50 2) | $($r.draw_calls_p50) | $(Format-InvNum $r.ups 1) | $brStr | $($r.godot_errors)/$($r.script_errors) |")
  }
  $md.Add("")
  Write-Utf8NoBom -Path (Join-Path $ModeDir "report.md") -Content ($md -join "`n")
}

# --- Main -----------------------------------------------------------------------------------------

if ($OutDir -eq "") {
  $OutDir = Join-Path (Join-Path $PSScriptRoot "bench-results") $PcName
}
# Absolute: the probe's path goes to the client, and an exported Zenith reads a relative path as res://.
if (-not [System.IO.Path]::IsPathRooted($OutDir)) { $OutDir = Join-Path (Get-Location).Path $OutDir }
$OutDir = [System.IO.Path]::GetFullPath($OutDir)
$resolvedSave = Resolve-SaveFile -Spec $Save
$saveSha12 = (Get-FileHash -Algorithm SHA256 -Path $resolvedSave).Hash.Substring(0, 12).ToLowerInvariant()
$pcInfo = Get-PcInfo

$builds = @{}
$workBuildsDir = Join-Path $OutDir "_builds"
if ($Build.Count -gt 0 -and -not $PSBoundParameters.ContainsKey("Versions")) {
  $labels = New-Object System.Collections.Generic.List[string]
  foreach ($entry in $Build) { foreach ($part in ($entry -split ";")) { if ($part -match '^\s*([^=]+?)\s*=') { $labels.Add($Matches[1]) } } }
  if ($Build022 -ne "") { $labels.Add("0.2.2") }
  if ($Build030 -ne "") { $labels.Add("0.3.0") }
  $Versions = @($labels | Select-Object -Unique | Sort-Object { ConvertTo-VersionKey $_ })
}
if ($Versions -contains "0.2.2" -and -not ($Build -match '^\s*0\.2\.2\s*=')) {
  $builds["0.2.2"] = Resolve-ZenithBuild -Version "0.2.2" -Spec $Build022 -WorkBuildsDir $workBuildsDir -GodotExe $Godot -NoExtract:$DryRun
}
if ($Versions -contains "0.3.0" -and -not ($Build -match '^\s*0\.3\.0\s*=')) {
  $builds["0.3.0"] = Resolve-ZenithBuild -Version "0.3.0" -Spec $Build030 -WorkBuildsDir $workBuildsDir -GodotExe $Godot -NoExtract:$DryRun
}
$extraBuilds = [ordered]@{}
foreach ($entry in $Build) {
  foreach ($part in ($entry -split ";")) {
    if ($part -match '^\s*([^=]+?)\s*=\s*(.+?)\s*$') { $extraBuilds[$Matches[1]] = $Matches[2] }
  }
}
foreach ($label in $extraBuilds.Keys) {
  $spec = $extraBuilds[$label]
  $userArgs = @()
  $bar = $spec.IndexOf("|")
  if ($bar -ge 0) {
    $userArgs = @(($spec.Substring($bar + 1).Trim()) -split '\s+' | Where-Object { $_ -ne "" })
    $spec = $spec.Substring(0, $bar).Trim()
  }
  $builds[$label] = Resolve-ZenithBuild -Version $label -Spec $spec -WorkBuildsDir $workBuildsDir -GodotExe $Godot -NoExtract:$DryRun
  $builds[$label]["user_args"] = $userArgs
}
foreach ($v in $Versions) {
  if (-not $builds.ContainsKey($v)) {
    throw "No build for version '$v'. Pass -Build022 / -Build030, or -Build `"$v=<folder or zip>`"."
  }
}

# Construct ordered test matrix. Interleave versions by default so thermal/background drift cancels.
$plan = New-Object System.Collections.Generic.List[hashtable]
if ($Repeat -lt 1) { $Repeat = 1 }
function Add-PlanCase {
  param([string]$V, [string]$Pr, [string]$Lk, [string]$Rt)
  if ($Lk -eq "cinematic" -and -not (Test-HasBusAndCinematic $V)) { return }
  $rtUse = $Rt
  if ($Rt -eq "bus" -and -not (Test-HasBusAndCinematic $V)) { $rtUse = "fast" }
  $script:plan.Add(@{ "version" = $V; "preset" = $Pr; "look" = $Lk; "route" = $rtUse; "mode" = $Mode; "run" = $script:curRun })
}
if (-not $NoInterleave) {
  foreach ($pr in $Presets) {
    foreach ($lk in $Looks) {
      foreach ($rt in $Routes) {
        for ($script:curRun = 1; $script:curRun -le $Repeat; $script:curRun++) {
          foreach ($v in $Versions) { Add-PlanCase $v $pr $lk $rt }
        }
      }
    }
  }
} else {
  foreach ($v in $Versions) {
    foreach ($pr in $Presets) {
      foreach ($lk in $Looks) {
        foreach ($rt in $Routes) {
          for ($script:curRun = 1; $script:curRun -le $Repeat; $script:curRun++) { Add-PlanCase $v $pr $lk $rt }
        }
      }
    }
  }
}

Write-Host "=== Zenith Cross-PC Benchmark Matrix ($Mode mode) ==="
Write-Host "PC:       $($pcInfo.pc_name) | $($pcInfo.cpu) ($($pcInfo.cpu_threads)T) | $($pcInfo.ram_gb) GB | $($pcInfo.gpu) (drv $($pcInfo.gpu_driver))"
Write-Host "Screen:   $($pcInfo.screen) | OS: $($pcInfo.os)"
Write-Host "Save:     $resolvedSave (sha256: $saveSha12)"
Write-Host "OutDir:   $OutDir"
foreach ($v in $Versions) {
  $b = $builds[$v]
  $addonNote = if ($b.addon_arg -ne "") { " [addon: $($b.addon_arg)]" } else { "" }
  Write-Host "Build $v`: $($b.kind) -> $($b.dir)$addonNote"
}
Write-Host "Tests planned: $($plan.Count) (repeat=$Repeat, interleave=$(-not $NoInterleave), resume=$(-not $NoResume), alt_mode=$($AltMode.IsPresent), res='$(if ($Resolution -ne '') { $Resolution } else { 'native' })')"

if ($DryRun) {
  Write-Host ""
  Write-Host "--- Sample generated settings.cfg (preset=high) ---"
  foreach ($v in $Versions) {
    foreach ($lk in $Looks) {
      Write-Host "[$v | high | $lk | mode=$Mode]"
      Write-Host (Build-TestSettingsText -Version $v -Preset "high" -Look $lk -BenchMode $Mode -TargetResolution $Resolution -UseAltMode:$AltMode.IsPresent)
    }
  }
  Write-Host "--- Test order ($($plan.Count) tests) ---"
  for ($i = 0; $i -lt $plan.Count; $i++) {
    $t = $plan[$i]
    $id = "$($t.version)_$($t.preset)_$($t.look)_$($t.route)"
    if ($Repeat -gt 1) { $id += "_r$($t.run)" }
    $ua = if ($builds[$t.version].user_args) { "  [client args: $($builds[$t.version].user_args -join ' ')]" } else { "" }
    Write-Host ("  {0,2}. {1}{2}" -f ($i + 1), $id, $ua)
  }
  exit 0
}

$udpPort = $PortBase
$gamePort = $PortBase + 1
$rconPort = $PortBase + 2
$clientPort = $PortBase + 3
foreach ($p in @($udpPort, $clientPort)) {
  if (-not (Test-UdpPortFree -Port $p)) {
    throw "UDP port $p is already in use. Close running servers/clients or pass -PortBase."
  }
}

$modeDir = Join-Path $OutDir $Mode
$runsDir = Join-Path $modeDir "runs"
$scratchSave = Join-Path (Join-Path $OutDir "_scratch") "bench_save.zip"
New-Item -ItemType Directory -Force -Path $runsDir | Out-Null

$runConfig = [ordered]@{
  "mode"             = $Mode
  "versions"         = @($Versions)
  "presets"          = @($Presets)
  "looks"            = @($Looks)
  "routes"           = @($Routes)
  "resolution"       = $Resolution
  "alt_mode"         = $AltMode.IsPresent
  "warmup"           = $Warmup
  "interleaved"      = (-not $NoInterleave)
  "repeat"           = $Repeat
  "save_sha12"       = $saveSha12
  "factorio_version" = "?"
  "space_age"        = $false
  "started_utc"      = [DateTime]::UtcNow.ToString("o")
}

$traceByRoute = @{ "stand" = 1500; "bus" = 1800; "fast" = 1800 }
$results = New-Object System.Collections.Generic.List[object]

for ($i = 0; $i -lt $plan.Count; $i++) {
  $t = $plan[$i]
  $v = $t.version
  $pr = $t.preset
  $lk = $t.look
  $rt = $t.route
  $testId = "${v}_${pr}_${lk}_${rt}"
  if ($Repeat -gt 1) { $testId += "_r$($t.run)" }
  $runDir = Join-Path $runsDir $testId
  $resFile = Join-Path $runDir "result.json"

  if (-not $NoResume -and (Test-Path $resFile)) {
    try {
      $prev = (Get-Content -Raw $resFile) | ConvertFrom-Json
      if ($prev.ok -eq $true) {
        Write-Host ("[{0}/{1}] SKIP (already ok): {2}" -f ($i + 1), $plan.Count, $testId)
        $h = [ordered]@{}
        foreach ($prop in $prev.PSObject.Properties) { $h[$prop.Name] = $prop.Value }
        $results.Add($h)
        continue
      }
    } catch {}
  }

  Write-Host ("[{0}/{1}] RUN: {2}" -f ($i + 1), $plan.Count, $testId)
  New-Item -ItemType Directory -Force -Path $runDir | Out-Null

  $b = $builds[$v]
  $settingsFile = Join-Path $runDir "settings.cfg"
  $godotLog = Join-Path $runDir "godot.log"
  $probeJson = Join-Path $runDir "probe.json"
  $stdoutLog = Join-Path $runDir "client.stdout.log"
  $stderrLog = Join-Path $runDir "client.stderr.log"
  foreach ($f in @($probeJson, $godotLog, $stdoutLog, $stderrLog)) {
    if (Test-Path $f) { Remove-Item -Path $f -Force -ErrorAction SilentlyContinue }
  }
  Write-Utf8NoBom -Path $settingsFile -Content (Build-TestSettingsText -Version $v -Preset $pr -Look $lk -BenchMode $Mode -TargetResolution $Resolution -UseAltMode:$AltMode.IsPresent)

  $isolatedAppData = Join-Path (Join-Path $modeDir "appdata") $v
  $zenithUser = Join-Path $isolatedAppData "Godot\app_userdata\Zenith"
  New-Item -ItemType Directory -Force -Path (Join-Path $zenithUser "logs") | Out-Null
  foreach ($cacheSub in @("chunk-cache", "lod-cache")) {
    $cachePath = Join-Path $zenithUser $cacheSub
    if (Test-Path $cachePath) {
      Remove-Item -Path $cachePath -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  $traceTicks = if ($traceByRoute.ContainsKey($rt)) { $traceByRoute[$rt] } else { 1200 }
  $clientArgs = New-Object System.Collections.Generic.List[string]
  if ($b.kind -eq "checkout") {
    $clientArgs.Add("--path")
    $clientArgs.Add((Join-Path $b.dir "client"))
  }
  $clientArgs.Add("--audio-driver")
  $clientArgs.Add("Dummy")
  $clientArgs.Add("--log-file")
  $clientArgs.Add($godotLog)
  $clientArgs.Add("--")
  $clientArgs.Add("--settings-file=$settingsFile")
  $clientArgs.Add("--factorio-port=$udpPort")
  $clientArgs.Add("--port=$clientPort")
  $clientArgs.Add("--gpu-profile")
  $clientArgs.Add("--stutter-probe=$probeJson@$rt")
  $clientArgs.Add("--probe-trace=$traceTicks")
  if ($Warmup -ne 15) {
    $clientArgs.Add("--probe-warmup=$Warmup")
  }
  if ($lk -eq "cinematic" -and $b.addon_arg -ne "") {
    $clientArgs.Add($b.addon_arg)
  }
  foreach ($ua in @($b.user_args)) { if ($ua) { $clientArgs.Add([string]$ua) } }

  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $clientExitCode = -1
  $runErr = ""
  Stop-BuildServer -Build $b -RconPort $rconPort
  try {
    $srvInfo = Start-BuildServer -Build $b -SrcSave $resolvedSave -ScratchSave $scratchSave -UdpPort $udpPort -GamePort $gamePort -RconPort $rconPort -FactorioExe $Factorio
    if ($runConfig.factorio_version -eq "?") {
      $runConfig.factorio_version = $srvInfo.factorio_version
      $runConfig.space_age = $srvInfo.space_age
    }
    $savedAppData = $env:APPDATA
    $cproc = $null
    try {
      $env:APPDATA = $isolatedAppData
      $cproc = Start-Process -FilePath $b.exe -ArgumentList (Format-WinArgsLine $clientArgs.ToArray()) -WorkingDirectory $b.dir -RedirectStandardOutput $stdoutLog -RedirectStandardError $stderrLog -PassThru
    } finally {
      $env:APPDATA = $savedAppData
    }
    # Clients before 0.1.3 have no --probe-trace: start the bridge's trace over RCON 35 s in, as compare_builds.py does
    # (a save's first /c only gets Factorio's achievements warning, so one goes first).
    if ((ConvertTo-VersionKey $v) -lt [version]"0.1.3") {
      $traceAt = (Get-Date).AddSeconds(35)
      while ((Get-Date) -lt $traceAt -and -not $cproc.HasExited) { Start-Sleep -Milliseconds 500 }
      if (-not $cproc.HasExited) {
        try {
          $pw = (Get-Content -Raw (Join-Path (Join-Path $b.server_dir "data") "rcon-password.txt")).Trim()
          $null = Send-FactorioRcon -Port $rconPort -Password $pw -Command "/c rcon.print('')" -TimeoutMs 5000
          $traceCmd = "/c __factorio-3d-bridge__ local p = package.loaded['__factorio-3d-bridge__/scripts/profile.lua'] or require('scripts.profile') rcon.print(p.trace($traceTicks))"
          $null = Send-FactorioRcon -Port $rconPort -Password $pw -Command $traceCmd -TimeoutMs 10000
        } catch {
          Write-Warning "   RCON trace failed: $($_.Exception.Message)"
        }
      }
    }
    if (-not $cproc.WaitForExit($ClientTimeoutSec * 1000)) {
      try { Stop-Process -Id $cproc.Id -Force -ErrorAction SilentlyContinue } catch {}
      $runErr = "Client timed out after $ClientTimeoutSec s"
    } else {
      $cproc.WaitForExit()
      $clientExitCode = $cproc.ExitCode
    }
    Start-Sleep -Seconds 2
    Stop-BuildServer -Build $b -RconPort $rconPort
    $flog = Join-Path (Join-Path $b.server_dir "data") "factorio-current.log"
    if (Test-Path $flog) {
      Copy-Item -Path $flog -Destination (Join-Path $runDir "factorio.log") -Force
    }
  } catch {
    $runErr = $_.Exception.Message
  } finally {
    Stop-BuildServer -Build $b -RconPort $rconPort
    if (Test-Path $scratchSave) {
      Remove-Item -Path $scratchSave -Force -ErrorAction SilentlyContinue
    }
  }
  $sw.Stop()

  $row = Parse-TestMetrics -RunDir $runDir -TestId $testId -Meta $t -ClientExitCode $clientExitCode -DurationSec $sw.Elapsed.TotalSeconds
  if ($runErr -ne "") {
    $row["ok"] = $false
    $row["error"] = $runErr
  }
  Write-Utf8NoBom -Path $resFile -Content ($row | ConvertTo-Json -Depth 6)
  $results.Add($row)
  Write-ModeOutputs -ModeDir $modeDir -PcInfo $pcInfo -RunConfig $runConfig -Rows $results.ToArray()

  if ($row.ok) {
    Write-Host ("   OK: {0} FPS (p50 {1} ms, p99 {2} ms, GPU {3} ms) | UPS {4} | Bridge {5} ms" -f `
      (Format-InvNum $row.fps_p50 1), (Format-InvNum $row.p50 1), (Format-InvNum $row.p99 1), `
      (Format-InvNum $row.gpu_p50 2), (Format-InvNum $row.ups 1), (Format-InvNum $row.bridge_avg 2))
  } else {
    Write-Warning "   FAILED ($testId): $($row.error)"
  }
}

Write-Host ""
Write-Host "Done. Wrote $(Join-Path $modeDir 'results.json'), results.csv, and report.md"
