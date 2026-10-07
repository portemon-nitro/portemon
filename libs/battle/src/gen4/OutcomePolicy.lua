-- Terminal result selection. The result is selected from side standings
-- at settlement checkpoints, never from raw health: outstanding
-- replacements withhold every outcome, kept combatants select capture, fled
-- sides select flight without a winner's honors, mutual wipes select a
-- draw, and the surviving side otherwise wins. Results carry exactly their
-- documented keys; numeric outcome projection stays host-owned and no field
-- mutation passes through the selector.

---@class BattleResult
---@field reason string semantic terminal reason
---@field winningSides integer[] sides credited with the win
---@field losingSides integer[] sides recorded as losing
---@field captured integer[] combatants kept through capture
---@field nativeOutcome string? semantic outcome code; numeric conversion is host-owned

---@class OutcomePolicy
local OutcomePolicy = {}

---@param value unknown
---@return boolean
local function isPositiveInt(value)
  return type(value) == "number" and value == value and value % 1 == 0 and value >= 1 and value <= 9007199254740991
end

--- Evaluates a settlement summary. Returns nil while replacements are
--- outstanding or every side still stands; otherwise returns the semantic
--- result naming its reason and side results.
---@param summary table<string, unknown> settlement summary carrying sides, pendingReplacements, and captured
---@return BattleResult?
function OutcomePolicy.evaluate(summary)
  assert(type(summary) == "table", "result selection reads a settlement summary")
  local sides = summary.sides
  assert(type(sides) == "table" and #sides >= 1, "result selection reads side standings")
  local pending = summary.pendingReplacements
  assert(
    type(pending) == "number" and pending % 1 == 0 and pending >= 0,
    "result selection reads outstanding replacements"
  )
  if pending > 0 then
    return nil
  end
  local captured = summary.captured
  assert(type(captured) == "table", "result selection reads kept combatants")
  if #captured > 0 then
    local kept = {}
    for index, combatant in ipairs(captured) do
      assert(isPositiveInt(combatant), "kept combatants name positive roster identities")
      kept[index] = combatant
    end
    return { reason = "capture", winningSides = {}, losingSides = {}, captured = kept }
  end
  local fledSides = {}
  local standingSides = {}
  local wipedSides = {}
  for _, side in ipairs(sides) do
    assert(type(side) == "table", "result selection reads side records")
    assert(isPositiveInt(side.id), "side records name a positive side")
    assert(
      type(side.standing) == "number" and side.standing % 1 == 0 and side.standing >= 0,
      "side records count combatants still able to continue"
    )
    if side.fled == true then
      fledSides[#fledSides + 1] = side.id
    elseif side.standing > 0 then
      standingSides[#standingSides + 1] = side.id
    else
      wipedSides[#wipedSides + 1] = side.id
    end
  end
  if #fledSides > 0 then
    return { reason = "flee", winningSides = {}, losingSides = fledSides, captured = {} }
  end
  if #standingSides == #sides then
    return nil
  end
  if #standingSides == 0 then
    return { reason = "draw", winningSides = {}, losingSides = wipedSides, captured = {} }
  end
  return { reason = "victory", winningSides = standingSides, losingSides = wipedSides, captured = {} }
end

return OutcomePolicy
