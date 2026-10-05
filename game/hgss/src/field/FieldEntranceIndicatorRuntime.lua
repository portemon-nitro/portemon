-- Runtime composition for the directional entrance field effect. This keeps
-- generated-asset loading and lifecycle rebinding outside FieldRuntime's large
-- boot closure while leaving the effect state itself pure and engine-owned.

local FieldEffectAssetCache = require("libs.assets.src.field.FieldEffectAssetCache")
local FieldEntranceIndicator = require("libs.hgss.src.transition.FieldEntranceIndicator")
local ModelAsset = require("libs.assets.src.model.ModelAsset")
local Contract = require("libs.assets.src.DerivedAssetContract")

local M = {}

function M.load(cacheFs)
  local index = assert(
    cacheFs:loadLua(FieldEffectAssetCache.indexPath()),
    "field-effect cache is cold -- run `scripts/buildcache.sh` first"
  )
  assert(index.schema == Contract.fieldEffects.indexSchema, "field-effect index schema is unsupported")
  local effects = {}
  for _, kind in ipairs({ "warp_entrance", "tall_grass", "very_tall_grass", "trainer_reveal", "surf_attachment" }) do
    local entry = assert(index.effects[kind], "field-effect index is missing " .. kind)
    local definition = assert(cacheFs:loadLua(entry.path), "field-effect definition is missing: " .. kind)
    ModelAsset.validate(definition.model)
    effects[kind] = definition
  end
  local healingEntry = assert(index.effects.pokemon_center_heal, "field-effect index is missing pokemon_center_heal")
  assert(
    healingEntry.kind == "healing"
      and healingEntry.definition == "pokemon_center_heal"
      and healingEntry.path == FieldEffectAssetCache.definitionPath("pokemon_center_heal"),
    "field-effect index has an invalid pokemon_center_heal entry"
  )
  local healingDefinition =
    assert(cacheFs:loadLua(healingEntry.path), "field-effect definition is missing: pokemon_center_heal")
  assert(type(healingDefinition.models) == "table" and #healingDefinition.models == 1, "healing model is missing")
  ModelAsset.validate(healingDefinition.models[1])
  effects.pokemon_center_heal = healingDefinition
  local model = effects.warp_entrance.model
  ModelAsset.validate(model)
  return { model = model, schema = index.schema, index = index, effects = effects }, FieldEntranceIndicator.new()
end

return M
