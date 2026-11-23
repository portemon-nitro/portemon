-- Native trainer engagement owner: the source approach state machine, the
-- engagement-slot lifetime, and the trainer-script queries. Fakes stand in only
-- for the field host boundaries (actors, player, map); the catalog, the
-- trigger and the movement calibration are the real owners.

local Assert = require("tests.support.Assert")
local HgssTrainerCatalog = require("libs.hgss.src.battle.HgssTrainerCatalog")
local TrainerBattleTrigger = require("libs.hgss.src.battle.TrainerBattleTrigger")
local TrainerEncounterCoordinator = require("game.hgss.src.field.TrainerEncounterCoordinator")

local T = {}

local MOVEMENTS =
  { stationary = 0, look_north = 14, look_south = 15, look_west = 16, look_east = 17, vs_seeker_spin = 49 }

---@param overrides table<string, unknown>|nil
---@return HgssTrainerCatalog
local function catalog(overrides)
  local template = {
    trainerClass = 82,
    nameReference = { trainerIndex = 46 },
    party = { { species = "GASTLY", level = 10 } },
    aiPasses = {},
    doubleBattle = false,
    items = {},
    prizeMoney = { trainerClass = 82, classRate = 10 },
    messageSelectors = { intro = 0, lose = 1, after = 2 },
    loseSpeechSelector = "trainer-speech:" .. string.rep("a", 40),
    encounterMusic = { johto = "SEQ_GS_EYE_BOUZU", kanto = "SEQ_GS_EYE_J_MADAME" },
    fieldMessages = { [0] = 12, [2] = 40 },
  }
  for key, value in pairs(overrides or {}) do
    template[key] = value
  end
  return HgssTrainerCatalog.new({
    trainers = { [46] = template, [81] = template },
    nativeMovementByType = MOVEMENTS,
    fieldMessageBank = 728,
  })
end

