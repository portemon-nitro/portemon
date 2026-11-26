-- The field's care presentation owner: one per-open lease over the generated
-- manifest of the open care application and its staged images. Preparation advances the shared image
-- pool without blocking, commits one whole renderer bundle when every demanded
-- image is ready, and returns each acquired image lease exactly once on
-- release. Borrowed image pool, text renderer, window renderer and cache are
-- never released here. A missing or unreadable manifest fails the lease instead
-- of drawing a blank scene.
--
-- The script-owned Summary children commit the same way: their bundle carries
-- the summary family the child screen draws with, so one acquisition covers the
-- reminder's own art and the replacement Summary alike.

local EggHatchRenderer = require("libs.hgss.src.ui.EggHatchRenderer")
local MoveRelearnerRenderer = require("libs.hgss.src.ui.MoveRelearnerRenderer")
local MonCache = require("libs.assets.src.MonCache")
local NpcTradeRenderer = require("libs.hgss.src.ui.NpcTradeRenderer")
local PokemonCareInterface = require("libs.hgss.src.ui.PokemonCareInterface")
local PokemonCareCache = require("libs.assets.src.PokemonCareCache")
local SummaryCache = require("libs.assets.src.SummaryCache")

local POOLED_SAMPLER = { wrapX = "clamp", wrapY = "clamp", minFilter = "nearest", magFilter = "nearest" }

---@class PokemonCarePresentationResources
---@field private _cacheFs table<string, unknown> borrowed version cache reader
---@field private _graphics table<string, unknown> the graphics namespace the renderer draws through
---@field private _imagePool table<string, unknown> borrowed session image owner
---@field private _text table<string, unknown> borrowed Font0 field text renderer
---@field private _window table<string, unknown>? borrowed framed window renderer
---@field private _fontDef table<string, unknown> borrowed field font definition
---@field private _frameIndex integer? the player's selected window frame
---@field private _measureDisplay (fun(): table<string, unknown>)? live display facts for dual-screen scenes
---@field private _lease table<string, unknown>? the one active per-open lease
---@field private _released boolean
local PokemonCarePresentationResources = {}
PokemonCarePresentationResources.__index = PokemonCarePresentationResources

---@class PokemonCarePresentationResources.Options
---@field cacheFs table<string, unknown>
---@field graphics table<string, unknown>
---@field imagePool table<string, unknown>
---@field text table<string, unknown>
---@field window table<string, unknown>?
---@field fontDef table<string, unknown>
---@field frameIndex integer?
---@field measureDisplay (fun(): table<string, unknown>)?

---@param opts PokemonCarePresentationResources.Options
---@return PokemonCarePresentationResources
function PokemonCarePresentationResources.new(opts)
  assert(type(opts) == "table", "care preparation requires its options")
  assert(opts.cacheFs and opts.cacheFs.read and opts.cacheFs.loadLua, "care preparation borrows the version cache")
  local graphics = assert(opts.graphics, "care preparation needs its graphics namespace")
  assert(type(graphics.draw) == "function", "care preparation realizes through the graphics namespace")
  local pool = assert(opts.imagePool, "care preparation borrows the shared image owner")
  assert(
    type(pool.request) == "function" and type(pool.poll) == "function" and type(pool.acquire) == "function",
    "care preparation drives request, poll and acquire"
  )
  assert(type(opts.text) == "table", "care preparation borrows the field text renderer")
  assert(type(opts.fontDef) == "table", "care preparation borrows the field font definition")
  return setmetatable({
    _cacheFs = opts.cacheFs,
    _graphics = graphics,
    _imagePool = pool,
    _text = opts.text,
    _window = opts.window,
    _fontDef = opts.fontDef,
    _frameIndex = opts.frameIndex,
    _measureDisplay = opts.measureDisplay,
    _lease = nil,
    _released = false,
  }, PokemonCarePresentationResources)
end

