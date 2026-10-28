-- Shared title and footer wording for an open battle child modal. Both
-- battle presentations draw the same title, guidance caption, and
-- occupied roster fraction while keeping their own screen geometry and
-- pixel placement, so only these pure text projections live here. The
-- helper never observes LÖVE, input, assets, or mutable state.

---@class BattleChildText
local BattleChildText = {}

---@param child table<string, unknown> detached child view under titling
---@return string modal title wording
function BattleChildText.title(child)
  if type(child.sourceTitle) == "string" then
    return child.sourceTitle
  end
  local kind = child.kind
  if kind == "target" then
    return "Use " .. tostring(child.stagedItem or "the item") .. " on whom?"
  elseif kind == "bag" then
    if child.empty == true then
      return "The bag is empty."
    end
    local page = child.page --[[@as table<string, unknown>?]]
    local paging = ""
    if type(page) == "table" then
      paging = " " .. tostring(page.current or 1) .. "/" .. tostring(page.count or 1)
    end
    return "BAG: " .. tostring(child.currentPocket or "?") .. paging
  elseif kind == "learn" then
    return "Forget a move for " .. tostring(child.incomingMove or "?") .. "?"
  elseif kind == "move" then
    assert(type(child.holderName) == "string" and child.holderName ~= "", "move selection names its holder")
    return child.holderName
  end
  if child.cancellable == true then
    return "Choose a Pokemon!"
  end
  return "Choose a replacement!"
end

---@param child table<string, unknown> detached child view under guidance wording
---@return string footer guidance wording
function BattleChildText.subtitle(child)
  if type(child.sourcePrompt) == "string" then
    return child.sourcePrompt
  end
  if child.kind == "target" then
    return "Select the target."
  elseif child.kind == "bag" then
    return "Select an item."
  elseif child.kind == "learn" then
    return "Select a move to forget."
  elseif child.kind == "move" then
    return "Restore which move?"
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
