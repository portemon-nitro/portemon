-- Small decoded G2D records with literal colors, geometry, and frame timing.
-- These values describe the fixture itself; they are not ROM extracts.

local M = {}

---@return table
function M.new()
  local redTile = string.rep(string.char(0x11), 32)
  local greenTile = string.rep(string.char(0x22), 32)
  return {
    char = { depth = 3, tiles = redTile .. greenTile },
    palette = {
      colors = {
        { r = 0, g = 0, b = 0 },
        { r = 255, g = 0, b = 0 },
        { r = 0, g = 255, b = 0 },
      },
    },
    screen = {
      width = 8,
      height = 8,
      entries = { { tile = 0, flipH = false, flipV = false, palette = 0 } },
    },
    cell = {
      cells = {
        {
          objs = {
            {
              x = -2,
              y = 3,
              tile = 0,
              flipH = false,
              flipV = false,
              palette = 0,
              width = 8,
              height = 8,
            },
          },
        },
      },
    },
    animation = {
      frames = {
        {
          cell = 0,
          duration = 4,
          element = "none",
          translateX = 0,
          translateY = 0,
          scaleX = 1,
          scaleY = 1,
          rotation = 0,
        },
      },
    },
  }
end

return M
