-- Strict persisted state for the retail LocalFieldData poison step
-- counter: the 0..3 phase behind field poison damage every fourth
-- committed step. The bucket carries exactly its schema and the counter,
-- rejects malformed records without repairing them, and round-trips
-- through capture/restore. A missing bucket restores to the defined
-- initial phase so pre-poison saves resume without shifting the cadence.
-- Pure domain module: no love dependency.

local Errors = require("libs.errors.src.Errors")
local GameSaveErrors = require("libs.hgss.src.save.GameSaveErrors")

---@class FieldPoisonSave
local FieldPoisonSave = {}

FieldPoisonSave.SCHEMA = "hgss-field-poison-v1"

---@param message string
---@param context table<string, unknown>?
local function fail(message, context)
  Errors.raise(GameSaveErrors.GAME_SAVE_BUCKET_INVALID, message, context or {})
end

---@return table<string, unknown> the defined initial phase
function FieldPoisonSave.initial()
  return { schema = FieldPoisonSave.SCHEMA, steps = 0 }
end

---@param bucket unknown
---@return table<string, unknown> canonical detached shape
local function checkShape(bucket)
  if type(bucket) ~= "table" then
    fail("field poison bucket must be a table", {})
  end
  assert(type(bucket) == "table", "shape validation reads the bucket record")
  if bucket.schema ~= FieldPoisonSave.SCHEMA then
    fail("field poison schema must be " .. FieldPoisonSave.SCHEMA, { schema = bucket.schema })
  end
  if type(bucket.steps) ~= "number" or bucket.steps % 1 ~= 0 or bucket.steps < 0 or bucket.steps > 3 then
    fail("field poison steps must be an integer in 0..3", { steps = bucket.steps })
  end
  for key in pairs(bucket) do
    if key ~= "schema" and key ~= "steps" then
      fail("field poison bucket has an unknown field", { field = key })
    end
  end
  return { schema = FieldPoisonSave.SCHEMA, steps = bucket.steps }
end

-- Restores a bucket for loading: a missing bucket yields the defined
-- initial phase, a present bucket validates exactly.
---@param bucket table<string, unknown>?
---@return table<string, unknown> canonical detached record
function FieldPoisonSave.restore(bucket)
  if bucket == nil then
    return FieldPoisonSave.initial()
  end
  return checkShape(bucket)
end

-- Captures a bucket from a state owner exposing the persistable counter.
-- Only the 0..3 phase persists.
---@param state table<string, unknown>
---@return table<string, unknown>
function FieldPoisonSave.capture(state)
  if type(state) ~= "table" or type(state.capture) ~= "function" then
    fail("field poison capture needs a counter state", {})
  end
  assert(type(state) == "table", "capture reads the state owner")
  local captured = state:capture()
  if type(captured) ~= "table" then
    fail("field poison capture carries no state", {})
  end
  assert(type(captured) == "table", "capture reads the persistable fields")
  return checkShape({ schema = FieldPoisonSave.SCHEMA, steps = captured.steps })
end

return FieldPoisonSave
