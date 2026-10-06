-- Native turn and action ordering. Priority brackets dominate every speed
-- comparison; inside one bracket, boosted-priority holders go first,
-- lowered-priority and Stall holders go last, and Trick Room reverses only
-- the remaining plain-speed comparison. Equal comparisons resolve through
-- labeled battle-stream draws taken while walking the live nested pairwise
-- order, so input array positions and library sort internals never
-- influence the stream. Building freezes each action's ordering facts at
-- the sampled point, so later mutations never reorder built actions.
-- Native anchors: CheckSortSpeed, SortMonsBySpeed and
-- SortExecutionOrderBySpeed feeding the command and subscript dispatch.

---@class ActionOrderFacts
---@field priority integer
---@field speed integer
---@field boostedPriority boolean
---@field loweredPriority boolean
---@field stall boolean

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
---@field boostedPriority boolean?
---@field loweredPriority boolean?
---@field stall boolean?

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

---@param value unknown
---@param name string
---@return boolean staged special-ordering fact, false when the stager carries none
local function checkOrderFlag(value, name)
  if value == nil then
    return false
  end
  assert(type(value) == "boolean", name .. " stages a boolean ordering fact")
  return value
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
  local boosted = checkOrderFlag(candidate.boostedPriority, "ordering candidate boosted priority")
  local lowered = checkOrderFlag(candidate.loweredPriority, "ordering candidate lowered priority")
  local stall = checkOrderFlag(candidate.stall, "ordering candidate stall")
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
    sampledOrder = {
      priority = candidate.priority,
      speed = candidate.speed,
      boostedPriority = boosted,
      loweredPriority = lowered,
      stall = stall,
    },
    progress = "queued",
  }
end

---@param firstSpeed integer sampled speed of the current holder
---@param secondSpeed integer sampled speed of the later challenger
---@param reverse boolean true while the speed dimension is reversed
---@param stream BattleRng labeled battle stream for tie resolution
---@param label string tie-draw label for this ordering
---@return boolean true when the challenger belongs ahead of the holder
local function comparePlainSpeed(firstSpeed, secondSpeed, reverse, stream, label)
  if firstSpeed ~= secondSpeed then
    if reverse then
      return secondSpeed < firstSpeed
    end
    return secondSpeed > firstSpeed
  end
  return drawTieSwap(stream, label)
end

---@param first ScheduledAction current holder under comparison
---@param second ScheduledAction later challenger under comparison
---@param reverse boolean true while the speed dimension is reversed
---@param stream BattleRng labeled battle stream for tie resolution
---@return boolean true when the challenger belongs ahead of the holder
local function secondGoesFirst(first, second, reverse, stream)
  local head = first.sampledOrder
  local tail = second.sampledOrder
  if head.priority ~= tail.priority then
    return tail.priority > head.priority
  end
  if head.boostedPriority ~= tail.boostedPriority then
    return tail.boostedPriority
  end
  if head.boostedPriority and tail.boostedPriority then
    if head.speed ~= tail.speed then
      return tail.speed > head.speed
    end
    return drawTieSwap(stream, SPEED_TIE_LABEL)
  end
  if head.loweredPriority ~= tail.loweredPriority then
    return head.loweredPriority
  end
  if head.loweredPriority and tail.loweredPriority then
    if head.speed ~= tail.speed then
      return tail.speed < head.speed
    end
    return drawTieSwap(stream, SPEED_TIE_LABEL)
  end
  if head.stall ~= tail.stall then
    return head.stall
  end
  if head.stall and tail.stall then
    if head.speed ~= tail.speed then
      return tail.speed < head.speed
    end
    return drawTieSwap(stream, SPEED_TIE_LABEL)
  end
  return comparePlainSpeed(head.speed, tail.speed, reverse, stream, SPEED_TIE_LABEL)
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
  -- Selection order seeds the live order before any comparison runs, so
  -- input array permutation never influences the stream; the nested walk
  -- below swaps the holder the moment a later challenger wins, exactly
  -- like the native pairwise pass.
  table.sort(staged, function(a, b)
    if a.selectedOrdinal ~= b.selectedOrdinal then
      return a.selectedOrdinal < b.selectedOrdinal
    end
    return a.id < b.id
  end)
  for i = 1, #staged - 1 do
    for j = i + 1, #staged do
      if secondGoesFirst(staged[i], staged[j], reverse, stream) then
        staged[i], staged[j] = staged[j], staged[i]
      end
    end
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
  -- Entry identity seeds the live order before any comparison runs; the
  -- nested walk below resolves equal speeds through the same pairwise
  -- tie draws as the action pass, without action-special branches.
  table.sort(staged, function(a, b)
    return a.id < b.id
  end)
  for i = 1, #staged - 1 do
    for j = i + 1, #staged do
      if comparePlainSpeed(staged[i].speed, staged[j].speed, reverse, stream, label) then
        staged[i], staged[j] = staged[j], staged[i]
      end
    end
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
