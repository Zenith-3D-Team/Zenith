// InserterIngestNative: inserter_ingest_native.h says what it is (GPL-3.0, like the rest of Zenith).

#include "inserter_ingest_native.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/object.hpp>
#include <godot_cpp/core/object_id.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <algorithm>
#include <vector>

using namespace godot;

namespace {

// The object id a Variant holds (0: none, or not an object).
uint64_t id_of(const Variant &v) {
	if (v.get_type() != Variant::OBJECT) {
		return 0;
	}
	ObjectID oid = v.operator ObjectID();
	return (uint64_t)oid;
}

// A list's numbers as int64 (an Array of JSON floats or ints, or a binary frame's packed list), read in place.
struct WireList {
	const Array *array = nullptr;
	const int32_t *i32 = nullptr;
	const int64_t *i64 = nullptr;
	int64_t n = 0;
	PackedInt32Array keep32;
	PackedInt64Array keep64;
	Array keep_array;

	explicit WireList(const Variant &v) {
		switch (v.get_type()) {
			case Variant::ARRAY:
				keep_array = v;
				array = &keep_array;
				n = keep_array.size();
				break;
			case Variant::PACKED_INT32_ARRAY:
				keep32 = v;
				i32 = keep32.ptr();
				n = keep32.size();
				break;
			case Variant::PACKED_INT64_ARRAY:
				keep64 = v;
				i64 = keep64.ptr();
				n = keep64.size();
				break;
			default:
				break;
		}
	}
	int64_t at(int64_t i) const {
		if (i32 != nullptr) {
			return i32[i];
		}
		if (i64 != nullptr) {
			return i64[i];
		}
		return (int64_t)(*array)[i];
	}
};

} // namespace

InserterIngestNative::Entry *InserterIngestNative::bound(int64_t unit, const Dictionary &arm_map, const Dictionary *entities) {
	auto it = arms.find(unit);
	if (it == arms.end()) {
		return nullptr;
	}
	Entry &e = it->second;
	if (!e.live) {
		return nullptr;
	}
	Variant key(unit);
	if (!trust && id_of(arm_map.get(key, Variant())) != e.arm) {
		arms.erase(it);  // (dropped or made again: GDScript makes and binds it)
		return nullptr;
	}
	if (entities != nullptr && id_of(entities->get(key, Variant())) != e.rec) {
		e.live = false;  // (its record replaced or gone: GDScript binds it again)
		return nullptr;
	}
	return &e;
}

void InserterIngestNative::bind_arm(int64_t unit, int slot, Object *arm, Object *rec, const Vector2 &base, const Vector2i &chunk,
		bool ev_any, double last_heard) {
	if (arm == nullptr || rec == nullptr || slot < 0) {
		arms.erase(unit);
		return;
	}
	Entry &e = arms[unit];
	bool same = e.arm == (uint64_t)arm->get_instance_id();
	e.live = true;
	e.slot = slot;
	e.arm = (uint64_t)arm->get_instance_id();
	e.rec = (uint64_t)rec->get_instance_id();
	e.base = base;
	e.chunk = chunk;
	e.ev_any = ev_any;
	if (!same) {
		e.seen = false;
		e.last_heard = last_heard;
		e.synced = last_heard;
	} else {
		e.last_heard = std::max(e.last_heard, last_heard);
		e.synced = std::max(e.synced, last_heard);
	}
}

void InserterIngestNative::forget(int64_t unit) {
	auto it = arms.find(unit);
	if (it != arms.end()) {
		it->second.live = false;
	}
}

void InserterIngestNative::forget_chunk(const Vector2i &chunk) {
	for (auto &kv : arms) {
		if (kv.second.chunk == chunk) {
			kv.second.live = false;
		}
	}
}

void InserterIngestNative::unbind_all() {
	for (auto &kv : arms) {
		kv.second.live = false;
	}
}

void InserterIngestNative::clear() {
	arms.clear();
	first_events.clear();
}

PackedInt64Array InserterIngestNative::add_hands(const Variant &list_v, bool deltas, int64_t k, const Dictionary &entities,
		const Dictionary &arm_map) {
	PackedInt64Array rest;
	WireList list(list_v);
	int64_t unit = 0, x = 0, y = 0, item = 0;
	double kf = (double)k;
	for (int64_t i = 0; i + 3 < list.n; i += 4) {
		if (deltas) {
			unit += list.at(i);
			x += list.at(i + 1);
			y += list.at(i + 2);
			item += list.at(i + 3);
		} else {
			unit = list.at(i);
			x = list.at(i + 1);
			y = list.at(i + 2);
			item = list.at(i + 3);
		}
		Entry *e = pose.is_valid() ? bound(unit, arm_map, &entities) : nullptr;
		if (e == nullptr) {
			rest.push_back(unit);
			rest.push_back(x);
			rest.push_back(y);
			rest.push_back(item);
			hands_back++;
			continue;
		}
		// (_update, _add_sample) As the GDScript: the hand in float Vector2s, its angle and reach about the base.
		e->seen = true;
		Vector2 rel = Vector2((real_t)x, (real_t)y) / (real_t)256.0 - e->base;
		if (pose->add_sample(e->slot, kf, (double)rel.angle(), (double)rel.length(), (int)item, true)) {
			e->last_heard = std::max(e->last_heard, kf);
		}
		hands_native++;
	}
	return rest;
}

