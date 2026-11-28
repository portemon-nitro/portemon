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
---@field fadedIntro? fun(source: table<string, unknown>, palette: string): table<string, unknown>?, string?
---@field paletteImage? fun(key: string, source: table<string, unknown>, palette: string): table<string, unknown>|userdata|nil, string?
---@field requestEffect? fun(key: string): boolean?, string?
---@field loadEffect? fun(key: string): table<string, unknown>?, string?
---@field resolveEffectResource? fun(effect: table<string, unknown>, resourceKey: string): table<string, unknown>?, string?
---@field releaseEffectResource? fun(lease: table<string, unknown>): boolean?, string?
---@field effectSoundBanks? fun(effectKey: string, symbols: string[]): integer[]?, string?
---@field requireEffectBank? fun(bankId: integer): boolean?, string?
---@field releaseEffectBank? fun(bankId: integer)

---@class BattlePresentationAssets.EffectState
---@field ready boolean true once the staged closure validated
---@field record table<string, unknown>? loaded schema-valid effect record
---@field soundBanks integer[]? distinct sound banks the record's named sequences need, projected once
---@field failed string? terminal effect failure, latched without retry

-- One caller's interest in a staged effect: the texture borrows and sound
-- bank interests this hold itself acquired, returned exactly once when the
-- caller closes it (a prediction retiring, an occurrence ending) or when its
-- own acquisition fails terminally.
---@class BattlePresentationAssets.EffectHold
---@field key string flat semantic effect key
---@field leases table<string, unknown>[] texture borrows this hold acquired
---@field banks integer[] sound banks this hold counts an interest in
---@field texturesHeld boolean every declared texture is borrowed
---@field banksEnrolled boolean every named sound bank carries this hold's interest
---@field readyBanks table<integer, boolean> enrolled banks whose required sources this hold saw staged
---@field ready boolean the record, textures, and required sound sources are usable
---@field closed boolean acquisitions already returned

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
---@field _paletteDrawables table<string, { image: table<string, unknown>|userdata, uploadKey: string, source: table<string, unknown>, palette: string }> active palette-sampled drawable substitutions
---@field _paletteGeneration integer generation for transactional palette image replacements
---@field _imageErrors table<string, string> terminal upload failures by key, latched without retry
---@field _effects table<string, BattlePresentationAssets.EffectState> per-effect demand/load state by flat effect key
---@field _effectLeases table<table<string, unknown>, string> outstanding resource lease identities to their effect key
---@field _effectHolds table<BattlePresentationAssets.EffectHold, boolean> open effect holds
---@field _effectBanks table<integer, integer> open hold interests per effect sound bank
---@field _effectDrawables table<string, boolean> staged semantic texture keys admitted through effect leases
---@field _picturePass table<string, unknown>? per-screen Pokepic color/depth renderer
---@field _predicted table<string, BattlePresentationAssets.PredictedEffect> effects staged for the active roster's selectable moves, by key
---@field _predictedOrder string[] predicted keys in staging order
---@field _retiring table<string, BattlePresentationAssets.PredictedEffect> predictions a newer fact dropped, held until the accepted delivery settles
---@field _released boolean release guard
---@field _headless boolean explicit data-only composition
local BattlePresentationAssets = {}
BattlePresentationAssets.__index = BattlePresentationAssets

BattlePresentationAssets.DEFAULT_FRAME = "default"

---@class BattlePresentationAssets.PredictedEffect
---@field hold BattlePresentationAssets.EffectHold this prediction's own effect interest
---@field settled boolean true once the hold is ready or its staging ended terminally

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
    _effectLeases = {},
    _effectHolds = {},
    _effectBanks = {},
    _effectDrawables = {},
    _predicted = {},
    _predictedOrder = {},
    _retiring = {},
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

-- Retail battle mon-menu/summary/check-moves/move-detail page
-- backgrounds ride every launch demand (battle_party_menu.c
-- LoadPageTilemaps): the four semantic page keys stage without
-- invented substitutes. No readiness gate waits on them: a missing page
-- draws nothing at paint time instead of failing the launch.
local PARTY_PAGES = {
  "party:page/check-moves",
  "party:page/mon-menu",
  "party:page/move-detail",
  "party:page/summary",
}

