// GPL-3.0, like the rest of Zenith. See wire_decode_native.h.
#include "wire_decode_native.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/array.hpp>

#include <cstring>
#include <vector>

using namespace godot;

namespace {

const uint8_t WIRE_MAGIC = 0xF3;
const int KIND_JSON = 0, KIND_DG = 1, KIND_MV = 16, KIND_BS = 17, KIND_BFAR = 18, KIND_CHUNK = 19, KIND_ENTS = 20,
		KIND_ST = 21, KIND_IH = 22, KIND_RB = 23;
const int RB_STRIDE = 11, ENT_STRIDE = 5, IH_STRIDE = 4, SX_STRIDE = 7, MV_STRIDE = 5, LANE_KEYS = 8;
const int FLAG_RELIABLE = 1;
const int BS_FIELD_COUNT = 8;
// lm, sl, ew, sh, pc, pu, dl, of; their stride as JSON has them (sl: by its count).
const char *BS_FIELDS[BS_FIELD_COUNT] = { "lm", "sl", "ew", "sh", "pc", "pu", "dl", "of" };
const int BS_STRIDES[BS_FIELD_COUNT] = { 12, 0, 4, 2, 5, 3, 1, 2 };

struct Buf {
	const uint8_t *d;
	int64_t size;
	uint32_t u32(int64_t at) const {
		uint32_t v;
		memcpy(&v, d + at, 4);
		return v;
	}
	int32_t s32(int64_t at) const {
		int32_t v;
		memcpy(&v, d + at, 4);
		return v;
	}
};

// A block: width u8 (4 or 8), count u32, then count signed numbers. ok false when it doesn't fit.
struct Block {
	bool ok = false;
	int width = 4;
	int64_t count = 0;
	int64_t data = 0; // offset of the first number
	int64_t next = 0;
};

Block block_at(const Buf &b, int64_t at, int64_t end) {
	Block r;
	if (at + 5 > end) {
		return r;
	}
	int width = b.d[at];
	int64_t count = b.u32(at + 1);
	if (width != 4 && width != 8) {
		return r;
	}
	int64_t a = at + 5;
	int64_t e = a + width * count;
	if (e > end) {
		return r;
	}
	r.ok = true;
	r.width = width;
	r.count = count;
	r.data = a;
	r.next = e;
	return r;
}

// The block's numbers as they are in the datagram (int32 or int64), as a Variant packed array.
Variant block_array(const Buf &b, const Block &k) {
	if (k.width == 4) {
		PackedInt32Array out;
		out.resize(k.count);
		if (k.count > 0) {
			memcpy(out.ptrw(), b.d + k.data, k.count * 4);
		}
		return out;
	}
	PackedInt64Array out;
	out.resize(k.count);
	if (k.count > 0) {
		memcpy(out.ptrw(), b.d + k.data, k.count * 8);
	}
	return out;
}

// The block's numbers widened to int64.
void block_wide(const Buf &b, const Block &k, std::vector<int64_t> &out) {
	out.resize(k.count);
	if (k.width == 8) {
		if (k.count > 0) {
			memcpy(out.data(), b.d + k.data, k.count * 8);
		}
	} else {
		for (int64_t i = 0; i < k.count; i++) {
			int32_t v;
			memcpy(&v, b.d + k.data + i * 4, 4);
			out[i] = v;
		}
	}
}

int64_t lane_key(int64_t unit, int64_t line) {
	if (line == 0) {
		return 0;
	}
	int64_t key = unit * LANE_KEYS + (line < 0 ? -line : line);
	return line > 0 ? key : -key;
}

PackedInt64Array to_packed64(const std::vector<int64_t> &v) {
	PackedInt64Array out;
	out.resize(v.size());
	if (!v.empty()) {
		memcpy(out.ptrw(), v.data(), v.size() * 8);
	}
	return out;
}

// One bs list from its block's layout (keys as two numbers) to JSON's. False when it doesn't add up.
bool bs_join(int field, const std::vector<int64_t> &flat, std::vector<int64_t> &out) {
	int64_t size = flat.size();
	const char *name = BS_FIELDS[field];
	if (strcmp(name, "of") == 0) {
		if (size % 2 != 0) {
			return false;
		}
		out = flat;
		return true;
	}
	if (strcmp(name, "sl") == 0) {
		int64_t i = 0;
		while (i < size) {
			if (i + 4 > size) {
				return false;
			}
			int64_t n = flat[i + 3];
			if (n < 0 || n > (size - i - 4) / 4) {
				return false;
			}
			out.push_back(lane_key(flat[i], flat[i + 1]));
			for (int64_t j = i + 2; j < i + 4 + n * 4; j++) {
				out.push_back(flat[j]);
			}
			i += 4 + n * 4;
		}
		return true;
	}
	bool lm = strcmp(name, "lm") == 0;
	int stride = BS_STRIDES[field];
	int64_t wide = stride + (lm ? 2 : 1);
	if (size % wide != 0) {
		return false;
	}
	for (int64_t i = 0; i < size; i += wide) {
		out.push_back(lane_key(flat[i], flat[i + 1]));
		if (lm) {
			for (int j = 2; j < 12; j++) {
				out.push_back(flat[i + j]);
			}
			out.push_back(lane_key(flat[i + 12], flat[i + 13]));
		} else if (stride > 1) {
			for (int j = 2; j < 1 + stride; j++) {
				out.push_back(flat[i + j]);
			}
		}
	}
	return true;
}

// MessageDecode.utf8_cleaned + get_string_from_utf8.
String text_of(const uint8_t *p, int64_t n) {
	// NUL ends a GDScript string read; the same here.
	int64_t len = 0;
	bool ascii = true;
	while (len < n && p[len] != 0) {
		if (p[len] >= 0x80) {
			ascii = false;
		}
		len++;
	}
	if (ascii && len == n) {
		return String::utf8((const char *)p, (int)n);
	}
	std::vector<uint8_t> out(p, p + n);
	int64_t i = 0;
	while (i < n) {
		int b = p[i];
		if (b < 0x80) {
			i++;
			continue;
		}
		int need = 0, lo = 0x80, hi = 0xBF;
		if (b >= 0xC2 && b <= 0xDF) {
			need = 1;
		} else if (b == 0xE0) {
			need = 2;
			lo = 0xA0;
		} else if (b >= 0xE1 && b <= 0xEF) {
			need = 2;
			if (b == 0xED) {
				hi = 0x9F;
			}
		} else if (b == 0xF0) {
			need = 3;
			lo = 0x90;
		} else if (b >= 0xF1 && b <= 0xF3) {
			need = 3;
		} else if (b == 0xF4) {
			need = 3;
			hi = 0x8F;
		}
		bool ok = need > 0 && i + need < n;
		if (ok) {
			for (int k = 0; k < need; k++) {
				int c = p[i + 1 + k];
				if (c < (k == 0 ? lo : 0x80) || c > (k == 0 ? hi : 0xBF)) {
					ok = false;
					break;
				}
			}
		}
		if (ok) {
			i += need + 1;
			continue;
		}
		out[i] = 0x3F;
		i++;
	}
	int64_t l2 = 0;
	while (l2 < n && out[l2] != 0) {
		l2++;
	}
	return String::utf8((const char *)out.data(), (int)l2);
}

// Each reader returns an empty Dictionary when the body doesn't add up.

Dictionary read_mv(const Buf &b, int flags, int64_t start, int64_t end) {
	Dictionary msg, none;
	int64_t p = start;
	if (p + 4 > end) {
		return none;
	}
	msg["t"] = "mv";
	msg["k"] = (int64_t)b.u32(p);
	p += 4;
	if (flags & FLAG_RELIABLE) {
		if (p + 4 > end) {
			return none;
		}
		msg["r"] = (int64_t)b.u32(p);
		p += 4;
	}
	if (p + 12 > end) {
		return none;
	}
	msg["part"] = (int64_t)b.u32(p);
	msg["parts"] = (int64_t)b.u32(p + 4);
	uint32_t period = b.u32(p + 8);
	if (period > 0) {
		msg["p"] = (int64_t)period;
	}
	Block k = block_at(b, p + 12, end);
	if (!k.ok || k.next != end || k.count % MV_STRIDE != 0) {
		return none;
	}
	msg["l"] = block_array(b, k);
	return msg;
}

Dictionary read_bs(const Buf &b, int flags, int64_t start, int64_t end, int version) {
	Dictionary msg, none;
	int64_t p = start;
	if (p + 4 > end) {
		return none;
	}
	msg["t"] = "bs";
	msg["k"] = (int64_t)b.u32(p);
	p += 4;
	if (flags & FLAG_RELIABLE) {
		if (p + 4 > end) {
			return none;
		}
		msg["r"] = (int64_t)b.u32(p);
		p += 4;
	}
	if (p + 32 > end) {
		return none;
	}
	msg["part"] = (int64_t)b.u32(p);
	msg["parts"] = (int64_t)b.u32(p + 4);
	msg["p"] = (int64_t)b.u32(p + 8);
	msg["w"] = (int64_t)b.u32(p + 12);
	msg["fx"] = (int64_t)b.s32(p + 16);
	msg["fy"] = (int64_t)b.s32(p + 20);
	msg["fr"] = (int64_t)b.u32(p + 24);
	if (b.u32(p + 28) != 0) {
		msg["ld"] = (int64_t)b.u32(p + 28);
	}
	p += 32;
	std::vector<int64_t> flat, joined;
	for (int f = 0; f < BS_FIELD_COUNT; f++) {
		Block k = block_at(b, p, end);
		if (!k.ok) {
			return none;
		}
		p = k.next;
		if (k.count == 0) {
			continue;
		}
		block_wide(b, k, flat);
		joined.clear();
		if (!bs_join(f, flat, joined)) {
			return none;
		}
		msg[BS_FIELDS[f]] = to_packed64(joined);
	}
	Block uids = block_at(b, p, end);
	if (!uids.ok || uids.next + 4 > end) {
		return none;
	}
	p = uids.next;
	int64_t n = b.u32(p);
	p += 4;
	int64_t text_end = p + n;
	if (text_end > end || (text_end != end && version < 5)) {
		return none;
	}
	if (text_end != end) {
		Block sx = block_at(b, text_end, end);
		if (!sx.ok || sx.next != end || sx.count % SX_STRIDE != 0) {
			return none;
		}
		if (sx.count > 0) {
			block_wide(b, sx, flat);
			msg["sx"] = to_packed64(flat);
		}
	}
	if (n > 0 || uids.count > 0) {
		// get_string_from_utf8().split(","): count = commas + 1.
		std::vector<int64_t> ids;
		block_wide(b, uids, ids);
		String all = String::utf8((const char *)b.d + p, (int)n);
		PackedStringArray names = all.split(",");
		if (names.size() != (int64_t)ids.size()) {
			return none;
		}
		Array qu;
		for (int64_t j = 0; j < (int64_t)ids.size(); j++) {
			qu.append(ids[j]);
			qu.append(names[j]);
		}
		msg["qu"] = qu;
	}
	return msg;
}

Dictionary read_bfar(const Buf &b, int64_t start, int64_t end) {
	Dictionary msg, none;
	if (start + 12 > end) {
		return none;
	}
	msg["t"] = "bfar";
	msg["k"] = (int64_t)b.u32(start);
	msg["cx"] = (int64_t)b.s32(start + 4);
	msg["cy"] = (int64_t)b.s32(start + 8);
	int64_t p = start + 12;
	Block bl[3];
	for (int j = 0; j < 3; j++) {
		bl[j] = block_at(b, p, end);
		if (!bl[j].ok) {
			return none;
		}
		p = bl[j].next;
	}
	int64_t lc = bl[0].count, cc = bl[1].count, hc = bl[2].count;
	if (p != end || lc % 5 != 0 || cc * 5 != lc * 2 || (hc != 0 && hc != cc)) {
		return none;
	}
	msg["l"] = block_array(b, bl[0]);
	msg["c"] = block_array(b, bl[1]);
	if (hc != 0) {
		msg["h"] = block_array(b, bl[2]);
	}
	return msg;
}

int64_t num_at(const Buf &b, const Block &k, int64_t i) {
	if (k.width == 8) {
		int64_t v;
		memcpy(&v, b.d + k.data + i * 8, 8);
		return v;
	}
	return b.s32(k.data + i * 4);
}

Dictionary read_v3(const Buf &b, int kind, int flags, int64_t start, int64_t end) {
	Dictionary msg, none;
	int64_t p = start;
	if (p + 4 > end) {
		return none;
	}
	msg["k"] = (int64_t)b.u32(p);
	p += 4;
	if (flags & FLAG_RELIABLE) {
		if (p + 4 > end) {
			return none;
		}
		msg["r"] = (int64_t)b.u32(p);
		p += 4;
	}
	if (kind == KIND_CHUNK) {
		if (p + 24 > end) {
			return none;
		}
		msg["t"] = "chunk";
		msg["cx"] = (int64_t)b.s32(p);
		msg["cy"] = (int64_t)b.s32(p + 4);
		msg["parts"] = (int64_t)b.u32(p + 8);
		msg["rs"] = (int64_t)b.u32(p + 12);
		msg["rv"] = (int64_t)b.u32(p + 16);
		msg["n"] = (int64_t)b.u32(p + 20);
		Block t = block_at(b, p + 24, end);
		if (!t.ok || t.next != end || t.count % 2 != 0) {
			return none;
		}
		msg["tiles"] = block_array(b, t);
		return msg;
	}
	if (kind == KIND_ENTS) {
		if (p + 16 > end) {
			return none;
		}
		msg["t"] = "ents";
		msg["cx"] = (int64_t)b.s32(p);
		msg["cy"] = (int64_t)b.s32(p + 4);
		msg["part"] = (int64_t)b.u32(p + 8);
		msg["parts"] = (int64_t)b.u32(p + 12);
		Block recs = block_at(b, p + 16, end);
		if (!recs.ok) {
			return none;
		}
		Block xi = block_at(b, recs.next, end);
		if (!xi.ok || xi.next + 4 > end) {
			return none;
		}
		p = xi.next;
		int64_t n = b.u32(p);
		p += 4;
		if (p + n != end || recs.count % ENT_STRIDE != 0) {
			return none;
		}
		int64_t count = recs.count / ENT_STRIDE;
		for (int64_t j = 0; j < xi.count; j++) {
			int64_t v = num_at(b, xi, j);
			if (v < 0 || v >= count) {
				return none;
			}
		}
		if ((n == 0) != (xi.count == 0)) {
			return none;
		}
		msg["e"] = block_array(b, recs);
		msg["xi"] = block_array(b, xi);
		if (n > 0) {
			msg["xt"] = text_of(b.d + p, end - p);
		}
		return msg;
	}
	if (kind == KIND_ST) {
		msg["t"] = "st";
		static const char *keys[3] = { "l", "lc", "ao" };
		for (int j = 0; j < 3; j++) {
			Block k = block_at(b, p, end);
			if (!k.ok || k.count % 2 != 0) {
				return none;
			}
			p = k.next;
			if (j == 0 || k.count != 0) {
				msg[keys[j]] = block_array(b, k);
			}
		}
		return p == end ? msg : none;
	}
	if (p + 12 > end) {
		return none;
	}
	msg["t"] = "ih";
	msg["part"] = (int64_t)b.u32(p);
	msg["parts"] = (int64_t)b.u32(p + 4);
	uint32_t period = b.u32(p + 8);
	if (period > 0) {
		msg["p"] = (int64_t)period;
	}
	Block h = block_at(b, p + 12, end);
	if (!h.ok || h.next != end || h.count % IH_STRIDE != 0) {
		return none;
	}
	msg["l"] = block_array(b, h);
	return msg;
}

Dictionary read_rb(const Buf &b, int flags, int64_t start, int64_t end) {
	Dictionary msg, none;
	int64_t p = start;
	if (p + 4 > end) {
		return none;
	}
	msg["t"] = "rb";
	msg["k"] = (int64_t)b.u32(p);
	p += 4;
	if (flags & FLAG_RELIABLE) {
		if (p + 4 > end) {
			return none;
		}
		msg["r"] = (int64_t)b.u32(p);
		p += 4;
	}
	if (p + 20 > end) {
		return none;
	}
	msg["part"] = (int64_t)b.u32(p);
	msg["parts"] = (int64_t)b.u32(p + 4);
	msg["p"] = (int64_t)b.u32(p + 8);
	msg["sm"] = (int64_t)b.u32(p + 12);
	uint32_t snap = b.u32(p + 16);
	if (snap != 0) {
		msg["snap"] = (int64_t)snap;
	}
	Block u = block_at(b, p + 20, end);
	if (!u.ok) {
		return none;
	}
	Block g = block_at(b, u.next, end);
	if (!g.ok || g.next != end) {
		return none;
	}
	if (u.count % RB_STRIDE != 0) {
		return none;
	}
	msg["u"] = block_array(b, u);
	if (g.count != 0) {
		msg["g"] = block_array(b, g);
	}
	return msg;
}

} // namespace

