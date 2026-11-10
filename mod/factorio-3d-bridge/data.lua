-- "Show in Zenith": a key in the real game that brings the 3D client's window to the front, on the
-- same running world, or with no client connected asks the launcher beside Factorio to start one
-- (server/factorio-with-zenith.ps1; control.lua). The client's Ctrl+F9 comes the other way.
data:extend({
  {
    type = "custom-input",
    name = "f3d-show-3d",
    key_sequence = "CONTROL + F9",
    consuming = "none",
    action = "lua",
  },
})

-- The same as a button in the real game's top-left row of mod buttons (control.lua), with Zenith's
-- square gear logo (the client's icon, by David, used with permission: client/assets/branding).
data:extend({
  {
    type = "sprite",
    name = "f3d-zenith-gear",
    filename = "__factorio-3d-bridge__/graphics/zenith-gear.png",
    size = 64,
    flags = { "gui-icon" },
  },
})
