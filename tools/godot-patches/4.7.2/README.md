# Godot 4.7.2 patches

Zenith's changes to Godot `4.7.2-stable`, as `git diff` patch files (`NNNN-short-name.patch`), applied in
name order by `tools/godot/build_template.ps1` on top of the pinned tag. Only patches go here, never a copy of
Godot's source. Each patch is MIT-licensed like Godot, vendor-free (no AMD or NVIDIA code or headers), and says
at its top what it does and why.

Together they are the **upscaler hook** of the vendor-upscaler plan (step 2): a place in Godot's Forward+
renderer where an extension's native code upscales the 3D picture with Godot's own D3D12 command list, the way
AMD FSR and NVIDIA DLSS need. About 690 lines added.

| Patch | Lines (+/-) | What and why | Upstream |
| --- | --- | --- | --- |
| `0001-custom-upscaler-pr114670.patch` | +446 / -17, 22 files (5 of them docs) | `Viewport.SCALING_3D_MODE_CUSTOM` (6), the `ViewportUpscaler` resource and `RenderingServer.viewport_upscaler_*`: a render callback where FSR 2.2 would run, the upscaled texture to fill, motion vectors, jitter phase count and mip bias on request. The API Godot is likely to ship, so our code follows it | Backport of [godotengine/godot#114670](https://github.com/godotengine/godot/pull/114670) (open, milestone 4.x), unchanged: applies to 4.7.2 as it is |
| `0002-native-callback.patch` | +192, 5 files | `RenderingDevice.native_callback_add(callback, userdata, textures, usages)` and `native_callback_get_version()`: binds the engine's internal `driver_callback_add` (MetalFX's mechanism) for extensions. A C function runs with the D3D12 command list being recorded, at its place in the render graph, with the device, the queue and each texture's `ID3D12Resource` and the state (legacy barriers) or layout (enhanced barriers) it is in. With legacy barriers the textures are first moved to the states their usages ask for (copy source/dest, shader resource, UAV). After the callback the driver forgets its cached command-list state (descriptor heaps, root signatures, pipelines, dynamic state) | Zenith's own; #114670 has no command list, upstream may add its own later |
| `0003-upscale-inputs.patch` | +47, 6 files | `RenderData.get_upscale_inputs()` during a `ViewportUpscaler`'s callback: colour, depth, velocity, output and exposure textures, render and output size, jitter (render pixels as FSR 2.2 gets it, and NDC), jitter phase count, a reset flag (new or resized buffers), near/far, vertical FOV, orthogonal, delta time, the reprojection matrix. #114670 leaves these to the extension, which can't reach jitter, exposure or reset | Zenith's own |

The C layout an extension sees (`RenderingDeviceDriver::NativeCallbackInfo`, append-only; `struct_size` first):

```c
struct NativeCallbackInfo {
	uint32_t struct_size, api;            // api 1 = Direct3D 12
	uint64_t device, command_queue, command_list;   // ID3D12Device*, ID3D12CommandQueue*, ID3D12GraphicsCommandList*
	uint32_t barrier_model, resource_count;         // 0 = D3D12_RESOURCE_STATES, 1 = D3D12_BARRIER_LAYOUT
	const uint64_t *resources;            // ID3D12Resource*, in the order handed over
	const uint32_t *states;               // state/layout each is in: leave it there
};
void callback(const struct NativeCallbackInfo *info, void *userdata);
```

Usages accepted by `native_callback_add` (RenderingDevice's `CALLBACK_RESOURCE_USAGE_*`): `COPY_FROM` (1),
`COPY_TO` (2), `TEXTURE_SAMPLE` (13), `STORAGE_IMAGE_READ` (14), `STORAGE_IMAGE_READ_WRITE` (15); up to 16
textures. D3D12 only: Vulkan and the others report version 0 and refuse (plan step 9 adds Vulkan).

The user of all three: `client/native/upscalers/src/hook_upscaler.cpp` (`ZenithHookUpscaler`, a do-nothing copy
that proves the hook), later the AMD FSR and DLSS code. Window test: `tools/godot/hook_window_test.ps1`.

Updating Godot: re-check that each patch applies to the new tag (`git apply --check`), drop `0001` once Godot
ships #114670, and keep `0002`/`0003` as small as they are.
