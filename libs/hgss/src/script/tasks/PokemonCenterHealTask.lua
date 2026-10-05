-- Blocks the script while the field-owned healing choreography runs.

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.script.src.errors")

local PokemonCenterHealTask = {}
PokemonCenterHealTask.type = "pokemon_center_heal"
PokemonCenterHealTask.version = 1

function PokemonCenterHealTask.create(spec, ctx)
  assert(type(spec.count) == "number" and spec.count % 1 == 0 and spec.count >= 0, "center healing count is invalid")
  local flow = assert(ctx.services.pokemonCenterHeal, "pokemonCenterHeal service is unavailable")
  flow:start(spec.count)
  return { count = spec.count }
end

function PokemonCenterHealTask.poll(state, ctx)
  local flow = assert(ctx.services.pokemonCenterHeal, "pokemonCenterHeal service is unavailable")
  local status = flow:status()
  if status.error ~= nil then
    return { complete = true, state = state, result = { termination = "faulted", error = status.error } }
  end
  if status.phase == "complete" then
    return { complete = true, state = state, result = nil }
  end
  return { complete = false, state = state }
end

function PokemonCenterHealTask.cancel(_, reason, ctx)
  local flow = assert(ctx.services.pokemonCenterHeal, "pokemonCenterHeal service is unavailable")
  flow:cancel(reason)
end

function PokemonCenterHealTask.validate(state)
  if type(state) ~= "table" or type(state.count) ~= "number" or state.count % 1 ~= 0 or state.count < 0 then
    local context = { state = state }
    ---@cast context Errors.Context
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "center healing task state is invalid", context)
  end
  for key in pairs(state) do
    if key ~= "count" then
      local context = { state = state, key = key }
      ---@cast context Errors.Context
      return Errors.new(
        ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE,
        "center healing task state contains runtime state",
        context
      )
    end
  end
  return nil
end

return PokemonCenterHealTask
