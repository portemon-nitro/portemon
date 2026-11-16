-- Shared title and footer wording for an open battle child modal. Bag,
-- learn, and move children keep their staged titles and guidance
-- captions; party and target children paint through the native roster
-- and the retail wrapper pages alone, so without staged wording they
-- contribute no invented modal text. The helper never observes LÖVE,
-- input, assets, or mutable state.

---@class BattleChildText
local BattleChildText = {}

---@param child table<string, unknown> detached child view under titling
---@return string modal title wording, empty for natively painted children
function BattleChildText.title(child)
  if type(child.sourceTitle) == "string" then
    return child.sourceTitle
  end
  local kind = child.kind
  if kind == "bag" then
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
  return ""
end

---@param child table<string, unknown> detached child view under guidance wording
---@return string footer guidance wording, empty for natively painted children
function BattleChildText.subtitle(child)
  if type(child.sourcePrompt) == "string" then
    return child.sourcePrompt
  end
  if child.kind == "bag" then
    return "Select an item."
  elseif child.kind == "learn" then
    return "Select a move to forget."
  elseif child.kind == "move" then
    return "Restore which move?"
  end
  return ""
end

return BattleChildText
