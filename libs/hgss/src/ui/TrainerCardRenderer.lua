-- Renders the authentic HGSS Trainer Card front through one resolved
-- logical placement: the generated card art (the manifest's
-- `hgss.trainer_card.front` asset at its front rect) plus the audited front
-- text layout from the retail ROM — the front windows created from the
-- template table (8px/tile) and the label/value prints of the
-- source function. The front labels ("ID No.", "NAME", "MONEY", "SCORE",
-- "TIME", "ADVENTURE STARTED") are the fixed card layout (msgdata bank 727
-- messages 0..6); the player name is right-aligned to x=240 and the trainer
-- id (five digits, zero-padded per the source's String16_FormatInteger)
-- right-aligned to x=112 on the y=24 row. The presentation carries only the
-- implemented profile fields (name, trainerId), so the label rows
-- for values gameplay does not own stay empty and the source-gated POKéDEX
-- row is not drawn at all: nothing is fabricated. Text draws through the
-- shared FieldTextRenderer (owned by FieldState); this renderer owns only
-- the card front image. Construction is failure-safe: a missing card front
-- is a typed error, a quad failure after the image was created releases it
-- before rethrowing, and draw() restores every graphics state it touches.
-- The runtime-validated manifest is injected explicitly; this renderer never
-- reloads it from the cache.

local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.hgss.src.field.FieldErrors")
local FieldUiAssetCache = require("libs.assets.src.field.FieldUiAssetCache")
local ImageSampling = require("libs.nds.src.love.ImageSampling")
local LogicalSurface = require("libs.ui.src.LogicalSurface")

---@class TrainerCardRenderer
---@field _graphics love.graphics
---@field _text FieldTextRenderer the shared glyph atlas/text drawing collaborator
---@field _pool table<string, unknown>? borrowed shared image owner behind the card front
---@field _cardLease table<string, unknown>? installed card-front borrow returned on release
---@field _cardImage love.Image?
---@field _cardQuad love.Quad?
---@field card { front: { x: number, y: number, width: number, height: number } } the resolved manifest front surface
local TrainerCardRenderer = {}
TrainerCardRenderer.__index = TrainerCardRenderer

-- The audited front text anchors (canonical 256x192 reference space): the
-- label origin of each front window and the
-- right edge of each right-aligned value print.
TrainerCardRenderer.LABEL_ANCHORS = {
  { text = "ID No.", x = 16, y = 24 },
  { text = "NAME", x = 136, y = 24 },
  { text = "MONEY", x = 16, y = 48 },
  { text = "SCORE", x = 16, y = 104 },
  { text = "TIME", x = 16, y = 128 },
  { text = "ADVENTURE STARTED", x = 16, y = 144 },
}
TrainerCardRenderer.NAME_RIGHT_EDGE = 240
TrainerCardRenderer.TRAINER_ID_RIGHT_EDGE = 112
TrainerCardRenderer.TRAINER_ID_DIGITS = 5

-- opts.cacheFs: version-scoped private cache holding the generated field-UI
-- class (card front PNG); opts.manifest: the already-validated generated
-- field-UI manifest the runtime loaded once (FieldRuntime.uiManifest);
-- opts.text: the shared FieldTextRenderer (FieldState owns exactly one);
-- opts.graphics: injectable LÖVE graphics namespace so tests can record draw
-- calls; LÖVE itself remains an allowed presentation-layer dependency (the
-- PNG bytes still enter through love.filesystem.newFileData).

-- The card front samples point-filtered and clamped, matching the direct
-- construction below, so pooled borrows draw identically.
local POOLED_SAMPLER = { wrapX = "clamp", wrapY = "clamp", minFilter = "nearest", magFilter = "nearest" }

-- Borrows one generated visual through the shared owner, waiting out its
-- classification without blocking the field longer than the bounded stall
-- budget. Failures name their path instead of drawing a blank visual.
---@param pool table<string, unknown>
---@param token integer shared-owner request token behind the borrow
---@param path string generated visual path behind diagnostics
---@param what string visual role behind diagnostics
---@return table<string, unknown> borrow resolving the immutable visual
local function acquireReady(pool, token, path, what)
  local stalled = 0
  while true do
    local status, failure = pool:poll(token)
    if status == "ready" then
      return pool:acquire(token)
    end
    if status == "failed" then
      error(what .. " missing at " .. path .. ": " .. tostring(failure), 0)
    end
    assert(status == "pending", "trainer card preparation reports pending or ready")
    stalled = stalled + 1
    if stalled > 10000 then
      error(what .. " stalled at " .. path, 0)
    end
    local timer = love and love.timer
    if timer ~= nil and timer.sleep ~= nil then
      timer.sleep(0.001)
    end
  end
end

---@param opts { cacheFs: CacheFs, manifest: table<string, unknown>, text: FieldTextRenderer, graphics?: love.graphics, imagePool?: table<string, unknown> }
---@return TrainerCardRenderer
function TrainerCardRenderer.new(opts)
  assert(
    type(opts) == "table" and opts.cacheFs and opts.cacheFs.read,
    "TrainerCardRenderer requires a CacheFs-shaped object"
  )
  local graphics = opts.graphics
  if graphics == nil then
    graphics = love and love.graphics
  end
  assert(graphics and graphics.newImage and graphics.newQuad, "TrainerCardRenderer requires love.graphics")
  local text = opts.text
  assert(text and type(text.drawText) == "function", "TrainerCardRenderer requires the shared FieldTextRenderer")
  local cacheFs = opts.cacheFs
  local manifest = opts.manifest
  assert(type(manifest) == "table", "TrainerCardRenderer requires the runtime-validated field-UI manifest")

  -- The generated field-UI class is a required renderer asset: the manifest
  -- names the card front PNG and its rect. The runtime boot already validates
  -- the full manifest; the renderer resolves what it draws.
  local trainerCard = assert(manifest.trainerCard, "the field-UI manifest must carry the trainer card section")
  local frontAsset = assert(
    manifest.assets[FieldUiAssetCache.ASSET.TRAINER_CARD_FRONT],
    "the field-UI manifest must carry the trainer card front asset"
  )
  local cardPath = assert(frontAsset.image, "the trainer card front asset must name an image path")

  local self = setmetatable({
    _graphics = graphics,
    _text = text,
    _pool = opts.imagePool,
    _cardLease = nil,
    _cardImage = nil,
    _cardQuad = nil,
    card = {
      front = trainerCard.front,
    },
  }, TrainerCardRenderer)

  -- A missing card front is the existing named construction failure in
  -- every branch: the pooled borrow below never substitutes another image.
  local cardData = cacheFs:read(cardPath)
  if not cardData then
    self:release()
    Errors.raise(FieldErrors.FIELD_UI_TRAINER_CARD_FRONT_MISSING, "trainer card front missing at " .. cardPath, {
      path = cardPath,
    })
  end
  cardData = assert(cardData)
  local pool = opts.imagePool
  local ok, err = pcall(function()
    if pool ~= nil then
      -- The card front borrows the shared owner as an installed lease;
      -- quads stay renderer-owned geometry over the borrowed image.
      local token = pool:request(cardPath, POOLED_SAMPLER, "demand")
      local lease = acquireReady(pool, token, cardPath, "trainer card front")
      self._cardLease = lease
      self._cardImage = assert(lease.image, "shared borrows carry their resolved image")
      self._cardImage:setFilter("nearest", "nearest")
    else
      self._cardImage = graphics.newImage(love.filesystem.newFileData(cardData, cardPath))
      self._cardImage:setFilter("nearest", "nearest")
    end
    self:_buildQuads()
  end)
  if not ok then
    self:release()
    error(err)
  end
  return self
end

-- The card front surface quad: the manifest rect inside its atlas.
function TrainerCardRenderer:_buildQuads()
  local lg = assert(self._graphics)
  local card = assert(self._cardImage)
  local rect = self.card.front
  self._cardQuad = lg.newQuad(rect.x, rect.y, rect.width, rect.height, card:getWidth(), card:getHeight())
end

-- Draws the canonical card front through the resolved placement: the card
-- art over the manifest front rect, then the audited labels and the two
-- authoritative values (right-aligned per the source prints), all in logical
-- coordinates under one shared root transform. The presentation carries
-- only the implemented profile fields, so the label rows for unimplemented
-- values stay empty and nothing is fabricated. No-op (and no state touched)
-- when this renderer has no images. Restores canvas, shader, scissor,
-- blend, depth, wireframe, cull, and color afterwards.

---@param presentation table<string, unknown>?
---@param placement table<string, unknown>? the resolved full frame/clip placement
function TrainerCardRenderer:draw(presentation, placement)
  if not presentation or not self._cardImage then
    return
  end
  local lg = assert(self._graphics)
  assert(type(presentation.name) == "string", "the card presentation requires the player name")
  assert(type(presentation.visibleTrainerId) == "number", "the card presentation requires the visible trainer id")
  assert(type(presentation.money) == "number", "the card presentation requires money")
  assert(type(presentation.playTimeSeconds) == "number", "the card presentation requires play time")
  assert(
    placement ~= nil and type(placement.frame) == "table" and type(placement.scale) == "number",
    "the card surface requires the placement record"
  )
  lg.push("all")
  LogicalSurface.draw(lg, placement, function()
    lg.setColor(1, 1, 1, 1)
    local cardLease = self._cardLease
    if cardLease ~= nil then
      ImageSampling.draw(lg, cardLease, assert(self._cardQuad), self.card.front.x, self.card.front.y)
    else
      lg.draw(assert(self._cardImage), assert(self._cardQuad), self.card.front.x, self.card.front.y)
    end
    for _, anchor in ipairs(TrainerCardRenderer.LABEL_ANCHORS) do
      self._text:drawText(anchor.text, anchor.x, anchor.y)
    end
    local name = presentation.name
    self._text:drawText(name, TrainerCardRenderer.NAME_RIGHT_EDGE - self._text:textWidth(name), 24)
    local money = tostring(presentation.money)
    self._text:drawText(money, 152 - self._text:textWidth(money), 48)
    local totalMinutes = math.floor(presentation.playTimeSeconds / 60)
    local hours = math.floor(totalMinutes / 60)
    local minutes = totalMinutes % 60
    local playTime = string.format("%d:%02d", hours, minutes)
    self._text:drawText(playTime, 240 - self._text:textWidth(playTime), 128)
    local trainerId = string.format("%0" .. TrainerCardRenderer.TRAINER_ID_DIGITS .. "d", presentation.visibleTrainerId)
    self._text:drawText(trainerId, TrainerCardRenderer.TRAINER_ID_RIGHT_EDGE - self._text:textWidth(trainerId), 24)
  end)
  lg.pop()
end

function TrainerCardRenderer:release()
  local pool = self._pool
  self._pool = nil
  local lease = self._cardLease
  self._cardLease = nil
  if pool ~= nil then
    if lease ~= nil then
      pool:release(lease)
    end
  elseif self._cardImage and self._cardImage.release then
    self._cardImage:release()
  end
  self._cardImage, self._cardQuad = nil, nil
end

return TrainerCardRenderer
