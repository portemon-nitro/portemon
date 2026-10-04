-- Complete the real following-mon script through the production field runtime.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FollowerInteractionCache = require("libs.assets.src.field.FollowerInteractionCache")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")

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
local SCRIPT_ID = "common.following_mon"

local function boot(versionId)
  local game = AcceptanceHarness.new():boot({
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

local function taskRecordsFor(game, instanceId)
  local records = {}
  for _, record in ipairs(game:recordsNamed("script.task_started")) do
    if record.payload.instanceId == instanceId and record.payload.taskType == "follower_interaction" then
      records[#records + 1] = record
    end
  end
  return records
end

local function driveScriptToEnd(game)
  for _ = 1, 3600 do
    if #game:recordsForScript(SCRIPT_ID, "script.ended") == 1 then
      return
    end
    if game:snapshot().dialogue.modal or game:contextChoiceStatus() ~= nil then
      game.runtime:pressAction()
      game:step()
      game.runtime:releaseAction()
    else
      game:step()
    end
  end
  error("the compiled following-mon script did not finish within the bounded field-tick window")
end

function T.tests.compiled_following_mon_script_blocks_on_live_interaction_and_resumes()
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

    game:startScript(SCRIPT_ID)
    game:advanceUntil("the compiled script reaches its interaction command", function()
      local starts = game:recordsForScript(SCRIPT_ID)
      if #starts ~= 1 then
        return false
      end
      return #taskRecordsFor(game, starts[1].payload.instanceId) == 1
        or #game:recordsForScript(SCRIPT_ID, "script.ended") == 1
    end, 120)
    local starts = game:recordsForScript(SCRIPT_ID)
    Assert.equal(#starts, 1, "the ROM-derived script must start exactly once")
    local instanceId = assert(starts[1].payload.instanceId)
    local interactionTasks = taskRecordsFor(game, instanceId)
    local errors = game:recordsForScript(SCRIPT_ID, "script.error")
    Assert.equal(
      #interactionTasks,
      1,
      "the compiled opcode 711 must create its registered blocking task; script fault: "
        .. tostring(errors[1] and errors[1].payload.code)
    )
    Assert.equal(interactionTasks[1].payload.taskVersion, 1, "the interaction task must use its registered version")
    local task = assert(game.runtime.scripts.scheduler:taskById(interactionTasks[1].payload.taskId))
    Assert.equal(task.taskType, "follower_interaction", "the registered task must own opcode 711")
    Assert.equal(task.status, "active", "the script must block while the interaction task is active")
    Assert.isNil(game:recordsForScript(SCRIPT_ID, "script.ended")[1], "the script must not resume before the task completes")
    Assert.isTrue(catalog.programs[task.state.programId] ~= nil, "selection must use a program from the supplied ROM catalog")
    local selectedFromMap = false
    for _, rule in ipairs(sectionRules) do
      selectedFromMap = selectedFromMap or rule.interactionId == task.state.programId
    end
    Assert.isTrue(selectedFromMap, "selection must come from the live map section's generated rule list")

    driveScriptToEnd(game)
    Assert.equal(#taskRecordsFor(game, instanceId), 1, "script execution must not create a duplicate interaction task")
    local taskEnds = {}
    for _, record in ipairs(game:recordsNamed("script.task_ended")) do
      if record.payload.instanceId == instanceId and record.payload.taskType == "follower_interaction" then
        taskEnds[#taskEnds + 1] = record
      end
    end
    Assert.equal(
      #taskEnds,
      1,
      "the registered interaction task must complete once; status="
        .. tostring(task.status)
        .. ", phase="
        .. tostring(task.state and task.state.phase)
        .. ", scriptEnd="
        .. tostring(game:recordsForScript(SCRIPT_ID, "script.ended")[1] ~= nil)
        .. ", endReason="
        .. tostring(game:recordsForScript(SCRIPT_ID, "script.ended")[1] and game:recordsForScript(SCRIPT_ID, "script.ended")[1].payload.reason)
        .. ", error="
        .. tostring(game:recordsForScript(SCRIPT_ID, "script.error")[1] and game:recordsForScript(SCRIPT_ID, "script.error")[1].payload.code)
    )
    local scriptEnds = game:recordsForScript(SCRIPT_ID, "script.ended")
    Assert.equal(#scriptEnds, 1, "the compiled script must resume and finish once")
    Assert.isTrue(scriptEnds[1].payload.completed, "the compiled script must complete after its interaction")
    Assert.equal(scriptEnds[1].payload.reason, "completed", "the script must reach its normal source end")
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
