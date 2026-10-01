-- Native turn and action ordering. Priority brackets dominate every speed
-- comparison, sampled speed decides inside one bracket, and Trick Room
-- reverses only the speed dimension. Equal priority and speed resolve
-- through labeled battle-stream draws taken in recorded selection order, so
-- input array positions and library sort internals never influence the
-- stream. Building freezes each action's ordering facts at the sampled
-- point, so later mutations never reorder built actions. Native anchors:
-- CheckSortSpeed, SortMonsBySpeed and SortExecutionOrderBySpeed feeding the
-- command and subscript dispatch.

---@class ActionOrderFacts
---@field priority integer
---@field speed integer

---@class ScheduledActor
---@field combatant integer
---@field activation integer

---@class ScheduledAction
---@field id integer
---@field actor ScheduledActor
---@field kind string
---@field payload table<string, unknown>
---@field selectedOrdinal integer
---@field sampledOrder ActionOrderFacts
---@field parentActionId integer?
---@field progress "queued"|"running"|"suspended"|"complete"|"cancelled"

---@class TurnOrderCandidate
---@field id integer
---@field actor ScheduledActor
---@field kind string
---@field payload table<string, unknown>
---@field selectedOrdinal integer
---@field priority integer
---@field speed integer

---@class TurnOrderOptions
---@field trickRoom boolean

---@class ResidualEntry
---@field id integer
---@field speed integer

local TurnOrder = {}

local SPEED_TIE_LABEL = "speed_tie"
local RESIDUAL_TIE_LABEL = "residual_tie"
local ENTRY_TIE_LABEL = "entry_tie"

---@param value unknown
---@param name string
local function requireIdentity(value, name)
  assert(type(value) == "number" and value % 1 == 0, name .. " carries an integer identity")
end

---@param value unknown
---@param name string
local function requireSampledSpeed(value, name)
  assert(type(value) == "number" and value % 1 == 0, name .. " samples an integer speed")
end

---@param stream BattleRng
---@param label string
---@return boolean true when the tied comparison swaps its pair
local function drawTieSwap(stream, label)
  return stream:nextU16(label, { kind = label }) % 2 == 1
end

---@param candidate TurnOrderCandidate
---@return ScheduledAction
local function checkCandidate(candidate)
  assert(type(candidate) == "table", "ordering candidates are records")
  requireIdentity(candidate.id, "ordering candidate")
  assert(type(candidate.actor) == "table", "ordering candidates name their actor")
  requireIdentity(candidate.actor.combatant, "ordering actor")
  requireIdentity(candidate.actor.activation, "ordering activation")
  assert(type(candidate.kind) == "string" and candidate.kind ~= "", "ordering candidates name their action class")
  assert(type(candidate.payload) == "table", "ordering candidates carry their payload")
  requireIdentity(candidate.selectedOrdinal, "ordering selection order")
  assert(
    type(candidate.priority) == "number" and candidate.priority % 1 == 0,
    "ordering candidates carry an integer priority"
  )
  requireSampledSpeed(candidate.speed, "ordering candidate")
  local payload = {} ---@type table<string, unknown>
  for key, value in pairs(candidate.payload) do
    payload[key] = value
  end
  return {
    id = candidate.id,
    actor = { combatant = candidate.actor.combatant, activation = candidate.actor.activation },
    kind = candidate.kind,
    payload = payload,
    selectedOrdinal = candidate.selectedOrdinal,
    sampledOrder = { priority = candidate.priority, speed = candidate.speed },
    progress = "queued",
  }
end

