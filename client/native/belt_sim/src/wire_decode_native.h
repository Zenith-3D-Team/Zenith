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

protected:
	static void _bind_methods();
};

} // namespace godot
