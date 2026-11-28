#pragma once

#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/rid.hpp>

#include <atomic>
#include <mutex>
#include <string>

namespace godot {
class RenderingDevice;
}

// Godot's Forward+ renderer writes motion vectors only for objects that moved: it clears its velocity buffer to
// (-1, -1) and draws just the moving ones into it (render_forward_clustered.cpp, "Render Motion Pass"). Everything
// else, most of the screen, keeps (-1, -1), and Godot's own FSR 2.2 and TAA rebuild those pixels from depth and the
// camera's reprojection (FFX_FSR2_OPTION_GODOT_DERIVE_INVALID_MOTION_VECTORS, motion_vector_inc.glsl). AMD's FSR 3.1/4
// and NVIDIA's DLSS know nothing of that marker: they read (-1, -1) as a jump of a whole screen and throw the history
// away (blur, flicker). MotionFill does what Godot's FSR 2.2 does, once, in a compute pass at the upscale point:
// a render-size copy of the velocity buffer with the marked pixels derived from depth and the reprojection matrix
// (the hook's RenderData.get_upscale_inputs "reprojection", the same one FSR 2.2 gets). Render thread only.
class MotionFill {
public:
	// This frame's filled motion vectors (the hook's inputs dictionary), or the raw velocity buffer when the pass
	// can't run (problem() says why). Records the compute pass into Godot's frame; the RenderingDevice's graph orders
	// it before whatever reads the result.
	godot::RID process(godot::RenderingDevice *p_rd, const godot::Dictionary &p_inputs);

	// Frees the GPU objects (on the render thread; safe from the main thread after RenderingServer.force_sync()).
	void release();

	~MotionFill();

	int64_t passes() const { return passes_.load(); }
	std::string problem() const;

private:
	bool ensure_pipeline(godot::RenderingDevice *p_rd);
	void set_problem(const std::string &p_why);

	godot::RID shader, pipeline, sampler;
	godot::RID texture; // R16G16 float, render size: what the upscaler gets.
	int32_t tex_w = 0, tex_h = 0;
	godot::RID uniform_set;
	godot::RID set_depth, set_velocity, set_texture; // What uniform_set was made with.
	bool failed = false; // The shader, pipeline, sampler, texture or uniform set couldn't be made: raw velocity until release().

	std::atomic<int64_t> passes_{ 0 };
	mutable std::mutex text_lock;
	std::string problem_;
};
