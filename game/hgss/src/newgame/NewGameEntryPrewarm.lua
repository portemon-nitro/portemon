-- Bounded speculative field-entry demand coordinator for later New Game
-- runs. While the Oak intro plays it keeps field planning and the field
-- runtime enrolled at near urgency, and once planning metadata is ready it
-- enrolls the exact opening bedroom closure at near through a temporary
-- metadata-only loader. It never blocks Oak: every speculative demand is
-- guarded, failures are retained only as diagnostics, and the handoff
-- preparation still promotes the same work to required and owns transfer.

local CacheFs = require("libs.storage.src.CacheFs")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local FieldMapLoader = require("libs.hgss.src.world.FieldMapLoader")

---@class NewGameEntryPrewarm
---@field versionId string selected game version, carried for diagnostics
---@field derivedAssets table<string, function>? borrowed semantic host, cleared on disposal
---@field openingLocation { mapSymbol: string, fieldX: integer, fieldZ: integer } map-local opening record
---@field loader table<string, unknown>? retained metadata-only planning loader, built once
---@field target { symbol: string, x: integer, z: integer }? retained globalized opening target
---@field diagnostic unknown? latest speculative failure, kept for diagnosis only
---@field disposed boolean
local NewGameEntryPrewarm = {}
NewGameEntryPrewarm.__index = NewGameEntryPrewarm

---@param options { versionId: string, derivedAssets: table<string, function>, openingLocation: table<string, unknown> }
---@return NewGameEntryPrewarm
function NewGameEntryPrewarm.new(options)
  assert(type(options) == "table", "entry prewarm requires its composition")
  local versionId = options.versionId
  assert(type(versionId) == "string" and versionId ~= "", "entry prewarm requires its selected version")
  local derivedAssets = options.derivedAssets
  assert(
    type(derivedAssets) == "table" and type(derivedAssets.requestMilestone) == "function",
    "entry prewarm requires its borrowed derived host"
  )
  local openingLocation = options.openingLocation
  assert(type(openingLocation) == "table", "entry prewarm requires its opening location")
  assert(type(openingLocation.mapSymbol) == "string", "entry prewarm requires a mapped opening location")
  assert(
    type(openingLocation.fieldX) == "number" and openingLocation.fieldX % 1 == 0,
    "entry prewarm requires an integer opening field position"
  )
  assert(
    type(openingLocation.fieldZ) == "number" and openingLocation.fieldZ % 1 == 0,
    "entry prewarm requires an integer opening field position"
  )
  return setmetatable({
    versionId = versionId,
    derivedAssets = derivedAssets,
    openingLocation = {
      mapSymbol = openingLocation.mapSymbol,
      fieldX = openingLocation.fieldX,
      fieldZ = openingLocation.fieldZ,
    },
    loader = nil,
    target = nil,
    diagnostic = nil,
    disposed = false,
  }, NewGameEntryPrewarm)
end

---@param name string milestone interest to observe
---@return boolean? observed ready, nil when the demand itself failed
local function requestNear(self, name)
  -- The semantic host is a plain function table (dot calls, no self).
  -- Repeating near interest re-affirms it; a raising host is a
  -- speculative failure, never an Oak failure.
  local host = self.derivedAssets
  if host == nil then
    return nil
  end
  local ok, ready, failure = pcall(host.requestMilestone, name, "near")
  if not ok then
    self.diagnostic = ready
    return nil
  end
  if failure ~= nil then
    self.diagnostic = failure
    return nil
  end
  return ready == true
end

