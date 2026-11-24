-- The field's hatch presentation owner: one per-open lease over the generated
-- hatch manifest and its staged images. Preparation advances the shared image
-- pool without blocking, commits one whole renderer bundle when every demanded
-- image is ready, and returns each acquired image lease exactly once on
-- release. Borrowed image pool, text renderer, window renderer and cache are
-- never released here. A missing or unreadable manifest fails the lease instead
-- of drawing a blank scene.

local EggHatchRenderer = require("libs.hgss.src.ui.EggHatchRenderer")
local PokemonCareCache = require("libs.assets.src.PokemonCareCache")

local POOLED_SAMPLER = { wrapX = "clamp", wrapY = "clamp", minFilter = "nearest", magFilter = "nearest" }

---@class PokemonCarePresentationResources
---@field private _cacheFs table<string, unknown> borrowed version cache reader
---@field private _graphics table<string, unknown> the graphics namespace the renderer draws through
---@field private _imagePool table<string, unknown> borrowed session image owner
---@field private _text table<string, unknown> borrowed Font0 field text renderer
---@field private _window table<string, unknown>? borrowed framed window renderer
---@field private _fontDef table<string, unknown> borrowed field font definition
---@field private _frameIndex integer? the player's selected window frame
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
end

---@param owner PokemonCarePresentationResources
---@param lease table<string, unknown>
---@param request table<string, unknown>
---@return table<string, unknown> preparation outcome
local function prepareLease(owner, lease, request)
  if lease._presentation ~= nil then
    return { kind = "ready", presentation = lease._presentation }
  end
  if lease._manifest == nil then
    local ok, manifest = pcall(PokemonCareCache.loadHatchManifest, owner._cacheFs)
    if not ok or type(manifest) ~= "table" then
      owner:_releaseLeaseInterests(lease)
      return { kind = "failed", error = "the hatch presentation manifest is unavailable: " .. tostring(manifest) }
    end
    lease._manifest = manifest
    local pool = owner._imagePool
    for _, path in ipairs(PokemonCareCache.referencedHatchPaths(manifest)) do
      local requested, token = pcall(pool.request, pool, path, POOLED_SAMPLER, "demand")
      if not requested then
        owner:_releaseLeaseInterests(lease)
        return { kind = "failed", error = "hatch image request failed: " .. tostring(token) }
      end
      lease._tokens[path] = token
      lease._pendingTokens[#lease._pendingTokens + 1] = token
    end
  end
  local pool = owner._imagePool
  local images = {}
  for path, token in pairs(lease._tokens) do
    if lease._acquired[path] == nil then
      local status, failure = pool:poll(token)
      if status == "failed" then
        owner:_releaseLeaseInterests(lease)
        return { kind = "failed", error = "hatch image is missing: " .. tostring(failure or path) }
      end
      if status ~= "ready" then
        return { kind = "pending" }
      end
      local acquiredOk, acquired = pcall(pool.acquire, pool, token)
      if not acquiredOk then
        owner:_releaseLeaseInterests(lease)
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
  local manifest = assert(lease._manifest, "prepared leases resolve their manifest before commit")
  local rendererOk, renderer = pcall(EggHatchRenderer.new, {
    graphics = owner._graphics,
    manifest = manifest,
    images = images,
    text = owner._text,
    window = owner._window,
    fontDef = owner._fontDef,
    frameIndex = owner._frameIndex,
  })
  if not rendererOk then
    owner:_releaseLeaseInterests(lease)
    return { kind = "failed", error = "hatch renderer failed: " .. tostring(renderer) }
  end
  local presentation = {
    renderer = renderer,
    images = images,
    manifest = manifest,
    name = assert(request.nickname, "the hatch request carries the hatched name"),
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
    _tokens = {},
    _pendingTokens = {},
    _acquired = {},
    _presentation = nil,
  }
  function lease:prepare()
    if self._released then
      return { kind = "failed", error = "care lease is released" }
    end
    local ok, outcome = pcall(prepareLease, owner, self, self._request)
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
    if self._released then
      return
    end
    self._released = true
    if not owner._released then
      owner:_releaseLeaseInterests(self)
    end
    if owner._lease == self then
      owner._lease = nil
    end
  end
  self._lease = lease
  return lease
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
