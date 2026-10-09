-- Selection fill shared by the field-attached list screens that still draw
-- their own rows.

---@class FieldMenuTheme
---@field colors { selected: number[] }
local FieldMenuTheme = {}

FieldMenuTheme.colors = {
  selected = { 0.48, 0.62, 0.88, 1 },
}

return FieldMenuTheme
