<#
.SYNOPSIS
Builds NVIDIA Streamline (MIT source, pinned v2.14.16) without its updater, for Zenith's NVIDIA DLSS (tools/dlss/README.md).

.DESCRIPTION
Fetches Streamline at the pinned tag into a git-ignored folder (art-src/streamline-build/ of the main checkout by
default) and checks its commit and its Git LFS files, puts the source back to the tag, applies every patch in
tools/dlss/patches/ in name order (0001: no OTA, the NGX updater nvngx_update.exe never started, no downloaded
plugins, no NGX feature update; 0002: plugins load by the SHA-256 manifest this script writes, in place of the
NVIDIA-signer check), fetches the three build tools Streamline's own setup pulls with its own packman (premake,
the Vulkan SDK headers, slang; pinned in its project.xml; packman's cache stays in the build folder and no user
environment variable is set), generates its Visual Studio solution with its own premake.lua and builds
sl.interposer, sl.common and sl.dlss in its Production configuration with MSVC.
The three DLLs, zenith-sl-manifest.txt (their SHA-256s, read by the patched interposer and by Zenith) and BUILD.txt
are copied to <OutDir> (art-src/vendor-runtimes/streamline-built/ by default). Copy all four files into Zenith's
vendor/nvidia/ beside the player's own nvngx_dlss.dll (docs/RUNNING.md).
The DLLs link NVIDIA's closed NGX SDK and NVAPI libraries from Streamline's external/ folder: they are for local
testing and are never committed.
Runs at below-normal priority with jobs limited so cores and >= -MinFreeGB of RAM stay free, and stops its own build
if free RAM drops under -AbortFreeGB.

.EXAMPLE
powershell -ExecutionPolicy Bypass -File tools\dlss\build_streamline.ps1
powershell -ExecutionPolicy Bypass -File tools\dlss\build_streamline.ps1 -Jobs 4 -OutDir D:\sl-built
#>
param(
	[string]$BuildDir = "",
	[string]$OutDir = "",
	[int]$Jobs = 0,
	[double]$MinFreeGB = 8,
	[double]$AbortFreeGB = 3,
	[double]$GBPerJob = 1,
	[string]$Toolset = "",  # MSVC platform toolset (v143 = VS 2022, v145 = VS 2026); default: the installed one
	[switch]$SkipDeps
)
$ErrorActionPreference = "Stop"

# Pinned Streamline: the tag and the commit it must point at (github.com/NVIDIA-RTX/Streamline, v2.14.16).
$Version = "2.14.16"
$Tag = "v$Version"
$Commit = "625db07d4bca5abc67d781c42af7e7fb0761f1b6"
$RepoUrl = "https://github.com/NVIDIA-RTX/Streamline.git"
# The three DLLs Zenith loads (and the projects that make them).
$Dlls = @("sl.interposer.dll", "sl.common.dll", "sl.dlss.dll")
$Targets = "core\sl_interposer;plugins\sl_common;plugins\sl_dlss"  # msbuild names them by solution folder
# The build tools from Streamline's own project.xml that these three need (packman, NVIDIA's package host).
$Packages = @("premake", "VulkanSDK", "slang")

$Repo = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$Main = Split-Path -Parent (git -C $Repo rev-parse --path-format=absolute --git-common-dir)
if (-not $BuildDir) { $BuildDir = Join-Path $Main "art-src\streamline-build" }
if (-not $OutDir) { $OutDir = Join-Path $Main "art-src\vendor-runtimes\streamline-built" }
$Src = Join-Path $BuildDir "src"
$PackmanRepo = Join-Path $BuildDir "packman-repo"
$Patches = Join-Path $PSScriptRoot "patches"
$Log = Join-Path $BuildDir "build-$Version.log"
New-Item -ItemType Directory -Force $BuildDir, $OutDir | Out-Null

