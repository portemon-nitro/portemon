-- Runtime composition for the directional entrance field effect. This keeps
-- generated-asset loading and lifecycle rebinding outside FieldRuntime's large
-- boot closure while leaving the effect state itself pure and engine-owned.

local FieldEffectAssetCache = require("libs.assets.src.field.FieldEffectAssetCache")
local FieldEntranceIndicator = require("libs.hgss.src.transition.FieldEntranceIndicator")
local Contract = require("libs.assets.src.DerivedAssetContract")

local M = {}

function M.load(cacheFs)
  local index = assert(
    cacheFs:loadLua(FieldEffectAssetCache.indexPath()),
    "field-effect cache is cold -- run `scripts/buildcache.sh` first"
  )
  assert(index.schema == Contract.fieldEffects.indexSchema, "field-effect index schema is unsupported")
  -- Effect definitions are trusted published artifacts: presence through the
  -- ready cache path is sufficient, and the producer pipeline plus explicit
  -- audit own whole-definition validation. Model construction asserts the
  -- model fields it actually consumes.
  local effects = {}
  for _, kind in ipairs({ "warp_entrance", "tall_grass", "very_tall_grass", "trainer_reveal", "surf_attachment" }) do
    local entry = assert(index.effects[kind], "field-effect index is missing " .. kind)
    local definition = assert(cacheFs:loadLua(entry.path), "field-effect definition is missing: " .. kind)
    effects[kind] = definition
  end
  for selector = 1, 14 do
    local kind = "follower_reaction_" .. selector
    local entry = assert(index.effects[kind], "field-effect index is missing " .. kind)
    local definition = assert(cacheFs:loadLua(entry.path), "field-effect definition is missing: " .. kind)
    effects[kind] = definition
  end
  local model = effects.warp_entrance.model
  return { model = model, schema = index.schema, index = index, effects = effects }, FieldEntranceIndicator.new()
end

return M
