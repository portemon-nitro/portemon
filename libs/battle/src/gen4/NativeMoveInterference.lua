-- Turn-scoped move redirection for the HGSS native session. Magic Coat
-- reflects an eligible move from its selected recipient; Snatch transfers
-- an eligible move to the first armed battler in queued turn order. Source
-- references: BtlCmd_TrySetMagicCoat, BtlCmd_TrySnatch, and
-- BattleControllerPlayer_CheckMagicCoat in the decomp.

local BattleState = require("libs.battle.src.BattleState")
local NativePassiveBridge = require("libs.battle.src.gen4.NativePassiveBridge")

---@class NativeMoveInterference
local NativeMoveInterference = {}

---@param entries table<integer, table<string, integer>> living active battlers with sampled Speed
---@param trickRoom boolean current speed dimension
---@param stream table<string, unknown> battle random stream for speed ties
---@return integer[] battler identities in native speed order
local function orderedSpeedIds(entries, trickRoom, stream)
  local TurnOrder = require("libs.battle.src.gen4.TurnOrder")
  local ordered = TurnOrder.orderEntryEffects(entries, { trickRoom = trickRoom }, stream)
  local ids = {} ---@type integer[]
  for _, entry in ipairs(ordered) do
    ids[#ids + 1] = entry.id
  end
  return ids
end

---@param state table<string, unknown> live battle state under interception
---@return boolean true when the field topology has more than one slot per side
local function hasPartners(state)
  local counts = {} ---@type table<integer, integer>
  for _, positionId in
    ipairs(state.positionOrder --[[@as integer[] ]])
  do
    local position = BattleState.position(state, positionId)
    local side = position.side --[[@as integer]]
    counts[side] = (counts[side] or 0) + 1
  end
  for _, count in pairs(counts) do
    if count > 1 then
      return true
    end
  end
  return false
end

---@param state table<string, unknown> live battle state under marker lookup
---@param combatantId integer combatant whose marker is read
---@param key string marker key under lookup
---@return boolean true when the marker belongs to the combatant's live entry
local function hasMarker(state, combatantId, key)
  local combatant = BattleState.combatant(state, combatantId)
  local active = combatant.active
  if
    active == nil
    or combatant.hp --[[@as integer]]
      <= 0
  then
    return false
  end
  local bag = state.effectBag --[[@as table<string, unknown>]]
  local effects = bag:capture() --[[@as table<integer, table<string, unknown>>]]
  for _, effect in ipairs(effects) do
    local scope = effect.scope --[[@as table<string, unknown>]]
    if
      effect.key == key
      and scope.kind == "active"
      and scope.combatant == combatantId
      and scope.activation == active.activation
    then
      return true
    end
  end
  return false
end

---@param state table<string, unknown> live battle state under side lookup
---@param combatantId integer combatant whose side is inspected
---@return integer side identity
local function sideOf(state, combatantId)
  local combatant = BattleState.combatant(state, combatantId)
  return BattleState.participant(state, combatant.participant --[[@as integer]]).side
end

---@param state table<string, unknown> live battle state under Follow Me lookup
---@param side integer side whose Follow Me state is inspected
---@return integer? active Follow Me owner
local function followMeForSide(state, side)
  local bag = state.effectBag --[[@as table<string, unknown>]]
  local latest = nil
  for _, effect in ipairs(bag:capture()) do
    local scope = effect.scope --[[@as table<string, unknown>]]
    if effect.key == "followme" and scope.kind == "active" and type(scope.combatant) == "number" then
      local combatantId = scope.combatant --[[@as integer]]
      local combatant = BattleState.combatant(state, combatantId)
      local active = combatant.active
      if
        active ~= nil
        and active.activation == scope.activation
        and combatant.hp --[[@as integer]]
          > 0
        and sideOf(state, combatantId) == side
      then
        latest = combatantId
      end
    end
  end
  return latest
end

local JUDGMENT_PLATE_TYPES = {
  FIST_PLATE = "fighting",
  SKY_PLATE = "flying",
  TOXIC_PLATE = "poison",
  EARTH_PLATE = "ground",
  STONE_PLATE = "rock",
  INSECT_PLATE = "bug",
  SPOOKY_PLATE = "ghost",
  IRON_PLATE = "steel",
  FLAME_PLATE = "fire",
  SPLASH_PLATE = "water",
  MEADOW_PLATE = "grass",
  ZAP_PLATE = "electric",
  MIND_PLATE = "psychic",
  ICICLE_PLATE = "ice",
  DRACO_PLATE = "dragon",
  DREAD_PLATE = "dark",
}

local HIDDEN_POWER_TYPES = {
  "fighting",
  "flying",
  "poison",
  "ground",
  "rock",
  "bug",
  "ghost",
  "steel",
  "fire",
  "water",
  "grass",
  "electric",
  "psychic",
  "ice",
  "dragon",
  "dark",
}

local WEATHER_BALL_TYPES = {
  raindance = "water",
  sandstorm = "rock",
  sunnyday = "fire",
  hail = "ice",
}

---@param state table<string, unknown> live battle state under dynamic type lookup
---@param actor integer attacking combatant used by GetDynamicMoveType
---@param move string dynamic move identity
---@param moveFacts table<string, unknown> immutable move facts
---@param itemFacts table<string, table<string, unknown>> immutable item facts
---@return string semantic move type using HGSS GetDynamicMoveType cases
function NativeMoveInterference.dynamicMoveType(state, actor, move, moveFacts, itemFacts)
  local combatant = BattleState.combatant(state, actor)
  local mon = combatant.mon --[[@as table<string, unknown>]]
  if move == "NATURAL_GIFT" then
    local heldItem = mon.heldItem
    local held = type(heldItem) == "string" and itemFacts[heldItem] or nil
    local gift = type(held) == "table" and held.naturalGift or nil
    if type(gift) == "table" and type(gift.type) == "string" then
      return gift.type
    end
  elseif move == "JUDGMENT" then
    local heldItem = mon.heldItem
    return (type(heldItem) == "string" and JUDGMENT_PLATE_TYPES[heldItem]) or "normal"
  elseif move == "HIDDEN_POWER" then
    local ivs = mon.ivs --[[@as table<string, unknown>]]
    local index = 0
    for position, stat in ipairs({ "hp", "attack", "defense", "speed", "specialAttack", "specialDefense" }) do
      local value = ivs[stat]
      assert(type(value) == "number" and value % 1 == 0, "Hidden Power has six integer IVs")
      index = index + (value % 2) * (2 ^ (position - 1))
    end
    local raw = math.floor(index * 15 / 63) + 1
    if raw >= 9 then
      raw = raw + 1
    end
    return HIDDEN_POWER_TYPES[raw <= 8 and raw or raw - 1]
  elseif move == "WEATHER_BALL" then
    local suppressed = false
    local bridge = NativePassiveBridge.wrap(state)
    for _, combatantId in
      ipairs(state.combatantOrder --[[@as integer[] ]])
    do
      local holder = BattleState.combatant(state, combatantId)
      local ability = bridge:abilityOf(combatantId)
      if
        holder.active ~= nil
        and holder.hp --[[@as integer]]
          > 0
        and (ability == "CLOUD_NINE" or ability == "AIR_LOCK")
      then
        suppressed = true
        break
      end
    end
    if not suppressed then
      local bag = state.effectBag --[[@as table<string, unknown>]]
      for _, effect in ipairs(bag:capture()) do
        local scope = effect.scope --[[@as table<string, unknown>]]
        if scope.kind == "field" and WEATHER_BALL_TYPES[effect.key] ~= nil then
          return WEATHER_BALL_TYPES[effect.key]
        end
      end
    end
  end
  local moveType = moveFacts.moveType
  assert(type(moveType) == "string", "native move facts carry a semantic type")
  return moveType
end

---@param state table<string, unknown> live battle state under Magic Coat targeting
---@param coatUser integer coat user whose opposing target is recomputed
---@param originalUser integer original incoming move user
---@param move string incoming move identity
---@param moveFacts table<string, unknown> immutable incoming move facts
---@param itemFacts table<string, table<string, unknown>> immutable item facts
---@param speedEntries table<integer, table<string, integer>> current living battlers' sampled Speed
---@param trickRoom boolean current speed dimension
---@param stream table<string, unknown> battle random stream for speed ties
---@return table<string, unknown> recipient and optional ability redirect
function NativeMoveInterference.magicCoatRecipient(
  state,
  coatUser,
  originalUser,
  move,
  moveFacts,
  itemFacts,
  speedEntries,
  trickRoom,
  stream
)
  local bridge = NativePassiveBridge.wrap(state)
  local followMe = followMeForSide(state, sideOf(state, coatUser))
  if followMe ~= nil then
    return { combatant = followMe }
  end

  local range = moveFacts.range
  if range == 4 or range == 8 then
    return { combatant = originalUser }
  end
  local moveType = NativeMoveInterference.dynamicMoveType(state, coatUser, move, moveFacts, itemFacts)
  local redirectAbility = moveType == "electric" and "LIGHTNINGROD" or moveType == "water" and "STORM_DRAIN" or nil
  if range == 0 or range == 2 then
    local coatAbility = bridge:abilityOf(coatUser)
    if coatAbility ~= "MOLD_BREAKER" and coatAbility ~= "NORMALIZE" and redirectAbility ~= nil then
      for _, candidate in ipairs(orderedSpeedIds(speedEntries, trickRoom, stream)) do
        if candidate ~= coatUser then
          local combatant = BattleState.combatant(state, candidate)
          if
            combatant.hp --[[@as integer]]
              > 0
            and combatant.active ~= nil
            and bridge:abilityOf(candidate) == redirectAbility
          then
            return { combatant = candidate, ability = redirectAbility, moveType = moveType }
          end
        end
      end
    end
  end
  return { combatant = originalUser }
end

---@param state table<string, unknown> live battle state under recipient selection
---@param actor integer current move user
---@param move string executing move identity
---@param moveFacts table<string, unknown> immutable move facts
---@param itemFacts table<string, table<string, unknown>> immutable item facts
---@param chargeTurn boolean whether the move is resolving its stored charge turn
---@param targets integer[] current sampled recipients
---@param speedEntries table<integer, table<string, integer>> sampled living battler speeds
---@param trickRoom boolean whether Trick Room reverses speed order
---@param stream table<string, unknown> battle random stream for speed ties
---@return table<string, unknown>? redirected ability holder and move type
function NativeMoveInterference.redirectRecipient(
  state,
  actor,
  move,
  moveFacts,
  itemFacts,
  chargeTurn,
  targets,
  speedEntries,
  trickRoom,
  stream
)
  local range = moveFacts.range
  if (range ~= 0 and range ~= 2) or chargeTurn then
    return nil
  end
  local bridge = NativePassiveBridge.wrap(state)
  local attackerAbility = bridge:abilityOf(actor)
  if attackerAbility == "NORMALIZE" or attackerAbility == "MOLD_BREAKER" then
    return nil
  end
  local userSide = sideOf(state, actor)
  local opposingSide = nil
  for _, combatantId in
    ipairs(state.combatantOrder --[[@as integer[] ]])
  do
    local combatant = BattleState.combatant(state, combatantId)
    if
      combatant.active ~= nil
      and BattleState.participant(state, combatant.participant --[[@as integer]]).side ~= userSide
    then
      opposingSide = BattleState.participant(state, combatant.participant --[[@as integer]]).side
      break
    end
  end
  if opposingSide ~= nil and followMeForSide(state, opposingSide) ~= nil then
    return nil
  end
  local moveType = NativeMoveInterference.dynamicMoveType(state, actor, move, moveFacts, itemFacts)
  local ability = moveType == "electric" and "LIGHTNINGROD" or moveType == "water" and "STORM_DRAIN" or nil
  if ability == nil then
    return nil
  end
  local order = {} ---@type integer[]
  if #speedEntries > 0 then
    order = orderedSpeedIds(speedEntries, trickRoom, stream)
  else
    for _, combatantId in
      ipairs(state.combatantOrder --[[@as integer[] ]])
    do
      order[#order + 1] = combatantId
    end
  end
  for _, combatantId in ipairs(order) do
    local combatant = BattleState.combatant(state, combatantId)
    if
      combatantId ~= actor
      and combatant.active ~= nil
      and combatant.hp > 0
      and bridge:abilityOf(combatantId) == ability
    then
      if targets[1] == combatantId then
        return nil
      end
      return { combatant = combatantId, ability = ability, moveType = moveType }
    end
  end
  return nil
end

---@param state table<string, unknown> live battle state under ability response
---@param context table<string, unknown> battle context emitting the response
---@param combatant integer redirected ability holder
---@param ability string source ability identity
---@param move string reflected move identity
---@param moveType string dynamically resolved move type
---@param attackerAbility string? reflected move user's live ability
---@return boolean false because source Lightning Rod and Storm Drain redirect without absorbing
function NativeMoveInterference.applyAbilityResponse(
  state,
  context,
  combatant,
  ability,
  move,
  moveType,
  attackerAbility
)
  assert(BattleState.combatant(state, combatant).active ~= nil, "redirected abilities belong to active combatants")
  context:emit("ability", { kind = "ability", key = ability, combatant = combatant }, {
    combatant = combatant,
    ability = ability,
    move = move,
    moveType = moveType,
    attackerAbility = attackerAbility,
    redirected = true,
  })
  return false
end

---@param state table<string, unknown> live battle state under interception
---@param move string incoming move identity
---@param actor integer original move user
---@param targets integer[] sampled target identities
---@param flags table<string, unknown> semantic move flags from compiled move facts
---@return table<string, unknown>? intercept record with actor, target, and kind
function NativeMoveInterference.resolve(state, move, actor, targets, flags)
  assert(type(state) == "table", "move interception reads live battle state")
  assert(type(move) == "string" and move ~= "", "move interception names its move")
  assert(type(actor) == "number", "move interception reads its original actor")
  assert(type(targets) == "table", "move interception reads sampled recipients")
  assert(type(flags) == "table", "move interception reads compiled semantic flags")
  if not hasPartners(state) then
    return nil
  end
  if flags.reflectable == true then
    for _, target in ipairs(targets) do
      if hasMarker(state, target, "magiccoat") then
        return {
          actor = target,
          target = actor,
          kind = "magiccoat",
          markerOwner = target,
          markerKey = "magiccoat",
        }
      end
    end
  end
  if flags.snatchable == true then
    local queue = state.queue --[[@as table<integer, table<string, unknown>>?]]
    if type(queue) == "table" then
      for _, action in ipairs(queue) do
        local queuedActor = action.actor --[[@as table<string, unknown>?]]
        if type(queuedActor) == "table" and type(queuedActor.combatant) == "number" then
          local candidate = queuedActor.combatant --[[@as integer]]
          if hasMarker(state, candidate, "snatch") then
            return {
              actor = candidate,
              target = actor,
              kind = "snatch",
              markerOwner = candidate,
              markerKey = "snatch",
            }
          end
        end
      end
    end
  end
  return nil
end

---@param context table<string, unknown> battle context consuming a one-shot marker
---@param interception table<string, unknown> successful move interception carrying its marker
function NativeMoveInterference.consume(context, interception)
  assert(type(context) == "table", "move interception consumes through the battle context")
  assert(type(interception.markerOwner) == "number", "interceptions name the marker owner")
  assert(type(interception.markerKey) == "string", "interceptions name the marker key")
  context:removeBattleEffect(interception.markerOwner --[[@as integer]], interception.markerKey --[[@as string]])
end

return NativeMoveInterference
