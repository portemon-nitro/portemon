-- Start Menu / Trainer Card placement must not follow field camera zoom.

local Assert = require("tests.support.Assert")
local FieldSession = require("libs.hgss.src.field.FieldSession")
local ApplicationLayout = require("libs.ui.src.ApplicationLayout")
local ScreenTopology = require("libs.ui.src.ScreenTopology")
local StartMenuInterface = require("game.hgss.src.field.StartMenuInterface")

local T = {}

local function measurementFor(topology, width, height)
  return {
    width = width,
    height = height,
    topology = topology,
    pixelRatio = 1,
    signature = "zoom-probe",
  }
end

local function fullscreenContext(topology, width, height)
  local measurement = measurementFor(topology, width, height)
  local selection = ApplicationLayout.selectSurfaces(measurement)
  return {
    measurement = measurement,
    configuration = "nativeLike",
    primary = selection.primary,
    secondary = selection.secondary,
    nativeLikeInterface = StartMenuInterface.fullscreen,
  }
end

function T.start_menu_plan_identical_across_zooms()
  local topology = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = 640, height = 480 },
    touch = false,
    role = "world",
  })
  local view = {}
  local first = StartMenuInterface.fullscreen(fullscreenContext(topology, 640, 480), view)
  local second = StartMenuInterface.fullscreen(fullscreenContext(topology, 640, 480), view)
  -- Two resolves under different field zooms share one UI fit: the
  -- interface never consumes a camera zoom argument.
  Assert.deepEqual(first.panes[1].placement, second.panes[1].placement)
  -- Different zooms would carry different field scales, but the plan is
  -- the same UI-bounds fit either way.
  local zoomedOut, zoomedIn = 1, 3
  Assert.isTrue(zoomedOut ~= zoomedIn)
  Assert.equal(first.panes[1].placement.pixelScale, 2, "the 640x480 UI fit stays 2x at any zoom")
end

function T.trainer_card_draw_placement_identical_across_zooms()
  local PixelScale = require("libs.ui.src.PixelScale")
  -- Application surfaces resolve one integer-fit placement from UI
  -- bounds and never consume the field camera zoom: the same resolved
  -- placement draws identically twice.
  local placement = assert(
    PixelScale.placeFixed({ x = 0, y = 0, width = 1280, height = 720 }, 256, 192),
    "the probe host must admit a card placement"
  )
  local FieldUiFixture = require("tests.support.FieldUiFixture")
  local FieldTextRenderer = require("libs.hgss.src.ui.FieldTextRenderer")
  local TrainerCardRenderer = require("libs.hgss.src.ui.TrainerCardRenderer")
  local FakeGraphics = require("tests.support.FakeGraphics")
  local lgA = FakeGraphics.new({ imageSizes = { { 16, 16 }, { 16, 16 }, { 96, 32 }, { 256, 256 } } })
  local lgB = FakeGraphics.new({ imageSizes = { { 16, 16 }, { 16, 16 }, { 96, 32 }, { 256, 256 } } })
  local cache = FieldUiFixture.trainerCardCache()
  local manifest = FieldUiFixture.manifest()
  local textA = FieldTextRenderer.new({ cacheFs = cache, graphics = lgA })
  local textB = FieldTextRenderer.new({ cacheFs = cache, graphics = lgB })
  local rA = TrainerCardRenderer.new({ cacheFs = cache, manifest = manifest, text = textA, graphics = lgA })
  local rB = TrainerCardRenderer.new({ cacheFs = cache, manifest = manifest, text = textB, graphics = lgB })
  local presentation = {
    name = "RED",
    trainerId = 12345,
    visibleTrainerId = 12345,
    money = 0,
    playTimeSeconds = 0,
  }
  rA:draw(presentation, placement)
  rB:draw(presentation, placement)
  Assert.deepEqual(
    lgA.transforms,
    lgB.transforms,
    "trainer card transform identical regardless of camera zoom (no zoom plumbing)"
  )
  -- Trainer card is an application surface and stays independent of field zoom;
  -- only field-attached renderers gain zoom-aware transforms.
  rA:release()
  rB:release()
  textA:release()
  textB:release()
end

-- Minimal field session fixture for modal-ownership topology: every world
-- collaborator idles so each tick reaches the script/modal phase, and only
-- the modal hosts under test vary per scenario.
local function idlePlayer()
  return {
    fieldX = 4,
    fieldZ = 13,
    worldX = 0,
    worldY = 0,
    worldZ = 0,
    surfaceId = 0,
    facing = "south",
    motion = "idle",
    updateFixed = function()
      return false
    end,
    collisionCandidatesInto = function(self, out)
      out[1] = { fieldX = self.fieldX, fieldZ = self.fieldZ, surfaceId = self.surfaceId }
      out[2] = nil
      return out
    end,
    clearGesturePresentation = function() end,
    presentationStateInto = function(_, out)
      out.locomotionActive = false
      out.gesturePose = nil
      out.gestureTick = nil
      out.gestureOffsetY = 0
      return out
    end,
    collapseRenderInterpolation = function() end,
  }
end

