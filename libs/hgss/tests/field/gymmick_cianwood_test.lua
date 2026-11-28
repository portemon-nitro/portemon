-- The Cianwood Gym winch over the field's own owners: the source's refusal
-- order, the committed raised bit at the activation point, the two camera pans
-- with the winch's own animation wait between them, and the settled frames a
-- reload restores.

local Assert = require("tests.support.Assert")
local CianwoodGym = require("libs.hgss.src.field.gymmick.CianwoodGym")
local GymMechanismState = require("libs.hgss.src.field.GymMechanismState")
local MapProps = require("libs.hgss.src.world.MapProps")
local ModelDefinition = require("libs.hgss.src.presentation.ModelDefinition")
local ModelInstance = require("libs.hgss.src.presentation.ModelInstance")

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

-- A real model instance over synthetic compiled clips. The water definition
-- already owns the producer-bound 174 records; no foreign clip is ever
-- attached at runtime. Record kinds are distinct because the real animation
-- state permits one active attachment per kind.
local function clip(id, name, kind, frameCount)
  return {
    id = id,
    name = name,
    category = "material",
    kind = kind,
    frameCount = frameCount,
    tracks = { { target = "surface" } },
    semanticNames = {},
    compiled = {},
  }
end

local function instanceFor(key, clips)
  return ModelInstance.new(ModelDefinition.new({
    key = key,
    nodes = { { index = 0 } },
    meshes = { { id = 0, nodeIndex = 0, materialIndex = 0 } },
    materials = { {
      id = 0,
      name = "surface",
      alphaMode = "opaque",
      baseColor = { r = 255, g = 255, b = 255, a = 255 },
      polygonAlpha = 255,
    } },
    animations = clips,
  }))
end

