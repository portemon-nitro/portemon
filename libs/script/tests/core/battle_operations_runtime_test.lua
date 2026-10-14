-- Script runtime coverage for battle launch and result: the launch node
-- resolves its details and blocks on the battle task, while the result
-- node answers from the injected host's latest committed outcome. A
-- missing host is an attributed fault; an unrecorded battle reads back
-- not-won instead of a guessed victory.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local Runtime = require("libs.script.src.Runtime")
local RuntimeValues = require("libs.hgss.src.script.RuntimeValues")

local T = {}

local function runWith(services)
  local created = {}
  return {
    run = {
      instance = { scriptId = "test.battle", mode = "foreground", locals = {}, textArgs = {} },
      node = { nodeId = "n1" },
      tick = 1,
      input = {},
      services = services,
      semantics = RuntimeValues,
      scheduler = {
        createTask = function(_, taskType, spec, _, _, _)
          created[#created + 1] = { taskType = taskType, spec = spec }
          return #created
        end,
      },
    },
    created = created,
  }
end

local function worldWith(vars)
  return {
    vars = vars or {},
    getVar = function(self, id)
      return self.vars[id]
    end,
    setVar = function(self, id, value)
      self.vars[id] = value
    end,
  }
end

local function var(id)
  return { value = "var", id = id }
end

function T.launch_blocks_on_the_battle_task_with_resolved_details()
  local world = worldWith({ [7] = 25 })
  local fixture = runWith({ world = world, battle = {} })
  local outcome = Runtime.executeNode({
    op = "battle_launch",
    kind = "trainer",
    details = { trainer = var(7), args = { 1 } },
    result = var(9),
  }, fixture.run)
  Assert.equal(outcome, Runtime.OUTCOME_BLOCK)
  Assert.equal(#fixture.created, 1)
  Assert.equal(fixture.created[1].taskType, "battle")
  Assert.equal(fixture.created[1].spec.kind, "trainer")
  Assert.equal(fixture.created[1].spec.details.trainer, 25, "variable references evaluate before the host")
  Assert.equal(fixture.created[1].spec.details.args[1], 1, "plain data rides through untouched")
end

function T.launch_without_a_host_is_an_attributed_fault()
  local fixture = runWith({ world = worldWith({}) })
  local err = Assert.throws(function()
    Runtime.executeNode({ op = "battle_launch", kind = "wild", details = {} }, fixture.run)
  end)
  Assert.isTrue(Errors.is(err))
  Assert.equal(err.code, "SCRIPT_SERVICE_MISSING")
end

function T.result_reads_the_host_latest_outcome()
  local host = { lastBattleResult = function()
    return { result = "win", sourceResult = 1 }
  end }
  local world = worldWith({})
  local fixture = runWith({ world = world, battle = host })
  local outcome = Runtime.executeNode({ op = "battle_result", result = var(3) }, fixture.run)
  Assert.equal(outcome, Runtime.OUTCOME_CONTINUE)
  Assert.equal(world.vars[3], 1, "a won battle reads back won")
end

function T.result_maps_contexts_and_unrecorded_battles_conservatively()
  local world = worldWith({})
  local host = { lastBattleResult = function()
    return { result = "draw", sourceResult = 0 }
  end }
  local fixture = runWith({ world = world, battle = host })
  Runtime.executeNode({ op = "battle_result", result = var(3) }, fixture.run)
  Assert.equal(world.vars[3], 0, "a drawn battle never reads back won")
  Runtime.executeNode({ op = "battle_result", result = var(4), context = "static_wild_won_or_caught" }, fixture.run)
  Assert.equal(world.vars[4], 0)

  local caughtHost = { lastBattleResult = function()
    return { result = "capture", sourceResult = 1 }
  end }
  local caughtFixture = runWith({ world = world, battle = caughtHost })
  Runtime.executeNode(
    { op = "battle_result", result = var(5), context = "static_wild_won_or_caught" },
    caughtFixture.run
  )
  Assert.equal(world.vars[5], 1, "the static context counts captures")

  local emptyHost = { lastBattleResult = function()
    return nil
  end }
  local emptyFixture = runWith({ world = world, battle = emptyHost })
  Runtime.executeNode({ op = "battle_result", result = var(6) }, emptyFixture.run)
  Assert.equal(world.vars[6], 0, "an unrecorded battle reads back not-won")
end

function T.result_without_a_host_is_an_attributed_fault()
  local fixture = runWith({ world = worldWith({}) })
  local err = Assert.throws(function()
    Runtime.executeNode({ op = "battle_result", result = var(3) }, fixture.run)
  end)
  Assert.isTrue(Errors.is(err))
  Assert.equal(err.code, "SCRIPT_SERVICE_MISSING")
end

function T.trainer_message_parameters_follow_single_and_double_source_selectors()
  local world = worldWith({})
  local catalog = require("libs.hgss.src.battle.HgssTrainerCatalog").new({ trainers = {
    [8] = { trainerClass = 2, nameReference = {}, party = {}, doubleBattle = false, messageIds = {} },
    [9] = { trainerClass = 3, nameReference = {}, party = {}, doubleBattle = true, messageIds = {} },
  } })
  local fixture = runWith({ world = world, trainerCatalog = catalog })
  local value = function(trainer, partner, selector)
    return RuntimeValues.evaluateValue({
      value = "trainer_message_param",
      trainer = trainer,
      partner = partner,
      selector = selector,
    }, fixture.run)
  end
  Assert.deepEqual({ value(8, false, 1), value(8, false, 2), value(8, false, 3) }, { 0, 2, 0 })
  Assert.deepEqual({ value(9, false, 1), value(9, false, 2), value(9, false, 3) }, { 3, 5, 6 })
  Assert.deepEqual({ value(9, true, 1), value(9, true, 2), value(9, true, 3) }, { 7, 9, 10 })
end

function T.phone_rematch_message_parameters_follow_native_single_and_double_selectors()
  local world = worldWith({})
  local catalog = require("libs.hgss.src.battle.HgssTrainerCatalog").new({ trainers = {
    [8] = { trainerClass = 2, nameReference = {}, party = {}, doubleBattle = false, messageIds = {} },
    [9] = { trainerClass = 3, nameReference = {}, party = {}, doubleBattle = true, messageIds = {} },
  } })
  local fixture = runWith({ world = world, trainerCatalog = catalog })
  local value = function(trainer, partner, selector)
    return RuntimeValues.evaluateValue({
      value = "trainer_rematch_message_param",
      trainer = trainer,
      partner = partner,
      selector = selector,
    }, fixture.run)
  end
  Assert.deepEqual({ value(8, false, 1), value(8, false, 2), value(8, false, 3) }, { 17, 0, 0 })
  Assert.deepEqual({ value(9, false, 1), value(9, false, 2), value(9, false, 3) }, { 18, 0, 6 })
  Assert.deepEqual({ value(9, true, 1), value(9, true, 2), value(9, true, 3) }, { 19, 0, 10 })
end

function T.trainer_reaction_uses_the_native_facing_movement_through_the_field_task()
  local expected = {
    north = { action = "walk", direction = "west", speed = "normal" },
    south = { action = "walk", direction = "east", speed = "normal" },
    west = { action = "walk", direction = "north", speed = "fast" },
    east = { action = "walk", direction = "south", speed = "fast" },
  }
  for facing, action in pairs(expected) do
    local fixture = runWith({
      actors = { snapshot = function(_, actorId)
        Assert.equal(actorId, "joey")
        return { facing = facing }
      end, exists = function(_, actorId) return actorId == "joey" end },
    })
    fixture.run.instance.trigger = { selfActor = "joey" }
    Assert.equal(
      Runtime.executeNode({
        op = "trainer_reaction_movement",
        actor = { ref = "actor", special = "last_talked" },
      }, fixture.run),
      Runtime.OUTCOME_CONTINUE
    )
    Assert.equal(fixture.created[1].taskType, "movement")
    Assert.deepEqual(fixture.created[1].spec.sequence, { action })
    Assert.isFalse(fixture.created[1].spec.blocking, "the native cue queues movement without blocking")
  end
end

function T.trainer_flag_write_resolves_native_or_variable_identity_through_world_state()
  local defeated = {}
  local world = worldWith({ [7] = 8 })
  world.setTrainerDefeated = function(_, trainerId)
    defeated[#defeated + 1] = trainerId
  end
  local fixture = runWith({ world = world })
  Runtime.executeNode({ op = "set_trainer_flag", trainer = var(7) }, fixture.run)
  Runtime.executeNode({ op = "set_trainer_flag", trainer = 9 }, fixture.run)
  Assert.deepEqual(defeated, { 8, 9 }, "variable selectors dereference before the HGSS history owner")
end

return { tests = T }