---@param self BattlePresentationAssets holder owning the per-effect state
---@param key string flat semantic effect key
---@return BattlePresentationAssets.EffectState mutable per-effect demand/load/lease state
local function effectState(self, key)
  local state = self._effects[key]
  if state == nil then
    state = { ready = false, record = nil, soundBanks = nil, failed = nil }
    self._effects[key] = state
  end
  return state
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
  local partyPages = {}
  for _, key in ipairs(PARTY_PAGES) do
    partyPages[#partyPages + 1] = key
  end
  return {
    launchId = self._launchId,
    scenes = { self._sceneKey },
    pages = selectors,
    partyPages = partyPages,
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

-- Image keys the launch always draws beside the selected scene: both
-- HUD composites and the shadow. Battler portraits stay cue-gated
-- through their side keys instead: their selectors arrive after the
-- opening delivery, so readiness cannot wait on them. The art an
-- ordinary command's entry points paint first gates that command alone
-- (BattleScreenState), never launch readiness.
local REQUIRED_DRAWABLES = {
  "hud:enemy",
  "hud:player",
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
  -- Party pages stay out of the launch readiness gate on purpose: the
  -- demand still names every staged page so they resolve eagerly, while
  -- the page painter gates on each drawable and draws nothing new while
  -- its background is missing.
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
  -- The live effect resource owns the image; the holder never releases it
  -- through the generic drawable path.
  if self._effectDrawables[key] then
    return self._assets.drawable(key)
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

-- Validates one source-indexed palette substitution request: the source
-- carries its stable identity with immutable index bytes, and the
-- palette carries the exact 256-slot RGBA8 bytes behind the generation.
---@param sourceKey string source drawable key under staging
---@param request table<string, unknown> staged substitution request under staging
local function checkPaletteRequest(sourceKey, request)
  assert(type(sourceKey) == "string" and sourceKey ~= "", "palette substitutions name their source drawable")
  assert(type(request) == "table", "palette substitution carries its upload request")
  assert(
    type(request.uploadKey) == "string" and request.uploadKey:match("^battle%-palette:") ~= nil,
    "palette upload keys are battle-scoped"
  )
  local source = request.source
  assert(type(source) == "table", "palette substitutions carry their immutable source indices")
  assert(type(source.id) == "string" and source.id ~= "", "palette substitutions name their stable source identity")
  assert(
    type(source.width) == "number"
      and source.width % 1 == 0
      and source.width > 0
      and type(source.height) == "number"
      and source.height % 1 == 0
      and source.height > 0
      and type(source.pixels) == "string"
      and #source.pixels == source.width * source.height * 4,
    "palette source indices match their raster dimensions"
  )
  assert(type(request.palette) == "string", "palette substitutions carry their exact palette bytes")
end

-- Publishes a complete keyed source-indexed palette set after its
-- uploads succeed. Upload keys are generation-specific so the previous
-- drawable set remains valid until the replacement batch is ready. An
-- unchanged batch reuses its handles without uploading: only source
-- identity and the exact palette signature compare, never upload keys
-- or composed pixels.
---@param requests table<string, { uploadKey: string, source: table<string, unknown>, palette: string }> source drawable key to source-index request
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
  -- A batch that changes no key, no source identity, and no palette
  -- signature reuses the published generation without allocating a new
  -- one: no upload, no replacement, and no release. Obsolete keys still
  -- retire only after a successful replacement below.
  local unchanged = true
  for sourceKey, request in pairs(requests) do
    checkPaletteRequest(sourceKey, request)
    local current = self._paletteDrawables[sourceKey]
    if current == nil or current.source ~= request.source or current.palette ~= request.palette then
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
  -- Staging walks keys in sorted order so the first failing key is
  -- deterministic. A terminal failure returns the already staged
  -- replacements and leaves the published set untouched.
  local orderedKeys = {}
  for sourceKey in pairs(requests) do
    orderedKeys[#orderedKeys + 1] = sourceKey
  end
  table.sort(orderedKeys)
  for _, sourceKey in ipairs(orderedKeys) do
    local request = requests[sourceKey]
    checkPaletteRequest(sourceKey, request)
    local current = self._paletteDrawables[sourceKey]
    if current ~= nil and current.source == request.source and current.palette == request.palette then
      nextDrawables[sourceKey] = current
      nextKeys[current.uploadKey] = true
    else
      local uploadKey = request.uploadKey .. ":generation:" .. tostring(generation)
      local image, failure = upload(uploadKey, request.source, request.palette)
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
      nextDrawables[sourceKey] =
        { image = image, uploadKey = uploadKey, source = request.source, palette = request.palette }
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
  if state.record ~= nil then
    return state.record
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

-- Resolves one dependency of a loaded effect into a distinct semantic
-- lease: texture leases share one immutable uploaded image across
-- borrows, other kinds arrive as immutable normalized records. A failure
-- latches the effect failed and replays identically instead of hanging as
-- pending; the caller returns only the borrows it acquired itself.
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
    state.failed = self:_withLaunch(failure or ("battle effect resource " .. resourceKey .. " is not staged"))
    return nil, state.failed
  end
  self._effectLeases[lease] = effectKey
  if lease.handle ~= nil then
    self._effectDrawables[resourceKey] = true
  end
  return lease
end

-- Returns one admitted effect lease exactly once by identity: the
-- configured service frees the shared image at its last release. A lease
-- this holder does not hold (unknown or already returned) is refused
-- before anything reaches the service, so it can never consume another
-- borrow's reference.
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
  if self._effectLeases[lease] == nil then
    return nil, self:_withLaunch("effect lease " .. tostring(lease.key) .. " is not held")
  end
  self._effectLeases[lease] = nil
  local released, failure = self._assets.releaseEffectResource(lease)
  if released == nil then
    return nil, self:_withLaunch(failure or ("effect lease " .. tostring(lease.key) .. " is already released"))
  end
  return true
end

---@param record table<string, unknown> loaded schema-valid effect record
---@return string[] distinct named sequence symbols of the lowered program, sorted
local function soundSymbols(record)
  local program = record.program --[[@as table<string, unknown>?]]
  local symbols, seen = {}, {} ---@type string[], table<string, boolean>
  for _, instruction in ipairs(type(program) == "table" and program.instructions or {}) do
    local symbol = type(instruction) == "table" and instruction.sound or nil
    if type(symbol) == "string" and not seen[symbol] then
      seen[symbol] = true
      symbols[#symbols + 1] = symbol
    end
  end
  table.sort(symbols)
  return symbols
end

-- Projects a loaded effect's named sounds onto its distinct sound banks once
-- per effect: a silent effect needs no bank, and an unresolvable named
-- sound latches the effect failed instead of reporting ready.
---@param self BattlePresentationAssets holder owning the per-effect state
---@param key string flat semantic effect key
---@param state BattlePresentationAssets.EffectState loaded effect state
---@return integer[]? banks distinct sound banks, nil on terminal failure
---@return string? terminal failure naming effect and launch
local function effectSoundBanks(self, key, state)
  if state.soundBanks ~= nil then
    return state.soundBanks
  end
  local symbols = soundSymbols(state.record --[[@as table<string, unknown>]])
  if #symbols == 0 then
    state.soundBanks = {}
    return state.soundBanks
  end
  local project = self._assets.effectSoundBanks
  if type(project) ~= "function" then
    state.failed = "battle effect "
      .. key
      .. " cannot stage its sounds for launch "
      .. self._launchId
      .. ": no configured effect audio service"
    return nil, state.failed
  end
  local banks, failure = project(key, symbols)
  if banks == nil then
    state.failed = self:_withLaunch(failure or ("battle effect " .. key .. " sounds have no staged banks"))
    return nil, state.failed
  end
  state.soundBanks = banks
  return banks
end

-- Opens one caller-owned interest in a staged effect. The hold acquires
-- nothing until advanced and returns only what it acquired when closed.
---@param key string flat semantic effect key
---@return BattlePresentationAssets.EffectHold hold open effect interest
function BattlePresentationAssets:openEffectHold(key)
  assert(flatEffectKey(key), "effect holds name flat semantic keys")
  local hold = {
    key = key,
    leases = {},
    banks = {},
    texturesHeld = false,
    banksEnrolled = false,
    readyBanks = {},
    ready = false,
    closed = false,
  }
  self._effectHolds[hold] = true
  return hold
end

-- Returns every acquisition of one hold exactly once: its texture borrows
-- by identity and its sound bank interests, releasing a bank only once no
-- open hold of this launch still needs it.
---@param self BattlePresentationAssets holder owning the hold
---@param hold BattlePresentationAssets.EffectHold hold whose acquisitions return
---@return string? failure first service release failure, nil on success
local function returnHoldAcquisitions(self, hold)
  local firstFailure = nil
  for index = #hold.leases, 1, -1 do
    local lease = hold.leases[index]
    hold.leases[index] = nil
    local released, failure = self:releaseEffectResource(lease)
    if released == nil and firstFailure == nil then
      firstFailure = failure
    end
  end
  for index = #hold.banks, 1, -1 do
    local bankId = hold.banks[index]
    hold.banks[index] = nil
    local left = (self._effectBanks[bankId] or 0) - 1
    if left <= 0 then
      self._effectBanks[bankId] = nil
      local releaseBank = self._assets.releaseEffectBank
      if type(releaseBank) == "function" then
        releaseBank(bankId)
      end
    else
      self._effectBanks[bankId] = left
    end
  end
  hold.texturesHeld = false
  hold.banksEnrolled = false
  hold.readyBanks = {}
  hold.ready = false
  return firstFailure
end

-- Advances one hold toward usability without executing anything: the
-- staged closure is demanded until the worker accepts it, then the hold
-- realizes (its record loads once, every declared texture is borrowed,
-- every named sound bank is enrolled), and each enrolled bank is polled
-- until its required selected sources stage. A hold that may not realize
-- yet stops once its closure is accepted. Pending answers false and keeps
-- what the hold already acquired. A terminal failure latches the effect
-- failed with its original cause and returns this hold's own acquisitions.
---@param self BattlePresentationAssets holder owning the hold
---@param hold BattlePresentationAssets.EffectHold open hold under advancing
---@param mayRealize boolean false defers loading, borrowing, and bank enrollment
---@return boolean? ready true once usable, false while pending, nil on terminal failure
---@return string? terminal failure naming effect and launch
---@return boolean realized true when this call performed the hold's realization
local function advanceHold(self, hold, mayRealize)
  assert(type(hold) == "table" and self._effectHolds[hold], "effect holds advance while open")
  if hold.ready then
    return true, nil, false
  end
  local key = hold.key
  local state = effectState(self, key)
  local realizing = false
  local function fail(failure)
    returnHoldAcquisitions(self, hold)
    return nil, failure, realizing
  end
  if state.failed ~= nil then
    return fail(state.failed)
  end
  if not state.ready then
    local ready, demandFailure = self:demandEffect(key)
    if demandFailure ~= nil then
      return fail(demandFailure)
    end
    if ready ~= true then
      return false, nil, false
    end
  end
  realizing = state.record == nil or not hold.texturesHeld or not hold.banksEnrolled
  if realizing and not mayRealize then
    return false, nil, false
  end
  if state.record == nil then
    local _, loadFailure = self:loadEffect(key)
    if state.record == nil then
      return fail(loadFailure)
    end
  end
  local record = state.record --[[@as table<string, unknown>]]
  if not hold.texturesHeld then
    local declared = record.resources --[[@as table<string, table<string, unknown>>?]]
    local resourceKeys = {} ---@type string[]
    for resourceKey, descriptor in pairs(type(declared) == "table" and declared or {}) do
      if type(descriptor) == "table" and descriptor.kind == "texture" then
        resourceKeys[#resourceKeys + 1] = resourceKey
      end
    end
    table.sort(resourceKeys)
    for _, resourceKey in ipairs(resourceKeys) do
      local lease, failure = self:resolveEffectResource(record, resourceKey)
      if lease == nil then
        return fail(failure)
      end
      hold.leases[#hold.leases + 1] = lease
    end
    hold.texturesHeld = true
  end
  if not hold.banksEnrolled then
    local banks, soundFailure = effectSoundBanks(self, key, state)
    if banks == nil then
      return fail(soundFailure)
    end
    for _, bankId in ipairs(banks) do
      self._effectBanks[bankId] = (self._effectBanks[bankId] or 0) + 1
      hold.banks[#hold.banks + 1] = bankId
    end
    hold.banksEnrolled = true
  end
  -- A staged bank stays staged while this hold's interest retains it, so
  -- only the banks still reading are polled again.
  local pending = false
  for _, bankId in ipairs(hold.banks) do
    if not hold.readyBanks[bankId] then
      local requireBank = self._assets.requireEffectBank
      if type(requireBank) ~= "function" then
        state.failed = "battle effect "
          .. key
          .. " cannot stage its sounds for launch "
          .. self._launchId
          .. ": no configured effect audio service"
        return fail(state.failed)
      end
      local ready, bankFailure = requireBank(bankId)
      if ready == nil or bankFailure ~= nil then
        state.failed = self:_withLaunch(
          "battle effect " .. key .. " sound bank " .. tostring(bankId) .. " failed: " .. tostring(bankFailure)
        )
        return fail(state.failed)
      end
      if ready == true then
        hold.readyBanks[bankId] = true
      else
        pending = true
      end
    end
  end
  if pending then
    return false, nil, realizing
  end
  hold.ready = true
  return true, nil, realizing
end

-- Advances one hold toward usability, realizing it as soon as its staged
-- closure is accepted.
---@param hold BattlePresentationAssets.EffectHold open hold under advancing
---@return boolean? ready true once usable, false while pending, nil on terminal failure
---@return string? terminal failure naming effect and launch
function BattlePresentationAssets:advanceEffectHold(hold)
  local ready, failure = advanceHold(self, hold, true)
  return ready, failure
end

-- Closes one hold, returning exactly what it acquired once. A closed hold
-- stays closed.
---@param hold BattlePresentationAssets.EffectHold hold under closing
---@return boolean? closed true once returned
---@return string? failure first release failure behind the return
function BattlePresentationAssets:closeEffectHold(hold)
  if hold.closed then
    return true
  end
  hold.closed = true
  self._effectHolds[hold] = nil
  if self._released then
    return true
  end
  local failure = returnHoldAcquisitions(self, hold)
  if failure ~= nil then
    return nil, failure
  end
  return true
end

-- Replaces the set of effects the active roster can select next. A key
-- leaving the set keeps its hold while the delivery that carried this fact
-- is still being presented: its accepted events may still play that
-- effect. The screen retires those interests once that delivery settles. A
-- key already predicted, or returning before retirement, keeps its progress.
---@param keys string[] flat semantic effect keys, order irrelevant
function BattlePresentationAssets:setPredictedEffects(keys)
  assert(type(keys) == "table", "predicted effects arrive as an array")
  if self._released then
    return
  end
  local wanted = {} ---@type table<string, boolean>
  for _, key in ipairs(keys) do
    assert(flatEffectKey(key), "predicted effects name flat semantic keys")
    wanted[key] = true
  end
  local order = {} ---@type string[]
  for _, key in ipairs(self._predictedOrder) do
    if wanted[key] then
      order[#order + 1] = key
    else
      self._retiring[key] = self._predicted[key]
      self._predicted[key] = nil
    end
  end
  for _, key in ipairs(keys) do
    if self._predicted[key] == nil then
      local revived = self._retiring[key]
      self._retiring[key] = nil
      self._predicted[key] = revived or { hold = self:openEffectHold(key), settled = false }
      order[#order + 1] = key
    end
  end
  self._predictedOrder = order
end

-- Returns the interests of predictions a newer fact dropped. The screen
-- calls this once the deliveries that could still play them have settled.
function BattlePresentationAssets:retireDroppedPredictions()
  local retiring = self._retiring
  self._retiring = {}
  for _, entry in pairs(retiring) do
    self:closeEffectHold(entry.hold)
  end
end

-- Advances every unsettled predicted effect toward readiness without
-- waiting on any one of them: every still-staging closure keeps its demand
-- enrolled, while at most one accepted effect realizes its record, textures,
-- and sound banks per poll, so closures turning ready together spread their
-- main-thread loading across source ticks. A terminal failure settles the
-- prediction without admitting it: the failure stays latched on the effect
-- and surfaces with provenance only if that effect is ever played.
function BattlePresentationAssets:pollPredictedEffects()
  if self._released then
    return
  end
  local realized = false
  for _, key in ipairs(self._predictedOrder) do
    local entry = self._predicted[key]
    if not entry.settled then
      local ready, failure, didRealize = advanceHold(self, entry.hold, not realized)
      realized = realized or didRealize
      if ready == true or failure ~= nil then
        entry.settled = true
      end
    end
  end
end

---@return boolean ready true once every predicted effect is usable or settled terminally
function BattlePresentationAssets:predictedEffectsReady()
  for _, entry in pairs(self._predicted) do
    if not entry.settled then
      return false
    end
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

---@param raster table<string, unknown> cached stripe raster from the panel task
---@return table<string, unknown>? image handle, nil when this host has no mutable layer adapter
---@return string? terminal image failure
function BattlePresentationAssets:stripeBackground(raster)
  if type(self._assets.background) ~= "function" then
    return nil
  end
  local image, failure = self._assets.background(raster)
  if failure ~= nil then
    self._state = "failed"
    self._error = "battle stripe image failed for launch " .. self._launchId .. ": " .. tostring(failure)
    return nil, self._error
  end
  if image ~= nil then
    self._owned["battle-stripes"] = true
  end
  return image
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

-- Uploads one source-indexed faded intro generation through the services
-- adapter: nil without an adapter, nil plus a launch-scoped terminal
-- error when a configured upload fails. Successful uploads mark the key
-- owned so disposal returns them exactly once.
---@param source table<string, unknown> immutable intro source indices with stable identity
---@param palette string exact 256-slot RGBA8 intro palette bytes
---@return table<string, unknown>? image handle, nil without an adapter or after failure
---@return string? terminal upload failure, nil without an adapter or on success
function BattlePresentationAssets:fadedIntro(source, palette)
  if type(self._assets.fadedIntro) ~= "function" then
    return nil
  end
  assert(type(source) == "table", "the faded intro carries its immutable source indices")
  assert(type(source.id) == "string" and source.id ~= "", "the faded intro names its stable source identity")
  assert(
    type(source.width) == "number"
      and source.width % 1 == 0
      and source.width > 0
      and type(source.height) == "number"
      and source.height % 1 == 0
      and source.height > 0
      and type(source.pixels) == "string"
      and #source.pixels == source.width * source.height * 4,
    "the faded intro source indices match their raster dimensions"
  )
  assert(type(palette) == "string", "the faded intro carries its exact palette bytes")
  local image, failure = self._assets.fadedIntro(source, palette)
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

-- Releases each owned handle exactly once, including every outstanding
-- effect lease and sound bank interest admitted through this holder. Borrowed text and window
-- services are never touched here.
function BattlePresentationAssets:dispose()
  if self._released then
    return
  end
  self._released = true
  self._evolutionRecord = nil
  local releaseLease = self._assets.releaseEffectResource
  if type(releaseLease) == "function" then
    for lease in pairs(self._effectLeases) do
      releaseLease(lease)
    end
  end
  local releaseBank = self._assets.releaseEffectBank
  if type(releaseBank) == "function" then
    for bankId in pairs(self._effectBanks) do
      releaseBank(bankId)
    end
  end
  for hold in pairs(self._effectHolds) do
    hold.closed = true
  end
  self._effectLeases = {}
  self._effectBanks = {}
  self._effectHolds = {}
  self._predicted = {}
  self._predictedOrder = {}
  self._retiring = {}
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
