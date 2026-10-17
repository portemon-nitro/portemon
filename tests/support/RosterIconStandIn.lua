-- A roster icon provider over one generated 32x32 image, for graphics
-- tests that draw the Summary without preparing the real icon pages.
-- The provider keeps the production read surface: image, handleFor,
-- quadFor, and dimensions by icon key.

local RosterIconStandIn = {}

---@param scope table<string, unknown> graphics ownership scope that disposes the image
---@return table<string, unknown> provider
function RosterIconStandIn.new(scope)
  local data = love.image.newImageData(32, 32)
  data:mapPixel(function()
    return 0.2, 0.8, 0.2, 1
  end)
  local image = scope:own(love.graphics.newImage(data))
  local quad = love.graphics.newQuad(0, 0, 32, 32, 32, 32)
  local provider = {}
  function provider:image(_)
    return image
  end
  function provider:handleFor(_)
    return { image = image, kind = "rgba8", width = 32, height = 32 }
  end
  function provider:quadFor(_)
    return quad
  end
  function provider:dimensions(_)
    return { width = 32, height = 32 }
  end
  return provider
end

return RosterIconStandIn
