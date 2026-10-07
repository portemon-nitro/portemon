-- Private live passive composition for the Gen IV battle. Session and
-- move checkpoints ask this bridge about the current holder while the
-- canonical handler registry keeps every item and ability semantic: the
-- bridge reads present ability, species, and possession from canonical
-- battle state, derives the effective holding under the current
-- suppression, materializes ephemeral ability and effective-item
-- instances scoped to the live entry, and runs them through the existing
-- dispatch. Ephemeral instances are discarded after each invocation, so
-- consumed or transferred holdings vanish from later checkpoints and no
-- innate instance ever reaches the live effect bag or snapshots.

local BattleErrors = require("libs.battle.src.errors")
local BattleState = require("libs.battle.src.BattleState")
local EffectBag = require("libs.battle.src.EffectBag")
local EffectDispatch = require("libs.battle.src.EffectDispatch")
local NativePassives = require("libs.battle.src.gen4.behaviors.NativePassives")

---@class NativePassiveBridge
---@field private _state table<string, unknown>
local NativePassiveBridge = {}
NativePassiveBridge.__index = NativePassiveBridge

NativePassiveBridge.SENTINEL_ABILITY = NativePassives.SENTINEL_ABILITY
NativePassiveBridge.SENTINEL_ITEM = "NONE"

---@type table<string, fun(instance: table<string, unknown>, context: table<string, unknown>): table<string, unknown>?>?
local HANDLERS = nil

---@return table<string, fun(instance: table<string, unknown>, context: table<string, unknown>): table<string, unknown>?> registered native handlers shared by every invocation
local function handlers()
  if HANDLERS == nil then
    local owned = {}
    NativePassives.register(owned)
    HANDLERS = owned
  end
  return HANDLERS --[[@as table<string, fun(instance: table<string, unknown>, context: table<string, unknown>): table<string, unknown>?>]]
end

---@param state unknown candidate probe state under validation
---@return table<string, unknown> the probe state record unchanged
local function probeState(state)
  assert(type(state) == "table", "passive probes carry a state record")
  return state --[[@as table<string, unknown>]]
end

---@param key string passive identity under materialization
---@param timing string finite timing binding the ephemeral instance
---@return table<string, unknown> ephemeral definition for one invocation
local function definitionFor(key, timing)
  return {
    key = key,
    stateVersion = 1,
    validateState = probeState,
    timings = { { timing = timing, handler = key, orderClass = "affliction" } },
    lifecycle = { stacking = "replace", transfer = "clear" },
  }
end

---@param state table<string, unknown> live battle state under the read
---@return NativePassiveBridge bridge bound to the live state
function NativePassiveBridge.wrap(state)
  assert(type(state) == "table", "live passives read their battle state")
  return setmetatable({ _state = state }, NativePassiveBridge)
end

---@param combatant table<string, unknown> live combatant under the read
---@return table<string, unknown> battle-local mon record
local function checkMon(combatant)
  local mon = combatant.mon
  if type(mon) ~= "table" then
    error(BattleErrors.missingBehavior("live passives read their holder mon", {}))
  end
  return mon --[[@as table<string, unknown>]]
end

---@param combatant table<string, unknown> live combatant under the read
---@return integer live entry token for activation scoping
local function checkActivation(combatant)
  local active = combatant.active
  if
    type(active) ~= "table" or type((active --[[@as table<string, unknown>]]).activation) ~= "number"
  then
    error(BattleErrors.invalidState("live passives scope to an entered holder", {}))
  end
  return (active --[[@as table<string, unknown>]]).activation --[[@as integer]]
end

---@param combatant table<string, unknown> live combatant under the read
---@return string? battle ability key, absent for the sentinel and unnamed holders
local function readAbility(combatant)
  local mon = combatant.mon
  if type(mon) ~= "table" then
    return nil
  end
  local ability = (mon --[[@as table<string, unknown>]]).ability
  if type(ability) ~= "string" or ability == "" or ability == NativePassiveBridge.SENTINEL_ABILITY then
    return nil
  end
  return ability
end

