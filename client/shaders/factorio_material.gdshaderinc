// Factorio's look for every model. Each part has its own colour, sampled from Factorio's sprite
// when the model was built (CUSTOM1, tools/models/part_colors.py; the material's palette colour
// without one), and a procedural layer paints what the sprites show over it: dark ambient
// occlusion, grime in the crevices and round the base, worn bright edges, rust patches and
// streaks, dust on top, from vertex data baked by tools/models/bake.py (lighter over part colours,
// which carry Factorio's wear already).
//
// Vertex data (client/assets/models/README.md):
//   COLOR.rgb   albedo multiplier (the nature models' own shading), COLOR.a  ambient occlusion
//   UV2.x       worn edge (1 on bevels and rims)                     UV2.y  random per part
//   CUSTOM0     how much Factorio's camera sees of the vertex with the model facing north, east,
//               south, west (TEXCOORD_2 and _3 in the .glb)
//   CUSTOM1     the part's colour sampled from Factorio's sprite (rgb, linear) and how much of it
//               comes from the sprite (a), by tools/models/part_colors.py (TEXCOORD_4 and _5)
// Missing data (vertex_data / edge_data = 0) means a plain, unoccluded surface.
//
// The weathering uniforms come per material class from model_library.gd: steel rusts, paint
// chips to bare metal, wood and stone only gather dirt, foliage only gets its occlusion.
// Everything varies per instance with a hash of the instance's position, so neighbouring
// machines drawn from one MultiMesh don't look stamped out.
//
// Animation (anim.gd, chunk_view.gd):
//   animated        a moving part (a drill head, a turret head): its mesh is in model space at
//                   rest and its transform turns, so the entity's position (x, z) and direction
//                   (0-3) come from INSTANCE_CUSTOM.rgb instead of MODEL_MATRIX; the sprite and
//                   weathering stay painted on the part as it turns. Parts the shader moves itself
//                   (anim_mode, below) are drawn at the entity's own transform instead.
//   activity_glow   emissive surfaces (fire, anim_glow_* parts) glow by INSTANCE_CUSTOM.a, the
//                   machine's activity (0 idle, 1 working), and darken when idle.
//   glow_flicker    fire (furnaces, boilers, flares): how much the glow flickers, licking up
//                   the surface, at a rate of its own per instance.
//   glow_pulse      lights that breathe (lab, biochamber, fusion): how deep each pulse dims,
//                   glow_rate pulses a second (Factorio's loop: 60 * animation_speed / frames).
//   glow_fades      a see-through emissive material (a plume) is only there while it glows.
//   belt_speed      tiles per second: the belt surface's slats move north (-Z; south when
//                   negative, for underground exits), or round the
//                   arc on curves (belt_shape 1: left curve, 2: right curve).


// The shaders' clock (--static-mv): Godot draws every surface whose shader reads TIME in vertex()
// (or TIME and a discard in fragment()) in FSR 2.2's / TAA's motion-vector pass each frame, as if it
// moved. Standing buildings read the world's own clock instead (f3d_time, TIME's twin, set each
// frame by belt_blur.gd), so only what moves is drawn there: movers, robots and ragdolls, and the
// materials ModelLibrary.timed_shader() gives F3D_SHADER_TIME (worms, idle rigs; all of them with
// --static-mv=old), keep TIME so their vertex motion still gets its motion vectors.
#ifdef MOVER
#ifndef F3D_SHADER_TIME
#define F3D_SHADER_TIME
#endif
#endif
#ifdef RAGDOLL_DECAY
#ifndef F3D_SHADER_TIME
#define F3D_SHADER_TIME
#endif
#endif
#ifdef F3D_SHADER_TIME
#define F3D_TIME TIME
#else
global uniform float f3d_time;
#define F3D_TIME f3d_time
#endif

#include "res://shaders/noise.gdshaderinc"
#include "res://shaders/ground_height.gdshaderinc"
#include "res://shaders/lamp_light.gdshaderinc"
#include "res://shaders/weather_surface.gdshaderinc"
#ifdef MOVER
#include "res://shaders/mover_records.gdshaderinc"
#endif
#ifdef LEAF_CUT
#include "res://shaders/pollution.gdshaderinc"
#endif

uniform vec4 albedo : source_color = vec4(1.0);
uniform float roughness : hint_range(0.0, 1.0) = 0.6;
uniform float metallic : hint_range(0.0, 1.0) = 0.0;
uniform vec3 emission : source_color = vec3(0.0);
uniform float emission_energy = 0.0;
// 1 when the mesh has the baked COLOR, UV2 and CUSTOM0 data.
uniform float vertex_data = 1.0;
uniform float edge_data = 1.0;
uniform float view_data = 1.0;
// 1 when the mesh has part colours (CUSTOM1); part_colors 0 ignores them (the palette look, and
// tier and creature tints, which recolour the material).
uniform float part_data = 0.0;
uniform bool part_colors = true;
// A creature's tinted skin (tools/models/creature_skin.py, creature_models.gd): its part colours are
// Factorio's mask layers per vertex, coloured by the tier's tints as Factorio draws them. skin_mode
// 1: (mask 1, mask 2, mask 2's cover) under albedo (tint 1) and skin_tint2; 2: one mask (its shade
// and cover in COLOR) over the part colour, tinted by albedo, skin_tint2.a its alpha; 3: mode 2 as
// 0.2.1 read it, where the mask doesn't reach glowing in the tier's colour (--creature-glow=old). 0:
// the part colour as it is. In a merged table: row flags 16, 32 and both (3), tint 2 in the emission
// slot and its alpha in row 5's w.
uniform int skin_mode = 0;
uniform vec4 skin_tint2 : source_color = vec4(1.0);
// A glowing material that shines by its own paint: the emission (colour times strength) multiplies
// what the surface shows instead of glowing in its own colour (creature_models.gd: the demolishers'
// lava, whose part colours are the sprite's lava). Row flag 64 in a merged table.
uniform bool emission_from_paint = false;
// Cliffs: lifted by the low ground (ground_height.gdshaderinc), so the rock sits at the foot of
// the terrace its cliff makes instead of riding up it.
uniform bool ground_low = false;
// The generated cliff wall (cliff_wall.gd): seated by ground_lift_cliff_wall (its foot over the ramp).
uniform bool cliff_wall = false;
// Cliffs and rocks (model_library.gd wet_rock): wet like rough stone in the rain, no puddles or drips
// (weather_surface.gdshaderinc weather_apply_model; row flag 512 in a merged table).
uniform bool wet_rock = false;
// Organic creatures (model_library.gd organic_surface): 1 flesh/hide, 2 chitin/shell;
// procedural 3D micro-bump, roughness breakup, and non-mirror rain wetness (row flags 1024, 2048).
uniform int organic_surface = 0;
// 1: organic micro-bump and damp-organic wetness on; 0: --organic-surface=old.
global uniform float f3d_organic_surface;
// A mover (the character, cars, tanks, creatures drawn by their transform; movers.gd, avatar.gd):
// lifted whole onto the hills by the ground under its origin, not vertex by vertex, so it doesn't bend
// over a cliff's step. Walkers and robots drawn from their records (MOVER) always are.
uniform bool ground_rigid = false;
// 1: movers lifted whole (ground_rigid, MOVER); 0: --mover-lift=vertex, vertex by vertex as before.
global uniform float f3d_mover_rigid;

// A vertex lifted by the ground's height at one world point `xz` (the mover's origin: the side of a
// cliff's step it stands on), the same for every vertex of the model.
vec3 ground_lift_rigid(vec3 v, mat4 model, vec2 xz) {
	if (f3d_ground_on < 0.5) {
		return v;
	}
	float h = ground_h(xz);
	if (h == 0.0) {
		return v;
	}
	return v + ground_up_in(model, h);
}
// Multiplies the whole model's colour: Factorio's tinted copies of another entity's pictures
// (the infinity pipe is the pipe tinted blue; model_library.gd WHOLE_TINTS).
uniform vec3 model_tint : source_color = vec3(1.0);
// A model's own textures (model_textures.gd): its base colour picture stands in for the part colour
// (the paint as it looks, wear and all); glTF's metallic-roughness picture (G rough, B metal) for those.
uniform bool use_albedo_tex = false;
#ifdef ALPHA_CLIP
// glTF's alphaCutoff (Blender's Alpha Clip threshold): pixels under it are dropped.
uniform float alpha_clip = 0.5;
// A "pbr" pack's cut-out material whose file says single-sided (glTF doubleSided false, Godot's
// CULL_BACK): its back faces are dropped, shadows too, as Godot's own material culls them, while packs'
// own shading is on. Everyone else's cut-outs draw both sides (fences, grilles, leaves).
uniform bool clip_one_side = false;
#endif
uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform bool use_orm_tex = false;
// A model's own emission texture (glTF emissiveTexture): which parts glow, and in what colour, times
// the emission colour and strength. Without it the whole material glows (Zenith's own models).
uniform bool use_emission_tex = false;
uniform sampler2D emission_tex : source_color, filter_linear_mipmap, repeat_enable;
// A model's own normal map (glTF normalTexture, OpenGL style, green up). Models lose their tangents
// when their parts are merged, so the tangent frame is worked out per pixel from the UVs' slopes.
uniform bool use_normal_tex = false;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap, repeat_enable;
uniform float normal_scale = 1.0;
uniform sampler2D orm_tex : hint_default_white, filter_linear_mipmap, repeat_enable;
// The same pictures where the model's .glb asks for nearest filtering (Blender's Closest): texel by
// texel up close, mipmapped further off (model_textures.gd NEAREST_META).
uniform bool albedo_nearest = false;
uniform sampler2D albedo_tex_nearest : source_color, filter_nearest_mipmap_anisotropic, repeat_enable;
uniform bool orm_nearest = false;
uniform sampler2D orm_tex_nearest : hint_default_white, filter_nearest_mipmap, repeat_enable;
// A model's own occlusion picture (glTF occlusionTexture, its red channel): 1 when it is the ORM
// picture above (glTF's usual packing, one sample for both), 2 a picture of its own. It multiplies
// the baked per-vertex occlusion (COLOR.a, tools/models/bake_glb.py for textured models).
uniform int occlusion_mode = 0;
uniform sampler2D occlusion_tex : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform vec4 occlusion_channel = vec4(1.0, 0.0, 0.0, 0.0);
// The sampled colours already carry Factorio's grime and wear on average: the weathering on top of
// them is scaled by these (rust and streaks, worn edges, grime, dust), and they skip the palette's
// greying (desaturate, value). Worn edges and dust most of all: converted models are full of small
// bevels, and pale dust on every top read as a lighter colour.
uniform vec4 part_weathering = vec4(0.4, 0.2, 0.6, 0.1);
// Godot's sun lights tops far harder than the sides (about 3 to 1 from Factorio's view at noon,
// where Factorio's own renders have 1.3 to 1): part colours, which are Factorio's colours as its
// view shows them, are balanced back by the way the surface faces (x sides, y tops), so a forced
// colour shows about as given on a top and the sides keep their share.
uniform vec2 part_light = vec2(0.95, 0.6);
// A textured material from a pack whose pack.json says "shading": "pbr" (model_library.gd PACK_PBR_META):
// drawn as its file says, as Godot's own material draws it, while f3d_pack_shading is on. Its base colour
// picture is a colour with no light in it, so it gets the look's texture_light balance instead of
// part_light, Godot's SPECULAR 0.5, its own roughness and metal (at the look's pbr_metal share), its
// occlusion picture as ambient occlusion only, and a normal-map frame right whichever way dFdy runs.
uniform bool modeller_tex = false;
const float PART_RANGE = 4.0;
const float PART_SHARE = 0.25;

uniform float ao_strength = 1.0;
uniform float grime = 0.5;
uniform vec3 grime_color : source_color = vec3(0.13, 0.11, 0.09);
// Grime rising from the ground: how high (tiles) it reaches.
uniform float ground_grime_height = 0.45;
uniform float edge_wear = 0.5;
uniform vec3 edge_color : source_color = vec3(0.62, 0.6, 0.56);
uniform float edge_metallic = 0.7;
uniform float rust = 0.0;
uniform vec3 rust_color : source_color = vec3(0.36, 0.19, 0.09);
uniform float streaks = 0.0;
uniform float dust = 0.25;
uniform vec3 dust_color : source_color = vec3(0.5, 0.46, 0.38);
uniform float desaturate = 0.15;
uniform float value = 0.9;
uniform float grain = 0.08;
// Grain from the model's own Factorio picture (bark, rock: scripts/world/nature_looks.gd): 0 none,
// else its layer of f3d_nature_grain + 1 plus how much of it shows (0-1): layer 2 at 0.8 is 3.8.
uniform float nature_grain = 0.0;

