// Marks fast UV-scrolling belt surfaces in Godot 4 Forward+'s FSR 2.2 reactive mask (color buffer alpha).
// Attached as `next_pass` on belt materials (`render_priority = -95`, after LookReactiveClear at -101).
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_back, fog_disabled, shadows_disabled;

#include "res://shaders/ground_height.gdshaderinc"

global uniform float f3d_belt_reactive;
uniform float belt_speed = 0.0;
// 24-bit mask of merged MaterialRows that have non-zero belt_speed; 0 on unmerged belt materials.
uniform int belt_row_mask = 0;

void vertex() {
	bool active = f3d_belt_reactive >= 0.5 && abs(belt_speed) >= 0.001;
	if (active && belt_row_mask != 0) {
		int row = clamp(int(CUSTOM2.r + 0.5), 0, 23);
		active = ((belt_row_mask >> row) & 1) != 0;
	}
	if (active) {
		bool timed = INSTANCE_CUSTOM.b < -0.5;
		float aflags = floor(-INSTANCE_CUSTOM.b - 1.0);
		bool belt_off = timed ? (mod(floor(aflags / 8.0), 2.0) > 0.5) : (abs(INSTANCE_CUSTOM.b - 5.0) < 0.5);
		active = !belt_off;
	}
	if (!active) {
		VERTEX = vec3(0.0);
	} else {
		VERTEX = ground_lift(VERTEX, MODEL_MATRIX);
	}
}

void fragment() {
	ALBEDO = vec3(0.0);
	ALPHA = clamp(0.55 + abs(belt_speed) * 0.05, 0.60, 0.95);
}
