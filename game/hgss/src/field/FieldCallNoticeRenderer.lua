-- Paints the incoming-call notice over the live field at the canonical
-- 256x192 MAIN surface: the touchscreen menu's Pokegear icon playing the
-- shared source ringing animation, and the source caller window beside it,
-- which is a green speech bubble with the caller's name printed on it. The
-- bubble is the compiled source nine-slice: a three-tile cap carrying the
-- phone art and the tail that points at the gear icon, a body edge that
-- repeats across the name width, and a one-tile right edge. The name width
-- is the source formula `floor(fontWidth / 8) + 2` capped at the compiled
-- maximum, so the bubble always fits the caller name. Placement and the
-- single logical transform come from the shared PixelScale/LogicalSurface
-- primitives; the renderer resolves no caller or ring policy and owns only
-- the generated art it borrows.

local LogicalSurface = require("libs.ui.src.LogicalSurface")
local PixelScale = require("libs.ui.src.PixelScale")

---@class FieldCallNoticeRenderer.Color
---@field r integer
---@field g integer
---@field b integer
---@field a integer

---@class FieldCallNoticeRenderer
---@field _graphics love.graphics
---@field _text FieldTextRenderer
---@field _window { tileLeft: integer, top: integer, height: integer, maxWidth: integer }
---@field _gear { x: number, y: number }
---@field _ringingAsset string
---@field _ringingQuads love.Quad[]
---@field _ringingOffsets { x: number, y: number }[]
---@field _ringingDurations integer[]
---@field _ringingPrefixTicks integer source ticks before the loop point
---@field _ringingLoopTicks integer source ticks of the looped tail
---@field _loopStartFrame integer one-based first looped frame
---@field _bubbleAsset string
---@field _bubbleQuads { left: love.Quad, right: love.Quad, top: love.Quad, bottom: love.Quad }
---@field _plate FieldCallNoticeRenderer.Color
---@field _name { foreground: FieldCallNoticeRenderer.Color, shadow: FieldCallNoticeRenderer.Color }
---@field _pool table<string, unknown>? the borrowed shared image owner; nil keeps eager construction
---@field _images love.Image[] every acquired image, released exactly once
---@field _imageByAsset table<string, love.Image>
---@field _leases table<integer, table<string, unknown>>?
---@field _leaseByAsset table<string, table<string, unknown>>?
local FieldCallNoticeRenderer = {}
FieldCallNoticeRenderer.__index = FieldCallNoticeRenderer

FieldCallNoticeRenderer.REFERENCE_WIDTH = 256
FieldCallNoticeRenderer.REFERENCE_HEIGHT = 192
-- The source prints the caller name three pixels into the window.
local TEXT_INSET = 3
-- The source frame is drawn around the window: three cap columns and one
-- right column, one row above and one row below the two-tile window.
local CAP_TILES = 3
-- Every notice visual samples point-filtered and clamped, matching the
-- eager construction, so pooled leases draw identically.
local POOLED_SAMPLER = { wrapX = "clamp", wrapY = "clamp", minFilter = "nearest", magFilter = "nearest" }

---@param color FieldCallNoticeRenderer.Color
---@return number red
---@return number green
---@return number blue
local function rgb(color)
  return color.r / 255, color.g / 255, color.b / 255
end

