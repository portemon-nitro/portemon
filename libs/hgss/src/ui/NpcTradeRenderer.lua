-- The app71 trade sequence's drawing: the source layers of the scene the
-- sequence is playing, the mon pictures the scene shows, the Poke Ball model,
-- the effect-sheet sprites and light streaks, the source message window with
-- the bank-179 line that scene prints, and the two detached subjects' names in
-- the printed lines. Every pixel comes from the generated trade manifest and
-- the mon portrait family; every transform comes from the immutable snapshot,
-- so the renderer never loads an asset, advances a timer, or draws random
-- state.
--
-- Draw order follows the source scenes (trade_sequence_*.c): the scene's
-- background layers, then its pictures, then the 3D model, then the effect
-- sprites and streaks, then the message window. The depart/arrive map layer is
-- the source's 256-colour affine background, so it draws under its own affine
-- transform: the source reference point stays fixed and the scene's zoom scale
-- grows it (TradeSequence_StartBgZoom / TradeSequence_ApplyBgZoom), offset by
-- the scene's vertical scroll.
--
-- Two source facts the state cannot own live here: the send/receive pokepic is
-- anchored at the source's (height + 80) bottom-line convention, so this file
-- adds the generated per-selector picture height to the scene anchor; and the
-- link pulses recolor the affine layer's own palette slots white, so the
-- renderer composes a screen-space overlay from that layer's published palette
-- index plane whenever the walk holds a slot.
--
-- Retail sources (tmp/refs/pokeheartgold): src/application/trade_sequence/
-- trade_sequence_{send,depart,recede,exchange,approach,arrive,receive}.c.

local PokemonCareInterface = require("libs.hgss.src.ui.PokemonCareInterface")
local TradeBalloonModel = require("libs.hgss.src.presentation.TradeBalloonModel")

---@class NpcTradeRenderer
---@field private _graphics table<string, unknown>
---@field private _cacheFs table<string, unknown>? borrowed version cache reader
---@field private _manifest table<string, unknown>
---@field private _images table<string, table<string, unknown>>
---@field private _text table<string, unknown> borrowed field text renderer
---@field private _window table<string, unknown>? borrowed window frame renderer
---@field private _frameIndex integer? the player's selected window frame
---@field private _pictures table<string, table<string, unknown>>? per-subject portrait records
---@field private _balloon table<string, unknown>? the realized Poke Ball model
---@field private _quads table<string, table<string, unknown>> per-page picture quads
---@field private _indexPlanes table<string, string> staged palette-index planes by path
---@field private _pulseOverlayImage table<string, unknown>? screen-space pulse overlay
---@field private _pulseOverlayData table<string, unknown>? its reusable pixel buffer
---@field private _pulseOverlayKey string? the walk and transform the overlay holds
local NpcTradeRenderer = {}
NpcTradeRenderer.__index = NpcTradeRenderer

-- The sequence's reference frame on the main screen.
NpcTradeRenderer.REFERENCE_WIDTH = 256
NpcTradeRenderer.REFERENCE_HEIGHT = 192
-- TradeSequence_ApplyBgZoom keeps x 128 fixed and takes y from
-- sTradeSequenceBgZoomCenterY, which each scene names.
NpcTradeRenderer.AFFINE_CENTER_X = 128

-- The trade window prints its lines with the field's default ink on the
-- generated window fill; the sequence sets one text colour for the whole scene.
local TRADE_TEXT_PALETTE = {
  foreground = { r = 248, g = 248, b = 248, a = 255 },
  shadow = { r = 88, g = 88, b = 88, a = 255 },
  background = { r = 0, g = 0, b = 0, a = 255 },
}

