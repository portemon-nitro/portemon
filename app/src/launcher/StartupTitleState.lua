-- Holds the selected edition's loader/title while the existing Main Menu is staged.

local HgssOpeningMovie = require("libs.hgss.src.presentation.HgssOpeningMovie")
local HgssTitleScene = require("libs.hgss.src.presentation.HgssTitleScene")
local SourceTick = require("libs.hgss.src.field.SourceTick")

---@class StartupTitleLoading
---@field update fun(self: StartupTitleLoading, dt: number)
---@field draw fun(self: StartupTitleLoading, status: table<string, unknown>?)
---@field resize fun(self: StartupTitleLoading, width: number, height: number, safeRect: { x: number, y: number, width: number, height: number }?)
---@field dispose fun(self: StartupTitleLoading)
---@field keypressed fun(self: StartupTitleLoading, key: string, scancode: string?, isrepeat: boolean?)?
---@field gamepadpressed fun(self: StartupTitleLoading, joystick: unknown, button: string)?
---@field mousepressed fun(self: StartupTitleLoading, x: number, y: number, button: integer, istouch: boolean?)?
---@field mousemoved fun(self: StartupTitleLoading, x: number, y: number)?
---@field mousereleased fun(self: StartupTitleLoading, x: number, y: number, button: integer, istouch: boolean?)?
---@field touchpressed fun(self: StartupTitleLoading, id: number, x: number, y: number)?
---@field touchmoved fun(self: StartupTitleLoading, id: number, x: number, y: number)?
---@field touchreleased fun(self: StartupTitleLoading, id: number, x: number, y: number)?
---@field focus fun(self: StartupTitleLoading, focused: boolean)?

---@class StartupTitleState
---@field versionId string
---@field epoch integer
---@field cacheFs table<string, unknown>
---@field derivedAssets table<string, function>?
---@field stageMenu fun(): table<string, unknown>
---@field onFinished fun(menu: table<string, unknown>)
---@field onCancel fun()?
---@field isCurrent fun(epoch: integer): boolean
---@field onTitleReady fun()?
---@field beginWarmup fun()?
---@field audio table<string, function>?
---@field splRandomState table<string, integer>? borrowed boot stream record shared by one boot
---@field phase string
---@field loading StartupTitleLoading?
---@field movie table<string, unknown>?
---@field movieScenes table[]?
---@field movieCompleted boolean
---@field movieLeadIn integer remaining black ticks before the first video tick
---@field movieVideoStarted boolean true once the movie has advanced its first tick
---@field openingObserved boolean[]
---@field openingStarted boolean
---@field promotedBootstrap boolean
---@field sceneError unknown?
---@field sceneFailed boolean
---@field title HgssTitleScene?
---@field stagedMenu table<string, unknown>?
---@field skipRequested boolean
---@field pendingLegendaryCry boolean
---@field fadeStarted boolean
---@field titleElapsed integer
---@field titleEntry integer remaining retail title start-up calls before its theme starts
---@field titleAnimating boolean true once the adopted title has run its first animation call
---@field titleBuild HgssTitleScene.Build? staged title construction in progress
---@field assetRuntime { cacheFs: table<string, unknown>, decoded: table<string, unknown>, preparationQueue: table<string, unknown> } borrowed selected CPU runtime
---@field menuError unknown?
---@field titleError unknown?
---@field bootstrapError unknown?
---@field requested boolean
---@field titleObserved boolean
---@field titleReadyNotified boolean
---@field bootstrapObserved boolean
---@field audioObserved boolean
---@field audioReady boolean
---@field audioError unknown?
---@field audioStarted boolean
---@field menuAttempted boolean
---@field accumulator number
---@field loaderVisibleTime number seconds the transferred loader has animated
---@field fadeFrame integer
---@field pointerCapture string?
---@field canceledPointers table<string, boolean>
---@field transferred boolean
---@field disposed boolean
---@field width number
---@field height number
local StartupTitleState = {}
StartupTitleState.__index = StartupTitleState

-- Maximum host time a single update may advance the staged source clocks.
-- The retail loop advances video and audio together once per iteration no
-- matter how long the iteration takes, while our video accumulator would
-- otherwise replay blocked main-thread time faster (entry audio setup,
-- lazy sample loads, menu staging, GC) and the sample-clocked soundtrack
-- drops the same blocked time instead: every hitch would push the visuals
-- permanently ahead of the music. Capping the catch-up restores the
-- lockstep: a stalled frame delays both clocks together instead of
-- fast-forwarding the video. Two ticks cover normal frame jitter and
-- match the audio sink queue depth, so only real stalls are dropped.
local MAX_CATCHUP_TICKS = 2
-- Black source ticks between the acknowledged soundtrack start and the
-- first video tick. The retail overlay runs INIT and the scene runs INIT
-- (loading its graphics with the planes off) while the opening BGM already
-- plays, so the first video frame trails the soundtrack by two source
-- ticks; the staged movie holds its entry clock at zero behind black for
-- the same beat instead of ticking alongside the first audible frame.
local MOVIE_LEAD_IN_TICKS = 2
-- Retail src/title_screen.c start-up calls behind white before its first
-- animation call: TitleScreen_Init, the model-loading case, and the case
-- that starts SEQ_GS_POKEMON_THEME. The opening track keeps playing until
-- that last call, so its final note is never cut by an early title theme.
local TITLE_ENTRY_CALLS = 3
local FADE_OUT_FRAMES = 60
local FADE_IN_FRAMES = 18
-- Title geometry realization budget per update: one prepared mesh upload per
-- frame. This preparation advances independently of movie admission.
local TITLE_BUILD_WORK_UNITS = 1
local TITLE_LOAD_WORK_UNITS = 4
local DWELL_DT_CAP = 0.25
local OPENING_SCENE_COUNT = 5

