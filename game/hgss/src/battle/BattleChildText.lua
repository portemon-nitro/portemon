-- Shared footer wording for an open battle child modal. Both battle
-- presentations draw the same guidance caption and the same occupied
-- roster fraction while keeping their own screen geometry and pixel
-- placement, so only these two pure text projections live here. The
-- helper never observes LÖVE, input, assets, or mutable state.

---@class BattleChildText
local BattleChildText = {}

---@param child table<string, unknown> detached child view under guidance wording
---@return string footer guidance wording
function BattleChildText.subtitle(child)
  if child.kind == "target" then
    return "Select the target."
  elseif child.kind == "bag" then
    return "Select an item."
  elseif child.kind == "learn" then
    return "Select a move to forget."
  elseif child.cancellable == true then
    return "Select a reserve."
  end
  return "Select its replacement."
end

---@param child table<string, unknown> detached child view under occupancy wording
---@return string? occupied roster fraction, nil outside party selection
function BattleChildText.occupancy(child)
  if child.kind ~= "party" and child.kind ~= "target" then
    return nil
  end
  local rows = child.rows --[[@as table<integer, table<string, unknown>>?]]
  if type(rows) ~= "table" then
    return nil
  end
  local occupied = 0
  for _, row in ipairs(rows) do
    if type(row) == "table" and row.occupied == true then
      occupied = occupied + 1
    end
  end
  return tostring(occupied) .. "/" .. tostring(#rows)
end

return BattleChildText
