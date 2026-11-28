#include "motion_fill.h"

#include <godot_cpp/classes/rd_sampler_state.hpp>
#include <godot_cpp/classes/rd_shader_source.hpp>
#include <godot_cpp/classes/rd_shader_spirv.hpp>
#include <godot_cpp/classes/rd_texture_format.hpp>
#include <godot_cpp/classes/rd_texture_view.hpp>
#include <godot_cpp/classes/rd_uniform.hpp>
#include <godot_cpp/classes/rendering_device.hpp>
#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/variant/callable_method_pointer.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/projection.hpp>
#include <godot_cpp/variant/typed_array.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <godot_cpp/variant/vector2i.hpp>

#include <cstring>

using namespace godot;

// Godot's own derivation (servers/rendering/renderer_rd/shaders/effects/motion_vector_inc.glsl, MIT) for the pixels
// its motion pass left at the (-1, -1) clear value, as FSR 2.2's LoadInputMotionVector does it
// (FFX_FSR2_OPTION_GODOT_DERIVE_INVALID_MOTION_VECTORS); the rest copied as they are. Units stay Godot's: previous
// minus current position in UV.
static const char *FILL_SHADER = R"(#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D depth_buffer;
layout(set = 0, binding = 1) uniform sampler2D velocity_in;
layout(rg16f, set = 0, binding = 2) uniform restrict writeonly image2D velocity_out;

layout(push_constant, std430) uniform Params {
	highp mat4 reprojection_matrix;
	vec2 resolution;
	vec2 pad;
}
params;

vec2 derive_motion_vector(vec2 uv, float depth, mat4 reprojection_matrix) {
	vec4 previous_pos_ndc = reprojection_matrix * vec4(uv * 2.0f - 1.0f, depth * 2.0f - 1.0f, 1.0f);
	return 0.5f + (previous_pos_ndc.xy / previous_pos_ndc.w) * 0.5f - uv;
}

void main() {
	ivec2 pos = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(vec2(pos), params.resolution))) {
		return;
	}
	vec2 velocity = texelFetch(velocity_in, pos, 0).xy;
	if (all(lessThanEqual(velocity, vec2(-1.0f, -1.0f)))) {
		float depth = texelFetch(depth_buffer, pos, 0).x;
		vec2 uv = (vec2(pos) + 0.5f) / params.resolution;
		velocity = derive_motion_vector(uv, depth, params.reprojection_matrix);
	}
	imageStore(velocity_out, pos, vec4(velocity, 0.0f, 0.0f));
}
)";

struct FillPush {
	float reprojection[16];
	float resolution[2];
	float pad[2];
};

std::string MotionFill::problem() const {
	std::lock_guard<std::mutex> lock(text_lock);
	return problem_;
}

void MotionFill::set_problem(const std::string &p_why) {
	std::lock_guard<std::mutex> lock(text_lock);
	if (problem_ != p_why) {
		problem_ = p_why;
		UtilityFunctions::print(String("Upscaling: motion vectors: ") + String::utf8(p_why.c_str()));
	}
}

bool MotionFill::ensure_pipeline(RenderingDevice *p_rd) {
	// failed first: a pipeline made but no sampler (or a later texture or uniform set that couldn't be made) isn't
	// retried every frame with an engine error each time.
	if (failed) {
		return false;
	}
	if (pipeline.is_valid()) {
		return true;
	}
	failed = true;
	Ref<RDShaderSource> source;
	source.instantiate();
	source->set_stage_source(RenderingDevice::SHADER_STAGE_COMPUTE, FILL_SHADER);
	Ref<RDShaderSPIRV> spirv = p_rd->shader_compile_spirv_from_source(source);
	if (spirv.is_null()) {
		set_problem("the fill shader didn't compile (no SPIR-V): raw velocity handed over");
		return false;
	}
	String error = spirv->get_stage_compile_error(RenderingDevice::SHADER_STAGE_COMPUTE);
	if (!error.is_empty()) {
		set_problem(std::string("the fill shader didn't compile: ") + error.utf8().get_data());
		return false;
	}
	shader = p_rd->shader_create_from_spirv(spirv, "Zenith upscaler motion fill");
	if (!shader.is_valid()) {
		set_problem("the fill shader wasn't made: raw velocity handed over");
		return false;
	}
	pipeline = p_rd->compute_pipeline_create(shader);
	if (!pipeline.is_valid()) {
		set_problem("the fill pipeline wasn't made: raw velocity handed over");
		return false;
	}
	Ref<RDSamplerState> ss;
	ss.instantiate();
	ss->set_mag_filter(RenderingDevice::SAMPLER_FILTER_NEAREST);
	ss->set_min_filter(RenderingDevice::SAMPLER_FILTER_NEAREST);
	ss->set_repeat_u(RenderingDevice::SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE);
	ss->set_repeat_v(RenderingDevice::SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE);
	sampler = p_rd->sampler_create(ss);
	failed = !sampler.is_valid();
	if (failed) {
		set_problem("the fill sampler wasn't made: raw velocity handed over");
	}
	return !failed;
}