---@param options table<string, unknown>|nil
---@return table fake actor manager and its recorded calls
local function fakeActors(options)
  local opts = options or {}
  local actors = {}
  local calls = {}
  local manager = {}
  manager.actorsOf = function(_, mapId)
    local list = {}
    for _, actor in pairs(actors) do
      if actor.mapId == mapId then
        list[#list + 1] = actor
      end
    end
    table.sort(list, function(a, b)
      return a.objectEventId < b.objectEventId
    end)
    return list
  end
  manager.getActor = function(_, actorId)
    return actors[actorId]
  end
  manager.getPosition = function(_, actorId)
    local actor = actors[actorId]
    if actor == nil then
      return nil
    end
    return { fieldX = actor.fieldX, fieldZ = actor.fieldZ }
  end
  manager.getFacing = function(_, actorId)
    local actor = actors[actorId]
    return actor ~= nil and actor.facing or nil
  end
  manager.setFacing = function(_, actorId, direction)
    local actor = actors[actorId]
    actor.facing = direction
    calls[#calls + 1] = { "setFacing", actorId, direction }
  end
  manager.setMovementType = function(_, actorId, movementType)
    local actor = actors[actorId]
    actor.movementType = movementType
    calls[#calls + 1] = { "setMovementType", actorId, movementType }
  end
  manager.isScriptedMoving = function(_, actorId)
    local actor = actors[actorId]
    return actor ~= nil and actor.scriptedAction ~= nil
  end
  manager.beginScriptedAction = function(_, actorId, action)
    local actor = actors[actorId]
    actor.scriptedAction = action
    actor.actionProgress = 0
    calls[#calls + 1] = { "begin", actorId, action.action }
  end
  manager.advanceScriptedAction = function(_, actorId, progress)
    actors[actorId].actionProgress = progress
  end
  manager.commitScriptedAction = function(_, actorId)
    local actor = actors[actorId]
    local action = actor.scriptedAction
    actor.scriptedAction = nil
    if action.action == "walk" then
      local deltas = { north = { 0, -1 }, south = { 0, 1 }, west = { -1, 0 }, east = { 1, 0 } }
      local delta = assert(deltas[action.direction])
      actor.fieldX = actor.fieldX + delta[1]
      actor.fieldZ = actor.fieldZ + delta[2]
    end
    calls[#calls + 1] = { "commit", actorId, action.action }
  end
  manager.cancelScriptedMovement = function(_, actorId)
    if actors[actorId] ~= nil then
      actors[actorId].scriptedAction = nil
    end
    calls[#calls + 1] = { "cancel", actorId }
  end
  manager.getCollisionAt = opts.getCollisionAt or function()
    return nil
  end
  local function add(actor)
    actors[actor.actorId] = actor
    return actor
  end
  return manager, actors, calls, add
end

---@param fieldX integer
---@param fieldZ integer
---@param facing string
---@return table player facade
local function fakePlayer(fieldX, fieldZ, facing)
  return {
    fieldX = fieldX,
    fieldZ = fieldZ,
    facing = facing,
    turned = nil,
    presentationState = function()
      return { locomotionActive = false }
    end,
    turn = function(self, direction)
      self.facing = direction
      self.turned = direction
    end,
  }
end

---@param trainer table<string, unknown>
---@return table source object event carrying a produced trainer subject
local function eventWithTrainer(trainer)
  return {
    objectEventId = 5,
    facingDirection = "south",
    movementType = "look_south",
    xRange = 0,
    yRange = 0,
    x = 10,
    z = 10,
    y = 0,
    trainer = trainer,
  }
end

---@param overrides table<string, unknown>|nil
---@return table harness state: coordinator, actors, calls, player, started scenes
local function harness(overrides)
  local opts = overrides or {}
  local actors, player, started = nil, nil, {}
  local created, add = nil, nil
  do
    local manager
    manager, actors, _, add = fakeActors(opts)
    created = manager
  end
  local actors2 = actors
  local subject = {
    trainerId = 46,
    partner = "first",
    sightType = 1,
    sightRange = 3,
    approachScript = "vanilla.hgss.scr_seq.0953.script_739",
  }
  local actor = {
    actorId = "map:80:object:5",
    mapId = 80,
    objectEventId = 5,
    fieldX = 11,
    fieldZ = 19,
    facing = "south",
    movementType = "look_south",
    sourceEvent = eventWithTrainer(subject),
  }
  actor.scriptedAction = nil
  actors2[actor.actorId] = actor
  add(actor)
  player = opts.player or fakePlayer(11, 21, "south")
  local state = {
    scriptActive = false,
    battleActive = false,
    fieldReady = true,
    doublesEligible = true,
    foreground = true,
  }
  local map = {
    mapId = 80,
    coordinateOrigin = { x = 0, z = 0 },
    collision = {
      getLocal = function(_, localX, localZ)
        return { blocked = opts.blockedAt ~= nil and opts.blockedAt(localX, localZ) == true }
      end,
    },
  }
  local coordinator = TrainerEncounterCoordinator.new({
    actors = created,
    catalog = function()
      return opts.catalog or catalog()
    end,
    playerOf = function()
      return player
    end,
    currentMap = function()
      return map
    end,
    world = function()
      return {
        isFlagSet = function(_, id)
          return opts.defeated == true and id == 0x550 + subject.trainerId
        end,
      }
    end,
    startScene = function(scriptId)
      started[#started + 1] = scriptId
      state.scriptActive = state.foreground
      return state.foreground
    end,
    scriptActive = function()
      return state.scriptActive
    end,
    battleActive = function()
      return state.battleActive
    end,
    doublesEligible = function()
      return state.doublesEligible
    end,
    fieldReady = function()
      return state.fieldReady
    end,
    region = function()
      return opts.region or "johto"
    end,
  })
  return {
    coordinator = coordinator,
    actor = actor,
    add = add,
    player = player,
    state = state,
    started = started,
    catalog = opts.catalog or catalog(),
  }
end

function T.sight_starts_the_source_approach_scene_and_holds_the_engaged_actor()
  local h = harness()
  Assert.isTrue(h.coordinator:tryEngage(), "the source sight starts the engagement")
  Assert.deepEqual(h.started, { "vanilla.hgss.scr_seq.0953.script_739" })
  Assert.equal(h.coordinator:engagedActor(), "map:80:object:5", "slot 0 names the engaged actor")
  Assert.equal(h.coordinator:encounterType(), TrainerBattleTrigger.ENCOUNTER_SINGLE)
  Assert.equal(h.coordinator:engagementTrainer(0), 46)
end

function T.no_engagement_while_a_script_owns_the_field_or_the_field_is_not_ready()
  local busy = harness()
  busy.state.scriptActive = true
  Assert.isFalse(busy.coordinator:tryEngage(), "a foreground script keeps the field")

  local notReady = harness()
  notReady.state.fieldReady = false
  Assert.isFalse(notReady.coordinator:tryEngage(), "map entry and transitions precede the sight check")

  local defeated = harness({ defeated = true })
  Assert.isFalse(defeated.coordinator:tryEngage(), "a defeated trainer never re-engages")
end

-- The source sight stops at the first blocked tile between the two: an
-- obstruction on the ray is what keeps the trainer from noticing the player,
-- never mere tile proximity.
function T.a_blocked_intermediate_tile_stops_the_sight()
  local blocked = harness({
    blockedAt = function(localX, localZ)
      return localX == 11 and localZ == 20
    end,
  })
  Assert.isFalse(blocked.coordinator:tryEngage(), "an obstructed ray never engages")
  Assert.deepEqual(blocked.started, {})

  local clear = harness()
  Assert.isTrue(clear.coordinator:tryEngage(), "an open ray engages")
end

-- The source approach walks the trainer to one tile from the player: the sight
-- distance minus one steps, then the trainer faces the player and returns to
-- its stationary movement type. The script's poll answers 0 while the approach
-- runs and 1 once it finished.
function T.approach_walks_the_distance_minus_one_and_reports_its_source_progress()
  local h = harness()
  Assert.isTrue(h.coordinator:tryEngage())
  h.coordinator:startApproach(0)
  Assert.equal(h.coordinator:stepApproach(0), 0, "a live approach answers the source false")
  for _ = 1, 400 do
    h.coordinator:updateFixed()
    if h.coordinator:stepApproach(0) == 1 then
      break
    end
  end
  Assert.equal(h.actor.fieldZ, 20, "the trainer walks one tile toward the player")
  Assert.equal(h.actor.facing, "south", "the arrived trainer faces the player")
  Assert.equal(h.player.facing, "north", "the player turns toward the arrived trainer")
  Assert.equal(h.actor.movementType, "stationary", "the approach resets the trainer's movement")
  Assert.equal(h.coordinator:stepApproach(0), 1, "a completed approach keeps answering the source true")
end

-- The whole engagement ends with its script environment; a cancelled scene
-- clears both the slots and any motion they own.
function T.engagement_clears_when_its_script_environment_ends()
  local h = harness()
  Assert.isTrue(h.coordinator:tryEngage())
  h.state.scriptActive = false
  h.coordinator:updateFixed()
  Assert.isNil(h.coordinator:engagedActor(), "an ended scene drops its engagement")

  local cancelled = harness()
  Assert.isTrue(cancelled.coordinator:tryEngage())
  cancelled.coordinator:startApproach(0)
  cancelled.coordinator:dispose()
  Assert.isNil(cancelled.coordinator:engagedActor(), "disposing clears the engagement")
  Assert.isNil(cancelled.actor.scriptedAction, "disposing cancels the approach motion")
end

-- ScrCmd_GetObjectMovementType reads the actor's *current* movement type: a
-- source movement change is what the script observes, never the initial event
-- movement.
function T.movement_selector_follows_a_source_movement_change()
  local h = harness()
  Assert.equal(h.coordinator:movementSelector("map:80:object:5"), 15, "the authored look-south selector")
  h.actor.movementType = "look_east"
  Assert.equal(h.coordinator:movementSelector("map:80:object:5"), 17, "a changed movement answers its new selector")
end

-- ScrCmd_SetLastTalkedTrainerMovement rewrites the talked-to trainer's movement
-- from its facing with the source selectors, and the pair partner's with it.
function T.last_talked_movement_rewrites_the_trainer_and_its_pair_partner()
  local h = harness()
  local partner = h.add({
    actorId = "map:80:object:6",
    mapId = 80,
    objectEventId = 6,
    fieldX = 12,
    fieldZ = 19,
    facing = "south",
    movementType = "look_south",
    scriptedAction = nil,
    sourceEvent = eventWithTrainer({
      trainerId = 46,
      partner = "second",
      sightType = 1,
      sightRange = 3,
      approachScript = "vanilla.hgss.scr_seq.0953.script_739",
    }),
  })
  h.actor.facing = "east"
  h.coordinator:lastTalkedMovement({ selfActor = h.actor.actorId })
  Assert.equal(partner.movementType, "look_east", "the pair partner follows the talked-to trainer's facing")
  Assert.equal(h.actor.movementType, "look_east", "an east-facing trainer gets the native selector 17")
  Assert.equal(
    h.coordinator:movementSelector(h.actor.actorId),
    17,
    "the source movement read answers the movement the talk command just wrote"
  )
end

-- The source message kinds: single intro/after/short-intro, then the double
-- pair's two slot variants, and the phone-rematch kinds.
function T.message_parameters_answer_the_source_kinds_per_trainer_shape()
  local single = harness()
  local params = single.coordinator:messageParams({ selfActor = "map:80:object:5" }, false)
  Assert.deepEqual(params, { intro = 0, after = 2, shortIntro = 0 })

  local rematch = single.coordinator:messageParams({ selfActor = "map:80:object:5" }, true)
  Assert.deepEqual(rematch, { intro = 17, after = 0, shortIntro = 0 })

  local doubleCatalog = catalog({ doubleBattle = true })
  local pairHarness = harness({ catalog = doubleCatalog })
  local first = pairHarness.coordinator:messageParams({ selfActor = "map:80:object:5" }, false)
  Assert.deepEqual(first, { intro = 3, after = 5, shortIntro = 6 }, "the double pair's first slot")

  pairHarness.actor.sourceEvent.trainer.partner = "second"
  local second = pairHarness.coordinator:messageParams({ selfActor = "map:80:object:5" }, false)
  Assert.deepEqual(second, { intro = 7, after = 9, shortIntro = 10 }, "the double pair's second slot")
  Assert.isTrue(pairHarness.coordinator:isDoubleTrainer({ selfActor = "map:80:object:5" }))
end

-- The field speech location and the eyes-meet sequence come from the catalog
-- for the map's own native region.
function T.field_message_and_encounter_music_read_the_catalog()
  local johto = harness()
  Assert.deepEqual(johto.coordinator:fieldMessage(46, 0), { bank = 728, id = 12 })
  Assert.isNil(johto.coordinator:fieldMessage(46, 7), "an absent pair answers no message")
  Assert.equal(johto.coordinator:encounterMusic(46), "SEQ_GS_EYE_BOUZU")

  local kanto = harness({ region = "kanto" })
  Assert.equal(kanto.coordinator:encounterMusic(46), "SEQ_GS_EYE_J_MADAME")
end

function T.the_running_script_context_answers_its_trainer_number_and_double_mark()
  local h = harness()
  Assert.equal(h.coordinator:activeTrainerNumber({ selfActor = "map:80:object:5" }), 46)
  Assert.isFalse(h.coordinator:isDoubleTrainer({ selfActor = "map:80:object:5" }))
end

return { tests = T }