local function modalSession(overrides)
  local player = idlePlayer()
  player.presentationState = function(self)
    return self:presentationStateInto({})
  end
  local input = {
    batch = { { type = "navigate", direction = "down" } },
    begins = 0,
    clears = 0,
  }
  function input:snapshot()
    return {}
  end
  function input:uiSnapshot(_)
    return self.batch
  end
  function input:beginUi(_)
    self.begins = self.begins + 1
  end
  function input:clearUi()
    self.clears = self.clears + 1
  end
  function input:clearEdges() end
  local scheduler = { seen = {} }
  function scheduler:step(_, schedulerInput)
    self.seen[#self.seen + 1] = schedulerInput
  end
  function scheduler:playerInputLocked()
    return false
  end
  function scheduler:playerInputOwned()
    return false
  end
  function scheduler:foregroundEnvironmentId()
    return nil
  end
  function scheduler:foregroundTrigger()
    return nil
  end
  function scheduler:autonomousActorsLocked()
    return false
  end
  function scheduler:autonomousActorLocked()
    return false
  end
  local options = {
    versionId = "heartgold",
    currentMap = {
      mapId = 61,
      fieldData = { events = { warps = {} } },
      updateAnimated = function() end,
    },
    player = player,
    camera = { updateFixed = function() end },
    transition = {
      phase = "idle",
      locked = false,
      completed = false,
      updateFixed = function()
        return false
      end,
      start = function()
        error("idle transition must never start a warp", 2)
      end,
    },
    actors = {
      beginFixedStep = function() end,
      step = function() end,
      cameraTargetId = function()
        return nil
      end,
    },
    input = input,
    dialogue = {
      isModal = function()
        return false
      end,
    },
    scriptScheduler = scheduler,
    scriptClient = { consume = function() end },
    menuHost = {
      isModal = function()
        return false
      end,
      advance = function() end,
    },
    contextChoice = {
      isActive = function()
        return false
      end,
    },
    signpost = {
      isModal = function()
        return false
      end,
    },
    applicationHost = {
      isActive = function()
        return false
      end,
      updateFixed = function() end,
      requestOpen = function()
        return false
      end,
      takeReopen = function()
        return false
      end,
      status = function() end,
    },
    pcApplications = {
      isActive = function()
        return false
      end,
      cancelPointerCapture = function() end,
    },
    interactions = {
      resolve = function()
        return nil
      end,
    },
    eventResolver = {
      resolveCoordinate = function()
        return nil
      end,
      resolvePassiveSign = function()
        return nil
      end,
    },
    eventState = { getVar = function() end },
    fieldEntranceIndicator = { updateFixed = function() end },
  }
  for key, value in pairs(overrides or {}) do
    options[key] = value
  end
  local session = FieldSession.new(options)
  return session, options
end

function T.overlapping_script_modals_fail_loudly()
  local session = modalSession({
    starterChoice = {
      isActive = function()
        return true
      end,
    },
    martHost = {
      isActive = function()
        return true
      end,
    },
  })
  local err = Assert.throws(function()
    session:updateFixed({})
  end)
  Assert.notNil(tostring(err):find("mutually exclusive", 1, true), "the overlapping script modals are identified")
end

function T.simultaneous_live_and_contextual_choices_are_rejected()
  local session = modalSession({
    contextChoice = {
      isActive = function()
        return true
      end,
    },
    yesNoHost = {
      isModal = function()
        return true
      end,
      inputEvents = function(_, events)
        return events
      end,
      inputEventsFor = function(_, _, events)
        return events
      end,
      clearBorrowedChoice = function() end,
    },
    contextChoicePresentation = function()
      return nil
    end,
  })
  local err = Assert.throws(function()
    session:updateFixed({})
  end)
  Assert.notNil(
    tostring(err):find("field cannot present opcode-63 and contextual two-choice prompts at once", 1, true),
    "the invalid choice composition is identified"
  )
end

function T.unpresentable_choice_keeps_raw_lane_and_stale_gestures_die_with_it()
  local freshBatch = { { type = "navigate", direction = "up" } }
  local translated, clears = nil, 0
  local choiceActive, liveChoice = true, false
  local host = {
    isModal = function()
      return liveChoice
    end,
    inputEvents = function(_, events)
      translated = events
      return { { type = "confirm" } }
    end,
    inputEventsFor = function()
      error("an unpresentable choice must never translate pointer input", 2)
    end,
    clearBorrowedChoice = function()
      clears = clears + 1
    end,
  }
  local session, options = modalSession({
    contextChoice = {
      isActive = function()
        return choiceActive
      end,
    },
    yesNoHost = host,
    contextChoicePresentation = function()
      return nil
    end,
  })
  -- The choice is open but has no screen topology: the tick keeps the raw
  -- lane and keeps the borrowed gesture alive.
  session:updateFixed({ pressedAction = true })
  local scheduler = options.scriptScheduler
  Assert.equal(scheduler.seen[1].uiEvents, options.input.batch, "the scheduler receives the raw snapshot")
  Assert.equal(clears, 0, "an open choice keeps its borrowed capture")
  -- The choice closes: even a fully idle tick drops the borrowed gesture so
  -- a release from the old choice cannot answer a later prompt.
  choiceActive = false
  session:updateFixed({})
  Assert.equal(clears, 1, "an inactive tick clears borrowed pointer capture")
  Assert.isNil(scheduler.seen[2].uiEvents, "no translated choice events reach the scheduler while idle")
  -- A later live prompt is answered by its own fresh snapshot, never the
  -- stale borrowed gesture.
  liveChoice = true
  options.input.batch = freshBatch
  session:updateFixed({ pressedAction = true })
  Assert.equal(translated, freshBatch, "the later prompt translates the fresh snapshot")
  Assert.deepEqual(scheduler.seen[3].uiEvents, { { type = "confirm" } }, "the scheduler consumes the fresh answer")
  Assert.isNil(scheduler.seen[3].pressedAction, "world action stays cleared under the later prompt")
end

return { tests = T }
