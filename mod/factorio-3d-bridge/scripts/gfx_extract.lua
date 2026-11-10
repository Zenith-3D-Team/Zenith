-- Data stage only (data-final-fixes.lua): lists every prototype's graphics as file names and
-- numbers, for the client to read from the mods' own files (docs/MOD-GRAPHICS-PLAN.md). The runtime
-- API gives no icon or sprite paths, so this is the only place the bridge can learn them.
--
-- The list goes into a `mod-data` prototype ("zenith-graphics"), already written as JSON text in
-- parts of at most PART_BYTES, so the runtime only sends them (transport.send_text):
--   data.fp   fingerprint of the whole list and its format (two 32-bit polynomial hashes, hex):
--             the client keeps a copy per fingerprint, so a new FORMAT makes it fetch the list again
--   data.n    how many parts
--   data.b    bytes in all
--   data.p<i> part i: a JSON object {"icons": {kind: {name: layers}}, "tiles": {name: rec},
--             "decor": {name: rec}, "ents": {name: rec}}; every name is in one part only
--
-- Formats (docs/PROTOCOL.md, `gfx`):
--   icon layers  [[file, icon_size, tint or null, scale or null, shift or null], ...] as
--                res://data/icons.json, file as "__mod__/path"
--   tile         {"main": [[file, count, size, x, y, line_length, probability, weights or null, scale]],
--                 "mat": [file, count, scale], "layer": n, "group": layer_group, "water": 0/1,
--                 "map": [r, g, b] (0-1), "fx": the tile effect's picture when it is a
--                 wetland-water shader}
--   decorative   {"layer": render_layer, "box": [x1, y1, x2, y2], "pics": [[file, x, y, w, h,
--                 scale, shift x, shift y], ...]} as res://data/decoratives.json
--   sprite       [[file, x, y, w, h, scale, shift x, shift y], ...]: a `sprite` prototype's layers,
--                bottom first (mods' GUI pictures: SpritePath "se-..." on a button)
--
-- Nothing here runs at runtime, and it reads only data.raw: the same on every peer.

local M = {}

M.FORMAT = 2  -- 2: sprites
M.NAME = "zenith-graphics"
local PART_BYTES = 30000
local MAX_PICS = 8
local NULL = setmetatable({}, { __tostring = function() return "null" end })
M.NULL = NULL

---------------------------------------------------------------------------------------------
-- JSON, with sorted keys so the text (and the fingerprint) is the same whatever pairs() does.

local function is_array(t)
  if t == NULL then
    return false
  end
  local n = #t
  if n == 0 then
    return next(t) == nil and rawget(t, "__array") ~= nil
  end
  for k in pairs(t) do
    if type(k) ~= "number" or k < 1 or k > n or k % 1 ~= 0 then
      return false
    end
  end
  return true
end

local function num(v)
  if v ~= v or v == math.huge or v == -math.huge then
    return "0"
  end
  if v % 1 == 0 and math.abs(v) < 1e15 then
    return string.format("%d", v)
  end
  local s = string.format("%.5g", v)
  if s == "-0" then
    return "0"
  end
  return s
end

local ESCAPES = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }

local function str(s)
  return '"' .. s:gsub('[%c"\\]', function(c)
    return ESCAPES[c] or string.format("\\u%04x", c:byte())
  end) .. '"'
end

local encode

