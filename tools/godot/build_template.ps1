<#
.SYNOPSIS
Builds Zenith's own Godot Windows x86_64 release export template from Godot's source (tools/godot/README.md).

.DESCRIPTION
Fetches the pinned Godot tag into a git-ignored folder (art-src/godot-build/ of the main checkout by
default) and checks its commit, installs Godot's Windows build dependencies there (Direct3D 12: Mesa NIR,
Agility SDK, PIX; AccessKit; ANGLE) with Godot's own scripts, puts the source back to the tag, applies every
patch in tools/godot-patches/<version>/ in name order, and builds
`platform=windows target=template_release arch=x86_64 production=yes` with D3D12 and Vulkan on, with MSVC.
Source paths are trimmed from __FILE__ (/d1trimfile, as client/native/belt_sim does) so the binary carries
no user paths. Runs at below-normal priority with jobs limited so cores and >= -MinFreeGB of RAM stay free.
The result is copied to <BuildDir>\out\<version>\windows_release_x86_64.exe (+ _console.exe and BUILD.txt);
export with it through `tools/release/package.py --windows-template <that exe>`.

.EXAMPLE
powershell -ExecutionPolicy Bypass -File tools\godot\build_template.ps1
powershell -ExecutionPolicy Bypass -File tools\godot\build_template.ps1 -Jobs 4 -BuildDir D:\godot-build
#>
param(
	[string]$BuildDir = "",
	[int]$Jobs = 0,
	[double]$MinFreeGB = 8,
	[double]$GBPerJob = 1,  # cl.exe measured at 0.1-0.7 GB a job
	[string]$Python = "",
	[switch]$SkipDeps,
	[switch]$Clean
)
$ErrorActionPreference = "Stop"

# Pinned Godot: the tag and the commit it must point at (github.com/godotengine/godot, 4.7.2-stable).
$Version = "4.7.2"
$Tag = "4.7.2-stable"
$Commit = "ed1daf0bf001b61586d9930840f2f1394092c079"

$Repo = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
# The main checkout (worktrees share it): its art-src\ holds the source, dependencies and objects once.
$Main = Split-Path -Parent (git -C $Repo rev-parse --path-format=absolute --git-common-dir)
if (-not $BuildDir) { $BuildDir = Join-Path $Main "art-src\godot-build" }
if (-not $Python) {
	$Python = Join-Path $Main ".venv\Scripts\python.exe"
	if (-not (Test-Path $Python)) { $Python = "python" }
}
$Src = Join-Path $BuildDir "godot-$Version"
$Deps = Join-Path $BuildDir "deps"            # LOCALAPPDATA for Godot's install scripts
$DepsRoot = Join-Path $Deps "Godot\build_deps"
$Out = Join-Path $BuildDir "out\$Version"
$Patches = Join-Path $Repo "tools\godot-patches\$Version"
$Log = Join-Path $BuildDir "build-$Version.log"
New-Item -ItemType Directory -Force $BuildDir, $Out | Out-Null