---@param combatant table<string, unknown> live combatant under the read
---@return string? possessed held-item key, absent for empty-handed holders
local function readRawItem(combatant)
  local mon = combatant.mon
  if type(mon) ~= "table" then
    return nil
  end
  local held = (mon --[[@as table<string, unknown>]]).heldItem
  if type(held) ~= "string" or held == "" or held == NativePassiveBridge.SENTINEL_ITEM then
    return nil
  end
  return held
end

---@param combatantId integer holder combatant under the read
---@return string? possessed held-item key, absent for empty-handed holders
function NativePassiveBridge:rawHeldItem(combatantId)
  return readRawItem(BattleState.combatant(self._state, combatantId))
end

-- Embargo suppression follows the live entry: a stale entry token never
-- inherits the suppression, and battles without a live effect owner
-- carry no suppression at all.
---@param combatantId integer holder combatant under the read
---@return boolean true when an active Embargo instance covers the holder
function NativePassiveBridge:embargoed(combatantId)
  local owner = self._state.effectBag
  if
    type(owner) ~= "table" or type((owner --[[@as table<string, unknown>]]).capture) ~= "function"
  then
    return false
  end
  local combatant = BattleState.combatant(self._state, combatantId)
  local active = combatant.active
  local token = type(active) == "table" and (active --[[@as table<string, unknown>]]).activation or nil
  local capture = (owner --[[@as table<string, unknown>]]).capture
  for _, record in
    ipairs((capture --[[@as fun(self: unknown): table<integer, table<string, unknown>>]])(owner))
  do
    if record.key == "embargo" then
      local scope = record.scope --[[@as table<string, unknown>?]]
      if
        type(scope) == "table"
        and scope.combatant == combatantId
        and (scope.activation == nil or scope.activation == token)
      then
        return true
      end
    end
  end
  return false
end

-- Ordinary held effects read the effective holding: the possessed item
-- unless the holder's own ability or an active Embargo suppresses it.
-- Suppression never rewrites possession; the raw read stays authoritative
-- for the source-proven raw exceptions beside this call.
---@param combatantId integer holder combatant under the read
---@return string? effective held-item key, absent under suppression
function NativePassiveBridge:effectiveHeldItem(combatantId)
  local combatant = BattleState.combatant(self._state, combatantId)
  local raw = readRawItem(combatant)
  if raw == nil then
    return nil
  end
  if readAbility(combatant) == "KLUTZ" or self:embargoed(combatantId) then
    return nil
  end
  return raw
end

---@param value unknown
---@return table<string, unknown> detached checkpoint context for the invocation
local function copyContext(value)
  assert(type(value) == "table", "passive checkpoints carry their context record")
  local out = {}
  for key, item in
    pairs(value --[[@as table<string, unknown>]])
  do
    out[key] = item
  end
  return out
end

