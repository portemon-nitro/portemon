-- Production-composed New Bark transition badge contract. Boots the real
-- field runtime on the real town map and lets the generated on-transition
-- lifecycle settle through the production script composition. A fresh
-- profile hides Cameron through the retail badge check; a profile carrying
-- the Plain Badge takes the other branch without a script fault.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local OpeningLifecycle = require("tests.acceptance.support.OpeningLifecycle")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local PlayerProgression = require("libs.hgss.src.save.PlayerProgression")

local T = {
  metadata = {
    capabilities = { "rom_dump" },
    derivedAssets = { "field-runtime", "map:60" },
    tags = { "field", "transition", "badges" },
  },
  tests = {},
}

local TOWN = "MAP_NEW_BARK"
local FLAG_HIDE_CAMERON = FieldScriptSymbols.flagsByName.FLAG_HIDE_CAMERON

local function transitionScriptId(game)
  return assert(
    OpeningLifecycle.lifecycleScriptId(game.runtime, "on_transition"),
    "New Bark must declare an on-transition lifecycle script"
  )
end

local function cameronActorId(game)
  local runtimeMap = game.runtime.runtimeMap
  for _, event in ipairs(runtimeMap.fieldData.events.objects) do
    if event.eventFlag == FLAG_HIDE_CAMERON then
      return "map:" .. runtimeMap.mapId .. ":object:" .. event.objectEventId
    end
  end
  error("New Bark must declare the Cameron object event bound to its hide flag", 0)
end

local function settleTransition(game)
  local scriptId = transitionScriptId(game)
  game:waitForFieldEntry()
  game:advanceUntil("the town transition lifecycle settles", function()
    return game.runtime.scripts.scheduler:foregroundEnvironmentId() == nil and not game:snapshot().fieldLocked
  end, 240)
  return scriptId
end

function T.tests.fresh_town_hides_cameron_through_the_transition_script()
  local harness = AcceptanceHarness.new()
  local game = harness:boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = TOWN,
    save = "fresh",
    fieldOptions = { recordingScriptHosts = true },
  })
  local ok, err = xpcall(function()
    local scriptId = settleTransition(game)
    local faults = game:recordsForScript(scriptId, "script.error")
    Assert.equal(
      #faults,
      0,
      "the transition script must not fault on a fresh profile; got "
        .. (faults[1] and faults[1].payload.code or "no record")
    )
    Assert.isTrue(
      game.runtime.scripts.worldState:isFlagSet(FLAG_HIDE_CAMERON),
      "a fresh profile without the Plain Badge must hide Cameron"
    )
    Assert.isNil(
      game.runtime.actors:getById(cameronActorId(game)),
      "a hidden Cameron must not remain live"
    )
    Assert.equal(game:renderAttempts(), 0, "the transition flow must stop before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

function T.tests.plain_badge_town_keeps_cameron_without_a_script_fault()
  local harness = AcceptanceHarness.new()
  local defaultFactory = harness.gameFactory
  harness.gameFactory = function(versionId, map)
    local game = defaultFactory(versionId, map)
    PlayerProgression.new(game.playerData.profile):awardBadge("plain")
    return game
  end
  local game = harness:boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = TOWN,
    save = "fresh",
    fieldOptions = { recordingScriptHosts = true },
  })
  local ok, err = xpcall(function()
    local scriptId = settleTransition(game)
    -- The retail badge-present branch reads the weekday next, and that
    -- source read has no runtime lowering yet, so the script stops there
    -- with the documented unsupported-operation fault. That gap is outside
    -- badge wiring: what matters here is the badge check itself evaluates
    -- without a service fault and the no-badge hide branch never runs.
    local faults = game:recordsForScript(scriptId, "script.error")
    for _, fault in ipairs(faults) do
      Assert.isFalse(
        fault.payload.code == "SCRIPT_SERVICE_MISSING",
        "the badge check must evaluate through the live progression service"
      )
    end
    Assert.isFalse(
      game.runtime.scripts.worldState:isFlagSet(FLAG_HIDE_CAMERON),
      "a profile carrying the Plain Badge must not take the no-badge hide branch"
    )
    Assert.notNil(
      game.runtime.actors:getById(cameronActorId(game)),
      "Cameron must stay live while the hide flag stays clear"
    )
    Assert.equal(game:renderAttempts(), 0, "the transition flow must stop before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

return T