function Free-GB {  # free + standby (reclaimable); the CIM figure if the counter's name is localised
	try { (Get-Counter '\Memory\Available MBytes' -ErrorAction Stop).CounterSamples[0].CookedValue / 1024 }
	catch { (Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1MB }
}

# 1. Source at the pinned tag, commit checked.
if (-not (Test-Path (Join-Path $Src ".git"))) {
	Write-Host "Fetching Godot $Tag ..."
	git -c advice.detachedHead=false clone --depth 1 --branch $Tag https://github.com/godotengine/godot.git $Src
	if ($LASTEXITCODE) { throw "git clone failed" }
}
$head = (git -C $Src rev-parse "$Tag^{commit}").Trim()
if ($head -ne $Commit) { throw "Godot tag $Tag is ${head}, expected ${Commit}: refusing to build" }

# 2. Back to the tag (untracked files removed, git-ignored build objects kept), then our patches.
git -C $Src reset --quiet --hard $Commit
git -C $Src clean -q -fd
$applied = @()
Get-ChildItem $Patches -Filter *.patch -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object {
	git -C $Src apply --check $_.FullName
	if ($LASTEXITCODE) { throw "patch $($_.Name) does not apply to $Tag" }
	git -C $Src apply $_.FullName
	$applied += "$($_.Name) sha256 $((Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLower())"
	Write-Host "Applied $($_.Name)"
}
if (-not $applied) { Write-Host "No patches in $Patches (stock Godot)." }

# 3. Godot's Windows build dependencies, with its own scripts, into the build folder.
if (-not $SkipDeps) {
	$need = @{
		"install_d3d12_sdk_windows.py" = "mesa-x86_64-msvc"
		"install_accesskit.py" = "accesskit"
		"install_angle.py" = "angle-x86_64-msvc"
	}
	foreach ($script in $need.Keys) {
		if (Test-Path (Join-Path $DepsRoot $need[$script])) { continue }
		$saved = $env:LOCALAPPDATA
		try {
			$env:LOCALAPPDATA = $Deps
			Push-Location $Src
			& $Python (Join-Path "misc\scripts" $script)
			if ($LASTEXITCODE) { throw "$script failed" }
		} finally { Pop-Location; $env:LOCALAPPDATA = $saved }
	}
}

# 4. MSVC.
$vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
$vs = (& $vswhere -latest -products * -property installationPath | Select-Object -First 1)
$vcvars = Join-Path $vs "VC\Auxiliary\Build\vcvars64.bat"
if (-not (Test-Path $vcvars)) { throw "MSVC not found (vcvars64.bat)" }

# 5. Jobs: cores and RAM left free for whoever uses the PC.
$free = Free-GB
if ($Jobs -le 0) {
	$cores = [Environment]::ProcessorCount
	$Jobs = [Math]::Min([Math]::Max(1, $cores - 4), [Math]::Floor(($free - $MinFreeGB) / $GBPerJob))
}
if ($Jobs -lt 1 -or $free - $Jobs * $GBPerJob -lt $MinFreeGB) {
	throw ("{0:N1} GB RAM free: a build with {1} job(s) would leave less than {2} GB. Close something or wait." -f $free, [Math]::Max(1, $Jobs), $MinFreeGB)
}

# 6. Build. /d1trimfile cuts the source and dependency folders off __FILE__ (CL is read by cl.exe;
# import_env_vars hands it to SCons' environment). A trailing \\ before the closing quote is one \.
$trim = @($Src, $DepsRoot) | ForEach-Object { '/d1trimfile:"' + $_ + '\\"' }
$env:CL = ($trim -join " ")
$env:BUILD_NAME = "zenith"
$sconsArgs = @(
	"platform=windows", "target=template_release", "arch=x86_64", "production=yes",
	"d3d12=yes", "vulkan=yes",
	"mesa_libs=`"$DepsRoot\mesa`"", "agility_sdk_path=`"$DepsRoot\agility_sdk`"",
	"accesskit_sdk_path=`"$DepsRoot\accesskit`"", "angle_libs=`"$DepsRoot\angle`"",
	"pix_path=`"$DepsRoot\pix`"", "import_env_vars=CL", "-j$Jobs"
)
if ($Clean) { $sconsArgs += "--clean" }
$bat = Join-Path $BuildDir "build-$Version.cmd"
@(
	"@echo off",
	"set `"PATH=$(Split-Path $vswhere);%PATH%`"",  # vcvars looks for vswhere
	"call `"$vcvars`" >nul || exit /b 1",
	"cd /d `"$Src`" || exit /b 1",
	("`"$Python`" -m SCons " + ($sconsArgs -join " "))
) | Set-Content $bat -Encoding ascii
Write-Host ("Building with {0} job(s), {1:N1} GB RAM free, log {2}" -f $Jobs, $free, $Log)
$started = Get-Date
$p = Start-Process cmd.exe -ArgumentList "/d", "/c", "`"$bat`"" -NoNewWindow -PassThru `
	-RedirectStandardOutput $Log -RedirectStandardError "$Log.err"
$null = $p.Handle  # keeps ExitCode readable after WaitForExit
try { $p.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::BelowNormal } catch {}
$p.WaitForExit()
$minutes = ((Get-Date) - $started).TotalMinutes
Remove-Item Env:CL, Env:BUILD_NAME
if ($p.ExitCode) { Get-Content $Log -Tail 20; Get-Content "$Log.err" -Tail 20; throw "SCons failed (exit $($p.ExitCode)); log $Log" }
if ($Clean) { Write-Host "Cleaned."; exit 0 }

# 7. Result.
$exe = Join-Path $Src "bin\godot.windows.template_release.x86_64.exe"
$console = Join-Path $Src "bin\godot.windows.template_release.x86_64.console.exe"
Copy-Item $exe (Join-Path $Out "windows_release_x86_64.exe") -Force
if (Test-Path $console) { Copy-Item $console (Join-Path $Out "windows_release_x86_64_console.exe") -Force }
$msvc = (Get-ChildItem (Join-Path $vs "VC\Tools\MSVC") | Sort-Object Name | Select-Object -Last 1).Name
@(
	"Godot $Tag ($Commit), BUILD_NAME zenith",
	"platform=windows target=template_release arch=x86_64 production=yes d3d12=yes vulkan=yes",
	"MSVC $msvc, $Jobs job(s), $([Math]::Round($minutes, 1)) min",
	"patches: $(if ($applied) { $applied -join '; ' } else { 'none (stock)' })"
) | Set-Content (Join-Path $Out "BUILD.txt") -Encoding utf8
$size = (Get-Item (Join-Path $Out "windows_release_x86_64.exe")).Length / 1MB
Write-Host ("Built in {0:N1} min: {1}\windows_release_x86_64.exe ({2:N1} MB)" -f $minutes, $Out, $size)
