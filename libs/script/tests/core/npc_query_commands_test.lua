-- The specialty-NPC command family through the generic script runtime: every
-- operand is evaluated before the injected leaf answers, buffered display names
-- become literals in the command's own tick, the size-record comparison's
-- source quirk yields a tick without writing its result, and the stat judge
-- writes its three outputs.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local Runtime = require("libs.script.src.Runtime")
local RuntimeValues = require("libs.hgss.src.script.RuntimeValues")
local ScriptErrors = require("libs.script.src.errors")

local T = {}

---@param npc table
---@param vars table<string, integer>?
---@return table run, table<string, integer> values
local function runWith(npc, vars)
  local values = vars or { VAR_TEMP_x4001 = 0, VAR_TEMP_x4002 = 0, VAR_TEMP_x4003 = 0, VAR_TEMP_x4004 = 0 }
  local run = {
    instance = { scriptId = "test.npc", locals = {}, textArgs = {} },
    services = {
      npcServices = npc,
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
    },
    semantics = RuntimeValues,
  }
  return run, values
end

---@return table a recording NPC leaf
local function recordingNpc()
  local npc = { calls = {} }
  function npc:sizeCompare(slot0)
    self.calls[#self.calls + 1] = { "sizeCompare", slot0 }
    return self.comparison or "larger"
  end
  function npc:sizeRecordUpdate(slot0)
    self.calls[#self.calls + 1] = { "sizeRecordUpdate", slot0 }
  end
  function npc:monSizeText(slot0)
    self.calls[#self.calls + 1] = { "monSizeText", slot0 }
    return { whole = " 30", fraction = "3" }
  end
  function npc:recordSizeText(speciesId)
    self.calls[#self.calls + 1] = { "recordSizeText", speciesId }
    return { whole = " 10", fraction = "3" }
  end
  function npc:monHasRibbon(slot0, ribbonId)
    self.calls[#self.calls + 1] = { "monHasRibbon", slot0, ribbonId }
    return true
  end
  function npc:ribbonName(ribbonId)
    self.calls[#self.calls + 1] = { "ribbonName", ribbonId }
    return "Cool Ribbon"
  end
  function npc:evTotal(slot0)
    self.calls[#self.calls + 1] = { "evTotal", slot0 }
    return 510
  end
  function npc:kenyaCheck(slot0, exact)
    self.calls[#self.calls + 1] = { "kenyaCheck", slot0, exact }
    return true
  end
  function npc:kenyaCheckPartyOrMailbox()
    self.calls[#self.calls + 1] = { "kenyaCheckPartyOrMailbox" }
    return false
  end
  function npc:statJudge(slot0)
    self.calls[#self.calls + 1] = { "statJudge", slot0 }
    return { total = 93, messageId = 124, highest = 31 }
  end
  function npc:statName(statId)
    self.calls[#self.calls + 1] = { "statName", statId }
    return "Attack"
  end
  function npc:hiddenPowerType(slot0)
    self.calls[#self.calls + 1] = { "hiddenPowerType", slot0 }
    return -1
  end
  return npc
end

-- An equal imperial height yields the next tick and leaves the result variable
-- alone; a larger or smaller mon writes its source code in the same tick.
function T.the_size_record_comparison_yields_on_a_tie_and_writes_otherwise()
  local npc = recordingNpc()
  local run, values = runWith(npc)
  npc.comparison = "equal"
  Assert.equal(
    Runtime.executeNode({
      op = "size_record_compare",
      result = { value = "var", id = "VAR_TEMP_x4002" },
      slot = 0,
    }, run),
    Runtime.OUTCOME_YIELD_TICK,
    "an equal record yields the next tick"
  )
  Assert.equal(values.VAR_TEMP_x4002, 0, "the yielding comparison writes nothing")

  npc.comparison = "larger"
  Assert.equal(
    Runtime.executeNode({
      op = "size_record_compare",
      result = { value = "var", id = "VAR_TEMP_x4002" },
      slot = 0,
    }, run),
    Runtime.OUTCOME_CONTINUE
  )
  Assert.equal(values.VAR_TEMP_x4002, 2, "a larger mon answers 2")
  npc.comparison = "smaller"
  Runtime.executeNode({ op = "size_record_compare", result = { value = "var", id = "VAR_TEMP_x4002" }, slot = 0 }, run)
  Assert.equal(values.VAR_TEMP_x4002, 0, "a smaller mon answers 0")
end

-- The size buffers resolve the format-field values and store the two literal
-- cell strings the following message prints.
function T.the_size_buffers_write_the_named_format_fields()
  local npc = recordingNpc()
  local run, values = runWith(npc, { VAR_TEMP_x4001 = 2, VAR_TEMP_x4002 = 3 })
  Assert.equal(
    Runtime.executeNode({
      op = "buffer_mon_size",
      wholeBuffer = { value = "var", id = "VAR_TEMP_x4001" },
      fractionBuffer = { value = "var", id = "VAR_TEMP_x4002" },
      slot = 1,
    }, run),
    Runtime.OUTCOME_CONTINUE
  )
  Assert.deepEqual(run.instance.textArgs[2], { text = "literal_text", value = " 30" }, "the whole count is buffered")
  Assert.deepEqual(run.instance.textArgs[3], { text = "literal_text", value = "3" }, "the tenth is buffered")
  Assert.deepEqual(npc.calls, { { "monSizeText", 1 } }, "the leaf answers the named slot once")

  Assert.equal(
    Runtime.executeNode({
      op = "buffer_record_size",
      wholeBuffer = 4,
      fractionBuffer = 5,
      species = 129,
    }, run),
    Runtime.OUTCOME_CONTINUE
  )
  Assert.deepEqual(run.instance.textArgs[4], { text = "literal_text", value = " 10" }, "the record count is buffered")
  Assert.deepEqual(run.instance.textArgs[5], { text = "literal_text", value = "3" }, "the record tenth is buffered")
end

-- The ribbon, effort-value, Kenya and Hidden Power queries write their source
-- answers, and the names resolve into their format fields.
function T.the_query_commands_write_their_source_answers()
  local npc = recordingNpc()
  local run, values = runWith(npc, { VAR_TEMP_x4001 = 1 })
  Runtime.executeNode({ op = "mon_has_ribbon", result = { value = "var", id = "VAR_TEMP_x4002" }, slot = 0, ribbon = 1 }, run)
  Assert.equal(values.VAR_TEMP_x4002, 1, "a stored ribbon answers 1")
  Runtime.executeNode({ op = "ev_total", result = { value = "var", id = "VAR_TEMP_x4002" }, slot = 0 }, run)
  Assert.equal(values.VAR_TEMP_x4002, 510, "the effort-value total is written")
  Runtime.executeNode({ op = "kenya_check", result = { value = "var", id = "VAR_TEMP_x4002" }, slot = 0, exact = 1 }, run)
  Assert.equal(values.VAR_TEMP_x4002, 1, "the exact Kenya check answers 1")
  Runtime.executeNode({ op = "kenya_check_party", result = { value = "var", id = "VAR_TEMP_x4002" } }, run)
  Assert.equal(values.VAR_TEMP_x4002, 0, "the party-or-mailbox check answers 0")
  Runtime.executeNode({ op = "hidden_power_type", slot = 0, result = { value = "var", id = "VAR_TEMP_x4004" } }, run)
  Assert.equal(values.VAR_TEMP_x4004, -1, "the refusal sentinel is written unchanged")

  Runtime.executeNode({ op = "buffer_ribbon_name", buffer = 6, ribbon = { value = "var", id = "VAR_TEMP_x4001" } }, run)
  Assert.deepEqual(run.instance.textArgs[6], { text = "literal_text", value = "Cool Ribbon" }, "the ribbon name is buffered")
  Runtime.executeNode({ op = "buffer_stat_name", buffer = 7, stat = { value = "var", id = "VAR_TEMP_x4001" } }, run)
  Assert.deepEqual(run.instance.textArgs[7], { text = "literal_text", value = "Attack" }, "the stat name is buffered")
  Assert.deepEqual(npc.calls, {
    { "monHasRibbon", 0, 1 },
    { "evTotal", 0 },
    { "kenyaCheck", 0, true },
    { "kenyaCheckPartyOrMailbox" },
    { "hiddenPowerType", 0 },
    { "ribbonName", 1 },
    { "statName", 1 },
  }, "every query reaches the leaf once, in source order")
end

-- The stat judge writes its three outputs and can be asked for its message text.
function T.the_stat_judge_writes_three_outputs()
  local npc = recordingNpc()
  local run, values = runWith(npc)
  Assert.equal(
    Runtime.executeNode({
      op = "stat_judge",
      slot = 0,
      total = { value = "var", id = "VAR_TEMP_x4001" },
      message = { value = "var", id = "VAR_TEMP_x4002" },
      highest = { value = "var", id = "VAR_TEMP_x4003" },
    }, run),
    Runtime.OUTCOME_CONTINUE
  )
  Assert.equal(values.VAR_TEMP_x4001, 93, "the total is written")
  Assert.equal(values.VAR_TEMP_x4002, 124, "the best-stat message row is written")
  Assert.equal(values.VAR_TEMP_x4003, 31, "the highest individual value is written")
  Assert.deepEqual(npc.calls, { { "statJudge", 0 } }, "the judge answers once")
end

-- A missing leaf faults the operation that needs it.
function T.every_npc_command_faults_without_its_owner()
  for _, node in ipairs({
    { op = "size_record_compare", result = { value = "var", id = "VAR_TEMP_x4001" }, slot = 0 },
    { op = "size_record_update", slot = 0 },
    { op = "buffer_mon_size", wholeBuffer = 0, fractionBuffer = 1, slot = 0 },
    { op = "buffer_record_size", wholeBuffer = 0, fractionBuffer = 1, species = 129 },
    { op = "mon_has_ribbon", result = { value = "var", id = "VAR_TEMP_x4001" }, slot = 0, ribbon = 0 },
    { op = "buffer_ribbon_name", buffer = 0, ribbon = 0 },
    { op = "ev_total", result = { value = "var", id = "VAR_TEMP_x4001" }, slot = 0 },
    { op = "kenya_check", result = { value = "var", id = "VAR_TEMP_x4001" }, slot = 0, exact = 0 },
    { op = "kenya_check_party", result = { value = "var", id = "VAR_TEMP_x4001" } },
    {
      op = "stat_judge",
      slot = 0,
      total = { value = "var", id = "VAR_TEMP_x4001" },
      message = { value = "var", id = "VAR_TEMP_x4002" },
      highest = { value = "var", id = "VAR_TEMP_x4003" },
    },
    { op = "buffer_stat_name", buffer = 0, stat = 0 },
    { op = "hidden_power_type", slot = 0, result = { value = "var", id = "VAR_TEMP_x4001" } },
  }) do
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
