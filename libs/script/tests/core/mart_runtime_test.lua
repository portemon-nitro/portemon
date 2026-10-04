-- Mart DSL/schema and runtime boundary tests. Script execution stays generic:
-- modal launch blocks through the registered task and queries write through
-- the caller's declared destination in the same tick.

local Assert = require("tests.support.Assert")
local Dsl = require("libs.script.src.Dsl")
local Compiler = require("libs.script.src.Compiler")
local Runtime = require("libs.script.src.Runtime")
local Validator = require("libs.script.src.Validator")

local T = {}

local function validateStep(step)
  return Validator.validate(Dsl.script({ api = 1, id = "test.mart_api", steps = { step } }))
end

local function assertValid(step)
  local ok, err = validateStep(step)
  Assert.isTrue(ok, "the mart operation validates: " .. tostring(err))
end

local function assertInvalid(step)
  local ok = validateStep(step)
  Assert.isNil(ok, "the malformed mart operation is rejected")
end

function T.mart_constructors_use_the_canonical_single_spec_shapes()
  for _, kind in ipairs({ "standard", "athlete", "data_cards", "sell" }) do
    local node = Dsl.mart({ kind = kind })
    Assert.equal(node.op, "mart_open")
    Assert.equal(node.kind, kind)
    assertValid(node)
  end
  for _, kind in ipairs({ "special", "seal", "decoration" }) do
    local node = Dsl.mart({ kind = kind, selector = Dsl.var("VAR_SPECIAL_SELECTOR") })
    Assert.equal(node.op, "mart_open")
    Assert.deepEqual(node.selector, { value = "var", id = "VAR_SPECIAL_SELECTOR" })
    assertValid(node)
  end
  local stock = {
    key = "sample_potion_stock",
    currency = "money",
    presentationKind = "items",
    quantityMode = "multiple",
    bonusPolicy = "none",
    entries = {
      {
        key = "potion",
        displayItemKey = "ITEM_POTION",
        description = { kind = "item" },
        unitPrice = 100,
        destination = { kind = "bag", key = "ITEM_POTION" },
        restriction = { kind = "none" },
        capacityProbe = { kind = "bag", key = "ITEM_POTION" },
      },
    },
  }
  local custom = Dsl.mart({ kind = "custom", stock = stock })
  Assert.equal(custom.op, "mart_open")
  Assert.deepEqual(custom.stock, stock)
  assertValid(custom)
  for _, kind in ipairs({ "athlete_available", "card_prefix" }) do
    local query = Dsl.martQuery({ kind = kind, result = Dsl.var("VAR_SPECIAL_RESULT") })
    Assert.equal(query.op, "mart_query")
    Assert.deepEqual(query.result, { value = "var", id = "VAR_SPECIAL_RESULT" })
    assertValid(query)
  end
end

function T.documented_custom_stock_and_query_compile_as_a_script()
  local stock = {
    key = "sample_potion_stock",
    currency = "money",
    presentationKind = "items",
    quantityMode = "multiple",
    bonusPolicy = "none",
    entries = {
      {
        key = "potion",
        displayItemKey = "ITEM_POTION",
        description = { kind = "item" },
        unitPrice = 100,
        destination = { kind = "bag", key = "ITEM_POTION" },
        restriction = { kind = "none" },
      },
    },
  }
  local graph, err = Compiler.compile(Dsl.script({
    api = 1,
    id = "test.custom_mart",
    steps = {
      Dsl.mart({ kind = "custom", stock = stock }),
      Dsl.martQuery({ kind = "card_prefix", result = Dsl.var("VAR_SPECIAL_RESULT") }),
    },
  }))
  Assert.notNil(graph, "the documented stock/query script compiles: " .. tostring(err))
end

