// WireDecodeNative: the bridge's binary frames read in C++, a twin of scripts/net/wire_decode.gd read()
// (docs/PROTOCOL.md, "Binary frames"). Same results as the GDScript: the same Dictionaries (keys in the same
// order), packed lists of the same types, the same refusals. Stateless: any thread may call it.
// GPL-3.0, like the rest of Zenith.
#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/string.hpp>

#include <cstdint>

namespace godot {

class WireDecodeNative : public RefCounted {
	GDCLASS(WireDecodeNative, RefCounted)

public:
	// A binary datagram read: [entries, lengths, dg, bad] (wire_decode.gd read()). max_version: the highest
	// wire version read (WireDecode.WIRE_VERSION).
	Array read(const PackedByteArray &packet, int max_version);
	// MessageDecode.packet_text: a datagram's text, invalid UTF-8 bytes read as "?".
	String packet_text(const PackedByteArray &packet);
	// LodChunk._decode_tile_rle + _decode_ent_rle (lod_data.gd) in one: a Distant Horizon `lod` message's
	// `tl` ([tile, count, ...]) and `el` ([proto, flags, count, ...]) runs as one value per cell:
	// [tiles: PackedInt32Array, protos: PackedInt32Array, flags: PackedByteArray], or [] where the GDScript
	// refuses (odd sizes, counts past `total` or short of it, negative ids, flags past 255, non-numbers).
	// `tl`/`el`: PackedInt32Array, PackedInt64Array or an Array (JSON); anything else counts as empty.
	Array lod_cells(const Variant &tl, const Variant &el, int total);

protected:
	static void _bind_methods();
};

} // namespace godot
