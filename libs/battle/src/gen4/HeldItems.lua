-- Held-item possession and consequence history for one battle entry.
-- A history record keeps the original item and its first owner anchored
-- while the live item moves through consumption, removal, suppression,
-- and swaps. Possession answers what applies right now; the consumed,
-- knocked-off, and transfer lists answer what happened. Format policies
-- decide whether a spent item returns: restoring formats refill an
-- emptied holder from its own consumption record, nonrestoring formats
-- leave it empty, and knocked-off items never return under either
-- policy. History is never rewritten by restoration.

---@class HeldItemTransfer
---@field received string? item key now held after the swap
---@field cause table<string, unknown> causal source attributed to the swap

---@class HeldItemHistory
---@field original string item key held when the record opened
---@field current string? item key applying right now, nil when emptied
---@field originalOwner integer combatant holding the item when the record opened
---@field consumed string[] item keys spent from this record, in order
---@field knockedOff boolean true once the item is removed onto the field
---@field suppressed boolean true while an effect suppresses the item
---@field transfers HeldItemTransfer[] completed swaps, in order

local HeldItems = {}

HeldItems.RESTORING = "restoring"
HeldItems.NONRESTORING = "nonrestoring"

---@param record unknown candidate history record under inspection
---@return HeldItemHistory the validated record
local function checkRecord(record)
  assert(type(record) == "table", "held-item history travels as a record")
  assert(type(record --[[@as HeldItemHistory]].original) == "string", "held-item history anchors its original")
  local current = record --[[@as HeldItemHistory]].current
  assert(current == nil or type(current) == "string", "held-item possession stays a key or empty")
  assert(type(record --[[@as HeldItemHistory]].originalOwner) == "number", "held-item history anchors its owner")
  assert(type(record --[[@as HeldItemHistory]].consumed) == "table", "held-item history lists its consumption")
  assert(type(record --[[@as HeldItemHistory]].knockedOff) == "boolean", "held-item history flags removal")
  assert(type(record --[[@as HeldItemHistory]].suppressed) == "boolean", "held-item history flags suppression")
  assert(type(record --[[@as HeldItemHistory]].transfers) == "table", "held-item history lists its swaps")
  return record --[[@as HeldItemHistory]]
end

---@param cause unknown candidate causal source under inspection
---@return table<string, unknown> detached copy of the causal source
local function checkCause(cause)
  assert(type(cause) == "table", "held-item changes carry their causal source")
  local source = cause --[[@as table<string, unknown>]]
  return { kind = source.kind, combatant = source.combatant, activation = source.activation }
end

--- Reads the item applying right now: nil once the holder is emptied,
--- knocked off the field, or suppressed. Provenance stays on the record.
---@param record HeldItemHistory history record under inspection
---@return string? live item key, or nil when nothing applies
function HeldItems.effective(record)
  local checked = checkRecord(record)
  if checked.knockedOff or checked.suppressed then
    return nil
  end
  if checked.current == nil or checked.current == "" then
    return nil
  end
  return checked.current
end

--- Spends the live item: possession empties while the spent key stays on
--- record for later use. Spending an empty holder changes nothing.
---@param record HeldItemHistory history record being spent
---@param cause table<string, unknown> causal source of the consumption
---@return boolean true when an item was spent
function HeldItems.consume(record, cause)
  local checked = checkRecord(record)
  checkCause(cause)
  if checked.current == nil or checked.current == "" then
    return false
  end
  checked.consumed[#checked.consumed + 1] = checked.current
  checked.current = nil
  return true
end

--- Swaps the live items of two records: each holder applies the item it
--- receives, both originals stay anchored, and both records keep a
--- mirrored entry. Nothing is copied; each live item exists exactly once.
---@param first HeldItemHistory one side of the swap
---@param second HeldItemHistory the other side of the swap
---@param cause table<string, unknown> causal source of the swap
---@return boolean true when the swap completed
function HeldItems.transfer(first, second, cause)
  local left = checkRecord(first)
  local right = checkRecord(second)
  local source = checkCause(cause)
  left.current, right.current = right.current, left.current
  left.transfers[#left.transfers + 1] = { received = left.current, cause = source }
  right.transfers[#right.transfers + 1] = { received = right.current, cause = source }
  return true
end

--- Knocks the live item off the field: possession empties, the removal
--- stays flagged, and the item is never recorded as consumed.
---@param record HeldItemHistory history record being stripped
---@param cause table<string, unknown> causal source of the removal
---@return boolean true when the removal completed
function HeldItems.knockOff(record, cause)
  local checked = checkRecord(record)
  checkCause(cause)
  checked.knockedOff = true
  checked.current = nil
  return true
end

--- Applies the format restoration policy after a sequence: a restoring
--- policy refills an emptied holder from its own most recent consumption,
--- a nonrestoring policy leaves it empty, and knocked-off items never
--- return under either policy. History is left untouched.
---@param record HeldItemHistory history record being restored
---@param policy string restoring or nonrestoring format policy
---@return boolean true when possession was refilled
function HeldItems.restore(record, policy)
  local checked = checkRecord(record)
  assert(policy == HeldItems.RESTORING or policy == HeldItems.NONRESTORING, "restoration names its format policy")
  if policy ~= HeldItems.RESTORING then
    return false
  end
  if checked.knockedOff then
    return false
  end
  if checked.current ~= nil and checked.current ~= "" then
    return false
  end
  if #checked.consumed == 0 then
    return false
  end
  checked.current = checked.consumed[#checked.consumed]
  return true
end

return HeldItems
