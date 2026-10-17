-- HGSS naming surface renderer composing generated source visuals with
-- shared field text. The opaque base draws first, the selected transparent
-- page overlay draws over it at its manifest placement, then the
-- OAM-composed support backing, page controls, entry slots, keyboard and
-- entered-name text from the generated text geometry, the animated player
-- subject from the manifest, and the animated cursor visual with its
-- source palette pulse mask on top. Subject and cursor frames resolve
-- deterministically from the snapshot presentation clocks against the
-- generated durations and playback modes. Non-player subjects stay
-- host-owned: the host injects drawSubject with an explicit source position
-- and icon frame, and the renderer only brackets the call with balanced
-- graphics state. Generated images are owned here and released on
-- dispose, or borrowed from the shared image owner and returned there;
-- the text renderer and subject resources stay host-owned.

local ImageSampling = require("libs.nds.src.love.ImageSampling")
local PixelScale = require("libs.ui.src.PixelScale")
local Utf8Glyphs = require("libs.assets.src.Utf8Glyphs")
local Rgb555 = require("libs.codec.src.Rgb555")

local NamingScreenRenderer = {}

---@class NamingScreenRendererOptions
---@field graphics table<string, function>
---@field text table<string, function>
---@field drawSubject fun(graphics: table<string, function>, subject: table<string, unknown>, placement: { x: number, y: number, frameIndex: integer })
---@field manifest table<string, unknown>
---@field imageLoader (fun(path: string): unknown)? injected generated-image loader behind test and intro composition
---@field imagePool table<string, unknown>? borrowed shared generated-image owner behind field chrome

---@class NamingScreenRenderer
---@field graphics table<string, function>
---@field text table<string, function>
---@field drawSubject fun(graphics: table<string, function>, subject: table<string, unknown>, placement: { x: number, y: number, frameIndex: integer })?
---@field naming table<string, unknown>
---@field placement table<string, number>
---@field images table<string, unknown>
---@field quads table<table, table<string, unknown>>
---@field atlasSizes table<string, table<string, integer>>
---@field _pool table<string, unknown>? borrowed shared image owner behind leased chrome
---@field _leases table<string, table<string, unknown>> installed borrows by image key
---@field released boolean
---@field new fun(options: NamingScreenRendererOptions): NamingScreenRenderer
---@field draw fun(self: NamingScreenRenderer, view: NamingScreenSnapshot, layout: NamingScreenLayoutResult)
---@field dispose fun(self: NamingScreenRenderer)
NamingScreenRenderer.__index = NamingScreenRenderer

local PAGE_KEYS = { "upper", "lower", "symbols" }
local CONTROL_KEYS = { "upper", "lower", "symbols", "back", "ok", "backing" }
local HOME_KEYS = { "upper", "lower", "symbols", "back", "ok" }
local PAGE_CONTROL_KEYS = { "upper", "lower", "symbols" }
local PRESS_KEYS = { "back", "ok" }

local function imagePath(manifest, entry, what)
  assert(type(entry) == "table", "naming chrome " .. what .. " is missing")
  if type(entry.image) == "string" and entry.image ~= "" then
    return entry.image
  end
  local assets = manifest.assets
  local record = type(assets) == "table" and assets[entry.asset] or nil
  if type(record) == "table" and type(record.image) == "string" and record.image ~= "" then
    return record.image
  end
  error("naming chrome " .. what .. " names no generated image", 0)
end