uniform bool animated = false;
uniform bool activity_glow = false;
// Movers are single MeshInstance3Ds with no INSTANCE_CUSTOM: vehicle_anim.gd sets their glow
// here instead (0 to 1; below 0, INSTANCE_CUSTOM.a as for buildings).
instance uniform float f3d_glow = -1.0;
// The colour a player painted a train or stop (movers.gd sets it; white leaves the model as it is).
instance uniform vec3 f3d_paint : source_color = vec3(1.0);
// Painted from this height in the model up (Factorio paints only a train stop's top).
instance uniform float f3d_paint_from = -1000.0;
// A level of detail cross-fading with the one before (chunk_view.gd update_lods): 1 drawn whole;
// 0-1 fading in, drawn where the screen-door pattern is under it; 2-3 fading out, drawn where it
// isn't under the value less 2. The two levels of a switch take the same value, so together they
// cover every pixel once, and neither shows through the other.
instance uniform float f3d_lod_fade = 1.0;
// Where the instance's seed (its weathering, dirt, a 2-tile belt's parity) is read when .y is 1
// (.xz the place), instead of its own position: the model preview (model_preview.gd) turns a model
// about its middle, so its origin circles and the seed, a hash of it, changed every frame (the
// model's dirt and wear flickered as it turned).
instance uniform vec3 f3d_seed_at = vec3(0.0, -1.0, 0.0);
// A vehicle's body and moving parts lifted whole (ground_rigid) by the ground under this world point
// (.y 1, .xz the vehicle's origin; movers.gd), not each part's own origin; below 0, MODEL_MATRIX's.
instance uniform vec3 f3d_lift_at = vec3(0.0, -1.0, 0.0);
uniform float glow_flicker = 0.0;
uniform float glow_pulse = 0.0;
uniform float glow_rate = 1.0;
// Coals' heat (scripts/fx/burner_fx.gd, a modeller's burner inserter's lit burner): the glow
// breathes brighter and dimmer by slow noise, each instance out of phase by where it stands; 0 off.
// Unmerged materials only (a modeller's textured ones never are). burner_fx.gd heat_wave() is the
// same sum in GDScript: change both together.
uniform float glow_heat = 0.0;
uniform bool glow_fades = false;
// A modeller's glowing material (model_library.gd _factorio): at rest only its glow goes out; its base
// colour isn't dimmed as Zenith's own fire boxes and lamps are.
uniform bool glow_keeps_albedo = false;
// Creatures (creature_models.gd, tools/models/wube_rig.py): limbs turn about their joints here.
// UV.x is the vertex's limb (1-12, 0 for the body), UV.y how much it follows it (0 at the joint).
// rig_mode 1: the gait comes from INSTANCE_CUSTOM (r phase in radians, g strength 0-1), set by
// creatures.gd from the creature's speed; 2: it runs on its own (worms, spawners) at rig_rate.
// Per limb: joint, swing axis, lift axis, gait (phase offset, swing and lift radians, pulse).
uniform int rig_mode = 0;
uniform float rig_rate = 1.0;
uniform vec3 rig_joint[12];
uniform vec3 rig_swing[12];
uniform vec3 rig_lift[12];
uniform vec4 rig_gait[12];
// Walking legs fold at a knee too (tools/models/creature_gait.py, fitted to Factorio's run sheets):
// rig_knee is the knee in model space (xyz) and the leg's reach from the joint (w; 0: no knee), the
// part from 0.45 to 0.57 of the reach out folding about the lift axis (creature_pose.py's PoseRig).
// rig_bend: the walk's rest knee, its flex while the leg is lifted, and the rest lift (radians).
uniform vec4 rig_knee[12];
uniform vec4 rig_bend[12];
// The body at rest on its bent legs: raised (x, tiles) and pitched (y, radians) about z up.
uniform vec3 rig_body = vec3(0.0);
// Poses the walking model blends into (creature_poses.json, the attack and corpse models' own,
// fitted to the sprites): RIG_POSES poses of 12 limbs, each (swing, lift, knee). A posed instance
// (creatures.gd: biting, spitting, dying) says which and how far in INSTANCE_CUSTOM.a: 2 + pose +
// amount * RIG_POSE_SCALE; 1 (walking) is none. Its body is turned on the CPU.
#define RIG_POSES 5
const float RIG_POSE_SCALE = 0.999;
uniform vec4 rig_pose[60];
// rig_mode 3: a skeleton posed on the CPU (the character, character_pose.gd). UV.x is bone a +
// 16 * bone b, UV.y a's weight; each bone's matrix is three rows (rotation | translation).
uniform vec4 rig_bone[48];
// rig_mode 4: a worm (creature_models.gd), bent and raised by position alone, so nothing can
// tear: the neck follows more the higher it is. INSTANCE_CUSTOM.a (anim.gd): 0 folded into its
// hole, 1 prepared (standing, swaying), up to 2 attacking (lunging forwards, -Z).
uniform float worm_height = 1.0;
// rig_mode 5: a ragdoll posed per-limb from the CPU (addon_creatures.gd): each limb's (swing,
// lift, knee, twist) radians directly, reusing rig_joint, rig_swing, rig_lift and rig_knee, and skipping
// rig_body's stand-lift and ground_lift_of. w > 50.0 collapses a severed leg cleanly to its socket.
uniform vec4 rig_ragdoll[12];
uniform float rig_decay = 0.0;
uniform float rig_decay_floor = 0.0;
// Per-ragdoll / split-chunk bloodiness (0..1), charring/ember burn (0..1), and up to 6 model-space
// bullet/shrapnel holes (xyz = impact pos in mesh-local space, w = radius > 0).
uniform float rig_blood = 0.0;
uniform float rig_burn = 0.0;
uniform vec4 rig_holes[6];
// Factorio's alternative idle: 1 / prepared_alternative_speed (0.014) ticks long, at
// prepared_alternative_chance (0.2).
const float WORM_ALT_SECONDS = 1.0 / 0.014 / 60.0;
const float WORM_ALT_CHANCE = 0.2;
uniform float belt_speed = 0.0;
// A textured belt surface: UV change per tile along the belt (model_library.gd _belt_uv_scroll).
uniform vec2 belt_uv_scroll = vec2(0.0);
uniform int belt_shape = 0;
// The space under a belt's top run (belt_return.gd cover): (lowest y of the top run, lateral range of its
// width lo, hi, on). Everything of the model below that height and inside that range (the return strip,
// the rollers) is a covered space: darker ambient, direct light and fill (model_library.gd _setup_belt).
uniform vec4 belt_cover = vec4(0.0);
// The tier's chevron painted on every other slat, pointing the way items go (Factorio's belt sheets:
// yellow, red, blue, green); alpha 0 leaves the slats bare.
uniform vec4 belt_chevron : source_color = vec4(0.0);
// Tiles from one chevron to the next (model_library.gd BELT_CHEVRON_PERIODS, measured from Factorio's
// belt sprites): yellow 0.5, red and blue 1, turbo 2 (FFF #393: turbo's arrows twice as far apart).
// Whole slats; a 2-tile period takes alternate tiles from belt_parity.
uniform float belt_chevron_period = 0.5;
// Distance between the belt's slats, in tiles. Factorio's belt animation loops every half tile
// of travel (16 frames at one frame per tick for yellow), so slats every quarter tile.
const float BELT_PERIOD = 0.25;
// A belt model's INSTANCE_CUSTOM.b when the circuit network has switched it off (a timed instance's
// flag 8 instead; anim.gd BELT_STOPPED). A value no direction takes; instances without custom data run.
const float BELT_OFF = 5.0;
// Fast belts' slats and chevrons smeared over the way they move in a frame (belt_blur.gd mirrors
// these): an express chevron jumps 0.094 tile a frame at 60 fps and turbo's 0.125, more than its
// 0.08 stroke, and turbo's slats exactly half their period, so unsmeared they blink from place to
// place. The box spans BELT_SHUTTER frames' travel (two washed the fast belts out) but at least
// BELT_SMEAR_MIN of a slat period (red's quarter-period step needs a little more than its own to
// stop its seams strobing), faded in as a frame's step goes from BELT_SMEAR_FROM to BELT_SMEAR_TO of
// a slat period: yellow belts at 60 fps (0.125) are drawn as before. f3d_frame_dt is 0 (no smear)
// under TAA and on screenshots.
const float BELT_SHUTTER = 1.0;
const float BELT_SMEAR_MIN = 0.36;
const float BELT_SMEAR_FROM = 0.13;
const float BELT_SMEAR_TO = 0.2;

// One surface per model (model_library.gd, material_rows.gd): a model's surfaces of one shader are
// merged into one draw, each of the materials it was made of a row of material_table, CUSTOM2.r the
// vertex's row. With material_rows 0 (the default) the per-material uniforms above are used, as
// before; with rows, the uniforms the rows hold are ignored and the rest stay the model's own
// (activity_glow is then whether any row glows). A merged surface has every vertex array: a
// material's missing ones are filled with what reads as "none" (white COLOR, UV2 (0, 0.5), CUSTOM0
// 1), so vertex_data, edge_data and view_data aren't needed there. A row, MATERIAL_ROW vec4s:
//   0  albedo (linear rgb, alpha)
//   1  emission * emission_energy (linear), flags: 1 activity_glow, 2 glow_fades,
//      4 a belt surface (belt_speed applies), 8 no sprite (a tier's own paint), 16 and 32 a
//      creature's skin (skin_mode 1, 2, both 3), 64 emission_from_paint, 128 glow_keeps_albedo,
//      256 modeller_tex, 512 wet_rock, 1024/2048 organic_surface (1 flesh, 2 chitin)
//   2  roughness, metallic, edge_metallic, ground_grime_height
//   3  part_data (0 without part_colors), glow_flicker, glow_pulse, glow_rate
//   4  ao_strength, streaks, desaturate, value
//   5  grain, part_light, nature_grain (a skinned creature's second tint's alpha instead)
//   6  part_weathering
//   7-10  grime_color, edge_color, rust_color, dust_color (linear), and grime, edge_wear, rust, dust
// One row's vec4s lie together (a cache line or two), and are read after the noise, which keeps
// them out of registers while it runs.
#define MATERIAL_ROW 11
#define MATERIAL_TABLE 264
uniform int material_rows = 0;
uniform vec4 material_table[MATERIAL_TABLE];
varying flat int mat_row;

bool row_flag(float flags, float bit) {
	return mod(floor(flags / bit), 2.0) > 0.5;
}

varying vec3 obj_pos;
varying vec3 obj_normal;
varying float world_y;
varying vec2 world_xz;
varying flat float inst_seed;
varying flat float activity;
varying flat float belt_off;
// 0 or 1 by the tile the instance stands on (a checkerboard): every step to a neighbouring tile
// flips it, along a line, round a curve, either way, so a 2-tile chevron period lines up tile to tile.
varying flat float belt_parity;
varying vec4 part_col;
// Live wounded creature state (creatures.gd): x = blood (0..1), y = hits (0..8).
varying flat vec2 v_wound;
#ifdef LEAF_CUT
// How far this tree is dying of pollution: 0 healthy, then grey, thinner leaves, 1 bare.
varying flat float leaf_dying;
// The dark inside of a crown (tools/models/nature/trees.py SHADOWS, materials "leaf-shadow-..."),
// drawn with the leaf cards' shader but not cut into leaves: it shows through the gaps between the
// cards, so it goes as they fall, or a dying crown is left as black blocks (seen on the owner's base).
// Merged with the cards into one surface (model_library.gd merge_materials) the cores' UV (-1) says
// so instead, and solid leaves (UV -2) fall the same way (fragment(), leaf_kind).
uniform bool leaf_core = false;
// Factorio's own leaves on the cards (scripts/world/nature_looks.gd): an atlas of cells x cells patches
// of the tree's leaves picture from the player's install, each texel its colour over the crown's mean
// (gamma-space contrast, a mean of 1 over the leaves kept), halved; its alpha cut to a spray. 0 cells:
// none (no Factorio install, or not read yet), and the leaves are cut procedurally (leaf_cut).
uniform sampler2D leaf_atlas : filter_linear_mipmap, repeat_disable;
uniform float leaf_atlas_cells = 0.0;
uniform float leaf_atlas_texels = 36.0;  // a patch's width in texels
// How much of the picture's own light and shade shows (1: all of it, 0: a flat colour).
uniform float leaf_detail = 0.8;
// The prototype's leaf colours over their mean: Factorio tints each tree with one of them at random.
uniform vec3 leaf_tints[16];
uniform int leaf_tint_count = 0;
varying flat vec3 leaf_tint;
#endif
float hash13(vec3 p) {
	p = mod(p, 4096.0);
	p = fract(p * 0.1031);
	p += dot(p, p.zyx + 31.32);
	return fract((p.x + p.y) * p.z);
}

float vnoise3(vec3 x) {
	vec3 i = floor(x);
	vec3 f = fract(x);
	vec3 u = f * f * (3.0 - 2.0 * f);
	float a = mix(hash13(i), hash13(i + vec3(1.0, 0.0, 0.0)), u.x);
	float b = mix(hash13(i + vec3(0.0, 1.0, 0.0)), hash13(i + vec3(1.0, 1.0, 0.0)), u.x);
	float c = mix(hash13(i + vec3(0.0, 0.0, 1.0)), hash13(i + vec3(1.0, 0.0, 1.0)), u.x);
	float d = mix(hash13(i + vec3(0.0, 1.0, 1.0)), hash13(i + vec3(1.0, 1.0, 1.0)), u.x);
	return mix(mix(a, b, u.y), mix(c, d, u.y), u.z);
}

// How far noise has faded to its average, with `cells` of it across a pixel: noise finer than a pixel
// costs full price and only adds shimmer, so it fades out from a cell a pixel wide to half a pixel,
// and is skipped after that.
float noise_fade(float cells) {
	return smoothstep(1.0, 2.0, cells);
}

float vnoise3_fading(vec3 x, float cells) {
	float fade = noise_fade(cells);
	return fade < 1.0 ? mix(vnoise3(x), 0.5, fade) : 0.5;
}

// `pixel`: how far p moves in a pixel.
float fbm3d(vec3 p, float pixel) {
	return 0.55 * vnoise3(p) + 0.3 * vnoise3(p * 2.07 + 17.3) + 0.15 * vnoise3_fading(p * 4.13 + 41.1, pixel * 4.13);
}

// The average, over the noise, of smoothstep(0.3, 0.6, noise + 0.25 * edge), the worn edges' chips
// (a fit, within 0.002 of the value noise's own average).
float chips_mean(float edge) {
	return 0.593 + edge * (0.492 - 0.15 * edge);
}

#ifdef LEAF_CUT
// Leaf cards (tools/models/nature/geo.py `card`, factorio_material_leaf.gdshader): each square
// holds a round spray of small pointed leaves, cut out here, so a crown's edge is as ragged and
// see-through as Factorio's tree sprites. Leaves sit one per cell of a LEAF_CELLS grid, nudged and
// turned at random by the card's own seed (UV2.y, random per part); only leaves whose middle lies
// inside the spray's circle are kept, whole. Returns the leaf's shade (each leaf a little lighter
// or darker, darker at its rim, like the sprites' leaves); discards between leaves. Far away,
// where a leaf would be under a pixel and shimmer, the spray turns into a solid, ragged disk.
// `dying` (pollution, leaf_dying): that share of the leaves has fallen, each leaf by its own hash so
// the crown thins evenly, the far disk shrinks with it, and a dead tree (1) has none left.
const float LEAF_CELLS = 5.0;

float leaf_cut(vec2 uv, float seed, bool in_shadow, float dying, float fw) {
	if (dying >= 0.98) {
		discard;
	}
	float fallen = dying * 0.95;
	vec2 g = uv * LEAF_CELLS;
	vec2 off = vec2(seed * 61.0, seed * 37.0);
	// Leaves only a pixel or two long shimmer as the camera moves: the disk takes over while a leaf is
	// still about four pixels long (a cell 0.25 pixels per unit of g, wholly by 0.55).
	float far_away = clamp((fw - 0.25) * 3.3, 0.0, 1.0);
	float disk = 0.0;
	// A crown's shadow doesn't show its leaves' small holes, nor a card small enough that only the disk remains.
	if (in_shadow || far_away > 0.0) {
		vec2 q = uv * 2.0 - 1.0;
		disk = 0.78 + 0.18 * hash12(floor(g * 2.0) + off) - length(q) - 0.6 * fallen;
		if (in_shadow || far_away >= 1.0) {
			if (disk <= 0.0) {
				discard;
			}
			return 0.95;
		}
	}
	vec2 cell = floor(g);
	float cover = 0.0;
	float shade = 1.0;
	for (int j = -1; j <= 1; j++) {
		for (int i = -1; i <= 1; i++) {
			vec2 c = cell + vec2(float(i), float(j));
			float h1 = hash12(c + off);
			float h2 = hash12(c + off + 17.31);
			float h3 = hash12(c + off + 41.7);
			vec2 centre = c + 0.15 + 0.7 * vec2(h1, h2);
			vec2 at = centre / LEAF_CELLS * 2.0 - 1.0;
			// The fallen leaf's hash only where pollution has taken some: nine of them a pixel otherwise.
			if (dot(at, at) > 0.72 + 0.2 * h3 || (fallen > 0.0 && hash12(c + off + 71.3) < fallen)) {
				continue;
			}
			float a = h3 * 6.2831853;
			vec2 d = g - centre;
			d = vec2(d.x * cos(a) + d.y * sin(a), -d.x * sin(a) + d.y * cos(a));
			// A pointed leaf: a lens 0.6-0.85 cells long, widest in its middle.
			float len = 0.6 + 0.25 * h1;
			float wid = (0.26 + 0.1 * h2) * max(0.0, 1.0 - abs(d.x) / len);
			float v = 1.0 - (d.x * d.x) / (len * len) - (d.y * d.y) / max(wid * wid, 1e-4);
			if (v > cover) {
				cover = v;
				shade = 0.72 + 0.5 * hash12(c + off + 5.3);
			}
		}
	}
	if ((far_away > 0.0 ? mix(cover, disk, far_away) : cover) <= 0.0) {
		discard;
	}
	return mix(shade * (0.7 + 0.3 * sqrt(clamp(cover, 0.0, 1.0))), 0.95, far_away);
}

// leaf_cut's average shade over a spray: the atlas's leaves are drawn as bright on the whole.
const float LEAF_MEAN = 0.85;

