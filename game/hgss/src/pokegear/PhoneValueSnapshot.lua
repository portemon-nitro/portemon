-- Detaches bounded phone values while preserving structured error identity.

local Errors = require("libs.errors.src.Errors")

---@param value unknown
---@return unknown
local function detach(value)
  if type(value) ~= "table" then
    return value
  end
  if Errors.is(value) then
    ---@cast value Errors.Error
    return Errors.new(value.code, value.message, detach(value.context))
  end
  local detached = {}
  for key, nested in
    pairs(value --[[@as table<unknown, unknown>]])
  do
    detached[detach(key)] = detach(nested)
  end
  return detached
end

return { detach = detach }
