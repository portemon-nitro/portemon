-- Exchange sequencing for combatants leaving and entering the field. An
-- exchange runs as an interruptible child frame: eligibility and trapping
-- gate the exchange before anything moves, a pursuit-style interception
-- checkpoint holds the departure while hit consequences settle, entry
-- consequences resolve before the parent action answers exactly once, and
-- each arrival mints a fresh entry token while only the declared effect
-- subset travels along. Reserves promised to one position are refused to
-- sibling positions until released.

local BattleErrors = require("libs.battle.src.errors")
local BattleProtocol = require("libs.battle.src.BattleProtocol")

---@class SwitchOutgoingRef
---@field combatant integer departing roster identity
---@field activation integer departing entry token

---@class SwitchFrameState
---@field position integer field slot being exchanged
---@field outgoing SwitchOutgoingRef captured departing entry
---@field incoming integer arriving roster identity
---@field reason string exchange class
---@field voluntary boolean true only for free voluntary exchanges
---@field activation integer fresh entry token minted for the arrival
---@field cursor string continuation cursor
---@field transferredEffects string[] effect names traveling with the exchange
---@field preview table<string, integer>? permitted arrival preview for shift prompts
---@field parentAction integer? interrupted action awaiting its single answer

---@class Switching
local Switching = {}

if not BattleProtocol.isDecisionKind("shift") then
  BattleProtocol.registerDecisionKind("shift", { "switch" })
end

local REASONS = {
  voluntary = true,
  forced = true,
  faint = true,
  u_turn = true,
  baton_pass = true,
  shift = true,
}

---@param value unknown
---@return boolean
local function isPositiveInt(value)
  return type(value) == "number" and value == value and value % 1 == 0 and value >= 1 and value <= 9007199254740991
end

---@param haystack table<string, unknown>|nil
---@param needle integer
---@return boolean
local function contains(haystack, needle)
  if type(haystack) ~= "table" then
    return false
  end
  for _, value in ipairs(haystack) do
    if value == needle then
      return true
    end
  end
  return false
end

---@param query table<string, unknown>
---@return boolean
local function isHeld(query)
  return type(query.trap) == "table" and query.trap.held == true
end

--- Judges whether the requested exchange may start. Trapping holds
--- voluntary and shift departures; required replacements answer despite
--- the trap. A promised reserve is refused to sibling positions.
---@param query table<string, unknown> exchange request under test
---@return table<string, unknown> eligibility verdict carrying ok and, on refusal, reason
function Switching.eligible(query)
  assert(type(query) == "table", "exchange eligibility reads a query record")
  local reason = query.reason
  if type(reason) ~= "string" or REASONS[reason] ~= true then
    return { ok = false, reason = "unknown_reason" }
  end
  if reason == "shift" then
    if query.style ~= "shift" then
      return { ok = false, reason = "set_style" }
    end
    local topology = query.topology
    if type(topology) ~= "table" or topology.activePerSide ~= 1 or topology.partners == true then
      return { ok = false, reason = "ineligible_format" }
    end
  end
  if (reason == "voluntary" or reason == "shift") and isHeld(query) then
    return { ok = false, reason = "trapped" }
  end
  local incoming = query.incoming
  if incoming ~= nil then
    if not isPositiveInt(incoming) then
      return { ok = false, reason = "unknown_reserve" }
    end
    if contains(query.reserved, incoming) then
      return { ok = false, reason = "reserved" }
    end
    if contains(query.fainted, incoming) then
      return { ok = false, reason = "fainted" }
    end
    if query.reserves ~= nil and not contains(query.reserves, incoming) then
      return { ok = false, reason = "unknown_reserve" }
    end
  end
  return { ok = true }
end

