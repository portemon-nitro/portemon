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
local Matrix4 = require("libs.math.src.Matrix4")

local NsbmdJointTransforms = {}

---@class NsbmdJointTransforms
---@field localMatrix fun(scalingRule: integer, node: table<string, unknown>, cmd: table<string, unknown>, cache: table<integer, number[]|false>): number[]
---@field localMatrixInto fun(out: number[], scalingRule: integer, node: table<string, unknown>, cmd: table<string, unknown>, cache: table<integer, number[]|false>, operation: number[], product: number[]): number[]
---@field localMatrixBufferInto fun(out: Matrix4.Buffer, scalingRule: integer, node: table<string, unknown>, cmd: table<string, unknown>, cache: table<integer, number[]|false>, operation: Matrix4.Buffer, product: Matrix4.Buffer): Matrix4.Buffer

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

---@param v integer
---@param mask integer
---@return boolean
local function bitSet(v, mask)
  return math.floor(v / mask) % 2 == 1
end

---@param out Matrix4.Buffer
---@param sx number
---@param sy number
---@param sz number
local function setScaleBuffer(out, sx, sy, sz)
  local m = out.m
  m[0], m[1], m[2], m[3] = sx, 0, 0, 0
  m[4], m[5], m[6], m[7] = 0, sy, 0, 0
  m[8], m[9], m[10], m[11] = 0, 0, sz, 0
  m[12], m[13], m[14], m[15] = 0, 0, 0, 1
end

---@param out Matrix4.Buffer
---@param node table<string, unknown>
local function setRotationBuffer(out, node)
  local rotation = node.rotation ---@type number[]
  local m = out.m
  m[0], m[1], m[2], m[3] = rotation[1], rotation[2], rotation[3], 0
  m[4], m[5], m[6], m[7] = rotation[4], rotation[5], rotation[6], 0
  m[8], m[9], m[10], m[11] = rotation[7], rotation[8], rotation[9], 0
  m[12], m[13], m[14], m[15] = 0, 0, 0, 1
end

---@param out Matrix4.Buffer
---@param node table<string, unknown>
local function setTranslationBuffer(out, node)
  local translation = node.translation ---@type { x: number, y: number, z: number }
  local m = out.m
  m[0], m[1], m[2], m[3] = 1, 0, 0, 0
  m[4], m[5], m[6], m[7] = 0, 1, 0, 0
  m[8], m[9], m[10], m[11] = 0, 0, 1, 0
  m[12], m[13], m[14], m[15] = translation.x, translation.y, translation.z, 1
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

-- Validates the NODEDESC flags and inverse-scale presence for `model`'s scaling
-- rule, updates the Maya inverse-scale cache, and resolves the two composition
-- inputs both matrix entry points share: whether the joint emits its
-- translation factor and which parent inverse scale it compensates with.
---@param scalingRule integer
---@param node table<string, unknown>
---@param cmd table<string, unknown>
---@param cache table<integer, number[]|false>
---@return boolean includeTranslation
---@return { x: number, y: number, z: number }? scaleEx0
local function resolveJointComposition(scalingRule, node, cmd, cache)
  if scalingRule == NsbmdJointTransforms.STANDARD then
    if cmd.flags ~= 0 then
      Errors.raise(
        "NSBMD_JOINT_UNEXPECTED_NODEDESC_FLAGS",
        string.format("NODEDESC flags 0x%02X are only defined for the Maya scaling rule", cmd.flags),
        { flags = cmd.flags, nodeIndex = cmd.nodeIndex, scalingRule = scalingRule }
      )
    end
    return true, nil
  end

  if scalingRule == NsbmdJointTransforms.MAYA then
    if not node.scaleOne and not node.inverseScale then
      Errors.raise(
        "NSBMD_JOINT_MISSING_INVERSE_SCALE",
        "a Maya joint with a scale must carry an inverse scale",
        { nodeIndex = cmd.nodeIndex, scalingRule = scalingRule }
      )
    end
    return true, mayaScaleEx0(node, cmd, cache)
  end

  Errors.raise(
    "NSBMD_JOINT_UNSUPPORTED_SCALING_RULE",
    "scaling rule " .. tostring(scalingRule) .. " is not implemented",
    { scalingRule = scalingRule, nodeIndex = cmd.nodeIndex }
  )
  error("unreachable")
end

