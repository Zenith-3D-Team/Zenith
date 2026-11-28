#include "acid_goo_native.h"
#include "alt_icons_native.h"
#include "belt_draw_native.h"
#include "belt_items_native.h"
#include "belt_lattice_native.h"
#include "belt_mv_native.h"
#include "belt_sim_native.h"
#include "biter_gore_native.h"
#include "biter_ragdoll_native.h"
#include "movers_native.h"
#include "decor_native.h"
#include "chunk_build_native.h"
#include "inserter_arms_native.h"
#include "inserter_ingest_native.h"
#include "inserter_pose_native.h"
#include "inserter_swing_native.h"
#include "lod_mesher_native.h"
#include "terrain_field_native.h"
#include "texture_compress_native.h"
#include "udp_socket_native.h"
#include "wire_decode_native.h"

#include <gdextension_interface.h>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>

using namespace godot;

static void initialize_belt_sim(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
	GDREGISTER_CLASS(AcidGooNative);
	GDREGISTER_CLASS(AltIconsNative);
	GDREGISTER_CLASS(BeltSimNative);
	GDREGISTER_CLASS(BeltDrawNative);
	GDREGISTER_CLASS(BeltItemsNative);
	GDREGISTER_CLASS(BeltLatticeNative);
	GDREGISTER_CLASS(BeltMvNative);
	GDREGISTER_CLASS(BiterGoreNative);
	GDREGISTER_CLASS(BiterRagdollNative);
	GDREGISTER_CLASS(MoversNative);
	GDREGISTER_CLASS(UdpSocketNative);
	GDREGISTER_CLASS(DecorNative);
	GDREGISTER_CLASS(WireDecodeNative);
	GDREGISTER_CLASS(ChunkBuildNative);
	GDREGISTER_CLASS(InserterArmsNative);
	GDREGISTER_CLASS(InserterSwingNative);
	GDREGISTER_CLASS(InserterPoseNative);
	GDREGISTER_CLASS(InserterIngestNative);
	GDREGISTER_CLASS(LodMesherNative);
	GDREGISTER_CLASS(TerrainFieldNative);
	GDREGISTER_CLASS(TextureCompressNative);
}

static void uninitialize_belt_sim(ModuleInitializationLevel p_level) {
}

extern "C" {
GDExtensionBool GDE_EXPORT belt_sim_library_init(GDExtensionInterfaceGetProcAddress p_get_proc_address,
		const GDExtensionClassLibraryPtr p_library, GDExtensionInitialization *r_initialization) {
	godot::GDExtensionBinding::InitObject init_obj(p_get_proc_address, p_library, r_initialization);
	init_obj.register_initializer(initialize_belt_sim);
	init_obj.register_terminator(uninitialize_belt_sim);
	init_obj.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);
	return init_obj.init();
}
}
