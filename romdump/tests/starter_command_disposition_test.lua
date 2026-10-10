-- Starter opcode contract: the source starter command is supported with
-- real blocking semantics. It lowers to a semantic starter operation (never
-- a silent fallback or an explicit unsupported node), the operation exists
-- in the script DSL and schema, and the HGSS task composition registers the
-- blocking starter task.

local Assert = require("tests.support.Assert")
local CommandCatalog = require("romdump.src.digest.script.CommandCatalog")
local ScriptCommands = require("romdump.src.reference.hgss.script_commands")
local SemanticLowering = require("romdump.src.digest.script.SemanticLowering")
local SourceCatalog = require("romdump.src.digest.script.SourceCatalog")

local T = {}

local function entry(opcode)
  local found = ScriptCommands.byOpcode[opcode]
  Assert.notNil(found, "the pinned catalog names opcode " .. opcode)
  return assert(found)
end

local function lowerWith(opcode, operands)
  local lowered = SemanticLowering.lowerScript(
    { instructions = { { opcode = opcode, operands = operands, offset = 0 } } },
    { member = 12, scripts = {}, movements = {} },
    { stdCatalog = SourceCatalog.catalog() }
  )
  return lowered.items
end

local function lowerSingle(opcode)
  local widths = CommandCatalog.widths(opcode) or {}
  local operands = {}
  for index = 1, #widths do
    operands[index] = 0
  end
  return lowerWith(opcode, operands)
end

function T.starter_command_is_supported_with_blocking_timing()
  local tagged = entry(167)
  Assert.equal(tagged.disposition, "supported", "the starter command is supported here")
  Assert.equal(tagged.feature, "starter", "the starter command belongs to the starter family")
  Assert.isNil(tagged.deferredReason, "a supported starter command carries no deferral category")
  Assert.equal(tagged.classification, "native_wait", "the starter application blocks like the source scene")
end

function T.starter_command_lowers_to_a_semantic_starter_operation()
  local items = lowerSingle(167)
  Assert.equal(#items, 1, "the starter command lowers to one step")
  Assert.equal(items[1].op, "choose_starter", "the starter command lowers to real semantics")
end

function T.starter_operation_exists_in_the_script_dsl_and_schema()
  local Dsl = require("libs.script.src.Dsl")
  Assert.isTrue(type(Dsl.chooseStarter) == "function", "generated scripts construct the starter operation")
  local node = Dsl.chooseStarter({})
  Assert.equal(node.op, "choose_starter", "the constructor names the semantic operation")

  local Schema = require("libs.script.src.Schema")
  Assert.notNil(Schema.OPERATIONS, "the schema exposes its operation table")
  Assert.notNil(Schema.OPERATIONS.choose_starter, "the schema validates the starter operation")
end

function T.hgss_composition_registers_the_blocking_starter_task()
  local Composition = require("libs.hgss.src.script.Composition")
  local TaskRegistry = require("libs.script.src.TaskRegistry")
  local registry = TaskRegistry.new()
  Composition.registerTasks(registry)
  local ok, impl = pcall(TaskRegistry.resolveCurrent, registry, "choose_starter")
  Assert.isTrue(ok, "the starter task is registered for blocking execution")
  Assert.isTrue(type(impl) == "table", "the registered starter task is a task implementation")
end

-- ScrCmd_SetStarterChoice stores its variable operand into VAR_PLAYER_STARTER
-- and continues in the same tick (pinned scrcmd_c.c ScrCmd_SetStarterChoice:
-- ScriptGetVar, Save_VarsFlags_SetStarter, return FALSE). It needs no
-- application: the starter scene already published the party, so the command
-- is one existing variable store.
function T.starter_choice_store_is_supported_with_same_tick_timing()
  local tagged = entry(131)
  Assert.equal(tagged.disposition, "supported", "the starter-choice store is supported here")
  Assert.equal(tagged.feature, "starter", "the starter-choice store belongs to the starter family")
  Assert.isNil(tagged.deferredReason, "a supported starter command carries no deferral category")
  Assert.equal(tagged.classification, "continue_same_tick", "the starter-choice store continues like the source scene")
end

function T.starter_choice_store_lowers_to_the_starter_variable()
  local items = lowerWith(131, { 0x4001 })
  Assert.equal(#items, 1, "the starter-choice store lowers to one step")
  Assert.equal(items[1].op, "set_var", "the starter-choice store lowers to the existing variable store")
  Assert.equal(items[1].variable, "VAR_PLAYER_STARTER", "the store names the source starter variable")
  Assert.deepEqual(items[1].value, { value = "var", id = 0x4001 }, "the source value-or-variable operand rides through")
  Assert.isNil(items[1].command, "variable semantics dispatch no source opcode number")
end

-- ScrCmd_GetStarterChoice reads VAR_PLAYER_STARTER into its result variable
-- and continues in the same tick (pinned scrcmd_c.c ScrCmd_GetStarterChoice,
-- Save_VarsFlags_GetStarter). It is the read side of the choice store above.
function T.starter_choice_read_is_supported_with_same_tick_timing()
  local tagged = entry(206)
  Assert.equal(tagged.disposition, "supported", "the starter-choice read is supported here")
  Assert.isNil(tagged.deferredReason, "a supported starter command carries no deferral category")
  Assert.equal(tagged.classification, "continue_same_tick", "the starter-choice read continues like the source scene")
end

function T.starter_choice_read_copies_the_starter_variable_into_the_result()
  local items = lowerWith(206, { 0x4001 })
  Assert.equal(#items, 1, "the starter-choice read lowers to one step")
  Assert.equal(items[1].op, "copy_var", "the starter-choice read reuses the variable copy")
  Assert.deepEqual(items[1].destination, { value = "var", id = 0x4001 }, "the source result operand rides through")
  Assert.equal(items[1].source, "VAR_PLAYER_STARTER", "the read names the source starter variable")
end

-- The lowered store and read round-trip through the production runtime
-- semantics: the value the store wrote is what the read reports.
function T.starter_choice_store_then_read_round_trips_through_the_runtime()
  local Runtime = require("libs.script.src.Runtime")
  local RuntimeValues = require("libs.hgss.src.script.RuntimeValues")
  local world = {
    vars = {},
    getVar = function(self, id)
      return self.vars[id] or 0
    end,
    setVar = function(self, id, value)
      self.vars[id] = value
    end,
  }
  local run = {
    instance = { scriptId = "test.starter", locals = {}, textArgs = {} },
    services = { world = world },
    semantics = RuntimeValues,
  }
  local store = lowerWith(131, { 2 })[1]
  local read = lowerWith(206, { 0x4001 })[1]
  Assert.equal(Runtime.executeNode(store, run), Runtime.OUTCOME_CONTINUE)
  Assert.equal(Runtime.executeNode(read, run), Runtime.OUTCOME_CONTINUE)
  Assert.equal(world.vars[0x4001], 2, "the read reports the stored starter")
end

return { tests = T }
