-- Field-local presented-battle adapter. One envelope per field lifetime owns
-- cover and readiness while delegating each launch to a live per-launch
-- battle screen built through its bindable factory. It never chooses
-- moves, generates opponents, interprets raw battle graphics, or publishes
-- party, bag, or money consequences: the field runtime owns the launch
-- machine and receipts, the battle runtime owns mechanics and publication,
-- and the blackout flow owns defeat recovery. Draw calls are read-only;
-- the fixed clock is the only thing that advances presentation.

local BattlePresentationCache = require("libs.assets.src.battle.BattlePresentationCache")
local BattlePresentationModel = require("game.hgss.src.battle.BattlePresentationModel")
local BattleScreenState = require("game.hgss.src.battle.BattleScreenState")
local MonCache = require("libs.assets.src.MonCache")
local PngWriter = require("libs.assets.src.PngWriter")

---@class FieldBattlePresentation
---@field _cacheFs table<string, unknown> versioned derived cache behind demand validation
---@field _text table<string, unknown> borrowed text services behind plan rendering
---@field _windows table<string, unknown> borrowed window services behind plan rendering
---@field _screenAudio table<string, unknown> semantic cue-audio boundary behind the screen
---@field _itemCatalog table<string, unknown>? borrowed immutable item catalog behind battle bag grouping
---@field _monCatalog table<string, unknown>? borrowed immutable mon catalog behind machine display facts
---@field _images table<string, unknown> owned image handles behind the live screen
---@field _measureDisplay fun(): table<string, unknown> live display facts
---@field _graphics table<string, unknown>? host graphics namespace enabling GPU upload, nil for data descriptors
---@field _manifest table<string, unknown> staged or planning presentation manifest
---@field _services table<string, unknown> cache-backed preparation services carrying prepare/drawable/release
---@field _preparedDemands table<integer, table<string, unknown>> exact launch demands requested, in order
---@field _portraitPages table<string, string> latest demanded portrait page per facing
---@field _recording table<string, unknown> host-safe recording graphics behind the per-tick refresh
---@field _launchId string? active launch identity, nil outside launches
---@field _descriptor table<string, unknown>? active launch descriptor from the runtime
---@field _recoveryPointerId string|number|nil pending recovery press identity awaiting its release
---@field _screen table<string, unknown>? live per-launch battle screen
---@field _port table<string, unknown>? live five-operation port behind the owned battle
---@field _lastStatus table<string, unknown>? latest observed launch status snapshot
---@field _cover integer current opaque-black cover coefficient on the 0..16 scale
---@field _accumulator number source-frame time held toward the next cover step
---@field _revealingBattle boolean true once the constructed battle starts its reveal
---@field _musicStarted boolean true once battle music was attempted for the launch
---@field _musicNote string? battle-music start outcome for launch diagnostics
---@field _drewExternally boolean true once an outer owner drew this frame
---@field _disposed boolean
local FieldBattlePresentation = {}
FieldBattlePresentation.__index = FieldBattlePresentation

FieldBattlePresentation.COVER_MAX = 16
FieldBattlePresentation.COVER_STEP = 2
FieldBattlePresentation.COVER_COLOR = 0
FieldBattlePresentation.SOURCE_FRAME = 1 / 30
FieldBattlePresentation.SOURCE_EPSILON = 1e-12
FieldBattlePresentation.MAX_CATCH_UP = 6

---@class FieldBattlePresentation.Options
---@field cacheFs table<string, unknown> versioned derived cache behind demand validation
---@field windows table<string, unknown> borrowed window services behind plan rendering
---@field text table<string, unknown> borrowed text services behind plan rendering
---@field audio table<string, unknown>? semantic cue-audio boundary behind the screen
---@field measureDisplay fun(): table<string, unknown> live display facts
---@field graphics table<string, unknown>? host graphics namespace enabling GPU upload, nil for data descriptors
---@field itemCatalog table<string, unknown>? borrowed immutable item catalog behind battle bag grouping
---@field monCatalog table<string, unknown>? borrowed immutable mon catalog behind machine display facts
---@field overrides table<string, unknown>? per-instance scene, frame, and case inputs

---@return table<string, unknown> silent cue sink used when no audio boundary is composed
local function nullAudio()
  local function play(_)
    return true
  end
  return {
    play = play,
  }
end

---@param cacheFs table<string, unknown>
---@return table<string, unknown> staged manifest, or the planning inventory before staging
local function loadManifest(cacheFs)
  return BattlePresentationCache.load(cacheFs)
end

