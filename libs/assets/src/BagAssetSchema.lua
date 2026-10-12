-- Authoritative validation for the generated field-bag presentation class.
-- The manifest carries the upper-pane hero (gender backdrops, description
-- frame, gender hero models with pocket-indexed animation states, normalized
-- camera/transform/light facts, the eight-entry edge-color table) plus the
-- lower-pane controls (eight pocket
-- tabs with one 256x32 strip visual per active pocket, six item slots pairing
-- full touch rects with
-- text windows and explicit text anchors plus registration markers, the
-- semantic focus visuals with their canonical target points, the count
-- readout, Cancel with its text window and source-centered label area,
-- pocket-aware browse/action/quantity count backgrounds (seven realized
-- variants per pocket), pocket-aware move count/origin backgrounds, the
-- retained selected-item panel, short/tall lower-message geometry,
-- activation feedback timing with control visuals, unchanged/changed move
-- commit clips, original/candidate move target visuals, pocket-aware hero
-- framing records, semantic action
-- text/templates, and the action/quantity/move overlays with no standalone
-- confirmation surface). Every loader, producer
-- writer, and test calls these validators, so no second interpretation of
-- the shapes exists. Unknown fields, wrong pane sizes, out-of-bounds
-- geometry, wrong tab/slot cardinality, unresolvable animation states, and
-- leaked source identities fail loudly. Love-free and filesystem-free.

local Errors = require("libs.errors.src.Errors")
local Checks = require("libs.assets.src.BagManifestChecks")
local HeroValidation = require("libs.assets.src.BagHeroValidation")
local InteractiveValidation = require("libs.assets.src.BagInteractiveValidation")

---@class BagAssetSchema
local BagAssetSchema = {}

BagAssetSchema.SCHEMA = "g4-bag-assets-v17"
BagAssetSchema.PANE_WIDTH = 256
BagAssetSchema.PANE_HEIGHT = 192
BagAssetSchema.TAB_COUNT = 8
BagAssetSchema.SLOT_COUNT = 6
BagAssetSchema.STATE_COUNT = 8

-- Source pocket keys in native order: hero animation states are selected by
-- this order.
BagAssetSchema.POCKETS = { "items", "medicine", "balls", "tmhm", "berries", "mail", "battle_items", "key_items" }

local POCKET_SET = {}
for _, pocket in ipairs(BagAssetSchema.POCKETS) do
  POCKET_SET[pocket] = true
end

local VALIDATION_CONSTANTS = {
  POCKETS = BagAssetSchema.POCKETS,
  POCKET_SET = POCKET_SET,
  PANE_WIDTH = BagAssetSchema.PANE_WIDTH,
  PANE_HEIGHT = BagAssetSchema.PANE_HEIGHT,
  TAB_COUNT = BagAssetSchema.TAB_COUNT,
  SLOT_COUNT = BagAssetSchema.SLOT_COUNT,
  STATE_COUNT = BagAssetSchema.STATE_COUNT,
}

-- Full manifest validation remains the one public v17 admission boundary.
-- Section owners report their first fault in the established hero/interactive
-- order before the source-identity sweep.
function BagAssetSchema.assertManifest(manifest)
  local context = {}
  Checks.checkRecord(
    manifest,
    { schema = true, logicalSize = true, hero = true, interactive = true },
    context,
    "manifest"
  )
  if manifest.schema ~= BagAssetSchema.SCHEMA then
    Checks.reject("manifest schema must be " .. BagAssetSchema.SCHEMA, context)
  end
  local logicalSize = manifest.logicalSize
  Checks.checkRecord(logicalSize, { width = true, height = true }, context, "manifest logicalSize")
  if logicalSize.width ~= BagAssetSchema.PANE_WIDTH or logicalSize.height ~= BagAssetSchema.PANE_HEIGHT then
    Checks.reject("manifest logicalSize must be 256x192", context)
  end
  HeroValidation.validate(manifest.hero, VALIDATION_CONSTANTS)
  InteractiveValidation.validate(manifest.interactive, VALIDATION_CONSTANTS)
  Checks.checkNoSourceIdentities(manifest, context, "manifest")
  return true
end

function BagAssetSchema.isValidManifest(manifest)
  ---@type boolean
  local ok
  ---@type unknown
  local result
  ok, result = pcall(BagAssetSchema.assertManifest, manifest)
  if ok then
    return true
  end
  if Errors.is(result) then
    local manifestError = result --[[@as Errors.Error]]
    if manifestError.code == "BAG_MANIFEST_INVALID" then
      return false, manifestError
    end
  end
  error(result, 0)
end

return BagAssetSchema
