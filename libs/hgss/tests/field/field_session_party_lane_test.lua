-- Script party modal input lane: while the script-owned party selection
-- is active, the session forwards one normalized UI snapshot to the
-- scheduler, suppresses the raw field edges for that tick, and balances
-- the modal begin/clear calls on acquire and release. Siblings stay
-- quiet and the session never steps a party controller itself.

local Assert = require("tests.support.Assert")
local FieldSession = require("libs.hgss.src.field.FieldSession")

local T = {}

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

local function recordingInput()
  local input = {
    snapshots = {},
    begins = 0,
    clears = 0,
    batch = { { type = "navigate", direction = "down" } },
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
  return input
end

local function recordingScheduler()
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
  function scheduler:autonomousActorsLocked()
    return false
  end
  function scheduler:autonomousActorLocked()
    return false
  end
  return scheduler
end

local function quietHost()
  return {
    isModal = function()
      return false
    end,
    advance = function() end,
  }
end

local function quietChoice()
  return {
    isActive = function()
      return false
    end,
  }
end

local function partyLane(activeTransitions)
  local lane = { calls = 0 }
  function lane:isActive()
    self.calls = self.calls + 1
    -- Mirrors production: the task opens the host during the scheduler
    -- step, so the lane reads inactive at tick start and active after.
    -- activeFrom/inactiveFrom name isActive call counts (two per tick).
    local from = activeTransitions.activeFrom or 1
    local untilCall = activeTransitions.inactiveFrom
    if untilCall ~= nil and self.calls >= untilCall then
      return false
    end
    return self.calls >= from
  end
  return lane
end

local function optionsWith(overrides)
  local options = {
    versionId = "heartgold",
    currentMap = {
      mapId = 61,
      fieldData = { events = { warps = {} } },
      updateAnimated = function() end,
    },
    player = (function()
      local player = idlePlayer()
      player.presentationState = function(self)
        return self:presentationStateInto({})
      end
      return player
    end)(),
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
    actors = { beginFixedStep = function() end, step = function() end },
    input = recordingInput(),
    dialogue = {
      isModal = function()
        return false
      end,
    },
    scriptScheduler = recordingScheduler(),
    scriptClient = { consume = function() end },
    menuHost = quietHost(),
    contextChoice = quietChoice(),
    starterChoice = nil,
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
  return options
end

function T.active_lane_routes_one_snapshot_and_suppresses_raw_edges()
  local active = { activeFrom = 1 }
  local options = optionsWith({ partySelection = partyLane(active) })
  local session = FieldSession.new(options)
  session:updateFixed({
    heldDirection = nil,
    pressedDirection = "south",
    actionPressed = true,
    cancelPressed = true,
    menuPressed = false,
  })
  local scheduler = options.scriptScheduler
  Assert.isTrue(#scheduler.seen >= 1, "the scheduler steps while the lane is active")
  local last = scheduler.seen[#scheduler.seen]
  Assert.equal(last.uiEvents, options.input.batch, "the lane forwards one normalized snapshot")
  Assert.isNil(last.pressedDirection, "raw direction never reaches script input on the lane")
  Assert.isNil(last.pressedAction, "raw action never reaches script input on the lane")
  Assert.isNil(last.pressedCancel, "raw cancel never reaches script input on the lane")
end

function T.idle_lane_sends_no_snapshot()
  local active = { activeFrom = 10 }
  local options = optionsWith({ partySelection = partyLane(active) })
  local session = FieldSession.new(options)
  session:updateFixed({})
  local scheduler = options.scriptScheduler
  Assert.isTrue(#scheduler.seen >= 1)
  Assert.isNil(scheduler.seen[#scheduler.seen].uiEvents, "an idle lane contributes no UI batch")
end

function T.active_mart_routes_ui_without_replaying_field_edges()
  local active = false
  local mart = {
    isActive = function()
      return active
    end,
  }
  local input = recordingInput()
  local scheduler = recordingScheduler()
  scheduler.step = function(_, _, schedulerInput)
    if #scheduler.seen == 0 then
      active = true
    elseif #scheduler.seen == 2 then
      active = false
    end
    scheduler.seen[#scheduler.seen + 1] = schedulerInput
  end
  local options = optionsWith({ martHost = mart, input = input, scriptScheduler = scheduler })
  local session = FieldSession.new(options)
  session:updateFixed({ pressedDirection = "south", actionPressed = true, cancelPressed = true })
  Assert.equal(input.begins, 1, "opening a mart begins UI capture")
  session:updateFixed({ pressedDirection = "north", actionPressed = true, cancelPressed = true })
  local routed = scheduler.seen[2]
  Assert.equal(routed.uiEvents, input.batch, "the active mart receives the normalized UI batch")
  Assert.isNil(routed.pressedDirection, "field direction is suppressed while the mart is active")
  Assert.isNil(routed.pressedAction, "field action is suppressed while the mart is active")
  Assert.isNil(routed.pressedCancel, "field cancel is suppressed while the mart is active")
  session:updateFixed({})
  Assert.equal(input.clears, 1, "closing a mart clears the captured UI edges")
end

function T.modal_edges_balance_on_acquire_and_release()
  -- Two isActive reads per tick (pre/post scheduler step): active from
  -- the post read of tick 2, idle again from the post read of tick 4.
  local active = { activeFrom = 4, inactiveFrom = 8 }
  local options = optionsWith({ partySelection = partyLane(active) })
  local session = FieldSession.new(options)
  session:updateFixed({})
  Assert.equal(options.input.begins, 0)
  Assert.equal(options.input.clears, 0)
  session:updateFixed({})
  Assert.equal(options.input.begins, 1, "acquiring the lane begins the modal batch once")
  session:updateFixed({})
  Assert.equal(options.input.begins, 1, "a held lane begins nothing again")
  Assert.equal(options.input.clears, 0)
  session:updateFixed({})
  Assert.equal(options.input.clears, 1, "releasing the lane clears the modal batch once")
end

function T.pc_application_owns_the_same_modal_ui_lane_and_balances_capture()
  local active = false
  local input = recordingInput()
  local scheduler = recordingScheduler()
  scheduler.step = function(_, _, schedulerInput)
    if #scheduler.seen == 0 then
      active = true
    elseif #scheduler.seen == 1 then
      active = false
    end
    scheduler.seen[#scheduler.seen + 1] = schedulerInput
  end
  local options = optionsWith({
    input = input,
    scriptScheduler = scheduler,
    pcApplications = {
      isActive = function()
        return active
      end,
      cancelPointerCapture = function() end,
    },
  })
  local session = FieldSession.new(options)
  session:updateFixed({ pressedDirection = "south", actionPressed = true, cancelPressed = true })
  Assert.equal(input.begins, 1, "opening a PC child begins UI capture")
  session:updateFixed({ pressedDirection = "north", actionPressed = true, cancelPressed = true })
  local routed = scheduler.seen[2]
  Assert.equal(routed.uiEvents, input.batch, "the PC child receives the normalized UI snapshot")
  Assert.isNil(routed.pressedDirection, "field direction is suppressed while the PC child is open")
  Assert.isNil(routed.pressedAction, "field action is suppressed while the PC child is open")
  Assert.isNil(routed.pressedCancel, "field cancel is suppressed while the PC child is open")
  Assert.equal(input.clears, 1, "closing the PC child clears captured UI edges")
end

return { tests = T }
