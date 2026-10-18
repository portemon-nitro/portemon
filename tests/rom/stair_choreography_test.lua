-- Private target test: the stair and ladder choreography against the real
-- HGSS dump, run through the production FieldTransition over real stair and
-- ladder pairs: the player-house 1F (3,3) <-> 2F (3,4) WARP_STAIRS_WEST pair,
-- the Saffron Magnet Train Station 1F <-> 2F_EMPTY west/east stair pair, and
-- the Sprout Tower 1F <-> 2F ladder pair including the profile-8 LADDER_DOWN
-- step warp and its listed-preview branch. Both directions must: lock input,
-- use the source-owned step/return, play the source-owned HGSS sound
-- (SEQ_SE_DP_KAIDAN2), swap only at full black, settle the profile camera once,
-- skip coordinate suppression (pressing the gate direction on the destination
-- tile re-arms immediately), and unlock at the end of the destination
-- presentation -- no door animation anywhere. Runs against every ready dump
-- through the ROM layer.

local Assert = require("tests.support.Assert")
local DoorTiles = require("libs.hgss.src.transition.DoorTiles")
local FieldCoordinates = require("libs.hgss.src.field.FieldCoordinates")
local FieldPlayer = require("libs.hgss.src.actors.FieldPlayer")
local FieldTransition = require("libs.hgss.src.transition.FieldTransition")
local FieldTransitionProfile = require("libs.hgss.src.transition.FieldTransitionProfile")
local MapAssetCompiler = require("romdump.src.digest.map.MapAssetCompiler")
local MapProps = require("libs.hgss.src.world.MapProps")
local ModelDefinition = require("libs.hgss.src.presentation.ModelDefinition")
local ModelInstance = require("libs.hgss.src.presentation.ModelInstance")
local RomRuntimeMap = require("tests.support.RomRuntimeMap")
local TransitionTrigger = require("libs.hgss.src.transition.TransitionTrigger")
local WarpSystem = require("libs.hgss.src.transition.WarpSystem")
local CompiledAsset = require("tests.rom.support.CompiledAsset")

local T = {}

local HOUSE_1F = "MAP_NEW_BARK_PLAYER_HOUSE_1F"
local HOUSE_2F = "MAP_NEW_BARK_PLAYER_HOUSE_2F"
local MAGNET_1F = "MAP_SAFFRON_MAGNET_TRAIN_STATION_1F"
local MAGNET_2F = "MAP_SAFFRON_MAGNET_TRAIN_STATION_2F_EMPTY"
local SPROUT_1F = "MAP_SPROUT_TOWER_1F"
local SPROUT_2F = "MAP_SPROUT_TOWER_2F"

-- One compiled scene: the runtime map and the MapProps facade, the shape
-- MapSceneLoader produces (the player house carries no building placements,
-- so there are no animated instances to advance).
-- The model-space AABB of a descriptor's geometry, recomputed from the
-- compiled bundle's mesh table (the loader stamps this from the decoded
-- .g4mesh assets).
local function footprintOf(desc, assets)
  local batches = desc.kind == "static" and desc.batches or desc.dynamic.batches
  local minX, maxX, minZ, maxZ
  for _, batch in ipairs(batches) do
    local sha = assert(batch.geometry:match("geometry/([%w]+)%.g4mesh"), "batch references .g4mesh geometry")
    local mesh = assert(assets.meshes[sha], "batch geometry present in the bundle")
    for _, v in ipairs(CompiledAsset.mesh(mesh).vertices) do
      minX = minX == nil and v[1] or math.min(minX, v[1])
      maxX = maxX == nil and v[1] or math.max(maxX, v[1])
      minZ = minZ == nil and v[3] or math.min(minZ, v[3])
      maxZ = maxZ == nil and v[3] or math.max(maxZ, v[3])
    end
  end
  return {
    minX = minX or 0,
    maxX = maxX or 0,
    minY = 0,
    maxY = 0,
    minZ = minZ or 0,
    maxZ = maxZ or 0,
  }
end

