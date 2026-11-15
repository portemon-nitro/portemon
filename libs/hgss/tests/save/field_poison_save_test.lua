-- Strict persisted record for the retail LocalFieldData poison step
-- counter: the 0..3 phase that fires field poison damage every fourth
-- committed step. The bucket carries exactly its schema and the counter,
-- rejects malformed records without repairing them, and round-trips
-- through capture/restore. Pure domain code.

local Assert = require("tests.support.Assert")
local FieldPoisonSave = require("libs.hgss.src.save.FieldPoisonSave")

local T = { metadata = { capabilities = {} }, tests = {} }

-- Valid buckets round-trip: the defined initial phase, a phased restore,
-- a missing bucket defaulting to phase zero, and capture output
-- restoring exactly.
function T.tests.valid_buckets_restore_and_round_trip()
  Assert.deepEqual(
    FieldPoisonSave.initial(),
    { schema = FieldPoisonSave.SCHEMA, steps = 0 },
    "new records start on poison phase zero"
  )
  local phased = FieldPoisonSave.restore({ schema = FieldPoisonSave.SCHEMA, steps = 3 })
  Assert.equal(phased.steps, 3)
  local defaulted = FieldPoisonSave.restore(nil)
  Assert.equal(defaulted.steps, 0, "pre-poison saves resume without shifting the cadence")
  Assert.deepEqual(defaulted, FieldPoisonSave.initial(), "the default is the initial record")
  local owner = {
    capture = function()
      return { steps = 2 }
    end,
  }
  local record = FieldPoisonSave.capture(owner)
  Assert.equal(record.steps, 2)
  Assert.equal(record.schema, FieldPoisonSave.SCHEMA)
  Assert.deepEqual(FieldPoisonSave.restore(record), record, "capture output restores exactly")
end

-- Malformed buckets fail validation without repair: out-of-range or
-- non-integer counters, schema mismatches, unknown fields, and non-tables.
function T.tests.malformed_counters_fail_without_repair()
  for _, steps in ipairs({ -1, 4, 1.5, "2" }) do
    local ok = pcall(FieldPoisonSave.restore, { schema = FieldPoisonSave.SCHEMA, steps = steps })
    Assert.isFalse(ok, "steps " .. tostring(steps) .. " must fail validation")
  end
  local okSchema = pcall(FieldPoisonSave.restore, { schema = "bogus", steps = 0 })
  Assert.isFalse(okSchema, "schema mismatches must fail validation")
  local okField = pcall(FieldPoisonSave.restore, { schema = FieldPoisonSave.SCHEMA, steps = 0, extra = 1 })
  Assert.isFalse(okField, "unknown fields must fail validation")
  local okTable = pcall(FieldPoisonSave.restore, "poison")
  Assert.isFalse(okTable, "non-table buckets must fail validation")
  local okCapture = pcall(FieldPoisonSave.capture, {})
  Assert.isFalse(okCapture, "capture without a counter state must fail validation")
end

return T