function Free-GB {  # free + standby (reclaimable); the CIM figure if the counter's name is localised
	try { (Get-Counter '\Memory\Available MBytes' -ErrorAction Stop).CounterSamples[0].CookedValue / 1024 }
	catch { (Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1MB }
}

# 1. Source at the pinned tag, commit checked, LFS files real (the NGX and NVAPI libraries are in Git LFS).
if (-not (Test-Path (Join-Path $Src ".git"))) {
	Write-Host "Fetching Streamline $Tag ..."
	git lfs version | Out-Null
	if ($LASTEXITCODE) { throw "Git LFS is needed (Streamline keeps its libraries in LFS): git lfs install" }
	git -c advice.detachedHead=false -c core.autocrlf=true clone --depth 1 --branch $Tag $RepoUrl $Src
	if ($LASTEXITCODE) { throw "git clone failed" }
}
$head = (git -C $Src rev-parse "$Tag^{commit}").Trim()
if ($head -ne $Commit) { throw "Streamline tag $Tag is ${head}, expected ${Commit}: refusing to build" }

# 2. Back to the tag (tracked files only: packman's links and the build output stay), then our patches.
# Streamline keeps CRLF sources; our patches are LF (.gitattributes), so Git converts on both sides.
git -C $Src config core.autocrlf true
git -C $Src reset --quiet --hard $Commit
if ($LASTEXITCODE) { throw "git reset failed" }
git -C $Src lfs pull
foreach ($lib in @("external\ngx-sdk\lib\Windows_x86_64\nvsdk_ngx_d.lib", "external\nvapi\amd64\nvapi64.lib")) {
	$f = Join-Path $Src $lib
	if (-not (Test-Path $f) -or (Get-Item $f).Length -lt 100KB) { throw "$lib is missing or an LFS pointer: git -C `"$Src`" lfs pull" }
}
$applied = @()
Get-ChildItem $Patches -Filter *.patch | Sort-Object Name | ForEach-Object {
	git -C $Src apply --check $_.FullName
	if ($LASTEXITCODE) { throw "patch $($_.Name) does not apply to $Tag" }
	git -C $Src apply $_.FullName
	if ($LASTEXITCODE) { throw "patch $($_.Name) failed" }
	$applied += "$($_.Name) sha256 $((Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLower())"
	Write-Host "Applied $($_.Name)"
}
if ($applied.Count -lt 3) { throw "expected the three patches in $Patches" }
# The patch removes every call that starts the updater; check nothing that does is left.
$left = git -C $Src grep -n -e "checkForOTA(m_api" -e "readServerManifest();" -e "NVSDK_NGX_UpdateFeature(" -e "execThread(execThreadProc" -- source
if ($left) { throw "updater calls left after patching:`n$left" }

# 3. Build tools from Streamline's own project.xml, only the three needed (pinned versions), with its packman.
# PM_PACKAGES_ROOT set here keeps packman's cache in the build folder and stops it from setx-ing one for the user.
if (-not $SkipDeps) {
	[xml]$project = Get-Content (Join-Path $Src "project.xml")
	foreach ($d in @($project.project.dependency)) {
		if ($Packages -notcontains $d.name) { [void]$project.project.RemoveChild($d) }
	}
	$deps = Join-Path $Src "zenith-deps.xml"
	$project.Save($deps)
	$env:PM_PACKAGES_ROOT = $PackmanRepo
	Push-Location $Src
	try {
		cmd /d /c "call tools\packman\packman.cmd pull -p windows-x86_64 zenith-deps.xml"
		if ($LASTEXITCODE) { throw "packman pull failed" }
	} finally { Pop-Location }
}
foreach ($need in @("tools\premake5\premake5.exe", "external\vulkan\Include\vulkan\vk_layer_dispatch_table.h", "external\slang\bin\windows-x64\release\slangc.exe")) {
	if (-not (Test-Path (Join-Path $Src $need))) { throw "missing $need (run without -SkipDeps)" }
}

# 4. MSVC.
$vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
$vs = (& $vswhere -latest -products * -property installationPath | Select-Object -First 1)
$vcvars = Join-Path $vs "VC\Auxiliary\Build\vcvars64.bat"
if (-not (Test-Path $vcvars)) { throw "MSVC not found (vcvars64.bat)" }
if (-not $Toolset) {
	$major = [int]((& $vswhere -latest -products * -property installationVersion | Select-Object -First 1).Split(".")[0])
	$Toolset = if ($major -ge 18) { "v145" } elseif ($major -eq 17) { "v143" } else { "v142" }
}

# 5. Jobs: cores and RAM left free for whoever uses the PC.
$free = Free-GB
if ($Jobs -le 0) {
	$cores = [Environment]::ProcessorCount
	$Jobs = [Math]::Min([Math]::Max(1, $cores - 4), [Math]::Floor(($free - $MinFreeGB) / $GBPerJob))
}
if ($Jobs -lt 1 -or $free - $Jobs * $GBPerJob -lt $MinFreeGB) {
	throw ("{0:N1} GB RAM free: a build with {1} job(s) would leave less than {2} GB. Close something or wait." -f $free, [Math]::Max(1, $Jobs), $MinFreeGB)
}

# 6. Solution (its premake.lua; no NvLowLatencyVk, a Vulkan-only closed library) and build.
# _CL_ is appended to cl.exe's command line: /d1trimfile cuts the source folder off __FILE__ (a trailing \\ before
# the closing quote is one \). _LINK_ the same for link.exe: the DLLs name their PDB without its folder.
$env:_CL_ = '/d1trimfile:"' + $Src + '\\"'
$env:_LINK_ = '/PDBALTPATH:%_PDB%'
$bat = Join-Path $BuildDir "build-$Version.cmd"
@(
	"@echo off",
	"set `"PATH=$(Split-Path $vswhere);%PATH%`"",
	"call `"$vcvars`" >nul || exit /b 1",
	"cd /d `"$Src`" || exit /b 1",
	"tools\premake5\premake5.exe vs2022 --file=premake.lua --with-nvllvk=no || exit /b 1",
	("msbuild _project\vs2022\streamline.sln -nologo -v:m -m:1 -t:$Targets -p:Configuration=Production -p:Platform=x64" +
		" -p:PlatformToolset=$Toolset -p:CL_MPCount=$Jobs")
) | Set-Content $bat -Encoding ascii
Write-Host ("Building with {0} job(s), toolset {1}, {2:N1} GB RAM free, log {3}" -f $Jobs, $Toolset, $free, $Log)
$started = Get-Date
$p = Start-Process cmd.exe -ArgumentList "/d", "/c", "`"$bat`"" -NoNewWindow -PassThru `
	-RedirectStandardOutput $Log -RedirectStandardError "$Log.err"
$null = $p.Handle  # keeps ExitCode readable after WaitForExit
try { $p.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::BelowNormal } catch {}
$aborted = $false
while (-not $p.WaitForExit(5000)) {
	if ((Free-GB) -lt $AbortFreeGB) {
		# Our own build only: the cmd.exe started above and everything under it.
		taskkill /T /F /PID $p.Id | Out-Null
		$aborted = $true
		break
	}
}
$minutes = ((Get-Date) - $started).TotalMinutes
Remove-Item Env:_CL_, Env:_LINK_
if ($aborted) { throw "Stopped the build: free RAM fell under $AbortFreeGB GB" }
if ($p.ExitCode) { Get-Content $Log -Tail 30; Get-Content "$Log.err" -Tail 20; throw "build failed (exit $($p.ExitCode)); log $Log" }

# 7. Result: the DLLs, their SHA-256 manifest (the patched interposer and Zenith read it) and BUILD.txt.
$manifest = @("# Zenith's self-built Streamline $Tag ($Commit), patched: tools/dlss/patches. sha256  file")
foreach ($dll in $Dlls) {
	$name = [IO.Path]::GetFileNameWithoutExtension($dll)
	$built = Join-Path $Src "_artifacts\$name\Production_x64\$dll"
	if (-not (Test-Path $built)) { throw "not built: $built" }
	Copy-Item $built (Join-Path $OutDir $dll) -Force
	$manifest += "$((Get-FileHash $built -Algorithm SHA256).Hash.ToLower())  $dll"
}
$manifest | Set-Content (Join-Path $OutDir "zenith-sl-manifest.txt") -Encoding ascii
$msvc = (Get-ChildItem (Join-Path $vs "VC\Tools\MSVC") | Sort-Object Name | Select-Object -Last 1).Name
@(
	"Streamline $Tag ($Commit), configuration Production x64, premake --with-nvllvk=no",
	"MSVC $msvc (toolset $Toolset), $Jobs job(s), $([Math]::Round($minutes, 1)) min",
	"patches: $($applied -join '; ')",
	"packman packages: $($Packages -join ', ') (versions as in Streamline's project.xml)"
) + $manifest | Set-Content (Join-Path $OutDir "BUILD.txt") -Encoding utf8
Write-Host ("Built in {0:N1} min into {1}:" -f $minutes, $OutDir)
$manifest | Select-Object -Skip 1 | ForEach-Object { Write-Host "  $_" }
