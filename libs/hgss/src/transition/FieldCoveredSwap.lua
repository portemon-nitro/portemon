-- Owns one direct map replacement under cover already supplied by its caller.

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.script.src.errors")
local FieldTransition = require("libs.hgss.src.transition.FieldTransition")

---@class FieldCoveredSwap
---@field loader table<string, unknown>
---@field transition table<string, unknown>
---@field sourceMap table<string, unknown>
---@field pending boolean
---@field failure unknown|nil
local FieldCoveredSwap = {}
FieldCoveredSwap.__index = FieldCoveredSwap

function FieldCoveredSwap.new(opts)
  assert(
    type(opts) == "table" and opts.loader and opts.transition and opts.sourceMap,
    "covered swap dependencies are required"
  )
  return setmetatable({
    loader = opts.loader,
    transition = opts.transition,
    sourceMap = opts.sourceMap,
    pending = false,
    failure = nil,
  }, FieldCoveredSwap)
end

function FieldCoveredSwap:setSourceMap(sourceMap)
  self.sourceMap = sourceMap
end

function FieldCoveredSwap:start(target)
  assert(not self.pending, "a covered map swap is already in progress")
  local destination, loadErr = self.loader:load(target.map)
  if destination == nil or destination.mapId == nil then
    Errors.raise(
      ScriptErrors.SCRIPT_INVALID_REFERENCE,
      "covered swap target map is unavailable: " .. tostring(target.map),
      {
        map = target.map,
        cause = loadErr,
      }
    )
  end
  local loadedMap = destination --[[@as table<string, unknown>]]
  local origin = loadedMap.coordinateOrigin
  if type(origin) ~= "table" or type(origin.x) ~= "number" or type(origin.z) ~= "number" then
    Errors.raise(
      ScriptErrors.SCRIPT_INVALID_REFERENCE,
      "covered swap target has no coordinate origin",
      { map = target.map }
    )
  end
  local coordinateOrigin = origin --[[@as table<string, number>]]
  local warpId = target.warp or 0
  local warp = {
    index = warpId,
    x = coordinateOrigin.x + target.fieldX,
    z = coordinateOrigin.z + target.fieldZ,
    destinationMapId = assert(loadedMap.mapId) --[[@as number]],
    destinationWarpId = warpId,
    direct = true,
  }
  self.pending = true
  self.failure = nil
  self.transition:startCoveredSwap(self.sourceMap, { warp = warp }, target.facing)
end

function FieldCoveredSwap:done()
  if not self.pending then
    return false
  end
  if self.transition.error ~= nil then
    self.failure = self.transition.error
    self.pending = false
    return true
  end
  if self.transition.phase == FieldTransition.PHASES.idle and self.transition.sourceMap == nil then
    self.pending = false
    return true
  end
  return false
end

function FieldCoveredSwap:error()
  return self.failure
end

return FieldCoveredSwap
