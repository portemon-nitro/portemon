-- Source legendary-story scene lifetimes through the production field
-- composition. The Bell Tower 1F wing scene runs the map's own child script
-- while its wing effect is still looping (a blocking task that starved the
-- child would deadlock the scene), Lance's Lake of Rage departure waits for the
-- Fly effect before the scene hides him, and the field Pokémon picture window
-- keeps its picture while the orphaned dialogue runs, closes with its script and
-- is disposed when that script is cancelled. Only audio, fade and clock host
-- boundaries are recorded; maps, actors, scripts, the picture window and the
-- scene owners stay production-owned, and the render trap stays active.

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
      -- Bell Tower 1F, where the Kimono Girls' wing scene runs.
      "map:111",
      "map-data:111",
      "message-bank:57",
      -- The Lake of Rage shore where Lance and his Dragonite stand.
      "map:88",
      "map-data:88",
      "message-bank:626",
      "map:45",
      "map-data:45",
      "field-cell:0-14",
      "field-cell:0-15",
      "field-cell:0-16",
      "field-cell:0-17",
      "field-cell:0-18",
      "field-cell:0-61",
      "field-cell:0-62",
      "field-cell:0-63",
      "field-cell:0-64",
      "field-cell:0-65",
      "field-cell:0-108",
      "field-cell:0-109",
      "field-cell:0-110",
      "field-cell:0-111",
      "field-cell:0-112",
      "field-cell:0-155",
      "field-cell:0-156",
      "field-cell:0-157",
      "field-cell:0-158",
      "field-cell:0-159",
      "field-cell:0-202",
      "field-cell:0-203",
      "field-cell:0-204",
      "field-cell:0-205",
      "field-cell:0-206",
      -- Vermilion, whose map-init scene shows the version's Lati in the
      -- source picture window, with the neighbouring outdoor coverage.
      "map:54",
      "map-data:54",
      "map-data:14",
      "map-data:15",
      "map-data:16",
      "map-data:19",
      "map-data:21",
      "map-data:55",
      "map-data:59",
      "message-bank:483",
    },
    tags = { "field", "script", "legend" },
  },
  tests = {},
}

local BELL_TOWER = "MAP_BELL_TOWER_1F"
-- The map's own coordinate event covers (7,12)-(9,12) while VAR_UNK_40F3 still
-- reads its pre-scene value; the player walks onto it from the south.
local BELL_TOWER_APPROACH = { fieldX = 7, fieldZ = 13 }
-- The wing scene itself and the map script entry the wing effect starts while
-- its loop clip plays.
local WING_SCRIPT = "vanilla.hgss.scr_seq.0019.script_001"
local WING_CHILD_SCRIPT = "vanilla.hgss.scr_seq.0019.script_002"
-- The Kimono Girls' dance result: the scene only runs after their Bell Tower
-- story flag is set.
local WING_SCENE_FLAG = assert(FieldScriptSymbols.flagsByName.FLAG_UNK_093)
local WING_RESULT_VAR = assert(FieldScriptSymbols.variablesByName.VAR_UNK_40F3)

local LAKE_OF_RAGE = "MAP_LAKE_OF_RAGE"
-- The lake's own field coordinate origin; the source event tiles below are
-- global, so the fixture converts them into map-local spawn coordinates.
local LAKE_OF_RAGE_ORIGIN = { x = 512, z = 32 }
-- Lance stands on (528,83) and his Dragonite on (529,83); the player approaches
-- from the tile below Lance and talks to him.
local LANCE_TILE = { fieldX = 528, fieldZ = 83 }
local LANCE_APPROACH = { fieldX = 528, fieldZ = 84 }
local LANCE_SCRIPT = "vanilla.hgss.scr_seq.0938.script_003"
local LANCE_HIDDEN_FLAG = assert(FieldScriptSymbols.flagsByName.FLAG_HIDE_LAKE_OF_RAGE_LANCE)
local LANCE_DEPARTED_VAR = assert(FieldScriptSymbols.variablesByName.VAR_UNK_40A8)
local LANCE_ACTOR_IDS = { "map:88:object:8", "map:88:object:10" }
local LANCE_ALREADY_GONE_FLAG = assert(FieldScriptSymbols.flagsByName.FLAG_UNK_0C3)

