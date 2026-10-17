-- Owns one direct map replacement under cover already supplied by its caller.

local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.hgss.src.field.FieldErrors")
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

-- Structural destination placement without building generated assets, so a
-- cold destination waits in the transition's async preparation instead of
-- faulting the warp start. Unknown maps keep the script-shaped
-- unavailable-destination fault; anything else propagates untouched.
---@param loader table<string, unknown>
---@param symbol string
---@return { id: integer, originX: integer, originZ: integer }
local function lookupPlacement(loader, symbol)
  local ok, placement = pcall(loader.mapPlacement, loader, symbol)
  if not ok then
    if Errors.is(placement) and placement.code == FieldErrors.FIELD_MAP_UNKNOWN then
      placement = nil
    else
      error(placement, 0)
    end
  end
  if
    type(placement) ~= "table"
    or type(placement.id) ~= "number"
    or type(placement.originX) ~= "number"
    or type(placement.originZ) ~= "number"
  then
    Errors.raise(
      ScriptErrors.SCRIPT_INVALID_REFERENCE,
      "covered swap target map is unavailable: " .. tostring(symbol),
      { map = symbol }
    )
  end
  return placement
end

function FieldCoveredSwap:start(target)
  assert(not self.pending, "a covered map swap is already in progress")
  local placement = lookupPlacement(self.loader, target.map)
  local warpId = target.warp or 0
  local warp = {
    index = warpId,
    x = placement.originX + target.fieldX,
    z = placement.originZ + target.fieldZ,
    destinationMapId = placement.id,
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