---@class StartupTitleState.Options
---@field versionId string
---@field epoch integer
---@field cacheFs table<string, unknown> selected epoch's installed generated view
---@field assetRuntime { cacheFs: table<string, unknown>, decoded: table<string, unknown>, preparationQueue: table<string, unknown> } borrowed selected CPU runtime
---@field derivedAssets table<string, function> selected epoch host
---@field stageMenu fun(): table<string, unknown> constructs the actual product menu
---@field onFinished fun(menu: table<string, unknown>) transfers the staged menu
---@field onCancel fun()? returns to the edition selector
---@field isCurrent fun(epoch: integer): boolean
---@field onTitleReady (fun())?
---@field beginWarmup (fun())? fires the save-agnostic near/sweep prefetch once at title entry
---@field audio table<string, function>? borrowed App-owned callbacks
---@field splRandomState table<string, integer>? borrowed boot stream record shared by one boot
---@field loading StartupTitleLoading one transferred neutral loading presentation
---@field width number
---@field height number

---@param options StartupTitleState.Options
---@return StartupTitleState
function StartupTitleState.new(options)
  assert(type(options) == "table", "startup title requires composition options")
  assert(
    options.versionId == "heartgold" or options.versionId == "soulsilver",
    "startup title requires a supported edition"
  )
  assert(type(options.epoch) == "number" and options.epoch % 1 == 0, "startup title requires its selected epoch")
  assert(type(options.derivedAssets) == "table", "startup title requires the selected derived host")
  assert(options.cacheFs ~= nil, "startup title requires the selected epoch's installed generated view")
  local assetRuntime = options.assetRuntime
  assert(
    type(assetRuntime) == "table"
      and assetRuntime.cacheFs == options.cacheFs
      and assetRuntime.preparationQueue ~= nil
      and assetRuntime.decoded ~= nil,
    "startup title requires the selected epoch's CPU runtime"
  )
  -- Production collaborators are required: the five-scene opening selector
  -- is part of the locked movie-first journey, never an optional feature
  -- with a title-only fallback.
  assert(
    type(options.derivedAssets.requestOpeningScene) == "function",
    "startup title requires the five-scene opening selector"
  )
  assert(type(options.stageMenu) == "function", "startup title requires menu staging")
  assert(type(options.onFinished) == "function", "startup title requires the menu transfer")
  assert(type(options.isCurrent) == "function", "startup title requires an epoch guard")
  if options.beginWarmup ~= nil then
    assert(type(options.beginWarmup) == "function", "startup title begins its warmup through a function")
  end
  assert(type(options.width) == "number" and type(options.height) == "number")
  assert(
    options.splRandomState == nil or type(options.splRandomState) == "table",
    "startup title borrows the boot stream record"
  )
  local loading = assert(options.loading, "startup title requires the transferred neutral loading presentation")
  assert(
    type(loading.update) == "function"
      and type(loading.draw) == "function"
      and type(loading.resize) == "function"
      and type(loading.dispose) == "function",
    "the transferred boot presentation is unusable"
  )
  local self = setmetatable({
    versionId = options.versionId,
    epoch = options.epoch,
    cacheFs = options.cacheFs,
    assetRuntime = assetRuntime,
    derivedAssets = options.derivedAssets,
    stageMenu = options.stageMenu,
    onFinished = options.onFinished,
    onCancel = options.onCancel,
    isCurrent = options.isCurrent,
    onTitleReady = options.onTitleReady,
    beginWarmup = options.beginWarmup,
    audio = options.audio,
    splRandomState = options.splRandomState,
    phase = "loading",
    loading = loading,
    movie = nil,
    movieScenes = nil,
    movieCompleted = false,
    movieLeadIn = 0,
    movieVideoStarted = false,
    openingObserved = { false, false, false, false, false },
    openingStarted = false,
    promotedBootstrap = false,
    sceneError = nil,
    sceneFailed = false,
    title = nil,
    stagedMenu = nil,
    skipRequested = false,
    pendingLegendaryCry = false,
    fadeStarted = false,
    titleElapsed = 0,
    titleEntry = 0,
    titleAnimating = false,
    titleBuild = nil,
    menuError = nil,
    titleError = nil,
    bootstrapError = nil,
    requested = false,
    titleObserved = false,
    titleReadyNotified = false,
    bootstrapObserved = false,
    audioObserved = false,
    audioReady = false,
    audioError = nil,
    audioStarted = false,
    menuAttempted = false,
    accumulator = 0,
    loaderVisibleTime = 0,
    warmupFired = false,
    fadeFrame = 0,
    pointerCapture = nil,
    canceledPointers = {},
    transferred = false,
    disposed = false,
    width = options.width,
    height = options.height,
  }, StartupTitleState)
  return self
end

function StartupTitleState:_live()
  return not self.disposed and self.isCurrent(self.epoch)
end

function StartupTitleState:_request(name, urgency)
  local ok, ready, failure = pcall(self.derivedAssets.requestMilestone, name, urgency or "required")
  if not ok then
    return false, ready
  end
  if failure ~= nil then
    return false, failure
  end
  return ready == true, nil
