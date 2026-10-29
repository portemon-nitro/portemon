-- Native HGSS battle-menu pointer regions shared by input and rendering.

---@class BattleMenuRegions
local BattleMenuRegions = {}

local REGIONS = {
  command = {
    { id = "fight", x = 0, y = 24, w = 256, h = 120 },
    { id = "bag", x = 0, y = 144, w = 80, h = 48 },
    { id = "pokemon", x = 176, y = 144, w = 80, h = 48 },
    { id = "run", x = 88, y = 152, w = 80, h = 40 },
  },
  moves = {
    { id = "move:0", x = 0, y = 24, w = 128, h = 56 },
    { id = "move:1", x = 128, y = 24, w = 128, h = 56 },
    { id = "move:2", x = 0, y = 88, w = 128, h = 56 },
    { id = "move:3", x = 128, y = 88, w = 128, h = 56 },
    { id = "cancel", x = 8, y = 152, w = 240, h = 40 },
  },
  target = {
    { id = "target:0", x = 0, y = 88, w = 121, h = 57 },
    { id = "target:1", x = 136, y = 8, w = 120, h = 73 },
    { id = "target:2", x = 136, y = 88, w = 120, h = 57 },
    { id = "target:3", x = 0, y = 8, w = 121, h = 73 },
    { id = "cancel", x = 8, y = 152, w = 240, h = 40 },
  },
  ["two-option"] = {
    { id = "confirm", x = 0, y = 32, w = 256, h = 64 },
    { id = "back", x = 0, y = 104, w = 256, h = 64 },
  },
}

---@param layout string native battle menu layout
---@return { id: string, x: number, y: number, w: number, h: number }[]? shared source regions, nil for unsupported layouts
function BattleMenuRegions.forLayout(layout)
  return REGIONS[layout]
end

return BattleMenuRegions
