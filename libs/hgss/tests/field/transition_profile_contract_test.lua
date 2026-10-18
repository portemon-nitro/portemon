-- Pure transition-profile contracts. These fixtures isolate source-selected
-- door audio and the asymmetric HGSS door movement from ROM loading.

local Assert = require("tests.support.Assert")
local FieldPlayer = require("libs.hgss.src.actors.FieldPlayer")
local FieldTransition = require("libs.hgss.src.transition.FieldTransition")
local FieldTransitionProfile = require("libs.hgss.src.transition.FieldTransitionProfile")
local MetatileBehavior = require("libs.hgss.src.world.MetatileBehavior")
local TerrainSurface = require("libs.hgss.src.world.TerrainSurface")

local T = { tests = {} }

local function step(transition)
  local moved = transition:updateFixed()
  transition:updateSourceFrame()
  return moved
end

local function advanceTo(transition, phase, maxTicks)
  for _ = 1, maxTicks do
    if transition.phase == phase then
      return
    end
    step(transition)
  end
  Assert.equal(transition.phase, phase)
end

-- Environment-selected profiles use the generated semantic map matrix,
-- including an explicit failure for unsupported pairs.
function T.tests.environment_selection_matches_hgss_matrix()
  local expected = {
    { "cave", "cave", 6 },
    { "cave", "outdoors", 5 },
    { "cave", "building", 6 },
    { "outdoors", "cave", 4 },
    { "outdoors", "building", 6 },
    { "building", "building", 6 },
    { "building", "cave", 0 },
    { "building", "outdoors", 0 },
  }
  for _, pair in ipairs(expected) do
    Assert.equal(FieldTransitionProfile.selectEnvironment(pair[1], pair[2]), pair[3])
  end

  Assert.throws(function()
    FieldTransitionProfile.selectEnvironment("outdoors", "outdoors")
  end, "outdoors-to-outdoors must fail instead of defaulting to a profile")
end

