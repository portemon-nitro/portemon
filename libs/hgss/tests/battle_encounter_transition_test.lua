local Assert = require("tests.support.Assert")
local BattleEncounterTransition = require("libs.hgss.src.transition.BattleEncounterTransition")
local TransitionFamilyFactory = require("libs.hgss.src.transition.TransitionFamilyFactory")

local T = {}

local function fixture()
  local event = nil
  local steps = 0
  local disposed = 0
  local cacheFs = {
    loadLua = function(_, path)
      return { path = path }
    end,
  }
  local manifest = {
    transitions = {
      routes = {
        ["trainer/red"] = {
          role = "red-trainer-transition",
          resources = { "transition/red/character" },
        },
      },
      selection = {
        trainerClassRoutes = { RIVAL = "trainer/red" },
        trainerClassMusicRoles = { RIVAL = "rival" },
        trainerRules = {
          specialBattle = {
            preserveRoute = "trainer/red",
            defaultRoute = "trainer/red",
            defaultMusicRole = "trainer",
            doublesRoute = "trainer/red",
            doublesMusicRole = "trainer",
          },
          preserveRoutes = { "trainer/red" },
          unknownRoute = "trainer/red",
          unknownMusicRole = "trainer",
          doublesRoute = "trainer/red",
          doublesMusicRole = "trainer",
          alternateTransitionRoute = "trainer/red",
          alternateMusicRole = "trainer",
        },
        wildRules = {},
        fallbackRoutes = {},
      },
    },
    resources = {
      ["transition/red/character"] = { path = "battle/transitions/red-character.lua" },
    },
  }
  local transition = BattleEncounterTransition.new({
    manifest = manifest,
    cacheFs = cacheFs,
    battleAssets = {
      requestBattleScene = function()
        return true
      end,
    },
    sceneKey = "general/plain/day",
    audioOperations = {
      emit = function(_, operation)
        event = operation
      end,
    },
    effectFactory = function(route, resources, launchContext)
      Assert.equal(route.role, "red-trainer-transition", "selected source route reaches its effect")
      Assert.equal(
        resources["transition/red/character"].path,
        "battle/transitions/red-character.lua",
        "route resource resolves through the manifest"
      )
      Assert.equal(
        launchContext.playerGender,
        "male",
        "the immutable semantic player gender reaches the family factory"
      )
      return {
        start = function() end,
        stepSourceTick = function()
          steps = steps + 1
          return steps == 2
        end,
        frame = function()
          return { phase = steps }
        end,
        dispose = function()
          disposed = disposed + 1
        end,
      }
    end,
  })
  return transition, function()
    return event, steps, disposed
  end
end

function T.selected_route_starts_music_at_effect_initialization_and_waits_for_native_done()
  local transition, state = fixture()
  local context = {
    kind = "trainer",
    trainerClass = "RIVAL",
    doubleBattle = false,
    specialBattle = false,
    alternateTransition = false,
    playerGender = "male",
  }
  Assert.equal(transition:prepare(context), "ready", "all selected route resources are prepared")
  Assert.equal(transition:start(), "running", "selected transition starts")
  local event, steps = state()
  Assert.equal(event.kind, "start-battle-music", "native init emits typed music operation")
  Assert.equal(event.role, "rival", "selected semantic music role is retained")
  Assert.equal(steps, 0, "effect does not advance during initialization")
  Assert.equal(transition:status().complete, false, "native task begins incomplete")
  transition:stepSourceTick()
  Assert.equal(transition:status().complete, false, "first native tick does not complete task")
  Assert.equal(transition:frame().phase, 1, "frame observes the running source task state")
  transition:stepSourceTick()
  Assert.equal(transition:status().complete, true, "native done condition completes task")
  transition:dispose()
  transition:dispose()
  local _, _, disposed = state()
  Assert.equal(disposed, 1, "completion and repeated disposal release effect once")
end

