-- Production battle cue audio and borrowed catalogs through the real field
-- composition: a FieldState-owned envelope adapts the method-based audio
-- controller behind a one-argument cue sink, the live screen drains its
-- ordered send-out and selection cues through that sink exactly once, and
-- a stocked battle bag opens against the borrowed item and mon catalogs.
-- A faulty controller fails the presented launch with context instead of
-- escaping as a host error. Synthetic fixtures only: a staged presentation
-- cache, fixture catalogs, and a method-faithful audio controller stand in
-- for the derived dump and the host sound backend. No ROM required.

local Assert = require("tests.support.Assert")
local BattlePresentationCache = require("libs.assets.src.battle.BattlePresentationCache")
local BattleRuntime = require("game.hgss.src.battle.BattleRuntime")
local CacheFs = require("libs.storage.src.CacheFs")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local FakeGraphics = require("tests.support.FakeGraphics")
local FieldBattlePresentation = require("game.hgss.src.field.FieldBattlePresentation")
local FieldRuntime = require("game.hgss.src.field.FieldRuntime")
local FieldState = require("game.hgss.src.field.FieldState")
local FieldStatePresentationFixture = require("tests.support.FieldStatePresentationFixture")
local FieldTerrainEffectController = require("libs.hgss.src.world.FieldTerrainEffectController")
local FieldUiFixture = require("tests.support.FieldUiFixture")
local HgssBagService = require("libs.hgss.src.items.HgssBagService")
local InactivePokemonNaming = require("tests.support.InactivePokemonNaming")
local ItemFixture = require("libs.items.tests.item_fixture")
local MonCache = require("libs.assets.src.MonCache")
local PngWriter = require("libs.assets.src.PngWriter")
local ScreenTopology = require("libs.ui.src.ScreenTopology")

local T = {}

local TICK = 1 / 60
local SCENE_KEY = "general/grass/day"
local MENU_IMAGE = "assets/generated/battle/menu-command-1.png"
local SELECT_SYMBOL = "SEQ_SE_DP_SELECT"
local LEAD_SPECIES = "EEVEE"
local FOE_SPECIES = "CHIKORITA"

---@return table caller-owned dual-surface display facts
local function dualMeasurement()
  return {
    width = 256,
    height = 384,
    topology = ScreenTopology.dualDisplay(
      { id = "main", rect = { x = 0, y = 0, width = 256, height = 192 }, touch = false, role = "world" },
      { id = "lower", rect = { x = 0, y = 192, width = 256, height = 192 }, touch = true, role = "auxiliary" },
      "battle-production-audio:dual"
    ),
    pixelRatio = 1,
    signature = "battle-production-audio:dual",
  }
end

