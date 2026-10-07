-- Field-owned Summary preparation lifetimes: one resource owner hands
-- out per-open demand leases over bounded portrait demand, isolates
-- overlapping leases by demand key and picture epoch, surfaces failures
-- instead of hanging, and releases every owned GPU object exactly once
-- while borrowed icon, queue, and text collaborators stay alive. Demand
-- per lease is the Summary-owned referenced visuals plus the shader, the
-- current roster icon keys, and at most the six unique portrait pages
-- behind the current party portrait identities; eggs resolve to small
-- Summary-owned visuals and demand no portrait page. Shared pages are
-- coalesced across leases; releasing one lease never cancels a
-- replacement lease's work. Portrait pages realize at most one new page
-- per prepare call while the borrowed icon provider keeps its own
-- independent bound. Every realized image is owned once under its
-- canonical cache-relative path; semantic names and page ids resolve to
-- that path instead of storing a second image. Realized art stays cached
-- at the owner while a live lease watches it; the last release of shared
-- demand frees each owned object exactly once, including quads and the
-- picture shader, so a later lease re-decodes with fresh identities.
-- A stale demand key can never be adopted as the selected picture.

local MonCache = require("libs.assets.src.MonCache")
local SummaryAssetSchema = require("libs.assets.src.SummaryAssetSchema")
local SummaryCache = require("libs.assets.src.SummaryCache")

local SHADER_PATH = "libs/hgss/src/ui/shaders/summary_picture.glsl"
local MAX_PORTRAIT_PAGES = 6

---@param path string
---@return string shader source
local function readShaderSource(path)
  if love and love.filesystem then
    local ok, source = pcall(love.filesystem.read, path)
    if ok and type(source) == "string" and source ~= "" then
      return source
    end
  end
  local file = io.open(path, "rb")
  if file then
    local source = file:read("*a")
    file:close()
    if type(source) == "string" and source ~= "" then
      return source
    end
  end
  error("cannot read summary picture shader source: " .. path, 0)
end

---@class SummaryPresentationResources
---@field _cacheFs table<string, unknown>
---@field _graphics table<string, unknown>
---@field _text table<string, unknown>
---@field _icons table<string, unknown>
---@field _queue table<string, unknown>
---@field _derivedAssets table<string, unknown>
---@field _manifest table<string, unknown>
---@field _portraitEntries table<string, table<string, unknown>>
---@field _visualPaths string[]
---@field _imagesByPath table<string, table<string, unknown>> realized images by canonical path
---@field _tokensByPath table<string, unknown> decode tokens by canonical path
---@field _payloadsByPath table<string, table<string, unknown>> decoded payloads awaiting realization by path
---@field _quads table<string, unknown> realized quads by selector and frame
---@field _quadPaths table<string, string> owning page path per cached quad
---@field _shader table<string, unknown>? the one owned picture-palette shader
---@field _shaderFailed string? visible shader failure
---@field _shaderSource string?
---@field _released boolean
---@field _leases table<string, unknown>[] per-open leases in acquisition order
local SummaryPresentationResources = {}
SummaryPresentationResources.__index = SummaryPresentationResources

---@class SummaryPresentationResources.Options
---@field cacheFs table<string, unknown>
---@field graphics table<string, unknown>
---@field text table<string, unknown>
---@field icons table<string, unknown>
---@field preparationQueue table<string, unknown>
---@field derivedAssets table<string, unknown>
---@field manifest table<string, unknown>