local function attachments(prop)
  local instance = prop and prop.instance
  if instance == nil then
    return {}
  end
  local out = {}
  for _, category in ipairs({ "joint", "material" }) do
    for _, handle in ipairs(instance.animationState:attachments(category)) do
      out[#out + 1] = handle
    end
  end
  return out
end

local function attachmentIds(prop)
  local ids = {}
  for _, handle in ipairs(attachments(prop)) do
    ids[#ids + 1] = handle.clip.id
  end
  return ids
end

local function advanceProp(prop)
  if prop ~= nil and prop.instance ~= nil then
    prop.instance:updateFixed()
  end
end

local function newHost(options)
  options = options or {}
  local host = {}
  host.camera = newCamera()
  -- The water target owns an unrelated record that must never play, plus the
  -- exact two records prebound from source 174 by the producer.
  local water = instanceFor("indoor:173:bound", {
    clip("water_own", "water_own", "texsrt", 9),
    clip("cianwood.water.1.texsrt", "fall_a", "texsrt", 7),
    clip("cianwood.water.2.pattern", "fall_b", "pattern", 5),
  })
  -- The winch owns record 0 (frame 4) and a longer record 1 (frame 10): the
  -- cutscene must wait for record 0, never the longest channel.
  local winch = instanceFor("indoor:175:bound", {
    clip("cianwood.winch.0.color", "winch0", "color", 4),
    clip("winch1", "winch1", "texsrt", 10),
  })
  local props = MapProps.new({
    placements = {
      { placementIndex = 3, modelKey = "indoor:175:4cad5f7bf8ee" },
      { placementIndex = 5, modelKey = "indoor:173:0e0db61c0496" },
      { placementIndex = 9, modelKey = "indoor:172:38fa7436f32b" },
    },
    instances = { [3] = winch, [5] = water },
    doorTiles = {},
  })
  host.waterProp = assert(props:prop(5))
  host.winchProp = assert(props:prop(3))
  -- Source 174 has no placement in this map. Its records are already bound to
  -- 173, so neither playback nor reload may search for a live 174 instance.
  host.runtimeMap = {
    mapProps = props,
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
    advanceProp(host.waterProp)
    advanceProp(host.winchProp)
    ticks = ticks + 1
    assert(ticks < 500, "the winch cutscene never completed")
  end
  return ticks
end

-- The source camera path is (50, 0, 58) native world units at 16 per tile:
-- (3.125, 0, 3.625) tiles over 24 frames each way. Independently derived,
-- not from the constant under test.
function T.the_pan_offset_is_the_source_world_units_in_tiles()
  Assert.near(CianwoodGym.PAN_OFFSET.x, 50 / 16, 1e-9, "pan x is 50 world units in tiles")
  Assert.near(CianwoodGym.PAN_OFFSET.y, 0, 1e-9)
  Assert.near(CianwoodGym.PAN_OFFSET.z, 58 / 16, 1e-9, "pan z is 58 world units in tiles")
  Assert.equal(CianwoodGym.PAN_TICKS, 24, "the source pans 24 frames each way")
end

function T.the_pan_moves_the_real_camera_by_the_tile_offset()
  local FieldCamera = require("libs.hgss.src.field.FieldCamera")
  local camera = FieldCamera.new({
    projectionType = "perspective",
    distanceTiles = 10,
    angleXRaw = -8192,
    angleYRaw = 0,
    halfFovRadians = math.rad(15),
    fullVerticalFovRadians = math.rad(30),
    nearTiles = 1,
    farTiles = 100,
    targetOffsetTiles = { x = 0, y = 0, z = 0 },
  }, { initialTarget = { x = 7, y = 0, z = 11 } })
  camera:startTranslation(CianwoodGym.PAN_OFFSET, CianwoodGym.PAN_TICKS)
  for _ = 1, CianwoodGym.PAN_TICKS do
    camera:updateFixed({ x = 7, y = 0, z = 11 })
  end
  Assert.near(camera.target.x, 7 + 50 / 16, 1e-9, "the pan centers the tile-space waterfall area")
  Assert.near(camera.target.z, 11 + 58 / 16, 1e-9)
  Assert.isTrue(camera:isTranslationFinished())
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
  Assert.equal(#attachments(raised.waterProp), 0, "a refused activation never replays the winch records")
end

-- An accepted activation commits the raised bit at the source point, pans away
-- over the source path, replays the bound waterfall records and winch record 0
-- once, waits for winch record 0 and pans back, with distinct START_ANIM and
-- PAN_BACK ticks.
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
  -- WAIT_PAN: the pan runs its 24 frames with no animation yet.
  for _ = 1, CianwoodGym.PAN_TICKS do
    host.gym:updateFixed()
    host.camera:step()
    Assert.equal(#attachments(host.waterProp), 0, "no replay during the outward pan")
  end
  Assert.equal(#host.camera.translations, 1)
  host.gym:updateFixed()
  host.camera:step()
  Assert.equal(#attachments(host.waterProp), 0, "WAIT_PAN completion only advances to START_ANIM")
  Assert.equal(#host.camera.translations, 1, "the camera waits for the winch before panning back")
  -- START_ANIM runs on its own tick.
  host.gym:updateFixed()
  Assert.deepEqual(attachmentIds(host.waterProp), {
    "cianwood.water.1.texsrt",
    "cianwood.water.2.pattern",
  }, "the water replays every producer-bound 174 record, not its own")
  Assert.deepEqual(attachmentIds(host.winchProp), { "cianwood.winch.0.color" }, "the winch replays only record 0")
  for _, handle in ipairs(attachments(host.waterProp)) do
    Assert.equal(handle.player.loopMode, "once", "each waterfall record plays once")
  end
  Assert.equal(attachments(host.winchProp)[1].player.loopMode, "once", "winch record 0 plays once")
  Assert.equal(#host.camera.translations, 1, "START_ANIM does not pan")
  -- WAIT_ANIM waits for winch record 0 (4 frames), not the longer record 1.
  -- The completion tick advances to the distinct PAN_BACK state; the next
  -- tick starts the return pan, so the loop observes one extra state tick.
  local waitedTicks = 0
  while #host.camera.translations == 1 do
    host.gym:updateFixed()
    advanceProp(host.winchProp)
    advanceProp(host.waterProp)
    waitedTicks = waitedTicks + 1
    assert(waitedTicks < 100, "the cutscene never left its animation wait")
  end
  Assert.equal(waitedTicks - 2, 4, "winch record 0's own clip length decides when the return pan starts")
  Assert.deepEqual(host.camera.translations[2], {
    x = -CianwoodGym.PAN_OFFSET.x,
    y = -CianwoodGym.PAN_OFFSET.y,
    z = -CianwoodGym.PAN_OFFSET.z,
    ticks = CianwoodGym.PAN_TICKS,
  })

  runCutscene(host)
  Assert.isTrue(host.gym:isComplete())
  host.gym:dispose()
  Assert.equal(#attachments(host.waterProp), 2, "a settled cutscene leaves both waterfall plays in place")
  Assert.equal(#attachments(host.winchProp), 1, "a settled cutscene leaves only winch record 0 in place")
end

-- A headless composition presents no prop instance: the cutscene still runs its
-- exact camera path and commits the bit, with no invented animation clock.
function T.a_composition_without_prop_instances_still_runs_the_camera_path()
  local host = newHost()
  host.waterProp.instance = nil
  host.winchProp.instance = nil
  host.runtimeMap.mapProps.instances[5] = nil
  host.runtimeMap.mapProps.instances[3] = nil
  Assert.isTrue(host.gym:activate())
  runCutscene(host)
  Assert.equal(#host.camera.translations, 2, "both source pans still run")
  Assert.isTrue(host.state:cianwoodWinchRaised())
end

-- GymmickInit_Cianwood restores a raised winch on its last animation frame:
-- the water target restores every 174 record, the winch restores only record 0.
function T.a_reloaded_raised_winch_restores_both_records_on_their_last_frame()
  local host = newHost()
  host.waterProp:play("water_own")
  CianwoodGym.restoreSettled(host.runtimeMap)
  Assert.deepEqual(attachmentIds(host.waterProp), {
    "cianwood.water.1.texsrt",
    "cianwood.water.2.pattern",
  }, "the settle restores every producer-bound 174 record")
  Assert.deepEqual(attachmentIds(host.winchProp), { "cianwood.winch.0.color" }, "the settle restores only winch record 0")
  for _, handle in ipairs(attachments(host.waterProp)) do
    Assert.isTrue(handle.player:isComplete(), "each restored record is paused at its end")
  end
  for _, handle in ipairs(attachments(host.winchProp)) do
    Assert.isTrue(handle.player:isComplete(), "the restored winch record is paused at its end")
  end

  local headless = newHost()
  headless.waterProp.instance = nil
  headless.winchProp.instance = nil
  headless.runtimeMap.mapProps.instances[5] = nil
  headless.runtimeMap.mapProps.instances[3] = nil
  CianwoodGym.restoreSettled(headless.runtimeMap)
  Assert.equal(#attachments(headless.waterProp), 0, "a headless map has no record to settle")
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
