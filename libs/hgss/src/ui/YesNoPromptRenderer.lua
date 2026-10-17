-- Renders the reusable two-row choice prompt through the generated button
-- artwork: both rows draw every active frame at the controller status
-- rectangles, the selected row through its selected visual while the
-- controller reports it highlighted and through its normal visual otherwise.
-- The runtime-validated manifest is injected
-- explicitly; this renderer never reloads it from the cache. Construction is
-- failure-safe: a missing section or asset is a loud error, a later
-- image/quad failure releases every image acquired so far before rethrowing,
-- and release() is idempotent with draw-after-release a no-op.

local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.hgss.src.field.FieldErrors")
local ImageSampling = require("libs.nds.src.love.ImageSampling")

---@class YesNoPromptRenderer
---@field _graphics love.graphics
---@field _pool table<string, unknown>? borrowed shared image owner behind the button art
---@field _leases table<string, table<string, unknown>> installed borrows by manifest asset id
---@field _images love.Image[] every acquired image, released exactly once
---@field _imageByAsset table<string, love.Image> acquired images by manifest asset id
---@field _quads table<string, love.Quad> quads by asset id plus rect
---@field _visuals table<string, { asset: string, rect: { x: integer, y: integer, width: integer, height: integer } }>
local YesNoPromptRenderer = {}
YesNoPromptRenderer.__index = YesNoPromptRenderer

-- opts.cacheFs: version-scoped private cache holding the generated field-UI
-- class (prompt button PNGs); opts.manifest: the already-validated
-- generated field-UI manifest the runtime loaded once;
-- opts.graphics: injectable LÖVE graphics namespace so tests can record draw
-- calls; LÖVE itself remains an allowed presentation-layer dependency (the
-- PNG bytes still enter through love.filesystem.newFileData).

-- Prompt button art samples point-filtered and clamped, matching the
-- direct construction below, so pooled borrows draw identically.
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
    assert(status == "pending", "prompt preparation reports pending or ready")
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

---@param opts { cacheFs: CacheFs, manifest: table<string, unknown>, graphics?: unknown, imagePool?: table<string, unknown> }
---@return YesNoPromptRenderer
function YesNoPromptRenderer.new(opts)
  assert(
    type(opts) == "table" and opts.cacheFs and opts.cacheFs.read,
    "YesNoPromptRenderer requires a CacheFs-shaped object"
  )
  local graphics = opts.graphics
  if graphics == nil then
    graphics = love and love.graphics
  end
  assert(graphics and graphics.newImage and graphics.newQuad, "YesNoPromptRenderer requires love.graphics")
  ---@cast graphics love.graphics
  local cacheFs = opts.cacheFs
  local manifest = opts.manifest
  assert(type(manifest) == "table", "YesNoPromptRenderer requires the runtime-validated field-UI manifest")

  -- The generated field-UI class is a required renderer asset: the manifest
  -- names the four compact button visuals. The runtime boot already
  -- validated the full manifest; the renderer resolves what it draws.
  local prompt = assert(manifest.yesNoPrompt, "the field-UI manifest must carry the two-row prompt section")
  assert(type(prompt) == "table", "the two-row prompt section must be a table")
  local shapes = assert(prompt.shapes, "the two-row prompt section must carry its shape map")
  local compact = assert(shapes.compact, "the field-UI manifest must carry the compact prompt shape")
  local visuals = {}
  for _, row in ipairs({ "yes", "no" }) do
    local states = assert(compact[row], "the compact prompt shape must carry the " .. row .. " row")
    for _, state in ipairs({ "normal", "selected" }) do
      local visual = assert(states[state], "the compact prompt " .. row .. " row must carry its " .. state .. " visual")
      assert(type(visual.asset) == "string", "a prompt visual must name its atlas")
      assert(type(visual.rect) == "table", "a prompt visual must carry its atlas rect")
      visuals[row .. "." .. state] = visual
    end
  end

  local self = setmetatable({
    _graphics = graphics,
    _pool = opts.imagePool,
    _leases = {},
    _images = {},
    _imageByAsset = {},
    _quads = {},
    _visuals = visuals,
  }, YesNoPromptRenderer)

  local ok, err = pcall(function()
    self:_acquire(cacheFs, manifest)
  end)
  if not ok then
    self:release()
    error(err)
  end
  return self
end