local VERMILION = "MAP_VERMILION"
local VERMILION_SCRIPT = "vanilla.hgss.scr_seq.0776.script_013"
local STEVEN_SCENE_VAR = assert(FieldScriptSymbols.variablesByName.VAR_UNK_4130)
local STEVEN_SCENE_READY = 1
-- The map-scene script shows the version's own Lati in the picture window:
-- Latias (380) as female on HeartGold, Latios (381) as male on SoulSilver.
local LATI_PICTURE = {
  heartgold = { species = "LATIAS", gender = "female" },
  soulsilver = { species = "LATIOS", gender = "male" },
}

---@param mapSymbol string
---@param location { fieldX: integer, fieldZ: integer, facing: string? }
---@param worldState table?
---@param origin { x: integer, z: integer }?
---@return AcceptanceHarness
local function harnessFor(mapSymbol, location, worldState, origin)
  return AcceptanceHarness.new({
    gameFactory = function(versionId)
      local localX = location.fieldX - (origin and origin.x or 0)
      local localZ = location.fieldZ - (origin and origin.z or 0)
      return FinalizedGameFixture.build(versionId, {
        location = {
          mapSymbol = mapSymbol,
          fieldX = localX,
          fieldZ = localZ,
          facing = location.facing or "south",
        },
        worldState = worldState,
      })
    end,
  })
end

---@param game table acceptance game owning the production field runtime
---@param scriptId string canonical source script identity under test
---@return string[] faults the script published
local function faultsFor(game, scriptId)
  local faults = {}
  for _, record in ipairs(game:recordsForScript(scriptId, "script.error")) do
    local payload = record.payload or {}
    local context = payload.context or {}
    local where = ""
    for _, key in ipairs({ "localX", "localZ", "actorId", "fieldX", "fieldZ", "mapId" }) do
      if context[key] ~= nil then
        where = where .. " " .. key .. "=" .. tostring(context[key])
      end
    end
    faults[#faults + 1] = string.format(
      "%s/%s/%s%s",
      tostring(payload.code),
      tostring(context.command or context.originalName or "unknown"),
      tostring(payload.message),
      where
    )
  end
  return faults
end

---@param game table
---@param scriptId string
---@return table[] the script's completion records in emission order
local function endedRecords(game, scriptId)
  return game:recordsForScript(scriptId, "script.ended")
end

-- Drives the fixed tick, answering only source dialogue and contextual prompts,
-- until the caller's boundary is reached or an observed script faults. The
-- caller asserts the fault itself, so a faulting scene still ends the drive.
---@param game table
---@param scriptIds string[] scripts whose published faults end the drive
---@param label string boundary description
---@param done fun(snapshot: table): boolean
---@param maxTicks integer
local function driveScene(game, scriptIds, label, done, maxTicks)
  for _ = 1, maxTicks do
    if done(game:snapshot()) then
      return
    end
    for _, scriptId in ipairs(scriptIds) do
      if #game:recordsForScript(scriptId, "script.error") > 0 then
        return
      end
    end
    if game:contextChoiceStatus() ~= nil or game:snapshot().dialogue.modal then
      game:pressAction()
    else
      game:step()
    end
  end
  error(
    "the scene did not reach its boundary: "
      .. label
      .. "; foreground="
      .. tostring(game:snapshot().foregroundScript)
      .. ", modal="
      .. tostring(game:snapshot().dialogue.modal)
      .. ", tick="
      .. tostring(game:snapshot().tick),
    0
  )
end

