-- The lazy field-owned Easy Chat preparation leaf: one finite image
-- demand set plus the compact prompt renderer over borrowed owners. At
-- most one active per-open lease exists; preparation advances the shared
-- semantic demand and the pooled image demand without blocking, and
-- release returns every acquired lease exactly once. Borrowed fonts,
-- frame renderer, image pool, filesystem, and derived request service
-- are never released here.

local EasyChatCache = require("libs.assets.src.EasyChatCache")

local POOLED_SAMPLER = { wrapX = "clamp", wrapY = "clamp", minFilter = "nearest", magFilter = "nearest" }

---@class EasyChatPresentationResources
---@field _cacheFs table<string, unknown> borrowed version cache reader
---@field _graphics love.graphics? host graphics namespace
---@field _imagePool table<string, unknown> borrowed session image owner
---@field _derivedAssets table<string, unknown> borrowed semantic cache host
---@field _uiManifest table<string, unknown> borrowed field UI manifest
---@field _text0 table<string, unknown> borrowed Font0 renderer
---@field _text1 table<string, unknown> borrowed Font1 renderer
---@field _text4 table<string, unknown> borrowed Font4 renderer
---@field _window table<string, unknown> borrowed window renderer
---@field _lease table<string, unknown>? the one active per-open lease
---@field _released boolean
local EasyChatPresentationResources = {}
EasyChatPresentationResources.__index = EasyChatPresentationResources

---@class EasyChatPresentationResources.Options
---@field cacheFs table<string, unknown> borrowed version cache reader
---@field graphics love.graphics? host graphics namespace
---@field imagePool table<string, unknown> borrowed session image owner
---@field derivedAssets table<string, unknown> borrowed semantic cache host
---@field uiManifest table<string, unknown> borrowed field UI manifest
---@field text0 table<string, unknown> borrowed Font0 renderer
---@field text1 table<string, unknown> borrowed Font1 renderer
---@field text4 table<string, unknown> borrowed Font4 renderer
---@field window table<string, unknown> borrowed window renderer

---@param opts EasyChatPresentationResources.Options
---@return EasyChatPresentationResources
function EasyChatPresentationResources.new(opts)
  assert(type(opts) == "table", "editor preparation requires its options")
  assert(opts.cacheFs and opts.cacheFs.read, "editor preparation borrows the version cache")
  assert(type(opts.imagePool) == "table", "editor preparation borrows the shared image owner")
  assert(type(opts.derivedAssets) == "table", "editor preparation borrows the semantic cache host")
  assert(type(opts.uiManifest) == "table", "editor preparation borrows the field UI manifest")
  assert(type(opts.text0) == "table", "editor preparation borrows the Font0 renderer")
  assert(type(opts.text1) == "table", "editor preparation borrows the Font1 renderer")
  assert(type(opts.text4) == "table", "editor preparation borrows the Font4 renderer")
  assert(type(opts.window) == "table", "editor preparation borrows the window renderer")
  return setmetatable({
    _cacheFs = opts.cacheFs,
    _graphics = opts.graphics or (love and love.graphics) or nil,
    _imagePool = opts.imagePool,
    _derivedAssets = opts.derivedAssets,
    _uiManifest = opts.uiManifest,
    _text0 = opts.text0,
    _text1 = opts.text1,
    _text4 = opts.text4,
    _window = opts.window,
    _lease = nil,
    _released = false,
  }, EasyChatPresentationResources)
end

---@param self EasyChatPresentationResources
---@param lease table<string, unknown>
function EasyChatPresentationResources:_releaseLeaseInterests(lease)
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
  if lease._prompt ~= nil then
    local prompt = lease._prompt
    lease._prompt = nil
    if type(prompt.release) == "function" then
      pcall(prompt.release, prompt)
    elseif type(prompt.dispose) == "function" then
      pcall(prompt.dispose, prompt)
    end
  end
  if lease._renderer ~= nil then
    local renderer = lease._renderer
    lease._renderer = nil
    if type(renderer.dispose) == "function" then
      pcall(renderer.dispose, renderer)
    elseif type(renderer.release) == "function" then
      pcall(renderer.release, renderer)
    end
  end
  lease._manifest = nil
  lease._committed = nil
end

