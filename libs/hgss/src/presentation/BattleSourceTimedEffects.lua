-- Registry of source-timed native battle animation bodies. Each family module
-- returns one table mapping a producer task kind to its body constructor.
-- These are the overlay-07 callbacks whose native implementations own a fixed
-- internal timeline instead of script timing operands, so their source
-- phase machines live here rather than in the compiled-timing lane.
--
-- A body constructor receives the factory's (kind, args, context, services)
-- and returns a Support.newBody task exposing stepSourceTick/status/cancel/
-- dispose. Bodies never read script words; script operands arrive through the
-- producer-lowered `parameters` record.

local BattleSourceTimedEffects = {}

local FAMILIES = {
  require("libs.hgss.src.presentation.sourceTimed.Core"),
  require("libs.hgss.src.presentation.sourceTimed.ScaleMotion"),
  require("libs.hgss.src.presentation.sourceTimed.PositionMotion"),
  require("libs.hgss.src.presentation.sourceTimed.ShakeAndPalette"),
  require("libs.hgss.src.presentation.sourceTimed.SpriteFormation"),
  require("libs.hgss.src.presentation.sourceTimed.Background"),
}

---@type table<string, fun(kind: string, args: table<string, unknown>, context: table<string, unknown>, services: table<string, unknown>): table<string, unknown>>
local BODIES = {}
for _, family in ipairs(FAMILIES) do
  for kind, constructor in pairs(family) do
    assert(type(kind) == "string" and kind ~= "", "source-timed families name their task kinds")
    assert(type(constructor) == "function", "source-timed families register a constructor per kind: " .. kind)
    assert(BODIES[kind] == nil, "source-timed task kinds have one owner: " .. kind)
    BODIES[kind] = constructor
  end
end

---@param kind string task kind under admission
---@return boolean supported true when this lane owns the kind
function BattleSourceTimedEffects.supportsKind(kind)
  return type(kind) == "string" and BODIES[kind] ~= nil
end

---@param kind string task kind under construction
---@param args table<string, unknown> instruction-derived construction arguments
---@param context table<string, unknown> occurrence-bound playback context
---@param services table<string, unknown> factory services record
---@return table<string, unknown> runnable source-timed task
function BattleSourceTimedEffects.create(kind, args, context, services)
  local constructor = BODIES[kind]
  assert(constructor ~= nil, "source-timed task kinds are constructed only through their registered body")
  return constructor(kind, args, context, services)
end

return BattleSourceTimedEffects
