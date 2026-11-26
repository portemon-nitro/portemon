-- Strict contract for the generated bank keypad presentation. The producer
-- writes it and the runtime cache validates it, so a stale or partial bundle
-- fails readiness instead of presenting a partial keypad.

local Contract = require("libs.assets.src.DerivedAssetContract")

local BankAssetSchema = {}

BankAssetSchema.SCHEMA = Contract.bank.schema

BankAssetSchema.ERROR = {
  SHAPE_INVALID = "BANK_ASSET_SHAPE_INVALID",
  LAYOUT_INVALID = "BANK_ASSET_LAYOUT_INVALID",
}

local DISPLAY_WIDTH = 256
local DISPLAY_HEIGHT = 192
local MAX_DIGITS = 6

local function fail(code, message, context)
  error({ code = code, message = message, context = context or {} }, 0)
end

local function isInteger(value)
  return type(value) == "number" and value % 1 == 0
end

local function checkKeys(value, allowed, what)
  if type(value) ~= "table" then
    fail(BankAssetSchema.ERROR.SHAPE_INVALID, what .. " must be a record", { what = what })
  end
  for key in pairs(value) do
    if allowed[key] ~= true then
      fail(BankAssetSchema.ERROR.SHAPE_INVALID, what .. " has an unknown field " .. tostring(key), {
        what = what,
        field = tostring(key),
      })
    end
  end
end

local function checkImagePath(value, what)
  if type(value) ~= "string" or value == "" then
    fail(BankAssetSchema.ERROR.SHAPE_INVALID, what .. " must name its image", { what = what })
  end
  if value:find("..", 1, true) ~= nil then
    fail(BankAssetSchema.ERROR.SHAPE_INVALID, what .. " must not traverse its family", { what = what })
  end
end

local function checkRect(value, what, bounds, extra)
  local allowed = { x = true, y = true, width = true, height = true }
  for key in pairs(extra or {}) do
    allowed[key] = true
  end
  checkKeys(value, allowed, what)
  for _, axis in ipairs({ "x", "y", "width", "height" }) do
    if not isInteger(value[axis]) then
      fail(BankAssetSchema.ERROR.LAYOUT_INVALID, what .. " needs an integral " .. axis, { what = what, axis = axis })
    end
  end
  if value.width <= 0 or value.height <= 0 then
    fail(BankAssetSchema.ERROR.LAYOUT_INVALID, what .. " must cover at least one pixel", { what = what })
  end
  if value.x < 0 or value.y < 0 or value.x + value.width > bounds.width or value.y + value.height > bounds.height then
    fail(BankAssetSchema.ERROR.LAYOUT_INVALID, what .. " leaves the bottom display", { what = what })
  end
end

local function checkFrame(value, what, bounds, extra)
  local allowed = { image = true, x = true, y = true, width = true, height = true }
  for key in pairs(extra or {}) do
    allowed[key] = true
  end
  checkKeys(value, allowed, what)
  checkImagePath(value.image, what)
  for _, axis in ipairs({ "x", "y", "width", "height" }) do
    if not isInteger(value[axis]) then
      fail(BankAssetSchema.ERROR.SHAPE_INVALID, what .. " needs an integral " .. axis, { what = what, axis = axis })
    end
  end
  if value.width <= 0 or value.height <= 0 then
    fail(BankAssetSchema.ERROR.SHAPE_INVALID, what .. " must carry at least one pixel", { what = what })
  end
  if value.x < 0 or value.y < 0 then
    fail(BankAssetSchema.ERROR.SHAPE_INVALID, what .. " needs a non-negative atlas origin", { what = what })
  end
  if value.x + value.width > bounds.width or value.y + value.height > bounds.height then
    fail(BankAssetSchema.ERROR.SHAPE_INVALID, what .. " leaves its atlas", { what = what })
  end
end