---@return boolean built
function NewGameEntryPrewarm:_buildTarget()
  -- The same metadata-only loader shape the handoff preparation uses:
  -- structural world only, no entries, scenes, or GPU resources. A failed
  -- build stays a retained diagnostic; the next poll retries, and the
  -- authoritative required demand at the handoff surfaces a real defect.
  if self.loader ~= nil then
    return true
  end
  local host = self.derivedAssets
  if host == nil then
    return false
  end
  local okFs, cacheFsOrError = pcall(CacheFs.forVersion, self.versionId)
  if not okFs then
    self.diagnostic = cacheFsOrError
    return false
  end
  local cacheFs = cacheFsOrError
  local okWorld, worldOrError = pcall(function()
    return assert(
      cacheFs:loadLua(MapAssetCache.worldPath()),
      "field world metadata is unavailable although entry planning is ready"
    )
  end)
  if not okWorld then
    self.diagnostic = worldOrError
    return false
  end
  local okLoader, loaderOrError = pcall(FieldMapLoader.new, cacheFs, worldOrError, { derivedAssets = host })
  if not okLoader then
    self.diagnostic = loaderOrError
    return false
  end
  local loader = loaderOrError
  local opening = self.openingLocation
  -- The opening coordinates are local to their map; the loader converts
  -- them to the same global domain normal loading uses.
  local okPosition, positionOrError = pcall(function()
    return loader:globalPosition(opening.mapSymbol, opening.fieldX, opening.fieldZ)
  end)
  if not okPosition then
    self.diagnostic = positionOrError
    pcall(function()
      loader:release()
    end)
    return false
  end
  local position = positionOrError
  self.loader = loader
  self.target = { symbol = opening.mapSymbol, x = position.x, z = position.z }
  return true
end

---@return boolean demanded
function NewGameEntryPrewarm:_demandTarget()
  -- Nonblocking near demand through the retained loader: performs no
  -- scene, terrain, or GPU acquisition. A failure is retained, never
  -- raised; the handoff repeats the same closure at required urgency.
  local target = self.target
  local loader = self.loader
  if target == nil or loader == nil then
    return false
  end
  local ok, _, failure = pcall(loader.requestLocation, loader, target.symbol, target.x, target.z, "near")
  if not ok then
    self.diagnostic = _
    return false
  end
  if failure ~= nil then
    self.diagnostic = failure
    return false
  end
  return true
end

---@return boolean enrolled whether the opening closure demand was expressed this poll
function NewGameEntryPrewarm:poll()
  if self.disposed then
    return false
  end
  local planningReady = requestNear(self, "field-planning")
  requestNear(self, "field-runtime")
  if planningReady ~= true then
    return false
  end
  if not self:_buildTarget() then
    return false
  end
  return self:_demandTarget()
end

---@param location table<string, unknown>? finalized candidate location
---@return boolean enrolled whether the finalized target is enrolled speculative
function NewGameEntryPrewarm:ensureFinalTarget(location)
  -- The handoff calls this with the finalized candidate location before
  -- installing field preparation: a matching target is already enrolled,
  -- a diverging one enrolls here at near, and an unavailable loader (or a
  -- malformed record) simply defers to the authoritative required demand.
  if self.disposed then
    return false
  end
  if type(location) ~= "table" or type(location.mapSymbol) ~= "string" then
    return false
  end
  if type(location.fieldX) ~= "number" or type(location.fieldZ) ~= "number" then
    return false
  end
  local loader = self.loader
  if loader == nil then
    return false
  end
  local okPosition, positionOrError = pcall(function()
    return loader:globalPosition(location.mapSymbol, location.fieldX, location.fieldZ)
  end)
  if not okPosition then
    self.diagnostic = positionOrError
    return false
  end
  local position = positionOrError
  local target = self.target
  if target ~= nil and target.symbol == location.mapSymbol and target.x == position.x and target.z == position.z then
    return true
  end
  local ok, _, failure = pcall(loader.requestLocation, loader, location.mapSymbol, position.x, position.z, "near")
  if not ok then
    self.diagnostic = _
    return false
  end
  if failure ~= nil then
    self.diagnostic = failure
    return false
  end
  return true
end

function NewGameEntryPrewarm:dispose()
  -- The retained planning loader is owned here (never borrowed from the
  -- handoff factory), so it is released exactly once; the borrowed
  -- semantic host stays with the route.
  if self.disposed then
    return
  end
  self.disposed = true
  local loader = self.loader
  self.loader = nil
  self.target = nil
  self.derivedAssets = nil
  if loader ~= nil then
    pcall(function()
      loader:release()
    end)
  end
end

return NewGameEntryPrewarm