end

function StartupTitleState:_requestOpeningScene(sceneNumber, urgency)
  local ok, ready, failure = pcall(self.derivedAssets.requestOpeningScene, sceneNumber, urgency)
  if not ok then
    return false, ready
  end
  if failure ~= nil then
    return false, failure
  end
  return ready == true, nil
end

function StartupTitleState:_startRequests()
  if self.requested then
    return
  end
  self.requested = true
  -- Scene one leads the closure. The remaining scenes start near and are
  -- promoted together once scene one is ready; all five still gate adoption.
  local ready, failure = self:_requestOpeningScene(1, "required")
  if failure ~= nil then
    self.sceneError = failure
    self.sceneFailed = true
    self.phase = "error"
  else
    self.openingObserved[1] = ready
  end
  for sceneNumber = 2, OPENING_SCENE_COUNT do
    local sceneReady, sceneFailure = self:_requestOpeningScene(sceneNumber, "near")
    if sceneFailure ~= nil then
      self.sceneError = sceneFailure
      self.sceneFailed = true
      self.phase = "error"
    else
      self.openingObserved[sceneNumber] = sceneReady
    end
  end
  -- Request order preserves title priority ahead of broad menu/gameplay
  -- work. Bootstrap stays near until the title pipeline shows progress.
  -- Boot already owns the one shared loader demand and passes the adopted
  -- presentation forward, so the title never demands its own copy.
  do
    local titleReady, titleFailure = self:_request("startup-title")
    if titleReady then
      self:_beginTitleBuild()
    elseif titleFailure ~= nil then
      self.titleError = titleFailure
      self.phase = "error"
    end
  end
  local bootstrapReady, bootstrapFailure = self:_request("bootstrap", "near")
  if bootstrapReady then
    self.bootstrapObserved = true
  elseif bootstrapFailure ~= nil then
    self.bootstrapError = bootstrapFailure
  end
  local audioReady, audioFailure = self:_request("startup-audio", "near")
  if audioReady then
    self.audioObserved = true
    self.audioReady = true
  elseif audioFailure ~= nil then
    self.audioObserved = true
    self.audioError = audioFailure
  end
  self:_notifyTitleReady()
  self:_maybeStartAudio()
end

-- Polls the five numbered scene demands and constructs the movie only after
-- all five validated packages are current. A terminal worker failure becomes a
-- visible recoverable error; pending scenes simply keep the loader.
function StartupTitleState:_pollOpeningScenes()
  if self.sceneFailed or self.movie ~= nil or self.movieCompleted then
    return
  end
  local allReady = true
  for sceneNumber = 1, OPENING_SCENE_COUNT do
    local urgency = sceneNumber == 1 and "required" or "near"
    if sceneNumber > 1 and self.openingObserved[1] then
      urgency = "required"
    end
    local ready, failure = self:_requestOpeningScene(sceneNumber, urgency)
    if failure ~= nil then
      self.sceneError = failure
      self.sceneFailed = true
      self.phase = "error"
      return
    end
    self.openingObserved[sceneNumber] = ready
    if not ready then
      allReady = false
    end
  end
  if allReady and self.phase == "loading" then
    self:_adoptMovie()
  end
end

-- Constructs the movie transactionally from five strictly validated scene
-- packages. The loader is retained until the movie's first frame is proven
-- drawable; a failed acquisition stays a visible error, never a fake title.
function StartupTitleState:_adoptMovie()
  if self.movie ~= nil or not self:_live() then
    return
  end
  for sceneNumber = 1, OPENING_SCENE_COUNT do
    if not self.openingObserved[sceneNumber] then
      return
    end
  end
  local cacheFs = self.cacheFs
  local scenes, failure = HgssOpeningMovie.loadValidatedScenes(cacheFs, self.versionId)
  if scenes == nil then
    self.sceneError = failure
    self.phase = "error"
    return
  end
  local runtime = self.assetRuntime
  local ok, movie = pcall(HgssOpeningMovie.new, {
    versionId = self.versionId,
    scenes = scenes,
    cacheFs = cacheFs,
    splRandomState = self.splRandomState,
    width = self.width,
    height = self.height,
    assetPreparation = runtime.preparationQueue,
    decoded = runtime.decoded,
  })
  if not ok then
    self.sceneError = movie
    self.phase = "error"
    return
  end
  self.movie = assert(movie)
  self.movieScenes = scenes
  -- The fully acquired movie stays staged behind the visible loader until
  -- the soundtrack acknowledges its start. Title preparation continues in
  -- parallel and never delays this admission.
end

-- Enters the staged movie once all five scenes and the soundtrack are ready.
-- Optional preparation starts at this actual first entry, never while assets
-- are still pending and never again on attract-loop reentry.
function StartupTitleState:_maybeEnterMovie()
  if self.phase ~= "loading" or self.movie == nil or not self:_live() then
    return
  end
  if not self:_confirmSoundtrackStart() then
    return
  end
  if not self.warmupFired and type(self.beginWarmup) == "function" then
    self.warmupFired = true
    self.beginWarmup()
  end
  local movie = assert(self.movie)
  if movie:isFinished() then
    self:_finishMovie()
    return
  end
  self.phase = "movie"
  -- The soundtrack is already audible: hold the staged entry frame behind
  -- black for the retail INIT beat before the first video tick.
  self.movieLeadIn = MOVIE_LEAD_IN_TICKS
  self.movieVideoStarted = false