PackedInt64Array InserterIngestNative::add_events(const Variant &list_v, bool deltas, const Dictionary &arm_map) {
	PackedInt64Array rest;
	WireList list(list_v);
	int64_t v[9] = { 0, 0, 0, 0, 0, 0, 0, 0, 0 };
	for (int64_t i = 0; i + 8 < list.n; i += 9) {
		for (int j = 0; j < 9; j++) {
			v[j] = deltas ? v[j] + list.at(i + j) : list.at(i + j);
		}
		int kind = (int)v[0];
		int64_t unit = v[1];
		if (kind == EV_PLACED) {
			continue;  // (for belt_items.gd)
		}
		Entry *e = kind != EV_GONE && pose.is_valid() ? bound(unit, arm_map, nullptr) : nullptr;
		if (e == nullptr) {
			if (kind == EV_GONE) {
				arms.erase(unit);
			}
			for (int j = 0; j < 9; j++) {
				rest.push_back(v[j]);
			}
			events_back++;
			continue;
		}
		events_native++;
		double k = (double)v[2];
		double x = (double)v[6] / 256.0;
		double y = (double)v[7] / 256.0;
		if (!pose->add_event(e->slot, k, kind, (int)v[3], (int)v[4], (int)v[5], x, y, (int)v[8])) {
			continue;
		}
		if (!e->ev_any) {
			e->ev_any = true;
			first_events.push_back(unit);
		}
		e->last_heard = std::max(e->last_heard, k);
		if (kind == EV_SYNC) {
			// (A sync's position: a sample too, not into the preplan queue.)
			Vector2 rel = Vector2((real_t)x, (real_t)y) - e->base;
			if (pose->add_sample(e->slot, k, (double)rel.angle(), (double)rel.length(), v[3] > 0 ? (int)v[4] : 0, false)) {
				e->last_heard = std::max(e->last_heard, k);
			}
		}
		if (v[5] == 0 && (kind == EV_PICKED || kind == EV_DROPPED)) {
			pose->backdate(e->slot, k);
		}
	}
	return rest;
}

PackedInt64Array InserterIngestNative::take_first_events() {
	PackedInt64Array out = first_events;
	first_events.clear();
	return out;
}

PackedInt64Array InserterIngestNative::end_frame(const Dictionary &arm_map, const Dictionary &seen, Dictionary missing) {
	PackedInt64Array drops;
	Array keys = arm_map.keys();
	Array values = arm_map.values();
	static const StringName ev_any_name("ev_any");
	static const StringName ev_ticks_name("ev_ticks");
	int64_t n = keys.size();
	for (int64_t i = 0; i < n; i++) {
		const Variant &key = keys[i];
		const Variant &arm_v = values[i];
		bool kept = false;
		bool known = false;
		if (key.get_type() == Variant::INT) {
			auto it = arms.find((int64_t)key);
			if (it != arms.end() && it->second.arm == id_of(arm_v)) {
				// (A forgotten entry's events since went through the GDScript: its Arm says whether it has any.)
				kept = it->second.seen || (it->second.live && it->second.ev_any) || seen.has(key);
				known = kept || it->second.live;
			}
		}
		if (!known) {
			if (seen.has(key)) {
				kept = true;
			} else {
				Object *arm = arm_v;
				if (arm != nullptr) {
					kept = (bool)arm->get(ev_any_name) || ((PackedFloat64Array)arm->get(ev_ticks_name)).size() > 0;
				}
			}
		}
		if (kept) {
			missing.erase(key);
			continue;
		}
		int count = (int)missing.get(key, 0) + 1;
		if (count >= MISSING_FRAMES) {
			drops.push_back((int64_t)key);
			missing.erase(key);
		} else {
			missing[key] = count;
		}
	}
	for (auto &kv : arms) {
		kv.second.seen = false;
	}
	return drops;
}

