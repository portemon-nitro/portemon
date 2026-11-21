-- The persisted follower inhibit bit: the closed bucket that keeps the
-- partner actor hidden while something other than the follower owns it. The
-- bucket carries exactly its schema and the boolean, rejects malformed
-- records without repairing them, and round-trips through capture/restore.
-- A save without the bucket shows the follower, which is what every record
-- written before the bucket existed owed. Inhibition is never derived from a
-- species, costume, or story flag. Pure domain module: no love dependency.

local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.hgss.src.field.FieldErrors")

---@class FollowingMonState
---@field private _inhibited boolean
local FollowingMonState = {}
FollowingMonState.__index = FollowingMonState

FollowingMonState.SCHEMA = "hgss-following-mon-v1"

---@param message string
---@param context table<string, unknown>?
local function fail(message, context)
  Errors.raise(FieldErrors.FIELD_GYM_MECHANISM_INVALID, message, context or {})
end

---@param bucket unknown
---@return boolean
local function checkInhibited(bucket)
  if type(bucket) ~= "table" then
    fail("following-mon bucket must be a record", {})
  end
  assert(type(bucket) == "table", "following-mon validation reads the record")
  if bucket.schema ~= FollowingMonState.SCHEMA then
    fail("following-mon bucket schema must be " .. FollowingMonState.SCHEMA, { schema = tostring(bucket.schema) })
  end
  if type(bucket.inhibited) ~= "boolean" then
    fail("following-mon inhibited flag must be a boolean", { inhibited = tostring(bucket.inhibited) })
  end
  for key in pairs(bucket) do
    if key ~= "schema" and key ~= "inhibited" then
      fail("following-mon bucket has an unknown field", { field = tostring(key) })
    end
  end
  return bucket.inhibited
end

---@return FollowingMonState
function FollowingMonState.new()
  return setmetatable({ _inhibited = false }, FollowingMonState)
end

---@param bucket unknown
---@return FollowingMonState
function FollowingMonState.restore(bucket)
  if bucket == nil then
    return FollowingMonState.new()
  end
  return setmetatable({ _inhibited = checkInhibited(bucket) }, FollowingMonState)
end

---@return boolean
function FollowingMonState:isInhibited()
  return self._inhibited
end

---@param inhibited boolean
function FollowingMonState:setInhibited(inhibited)
  if type(inhibited) ~= "boolean" then
    fail("following-mon inhibited flag must be a boolean", { inhibited = tostring(inhibited) })
  end
  self._inhibited = inhibited
end

---@return table<string, unknown>
function FollowingMonState:capture()
  return { schema = FollowingMonState.SCHEMA, inhibited = self._inhibited == true }
end

return FollowingMonState