local function sorted_keys(t)
  local keys = {}
  for k in pairs(t) do
    keys[#keys + 1] = tostring(k)
  end
  table.sort(keys)
  return keys
end

encode = function(v)
  local tv = type(v)
  if v == NULL or v == nil then
    return "null"
  elseif tv == "number" then
    return num(v)
  elseif tv == "string" then
    return str(v)
  elseif tv == "boolean" then
    return v and "true" or "false"
  elseif tv == "table" then
    if is_array(v) then
      local out = {}
      for i = 1, #v do
        out[i] = encode(v[i])
      end
      return "[" .. table.concat(out, ",") .. "]"
    end
    local out = {}
    for _, k in ipairs(sorted_keys(v)) do
      if k ~= "__array" then
        out[#out + 1] = str(k) .. ":" .. encode(v[k])
      end
    end
    return "{" .. table.concat(out, ",") .. "}"
  end
  return "null"
end
M.encode = encode

-- Two polynomial hashes mod 2^32 (exact in doubles: h * 131 + 255 < 2^53), over every byte.
-- From FORMAT 2 on the format is hashed in first (FORMAT 1's fingerprints stay as they were).
local function fingerprint(texts, format)
  local a, b = 7, 11
  if format and format > 1 then
    texts = { "zenith-graphics format " .. format, table.unpack(texts) }
  end
  for _, s in ipairs(texts) do
    local n = #s
    for i = 1, n, 64 do
      local bytes = { s:byte(i, math.min(i + 63, n)) }
      for j = 1, #bytes do
        local c = bytes[j]
        a = (a * 131 + c) % 4294967296
        b = (b * 257 + c) % 4294967291
      end
    end
  end
  return string.format("%08x%08x", a, b)
end
M.fingerprint = fingerprint

---------------------------------------------------------------------------------------------
-- Reading prototypes

local function file_of(path)
  return type(path) == "string" and path or nil
end

-- Colours as 0-1 [r, g, b, a] (Factorio takes 0-255 when any of r, g, b is above 1).
local function tint_of(t)
  if type(t) ~= "table" then
    return NULL
  end
  local r = t.r or t[1] or 0
  local g = t.g or t[2] or 0
  local b = t.b or t[3] or 0
  local a = t.a or t[4] or 1
  if r > 1 or g > 1 or b > 1 then
    r, g, b = r / 255, g / 255, b / 255
    if a > 1 then
      a = a / 255
    end
  end
  return { r, g, b, a }
end

local function vec(s)
  if type(s) ~= "table" then
    return nil
  end
  return { s.x or s[1] or 0, s.y or s[2] or 0 }
end

-- An icon's layers, or nil.
function M.icon_layers(proto)
  if type(proto.icons) == "table" and #proto.icons > 0 then
    local out = {}
    for _, l in ipairs(proto.icons) do
      if file_of(l.icon) then
        out[#out + 1] = { l.icon, l.icon_size or 64, l.tint and tint_of(l.tint) or NULL, l.scale or NULL,
          vec(l.shift) or NULL }
      end
    end
    return #out > 0 and out or nil
  end
  if file_of(proto.icon) then
    return { { proto.icon, proto.icon_size or 64, NULL, NULL, NULL } }
  end
  return nil
end

local function same_layers(a, b)
  return a and b and encode(a) == encode(b)
end

-- Which icon kind a prototype type is: "item" for every item type (anything with a stack size),
-- the plan's other kinds by type, "entity" for the rest that can be placed in the world.
local KIND_OF_TYPE = {
  fluid = "fluid", ["virtual-signal"] = "virtual-signal", technology = "technology", recipe = "recipe",
  tile = "tile", ["item-group"] = "item-group", ["item-subgroup"] = false, quality = "quality",
  planet = "space-location", ["space-location"] = "space-location", ["asteroid-chunk"] = "asteroid-chunk",
  ["optimized-decorative"] = false, achievement = false, ["tips-and-tricks-item"] = false,
  shortcut = false, ["custom-input"] = false, ["mod-data"] = false, ["ammo-category"] = false,
  ["damage-type"] = false, ["recipe-category"] = false, ["fuel-category"] = false,
  ["resource-category"] = false, ["module-category"] = false, ["equipment-category"] = false,
  ["equipment-grid"] = false, ["trigger-target-type"] = false, ["noise-expression"] = false,
  ["noise-function"] = false, ["autoplace-control"] = false, ["map-settings"] = false,
  ["map-gen-presets"] = false, ["utility-constants"] = false, ["utility-sounds"] = false,
  ["utility-sprites"] = false, ["gui-style"] = false, font = false, sprite = false,
  ["mouse-cursor"] = false, sound = false, ["ambient-sound"] = false, ["tile-effect"] = false,
  ["particle"] = false, ["impact-category"] = false, ["space-connection"] = "space-connection",
  ["surface-property"] = false, surface = false, ["collision-layer"] = false, ["airborne-pollutant"] = false,
  ["burner-usage"] = false, ["procession"] = false, ["procession-layer-inheritance-group"] = false,
  ["deliver-category"] = false, ["deliver-impact-combination"] = false,
}

local function is_item_type(protos)
  for _, p in pairs(protos) do
    return type(p) == "table" and p.stack_size ~= nil
  end
  return false
end

local function kind_of(type_name, protos)
  local k = KIND_OF_TYPE[type_name]
  if k ~= nil then
    return k or nil
  end
  if type_name:sub(-10) == "-equipment" then
    return "equipment"
  end
  if is_item_type(protos) then
    return "item"
  end
  return "entity"
end

local function sorted_names(t)
  local names = {}
  for name in pairs(t) do
    if type(name) == "string" then
      names[#names + 1] = name
    end
  end
  table.sort(names)
  return names
end

-- {kind: {name: layers}}. Entities only when no item has their name (icons.json does the same);
-- recipes only when their icon isn't their item's or fluid's, and without an icon of their own
-- their main product's.
function M.icons(raw)
  local out = {}
  local function put(kind, name, layers)
    out[kind] = out[kind] or {}
    out[kind][name] = layers
  end
  local entity_types = {}
  for _, type_name in ipairs(sorted_names(raw)) do
    local protos = raw[type_name]
    local kind = type(protos) == "table" and kind_of(type_name, protos)
    if kind == "entity" then
      entity_types[#entity_types + 1] = type_name
    elseif kind and kind ~= "recipe" then
      for _, name in ipairs(sorted_names(protos)) do
        local layers = M.icon_layers(protos[name])
        if layers and not (out[kind] and out[kind][name]) then
          put(kind, name, layers)
        end
      end
    end
  end
  local items = out.item or {}
  for _, type_name in ipairs(entity_types) do
    for _, name in ipairs(sorted_names(raw[type_name])) do
      if not items[name] then
        local layers = M.icon_layers(raw[type_name][name])
        if layers and not (out.entity and out.entity[name]) then
          put("entity", name, layers)
        end
      end
    end
  end
  local fluids = out.fluid or {}
  for _, name in ipairs(sorted_names(raw.recipe or {})) do
    local r = raw.recipe[name]
    local own = M.icon_layers(r)
    if not own then
      local results = type(r.results) == "table" and r.results or {}
      local main = r.main_product
      if (not main or main == "") and #results == 1 and type(results[1]) == "table" then
        main = results[1].name
      end
      if main and main ~= name then
        own = items[main] or fluids[main]
      end
    end
    if own and not same_layers(own, items[name]) and not same_layers(own, fluids[name]) then
      put("recipe", name, own)
    end
  end
  return out
end

-- Tiles: what terrain_textures.gd needs to repack a tile's pictures.
local function rgb(c)
  local t = tint_of(c)
  if t == NULL then
    return nil
  end
  return { t[1], t[2], t[3] }
end

function M.tile(t, effects)
  local v = type(t.variants) == "table" and t.variants or {}
  local rec = {}
  if type(v.main) == "table" then
    local main = {}
    for _, e in ipairs(v.main) do
      if type(e) == "table" and file_of(e.picture) then
        local weights = NULL
        if type(e.weights) == "table" and #e.weights > 0 then
          weights = e.weights
        end
        main[#main + 1] = { e.picture, e.count or 1, e.size or 1, e.x or 0, e.y or 0, e.line_length or e.count or 1,
          e.probability or 1, weights, e.scale or 1 }
      end
    end
    if #main > 0 then
      rec.main = main
    end
  end
  local mat = v.material_background
  if type(mat) == "table" and file_of(mat.picture) then
    rec.mat = { mat.picture, mat.count or 1, mat.scale or 1 }
  end
  if not rec.main and not rec.mat then
    return nil
  end
  rec.layer = t.layer or 0
  rec.group = t.layer_group or "ground-natural"
  local layers = type(t.collision_mask) == "table" and t.collision_mask.layers or {}
  -- Water by its collision mask, but empty space, out-of-map and lava carry `water_tile` too
  -- (Space Age's empty-space round every platform, tile_collision_masks.out_of_map and .lava):
  -- none of those is drawn as water.
  local water = layers.water_tile and not (layers.empty_space or layers.out_of_map or layers.lava_tile)
  rec.water = water and 1 or 0
  rec.map = rgb(t.map_color)
  local fx = t.effect and effects and effects[t.effect]
  if type(fx) == "table" and type(fx.water) == "table" and fx.water.shader_variation == "wetland-water" then
    local tex = fx.water.image_textures
    if type(tex) == "table" and type(tex[1]) == "table" and file_of(tex[1].filename) then
      rec.fx = tex[1].filename
    end
  end
  return rec
end

-- Decoratives: a SpriteVariations as plain sprites (decor_index.py's sprites()).
local function sprites(pictures, out)
  out = out or {}
  if type(pictures) ~= "table" or #out >= MAX_PICS then
    return out
  end
  if pictures.sheet then
    return sprites(pictures.sheet, out)
  end
  if pictures.layers then
    return sprites(pictures.layers[1], out)
  end
  if pictures.filename then
    local count = pictures.variation_count or 1
    if count > 1 then
      local per_row = pictures.line_length or count
      if per_row == 0 then
        per_row = count
      end
      local w = pictures.width or pictures.size
      local h = pictures.height or pictures.size
      if type(w) == "table" then
        w, h = w[1], w[2]
      end
      for i = 0, math.min(count, MAX_PICS) - 1 do
        local s = {}
        for k, val in pairs(pictures) do
          s[k] = val
        end
        s.x = (pictures.x or 0) + (i % per_row) * (w or 0)
        s.y = (pictures.y or 0) + math.floor(i / per_row) * (h or 0)
        s.variation_count = nil
        out[#out + 1] = s
      end
      return out
    end
    out[#out + 1] = pictures
    return out
  end
  for _, p in ipairs(pictures) do
    sprites(p, out)
  end
  return out
end

local function size_of(s)
  local w, h = s.width, s.height
  if not (w and h) then
    local size = s.size
    if type(size) == "table" then
      w, h = size[1] or size.x, size[2] or size.y
    elseif size then
      w, h = size, size
    end
  end
  return w, h
end

local function pic(s)
  local w, h = size_of(s)
  if not (file_of(s.filename) and w and h) then
    return nil
  end
  local shift = vec(s.shift) or { 0, 0 }
  local at = vec(s.position) or { s.x or 0, s.y or 0 }
  return { s.filename, at[1], at[2], w, h, s.scale or 1, shift[1], shift[2] }
end

-- A `sprite` prototype as its layers (bottom first), or nil when it has no picture this can read.
function M.sprite(proto)
  local out = {}
  for _, l in ipairs(type(proto.layers) == "table" and proto.layers or { proto }) do
    local p = type(l) == "table" and pic(l)
    if p then
      out[#out + 1] = p
    end
  end
  return #out > 0 and out or nil
end

local function box_of(b)
  if type(b) ~= "table" then
    return { -0.5, -0.5, 0.5, 0.5 }
  end
  local a, z = vec(b[1] or b.left_top) or { -0.5, -0.5 }, vec(b[2] or b.right_bottom) or { 0.5, 0.5 }
  return { a[1], a[2], z[1], z[2] }
end
M.box_of = box_of

function M.decorative(d)
  local pics = {}
  for _, s in ipairs(sprites(d.pictures)) do
    local p = pic(s)
    if p and #pics < MAX_PICS then
      pics[#pics + 1] = p
    end
  end
  if #pics == 0 then
    return nil
  end
  return { layer = d.render_layer or "decorative", box = box_of(d.collision_box), pics = pics }
end

---------------------------------------------------------------------------------------------
-- Entities' pictures, for buildings Zenith has no model of: per direction (n, e, s, w) the first
-- frame of what Factorio draws at rest, as layers [file, x, y, w, h, scale, shift x, shift y,
-- tint or null, anim?] (anim: how the layer's frames run, M.anim_of), and what a machine adds while
-- working (kn, ke, ks, kw); shadows and lights left out. e, s and w only when they differ from n.

-- Types never drawn as a building (effects, flying things, things carried by others).
local SKIP_TYPES = {
  explosion = true, particle = true, ["optimized-particle"] = true, projectile = true, ["artillery-projectile"] = true,
  beam = true, smoke = true, ["smoke-with-trigger"] = true, ["trivial-smoke"] = true, stream = true, fire = true,
  sticker = true, ["flying-text"] = true, ["speech-bubble"] = true, ["highlight-box"] = true, ["item-entity"] = true,
  ["item-request-proxy"] = true, ["entity-ghost"] = true, ["tile-ghost"] = true, ["deconstructible-tile-proxy"] = true,
  ["artillery-flare"] = true, ["arrow"] = true, ["character-corpse"] = true, ["particle-source"] = true,
  ["leaf-particle"] = true, ["combat-robot"] = true, ["construction-robot"] = true, ["logistic-robot"] = true,
  ["capture-robot"] = true, ["cargo-pod"] = true, ["rocket-silo-rocket"] = true, ["rocket-silo-rocket-shadow"] = true,
  ["spider-leg"] = true, ["segment"] = true, ["lightning"] = true, ["temporary-container"] = true,
}

-- Where each kind of entity keeps its picture at rest, tried in order; then any sprite-like table.
-- (pictures.picture before pictures: a storage tank keeps its tank there beside its fluid flow's
-- sprites, which come first by name; base_animation after base: some mods' base is a blank pixel.)
local PICTURE_KEYS = {
  "picture", "pictures.picture", "pictures", "graphics_set.animation", "graphics_set.idle_animation", "structure", "animation",
  "animations", "base", "base_animation", "platform_picture", "off_animation", "on_animation", "chargable_graphics.picture",
  "picture_off", "graphics_set.base_visualisation.animation", "folded_animation", "run_animation",
  "graphics_set.animations", "variations", "base_picture", "sprite", "sprites", "idle_animation",
  "horizontal_animation", "power_on_animation", "connection_sprites", "graphics_set.picture",
}
local SKIP_WORDS = { "shadow", "light", "glow", "frozen", "patch", "icon", "reflection", "remnant", "corpse",
  "sound", "visualisation", "visualization", "working", "circuit", "radius", "integration", "overlay", "flipped" }
local DIRS = { "n", "e", "s", "w" }
local DIR_NAMES = { "north", "east", "south", "west" }

local function skip_key(k)
  k = tostring(k)
  for _, w in ipairs(SKIP_WORDS) do
    if k:find(w, 1, true) then
      return true
    end
  end
  return false
end

-- One sprite's layer for direction index d (0-3) of a rotated sprite or animation.
local function one_layer(spec, d)
  if spec.draw_as_shadow or spec.draw_as_light or spec.draw_as_glow then
    return nil
  end
  local file = spec.filename
  local x, y = spec.x or 0, spec.y or 0
  if not file and type(spec.filenames) == "table" then
    file = spec.filenames[1]
    x, y = 0, 0
  end
  if not file and type(spec.stripes) == "table" and type(spec.stripes[1]) == "table" then
    file = spec.stripes[1].filename
    x, y = spec.stripes[1].x or 0, spec.stripes[1].y or 0
  end
  local w, h = size_of(spec)
  -- (A 1x1 or 2x2 picture is a blank placeholder: aai signal transmission's `base`.)
  if type(file) ~= "string" or not w or not h or (w <= 2 and h <= 2) then
    return nil
  end
  local count = spec.direction_count
  if count and count > 1 and d > 0 and file == spec.filename then
    local frames = math.max(1, spec.frame_count or 1)
    local index = math.floor(count * d / 4) * frames
    local line = spec.line_length
    if not line or line <= 0 then
      line = count * frames
    end
    x = x + (index % line) * w
    y = y + math.floor(index / line) * h
  end
  local shift = vec(spec.shift) or { 0, 0 }
  local layer = { file, x, y, w, h, spec.scale or 1, shift[1], shift[2], spec.tint and tint_of(spec.tint) or NULL }
  local anim = M.anim_of(spec, d)
  if anim then
    layer[10] = anim
  end
  return layer
end

-- How a layer animates, for the client to step through its frames (sprite_standins.gd), or nil
-- for a still one: {f = frame count, l = frames a line (0: all on one), s = frames a tick, o = the
-- first frame's index (a rotated animation's direction), x, y = the sheet's corner, q = the frame
-- order (1-based, Factorio's frame_sequence), m = run mode, r = repeat count, fs = the files of a
-- `filenames` sheet with p = lines a file, st = stripes [[file, frames across, frames down, x, y]]}.
function M.anim_of(spec, d)
  local frames = spec.frame_count or 1
  local seq = type(spec.frame_sequence) == "table" and #spec.frame_sequence > 1 and spec.frame_sequence or nil
  if frames <= 1 and not seq then
    return nil
  end
  local a = { f = frames, l = spec.line_length or 0, s = spec.animation_speed or 1, x = spec.x or 0, y = spec.y or 0 }
  local count = spec.direction_count
  if count and count > 1 and d > 0 then
    a.o = math.floor(count * d / 4) * frames
  end
  if seq then
    a.q = seq
  end
  if spec.run_mode and spec.run_mode ~= "forward" then
    a.m = spec.run_mode
  end
  if spec.repeat_count and spec.repeat_count > 1 then
    a.r = spec.repeat_count
  end
  if not spec.filename and type(spec.filenames) == "table" then
    a.fs = spec.filenames
    a.p = spec.lines_per_file or 1
  elseif not spec.filename and type(spec.stripes) == "table" then
    local st = {}
    for _, stripe in ipairs(spec.stripes) do
      if type(stripe) == "table" and type(stripe.filename) == "string" then
        st[#st + 1] = { stripe.filename, stripe.width_in_frames or 1, stripe.height_in_frames or 1, stripe.x or 0, stripe.y or 0 }
      end
    end
    a.st = st
  end
  return a
end

-- The layers of a picture spec for direction index d, or nil.
local function layers_of(spec, d, depth)
  depth = (depth or 0) + 1
  if type(spec) ~= "table" or depth > 6 then
    return nil
  end
  if spec.north ~= nil then
    return layers_of(spec[DIR_NAMES[d + 1]] or spec.north, d, depth)
  end
  if spec.trunk ~= nil then  -- a tree's variation: trunk and leaves
    local out = layers_of(spec.trunk, d, depth) or {}
    for _, l in ipairs(layers_of(spec.leaves, d, depth) or {}) do
      out[#out + 1] = l
    end
    return #out > 0 and out or nil
  end
  if spec.sheet ~= nil or spec.sheets ~= nil then  -- Sprite4Way: a frame per direction
    local sheets = spec.sheets or { spec.sheet }
    local out = {}
    for _, sh in ipairs(sheets) do
      local l = one_layer(sh, 0)
      if l then
        if (sh.frames or 4) >= 4 then
          l[2] = l[2] + d * l[4]
        end
        out[#out + 1] = l
      end
    end
    return #out > 0 and out or nil
  end
  if spec.layers ~= nil then
    local out = {}
    for _, layer in ipairs(spec.layers) do
      for _, l in ipairs(layers_of(layer, d, depth) or {}) do
        out[#out + 1] = l
      end
    end
    return #out > 0 and out or nil
  end
  if spec.filename ~= nil or spec.filenames ~= nil or spec.stripes ~= nil then
    local l = one_layer(spec, d)
    return l and { l } or nil
  end
  if spec[1] ~= nil then  -- variations: the first
    return layers_of(spec[1], d, depth)
  end
  local names = {}
  for k, v in pairs(spec) do
    if type(k) == "string" and type(v) == "table" and not skip_key(k) then
      names[#names + 1] = k
    end
  end
  table.sort(names)
  for _, k in ipairs(names) do
    local out = layers_of(spec[k], d, depth)
    if out then
      return out
    end
  end
  return nil
end
M.layers_of = layers_of

local function at_path(proto, path)
  local v = proto
  for part in path:gmatch("[^.]+") do
    if type(v) ~= "table" then
      return nil
    end
    v = v[part]
  end
  return v
end

-- {n, e?, s?, w?} for one entity, or nil.
function M.entity_pictures(proto)
  local spec
  for _, key in ipairs(PICTURE_KEYS) do
    local v = at_path(proto, key)
    if type(v) == "table" and layers_of(v, 0) then
      spec = v
      break
    end
  end
  if not spec then
    local names = {}
    for k, v in pairs(proto) do
      if type(k) == "string" and type(v) == "table" and not skip_key(k) then
        names[#names + 1] = k
      end
    end
    table.sort(names)
    for _, k in ipairs(names) do
      if layers_of(proto[k], 0) then
        spec = proto[k]
        break
      end
    end
  end
  local out, first = {}, nil
  for d = 0, 3 do
    local layers = layers_of(spec, d)
    if layers then
      local text = encode(layers)
      if d == 0 then
        out.n, first = layers, text
      elseif text ~= first then
        out[DIRS[d + 1]] = layers
      end
    end
  end
  if not out.n then
    return nil
  end
  -- What a machine adds while it works (graphics_set.working_visualisations): kn, ke, ks, kw.
  local wv = type(proto.graphics_set) == "table" and proto.graphics_set.working_visualisations
  if type(wv) == "table" then
    local firstk
    for d = 0, 3 do
      local layers = {}
      for _, vis in ipairs(wv) do
        if type(vis) == "table" and not vis.draw_as_light and not vis.light then
          local anim = vis[DIR_NAMES[d + 1] .. "_animation"] or vis.animation
          for _, l in ipairs(layers_of(anim, d) or {}) do
            layers[#layers + 1] = l
          end
        end
      end
      if #layers > 0 then
        local text = encode(layers)
        if d == 0 then
          out.kn, firstk = layers, text
        elseif text ~= firstk then
          out["k" .. DIRS[d + 1]] = layers
        end
      end
    end
  end
  return out
end

function M.entity_entries(raw, entries)
  local kinds = {}
  for _, type_name in ipairs(sorted_names(raw)) do
    local protos = raw[type_name]
    if type(protos) == "table" and not SKIP_TYPES[type_name] and kind_of(type_name, protos) == "entity" then
      kinds[#kinds + 1] = type_name
    end
  end
  local seen = {}
  local list = {}
  for _, type_name in ipairs(kinds) do
    for _, name in ipairs(sorted_names(raw[type_name])) do
      local proto = raw[type_name][name]
      if not seen[name] and type(proto) == "table" and proto.collision_box ~= nil then
        seen[name] = true
        local ok, rec = pcall(M.entity_pictures, proto)
        if ok and rec then
          list[#list + 1] = { name, rec }
        end
      end
    end
  end
  table.sort(list, function(a, b) return a[1] < b[1] end)
  for _, e in ipairs(list) do
    entries[#entries + 1] = { "ents", "", e[1], e[2] }
  end
end

---------------------------------------------------------------------------------------------
-- The whole list in parts

-- Every entry as [section, kind or "", name, value], in a fixed order.
function M.entries(raw)
  local entries = {}
  local icons = M.icons(raw)
  for _, kind in ipairs(sorted_names(icons)) do
    for _, name in ipairs(sorted_names(icons[kind])) do
      entries[#entries + 1] = { "icons", kind, name, icons[kind][name] }
    end
  end
  local effects = raw["tile-effect"] or {}
  for _, name in ipairs(sorted_names(raw.tile or {})) do
    local rec = M.tile(raw.tile[name], effects)
    if rec then
      entries[#entries + 1] = { "tiles", "", name, rec }
    end
  end
  for _, name in ipairs(sorted_names(raw["optimized-decorative"] or {})) do
    local rec = M.decorative(raw["optimized-decorative"][name])
    if rec then
      entries[#entries + 1] = { "decor", "", name, rec }
    end
  end
  for _, name in ipairs(sorted_names(raw.sprite or {})) do
    local rec = M.sprite(raw.sprite[name])
    if rec then
      entries[#entries + 1] = { "sprites", "", name, rec }
    end
  end
  if M.entity_entries then
    M.entity_entries(raw, entries)
  end
  return entries
end

-- Groups the entries' JSON into parts of at most PART_BYTES (one entry bigger than that is a part
-- on its own).
function M.parts(entries, limit)
  limit = limit or PART_BYTES
  local parts = {}
  local current, bytes = {}, 0
  local function flush()
    if bytes == 0 then
      return
    end
    -- {section: {kind: {name: value}}} or {section: {name: value}}
    local out = {}
    local sections = {}
    for _, e in ipairs(current) do
      local sec = e[1]
      if not sections[sec] then
        sections[sec] = { order = {}, kinds = {} }
        out[#out + 1] = sec
      end
      local k = e[2]
      local s = sections[sec]
      if not s.kinds[k] then
        s.kinds[k] = {}
        s.order[#s.order + 1] = k
      end
      local list = s.kinds[k]
      list[#list + 1] = e[5]
    end
    local text = {}
    for _, sec in ipairs(out) do
      local s = sections[sec]
      local body
      if #s.order == 1 and s.order[1] == "" then
        body = "{" .. table.concat(s.kinds[""], ",") .. "}"
      else
        local kinds = {}
        for _, k in ipairs(s.order) do
          kinds[#kinds + 1] = str(k) .. ":{" .. table.concat(s.kinds[k], ",") .. "}"
        end
        body = "{" .. table.concat(kinds, ",") .. "}"
      end
      text[#text + 1] = str(sec) .. ":" .. body
    end
    parts[#parts + 1] = "{" .. table.concat(text, ",") .. "}"
    current, bytes = {}, 0
  end
  for _, e in ipairs(entries) do
    local item = str(e[3]) .. ":" .. encode(e[4])
    if bytes > 0 and bytes + #item + 40 > limit then
      flush()
    end
    current[#current + 1] = { e[1], e[2], e[3], e[4], item }
    bytes = bytes + #item + 40
  end
  flush()
  return parts
end

-- The mod-data prototype for data:extend.
function M.prototype(raw)
  local parts = M.parts(M.entries(raw))
  local data = { fp = fingerprint(parts, M.FORMAT), n = #parts }
  local total = 0
  for i, p in ipairs(parts) do
    data["p" .. i] = p
    total = total + #p
  end
  data.b = total
  return { type = "mod-data", name = M.NAME, data_type = "zenith-graphics", data = data }
end

return M
