#include "belt_draw_native.h"
#include "belt_lattice_native.h"
#include "belt_sim_native.h"

#include <gdextension_interface.h>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>

using namespace godot;

static void initialize_belt_sim(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
	GDREGISTER_CLASS(BeltSimNative);
	GDREGISTER_CLASS(BeltDrawNative);
	GDREGISTER_CLASS(BeltLatticeNative);
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
