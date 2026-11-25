extends RefCounted
## Render Distance + Level of Detail resolver (`render_distance.gd`):
## Dual separate View distance (full) (`view_radius`, 2..50 chunks) and Distant horizon
## (`distant_horizon`, 0..512 chunks) sliders are always active by default, resolving together with
## `lod_quality` (`low`/`medium`/`high`/`ultra`) into regular-chunk loading (`real_radius`), `FarChunks`
## merge thresholds (`far_merge_scale`), and `DistantHorizon` settings (`dh_enabled`, `dh_radius`,
## `dh_quality`, `dh_dropoff`). Unified Render distance mode (one 2..512 slider auto-balanced by
## `lod_quality`) stays available via `--render-distance-split=unified` (forced dual via
## `--render-distance-split=manual`).

const Settings := preload("res://scripts/menu/settings.gd")
const ModelLods := preload("res://scripts/world/model_lods.gd")
const Switches := preload("res://scripts/switches.gd")

const RENDER_DISTANCE_MIN := 2
const RENDER_DISTANCE_MAX := 512
const REAL_RADIUS_MAX := 50
const VALID_LODS := ["low", "medium", "high", "ultra"]


## Normalizes a `lod_quality` string to one of VALID_LODS (default `"medium"`).
static func normalize_lod(lod_quality: String) -> String:
	var q := lod_quality.to_lower()
	if VALID_LODS.has(q):
		return q
	return "medium"


## Auto-balances full-chunk split radius, DH quality/dropoff, and FarChunks scale for a target distance and LOD.
static func auto_balance(total_radius: int, lod_quality: String, lod_distance := 0.0) -> Dictionary:
	var r := clampi(total_radius, RENDER_DISTANCE_MIN, RENDER_DISTANCE_MAX)
	var lod := normalize_lod(lod_quality)
	var out: Dictionary
	match lod:
		"low":
			out = {
				"real_cap": 5 if r >= 256 else 6,
				"dh_quality": "low",
				"dh_dropoff": "near",
				"far_merge_scale": 1.25 if ModelLods.old_low_lod else 2.20,
			}
		"high":
			out = {
				"real_cap": 12 if r >= 384 else (13 if r >= 256 else 14),
				"dh_quality": "high",
				"dh_dropoff": "balanced" if r > 160 else "far",
				"far_merge_scale": 0.85,
			}
		"ultra":
			out = {
				"real_cap": 16 if r >= 320 else 18,
				"dh_quality": "ultra",
				"dh_dropoff": "balanced" if r > 256 else "far",
				"far_merge_scale": 0.70,
			}
		_:
			out = {
				"real_cap": 8 if r >= 320 else (9 if r >= 192 else 10),
				"dh_quality": "medium",
				"dh_dropoff": "near" if r >= 256 else "balanced",
				"far_merge_scale": 1.0,
			}
	if lod_distance > 0.0:
		var dist_scale := clampf(lod_distance / ModelLods.LOD_DIST_REF, 0.25, 3.0)
		out["far_merge_scale"] = clampf(ModelLods.LOD_DIST_REF / lod_distance, 0.35, 3.5)
		out["real_cap"] = clampi(roundi(float(8 if r >= 320 else (9 if r >= 192 else 10)) * clampf(dist_scale, 0.4, 2.0)), 4, 20)
		out["dh_dropoff"] = "near" if lod_distance <= 36.0 else ("far" if lod_distance >= 80.0 and r <= 256 else "balanced")
	return out