---@param opts { graphics: table<string, unknown>, cacheFs: table<string, unknown>?, imageAssets: table<string, unknown>?, manifest: table<string, unknown>, images: table<string, table<string, unknown>>, pictures: table<string, table<string, unknown>>?, text: table<string, unknown>, window: table<string, unknown>?, frameIndex: integer? }
---@return NpcTradeRenderer
function NpcTradeRenderer.new(opts)
  assert(type(opts) == "table", "the trade renderer requires its options")
  local graphics = assert(opts.graphics, "the trade renderer requires the graphics namespace")
  assert(type(graphics.draw) == "function", "the trade renderer draws through the graphics namespace")
  local manifest = assert(opts.manifest, "the trade renderer requires the generated manifest")
  local images = assert(opts.images, "the trade renderer requires its realized images")
  local text = assert(opts.text, "the trade renderer borrows the field text renderer")
  assert(type(text.drawTextWithPalette) == "function", "the trade renderer requires the shared field text renderer")
  local window = opts.window
  if window ~= nil then
    assert(type(window.drawWindow) == "function", "the trade renderer borrows a framed window renderer")
  end
  local balloon = nil
  if opts.cacheFs ~= nil then
    local model = assert(assert(manifest.balloon, "the trade manifest carries its balloon") --[[@as table]]).model
    balloon = TradeBalloonModel.new({
      graphics = graphics,
      cacheFs = opts.cacheFs,
      imageAssets = assert(opts.imageAssets, "the trade balloon model borrows the session image owner"),
      model = assert(model --[[@as table<string, unknown>]]),
    })
  end
  return setmetatable({
    _graphics = graphics,
    _cacheFs = opts.cacheFs,
    _manifest = manifest,
    _images = images,
    _pictures = opts.pictures,
    _balloon = balloon,
    _quads = {},
    _indexPlanes = {},
    _pulseOverlayImage = nil,
    _pulseOverlayData = nil,
    _pulseOverlayKey = nil,
    _text = text,
    _window = window,
    _frameIndex = opts.frameIndex,
  }, NpcTradeRenderer)
end

---@param path string
---@return table<string, unknown>
function NpcTradeRenderer:_image(path)
  local image = self._images[path]
  assert(image ~= nil, "the trade scene image is not realized: " .. tostring(path))
  return image
end

-- The active scene's source layers.
---@param status PokemonCareTradeStatus
---@return table[]
function NpcTradeRenderer:_layers(status)
  local scenes = assert(self._manifest.scenes, "the trade manifest carries its scenes") --[[@as table]]
  local scene = assert(scenes[status.phase], "the trade phase names its source scene") --[[@as table]]
  return assert(scene.layers, "the trade scene carries its layers") --[[@as table[] ]]
end

-- One layer's surface for the snapshot's time-of-day bank.
---@param layer table<string, unknown>
---@param status PokemonCareTradeStatus
---@return table<string, unknown>
local function surfaceFor(layer, status)
  if layer.variants == nil then
    return layer
  end
  local variants = layer.variants --[[@as table]]
  local key = assert(status.backdrop, "a layered surface names its time-of-day bank")
  return assert(variants[key], "the layered surface carries its " .. key .. " bank") --[[@as table]]
end

-- Draws one layer. The affine map layer keeps the source reference point fixed
-- and scales around it; every text layer draws at its own origin.
---@param layer table<string, unknown>
---@param status PokemonCareTradeStatus
function NpcTradeRenderer:_drawLayer(layer, status)
  local lg = assert(self._graphics)
  local surface = surfaceFor(layer, status)
  local image = self:_image(assert(surface.image --[[@as string]]))
  lg.setColor(1, 1, 1, 1)
  if layer.affine ~= true then
    lg.draw(image, 0, 0)
    return
  end
  local zoom = assert(status.bgZoom, "the affine layer reads the scene's zoom scale")
  local centerX = NpcTradeRenderer.AFFINE_CENTER_X
  local centerY = assert(status.bgZoomCenterY, "the affine layer reads the scene's reference point")
  lg.push("all")
  lg.setScissor(0, 0, NpcTradeRenderer.REFERENCE_WIDTH, NpcTradeRenderer.REFERENCE_HEIGHT)
  lg.draw(image, centerX - centerX * zoom, centerY - centerY * zoom + status.bgScrollY, 0, zoom, zoom)
  lg.pop()
end

