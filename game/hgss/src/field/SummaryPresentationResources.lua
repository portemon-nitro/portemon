-- Field-owned Summary preparation lifetimes: one resource owner hands
-- out per-open demand leases over bounded portrait demand, isolates
-- overlapping leases by demand key and picture epoch, surfaces failures
-- instead of hanging, and releases every owned GPU object exactly once
-- while borrowed icon, queue, and text collaborators stay alive. Demand
-- per lease is the Summary-owned referenced visuals plus the shader, the
-- current roster icon keys, and at most the six unique portrait pages
-- behind the current party picture selectors; eggs resolve to small
-- Summary-owned visuals and demand no portrait page. Shared pages are
-- coalesced across leases; releasing one lease never cancels a
-- replacement lease's work. Portrait pages realize at most one new page
-- per prepare call while the borrowed icon provider keeps its own
-- independent bound. Realized art stays cached at the owner while a live
-- lease watches it; the last release of shared demand frees each owned
-- object exactly once. A stale demand key can never be adopted as the
-- selected picture.

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
---@field _barPieces { rule: string, kind: string, path: string }[]
---@field _eggPath string?
---@field _images table<string, table<string, unknown>> realized visuals by visual key
---@field _tokens table<string, unknown> decode tokens by visual key
---@field _payloads table<string, table<string, unknown>> decoded payloads awaiting realization
---@field _pageImages table<integer, table<string, unknown>> realized portrait page images
---@field _quads table<string, unknown> realized quads by selector key
---@field _shader table<string, unknown>? the one owned picture-palette shader
---@field _shaderFailed string? visible shader failure
---@field _shaderSource string?
---@field _released boolean
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

---@param manifest table<string, unknown>
---@return { rule: string, kind: string, path: string }[] bar piece records
local function barPieces(manifest)
  local pieces = {}
  local bars = manifest.bars
  if type(bars) ~= "table" then
    return pieces
  end
  for _, rule in ipairs({ "hp", "exp" }) do
    local entry = bars[rule]
    if type(entry) == "table" then
      for _, kind in ipairs({ "empty", "full" }) do
        local visual = entry[kind]
        if type(visual) == "table" and type(visual.image) == "string" then
          pieces[#pieces + 1] = { rule = rule, kind = kind, path = visual.image }
        end
      end
    end
  end
  return pieces
end

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
  local eggPath = nil
  local pictures = manifest.pictures
  if type(pictures) == "table" and type(pictures.EGG) == "table" then
    local visual = pictures.EGG.visual
    if type(visual) == "string" then
      eggPath = visual
    end
  end
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
    _barPieces = barPieces(manifest),
    _eggPath = eggPath,
    _images = {},
    _tokens = {},
    _payloads = {},
    _pageImages = {},
    _quads = {},
    _shader = nil,
    _shaderFailed = nil,
    _shaderSource = nil,
    _released = false,
  }, SummaryPresentationResources)
end