-- Expands one demand portrait key to the canonical staged selectors it
-- may resolve to. Screen keys name species, numeric form, and facing; the
-- staged manifest carries gender and shininess variants, so one screen key
-- expands to its four canonical candidates. Already-canonical keys pass
-- through untouched.
---@param pageKey string demand portrait key under expansion
---@return string[] canonical staged selectors
local function expandPortraitKey(pageKey)
  local species, form, facing = tostring(pageKey):match("^([^/]+)/([0-9]+)/([a-z]+)$")
  if species == nil or form == nil or (facing ~= "front" and facing ~= "back") then
    return { pageKey }
  end
  local expanded = {}
  for _, gender in ipairs({ "male", "female" }) do
    for _, finish in ipairs({ "plain", "shiny" }) do
      local selector = species .. "/f" .. form .. "/" .. gender .. "/" .. finish
      if facing == "back" then
        selector = selector .. "/back"
      end
      expanded[#expanded + 1] = selector
    end
  end
  return expanded
end

---@param cacheFs table<string, unknown>
---@param pageKey string demand portrait key under validation
---@return boolean valid
---@return string? reason
local function checkPortraitKey(cacheFs, pageKey)
  local portraits = cacheFs:loadLua(MonCache.portraitManifestPath())
  if type(portraits) ~= "table" or type(portraits.entries) ~= "table" then
    return false, "battle demand needs its staged portrait manifest: " .. tostring(pageKey)
  end
  local entries = portraits.entries --[[@as table<string, table<string, unknown>>]]
  local index = cacheFs:loadLua(MonCache.indexPath())
  if type(index) ~= "table" or type(index.portraitPages) ~= "table" then
    return false, "battle demand needs its staged mon page markers: " .. tostring(pageKey)
  end
  local markers = index.portraitPages --[[@as table<integer, string>]]
  for _, selector in ipairs(expandPortraitKey(pageKey)) do
    local entry = entries[selector]
    if type(entry) ~= "table" or type(entry.pageId) ~= "number" then
      return false, "battle demand names an unstaged portrait: " .. tostring(selector)
    end
    local pageId = entry.pageId --[[@as integer]]
    if not MonCache.isPageReady(cacheFs, "portraits", pageId, markers[pageId + 1]) then
      return false, "battle portrait page is not staged: " .. tostring(selector)
    end
  end
  return true
end

---@return table<string, unknown> host-safe recording graphics logging image draws
local function recordingGraphics()
  local recording = { draws = {} }
  function recording.push(_) end
  function recording.pop() end
  function recording.origin() end
  function recording.intersectScissor(_, _, _, _) end
  function recording.translate(_, _) end
  function recording.scale(_, _) end
  function recording.transformPoint(x, y)
    return x, y
  end
  function recording.getColor()
    return 1, 1, 1, 1
  end
  function recording.setColor(_, _, _, _) end
  function recording.rectangle(_, _, _, _, _) end
  function recording.newQuad(x, y, w, h, imgW, imgH)
    return { x = x, y = y, w = w, h = h, imgW = imgW, imgH = imgH }
  end
  function recording.draw(drawable, quad, x, y)
    if type(quad) == "number" then
      quad, x, y = nil, quad, x
    end
    local key = drawable
    if type(drawable) == "table" then
      key = drawable.key or drawable.handle or tostring(drawable)
    end
    recording.draws[#recording.draws + 1] = { key = key, quad = quad, x = x, y = y }
  end
  return recording
end

---@param opts FieldBattlePresentation.Options
---@return FieldBattlePresentation
function FieldBattlePresentation.new(opts)
  assert(type(opts) == "table", "the presented battle envelope requires options")
  assert(opts.cacheFs ~= nil, "the presented battle envelope requires its cache")
  assert(type(opts.windows) == "table", "the presented battle envelope borrows its window services")
  assert(type(opts.text) == "table", "the presented battle envelope borrows its text services")
  assert(type(opts.measureDisplay) == "function", "the presented battle envelope needs its display facts")
  if opts.graphics ~= nil then
    assert(type(opts.graphics) == "table", "the graphics namespace arrives as a record")
  end
  local envelope = setmetatable({
    _cacheFs = opts.cacheFs,
    _text = opts.text,
    _windows = opts.windows,
    _screenAudio = opts.audio or nullAudio(),
    _measureDisplay = opts.measureDisplay,
    _graphics = opts.graphics,
    _itemCatalog = opts.itemCatalog,
    _monCatalog = opts.monCatalog,
    _overrides = opts.overrides or {},
    _manifest = loadManifest(opts.cacheFs),
    _preparedDemands = {},
    _portraitPages = {},
    _launchId = nil,
    _descriptor = nil,
    _recoveryPointerId = nil,
    _screen = nil,
    _port = nil,
    _lastStatus = nil,
    _cover = 0,
    _accumulator = 0,
    _revealingBattle = false,
    _musicStarted = false,
    _musicNote = nil,
    _drewExternally = false,
    _disposed = false,
    _images = {},
  }, FieldBattlePresentation)
  envelope._recording = recordingGraphics()
  envelope._services = envelope:_preparationServices()
  return envelope
end

-- Uploads one staged image file through the host graphics namespace:
-- decode the staged bytes, then build and configure the owned image.
-- Any decode or upload failure answers nil so the caller holds instead
-- of drawing substitutes; only prepare owns typed failures.
---@param graphics table<string, unknown> host graphics namespace enabling GPU upload
---@param path string cache-relative staged image path behind diagnostics
---@param bytes string staged image bytes
---@return table<string, unknown>? owned image handle, nil while unavailable
local function uploadStaged(graphics, path, bytes)
  local ok, image = pcall(function()
    local pixels = love.image.newImageData(love.filesystem.newFileData(bytes, path))
    local uploaded = graphics.newImage(pixels)
    uploaded:setFilter("nearest", "nearest")
    return uploaded
  end)
  if not ok then
    return nil
  end
  return image
end

-- Uploads one staged portrait cell for a canonical portrait selector:
-- decode the owning atlas page, crop exactly the staged cell, then
-- build and configure the owned image. Any failure answers nil so the
-- caller holds instead of drawing substitutes.
---@param graphics table<string, unknown> host graphics namespace enabling GPU upload
---@param cacheFs table<string, unknown> versioned derived cache behind demand validation
---@param selector string canonical staged portrait selector
---@return table<string, unknown>? owned image handle, nil while unavailable
local function uploadPortraitCell(graphics, cacheFs, selector)
  local ok, image = pcall(function()
    local portraits = cacheFs:loadLua(MonCache.portraitManifestPath())
    assert(
      type(portraits) == "table" and type(portraits.entries) == "table",
      "the staged portrait manifest is unavailable"
    )
    local entry = portraits.entries[selector]
    assert(type(entry) == "table", "the staged manifest plans no such portrait: " .. tostring(selector))
    assert(type(entry.pageId) == "number", "the staged portrait names its page: " .. tostring(selector))
    assert(
      type(entry.x) == "number" and type(entry.y) == "number",
      "the staged portrait names its cell origin: " .. tostring(selector)
    )
    assert(
      type(entry.width) == "number" and type(entry.height) == "number",
      "the staged portrait names its cell size: " .. tostring(selector)
    )
    local path = MonCache.pageImagePath("portraits", entry.pageId)
    local bytes = cacheFs:read(path)
    assert(type(bytes) == "string", "the staged portrait page is not staged: " .. tostring(path))
    local page = love.image.newImageData(love.filesystem.newFileData(bytes, path))
    local cropped = love.image.newImageData(entry.width, entry.height)
    cropped:paste(page, 0, 0, entry.x, entry.y, entry.width, entry.height)
    local uploaded = graphics.newImage(cropped)
    uploaded:setFilter("nearest", "nearest")
    return uploaded
  end)
  if not ok then
    return nil
  end
  return image
end

-- Resolves one menu or HUD drawable key to its staged image path through
-- the verified manifest. Per-control artwork has no staged counterpart
-- and resolves to nothing so those controls draw labels only. A
-- planning manifest stages nothing and resolves nothing.
---@param envelope FieldBattlePresentation
---@param key string drawable key under resolution
---@return string? cache-relative staged image path, nil without a staged counterpart
local function stagedArtPath(envelope, key)
  local manifest = envelope._manifest
  if type(manifest) ~= "table" or manifest.verified ~= true then
    return nil
  end
  if key == "hud:enemy" then
    return type(manifest.enemyHud) == "table" and manifest.enemyHud.image or nil
  end
  if key == "hud:player" then
    return type(manifest.playerHud) == "table" and manifest.playerHud.image or nil
  end
  if key == "menu:command" then
    return type(manifest.command) == "table" and manifest.command.image or nil
  end
  if key == "menu:moves" then
    return type(manifest.moves) == "table" and manifest.moves.image or nil
  end
  if key == "menu:target" then
    return type(manifest.target) == "table" and manifest.target.image or nil
  end
  if key == "arrow" then
    return type(manifest.arrow) == "table" and manifest.arrow.image or nil
  end
  -- Both interaction-pane gauge rows use the 16-pixel family: no roster
  -- state selects the 32-pixel family, which stays staged but unused.
  if key == "gauges:player" or key == "gauges:enemy" then
    local family = type(manifest.partyGauges) == "table" and manifest.partyGauges[1] or nil
    return type(family) == "table" and family.image or nil
  end
  return nil
end

-- Resolves one battler-side drawable key to its canonical staged
-- portrait selector through the latest demanded portrait page for that
-- facing. The first expanded candidate is the deterministic male/plain
-- variant prepare already validated; a facing with no demanded page
-- resolves to nothing so cues hold until the demand names it.
---@param envelope FieldBattlePresentation
---@param key string battler-side drawable key under resolution
---@return string? canonical staged portrait selector, nil while undemanded
local function sidePortraitSelector(envelope, key)
  local facing = nil
  if key == "mon:enemy:front" then
    facing = "front"
  elseif key == "mon:player:back" then
    facing = "back"
  end
  if facing == nil then
    return nil
  end
  local pages = envelope._portraitPages
  local pageKey = type(pages) == "table" and pages[facing] or nil
  if type(pageKey) ~= "string" or pageKey == "" then
    return nil
  end
  local expanded = expandPortraitKey(pageKey)
  return expanded[1]
end

-- Records the latest demanded portrait page per facing so battler-side
-- drawables resolve to the current combatants. Later demands overwrite
-- earlier ones, so replacements move the side pictures without a second
-- upload path.
---@param envelope FieldBattlePresentation
---@param demand table<string, unknown> exact launch demand under tracking
local function trackPortraitPages(envelope, demand)
  local pages = demand.pages
  if type(pages) ~= "table" then
    return
  end
  for _, pageKey in ipairs(pages) do
    local facing = tostring(pageKey):match("^[^/]+/[0-9]+/([a-z]+)$")
    if facing == "front" or facing == "back" then
      envelope._portraitPages[facing] = pageKey
    end
  end
end

-- Validates the demanded audio members against the staged manifest
-- roles: every demanded role must be one of the staged wild, trainer,
-- rival, or select symbols. Banks and cries ride the demand for
-- exactness; without the normalized audio membership in presentation
-- scope only their shape is checked here.
---@param envelope FieldBattlePresentation
---@param demand table<string, unknown> exact launch demand under validation
---@return string? reason, nil when the audio members validate
local function checkAudioMembers(envelope, demand)
  local manifest = envelope._manifest
  if type(manifest) ~= "table" or manifest.verified ~= true then
    return "battle presentation is not staged: the launch needs its staged menu, HUD, font, and audio roles"
  end
  local audio = demand.audio or { roles = {}, banks = {}, cries = {} }
  if type(audio) ~= "table" then
    return "battle demands carry their audio roles"
  end
  local stagedRoles = {}
  if type(manifest.audioRoles) == "table" then
    for _, role in ipairs({ "wild", "trainer", "rival", "select" }) do
      if type(manifest.audioRoles[role]) == "string" then
        stagedRoles[manifest.audioRoles[role]] = true
      end
    end
  end
  if type(audio.roles) ~= "table" then
    return "battle demands carry their audio roles"
  end
  for _, role in ipairs(audio.roles) do
    if type(role) ~= "string" or role == "" then
      return "battle audio roles must be non-empty strings"
    end
    if not stagedRoles[role] then
      return "battle demand names an unstaged audio role: " .. tostring(role)
    end
  end
  if type(audio.banks) ~= "table" then
    return "battle demands carry their audio banks"
  end
  for _, bank in ipairs(audio.banks) do
    if type(bank) ~= "number" then
      return "battle audio banks must be bank identities"
    end
  end
  if type(audio.cries) ~= "table" then
    return "battle demands carry their audio cries"
  end
  for _, cry in ipairs(audio.cries) do
    if type(cry) ~= "string" or cry == "" then
      return "battle audio cries must be non-empty strings"
    end
  end
  return nil
end

-- Validates the staged menu, HUD, and font members behind the launch:
-- every drawable the renderers reach for must have its staged image,
-- and every manifest text role must have its staged font definition.
-- The borrowed field text renderer owns font pixels; this checks the
-- staged definitions the roles reference.
---@param envelope FieldBattlePresentation
---@return string? reason, nil when the staged members validate
local function checkStagedMembers(envelope)
  local manifest = envelope._manifest
  if type(manifest) ~= "table" or manifest.verified ~= true then
    return "battle presentation is not staged: the launch needs its staged menu, HUD, font, and audio roles"
  end
  local cacheFs = assert(envelope._cacheFs, "preparation requires the envelope cache")
  local required = {
    { key = "menu:command", path = type(manifest.command) == "table" and manifest.command.image or nil },
    { key = "menu:moves", path = type(manifest.moves) == "table" and manifest.moves.image or nil },
    { key = "menu:target", path = type(manifest.target) == "table" and manifest.target.image or nil },
    { key = "hud:enemy", path = type(manifest.enemyHud) == "table" and manifest.enemyHud.image or nil },
    { key = "hud:player", path = type(manifest.playerHud) == "table" and manifest.playerHud.image or nil },
  }
  for _, entry in ipairs(required) do
    local bytes = type(entry.path) == "string" and cacheFs:read(entry.path) or nil
    if type(bytes) ~= "string" or #bytes == 0 then
      return "battle menu art is not staged: " .. tostring(entry.key)
    end
  end
  if type(manifest.textRoles) ~= "table" then
    return "battle presentation is not staged: the launch needs its staged font roles"
  end
  for _, role in ipairs({ "narration", "menu", "hud" }) do
    local record = manifest.textRoles[role]
    local font = type(record) == "table" and record.font or nil
    if type(font) ~= "string" or type(cacheFs:read(font)) ~= "string" then
      return "battle font is not staged: " .. tostring(role)
    end
  end
  return nil
end

-- The cache-backed preparation services behind one envelope: prepare
-- validates the exact launch demand against the staged or planning
-- manifest, the portrait manifest and page markers, and -- where pixels
-- are actually required -- the staged menu, HUD, font, and audio
-- members; drawable resolves validated handles through the owned image
-- cache without ever inventing a second uploader; release forgets owned
-- handles exactly once. Missing staged scene pixels stay pending as data
-- descriptors in headless composition and fail closed only where pixels
-- are actually required.
---@return table<string, unknown> preparation services carrying prepare/drawable/release
function FieldBattlePresentation:_preparationServices()
  local envelope = self
  local cacheFs = assert(self._cacheFs, "preparation requires the envelope cache")
  local graphics = self._graphics
  local images = self._images --[[@as table<string, unknown>]]
  local services = {}
  function services.prepare(demand)
    if type(demand) ~= "table" then
      return nil, "battle demands arrive as records"
    end
    envelope._preparedDemands[#envelope._preparedDemands + 1] = demand
    trackPortraitPages(envelope, demand)
    for _, sceneKey in ipairs(demand.scenes or {}) do
      if BattlePresentationCache.parseSceneKey(sceneKey) == nil then
        return nil, "unknown battle scene key: " .. tostring(sceneKey)
      end
      if graphics ~= nil then
        local record, recordErr = BattlePresentationCache.loadScene(cacheFs, sceneKey)
        if record == nil then
          return nil, tostring(recordErr or ("no staged battle scene for " .. sceneKey))
        end
        local bytes = cacheFs:read(BattlePresentationCache.sceneImagePath(sceneKey))
        if type(bytes) ~= "string" or #bytes ~= PngWriter.encodedSize(record.canvasWidth, record.canvasHeight) then
          return nil, "battle scene image is not staged: " .. tostring(sceneKey)
        end
      end
    end
    for _, page in ipairs(demand.pages or {}) do
      if type(page) ~= "string" or page == "" then
        return nil, "portrait selectors must be non-empty strings"
      end
      local okPage, pageErr = checkPortraitKey(cacheFs, page)
      if not okPage then
        return nil, pageErr
      end
    end
    -- Menu, HUD, font, and audio members are required only where
    -- pixels are actually required: headless composition keeps its
    -- descriptor behavior so recording views prove without staged art.
    if graphics ~= nil then
      local stagedErr = checkStagedMembers(envelope)
      if stagedErr ~= nil then
        return nil, stagedErr
      end
      local audioErr = checkAudioMembers(envelope, demand)
      if audioErr ~= nil then
        return nil, audioErr
      end
    end
    return true
  end
  function services.drawable(key)
    assert(type(key) == "string" and key ~= "", "image resolution names its key")
    if images[key] ~= nil then
      return images[key]
    end
    if graphics == nil then
      -- Data descriptors carry the validated staged identity without
      -- GPU objects: the recording boundary proves views while pixels
      -- stay unstaged in headless composition.
      return { kind = "staged", key = key }
    end
    -- Production drawables are real owned handles or nothing: a plain
    -- table here would raise in host graphics, so unavailable images
    -- answer nil and cues hold instead of drawing substitutes.
    local sceneKey = tostring(key):match("^scene:(.+)$")
    if sceneKey ~= nil then
      local bytes = cacheFs:read(BattlePresentationCache.sceneImagePath(sceneKey))
      if type(bytes) ~= "string" then
        return nil
      end
      local image = uploadStaged(graphics, BattlePresentationCache.sceneImagePath(sceneKey), bytes)
      if image == nil then
        return nil
      end
      images[key] = image
      return image
    end
    local artPath = stagedArtPath(envelope, key)
    if artPath ~= nil then
      local bytes = cacheFs:read(artPath)
      if type(bytes) ~= "string" then
        return nil
      end
      local image = uploadStaged(graphics, artPath, bytes)
      if image == nil then
        return nil
      end
      images[key] = image
      return image
    end
    local selector = sidePortraitSelector(envelope, key)
    if selector ~= nil then
      local portrait = uploadPortraitCell(graphics, cacheFs, selector)
      if portrait == nil then
        return nil
      end
      images[key] = portrait
      return portrait
    end
    return nil
  end
  function services.release(key)
    images[key] = nil
  end
  return services
end

---@return table<integer, table<string, unknown>> exact launch demands requested, in order
function FieldBattlePresentation:preparedDemands()
  return self._preparedDemands
end

-- The bindable per-launch factory: each descriptor builds one fresh port
-- backed by one fresh battle screen. Construction failures release partial
-- resources and never return a half-valid port.
---@return fun(descriptor: table<string, unknown>): table<string, unknown>
function FieldBattlePresentation:factory()
  local envelope = self
  local function buildPort(descriptor)
    return envelope:_buildPort(descriptor)
  end
  return buildPort
end

-- Adapts one launch behind the screen-owned one-argument cue sink.
-- A method-based production controller resolves `select` to the staged
-- interface role and `cry:<species>` to the numeric species cry; every
-- other role is an explicit failure with launch context. An injected
-- semantic sink (no cry voice of its own) passes through untouched for
-- the deliberate headless contract, never as a production fallback.
---@param launchId string owning launch identity behind failure context
---@return table<string, unknown> one-argument cue sink behind the screen
function FieldBattlePresentation:_screenAudioFor(launchId)
  local controller = self._screenAudio
  if type(controller.playCry) ~= "function" then
    return controller
  end
  local manifest = self._manifest
  local monCatalog = self._monCatalog
  local function play(role)
    assert(type(role) == "string" and role ~= "", "battle cues name their sound role")
    if role == "select" then
      local audioRoles = type(manifest) == "table" and manifest.audioRoles or nil
      assert(type(audioRoles) == "table", "battle sound needs its staged select role for launch " .. launchId)
      local symbol = audioRoles.select
      assert(
        type(symbol) == "string" and symbol ~= "",
        "battle sound needs its staged select role for launch " .. launchId
      )
      return controller:play(symbol)
    end
    local speciesKey = role:match("^cry:(.+)$")
    if speciesKey ~= nil then
      assert(monCatalog ~= nil, "battle cries need their mon catalog for launch " .. launchId)
      local facts = monCatalog:species(speciesKey)
      assert(
        type(facts) == "table" and type(facts.nativeId) == "number",
        "battle cries name a cataloged species for launch " .. launchId .. ": " .. tostring(role)
      )
      return controller:playCry(facts.nativeId, 0)
    end
    error("unknown battle sound role for launch " .. launchId .. ": " .. tostring(role), 0)
  end
  return { play = play }
end

---@param descriptor table<string, unknown> detached launch descriptor from the runtime
---@return table<string, unknown> fresh five-operation port behind a fresh screen
function FieldBattlePresentation:_buildPort(descriptor)
  assert(type(descriptor) == "table", "presentation factories take a launch descriptor")
  assert(
    type(descriptor.launchId) == "string" and descriptor.launchId ~= "",
    "presentation factories take the launch identity"
  )
  assert(type(descriptor.environment) == "table", "presentation factories take the launch environment")
  assert(not self._disposed, "the presented battle envelope is disposed")
  assert(self._launchId == nil, "the envelope owns one launch at a time")
  local environment = descriptor.environment --[[@as table<string, unknown>]]
  local sceneKey = environment.sceneKey
  assert(type(sceneKey) == "string" and sceneKey ~= "", "launch environments resolve their scene identity")
  local manifest = self._manifest
  local sceneKnown = false
  if type(manifest) == "table" and type(manifest.scenes) == "table" then
    for _, entry in ipairs(manifest.scenes) do
      if type(entry) == "table" and entry.key == sceneKey then
        sceneKnown = true
        break
      end
    end
  end
  assert(sceneKnown, "launch scene is outside the presentation inventory: " .. tostring(sceneKey))
  local host = descriptor.host
  local function submit(reply)
    if host == nil then
      return false, { message = "the presented launch carries no host" }
    end
    return host.submit(reply)
  end
  local screen = BattleScreenState.new({
    launchId = descriptor.launchId,
    manifest = manifest,
    model = BattlePresentationModel,
    submit = submit,
    measureDisplay = self._measureDisplay,
    assets = self._services,
    text = self._text,
    windows = self._windows,
    audio = self:_screenAudioFor(descriptor.launchId),
    itemCatalog = self._itemCatalog,
    monCatalog = self._monCatalog,
    overrides = { sceneKey = sceneKey },
  })
  self._launchId = descriptor.launchId
  self._descriptor = descriptor
  self._screen = screen
  self._port = screen:presentationPort()
  self._lastStatus = nil
  self._cover = 0
  self._accumulator = 0
  self._revealingBattle = false
  self._musicStarted = false
  self._musicNote = nil
  return self._port
end

---@return table<string, unknown>? live per-launch battle screen, nil after its port disposes
function FieldBattlePresentation:liveScreen()
  local screen = self._screen
  if screen == nil then
    return nil
  end
  local ok, status = pcall(function()
    return screen:status()
  end)
  if not ok or type(status) ~= "table" or status.mode == "disposed" then
    return nil
  end
  return screen
end

---@return { coefficient: integer, color: integer } opaque-black cover status, 16 fully opaque
function FieldBattlePresentation:cover()
  return { coefficient = self._cover, color = FieldBattlePresentation.COVER_COLOR }
end

---@return boolean true while a presented launch holds field input and foreground
function FieldBattlePresentation:ownsInput()
  if self._launchId == nil then
    return false
  end
  local status = self._lastStatus
  return status == nil or status.phase ~= "transfer"
end

-- Routes one semantic input batch to the live battle or child. While the
-- owned launch recovers through its defeat message, genuine edges answer
-- that wait instead: confirm acts, cancel cancels, and only a pointer
-- release matching its press taps. The disposed battle screen never sees
-- recovery input, and recovery edges never reach field input. Batches
-- without a live screen are dropped: focus loss and teardown neither
-- answer nor cancel a battle request.
---@param events table<integer, table<string, unknown>> semantic input batch
function FieldBattlePresentation:input(events)
  local descriptor = self._descriptor
  local host = descriptor ~= nil and descriptor.host or nil
  if host ~= nil and type(host.recoveryInput) == "function" then
    local okStatus, status = pcall(function()
      return host.status()
    end)
    if okStatus and type(status) == "table" and status.phase == "recovering" then
      self:_inputRecovery(host, events)
      return
    end
    self._recoveryPointerId = nil
  end
  local screen = self:liveScreen()
  if screen == nil then
    return
  end
  screen:input(events)
end

-- Answers the waiting defeat message with one genuine edge per press:
-- confirm acts, cancel cancels, and a pointer release taps only its own
-- matching press. Orphan releases, moves, and anything else stay silent,
-- and every release forgets its press whether it matched or not.
---@param host table<string, unknown> owning launch host behind the recovery callback
---@param events table<integer, table<string, unknown>> semantic input batch
function FieldBattlePresentation:_inputRecovery(host, events)
  assert(type(events) == "table", "recovery input arrives as an event list")
  for _, event in ipairs(events) do
    if type(event) == "table" then
      if event.type == "confirm" then
        host.recoveryInput({ pressedAction = true })
      elseif event.type == "cancel" then
        host.recoveryInput({ pressedCancel = true })
      elseif event.type == "pointer_down" then
        local pointerId = event.pointerId
        if type(pointerId) == "string" or type(pointerId) == "number" then
          self._recoveryPointerId = pointerId
        end
      elseif event.type == "pointer_up" then
        local pressed = self._recoveryPointerId
        self._recoveryPointerId = nil
        if pressed ~= nil and event.pointerId == pressed then
          host.recoveryInput({ touchPressed = true })
        end
      end
    end
  end
end

-- Cancels a held press through both owners so a stale release never
-- activates after remeasure, submission, focus loss, or disposal.
function FieldBattlePresentation:cancelPointerCapture()
  self._recoveryPointerId = nil
  local screen = self._screen
  if screen ~= nil then
    screen:cancelPointerCapture()
  end
end

-- Draws the live battle through its screen owner with outer draw
-- resources. Never draws after the port disposes; the caller owns cover
-- and field composition around it.
---@param resources table<string, unknown>? outer draw resources carrying host graphics
---@return boolean drawn true while a live screen drew
function FieldBattlePresentation:drawBattle(resources)
  local screen = self:liveScreen()
  if screen == nil then
    return false
  end
  self._drewExternally = true
  screen:draw(resources or { graphics = self._recording, text = self._text, windows = self._windows })
  return true
end

---@return string? battle-music start outcome for launch diagnostics
function FieldBattlePresentation:musicNote()
  return self._musicNote
end

-- Advances the envelope one accepted fixed quantum: the cover machine
-- follows the observed launch phase while the live screen and its cue
-- accumulator advance on the accepted time only. Draw, resize, and status
-- polling never advance these clocks.
---@param dt number accepted presentation seconds
function FieldBattlePresentation:updateFixed(dt)
  assert(type(dt) == "number" and dt == dt and dt >= 0, "presentation updates take accepted seconds")
  assert(not self._disposed, "the presented battle envelope is disposed")
  self._accumulator = self._accumulator + dt
  local steps = 0
  while
    self._accumulator + FieldBattlePresentation.SOURCE_EPSILON >= FieldBattlePresentation.SOURCE_FRAME
    and steps < FieldBattlePresentation.MAX_CATCH_UP
  do
    self._accumulator = self._accumulator - FieldBattlePresentation.SOURCE_FRAME
    steps = steps + 1
    self:_stepCover()
  end
  if self._accumulator + FieldBattlePresentation.SOURCE_EPSILON >= FieldBattlePresentation.SOURCE_FRAME then
    local discarded =
      math.floor((self._accumulator + FieldBattlePresentation.SOURCE_EPSILON) / FieldBattlePresentation.SOURCE_FRAME)
    self._accumulator = self._accumulator - discarded * FieldBattlePresentation.SOURCE_FRAME
  end
  -- The presented launch advances only here: the runtime phase machine
  -- and the owned battle clock run once per envelope tick, never through
  -- the host-update pump as well.
  local descriptor = self._descriptor
  local host = descriptor ~= nil and descriptor.host or nil
  if self._launchId ~= nil and host ~= nil then
    host.advance()
  end
  local screen = self._screen
  if screen ~= nil then
    screen:updateFixed(steps * FieldBattlePresentation.SOURCE_FRAME)
    self:_observeScreenFailure()
  end
  self:_refreshRecording()
end

-- One source-clock cover step behind the observed launch phase. Cover
-- completion, terminal cover, and reveal each notify the runtime exactly
-- once at their threshold; stale notifications are ignored there.
function FieldBattlePresentation:_stepCover()
  local launchId = self._launchId
  if launchId == nil then
    if self._cover > 0 then
      self._cover = math.max(0, self._cover - FieldBattlePresentation.COVER_STEP)
    end
    return
  end
  local descriptor = self._descriptor
  local host = descriptor ~= nil and descriptor.host or nil
  if host == nil then
    self:_dropLaunch()
    return
  end
  local okStatus, status = pcall(function()
    return host.status()
  end)
  if not okStatus or status == nil then
    self:_dropLaunch()
    return
  end
  self._lastStatus = status
  local phase = status.phase
  if phase == nil or phase == "failed" or phase == "complete" then
    self:_dropLaunch()
    return
  end
  if phase == "covering" then
    self:_stepCoverUp()
    if self._cover >= FieldBattlePresentation.COVER_MAX then
      host.notify("cover-complete")
      -- Battle music starts once under full cover: the role was selected
      -- from staged source data at admission.
      self:_startBattleMusic()
    end
    return
  end
  if phase == "terminal" then
    self:_stepCoverUp()
    if self._cover >= FieldBattlePresentation.COVER_MAX then
      host.notify("battle-covered")
    end
    self._revealingBattle = false
    return
  end
  if phase == "revealing" then
    self:_stepCoverDown()
    if self._cover <= 0 then
      host.notify("revealed")
    end
    return
  end
  if phase == "recovering" or phase == "transfer" then
    -- The recovery UI owns input under its own cover once its message
    -- presents: the retained battle cover transfers instead of layering
    -- over the message. Until then full cover is retained.
    local blackoutPhase = status.blackoutPhase
    if blackoutPhase == "message_in" or blackoutPhase == "message_wait" or blackoutPhase == "message_out" then
      self:_stepCoverDown()
    end
    return
  end
  if phase == "restoring" then
    self:_stepCoverUp()
    return
  end
  -- Leaving and active hold full cover until the constructed battle
  -- proves exact-asset readiness; the reveal then runs beside the intro.
  if self._revealingBattle then
    self:_stepCoverDown()
    return
  end
  if self._cover >= FieldBattlePresentation.COVER_MAX and self:_portEnterReady() then
    self._revealingBattle = true
    self:_stepCoverDown()
  end
end

function FieldBattlePresentation:_stepCoverUp()
  if self._cover < FieldBattlePresentation.COVER_MAX then
    self._cover = math.min(FieldBattlePresentation.COVER_MAX, self._cover + FieldBattlePresentation.COVER_STEP)
  end
end

function FieldBattlePresentation:_stepCoverDown()
  if self._cover > 0 then
    self._cover = math.max(0, self._cover - FieldBattlePresentation.COVER_STEP)
  end
end

-- Polls exact-asset readiness through the port's idempotent entry: true
-- once the constructed opening model resolves its scene demand. Repeated
-- polls never restart entry.
---@return boolean ready
function FieldBattlePresentation:_portEnterReady()
  local port = self._port
  local descriptor = self._descriptor
  if port == nil or descriptor == nil then
    return false
  end
  local ok, ready = pcall(port.enter, { launchId = descriptor.launchId, kind = descriptor.kind })
  return ok and ready == true
end

-- Starts the source-defined battle music role once under full cover. The
-- start is attempted exactly once per launch; an unstaged bank records
-- its outcome and the launch continues, since the acceptance closure
-- stages no audio sequences while production playback resolves through
-- the normalized catalog.
function FieldBattlePresentation:_startBattleMusic()
  if self._musicStarted then
    return
  end
  self._musicStarted = true
  local descriptor = self._descriptor
  local role = descriptor ~= nil and descriptor.musicRole or nil
  local audio = descriptor ~= nil and descriptor.audio or nil
  if type(role) ~= "string" or role == "" then
    self._musicNote = "skipped-no-role"
    return
  end
  if audio == nil or type(audio.playMusic) ~= "function" then
    self._musicNote = "skipped-no-audio"
    return
  end
  local ok, err = pcall(function()
    return audio:playMusic(role)
  end)
  if ok then
    self._musicNote = "started:" .. role
  else
    self._musicNote = "unstaged:" .. role .. ":" .. tostring(err)
  end
end

-- Observes a failed screen and fails the launch loudly through the
-- runtime instead of polling a dead presentation: before commitment no
-- result is published, and after commitment mechanics are never rerun.
function FieldBattlePresentation:_observeScreenFailure()
  local screen = self._screen
  local descriptor = self._descriptor
  if screen == nil or descriptor == nil then
    return
  end
  local host = descriptor.host
  if host == nil then
    return
  end
  local ok, status = pcall(function()
    return screen:status()
  end)
  if ok and type(status) == "table" and status.mode == "failed" then
    host.notify("screen-failed")
    local _, _ = pcall(function()
      return screen:dispose()
    end)
    self:_dropLaunch()
  end
end

-- Refreshes the presented battle through the recording boundary: window
-- frames, text content, cue-adjacent graphics draws, and staged asset
-- identities log without ever reaching host graphics. Read-only and
-- clock-free; an externally drawn frame skips the refresh so production
-- pays no double render.
function FieldBattlePresentation:_refreshRecording()
  if self._drewExternally then
    self._drewExternally = false
    return
  end
  local screen = self._screen
  if screen == nil then
    return
  end
  local ok, status = pcall(function()
    return screen:status()
  end)
  if not ok or type(status) ~= "table" or status.mode == "failed" or status.mode == "disposed" then
    return
  end
  local _, _ = pcall(function()
    return screen:draw({ graphics = self._recording, text = self._text, windows = self._windows })
  end)
end

-- Forgets a cleared launch: the runtime disposed the battle port (and its
-- screen) before clearing, so only envelope bookkeeping remains.
function FieldBattlePresentation:_dropLaunch()
  self._launchId = nil
  self._descriptor = nil
  self._recoveryPointerId = nil
  self._screen = nil
  self._port = nil
  self._lastStatus = nil
  self._revealingBattle = false
  self._musicStarted = false
  self._musicNote = nil
end

-- Idempotent release of the envelope lifetime: the live screen releases
-- exactly once while borrowed field font, window, and audio services stay
-- usable for their owner. The factory binding belongs to the field
-- lifetime and is removed there, never here.
function FieldBattlePresentation:dispose()
  if self._disposed then
    return
  end
  self._disposed = true
  self:cancelPointerCapture()
  local screen = self._screen
  if screen ~= nil then
    local _, _ = pcall(function()
      return screen:dispose()
    end)
  end
  for key, _ in pairs(self._images) do
    self._images[key] = nil
  end
  self:_dropLaunch()
  self._cover = 0
  self._accumulator = 0
end

return FieldBattlePresentation
