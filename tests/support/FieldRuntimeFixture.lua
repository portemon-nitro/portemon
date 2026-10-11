-- Supplies the date collaborators required by FieldRuntime-only test doubles.

local FieldRuntimeFixture = {}

function FieldRuntimeFixture.withApricornDateOwner(runtime)
  runtime.localClock = runtime.localClock or {
    nowLocal = function()
      return { year = 2000, month = 1, day = 1, hour = 12, minute = 0, second = 0 }
    end,
  }
  runtime.martService = runtime.martService or {
    processApricornDate = function()
      return { advanced = false }
    end,
  }
  return runtime
end

return FieldRuntimeFixture
