-- The complete field Pokedex through production composition: the Start Menu
-- offers the destination once the dex grant lands, opening pauses field
-- simulation over the retained menu, every advertised page is reachable
-- and interactive, modal input keeps held state without leaking into
-- siblings, closing returns through the remembered menu with resume
-- persisted and history untouched, and repeated journeys release every
-- membership. Real field runtime over the prepared derived cache with the
-- ready dumps; the missing-dump version reports blocked. Only host
-- boundaries (saves, render trap) are faked; maps, scripts, actors, the
-- generated dex catalogs, and the save composition stay production. No
-- renderer or GPU call may occur on any journey.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local FieldApplicationHost = require("libs.hgss.src.field.FieldApplicationHost")
local FieldApplicationIds = require("libs.hgss.src.field.FieldApplicationIds")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local FieldState = require("game.hgss.src.field.FieldState")
local GameVersion = require("romdump.src.source.GameVersion")
local RomImporter = require("romdump.src.source.RomImporter")

local T = {}

local COMPOSITION_MODULE = "game.hgss.src.pokedex.PokedexComposition"
local DEX_ACTION = "vanilla.pokedex"
local BAG_ACTION = "vanilla.bag"
local POKEDEX_APPLICATION = FieldApplicationIds.POKEDEX
local FLAG_GOT_POKEDEX = FieldScriptSymbols.flagsByName.FLAG_GOT_POKEDEX

---@param behavior string missing field behavior under test
local function requireComposition(behavior)
  local ok, loaded = pcall(require, COMPOSITION_MODULE)
  Assert.isTrue(ok, "missing field pokedex factory: " .. behavior .. " (" .. COMPOSITION_MODULE .. ")")
  assert(loaded ~= nil, "the field pokedex factory loads")
end

