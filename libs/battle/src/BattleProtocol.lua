-- Typed external battle protocol: decision batches, replies, choices, and
-- events. Registered decision kinds own their accepted choice vocabulary;
-- every payload schema is validated here, and unknown kinds or malformed
-- references fail instead of coercing into a fallback choice. Target
-- references distinguish retargetable position slots from locked
-- combatant entries, side-wide intents, field-wide intents, and passes.

local BattleErrors = require("libs.battle.src.errors")

---@class BattleProtocol
local BattleProtocol = {}

---@param value unknown
---@param bound integer
---@return boolean
local function isPositiveInt(value, bound)
  return type(value) == "number"
    and value == value
    and math.abs(value) ~= math.huge
    and value % 1 == 0
    and value >= 1
    and value <= bound
end

---@param value unknown
---@return boolean
local function isId(value)
  return isPositiveInt(value, 9007199254740991)
end

-- Decision kinds map to the choice vocabulary they accept. The scripted
-- decision point used by the headless kernel accepts the whole choice
-- vocabulary; later battle phases register narrower kinds through the same
-- boundary instead of branching inside the session.
local decisionKinds = {
  action = { attack = true, switch = true, confirm = true, item = true, run = true },
}

---@param kind string
---@param allowed string[] choice kinds this decision point accepts
function BattleProtocol.registerDecisionKind(kind, allowed)
  assert(type(kind) == "string" and kind ~= "", "decision registration requires a non-empty kind")
  assert(type(allowed) == "table", "decision registration requires its accepted choices")
  if decisionKinds[kind] ~= nil then
    error(BattleErrors.invalidState("decision kinds are never registered twice", { kind = kind }))
  end
  local accepted = {}
  for _, choice in ipairs(allowed) do
    if choice ~= "attack" and choice ~= "switch" and choice ~= "confirm" and choice ~= "item" and choice ~= "run" then
      error(BattleErrors.input("decision kinds accept only known choice vocabulary", {
        kind = kind,
        choice = tostring(choice),
      }))
    end
    accepted[choice] = true
  end
  decisionKinds[kind] = accepted
end

---@param kind string
---@return boolean
function BattleProtocol.isDecisionKind(kind)
  return decisionKinds[kind] ~= nil
end

---@param ref unknown
---@return table<string, unknown> the validated target reference
function BattleProtocol.validateTarget(ref)
  if type(ref) ~= "table" then
    error(BattleErrors.input("choice targets must be records", {}))
  end
  local target = ref --[[@as table<string, unknown>]]
  local kind = target.kind
  if kind == "position" then
    if not isId(target.position) then
      error(BattleErrors.input("position targets must name a positive slot", {}))
    end
  elseif kind == "combatant" then
    if not isId(target.combatant) then
      error(BattleErrors.input("combatant targets must name a positive combatant", {}))
    end
    if target.activation ~= nil and not isId(target.activation) then
      error(BattleErrors.input("locked targets must carry positive entry tokens", {}))
    end
  elseif kind == "side" then
    if not isId(target.side) then
      error(BattleErrors.input("side targets must name a positive side", {}))
    end
  elseif kind == "field" or kind == "none" then
    -- Whole-field intents and passes carry no further identity.
  else
    error(BattleErrors.input("choice targets must name a known variant", { kind = tostring(kind) }))
  end
  return target
end

