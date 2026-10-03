-- Complete one generated follower interaction through the production field runtime.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FollowerInteractionCache = require("libs.assets.src.field.FollowerInteractionCache")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local FashionCaseState = require("libs.hgss.src.save.FashionCaseState")

local T = {
  metadata = {
    capabilities = { "rom_dump" },
    derivedAssets = {
      "field-runtime",
      "map-data:12",
      "map-data:17",
      "map-data:28",
      "map-data:29",
      "map-data:31",
      "map-data:33",
      "map-data:47",
      "map-data:48",
      "map-data:52",
      "map-data:60",
      "map-data:63",
      "map-data:64",
      "map:33",
      "map:60",
      "map:63",
      "map:64",
    },
    tags = { "field", "follower-interaction", "production" },
  },
  tests = {},
}

local MAP = "MAP_NEW_BARK"

local function boot(versionId)
  local harness = AcceptanceHarness.new()
  local gameFactory = harness.gameFactory
  harness.gameFactory = function(factoryVersion, map)
    local game = gameFactory(factoryVersion, map)
    game.fashionCase = FashionCaseState.empty()
    return game
  end
  local game = harness:boot({
    versionId = versionId,
    map = MAP,
    save = "fresh",
    fieldOptions = { recordingScriptHosts = true },
  })
  local ok, result = xpcall(function()
    game:waitForFieldReady()
    return game
  end, debug.traceback)
  if not ok then
    game:close()
    error(result, 0)
  end
  return game
end

local function taskContext(game, engine)
  local runtime = game.runtime
  local scripts = assert(runtime.scripts, "production field scripts are required")
  return {
    services = {
      followerInteraction = engine,
      followingMon = assert(runtime.followingMon),
      actors = assert(runtime.actors),
      terrainEffects = assert(runtime.fieldTerrainEffectController),
      audio = assert(runtime.scriptHosts and runtime.scriptHosts.audio, "recorded audio output is required"),
      dialogue = assert(scripts.dialogueHost),
      contextChoice = assert(runtime.contextChoiceProvider),
      world = assert(scripts.worldState),
      mons = assert(runtime.monService),
      player = assert(scripts.player),
    },
    instance = { instanceId = "acceptance-follower-interaction", scriptId = "acceptance", textArgs = {} },
    input = {},
  }
end

local function advanceTask(game, task, state, ctx)
  for _ = 1, 2400 do
    local result = task.poll(state, ctx)
    state = result.state
    if result.complete then
      return state
    end

    game:step()
    ctx.input = {}
    if state.dialogueState and state.dialogueState.phase == "input_armed" then
      ctx.input.pressedAction = true
    elseif state.choiceState and state.choiceState.phase == "waiting" then
      ctx.input.uiEvents = { { type = "confirm" } }
    end
  end
  error("generated follower interaction did not complete within the bounded fixed-tick window")
end

function T.tests.generated_rule_completes_with_live_field_owners()
  local versionId = AcceptanceHarness.defaultVersion()
  local game = boot(versionId)
  local ok, err = xpcall(function()
    local cacheFs = CacheFs.forVersion(versionId)
    local catalog = assert(cacheFs:loadLua(FollowerInteractionCache.catalogPath()))
    Assert.isTrue(
      FollowerInteractionCache.validateCatalog(catalog),
      "the supplied ROM must publish a valid interaction catalog"
    )

    local runtimeMap = assert(game.runtime.session.currentMap)
    local sectionRules = catalog.rulesByMapSection[runtimeMap.mapSectionNativeId]
    Assert.notNil(sectionRules, "the supplied ROM must have an interaction rule list for the loaded map section")
    Assert.isTrue(#sectionRules > 0, "the loaded map section must contain at least one generated interaction rule")

    Assert.isTrue(
      game.runtime.monService:giveMon({ species = "EEVEE", level = 5, form = 0 }),
      "the production mon service must add the lead mon"
    )
    game:advanceUntil("follower installation after interaction setup", function()
      return game.runtime.followingMon:partnerActorId() ~= nil
    end, 120)

    local engine = assert(
      game.runtime.scripts.followerInteractionEngine,
      "the field runtime must compose the generated interaction engine"
    )
    local actorId = assert(game.runtime.followingMon:partnerActorId())
    local actor = assert(game.runtime.actors:getById(actorId))
    local start = actor:getFieldPosition()
    local facing = game.runtime.actors:getFacing(actorId)
    local task = require("libs.hgss.src.script.tasks.FollowerInteractionTask")
    local ctx = taskContext(game, engine)
    local state = task.create({}, ctx)
    Assert.isTrue(
      catalog.programs[state.programId] ~= nil,
      "selection must resolve to a program from the supplied ROM catalog"
    )
    local selectedFromMap = false
    for _, rule in ipairs(sectionRules) do
      selectedFromMap = selectedFromMap or rule.interactionId == state.programId
    end
    Assert.isTrue(selectedFromMap, "selection must come from the live map section's generated rule list")

    local completed, outcome = pcall(advanceTask, game, task, state, ctx)
    if not completed then
      task.cancel(state, "acceptance failure cleanup", ctx)
    end
    Assert.isTrue(
      completed,
      "the production task must resolve the generated dialogue bindings and complete: " .. tostring(outcome)
    )
    state = outcome
    Assert.equal(state.phase, "done", "the selected retail interaction must complete")
    local ending = actor:getFieldPosition()
    Assert.equal(ending.fieldX, start.fieldX, "interaction motion must preserve the partner's logical X")
    Assert.equal(ending.fieldZ, start.fieldZ, "interaction motion must preserve the partner's logical Z")
    Assert.equal(
      game.runtime.actors:getFacing(actorId),
      facing,
      "interaction cleanup must restore the original partner facing"
    )
    Assert.isFalse(game.runtime.scripts.dialogueHost:isOpen(), "interaction completion must close task-owned dialogue")
    Assert.isNil(game.runtime.contextChoiceProvider:status(), "interaction completion must close task-owned choices")
    Assert.equal(game:renderAttempts(), 0, "follower interaction acceptance must stop before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

return T