function T.mart_schema_rejects_inapplicable_fields_and_read_only_results()
  assertInvalid({ op = "mart_open", kind = "standard", selector = 4 })
  assertInvalid({ op = "mart_open", kind = "special" })
  assertInvalid({ op = "mart_open", kind = "standard", stock = {} })
  assertInvalid({ op = "mart_open", kind = "custom" })
  assertInvalid({ op = "mart_open", kind = "sell", result = Dsl.var("VAR_RESULT") })
  assertInvalid({ op = "mart_open", kind = "competition" })
  assertInvalid({ op = "mart_query", kind = "badge_count", result = Dsl.var("VAR_RESULT") })
  assertInvalid({ op = "mart_query", kind = "card_prefix", result = Dsl.arg("read_only") })
  local stock = {
    key = "invalid",
    currency = "money",
    presentationKind = "items",
    quantityMode = "multiple",
    bonusPolicy = "none",
    entries = {},
  }
  stock.resolve = function() end
  assertInvalid({ op = "mart_open", kind = "custom", stock = stock })
  stock.resolve = nil
  stock.entries[1] = stock
  assertInvalid({ op = "mart_open", kind = "custom", stock = stock })
end

local function runtimeRun()
  local vars = {}
  local taskCalls = {}
  local queryCalls = {}
  local world = {
    vars = vars,
    getVar = function(self, id)
      return self.vars[id]
    end,
    setVar = function(self, id, value)
      self.vars[id] = value
    end,
  }
  local instance = {
    scriptId = "test.mart_runtime",
    instanceId = "mart-instance",
    mode = "foreground",
    locals = {},
    textArgs = {},
  }
  local semantics = {}
  function semantics.evaluateValue(value)
    if type(value) == "table" and value.value == "var" then
      return vars[value.id]
    end
    return value
  end
  function semantics.martTaskSpec(node, _)
    return { kind = node.kind, selector = node.selector and semantics.evaluateValue(node.selector) }
  end
  function semantics.martQuery(kind, _)
    queryCalls[#queryCalls + 1] = kind
    if kind == "athlete_available" then
      return 1
    end
    return 27
  end
  function semantics.writeRef(ref, value, _)
    if ref.value == "var" then
      vars[ref.id] = value
    else
      instance.locals[ref.name] = value
    end
  end
  local run = {
    instance = instance,
    node = { nodeId = "mart" },
    tick = 12,
    input = {},
    services = { world = world },
    semantics = semantics,
    scheduler = {
      createTask = function(_, taskType, spec, _, _, _)
        taskCalls[#taskCalls + 1] = { taskType = taskType, spec = spec }
        return "mart-task-1"
      end,
    },
  }
  return run, vars, taskCalls, queryCalls
end

function T.modal_mart_launch_blocks_the_foreground_script_on_its_task()
  local run, vars, taskCalls = runtimeRun()
  vars.SELECTOR = 3
  local outcome = Runtime.executeNode({
    op = "mart_open",
    kind = "special",
    selector = { value = "var", id = "SELECTOR" },
  }, run)
  Assert.equal(outcome, Runtime.OUTCOME_BLOCK)
  Assert.equal(run.blockTaskId, "mart-task-1")
  Assert.equal(#taskCalls, 1)
  Assert.equal(taskCalls[1].taskType, "mart")
  Assert.equal(taskCalls[1].spec.selector, 3, "selector value is resolved once for the launch descriptor")
  Assert.isNil(run.blockResultRef, "launch does not invent a result variable")
end

function T.mart_queries_write_their_result_before_runtime_continues()
  local run, vars, _, queryCalls = runtimeRun()
  for _, query in ipairs({
    { kind = "athlete_available", expected = 1 },
    { kind = "card_prefix", expected = 27 },
  }) do
    local outcome = Runtime.executeNode({
      op = "mart_query",
      kind = query.kind,
      result = { value = "var", id = "QUERY_RESULT" },
    }, run)
    Assert.equal(outcome, Runtime.OUTCOME_CONTINUE)
    Assert.equal(vars.QUERY_RESULT, query.expected, "query writes synchronously through its result reference")
  end
  Assert.deepEqual(queryCalls, { "athlete_available", "card_prefix" })
end

return { tests = T }
