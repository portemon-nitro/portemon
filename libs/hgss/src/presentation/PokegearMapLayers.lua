-- Drawing pieces the region map and the Fly entry share: prepared image
-- lookup, compiled sprite frames, palette-colored window text, and the world
-- layer under its affine transform with its tile patches and highlight.
-- Pure presentation: the host graphics namespace arrives as an argument.

local PokegearAtlas = require("libs.hgss.src.presentation.PokegearAtlas")

---@class PokegearMapLayers
local PokegearMapLayers = {}

local HIGHLIGHT_ALPHA = 10 / 16

---@param images table<string, unknown> pooled atlas leases by generated path
---@param path unknown
---@return table<string, unknown> pooled atlas lease behind the plane
function PokegearMapLayers.imageAt(images, path)
  assert(type(path) == "string", "the map plan resolves its plane images")
  local lease = images[path]
  assert(lease ~= nil, "the map render needs its prepared plane image")
  return lease
end

-- Draws one frame of a compiled sprite sequence centred on a position.
---@param graphics love.graphics
---@param images table<string, unknown>
---@param sprites table<string, table<integer, table<string, unknown>>>
---@param set string
---@param sequence number one-based
---@param frame number one-based
---@param x number
---@param y number
---@param scale number?
function PokegearMapLayers.drawSprite(graphics, images, sprites, set, sequence, frame, x, y, scale)
  local clip = assert(sprites[set][sequence], "the map sprites carry their sequence")
  local info = assert(clip.frames[frame], "the map sprite carries its frame")
  local lease = PokegearMapLayers.imageAt(images, info.image)
  if scale ~= nil and scale ~= 1 then
    lease:draw(graphics, x + info.anchorX * scale, y + info.anchorY * scale, 0, scale, scale)
  else
    lease:draw(graphics, x + info.anchorX, y + info.anchorY)
  end
end

-- Selects the one-based animation frame for a compiled sprite sequence
-- at a fixed source tick: frames advance by their source durations and
-- loop, so focus indicators blink instead of sticking on their opening
-- frame. Single-frame sequences always resolve to frame one.
---@param sprites table<string, table<integer, table<string, unknown>>>? the compiled set
---@param set string
---@param sequence number one-based
---@param tick integer? the fixed source tick, defaulting to the opening frame
---@return integer one-based frame
function PokegearMapLayers.animationFrame(sprites, set, sequence, tick)
  if type(sprites) ~= "table" then
    return 1
  end
  local group = sprites[set]
  if type(group) ~= "table" then
    return 1
  end
  local clip = group[sequence]
  if type(clip) ~= "table" or type(clip.frames) ~= "table" or #clip.frames <= 1 then
    return 1
  end
  local frames = clip.frames --[[@as table[] ]]
  local total = 0
  for _, frame in ipairs(frames) do
    local record = frame --[[@as table<string, unknown>]]
    local duration = record.duration or record.durationTicks or 1
    if type(duration) ~= "number" or duration < 1 then
      duration = 1
    end
    total = total + duration
  end
  if total <= 1 then
    return 1
  end
  local elapsed = (tick or 0) % total
  for index, frame in ipairs(frames) do
    local record = frame --[[@as table<string, unknown>]]
    local duration = record.duration or record.durationTicks or 1
    if type(duration) ~= "number" or duration < 1 then
      duration = 1
    end
    if elapsed < duration then
      return index
    end
    elapsed = elapsed - duration
  end
  return #frames
end

---@param text table<string, unknown>?
---@param line string
---@param x number
---@param y number
---@param colors table<string, table<string, number>>
function PokegearMapLayers.printText(text, line, x, y, colors)
  if
    text == nil or type((text --[[@as table<string, unknown>]]).drawTextWithPalette) ~= "function"
  then
    return
  end
  local draw = (text --[[@as table<string, unknown>]]).drawTextWithPalette --[[@as fun(self: table, line: string, x: number, y: number, palette: table)]]
  local row = 0
  for piece in (line .. "\n"):gmatch("([^\n]*)\n") do
    draw(text, piece, x, y + row * 16, colors)
    row = row + 1
  end
end

-- The world layer under its affine transform: the base, the patches copied
-- over it, and the selection highlight blended above.
---@param graphics love.graphics
---@param images table<string, unknown>
---@param content table<string, unknown>
---@param view table<string, unknown>
function PokegearMapLayers.drawWorld(graphics, images, content, view)
  local world = view.world --[[@as table<string, number>]]
  local lease = PokegearMapLayers.imageAt(images, content.world)
  local r = world.ratio
  graphics.push()
  graphics.translate(
    -(world.scrollX + world.xOffset) - (r - 1) * world.affineX,
    -world.scrollY - (r - 1) * world.affineY
  )
  graphics.scale(r, r)
  graphics.setColor(1, 1, 1, 1)
  lease:draw(graphics, 0, 0)
  for _, patch in
    ipairs(view.patches --[[@as table[] ]])
  do
    PokegearAtlas.draw(
      graphics,
      lease,
      patch.srcX * 8,
      patch.srcY * 8,
      patch.width * 8,
      patch.height * 8,
      patch.destX * 8,
      patch.destY * 8
    )
  end
  graphics.setColor(1, 1, 1, HIGHLIGHT_ALPHA)
  for _, patch in
    ipairs(view.highlight --[[@as table[] ]])
  do
    PokegearAtlas.draw(
      graphics,
      lease,
      patch.srcX * 8,
      patch.srcY * 8,
      patch.width * 8,
      patch.height * 8,
      patch.destX * 8,
      patch.destY * 8
    )
  end
  graphics.setColor(1, 1, 1, 1)
  graphics.pop()
end

return PokegearMapLayers