end

-- Confirms the staged movie's soundtrack start without advancing a tick.
-- Pending banks hold the loader; a missing session or callback, a raised
-- play failure, or a rejected start records its diagnostic and admits no
-- movie. Returns true only after the start is acknowledged.
---@return boolean
function StartupTitleState:_confirmSoundtrackStart()
  if not self.audioReady then
    return false
  end
  if self.audio == nil or type(self.audio.openingReady) ~= "function" then
    self.audioError = self.audioError or "startup audio unavailable"
    return false
  end
  local ok, acknowledged, reason = pcall(self.audio.openingReady)
  if not ok then
    self.audioError = acknowledged
    return false
  end
  if acknowledged ~= true then
    self.audioError = reason or "startup audio unavailable"
    return false
  end
  self.openingStarted = true
  self.audioError = nil
  return true
end

-- Records host-output loss during the active movie. Only the current movie
-- adopts the diagnostic and stops ticking with its existing error display;
-- title, menu, and other phases ignore the signal.
function StartupTitleState:openingAudioFailed(reason)
  if self.phase ~= "movie" or self.movie == nil then
    return
  end
  self.audioError = reason or "startup audio unavailable"
  self.phase = "error"
end

-- Retires the finished or skipped movie exactly once and hands the retained
-- title over directly. Admission guarantees a realized title, so the ordinary
-- handoff presents it in the same update; a title that lost its stage keeps the
-- loader while its rebuild is advanced.
function StartupTitleState:_finishMovie()
  local movie = self.movie
  if movie == nil then
    return
  end
  self.movie = nil
  self.movieCompleted = true
  movie:dispose()
  if self.title ~= nil then
    self:_presentTitle()
    return
  end
  self.phase = "loading"
  self:_pollTitleBuild()
end

-- Begins the staged title build once the validated title milestone is ready.
-- The build asks the presentation worker for the title model banks while the
-- opening cinematic is still playing, so the handoff frame only uploads
-- prepared mesh packets instead of decoding GX geometry on this thread.
function StartupTitleState:_beginTitleBuild()
  -- A journey that already failed (a terminal scene or milestone failure keeps
  -- the diagnostic loader) never starts the title presentation behind it.
  if self.phase == "error" or self.sceneFailed then
    return
  end
  if self.titleBuild ~= nil or self.title ~= nil or self.titleError ~= nil then
    return
  end
  local runtime = self.assetRuntime
  local ok, build = pcall(HgssTitleScene.begin, {
    versionId = self.versionId,
    cacheFs = self.cacheFs,
    width = self.width,
    height = self.height,
    assetPreparation = runtime.preparationQueue,
    decoded = runtime.decoded,
  })
  if not ok then
    self.titleError = build
    self.phase = "error"
    return
  end
  self.titleBuild = build
  self.titleObserved = true
end

-- Advances the staged title build with the budget its current cover allows and
-- adopts the finished scene without delaying movie admission.
function StartupTitleState:_pollTitleBuild()
  local build = self.titleBuild
  if build == nil then
    return
  end
  if not build:isReady() then
    local budget = self.phase == "loading" and TITLE_LOAD_WORK_UNITS or TITLE_BUILD_WORK_UNITS
    local ok, failure = pcall(build.advance, build, budget)
    if not ok then
      self.titleError = failure
      self.phase = "error"
      pcall(build.release, build)
      self.titleBuild = nil
      return
    end
    if not build:isReady() then
      return
    end
  end
  self:_adoptTitle()
end

function StartupTitleState:_adoptTitle()
  if self.title ~= nil or not self:_live() then
    return
  end
  local build = self.titleBuild
  if build == nil or not build:isReady() then
    return
  end
  local ok, result = pcall(build.takeResult, build)
  self.titleBuild = nil
  if not ok then
    self.titleError = result
    self.phase = "error"
    return
  end
  self.title = assert(result)
  -- The build laid out for the dimensions it began with; resizes while it was
  -- staged only reached this state.
  self.title:resize(self.width, self.height)
  -- A title realized while the opening plays is retained behind it and
  -- presented by the movie handoff; otherwise it presents right away.
  if self.movieCompleted then
    self:_presentTitle()
  end
end

-- Makes the retained title the visible presentation, starting its retail entry
-- cadence from zero. Called once by the movie handoff, or by adoption when no
-- opening is staged in front of it.
function StartupTitleState:_presentTitle()
  if self.phase ~= "loading" and self.phase ~= "movie" then
    return
  end
  self.titleElapsed = 0
  self.titleEntry = TITLE_ENTRY_CALLS
  self.titleAnimating = false
  self.phase = "title"
  self:_notifyTitleReady()
  self:_maybeStartAudio()
end

function StartupTitleState:_notifyTitleReady()
  if self.title == nil or self.titleReadyNotified or not self:_live() then
    return
  end
  self.titleReadyNotified = true
  if self.onTitleReady ~= nil then
    self.onTitleReady()
  end
end

