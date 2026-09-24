-- Closed semantic message substitution over generated segment records. Text
-- segments contribute their literal while every other segment kind resolves
-- the binding of that exact name, so bag prompts and party lines share one
-- substitution rule without sharing range or naming policy. The template and
-- bindings stay owned by callers and are never mutated.
-- Pure module: no love dependency, no I/O.

---@class MenuTextTemplate
local MenuTextTemplate = {}

MenuTextTemplate.ERROR = {
  TEMPLATE_INVALID = "MENU_TEXT_TEMPLATE_INVALID",
}

local function fail(role, message)
  error("[" .. MenuTextTemplate.ERROR.TEMPLATE_INVALID .. "] " .. role .. ": " .. message, 0)
end

---@param value unknown
---@return boolean
local function isFiniteInteger(value)
  return type(value) == "number" and value % 1 == 0 and value ~= math.huge and value ~= -math.huge and value == value
end

-- Formats one generated prompt template over caller-resolved display facts.
-- Bindings are strings or finite integers, never callbacks: an unknown or
-- unbound segment kind, a missing literal, or an unsupported value fails.
---@param template table<string, unknown>
---@param bindings table<string, string|integer>
---@param role string?
---@return string
function MenuTextTemplate.format(template, bindings, role)
  local owner = role or "message template"
  if type(template) ~= "table" or type(template.segments) ~= "table" or #template.segments < 1 then
    fail(owner, "the template carries its segments")
  end
  if type(bindings) ~= "table" then
    fail(owner, "the template needs its bindings")
  end
  local parts = {}
  for _, segment in ipairs(template.segments) do
    if type(segment) ~= "table" or type(segment.kind) ~= "string" or segment.kind == "" then
      fail(owner, "prompt segments are named records")
    end
    if segment.kind == "text" then
      if type(segment.value) ~= "string" or segment.value == "" then
        fail(owner, "text segments carry a literal")
      end
      parts[#parts + 1] = segment.value
    else
      local value = bindings[segment.kind]
      if type(value) == "string" then
        if value == "" then
          fail(owner, "segment " .. segment.kind .. " needs its display value")
        end
        parts[#parts + 1] = value
      elseif isFiniteInteger(value) then
        parts[#parts + 1] = tostring(value)
      else
        fail(owner, "segment " .. segment.kind .. " needs its display value")
      end
    end
  end
  return table.concat(parts)
end

return MenuTextTemplate
