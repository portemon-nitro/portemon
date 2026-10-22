-- Per-launch battle resource leases behind one battle screen. Resolves
-- the selected scene image and window frame through the injected
-- preparation services, tracks exactly the handles acquired here, and
-- reports truthful pending/ready/failed preparation with semantic error
-- context. Frame selection merges per-instance declarations over the one
-- built-in default: an undeclared frame key is an explicit content
-- failure, never a substitution. Borrowed text and window services are
-- never owned here.

---@class BattlePresentationAssets.Services
---@field prepare fun(demand: table<string, unknown>): boolean?, string?
---@field drawable fun(key: string): table<string, unknown>?, string?
---@field release fun(key: string)
---@field sceneLayer? fun(): table<string, unknown>?, string?
---@field background? fun(raster: table<string, unknown>): table<string, unknown>?, string?
---@field requestEffect? fun(key: string): boolean?, string?
---@field loadEffect? fun(key: string): table<string, unknown>?, string?
---@field resolveEffectResource? fun(effect: table<string, unknown>, resourceKey: string): table<string, unknown>?, string?
---@field releaseEffectResource? fun(lease: table<string, unknown>): boolean?, string?

---@class BattlePresentationAssets.EffectState
---@field ready boolean true once the staged closure validated
---@field record table<string, unknown>? loaded schema-valid effect record
---@field leases table<integer, table<string, unknown>> outstanding admitted resource leases
---@field failed string? terminal effect failure, latched without retry

---@class BattlePresentationAssets
---@field _assets BattlePresentationAssets.Services preparation services carrying prepare/drawable/release
---@field _launchId string owning launch identity
---@field _sceneKey string semantic scene identity for the demand
---@field _sceneImage string selected scene image key
---@field _sceneLayer table<string, unknown>? staged BG3 payload for the active scene
---@field _audioRoles string[] staged audio role symbols behind the demand
---@field _audioBanks integer[] chosen track bank identities behind the exact demand closure
---@field _frameKey string selected window frame key
---@field _frames table<string, table<string, unknown>>? per-instance frame declarations
---@field _shadowRegions table<integer, table<string, unknown>> normalized Pokepic shadow source rectangles
---@field _state "pending"|"ready"|"failed"
---@field _error string?
---@field _prepared boolean preparation accepted for the current demand
---@field _selectors string[] portrait selectors named so far
---@field _owned table<string, boolean> image keys acquired through this holder
---@field _imageErrors table<string, string> terminal upload failures by key, latched without retry
---@field _effects table<string, BattlePresentationAssets.EffectState> per-effect demand/load/lease state by flat effect key
---@field _effectDrawables table<string, boolean> staged semantic texture keys admitted through effect leases
---@field _picturePass table<string, unknown>? per-screen Pokepic color/depth renderer
---@field _released boolean release guard
local BattlePresentationAssets = {}
BattlePresentationAssets.__index = BattlePresentationAssets

BattlePresentationAssets.DEFAULT_FRAME = "default"

---@class BattlePresentationAssets.Options
---@field assets BattlePresentationAssets.Services preparation services carrying prepare/drawable/release
---@field launchId string owning launch identity
---@field sceneKey string semantic scene identity for the demand
---@field audioRoles string[]? staged audio role symbols behind the demand, none when absent
---@field audioBanks integer[]? chosen track bank identities behind the demand, none when absent
---@field sceneImage string? selected scene image key, derived from the scene key when absent
---@field frameKey string? selected window frame key, the built-in default when absent
---@field frames table<string, table<string, unknown>>? per-instance frame declarations
---@field shadowRegions table<integer, table<string, unknown>> normalized Pokepic shadow source rectangles

