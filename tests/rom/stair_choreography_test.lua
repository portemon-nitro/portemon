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
    playSound = function(soundId)
      sounds[#sounds + 1] = soundId
    end,
    selectPreview = options.selectPreview,
    cameraAdjust = options.cameraAdjust
        and function(_, adjustment)
          cameraAdjustments[#cameraAdjustments + 1] = adjustment
        end
      or nil,
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
  return transition, player, timeline, sounds, cameraAdjustments
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
  local upTransition, upPlayer, upTimeline, upSounds, upCamera =
    runChoreography(romFs, s1, s2, up, "west", { x = 3, z = 3 }, { cameraAdjust = true })
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
  local downTransition, downPlayer, _, downSounds, downCamera =
    runChoreography(romFs, s2, s1, down, "east", { x = 21, z = 14 }, { cameraAdjust = true })
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
    local transition, player, timeline, sounds, camera =
      runChoreography(romFs, t1, t2, up, face.facing, { x = face.x, z = face.z }, { cameraAdjust = true })
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
  local transition, player, _, sounds, camera =
    runChoreography(romFs, t2, t1, down, "south", { x = 6, z = 16 }, { cameraAdjust = true })
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

return require("tests.rom.support.RomSuite").fromFacts(T)