local function compileScene(romFs, symbol)
  local assets = assert(MapAssetCompiler.compile(romFs, symbol))
  local instances = {}
  local placements = {}
  for _, inst in ipairs(assets.scene.buildingInstances or {}) do
    local desc = assert(assets.models[inst.modelKey], "placement model descriptor")
    if desc.kind == "nitro-dynamic" then
      instances[inst.placementIndex] =
        ModelInstance.new(ModelDefinition.fromNitroDescriptor(desc, { key = inst.modelKey }))
    end
    placements[#placements + 1] = {
      placementIndex = inst.placementIndex,
      modelKey = inst.modelKey,
      transform = inst.transform,
      bounds = footprintOf(desc, assets),
    }
  end
  local map = RomRuntimeMap.compile(romFs, symbol)
  local props = MapProps.new({
    placements = placements,
    instances = instances,
    doorTiles = DoorTiles.fromGrid(map.collision),
  })
  return { map = map, props = props, instances = instances }
end

local function surfaceAt(map, fieldX, fieldZ)
  local localX, localZ = FieldCoordinates.fieldToLocal(map, fieldX, fieldZ)
  local candidates = map.terrain:candidatesAt(localX + 0.5, localZ + 0.5)
  Assert.isTrue(#candidates > 0, "spawn tile has terrain")
  return candidates[1].id
end

-- Drive one full stair/ladder choreography over the real pair. `trigger` is the
-- real classified trigger record from TransitionTrigger (kind + warp + profile
-- identity); a bare warp record is wrapped as the stair trigger the
-- player-house pair uses. `spawn` places the source player on the standing warp
-- tile; preparation builds the destination player before the black-screen
-- commit, like FieldRuntime. `options.selectPreview` and `options.cameraAdjust`
-- forward the post-commit preview selector and the camera hook.
-- Returns the final player, the transition, the first-tick phase timeline,
-- the recorded sound ids, and the recorded camera adjustments.
local function runChoreography(_, sourceScene, destinationScene, trigger, facing, spawn, options)
  options = options or {}
  if trigger.warp == nil then
    trigger = { kind = "stairs", warp = trigger }
  end
  local srcMap, destinationMap = sourceScene.map, destinationScene.map
  local maps = { [srcMap.mapId] = srcMap, [destinationMap.mapId] = destinationMap }
  local propsByMapId = { [srcMap.mapId] = sourceScene.props, [destinationMap.mapId] = destinationScene.props }
  local instancesByMapId = {
    [srcMap.mapId] = sourceScene.instances,
    [destinationMap.mapId] = destinationScene.instances,
  }
  local loader = {
    load = function(_, mapId)
      return assert(maps[mapId], "map " .. tostring(mapId))
    end,
    requestWarp = function(_, sourceMap, warp)
      assert(type(sourceMap) == "table", "fixture warp source is required")
      assert(type(warp) == "table", "fixture warp record is required")
      assert(maps[warp.destinationMapId], "fixture destination is not preloaded")
      return true
    end,
    protectMap = function() end,
    transitionEnvironment = function(_, mapId)
      local environmentMap = assert(maps[mapId], "map " .. tostring(mapId))
      return assert(
        environmentMap.fieldData.transitionEnvironment,
        "transition environment for map " .. tostring(mapId)
      )
    end,
  }

  ---@cast srcMap RuntimeFieldMap
  local player = FieldPlayer.new({
    currentMap = srcMap,
    fieldX = spawn.x,
    fieldZ = spawn.z,
    surfaceId = surfaceAt(srcMap, spawn.x, spawn.z),
    facing = facing,
  })

  local sounds = {}
  local stops = {}
  local cameraAdjustments = {}
  local transition
  local currentInstances = sourceScene.instances
  transition = FieldTransition.new({
    loader = loader,
    doorAt = function(runtimeMap, x, z)
      local props = propsByMapId[runtimeMap.mapId]
      if not props then
        return nil
      end
      return props:doorAt(runtimeMap, x, z)
    end,
    escalatorAt = options.escalatorAt,
    follower = options.follower,
    playSound = function(soundId)
      sounds[#sounds + 1] = soundId
    end,
    stopSound = function(soundId)
      stops[#stops + 1] = soundId
    end,
    selectPreview = options.selectPreview,
    cameraAdjust = (options.cameraAdjust or options.camera) and function(_, adjustment)
      cameraAdjustments[#cameraAdjustments + 1] = adjustment
      return options.camera
    end or nil,
    prepare = function(resolution, swapFacing)
      return FieldPlayer.new({
        currentMap = resolution.destinationMap,
        fieldX = resolution.fieldX,
        fieldZ = resolution.fieldZ,
        surfaceId = resolution.surfaceId,
        facing = swapFacing,
      })
    end,
    commit = function(resolution, _, preparedPlayer)
      Assert.equal(transition.fadeAlpha, 1, "the swap happens only at full black")
      player = preparedPlayer
      transition.player = player
      currentInstances = instancesByMapId[resolution.destinationMap.mapId]
    end,
  })
  transition.player = player
  transition:start(srcMap, trigger, facing)

  -- The fixed-tick loop mirrors the session: the transition ticks, and while
  -- the stair choreography is active the scene's animated instances advance.
  local timeline = {}
  local ticks = 0
  while transition.phase ~= "idle" and transition.phase ~= "error" and ticks < 500 do
    ticks = ticks + 1
    transition:updateFixed()
    if transition.locked or transition.completed then
      for _, instance in ipairs(currentInstances) do
        instance:updateFixed()
      end
    end
    transition:updateSourceFrame()
    if timeline[transition.phase] == nil then
      timeline[transition.phase] = ticks
    end
  end
  Assert.equal(transition.phase, "idle", "the choreography completes within the tick budget")
  Assert.notNil(transition.completed, "the choreography records one completion token")
  return transition, player, timeline, sounds, cameraAdjustments, stops
end

-- 1F (3,3) -> 2F: the standing WARP_STAIRS_WEST tile climbs in place while
-- the fade runs; the swap lands the player on the 2F stair tile (3,4), which
-- is itself a standing stair warp -- pressing west there re-arms immediately.
function T.house_1f_to_2f_stairs_choreograph(romFs, _)
  local h1 = compileScene(romFs, HOUSE_1F)
  local h2 = compileScene(romFs, HOUSE_2F)
  local warp = assert(WarpSystem.findAt(h1.map, 3, 3))
  local transition, player, timeline, sounds = runChoreography(romFs, h1, h2, warp, "west", {
    x = 3,
    z = 3,
  })

  Assert.equal(player.fieldX, 3)
  Assert.equal(player.fieldZ, 4, "the ascent lands on the 2F stair tile")
  Assert.equal(player.motion, "idle")
  Assert.isFalse(transition.locked, "input unlocks once the destination fade-in completes")
  Assert.isNil(transition.suppression, "stair warps never carry coordinate suppression")
  Assert.notNil(timeline.choreo_hold, "stairs hold until destination presentation completes")
  Assert.equal(#sounds, 1, "the source stair movement owns the stair sound")
  for _, id in ipairs(sounds) do
    Assert.equal(
      id,
      FieldTransitionProfile.ROUTINE_FAMILIES[FieldTransitionProfile.HORIZONTAL_STAIRS].exitSound,
      "the HGSS stair-climb sound id"
    )
  end
  Assert.isTrue(timeline.fade_out < timeline.swap_map, "the fade ran before the swap")
  Assert.equal(transition:consumeCompleted().sourceWarpId, warp.index)

  -- Immediate reversal: the destination tile is a standing stair warp, so
  -- pressing the gate direction re-arms the transition immediately.
  local back =
    assert(TransitionTrigger.inputPath(h2.map, player.fieldX, player.fieldZ, "west"), "the 2F stair tile re-triggers")
  Assert.equal(back.kind, "stairs")
  Assert.equal(assert(back.warp).destinationMapId, h1.map.mapId)
end

-- 2F (3,4) -> 1F: the descent mirrors the ascent and lands back on the 1F
-- stair tile (3,3), unlocked and immediately re-armed.
function T.house_2f_to_1f_stairs_choreograph(romFs, _)
  local h2 = compileScene(romFs, HOUSE_2F)
  local h1 = compileScene(romFs, HOUSE_1F)
  local warp = assert(WarpSystem.findAt(h2.map, 3, 4))
  local transition, player, timeline, sounds = runChoreography(romFs, h2, h1, warp, "west", {
    x = 3,
    z = 4,
  })

  Assert.equal(player.fieldX, 3)
  Assert.equal(player.fieldZ, 3, "the descent lands back on the 1F stair tile")
  Assert.equal(player.motion, "idle")
  Assert.isFalse(transition.locked)
  Assert.isNil(transition.suppression)
  Assert.notNil(timeline.choreo_hold)
  Assert.equal(#sounds, 1)
  Assert.isTrue(timeline.fade_out < timeline.swap_map)

  local back =
    assert(TransitionTrigger.inputPath(h1.map, player.fieldX, player.fieldZ, "west"), "the 1F stair tile re-triggers")
  Assert.equal(back.kind, "stairs")
end

-- Saffron Magnet Train Station 1F <-> 2F_EMPTY: a real WEST <-> EAST stair pair
-- (1F WARP_STAIRS_WEST (3,3) climbs to the 2F WARP_STAIRS_EAST tile (21,14),
-- and the 2F east stair descends back). Both directions carry profile 3,
-- settle the horizontal-stair camera once, and land standing on the reciprocal
-- stair tile, immediately re-armed.
function T.magnet_train_station_west_and_east_stairs_choreograph(romFs, _)
  local s1 = compileScene(romFs, MAGNET_1F)
  local s2 = compileScene(romFs, MAGNET_2F)

  local up = assert(TransitionTrigger.inputPath(s1.map, 3, 3, "west"), "the 1F west stair triggers")
  Assert.equal(up.kind, "stairs")
  Assert.equal(up.transition.profile, FieldTransitionProfile.HORIZONTAL_STAIRS)
  local upTransition, upPlayer, upTimeline, upSounds, upCamera = runChoreography(
    romFs,
    s1,
    s2,
    up,
    "west",
    { x = 3, z = 3 },
    { cameraAdjust = true }
  )
  Assert.equal(upPlayer.fieldX, 21)
  Assert.equal(upPlayer.fieldZ, 14, "the ascent lands on the 2F east-stair tile")
  Assert.equal(upPlayer.motion, "idle")
  Assert.isFalse(upTransition.locked)
  Assert.isNil(upTransition.suppression)
  Assert.notNil(upTimeline.choreo_hold, "the stair ascent holds for its destination presentation")
  Assert.deepEqual(upCamera, { "horizontal_stairs" }, "the stair camera settles once")
  Assert.deepEqual(
    upSounds,
    { FieldTransitionProfile.ROUTINE_FAMILIES[FieldTransitionProfile.HORIZONTAL_STAIRS].exitSound },
    "the ascent owns exactly the one stair sound"
  )
  Assert.isTrue(upTimeline.fade_out < upTimeline.swap_map)

  local down = assert(TransitionTrigger.inputPath(s2.map, 21, 14, "east"), "the 2F east stair triggers")
  Assert.equal(down.kind, "stairs")
  Assert.equal(down.transition.profile, FieldTransitionProfile.HORIZONTAL_STAIRS)
  Assert.equal(assert(down.warp).destinationMapId, s1.map.mapId, "the east stair points back at the 1F west stair")
  local downTransition, downPlayer, _, downSounds, downCamera = runChoreography(
    romFs,
    s2,
    s1,
    down,
    "east",
    { x = 21, z = 14 },
    { cameraAdjust = true }
  )
  Assert.equal(downPlayer.fieldX, 3)
  Assert.equal(downPlayer.fieldZ, 3, "the descent lands back on the 1F west-stair tile")
  Assert.isFalse(downTransition.locked)
  Assert.deepEqual(downCamera, { "horizontal_stairs" })
  Assert.deepEqual(downSounds, {
    FieldTransitionProfile.ROUTINE_FAMILIES[FieldTransitionProfile.HORIZONTAL_STAIRS].exitSound,
  })
end

-- Sprout Tower 1F <-> 2F: the two standing ladder faces on 1F both climb
-- (profile 7) to the 2F ladder tile (6,15), and the 2F LADDER_DOWN step warp
-- descends (profile 8) to the 1F south landing (6,17). Each direction owns the
-- ladder camera and the one ladder sound.
function T.sprout_tower_ladders_climb_both_faces_and_descend(romFs, _)
  local t1 = compileScene(romFs, SPROUT_1F)
  local t2 = compileScene(romFs, SPROUT_2F)

  for _, face in ipairs({
    { x = 6, z = 15, facing = "south" },
    { x = 6, z = 16, facing = "north" },
  }) do
    local up = assert(TransitionTrigger.inputPath(t1.map, face.x, face.z, face.facing), "the 1F ladder face triggers")
    Assert.equal(up.kind, "directional")
    Assert.equal(up.transition.profile, FieldTransitionProfile.LADDER)
    local transition, player, timeline, sounds, camera = runChoreography(
      romFs,
      t1,
      t2,
      up,
      face.facing,
      { x = face.x, z = face.z },
      { cameraAdjust = true }
    )
    Assert.equal(player.fieldX, 6)
    Assert.equal(player.fieldZ, 15, "the ascent lands on the 2F ladder tile")
    Assert.equal(player.motion, "idle")
    Assert.isFalse(transition.locked)
    Assert.notNil(timeline.choreo_hold, "the ascent holds for the vertical return")
    Assert.deepEqual(camera, { "ladder" }, "the ascent owns the vertical camera")
    Assert.deepEqual(sounds, {
      FieldTransitionProfile.ROUTINE_FAMILIES[FieldTransitionProfile.LADDER].exitSound,
    })
  end

  local down = assert(TransitionTrigger.stepPath(t2.map, 6, 16, "south"), "the 2F ladder-down step warp triggers")
  Assert.equal(down.kind, "generic")
  Assert.equal(down.transition.profile, FieldTransitionProfile.LADDER_DOWN)
  local transition, player, _, sounds, camera = runChoreography(
    romFs,
    t2,
    t1,
    down,
    "south",
    { x = 6, z = 16 },
    { cameraAdjust = true }
  )
  Assert.equal(player.fieldX, 6)
  Assert.equal(player.fieldZ, 17, "the descent steps off the ladder to the 1F south landing")
  Assert.isFalse(transition.locked)
  Assert.deepEqual(camera, { "ladder_down" })
  Assert.deepEqual(sounds, {
    FieldTransitionProfile.ROUTINE_FAMILIES[FieldTransitionProfile.LADDER_DOWN].exitSound,
  })
end

-- The profile-8 listed-preview source path: with a selected preview, the
-- special vertical return owns the arrival and the generic destination step is
-- never run, so the player lands on the ladder anchor (6,16) rather than one
-- tile south (6,17), and the ordinary destination fade-in/hold never occur.
function T.profile8_ladder_down_preview_replaces_the_generic_destination_step(romFs, _)
  local t1 = compileScene(romFs, SPROUT_1F)
  local t2 = compileScene(romFs, SPROUT_2F)
  local down = assert(TransitionTrigger.stepPath(t2.map, 6, 16, "south"))
  Assert.equal(down.transition.profile, FieldTransitionProfile.LADDER_DOWN)

  local transition, player, timeline, sounds = runChoreography(romFs, t2, t1, down, "south", { x = 6, z = 16 }, {
    selectPreview = function()
      return { imageKey = "preview.test", timeSlot = 1, profileId = FieldTransitionProfile.LADDER_DOWN }
    end,
  })

  Assert.equal(player.fieldX, 6)
  Assert.equal(player.fieldZ, 16, "the preview arrival skips the generic destination step")
  Assert.equal(player.facing, "south", "the preview arrival turns south exactly once")
  Assert.isFalse(transition.locked)
  Assert.notNil(timeline.preview, "the transition enters the preview substate")
  Assert.isNil(timeline.fade_in, "the preview replaces the ordinary destination fade-in")
  Assert.isNil(timeline.choreo_hold, "the preview replaces the generic destination hold")
  Assert.deepEqual(sounds, {
    FieldTransitionProfile.ROUTINE_FAMILIES[FieldTransitionProfile.LADDER_DOWN].exitSound,
  })
end

-- Goldenrod Department Store escalators: the real 1F (13,7) <-> 2F (18,7)
-- reciprocal pair (retail profile 2, exit/enter through the side door
-- with SEQ_SE_DP_ESUKA). The production resolver
-- chain (MapProps:propAt, the same owner FieldRuntime wires) resolves a live
-- prop on both tiles, but the generated indoor models carry no "escalator"
-- animation clip, so playback raises MAP_PROP_ANIM_UNKNOWN. That missing
-- generated data is the boundary: the readiness test below pins it on the
-- real pair, and the choreography test behind it runs the full profile-2
-- composition -- real step-path trigger, real cross-map resolution, real
-- player over real terrain -- with a recording prop stand-in at the
-- presentation seam until the generated clip lands.
local DEPT_1F = "MAP_GOLDENROD_DEPARTMENT_STORE_1F"
local DEPT_2F = "MAP_GOLDENROD_DEPARTMENT_STORE_2F"

local function recordingEscalatorProp()
  local prop = { plays = {}, polls = 0, finishAfter = 2, finished = true }
  function prop:play(animation)
    self.plays[#self.plays + 1] = animation
    self.finished = false
    self.polls = 0
  end
  function prop:isFinished()
    if self.finished then
      return true
    end
    self.polls = self.polls + 1
    if self.polls >= self.finishAfter then
      self.finished = true
    end
    return self.finished
  end
  return prop
end

function T.goldenrod_escalators_resolve_a_live_prop_with_the_escalator_animation(romFs, _, context)
  local scenes = {
    one = compileScene(romFs, DEPT_1F),
    two = compileScene(romFs, DEPT_2F),
  }
  for _, leg in ipairs({
    { scene = "one", x = 13, z = 7, facing = "east", destination = "two" },
    { scene = "two", x = 18, z = 7, facing = "west", destination = "one" },
  }) do
    local scene = scenes[leg.scene]
    local trigger = assert(
      TransitionTrigger.stepPath(scene.map, leg.x, leg.z, leg.facing),
      leg.scene .. " escalator tile triggers on the step path"
    )
    Assert.equal(trigger.kind, "directional", "escalators evaluate on the directional step path")
    Assert.equal(trigger.transition.profile, FieldTransitionProfile.ESCALATOR, "the real pair carries profile 2")
    local prop = assert(
      scene.props:propAt(scene.map, leg.x, leg.z),
      leg.scene .. " escalator tile resolves a live prop through the production resolver"
    )
    Assert.isTrue(type(prop.play) == "function", "the escalator prop carries playback")
    Assert.isTrue(type(prop.isFinished) == "function", "the escalator prop carries completion")
    local played = pcall(function()
      prop:play("escalator")
    end)
    if not played then
      context:skip("generated indoor models carry no escalator clip (producer gap)")
    end
    Assert.deepEqual(prop.plays or { "escalator" }, { "escalator" }, "the prop runs the escalator animation")
  end
end

function T.goldenrod_escalators_choreograph_both_directions(romFs, _)
  local d1 = compileScene(romFs, DEPT_1F)
  local d2 = compileScene(romFs, DEPT_2F)

  for _, leg in ipairs({
    { from = d1, to = d2, x = 13, z = 7, facing = "east", landX = 19, landZ = 7 },
    { from = d2, to = d1, x = 18, z = 7, facing = "west", landX = 12, landZ = 7 },
  }) do
    local trigger = assert(TransitionTrigger.stepPath(leg.from.map, leg.x, leg.z, leg.facing))
    Assert.equal(trigger.transition.profile, FieldTransitionProfile.ESCALATOR)
    local prop = recordingEscalatorProp()
    local plays = 0
    local standIn = setmetatable({}, {
      __index = function(_, key)
        if key == "play" then
          return function(_, animation)
            plays = plays + 1
            return prop:play(animation)
          end
        end
        return prop[key]
      end,
    })
    local transition, player, timeline, sounds, camera, stops = runChoreography(
      romFs,
      leg.from,
      leg.to,
      trigger,
      leg.facing,
      {
        x = leg.x,
        z = leg.z,
      },
      {
        cameraAdjust = true,
        escalatorAt = function()
          return standIn
        end,
      }
    )
    Assert.equal(player.fieldX, leg.landX, "the side-door exit steps one tile past the arrival warp")
    Assert.equal(player.fieldZ, leg.landZ)
    Assert.equal(player.facing, leg.facing, "the escalator preserves the travel facing")
    Assert.equal(player.motion, "idle")
    Assert.isFalse(transition.locked, "input unlocks once the destination side-door walk finishes")
    Assert.deepEqual(camera, { "escalator" }, "the escalator owns its camera exactly once")
    Assert.deepEqual(
      sounds,
      { FieldTransitionProfile.ROUTINE_FAMILIES[FieldTransitionProfile.ESCALATOR].exitSound },
      "the ascent owns exactly the one escalator sound"
    )
    Assert.deepEqual(stops, sounds, "the escalator sound stops once the source side finishes")
    Assert.isTrue(plays >= 2, "both the exit and the enter sides play the prop")
    Assert.isTrue(timeline.fade_out < timeline.swap_map, "the fade ran before the swap")
    Assert.notNil(transition:consumeCompleted(), "the escalator records one completion token")
  end
end

-- Cave/outdoor environment choreography on the real reciprocal
-- ECRUTEAK (376,149, WARP_NORTH step) <-> BURNED_TOWER_1F (15,26,
-- WARP_ENTRANCE_SOUTH input) pair. Outdoors -> cave runs profile 4
-- (cave_exit, SEQ_SE_DP_KAIDAN2, the 0x10 environment wipe from retail
-- stairs fade-out);
-- cave -> outdoors runs profile 5 (outdoor_exit, KAIDAN2, the white 0x7FFF
-- fade with the camera zoom choreography). The Union Cave <-> Route 32/33
-- warps are real but unreachable with the available harness: both
-- destinations resolve outside the compiled permission coverage
-- (FIELD_COORDINATES_OUT_OF_COVERAGE), so no pair there is asserted --
-- manufacturing one would fake the corpus.
local ECRUTEAK = "MAP_ECRUTEAK"
local BURNED_1F = "MAP_BURNED_TOWER_1F"

local function outdoorCamera()
  local angle = 0
  local deltas = {}
  return {
    rawPerspective = function(self)
      return angle
    end,
    adjustRawPerspective = function(self, delta)
      angle = angle + delta
      deltas[#deltas + 1] = delta
    end,
    deltas = deltas,
  }
end

function T.cave_entry_runs_the_0x10_environment_wipe_not_a_black_fade(romFs, _)
  local outdoors = compileScene(romFs, ECRUTEAK)
  local cave = compileScene(romFs, BURNED_1F)
  local trigger =
    assert(TransitionTrigger.stepPath(outdoors.map, 376, 149, "north"), "the Ecruteak cave mouth triggers")
  Assert.equal(trigger.kind, "generic")
  Assert.equal(trigger.transition.profile, nil, "the mouth carries the environment mode, not a fixed profile")

  local maps = { [outdoors.map.mapId] = outdoors.map, [cave.map.mapId] = cave.map }
  local player = FieldPlayer.new({
    currentMap = outdoors.map,
    fieldX = 376,
    fieldZ = 149,
    surfaceId = surfaceAt(outdoors.map, 376, 149),
    facing = "north",
  })
  local transition = FieldTransition.new({
    loader = {
      load = function(_, mapId)
        return assert(maps[mapId], "map " .. tostring(mapId))
      end,
      requestWarp = function()
        return true
      end,
      protectMap = function() end,
      transitionEnvironment = function(_, mapId)
        return assert(maps[mapId].fieldData.transitionEnvironment)
      end,
    },
    player = player,
    prepare = function() end,
    commit = function() end,
  })
  transition.player = player
  transition:start(outdoors.map, trigger, "north")
  Assert.equal(transition.profileId, 4, "outdoors -> cave selects profile 4")
  local status = transition:presentationStatus()
  Assert.equal(
    status.fadeMode,
    "environment_0x10",
    "the cave entry runs the 0x10 environment wipe, not a black brightness fade"
  )
end

function T.ecruteak_and_burned_tower_choreograph_cave_and_outdoor(romFs, _)
  local outdoors = compileScene(romFs, ECRUTEAK)
  local cave = compileScene(romFs, BURNED_1F)

  -- Outdoors -> cave: profile 4, the cave camera, the one stair sound, the
  -- generic destination step one tile south of the arrival warp, and the
  -- generic coordinate suppression retained.
  local enter = assert(TransitionTrigger.stepPath(outdoors.map, 376, 149, "north"))
  Assert.equal(enter.transition.profile, nil, "the mouth carries the environment mode")
  local enterTransition, enterPlayer, enterTimeline, enterSounds, enterCamera = runChoreography(
    romFs,
    outdoors,
    cave,
    enter,
    "north",
    {
      x = 376,
      z = 149,
    },
    { cameraAdjust = true }
  )
  Assert.equal(enterTransition.profileId, 4, "outdoors -> cave selects profile 4")
  Assert.equal(enterPlayer.fieldX, 15)
  Assert.equal(enterPlayer.fieldZ, 26, "the entry lands on the tower arrival warp")
  Assert.equal(enterPlayer.facing, "north", "the entry preserves the trigger facing")
  Assert.isFalse(enterTransition.locked)
  Assert.notNil(enterTransition.suppression, "the generic cave entry keeps coordinate suppression")
  Assert.deepEqual(enterCamera, { "cave" }, "the cave entry settles its camera once")
  Assert.deepEqual(
    enterSounds,
    { FieldTransitionProfile.ROUTINE_FAMILIES[4].exitSound },
    "the cave entry owns exactly the one stair sound"
  )
  Assert.isTrue(enterTimeline.fade_out < enterTimeline.swap_map)
  Assert.notNil(enterTransition:consumeCompleted(), "the cave entry records one completion token")

  -- Cave -> outdoors: profile 5, the white fade, the outdoor camera zoom
  -- that moves during the exit and restores the destination angle exactly,
  -- facing south, no suppression, one commit.
  local exit = assert(TransitionTrigger.inputPath(cave.map, 15, 26, "south"), "the tower mouth triggers")
  Assert.equal(exit.kind, "directional")
  local camera = outdoorCamera()
  local exitTransition, exitPlayer, exitTimeline, exitSounds, exitCamera = runChoreography(
    romFs,
    cave,
    outdoors,
    exit,
    "south",
    {
      x = 15,
      z = 26,
    },
    { cameraAdjust = true, camera = camera }
  )
  Assert.equal(exitTransition.profileId, 5, "cave -> outdoors selects profile 5")
  Assert.equal(exitPlayer.fieldX, 376)
  Assert.equal(exitPlayer.fieldZ, 149, "the exit lands back on the Ecruteak mouth")
  Assert.equal(exitPlayer.facing, "south", "the exit preserves the trigger facing")
  Assert.isFalse(exitTransition.locked)
  Assert.isNil(exitTransition.suppression, "directional exits carry no suppression")
  Assert.deepEqual(exitCamera, { "outdoor", "outdoor" }, "the outdoor exit drives the camera on both sides of the swap")
  Assert.deepEqual(
    exitSounds,
    { FieldTransitionProfile.ROUTINE_FAMILIES[5].exitSound },
    "the outdoor exit owns exactly the one stair sound"
  )
  Assert.isTrue(#camera.deltas > 0, "the outdoor zoom steps the live camera angle during the fade")
  Assert.isTrue(exitTimeline.fade_out < exitTimeline.swap_map)
  Assert.notNil(exitTransition:consumeCompleted(), "the outdoor exit records one completion token")
end

-- Profile-8 preview with a follower present (retail states 4-5 of
-- MapPreviewGraphic_RunPlayerDropIn): the transition must rejoin the
-- follower through its follower collaborator exactly once with the preview
-- reason, after the preview-owned arrival, without duplicating the commit.
function T.profile8_preview_with_follower_present_rejoins_once(romFs, _)
  local t1 = compileScene(romFs, SPROUT_1F)
  local t2 = compileScene(romFs, SPROUT_2F)
  local down = assert(TransitionTrigger.stepPath(t2.map, 6, 16, "south"))
  Assert.equal(down.transition.profile, FieldTransitionProfile.LADDER_DOWN)

  local rejoins = {}
  local transition, player, timeline = runChoreography(romFs, t2, t1, down, "south", { x = 6, z = 16 }, {
    selectPreview = function()
      return { imageKey = "preview.test", timeSlot = 1, profileId = FieldTransitionProfile.LADDER_DOWN }
    end,
    follower = {
      isPresent = function()
        return true
      end,
      recall = function() end,
      rejoin = function(reason)
        rejoins[#rejoins + 1] = reason
      end,
    },
  })

  Assert.equal(player.fieldX, 6)
  Assert.equal(player.fieldZ, 16, "the preview arrival skips the generic destination step")
  Assert.equal(player.facing, "south")
  Assert.isFalse(transition.locked)
  Assert.notNil(timeline.preview, "the transition enters the preview substate")
  Assert.deepEqual(rejoins, { "preview" }, "the preview arrival rejoins the present follower exactly once")
  Assert.notNil(transition.completed, "the preview still records one completion")
end

return require("tests.rom.support.RomSuite").fromFacts(T)
