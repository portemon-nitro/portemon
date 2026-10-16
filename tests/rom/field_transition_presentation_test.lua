-- Private target test: the ordinary conditional MODE_PANEL warp path. On the
-- real dump a supported WARP_PANEL map produces the synthetic panel mode -- not
-- a numeric profile -- and the transition's panel lifecycle notifies each side
-- once, commits the shared destination once, dispatches no profile family,
-- adjusts no camera, and plays no profile cue. The local absence of a rendered
-- panel effect is therefore a proven diagnostic, not a fabricated wipe. Runs
-- against every ready dump through the ROM layer.

local Assert = require("tests.support.Assert")
local FieldCoordinates = require("libs.hgss.src.field.FieldCoordinates")
local FieldPlayer = require("libs.hgss.src.actors.FieldPlayer")
local FieldTransition = require("libs.hgss.src.transition.FieldTransition")
local MetatileBehavior = require("libs.hgss.src.world.MetatileBehavior")
local RomRuntimeMap = require("tests.support.RomRuntimeMap")
local TransitionTrigger = require("libs.hgss.src.transition.TransitionTrigger")
local WarpSystem = require("libs.hgss.src.transition.WarpSystem")

local T = {}

-- The Goldenrod Global Terminal 2F carries real WARP_PANEL warps to the 1F. The
-- first panel tile with a warp is selected from the collision grid so the test
-- does not depend on a hand-copied coordinate.
local PANEL_MAP = "MAP_GOLDENROD_GLOBAL_TERMINAL_2F"

local function findPanelWarp(map)
  local collision = map.collision
  for localX = 0, collision.width - 1 do
    for localZ = 0, collision.height - 1 do
      if collision:getLocal(localX, localZ).behavior == MetatileBehavior.BEHAVIOR.WARP_PANEL then
        local fieldX, fieldZ = collision:localToGlobal(localX, localZ)
        local warp = WarpSystem.findAt(map, fieldX, fieldZ)
        if warp then
          return fieldX, fieldZ, warp
        end
      end
    end
  end
  error("no real WARP_PANEL warp found on " .. PANEL_MAP, 0)
end

local function surfaceAt(map, fieldX, fieldZ)
  local localX, localZ = FieldCoordinates.fieldToLocal(map, fieldX, fieldZ)
  local candidates = map.terrain:candidatesAt(localX + 0.5, localZ + 0.5)
  Assert.isTrue(#candidates > 0, "the panel spawn tile has terrain")
  return candidates[1].id
end

function T.real_panel_warp_uses_the_panel_mode_and_notifies_once(romFs, _)
  local sourceMap = RomRuntimeMap.compile(romFs, PANEL_MAP)
  local fieldX, fieldZ, warp = findPanelWarp(sourceMap)
  Assert.isTrue(warp.destinationMapId ~= sourceMap.mapId, "the panel warp crosses to another map")

  local trigger =
    assert(TransitionTrigger.stepPath(sourceMap, fieldX, fieldZ, "south"), "panel tiles trigger on the step path")
  Assert.equal(trigger.kind, "generic")
  Assert.equal(trigger.transition.mode, "panel")
  Assert.isNil(trigger.transition.profile, "the real panel warp carries no numeric profile")

  local destinationMap = RomRuntimeMap.compile(romFs, warp.destinationMapId)
  local maps = { [sourceMap.mapId] = sourceMap, [destinationMap.mapId] = destinationMap }
  local player = FieldPlayer.new({
    currentMap = sourceMap,
    fieldX = fieldX,
    fieldZ = fieldZ,
    surfaceId = surfaceAt(sourceMap, fieldX, fieldZ),
    facing = "south",
  })
  local panels = {}
  local profiles = {}
  local cameras = {}
  local sounds = {}
  local commits = 0
  local transition
  transition = FieldTransition.new({
    loader = {
      load = function(_, mapId)
        return assert(maps[mapId], "map " .. tostring(mapId))
      end,
      requestWarp = function()
        return true
      end,
      protectMap = function() end,
    },
    player = player,
    onPanel = function(phase)
      panels[#panels + 1] = phase
    end,
    onProfile = function(profileId, phase, family)
      profiles[#profiles + 1] = { profileId, phase, family }
    end,
    cameraAdjust = function(profileId, adjustment)
      cameras[#cameras + 1] = { profileId, adjustment }
    end,
    playSound = function(sound)
      sounds[#sounds + 1] = sound
    end,
    prepare = function(resolution, facing)
      return FieldPlayer.new({
        currentMap = resolution.destinationMap,
        fieldX = resolution.fieldX,
        fieldZ = resolution.fieldZ,
        surfaceId = resolution.surfaceId,
        facing = facing,
      })
    end,
    commit = function(_, _, prepared)
      commits = commits + 1
      player = prepared
      transition.player = player
    end,
  })
  transition.player = player
  transition:start(sourceMap, trigger, "south")

  local ticks = 0
  while transition.phase ~= "idle" and transition.phase ~= "error" and ticks < 256 do
    ticks = ticks + 1
    transition:updateFixed()
    transition:updateSourceFrame()
  end

  Assert.equal(transition.phase, "idle", "the panel warp completes")
  Assert.deepEqual(panels, { "exit", "enter" }, "each panel side is notified once")
  Assert.deepEqual(profiles, {}, "the panel mode dispatches no numeric profile family")
  Assert.deepEqual(cameras, {}, "the panel mode adjusts no camera")
  Assert.deepEqual(sounds, {}, "the panel mode plays no profile cue")
  Assert.equal(commits, 1, "the panel warp commits the shared destination once")
  Assert.notNil(transition.completed, "the panel warp records one completion")
end

return require("tests.rom.support.RomSuite").fromFacts(T)