-- Phase-aware audio dispatch. The opening track is confirmed at movie
-- admission before the first frame; the title track starts once on
-- unskipped title entry; a pending legendary cry is delivered exactly once
-- while a latched skip is still waiting for the menu fade. A phase that
-- already ended never starts its track belatedly.
function StartupTitleState:_maybeStartAudio()
  if not self:_live() or self.audio == nil then
    return
  end
  if self.phase == "movie" then
    return
  end
  if not self.audioReady then
    return
  end
  if self.phase ~= "title" or self.title == nil then
    return
  end
  if self.pendingLegendaryCry and not self.fadeStarted then
    -- Consume the pending cry only against a currently ready milestone;
    -- while audio is still absent the memory survives until the fade.
    local readyNow = self:_request("startup-audio", "near")
    if readyNow then
      if type(self.audio.prompt) == "function" then
        self.audio.prompt({ crySpeciesId = self.title.bundle.crySpeciesId })
      end
      self.pendingLegendaryCry = false
    end
    return
  end
  if self.skipRequested or self.audioStarted or self.titleEntry > 0 then
    return
  end
  if type(self.audio.titleReady) ~= "function" then
    return
  end
  self.audioStarted = true
  self.audio.titleReady({ crySpeciesId = self.title.bundle.crySpeciesId })
end

function StartupTitleState:_stageMenu()
  if self.menuAttempted or self.stagedMenu ~= nil or not self.bootstrapObserved or not self:_live() then
    return
  end
  self.menuAttempted = true
  local ok, menu = pcall(self.stageMenu)
  if not ok then
    self.menuError = menu
    return
  end
  assert(type(menu) == "table" and type(menu.draw) == "function" and type(menu.dispose) == "function")
  self.stagedMenu = menu
  self.menuError = nil
end

function StartupTitleState:_pollAssets()
  if not self.requested or not self:_live() then
    return
  end
  self:_pollOpeningScenes()
  if self.phase == "error" then
    return
  end
  if not self.titleObserved then
    local ready, failure = self:_request("startup-title")
    if failure ~= nil then
      self.titleError = failure
      self.phase = "error"
      self.titleObserved = true
    elseif ready then
      self:_beginTitleBuild()
    end
  end
  self:_pollTitleBuild()
  if not self.bootstrapObserved then
    -- Bootstrap rides near until the cinematic pipeline shows progress,
    -- then it is promoted so the menu stages promptly behind the title.
    local urgency = "near"
    if (self.phase == "movie" or self.phase == "title") and not self.promotedBootstrap then
      self.promotedBootstrap = true
    end
    if self.promotedBootstrap then
      urgency = "required"
    end
    local ready, failure = self:_request("bootstrap", urgency)
    if failure ~= nil then
      self.bootstrapError = failure
    elseif ready then
      self.bootstrapObserved = true
    end
  end
  if not self.audioObserved then
    -- While the movie is staged the soundtrack banks ride required ahead
    -- of visuals; the title-only path keeps its speculative demand.
    local urgency = "near"
    if self.movie ~= nil then
      urgency = "required"
    end
    local ready, failure = self:_request("startup-audio", urgency)
    if failure ~= nil then
      self.audioObserved = true
      self.audioError = failure
    elseif ready then
      self.audioObserved = true
      self.audioReady = true
    end
  end
  if self.bootstrapObserved then
    self:_stageMenu()
  end
  self:_notifyTitleReady()
  self:_maybeStartAudio()
end

function StartupTitleState:_beginFade()
  if self.phase == "title" and self.skipRequested and self.stagedMenu ~= nil then
    self.phase = "fadeOut"
    self.fadeFrame = 0
    -- The actual staged-menu fade starts the music fade and makes a
    -- previously unplayed cry permanently ineligible.
    self.fadeStarted = true
    self.pendingLegendaryCry = false
    if self.audio and type(self.audio.skip) == "function" then
      self.audio.skip()
    end
  end
end

-- Retail title idle timeout, measured in fixed title ticks from the title
-- entry behind the enabled prompt. Re-enters the opening movie loop without
-- selecting a new epoch, dropping the staged menu, or rescanning the
-- source. Disabled after skip intent and during the white fade.
---@return number fixed ticks before the idle title loops back to the movie
function StartupTitleState:_titleTimeoutFrames()
  local title = self.title
  local start = title ~= nil and title.bundle ~= nil and title.bundle.timeline ~= nil and title.bundle.timeline.start
    or nil
  local frames = start ~= nil and start.activeDurationFrames or nil
  if type(frames) == "number" and frames > 0 then
    return frames
  end
  return math.huge
end

-- Re-enters the movie loop on title idle timeout. The title GPU graph is
-- released before the movie scenes are re-acquired; the epoch, the staged
-- menu, and bootstrap readiness survive the loop. The next presentation is
-- rebuilt behind the loader, so the loop is admitted through exactly the same
-- title-realized invariant as the first cycle.
function StartupTitleState:_reenterMovie()
  if not self:_live() or self.phase ~= "title" or self.skipRequested then
    return
  end
  if self.movieScenes == nil then
    return
  end
  local title = self.title
  self.title = nil
  self.titleObserved = false
  self.movieCompleted = false
  self.titleElapsed = 0
  if title ~= nil then
    title:dispose()
  end
  local cacheFs = self.cacheFs
  local runtime = self.assetRuntime
  local ok, movie = pcall(HgssOpeningMovie.new, {
    versionId = self.versionId,
    scenes = self.movieScenes,
    cacheFs = cacheFs,
    splRandomState = self.splRandomState,
    width = self.width,
    height = self.height,
    assetPreparation = runtime.preparationQueue,
    decoded = runtime.decoded,
  })
  if not ok then
    self.sceneError = movie
    self.phase = "error"
    return
  end
  self.movie = movie
  -- A fresh movie entry re-enables its own opening track and the next
  -- title entry re-enables its own title track on the same session.
  self.openingStarted = false
  self.audioStarted = false
  if self.audio ~= nil and type(self.audio.beginMovieCycle) == "function" then
    self.audio.beginMovieCycle()
  end
  -- The loader covers the title rebuild and the soundtrack acknowledgement;
  -- the next updates admit the staged movie through _maybeEnterMovie.
  self.phase = "loading"
