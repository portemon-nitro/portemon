-- Runtime owner of the compiled mon icon page demand. Construction loads and
-- validates the generated icon layout metadata only and builds the
-- page-to-entries index; no GPU image is realized there. The visible party
-- demands exactly the pages behind its current icon keys through
-- prepareKeys, which enrolls compilation readiness plus one shared-owner
-- image request per page, then adopts at most one new page lease per call.
-- Page images live in the borrowed session image owner: adopted leases pin
-- the demanded pages while released demand rests idle under the shared idle
-- limit instead of a provider-specific evictor. Getters stay read-only: an
-- unprepared page is a loud error, never a blank icon or a draw-time load.
-- Portrait pages are never acquired here: the visible party demands its icon
-- pages through prepareKeys, and portraits stay on demand elsewhere.

local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.hgss.src.field.FieldErrors")
local ImageAssetPool = require("libs.hgss.src.presentation.ImageAssetPool")
local MonCache = require("libs.assets.src.MonCache")

---@class MonIconSamplingHandle
---@field image table<string, unknown> adopted page image behind the selector
---@field palette table<string, unknown>? exact RGBA palette for indexed pages
---@field kind string? payload representation of the page image
---@field width integer? adopted page width in pixels
---@field height integer? adopted page height in pixels
---@field draw fun(self: MonIconSamplingHandle, graphics: love.graphics, x: number, y: number, ...: unknown) palette-exact sampler draw shared with pool leases
---@field drawQuad fun(self: MonIconSamplingHandle, graphics: love.graphics, quad: love.Quad, x: number, y: number, ...: unknown) palette-exact viewport draw shared with pool leases

---@class MonIconAssetProvider
---@field _graphics love.graphics
---@field _cacheFs CacheFs
---@field _manifest table<string, unknown>
---@field _pageEntries table<integer, table<string, unknown>[]> validated entries by zero-based page id
---@field _pages table<integer, table<string, unknown>> demand interest by zero-based page id
---@field _pool table<string, unknown> borrowed session image owner behind every page lease
---@field _derivedAssets table<string, unknown>? borrowed semantic cache host
---@field _leases table<integer, table<string, unknown>> adopted page leases by zero-based page id
---@field _handles table<integer, table<string, unknown>> sampling handles over the adopted leases
---@field _quads table<string, love.Quad>
---@field _released boolean
local MonIconAssetProvider = {}
MonIconAssetProvider.__index = MonIconAssetProvider

-- The published icon manifest arrives through the staged writer boundary,
-- which already proved the full contract: construction only needs the
-- manifest present with the current schema and an entry record. Page-bound
-- safety stays with the publication gate plus per-realization bounds checks.
---@param cacheFs CacheFs
---@return table<string, unknown>
local function loadManifest(cacheFs)
  local manifest = cacheFs:loadLua(MonCache.iconManifestPath())
  if type(manifest) ~= "table" then
    Errors.raise(
      FieldErrors.MON_ICON_MANIFEST_UNAVAILABLE,
      "no compiled mon icon manifest at " .. MonCache.iconManifestPath(),
      { path = MonCache.iconManifestPath() }
    )
  end
  assert(type(manifest) == "table", "the icon manifest carries its entries")
  if manifest.schema ~= MonCache.ICON_MANIFEST_SCHEMA or type(manifest.entries) ~= "table" then
    Errors.raise(
      FieldErrors.MON_ICON_MANIFEST_UNAVAILABLE,
      "the compiled mon icon manifest is invalid: " .. MonCache.iconManifestPath(),
      { path = MonCache.iconManifestPath() }
    )
  end
  return manifest
end

---@param manifest table<string, unknown>
---@param iconKey string
---@return table<string, unknown>
local function entryFor(manifest, iconKey)
  assert(type(iconKey) == "string" and iconKey ~= "", "icon selection requires a semantic key")
  local entry = manifest.entries[iconKey]
  if entry == nil then
    Errors.raise(FieldErrors.MON_ICON_UNKNOWN_KEY, "unknown mon icon key " .. iconKey, { iconKey = iconKey })
  end
  assert(entry ~= nil, "the manifest carries the resolved entry")
  return entry
end

