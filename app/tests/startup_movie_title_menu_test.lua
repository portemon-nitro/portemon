-- Selected-edition startup through the full cinematic journey. The App keeps
-- one transferred loading presentation while five source opening scenes are
-- demanded, plays them before the legendary title, latches an early title
-- skip behind pending menu readiness, follows the original opening/title
-- music lifecycle with one late legendary cry, composes audio directly, and
-- disposes every owned presentation exactly once on failure or retirement.

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

local function fakeLoading()
  local presentation = {
    draws = 0,
    disposals = 0,
    adoptions = 0,
    adopted = false,
  }
  function presentation:update() end
  function presentation:resize() end
  function presentation:draw()
    self.draws = self.draws + 1
    active.paints = active.paints + 1
  end
  function presentation:dispose()
    self.disposals = self.disposals + 1
  end
  function presentation:adoptGeneratedAssets()
    self.adoptions = self.adoptions + 1
    self.adopted = true
    return true
  end
  active.loaders[#active.loaders + 1] = presentation
  return presentation
end

-- Deterministic stand-in for the five-scene movie renderer: the startup
-- state owns its lifetime and input eligibility, while the scene pixels
-- stay owned by the real movie renderer under ROM-backed graphics tests.
local function fakeMovie(options)
  assert(type(options) == "table" and type(options.scenes) == "table")
  assert(#options.scenes == 5, "the movie session needs all five validated scene packages")
  local movie = {
    ticks = 0,
    draws = 0,
    disposed = 0,
    duration = active.movieDuration or 120,
    skipAfter = active.movieSkipAfter,
    finished = false,
  }
  if movie.skipAfter == nil then
    movie.skipAfter = 10
  end
  function movie:updateFixed()
    self.ticks = self.ticks + 1
    if self.ticks >= self.duration then
      self.finished = true
    end
  end
  function movie:draw()
    self.draws = self.draws + 1
    active.paints = active.paints + 1
  end
  function movie:resize() end
  function movie:skipAllowed()
    return (not self.finished) and self.ticks >= self.skipAfter
  end
  function movie:requestSkip()
    if self:skipAllowed() then
      self.finished = true
      return true
    end
    return false
  end
  function movie:isFinished()
    return self.finished
  end
  function movie:sceneNumber()
    return 1
  end
  function movie:dispose()
    self.disposed = self.disposed + 1
  end
  active.movies[#active.movies + 1] = movie
  return movie
end

local function fakeMenu()
  local menu = { disposed = 0, inputs = 0 }
  function menu:update() end
  function menu:draw()
    active.paints = active.paints + 1
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
    startupAudioSession = App.startupAudioSession,
    startupAudioError = App.startupAudioError,
    gameFactory = HgssGame.new,
    recordPlayed = require("app.src.launcher.EditionPreference").recordPlayed,
  }

  active = {
    requests = {},
    scenes = {},
    menus = {},
    loaders = {},
    movies = {},
    epochs = {},
    paints = 0,
    graphicsEvents = {},
    whiteOverlays = 0,
    audioSessions = {},
    sceneReady = {},
    sceneFailure = {},
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
  function service:observe(_, selector)
    -- The boot wait demands the selected walking pair as a required
    -- interest before it transfers: model the healthy worker answer so the
    -- startup journey under test starts from its transferred loader.
    if selector.requestKind == "startup-walker" then
      return true, nil
    end
    if selector.requestKind == "opening-scene" then
      local sceneNumber = selector.sceneNumber
      local failure = active.sceneFailure[sceneNumber]
      if failure ~= nil then
        return false, failure
      end
      return active.sceneReady[sceneNumber] == true, nil
    end
    if selector.requestKind ~= "milestone" then
      return nil, nil
    end
    if selector.name == "startup-title" then
      return active.titleAssetsReady ~= false, nil
    end
    if selector.name == "bootstrap" then
      return active.bootstrapReady == true, nil
    end
    if selector.name == "startup-audio" then
      return active.audioReady == true, nil
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
  App.pairIndex = 1
  App.pendingQuiesce = nil
  App.selectedVersionId = nil
  App.startupAudioSession = nil
  App.startupAudioError = nil
  App.opts = { dev = false }
  App.drawableWidth, App.drawableHeight, App.pixelRatio = 800, 600, 1
  movieModule.new = fakeMovie
  StartupAssetCache.loadOpeningScene = function(_, sceneNumber, versionId)
    if active.sceneReady[sceneNumber] == true then
      return {
        sceneNumber = sceneNumber,
        versionId = versionId,
        generationId = "startup-test-generation",
      }
    end
    return nil, "scene " .. tostring(sceneNumber) .. " is still compiling"
  end
  StartupAudioSession.new = function(options)
    local session = { events = {}, disposals = 0 }
    local provided = type(options) == "table" and options.titleRecord or nil
    if type(provided) == "table" and type(provided.crySpeciesId) == "number" then
      session.titleRecord = { crySpeciesId = provided.crySpeciesId }
    end
    -- The borrowed audio owns the single cry identity for its selected
    -- edition: repeating the same species is a no-op while a different
    -- species for the same selection is a programming error.
    function session:bindTitleRecord(record)
      assert(
        type(record) == "table" and type(record.crySpeciesId) == "number",
        "title audio needs its normalized cry species"
      )
      if self.titleRecord ~= nil then
        assert(
          self.titleRecord.crySpeciesId == record.crySpeciesId,
          "the bound title cry cannot drift within its selected edition"
        )
        return
      end
      self.titleRecord = { crySpeciesId = record.crySpeciesId }
    end
    function session:beginOpening()
      self.events[#self.events + 1] = "opening"
      return true
    end
    function session:beginTitle(record)
      if record ~= nil and self.titleRecord == nil then
        self:bindTitleRecord(record)
      end
      self.events[#self.events + 1] = "title"
    end
    function session:notifySkip(record)
      if active.strictTitleBinding then
        local bound = self.titleRecord or record
        local species = type(bound) == "table" and bound.crySpeciesId or nil
        assert(type(species) == "number", "title skip needs its normalized audio record")
        self.events[#self.events + 1] = { "cry", species, 0 }
        return
      end
      self.events[#self.events + 1] = "cry"
    end
    function session:beginFade()
      self.events[#self.events + 1] = "fade"
    end
    function session:playMenuCue()
      self.events[#self.events + 1] = "menu"
    end
    function session:update() end
    function session:dispose()
      self.disposals = self.disposals + 1
    end
    active.audioSessions[#active.audioSessions + 1] = session
    return session
  end
  HgssLoadingPresentation.new = function()
    return fakeLoading()
  end
  titleSceneModule.new = function(options)
    local bundle = { crySpeciesId = active.titleCrySpecies or 25 }
    if active.titleTimeoutFrames ~= nil then
      bundle.timeline = { start = { activeDurationFrames = active.titleTimeoutFrames } }
    end
    local scene = {
      versionId = options.versionId,
      bundle = bundle,
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
      self.draws = self.draws + 1
      active.paints = active.paints + 1
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
      active.whiteOverlays = active.whiteOverlays + 1
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
  App.startupAudioSession = saved.startupAudioSession
  App.startupAudioError = saved.startupAudioError
  HgssGame.new = saved.gameFactory
  require("app.src.launcher.EditionPreference").recordPlayed = saved.recordPlayed
  if not ok then
    error(err, 0)
  end
end

local function startSelection(versionId)
  App._selectVersion(versionId or "heartgold")
  App.update(1 / 60)
  App.update(1 / 30)
  return App.state
end

---@return table<number> demanded opening scene numbers in request order
local function demandedScenes()
  local scenes = {}
  for _, request in ipairs(active.requests) do
    local selector = request.selector
    if selector.requestKind == "opening-scene" then
      scenes[#scenes + 1] = selector.sceneNumber
    end
  end
  return scenes
end

-- The transferred loader animates for its minimum beat behind the staged
-- movie before the opening plays: pump boundedly until the handoff instead
-- of assuming one update suffices. The staged movie holds its source clock
-- at zero throughout, so arrival still proves the loader-first ordering.
---@param state table the startup state under test
local function pumpUntilMovie(state)
  for _ = 1, 60 do
    if state.phase == "movie" then
      return
    end
    App.update(1 / 30)
  end
end

function T.tests.startup_demands_all_five_opening_scenes_and_keeps_one_menu_through_movie_and_title()
  withStartup(function()
    local state = startSelection()
    Assert.notNil(state, "the selected edition installs its startup state")
    -- The journey runs behind the admitted movie, so its soundtrack
    -- banks are ready before the five scenes complete.
    active.audioReady = true

    -- The transferred boot presentation is the one startup presentation:
    -- no second loader is constructed on the way into the cinematic.
    Assert.equal(#active.loaders, 1, "the boot presentation transfers without a replacement loader")
    Assert.equal(
      state.loading,
      active.loaders[1],
      "the startup state adopts the exact transferred presentation"
    )

    -- The cinematic journey is demanded as five numbered scenes, scene 1
    -- required first with the rest promoted before playback starts.
    local scenes = demandedScenes()
    for sceneNumber = 1, 5 do
      local seen = false
      for _, demanded in ipairs(scenes) do
        if demanded == sceneNumber then
          seen = true
        end
      end
      Assert.isTrue(seen, "the startup demands opening scene " .. sceneNumber .. " by number")
    end

    -- Loader stays animated while scenes compile: every frame paints.
    local paints = active.paints
    App.draw()
    Assert.isTrue(active.paints > paints, "the retained loader paints while scenes are still compiling")

    -- All five validated packages construct exactly one movie; the loader
    -- survives until its first movie frame is proven drawable.
    for sceneNumber = 1, 5 do
      active.sceneReady[sceneNumber] = true
    end
    pumpUntilMovie(state)
    Assert.equal(state.phase, "movie", "five ready scenes construct the opening movie phase")
    Assert.notNil(state.movie, "the movie session is owned by the startup state, not a parallel owner")
    Assert.equal(active.loaders[1].disposals, 0, "the loader is retained until the first movie frame")

    -- A finished movie disposes the movie once and presents the legendary
    -- title; a pending title keeps the same loader instead of blanking.
    active.titleAssetsReady = false
    for _ = 1, 60 do
      App.update(1 / 30)
      if state.phase ~= "movie" then
        break
      end
    end
    Assert.equal(state.phase, "movie", "an unfinished movie keeps playing while the title is pending")
    paints = active.paints
    App.draw()
    Assert.isTrue(active.paints > paints, "the movie keeps painting while the title bundle is pending")
    while state.movie ~= nil and not state.movie:isFinished() do
      state.movie:updateFixed()
    end
    App.update(1 / 30)
    Assert.isNil(state.movie, "the finished movie is disposed exactly once at the title handoff")
    Assert.equal(active.loaders[1].draws > 0, true, "the pending title keeps the same loader visible")
    paints = active.paints
    App.draw()
    Assert.isTrue(active.paints > paints, "no blank frame appears between the movie and the pending title")

    -- The independently ready title appears only after the movie; one
    -- latched skip then fades white into exactly one staged menu.
    active.titleAssetsReady = true
    App.update(1 / 30)
    Assert.equal(#active.scenes, 1, "the title scene is constructed once after the movie")
    Assert.equal(state.phase, "title", "the legendary title follows the completed movie")
    App.keypressed("return", "return", false)
    Assert.isFalse(state.skipRequested and state.movie ~= nil, "the title press never replays the movie")
    active.bootstrapReady = true
    App.update(1 / 30)
    Assert.equal(#active.menus, 1, "bootstrap stages exactly one menu behind the skipped title")
    for _ = 1, 100 do
      if App.state ~= state then
        break
      end
      App.draw()
      App.update(1 / 30)
    end
    Assert.equal(App.state, active.menus[1], "the same staged menu installs after the white fade")
    Assert.isTrue(active.whiteOverlays > 0, "the title-to-menu handoff fades through white")
    Assert.equal(#active.menus, 1, "handoff never reconstructs the menu")
  end)
end

function T.tests.warm_movie_starts_at_once_while_a_true_first_import_keeps_its_beat()
  withStartup(function()
    -- Warm: an ordinary selection enters the staged movie on the next
    -- eligible update with no loader beat.
    local state = startSelection()
    Assert.notNil(state, "the selected edition installs its startup state")
    -- Both the warm and the cold entry admit through the same
    -- soundtrack confirmation, so the banks are ready throughout.
    active.audioReady = true
    for sceneNumber = 1, 5 do
      active.sceneReady[sceneNumber] = true
    end
    App.update(1 / 30)
    Assert.equal(#active.movies, 1, "the warm entry stages the movie behind the loader")
    App.update(1 / 30)
    Assert.equal(state.phase, "movie", "the warm entry starts the staged movie without a loader beat")
    App.draw()
    Assert.isTrue(active.movies[1].draws >= 1, "the entered movie paints its first frame at once")
    -- Cold: a genuinely new import keeps one bounded beat so its freshly
    -- adopted art stays visible before the same handoff.
    App._selectVersion("heartgold", { freshImport = true })
    App.update(1 / 60)
    App.update(1 / 30)
    local cold = assert(App.state, "the first import installs its startup state")
    for _ = 1, 15 do
      App.update(1 / 30)
      App.draw()
    end
    Assert.equal(cold.phase, "loading", "the true first import keeps its bounded beat while fresh")
    Assert.equal(#active.movies, 2, "the cold entry stages the same movie behind its loader")
    Assert.equal(active.movies[2].ticks, 0, "the staged movie holds its source clock at zero during the beat")
    pumpUntilMovie(cold)
    Assert.equal(cold.phase, "movie", "the cold entry still reaches its staged movie after the beat")
    App.draw()
    Assert.isTrue(active.movies[2].draws >= 1, "the first playable source frame draws at the transition")
  end)
end

function T.tests.accepted_title_input_proceeds_once_and_latches_until_the_staged_menu_fades()
  withStartup(function()
    local state = startSelection()
    -- The skip journey runs behind the admitted movie, so its
    -- soundtrack banks are ready before the scenes complete.
    active.audioReady = true
    -- The legendary title follows the completed opening movie.
    for sceneNumber = 1, 5 do
      active.sceneReady[sceneNumber] = true
    end
    pumpUntilMovie(state)
    while state.movie ~= nil and not state.movie:isFinished() do
      state.movie:updateFixed()
    end
    App.update(1 / 30)
    Assert.equal(state.phase, "title", "the selected edition reaches its legendary title")

    App.keypressed("return", "return", false)
    Assert.isTrue(state.skipRequested, "the first title press latches skip intent")
    Assert.equal(active.scenes[1].proceeds, 1, "the accepted press starts the title proceed reveal once")
    for _ = 1, 60 do
      App.update(1 / 30)
    end
    Assert.equal(App.state, state, "pending menu readiness keeps the title installed")
    Assert.isTrue(active.scenes[1].ticks >= 60, "the title keeps animating while the skip is pending")
    Assert.equal(active.scenes[1].proceeds, 1, "waiting never replays the proceed reveal")
    Assert.equal(#active.menus, 0, "no menu stages before bootstrap readiness")

    active.bootstrapReady = true
    App.update(1 / 30)
    Assert.equal(#active.menus, 1, "bootstrap readiness stages the menu once under the latched skip")
    Assert.isTrue(
      state.phase == "fadeOut" or state.phase == "fadeIn",
      "the latched skip starts the fade automatically"
    )
    App.keypressed("return", "return", false)
    Assert.equal(active.scenes[1].proceeds, 1, "a second press never replays the proceed reveal")
    for _ = 1, 100 do
      if App.state ~= state then
        break
      end
      App.update(1 / 30)
    end
    Assert.equal(App.state, active.menus[1], "the exact staged menu installs after the fade")
    Assert.equal(#active.menus, 1, "handoff never reconstructs the menu")
    Assert.equal(active.scenes[1].disposed, 1, "the title scene releases once at handoff")
  end)
end

function T.tests.opening_and_title_music_follow_their_stages_with_one_late_cry()
  withStartup(function()
    local state = startSelection()
    Assert.notNil(state.audio, "the startup state borrows semantic audio callbacks")
    Assert.equal(
      type(state.audio.openingReady),
      "function",
      "the borrowed audio covers the movie stage opening cue"
    )

    -- Audio ready during the movie starts the opening track exactly once.
    active.audioReady = true
    for sceneNumber = 1, 5 do
      active.sceneReady[sceneNumber] = true
    end
    pumpUntilMovie(state)
    Assert.equal(state.phase, "movie", "five ready scenes reach the movie phase")
    local openings = 0
    for _, session in ipairs(active.audioSessions) do
      for _, event in ipairs(session.events) do
        if event == "opening" then
          openings = openings + 1
        end
      end
    end
    Assert.equal(openings, 1, "the active movie starts its opening track once")
    for _ = 1, 30 do
      App.update(1 / 30)
    end
    openings = 0
    for _, session in ipairs(active.audioSessions) do
      for _, event in ipairs(session.events) do
        if event == "opening" then
          openings = openings + 1
        end
      end
    end
    Assert.equal(openings, 1, "the movie never restarts its opening track")

    -- Entering the title switches to the title track; a skip while the
    -- session is absent remembers one cry for the late session.
    while state.movie ~= nil and not state.movie:isFinished() do
      state.movie:updateFixed()
    end
    App.update(1 / 30)
    Assert.equal(state.phase, "title", "the finished movie hands off to the legendary title")
    local titles = 0
    for _, session in ipairs(active.audioSessions) do
      for _, event in ipairs(session.events) do
        if event == "title" then
          titles = titles + 1
        end
      end
    end
    Assert.equal(titles, 1, "title entry switches to the title track once")
    App._releaseStartupAudio()
    active.audioReady = false
    App.keypressed("return", "return", false)
    Assert.isTrue(state.skipRequested, "the title press latches while audio is absent")
    Assert.isTrue(state.pendingLegendaryCry, "the accepted skip remembers its pending legendary cry")
    for _ = 1, 10 do
      App.update(1 / 30)
    end
    Assert.equal(App.state, state, "pending menu readiness keeps the title installed")
    active.audioReady = true
    App.update(1 / 30)
    App.update(1 / 30)
    local cries = 0
    for _, session in ipairs(active.audioSessions) do
      for _, event in ipairs(session.events) do
        if event == "cry" then
          cries = cries + 1
        end
      end
    end
    Assert.equal(cries, 1, "the late session delivers the pending cry once before the fade")
    Assert.isFalse(state.pendingLegendaryCry, "delivery consumes the pending cry")
    local lateTitles = 0
    for index = 2, #active.audioSessions do
      for _, event in ipairs(active.audioSessions[index].events) do
        if event == "title" then
          lateTitles = lateTitles + 1
        end
      end
    end
    Assert.equal(lateTitles, 0, "a session that arrives after the skip never starts a belated title track")

    -- The actual staged-menu fade starts the music fade exactly once.
    active.bootstrapReady = true
    App.update(1 / 30)
    local fades = 0
    for _, session in ipairs(active.audioSessions) do
      for _, event in ipairs(session.events) do
        if event == "fade" then
          fades = fades + 1
        end
      end
    end
    Assert.equal(fades, 1, "the staged-menu fade starts the music fade once")
    for _ = 1, 100 do
      if App.state ~= state then
        break
      end
      App.update(1 / 30)
    end
    Assert.equal(App.state, active.menus[1], "the staged menu installs after the fade")
  end)

  withStartup(function()
    -- Audio lost after admission stays lost through the skip and the
    -- fade: no cry and no replayed track, and never blocks the menu
    -- transfer.
    local state = startSelection()
    -- The admitted movie needs its soundtrack; the loss below happens
    -- after that acknowledgment.
    active.audioReady = true
    for sceneNumber = 1, 5 do
      active.sceneReady[sceneNumber] = true
    end
    pumpUntilMovie(state)
    Assert.equal(state.phase, "movie", "five ready scenes reach the movie phase")
    -- The soundtrack drops out after admission but before the title
    -- entry: the finished movie still hands off with no title track.
    App._releaseStartupAudio()
    active.audioReady = false
    while state.movie ~= nil and not state.movie:isFinished() do
      state.movie:updateFixed()
    end
    App.update(1 / 30)
    Assert.equal(state.phase, "title", "the selected edition reaches its legendary title")
    -- The title press latches with no session behind it.
    App.keypressed("return", "return", false)
    Assert.isTrue(state.skipRequested, "the title press latches while audio is absent")
    Assert.equal(#active.audioSessions, 1, "the skip with absent audio constructs no additional session")
    active.bootstrapReady = true
    App.update(1 / 30)
    Assert.isTrue(
      state.phase == "fadeOut" or state.phase == "fadeIn",
      "the latched skip starts the fade without audio"
    )
    active.audioReady = true
    for _ = 1, 100 do
      if App.state ~= state then
        break
      end
      App.update(1 / 30)
    end
    Assert.equal(App.state, active.menus[1], "the menu installs even though audio arrived mid-fade")
    for _, session in ipairs(active.audioSessions) do
      for _, event in ipairs(session.events) do
        Assert.isFalse(event == "cry", "audio that arrives after the fade begins plays no cry")
        Assert.isFalse(event == "title", "audio that arrives after the fade never starts a belated track")
      end
    end
    Assert.equal(#active.menus, 1, "the late audio never reconstructs the menu")
  end)
end

function T.tests.opening_music_starts_once_at_movie_entry_when_audio_is_ready()
  withStartup(function()
    local state = startSelection()
    active.audioReady = true
    for sceneNumber = 1, 5 do
      active.sceneReady[sceneNumber] = true
    end
    local entryUpdates = 0
    while state.phase ~= "movie" and entryUpdates < 5 do
      App.update(1 / 30)
      entryUpdates = entryUpdates + 1
    end
    Assert.equal(state.phase, "movie", "five ready scenes reach the movie phase")
    local function openings()
      local count = 0
      for _, session in ipairs(active.audioSessions) do
        for _, event in ipairs(session.events) do
          if event == "opening" then
            count = count + 1
          end
        end
      end
      return count
    end
    Assert.equal(openings(), 1, "ready audio starts the opening track once at movie entry")
    Assert.isTrue(
      state.movie.ticks <= 1,
      "the opening decision lands on the entry update before the movie advances"
    )
    for _ = 1, 30 do
      App.update(1 / 30)
    end
    Assert.equal(state.phase, "movie", "the movie keeps playing behind its single opening track")
    Assert.equal(openings(), 1, "the running movie never restarts its opening track")
  end)
end

function T.tests.pending_audio_holds_loader_until_readiness_admits_the_movie()
  withStartup(function()
    local state = startSelection()
    for sceneNumber = 1, 5 do
      active.sceneReady[sceneNumber] = true
    end
    -- Pending soundtrack banks hold the loader: the staged movie waits
    -- silently with no source tick, no session, and no start.
    for _ = 1, 10 do
      App.update(1 / 30)
    end
    Assert.equal(state.phase, "loading", "pending audio holds the loader behind the staged movie")
    Assert.notNil(state.movie, "all five scenes stage the movie while audio is pending")
    Assert.equal(state.movie.ticks, 0, "no source tick advances while the soundtrack is pending")
    Assert.equal(#active.audioSessions, 0, "pending audio constructs no session behind the loader")
    local paints = active.paints
    App.draw()
    Assert.isTrue(active.paints > paints, "the loader keeps painting while audio is pending")
    -- Readiness admits the staged movie with exactly one opening start.
    active.audioReady = true
    pumpUntilMovie(state)
    Assert.equal(state.phase, "movie", "readiness admits the staged movie")
    local function counts()
      local openings, titles = 0, 0
      for _, session in ipairs(active.audioSessions) do
        for _, event in ipairs(session.events) do
          if event == "opening" then
            openings = openings + 1
          elseif event == "title" then
            titles = titles + 1
          end
        end
      end
      return openings, titles
    end
    local openings, titles = counts()
    Assert.equal(openings, 1, "readiness starts the opening track once at admission")
    Assert.equal(titles, 0, "admission starts no title track")
    -- The admitted movie hands off to the title, which starts its own
    -- track once; the opening never replays.
    while state.movie ~= nil and not state.movie:isFinished() do
      state.movie:updateFixed()
    end
    App.update(1 / 30)
    Assert.equal(state.phase, "title", "the admitted movie hands off to the legendary title")
    openings, titles = counts()
    Assert.equal(openings, 1, "the opening track is never repeated after admission")
    Assert.equal(titles, 1, "title entry still starts its own track once")
  end)
end

function T.tests.startup_audio_composes_directly_without_the_game_root_wrapper()
  local GameAudio = require("game.hgss.src.audio.GameAudio")
  local savedCompose = GameAudio.compose
  local savedWrapper = HgssGame.newStartupAudio
  local composed = 0
  local sound = {}
  function sound:playMusic() end
  function sound:playCry() end
  function sound:fadeMusicOut() end
  function sound:stopMusic() end
  function sound:play() end
  function sound:updateSoundFrame() end
  local sink = {}
  function sink:update() end
  function sink:release() end
  GameAudio.compose = function(options)
    composed = composed + 1
    Assert.equal(options.outputRate, 32768, "startup composition keeps the source output rate")
    Assert.notNil(options.cacheFs, "startup composition keeps its version cache filesystem")
    return { sound = sound, sink = sink }
  end
  HgssGame.newStartupAudio = function()
    error("the game root no longer forwards startup audio composition", 0)
  end
  local ok, sessionOrError = pcall(StartupAudioSession.new, {
    versionId = "heartgold",
    cacheFs = {},
    titleRecord = { crySpeciesId = 250 },
  })
  GameAudio.compose = savedCompose
  HgssGame.newStartupAudio = savedWrapper
  Assert.isTrue(ok, "startup audio composes without the game root wrapper: " .. tostring(sessionOrError))
  local session = assert(sessionOrError)
  Assert.equal(composed, 1, "construction composes the game audio exactly once")
  session:beginTitle()
  session:notifySkip()
  session:beginFade()
  session:playMenuCue("select")
  session:update(1 / 30)
  session:dispose()
end

function T.tests.movie_skip_never_becomes_title_skip_and_releases_are_swallowed()
  withStartup(function()
    local state = startSelection()
    -- The skip-eligibility journey runs behind the admitted movie, so
    -- its soundtrack banks are ready before the scenes complete.
    active.audioReady = true
    for sceneNumber = 1, 5 do
      active.sceneReady[sceneNumber] = true
    end
    pumpUntilMovie(state)
    Assert.equal(state.phase, "movie", "five ready scenes reach the movie phase")

    -- The source skip gate stays shut before eligibility: input does nothing.
    App.keypressed("return", "return", false)
    Assert.equal(state.phase, "movie", "an early press cannot skip a gated movie")
    Assert.notNil(state.movie, "a gated movie survives its ineligible input")
    Assert.isFalse(state.skipRequested, "movie input never latches title skip intent")

    -- An eligible pointer press skips the movie and is swallowed, so the
    -- newly presented title still needs its own accepted press.
    for _ = 1, 12 do
      App.update(1 / 30)
    end
    App.mousepressed(400, 300, 1, false, 1)
    Assert.isNil(state.movie, "the eligible press finishes the movie exactly once")
    Assert.equal(active.movies[1].disposed, 1, "the skipped movie disposes exactly once")
    Assert.equal(state.phase, "title", "the skipped movie hands off to the legendary title")
    Assert.isFalse(state.skipRequested, "the movie press never becomes the title skip")
    Assert.equal(active.scenes[1].proceeds, 0, "the movie press never starts the title reveal")
    App.mousereleased(400, 300, 1, false, 1)
    Assert.deepEqual(state.canceledPointers, {}, "the movie press release is swallowed")
    Assert.deepEqual(App._swallowedPointers, {}, "the swallowed release never reaches a later owner")
    Assert.equal(#active.menus, 0, "no menu stages from a movie press")

    App.keypressed("return", "return", false)
    Assert.isTrue(state.skipRequested, "the title still needs its own accepted press")
    Assert.equal(active.scenes[1].proceeds, 1, "the title press starts the proceed reveal once")
    Assert.isNil(state.movie, "the title press never replays the movie")
  end)
end

function T.tests.partial_opening_manifest_keeps_the_loader_without_start_or_error()
  withStartup(function()
    local state = startSelection()
    for sceneNumber = 1, 4 do
      active.sceneReady[sceneNumber] = true
    end
    for _ = 1, 5 do
      App.update(1 / 30)
    end
    Assert.equal(state.phase, "loading", "four of five scenes never install the movie")
    Assert.isNil(state.movie, "a partial manifest constructs no movie session")
    Assert.isNil(state.sceneError, "a partial manifest reports no terminal failure")
    Assert.equal(#active.scenes, 0, "no title constructs while the movie is still pending")
    local paints = active.paints
    App.draw()
    Assert.isTrue(active.paints > paints, "the loader keeps painting while the last scene compiles")
    for _ = 1, 5 do
      App.update(1 / 30)
    end
    Assert.equal(state.phase, "loading", "polling never escalates a pending scene into an error")
    Assert.isNil(state.sceneError, "pending scenes never report a terminal failure")
  end)
end

function T.tests.late_audio_checkpoints_play_only_the_current_stage_cue()
  withStartup(function()
    local state = startSelection()
    Assert.equal(#active.audioSessions, 0, "no session exists before the first audio checkpoint")
    for sceneNumber = 1, 5 do
      active.sceneReady[sceneNumber] = true
    end
    -- Checkpoint 0: pending audio holds the loader behind the staged
    -- movie with no tick and no session.
    for _ = 1, 5 do
      App.update(1 / 30)
    end
    Assert.equal(state.phase, "loading", "pending audio holds the loader behind the staged movie")
    Assert.notNil(state.movie, "all five scenes stage the movie while audio is pending")
    Assert.equal(state.movie.ticks, 0, "no source tick advances while the soundtrack is pending")
    Assert.equal(#active.audioSessions, 0, "pending audio constructs no session behind the loader")

    -- Checkpoint 1: readiness admits the movie with only the opening cue.
    active.audioReady = true
    pumpUntilMovie(state)
    Assert.equal(state.phase, "movie", "readiness admits the staged movie")
    Assert.equal(#active.audioSessions, 1, "admission constructs one session")
    Assert.deepEqual(
      active.audioSessions[1].events,
      { "opening" },
      "admission starts only the opening track"
    )

    -- Checkpoint 2: title entry adds the title track on the same session.
    while state.movie ~= nil and not state.movie:isFinished() do
      state.movie:updateFixed()
    end
    App.update(1 / 30)
    Assert.equal(state.phase, "title", "the finished movie hands off to the legendary title")
    Assert.equal(#active.audioSessions, 1, "title entry constructs no second session")
    local session = active.audioSessions[1]
    Assert.deepEqual(session.events, { "opening", "title" }, "title entry adds only the title track")

    -- Checkpoint 3: skip while the session exists cries once.
    App.keypressed("return", "return", false)
    Assert.deepEqual(session.events, { "opening", "title", "cry" }, "the accepted skip cries once")
    for _ = 1, 10 do
      App.update(1 / 30)
    end
    Assert.deepEqual(session.events, { "opening", "title", "cry" }, "waiting never duplicates the cry")

    -- Checkpoint 4: the staged-menu fade starts the music fade once.
    active.bootstrapReady = true
    App.update(1 / 30)
    Assert.deepEqual(
      session.events,
      { "opening", "title", "cry", "fade" },
      "the fade starts once at handoff"
    )

    -- Checkpoint 5: the transferred menu keeps the session for cues only.
    for _ = 1, 100 do
      if App.state ~= state then
        break
      end
      App.update(1 / 30)
    end
    local menu = assert(App.state, "the staged menu installs after the fade")
    Assert.equal(#active.audioSessions, 1, "transfer constructs no second session")
    Assert.equal(session.disposals, 0, "transfer retains the borrowed session")

    -- Checkpoint 6: retirement disposes once and late results stay silent.
    App._selectVersion("soulsilver")
    Assert.equal(session.disposals, 1, "retirement disposes the startup session exactly once")
    Assert.equal(menu.disposed, 1, "retirement disposes the untransferred staged menu once")
  end)
end

function T.tests.idle_title_loops_the_movie_without_losing_epoch_or_menu()
  withStartup(function()
    active.titleTimeoutFrames = 30
    local state = startSelection()
    -- Both the first entry and the idle-loop re-entry admit through
    -- the same soundtrack confirmation, so the banks stay ready.
    active.audioReady = true
    for sceneNumber = 1, 5 do
      active.sceneReady[sceneNumber] = true
    end
    pumpUntilMovie(state)
    while state.movie ~= nil and not state.movie:isFinished() do
      state.movie:updateFixed()
    end
    App.update(1 / 30)
    Assert.equal(state.phase, "title", "the finished movie hands off to the legendary title")
    active.bootstrapReady = true
    App.update(1 / 30)
    local menu = assert(state.stagedMenu, "the menu stages behind the unskipped title")
    local epoch = App.epoch

    for _ = 1, 40 do
      App.update(1 / 30)
    end
    Assert.equal(state.phase, "movie", "the idle title loops back into the movie")
    Assert.equal(#active.movies, 2, "the loop acquires a fresh movie session")
    Assert.equal(active.scenes[1].disposed, 1, "the loop releases the idle title graph once")
    Assert.equal(App.epoch, epoch, "the loop selects no new epoch")
    Assert.equal(state.stagedMenu, menu, "the loop retains the already staged menu")
    Assert.isTrue(state.bootstrapObserved, "the loop retains bootstrap readiness")
    while state.movie ~= nil and not state.movie:isFinished() do
      state.movie:updateFixed()
    end
    App.update(1 / 30)
    Assert.equal(state.phase, "title", "the looped movie hands back to a fresh title")
    Assert.equal(#active.scenes, 2, "the looped movie presents the title again")
    Assert.equal(state.stagedMenu, menu, "the same staged menu survives the loop")
  end)

  withStartup(function()
    active.titleTimeoutFrames = 30
    local state = startSelection()
    -- The skipped title still needs its admitted movie first, so the
    -- soundtrack banks are ready before the scenes complete.
    active.audioReady = true
    for sceneNumber = 1, 5 do
      active.sceneReady[sceneNumber] = true
    end
    pumpUntilMovie(state)
    while state.movie ~= nil and not state.movie:isFinished() do
      state.movie:updateFixed()
    end
    App.update(1 / 30)
    App.keypressed("return", "return", false)
    Assert.isTrue(state.skipRequested, "the title press latches while the menu is pending")
    for _ = 1, 60 do
      App.update(1 / 30)
    end
    Assert.equal(App.state, state, "a skipped title never times out back into the movie")
    Assert.equal(#active.movies, 1, "pending skip constructs no second movie")
  end)
end

function T.tests.resize_during_fade_keeps_clocks_and_overlay()
  withStartup(function()
    local state = startSelection()
    -- The resize journey runs behind the admitted movie, so its
    -- soundtrack banks are ready before the scenes complete.
    active.audioReady = true
    for sceneNumber = 1, 5 do
      active.sceneReady[sceneNumber] = true
    end
    pumpUntilMovie(state)
    App.resize(1024, 768)
    Assert.equal(state.phase, "movie", "resize keeps the movie clock")
    Assert.equal(state.width, 1024, "resize reaches the startup dimensions")
    while state.movie ~= nil and not state.movie:isFinished() do
      state.movie:updateFixed()
    end
    App.update(1 / 30)
    App.keypressed("return", "return", false)
    active.bootstrapReady = true
    App.update(1 / 30)
    Assert.isTrue(state.phase == "fadeOut" or state.phase == "fadeIn", "the latched skip starts the fade")
    local phase, frame = state.phase, state.fadeFrame
    App.resize(640, 480)
    Assert.equal(state.phase, phase, "resize during the fade keeps the phase")
    Assert.equal(state.fadeFrame, frame, "resize during the fade keeps the fade clock")
    App.update(1 / 30)
    Assert.equal(state.phase, phase, "the fade advances in place after resize")
    local overlays = active.whiteOverlays
    App.draw()
    Assert.isTrue(active.whiteOverlays > overlays, "the fade still draws its white overlay after resize")
    for _ = 1, 100 do
      if App.state ~= state then
        break
      end
      App.update(1 / 30)
    end
    Assert.equal(App.state, active.menus[1], "the fade completes into the staged menu after resize")
  end)
end

function T.tests.failed_opening_scene_is_a_visible_error_and_retirement_disposes_everything_once()
  withStartup(function()
    active.sceneFailure[3] = "synthetic scene 3 compilation failure"
    local state = startSelection()
    Assert.notNil(state, "the selected edition installs its startup state")

    Assert.equal(state.phase, "error", "a terminal scene failure surfaces instead of a fake title")
    Assert.equal(#active.scenes, 0, "a failed journey constructs no title scene")
    Assert.notNil(state.sceneError, "the terminal scene failure is retained for the diagnostic surface")
    local paints = active.paints
    App.draw()
    Assert.isTrue(
      active.paints > paints,
      "the recoverable error keeps the retained loader painted instead of a blank frame"
    )
    for _ = 1, 5 do
      App.update(1 / 30)
    end
    Assert.equal(state.phase, "error", "polling never retries the failed scene behind a tight request loop")
    Assert.equal(#active.menus, 0, "a failed journey stages no menu")

    App.keypressed("escape", "escape", false)
    Assert.isTrue(App.state ~= state, "escape leaves the failed startup without a renderer retry")
    Assert.equal(active.loaders[1].disposals, 1, "leaving releases the retained loader exactly once")
  end)

  withStartup(function()
    for sceneNumber = 1, 5 do
      active.sceneReady[sceneNumber] = true
    end
    -- The retirement journey needs its admitted movie first, so the
    -- soundtrack banks are ready before the selection starts.
    active.audioReady = true
    local state = startSelection()
    pumpUntilMovie(state)
    Assert.equal(state.phase, "movie", "five ready scenes reach the movie phase")
    local movie = assert(state.movie, "the movie session is owned before retirement")

    App._selectVersion("soulsilver")
    Assert.equal(movie.disposed, 1, "edition retirement disposes the active movie exactly once")
    Assert.equal(active.loaders[1].disposals, 1, "edition retirement disposes the retained loader exactly once")
    Assert.isTrue(
      active.retired ~= nil and #active.retired == 1,
      "retirement retires exactly the selected cache epoch"
    )
  end)
end

function T.tests.movie_first_title_entry_keeps_its_edition_cry_through_the_accepted_skip()
  local cases = {
    { versionId = "heartgold", species = 250 },
    { versionId = "soulsilver", species = 249 },
  }
  for _, case in ipairs(cases) do
    withStartup(function()
      active.strictTitleBinding = true
      active.titleCrySpecies = case.species
      local state = startSelection(case.versionId)
      for sceneNumber = 1, 5 do
        active.sceneReady[sceneNumber] = true
      end
      active.audioReady = true
      pumpUntilMovie(state)
      Assert.equal(state.phase, "movie", "five ready scenes reach the movie phase")
      while state.movie ~= nil and not state.movie:isFinished() do
        state.movie:updateFixed()
      end
      App.update(1 / 30)
      Assert.equal(state.phase, "title", "the finished movie hands off to the legendary title")
      App.keypressed("return", "return", false)
      Assert.isTrue(state.skipRequested, "the title press latches skip intent")
      active.bootstrapReady = true
      App.update(1 / 30)
      Assert.equal(#active.menus, 1, "bootstrap stages exactly one menu behind the skipped title")
      for _ = 1, 120 do
        if App.state ~= state then
          break
        end
        App.update(1 / 30)
      end
      Assert.equal(App.state, active.menus[1], "the staged menu installs after the fade")
      local openings, titles, cries = 0, 0, {}
      for _, session in ipairs(active.audioSessions) do
        for _, event in ipairs(session.events) do
          if event == "opening" then
            openings = openings + 1
          elseif event == "title" then
            titles = titles + 1
          elseif type(event) == "table" and event[1] == "cry" then
            cries[#cries + 1] = event
          end
        end
      end
      Assert.equal(openings, 1, "the movie-first journey starts its opening track once")
      Assert.equal(titles, 1, "title entry switches to the title track once")
      Assert.deepEqual(
        cries,
        { { "cry", case.species, 0 } },
        "the accepted skip plays its edition cry exactly once with the source pattern"
      )
      Assert.isNil(App.startupAudioError, "the bound handoff keeps audio available without a disabled diagnostic")
      Assert.equal(#active.audioSessions, 1, "one session spans the movie-first title handoff")
    end)
  end
end

function T.tests.idle_title_replays_both_music_tracks_before_the_final_cry()
  withStartup(function()
    active.titleTimeoutFrames = 30
    local state = startSelection()
    for sceneNumber = 1, 5 do
      active.sceneReady[sceneNumber] = true
    end
    active.audioReady = true
    pumpUntilMovie(state)
    Assert.equal(state.phase, "movie", "five ready scenes reach the movie phase")
    while state.movie ~= nil and not state.movie:isFinished() do
      state.movie:updateFixed()
    end
    App.update(1 / 30)
    Assert.equal(state.phase, "title", "the finished movie hands off to the legendary title")
    active.bootstrapReady = true
    App.update(1 / 30)
    local menu = assert(state.stagedMenu, "the menu stages behind the unskipped title")
    local epoch = App.epoch
    for _ = 1, 40 do
      App.update(1 / 30)
    end
    Assert.equal(state.phase, "movie", "the idle title loops back into the movie")
    Assert.equal(#active.movies, 2, "the loop acquires a fresh movie session")
    Assert.equal(App.epoch, epoch, "the loop selects no new epoch")
    Assert.equal(state.stagedMenu, menu, "the loop retains the already staged menu")
    while state.movie ~= nil and not state.movie:isFinished() do
      state.movie:updateFixed()
    end
    App.update(1 / 30)
    Assert.equal(state.phase, "title", "the looped movie presents the title again")
    local function orderedAudioEvents()
      local order = {}
      for _, session in ipairs(active.audioSessions) do
        for _, event in ipairs(session.events) do
          order[#order + 1] = event
        end
      end
      return order
    end
    Assert.deepEqual(
      orderedAudioEvents(),
      { "opening", "title", "opening", "title" },
      "each visual entry restarts its own music track in source order"
    )
    for _ = 1, 10 do
      App.update(1 / 30)
    end
    Assert.deepEqual(
      orderedAudioEvents(),
      { "opening", "title", "opening", "title" },
      "reentrant updates never duplicate a track"
    )
    Assert.equal(state.phase, "title", "the replayed title waits for its own accepted press")
    App.keypressed("return", "return", false)
    for _ = 1, 120 do
      if App.state ~= state then
        break
      end
      App.update(1 / 30)
    end
    Assert.equal(App.state, menu, "the same staged menu installs after the final fade")
    Assert.deepEqual(
      orderedAudioEvents(),
      { "opening", "title", "opening", "title", "cry", "fade" },
      "the loop ends with one cry and one fade behind the replayed tracks"
    )
    Assert.equal(#active.audioSessions, 1, "one session spans every replayed entry")
  end)
end

return T
