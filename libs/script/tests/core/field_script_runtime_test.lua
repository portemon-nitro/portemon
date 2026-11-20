local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local Runtime = require("libs.script.src.Runtime")
local RuntimeValues = require("libs.hgss.src.script.RuntimeValues")
local S = require("gen4.script")
local ScriptErrors = require("libs.script.src.errors")

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
      weekday = function()
        return 3
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
  Assert.equal(Runtime.executeNode({ op = "weekday", result = { id = "DAY" } }, run), Runtime.OUTCOME_CONTINUE)
  Assert.equal(written.DAY, 3)
  Assert.equal(Runtime.executeNode({ op = "discard_value", value = { id = "WATCHED" } }, run), Runtime.OUTCOME_CONTINUE)
  Assert.deepEqual(evaluated, { { id = "WATCHED" } })
end

function T.camera_focus_ops_pin_and_release_through_the_actor_world()
  local focused = {}
  local run = runState({
    actors = {
      createCameraTarget = function(_, fieldX, fieldZ)
        focused = { fieldX = fieldX, fieldZ = fieldZ }
      end,
      clearCameraTarget = function()
        focused = {}
      end,
    },
  }, {})
  run.semantics.evaluateValue = function(value)
    return value
  end

  Assert.equal(
    Runtime.executeNode({ op = "camera_focus_set", fieldX = 12, fieldZ = 34 }, run),
    Runtime.OUTCOME_CONTINUE
  )
  Assert.deepEqual(focused, { fieldX = 12, fieldZ = 34 }, "the set pins the evaluated tile")
  Assert.equal(Runtime.executeNode({ op = "camera_focus_clear" }, run), Runtime.OUTCOME_CONTINUE)
  Assert.deepEqual(focused, {}, "the clear releases the focus")
end

function T.player_on_bike_check_reports_the_cycling_state()
  local written = {}
  local stateCode = 1
  local run = runState({
    player = {
      stateCode = function()
        return stateCode
      end,
    },
  }, written)

  Assert.equal(
    Runtime.executeNode({ op = "player_on_bike_check", result = { id = "ON_BIKE" } }, run),
    Runtime.OUTCOME_CONTINUE
  )
  Assert.equal(written.ON_BIKE, 1, "the cycling avatar reads as on the bike")

  stateCode = 0
  Assert.equal(
    Runtime.executeNode({ op = "player_on_bike_check", result = { id = "ON_BIKE" } }, run),
    Runtime.OUTCOME_CONTINUE
  )
  Assert.equal(written.ON_BIKE, 0, "the walking avatar reads as off the bike")
end

function T.celebi_time_travel_blocks_on_its_cutscene_task()
  local written = {}
  local run = runState({}, written)
  local outcome = Runtime.executeNode({ op = "celebi_time_travel" }, run)
  Assert.equal(outcome, Runtime.OUTCOME_BLOCK)
  Assert.equal(run.blockTaskId.type, "celebi_time_travel")
end

