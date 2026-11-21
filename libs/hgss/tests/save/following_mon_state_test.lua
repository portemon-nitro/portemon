-- The persisted follower inhibit bit: one strict schema, a boolean-only
-- record, detached capture, and malformed buckets rejected without repair.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.hgss.src.field.FieldErrors")
local FollowingMonState = require("libs.hgss.src.save.FollowingMonState")

local T = {}

function T.a_new_state_never_inhibits_the_follower()
  local state = FollowingMonState.new()
  Assert.isFalse(state:isInhibited(), "a new save shows the follower")
  Assert.deepEqual(state:capture(), { schema = FollowingMonState.SCHEMA, inhibited = false })
end

function T.restore_round_trips_the_inhibit_bit_and_rejects_malformed_buckets()
  local state = FollowingMonState.restore({ schema = FollowingMonState.SCHEMA, inhibited = true })
  Assert.isTrue(state:isInhibited())

  local cases = {
    { schema = "hgss-following-mon-v2", inhibited = true },
    { schema = FollowingMonState.SCHEMA },
    { schema = FollowingMonState.SCHEMA, inhibited = 1 },
    { schema = FollowingMonState.SCHEMA, inhibited = false, extra = true },
  }
  for index, bucket in ipairs(cases) do
    local err = Assert.throws(function()
      FollowingMonState.restore(bucket)
    end)
    Assert.isTrue(Errors.is(err), "case " .. index .. " raises a structured error")
    Assert.equal(err.code, FieldErrors.FIELD_GYM_MECHANISM_INVALID, "case " .. index .. " stays invalid")
  end
end

-- The bit is a durable owner write, so the same tick that sets it publishes
-- it and the capture follows.
function T.the_inhibit_bit_is_one_durable_write()
  local state = FollowingMonState.new()
  state:setInhibited(true)
  Assert.isTrue(state:isInhibited())
  Assert.equal(state:capture().inhibited, true)
  state:setInhibited(false)
  Assert.isFalse(state:capture().inhibited)
end

return { tests = T }
