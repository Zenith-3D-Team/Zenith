# Cross-PC Benchmark Matrix (`0.2.2` vs `0.3.0`)

Standalone Windows PowerShell 5.1+ scripts (`run_matrix.ps1`, `combine_matrix.ps1`) to run identical multi-preset / multi-look benchmarks on every test PC and merge the results into one cross-PC report. Zero Python, Git, or Godot install is required on PCs running packaged Zenith builds.

## Shared Folder / USB Layout

Put these in one folder (on a USB drive or copied identically to each PC):

- `run_matrix.ps1` and `run_matrix.bat` (and `combine_matrix.ps1`)
- `Zenith-0.2.2-dev-windows\` (or `.zip`)
- `Zenith-0.3.0-windows\` (or `.zip`, or a repo checkout)
- `Zenith Test.zip` (same Factorio save copied to all PCs — hashed automatically with SHA-256 to verify parity)

You still need Factorio 2.1 installed on each PC (`server\run-server.ps1` finds it automatically from Steam or `C:\Program Files\Factorio`, or pass `-Factorio "C:\path\to\factorio.exe"`).

## Quick Start

Preview everything (resolved builds, PC hardware, save hash, generated `settings.cfg`, and test order) without launching Factorio or Godot:

```powershell
.\tools\bench\run_matrix.bat -Save .\ZenithTest.zip -Build022 .\Zenith-0.2.2-dev-windows -Build030 .\Zenith-0.3.0-windows -DryRun
```

Run the full 32-test matrix (`0.2.2` + `0.3.0` x `low/medium/high/ultra` x `factorio/cinematic` x `stand/bus`, ~35-45 min, interleaved by version):

```powershell
.\tools\bench\run_matrix.bat -Save .\ZenithTest.zip -Build022 .\Zenith-0.2.2-dev-windows -Build030 .\Zenith-0.3.0-windows -OutDir .\bench-results\Desktop-PC
```

## Key Options

- **`-Mode native` (default) vs `-Mode matched`:**
  - `native`: each version uses its own default presets (`0.3.0` runs FSR 2.2, `render_scale = 0.8`, Distant Horizon `96`, updated `high` preset, and `god_rays`; `0.2.2` runs native `render_scale = 1.0` without Distant Horizon).
  - `matched`: pins identical engine settings (`render_scale = 1.0`, `upscaler = fsr1`, `distant_horizon = 0`, `god_rays = 0.0`, shared preset distances) across both `0.2.2` and `0.3.0` for pure engine-vs-engine numbers.
- **`-Resolution 1920x1080`:** Force the same output resolution across monitors (default `""` uses each PC's native resolution).
- **`-PcName MyLaptop`:** Name used for the PC column/table (defaults to `$env:COMPUTERNAME`).
- **`-AltMode`:** Turn Alt-mode on during all runs (off by default).
- **Resume & subsets:** Interrupted runs resume automatically (skipping tests whose `result.json` has `ok: true`; pass `-NoResume` to re-run from scratch). Filter with `-Versions`, `-Presets`, `-Looks`, `-Routes`.
- **Source checkout:** If `-Build030` points at a source repo instead of a packaged release, also pass `-Godot "C:\path\to\godot_console.exe"`. Cinematic Shaders is auto-loaded from `addons-src\cinematic-shaders`.

## Combining Results from All 3 PCs

Copy each PC's output directory into one parent folder (for example `bench-results\PC1\`, `bench-results\PC2\`, `bench-results\PC3\`) and run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools\bench\combine_matrix.ps1 -ResultsRoot .\bench-results
```

This writes `cross_pc_report.md` and `cross_pc_combined.csv`, including a hardware/consistency check (warning if save SHA-12, Factorio version, resolution, or Alt-mode differed between PCs), per-PC `0.2.2` vs `0.3.0` delta tables, and a side-by-side cross-PC matrix.