---@param choice unknown
---@param decisionKind string
---@return table<string, unknown> the validated choice
function BattleProtocol.validateChoice(choice, decisionKind)
  if type(decisionKind) ~= "string" or decisionKinds[decisionKind] == nil then
    error(BattleErrors.missingBehavior("choices require a registered decision kind", {
      kind = tostring(decisionKind),
    }))
  end
  if type(choice) ~= "table" then
    error(BattleErrors.input("battle choices must be records", {}))
  end
  local record = choice --[[@as table<string, unknown>]]
  local actor = record.actor
  if type(actor) ~= "table" then
    error(BattleErrors.input("battle choices must name their actor", {}))
  end
  local actorRecord = actor --[[@as table<string, unknown>]]
  if not isId(actorRecord.combatant) then
    error(BattleErrors.input("choice actors must name a positive combatant", {}))
  end
  if actorRecord.activation ~= nil and not isId(actorRecord.activation) then
    error(BattleErrors.input("choice actors must carry positive entry tokens", {}))
  end
  if type(record.kind) ~= "string" then
    error(BattleErrors.input("battle choices must name their kind", {}))
  end
  local kind = record.kind --[[@as string]]
  if
    decisionKinds[
      decisionKind --[[@as string]]
    ][kind] ~= true
  then
    error(BattleErrors.input("the decision point does not accept this choice", {
      decision = decisionKind,
      choice = kind,
    }))
  end
  if type(record.payload) ~= "table" then
    error(BattleErrors.input("battle choices must carry their payload record", { choice = kind }))
  end
  local payload = record.payload --[[@as table<string, unknown>]]
  if kind == "attack" then
    if
      type(payload.moveSlot) ~= "number"
      or payload.moveSlot ~= payload.moveSlot
      or payload.moveSlot % 1 ~= 0
      or payload.moveSlot < 0
    then
      error(BattleErrors.input("strike move slots are zero-based integers", { choice = kind }))
    end
    BattleProtocol.validateTarget(payload.target)
  elseif kind == "switch" then
    if not isId(payload.replacement) then
      error(BattleErrors.input("replacements must name a positive combatant", { choice = kind }))
    end
  elseif kind == "confirm" then
    -- Acknowledgement prompts carry no further payload.
  elseif kind == "item" then
    if type(payload.item) ~= "string" or payload.item == "" then
      error(BattleErrors.input("item choices must name their item", { choice = kind }))
    end
    if payload.target ~= nil then
      BattleProtocol.validateTarget(payload.target)
    end
  elseif kind == "run" then
    -- Flight carries an empty payload. Whether flight is legal (wild
    -- against trainer formats, trapping) is format and session policy,
    -- decided where the live battle facts are, not here.
  else
    error(BattleErrors.input("battle choices must name a known kind", { choice = kind }))
  end
  return record
end

---@param reply unknown
---@param decisionKind string
---@return table<string, unknown> the validated reply
function BattleProtocol.validateReply(reply, decisionKind)
  if type(reply) ~= "table" then
    error(BattleErrors.input("decision replies must be records", {}))
  end
  local record = reply --[[@as table<string, unknown>]]
  if not isId(record.requestId) then
    error(BattleErrors.input("decision replies must name a positive request", {}))
  end
  if type(record.epoch) ~= "number" or record.epoch ~= record.epoch or record.epoch % 1 ~= 0 or record.epoch < 0 then
    error(BattleErrors.input("decision replies must carry a non-negative integer epoch", {}))
  end
  if type(record.controller) ~= "string" or record.controller == "" then
    error(BattleErrors.input("decision replies must name their controller", {}))
  end
  if type(record.choices) ~= "table" then
    error(BattleErrors.input("decision replies must carry their choices array", {}))
  end
  local choices = record.choices --[[@as table<integer, unknown>]]
  if #choices == 0 then
    error(BattleErrors.input("decision replies must answer at least one actor", {}))
  end
  for index = 1, #choices do
    if choices[index] == nil then
      error(BattleErrors.input("decision replies must not skip choices", { index = index }))
    end
    BattleProtocol.validateChoice(choices[index], decisionKind)
  end
  return record
end

---@param event unknown
---@return table<string, unknown> the validated event
function BattleProtocol.validateEvent(event)
  if type(event) ~= "table" then
    error(BattleErrors.input("battle events must be records", {}))
  end
  local record = event --[[@as table<string, unknown>]]
  if not isId(record.sequence) then
    error(BattleErrors.input("battle events must carry positive sequence ordinals", {}))
  end
  if type(record.kind) ~= "string" or record.kind == "" then
    error(BattleErrors.input("battle events must name their kind", {}))
  end
  if type(record.cause) ~= "table" then
    error(BattleErrors.input("battle events must carry their cause", {}))
  end
  if type(record.audience) ~= "string" or record.audience == "" then
    error(BattleErrors.input("battle events must name their audience", {}))
  end
  if type(record.payload) ~= "table" then
    error(BattleErrors.input("battle events must carry their payload record", {}))
  end
  for _, field in ipairs({ "actionId", "hitIndex" }) do
    if record[field] ~= nil and not isId(record[field]) then
      error(BattleErrors.input("battle event ordinals must be positive integers", { field = field }))
    end
  end
  return record
end

return BattleProtocol
