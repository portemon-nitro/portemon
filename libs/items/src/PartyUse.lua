-- Shared source-defined HP restoration arithmetic for item-domain
-- consumers. Fixed, full, half, and quarter restoration resolve to exact
-- integer amounts: full restores the maximum, half and quarter floor, and
-- single-point maximums restore one point.

---@class PartyUse
local PartyUse = {}

---@param maxHp integer derived maximum health under restoration
---@param restore table<string, unknown> generated fixed/full/half/quarter restore record
---@return integer exact restoration amount before ceiling capping
function PartyUse.restoreAmount(maxHp, restore)
  assert(type(maxHp) == "number" and maxHp % 1 == 0 and maxHp >= 1, "restore needs the derived maximum")
  if maxHp == 1 then
    return 1
  end
  if restore.kind == "full" then
    return maxHp
  elseif restore.kind == "half" then
    return math.floor(maxHp / 2)
  elseif restore.kind == "quarter" then
    return math.floor(maxHp / 4)
  end
  assert(restore.kind == "fixed", "restore names a closed amount kind")
  local amount = assert(restore.amount) --[[@as integer]]
  assert(type(amount) == "number" and amount % 1 == 0 and amount >= 1, "fixed restore needs a positive amount")
  return amount
end

return PartyUse
