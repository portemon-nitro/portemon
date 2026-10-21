-- Exercise startup through App's source gate and selected epoch. Presentation
-- objects are recorded at their graphics boundary; cache readiness, state
-- ownership, and the staged menu path remain production-composed.

local Assert = require("tests.support.Assert")
local App = require("app.src.App")
local FirstPlayCompletion = require("romdump.src.FirstPlayCompletion")
local HgssLoadingPresentation = require("libs.hgss.src.ui.HgssLoadingPresentation")
local MainMenuComposition = require("app.src.mainmenu.MainMenuComposition")
local HgssGame = require("game.hgss.src.HgssGame")

local TITLE_SCENE_MODULE = "libs.hgss.src.presentation.HgssTitleScene"
local titleSceneModule = require(TITLE_SCENE_MODULE)

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
    firstPlayFactory = HgssGame.newFirstPlayCachePreparation,
    startupAudio = App.startupAudio,
  }

  active = { requests = {}, scenes = {}, menus = {}, epochs = {}, drawEvents = {}, graphicsEvents = {} }
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
    if selector.requestKind ~= "milestone" then
      return nil, nil
    end
    if selector.name == "startup-loader" or selector.name == "startup-title" then
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
  App.pendingQuiesce = nil
  App.selectedVersionId = nil
  App.startupAudio = nil
  App.opts = { dev = false }
  App.drawableWidth, App.drawableHeight, App.pixelRatio = 800, 600, 1
  HgssLoadingPresentation.new = newLoadingPresentation
  titleSceneModule.new = function(options)
    local scene = {
      versionId = options.versionId,
      ticks = 0,
      draws = 0,
      disposed = 0,
    }
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
  HgssGame.newFirstPlayCachePreparation = saved.firstPlayFactory
  App.startupAudio = saved.startupAudio
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
      { startupRequests[1], startupRequests[2], startupRequests[3] },
      { "startup-loader", "startup-title", "bootstrap" },
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
    Assert.equal(App.state.targetVersion, "soulsilver", "the unavailable edition opens D01 targeted import")
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
    local events = { titleReady = 0, prompt = 0, skip = 0 }
    App.startupAudio = {
      titleReady = function()
        events.titleReady = events.titleReady + 1
      end,
      prompt = function()
        events.prompt = events.prompt + 1
      end,
      skip = function()
        events.skip = events.skip + 1
      end,
    }

    local state = startTitle()
    Assert.equal(events.titleReady, 1, "title readiness emits one bounded audio event")
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

return T
