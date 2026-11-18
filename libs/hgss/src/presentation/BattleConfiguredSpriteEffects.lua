-- Registry of opcode-78 configured-sprite callback bodies. The interpreter
-- spawns one managed sprite through gBattleAnimSpriteFuncTable (33 entries,
-- asm/battle_anim_data.s) and hands it to the selected source callback; each
-- body here reproduces that callback machine from the pinned
-- battle_anim_funcs.c, battle_anim_effects.c, and battle_anim_move_effects.c
-- implementations. The generic authored-frame renderer stays the fallback
-- for spawns whose kind is not registered (probes and future callbacks).

local BattleConfiguredSpriteEffects = {}

local FAMILIES = {
  require("libs.hgss.src.presentation.configuredSprite.Funcs"),
  require("libs.hgss.src.presentation.configuredSprite.MoveEffects"),
  require("libs.hgss.src.presentation.configuredSprite.Effects"),
}

---@type table<string, fun(kind: string, args: table<string, unknown>, context: table<string, unknown>, services: table<string, unknown>): table<string, unknown>>
local BODIES = {}
for _, family in ipairs(FAMILIES) do
  for kind, constructor in pairs(family) do
    assert(type(kind) == "string" and kind ~= "", "configured sprite families name their task kinds")
    assert(type(constructor) == "function", "configured sprite families register a constructor per kind: " .. kind)
    assert(BODIES[kind] == nil, "configured sprite task kinds have one owner: " .. kind)
    BODIES[kind] = constructor
  end
end

---@param kind string task kind under admission
---@return boolean supported true when this lane owns the kind
function BattleConfiguredSpriteEffects.supportsKind(kind)
  return type(kind) == "string" and BODIES[kind] ~= nil
end

---@param kind string task kind under construction
---@param args table<string, unknown> instruction-derived construction arguments
---@param context table<string, unknown> occurrence-bound playback context
---@param services table<string, unknown> factory services record with the lane's lease seam
---@return table<string, unknown> runnable configured sprite task
function BattleConfiguredSpriteEffects.create(kind, args, context, services)
  local constructor = BODIES[kind]
  assert(constructor ~= nil, "configured sprite task kinds are constructed only through their registered body")
  return constructor(kind, args, context, services)
end

return BattleConfiguredSpriteEffects
