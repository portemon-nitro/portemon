-- Native battler slot centers used when a task has to place transient
-- sprites or anchor a picture write without a live layout read. These are
-- the presented picture centers the battle layout settles each side slot on;
-- particle sources, configured sprites, and picture tasks share them so one
-- source position has one portemon value.

local BattleSlotCenters = {}

BattleSlotCenters.centers = {
  ["solo-player"] = { x = 64, y = 112 },
  ["solo-enemy"] = { x = 192, y = 50 },
  ["player-side-slot-1"] = { x = 40, y = 112 },
  ["enemy-side-slot-1"] = { x = 216, y = 50 },
  ["player-side-slot-2"] = { x = 80, y = 120 },
  ["enemy-side-slot-2"] = { x = 176, y = 42 },
}

---@param slot string? topology slot identity
---@return { x: integer, y: integer }|nil center behind a known slot
function BattleSlotCenters.get(slot)
  if type(slot) ~= "string" then
    return nil
  end
  return BattleSlotCenters.centers[slot]
end

return BattleSlotCenters
