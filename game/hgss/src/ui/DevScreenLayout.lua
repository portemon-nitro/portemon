-- Shared plain-text layout for the developer-facing preparation/loading
-- screens (field entry, New Game). Not production HGSS chrome: a fixed
-- top-left margin with one line height between rows.

---@class DevScreenLayout
---@field MARGIN integer
---@field LINE_HEIGHT integer
local DevScreenLayout = {
  MARGIN = 24,
  LINE_HEIGHT = 24,
}

return DevScreenLayout