---@param candidates TurnOrderCandidate[]
---@param options TurnOrderOptions
---@param stream BattleRng
---@return ScheduledAction[] built actions in execution order
function TurnOrder.buildActions(candidates, options, stream)
  assert(type(candidates) == "table", "ordering builds from explicit candidates")
  assert(type(options) == "table" and type(options.trickRoom) == "boolean", "ordering names its speed dimension")
  assert(type(stream) == "table" and type(stream.nextU16) == "function", "ordering draws ties from the battle stream")
  local staged = {} ---@type ScheduledAction[]
  for _, candidate in ipairs(candidates) do
    staged[#staged + 1] = checkCandidate(candidate)
  end
  local reverse = options.trickRoom
  ---@param a ScheduledAction
  ---@param b ScheduledAction
  ---@return boolean
  local function byExecutionOrder(a, b)
    if a.sampledOrder.priority ~= b.sampledOrder.priority then
      return a.sampledOrder.priority > b.sampledOrder.priority
    end
    if a.sampledOrder.speed ~= b.sampledOrder.speed then
      if reverse then
        return a.sampledOrder.speed < b.sampledOrder.speed
      end
      return a.sampledOrder.speed > b.sampledOrder.speed
    end
    if a.selectedOrdinal ~= b.selectedOrdinal then
      return a.selectedOrdinal < b.selectedOrdinal
    end
    return a.id < b.id
  end
  -- The comparator above is a total order over recorded selection facts, so
  -- tied priority and speed always land adjacent in selection order before
  -- any draw is taken; input array permutation cannot move them.
  table.sort(staged, byExecutionOrder)
  local index = 1
  while index <= #staged do
    local runEnd = index
    while
      runEnd + 1 <= #staged
      and staged[runEnd + 1].sampledOrder.priority == staged[index].sampledOrder.priority
      and staged[runEnd + 1].sampledOrder.speed == staged[index].sampledOrder.speed
    do
      runEnd = runEnd + 1
    end
    if runEnd > index then
      for position = index, runEnd - 1 do
        if drawTieSwap(stream, SPEED_TIE_LABEL) then
          staged[position], staged[position + 1] = staged[position + 1], staged[position]
        end
      end
    end
    index = runEnd + 1
  end
  return staged
end

---@param entries ResidualEntry[]
---@param context TurnOrderOptions
---@param stream BattleRng
---@param label string
---@return ResidualEntry[] sequenced entries keeping every member
local function orderBySampledSpeed(entries, context, stream, label)
  assert(type(entries) == "table", "sequencing takes explicit entries")
  assert(type(context) == "table" and type(context.trickRoom) == "boolean", "sequencing names its speed dimension")
  assert(type(stream) == "table" and type(stream.nextU16) == "function", "sequenced ties draw from the battle stream")
  local staged = {} ---@type ResidualEntry[]
  for _, entry in ipairs(entries) do
    assert(type(entry) == "table", "sequenced entries are records")
    requireIdentity(entry.id, "sequenced entry")
    requireSampledSpeed(entry.speed, "sequenced entry")
    local copy = { id = entry.id, speed = entry.speed } ---@type ResidualEntry
    for key, value in pairs(entry) do
      if key ~= "id" and key ~= "speed" then
        copy[key] = value
      end
    end
    staged[#staged + 1] = copy
  end
  local reverse = context.trickRoom
  ---@param a ResidualEntry
  ---@param b ResidualEntry
  ---@return boolean
  local function bySpeed(a, b)
    if a.speed ~= b.speed then
      if reverse then
        return a.speed < b.speed
      end
      return a.speed > b.speed
    end
    return a.id < b.id
  end
  table.sort(staged, bySpeed)
  local index = 1
  while index <= #staged do
    local runEnd = index
    while runEnd + 1 <= #staged and staged[runEnd + 1].speed == staged[index].speed do
      runEnd = runEnd + 1
    end
    if runEnd > index then
      for position = index, runEnd - 1 do
        if drawTieSwap(stream, label) then
          staged[position], staged[position + 1] = staged[position + 1], staged[position]
        end
      end
    end
    index = runEnd + 1
  end
  return staged
end

---@param entries ResidualEntry[]
---@param context TurnOrderOptions
---@param stream BattleRng
---@return ResidualEntry[] sequenced entries keeping every member
function TurnOrder.orderResiduals(entries, context, stream)
  return orderBySampledSpeed(entries, context, stream, RESIDUAL_TIE_LABEL)
end

---@param entries ResidualEntry[]
---@param context TurnOrderOptions
---@param stream BattleRng
---@return ResidualEntry[] sequenced entries keeping every member
function TurnOrder.orderEntryEffects(entries, context, stream)
  return orderBySampledSpeed(entries, context, stream, ENTRY_TIE_LABEL)
end

return TurnOrder
