-- Locked compact portrait/action/message geometry in native logical
-- pixels for the Starter Choice nativeLike (single-pane) layout: the
-- selected semantic message, three source-order portraits, and the
-- primary/Back actions. Shared by the interface (hit-testing) and the
-- presentation (drawing) so the two never drift apart.

---@class StarterCompactLayout
local StarterCompactLayout = {
  MESSAGE = { x = 8, y = 8, width = 240, height = 48 },
  PORTRAITS = {
    { x = 8, y = 60, width = 80, height = 80 },
    { x = 88, y = 60, width = 80, height = 80 },
    { x = 168, y = 60, width = 80, height = 80 },
  },
  PRIMARY = { x = 8, y = 164, width = 112, height = 24 },
  BACK = { x = 136, y = 164, width = 112, height = 24 },
}

return StarterCompactLayout
