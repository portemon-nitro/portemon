-- FieldRuntime adapts the injectable local civil clock independently for
-- weather dates and map-music day/night policy.

local Assert = require("tests.support.Assert")
local FieldAudio = require("game.hgss.src.audio.FieldAudio")
local FieldRuntime = require("game.hgss.src.field.FieldRuntime")
local FieldSession = require("libs.hgss.src.field.FieldSession")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldRuntimeFixture = require("tests.support.FieldRuntimeFixture")
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
        profile = { name = "GOLD", gender = 0, trainerId = 1, money = 3000, badges = {} },
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

-- The field's Apricorn date pass belongs to the ordered daily dispatcher, not
-- to the fixed tick: one field update takes exactly one clock sample, hands the
-- same sample to the calendar observation and to the day handlers, and only a
-- forward day regrows (clearing Kurt's daily period with the whole source daily
-- block). A multi-tick update still takes one observation.
function T.tests.one_daily_observation_samples_the_apricorn_day_and_clears_forward_days()
  local originalLoad = FieldRuntime._load
  local day = { year = 2028, month = 2, day = 28, hour = 23, minute = 59, second = 59 }
  local clockCalls = 0
  local dates = {}
  local observed = {}
  local dayAdvance = 0
  local advanced = false
  local clock = LocalClock.new(function()
    clockCalls = clockCalls + 1
    return day
  end)
  local eventState = FieldEventState.new()
  local kurtFlag = assert(FieldScriptSymbols.flagsByName.FLAG_DAILY_KURT_MAKING_BALLS)
  local buenasFlag = assert(FieldScriptSymbols.flagsByName.FLAG_DAILY_BUENAS_PASSWORD)
  eventState:setFlag(kurtFlag)
  eventState:setFlag(buenasFlag)
  local mart = {
    processApricornDate = function(_, date)
      dates[#dates + 1] = date
      return { dayOrdinal = #dates, advanced = advanced }
    end,
    processDate = function()
      return { weekday = 0, dayOrdinal = 1 }
    end,
  }

  FieldRuntime._load = function() end
  local ok, err = xpcall(function()
    local runtime = FieldRuntime.new({ versionId = "heartgold", saveId = "test-save" }, { localClock = clock })
    FieldRuntimeFixture.withApricornDateOwner(runtime)
    runtime.eventState = eventState
    runtime.martService = mart
    runtime.battleCoordinator = {
      shouldPumpFromHost = function()
        return false
      end,
      prefetchEncounterScene = function() end,
    }
    runtime.session = {
      accumulator = 0,
      isBattleActive = function()
        return false
      end,
      mapEntryController = {
        isActive = function()
          return false
        end,
      },
      dialogue = {
        isModal = function()
          return false
        end,
      },
      applicationHost = {
        isActive = function()
          return false
        end,
      },
      updateFixed = function() end,
    }
    runtime.incomingCalls = {
      onFieldClock = function(_, sample)
        observed[#observed + 1] = sample
        return { dayAdvance = dayAdvance, minuteAdvance = 0, backward = false }
      end,
    }
    local FieldDailyEvents = require("game.hgss/src/field/FieldDailyEvents")
    runtime.dailyEvents = FieldDailyEvents.new({
      world = eventState,
      state = {
        readDailyIdentity = function()
          return { dailyGroupSeed = 1, outbreakSeed = 1, daySerial = 1 }
        end,
      },
      mons = {
        partyCount = function()
          return 0
        end,
        partyMon = function()
          return nil
        end,
        partyRevision = function()
          return 0
        end,
        preparePartyChanges = function()
          error("an empty party stages no change", 0)
        end,
      },
      mart = mart,
      calls = {
        advanceDays = function() end,
      },
      random = {
        lc = function()
          return 0
        end,
      },
      regrowApricorns = function(date)
        return runtime:_processApricornDate(date)
      end,
    })
    runtime._reconcileBattleGate = function() end
    runtime._consumeCommittedStep = function() end
    runtime._settleEggHatchClaim = function() end
    runtime._refreshFieldTimeOfDay = function() end
    runtime._refreshPrediction = function() end
    runtime.applicationHost = { error = function() end, isActive = function() end }
    runtime.transition = {
      error = false,
      updateSourceFrame = function() end,
      consumeCompleted = function() end,
    }
    runtime.screenFade = { updateSourceFrame = function() end }
    runtime.scentTint = { updateSourceFrame = function() end }
    runtime.fishingHost = { updateFixed = function() end, notice = function() end }

    runtime:update(FieldSession.FIXED_DT)
    Assert.equal(clockCalls, 1, "one field update takes exactly one civil sample")
    Assert.deepEqual(observed[1], day, "the observation reads the one sampled civil record")
    Assert.equal(#dates, 0, "a same-day observation regrows no tree")
    Assert.isTrue(eventState:isFlagSet(kurtFlag), "a same-day observation keeps Kurt's making period")
    Assert.isTrue(eventState:isFlagSet(buenasFlag), "a same-day observation keeps the daily block")

    day = { year = 2028, month = 2, day = 29, hour = 0, minute = 0, second = 0 }
    dayAdvance = 1
    advanced = true
    runtime.session.accumulator = FieldSession.FIXED_DT * 3
    runtime:update(0)
    Assert.equal(clockCalls, 2, "a multi-tick update still takes one civil sample")
    Assert.deepEqual(observed[2], day, "the day handlers read the same sampled civil record")
    Assert.equal(#dates, 1, "one forward day regrows the saved trees exactly once")
    Assert.deepEqual(dates[1], day, "the Apricorn pass reads the observed sample")
    Assert.isFalse(eventState:isFlagSet(kurtFlag), "a forward day ends Kurt's making period")
    Assert.isFalse(eventState:isFlagSet(buenasFlag), "a forward day clears the whole source daily block")
  end, debug.traceback)

  FieldRuntime._load = originalLoad
  if not ok then
    error(err, 0)
  end
end

return T