// leaf_cut with Factorio's leaves (leaf_atlas): the card wears one of the atlas's patches, picked
// and turned a quarter at a time by its seed, cut where the patch has no leaf. One texture read
// where leaf_cut searches nine cells. Returns the leaves' colour factor. Far away, where a leaf
// would be a pixel or two, the same solid ragged spray as leaf_cut's; in the shadow pass that
// spray alone.
// `lod`: the atlas's mip a pixel takes (worked out at the top of fragment(), before any discard).
vec3 leaf_atlas_cut(vec2 uv, float seed, bool in_shadow, float dying, float lod) {
	if (dying >= 0.98) {
		discard;
	}
	float fallen = dying * 0.95;
	vec2 off = vec2(seed * 61.0, seed * 37.0);
	float far_away = clamp((lod - 1.0) * 0.8, 0.0, 1.0);
	float disk = 0.0;
	if (in_shadow || far_away > 0.0) {
		disk = 0.78 + 0.18 * hash12(floor(uv * 10.0) + off) - length(uv * 2.0 - 1.0) - 0.6 * fallen;
		if (in_shadow || far_away >= 1.0) {
			if (disk <= 0.0) {
				discard;
			}
			if (!in_shadow && fallen > 0.0 && hash12(floor(uv * 12.0) + off + 7.1) < fallen) {
				discard;
			}
			return in_shadow ? vec3(1.0) : vec3(LEAF_MEAN);
		}
	}
	float n = leaf_atlas_cells;
	float k = floor(fract(seed * 7.137) * n * n);
	float turn = floor(fract(seed * 3.71) * 4.0);
	vec2 t = uv - 0.5;
	t = turn < 0.5 ? t : (turn < 1.5 ? vec2(t.y, -t.x) : (turn < 2.5 ? -t : vec2(-t.y, t.x)));
	t = clamp(t + 0.5, 0.5 / leaf_atlas_texels, 1.0 - 0.5 / leaf_atlas_texels);
	vec2 auv = (vec2(mod(k, n), floor(k / n)) + t) / n;
	// Coarser mips would shrink the cut (their alpha averages leaves with gaps): the far spray
	// takes over instead.
	vec4 s = textureLod(leaf_atlas, auv, clamp(lod, 0.0, 1.5));
	// Leaves fallen to pollution: clumps of three texels, each by its own hash.
	if (fallen > 0.0 && hash12(floor(auv * n * leaf_atlas_texels / 3.0) + 7.1) < fallen) {
		discard;
	}
	if ((far_away > 0.0 ? mix(s.a - 0.5, disk, far_away) : s.a - 0.5) <= 0.0) {
		discard;
	}
	return LEAF_MEAN * mix(vec3(1.0), mix(vec3(1.0), s.rgb * 2.0, leaf_detail), 1.0 - far_away);
}
#endif

#ifdef ROBOT
// Flying robots (robot_swarm.gd: one MultiMesh per robot kind and part, so a thousand robots are
// a few draw calls). Each part's mesh is in model space at rest, as for movers' nodes; what
// vehicle_anim.gd did per robot happens here from INSTANCE_CUSTOM: r how much it flies (0-1),
// g its bob's phase (radians), b 1 while it carries cargo + 2 while it works (a construction
// robot hovering in place), a how far its arms reach (radians).
uniform int robot_part = 0;  // 0 body, 1 thrusters, 2 cargo lamp, 3 empty lamp, 4 nozzle, 5 arms
uniform vec3 robot_pivot = vec3(0.0);
uniform vec3 robot_axis = vec3(1.0, 0.0, 0.0);  // the pivot's east-west axis, model space
uniform float robot_bob = 0.035;
uniform float robot_bob_rate = 0.7;
const float ROBOT_SWING = -0.5;  // radians the thrusters swing back at full speed
const float ROBOT_WORK_FRAME = 1.0 / 18.0;  // working animation: 2 frames at 0.3 a tick
// vehicle_anim.gd's ROBOT_FULL_SPEED, WORK_STILL and ARMS_REACH: the record's robots (MOVER).
const float ROBOT_FULL_SPEED = 2.5;
const float ROBOT_WORK_STILL = 0.3;
const float ROBOT_ARMS_REACH = 0.6;

void robot_vertex(inout vec3 v, inout vec3 n, vec4 c, float time) {
	float flags = floor(c.b + 0.5);
	bool cargo = mod(flags, 2.0) > 0.5;
	bool working = flags > 1.5;
	if ((robot_part == 2 && !cargo) || (robot_part == 3 && cargo)) {
		v = vec3(0.0);  // the other lamp: nothing drawn
		return;
	}
	float angle = robot_part == 1 ? ROBOT_SWING * c.r : (robot_part == 5 ? c.a : 0.0);
	if (angle != 0.0) {
		vec3 a = robot_axis;
		vec3 p = v - robot_pivot;
		p = p * cos(angle) + cross(a, p) * sin(angle) + a * dot(a, p) * (1.0 - cos(angle));
		n = n * cos(angle) + cross(a, n) * sin(angle) + a * dot(a, n) * (1.0 - cos(angle));
		v = robot_pivot + p;
	}
	v.y += robot_bob * sin(time * robot_bob_rate * 6.2831853 + c.g);
}

float robot_glow(vec4 c, float time) {
	bool working = floor(c.b + 0.5) > 1.5;
	if (robot_part == 1) {
		return 0.3 + 0.7 * c.r;
	}
	if (robot_part == 4) {
		return working ? (mod(floor(time / ROBOT_WORK_FRAME), 2.0) < 0.5 ? 1.0 : 0.3) : 0.6;
	}
	return 1.0;
}
#endif

// Machines' moving parts and glow, worked out here from their state instead of by anim.gd every
// frame. A chunk's moving part (one MultiMesh per part of a model) is drawn at its entity's own
// transform and turned or slid here; anim.gd writes an instance's INSTANCE_CUSTOM only when its
// state changes (`st`, a robot or pod coming near, a strike). Such "timed" instances, and the
// glowing models' instances, have INSTANCE_CUSTOM.b < 0:
//   r  when the state last changed: seconds on the clock f3d_anim_time.x or .y (flag 2)
//   g  how far the part had got then: loops of its motion, or how far open (linear parts)
//   b  -(1 + flags + its speed then, 0-0.999); flags: 1 moving (working; open, lit), 2 on the .y
//      clock, 4 glowing (working)
//   a  how much it glowed then (lit parts: how brightly)
// The two clocks are seconds since the start of anim.gd's latest even and odd epochs, so they stay
// small (and precise) however long the game runs: anim.gd moves every state onto the newer clock
// before the older one starts again.
// anim_mode, per part material (anim.gd setup_part): 1 spinning (loops of a turn), 2 cycling
// (anim_wave 0 out and back, 1 either way of rest, 2 round; ModelLibrary.CYCLES), 3 rocking with
// a crank, 4 a piston (bob), 5 lit, 6 linear (doors, hatches, gates, the power switch: towards
// anim_open at anim_speed a second), 7 a light fading linearly (roboport charging points).
// Turning is about anim_axis in the pivot's frame (anim_pivot, the part node's transform);
// sliding (anim_slide not zero) moves by anim_slide per unit.
global uniform vec2 f3d_anim_time;
// The look's fill light on models (looks.gd "model_fill", 0 by night; off unless --model-fill=on or the debug
// menu's Camera fill, owner: models lit by the scene's sun and ambient alone): Factorio's sprites were
// rendered with light from the camera's side as well as their shadows' sun, so their fronts and
// tops read bright; one sun leaves a model's south faces in shade. Added as light on the model
// alone, so the ground and its shadows keep the sun's and the sky's.
global uniform float f3d_look_model_fill;
// looks.gd "ao_direct": the share of a model's occlusion (its own and SSAO's) that darkens its direct light (1: as Zenith
// draws it; the Cinematic look's 0: occlusion on indirect light only).
global uniform float f3d_look_ao_direct;
global uniform float f3d_look_roughness_min;  // looks.gd "roughness_min": no surface shinier (a look's choice)
// The same on a "pbr" pack's surfaces: 0 (they keep the roughness their files give), the look's with --pbr-rough=floor.
global uniform float f3d_look_roughness_min_pbr;
// The share of a modeller's metallic-roughness picture's metal drawn (looks.gd "texture_metal", 0.1 by
// default: as paint, the share part colours and textures without such a picture get; 1: in full, as before).
// Zenith's only thing for metal to reflect is the dim blue sky, so a picture's full metal read dark and blue.
global uniform float f3d_look_texture_metal;
// Packs' own shading (looks.gd pack_shading): 1 as each pack's pack.json says, 0 Factorio's everywhere
// (--pack-shading=factorio, Settings > Graphics > Advanced). And the look's balance on a "pbr" pack's
// pictures (looks.gd "texture_light": sides, tops; (1, 1) as Godot's material draws them).
global uniform float f3d_pack_shading;
global uniform vec2 f3d_look_texture_light;
// The share of a "pbr" pack's metal drawn (looks.gd "pbr_metal", 1 by default since pbr-standard step 3, with the
// neutral reflection, pbr_env.gdshaderinc, to reflect; --pbr-metal=0.1 is 0.2.2's).
global uniform float f3d_look_pbr_metal;
#include "res://shaders/pbr_env.gdshaderinc"
// Seconds the last frame took (belt_blur.gd): how far a belt's surface moves between two frames.
global uniform float f3d_frame_dt;
// The grain layers (nature_looks.gd): each a tile of a bark's or rock's picture at Factorio's own 64
// texels a tile, its colour over its own light a few texels round, halved; on once they are made.
global uniform sampler2DArray f3d_nature_grain;
global uniform float f3d_nature_grain_on;
// 1: trees' trunks and leaf cards (and rocks) matte, specular 0.05 and fully rough, so the sun low behind them
// leaves no white Fresnel sheen (as the ground plants, decorative_grass.gdshaderinc); 0: --tree-sheen=old.
global uniform float f3d_tree_matte;

// A layer's grain read from the three sides the surface faces most (model space, mirrored every
// tile so it never shows a seam), as a colour factor round 1.
vec3 nature_grain_at(float code, vec3 p, vec3 n, vec3 dx, vec3 dy) {
	float layer = floor(code) - 1.0;
	float strength = fract(code);
	vec3 w = n * n;
	w *= w;
	w /= max(w.x + w.y + w.z, 1e-5);
	vec3 sum = vec3(0.0);
	float used = 0.0;
	// x-facing: (z, down); up-facing: (x, z); z-facing: (x, down). Bark's streaks run up the trunk.
	vec2 q[3] = vec2[3](vec2(p.z, -p.y), p.xz, vec2(p.x, -p.y));
	vec2 qx[3] = vec2[3](vec2(dx.z, -dx.y), dx.xz, vec2(dx.x, -dx.y));
	vec2 qy[3] = vec2[3](vec2(dy.z, -dy.y), dy.xz, vec2(dy.x, -dy.y));
	for (int i = 0; i < 3; i++) {
		if (w[i] > 0.02) {
			vec2 m = 1.0 - abs(fract(q[i] * 0.5) * 2.0 - 1.0);
			sum += w[i] * textureGrad(f3d_nature_grain, vec3(m, layer), qx[i], qy[i]).rgb;
			used += w[i];
		}
	}
	vec3 g = sum / max(used, 1e-5) * 2.0;
	return mix(vec3(1.0), g, strength);
}
uniform int anim_mode = 0;
uniform int anim_wave = 0;
uniform float anim_rate = 0.0;
uniform float anim_amount = 1.0;
uniform vec3 anim_slide = vec3(0.0);
uniform vec3 anim_axis = vec3(0.0, 1.0, 0.0);
uniform mat4 anim_pivot = mat4(1.0);
uniform mat4 anim_unpivot = mat4(1.0);
uniform float anim_speed = 1.0;
uniform float anim_open = 1.0;
uniform bool anim_flicker = false;
uniform bool anim_strike = false;
// anim_mode 8, a modeller's baked (skeletal) animation (model_skin.gd): each bone's 3x4 matrix at each
// frame, 3 texels a bone and a row a frame; each vertex's four bones and weights in CUSTOM3.
uniform sampler2D bake_tex : filter_nearest;
uniform int bake_frames = 0;
// A bone whose axes turn further than acos(bake_snap) between two frames is shown at the nearer one, not
// mixed (model_skin.gd SNAP, shown()); -2 always mixes (--baked-anim=old).
uniform float bake_snap = 0.866;
// anim.gd's SPIN_UP, SPIN_DOWN, GLOW_UP, GLOW_DOWN, STRIKE_RISE, STRIKE_FADE (seconds).
const float ANIM_SPIN_UP = 0.35;
const float ANIM_SPIN_DOWN = 0.9;
const float ANIM_GLOW_UP = 0.25;
const float ANIM_GLOW_DOWN = 0.9;
const float ANIM_STRIKE_RISE = 0.4;
const float ANIM_STRIKE_FADE = 2.5;

// A timed instance's flags (floor) and speed then (the fraction).
float anim_flags(vec4 c, out float speed0) {
	float code = -c.b - 1.0;
	float flags = floor(code);
	speed0 = code - flags;
	return flags;
}

bool anim_bit(float flags, float bit) {
	return mod(floor(flags / bit), 2.0) > 0.5;
}

// Seconds since the instance's state last changed.
float anim_since(vec4 c, float flags) {
	return max((anim_bit(flags, 2.0) ? f3d_anim_time.y : f3d_anim_time.x) - c.r, 0.0);
}

// A lightning attractor's glow after a strike: up over STRIKE_RISE, then fading.
float anim_strike_level(float age) {
	return age < ANIM_STRIKE_RISE ? age / ANIM_STRIKE_RISE : exp(-(age - ANIM_STRIKE_RISE) / ANIM_STRIKE_FADE * 3.0);
}

// move_toward(from, to, step)
float anim_toward(float from, float to, float step) {
	return from + clamp(to - from, -step, step);
}

// How much a timed instance glows now (id: the instance's index, for the flicker).
float anim_glow(vec4 c, float id) {
	float s0;
	float flags = anim_flags(c, s0);
	float dt = anim_since(c, flags);
	if (anim_mode == 5) {
		float level = anim_strike ? anim_strike_level(dt) : c.a;
		if (anim_flicker) {
			float t = f3d_anim_time.x;
			level *= 0.7 + 0.3 * sin(t * 31.0 + id * 1.7) * sin(t * 11.0 + id);
		}
		return level;
	}
	if (anim_mode == 7) {
		return anim_toward(c.g, anim_bit(flags, 1.0) ? 1.0 : 0.0, anim_speed * dt);
	}
	float goal = anim_bit(flags, 4.0) ? 1.0 : 0.0;
	return goal + (c.a - goal) * exp(-dt / (goal > 0.5 ? ANIM_GLOW_UP : ANIM_GLOW_DOWN));
}

// The part turned by `angle` radians about its pivot: pivot * rotation * pivot^-1, the normal by
// that's inverse transpose (the pivot may be scaled).
void anim_turn(inout vec3 v, inout vec3 n, float angle) {
	vec3 a = anim_axis;
	float co = cos(angle);
	float si = sin(angle);
	vec3 p = (anim_unpivot * vec4(v, 1.0)).xyz;
	p = p * co + cross(a, p) * si + a * dot(a, p) * (1.0 - co);
	v = (anim_pivot * vec4(p, 1.0)).xyz;
	vec3 m = transpose(mat3(anim_pivot)) * n;
	m = m * co + cross(a, m) * si + a * dot(a, m) * (1.0 - co);
	n = transpose(mat3(anim_unpivot)) * m;
}

// A timed part's pose now (anim.gd's _pose and AnimPart.turned, as they were done per frame).
// Distance along a belt (tiles, -0.5 at the input edge to 0.5 at the output edge; a curve's arc) and
// across it from its middle line, in the model's own frame.
vec2 belt_coords(vec3 op) {
	float s = -op.z;
	float across = op.x;
	if (belt_shape > 0) {
		float side = belt_shape == 1 ? 1.0 : -1.0;
		vec2 d = op.xz - vec2(-0.5 * side, -0.5);
		s = atan(-d.y, d.x * side) / 1.5707963 + 0.5;
		across = length(d) - 0.5;
	}
	return vec2(s, across);
}

