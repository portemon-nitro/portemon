-- Component coverage for the concrete HGSS application entry. It exercises
-- production Main Menu routing while observing existing composition seams.

local Assert = require("tests.support.Assert")

local T = {}

local READY_VERSION = "heartgold"

local function loadApplicationModules()
  local ok, hgssGameOrError = pcall(require, "game.hgss.src.HgssGame")
  Assert.isTrue(ok, "the concrete HGSS application must provide its entry: " .. tostring(hgssGameOrError))
  local okGame, gameOrError = pcall(require, "game.src.Game")
  Assert.isTrue(okGame, "the HGSS application must compose the generic game host: " .. tostring(gameOrError))
  local okField, fieldOrError = pcall(require, "game.hgss.src.field.FieldState")
  Assert.isTrue(okField, "the HGSS application must own FieldState: " .. tostring(fieldOrError))
  local okInit, initOrError = pcall(require, "game.hgss.src.newgame.NewGameInitialization")
  Assert.isTrue(okInit, "the HGSS application must own new-game initialization: " .. tostring(initOrError))
  local okMenu, menuOrError = pcall(require, "game.hgss.src.menu.MainMenuState")
  Assert.isTrue(okMenu, "the HGSS application must own Main Menu: " .. tostring(menuOrError))
  local okValidation, validationOrError = pcall(require, "libs.hgss.src.save.GameSaveValidation")
  Assert.isTrue(okValidation, "the HGSS application must own save validation: " .. tostring(validationOrError))
  local okStore, storeOrError = pcall(require, "libs.hgss.src.save.GameSaveStore")
  Assert.isTrue(okStore, "the HGSS application must compose the save store: " .. tostring(storeOrError))
  local okNewGame, newGameOrError = pcall(require, "game.hgss.src.newgame.NewGame")
  Assert.isTrue(okNewGame, "the HGSS application must compose New Game: " .. tostring(newGameOrError))
  local okOak, oakOrError = pcall(require, "game.hgss.src.newgame.OakIntroComposition")
  Assert.isTrue(okOak, "the HGSS application must compose Oak: " .. tostring(oakOrError))
  local okPrepared, preparedOrError = pcall(require, "game.hgss.src.field.PreparedFieldEntry")
  Assert.isTrue(okPrepared, "the HGSS application must own the prepared field entry: " .. tostring(preparedOrError))
  local okPreparation, preparationOrError = pcall(require, "game.hgss.src.field.FieldPreparationState")
  Assert.isTrue(
    okPreparation,
    "the HGSS application must own field preparation: " .. tostring(preparationOrError)
  )
  return {
    hgssGame = hgssGameOrError,
    game = gameOrError,
    fieldState = fieldOrError,
    initialization = initOrError,
    menu = menuOrError,
    validation = validationOrError,
    store = storeOrError,
    newGame = newGameOrError,
    oak = oakOrError,
    prepared = preparedOrError,
    preparation = preparationOrError,
  }
end

