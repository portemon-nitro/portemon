-- Production-composed Cherrygrove guide-gent scene: walking into the scene-0
-- coordinate trigger runs the real generated tour script to completion. The
-- Running Shoes gift persists in the player profile, the gent leaves the
-- town, and the scene variable advances, all without a script fault.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local LocalClock = require("game.src.LocalClock")
local PlayerProgression = require("libs.hgss.src.save.PlayerProgression")

local T = {
  metadata = {
    capabilities = { "rom_dump" },
    derivedAssets = { "field-runtime", "map:67" },
    tags = { "field", "script", "cherrygrove", "running-shoes" },
  },
  tests = {},
}

local MAP = "MAP_CHERRYGROVE"
local SCRIPT_ID = "vanilla.hgss.scr_seq.0850.script_001"
local VAR_SCENE = FieldScriptSymbols.variablesByName.VAR_SCENE_CHERRYGROVE_CITY_OW
local FLAG_HIDE_CAMERON = FieldScriptSymbols.flagsByName.FLAG_HIDE_CAMERON
local FLAG_HIDE_GUIDE = FieldScriptSymbols.flagsByName.FLAG_HIDE_CHERRYGROVE_GUIDE_GENT

-- The scene-0 trigger column is global x=566, z=397..400; locations are
-- relative to the map's first 32-cell chunk (16,12), so local (53,14) is the
-- trigger column's western neighbor.
local function boot()
  local harness = AcceptanceHarness.new()
  local defaultFactory = harness.gameFactory
  harness.gameFactory = function(versionId, map)
    local game = defaultFactory(versionId, map)
    game.location = { mapSymbol = map or MAP, fieldX = 53, fieldZ = 14, facing = "east" }
    return game
  end
  return harness:boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = MAP,
    save = "fresh",
    fieldOptions = { recordingScriptHosts = true },
  })
end

-- Holds a direction (and B when asked) until the player commits one tile and
-- returns the fixed ticks that took, then releases and settles.
local function ticksPerTile(game, direction, holdB)
  local before = game:snapshot().player
  game:face(direction)
  game.runtime:press(direction)
  if holdB then
    game.runtime:pressCancel()
  end
  local ticks = 0
  repeat
    game:step()
    ticks = ticks + 1
    local now = game:snapshot().player
    assert(ticks <= 20, "the player never committed a tile")
  until now.fieldX ~= before.fieldX or now.fieldZ ~= before.fieldZ
  game.runtime:release(direction)
  if holdB then
    game.runtime:releaseCancel()
  end
  game:advanceUntil("the step settles", function(snapshot)
    return snapshot.player.motion == "idle"
  end, 20)
  return ticks
end

local function walkableDirection(game)
  for _, direction in ipairs({ "south", "north", "west", "east" }) do
    if game.runtime.player:resolveStep(direction) ~= nil then
      return direction
    end
  end
  error("no walkable direction from the player's tile", 0)
end

function T.tests.guide_gent_tour_gives_running_shoes_and_completes()
  local game = boot()
  local ok, err = xpcall(function()
    -- The tour releases the follower, which exists only with a lead mon.
    game:waitForFieldEntry()
    assert(game.runtime.monService:giveMon({ species = "CHIKORITA", level = 5, form = 0 }), "setup gift must join")
    game:advanceUntil("the partner actor installs", function()
      return game.runtime.actors:partnerId() ~= nil
    end, 120)

    local profile = game.runtime.playerData.profile
    local world = assert(game.runtime.scripts.worldState, "the production script world state is required")
    Assert.equal(profile.runningShoes, false, "a fresh profile starts without the Running Shoes")
    Assert.equal(world:getVar(VAR_SCENE), 0, "the town scene starts before the guide tour")

    Assert.equal(ticksPerTile(game, "west", true), 8, "holding B without the shoes still walks")
    game:moveTo({ fieldX = 566, fieldZ = 398 })
    game:advanceUntil("the guide tour script starts", function()
      return #game:recordsForScript(SCRIPT_ID, "script.started") == 1
    end, 120)
    -- The script holds the field locked throughout, so confirm edges go to
    -- each open message instead of waiting for the lock to clear.
    game:advanceUntil("the guide tour completes", function(snapshot)
      if snapshot.dialogue.modal then
        game.runtime:pressAction()
        game:step()
        game.runtime:releaseAction()
      end
      return world:getVar(VAR_SCENE) == 1 and not snapshot.fieldLocked
    end, 4000)

    Assert.equal(#game:recordsNamed("script.error"), 0, "the guide tour must not fault")
    Assert.isTrue(profile.runningShoes, "the tour persists the Running Shoes in the player profile")
    Assert.isTrue(world:isFlagSet(FLAG_HIDE_GUIDE), "the guide gent leaves the town")
    local direction = walkableDirection(game)
    Assert.equal(ticksPerTile(game, direction, false), 8, "without B the shoes owner still walks")
    Assert.equal(ticksPerTile(game, walkableDirection(game), true), 4, "holding B with the shoes runs")
    Assert.equal(game:renderAttempts(), 0, "the scene must stop before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

-- Entering the town with the Plain Badge runs the map-init script, which
-- reads the weekday: Cameron appears on Monday, Wednesday and Friday.
local function plainBadgeTown(day)
  local harness = AcceptanceHarness.new()
  local defaultFactory = harness.gameFactory
  harness.gameFactory = function(versionId, map)
    local game = defaultFactory(versionId, map)
    PlayerProgression.new(game.playerData.profile):awardBadge("plain")
    return game
  end
  local clock = LocalClock.new(function()
    return { year = 2024, month = 2, day = day, hour = 12, minute = 0, second = 0 }
  end)
  local game = harness:boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = MAP,
    save = "fresh",
    fieldOptions = { recordingScriptHosts = true, localClock = clock },
  })
  local ok, result = xpcall(function()
    game:waitForFieldEntry()
    game:advanceUntil("the town lifecycle settles", function(snapshot)
      return game.runtime.scripts.scheduler:foregroundEnvironmentId() == nil and not snapshot.fieldLocked
    end, 240)
    Assert.equal(#game:recordsNamed("script.error"), 0, "the weekday branch must not fault")
    return game.runtime.scripts.worldState:isFlagSet(FLAG_HIDE_CAMERON)
  end, debug.traceback)
  game:close()
  if not ok then
    error(result, 0)
  end
  return result
end

function T.tests.plain_badge_town_shows_cameron_on_monday_wednesday_friday()
  -- 2024-02-26 is a Monday, the 27th a Tuesday, the 28th a Wednesday.
  Assert.isFalse(plainBadgeTown(26), "Cameron appears on Mondays")
  Assert.isTrue(plainBadgeTown(27), "Cameron is hidden on Tuesdays")
  Assert.isFalse(plainBadgeTown(28), "Cameron appears on Wednesdays")
end

return T
