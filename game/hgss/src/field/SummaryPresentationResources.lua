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
-- pages adopt up to ten new leases per prepare call while the borrowed
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

-- Portrait pairs admitted per prepare round. Six covers the whole party,
-- so one warm round settles every demanded page beside the bulk chrome
-- set; the bound only paces pathological demand growth, never the party.
local MAX_PORTRAIT_ADOPTS_PER_ROUND = 10

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
---@field _chromePaths string[] always-drawn core chrome paths pinned on first demand
---@field _knownChrome table<string, boolean> every chrome path the family publishes, core or demand-selected
---@field _chrome table<string, table<string, unknown>> field-lifetime chrome leases by canonical path
---@field _chromeTokens table<string, integer> unconsumed shared-owner tokens by canonical path
---@field _chromePriority table<string, string> request priority behind each unconsumed chrome token
---@field _warmWanted table<string, boolean> canonical portrait page paths predicted for the live party
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
  -- Chrome splits into always-drawn core and demand-selected extras: every
  -- earned-ribbon image and every ball visual enrolls only when the
  -- current demand names it, instead of decoding the whole family on
  -- first open. Anything else (windows, bars, marks, move icons) is on
  -- the always-visible path and stays eager.
  local deferred = {}
  local sprites = assert(manifest.sprites, "the summary family carries its sprite roles")
  assert(type(sprites) == "table", "sprite roles arrive as a record")
  local ballIcons = assert(sprites.ballIcons, "sprite roles carry ball icons")
  assert(type(ballIcons) == "table" and type(ballIcons.icons) == "table", "ball icons name their visuals")
  local visuals = assert(manifest.visuals, "the summary family carries its visuals")
  assert(type(visuals) == "table", "visuals arrive as a record")
  for _, name in pairs(ballIcons.icons) do
    local visual = assert(visuals[name], "ball icons name a known visual: " .. tostring(name))
    assert(type(visual) == "table", "visuals are records")
    deferred[assert(visual.image, "ball visuals carry their image")] = true
  end
  local ribbons = assert(manifest.ribbons, "the summary family carries ribbon definitions")
  assert(type(ribbons) == "table" and type(ribbons.entries) == "table", "ribbon definitions carry entries")
  for _, entry in ipairs(ribbons.entries) do
    assert(type(entry) == "table", "ribbon entries are records")
    local art = assert(entry.art, "ribbon entries carry their visuals")
    assert(type(art) == "table", "ribbon visuals are records")
    deferred[assert(art.image, "ribbon visuals carry their image")] = true
  end
  local seen = {}
  local knownChrome = {}
  local chromePaths = {}
  local function addChrome(path)
    if seen[path] ~= true then
      seen[path] = true
      knownChrome[path] = true
      if deferred[path] ~= true then
        chromePaths[#chromePaths + 1] = path
      end
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
    _knownChrome = knownChrome,
    _chrome = {},
    _chromeTokens = {},
    _chromePriority = {},
    _warmWanted = {},
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

-- Drops every still-unconsumed chrome token without touching adopted
-- leases: late worker payloads are discarded instead of retained
-- unclaimed, while already pinned chrome stays drawable.
---@param self SummaryPresentationResources
local function cancelChromeTokens(self)
  local pool = assert(self._pool, "summary preparation borrows its shared image owner")
  for path, token in pairs(self._chromeTokens) do
    pool:cancel(token)
    self._chromeTokens[path] = nil
    self._chromePriority[path] = nil
  end
end

-- Returns one round's adopted chrome after a failed round: every lease
-- adopted by that round goes back to the shared owner, while chrome
-- pinned by earlier successful rounds stays drawable.
---@param self SummaryPresentationResources
---@param adopted string[] paths adopted by the failed round
local function releaseRoundChrome(self, adopted)
  local pool = assert(self._pool, "summary preparation borrows its shared image owner")
  for _, path in ipairs(adopted) do
    local lease = self._chrome[path]
    if lease ~= nil then
      pool:release(lease)
      self._chrome[path] = nil
    end
  end
end

-- Progresses the field-lifetime chrome leases without sleeping or
-- spinning: the first round enrolls one shared-owner token per still-
-- unborrowed core or demanded path while icons, portraits, and cry banks
-- make their own progress, and each round borrows newly ready pairs
-- through their single-use tokens. Foreground demand borrows every ready
-- pair at once; idle staging borrows at most the shared admission budget.
-- A failed path cancels every remaining token, returns the round's
-- adoptions, and names its path instead of pinning chrome the field
-- lifetime cannot draw. The lease is ready once every core and demanded
-- path is borrowed; pinned chrome stays drawable for the field lifetime.
-- A recorded prefetch token promotes to demand priority before its
-- cancellation so the shared queue keeps its coalesced worker work.
---@param self SummaryPresentationResources
---@param demanded table<string, boolean> demand-selected chrome paths beyond the core set
---@param priority string? shared-owner request priority, demand for foreground
---@param allowance { remaining: integer }? shared per-round admission budget, nil for unbounded foreground
---@return boolean ready true once every core and demanded path is borrowed
---@return string? failure named cause when a chrome path cannot be borrowed
local function advanceChrome(self, demanded, priority, allowance)
  local pool = assert(self._pool, "summary preparation borrows its shared image owner")
  local knownChrome = assert(self._knownChrome, "summary preparation keeps its chrome inventory")
  local level = priority or "demand"
  local wantedSet = {}
  local wanted = {}
  local function want(path)
    if knownChrome[path] ~= true then
      error("summary demand names unknown chrome at " .. tostring(path), 0)
    end
    if wantedSet[path] ~= true then
      wantedSet[path] = true
      wanted[#wanted + 1] = path
    end
  end
  for _, path in ipairs(self._chromePaths) do
    want(path)
  end
  for path in pairs(demanded) do
    want(path)
  end
  local function enroll(path)
    if self._chrome[path] ~= nil then
      return
    end
    local existing = self._chromeTokens[path]
    if existing == nil then
      self._chromeTokens[path] = pool:request(path, POOLED_SAMPLER, level)
      self._chromePriority[path] = level
    elseif level == "demand" and self._chromePriority[path] == "prefetch" then
      local promoted = pool:request(path, POOLED_SAMPLER, "demand")
      pool:cancel(existing)
      self._chromeTokens[path] = promoted
      self._chromePriority[path] = "demand"
    end
  end
  for _, path in ipairs(wanted) do
    enroll(path)
  end
  local adopted = {}
  for _, path in ipairs(wanted) do
    if self._chrome[path] == nil then
      local token = self._chromeTokens[path]
      if token ~= nil then
        local status, cause = pool:poll(token)
        if status == "failed" then
          local failure = "compiled Summary image missing at " .. path .. ": " .. tostring(cause)
          cancelChromeTokens(self)
          releaseRoundChrome(self, adopted)
          return false, failure
        elseif status == "ready" then
          if allowance ~= nil and allowance.remaining <= 0 then
            -- The admission budget is spent; the ready pair waits for a later round.
          else
            local ok, lease = pcall(pool.acquire, pool, token)
            if not ok then
              local failure = "compiled Summary image missing at " .. path .. ": " .. tostring(lease)
              self._chromeTokens[path] = nil
              self._chromePriority[path] = nil
              pool:cancel(token)
              cancelChromeTokens(self)
              releaseRoundChrome(self, adopted)
              return false, failure
            end
            self._chromeTokens[path] = nil
            self._chromePriority[path] = nil
            self._chrome[path] = lease
            adopted[#adopted + 1] = path
            if allowance ~= nil then
              allowance.remaining = allowance.remaining - 1
            end
          end
        else
          assert(status == "pending", "summary preparation reports pending or ready")
        end
      end
    end
  end
  for _, path in ipairs(wanted) do
    if self._chrome[path] == nil then
      return false, nil
    end
  end
  return true, nil
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
  assert(type(demand.chrome) == "table", "demands carry their demand-selected chrome paths")
  for _, path in ipairs(demand.chrome) do
    assert(type(path) == "string" and path ~= "", "demand-selected chrome arrives as paths")
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
  for path in pairs(self._warmWanted or {}) do
    watched[path] = true
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

---@param demand table<string, unknown>
---@return table<string, boolean> demand-selected chrome paths as a set
local function demandChrome(demand)
  local selected = {}
  for _, path in ipairs(assert(demand.chrome, "demands carry their demand-selected chrome paths")) do
    selected[path] = true
  end
  return selected
end

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
  -- Fixed chrome enrolls before any prerequisite-specific early return:
  -- every still-unborrowed family visual takes one shared-owner token
  -- on the first round while the icon, portrait, and cry work below
  -- makes its own progress, admitting every ready pair per round.
  local chromeReady, chromeFailure = advanceChrome(self, demandChrome(demand))
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
  -- A first visible demand takes over a recorded idle prefetch token:
  -- the equivalent demand request enrolls first so the shared queue
  -- keeps its coalesced worker work, then the speculative token cancels.
  do
    local poolOwner = assert(self._pool, "summary preparation borrows its shared image owner")
    for _, pageId in ipairs(pages) do
      local record = self._pages[pageId]
      if record ~= nil and record.token ~= nil and record.warm == true then
        local path = MonCache.portraitPagePath(pageId)
        local promoted = poolOwner:request(path, POOLED_SAMPLER, "demand")
        poolOwner:cancel(record.token)
        record.token = promoted
        record.warm = nil
      end
    end
  end
  -- Portrait compilation through the existing provisioner seam: a named
  -- failure surfaces, an unready page waits, and dispatched jobs are
  -- never cancelled from here. A missing seam fails visibly instead of
  -- hanging the lease. Pages with an adopted lease never recompile, so
  -- overlapping leases compile each shared page once. Per-page readiness
  -- gates the shared-owner image requests below: a page whose bytes are
  -- not yet compiled enrolls no worker decode, so a pending compilation
  -- waits instead of failing on its missing file.
  local portraitPending = false
  local portraitFailure = nil
  local portraitReady = {}
  local requestPage = self._derivedAssets.requestMonPortraitPage
  if type(requestPage) ~= "function" then
    portraitFailure = "portrait compilation is unavailable"
  else
    for _, pageId in ipairs(pages) do
      local record = self._pages[pageId]
      if record ~= nil and record.lease ~= nil then
        portraitReady[pageId] = true
      elseif record ~= nil and record.token ~= nil then
        portraitReady[pageId] = true
      else
        local ok, ready, failure = pcall(requestPage, pageId, "required")
        if not ok then
          portraitFailure = tostring(ready)
          break
        elseif failure ~= nil then
          portraitFailure = tostring(failure)
          break
        elseif not ready then
          portraitPending = true
        else
          portraitReady[pageId] = true
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
  -- Portrait image requests enroll through the shared owner only for
  -- pages whose compilation is confirmed above, so one shared page
  -- borrows once no matter how many leases watch it while an uncompiled
  -- page waits without decoding its missing file. Failures surface
  -- before any new worker decode enrolls.
  if iconsFailure ~= nil then
    return { kind = "failed", error = iconsFailure }
  end
  if portraitFailure ~= nil then
    return { kind = "failed", error = portraitFailure }
  end
  if cryFailure ~= nil then
    return { kind = "failed", error = cryFailure }
  end
  -- A failed chrome path surfaces like any other missing visual while
  -- the adopted portrait leases stay pinned; pending chrome simply
  -- joins the readiness decision below.
  if chromeFailure ~= nil then
    return { kind = "failed", error = chromeFailure }
  end
  local pool = assert(self._pool, "summary preparation borrows its shared image owner")
  for _, pageId in ipairs(pages) do
    if portraitReady[pageId] == true then
      local record = pageRecord(self, pageId)
      if record.lease == nil and record.token == nil then
        record.token = pool:request(MonCache.portraitPagePath(pageId), POOLED_SAMPLER, "demand")
      end
    end
  end
  local pending = portraitPending or cryPending
  -- Portrait pages adopt up to ten new leases per call so a warm open
  -- settles the whole party in one round. A failed request forgets its
  -- token and names its cause; the next round re-enrolls it.
  local adopted = 0
  for _, pageId in ipairs(pages) do
    local record = self._pages[pageId]
    if record == nil then
      pending = true
    elseif record.lease == nil and record.token ~= nil and adopted < MAX_PORTRAIT_ADOPTS_PER_ROUND then
      local status, cause = pool:poll(record.token)
      if status == "failed" then
        pool:cancel(record.token)
        record.token = nil
        return { kind = "failed", error = tostring(cause) }
      elseif status == "ready" then
        local okAdopt, adoptedLease = pcall(pool.acquire, pool, record.token)
        if not okAdopt then
          pool:cancel(record.token)
          record.token = nil
          return { kind = "failed", error = tostring(adoptedLease) }
        end
        record.token = nil
        record.lease = adoptedLease
        self._leasedPortraits[MonCache.portraitPagePath(pageId)] = adoptedLease
        adopted = adopted + 1
      else
        pending = true
      end
    elseif record.lease == nil then
      pending = true
    end
  end
  if not iconsReady then
    pending = true
  end
  -- A ready bundle needs its chrome as well: later opens reuse the
  -- pinned set immediately while a first open waits without blocking
  -- the field. Chrome failures already returned above.
  if not chromeReady then
    pending = true
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

-- Stages the always-drawn core chrome and the predicted portrait pages
-- across idle updates without opening a Summary screen. Chrome enrolls
-- at prefetch priority and portraits compile at near urgency; at most one
-- new pool lease adopts per call under the shared admission budget.
-- Failures name their path or page without crashing the field, and stale
-- predictions release only once no live lease watches them.
---@param selectors string[] roster portrait identities in slot order
---@param remainingGpu integer 0 or 1 speculative GPU realizations for the call
---@return boolean usedGpu true when the call realized a new pool lease
---@return string? failure named path or page cause when idle staging cannot proceed
function SummaryPresentationResources:advanceWarmup(selectors, remainingGpu)
  assert(not self._released, "summary preparation is released")
  assert(type(selectors) == "table", "idle staging reads its roster selectors")
  assert(remainingGpu == 0 or remainingGpu == 1, "idle staging spends at most one GPU realization")
  local allowance = { remaining = remainingGpu }
  local chromeReady, chromeFailure = advanceChrome(self, {}, "prefetch", allowance)
  if chromeFailure ~= nil then
    return (remainingGpu - allowance.remaining) > 0, chromeFailure
  end
  local seen, pageIds = {}, {}
  for _, selector in ipairs(selectors) do
    if type(selector) ~= "string" or selector:find("/", 1, true) == nil then
      return (remainingGpu - allowance.remaining) > 0,
        "the portrait manifest carries no page for " .. tostring(selector)
    end
    local pageId, cause = pageForSelector(self, selector)
    if pageId == nil then
      return (remainingGpu - allowance.remaining) > 0, tostring(cause)
    end
    if not seen[pageId] then
      seen[pageId] = true
      pageIds[#pageIds + 1] = pageId
    end
  end
  table.sort(pageIds)
  local wanted = {}
  for _, pageId in ipairs(pageIds) do
    wanted[MonCache.portraitPagePath(pageId)] = true
  end
  self._warmWanted = wanted
  local pool = assert(self._pool, "summary preparation borrows its shared image owner")
  local requestPage = self._derivedAssets.requestMonPortraitPage
  if type(requestPage) ~= "function" then
    return (remainingGpu - allowance.remaining) > 0, "portrait compilation is unavailable"
  end
  for _, pageId in ipairs(pageIds) do
    local record = pageRecord(self, pageId)
    if record.lease == nil and record.token == nil then
      local ok, ready, failure = pcall(requestPage, pageId, "near")
      if not ok then
        return (remainingGpu - allowance.remaining) > 0, tostring(ready)
      elseif failure ~= nil then
        return (remainingGpu - allowance.remaining) > 0, tostring(failure)
      elseif ready then
        record.token = pool:request(MonCache.portraitPagePath(pageId), POOLED_SAMPLER, "prefetch")
        record.warm = true
      end
    end
  end
  for _, pageId in ipairs(pageIds) do
    local record = self._pages[pageId]
    if record ~= nil and record.lease == nil and record.token ~= nil then
      local path = MonCache.portraitPagePath(pageId)
      local status, cause = pool:poll(record.token)
      if status == "failed" then
        pool:cancel(record.token)
        record.token = nil
        record.warm = nil
        return (remainingGpu - allowance.remaining) > 0,
          "compiled Summary portrait missing at " .. path .. ": " .. tostring(cause)
      elseif status == "ready" then
        if allowance.remaining > 0 then
          local okAdopt, adopted = pcall(pool.acquire, pool, record.token)
          if not okAdopt then
            pool:cancel(record.token)
            record.token = nil
            record.warm = nil
            return (remainingGpu - allowance.remaining) > 0,
              "compiled Summary portrait missing at " .. path .. ": " .. tostring(adopted)
          end
          record.token = nil
          record.warm = nil
          record.lease = adopted
          self._leasedPortraits[path] = adopted
          allowance.remaining = allowance.remaining - 1
        end
      else
        assert(status == "pending", "summary preparation reports pending or ready")
      end
    end
  end
  dropUnwatchedPortraits(self, liveWatchedPaths(self))
  if not chromeReady then
    return (remainingGpu - allowance.remaining) > 0, nil
  end
  for _, pageId in ipairs(pageIds) do
    local record = self._pages[pageId]
    if record == nil or record.lease == nil then
      return (remainingGpu - allowance.remaining) > 0, nil
    end
  end
  return (remainingGpu - allowance.remaining) > 0, nil
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
      pool:cancel(record.token)
      record.token = nil
    end
    if record.lease ~= nil then
      pool:release(record.lease)
      record.lease = nil
    end
    self._pages[pageId] = nil
  end
  for path, token in pairs(self._chromeTokens) do
    pool:cancel(token)
    self._chromeTokens[path] = nil
    self._chromePriority[path] = nil
  end
  self._warmWanted = {}
  self._leasedPortraits = {}
  for path, lease in pairs(self._chrome) do
    pool:release(lease)
    self._chrome[path] = nil
  end
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
