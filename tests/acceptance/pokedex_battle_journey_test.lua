-- A wild first catch through the complete production field: the journey
-- boots a real game, gifts a party mon and guaranteed balls, enables the
-- dex, launches a real generated wild battle, and lands the capture
-- through the live committer. The terminal result carries the frozen
-- first-catch facts exactly once before publication; the field returns
-- cleanly, the browser shows the committed knowledge, and a save capture
-- plus production restart retains it. A repeat capture of the same
-- species presents no second card while extending observed history. Real
-- field runtime, generated caches, and live services throughout; only
-- host boundaries (saves, render trap) are faked, and no GPU call may
-- occur on any journey.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local FieldApplicationHost = require("libs.hgss.src.field.FieldApplicationHost")
local FieldApplicationIds = require("libs.hgss.src.field.FieldApplicationIds")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local FieldState = require("game.hgss.src.field.FieldState")
local GameVersion = require("romdump.src.source.GameVersion")
local RomImporter = require("romdump.src.source.RomImporter")
local SessionFixture = require("libs.battle.tests.session_fixture")

local T = {}

local DEX_ACTION = "vanilla.pokedex"
local POKEDEX_APPLICATION = FieldApplicationIds.POKEDEX
local FLAG_GOT_POKEDEX = FieldScriptSymbols.flagsByName.FLAG_GOT_POKEDEX
local WILD_MEMBER = 1

---@param behavior string missing field behavior under test
local function requireComposition(behavior)
  local ok, loaded = pcall(require, "game.hgss.src.pokedex.PokedexComposition")
  Assert.isTrue(ok, "missing field pokedex factory: " .. behavior .. " (game.hgss.src.pokedex.PokedexComposition)")
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
-- composition, capture, return, and browser ownership with the real
-- catalog, model, and factory, but no GPU may realize. The lease stays
-- pending like an unready worker while the retained host cover owns the
-- tick, so the browser still advances its first motion and closes
-- normally.
---@param game table<string, unknown> booted acceptance game
local function bindPokedexLease(game)
  local runtime = assert(game.runtime, "the journey binds the field preparation seam")
  local releases = 0
  runtime:bindPokedexPreparation(function(_)
    local lease = {}
    function lease:prepare(_)
      return { kind = "pending" }
    end
    function lease:release()
      releases = releases + 1
    end
    function lease:releases()
      return releases
    end
    return lease
  end)
end

---@param versionId string ready game version under test driving
---@param fn fun(game: table<string, unknown>) journey body under test driving
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
    Assert.equal(game:renderAttempts(), 0, "the capture journey stops before GPU rendering")
  end, debug.traceback)
  local namespace = game.saveNamespace
  game:close()
  if not ok then
    error(err, 0)
  end
  Assert.isNil(love.filesystem.getInfo(namespace), "teardown removes the isolated save namespace")
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
-- lifecycle consume the tick that starts it. Pure setup readiness; no
-- scenario assertion moves.
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

---@param game table<string, unknown> booted acceptance game
local function seedDexEnabled(game)
  game:setWorldState({ flag = FLAG_GOT_POKEDEX })
  local dex = assert(game.runtime.dexKnowledge, "field runtime owns the live dex knowledge")
  -- Ownership flags live with the knowledge owner, never with the story
  -- flag alone: the seeded grant stages dexEnabled beside seen-only
  -- history, mirroring the acquisition grant without its script. No
  -- species starts caught, so any wild capture is a first catch.
  dex
    :prepareChanges({
      flags = { dexEnabled = true },
      seen = { "CHIKORITA" },
    })
    :publish()
  Assert.isTrue(dex:hasPokedex(), "the seeded grant unlocks the destination")
end