---@param opts BattlePresentationAssets.Options
---@return BattlePresentationAssets
function BattlePresentationAssets.new(opts)
  assert(type(opts) == "table", "the resource holder requires options")
  assert(type(opts.assets) == "table", "the resource holder requires its preparation services")
  assert(type(opts.assets.prepare) == "function", "the preparation services prepare demands")
  assert(type(opts.assets.drawable) == "function", "the preparation services resolve drawables")
  assert(type(opts.assets.release) == "function", "the preparation services release handles")
  assert(type(opts.launchId) == "string" and opts.launchId ~= "", "the resource holder needs its launch identity")
  assert(type(opts.sceneKey) == "string" and opts.sceneKey ~= "", "the resource holder needs its scene identity")
  if opts.frameKey ~= nil then
    assert(type(opts.frameKey) == "string" and opts.frameKey ~= "", "the frame selection names its key")
  end
  if opts.frames ~= nil then
    assert(type(opts.frames) == "table", "frame declarations arrive as a keyed record")
  end
  if opts.audioRoles ~= nil then
    assert(type(opts.audioRoles) == "table", "staged audio roles arrive as an array")
  end
  if opts.audioBanks ~= nil then
    assert(type(opts.audioBanks) == "table", "chosen track banks arrive as an array")
  end
  assert(type(opts.shadowRegions) == "table", "staged Pokepic shadow size regions are required")
  return setmetatable({
    _assets = opts.assets,
    _launchId = opts.launchId,
    _sceneKey = opts.sceneKey,
    _audioRoles = opts.audioRoles or {},
    _audioBanks = opts.audioBanks or {},
    _sceneImage = opts.sceneImage or ("scene:" .. opts.sceneKey),
    _sceneLayer = nil,
    _frameKey = opts.frameKey or BattlePresentationAssets.DEFAULT_FRAME,
    _frames = opts.frames,
    _shadowRegions = opts.shadowRegions,
    _state = "pending",
    _error = nil,
    _prepared = false,
    _selectors = {},
    _owned = {},
    _imageErrors = {},
    _effects = {},
    _effectDrawables = {},
    _picturePass = nil,
    _released = false,
  }, BattlePresentationAssets)
end

---@return boolean valid
local function frameDeclared(self)
  if self._frameKey == BattlePresentationAssets.DEFAULT_FRAME then
    return true
  end
  return type(self._frames) == "table" and type(self._frames[self._frameKey]) == "table"
end

---@param key unknown semantic effect key under validation
---@return boolean flat true only for non-empty slash-free keys
local function flatEffectKey(key)
  return type(key) == "string" and key ~= "" and key:find("/", 1, true) == nil
end

---@param self BattlePresentationAssets holder owning the per-effect state
---@param key string flat semantic effect key
---@return BattlePresentationAssets.EffectState mutable per-effect demand/load/lease state
local function effectState(self, key)
  local state = self._effects[key]
  if state == nil then
    state = { ready = false, record = nil, leases = {}, failed = nil }
    self._effects[key] = state
  end
  return state
end

-- Returns every outstanding lease of one effect through the configured
-- release callback, ignoring results: rollback after a terminal upload
-- and launch disposal free exactly what this holder admitted without
-- touching handles owned elsewhere.
---@param self BattlePresentationAssets holder owning the per-effect state
---@param effectKey string flat semantic effect key under release
local function rollbackEffectLeases(self, effectKey)
  local state = self._effects[effectKey]
  if state == nil then
    return
  end
  local releaser = self._assets.releaseEffectResource
  if type(releaser) == "function" then
    for _, lease in ipairs(state.leases) do
      releaser(lease)
    end
  end
  state.leases = {}
end

