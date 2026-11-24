-- Blocks the source script while the native Summary application runs: the
-- scripted Summary (352), the move-selection page a machine or tutor opens
-- (352 mode 1) and the deletion picker OpenLearnForgetMove (394). The task
-- owns the source order around the screen -- open the care child, run it on the
-- fixed tick, park the semantic answer -- and the paired result command owns
-- the native translation (the picker's 4), the final party slot and the
-- one-time consumption. The screen itself, its presentation lease and its
-- canonical publication policy belong to the field's care host.
--
-- Retail sources (tmp/refs/pokeheartgold): src/scrcmd_c.c
-- (ScrCmd_PokemonSummaryScreen, ScrCmd_GetMoveSelection),
-- src/scrcmd_move_relearner.c (ScrCmd_OpenLearnForgetMove,
-- ScrCmd_GetLearnForgetMoveResult) and src/pokemon_summary.c.

local Errors = require("libs.errors.src.Errors")
local PokemonCareInterface = require("libs.hgss.src.ui.PokemonCareInterface")
local ScriptErrors = require("libs.script.src.errors")

local SummaryApplicationTask = {}
SummaryApplicationTask.type = "summary_application"
SummaryApplicationTask.version = 1

-- The parked semantic answer the paired result command reads exactly once.
SummaryApplicationTask.PARKED_KEY = "__summary_application"

local STAGES = {
  APPLICATION = "application",
  COMPLETE = "complete",
}

---@param ctx table<string, unknown>
---@param key string
---@return table<string, unknown>
local function service(ctx, key)
  local value = ctx.services and ctx.services[key]
  if type(value) ~= "table" then
    Errors.raise(ScriptErrors.SCRIPT_SERVICE_MISSING, "the Summary application requires " .. key, {
      scriptId = ctx.instance and ctx.instance.scriptId,
    })
  end
  return value
end

---@param spec table<string, unknown>
---@param ctx table<string, unknown>
---@return table<string, unknown>
function SummaryApplicationTask.create(spec, ctx)
  assert(type(spec) == "table", "the Summary application requires its request")
  local request = spec.request
  if type(request) ~= "table" then
    Errors.raise(ScriptErrors.SCRIPT_INVALID_REFERENCE, "the Summary application requires its mode", {
      scriptId = ctx.instance and ctx.instance.scriptId,
    })
  end
  local slot = request.slot
  if type(slot) ~= "number" or slot % 1 ~= 0 or slot < 0 or slot > 5 then
    Errors.raise(ScriptErrors.SCRIPT_INVALID_REFERENCE, "the Summary application names a party slot", {
      scriptId = ctx.instance and ctx.instance.scriptId,
      slot = slot,
    })
  end
  local care = service(ctx, "pokemonCare")
  local mons = service(ctx, "mons")
  local revision = mons:partyRevision()
  care:open({
    kind = PokemonCareInterface.KINDS.summary_application,
    mode = assert(request.mode, "the Summary application names its mode"),
    slot = slot,
    revision = revision,
    moveToLearn = request.moveToLearn,
  })
  return { stage = STAGES.APPLICATION, slot = slot, revision = revision }
end

-- Parks the screen's detached answer on the script instance: the paired
-- result command owns the native encoding and clears it.
---@param state table<string, unknown>
---@param ctx table<string, unknown>
---@param result table<string, unknown>
local function parkResult(state, ctx, result)
  local instance = assert(ctx.instance, "the Summary application runs on a script instance")
  assert(type(instance.locals) == "table", "the script instance carries locals")
  instance.locals[SummaryApplicationTask.PARKED_KEY] = {
    partySlot = assert(result.partySlot, "the Summary application answers its final party slot"),
    moveSlot = result.moveSlot,
    cancelled = result.cancelled == true,
  }
  state.stage = STAGES.COMPLETE
end

---@param state table<string, unknown>
---@param ctx table<string, unknown>
---@return table<string, unknown>
function SummaryApplicationTask.poll(state, ctx)
  if state.stage == STAGES.COMPLETE then
    return { complete = true, state = state }
  end
  assert(state.stage == STAGES.APPLICATION, "unknown Summary application stage")
  local care = service(ctx, "pokemonCare")
  local handle = assert(care:activeHandle(), "the Summary application owns its child")
  care:step(handle, ctx.input)
  local result = care:result(handle)
  if result == nil then
    return { complete = false, state = state }
  end
  parkResult(state, ctx, result)
  care:close(handle)
  return { complete = true, state = state }
end

-- A torn-down script closes the screen without answering: the parked result
-- stays absent, so its paired command faults instead of reading a guess.
---@param state table<string, unknown>
---@param reason string
---@param ctx table<string, unknown>|nil
function SummaryApplicationTask.cancel(state, reason, ctx)
  state.cancelled = reason
  if ctx == nil or state.stage == STAGES.COMPLETE then
    return
  end
  local care = ctx.services and ctx.services.pokemonCare
  if type(care) == "table" and type(care.isActive) == "function" and care:isActive() then
    care:cancel(reason)
  end
  state.stage = STAGES.COMPLETE
end

---@param state unknown
---@return Errors.Error|nil
function SummaryApplicationTask.validate(state)
  if type(state) ~= "table" then
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "Summary task state must be a record", {})
  end
  local typed = state --[[@as table<string, unknown>]]
  if typed.stage ~= STAGES.APPLICATION and typed.stage ~= STAGES.COMPLETE then
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "Summary task stage is invalid", {})
  end
  if type(typed.slot) ~= "number" or typed.slot % 1 ~= 0 or typed.slot < 0 or typed.slot > 5 then
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "Summary task slot must be 0..5", {})
  end
  if type(typed.revision) ~= "number" or typed.revision % 1 ~= 0 then
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "Summary task carries its party revision", {})
  end
  return nil
end

return SummaryApplicationTask
