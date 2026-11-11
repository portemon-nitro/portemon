-- Per-launch battle resource leases behind one battle screen. Resolves
-- the selected scene image and window frame through the injected
-- preparation services, tracks exactly the handles acquired here, and
-- reports truthful pending/ready/failed preparation with semantic error
-- context. Frame selection merges per-instance declarations over the one
-- built-in default: an undeclared frame key is an explicit content
-- failure, never a substitution. Borrowed text and window services are
-- never owned here.

local BattlePresentationCache = require("libs.assets.src.battle.BattlePresentationCache")

---@class BattlePresentationAssets.Services
---@field prepare fun(demand: table<string, unknown>): boolean?, string?
---@field headless? boolean explicit data-only composition without native palette image output
---@field drawable fun(key: string): table<string, unknown>?, string?
---@field release fun(key: string)
---@field prepareEvolution (fun(): table<string, unknown>?, string?)? late evolution leaf demand, nil while pending
---@field sceneLayer? fun(): table<string, unknown>?, string?
---@field background? fun(raster: table<string, unknown>): table<string, unknown>?, string?
---@field fadedIntro? fun(raster: table<string, unknown>): table<string, unknown>?, string?
---@field paletteImage? fun(key: string, raster: table<string, unknown>): table<string, unknown>|userdata|nil, string?
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
---@field _evolutionRecord table<string, unknown>? staged evolution leaf record for this launch, nil until ready
---@field _evolutionFailed string? terminal evolution failure, latched without retry
---@field _launchId string owning launch identity
---@field _sceneKey string semantic scene identity for the demand
---@field _background string battle background named by the scene identity
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
---@field _iconKeys string[] party icon selectors named so far
---@field _trainerPictures string[] semantic trainer picture class keys named so far
---@field _battleBalls string[] semantic ball selectors needed by this launch
---@field _owned table<string, boolean> image keys acquired through this holder
---@field _paletteDrawables table<string, { image: table<string, unknown>|userdata, uploadKey: string, raster: table<string, unknown> }> active palette-sampled drawable substitutions
---@field _paletteGeneration integer generation for transactional palette image replacements
---@field _imageErrors table<string, string> terminal upload failures by key, latched without retry
---@field _effects table<string, BattlePresentationAssets.EffectState> per-effect demand/load/lease state by flat effect key
---@field _effectDrawables table<string, boolean> staged semantic texture keys admitted through effect leases
---@field _picturePass table<string, unknown>? per-screen Pokepic color/depth renderer
---@field _released boolean release guard
---@field _headless boolean explicit data-only composition
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
---@field trainerPictures string[]? semantic trainer picture class keys named for this launch
---@field battleBalls string[]? semantic ball selectors needed by this launch

---@param opts BattlePresentationAssets.Options
---@return BattlePresentationAssets
function BattlePresentationAssets.new(opts)
  assert(type(opts) == "table", "the resource holder requires options")
  assert(type(opts.assets) == "table", "the resource holder requires its preparation services")
  assert(type(opts.assets.prepare) == "function", "the preparation services prepare demands")
  assert(type(opts.assets.drawable) == "function", "the preparation services resolve drawables")
  assert(type(opts.assets.release) == "function", "the preparation services release handles")
  assert(opts.assets.headless == nil or type(opts.assets.headless) == "boolean", "headless service mode is explicit")
  assert(type(opts.launchId) == "string" and opts.launchId ~= "", "the resource holder needs its launch identity")
  assert(type(opts.sceneKey) == "string" and opts.sceneKey ~= "", "the resource holder needs its scene identity")
  local scene = BattlePresentationCache.parseSceneKey(opts.sceneKey)
  assert(scene ~= nil, "the resource holder needs a canonical scene identity: " .. opts.sceneKey)
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
    _background = scene.background,
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
    _iconKeys = {},
    _trainerPictures = {},
    _battleBalls = {},
    _evolutionRecord = nil,
    _evolutionFailed = nil,
    _owned = {},
    _paletteDrawables = {},
    _paletteGeneration = 0,
    _imageErrors = {},
    _effects = {},
    _effectDrawables = {},
    _picturePass = nil,
    _released = false,
    _headless = opts.assets.headless == true,
  }, BattlePresentationAssets)
end

