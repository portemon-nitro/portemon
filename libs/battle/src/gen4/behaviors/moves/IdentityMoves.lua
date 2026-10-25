-- Transform and identity-change move families: temporary active-entry
-- changes and permanent Sketch learning. Mimic replaces one move slot
-- for the active entry and restores the roster slot when it leaves, as
-- the source mimicedMoveIndex copyback rule does. Source references:
-- BtlCmd_TryMimic and CheckLegalMimicMove in src/battle/battle_command.c
-- and src/battle/battle_util.c; other identity handlers use
-- src/battle/overlay_12_0224E4FC.c.

local BattleErrors = require("libs.battle.src.errors")
local CalledMoves = require("libs.battle.src.gen4.behaviors.moves.CalledMoves")
local NativeEffectHandlers = require("libs.battle.src.gen4.behaviors.effects.NativeEffectHandlers")
local NativePassiveBridge = require("libs.battle.src.gen4.NativePassiveBridge")

---@class IdentityMoves
local IdentityMoves = {}

IdentityMoves.MEMBERS = {
  "TRANSFORM",
  "SKETCH",
  "MIMIC",
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

-- These identities retain their event route until their source mutation
-- is resolved below. They remain bound during staged implementation.
local ITEM_INTENTS = {
  PSYCHO_SHIFT = true,
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

---@param frame table<string, unknown> move frame carrying immutable item facts
---@param item string held item identity under restriction checking
---@return boolean true when the source item pocket permits exchange
local function itemCanBeExchanged(frame, item)
  local locals = frame.locals --[[@as table<string, unknown>]]
  local itemFacts = locals.itemFacts
  if type(itemFacts) ~= "table" then
    error(BattleErrors.missingBehavior("held-item moves read immutable item facts", { item = item }))
  end
  local facts = (itemFacts --[[@as table<string, unknown>]])[item]
  if type(facts) ~= "table" then
    error(BattleErrors.missingBehavior("held-item moves resolve their item", { item = item }))
  end
  local pocket = (facts --[[@as table<string, unknown>]]).pocket
  if type(pocket) ~= "string" then
    error(BattleErrors.missingBehavior("held-item moves resolve item pocket", { item = item }))
  end
  return pocket ~= "mail"
end

-- Trick and Switcheroo swap existing possession only after the source
-- TrySwapItems checks admit both holders. Source references: BtlCmd_TrySwapItems
-- and subscript_0134_ExchangeItems.s.
local function stepExchangeItems(ctx, frame)
  assert(type(ctx) == "table", "held-item exchanges step through the battle context")
  assert(type(frame) == "table", "held-item exchanges step from their move frame")
  local record = frame --[[@as table<string, unknown>]]
  local user = userOf(record)
  local target = targetOf((record.targets --[[@as table<integer, unknown>]])[1])
  local locals = record.locals --[[@as table<string, unknown>]]
  if locals.itemTransferAllowed ~= true then
    return { kind = "complete", result = "failed" }
  end
  local userItem = ctx:heldItemOf(user)
  local targetItem = ctx:heldItemOf(target)
  if userItem == nil and targetItem == nil or ctx:heldItemWasKnockedOff(user) or ctx:heldItemWasKnockedOff(target) then
    return { kind = "complete", result = "failed" }
  end
  if
    (userItem ~= nil and not itemCanBeExchanged(record, userItem))
    or (targetItem ~= nil and not itemCanBeExchanged(record, targetItem))
  then
    return { kind = "complete", result = "failed" }
  end
  local abilities = locals.abilities --[[@as table<string, unknown>]]
  if abilities.foe == "STICKY_HOLD" and abilities.user ~= "MOLD_BREAKER" then
    return { kind = "complete", result = "failed" }
  end
  ctx:setHeldItem(user, targetItem)
  ctx:setHeldItem(target, userItem)
  ctx:emit("item-intent", causeFor(record), { target = target, mode = "swap" })
  emitUsed(ctx, record)
  return { kind = "complete", result = "hit" }
end

local function stepEmbargo(ctx, frame)
  assert(type(ctx) == "table", "identity changes step through the battle context")
  assert(type(frame) == "table", "identity changes step from their move frame")
  local record = frame --[[@as table<string, unknown>]]
  local target = targetOf((record.targets --[[@as table<integer, unknown>]])[1])
  local locals = record.locals --[[@as table<string, unknown>]]
  local abilities = locals.abilities --[[@as table<string, unknown>]]
  if
    ctx:hasBattleEffect(target, "substitute")
    or ctx:hasBattleEffect(target, "embargo")
    or abilities.foe == "MULTITYPE"
    or ctx:heldItemOf(target) == "GRISEOUS_ORB"
  then
    return { kind = "complete", result = "failed" }
  end
  local active = ctx:entryOf(target)
  assert(type(active.activation) == "number", "Embargo scopes to the target's active entry")
  ctx:addBattleEffect(
    NativeEffectHandlers.definitionFor("embargo"),
    { kind = "active", combatant = target, activation = active.activation },
    { kind = "move", combatant = userOf(record) },
    { version = 1, turns = 5 }
  )
  emitUsed(ctx, record)
  return { kind = "complete", result = "hit" }
end

local function stepPowerTrick(ctx, frame)
  assert(type(ctx) == "table", "identity changes step through the battle context")
  assert(type(frame) == "table", "identity changes step from their move frame")
  local record = frame --[[@as table<string, unknown>]]
  local user = userOf(record)
  if ctx:hasBattleEffect(user, "POWER_TRICK") then
    ctx:removeBattleEffect(user, "POWER_TRICK")
  else
    markVolatile(ctx, user, "POWER_TRICK")
  end
  emitUsed(ctx, record)
  return { kind = "complete", result = "hit" }
end

local function stepPsychoShift(ctx, frame)
  assert(type(ctx) == "table", "identity changes step through the battle context")
  assert(type(frame) == "table", "identity changes step from their move frame")
  local record = frame --[[@as table<string, unknown>]]
  local user = userOf(record)
  local target = targetOf((record.targets --[[@as table<integer, unknown>]])[1])
  local status = ctx:statusRecordOf(user)
  if status == nil or ctx:statusOf(target) ~= nil or ctx:hasBattleEffect(target, "substitute") then
    return { kind = "complete", result = "failed" }
  end
  local key = status.key --[[@as string]]
  local locals = record.locals --[[@as table<string, unknown>]]
  local defenders = locals.defenderTypes --[[@as table<integer, unknown>]]
  local targetTypes = defenders[target] --[[@as string[] ]]
  local typeImmune = false
  for _, targetType in ipairs(targetTypes) do
    if (key == "poison" or key == "toxic") and (targetType == "poison" or targetType == "steel") then
      typeImmune = true
    elseif key == "burn" and targetType == "fire" then
      typeImmune = true
    elseif key == "freeze" and targetType == "ice" then
      typeImmune = true
    end
  end
  local abilities = locals.abilities --[[@as table<string, unknown>]]
  local abilityImmune = false
  local statusAttempt = key == "toxic" and "poison" or key
  local weather = locals.weatherSuppressed == true and "none" or locals.weather
  if abilities.user ~= "MOLD_BREAKER" then
    local outcome = NativePassiveBridge.invokeFacts({
      combatant = target,
      ability = abilities.foe --[[@as string?]],
    }, "beforeHit", { statusAttempt = statusAttempt, weather = weather })
    for _, event in ipairs(outcome.events) do
      if event.prevented == true then
        abilityImmune = true
        break
      end
    end
  end
  if typeImmune or abilityImmune or ctx:sideEffect(ctx:entryOf(target).side, "safeguard") ~= nil then
    return { kind = "complete", result = "failed" }
  end
  local state = status.state --[[@as table<string, unknown>]]
  if ctx:applyStatus(target, key, state, causeFor(record)) then
    ctx:cureStatus(user, key, causeFor(record))
    local foeAbility = abilities.foe
    if type(foeAbility) == "string" then
      local entry = ctx:entryOf(target)
      if entry.activation == nil then
        error(BattleErrors.invalidState("Psycho Shift reflection scopes to a live target", { combatant = target }))
      end
      local reflected = NativePassiveBridge.invokeFacts(
        { combatant = target, activation = entry.activation, ability = foeAbility },
        "afterHit",
        { inflictedStatus = key }
      )
      for _, event in ipairs(reflected.events) do
        if type(event.reflected) == "string" then
          ctx:applyStatus(user, event.reflected, state, causeFor(record))
        end
      end
    end
    emitUsed(ctx, record)
    return { kind = "complete", result = "hit" }
  end
  return { kind = "complete", result = "failed" }
end

local function stepRecycle(ctx, frame)
  assert(type(ctx) == "table", "identity changes step through the battle context")
  assert(type(frame) == "table", "identity changes step from their move frame")
  local record = frame --[[@as table<string, unknown>]]
  local user = userOf(record)
  local item = ctx:recycleHeldItem(user)
  if item == nil then
    return { kind = "complete", result = "failed" }
  end
  ctx:emit("item-intent", causeFor(record), { target = user, mode = "recycle", item = item })
  emitUsed(ctx, record)
  return { kind = "complete", result = "hit" }
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

-- Sketch permanently replaces its own move slot with the target's last
-- used move and resets that slot to the copied move's base PP, matching
-- BtlCmd_TrySketch in src/battle/battle_command.c.
local function stepSketch(ctx, frame)
  assert(type(ctx) == "table", "identity changes step through the battle context")
  assert(type(frame) == "table", "identity changes step from their move frame")
  local record = frame --[[@as table<string, unknown>]]
  local locals = record.locals --[[@as table<string, unknown>]]
  local copiedMove = locals.copiedMove
  if
    type(copiedMove) ~= "string"
    or copiedMove == ""
    or copiedMove == "NONE"
    or copiedMove == "STRUGGLE"
    or copiedMove == "SKETCH"
    or copiedMove == "CHATTER"
  then
    return { kind = "complete", result = "failed" }
  end
  local user = userOf(record)
  if ctx:hasBattleEffect(user, "TRANSFORM") then
    return { kind = "complete", result = "failed" }
  end
  local moves = record.moves --[[@as table<integer, unknown>]]
  local slot = record.ppOwnerSlot
  if type(slot) ~= "number" or slot % 1 ~= 0 or slot < 0 then
    return { kind = "complete", result = "failed" }
  end
  local sketchSlot = moves[slot + 1]
  if
    type(sketchSlot) ~= "table" or (sketchSlot --[[@as table<string, unknown>]]).move ~= "SKETCH"
  then
    return { kind = "complete", result = "failed" }
  end
  for index, entry in ipairs(moves) do
    if
      index ~= slot + 1
      and type(entry) == "table"
      and (entry --[[@as table<string, unknown>]]).move == copiedMove
    then
      return { kind = "complete", result = "failed" }
    end
  end
  local moveFacts = locals.moveFacts --[[@as table<string, unknown>]]
  local facts = moveFacts[copiedMove]
  if type(facts) ~= "table" then
    error(BattleErrors.missingBehavior("Sketch resolves the copied move's PP facts", { key = copiedMove }))
  end
  local basePp = (facts --[[@as table<string, unknown>]]).basePp
  if type(basePp) ~= "number" or basePp % 1 ~= 0 or basePp < 1 then
    error(BattleErrors.invalidState("Sketch receives positive base PP facts", { key = copiedMove }))
  end
  local copiedSlot = sketchSlot --[[@as table<string, unknown>]]
  copiedSlot.move = copiedMove
  copiedSlot.pp = basePp
  if copiedMove == "LAST_RESORT" then
    ctx:resetUsedMoves(user)
  end
  ctx:emit("sketched", causeFor(record), { target = user, copied = copiedMove })
  return { kind = "complete", result = "hit" }
end

local function stepMimic(ctx, frame)
  assert(type(ctx) == "table", "identity changes step through the battle context")
  assert(type(frame) == "table", "identity changes step from their move frame")
  local record = frame --[[@as table<string, unknown>]]
  local locals = record.locals --[[@as table<string, unknown>]]
  local copiedMove = locals.copiedMove
  if not CalledMoves.isMimicMoveLegal(copiedMove) then
    return { kind = "complete", result = "failed" }
  end
  local user = userOf(record)
  local defender = targetOf((record.targets --[[@as table<integer, unknown>]])[1])
  if ctx:hasBattleEffect(user, "TRANSFORM") or ctx:hasBattleEffect(defender, "substitute") then
    return { kind = "complete", result = "failed" }
  end
  local moves = record.moves --[[@as table<integer, unknown>]]
  local slot = record.ppOwnerSlot
  if type(slot) ~= "number" or slot % 1 ~= 0 or slot < 0 then
    return { kind = "complete", result = "failed" }
  end
  local mimicSlot = moves[slot + 1]
  if
    type(mimicSlot) ~= "table" or (mimicSlot --[[@as table<string, unknown>]]).move ~= "MIMIC"
  then
    return { kind = "complete", result = "failed" }
  end
  for _, entry in ipairs(moves) do
    if
      type(entry) == "table" and (entry --[[@as table<string, unknown>]]).move == copiedMove
    then
      return { kind = "complete", result = "failed" }
    end
  end
  local moveFacts = locals.moveFacts --[[@as table<string, unknown>]]
  local facts = moveFacts[
    copiedMove --[[@as string]]
  ]
  if type(facts) ~= "table" then
    error(BattleErrors.missingBehavior("Mimic resolves the copied move's PP facts", {
      key = copiedMove --[[@as string]],
    }))
  end
  local basePp = (facts --[[@as table<string, unknown>]]).basePp
  if type(basePp) ~= "number" or basePp % 1 ~= 0 or basePp < 1 then
    error(BattleErrors.invalidState("Mimic receives positive base PP facts", {
      key = copiedMove --[[@as string]],
    }))
  end
  ctx:mimicMove(user, slot --[[@as integer]], copiedMove --[[@as string]], math.min(basePp, 5))
  if copiedMove == "LAST_RESORT" then
    ctx:resetUsedMoves(user)
  end
  ctx:emit("mimicked", causeFor(record), {
    user = user,
    target = defender,
    copied = copiedMove --[[@as string]],
    slot = slot,
  })
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
  if key == "MIMIC" then
    return bind(stepMimic)
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
    if key == "POWER_TRICK" then
      return bind(stepPowerTrick)
    end
    return bind(makeAbilityMarker(false, key))
  end
  if key == "TRICK" or key == "SWITCHEROO" then
    return bind(stepExchangeItems)
  end
  if key == "EMBARGO" then
    return bind(stepEmbargo)
  end
  if key == "PSYCHO_SHIFT" then
    return bind(stepPsychoShift)
  end
  if key == "RECYCLE" then
    return bind(stepRecycle)
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
