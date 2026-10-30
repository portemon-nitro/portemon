-- Return-warp adaptation over the borrowed maps service: Dig resolves
-- the recorded special spawn, Teleport resolves
-- the recorded heal spawn through the injected cited landing
-- destinations (unknown keys fail loudly, never a guess), warps start
-- exactly once with destination-local coordinates, completion and
-- failures surface through the service protocol, and nothing is owned.

local Errors = require("libs.errors.src.Errors")
local Assert = require("tests.support.Assert")
local FieldMoveCutInBannerAssetCache = require("libs.assets.src.field.FieldMoveCutInBannerAssetCache")
local FieldMoveWorld = require("game.hgss.src.field.FieldMoveWorld")
local FieldWarpSequence = require("libs.hgss.src.field.FieldWarpSequence")

local T = {}

-- Structural service double for return warps: records starts with plain
-- data so assertions read recorded values, never live references.
---@class ReturnWarpsDouble
---@field origin table<string, integer>
---@field done boolean
---@field errorValue unknown
---@field started table<string, unknown>?
---@field placement fun(self: ReturnWarpsDouble, ref: unknown): { id: integer, originX: integer, originZ: integer }
---@field startWarp fun(self: ReturnWarpsDouble, target: table<string, unknown>)
---@field warpDone fun(self: ReturnWarpsDouble): boolean
---@field pendingError fun(self: ReturnWarpsDouble): unknown

local function warpsDouble()
  local calls = { start = 0 }
  local service = {
    started = nil,
    done = false,
    errorValue = nil,
    origin = { x = 600, z = 300 },
    placement = function(self, ref)
      if ref ~= "MAP_ROUTE_46" then
        Errors.raise("FIELD_MAP_UNKNOWN", "no runtime map for " .. tostring(ref), {})
      end
      return { id = 48, originX = self.origin.x, originZ = self.origin.z }
    end,
    startWarp = function(self, target)
      calls.start = calls.start + 1
      self.started = target
    end,
    warpDone = function(self)
      return self.done
    end,
    pendingError = function(self)
      return self.errorValue
    end,
  } ---@type ReturnWarpsDouble
  return service, calls
end

local function worldWith(warps, spawns, travel)
  local function stub()
    return function() end
  end
  return FieldMoveWorld.new({
    actors = {
      getActor = stub(),
      actorsOf = stub(),
      getPosition = stub(),
      getCollisionAt = stub(),
      beginScriptedAction = stub(),
      advanceScriptedAction = stub(),
      commitScriptedAction = stub(),
      cancelScriptedMovement = stub(),
      isScriptedMoving = stub(),
      removePresence = stub(),
      syncEventStateChanges = stub(),
    },
    events = { setFlag = stub(), isFlagSet = stub() },
    maps = {
      current = function()
        return {}
      end,
      runtimeMap = function()
        return {}
      end,
    },
    player = {
      position = stub(),
      facing = stub(),
      beginScriptedAction = stub(),
      advanceScriptedAction = stub(),
      commitScriptedAction = stub(),
      cancelScriptedMovement = stub(),
      isScriptedMoving = stub(),
      queueAvatarTransition = stub(),
      applyAvatarTransitions = stub(),
    },
    profile = { badges = 0 },
    weather = { change = stub() },
    reactions = { dispatch = stub() },
    warps = warps,
    spawns = spawns,
    travel = travel,
  })
end

local function travelWith(special)
  return {
    lastHealSpawn = "SPAWN_NEW_BARK",
    specialSpawn = special,
  }
end

local function contextWith()
  return { mapId = 176 }
end

function T.plan_return_dig_resolves_the_recorded_special_spawn()
  local warps = warpsDouble()
  local world = worldWith(warps)
  local special = { map = "MAP_ROUTE_46", fieldX = 628, fieldZ = 329, warpId = -1, direction = "north" }
  local destination = world:planReturn("dig", contextWith(), travelWith(special))
  Assert.equal(destination.map, "MAP_ROUTE_46", "dig exits through the recorded map")
  Assert.equal(destination.fieldX, 628, "dig keeps destination-global record tiles")
  Assert.equal(destination.fieldZ, 329, "dig keeps destination-global record tiles")
  Assert.equal(destination.facing, "north", "dig arrives facing the recorded direction")
  Assert.isNil(destination.specialSpawnKey, "dig reads the special spawn and never rewrites it")