-- Borrows one manifest atlas, either from the shared image owner or from the
-- version-scoped cache, and installs it under its asset id. Pooled
-- acquisitions keep their lease for release and draw through the exact
-- sampler.
---@param self FieldCallNoticeRenderer
---@param cacheFs CacheFs
---@param manifest table<string, unknown>
---@param assetId string
---@return love.Image
local function acquireAtlas(self, cacheFs, manifest, assetId)
  local existing = self._imageByAsset[assetId]
  if existing ~= nil then
    return existing
  end
  local entry = assert(manifest.assets[assetId], "the field-UI manifest must index " .. assetId)
  local path = assert(entry.image, "the field-UI manifest must name the " .. assetId .. " image")
  local graphics = assert(self._graphics)
  local image
  local pool = self._pool
  if pool ~= nil then
    local token = pool:request(path, POOLED_SAMPLER, "demand")
    local stalled = 0
    while true do
      local status, failure = pool:poll(token)
      if status == "ready" then
        local lease = pool:acquire(token)
        self._images[#self._images + 1] = assert(lease.image, "shared leases carry their resolved image")
        local leases = assert(self._leases, "pooled chrome tracks its installed leases")
        leases[#leases + 1] = lease
        local byAsset = assert(self._leaseByAsset, "pooled chrome tracks its leases by asset")
        byAsset[assetId] = lease
        image = assert(lease.image)
        break
      end
      if status == "failed" then
        error("missing generated field-UI image " .. path .. ": " .. tostring(failure), 0)
      end
      assert(status == "pending", "field-UI preparation reports pending or ready")
      stalled = stalled + 1
      if stalled > 10000 then
        error("stalled generated field-UI image " .. path, 0)
      end
      local timer = love and love.timer
      if timer ~= nil and timer.sleep ~= nil then
        timer.sleep(0.001)
      end
    end
  else
    local data = cacheFs:read(path)
    if data == nil then
      error("missing generated field-UI image at " .. path, 0)
    end
    image = graphics.newImage(love.filesystem.newFileData(data, path))
    self._images[#self._images + 1] = image
  end
  assert(image ~= nil, "the field-UI atlas resolves an image")
  image:setFilter("nearest", "nearest")
  self._imageByAsset[assetId] = image
  return image
end

-- One compiled ringing animation as installed quads, offsets, and source-tick
-- durations. The loop point splits the opening frames from the repeated tail,
-- so the shared forward-loop playback mode stays faithful.
---@param self FieldCallNoticeRenderer
---@param record table<string, unknown>
---@param image love.Image
---@param assetId string
local function installRinging(self, record, image, assetId)
  local frames = assert(record.frames, "the compiled ringing animation must carry its frames")
  assert(#frames > 0, "the compiled ringing animation must carry at least one frame")
  local loopStart = assert(record.loopStartFrameIdx, "the compiled ringing animation must carry its loop start")
  assert(
    type(loopStart) == "number" and loopStart % 1 == 0 and loopStart >= 0 and loopStart < #frames,
    "the compiled ringing loop start must address a frame"
  )
  assert(record.playMode == "forward_loop", "the caller notice plays the compiled forward-loop animation")
  local graphics = assert(self._graphics)
  local width, height = image:getWidth(), image:getHeight()
  local quads, offsets, durations = {}, {}, {}
  local prefixTicks, loopTicks = 0, 0
  for index, frame in ipairs(frames) do
    local rect = assert(frame.rect, "a compiled ringing frame must carry its rect")
    quads[index] = graphics.newQuad(rect.x, rect.y, rect.width, rect.height, width, height)
    offsets[index] = assert(frame.offset, "a compiled ringing frame must carry its offset")
    local duration = assert(frame.duration, "a compiled ringing frame must carry its duration")
    assert(type(duration) == "number" and duration % 1 == 0 and duration >= 1, "frame durations are positive ticks")
    durations[index] = duration
    if index <= loopStart then
      prefixTicks = prefixTicks + duration
    else
      loopTicks = loopTicks + duration
    end
  end
  assert(loopTicks > 0, "the compiled ringing loop must advance")
  self._ringingAsset = assetId
  self._ringingQuads = quads
  self._ringingOffsets = offsets
  self._ringingDurations = durations
  self._ringingPrefixTicks = prefixTicks
  self._ringingLoopTicks = loopTicks
  self._loopStartFrame = loopStart + 1
end

---@param opts { cacheFs: CacheFs, manifest: table<string, unknown>, text: FieldTextRenderer, graphics?: love.graphics, imagePool?: table<string, unknown> }
---@return FieldCallNoticeRenderer
function FieldCallNoticeRenderer.new(opts)
  assert(
    type(opts) == "table" and opts.cacheFs and opts.cacheFs.read,
    "FieldCallNoticeRenderer requires a CacheFs-shaped object"
  )
  local graphics = opts.graphics
  if graphics == nil then
    graphics = love and love.graphics
  end
  assert(graphics and graphics.newQuad, "FieldCallNoticeRenderer requires love.graphics")
  local text = opts.text
  assert(
    text and type(text.textWidth) == "function" and type(text.drawTextWithPalette) == "function",
    "FieldCallNoticeRenderer requires the shared text collaborator"
  )
  local manifest = opts.manifest
  assert(type(manifest) == "table", "FieldCallNoticeRenderer requires the validated field-UI manifest")
  local startMenu = assert(manifest.startMenu, "the field-UI manifest must carry the start menu section")
  local notification =
    assert(startMenu.phoneNotification, "the field-UI manifest must carry the incoming-call notification projection")
  local window = assert(notification.window, "the incoming call must carry its source window")
  local ringing = assert(notification.ringing, "the incoming call must carry its ringing animation")
  local bubble = assert(notification.bubble, "the incoming call must carry its caller bubble")
  local actionIcons = assert(startMenu.actionIcons, "the start menu must map its actions to icon rows")
  local interactive = assert(startMenu.interactive, "the start menu must carry its interactive positions")
  local gearIndex =
    assert(actionIcons["vanilla.pokegear"], "the start menu must map the Pokegear action to its ringing icon")
  local gearPosition =
    assert(interactive.positions[gearIndex], "the Pokegear ringing icon must carry its source position")
  local pool = opts.imagePool
  local self = setmetatable({
    _graphics = graphics,
    _text = text,
    _window = window,
    _gear = assert(gearPosition.anchor, "the Pokegear position must carry its source anchor"),
    _bubbleAsset = assert(bubble.asset, "the caller bubble must name its asset"),
    _plate = assert(bubble.plate, "the caller bubble must carry its plate color"),
    _name = assert(bubble.name, "the caller bubble must carry its name colors"),
    _pool = pool,
    _images = {},
    _imageByAsset = {},
    _leases = pool ~= nil and {} or nil,
    _leaseByAsset = pool ~= nil and {} or nil,
  }, FieldCallNoticeRenderer)
  local ok, err = pcall(function()
    local ringingImage = acquireAtlas(self, opts.cacheFs, manifest, assert(ringing.asset))
    installRinging(self, ringing, ringingImage, assert(ringing.asset))
    local bubbleImage = acquireAtlas(self, opts.cacheFs, manifest, self._bubbleAsset)
    local width, height = bubbleImage:getWidth(), bubbleImage:getHeight()
    local quads = {}
    for _, key in ipairs({ "left", "right", "top", "bottom" }) do
      local slice = assert(bubble[key], "the caller bubble must carry its " .. key .. " slice")
      local rect = assert(slice.rect, "the caller bubble " .. key .. " slice must carry its rect")
      quads[key] = graphics.newQuad(rect.x, rect.y, rect.width, rect.height, width, height)
    end
    self._bubbleQuads = quads
  end)
  if not ok then
    self:release()
    error(err)
  end
  return self
end

-- The frame index covering one elapsed source tick: opening frames play once,
-- then the tail loops from the compiled loop point.
---@param self FieldCallNoticeRenderer
---@param tick integer
---@return integer
function FieldCallNoticeRenderer:_frameAt(tick)
  local durations = assert(self._ringingDurations)
  local loopStart = assert(self._loopStartFrame)
  local prefix = assert(self._ringingPrefixTicks)
  local function cover(first, last, remaining)
    for index = first, last do
      local duration = assert(durations[index])
      if remaining < duration then
        return index
      end
      remaining = remaining - duration
    end
    return last
  end
  local elapsed = math.max(tick, 0)
  if elapsed < prefix then
    return cover(1, loopStart - 1, elapsed)
  end
  return cover(loopStart, #durations, (elapsed - prefix) % assert(self._ringingLoopTicks))
end

-- The source caller window width for one name: the field font advance
-- converted to whole tiles plus the window's two extra columns, capped at the
-- compiled maximum.
---@param self FieldCallNoticeRenderer
---@param name string
---@return integer
function FieldCallNoticeRenderer:windowWidth(name)
  local tiles = math.floor(self._text:textWidth(name) / 8) + 2
  if tiles > self._window.maxWidth then
    tiles = self._window.maxWidth
  end
  return tiles
end

-- Draws one compiled slice through the exact sampler when the atlas is a
-- pooled borrow, else the unchanged eager draw.
---@param self FieldCallNoticeRenderer
---@param assetId string
---@param quad love.Quad
---@param x number
---@param y number
function FieldCallNoticeRenderer:_drawSlice(assetId, quad, x, y)
  local graphics = assert(self._graphics)
  local image = assert(self._imageByAsset[assetId], "a drawn slice must be acquired")
  local lease = self._leaseByAsset ~= nil and self._leaseByAsset[assetId] or nil
  if lease ~= nil then
    lease:drawQuad(graphics, quad, x, y)
    return
  end
  graphics.draw(image, quad, x, y)
end

-- Draws the caller bubble for one name at its source geometry: the plate
-- fills the window, the compiled cap and edges paint the source frame, and
-- the name prints three pixels into the plate through the window's own text
-- colour roles.
---@param self FieldCallNoticeRenderer
---@param name string
function FieldCallNoticeRenderer:_drawBubble(name)
  local graphics = assert(self._graphics)
  local window = self._window
  local tile = 8
  local width = self:windowWidth(name)
  local originX = (window.tileLeft - CAP_TILES) * tile
  local originY = (window.top - 1) * tile
  local bodyX = window.tileLeft * tile
  local bodyWidth = width * tile
  local plate = self._plate
  local plateR, plateG, plateB = rgb(plate)
  graphics.setColor(plateR, plateG, plateB, 1)
  graphics.rectangle("fill", bodyX, originY + tile, bodyWidth, window.height * tile)
  graphics.setColor(1, 1, 1, 1)
  local quads = assert(self._bubbleQuads)
  self:_drawSlice(self._bubbleAsset, quads.left, originX, originY)
  self:_drawSlice(self._bubbleAsset, quads.right, bodyX + bodyWidth, originY)
  for column = 0, width - 1 do
    local columnX = bodyX + column * tile
    self:_drawSlice(self._bubbleAsset, quads.top, columnX, originY)
    self:_drawSlice(self._bubbleAsset, quads.bottom, columnX, originY + window.height * tile + tile)
  end
  local nameColors = self._name
  -- The source text printer clips every glyph to the window pixel buffer, so
  -- a name wider than the capped window stops at the bubble edge instead of
  -- painting over the host surface.
  LogicalSurface.clip(
    graphics,
    { x = bodyX, y = originY + tile, width = bodyWidth, height = window.height * tile },
    function()
      self._text:drawTextWithPalette(name, bodyX + TEXT_INSET, originY + tile, {
        foreground = nameColors.foreground,
        shadow = nameColors.shadow,
        background = { r = plate.r, g = plate.g, b = plate.b, a = 0 },
      })
    end
  )
end

-- Draws the ringing icon at its source anchor plus the compiled frame offset,
-- so the ring sway stays relative to the icon.
---@param self FieldCallNoticeRenderer
---@param tick integer
function FieldCallNoticeRenderer:_drawRing(tick)
  local index = self:_frameAt(tick)
  local offset = assert(self._ringingOffsets[index])
  self:_drawSlice(
    self._ringingAsset,
    assert(self._ringingQuads[index]),
    self._gear.x + offset.x,
    self._gear.y + offset.y
  )
end

-- Draws one ringing notice into the MAIN reference frame: the gear icon then
-- the caller bubble, both at their source coordinates.
---@param notice { name: string }
---@param tick integer elapsed source ticks since the ring began
---@param referenceFrame LayoutGeometry.Rect
function FieldCallNoticeRenderer:draw(notice, tick, referenceFrame)
  assert(type(notice) == "table" and type(notice.name) == "string", "a caller notice names its caller")
  assert(type(tick) == "number" and tick % 1 == 0, "the caller notice advances on whole source ticks")
  local placement = PixelScale.placeFixed(
    referenceFrame,
    FieldCallNoticeRenderer.REFERENCE_WIDTH,
    FieldCallNoticeRenderer.REFERENCE_HEIGHT
  )
  if placement == nil then
    return
  end
  local graphics = assert(self._graphics)
  LogicalSurface.draw(graphics, placement, function()
    graphics.setColor(1, 1, 1, 1)
    self:_drawRing(tick)
    self:_drawBubble(notice.name)
  end)
end

-- Releases every acquired image or installed lease exactly once.
function FieldCallNoticeRenderer:release()
  local pool = self._pool
  local leases = self._leases
  self._leases = nil
  self._leaseByAsset = nil
  self._pool = nil
  if pool ~= nil then
    for _, lease in ipairs(leases or {}) do
      pool:release(lease)
    end
  else
    for _, image in ipairs(self._images) do
      if image.release then
        image:release()
      end
    end
  end
  self._images = {}
  self._imageByAsset = {}
  self._bubbleQuads = nil
  self._ringingQuads = nil
  self._ringingOffsets = nil
  self._ringingDurations = nil
end

return FieldCallNoticeRenderer