function T.tests.vertical_profiles_return_from_staging_before_the_final_step()
  for _, profile in ipairs({ 7, 8 }) do
    local events = {}
    local stagedY
    local player = {
      motion = "idle",
      beginTransitionVerticalReturn = function(self, anchorY)
        events[#events + 1] = { "return", anchorY }
        self.motion = "transition"
        return true
      end,
      beginTransitionLadderExit = function(self)
        self.motion = "transition"
        return true
      end,
      beginTransitionLadderDownExit = function(self)
        self.motion = "transition"
        return true
      end,
      beginTransitionStep = function(self, direction)
        events[#events + 1] = { "step", direction }
        self.motion = "walking"
        return true
      end,
      updateFixed = function(self)
        self.motion = "idle"
        return true
      end,
    }
    local transition = FieldTransition.new({
      loader = {
        requestWarp = function()
          return true
        end,
      },
      player = player,
      resolveDestination = function()
        return {
          destinationMap = { mapId = 60 },
          destinationWarp = { x = 4, z = 4 },
          fieldX = 4,
          fieldZ = 4,
          surfaceId = 0,
          worldY = 10,
        }
      end,
      prepare = function(result)
        stagedY = result.worldY
        return result
      end,
      commit = function() end,
    })
    transition:start({ mapId = 61 }, {
      warp = { index = 0, destinationMapId = 60, destinationWarpId = 0 },
      transition = { mode = "fixed", profile = profile },
    }, "south")
    advanceTo(transition, FieldTransition.PHASES.idle, 128)
    local expectedDirection = profile == 7 and "north" or "south"
    Assert.equal(stagedY, profile == 7 and 8 or 12)
    Assert.deepEqual(events, { { "return", 10 }, { "step", expectedDirection } })
  end
end

local function eventIndex(events, expected)
  for index, event in ipairs(events) do
    if event == expected then
      return index
    end
  end
  return nil
end

function T.tests.escalator_source_lifecycle_orders_effects_and_pause_ownership()
  local events = {}
  local stepCount = 0
  local propPlayCount = 0
  local sourcePropPolls = 0
  local prop = {
    play = function(self, animation)
      events[#events + 1] = "prop:" .. animation
      propPlayCount = propPlayCount + 1
      if propPlayCount == 1 then
        sourcePropPolls = 0
      end
      self.finished = false
    end,
    isFinished = function(_)
      if propPlayCount == 1 then
        sourcePropPolls = sourcePropPolls + 1
        return sourcePropPolls >= 3
      end
      return true
    end,
  }
  local player = {
    motion = "idle",
    animationPaused = false,
    pauseTransitionAnimation = function(self)
      events[#events + 1] = "pause"
      self.animationPaused = true
    end,
    resumeTransitionAnimation = function(self)
      events[#events + 1] = "resume"
      self.animationPaused = false
    end,
    beginTransitionStep = function(self, facing)
      events[#events + 1] = "horizontal:" .. facing
      self.motion = "walking"
      stepCount = 0
      return true
    end,
    updateFixed = function(self)
      stepCount = stepCount + 1
      if stepCount >= 2 then
        self.motion = "idle"
      end
      return true
    end,
  }
  local transition = FieldTransition.new({
    loader = {
      requestWarp = function()
        return true
      end,
    },
    player = player,
    escalatorAt = function()
      return prop
    end,
    playSound = function(sound)
      events[#events + 1] = "sound:" .. sound
    end,
    stopSound = function(sound)
      events[#events + 1] = "stop:" .. sound
    end,
    resolveDestination = function()
      events[#events + 1] = "resolve"
      return {
        destinationMap = { mapId = 60 },
        fieldX = 4,
        fieldZ = 4,
        surfaceId = 0,
        worldY = 0,
      }
    end,
    prepare = function(result)
      events[#events + 1] = "prepare"
      return result
    end,
    commit = function()
      events[#events + 1] = "commit"
    end,
  })
  transition:start({ mapId = 61 }, {
    warp = { index = 0, destinationMapId = 60, destinationWarpId = 0, x = 4, z = 4 },
    transition = { mode = "fixed", profile = FieldTransitionProfile.ESCALATOR },
  }, "east")
  Assert.deepEqual(events, {
    "prop:escalator",
    "pause",
    "horizontal:east",
    "sound:SEQ_SE_DP_ESUKA",
  })
  Assert.isTrue(player.animationPaused)
  Assert.isFalse(transition.fadeStarted)
  local sourceFrameStoppedBeforeMotion = not transition:updateSourceFrame()
  local coefficientStayedAtZero = transition:presentationStatus().coefficient == 0

  transition:updateFixed()
  Assert.equal(player.motion, "walking")
  Assert.isTrue(transition.fadeStarted)
  Assert.isTrue(transition:updateSourceFrame())
  Assert.isTrue(transition:presentationStatus().coefficient > 0)
  transition:updateFixed()
  Assert.equal(player.motion, "idle")

  while not transition.fade:status().completed do
    Assert.isTrue(transition:updateSourceFrame())
  end
  Assert.isTrue(transition.fade:status().completed)
  transition:updateFixed()
  Assert.equal(transition.phase, FieldTransition.PHASES.fade_out)
  Assert.isTrue(player.animationPaused)
  Assert.isNil(eventIndex(events, "stop:SEQ_SE_DP_ESUKA"))

  transition:updateFixed()
  Assert.equal(transition.phase, FieldTransition.PHASES.load_destination)
  Assert.isFalse(player.animationPaused)
  local sourceStopBeforeResolve = eventIndex(events, "stop:SEQ_SE_DP_ESUKA")

  transition:updateFixed()
  Assert.equal(transition.phase, FieldTransition.PHASES.swap_map)
  transition:updateFixed()
  Assert.equal(transition.phase, FieldTransition.PHASES.fade_in)

  advanceTo(transition, FieldTransition.PHASES.idle, 128)
  Assert.equal(transition.phase, "idle")
  Assert.isFalse(player.animationPaused)
  Assert.isTrue(sourceFrameStoppedBeforeMotion, "source frames must not advance before source motion")
  Assert.isTrue(coefficientStayedAtZero, "source fade coefficient must remain zero before source motion")
  Assert.notNil(sourceStopBeforeResolve, "source sound must stop before destination resolution")
  Assert.equal(eventIndex(events, "sound:SEQ_SE_DP_ESUKA"), 4)
  Assert.equal(eventIndex(events, "stop:SEQ_SE_DP_ESUKA"), eventIndex(events, "resume") + 1)
  Assert.isTrue(
    sourceStopBeforeResolve < eventIndex(events, "resolve"),
    "source sound must stop before destination resolution"
  )
  Assert.isTrue(eventIndex(events, "resume") < eventIndex(events, "resolve"))
  Assert.isTrue(eventIndex(events, "stop:SEQ_SE_DP_ESUKA") < eventIndex(events, "resolve"))
end

function T.tests.escalator_step_failure_releases_owned_animation_pause()
  local player = {
    motion = "idle",
    animationPaused = false,
    pauseTransitionAnimation = function(self)
      self.animationPaused = true
    end,
    resumeTransitionAnimation = function(self)
      self.animationPaused = false
    end,
    beginTransitionStep = function()
      return false
    end,
  }
  local transition = FieldTransition.new({
    loader = {
      requestWarp = function()
        return true
      end,
    },
    player = player,
    escalatorAt = function()
      return {
        play = function() end,
        isFinished = function()
          return true
        end,
      }
    end,
    playSound = function() end,
    stopSound = function() end,
    resolveDestination = function()
      return { destinationMap = { mapId = 60 }, fieldX = 0, fieldZ = 0, surfaceId = 0, worldY = 0 }
    end,
    prepare = function(result)
      return result
    end,
    commit = function() end,
  })

  local err = Assert.throws(function()
    transition:start({ mapId = 61 }, {
      warp = { index = 0, destinationMapId = 60, destinationWarpId = 0, x = 4, z = 4 },
      transition = { mode = "fixed", profile = FieldTransitionProfile.ESCALATOR },
    }, "east")
  end)
  Assert.isTrue(string.find(tostring(err), "escalator transition step could not start", 1, true) ~= nil)
  Assert.equal(transition.phase, FieldTransition.PHASES.idle)
  Assert.isFalse(transition.locked)
  Assert.equal(transition.error, err)
  Assert.isFalse(player.animationPaused)
  Assert.isFalse(transition:updateSourceFrame())
end

T.tests.transition_profiles_preserve_source_semantics = function()
  Assert.equal(FieldTransitionProfile.fixed(1).profile, 1)
  Assert.equal(FieldTransitionProfile.fixed(3).profile, 3)
  Assert.equal(FieldTransitionProfile.selectEnvironment("building", "building"), 6)
  Assert.equal(FieldTransitionProfile.selectEnvironment("building", "outdoors"), 0)
end

function T.tests.all_fixed_profiles_are_explicit_and_panel_has_no_numeric_profile()
  for profile = 0, 8 do
    Assert.equal(FieldTransitionProfile.fixed(profile).profile, profile)
  end
  Assert.throws(function()
    FieldTransitionProfile.fixed(-1)
  end, "negative transition profiles are invalid")
  Assert.throws(function()
    FieldTransitionProfile.fixed(9)
  end, "unknown transition profiles are invalid")

  local transition = FieldTransition.new({
    loader = {
      requestWarp = function()
        return true
      end,
    },
    prepare = function() end,
    commit = function() end,
  })
  transition:start(
    { mapId = 61 },
    { warp = { index = 0, destinationMapId = 60, destinationWarpId = 0 }, transition = { mode = "panel" } },
    "north"
  )
  Assert.isNil(transition.profileId)
  Assert.equal(transition.transitionMode, FieldTransitionProfile.MODE_PANEL)
end

function T.tests.ordinary_profiles_share_source_exit_audio_and_fade()
  local observations = {}
  for _, profile in ipairs({ FieldTransitionProfile.ORDINARY, FieldTransitionProfile.ORDINARY_INDOOR }) do
    local sounds = {}
    local transition = FieldTransition.new({
      loader = {
        requestWarp = function()
          return true
        end,
      },
      prepare = function() end,
      commit = function() end,
      playSound = function(sound)
        sounds[#sounds + 1] = sound
      end,
    })
    transition:start({ mapId = 61 }, {
      warp = { index = 0, destinationMapId = 60, destinationWarpId = 0 },
      transition = { mode = "fixed", profile = profile },
    }, "north")
    observations[#observations + 1] = {
      profile = profile,
      sounds = sounds,
      fade = transition.fade:status(),
    }
    Assert.isTrue(transition:updateSourceFrame(), "ordinary source fade advances at start")
  end

  Assert.deepEqual(observations[1].sounds, { "SEQ_SE_DP_KAIDAN2" }, "profile 0 source exit audio")
  Assert.deepEqual(observations[2].sounds, observations[1].sounds, "profile 6 shares profile 0 source exit audio")
  Assert.equal(observations[2].fade.coefficient, observations[1].fade.coefficient)
end

function T.tests.west_indoor_entry_plays_exit_sound_and_fades_with_no_entry_step()
  local sounds = {}
  local steps = {}
  local player = {
    motion = "idle",
    beginTransitionStep = function(self, direction)
      steps[#steps + 1] = direction
      self.motion = "walking"
      return true
    end,
    updateFixed = function(self)
      self.motion = "idle"
      return true
    end,
  }
  local transition = FieldTransition.new({
    loader = {
      requestWarp = function()
        return true
      end,
    },
    player = player,
    resolveDestination = function()
      return {
        destinationMap = { mapId = 60 },
        fieldX = 4,
        fieldZ = 4,
        surfaceId = 0,
        worldY = 0,
      }
    end,
    prepare = function() end,
    commit = function() end,
    playSound = function(sound)
      sounds[#sounds + 1] = sound
    end,
  })
  transition:start({ mapId = 61 }, {
    warp = { index = 0, destinationMapId = 60, destinationWarpId = 0 },
    transition = { mode = "fixed", profile = FieldTransitionProfile.ORDINARY_INDOOR },
    destinationFacing = "west",
  }, "south")
  advanceTo(transition, "idle", 128)
  Assert.equal(transition.phase, "idle", "the west indoor entry completes")
  Assert.deepEqual(sounds, { "SEQ_SE_DP_KAIDAN2" }, "the west indoor entry plays the exit sound once")
  Assert.deepEqual(steps, {}, "the west indoor entry authors no player step")
  Assert.deepEqual(
    transition.completed,
    { sourceMapId = 61, destinationMapId = 60, sourceWarpId = 0 },
    "the fade lifecycle completes through the destination swap"
  )
end

local function ladderSourceFixture(profile)
  local sounds = {}
  local updates = 0
  local player = {
    motion = "idle",
    beginTransitionLadderExit = function(self)
      self.motion = "transition"
      return true
    end,
    beginTransitionLadderDownExit = function(self)
      self.motion = "transition"
      return true
    end,
    updateFixed = function(self)
      updates = updates + 1
      if updates == 16 then
        self.motion = "idle"
      end
      return true
    end,
  }
  local transition = FieldTransition.new({
    loader = {
      requestWarp = function()
        return true
      end,
    },
    player = player,
    resolveDestination = function()
      return {
        destinationMap = { mapId = 60 },
        fieldX = 4,
        fieldZ = 4,
        surfaceId = 0,
        worldY = 0,
      }
    end,
    prepare = function(result)
      return result
    end,
    commit = function() end,
    playSound = function(sound)
      sounds[#sounds + 1] = sound
    end,
  })
  transition:start({ mapId = 61 }, {
    warp = { index = 0, destinationMapId = 60, destinationWarpId = 0 },
    transition = { mode = "fixed", profile = profile },
  }, "north")
  return transition, player, sounds
end

function T.tests.ladder_source_motion_finishes_before_sound_and_fade()
  for _, profile in ipairs({ FieldTransitionProfile.LADDER, FieldTransitionProfile.LADDER_DOWN }) do
    local transition, player, sounds = ladderSourceFixture(profile)
    Assert.equal(player.motion, "transition")
    Assert.deepEqual(sounds, {})
    Assert.isFalse(transition:updateSourceFrame())
    Assert.equal(transition:presentationStatus().coefficient, 0)

    for _ = 1, 15 do
      transition:updateFixed()
      Assert.equal(player.motion, "transition")
      Assert.deepEqual(sounds, {})
      Assert.isFalse(transition:updateSourceFrame())
      Assert.equal(transition:presentationStatus().coefficient, 0)
    end

    transition:updateFixed()
    Assert.equal(player.motion, "idle")
    Assert.deepEqual(sounds, { "SEQ_SE_DP_KAIDAN2" })
    Assert.equal(transition:presentationStatus().coefficient, 0)
    Assert.isTrue(transition:updateSourceFrame())
    Assert.equal(transition:presentationStatus().coefficient, 2)
  end
end

function T.tests.ordinary_profile_exit_audio_is_played_once()
  local sounds = {}
  local transition = FieldTransition.new({
    loader = {
      requestWarp = function()
        return true
      end,
    },
    resolveDestination = function()
      return { destinationMap = { mapId = 60 }, fieldX = 0, fieldZ = 0, surfaceId = 0, worldY = 0 }
    end,
    prepare = function() end,
    commit = function() end,
    playSound = function(sound)
      sounds[#sounds + 1] = sound
    end,
  })
  transition:start({ mapId = 61 }, {
    warp = { index = 0, destinationMapId = 60, destinationWarpId = 0 },
    transition = { mode = "fixed", profile = FieldTransitionProfile.ORDINARY },
  }, "north")
  advanceTo(transition, "idle", 128)
  Assert.equal(transition.phase, "idle")
  Assert.deepEqual(sounds, { "SEQ_SE_DP_KAIDAN2" })
end

function T.tests.transition_motion_profiles_require_the_player_motion_contract()
  local transition = FieldTransition.new({
    loader = {
      requestWarp = function()
        return true
      end,
    },
    prepare = function() end,
    commit = function() end,
  })
  Assert.throws(function()
    transition:start({ mapId = 61 }, {
      warp = { index = 0, destinationMapId = 60, destinationWarpId = 0 },
      transition = { mode = "fixed", profile = FieldTransitionProfile.ESCALATOR },
    }, "south")
  end, "transition movement profiles require semantic player motion")
end

function T.tests.field_transition_consumes_trigger_profile_before_ownership()
  local metadataCalls = 0
  local loader = {
    transitionEnvironment = function(_, mapId)
      metadataCalls = metadataCalls + 1
      Assert.equal(mapId, 60)
      return "building"
    end,
    load = function()
      error("profile selection must not load a destination map", 0)
    end,
    requestWarp = function()
      return true
    end,
  }
  local transition = FieldTransition.new({
    loader = loader,
    resolveDestination = function()
      return {
        destinationMap = { mapId = 60 },
        fieldX = 0,
        fieldZ = 0,
        surfaceId = 0,
        worldY = 0,
      }
    end,
    prepare = function() end,
    commit = function() end,
  })

  transition:start({ mapId = 61, fieldData = { transitionEnvironment = "outdoors" } }, {
    warp = { index = 0, destinationMapId = 60, destinationWarpId = 0 },
    transition = { mode = "environment" },
  }, "east")
  Assert.equal(transition.profileId, 6)
  Assert.equal(metadataCalls, 1)
  Assert.isTrue(transition.locked)
end

function T.tests.field_transition_rejects_unsupported_environment_before_lock()
  local transition = FieldTransition.new({
    loader = {
      transitionEnvironment = function()
        return "outdoors"
      end,
      requestWarp = function()
        return true
      end,
    },
    prepare = function() end,
    commit = function() end,
  })

  local ok, err = pcall(function()
    transition:start({ mapId = 61, fieldData = { transitionEnvironment = "outdoors" } }, {
      warp = { index = 0, destinationMapId = 60, destinationWarpId = 0 },
      transition = { mode = "environment" },
    }, "east")
  end)
  Assert.isFalse(ok)
  if type(err) ~= "table" then
    error("expected a structured transition profile error")
  end
  Assert.equal(err.code, "MAP_TRANSITION_PROFILE_UNSUPPORTED")
  Assert.equal(transition.phase, "idle")
  Assert.isFalse(transition.locked)
end

function T.tests.field_transition_uses_trigger_destination_facing()
  local receivedFacing
  local player = {
    motion = "idle",
    pauseTransitionAnimation = function() end,
    resumeTransitionAnimation = function() end,
    beginTransitionStep = function(self, facing)
      self.motion = "idle"
      self.facing = facing
      return true
    end,
    updateFixed = function() end,
  }
  local transition = FieldTransition.new({
    loader = {
      requestWarp = function()
        return true
      end,
    },
    resolveDestination = function()
      return { destinationMap = { mapId = 60 }, fieldX = 0, fieldZ = 0, surfaceId = 0, worldY = 0 }
    end,
    prepare = function(_, facing)
      receivedFacing = facing
    end,
    commit = function() end,
    player = player,
    escalatorAt = function()
      return {
        play = function() end,
        isFinished = function()
          return true
        end,
      }
    end,
  })
  transition:start({ mapId = 61 }, {
    warp = { index = 0, destinationMapId = 60, destinationWarpId = 0 },
    transition = { mode = "fixed", profile = FieldTransitionProfile.ESCALATOR },
    destinationFacing = "west",
  }, "east")
  advanceTo(transition, "swap_map", 10)
  Assert.equal(receivedFacing, "west")
end

local function runTransition(options)
  local source = { mapId = 61 }
  local destination = { mapId = 60 }
  local player = options.player
    or {
      motion = "idle",
      scriptedStep = function()
        return true
      end,
      updateFixed = function() end,
    }
  local transition = FieldTransition.new({
    loader = {
      requestWarp = function()
        return true
      end,
    },
    resolveDestination = function()
      return {
        destinationMap = destination,
        destinationWarp = { x = 4, z = 14 },
        fieldX = 4,
        fieldZ = 13,
        surfaceId = 0,
        worldY = 0,
      }
    end,
    prepare = function() end,
    commit = function() end,
    doorAt = function(map)
      if map == source then
        if options.doorAt then
          return options.doorAt()
        end
        return options.sourceDoor
      end
      return options.destinationDoor or (options.doorAt and options.doorAt())
    end,
    playSound = options.playSound,
    player = player,
  })
  transition:start(source, {
    kind = "door",
    warp = { index = 0, x = 684, z = 393, destinationMapId = 60, destinationWarpId = 0 },
    destinationFacing = options.destinationFacing,
  }, "north")
  advanceTo(transition, "idle", 128)
  Assert.equal(transition.phase, "idle", "the pure transition fixture must complete")
end

local function instantDoor(soundType)
  local open = {
    [1] = "SEQ_SE_DP_DOOR_OPEN",
    [2] = "SEQ_SE_DP_DOOR10",
    [3] = "SEQ_SE_PL_DOOR_OPEN5",
    [4] = "SEQ_SE_GS_HIKIDO_OPEN",
  }
  local close = {
    [1] = "SEQ_SE_DP_DOOR_CLOSE2",
    [2] = nil,
    [3] = nil,
    [4] = "SEQ_SE_GS_HIKIDO_CLOSE",
  }
  return {
    soundType = soundType,
    open = function()
      return open[soundType]
    end,
    close = function()
      return close[soundType]
    end,
    isFinished = function()
      return true
    end,
  }
end

function T.tests.door_audio_comes_only_from_door_operations()
  local sounds = {}
  local door = {
    soundType = 1,
    open = function()
      return "SEQ_FROM_OPEN"
    end,
    close = function()
      return nil
    end,
    isFinished = function()
      return true
    end,
  }
  runTransition({
    doorAt = function()
      return door
    end,
    playSound = function(sound)
      sounds[#sounds + 1] = sound
    end,
  })
  Assert.deepEqual(sounds, { "SEQ_FROM_OPEN" })
end

function T.tests.door_sound_selector_emits_exact_open_and_close_sequences()
  local expected = {
    [1] = { "SEQ_SE_DP_DOOR_OPEN", "SEQ_SE_DP_DOOR_CLOSE2" },
    [2] = { "SEQ_SE_DP_DOOR10" },
    [3] = { "SEQ_SE_PL_DOOR_OPEN5" },
    [4] = { "SEQ_SE_GS_HIKIDO_OPEN", "SEQ_SE_GS_HIKIDO_CLOSE" },
  }
  for soundType = 1, 4 do
    local sounds = {}
    local door = instantDoor(soundType)
    runTransition({
      doorAt = function()
        return door
      end,
      playSound = function(sequence)
        sounds[#sounds + 1] = sequence
      end,
    })
    Assert.deepEqual(sounds, expected[soundType], "door sound selector " .. soundType)
  end
end

function T.tests.door_profile_uses_destination_door_and_facing_asymmetric_steps()
  local function runCase(destinationDoor, destinationFacing)
    local player = {
      motion = "idle",
      steps = {},
      scriptedStep = function(self, direction)
        self.steps[#self.steps + 1] = direction
        self.motion = "idle"
        return true
      end,
    }
    runTransition({
      sourceDoor = instantDoor(1),
      destinationDoor = destinationDoor and instantDoor(1) or nil,
      destinationFacing = destinationFacing,
      player = player,
    })
    return player.steps
  end

  Assert.deepEqual(runCase(false, "north"), { "north" })
  Assert.deepEqual(runCase(false, "south"), { "north", "south" })
  Assert.deepEqual(runCase(true, "north"), { "north", "south" })
end

function T.tests.nonordinary_profiles_dispatch_exit_enter_and_camera_families()
  local events = {}
  local player = {
    motion = "idle",
    facing = "south",
    pauseTransitionAnimation = function() end,
    resumeTransitionAnimation = function() end,
    beginTransitionStep = function(self, facing)
      events[#events + 1] = { phase = "movement", family = "step:" .. facing }
      self.motion = "transition"
      self.transitionTicks = 0
      self.facing = facing
      return true
    end,
    beginTransitionLadderExit = function(self, facing)
      events[#events + 1] = { phase = "movement", family = "ladder_exit:" .. facing }
      self.motion = "transition"
      self.transitionTicks = 0
      return true
    end,
    beginTransitionLadderDownExit = function(self, facing)
      events[#events + 1] = { phase = "movement", family = "ladder_down_exit:" .. facing }
      self.motion = "transition"
      self.transitionTicks = 0
      return true
    end,
    beginTransitionVerticalReturn = function(self)
      self.motion = "transition"
      self.transitionTicks = 0
      return true
    end,
    updateFixed = function(self)
      self.transitionTicks = self.transitionTicks + 1
      if self.transitionTicks == 1 then
        self.motion = "idle"
      end
      return true
    end,
  }
  local transition = FieldTransition.new({
    loader = {
      requestWarp = function()
        return true
      end,
    },
    resolveDestination = function()
      return { destinationMap = { mapId = 60 }, fieldX = 0, fieldZ = 0, surfaceId = 0, worldY = 0 }
    end,
    prepare = function() end,
    commit = function() end,
    player = player,
    onProfile = function(profile, phase, family, ...)
      events[#events + 1] = {
        profile = profile,
        phase = phase,
        family = family,
        argumentCount = select("#", profile, phase, family, ...),
      }
    end,
    cameraAdjust = function(profile, adjustment)
      events[#events + 1] = { profile = profile, phase = "camera", family = adjustment }
    end,
    escalatorAt = function()
      return {
        play = function() end,
        isFinished = function()
          return true
        end,
      }
    end,
  })

  for _, profile in ipairs({ 2, 4, 5, 7, 8 }) do
    events = {}
    transition:start({ mapId = 61 }, {
      warp = { index = 0, destinationMapId = 60, destinationWarpId = 0 },
      transition = { mode = "fixed", profile = profile },
    }, "south")
    advanceTo(transition, "idle", 128)
    Assert.equal(transition.phase, "idle", "profile " .. profile .. " completes")
    Assert.equal(events[1].profile, profile)
    Assert.equal(events[1].phase, "exit")
    Assert.equal(events[1].family, FieldTransitionProfile.ROUTINE_FAMILIES[profile].exit)
    Assert.equal(events[1].argumentCount, 3)
    local enter
    for _, event in ipairs(events) do
      if event.phase == "enter" then
        enter = event
        break
      end
    end
    Assert.notNil(enter, "profile " .. profile .. " must dispatch its enter routine")
    Assert.equal(enter.profile, profile)
    Assert.equal(enter.family, FieldTransitionProfile.ROUTINE_FAMILIES[profile].enter)
    local camera = FieldTransitionProfile.ROUTINE_FAMILIES[profile].adjustment
    if camera then
      local cameraEvent
      for _, event in ipairs(events) do
        if event.phase == "camera" then
          cameraEvent = event
          break
        end
      end
      Assert.notNil(cameraEvent, "profile " .. profile .. " must adjust the camera")
      Assert.equal(cameraEvent.family, camera)
    else
      for _, event in ipairs(events) do
        Assert.isFalse(event.phase == "camera", "profile " .. profile .. " must not adjust the camera")
      end
    end
  end
end

function T.tests.panel_lifecycle_notifies_each_side_once_without_profile_dispatch()
  local panels = {}
  local profiles = {}
  local cameras = {}
  local commits = 0
  local transition = FieldTransition.new({
    loader = {
      requestWarp = function()
        return true
      end,
    },
    resolveDestination = function()
      return { destinationMap = { mapId = 60 }, fieldX = 0, fieldZ = 0, surfaceId = 0, worldY = 0 }
    end,
    prepare = function() end,
    commit = function()
      commits = commits + 1
    end,
    onPanel = function(phase)
      panels[#panels + 1] = phase
    end,
    onProfile = function()
      profiles[#profiles + 1] = true
    end,
    cameraAdjust = function()
      cameras[#cameras + 1] = true
    end,
  })
  transition:start({ mapId = 61 }, {
    warp = { index = 0, destinationMapId = 60, destinationWarpId = 0 },
    transition = { mode = "panel" },
  }, "south")
  for _ = 1, 10 do
    if transition.phase == "idle" then
      break
    end
    step(transition)
  end
  -- The synthetic panel mode notifies each side exactly once and commits once;
  -- it dispatches no numeric profile family and adjusts no camera, so the
  -- notification never grows into a speculative rendered effect.
  Assert.deepEqual(panels, { "exit", "enter" })
  Assert.deepEqual(profiles, {})
  Assert.deepEqual(cameras, {})
  Assert.equal(commits, 1, "the panel lifecycle commits the shared destination once")
  Assert.notNil(transition.completed, "the panel lifecycle records one completion")
end

function T.tests.profile_hook_failure_aborts_before_commit_but_after_commit_propagates()
  local commits = 0
  local before = FieldTransition.new({
    loader = {
      requestWarp = function()
        return true
      end,
    },
    onProfile = function(_, phase)
      if phase == "exit" then
        error("exit failed", 0)
      end
    end,
    prepare = function() end,
    commit = function()
      commits = commits + 1
    end,
  })
  local ok, err = pcall(function()
    before:start({ mapId = 61 }, {
      warp = { index = 0, destinationMapId = 60, destinationWarpId = 0 },
      transition = { mode = "fixed", profile = 4 },
    }, "south")
  end)
  Assert.isFalse(ok)
  Assert.equal(tostring(err), "exit failed")
  Assert.equal(before.phase, "idle")
  Assert.isFalse(before.locked)
  Assert.isNil(before.sourceMap)
  Assert.equal(tostring(before.error), "exit failed")
  Assert.equal(commits, 0)

  local after = FieldTransition.new({
    loader = {
      requestWarp = function()
        return true
      end,
    },
    resolveDestination = function()
      return { destinationMap = { mapId = 60 }, fieldX = 0, fieldZ = 0, surfaceId = 0, worldY = 0 }
    end,
    prepare = function() end,
    commit = function() end,
    onProfile = function(_, phase)
      if phase == "enter" then
        error("enter failed", 0)
      end
    end,
  })
  after:start({ mapId = 61 }, {
    warp = { index = 0, destinationMapId = 60, destinationWarpId = 0 },
    transition = { mode = "fixed", profile = 4 },
  }, "south")
  advanceTo(after, "swap_map", 128)
  local enterOk, enterErr = pcall(after.updateFixed, after)
  Assert.isFalse(enterOk)
  Assert.equal(tostring(enterErr), "enter failed")
  Assert.equal(after.phase, "swap_map")
end

-- The profile-8 preview special reuses the player-owned vertical return, so
-- its duration argument must stay backwards-compatible: no override keeps the
-- ordinary sixteen fixed ticks, while the preview route's eight ticks descend
-- through the very same interpolation and reach the anchor exactly. Only a
-- validated positive integer override is accepted.
local function verticalReturnPlayer()
  local EMPTY_MAP_PROPS = {}
  ---@cast EMPTY_MAP_PROPS MapProps
  local ROOT_HALF = math.sqrt(0.5)
  local map = {
    mapId = 60,
    mapSymbol = "test-map",
    mapSection = "test-section",
    mapSectionNativeId = 7,
    followMode = "ALLOW",
    coordinateOrigin = { x = 0, z = 0 },
    scene = {},
    fieldData = {},
    collision = {
      containsLocal = function(_, x, z)
        return x >= 0 and x < 32 and z >= 0 and z < 32
      end,
      isBlockedLocal = function()
        return false
      end,
      getLocal = function()
        return { blocked = false }
      end,
    },
    terrain = TerrainSurface.new({
      plates = {
        {
          id = 0,
          minX = 0,
          minZ = 0,
          maxX = 32,
          maxZ = 32,
          normal = { x = -ROOT_HALF, y = ROOT_HALF, z = 0 },
          distance = 0,
          slopeClass = "flat",
        },
      },
    }),
    terrainDependencyHash = "test-terrain",
    mapProps = EMPTY_MAP_PROPS,
    fieldRegion = {},
    cameraType = 0,
    release = function() end,
    updateAnimated = function() end,
  } --[[@as RuntimeFieldMap]]
  return FieldPlayer.new({ currentMap = map, fieldX = 0, fieldZ = 4, surfaceId = 0, facing = "south" })
end

function T.tests.vertical_return_keeps_sixteen_default_ticks_and_accepts_the_preview_eight()
  local ordinary = verticalReturnPlayer()
  Assert.isTrue(ordinary:beginTransitionVerticalReturn(2))
  Assert.equal(ordinary.durationTicks, 16, "an unqualified vertical return keeps the ordinary sixteen fixed ticks")
  local defaultTicks = 0
  while ordinary.motion == "transition" do
    ordinary:updateFixed()
    defaultTicks = defaultTicks + 1
    Assert.isTrue(defaultTicks <= 40, "the default vertical return must complete within a bounded tick count")
  end
  Assert.equal(defaultTicks, 16, "the default vertical return interpolates for sixteen fixed ticks")

  local preview = verticalReturnPlayer()
  Assert.isTrue(preview:beginTransitionVerticalReturn(2, 8))
  Assert.equal(preview.durationTicks, 8, "the preview special descends over eight fixed ticks")
  local previewTicks = 0
  while preview.motion == "transition" do
    preview:updateFixed()
    previewTicks = previewTicks + 1
    Assert.isTrue(previewTicks <= 40, "the preview vertical return must complete within a bounded tick count")
  end
  Assert.equal(previewTicks, 8, "the preview special interpolates for eight fixed ticks")
end

function T.tests.vertical_return_rejects_a_duration_that_is_not_a_positive_integer()
  for _, invalid in ipairs({ 0, -1, 1.5, "8" }) do
    local player = verticalReturnPlayer()
    Assert.throws(function()
      player:beginTransitionVerticalReturn(2, invalid)
    end, "the vertical return must reject an invalid duration override: " .. tostring(invalid))
    Assert.equal(player.motion, "idle", "a rejected duration override leaves the player idle")
  end
end

-- Nine-profile source dispatch census -------------------------------------

-- The complete source routine-family table, pinned to the retail ROM's
-- 9-entry exit/enter/camera/audio dispatch. This is the single frozen table the
-- runtime dispatch is compared against; the lifecycle censuses below prove the
-- runtime reaches exactly these routines.
function T.tests.source_routine_family_table_is_the_frozen_nine_profile_dispatch()
  Assert.deepEqual(FieldTransitionProfile.ROUTINE_FAMILIES, {
    [0] = { exit = "ordinary_exit", enter = "ordinary_enter", exitSound = "SEQ_SE_DP_KAIDAN2" },
    [1] = { exit = "door_exit", enter = "door_enter", entryAction = "step_down" },
    [2] = {
      exit = "escalator_exit",
      enter = "escalator_enter",
      adjustment = "escalator",
      exitSound = "SEQ_SE_DP_ESUKA",
    },
    [3] = {
      exit = "horizontal_stairs_exit",
      enter = "horizontal_stairs_enter",
      adjustment = "horizontal_stairs",
      exitSound = "SEQ_SE_DP_KAIDAN2",
    },
    [4] = {
      exit = "cave_exit",
      enter = "door_enter",
      adjustment = "cave",
      exitSound = "SEQ_SE_DP_KAIDAN2",
      fadeMode = "environment_0x10",
    },
    [5] = {
      exit = "outdoor_exit",
      enter = "outdoor_enter",
      adjustment = "outdoor",
      exitSound = "SEQ_SE_DP_KAIDAN2",
      fadeColor = 0x7FFF,
    },
    [6] = { exit = "ordinary_exit", enter = "indoor_enter", exitSound = "SEQ_SE_DP_KAIDAN2" },
    [7] = {
      exit = "ladder_up",
      enter = "ladder_enter",
      adjustment = "ladder",
      exitSound = "SEQ_SE_DP_KAIDAN2",
    },
    [8] = {
      exit = "ladder_down",
      enter = "ladder_down_enter",
      adjustment = "ladder_down",
      exitSound = "SEQ_SE_DP_KAIDAN2",
    },
  })
end

-- A player stub that satisfies every profile's source and destination motion
-- contract and records which begin method the transition invoked.
local function profileDispatchPlayer(events)
  return {
    motion = "idle",
    facing = "south",
    turn = function(self, facing)
      self.facing = facing
    end,
    pauseTransitionAnimation = function() end,
    resumeTransitionAnimation = function() end,
    updateFixed = function(self)
      self.transitionTicks = (self.transitionTicks or 0) + 1
      if self.transitionTicks == 1 then
        self.motion = "idle"
      end
      return true
    end,
    beginTransitionStep = function(self, facing)
      events[#events + 1] = { at = "player", method = "step", facing = facing }
      self.motion = "transition"
      self.transitionTicks = 0
      return true
    end,
    beginTransitionHeldStair = function(self)
      events[#events + 1] = { at = "player", method = "held_stair" }
      self.motion = "transition"
      self.transitionTicks = 0
      return true
    end,
    beginTransitionLadderExit = function(self, facing)
      events[#events + 1] = { at = "player", method = "ladder_exit", facing = facing }
      self.motion = "transition"
      self.transitionTicks = 0
      return true
    end,
    beginTransitionLadderDownExit = function(self, facing)
      events[#events + 1] = { at = "player", method = "ladder_down_exit", facing = facing }
      self.motion = "transition"
      self.transitionTicks = 0
      return true
    end,
    beginTransitionVerticalReturn = function(self)
      events[#events + 1] = { at = "player", method = "vertical_return" }
      self.motion = "transition"
      self.transitionTicks = 0
      return true
    end,
  }
end

-- The horizontal-stair destination presentation needs a stair behavior byte
-- and a covering plate: the runtime derives the visual start cell from the
-- destination warp's behavior before the swap.
local STAIR_ROOT_HALF = math.sqrt(0.5)

local function stairDestinationMap()
  return {
    mapId = 60,
    coordinateOrigin = { x = 0, z = 0 },
    collision = {
      containsLocal = function()
        return true
      end,
      getLocal = function()
        return { behavior = MetatileBehavior.BEHAVIOR.WARP_STAIRS_WEST }
      end,
    },
    terrain = TerrainSurface.new({
      plates = {
        {
          id = 0,
          minX = 0,
          minZ = 0,
          maxX = 64,
          maxZ = 64,
          normal = { x = -STAIR_ROOT_HALF, y = STAIR_ROOT_HALF, z = 0 },
          distance = 0,
          slopeClass = "flat",
        },
      },
    }),
  }
end

local function censusDestination(profile)
  if profile == FieldTransitionProfile.HORIZONTAL_STAIRS then
    return stairDestinationMap()
  end
  return { mapId = 60 }
end

local function profileEvents(events, phase)
  for index, event in ipairs(events) do
    if event.at == "profile" and event.phase == phase then
      return index, event
    end
  end
  return nil, nil
end

-- A single complete lifecycle census over profiles 0..8: each drives one
-- transition through its source exit, the one commit, and its destination
-- enter, and reaches exactly the routine family, camera adjustment, and
-- source exit audio the frozen table names.
function T.tests.all_nine_profiles_dispatch_exit_enter_camera_and_one_commit()
  for profile = 0, 8 do
    local expected = FieldTransitionProfile.ROUTINE_FAMILIES[profile]
    local events = {}
    local sounds = {}
    local player = profileDispatchPlayer(events)
    local transition
    transition = FieldTransition.new({
      loader = {
        requestWarp = function()
          return true
        end,
      },
      player = player,
      resolveDestination = function()
        return {
          destinationMap = censusDestination(profile),
          destinationWarp = { x = 4, z = 4 },
          fieldX = 4,
          fieldZ = 4,
          surfaceId = 0,
          worldY = 0,
        }
      end,
      prepare = function() end,
      commit = function()
        events[#events + 1] = { at = "commit" }
      end,
      onProfile = function(profileId, phase, family)
        events[#events + 1] = { at = "profile", profileId = profileId, phase = phase, family = family }
      end,
      cameraAdjust = function(profileId, adjustment)
        events[#events + 1] = { at = "camera", profileId = profileId, family = adjustment }
      end,
      playSound = function(sound)
        sounds[#sounds + 1] = sound
      end,
      stopSound = function() end,
      escalatorAt = function()
        return {
          play = function() end,
          isFinished = function()
            return true
          end,
        }
      end,
    })
    transition.player = player
    transition:start({ mapId = 61 }, {
      kind = "generic",
      warp = { index = 0, x = 4, z = 4, destinationMapId = 60, destinationWarpId = 0 },
      transition = { mode = "fixed", profile = profile },
    }, "north")
    advanceTo(transition, "idle", 256)
    Assert.equal(transition.phase, "idle", "profile " .. profile .. " completes")

    local exitIndex, exitEvent = profileEvents(events, "exit")
    local enterIndex, enterEvent = profileEvents(events, "enter")
    Assert.notNil(exitEvent, "profile " .. profile .. " dispatches its source exit routine")
    Assert.equal(exitEvent.profileId, profile, "profile " .. profile .. " source dispatch carries its profile")
    Assert.equal(exitEvent.family, expected.exit, "profile " .. profile .. " source exit family")
    Assert.notNil(enterEvent, "profile " .. profile .. " dispatches its destination enter routine")
    Assert.equal(enterEvent.profileId, profile, "profile " .. profile .. " enter dispatch carries its profile")
    Assert.equal(enterEvent.family, expected.enter, "profile " .. profile .. " destination enter family")

    local commitIndex
    local commitCount = 0
    for index, event in ipairs(events) do
      if event.at == "commit" then
        commitIndex = commitIndex or index
        commitCount = commitCount + 1
      end
    end
    Assert.equal(commitCount, 1, "profile " .. profile .. " commits the shared destination exactly once")
    Assert.isTrue(exitIndex < commitIndex, "profile " .. profile .. " exits before the commit")
    Assert.isTrue(commitIndex < enterIndex, "profile " .. profile .. " enters after the commit")

    if expected.adjustment then
      local cameraEvent
      for _, event in ipairs(events) do
        if event.at == "camera" then
          cameraEvent = cameraEvent or event
          Assert.equal(event.profileId, profile, "profile " .. profile .. " camera carries its profile")
          Assert.equal(event.family, expected.adjustment, "profile " .. profile .. " camera adjustment")
        end
      end
      Assert.notNil(cameraEvent, "profile " .. profile .. " adjusts the camera with " .. expected.adjustment)
    else
      for _, event in ipairs(events) do
        Assert.isFalse(event.at == "camera", "profile " .. profile .. " adjusts no camera")
      end
    end

    if expected.exitSound then
      Assert.deepEqual(sounds, { expected.exitSound }, "profile " .. profile .. " plays its source exit sound once")
    else
      Assert.deepEqual(sounds, {}, "profile " .. profile .. " has no source exit sound")
    end

    Assert.notNil(transition.completed, "profile " .. profile .. " records a completion")
    Assert.notNil(transition:consumeCompleted(), "profile " .. profile .. " hands back one completion token")
    Assert.isNil(transition:consumeCompleted(), "profile " .. profile .. " never completes twice")
  end
end

-- The source-selected preview replacement is a property of every profile, not
-- profiles 0 and 8 alone: when the selector returns a preview the ordinary
-- destination enter choreography never runs, the preview substate owns the
-- reveal, and the one commit/completion contract is unchanged.
function T.tests.every_profile_preview_replaces_the_ordinary_destination_choreography()
  for profile = 0, 8 do
    local events = {}
    local player = profileDispatchPlayer(events)
    local selections = {}
    local transition
    transition = FieldTransition.new({
      loader = {
        requestWarp = function()
          return true
        end,
      },
      player = player,
      selectPreview = function(sourceMap, destinationMap, profileId)
        selections[#selections + 1] = {
          sourceMapId = sourceMap.mapId,
          destinationMapId = destinationMap.mapId,
          profileId = profileId,
        }
        return { imageKey = "preview.test", timeSlot = 1, profileId = profileId }
      end,
      resolveDestination = function()
        return {
          destinationMap = censusDestination(profile),
          destinationWarp = { x = 4, z = 4 },
          fieldX = 4,
          fieldZ = 4,
          surfaceId = 0,
          worldY = 0,
        }
      end,
      prepare = function() end,
      commit = function()
        events[#events + 1] = { at = "commit" }
      end,
      onProfile = function(profileId, phase, family)
        events[#events + 1] = { at = "profile", profileId = profileId, phase = phase, family = family }
      end,
      cameraAdjust = function(profileId, adjustment)
        events[#events + 1] = { at = "camera", profileId = profileId, family = adjustment }
      end,
      playSound = function() end,
      stopSound = function() end,
      escalatorAt = function()
        return {
          play = function() end,
          isFinished = function()
            return true
          end,
        }
      end,
    })
    transition.player = player
    transition:start({ mapId = 61 }, {
      kind = "generic",
      warp = { index = 0, x = 4, z = 4, destinationMapId = 60, destinationWarpId = 0 },
      transition = { mode = "fixed", profile = profile },
    }, "north")

    local sawPreview = false
    local ticks = 0
    while transition.phase ~= "idle" and transition.phase ~= "error" and ticks < 256 do
      ticks = ticks + 1
      transition:updateFixed()
      transition:updateSourceFrame()
      if transition.phase == FieldTransition.PHASES.preview then
        sawPreview = true
      end
    end
    Assert.equal(transition.phase, "idle", "profile " .. profile .. " preview completes")
    Assert.isTrue(sawPreview, "profile " .. profile .. " enters the preview substate")
    Assert.equal(#selections, 1, "profile " .. profile .. " consults the preview selector once")
    Assert.equal(selections[1].sourceMapId, 61)
    Assert.equal(selections[1].destinationMapId, 60)
    Assert.equal(selections[1].profileId, profile, "profile " .. profile .. " selects its own preview")

    for _, event in ipairs(events) do
      Assert.isFalse(
        event.at == "profile" and event.phase == "enter",
        "profile " .. profile .. " preview replaces the ordinary destination enter"
      )
    end

    local commitIndex
    for index, event in ipairs(events) do
      if event.at == "commit" then
        commitIndex = index
      end
    end
    local destinationMotion = {}
    for index = (commitIndex or 0) + 1, #events do
      if events[index].at == "player" then
        destinationMotion[#destinationMotion + 1] = events[index].method
      end
    end
    if profile == FieldTransitionProfile.LADDER_DOWN then
      Assert.deepEqual(destinationMotion, { "vertical_return" }, "the profile-8 preview owns its arrival")
    else
      Assert.deepEqual(destinationMotion, {}, "profile " .. profile .. " preview runs no destination motion")
    end
    Assert.notNil(transition.completed, "profile " .. profile .. " preview records one completion")
  end
end

return T
