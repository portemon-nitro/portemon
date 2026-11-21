-- Test composition of the App-owned selected-epoch CPU runtime: one decoded
-- kernel and one lazy preparation queue over a generated reader. Suites that
-- compose production consumers directly borrow this record exactly like the
-- App hands it to them; no consumer here owns or closes it.

local ResidentAssetCache = require("libs.hgss.src.field.ResidentAssetCache")
local AssetPreparationQueue = require("libs.hgss.src.presentation.AssetPreparationQueue")

local SelectedAssetRuntimeFixture = {}

local IDLE_BYTES = 64 * 1024 * 1024

-- Borrow one selected runtime over `cacheFs`. A scope-owned cleanup releases
-- the queue and clears the kernel when the suite owns the runtime; otherwise
-- the caller disposes it through `release`.
---@param cacheFs table<string, unknown>
---@param scope table? GraphicsSmoke-like scope with `own`
---@return { cacheFs: table<string, unknown>, decoded: table<string, unknown>, preparationQueue: table<string, unknown> }
---@return fun() release
function SelectedAssetRuntimeFixture.new(cacheFs, scope)
  local decoded = ResidentAssetCache.new({
    idleByteLimit = IDLE_BYTES,
    release = function(value)
      value:release()
    end,
  })
  local queue = AssetPreparationQueue.new(cacheFs, { decoded = decoded })
  local released = false
  local function release()
    if released then
      return
    end
    released = true
    queue:release()
    decoded:clear()
  end
  if scope ~= nil and type(scope.own) == "function" then
    scope:own({ release = release })
  end
  return { cacheFs = cacheFs, decoded = decoded, preparationQueue = queue }, release
end

-- The base-source acquisition capability the selected queue exposes to compact
-- consumers (message banks, collision, PCM): one rooted interest per resolved
-- resident reference, with no kernel entry and no charge.
---@param runtime { preparationQueue: table<string, unknown> }
---@return fun(reference: table<string, unknown>): table<string, unknown>
function SelectedAssetRuntimeFixture.acquireSource(runtime)
  local queue = runtime.preparationQueue
  return function(reference)
    return queue:acquireSource(reference)
  end
end

return SelectedAssetRuntimeFixture