---@param manifest table<string, unknown>
---@return table<integer, table<string, unknown>[]>
local function indexEntriesByPage(manifest)
  local index = {}
  for _, entry in pairs(manifest.entries) do
    local pageId = entry.pageId
    local bucket = index[pageId]
    if bucket == nil then
      bucket = {}
      index[pageId] = bucket
    end
    bucket[#bucket + 1] = entry
  end
  return index
end

---@param cacheFs CacheFs
---@param opts { graphics?: love.graphics, imagePool: table<string, unknown>, derivedAssets?: table<string, unknown> }?
---@return MonIconAssetProvider
function MonIconAssetProvider.new(cacheFs, opts)
  assert(cacheFs ~= nil, "MonIconAssetProvider requires a CacheFs")
  opts = opts or {}
  local graphics = opts.graphics
  if graphics == nil then
    graphics = love and love.graphics
  end
  assert(graphics and graphics.newImage and graphics.newQuad, "MonIconAssetProvider requires love.graphics")
  local pool = assert(opts.imagePool, "MonIconAssetProvider borrows its shared image owner")
  assert(
    type(pool.request) == "function"
      and type(pool.poll) == "function"
      and type(pool.acquire) == "function"
      and type(pool.release) == "function"
      and type(pool.cancel) == "function",
    "MonIconAssetProvider borrows request, poll, acquire, release, and cancel from its image owner"
  )
  local manifest = loadManifest(cacheFs)
  return setmetatable({
    _graphics = graphics,
    _cacheFs = cacheFs,
    _manifest = manifest,
    _pageEntries = indexEntriesByPage(manifest),
    _pages = {},
    _pool = pool,
    _derivedAssets = opts.derivedAssets,
    _leases = {},
    _handles = {},
    _quads = {},
    _released = false,
  }, MonIconAssetProvider)
end

-- Icon pages sample point-filtered and clamped, matching the retired
-- direct construction, so pooled leases draw identically.
local POOLED_SAMPLER = { wrapX = "clamp", wrapY = "clamp", minFilter = "nearest", magFilter = "nearest" }

---@param self MonIconAssetProvider
---@param pageId integer
---@return table<string, unknown> the mutable demand record for the page
local function pageState(self, pageId)
  local state = self._pages[pageId]
  if state == nil then
    state = { token = nil, failure = nil }
    self._pages[pageId] = state
  end
  return state
end

---@param self MonIconAssetProvider
---@param iconKeys string[]
---@return integer[] sorted unique page ids behind the keys
local function uniquePages(self, iconKeys)
  assert(type(iconKeys) == "table", "icon preparation requires the visible icon keys")
  local seen = {}
  local pages = {}
  for _, iconKey in ipairs(iconKeys) do
    local entry = entryFor(self._manifest, iconKey)
    local pageId = entry.pageId
    if not seen[pageId] then
      seen[pageId] = true
      pages[#pages + 1] = pageId
    end
  end
  table.sort(pages)
  return pages
end

---@param self MonIconAssetProvider
---@param pageId integer
---@param lease table<string, unknown> adopted shared page lease
local function validateLeaseBounds(self, pageId, lease)
  local width = assert(lease.width, "shared icon leases carry their page width")
  local height = assert(lease.height, "shared icon leases carry their page height")
  for _, entry in ipairs(assert(self._pageEntries[pageId], "the page index carries the realized page")) do
    for _, frame in ipairs(entry.frames) do
      assert(frame.x + frame.width <= width and frame.y + frame.height <= height, "icon frame exceeds its page")
    end
  end
end

-- Enrolls one demanded page once: compilation readiness through the
-- semantic cache host, then one shared-owner image request. A page that is
-- already enrolled, leased, or failed enrolls nothing more, so shared pages
-- deduplicate and the unrelated pages stay untouched. Missing compiled
-- bytes fail the page with its path instead of enrolling pool work that
-- could never stage.

---@param self MonIconAssetProvider
---@param pageId integer
local function enrollPage(self, pageId)
  local state = pageState(self, pageId)
  if state.token ~= nil or self._leases[pageId] ~= nil or state.failure ~= nil then
    return
  end
  local derivedAssets = assert(self._derivedAssets, "presented icon preparation requires the semantic cache host")
  local ok, ready, failure = pcall(derivedAssets.requestIconPage, pageId, "required")
  if not ok then
    state.failure = tostring(ready)
    return
  end
  if failure ~= nil then
    state.failure = tostring(failure)
    return
  end
  if not ready then
    return
  end
  local path = MonCache.iconPagePath(pageId)
  if self._cacheFs:read(path) == nil then
    state.failure = "mon icon page missing at " .. path
    return
  end
  state.token = self._pool:request(path, POOLED_SAMPLER, "demand")
end

-- Returns the leases the current demand no longer covers: each returned
-- borrow rests idle under the shared idle limit while quads behind a
-- released page clear with it, so getters never alias freed art and a
-- later demand re-borrows with fresh identities.
---@param self MonIconAssetProvider
---@param pages integer[] sorted unique page ids behind the current demand
local function releaseUndemandedLeases(self, pages)
  local wanted = {}
  for _, pageId in ipairs(pages) do
    wanted[pageId] = true
  end
  local pool = assert(self._pool, "the icon provider borrows its shared image owner")
  local evicted = {}
  for pageId, state in pairs(self._pages) do
    if not wanted[pageId] then
      -- Pending interest is cancelled unstaged: enrolled-but-unpolled
      -- worker payloads are discarded instead of retained unclaimed,
      -- while adopted leases below rest idle under the shared limit.
      if state.token ~= nil then
        pool:cancel(state.token)
        state.token = nil
      end
      self._pages[pageId] = nil
      local lease = self._leases[pageId]
      if lease ~= nil then
        evicted[pageId] = true
        self._leases[pageId] = nil
        self._handles[pageId] = nil
        pool:release(lease)
      end
    end
  end
  if next(evicted) ~= nil then
    for iconKey, entry in pairs(self._manifest.entries) do
      if evicted[entry.pageId] == true then
        for frameIndex = 1, #entry.frames do
          self._quads[iconKey .. "#" .. frameIndex] = nil
        end
      end
    end
  end
end

-- Adopts one staged page without enforcing the per-advance budget: the
-- caller polls progressively and stops after the first adoption, so at
-- most one new GPU page lands per preparation update while pending pages
-- keep polling without staging.

-- Advances the demanded pages one step: every independent page enrolls
-- its compilation readiness plus its shared-owner image request first, then
-- enrolled requests poll progressively with at most one new page adoption
-- per call. Returns whether the full key set is ready and the first page
-- failure, if any. Unknown keys fail the round as a visible error instead
-- of enrolling partial work. Pending rounds keep every adopted lease (last
-- known good) and failed rounds change nothing, so replacing demand never
-- strands a borrower mid-transition.
---@param iconKeys string[]
---@return boolean ready
---@return string? failure
function MonIconAssetProvider:prepareKeys(iconKeys)
  assert(not self._released, "the icon provider is released")
  assert(self._derivedAssets, "presented icon preparation requires the semantic cache host")
  local pool = assert(self._pool, "the icon provider borrows its shared image owner")
  local ok, pages = pcall(uniquePages, self, iconKeys)
  if not ok then
    return false, tostring(pages)
  end
  assert(pages ~= nil, "icon keys resolve to demanded pages")
  for _, pageId in ipairs(pages) do
    enrollPage(self, pageId)
  end
  local allReady = true
  local firstFailure = nil
  local adopted = false
  for _, pageId in ipairs(pages) do
    local state = assert(self._pages[pageId], "demand enrolls every page before polling")
    if self._leases[pageId] ~= nil then
      -- Already adopted for the current demand; nothing to do.
    elseif state.failure ~= nil then
      allReady = false
      if firstFailure == nil then
        firstFailure = state.failure
      end
    elseif state.token ~= nil and not adopted then
      local status, cause = pool:poll(state.token)
      if status == "failed" then
        pool:cancel(state.token)
        state.token = nil
        state.failure = tostring(cause)
        allReady = false
        if firstFailure == nil then
          firstFailure = state.failure
        end
      elseif status == "ready" then
        local lease = pool:acquire(state.token)
        state.token = nil
        local boundsOk, boundsErr = pcall(validateLeaseBounds, self, pageId, lease)
        if not boundsOk then
          pool:release(lease)
          state.failure = tostring(boundsErr)
          allReady = false
          if firstFailure == nil then
            firstFailure = state.failure
          end
        else
          self._leases[pageId] = lease
          -- Sampling handles share the pool-lease draw surface so icon
          -- consumers behind unimportable layers draw through the exact
          -- sampler with zero new imports; the record shape is unchanged.
          self._handles[pageId] = setmetatable({
            image = assert(lease.image, "shared leases carry their page image"),
            palette = lease.palette,
            kind = lease.kind,
            width = lease.width,
            height = lease.height,
          }, ImageAssetPool.Lease)
          adopted = true
        end
      else
        allReady = false
      end
    else
      allReady = false
    end
  end
  if allReady then
    releaseUndemandedLeases(self, pages)
  end
  return allReady, firstFailure
end

-- Drops pending image interest without touching adopted page leases:
-- unenrolled tokens cancel through the shared owner so their worker
-- payloads are discarded, and compiled pages wait for a fresh request on
-- the next round. Adopted leases survive for reopen and reorder; release
-- owns their lifetime instead.
function MonIconAssetProvider:cancelPreparation()
  local pool = assert(self._pool, "the icon provider borrows its shared image owner")
  for _, state in pairs(self._pages) do
    if state.token ~= nil then
      pool:cancel(state.token)
      state.token = nil
    end
  end
end

-- The page image carrying one icon selector. Selectors sharing a page
-- share its leased image; selectors on different pages resolve to their
-- own. Read-only: an unprepared page is a loud error, never a blank icon.
---@param iconKey string
---@return love.Image the page image for draw calls
function MonIconAssetProvider:image(iconKey)
  assert(not self._released, "the icon provider is released")
  local entry = entryFor(self._manifest, iconKey)
  local lease = self._leases[entry.pageId]
  assert(lease ~= nil, "the icon page is not prepared for " .. iconKey)
  return lease.image
end

-- The sampling handle carrying one icon selector for palette-aware draws:
-- the cached record over the adopted page lease, so indexed pages bind
-- their exact palette through the shared sampler instead of rendering
-- index bytes. Read-only like image: an unprepared page is a loud error.
---@param iconKey string
---@return MonIconSamplingHandle sampling handle carrying the adopted page lease surface
function MonIconAssetProvider:handleFor(iconKey)
  assert(not self._released, "the icon provider is released")
  local entry = entryFor(self._manifest, iconKey)
  local handle = self._handles[entry.pageId]
  assert(handle ~= nil, "the icon page is not prepared for " .. iconKey)
  return handle
end

---@param iconKey string
---@param frameIndex integer?
---@return love.Quad quad
function MonIconAssetProvider:quadFor(iconKey, frameIndex)
  assert(not self._released, "the icon provider is released")
  frameIndex = frameIndex or 1
  assert(type(frameIndex) == "number" and frameIndex % 1 == 0 and frameIndex >= 1, "icon frame index starts at one")
  local entry = entryFor(self._manifest, iconKey)
  assert(frameIndex <= #entry.frames, "icon frame " .. frameIndex .. " is missing for " .. iconKey)
  local cacheKey = iconKey .. "#" .. frameIndex
  local quad = self._quads[cacheKey]
  if quad == nil then
    local frame = entry.frames[frameIndex]
    local lease = self._leases[entry.pageId]
    assert(lease ~= nil, "the icon page is not prepared for " .. iconKey)
    local image = assert(lease.image, "shared leases carry their page image")
    quad = self._graphics.newQuad(frame.x, frame.y, frame.width, frame.height, image:getWidth(), image:getHeight())
    self._quads[cacheKey] = quad
  end
  return quad
end

---@param iconKey string
---@return { width: integer, height: integer }
function MonIconAssetProvider:dimensions(iconKey)
  assert(not self._released, "the icon provider is released")
  local entry = entryFor(self._manifest, iconKey)
  return { width = entry.width, height = entry.height }
end

-- Returns every adopted page lease exactly once; quads and sampling
-- handles reference no resources of their own, so dropping the caches is
-- sufficient. Safe to call repeatedly. Pending interest is abandoned
-- unstaged first so no decode outlives the provider; the borrowed image
-- owner itself is field-owned and stays live.
function MonIconAssetProvider:release()
  self:cancelPreparation()
  local pool = assert(self._pool, "the icon provider borrows its shared image owner")
  local leases = self._leases
  self._leases = {}
  self._handles = {}
  self._quads = {}
  self._pages = {}
  self._released = true
  for _, lease in pairs(leases) do
    pool:release(lease)
  end
end

return MonIconAssetProvider
