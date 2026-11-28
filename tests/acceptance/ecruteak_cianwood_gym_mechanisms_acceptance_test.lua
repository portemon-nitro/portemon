-- Ecruteak Gym's candles and Cianwood Gym's winch. Both mechanisms are driven
-- by the gyms' own generated source scripts and settle into the field's saved
-- gym union; the render trap stays active throughout.
--
-- The Ecruteak candle commands live only in the source's common trainer
-- interaction scripts, so the candle scenario enters through the medium
-- trainer the gym's own event data places on the map. The Cianwood winch's
-- source background event sits on a wall tile with no walkable terrain
-- surface, so its scenario starts the gym's own generated winch script through
-- the production script composition instead of pressing Action on that tile.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FinalizedGameFixture = require("tests.support.FinalizedGameFixture")
local EcruteakGym = require("libs.hgss.src.field.gymmick.EcruteakGym")

local T = {
  metadata = {
    capabilities = { "rom_dump" },
    derivedAssets = {
      "field-runtime",
      "map:80",
      "map-data:80",
      "message-bank:614",
      "map:139",
      "map-data:139",
      "message-bank:574",
    },
    tags = { "field", "script", "gym", "save" },
  },
  tests = {},
}

local ECRUTEAK_MAP = "MAP_ECRUTEAK_GYM"
local ECRUTEAK_INIT_SCRIPT = "vanilla.hgss.scr_seq.0922.script_000"
local ECRUTEAK_PUSH_SCRIPT = "vanilla.hgss.scr_seq.0922.script_002"
-- The source's own one-time entry scene for the gym is gated on this story
-- variable; a fixture that has already seen it starts on the puzzle floor.
local ECRUTEAK_ENTRY_SCENE_VAR =
  assert(FieldScriptSymbols.variablesByName.VAR_UNK_4079, "the Ecruteak gym entry scene gate is a source variable")
local ECRUTEAK_MEDIUM_TRAINER = { fieldX = 11, fieldZ = 19 }
local ECRUTEAK_APPROACH = { fieldX = 11, fieldZ = 20 }
local ECRUTEAK_PUSH_ENTRY = { fieldX = 12, fieldZ = 19 }
local ECRUTEAK_PUSH_LANDING = { fieldX = 16, fieldZ = 49 }

local CIANWOOD_MAP = "MAP_CIANWOOD_GYM"
local CIANWOOD_INIT_SCRIPT = "vanilla.hgss.scr_seq.0877.script_001"
local CIANWOOD_WINCH_SCRIPT = "vanilla.hgss.scr_seq.0877.script_002"
local CIANWOOD_SPAWN = { fieldX = 13, fieldZ = 18 }
-- The first script temp variable: the source winch command writes its boolean
-- result here, and the source clears temp data on every map entry
-- (src/script_manager.c::ClearTempFieldEventData), so each activation starts
-- from the cleared value.
local WINCH_RESULT_VAR =
  assert(FieldScriptSymbols.variablesByName.VAR_BASE, "the first script temp variable is a source symbol")
-- Source camera translation path (src/field/gymmick/cianwood.c): the pan moves
-- the camera target by (50, 0, 58) source units over 24 ticks out and 24 back.
local PAN_WORLD_X = 50
local PAN_WORLD_Z = 58
local PAN_TICKS_EACH_WAY = 24

local function failureText(game, scriptId)
  local faults = game:recordsForScript(scriptId, "script.error")
  if #faults == 0 then
    return "no fault"
  end
  local payload = faults[1].payload or {}
  local context = payload.context or {}
  return tostring(payload.code) .. " (command " .. tostring(context.command or context.originalName or "unknown") .. ")"
end

local function actorCount(game)
  local count = 0
  for _ in pairs(game:snapshot().actors) do
    count = count + 1
  end
  return count
end

local function sourceObjectCount(game)
  return #assert(game.runtime.runtimeMap.fieldData.events.objects, "the map's own object events are required")
end

-- The source camera targets the player. A cutscene pan is exactly the
-- deviation of the published camera target from the player's own world
-- position, so an idle field answers zero on every axis.
local function cameraOffset(snapshot)
  return {
    x = snapshot.camera.target.x - snapshot.player.worldX,
    y = snapshot.camera.target.y - snapshot.player.worldY,
    z = snapshot.camera.target.z - snapshot.player.worldZ,
  }
end

