-- Definitions for scripts owned by the runtime rather than the generated ROM
-- corpus or the mod override layer. These resources still use the normal
-- script compiler and scheduler path.

local S = require("gen4.script")
local Bindings = require("libs.hgss.src.script.Bindings")
local LuaWriter = require("libs.codec.src.LuaWriter")
local Sha256 = require("libs.script.src.Sha256")

local BuiltinScripts = {}

-- The runtime-owned menu-to-field entry script id: claims the queued
-- field request into serializable task state through the existing
-- foreground scheduler. One script for every move and slot; no per-move
-- scripts and no temporary global variables.
BuiltinScripts.FIELD_MOVE_ENTRY_SCRIPT = "runtime.field_move_entry"

-- The runtime-owned Sweet Scent script (a field task in the source, with no
-- script of its own): the scent task, then a wild battle for a prepared
-- encounter or the faded-weather / nothing-happened standard message.
BuiltinScripts.SWEET_SCENT_SCRIPT = "runtime.sweet_scent"

-- The standard scripts the source queues after the scent task: 2018 says
-- nothing happened, 2019 says the scent faded.
local NOTHING_HAPPENED_SCRIPT = "common.honey_sweet_scent_nothing_happened"
local SCENT_FADED_SCRIPT = "common.honey_sweet_scent_faded"

local function sweetScentSteps()
  local outcome = S.local_("outcome")
  return {
    S.sweetScent({ result = outcome }),
    S.if_({
      condition = S.eq(outcome, 2),
      yes = { S.battleLaunch({ kind = "wild" }) },
      no = {
        S.if_({
          condition = S.eq(outcome, 1),
          yes = { S.callCommon({ target = SCENT_FADED_SCRIPT }) },
          no = { S.callCommon({ target = NOTHING_HAPPENED_SCRIPT }) },
        }),
      },
    }),
  }
end

---@return table<string, table<string, unknown>>
function BuiltinScripts.all()
  return {
    [Bindings.CANONICAL_INERT_SCRIPT] = S.script({
      api = 1,
      id = Bindings.CANONICAL_INERT_SCRIPT,
      steps = { S.stop() },
    }),
    [BuiltinScripts.FIELD_MOVE_ENTRY_SCRIPT] = S.script({
      api = 1,
      id = BuiltinScripts.FIELD_MOVE_ENTRY_SCRIPT,
      steps = { S.fieldMove({ source = "pending" }) },
    }),
    [BuiltinScripts.SWEET_SCENT_SCRIPT] = S.script({
      api = 1,
      id = BuiltinScripts.SWEET_SCENT_SCRIPT,
      locals = { outcome = "integer" },
      steps = sweetScentSteps(),
    }),
  }
end

-- The digest covers the executable builtin projection, including ids and
-- script data, with the same deterministic serializer used by registry
-- fingerprints.
---@return string
function BuiltinScripts.contentHash()
  return Sha256.hex(LuaWriter.encode(BuiltinScripts.all()))
end

return BuiltinScripts
