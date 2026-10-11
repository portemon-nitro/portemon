-- Nitro joint-SRT dispatch: turns one NODEDESC's decoded node record into the
-- local matrix the geometry engine would have accumulated for it. This is the
-- composition both pose evaluators share: NsbmdStaticTransforms (digest-side,
-- bind pose) and NsbmdSbcEvaluator (pose-driven, animated) route every joint
-- through the same scaling-rule logic so the two paths cannot drift.
--
-- NitroSystem selects a scaling rule per model (NNSG3dResMdlInfo.scalingRule)
-- and routes every joint through a matching GetJointScale/SendJointSRT pair.
-- Each SendJointSRT emits a sequence of geometry-engine matrix commands against
-- the current matrix, so the joint's local transform is the product of those
-- commands in emission order. This module reproduces that order rather than
-- guessing an equivalent multiplication:
--
--   standard (rule 0)  cgtool/basic.c  NNSi_G3dSendJointSRTBasic
--   maya     (rule 1)  cgtool/maya.c   NNSi_G3dSendJointSRTMaya / GetJointScaleMaya
--
-- Rule 2 (Si3D) is not implemented: no model in the target world uses it, and
-- its parent-chained scale cache has no asset to validate against.
--
-- Maya's "single scale compensate" makes a joint cancel its parent's scale. The
-- per-node inverse scales that requires live in a caller-owned cache, because
-- NNS_G3dRSOnGlb.scaleCache is written as the SBC stream is walked and read by
-- later joints. Pure domain module.

local Errors = require("libs.errors.src.Errors")

local NsbmdJointTransforms = {}

---@class NsbmdJointTransforms
---@field localMatrix fun(scalingRule: integer, node: table<string, unknown>, cmd: table<string, unknown>, cache: table<integer, number[]|false>): number[]
---@field localMatrixInto fun(out: number[], scalingRule: integer, node: table<string, unknown>, cmd: table<string, unknown>, cache: table<integer, number[]|false>, operation: number[], product: number[]): number[]

NsbmdJointTransforms.STANDARD = 0
NsbmdJointTransforms.MAYA = 1
NsbmdJointTransforms.SI3D = 2

-- NNS_G3D_SBC_NODEDESC_FLAG_* (res_struct.h): byte 3 of a NODEDESC command.
local MAYASSC_APPLY = 0x01
local MAYASSC_PARENT = 0x02

---@param out number[]
---@param a number[]
---@param b number[]
---@param product number[]
local function multiplyInto(out, a, b, product)
  assert(product ~= a and product ~= b and product ~= out)
  for col = 0, 3 do
    local offset = col * 4
    local b0, b1, b2, b3 = b[offset + 1], b[offset + 2], b[offset + 3], b[offset + 4]
    product[offset + 1] = a[1] * b0 + a[5] * b1 + a[9] * b2 + a[13] * b3
    product[offset + 2] = a[2] * b0 + a[6] * b1 + a[10] * b2 + a[14] * b3
    product[offset + 3] = a[3] * b0 + a[7] * b1 + a[11] * b2 + a[15] * b3
    product[offset + 4] = a[4] * b0 + a[8] * b1 + a[12] * b2 + a[16] * b3
  end
  for i = 1, 16 do
    out[i] = product[i]
  end
end

---@param out number[]
---@param sx number
---@param sy number
---@param sz number
local function setScale(out, sx, sy, sz)
  out[1], out[2], out[3], out[4] = sx, 0, 0, 0
  out[5], out[6], out[7], out[8] = 0, sy, 0, 0
  out[9], out[10], out[11], out[12] = 0, 0, sz, 0
  out[13], out[14], out[15], out[16] = 0, 0, 0, 1
end

---@param out number[]
---@param node table<string, unknown>
local function setRotation(out, node)
  local rotation = node.rotation ---@type number[]
  out[1], out[2], out[3], out[4] = rotation[1], rotation[2], rotation[3], 0
  out[5], out[6], out[7], out[8] = rotation[4], rotation[5], rotation[6], 0
  out[9], out[10], out[11], out[12] = rotation[7], rotation[8], rotation[9], 0
  out[13], out[14], out[15], out[16] = 0, 0, 0, 1
end

---@param out number[]
---@param node table<string, unknown>
local function setTranslation(out, node)
  local translation = node.translation ---@type { x: number, y: number, z: number }
  out[1], out[2], out[3], out[4] = 1, 0, 0, 0
  out[5], out[6], out[7], out[8] = 0, 1, 0, 0
  out[9], out[10], out[11], out[12] = 0, 0, 1, 0
  out[13], out[14], out[15], out[16] = translation.x, translation.y, translation.z, 1
end

