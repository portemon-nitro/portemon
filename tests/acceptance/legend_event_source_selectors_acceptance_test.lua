-- The source event-key selector behind the local event guardians. Script 546
-- compares the raw event key the caller names against the key the save already
-- carries and writes its answer into the requested output, and the guardian's
-- own authored branches decide what the player receives from that answer. The
-- selector is exercised through the production field script composition on its
-- own generated script; only audio, fade and clock host boundaries are recorded,
-- and the render trap stays active throughout.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local FinalizedGameFixture = require("tests.support.FinalizedGameFixture")

local T = {
  metadata = {
    capabilities = { "rom_dump" },
    derivedAssets = {
      "field-runtime",
      -- Elm's Lab hosts the scenario's field; the guardian script itself is a
      -- global generated script and is independent of the map it runs on.
      "map-data:61",
      "map:61",
      "message-bank:543",
      "message-bank:40",
      "map-data:69",
      "map:69",
      "message-bank:552",
      "encounters:global",
      "trainers:global",
    },
    tags = { "field", "script", "legend" },
  },
  tests = {},
}

-- The event guardian's own script: it asks for the source event key and then
-- hides or reveals its own host depending on the answer.
local GUARDIAN_SCRIPT = "vanilla.hgss.scr_seq.0755.script_014"
-- The guardian only asks once its own story progress word still reads zero, and
-- only while the player actually holds the event's own key item.
local GUARDIAN_RESULT_VAR = assert(FieldScriptSymbols.variablesByName.VAR_UNK_4083)
local EVENT_KEY_VAR = assert(FieldScriptSymbols.variablesByName.VAR_UNK_4043)
-- The guardian names this script variable as the selector's output operand, so
-- the selector writes its answer into it rather than into a fixed destination.
local SELECTOR_OUTPUT_VAR = assert(FieldScriptSymbols.variablesByName.VAR_BASE)
local HOST_HIDDEN_BEFORE = assert(FieldScriptSymbols.flagsByName.FLAG_HIDE_STEVEN_IN_HOUSE_BEFORE_LATIS)
local HOST_HIDDEN_AFTER = assert(FieldScriptSymbols.flagsByName.FLAG_HIDE_STEVEN_IN_HOUSE_AFTER_LATIS)
-- src/scrcmd_c.c::ScrCmd_CheckEventKey reads the save's two stored event keys;
-- the raw key operand 0 selects the first of them, whose accepted value is
-- 0x06F2. Any other stored value is refused.
local EVENT_KEY_ITEM_ID = 536
local ACCEPTED_KEY = 0x06F2
local REFUSED_KEY = 0x1234

---@param eventKey integer
---@return AcceptanceHarness
local function harnessWithKey(eventKey)
  local worldState = FieldEventState.new()
  worldState:setVar(GUARDIAN_RESULT_VAR, 0)
  worldState:setVar(EVENT_KEY_VAR, eventKey)
  worldState:setFlag(HOST_HIDDEN_AFTER)
  return AcceptanceHarness.new({
    gameFactory = function(versionId)
      return FinalizedGameFixture.build(versionId, {
        location = { mapSymbol = "MAP_NEW_BARK_ELMS_LAB_1F", fieldX = 4, fieldZ = 13, facing = "north" },
        worldState = worldState,
      })
    end,
  })
end

---@param game table
---@param itemKey string
---@return table game
local function bootGuardian(game, itemKey)
  Assert.isTrue(
    game.runtime.bagService:add(itemKey, 1),
    "the guardian scenario stocks the event's own key item through the production bag"
  )
  game:waitForFieldReady(480)
  game:startScript(GUARDIAN_SCRIPT)
  for _ = 1, 240 do
    if #game:recordsForScript(GUARDIAN_SCRIPT, "script.ended") > 0 then
      return game
    end
    if #game:recordsForScript(GUARDIAN_SCRIPT, "script.error") > 0 then
      return game
    end
    if game:contextChoiceStatus() ~= nil or game:snapshot().dialogue.modal then
      game:pressAction()
    else
      game:step()
    end
  end
  return game
end

---@param game table
---@return string[]
local function faults(game)
  local faults = {}
  for _, record in ipairs(game:recordsForScript(GUARDIAN_SCRIPT, "script.error")) do
    local payload = record.payload or {}
    local context = payload.context or {}
    faults[#faults + 1] = string.format(
      "%s/%s/%s",
      tostring(payload.code),
      tostring(context.command or context.originalName or "unknown"),
      tostring(payload.message)
    )
  end
  return faults
end

-- The accepted key sends the guardian down its authored reward branch, which
-- reveals the host the event unlocks.
function T.tests.accepted_event_key_runs_the_authored_reward_branch()
  local versionId = AcceptanceHarness.defaultVersion()
  local game = harnessWithKey(ACCEPTED_KEY):boot({
    versionId = versionId,
    save = "fresh",
    fieldOptions = { recordingScriptHosts = true, audioHost = "recording" },
  })
  local ok, err = xpcall(function()
    game:waitForFieldEntry()
    local itemKey = game.runtime.itemCatalog:itemKeyByNativeId(EVENT_KEY_ITEM_ID)
    bootGuardian(game, itemKey)
    local observed = faults(game)
    Assert.equal(#observed, 0, "the guardian script runs its own native operations: " .. table.concat(observed, ","))
    local world = game.runtime.scripts.worldState
    Assert.equal(
      world:getVar(GUARDIAN_RESULT_VAR),
      1,
      "the accepted event key completes the guardian's own story word"
    )
    Assert.equal(
      world:getVar(SELECTOR_OUTPUT_VAR),
      1,
      "the accepted event key writes its answer into the named output variable"
    )
    Assert.isFalse(
      world:isFlagSet(HOST_HIDDEN_BEFORE),
      "the accepted event key reveals the host the event unlocks"
    )
    Assert.isTrue(world:isFlagSet(HOST_HIDDEN_AFTER), "the accepted event key keeps the post-event host hidden")
    Assert.equal(game:renderAttempts(), 0, "the selector acceptance stops before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

-- Any other stored key is refused: the guardian keeps its host hidden and never
-- advances its own story word.
function T.tests.mismatched_event_key_is_refused_without_reward()
  local versionId = AcceptanceHarness.defaultVersion()
  local game = harnessWithKey(REFUSED_KEY):boot({
    versionId = versionId,
    save = "fresh",
    fieldOptions = { recordingScriptHosts = true, audioHost = "recording" },
  })
  local ok, err = xpcall(function()
    game:waitForFieldEntry()
    local itemKey = game.runtime.itemCatalog:itemKeyByNativeId(EVENT_KEY_ITEM_ID)
    bootGuardian(game, itemKey)
    local observed = faults(game)
    Assert.equal(#observed, 0, "the guardian script runs its own native operations: " .. table.concat(observed, ","))
    local world = game.runtime.scripts.worldState
    Assert.equal(
      world:getVar(GUARDIAN_RESULT_VAR),
      0,
      "a mismatched event key never advances the guardian's story word"
    )
    Assert.isTrue(
      world:isFlagSet(HOST_HIDDEN_BEFORE),
      "a mismatched event key leaves the host the event unlocks hidden"
    )
    Assert.equal(game:renderAttempts(), 0, "the selector acceptance stops before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

return T