PackedInt64Array InserterIngestNative::end_frame2(const Dictionary &seen, Dictionary missing, const Dictionary &unbound) {
	PackedInt64Array drops;
	static const StringName ev_any_name("ev_any");
	static const StringName ev_ticks_name("ev_ticks");
	bool any_seen = !seen.is_empty();
	auto count_one = [&](const Variant &key, bool kept) {
		if (kept) {
			if (!missing.is_empty()) {
				missing.erase(key);
			}
			return;
		}
		int count = (int)missing.get(key, 0) + 1;
		if (count >= MISSING_FRAMES) {
			drops.push_back((int64_t)key);
			missing.erase(key);
		} else {
			missing[key] = count;
		}
	};
	auto arm_has_events = [&](Object *arm) -> bool {
		return arm != nullptr && ((bool)arm->get(ev_any_name) || ((PackedFloat64Array)arm->get(ev_ticks_name)).size() > 0);
	};
	for (auto &kv : arms) {
		Entry &e = kv.second;
		Variant key(kv.first);
		bool kept = e.seen || (e.live && e.ev_any);
		if (!kept && any_seen) {
			kept = seen.has(key);
		}
		if (!kept && !e.live) {
			// (A forgotten entry's events since went through the GDScript: its Arm says whether it has any.)
			kept = arm_has_events(UtilityFunctions::instance_from_id((int64_t)e.arm));
		}
		count_one(key, kept);
		e.seen = false;
	}
	if (!unbound.is_empty()) {
		Array keys = unbound.keys();
		Array values = unbound.values();
		for (int64_t i = 0, n = keys.size(); i < n; i++) {
			const Variant &key = keys[i];
			Object *arm = values[i];
			bool kept = (any_seen && seen.has(key)) || arm_has_events(arm);
			count_one(key, kept);
		}
	}
	return drops;
}

PackedInt64Array InserterIngestNative::sweep(double threshold) {
	PackedInt64Array stale;
	static const StringName last_heard_name("last_heard");
	for (auto &kv : arms) {
		Entry &e = kv.second;
		double lh = e.last_heard;
		if (!e.live) {
			Object *arm = UtilityFunctions::instance_from_id((int64_t)e.arm);
			if (arm != nullptr) {
				double al = (double)arm->get(last_heard_name);
				if (e.last_heard > e.synced) {
					if (e.last_heard > al) {
						arm->set(last_heard_name, e.last_heard);
					}
					e.synced = e.last_heard;
				}
				lh = std::max(lh, al);
			}
		}
		if (lh >= 0.0 && lh < threshold) {
			stale.push_back(kv.first);
		}
	}
	return stale;
}

PackedFloat64Array InserterIngestNative::heard(const Dictionary &arm_map) {
	PackedFloat64Array out;
	for (auto it = arms.begin(); it != arms.end();) {
		Entry &e = it->second;
		if (e.last_heard > e.synced) {
			if (id_of(arm_map.get(Variant(it->first), Variant())) != e.arm) {
				it = arms.erase(it);
				continue;
			}
			out.push_back((double)it->first);
			out.push_back(e.last_heard);
			e.synced = e.last_heard;
		}
		++it;
	}
	return out;
}

PackedInt64Array InserterIngestNative::counts() const {
	PackedInt64Array out;
	out.push_back(hands_native);
	out.push_back(hands_back);
	out.push_back(events_native);
	out.push_back(events_back);
	return out;
}

void InserterIngestNative::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_pose", "pose"), &InserterIngestNative::set_pose);
	ClassDB::bind_method(D_METHOD("bind_arm", "unit", "slot", "arm", "rec", "base", "chunk", "ev_any", "last_heard"),
			&InserterIngestNative::bind_arm);
	ClassDB::bind_method(D_METHOD("forget", "unit"), &InserterIngestNative::forget);
	ClassDB::bind_method(D_METHOD("forget_chunk", "chunk"), &InserterIngestNative::forget_chunk);
	ClassDB::bind_method(D_METHOD("unbind_all"), &InserterIngestNative::unbind_all);
	ClassDB::bind_method(D_METHOD("clear"), &InserterIngestNative::clear);
	ClassDB::bind_method(D_METHOD("has", "unit"), &InserterIngestNative::has);
	ClassDB::bind_method(D_METHOD("size"), &InserterIngestNative::size);
	ClassDB::bind_method(D_METHOD("add_hands", "list", "deltas", "k", "entities", "arms"), &InserterIngestNative::add_hands);
	ClassDB::bind_method(D_METHOD("add_events", "list", "deltas", "arms"), &InserterIngestNative::add_events);
	ClassDB::bind_method(D_METHOD("take_first_events"), &InserterIngestNative::take_first_events);
	ClassDB::bind_method(D_METHOD("end_frame", "arms", "seen", "missing"), &InserterIngestNative::end_frame);
	ClassDB::bind_method(D_METHOD("heard", "arms"), &InserterIngestNative::heard);
	ClassDB::bind_method(D_METHOD("counts"), &InserterIngestNative::counts);
	ClassDB::bind_method(D_METHOD("set_trust", "trust"), &InserterIngestNative::set_trust);
	ClassDB::bind_method(D_METHOD("drop", "unit"), &InserterIngestNative::drop);
	ClassDB::bind_method(D_METHOD("end_frame2", "seen", "missing", "unbound"), &InserterIngestNative::end_frame2);
	ClassDB::bind_method(D_METHOD("sweep", "threshold"), &InserterIngestNative::sweep);
}