-- One compiled frame of a sheet sequence at the snapshot's tick. The source
-- sprites animate continuously at one frame per tick (Sprite_SetAnimSpeed
-- FX32_ONE with the animation active), so the sequence loops over its own
-- per-frame durations.
---@param sequence table<string, unknown>
---@param tick integer
---@return table<string, unknown> frame
local function frameAt(sequence, tick)
  local frames = assert(sequence.frames, "a trade sprite sequence carries its frames") --[[@as table[] ]]
  local total = 0
  for _, frame in ipairs(frames) do
    total = total + assert(frame.durationTicks --[[@as integer]])
  end
  assert(total > 0, "a trade sprite sequence lasts at least one tick")
  local remaining = tick % total
  for _, frame in ipairs(frames) do
    local duration = assert(frame.durationTicks --[[@as integer]])
    if remaining < duration then
      return frame
    end
    remaining = remaining - duration
  end
  return assert(frames[#frames], "a looping sequence lands on a frame")
end

-- The effect sheet's sequences by source sequence index.
---@return table<integer, table<string, unknown>>
function NpcTradeRenderer:_sequences()
  local sprites = assert(self._manifest.sprites, "the trade manifest carries its sprite sheets") --[[@as table]]
  local sheet = assert(sprites.effect, "the trade manifest carries its effect sheet") --[[@as table]]
  local bySequence = {}
  for _, sequence in
    ipairs(assert(sheet.sequences, "the effect sheet carries its sequences") --[[@as table[] ]])
  do
    bySequence[
      assert(sequence.sequence --[[@as integer]])
    ] = sequence
  end
  return bySequence
end

-- Draws the scene's effect sprites in the snapshot's own draw order.
---@param status PokemonCareTradeStatus
function NpcTradeRenderer:_drawSprites(status)
  if #status.sprites == 0 then
    return
  end
  local lg = assert(self._graphics)
  local sequences = self:_sequences()
  lg.setColor(1, 1, 1, 1)
  for _, sprite in ipairs(status.sprites) do
    local sequence = sequences[sprite.sequence]
    assert(sequence ~= nil, "the effect sheet carries sequence " .. tostring(sprite.sequence))
    local frame = frameAt(assert(sequence --[[@as table<string, unknown>]]), sprite.tick)
    if frame.blank ~= true then
      local image = self:_image(assert(frame.image --[[@as string]]))
      -- The source positions a sprite by its cell centre, so the rasterized
      -- frame is drawn centred on the origin the scene created it with.
      lg.draw(image, sprite.x - image:getWidth() / 2, sprite.y - image:getHeight() / 2)
    end
  end
end

-- One mon picture: the portrait page the subject's selector belongs to, its
-- staged frame rectangle and the source's front picture height. The send and
-- receive scenes anchor a pokepic at the source's (height + 80) bottom line;
-- the exchange scene's two pictures ride the background tilemap rows and take
-- no height offset.
---@param subject string "outgoing" or "incoming"
---@param phase string the snapshot's scene
---@return table<string, unknown>? record { image, quad, height }
function NpcTradeRenderer:_pictureRecord(subject, phase)
  local records = self._pictures
  if records == nil then
    return nil
  end
  local record = records[subject]
  if record == nil then
    return nil
  end
  local pagePath = assert(record.page --[[@as string]])
  local image = self:_image(pagePath)
  local frame = assert(record.frame, "a trade picture record carries its frame") --[[@as table]]
  local key = pagePath .. "#" .. tostring(frame.x) .. ":" .. tostring(frame.y)
  local quad = self._quads[key]
  if quad == nil then
    local graphics = assert(self._graphics)
    assert(type(graphics.newQuad) == "function", "the trade renderer builds picture quads")
    quad = graphics.newQuad(frame.x, frame.y, frame.width, frame.height, image:getWidth(), image:getHeight())
    self._quads[key] = quad
  end
  local height = phase == PokemonCareInterface.TRADE_PHASES.EXCHANGE and 0 or assert(record.height --[[@as integer]])
  return { image = image, quad = quad, height = height, width = frame.width, heightPixels = frame.height }
end

-- Draws the scene's mon pictures in the snapshot's own order.
---@param status PokemonCareTradeStatus
function NpcTradeRenderer:_drawPictures(status)
  if #status.pictures == 0 then
    return
  end
  local lg = assert(self._graphics)
  lg.setColor(1, 1, 1, 1)
  for _, picture in ipairs(status.pictures) do
    if picture.visible then
      local record = self:_pictureRecord(picture.subject, status.phase)
      if record ~= nil then
        -- The picture's source anchor is its centre (NNS_G2dDrawSpriteFast
        -- with xCenter - 40), so the frame draws around it.
        local width = assert(record.width --[[@as integer]])
        local height = assert(record.heightPixels --[[@as integer]])
        local x = picture.x - width / 2
        local y = picture.y - height / 2 + record.height --[[@as integer]]
        lg.draw(record.image --[[@as table]], record.quad --[[@as table]], x, y)
      end
    end
  end
end

-- Draws the depart scene's falling light streaks from the shared sheet: the
-- head runs sequence 0 and its tail sequence 1, both at the source's own
-- positions.
---@param status PokemonCareTradeStatus
function NpcTradeRenderer:_drawStreaks(status)
  local streaks = status.streaks
  if #streaks == 0 then
    return
  end
  local lg = assert(self._graphics)
  local sequences = self:_sequences()
  local head = sequences[0]
  local tail = sequences[1]
  assert(head ~= nil and tail ~= nil, "the effect sheet carries the streak sequences")
  lg.setColor(1, 1, 1, 1)
  for _, streak in ipairs(streaks) do
    local headFrame = frameAt(assert(head --[[@as table<string, unknown>]]), streak.tick)
    if headFrame.blank ~= true then
      local image = self:_image(assert(headFrame.image --[[@as string]]))
      lg.draw(image, streak.x - image:getWidth() / 2, streak.headY - image:getHeight() / 2)
    end
    local tailFrame = frameAt(assert(tail --[[@as table<string, unknown>]]), streak.tick)
    if tailFrame.blank ~= true then
      local image = self:_image(assert(tailFrame.image --[[@as string]]))
      lg.draw(image, streak.x - image:getWidth() / 2, streak.tailY - image:getHeight() / 2)
    end
  end
end

-- The pulse overlay palette is white, and the source's slot 0 is the
-- transparency slot a background never draws, so a pulse on slot 0 paints
-- nothing (the state still publishes it: the walk is the source's).
local PULSE_WHITE = { 1, 1, 1, 1 }

-- One affine layer's staged palette-index plane, read once and kept as bytes.
---@param path string staged index-plane path
---@return string
function NpcTradeRenderer:_indexPlane(path)
  local planes = self._indexPlanes
  local cached = planes[path]
  if cached ~= nil then
    return cached
  end
  local cacheFs = assert(self._cacheFs, "the trade pulses read their staged index plane")
  local bytes = assert(cacheFs:read(path), "the trade index plane is missing: " .. tostring(path))
  planes[path] = bytes
  return bytes
end

-- Composes the pulse overlay for one snapshot: a screen-space RGBA image where
-- only the affine layer's pixels whose palette index the walk currently holds
-- white are opaque white, derived from the published index plane and the
-- snapshot's walk under the layer's own zoom/scroll transform. The image is
-- rebuilt only when the walk or the transform changes.
---@param layer table<string, unknown>
---@param surface table<string, unknown>
---@param status PokemonCareTradeStatus
---@return table<string, unknown> overlay image
function NpcTradeRenderer:_pulseOverlay(layer, surface, status)
  local path = assert(layer.indices --[[@as string]], "an affine layer carries its index plane")
  local zoom = assert(status.bgZoom, "the affine layer reads the scene's zoom scale")
  local centerX = NpcTradeRenderer.AFFINE_CENTER_X
  local centerY = assert(status.bgZoomCenterY, "the affine layer reads the scene's reference point")
  local scrollY = status.bgScrollY
  local key = table.concat(status.pulses, ",")
    .. "|"
    .. tostring(zoom)
    .. "|"
    .. tostring(scrollY)
    .. "|"
    .. tostring(centerY)
    .. "|"
    .. path
  if self._pulseOverlayImage ~= nil and self._pulseOverlayKey == key then
    return self._pulseOverlayImage
  end
  local graphics = assert(self._graphics)
  local white = {}
  for _, slot in ipairs(status.pulses) do
    if slot ~= 0 then
      white[slot] = true
    end
  end
  local plane = self:_indexPlane(path)
  local planeWidth = assert(surface.width --[[@as integer]])
  local planeHeight = assert(surface.height --[[@as integer]])
  assert(#plane == planeWidth * planeHeight, "a trade index plane matches its surface dimensions")
  local width = NpcTradeRenderer.REFERENCE_WIDTH
  local height = NpcTradeRenderer.REFERENCE_HEIGHT
  local data = self._pulseOverlayData
  if data == nil then
    data = love.image.newImageData(width, height, "rgba8")
    self._pulseOverlayData = data
  end
  local offsetX = centerX - centerX * zoom
  local offsetY = centerY - centerY * zoom + scrollY
  for screenY = 0, height - 1 do
    local sourceY = math.floor((screenY - offsetY) / zoom + 0.5)
    local rowBase = sourceY * planeWidth
    local inRow = sourceY >= 0 and sourceY < planeHeight
    for screenX = 0, width - 1 do
      local sourceX = math.floor((screenX - offsetX) / zoom + 0.5)
      local opaque = false
      if inRow and sourceX >= 0 and sourceX < planeWidth then
        local index = string.byte(plane, rowBase + sourceX + 1) or 0
        opaque = white[index] == true
      end
      if opaque then
        data:setPixel(screenX, screenY, PULSE_WHITE[1], PULSE_WHITE[2], PULSE_WHITE[3], PULSE_WHITE[4])
      else
        data:setPixel(screenX, screenY, 0, 0, 0, 0)
      end
    end
  end
  if self._pulseOverlayImage == nil then
    self._pulseOverlayImage = graphics.newImage(data)
    self._pulseOverlayImage:setFilter("nearest", "nearest")
  else
    self._pulseOverlayImage:replacePixels(data)
  end
  self._pulseOverlayKey = key
  return self._pulseOverlayImage
end

-- Draws the source's link pulses over the affine layer they walk.
---@param layer table<string, unknown>
---@param status PokemonCareTradeStatus
function NpcTradeRenderer:_drawPulses(layer, status)
  if layer.affine ~= true or #status.pulses == 0 then
    return
  end
  local overlay = self:_pulseOverlay(layer, surfaceFor(layer, status), status)
  local lg = assert(self._graphics)
  lg.push("all")
  lg.setScissor(0, 0, NpcTradeRenderer.REFERENCE_WIDTH, NpcTradeRenderer.REFERENCE_HEIGHT)
  lg.setColor(1, 1, 1, 1)
  lg.draw(overlay, 0, 0)
  lg.pop()
end

-- Draws the Poke Ball model for the snapshot's placement and scene camera.
---@param status PokemonCareTradeStatus
function NpcTradeRenderer:_drawBalloon(status)
  local balloon = status.balloon
  if balloon == nil then
    return
  end
  local camera = assert(status.camera, "a drawn model carries its scene camera")
  assert(self._balloon, "the trade renderer realized its Poke Ball model"):draw(balloon, camera)
end

-- The compiled line for one bank-179 index, with the source message-format
-- buffers filled from the two detached subjects and the trade profile name.
---@param messageId integer
---@param status PokemonCareTradeStatus
---@param playerName string
---@return string?
function NpcTradeRenderer:lineText(messageId, status, playerName)
  local messages = assert(self._manifest.messages, "the trade manifest carries its lines") --[[@as table]]
  for _, key in ipairs({ "send", "farewell", "received", "takeCare" }) do
    local line = assert(messages[key], "the trade manifest carries " .. key) --[[@as table]]
    if line.id == messageId then
      local text = assert(line.text --[[@as string]])
      text = text:gsub("{sent}", status.outgoing.nickname)
      text = text:gsub("{received}", status.incoming.nickname)
      return (text:gsub("{player}", playerName))
    end
  end
  return nil
end

-- Draws one immutable snapshot of the trade sequence at native 256x192
-- reference coordinates. The caller owns the pane transform and the graphics
-- state.
---@param status PokemonCareTradeStatus
---@param playerName string the trade OT the source buffers by name
function NpcTradeRenderer:draw(status, playerName)
  local lg = assert(self._graphics)
  for _, layer in ipairs(self:_layers(status)) do
    self:_drawLayer(layer, status)
    self:_drawPulses(layer, status)
  end
  self:_drawPictures(status)
  self:_drawBalloon(status)
  self:_drawSprites(status)
  self:_drawStreaks(status)

  local window = self._window
  if window ~= nil then
    local spec = assert(self._manifest.window, "the trade manifest carries its window") --[[@as table]]
    local box = {
      x = assert(spec.x) --[[@as number]],
      y = assert(spec.y) --[[@as number]],
      width = assert(spec.width) --[[@as number]],
      height = assert(spec.height) --[[@as number]],
    }
    window:drawWindow(box, self._frameIndex, self._text:windowBackgroundColor())
    local messageId = status.messageId
    if messageId ~= nil then
      local line = self:lineText(messageId, status, playerName)
      if line ~= nil then
        self._text:drawTextWithPalette(line, box.x + 4, box.y + 2, TRADE_TEXT_PALETTE)
      end
    end
  end
  lg.setColor(1, 1, 1, 1)
end

-- Releases the Poke Ball model's own GPU resources; the realized images, the
-- field text renderer and the framed window renderer belong to the field
-- presentation that created them.
function NpcTradeRenderer:release()
  if self._balloon ~= nil then
    self._balloon:release()
    self._balloon = nil
  end
  if self._pulseOverlayImage ~= nil then
    self._pulseOverlayImage:release()
    self._pulseOverlayImage = nil
    self._pulseOverlayData = nil
    self._pulseOverlayKey = nil
  end
  self._indexPlanes = {}
  self._quads = {}
end

return NpcTradeRenderer
