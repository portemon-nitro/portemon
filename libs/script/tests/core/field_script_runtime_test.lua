local Assert = require("tests.support.Assert")
local Runtime = require("libs.script.src.Runtime")

local T = {}

local function runState(services, written)
  return {
    instance = { scriptId = "test", mode = "foreground" },
    services = services,
    scheduler = {
      createTask = function(_, taskType, spec)
        return { type = taskType, spec = spec }
      end,
    },
    semantics = {
      evaluateValue = function(value)
        return value
      end,
      writeRef = function(ref, value)
        written[ref.id] = value
      end,
    },
  }
end

function T.lifecycle_nodes_block_and_current_map_query_is_same_tick()
  local written = {}
  local run = runState({ maps = {
    currentId = function()
      return 61
    end,
  } }, written)
  local outcome = Runtime.executeNode({ op = "current_map_id", result = { id = "VAR_MAP" } }, run)
  Assert.equal(outcome, Runtime.OUTCOME_CONTINUE)
  Assert.equal(written.VAR_MAP, 61)

  run.services.overworld = {}
  outcome = Runtime.executeNode({ op = "overworld_leave" }, run)
  Assert.equal(outcome, Runtime.OUTCOME_BLOCK)
  Assert.equal(run.blockTaskId.type, "overworld_lifecycle")
  Assert.equal(run.blockTaskId.spec.action, "leave")
end

function T.pokemon_center_heal_dispatches_a_blocking_task_without_healing_in_runtime()
  local written = {}
  local run = runState({}, written)
  run.semantics.evaluateValue = function(value)
    Assert.equal(value, "PARTY_COUNT")
    return 3
  end
  local outcome = Runtime.executeNode({ op = "pokemon_center_heal", count = "PARTY_COUNT" }, run)
  Assert.equal(outcome, Runtime.OUTCOME_BLOCK)
  Assert.equal(run.blockTaskId.type, "pokemon_center_heal")
  Assert.equal(run.blockTaskId.spec.count, 3)
end

function T.source_synchronous_player_time_and_discard_commands_keep_their_values()
  local written = {}
  local evaluated = {}
  local run = runState({
    player = {
      stateCode = function()
        return 2
      end,
    },
    timeOfDay = {
      currentCode = function()
        return 4
      end,
    },
  }, written)
  run.semantics.evaluateValue = function(value)
    evaluated[#evaluated + 1] = value
    return "read"
  end

  Assert.equal(
    Runtime.executeNode({ op = "player_state", result = { id = "PLAYER_STATE" } }, run),
    Runtime.OUTCOME_CONTINUE
  )
  Assert.equal(written.PLAYER_STATE, 2)
  Assert.equal(Runtime.executeNode({ op = "time_of_day", result = { id = "TIME" } }, run), Runtime.OUTCOME_CONTINUE)
  Assert.equal(written.TIME, 4)
  Assert.equal(Runtime.executeNode({ op = "discard_value", value = { id = "WATCHED" } }, run), Runtime.OUTCOME_CONTINUE)
  Assert.deepEqual(evaluated, { { id = "WATCHED" } })
end

function T.trainer_card_stars_writes_the_live_save_result()
  local written = {}
  local run = runState({
    trainerCardStars = {
      count = function()
        return 4
      end,
    },
  }, written)
  local outcome = Runtime.executeNode({ op = "trainer_card_stars", result = { id = "STARS" } }, run)
  Assert.equal(outcome, Runtime.OUTCOME_CONTINUE)
  Assert.equal(written.STARS, 4)
end

function T.nonblocking_message_evaluates_variable_bank_reference_before_host_dispatch()
  local resolved = nil
  local printed = nil
  local run = runState({
    dialogue = {
      openMessage = function() end,
      startPrint = function(_, message)
        printed = message
      end,
    },
  }, {})
  run.semantics.evaluateMessage = function(message)
    resolved = message
    return { message = "external", bank = 40, id = 83 }
  end
  local descriptor = { message = "external", bank = 40, id = { value = "var", id = "VAR_SPECIAL_x8004" } }
  Assert.equal(
    Runtime.executeNode({ op = "message", message = descriptor, waitForPrint = false }, run),
    Runtime.OUTCOME_CONTINUE
  )
  Assert.equal(resolved, descriptor)
  Assert.deepEqual(printed, { message = "external", bank = 40, id = 83 })
end

return { tests = T }
