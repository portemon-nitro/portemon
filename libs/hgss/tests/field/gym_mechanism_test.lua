-- The gym mechanism owner: the closed kind dispatch, the single activation
-- lease, the source switch flip, the Ecruteak candle commands and the Cianwood
-- winch, the map-entry reset that retains a connection's union, and the save
-- stability window.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.hgss.src.field.FieldErrors")
local GymMechanism = require("libs.hgss.src.field.GymMechanism")
local GymMechanismState = require("libs.hgss.src.field.GymMechanismState")

local T = {}

local function newHost(options)
  options = options or {}
  local host = { effects = {}, binds = {}, sprites = {}, foreground = options.foreground or "script-a" }
  host.player = {
    fieldX = 15,
    fieldZ = 20,
    worldX = 15.5,
    worldY = 0,
    worldZ = 20.5,
    surfaceId = 0,
    motion = "idle",
    _lease = false,
    beginTransport = function(self)
      self._lease = true
    end,
    applyTransportPose = function(self, x, y, z)
      self.worldX, self.worldY, self.worldZ = x, y, z
    end,
    commitTransport = function(self)
      self._lease = false
    end,
    cancelTransport = function(self)
      self._lease = false
    end,
    beginScriptedAction = function(self)
      self.motion = "walking"
    end,
    advanceScriptedAction = function()
      host.ticks = (host.ticks or 0) + 1
    end,
    commitScriptedAction = function(self)
      self.motion = "idle"
    end,
    currentMap = { mapId = 80, coordinateOrigin = { x = 0, z = 0 } },
  }
  host.actors = {
    partnerId = function()
      return nil
    end,
    getById = function()
      return nil
    end,
    getPosition = function()
      return nil
    end,
    setPresentationOffset = function() end,
    clearPresentationOffset = function() end,
    setSprite = function(_, actorId, spriteId)
      host.sprites[#host.sprites + 1] = { actorId = actorId, spriteId = spriteId }
    end,
  }
  host.followingMon = {
    repositionRelativeToPlayer = function() end,
    moveToPlayer = function() end,
  }
  host.geometry = {
    _raised = false,
    restoreViolet = function(self, raised)
      self._raised = raised
    end,
    isVioletRaised = function(self)
      return self._raised
    end,
    setVioletRaised = function(self, raised)
      self._raised = raised
    end,
    bindMap = function(self, map)
      self._map = map
      host.binds[#host.binds + 1] = map
    end,
    unbind = function(self)
      self._map = nil
    end,
    violetCarWorldY = function(self)
      return self._raised and 31 or 2
    end,
    violetCarWorldPoint = function(self)
      return { x = 15.5, z = 20.5 }
    end,
    floorWorldY = function()
      return 0
    end,
  }
  host.audio = {
    play = function(_, sound)
      host.effects[#host.effects + 1] = "play:" .. sound
    end,
    stop = function(_, sound)
      host.effects[#host.effects + 1] = "stop:" .. sound
    end,
    isEffectWaitComplete = function()
      return host.switchSettled == true
    end,
  }
  host.state = GymMechanismState.restore(options.union)
  host.mechanism = GymMechanism.new({
    state = host.state,
    geometry = host.geometry,
    playerOf = function()
      return host.player
    end,
    actors = host.actors,
    followingMon = host.followingMon,
    audio = host.audio,
    foregroundScript = function()
      return host.foreground
    end,
    trainerEngagement = options.trainerEngagement,
  })
  return host
end

local function union(kind, data)
  return { schema = GymMechanismState.SCHEMA, kind = kind, data = data or {} }
end

-- The presented source props: one renderer-owned model per prop, created by
-- the mechanism and released exactly once.
local function newModelFactory(host)
  host.models = { cars = 0, carUpdates = 0, carDisposals = 0, spiders = {}, started = 0, stopped = 0 }
  return {
    car = function()
      host.models.cars = host.models.cars + 1
      return {
        updateFixed = function()
          host.models.carUpdates = host.models.carUpdates + 1
        end,
        dispose = function()
          host.models.carDisposals = host.models.carDisposals + 1
        end,
      }
    end,
    spider = function(slot)
      host.models.spiders[slot] = { disposed = 0 }
      local record = host.models.spiders[slot]
      return {
        startRideAnimation = function()
          host.models.started = host.models.started + 1
        end,
        stopRideAnimation = function()
          host.models.stopped = host.models.stopped + 1
        end,
        updateFixed = function() end,
        dispose = function()
          record.disposed = record.disposed + 1
        end,
      }
    end,
  }
end

function T.a_mechanism_only_answers_its_own_installed_kind()
  local host = newHost({ union = union("violet", { raised = false }) })
  local err = Assert.throws(function()
    host.mechanism:begin("spinarak", { selector = 1 })
  end)
  Assert.isTrue(Errors.is(err))
  Assert.equal(err.code, FieldErrors.FIELD_GYM_MECHANISM_INVALID)

  local azalea = newHost({ union = union("azalea", { endpoints = { 0, 1, 2, 7 }, switchMask = 0 }) })
  err = Assert.throws(function()
    azalea.mechanism:begin("elevator")
  end)
  Assert.equal(err.code, FieldErrors.FIELD_GYM_MECHANISM_INVALID)

  err = Assert.throws(function()
    azalea.mechanism:begin("unknown_action")
  end)
  Assert.equal(err.code, FieldErrors.FIELD_GYM_MECHANISM_INVALID)
end

-- The winch answers its own refusal boolean for a wrong gym instead of
-- faulting: ScrCmd_CianwoodGymTurnWinch writes false and yields.
function T.the_winch_writes_its_refusal_boolean_for_a_wrong_gym()
  local host = newHost({ union = union("azalea", { endpoints = { 0, 1, 2, 7 }, switchMask = 0 }) })
  host.mechanism:begin("winch")
  Assert.equal(host.mechanism:takeResult(), 0, "a wrong gym answers the source false")
  Assert.equal(host.mechanism:step(), "complete")
end

-- The gym init command installs one kind without touching runtime geometry,
-- exactly like Save_Gymmick_Init: a car the rider stands on cannot be dropped
-- by a re-entry's init script.
function T.gym_init_installs_the_kind_and_leaves_the_runtime_place_alone()
  local host = newHost({ union = union("violet", { raised = true }) })
  host.mechanism:bindMap({ mapId = 135 })
  Assert.isTrue(host.geometry:isVioletRaised(), "the map load restored the settled floor")
  host.mechanism:initialize("azalea")
  Assert.equal(host.state:kind(), "azalea")
  Assert.deepEqual(host.state:spiderEndpoints(), { 0, 1, 2, 7 })
  Assert.isTrue(host.geometry:isVioletRaised(), "the init command never moves the runtime plate")
  host.mechanism:initialize("violet")
  Assert.isFalse(host.state:violetRaised(), "a fresh violet union starts on the lower floor")
end

-- A non-connection entry clears the union and rebinds the destination map; a
-- connection (a rebind with no entry) keeps it, which is the whole difference
-- between the two source paths.
function T.a_non_connection_entry_clears_the_union_and_a_connection_keeps_it()
  local host = newHost({ union = union("azalea", { endpoints = { 0, 3, 5, 7 }, switchMask = 3 }) })
  host.mechanism:bindMap({ mapId = 180 })
  -- A connection: the same map rebinds, and the settled union survives.
  host.mechanism:bindMap({ mapId = 180 })
  Assert.equal(host.state:kind(), "azalea")
  Assert.deepEqual(host.state:spiderEndpoints(), { 0, 3, 5, 7 }, "a connection retains the union")
  Assert.equal(host.state:switchMask(), 3)

  -- A warp entry: the source clears the union and the destination map starts
  -- with no mechanism of its own.
  host.mechanism:enterMap({ mapId = 136 })
  Assert.equal(host.state:kind(), "none")
  Assert.equal(#host.binds, 3, "the entry rebinds the destination map")
end

-- One activation owns the field: a second ride, a second switch, or a gym init
-- while it runs is a busy fault rather than a silent overwrite.
function T.one_activation_owns_the_field()
  local host = newHost({ union = union("violet", { raised = false }) })
  host.mechanism:begin("elevator")
  Assert.isTrue(host.mechanism:isRiding())
  Assert.isFalse(host.mechanism:isStableForSave(), "an in-flight ride is never saved")
  local err = Assert.throws(function()
    host.mechanism:begin("elevator")
  end)
  Assert.equal(err.code, FieldErrors.FIELD_GYM_MECHANISM_BUSY)
  err = Assert.throws(function()
    host.mechanism:initialize("violet")
  end)
  Assert.equal(err.code, FieldErrors.FIELD_GYM_MECHANISM_BUSY)
  Assert.equal(host.mechanism:step(), "riding")
  local status = "riding"
  for _ = 1, 200 do
    if status == "complete" then
      break
    end
    status = host.mechanism:step()
  end
  Assert.equal(status, "complete", "the ride completes after its source ticks")
  Assert.isFalse(host.mechanism:isRiding())
end

-- The save window: a completed ride still belongs to the script frame that
-- started it, so capture stays deferred until that frame released the field.
function T.a_ride_stays_unstable_for_save_until_its_own_frame_ended()
  local host = newHost({ union = union("violet", { raised = false }), foreground = "gym-script" })
  host.mechanism:bindMap({ mapId = 135 })
  host.mechanism:begin("elevator")
  while host.mechanism:step() ~= "complete" do
  end
  Assert.isFalse(host.mechanism:isStableForSave(), "the owning script frame has not released the field")
  Assert.equal(host.foreground, "gym-script")
  host.foreground = nil
  Assert.isTrue(host.mechanism:isStableForSave(), "the settled ride publishes once its frame ended")
end

-- The switch flip commits its own bit in the same tick, plays the source
-- sound, and holds the script only until that sound finished.
function T.the_switch_flip_commits_its_bit_and_waits_for_its_own_sound()
  local host = newHost({ union = union("azalea", { endpoints = { 0, 1, 2, 7 }, switchMask = 0 }) })
  host.mechanism:begin("switch", { switchNumber = 1 })
  Assert.equal(host.state:switchMask(), 2, "switch 1 owns the high bit")
  Assert.deepEqual(host.effects, { "play:" .. GymMechanism.SWITCH_SEQUENCE })
  Assert.equal(host.mechanism:step(), "riding", "the flip waits for the source sound")
  host.switchSettled = true
  Assert.equal(host.mechanism:step(), "complete")
  Assert.isFalse(host.mechanism:isStableForSave(), "the flip's own script frame still owns the field")
  host.foreground = nil
  Assert.isTrue(host.mechanism:isStableForSave())

  local err = Assert.throws(function()
    host.mechanism:begin("switch", { switchNumber = 2 })
  end)
  Assert.equal(err.code, FieldErrors.FIELD_GYM_MECHANISM_INVALID)
end

-- A selector whose source table carries no route completes at once: the script
-- ran, no transport started, and nothing is left owning the field.
function T.a_refused_ride_completes_without_claiming_the_field()
  local host = newHost({ union = union("azalea", { endpoints = { 6, 1, 2, 7 }, switchMask = 0 }) })
  host.mechanism:begin("spinarak", { selector = 6 })
  Assert.isFalse(host.mechanism:isRiding(), "a refused ride never claims the field")
  Assert.equal(host.mechanism:step(), "complete")
  Assert.equal(#host.effects, 0, "a refusal plays no source sound")
  Assert.deepEqual(host.state:spiderEndpoints(), { 6, 1, 2, 7 }, "a refusal commits no endpoint")
end

-- Cancelling restores the ride's own anchor and settled state; every captured
-- bucket is detached from the live union.
function T.cancel_restores_the_ride_and_capture_stays_detached()
  local host = newHost({ union = union("violet", { raised = false }) })
  host.mechanism:bindMap({ mapId = 135 })
  host.mechanism:begin("elevator")
  host.mechanism:step()
  local captured = host.mechanism:capture()
  host.mechanism:cancelRide("cancelled")
  Assert.isFalse(host.mechanism:isRiding())
  Assert.equal(host.effects[#host.effects], "stop:SEQ_SE_DP_ELEBETA", "the cancelled ride releases the motor")
  Assert.isFalse(host.geometry:isVioletRaised(), "a cancelled ascent leaves the car down")
  Assert.deepEqual(captured, { schema = GymMechanismState.SCHEMA, kind = "violet", data = { raised = false } })
  Assert.deepEqual(host.mechanism:capture(), captured, "the cancelled ride committed nothing")
end

-- The completed-step seam: this slice's mechanisms own no committed-step
-- claim, so the field's own owners keep running after the question.
function T.the_completed_step_seam_claims_nothing()
  local host = newHost({ union = union("violet", { raised = false }) })
  Assert.isFalse(host.mechanism:tryClaimCompletedStep({
    mapId = 135,
    fieldX = 15,
    fieldZ = 20,
    surfaceId = 0,
    worldY = 0,
    facing = "north",
  }))
end

-- The settled union decides which runtime-loaded source props are presented:
-- the Violet car on its pad centre tile, the four Azalea Spinarak on their
-- route nodes, and nothing for a cleared union.
function T.the_presentation_matches_the_union_the_map_loaded_with()
  local violet = newHost({ union = union("violet", { raised = true }) })
  violet.mechanism:bindMap(violet.player.currentMap)
  violet.mechanism:setModelFactory(newModelFactory(violet))
  Assert.equal(violet.models.cars, 1, "the violet union loads the car")
  Assert.equal(#violet.models.spiders, 0, "the violet union loads no spider")
  local car = assert(violet.mechanism:presentation().car)
  Assert.equal(car.x, 15.5, "the car stands on its own source tile")
  Assert.equal(car.z, 20.5)
  Assert.equal(car.y, 31, "a raised car stands on the settled upper stop")
  Assert.equal(car.rotationDegrees, 0, "the source loads both props with a null rotation override")

  local lowered = newHost({ union = union("violet", { raised = false }) })
  lowered.mechanism:bindMap(lowered.player.currentMap)
  Assert.equal(assert(lowered.mechanism:presentation().car).y, 2, "a lowered car stands on the lower stop")

  local azalea = newHost({ union = union("azalea", { endpoints = { 0, 1, 2, 7 }, switchMask = 0 }) })
  azalea.mechanism:bindMap(azalea.player.currentMap)
  azalea.mechanism:setModelFactory(newModelFactory(azalea))
  Assert.equal(azalea.models.cars, 0, "the azalea union loads no car")
  Assert.equal(#azalea.models.spiders, 4, "the azalea union loads the source quartet")
  local spiders = assert(azalea.mechanism:presentation().spiders)
  Assert.equal(#spiders, 4)
  Assert.equal(spiders[1].x, -12.5, "endpoint 0 sits on its own column")
  Assert.equal(spiders[1].z, 15, "the source prop stands half a tile north of the node centre")
  Assert.equal(spiders[2].x, -6.5)
  Assert.equal(spiders[3].x, -0.5)
  Assert.equal(spiders[4].z, 0)
  for slot = 1, 4 do
    Assert.equal(spiders[slot].slot, slot)
    Assert.equal(spiders[slot].rotationDegrees, 0)
  end

  azalea.mechanism:initialize(GymMechanismState.NONE)
  Assert.isNil(azalea.mechanism:presentation().spiders, "a cleared union presents no spider")
  for slot = 1, 4 do
    Assert.equal(azalea.models.spiders[slot].disposed, 1, "a cleared union releases its spiders once")
  end
end

-- The car rides with its riders for the whole lift: the source carries both on
-- the same height, so the presented car takes the riding player's height.
function T.the_presented_car_rides_with_its_rider()
  local host = newHost({ union = union("violet", { raised = false }) })
  host.mechanism:bindMap(host.player.currentMap)
  local floor = host.player.worldY
  host.mechanism:begin("elevator")
  host.mechanism:step()
  local carried = host.player.worldY
  Assert.equal(carried, floor + 1, "the first motion tick carried the rider up one tile")
  Assert.equal(assert(host.mechanism:presentation().car).y, carried, "the car holds the rider's carried height")
  host.mechanism:step()
  Assert.equal(assert(host.mechanism:presentation().car).y, host.player.worldY)
  host.mechanism:cancelRide("cancelled")
  Assert.equal(assert(host.mechanism:presentation().car).y, 2, "a cancelled ride drops the car back on its stop")
end

-- A spider's own presentation follows its ride: it leaves the settled node on
-- the first motion tick, plays the source one-shot while it moves, and settles
-- on the destination node the ride commits at arrival.
function T.a_presented_spider_follows_its_ride_and_settles_on_arrival()
  local host = newHost({ union = union("azalea", { endpoints = { 0, 1, 2, 7 }, switchMask = 0 }) })
  host.mechanism:bindMap(host.player.currentMap)
  host.mechanism:setModelFactory(newModelFactory(host))
  host.player.fieldX, host.player.fieldZ = 9, 32
  host.mechanism:begin("spinarak", { selector = 1 })
  local settled = assert(host.mechanism:presentation().spiders)[2]
  Assert.equal(settled.x, -6.5, "the spider starts on its own route node")

  -- The source ride covers 25 tiles at two source units per tick.
  local moving = false
  for _ = 1, 400 do
    local status = host.mechanism:step()
    local current = assert(host.mechanism:presentation().spiders)[2]
    if current.x ~= settled.x or current.z ~= settled.z then
      moving = true
    end
    if status == "complete" then
      break
    end
  end
  Assert.isTrue(moving, "the spider moved with the source route")
  Assert.equal(host.models.started, 1, "the ride plays the source one-shot once")
  Assert.equal(host.models.stopped, 1, "the arrival unloads the one-shot")
  Assert.deepEqual(host.state:spiderEndpoints(), { 0, 5, 2, 7 }, "the ride commits its destination endpoint")
  local arrived = assert(host.mechanism:presentation().spiders)[2]
  Assert.equal(arrived.x, -0.5, "the spider settles on the destination node column")
  Assert.equal(arrived.z, 8, "the spider settles on the destination node row")
  Assert.equal(assert(host.mechanism:presentation().spiders)[1].x, -12.5, "the other spiders stay put")
end

-- A cancelled ride leaves the spider on the node it started from: the settled
-- endpoints never moved, and the one-shot is released.
function T.a_cancelled_ride_leaves_its_spider_on_the_starting_node()
  local host = newHost({ union = union("azalea", { endpoints = { 0, 1, 2, 7 }, switchMask = 0 }) })
  host.mechanism:bindMap(host.player.currentMap)
  host.mechanism:setModelFactory(newModelFactory(host))
  host.player.fieldX, host.player.fieldZ = 9, 32
  host.mechanism:begin("spinarak", { selector = 1 })
  for _ = 1, 12 do
    host.mechanism:step()
  end
  host.mechanism:cancelRide("cancelled")
  Assert.equal(host.models.stopped, 1, "the cancelled ride releases the one-shot")
  Assert.deepEqual(host.state:spiderEndpoints(), { 0, 1, 2, 7 })
  Assert.equal(assert(host.mechanism:presentation().spiders)[2].x, -6.5, "the spider is back on its node")
end

-- Map teardown and the factory reset release every presented prop exactly
-- once; a headless mechanism presents nothing at all.
function T.map_teardown_releases_every_presented_model_once()
  local host = newHost({ union = union("azalea", { endpoints = { 0, 1, 2, 7 }, switchMask = 0 }) })
  host.mechanism:bindMap(host.player.currentMap)
  Assert.equal(#assert(host.mechanism:presentation().spiders), 4, "the snapshot describes the source state")

  host.mechanism:setModelFactory(newModelFactory(host))
  host.mechanism:unbind()
  for slot = 1, 4 do
    Assert.equal(host.models.spiders[slot].disposed, 1, "the map teardown releases spider " .. slot)
  end
  host.mechanism:unbind()
  for slot = 1, 4 do
    Assert.equal(host.models.spiders[slot].disposed, 1, "a second teardown releases nothing again")
  end

  host.mechanism:bindMap(host.player.currentMap)
  host.mechanism:setModelFactory(newModelFactory(host))
  host.mechanism:setModelFactory(nil)
  for slot = 1, 4 do
    Assert.equal(host.models.spiders[slot].disposed, 1, "the factory reset releases the quartet once")
  end
end

-- The candle commands read the source script environment's trainer attributes:
-- slot 0's engaged trainer from the injected engagement context and the last
-- interacted actor from the invocation that carries it, and a wrong gym answers
-- the source no-op.
function T.the_candle_commands_follow_the_source_trainer_attributes()
  local engaged = "map:80:object:3"
  local withoutEngagement = newHost({ union = union("ecruteak", { candles = { false, false, false, false } }) })
  withoutEngagement.actors.getById = function(_, actorId)
    if actorId == engaged then
      return { actorId = actorId, objectEventId = 3 }
    end
    return nil
  end
  withoutEngagement.mechanism:bindMap(withoutEngagement.player.currentMap)
  local ok = pcall(function()
    withoutEngagement.mechanism:bindCandle()
  end)
  Assert.isFalse(ok, "no engaged trainer is the source's own missing-actor path")

  local host = newHost({
    union = union("ecruteak", { candles = { false, false, false, false } }),
    trainerEngagement = {
      engagedActor = function()
        return engaged
      end,
    },
  })
  host.actors.getById = function(_, actorId)
    if actorId == engaged then
      return { actorId = actorId, objectEventId = 3 }
    end
    return nil
  end
  host.mechanism:bindMap(host.player.currentMap)
  host.mechanism:bindCandle()
  Assert.equal(host.mechanism._ecruteak:boundActorId(), engaged, "the engaged trainer's candle follows it")
  host.mechanism:unbindCandle()
  Assert.isNil(host.mechanism._ecruteak:boundActorId(), "unbinding releases the follow")
end

-- A wrong gym answers the source no-op for every candle command and never
-- builds a candle mechanism.
function T.candle_commands_do_nothing_outside_the_ecruteak_union()
  local host = newHost({ union = union("azalea", { endpoints = { 0, 1, 2, 7 }, switchMask = 0 }) })
  host.mechanism:bindCandle()
  host.mechanism:unbindCandle()
  host.mechanism:begin("candle_extinguish", { useLastInteracted = true, lastInteractedActor = "map:80:object:2" })
  Assert.isNil(host.mechanism._ecruteak, "a wrong gym owns no candle mechanism")
  Assert.equal(host.mechanism:step(), "complete", "the same-tick refusal completes without a wait")
end

-- The extinguish command blocks while the source task runs and takes its
-- result-free completion: the union's candle bit is the committed evidence.
function T.extinguishing_a_candle_blocks_until_the_source_task_finished()
  local host = newHost({ union = union("ecruteak", { candles = { false, false, false, false } }) })
  host.mechanism:setModelFactory(newModelFactory(host))
  host.mechanism:bindMap(host.player.currentMap)
  local actorId = "map:80:object:5"
  host.actors.getById = function(_, id)
    if id == actorId then
      return { actorId = id, objectEventId = 5 }
    end
    return nil
  end
  host.mechanism:setModelFactory(nil)

  host.mechanism:begin("candle_extinguish", { useLastInteracted = true, lastInteractedActor = actorId })
  Assert.isTrue(host.mechanism:isRiding(), "the running task owns the field")
  Assert.isFalse(host.mechanism:isStableForSave(), "a running candle task is never saved mid-way")
  local status
  repeat
    status = host.mechanism:step()
  until status == "complete"
  Assert.deepEqual(host.state:ecruteakCandles(), { false, false, false, true }, "the candle bit is committed")
  Assert.isFalse(host.mechanism:isRiding())
  Assert.isNil(host.mechanism:takeResult(), "the candle command answers no output variable")
end

-- The winch command answers its output variable with the source boolean and
-- blocks until the cutscene released the camera; a repeated activation answers
-- false without a second cutscene.
function T.the_winch_command_answers_the_source_boolean()
  local host = newHost({ union = union("cianwood", { winchRaised = false }) })
  host.mechanism:bindMap(host.player.currentMap)
  host.camera = nil
  local camera = {
    translations = {},
    finished = true,
    startTranslation = function(self, offset, ticks)
      self.finished = false
      self.remaining = ticks
      self.translations[#self.translations + 1] = { x = offset.x, z = offset.z, ticks = ticks }
    end,
    isTranslationFinished = function(self)
      return self.finished
    end,
    abandonTranslation = function(self)
      self.finished = true
    end,
  }
  host.mechanism._camera = camera

  host.mechanism:begin("winch")
  Assert.equal(host.mechanism:takeResult(), 1, "the source boolean is one for an accepted turn")
  Assert.isTrue(host.mechanism:isRiding(), "the cutscene owns the field")
  Assert.isTrue(host.state:cianwoodWinchRaised(), "the raised bit is committed at the activation point")

  local ticks = 0
  while host.mechanism:step() ~= "complete" do
    if not camera.finished then
      camera.remaining = camera.remaining - 1
      camera.finished = camera.remaining <= 0
    end
    ticks = ticks + 1
    assert(ticks < 500, "the cutscene never released the field")
  end
  Assert.equal(#camera.translations, 2, "the accepted turn pans out and back")
  Assert.deepEqual(camera.translations[1], { x = 50, z = 58, ticks = 24 })
  Assert.deepEqual(camera.translations[2], { x = -50, z = -58, ticks = 24 })

  host.mechanism:begin("winch")
  Assert.equal(host.mechanism:takeResult(), 0, "an already raised winch answers the source false")
  Assert.equal(host.mechanism:step(), "complete", "a refused turn yields without a cutscene")
  Assert.equal(#camera.translations, 2, "a refused turn never pans")
end

-- A raised winch union on a map load restores the gym's settled props; the
-- Ecruteak union installs the gym's own fog on the loaded map.
function T.a_loaded_union_restores_the_gyms_own_map_state()
  local fog = { enabled = true }
  local ecruteak = newHost({ union = union("ecruteak", { candles = { true, false, false, false } }) })
  ecruteak.player.currentMap.renderEnvironment = { fog = fog }
  ecruteak.mechanism:bindMap(ecruteak.player.currentMap)
  Assert.equal(ecruteak.player.currentMap.renderEnvironment.fog, require("libs.hgss.src.field.gymmick.EcruteakGym").FOG)

  local cianwood = newHost({ union = union("cianwood", { winchRaised = true }) })
  local rested = {}
  cianwood.player.currentMap.mapProps = {
    placements = {
      { placementIndex = 1, modelKey = "indoor:175:abfb66ef8784" },
      { placementIndex = 2, modelKey = "indoor:173:3e8deabe626a" },
    },
    prop = function(_, placementIndex)
      return {
        instance = {},
        restAtEnd = function()
          rested[#rested + 1] = placementIndex
        end,
      }
    end,
  }
  cianwood.mechanism:bindMap(cianwood.player.currentMap)
  table.sort(rested)
  Assert.deepEqual(rested, { 1, 2 }, "a raised winch restores both settled records")

  local lowered = newHost({ union = union("cianwood", { winchRaised = false }) })
  lowered.player.currentMap.mapProps = cianwood.player.currentMap.mapProps
  lowered.mechanism:bindMap(lowered.player.currentMap)
  Assert.deepEqual(rested, { 1, 2 }, "a lowered winch restores nothing")
end

return { tests = T }
