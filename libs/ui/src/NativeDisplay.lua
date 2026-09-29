-- The one shared native pane resolution every fixed-size HGSS layout fits
-- against. Plain data: no geometry, no policy, no love.

---@class NativeDisplay
---@field WIDTH integer
---@field HEIGHT integer
local NativeDisplay = {
  WIDTH = 256,
  HEIGHT = 192,
}

return NativeDisplay
