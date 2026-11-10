-- Counts which events fire, and with which player, for Zenith's compatibility checks.
local names = {
  "on_built_entity", "on_pre_build", "script_raised_built", "script_raised_revive", "on_robot_built_entity",
  "on_player_mined_entity", "on_pre_player_mined_item", "on_player_mined_item", "script_raised_destroy",
  "on_player_rotated_entity", "on_player_flipped_entity", "on_gui_opened", "on_gui_closed",
  "on_entity_settings_pasted", "on_pre_entity_settings_pasted", "on_player_deconstructed_area",
  "on_marked_for_deconstruction", "on_marked_for_upgrade", "on_player_setup_blueprint", "on_player_cursor_stack_changed",
  "on_player_main_inventory_changed", "on_player_crafted_item", "on_pre_player_crafted_item", "on_player_fast_transferred",
  "on_player_built_tile", "on_player_mined_tile", "script_raised_set_tiles", "on_player_dropped_item",
  "on_picked_up_item", "on_player_used_capsule", "on_player_changed_position", "on_selected_entity_changed",
  "on_player_driving_changed_state", "on_player_placed_equipment", "on_player_removed_equipment",
  "on_player_ammo_inventory_changed", "on_player_gun_inventory_changed", "on_entity_renamed",
  "on_gui_click", "on_player_pipette", "on_cancelled_deconstruction", "on_player_alt_selected_area", "on_player_selected_area",
}
local function bump(name, e)
  storage.c = storage.c or {}
  storage.c[name] = (storage.c[name] or 0) + 1
  storage.p = storage.p or {}
  storage.p[name] = e.player_index or (e.player and e.player.index) or 0
end
for _, n in pairs(names) do
  local id = defines.events[n]
  if id then script.on_event(id, function(e) bump(n, e) end) end
end
remote.add_interface("probe", {
  get = function() return helpers.table_to_json({ c = storage.c or {}, p = storage.p or {} }) end,
  reset = function() storage.c = {}; storage.p = {} end,
})
