-- Transform, copy, and identity-change move families: temporary type,
-- move, ability, and item changes that live on the active entry, plus the
-- one intentional permanent change. Temporary records settle as volatile
-- markers through the validated surface, so leaving discards them with
-- the rest of the activation-local state and the persistent move set
-- never changes; permanent Sketch intent travels as an ordered event for
-- the persistent-mon owner, since the frame protocol carries no mon
-- handle. Source references: src/battle/battle_command.c and
-- src/battle/overlay_12_0224E4FC.c.

local BattleErrors = require("libs.battle.src.errors")

---@class IdentityMoves
local IdentityMoves = {}

IdentityMoves.MEMBERS = {
  "TRANSFORM",
  "SKETCH",
  "CONVERSION",
  "CONVERSION_2",
  "CAMOUFLAGE",
  "ROLE_PLAY",
  "SKILL_SWAP",
  "WORRY_SEED",
  "GASTRO_ACID",
  "POWER_SWAP",
  "GUARD_SWAP",
  "HEART_SWAP",
  "POWER_TRICK",
  "PSYCHO_SHIFT",
  "TRICK",
  "SWITCHEROO",
  "EMBARGO",
  "RECYCLE",
}

-- Temporary type changes recorded as volatile markers on the user.
local TYPE_MARKERS = {
  CONVERSION = true,
  CONVERSION_2 = true,
  CAMOUFLAGE = true,
}

-- Temporary ability changes recorded as volatile markers on the named
-- combatant: self-applied for Role Play, target-applied for the rest.
local ABILITY_SELF = {
  ROLE_PLAY = true,
}

local ABILITY_TARGET = {
  SKILL_SWAP = true,
  WORRY_SEED = true,
  GASTRO_ACID = true,
}

-- Stat-swap markers recorded on the user for the stat-stage owner.
local SWAP_MARKERS = {
  POWER_SWAP = true,
  GUARD_SWAP = true,
  HEART_SWAP = true,
  POWER_TRICK = true,
}

-- Item operations settle through the inventory owners, never the live
-- Bag, so these handlers emit the ordered item intent and complete.
local ITEM_INTENTS = {
  PSYCHO_SHIFT = true,
  TRICK = true,
  SWITCHEROO = true,
  EMBARGO = true,
  RECYCLE = true,
}

---@param frame table<string, unknown> move frame under execution
---@return table<string, unknown> semantic cause carried by writes and events
local function causeFor(frame)
  return { key = frame.executingMove }
end

---@param frame table<string, unknown> move frame under execution
---@return integer user combatant owning the move
local function userOf(frame)
  local actor = frame.actor --[[@as table<string, unknown>]]
  assert(type(actor.combatant) == "number", "identity changes read their user combatant")
  return actor.combatant --[[@as integer]]
end

---@param entry unknown target entry under resolution
---@return integer defender combatant receiving the change
local function targetOf(entry)
  assert(type(entry) == "table", "identity changes read their target entries")
  local record = entry --[[@as table<string, unknown>]]
  assert(type(record.combatant) == "number", "identity changes target combatants")
  return record.combatant --[[@as integer]]
end

---@param state unknown candidate typed state under the inert recording
---@return table<string, unknown> the versioned record
local function validateInert(state)
  if type(state) ~= "table" or state.version ~= 1 then
    error("inert markers carry their schema version")
  end
  return { version = 1 }
end

---@param ctx BattleContext mechanics context under execution
---@param combatant integer combatant receiving the volatile marker
---@param key string volatile identity under the marker
local function markVolatile(ctx, combatant, key)
  -- Unmigrated identity markers record presence only: no dispatched
  -- timing collects them (leave is never dispatched by any session
  -- lifecycle), and leaving discards them with the rest of the
  -- activation-local instances. Their mechanics are not yet implemented
  -- and must never be mistaken for live behavior.
  local entry = ctx:entryOf(combatant)
  if entry.activation == nil then
    error("identity markers scope to a live entry")
  end
  ctx:addBattleEffect(
    {
      key = key,
      stateVersion = 1,
      validateState = validateInert,
      timings = { { timing = "leave", handler = key, orderClass = "affliction" } },
      lifecycle = { stacking = "replace", transfer = "clear", persistent = false },
    },
    { kind = "active", combatant = combatant, activation = entry.activation },
    { kind = "move", combatant = combatant },
    { version = 1 }
  )
end

---@param ctx BattleContext mechanics context under execution
---@param frame table<string, unknown> move frame under execution
local function emitUsed(ctx, frame)
  local record = frame --[[@as table<string, unknown>]]
  ctx:emit("move-used", causeFor(record), {
    user = userOf(record),
    targets = #record.targets,
  })
end

---@param handler fun(ctx: BattleContext, frame: table<string, unknown>): table<string, unknown> shared family body under binding
---@return fun(ctx: BattleContext, frame: table<string, unknown>): table<string, unknown> distinct per-move binding over the shared body
local function bind(handler)
  local function stepBound(ctx, frame)
    return handler(ctx, frame)
  end
  return stepBound