## Resolves manual split (default) or unified render settings plus CLI overrides into effective runtime bounds.
static func resolve(total_radius: int, lod_quality: String, manual_split := true,
		manual_dh_radius := 0, manual_dh_quality := "medium", manual_dh_dropoff := "balanced",
		dh_cli := {}, lod_distance := 0.0) -> Dictionary:
	var bal := auto_balance(total_radius, lod_quality, lod_distance)
	var far_merge_scale := float(bal["far_merge_scale"])

	if dh_cli.has("enabled") and not bool(dh_cli["enabled"]):
		var real_r := clampi(total_radius, 1, REAL_RADIUS_MAX)
		return {
			"total_radius": real_r,
			"real_radius": real_r,
			"dh_enabled": false,
			"dh_radius": 0,
			"dh_quality": manual_dh_quality if manual_split else str(bal["dh_quality"]),
			"dh_dropoff": manual_dh_dropoff if manual_split else str(bal["dh_dropoff"]),
			"far_merge_scale": far_merge_scale,
			"manual": manual_split,
		}

	if manual_split:
		var real_r := clampi(total_radius, 1, REAL_RADIUS_MAX)
		var dh_r := clampi(int(dh_cli["radius_chunks"]), 0, RENDER_DISTANCE_MAX) if dh_cli.has("radius_chunks") else clampi(manual_dh_radius, 0, RENDER_DISTANCE_MAX)
		var dh_en := bool(dh_cli["enabled"]) if dh_cli.has("enabled") else (dh_r > 0)
		if not dh_en:
			dh_r = 0
		return {
			"total_radius": maxi(real_r, dh_r),
			"real_radius": real_r,
			"dh_enabled": dh_en,
			"dh_radius": dh_r,
			"dh_quality": str(dh_cli["quality"]) if dh_cli.has("quality") else manual_dh_quality,
			"dh_dropoff": str(dh_cli["dropoff"]) if dh_cli.has("dropoff") else manual_dh_dropoff,
			"far_merge_scale": far_merge_scale,
			"manual": true,
		}

	var eff_total := clampi(total_radius, RENDER_DISTANCE_MIN, RENDER_DISTANCE_MAX)
	if dh_cli.has("radius_chunks"):
		eff_total = maxi(eff_total, clampi(int(dh_cli["radius_chunks"]), 0, RENDER_DISTANCE_MAX))
	bal = auto_balance(eff_total, lod_quality, lod_distance)
	far_merge_scale = float(bal["far_merge_scale"])
	var real_r := mini(eff_total, int(bal["real_cap"]))
	var cli_forced_on := dh_cli.has("enabled") and bool(dh_cli["enabled"]) and eff_total > 0
	var dh_en := eff_total > real_r or cli_forced_on
	var dh_r := eff_total if dh_en else 0
	return {
		"total_radius": eff_total,
		"real_radius": real_r,
		"dh_enabled": dh_en,
		"dh_radius": dh_r,
		"dh_quality": str(dh_cli["quality"]) if dh_cli.has("quality") else str(bal["dh_quality"]),
		"dh_dropoff": str(dh_cli["dropoff"]) if dh_cli.has("dropoff") else str(bal["dh_dropoff"]),
		"far_merge_scale": far_merge_scale,
		"manual": false,
	}


## True when separate View distance (full) + Distant horizon controls are active: the default. The
## `graphics.distant_horizon_manual` setting (Graphics > Manual horizon split) switches it off for the unified
## Render distance; `--render-distance-split=unified|manual` on the command line wins over the setting.
static func is_manual_split(args: PackedStringArray = Switches.args()) -> bool:
	var manual := bool(Settings.get_value("graphics", "distant_horizon_manual"))
	for arg: String in args:
		if arg == "--render-distance-split=unified":
			manual = false
		elif arg == "--render-distance-split=manual":
			manual = true
	return manual


## Resolves render distance parameters from saved Settings and optional CLI overrides.
static func from_settings(dh_cli := {}) -> Dictionary:
	return resolve(
		int(Settings.get_value("graphics", "view_radius")),
		str(Settings.get_value("graphics", "lod_quality")),
		is_manual_split(),
		int(Settings.get_value("graphics", "distant_horizon")),
		str(Settings.get_value("graphics", "distant_horizon_quality")),
		str(Settings.get_value("graphics", "distant_horizon_dropoff")),
		dh_cli,
		float(Settings.get_value("graphics", "lod_distance"))
	)


## Applies UPS-governed `governed_real`, backfilling with Distant Horizon in unified mode so the outer horizon stays steady.
static func with_governed_real(resolved: Dictionary, governed_real: int, dh_cli := {}) -> Dictionary:
	var out := resolved.duplicate()
	var real_r := clampi(governed_real, 1, REAL_RADIUS_MAX)
	out["real_radius"] = real_r
	var cli_disabled := dh_cli.has("enabled") and not bool(dh_cli["enabled"])
	if not bool(out.get("manual", false)) and not cli_disabled:
		var target := int(out.get("total_radius", real_r))
		if real_r < target:
			out["dh_enabled"] = true
			out["dh_radius"] = maxi(int(out.get("dh_radius", 0)), target)
	return out