---@param manifest unknown
---@return table<string, unknown>
function BankAssetSchema.validate(manifest)
  checkKeys(manifest, {
    schema = true,
    display = true,
    layer = true,
    sprites = true,
    keys = true,
    labels = true,
    timing = true,
  }, "bank manifest")
  if manifest.schema ~= BankAssetSchema.SCHEMA then
    fail(BankAssetSchema.ERROR.SHAPE_INVALID, "bank manifest schema is not current", { schema = manifest.schema })
  end

  local display = manifest.display
  checkKeys(display, { width = true, height = true }, "bank display")
  if display.width ~= DISPLAY_WIDTH or display.height ~= DISPLAY_HEIGHT then
    fail(BankAssetSchema.ERROR.LAYOUT_INVALID, "the keypad paints the 256x192 bottom display", {
      width = display.width,
      height = display.height,
    })
  end
  local bounds = { width = DISPLAY_WIDTH, height = DISPLAY_HEIGHT }

  -- The composited BG layer: the source's char/screen/palette set rendered
  -- once onto the display.
  local layer = manifest.layer
  checkKeys(layer, { image = true, width = true, height = true }, "bank layer")
  checkImagePath(layer.image, "bank layer")
  if not isInteger(layer.width) or not isInteger(layer.height) or layer.width <= 0 or layer.height <= 0 then
    fail(BankAssetSchema.ERROR.SHAPE_INVALID, "the bank layer carries its pixel size", {})
  end
  if layer.width < DISPLAY_WIDTH or layer.height < DISPLAY_HEIGHT then
    fail(BankAssetSchema.ERROR.LAYOUT_INVALID, "the bank layer covers the bottom display", {
      width = layer.width,
      height = layer.height,
    })
  end

  -- Sprite sets: one atlas per source resource group with the frames the
  -- keypad draws.
  local sprites = manifest.sprites
  checkKeys(sprites, {
    atlas = true,
    atlasWidth = true,
    atlasHeight = true,
    cursor = true,
    cursorButton = true,
    underline = true,
    back = true,
    confirm = true,
    quit = true,
    digits = true,
  }, "bank sprites")
  checkImagePath(sprites.atlas, "bank sprite atlas")
  for _, axis in ipairs({ "atlasWidth", "atlasHeight" }) do
    if not isInteger(sprites[axis]) or sprites[axis] <= 0 then
      fail(BankAssetSchema.ERROR.SHAPE_INVALID, "the sprite atlas carries its pixel size", { field = axis })
    end
  end
  local atlas = { width = sprites.atlasWidth, height = sprites.atlasHeight }
  for _, role in ipairs({ "cursor", "cursorButton", "underline", "back", "confirm", "quit" }) do
    checkFrame(sprites[role], "bank sprite " .. role, atlas)
  end
  if type(sprites.digits) ~= "table" or #sprites.digits ~= 10 then
    fail(BankAssetSchema.ERROR.SHAPE_INVALID, "the digit glyph set carries ten frames", {})
  end
  for digit = 0, 9 do
    local frame = sprites.digits[digit + 1]
    checkFrame(frame, "bank digit " .. digit, atlas, { digit = true })
    if frame.digit ~= digit then
      fail(BankAssetSchema.ERROR.SHAPE_INVALID, "a digit frame names its own digit", { digit = digit })
    end
  end

  -- The source touch regions: ten digit cells, the three action keys and the
  -- walkable dpad grid.
  local keys = manifest.keys
  checkKeys(keys, { digits = true, actions = true, dpad = true, cursorStrips = true }, "bank keys")
  if type(keys.digits) ~= "table" or #keys.digits ~= 10 then
    fail(BankAssetSchema.ERROR.SHAPE_INVALID, "the digit pad carries ten cells", {})
  end
  for digit = 0, 9 do
    local cell = keys.digits[digit + 1]
    checkRect(cell, "bank digit cell " .. digit, bounds, { digit = true })
    if cell.digit ~= digit then
      fail(BankAssetSchema.ERROR.SHAPE_INVALID, "a digit cell names its own digit", { digit = digit })
    end
  end
  if type(keys.actions) ~= "table" or #keys.actions ~= 3 then
    fail(BankAssetSchema.ERROR.SHAPE_INVALID, "the action row carries three keys", {})
  end
  local actionKeys = {}
  for _, action in ipairs(keys.actions) do
    checkKeys(action, { key = true, x = true, y = true, width = true, height = true }, "bank action key")
    if type(action.key) ~= "string" or actionKeys[action.key] then
      fail(BankAssetSchema.ERROR.SHAPE_INVALID, "an action key names its own role", { key = action.key })
    end
    actionKeys[action.key] = true
    checkRect({ x = action.x, y = action.y, width = action.width, height = action.height }, "bank action key", bounds)
  end
  for _, role in ipairs({ "back", "confirm", "quit" }) do
    if actionKeys[role] ~= true then
      fail(BankAssetSchema.ERROR.SHAPE_INVALID, "the action row carries the " .. role .. " key", { key = role })
    end
  end
  if type(keys.dpad) ~= "table" or #keys.dpad ~= 13 then
    fail(BankAssetSchema.ERROR.SHAPE_INVALID, "the dpad grid carries thirteen positions", {})
  end
  for index, box in ipairs(keys.dpad) do
    checkKeys(box, { x = true, y = true, up = true, down = true, left = true, right = true }, "bank dpad box")
    for _, axis in ipairs({ "x", "y" }) do
      if not isInteger(box[axis]) or box[axis] < 0 then
        fail(BankAssetSchema.ERROR.LAYOUT_INVALID, "a dpad box needs an integral position", { index = index })
      end
    end
    for _, direction in ipairs({ "up", "down", "left", "right" }) do
      local target = box[direction]
      if not isInteger(target) or target < 0 or target > 12 then
        fail(BankAssetSchema.ERROR.LAYOUT_INVALID, "a dpad neighbour names a grid position", { index = index })
      end
    end
  end
  if type(keys.cursorStrips) ~= "table" then
    fail(BankAssetSchema.ERROR.SHAPE_INVALID, "the cursor strips are a table by digit count", {})
  end
  for count = 1, MAX_DIGITS do
    local strips = keys.cursorStrips[count]
    if type(strips) ~= "table" or #strips ~= count then
      fail(BankAssetSchema.ERROR.LAYOUT_INVALID, "the cursor strips follow the digit count", { digits = count })
    end
    for _, strip in ipairs(strips) do
      checkRect(strip, "bank cursor strip", bounds)
    end
  end

  local labels = manifest.labels
  checkKeys(labels, { back = true, confirm = true, quit = true }, "bank labels")
  for _, role in ipairs({ "back", "confirm", "quit" }) do
    if type(labels[role]) ~= "string" or labels[role] == "" then
      fail(BankAssetSchema.ERROR.SHAPE_INVALID, "the " .. role .. " label resolves display text", { key = role })
    end
  end

  local timing = manifest.timing
  checkKeys(timing, { blinkFirstTicks = true, blinkSecondTicks = true, maxDigits = true }, "bank timing")
  if timing.blinkFirstTicks ~= 4 or timing.blinkSecondTicks ~= 2 or timing.maxDigits ~= MAX_DIGITS then
    fail(BankAssetSchema.ERROR.LAYOUT_INVALID, "the keypad keeps the source blink and cell counts", {})
  end
  return manifest --[[@as table<string, unknown>]]
end

---@param manifest unknown
---@return boolean, string?
function BankAssetSchema.check(manifest)
  local ok, err = pcall(BankAssetSchema.validate, manifest)
  if ok then
    return true
  end
  if type(err) == "table" and err.code ~= nil then
    return false, err.code
  end
  error(err, 0)
end

---@param manifest table<string, unknown> the compiled keypad bundle
---@return string[]
function BankAssetSchema.referencedPaths(manifest)
  local paths = {}
  local seen = {}
  local function add(path)
    if type(path) == "string" and not seen[path] then
      paths[#paths + 1] = path
      seen[path] = true
    end
  end
  add(manifest.layer and manifest.layer.image)
  local sprites = manifest.sprites
  if type(sprites) == "table" then
    add(sprites.atlas)
    for _, frame in pairs(sprites) do
      if type(frame) == "table" and type(frame.image) == "string" then
        add(frame.image)
      end
    end
  end
  table.sort(paths)
  return paths
end

return BankAssetSchema