end

-- Ownership order only: detach before callback, never restore once the
-- callback starts. The App transfer installs the menu exactly once; a
-- post-install optional failure is recorded there and never rolls back
-- into this disposed owner.
function StartupTitleState:_finish()
  if self.transferred or not self:_live() then
    return
  end
  local menu = self:takeStagedMenu()
  self.transferred = true
  self.phase = "transferred"
  self.onFinished(menu)
end

function StartupTitleState:_tick()
  if self.phase == "movie" then
    if self.audioError ~= nil then
      return
    end
    local movie = self.movie
    if movie == nil then
      self.phase = "loading"
      return
    end
    -- A finished movie never needs its lead-in: hand off at once instead
    -- of holding black behind an already-completed session.
    if movie:isFinished() then
      self:_finishMovie()
      return
    end
    -- The soundtrack lead-in holds the staged entry frame behind black:
    -- the source clock only starts once the retail INIT beat has elapsed.
    if self.movieLeadIn > 0 then
      self.movieLeadIn = self.movieLeadIn - 1
      return
    end
    self.movieVideoStarted = true
    local ok, failure = pcall(movie.updateFixed, movie)
    if not ok then
      self.sceneError = failure
      self.phase = "error"
      self.movie = nil
      pcall(movie.dispose, movie)
      return
    end
    if movie:isFinished() then
      self:_finishMovie()
    end
    return
  end
  if self.phase == "title" and self.titleEntry > 0 then
    self.titleEntry = self.titleEntry - 1
    if self.titleEntry == 0 then
      self:_maybeStartAudio()
    end
    return
  end
  if self.title ~= nil and (self.phase == "title" or self.phase == "fadeOut" or self.phase == "fadeIn") then
    self.title:updateFixed()
    self.titleAnimating = true
  end
  if self.phase == "title" then
    if not self.skipRequested then
      self.titleElapsed = self.titleElapsed + 1
      if self.titleElapsed >= self:_titleTimeoutFrames() then
        self:_reenterMovie()
        return
      end
    end
    self:_beginFade()
  elseif self.phase == "fadeOut" then
    self.fadeFrame = self.fadeFrame + 1
    if self.fadeFrame >= FADE_OUT_FRAMES then
      self.phase = "fadeIn"
      self.fadeFrame = 0
    end
  elseif self.phase == "fadeIn" then
    self.fadeFrame = self.fadeFrame + 1
    if self.fadeFrame >= FADE_IN_FRAMES then
      self:_finish()
    end
  end
end

-- This state is a genuine asset-preparation presentation while its loader owns
-- the screen: the selected epoch may compile at loader throughput. A failure
-- diagnostic, the movie, the title and the menu never claim it.
---@return boolean
function StartupTitleState:isPreparingAssets()
  return not self.disposed and self.phase == "loading"
end

function StartupTitleState:update(dt)
  if not self:_live() then
    self:dispose()
    return
  end
  assert(type(dt) == "number" and dt >= 0, "startup title delta must be non-negative")
  self:_startRequests()
  self:_pollAssets()
  if self.phase == "loading" or self.phase == "error" then
    self.loading:update(dt)
  end
  -- The visible beat accumulates only while the loader owns the screen, so
  -- a hitch never skips it and later phases never extend it.
  if self.phase == "loading" then
    self.loaderVisibleTime = self.loaderVisibleTime + math.min(dt, DWELL_DT_CAP)
    self:_maybeEnterMovie()
  end
  self.accumulator = self.accumulator + math.min(dt, MAX_CATCHUP_TICKS * SourceTick.DT)
  while self.accumulator >= SourceTick.DT and not self.disposed do
    self.accumulator = self.accumulator - SourceTick.DT
    self:_tick()
    if self.phase == "error" or self.phase == "transferred" then
      self.accumulator = 0
    end
  end
end

function StartupTitleState:_status()
  if self.sceneError ~= nil and (self.phase == "error" or self.movie == nil) then
    return {
      label = "Movie unavailable",
      error = tostring(self.sceneError),
      detail = "Press Esc to return",
    }
  end
  if self.audioError ~= nil and self.movie ~= nil and not self.movieCompleted then
    return {
      label = "Movie unavailable",
      error = tostring(self.audioError),
      detail = "Press Esc to return",
    }
  end
  if self.titleError ~= nil or self.phase == "error" then
    local detail = self.titleError or self.menuError or self.bootstrapError
    return {
      label = "Title unavailable",
      error = tostring(detail),
      detail = "Press Esc to return",
    }
  end
  local detail = self.menuError or self.bootstrapError
  if detail ~= nil then
    return {
      label = "Menu unavailable",
      error = tostring(detail),
      detail = "Press R to retry",
    }
  end
  return nil
end