// How far (tiles) a belt's surface is smeared this frame: BELT_SHUTTER frames' travel (at least
// BELT_SMEAR_MIN of a slat period), faded in for steps that are a big share of the slats' period; 0
// for a slow or stopped belt.
float belt_smear(float speed, float dt) {
	float moved = abs(speed) * dt;
	return max(moved * BELT_SHUTTER, BELT_SMEAR_MIN * BELT_PERIOD)
		* smoothstep(BELT_SMEAR_FROM * BELT_PERIOD, BELT_SMEAR_TO * BELT_PERIOD, moved);
}

// The integral of smoothstep(a, b, fract(t)) from 0 to x: box-filtering the belt's periodic
// profiles is the difference of two of these over the width.
float smoothstep_integral(float a, float b, float x) {
	float whole = floor(x);
	float p = x - whole;
	float u = clamp((p - a) / (b - a), 0.0, 1.0);
	return whole * (1.0 - 0.5 * (a + b)) + (b - a) * (u * u * u - 0.5 * u * u * u * u) + max(p - b, 0.0);
}

// The integral of the slats' shade (0.45 slat - 0.45 seam - 0.12, as fragment() draws it) over
// phase 0 to x. The slat is smoothstep(0, 0.08) - smoothstep(0.62, 0.78) on [0, 1), the seam one
// minus smoothstep(0, 0.06) - smoothstep(0.9, 1).
float belt_slat_integral(float x) {
	return 0.45 * (smoothstep_integral(0.0, 0.08, x) - smoothstep_integral(0.62, 0.78, x))
		- 0.45 * (x - smoothstep_integral(0.0, 0.06, x) + smoothstep_integral(0.9, 1.0, x)) - 0.12 * x;
}

// The integral of the chevron's stroke across `d` (distance from its middle line, half width h,
// edges smoothstepped over aa), from far before it to d; and of the next chevron, `period` on.
float belt_stroke_ramp(float x, float aa) {
	float u = clamp((x + aa) / (2.0 * aa), 0.0, 1.0);
	return 2.0 * aa * (u * u * u - 0.5 * u * u * u * u) + max(x - aa, 0.0);
}
float belt_stroke_integral(float d, float h, float aa, float period) {
	float next = d - period;
	return belt_stroke_ramp(d + h, aa) - belt_stroke_ramp(d - h, aa)
		+ belt_stroke_ramp(next + h, aa) - belt_stroke_ramp(next - h, aa);
}

// A bone's matrix at frame f (rows from bake_tex).
mat4 bake_bone(int bone, int f) {
	vec4 r0 = texelFetch(bake_tex, ivec2(bone * 3, f), 0);
	vec4 r1 = texelFetch(bake_tex, ivec2(bone * 3 + 1, f), 0);
	vec4 r2 = texelFetch(bake_tex, ivec2(bone * 3 + 2, f), 0);
	return mat4(vec4(r0.x, r1.x, r2.x, 0.0), vec4(r0.y, r1.y, r2.y, 0.0), vec4(r0.z, r1.z, r2.z, 0.0),
		vec4(r0.w, r1.w, r2.w, 1.0));
}

// The cosine of the largest turn of a's axes to b's; 1 for an axis scaled to nothing at either end
// (model_skin.gd turned()).
float bake_turned(mat4 a, mat4 b) {
	float c = 1.0;
	for (int i = 0; i < 3; i++) {
		float l = length(a[i].xyz) * length(b[i].xyz);
		if (l > 1e-8) {
			c = min(c, dot(a[i].xyz, b[i].xyz) / l);
		}
	}
	return c;
}

// The baked animation: the machine's clock (as a spinning part's: easing up while it works, coasting
// to a stop) says how many loops of the action have gone; the vertex is skinned by its bones there,
// blended between the two frames around it (a bone turning fast between them: the nearer frame).
void anim_baked(inout vec3 v, inout vec3 n, vec4 c, vec4 skin) {
	float s0;
	float flags = anim_flags(c, s0);
	bool on = anim_bit(flags, 1.0);
	float dt = anim_since(c, flags);
	float fr;
	if (anim_mode == 9) {
		fr = clamp(anim_toward(c.g, on ? anim_open : 0.0, anim_speed * dt), 0.0, 1.0) * float(bake_frames - 1);
	} else {
		float goal = on ? 1.0 : 0.0;
		float tau = on ? ANIM_SPIN_UP : ANIM_SPIN_DOWN;
		float e = exp(-dt / tau);
		float loops = c.g + anim_rate * (goal * dt + (s0 - goal) * tau * (1.0 - e));
		fr = fract(loops) * float(bake_frames - 1);
	}
	int f0 = int(floor(fr));
	int f1 = min(f0 + 1, bake_frames - 1);
	float u = fr - float(f0);
	mat4 m = mat4(0.0);
	float total = 0.0;
	for (int k = 0; k < 4; k++) {
		float code = skin[k];
		float w = fract(code) / 0.999;
		if (w <= 0.0) {
			continue;
		}
		int bone = int(floor(code));
		mat4 a = bake_bone(bone, f0);
		mat4 b = bake_bone(bone, f1);
		float ub = bake_turned(a, b) < bake_snap ? step(0.5, u) : u;
		m += w * ((1.0 - ub) * a + ub * b);
		total += w;
	}
	if (total <= 0.0) {
		return;
	}
	m /= total;
	v = (m * vec4(v, 1.0)).xyz;
	n = normalize(mat3(m) * n);
}

void anim_vertex(inout vec3 v, inout vec3 n, vec4 c) {
	float s0;
	float flags = anim_flags(c, s0);
	bool on = anim_bit(flags, 1.0);
	float dt = anim_since(c, flags);
	if (anim_mode == 5) {
		// Hidden: shrunk to nothing at the model's origin, inside the body (ModelLibrary.HIDDEN).
		if (!on || (anim_strike && anim_strike_level(dt) <= 0.02)) {
			v *= 0.001;
		}
		return;
	}
	if (anim_mode == 7) {
		return;
	}
	float x = 0.0;
	if (anim_mode == 6) {
		x = anim_toward(c.g, on ? anim_open : 0.0, anim_speed * dt) * anim_amount;
	} else {
		// The machine's speed eases towards full while it works and coasts to a stop when not;
		// how far the part has gone is that speed's integral since the change.
		float goal = on ? 1.0 : 0.0;
		float tau = on ? ANIM_SPIN_UP : ANIM_SPIN_DOWN;
		float e = exp(-dt / tau);
		float speed = goal + (s0 - goal) * e;
		float loops = c.g + anim_rate * (goal * dt + (s0 - goal) * tau * (1.0 - e));
		if (anim_mode == 1) {
			x = fract(loops) * 6.2831853;
		} else if (anim_mode == 2) {
			if (anim_wave == 1) {
				x = sin(loops * 6.2831853);
			} else if (anim_wave == 2) {
				x = fract(loops);
			} else {
				x = 0.5 - 0.5 * cos(loops * 6.2831853);
			}
			x *= anim_amount;
		} else if (anim_mode == 3) {
			x = anim_amount * sin(loops * 6.2831853);
		} else {
			x = (0.5 - 0.5 * cos(loops * 6.2831853)) * min(speed * 3.0, 1.0);
		}
	}
	if (any(notEqual(anim_slide, vec3(0.0)))) {
		v += anim_slide * x;
	} else {
		anim_turn(v, n, x);
	}
}

// A point turned about a unit axis through the origin (Rodrigues).
vec3 rig_turn(vec3 p, vec3 a, float angle) {
	float c = cos(angle);
	float s = sin(angle);
	return p * c + cross(a, p) * s + a * dot(a, p) * (1.0 - c);
}

