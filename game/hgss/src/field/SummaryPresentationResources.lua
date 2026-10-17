-- Field-owned Summary preparation lifetimes: one resource owner loads the
-- Summary-owned referenced metadata and the picture shader once at
-- construction, like the Party and Bag renderers, and keeps them for the
-- field lifetime. It then hands out per-open demand leases over bounded
-- per-mon demand, isolates overlapping leases by demand key and picture
-- epoch, surfaces failures instead of hanging, and returns every borrowed
-- lease exactly once while borrowed icon, pool, and text collaborators
-- stay alive. Demand per lease is the current roster icon keys, the cry
-- banks, and at most the six unique portrait pages behind the current
-- party portrait identities; eggs resolve to small Summary-owned visuals
-- and demand no portrait page. Shared pages are coalesced across leases;
-- releasing one lease never cancels a replacement lease's work. Portrait
-- pages adopt at most one new lease per prepare call while the borrowed
-- icon provider keeps its own independent bound. Every realized image is
-- borrowed from the session image owner under its canonical
-- cache-relative path; semantic names and page ids resolve to that borrow
-- instead of a second image store. Adopted portrait leases stay pinned at
-- the owner while a live lease watches them; the last release of shared
-- demand returns each borrow exactly once and its quads clear with it, so
-- a later lease re-borrows with fresh identities while the physical image
-- rests idle under the shared idle limit. Summary chrome resolves through
-- the same owner on first demand and stays pinned for the field lifetime.
-- A stale demand key can never be adopted as the selected picture.

local MonCache = require("libs.assets.src.MonCache")
local MoveIconCache = require("libs.assets.src.MoveIconCache")
local SummaryCache = require("libs.assets.src.SummaryCache")
local ImageAssetPool = require("libs.hgss.src.presentation.ImageAssetPool")

local SHADER_PATH = "libs/hgss/src/ui/shaders/summary_picture.glsl"
local MAX_PORTRAIT_PAGES = 6

-- Summary visuals sample point-filtered and clamped, matching the retired
-- direct construction, so pooled leases draw identically.
local POOLED_SAMPLER = { wrapX = "clamp", wrapY = "clamp", minFilter = "nearest", magFilter = "nearest" }

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
---@field _pool table<string, unknown> borrowed session image owner behind chrome and portrait leases
---@field _derivedAssets table<string, unknown>
---@field _manifest table<string, unknown>
---@field _moveIcons table<string, unknown> the shared move-icons manifest
---@field _portraitEntries table<string, table<string, unknown>>
---@field _chromePaths string[] unique canonical chrome paths pinned on first demand
---@field _chrome table<string, table<string, unknown>> field-lifetime chrome leases by canonical path
---@field _chromeReady boolean true once chrome leases are installed
---@field _pages table<integer, table<string, unknown>> portrait demand records by page id
---@field _leasedPortraits table<string, table<string, unknown>> adopted portrait leases by canonical path
---@field _quads table<string, unknown> realized quads by selector and frame
---@field _quadPaths table<string, string> owning page path per cached quad
---@field _shader table<string, unknown>? the one owned picture-palette shader
---@field _shaderFailed string? visible shader failure
---@field _released boolean
---@field _leases table<string, unknown>[] per-open leases in acquisition order
local SummaryPresentationResources = {}
SummaryPresentationResources.__index = SummaryPresentationResources

