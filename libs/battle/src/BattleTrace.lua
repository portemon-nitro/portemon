-- Behaviorally inert battle diagnostics. A trace collector is owned by the
-- caller and carries an explicit entry bound; recording an event, a labeled
-- draw, or a staged arithmetic intermediate only appends a numbered entry
-- and never touches battle state, the random stream, the clock, or the
-- renderer. Over-bound recording fails instead of growing, and comparing
-- two collectors reports the first divergent entry with both sides
-- attached. A late consumer formats stored entries long after the battle
-- ended without reaching back into live objects.

---@class BattleTraceCollector
---@field bound integer maximum entries the collector accepts
---@field entries table<integer, table<string, unknown>> recorded entries in order

---@class BattleTraceEntry
---@field kind string record kind: random, arithmetic, or event
---@field ordinal integer one-based position in the collector
---@field detail table<string, unknown> the recorded draw, stage, or event

---@class BattleTraceMismatch
---@field kind string boundary of the first divergence
---@field ordinal integer position of the first divergent entry
---@field expected table<string, unknown>? the expected entry, when present
---@field actual table<string, unknown>? the actual entry, when present

---@class BattleTrace
local BattleTrace = {}

---@param collector unknown caller-owned collector under inspection
---@return table<integer, table<string, unknown>> the entry array
local function checkCollector(collector)
  assert(type(collector) == "table", "diagnostics record into a caller-owned collector")
  local owned = collector --[[@as table<string, unknown>]]
  assert(
    type(owned.bound) == "number" and owned.bound --[[@as integer]] % 1 == 0 and owned.bound --[[@as integer]] >= 1,
    "diagnostic collectors carry a positive integer bound"
  )
  assert(type(owned.entries) == "table", "diagnostic collectors carry their entry array")
  return owned.entries --[[@as table<integer, table<string, unknown>>]]
end

---@param collector table<string, unknown> caller-owned collector
---@param kind string record kind under recording
---@param detail table<string, unknown> draw, stage, or event under recording
local function append(collector, kind, detail)
  local entries = checkCollector(collector)
  assert(type(detail) == "table", "diagnostic entries carry a record detail")
  local bound = collector.bound --[[@as integer]]
  assert(#entries < bound, "diagnostic collector reached its bound")
  entries[#entries + 1] = { kind = kind, ordinal = #entries + 1, detail = detail }
end

--- Records one labeled draw (raw value, call-site reason, and semantic
--- cause) without consuming an extra draw.
---@param collector table<string, unknown> caller-owned collector
---@param draw table<string, unknown> draw record under recording
function BattleTrace.random(collector, draw)
  append(collector, "random", draw)
end

--- Records one staged arithmetic intermediate (stage name with its integer
--- input and output) without moving the shared stream.
---@param collector table<string, unknown> caller-owned collector
---@param stage table<string, unknown> staged intermediate under recording
function BattleTrace.arithmetic(collector, stage)
  append(collector, "arithmetic", stage)
end

--- Mirrors one emitted semantic event into the collector.
---@param collector table<string, unknown> caller-owned collector
---@param event table<string, unknown> emitted event under recording
function BattleTrace.event(collector, event)
  append(collector, "event", event)
end

---@param want unknown expected entry side
---@param got unknown actual entry side
---@param active table<string, boolean> traversal keys on the current path
---@return boolean true when both entry sides match structurally
local function entriesEqual(want, got, active)
  if type(want) ~= type(got) then
    return false
  end
  if type(want) ~= "table" then
    return want == got
  end
  local key = tostring(want) .. "/" .. tostring(got)
  if active[key] == true then
    return true
  end
  active[key] = true
  local expected = want --[[@as table<unknown, unknown>]]
  local actual = got --[[@as table<unknown, unknown>]]
  for field, value in pairs(expected) do
    if not entriesEqual(value, actual[field], active) then
      return false
    end
  end
  for field in pairs(actual) do
    if expected[field] == nil then
      return false
    end
  end
  active[key] = nil
  return true
end

--- Compares two entry arrays and reports the first divergent position with
--- both sides attached. Returns nil when the arrays match exactly.
---@param expected table<integer, table<string, unknown>> expected entries in order
---@param actual table<integer, table<string, unknown>> actual entries in order
---@return BattleTraceMismatch? the first divergence, or nil when entries match
function BattleTrace.mismatch(expected, actual)
  assert(type(expected) == "table", "divergence reports compare two entry arrays")
  assert(type(actual) == "table", "divergence reports compare two entry arrays")
  local count = math.max(#expected, #actual)
  for ordinal = 1, count do
    local want = expected[ordinal]
    local got = actual[ordinal]
    if not entriesEqual(want, got, {}) then
      local kind = "event"
      if type(want) == "table" and type(want.kind) == "string" then
        kind = want.kind --[[@as string]]
      elseif type(got) == "table" and type(got.kind) == "string" then
        kind = got.kind --[[@as string]]
      end
      return { kind = kind, ordinal = ordinal, expected = want, actual = got }
    end
  end
  return nil
end

return BattleTrace