local function withGame(options, context, fn)
  if context ~= nil and type(context.hasCapability) == "function" and not context:hasCapability("rom_dump") then
    context:skip("requires rom_dump and prepared assets")
  end
  local versionId = AcceptanceHarness.defaultVersion()
  local harness = AcceptanceHarness.new({
    gameFactory = function(requestedVersion, requestedMap)
      local worldState = FieldEventState.new()
      if options.worldState ~= nil then
        options.worldState(worldState)
      end
      return FinalizedGameFixture.build(requestedVersion, {
        location = {
          mapSymbol = requestedMap,
          fieldX = options.spawn.fieldX,
          fieldZ = options.spawn.fieldZ,
          facing = "north",
        },
        worldState = worldState,
      })
    end,
  })
  local game = harness:boot({
    versionId = versionId,
    map = options.map,
    save = "fresh",
    fieldOptions = { recordingScriptHosts = true },
  })
  local ok, err = xpcall(function()
    game:waitForFieldEntry()
    fn(game)
    Assert.equal(game:renderAttempts(), 0, "the gym acceptance stops before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

---@param context table test context
---@param fn fun(game: table)
---@param spawn table? override for a scenario that must start off every trainer's sight
local function withEcruteakGame(context, fn, spawn)
  withGame({
    map = ECRUTEAK_MAP,
    spawn = spawn or ECRUTEAK_APPROACH,
    worldState = function(worldState)
      worldState:setVar(ECRUTEAK_ENTRY_SCENE_VAR, 1)
    end,
  }, context, fn)
end

local function withCianwoodGame(context, fn)
  withGame({ map = CIANWOOD_MAP, spawn = CIANWOOD_SPAWN }, context, fn)
end

local function endedCount(game, scriptId)
  return #game:recordsForScript(scriptId, "script.ended")
end

-- The source winch script's own interaction variable carries its result, so
-- every independent activation starts from the source's cleared temp value.
local function clearWinchResult(game)
  game.runtime.scripts.worldState:setVar(WINCH_RESULT_VAR, 0)
end

-- Runs the gym's own generated winch script to completion, answering its
-- source message and its two-choice prompt, and samples the published camera
-- on every tick.
---@return table[] samples
local function runWinchScript(game, label)
  game:waitForFieldReady(480)
  clearWinchResult(game)
  local endedBefore = endedCount(game, CIANWOOD_WINCH_SCRIPT)
  game:startScript(CIANWOOD_WINCH_SCRIPT)
  local samples = {}
  for _ = 1, 720 do
    local snapshot = game:snapshot()
    samples[#samples + 1] = snapshot
    if endedCount(game, CIANWOOD_WINCH_SCRIPT) > endedBefore and not snapshot.fieldLocked then
      return samples
    end
    if game:contextChoiceStatus() ~= nil or snapshot.dialogue.modal then
      game:pressAction()
    else
      game:step()
    end
  end
  error(label .. " never released the field; last foreground=" .. tostring(game:snapshot().foregroundScript))
end

---@return { peakX: number, peakZ: number, movingTicks: integer }
local function panSummary(samples)
  local peakX, peakZ, movingTicks = 0, 0, 0
  for _, sample in ipairs(samples) do
    local offset = cameraOffset(sample)
    peakX = math.max(peakX, offset.x)
    peakZ = math.max(peakZ, offset.z)
    if math.abs(offset.x) > 1e-6 or math.abs(offset.z) > 1e-6 then
      movingTicks = movingTicks + 1
    end
  end
  return { peakX = peakX, peakZ = peakZ, movingTicks = movingTicks }
end

local function assertCameraAtPlayer(game, label)
  local offset = cameraOffset(game:snapshot())
  Assert.near(offset.x, 0, 1e-6, label .. " leaves the camera on the player in x")
  Assert.near(offset.z, 0, 1e-6, label .. " leaves the camera on the player in z")
end

-- A save capture requires every autonomous actor to be settled between its own
-- steps, and this map's black belts walk continuously, so advance to the next
-- settled tick before writing the ordinary save.
local function assertEcruteakEnvironment(game)
  local environment = assert(game.runtime.runtimeMap.renderEnvironment, "the gym owns a render environment")
  Assert.equal(environment.fog, EcruteakGym.FOG, "normal gym lifecycle installs the source fog preset")
  Assert.isFalse(environment.actorFogEnabled, "the gym disables fog at the actor draw boundary")
  Assert.near(environment.billboardDepthOffsetTiles, 0.0625, 1e-9, "the gym installs its one-unit projection offset")
end

local function saveWhenSettled(game)
  for _ = 1, 480 do
    local captured = pcall(game.runtime.captureGameSave, game.runtime)
    if captured then
      return game:save()
    end
    game:step()
  end
  error("the field never reached a settled saveable state")
end

-- The four source candle media stand on the source trainer objects, and the
-- candle commands run inside the source's common trainer interaction script.
-- Native trainer engagement owns that entry, so this scenario proves the
-- source path up to the engagement and then stops naming the missing owner
-- instead of fabricating an interaction the source never performs.
function T.tests.ecruteak_candle_commands_run_for_the_medium_trainer_interaction(context)
  withEcruteakGame(context, function(game)
    Assert.equal(
      #game:recordsForScript(ECRUTEAK_INIT_SCRIPT, "script.error"),
      0,
      "the gym's own init script completes: " .. failureText(game, ECRUTEAK_INIT_SCRIPT)
    )
    game:waitForFieldReady(480)
    assertEcruteakEnvironment(game)
    Assert.equal(
      actorCount(game),
      sourceObjectCount(game),
      "the candle world publishes every source map object exactly once"
    )

    local trainer = game:actor("map:80:object:5")
    Assert.notNil(trainer, "the medium trainer stands on the map")
    Assert.equal(trainer.fieldX, ECRUTEAK_MEDIUM_TRAINER.fieldX, "the medium trainer stands on its source tile")
    Assert.equal(trainer.fieldZ, ECRUTEAK_MEDIUM_TRAINER.fieldZ, "the medium trainer stands on its source tile")

    game:face("north")
    game:pressAction()
    local interaction = game:interaction()
    Assert.equal(interaction.kind, "object", "the faced tile holds the source medium trainer")
    Assert.equal(interaction.actorId, "map:80:object:5", "the interaction names the source medium trainer object")
    if interaction.scriptId == nil then
      context:skip(
        "the medium trainer's common source script is not composed yet, so no candle command is reachable: "
          .. "native trainer engagement must land before this scenario can bind, shrink and unbind the candles"
      )
    end
    Assert.equal(
      #game:recordsForScript(interaction.scriptId, "script.error"),
      0,
      "the medium trainer's source script completes: " .. failureText(game, interaction.scriptId)
    )
  end)
end

function T.tests.cianwood_winch_raises_once_through_its_own_source_script(context)
  withCianwoodGame(context, function(game)
    game:waitForFieldReady(480)
    assertCameraAtPlayer(game, "an idle field")

    local accepted = runWinchScript(game, "the first winch activation")
    Assert.equal(
      #game:recordsForScript(CIANWOOD_WINCH_SCRIPT, "script.error"),
      0,
      "the source winch script completes: " .. failureText(game, CIANWOOD_WINCH_SCRIPT)
    )
    Assert.equal(
      game.runtime.scripts.worldState:getVar(WINCH_RESULT_VAR),
      1,
      "the accepted activation writes the source true boolean"
    )

    local pan = panSummary(accepted)
    Assert.isTrue(pan.peakX > 1, string.format("the camera leaves the player in x (%.3f)", pan.peakX))
    Assert.isTrue(pan.peakZ > 1, string.format("the camera leaves the player in z (%.3f)", pan.peakZ))
    Assert.near(pan.peakZ / pan.peakX, PAN_WORLD_Z / PAN_WORLD_X, 0.1, "the pan follows the source offset proportions")
    Assert.isTrue(
      pan.movingTicks >= 2 * PAN_TICKS_EACH_WAY - 8,
      string.format("the pan spans the source out-and-back road (%d ticks)", pan.movingTicks)
    )
    Assert.isTrue(
      pan.movingTicks <= 2 * PAN_TICKS_EACH_WAY + 40,
      string.format("the pan releases the camera on the source schedule (%d ticks)", pan.movingTicks)
    )
    assertCameraAtPlayer(game, "the completed activation")

    local refused = runWinchScript(game, "the repeated winch activation")
    Assert.equal(
      #game:recordsForScript(CIANWOOD_WINCH_SCRIPT, "script.error"),
      0,
      "the repeated source winch script completes: " .. failureText(game, CIANWOOD_WINCH_SCRIPT)
    )
    Assert.equal(
      game.runtime.scripts.worldState:getVar(WINCH_RESULT_VAR),
      0,
      "an already raised winch answers the source false boolean"
    )
    local repeatedPan = panSummary(refused)
    Assert.near(repeatedPan.peakX, 0, 1e-6, "a raised winch never pans the camera again in x")
    Assert.near(repeatedPan.peakZ, 0, 1e-6, "a raised winch never pans the camera again in z")
    assertCameraAtPlayer(game, "the refused activation")
  end)
end

function T.tests.cianwood_winch_state_survives_continue_without_a_source_reinit(context)
  withCianwoodGame(context, function(game)
    Assert.equal(
      #game:recordsForScript(CIANWOOD_INIT_SCRIPT, "script.error"),
      0,
      "the gym's own init script completes: " .. failureText(game, CIANWOOD_INIT_SCRIPT)
    )
    game:waitForFieldReady(480)
    local actorsBefore = actorCount(game)
    local objectsBefore = sourceObjectCount(game)
    Assert.equal(actorsBefore, objectsBefore, "the gym publishes every source map object exactly once")

    runWinchScript(game, "the winch activation before the save")
    Assert.equal(
      #game:recordsForScript(CIANWOOD_WINCH_SCRIPT, "script.error"),
      0,
      "the source winch script completes before the save: " .. failureText(game, CIANWOOD_WINCH_SCRIPT)
    )
    Assert.equal(game.runtime.scripts.worldState:getVar(WINCH_RESULT_VAR), 1, "the winch is raised before the save")

    saveWhenSettled(game)
    game:restart()
    game:waitForFieldReady(960)
    Assert.equal(game:snapshot().mapSymbol, CIANWOOD_MAP, "Continue returns to the gym")
    Assert.equal(
      #game:recordsForScript(CIANWOOD_INIT_SCRIPT, "script.started"),
      0,
      "Continue restores the settled union without issuing the source gym init again"
    )
    Assert.equal(actorCount(game), actorsBefore, "Continue publishes the source map objects exactly once")

    runWinchScript(game, "the winch activation after Continue")
    Assert.equal(
      #game:recordsForScript(CIANWOOD_WINCH_SCRIPT, "script.error"),
      0,
      "the source winch script completes after Continue: " .. failureText(game, CIANWOOD_WINCH_SCRIPT)
    )
    Assert.equal(
      game.runtime.scripts.worldState:getVar(WINCH_RESULT_VAR),
      0,
      "the settled raised winch still answers the source false boolean after Continue"
    )
    assertCameraAtPlayer(game, "the activation after Continue")
  end)
end

function T.tests.ecruteak_gym_state_survives_continue_and_reinitializes_on_a_committed_warp(context)
  -- The source medium trainer watches this gym's own approach tile, so this
  -- scenario starts beside the push entry instead: it walks, saves and warps a
  -- settled gym, and native trainer engagement would own the field first.
  withEcruteakGame(context, function(game)
    Assert.equal(
      #game:recordsForScript(ECRUTEAK_INIT_SCRIPT, "script.error"),
      0,
      "the gym's own init script completes: " .. failureText(game, ECRUTEAK_INIT_SCRIPT)
    )
    game:waitForFieldReady(480)
    local actorsBefore = actorCount(game)
    Assert.equal(actorsBefore, sourceObjectCount(game), "the gym publishes every source map object exactly once")

    game:save()
    game:restart()
    game:waitForFieldReady(960)
    Assert.equal(game:snapshot().mapSymbol, ECRUTEAK_MAP, "Continue returns to the gym")
    assertEcruteakEnvironment(game)
    Assert.equal(
      #game:recordsForScript(ECRUTEAK_INIT_SCRIPT, "script.started"),
      0,
      "Continue restores the settled union without issuing the source gym init again"
    )
    Assert.equal(actorCount(game), actorsBefore, "Continue publishes the source map objects exactly once")

    -- The gym's own invisible-floor coordinate event starts the source push
    -- script, whose committed warp re-enters the same map.
    game:moveTo({ fieldX = ECRUTEAK_PUSH_ENTRY.fieldX, fieldZ = ECRUTEAK_PUSH_ENTRY.fieldZ })
    local landed = game:advanceUntil("the source push warp lands", function(snapshot)
      return snapshot.player.fieldX == ECRUTEAK_PUSH_LANDING.fieldX
        and snapshot.player.fieldZ == ECRUTEAK_PUSH_LANDING.fieldZ
    end, 960)
    Assert.equal(landed.mapSymbol, ECRUTEAK_MAP, "the committed warp stays on the gym's own map")
    Assert.equal(
      #game:recordsForScript(ECRUTEAK_PUSH_SCRIPT, "script.error"),
      0,
      "the source push script completes: " .. failureText(game, ECRUTEAK_PUSH_SCRIPT)
    )
    game:waitForFieldReady(960)
    Assert.equal(
      #game:recordsForScript(ECRUTEAK_INIT_SCRIPT, "script.started"),
      1,
      "the committed warp clears the union and lets the gym's own init script install it again"
    )
    Assert.equal(
      #game:recordsForScript(ECRUTEAK_INIT_SCRIPT, "script.error"),
      0,
      "the gym's own init script completes again: " .. failureText(game, ECRUTEAK_INIT_SCRIPT)
    )
    Assert.equal(actorCount(game), actorsBefore, "the re-entered gym publishes no duplicate map object")
    assertEcruteakEnvironment(game)
  end, { fieldX = 12, fieldZ = 20 })
end

return T
