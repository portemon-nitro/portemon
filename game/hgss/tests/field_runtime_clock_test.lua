-- FieldRuntime adapts the injectable local civil clock independently for
-- weather dates and map-music day/night policy.

local Assert = require("tests.support.Assert")
local FieldAudio = require("game.hgss.src.audio.FieldAudio")
local FieldRuntime = require("game.hgss.src.field.FieldRuntime")
local FieldSession = require("libs.hgss.src.field.FieldSession")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local LocalClock = require("game.src.LocalClock")

local T = { tests = {} }

function T.tests.weather_and_map_music_use_the_injected_local_clock()
  local originalLoad = FieldRuntime._load
  local originalCompose = FieldAudio.compose
  local originalDate = os.date
  local calls = 0
  local composition
  local clock = LocalClock.new(function()
    calls = calls + 1
    return { year = 2024, month = 2, day = 29, hour = 12, minute = 34, second = 56 }
  end)

  FieldRuntime._load = function() end
  FieldAudio.compose = function(options)
    composition = options
    return {
      service = { enterMap = function() end },
      sink = nil,
    }
  end
  os.date = function()
    error("FieldRuntime must not read os.date directly")
  end

  local ok, err = xpcall(function()
    local runtime = FieldRuntime.new({
      saveId = "test-save",
      versionId = "heartgold",
      location = { mapSymbol = "MAP_NEW_BARK_ELMS_LAB_1F", fieldX = 6, fieldZ = 6, facing = "south" },
      playerData = {
        profile = { name = "GOLD", gender = 0, trainerId = 1, money = 3000, badges = 0 },
        options = { textSpeed = "mid", textFrame = 0 },
      },
      fieldTravel = { lastHealSpawn = "SPAWN_NEW_BARK" },
      worldState = {
        serialize = function()
          return {}
        end,
      },
    }, { localClock = clock })
    Assert.deepEqual(runtime.weatherClock:today(), { month = 2, day = 29 })
    runtime:_composeAudio({
      loadLua = function()
        return {}
      end,
    }, nil)
    Assert.equal(composition.dayNight(), "day")
    Assert.equal(calls, 2, "weather and map music each sample the shared clock boundary")
  end, debug.traceback)

  FieldRuntime._load = originalLoad
  FieldAudio.compose = originalCompose
  os.date = originalDate
  if not ok then
    error(err, 0)
  end
end

function T.tests.apricorn_day_is_sampled_before_each_fixed_tick_and_only_advance_clears_kurt_flag()
  local originalLoad = FieldRuntime._load
  local day = { year = 2028, month = 2, day = 28, hour = 23, minute = 59, second = 59 }
  local clockCalls = 0
  local dates = {}
  local advanced = false
  local clock = LocalClock.new(function()
    clockCalls = clockCalls + 1
    return day
  end)
  local eventState = FieldEventState.new()
  local kurtFlag = FieldScriptSymbols.flagsByName.FLAG_DAILY_KURT_MAKING_BALLS
  local unrelatedDailyFlag = FieldScriptSymbols.flagsByName.FLAG_DAILY_BUENAS_PASSWORD
  eventState:setFlag(kurtFlag)
  eventState:setFlag(unrelatedDailyFlag)

  FieldRuntime._load = function() end
  local ok, err = xpcall(function()
    local runtime = FieldRuntime.new({ versionId = "heartgold", saveId = "test-save" }, { localClock = clock })
    runtime.eventState = eventState
    runtime.martService = {
      processApricornDate = function(_, date)
        dates[#dates + 1] = date
        return { dayOrdinal = #dates, advanced = advanced }
      end,
    }
    runtime.session = {
      accumulator = 0,
      updateFixed = function()
        Assert.equal(#dates, clockCalls, "daily state is refreshed before scripts run")
        if advanced then
          Assert.isFalse(eventState:isFlagSet(kurtFlag), "a forward civil day ends Kurt's making period before scripts")
        else
          Assert.isTrue(eventState:isFlagSet(kurtFlag), "same-day ticks keep Kurt's making period active")
        end
      end,
    }
    runtime._reconcileBattleGate = function() end
    runtime._consumeCommittedStep = function() end
    runtime._refreshFieldTimeOfDay = function() end
    runtime.applicationHost = { error = function() end }
    runtime.transition = {
      error = false,
      updateSourceFrame = function() end,
      consumeCompleted = function() end,
    }
    runtime.screenFade = { updateSourceFrame = function() end }

    runtime:update(FieldSession.FIXED_DT)
    Assert.equal(#dates, 1)
    Assert.deepEqual(dates[1], { year = 2028, month = 2, day = 28 })
    Assert.isTrue(eventState:isFlagSet(unrelatedDailyFlag), "unrelated daily flags are retained")

    day = { year = 2028, month = 2, day = 29, hour = 0, minute = 0, second = 0 }
    advanced = true
    runtime:update(FieldSession.FIXED_DT)
    Assert.equal(#dates, 2)
    Assert.deepEqual(dates[2], { year = 2028, month = 2, day = 29 })
    Assert.isFalse(eventState:isFlagSet(kurtFlag))
    Assert.isTrue(eventState:isFlagSet(unrelatedDailyFlag))
  end, debug.traceback)

  FieldRuntime._load = originalLoad
  if not ok then
    error(err, 0)
  end
end

return T
