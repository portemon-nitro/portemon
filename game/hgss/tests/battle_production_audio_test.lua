-- Production battle cue audio and borrowed catalogs through the real field
-- composition: a FieldState-owned envelope adapts the method-based audio
-- controller behind a one-argument cue sink, the live screen drains its
-- ordered send-out and selection cues through that sink exactly once, and
-- a stocked battle bag opens against the borrowed item and mon catalogs.
-- A faulty controller fails the presented launch with context instead of
-- escaping as a host error. Synthetic fixtures only: a staged presentation
-- cache, fixture catalogs, and a method-faithful audio controller stand in
-- for the derived dump and the host sound backend. No ROM required.

local AssetNeedsRegistry = require("libs.hgss.src.field.AssetNeedsRegistry")
local Assert = require("tests.support.Assert")
local BattlePresentationCache = require("libs.assets.src.battle.BattlePresentationCache")
local BattlePresentationManifestFixture = require("tests.support.BattlePresentationManifestFixture")
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
local InactiveMonNaming = require("tests.support.InactiveMonNaming")
local ItemFixture = require("libs.items.tests.item_fixture")
local MonCache = require("libs.assets.src.MonCache")
local PngWriter = require("libs.assets.src.PngWriter")
local PokedexDexFixture = require("libs.hgss.tests.mons.pokedex_dex_fixture")
local ScreenTopology = require("libs.ui.src.ScreenTopology")
local SummaryAcceptanceFixture = require("tests.support.SummaryAcceptanceFixture")

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
    return true
  end
  function controller:playCry(species, pattern, form, mode, pan, volume, pitch)
    controller.calls[#controller.calls + 1] = {
      method = "playCry",
      receiver = self,
      species = species,
      pattern = pattern,
      form = form,
      mode = mode,
      pan = pan,
      volume = volume,
      pitch = pitch,
    }
    return true
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
  local manifest = BattlePresentationManifestFixture.manifest()
  manifest.menus.images[MENU_IMAGE] = { width = 8, height = 8 }
  manifest.menus.images[sceneImage] = { width = 512, height = 256 }
  manifest.audioRoles.select = SELECT_SYMBOL
  return manifest
end