local function fakeStore(entries)
  local store = { entries = entries, loads = {}, deletes = {} }
  function store:list()
    return self.entries
  end
  function store:listMetadata()
    return self.entries
  end
  function store:load(saveId)
    self.loads[#self.loads + 1] = saveId
    for _, entry in ipairs(self.entries) do
      if entry.saveId == saveId then
        return entry
      end
    end
    error("missing fake save " .. saveId)
  end
  function store:delete(saveId)
    self.deletes[#self.deletes + 1] = saveId
    return true
  end
  return store
end

local function readyHost()
  return {
    requestMilestone = function()
      return true
    end,
    milestoneStatus = function()
      return { state = "ready", ready = 1, total = 1 }
    end,
    requestField = function()
      return true
    end,
    ensureField = function()
      return true
    end,
    ensureLogicalField = function()
      return true
    end,
    requestCell = function()
      return true
    end,
    ensureCell = function()
      return true
    end,
    requestMonPortraitPage = function()
      return true
    end,
    requestLogicalField = function()
      return true
    end,
    status = function()
      return {}
    end,
  }
end

local function planningLoader()
  return {
    requestLocation = function()
      return true
    end,
    globalPosition = function(_, _, fieldX, fieldZ)
      return { x = fieldX, z = fieldZ }
    end,
  }
end

local function settle(game)
  for _ = 1, 10 do
    game:update(1 / 60)
  end
end

local function saveRecord(saveId)
  return {
    saveId = saveId,
    versionId = READY_VERSION,
    playerData = { profile = { name = "GOLD" } },
    playTimeSeconds = 0,
    mapId = 60,
    fieldX = 684,
    fieldZ = 393,
  }
end

local function disposableState(kind)
  local state = { kind = kind, disposed = 0 }
  function state:dispose()
    self.disposed = self.disposed + 1
  end
  return state
end

-- All monkey patches are restored after the callback, including when a
-- constructor or assertion fails.
local function withCompositionSpies(fn)
  local modules = loadApplicationModules()
  local okText, textOrError = pcall(require, "libs.hgss.src.ui.FieldTextRenderer")
  Assert.isTrue(okText, "the Main Menu must render through FieldTextRenderer: " .. tostring(textOrError))
  local okRenderer, rendererOrError = pcall(require, "game.hgss.src.menu.MainMenuRenderer")
  Assert.isTrue(okRenderer, "the Main Menu must own its renderer: " .. tostring(rendererOrError))
  modules.fieldText = textOrError
  modules.menuRenderer = rendererOrError
  local original = {
    preparedNew = modules.prepared.new,
    preparationNew = modules.preparation.new,
    fieldNew = modules.fieldState.new,
    apply = modules.initialization.apply,
    initialLocation = modules.initialization.initialLocation,
    validationNew = modules.validation.new,
    storeNew = modules.store.new,
    candidate = modules.newGame.createCandidate,
    oakCompose = modules.oak.compose,
    textNew = modules.fieldText.new,
    menuRendererNew = modules.menuRenderer.new,
  }
  -- Incidental Oak boots (routing, menu, continue paths) use a ready fake
  -- entry; handoff tests configure their own recording factory instead.
  local function defaultPreparedEntry(options)
    local entry = { polls = 0, disposals = 0, takes = 0, location = options.location }
    function entry:poll()
      self.polls = self.polls + 1
      return true
    end
    function entry:dispose()
      self.disposals = self.disposals + 1
    end
    function entry:isReady()
      return true
    end
    function entry:take()
      self.takes = self.takes + 1
      local transfer = { versionId = options.versionId, location = options.location, claims = 0, disposals = 0 }
      function transfer:claim(_)
        self.claims = self.claims + 1
        return { mapLoader = {}, assetPreparation = {} }
      end
      function transfer:dispose()
        self.disposals = self.disposals + 1
      end
      entry.transfer = transfer
      return transfer
    end
    return entry
  end
  local context
  context = {
    fieldCalls = {},
    applyCalls = {},
    validationCalls = {},
    storeCalls = {},
    candidateCalls = {},
    oakCalls = {},
    textCalls = {},
    menuRendererCalls = {},
    texts = {},
    menuRenderers = {},
    rendererFailure = nil,
    preparedEntry = nil,
    preparationCalls = {},
    stores = {},
    validationFactory = function(_)
      return {
        validate = function(_, record)
          return record
        end,
      }
    end,
    storeFactory = function(_, index)
      return assert(context.stores[index], "test store not configured")
    end,
    candidateFactory = function(_)
      return assert(context.candidate, "test candidate not configured")
    end,
    oakFactory = function(_)
      return assert(context.oakState, "test Oak state not configured")
    end,
  }

  modules.prepared.new = function(options)
    return (context.preparedEntry or defaultPreparedEntry)(options)
  end
  modules.preparation.new = function(options)
    context.preparationCalls[#context.preparationCalls + 1] = options
    return original.preparationNew(options)
  end
  modules.fieldState.new = function(game, options)
    context.fieldCalls[#context.fieldCalls + 1] = { game = game, options = options }
    if context.fieldFailure ~= nil then
      error(context.fieldFailure, 0)
    end
    return disposableState("field")
  end
  rawset(modules.initialization, "apply", function(game)
    context.applyCalls[#context.applyCalls + 1] = game
    return game
  end)
  -- The generated start-location read is behind the same fake-ready host:
  -- the stub returns the pinned record so routing observes the pass-through
  -- without touching the real cache. Accessor behavior itself is covered in
  -- new_game_initialization_test against a stubbed CacheFs.
  rawset(modules.initialization, "initialLocation", function(_)
    return {
      mapSymbol = "MAP_NEW_BARK_PLAYER_HOUSE_2F",
      fieldX = 6,
      fieldZ = 6,
      facing = "south",
    }
  end)
  modules.validation.new = function(options)
    context.validationCalls[#context.validationCalls + 1] = options
    return context.validationFactory(options)
  end
  rawset(modules.store, "new", function(fs, options)
    context.storeCalls[#context.storeCalls + 1] = { fs = fs, options = options }
    return context.storeFactory(fs, #context.storeCalls)
  end)
  rawset(modules.newGame, "createCandidate", function(options)
    context.candidateCalls[#context.candidateCalls + 1] = options
    return context.candidateFactory(options)
  end)
  rawset(modules.oak, "compose", function(options)
    context.oakCalls[#context.oakCalls + 1] = options
    return context.oakFactory(options)
  end)
  -- Headless composition never loads generated presentation assets: the
  -- required text/renderer constructors are replaced with strict fakes that
  -- observe wiring and ownership instead.
  local function fakeText()
    local text = { releases = 0, draws = 0 }
    function text:drawText()
      self.draws = self.draws + 1
    end
    function text:release()
      self.releases = self.releases + 1
    end
    return text
  end
  modules.fieldText.new = function(options)
    context.textCalls[#context.textCalls + 1] = options
    local text = fakeText()
    context.texts[#context.texts + 1] = text
    return text
  end
  modules.menuRenderer.new = function(options)
    context.menuRendererCalls[#context.menuRendererCalls + 1] = options
    if context.rendererFailure ~= nil then
      error(context.rendererFailure, 0)
    end
    Assert.equal(options.text, context.texts[#context.texts], "the menu renderer must own the composed menu text")
    local renderer = {
      text = options.text,
      draws = 0,
      disposed = 0,
    }
    function renderer:draw()
      self.draws = self.draws + 1
    end
    function renderer:dispose()
      self.disposed = self.disposed + 1
      if self.text and self.text.release then
        self.text:release()
      end
      self.text = nil
    end
    context.menuRenderers[#context.menuRenderers + 1] = renderer
    return renderer
  end
  local ok, err = pcall(function()
    fn(modules, context)
  end)

  modules.prepared.new = original.preparedNew
  modules.preparation.new = original.preparationNew
  modules.fieldState.new = original.fieldNew
  rawset(modules.initialization, "apply", original.apply)
  rawset(modules.initialization, "initialLocation", original.initialLocation)
  modules.validation.new = original.validationNew
  rawset(modules.store, "new", original.storeNew)
  rawset(modules.newGame, "createCandidate", original.candidate)
  rawset(modules.oak, "compose", original.oakCompose)
  modules.fieldText.new = original.textNew
  modules.menuRenderer.new = original.menuRendererNew
  if not ok then
    error(err, 0)
  end
end

local function menuView(menu)
  return assert(menu:view())
end

function T.hgss_entry_owns_menu_continue_new_game_oak_and_quit_routing()
  withCompositionSpies(function(modules, context)
    local exits = {}
    local continueRecord = saveRecord("save-00000002")
    context.stores[1] = fakeStore({ continueRecord })
    context.stores[2] = fakeStore({})
    context.stores[3] = fakeStore({})
    local candidate = {
      saveId = "save-00000003",
      versionId = READY_VERSION,
      playerData = nil,
      location = { mapSymbol = "MAP_NEW_BARK_PLAYER_HOUSE_2F", fieldX = 6, fieldZ = 6 },
    }
    local finalized = {
      saveId = candidate.saveId,
      versionId = READY_VERSION,
      playerData = {},
      location = { mapSymbol = "MAP_NEW_BARK_PLAYER_HOUSE_2F", fieldX = 6, fieldZ = 6 },
    }
    context.candidate = candidate
    context.candidateFactory = function(options)
      Assert.equal(options.saveService, context.stores[2])
      Assert.equal(options.versionId, READY_VERSION)
      Assert.notNil(options.eventState)
      Assert.notNil(options.scriptSymbols)
      Assert.deepEqual(options.mapIdentity, {
        mapSymbol = "MAP_NEW_BARK_PLAYER_HOUSE_2F",
        fieldX = 6,
        fieldZ = 6,
        facing = "south",
      })
      return candidate
    end
    context.oakState = disposableState("oak")
    context.oakFactory = function(options)
      Assert.equal(options.candidate, candidate)
      Assert.equal(options.versionId, READY_VERSION)
      Assert.isTrue(type(options.onComplete) == "function")
      Assert.isTrue(type(options.preparedEntry) == "table", "Oak receives the staged bedroom entry")
      Assert.isTrue(type(options.preparedEntry.poll) == "function", "the staged entry polls")
      Assert.isTrue(type(options.preparedEntry.dispose) == "function", "the staged entry disposes")
      return context.oakState
    end

    local game = modules.hgssGame.new({
      versionId = READY_VERSION,
      onExit = function(result)
        exits[#exits + 1] = result
      end,
      development = false,
      derivedAssets = readyHost(),
      fieldMapLoader = planningLoader(),
    })
    Assert.equal(getmetatable(game).__index, modules.game)
    Assert.equal(getmetatable(game.state).__index, modules.menu)
    Assert.equal(menuView(game.state).kind, "main_menu")
    Assert.equal(#context.validationCalls, 1)
    Assert.equal(#context.storeCalls, 1)

    game.state:keypressed("return")
    Assert.equal(#context.fieldCalls, 0, "Continue waits for planning, runtime, and geometry before strict load")
    settle(game)
    Assert.equal(#context.fieldCalls, 1)
    Assert.equal(context.fieldCalls[1].game, continueRecord)
    Assert.deepEqual(context.stores[1].loads, { continueRecord.saveId })
    Assert.equal(type(context.storeCalls[1].options.recordValidate), "function")
    local firstField = game.state
    game:setState(nil)
    Assert.equal(firstField.disposed, 1)

    local newGame = modules.hgssGame.new({
      versionId = READY_VERSION,
      onExit = function(result)
        exits[#exits + 1] = result
      end,
      development = true,
      derivedAssets = readyHost(),
      fieldMapLoader = planningLoader(),
    })
    newGame.state:keypressed("return")
    Assert.equal(#context.candidateCalls, 0, "New Game waits for its intro milestone before reserving a candidate")
    Assert.equal(#context.oakCalls, 0, "New Game waits for its intro milestone before composing Oak")
    settle(newGame)
    Assert.equal(#context.candidateCalls, 1)
    Assert.equal(#context.oakCalls, 1)
    local preparationsBeforeHandoff = #context.preparationCalls
    context.oakCalls[1].onComplete(finalized)
    Assert.equal(#context.applyCalls, 1)
    Assert.equal(context.applyCalls[1], finalized)
    Assert.equal(#context.fieldCalls, 2, "the handoff constructs the field directly from the staged entry")
    Assert.equal(context.fieldCalls[2].game, finalized)
    Assert.isTrue(context.fieldCalls[2].options.development)
    Assert.isTrue(
      context.fieldCalls[2].options.preparedEntry ~= nil,
      "the direct handoff carries the staged transfer"
    )
    Assert.equal(
      #context.preparationCalls,
      preparationsBeforeHandoff,
      "the New Game handoff never installs a preparation state"
    )
    settle(newGame)
    Assert.equal(#context.fieldCalls, 2, "waiting constructs no second field")
    Assert.equal(context.oakState.disposed, 1)
    newGame:setState(nil)

    local quitGame = modules.hgssGame.new({
      versionId = READY_VERSION,
      onExit = function(result)
        exits[#exits + 1] = result
      end,
      derivedAssets = readyHost(),
      fieldMapLoader = planningLoader(),
    })
    quitGame.state:keypressed("escape")
    Assert.deepEqual(exits, { { kind = "quit" } })
    quitGame:dispose()
  end)
end

-- Choosing New Game while its intro closure is cold enters preparation
-- instead of composing Oak: the milestone is requested as required, no
-- candidate is reserved and no Oak state is composed until readiness, and
-- the pending transfer then happens exactly once.
function T.cold_new_game_waits_for_its_intro_milestone_before_oak()
  withCompositionSpies(function(modules, context)
    local NewGamePreparationState = require("game.hgss.src.newgame.NewGamePreparationState")
    context.stores[1] = fakeStore({})
    local candidate = {
      saveId = "save-00000003",
      versionId = READY_VERSION,
      playerData = nil,
      location = { mapSymbol = "MAP_NEW_BARK_PLAYER_HOUSE_2F", fieldX = 6, fieldZ = 6 },
    }
    context.candidate = candidate
    context.oakState = disposableState("oak")
    local introReady = false
    local milestoneCalls = {}
    local host = readyHost()
    host.requestMilestone = function(name, urgency)
      if name == "new-game-intro" then
        milestoneCalls[#milestoneCalls + 1] = urgency
        return introReady
      end
      return true
    end
    local game = modules.hgssGame.new({
      versionId = READY_VERSION,
      onExit = function() end,
      derivedAssets = host,
      fieldMapLoader = planningLoader(),
    })
    game.state:keypressed("return")
    Assert.equal(getmetatable(game.state).__index, NewGamePreparationState, "cold New Game enters preparation")
    settle(game)
    Assert.equal(#milestoneCalls >= 2, true, "menu prefetch plus preparation request their intro milestone")
    Assert.equal(milestoneCalls[1], "near", "menu installation prefetches the intro closure")
    for index = 2, #milestoneCalls do
      Assert.equal(milestoneCalls[index], "required")
    end
    Assert.equal(#context.candidateCalls, 0, "no candidate is reserved while the intro closure is cold")
    Assert.equal(#context.oakCalls, 0, "Oak is never composed before milestone readiness")
    introReady = true
    settle(game)
    Assert.equal(#context.candidateCalls, 1, "readiness reserves exactly one candidate")
    Assert.equal(#context.oakCalls, 1, "readiness composes Oak exactly once")
    settle(game)
    Assert.equal(#context.candidateCalls, 1, "settling never reserves a second candidate")
    Assert.equal(#context.oakCalls, 1, "settling never composes a second Oak")
    game:setState(nil)
  end)
end

function T.menu_presentation_is_wired_from_fakes_and_released_exactly_once()
  withCompositionSpies(function(modules, context)
    context.stores[1] = fakeStore({})
    local game = modules.hgssGame.new({
      versionId = READY_VERSION,
      onExit = function() end,
      derivedAssets = readyHost(),
      fieldMapLoader = planningLoader(),
    })
    Assert.equal(#context.textCalls, 1, "menu text construction must run once per game")
    Assert.equal(#context.menuRendererCalls, 1, "menu renderer construction must run once per game")
    Assert.equal(#context.texts, 1)
    Assert.equal(#context.menuRenderers, 1)
    local renderer = context.menuRenderers[1]
    Assert.equal(renderer.text, context.texts[1], "the fake renderer must own the fake menu text")
    Assert.equal(menuView(game.state).kind, "main_menu")
    game:dispose()
    Assert.equal(renderer.disposed, 1, "the menu renderer must be disposed exactly once")
    Assert.equal(context.texts[1].releases, 1, "the owned menu text must be released exactly once")
  end)
end

function T.menu_renderer_failure_releases_the_allocated_text_exactly_once()
  withCompositionSpies(function(modules, context)
    context.stores[1] = fakeStore({})
    context.rendererFailure = "injected menu renderer failure"
    local ok, err = pcall(modules.hgssGame.new, {
      versionId = READY_VERSION,
      onExit = function() end,
      derivedAssets = readyHost(),
      fieldMapLoader = planningLoader(),
    })
    Assert.isFalse(ok, "a menu renderer failure must fail game construction")
    Assert.isTrue(string.find(tostring(err), "injected menu renderer failure") ~= nil)
    Assert.equal(#context.texts, 1, "the text must be allocated before the renderer fails")
    Assert.equal(context.texts[1].releases, 1, "the allocated text must be released exactly once")
    Assert.equal(#context.menuRenderers, 0, "no menu renderer may escape a failed construction")
  end)
end

-- Production loader observation for the cold-cache sequencing contract below.
-- The fake version cache answers only the world-manifest read with a canned
-- manifest; every other generated read fails loudly so the tests prove the
-- composition never reaches past the manifest before field-runtime readiness.
local function cannedWorld()
  local MapAssetCache = require("libs.assets.src.MapAssetCache")
  return {
    schema = MapAssetCache.WORLD_SCHEMA,
    maps = {
      {
        id = 60,
        symbol = "MAP_NEW_BARK_PLAYER_HOUSE_2F",
        mapSection = "TEST_SECTION",
        mapSectionNativeId = 7,
        followMode = "ALLOW",
        worldOriginX = 0,
        worldOriginZ = 0,
        matrix = { memberId = 0 },
      },
    },
    byId = { [60] = 1 },
    bySymbol = { MAP_NEW_BARK_PLAYER_HOUSE_2F = 60 },
    analysis = { mapHeaderCount = 1, excluded = {} },
  }
end

local function withProductionLoaderObservation(worldOrNil, fn)
  local CacheFs = require("libs.storage.src.CacheFs")
  local FieldCellCache = require("libs.assets.src.field.FieldCellCache")
  local FieldMapLoader = require("libs.hgss.src.world.FieldMapLoader")
  local MapAssetCache = require("libs.assets.src.MapAssetCache")
  local originalForVersion = CacheFs.forVersion
  local originalLoaderNew = FieldMapLoader.new
  local observation = { worldReads = 0, loaderBuilds = 0, world = worldOrNil }
  rawset(CacheFs, "forVersion", function(_)
    local cacheFs = {}
    -- Only the world-manifest path counts as a world read: entry geometry
    -- demand reads sibling records (warp-exit field data) through the same
    -- filesystem after readiness, and those must not masquerade as
    -- manifest reads. Best-effort prewarming treats an unreadable record
    -- as absent, so the count stays exact without weakening the contract.
    function cacheFs.loadLua(_, path)
      if path == MapAssetCache.worldPath() then
        observation.worldReads = observation.worldReads + 1
        return observation.world
      end
      if path == FieldCellCache.indexPath() then
        return { schema = FieldCellCache.INDEX_SCHEMA, matrices = {} }
      end
      return nil
    end
    return cacheFs
  end)
  rawset(FieldMapLoader, "new", function(cacheFs, world, options)
    observation.loaderBuilds = observation.loaderBuilds + 1
    return originalLoaderNew(cacheFs, world, options)
  end)
  local ok, err = pcall(fn, observation)
  rawset(CacheFs, "forVersion", originalForVersion)
  rawset(FieldMapLoader, "new", originalLoaderNew)
  if not ok then
    error(err, 0)
  end
end

-- Cold Continue must not touch generated world metadata before entry
-- planning reports ready: selecting Continue with pending planning
-- constructs preparation without reading the world, and the production
-- loader is built exactly once after readiness before geometry is
-- requested.
function T.cold_continue_defers_world_read_until_field_planning_is_ready()
  withCompositionSpies(function(modules, _)
    withProductionLoaderObservation(cannedWorld(), function(observation)
      local continueRecord = saveRecord("save-00000002")
      local contextStores = { fakeStore({ continueRecord }) }
      local storeModule = require("libs.hgss.src.save.GameSaveStore")
      local originalStoreNew = storeModule.new
      rawset(storeModule, "new", function()
        return contextStores[1]
      end)
      local ok, err = pcall(function()
        local planningReady = false
        local host = readyHost()
        host.requestMilestone = function(name, _)
          if name == "field-planning" then
            return planningReady
          end
          return true
        end
        local game = modules.hgssGame.new({
          versionId = READY_VERSION,
          onExit = function() end,
          derivedAssets = host,
        })
        game.state:keypressed("return")
        Assert.equal(observation.worldReads, 0, "selecting Continue reads no world metadata")
        Assert.equal(observation.loaderBuilds, 0, "selecting Continue builds no planning loader")
        settle(game)
        Assert.equal(observation.worldReads, 0, "pending planning never reads world metadata")
        Assert.equal(observation.loaderBuilds, 0, "pending planning never builds the planning loader")
        planningReady = true
        settle(game)
        Assert.equal(observation.worldReads, 1, "readiness reads the world manifest exactly once")
        Assert.equal(observation.loaderBuilds, 1, "readiness builds the planning loader exactly once")
        settle(game)
        Assert.equal(observation.worldReads, 1, "settling never re-reads the world manifest")
        Assert.equal(observation.loaderBuilds, 1, "settling never rebuilds the planning loader")
        game:setState(nil)
      end)
      rawset(storeModule, "new", originalStoreNew)
      if not ok then
        error(err, 0)
      end
    end)
  end)
end

-- Cold New Game must survive the Oak handoff without world metadata: the
-- finalized candidate waits on entry planning with zero world reads, then
-- builds the production loader exactly once after readiness.
function T.oak_completion_with_a_diverging_location_fails_without_field()
  withCompositionSpies(function(modules, context)
    context.stores[1] = fakeStore({})
    context.candidate = {
      saveId = "save-00000003",
      versionId = READY_VERSION,
      playerData = nil,
      location = { mapSymbol = "MAP_NEW_BARK_PLAYER_HOUSE_2F", fieldX = 6, fieldZ = 6 },
    }
    context.oakState = disposableState("oak")
    local game = modules.hgssGame.new({
      versionId = READY_VERSION,
      onExit = function() end,
      derivedAssets = readyHost(),
      fieldMapLoader = planningLoader(),
    })
    game.state:keypressed("return")
    settle(game)
    local diverged = {
      saveId = "save-00000003",
      versionId = READY_VERSION,
      playerData = {},
      location = { mapSymbol = "MAP_NEW_BARK_TOWN", fieldX = 1, fieldZ = 1 },
    }
    local ok, err = pcall(context.oakCalls[1].onComplete, diverged)
    Assert.isFalse(ok, "a diverging finalized location fails the handoff")
    Assert.isTrue(string.find(tostring(err), "diverges", 1, true) ~= nil, "the failure names the divergence")
    Assert.equal(#context.fieldCalls, 0, "a diverging handoff constructs no field")
    Assert.equal(#context.preparationCalls, 0, "a diverging handoff falls back to no preparation state")
    game:setState(nil)
  end)
end

function T.failed_field_construction_releases_the_unclaimed_transfer()
  withCompositionSpies(function(modules, context)
    context.stores[1] = fakeStore({})
    context.candidate = {
      saveId = "save-00000003",
      versionId = READY_VERSION,
      playerData = nil,
      location = { mapSymbol = "MAP_NEW_BARK_PLAYER_HOUSE_2F", fieldX = 6, fieldZ = 6 },
    }
    context.oakState = disposableState("oak")
    local entries = {}
    context.preparedEntry = function(options)
      local entry = { location = options.location }
      function entry:poll()
        return true
      end
      function entry:dispose() end
      function entry:take()
        local transfer = { disposals = 0 }
        function transfer:claim(_)
          return { mapLoader = {}, assetPreparation = {} }
        end
        function transfer:dispose()
          self.disposals = self.disposals + 1
        end
        entry.transfer = transfer
        return transfer
      end
      entries[#entries + 1] = entry
      return entry
    end
    context.fieldFailure = "injected field construction failure"
    local game = modules.hgssGame.new({
      versionId = READY_VERSION,
      onExit = function() end,
      derivedAssets = readyHost(),
      fieldMapLoader = planningLoader(),
    })
    game.state:keypressed("return")
    settle(game)
    local finalized = {
      saveId = "save-00000003",
      versionId = READY_VERSION,
      playerData = {},
      location = { mapSymbol = "MAP_NEW_BARK_PLAYER_HOUSE_2F", fieldX = 6, fieldZ = 6 },
    }
    local ok, err = pcall(context.oakCalls[1].onComplete, finalized)
    Assert.isFalse(ok, "field construction failure propagates")
    Assert.isTrue(
      string.find(tostring(err), "injected field construction failure", 1, true) ~= nil,
      "the original failure surfaces"
    )
    Assert.equal(entries[1].transfer.disposals, 1, "the unclaimed transfer releases exactly once")
    Assert.equal(#context.preparationCalls, 0, "a failed handoff installs no preparation state")
    game:setState(nil)
  end)
end

-- A world manifest that is still unavailable after entry readiness is a
-- visible preparation failure, never an escaped composition error and
-- never a manual full-cache instruction.
function T.missing_world_after_readiness_fails_preparation_visibly()
  withCompositionSpies(function(modules, _)
    withProductionLoaderObservation(nil, function(observation)
      local continueRecord = saveRecord("save-00000002")
      local contextStores = { fakeStore({ continueRecord }) }
      local storeModule = require("libs.hgss.src.save.GameSaveStore")
      local originalStoreNew = storeModule.new
      rawset(storeModule, "new", function()
        return contextStores[1]
      end)
      local ok, err = pcall(function()
        local FieldPreparationState = require("game.hgss.src.field.FieldPreparationState")
        local game = modules.hgssGame.new({
          versionId = READY_VERSION,
          onExit = function() end,
          derivedAssets = readyHost(),
        })
        game.state:keypressed("return")
        Assert.equal(observation.worldReads, 0, "selecting Continue reads no world metadata")
        settle(game)
        Assert.equal(
          getmetatable(game.state).__index,
          FieldPreparationState,
          "a missing world still enters preparation once core is ready"
        )
        Assert.equal(game.state.phase, "failed", "the missing world fails preparation visibly")
        Assert.isTrue(game.state.error ~= nil, "the failure carries a diagnostic")
        Assert.isTrue(
          string.find(tostring(game.state.error), "buildcache", 1, true) == nil,
          "the failure never instructs a manual full-cache build: " .. tostring(game.state.error)
        )
        Assert.equal(observation.worldReads, 1, "the failed attempt still read the world exactly once")
        game:setState(nil)
      end)
      rawset(storeModule, "new", originalStoreNew)
      if not ok then
        error(err, 0)
      end
    end)
  end)
end

function T.composition_spies_restore_presentation_constructors_when_the_body_throws()
  local fieldText = require("libs.hgss.src.ui.FieldTextRenderer")
  local menuRenderer = require("game.hgss.src.menu.MainMenuRenderer")
  local textNew, rendererNew = fieldText.new, menuRenderer.new
  local ok, err = pcall(withCompositionSpies, function()
    error("injected composition body failure", 0)
  end)
  Assert.isFalse(ok, "the spy wrapper must rethrow the body failure")
  Assert.isTrue(string.find(tostring(err), "injected composition body failure") ~= nil)
  Assert.equal(fieldText.new, textNew, "the text constructor must be restored after a throw")
  Assert.equal(menuRenderer.new, rendererNew, "the menu renderer constructor must be restored after a throw")
end

function T.field_receives_the_shared_display_context_and_copied_overrides()
  withCompositionSpies(function(modules, context)
    local continueRecord = saveRecord("save-00000002")
    context.stores[1] = fakeStore({ continueRecord })
    context.stores[2] = fakeStore({ saveRecord("save-00000004") })
    local wideFn = function(_, _)
      return {}
    end
    local overrides = { start_menu = { wide = wideFn } }
    local game = modules.hgssGame.new({
      versionId = READY_VERSION,
      onExit = function() end,
      derivedAssets = readyHost(),
      fieldMapLoader = planningLoader(),
      presentationOverrides = overrides,
    })
    game.state:keypressed("return")
    settle(game)
    Assert.equal(#context.fieldCalls, 1, "the continue route must reach the field")
    local fieldOptions = context.fieldCalls[1].options
    Assert.notNil(fieldOptions.displayContext, "the field shares the product display context")
    local copied = assert(
      fieldOptions.presentationOverrides and fieldOptions.presentationOverrides.start_menu,
      "the field receives the start menu overrides"
    )
    Assert.isTrue(copied.wide == wideFn, "override functions arrive intact")
    Assert.isTrue(fieldOptions.presentationOverrides ~= overrides, "overrides are copied once, never retained")
    overrides.start_menu.wide = function(_, _)
      return {}
    end
    Assert.isTrue(copied.wide == wideFn, "later caller mutations never reach the game")
    game:setState(nil)

    local plain = modules.hgssGame.new({
      versionId = READY_VERSION,
      onExit = function() end,
      derivedAssets = readyHost(),
      fieldMapLoader = planningLoader(),
    })
    plain.state:keypressed("return")
    settle(plain)
    Assert.equal(#context.fieldCalls, 2, "the second game routes independently")
    Assert.isTrue(
      context.fieldCalls[2].options.presentationOverrides == nil,
      "overrides never leak between game instances"
    )
    Assert.isTrue(
      context.fieldCalls[2].options.displayContext ~= fieldOptions.displayContext,
      "each game owns its display context"
    )
    plain:setState(nil)
  end)
end

function T.invalid_presentation_overrides_fail_game_construction()
  withCompositionSpies(function(modules, context)
    context.stores[1] = fakeStore({})
    local okKey = pcall(modules.hgssGame.new, {
      versionId = READY_VERSION,
      onExit = function() end,
      derivedAssets = readyHost(),
      fieldMapLoader = planningLoader(),
      presentationOverrides = {
        start_menu = {
          sideways = function(_, _) end,
        },
      },
    })
    Assert.isFalse(okKey, "an unknown override case fails construction")
    local okFn = pcall(modules.hgssGame.new, {
      versionId = READY_VERSION,
      onExit = function() end,
      derivedAssets = readyHost(),
      fieldMapLoader = planningLoader(),
      presentationOverrides = {
        start_menu = { wide = "not-a-function" },
      },
    })
    Assert.isFalse(okFn, "a non-function override fails construction")
  end)
end

function T.cancelling_field_preparation_returns_to_the_menu_without_publishing()
  withCompositionSpies(function(modules, context)
    local continueRecord = saveRecord("save-00000002")
    context.stores[1] = fakeStore({ continueRecord })
    local pending = true
    local host = readyHost()
    host.requestMilestone = function()
      return not pending
    end
    local game = modules.hgssGame.new({
      versionId = READY_VERSION,
      onExit = function() end,
      derivedAssets = host,
      fieldMapLoader = planningLoader(),
    })
    game.state:keypressed("return")
    settle(game)
    Assert.equal(#context.fieldCalls, 0, "pending core never constructs the field")
    game.state:keypressed("escape")
    Assert.equal(getmetatable(game.state).__index, modules.menu, "cancellation returns to the owning menu")
    Assert.equal(#context.fieldCalls, 0, "cancellation publishes no field")
    pending = false
    settle(game)
    Assert.equal(#context.fieldCalls, 0, "a cancelled preparation never transfers late")
    game:dispose()
  end)
end

function T.cancelled_preparation_rebuilds_the_menu_at_the_current_viewport()
  withCompositionSpies(function(modules, context)
    local continueRecord = saveRecord("save-00000002")
    context.stores[1] = fakeStore({ continueRecord })
    local pending = true
    local host = readyHost()
    host.requestMilestone = function()
      return not pending
    end
    local game = modules.hgssGame.new({
      versionId = READY_VERSION,
      onExit = function() end,
      derivedAssets = host,
      fieldMapLoader = planningLoader(),
    })
    local firstRenderer = context.menuRenderers[1]
    local firstText = context.texts[1]
    game.state:keypressed("return")
    settle(game)
    Assert.equal(#context.fieldCalls, 0, "pending core never constructs the field")
    Assert.isTrue(
      getmetatable(game.state).__index ~= modules.menu,
      "Continue must leave the menu for preparation while core is pending"
    )
    Assert.equal(firstRenderer.disposed, 1, "entering preparation disposes the previous menu renderer")
    Assert.equal(firstText.releases, 1, "entering preparation releases the previous menu text")
    game:resize(960, 720)
    game.state:keypressed("escape")
    Assert.equal(getmetatable(game.state).__index, modules.menu, "cancellation returns to the owning menu")
    Assert.equal(#context.fieldCalls, 0, "cancellation publishes no field")
    local rebuilt = game.state
    Assert.equal(rebuilt.width, 960, "the rebuilt menu must use the current drawable width")
    Assert.equal(rebuilt.height, 720, "the rebuilt menu must use the current drawable height")
    local frame = assert(
      menuView(rebuilt).presentation.panes[1].placement.frame,
      "the rebuilt menu must resolve its placement frame"
    )
    Assert.equal(frame.width, 960, "the rebuilt menu frame must cover the current viewport width")
    Assert.equal(frame.height, 720, "the rebuilt menu frame must cover the current viewport height")
    Assert.equal(#context.menuRenderers, 2, "cancellation constructs exactly one replacement renderer")
    Assert.equal(#context.texts, 2, "cancellation constructs exactly one replacement text")
    local secondRenderer = context.menuRenderers[2]
    Assert.equal(secondRenderer.disposed, 0, "the replacement renderer must be live before disposal")
    game:dispose()
    Assert.equal(secondRenderer.disposed, 1, "final disposal releases the replacement renderer exactly once")
    Assert.equal(context.texts[2].releases, 1, "final disposal releases the replacement text exactly once")
    Assert.equal(firstRenderer.disposed, 1, "the first renderer must not be disposed twice")
    Assert.equal(firstText.releases, 1, "the first text must not be released twice")
  end)
end

function T.menu_installation_prefetches_the_new_game_closure_at_near()
  withCompositionSpies(function(modules, context)
    context.stores[1] = fakeStore({})
    local requests = {}
    local host = readyHost()
    host.requestMilestone = function(name, urgency)
      requests[#requests + 1] = { name = name, urgency = urgency }
      return true
    end
    local game = modules.hgssGame.new({
      versionId = READY_VERSION,
      onExit = function() end,
      derivedAssets = host,
      fieldMapLoader = planningLoader(),
    })
    Assert.equal(getmetatable(game.state).__index, modules.menu, "construction installs the menu")
    local prefetch = 0
    for _, request in ipairs(requests) do
      Assert.isTrue(request.name ~= "field-runtime", "menu installation prefetches no field demand")
      if request.name == "new-game-intro" then
        prefetch = prefetch + 1
        Assert.equal(request.urgency, "near", "the New Game prefetch stays speculative")
      end
    end
    Assert.equal(prefetch, 1, "menu installation prefetches the New Game closure exactly once")
    game:dispose()
  end)
end

-- Booting the Oak intro prefetches the static field runtime at near
-- without waiting for it: Oak is composed while the runtime is still
-- pending, the intro gate never demands the runtime as required, and the
-- prewarm happens exactly once.
function T.oak_boot_stages_the_bedroom_entry_without_waiting_for_it()
  withCompositionSpies(function(modules, context)
    context.stores[1] = fakeStore({})
    context.candidate = {
      saveId = "save-00000003",
      versionId = READY_VERSION,
      playerData = nil,
      location = { mapSymbol = "MAP_NEW_BARK_PLAYER_HOUSE_2F", fieldX = 6, fieldZ = 6 },
    }
    context.oakState = disposableState("oak")
    local entries = {}
    context.preparedEntry = function(options)
      local entry = { polls = 0, disposals = 0, location = options.location }
      function entry:poll()
        self.polls = self.polls + 1
        return false
      end
      function entry:dispose()
        self.disposals = self.disposals + 1
      end
      entries[#entries + 1] = entry
      return entry
    end
    local game = modules.hgssGame.new({
      versionId = READY_VERSION,
      onExit = function() end,
      derivedAssets = readyHost(),
      fieldMapLoader = planningLoader(),
    })
    game.state:keypressed("return")
    settle(game)
    Assert.equal(#context.oakCalls, 1, "Oak is composed while bedroom staging is still pending")
    Assert.equal(#entries, 1, "Oak boot stages the bedroom entry exactly once")
    local composed = assert(context.oakCalls[1], "Oak composition must be observed")
    Assert.isTrue(composed.preparedEntry == entries[1], "Oak receives the staged bedroom entry")
    Assert.isTrue(entries[1].polls >= 1, "boot polls the entry without blocking on it")
    Assert.equal(#context.preparationCalls, 0, "booting Oak installs no preparation state")
    Assert.equal(#context.fieldCalls, 0, "pending staging never constructs the field")
    game:setState(nil)
  end)
end

-- Oak boots even when speculative field demands fail: the coordinator retains
-- the failure for diagnosis and composition proceeds, so a broken cache
-- surfaces at the authoritative handoff instead of aborting the intro.
function T.oak_boot_survives_preparation_demand_failure()
  withCompositionSpies(function(modules, context)
    context.stores[1] = fakeStore({})
    context.candidate = {
      saveId = "save-00000003",
      versionId = READY_VERSION,
      playerData = nil,
      location = { mapSymbol = "MAP_NEW_BARK_PLAYER_HOUSE_2F", fieldX = 6, fieldZ = 6 },
    }
    context.oakState = disposableState("oak")
    local host = readyHost()
    host.requestMilestone = function(name, _)
      if name == "new-game-intro" then
        return true
      end
      error("injected preparation demand failure", 0)
    end
    local game = modules.hgssGame.new({
      versionId = READY_VERSION,
      onExit = function() end,
      derivedAssets = host,
      fieldMapLoader = planningLoader(),
    })
    game.state:keypressed("return")
    settle(game)
    Assert.equal(#context.oakCalls, 1, "Oak composes even when preparation demands fail")
    Assert.equal(#context.preparationCalls, 0, "a demand failure installs no preparation state")
    game:setState(nil)
  end)
end

-- Completing Oak promotes the runtime prewarm to required interest through
-- the handoff preparation: planning and runtime are demanded as required
-- exactly once each, initialization still applies exactly once while the
-- handoff waits, and no second candidate is created by later updates.
function T.oak_completion_enters_the_prepared_field_directly()
  withCompositionSpies(function(modules, context)
    context.stores[1] = fakeStore({})
    local candidate = {
      saveId = "save-00000003",
      versionId = READY_VERSION,
      playerData = nil,
      location = { mapSymbol = "MAP_NEW_BARK_PLAYER_HOUSE_2F", fieldX = 6, fieldZ = 6 },
    }
    local finalized = {
      saveId = candidate.saveId,
      versionId = READY_VERSION,
      playerData = {},
      location = { mapSymbol = "MAP_NEW_BARK_PLAYER_HOUSE_2F", fieldX = 6, fieldZ = 6 },
    }
    context.candidate = candidate
    context.oakState = disposableState("oak")
    local entries = {}
    context.preparedEntry = function(options)
      local entry = { takes = 0, disposals = 0, location = options.location }
      function entry:poll()
        return true
      end
      function entry:dispose()
        self.disposals = self.disposals + 1
      end
      function entry:take()
        self.takes = self.takes + 1
        local transfer = { claims = 0, disposals = 0, location = self.location }
        function transfer:claim(_)
          self.claims = self.claims + 1
          return { mapLoader = {}, assetPreparation = {} }
        end
        function transfer:dispose()
          self.disposals = self.disposals + 1
        end
        entry.transfer = transfer
        return transfer
      end
      entries[#entries + 1] = entry
      return entry
    end
    local game = modules.hgssGame.new({
      versionId = READY_VERSION,
      onExit = function() end,
      derivedAssets = readyHost(),
      fieldMapLoader = planningLoader(),
    })
    game.state:keypressed("return")
    settle(game)
    Assert.equal(#context.oakCalls, 1, "Oak is composed before the handoff")
    context.oakCalls[1].onComplete(finalized)
    Assert.equal(#context.applyCalls, 1, "initialization applies exactly once")
    Assert.equal(entries[1].takes, 1, "the handoff takes the staged entry exactly once")
    Assert.equal(#context.fieldCalls, 1, "the handoff constructs the field directly")
    Assert.equal(context.fieldCalls[1].game, finalized, "the field receives the finalized candidate")
    Assert.isTrue(
      context.fieldCalls[1].options.preparedEntry == entries[1].transfer,
      "the field receives the staged transfer"
    )
    Assert.equal(#context.preparationCalls, 0, "the New Game handoff never installs a preparation state")
    settle(game)
    Assert.equal(#context.applyCalls, 1, "waiting never reapplies initialization")
    Assert.equal(#context.candidateCalls, 1, "waiting never reserves a second candidate")
    game:setState(nil)
  end)
end

return { tests = T }