---@param opts SummaryPresentationResources.Options
---@return SummaryPresentationResources
function SummaryPresentationResources.new(opts)
  assert(type(opts) == "table", "summary preparation needs its collaborators")
  local cacheFs = assert(opts.cacheFs, "summary preparation needs its cache reader")
  assert(type(cacheFs.loadLua) == "function", "summary preparation reads metadata through its cache")
  local graphics = assert(opts.graphics, "summary preparation needs its graphics namespace")
  assert(
    type(graphics.newImage) == "function" and type(graphics.newQuad) == "function",
    "summary preparation realizes images and quads"
  )
  local text = assert(opts.text, "summary preparation borrows its text renderer")
  local icons = assert(opts.icons, "summary preparation borrows its icon provider")
  local queue = assert(opts.preparationQueue, "summary preparation borrows its image queue")
  assert(
    type(queue.request) == "function"
      and type(queue.poll) == "function"
      and type(queue.take) == "function"
      and type(queue.cancel) == "function",
    "summary preparation drives request, poll, take, and cancel"
  )
  local derivedAssets = assert(opts.derivedAssets, "summary preparation needs its compilation seam")
  assert(type(derivedAssets) == "table", "summary preparation demands portrait pages through the provisioner")
  local manifest = assert(opts.manifest, "summary preparation needs the summary family")
  SummaryAssetSchema.assertManifest(manifest)
  local portraitManifest =
    assert(cacheFs:loadLua(MonCache.portraitManifestPath()), "summary preparation needs the portrait manifest")
  assert(type(portraitManifest.entries) == "table", "the portrait manifest carries entries")
  return setmetatable({
    _cacheFs = cacheFs,
    _graphics = graphics,
    _text = text,
    _icons = icons,
    _queue = queue,
    _derivedAssets = derivedAssets,
    _manifest = manifest,
    _portraitEntries = portraitManifest.entries,
    _visualPaths = SummaryCache.referencedPaths(manifest),
    _imagesByPath = {},
    _tokensByPath = {},
    _payloadsByPath = {},
    _quads = {},
    _quadPaths = {},
    _shader = nil,
    _shaderFailed = nil,
    _shaderSource = nil,
    _released = false,
  }, SummaryPresentationResources)
end

---@param self SummaryPresentationResources
---@param selector string full roster portrait identity
---@return integer? portrait page behind the exact identity
---@return string? absence cause when the generated manifest carries no page
local function pageForSelector(self, selector)
  local entries = assert(self._portraitEntries, "summary preparation keeps its portrait entries")
  local entry = entries[selector]
  if type(entry) ~= "table" then
    return nil, "the portrait manifest carries no page for " .. tostring(selector)
  end
  local pageId = entry.pageId
  if type(pageId) ~= "number" then
    return nil, "the portrait entry for " .. tostring(selector) .. " carries no page"
  end
  return pageId
end