---@return boolean headless true when this launch has no native image output capability
function BattlePresentationAssets:isHeadless()
  return self._headless
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
  local iconKeys = {}
  for _, key in ipairs(self._iconKeys) do
    iconKeys[#iconKeys + 1] = key
  end
  local trainerPictures = {}
  for _, classKey in ipairs(self._trainerPictures) do
    trainerPictures[#trainerPictures + 1] = classKey
  end
  local battleBalls = {}
  for _, selector in ipairs(self._battleBalls) do
    battleBalls[#battleBalls + 1] = selector
  end
  return {
    launchId = self._launchId,
    scenes = { self._sceneKey },
    pages = selectors,
    iconKeys = iconKeys,
    trainerPictures = trainerPictures,
    battleBalls = battleBalls,
    audio = { roles = roles, banks = banks, cries = cries },
  }
end

-- Names semantic trainer-class pictures needed by the opening scene.
-- New classes reopen the exact launch demand while retaining existing
-- staged handles.
---@param classKeys string[] semantic trainer class keys
function BattlePresentationAssets:addTrainerPictures(classKeys)
  assert(type(classKeys) == "table", "trainer picture class keys arrive as an array")
  local known = {}
  for _, classKey in ipairs(self._trainerPictures) do
    known[classKey] = true
  end
  local grown = false
  for _, classKey in ipairs(classKeys) do
    assert(type(classKey) == "string", "trainer pictures name semantic selectors")
    local isFront = classKey:match("^front:[A-Z][A-Z0-9_]*$") ~= nil
    local isBack = classKey:match("^back:[A-Z][A-Z0-9_]*$") ~= nil
    assert(isFront or isBack, "trainer pictures name front/back plus a semantic class key")
    if not known[classKey] then
      known[classKey] = true
      self._trainerPictures[#self._trainerPictures + 1] = classKey
      grown = true
    end
  end
  table.sort(self._trainerPictures)
  if grown and self._state ~= "failed" then
    self._state = "pending"
    self._prepared = false
  end
end

-- Names the exact semantic ball sprites needed by active send-out cues.
-- A new ball reopens the launch demand while keeping already staged handles.
---@param selectors string[] semantic `ball:<key>` selectors
function BattlePresentationAssets:addBattleBalls(selectors)
  assert(type(selectors) == "table", "battle ball selectors arrive as an array")
  local known = {}
  for _, selector in ipairs(self._battleBalls) do
    known[selector] = true
  end
  local grown = false
  for _, selector in ipairs(selectors) do
    assert(
      type(selector) == "string" and selector:match("^ball:[A-Z][A-Z0-9_]*$") ~= nil,
      "battle ball selectors name semantic keys"
    )
    if not known[selector] then
      known[selector] = true
      self._battleBalls[#self._battleBalls + 1] = selector
      grown = true
    end
  end
  table.sort(self._battleBalls)
  if grown and self._state ~= "failed" then
    self._state = "pending"
    self._prepared = false
  end
end

-- Names the party icon pages needed by the command menu. Like portraits,
-- icon demand growth reopens preparation without releasing the current
-- ready set; the borrowed field icon owner keeps the page leases.
---@param iconKeys string[] exact canonical icon selectors currently needed
function BattlePresentationAssets:setIconKeys(iconKeys)
  assert(type(iconKeys) == "table", "party icon selectors arrive as an array")
  local nextKeys, known = {}, {}
  for _, key in ipairs(iconKeys) do
    if type(key) == "string" and key ~= "" and not known[key] then
      known[key] = true
      nextKeys[#nextKeys + 1] = key
    end
  end
  table.sort(nextKeys)
  local changed = #nextKeys ~= #self._iconKeys
  if not changed then
    for index, key in ipairs(nextKeys) do
      if self._iconKeys[index] ~= key then
        changed = true
        break
      end
    end
  end
  if changed then
    self._iconKeys = nextKeys
  end
  if changed and self._state ~= "failed" then
    self._state = "pending"
    self._prepared = false
  end
end

-- Image keys the launch always draws: the selected scene, both HUD
-- composites, and all three menu surfaces. Battler portraits stay
-- cue-gated through their side keys instead: their selectors arrive
-- after the opening delivery, so readiness cannot wait on them.
local REQUIRED_DRAWABLES = {
  "hud:enemy",
  "hud:player",
  "menu:command",
  "menu:moves",
  "menu:target",
  "shadow",
}

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
---@return table<string, unknown>|userdata|nil image handle, nil while unavailable or after failure
---@return string? terminal failure naming the exact image key, nil while pending or ready
function BattlePresentationAssets:drawable(key)
  assert(type(key) == "string" and key ~= "", "image resolution names its key")
  -- Lower menu screens resolve the scene background's palette variant.
  local menuScreen = key:match("^(menu:[%a%-]+:screen:%d+):touch$")
  local touch = menuScreen ~= nil and ":touch" or nil
  if menuScreen == nil then
    menuScreen = key:match("^(menu:[%a%-]+:screen:%d+)$")
  end
  if menuScreen ~= nil then
    key = menuScreen .. "@" .. self._background .. (touch or "")
  end
  local paletteDrawable = self._paletteDrawables[key]
  if paletteDrawable ~= nil then
    return paletteDrawable.image
  end
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

-- Publishes a complete keyed palette image set after its uploads succeed.
-- Upload keys are generation-specific so the previous drawable set remains
-- valid until the replacement batch is ready.
---@param requests table<string, { uploadKey: string, raster: table<string, unknown> }> source drawable key to sampled raster request
---@return boolean published
---@return string? failure
function BattlePresentationAssets:updatePaletteDrawables(requests)
  assert(not self._released, "released battle assets publish no palette drawables")
  assert(type(requests) == "table", "palette drawable requests arrive as a keyed record")
  if next(requests) == nil then
    for _, current in pairs(self._paletteDrawables) do
      if self._owned[current.uploadKey] ~= nil then
        self._owned[current.uploadKey] = nil
        self._assets.release(current.uploadKey)
      end
    end
    self._paletteDrawables = {}
    return true
  end
  if self._state == "failed" then
    return false, self._error
  end
  local upload = self._assets.paletteImage
  if type(upload) ~= "function" then
    self._state = "failed"
    self._error = "battle palette image upload service is unavailable for launch " .. self._launchId
    return false, self._error
  end
  -- A batch that changes no key and no raster reuses the published
  -- generation without allocating a new one: no upload, no replacement,
  -- and no release. Obsolete keys still retire only after a successful
  -- replacement below.
  local unchanged = true
  for sourceKey, request in pairs(requests) do
    assert(type(sourceKey) == "string" and sourceKey ~= "", "palette substitutions name their source drawable")
    assert(type(request) == "table", "palette substitution carries its upload request")
    assert(
      type(request.uploadKey) == "string" and request.uploadKey:match("^battle%-palette:") ~= nil,
      "palette upload keys are battle-scoped"
    )
    local raster = request.raster
    assert(
      type(raster) == "table" and type(raster.pixels) == "string",
      "palette image requests carry RGBA8 raster pixels"
    )
    local current = self._paletteDrawables[sourceKey]
    if
      current == nil
      or current.raster.width ~= raster.width
      or current.raster.height ~= raster.height
      or current.raster.pixels ~= raster.pixels
    then
      unchanged = false
      break
    end
  end
  if unchanged then
    for sourceKey in pairs(self._paletteDrawables) do
      if requests[sourceKey] == nil then
        unchanged = false
        break
      end
    end
  end
  if unchanged then
    return true
  end
  self._paletteGeneration = self._paletteGeneration + 1
  local generation = self._paletteGeneration
  local nextDrawables = {}
  local nextKeys = {}
  local newlyUploaded = {}
  for sourceKey, request in pairs(requests) do
    assert(type(sourceKey) == "string" and sourceKey ~= "", "palette substitutions name their source drawable")
    assert(type(request) == "table", "palette substitution carries its upload request")
    assert(
      type(request.uploadKey) == "string" and request.uploadKey:match("^battle%-palette:") ~= nil,
      "palette upload keys are battle-scoped"
    )
    local current = self._paletteDrawables[sourceKey]
    local raster = request.raster
    assert(
      type(raster) == "table" and type(raster.pixels) == "string",
      "palette image requests carry RGBA8 raster pixels"
    )
    if
      current ~= nil
      and current.raster.width == raster.width
      and current.raster.height == raster.height
      and current.raster.pixels == raster.pixels
    then
      nextDrawables[sourceKey] = current
      nextKeys[current.uploadKey] = true
    else
      local uploadKey = request.uploadKey .. ":generation:" .. tostring(generation)
      local image, failure = upload(uploadKey, raster)
      if failure ~= nil or image == nil then
        for rollbackKey in pairs(newlyUploaded) do
          self._assets.release(rollbackKey)
        end
        self._state = "failed"
        self._error = "battle palette image failed for "
          .. sourceKey
          .. " in launch "
          .. self._launchId
          .. ": "
          .. tostring(failure or "upload returned no image")
        return false, self._error
      end
      nextDrawables[sourceKey] = { image = image, uploadKey = uploadKey, raster = raster }
      nextKeys[uploadKey] = true
      newlyUploaded[uploadKey] = true
    end
  end
  for _, current in pairs(self._paletteDrawables) do
    if not nextKeys[current.uploadKey] and self._owned[current.uploadKey] ~= nil then
      self._owned[current.uploadKey] = nil
      self._assets.release(current.uploadKey)
    end
  end
  for uploadKey in pairs(nextKeys) do
    self._owned[uploadKey] = true
  end
  self._paletteDrawables = nextDrawables
  return true
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

-- Polls the late evolution leaf for one committed evolution: the first
-- call demands the bundle through the field services and every pending
-- call repolls the same worker without rerunning a successful load.
-- Success retains exactly one launch-local record; a terminal cause
-- latches and replays identically. Never requests evolution without a
-- committed evolution driving it, and never substitutes art.
---@return table<string, unknown>? staged evolution leaf record, nil while pending
---@return string? terminal evolution failure, nil while pending or ready
function BattlePresentationAssets:ensureEvolution()
  if self._evolutionRecord ~= nil then
    return self._evolutionRecord
  end
  if self._evolutionFailed ~= nil then
    return nil, self._evolutionFailed
  end
  if self._released then
    return nil, "battle evolution is not staged for launch " .. self._launchId .. ": the battle assets are released"
  end
  local prepareEvolution = self._assets.prepareEvolution
  if type(prepareEvolution) ~= "function" then
    self._evolutionFailed = "battle evolution cannot stage for launch "
      .. self._launchId
      .. ": no configured evolution service"
    return nil, self._evolutionFailed
  end
  local record, failure = prepareEvolution()
  if failure ~= nil then
    self._evolutionFailed = self:_withLaunch(failure)
    return nil, self._evolutionFailed
  end
  if record == nil then
    return nil
  end
  self._evolutionRecord = record
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

-- Uploads one composed faded intro raster through the services adapter:
-- nil without an adapter, nil plus a launch-scoped terminal error when
-- a configured upload fails. Successful uploads mark the key owned so
-- disposal returns them exactly once.
---@param raster table<string, unknown> composed RGBA8 intro raster from the battle scene
---@return table<string, unknown>? image handle, nil without an adapter or after failure
---@return string? terminal upload failure, nil without an adapter or on success
function BattlePresentationAssets:fadedIntro(raster)
  if type(self._assets.fadedIntro) ~= "function" then
    return nil
  end
  local image, failure = self._assets.fadedIntro(raster)
  if failure ~= nil or image == nil then
    self._state = "failed"
    self._error = "battle faded intro image failed for launch "
      .. self._launchId
      .. ": "
      .. tostring(failure or "upload returned no image")
    return nil, self._error
  end
  if image ~= nil then
    self._owned["battle-faded-intro"] = true
  end
  return image
end

-- Returns a held faded intro upload mid-launch without a later disposal
-- double-release: the screen calls this when the encounter fade ends so
-- draws fall back to the static intro lease.
function BattlePresentationAssets:releaseFadedIntro()
  if self._owned["battle-faded-intro"] == nil then
    return
  end
  self._owned["battle-faded-intro"] = nil
  if type(self._assets.release) == "function" then
    self._assets.release("battle-faded-intro")
  end
end

-- Delegates one complete typed composition frame to the screen's shared
-- battle pass: native pictures and particle polygons share one exact 3D
-- target, then the private six-plane resolve blends the 2D planes. The
-- pass owns its targets; callers borrow the returned opaque canvas until
-- the next render and never retain or release it.
---@param graphics table<string, unknown> borrowed graphics namespace
---@param frame table<string, unknown> typed composition frame for one engine
---@return table<string, unknown> borrowed opaque logical canvas
function BattlePresentationAssets:renderPictures(graphics, frame)
  assert(not self._released, "released battle assets render no pictures")
  assert(type(frame) == "table" and frame.engine ~= nil, "battle composition renders its typed frame")
  if self._picturePass == nil then
    local BattlePicturePass = require("libs.hgss.src.presentation.BattlePicturePass")
    self._picturePass = BattlePicturePass.new(graphics)
  end
  return self._picturePass:render(graphics, frame)
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
  self._evolutionRecord = nil
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
  self._paletteDrawables = {}
end

return BattlePresentationAssets