Array WireDecodeNative::read(const PackedByteArray &packet, int max_version) {
	Array entries;
	PackedInt32Array lengths;
	int64_t dg = -1;
	Buf b{ packet.ptr(), packet.size() };
	int64_t size = b.size;
	auto result = [&](int bad) {
		Array r;
		r.append(entries);
		r.append(lengths);
		r.append(dg);
		r.append(bad);
		return r;
	};
	if (size < 2 || b.d[0] != WIRE_MAGIC || b.d[1] < 1 || b.d[1] > max_version) {
		return result(1);
	}
	int version = b.d[1];
	int64_t at = 2;
	while (at < size) {
		if (at + 6 > size) {
			return result(1);
		}
		int kind = b.d[at];
		int flags = b.d[at + 1];
		int64_t start = at + 6;
		int64_t end = start + b.u32(at + 2);
		if (end > size) {
			return result(1);
		}
		if (kind == KIND_JSON) {
			entries.append(text_of(b.d + start, end - start));
			lengths.append((int32_t)(end - start));
		} else if (kind == KIND_DG) {
			if (end - start != 12) {
				return result(1);
			}
			dg = b.u32(start);
		} else {
			Dictionary msg;
			if (kind >= KIND_CHUNK && kind <= KIND_IH) {
				msg = read_v3(b, kind, flags, start, end);
			} else if (kind == KIND_RB) {
				msg = read_rb(b, flags, start, end);
			} else if (kind == KIND_BS) {
				msg = read_bs(b, flags, start, end, version);
			} else if (kind == KIND_BFAR) {
				msg = read_bfar(b, start, end);
			} else if (kind == KIND_MV) {
				msg = read_mv(b, flags, start, end);
			}
			if (msg.is_empty()) {
				return result(1);
			}
			entries.append(msg);
			lengths.append((int32_t)(end - start));
		}
		at = end;
	}
	return result(0);
}

String WireDecodeNative::packet_text(const PackedByteArray &packet) {
	return text_of(packet.ptr(), packet.size());
}

void WireDecodeNative::_bind_methods() {
	ClassDB::bind_method(D_METHOD("read", "packet", "max_version"), &WireDecodeNative::read);
	ClassDB::bind_method(D_METHOD("packet_text", "packet"), &WireDecodeNative::packet_text);
}
