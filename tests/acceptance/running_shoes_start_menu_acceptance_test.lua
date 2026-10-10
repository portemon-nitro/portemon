-- Production-composed Running Shoes toggle on the Start Menu. The retail
-- touch button appears only once the shoes are owned; a fresh touch inside
-- its generated rectangle flips the persisted auto-run lock, and while the
-- lock holds B for the player every ordinary step runs without any held
-- button. Without the shoes the menu presents no toggle and the same touch
-- changes nothing.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local FieldApplicationHost = require("libs.hgss.src.field.FieldApplicationHost")
local ScreenTopology = require("libs.ui.src.ScreenTopology")

local T = {
  metadata = {
    capabilities = { "rom_dump" },
    derivedAssets = { "field-runtime", "map:7" },
    tags = { "field", "menu", "start-menu", "running-shoes" },
  },
  tests = {},
}

local function withGame(hasShoes, fn)
  local harness = AcceptanceHarness.new()
  local defaultFactory = harness.gameFactory
  harness.gameFactory = function(versionId, map)
    local game = defaultFactory(versionId, map)
    game.playerData.profile.runningShoes = hasShoes
    return game
  end
  local game = harness:boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = "MAP_BURNED_TOWER_1F",
    save = "fresh",
    fieldOptions = {
      screenTopology = ScreenTopology.oneDisplay({
        id = "main",
        rect = { x = 0, y = 0, width = 256, height = 192 },
        role = "world",
        touch = false,
      }),
      viewportWidth = 256,
      viewportHeight = 192,
    },
  })
  local ok, err = xpcall(function()
    game:waitForFieldEntry()
    fn(game)
    Assert.equal(game:renderAttempts(), 0, "Running Shoes acceptance must stop before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

local function menuStatus(game)
  local status = game.runtime.applicationHost:status()
  Assert.equal(status.phase, FieldApplicationHost.PHASES.menu, "the Start Menu must own the field tick")
  return assert(status.menu)
end

local function toggleMenu(game, phase)
  game.runtime:pressMenu()
  game:step()
  game.runtime:releaseMenu()
  game:advanceUntil("the Start Menu " .. phase, function()
    return (game.runtime.applicationHost:status().phase == FieldApplicationHost.PHASES.menu) == (phase == "opens")
  end, 30)
end

local function tapShoes(game)
  local rect = game.runtime.uiManifest.startMenu.runningShoes.hitRect
  local x, y = rect.x + rect.width / 2, rect.y + rect.height / 2
  game.runtime.input:pointerDown("acceptance:running-shoes", x, y)
  game:step()
  game.runtime.input:pointerUp("acceptance:running-shoes", x, y)
  game:step()
end

-- Ticks one unheld ordinary step takes, in the first walkable direction.
local function ticksPerTile(game)
  local direction
  for _, candidate in ipairs({ "south", "north", "west", "east" }) do
    if game.runtime.player:resolveStep(candidate) ~= nil then
      direction = candidate
      break
    end
  end
  assert(direction, "no walkable direction from the player's tile")
  local before = game:snapshot().player
  game:face(direction)
  game.runtime:press(direction)
  local ticks = 0
  repeat
    game:step()
    ticks = ticks + 1
    local now = game:snapshot().player
    assert(ticks <= 20, "the player never committed a tile")
  until now.fieldX ~= before.fieldX or now.fieldZ ~= before.fieldZ
  game.runtime:release(direction)
  game:advanceUntil("the step settles", function(snapshot)
    return snapshot.player.motion == "idle"
  end, 20)
  return ticks
end

function T.tests.start_menu_toggle_flips_the_persisted_lock_that_runs_without_b()
  withGame(true, function(game)
    local profile = game.runtime.playerData.profile
    Assert.equal(ticksPerTile(game), 8, "without B or the lock the player walks")

    toggleMenu(game, "opens")
    Assert.deepEqual(
      menuStatus(game).runningShoes,
      { locked = false },
      "the owned shoes present their toggle, unlocked"
    )
    tapShoes(game)
    Assert.deepEqual(menuStatus(game).runningShoes, { locked = true }, "a fresh touch locks auto-run")
    Assert.isTrue(profile.runningShoesLock, "the lock lives in the saved profile")
    toggleMenu(game, "closes")
    Assert.isTrue(
      assert(game.runtime:captureGameSave()).playerData.profile.runningShoesLock,
      "a save captures the lock"
    )
    Assert.equal(ticksPerTile(game), 4, "the lock runs without holding B")

    toggleMenu(game, "opens")
    tapShoes(game)
    Assert.deepEqual(menuStatus(game).runningShoes, { locked = false }, "a second touch unlocks")
    toggleMenu(game, "closes")
    Assert.equal(ticksPerTile(game), 8, "the unlocked player walks again")
  end)
end

function T.tests.start_menu_without_the_shoes_presents_no_toggle()
  withGame(false, function(game)
    toggleMenu(game, "opens")
    Assert.isNil(menuStatus(game).runningShoes, "no shoes, no toggle")
    tapShoes(game)
    Assert.isFalse(
      game.runtime.playerData.profile.runningShoesLock,
      "the touch region does not exist without the shoes"
    )
  end)
end

return T
