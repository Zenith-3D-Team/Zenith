// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
// TextureCompressNative: clean-room CPU BC1 (DXT1) and BC3 (DXT5) texture compressor for
// terrain_textures.gd (FORMAT_DXT1) and decoratives.gd / decor_sheet_baker.gd (FORMAT_DXT5),
// enabling block compression in exported builds where Godot's editor-only etcpak is absent.
// Stateless: every method takes inputs and returns new buffers/Images, safe across worker threads.

#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>

#include <cstdint>

namespace godot {

class TextureCompressNative : public RefCounted {
	GDCLASS(TextureCompressNative, RefCounted)

protected:
	static void _bind_methods();

public:
	int version() const { return 1; }

	// Compresses RGBA8 base image bytes (width * height * 4) to BC1 / DXT1 (8 bytes per 4x4 block).
	// When generate_mipmaps is true, builds 2x2 box-filtered mip levels down to 1x1 into a
	// contiguous buffer matching Godot's Image.FORMAT_DXT1 layout.
	PackedByteArray compress_bc1(const PackedByteArray &p_rgba_bytes, int p_width, int p_height,
			bool p_generate_mipmaps = true) const;

	// Compresses RGBA8 base image bytes (width * height * 4) to BC3 / DXT5 (16 bytes per 4x4 block).
	// When generate_mipmaps is true, builds 2x2 box-filtered mip levels down to 1x1 into a
	// contiguous buffer matching Godot's Image.FORMAT_DXT5 layout.
	PackedByteArray compress_bc3(const PackedByteArray &p_rgba_bytes, int p_width, int p_height,
			bool p_generate_mipmaps = true) const;

	// Compresses an Image to Image.FORMAT_DXT1 (alpha=false) or Image.FORMAT_DXT5 (alpha=true).
	// Preserves existing mipmaps if present, or generates box-filtered mipmaps if generate_mipmaps is true.
	Ref<Image> compress_image(const Ref<Image> &p_img, bool p_alpha = false, bool p_generate_mipmaps = true) const;

	// Expected byte count for a DXT1 (alpha=false) or DXT5 (alpha=true) texture (with or without mipmaps).
	int64_t expected_size(int p_width, int p_height, bool p_alpha = false, bool p_mipmaps = true) const;
};

} // namespace godot
