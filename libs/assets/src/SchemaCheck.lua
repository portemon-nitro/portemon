-- Shared structural-guard primitives for the generated/mod-facing asset
-- schemas (Mon, Party, Bag, Item). Every schema owns its own field
-- vocabulary and domain rules; this module owns only the identical
-- unknown-field, record-shape, bounded-integer, non-empty-string, and
-- hash-shape checks that each schema previously reimplemented. Callers
-- supply their own error code so rejections keep each schema's identity.

local Errors = require("libs.errors.src.Errors")
local Validate = require("libs.assets.src.Validate")

local SchemaCheck = {}

---@param code string
---@param message string
---@param context table<string, unknown>?
function SchemaCheck.fail(code, message, context)
  Errors.raise(code, message, context or {})
end

-- Fails on the first key in `record` absent from `allowed`. `what`, when
-- given, prefixes the message with the record's own name; otherwise the
-- message names only the field.
---@param record table<string, unknown>
---@param allowed table<string, true>
---@param context table<string, unknown>?
---@param code string
---@param what string?
function SchemaCheck.checkKeys(record, allowed, context, code, what)
  for key in pairs(record) do
    if allowed[key] == nil then
      local message = what and (what .. " carries an unknown field " .. tostring(key))
        or ("unknown field " .. tostring(key))
      SchemaCheck.fail(code, message, context)
    end
  end
end

-- One record guard shared by every manifest/catalog record: the value must
-- be a table, and when `allowed` is given it must carry only allowed keys.
---@param value unknown
---@param allowed table<string, true>?
---@param context table<string, unknown>?
---@param code string
---@param what string
---@param noun string?
function SchemaCheck.checkRecord(value, allowed, context, code, what, noun)
  if type(value) ~= "table" then
    SchemaCheck.fail(code, what .. " must be " .. (noun or "a record"), context)
  end
  if allowed ~= nil then
    SchemaCheck.checkKeys(value, allowed, context, code)
  end
end

-- One bounded-integer guard. `expectation`, when given, replaces the
-- auto-generated range wording with the caller's own phrase (for example
-- "a non-negative integer"); otherwise the message states the bounds that
-- were actually supplied.
---@param value unknown
---@param context table<string, unknown>?
---@param code string
---@param field string
---@param lower number?
---@param upper number?
---@param expectation string?
function SchemaCheck.checkInteger(value, context, code, field, lower, upper, expectation)
  local invalid = type(value) ~= "number"
    or value % 1 ~= 0
    or (lower ~= nil and value < lower)
    or (upper ~= nil and value > upper)
  if not invalid then
    return
  end
  if expectation then
    SchemaCheck.fail(code, field .. " must be " .. expectation, context)
  elseif lower ~= nil and upper ~= nil then
    SchemaCheck.fail(code, field .. " must be an integer in " .. tostring(lower) .. ".." .. tostring(upper), context)
  elseif lower ~= nil then
    SchemaCheck.fail(code, field .. " must be an integer at least " .. tostring(lower), context)
  else
    SchemaCheck.fail(code, field .. " must be an integer", context)
  end
end

---@param value unknown
---@param context table<string, unknown>?
---@param code string
---@param field string
function SchemaCheck.checkNonEmptyString(value, context, code, field)
  if type(value) ~= "string" or value == "" then
    SchemaCheck.fail(code, field .. " must be a non-empty string", context)
  end
end

-- A content-address key: 40 lowercase hex characters (sha1 shape).
---@param value unknown
---@param context table<string, unknown>?
---@param code string
---@param field string
function SchemaCheck.checkHash(value, context, code, field)
  if not Validate.isSha1Key(value) then
    SchemaCheck.fail(code, field .. " must be a 40-character hex digest", context)
  end
end

return SchemaCheck
