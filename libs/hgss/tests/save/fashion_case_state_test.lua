-- Fashion Case accessory quantities are a strict copied save value.

local Assert = require("tests.support.Assert")
local FashionCaseState = require("libs.hgss.src.save.FashionCaseState")

local T = {}

function T.accessory_caps_capture_and_restore_are_exact()
  local state = FashionCaseState.new(FashionCaseState.empty())
  for _ = 1, 9 do
    Assert.isTrue(state:tryAdd(0))
  end
  Assert.isFalse(state:tryAdd(0))
  Assert.isTrue(state:tryAdd(61))
  Assert.isFalse(state:tryAdd(61))

  local captured = state:capture()
  local restored = FashionCaseState.new(captured)
  Assert.equal(restored:quantity(0), 9)
  Assert.equal(restored:quantity(61), 1)
  captured.counts[1] = 0
  Assert.equal(state:quantity(0), 9, "captures do not alias live quantities")
end

function T.trusted_restore_takes_ownership_without_revalidation()
  local state = FashionCaseState.new(FashionCaseState.empty())
  for _ = 1, 9 do
    Assert.isTrue(state:tryAdd(0))
  end
  Assert.isTrue(state:tryAdd(61))
  local snapshot = state:capture()

  local calls = 0
  local original = FashionCaseState.validate
  FashionCaseState.validate = function(...)
    calls = calls + 1
    return original(...)
  end
  local ok, restored = pcall(FashionCaseState.new, snapshot)
  FashionCaseState.validate = original
  Assert.isTrue(ok, "trusted Fashion Case restore succeeds")
  Assert.equal(calls, 0, "trusted Fashion Case restore must not revalidate owner state")
  Assert.deepEqual(restored:capture(), snapshot, "restored quantities capture back to the snapshot")
  Assert.equal(restored:quantity(0), 9)
  Assert.equal(restored:quantity(61), 1)
  Assert.isFalse(restored:tryAdd(0), "accessory caps still bind restored state")
  Assert.isFalse(restored:tryAdd(61))
end

function T.validation_rejects_wrong_shape_and_quantities()
  local cases = {
    function(record)
      record.schema = "old-fashion-case"
    end,
    function(record)
      record.extra = true
    end,
    function(record)
      record.counts[100] = nil
    end,
    function(record)
      record.counts[101] = 0
    end,
    function(record)
      record.counts[1] = -1
    end,
    function(record)
      record.counts[1] = 0.5
    end,
    function(record)
      record.counts[1] = 10
    end,
    function(record)
      record.counts[62] = 2
    end,
  }
  for _, corrupt in ipairs(cases) do
    local malformed = FashionCaseState.empty()
    corrupt(malformed)
    Assert.throws(function()
      FashionCaseState.validate(malformed)
    end)
  end
end

return { tests = T }
