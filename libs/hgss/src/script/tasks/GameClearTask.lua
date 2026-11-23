-- The League ending's blocking script task: ScrCmd_HOFCredits (163) reads one
-- raw vsRed halfword and calls CallTask_GameClear, which returns TRUE — the
-- script frame stays owned until the whole ending returned.
--
-- The task itself owns nothing: the field's one ending coordinator owns the
-- transaction, the credits and the retry, and the runtime releases the
-- suspended ending script and hands the host its main-menu route when the
-- coordinator completed. The task therefore never serializes (an active ending
-- owns presented surfaces, the suspended save candidate and the source input
-- gate) and it never writes a save directly.

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.script.src.errors")

local GameClearTask = {}
GameClearTask.type = "game_clear"
GameClearTask.version = 1

---@param ctx table<string, unknown>|nil
---@return table<string, unknown>
local function requireCoordinator(ctx)
  assert(ctx ~= nil, "the game-clear task requires the task context")
  local services = assert(ctx.services, "the game-clear task requires its services")
  return assert(services.gameClear, "gameClear service is unavailable")
end

---@param spec { vsRed: integer }
---@param ctx table<string, unknown>
---@return table<string, unknown> state
function GameClearTask.create(spec, ctx)
  assert(type(spec) == "table" and type(spec.vsRed) == "number", "the game-clear task needs its raw vsRed word")
  requireCoordinator(ctx):begin(spec.vsRed)
  return { vsRed = spec.vsRed, completed = false }
end

---@param state table<string, unknown>
---@param ctx table<string, unknown>
---@return table<string, unknown> result
function GameClearTask.poll(state, ctx)
  if state.completed then
    return { complete = true, state = state }
  end
  -- The runtime owns the fixed-tick advance and releases this environment on
  -- completion, so an observation here only confirms the ending still owns the
  -- field.
  if requireCoordinator(ctx):isActive() then
    return { complete = false, state = state }
  end
  state.completed = true
  return { complete = true, state = state }
end

-- Cancel the ending with its owning environment. Everything it published stays
-- durable; an ending closed before its publication leaves the previous save.
---@param state table<string, unknown>
---@param reason string
---@param ctx table<string, unknown>|nil
function GameClearTask.cancel(state, reason, ctx)
  if state.completed then
    return
  end
  state.completed = true
  local services = ctx ~= nil and ctx.services or nil
  if services == nil or services.gameClear == nil then
    return
  end
  services.gameClear:cancel(reason)
end

---@param state table<string, unknown>
---@return Errors.Error|nil
function GameClearTask.validate(state)
  if type(state) ~= "table" or type(state.vsRed) ~= "number" or type(state.completed) ~= "boolean" then
    local context = { state = state }
    ---@cast context Errors.Context
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "game-clear task state is invalid", context)
  end
  if not state.completed then
    local context = { vsRed = state.vsRed }
    ---@cast context Errors.Context
    return Errors.new(
      ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE,
      "an active League ending owns its presentation, save candidate and route and cannot be restored",
      context
    )
  end
  return nil
end

return GameClearTask