---@param lease table<string, unknown>
function PokemonCarePresentationResources:_releaseLeaseInterests(lease)
  local pool = self._imagePool
  for _, token in ipairs(lease._pendingTokens or {}) do
    pcall(pool.cancel, pool, token)
  end
  lease._pendingTokens = {}
  for path, acquired in pairs(lease._acquired or {}) do
    if acquired ~= nil and type(acquired.release) == "function" then
      pcall(acquired.release, acquired)
    end
    lease._acquired[path] = nil
  end
  if lease._presentation ~= nil then
    local presentation = lease._presentation
    lease._presentation = nil
    presentation.renderer:release()
  end
  lease._manifest = nil
  lease._reminderManifest = nil
  lease._picture = nil
  lease._assets = nil
end

-- The mon portraits a trade scene draws, per detached subject: the generated
-- page that carries the subject's own selector, its first frame rectangle, and
-- the source's front picture height for that selector. The height only depends
-- on species, form and gender, so shiny selectors share the plain entry.
---@param manifest table<string, unknown> trade manifest
---@param request table<string, unknown> trade request
---@return table<string, table<string, unknown>> pictures
---@return string[] pagePaths
function PokemonCarePresentationResources:_tradePictures(manifest, request)
  local portraits = self._cacheFs:loadLua(MonCache.portraitManifestPath())
  assert(type(portraits) == "table" and type(portraits.entries) == "table", "the mon portrait family is published")
  local entries = portraits.entries --[[@as table<string, table<string, unknown>>]]
  local heights = assert(assert(manifest.pictures, "the trade manifest carries its pictures") --[[@as table]]).heights
  local pictures = {}
  local pages = {}
  for _, subjectKey in ipairs({ "outgoing", "incoming" }) do
    local subject = assert(request[subjectKey], "the trade request carries both subjects") --[[@as table]]
    local selector = MonCache.portraitSelector(subject.speciesKey, subject.form, subject.gender, subject.shiny)
    local entry = assert(entries[selector], "the mon portrait family carries the trade picture " .. tostring(selector)) --[[@as table]]
    local frame = assert(assert(entry.frames)[1], "a portrait entry carries its first frame") --[[@as table]]
    local plain = MonCache.portraitSelector(subject.speciesKey, subject.form, subject.gender, false)
    local height = assert(heights[plain], "the trade manifest carries the picture height for " .. tostring(plain)) --[[@as integer]]
    local page = MonCache.portraitPagePath(assert(entry.pageId, "a portrait entry names its page") --[[@as integer]])
    pictures[subjectKey] = {
      page = page,
      frame = { x = frame.x, y = frame.y, width = frame.width, height = frame.height },
      height = height,
    }
    pages[#pages + 1] = page
  end
  return pictures, pages
end

-- The reminder's main-screen picture: the generated portrait page carrying the
-- subject's own selector and that entry's first frame. The scene draws it as
-- the source's centred Pokémon picture over the main screen's own surface.
---@param request table<string, unknown>
---@return { page: string, frame: { x: integer, y: integer, width: integer, height: integer } }
---@return string page path
function PokemonCarePresentationResources:_reminderPicture(request)
  local subject = assert(request.subject, "the reminder request carries its subject") --[[@as table]]
  local portraits = self._cacheFs:loadLua(MonCache.portraitManifestPath())
  assert(type(portraits) == "table" and type(portraits.entries) == "table", "the mon portrait family is published")
  local entries = portraits.entries --[[@as table<string, table<string, unknown>>]]
  local selector = MonCache.portraitSelector(subject.speciesKey, subject.form, subject.gender, subject.shiny)
  local entry = assert(entries[selector], "the mon portrait family carries the reminder picture " .. tostring(selector))
  local frame = assert(assert(entry.frames)[1], "a portrait entry carries its first frame") --[[@as table]]
  local page = MonCache.portraitPagePath(assert(entry.pageId, "a portrait entry names its page") --[[@as integer]])
  return {
    page = page,
    frame = { x = frame.x, y = frame.y, width = frame.width, height = frame.height },
  },
    page
end

-- The scripted Summary kinds commit the summary family beside the reminder's
-- own art: the child screen and the reminder's replacement Summary draw from the
-- family the field already publishes, never from a second definition.
---@param lease table<string, unknown>
---@param request table<string, unknown>
---@return boolean, string?
function PokemonCarePresentationResources:_prepareScriptedManifests(lease, request)
  if lease._assets ~= nil then
    return true, nil
  end
  local ok, manifest = pcall(SummaryCache.loadManifest, self._cacheFs)
  if not ok or type(manifest) ~= "table" then
    return false, "the summary family is unavailable: " .. tostring(manifest)
  end
  local assets = { manifest = manifest }
  local paths = {}
  if request.kind == PokemonCareInterface.KINDS.move_relearner then
    local reminderOk, reminder = pcall(PokemonCareCache.loadReminderManifest, self._cacheFs)
    if not reminderOk or type(reminder) ~= "table" then
      return false, "the reminder presentation manifest is unavailable: " .. tostring(reminder)
    end
    assets.reminder = reminder
    lease._reminderManifest = reminder
    local picture, page = self:_reminderPicture(request)
    lease._picture = picture
    paths[#paths + 1] = page
    for _, path in ipairs(PokemonCareCache.referencedReminderPaths(reminder)) do
      paths[#paths + 1] = path
    end
  end
  lease._assets = assets
  local pool = self._imagePool
  for _, path in ipairs(paths) do
    local requested, token = pcall(pool.request, pool, path, POOLED_SAMPLER, "demand")
    if not requested then
      return false, "care image request failed: " .. tostring(token)
    end
    lease._tokens[path] = token
    lease._pendingTokens[#lease._pendingTokens + 1] = token
  end
  return true, nil
end

---@param lease table<string, unknown>
---@param request table<string, unknown>
---@return table<string, unknown> preparation outcome
function PokemonCarePresentationResources:_prepareLease(lease, request)
  if lease._presentation ~= nil then
    return { kind = "ready", presentation = lease._presentation, assets = lease._assets }
  end
  local trade = request.kind == PokemonCareInterface.KINDS.trade
  local scripted = request.kind == PokemonCareInterface.KINDS.move_relearner
    or request.kind == PokemonCareInterface.KINDS.summary_application
  if scripted then
    local prepared, failure = self:_prepareScriptedManifests(lease, request)
    if not prepared then
      self:_releaseLeaseInterests(lease)
      return { kind = "failed", error = failure }
    end
  elseif lease._manifest == nil then
    local loader = trade and PokemonCareCache.loadTradeManifest or PokemonCareCache.loadHatchManifest
    local ok, manifest = pcall(loader, self._cacheFs)
    if not ok or type(manifest) ~= "table" then
      self:_releaseLeaseInterests(lease)
      return { kind = "failed", error = "the care presentation manifest is unavailable: " .. tostring(manifest) }
    end
    lease._manifest = manifest
    local paths = trade and PokemonCareCache.referencedTradePaths(manifest)
      or PokemonCareCache.referencedHatchPaths(manifest)
    if trade then
      local pictures, pages = self:_tradePictures(manifest, request)
      lease._pictures = pictures
      for _, page in ipairs(pages) do
        paths[#paths + 1] = page
      end
    end
    local pool = self._imagePool
    for _, path in ipairs(paths) do
      local requested, token = pcall(pool.request, pool, path, POOLED_SAMPLER, "demand")
      if not requested then
        self:_releaseLeaseInterests(lease)
        return { kind = "failed", error = "care image request failed: " .. tostring(token) }
      end
      lease._tokens[path] = token
      lease._pendingTokens[#lease._pendingTokens + 1] = token
    end
  end
  local pool = self._imagePool
  local images = {}
  for path, token in pairs(lease._tokens) do
    if lease._acquired[path] == nil then
      local status, failure = pool:poll(token)
      if status == "failed" then
        self:_releaseLeaseInterests(lease)
        return { kind = "failed", error = "hatch image is missing: " .. tostring(failure or path) }
      end
      if status ~= "ready" then
        return { kind = "pending" }
      end
      local acquiredOk, acquired = pcall(pool.acquire, pool, token)
      if not acquiredOk then
        self:_releaseLeaseInterests(lease)
        return { kind = "failed", error = "hatch image acquire failed: " .. tostring(acquired) }
      end
      lease._acquired[path] = acquired
      for index, pending in ipairs(lease._pendingTokens) do
        if pending == token then
          table.remove(lease._pendingTokens, index)
          break
        end
      end
    end
    local acquired = lease._acquired[path]
    images[path] = (type(acquired) == "table" and acquired.image) or acquired
  end
  if scripted then
    local assets = assert(lease._assets, "scripted leases commit their family bundle")
    if request.kind == PokemonCareInterface.KINDS.summary_application then
      return { kind = "ready", presentation = nil, assets = assets }
    end
    local reminderManifest = assert(lease._reminderManifest, "the reminder lease carries its own family")
    local built, renderer = pcall(MoveRelearnerRenderer.new, {
      graphics = self._graphics,
      manifest = reminderManifest,
      images = images,
      picture = assert(lease._picture, "the reminder lease carries its subject picture"),
      measureDisplay = assert(self._measureDisplay, "the reminder renders its two source screens"),
      text = self._text,
      window = self._window,
      fontDef = self._fontDef,
      frameIndex = self._frameIndex,
    })
    if not built then
      self:_releaseLeaseInterests(lease)
      return { kind = "failed", error = "care renderer failed: " .. tostring(renderer) }
    end
    local presentation = { renderer = renderer, images = images, manifest = reminderManifest, name = request.nickname }
    lease._presentation = presentation
    return { kind = "ready", presentation = presentation, assets = assets }
  end
  local manifest = assert(lease._manifest, "prepared leases resolve their manifest before commit")
  local rendererOptions = {
    graphics = self._graphics,
    cacheFs = self._cacheFs,
    manifest = manifest,
    images = images,
    pictures = lease._pictures,
    text = self._text,
    window = self._window,
    fontDef = self._fontDef,
    frameIndex = self._frameIndex,
  }
  local rendererOk, renderer = pcall(trade and NpcTradeRenderer.new or EggHatchRenderer.new, rendererOptions)
  if not rendererOk then
    self:_releaseLeaseInterests(lease)
    return { kind = "failed", error = "care renderer failed: " .. tostring(renderer) }
  end
  local presentation = {
    renderer = renderer,
    images = images,
    manifest = manifest,
    name = trade and request.playerName or assert(request.nickname, "the hatch request carries the hatched name"),
  }
  lease._presentation = presentation
  return { kind = "ready", presentation = presentation }
end

-- Acquires the one active per-open lease. A second concurrent acquire is a
-- composition error: one hatch application owns the presentation.
---@param request table<string, unknown>
---@return table<string, unknown> lease with prepare/presentation/release
function PokemonCarePresentationResources:acquire(request)
  assert(not self._released, "care preparation is released")
  assert(self._lease == nil, "one care lease owns the presented lifetime")
  local owner = self
  local lease = {
    _owner = owner,
    _request = request,
    _released = false,
    _manifest = nil,
    _reminderManifest = nil,
    _assets = nil,
    _pictures = nil,
    _tokens = {},
    _pendingTokens = {},
    _acquired = {},
    _presentation = nil,
  }
  function lease:prepare()
    if self._released then
      return { kind = "failed", error = "care lease is released" }
    end
    local ok, outcome = pcall(PokemonCarePresentationResources._prepareLease, owner, self, self._request)
    if not ok then
      owner:_releaseLeaseInterests(self)
      return { kind = "failed", error = tostring(outcome) }
    end
    return outcome
  end
  function lease:presentation()
    return self._presentation
  end
  function lease:release()
    owner:_releaseLease(self)
  end
  self._lease = lease
  return lease
end

-- Releases one lease exactly once: a released child frees the owner for the
-- next application, and a child released after the field lifetime only drops
-- its own state.
---@param lease table<string, unknown>
function PokemonCarePresentationResources:_releaseLease(lease)
  if lease._released then
    return
  end
  lease._released = true
  if not self._released then
    self:_releaseLeaseInterests(lease)
  end
  if self._lease == lease then
    self._lease = nil
  end
end

-- Idempotent release of the field lifetime: invalidates the active lease and
-- returns every acquired image lease exactly once. Borrowed collaborators stay
-- alive.
function PokemonCarePresentationResources:release()
  if self._released then
    return
  end
  self._released = true
  local lease = self._lease
  self._lease = nil
  if lease ~= nil then
    lease._released = true
    self:_releaseLeaseInterests(lease)
  end
end

return PokemonCarePresentationResources