---@param self SummaryPresentationResources
---@param key string roster picture key (species or full portrait selector)
---@return integer? portrait page, or nil for egg art
local function pageForKey(self, key)
  assert(type(key) == "string" and key ~= "", "roster picture keys arrive as strings")
  if key == "EGG" then
    return nil
  end
  local entries = assert(self._portraitEntries, "summary preparation keeps its portrait entries")
  if key:find("/", 1, true) ~= nil then
    local entry = entries[key]
    if entry == nil and key:find("/male/", 1, true) ~= nil then
      entry = entries[key:gsub("/male/", "/female/")]
    end
    assert(type(entry) == "table", "the portrait manifest carries selector " .. key)
    local pageId = assert(entry.pageId, "portrait entries carry their page")
    assert(type(pageId) == "number", "portrait pages are numeric")
    return pageId
  end
  local direct = entries[key .. "/f0/male/plain"]
  if type(direct) == "table" and type(direct.pageId) == "number" then
    return direct.pageId
  end
  local prefix = key .. "/"
  local match = nil
  for selector in pairs(entries) do
    if type(selector) == "string" and selector:sub(1, #prefix) == prefix then
      if match == nil or selector < match then
        match = selector
      end
    end
  end
  assert(type(match) == "string", "the portrait manifest carries species " .. key)
  local pageId = assert(entries[match].pageId, "portrait entries carry their page")
  assert(type(pageId) == "number", "portrait pages are numeric")
  return pageId
end

---@param demand table<string, unknown>
local function checkDemand(demand)
  assert(type(demand) == "table", "preparation demands arrive as records")
  assert(type(demand.key) == "string" and demand.key ~= "", "demands carry their key")
  assert(type(demand.revision) == "number", "demands carry the roster revision")
  assert(type(demand.pictureEpoch) == "number", "demands carry the picture epoch")
  assert(type(demand.rosterPictureKeys) == "table", "demands carry roster picture keys")
  assert(#demand.rosterPictureKeys <= MAX_PORTRAIT_PAGES, "portrait demand stays within the current party")
  for _, key in ipairs(demand.rosterPictureKeys) do
    assert(type(key) == "string" and key ~= "", "roster picture keys arrive as strings")
  end
  assert(type(demand.iconKeys) == "table", "demands carry roster icon keys")
  for _, key in ipairs(demand.iconKeys) do
    assert(type(key) == "string" and key ~= "", "roster icon keys arrive as strings")
  end
end

---@param self SummaryPresentationResources
---@param demand table<string, unknown>
---@return integer[] sorted unique portrait pages behind the roster keys
local function demandPages(self, demand)
  local seen = {}
  local pages = {}
  for _, key in ipairs(demand.rosterPictureKeys) do
    local pageId = pageForKey(self, key)
    if pageId ~= nil and not seen[pageId] then
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
---@param key string visual key
---@param path string cache-relative image path
---@return "ready"|"pending"|"failed", string?
local function advanceDecode(self, key, path)
  if self._images[key] ~= nil then
    return "ready"
  end
  if self._payloads[key] ~= nil then
    return "ready"
  end
  local token = self._tokens[key]
  if token == nil then
    local ok, requested = pcall(self._queue.request, self._queue, "image", path, "demand")
    if not ok then
      return "failed", tostring(requested)
    end
    self._tokens[key] = requested
    token = requested
  end
  local ok, pollState, pollCause = pcall(self._queue.poll, self._queue, token)
  if not ok then
    self._tokens[key] = nil
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
    self._tokens[key] = nil
    return "failed", tostring(cause)
  end
  if state == "ready" then
    local takeOk, payload = pcall(self._queue.take, self._queue, token)
    self._tokens[key] = nil
    if not takeOk then
      return "failed", tostring(payload)
    end
    assert(type(payload) == "table", "decoded payloads arrive as records")
    payload.path = payload.path or path
    self._payloads[key] = payload
    return "ready"
  end
  return "pending"
end

-- Releases demand interest the lease no longer owns: tokens no other live
-- lease watches cancel through the borrowed queue; realized images stay
-- cached at the owner for their lifetime.
---@param self SummaryPresentationResources
---@param lease table<string, unknown>
---@return table<string, boolean> demand keys still watched by another live lease
local function liveWatchedKeys(self, lease)
  local watched = {}
  for _, other in pairs(self._leases or {}) do
    if other ~= lease and other._released ~= true and type(other._watched) == "table" then
      for _, key in ipairs(other._watched) do
        watched[key] = true
      end
    end
  end
  return watched
end

-- Disposes owned art no live lease watches anymore: the last release of
-- shared demand frees each realized object exactly once, while a
-- surviving replacement lease keeps its coalesced demand usable without
-- re-decoding. Alias keys ride the same object guard as the release path.
---@param self SummaryPresentationResources
---@param watched table<string, boolean> demand keys kept by other live leases
local function dropUnwatchedArt(self, watched)
  local keepObject = {}
  for key, image in pairs(self._images) do
    if watched[key] == true then
      keepObject[image] = true
    end
  end
  for pageId, image in pairs(self._pageImages) do
    if watched["page:" .. pageId] == true then
      keepObject[image] = true
    end
  end
  local dropped = false
  for key, image in pairs(self._images) do
    if keepObject[image] ~= true then
      if type(image) == "table" or type(image) == "userdata" then
        if type(image.release) == "function" then
          pcall(image.release, image)
        end
      end
      keepObject[image] = true
      self._images[key] = nil
      dropped = true
    end
  end
  for pageId, image in pairs(self._pageImages) do
    if keepObject[image] ~= true then
      if type(image) == "table" or type(image) == "userdata" then
        if type(image.release) == "function" then
          pcall(image.release, image)
        end
      end
      keepObject[image] = true
      self._pageImages[pageId] = nil
      dropped = true
    end
  end
  for key, _ in pairs(self._payloads) do
    if watched[key] ~= true then
      self._payloads[key] = nil
      dropped = true
    end
  end
  if dropped then
    self._quads = {}
  end
end
-- Releases demand interest the lease no longer owns: tokens no other live
-- lease watches cancel through the borrowed queue, and realized art no
-- live lease watches disposes so the last release frees every owned
-- object exactly once. A surviving replacement lease keeps its coalesced
-- demand without re-decoding.
---@param self SummaryPresentationResources
---@param lease table<string, unknown>
local function dropLeaseInterest(self, lease)
  local watched = liveWatchedKeys(self, lease)
  for _, key in ipairs(lease._watched or {}) do
    if not watched[key] and self._images[key] == nil and self._payloads[key] == nil then
      local token = self._tokens[key]
      if token ~= nil then
        pcall(self._queue.cancel, self._queue, token)
        self._tokens[key] = nil
      end
    end
  end
  dropUnwatchedArt(self, watched)
  lease._watched = {}
end

---@param self SummaryPresentationResources
---@return table<string, unknown> ready bundle accessors over realized art
local function readyBundle(self)
  local owner = self
  local portraits = {}
  function portraits:image(selector)
    assert(type(selector) == "string", "portrait reads name their selector")
    local entry = assert(owner._portraitEntries[selector], "the portrait manifest carries " .. selector)
    local image = assert(owner._pageImages[entry.pageId], "the portrait page is not prepared for " .. selector)
    return image
  end
  function portraits:quadFor(selector, frameIndex)
    assert(type(selector) == "string", "portrait reads name their selector")
    local entry = assert(owner._portraitEntries[selector], "the portrait manifest carries " .. selector)
    local frames = assert(entry.frames, "portrait entries carry frames")
    local frame = frames[frameIndex or 1] or assert(frames[1], "portrait entries carry frames")
    local cacheKey = selector .. "#" .. tostring(frameIndex or 1)
    local quad = owner._quads[cacheKey]
    if quad == nil then
      local image = portraits:image(selector)
      quad = owner._graphics.newQuad(frame.x, frame.y, frame.width, frame.height, image:getWidth(), image:getHeight())
      owner._quads[cacheKey] = quad
    end
    return quad
  end
  function portraits:dimensions(selector)
    assert(type(selector) == "string", "portrait reads name their selector")
    local entry = assert(owner._portraitEntries[selector], "the portrait manifest carries " .. selector)
    return { width = entry.width, height = entry.height }
  end
  local bundle = {
    manifest = owner._manifest,
    portraits = portraits,
    icons = owner._icons,
    text = owner._text,
    shader = owner._shader,
  }
  function bundle.visualImage(name)
    return owner._images[name]
  end
  local function visualByName(_, name)
    return owner._images[name]
  end
  bundle.visuals = setmetatable({}, { __index = visualByName })
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
  local pages = demandPages(self, demand)
  local watched = {}
  for _, path in ipairs(self._visualPaths) do
    watched[#watched + 1] = "visual:" .. path
  end
  for _, piece in ipairs(self._barPieces) do
    watched[#watched + 1] = "bar:" .. piece.rule .. "-" .. piece.kind
  end
  if self._eggPath ~= nil then
    watched[#watched + 1] = "egg"
  end
  for _, pageId in ipairs(pages) do
    watched[#watched + 1] = "page:" .. pageId
  end
  lease._watched = watched
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
    if self._pageImages[pageId] == nil and self._payloads["page:" .. pageId] == nil then
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
  local function decodeVisual(key, path)
    local state, cause = advanceDecode(self, key, path)
    if state == "failed" then
      return cause
    end
    if state == "pending" then
      pending = true
    end
    return nil
  end
  for _, path in ipairs(self._visualPaths) do
    local failure = decodeVisual("visual:" .. path, path)
    if failure ~= nil then
      return { kind = "failed", error = failure }
    end
  end
  for _, pageId in ipairs(pages) do
    local failure = decodeVisual("page:" .. pageId, MonCache.portraitPagePath(pageId))
    if failure ~= nil then
      return { kind = "failed", error = failure }
    end
  end
  -- Realize decoded visuals as they arrive; portrait pages realize at
  -- most one new page per call so a cold open never uploads the party at
  -- once. Realization failures name their page.
  for key, payload in pairs(self._payloads) do
    if self._images[key] == nil then
      local isPage = key:sub(1, 5) == "page:"
      if not isPage then
        local ok, image = pcall(realizeImage, self, payload)
        if not ok then
          return { kind = "failed", error = tostring(image) }
        end
        self._images[key] = image
        self._payloads[key] = nil
      end
    end
  end
  local realizedPage = false
  for _, pageId in ipairs(pages) do
    local key = "page:" .. pageId
    if self._pageImages[pageId] == nil and self._payloads[key] ~= nil and not realizedPage then
      local ok, image = pcall(realizeImage, self, self._payloads[key])
      if not ok then
        return { kind = "failed", error = tostring(image) }
      end
      self._pageImages[pageId] = image
      self._payloads[key] = nil
      realizedPage = true
    end
    if self._pageImages[pageId] == nil then
      pending = true
    end
  end
  if pending then
    return { kind = "pending" }
  end
  -- Bar pieces and the egg visual register under their bundle keys once
  -- their referenced image realizes.
  for _, piece in ipairs(self._barPieces) do
    local image = self._images["visual:" .. piece.path]
    if image ~= nil then
      self._images[piece.rule .. "-" .. piece.kind] = image
    end
  end
  if self._eggPath ~= nil then
    local egg = self._images["visual:" .. self._eggPath]
    if egg ~= nil then
      self._images.egg = egg
    end
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
  for key, token in pairs(self._tokens) do
    pcall(self._queue.cancel, self._queue, token)
    self._tokens[key] = nil
  end
  self._payloads = {}
  -- Bundle keys alias shared art (bar pieces and the egg visual ride
  -- their realized image under two keys): release each owned GPU object
  -- once by identity so aliases never double-release.
  local released = {}
  local function releaseOwned(image)
    if image == nil or released[image] == true then
      return
    end
    released[image] = true
    if type(image) == "table" or type(image) == "userdata" then
      if type(image.release) == "function" then
        pcall(image.release, image)
      end
    end
  end
  for key, image in pairs(self._images) do
    releaseOwned(image)
    self._images[key] = nil
  end
  for pageId, image in pairs(self._pageImages) do
    releaseOwned(image)
    self._pageImages[pageId] = nil
  end
  self._quads = {}
  local shader = self._shader
  self._shader = nil
  if type(shader) == "table" and type(shader.release) == "function" then
    pcall(shader.release, shader)
  end
end

return SummaryPresentationResources
