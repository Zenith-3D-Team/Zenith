// Contact shading under loose items (item_cards.gd contact): the soft dark rim round an item where it
// lies on a belt or the ground, as contact_shade.gdshader draws round a building's foot (the same profile,
// strength and rim width; the debug menu's sliders move both). Without it items on belts looked stood
// above the belt rather than on it (owner: "contact shadows for items on belts?").
//
// One more surface on each kind's mesh (so it is drawn by the kind's own MultiMesh, placed on the GPU
// with its items by belt_place(): nothing per item on the CPU, one more instanced draw a kind): a box round
// the item's footprint reaching down from its base, drawn in the alpha pass as a decal. Each pixel the box
// covers reads the opaque scene's depth there (the copy the cloud shadows already take each frame), and
// darkens it by how far the surface there is outside the item's footprint and how far below its base: so the
// rim lands on whatever is under the item, the belt's surface between its rails (items ride on the rails' top,
// belt_items.gd item_height(), up to a few hundredths of a tile above it) or the ground, and never on the item
// itself. Not in the shadow pass (an alpha-only material casts none), no light of its own.
//
// CUSTOM0: the footprint's centre (x, z) and half size (x, z) in the mesh's units; UV.x the item's base (its
// mesh's lowest point). A pile's copies have none (their item has one), nor has an item hidden (belt_place).
shader_type spatial;
render_mode world_vertex_coords, unshaded, blend_mul, depth_draw_never, cull_back, shadows_disabled, fog_disabled;

#define BELT_IGNORE_VARIANTS
#include "res://shaders/belt_path.gdshaderinc"
#include "res://shaders/ground_height.gdshaderinc"

uniform sampler2D depth_texture : hint_depth_texture, filter_nearest;
// Shown (Settings > Graphics > Contact shading; item_cards.gd sets it).
uniform bool on = true;
// The rim's darkness at the footprint's edge and its falloff (tiles): contact_shade.gdshader's, and the
// debug menu's Contact strength and rim width sliders set both. `strength` scales it for items.
uniform float rim_dark = 0.47;
uniform float rim_falloff = 0.06;
uniform float strength = 0.35;
// Under the item the darkness eases from the rim's to this share of it at the middle (seen where the
// item doesn't cover its footprint: an icon card's clear corners, a gear's teeth).
uniform float inner = 0.30;
// How far past the footprint the rim reaches (tiles; the box's margin, item_cards.gd CONTACT_REACH).
uniform float reach = 0.055;
// A surface this far below the base (tiles) gets the whole rim, gone by gap_gone (the box's depth,
// item_cards.gd CONTACT_DROP); less than min_gap below the base, none (the item itself: a card's own pixels lie at its base).
uniform float gap_full = 0.045;
uniform float gap_gone = 0.11;
uniform float min_gap = 0.008;
// The rim is drawn while a pixel covers less than fade_from tiles, gone past fade_to (tighter than
// buildings' AoZoom.RIM_FULL/RIM_GONE: an item is ~0.3 tiles across and its 0.06-tile rim vanishes
// past ~20 px/tile; item_cards.gd CONTACT_FADE_FROM, CONTACT_FADE_TO).
uniform float fade_from = 0.025;
uniform float fade_to = 0.05;
uniform bool use_anchor = false;
uniform vec3 anchor_pos = vec3(0.0);
uniform float anchor_fade_from = 20.0;
uniform float anchor_fade_to = 32.0;
// The profile is on-screen (sRGB) darkness; the multiply is in linear light (contact_shade.gdshader).
uniform float profile_gamma = 2.2;

varying flat vec3 base;    // the item's base, world
varying flat vec3 axes;    // its turn (cos, sin) and scale
varying flat vec4 rect;    // CUSTOM0
varying vec3 box_world;