void vertex() {
	vec4 icustom = INSTANCE_CUSTOM;
#ifdef MOVER
	// Movers interpolated here from their record (mover_records.gdshaderinc). Robots always have
	// one (their slot in INSTANCE_CUSTOM.r); creatures walking have theirs in b (slot + 1), while
	// creatures posed by creatures.gd (attacking, dying) are drawn at their instance transform as
	// before. What creatures.gd and robot_swarm.gd used to write per instance every frame
	// (INSTANCE_CUSTOM) is worked out from the record into icustom.
#ifdef ROBOT
	bool mover = true;
	int mover_slot = int(INSTANCE_CUSTOM.r + 0.5);
#else
	bool mover = INSTANCE_CUSTOM.b > 0.5;
	int mover_slot = int(INSTANCE_CUSTOM.b - 0.5);
#endif
	bool mover_xformed = mover && INSTANCE_CUSTOM.g > 0.5;
	float mover_bob = 0.0;
	MoverState ms;
	if (mover) {
		ms = mover_state(mover_slot);
#ifdef ROBOT
		// How much it flies, its bob, cargo and working flags and its arms' reach, as robot_swarm.gd
		// worked them out: flying eases at 3 a second towards its speed, a construction robot
		// standing still for ROBOT_WORK_STILL works, its arms easing out and back at 3 radians a second.
		float amount = 0.0;
		float reach = 0.0;
		float flags = 0.0;
		bool animates = mover_flag(ms.flags, 16.0);
		if (animates) {
			amount = mover_toward(ms.carried.z, clamp(ms.speed / ROBOT_FULL_SPEED, 0.0, 1.0), 3.0 * ms.since);
			bool working = mover_flag(ms.flags, 4.0) && (!mover_flag(ms.flags, 32.0) || mover_flag(ms.flags, 64.0)) && ms.still > ROBOT_WORK_STILL;
			if (working) {
				float began = max(ms.since - (ms.still - ROBOT_WORK_STILL), 0.0);
				reach = mover_toward(mover_toward(ms.carried.w, 0.0, 3.0 * began), ROBOT_ARMS_REACH, 3.0 * (ms.since - began));
			} else {
				reach = mover_toward(ms.carried.w, 0.0, 3.0 * ms.since);
			}
			flags = (mover_flag(ms.flags, 8.0) ? 1.0 : 0.0) + (working ? 2.0 : 0.0);
		}
		icustom = vec4(amount, animates ? ms.kind.x : 0.0, flags, reach);
#else
		// The gait's phase from the distance walked (a loop of legs per kind.y radians a tile) and a
		// slow idle loop; its strength from its speed over the last few ticks; the body's bob.
		float phase = ms.kind.x + ms.kind.y * ms.walked + 0.15 * 6.2831853 * f3d_mover_clock.w;
		float gait = clamp(ms.average / 1.5, 0.0, 1.0);
		float bob = abs(sin(phase)) * 0.025 * gait * ms.kind.z;
		if (mover_xformed) {
			mover_bob = bob;
		} else {
			ms.pos.y += bob;
		}
		icustom = vec4(phase, max(gait, 0.15), 0.0, 1.0);
#endif
	}
#endif
	obj_pos = VERTEX;
	obj_normal = NORMAL;
	part_col = CUSTOM1;
	// The table isn't read here (the shadow and depth passes run this for every vertex): the
	// instance's glow is worked out for the model, and each row takes it or not in fragment().
	mat_row = material_rows > 0 ? clamp(int(CUSTOM2.r + 0.5), 0, material_rows - 1) : -1;
	bool glows = activity_glow;
	world_y = (MODEL_MATRIX * vec4(VERTEX, 1.0)).y;
	// One value per instance: a MultiMesh instance's MODEL_MATRIX is its own transform. Parts
	// turned by anim.gd take the entity's position and direction from INSTANCE_CUSTOM instead;
	// timed ones (moved here) are drawn at the entity's own transform.
	bool timed = INSTANCE_CUSTOM.b < -0.5 && rig_mode != 1 && rig_mode != 2 && rig_mode != 4;
	bool from_custom = animated && !timed;
	float off_speed;
	belt_off = (timed ? anim_bit(anim_flags(INSTANCE_CUSTOM, off_speed), 8.0) : abs(INSTANCE_CUSTOM.b - BELT_OFF) < 0.5) ? 1.0 : 0.0;
	vec2 origin = from_custom ? INSTANCE_CUSTOM.rg : MODEL_MATRIX[3].xz;
	if (f3d_seed_at.y > 0.5) {
		origin = f3d_seed_at.xz;
	}
	belt_parity = mod(floor(origin.x) + floor(origin.y), 2.0);
	inst_seed = hash12(origin * 3.17 + 0.5);
#ifdef MOVER
	if (mover) {
		inst_seed = fract(ms.kind.x * 0.1591549 + 0.37);  // its own, not where it happens to be
	}
#endif
	// Live wounded creatures (creatures.gd / anim.gd): packed into negative INSTANCE_CUSTOM.b so it
	// never collides with GPU-walker slot encoding (> 0.5) or timed machine animations.
	v_wound = vec2(0.0);
#ifndef ROBOT
	bool wound_rig = rig_mode == 1 || rig_mode == 2 || rig_mode == 4;
#ifdef MOVER
	if (wound_rig && !mover && icustom.b < -0.5) {
		float wpack = -icustom.b - 1.0;
		float whits = clamp(floor(wpack * 0.5 + 1e-4), 0.0, 8.0);
		float wblood = clamp(wpack - whits * 2.0, 0.0, 1.0);
		v_wound = vec2(wblood, whits);
	}
#else
	if (wound_rig && icustom.b < -0.5) {
		float wpack = -icustom.b - 1.0;
		float whits = clamp(floor(wpack * 0.5 + 1e-4), 0.0, 8.0);
		float wblood = clamp(wpack - whits * 2.0, 0.0, 1.0);
		v_wound = vec2(wblood, whits);
	}
#endif
#endif
#ifdef LEAF_CUT
	// Pollution where the tree stands (scripts/world/pollution.gd), each tree a little ahead of or
	// behind its neighbours, as Factorio's trees in one chunk don't all lose their leaves at once.
	leaf_dying = clamp(pollution_at(origin).x * 1.3 - 0.3 * inst_seed, 0.0, 1.0);
	// One of the prototype's colours per tree, by where it stands (not tied to its pollution lag).
	leaf_tint = vec3(1.0);
	if (leaf_tint_count > 0) {
		leaf_tint = leaf_tints[clamp(int(fract(inst_seed * 13.37 + 0.21) * float(leaf_tint_count)), 0, leaf_tint_count - 1)];
	}
#endif
	activity = glows && rig_mode != 4 ? clamp(f3d_glow >= 0.0 ? f3d_glow
		: (timed ? anim_glow(INSTANCE_CUSTOM, float(INSTANCE_ID)) : icustom.a), 0.0, 1.0) : 1.0;
#ifdef ROBOT
	activity = glows ? robot_glow(icustom, F3D_TIME) : 1.0;
#endif

	// Creatures' limbs: weathering stays painted on the limb as it moves.
	if (rig_mode == 4) {
		float h = max(worm_height, 0.01);
		float state = INSTANCE_CUSTOM.a;
		float raised = clamp(state, 0.0, 1.0);
		float attack = clamp(state - 1.0, 0.0, 1.0);
		// How much of the neck a point is: none at the ground ring, all of it at the head.
		float t = smoothstep(0.06 * h, 0.9 * h, VERTEX.y) * (1.0 - smoothstep(0.3 * h, 0.55 * h, length(VERTEX.xz)));
		// Factorio's prepared loop: 9 frames forward then back, each way 1 / 0.024 ticks (0.7 Hz).
		float phase = F3D_TIME * 0.72 * 6.2831853 + inst_seed * 6.2831853;
		// Factorio's alternative idle (prepared_alternative_animation: 17 frames at 0.014, on a fifth of
		// its loops): the head thrown back, horns spread and the mouth wide, then back. Here each worm's
		// time runs in slots of that length, a fifth of them (by the slot and the worm) playing it.
		float slot = (F3D_TIME + inst_seed * 37.0) / WORM_ALT_SECONDS;
		float alt_on = step(fract(sin(floor(slot) * 12.9898 + inst_seed * 78.233) * 43758.5453), WORM_ALT_CHANCE);
		float alt = alt_on * sin(fract(slot) * 3.14159265) * raised * (1.0 - attack);
		// The head (horns round the mouth): closed over it folded, opening as it rises (Factorio's
		// preparing frames), spread further in the alternative idle and while it spits.
		float crown = smoothstep(0.78 * h, 0.98 * h, VERTEX.y);
		float open = mix(0.78, 1.0, raised) + 0.22 * alt + 0.1 * attack;
		// Folded: the neck sinks into the hole, leaving the head's crown above the ground.
		vec3 p = VERTEX;
		p.xz *= 1.0 + crown * (open - 1.0);
		p.y += crown * alt * 0.04 * h;
		p.y -= (1.0 - raised) * t * (p.y - 0.05 * h) * 0.82;
		p.xz *= 1.0 + (1.0 - raised) * t * 0.25;
		// Swaying while prepared. Attacking, it strikes forward over the starting attack and holds
		// the head out while it spits its stream (a 4-tick cooldown), heaving a little with it.
		// Factorio's lunge (worm-attack, last frames) bends it over until the mouth faces the
		// target, the head about a third of its height off the ground: about a radian at the top.
		float spit = sin(F3D_TIME * 15.0 + inst_seed * 6.2831853);
		float bend = raised * (0.07 * sin(phase) * (1.0 - attack) + attack * (0.95 + 0.04 * spit)) - 0.12 * alt;
		float side = raised * 0.06 * sin(phase * 0.71 + 1.3);
		float a = bend * t * t;
		float b = side * t * t;
		vec3 n = NORMAL;
		// Forwards (towards -Z) about the X axis through the base, then sideways about Z.
		p = vec3(p.x, p.y * cos(a) + p.z * sin(a), -p.y * sin(a) + p.z * cos(a));
		n = vec3(n.x, n.y * cos(a) + n.z * sin(a), -n.y * sin(a) + n.z * cos(a));
		p = vec3(p.x * cos(b) - p.y * sin(b), p.x * sin(b) + p.y * cos(b), p.z);
		n = vec3(n.x * cos(b) - n.y * sin(b), n.x * sin(b) + n.y * cos(b), n.z);
		VERTEX = p;
		NORMAL = n;
	} else if (rig_mode == 3) {
		float code = round(UV.x);
		int a = int(mod(code, 16.0)) * 3;
		int b = int(floor(code / 16.0 + 0.01)) * 3;
		vec4 v = vec4(VERTEX, 1.0);
		vec3 pa = vec3(dot(rig_bone[a], v), dot(rig_bone[a + 1], v), dot(rig_bone[a + 2], v));
		vec3 pb = vec3(dot(rig_bone[b], v), dot(rig_bone[b + 1], v), dot(rig_bone[b + 2], v));
		vec4 n = vec4(NORMAL, 0.0);
		vec3 na = vec3(dot(rig_bone[a], n), dot(rig_bone[a + 1], n), dot(rig_bone[a + 2], n));
		vec3 nb = vec3(dot(rig_bone[b], n), dot(rig_bone[b + 1], n), dot(rig_bone[b + 2], n));
		VERTEX = mix(pb, pa, UV.y);
		NORMAL = normalize(mix(nb, na, UV.y));
	} else if (rig_mode == 5) {
		if (UV.x > 0.5) {
			int i = clamp(int(UV.x + 0.5) - 1, 0, 11);
			vec4 rd = rig_ragdoll[i];
			if (rd.w > 50.0) {
				VERTEX = rig_joint[i];
			} else if (UV.y > 0.0) {
				float swing = rd.x;
				float lift = rd.y;
				float knee = rd.z;
				float twist = rd.w;
				vec3 p = VERTEX - rig_joint[i];
				vec3 nn = NORMAL;
				vec3 a = rig_lift[i];
				vec4 kp = rig_knee[i];
				if (kp.w > 0.0 && knee != 0.0) {
					vec3 k = kp.xyz - rig_joint[i];
					float fold = knee * smoothstep(0.45 * kp.w, 0.57 * kp.w, length(p));
					p = k + rig_turn(p - k, a, fold);
					nn = rig_turn(nn, a, fold);
				}
				p = rig_turn(p, a, lift * UV.y);
				nn = rig_turn(nn, a, lift * UV.y);
				a = rig_swing[i];
				p = rig_turn(p, a, swing * UV.y);
				nn = rig_turn(nn, a, swing * UV.y);
				if (abs(twist) > 0.0001) {
					vec3 tw_raw = cross(rig_swing[i], rig_lift[i]);
					float tw_len = length(tw_raw);
					if (tw_len > 0.0001) {
						vec3 tw = tw_raw / tw_len;
						p = rig_turn(p, tw, twist * UV.y);
						nn = rig_turn(nn, tw, twist * UV.y);
					}
				}
				VERTEX = rig_joint[i] + p;
				NORMAL = nn;
			}
		}
	} else if (rig_mode > 0) {
		// A walker biting, spitting or dying blends its legs into that pose (rig_pose) and leaves
		// its walk's rest bend.
		int pose = -1;
		float pose_k = 0.0;
		if (rig_mode == 1 && icustom.a > 1.5) {
			float code = icustom.a - 2.0;
			pose = clamp(int(floor(code)), 0, RIG_POSES - 1);
			pose_k = clamp(fract(code) / RIG_POSE_SCALE, 0.0, 1.0);
		}
		if (UV.x > 0.5 && UV.y > 0.0) {
			int i = clamp(int(UV.x + 0.5) - 1, 0, 11);
			float phase = rig_mode == 1 ? icustom.r : F3D_TIME * rig_rate * 6.2831853 + inst_seed * 6.2831853;
			float gait = rig_mode == 1 ? clamp(icustom.g, 0.0, 1.0) : 1.0;
			vec4 g = rig_gait[i];
			vec4 bend = rig_bend[i];
			float s = sin(phase + g.x);
			float up = max(0.0, cos(phase + g.x));
			// Swung forward and back; lifted and folded at the knee while it steps.
			float swing = g.y * s * gait;
			float lift = bend.z + g.z * up * gait;
			float knee = bend.x + bend.y * up * gait;
			if (pose >= 0) {
				vec4 at = rig_pose[pose * 12 + i];
				swing = mix(swing, at.x, pose_k);
				lift = mix(lift, at.y, pose_k);
				knee = mix(knee, at.z, pose_k);
			}
			vec3 p = VERTEX - rig_joint[i];
			vec3 nn = NORMAL;
			vec3 a = rig_lift[i];
			vec4 kp = rig_knee[i];
			if (kp.w > 0.0 && knee != 0.0) {
				vec3 k = kp.xyz - rig_joint[i];
				float fold = knee * smoothstep(0.45 * kp.w, 0.57 * kp.w, length(p));
				p = k + rig_turn(p - k, a, fold);
				nn = rig_turn(nn, a, fold);
			}
			p = rig_turn(p, a, lift * UV.y);
			nn = rig_turn(nn, a, lift * UV.y);
			a = rig_swing[i];
			p = rig_turn(p, a, swing * UV.y);
			nn = rig_turn(nn, a, swing * UV.y);
			VERTEX = rig_joint[i] + p * (1.0 + g.w * (0.5 + 0.5 * s) * UV.y);
			NORMAL = nn;
		}
		if (rig_mode == 1 && rig_body != vec3(0.0)) {
			// Standing on its bent legs: the whole model raised and pitched as creature_gait.py fitted
			// it, gone in a pose (whose body creatures.gd turns).
			float k = 1.0 - pose_k;
			vec3 pivot = vec3(0.0, rig_body.z, 0.0);
			VERTEX = pivot + rig_turn(VERTEX - pivot, vec3(1.0, 0.0, 0.0), rig_body.y * k);
			NORMAL = rig_turn(NORMAL, vec3(1.0, 0.0, 0.0), rig_body.y * k);
			VERTEX.y += rig_body.x * k;
		}
	}
	// Machines' moving parts, also after the sprite was projected from the rest pose.
	if ((anim_mode == 8 || anim_mode == 9) && timed) {
		anim_baked(VERTEX, NORMAL, INSTANCE_CUSTOM, CUSTOM3);
		world_y = (MODEL_MATRIX * vec4(VERTEX, 1.0)).y;
	} else if (anim_mode > 0 && timed) {
		anim_vertex(VERTEX, NORMAL, INSTANCE_CUSTOM);
		world_y = (MODEL_MATRIX * vec4(VERTEX, 1.0)).y;
	}
#ifdef ROBOT
	robot_vertex(VERTEX, NORMAL, icustom, F3D_TIME);
#endif
#ifdef MOVER
	if (mover) {
		if (mover_xformed) {
			if (mover_flag(ms.flags, 2.0)) {
				VERTEX = vec3(0.0);
			} else {
				VERTEX.y += mover_bob;
			}
		} else {
			mover_place(VERTEX, NORMAL, ms, MODEL_MATRIX[3].xyz);
		}
		world_y = (MODEL_MATRIX * vec4(VERTEX, 1.0)).y;
	}
#endif
#ifdef RAGDOLL_DECAY
	if (rig_decay > 0.001) {
		vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
		float flat_k = smoothstep(0.20, 0.85, rig_decay);
		wp.y = mix(wp.y, rig_decay_floor + 0.03, flat_k * 0.78);
		mat4 inv_m = inverse(MODEL_MATRIX);
		VERTEX = (inv_m * vec4(wp, 1.0)).xyz;
		vec3 local_up = normalize((inv_m * vec4(0.0, 1.0, 0.0, 0.0)).xyz);
		NORMAL = normalize(mix(NORMAL, local_up, flat_k * 0.45));
	}
#endif
	// The ground's height under every vertex (ground_height.gdshaderinc), last, so moving parts, rigs and
	// movers all ride on it. world_y stays the height over the ground (weathering reads it).
	world_xz = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xz;
#ifdef LEAF_CUT
	if (leaf_dying >= 0.98) {
		VERTEX = vec3(0.0);
	} else {
		VERTEX = ground_low && cliff_wall ? ground_lift_cliff_wall(VERTEX, MODEL_MATRIX) : ground_lift_low(VERTEX, MODEL_MATRIX, ground_low);
	}
#elif !defined(RAGDOLL_DECAY)
	if (rig_mode != 5) {
		bool rigid = ground_rigid;
		vec2 rigid_at = f3d_lift_at.y > 0.0 ? f3d_lift_at.xz : MODEL_MATRIX[3].xz;
#ifdef MOVER
		rigid = true;
		if (mover && !mover_xformed) {
			rigid_at = ms.pos.xz;  // placed from its record: the model's origin isn't the walker's
		}
#endif
		if (rigid && f3d_mover_rigid > 0.5) {
			VERTEX = ground_lift_rigid(VERTEX, MODEL_MATRIX, rigid_at);
		} else {
			VERTEX = ground_low && cliff_wall ? ground_lift_cliff_wall(VERTEX, MODEL_MATRIX) : ground_lift_low(VERTEX, MODEL_MATRIX, ground_low);
		}
	}
#endif
}

// With MSAA a pixel only partly covered by a triangle is shaded once, at a point that can lie outside the
// triangle, and Godot has no `centroid` qualifier: varyings there are extrapolated past their real range. A
// normal can land on zero and a colour go negative, and one NaN or infinity shows as a dark speck on the
// edge, on every model and worst far away, where most of a building is edges. So nothing leaves unchecked.
vec3 f3d_finite(vec3 v, vec3 fallback) {
	return (any(isnan(v)) || any(isinf(v))) ? fallback : v;
}

float f3d_finite1(float v, float fallback) {
	return (isnan(v) || isinf(v)) ? fallback : v;
}