end

function T.plan_return_dig_without_a_special_spawn_reports_not_now()
  local warps = warpsDouble()
  local world = worldWith(warps)
  local decision = world:planReturn("dig", contextWith(), travelWith(nil))
  Assert.equal(decision.kind, "not_now", "dig with no recorded special spawn is not now, never a guess")
end

function T.plan_return_teleport_resolves_the_recorded_heal_spawn()
  local warps = warpsDouble()
  local spawns = {
    destinationFor = function(_, key)
      assert(key == "SPAWN_NEW_BARK", "resolution requests the recorded spawn")
      return { map = "MAP_NEW_BARK", fieldX = 695, fieldZ = 397 }
    end,
    specialFor = function() end,
  }
  local world = worldWith(warps, spawns)
  local destination = world:planReturn("teleport", contextWith(), travelWith(nil))
  Assert.equal(destination.map, "MAP_NEW_BARK", "teleport exits through the recorded spawn map")
  Assert.equal(destination.fieldX, 695, "teleport keeps destination-global record tiles")
  Assert.equal(destination.fieldZ, 397, "teleport keeps destination-global record tiles")
  Assert.equal(destination.facing, "south", "teleport stamps the standard arrival facing")
end

function T.beginning_a_teleport_rewrites_the_special_spawn_after_the_warp_starts()
  local warps = warpsDouble()
  local written = {}
  local spawns = {
    destinationFor = function()
      return { map = "MAP_ROUTE_46", fieldX = 628, fieldZ = 329 }
    end,
    specialFor = function(_, key)
      assert(key == "SPAWN_NEW_BARK", "the rewrite names the spawn teleport leaves for")
      return { map = "MAP_NEW_BARK", fieldX = 695, fieldZ = 397, warpId = -1, direction = "south" }
    end,
  }
  local travel = {
    setSpecialSpawn = function(_, spawn)
      assert(warps.started ~= nil, "the rewrite follows the warp start")
      written[#written + 1] = spawn
    end,
  }
  local world = worldWith(warps, spawns, travel)
  local destination = world:planReturn("teleport", contextWith(), travelWith(nil))
  world:beginReturnWarp({ kind = "teleport", destination = destination })
  Assert.equal(#written, 1, "the special spawn is rewritten exactly once")
  Assert.equal(written[1].map, "MAP_NEW_BARK", "the rewritten record is the cited special spawn")
  Assert.equal(written[1].direction, "south", "special spawn records always face south")
end

function T.plan_return_teleport_with_an_uncited_spawn_fails_loudly()
  local warps = warpsDouble()
  local spawns = {
    destinationFor = function(_, _)
      return nil
    end,
    specialFor = function() end,
  }
  local world = worldWith(warps, spawns)
  local ok, err = pcall(function()
    world:planReturn("teleport", contextWith(), travelWith(nil))
  end)
  Assert.isFalse(ok, "an uncited spawn must never warp somewhere convenient")
  Assert.notNil(tostring(err):find("SPAWN_NEW_BARK", 1, true), "the refusal names the spawn")
end

function T.plan_return_teleport_without_destinations_is_a_programming_error()
  local warps = warpsDouble()
  local world = worldWith(warps, nil)
  local ok = pcall(function()
    world:planReturn("teleport", contextWith(), travelWith(nil))
  end)
  Assert.isFalse(ok, "teleport without destinations must fail loudly, never guess")
end

function T.begin_starts_the_warp_exactly_once_with_local_coordinates()
  local warps = warpsDouble()
  local world = worldWith(warps)
  local special = { map = "MAP_ROUTE_46", fieldX = 628, fieldZ = 329, warpId = -1, direction = "south" }
  local destination = world:planReturn("dig", contextWith(), travelWith(special))
  local plan = { kind = "dig", destination = destination }
  world:beginReturnWarp(plan)
  local started = assert(warps.started, "the warp must start")
  Assert.equal(started.map, "MAP_ROUTE_46", "the warp targets the recorded map")
  Assert.equal(started.fieldX, 28, "the warp carries destination-local tiles")
  Assert.isTrue(plan.warpStarted, "the plan records its single start")
  local ok = pcall(function()
    world:beginReturnWarp(plan)
  end)
  Assert.isFalse(ok, "a second start must not silently re-warp")
  local restated = assert(warps.started, "the single start persists")
  Assert.isTrue(restated.map == "MAP_ROUTE_46", "no duplicate start reaches the service")
end

function T.done_and_error_read_the_service_protocol()
  local warps = warpsDouble()
  local world = worldWith(warps)
  local plan = { kind = "dig", destination = { map = "M", warp = 0, fieldX = 1, fieldZ = 2, facing = "south" } }
  Assert.isFalse(world:returnWarpDone(plan), "an unfinished warp is not done")
  Assert.isNil(world:returnWarpError(plan), "no error surfaces before completion")
  warps.done = true
  Assert.isTrue(world:returnWarpDone(plan), "a finished warp reports done")
  warps.errorValue = { kind = "stale" }
  Assert.deepEqual(world:returnWarpError(plan), { kind = "stale" }, "service failures surface verbatim")
end

function T.unresolvable_destination_refuses_with_the_service_code()
  local warps = warpsDouble()
  local world = worldWith(warps)
  local plan = {
    kind = "dig",
    destination = { map = "MAP_NOWHERE", warp = 0, fieldX = 1, fieldZ = 2, facing = "south" },
  }
  local ok, err = pcall(function()
    world:beginReturnWarp(plan)
  end)
  Assert.isFalse(ok, "an unresolvable destination must not start")
  Assert.isTrue(Errors.is(err), "resolution failure stays a structured error")
  ---@cast err Errors.Error
  Assert.equal(err.code, "SCRIPT_INVALID_REFERENCE", "unknown maps refuse with the service code")
  Assert.isFalse(plan.warpStarted == true, "a refused start marks nothing")
end

function T.unknown_moves_and_malformed_travel_fail_loudly()
  local warps = warpsDouble()
  local world = worldWith(warps)
  local ok = pcall(function()
    world:planReturn("cut", contextWith(), travelWith(nil))
  end)
  Assert.isFalse(ok, "return planning accepts only dig and teleport")
  local bad = pcall(function()
    world:planReturn("dig", contextWith(), {})
  end)
  Assert.isFalse(bad, "return planning requires a travel record")
end

-- Fly presentation doubles: the live camera for the landing zoom, the
-- script screen-fade owner for the warp covers, the lead cry, and the
-- cut-in/landing presenter fed by the staged banner class.
local function cameraDouble()
  local camera = { distance = 10, sets = {} }
  function camera:distanceTiles()
    return self.distance
  end
  function camera:setDistanceTiles(tiles)
    self.distance = tiles
    self.sets[#self.sets + 1] = tiles
  end
  return camera
end

local function screenDouble()
  local screen = { lease = 0, doneValue = false, cleared = {} }
  function screen:startFade(_)
    self.lease = self.lease + 1
    self.doneValue = false
    return self.lease
  end
  function screen:fadeDone()
    return self.doneValue
  end
  function screen:clearIfCurrent(lease)
    self.cleared[#self.cleared + 1] = lease
  end
  return screen
end

local function cryDouble()
  return {
    started = 0,
    doneValue = true,
    start = function(self, slot)
      self.started = self.started + 1
      self.slot = slot
    end,
    done = function(self)
      return self.doneValue
    end,
  }
end

local function bannerManifest()
  return {
    schema = FieldMoveCutInBannerAssetCache.SCHEMA,
    reference = {
      width = FieldMoveCutInBannerAssetCache.BANNER_WIDTH,
      height = FieldMoveCutInBannerAssetCache.BANNER_HEIGHT,
    },
    assets = {
      banner = {
        image = "assets/generated/field/cutin-banner/banner.png",
        width = FieldMoveCutInBannerAssetCache.BANNER_WIDTH,
        height = FieldMoveCutInBannerAssetCache.BANNER_HEIGHT,
      },
    },
    banner = "banner",
    paletteSlot = FieldMoveCutInBannerAssetCache.PALETTE_SLOT,
  }
end

local function cutinDouble(manifest)
  local cutin = {
    manifest = manifest,
    starts = {},
    landings = 0,
    bannerDoneValue = false,
    climbedValue = false,
    landingDoneValue = false,
    cancels = {},
  }
  function cutin:startCutIn(args)
    self.starts[#self.starts + 1] = args
  end
  function cutin:cutInDone()
    return self.bannerDoneValue
  end
  function cutin:cancelCutIn()
    self.cancels[#self.cancels + 1] = "cutin"
  end
  function cutin:startLanding()
    self.landings = self.landings + 1
  end
  function cutin:landingClimbed()
    return self.climbedValue
  end
  function cutin:landingDone()
    return self.landingDoneValue
  end
  function cutin:cancelLanding()
    self.cancels[#self.cancels + 1] = "landing"
  end
  return cutin
end

local function flyWorldWith(overrides)
  overrides = overrides or {}
  local function stub()
    return function() end
  end
  local camera = cameraDouble()
  local screen = screenDouble()
  local cry = cryDouble()
  return FieldMoveWorld.new({
    actors = {
      getActor = stub(),
      actorsOf = stub(),
      getPosition = stub(),
      getCollisionAt = stub(),
      beginScriptedAction = stub(),
      advanceScriptedAction = stub(),
      commitScriptedAction = stub(),
      cancelScriptedMovement = stub(),
      isScriptedMoving = stub(),
      removePresence = stub(),
      syncEventStateChanges = stub(),
    },
    events = { setFlag = stub(), isFlagSet = stub() },
    maps = {
      current = function()
        return {}
      end,
      runtimeMap = function()
        return {}
      end,
    },
    player = {
      position = stub(),
      facing = stub(),
      beginScriptedAction = stub(),
      advanceScriptedAction = stub(),
      commitScriptedAction = stub(),
      cancelScriptedMovement = stub(),
      isScriptedMoving = stub(),
      queueAvatarTransition = stub(),
      applyAvatarTransitions = stub(),
    },
    profile = { badges = 0 },
    weather = { change = stub() },
    reactions = { dispatch = stub() },
    camera = function()
      return camera
    end,
    screen = screen,
    cry = cry,
    audio = overrides.audio,
    party = overrides.party,
    cutin = overrides.cutin,
  }),
    camera,
    screen,
    cry
end

local function flyPlan(slot)
  return { kind = "fly", sequence = FieldWarpSequence.new("fly"), slot = slot or 0 }
end

local function driveDeparture(world, plan, screen, limit)
  local bound = limit or 40
  if type(screen) == "number" then
    bound = screen
    screen = nil
  end
  for _ = 1, bound do
    local result = world:stepWarpDeparture(plan)
    if result ~= "running" then
      return result
    end
    -- The screen cover completes only after its fade starts: starting the
    -- cover resets the completion flag, so a flag set before the start
    -- never settles. Mark completion after each running tick so the cover
    -- started on that tick completes on the next one.
    if screen ~= nil then
      screen.doneValue = true
    end
  end
  error("fly departure never settled", 0)
end

function T.fly_departure_presents_the_staged_banner_before_the_white_cover()
  local cutin = cutinDouble(bannerManifest())
  local world, _, screen, cry = flyWorldWith({ cutin = cutin })
  local plan = flyPlan(2)
  Assert.equal(world:stepWarpDeparture(plan), "running")
  Assert.equal(cry.started, 1, "the departure cries the departing slot")
  Assert.equal(cry.slot, 2, "the cry names the plan slot")
  Assert.equal(world:stepWarpDeparture(plan), "running")
  Assert.equal(#cutin.starts, 1, "the cry hands off to the cut-in presenter")
  Assert.equal(cutin.starts[1].slot, 2, "the cut-in names the departing slot")
  local banner = assert(cutin.starts[1].banner, "the cut-in carries the staged banner")
  Assert.equal(banner.key, "banner", "the cut-in selects the semantic staged banner")
  Assert.equal(banner.image, "assets/generated/field/cutin-banner/banner.png")
  Assert.equal(banner.width, 256, "the cut-in carries the staged banner width")
  Assert.equal(banner.height, 256, "the cut-in carries the staged banner height")
  Assert.equal(banner.paletteSlot, 12, "the cut-in carries the staged hardware palette slot")
  Assert.equal(world:stepWarpDeparture(plan), "running", "an unfinished cut-in holds the departure")
  cutin.bannerDoneValue = true
  Assert.equal(world:stepWarpDeparture(plan), "running", "the finished cut-in starts the cover")
  screen.doneValue = true
  Assert.equal(driveDeparture(world, plan), "warp", "the covered screen releases the warp")
end

function T.fly_departure_without_a_presenter_keeps_the_legacy_cover()
  local world, _, screen = flyWorldWith()
  local plan = flyPlan()
  Assert.equal(driveDeparture(world, plan, screen), "warp", "a host without a presenter still warps")
end

function T.fly_arrival_runs_the_landing_zoom_around_the_presenter()
  local cutin = cutinDouble(bannerManifest())
  local world, camera, screen = flyWorldWith({ cutin = cutin })
  local plan = flyPlan()
  cutin.bannerDoneValue = true
  screen.doneValue = true
  Assert.equal(driveDeparture(world, plan, screen), "warp", "the departure reaches the warp")
  screen.doneValue = false
  Assert.equal(world:stepWarpArrival(plan), "running")
  Assert.equal(cutin.landings, 0, "the landing waits for the fade")
  screen.doneValue = true
  Assert.equal(world:stepWarpArrival(plan), "running")
  Assert.equal(cutin.landings, 1, "the faded-in screen hands off to the landing")
  Assert.equal(world:stepWarpArrival(plan), "running", "an unfinished landing holds the arrival")
  Assert.isTrue(camera.distance < 10, "the landing dives the camera")
  local dove = camera.distance
  cutin.climbedValue = true
  cutin.landingDoneValue = true
  for _ = 1, 40 do
    if world:stepWarpArrival(plan) == "done" then
      break
    end
  end
  Assert.isTrue(camera.distance > dove, "the climb eases the camera back")
  Assert.equal(camera.distance, 10, "the finished landing restores the captured distance")
  Assert.equal(cutin.landings, 1, "the landing starts exactly once")
end

function T.malformed_staged_banner_fails_at_construction()
  local manifest = bannerManifest()
  manifest.paletteSlot = 7
  local ok, err = pcall(function()
    flyWorldWith({ cutin = cutinDouble(manifest) })
  end)
  Assert.isFalse(ok, "a malformed staged banner must never present")
  Assert.isTrue(Errors.is(err), "the refusal stays a structured error")
  ---@cast err Errors.Error
  Assert.equal(err.code, FieldMoveCutInBannerAssetCache.MANIFEST_INVALID, "the refusal names the banner contract")
end

function T.cancel_during_the_fly_cutin_releases_the_presenter_once()
  local cutin = cutinDouble(bannerManifest())
  local world = flyWorldWith({ cutin = cutin })
  local plan = flyPlan()
  world:stepWarpDeparture(plan)
  world:stepWarpDeparture(plan)
  world:cancelMotion(plan)
  world:cancelMotion(plan)
  Assert.deepEqual(cutin.cancels, { "cutin" }, "cancellation releases the in-flight cut-in once")
end

function T.cancel_during_the_fly_landing_releases_the_presenter_and_zoom_once()
  local cutin = cutinDouble(bannerManifest())
  local world, camera, screen = flyWorldWith({ cutin = cutin })
  local plan = flyPlan()
  cutin.bannerDoneValue = true
  screen.doneValue = true
  Assert.equal(driveDeparture(world, plan, screen), "warp")
  screen.doneValue = false
  world:stepWarpArrival(plan)
  screen.doneValue = true
  world:stepWarpArrival(plan)
  world:cancelMotion(plan)
  world:cancelMotion(plan)
  Assert.deepEqual(cutin.cancels, { "landing" }, "cancellation releases the in-flight landing once")
  Assert.equal(camera.distance, 10, "cancellation restores the captured camera distance")
end

function T.party_knows_waterfall_reads_the_party_port()
  local knower = flyWorldWith({
    party = {
      knowsMove = function(_, move)
        assert(move == "WATERFALL", "the descent gates on waterfall knowledge")
        return true
      end,
    },
  })
  Assert.isTrue(knower:partyKnowsWaterfall(), "a party with waterfall descends")
  local learner = flyWorldWith({
    party = {
      knowsMove = function()
        return false
      end,
    },
  })
  Assert.isFalse(learner:partyKnowsWaterfall(), "a party without waterfall never auto-descends")
end

return { tests = T }