function T.lugia_reveal_ops_route_through_the_legend_cutscene()
  local written = {}
  local commands = {}
  local run = runState({
    legendCutscene = {
      command = function(_, op, destination)
        commands[#commands + 1] = { op = op, destination = destination }
      end,
      taskTicks = function(_, op)
        Assert.equal(op, "legend_cutscene_lugia_eye_glimmer")
        return 61
      end,
    },
  }, written)
  local outcome = Runtime.executeNode({ op = "legend_cutscene_lugia_eye_glimmer" }, run)
  Assert.equal(outcome, Runtime.OUTCOME_BLOCK)
  Assert.equal(run.blockTaskId.type, "wait_ticks")
  Assert.equal(run.blockTaskId.spec.ticks, 61)
  Assert.equal(commands[1].op, "legend_cutscene_lugia_eye_glimmer")
  Assert.equal(Runtime.executeNode({ op = "legend_cutscene_lugia_arrives_begin" }, run), Runtime.OUTCOME_CONTINUE)
  Assert.equal(commands[2].op, "legend_cutscene_lugia_arrives_begin")
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

function T.field_clock_hour_reads_the_injected_clock_same_tick()
  local written = {}
  local hour = 23
  local run = runState({
    clock = {
      nowLocal = function()
        return { year = 2000, month = 1, day = 1, hour = hour, minute = 5 }
      end,
    },
  }, written)

  Assert.equal(
    Runtime.executeNode({ op = "field_clock_hour", result = { value = "var", id = "VAR_TEMP_x4001" } }, run),
    Runtime.OUTCOME_CONTINUE
  )
  Assert.equal(written.VAR_TEMP_x4001, 23, "the late hour answers the injected local clock")

  hour = 0
  Assert.equal(
    Runtime.executeNode({ op = "field_clock_hour", result = { value = "var", id = "VAR_TEMP_x4001" } }, run),
    Runtime.OUTCOME_CONTINUE
  )
  Assert.equal(written.VAR_TEMP_x4001, 0, "the hour wraps to midnight through the same clock")
end

function T.dynamic_warp_operations_delegate_to_the_maps_service_same_tick()
  local written = {}
  local values = { DYNAMIC_MAP = 60, WARP = 2, X = 10, Z = 20, DIRECTION = 4 }
  local calls = {}
  local run = runState({
    maps = {
      setDynamicWarp = function(_, warp)
        calls[#calls + 1] = { op = "set", warp = warp }
      end,
      dynamicWarpFloor = function()
        return 3
      end,
      moveWarpEvent = function(_, warpId, x, z)
        calls[#calls + 1] = { op = "move", warpId = warpId, fieldX = x, fieldZ = z }
      end,
    },
  }, written)
  run.semantics.evaluateValue = function(value)
    if type(value) == "table" then
      return values[value.id]
    end
    return value
  end

  Assert.equal(
    Runtime.executeNode({
      op = "set_dynamic_warp",
      map = { id = "DYNAMIC_MAP" },
      warpId = { id = "WARP" },
      fieldX = { id = "X" },
      fieldZ = { id = "Z" },
      direction = { id = "DIRECTION" },
    }, run),
    Runtime.OUTCOME_CONTINUE
  )
  Assert.deepEqual(calls[1].warp, { map = 60, warpId = 2, fieldX = 10, fieldZ = 20, direction = 4 })

  Assert.equal(
    Runtime.executeNode({ op = "get_dynamic_warp_floor", result = { value = "var", id = "FLOOR" } }, run),
    Runtime.OUTCOME_CONTINUE
  )
  Assert.equal(written.FLOOR, 3, "the floor query writes the maps-service answer")

  Assert.equal(
    Runtime.executeNode({
      op = "move_warp_event",
      warpId = { id = "WARP" },
      fieldX = { id = "X" },
      fieldZ = { id = "Z" },
    }, run),
    Runtime.OUTCOME_CONTINUE
  )
  Assert.deepEqual(calls[2], { op = "move", warpId = 2, fieldX = 10, fieldZ = 20 })
end

function T.elevator_animation_blocks_on_its_registered_task()
  local run = runState({ propAnimations = {} }, {})
  run.semantics.evaluateValue = function(value)
    if type(value) == "table" and value.id == "DIRECTION" then
      return 0
    elseif type(value) == "table" and value.id == "LENGTH" then
      return 6
    end
    return value
  end
  local outcome = Runtime.executeNode({
    op = "elevator_anim",
    direction = { id = "DIRECTION" },
    length = { id = "LENGTH" },
  }, run)
  Assert.equal(outcome, Runtime.OUTCOME_BLOCK, "the elevator animation owns the script's frames")
  Assert.equal(run.blockTaskId.type, "elevator_anim")
  Assert.equal(run.blockTaskId.spec.direction, 0)
  Assert.equal(run.blockTaskId.spec.length, 6, "the source length reaches the task evaluated")
end

-- The floor window command only shows a window: the source lifetime is the
-- result variable, which the script (not the command) sets to its sentinel.
function T.floor_window_show_is_same_tick_and_never_writes_its_result_variable()
  local written = {}
  local shown = {}
  local run = runState(
    { floorWindow = {
      show = function(_, request)
        shown[#shown + 1] = request
      end,
    } },
    written
  )
  run.semantics.evaluateValue = function(value)
    if type(value) == "table" then
      return 2
    end
    return value
  end

  Assert.equal(
    Runtime.executeNode({
      op = "floor_window_show",
      tileX = 5,
      tileY = 6,
      floor = { id = "FLOOR" },
      result = { value = "var", id = "VAR_RESULT" },
    }, run),
    Runtime.OUTCOME_CONTINUE,
    "showing the floor window returns in the same tick"
  )
  Assert.equal(#shown, 1)
  Assert.equal(shown[1].tileX, 5)
  Assert.equal(shown[1].tileY, 6)
  Assert.equal(shown[1].floor, 2, "the evaluated floor reaches the window host")
  Assert.equal(shown[1].result.id, "VAR_RESULT", "the window host observes the source result variable")
  Assert.isNil(written.VAR_RESULT, "the command never writes the closing sentinel itself")
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

-- A source money command operates the one live wallet through the injected
-- `money` facade: every amount is evaluated before the facade sees it, a money
-- check writes its boolean instead of moving the wallet, and the money box
-- operations reach the field window in source order. All three return in the
-- same tick.
local function moneyRun(wallet, vars)
  local values = vars or { VAR_TEMP_x4001 = 40, VAR_TEMP_x4002 = 3, VAR_TEMP_x4003 = 5 }
  local run = {
    instance = { scriptId = "test.money", locals = {}, textArgs = {} },
    services = {
      world = {
        getVar = function(_, id)
          return values[id]
        end,
        setVar = function(_, id, value)
          values[id] = value
        end,
        isFlagSet = function(_, id)
          return values[id] == true
        end,
      },
      money = wallet,
    },
    semantics = RuntimeValues,
  }
  return run, values
end

-- One recording source wallet: the capability set the runtime may call, with
-- the source arithmetic the facade owns kept out of the runtime.
local function recordingWallet(money)
  local wallet = { money = money, calls = {} }
  function wallet:add(amount)
    self.calls[#self.calls + 1] = { "add", amount }
    self.money = math.min(999999, self.money + amount)
  end
  function wallet:subtract(amount)
    self.calls[#self.calls + 1] = { "subtract", amount }
    self.money = math.max(0, self.money - amount)
  end
  function wallet:hasEnough(amount)
    self.calls[#self.calls + 1] = { "hasEnough", amount }
    return self.money >= amount
  end
  function wallet:showBox(tileX, tileY)
    self.calls[#self.calls + 1] = { "showBox", tileX, tileY }
  end
  function wallet:updateBox()
    self.calls[#self.calls + 1] = { "updateBox" }
  end
  function wallet:hideBox()
    self.calls[#self.calls + 1] = { "hideBox" }
  end
  return wallet
end

function T.money_change_evaluates_its_amount_before_the_live_wallet_sees_it()
  local wallet = recordingWallet(100)
  local run = moneyRun(wallet)
  Assert.equal(
    Runtime.executeNode({ op = "money_change", action = "add", amount = 150 }, run),
    Runtime.OUTCOME_CONTINUE,
    "a source add returns in the same tick"
  )
  Assert.equal(
    Runtime.executeNode({ op = "money_change", action = "add", amount = { value = "var", id = "VAR_TEMP_x4001" } }, run),
    Runtime.OUTCOME_CONTINUE
  )
  Assert.equal(
    Runtime.executeNode({ op = "money_change", action = "subtract", amount = 10 }, run),
    Runtime.OUTCOME_CONTINUE
  )
  Assert.isNil(run.blockTaskId, "money changes never block on a task")
  Assert.deepEqual(wallet.calls, {
    { "add", 150 },
    { "add", 40 },
    { "subtract", 10 },
  }, "each command hands the live wallet its evaluated source amount exactly once")
end

function T.money_check_writes_the_source_boolean_and_never_moves_the_wallet()
  local wallet = recordingWallet(60)
  local run, values = moneyRun(wallet)
  Assert.equal(
    Runtime.executeNode({ op = "money_check", amount = 1000, result = { value = "var", id = "VAR_TEMP_x4002" } }, run),
    Runtime.OUTCOME_CONTINUE
  )
  Assert.equal(values.VAR_TEMP_x4002, 0, "an unaffordable source amount writes 0")
  Assert.equal(
    Runtime.executeNode({ op = "money_check", amount = 60, result = { value = "var", id = "VAR_TEMP_x4002" } }, run),
    Runtime.OUTCOME_CONTINUE
  )
  Assert.equal(values.VAR_TEMP_x4002, 1, "the exact affordable boundary writes 1")
  Assert.equal(wallet.money, 60, "a money check never changes the balance")
  Assert.deepEqual(wallet.calls, { { "hasEnough", 1000 }, { "hasEnough", 60 } }, "only the check is asked")
end

-- The source reads the amount operand before it writes the result pointer, so
-- one variable may serve as both: the check answers the pre-write value.
function T.money_check_evaluates_an_aliased_amount_before_it_writes_the_result()
  local wallet = recordingWallet(100)
  local run, values = moneyRun(wallet, { VAR_TEMP_x4001 = 40 })
  Assert.equal(
    Runtime.executeNode({
      op = "money_check",
      amount = { value = "var", id = "VAR_TEMP_x4001" },
      result = { value = "var", id = "VAR_TEMP_x4001" },
    }, run),
    Runtime.OUTCOME_CONTINUE
  )
  Assert.deepEqual(wallet.calls, { { "hasEnough", 40 } }, "the amount is read before the result is written")
  Assert.equal(values.VAR_TEMP_x4001, 1, "the aliased variable holds the answer afterwards")
end

function T.money_box_operations_reach_the_field_window_in_source_order()
  local wallet = recordingWallet(100)
  local run = moneyRun(wallet)
  Assert.equal(
    Runtime.executeNode({
      op = "money_box",
      action = "show",
      tileX = { value = "var", id = "VAR_TEMP_x4002" },
      tileY = { value = "var", id = "VAR_TEMP_x4003" },
    }, run),
    Runtime.OUTCOME_CONTINUE,
    "the source money box opens in the same tick"
  )
  Assert.equal(Runtime.executeNode({ op = "money_box", action = "update" }, run), Runtime.OUTCOME_CONTINUE)
  Assert.equal(Runtime.executeNode({ op = "money_box", action = "hide" }, run), Runtime.OUTCOME_CONTINUE)
  Assert.isNil(run.blockTaskId, "the money box never blocks on a task")
  Assert.deepEqual(wallet.calls, {
    { "showBox", 3, 5 },
    { "updateBox" },
    { "hideBox" },
  }, "the box operations arrive in source order with the evaluated tile coordinates")
end

function T.money_commands_fault_without_a_wallet_owner()
  for _, node in ipairs({
    { op = "money_change", action = "add", amount = 1 },
    { op = "money_check", amount = 1, result = { value = "var", id = "VAR_TEMP_x4002" } },
    { op = "money_box", action = "hide" },
  }) do
    local run, _ = moneyRun(nil)
    local ok, err = pcall(function()
      Runtime.executeNode(node, run)
    end)
    Assert.isFalse(ok, "a scripted " .. node.op .. " never succeeds without the wallet owner")
    Assert.isTrue(Errors.is(err), "the missing owner is an attributed fault: " .. tostring(err))
    ---@cast err Errors.Error
    Assert.equal(err.code, ScriptErrors.SCRIPT_SERVICE_MISSING, "the fault names the missing service")
  end
end

function T.money_operations_carry_source_operands_only()
  local function validate(step)
    return S.validate({ api = 1, id = "test.money_schema", steps = { step } })
  end
  Assert.equal(validate({ op = "money_change", action = "add", amount = 999999 }), true)
  Assert.equal(
    validate({ op = "money_change", action = "subtract", amount = { value = "var", id = "VAR_TEMP_x4001" } }),
    true
  )
  Assert.equal(validate({ op = "money_check", amount = 100, result = { value = "var", id = "VAR_TEMP_x4002" } }), true)
  Assert.equal(validate({ op = "money_box", action = "show", tileX = 3, tileY = 5 }), true)
  Assert.equal(validate({ op = "money_box", action = "update" }), true, "an update carries no operands")
  Assert.equal(validate({ op = "money_box", action = "hide" }), true, "a hide carries no operands")

  Assert.isNil(validate({ op = "money_change", action = "set", amount = 1 }), "money_change has two source actions")
  Assert.isNil(validate({ op = "money_change", action = "add" }), "a money change requires its amount")
  Assert.isNil(
    validate({ op = "money_change", action = "add", amount = "999999" }),
    "a source amount is a number or a value reference"
  )
  Assert.isNil(validate({ op = "money_check", amount = 1 }), "a money check requires its result variable")
  Assert.isNil(validate({ op = "money_box", action = "show" }), "the source money box opens at two tile coordinates")
  Assert.isNil(validate({ op = "money_box", action = "update", tileX = 3 }), "no box action carries a coordinate")
end

return { tests = T }