---@alias NsbmdJointFactorKind "translation"|"scaleEx0"|"rotation"|"scale"

-- Emits each post-multiplied composition factor in geometry-engine emission
-- order: translation, parent inverse scale, rotation, scale. Skipped factors
-- (a zero translation, an absent compensation scale, identity rotation/scale)
-- never emit. Both storage-specific composers below consume this single driver,
-- so the factor order cannot drift between the plain-table and typed-buffer
-- paths.
---@param node table<string, unknown>
---@param includeTranslation boolean
---@param scaleEx0 { x: number, y: number, z: number }?
---@param emit fun(kind: NsbmdJointFactorKind)
local function forEachCompositionFactor(node, includeTranslation, scaleEx0, emit)
  if includeTranslation and not node.transZero then
    emit("translation")
  end
  if scaleEx0 then
    emit("scaleEx0")
  end
  if not node.rotZero then
    emit("rotation")
  end
  if not node.scaleOne then
    emit("scale")
  end
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
  forEachCompositionFactor(node, includeTranslation, scaleEx0, function(kind)
    if kind == "translation" then
      setTranslation(operation, node)
    elseif kind == "scaleEx0" then
      assert(scaleEx0 ~= nil, "scaleEx0 factor requires a cached parent inverse scale")
      local ex0 = scaleEx0
      setScale(operation, ex0.x, ex0.y, ex0.z)
    elseif kind == "rotation" then
      setRotation(operation, node)
    else
      local scale = node.scale ---@type { x: number, y: number, z: number }
      setScale(operation, scale.x, scale.y, scale.z)
    end
    multiplyInto(out, out, operation, product)
  end)
end

-- The same joint composition as composeInto, applied to typed matrix
-- workspaces: identity, then post-multiplied translation, parent inverse
-- scale, rotation and scale in emission order. `operation` carries each
-- factor while `product` stages the multiply so the output never aliases
-- an input.
---@param out Matrix4.Buffer
---@param operation Matrix4.Buffer
---@param product Matrix4.Buffer
---@param node table<string, unknown>
---@param includeTranslation boolean
---@param scaleEx0 { x: number, y: number, z: number }?
---@return Matrix4.Buffer
local function composeBufferInto(out, operation, product, node, includeTranslation, scaleEx0)
  Matrix4.identityInto(out)
  forEachCompositionFactor(node, includeTranslation, scaleEx0, function(kind)
    if kind == "translation" then
      setTranslationBuffer(operation, node)
    elseif kind == "scaleEx0" then
      assert(scaleEx0 ~= nil, "scaleEx0 factor requires a cached parent inverse scale")
      local ex0 = scaleEx0
      setScaleBuffer(operation, ex0.x, ex0.y, ex0.z)
    elseif kind == "rotation" then
      setRotationBuffer(operation, node)
    else
      local scale = node.scale ---@type { x: number, y: number, z: number }
      setScaleBuffer(operation, scale.x, scale.y, scale.z)
    end
    Matrix4.multiplyInto(product, out, operation)
    Matrix4.copyInto(out, product)
  end)
  return out
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
  local includeTranslation, scaleEx0 = resolveJointComposition(scalingRule, node, cmd, cache)
  composeInto(out, operation, product, node, includeTranslation, scaleEx0)
  return out
end

-- The joint's local matrix written directly into a typed workspace: the
-- same standard/Maya validation, scale-compensation cache handling and
-- composition order as localMatrixInto, without the 16-value roundtrip
-- through caller-owned Lua tables. `operation` and `product` are
-- caller-owned typed scratch staging each post-multiplied factor.
---@param out Matrix4.Buffer
---@param scalingRule integer
---@param node table<string, unknown>
---@param cmd table<string, unknown>
---@param cache table<integer, number[]|false>
---@param operation Matrix4.Buffer
---@param product Matrix4.Buffer
---@return Matrix4.Buffer
function NsbmdJointTransforms.localMatrixBufferInto(out, scalingRule, node, cmd, cache, operation, product)
  assert(out ~= operation and out ~= product, "localMatrixBufferInto output must not alias its scratch")
  local includeTranslation, scaleEx0 = resolveJointComposition(scalingRule, node, cmd, cache)
  composeBufferInto(out, operation, product, node, includeTranslation, scaleEx0)
  return out
end

return NsbmdJointTransforms
