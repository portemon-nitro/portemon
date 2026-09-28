-- Production-composed Start Menu contracts. The real field runtime owns the
-- menu policy, controller, placement, generated manifest, and input mapping;
-- acceptance only supplies host boundaries and semantic input.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local FieldApplicationHost = require("libs.hgss.src.field.FieldApplicationHost")
local ScreenTopology = require("libs.hgss.src.ui.ScreenTopology")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_cache" },
    tags = { "field", "menu", "start-menu", "topology", "integer-scale" },
  },
  tests = {},
}

local function topology(width, height)
  return ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = width, height = height },
    role = "world",
    touch = false,
  })
end

local function menuStatus(game)
  local status = game.runtime.applicationHost:status()
  Assert.equal(status.phase, FieldApplicationHost.PHASES.menu, "the Start Menu must own the field tick")
  return assert(status.menu, "the open Start Menu must expose its controller status")
end

local function openMenu(game)
  game.runtime:pressMenu()
  game:step()
  game.runtime:releaseMenu()
  game:advanceUntil("Start Menu opens", function()
    return game.runtime.applicationHost:status().phase == FieldApplicationHost.PHASES.menu
  end, 30)
  return menuStatus(game)
end

local function navigate(game, direction)
  local source = "acceptance:start-menu:" .. direction
  game.runtime.input:pressDirection(direction, source)
  game:step()
  game.runtime.input:releaseDirection(source)
  return menuStatus(game)
end

local function withEveryVersion(fn)
  local harness = AcceptanceHarness.new()
  harness:forEachVersion(function(versionId)
    fn(harness, versionId)
  end)
end

local function withGame(harness, versionId, options, fn)
  local game = harness:boot({
    versionId = versionId,
    map = "MAP_BURNED_TOWER_1F",
    save = "fresh",
    fieldOptions = {
      viewportWidth = options.width,
      viewportHeight = options.height,
      screenTopology = options.topology,
    },
  })
  local ok, err = xpcall(function()
    game:waitForFieldEntry()
    fn(game)
    Assert.equal(game:renderAttempts(), 0, "Start Menu acceptance must stop before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

function T.tests.production_start_menu_follows_the_ordered_candidate_topology()
  withEveryVersion(function(harness, versionId)
    local options = { width = 256, height = 192, topology = topology(256, 192) }
    withGame(harness, versionId, options, function(game)
      -- A fresh save owns no progression: only the unlock-gated trainer
      -- card, save, and options rows are present, keeping their fixed
      -- retail slots on the right column while the early slots stay holes.
      local status = openMenu(game)
      Assert.equal(status.selectedPosition, 4, "fresh field selection starts at the first present fixed slot")

      local byPosition = {}
      for _, action in ipairs(status.actions) do
        byPosition[action.position] = action
      end
      Assert.isNil(byPosition[0], "the absent pokedex slot remains a hole")
      Assert.isNil(byPosition[1], "the absent pokemon slot remains a hole")
      Assert.isNil(byPosition[2], "the absent bag slot remains a hole")
      Assert.isNil(byPosition[3], "the absent pokegear slot remains a hole")
      Assert.notNil(byPosition[4], "the trainer card keeps its fixed slot")
      Assert.isFalse(byPosition[4].enabled, "the trainer card is visible but disabled")
      Assert.notNil(byPosition[5], "save keeps its fixed slot")
      Assert.notNil(byPosition[6], "options keeps its fixed slot")
      Assert.isNil(byPosition[7], "the special-9 bookkeeping entry is not a visual button")
      Assert.isNil(byPosition[8], "the special-10 bookkeeping entry is not a visual button")

      game.runtime:pressAction()
      game:step()
      game.runtime:releaseAction()
      Assert.equal(menuStatus(game).selectedPosition, 4, "a disabled visible action is not activated")

      Assert.equal(navigate(game, "east").selectedPosition, 4, "right stays on the first visible candidate")
      Assert.equal(navigate(game, "south").selectedPosition, 5, "down selects the next visible candidate")
      Assert.equal(navigate(game, "west").selectedPosition, 5, "left stays when no candidate is visible")
      Assert.equal(navigate(game, "north").selectedPosition, 4, "up selects the previous visible candidate")
      Assert.equal(navigate(game, "south").selectedPosition, 5, "down selects the next visible candidate again")
      Assert.equal(navigate(game, "east").selectedPosition, 5, "right stays when no candidate is visible")
      Assert.equal(navigate(game, "south").selectedPosition, 6, "down selects the last visible candidate")
      Assert.equal(navigate(game, "west").selectedPosition, 6, "left stays when no candidate is visible")

      local hitRect = game.runtime.uiManifest.startMenu.interactive.positions[0].hitRect
      game.runtime.input:pointerMove("acceptance:start-menu:pointer", hitRect.x + 1, hitRect.y + 1)
      game:step()
      Assert.equal(menuStatus(game).selectedPosition, 6, "pointer hover over a position hole changes nothing")
    end)
  end)
end

return T