---@param demand table<string, unknown>
local function checkDemand(demand)
  assert(type(demand) == "table", "preparation demands arrive as records")
  assert(type(demand.key) == "string" and demand.key ~= "", "demands carry their key")
  assert(type(demand.revision) == "number", "demands carry the roster revision")
  assert(type(demand.pictureEpoch) == "number", "demands carry the picture epoch")
  assert(type(demand.portraitSelectors) == "table", "demands carry roster portrait selectors")
  assert(#demand.portraitSelectors <= MAX_PORTRAIT_PAGES, "portrait demand stays within the current party")
  for _, selector in ipairs(demand.portraitSelectors) do
    assert(
      type(selector) == "string" and selector:find("/", 1, true) ~= nil,
      "roster portrait selectors arrive as full identities"
    )
  end
  assert(type(demand.iconKeys) == "table", "demands carry roster icon keys")
  for _, key in ipairs(demand.iconKeys) do
    assert(type(key) == "string" and key ~= "", "roster icon keys arrive as strings")
  end
end

---@param self SummaryPresentationResources
---@param demand table<string, unknown>
---@return integer[]? sorted unique portrait pages behind the exact selectors
---@return string? absence cause naming the first selector without a page
local function demandPages(self, demand)
  local seen = {}
  local pages = {}
  for _, selector in ipairs(demand.portraitSelectors) do
    local pageId, cause = pageForSelector(self, selector)
    if pageId == nil then
      return nil, cause
    end
    if not seen[pageId] then
      seen[pageId] = true
      pages[#pages + 1] = pageId
    end
  end
  table.sort(pages)
  assert(#pages <= MAX_PORTRAIT_PAGES, "portrait demand stays within the current party")
  return pages
end

---@param self SummaryPresentationResources
---@param payload table<string, unknown>
---@return table<string, unknown> realized image with nearest filtering
local function realizeImage(self, payload)
  local graphics = assert(self._graphics, "summary preparation keeps its graphics namespace")
  local feed = payload.imageData or payload.bytes
  local image = nil
  if feed ~= nil then
    image = graphics.newImage(feed)
  else
    image = graphics.newImage(assert(payload.path, "decoded payloads carry their path"))
  end
  if type(image.setFilter) == "function" then
    image:setFilter("nearest", "nearest")
  end
  return image
end

-- Advances one decode: request once per path, poll the outstanding token,
-- and take exactly one ready payload. Failures cancel the token and name
-- their cause; a second lease sharing the path reuses the same record.
---@param self SummaryPresentationResources
---@param path string cache-relative image path
---@return "ready"|"pending"|"failed", string?
local function advanceDecode(self, path)
  if self._imagesByPath[path] ~= nil then
    return "ready"
  end
  if self._payloadsByPath[path] ~= nil then
    return "ready"
  end
  local token = self._tokensByPath[path]
  if token == nil then
    local ok, requested = pcall(self._queue.request, self._queue, "image", path, "demand")
    if not ok then
      return "failed", tostring(requested)
    end
    self._tokensByPath[path] = requested
    token = requested
  end
  local ok, pollState, pollCause = pcall(self._queue.poll, self._queue, token)
  if not ok then
    self._tokensByPath[path] = nil
    return "failed", tostring(pollState)
  end
  -- The preparation harness reports table outcomes while the production
  -- queue reports bare statuses; both ride the same pending/ready/failed
  -- vocabulary.
  local state, cause = pollState, pollCause
  if type(pollState) == "table" then
    state = pollState.status
    cause = pollState.error or pollCause
  end
  if state == "failed" then
    pcall(self._queue.cancel, self._queue, token)
    self._tokensByPath[path] = nil
    return "failed", tostring(cause)
  end
  if state == "ready" then
    local takeOk, payload = pcall(self._queue.take, self._queue, token)
    self._tokensByPath[path] = nil
    if not takeOk then
      return "failed", tostring(payload)
    end
    assert(type(payload) == "table", "decoded payloads arrive as records")
    payload.path = payload.path or path
    self._payloadsByPath[path] = payload
    return "ready"
  end
  return "pending"
end

---@param image table<string, unknown>? owned GPU object
local function releaseOwned(image)
  if image == nil then
    return
  end
  if type(image) == "table" or type(image) == "userdata" then
    if type(image.release) == "function" then
      image:release()
    end
  end
end

-- Union of canonical paths still watched by live leases. Leases that
-- never prepared watch nothing; released leases watch nothing.
---@param self SummaryPresentationResources
---@return table<string, boolean> canonical paths with live interest
local function liveWatchedPaths(self)
  local watched = {}
  for _, other in pairs(self._leases or {}) do
    if other._released ~= true and type(other._watched) == "table" then
      for _, path in ipairs(other._watched) do
        watched[path] = true
      end
    end
  end
  return watched
end

-- Drops owned state no live lease watches anymore: outstanding decode
-- tokens cancel through the borrowed queue, decoded payloads clear, and
-- each realized image releases exactly once. Quads resolve through their
-- owning page path, so quads behind a dropped page clear with it. When
-- no live lease watches anything, the owned quads and picture shader
-- release as well and the shader failure clears so a later lease can
-- retry; the shader source bytes stay cached because they own no GPU
-- state. A surviving replacement lease keeps its coalesced demand
-- usable without re-decoding.
---@param self SummaryPresentationResources
---@param watched table<string, boolean> canonical paths kept by live leases
local function dropUnwatchedArt(self, watched)
  for path, token in pairs(self._tokensByPath) do
    if watched[path] ~= true then
      pcall(self._queue.cancel, self._queue, token)
      self._tokensByPath[path] = nil
    end
  end
  for path, _ in pairs(self._payloadsByPath) do
    if watched[path] ~= true then
      self._payloadsByPath[path] = nil
    end
  end
  local dropped = {}
  for path, image in pairs(self._imagesByPath) do
    if watched[path] ~= true then
      releaseOwned(image)
      self._imagesByPath[path] = nil
      dropped[path] = true
    end
  end
  local keepQuads = next(dropped) == nil
  if not keepQuads and next(watched) ~= nil then
    for cacheKey, path in pairs(self._quadPaths) do
      if dropped[path] == true then
        releaseOwned(self._quads[cacheKey])
        self._quads[cacheKey] = nil
        self._quadPaths[cacheKey] = nil
      end
    end
  end
  if next(watched) == nil then
    for cacheKey, quad in pairs(self._quads) do
      releaseOwned(quad)
      self._quads[cacheKey] = nil
      self._quadPaths[cacheKey] = nil
    end
    local shader = self._shader
    self._shader = nil
    releaseOwned(shader)
    self._shaderFailed = nil
  end
end
-- Releases the demand interest the lease no longer owns: paths no other
-- live lease watches cancel through the borrowed queue, and owned art no
-- live lease watches disposes so the last release frees every owned
-- object exactly once. A surviving replacement lease keeps its coalesced
-- demand without re-decoding.
---@param self SummaryPresentationResources
---@param lease table<string, unknown>
local function dropLeaseInterest(self, lease)
  lease._watched = {}
  dropUnwatchedArt(self, liveWatchedPaths(self))
end

---@param self SummaryPresentationResources
---@return table<string, unknown> ready bundle accessors over canonical path-owned art
local function readyBundle(self)
  local owner = self
  local manifest = assert(owner._manifest, "summary preparation keeps its family")
  local portraits = {}
  function portraits:image(selector)
    assert(type(selector) == "string", "portrait reads name their selector")
    local entry = assert(owner._portraitEntries[selector], "the portrait manifest carries no page for " .. selector)
    local pageId = assert(entry.pageId, "the portrait entry for " .. selector .. " carries its page")
    local image = owner._imagesByPath[MonCache.portraitPagePath(pageId)]
    assert(image ~= nil, "the portrait page is not prepared for " .. selector)
    return image
  end
  function portraits:quadFor(selector, frameIndex)
    assert(type(selector) == "string", "portrait reads name their selector")
    local entry = assert(owner._portraitEntries[selector], "the portrait manifest carries no page for " .. selector)
    local frames = assert(entry.frames, "portrait entries carry frames")
    local frame = frames[frameIndex or 1] or assert(frames[1], "portrait entries carry frames")
    local cacheKey = selector .. "#" .. tostring(frameIndex or 1)
    local quad = owner._quads[cacheKey]
    if quad == nil then
      local image = portraits:image(selector)
      quad = owner._graphics.newQuad(frame.x, frame.y, frame.width, frame.height, image:getWidth(), image:getHeight())
      owner._quads[cacheKey] = quad
      owner._quadPaths[cacheKey] =
        MonCache.portraitPagePath(assert(entry.pageId, "the portrait entry for " .. selector .. " carries its page"))
    end
    return quad
  end
  function portraits:dimensions(selector)
    assert(type(selector) == "string", "portrait reads name their selector")
    local entry = assert(owner._portraitEntries[selector], "the portrait manifest carries no page for " .. selector)
    return { width = entry.width, height = entry.height }
  end
  local bundle = {
    manifest = manifest,
    portraits = portraits,
    icons = owner._icons,
    text = owner._text,
    shader = assert(owner._shader, "ready preparation carries its picture shader"),
  }
  function bundle.visualImage(name)
    assert(type(name) == "string" and name ~= "", "visual reads name their record")
    local visuals = assert(manifest.visuals, "the summary family carries its visuals")
    local record = assert(visuals[name], "the summary family carries visual " .. name)
    local path = assert(record.image, "visual " .. name .. " carries its image")
    local image = owner._imagesByPath[path]
    assert(image ~= nil, "visual " .. name .. " is not prepared at " .. path)
    return image
  end
  function bundle.imageForPath(path)
    assert(type(path) == "string" and path ~= "", "path reads name their cache-relative path")
    local image = owner._imagesByPath[path]
    assert(image ~= nil, "no prepared image for path " .. path)
    return image
  end
  return bundle
end

---@param self SummaryPresentationResources
---@param lease table<string, unknown>
---@param demand table<string, unknown>
---@return table<string, unknown> prepare outcome
local function prepareLease(self, lease, demand)
  assert(not self._released, "summary preparation is released")
  assert(lease._released ~= true, "the preparation lease is released")
  assert(lease._owner == self, "leases prepare through their owner")
  checkDemand(demand)
  local pages, pageCause = demandPages(self, demand)
  if pages == nil then
    return { kind = "failed", error = tostring(pageCause) }
  end
  local watched = {}
  for _, path in ipairs(self._visualPaths) do
    watched[#watched + 1] = path
  end
  local pagePaths = {}
  for _, pageId in ipairs(pages) do
    local path = MonCache.portraitPagePath(pageId)
    pagePaths[#pagePaths + 1] = path
    watched[#watched + 1] = path
  end
  lease._watched = watched
  -- A changed demand drops interest the union no longer owns before new
  -- work starts, so cancelled tokens and their late completions can
  -- never populate a path the live leases stopped watching.
  dropUnwatchedArt(self, liveWatchedPaths(self))
  -- Roster icons ride the borrowed provider with its own lifetime: never
  -- cancelled or released here, only observed ready or failed.
  do
    local ok, ready, failure = pcall(self._icons.prepareKeys, self._icons, demand.iconKeys)
    if not ok then
      return { kind = "failed", error = tostring(ready) }
    end
    if failure ~= nil then
      return { kind = "failed", error = tostring(failure) }
    end
    if not ready then
      return { kind = "pending" }
    end
  end
  -- Portrait compilation through the existing provisioner seam: a named
  -- failure surfaces, an unready page waits, and dispatched jobs are
  -- never cancelled from here. A missing seam fails visibly instead of
  -- hanging the lease.
  local requestPage = self._derivedAssets.requestMonPortraitPage
  if type(requestPage) ~= "function" then
    return { kind = "failed", error = "portrait compilation is unavailable" }
  end
  for _, pageId in ipairs(pages) do
    local path = MonCache.portraitPagePath(pageId)
    if self._imagesByPath[path] == nil and self._payloadsByPath[path] == nil then
      local ok, ready, failure = pcall(requestPage, self._derivedAssets, pageId, "required")
      if not ok then
        return { kind = "failed", error = tostring(ready) }
      end
      if failure ~= nil then
        return { kind = "failed", error = tostring(failure) }
      end
      if not ready then
        return { kind = "pending" }
      end
    end
  end
  local pending = false
  local function decodePath(path)
    local state, cause = advanceDecode(self, path)
    if state == "failed" then
      return cause
    end
    if state == "pending" then
      pending = true
    end
    return nil
  end
  for _, path in ipairs(self._visualPaths) do
    local failure = decodePath(path)
    if failure ~= nil then
      return { kind = "failed", error = failure }
    end
  end
  for _, path in ipairs(pagePaths) do
    local failure = decodePath(path)
    if failure ~= nil then
      return { kind = "failed", error = failure }
    end
  end
  -- Realize decoded visuals as they arrive; portrait pages realize at
  -- most one new page per call so a cold open never uploads the party at
  -- once. Realization failures name their path.
  for _, path in ipairs(self._visualPaths) do
    local payload = self._payloadsByPath[path]
    if payload ~= nil and self._imagesByPath[path] == nil then
      local ok, image = pcall(realizeImage, self, payload)
      if not ok then
        return { kind = "failed", error = tostring(image) }
      end
      self._imagesByPath[path] = image
      self._payloadsByPath[path] = nil
    end
    if self._imagesByPath[path] == nil then
      pending = true
    end
  end
  local realizedPage = false
  for _, path in ipairs(pagePaths) do
    if self._imagesByPath[path] == nil and self._payloadsByPath[path] ~= nil and not realizedPage then
      local ok, image = pcall(realizeImage, self, self._payloadsByPath[path])
      if not ok then
        return { kind = "failed", error = tostring(image) }
      end
      self._imagesByPath[path] = image
      self._payloadsByPath[path] = nil
      realizedPage = true
    end
    if self._imagesByPath[path] == nil then
      pending = true
    end
  end
  if pending then
    return { kind = "pending" }
  end
  if self._shader == nil and self._shaderFailed == nil then
    if self._shaderSource == nil then
      local ok, source = pcall(readShaderSource, SHADER_PATH)
      if not ok then
        self._shaderFailed = tostring(source)
        return { kind = "failed", error = self._shaderFailed }
      end
      self._shaderSource = source
    end
    local ok, shader = pcall(self._graphics.newShader, self._shaderSource)
    if not ok then
      self._shaderFailed = tostring(shader)
      return { kind = "failed", error = self._shaderFailed }
    end
    self._shader = shader
  end
  if self._shaderFailed ~= nil then
    return { kind = "failed", error = self._shaderFailed }
  end
  lease._readyKey = demand.key
  return { kind = "ready", key = demand.key, assets = readyBundle(self) }
end

-- Acquires one opaque per-open preparation lease. Leases own only demand
-- membership; release is idempotent and never touches borrowed owners.
---@return table<string, unknown> lease with prepare and release
function SummaryPresentationResources:acquire()
  assert(not self._released, "summary preparation is released")
  self._leases = self._leases or {}
  local owner = self
  local lease = { _owner = owner, _released = false, _watched = {}, _readyKey = nil }
  function lease:prepare(demand)
    return prepareLease(owner, self, demand)
  end
  function lease:release()
    if self._released then
      return
    end
    self._released = true
    if not owner._released then
      dropLeaseInterest(owner, self)
      -- Released leases watch nothing, so drop them from the owner set:
      -- the field lifetime outlives many per-open leases.
      for index, other in ipairs(owner._leases or {}) do
        if other == self then
          table.remove(owner._leases, index)
          break
        end
      end
    end
    self._watched = {}
  end
  self._leases[#self._leases + 1] = lease
  return lease
end

-- Idempotent release of the field lifetime: invalidates every remaining
-- lease, cancels owned decode interest, and disposes each owned GPU
-- object once. Borrowed icon, queue, text, and graphics collaborators
-- stay alive.
function SummaryPresentationResources:release()
  if self._released then
    return
  end
  self._released = true
  for _, lease in ipairs(self._leases or {}) do
    lease._released = true
    lease._watched = {}
  end
  self._leases = {}
  for path, token in pairs(self._tokensByPath) do
    pcall(self._queue.cancel, self._queue, token)
    self._tokensByPath[path] = nil
  end
  self._payloadsByPath = {}
  -- Each canonical path owns exactly one image, so releasing per path
  -- releases each owned GPU object once with no alias bookkeeping.
  for path, image in pairs(self._imagesByPath) do
    releaseOwned(image)
    self._imagesByPath[path] = nil
  end
  for cacheKey, quad in pairs(self._quads) do
    releaseOwned(quad)
    self._quads[cacheKey] = nil
    self._quadPaths[cacheKey] = nil
  end
  local shader = self._shader
  self._shader = nil
  self._shaderFailed = nil
  releaseOwned(shader)
end

return SummaryPresentationResources
