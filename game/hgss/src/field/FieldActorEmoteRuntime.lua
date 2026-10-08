-- Runtime composition for overhead emote art. Mirrors
-- FieldEntranceIndicatorRuntime: keeps generated-asset loading outside
-- FieldRuntime's boot closure. There is no per-emote ticking state -- the actor
-- manager's draw record carries activeEmoteKind, its tick, and the final
-- presented world position, so the renderer reads those directly every frame.

local FieldActorEmote = require("libs.hgss.src.actors.FieldActorEmote")
local FieldEmoteAssetCache = require("libs.assets.src.field.FieldEmoteAssetCache")

local M = {}

-- Returns the emote art by kind (the movement emote models and the follower
-- reaction models already loaded with the field effects) and each follower
-- reaction's emote duration.
---@param cacheFs table<string, unknown>
---@param fieldEffects table<string, table<string, unknown>> loaded field-effect definitions by kind
---@return table<string, table<string, unknown>> modelsByKind, table<string, integer> reactionTicks
function M.load(cacheFs, fieldEffects)
  -- The descriptor is a trusted published artifact: presence through the
  -- ready cache path is sufficient. The renderer asserts the model fields it
  -- actually reads, and the producer pipeline plus explicit audit own
  -- whole-descriptor validation.
  local exclamation = assert(
    cacheFs:loadLua(FieldEmoteAssetCache.exclamationDescriptorPath()),
    "field emote cache is cold -- run `scripts/buildcache.sh` first"
  )
  assert(exclamation.schema == FieldEmoteAssetCache.SCHEMA, "field emote descriptor schema is unsupported")
  local models = { exclamation = exclamation.model }
  local reactionTicks = {}
  for selector = 1, 14 do
    local kind = "follower_reaction_" .. selector
    local definition = assert(fieldEffects[kind], "follower reaction definition is missing: " .. kind)
    models[kind] = definition.model
    reactionTicks[kind] = FieldActorEmote.reactionTicks(definition.lifecycle.frameCount)
  end
  return models, reactionTicks
end

return M