-- Every generated PNG the renderer draws, in deterministic acquisition
-- order: static visuals by semantic key, then each unique animation atlas
-- (normal frames first, pulse masks alongside their cursor record).
local function acquireOrder(naming)
  local order = { "base", "upper", "lower", "symbols" }
  for _, key in ipairs(CONTROL_KEYS) do
    order[#order + 1] = "control:" .. key
  end
  for _, key in ipairs(PAGE_CONTROL_KEYS) do
    order[#order + 1] = "selected:" .. key
  end
  order[#order + 1] = "slot:normal"
  local seen = {}
  local function animationAssets(records)
    for _, record in ipairs(records) do
      for _, frame in ipairs(record.frames) do
        if not seen[frame.asset] then
          seen[frame.asset] = true
          order[#order + 1] = "atlas:" .. frame.asset
        end
      end
      if record.pulseAsset ~= nil and not seen[record.pulseAsset] then
        seen[record.pulseAsset] = true
        order[#order + 1] = "atlas:" .. record.pulseAsset
      end
    end
  end
  animationAssets({
    naming.entrySlots.selected,
    naming.playerSubjects.male,
    naming.playerSubjects.female,
    naming.pokemonGenderMarkers.male,
    naming.pokemonGenderMarkers.female,
  })
  animationAssets({ naming.pressed.back, naming.pressed.ok })
  animationAssets({ naming.cursor.keyboard })
  local homeRecords = {}
  for _, key in ipairs(HOME_KEYS) do
    homeRecords[#homeRecords + 1] = naming.cursor.home[key]
  end
  animationAssets(homeRecords)
  return order
end

local function trunc0(value)
  return value < 0 and math.ceil(value) or math.floor(value)
end

local function pulseGreen5(angle)
  return math.max(0, math.min(31, 15 + trunc0(math.sin(math.rad(angle)) * 10)))
end

-- The source focus-glow color: palette entry 29 with red 29, blue 0, and
-- the angle-driven green role, converted through the shared 5-bit decoder.
local function pulseColor(angle)
  local rgb = Rgb555.decode(29 + pulseGreen5(angle) * 32)
  return { r = rgb.r / 255, g = rgb.g / 255, b = rgb.b / 255 }
end

local function frameDurations(frames)
  local total = 0
  for _, frame in ipairs(frames) do
    total = total + frame.duration
  end
  return total
end

local function frameAt(entries, tick)
  local remaining = tick
  for _, entry in ipairs(entries) do
    if remaining < entry.frame.duration then
      return entry.index
    end
    remaining = remaining - entry.frame.duration
  end
  return entries[#entries].index
end

local function indexed(frames)
  local entries = {}
  for index, frame in ipairs(frames) do
    entries[index] = { frame = frame, index = index }
  end
  return entries
end

local function reversedEntries(frames)
  local entries = {}
  for index = #frames, 1, -1 do
    entries[#entries + 1] = { frame = frames[index], index = index }
  end
  return entries
end

-- Resolve the generated animation frame for a presentation tick. Forward
-- playback holds its last frame; looping playback repeats its loop segment
-- (forward from the loop start, reverse back down to it) after one full
-- pass. Reverse modes traverse the same frames in the opposite order.
local function resolveFrameIndex(record, tick)
  local frames = record.frames
  local total = frameDurations(frames)
  local mode = record.playMode
  if mode == "forward" then
    return frameAt(indexed(frames), math.min(tick, total - 1))
  elseif mode == "forward_loop" then
    if tick < total then
      return frameAt(indexed(frames), tick)
    end
    local start = record.loopStartFrameIdx + 1
    local prefix = 0
    for index = 1, start - 1 do
      prefix = prefix + frames[index].duration
    end
    return frameAt(indexed(frames), prefix + (tick - total) % (total - prefix))
  elseif mode == "reverse" then
    return frameAt(reversedEntries(frames), math.min(tick, total - 1))
  elseif mode == "reverse_loop" then
    local entries = reversedEntries(frames)
    if tick < total then
      return frameAt(entries, tick)
    end
    local region = {}
    for index = 1, #frames - record.loopStartFrameIdx do
      region[#region + 1] = entries[index]
    end
    local regionTotal = 0
    for _, entry in ipairs(region) do
      regionTotal = regionTotal + entry.frame.duration
    end
    local prefix = total - regionTotal
    return frameAt(region, prefix + (tick - total) % regionTotal)
  end
  error("unknown naming animation play mode: " .. tostring(mode), 0)
end

local function requireSprite(section, key, what)
  local entry = type(section) == "table" and section[key] or nil
  assert(type(entry) == "table", "naming renderer requires the " .. what .. " visual")
  assert(type(entry.anchor) == "table", "naming renderer requires the " .. what .. " anchor")
  assert(type(entry.offset) == "table", "naming renderer requires the " .. what .. " frame offset")
  return entry
end

local function requireAnchor(anchor, what)
  assert(type(anchor) == "table", "naming renderer requires the " .. what .. " anchor")
  assert(
    type(anchor.x) == "number" and anchor.x % 1 == 0 and type(anchor.y) == "number" and anchor.y % 1 == 0,
    "naming renderer requires integer " .. what .. " anchor coordinates"
  )
end

local function requireDenseArray(entries, what)
  assert(type(entries) == "table", "naming renderer requires " .. what)
  local count = 0
  local highestIndex = 0
  for index in pairs(entries) do
    assert(type(index) == "number" and index % 1 == 0 and index >= 1, "naming renderer requires dense " .. what)
    count = count + 1
    highestIndex = math.max(highestIndex, index)
  end
  assert(count > 0 and highestIndex == count, "naming renderer requires nonempty dense " .. what)
end

-- Naming chrome samples point-filtered and clamped, matching the direct
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
    assert(status == "pending", "naming preparation reports pending or ready")
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

-- Requests one generated visual through the shared owner and resolves
-- its borrow. Pool calls stay in module scope: captured upvalues do not
-- narrow inside the acquisition closure below.
---@param pool table<string, unknown>
---@param path string generated visual path behind diagnostics
---@param what string visual role behind diagnostics
---@return table<string, unknown> borrow resolving the immutable visual
local function acquireLease(pool, path, what)
  local token = pool:request(path, POOLED_SAMPLER, "demand")
  return acquireReady(pool, token, path, what)
end

-- Returns one borrow to the shared owner without touching its image:
-- pooled images die with their lease, never with an image release.
---@param pool table<string, unknown>
---@param lease table<string, unknown> borrow to return
local function releaseLease(pool, lease)
  pcall(pool.release, pool, lease)
end

---@param options { graphics: table<string, function>, text: table<string, function>, drawSubject: fun(graphics: table<string, function>, subject: table<string, unknown>, placement: { x: number, y: number, frameIndex: integer }), manifest: table<string, unknown>, imageLoader: (fun(path: string): unknown)?, imagePool: table<string, unknown>? }
---@return NamingScreenRenderer
function NamingScreenRenderer.new(options)
  assert(type(options) == "table" and options.graphics and options.text, "naming renderer requires graphics and text")
  assert(type(options.text.drawText) == "function", "naming renderer requires FieldTextRenderer.drawText")
  assert(type(options.drawSubject) == "function", "naming renderer requires a host drawSubject callback")
  assert(type(options.manifest) == "table", "naming renderer requires the field-UI naming manifest")
  assert(
    type(options.imageLoader) == "function" or options.imagePool ~= nil,
    "naming renderer requires the generated image loader or a shared image owner"
  )
  local naming = options.manifest.namingScreen
  assert(type(naming) == "table", "naming renderer requires the namingScreen manifest section")
  assert(type(naming.base) == "table", "naming renderer requires the naming base entry")
  assert(type(naming.pages) == "table", "naming renderer requires the naming page entries")
  assert(type(naming.placement) == "table", "naming renderer requires the naming page placement")
  assert(type(naming.text) == "table", "naming renderer requires the naming text geometry")
  assert(type(naming.controls) == "table", "naming renderer requires the naming controls")
  assert(type(naming.cursor) == "table", "naming renderer requires the naming cursor")
  assert(type(naming.entrySlots) == "table", "naming renderer requires the naming entry slots")
  assert(type(naming.playerSubjects) == "table", "naming renderer requires the naming player subjects")
  assert(type(naming.pokemonSubject) == "table", "naming renderer requires the Pokemon subject animation")
  assert(type(naming.pokemonGenderMarkers) == "table", "naming renderer requires the Pokemon gender markers")
  requireAnchor(naming.pokemonGenderMarkers.anchor, "Pokemon gender marker")
  for _, key in ipairs(CONTROL_KEYS) do
    requireSprite(naming.controls, key, key .. " control")
  end
  requireSprite(naming.entrySlots, "normal", "normal slot")
  for _, key in ipairs(PAGE_CONTROL_KEYS) do
    requireSprite(naming.pageSelected, key, key .. " selected control")
  end
  local animatedRecords = {
    naming.pressed.back,
    naming.pressed.ok,
    naming.entrySlots.selected,
    naming.playerSubjects.male,
    naming.playerSubjects.female,
    naming.pokemonGenderMarkers.male,
    naming.pokemonGenderMarkers.female,
    naming.cursor.keyboard,
  }
  for _, key in ipairs(HOME_KEYS) do
    animatedRecords[#animatedRecords + 1] = naming.cursor.home[key]
  end
  for _, record in ipairs(animatedRecords) do
    assert(
      type(record) == "table" and type(record.frames) == "table",
      "naming renderer requires generated animation frames"
    )
    assert(
      record.playMode == "forward"
        or record.playMode == "forward_loop"
        or record.playMode == "reverse"
        or record.playMode == "reverse_loop",
      "naming renderer requires a supported animation play mode"
    )
    assert(
      type(record.loopStartFrameIdx) == "number"
        and record.loopStartFrameIdx % 1 == 0
        and record.loopStartFrameIdx >= 0
        and record.loopStartFrameIdx < #record.frames,
      "naming renderer requires a loop start inside its animation frames"
    )
  end
  local pokemonSubject = naming.pokemonSubject
  requireDenseArray(pokemonSubject.frames, "Pokemon subject frames")
  requireAnchor(pokemonSubject.anchor, "Pokemon subject")
  assert(
    pokemonSubject.playMode == "forward"
      or pokemonSubject.playMode == "forward_loop"
      or pokemonSubject.playMode == "reverse"
      or pokemonSubject.playMode == "reverse_loop",
    "naming renderer requires a supported Pokemon subject play mode"
  )
  assert(
    type(pokemonSubject.loopStartFrameIdx) == "number"
      and pokemonSubject.loopStartFrameIdx % 1 == 0
      and pokemonSubject.loopStartFrameIdx >= 0
      and pokemonSubject.loopStartFrameIdx < #pokemonSubject.frames,
    "naming renderer requires a Pokemon subject loop start inside its frames"
  )
  for _, frame in ipairs(pokemonSubject.frames) do
    assert(type(frame.duration) == "number" and frame.duration % 1 == 0 and frame.duration > 0)
    requireDenseArray(frame.parts, "Pokemon subject parts")
    for _, part in ipairs(frame.parts) do
      assert(
        type(part.iconFrame) == "number"
          and part.iconFrame % 1 == 0
          and part.iconFrame >= 1
          and type(part.offset) == "table"
          and type(part.offset.x) == "number"
          and part.offset.x % 1 == 0
          and type(part.offset.y) == "number"
          and part.offset.y % 1 == 0,
        "naming renderer requires validated Pokemon subject part semantics"
      )
    end
  end
  local paths = { base = imagePath(options.manifest, naming.base, "base") }
  for _, key in ipairs(PAGE_KEYS) do
    paths[key] = imagePath(options.manifest, naming.pages[key], key .. " page")
  end
  for _, key in ipairs(CONTROL_KEYS) do
    paths["control:" .. key] = imagePath(options.manifest, naming.controls[key], key .. " control")
  end
  for _, key in ipairs(PAGE_CONTROL_KEYS) do
    paths["selected:" .. key] = imagePath(options.manifest, naming.pageSelected[key], key .. " selected control")
  end
  paths["slot:normal"] = imagePath(options.manifest, naming.entrySlots.normal, "normal slot")
  local function animationPath(assetId, what)
    local assets = options.manifest.assets
    local record = type(assets) == "table" and assets[assetId] or nil
    if type(record) == "table" and type(record.image) == "string" and record.image ~= "" then
      return record.image, record.width, record.height
    end
    error("naming animation " .. what .. " names no generated image", 0)
  end
  local atlasSizes = {}
  for _, record in ipairs(animatedRecords) do
    for _, frame in ipairs(record.frames) do
      if atlasSizes[frame.asset] == nil then
        local image, width, height = animationPath(frame.asset, "frame")
        paths["atlas:" .. frame.asset] = image
        atlasSizes[frame.asset] = { width = width, height = height }
      end
    end
    if record.pulseAsset ~= nil and atlasSizes[record.pulseAsset] == nil then
      local image, width, height = animationPath(record.pulseAsset, "pulse mask")
      paths["atlas:" .. record.pulseAsset] = image
      atlasSizes[record.pulseAsset] = { width = width, height = height }
    end
  end
  ---@type NamingScreenRenderer
  local pool = options.imagePool
  local renderer = setmetatable({
    graphics = options.graphics,
    text = options.text,
    drawSubject = options.drawSubject,
    naming = naming,
    placement = naming.placement,
    images = {},
    quads = {},
    atlasSizes = atlasSizes,
    _pool = pool,
    _leases = {},
    released = false,
  }, NamingScreenRenderer)
  local acquired = renderer.images
  local order = acquireOrder(naming)
  local ok, failure = pcall(function()
    for _, key in ipairs(order) do
      -- A borrowed pool image stays renderer-drawn but pool-owned: its
      -- lease returns at dispose while loader-owned images release
      -- directly, so the two ownership paths never mix on one instance.
      if pool ~= nil then
        local lease = acquireLease(assert(pool), paths[key], "naming chrome")
        local image = assert(lease.image, "shared borrows carry their resolved image")
        renderer._leases[key] = lease
        acquired[key] = image
        assert(type(image.setFilter) == "function", "naming image filtering is unavailable for " .. key)
        image:setFilter("nearest", "nearest")
      else
        local loader = assert(options.imageLoader, "naming renderer requires its generated image loader")
        local loaded = loader(paths[key])
        assert(loaded ~= nil, "naming image loader returned no image for " .. key)
        -- A loader answer carrying the lease sampler surface borrows
        -- from the shared owner: the image stays drawable while the
        -- lease installs beside it for sampler draws and returns at
        -- dispose. Bare loader-owned images behave exactly as before.
        local image = loaded
        if type(loaded) == "table" and type(loaded.drawQuad) == "function" then
          renderer._leases[key] = loaded
          image = assert(loaded.image, "shared borrows carry their resolved image")
        end
        acquired[key] = image
        assert(type(image.setFilter) == "function", "naming image filtering is unavailable for " .. key)
        image:setFilter("nearest", "nearest")
      end
    end
    for _, record in ipairs(animatedRecords) do
      for _, frame in ipairs(record.frames) do
        local atlas = assert(atlasSizes[frame.asset], "naming animation frame names an unindexed atlas")
        renderer.quads[frame] = {
          quad = options.graphics.newQuad(
            frame.rect.x,
            frame.rect.y,
            frame.rect.width,
            frame.rect.height,
            atlas.width,
            atlas.height
          ),
        }
        if record.pulseAsset ~= nil then
          local maskAtlas = assert(atlasSizes[record.pulseAsset], "naming cursor names an unindexed pulse atlas")
          renderer.quads[frame].maskQuad = options.graphics.newQuad(
            frame.pulseRect.x,
            frame.pulseRect.y,
            frame.pulseRect.width,
            frame.pulseRect.height,
            maskAtlas.width,
            maskAtlas.height
          )
        end
      end
    end
  end)
  if not ok then
    for _, key in ipairs(order) do
      local lease = renderer._leases[key]
      if lease ~= nil then
        -- Borrowed images die with their lease: releasing the image as
        -- well would free the session-owned physical underneath the pool.
        renderer._leases[key] = nil
        acquired[key] = nil
        if pool ~= nil then
          releaseLease(assert(pool), lease)
        end
      else
        local image = acquired[key]
        if image ~= nil then
          pcall(image.release, image)
          acquired[key] = nil
        end
      end
    end
    renderer.quads = {}
    error(failure, 0)
  end
  return renderer
end

local function homeControlAt(column)
  if column == 1 or column == 2 then
    return "upper"
  elseif column == 3 or column == 4 then
    return "lower"
  elseif column == 5 or column == 6 then
    return "symbols"
  elseif column == 9 or column == 10 or column == 11 then
    return "back"
  elseif column == 12 or column == 13 then
    return "ok"
  end
  return nil
end

function NamingScreenRenderer:draw(view, layout)
  assert(not self.released, "naming renderer is released")
  assert(type(view) == "table" and type(layout) == "table", "naming draw requires view and layout")
  assert(type(view.subject) == "table", "naming draw requires a semantic subject")
  assert(type(layout.surface) == "table", "naming draw requires a canonical surface")
  local naming = assert(self.naming, "naming renderer requires its manifest section")
  local page = self.images[view.page]
  if page == nil then
    error("unknown naming page: " .. tostring(view.page), 0)
  end
  local g = self.graphics
  g.push()
  g.translate(layout.surface.x, layout.surface.y)
  g.setColor(1, 1, 1, 1)
  self:_drawKeyed("base", nil, 0, 0)
  self:_drawKeyed(view.page, nil, self.placement.x, self.placement.y)
  local function drawVisual(imageKey, x, y)
    self:_drawKeyed(imageKey, nil, PixelScale.snapLogical(x), PixelScale.snapLogical(y))
  end
  -- The support backing composites first so the home controls it frames
  -- stay visible above it.
  do
    local backing = naming.controls.backing
    drawVisual("control:backing", backing.anchor.x + backing.offset.x, backing.anchor.y + backing.offset.y)
  end
  local presentation = assert(view.presentation, "naming draw requires snapshot presentation clocks")
  assert(type(presentation.pressTicks) == "table", "naming draw requires the control press clocks")
  for _, key in ipairs(PAGE_CONTROL_KEYS) do
    local selected = view.page == key
    local record = selected and naming.pageSelected[key] or naming.controls[key]
    drawVisual(
      (selected and "selected:" or "control:") .. key,
      record.anchor.x + record.offset.x,
      record.anchor.y + record.offset.y
    )
  end
  for _, key in ipairs(PRESS_KEYS) do
    local pressTick = presentation.pressTicks[key]
    if pressTick == nil then
      local record = naming.controls[key]
      drawVisual("control:" .. key, record.anchor.x + record.offset.x, record.anchor.y + record.offset.y)
    else
      local record = naming.pressed[key]
      local frame = record.frames[resolveFrameIndex(record, pressTick)]
      self:_drawAnimatedFrame(record, frame, record.anchor.x, record.anchor.y, nil)
    end
  end
  local slots = naming.entrySlots
  local entered = 0
  for _ in Utf8Glyphs.iter(view.text or "") do
    entered = entered + 1
  end
  assert(
    type(presentation.subjectTick) == "number"
      and type(presentation.cursorTick) == "number"
      and type(presentation.entrySlotTick) == "number"
      and type(presentation.glowAngle) == "number",
    "naming draw requires snapshot presentation clocks"
  )
  local maxLength = view.maxLength or entered
  for index = 0, maxLength - 1 do
    if index ~= entered or entered >= maxLength then
      local record = slots.normal
      drawVisual(
        "slot:normal",
        slots.origin.x + index * slots.stepX + record.offset.x,
        slots.origin.y + record.offset.y
      )
    end
  end
  if entered < maxLength then
    local record = slots.selected
    local frame = record.frames[resolveFrameIndex(record, presentation.entrySlotTick)]
    self:_drawAnimatedFrame(record, frame, slots.origin.x + entered * slots.stepX, slots.origin.y, nil)
  end
  g.setColor(1, 1, 1, 1)
  local keyboard = naming.text.keyboard.cells
  for row = 2, 6 do
    for column = 1, 13 do
      local cell = view.grid[row][column]
      if cell.kind == "glyph" then
        local textCell = keyboard[row - 1][column]
        local glyphWidth = self.text.textWidth and self.text:textWidth(cell.glyph) or 0
        self.text:drawText(cell.glyph, textCell.x + (textCell.width - glyphWidth) / 2, textCell.y)
      end
    end
  end
  local name = naming.text.name
  local slot = 0
  for glyph in Utf8Glyphs.iter(view.text or "") do
    self.text:drawText(glyph, name.x + slot * name.advanceX, name.y)
    slot = slot + 1
  end
  if view.subject.kind == "player" then
    local gender = view.subject.gender == 1 and "female" or "male"
    local record = naming.playerSubjects[gender]
    local frame = record.frames[resolveFrameIndex(record, presentation.subjectTick)]
    self:_drawAnimatedFrame(record, frame, record.anchor.x, record.anchor.y, nil)
  else
    local record = naming.pokemonSubject
    local frame = record.frames[resolveFrameIndex(record, presentation.subjectTick)]
    for _, part in ipairs(frame.parts) do
      g.push()
      self.drawSubject(g, view.subject, {
        x = record.anchor.x + part.offset.x,
        y = record.anchor.y + part.offset.y,
        frameIndex = part.iconFrame,
      })
      g.pop()
    end
    local gender = view.subject.gender
    if gender == "male" or gender == "female" then
      local marker = naming.pokemonGenderMarkers[gender]
      local markerFrame = marker.frames[resolveFrameIndex(marker, presentation.subjectTick)]
      self:_drawAnimatedFrame(
        marker,
        markerFrame,
        naming.pokemonGenderMarkers.anchor.x,
        naming.pokemonGenderMarkers.anchor.y,
        nil
      )
    else
      assert(gender == "genderless", "Pokemon naming subject has an unsupported gender")
    end
  end
  -- The focus cursor composites last so it stays above the control it
  -- highlights.
  local cursor = view.cursor
  if cursor.row == 1 then
    local controlId = homeControlAt(cursor.column)
    if controlId ~= nil then
      local record = naming.cursor.home[controlId]
      local frame = record.frames[resolveFrameIndex(record, presentation.cursorTick)]
      self:_drawAnimatedFrame(record, frame, record.anchor.x, record.anchor.y, presentation.glowAngle)
    end
  else
    local record = naming.cursor.keyboard
    local frame = record.frames[resolveFrameIndex(record, presentation.cursorTick)]
    self:_drawAnimatedFrame(
      record,
      frame,
      record.origin.x + (cursor.column - 1) * record.stepX,
      record.origin.y + (cursor.row - 2) * record.stepY,
      presentation.glowAngle
    )
  end
  g.pop()
end

-- One chrome/atlas draw through the shared exact sampler when its image
-- key is a pooled borrow, else the unchanged eager raw draw. The quad
-- stays optional and extra placement arguments pass through.
---@param imageKey string acquisition key ("base", page, "control:*", "atlas:*")
---@param quad love.Quad?
---@param x number
---@param y number
---@param ... unknown extra placement arguments forwarded to the draw call
function NamingScreenRenderer:_drawKeyed(imageKey, quad, x, y, ...)
  local g = self.graphics
  local lease = self._leases[imageKey]
  if lease ~= nil then
    ImageSampling.draw(g, lease, quad, x, y, ...)
    return
  end
  local image = assert(self.images[imageKey], "naming visual is missing: " .. tostring(imageKey))
  if quad ~= nil then
    g.draw(image, quad, x, y, ...)
  else
    g.draw(image, x, y, ...)
  end
end

-- Draw one resolved animation frame at its anchor plus the generated frame
-- offset. Cursor frames additionally draw their pulse mask tinted with the
-- current glow color; only mask pixels take the tint.
function NamingScreenRenderer:_drawAnimatedFrame(record, frame, anchorX, anchorY, glowAngle)
  local g = self.graphics
  local visual = assert(self.quads[frame], "naming animation frame was not acquired")
  self:_drawKeyed(
    "atlas:" .. frame.asset,
    visual.quad,
    PixelScale.snapLogical(anchorX + frame.offset.x),
    PixelScale.snapLogical(anchorY + frame.offset.y)
  )
  if glowAngle ~= nil and record.pulseAsset ~= nil then
    local tint = pulseColor(glowAngle)
    g.setColor(tint.r, tint.g, tint.b, 1)
    self:_drawKeyed(
      "atlas:" .. record.pulseAsset,
      assert(visual.maskQuad, "naming cursor frame was not masked"),
      PixelScale.snapLogical(anchorX + frame.offset.x),
      PixelScale.snapLogical(anchorY + frame.offset.y)
    )
    g.setColor(1, 1, 1, 1)
  end
end

function NamingScreenRenderer:dispose()
  if self.released then
    return
  end
  self.released = true
  -- Borrowed chrome returns to the shared owner instead of releasing
  -- its images: the pool alone frees session-owned physicals.
  local pool = self._pool
  self._pool = nil
  if pool ~= nil then
    for key, lease in pairs(self._leases) do
      self._leases[key] = nil
      self.images[key] = nil
      pcall(pool.release, pool, lease)
    end
    self.quads = {}
    self.drawSubject = nil
    return
  end
  for key, image in pairs(self.images) do
    -- Loader answers that borrowed a pool lease stay loader-owned: the
    -- loader returns its borrows at its own teardown, so releasing the
    -- image here would free the session-owned physical underneath it.
    if image ~= nil and self._leases[key] == nil then
      pcall(image.release, image)
    end
    self.images[key] = nil
  end
  self._leases = {}
  self.quads = {}
  self.drawSubject = nil
end

NamingScreenRenderer.release = NamingScreenRenderer.dispose
return NamingScreenRenderer