-- Stages the battle manifest, one scene record with exactly-sized pixels,
-- and the lead/foe portrait pages over the presentation fixture cache.
---@param cache table versioned derived cache under staging
local function stageBattlePresentation(cache)
  local staged = stagedManifest(BattlePresentationCache.sceneImagePath(SCENE_KEY))
  cache:writeLua(BattlePresentationCache.manifestPath(), staged)
  cache:write(MENU_IMAGE, solidPng(8, 8))
  -- The field narration renderer behind battle text reads font 1:
  -- stage it beside the menu font the shared fixture already carries.
  FieldUiFixture.writeFont(cache, 1)
  -- The health-box strips the launch validator requires before a battle
  -- admits: every HUD section image needs staged bytes beside the menu art.
  local hud = staged.hud --[[@as table<string, unknown>]]
  local doubles = hud.doubles --[[@as table<string, unknown>]]
  local strips = { hud.enemy, hud.player }
  for _, slot in ipairs({ "playerLeft", "playerRight", "enemyLeft", "enemyRight" }) do
    strips[#strips + 1] = doubles[slot]
  end
  for _, section in ipairs(strips) do
    local image = (section --[[@as table<string, unknown>]]).image --[[@as string]]
    cache:write(image, solidPng(1648, 8))
  end
  -- The Pokepic shadow plate the asset holder requires beside the HUD.
  local pictures = staged.pictures --[[@as table<string, unknown>]]
  local shadow = pictures.shadow --[[@as table<string, unknown>]]
  cache:write(shadow.image --[[@as string]], solidPng(64, 64))
  for _, font in ipairs({ "font-0" }) do
    cache:write(font, "staged-font")
  end
  local charactersPath = BattlePresentationCache.sceneCharactersPath(SCENE_KEY)
  local mapPath = BattlePresentationCache.sceneMapPath(SCENE_KEY)
  local palettePath = BattlePresentationCache.scenePalettePath(SCENE_KEY)
  local mapEntries = {}
  for index = 1, 2048 do
    mapEntries[index] = { tile = 0, flipH = false, flipV = false, palette = 0 }
  end
  local paletteColors = {}
  for index = 1, 256 do
    paletteColors[index] = { r = 0, g = 0, b = 0 }
  end
  cache:writeLua(BattlePresentationCache.scenePath(SCENE_KEY), {
    schema = "g4-battle-scene-v2",
    key = SCENE_KEY,
    background = "general",
    terrain = "grass",
    time = "day",
    canvasWidth = 512,
    canvasHeight = 256,
    viewport = { x = 0, y = 0, width = 256, height = 192 },
    layers = {
      {
        key = "background",
        backing = { width = 512, height = 256, mapWidth = 64, mapHeight = 32 },
        viewport = { x = 0, y = 0, width = 256, height = 192 },
        scroll = { x = 0, y = 0 },
        characters = {
          key = "battle-scene/general-grass-day/background/characters",
          path = charactersPath,
          format = "indexed8",
        },
        map = {
          key = "battle-scene/general-grass-day/background/map",
          path = mapPath,
          format = "tilemap",
        },
        palette = {
          key = "battle-scene/general-grass-day/background/palette",
          path = palettePath,
          format = "rgb888",
        },
      },
    },
    imagePath = BattlePresentationCache.sceneImagePath(SCENE_KEY),
  })
  cache:write(BattlePresentationCache.sceneImagePath(SCENE_KEY), solidPng(512, 256))
  cache:write(charactersPath, string.rep("\0", 65536))
  cache:writeLua(mapPath, { width = 512, height = 256, entries = mapEntries })
  cache:writeLua(palettePath, { colors = paletteColors })
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
    entries[selector] = {
      x = 0,
      y = 0,
      width = 8,
      height = 8,
      pageId = 0,
      frames = {
        { x = 0, y = 0, width = 8, height = 8 },
        { x = 8, y = 0, width = 8, height = 8 },
      },
    }
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
    monNaming = InactiveMonNaming.new(),
    cacheFs = cache,
    assetNeeds = AssetNeedsRegistry.new(),
    derivedAssets = FieldStatePresentationFixture.iconHost().derivedAssets,
    -- The presented composition borrows its session image owner for the
    -- battle envelope and menu chrome: the sized pool keeps real
    -- consumers (font quads read dimensions off borrows) honest without
    -- a second worker beside the stub.
    imageAssets = SummaryAcceptanceFixture.sizedImagePool(),
    uiManifest = FieldUiFixture.fieldStateManifest(),
    audio = audio,
    itemCatalog = itemCatalog,
    monCatalog = monCatalog,
    -- The field battle envelope borrows the field-owned pokedex
    -- preparation leaf, so the stub carries the synthetic generated dex
    -- catalog exactly like production carries its derived one. The audio
    -- legs never prepare through it; construction alone keeps the
    -- composition honest without a ROM dump.
    pokedexCatalog = PokedexDexFixture.buildPokedexCatalog(),
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
    -- The currently bound world instance the actor presentation reconciles
    -- its visuals against.
    runtimeMap = {},
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
  local record = factory:createNormal(CatalogFixture.normalRequest({ species = LEAD_SPECIES, level = 20 }))
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

-- Waits for the source menu input gate to open before answering: the
-- production command menu drops input during its entry travel, so a
-- reply sent earlier would never reach the cue sink.
---@param rig table live rig under test driving
local function waitMenuInput(rig)
  for _ = 1, 300 do
    if rig.screen:view().menuInputEnabled then
      return
    end
    pump(rig)
  end
  error("the source menu input gate never opened", 0)
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
      waitMenuInput(rig)
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
-- signatures: one numeric send-out cry per battler for the wild foe
-- and the active lead, and one selection sound for the accepted Fight
-- choice, each dispatched exactly once with the controller as its
-- receiver and no pseudo-sequence.
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
  local foeNativeId = monCatalog:species(FOE_SPECIES).nativeId
  local cries, plays = {}, {}
  for _, call in ipairs(audio.calls) do
    Assert.isTrue(call.receiver == audio, "every cue reaches the controller with its receiver")
    Assert.isTrue(
      call.symbol == nil or tostring(call.symbol):sub(1, 4) ~= "cry:",
      "no cue dispatches a pseudo-sequence"
    )
    if call.method == "playCry" then
      cries[#cries + 1] = call
    elseif call.method == "play" then
      plays[#plays + 1] = call
    end
  end
  local leadCries, foeCries = {}, {}
  for _, cry in ipairs(cries) do
    if cry.species == leadNativeId then
      leadCries[#leadCries + 1] = cry
    elseif cry.species == foeNativeId then
      foeCries[#foeCries + 1] = cry
    end
  end
  Assert.equal(#leadCries, 1, "the lead send-out cries exactly once")
  Assert.equal(#foeCries, 1, "the foe send-out cries exactly once")
  Assert.equal(leadCries[1].species, leadNativeId, "the cry names the numeric lead identity")
  Assert.equal(leadCries[1].pattern, 0, "the cry uses the plain pattern")
  Assert.equal(foeCries[1].pattern, 0, "the foe cry uses the plain pattern")
  Assert.isTrue(leadCries[1].form == 0, "the lead cry names its form")
  Assert.isTrue(foeCries[1].pan ~= leadCries[1].pan, "foe and lead cries voice from their own sides")
  Assert.equal(#plays, 0, "no selection plays before an accepted reply")
  rig.screen:input({ { type = "confirm" } })
  pump(rig)
  Assert.equal(rig.screen:status().mode, "moves", "confirming Fight opens move selection")
  waitMenuInput(rig)
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
  Assert.equal(countCalls(audio.calls, "playCry"), 2, "settling replays no cry")
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
    context:find("cry:" .. FOE_SPECIES, 1, true) ~= nil or context:find("SEQ_", 1, true) ~= nil,
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

---@return table caller-owned dual-surface display facts
local function musicDualMeasurement()
  return {
    width = 256,
    height = 384,
    topology = ScreenTopology.dualDisplay(
      { id = "main", rect = { x = 0, y = 0, width = 256, height = 192 }, touch = false, role = "world" },
      { id = "lower", rect = { x = 0, y = 192, width = 256, height = 192 }, touch = true, role = "auxiliary" },
      "result-music:dual"
    ),
    pixelRatio = 1,
    signature = "result-music:dual",
  }
end

---@return table recording text boundary keeping every drawn string
local function musicText()
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
local function musicWindows()
  local windows = { calls = {} }
  function windows.drawWindow(box, frameKey, background)
    windows.calls[#windows.calls + 1] = { box = box, frame = frameKey, background = background }
  end
  function windows.drawApplicationFrame(box, frameKey)
    windows.calls[#windows.calls + 1] = { box = box, frame = frameKey }
  end
  return windows
end

-- A strict recording field-audio double behind the result BGM: an
-- accepted start answers true once recorded, so silent or repeated
-- swaps fail instead of passing quietly.
---@return table recording field audio double
local function strictMusicAudio()
  local audio = { music = {}, attempts = 0 }
  function audio:playMusic(symbol)
    audio.attempts = audio.attempts + 1
    audio.music[#audio.music + 1] = symbol
    return true
  end
  return audio
end

-- A field-audio double that records its one attempt and then rejects
-- it, so the envelope must latch the failure instead of retrying.
---@return table rejecting field audio double
local function rejectingMusicAudio()
  local audio = { attempts = 0 }
  function audio:playMusic(_)
    audio.attempts = audio.attempts + 1
    error("injected result-music fault", 0)
  end
  return audio
end

---@param launchId string owning launch identity under test driving
---@return table stub launch host holding its phase with recorded notifications
local function musicStubHost(launchId)
  local host = { launchId = launchId, notifies = {} }
  function host.status()
    return { phase = "active" }
  end
  function host.advance() end
  function host.submit(_)
    return false, { message = "no open request" }
  end
  function host.notify(event, detail)
    host.notifies[#host.notifies + 1] = { event = event, detail = detail }
  end
  return host
end

---@param fieldAudio table field audio double behind the result BGM
---@param kind string launch kind behind the BGM lookup
---@param launchTag string launch tag behind distinct identities
---@return table live rig with the real envelope, screen, port, and stub host
local function openMusicLaunch(fieldAudio, kind, launchTag)
  local BattlePresentationCache = require("libs.assets.src.battle.BattlePresentationCache")
  local BattlePresentationManifestFixture = require("tests.support.BattlePresentationManifestFixture")
  local cache = FieldStatePresentationFixture.cache()
  cache:writeLua(BattlePresentationCache.manifestPath(), BattlePresentationManifestFixture.manifest())
  local envelope = FieldBattlePresentation.new({
    cacheFs = cache,
    windows = musicWindows(),
    text = musicText(),
    audio = {
      play = function(_, _)
        return true
      end,
    },
    measureDisplay = function()
      return musicDualMeasurement()
    end,
  })
  local launchId = "result-music-" .. launchTag
  local host = musicStubHost(launchId)
  local port = envelope:factory()({
    launchId = launchId,
    environment = { sceneKey = SCENE_KEY },
    host = host,
    audio = fieldAudio,
    kind = kind,
    textSpeed = "mid",
  })
  Assert.notNil(port, "the envelope admits its presented launch")
  local screen = envelope:liveScreen()
  Assert.notNil(screen, "the envelope owns its live screen")
  return { envelope = envelope, screen = screen, port = port, host = host, fieldAudio = fieldAudio }
end

---@param word string terminal result word behind the fabricated delivery
---@return table detached terminal delivery picturing the settled views
local function musicTerminalPacket(launchId, packetId, word)
  local view = {
    own = {
      {
        combatant = 1,
        activation = 1,
        side = 1,
        position = 1,
        name = "LEAD",
        species = "EEVEE",
        level = 5,
        hp = 20,
        maxHp = 20,
        active = true,
      },
    },
    foes = {
      {
        combatant = 2,
        activation = 1,
        side = 2,
        position = 2,
        name = "Wild CHIKORITA",
        species = "CHIKORITA",
        level = 3,
        hp = 0,
        maxHp = 18,
        active = true,
      },
    },
  }
  return {
    launchId = launchId,
    packetId = packetId,
    events = {},
    before = view,
    after = view,
    result = { word = word },
  }
end

---@param rig table live rig under test driving
---@param word string terminal result word under test driving
---@param packetId integer delivery identity under test driving
local function driveMusicToOutcome(rig, word, packetId)
  rig.port.present(musicTerminalPacket(rig.host.launchId, packetId, word))
  for _ = 1, 900 do
    rig.screen:updateFixed(TICK)
    if rig.screen:status().mode == "outcome" then
      return
    end
    Assert.isTrue(
      rig.screen:status().mode ~= "failed",
      "the presented screen never fails: " .. tostring(rig.screen:status().error)
    )
  end
  error("the presented screen never reached its outcome for " .. tostring(word), 0)
end

---@param rig table live rig under test driving
local function acknowledgeOutcome(rig)
  for _ = 1, 30 do
    rig.screen:input({ { type = "confirm" } })
    rig.screen:updateFixed(TICK)
    if rig.port.leave({}) then
      return
    end
  end
  error("the terminal narration never acknowledged", 0)
end

-- Nonvictory terminals, replays, and a rejecting music sink stay safe:
-- loss, flee, and draw voice no BGM, a duplicated terminal delivery
-- replays no BGM, and a rejected win BGM reports once with its launch
-- identity while the committed result still acknowledges and returns.
-- A later nickname decision and launch teardown replay nothing.
function T.nonvictory_duplicate_and_rejected_result_music_stays_single_and_safe()
  for _, word in ipairs({ "loss", "flee", "draw" }) do
    local rig = openMusicLaunch(strictMusicAudio(), "wild", word)
    driveMusicToOutcome(rig, word, 1)
    for _ = 1, 30 do
      rig.envelope:updateFixed(TICK)
    end
    Assert.equal(#rig.fieldAudio.music, 0, word .. " voices no victory BGM")
    acknowledgeOutcome(rig)
    Assert.equal(#rig.fieldAudio.music, 0, word .. " still voices no victory BGM after ack")
    Assert.isTrue(rig.port.leave({}), "the acknowledged " .. word .. " terminal returns")
    rig.envelope:dispose()
  end
  do
    local rig = openMusicLaunch(strictMusicAudio(), "wild", "duplicate")
    driveMusicToOutcome(rig, "win", 1)
    Assert.equal(#rig.fieldAudio.music, 1, "the win voices its BGM once")
    rig.port.present(musicTerminalPacket(rig.host.launchId, 2, "win"))
    for _ = 1, 60 do
      rig.screen:updateFixed(TICK)
      rig.envelope:updateFixed(TICK)
    end
    Assert.equal(#rig.fieldAudio.music, 1, "the duplicated terminal replays no BGM")
    Assert.equal(rig.fieldAudio.attempts, 1, "the duplicated terminal retries no BGM start")
    acknowledgeOutcome(rig)
    Assert.equal(#rig.fieldAudio.music, 1, "the acknowledged win replays no BGM")
    rig.envelope:dispose()
  end
  do
    local rig = openMusicLaunch(rejectingMusicAudio(), "wild", "rejected")
    driveMusicToOutcome(rig, "win", 1)
    Assert.equal(rig.fieldAudio.attempts, 1, "the rejected BGM is attempted exactly once")
    local failed = {}
    for _, note in ipairs(rig.host.notifies) do
      if note.event == "screen-failed" then
        failed[#failed + 1] = note
      end
    end
    Assert.equal(#failed, 1, "the rejected BGM reports exactly once")
    local context = tostring(failed[1].detail)
    Assert.isTrue(context:find(rig.host.launchId, 1, true) ~= nil, "the failure names its launch: " .. context)
    Assert.isTrue(context:find("SEQ_GS_WIN2", 1, true) ~= nil, "the failure names its track: " .. context)
    Assert.equal(rig.screen:status().mode, "outcome", "the committed win survives its rejected BGM")
    for _ = 1, 30 do
      rig.screen:updateFixed(TICK)
      rig.envelope:updateFixed(TICK)
    end
    Assert.equal(rig.fieldAudio.attempts, 1, "the rejected BGM retries nothing per frame")
    local refailed = 0
    for _, note in ipairs(rig.host.notifies) do
      if note.event == "screen-failed" then
        refailed = refailed + 1
      end
    end
    Assert.equal(refailed, 1, "the rejected BGM reports nothing twice")
    acknowledgeOutcome(rig)
    Assert.isTrue(rig.port.leave({}), "the committed win still returns after its rejected BGM")
    rig.envelope:dispose()
  end
  do
    local rig = openMusicLaunch(strictMusicAudio(), "wild", "completion")
    driveMusicToOutcome(rig, "win", 1)
    Assert.equal(#rig.fieldAudio.music, 1, "the win voices its BGM once")
    acknowledgeOutcome(rig)
    local catalog = CatalogFixture.makeCatalog()
    local factory = CatalogFixture.makeFactory(0x1D000001, catalog)
    local subject = factory:createNormal(CatalogFixture.normalRequest({ species = "EEVEE", level = 4 }))
    Assert.isTrue(
      rig.port.openCompletion({
        launchId = rig.host.launchId,
        completionId = "nickname-1",
        kind = "capture_nickname",
        subject = subject,
      }),
      "the acknowledged terminal stores its nickname decision"
    )
    for _ = 1, 30 do
      rig.screen:updateFixed(TICK)
      rig.envelope:updateFixed(TICK)
    end
    Assert.equal(#rig.fieldAudio.music, 1, "the open completion retriggers no BGM")
    rig.screen:input({ { type = "cancel" } })
    rig.screen:updateFixed(TICK)
    local declined = rig.port.takeCompletion()
    Assert.notNil(declined, "the declined decision still seals")
    Assert.equal(#rig.fieldAudio.music, 1, "the sealed completion retriggers no BGM")
    Assert.isTrue(rig.port.leave({}), "the completed win still returns")
    rig.port.dispose()
    for _ = 1, 10 do
      rig.screen:updateFixed(TICK)
    end
    Assert.equal(#rig.fieldAudio.music, 1, "launch teardown replays no BGM")
    rig.envelope:dispose()
  end
end

return { tests = T }
