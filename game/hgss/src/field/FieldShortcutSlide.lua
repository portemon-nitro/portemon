-- Fixed-tick slide of the closed-menu shortcut cluster (the Running Shoes
-- toggle and registered-item tabs pinned to the field's bottom-right corner):
-- it slides out past the screen's right edge while the field is held (the
-- start menu, a cutscene, or dialogue) and back in once it is free, at the
-- area-name banner's scroll step.

local FieldMapNameBanner = require("libs.hgss.src.ui.FieldMapNameBanner")

---@class FieldShortcutSlide
---@field private _distance integer logical pixels from fully in to fully out
---@field private _offset integer current logical displacement toward the edge
local FieldShortcutSlide = {}
FieldShortcutSlide.__index = FieldShortcutSlide

---@param distance integer logical pixels from fully in to fully out
---@return FieldShortcutSlide
function FieldShortcutSlide.new(distance)
  assert(type(distance) == "number" and distance % 1 == 0 and distance > 0, "the slide needs a positive distance")
  return setmetatable({ _distance = distance, _offset = 0 }, FieldShortcutSlide)
end

---@param held boolean whether the start menu or a cutscene/dialogue holds the field
function FieldShortcutSlide:updateFixed(held)
  local step = FieldMapNameBanner.SCROLL_STEP
  if held then
    self._offset = math.min(self._distance, self._offset + step)
  else
    self._offset = math.max(0, self._offset - step)
  end
end

---@return integer
function FieldShortcutSlide:offset()
  return self._offset
end

---@return boolean
function FieldShortcutSlide:isHidden()
  return self._offset >= self._distance
end

return FieldShortcutSlide
