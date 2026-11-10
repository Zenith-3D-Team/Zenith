-- Acting as the player, so other mods hear what was done.
--
-- Many mods react only to the events Factorio raises when a player acts: on_built_entity,
-- on_player_mined_entity, on_player_rotated_entity, on_entity_settings_pasted, on_gui_opened.
-- A script can't raise those itself (LuaBootstrap.raise_event takes custom events and a short list:
-- console chat, crafted item, fast transfer, script_raised_*), and the bridge's own way of building
-- (create_entity with raise_built) raises only script_raised_built, which those mods often ignore.
-- When the character the bridge plays belongs to a LuaPlayer (single-player, or f3d-player on a
-- server while that player is connected), the bridge acts through that player's own methods
-- instead, and Factorio raises the player events itself (lua-api 2.1.24: build_from_cursor raises
-- on_pre_build and on_built_entity, LuaControl.mine_entity on_pre_player_mined_item and
-- on_player_mined_entity, rotate{by_player} on_player_rotated_entity, copy_settings(e, player)
-- on_entity_settings_pasted, writing LuaControl.opened on_gui_opened). It also means Factorio's own
-- rules decide: reach (with every mod's bonus), fast-replace, building over ghosts, undergrounds.
--
-- The player's own character only: the bridge's player-less character has nobody to act as, and
-- keeps the script path. Off with the map setting f3d-act-as-player. Everything here runs from the
-- bridge's commands (on_tick) and changes the game only as the player's own action would, so it
-- stays deterministic in multiplayer.

local M = {}

local function get(obj, key)
  local ok, v = pcall(function() return obj[key] end)
  if ok then
    return v
  end
  return nil
end

-- The player to act as for character `c`, or nil (no player, or the setting is off).
function M.player(c)
  if not (c and c.valid) then
    return nil
  end
  local setting = settings.global["f3d-act-as-player"]
  if setting and setting.value == false then
    return nil
  end
  local p = get(c, "player")
  if not (p and p.valid and p.connected and get(p, "character") == c) then
    return nil
  end
  return p
end

-- Whether the player's cursor is free to borrow: nothing held, no ghost or blueprint record (in
-- single-player the Factorio window's cursor is the same one, and what it holds stays as it is).
local function cursor_free(p)
  local cursor = get(p, "cursor_stack")
  if not cursor or cursor.valid_for_read then
    return nil
  end
  if get(p, "cursor_ghost") or get(p, "cursor_record") then
    return nil
  end
  return cursor
end

-- Builds one `item` (of `quality`) at `position` from the player's cursor, as their click would:
-- true when built, false when Factorio refused, nil when this path doesn't apply (no player, the
-- cursor busy, another surface, the item not in the main inventory), so the caller builds its way.
function M.build(c, item, quality, position, direction, mirror, surface)
  local p = M.player(c)
  if not p or (surface and p.surface ~= surface) then
    return nil
  end
  local cursor = cursor_free(p)
  local inventory = cursor and c.get_main_inventory()
  if not inventory then
    return nil
  end
  local ok, stack = pcall(inventory.find_item_stack, { name = item, quality = quality or "normal" })
  if not (ok and stack and stack.valid_for_read) then
    return nil
  end
  if not cursor.transfer_stack(stack) or not cursor.valid_for_read then
    return nil
  end
  local before = cursor.count
  -- can_build_from_cursor has no `mirror` (2.1.24); a flipped entity covers the same tiles.
  local okc, can = pcall(p.can_build_from_cursor, { position = position, direction = direction })
  local spec = { position = position, direction = direction }
  if mirror then
    spec.mirror = true
  end
  local built = false
  if okc and can then
    pcall(p.build_from_cursor, spec)
    built = not cursor.valid_for_read or cursor.count < before
  end
  -- What's left goes back into the inventory (Factorio puts it in the slot it came from).
  if cursor.valid_for_read then
    p.clear_cursor()
  end
  return built
end

-- Mines `e` as the player: true when mined, nil when this path doesn't apply.
function M.mine(c, e)
  local p = M.player(c)
  if not p then
    return nil
  end
  local ok, mined = pcall(p.mine_entity, e)
  return ok and mined or false
end

-- The player to name as `by_player` / `player` in LuaEntity methods that take one, or nil.
function M.by(c)
  return M.player(c)
end

-- Tells mods the player opened `e` (on_gui_opened), as clicking it in Factorio does, or closed
-- it (nil: asks what's open to close, on_gui_closed). Only entities, only for the player's own
-- character; in single-player the Factorio window shows the same screen.
function M.opened(c, e)
  local p = M.player(c)
  if not p then
    return
  end
  if e then
    pcall(function() p.opened = e end)
  elseif get(p, "opened_gui_type") == defines.gui_type.entity then
    pcall(function() p.opened = nil end)
  end
end

return M
