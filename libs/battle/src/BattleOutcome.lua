-- Detached battle completion result: validates the typed outcome a finished
-- battle hands to result publication and finalizes per-combatant persistent
-- records. Finalization starts from the settled persistent record the
-- progression owners resolved and enforces source copy-out hygiene: the
-- canonical species, form, ability, and learned moves always come from the
-- persistent record, and battle-temporary keys (projected stages,
-- frame-local references, volatile state) never persist. This module owns
-- no live state and performs no publication; callers stage the finalized
-- records through the party owner.

---@class BattleOutcome
local BattleOutcome = {}

-- Terminal results the committer accepts. A capture result reports that
-- the throw succeeded; placement of the caught mon is decided separately.
BattleOutcome.RESULTS = { win = true, loss = true, draw = true, flee = true, capture = true }

-- Battle-temporary keys that must never reach a persisted mon record.
local TRANSIENT_FIELDS = {
  stages = true,
  statStages = true,
  volatiles = true,
  volatile = true,
  frame = true,
  combat = true,
  temporary = true,
}

-- Canonical identity fields that always resolve from the persistent
-- record, never from borrowed battle state such as a transform target.
local IDENTITY_FIELDS = { "species", "form", "ability", "moves", "personality" }

---@generic T
---@param value T
---@return T
local function copyValue(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for key, item in pairs(value) do
    out[key] = copyValue(item)
  end
  return out
end

---@param result unknown
local function checkResult(result)
  if type(result) ~= "string" or BattleOutcome.RESULTS[result] ~= true then
    error("battle outcome carries an unknown result: " .. tostring(result), 0)
  end
end

---@param outcome table<string, unknown>
---@return table<string, unknown>
function BattleOutcome.validate(outcome)
  if type(outcome) ~= "table" then
    error("battle outcome must be a record", 0)
  end
  if type(outcome.id) ~= "string" or outcome.id == "" then
    error("battle outcome requires a non-empty id", 0)
  end
  checkResult(outcome.result)
  if type(outcome.monUpdates) ~= "table" then
    error("battle outcome requires a mon update array", 0)
  end
  for _, update in ipairs(outcome.monUpdates) do
    if type(update) ~= "table" or type(update.mon) ~= "table" then
      error("battle outcome updates carry persistent mon records", 0)
    end
  end
  for _, key in ipairs({ "inventoryDeltas", "captures", "progressionFlags" }) do
    if outcome[key] ~= nil and type(outcome[key]) ~= "table" then
      error("battle outcome " .. key .. " must be a record when present", 0)
    end
  end
  return copyValue(outcome)
end

---@param persistent table<string, unknown>
---@param battle table<string, unknown>?
---@return table<string, unknown>
local function finalizeMon(persistent, battle)
  if type(persistent) ~= "table" then
    error("battle outcome combatants carry settled persistent records", 0)
  end
  if battle ~= nil and type(battle) ~= "table" then
    error("battle outcome combatants carry record battle state", 0)
  end
  local mon = copyValue(persistent)
  if type(battle) == "table" then
    for _, field in ipairs(IDENTITY_FIELDS) do
      if persistent[field] ~= nil then
        mon[field] = copyValue(persistent[field])
      end
    end
  end
  for field in pairs(mon) do
    if TRANSIENT_FIELDS[field] == true then
      mon[field] = nil
    end
  end
  return mon
end

-- Builds the detached completion result from settled combatants. Each
-- combatant carries the settled persistent record plus the optional
-- battle record it fought with; only persistent identity and persistent
-- state survive. Optional detached payloads (inventory deltas, captures,
-- rewards, world results, random provenance, progression flags) pass
-- through untouched when the caller supplies them.
---@param input { id: string, result: string, combatants: { persistent: table<string, unknown>, battle: table<string, unknown>?, source: table<string, unknown>? }[], inventoryDeltas: table<string, unknown>?, captures: table<string, unknown>?, rewards: table<string, unknown>?, worldResults: table<string, unknown>?, finalRandom: table<string, unknown>?, progressionFlags: table<string, unknown>? }
---@return table<string, unknown>
function BattleOutcome.finalize(input)
  if type(input) ~= "table" then
    error("battle outcome finalization requires an input record", 0)
  end
  if type(input.id) ~= "string" or input.id == "" then
    error("battle outcome requires a non-empty id", 0)
  end
  checkResult(input.result)
  if type(input.combatants) ~= "table" then
    error("battle outcome requires a combatant array", 0)
  end
  local monUpdates = {}
  for _, combatant in ipairs(input.combatants) do
    if type(combatant) ~= "table" then
      error("battle outcome combatants must be records", 0)
    end
    monUpdates[#monUpdates + 1] = {
      source = copyValue(combatant.source),
      mon = finalizeMon(combatant.persistent, combatant.battle),
    }
  end
  return BattleOutcome.validate({
    id = input.id,
    result = input.result,
    monUpdates = monUpdates,
    inventoryDeltas = copyValue(input.inventoryDeltas) or {},
    captures = copyValue(input.captures) or {},
    rewards = copyValue(input.rewards) or {},
    worldResults = copyValue(input.worldResults) or {},
    finalRandom = copyValue(input.finalRandom),
    progressionFlags = copyValue(input.progressionFlags) or {},
  })
end

return BattleOutcome