---@param out number[]
---@param operation number[]
---@param product number[]
---@param node table<string, unknown>
---@param includeTranslation boolean
---@param scaleEx0 { x: number, y: number, z: number }?
local function composeInto(out, operation, product, node, includeTranslation, scaleEx0)
  out[1], out[2], out[3], out[4] = 1, 0, 0, 0
  out[5], out[6], out[7], out[8] = 0, 1, 0, 0
  out[9], out[10], out[11], out[12] = 0, 0, 1, 0
  out[13], out[14], out[15], out[16] = 0, 0, 0, 1
  if includeTranslation and not node.transZero then
    setTranslation(operation, node)
    multiplyInto(out, out, operation, product)
  end
  if scaleEx0 then
    setScale(operation, scaleEx0.x, scaleEx0.y, scaleEx0.z)
    multiplyInto(out, out, operation, product)
  end
  if not node.rotZero then
    setRotation(operation, node)
    multiplyInto(out, out, operation, product)
  end
  if not node.scaleOne then
    local scale = node.scale ---@type { x: number, y: number, z: number }
    setScale(operation, scale.x, scale.y, scale.z)
    multiplyInto(out, out, operation, product)
  end
end

---@param v integer
---@param mask integer
---@return boolean
local function bitSet(v, mask)
  return math.floor(v / mask) % 2 == 1
end

-- NNSi_G3dGetJointScaleMaya: publish this joint's inverse scale for children
-- that compensate it, and read the parent's when this joint compensates.
-- `cache` maps node index -> inverse scale, with `false` meaning "scale is one".
---@param node table<string, unknown>
---@param cmd table<string, unknown>
---@param cache table<integer, number[]|false>
---@return number[]?
local function mayaScaleEx0(node, cmd, cache)
  if bitSet(cmd.flags, MAYASSC_PARENT) then
    cache[cmd.nodeIndex] = (not node.scaleOne) and node.inverseScale or false
  end
  if not bitSet(cmd.flags, MAYASSC_APPLY) then
    return nil
  end
  local parent = cache[cmd.parentIndex]
  -- A parent that never published a scale, or published scale one, contributes
  -- nothing: NNS_G3dRS->isScaleCacheOne starts set for every node.
  if not parent then
    return nil
  end
  return parent
end

-- Return the joint's local matrix for `model`'s scaling rule.
--   node   a decoded Nsbmd node (translation/rotation/scale, the SRT zero flags,
--          and inverseScale for the non-standard rules)
--   cmd    the NODEDESC command driving this joint (nodeIndex, parentIndex, flags)
--   cache  caller-owned Maya inverse-scale cache, mutated as joints are walked
---@param scalingRule integer
---@param node table<string, unknown>
---@param cmd table<string, unknown>
---@param cache table<integer, number[]|false>
---@return number[]
function NsbmdJointTransforms.localMatrix(scalingRule, node, cmd, cache)
  local out = {}
  return NsbmdJointTransforms.localMatrixInto(out, scalingRule, node, cmd, cache, {}, {})
end

---@param out number[]
---@param scalingRule integer
---@param node table<string, unknown>
---@param cmd table<string, unknown>
---@param cache table<integer, number[]|false>
---@param operation number[]
---@param product number[]
---@return number[]
function NsbmdJointTransforms.localMatrixInto(out, scalingRule, node, cmd, cache, operation, product)
  if scalingRule == NsbmdJointTransforms.STANDARD then
    if cmd.flags ~= 0 then
      Errors.raise(
        "NSBMD_JOINT_UNEXPECTED_NODEDESC_FLAGS",
        string.format("NODEDESC flags 0x%02X are only defined for the Maya scaling rule", cmd.flags),
        { flags = cmd.flags, nodeIndex = cmd.nodeIndex, scalingRule = scalingRule }
      )
    end
    composeInto(out, operation, product, node, true, nil)
    return out
  end

  if scalingRule == NsbmdJointTransforms.MAYA then
    if not node.scaleOne and not node.inverseScale then
      Errors.raise(
        "NSBMD_JOINT_MISSING_INVERSE_SCALE",
        "a Maya joint with a scale must carry an inverse scale",
        { nodeIndex = cmd.nodeIndex, scalingRule = scalingRule }
      )
    end
    composeInto(out, operation, product, node, true, mayaScaleEx0(node, cmd, cache))
    return out
  end

  Errors.raise(
    "NSBMD_JOINT_UNSUPPORTED_SCALING_RULE",
    "scaling rule " .. tostring(scalingRule) .. " is not implemented",
    { scalingRule = scalingRule, nodeIndex = cmd.nodeIndex }
  )
  error("unreachable")
end

return NsbmdJointTransforms
