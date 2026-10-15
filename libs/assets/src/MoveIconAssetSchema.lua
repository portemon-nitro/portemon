-- Strict schema of the generated move-icons manifest: one static image
-- record per semantic type and damage-category key, nothing else.

local MoveIconCache = require("libs.assets.src.MoveIconCache")
local Errors = require("libs.errors.src.Errors")

local MoveIconAssetSchema = {}

MoveIconAssetSchema.ERROR = { MANIFEST_INVALID = "MOVE_ICON_MANIFEST_INVALID" }

---@noreturn
local function fail(message)
  Errors.raise(MoveIconAssetSchema.ERROR.MANIFEST_INVALID, "move icon manifest: " .. message, {})
end

local function checkVisual(visual, what)
  if type(visual) ~= "table" then
    fail(what .. " must be a record")
  end
  local prefix = MoveIconCache.assetDir() .. "/"
  if type(visual.image) ~= "string" or visual.image:sub(1, #prefix) ~= prefix or visual.image:find("..", 1, true) then
    fail(what .. ".image must be a family-relative path")
  end
  for _, field in ipairs({ "width", "height" }) do
    if type(visual[field]) ~= "number" or visual[field] % 1 ~= 0 or visual[field] <= 0 then
      fail(what .. "." .. field .. " must be a positive integer")
    end
  end
  for key in pairs(visual) do
    if key ~= "image" and key ~= "width" and key ~= "height" and key ~= "offset" then
      fail(what .. " carries unknown field " .. tostring(key))
    end
  end
  if visual.offset ~= nil then
    local offset = visual.offset
    if type(offset) ~= "table" or type(offset.x) ~= "number" or type(offset.y) ~= "number" then
      fail(what .. ".offset must carry integer x and y")
    end
  end
end

local function checkSet(set, keys, what)
  if type(set) ~= "table" then
    fail(what .. " must be a record")
  end
  local expected = {}
  for _, key in ipairs(keys) do
    expected[key] = true
    checkVisual(set[key], what .. "." .. key)
  end
  for key in pairs(set) do
    if not expected[key] then
      fail(what .. " carries unknown key " .. tostring(key))
    end
  end
end

---@param manifest unknown
function MoveIconAssetSchema.assertManifest(manifest)
  if type(manifest) ~= "table" or manifest.schema ~= MoveIconCache.SCHEMA then
    fail("schema must be " .. MoveIconCache.SCHEMA)
  end
  for key in pairs(manifest) do
    if key ~= "schema" and key ~= "types" and key ~= "categories" then
      fail("carries unknown field " .. tostring(key))
    end
  end
  checkSet(manifest.types, MoveIconCache.TYPE_KEYS, "types")
  checkSet(manifest.categories, MoveIconCache.CATEGORY_KEYS, "categories")
end

return MoveIconAssetSchema