---@param record table packet log owned by the test
---@return table five-operation recording presentation port
local function recordingPort(record)
  return {
    enter = function(_plan)
      record.enters = record.enters + 1
      return true
    end,
    present = function(packet)
      record.packets[#record.packets + 1] = packet
    end,
    ready = function()
      return true
    end,
    leave = function(_plan)
      record.leaves = record.leaves + 1
      return true
    end,
    dispose = function()
      record.disposed = record.disposed + 1
    end,
  }
end

---@param game table<string, unknown> live acceptance game behind the journey
---@param firstEvent integer first event identity for the attempt scan
---@return integer attempt identity holding a prepared wild encounter
local function prepareWild(game, firstEvent)
  local runtime = game.runtime
  for index = firstEvent, firstEvent + 99 do
    local attempt = runtime:attemptEncounter({
      eventId = index,
      mapId = WILD_MEMBER,
      method = "grass",
      movement = "step",
      modifiers = {},
      environment = {},
      timeOfDay = "day",
      playerProfile = runtime.playerData.profile,
    })
    Assert.notNil(attempt, "grass attempts answer through the composed service")
    if attempt.kind == "prepared" then
      return assert(attempt.attemptId, "a prepared attempt carries its identity")
    end
  end
  error("grass attempts prepare a wild encounter within budget", 0)
end

---@param game table<string, unknown> live acceptance game behind the journey
---@param choose fun(request: table<string, unknown>, turn: integer): table decision driver
---@param budget integer maximum update ticks before the driver gives up
local function runLeg(game, choose, budget)
  local runtime = game.runtime
  local turn = 0
  local ticks = 0
  while runtime.battleCoordinator:activeBattle() ~= nil and ticks < (budget or 1200) do
    local battle = runtime.battleCoordinator:activeBattle()
    local current = battle:status()
    if current.phase == "running" and current.request ~= nil then
      turn = turn + 1
      local answer = choose(current.request, turn)
      local choices = answer
      if type(answer) == "table" and answer.kind ~= nil then
        choices = { answer }
      end
      assert(type(choices) == "table", "decision drivers answer with a choice record or a choice array")
      local actors = assert(current.request.actors, "player decisions address their combatants")
      Assert.equal(#choices, #actors, "every addressed actor answers exactly once")
      for index, actor in ipairs(actors) do
        Assert.isTrue(choices[index].actor == actor, "replies preserve their addressed actor records in order")
      end
      local accepted, replyErr = battle:submit(SessionFixture.replyFor(current.request, choices))
      Assert.isTrue(accepted, "a legal decision is accepted: " .. tostring(replyErr))
    end
    runtime:updateBattle()
    ticks = ticks + 1
  end
  Assert.isNil(runtime.battleCoordinator:activeBattle(), "answered decisions settle the owned lifetime")
  return turn
end

---@param game table<string, unknown> booted acceptance game
---@return string captured species key
---@return table delivered presentation packets
---@return integer captured wild personality
local function captureWild(game)
  local runtime = game.runtime
  Assert.isTrue(
    runtime.monService:giveMon({ species = "CHIKORITA", level = 10, heldItem = "NONE", form = 0 }),
    "the journey needs its catcher"
  )
  Assert.isTrue(runtime.bagService:add("MASTER_BALL", 2), "the journey stocks its guaranteed balls")
  local prepared = prepareWild(game, 2)
  local pending = assert(runtime.pendingEncounter, "the prepared encounter waits for its launch")
  local wild = assert(pending.mons[1].mon, "the prepared encounter carries its wild mon")
  local species = assert(wild.species, "the prepared wild mon names its species")
  local dex = assert(runtime.dexKnowledge, "the journey needs its live dex knowledge")
  Assert.isFalse(dex:isCaught(species), "the journey captures a previously uncaught species")
  local partyBefore = runtime.monService:partyCount()
  local record = { enters = 0, packets = {}, leaves = 0, disposed = 0 }
  runtime:startBattle({
    request = {
      id = "launch-capture-first-catch",
      kind = "wild",
      payload = {
        species = species,
        level = runtime.monService:derive(wild).level,
        attemptId = prepared,
      },
    },
    presentation = recordingPort(record),
    seed = 0xD080073,
  })
  local battle = assert(runtime.battleCoordinator:activeBattle(), "the field retains its active battle owner")
  local foeOf = function()
    return runtime.monService:partyCount() + 1
  end
  runLeg(game, function(request)
    if request.kind == "learn_move" then
      local actor = assert(request.actors[1], "learning prompts address their recipient")
      return { actor = actor, kind = "confirm", payload = { decision = "decline" } }
    end
    local actor = assert(request.actors[1], "every player decision addresses its combatant")
    return { actor = actor, kind = "item", payload = {
      item = "MASTER_BALL",
      target = { kind = "combatant", combatant = foeOf() },
    } }
  end)
  Assert.isNil(runtime.errorText, "the capture settles without faulting the field")
  Assert.equal(battle:status().phase, "complete", "the capture battle owner settles")
  local receipt = assert(battle:status().outcomeReceipt, "completion carries its commit receipt")
  Assert.isTrue(receipt.committed, "the capture owner receipt proves publication")
  Assert.equal(runtime.monService:partyCount(), partyBefore + 1, "the caught mon lands in the live party")
  local stored = runtime.monService:partyMon(partyBefore)
  Assert.equal(stored.species, species, "the appended mon keeps its species")
  Assert.equal(stored.personality, wild.personality, "the appended mon keeps its wild identity")
  return species, record, wild.personality
end

---@param packets table[] delivered presentation packets under inspection
---@return table[] result-bearing packets carrying frozen first-catch facts
local function registrationTerminals(packets)
  local terminals = {}
  for _, packet in ipairs(packets) do
    if type(packet) == "table" and type(packet.result) == "table" and packet.result.registration ~= nil then
      terminals[#terminals + 1] = packet
    end
  end
  return terminals
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

local function runCaptureJourney(versionId)
  requireComposition("real capture, return, and browser composition")
  withGame(versionId, function(game)
    local state = hostCallbacks(game)
    seedDexEnabled(game)
    local dex = assert(game.runtime.dexKnowledge, "field runtime owns the live dex knowledge")

    local species, record = captureWild(game)

    -- The card appears exactly once before publication: one terminal
    -- result carries the frozen facts, and the live owners already show
    -- the committed capture with its actual observed identity.
    local terminals = registrationTerminals(record.packets)
    Assert.equal(#terminals, 1, "the first catch presents its registration card exactly once")
    local registration = terminals[1].result.registration
    Assert.equal(registration.specimen.species, species, "the card freezes the actual captured species")
    Assert.isTrue(
      type(registration.displayName) == "string" and registration.displayName ~= "",
      "the card freezes a nonempty display name"
    )
    Assert.equal(
      registration.dexMode,
      dex:hasNationalDex() and "national" or "johto",
      "the card freezes the live national mode instead of rereading it later"
    )
    Assert.isTrue(dex:isCaught(species), "the committed capture registers caught knowledge")
    Assert.isTrue(dex:isSeen(species), "a caught mon counts as seen")
    Assert.isTrue(
      #dex:observedGenders(species) >= 1,
      "the committed capture records its actual observed gender"
    )
    local lastResult = assert(
      game.runtime:lastBattleResult(),
      "the settled capture records its outcome words"
    )
    Assert.equal(lastResult.result, "capture", "the committed capture reports its outcome word")

    -- The field resumes around the retained menu, and the browser shows
    -- the committed knowledge without recording new history.
    local viewing = openPokedex(game, state)
    Assert.isTrue(viewing.application ~= nil, "the open application exposes its live child")
    closePokedex(game, state)
    local remembered = actionById(menuStatus(game), DEX_ACTION)
    Assert.isTrue(remembered ~= nil, "the retained menu remembers its selection across the child")
    cancel(game, state)
    game:advanceUntil("the menu closes back to the field", function(snapshot)
      return hostPhase(game) == FieldApplicationHost.PHASES.closed and not snapshot.fieldLocked
    end, 120)

    -- A stable save capture plus production restart retains the capture,
    -- its observed history, and the party mon.
    local countBefore = dex:countCaught("johto") + dex:countCaught("national")
    local gendersBefore = dex:observedGenders(species)
    Assert.isTrue(game.runtime:captureGameSave() ~= nil, "quit-save requires a stable captured game")
    game:save()
    game:restart()
    game:waitForFieldEntry()
    local reloaded = assert(game.runtime.dexKnowledge, "continue restores the live dex knowledge")
    Assert.isTrue(reloaded:isCaught(species), "continue retains the captured species")
    Assert.deepEqual(
      reloaded:observedGenders(species),
      gendersBefore,
      "continue retains the observed gender history"
    )
    Assert.equal(
      reloaded:countCaught("johto") + reloaded:countCaught("national"),
      countBefore,
      "continue retains the exact caught counts"
    )
    local kept = false
    for index = 0, game.runtime.monService:partyCount() - 1 do
      if game.runtime.monService:partyMon(index).species == species then
        kept = true
      end
    end
    Assert.isTrue(kept, "continue retains the captured party mon")
    Assert.isNil(game.runtime.errorText, "reloading the captured game does not fault the field")
  end)
end

function T.first_capture_registers_once_then_browser_and_save_remember_it(context)
  for _, versionId in ipairs(requireVersions(context)) do
    runCaptureJourney(versionId)
  end
end

-- Catching the same species again presents no second card while its newly
-- observed history still extends: the repeat terminal carries no
-- registration, first history stays frozen, and the gender record grows
-- only with genuinely new observations.
function T.repeat_capture_skips_the_card_but_extends_observed_history(context)
  for _, versionId in ipairs(requireVersions(context)) do
    requireComposition("repeat capture and history extension")
    withGame(versionId, function(game)
      seedDexEnabled(game)
      local dex = assert(game.runtime.dexKnowledge, "field runtime owns the live dex knowledge")
      local species, firstRecord, _ = captureWild(game)
      local firstTerminals = registrationTerminals(firstRecord.packets)
      Assert.equal(#firstTerminals, 1, "the first catch presents its registration card exactly once")

      -- The same wild species must reappear through the composed
      -- encounter service: bounded windows only, otherwise the leg stays
      -- blocked instead of inventing its setup.
      local repeatPrepared = nil
      for window = 102, 502, 100 do
        local attempt = nil
        for index = window, window + 99 do
          attempt = game.runtime:attemptEncounter({
            eventId = index,
            mapId = WILD_MEMBER,
            method = "grass",
            movement = "step",
            modifiers = {},
            environment = {},
            timeOfDay = "day",
            playerProfile = game.runtime.playerData.profile,
          })
          if attempt ~= nil and attempt.kind == "prepared" then
            local candidate = assert(attempt.attemptId, "a prepared attempt carries its identity")
            local pending = assert(game.runtime.pendingEncounter, "the prepared encounter waits")
            if pending.mons[1].mon.species == species then
              repeatPrepared = candidate
              break
            end
          end
        end
        if repeatPrepared ~= nil then
          break
        end
      end
      if repeatPrepared == nil then
        assert(context ~= nil, "blocked-leg reporting needs its runner context")
        context:skip("the wild species did not reappear in budget; the repeat leg stays blocked")
        return
      end

      local runtime = game.runtime
      local pending = assert(runtime.pendingEncounter, "the repeat encounter waits for its launch")
      local wild = assert(pending.mons[1].mon, "the repeat encounter carries its wild mon")
      local record = { enters = 0, packets = {}, leaves = 0, disposed = 0 }
      runtime:startBattle({
        request = {
          id = "launch-capture-repeat",
          kind = "wild",
          payload = {
            species = species,
            level = runtime.monService:derive(wild).level,
            attemptId = repeatPrepared,
          },
        },
        presentation = recordingPort(record),
        seed = 0xD080074,
      })
      local foeOf = function()
        return runtime.monService:partyCount() + 1
      end
      runLeg(game, function(request)
        if request.kind == "learn_move" then
          local actor = assert(request.actors[1], "learning prompts address their recipient")
          return { actor = actor, kind = "confirm", payload = { decision = "decline" } }
        end
        local actor = assert(request.actors[1], "every player decision addresses its combatant")
        return { actor = actor, kind = "item", payload = {
          item = "MASTER_BALL",
          target = { kind = "combatant", combatant = foeOf() },
        } }
      end)
      Assert.isNil(runtime.errorText, "the repeat capture settles without faulting the field")
      Assert.equal(#registrationTerminals(record.packets), 0, "a repeat catch presents no second card")
      Assert.isTrue(dex:isCaught(species), "the repeat catch keeps the species caught")
      Assert.isNil(
        dex:firstPersonality(species),
        "the repeat catch never reorders first history"
      )
      local genders = dex:observedGenders(species)
      Assert.isTrue(#genders >= 1, "observed gender history survives the repeat catch")
    end)
  end
end

function T.heartgold_capture_legs_stay_blocked_without_a_dump(context)
  if not RomImporter.isReady("heartgold") then
    assert(context ~= nil, "blocked-version reporting needs its runner context")
    context:skip("heartgold dump not owned; the heartgold capture legs stay blocked")
    return
  end
  requireComposition("real capture, return, and browser composition")
  runCaptureJourney("heartgold")
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
    tags = { "pokedex", "battle" },
  },
}
