-- The Cianwood Gym winch over the field's own owners: the source's refusal
-- order, the committed raised bit at the activation point, the two camera pans
-- with the winch's own animation wait between them, and the settled frames a
-- reload restores.

local Assert = require("tests.support.Assert")
local AnimationPlayer = require("libs.hgss.src.presentation.AnimationPlayer")
local CianwoodGym = require("libs.hgss.src.field.gymmick.CianwoodGym")
local GymMechanismState = require("libs.hgss.src.field.GymMechanismState")

local T = {}

-- A camera that runs one translation path at a time, like the field's own.
local function newCamera()
  local camera = { translations = {}, finished = true, abandoned = 0 }
  function camera:startTranslation(offset, ticks)
    Assert.isTrue(self.finished, "one camera translation path at a time")
    self.finished = false
    self.remaining = ticks
    self.offset = { x = offset.x, y = offset.y, z = offset.z }
    self.translations[#self.translations + 1] = { x = offset.x, y = offset.y, z = offset.z, ticks = ticks }
  end
  function camera:isTranslationFinished()
    return self.finished
  end
  function camera:step()
    if self.finished then
      return
    end
    self.remaining = self.remaining - 1
    if self.remaining <= 0 then
      self.finished = true
    end
  end
  function camera:abandonTranslation()
    self.abandoned = self.abandoned + 1
    self.finished = true
  end
  return camera
end

-- One animated map prop: the live instance the cutscene replays and settles.
local function newProp(name, frameCount)
  local clip = { name = name, frameCount = frameCount, category = "material", kind = "texsrt" }
  local prop = {
    instance = { definition = { animations = { clip } } },
    plays = {},
    stopped = 0,
    playsAtEnd = {},
  }
  function prop:stopAll()
    self.stopped = self.stopped + 1
    self.plays = {}
    self.playsAtEnd = {}
    return 1
  end
  function prop:playAll(_, opts)
    local player = opts and opts.player or AnimationPlayer.new(clip)
    local loopMode = opts and opts.loopMode or nil
    if loopMode ~= nil then
      player.loopMode = loopMode
    end
    local handle = { clip = clip, player = player }
    self.plays[#self.plays + 1] = handle
    return { handle }
  end
  function prop:arePlaysFinished(handles)
    for _, handle in ipairs(handles) do
      if not handle.player:isComplete() then
        return false
      end
    end
    return true
  end
  function prop:restAtEnd()
    self.rested = (self.rested or 0) + 1
    local handle = { clip = clip, player = AnimationPlayer.atEnd(clip) }
    self.playsAtEnd[#self.playsAtEnd + 1] = handle
    return { handle }
  end
  function prop:advance()
    for _, handle in ipairs(self.plays) do
      handle.player:updateFixed()
    end
  end
  return prop
end

local function newHost(options)
  options = options or {}
  local host = {}
  host.camera = newCamera()
  host.waterProp = newProp("mg06_fl1", 3)
  host.winchProp = newProp("mg06_swc", 3)
  host.runtimeMap = {
    mapProps = {
      placements = {
        { placementIndex = 3, modelKey = "indoor:175:abfb66ef8784" },
        { placementIndex = 5, modelKey = "indoor:173:3e8deabe626a" },
        { placementIndex = 9, modelKey = "indoor:172:38fa7436f32b" },
      },
      prop = function(_, placementIndex)
        return placementIndex == 3 and host.winchProp or host.waterProp
      end,
    },
  }
  local kind = options.kind or "cianwood"
  local data = { winchRaised = options.raised == true }
  if kind == "ecruteak" then
    data = { candles = { false, false, false, false } }
  end
  host.state = GymMechanismState.restore({ schema = GymMechanismState.SCHEMA, kind = kind, data = data })
  local camera = host.camera
  if options.noCamera then
    camera = nil
  end
  local runtimeMap = host.runtimeMap
  if options.noRuntimeMap then
    runtimeMap = nil
  end
  host.gym = CianwoodGym.new({ state = host.state, camera = camera, runtimeMap = runtimeMap })
  return host
end

-- One whole cutscene: every tick steps the camera path and the props' clocks.
local function runCutscene(host)
  local ticks = 0
  while not host.gym:isComplete() do
    host.gym:updateFixed()
    host.camera:step()
    host.waterProp:advance()
    host.winchProp:advance()
    ticks = ticks + 1
    assert(ticks < 500, "the winch cutscene never completed")
  end
  return ticks
end

-- The source refusal order: wrong gym, missing mechanism runtime, already
-- raised. A refused activation never commits the bit and never pans.
function T.the_winch_refuses_a_wrong_gym_missing_runtime_and_a_raised_winch()
  local wrongGym = newHost({ kind = "ecruteak" })
  Assert.isFalse(wrongGym.gym:activate(), "a wrong gym refuses the winch")
  Assert.isTrue(wrongGym.gym:isComplete(), "a refused activation owns nothing")

  local noRuntime = newHost({ noRuntimeMap = true })
  Assert.isFalse(noRuntime.gym:activate(), "a missing mechanism runtime refuses the winch")
  Assert.isFalse(noRuntime.state:cianwoodWinchRaised(), "a refusal never raises the winch")
  Assert.equal(#noRuntime.camera.translations, 0)

  local raised = newHost({ raised = true })
  Assert.isFalse(raised.gym:activate(), "an already raised winch refuses a second activation")
  Assert.equal(#raised.camera.translations, 0, "a refused activation never pans")
  Assert.equal(raised.waterProp.stopped, 0, "a refused activation never replays the winch records")
end

-- An accepted activation commits the raised bit at the source point, pans away
-- over the source path, replays both prop records once, waits for the winch
-- prop's own animation and pans back.
function T.an_accepted_winch_commits_the_bit_and_runs_the_source_cutscene()
  local host = newHost()
  Assert.isTrue(host.gym:activate(), "a lowered winch turns")
  Assert.isTrue(host.state:cianwoodWinchRaised(), "the raised bit is committed at the activation point")

  host.gym:updateFixed()
  Assert.deepEqual(host.camera.translations[1], {
    x = CianwoodGym.PAN_OFFSET.x,
    y = CianwoodGym.PAN_OFFSET.y,
    z = CianwoodGym.PAN_OFFSET.z,
    ticks = CianwoodGym.PAN_TICKS,
  })
  for _ = 1, CianwoodGym.PAN_TICKS + 1 do
    host.gym:updateFixed()
    host.camera:step()
  end
  Assert.equal(host.waterProp.stopped, 1, "the water prop drops its own records before the replay")
  Assert.equal(host.waterProp.plays[1].player.loopMode, "once", "the source record plays once")
  Assert.equal(host.winchProp.plays[1].player.loopMode, "once", "the winch record plays once")
  Assert.equal(#host.camera.translations, 1, "the camera waits for the winch before panning back")

  -- The winch's own clip decides the wait, never an elapsed estimate.
  local waitedTicks = 0
  while #host.camera.translations == 1 do
    host.gym:updateFixed()
    host.winchProp:advance()
    waitedTicks = waitedTicks + 1
    assert(waitedTicks < 100, "the cutscene never left its animation wait")
  end
  Assert.equal(waitedTicks - 1, 3, "the winch prop's own clip length decides when the return pan starts")
  Assert.deepEqual(host.camera.translations[2], {
    x = -CianwoodGym.PAN_OFFSET.x,
    y = -CianwoodGym.PAN_OFFSET.y,
    z = -CianwoodGym.PAN_OFFSET.z,
    ticks = CianwoodGym.PAN_TICKS,
  })

  runCutscene(host)
  Assert.isTrue(host.gym:isComplete())
  host.gym:dispose()
  Assert.equal(#host.waterProp.plays, 1, "a settled cutscene leaves its one play in place")
end

-- A headless composition presents no prop instance: the cutscene still runs its
-- exact camera path and commits the bit, with no invented animation clock.
function T.a_composition_without_prop_instances_still_runs_the_camera_path()
  local host = newHost()
  host.waterProp.instance = nil
  host.winchProp.instance = nil
  Assert.isTrue(host.gym:activate())
  runCutscene(host)
  Assert.equal(#host.camera.translations, 2, "both source pans still run")
  Assert.isTrue(host.state:cianwoodWinchRaised())
end

-- GymmickInit_Cianwood restores a raised winch on its last animation frame.
function T.a_reloaded_raised_winch_restores_both_records_on_their_last_frame()
  local host = newHost()
  CianwoodGym.restoreSettled(host.runtimeMap)
  Assert.equal(host.waterProp.rested, 1, "the water record settles on its last frame")
  Assert.equal(host.winchProp.rested, 1, "the winch record settles on its last frame")
  for _, handle in ipairs(host.waterProp.playsAtEnd) do
    Assert.isTrue(handle.player:isComplete(), "the restored record is paused at its end")
  end

  local headless = newHost()
  headless.waterProp.instance = nil
  headless.winchProp.instance = nil
  CianwoodGym.restoreSettled(headless.runtimeMap)
  Assert.isNil(headless.waterProp.rested, "a headless map has no record to settle")
end

-- Cancelling leaves the committed bit and the camera the source's own task
-- leaves behind, and never reports the cutscene as having run.
function T.cancelling_the_cutscene_keeps_the_committed_bit_and_drops_the_path()
  local host = newHost()
  Assert.isTrue(host.gym:activate())
  host.gym:updateFixed()
  host.gym:cancel("the script was cancelled")
  Assert.isTrue(host.state:cianwoodWinchRaised(), "the committed bit is never replayed by cleanup")
  Assert.equal(host.camera.abandoned, 1, "the camera path is dropped once")
  Assert.isTrue(host.gym:isComplete())
  host.gym:dispose()
end

-- A missing camera is a mechanism fault, not a silent refusal.
function T.a_live_runtime_without_a_camera_faults()
  local host = newHost({ noCamera = true })
  local ok, err = pcall(function()
    host.gym:activate()
  end)
  Assert.isFalse(ok, "the winch needs the field camera")
  Assert.equal(type(err), "table")
  Assert.equal(err.code, "FIELD_GYM_MECHANISM_INVALID")
  Assert.isFalse(host.state:cianwoodWinchRaised(), "a fault never commits the raised bit")
end

return { tests = T }
