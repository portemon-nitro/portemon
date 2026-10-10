-- Production-composed proof that outdoor field lighting tracks the host
-- local clock continuously, the user-visible day/night lighting boundary
-- that FieldLightProfile/FieldRenderer alone cannot prove end to end.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local FieldLightProfile = require("libs.assets.src.field.FieldLightProfile")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local LocalClock = require("game.src.LocalClock")

local T = {
  metadata = {
    capabilities = { "rom_dump" },
    derivedAssets = { "field-runtime", "map-data:60", "map:60", "map-data:33" },
    tags = { "field", "lighting", "time-of-day", "acceptance" },
  },
  tests = {},
}

local TOWN = "MAP_NEW_BARK"

local function withGame(time, fn)
  local clock = LocalClock.new(function()
    return { year = 2000, month = 1, day = 1, hour = time.hour, minute = time.minute, second = time.second }
  end)
  local game = AcceptanceHarness.new():boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = TOWN,
    save = "fresh",
    fieldOptions = { localClock = clock },
  })
  local ok, err = xpcall(function()
    fn(game)
    Assert.equal(game:renderAttempts(), 0, "field time-of-day acceptance must stop before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

function T.tests.outdoor_field_lighting_advances_continuously_from_the_host_clock()
  local time = { hour = 22, minute = 0, second = 0 }
  withGame(time, function(game)
    game:waitForFieldEntry()
    local environment = game.runtime.runtimeMap.renderEnvironment
    Assert.notNil(environment.lighting, "New Bark Town must carry a field lighting profile")
    Assert.equal(
      environment.fieldTimeSeconds,
      22 * 3600,
      "field time-of-day starts from the injected host clock, not a fixed default"
    )
    local nightRecord = FieldLightProfile.select(environment.lighting, environment.fieldTimeSeconds)

    -- The host clock advances mid-session, exactly as it does when real wall
    -- time passes during play; the next runtime update must resample it.
    time.hour = 7
    game:step()

    Assert.equal(
      environment.fieldTimeSeconds,
      7 * 3600,
      "field time-of-day tracks the live host clock on every runtime update"
    )
    local morningRecord = FieldLightProfile.select(environment.lighting, environment.fieldTimeSeconds)
    Assert.isTrue(
      nightRecord ~= morningRecord,
      "night and morning must select different lighting records for New Bark Town"
    )
  end)
end

-- A seamless zone change activates the neighbor's render environment inside
-- a fixed tick; the frame that draws it must already carry the host time.
function T.tests.zone_change_frame_carries_the_host_time()
  local time = { hour = 22, minute = 0, second = 0 }
  withGame(time, function(game)
    game:waitForFieldEntry()
    local townMapId = game.runtime.runtimeMap.mapId
    -- Disarm the west-exit scene trigger so the walk is uninterrupted.
    game:setWorldState({ variable = FieldScriptSymbols.variablesByName.VAR_SCENE_NEW_BARK_WEST_EXIT, value = 1 })
    game:moveTo({ fieldX = 676, fieldZ = 399 })
    local crossed = false
    for _ = 1, 24 do
      game:_moveOne("west")
      local runtimeMap = game.runtime.runtimeMap
      Assert.equal(
        runtimeMap.renderEnvironment.fieldTimeSeconds,
        22 * 3600,
        "the active map's lighting time matches the host clock after every step"
      )
      crossed = crossed or runtimeMap.mapId ~= townMapId
    end
    Assert.isTrue(crossed, "the walk crosses into the neighboring zone")
  end)
end

return T