---@param owner EasyChatPresentationResources
---@param lease table<string, unknown>
---@return table<string, unknown> preparation outcome
local function prepareLease(owner, lease)
  if lease._committed ~= nil then
    return { kind = "ready", assets = lease._committed }
  end
  local derived = owner._derivedAssets
  local request = assert(derived.requestEasyChat, "editor preparation requests through the semantic cache host")
  local ready, failure = request("required")
  if failure ~= nil then
    owner:_releaseLeaseInterests(lease)
    return { kind = "failed", error = tostring(failure) }
  end
  if ready ~= true then
    return { kind = "pending" }
  end
  if lease._manifest == nil then
    local ok, manifest = pcall(EasyChatCache.loadManifest, owner._cacheFs)
    if not ok or type(manifest) ~= "table" then
      owner:_releaseLeaseInterests(lease)
      return { kind = "failed", error = "easy chat manifest is unavailable: " .. tostring(manifest) }
    end
    lease._manifest = manifest
    local paths = EasyChatCache.referencedPaths(manifest)
    local pool = owner._imagePool
    for _, path in ipairs(paths) do
      if lease._tokens[path] == nil then
        local okRequest, token = pcall(pool.request, pool, path, POOLED_SAMPLER, "demand")
        if not okRequest then
          owner:_releaseLeaseInterests(lease)
          return { kind = "failed", error = "easy chat image request failed: " .. tostring(token) }
        end
        lease._tokens[path] = token
        lease._pendingTokens[#lease._pendingTokens + 1] = token
      end
    end
  end
  local pool = owner._imagePool
  local images = {}
  for path, token in pairs(lease._tokens) do
    if lease._acquired[path] == nil then
      local status, pollFailure = pool:poll(token)
      if status == "failed" then
        owner:_releaseLeaseInterests(lease)
        return { kind = "failed", error = "easy chat image is missing: " .. tostring(pollFailure) }
      end
      if status ~= "ready" then
        return { kind = "pending" }
      end
      local okAcquire, acquired = pcall(pool.acquire, pool, token)
      if not okAcquire then
        owner:_releaseLeaseInterests(lease)
        return { kind = "failed", error = "easy chat image acquire failed: " .. tostring(acquired) }
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
  local EasyChatRenderer = require("libs.hgss.src.ui.EasyChatRenderer")
  local okRenderer, renderer = pcall(EasyChatRenderer.new, {
    manifest = manifest,
    images = images,
    text0 = owner._text0,
    text1 = owner._text1,
    text4 = owner._text4,
    window = owner._window,
    prompt = lease._prompt,
  })
  if not okRenderer then
    owner:_releaseLeaseInterests(lease)
    return { kind = "failed", error = "easy chat renderer failed: " .. tostring(renderer) }
  end
  local committed = {
    manifest = manifest,
    images = images,
    text0 = owner._text0,
    text1 = owner._text1,
    text4 = owner._text4,
    window = owner._window,
    prompt = lease._prompt,
    renderer = renderer,
  }
  lease._committed = committed
  return { kind = "ready", assets = committed }
end

-- Acquires the one active per-open lease: preparation polls the exact
-- easy-chat closure, admits its bounded referenced images through the
-- existing pool, and commits one whole asset bundle. A second concurrent
-- acquire is a composition error.
---@return table<string, unknown> lease with prepare/release
function EasyChatPresentationResources:acquire()
  assert(not self._released, "editor preparation is released")
  assert(self._lease == nil, "one editor lease owns the presented lifetime")
  local owner = self
  local lease = {
    _owner = owner,
    _released = false,
    _manifest = nil,
    _tokens = {},
    _pendingTokens = {},
    _acquired = {},
    _prompt = nil,
    _renderer = nil,
    _committed = nil,
  }
  function lease:prepare()
    if self._released then
      return { kind = "failed", error = "editor lease is released" }
    end
    local ok, outcome = pcall(prepareLease, owner, self)
    if not ok then
      owner:_releaseLeaseInterests(self)
      return { kind = "failed", error = tostring(outcome) }
    end
    return outcome
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

-- Idempotent release of the field lifetime: invalidates the active
-- lease, returns every acquired image lease exactly once, and releases
-- only the owned renderer. Borrowed fonts, frame renderer, image pool,
-- filesystem, and derived request service stay alive.
function EasyChatPresentationResources:release()
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

return EasyChatPresentationResources