---@param seed table<string, unknown> exchange request carrying its draw stream
---@return integer
local function drawForcedArrival(seed)
  local candidates = {}
  if type(seed.reserves) == "table" then
    for _, combatant in ipairs(seed.reserves) do
      if
        isPositiveInt(combatant)
        and not contains(seed.fainted, combatant)
        and not contains(seed.reserved, combatant)
      then
        candidates[#candidates + 1] = combatant
      end
    end
  end
  if #candidates == 0 then
    error(BattleErrors.input("forced replacement has no eligible reserve", {}))
  end
  local stream = seed.stream
  assert(
    type(stream) == "table" and type(stream.nextU16) == "function",
    "forced replacement draws from the battle stream"
  )
  local roll = stream:nextU16("switch:forced", { reason = "forced", position = seed.position })
  assert(type(roll) == "number", "forced replacement draws an integer roll")
  return candidates[(roll % #candidates) + 1]
end

---@param frame SwitchFrameState
---@param cursor string
---@param incoming integer?
---@return SwitchFrameState
local function advanceFrame(frame, cursor, incoming)
  local transferred = {}
  for index, name in ipairs(frame.transferredEffects) do
    transferred[index] = name
  end
  local next = {
    position = frame.position,
    outgoing = { combatant = frame.outgoing.combatant, activation = frame.outgoing.activation },
    incoming = incoming or frame.incoming,
    reason = frame.reason,
    voluntary = frame.voluntary,
    activation = frame.activation,
    cursor = cursor,
    transferredEffects = transferred,
    preview = nil,
    parentAction = frame.parentAction,
  }
  if frame.preview ~= nil then
    next.preview = { incoming = next.incoming }
  end
  return Switching.validateFrame(next)
end

--- Starts an exchange continuation. Ineligible requests fail as invalid
--- input before drawing; forced replacement without a named arrival draws
--- its arrival from the eligible reserves through the battle stream.
---@param seed table<string, unknown> exchange request
---@return SwitchFrameState
function Switching.start(seed)
  assert(type(seed) == "table", "exchanges start from a seed record")
  assert(isPositiveInt(seed.position), "exchange seeds name a positive position")
  assert(type(seed.outgoing) == "table", "exchange seeds capture the departing entry")
  assert(isPositiveInt(seed.outgoing.combatant), "exchange seeds name the departing combatant")
  assert(isPositiveInt(seed.outgoing.activation), "exchange seeds capture the departing entry token")
  local verdict = Switching.eligible({
    position = seed.position,
    incoming = seed.incoming,
    reason = seed.reason,
    style = seed.style,
    topology = seed.topology,
    trap = seed.trap,
    reserves = seed.reserves,
    reserved = seed.reserved,
    fainted = seed.fainted,
  })
  if not verdict.ok then
    error(BattleErrors.input("the exchange is not eligible", { reason = verdict.reason }))
  end
  local reason = seed.reason --[[@as string]]
  local incoming = seed.incoming
  if incoming == nil then
    if reason ~= "forced" then
      error(BattleErrors.input("only forced replacement draws its own arrival", { reason = tostring(reason) }))
    end
    incoming = drawForcedArrival(seed)
  end
  assert(isPositiveInt(incoming), "exchanges name a positive arrival")
  local transferred = {}
  if seed.transfer ~= nil then
    assert(type(seed.transfer) == "table", "exchange seeds declare their traveling subset as an array")
    for index, name in ipairs(seed.transfer) do
      assert(type(name) == "string", "traveling effects are named")
      transferred[index] = name
    end
  end
  local frame = {
    position = seed.position,
    outgoing = { combatant = seed.outgoing.combatant, activation = seed.outgoing.activation },
    incoming = incoming,
    reason = reason,
    voluntary = reason == "voluntary",
    activation = seed.outgoing.activation + 1,
    cursor = "start",
    transferredEffects = transferred,
    preview = nil,
    parentAction = seed.parentAction,
  }
  if reason == "shift" then
    frame.preview = { incoming = incoming }
  end
  return Switching.validateFrame(frame)
end

--- Steps an exchange continuation. Waiting outcomes withhold the parent
--- answer; the first completing step answers the parent exactly once and
--- settled frames stay settled without answering again.
---@param context table<string, unknown> step inputs carrying interception, entry, and replacement state
---@param frame SwitchFrameState
---@return table<string, unknown> step outcome carrying done, events, frame, and parentResume or needsReplacement
function Switching.step(context, frame)
  assert(type(context) == "table", "exchange steps carry their step context")
  local current = Switching.validateFrame(frame)
  if current.cursor == "done" then
    return { done = true, events = {}, frame = current, parentResume = nil, needsReplacement = nil }
  end
  if context.hitConsequences == "pending" then
    return { done = false, events = {}, frame = current, parentResume = nil, needsReplacement = nil }
  end
  if context.replacement ~= nil then
    assert(isPositiveInt(context.replacement), "supplied replacements name a positive combatant")
    local completed = advanceFrame(current, "done", context.replacement)
    completed.activation = current.activation + 1
    local settled = Switching.validateFrame(completed)
    local outcome = { done = true, events = {}, frame = settled, parentResume = nil, needsReplacement = nil }
    if settled.parentAction ~= nil then
      outcome.parentResume = "resume"
    end
    return outcome
  end
  local entry = context.entry
  if type(entry) == "table" and type(entry.damageToIncoming) == "number" and entry.damageToIncoming > 0 then
    local waiting = advanceFrame(current, "entry")
    return { done = false, events = {}, frame = waiting, parentResume = nil, needsReplacement = current.position }
  end
  local settled = advanceFrame(current, "done")
  local outcome = { done = true, events = {}, frame = settled, parentResume = nil, needsReplacement = nil }
  if settled.parentAction ~= nil then
    outcome.parentResume = "resume"
  end
  return outcome
end

--- Validates an exchange continuation frame.
---@param frame SwitchFrameState
---@return SwitchFrameState
function Switching.validateFrame(frame)
  assert(type(frame) == "table", "exchange frames are records")
  assert(isPositiveInt(frame.position), "exchange frames stay pinned to a positive position")
  assert(type(frame.outgoing) == "table", "exchange frames capture the departing entry")
  assert(isPositiveInt(frame.outgoing.combatant), "exchange frames name the departing combatant")
  assert(isPositiveInt(frame.outgoing.activation), "exchange frames capture the departing entry token")
  assert(isPositiveInt(frame.incoming), "exchange frames name their arrival")
  assert(type(frame.reason) == "string" and REASONS[frame.reason] == true, "exchange frames keep a known reason")
  assert(type(frame.voluntary) == "boolean", "exchange frames mark voluntary exchanges")
  assert(frame.voluntary == (frame.reason == "voluntary"), "only the voluntary reason counts as voluntary")
  assert(isPositiveInt(frame.activation), "exchange frames mint a fresh entry token for the arrival")
  assert(type(frame.cursor) == "string" and frame.cursor ~= "", "exchange frames name their cursor")
  assert(type(frame.transferredEffects) == "table", "exchange frames name their traveling subset")
  if frame.preview ~= nil then
    assert(type(frame.preview) == "table", "exchange previews are records")
  end
  return frame
end

return Switching
