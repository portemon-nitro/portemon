-- The lottery command family through the generic script runtime: the get and
-- the shared daily variable answer in their own tick, the set consumes the
-- owner's roll, and the search reads its lottery identity before it writes the
-- three source results, so an output aliasing the identity never changes what
-- the owner searched for.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local Runtime = require("libs.script.src.Runtime")
local RuntimeValues = require("libs.hgss.src.script.RuntimeValues")
local ScriptErrors = require("libs.script.src.errors")

local T = {}

---@param lottery table?
---@param vars table<string, integer>?
---@return table run, table<string, integer> values
local function runWith(lottery, vars)
  local values = vars or { VAR_TEMP_x4001 = 0, VAR_TEMP_x4002 = 0, VAR_TEMP_x4003 = 0, VAR_TEMP_x4004 = 0 }
  local run = {
    instance = { scriptId = "test.lottery", locals = {}, textArgs = {} },
    services = {
      lottery = lottery,
      world = {
        getVar = function(_, id)
          return values[id]
        end,
        setVar = function(_, id, value)
          values[id] = value
        end,
      },
    },
    semantics = RuntimeValues,
  }
  return run, values
end

---@return table a recording lottery owner
local function recordingLottery()
  local lottery = { calls = {}, saved = 0x12345678 }
  function lottery:lotoId()
    self.calls[#self.calls + 1] = { "lotoId" }
    return self.saved
  end
  function lottery:rollLotoId()
    self.calls[#self.calls + 1] = { "rollLotoId" }
    self.saved = 0x0F0F0000 + 0xABCD
  end
  function lottery:searchLotoId(lotoId)
    self.calls[#self.calls + 1] = { "searchLotoId", lotoId }
    self.search = lotoId
    return self.result or { position = 31, count = 5, kind = 1 }
  end
  function lottery:var4041()
    self.calls[#self.calls + 1] = { "var4041" }
    return 42
  end
  return lottery
end

-- The saved identity and the shared daily variable land in their result
-- variables, and the set reaches the owner's roll exactly once.
function T.the_lottery_get_set_and_daily_variable_answer_in_their_own_tick()
  local lottery = recordingLottery()
  local run, values = runWith(lottery)
  Assert.equal(
    Runtime.executeNode({ op = "loto_id_get", result = { value = "var", id = "VAR_TEMP_x4001" } }, run),
    Runtime.OUTCOME_CONTINUE
  )
  Assert.equal(values.VAR_TEMP_x4001, 0x12345678, "the saved identity is written")
  Assert.equal(Runtime.executeNode({ op = "loto_id_set" }, run), Runtime.OUTCOME_CONTINUE)
  Assert.equal(lottery.saved, 0x0F0F0000 + 0xABCD, "the set rolls the owner's identity")
  Assert.equal(
    Runtime.executeNode({ op = "get_var_4041", result = { value = "var", id = "VAR_TEMP_x4002" } }, run),
    Runtime.OUTCOME_CONTINUE
  )
  Assert.equal(values.VAR_TEMP_x4002, 42, "the shared daily variable is written")
  Assert.deepEqual(lottery.calls, { { "lotoId" }, { "rollLotoId" }, { "var4041" } }, "every command asks once")
end

-- The search reads its identity through the value reference before writing the
-- three results: an output aliasing the identity variable still searches for
-- the value the script named.
function T.the_lottery_search_reads_its_identity_before_writing_aliased_outputs()
  local lottery = recordingLottery()
  local run, values = runWith(lottery, { VAR_TEMP_x4001 = 12345 })
  Assert.equal(
    Runtime.executeNode({
      op = "loto_id_search",
      position = { value = "var", id = "VAR_TEMP_x4001" },
      count = { value = "var", id = "VAR_TEMP_x4002" },
      kind = { value = "var", id = "VAR_TEMP_x4003" },
      id = { value = "var", id = "VAR_TEMP_x4001" },
    }, run),
    Runtime.OUTCOME_CONTINUE
  )
  Assert.deepEqual(lottery.calls, { { "searchLotoId", 12345 } }, "the owner searches the named identity")
  Assert.equal(values.VAR_TEMP_x4001, 31, "the zero-based slot is written first")
  Assert.equal(values.VAR_TEMP_x4002, 5, "the matched digit count is written second")
  Assert.equal(values.VAR_TEMP_x4003, 1, "the container kind is written third")

  lottery.result = { position = 0, count = 0, kind = 0 }
  Runtime.executeNode({
    op = "loto_id_search",
    position = { value = "var", id = "VAR_TEMP_x4001" },
    count = { value = "var", id = "VAR_TEMP_x4002" },
    kind = { value = "var", id = "VAR_TEMP_x4003" },
    id = { value = "var", id = "VAR_TEMP_x4004" },
  }, run)
  Assert.deepEqual(
    { values.VAR_TEMP_x4001, values.VAR_TEMP_x4002, values.VAR_TEMP_x4003 },
    { 0, 0, 0 },
    "a no-match result writes the source zero triplet"
  )
end

-- Every lottery command faults with the missing-owner code instead of
-- fabricating an answer.
function T.the_lottery_commands_require_their_owner()
  local nodes = {
    { op = "loto_id_get", result = { value = "var", id = "VAR_TEMP_x4001" } },
    { op = "loto_id_set" },
    { op = "get_var_4041", result = { value = "var", id = "VAR_TEMP_x4001" } },
    {
      op = "loto_id_search",
      position = { value = "var", id = "VAR_TEMP_x4001" },
      count = { value = "var", id = "VAR_TEMP_x4002" },
      kind = { value = "var", id = "VAR_TEMP_x4003" },
      id = 0,
    },
  }
  for _, node in ipairs(nodes) do
    local run = runWith(nil)
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