---@class SummaryPresentationResources.Options
---@field cacheFs table<string, unknown>
---@field graphics table<string, unknown>
---@field text table<string, unknown>
---@field icons table<string, unknown>
---@field imagePool table<string, unknown>
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
  local pool = assert(opts.imagePool, "summary preparation borrows its shared image owner")
  assert(
    type(pool.request) == "function"
      and type(pool.poll) == "function"
      and type(pool.acquire) == "function"
      and type(pool.release) == "function"
      and type(pool.cancel) == "function",
    "summary preparation drives request, poll, acquire, release, and cancel"
  )
  local derivedAssets = assert(opts.derivedAssets, "summary preparation needs its compilation seam")
  assert(type(derivedAssets) == "table", "summary preparation demands portrait pages through the provisioner")
  local manifest = assert(opts.manifest, "summary preparation needs the summary family")
  SummaryCache.validateManifest(manifest)
  local moveIcons = MoveIconCache.loadManifest(cacheFs)
  local seen = {}
  local chromePaths = {}
  local function addChrome(path)
    if seen[path] ~= true then
      seen[path] = true
      chromePaths[#chromePaths + 1] = path
    end
  end
  for _, path in ipairs(SummaryCache.referencedPaths(manifest)) do
    addChrome(path)
  end
  for _, path in ipairs(MoveIconCache.referencedPaths(moveIcons)) do
    addChrome(path)
  end
  local portraitManifest =
    assert(cacheFs:loadLua(MonCache.portraitManifestPath()), "summary preparation needs the portrait manifest")
  assert(type(portraitManifest.entries) == "table", "the portrait manifest carries entries")
  local self = setmetatable({
    _cacheFs = cacheFs,
    _graphics = graphics,
    _text = text,
    _icons = icons,
    _pool = pool,
    _derivedAssets = derivedAssets,
    _manifest = manifest,
    _portraitEntries = portraitManifest.entries,
    _moveIcons = moveIcons,
    _chromePaths = chromePaths,
    _chrome = {},
    _chromeReady = false,
    _pages = {},
    _leasedPortraits = {},
    _quads = {},
    _quadPaths = {},
    _shader = nil,
    _shaderFailed = nil,
    _released = false,
  }, SummaryPresentationResources)
  local loaded, loadErr = pcall(function()
    self:_loadShader()
  end)
  if not loaded then
    self:release()
    error(loadErr, 0)
  end
  return self
end

-- compiles the picture shader once: the picture palette blend is
-- Summary-owned non-image state, so opening a Summary never waits on
-- it. The shared exact-sampling rule splices in through the pool
-- module (this layer cannot import the platform sampler itself), so
-- indexed portrait pages resolve through their exact palette before
-- the blend math runs. A shader that fails to compile stays a visible
-- per-open failure instead of failing the field.
function SummaryPresentationResources:_loadShader()
  local ok, source = pcall(readShaderSource, SHADER_PATH)
  if not ok then
    self._shaderFailed = tostring(source)
    return
  end
  local compiled, shader = pcall(self._graphics.newShader, ImageAssetPool.withSharedSampling(source))
  if not compiled then
    self._shaderFailed = tostring(shader)
    return
  end
  self._shader = shader
end

-- Borrows one generated visual through the shared owner, waiting out its
-- classification without blocking the field longer than the bounded stall
-- budget. Failures name their path instead of preparing a blank visual.
---@param self SummaryPresentationResources
---@param path string
---@return table<string, unknown> lease resolving the immutable visual
local function acquirePinned(self, path)
  local pool = assert(self._pool, "summary preparation borrows its shared image owner")
  local token = pool:request(path, POOLED_SAMPLER, "demand")
  local stalled = 0
  while true do
    local status, failure = pool:poll(token)
    if status == "ready" then
      return pool:acquire(token)
    end
    if status == "failed" then
      error("compiled Summary image missing at " .. path .. ": " .. tostring(failure), 0)
    end
    assert(status == "pending", "summary preparation reports pending or ready")
    stalled = stalled + 1
    if stalled > 10000 then
      error("compiled Summary image stalled at " .. path, 0)
    end
    local timer = love and love.timer
    if timer ~= nil and timer.sleep ~= nil then
      timer.sleep(0.001)
    end
  end
end

-- Installs the field-lifetime chrome leases once on first demand: every
-- family-owned visual borrows the shared owner up front, so opening a
-- Summary never waits on chrome afterwards. A failed visual returns the
-- leases installed so far and fails visibly instead of pinning chrome
-- the field lifetime cannot draw.
---@param self SummaryPresentationResources
local function ensureChrome(self)
  if self._chromeReady then
    return
  end
  local pool = assert(self._pool, "summary preparation borrows its shared image owner")
  local installed = {}
  local ok, err = pcall(function()
    for _, path in ipairs(self._chromePaths) do
      if self._chrome[path] == nil then
        local lease = acquirePinned(self, path)
        self._chrome[path] = lease
        installed[#installed + 1] = lease
      end
    end
  end)
  if not ok then
    for _, lease in ipairs(installed) do
      pool:release(lease)
    end
    for path, _ in pairs(self._chrome) do
      self._chrome[path] = nil
    end
    error(err, 0)
  end
  self._chromeReady = true
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
  assert(type(demand.cryBanks) == "table", "demands carry the displayed cry banks")
  for _, bank in ipairs(demand.cryBanks) do
    assert(type(bank) == "number" and bank % 1 == 0 and bank >= 0, "cry banks arrive as bank ids")
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

---@param image table<string, unknown>? borrowed GPU object
local function releaseBorrowed(image)
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

-- Drops quads behind one released portrait page so a later borrow rebuilds
-- its quads instead of aliasing freed art.
---@param self SummaryPresentationResources
---@param path string canonical portrait page path
local function dropPageQuads(self, path)
  for cacheKey, owner in pairs(self._quadPaths) do
    if owner == path then
      releaseBorrowed(self._quads[cacheKey])
      self._quads[cacheKey] = nil
      self._quadPaths[cacheKey] = nil
    end
  end
end

-- Returns the portrait borrows the live leases no longer watch: each
-- returned borrow rests idle under the shared idle limit while a surviving
-- replacement lease keeps its coalesced demand usable without
-- re-borrowing. Tokens the live leases stopped watching cancel unstaged
-- so their worker payloads are discarded instead of retained unclaimed.
-- A surviving replacement lease keeps its demand; a failed demand changes
-- nothing, preserving the last-good picture.
---@param self SummaryPresentationResources
---@param watched table<string, boolean> canonical paths kept by live leases
local function dropUnwatchedPortraits(self, watched)
  local pool = assert(self._pool, "summary preparation borrows its shared image owner")
  for pageId, record in pairs(self._pages) do
    local path = MonCache.portraitPagePath(pageId)
    if watched[path] ~= true then
      if record.token ~= nil then
        pool:cancel(record.token)
        record.token = nil
      end
      if record.lease ~= nil then
        local lease = record.lease
        record.lease = nil
        self._leasedPortraits[path] = nil
        dropPageQuads(self, path)
        pool:release(lease)
      end
      if record.token == nil and record.lease == nil then
        self._pages[pageId] = nil
      end
    end
  end
end

-- Releases the demand interest the lease no longer owns: portrait borrows
-- no other live lease watches return to the shared owner, and their quads
-- clear with them, so the last release returns every borrow exactly once.
-- A surviving replacement lease keeps its coalesced demand without
-- re-borrowing.
---@param self SummaryPresentationResources
---@param lease table<string, unknown>
local function dropLeaseInterest(self, lease)
  lease._watched = {}
  dropUnwatchedPortraits(self, liveWatchedPaths(self))
end

---@param self SummaryPresentationResources
---@return table<string, unknown> ready bundle accessors over borrowed art
local function readyBundle(self)
  local owner = self
  local manifest = assert(owner._manifest, "summary preparation keeps its family")
  local portraits = {}
  function portraits:image(selector)
    assert(type(selector) == "string", "portrait reads name their selector")
    local entry = assert(owner._portraitEntries[selector], "the portrait manifest carries no page for " .. selector)
    local pageId = assert(entry.pageId, "the portrait entry for " .. selector .. " carries its page")
    local record = owner._pages[pageId]
    local lease = record and record.lease
    assert(lease ~= nil, "the portrait page is not prepared for " .. selector)
    return lease.image
  end
  -- The sampling handle behind one portrait selector for palette-aware
  -- draws: the adopted page lease itself, so indexed pages bind their
  -- exact palette through the shared sampler. Read-only like image.
  function portraits:handleFor(selector)
    assert(type(selector) == "string", "portrait reads name their selector")
    local entry = assert(owner._portraitEntries[selector], "the portrait manifest carries no page for " .. selector)
    local pageId = assert(entry.pageId, "the portrait entry for " .. selector .. " carries its page")
    local record = owner._pages[pageId]
    local lease = record and record.lease
    assert(lease ~= nil, "the portrait page is not prepared for " .. selector)
    return lease
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
    moveIcons = owner._moveIcons,
    text = owner._text,
    shader = assert(owner._shader, "ready preparation carries its picture shader"),
  }
  function bundle.visualImage(name)
    assert(type(name) == "string" and name ~= "", "visual reads name their record")
    local visuals = assert(manifest.visuals, "the summary family carries its visuals")
    local record = assert(visuals[name], "the summary family carries visual " .. name)
    local path = assert(record.image, "visual " .. name .. " carries its image")
    local lease = owner._chrome[path]
    assert(lease ~= nil, "visual " .. name .. " is not loaded at " .. path)
    return lease.image
  end
  -- The sampling handle behind one named visual for palette-aware
  -- draws: the installed chrome lease itself. Mirrors visualImage.
  function bundle.visualHandle(name)
    assert(type(name) == "string" and name ~= "", "visual reads name their record")
    local visuals = assert(manifest.visuals, "the summary family carries its visuals")
    local record = assert(visuals[name], "the summary family carries visual " .. name)
    local path = assert(record.image, "visual " .. name .. " carries its image")
    local lease = owner._chrome[path]
    assert(lease ~= nil, "visual " .. name .. " is not loaded at " .. path)
    return lease
  end
  function bundle.imageForPath(path)
    assert(type(path) == "string" and path ~= "", "path reads name their cache-relative path")
    local chrome = owner._chrome[path]
    if chrome ~= nil then
      return chrome.image
    end
    local portrait = owner._leasedPortraits[path]
    assert(portrait ~= nil, "no prepared image for path " .. path)
    return portrait.image
  end
  -- The sampling handle behind one canonical path for palette-aware
  -- draws: the chrome or portrait lease itself. Mirrors imageForPath.
  function bundle.handleForPath(path)
    assert(type(path) == "string" and path ~= "", "path reads name their cache-relative path")
    local chrome = owner._chrome[path]
    if chrome ~= nil then
      return chrome
    end
    local portrait = owner._leasedPortraits[path]
    assert(portrait ~= nil, "no prepared image for path " .. path)
    return portrait
  end
  return bundle
end

---@param self SummaryPresentationResources
---@param pageId integer
---@return table<string, unknown> the mutable demand record for the page
local function pageRecord(self, pageId)
  local record = self._pages[pageId]
  if record == nil then
    record = { token = nil, lease = nil }
    self._pages[pageId] = record
  end
  return record
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
  for _, pageId in ipairs(pages) do
    watched[#watched + 1] = MonCache.portraitPagePath(pageId)
  end
  lease._watched = watched
  -- Every independent prerequisite enrolls before the first pending
  -- answer: roster icons through the borrowed provider, portrait page
  -- compilation and cry bank readiness through the provisioner seam, and
  -- portrait image requests through the shared owner. Nothing enrolled
  -- here is released; readiness evaluates only after all of it is in
  -- flight, so one unready family never serializes the others.
  -- Roster icons ride the borrowed provider with its own lifetime: never
  -- cancelled or released here, only observed ready or failed.
  local iconsReady = false
  local iconsFailure = nil
  do
    local ok, ready, failure = pcall(self._icons.prepareKeys, self._icons, demand.iconKeys)
    if not ok then
      iconsFailure = tostring(ready)
    elseif failure ~= nil then
      iconsFailure = tostring(failure)
    else
      iconsReady = ready
    end
  end
  -- Portrait compilation through the existing provisioner seam: a named
  -- failure surfaces, an unready page waits, and dispatched jobs are
  -- never cancelled from here. A missing seam fails visibly instead of
  -- hanging the lease. Pages with an adopted lease never recompile, so
  -- overlapping leases compile each shared page once.
  local portraitPending = false
  local portraitFailure = nil
  local requestPage = self._derivedAssets.requestMonPortraitPage
  if type(requestPage) ~= "function" then
    portraitFailure = "portrait compilation is unavailable"
  else
    for _, pageId in ipairs(pages) do
      local record = self._pages[pageId]
      if record == nil or (record.lease == nil and record.token == nil) then
        local ok, ready, failure = pcall(requestPage, pageId, "required")
        if not ok then
          portraitFailure = tostring(ready)
          break
        elseif failure ~= nil then
          portraitFailure = tostring(failure)
          break
        elseif not ready then
          portraitPending = true
        end
      end
    end
  end
  -- Cry banks compile through the same provisioner seam so the summary
  -- never plays a cry whose bank is not in the generated cache. Banks
  -- enroll even while portraits are still decoding, so a cached portrait
  -- never hides a pending cry bank.
  local cryPending = false
  local cryFailure = nil
  local requestBank = self._derivedAssets.requestAudioBank
  if type(requestBank) ~= "function" then
    cryFailure = "audio bank compilation is unavailable"
  else
    for _, bankId in ipairs(demand.cryBanks) do
      local ok, ready, failure = pcall(requestBank, bankId, "required")
      if not ok then
        cryFailure = tostring(ready)
        break
      elseif failure ~= nil then
        cryFailure = tostring(failure)
        break
      elseif not ready then
        cryPending = true
      end
    end
  end
  -- Portrait image requests enroll through the shared owner for every page
  -- without an adopted lease or an outstanding request, so one shared page
  -- borrows once no matter how many leases watch it.
  local pool = assert(self._pool, "summary preparation borrows its shared image owner")
  for _, pageId in ipairs(pages) do
    local record = pageRecord(self, pageId)
    if record.lease == nil and record.token == nil then
      record.token = pool:request(MonCache.portraitPagePath(pageId), POOLED_SAMPLER, "demand")
    end
  end
  if iconsFailure ~= nil then
    return { kind = "failed", error = iconsFailure }
  end
  if portraitFailure ~= nil then
    return { kind = "failed", error = portraitFailure }
  end
  if cryFailure ~= nil then
    return { kind = "failed", error = cryFailure }
  end
  local pending = portraitPending or cryPending
  -- Portrait pages adopt at most one new lease per call so a cold open
  -- never uploads the party at once. A failed request forgets its token
  -- and names its cause; the next round re-enrolls it.
  local adopted = false
  for _, pageId in ipairs(pages) do
    local record = assert(self._pages[pageId], "demand enrolls every page before polling")
    if record.lease == nil and record.token ~= nil and not adopted then
      local status, cause = pool:poll(record.token)
      if status == "failed" then
        pool:cancel(record.token)
        record.token = nil
        return { kind = "failed", error = tostring(cause) }
      elseif status == "ready" then
        local adoptedLease = pool:acquire(record.token)
        record.token = nil
        record.lease = adoptedLease
        self._leasedPortraits[MonCache.portraitPagePath(pageId)] = adoptedLease
        adopted = true
      else
        pending = true
      end
    end
    if record.lease == nil then
      pending = true
    end
  end
  if not iconsReady then
    pending = true
  end
  -- Summary chrome pins on the first demand that reaches polling: every
  -- family-owned visual borrows the shared owner up front, so later opens
  -- never wait on chrome. Chrome failures surface like any other missing
  -- visual while the adopted portrait leases stay pinned.
  if not pending then
    local chromeOk, chromeErr = pcall(ensureChrome, self)
    if not chromeOk then
      return { kind = "failed", error = tostring(chromeErr) }
    end
  end
  if pending then
    return { kind = "pending" }
  end
  if self._shaderFailed ~= nil then
    return { kind = "failed", error = self._shaderFailed }
  end
  lease._readyKey = demand.key
  -- Stale portrait interest releases only now that the replacement covers
  -- the visible state: borrows no live lease watches return to the shared
  -- owner while the committed demand keeps its coalesced pages.
  dropUnwatchedPortraits(self, liveWatchedPaths(self))
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
-- lease and returns every adopted portrait and chrome borrow exactly once.
-- Returned borrows rest idle under the shared idle limit; the borrowed
-- icon, pool, text, and graphics collaborators stay alive.
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
  local pool = assert(self._pool, "summary preparation borrows its shared image owner")
  for pageId, record in pairs(self._pages) do
    if record.token ~= nil then
      record.token = nil
    end
    if record.lease ~= nil then
      pool:release(record.lease)
      record.lease = nil
    end
    self._pages[pageId] = nil
  end
  self._leasedPortraits = {}
  for path, lease in pairs(self._chrome) do
    pool:release(lease)
    self._chrome[path] = nil
  end
  self._chromeReady = false
  for cacheKey, quad in pairs(self._quads) do
    releaseBorrowed(quad)
    self._quads[cacheKey] = nil
    self._quadPaths[cacheKey] = nil
  end
  local shader = self._shader
  self._shader = nil
  self._shaderFailed = nil
  releaseBorrowed(shader)
end

return SummaryPresentationResources
