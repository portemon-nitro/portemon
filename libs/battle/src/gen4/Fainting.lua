-- Knockout settlement. Fainting is detected at native checkpoints and
-- settled from one source-ordered queue: each entry queues exactly once per
-- entry token, settlement follows detection order with each knockout
-- progressed once, replacements resolve before any terminal result is
-- named, and re-stepping a drained settlement emits nothing new.

---@class FaintTarget
---@field combatant integer knocked-out roster identity
---@field activation integer knocked-out entry token

---@class FaintRecord
---@field target FaintTarget knocked-out entry
---@field cause table<string, unknown> semantic reason that ordered the knockout
---@field detectedOrdinal integer detection order
---@field processed boolean whether settlement already progressed this record

---@class FaintObligation
---@field combatant integer knocked-out roster identity owing a replacement
---@field activation integer knocked-out entry token the obligation binds

---@class FaintOutcome
---@field done boolean whether settlement drained
---@field events table<string, unknown>[] faint facts in detection order
---@field frame FaintFrame continuation frame carrying the open obligations while open
---@field needsReplacement table<string, unknown>|nil first outstanding replacement while open
---@field replacements FaintObligation[] ordered replacement obligations, one per settled knockout
---@field progression unknown[] one reward child per settled knockout, in order

---@class FaintFrame
---@field kind string settlement identity
---@field cursor string continuation cursor
---@field obligations FaintObligation[]|nil ordered replacement obligations carried while open; absent on fresh and drained frames

---@class Fainting
local Fainting = {}

---@param value unknown
---@return boolean
local function isPositiveInt(value)
  return type(value) == "number" and value == value and value % 1 == 0 and value >= 1 and value <= 9007199254740991
end

--- Queues one faint resolution per entry token. Repeat reports for the same
--- entry token are absorbed; a fresh entry token queues again.
---@param queue table<number, FaintRecord> explicit faint queue under test
---@param target table<string, unknown> knocked-out entry pinned to one entry token
---@param cause table<string, unknown> semantic reason that ordered the knockout
---@param ordinal integer detection order
---@return FaintRecord
function Fainting.detect(queue, target, cause, ordinal)
  assert(type(queue) == "table", "faint detection enqueues into an explicit queue")
  assert(type(target) == "table", "faint detection names the knocked-out entry")
  assert(isPositiveInt(target.combatant), "faint detection names the knocked-out combatant")
  assert(isPositiveInt(target.activation), "faint detection pins the knocked-out entry token")
  assert(type(cause) == "table", "faint detection carries its cause")
  assert(type(ordinal) == "number" and ordinal % 1 == 0 and ordinal >= 1, "faint detection orders by positive ordinal")
  for _, record in ipairs(queue) do
    if
      type(record) == "table"
      and type(record.target) == "table"
      and record.target.combatant == target.combatant
      and record.target.activation == target.activation
    then
      return record
    end
  end
  local copied = {}
  for key, value in pairs(cause) do
    copied[key] = value
  end
  local record = {
    target = { combatant = target.combatant, activation = target.activation },
    cause = copied,
    detectedOrdinal = ordinal,
    processed = false,
  }
  queue[#queue + 1] = record
  return record
end

--- Settles the faint queue in detection order. Each knockout is progressed
--- exactly once and marked processed; while eligible reserves still owe a
--- replacement the settlement stays open and names one ordered obligation
--- per settled knockout, bound to its fainted entry, instead of finishing.
--- The open obligations travel in the returned frame as plain data, so
--- re-stepping the open frame resumes the same request with no new events
--- and no new progression children, without touching queue records.
---@param context table<string, unknown> settlement inputs carrying the queue, reserves, and progression hook
---@param frame FaintFrame
---@return table<string, unknown> step outcome carrying done, events, frame, ordered replacements, and needsReplacement while open
function Fainting.step(context, frame)
  assert(type(context) == "table", "faint settlement steps carry their settlement context")
  Fainting.validateFrame(frame)
  local carried = frame.obligations
  if type(carried) == "table" and #carried > 0 then
    -- Open-frame resume: the obligations already settled stay settled.
    -- Records are never re-touched and no child is re-spawned; the same
    -- carried obligation tables answer again so repeated steps name the
    -- identical replacement request.
    return {
      done = false,
      events = {},
      frame = frame,
      needsReplacement = carried[1],
      replacements = carried,
      progression = {},
    }
  end
  if context.progression ~= nil then
    assert(
      type(context.progression) == "function",
      "faint settlement spawns reward children through a progression function"
    )
  end
  local queue = context.queue
  assert(type(queue) == "table", "faint settlement drains an explicit queue")
  local pending = {}
  for _, record in ipairs(queue) do
    assert(type(record) == "table", "faint queues hold faint records")
    if record.processed ~= true then
      pending[#pending + 1] = record
    end
  end
  table.sort(pending, function(a, b)
    return a.detectedOrdinal < b.detectedOrdinal
  end)
  local events = {}
  local children = {}
  for _, record in ipairs(pending) do
    if type(context.progress) == "function" then
      context.progress(record)
    end
    -- The reward checkpoint spawns exactly one child per settled knockout
    -- with the complete knockout facts; already processed records never
    -- reach it again, so restored settlements cannot award twice.
    if type(context.progression) == "function" then
      children[#children + 1] = context.progression(record)
    end
    record.processed = true
    events[#events + 1] = {
      kind = "faint",
      combatant = record.target.combatant,
      activation = record.target.activation,
    }
  end
  local settled = { kind = "faint", cursor = "done" }
  local outcome = {
    done = true,
    events = events,
    frame = settled,
    needsReplacement = nil,
    replacements = {},
    progression = children,
  }
  local reserves = context.reserves
  if type(reserves) == "table" and #reserves > 0 then
    -- One plain-data obligation per knockout settled above, in detection
    -- order: callers match each obligation against live reserve
    -- eligibility, so simultaneous faints never collapse to one reserve.
    local obligations = {} ---@type table<integer, table<string, integer>>
    for _, record in ipairs(pending) do
      obligations[#obligations + 1] = {
        combatant = record.target.combatant,
        activation = record.target.activation,
      }
    end
    outcome.replacements = obligations
    if #obligations > 0 then
      outcome.done = false
      outcome.needsReplacement = obligations[1]
      outcome.frame = { kind = "faint", cursor = "open", obligations = obligations }
    end
  end
  return outcome
end

--- Validates a faint settlement frame.
---@param frame FaintFrame
---@return FaintFrame
function Fainting.validateFrame(frame)
  assert(type(frame) == "table", "faint frames are records")
  assert(frame.kind == "faint", "faint frames carry the faint settlement identity")
  assert(type(frame.cursor) == "string" and frame.cursor ~= "", "faint frames name their cursor")
  if frame.obligations ~= nil then
    assert(type(frame.obligations) == "table", "faint frames carry plain-data obligations")
    for index, obligation in ipairs(frame.obligations) do
      assert(type(obligation) == "table", "faint obligations are records")
      assert(
        isPositiveInt(obligation.combatant),
        "faint obligations name the knocked-out combatant at position " .. tostring(index)
      )
      assert(
        isPositiveInt(obligation.activation),
        "faint obligations pin the knocked-out entry token at position " .. tostring(index)
      )
    end
  end
  return frame
end

return Fainting
