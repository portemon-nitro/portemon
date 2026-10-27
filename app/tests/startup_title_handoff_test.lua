-- Exercise startup through App's source gate and selected epoch. Presentation
-- objects are recorded at their graphics boundary; cache readiness, state
-- ownership, and the staged menu path remain production-composed.

local Assert = require("tests.support.Assert")
local App = require("app.src.App")
local FirstPlayCompletion = require("romdump.src.FirstPlayCompletion")
local HgssLoadingPresentation = require("libs.hgss.src.ui.HgssLoadingPresentation")
local MainMenuComposition = require("app.src.mainmenu.MainMenuComposition")
local HgssGame = require("game.hgss.src.HgssGame")
local StartupAudioSession = require("app.src.audio.StartupAudioSession")

local TITLE_SCENE_MODULE = "libs.hgss.src.presentation.HgssTitleScene"
local titleSceneModule = require(TITLE_SCENE_MODULE)
local MOVIE_MODULE = "libs.hgss.src.presentation.HgssOpeningMovie"
local movieModule = require(MOVIE_MODULE)
local StartupAssetCache = require("libs.assets.src.StartupAssetCache")

local T = { tests = {} }
local active

local function newLoadingPresentation()
  return {
    update = function() end,
    resize = function() end,
    draw = function() end,
    dispose = function() end,
    adoptGeneratedAssets = function()
      return true
    end,
  }
end