function StartupTitleState:draw()
  if self.disposed then
    return
  end
  if self.phase == "movie" and self.movie ~= nil and not self.movieVideoStarted then
    -- The soundtrack lead-in covers the staged entry frame: retail shows
    -- black while the INIT beat elapses behind the already-audible BGM.
    local graphics = love.graphics
    graphics.setColor(0, 0, 0, 1)
    graphics.rectangle("fill", 0, 0, self.width, self.height)
    graphics.setColor(1, 1, 1, 1)
  elseif self.phase == "movie" and self.movie ~= nil then
    local graphics = love.graphics
    graphics.push("all")
    local ok, failure = pcall(self.movie.draw, self.movie)
    graphics.pop()
    if not ok then
      self.sceneError = tostring(failure)
      self.phase = "error"
      local movie = self.movie
      self.movie = nil
      if movie ~= nil then
        pcall(movie.dispose, movie)
      end
      self.loading:draw(self:_status())
    end
  elseif self.phase == "title" and self.title ~= nil and not self.titleAnimating then
    -- Retail holds both screens white through the title start-up calls.
    local graphics = love.graphics
    graphics.setColor(1, 1, 1, 1)
    graphics.rectangle("fill", 0, 0, self.width, self.height)
    graphics.setColor(1, 1, 1, 1)
  elseif self.title ~= nil and self.phase ~= "loading" and self.phase ~= "error" then
    local graphics = love.graphics
    graphics.push("all")
    local ok, failure = pcall(self.title.draw, self.title, {
      preparingMenu = self.skipRequested and self.stagedMenu == nil,
      menuError = self.menuError or self.bootstrapError,
    })
    graphics.pop()
    if not ok then
      self.titleError = tostring(failure)
      self.phase = "error"
      self.loading:draw({ label = "Title unavailable", error = self.titleError })
    end
  else
    self.loading:draw(self:_status())
  end
  local graphics = love.graphics
  if self.phase == "fadeOut" then
    graphics.setColor(1, 1, 1, self.fadeFrame / FADE_OUT_FRAMES)
    graphics.rectangle("fill", 0, 0, self.width, self.height)
  elseif self.phase == "fadeIn" then
    if self.stagedMenu ~= nil then
      self.stagedMenu:draw()
    end
    graphics.setColor(1, 1, 1, 1 - self.fadeFrame / FADE_IN_FRAMES)
    graphics.rectangle("fill", 0, 0, self.width, self.height)
  end
  graphics.setColor(1, 1, 1, 1)
end

function StartupTitleState:resize(width, height, safeRect)
  assert(width > 0 and height > 0, "startup title dimensions must be positive")
  self.width, self.height = width, height
  self.loading:resize(width, height, safeRect)
  if self.movie ~= nil then
    self.movie:resize(width, height)
  end
  if self.title ~= nil then
    self.title:resize(width, height)
  end
  if self.stagedMenu ~= nil and type(self.stagedMenu.resize) == "function" then
    self.stagedMenu:resize(width, height)
  end
  self.pointerCapture = nil
  self.canceledPointers = {}
end

local function mouseButtonFromPointerId(pointerId)
  local button = tonumber(pointerId:sub(7))
  assert(
    type(button) == "number" and button == button and math.abs(button) < math.huge and button % 1 == 0,
    "mouse pointer identity must contain an integer button"
  )
  return button --[[@as integer]]
end

function StartupTitleState:_pressPointer(pointerId, x, y)
  if not self:_live() then
    return
  end
  if (self.phase == "loading" or self.phase == "error") and self.loading ~= nil then
    if pointerId:sub(1, 6) == "touch:" and type(self.loading.touchpressed) == "function" then
      self.loading:touchpressed(pointerId:sub(7), x, y)
      return
    elseif pointerId:sub(1, 6) == "mouse:" and type(self.loading.mousepressed) == "function" then
      self.loading:mousepressed(x, y, mouseButtonFromPointerId(pointerId))
      return
    end
  end
  -- The movie owns its own input: a press that skips the movie is captured
  -- and swallowed here so it can never become the newly presented title's
  -- skip.
  if self.phase == "movie" and self.movie ~= nil then
    self.pointerCapture = pointerId
    self.canceledPointers[pointerId] = true
    self:_requestMovieSkip()
    return
  end
  if (self.phase == "title" or self.phase == "error") and self.title ~= nil then
    if self.phase == "title" then
      self.pointerCapture = pointerId
      self.canceledPointers[pointerId] = true
      self:_requestSkip()
    end
  end
end

function StartupTitleState:_requestMovieSkip()
  if self.phase ~= "movie" or self.movie == nil then
    return
  end
  if self.movie:requestSkip() then
    self:_finishMovie()
  end
end

function StartupTitleState:_requestSkip()
  -- Retail reads title input only from its first animation call onward.
  if self.phase ~= "title" or self.title == nil or not self.titleAnimating then
    return
  end
  if not self.skipRequested then
    self.skipRequested = true
    -- The accepted press remembers one legendary cry regardless of whether
    -- optional audio is ready: delivery happens now when the milestone is
    -- currently ready, otherwise once the session arrives before the fade.
    self.pendingLegendaryCry = true
    self.title:beginProceed()
    local readyNow = self:_request("startup-audio", "near")
    if readyNow and not self.fadeStarted and self.audio and type(self.audio.prompt) == "function" then
      self.audio.prompt({ crySpeciesId = self.title.bundle.crySpeciesId })
      self.pendingLegendaryCry = false
    end
  end
  self:_beginFade()
end

