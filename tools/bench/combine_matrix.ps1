# Aggregates benchmark results from multiple PCs (each folder containing results.json written by
# run_matrix.ps1) into cross_pc_combined.csv and cross_pc_report.md.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\bench\combine_matrix.ps1 -ResultsRoot .\bench-results

param(
  [Parameter(Mandatory = $true)][string]$ResultsRoot,
  [string]$OutDir = "",
  [string]$Mode = ""
)

$ErrorActionPreference = "Stop"
$Inv = [System.Globalization.CultureInfo]::InvariantCulture
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Write-Utf8NoBom {
  param([string]$Path, [string]$Content)
  $parent = Split-Path $Path -Parent
  if ($parent -and -not (Test-Path $parent)) {
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
  }
  [System.IO.File]::WriteAllText($Path, $Content, $Utf8NoBom)
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

function Escape-CsvCell {
  param([string]$Text)
  if ($null -eq $Text) { return "" }
  if ($Text -match '[,"\r\n]') {
    return '"' + $Text.Replace('"', '""') + '"'
  }
  return $Text
}

function Get-OrderedDistinct {
  param([string[]]$Items)
  $out = New-Object System.Collections.Generic.List[string]
  foreach ($x in $Items) {
    if ($x -ne "" -and -not $out.Contains($x)) { $out.Add($x) }
  }
  return $out.ToArray()
}

if (-not (Test-Path $ResultsRoot)) {
  throw "ResultsRoot not found: $ResultsRoot"
}
$rootPath = (Resolve-Path $ResultsRoot).Path
if ($OutDir -eq "") { $OutDir = $rootPath }

$jsonFiles = @(Get-ChildItem -Path $rootPath -Filter "results.json" -Recurse -File | Sort-Object FullName)
if ($jsonFiles.Count -eq 0) {
  throw "No results.json files found under $rootPath"
}

$datasets = New-Object System.Collections.Generic.List[object]
foreach ($jf in $jsonFiles) {
  try {
    $data = (Get-Content -Raw $jf.FullName) | ConvertFrom-Json
    if ($null -eq $data.pc_info -or $null -eq $data.run_config -or $null -eq $data.tests) {
      continue
    }
    $m = [string]$data.run_config.mode
    if ($Mode -ne "" -and $m -ne $Mode) {
      continue
    }
    $datasets.Add(@{ "path" = $jf.FullName; "data" = $data; "mode" = $m })
  } catch {
    Write-Warning "Skipping unreadable JSON: $($jf.FullName) ($($_.Exception.Message))"
  }
}

if ($datasets.Count -eq 0) {
  throw "No matching benchmark results.json payloads found under $rootPath"
}

$cols = @("pc_name", "mode", "version", "run", "preset", "look", "route", "ok", "fps_p50", "p50", "p99", "worst",
  "over16", "over33", "over50", "frames", "gpu_p50", "gpu_p99", "render_cpu_p50", "process_p50", "process_p99",
  "draw_calls_p50", "primitives_p50", "load_p50", "load_worst", "ups", "bridge_avg", "bridge_p99",
  "bridge_worst", "bridge_over_16", "belt_items_avg", "belt_items_p99", "served_ticks", "godot_errors",
  "script_errors", "seconds", "error")

$csvLines = New-Object System.Collections.Generic.List[string]
$csvLines.Add(($cols -join ","))

$md = New-Object System.Collections.Generic.List[string]
$md.Add("# Zenith Cross-PC Benchmark Report")
$md.Add("")

$modesFound = @(Get-OrderedDistinct (@($datasets | ForEach-Object { $_.mode })))
foreach ($mName in $modesFound) {
  $modeSets = @($datasets | Where-Object { $_.mode -eq $mName } | Sort-Object { [string]$_.data.pc_info.pc_name })
  $md.Add("## Mode: ``$mName`` ($($modeSets.Count) PC(s))")
  $md.Add("")

  # Consistency check across PCs
  $shas = @(Get-OrderedDistinct (@($modeSets | ForEach-Object { [string]$_.data.run_config.save_sha12 })))
  $fvers = @(Get-OrderedDistinct (@($modeSets | ForEach-Object { [string]$_.data.run_config.factorio_version })))
  $ress = @(Get-OrderedDistinct (@($modeSets | ForEach-Object { if ([string]$_.data.run_config.resolution -ne "") { [string]$_.data.run_config.resolution } else { "native" } })))
  $alts = @(Get-OrderedDistinct (@($modeSets | ForEach-Object { [string]$_.data.run_config.alt_mode })))

  $warnings = New-Object System.Collections.Generic.List[string]
  if ($shas.Count -gt 1)  { $warnings.Add("save SHA-12 differs across PCs: $($shas -join ', ')") }
  if ($fvers.Count -gt 1) { $warnings.Add("Factorio version differs across PCs: $($fvers -join ', ')") }
  if ($ress.Count -gt 1)  { $warnings.Add("target resolution differs across PCs: $($ress -join ', ')") }
  if ($alts.Count -gt 1)  { $warnings.Add("alt_mode differs across PCs: $($alts -join ', ')") }
  if ($warnings.Count -gt 0) {
    foreach ($w in $warnings) {
      $md.Add("> **WARNING:** $w")
    }
    $md.Add("")
  } else {
    $md.Add("Consistency check passed: same save (``$($shas[0])``), Factorio (``$($fvers[0])``), resolution (``$($ress[0])``), and Alt-mode (``$($alts[0])``).")
    $md.Add("")
  }

  # 1. Hardware table
  $md.Add("### 1. PC Hardware & Environment")
  $md.Add("")
  $md.Add("| PC | CPU | GPU (Driver) | RAM | Screen | OS | Factorio | Save SHA-12 | Target Res |")
  $md.Add("|---|---|---|---:|---|---|---|---|---|")
  foreach ($ds in $modeSets) {
    $pc = $ds.data.pc_info
    $rc = $ds.data.run_config
    $resLabel = if ([string]$rc.resolution -ne "") { [string]$rc.resolution } else { "native ($($pc.screen))" }
    $saStr = if ($rc.space_age) { "$($rc.factorio_version) +SA" } else { "$($rc.factorio_version)" }
    $md.Add("| $($pc.pc_name) | $($pc.cpu) ($($pc.cpu_threads)T) | $($pc.gpu) ($($pc.gpu_driver)) | $($pc.ram_gb) GB | $($pc.screen) | $($pc.os) | $saStr | ``$($rc.save_sha12)`` | $resLabel |")
  }
  $md.Add("")

  $allVersions = New-Object System.Collections.Generic.List[string]
  $allPresets = New-Object System.Collections.Generic.List[string]
  $allLooks = New-Object System.Collections.Generic.List[string]
  $allRoutes = New-Object System.Collections.Generic.List[string]
  $byPc = @{}
  $caseRuns = @{}

  foreach ($ds in $modeSets) {
    $pcKey = [string]$ds.data.pc_info.pc_name
    if (-not $byPc.ContainsKey($pcKey)) { $byPc[$pcKey] = @{} }
    foreach ($t in @($ds.data.tests)) {
      $tv = [string]$t.version
      $tp = [string]$t.preset
      $tl = [string]$t.look
      $tr = [string]$t.route
      if (-not $allVersions.Contains($tv)) { $allVersions.Add($tv) }
      if (-not $allPresets.Contains($tp))  { $allPresets.Add($tp) }
      if (-not $allLooks.Contains($tl))    { $allLooks.Add($tl) }
      if (-not $allRoutes.Contains($tr))   { $allRoutes.Add($tr) }
      # Repeated runs of a case (run_matrix.ps1 -Repeat): the side-by-side tables show the median of each metric.
      $caseKey = "$tv|$tp|$tl|$tr"
      if (-not $caseRuns.ContainsKey("$pcKey|$caseKey")) { $caseRuns["$pcKey|$caseKey"] = New-Object System.Collections.Generic.List[object] }
      $caseRuns["$pcKey|$caseKey"].Add($t)
      $okRuns = @($caseRuns["$pcKey|$caseKey"] | Where-Object { $_.ok })
      if ($okRuns.Count -le 1) { $byPc[$pcKey][$caseKey] = $t }
      else {
        $m = $okRuns[0].PSObject.Copy()
        foreach ($mk in @("fps_p50", "p50", "p99", "worst", "over16", "over33", "over50", "gpu_p50", "gpu_p99", "render_cpu_p50", "process_p50", "process_p99", "draw_calls_p50", "ups", "bridge_avg", "bridge_p99")) {
          $vals = @($okRuns | Where-Object { $null -ne $_.$mk } | ForEach-Object { [double]$_.$mk } | Sort-Object)
          if ($vals.Count -gt 0) { $m.$mk = $vals[[int][math]::Floor(($vals.Count - 1) / 2)] }
        }
        $byPc[$pcKey][$caseKey] = $m
      }

      $cells = New-Object System.Collections.Generic.List[string]
      foreach ($c in $cols) {
        if ($c -eq "pc_name") { $cells.Add((Escape-CsvCell $pcKey)); continue }
        $v = $t.$c
        if ($null -eq $v) {
          $cells.Add("")
        } elseif ($v -is [bool]) {
          if ($v) { $cells.Add("true") } else { $cells.Add("false") }
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
  }

  # 2. Per-PC 0.2.2 vs 0.3.0 tables
  if ($allVersions.Contains("0.2.2") -and $allVersions.Contains("0.3.0")) {
    $md.Add("### 2. Per-PC 0.2.2 vs 0.3.0 Comparison")
    $md.Add("")
    foreach ($ds in $modeSets) {
      $pcKey = [string]$ds.data.pc_info.pc_name
      $map = $byPc[$pcKey]
      $md.Add("#### $pcKey")
      $md.Add("")
      foreach ($rt in $allRoutes) {
        $md.Add("##### Route: ``$rt``")
        $md.Add("")
        $md.Add("| Preset | Look | 0.2.2 FPS (p50) | 0.3.0 FPS (p50) | FPS Delta | p50 Delta | 0.2.2 p99 | 0.3.0 p99 | 0.2.2 GPU | 0.3.0 GPU | 0.2.2 UPS | 0.3.0 UPS | 0.2.2 Bridge | 0.3.0 Bridge | Bridge Delta |")
        $md.Add("|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
        foreach ($pr in $allPresets) {
          foreach ($lk in $allLooks) {
            $a = $map["0.2.2|$pr|$lk|$rt"]
            $b = $map["0.3.0|$pr|$lk|$rt"]
            $fpsA = if ($a -and $a.ok) { "$(Format-InvNum $a.fps_p50 1) ($(Format-InvNum $a.p50 1)ms)" } else { "n/a" }
            $fpsB = if ($b -and $b.ok) { "$(Format-InvNum $b.fps_p50 1) ($(Format-InvNum $b.p50 1)ms)" } else { "n/a" }
            $fpsD = "n/a"
            $p50D = "n/a"
            if ($a -and $b -and $a.ok -and $b.ok -and [double]$a.fps_p50 -gt 0 -and [double]$a.p50 -gt 0) {
              $df = (([double]$b.fps_p50 - [double]$a.fps_p50) / [double]$a.fps_p50) * 100.0
              $dp = (([double]$b.p50 - [double]$a.p50) / [double]$a.p50) * 100.0
              $fpsD = "$(if ($df -ge 0) { '+' } else { '' })$(Format-InvNum $df 1)%"
              $p50D = "$(if ($dp -ge 0) { '+' } else { '' })$(Format-InvNum $dp 1)%"
            }
            $p99A = if ($a -and $a.ok) { "$(Format-InvNum $a.p99 1)ms" } else { "n/a" }
            $p99B = if ($b -and $b.ok) { "$(Format-InvNum $b.p99 1)ms" } else { "n/a" }
            $gpuA = if ($a -and $a.ok -and $null -ne $a.gpu_p50) { "$(Format-InvNum $a.gpu_p50 2)ms" } else { "n/a" }
            $gpuB = if ($b -and $b.ok -and $null -ne $b.gpu_p50) { "$(Format-InvNum $b.gpu_p50 2)ms" } else { "n/a" }
            $upsA = if ($a -and $null -ne $a.ups) { Format-InvNum $a.ups 1 } else { "n/a" }
            $upsB = if ($b -and $null -ne $b.ups) { Format-InvNum $b.ups 1 } else { "n/a" }
            $brA = if ($a -and $null -ne $a.bridge_avg) { "$(Format-InvNum $a.bridge_avg 2)ms" } else { "n/a" }
            $brB = if ($b -and $null -ne $b.bridge_avg) { "$(Format-InvNum $b.bridge_avg 2)ms" } else { "n/a" }
            $brD = "n/a"
            if ($a -and $b -and $null -ne $a.bridge_avg -and $null -ne $b.bridge_avg -and [double]$a.bridge_avg -gt 0) {
              $db = (([double]$b.bridge_avg - [double]$a.bridge_avg) / [double]$a.bridge_avg) * 100.0
              $brD = "$(if ($db -ge 0) { '+' } else { '' })$(Format-InvNum $db 1)%"
            }
            $md.Add("| $pr | $lk | $fpsA | $fpsB | $fpsD | $p50D | $p99A | $p99B | $gpuA | $gpuB | $upsA | $upsB | $brA | $brB | $brD |")
          }
        }
        $md.Add("")
      }
    }
  }

  # 3. Cross-PC side-by-side matrix per version x route
  $md.Add("### 3. Cross-PC Side-by-Side Matrix")
  $md.Add("")
  $pcNames = @($modeSets | ForEach-Object { [string]$_.data.pc_info.pc_name })
  foreach ($ver in $allVersions) {
    foreach ($rt in $allRoutes) {
      $md.Add("#### Version ``$ver`` | Route ``$rt`` (FPS / p50 ms / p99 ms / UPS)")
      $md.Add("")
      $hdr = "| Preset | Look |"
      $sep = "|---|---|"
      foreach ($pn in $pcNames) {
        $hdr += " $pn |"
        $sep += "---:|"
      }
      $md.Add($hdr)
      $md.Add($sep)
      foreach ($pr in $allPresets) {
        foreach ($lk in $allLooks) {
          $line = "| $pr | $lk |"
          foreach ($pn in $pcNames) {
            $r = $byPc[$pn]["$ver|$pr|$lk|$rt"]
            if ($r -and $r.ok) {
              $upsStr = if ($null -ne $r.ups) { Format-InvNum $r.ups 1 } else { "?" }
              $cell = "$(Format-InvNum $r.fps_p50 1) FPS ($(Format-InvNum $r.p50 1) / p99 $(Format-InvNum $r.p99 1) ms, $upsStr UPS)"
            } else {
              $cell = "n/a"
            }
            $line += " $cell |"
          }
          $md.Add($line)
        }
      }
      $md.Add("")
    }
  }
}

$csvOut = Join-Path $OutDir "cross_pc_combined.csv"
$mdOut = Join-Path $OutDir "cross_pc_report.md"
Write-Utf8NoBom -Path $csvOut -Content ($csvLines -join "`n")
Write-Utf8NoBom -Path $mdOut -Content ($md -join "`n")
Write-Host "Combined $($datasets.Count) dataset(s) -> $mdOut & $csvOut"