function T.selected_resource_failure_does_not_start_music_or_effect()
  local emitted = 0
  local manifest = {
    transitions = {
      routes = {
        ["trainer/red"] = { role = "red-trainer-transition", resources = { "missing" } },
      },
      selection = {
        trainerClassRoutes = { RIVAL = "trainer/red" },
        trainerClassMusicRoles = { RIVAL = "rival" },
        trainerRules = {
          specialBattle = {
            preserveRoute = "trainer/red",
            defaultRoute = "trainer/red",
            defaultMusicRole = "trainer",
            doublesRoute = "trainer/red",
            doublesMusicRole = "trainer",
          },
          preserveRoutes = { "trainer/red" },
          unknownRoute = "trainer/red",
          unknownMusicRole = "trainer",
          doublesRoute = "trainer/red",
          doublesMusicRole = "trainer",
          alternateTransitionRoute = "trainer/red",
          alternateMusicRole = "trainer",
        },
        wildRules = {},
        fallbackRoutes = {},
      },
    },
    resources = {},
  }
  local transition = BattleEncounterTransition.new({
    manifest = manifest,
    cacheFs = {
      loadLua = function()
        error("must not load an undeclared resource")
      end,
    },
    battleAssets = {
      requestBattleScene = function()
        return true
      end,
    },
    sceneKey = "general/plain/day",
    audioOperations = {
      emit = function()
        emitted = emitted + 1
      end,
    },
    effectFactory = function()
      error("must not create an effect")
    end,
  })
  local ok = pcall(function()
    transition:prepare({
      kind = "trainer",
      trainerClass = "RIVAL",
      doubleBattle = false,
      specialBattle = false,
      alternateTransition = false,
    })
  end)
  Assert.equal(ok, false, "an undeclared selected resource is a preparation failure")
  Assert.equal(emitted, 0, "preparation failure emits no music operation")
  Assert.equal(transition:status().phase, "failed", "preparation failure is observable")
  transition:dispose()
end

function T.partial_native_start_failure_disposes_the_effect_once()
  local disposed = 0
  local emitted = 0
  local transition = BattleEncounterTransition.new({
    manifest = {
      transitions = {
        routes = { ["trainer/red"] = { role = "red-trainer-transition", resources = {} } },
        selection = {
          trainerClassRoutes = { RIVAL = "trainer/red" },
          trainerClassMusicRoles = { RIVAL = "rival" },
          trainerRules = {
            specialBattle = {
              preserveRoute = "trainer/red",
              defaultRoute = "trainer/red",
              defaultMusicRole = "trainer",
              doublesRoute = "trainer/red",
              doublesMusicRole = "trainer",
            },
            preserveRoutes = { "trainer/red" },
            unknownRoute = "trainer/red",
            unknownMusicRole = "trainer",
            doublesRoute = "trainer/red",
            doublesMusicRole = "trainer",
            alternateTransitionRoute = "trainer/red",
            alternateMusicRole = "trainer",
          },
          wildRules = {},
          fallbackRoutes = {},
        },
      },
      resources = {},
    },
    cacheFs = {
      loadLua = function()
        error("route has no resources")
      end,
    },
    battleAssets = {
      requestBattleScene = function()
        return true
      end,
    },
    sceneKey = "general/plain/day",
    audioOperations = {
      emit = function()
        emitted = emitted + 1
      end,
    },
    effectFactory = function()
      return {
        start = function()
          error("injected failure after effect acquisition")
        end,
        stepSourceTick = function()
          return false
        end,
        frame = function()
          return {}
        end,
        dispose = function()
          disposed = disposed + 1
        end,
      }
    end,
  })
  transition:prepare({
    kind = "trainer",
    trainerClass = "RIVAL",
    doubleBattle = false,
    specialBattle = false,
    alternateTransition = false,
  })
  local ok = pcall(function()
    transition:start()
  end)
  Assert.equal(ok, false, "partially started effect failure is propagated")
  Assert.equal(emitted, 1, "music operation is emitted at the native start boundary")
  Assert.equal(transition:status().phase, "failed", "failed start is observable")
  transition:dispose()
  Assert.equal(disposed, 1, "partial effect acquisition is released exactly once")