-- Acquires the button images and builds every visual quad. Images are owned
-- once per manifest asset id while quads are cached per asset plus rect, so
-- several button states may share one atlas image. Any failure releases
-- everything acquired so far before the constructor rethrows.
---@param cacheFs CacheFs
---@param manifest table<string, unknown>
function YesNoPromptRenderer:_acquire(cacheFs, manifest)
  local graphics = assert(self._graphics)
  local pool = self._pool
  local function acquire(assetId)
    local known = self._imageByAsset[assetId]
    if known ~= nil then
      return known
    end
    local entry = assert(manifest.assets[assetId], "the field-UI manifest must carry the prompt button asset")
    local path = assert(entry.image, "a prompt button asset must name an image path")
    if pool ~= nil then
      -- Button atlases borrow the shared owner as installed leases; the
      -- drawn image stays the resolved lease image, released with the
      -- renderer instead of outliving the prompt.
      local token = pool:request(path, POOLED_SAMPLER, "demand")
      local lease = acquireReady(pool, token, path, "the prompt button art")
      local image = assert(lease.image, "shared borrows carry their resolved image")
      self._leases[assetId] = lease
      self._imageByAsset[assetId] = image
      image:setFilter("nearest", "nearest")
      return image
    end
    local data = cacheFs:read(path)
    if not data then
      Errors.raise(
        FieldErrors.FIELD_UI_YES_NO_PROMPT_MISSING,
        "the prompt button art is missing at " .. path,
        { path = path }
      )
    end
    data = assert(data)
    local image = graphics.newImage(love.filesystem.newFileData(data, path))
    self._images[#self._images + 1] = image
    self._imageByAsset[assetId] = image
    image:setFilter("nearest", "nearest")
    return image
  end
  local function quadFor(assetId, rect)
    local key = assetId .. "\0" .. rect.x .. "," .. rect.y .. "," .. rect.width .. "," .. rect.height
    local quad = self._quads[key]
    if quad == nil then
      local image = acquire(assetId)
      quad = graphics.newQuad(rect.x, rect.y, rect.width, rect.height, image:getWidth(), image:getHeight())
      self._quads[key] = quad
    end
    return quad
  end
  for _, key in ipairs({ "yes.normal", "yes.selected", "no.normal", "no.selected" }) do
    local visual = assert(self._visuals[key], "the compact prompt must carry the " .. key .. " visual")
    quadFor(assert(visual.asset), assert(visual.rect))
  end
end

---@param assetId string
---@param rect { x: integer, y: integer, width: integer, height: integer }
---@return love.Quad
function YesNoPromptRenderer:_quadFor(assetId, rect)
  local key = assetId .. "\0" .. rect.x .. "," .. rect.y .. "," .. rect.width .. "," .. rect.height
  return assert(self._quads[key], "a prompt button visual must have a built quad")
end

-- Draws the active prompt: the YES row then the NO row at the status button
-- rectangles. While the selection is highlighted the selected row draws
-- through its selected visual; otherwise both rows draw through their
-- normal visuals. A nil, inactive, or post-release status draws nothing.
---@param status { active: boolean, selected: string?, selectionHighlighted: boolean?, buttons: { yes: { x: integer, y: integer, width: integer, height: integer }, no: { x: integer, y: integer, width: integer, height: integer } }? }?
function YesNoPromptRenderer:draw(status)
  if type(status) ~= "table" or status.active ~= true then
    return
  end
  -- Drawn chrome is either privately owned images or pooled borrows: an
  -- empty prompt with neither draws nothing, including after release.
  if #self._images == 0 and next(self._leases) == nil then
    return
  end
  local selected = assert(status.selected, "an active prompt has a selection")
  assert(selected == "yes" or selected == "no", "an active prompt has a selection")
  assert(type(status.selectionHighlighted) == "boolean", "an active prompt carries its selection highlight phase")
  local buttons = assert(status.buttons, "an active prompt carries its button rows")
  assert(type(buttons) == "table", "an active prompt carries its button rows")
  local yesRow = assert(buttons.yes, "an active prompt carries the YES row")
  local noRow = assert(buttons.no, "an active prompt carries the NO row")
  local highlighted = status.selectionHighlighted
  local yesVisual = assert(self._visuals[selected == "yes" and highlighted and "yes.selected" or "yes.normal"])
  local noVisual = assert(self._visuals[selected == "no" and highlighted and "no.selected" or "no.normal"])
  local graphics = assert(self._graphics)
  graphics.setColor(1, 1, 1, 1)
  self:_drawButton(yesVisual, yesRow.x, yesRow.y)
  self:_drawButton(noVisual, noRow.x, noRow.y)
end

-- One prompt button through the shared exact sampler when its atlas is a
-- pooled borrow, else the unchanged eager raw draw. RGBA borrows render
-- pixel-identical through the sampler; indexed borrows bind their exact
-- palette instead of rendering index bytes.
---@param visual { asset: string, rect: { x: integer, y: integer, width: integer, height: integer } }
---@param x number
---@param y number
function YesNoPromptRenderer:_drawButton(visual, x, y)
  local graphics = assert(self._graphics)
  local asset = assert(visual.asset, "a prompt visual must name its atlas")
  local quad = self:_quadFor(asset, assert(visual.rect, "a prompt visual must carry its atlas rect"))
  local lease = self._leases[asset]
  if lease ~= nil then
    ImageSampling.draw(graphics, lease, quad, x, y)
    return
  end
  graphics.draw(assert(self._imageByAsset[asset], "a prompt button visual must have its image"), quad, x, y)
end

function YesNoPromptRenderer:release()
  local pool = self._pool
  self._pool = nil
  if pool ~= nil then
    for _, lease in pairs(self._leases) do
      pool:release(lease)
    end
    self._leases = {}
    self._imageByAsset = {}
    self._quads = {}
    return
  end
  for _, image in ipairs(self._images) do
    if image.release then
      image:release()
    end
  end
  self._images = {}
  self._imageByAsset = {}
  self._quads = {}
end

return YesNoPromptRenderer