local function fakeMenu(options)
  active.menuAttempts = (active.menuAttempts or 0) + 1
  if active.failMenuConstruction then
    active.failMenuConstruction = false
    error("synthetic staged menu construction failure")
  end
  local menu = {
    options = options,
    disposed = 0,
    inputs = 0,
  }
  function menu:update() end
  function menu:draw()
    active.drawEvents[#active.drawEvents + 1] = "menu"
  end
  function menu:resize() end
  function menu:keypressed()
    self.inputs = self.inputs + 1
  end
  function menu:mousereleased()
    self.releases = (self.releases or 0) + 1
  end
  function menu:dispose()
    self.disposed = self.disposed + 1
  end
  active.menus[#active.menus + 1] = menu
  return menu
end

local function withStartup(fn)
  local saved = {
    state = App.state,
    importer = App.importer,
    provisioner = App.provisioner,
    service = App.service,
    epoch = App.epoch,
    pairIndex = App.pairIndex,
    pendingQuiesce = App.pendingQuiesce,
    selectedVersionId = App.selectedVersionId,
    opts = App.opts,
    drawableWidth = App.drawableWidth,
    drawableHeight = App.drawableHeight,
    pixelRatio = App.pixelRatio,
    loadingNew = HgssLoadingPresentation.new,
    menuNew = MainMenuComposition.new,
    isCurrent = FirstPlayCompletion.isCurrent,
    hasStored = FirstPlayCompletion.hasStored,
    releaseGenerationId = FirstPlayCompletion.releaseGenerationId,
    graphicsDimensions = love.graphics.getDimensions,
    graphicsDpi = love.graphics.getDPIScale,
    graphicsSetColor = love.graphics.setColor,
    graphicsRectangle = love.graphics.rectangle,
    romIsReady = require("romdump.src.source.RomImporter").isReady,
    titleSceneNew = titleSceneModule.new,
    movieNew = movieModule.new,
    loadOpeningScene = StartupAssetCache.loadOpeningScene,
    firstPlayFactory = HgssGame.newFirstPlayCachePreparation,
    startupAudioFactory = HgssGame.newStartupAudio,
    startupAudioNew = StartupAudioSession.new,
    gameFactory = HgssGame.new,
    recordPlayed = require("app.src.launcher.EditionPreference").recordPlayed,
  }

  active = {
    requests = {},
    scenes = {},
    menus = {},
    epochs = {},
    drawEvents = {},
    graphicsEvents = {},
    audioSessions = {},
  }
  local nextEpoch = 0
  local service = {}
  function service:select(_)
    nextEpoch = nextEpoch + 1
    active.epochs[#active.epochs + 1] = nextEpoch
    return nextEpoch
  end
  function service:request(epoch, selector)
    active.requests[#active.requests + 1] = { epoch = epoch, selector = selector }
  end
  function service:observe(epoch, selector)
    -- The boot wait demands the selected walking pair as a required
    -- interest before it transfers: model the healthy worker answer so the
    -- startup journey under test starts from its transferred loader.
    if selector.requestKind == "startup-walker" then
      return true, nil
    end
    -- The cinematic scenes are ready by default behind these title-first
    -- compositions: the instant movie below hands off to the legendary
    -- title within the same selection updates, preserving every title,
    -- menu, and audio ownership assertion.
    if selector.requestKind == "opening-scene" then
      return true, nil
    end
    if selector.requestKind ~= "milestone" then
      return nil, nil
    end
    if selector.name == "startup-title" then
      return active.titleAssetsReady ~= false, nil
    end
    if selector.name == "startup-loader" then
      return true, nil
    end
    if selector.name == "bootstrap" then
      return active.bootstrapReady == true, nil
    end
    return false, nil
  end
  function service:requestBootSource(_) end
  function service:bootSourceStatus(_)
    return "ready", nil
  end
  function service:update() end
  function service:retire(epoch)
    active.retired = active.retired or {}
    active.retired[#active.retired + 1] = epoch
  end
  function service:enableSweep(_)
    active.sweeps = (active.sweeps or 0) + 1
  end
  function service:generationId(_)
    return "startup-test-generation"
  end
  function service:shutdown() end
  function service:quiesce(_)
    return nil
  end

  App.state = nil
  App.importer = nil
  App.provisioner = nil
  App.service = service
  App.epoch = 0
  -- The harness stands in for the selection flow's chosen walking pair (the
  -- selection flow owns the production assignment): the game handoff forwards it.
  App.pairIndex = 1
  App.pendingQuiesce = nil
  App.selectedVersionId = nil
  App.opts = { dev = false }
  App.drawableWidth, App.drawableHeight, App.pixelRatio = 800, 600, 1
  StartupAudioSession.new = function()
    return {
      bindTitleRecord = function(self, record)
        assert(type(record) == "table" and type(record.crySpeciesId) == "number")
        if self.titleRecord ~= nil then
          assert(self.titleRecord.crySpeciesId == record.crySpeciesId)
          return
        end
        self.titleRecord = { crySpeciesId = record.crySpeciesId }
      end,
      beginTitle = function() end,
      notifySkip = function() end,
      beginFade = function() end,
      playMenuCue = function() end,
      update = function() end,
      dispose = function() end,
    }
  end
  HgssLoadingPresentation.new = newLoadingPresentation
  movieModule.new = function(options)
    assert(type(options.scenes) == "table" and #options.scenes == 5)
    local movie = { draws = 0, disposed = 0 }
    function movie:updateFixed() end
    function movie:draw()
      self.draws = self.draws + 1
      active.drawEvents[#active.drawEvents + 1] = "movie"
    end
    function movie:resize() end
    function movie:skipAllowed()
      return false
    end
    function movie:requestSkip()
      return false
    end
    function movie:isFinished()
      return true
    end
    function movie:sceneNumber()
      return 1
    end
    function movie:dispose()
      self.disposed = self.disposed + 1
    end
    return movie
  end
  StartupAssetCache.loadOpeningScene = function(_, sceneNumber, versionId)
    return { sceneNumber = sceneNumber, versionId = versionId, generationId = "startup-test-generation" }
  end
  titleSceneModule.new = function(options)
    local scene = {
      versionId = options.versionId,
      bundle = { crySpeciesId = 25 },
      ticks = 0,
      draws = 0,
      disposed = 0,
      proceeds = 0,
    }
    function scene:beginProceed()
      self.proceeds = self.proceeds + 1
    end
    function scene:updateFixed()
      self.ticks = self.ticks + 1
    end
    function scene:update()
      self.ticks = self.ticks + 1
    end
    function scene:draw()
      if active.failTitleDraw then
        error("synthetic title renderer draw failure")
      end
      self.draws = self.draws + 1
      active.drawEvents[#active.drawEvents + 1] = "title"
    end
    function scene:resize(width, height)
      self.resizes = self.resizes or {}
      self.resizes[#self.resizes + 1] = { width, height }
    end
    function scene:dispose()
      self.disposed = self.disposed + 1
    end
    active.scenes[#active.scenes + 1] = scene
    return scene
  end
  MainMenuComposition.new = fakeMenu
  FirstPlayCompletion.isCurrent = function()
    return false
  end
  FirstPlayCompletion.hasStored = function()
    return false
  end
  FirstPlayCompletion.releaseGenerationId = function()
    return "startup-test-generation"
  end
  love.graphics.getDimensions = function()
    return 800, 600
  end
  love.graphics.getDPIScale = function()
    return 1
  end
  love.graphics.setColor = function(r, g, b, a)
    active.color = { r, g, b, a }
  end
  love.graphics.rectangle = function(mode, x, y, width, height)
    local color = active.color
    if color ~= nil and color[1] == 1 and color[2] == 1 and color[3] == 1 and (color[4] or 1) > 0 then
      active.whiteOverlayDrawn = true
    end
    active.graphicsEvents[#active.graphicsEvents + 1] = {
      kind = "rectangle",
      mode = mode,
      color = color,
      x = x,
      y = y,
      width = width,
      height = height,
    }
  end

  local ok, err = xpcall(fn, debug.traceback)
  if App.state ~= nil then
    App.setState(nil)
  end
  if App.provisioner ~= nil then
    App._retireSelection()
  end
  active = nil

  App.state = saved.state
  App.importer = saved.importer
  App.provisioner = saved.provisioner
  App.service = saved.service
  App.epoch = saved.epoch
  App.pairIndex = saved.pairIndex
  App.pendingQuiesce = saved.pendingQuiesce
  App.selectedVersionId = saved.selectedVersionId
  App.opts = saved.opts
  App.drawableWidth = saved.drawableWidth
  App.drawableHeight = saved.drawableHeight
  App.pixelRatio = saved.pixelRatio
  HgssLoadingPresentation.new = saved.loadingNew
  MainMenuComposition.new = saved.menuNew
  FirstPlayCompletion.isCurrent = saved.isCurrent
  FirstPlayCompletion.hasStored = saved.hasStored
  FirstPlayCompletion.releaseGenerationId = saved.releaseGenerationId
  love.graphics.getDimensions = saved.graphicsDimensions
  love.graphics.getDPIScale = saved.graphicsDpi
  love.graphics.setColor = saved.graphicsSetColor
  love.graphics.rectangle = saved.graphicsRectangle
  require("romdump.src.source.RomImporter").isReady = saved.romIsReady
  titleSceneModule.new = saved.titleSceneNew
  movieModule.new = saved.movieNew
  StartupAssetCache.loadOpeningScene = saved.loadOpeningScene
  HgssGame.newFirstPlayCachePreparation = saved.firstPlayFactory
  HgssGame.newStartupAudio = saved.startupAudioFactory
  StartupAudioSession.new = saved.startupAudioNew
  HgssGame.new = saved.gameFactory
  require("app.src.launcher.EditionPreference").recordPlayed = saved.recordPlayed
  if not ok then
    error(err, 0)
  end
end

local function startTitle(versionId)
  App._selectVersion(versionId or "heartgold")
  App.update(1 / 60)
  App.update(1 / 30)
  return App.state
end

local function isStartupTitle(state)
  return state ~= nil and state.phase == "title" and state.title ~= nil
end

function T.tests.title_is_presented_while_menu_and_first_play_are_pending()
  withStartup(function()
    local state = startTitle()

    Assert.isTrue(
      isStartupTitle(state),
      "the selected App epoch must present its ready title while bootstrap and first-play remain pending"
    )
    Assert.equal(#active.scenes, 1, "the selected edition constructs one title scene")
    Assert.equal(active.scenes[1].versionId, "heartgold")
    Assert.equal(#active.menus, 0, "pending bootstrap has not constructed a menu")
    Assert.isTrue(active.scenes[1].ticks > 0, "the active title advances while menu readiness is pending")
    local startupRequests = {}
    for _, request in ipairs(active.requests) do
      local selector = request.selector
      if selector.requestKind == "milestone" then
        startupRequests[#startupRequests + 1] = selector.name
      end
      Assert.isFalse(
        selector.name == "new-game-intro" and selector.urgency == "required",
        "first-play work cannot become a required menu gate"
      )
    end
    Assert.deepEqual(
      { startupRequests[1], startupRequests[2], startupRequests[3], startupRequests[4] },
      { "startup-loader", "startup-title", "bootstrap", "startup-audio" },
      "the first startup demand batch prioritizes title before broad bootstrap"
    )
  end)
end

function T.tests.early_skip_waits_on_the_title_then_transfers_the_staged_menu_once()
  withStartup(function()
    local state = startTitle()
    Assert.isTrue(isStartupTitle(state), "the production App path reaches the title before input")

    App.keypressed("return", "return", false)
    Assert.isTrue(state.skipRequested, "the title press latches skip intent immediately")
    for _ = 1, 150 do
      App.update(1 / 30)
    end
    Assert.equal(App.state, state, "pending menu readiness keeps the title installed")
    Assert.isTrue(active.scenes[1].ticks >= 150, "the title keeps animating while skip is pending")
    Assert.equal(#active.menus, 0, "a pending bootstrap has no staged menu to receive input")

    active.bootstrapReady = true
    App.update(1 / 30)
    Assert.equal(#active.menus, 1, "bootstrap constructs the real menu owner through App's composition seam")
    local stagedMenu = active.menus[1]
    Assert.equal(state.stagedMenu, stagedMenu, "the title owns the menu instance it will transfer")
    Assert.isTrue(state.phase == "fadeOut" or state.phase == "fadeIn", "latched intent starts the fade automatically")
    Assert.equal(stagedMenu.inputs, 0, "the title press never reaches the staged menu")

    for _ = 1, 100 do
      if App.state == stagedMenu then
        break
      end
      App.update(1 / 30)
    end
    Assert.equal(App.state, stagedMenu, "the exact staged menu becomes App's active state")
    Assert.equal(#active.menus, 1, "handoff does not reconstruct the menu")
    Assert.equal(stagedMenu.disposed, 0, "transferred ownership leaves the menu alive")
    Assert.equal(active.scenes[1].disposed, 1, "the title scene is released at handoff")
    Assert.equal(stagedMenu.inputs, 0, "no title input is replayed after transfer")
  end)
end

function T.tests.menu_readiness_does_not_skip_a_title_without_user_intent()
  withStartup(function()
    local state = startTitle()
    Assert.isTrue(isStartupTitle(state), "the production App path presents the title")
    active.bootstrapReady = true
    App.update(1 / 30)
    for _ = 1, 150 do
      App.update(1 / 30)
    end

    Assert.equal(App.state, state, "a ready menu does not bypass the unpressed title")
    Assert.isFalse(state.skipRequested, "menu readiness does not synthesize user intent")
    Assert.equal(#active.menus, 1, "the usable menu remains staged once")
  end)
end

function T.tests.retired_title_epoch_cannot_replace_the_new_edition()
  withStartup(function()
    local oldState = startTitle()
    Assert.isTrue(isStartupTitle(oldState), "the first selected edition reaches its title")
    local oldEpoch = App.epoch

    App._selectVersion("soulsilver")
    Assert.equal(active.scenes[1].disposed, 1, "switching retires the previous title scene")
    Assert.equal(App.selectedVersionId, "soulsilver")
    Assert.isTrue(App.epoch > oldEpoch, "edition switch owns a new selection epoch")

    active.bootstrapReady = false
    App.update(1 / 60)
    App.update(1 / 30)
    Assert.isTrue(
      App.state == nil or App.state.versionId == "soulsilver" or App.state.phase == "title",
      "the retired HeartGold completion cannot replace the SoulSilver selection"
    )
    Assert.equal(active.scenes[#active.scenes].versionId, "soulsilver")
    Assert.equal(#active.menus, 0, "no late old-epoch result stages a menu into the new edition")
  end)
end

function T.tests.menu_is_staged_before_first_play_without_claiming_entry_readiness()
  withStartup(function()
    local state = startTitle()
    Assert.isTrue(isStartupTitle(state), "the source-admitted selection reaches the title before field closure")
    active.bootstrapReady = true
    App.update(1 / 30)

    Assert.equal(#active.menus, 1, "bootstrap readiness stages the actual menu while field milestones remain pending")
    Assert.isFalse(
      FirstPlayCompletion.isCurrent("heartgold", "startup-test-generation"),
      "menu readiness does not attest first-play completion"
    )
    for _, request in ipairs(active.requests) do
      local selector = request.selector
      Assert.isFalse(
        selector.name == "new-game-intro" and selector.urgency == "required",
        "menu admission does not turn New Game's intro into a required startup gate"
      )
    end
    Assert.equal(App.state, state, "staging a menu does not replace the still-unskipped title")
  end)
end

function T.tests.white_handoff_draws_owned_frames_and_consumes_the_title_pointer_release()
  withStartup(function()
    local state = startTitle()
    Assert.isTrue(isStartupTitle(state), "the production App path presents a title before drawing")
    active.bootstrapReady = true
    App.update(1 / 30)
    local menu = assert(state.stagedMenu, "the exact menu is staged under title ownership")

    App.mousepressed(400, 300, 1, false, 1)
    for _ = 1, 80 do
      active.drawEvents = {}
      active.graphicsEvents = {}
      App.draw()
      Assert.isTrue(
        #active.drawEvents > 0,
        "each transition frame draws the title or the staged menu behind its white veil"
      )
      App.update(1 / 30)
    end

    Assert.equal(App.state, menu, "the white transition transfers the same staged menu")
    Assert.isTrue(active.whiteOverlayDrawn, "the title-to-menu handoff draws a white veil")
    Assert.equal(#active.menus, 1, "handoff never reconstructs the staged menu")
    Assert.equal(active.scenes[1].disposed, 1, "the title owner releases its scene once after transfer")
    App.mousereleased(790, 590, 1, false, 1)
    Assert.equal(menu.releases or 0, 0, "a pointer release captured by the title cannot click through")
    App.keypressed("n", "n", false)
    Assert.equal(menu.inputs, 1, "new input after transfer reaches the active menu")
  end)
end

function T.tests.edition_switch_uses_the_opposite_safe_corner_and_missing_version_import_route()
  withStartup(function()
    local RomImporter = require("romdump.src.source.RomImporter")
    RomImporter.isReady = function(_)
      return true
    end
    local hgTitle = startTitle("heartgold")
    Assert.isTrue(isStartupTitle(hgTitle), "HeartGold starts in its selected epoch")
    App.mousepressed(790, 590, 1, false, 1)
    Assert.equal(App.selectedVersionId, "soulsilver", "HeartGold's lower-right control selects SoulSilver")
    Assert.isTrue(App.epoch > 1, "an installed alternate edition starts a fresh source-gated epoch")
    Assert.isFalse(hgTitle.skipRequested, "edition preview does not become a title skip")
  end)

  withStartup(function()
    local RomImporter = require("romdump.src.source.RomImporter")
    RomImporter.isReady = function()
      return true
    end
    local ssTitle = startTitle("soulsilver")
    Assert.isTrue(isStartupTitle(ssTitle), "SoulSilver starts in its selected epoch")
    App.resize(256, 192)
    App.resize(1200, 600)
    App.resize(600, 1000)
    App.resize(512, 384)
    Assert.equal(#active.scenes[1].resizes, 4, "physical, wide, tall and 4:3 resizes reach the current title scene")
    App.mousepressed(10, 590, 1, false, 1)
    Assert.equal(App.selectedVersionId, "heartgold", "SoulSilver's lower-left control selects HeartGold")
    Assert.isTrue(App.epoch > 1, "the installed HeartGold edition passes through source admission")
  end)

  withStartup(function()
    local RomImporter = require("romdump.src.source.RomImporter")
    RomImporter.isReady = function(versionId)
      return versionId == "heartgold"
    end
    local state = startTitle("heartgold")
    Assert.isTrue(isStartupTitle(state), "the current edition title remains active")
    App.mousepressed(790, 590, 1, false, 1)
    Assert.equal(App.selectedVersionId, "heartgold", "an unavailable alternate does not become the selected game")
    Assert.equal(App.state.targetVersion, "soulsilver", "the unavailable edition opens targeted import")
    Assert.isFalse(state.skipRequested, "the edition control is not also a title skip")
  end)
end

function T.tests.title_and_staged_menu_dispose_once_when_the_selection_quits()
  withStartup(function()
    local state = startTitle()
    Assert.isTrue(isStartupTitle(state), "the selected App path owns a title scene before quit")
    active.bootstrapReady = true
    App.update(1 / 30)
    local menu = assert(state.stagedMenu, "the menu remains staged under the title")

    App.quit()
    Assert.equal(active.scenes[1].disposed, 1, "quit disposes the title scene once")
    Assert.equal(menu.disposed, 1, "quit disposes the untransferred staged menu once")
    Assert.isTrue(active.retired ~= nil and #active.retired == 1, "quit retires the selected cache epoch")
  end)
end

function T.tests.menu_construction_failure_keeps_title_and_skip_owned_by_current_epoch()
  withStartup(function()
    local state = startTitle()
    Assert.isTrue(isStartupTitle(state), "the current epoch owns the title before menu construction")
    App.keypressed("return", "return", false)
    active.failMenuConstruction = true
    active.bootstrapReady = true
    App.update(1 / 30)

    Assert.equal(App.state, state, "a failed menu constructor cannot replace the active title")
    Assert.isTrue(state.skipRequested, "menu failure preserves the user's pending skip intent")
    Assert.equal(#active.menus, 0, "a partial failed menu is never exposed as ready")
    for _ = 1, 5 do
      App.update(1 / 30)
    end
    Assert.equal(active.menuAttempts, 1, "a transient construction error does not create an automatic retry loop")

    App.keypressed("r", "r", false)
    Assert.equal(active.menuAttempts, 2, "R deliberately retries staged menu construction")
    local menu = assert(state.stagedMenu, "a successful retry stages the real menu under the title")
    Assert.isTrue(state.phase == "fadeOut" or state.phase == "fadeIn", "the preserved skip begins handoff after retry")
    for _ = 1, 80 do
      if App.state == menu then
        break
      end
      App.update(1 / 30)
    end
    Assert.equal(App.state, menu, "the retried staged menu receives the existing skip intent")
    Assert.equal(active.menuAttempts, 2, "retry transfers the same menu without reconstructing it")

    App.quit()
    Assert.equal(menu.disposed, 1, "quit disposes the transferred menu once")
    Assert.equal(active.scenes[1].disposed, 1, "quitting after a constructor failure disposes title resources once")
    Assert.isTrue(active.retired ~= nil and #active.retired == 1, "failure cleanup retires only the selected epoch")
  end)
end

function T.tests.title_draw_failure_shows_diagnostic_and_keeps_escape_recovery()
  withStartup(function()
    local state = startTitle()
    active.failTitleDraw = true
    local ok, failure = pcall(App.draw)

    Assert.isTrue(ok, "renderer failure is contained at the title boundary: " .. tostring(failure))
    Assert.equal(App.state, state, "a draw failure does not replace the selected title state")
    Assert.equal(state.phase, "error", "the title enters its explicit recoverable error phase")
    Assert.isTrue(
      tostring(state.titleError):match("synthetic title renderer draw failure") ~= nil,
      "the draw failure is preserved for the diagnostic surface"
    )
    App.keypressed("escape", "escape", false)
    Assert.isTrue(App.state ~= state, "Escape can leave the failed title without a renderer retry")
    Assert.equal(active.scenes[1].disposed, 1, "leaving releases the failed renderer once")
  end)
end

function T.tests.title_owned_prewarm_uses_near_priority_and_disposes_with_selection()
  withStartup(function()
    local preparation = { disposed = 0, polls = 0 }
    function preparation:poll()
      self.polls = self.polls + 1
      return false, nil
    end
    function preparation:dispose()
      self.disposed = self.disposed + 1
    end
    HgssGame.newFirstPlayCachePreparation = function(options)
      Assert.equal(options.urgency, "near", "optional startup warmup cannot outrank title work")
      return preparation
    end

    startTitle()
    App.update(1 / 30)
    Assert.equal(preparation.polls, 1, "title availability starts the optional first-play poll")
    Assert.equal(preparation.disposed, 0, "pending first-play work remains owned by the selected epoch")
    App.quit()
    Assert.equal(
      preparation.disposed,
      1,
      "retiring the selected epoch disposes its pending first-play preparation once"
    )
  end)
end

function T.tests.title_audio_events_use_the_bounded_borrowed_callbacks()
  withStartup(function()
    local baseObserve = App.service.observe
    App.service.observe = function(self, epoch, selector)
      if selector.requestKind == "milestone" and selector.name == "startup-audio" then
        return active.audioReady == true, nil
      end
      return baseObserve(self, epoch, selector)
    end
    local events = { titleReady = 0, prompt = 0, skip = 0 }
    StartupAudioSession.new = function()
      return {
        bindTitleRecord = function(self, record)
          assert(type(record) == "table" and type(record.crySpeciesId) == "number")
          if self.titleRecord ~= nil then
            assert(self.titleRecord.crySpeciesId == record.crySpeciesId)
            return
          end
          self.titleRecord = { crySpeciesId = record.crySpeciesId }
        end,
        beginTitle = function()
          events.titleReady = events.titleReady + 1
        end,
        notifySkip = function()
          events.prompt = events.prompt + 1
        end,
        beginFade = function()
          events.skip = events.skip + 1
        end,
        update = function() end,
        dispose = function() end,
      }
    end

    local state = startTitle()
    Assert.equal(events.titleReady, 0, "pending optional audio emits no title event behind the visible title")
    active.audioReady = true
    App.update(1 / 30)
    Assert.equal(events.titleReady, 1, "audio readiness emits one bounded audio event")
    App.keypressed("return", "return", false)
    Assert.equal(events.prompt, 1, "the first title press emits the prompt/cry event")
    Assert.equal(events.skip, 0, "the transition cue waits for actual menu readiness")
    active.bootstrapReady = true
    App.update(1 / 30)
    Assert.equal(events.skip, 1, "the skip fade emits one cue only after staging")
    App.keypressed("return", "return", false)
    Assert.equal(events.titleReady, 1, "later input never replays title startup audio")
    Assert.equal(events.prompt, 1, "repeat skip intent never replays the prompt event")
    Assert.equal(events.skip, 1, "the fade-start event is emitted once")
    Assert.isTrue(state.phase == "fadeOut" or state.phase == "fadeIn", "stub audio does not control title readiness")
  end)
end

function T.tests.startup_audio_has_one_app_owner_through_title_menu_game_return_and_quit()
  withStartup(function()
    local function newSession(options)
      Assert.isTrue(
        options.versionId == "heartgold" or options.versionId == "soulsilver",
        "the session is bound to the selected edition"
      )
      local session = { versionId = options.versionId, events = {}, updates = 0, disposals = 0 }
      function session:bindTitleRecord(record)
        assert(type(record) == "table" and type(record.crySpeciesId) == "number")
        if self.titleRecord ~= nil then
          assert(self.titleRecord.crySpeciesId == record.crySpeciesId)
          return
        end
        self.titleRecord = { crySpeciesId = record.crySpeciesId }
      end
      function session:beginTitle()
        self.events[#self.events + 1] = "title"
      end
      function session:notifySkip()
        self.events[#self.events + 1] = "cry"
      end
      function session:beginFade()
        self.events[#self.events + 1] = "fade"
      end
      function session:playMenuCue()
        self.events[#self.events + 1] = "menu"
      end
      function session:update()
        self.updates = self.updates + 1
      end
      function session:dispose()
        self.disposals = self.disposals + 1
      end
      active.audioSessions[#active.audioSessions + 1] = session
      return session
    end
    StartupAudioSession.new = newSession

    local baseObserve = App.service.observe
    App.service.observe = function(self, epoch, selector)
      if selector.requestKind == "milestone" and selector.name == "startup-audio" then
        return active.audioReady == true, nil
      end
      return baseObserve(self, epoch, selector)
    end
    active.titleAssetsReady = false
    local title = startTitle()
    Assert.equal(#active.audioSessions, 0, "pending startup-title audio assets cannot construct a session")
    active.titleAssetsReady = true
    App.update(1 / 30)
    Assert.isTrue(isStartupTitle(title), "the selected title remains the active App state")
    Assert.equal(#active.audioSessions, 0, "visual readiness alone cannot construct a session")
    active.audioReady = true
    App.update(1 / 30)
    Assert.equal(#active.audioSessions, 1, "audio readiness creates one app-owned audio session")
    local session = active.audioSessions[1]
    Assert.deepEqual(session.events, { "title" }, "the title theme starts once after title readiness")
    local menuUpdateCount = session.updates
    App.update(1 / 60)
    Assert.equal(session.updates, menuUpdateCount + 1, "each App host update pumps the one session once")

    App.keypressed("return", "return", false)
    Assert.deepEqual(session.events, { "title", "cry" }, "the first valid skip requests one legendary cry")
    for _ = 1, 75 do
      App.update(1 / 30)
    end
    Assert.deepEqual(
      session.events,
      { "title", "cry" },
      "the title remains audible and unfaded while the menu is still pending"
    )

    active.bootstrapReady = true
    App.update(1 / 30)
    local stagedMenu = assert(title.stagedMenu)
    local menuAudio = assert(stagedMenu.options.audio, "the staged menu receives a borrowed cue callback")
    Assert.isTrue(type(menuAudio.playMenuCue) == "function", "the staged menu has only its semantic cue operation")
    Assert.deepEqual(session.events, { "title", "cry", "fade" }, "staging alone emits no menu audio")
    for _ = 1, 80 do
      if App.state == stagedMenu then
        break
      end
      App.update(1 / 30)
    end
    Assert.equal(App.state, stagedMenu, "the same staged menu receives the title handoff")
    Assert.equal(#active.audioSessions, 1, "the title/menu handoff does not construct another sink")
    Assert.equal(session.disposals, 0, "the transferred menu retains its borrowed session")
    menuAudio.playMenuCue()
    Assert.deepEqual(
      session.events,
      { "title", "cry", "fade", "menu" },
      "the active menu routes its semantic cue through the original session"
    )

    local gameOptions
    HgssGame.new = function(options)
      gameOptions = options
      Assert.equal(session.disposals, 1, "startup output closes before the retail game takes ownership")
      return {
        dispose = function() end,
      }
    end
    require("app.src.launcher.EditionPreference").recordPlayed = function()
      return true
    end
    App._launchGameWithProvisioner("heartgold", { kind = "new_game" })
    Assert.equal(session.disposals, 1, "entering the game releases the startup session exactly once")
    assert(gameOptions, "the production game handoff is composed")
    gameOptions.onExit({ kind = "main_menu" })
    Assert.equal(#active.audioSessions, 2, "returning to the menu creates an effects-capable session")
    Assert.deepEqual(active.audioSessions[2].events, {}, "returning from gameplay does not replay title music or cry")

    App._selectVersion("soulsilver")
    Assert.equal(active.audioSessions[2].disposals, 1, "edition selection releases the previous menu session once")
    App.update(1 / 30)
    App.update(1 / 30)
    Assert.equal(
      #active.audioSessions,
      3,
      "the new selected edition obtains one audio session after its title is ready"
    )
    Assert.equal(active.audioSessions[3].versionId, "soulsilver")
    App.quit()
    Assert.equal(active.audioSessions[3].disposals, 1, "quit releases the current edition session once")
  end)
end

function T.tests.post_install_warmup_failure_keeps_the_single_installed_menu()
  withStartup(function()
    local state = startTitle()
    Assert.isTrue(isStartupTitle(state), "the selected title is active before the skip")
    local provisioner = assert(App.provisioner, "the selection owns its provisioner through handoff")
    local epoch = App.epoch
    provisioner.startBackgroundWarmup = function(_)
      error("synthetic post-install warmup failure")
    end

    App.keypressed("return", "return", false)
    Assert.isTrue(state.skipRequested, "the press latches skip intent before menu readiness")
    for _ = 1, 30 do
      App.update(1 / 30)
    end
    Assert.equal(App.state, state, "pending menu readiness keeps the title installed")

    active.bootstrapReady = true
    for _ = 1, 120 do
      App.update(1 / 30)
      if App.state ~= state then
        break
      end
    end
    local menu = App.state
    Assert.equal(#active.menus, 1, "the failed warmup never reconstructs the menu")
    Assert.equal(menu, active.menus[1], "exactly the staged menu installs despite the post-install failure")
    Assert.equal(menu.disposed, 0, "the installed menu stays alive")
    Assert.equal(active.scenes[1].disposed, 1, "the title scene releases once at handoff")
    Assert.equal(state.phase, "transferred", "a committed handoff never returns to the title phase")
    Assert.isNil(state.stagedMenu, "the committed title holds no menu to resurrect")
    Assert.equal(App.epoch, epoch, "the selected epoch survives the optional failure")
    Assert.isTrue(App.provisioner == provisioner, "the selected provisioner survives the optional failure")
    Assert.equal(#active.epochs, 1, "no replacement selection is minted by the failure")
    for _ = 1, 30 do
      App.update(1 / 30)
    end
    Assert.equal(App.state, menu, "later updates keep the single installed menu")
  end)
end

function T.tests.title_and_menu_proceed_while_optional_audio_is_pending()
  local function observeAudio(service, baseObserve)
    service.observe = function(self, epoch, selector)
      if selector.requestKind == "milestone" and selector.name == "startup-audio" then
        if active.audioFailed then
          return false, "synthetic audio bank failure"
        end
        if active.audioReady then
          return true, nil
        end
        return false, nil
      end
      return baseObserve(self, epoch, selector)
    end
  end
  local function countingAudio(sessions)
    StartupAudioSession.new = function()
      local session = { cues = {} }
      function session:bindTitleRecord(record)
        assert(type(record) == "table" and type(record.crySpeciesId) == "number")
        if self.titleRecord ~= nil then
          assert(self.titleRecord.crySpeciesId == record.crySpeciesId)
          return
        end
        self.titleRecord = { crySpeciesId = record.crySpeciesId }
      end
      function session:beginTitle()
        self.cues[#self.cues + 1] = "title"
      end
      function session:notifySkip()
        self.cues[#self.cues + 1] = "cry"
      end
      function session:beginFade()
        self.cues[#self.cues + 1] = "fade"
      end
      function session:playMenuCue()
        self.cues[#self.cues + 1] = "menu"
      end
      function session:update() end
      function session:dispose() end
      sessions[#sessions + 1] = session
      return session
    end
  end

  withStartup(function()
    observeAudio(App.service, App.service.observe)
    local sessions = {}
    countingAudio(sessions)
    local state = startTitle()
    Assert.isTrue(isStartupTitle(state), "the visual title presents while audio is still pending")
    Assert.equal(#sessions, 0, "pending optional audio constructs no session behind the visible title")
    local sawAudio, audioUrgency = false, nil
    for _, request in ipairs(active.requests) do
      local selector = request.selector
      if selector.requestKind == "milestone" and selector.name == "startup-audio" then
        sawAudio = true
        audioUrgency = selector.urgency
      end
    end
    Assert.isTrue(sawAudio, "the selected title demands its optional audio milestone independently")
    Assert.equal(audioUrgency, "near", "optional audio never outranks visual work")

    active.audioReady = true
    App.update(1 / 30)
    App.update(1 / 30)
    Assert.equal(#sessions, 1, "audio readiness starts one session while the title is still visible")
    Assert.deepEqual(sessions[1].cues, { "title" }, "ready-before-skip starts the title theme once")
    Assert.isTrue(isStartupTitle(App.state), "audio readiness does not dismiss the unpressed title")
    Assert.isFalse(state.skipRequested, "audio readiness synthesizes no skip intent")

    App.keypressed("return", "return", false)
    Assert.deepEqual(sessions[1].cues, { "title", "cry" }, "the first skip requests one cry")
    for _ = 1, 30 do
      App.update(1 / 30)
    end
    Assert.equal(App.state, state, "the title waits for the pending menu after the skip")

    active.bootstrapReady = true
    for _ = 1, 120 do
      App.update(1 / 30)
      if App.state ~= state then
        break
      end
    end
    Assert.equal(App.state, active.menus[1], "the staged menu installs after the fade")
    Assert.equal(#sessions, 1, "handoff constructs no second session")
    Assert.deepEqual(sessions[1].cues, { "title", "cry", "fade" }, "the skip fade emits one cue only")
  end)

  withStartup(function()
    observeAudio(App.service, App.service.observe)
    local sessions = {}
    local lateCues = {}
    StartupAudioSession.new = function()
      local session = {}
      function session:bindTitleRecord(record)
        assert(type(record) == "table" and type(record.crySpeciesId) == "number")
        if self.titleRecord ~= nil then
          assert(self.titleRecord.crySpeciesId == record.crySpeciesId)
          return
        end
        self.titleRecord = { crySpeciesId = record.crySpeciesId }
      end
      function session:beginTitle()
        lateCues[#lateCues + 1] = "title"
      end
      function session:notifySkip()
        lateCues[#lateCues + 1] = "cry"
      end
      function session:beginFade()
        lateCues[#lateCues + 1] = "fade"
      end
      function session:playMenuCue()
        lateCues[#lateCues + 1] = "menu"
      end
      function session:update() end
      function session:dispose() end
      sessions[#sessions + 1] = session
      return session
    end
    active.bootstrapReady = true
    local state = startTitle()
    Assert.isTrue(isStartupTitle(state), "the visual title presents while audio is still pending")
    Assert.equal(#sessions, 0, "pending optional audio constructs no session behind the visible title")
    App.keypressed("return", "return", false)
    for _ = 1, 10 do
      App.update(1 / 30)
    end
    Assert.isTrue(state.phase == "fadeOut" or state.phase == "fadeIn", "latched skip starts the fade")
    active.audioReady = true
    for _ = 1, 120 do
      App.update(1 / 30)
      if App.state ~= state then
        break
      end
    end
    Assert.equal(App.state, active.menus[1], "the menu installs even though audio arrived mid-fade")
    for _, cue in ipairs(lateCues) do
      Assert.isFalse(cue == "title", "audio that arrives after the skip never starts a belated title theme")
      Assert.isFalse(cue == "cry", "audio that arrives after the skip never plays a belated cry")
    end
    Assert.equal(#active.menus, 1, "the late audio never reconstructs the menu")
  end)
end

function T.tests.pending_skip_transfers_once_and_the_retry_key_stays_useful()
  withStartup(function()
    local state = startTitle()
    Assert.isTrue(isStartupTitle(state), "the title is active before the skip")
    App.keypressed("return", "return", false)
    Assert.isTrue(state.skipRequested, "the first press latches skip intent")
    for _ = 1, 30 do
      App.update(1 / 30)
    end
    Assert.equal(App.state, state, "the title keeps animating while the menu is pending")
    Assert.equal(#active.menus, 0, "no menu stages before bootstrap readiness")
    active.bootstrapReady = true
    App.update(1 / 30)
    Assert.equal(#active.menus, 1, "bootstrap readiness stages the menu once")
    Assert.isTrue(
      state.phase == "fadeOut" or state.phase == "fadeIn",
      "latched intent starts the fade without another press"
    )
    for _ = 1, 80 do
      if App.state ~= state then
        break
      end
      App.update(1 / 30)
    end
    Assert.equal(App.state, active.menus[1], "the exact staged menu installs after the fade")
    Assert.equal(#active.menus, 1, "handoff never reconstructs the menu")
  end)

  withStartup(function()
    local state = startTitle()
    Assert.isTrue(isStartupTitle(state), "the title owns the pending menu construction")
    App.keypressed("return", "return", false)
    active.failMenuConstruction = true
    active.bootstrapReady = true
    App.update(1 / 30)
    Assert.equal(App.state, state, "a failed menu keeps the title installed")
    Assert.isTrue(state.skipRequested, "the failure preserves the pending skip")
    Assert.equal(active.menuAttempts, 1, "the failure consumes exactly one construction attempt")
    App.keypressed("r", "r", false)
    Assert.equal(active.menuAttempts, 2, "the retry key rebuilds the menu once")
    Assert.isTrue(
      state.phase == "fadeOut" or state.phase == "fadeIn",
      "the preserved skip starts the fade after the retry"
    )
    for _ = 1, 80 do
      if App.state ~= state then
        break
      end
      App.update(1 / 30)
    end
    Assert.equal(App.state, active.menus[1], "the retried menu receives the existing skip intent")
    Assert.equal(active.menuAttempts, 2, "retry transfers the same menu without reconstructing it")
  end)

  withStartup(function()
    local state = startTitle()
    Assert.isTrue(isStartupTitle(state), "the healthy title is active before the retry key")
    App.keypressed("r", "r", false)
    Assert.isTrue(state.skipRequested, "the retry key acts as ordinary skip intent when nothing needs retry")
  end)
end

function T.tests.title_skip_honors_the_full_input_family_with_exact_pointer_identity()
  withStartup(function()
    App._swallowedPointers = {}
    local state = startTitle()
    Assert.isTrue(isStartupTitle(state), "the title is active before secondary input")
    App.mousepressed(400, 300, 2, false, 1)
    App.mousepressed(400, 300, 3, false, 1)
    App.keypressed("lshift", "lshift", false)
    App.keypressed("lctrl", "lctrl", false)
    Assert.isFalse(state.skipRequested, "secondary buttons and modifier keys never request skip")
    Assert.equal(App.state, state, "ignored input keeps the title installed")
  end)

  withStartup(function()
    App._swallowedPointers = {}
    local state = startTitle()
    App.keypressed("a", "a", false)
    Assert.isTrue(state.skipRequested, "an ordinary key requests skip")
  end)

  withStartup(function()
    App._swallowedPointers = {}
    local state = startTitle()
    App.keypressed("left", "left", false)
    Assert.isTrue(state.skipRequested, "an arrow key requests skip")
  end)

  withStartup(function()
    App._swallowedPointers = {}
    local state = startTitle()
    App.gamepadpressed({}, "b")
    Assert.isTrue(state.skipRequested, "a discrete gamepad button requests skip")
  end)

  withStartup(function()
    App._swallowedPointers = {}
    local state = startTitle()
    App.gamepadpressed({}, "dpleft")
    Assert.isTrue(state.skipRequested, "a gamepad direction requests skip")
  end)

  withStartup(function()
    App._swallowedPointers = {}
    local state = startTitle()
    App.mousepressed(400, 300, 1, false, 1)
    Assert.isTrue(state.skipRequested, "the primary button requests skip")
  end)

  withStartup(function()
    App._swallowedPointers = {}
    local state = startTitle()
    state:touchpressed(9, 400, 300)
    Assert.equal(state.pointerCapture, "touch:9", "press captures the normalized touch identity")
    Assert.isTrue(state.skipRequested, "touch press inside the scene requests skip")
    state:touchreleased(9)
    Assert.isNil(state.pointerCapture, "release clears the capture under the same identity")
    Assert.deepEqual(state.canceledPointers, {}, "release clears the consumed pointer record")
  end)

  withStartup(function()
    App._swallowedPointers = {}
    local state = startTitle()
    App.touchpressed(11, 400, 300, 0, 0, 1)
    Assert.equal(state.pointerCapture, "touch:11", "the host press captures the normalized touch identity")
    App.touchreleased(11, 400, 300, 0, 0, 1)
    Assert.isNil(state.pointerCapture, "the active title clears its capture before the release is swallowed")
    Assert.deepEqual(state.canceledPointers, {}, "the active title clears its consumed record on release")
    Assert.deepEqual(App._swallowedPointers, {}, "the consumed release never reaches a later owner")
  end)

  withStartup(function()
    local RomImporter = require("romdump.src.source.RomImporter")
    RomImporter.isReady = function(_)
      return true
    end
    App._swallowedPointers = {}
    local state = startTitle("heartgold")
    Assert.isTrue(isStartupTitle(state), "the current edition title remains active")
    App.mousepressed(790, 590, 1, false, 1)
    Assert.equal(App.selectedVersionId, "soulsilver", "the corner control selects the alternate edition")
    Assert.isFalse(state.skipRequested, "the edition control is not also a title skip")
  end)

  withStartup(function()
    App._swallowedPointers = {}
    local state = startTitle()
    App.mousepressed(400, 300, 1, false, 1)
    Assert.equal(state.pointerCapture, "mouse:1", "press captures the normalized primary identity")
    App.focus(false)
    Assert.isNil(state.pointerCapture, "losing focus drops the pending capture")
    Assert.deepEqual(state.canceledPointers, {}, "losing focus drops consumed records")
    Assert.deepEqual(App._swallowedPointers, {}, "losing focus drops the host barrier")
  end)
end

function T.tests.failed_optional_audio_never_blocks_the_menu()
  withStartup(function()
    local baseObserve = App.service.observe
    App.service.observe = function(self, epoch, selector)
      if selector.requestKind == "milestone" and selector.name == "startup-audio" then
        return false, "synthetic audio bank failure"
      end
      return baseObserve(self, epoch, selector)
    end
    local sessions = 0
    StartupAudioSession.new = function()
      sessions = sessions + 1
      return {
        beginTitle = function() end,
        notifySkip = function() end,
        beginFade = function() end,
        playMenuCue = function() end,
        update = function() end,
        dispose = function() end,
      }
    end
    active.bootstrapReady = true
    local state = startTitle()
    Assert.isTrue(isStartupTitle(state), "the visual title presents while audio has failed")
    Assert.equal(sessions, 0, "failed optional audio constructs no session")
    App.keypressed("return", "return", false)
    for _ = 1, 120 do
      if App.state ~= state then
        break
      end
      App.update(1 / 30)
    end
    Assert.equal(App.state, active.menus[1], "the staged menu installs despite failed audio")
    Assert.equal(sessions, 0, "the failed audio never constructs a session")
    Assert.equal(#active.menus, 1, "the failure never reconstructs the menu")
  end)
end

function T.tests.throwing_transfer_callback_propagates_without_resurrecting_the_title()
  withStartup(function()
    local StartupTitleState = require("app.src.launcher.StartupTitleState")
    local host = {
      requestMilestone = function(name, _)
        return true, nil
      end,
      requestOpeningScene = function(_sceneNumber, _urgency)
        return true, nil
      end,
      milestoneStatus = function(_)
        return { state = "ready", ready = 1, total = 1, failure = nil }
      end,
    }
    local transfers = 0
    local menu = {
      draw = function() end,
      dispose = function() end,
    }
    local state = StartupTitleState.new({
      versionId = "heartgold",
      epoch = 7,
      derivedAssets = host,
      stageMenu = function()
        return menu
      end,
      onFinished = function(_)
        transfers = transfers + 1
        error("synthetic commit failure after install")
      end,
      onSwitchEdition = function() end,
      isCurrent = function()
        return true
      end,
      width = 800,
      height = 600,
    })
    for _ = 1, 5 do
      state:update(1 / 30)
    end
    Assert.equal(state.phase, "title", "visual readiness presents the title before input")
    state:keypressed("return", "return", false)
    Assert.isTrue(state.skipRequested, "the press latches skip intent")
    local failure = nil
    for _ = 1, 120 do
      local ok, err = pcall(state.update, state, 1 / 30)
      if not ok then
        failure = err
        break
      end
    end
    Assert.isTrue(failure ~= nil, "a true commit failure propagates to the caller")
    Assert.equal(transfers, 1, "the transfer callback runs exactly once")
    Assert.isTrue(state.transferred, "the transfer stays committed")
    Assert.equal(state.phase, "transferred", "a failed callback never returns the title phase")
    Assert.isNil(state.stagedMenu, "the committed title holds no menu to resurrect")
    state:update(1 / 30)
    Assert.equal(transfers, 1, "later updates never re-enter the transfer")
    state:dispose()
  end)
end

-- An already renderable opening movie starts on the next eligible update
-- without waiting out the loader beat on a warm entry, while a true first
-- import keeps its bounded beat until the staged movie is drawable.
function T.tests.renderable_warm_movie_starts_without_waiting_for_the_loader_beat()
  local StartupTitleState = require("app.src.launcher.StartupTitleState")
  local CacheFs = require("libs.storage.src.CacheFs")
  local MovieModule = require("libs.hgss.src.presentation.HgssOpeningMovie")
  local saved = {
    forVersion = CacheFs.forVersion,
    loadScenes = MovieModule.loadValidatedScenes,
    movieNew = MovieModule.new,
  }
  local function fakeLoading()
    local presentation = {}
    function presentation:update()
    end
    function presentation:resize()
    end
    function presentation:draw()
    end
    function presentation:dispose()
    end
    function presentation:adoptGeneratedAssets()
      return true
    end
    return presentation
  end
  local function fakeHost()
    local host = {}
    function host.requestMilestone(name, _)
      if name == "startup-loader" or name == "startup-title" or name == "startup-audio" then
        return true, nil
      end
      return false, nil
    end
    function host.requestOpeningScene(_, _)
      return true, nil
    end
    function host.milestoneStatus(_)
      return { state = "ready", ready = 1, total = 1, failure = nil }
    end
    return host
  end
  local function fakeMovie()
    local movie = { draws = 0 }
    function movie:updateFixed()
    end
    function movie:draw()
      self.draws = self.draws + 1
    end
    function movie:resize()
    end
    function movie:skipAllowed()
      return false
    end
    function movie:requestSkip()
      return false
    end
    function movie:isFinished()
      return false
    end
    function movie:sceneNumber()
      return 1
    end
    function movie:dispose()
    end
    return movie
  end
  local function build(initialImport)
    local staged = fakeMovie()
    CacheFs.forVersion = function(_)
      return {}
    end
    MovieModule.loadValidatedScenes = function()
      return { {}, {}, {}, {}, {} }
    end
    MovieModule.new = function(_)
      return staged
    end
    local state = StartupTitleState.new({
      versionId = "soulsilver",
      epoch = 7,
      derivedAssets = fakeHost(),
      stageMenu = function()
        error("the movie beat test never stages a menu")
      end,
      onFinished = function()
        error("the movie beat test never finishes")
      end,
      onSwitchEdition = function()
      end,
      isCurrent = function()
        return true
      end,
      width = 800,
      height = 600,
      initialImport = initialImport,
      loading = fakeLoading(),
      audio = {
        openingReady = function()
          return true
        end,
      },
    })
    return state, staged
  end
  local function restore()
    CacheFs.forVersion = saved.forVersion
    MovieModule.loadValidatedScenes = saved.loadScenes
    MovieModule.new = saved.movieNew
  end
  local ok, err = xpcall(function()
    do
      local state, staged = build(false)
      state:update(1 / 30)
      Assert.notNil(state.movie, "the five ready scenes stage the movie behind the loader")
      state:update(1 / 30)
      Assert.equal(state.phase, "movie", "the warm entry enters the staged movie without the loader beat")
      state:draw()
      Assert.isTrue(staged.draws >= 1, "the entered movie paints its first frame")
      state:dispose()
    end
    do
      local state, _ = build(true)
      state:update(1 / 30)
      Assert.notNil(state.movie, "the cold entry stages the movie the same way")
      state:update(1 / 30)
      Assert.equal(state.phase, "loading", "the true first import keeps its bounded beat while fresh")
      for _ = 1, 30 do
        state:update(1 / 30)
      end
      Assert.equal(state.phase, "movie", "the cold entry still reaches its staged movie after the beat")
      state:dispose()
    end
  end, debug.traceback)
  restore()
  if not ok then
    error(err, 0)
  end
end

-- A staged opening movie waits behind the visible loader while its
-- soundtrack banks are still pending: no source tick advances and no
-- movie frame draws until the selected audio session confirms the start.
function T.tests.movie_holds_loader_until_soundtrack_start_is_confirmed()
  local StartupTitleState = require("app.src.launcher.StartupTitleState")
  local CacheFs = require("libs.storage.src.CacheFs")
  local MovieModule = require("libs.hgss.src.presentation.HgssOpeningMovie")
  local saved = {
    forVersion = CacheFs.forVersion,
    loadScenes = MovieModule.loadValidatedScenes,
    movieNew = MovieModule.new,
  }
  local audioPending = true
  local audioUrgencies = {}
  local order = {}
  local sounds = 0
  local ticks = 0
  local draws = 0
  local function fakeLoading()
    local presentation = {}
    function presentation:update() end
    function presentation:resize() end
    function presentation:draw() end
    function presentation:dispose() end
    function presentation:adoptGeneratedAssets()
      return true
    end
    return presentation
  end
  local host = {}
  function host.requestMilestone(name, urgency)
    if name == "startup-audio" then
      audioUrgencies[#audioUrgencies + 1] = urgency
      if audioPending then
        return false, nil
      end
      return true, nil
    end
    if name == "startup-loader" or name == "startup-title" then
      return true, nil
    end
    return false, nil
  end
  function host.requestOpeningScene(_, _)
    return true, nil
  end
  local movie = { disposed = 0 }
  function movie:updateFixed()
    ticks = ticks + 1
    order[#order + 1] = "tick"
  end
  function movie:draw()
    draws = draws + 1
  end
  function movie:resize() end
  function movie:skipAllowed()
    return false
  end
  function movie:requestSkip()
    return false
  end
  function movie:isFinished()
    return false
  end
  function movie:sceneNumber()
    return 1
  end
  function movie:dispose()
    self.disposed = self.disposed + 1
  end
  local audio = {}
  function audio.openingReady()
    sounds = sounds + 1
    order[#order + 1] = "sound"
    return true
  end
  CacheFs.forVersion = function(_)
    return {}
  end
  MovieModule.loadValidatedScenes = function()
    return { {}, {}, {}, {}, {} }
  end
  MovieModule.new = function(_)
    return movie
  end
  local ok, err = xpcall(function()
    local state = StartupTitleState.new({
      versionId = "heartgold",
      epoch = 7,
      derivedAssets = host,
      stageMenu = function()
        error("the soundtrack hold test never stages a menu")
      end,
      onFinished = function()
        error("the soundtrack hold test never finishes")
      end,
      onSwitchEdition = function() end,
      isCurrent = function()
        return true
      end,
      width = 800,
      height = 600,
      initialImport = false,
      loading = fakeLoading(),
      audio = audio,
    })
    for _ = 1, 5 do
      state:update(1 / 30)
    end
    Assert.notNil(state.movie, "the five ready scenes stage the movie behind the loader")
    Assert.equal(state.phase, "loading", "pending soundtrack banks keep the loader visible")
    Assert.equal(ticks, 0, "no source tick advances while the soundtrack is pending")
    Assert.equal(sounds, 0, "no soundtrack start is confirmed while its banks are pending")
    local required = false
    for _, urgency in ipairs(audioUrgencies) do
      if urgency == "required" then
        required = true
      end
    end
    Assert.isTrue(required, "the staged movie demands its soundtrack banks ahead of visuals")
    state:draw()
    Assert.equal(draws, 0, "the loader draw shows no movie frame while the soundtrack is pending")
    audioPending = false
    for _ = 1, 5 do
      state:update(1 / 30)
    end
    Assert.equal(sounds, 1, "readiness confirms exactly one soundtrack start")
    Assert.equal(state.phase, "movie", "the confirmed soundtrack admits the staged movie")
    local firstSound, firstTick = nil, nil
    for index, kind in ipairs(order) do
      if kind == "sound" and firstSound == nil then
        firstSound = index
      end
      if kind == "tick" and firstTick == nil then
        firstTick = index
      end
    end
    Assert.notNil(firstSound, "the soundtrack start is recorded")
    Assert.notNil(firstTick, "the admitted movie advances")
    Assert.isTrue(firstSound < firstTick, "the soundtrack start precedes the first movie tick")
    for _ = 1, 5 do
      state:update(1 / 30)
    end
    Assert.equal(sounds, 1, "later updates never restart the admitted soundtrack")
    state:dispose()
  end, debug.traceback)
  CacheFs.forVersion = saved.forVersion
  MovieModule.loadValidatedScenes = saved.loadScenes
  MovieModule.new = saved.movieNew
  if not ok then
    error(err, 0)
  end
end

-- A terminal soundtrack failure and a rejected soundtrack start both keep
-- the loader visible with an explicit diagnostic: the movie never plays
-- silently and the selection can still be cancelled.
function T.tests.audio_failure_keeps_loader_visible_instead_of_silent_movie()
  local StartupTitleState = require("app.src.launcher.StartupTitleState")
  local CacheFs = require("libs.storage.src.CacheFs")
  local MovieModule = require("libs.hgss.src.presentation.HgssOpeningMovie")
  local saved = {
    forVersion = CacheFs.forVersion,
    loadScenes = MovieModule.loadValidatedScenes,
    movieNew = MovieModule.new,
  }
  local function runCase(mode)
    local ticks = 0
    local statuses = {}
    local cancelled = false
    local function fakeLoading()
      local presentation = {}
      function presentation:update() end
      function presentation:resize() end
      function presentation:draw(status)
        statuses[#statuses + 1] = status
      end
      function presentation:dispose() end
      function presentation:adoptGeneratedAssets()
        return true
      end
      return presentation
    end
    local host = {}
    function host.requestMilestone(name, _)
      if name == "startup-audio" then
        if mode == "bank failure" then
          return false, "synthetic bank failure"
        end
        return true, nil
      end
      if name == "startup-loader" or name == "startup-title" then
        return true, nil
      end
      return false, nil
    end
    function host.requestOpeningScene(_, _)
      return true, nil
    end
    local movie = {}
    function movie:updateFixed()
      ticks = ticks + 1
    end
    function movie:draw() end
    function movie:resize() end
    function movie:skipAllowed()
      return false
    end
    function movie:requestSkip()
      return false
    end
    function movie:isFinished()
      return false
    end
    function movie:sceneNumber()
      return 1
    end
    function movie:dispose() end
    local audio = {}
    function audio.openingReady()
      if mode == "rejected start" then
        return false, "synthetic play failure"
      end
      error("the " .. mode .. " case never confirms a soundtrack start")
    end
    CacheFs.forVersion = function(_)
      return {}
    end
    MovieModule.loadValidatedScenes = function()
      return { {}, {}, {}, {}, {} }
    end
    MovieModule.new = function(_)
      return movie
    end
    local ok, err = xpcall(function()
      local state = StartupTitleState.new({
        versionId = "heartgold",
        epoch = 7,
        derivedAssets = host,
        stageMenu = function()
          error("the " .. mode .. " case never stages a menu")
        end,
        onFinished = function()
          error("the " .. mode .. " case never finishes")
        end,
        onSwitchEdition = function() end,
        onCancel = function()
          cancelled = true
        end,
        isCurrent = function()
          return true
        end,
        width = 800,
        height = 600,
        initialImport = false,
        loading = fakeLoading(),
        audio = audio,
      })
      for _ = 1, 5 do
        state:update(1 / 30)
      end
      Assert.isFalse(
        state.phase == "movie",
        "the " .. mode .. " never admits a silent movie"
      )
      Assert.equal(ticks, 0, "the " .. mode .. " advances no source tick")
      state:draw()
      Assert.notNil(statuses[#statuses], "the " .. mode .. " stays visible with a diagnostic")
      state:keypressed("escape", "escape", false)
      Assert.isTrue(cancelled, "the " .. mode .. " still honours selection cancel")
      state:dispose()
    end, debug.traceback)
    CacheFs.forVersion = saved.forVersion
    MovieModule.loadValidatedScenes = saved.loadScenes
    MovieModule.new = saved.movieNew
    if not ok then
      error(err, 0)
    end
  end
  runCase("bank failure")
  runCase("rejected start")
end

return T