RID MotionFill::process(RenderingDevice *p_rd, const Dictionary &p_inputs) {
	RID velocity = p_inputs.get("velocity", RID());
	RID depth = p_inputs.get("depth", RID());
	Vector2i size = p_inputs.get("render_size", Vector2i());
	if (!p_rd || !velocity.is_valid() || !depth.is_valid() || size.x <= 0 || size.y <= 0 || !ensure_pipeline(p_rd)) {
		return velocity;
	}
	if (!texture.is_valid() || !p_rd->texture_is_valid(texture) || tex_w != size.x || tex_h != size.y) {
		if (uniform_set.is_valid() && p_rd->uniform_set_is_valid(uniform_set)) {
			p_rd->free_rid(uniform_set);
		}
		uniform_set = RID();
		if (texture.is_valid() && p_rd->texture_is_valid(texture)) {
			p_rd->free_rid(texture);
		}
		Ref<RDTextureFormat> tf;
		tf.instantiate();
		tf->set_format(RenderingDevice::DATA_FORMAT_R16G16_SFLOAT);
		tf->set_width(uint32_t(size.x));
		tf->set_height(uint32_t(size.y));
		tf->set_usage_bits(RenderingDevice::TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice::TEXTURE_USAGE_STORAGE_BIT);
		Ref<RDTextureView> tv;
		tv.instantiate();
		texture = p_rd->texture_create(tf, tv);
		tex_w = size.x;
		tex_h = size.y;
		if (!texture.is_valid()) {
			tex_w = tex_h = 0;
			failed = true;
			set_problem("the filled motion vectors' texture wasn't made: raw velocity handed over");
			return velocity;
		}
	}
	// Godot's buffers are remade on resize (and the uniform set freed with them): a new set when any changed.
	if (!uniform_set.is_valid() || !p_rd->uniform_set_is_valid(uniform_set) || set_depth != depth || set_velocity != velocity || set_texture != texture) {
		if (uniform_set.is_valid() && p_rd->uniform_set_is_valid(uniform_set)) {
			p_rd->free_rid(uniform_set);
		}
		Ref<RDUniform> u_depth;
		u_depth.instantiate();
		u_depth->set_uniform_type(RenderingDevice::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE);
		u_depth->set_binding(0);
		u_depth->add_id(sampler);
		u_depth->add_id(depth);
		Ref<RDUniform> u_velocity;
		u_velocity.instantiate();
		u_velocity->set_uniform_type(RenderingDevice::UNIFORM_TYPE_SAMPLER_WITH_TEXTURE);
		u_velocity->set_binding(1);
		u_velocity->add_id(sampler);
		u_velocity->add_id(velocity);
		Ref<RDUniform> u_out;
		u_out.instantiate();
		u_out->set_uniform_type(RenderingDevice::UNIFORM_TYPE_IMAGE);
		u_out->set_binding(2);
		u_out->add_id(texture);
		TypedArray<Ref<RDUniform>> uniforms;
		uniforms.push_back(u_depth);
		uniforms.push_back(u_velocity);
		uniforms.push_back(u_out);
		uniform_set = p_rd->uniform_set_create(uniforms, shader, 0);
		set_depth = depth;
		set_velocity = velocity;
		set_texture = texture;
		if (!uniform_set.is_valid()) {
			failed = true;
			set_problem("the fill pass's inputs couldn't be bound: raw velocity handed over");
			return velocity;
		}
	}
	FillPush push = {};
	Projection reprojection = p_inputs.get("reprojection", Projection());
	for (int i = 0; i < 4; i++) {
		for (int j = 0; j < 4; j++) {
			push.reprojection[i * 4 + j] = float(reprojection.columns[i][j]); // Column-major, as GLSL's mat4.
		}
	}
	push.resolution[0] = float(size.x);
	push.resolution[1] = float(size.y);
	PackedByteArray bytes;
	bytes.resize(sizeof(FillPush));
	memcpy(bytes.ptrw(), &push, sizeof(FillPush));

	const int64_t list = p_rd->compute_list_begin();
	p_rd->compute_list_bind_compute_pipeline(list, pipeline);
	p_rd->compute_list_bind_uniform_set(list, uniform_set, 0);
	p_rd->compute_list_set_push_constant(list, bytes, uint32_t(bytes.size()));
	p_rd->compute_list_dispatch(list, uint32_t((size.x + 7) / 8), uint32_t((size.y + 7) / 8), 1);
	p_rd->compute_list_end();
	passes_++;
	return texture;
}

// On the render thread: the GPU objects (the RenderingDevice defers the real frees past frames in flight).
static void free_fill_rids(const Array &p_rids) {
	RenderingServer *rs = RenderingServer::get_singleton();
	RenderingDevice *rd = rs ? rs->get_rendering_device() : nullptr;
	if (!rd || p_rids.size() < 5) {
		return;
	}
	const RID set = p_rids[0], texture = p_rids[1], pipeline = p_rids[2], sampler = p_rids[3], shader = p_rids[4];
	if (set.is_valid() && rd->uniform_set_is_valid(set)) {
		rd->free_rid(set);
	}
	if (texture.is_valid() && rd->texture_is_valid(texture)) {
		rd->free_rid(texture);
	}
	if (pipeline.is_valid() && rd->compute_pipeline_is_valid(pipeline)) {
		rd->free_rid(pipeline);
	}
	if (sampler.is_valid()) {
		rd->free_rid(sampler);
	}
	if (shader.is_valid()) {
		rd->free_rid(shader);
	}
}

void MotionFill::release() {
	if (!shader.is_valid() && !texture.is_valid() && !sampler.is_valid()) {
		return;
	}
	Array rids;
	rids.push_back(uniform_set);
	rids.push_back(texture);
	rids.push_back(pipeline);
	rids.push_back(sampler);
	rids.push_back(shader);
	uniform_set = texture = pipeline = sampler = shader = RID();
	set_depth = set_velocity = set_texture = RID();
	tex_w = tex_h = 0;
	failed = false;
	RenderingServer *rs = RenderingServer::get_singleton();
	if (rs) {
		rs->call_on_render_thread(callable_mp_static(&free_fill_rids).bind(rids));
	}
}

MotionFill::~MotionFill() {
	release();
}
