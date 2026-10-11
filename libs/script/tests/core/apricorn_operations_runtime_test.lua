-- Field script Apricorn operations resolve the interacted actor and delegate
-- inventory and text work to the injected Apricorn owner.

local Assert = require("tests.support.Assert")
local Runtime = require("libs.script.src.Runtime")
local RuntimeValues = require("libs.hgss.src.script.RuntimeValues")
local Compiler = require("libs.script.src.Compiler")
local Dsl = require("libs.script.src.Dsl")

local T = {}

local function harness()
  local values = { [0x8000] = 3, [0x8001] = 2 }
  local calls = {}
  local run = {
    instance = { scriptId = "common.apricorn_tree", trigger = { selfActor = "map:34:object:2" }, textArgs = {} },
    services = {
      world = {
        getVar = function(_, id)
          return values[id]
        end,
        setVar = function(_, id, value)
          values[id] = value
        end,
      },
      apricorn = {
        colorForActor = function(_, actorId)
          calls[#calls + 1] = { "colorForActor", actorId }
          return 3
        end,
        give = function(_, color, quantity)
          calls[#calls + 1] = { "give", color, quantity }
          return false
        end,
        displayName = function(_, color)
          calls[#calls + 1] = { "displayName", color }
          return "Green Apricorn"
        end,
      },
      apricornKurt = {
        pendingQuantity = function()
          calls[#calls + 1] = { "pendingQuantity" }
          return 4
        end,
        pendingBallNativeId = function()
          calls[#calls + 1] = { "pendingBallNativeId" }
          return 12
        end,
        total = function()
          calls[#calls + 1] = { "total" }
          return 9
        end,
        clear = function()
          calls[#calls + 1] = { "clear" }
        end,
      },
      kurtBoxHost = {},
    },
    semantics = RuntimeValues,
    scheduler = {
      createTask = function(_, taskType, spec)
        calls[#calls + 1] = { "createTask", taskType, spec.actorId }
        return "task:apricorn"
      end,
    },
    tick = 1,
    input = {},
  }
  return run, values, calls
end

local function var(id)
  return { value = "var", id = id }
end

function T.color_give_and_name_keep_source_result_conventions()
  local run, values, calls = harness()
  Runtime.executeNode({ op = "apricorn_tree_color", result = var(0x8002) }, run)
  Assert.equal(values[0x8002], 3)
  Runtime.executeNode({ op = "apricorn_give", color = var(0x8000), quantity = var(0x8001), result = var(0x8003) }, run)
  Assert.equal(values[0x8003], 0, "failed capacity check writes source FALSE")
  Runtime.executeNode({ op = "apricorn_name", slot = 2, color = var(0x8000) }, run)
  Assert.equal(run.instance.textArgs[2], "Green Apricorn")
  Assert.equal(calls[1][1], "colorForActor")
  Assert.equal(calls[1][2], "map:34:object:2", "queries use the interacted actor")
  Assert.equal(calls[2][1], "give")
  Assert.equal(calls[2][2], 3)
  Assert.equal(calls[2][3], 2)
  Assert.equal(calls[3][1], "displayName")
  Assert.equal(calls[3][2], 3)
end

function T.animation_blocks_on_the_interacted_actor()
  local run, _, calls = harness()
  Assert.equal(Runtime.executeNode({ op = "apricorn_tree_anim", result = var(0x8004) }, run), Runtime.OUTCOME_BLOCK)
  Assert.equal(calls[1][1], "createTask")
  Assert.equal(calls[1][2], "apricorn_tree")
  Assert.equal(calls[1][3], "map:34:object:2")
end

function T.kurt_commands_write_queries_clear_and_block_on_the_source_values()
  local run, values, calls = harness()
  Assert.equal(
    Runtime.executeNode({ op = "apricorn_kurt_quantity", result = var(0x8005) }, run),
    Runtime.OUTCOME_CONTINUE
  )
  Assert.equal(Runtime.executeNode({ op = "apricorn_kurt_ball", result = var(0x8006) }, run), Runtime.OUTCOME_CONTINUE)
  Assert.equal(Runtime.executeNode({ op = "apricorn_total", result = var(0x8007) }, run), Runtime.OUTCOME_CONTINUE)
  Assert.equal(values[0x8005], 4)
  Assert.equal(values[0x8006], 12)
  Assert.equal(values[0x8007], 9)
  Assert.equal(Runtime.executeNode({ op = "apricorn_kurt_clear" }, run), Runtime.OUTCOME_CONTINUE)
  Assert.equal(Runtime.executeNode({ op = "apricorn_box_select" }, run), Runtime.OUTCOME_BLOCK)
  Assert.equal(run.blockTaskId, "task:apricorn")
  Assert.deepEqual(calls, {
    { "pendingQuantity" },
    { "pendingBallNativeId" },
    { "total" },
    { "clear" },
    { "createTask", "kurt_apricorn_box", nil },
  })
end

function T.kurt_operations_validate_and_compile_with_exact_result_shapes()
  local result = Dsl.var("VAR_RESULT")
  local script = Dsl.script({
    api = 1,
    id = "test.kurt_commands",
    steps = {
      Dsl.apricornKurtQuantity({ result = result }),
      Dsl.apricornKurtBall({ result = result }),
      Dsl.apricornTotal({ result = result }),
      Dsl.apricornKurtClear({}),
      Dsl.apricornBoxSelect({}),
    },
  })
  local graph, err = Compiler.compile(script)
  Assert.notNil(graph, "all five Kurt source nodes compile: " .. tostring(err))
  local selectNode
  for _, node in pairs(graph.nodes) do
    if node.op == "apricorn_box_select" then
      selectNode = node
    end
  end
  Assert.notNil(selectNode)
  Assert.isNil(selectNode.result, "blocking select has no invented source destination")
  local malformed, _ = Compiler.compile(Dsl.script({
    api = 1,
    id = "test.kurt_bad_query",
    steps = { { op = "apricorn_kurt_clear", result = result } },
  }))
  Assert.isNil(malformed, "unconditional clear accepts no guard or result parameter")
end

return { tests = T }