-- Runs one named passive timing for explicit holder facts. Ordinary
-- move-local checkpoints reach the bridge here: the caller already
-- derived the effective holding (suppression without possession writes
-- stays the caller's fact), and the bridge materializes, dispatches,
-- and discards beside the live effect bag.
---@class PassiveHolderFacts
---@field combatant integer holder combatant identity
---@field activation integer? live entry token scoping the instances, absent for benched projections
---@field ability string? battle ability key answering the checkpoint
---@field heldItem string? effective held-item key answering the checkpoint
---@field species string? holder species gating species-locked answers
---@param holder PassiveHolderFacts holder facts answering the checkpoint
---@param timing string finite timing binding the ephemeral instances
---@param context table<string, unknown> checkpoint facts for the handlers
---@return table<string, unknown> dispatch outcome with the semantic events
function NativePassiveBridge.invokeFacts(holder, timing, context)
  assert(type(holder) == "table", "passive checkpoints name their holder facts")
  assert(type(holder.combatant) == "number", "passive checkpoints name their holder")
  assert(type(timing) == "string" and timing ~= "", "passive checkpoints name their timing")
  local merged = copyContext(context)
  if merged.ability == nil and holder.ability ~= nil then
    merged.ability = holder.ability
  end
  if merged.species == nil and holder.species ~= nil then
    merged.species = holder.species
  end
  local owned = handlers()
  local bag = EffectBag.new()
  -- Entered holders scope to their live entry; benched projections
  -- (stat backfills over reserves) scope to the roster member, since
  -- no entry token exists yet.
  local scope = { kind = "roster", combatant = holder.combatant }
  local source = { kind = "innate", combatant = holder.combatant }
  if holder.activation ~= nil then
    scope = { kind = "active", combatant = holder.combatant, activation = holder.activation }
    source = { kind = "innate", combatant = holder.combatant, activation = holder.activation }
  end
  if type(holder.ability) == "string" and holder.ability ~= "" then
    if type(owned[holder.ability]) ~= "function" then
      error(BattleErrors.missingBehavior("no native passive handler is bound for the battle ability", {
        key = holder.ability,
      }))
    end
    bag:add(definitionFor(holder.ability --[[@as string]], timing), scope, source, { version = 1 })
  end
  if type(holder.heldItem) == "string" and holder.heldItem ~= "" then
    if type(owned[holder.heldItem]) ~= "function" then
      error(BattleErrors.missingBehavior("no native passive handler is bound for the held item", {
        key = holder.heldItem,
      }))
    end
    bag:add(definitionFor(holder.heldItem --[[@as string]], timing), scope, source, { version = 1 })
  end
  local outcome = EffectDispatch.new(bag, owned):invoke(timing, merged)
  assert(outcome.done == true, "passive checkpoints run to completion")
  return outcome
end

---@param combatant table<string, unknown> live combatant under the read
---@return integer battle maximum health ceiling for recovery checkpoints
local function ceilingOf(combatant)
  local ceiling = combatant.maxHp
  if type(ceiling) ~= "number" then
    ceiling = combatant.entryHp
  end
  assert(type(ceiling) == "number", "passive checkpoints read their holder ceiling")
  return ceiling --[[@as integer]]
end

---@param state table<string, unknown> live battle state under the read
---@param combatant table<string, unknown> live combatant under the read
---@param combatantId integer holder combatant under the checkpoint
---@param context table<string, unknown> checkpoint facts for the handlers
---@return table<string, unknown> checkpoint context with holder clock and live health defaults
local function holderContext(state, combatant, combatantId, context)
  local merged = copyContext(context)
  if merged.nativeTurn == nil then
    merged.nativeTurn = BattleState.nativeTurn(state)
  end
  if merged.entryTurn == nil and combatant.active ~= nil then
    merged.entryTurn = (combatant.active --[[@as table<string, unknown>]]).entryTurn
  end
  if merged.health == nil then
    merged.health = { [combatantId] = combatant.hp }
  end
  if merged.maxHealth == nil then
    merged.maxHealth = { [combatantId] = ceilingOf(combatant) }
  end
  return merged
end

-- Runs one named passive timing for the current holder: ability,
-- species, raw possession, and suppression re-read from canonical state,
-- so earlier consumption or transfer in the same turn is already
-- visible. The invocation merges the holder clock, live health, ability,
-- and species facts the handlers gate on; checkpoint-specific facts
-- stay with the caller and win over no default.
---@param timing string finite timing binding the ephemeral instances
---@param combatantId integer holder combatant under the checkpoint
---@param context table<string, unknown> checkpoint facts for the handlers
---@return table<string, unknown> dispatch outcome with the semantic events
function NativePassiveBridge:invoke(timing, combatantId, context)
  local combatant = BattleState.combatant(self._state, combatantId)
  local mon = checkMon(combatant)
  local record = mon --[[@as table<string, unknown>]]
  local species = record.species
  if type(species) ~= "string" or species == "" then
    species = nil
  end
  local merged = holderContext(self._state, combatant, combatantId, context)
  return NativePassiveBridge.invokeFacts({
    combatant = combatantId,
    activation = checkActivation(combatant),
    ability = readAbility(combatant),
    heldItem = self:effectiveHeldItem(combatantId),
    species = species --[[@as string?]],
  }, timing, merged)
end

-- Answers the exact boost ratio behind one stat checkpoint for the
-- current holder ability. Item holdings never answer here: ordinary
-- item stat arithmetic stays with its checkpoint owner beside the
-- effective-possession read.
---@param combatantId integer holder combatant under the checkpoint
---@param stat string combat stat under the checkpoint
---@param statused boolean whether the holder carries a persistent condition
---@param split string? physical/special split selecting split-gated boosts
---@return table<string, integer>? exact boost ratio, when the owned passive applies
function NativePassiveBridge:statRatio(combatantId, stat, statused, split)
  local combatant = BattleState.combatant(self._state, combatantId)
  local ability = readAbility(combatant)
  if ability == nil then
    return nil
  end
  if type(handlers()[ability]) ~= "function" then
    error(BattleErrors.missingBehavior("no native passive handler is bound for the battle ability", { key = ability }))
  end
  local context = { stat = stat, statused = statused }
  if split ~= nil then
    context.split = split
  end
  local active = combatant.active
  local token = type(active) == "table" and (active --[[@as table<string, unknown>]]).activation or nil
  local outcome = NativePassiveBridge.invokeFacts({
    combatant = combatantId,
    activation = token --[[@as integer?]],
    ability = ability,
  }, "modifyStat", context)
  for _, event in ipairs(outcome.events) do
    local record = event --[[@as table<string, unknown>]]
    if record.key == ability and record.stages == "boosted" then
      local ratio = record.ratio --[[@as table<string, unknown>?]]
      if type(ratio) == "table" and type(ratio.numerator) == "number" and type(ratio.denominator) == "number" then
        return {
          numerator = ratio.numerator --[[@as integer]],
          denominator = ratio.denominator --[[@as integer]],
        }
      end
    end
  end
  return nil
end

---@class OrderFacts
---@field first boolean true when an early-order answer moves the holder first
---@field last boolean true when a late-order answer holds the holder last
---@field stall boolean true when the stalling ability holds the holder last
---@field consume boolean true when the ordering answer spends the holding

-- Answers the sorter facts behind one action candidate from the current
-- holder: early-order holdings read the pre-turn order sample with no
-- draw, pinch holdings read live health, lagging holdings and the
-- stalling ability read effective possession. Ability and item answers
-- compose independently, so the stalling ability never masquerades as a
-- lagging holding. A spent ordering holding is reported, never written:
-- the checkpoint owner consumes through its canonical mutation.
---@param combatantId integer holder combatant under the checkpoint
---@param context table<string, unknown> checkpoint facts carrying the pre-turn order sample
---@return OrderFacts sorter facts for the candidate
function NativePassiveBridge:orderFacts(combatantId, context)
  local combatant = BattleState.combatant(self._state, combatantId)
  local activation = checkActivation(combatant)
  local ability = readAbility(combatant)
  local heldItem = self:effectiveHeldItem(combatantId)
  local mon = checkMon(combatant)
  local record = mon --[[@as table<string, unknown>]]
  local species = record.species
  if type(species) ~= "string" or species == "" then
    species = nil
  end
  local shared = holderContext(self._state, combatant, combatantId, context)
  local facts = { first = false, last = false, stall = false, consume = false } ---@type OrderFacts
  if ability ~= nil then
    local outcome = NativePassiveBridge.invokeFacts({
      combatant = combatantId,
      activation = activation,
      ability = ability,
      species = species --[[@as string?]],
    }, "beforeAction", shared)
    for _, event in ipairs(outcome.events) do
      if
        (event --[[@as table<string, unknown>]]).order == "last"
      then
        facts.stall = true
      end
    end
  end
  if heldItem ~= nil then
    local outcome = NativePassiveBridge.invokeFacts({
      combatant = combatantId,
      activation = activation,
      ability = ability,
      heldItem = heldItem,
      species = species --[[@as string?]],
    }, "beforeAction", shared)
    for _, event in ipairs(outcome.events) do
      local answer = event --[[@as table<string, unknown>]]
      if answer.order == "first" then
        facts.first = true
        if answer.consumed == true then
          facts.consume = true
        end
      elseif answer.order == "last" then
        facts.last = true
      end
    end
  end
  return facts
end

return NativePassiveBridge