end

function T.generic_trainer_source_task_renders_then_completes_after_owned_sprite_cleanup()
  local effect
  local spriteResources = {
    palette = { colors = { { r = 0, g = 0, b = 0 }, { r = 250, g = 30, b = 20 } } },
    characters = { depth = 3, tiles = string.rep(string.char(0x11), 32) },
    cells = { cells = { { objs = { { tile = 0, width = 8, height = 8, x = -4, y = -4, palette = 0 } } } } },
    animation = {
      anims = {
        {
          frames = { { cell = 0, duration = 1, translateX = 0, translateY = 0, scaleX = 1, scaleY = 1, rotation = 0 } },
        },
      },
    },
  }
  local resourceData = {
    paletteKey = spriteResources.palette,
    characterKey = spriteResources.characters,
    cellKey = spriteResources.cells,
    animationKey = spriteResources.animation,
  }
  local route = {
    role = "generic-trainer-transition",
    resources = { "paletteKey", "characterKey", "cellKey", "animationKey" },
    assetGroups = {
      sprite = { palette = "paletteKey", character = "characterKey", cell = "cellKey", animation = "animationKey" },
    },
  }
  local transition = BattleEncounterTransition.new({
    manifest = {
      transitions = {
        routes = { ["trainer/generic"] = route },
        selection = {
          trainerClassRoutes = { GENERIC = "trainer/generic" },
          trainerClassMusicRoles = { GENERIC = "trainer" },
          trainerRules = {
            specialBattle = {
              preserveRoute = "trainer/generic",
              defaultRoute = "trainer/generic",
              defaultMusicRole = "trainer",
              doublesRoute = "trainer/generic",
              doublesMusicRole = "trainer",
            },
            preserveRoutes = { "trainer/generic" },
            unknownRoute = "trainer/generic",
            unknownMusicRole = "trainer",
            doublesRoute = "trainer/generic",
            doublesMusicRole = "trainer",
            alternateTransitionRoute = "trainer/generic",
            alternateMusicRole = "trainer",
          },
          wildRules = {},
          fallbackRoutes = {},
        },
      },
      resources = {
        paletteKey = { path = "palette.lua" },
        characterKey = { path = "characters.lua" },
        cellKey = { path = "cells.lua" },
        animationKey = { path = "animation.lua" },
      },
    },
    cacheFs = {
      loadLua = function(_, path)
        local key = ({
          ["palette.lua"] = "paletteKey",
          ["characters.lua"] = "characterKey",
          ["cells.lua"] = "cellKey",
          ["animation.lua"] = "animationKey",
        })[path]
        return resourceData[key]
      end,
    },
    battleAssets = {
      requestBattleScene = function()
        return true
      end,
    },
    sceneKey = "general/plain/day",
    audioOperations = { emit = function() end },
    effectFactory = function(selectedRoute, resources)
      effect = TransitionFamilyFactory.new(selectedRoute, resources, love.graphics, {}, { playerGender = "male" })
      return effect
    end,
  })
  transition:prepare({
    kind = "trainer",
    trainerClass = "GENERIC",
    doubleBattle = false,
    specialBattle = false,
    alternateTransition = false,
  })
  transition:start()
  Assert.equal(effect:frame().sourcePhase, 0, "native callback begins at its source state zero")
  transition:stepSourceTick()
  local firstFrame = transition:frame()
  Assert.equal(firstFrame.sourcePhase, 1, "source callback creates sprites then advances to state one")
  Assert.equal(#firstFrame.sprites, 1, "trainer route renders exactly its source sprite")
  Assert.equal(firstFrame.sprites[1].visible, false, "source sprite remains hidden through HBlank setup")
  local ticks = 1
  while transition:frame().sourcePhase < 4 do
    transition:stepSourceTick()
    ticks = ticks + 1
  end
  Assert.equal(transition:frame().sprites[1].visible, true, "trainer callback shows its sprite at source state three")
  Assert.equal(transition:frame().blendAlpha, 0, "trainer callback starts its source blend at zero")
  for _ = 1, 13 do
    transition:stepSourceTick()
    ticks = ticks + 1
  end
  Assert.equal(transition:frame().sourcePhase, 5, "twelve-tick source blend enters affine setup")
  Assert.equal(transition:frame().blendAlpha, 16, "source blend reaches its native coefficient")
  transition:stepSourceTick()
  ticks = ticks + 1
  Assert.equal(transition:frame().wipe.kind, "circle", "trainer callback selects its source circle wipe")
  Assert.equal(transition:frame().wipe.step, 0, "trainer circle begins at its source radius")
  Assert.equal(transition:frame().wipe.rows[1][1][1], 0, "initial source circle covers the left edge")
  Assert.equal(transition:frame().wipe.rows[1][1][2], 255, "initial source circle covers the right edge")
  transition:stepSourceTick()
  ticks = ticks + 1
  Assert.equal(transition:frame().affineValue, 4096, "trainer affine helper begins at its 12-bit source scale")
  transition:stepSourceTick()
  ticks = ticks + 1
  Assert.equal(transition:frame().affineValue, 3995, "trainer affine helper retains source fixed-point rounding")
  transition:stepSourceTick()
  ticks = ticks + 1
  transition:stepSourceTick()
  ticks = ticks + 1
  Assert.equal(transition:frame().wipe.step, 4, "trainer circle follows four native fade steps")
  Assert.equal(transition:frame().wipe.rows[97][1][1], 43, "circle radius follows the source fixed-point step")
  Assert.equal(transition:frame().wipe.rows[97][1][2], 213, "circle span stays centered on the source field")
  Assert.equal(#transition:frame().wipe.rows[1], 0, "circle mask excludes rows beyond its source radius")
  while not transition:status().complete and ticks < 100 do
    transition:stepSourceTick()
    ticks = ticks + 1
  end
  Assert.equal(transition:status().complete, true, "native task reaches its source done state")
  Assert.equal(effect:frame().sourcePhase, 7, "completion follows callback state seven cleanup")
  Assert.equal(#effect:frame().sprites, 0, "disposed callback no longer owns sprite resources")
  Assert.equal(ticks < 100, true, "native task completes without an external timer")
end

function T.scene_receipt_stays_pending_without_loading_and_resumes_only_when_ready()
  local requested = {}
  local shouldBeReady = false
  local loads = 0
  local started = 0
  local manifest = {
    transitions = {
      routes = {
        ["trainer/red"] = {
          role = "red-trainer-transition",
          resources = { "sprite" },
        },
      },
      selection = {
        trainerClassRoutes = { RIVAL = "trainer/red" },
        trainerClassMusicRoles = { RIVAL = "rival" },
        trainerRules = {
          specialBattle = {
            preserveRoute = "trainer/red",
            defaultRoute = "trainer/red",
            defaultMusicRole = "trainer",
            doublesRoute = "trainer/red",
            doublesMusicRole = "trainer",
          },
          preserveRoutes = { "trainer/red" },
          unknownRoute = "trainer/red",
          unknownMusicRole = "trainer",
          doublesRoute = "trainer/red",
          doublesMusicRole = "trainer",
          alternateTransitionRoute = "trainer/red",
          alternateMusicRole = "trainer",
        },
        wildRules = {},
        fallbackRoutes = {},
      },
    },
    resources = { sprite = { path = "sprite.lua" } },
  }
  local transition = BattleEncounterTransition.new({
    manifest = manifest,
    cacheFs = {
      loadLua = function()
        loads = loads + 1
        return { decoded = true }
      end,
    },
    battleAssets = {
      requestBattleScene = function(sceneKey, urgency)
        requested[#requested + 1] = { sceneKey = sceneKey, urgency = urgency }
        return shouldBeReady, nil
      end,
    },
    sceneKey = "general/plain/day",
    audioOperations = { emit = function() end },
    effectFactory = function()
      return {
        start = function()
          started = started + 1
        end,
        stepSourceTick = function()
          return false
        end,
        frame = function()
          return {}
        end,
        dispose = function() end,
      }
    end,
  })
  local context = {
    kind = "trainer",
    trainerClass = "RIVAL",
    doubleBattle = false,
    specialBattle = false,
    alternateTransition = false,
  }
  Assert.equal(transition:prepare(context), "pending", "unready scene receipt keeps preparation pending")
  Assert.equal(transition:status().phase, "pending", "pending scene receipt is observable")
  Assert.equal(loads, 0, "transition payload bytes are not opened before global readiness")
  Assert.equal(started, 0, "pending scene does not construct or start its family")
  shouldBeReady = true
  Assert.equal(transition:prepare(context), "ready", "the selected scene resumes after global publication")
  Assert.equal(transition:start(), "running", "ready scene starts once")
  Assert.equal(loads, 1, "selected payload bytes load only after the ready receipt")
  Assert.equal(started, 1, "native task starts only after complete publication")
  Assert.deepEqual(requested, {
    { sceneKey = "general/plain/day", urgency = "required" },
    { sceneKey = "general/plain/day", urgency = "required" },
  }, "repeated preparation uses the idempotent launch-scoped scene demand")
  transition:dispose()
end

function T.scene_receipt_failure_is_terminal_without_loading_or_starting()
  local loads = 0
  local starts = 0
  local manifest = {
    transitions = {
      routes = { ["trainer/red"] = { role = "red-trainer-transition", resources = { "sprite" } } },
      selection = {
        trainerClassRoutes = { RIVAL = "trainer/red" },
        trainerClassMusicRoles = { RIVAL = "rival" },
        trainerRules = {
          specialBattle = {
            preserveRoute = "trainer/red",
            defaultRoute = "trainer/red",
            defaultMusicRole = "trainer",
            doublesRoute = "trainer/red",
            doublesMusicRole = "trainer",
          },
          preserveRoutes = { "trainer/red" },
          unknownRoute = "trainer/red",
          unknownMusicRole = "trainer",
          doublesRoute = "trainer/red",
          doublesMusicRole = "trainer",
          alternateTransitionRoute = "trainer/red",
          alternateMusicRole = "trainer",
        },
        wildRules = {},
        fallbackRoutes = {},
      },
    },
    resources = { sprite = { path = "sprite.lua" } },
  }
  local transition = BattleEncounterTransition.new({
    manifest = manifest,
    cacheFs = {
      loadLua = function()
        loads = loads + 1
        return {}
      end,
    },
    battleAssets = {
      requestBattleScene = function()
        return nil, "corrupt scene"
      end,
    },
    sceneKey = "general/plain/day",
    audioOperations = { emit = function() end },
    effectFactory = function()
      return {
        start = function()
          starts = starts + 1
        end,
        stepSourceTick = function()
          return false
        end,
        frame = function()
          return {}
        end,
        dispose = function() end,
      }
    end,
  })
  local ok = pcall(function()
    transition:prepare({
      kind = "trainer",
      trainerClass = "RIVAL",
      doubleBattle = false,
      specialBattle = false,
      alternateTransition = false,
    })
  end)
  Assert.isFalse(ok, "failed global publication is a terminal preparation error")
  Assert.equal(transition:status().phase, "failed", "failed scene readiness is observable")
  Assert.equal(loads, 0, "failed global publication never opens resource payloads")
  Assert.equal(starts, 0, "failed global publication never starts a native task")
  transition:dispose()
end

-- The native encounter task loads its overlay, spawns its effect, and
-- starts scene battle music synchronously at initialization, strictly
-- before the first source tick, the native done condition, and teardown.
function T.effect_init_emits_music_before_ticks_done_and_unload_exactly_once()
  local events = {}
  local manifest = {
    transitions = {
      routes = {
        ["trainer/scout"] = { role = "generic-trainer-transition", resources = { "sprite" } },
      },
      selection = {
        trainerClassRoutes = { SCOUT = "trainer/scout" },
        trainerClassMusicRoles = { SCOUT = "trainer" },
        trainerRules = {
          specialBattle = {
            preserveRoute = "trainer/scout",
            defaultRoute = "trainer/scout",
            defaultMusicRole = "trainer",
            doublesRoute = "trainer/scout",
            doublesMusicRole = "trainer",
          },
          preserveRoutes = { "trainer/scout" },
          unknownRoute = "trainer/scout",
          unknownMusicRole = "trainer",
          doublesRoute = "trainer/scout",
          doublesMusicRole = "trainer",
          alternateTransitionRoute = "trainer/scout",
          alternateMusicRole = "trainer",
        },
        wildRules = {},
        fallbackRoutes = {},
      },
    },
    resources = { sprite = { path = "sprite.lua" } },
  }
  local transition = BattleEncounterTransition.new({
    manifest = manifest,
    cacheFs = {
      loadLua = function(_, path)
        events[#events + 1] = "resource:" .. tostring(path)
        return { decoded = true }
      end,
    },
    battleAssets = {
      requestBattleScene = function(_, _, _)
        events[#events + 1] = "scene-demand"
        return true
      end,
    },
    sceneKey = "general/plain/day",
    audioOperations = {
      emit = function(_, operation)
        events[#events + 1] = operation.kind .. ":" .. tostring(operation.role)
      end,
    },
    effectFactory = function(_, _)
      events[#events + 1] = "effect-spawn"
      local ticks = 0
      return {
        start = function()
          events[#events + 1] = "effect-start"
        end,
        stepSourceTick = function()
          ticks = ticks + 1
          events[#events + 1] = "tick:" .. tostring(ticks)
          return ticks == 2
        end,
        frame = function()
          return {}
        end,
        dispose = function()
          events[#events + 1] = "effect-unload"
        end,
      }
    end,
  })
  local context = {
    kind = "trainer",
    trainerClass = "SCOUT",
    doubleBattle = false,
    specialBattle = false,
    alternateTransition = false,
  }
  Assert.equal(transition:prepare(context), "ready", "overlay load completes preparation")
  Assert.equal(transition:start(), "running", "spawned effect starts")
  local musicAt = nil
  local firstTickAt = nil
  for index, event in ipairs(events) do
    if event == "start-battle-music:trainer" and musicAt == nil then
      musicAt = index
    end
    if tostring(event):match("^tick:") ~= nil and firstTickAt == nil then
      firstTickAt = index
    end
  end
  Assert.notNil(musicAt, "battle music starts synchronously at effect initialization")
  Assert.isNil(firstTickAt, "no source tick runs before music starts")
  transition:stepSourceTick()
  transition:stepSourceTick()
  Assert.equal(transition:status().phase, "complete", "native done completes the task")
  transition:dispose()
  local musicCount = 0
  local unloadAt = nil
  local doneAt = nil
  for index, event in ipairs(events) do
    if event == "start-battle-music:trainer" then
      musicCount = musicCount + 1
    end
    if event == "tick:2" then
      doneAt = index
    end
    if event == "effect-unload" then
      unloadAt = index
    end
  end
  Assert.equal(musicCount, 1, "battle music starts exactly once per launch")
  Assert.isTrue(unloadAt ~= nil and doneAt ~= nil and unloadAt > doneAt, "unload follows the native done")
  Assert.deepEqual(events, {
    "scene-demand",
    "resource:sprite.lua",
    "effect-spawn",
    "start-battle-music:trainer",
    "effect-start",
    "tick:1",
    "tick:2",
    "effect-unload",
  }, "init, music, ticks, done, and unload keep the source order")
  transition:dispose()
end

return { tests = T }
