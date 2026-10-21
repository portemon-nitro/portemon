-- Production field smoke: open the Bag and close it through host pointer input.
-- The production field owns the Bag lifecycle; this check stops before rendering.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local BagCache = require("libs.assets.src.BagCache")
local CacheFs = require("libs.storage.src.CacheFs")
local FieldApplicationHost = require("libs.hgss.src.field.FieldApplicationHost")
local FieldApplicationIds = require("libs.hgss.src.field.FieldApplicationIds")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local FieldState = require("game.hgss.src.field.FieldState")
local ScreenTopology = require("libs.ui.src.ScreenTopology")

local T = {
  metadata = {
    capabilities = { "rom_dump" },
    derivedAssets = { "field-runtime", "map:7" },
    tags = { "field", "menu", "bag" },
  },
  tests = {},
}

local FLAG_GOT_BAG = FieldScriptSymbols.flagsByName.FLAG_GOT_BAG
local BAG_ACTION = "vanilla.bag"
local BAG_APPLICATION = FieldApplicationIds.BAG

local function withGame(fn)
  -- Match the boot topology to the drawable used by the production host.
  local bootWidth, bootHeight = love.graphics.getDimensions()
  local game = AcceptanceHarness.new():boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = "MAP_BURNED_TOWER_1F",
    save = "fresh",
    fieldOptions = {
      screenTopology = ScreenTopology.oneDisplay({
        id = "main",
        rect = { x = 0, y = 0, width = bootWidth, height = bootHeight },
        touch = false,
        role = "world",
      }),
    },
  })
  local ok, err = xpcall(function()
    game:waitForFieldEntry()
    fn(game)
    Assert.equal(game:renderAttempts(), 0, "bag acceptance must stop before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

-- The same FieldState callbacks LOVE dispatches in production. No synthetic
-- input behavior of its own.
local function hostCallbacks(game)
  return setmetatable({
    runtime = {
      input = game.runtime.input,
      actionKeys = game.runtime.actionKeys,
      cancelKeys = game.runtime.cancelKeys,
      menuKeys = game.runtime.menuKeys,
    },
  }, FieldState)
end

local function hostPhase(game)
  return game.runtime.applicationHost:status().phase
end

local function openStartMenu(game)
  game.runtime:pressMenu()
  game:step()
  game.runtime:releaseMenu()
  return game:advanceUntil("start menu becomes modal", function()
    return hostPhase(game) == FieldApplicationHost.PHASES.menu
  end, 120)
end

local function closeStartMenu(game)
  game.runtime:pressMenu()
  game:step()
  game.runtime:releaseMenu()
  game:advanceUntil("start menu closes", function(snapshot)
    return hostPhase(game) == FieldApplicationHost.PHASES.closed and not snapshot.fieldLocked
  end, 120)
end

local function menuStatus(game)
  local status = game.runtime.applicationHost:status()
  Assert.equal(status.phase, FieldApplicationHost.PHASES.menu, "the start menu must own the tick")
  return assert(status.menu, "the menu phase must expose the controller status")
end

local function actionById(status, id)
  for _, action in ipairs(assert(status.actions, "menu status must list actions")) do
    if action.id == id then
      return action
    end
  end
  return nil
end

local function cursorActionId(status)
  local position = assert(status.selectedPosition, "menu status must expose the selected position")
  for _, action in ipairs(assert(status.actions, "menu status must list actions")) do
    if action.position == position then
      return action.id
    end
  end
  error("start menu cursor does not resolve to a visible action", 0)
end

local function navigateTo(game, state, id)
  local status = menuStatus(game)
  for _ = 1, #status.actions + 1 do
    if cursorActionId(menuStatus(game)) == id then
      return
    end
    state:keypressed("s")
    game:step()
    state:keyreleased("s")
  end
  error("start menu never focuses the bag action", 0)
end

local function confirm(game)
  game.runtime.input:pressAction("key:return")
  game:step()
  game.runtime.input:releaseAction("key:return")
end

local function grantBag(game)
  game:setWorldState({ flag = FLAG_GOT_BAG })
end

-- The live Bag status is published through its bounded menu flow.
local function bagView(game)
  local status = game.runtime.applicationHost:status()
  Assert.equal(
    status.phase,
    FieldApplicationHost.PHASES.application,
    "the bag application must own the tick while browsing"
  )
  Assert.equal(status.applicationId, BAG_APPLICATION, "the launched application must be the bag")
  -- Production serves the bag through the bounded menu flow: the live
  -- leaf status rides one level down with identical content.
  local flow = assert(status.application, "the bag application must expose its flow status")
  local view = assert(flow.child, "the bag flow must expose its live leaf status")
  assert(type(view) == "table", "the bag browse status must be a record")
  return view
end

local function openBag(game, state)
  openStartMenu(game)
  local action = actionById(menuStatus(game), BAG_ACTION)
  Assert.isTrue(
    action ~= nil and action.enabled == true,
    "the unlocked bag must enable its start menu action through policy/capability composition"
  )
  navigateTo(game, state, BAG_ACTION)
  confirm(game)
  game:advanceUntil("bag application opens over the retained menu", function()
    return hostPhase(game) == FieldApplicationHost.PHASES.application
  end, 120)
  game:advanceUntil("the Bag opening settles", function()
    return bagView(game).phase == "interactive"
  end, 120)
  return bagView(game)
end

-- Raw host-coordinate Cancel activation through the production host: a
-- press and release over generated Cancel geometry closes the Bag. This
-- journey proves the composed host maps the placement from real
-- pointer input through the session into the live Bag controller.
function T.tests.bag_cancel_pointer_closes_through_the_host()
  withGame(function(game)
    local state = hostCallbacks(game)
    grantBag(game)
    openBag(game, state)

    local view = bagView(game)
    local plan = assert(view.presentation, "the bag status must carry its presentation plan")
    local interactive
    for _, pane in ipairs(plan.panes) do
      if pane.interactive then
        interactive = pane
      end
    end
    interactive = assert(interactive, "the bag plan must place its interactive pane")
    local placement = assert(interactive.placement, "the interactive pane must carry its placement")
    local frame = assert(placement.frame, "the interactive placement must expose its host frame")
    local scale = assert(placement.scale, "the interactive placement must expose its scale")
    local manifest = BagCache.loadManifest(CacheFs.forVersion(AcceptanceHarness.defaultVersion()))
    local cancelGeometry = assert(
      manifest.interactive and manifest.interactive.cancel,
      "the generated manifest must carry its cancel geometry"
    )
    local cancel = assert(cancelGeometry.rect, "the generated manifest must carry its cancel control rectangle")
    local hostX = frame.x + (cancel.x + cancel.width / 2) * scale
    local hostY = frame.y + (cancel.y + cancel.height / 2) * scale

    game.runtime.input:pointerDown("touch:0", hostX, hostY)
    game:step()
    Assert.equal(
      hostPhase(game),
      FieldApplicationHost.PHASES.application,
      "the press tick must keep the bag application open"
    )
    game.runtime.input:pointerUp("touch:0", hostX, hostY)
    game:step()
    game:advanceUntil("cancel pointer closes the bag to the start menu", function()
      return hostPhase(game) == FieldApplicationHost.PHASES.menu
    end, 120)
    closeStartMenu(game)
    Assert.equal(hostPhase(game), FieldApplicationHost.PHASES.closed, "the pointer journey must end back on the field")
  end)
end

return T