#ifdef RAGDOLL_DECAY
float f3d_decay_hash(vec3 p) {
	p = fract(p * 0.3183099 + vec3(0.1, 0.2, 0.3));
	p *= 17.0;
	return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

float f3d_decay_noise(vec3 x) {
	vec3 i = floor(x);
	vec3 f = fract(x);
	f = f * f * (3.0 - 2.0 * f);
	float n00 = mix(f3d_decay_hash(i + vec3(0.0, 0.0, 0.0)), f3d_decay_hash(i + vec3(1.0, 0.0, 0.0)), f.x);
	float n10 = mix(f3d_decay_hash(i + vec3(0.0, 1.0, 0.0)), f3d_decay_hash(i + vec3(1.0, 1.0, 0.0)), f.x);
	float n01 = mix(f3d_decay_hash(i + vec3(0.0, 0.0, 1.0)), f3d_decay_hash(i + vec3(1.0, 0.0, 1.0)), f.x);
	float n11 = mix(f3d_decay_hash(i + vec3(0.0, 1.0, 1.0)), f3d_decay_hash(i + vec3(1.0, 1.0, 1.0)), f.x);
	return mix(mix(n00, n10, f.y), mix(n01, n11, f.y), f.z);
}
#endif

void fragment() {
#ifdef LEAF_CUT
	vec2 uv_dx = dFdx(UV);
	vec2 uv_dy = dFdy(UV);
	float leaf_lod = log2(max(max(length(uv_dx), length(uv_dy)) * leaf_atlas_texels, 1e-4));
	float leaf_fw = max(abs(uv_dx.x) + abs(uv_dy.x), abs(uv_dx.y) + abs(uv_dy.y)) * LEAF_CELLS;
#else
	// How far the model's surface moves in a pixel, for the noise (first: a discard below would
	// leave neighbouring pixels' derivatives undefined).
	vec3 obj_step = fwidth(obj_pos);
	float pixel = max(obj_step.x, max(obj_step.y, obj_step.z));
	// The bark's and rock's grain is read along the three axes (nature_grain): their derivatives too.
	vec3 obj_dx = dFdx(obj_pos);
	vec3 obj_dy = dFdy(obj_pos);
#endif
	// A level of detail cross-fading (f3d_lod_fade): a 4x4 Bayer screen door. Shadows stay whole
	// (the level fading out casts none).
	if (f3d_lod_fade != 1.0 && !IN_SHADOW_PASS) {
		int bx = int(FRAGCOORD.x) & 3;
		int by = int(FRAGCOORD.y) & 3;
		int ba = bx ^ by;
		int bayer = ((ba & 1) << 3) | ((by & 1) << 2) | (ba & 2) | ((by & 2) >> 1);
		float d = (float(bayer) + 0.5) / 16.0;
		if (f3d_lod_fade < 1.5 ? d >= f3d_lod_fade : d < f3d_lod_fade - 2.0) {
			discard;
		}
	}
#ifdef LEAF_CUT
	float leaf_shade = 1.0;
	vec3 leaf_rgb = vec3(1.0);
	// What this surface is: a crown's dark core (leaf_core, or UV -1 where the cores share the
	// cards' merged surface), solid leaves (UV -2: tree-06's strands) or leaf cards (UV 0-1; the
	// models' layout, tools/models/nature/plain_geo.py).
	float leaf_kind = leaf_core ? 1.0 : (UV.x < -1.5 ? 2.0 : (UV.x < -0.5 ? 1.0 : 0.0));
	if (leaf_kind > 0.5) {
		// Thins out with the leaves round it, a 4x4 screen door (as the levels' cross-fade): a core
		// is gone before the crown is bare, solid leaves as the last leaves fall; their shadow goes
		// at once half way.
		float gone = leaf_kind > 1.5 ? smoothstep(0.05, 0.95, leaf_dying) : smoothstep(0.1, 0.6, leaf_dying);
		if (IN_SHADOW_PASS) {
			if (gone >= 0.5) {
				discard;
			}
		} else if (gone > 0.0) {
			int cx = int(FRAGCOORD.x) & 3;
			int cy = int(FRAGCOORD.y) & 3;
			int ca = cx ^ cy;
			int cb = ((ca & 1) << 3) | ((cy & 1) << 2) | (ca & 2) | ((cy & 2) >> 1);
			if ((float(cb) + 0.5) / 16.0 < gone) {
				discard;
			}
		}
	} else if (leaf_atlas_cells > 0.0) {
		leaf_rgb = leaf_atlas_cut(UV, UV2.y, IN_SHADOW_PASS, leaf_dying, leaf_lod);
	} else {
		leaf_shade = leaf_cut(UV, UV2.y, IN_SHADOW_PASS, leaf_dying, leaf_fw);
	}
	// Both sides are drawn and lit by the crown's normal the card carries (Godot flips it on the
	// back side: flipped back).
	if (!FRONT_FACING) {
		NORMAL = -NORMAL;
	}
#endif
#ifdef ALPHA_CLIP
	if (clip_one_side && modeller_tex && f3d_pack_shading > 0.5 && !FRONT_FACING) {
		discard;
	}
#endif
	// A merged surface has every vertex array (material_rows): its data flags are all on.
	bool merged = mat_row >= 0;
	float vertex_on = merged ? 1.0 : vertex_data;
	float edge_on = merged ? 1.0 : edge_data;
	vec3 n = dot(obj_normal, obj_normal) > 1e-10 ? normalize(obj_normal) : vec3(0.0, 1.0, 0.0);
	float ao = mix(1.0, clamp(COLOR.a, 0.0, 1.0), vertex_on);
	vec3 tint = mix(vec3(1.0), max(COLOR.rgb, vec3(0.0)), vertex_on);
	float edge = UV2.x * edge_on;
	float part = mix(0.5, UV2.y, edge_on);
	// How dirty this instance and this part are.
	float dirt = 0.75 + 0.5 * inst_seed;
#ifdef LEAF_CUT
	// Foliage cards skip the 3D weathering noise: they wear ground grime only and draw up to a dozen
	// layers deep per crown.
	float patches = 0.5;
	float fine = 0.5;
	float mid = 0.5;
#else
	vec3 p = obj_pos + vec3(inst_seed * 37.0, 0.0, inst_seed * 53.0) + part * 11.0;

	float patches = fbm3d(p * 2.3, pixel * 2.3);
	float fine = vnoise3_fading(p * 23.0, pixel * 23.0);
	float mid = vnoise3(p * 7.0 + 5.0);
#endif
	// This fragment's material: the uniforms, or its row of the model's table (material_rows).
	vec4 m_albedo = albedo;
	vec3 m_emission = emission * emission_energy;
	bool m_glow = activity_glow;
	bool m_fades = glow_fades;
	bool m_belt = belt_speed != 0.0;
	float m_rough = roughness;
	float m_metal = metallic;
	float m_edge_metal = edge_metallic;
	float m_ground_height = ground_grime_height;
	float m_part = part_colors ? part_data : 0.0;
	float m_flicker = glow_flicker;
	float m_pulse = glow_pulse;
	float m_rate = glow_rate;
	float m_ao = ao_strength;
	vec4 m_wear = part_weathering;
	float m_streaks = streaks;
	float m_desat = desaturate;
	float m_value = value;
	float m_grain = grain;
	float m_nature = nature_grain;
	vec2 m_light = part_light;
	vec4 m_grime = vec4(grime_color, grime);
	vec4 m_edge = vec4(edge_color, edge_wear);
	vec4 m_rust = vec4(rust_color, rust);
	vec4 m_dust = vec4(dust_color, dust);
	int m_skin = skin_mode;
	vec4 m_tint2 = skin_tint2;
	bool m_paint_glow = emission_from_paint;
	bool m_keep_albedo = glow_keeps_albedo;
	bool m_modeller_tex = modeller_tex;
	bool m_wet_rock = wet_rock;
	int m_organic = organic_surface;
	if (merged) {
		int r = mat_row * MATERIAL_ROW;
		m_albedo = material_table[r];
		vec4 e = material_table[r + 1];
		m_emission = e.rgb;
		m_skin = (row_flag(e.w, 16.0) ? 1 : 0) + (row_flag(e.w, 32.0) ? 2 : 0);
		m_paint_glow = row_flag(e.w, 64.0);
		m_keep_albedo = row_flag(e.w, 128.0);
		m_modeller_tex = row_flag(e.w, 256.0);
		m_wet_rock = row_flag(e.w, 512.0);
		m_organic = (row_flag(e.w, 1024.0) ? 1 : 0) + (row_flag(e.w, 2048.0) ? 2 : 0);
		if (m_skin > 0) {
			m_tint2 = vec4(m_skin == 1 ? e.rgb : vec3(0.0), material_table[r + 5].w);
			m_emission = vec3(0.0);
		}
		m_glow = row_flag(e.w, 1.0);
		m_fades = row_flag(e.w, 2.0);
		m_belt = m_belt && row_flag(e.w, 4.0);
		vec4 s = material_table[r + 2];
		m_rough = s.x;
		m_metal = s.y;
		m_edge_metal = s.z;
		m_ground_height = s.w;
		vec4 g = material_table[r + 3];
		m_part = g.x;
		m_flicker = g.y;
		m_pulse = g.z;
		m_rate = g.w;
		vec4 t = material_table[r + 4];
		m_ao = t.x;
		m_streaks = t.y;
		m_desat = t.z;
		m_value = t.w;
		vec4 l = material_table[r + 5];
		m_grain = l.x;
		m_nature = m_skin > 0 ? 0.0 : l.w;  // 5.w is a skinned creature's tint alpha instead
		m_light = l.yz;
		m_wear = material_table[r + 6];
		m_grime = material_table[r + 7];
		m_edge = material_table[r + 8];
		m_rust = material_table[r + 9];
		m_dust = material_table[r + 10];
	}
	// The instance's glow (worked out in vertex() for the model) applies to the rows that glow.
	float act = m_glow ? activity : 1.0;

	// The part's own colour from Factorio's sprite, where the model has one. Stored with headroom
	// (rgb / PART_RANGE, a = share * PART_SHARE) so a dark baked tint (the nature models' COLOR)
	// can be divided out without clipping; files from before that store rgb and the share as is,
	// with shares above PART_SHARE (part_colors.py).
	bool headroom = part_col.a <= PART_SHARE + 0.0001;
	float pc = clamp(headroom ? part_col.a / PART_SHARE : part_col.a, 0.0, 1.0) * m_part;
	// A "pbr" pack's material (m_modeller_tex): its colour is its picture times its factor, or the
	// factor alone without a picture (pc 1 either way, no part colours), its surface plain glTF (paint 0).
	// A textured model's own pictures carry its wear and dirt (as an untextured "pbr" row while packs' own shading is on).
	bool mp = m_modeller_tex && f3d_pack_shading > 0.5;
	// Skinned creatures without an albedo texture carry Factorio's mask layers in CUSTOM1:
	// never overwrite part_rgb with the raw tier tint or drop matte paint roughness/specular.
	if (m_skin > 0 && !(use_albedo_tex && !merged)) {
		mp = false;
	}
	float occluded = ((use_albedo_tex && !merged) || mp) ? 0.0 : 1.0 - ao;
	vec3 part_rgb = max(part_col.rgb, vec3(0.0)) * (headroom ? PART_RANGE : 1.0);
	// Textured surfaces are never merged (model_library.gd Load.combined): their textures are the
	// material's own uniforms.
	// The texture's alpha (1 without one): cuts a clipped material, fades a blended one.
	float tex_a = 1.0;
	// A "pbr" pack's occlusion picture (mp): ambient only, as glTF's occlusion is.
	float pic_ao = 1.0;
	// A modeller's textured belt surface: its own texture runs along the belt at the tier's speed
	// (the drawn slats and chevrons are left out). belt_uv_scroll is how far its UVs go per tile along
	// the belt, measured from the mesh (model_library.gd _belt_uv_scroll); the offset wraps on whole
	// repeats of the texture, which tiles, so it never jumps, on curves too.
	vec2 tuv = UV;
	// Every belt runs all the time; one switched off stands still, all of them at the same place so
	// their slats still line up from tile to tile.
	float belt_t = belt_off > 0.5 ? 0.0 : F3D_TIME;
	// How far the surface is smeared this frame (tiles; 0 switched off, slow or still).
	float smear = m_belt && belt_off < 0.5 ? min(belt_smear(belt_speed, f3d_frame_dt), 2.0 * BELT_PERIOD) : 0.0;
	if (m_belt && use_albedo_tex && !merged) {
		tuv = UV - fract(belt_uv_scroll * (belt_t * belt_speed));
	}
	if (use_albedo_tex && !merged) {
		pc = 1.0;
		vec4 tex = albedo_nearest ? texture(albedo_tex_nearest, tuv) : texture(albedo_tex, tuv);
		if (m_belt) {
			vec2 tdx = dFdx(tuv);
			vec2 tdy = dFdy(tuv);
			if (smear > 0.0) {
				// Smear along scroll only when motion exceeds a pixel; anisotropic taps cover linear textures cheaply.
				vec2 back = belt_uv_scroll * (smear * sign(belt_speed));
				float uv_px = max(length(tdx), length(tdy));
				float smear_px = length(back) / max(uv_px, 1e-6);
				if (smear_px >= 1.25) {
					if (albedo_nearest) {
						int taps = smear_px < 6.0 ? 4 : 8;
						float denom = float(taps - 1);
						for (int i = 1; i < taps; i++) {
							vec2 at = tuv + back * (float(i) / denom);
							tex += textureGrad(albedo_tex_nearest, at, tdx, tdy);
						}
						tex /= float(taps);
					} else if (smear_px < 4.0) {
						tex += textureGrad(albedo_tex, tuv + back * 0.5, tdx, tdy);
						tex += textureGrad(albedo_tex, tuv + back, tdx, tdy);
						tex *= (1.0 / 3.0);
					} else {
						vec2 step_uv = back * 0.25;
						vec2 sdx = tdx;
						vec2 sdy = tdy;
						if (abs(dot(tdx, back)) >= abs(dot(tdy, back))) {
							sdx += step_uv * (dot(tdx, step_uv) < 0.0 ? -1.0 : 1.0);
						} else {
							sdy += step_uv * (dot(tdy, step_uv) < 0.0 ? -1.0 : 1.0);
						}
						tex = textureGrad(albedo_tex, tuv + back * 0.125, sdx, sdy)
							+ textureGrad(albedo_tex, tuv + back * 0.375, sdx, sdy)
							+ textureGrad(albedo_tex, tuv + back * 0.625, sdx, sdy)
							+ textureGrad(albedo_tex, tuv + back * 0.875, sdx, sdy);
						tex *= 0.25;
					}
				}
			}
		}
		part_rgb = tex.rgb * albedo.rgb;
		tex_a = tex.a;
	} else if (mp) {
		pc = 1.0;
		part_rgb = m_albedo.rgb;
	}
#ifdef ALPHA_CLIP
	if (m_albedo.a * tex_a < alpha_clip) {
		discard;
	}
#endif
	if (m_skin == 1) {
		// Factorio's two mask layers: the first (all of the carapace) tinted by tint 1, the second
		// over it where it covers (times tint 2's alpha) tinted by tint 2.
		part_rgb = mix(part_rgb.r * m_albedo.rgb, part_rgb.g * m_tint2.rgb, clamp(part_rgb.b * m_tint2.a, 0.0, 1.0));
	} else if (m_skin >= 2) {
		// One mask over the part's own colour: its shade (COLOR.r = sqrt(shade / 4)) tinted by tint 1,
		// covering COLOR.g of it (times the tint's alpha, in skin_tint2's). COLOR is the mask's data
		// here, not a shading. A vertex the mask doesn't reach is (1, 1, 1) (creature_skin.py), the
		// masked ones' blue 0: taking the blue off red and green reads it as no mask, as if it held
		// (0, 0, 0), smoothly across its triangles. Read as it is, it was shade 4 under full cover,
		// the tier's tint four times over (a worm's mouth, a spawner's sacs): mode 3 keeps that.
		float unmasked = m_skin == 3 ? 0.0 : COLOR.b;
		float mask_r = max(COLOR.r - unmasked, 0.0);
		float shade = 4.0 * mask_r * mask_r;
		part_rgb = mix(part_rgb, shade * m_albedo.rgb, clamp(max(COLOR.g - unmasked, 0.0) * m_tint2.a, 0.0, 1.0));
		tint = vec3(1.0);
	}
	vec3 col = mix(m_albedo.rgb, part_rgb, pc) * tint * model_tint;
#ifndef LEAF_CUT
	if (m_nature > 0.5 && f3d_nature_grain_on > 0.5) {
		col *= nature_grain_at(m_nature, obj_pos, n, obj_dx, obj_dy);
	}
	float org_seam = fwidth(float(m_organic));
	bool org_wet = m_organic > 0 && f3d_organic_surface > 0.5;
	bool org_detail = org_wet && !(use_albedo_tex && !merged) && !(use_normal_tex && !merged);
	float org_h = 0.5;
	float org_scale = 1.0;
	if (org_detail) {
		org_scale = rig_body.z > 0.05 ? (rig_body.z / 0.9) : (rig_mode == 4 && worm_height > 0.05 ? (worm_height / 4.4) : 1.0);
		float opx = pixel / max(org_scale, 0.1);
		vec3 op = obj_pos / max(org_scale, 0.1) + vec3(inst_seed * 19.0, 0.0, inst_seed * 29.0) + part * 7.0;
		if (m_organic == 2) {
			float ridge = vnoise3_fading(vec3(op.x * 16.0, op.y * 24.0, op.z * 34.0), opx * 34.0);
			float plate = vnoise3_fading(op * 14.0 + 7.3, opx * 14.0);
			float pores = vnoise3_fading(op * 30.0 + 19.1, opx * 30.0);
			org_h = 0.33 * ridge + 0.42 * plate + 0.25 * pores;
		} else {
			float fiber = vnoise3_fading(vec3(op.x * 26.0, op.y * 22.0, op.z * 14.0), opx * 26.0);
			float fold = vnoise3_fading(op * 12.0 + 3.7, opx * 12.0);
			float pebble = vnoise3_fading(op * 28.0 + 15.9, opx * 28.0);
			org_h = 0.30 * fiber + 0.45 * fold + 0.25 * pebble;
		}
		col *= 1.0 + (org_h - 0.5) * (m_organic == 2 ? 0.26 : 0.20);
	}
	if (!IN_SHADOW_PASS && f3d_organic_surface > 0.5) {
		// Derivatives stay in uniform control flow across 2x2 pixel quads; only applied inside one row.
		vec3 dpdx = dFdx(VERTEX);
		vec3 dpdy = dFdy(VERTEX);
		float dhdx = dFdx(org_h);
		float dhdy = dFdy(org_h);
		if (org_detail && org_seam < 0.01) {
			vec3 surf_n = normalize(NORMAL);
			vec3 r1 = cross(dpdy, surf_n);
			vec3 r2 = cross(surf_n, dpdx);
			float det = dot(dpdx, r1);
			if (abs(det) > 1e-8) {
				vec3 grad = f3d_finite((dhdx * r1 + dhdy * r2) / det, vec3(0.0));
				float bump_k = (m_organic == 2 ? 0.042 : 0.036) * max(org_scale, 0.25);
				vec3 delta = grad * bump_k;
				float dlen = length(delta);
				if (dlen > 0.65) {
					delta *= 0.65 / dlen;
				}
				NORMAL = normalize(surf_n - delta);
			}
		}
	}
#endif
	vec4 wear = mix(vec4(1.0), m_wear, pc);
	// Part colours are the sprite's paint as it looks, metal and all: drawn mostly as diffuse paint
	// (as the projected sprite is), or the sky's reflection would grey them.
	// Little specular either: the sun's highlight on tops and domes read as a lighter colour.
	float paint = mp ? 0.0 : pc;
	float rough = mix(m_rough, 0.85, paint);
	float metal = m_metal * mix(1.0, 0.1, paint);
	if (mp) {
		metal = m_metal * f3d_look_pbr_metal;
	}
	if (use_orm_tex && !merged) {
		vec3 orm = orm_nearest ? texture(orm_tex_nearest, tuv).rgb : texture(orm_tex, tuv).rgb;
		rough = roughness * orm.g;
		metal = metallic * orm.b * (mp ? f3d_look_pbr_metal : f3d_look_texture_metal);
	}
	if (occlusion_mode > 0 && !merged) {
		vec4 occ = occlusion_mode == 2 ? texture(occlusion_tex, tuv)
			: (orm_nearest ? texture(orm_tex_nearest, tuv) : texture(orm_tex, tuv));
		float occ_v = clamp(dot(occ, occlusion_channel), 0.0, 1.0);
		if (mp) {
			pic_ao = occ_v;
		} else {
			ao *= occ_v;
		}
	}
	if (use_normal_tex && !merged) {
		vec3 nm = texture(normal_tex, tuv).rgb * 2.0 - 1.0;
		nm.xy *= normal_scale;
		// Cotangent frame from the UVs' screen slopes (no tangents needed); glTF's V runs down the
		// picture while its green points up it, hence the bitangent's sign.
		vec3 n0 = normalize(NORMAL);
		vec3 dp1 = dFdx(VERTEX);
		vec3 dp2 = dFdy(VERTEX);
		vec2 duv1 = dFdx(tuv);
		vec2 duv2 = dFdy(tuv);
		vec3 dp2perp = cross(dp2, n0);
		vec3 dp1perp = cross(n0, dp1);
		vec3 t = dp2perp * duv1.x + dp1perp * duv2.x;
		vec3 b = dp2perp * duv1.y + dp1perp * duv2.y;
		if (mp) {
			// The full formula: the frame's handedness from the screen slopes themselves, so it is right
			// whichever way dFdy runs (pbr-rd).
			float hand = dot(dp1, dp2perp) < 0.0 ? -1.0 : 1.0;
			t *= hand;
			b *= hand;
		}
		float inv = inversesqrt(max(max(dot(t, t), dot(b, b)), 1e-20));
		NORMAL = normalize(mat3(t * inv, -b * inv, n0) * nm);
	}

	// The belt's moving slats: light ridges and dark seams over the weathered surface.
	float belt_shade = 1.0;
	float chevron = 0.0;
#ifndef LEAF_CUT
	if (m_belt && !(use_albedo_tex && !merged)) {
		// Distance along the belt (tiles, -0.5 at the input edge to 0.5 at the output edge),
		// so the slats line up from tile to tile. Curves spread a tile's worth over the arc.
		// `across` is the distance from the belt's middle line.
		float s = -obj_pos.z;
		float across = obj_pos.x;
		if (belt_shape > 0) {
			float side = belt_shape == 1 ? 1.0 : -1.0;
			vec2 d = obj_pos.xz - vec2(-0.5 * side, -0.5);
			s = atan(-d.y, d.x * side) / 1.5707963 + 0.5;
			across = length(d) - 0.5;
		}
		if (belt_chevron.a > 0.0) {
			// Factorio's chevron: 0.3 tiles wide, 0.1 deep, its stroke 0.08, on the middle of a
			// slat every belt_chevron_period tiles; `along` is measured from its middle towards the
			// way items go. A 2-tile period counts alternate tiles on (belt_parity): a tile's `s`
			// runs -0.5 to 0.5, so shorter periods repeat within it.
			float cper = max(belt_chevron_period, 2.0 * BELT_PERIOD);
			float line_s = s + (cper > 1.5 ? belt_parity : 0.0);
			float cp = fract((line_s - belt_t * belt_speed + 0.1625) / cper);
			float along = (cp - 0.5) * cper * sign(belt_speed);
			float centre = 0.05 - abs(across) * 0.67;
			float dist = abs(along - centre);
			float aa = max(fwidth(along), 0.004);
			float stroke = 1.0 - smoothstep(0.04 - aa, 0.04 + aa, dist);
			if (smear > 0.0) {
				// Averaged over where the stroke was this frame and the last (`along` was larger
				// then, whichever way the belt runs).
				stroke = (belt_stroke_integral(along - centre + smear, 0.04, aa, cper)
					- belt_stroke_integral(along - centre, 0.04, aa, cper)) / smear;
			}
			chevron = stroke
				* (1.0 - smoothstep(0.15 - aa, 0.15 + aa, abs(across)))
				* smoothstep(0.6, 0.9, n.y)
				// Far away the stroke is under a pixel: fades out rather than shimmering.
				* (1.0 - smoothstep(0.03, 0.06, aa)) * belt_chevron.a;
		}
		float phase = fract((s - belt_t * belt_speed) / BELT_PERIOD);
		// A raised slat with a dark seam behind it, like Factorio's belt; fast belts blur.
		float slat = smoothstep(0.0, 0.08, phase) * (1.0 - smoothstep(0.62, 0.78, phase));
		float seam = 1.0 - smoothstep(0.0, 0.06, phase) * (1.0 - smoothstep(0.9, 1.0, phase));
		float ridge = 0.45 * slat - 0.45 * seam - 0.12;
		if (smear > 0.0) {
			// The same shade averaged over the phases it passed through (later phases were
			// earlier in time for a belt running forwards, earlier ones running back).
			float width = smear / BELT_PERIOD;
			float from = phase - (belt_speed < 0.0 ? width : 0.0);
			ridge = (belt_slat_integral(from + width) - belt_slat_integral(from)) / width;
		}
		float blur = clamp(1.15 - abs(belt_speed) * 0.09, 0.45, 1.0);
		blur *= 1.0 - smoothstep(0.25, 0.6, fwidth(s) / BELT_PERIOD);
		belt_shade = 1.0 + blur * ridge;
	}
#endif

	// Slightly greyed and darker, like Factorio's palette next to a clean render.
	float lum = dot(col, vec3(0.299, 0.587, 0.114));
	col = mix(col, vec3(lum), m_desat * (1.0 - pc)) * mix(m_value, 1.0, pc);
	// Mottling: no flat surface in Factorio's art is one colour.
	col *= 1.0 + m_grain * ((fine - 0.5) * 1.4 + (mid - 0.5) * 1.2);

#ifndef LEAF_CUT
	// Rust: patches where water sits (crevices, low down, the top of a part) and streaks
	// running down the sides.
	float side = 1.0 - abs(n.y);
	float low = 1.0 - smoothstep(0.0, 0.9, world_y);
	float rust_place = 0.25 * occluded + 0.12 * low + 0.2 * (part - 0.5) + 0.1 * (dirt - 1.0);
	float rust_mask = smoothstep(0.62, 0.8, patches + rust_place);
	// Streaks run down sides, on materials that have them: from the angled camera most of what's in
	// view has none, and the noise is skipped. (Not side > 0: a flat top's interpolated normal is a
	// rounding error off straight up.)
	float streak = 0.0;
	if (m_streaks != 0.0 && side > 1e-5) {
		streak = smoothstep(0.55, 0.85, vnoise3(vec3(p.x * 11.0, p.y * 0.9, p.z * 11.0)))
			* smoothstep(0.35, 0.65, vnoise3(p * 1.7 + 3.0)) * side;
	}
	float r = clamp((m_rust.a * rust_mask * (0.6 + 0.6 * fine) + m_streaks * streak * dirt) * wear.x, 0.0, 1.0);
	vec3 rc = m_rust.rgb * (0.75 + 0.5 * mid);
	col = mix(col, rc, r);
	metal = mix(metal, 0.25, r);

	// Worn edges: chipped back to bright metal (or lighter wood and stone).
	float edge_amount = m_edge.a * wear.y * edge;
	float chips = 0.0;
	if (edge_amount != 0.0) {
		float fade = noise_fade(pixel * 31.0);
		chips = chips_mean(edge);
		if (fade < 1.0) {
			chips = mix(smoothstep(0.3, 0.6, vnoise3(p * 31.0) + 0.25 * edge), chips, fade);
		}
	}
	float e = edge_amount * chips * (1.0 - 0.6 * r);
	col = mix(col, m_edge.rgb * (0.85 + 0.3 * fine), e);
	metal = mix(metal, m_edge_metal, e);
#endif

	// Grime: settles in occluded corners and climbs up from the ground.
	float ground = 1.0 - smoothstep(0.0, m_ground_height, world_y);
	float grime_amount = m_grime.a * wear.z * dirt * clamp(occluded * 1.4 + ground * 0.8, 0.0, 1.0);
	float g = grime_amount * (0.55 + 0.6 * patches);
	col = mix(col, m_grime.rgb, clamp(g, 0.0, 0.85));
	metal = mix(metal, 0.1, g);

#ifndef LEAF_CUT
	// Dust on surfaces facing up.
	float dust_amount = m_dust.a * wear.w * smoothstep(0.35, 0.95, n.y);
	float d = dust_amount * smoothstep(0.3, 0.7, patches + 0.2 * fine);
	col = mix(col, m_dust.rgb, d);
	metal = mix(metal, 0.0, d);

	// Roughness from the same weathering with each noise at its average (measured from the value
	// noise). With SSAO or SSIL on, Godot's depth pre-pass writes normals and roughness, and whatever
	// feeds ROUGHNESS runs there: nothing else in that pass reads the noise, so the compiler drops it.
	float rough_rust = clamp((m_rust.a * smoothstep(0.0, 0.42, rust_place) * 0.9 + m_streaks * 0.083 * side * dirt) * wear.x, 0.0, 1.0);
	rough = mix(clamp(rough, 0.0, 1.0), 0.9, rough_rust);
	rough = mix(rough, rough * 0.6, m_edge.a * wear.y * edge * chips_mean(edge) * (1.0 - 0.6 * rough_rust));
	rough = mix(rough, 0.95, grime_amount * 0.85);
	rough = mix(rough, 1.0, dust_amount * 0.74);
	if (org_detail) {
		float var_k = clamp(org_h * 0.7 + patches * 0.3, 0.0, 1.0);
		float org_rough = m_organic == 2 ? mix(0.80, 0.60, var_k) : mix(0.90, 0.74, var_k);
		rough = mix(org_rough, max(rough, org_rough), grime_amount * 0.5);
	}

	col *= belt_shade;
	col = mix(col, belt_chevron.rgb * (0.9 + 0.2 * fine), chevron);
#endif

	// Baked occlusion darkens direct light too: Factorio's sprites have it painted in. Above 1 the
	// strength is a power (textured models, model_library.gd TEXTURED_AO): their bake is per vertex
	// over long faces, so what shows of it is the 0.6-0.9 near their corners and feet; squared it
	// reads about as Factorio's sprites shade theirs.
	float shade = m_ao > 1.0 ? pow(ao, m_ao) : mix(1.0, ao, m_ao);
	ALBEDO = col * mix(1.0, shade, 0.65);
	ALBEDO *= mix(vec3(1.0), f3d_paint * 1.4, 0.6 * step(dot(f3d_paint, vec3(1.0)), 2.99) * step(f3d_paint_from, obj_pos.y));
#ifdef LEAF_CUT
	ALBEDO *= leaf_shade * leaf_rgb * leaf_tint;
	// Polluted trees as Factorio draws them: first greyed, then the grey-brown of dead leaves.
	if (leaf_dying > 0.0) {
		float lum = dot(ALBEDO, vec3(0.3, 0.59, 0.11));
		vec3 grey = mix(ALBEDO, vec3(lum), smoothstep(0.0, 0.45, leaf_dying));
		ALBEDO = mix(grey, lum * vec3(1.2, 0.98, 0.66), smoothstep(0.3, 0.8, leaf_dying));
	}
#endif
	float up = clamp((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).y, 0.0, 1.0);
	// A "pbr" pack's picture: the look's balance, darkened as part_light is (a burnt remnant's 0.42).
	vec2 balance = mp ? f3d_look_texture_light * (m_light.x / 0.95) : m_light;
	ALBEDO *= mix(1.0, mix(balance.x, balance.y, up), pc);
	float covered = 0.0;
	if (belt_cover.w > 0.0) {
		float lat = belt_shape > 0 ? belt_coords(obj_pos).y + 0.5 : abs(obj_pos.x);
		covered = (1.0 - smoothstep(belt_cover.x - 0.04, belt_cover.x, obj_pos.y))
				* step(belt_cover.y - 0.01, lat) * step(lat, belt_cover.z + 0.01);
		ALBEDO *= mix(1.0, 0.6, covered);
		shade = mix(shade, min(shade, 0.3), covered);
	}
	AO = shade * pic_ao;
	// A "pbr" pack: its picture's occlusion only on ambient light, the baked vertex occlusion (shade) still
	// darkening direct light by its 0.3 share (Godot: direct * mix(1, AO, affect) = 1 - 0.3 * (1 - shade)).
	AO_LIGHT_AFFECT = mix((mp ? 0.3 * (1.0 - shade) / max(1.0 - shade * pic_ao, 1e-4) : 0.3) * f3d_look_ao_direct, 1.0, covered);
	ROUGHNESS = max(rough, mp ? f3d_look_roughness_min_pbr : f3d_look_roughness_min);
#ifdef LEAF_CUT
	// Leaves keep their base roughness: with SSAO on, Godot's depth prepass writes normals and
	// roughness, so every one of a crown's dozen cut-out card layers ran the weathering noise and
	// sprite sampling feeding `rough` there, which nothing else in that pass needs.
	ROUGHNESS = mix(m_rough, 0.85, pc);
	float tree_matte = f3d_tree_matte;
#else
	float tree_matte = (m_nature > 0.5) ? f3d_tree_matte : 0.0;
#endif
	METALLIC = metal;
	SPECULAR = mix(mix(0.5, 0.2, paint), 0.05, tree_matte);
#ifndef LEAF_CUT
	if (org_detail) {
		SPECULAR = m_organic == 2 ? mix(0.24, 0.34, org_h) : 0.22;
	}
#endif
	ROUGHNESS = mix(ROUGHNESS, 1.0, tree_matte);
	if (!IN_SHADOW_PASS && f3d_weather_wet.y > 0.001) {
		vec3 wn = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
#ifdef LEAF_CUT
		float wet_cover = 0.65;
		int wet_kind = 0;
#else
		float wet_cover = covered;
		int wet_kind = (m_wet_rock && f3d_wet_rock > 0.5) ? 1 : (org_wet ? 2 : 0);
#endif
		weather_apply_model(world_xz, world_y, wn, wet_cover, length(VERTEX), wet_kind,
				ALBEDO, ROUGHNESS, SPECULAR, METALLIC, NORMAL, VIEW_MATRIX);
	}
#ifdef RAGDOLL_DECAY
	if (!IN_SHADOW_PASS) {
		float w_scale = rig_body.z > 0.05 ? (rig_body.z / 0.9) : 1.0;
		vec3 bp = obj_pos / w_scale;
		if (rig_blood > 0.01) {
			float b_amt = clamp(rig_blood, 0.0, 1.0);
			float bn1 = f3d_decay_noise(bp * 6.2 + vec3(1.7, 3.1, 5.3));
			float bn2 = f3d_decay_noise(bp * 14.5 + vec3(4.1, 7.9, 2.3));
			float blotch = bn1 * 0.56 + bn2 * 0.44;
			float thresh = mix(0.68, 0.47, b_amt);
			float bmask = smoothstep(thresh - 0.04, thresh + 0.06, blotch) * clamp(b_amt * 1.15, 0.35, 0.92);
			vec3 ichor_col = mix(vec3(0.055, 0.005, 0.038), vec3(0.135, 0.014, 0.095), bn2);
			ALBEDO = mix(ALBEDO, ichor_col, bmask * 0.86);
			ROUGHNESS = mix(ROUGHNESS, f3d_organic_surface > 0.5 ? 0.30 : 0.22, bmask);
			SPECULAR = mix(SPECULAR, f3d_organic_surface > 0.5 ? 0.42 : 0.52, bmask);
			METALLIC *= (1.0 - bmask * 0.7);
		}
		for (int k = 0; k < 6; k++) {
			vec4 hole = rig_holes[k];
			if (hole.w <= 0.001) {
				continue;
			}
			float d = length(obj_pos - hole.xyz) / hole.w;
			if (d >= 2.2) {
				continue;
			}
			float hn = f3d_decay_noise(obj_pos * 14.0 + vec3(float(k) * 7.3, 2.1, float(k) * 11.9));
			float j_d = d + (hn - 0.5) * 0.28;
			float cavity = 1.0 - smoothstep(0.38, 0.58, j_d);
			float rim = smoothstep(0.45, 0.62, j_d) * (1.0 - smoothstep(0.82, 1.02, j_d));
			float halo_env = smoothstep(0.75, 1.05, d) * (1.0 - smoothstep(1.35, 2.1, d));
			float halo = halo_env * smoothstep(0.35, 0.72, hn + 0.15 * (1.0 - clamp(d / 2.1, 0.0, 1.0)));
			vec3 halo_col = mix(vec3(0.060, 0.006, 0.042), vec3(0.145, 0.016, 0.105), hn);
			ALBEDO = mix(ALBEDO, halo_col, halo * 0.75);
			ROUGHNESS = mix(ROUGHNESS, 0.24, halo);
			SPECULAR = mix(SPECULAR, 0.48, halo);
			vec3 rim_col = vec3(0.032, 0.004, 0.025);
			ALBEDO = mix(ALBEDO, rim_col, rim * 0.85);
			ROUGHNESS = mix(ROUGHNESS, 0.28, rim);
			AO = mix(AO, 0.25, rim * 0.7);
			vec3 cav_col = vec3(0.006, 0.001, 0.007);
			ALBEDO = mix(ALBEDO, cav_col, cavity * 0.96);
			ROUGHNESS = mix(ROUGHNESS, 0.22, cavity);
			AO = mix(AO, 0.05, cavity);
		}
	}
#elif !defined(LEAF_CUT) && !defined(ROBOT)
	if (!IN_SHADOW_PASS && (v_wound.x > 0.01 || v_wound.y > 0.5)) {
		float w_scale = 1.0;
		if (rig_mode == 4) {
			w_scale = worm_height > 0.05 ? (worm_height / 4.4) : 1.0;
		} else if (rig_mode == 1) {
			w_scale = rig_body.z > 0.05 ? (rig_body.z / 0.9) : 1.0;
		}
		vec3 np = obj_pos / w_scale;
		float w_blood = clamp(v_wound.x, 0.0, 1.0);
		if (w_blood > 0.01) {
			vec3 bp = rig_mode == 2 ? (np * 0.45) : (rig_mode == 4 ? (np * 0.7) : np);
			float bn1 = vnoise3(bp * 6.2 + vec3(1.7, 3.1, 5.3));
			float bn2 = vnoise3(bp * 14.5 + vec3(4.1, 7.9, 2.3));
			float blotch = bn1 * 0.56 + bn2 * 0.44;
			float thresh = mix(0.68, 0.47, w_blood);
			float bmask = smoothstep(thresh - 0.04, thresh + 0.06, blotch) * clamp(w_blood * 1.15, 0.35, 0.92);
			vec3 ichor_col = mix(vec3(0.055, 0.005, 0.038), vec3(0.135, 0.014, 0.095), bn2);
			ALBEDO = mix(ALBEDO, ichor_col, bmask * 0.86);
			ROUGHNESS = mix(ROUGHNESS, f3d_organic_surface > 0.5 ? 0.30 : 0.22, bmask);
			SPECULAR = mix(SPECULAR, f3d_organic_surface > 0.5 ? 0.42 : 0.52, bmask);
			METALLIC *= (1.0 - bmask * 0.7);
		}
		int hit_n = clamp(int(v_wound.y + 0.5), 0, 8);
		bool can_holes = hit_n > 0 && ((rig_mode == 1 && UV.x < 0.5) || rig_mode == 4 || (rig_mode == 2 && UV.x < 1.5));
		if (can_holes) {
			const vec4 LIVE_HOLE_DIR[8] = vec4[8](
				vec4(-0.6489, 0.7188, -0.2496, 0.110),
				vec4(0.7982, 0.5936, -0.1023, 0.120),
				vec4(0.1506, 0.9636, -0.2208, 0.130),
				vec4(-0.3498, 0.7795, -0.5197, 0.105),
				vec4(-0.7234, 0.6431, 0.2512, 0.125),
				vec4(0.2796, 0.9185, 0.2796, 0.120),
				vec4(0.6798, 0.6498, -0.3399, 0.115),
				vec4(-0.5530, 0.8244, 0.1206, 0.135)
			);
			const float LIVE_HOLE_Z[8] = float[8](-0.35, 0.05, -0.10, -0.75, 0.55, 0.72, -0.52, 0.28);
			const vec4 LIVE_WORM_DIR[8] = vec4[8](
				vec4(0.8165, 0.0797, -0.5717, 0.190),
				vec4(-0.3416, 0.0499, 0.9385, 0.210),
				vec4(-0.8181, -0.0499, -0.5729, 0.170),
				vec4(0.8151, 0.0995, 0.5707, 0.220),
				vec4(-0.4991, 0.0599, -0.8645, 0.180),
				vec4(-0.9389, -0.0400, 0.3417, 0.200),
				vec4(0.2570, 0.1191, -0.9590, 0.160),
				vec4(0.3417, 0.0400, 0.9389, 0.190)
			);
			const float LIVE_WORM_Y[8] = float[8](2.85, 1.85, 3.25, 1.25, 2.35, 0.95, 3.55, 2.55);
			const vec4 LIVE_NEST_HOLES[8] = vec4[8](
				vec4(-0.72, 1.54, -0.56, 0.32),
				vec4(0.78, 1.58, 0.35, 0.34),
				vec4(0.15, 1.29, -1.10, 0.36),
				vec4(-1.28, 1.18, 0.58, 0.34),
				vec4(1.30, 1.07, -0.77, 0.32),
				vec4(-0.23, 1.31, 1.16, 0.36),
				vec4(-1.55, 0.85, -0.58, 0.32),
				vec4(1.65, 0.67, 0.82, 0.32)
			);
			float hn_freq = rig_mode == 2 ? 6.0 : (rig_mode == 4 ? 9.0 : 14.0);
			for (int k = 0; k < 8; k++) {
				if (k >= hit_n) {
					break;
				}
				float d = 10.0;
				if (rig_mode == 1) {
					vec4 hd = LIVE_HOLE_DIR[k];
					vec3 rel = np - vec3(0.0, 1.05, LIVE_HOLE_Z[k]);
					float along = dot(rel, hd.xyz);
					if (along <= 0.12 || along >= 1.25) {
						continue;
					}
					d = length(rel - hd.xyz * along) / hd.w;
				} else if (rig_mode == 4) {
					vec4 wd = LIVE_WORM_DIR[k];
					vec3 rel = np - vec3(0.0, LIVE_WORM_Y[k], 0.0);
					float along = dot(rel, wd.xyz);
					if (along <= 0.35 || along >= 1.65) {
						continue;
					}
					d = length(rel - wd.xyz * along) / wd.w;
				} else {
					vec4 nh = LIVE_NEST_HOLES[k];
					d = length(np - nh.xyz) / nh.w;
				}
				if (d >= 2.2) {
					continue;
				}
				float hn = vnoise3(np * hn_freq + vec3(float(k) * 7.3, 2.1, float(k) * 11.9));
				float j_d = d + (hn - 0.5) * 0.28;
				float cavity = 1.0 - smoothstep(0.38, 0.58, j_d);
				float rim = smoothstep(0.45, 0.62, j_d) * (1.0 - smoothstep(0.82, 1.02, j_d));
				float halo_env = smoothstep(0.75, 1.05, d) * (1.0 - smoothstep(1.35, 2.1, d));
				float halo = halo_env * smoothstep(0.35, 0.72, hn + 0.15 * (1.0 - clamp(d / 2.1, 0.0, 1.0)));
				vec3 halo_col = mix(vec3(0.060, 0.006, 0.042), vec3(0.145, 0.016, 0.105), hn);
				ALBEDO = mix(ALBEDO, halo_col, halo * 0.75);
				ROUGHNESS = mix(ROUGHNESS, 0.24, halo);
				SPECULAR = mix(SPECULAR, 0.48, halo);
				vec3 rim_col = vec3(0.032, 0.004, 0.025);
				ALBEDO = mix(ALBEDO, rim_col, rim * 0.85);
				ROUGHNESS = mix(ROUGHNESS, 0.28, rim);
				AO = mix(AO, 0.25, rim * 0.7);
				vec3 cav_col = vec3(0.006, 0.001, 0.007);
				ALBEDO = mix(ALBEDO, cav_col, cavity * 0.96);
				ROUGHNESS = mix(ROUGHNESS, 0.22, cavity);
				AO = mix(AO, 0.05, cavity);
			}
		}
	}
#endif
	float wave = 1.0;
	if (m_flicker > 0.0) {
		float t = F3D_TIME * 8.0 + inst_seed * 40.0 - obj_pos.y * 6.0 + obj_pos.x * 2.0;
		wave -= m_flicker * (0.5 + 0.25 * sin(t) + 0.15 * sin(t * 2.3 + 1.7) + 0.1 * sin(t * 5.1 + 0.4));
	}
	if (m_pulse > 0.0) {
		wave -= m_pulse * (0.5 + 0.5 * sin((F3D_TIME * m_rate + inst_seed) * 6.2831853));
	}
	if (glow_heat > 0.0 && !merged) {
		// Three slow sines at unrelated rates (0.9, 1.7, 2.9 a second) summed to -1..1: 0.75 to 1.15 of
		// the glow at full heat.
		float ht = (F3D_TIME + inst_seed * 37.0) * 6.2831853;
		float n = 0.5 * sin(ht * 0.9) + 0.3 * sin(ht * 1.7 + 1.3) + 0.2 * sin(ht * 2.9 + 2.9);
		wave *= 1.0 + glow_heat * (-0.05 + 0.2 * n);
	}
	if (use_emission_tex && !merged) {
		m_emission *= texture(emission_tex, UV).rgb;
	}
	if (m_paint_glow) {
		m_emission *= ALBEDO;
	}
	EMISSION = m_emission * act * act * wave;
	// A "pbr" pack: its pbr_fill share of it (pbr_env.gdshaderinc), so the sun decides its lit and shaded sides.
	EMISSION += ALBEDO * f3d_look_model_fill * (mp ? pbr_fill_share() : 1.0) * (0.35 + 0.65 * max(dot(NORMAL, VIEW), 0.0)) * mix(1.0, 0.25, covered);
	EMISSION += lamp_light_emission(ALBEDO, world_xz, world_y, up) * mix(1.0, 0.35, covered);
	if (m_glow && !(use_emission_tex && !merged) && !m_keep_albedo) {
		// Idle fire boxes and lamps go dark, as Factorio's do. A material with its own emission
		// texture is the model's whole surface (a modeller's): only its painted glow fades, or the
		// whole model would darken when idle and look washed white when it works. Nor does a
		// modeller's glow without a picture (glow_keeps_albedo): only its emission goes out.
		ALBEDO *= mix(0.3, 1.0, act);
	}
#ifdef RAGDOLL_DECAY
	if (rig_decay > 0.001) {
		float dnoise = f3d_decay_noise(obj_pos * 5.5 + vec3(inst_seed * 17.0, 3.1, inst_seed * 29.0));
		float dry_k = smoothstep(0.0, 0.50, rig_decay);
		ALBEDO = mix(ALBEDO, vec3(0.14, 0.11, 0.09), dry_k * 0.82);
		ROUGHNESS = mix(ROUGHNESS, 1.0, smoothstep(0.0, 0.45, rig_decay));
		float dissolve = smoothstep(0.45, 1.0, rig_decay);
		if (dnoise < dissolve) {
			discard;
		}
		float rim = smoothstep(dissolve, dissolve + 0.08, dnoise);
		ALBEDO *= mix(0.45, 1.0, rim);
	}
	if (!IN_SHADOW_PASS && rig_burn > 0.005) {
		float burn = clamp(rig_burn, 0.0, 1.0);
		float w_scale = rig_body.z > 0.05 ? (rig_body.z / 0.9) : 1.0;
		vec3 bp = obj_pos / w_scale;
		float n1 = f3d_decay_noise(bp * 5.2 + vec3(3.7, 1.9, 6.1));
		float n2 = f3d_decay_noise(bp * 13.0 + vec3(8.3, 4.2, 2.7));
		float char_mask = smoothstep(mix(0.85, 0.08, burn), mix(0.95, 0.35, burn), n1 * 0.65 + n2 * 0.35) * clamp(burn * 1.35, 0.0, 1.0);
		vec3 char_col = mix(vec3(0.018, 0.014, 0.013), vec3(0.045, 0.042, 0.040), clamp(rig_decay, 0.0, 1.0));
		ALBEDO = mix(ALBEDO, char_col, char_mask);
		ROUGHNESS = mix(ROUGHNESS, 0.95, char_mask);
		SPECULAR = mix(SPECULAR, 0.05, char_mask);
		METALLIC *= (1.0 - char_mask);
		float ember_band = smoothstep(0.46, 0.54, n2) * (1.0 - smoothstep(0.56, 0.65, n2));
		float ember_pulse = sin(F3D_TIME * 5.5 + n1 * 12.0) * 0.25 + 0.75;
		float ash_fade = 1.0 - smoothstep(0.45, 0.92, rig_decay);
		float burn_peak = smoothstep(0.10, 0.28, burn) * (1.0 - 0.4 * smoothstep(0.92, 1.0, burn));
		float char_front = char_mask * (1.0 - char_mask) * 3.0;
		float ember_mask = clamp(ember_band * char_mask * 1.15 + char_front * ember_band * 0.85, 0.0, 1.0) * burn_peak * ash_fade * ember_pulse;
		EMISSION += mix(vec3(1.8, 0.22, 0.02), vec3(3.2, 0.85, 0.08), n2) * ember_mask;
	}
#endif
	ALBEDO = max(f3d_finite(ALBEDO, m_albedo.rgb), vec3(0.0));
	EMISSION = max(f3d_finite(EMISSION, vec3(0.0)), vec3(0.0));
	ROUGHNESS = clamp(f3d_finite1(ROUGHNESS, 0.8), 0.0, 1.0);
	METALLIC = clamp(f3d_finite1(METALLIC, 0.0), 0.0, 1.0);
	AO = clamp(f3d_finite1(AO, 1.0), 0.0, 1.0);
	if (any(isnan(NORMAL)) || any(isinf(NORMAL)) || dot(NORMAL, NORMAL) < 0.25) {
		NORMAL = vec3(0.0, 0.0, 1.0);
	}
#if defined(SHADER_LIGHT_ENV) && !defined(LEAF_CUT)
	if (mp && f3d_light_env < 0.5) {
		// A "pbr" pack under --light-env=shader: the neutral reflection and directional ambient
		// (pbr_env.gdshaderinc). Compiled out by default so Godot skips custom IBL registers.
		RADIANCE = pbr_env_radiance(VIEW, normalize(NORMAL), ROUGHNESS, INV_VIEW_MATRIX);
		IRRADIANCE = pbr_irradiance(normalize(NORMAL), INV_VIEW_MATRIX);
	}
#endif
#ifdef BLEND_ALPHA
	// See-through light (a thruster's plume) fades away with its glow when idle; glass stays.
	ALPHA = m_albedo.a * tex_a * (m_fades ? act : 1.0);
#endif
}
