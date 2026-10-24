-- Resolves HGSS pivot and forced-departure outcomes from a sequenced move.
local BattleState = require("libs.battle.src.BattleState")
local Experience = require("libs.mons.src.gen4.Experience")
local Switching = require("libs.battle.src.gen4.Switching")

local M = {}

---@param state table<string, unknown> live battle state
---@param combatant integer roster identity under level lookup
---@param speciesFacts table<string, table<integer, table<string, unknown>>> static mon facts
---@return integer level from the mon's stored experience
local function levelOf(state, combatant, speciesFacts)
  local mon = BattleState.combatant(state, combatant).mon --[[@as table<string, unknown>]]
  local species = mon.species --[[@as string]]
  local form = mon.form --[[@as integer]]
  local facts = speciesFacts[species][form]
  local curve = facts.growthCurve --[[@as integer[] ]]
  local experience = mon.experience --[[@as integer]]
  return Experience.level(curve, experience)
end

---@param state table<string, unknown> live battle state
---@param target integer departing combatant identity
---@return integer[] living benched reserves in roster order
local function reservesOf(state, target)
  local combatant = BattleState.combatant(state, target)
  local participant = BattleState.participant(state, combatant.participant --[[@as integer]])
  local reserves = {} ---@type integer[]
  for _, candidateId in
    ipairs(participant.roster --[[@as integer[] ]])
  do
    local candidate = BattleState.combatant(state, candidateId)
    if
      candidate.active == nil
      and candidate.hp --[[@as integer]]
        > 0
    then
      reserves[#reserves + 1] = candidateId
    end
  end
  return reserves
end

---@param state table<string, unknown> live battle state
---@param participant integer participant whose party is being counted
---@return integer active capacity on the participant's side
local function activeCapacity(state, participant)
  local capacity = 0
  for _, positionId in
    ipairs(state.positionOrder --[[@as integer[] ]])
  do
    local position = BattleState.position(state, positionId)
    for _, eligible in
      ipairs(position.eligible --[[@as integer[] ]])
    do
      if eligible == participant then
        capacity = capacity + 1
        break
      end
    end
  end
  return capacity
end

--- Applies BtlCmd_TryWhirlwind's level gate and selects the forced arrival.
---@param state table<string, unknown> live battle state
---@param intent table<string, unknown> emitted forced-switch intent
---@param speciesFacts table<string, table<integer, table<string, unknown>>> static mon facts
---@return table<string, unknown>? flee marker or replacement target/incoming identities; nil when the target stays
function M.forcedDeparture(state, intent, speciesFacts)
  local targetId = intent.target
  if type(targetId) ~= "number" or targetId % 1 ~= 0 then
    return nil
  end
  local target = BattleState.combatant(state, targetId)
  local active = target.active
  if
    active == nil
    or target.hp --[[@as integer]]
      <= 0
  then
    return nil
  end
  local mon = target.mon --[[@as table<string, unknown>]]
  local context = require("libs.battle.src.BattleContext").wrap(state)
  local userId = intent.user --[[@as integer]]
  local userMon = BattleState.combatant(state, userId).mon --[[@as table<string, unknown>]]
  local moldBreaker = userMon.ability == "MOLD_BREAKER"
    or userMon.ability == "TERAVOLT"
    or userMon.ability == "TURBOBLAZE"
  local ignoredAbility = context:hasBattleEffect(targetId, "GASTRO_ACID")
  if
    (mon.ability == "SUCTION_CUPS" and not moldBreaker and not ignoredAbility)
    or context:hasBattleEffect(targetId, "ingrain")
  then
    return nil
  end
  local userLevel = levelOf(state, userId, speciesFacts)
  local targetLevel = levelOf(state, targetId, speciesFacts)
  if userLevel < targetLevel then
    local stream = state.rng --[[@as table<string, unknown>]]
    assert(
      type(stream) == "table" and type(stream.nextU16) == "function",
      "forced departure draws from the battle stream"
    )
    local roll = stream:nextU16("whirlwind:level", { user = userId, target = targetId }) % 256
    local check = math.floor(roll * (userLevel + targetLevel) / 256) + 1
    if check <= targetLevel / 4 then
      return nil
    end
  end
  if intent.battleKind == "wild" then
    return { kind = "flee" }
  end
  local reserves = reservesOf(state, targetId)
  local participantId = target.participant --[[@as integer]]
  local living = #reserves
  local participant = BattleState.participant(state, participantId)
  for _, combatantId in
    ipairs(participant.roster --[[@as integer[] ]])
  do
    local combatant = BattleState.combatant(state, combatantId)
    if
      combatant.active ~= nil
      and combatant.hp --[[@as integer]]
        > 0
    then
      living = living + 1
    end
  end
  if living <= activeCapacity(state, participantId) then
    return nil
  end
  local frame = Switching.start({
    position = active.position,
    outgoing = { combatant = targetId, activation = active.activation },
    reason = "forced",
    reserves = reserves,
    stream = state.rng,
  })
  return { kind = "replace", target = targetId, incoming = frame.incoming }
end

return M
