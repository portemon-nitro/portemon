-- The source field Pokémon picture window's owner task (Screen 452/453). The
-- window itself is the field's presentation owner; this task holds the window
-- open for exactly the script environment that showed it, so a cancelled or
-- retired scene disposes its picture instead of leaving an orphan behind. The
-- close command closes the window and the task completes on its next poll, so
-- the source's own one-tick yield after the close is unchanged.
--
-- The task owns no lease of its own: the window belongs to the field's picture
-- owner, which is why an active task stays serializable.

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.script.src.errors")

local MonPictureTask = {}
MonPictureTask.type = "mon_picture"
MonPictureTask.version = 1

---@param ctx table<string, unknown>|nil
---@return table<string, unknown>
local function requirePicture(ctx)
  assert(ctx ~= nil, "the picture window task requires the task context")
  local services = assert(ctx.services, "the picture window task requires its services")
  return assert(services.monPicture, "monPicture service is unavailable")
end

---@param _ table<string, unknown>
---@param ctx table<string, unknown>
---@return table<string, unknown> state
function MonPictureTask.create(_, ctx)
  requirePicture(ctx)
  return { open = true }
end

---@param state table<string, unknown>
---@param ctx table<string, unknown>
---@return table<string, unknown> result
function MonPictureTask.poll(state, ctx)
  if requirePicture(ctx):status() == nil then
    state.open = false
    return { complete = true, state = state, result = nil }
  end
  return { complete = false, state = state }
end

-- A cancelled scene takes its picture down exactly once; the field owner
-- ignores a close of an already-closed window.
---@param state table<string, unknown>
---@param _ string?
---@param ctx table<string, unknown>|nil
function MonPictureTask.cancel(state, _, ctx)
  state.open = false
  local services = ctx ~= nil and ctx.services or nil
  if services == nil or services.monPicture == nil then
    return
  end
  services.monPicture:close()
end

---@param state table<string, unknown>
---@return Errors.Error|nil
function MonPictureTask.validate(state)
  if type(state) ~= "table" or type(state.open) ~= "boolean" then
    local context = { state = state }
    ---@cast context Errors.Context
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "picture window state is invalid", context)
  end
  return nil
end

return MonPictureTask