---@return table recording text boundary keeping every drawn string
local function recordingText()
  local text = { draws = {} }
  function text.measure(content)
    return { width = 8 * #tostring(content), height = 16 }
  end
  function text.drawText(content, x, y)
    text.draws[#text.draws + 1] = { content = tostring(content), x = x, y = y }
  end
  return text
end

---@return table recording window-frame boundary
local function recordingWindows()
  local windows = { calls = {} }
  function windows.drawWindow(box, frameKey, background)
    windows.calls[#windows.calls + 1] = { box = box, frame = frameKey, background = background }
  end
  function windows.drawApplicationFrame(box, frameKey)
    windows.calls[#windows.calls + 1] = { box = box, frame = frameKey }
  end
  return windows
end

-- A method-faithful stand-in for the production audio controller: every
-- call records its receiver so the tests can tell a correctly bound
-- method call from a free-function call carrying the role as its self.
---@return table controller double with colon-semantics play and playCry
local function methodAudio()
  local controller = { calls = {} }
  function controller:play(symbol)
    controller.calls[#controller.calls + 1] = { method = "play", receiver = self, symbol = symbol }
  end
  function controller:playCry(species, pattern)
    controller.calls[#controller.calls + 1] = { method = "playCry", receiver = self, species = species, pattern = pattern }
  end
  function controller:rejects()
    return false
  end
  return controller
end

-- A method-based controller that records its receiver and then rejects a
-- valid role, so cue dispatch must attribute the failure instead of
-- escaping as a host error.
---@return table faulty controller double
local function faultyAudio()
  local controller = { calls = {} }
  local function checkReceiver(self)
    controller.calls[#controller.calls + 1] = { receiver = self }
    if self ~= controller then
      error("cue audio reached the controller without its receiver", 0)
    end
    error("injected cue fault", 0)
  end
  function controller:play(_)
    checkReceiver(self)
  end
  function controller:playCry(_, _)
    checkReceiver(self)
  end
  return controller
end

---@param width integer
---@param height integer
---@return string real decodable pixels the host image loader accepts
local function solidPng(width, height)
  local pixels = {}
  for _ = 1, width * height do
    pixels[#pixels + 1] = string.char(255, 255, 255, 255)
  end
  return PngWriter.encode(width, height, table.concat(pixels))
end

-- The staged battle manifest the envelope loads: one scene, the shared
-- menu artwork, and the published wild/trainer/rival/select audio roles.
---@param sceneImage string cache-relative staged scene image path
---@return table schema-valid staged battle manifest
local function stagedManifest(sceneImage)
  local images = {
    [MENU_IMAGE] = { width = 8, height = 8 },
    [sceneImage] = { width = 64, height = 64 },
  }
  local function sprite(image)
    return {
      image = image,
      cells = {
        {
          objs = {
            {
              x = 0,
              y = 0,
              tile = 0,
              flipH = false,
              flipV = false,
              palette = 0,
              shape = 0,
              size = 0,
              width = 8,
              height = 8,
              affine = false,
              disabled = false,
              objMode = "normal",
              mosaic = false,
              colorMode = "16-color",
              priority = 0,
            },
          },
        },
      },
      animation = { playMode = "forward", loopStartFrameIdx = 0, frames = { { cell = 0, duration = 4 } } },
      palette = { colors = { { r = 1, g = 2, b = 3 } } },
    }
  end
  local function menu(image)
    return {
      image = image,
      screens = { { image = image, width = 8, height = 8 } },
    }
  end
  local command = menu(MENU_IMAGE)
  return {
    schema = "g4-battle-presentation-v1",
    version = { id = "heartgold", language = "en" },
    verified = true,
    scenes = { { key = SCENE_KEY, background = "general", terrain = "grass", time = "day" } },
    images = images,
    command = command,
    moves = command,
    target = command,
    twoOption = command,
    lower = {
      image = MENU_IMAGE,
      palette = { colors = { { r = 1, g = 2, b = 3 } } },
      variants = {
        general = {
          base = { colors = { { r = 1, g = 2, b = 3 } } },
          touch = { colors = { { r = 1, g = 2, b = 3 } } },
        },
      },
    },
    playerHud = sprite(MENU_IMAGE),
    enemyHud = sprite(MENU_IMAGE),
    arrow = sprite(MENU_IMAGE),
    partyGauges = {
      sprite(MENU_IMAGE),
      sprite(MENU_IMAGE),
    },
    terrain = {
      type0 = { cells = sprite(MENU_IMAGE).cells, animation = sprite(MENU_IMAGE).animation },
      type1 = { cells = sprite(MENU_IMAGE).cells, animation = sprite(MENU_IMAGE).animation },
    },
    textRoles = {
      narration = { font = "font-0", sourceFontId = 1 },
      menu = { font = "font-0" },
      hud = { font = "font-0" },
    },
    audioRoles = {
      wild = "SEQ_GS_VS_NORAPOKE",
      trainer = "SEQ_GS_VS_TRAINER",
      rival = "SEQ_GS_VS_RIVAL",
      select = SELECT_SYMBOL,
      narrationBank = 197,
      cries = "species",
    },
  }
end

-- Stages the battle manifest, one scene record with exactly-sized pixels,
-- and the lead/foe portrait pages over the presentation fixture cache.
---@param cache table versioned derived cache under staging
local function stageBattlePresentation(cache)
  cache:writeLua(BattlePresentationCache.manifestPath(), stagedManifest(BattlePresentationCache.sceneImagePath(SCENE_KEY)))
  cache:write(MENU_IMAGE, solidPng(8, 8))
  for _, font in ipairs({ "font-0" }) do
    cache:write(font, "staged-font")
  end
  cache:writeLua(BattlePresentationCache.scenePath(SCENE_KEY), {
    schema = "g4-battle-scene-v1",
    key = SCENE_KEY,
    background = "general",
    terrain = "grass",
    time = "day",
    canvasWidth = 64,
    canvasHeight = 64,
    viewport = { x = 0, y = 0, width = 64, height = 64 },
    imagePath = BattlePresentationCache.sceneImagePath(SCENE_KEY),
  })
  cache:write(BattlePresentationCache.sceneImagePath(SCENE_KEY), solidPng(64, 64))
  local entries = {}
  for _, selector in ipairs({
    LEAD_SPECIES .. "/f0/male/plain/back",
    LEAD_SPECIES .. "/f0/male/shiny/back",
    LEAD_SPECIES .. "/f0/female/plain/back",
    LEAD_SPECIES .. "/f0/female/shiny/back",
    FOE_SPECIES .. "/f0/male/plain",
    FOE_SPECIES .. "/f0/male/shiny",
    FOE_SPECIES .. "/f0/female/plain",
    FOE_SPECIES .. "/f0/female/shiny",
  }) do
    entries[selector] = { x = 0, y = 0, width = 8, height = 8, pageId = 0 }
  end
  cache:writeLua(MonCache.portraitManifestPath(), { entries = entries })
  cache:writeLua(MonCache.indexPath(), { portraitPages = { "portrait-marker-0" } })
  cache:write(MonCache.pageMarkerPath("portraits", 0), "portrait-marker-0")
  cache:write(MonCache.pageImagePath("portraits", 0), solidPng(64, 64))
end

-- The stubbed presentation runtime a real FieldState boot reads, carrying
-- the method-based audio controller and the borrowed catalogs exactly
-- where the production runtime composes them.
---@param cache table staged presentation cache under serving
---@param audio table method-based audio controller under borrowing
---@param itemCatalog table borrowed immutable item catalog
---@param monCatalog table borrowed immutable mon catalog
---@return table presentation runtime stub
local function stubPresentationRuntime(cache, audio, itemCatalog, monCatalog)
  local effects = FieldStatePresentationFixture.terrainEffects(cache)
  local measurement = dualMeasurement()
  return setmetatable({
    pokemonNaming = InactivePokemonNaming.new(),
    cacheFs = cache,
    derivedAssets = FieldStatePresentationFixture.iconHost().derivedAssets,
    uiManifest = FieldUiFixture.fieldStateManifest(),
    audio = audio,
    itemCatalog = itemCatalog,
    monCatalog = monCatalog,
    presentationDisplay = measurement,
    bindPartyIconPreparation = function(_, _, _)
      return 1
    end,
    unbindPartyIconPreparation = function(_, _) end,
    bindBattlePresentation = function(self, factory)
      assert(type(factory) == "function", "battle presentation binding requires its factory function")
      assert(self.battlePresentation == nil, "one battle presentation binding owns the presented lifetime")
      self.battlePresentation = { id = 1, make = factory }
      return self.battlePresentation.id
    end,
    unbindBattlePresentation = function(self, binding)
      local current = self.battlePresentation
      if current ~= nil and current.id == binding then
        self.battlePresentation = nil
      end
    end,
    bindSummaryPreparation = function(self, acquire)
      assert(type(acquire) == "function", "summary preparation binding requires its acquire function")
      assert(self.summaryPreparation == nil, "one summary preparation binding owns the presented lifetime")
      self.summaryPreparation = { id = 1, acquire = acquire }
      return self.summaryPreparation.id
    end,
    unbindSummaryPreparation = function(self, binding)
      local current = self.summaryPreparation
      if current ~= nil and current.id == binding then
        self.summaryPreparation = nil
      end
    end,
    fieldEntranceIndicatorAsset = {
      model = { batches = {}, materials = {} },
      effects = {
        surf_attachment = {
          model = { batches = {}, materials = {} },
          presentation = { yawDegrees = { north = 180, south = 0, west = 270, east = 90 } },
        },
      },
    },
    fieldEmoteModels = {
      exclamation = { kind = "static", batches = {}, materials = {} },
    },
    fieldEffectAssets = { effects = effects },
    fieldTerrainEffectController = FieldTerrainEffectController.new({
      effects = effects,
      modelFactory = function()
        error("the terrain model factory is installed by presentation resources", 0)
      end,
    }),
    windowStyles = {
      resolve = function() end,
    },
    playerData = { options = { textFrame = 0 } },
    menuHost = {
      setScreenTopology = function() end,
      setPresentationMetrics = function() end,
    },
    actors = {
      visualRevision = function()
        return 0
      end,
      collectSpriteIds = function() end,
    },
    playerVisual = { spriteId = 0 },
    resizePresentation = function() end,
    dispose = function() end,
  }, FieldRuntime)
end

---@param cache table staged presentation cache under serving
---@param audio table method-based audio controller under borrowing
---@param itemCatalog table borrowed immutable item catalog
---@param monCatalog table borrowed immutable mon catalog
---@return FieldState state live production field state owning its envelope
local function bootFieldState(cache, audio, itemCatalog, monCatalog)
  local originalNew = FieldRuntime.new
  FieldRuntime.new = function(_, _)
    return stubPresentationRuntime(cache, audio, itemCatalog, monCatalog)
  end
  local game = { saveId = "save-00000001", versionId = "heartgold" }
  local ok, state = pcall(FieldState.new, game, {
    topologyProvider = function()
      return ScreenTopology.oneDisplay({
        id = "main",
        rect = { x = 0, y = 0, width = 640, height = 480 },
        touch = false,
        role = "world",
      })
    end,
  })
  FieldRuntime.new = originalNew
  if not ok then
    error(state, 0)
  end
  return state
end

---@param species string
---@param level integer
---@param seed integer
---@return table full mon-domain record with a single known move
local function foeRecord(species, level, seed)
  local catalog = CatalogFixture.makeCatalog()
  local factory = CatalogFixture.makeFactory(seed, catalog)
  local record = factory:createNormal(CatalogFixture.normalRequest({ species = species, level = level }))
  record.moves = { { move = "TACKLE", pp = 35, ppUps = 0 } }
  return record
end

---@return table live party owner holding a single lead
-- A single combatant with an empty bag keeps the kernel decision prober on
-- attack choices only: reserve and stocked-item probes need staged
-- reservations the prober does not supply, which is outside this
-- composition's ownership, so the cue-audio scenarios isolate dispatch
-- from that unrelated path.
local function makeParty()
  local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
  local Lcrng = require("libs.mons.src.gen4.Lcrng")
  local MonsSave = require("libs.mons.src.MonsSave")
  local Party = require("libs.mons.src.Party")
  local catalog = CatalogFixture.makeCatalog()
  local owner = HgssMonService.new({
    catalog = catalog,
    bucket = MonsSave.capture(Party.new():capture(), Lcrng.new(0x22222222):capture()),
    profile = CatalogFixture.profile(),
    game = "heartgold",
    language = "english",
    charmap = CatalogFixture.CHARMAP,
    games = CatalogFixture.GAMES,
    languages = CatalogFixture.LANGUAGES,
    items = CatalogFixture.ITEMS,
    balls = CatalogFixture.BALLS,
    mapSection = 7,
    date = CatalogFixture.metDate(),
  })
  local factory = CatalogFixture.makeFactory(0x33333333, catalog)
  local record =
    factory:createNormal(CatalogFixture.normalRequest({ species = LEAD_SPECIES, level = 20 }))
  record.moves = { { move = "TACKLE", pp = 35, ppUps = 0 } }
  Assert.isTrue(owner:addMon(record), "the production path needs its live party lead")
  return owner
end

---@return table stub launch host holding its phase with recorded notifications
local function stubHost(holder)
  local host = { notifies = {} }
  function host.status()
    return { phase = "leaving" }
  end
  function host.advance() end
  function host.submit(reply)
    return holder.battle:submit(reply)
  end
  function host.notify(event)
    host.notifies[#host.notifies + 1] = event
  end
  return host
end

---@param state FieldState live production field state under test driving
---@param stock table<string, integer>? battle stock under test driving
---@return table rig live envelope, screen, battle, and host under test driving
local function openBattle(state, stock)
  local holder = {}
  local host = stubHost(holder)
  local launchId = "launch-production-audio"
  local port = state.battleEnvelope:factory()({
    launchId = launchId,
    environment = { sceneKey = SCENE_KEY },
    host = host,
  })
  local screen = assert(state.battleEnvelope:liveScreen(), "the envelope owns its live screen")
  local party = makeParty()
  local bag = HgssBagService.new({ catalog = ItemFixture.makeCatalog() })
  for key, quantity in pairs(stock or {}) do
    Assert.isTrue(bag:add(key, quantity), "the production path stocks " .. tostring(key))
  end
  local launch = {
    id = launchId,
    kind = "wild",
    payload = { attemptId = launchId .. "-attempt", species = FOE_SPECIES, form = 0, level = 3, personality = 1 },
  }
  local ScenarioFactory = require("libs.hgss.src.battle.HgssBattleScenarioFactory")
  local scenario = ScenarioFactory.fromEncounter(
    { attemptId = launchId .. "-attempt", mon = foeRecord(FOE_SPECIES, 3, 0x5EED0002) },
    { party = party, bag = bag, player = { trainerId = 99, trainerName = "MINT", language = "french" } }
  )
  holder.battle = BattleRuntime.new({
    request = launch,
    scenario = scenario,
    party = party,
    bag = bag,
    presentation = port,
    seed = 0x12345678,
  })
  return { state = state, screen = screen, port = port, battle = holder.battle, host = host, party = party, bag = bag }
end

---@param rig table live rig under test driving
local function pump(rig)
  rig.battle:update()
  rig.state.battleEnvelope:updateFixed(TICK)
end

-- Drives the live battle until the screen exposes its command decision,
-- failing loudly with the screen context when presentation fails first.
---@param rig table live rig under test driving
local function driveToCommand(rig)
  for _ = 1, 900 do
    pump(rig)
    local status = rig.screen:status()
    if status.mode == "failed" then
      error("the production battle failed before its command: " .. tostring(status.error), 0)
    end
    if status.mode == "command" then
      return
    end
  end
  error("the production battle never reached its command", 0)
end

---@param calls table recorded controller calls under inspection
---@param method string controller method under counting
---@return integer matching calls
local function countCalls(calls, method)
  local total = 0
  for _, call in ipairs(calls) do
    if call.method == method then
      total = total + 1
    end
  end
  return total
end

-- The played battle reaches the bound controller with real method
-- signatures: one numeric send-out cry for the active lead and one
-- selection sound for the accepted Fight choice, each dispatched exactly
-- once with the controller as its receiver and no pseudo-sequence.
function T.selection_and_cry_reach_the_bound_controller_once()
  local cache = FieldStatePresentationFixture.cache()
  stageBattlePresentation(cache)
  local audio = methodAudio()
  local itemCatalog = ItemFixture.makeCatalog()
  local monCatalog = CatalogFixture.makeCatalog()
  local state = bootFieldState(cache, audio, itemCatalog, monCatalog)
  local rig = openBattle(state, {})
  driveToCommand(rig)
  local leadNativeId = monCatalog:species(LEAD_SPECIES).nativeId
  local cries, plays = {}, {}
  for _, call in ipairs(audio.calls) do
    Assert.isTrue(call.receiver == audio, "every cue reaches the controller with its receiver")
    Assert.isTrue(call.symbol == nil or tostring(call.symbol):sub(1, 4) ~= "cry:", "no cue dispatches a pseudo-sequence")
    if call.method == "playCry" then
      cries[#cries + 1] = call
    elseif call.method == "play" then
      plays[#plays + 1] = call
    end
  end
  Assert.equal(#cries, 1, "the send-out cries exactly once")
  Assert.equal(cries[1].species, leadNativeId, "the cry names the numeric lead identity")
  Assert.equal(cries[1].pattern, 0, "the cry uses the plain pattern")
  Assert.equal(#plays, 0, "no selection plays before an accepted reply")
  rig.screen:input({ { type = "confirm" } })
  pump(rig)
  Assert.equal(rig.screen:status().mode, "moves", "confirming Fight opens move selection")
  rig.screen:input({ { type = "confirm" } })
  pump(rig)
  Assert.equal(rig.screen:status().mode, "awaiting_resolution", "confirming the known slot submits")
  Assert.equal(countCalls(audio.calls, "play"), 1, "the accepted reply plays its selection exactly once")
  local select
  for _, call in ipairs(audio.calls) do
    if call.method == "play" then
      select = call
    end
  end
  Assert.notNil(select, "the selection dispatch is recorded")
  Assert.isTrue(select.receiver == audio, "the selection reaches the controller with its receiver")
  Assert.equal(select.symbol, SELECT_SYMBOL, "the selection plays the staged interface role")
  pump(rig)
  pump(rig)
  Assert.equal(countCalls(audio.calls, "playCry"), 1, "settling replays no cry")
  Assert.equal(countCalls(audio.calls, "play"), 1, "settling replays no selection")
  rig.battle:dispose()
  state:dispose()
end

-- A stocked production bag opens against the borrowed catalogs: potions,
-- balls, and a machine resolve without a missing-catalog refusal, and
-- the machine display can resolve its mon move through the catalog.
-- The stocked inventory exercises the kernel item prober, which needs
-- staged reservations from outside this composition.
function T.stocked_production_bag_opens_with_borrowed_catalogs()
  local cache = FieldStatePresentationFixture.cache()
  stageBattlePresentation(cache)
  local audio = methodAudio()
  local itemCatalog = ItemFixture.makeCatalog()
  local monCatalog = CatalogFixture.makeCatalog()
  Assert.notNil(itemCatalog:item("HM01"), "the stocked machine resolves through the item catalog")
  Assert.notNil(monCatalog:moveByNativeId(15), "the machine move resolves through the mon catalog")
  local state = bootFieldState(cache, audio, itemCatalog, monCatalog)
  local rig = openBattle(state, { POTION = 3, POKE_BALL = 2, HM01 = 1 })
  driveToCommand(rig)
  rig.screen:input({ { type = "navigate", direction = "down" } })
  pump(rig)
  rig.screen:input({ { type = "navigate", direction = "left" } })
  pump(rig)
  rig.screen:input({ { type = "confirm" } })
  pump(rig)
  Assert.equal(rig.screen:status().mode, "child", "the stocked bag opens its child selection")
  local message = rig.screen:view().message
  Assert.isTrue(tostring(message):find("catalog", 1, true) == nil, "opening names no missing catalog")
  rig.battle:dispose()
  state:dispose()
end

-- A rejecting controller fails the presented launch with context: the
-- dispatch never escapes as a host error, the failure names the launch
-- and role, nothing commits, and later ticks replay nothing.
function T.rejecting_cue_audio_fails_the_launch_with_context()
  local cache = FieldStatePresentationFixture.cache()
  stageBattlePresentation(cache)
  local audio = faultyAudio()
  local itemCatalog = ItemFixture.makeCatalog()
  local monCatalog = CatalogFixture.makeCatalog()
  local state = bootFieldState(cache, audio, itemCatalog, monCatalog)
  local rig = openBattle(state, {})
  local driven, driveErr = pcall(function()
    for _ = 1, 900 do
      pump(rig)
      local mode = rig.screen:status().mode
      if mode == "failed" or mode == "disposed" or mode == "command" then
        return
      end
    end
    error("the production battle never settled its cues", 0)
  end)
  Assert.isTrue(driven, "cue audio never escapes as a host error: " .. tostring(driveErr))
  local status = rig.screen:status()
  Assert.isTrue(status.mode ~= "command", "the faulty cue never reaches an interactive decision")
  local context = tostring(status.error)
  Assert.isTrue(context:find("launch-production-audio", 1, true) ~= nil, "the failure names its launch: " .. context)
  Assert.isTrue(
    context:find("cry:" .. LEAD_SPECIES, 1, true) ~= nil or context:find("SEQ_", 1, true) ~= nil,
    "the failure names its cue role: " .. context
  )
  local callsAtFailure = #audio.calls
  Assert.isTrue(callsAtFailure >= 1, "the faulty cue was dispatched before failing")
  for _ = 1, 30 do
    local settled, settleErr = pcall(pump, rig)
    Assert.isTrue(settled, "later ticks stay controlled: " .. tostring(settleErr))
  end
  Assert.equal(#audio.calls, callsAtFailure, "a failed launch replays no cue")
  Assert.isNil(state.battleEnvelope:liveScreen(), "the failed launch releases its screen")
  local failed = 0
  for _, event in ipairs(rig.host.notifies) do
    if event == "screen-failed" then
      failed = failed + 1
    end
  end
  Assert.equal(failed, 1, "the envelope reports its deterministic failure exactly once")
  rig.battle:dispose()
  state:dispose()
end

return { tests = T }
