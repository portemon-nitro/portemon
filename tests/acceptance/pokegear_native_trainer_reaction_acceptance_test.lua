-- Source-backed Route 37 twin reaction through the production field runtime.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local FieldMovement = require("tests.acceptance.support.FieldMovement")

local T = {
  metadata = {
    capabilities = { "rom_dump" },
    derivedAssets = {
      "field-runtime",
      "map:41",
      "map-data:41",
      "map:78",
      "map-data:78",
      "map:44",
      "map-data:44",
      "map:40",
      "map-data:40",
      "map:42",
      "map-data:42",
      "map:113",
      "map-data:113",
    },
    tags = { "field", "interaction" },
  },
  tests = {},
}

local ROUTE_37 = "MAP_ROUTE_37"
local REACTION_SCRIPT_ID = "vanilla.hgss.scr_seq.0953.script_080"
local FIRST_TWIN = { fieldX = 390, fieldZ = 211 }
local SECOND_TWIN = { fieldX = 391, fieldZ = 211 }

local acceptanceScripts = {
  [REACTION_SCRIPT_ID] = [[
local S = require("gen4.script")

return S.script {
  api = 1,
  id = "vanilla.hgss.scr_seq.0953.script_080",
  steps = {
    {
      op = "trainer_reaction_movement",
      actor = { ref = "actor", special = "last_talked" },
    },
    { op = "wait_movement" },
  },
}
]],
}

local function twinEvents(game)
  local events = assert(game.runtime.runtimeMap.fieldData.events.objects, "Route 37 exposes source object events")
  local found = {}
  for _, event in ipairs(events) do
    if
      (event.x == FIRST_TWIN.fieldX or event.x == SECOND_TWIN.fieldX)
      and event.z == FIRST_TWIN.fieldZ
    then
      found[event.x] = event
    end
  end
  local first = assert(found[FIRST_TWIN.fieldX], "Route 37 source declares the twin at (390,211)")
  local second = assert(found[SECOND_TWIN.fieldX], "Route 37 source declares the twin at (391,211)")
  Assert.equal(first.objectEventId == second.objectEventId, false, "the source twins have distinct object identities")
  return first, second
end

local function actorForEvent(game, event)
  local mapId = assert(game.runtime.runtimeMap.mapId, "Route 37 runtime has a map identity")
  return assert(
    game.runtime.actors:getActor("map:" .. mapId .. ":object:" .. event.objectEventId),
    "the source object has a manager actor"
  )
end

local function movementActors(game, instanceId, firstActorId, secondActorId)
  local actors = {}
  local tasks = {}
  for _, record in ipairs(game:recordsNamed("script.task_started")) do
    local payload = record.payload or {}
    if payload.instanceId == instanceId and payload.taskType == "movement" then
      local fields = {}
      for key, value in pairs(payload) do
        fields[#fields + 1] = key .. "=" .. tostring(value)
      end
      local task = assert(
        game.runtime.scripts.scheduler:taskById(payload.taskId),
        "started movement task remains observable (" .. table.concat(fields, ",") .. ")"
      )
      local actorId = task.state and task.state.actor
      if actorId == firstActorId or actorId == secondActorId then
        actors[#actors + 1] = actorId
        tasks[#tasks + 1] = task.state
      end
    end
  end
  return actors, tasks
end

function T.tests.route_37_native_twins_start_the_composed_reaction_in_partner_order()
  local game = AcceptanceHarness.new():boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = ROUTE_37,
    save = "fresh",
    fieldOptions = { acceptanceScripts = acceptanceScripts, recordingScriptHosts = true },
  })
  local ok, err = xpcall(function()
    game:waitForFieldEntry()
    Assert.equal(game.runtime.runtimeMap.mapId, 41, "the source Route 37 map is loaded")

    local firstEvent, secondEvent = twinEvents(game)
    local firstActor = actorForEvent(game, firstEvent)
    local secondActor = actorForEvent(game, secondEvent)
    local firstReaction = assert(firstActor.sourceEvent.trainerReaction, "the first source twin has normalized trainer metadata")
    local secondReaction = assert(secondActor.sourceEvent.trainerReaction, "the second source twin has normalized trainer metadata")
    Assert.equal(firstReaction.trainerId, 81, "the source twin pair uses trainer 81")
    Assert.equal(secondReaction.trainerId, 81, "the source twin pair uses trainer 81")
    Assert.isTrue(firstReaction.variant ~= secondReaction.variant, "the source twins have opposite variants")

    local primary, partner
    if firstReaction.variant == "first" then
      primary, partner = firstActor, secondActor
    else
      primary, partner = secondActor, firstActor
    end
    Assert.isTrue(primary:isResident(), "the primary source twin is resident at the cue")
    Assert.isTrue(partner:isResident(), "the paired source twin is resident at the cue")

    local primaryPosition = primary:getFieldPosition()
    local playerTarget = { fieldX = primaryPosition.fieldX, fieldZ = primaryPosition.fieldZ + 1 }
    Assert.notNil(FieldMovement.route(game, playerTarget), "the production field route reaches the twin's interaction tile")
    game:moveTo(playerTarget)
    game:face("north")
    game:pressAction()
    game:advanceUntil("the overridden source interaction starts both twin movement tasks", function()
      for _, record in ipairs(game:recordsNamed("script.started")) do
        local payload = record.payload or {}
        if
          payload.scriptId == REACTION_SCRIPT_ID
          and #movementActors(game, payload.instanceId, partner.actorId, primary.actorId) == 2
        then
          return true
        end
      end
      return false
    end, 120)

    local reactionInstanceId
    for _, record in ipairs(game:recordsNamed("script.started")) do
      local payload = record.payload or {}
      if payload.scriptId == REACTION_SCRIPT_ID then
        reactionInstanceId = payload.instanceId
      end
    end
    assert(reactionInstanceId ~= nil, "the source twin interaction starts the reaction script")
    local actorsInCueOrder, movementStates = movementActors(game, reactionInstanceId, partner.actorId, primary.actorId)
    Assert.deepEqual(
      actorsInCueOrder,
      { partner.actorId, primary.actorId },
      "the production scheduler starts partner movement before primary movement"
    )
    Assert.equal(#movementStates, 2, "the source interaction queues exactly two native twin movement tasks")
    local directionByFacing = { north = "west", south = "east", west = "north", east = "south" }
    local expectedDirection = assert(directionByFacing[primary.facing], "the primary source twin has a native facing")
    for _, state in ipairs(movementStates) do
      Assert.equal(state.sequence[1].action, "walk", "each twin receives the native walk cue")
      Assert.equal(
        state.sequence[1].direction,
        expectedDirection,
        "both twin tasks use the primary-facing-derived native cue direction"
      )
    end
    Assert.equal(#game:recordsNamed("script.error"), 0, "the production twin reaction has no script faults")
    Assert.equal(game:renderAttempts(), 0, "the source-backed reaction stops before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

return T