---@return table<string, unknown> exact launch demand for the preparation services
function BattlePresentationAssets:_demand()
  local selectors = {}
  for _, selector in ipairs(self._selectors) do
    selectors[#selectors + 1] = selector
  end
  local roles = {}
  for _, role in ipairs(self._audioRoles) do
    roles[#roles + 1] = role
  end
  local seenCries, cries = {}, {}
  for _, selector in ipairs(selectors) do
    local species = tostring(selector):match("^([^/]+)")
    if type(species) == "string" and species ~= "" then
      local cry = "cry:" .. species
      if not seenCries[cry] then
        seenCries[cry] = true
        cries[#cries + 1] = cry
      end
    end
  end
  table.sort(cries)
  local banks = {}
  for _, bank in ipairs(self._audioBanks) do
    if type(bank) == "number" then
      banks[#banks + 1] = bank
    end
  end
  table.sort(banks)
  return {
    launchId = self._launchId,
    scenes = { self._sceneKey },
    pages = selectors,
    audio = { roles = roles, banks = banks, cries = cries },
  }
end

-- Image keys the launch always draws: the selected scene, both HUD
-- composites, and all three menu surfaces. Battler portraits stay
-- cue-gated through their side keys instead: their selectors arrive
-- after the opening delivery, so readiness cannot wait on them.
local REQUIRED_DRAWABLES = { "hud:enemy", "hud:player", "menu:command", "menu:moves", "menu:target", "shadow" }

-- Runs preparation once per demand: an invalid frame selection or a
-- service failure becomes failed with context; a missing required image
-- stays pending until its drawable resolves instead of failing. A
-- drawable that answers a terminal upload error fails closed with that
-- key's context and never retries; already acquired handles stay owned
-- until exactly-once disposal.
function BattlePresentationAssets:update()
  if self._state == "failed" or self._state == "ready" then
    return
  end
  if not frameDeclared(self) then
    self._state = "failed"
    self._error = "unknown battle frame: " .. self._frameKey
    return
  end
  if not self._prepared then
    local ok, failure = self._assets.prepare(self:_demand())
    if ok == nil or failure ~= nil then
      self._state = "failed"
      self._error = tostring(failure or "battle preparation failed")
      return
    end
    -- A bare not-yet answer polls again: false without a failure string
    -- means the demand is still preparing. A nil answer, or any answer
    -- carrying a failure string, is a terminal preparation failure and
    -- fails closed with context.
    if ok == false then
      return
    end
    self._prepared = true
  end
  local sceneLayer = nil
  if type(self._assets.sceneLayer) == "function" then
    local layerFailure = nil
    sceneLayer, layerFailure = self._assets.sceneLayer()
    if layerFailure ~= nil then
      self._state = "failed"
      self._error = "battle scene layer failed for launch " .. self._launchId .. ": " .. tostring(layerFailure)
      return
    end
  end
  if sceneLayer ~= nil then
    self._sceneLayer = sceneLayer
  else
    local sceneHandle, sceneFailure = self._assets.drawable(self._sceneImage)
    if sceneFailure ~= nil then
      self._state = "failed"
      self._error = "battle scene image failed for launch " .. self._launchId .. ": " .. tostring(sceneFailure)
      self._imageErrors[self._sceneImage] = self._error --[[@as string]]
      return
    end
    if sceneHandle == nil then
      return
    end
    self._owned[self._sceneImage] = true
  end
  for _, key in ipairs(REQUIRED_DRAWABLES) do
    local handle, failure = self._assets.drawable(key)
    if failure ~= nil then
      self._state = "failed"
      self._error = "battle image failed for launch " .. self._launchId .. ": " .. tostring(failure)
      self._imageErrors[key] = self._error --[[@as string]]
      return
    end
    if handle == nil then
      return
    end
    self._owned[key] = true
  end
  self._state = "ready"
end

-- Names portrait selectors for later demand growth. A genuinely grown
-- set reopens pending until the enlarged exact demand settles on the
-- next update: already leased handles stay owned, terminal failures stay
-- latched, and preparation reruns against the complete new set.
---@param selectors string[]
function BattlePresentationAssets:addSelectors(selectors)
  assert(type(selectors) == "table", "portrait selectors arrive as an array")
  local known = {}
  for _, selector in ipairs(self._selectors) do
    known[selector] = true
  end
  local grown = false
  for _, selector in ipairs(selectors) do
    if type(selector) == "string" and selector ~= "" and not known[selector] then
      known[selector] = true
      self._selectors[#self._selectors + 1] = selector
      grown = true
    end
  end
  if grown and self._state ~= "failed" then
    self._state = "pending"
    self._prepared = false
  end
end

-- Resolves one image through the preparation services, tracking
-- ownership of every handle acquired here. Unavailable images report
-- nil with no error so cues can hold instead of drawing substitutes.
-- A terminal upload error latches the holder failed with the exact
-- image key and replays identically without re-entering the services.
---@param key string image key under resolution
---@return table<string, unknown>? image handle, nil while unavailable or after failure
---@return string? terminal failure naming the exact image key, nil while pending or ready
function BattlePresentationAssets:drawable(key)
  assert(type(key) == "string" and key ~= "", "image resolution names its key")
  if self._imageErrors[key] ~= nil then
    return nil, self._imageErrors[key]
  end
  -- Admitted effect textures resolve verbatim through the services:
  -- an effect-scoped terminal stays scoped to its effect instead of
  -- failing the whole holder and its already-ready scene resources.
  if self._effectDrawables[key] then
    local admitted, admittedFailure = self._assets.drawable(key)
    if admitted ~= nil then
      self._owned[key] = true
    end
    return admitted, admittedFailure
  end
  if self._state == "failed" then
    return nil, self._error
  end
  local handle, failure = self._assets.drawable(key)
  if failure ~= nil then
    self._state = "failed"
    self._error = "battle image " .. key .. " failed for launch " .. self._launchId .. ": " .. tostring(failure)
    self._imageErrors[key] = self._error --[[@as string]]
    return nil, self._error
  end
  if handle ~= nil then
    self._owned[key] = true
  end
  return handle
end

-- Carries the launch identity into an effect failure once: service
-- reasons already naming this launch pass through verbatim so terminal
-- causes replay identically across demand, load, and resolve probes.
---@param reason unknown service cause under diagnosing
---@return string terminal failure naming the launch exactly once
function BattlePresentationAssets:_withLaunch(reason)
  local text = tostring(reason)
  if text:find(self._launchId, 1, true) ~= nil then
    return text
  end
  return text .. " for launch " .. self._launchId
end

-- Demands one lazily staged battle effect by flat semantic key: true
-- only with a schema-valid complete staged closure, false while the
-- worker or any dependency payload is still staging, nil plus a
-- terminal reason on flat-key violations, worker failures, corrupt
-- records, or a latched earlier terminal. Probes never instantiate
-- images; sibling effects stay lazy.
---@param key string flat semantic effect key under demand
---@return boolean? ready true when fully staged, false while pending, nil on terminal failure
---@return string? terminal failure naming effect and launch, nil while pending or ready
function BattlePresentationAssets:demandEffect(key)
  if not flatEffectKey(key) then
    return nil, "unknown battle effect key: " .. tostring(key)
  end
  local effectKey = key --[[@as string]]
  if self._released then
    return nil,
      "battle effect "
        .. effectKey
        .. " is not staged for launch "
        .. self._launchId
        .. ": the battle assets are released"
  end
  local state = effectState(self, effectKey)
  if state.failed ~= nil then
    return nil, state.failed
  end
  if type(self._assets.requestEffect) ~= "function" then
    state.failed = "battle effect "
      .. effectKey
      .. " cannot stage for launch "
      .. self._launchId
      .. ": no configured effect service"
    return nil, state.failed
  end
  local ready, failure = self._assets.requestEffect(effectKey)
  if failure ~= nil then
    state.failed = self:_withLaunch(failure)
    return nil, state.failed
  end
  if ready == true then
    state.ready = true
    return true
  end
  return false
end

-- Loads the exact staged effect record, but only after this holder
-- observed readiness: schema and key identity validate through the
-- configured loader, and a load racing a corrupt publication latches
-- the effect failed instead of handing out a half record.
---@param key string flat semantic effect key under loading
---@return table<string, unknown>? schema-valid effect record, nil unless ready
---@return string? terminal failure naming effect and launch, nil on success
function BattlePresentationAssets:loadEffect(key)
  if not flatEffectKey(key) then
    return nil, "unknown battle effect key: " .. tostring(key)
  end
  local effectKey = key --[[@as string]]
  if self._released then
    return nil,
      "battle effect "
        .. effectKey
        .. " is not staged for launch "
        .. self._launchId
        .. ": the battle assets are released"
  end
  local state = effectState(self, effectKey)
  if state.failed ~= nil then
    return nil, state.failed
  end
  if type(self._assets.loadEffect) ~= "function" then
    state.failed = "battle effect "
      .. effectKey
      .. " cannot stage for launch "
      .. self._launchId
      .. ": no configured effect service"
    return nil, state.failed
  end
  if not state.ready then
    return nil, "battle effect " .. effectKey .. " is not ready for launch " .. self._launchId
  end
  local record, failure = self._assets.loadEffect(effectKey)
  if record == nil then
    state.failed = self:_withLaunch(failure or ("battle effect " .. effectKey .. " is not staged"))
    return nil, state.failed
  end
  state.record = record
  return record
end

-- Resolves one dependency of a loaded effect into a semantic lease:
-- texture leases share one immutable uploaded image across duplicate
-- resolves, other kinds arrive as immutable typed descriptors with no
-- pixels. An upload failure rolls back every handle this holder
-- admitted for the effect and latches it failed; the failure replays
-- identically instead of hanging as pending.
---@param effect table<string, unknown> loaded schema-valid effect record
---@param resourceKey string semantic dependency key under resolving
---@return table<string, unknown>? admitted resource lease, nil on terminal failure
---@return string? terminal failure naming launch, effect, and resource, nil on success
function BattlePresentationAssets:resolveEffectResource(effect, resourceKey)
  if self._released then
    return nil, "battle effect resources are released for launch " .. self._launchId
  end
  if type(effect) ~= "table" or not flatEffectKey(effect.key) then
    return nil, "effect leases resolve from a loaded effect for launch " .. self._launchId
  end
  local effectKey = effect.key --[[@as string]]
  local state = effectState(self, effectKey)
  if state.failed ~= nil then
    return nil, state.failed
  end
  if type(resourceKey) ~= "string" or resourceKey == "" then
    return nil,
      "unknown battle effect resource "
        .. tostring(resourceKey)
        .. " for effect "
        .. effectKey
        .. " for launch "
        .. self._launchId
  end
  if type(self._assets.resolveEffectResource) ~= "function" then
    state.failed = "battle effect "
      .. effectKey
      .. " cannot stage for launch "
      .. self._launchId
      .. ": no configured effect service"
    return nil, state.failed
  end
  if not state.ready or state.record == nil then
    return nil, "battle effect " .. effectKey .. " is not ready for launch " .. self._launchId
  end
  local lease, failure = self._assets.resolveEffectResource(effect, resourceKey)
  if lease == nil then
    rollbackEffectLeases(self, effectKey)
    state.failed = self:_withLaunch(failure or ("battle effect resource " .. resourceKey .. " is not staged"))
    return nil, state.failed
  end
  state.leases[#state.leases + 1] = lease
  if lease.handle ~= nil then
    self._owned[resourceKey] = true
    self._effectDrawables[resourceKey] = true
  end
  return lease
end

-- Returns one admitted effect lease exactly once: the configured
-- service frees the shared image at its last release. Unknown leases
-- and releases without a configured service fail with context.
---@param lease table<string, unknown> admitted resource lease under release
---@return boolean? released true once returned
---@return string? terminal release failure, nil on success
function BattlePresentationAssets:releaseEffectResource(lease)
  if self._released then
    return nil, "battle effect resources are released for launch " .. self._launchId
  end
  if type(lease) ~= "table" or type(lease.key) ~= "string" or lease.key == "" then
    return nil, "effect releases name their lease for launch " .. self._launchId
  end
  if type(self._assets.releaseEffectResource) ~= "function" then
    return nil,
      "battle effect "
        .. tostring(lease.key)
        .. " cannot stage for launch "
        .. self._launchId
        .. ": no configured effect service"
  end
  for _, state in pairs(self._effects) do
    for index, held in ipairs(state.leases) do
      if held == lease then
        table.remove(state.leases, index)
        break
      end
    end
  end
  local released, failure = self._assets.releaseEffectResource(lease)
  if released == nil then
    return nil, self:_withLaunch(failure or ("effect lease " .. tostring(lease.key) .. " is already released"))
  end
  return true
end

---@return string selected scene image key
function BattlePresentationAssets:sceneImage()
  return self._sceneImage
end

---@return table<string, unknown>? staged BG3 payload when a runtime layer is available
function BattlePresentationAssets:sceneLayer()
  return self._sceneLayer
end

---@param raster table<string, unknown> cached BG3 raster from BattleScene
---@return table<string, unknown>? image handle, nil when this host has no mutable layer adapter
---@return string? terminal image failure
function BattlePresentationAssets:background(raster)
  if type(self._assets.background) ~= "function" then
    return nil
  end
  local image, failure = self._assets.background(raster)
  if failure ~= nil then
    self._state = "failed"
    self._error = "battle BG3 image failed for launch " .. self._launchId .. ": " .. tostring(failure)
    return nil, self._error
  end
  if image ~= nil then
    self._owned["battle-background"] = true
  end
  return image
end

-- Renders one source Pokepic plane into this screen's isolated depth target.
---@param graphics table<string, unknown> borrowed graphics namespace
---@param pictures table<integer, table<string, unknown>> visible native picture submissions
---@return table<string, unknown> staged picture color layer
function BattlePresentationAssets:renderPictures(graphics, pictures)
  assert(not self._released, "released battle assets render no pictures")
  if self._picturePass == nil then
    local BattlePicturePass = require("libs.hgss.src.presentation.BattlePicturePass")
    self._picturePass = BattlePicturePass.new(graphics)
  end
  return self._picturePass:render(graphics, pictures)
end

---@param size integer native Pokepic shadow-size selector
---@return table<string, unknown> normalized image rectangle for the selected size
function BattlePresentationAssets:shadowRegion(size)
  assert(type(size) == "number" and size % 1 == 0, "Pokepic shadow size is integral")
  for _, region in ipairs(self._shadowRegions) do
    if region.size == size then
      return region
    end
  end
  error("Pokepic shadow size is not staged: " .. tostring(size), 2)
end

---@return string selected window frame key
function BattlePresentationAssets:frameKey()
  return self._frameKey
end

---@return "pending"|"ready"|"failed"
function BattlePresentationAssets:state()
  return self._state
end

---@return string? failure context, nil unless failed
function BattlePresentationAssets:error()
  return self._error
end

-- Releases each owned handle exactly once, including outstanding
-- effect leases admitted through this holder. Borrowed text and window
-- services are never touched here.
function BattlePresentationAssets:dispose()
  if self._released then
    return
  end
  self._released = true
  for effectKey in pairs(self._effects) do
    rollbackEffectLeases(self, effectKey)
  end
  if self._picturePass ~= nil then
    self._picturePass:release()
    self._picturePass = nil
  end
  for key in pairs(self._owned) do
    self._assets.release(key)
  end
  self._owned = {}
end

return BattlePresentationAssets
