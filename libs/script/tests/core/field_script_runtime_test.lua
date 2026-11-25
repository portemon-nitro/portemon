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
      isOpen = function()
        return false
      end,
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

-- The Battle Point family borrows the same kind of injected owner: the
-- runtime reads the wallet, moves it by the requested amount, answers the
-- affordability check, and drives the transient points window, while the
-- source saturation and the recorded statistics stay with the owner.
local function battlePointsRun(wallet, vars)
  local values = vars or { VAR_TEMP_x4001 = 32, VAR_TEMP_x4002 = 0 }
  local run = {
    instance = { scriptId = "test.battle_points", locals = {}, textArgs = {} },
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
      battlePoints = wallet,
    },
    semantics = RuntimeValues,
  }
  return run, values
end

-- One recording source wallet with the capability set the runtime may call.
local function recordingBattlePoints(balance)
  local wallet = { balance = balance, calls = {} }
  function wallet:balance()
    self.calls[#self.calls + 1] = { "balance" }
    return self.walletBalanceValue or self._balanceValue
  end
  function wallet:give(amount)
    self.calls[#self.calls + 1] = { "give", amount }
  end
  function wallet:take(amount)
    self.calls[#self.calls + 1] = { "take", amount }
  end
  function wallet:hasEnough(amount)
    self.calls[#self.calls + 1] = { "hasEnough", amount }
    return self._balanceValue >= amount
  end
  function wallet:showBox(valueType, tileX, tileY)
    self.calls[#self.calls + 1] = { "showBox", valueType, tileX, tileY }
  end
  function wallet:updateBox(valueType)
    self.calls[#self.calls + 1] = { "updateBox", valueType }
  end
  function wallet:hideBox()
    self.calls[#self.calls + 1] = { "hideBox" }
  end
  wallet._balanceValue = balance
  return wallet
end

function T.battle_point_commands_read_move_and_check_the_one_wallet()
  local wallet = recordingBattlePoints(80)
  local run, values = battlePointsRun(wallet)
  Assert.equal(
    Runtime.executeNode({ op = "battle_points_read", result = { value = "var", id = "VAR_TEMP_x4002" } }, run),
    Runtime.OUTCOME_CONTINUE,
    "the source read answers in the same tick"
  )
  Assert.equal(values.VAR_TEMP_x4002, 80, "the read writes the saved balance")
  Assert.equal(
    Runtime.executeNode({
      op = "battle_points_change",
      action = "give",
      amount = { value = "var", id = "VAR_TEMP_x4001" },
    }, run),
    Runtime.OUTCOME_CONTINUE
  )
  Assert.equal(Runtime.executeNode({ op = "battle_points_change", action = "take", amount = 48 }, run), Runtime.OUTCOME_CONTINUE)
  Assert.deepEqual(wallet.calls, { { "balance" }, { "give", 32 }, { "take", 48 } }, "each command moves the owner once")
  Assert.isNil(run.blockTaskId, "no Battle Point command blocks on a task")
end

-- The source reads the amount operand before it writes the result pointer, so
-- one variable may serve as both.
function T.battle_point_check_evaluates_an_aliased_amount_before_it_writes_the_result()
  local wallet = recordingBattlePoints(48)
  local run, values = battlePointsRun(wallet, { VAR_TEMP_x4001 = 48 })
  Assert.equal(
    Runtime.executeNode({
      op = "battle_points_check",
      amount = { value = "var", id = "VAR_TEMP_x4001" },
      result = { value = "var", id = "VAR_TEMP_x4001" },
    }, run),
    Runtime.OUTCOME_CONTINUE
  )
  Assert.deepEqual(wallet.calls, { { "hasEnough", 48 } }, "the amount is read before the result is written")
  Assert.equal(values.VAR_TEMP_x4001, 1, "the exact affordable boundary answers 1")
  values.VAR_TEMP_x4001 = 49
  Runtime.executeNode({
    op = "battle_points_check",
    amount = { value = "var", id = "VAR_TEMP_x4001" },
    result = { value = "var", id = "VAR_TEMP_x4001" },
  }, run)
  Assert.equal(values.VAR_TEMP_x4001, 0, "one point short answers 0")
end

function T.the_points_window_passes_the_raw_type_and_evaluated_coordinates()
  local wallet = recordingBattlePoints(200)
  local run = battlePointsRun(wallet)
  Assert.equal(
    Runtime.executeNode({
      op = "points_box",
      action = "show",
      valueType = 1,
      tileX = { value = "var", id = "VAR_TEMP_x4001" },
      tileY = 21,
    }, run),
    Runtime.OUTCOME_CONTINUE,
    "the source window opens in the same tick"
  )
  Assert.equal(Runtime.executeNode({ op = "points_box", action = "update", valueType = 1 }, run), Runtime.OUTCOME_CONTINUE)
  Assert.equal(Runtime.executeNode({ op = "points_box", action = "hide" }, run), Runtime.OUTCOME_CONTINUE)
  Assert.isNil(run.blockTaskId, "the points window never blocks on a task")
  Assert.deepEqual(wallet.calls, {
    { "showBox", 1, 32, 21 },
    { "updateBox", 1 },
    { "hideBox" },
  }, "the window operations arrive in source order with the evaluated coordinates")
end

function T.battle_point_and_points_window_commands_fault_without_their_owner()
  for _, node in ipairs({
    { op = "battle_points_read", result = { value = "var", id = "VAR_TEMP_x4002" } },
    { op = "battle_points_change", action = "give", amount = 1 },
    { op = "battle_points_check", amount = 1, result = { value = "var", id = "VAR_TEMP_x4002" } },
    { op = "points_box", action = "hide" },
  }) do
    local run = battlePointsRun(nil)
    local ok, err = pcall(function()
      Runtime.executeNode(node, run)
    end)
    Assert.isFalse(ok, "a scripted " .. node.op .. " never succeeds without the wallet owner")
    Assert.isTrue(Errors.is(err), "the missing owner is an attributed fault: " .. tostring(err))
    ---@cast err Errors.Error
    Assert.equal(err.code, ScriptErrors.SCRIPT_SERVICE_MISSING, "the fault names the missing service")
  end
end

-- The Frontier move tutor family: the page count, the price and the Headbutt
-- eligibility answer in the same tick through the tutor owner; the list menu
-- blocks the script on the generated page, whose rows carry the source move
-- identities, the Next row 0xfffd and the Cancel row 0xfffe.
local function tutorRun(tutor, mons, vars)
  local values = vars or { VAR_TEMP_x4001 = 0, VAR_TEMP_x4002 = 1 }
  local written = {}
  local run = {
    instance = { scriptId = "test.tutor", mode = "foreground", locals = {}, textArgs = {} },
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
      moveTutor = tutor,
      mons = mons,
    },
    scheduler = {
      createTask = function(_, taskType, spec)
        return { type = taskType, spec = spec }
      end,
    },
    semantics = {
      evaluateValue = function(value)
        if type(value) == "table" then
          return values[value.id]
        end
        return value
      end,
      writeRef = function(ref, value)
        written[ref.id] = value
        values[ref.id] = value
      end,
    },
  }
  return run, values, written
end

local function recordingTutor()
  local tutor = { calls = {} }
  function tutor:tutorPageCount(slot, tutorNpc)
    self.calls[#self.calls + 1] = { "tutorPageCount", slot, tutorNpc }
    return 2
  end
  function tutor:tutorPage(slot, tutorNpc, page)
    self.calls[#self.calls + 1] = { "tutorPage", slot, tutorNpc, page }
    return {
      rows = {
        { move = "MUD_SLAP", cost = 32, nativeId = 189 },
        { move = "SUPERPOWER", cost = 48, nativeId = 276 },
      },
      hasNext = true,
    }
  end
  function tutor:tutorPrice(move)
    self.calls[#self.calls + 1] = { "tutorPrice", move }
    if move == 189 then
      return { move = "MUD_SLAP", cost = 32, nativeId = 189 }
    end
    return nil
  end
  function tutor:canLearnHeadbutt(slot)
    self.calls[#self.calls + 1] = { "canLearnHeadbutt", slot }
    return slot == 0
  end
  return tutor
end

local function recordingTutorMons()
  local mons = { calls = {}, taught = {} }
  function mons:catalog()
    return {
      move = function(_, key)
        return { nativeId = key == "MUD_SLAP" and 189 or 276, name = key, basePp = 10 }
      end,
    }
  end
  function mons:setMove(slot, moveSlot, move)
    self.calls[#self.calls + 1] = { "setMove", slot, moveSlot, move }
    self.taught[#self.taught + 1] = { slot = slot, moveSlot = moveSlot, move = move }
  end
  return mons
end

function T.tutor_queries_answer_in_the_same_tick()
  local tutor = recordingTutor()
  local run, _, written = tutorRun(tutor, recordingTutorMons(), { VAR_TEMP_x4001 = 2, VAR_TEMP_x4002 = 1 })
  Assert.equal(
    Runtime.executeNode({
      op = "tutor_move_page_count",
      slot = { value = "var", id = "VAR_TEMP_x4001" },
      tutorNpc = { value = "var", id = "VAR_TEMP_x4002" },
      result = { value = "var", id = "VAR_TEMP_x4003" },
    }, run),
    Runtime.OUTCOME_CONTINUE
  )
  Assert.equal(written.VAR_TEMP_x4003, 2, "the page count answers in the same tick")
  Assert.equal(
    Runtime.executeNode({
      op = "tutor_move_price",
      move = 189,
      result = { value = "var", id = "VAR_TEMP_x4004" },
    }, run),
    Runtime.OUTCOME_CONTINUE
  )
  Assert.equal(written.VAR_TEMP_x4004, 32, "the price answers the inventory row")
  Assert.equal(
    Runtime.executeNode({
      op = "headbutt_tutor_eligible",
      slot = { value = "var", id = "VAR_TEMP_x4001" },
      result = { value = "var", id = "VAR_TEMP_x4005" },
    }, run),
    Runtime.OUTCOME_CONTINUE
  )
  Assert.equal(written.VAR_TEMP_x4005, 0, "an ineligible party slot answers 0")
  Assert.deepEqual(tutor.calls, {
    { "tutorPageCount", 2, 1 },
    { "tutorPrice", 189 },
    { "canLearnHeadbutt", 2 },
  })
end

function T.the_tutor_price_query_faults_on_a_move_outside_the_inventory()
  local run = tutorRun(recordingTutor(), recordingTutorMons())
  local ok, err = pcall(function()
    Runtime.executeNode({ op = "tutor_move_price", move = 9999, result = { value = "var", id = "VAR_TEMP_x4004" } }, run)
  end)
  Assert.isFalse(ok, "an unoffered move never prices at zero")
  Assert.isTrue(Errors.is(err), "the refusal is an attributed fault: " .. tostring(err))
  ---@cast err Errors.Error
  Assert.equal(err.code, ScriptErrors.SCRIPT_TUTOR_MOVE_UNKNOWN)
end

function T.the_tutor_teaching_command_writes_the_answered_row_once()
  local mons = recordingTutorMons()
  local run = tutorRun(recordingTutor(), mons, { VAR_TEMP_x4001 = 0, VAR_TEMP_x4002 = 3, VAR_TEMP_x4003 = 189 })
  Assert.equal(
    Runtime.executeNode({
      op = "tutor_move_teach",
      slot = { value = "var", id = "VAR_TEMP_x4001" },
      moveSlot = { value = "var", id = "VAR_TEMP_x4002" },
      move = { value = "var", id = "VAR_TEMP_x4003" },
    }, run),
    Runtime.OUTCOME_CONTINUE
  )
  Assert.deepEqual(
    mons.taught,
    { { slot = 0, moveSlot = 3, move = 189 } },
    "the answered row receives the selected source move exactly once"
  )
end

function T.the_tutor_list_blocks_on_its_generated_page()
  local tutor = recordingTutor()
  local run, _, written = tutorRun(tutor, recordingTutorMons(), { VAR_TEMP_x4001 = 0, VAR_TEMP_x4002 = 1, VAR_TEMP_x4004 = 0 })
  local outcome = Runtime.executeNode({
    op = "tutor_choose_move",
    slot = { value = "var", id = "VAR_TEMP_x4001" },
    tutorNpc = { value = "var", id = "VAR_TEMP_x4002" },
    page = { value = "var", id = "VAR_TEMP_x4004" },
    result = { value = "var", id = "VAR_TEMP_x4003" },
  }, run)
  Assert.equal(outcome, Runtime.OUTCOME_BLOCK, "the source list blocks the script")
  Assert.equal(run.blockTaskId.type, "menu", "the list rides the shared source menu task")
  local items = run.blockTaskId.spec.menu.items
  Assert.equal(#items, 4, "two moves plus the Next and Cancel rows")
  Assert.equal(items[1].value, 189, "a row carries the source move identity")
  Assert.equal(items[2].value, 276, "the second row carries its own identity")
  Assert.equal(items[3].value, 0xFFFD, "the Next row carries the source sentinel")
  Assert.equal(items[4].value, 0xFFFE, "the Cancel row carries the source sentinel")
  Assert.isTrue(items[1].text:find("32", 1, true) ~= nil, "a row prints the source price beside the move name")
  Assert.equal(written.VAR_TEMP_x4003, 0xEEEE, "the open list publishes the source pending answer")
  Assert.deepEqual(run.blockResultRef, { value = "var", id = "VAR_TEMP_x4003" }, "the completed row writes its own target")
  Assert.deepEqual(tutor.calls, { { "tutorPage", 0, 1, 0 } })
end

function T.battle_point_and_tutor_nodes_carry_source_operands_only()
  local function validate(step)
    return S.validate({ api = 1, id = "test.battle_points_schema", steps = { step } })
  end
  Assert.equal(validate({ op = "battle_points_read", result = { value = "var", id = "VAR_TEMP_x4002" } }), true)
  Assert.equal(validate({ op = "battle_points_change", action = "give", amount = 32 }), true)
  Assert.equal(validate({ op = "battle_points_change", action = "take", amount = { value = "var", id = "V" } }), true)
  Assert.equal(validate({ op = "battle_points_check", amount = 48, result = { value = "var", id = "V" } }), true)
  Assert.equal(validate({ op = "points_box", action = "show", valueType = 1, tileX = 21, tileY = 1 }), true)
  Assert.equal(validate({ op = "points_box", action = "update", valueType = 1 }), true)
  Assert.equal(validate({ op = "points_box", action = "hide" }), true)
  Assert.equal(
    validate({
      op = "tutor_move_page_count",
      slot = 0,
      tutorNpc = 1,
      result = { value = "var", id = "V" },
    }),
    true
  )
  Assert.equal(
    validate({
      op = "tutor_choose_move",
      slot = 0,
      tutorNpc = 1,
      page = 0,
      result = { value = "var", id = "V" },
    }),
    true
  )
  Assert.equal(validate({ op = "tutor_move_teach", slot = 0, moveSlot = 3, move = 189 }), true)
  Assert.equal(validate({ op = "tutor_move_price", move = 189, result = { value = "var", id = "V" } }), true)
  Assert.equal(validate({ op = "headbutt_tutor_eligible", slot = 0, result = { value = "var", id = "V" } }), true)

  Assert.isNil(validate({ op = "battle_points_change", action = "restore", amount = 1 }), "two wallet actions")
  Assert.isNil(validate({ op = "battle_points_read" }), "a wallet read names its result variable")
  Assert.isNil(validate({ op = "points_box", action = "show", valueType = 1 }), "show needs both coordinates")
  Assert.isNil(validate({ op = "points_box", action = "update", valueType = 1, tileX = 1 }), "only show carries a tile")
  Assert.isNil(validate({ op = "points_box", action = "update" }), "a repaint names its source type")
  Assert.isNil(validate({ op = "points_box", action = "hide", valueType = 1 }), "hiding carries no type")
  Assert.isNil(validate({ op = "tutor_choose_move", slot = 0, tutorNpc = 1, result = {} }), "the page is required")
  Assert.isNil(validate({ op = "tutor_move_price", move = 189 }), "the price names its result variable")
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

-- The gym mechanism nodes: the init command is a same-tick union write, and
-- every ride/switch command blocks on the one registered mechanism task with
-- its evaluated operands. The runtime never drives the mechanism itself.
function T.gym_mechanism_nodes_dispatch_their_source_operands()
  local written = {}
  local initialized = {}
  local called = {}
  local run = runState({
    gymMechanism = {
      initialize = function(_, kind)
        initialized[#initialized + 1] = kind
      end,
      bindCandle = function()
        called[#called + 1] = "bindCandle"
      end,
      unbindCandle = function()
        called[#called + 1] = "unbindCandle"
      end,
    },
  }, written)
  Assert.equal(Runtime.executeNode({ op = "gym_init", kind = "violet" }, run), Runtime.OUTCOME_CONTINUE)
  Assert.equal(Runtime.executeNode({ op = "gym_init", kind = "azalea" }, run), Runtime.OUTCOME_CONTINUE)
  Assert.deepEqual(initialized, { "violet", "azalea" }, "each init command installs its own closed kind")

  local outcome = Runtime.executeNode({ op = "gym_elevator" }, run)
  Assert.equal(outcome, Runtime.OUTCOME_BLOCK, "the lift owns the script's frames")
  Assert.equal(run.blockTaskId.type, "gym_mechanism")
  Assert.equal(run.blockTaskId.spec.action, "elevator")

  outcome = Runtime.executeNode({ op = "gym_spinarak", selector = 7 }, run)
  Assert.equal(outcome, Runtime.OUTCOME_BLOCK, "the spider ride owns the script's frames")
  Assert.equal(run.blockTaskId.type, "gym_mechanism")
  Assert.equal(run.blockTaskId.spec.action, "spinarak")
  Assert.equal(run.blockTaskId.spec.selector, 7, "the source selector is a literal endpoint operand")

  outcome = Runtime.executeNode({ op = "gym_switch", switchNumber = 1 }, run)
  Assert.equal(outcome, Runtime.OUTCOME_BLOCK, "the switch waits for its own source sound")
  Assert.equal(run.blockTaskId.type, "gym_mechanism")
  Assert.equal(run.blockTaskId.spec.action, "switch")
  Assert.equal(run.blockTaskId.spec.switchNumber, 1)

  Assert.equal(Runtime.executeNode({ op = "gym_init", kind = "ecruteak" }, run), Runtime.OUTCOME_CONTINUE)
  Assert.equal(Runtime.executeNode({ op = "gym_init", kind = "cianwood" }, run), Runtime.OUTCOME_CONTINUE)
  Assert.equal(Runtime.executeNode({ op = "gym_init", kind = "blackthorn" }, run), Runtime.OUTCOME_CONTINUE)
  Assert.deepEqual(initialized, { "violet", "azalea", "ecruteak", "cianwood", "blackthorn" })

  Assert.equal(Runtime.executeNode({ op = "gym_candle_bind" }, run), Runtime.OUTCOME_CONTINUE)
  Assert.equal(Runtime.executeNode({ op = "gym_candle_unbind" }, run), Runtime.OUTCOME_CONTINUE)
  Assert.deepEqual(called, { "bindCandle", "unbindCandle" }, "the candle binding commands are same-tick calls")
  Assert.equal(
    Runtime.executeNode({ op = "gym_winch", result = { value = "var", id = 0x4000 } }, run),
    Runtime.OUTCOME_BLOCK
  )
  Assert.equal(run.blockTaskId.spec.action, "winch")
  Assert.equal(run.blockResultRef.id, 0x4000, "the winch writes the variable its command names")
end

-- The candle's raw selector byte chooses the source script environment
-- attribute: nonzero names the invoked interaction's actor, zero the engaged
-- trainer slot, which the mechanism resolves itself.
function T.the_candle_extinguish_selector_chooses_its_source_attribute()
  local run = runState({ gymMechanism = {} }, {})
  run.instance.trigger = { kind = "object", selfActor = "map:80:object:5" }
  local outcome = Runtime.executeNode({ op = "gym_candle_extinguish", useLastInteracted = 1 }, run)
  Assert.equal(outcome, Runtime.OUTCOME_BLOCK)
  Assert.equal(run.blockTaskId.spec.action, "candle_extinguish")
  Assert.isTrue(run.blockTaskId.spec.useLastInteracted)
  Assert.equal(run.blockTaskId.spec.lastInteractedActor, "map:80:object:5")
  Assert.isNil(run.blockResultRef, "the extinguish command answers no output variable")

  run.instance.trigger = nil
  Runtime.executeNode({ op = "gym_candle_extinguish", useLastInteracted = 0 }, run)
  Assert.isFalse(run.blockTaskId.spec.useLastInteracted, "a zero selector names the engaged trainer")
  Assert.isNil(run.blockTaskId.spec.lastInteractedActor)
end

-- A runtime without the mechanism service faults instead of pretending the
-- gym moved: the missing owner is a composition fault, not a no-op.
function T.gym_mechanism_nodes_require_their_owner()
  local run = runState({}, {})
  local err = Assert.throws(function()
    Runtime.executeNode({ op = "gym_init", kind = "violet" }, run)
  end)
  Assert.isTrue(Errors.is(err))
  Assert.equal(err.code, ScriptErrors.SCRIPT_SERVICE_MISSING)
  err = Assert.throws(function()
    Runtime.executeNode({ op = "gym_elevator" }, run)
  end)
  Assert.equal(err.code, ScriptErrors.SCRIPT_SERVICE_MISSING)
end

-- The native trainer engagement family: the approach start returns in its own
-- tick, the approach poll yields exactly one source tick after its same-tick
-- write, and every query answers in the tick that runs it. The trainer
-- identity and message kind operands are evaluated before the service reads
-- them, exactly like ScriptGetVar.
function T.trainer_approach_and_queries_run_in_their_source_ticks()
  local written = {}
  local calls = {}
  local trigger = { kind = "object", selfActor = "map:80:object:5" }
  local run = runState({
    trainerEncounter = {
      startApproach = function(_, index)
        calls[#calls + 1] = { op = "start", index = index }
      end,
      stepApproach = function(_, index)
        calls[#calls + 1] = { op = "step", index = index }
        return 0
      end,
      encounterType = function()
        return 1
      end,
      engagementTrainer = function(_, index)
        return 40 + index
      end,
      activeTrainerNumber = function(_, context)
        Assert.equal(context, trigger, "the running script carries its own launch context")
        return 46
      end,
      isDoubleTrainer = function()
        return true
      end,
    },
    mons = {
      countAliveMons = function()
        return 2
      end,
    },
  }, written)
  run.instance.trigger = trigger
  local values = { SLOT = 1 }
  run.semantics.evaluateValue = function(value)
    if type(value) == "table" then
      return values[value.id]
    end
    return value
  end

  Assert.equal(
    Runtime.executeNode({ op = "trainer_approach_start", index = { id = "SLOT" } }, run),
    Runtime.OUTCOME_CONTINUE,
    "the approach start answers in its own tick"
  )
  Assert.deepEqual(calls[1], { op = "start", index = 1 }, "the slot variable is evaluated before the call")

  Assert.equal(
    Runtime.executeNode({
      op = "trainer_approach_step",
      index = { id = "SLOT" },
      result = { value = "var", id = "VAR_RESULT" },
    }, run),
    Runtime.OUTCOME_YIELD_TICK,
    "the approach poll spends one source tick"
  )
  Assert.equal(written.VAR_RESULT, 0, "the poll answers its native false while the approach runs")
  Assert.equal(calls[2].op, "step")

  Assert.equal(
    Runtime.executeNode({ op = "trainer_encounter_type", result = { value = "var", id = "VAR_TYPE" } }, run),
    Runtime.OUTCOME_CONTINUE
  )
  Assert.equal(written.VAR_TYPE, 1)

  Assert.equal(
    Runtime.executeNode({
      op = "trainer_engagement_number",
      index = { id = "SLOT" },
      result = { value = "var", id = "VAR_TRAINER" },
    }, run),
    Runtime.OUTCOME_CONTINUE
  )
  Assert.equal(written.VAR_TRAINER, 41, "the engagement slot answers its own native trainer")

  Assert.equal(
    Runtime.executeNode({ op = "trainer_active_number", result = { value = "var", id = "VAR_OWN" } }, run),
    Runtime.OUTCOME_CONTINUE
  )
  Assert.equal(written.VAR_OWN, 46)

  Assert.equal(
    Runtime.executeNode({ op = "trainer_is_double", result = { value = "var", id = "VAR_DOUBLE" } }, run),
    Runtime.OUTCOME_CONTINUE
  )
  Assert.equal(written.VAR_DOUBLE, 1, "the source boolean writes as one")

  Assert.equal(
    Runtime.executeNode({ op = "party_can_double_battle", result = { value = "var", id = "VAR_PARTY" } }, run),
    Runtime.OUTCOME_CONTINUE
  )
  Assert.equal(written.VAR_PARTY, 1, "two living mons field a double battle")
end

-- The source message parameters write their three ordered outputs in the same
-- tick: ordinary kinds, the double pair's slot variants, and the phone
-- rematch kinds.
function T.trainer_message_parameters_write_their_three_kinds_same_tick()
  local written = {}
  local run = runState({
    trainerEncounter = {
      messageParams = function(_, _, rematch)
        Assert.isFalse(rematch, "the ordinary command reads the ordinary kinds")
        return { intro = 3, after = 5, shortIntro = 6 }
      end,
    },
  }, written)
  run.instance.trigger = { kind = "object", selfActor = "map:41:object:0" }
  Assert.equal(
    Runtime.executeNode({
      op = "trainer_message_params",
      intro = { value = "var", id = "VAR_INTRO" },
      after = { value = "var", id = "VAR_AFTER" },
      shortIntro = { value = "var", id = "VAR_SHORT" },
    }, run),
    Runtime.OUTCOME_CONTINUE
  )
  Assert.deepEqual(
    { written.VAR_INTRO, written.VAR_AFTER, written.VAR_SHORT },
    { 3, 5, 6 },
    "the pair's first slot kinds land in their source order"
  )

  run.services.trainerEncounter.messageParams = function(_, _, rematch)
    Assert.isTrue(rematch, "the rematch command asks for the phone-rematch kinds")
    return { intro = 18, after = 0, shortIntro = 6 }
  end
  Runtime.executeNode({
    op = "trainer_rematch_message_params",
    intro = { value = "var", id = "VAR_INTRO" },
    after = { value = "var", id = "VAR_AFTER" },
    shortIntro = { value = "var", id = "VAR_SHORT" },
  }, run)
  Assert.deepEqual({ written.VAR_INTRO, written.VAR_SHORT }, { 18, 6 })
end

-- ScrCmd_TrainerMessage prints the source pair's field speech through the
-- shared dialogue task with the native print-only wait. A trainer whose pair
-- the source does not carry has no readable speech: the command spends its own
-- tick instead of borrowing another trainer's message.
function T.trainer_message_prints_field_speech_and_empty_pairs_spend_their_tick()
  local written = {}
  local asked = {}
  local location = { bank = 728, id = 40 }
  local run = runState({
    trainerEncounter = {
      fieldMessage = function(_, trainer, kind)
        asked[#asked + 1] = { trainer = trainer, kind = kind }
        return location
      end,
    },
    dialogue = {},
  }, written)
  run.semantics.evaluateValue = function(value)
    return value
  end
  Assert.equal(
    Runtime.executeNode({ op = "trainer_message", trainer = 46, kind = 2, bindings = {} }, run),
    Runtime.OUTCOME_BLOCK,
    "the field speech blocks until its print completes"
  )
  Assert.equal(run.blockTaskId.type, "dialogue")
  Assert.deepEqual(asked[1], { trainer = 46, kind = 2 }, "the pair reads the script's own trainer and kind")
  local taskNode = run.blockTaskId.spec.node
  Assert.equal(taskNode.op, "message")
  Assert.deepEqual(taskNode.message, { message = "external", bank = 728, id = 40 })

  location = nil
  run.blockTaskId = nil
  Assert.equal(
    Runtime.executeNode({ op = "trainer_message", trainer = 46, kind = 7 }, run),
    Runtime.OUTCOME_YIELD_TICK,
    "a missing pair spends the source's own tick"
  )
  Assert.isNil(run.blockTaskId, "the missing pair opens no print")
  Assert.deepEqual(asked[2], { trainer = 46, kind = 7 }, "the missing pair keeps its own trainer and kind")
end

-- ScrCmd_EncounterMusic starts the trainer class's eyes-meet sequence and
-- returns TRUE, spending one source tick.
function T.trainer_encounter_music_plays_the_catalog_sequence_and_yields_one_tick()
  local written = {}
  local played = nil
  local run = runState({
    trainerEncounter = {
      encounterMusic = function(_, trainer)
        Assert.equal(trainer, 46)
        return "SEQ_GS_EYE_BOUZU"
      end,
    },
    audio = {
      temporaryMusic = function(_, sequence)
        played = sequence
      end,
    },
  }, written)
  run.semantics.evaluateValue = function(value)
    return value
  end
  Assert.equal(
    Runtime.executeNode({ op = "trainer_encounter_music", trainer = 46 }, run),
    Runtime.OUTCOME_YIELD_TICK,
    "the eyes-meet sequence spends the source's one tick"
  )
  Assert.equal(played, "SEQ_GS_EYE_BOUZU")
end

-- ScrCmd_SetLastTalkedTrainerMovement rewrites the talked-to trainer's live
-- movement from the launch context in its own tick, and
-- ScrCmd_GetObjectMovementType answers the named actor's current native
-- selector in its own tick.
function T.trainer_movement_commands_read_the_script_context_and_named_actor()
  local written = {}
  local calls = {}
  local run = runState({
    trainerEncounter = {
      lastTalkedMovement = function(_, trigger)
        calls[#calls + 1] = { op = "last_talked", trigger = trigger }
      end,
      movementSelector = function(_, actorId)
        calls[#calls + 1] = { op = "selector", actor = actorId }
        return 17
      end,
    },
  }, written)
  run.instance.trigger = { kind = "object", selfActor = "map:80:object:5" }
  run.semantics.evaluateValue = function(value)
    return value
  end
  run.semantics.requireActor = function(ref)
    Assert.deepEqual(ref, { ref = "actor", special = "last_talked" }, "the movement read names its actor operand")
    return "map:80:object:5"
  end

  Assert.equal(Runtime.executeNode({ op = "trainer_last_talked_movement" }, run), Runtime.OUTCOME_CONTINUE)
  Assert.equal(calls[1].op, "last_talked")
  Assert.equal(calls[1].trigger, run.instance.trigger, "the talk movement reads the launch context")

  Assert.equal(
    Runtime.executeNode({
      op = "object_movement_type",
      actor = { ref = "actor", special = "last_talked" },
      result = { value = "var", id = "VAR_MOVEMENT" },
    }, run),
    Runtime.OUTCOME_CONTINUE
  )
  Assert.equal(written.VAR_MOVEMENT, 17, "the selector lands in the destination variable")
  Assert.equal(calls[2].actor, "map:80:object:5")
end

return { tests = T }