void vertex() {
	bool hide = !on;
	vec3 o = vec3(0.0);
	vec3 ax = vec3(1.0, 0.0, 0.0);
	if (!hide) {
		o = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
		ax = (MODEL_MATRIX * vec4(1.0, 0.0, 0.0, 0.0)).xyz;
		if (belt_base >= 0) {
			// A pile's copy (texel 3 y > 0): its item, under it, has the rim.
			if (belt_texel(belt_base + INSTANCE_ID, 3, belt_layer_texels()).y > 0.5) {
				hide = true;
			} else {
				vec3 local_v = VERTEX;
				belt_place(o, ax, INSTANCE_ID);
				if (o == vec3(0.0)) {
					hide = true;
				} else {
					// One call per vertex: belt_place turned (1, 0, 0) to (c.x, 0, -c.y) and placed (0, 0, 0) at o.
					VERTEX = vec3(ax.x * local_v.x - ax.z * local_v.z, local_v.y, ax.z * local_v.x + ax.x * local_v.z) + o;
				}
			}
		} else if (belt_base == -2) {
			if (INSTANCE_CUSTOM.x >= 64.0 || f3d_belt_clock < INSTANCE_CUSTOM.w) {
				hide = true;
			}
#ifndef BELT_NO_VIEW_CULL
			if (!hide && (o.x < f3d_item_view_rect.x || o.x > f3d_item_view_rect.z
					|| o.z < f3d_item_view_rect.y || o.z > f3d_item_view_rect.w)) {
				hide = true;
			}
#endif
		}
	}
	if (!hide) {
		if (use_anchor) {
			hide = length(o.xz - anchor_pos.xz) >= anchor_fade_to;
		} else {
			// Past fade_to (tiles a pixel across the view; on the ground, which fragment() measures, a pixel is at
			// least as long) the rim is gone: no box, so a far view of thousands of items runs no pixels for it.
			vec4 c0 = PROJECTION_MATRIX * VIEW_MATRIX * vec4(o, 1.0);
			vec4 c1 = PROJECTION_MATRIX * VIEW_MATRIX * vec4(o + INV_VIEW_MATRIX[0].xyz, 1.0);
			float tile_px = length((c1.xy / c1.w - c0.xy / c0.w) * VIEWPORT_SIZE * 0.5);
			hide = c0.w <= 0.0 || c1.w <= 0.0 || tile_px * fade_to < 1.0;
		}
	}
	if (hide) {
		VERTEX = vec3(0.0);
		axes = vec3(1.0, 0.0, 1.0);
		base = vec3(0.0);
		rect = CUSTOM0;
		box_world = vec3(0.0);
	} else {
		float s = max(length(ax.xz), 1.0e-4);
		float h = ground_h(o.xz);  // one height for the whole box: an item is small
		VERTEX.y += h;
		// (cos, sin) of the turn: belt_place turns x to (c, 0, -s).
		axes = vec3(ax.x / s, -ax.z / s, s);
		base = vec3(o.x, o.y + h + UV.x * s, o.z);
		rect = CUSTOM0;
		box_world = VERTEX;
	}
}

void fragment() {
	// A pixel's size on the ground (from the box, smooth, computed before any discard so quad derivatives
	// stay valid): used to anti-alias the falloff (`k`), and to fade out by view in camera-led mode.
	float px = max(length(dFdx(box_world.xz)), length(dFdy(box_world.xz)));
	float fade = 1.0;
	if (use_anchor) {
		float ad = length(base.xz - anchor_pos.xz);
		if (ad >= anchor_fade_to) {
			discard;
		}
		fade = 1.0 - smoothstep(anchor_fade_from, anchor_fade_to, ad);
	} else {
		if (px >= fade_to) {
			discard;
		}
		fade = 1.0 - smoothstep(fade_from, fade_to, px);
	}
	float depth = texture(depth_texture, SCREEN_UV).r;
	vec4 wp = INV_VIEW_MATRIX * INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth, 1.0);
	vec3 pos = wp.xyz / wp.w;
	float gap = base.y - pos.y;
	if (gap < min_gap || gap >= gap_gone) {
		discard;
	}
	// Back into the item's own frame (belt_path.gdshaderinc's turn, undone), in its mesh's units.
	vec2 w = (pos.xz - base.xz) / axes.z;
	vec2 local = vec2(axes.x * w.x - axes.y * w.y, axes.y * w.x + axes.x * w.y) - rect.xy;
	vec2 half_size = max(rect.zw, vec2(0.01));
	float corner = min(half_size.x, half_size.y) * 0.5;
	vec2 q = abs(local) - (half_size - vec2(corner));
	float d = (length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - corner) * axes.z;
	if (d >= reach) {
		discard;
	}
	float eff_falloff = min(rim_falloff, reach * 0.55);
	float k = max(eff_falloff, px * 0.7);
	float dd = max(d, 0.0);
	float rim = rim_dark * (eff_falloff / k) * exp(-dd / k) * (1.0 - smoothstep(reach * 0.5, reach, dd));
	// Inside the footprint: the rim's darkness at the edge, easing to `inner` of it at the middle.
	float mid = min(half_size.x, half_size.y) * axes.z;
	rim *= d < 0.0 ? mix(1.0, inner, clamp(-d / max(mid, 0.01), 0.0, 1.0)) : 1.0;
	float dark = rim * strength
		* (1.0 - smoothstep(gap_full, gap_gone, gap))
		* fade;
	ALBEDO = vec3(pow(1.0 - clamp(dark, 0.0, 0.38), profile_gamma));
}