---@param game table
---@param scriptId string
---@return string the instance id of the script's first start record
local function rootInstance(game, scriptId)
  local started = game:recordsForScript(scriptId, "script.started")
  Assert.equal(#started, 1, "the scene starts exactly one root instance")
  return assert(started[1].payload.instanceId, "a started script carries its instance id")
end

---@param game table
---@param actorId string
---@return boolean
local function actorVisible(game, actorId)
  for _, record in ipairs(game.runtime.actors:drawRecords()) do
    if record.actorId == actorId and record.visible then
      return true
    end
  end
  return false
end

-- ---------------------------------------------------------------------------
-- Bell Tower 1F: the wing effect starts the map's own script entry while its
-- looping clip is active, so the child scene must run to completion inside the
-- parent's block instead of being starved by it.
-- ---------------------------------------------------------------------------

function T.tests.bell_tower_wing_effect_runs_the_map_child_script_while_it_loops()
  local worldState = FieldEventState.new()
  worldState:setFlag(WING_SCENE_FLAG)
  local game = harnessFor(BELL_TOWER, BELL_TOWER_APPROACH, worldState):boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = BELL_TOWER,
    save = "fresh",
    fieldOptions = { recordingScriptHosts = true, audioHost = "recording" },
  })
  local ok, err = xpcall(function()
    game:waitForFieldEntry()
    Assert.equal(game:renderAttempts(), 0, "the scene acceptance stops before GPU rendering")
    game:face("north")
    game:move("north")
    game:advanceUntil("the wing scene starts", function()
      return #game:recordsForScript(WING_SCRIPT, "script.started") > 0
    end, 240)

    -- While the wing effect blocks the scene, the map's own second script entry
    -- runs and finishes before the scene itself can end.
    driveScene(game, { WING_SCRIPT }, "the wing scene closes", function()
      return #endedRecords(game, WING_SCRIPT) > 0
    end, 4000)

    local parentFaults = faultsFor(game, WING_SCRIPT)
    Assert.equal(
      #parentFaults,
      0,
      "the wing scene runs its own native operations: " .. table.concat(parentFaults, ",")
    )
    local childFaults = faultsFor(game, WING_CHILD_SCRIPT)
    Assert.equal(#childFaults, 0, "the wing child script runs its own steps: " .. table.concat(childFaults, ","))

    local childStarted = game:recordsForScript(WING_CHILD_SCRIPT, "script.started")
    Assert.equal(#childStarted, 1, "the wing effect starts the map's child script exactly once")
    local childEnded = endedRecords(game, WING_CHILD_SCRIPT)
    Assert.equal(#childEnded, 1, "the child script finishes exactly once")
    Assert.equal(childEnded[1].payload.completed, true, "the child script completes instead of faulting")

    -- The child must run inside the parent's block rather than after it.
    local parentEnded = endedRecords(game, WING_SCRIPT)
    Assert.equal(#parentEnded, 1, "the wing scene ends exactly once")
    Assert.equal(parentEnded[1].payload.completed, true, "the wing scene completes instead of faulting")
    local seenChildStart, seenChildEnd, seenParentEnd = false, false, false
    for _, record in ipairs(game:hostEvents().records) do
      local payload = record.payload or {}
      if record.name == "script.started" and payload.scriptId == WING_CHILD_SCRIPT then
        seenChildStart = true
      elseif record.name == "script.ended" and payload.scriptId == WING_CHILD_SCRIPT then
        seenChildEnd = true
      elseif record.name == "script.ended" and payload.scriptId == WING_SCRIPT then
        seenParentEnd = true
      end
      if seenParentEnd then
        break
      end
    end
    Assert.isTrue(seenChildStart, "the child script starts before the wing scene ends")
    Assert.isTrue(seenChildEnd, "the child script ends before the wing scene ends")
    Assert.equal(
      game.runtime.scripts.worldState:getVar(WING_RESULT_VAR),
      1,
      "the wing scene publishes its result only after the wing effect and its child finished"
    )
    Assert.equal(game:renderAttempts(), 0, "the scene acceptance stops before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

-- The same scene, cancelled while its wing effect is still looping: the field
-- keeps no in-flight ownership, publishes no result, and stays saveable.
function T.tests.cancelling_the_wing_effect_leaves_no_result_and_no_in_flight_claim()
  local worldState = FieldEventState.new()
  worldState:setFlag(WING_SCENE_FLAG)
  local game = harnessFor(BELL_TOWER, BELL_TOWER_APPROACH, worldState):boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = BELL_TOWER,
    save = "fresh",
    fieldOptions = { recordingScriptHosts = true, audioHost = "recording" },
  })
  local ok, err = xpcall(function()
    game:waitForFieldEntry()
    game:face("north")
    game:move("north")
    game:advanceUntil("the wing scene starts", function()
      return #game:recordsForScript(WING_SCRIPT, "script.started") > 0
    end, 240)
    -- The cancellation under test happens while the wing effect loops, which is
    -- only observable once its map child script has started.
    local childStarted = false
    for _ = 1, 600 do
      if #game:recordsForScript(WING_CHILD_SCRIPT, "script.started") > 0 then
        childStarted = true
        break
      end
      if #game:recordsForScript(WING_SCRIPT, "script.error") > 0 then
        break
      end
      if game:contextChoiceStatus() ~= nil or game:snapshot().dialogue.modal then
        game:pressAction()
      else
        game:step()
      end
    end
    local faults = faultsFor(game, WING_SCRIPT)
    Assert.isTrue(
      childStarted,
      "the wing effect starts its child script while its loop is active: " .. table.concat(faults, ",")
    )
    local cancelReason = "the wing scene is cancelled"
    game.runtime.scripts.scheduler:cancelInstance(rootInstance(game, WING_SCRIPT), cancelReason)
    local released = game:advanceUntil("the cancelled wing scene releases the field", function(snapshot)
      return not snapshot.fieldLocked
    end, 480)
    Assert.isFalse(released.fieldLocked, "the cancelled wing scene releases the field")
    Assert.equal(
      game.runtime.scripts.worldState:getVar(WING_RESULT_VAR),
      0,
      "a cancelled wing scene leaves the source result word at its pre-scene value"
    )
    local ended = endedRecords(game, WING_SCRIPT)
    Assert.equal(#ended, 1, "a cancelled wing scene ends exactly once")
    Assert.equal(ended[1].payload.completed, false, "a cancelled wing scene never reports completion")
    Assert.equal(ended[1].payload.reason, cancelReason, "the cancelled scene records its cancellation reason")
    Assert.equal(
      #game.runtime.scripts.scheduler:tasks(),
      0,
      "a cancelled wing scene leaves no effect task behind"
    )
    Assert.isNil(game:snapshot().foregroundScript, "a cancelled wing scene leaves no foreground owner")
    Assert.notNil(game.runtime:captureGameSave(), "a cancelled wing scene leaves the field saveable")
    Assert.equal(game:renderAttempts(), 0, "the scene acceptance stops before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

-- ---------------------------------------------------------------------------
-- Lake of Rage: Lance's own departure branch plays the Fly effect with him and
-- his Dragonite and only then hides both actors and finishes the scene.
-- ---------------------------------------------------------------------------

function T.tests.lance_departure_waits_for_the_fly_effect_before_hiding_both_actors()
  local worldState = FieldEventState.new()
  local game = harnessFor(
    LAKE_OF_RAGE,
    { fieldX = LANCE_APPROACH.fieldX, fieldZ = LANCE_APPROACH.fieldZ, facing = "north" },
    worldState,
    LAKE_OF_RAGE_ORIGIN
  ):boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = LAKE_OF_RAGE,
    save = "fresh",
    fieldOptions = { recordingScriptHosts = true, audioHost = "recording" },
  })
  local ok, err = xpcall(function()
    game:waitForFieldEntry()
    Assert.isFalse(
      game.runtime.scripts.worldState:isFlagSet(LANCE_ALREADY_GONE_FLAG),
      "the scene starts before Lance's own already-departed branch"
    )
    Assert.isTrue(actorVisible(game, LANCE_ACTOR_IDS[1]), "Lance stands on the lake shore before the scene")
    Assert.isTrue(actorVisible(game, LANCE_ACTOR_IDS[2]), "Lance's Dragonite stands beside him")
    Assert.equal(game:actor(LANCE_ACTOR_IDS[1]).fieldX, LANCE_TILE.fieldX, "Lance stands on his source tile")
    Assert.equal(game:actor(LANCE_ACTOR_IDS[1]).fieldZ, LANCE_TILE.fieldZ, "Lance stands on his source row")
    Assert.equal(game:actor(LANCE_ACTOR_IDS[2]).fieldX, LANCE_TILE.fieldX + 1, "the Dragonite stands beside him")

    game:pressAction()
    Assert.equal(
      game.lastInteraction and game.lastInteraction.scriptId,
      LANCE_SCRIPT,
      "talking to Lance starts his own departure script"
    )
    driveScene(game, { LANCE_SCRIPT }, "Lance's departure closes", function()
      return #endedRecords(game, LANCE_SCRIPT) > 0
    end, 4000)

    local faults = faultsFor(game, LANCE_SCRIPT)
    Assert.equal(#faults, 0, "the departure script runs its own native operations: " .. table.concat(faults, ","))
    local ended = endedRecords(game, LANCE_SCRIPT)
    Assert.equal(#ended, 1, "the departure script ends exactly once")
    Assert.equal(ended[1].payload.completed, true, "the departure script completes instead of faulting")
    local world = game.runtime.scripts.worldState
    Assert.isTrue(world:isFlagSet(LANCE_HIDDEN_FLAG), "the scene hides Lance after his Fly effect")
    Assert.equal(world:getVar(LANCE_DEPARTED_VAR), 1, "the scene publishes its own departure result")
    for _, actorId in ipairs(LANCE_ACTOR_IDS) do
      Assert.isFalse(actorVisible(game, actorId), "the scene removes the flown-away actor " .. actorId)
    end
    local released = game:waitForFieldReady(480)
    Assert.isFalse(released.fieldLocked, "the departure scene returns the field")
    Assert.notNil(game.runtime:captureGameSave(), "the departure scene leaves the field saveable")
    Assert.equal(game:renderAttempts(), 0, "the scene acceptance stops before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

-- ---------------------------------------------------------------------------
-- Vermilion: the map-init Steven scene opens the source picture window on the
-- version's Lati, the authored dialogue runs while that picture stays open, and
-- the scene's own close command takes it down. A cancelled scene must likewise
-- leave no picture behind.
-- ---------------------------------------------------------------------------

---@param versionId string
---@return table { game: table, picture: table }
local function bootStevenScene(versionId)
  local picture = assert(LATI_PICTURE[versionId], "the scenario names the version's Lati")
  local worldState = FieldEventState.new()
  worldState:setVar(STEVEN_SCENE_VAR, STEVEN_SCENE_READY)
  local game = harnessFor(VERMILION, { fieldX = 16, fieldZ = 30 }, worldState):boot({
    versionId = versionId,
    map = VERMILION,
    save = "fresh",
    fieldOptions = { recordingScriptHosts = true, audioHost = "recording" },
  })
  return { game = game, picture = picture }
end

function T.tests.picture_window_keeps_its_picture_across_the_scene_dialogue_and_closes_with_it()
  local versionId = AcceptanceHarness.defaultVersion()
  local booted = bootStevenScene(versionId)
  local game = booted.game
  local ok, err = xpcall(function()
    game:waitForFieldEntry()
    game:advanceUntil("the map-init picture scene starts", function()
      return #game:recordsForScript(VERMILION_SCRIPT, "script.started") > 0
    end, 480)
    driveScene(game, { VERMILION_SCRIPT }, "the source picture window opens", function()
      return game.runtime.monPicture:status() ~= nil
    end, 4000)
    local opened = game:snapshot()
    local status = game.runtime.monPicture:status()
    Assert.equal(status.species, booted.picture.species, "the window shows the version's own Lati")
    Assert.equal(status.gender, booted.picture.gender, "the window shows the source gender")
    Assert.notNil(status.pageId, "the open picture carries its generated portrait page")
    Assert.notNil(status.frame, "the open picture carries its source frame")
    Assert.isTrue(
      game.runtime.monService:hasSeenSpecies(booted.picture.species),
      "opening the window publishes the shown species as seen"
    )
    -- The authored dialogue between the show and the close runs with the picture
    -- still on screen.
    Assert.isTrue(opened.dialogue.modal or opened.fieldLocked, "the scene holds the field while the picture is open")

    driveScene(game, { VERMILION_SCRIPT }, "the picture scene closes its window", function(snapshot)
      return #endedRecords(game, VERMILION_SCRIPT) > 0 and not snapshot.fieldLocked
    end, 6000)

    local faults = faultsFor(game, VERMILION_SCRIPT)
    Assert.equal(#faults, 0, "the picture scene runs its own native operations: " .. table.concat(faults, ","))
    Assert.isNil(game.runtime.monPicture:status(), "the scene's own close command takes the picture down")
    Assert.equal(game:renderAttempts(), 0, "the scene acceptance stops before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

function T.tests.cancelling_the_picture_scene_disposes_its_window()
  local versionId = AcceptanceHarness.defaultVersion()
  local booted = bootStevenScene(versionId)
  local game = booted.game
  local ok, err = xpcall(function()
    game:waitForFieldEntry()
    driveScene(game, { VERMILION_SCRIPT }, "the source picture window opens", function()
      return game.runtime.monPicture:status() ~= nil
    end, 6000)
    game.runtime.scripts.scheduler:cancelInstance(rootInstance(game, VERMILION_SCRIPT), "the picture scene is cancelled")
    game:advanceUntil("the cancelled picture scene releases the field", function(snapshot)
      return not snapshot.fieldLocked
    end, 480)
    Assert.isNil(
      game.runtime.monPicture:status(),
      "a cancelled picture scene disposes the window it opened"
    )
    Assert.equal(
      #game.runtime.scripts.scheduler:tasks(),
      0,
      "a cancelled picture scene leaves no application task behind"
    )
    Assert.notNil(game.runtime:captureGameSave(), "a cancelled picture scene leaves the field saveable")
    Assert.equal(game:renderAttempts(), 0, "the scene acceptance stops before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

return T
