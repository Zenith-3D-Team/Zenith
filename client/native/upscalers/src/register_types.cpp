// The upscalers library (ZenithUpscalerCaps, ZenithHookUpscaler, ZenithFsrUpscaler, ZenithDlssUpscaler): its own GDExtension, never part of
// belt_sim. Loaded by scripts/menu/upscalers.gd when its DLL is there; Zenith runs the same without it.
#include "dlss_upscaler.h"
#include "fsr_upscaler.h"
#include "hook_upscaler.h"
#include "upscaler_caps.h"

#include <gdextension_interface.h>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>

using namespace godot;

static void initialize_upscalers(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
	GDREGISTER_CLASS(ZenithUpscalerCaps);
	GDREGISTER_CLASS(ZenithHookUpscaler);
	GDREGISTER_CLASS(ZenithFsrUpscaler);
	GDREGISTER_CLASS(ZenithDlssUpscaler);
}

static void uninitialize_upscalers(ModuleInitializationLevel p_level) {
}

extern "C" {
GDExtensionBool GDE_EXPORT upscalers_library_init(GDExtensionInterfaceGetProcAddress p_get_proc_address,
		const GDExtensionClassLibraryPtr p_library, GDExtensionInitialization *r_initialization) {
	godot::GDExtensionBinding::InitObject init_obj(p_get_proc_address, p_library, r_initialization);
	init_obj.register_initializer(initialize_upscalers);
	init_obj.register_terminator(uninitialize_upscalers);
	init_obj.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);
	return init_obj.init();
}
}
