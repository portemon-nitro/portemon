-- The saved coin wallet, the Pokéathlon Athlete Point wallet, the transient
-- savings window and the Mom bank commands through the generic script
-- runtime: every operand is evaluated before the injected owner is called, a
-- check writes its 0/1 answer instead of moving a balance, the bank transfer
-- blocks on its own task, and ScrCmd_BankOrWalletIsFull yields the next tick
-- even though its query is synchronous.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local Runtime = require("libs.script.src.Runtime")
local RuntimeValues = require("libs.hgss.src.script.RuntimeValues")
local ScriptErrors = require("libs.script.src.errors")

local T = {}

---@param services table<string, unknown>
---@param vars table<string, integer>?
---@return table run, table<string, integer> values
local function runWith(services, vars)
  local values = vars or { VAR_TEMP_x4001 = 0, VAR_TEMP_x4002 = 0 }
  local run = {
    instance = { scriptId = "test.currencies", locals = {}, textArgs = {} },
    services = services,
    semantics = RuntimeValues,
  }
  run.services.world = {
    getVar = function(_, id)
      return values[id]
    end,
    setVar = function(_, id, value)
      values[id] = value
    end,
    isFlagSet = function(_, id)
      return values[id] == true
    end,
  }
  return run, values
end

local function recordingCoins()
  local wallet = { balanceValue = 1000, calls = {} }
  function wallet:balance()
    self.calls[#self.calls + 1] = { "balance" }
    return self.balanceValue
  end
  function wallet:give(amount)
    self.calls[#self.calls + 1] = { "give", amount }
  end
  function wallet:take(amount)
    self.calls[#self.calls + 1] = { "take", amount }
  end
  function wallet:canGive(amount)
    self.calls[#self.calls + 1] = { "canGive", amount }
    return self.balanceValue + amount <= 50000
  end
  return wallet
end

local function recordingAthletePoints(balance)
  local wallet = { balanceValue = balance, calls = {} }
  function wallet:balance()
    self.calls[#self.calls + 1] = { "balance" }
    return self.balanceValue
  end
  function wallet:give(amount)
    self.calls[#self.calls + 1] = { "give", amount }
    return true
  end
  function wallet:take(amount)
    self.calls[#self.calls + 1] = { "take", amount }
    return true
  end
  return wallet
end

-- ScrCmd_GetCoinAmount/GiveCoins/TakeCoins: the read answers the saved
-- balance, the mutations take the script's own amount, and every command
-- returns in the same tick.
function T.coin_commands_read_and_move_the_one_wallet()
  local wallet = recordingCoins()
  local run, values = runWith({ coins = wallet })
  Assert.equal(
    Runtime.executeNode({ op = "coin_read", result = { value = "var", id = "VAR_TEMP_x4002" } }, run),
    Runtime.OUTCOME_CONTINUE
  )
  Assert.equal(values.VAR_TEMP_x4002, 1000, "the read answers the saved balance")
  Assert.equal(
    Runtime.executeNode({ op = "coin_change", action = "give", amount = { value = "var", id = "VAR_TEMP_x4001" } }, run),
    Runtime.OUTCOME_CONTINUE
  )
  Assert.equal(Runtime.executeNode({ op = "coin_change", action = "take", amount = 480 }, run), Runtime.OUTCOME_CONTINUE)
  Assert.deepEqual(wallet.calls, { { "balance" }, { "give", 0 }, { "take", 480 } }, "each command moves the owner once")
  Assert.isNil(run.blockTaskId, "no coin command blocks on a task")
end

-- ScrCmd_CheckCoinsImmediate/CheckGiveCoins/CheckCoinsVar read their amount
-- before writing the result, so one variable may serve as both.
function T.coin_checks_answer_without_moving_the_wallet()
  local wallet = recordingCoins()
  local run, values = runWith({ coins = wallet }, { VAR_TEMP_x4001 = 1000 })
  Assert.equal(
    Runtime.executeNode({
      op = "coin_check",
      action = "balance",
      amount = { value = "var", id = "VAR_TEMP_x4001" },
      result = { value = "var", id = "VAR_TEMP_x4001" },
    }, run),
    Runtime.OUTCOME_CONTINUE
  )
  Assert.equal(values.VAR_TEMP_x4001, 1, "an exact balance answers 1")
  values.VAR_TEMP_x4001 = 1001
  Runtime.executeNode({
    op = "coin_check",
    action = "balance",
    amount = { value = "var", id = "VAR_TEMP_x4001" },
    result = { value = "var", id = "VAR_TEMP_x4001" },
  }, run)
  Assert.equal(values.VAR_TEMP_x4001, 0, "one coin short answers 0")

  Runtime.executeNode({
    op = "coin_check",
    action = "can_give",
    amount = { value = "var", id = "VAR_TEMP_x4001" },
    result = { value = "var", id = "VAR_TEMP_x4002" },
  }, run)
  Assert.equal(values.VAR_TEMP_x4002, 1, "the accumulator query asks the wallet owner")
  Assert.deepEqual(
    wallet.calls,
    { { "balance" }, { "balance" }, { "canGive", 0 } },
    "the checks only read the wallet"
  )
end

-- The Pokéathlon wallet has its own two mutations and its own compare.
function T.athlete_point_commands_use_the_athlete_wallet()
  local wallet = recordingAthletePoints(4200)
  local run, values = runWith({ athletePoints = wallet }, { VAR_TEMP_x4001 = 200 })
  Assert.equal(
    Runtime.executeNode({ op = "athlete_points_change", action = "give", amount = { value = "var", id = "VAR_TEMP_x4001" } }, run),
    Runtime.OUTCOME_CONTINUE
  )
  Assert.equal(Runtime.executeNode({ op = "athlete_points_change", action = "take", amount = 50 }, run), Runtime.OUTCOME_CONTINUE)
  Runtime.executeNode({
    op = "athlete_points_check",
    amount = { value = "var", id = "VAR_TEMP_x4001" },
    result = { value = "var", id = "VAR_TEMP_x4002" },
  }, run)
  Assert.equal(values.VAR_TEMP_x4002, 1, "the compare reads the saved athlete balance")
  Assert.deepEqual(wallet.calls, { { "give", 200 }, { "take", 50 }, { "balance" } }, "the owner answers in source order")
end

-- ScrCmd_ShowSavingsBox/UpdateSavingsBox/HideSavingsBox drive the one
-- transient window through the bank owner's savings window.
function T.the_savings_window_commands_pass_evaluated_coordinates()
  local window = { calls = {} }
  function window:show(tileX, tileY)
    self.calls[#self.calls + 1] = { "show", tileX, tileY }
  end
  function window:update()
    self.calls[#self.calls + 1] = { "update" }
  end
  function window:hide()
    self.calls[#self.calls + 1] = { "hide" }
  end
  local run = runWith({ bank = { savingsBox = window } }, { VAR_TEMP_x4001 = 1 })
  Assert.equal(
    Runtime.executeNode({
      op = "savings_box",
      action = "show",
      tileX = { value = "var", id = "VAR_TEMP_x4001" },
      tileY = 1,
    }, run),
    Runtime.OUTCOME_CONTINUE
  )
  Assert.equal(Runtime.executeNode({ op = "savings_box", action = "update" }, run), Runtime.OUTCOME_CONTINUE)
  Assert.equal(Runtime.executeNode({ op = "savings_box", action = "hide" }, run), Runtime.OUTCOME_CONTINUE)
  Assert.deepEqual(window.calls, { { "show", 1, 1 }, { "update" }, { "hide" } }, "the window sees the evaluated tiles")
  Assert.isNil(run.blockTaskId, "the savings window never blocks")
end

-- ScrCmd_BankOrWalletIsFull writes its answer and yields the next tick;
-- ScrCmd_CheckBankBalance answers in the same tick.
function T.bank_queries_answer_and_the_fullness_check_yields_a_tick()
  local bank = {
    savings = function()
      return 999999
    end,
    wallet = function()
      return 3000
    end,
    isFull = function(_, kind)
      return kind == "bank"
    end,
  }
  local run, values = runWith({ bank = bank })
  Assert.equal(
    Runtime.executeNode({
      op = "bank_overflow_check",
      action = 0,
      result = { value = "var", id = "VAR_TEMP_x4002" },
    }, run),
    Runtime.OUTCOME_YIELD_TICK,
    "the source fullness check yields the next tick"
  )
  Assert.equal(values.VAR_TEMP_x4002, 1, "the full savings account answers 1")
  Runtime.executeNode({
    op = "bank_overflow_check",
    action = 1,
    result = { value = "var", id = "VAR_TEMP_x4002" },
  }, run)
  Assert.equal(values.VAR_TEMP_x4002, 0, "the wallet is not full")

  Assert.equal(
    Runtime.executeNode({
      op = "bank_balance_check",
      amount = 1000,
      result = { value = "var", id = "VAR_TEMP_x4002" },
    }, run),
    Runtime.OUTCOME_CONTINUE,
    "the balance compare answers in the same tick"
  )
  Assert.equal(values.VAR_TEMP_x4002, 1, "a savings balance above the threshold answers 1")
end

-- ScrCmd_BankTransaction blocks on its own task and a missing owner faults the
-- operation that needs it.
function T.the_bank_commands_fault_without_their_owner()
  for _, node in ipairs({
    { op = "savings_box", action = "hide" },
    { op = "bank_balance_check", amount = 1, result = { value = "var", id = "VAR_TEMP_x4002" } },
    { op = "bank_overflow_check", action = 0, result = { value = "var", id = "VAR_TEMP_x4002" } },
    { op = "coin_read", result = { value = "var", id = "VAR_TEMP_x4002" } },
    { op = "coin_change", action = "give", amount = 1 },
    { op = "athlete_points_change", action = "take", amount = 1 },
  }) do
    local run = runWith({})
    run.foreground = function()
      return true
    end
    local ok, err = pcall(function()
      Runtime.executeNode(node, run)
    end)
    Assert.isFalse(ok, "a scripted " .. node.op .. " never succeeds without its owner")
    Assert.isTrue(Errors.is(err), "the missing owner is an attributed fault: " .. tostring(err))
    ---@cast err Errors.Error
    Assert.equal(err.code, ScriptErrors.SCRIPT_SERVICE_MISSING, "the fault names the missing service")
  end
end

return { tests = T }
