-- FieldRuntime advances the active map's field lighting/time-of-day
-- continuously from the injected local clock, independently from the
-- event-driven weather clock (see field_runtime_weather_application_test).

local Assert = require("tests.support.Assert")
local FieldRuntime = require("game.hgss.src.field.FieldRuntime")

local T = { tests = {} }

local function clockAt(hour, minute, second)
  return {
    nowLocal = function()
      return { year = 2000, month = 1, day = 1, hour = hour, minute = minute, second = second or 0 }
    end,
  }
end

local function runtimeWithEnvironment(clock, environment, sceneRuntime)
  return setmetatable({
    localClock = clock,
    runtimeMap = { renderEnvironment = environment, sceneRuntime = sceneRuntime },
    session = { accumulator = 0, updateFixed = function() end },
    transition = {
      error = nil,
      consumeCompleted = function()
        return false
      end,
      updateSourceFrame = function() end,
    },
    screenFade = { updateSourceFrame = function() end },
    applicationHost = {
      error = function()
        return nil
      end,
    },
  }, FieldRuntime)
end

function T.tests.update_advances_field_time_seconds_from_the_injected_clock()
  local environment = { lighting = { records = {} }, fieldTimeSeconds = 0 }
  local runtime = runtimeWithEnvironment(clockAt(14, 30, 15), environment)
  runtime:update(1 / 30)
  Assert.equal(environment.fieldTimeSeconds, 14 * 3600 + 30 * 60 + 15)
end

function T.tests.update_swaps_the_scene_time_band_to_match_the_clock()
  local bands = {}
  local environment = { lighting = { records = {} }, fieldTimeSeconds = 0 }
  local sceneRuntime = {
    timeBand = "day",
    setTimeBand = function(_, band)
      bands[#bands + 1] = band
    end,
  }
  local runtime = runtimeWithEnvironment(clockAt(22, 0, 0), environment, sceneRuntime)
  runtime:update(1 / 30)
  Assert.deepEqual(bands, { "nite" })
end

function T.tests.update_leaves_an_environment_without_live_time_state_untouched()
  local environment = { lighting = { records = {} } } -- no fieldTimeSeconds: not a live time-of-day environment
  local runtime = runtimeWithEnvironment(clockAt(8, 0, 0), environment)
  runtime:update(1 / 30)
  Assert.isNil(environment.fieldTimeSeconds)
end

return { tests = T.tests, metadata = { tags = { "field", "lighting" } } }