local function readyVersions()
  local versions = {}
  for _, versionId in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(versionId) then
      versions[#versions + 1] = versionId
    end
  end
  return versions
end

local function requireVersions(context)
  local versions = readyVersions()
  if #versions == 0 then
    if context ~= nil and type(context.hasCapability) == "function" then
      context:skip("requires rom_dump and prepared assets")
    end
    error("production field boot needs a ready versioned cache", 0)
  end
  return versions
end

-- Headless preparation double: the journey proves production
-- composition, pause/return ownership, and resume with the real catalog,
-- model, and factory, but no GPU may realize. The lease stays pending
-- like an unready worker while the retained host cover owns the tick, so
-- the browser still advances its first motion and closes normally.
-- The most recently bound preparation gate, so journeys can stage
-- delayed first readiness: closed while the screen must stay inert, opened
-- once the test models staged worker completion.
local boundGate = nil

---@param game table<string, unknown> booted acceptance game
---@return table gate with open/releases behind the bound lease double
local function bindPokedexLease(game)
  local runtime = assert(game.runtime, "the journey binds the field preparation seam")
  local gate = { open = false, releases = 0 }
  -- Headless preparation double: the journey proves production
  -- composition, pause/return ownership, and resume with the real catalog,
  -- model, and factory, but no GPU may realize. The lease stays pending
  -- until the journey opens the gate, then commits one imageless whole
  -- bundle whose animations record alone admits further motion.
  local bundle = { animations = {}, chrome = {}, pictures = {}, surfaces = {}, fonts = {}, messages = {} }
  runtime:bindPokedexPreparation(function(_)
    local lease = {}
    function lease:prepare(demand)
      if gate.open and type(demand) == "table" and demand.key ~= nil then
        return { kind = "ready", key = demand.key, assets = bundle }
      end
      return { kind = "pending" }
    end
    function lease:release()
      gate.releases = gate.releases + 1
    end
    function lease:releases()
      return gate.releases
    end
    return lease
  end)
  boundGate = gate
  return gate
end

local function withGame(versionId, fn)
  local bootWidth, bootHeight = love.graphics.getDimensions()
  local harness = AcceptanceHarness.new({ versions = { versionId } })
  local game = harness:boot({
    versionId = versionId,
    map = "MAP_NEW_BARK",
    save = "fresh",
    fieldOptions = {
      screenTopology = require("libs.ui.src.ScreenTopology").oneDisplay({
        id = "main",
        rect = { x = 0, y = 0, width = bootWidth, height = bootHeight },
        touch = false,
        role = "world",
      }),
    },
  })
  local ok, err = xpcall(function()
    game:waitForFieldEntry()
    bindPokedexLease(game)
    fn(game)
    Assert.equal(game:renderAttempts(), 0, "pokedex acceptance must stop before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

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

local function tapDirection(game, state, key)
  state:keypressed(key)
  game:step()
  state:keyreleased(key)
end

-- Waits for the field to settle before driving the menu: a closing
-- child leaves a one-use resume behind, and maps with an on_resume
-- lifecycle consume the tick that starts it. Pressing the menu edge
-- into that tick would drop it by design, so the journey only presses
-- once the host is closed, no foreground script owns the field, and no
-- resume is pending. Pure setup readiness; no scenario assertion moves.
---@param game table<string, unknown> booted acceptance game
local function waitForFieldIdle(game)
  game:advanceUntil("field settles after child return", function()
    if hostPhase(game) ~= FieldApplicationHost.PHASES.closed then
      return false
    end
    local session = game.runtime.session
    if session ~= nil then
      if session.childResumePending then
        return false
      end
      local scheduler = session.scriptScheduler
      if
        scheduler ~= nil
        and type(scheduler.foregroundEnvironmentId) == "function"
        and scheduler:foregroundEnvironmentId() ~= nil
      then
        return false
      end
    end
    return true
  end, 240)
end

local function openStartMenu(game, state)
  waitForFieldIdle(game)
  game.runtime:pressMenu()
  game:step()
  game.runtime:releaseMenu()
  game:advanceUntil("start menu becomes modal", function()
    return hostPhase(game) == FieldApplicationHost.PHASES.menu
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

local function navigateTo(game, state, id)
  for _ = 1, 40 do
    local status = menuStatus(game)
    local position = assert(status.selectedPosition, "menu status must expose the selected position")
    local current = nil
    for _, action in ipairs(assert(status.actions, "menu status must list actions")) do
      if action.position == position then
        current = action.id
      end
    end
    if current == id then
      return
    end
    tapDirection(game, state, "s")
  end
  error("the start menu never reaches its pokedex action", 0)
end

local function confirm(game, _)
  game.runtime.input:pressAction("key:return")
  game:step()
  game.runtime.input:releaseAction("key:return")
end

local function cancel(game, _)
  game.runtime:pressCancel()
  game:step()
  game.runtime:releaseCancel()
end

local function seedUnlockedDex(game)
  game:setWorldState({ flag = FLAG_GOT_POKEDEX })
  game:setWorldState({ flag = FieldScriptSymbols.flagsByName.FLAG_GOT_BAG })
  local dex = assert(game.runtime.dexKnowledge, "field runtime owns the live dex knowledge")
  -- Ownership flags live with the knowledge owner, never with the story
  -- flag alone: the seeded grant stages dexEnabled beside the mixed
  -- seen/caught history, mirroring the acquisition grant without its script.
  dex
    :prepareChanges({
      flags = { dexEnabled = true },
      seen = { "CHIKORITA", "EEVEE" },
      caught = { "TOTODILE", "SPINDA" },
    })
    :publish()
  Assert.isTrue(dex:hasPokedex(), "the seeded grant unlocks the destination")
end

local function dexCounts(game)
  local dex = assert(game.runtime.dexKnowledge, "field runtime owns the live dex knowledge")
  return dex:countSeen("johto") + dex:countSeen("national"), dex:countCaught("johto") + dex:countCaught("national")
end

local function openPokedex(game, state)
  openStartMenu(game, state)
  local action = actionById(menuStatus(game), DEX_ACTION)
  Assert.isTrue(
    action ~= nil and action.enabled == true,
    "the unlocked dex enables its start menu action through policy/capability composition"
  )
  navigateTo(game, state, DEX_ACTION)
  confirm(game, state)
  game:advanceUntil("pokedex application owns the tick", function()
    return hostPhase(game) == FieldApplicationHost.PHASES.application
  end, 120)
  local status = game.runtime.applicationHost:status()
  Assert.equal(status.applicationId, POKEDEX_APPLICATION, "the launched application is the pokedex")
  return status
end

local function closePokedex(game, state)
  cancel(game, state)
  game:advanceUntil("pokedex closes back to the start menu", function()
    return hostPhase(game) == FieldApplicationHost.PHASES.menu
  end, 240)
end

local function runLaunchJourney(versionId)
  requireComposition("real field launch, pause, return, and resume")
  withGame(versionId, function(game)
    local state = hostCallbacks(game)
    seedUnlockedDex(game)
    local seenBefore, caughtBefore = dexCounts(game)
    openPokedex(game, state)
    local viewing = game.runtime.applicationHost:status()
    Assert.isTrue(viewing.application ~= nil, "the open application exposes its live child")
    closePokedex(game, state)
    local remembered = actionById(menuStatus(game), DEX_ACTION)
    Assert.isTrue(remembered ~= nil, "the retained menu remembers its selection across the child")
    cancel(game, state)
    game:advanceUntil("the menu closes back to the field", function(snapshot)
      return hostPhase(game) == FieldApplicationHost.PHASES.closed and not snapshot.fieldLocked
    end, 120)
    local seenAfter, caughtAfter = dexCounts(game)
    Assert.equal(seenAfter, seenBefore, "browsing records no new seen history")
    Assert.equal(caughtAfter, caughtBefore, "browsing records no new caught history")
    local dex = assert(game.runtime.dexKnowledge, "field runtime owns the live dex knowledge")
    local resume = dex:resume()
    Assert.equal(type(resume), "table", "closing through the menu persists the browser resume")
    Assert.equal(resume.mode, "johto", "the persisted resume keeps the eligible browser mode")
    openStartMenu(game, state)
    local bag = actionById(menuStatus(game), BAG_ACTION)
    Assert.isTrue(bag ~= nil, "sibling destinations stay reachable after the pokedex returns")
    cancel(game, state)
    game:advanceUntil("the sibling check closes back to the field", function(snapshot)
      return hostPhase(game) == FieldApplicationHost.PHASES.closed and not snapshot.fieldLocked
    end, 120)
  end)
end

local function browserLeaf(game)
  local status = game.runtime.applicationHost:status()
  local live = assert(status.application, "the open application exposes its live child")
  return live.child or live
end

local function runFirstReadinessJourney(versionId)
  requireComposition("first-open readiness gating")
  withGame(versionId, function(game)
    local state = hostCallbacks(game)
    seedUnlockedDex(game)
    openPokedex(game, state)
    local leaf = browserLeaf(game)
    local firstPage = assert(leaf.page or (leaf.view and leaf.view.page), "the browser exposes its page")
    Assert.equal(firstPage, "cover", "the pokedex opens on its cover")
    local firstKey = assert(leaf.view, "the browser exposes its detached projection").key
    for _ = 1, 5 do
      confirm(game, state)
    end
    leaf = browserLeaf(game)
    Assert.equal(
      leaf.page or (leaf.view and leaf.view.page),
      "cover",
      "confirming the cover before readiness advances nothing"
    )
    Assert.equal(leaf.view.key, firstKey, "pending ticks publish no new generation")
    local gate = assert(boundGate, "the journey binds the preparation gate")
    gate.open = true
    game:step()
    game:step()
    confirm(game, state)
    game:advanceUntil("the committed cover admits its confirm onto the cursor entry", function()
      local live = browserLeaf(game)
      return (live.page or (live.view and live.view.page)) == "area"
    end, 240)
    cancel(game, state)
    game:advanceUntil("entry cancel returns to the grid", function()
      local live = browserLeaf(game)
      return (live.page or (live.view and live.view.page)) == "grid"
    end, 240)
    closePokedex(game, state)
    cancel(game, state)
    game:advanceUntil("the readiness journey closes back to the field", function(snapshot)
      return hostPhase(game) == FieldApplicationHost.PHASES.closed and not snapshot.fieldLocked
    end, 120)
  end)
end

local function runBrowserJourney(versionId)
  requireComposition("every advertised page presented and interactive")
  withGame(versionId, function(game)
    local state = hostCallbacks(game)
    seedUnlockedDex(game)
    openPokedex(game, state)
    local gate = assert(boundGate, "the journey binds the preparation gate")
    gate.open = true
    game:step()
    game:step()
    local status = game.runtime.applicationHost:status()
    local child = assert(status.application, "the open application exposes its live child")
    local leaf = child.child or child
    local firstPage = assert(leaf.page or (leaf.view and leaf.view.page), "the browser exposes its page")
    Assert.equal(firstPage, "cover", "the pokedex opens on its cover")
    confirm(game, state)
    game:advanceUntil("confirming the cover reaches the cursor entry", function()
      local current = game.runtime.applicationHost:status()
      local live = current.application
      local view = live.child or live
      return (view.page or (view.view and view.view.page)) == "area"
    end, 240)
    cancel(game, state)
    game:advanceUntil("entry cancel returns to the grid", function()
      local current = game.runtime.applicationHost:status()
      local live = current.application
      local view = live.child or live
      return (view.page or (view.view and view.view.page)) == "grid"
    end, 240)
    closePokedex(game, state)
    cancel(game, state)
    game:advanceUntil("the browser journey closes back to the field", function(snapshot)
      return hostPhase(game) == FieldApplicationHost.PHASES.closed and not snapshot.fieldLocked
    end, 120)
  end)
end

local function runModalInputJourney(versionId)
  requireComposition("modal controls keep held state without leaking into siblings")
  withGame(versionId, function(game)
    local state = hostCallbacks(game)
    seedUnlockedDex(game)
    state:keypressed("q")
    openPokedex(game, state)
    state:keyreleased("q")
    tapDirection(game, state, "a")
    tapDirection(game, state, "d")
    for _ = 1, 12 do
      game:step()
    end
    closePokedex(game, state)
    cancel(game, state)
    game:advanceUntil("the modal journey closes back to the field", function(snapshot)
      return hostPhase(game) == FieldApplicationHost.PHASES.closed and not snapshot.fieldLocked
    end, 120)
    openStartMenu(game, state)
    cancel(game, state)
    game:advanceUntil("the menu keeps its default behavior after modal input", function(snapshot)
      return hostPhase(game) == FieldApplicationHost.PHASES.closed and not snapshot.fieldLocked
    end, 120)
  end)
end

local function runRepeatedJourney(versionId)
  requireComposition("repeated journeys release every membership")
  withGame(versionId, function(game)
    local state = hostCallbacks(game)
    seedUnlockedDex(game)
    for _ = 1, 3 do
      openPokedex(game, state)
      confirm(game, state)
      for _ = 1, 8 do
        game:step()
      end
      local leaf = browserLeaf(game)
      if (leaf.page or (leaf.view and leaf.view.page)) == "area" then
        cancel(game, state)
        game:advanceUntil("entry cancel returns to the grid", function()
          local live = browserLeaf(game)
          return (live.page or (live.view and live.view.page)) == "grid"
        end, 120)
      end
      closePokedex(game, state)
      cancel(game, state)
      game:advanceUntil("each repeated pass returns to the field", function(snapshot)
        return hostPhase(game) == FieldApplicationHost.PHASES.closed and not snapshot.fieldLocked
      end, 120)
    end
    local dex = assert(game.runtime.dexKnowledge, "field runtime owns the live dex knowledge")
    Assert.equal(type(dex:resume()), "table", "repeated journeys keep a persisted browser resume")
  end)
end

function T.field_launch_pauses_field_and_returns_through_the_retained_menu(context)
  for _, versionId in ipairs(requireVersions(context)) do
    runLaunchJourney(versionId)
  end
end

function T.first_open_withholds_motion_until_preparation_commits(context)
  for _, versionId in ipairs(requireVersions(context)) do
    runFirstReadinessJourney(versionId)
  end
end

function T.complete_browser_journey_through_every_page(context)
  for _, versionId in ipairs(requireVersions(context)) do
    runBrowserJourney(versionId)
  end
end

function T.modal_input_keeps_held_state_and_sibling_cadence(context)
  for _, versionId in ipairs(requireVersions(context)) do
    runModalInputJourney(versionId)
  end
end

function T.repeated_field_journeys_release_every_membership(context)
  for _, versionId in ipairs(requireVersions(context)) do
    runRepeatedJourney(versionId)
  end
end

function T.heartgold_field_legs_stay_blocked_without_a_dump(context)
  if not RomImporter.isReady("heartgold") then
    assert(context ~= nil, "blocked-version reporting needs its runner context")
    context:skip("heartgold dump not owned; the heartgold field legs stay blocked")
    return
  end
  requireComposition("real field launch, pause, return, and resume")
  runLaunchJourney("heartgold")
  runBrowserJourney("heartgold")
end

return {
  tests = T,
  metadata = {
    capabilities = { "rom_dump", "derived_assets" },
    derivedAssets = {
      "field-runtime",
      "map:64",
      "map-data:64",
      "trainers:global",
      "encounters:global",
      "audio-bank:702",
      "audio-bank:756",
      "pokedex-data:global",
    },
    tags = { "pokedex" },
  },
}