end

-- Transform copies the sampled target identity onto the active entry
-- only: the marker carries the source combatant, leaving discards it with
-- the entry, and the persistent move set is never touched.
local function stepTransform(ctx, frame)
  assert(type(ctx) == "table", "identity changes step through the battle context")
  assert(type(frame) == "table", "identity changes step from their move frame")
  local record = frame --[[@as table<string, unknown>]]
  local defender = targetOf((record.targets --[[@as table<integer, unknown>]])[1])
  markVolatile(ctx, userOf(record), "TRANSFORM")
  ctx:emit("transformed", causeFor(record), { target = userOf(record), copiedFrom = defender })
  return { kind = "complete", result = "hit" }
end

-- Sketch is the intentional permanent change: the handler emits the
-- ordered sketch intent carrying the copied identity when the frame
-- threads one, so the persistent-mon owner can write it through. Without
-- a threaded identity the handler still completes its ordered event.
local function stepSketch(ctx, frame)
  assert(type(ctx) == "table", "identity changes step through the battle context")
  assert(type(frame) == "table", "identity changes step from their move frame")
  local record = frame --[[@as table<string, unknown>]]
  local locals = record.locals --[[@as table<string, unknown>]]
  if type(locals.copiedMove) == "string" and locals.copiedMove ~= "" then
    ctx:emit("sketched", causeFor(record), {
      target = userOf(record),
      copied = locals.copiedMove --[[@as string]],
    })
  else
    emitUsed(ctx, record)
  end
  return { kind = "complete", result = "hit" }
end

---@param onTarget boolean true when the marker lands on the sampled target
---@return fun(ctx: BattleContext, frame: table<string, unknown>): table<string, unknown> step handler recording the type marker
local function makeTypeMarker(onTarget)
  local function stepTypeMarker(ctx, frame)
    assert(type(ctx) == "table", "identity changes step through the battle context")
    assert(type(frame) == "table", "identity changes step from their move frame")
    local record = frame --[[@as table<string, unknown>]]
    if onTarget then
      markVolatile(
        ctx,
        targetOf((record.targets --[[@as table<integer, unknown>]])[1]),
        record.executingMove --[[@as string]]
      )
    else
      markVolatile(ctx, userOf(record), record.executingMove --[[@as string]])
    end
    emitUsed(ctx, record)
    return { kind = "complete", result = "hit" }
  end
  return stepTypeMarker
end

---@param onTarget boolean true when the marker lands on the sampled target
---@param marker string ability identity recorded by the marker
---@return fun(ctx: BattleContext, frame: table<string, unknown>): table<string, unknown> step handler recording the ability marker
local function makeAbilityMarker(onTarget, marker)
  local function stepAbilityMarker(ctx, frame)
    assert(type(ctx) == "table", "identity changes step through the battle context")
    assert(type(frame) == "table", "identity changes step from their move frame")
    local record = frame --[[@as table<string, unknown>]]
    if onTarget then
      markVolatile(ctx, targetOf((record.targets --[[@as table<integer, unknown>]])[1]), marker)
    else
      markVolatile(ctx, userOf(record), marker)
    end
    emitUsed(ctx, record)
    return { kind = "complete", result = "hit" }
  end
  return stepAbilityMarker
end

---@param key string identity move identity under binding
---@return fun(ctx: BattleContext, frame: table<string, unknown>): table<string, unknown> distinct per-move handler for the registry
local function bodyFor(key)
  if key == "TRANSFORM" then
    return bind(stepTransform)
  end
  if key == "SKETCH" then
    return bind(stepSketch)
  end
  if TYPE_MARKERS[key] == true then
    return bind(makeTypeMarker(false))
  end
  if ABILITY_SELF[key] == true then
    return bind(makeAbilityMarker(false, key))
  end
  if ABILITY_TARGET[key] == true then
    return bind(makeAbilityMarker(true, key))
  end
  if SWAP_MARKERS[key] == true then
    return bind(makeAbilityMarker(false, key))
  end
  if ITEM_INTENTS[key] == true then
    local function stepItemIntent(ctx, frame)
      assert(type(ctx) == "table", "identity changes step through the battle context")
      assert(type(frame) == "table", "identity changes step from their move frame")
      local record = frame --[[@as table<string, unknown>]]
      ctx:emit("item-intent", causeFor(record), {
        target = targetOf((record.targets --[[@as table<integer, unknown>]])[1]),
      })
      return { kind = "complete", result = "hit" }
    end
    return bind(stepItemIntent)
  end
  error(BattleErrors.missingBehavior("no identity handler is bound for the source identity", { key = key }))
end

--- Binds the identity family handlers into the owner table.
---@param owned table<string, fun(ctx: BattleContext, frame: table<string, unknown>): table<string, unknown>> handler owner receiving the family bindings
function IdentityMoves.register(owned)
  assert(type(owned) == "table", "identity moves register into their owner table")
  for _, key in ipairs(IdentityMoves.MEMBERS) do
    owned[key] = bodyFor(key)
  end
end

return IdentityMoves
