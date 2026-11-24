-- Deferred commands fail loudly: lowering keeps the source identity and
-- the deferral dependency, and reaching the node at runtime raises a
-- structured error before any party state can change.

local Assert = require("tests.support.Assert")
local CommandCatalog = require("romdump.src.digest.script.CommandCatalog")
local Errors = require("libs.errors.src.Errors")
local Runtime = require("libs.script.src.Runtime")
local ScriptCommands = require("romdump.src.catalog.hgss.script_commands")
local ScriptErrors = require("libs.script.src.errors")
local SemanticLowering = require("romdump.src.digest.script.SemanticLowering")
local SourceCatalog = require("romdump.src.digest.script.SourceCatalog")

local T = {}

local function lowerSingle(opcode)
  local widths = CommandCatalog.widths(opcode) or {}
  local operands = {}
  for index = 1, #widths do
    operands[index] = 0
  end
  local lowered = SemanticLowering.lowerScript(
    { instructions = { { opcode = opcode, operands = operands, offset = 16 } } },
    { member = 12, scripts = {}, movements = {} },
    { stdCatalog = SourceCatalog.catalog() }
  )
  Assert.equal(#lowered.items, 1, "the deferred command lowers to one step")
  return lowered.items[1]
end

local function reachError(node)
  local ok, result = pcall(Runtime.executeNode, node, {
    instance = { scriptId = "vanilla.012.0000" },
    services = {},
  })
  Assert.isFalse(ok, "reaching a deferred command must fail")
  local failure = result --[[@as Errors.Error]]
  Assert.isTrue(Errors.is(failure), "the failure uses the structured script-error path")
  return failure
end

function T.togepi_egg_command_runs_with_its_source_timing()
  local tagged = assert(ScriptCommands.byOpcode[776])
  Assert.equal(tagged.disposition, "supported", "the egg gift runs in its source family")
  Assert.equal(tagged.classification, "continue_same_tick", "the gift continues without a wait")
  Assert.isNil(tagged.deferredReason, "the supported command carries no deferral category")
  local node = lowerSingle(776)
  Assert.equal(node.op, "give_togepi_egg", "the gift lowers to its own operation")
end

function T.a_deferred_command_keeps_its_dependency_and_fails_at_runtime()
  local tagged = assert(ScriptCommands.byOpcode[468])
  Assert.equal(tagged.disposition, "deferred", "the tutor command waits for its owner")
  Assert.equal(tagged.deferredReason, "party_special_application", "the tutor command names its dependency")
  local node = lowerSingle(468)
  Assert.equal(node.op, "unsupported", "the deferred command lowers explicitly")
  local failure = reachError(node)
  Assert.equal(failure.code, ScriptErrors.SCRIPT_UNSUPPORTED_REACHABLE, "the runtime names the reach")
  Assert.equal(failure.context.command, 468, "the error names the source command")
end

-- The exchange itself is executable now: the command lowers to its own
-- blocking operation instead of the explicit unsupported node.
function T.the_exchange_command_lowers_to_its_own_operation()
  local tagged = assert(ScriptCommands.byOpcode[473])
  Assert.equal(tagged.disposition, "supported", "the exchange runs its own application")
  Assert.equal(tagged.classification, "native_wait", "the exchange blocks the script")
  local node = lowerSingle(473)
  Assert.equal(node.op, "npc_trade_exec", "the exchange lowers to its own operation")
end

return { tests = T }
