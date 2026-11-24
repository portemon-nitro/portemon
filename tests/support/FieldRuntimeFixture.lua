-- Supplies the date, asset-preparation and input collaborators required by
-- FieldRuntime-only test doubles.

local AssetNeedsRegistry = require("libs.hgss.src.field.AssetNeedsRegistry")

local FieldRuntimeFixture = {}

function FieldRuntimeFixture.withApricornDateOwner(runtime)
  runtime.localClock = runtime.localClock
    or {
      nowLocal = function()
        return { year = 2000, month = 1, day = 1, hour = 12, minute = 0, second = 0 }
      end,
    }
  runtime.assetNeeds = runtime.assetNeeds or AssetNeedsRegistry.new()
  runtime.martService = runtime.martService
    or {
      processApricornDate = function()
        return { advanced = false }
      end,
    }
  -- The fixed tick samples the live input owner; a double that models no player
  -- input answers the production snapshot record with no held or fresh edges.
  runtime.input = runtime.input
    or {
      snapshot = function()
        return { heldDirection = nil, actionDown = false, cancelDown = false, menuDown = false }
      end,
    }
  return runtime
end

return FieldRuntimeFixture