function StartupTitleState:_retryMenu()
  if self.phase ~= "title" then
    return
  end
  if self.bootstrapError ~= nil and not self.bootstrapObserved then
    self.bootstrapError = nil
    local ready, failure = self:_request("bootstrap", "near")
    if failure ~= nil then
      self.bootstrapError = failure
      return
    end
    if ready then
      self.bootstrapObserved = true
    end
  end
  if self.menuError == nil or not self.bootstrapObserved then
    return
  end
  self.menuError = nil
  self.menuAttempted = false
  self:_stageMenu()
  self:_beginFade()
end

-- Modifier-only keys never act: they carry no discrete press intent.
local MODIFIER_KEYS = {
  lshift = true,
  rshift = true,
  lctrl = true,
  rctrl = true,
  lalt = true,
  ralt = true,
  lgui = true,
  rgui = true,
}

-- Releases one normalized pointer identity. Touch and mouse releases use
-- the exact identity their press captured, never a doubly prefixed one.
function StartupTitleState:_releasePointer(pointerId, x, y)
  if (self.phase == "loading" or self.phase == "error") and self.loading ~= nil then
    if pointerId:sub(1, 6) == "touch:" and type(self.loading.touchreleased) == "function" then
      self.loading:touchreleased(pointerId:sub(7), x, y)
      return
    elseif pointerId:sub(1, 6) == "mouse:" and type(self.loading.mousereleased) == "function" then
      self.loading:mousereleased(x, y, mouseButtonFromPointerId(pointerId))
      return
    end
  end
  if self.canceledPointers[pointerId] then
    self.canceledPointers[pointerId] = nil
    if self.pointerCapture == pointerId then
      self.pointerCapture = nil
    end
  end
end

-- One discrete press intent for the visible stage: the movie owns its skip
-- while it plays, the title owns its skip once it presents. Neither input
-- leaks into the next stage.
function StartupTitleState:_pressAction()
  if self.phase == "movie" then
    self:_requestMovieSkip()
  else
    self:_requestSkip()
  end
end

function StartupTitleState:keypressed(key, _, isrepeat)
  if isrepeat then
    return
  end
  if
    (self.phase == "loading" or self.phase == "error")
    and self.loading ~= nil
    and type(self.loading.keypressed) == "function"
  then
    self.loading:keypressed(key, _, isrepeat)
    return
  end
  if key == "escape" then
    self.phase = "cancelled"
    if self.onCancel ~= nil then
      self.onCancel()
    end
  elseif key == "r" then
    if self.menuError ~= nil or self.bootstrapError ~= nil then
      self:_retryMenu()
    else
      self:_pressAction()
    end
  elseif not MODIFIER_KEYS[key] then
    self:_pressAction()
  end
end

function StartupTitleState:gamepadpressed(joystick, button)
  if
    (self.phase == "loading" or self.phase == "error")
    and self.loading ~= nil
    and type(self.loading.gamepadpressed) == "function"
  then
    self.loading:gamepadpressed(joystick, button)
    return
  end
  self:_pressAction()
end

function StartupTitleState:mousepressed(x, y, button)
  if button ~= 1 then
    return
  end
  self:_pressPointer("mouse:" .. tostring(button), x, y)
end

function StartupTitleState:mousemoved(x, y)
  if
    (self.phase == "loading" or self.phase == "error")
    and self.loading ~= nil
    and type(self.loading.mousemoved) == "function"
  then
    self.loading:mousemoved(x, y)
  end
end

function StartupTitleState:mousereleased(x, y, button)
  self:_releasePointer("mouse:" .. tostring(button), x, y)
end

function StartupTitleState:touchpressed(id, x, y)
  self:_pressPointer("touch:" .. tostring(id), x, y)
end

function StartupTitleState:touchmoved(id, x, y)
  if
    (self.phase == "loading" or self.phase == "error")
    and self.loading ~= nil
    and type(self.loading.touchmoved) == "function"
  then
    self.loading:touchmoved(id, x, y)
  end
end

function StartupTitleState:touchreleased(id, x, y)
  self:_releasePointer("touch:" .. tostring(id), x, y)
end

function StartupTitleState:focus(focused)
  if not focused then
    if self.loading ~= nil and type(self.loading.focus) == "function" then
      self.loading:focus(false)
    end
    self.pointerCapture = nil
    self.canceledPointers = {}
  end
end

function StartupTitleState:takeStagedMenu()
  assert(
    self.phase == "fadeIn" and self.fadeFrame >= FADE_IN_FRAMES and not self.transferred,
    "menu can transfer only once after the reveal"
  )
  local menu = assert(self.stagedMenu, "the staged menu was already taken")
  self.stagedMenu = nil
  return menu
end

function StartupTitleState:dispose()
  if self.disposed then
    return
  end
  self.disposed = true
  local menu, title, movie, loading = self.stagedMenu, self.title, self.movie, self.loading
  local titleBuild = self.titleBuild
  self.stagedMenu, self.title, self.movie, self.loading = nil, nil, nil, nil
  self.titleBuild = nil
  self.assetRuntime = nil
  self.derivedAssets = nil
  self.audio = nil
  if menu ~= nil then
    menu:dispose()
  end
  if titleBuild ~= nil then
    titleBuild:release()
  end
  if title ~= nil then
    title:dispose()
  end
  if movie ~= nil then
    movie:dispose()
  end
  if loading ~= nil then
    loading:dispose()
  end
end

return StartupTitleState
