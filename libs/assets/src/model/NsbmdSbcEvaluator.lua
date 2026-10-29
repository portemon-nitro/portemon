-- NsbmdSbcEvaluator: pose-driven replay of a Nitro model's SBC draw stream.
--
-- NitroSystem's SBC commands drive the DS geometry engine's matrix stack:
-- NODEDESC computes joint matrices, POSSCALE folds the model header's
-- posScale in and out, MTX restores a stored slot, and SHP issues a shape
-- draw. This evaluator replays those commands over a compiled transform
-- program (NsbmdTransformProgram on the digest side) with the node SRTs
-- supplied by a pose provider, so the same replay drives the static path
-- (bind pose) and the animated path (NSBCA poses). See GBATEK "DS Video
-- Geometry Commands" and NitroSystem g3d/sbc for the command semantics.
--
-- The pose provider contract:
--
--   poseProvider = {
--     nodeSRT(nodeIndex) -> SRT record | nil,
--         -- the effective node translation/rotation/scale/inverseScale
--         -- plus the transZero/rotZero/scaleOne flags; nil falls back to
--         -- the program's bind SRT (unaffected node)
--   }
--
-- Visibility is not part of the contract: the SBC NODE command alone
-- decides it (no provider supplies a visibility hook).
--
-- The SRT record shape matches the decoded Nsbmd node record
-- (NsbmdJointTransforms composes it under the model's scaling rule), so a
-- bind-pose provider returning the program's own nodes reproduces the static
-- evaluation exactly -- the bind-pose equivalence invariant is checked in
-- romdump/tests/nsbmd_dynamic_mesh_test.lua, and NsbmdStaticTransforms is
-- that same evaluation under the bind-pose provider.
--
-- BB cannot be resolved here, because the matrix it installs depends on the
-- camera. It is therefore reported in two halves: the position matrix the
-- command captured (`baseTransform`, pose-dependent) and the billboard marker;
-- the renderer derives camera-independent center/scale data for the shader.
-- Compiled matrix-boundary provenance is retained by the backend mesh record,
-- but is not part of this evaluated pose.
--
-- NODEMIX blends matrix-stack slots through the joints' inverse bind poses.
-- Only the position sum is reproduced; the rigid-bind-pose invariant that
-- makes the normal sum follow from it is a static program property and is
-- enforced once at compile time (NsbmdTransformProgram.compile), not per
-- evaluation frame.
--
-- Out of scope (fail loudly): BBY, external display lists (CALLDL), the
-- Si3D scaling rule, and any opcode outside the handled set (NOP and ENVMAP
-- included -- both are absent from the HGSS corpus). Matrix-stack slot reads
-- (MTX, NODEDESC restore, NODEMIX terms) are strict: a slot no command wrote
-- raises NSBMD_SBC_SLOT_NOT_FOUND rather than falling back to identity. A
-- NODEDESC whose parent matrix was never generated (parentIndex naming a
-- node whose NODEDESC has not executed) raises NSBMD_SBC_NODE_PARENT_MISSING
-- the same way -- identity is only the self-parenting root's no-source
-- matrix.
-- PRJMAP is handled as a no-op: it selects projection-map texgen state only
-- (matrix-palette entry) and never touches the position-matrix stack.
--
-- This module is pure domain: programs are decoded data, no ROM bytes are
-- read, and all dependencies are pure-domain modules.

local Errors = require("libs.errors.src.Errors")
local ErrorCodes = require("libs.assets.src.ErrorCodes")
local Matrix4 = require("libs.math.src.Matrix4")
local NsbmdJointTransforms = require("libs.assets.src.model.NsbmdJointTransforms")
local PoseContract = require("libs.assets.src.model.PoseContract")

local NsbmdSbcEvaluator = {}

---@class NsbmdSbcEvaluator.Term
---@field nodeIndex integer
---@field matrixSlot integer
---@field ratio number

---@class NsbmdSbcEvaluator.Command
---@field opcode integer
---@field offset integer
---@field name string
---@field command integer
---@field nodeIndex integer
---@field parentIndex integer
---@field matrixSlot integer
---@field storeSlot integer
---@field restoreSlot integer
---@field materialIndex integer
---@field shapeIndex integer
---@field visible boolean
---@field option integer
---@field optionBits integer
---@field inverse boolean
---@field terms NsbmdSbcEvaluator.Term[]

---@class NsbmdSbcEvaluator.Program
---@field name string
---@field commands table[]
---@field nodes table[]
---@field posScale number
---@field invPosScale number
---@field scalingRule integer
---@field evpMatrices table<integer, { invM: number[] }>?

---@class NsbmdSbcEvaluator.PoseProvider
---@field nodeSRT fun(nodeIndex: integer): table<string, unknown>?

-- The matrix-stack slot read of MTX, NODEDESC restore, and NODEMIX terms
-- must name a slot a previous command wrote. A missing slot means the
-- program restores state that was never set; replaying it as identity would
-- silently draw with a wrong matrix. Every real HGSS program and compiled
-- fixture satisfies the invariant (census: 0 unset-slot reads across 7
-- fixture programs, 640 compiled dynamic programs, and 1238 raw archive
-- members), so the raise is corpus-safe and no compiler-side validation is
-- needed.
---@param program NsbmdSbcEvaluator.Program
---@param slots table<integer, number[]>
---@param slot integer
---@param cmd table<string, unknown>
---@return number[]
local function slotAt(program, slots, slot, cmd)
  local m = slots[slot]
  if not m then
    Errors.raise(
      "NSBMD_SBC_SLOT_NOT_FOUND",
      "matrix-stack slot " .. tostring(slot) .. " was never written",
      { slot = slot, offset = cmd.offset, model = program.name }
    )
  end
  return m
end

-- The 4x3 part of a column-major matrix: the three basis columns plus the
-- translation. The implicit fourth row is (0,0,0,1), which NODEMIX never sums.
-- Zero-based cells into a typed matrix workspace.
local AFFINE_CELLS = { 0, 1, 2, 4, 5, 6, 8, 9, 10, 12, 13, 14 }

-- A pooled 1-based Lua matrix into owned typed cells. Source records stay
-- Lua; only the arithmetic staging crosses into the workspace.
---@param out Matrix4.Buffer
---@param m number[]
local function loadInto(out, m)
  assert(#m == 16, "typed matrix loads require a 16-element source")
  local cells = out.m
  for i = 0, 15 do
    cells[i] = m[i + 1]
  end
end

-- NitroSystem accumulates two independent sums for NODEMIX (sbc.c
-- NNSi_G3dFuncSbc_NODEMIX):
--   sum.M = Σ wᵢ · (positionSlot[slotᵢ] × invM[jointᵢ])
--   sum.N = Σ wᵢ · (directionSlot[slotᵢ] × invN[jointᵢ])
-- This evaluator tracks position matrices per slot only, and the direction
-- matrix of a draw is derived as the linear part of its position matrix.
-- Under that contract sum.N comes out as the linear part of sum.M, which
-- equals the SDK's result exactly when invN is the linear part of invM --
-- true of a rigid bind pose. NsbmdTransformProgram.compile rejects
-- non-rigid bind poses once at compile time, so the evaluator itself can
-- assume the property instead of blending wrong normals.

-- The blended matrix a NODEMIX command installs and stores, accumulated in
-- typed cells: each term restores its slot, post-multiplies the joint's
-- inverse bind pose, and weights the 12 affine cells into `accum`.
-- `slotBuf`/`evpBuf` stage one term's Lua sources at the arithmetic edge.
---@param program NsbmdSbcEvaluator.Program
---@param cmd table<string, unknown>
---@param matrixSlots table<integer, number[]>
---@param accum Matrix4.Buffer
---@param product Matrix4.Buffer
---@param slotBuf Matrix4.Buffer
---@param evpBuf Matrix4.Buffer
---@return Matrix4.Buffer
local function nodemixMatrix(program, cmd, matrixSlots, accum, product, slotBuf, evpBuf)
  if not program.evpMatrices then
    Errors.raise(
      "NSBMD_SBC_NODEMIX_NO_EVP_MATRICES",
      "NODEMIX needs the model's inverse bind matrices, but the program has no EvpMtx block",
      { model = program.name, offset = cmd.offset }
    )
  end
  -- NNS_G3D_ASSERT(numMtx >= 2): fewer terms would be a plain MTX restore.
  local terms = cmd.terms ---@type NsbmdSbcEvaluator.Term[]
  assert(#terms >= 2, "NODEMIX must blend at least two matrices")

  local acc = accum.m
  for i = 0, 14 do
    acc[i] = 0
  end
  acc[15] = 1
  local prod = product.m
  for _, term in ipairs(terms) do
    local evp = program.evpMatrices[term.nodeIndex]
    if not evp then
      Errors.raise(
        "NSBMD_SBC_NODEMIX_JOINT_NOT_FOUND",
        "NODEMIX references joint index " .. tostring(term.nodeIndex),
        { jointIndex = term.nodeIndex, model = program.name, offset = cmd.offset }
      )
    end
    -- The SDK restores the slot then multiplies invM into it, which in row-vector
    -- order applies invM to the vertex first.
    local evpMatrix = evp ---@type { invM: number[] }
    loadInto(slotBuf, slotAt(program, matrixSlots, term.matrixSlot, cmd))
    loadInto(evpBuf, evpMatrix.invM)
    Matrix4.multiplyInto(product, slotBuf, evpBuf)
    local weight = term.ratio / 256 -- the operand is `ratio << 4` in fx32
    for _, i in ipairs(AFFINE_CELLS) do
      acc[i] = acc[i] + weight * prod[i]
    end
  end
  return accum
end

local SUPPORTED_SCALING_RULES = {
  [NsbmdJointTransforms.STANDARD] = true,
  [NsbmdJointTransforms.MAYA] = true,
}

-- The draw record shape evaluate produces (see the function doc for the
-- billboard split).
---@class SbcDraw
---@field nodeIndex integer
---@field materialIndex integer
---@field shapeIndex integer
---@field materialReapplied boolean
---@field matrix number[] -- 16-element column-major matrix (program units)
---@field restoreStack { [integer]: number[] }
---@field transformMode TransformMode
---@field baseTransform number[]|nil -- billboard draws only
---@field _base number[]? -- scratch-owned captured base storage, reused across evaluations

---@class SbcEvaluation
---@field draws SbcDraw[]
---@field nodeMatrices { [integer]: number[] } -- NODEDESC results
---@field nodeVisibility { [integer]: boolean } -- effective NODE visibility
---@field matrixSlots { [integer]: number[] } -- the matrix-stack slots as of the
--  end of the replay, [slot] = column-major matrix (program units)

---@class NsbmdSbcEvaluator.Scratch
---@field draws SbcDraw[] -- live draw list, active prefix of drawPool
---@field drawPool SbcDraw[] -- every draw record, retained across evaluations
---@field nodeMatrices { [integer]: number[] }
---@field nodeVisibility { [integer]: boolean }
---@field matrixSlots { [integer]: number[] }
---@field result SbcEvaluation -- the live result, aliasing the tables above
---@field _mCur Matrix4.Buffer -- working position matrix
---@field _mBase Matrix4.Buffer -- working NODEDESC base matrix, one term's NODEMIX slot source
---@field _mBill Matrix4.Buffer -- working captured billboard matrix
---@field _mLocal Matrix4.Buffer -- working joint-local matrix, one term's NODEMIX inverse bind pose
---@field _mJointOp Matrix4.Buffer -- joint factor staging, POSSCALE factor
---@field _mJointProd Matrix4.Buffer -- joint multiply staging
---@field _mTmp Matrix4.Buffer -- NODEDESC/POSSCALE/NODEMIX product staging
---@field _mMixAccum Matrix4.Buffer -- NODEMIX weighted accumulation
---@field _hasBillboard boolean
---@field _mayaCache table<integer, number[]|false>
---@field _slotVersionPool table<integer, number[]> -- each write version, retained across evaluations
---@field _slotWriteCount integer
---@field _nodePool table<integer, number[]> -- every node-matrix table, retained across evaluations

local function freshMatrix()
  return { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 }
end

-- The pooled matrix at `key`: `pool` retains the table across evaluations
-- while `live` only references it for the current replay. Clearing `live`
-- each evaluation is allocation-free; the pool keeps every table.
---@param pool table<integer, number[]>
---@param live table<integer, number[]>
---@param key integer
---@return number[]
local function reusablePooled(pool, live, key)
  local m = pool[key]
  if not m then
    m = freshMatrix()
    pool[key] = m
  end
  live[key] = m
  return m
end

-- Record `slot`'s new version from typed cells: the write obtains the next
-- pooled 1-based output, materialized before any draw references it, so a
-- later rewrite never mutates an earlier snapshot.
---@param scratch NsbmdSbcEvaluator.Scratch
---@param matrixSlots table<integer, number[]>
---@param slot integer
---@param matrix Matrix4.Buffer
local function storeSlotVersion(scratch, matrixSlots, slot, matrix)
  scratch._slotWriteCount = scratch._slotWriteCount + 1
  local version = scratch._slotVersionPool[scratch._slotWriteCount]
  if not version then
    version = freshMatrix()
    scratch._slotVersionPool[scratch._slotWriteCount] = version
  end
  Matrix4.toArrayBufferInto(version, matrix)
  matrixSlots[slot] = version
end

-- Owner-held reusable storage for one transform program. Draw records,
-- node/slot matrices, and the result containers are allocated here (or on
-- the cold first evaluation when a foreign program names more state) and
-- only overwritten afterwards, so warmed replays reuse every output
-- container. A scratch is sized from the program passed to newScratch;
-- evaluating a different program with it only allocates for the growth.
---@param program NsbmdSbcEvaluator.Program
---@return NsbmdSbcEvaluator.Scratch
function NsbmdSbcEvaluator.newScratch(program)
  assert(
    type(program) == "table" and program.commands ~= nil,
    "NsbmdSbcEvaluator.newScratch requires a transform program"
  )
  -- The draw capacity is the SHP count: visibility only shrinks the active
  -- prefix, so prebuilt records cover every warmed evaluation.
  local drawCapacity = 0
  for _, rawCmd in ipairs(program.commands) do
    ---@cast rawCmd NsbmdSbcEvaluator.Command
    local cmd = rawCmd
    if cmd.opcode == 0x05 then
      drawCapacity = drawCapacity + 1
    end
  end
  local scratch = {
    draws = {},
    drawPool = {},
    nodeMatrices = {},
    nodeVisibility = {},
    matrixSlots = {},
    result = {},
    _mCur = Matrix4.newBuffer(),
    _mBase = Matrix4.newBuffer(),
    _mBill = Matrix4.newBuffer(),
    _mLocal = Matrix4.newBuffer(),
    _mJointOp = Matrix4.newBuffer(),
    _mJointProd = Matrix4.newBuffer(),
    _mTmp = Matrix4.newBuffer(),
    _mMixAccum = Matrix4.newBuffer(),
    _hasBillboard = false,
    _mayaCache = {},
    _slotVersionPool = {},
    _slotWriteCount = 0,
    _nodePool = {},
  }
  for _ = 1, drawCapacity do
    scratch.drawPool[#scratch.drawPool + 1] = {
      nodeIndex = 0,
      materialIndex = 0,
      shapeIndex = 0,
      materialReapplied = false,
      matrix = freshMatrix(),
      restoreStack = {},
      transformMode = PoseContract.STATIC,
      baseTransform = nil,
      _base = freshMatrix(),
    }
  end
  scratch.result = {
    draws = scratch.draws,
    nodeMatrices = scratch.nodeMatrices,
    nodeVisibility = scratch.nodeVisibility,
    matrixSlots = scratch.matrixSlots,
  }
  return scratch
end

-- Replay the SBC stream of `program` with `poseProvider` into `scratch` and
-- return the live result. This is the single opcode implementation: the
-- allocating evaluate below snapshots this replay, so the two paths cannot
-- drift. Repeated calls with the same topology reuse the same result, draw
-- list, draw records, and matrix containers; visibility changes shrink the
-- active draw prefix (surplus entries are cleared) and reappearance reuses
-- the retained records.
--
-- For a billboard draw, `matrix` holds only what the stream accumulated
-- after the BB command (normally identity), so the shape's vertices stay in
-- billboard-local space; `baseTransform` is the matrix BB captured, from
-- which the runtime takes the translation and per-axis scale.
---@param program NsbmdSbcEvaluator.Program
---@param poseProvider NsbmdSbcEvaluator.PoseProvider
---@param scratch NsbmdSbcEvaluator.Scratch
---@return SbcEvaluation
function NsbmdSbcEvaluator.evaluateInto(program, poseProvider, scratch)
  assert(
    type(program) == "table" and program.commands ~= nil,
    "NsbmdSbcEvaluator.evaluateInto requires a transform program"
  )
  assert(
    type(poseProvider) == "table" and poseProvider.nodeSRT ~= nil,
    "NsbmdSbcEvaluator.evaluateInto requires a pose provider with nodeSRT"
  )
  assert(type(scratch) == "table" and scratch.draws ~= nil, "NsbmdSbcEvaluator.evaluateInto requires evaluator scratch")

  local scalingRule = program.scalingRule
  if not SUPPORTED_SCALING_RULES[scalingRule] then
    Errors.raise(
      "NSBMD_SBC_UNSUPPORTED_SCALING_RULE",
      "only the standard (0) and Maya (1) scaling rules are supported by SBC evaluation",
      { scalingRule = scalingRule, model = program.name }
    )
  end

  local matrixSlots = scratch.matrixSlots
  local nodeMatrices = scratch.nodeMatrices
  local nodeVisibility = scratch.nodeVisibility
  for key in pairs(nodeVisibility) do
    nodeVisibility[key] = nil
  end
  -- The slot and node tables accumulate writes as the stream walks; each
  -- replay starts empty exactly like the allocating path. The pooled tables
  -- stay retained, so clearing and re-referencing them allocates nothing
  -- once warm.
  for key in pairs(matrixSlots) do
    matrixSlots[key] = nil
  end
  scratch._slotWriteCount = 0
  for key in pairs(nodeMatrices) do
    nodeMatrices[key] = nil
  end
  local currentMatrix = scratch._mCur
  local baseWork = scratch._mBase
  local billboardWork = scratch._mBill
  Matrix4.identityInto(currentMatrix)
  local hasBillboard = false
  local currentNode = 0
  local currentMaterial = 0
  local materialReapplied = true
  -- Written by joints flagged MAYASSC_PARENT and read by their children; the
  -- SDK keeps the equivalent state in NNS_G3dRSOnGlb.scaleCache for one walk.
  local mayaScaleCache = scratch._mayaCache
  for key in pairs(mayaScaleCache) do
    mayaScaleCache[key] = nil
  end

  local draws = scratch.draws
  local drawPool = scratch.drawPool
  local activeCount = 0

  for _, rawCmd in ipairs(program.commands) do
    ---@cast rawCmd NsbmdSbcEvaluator.Command
    local cmd = rawCmd
    local op = cmd.opcode ---@type integer

    if op == 0x01 then -- RET
      break
    elseif op == 0x02 then -- NODE
      currentNode = cmd.nodeIndex
      nodeVisibility[cmd.nodeIndex] = cmd.visible
    elseif op == 0x03 then -- MTX
      loadInto(currentMatrix, slotAt(program, matrixSlots, cmd.matrixSlot, cmd))
      hasBillboard = false
    elseif op == 0x04 then -- MAT
      currentMaterial = cmd.materialIndex
      materialReapplied = true
    elseif op == 0x05 then -- SHP
      if nodeVisibility[currentNode] ~= false then
        activeCount = activeCount + 1
        local record = drawPool[activeCount]
        if not record then
          record = {
            nodeIndex = 0,
            materialIndex = 0,
            shapeIndex = 0,
            materialReapplied = false,
            matrix = freshMatrix(),
            restoreStack = {},
            transformMode = PoseContract.STATIC,
            baseTransform = nil,
            _base = freshMatrix(),
          }
          drawPool[activeCount] = record
        end
        record.nodeIndex = currentNode
        record.materialIndex = currentMaterial
        record.shapeIndex = cmd.shapeIndex
        record.materialReapplied = materialReapplied
        Matrix4.toArrayBufferInto(record.matrix, currentMatrix)
        local restoreStack = record.restoreStack
        for slot, slotMatrix in pairs(matrixSlots) do
          restoreStack[slot] = slotMatrix
        end
        for slot in pairs(restoreStack) do
          if matrixSlots[slot] == nil then
            restoreStack[slot] = nil
          end
        end
        if hasBillboard then
          Matrix4.toArrayBufferInto(record._base, billboardWork)
          record.baseTransform = record._base
          record.transformMode = PoseContract.BILLBOARD
        else
          record.baseTransform = nil
          record.transformMode = PoseContract.STATIC
        end
        draws[activeCount] = record
      end
      materialReapplied = false
    elseif op == 0x06 then -- NODEDESC
      local srt = poseProvider.nodeSRT(cmd.nodeIndex) or program.nodes[cmd.nodeIndex + 1]
      if not srt then
        Errors.raise(
          "NSBMD_SBC_NODE_NOT_FOUND",
          "NODEDESC references node index " .. tostring(cmd.nodeIndex),
          { nodeIndex = cmd.nodeIndex, model = program.name }
        )
      end

      if cmd.restoreSlot ~= nil then
        loadInto(baseWork, slotAt(program, matrixSlots, cmd.restoreSlot, cmd))
      elseif cmd.parentIndex == cmd.nodeIndex then
        -- Self-parenting root: no source matrix (the explicit no-source op).
        Matrix4.identityInto(baseWork)
      else
        local parent = nodeMatrices[cmd.parentIndex] ---@type number[]?
        if not parent then
          Errors.raise(
            ErrorCodes.NSBMD_SBC_NODE_PARENT_MISSING,
            "NODEDESC references parent node index "
              .. tostring(cmd.parentIndex)
              .. " whose NODEDESC has not executed; pre-order streams place the parent first",
            { nodeIndex = cmd.nodeIndex, parentIndex = cmd.parentIndex, model = program.name }
          )
        end
        assert(parent ~= nil)
        loadInto(baseWork, parent)
      end

      local localMatrix = NsbmdJointTransforms.localMatrixBufferInto(
        scratch._mLocal,
        scalingRule,
        srt,
        cmd,
        mayaScaleCache,
        scratch._mJointOp,
        scratch._mJointProd
      )
      Matrix4.multiplyInto(scratch._mTmp, baseWork, localMatrix)
      local world = scratch._mTmp
      Matrix4.toArrayBufferInto(reusablePooled(scratch._nodePool, nodeMatrices, cmd.nodeIndex), world)
      storeSlotVersion(scratch, matrixSlots, srt.matrixStackIndex, world)
      if cmd.storeSlot ~= nil then
        storeSlotVersion(scratch, matrixSlots, cmd.storeSlot, world)
      end
      Matrix4.copyInto(currentMatrix, world)
      currentNode = cmd.nodeIndex
      hasBillboard = false
    elseif op == 0x07 then -- BB
      if cmd.restoreSlot ~= nil then
        loadInto(currentMatrix, slotAt(program, matrixSlots, cmd.restoreSlot, cmd))
      end
      Matrix4.copyInto(billboardWork, currentMatrix)
      if cmd.storeSlot ~= nil then
        storeSlotVersion(scratch, matrixSlots, cmd.storeSlot, billboardWork)
      end
      hasBillboard = true
      Matrix4.identityInto(currentMatrix)
      currentNode = cmd.nodeIndex
    elseif op == 0x09 then -- NODEMIX
      local blended =
        nodemixMatrix(program, cmd, matrixSlots, scratch._mMixAccum, scratch._mTmp, scratch._mBase, scratch._mLocal)
      storeSlotVersion(scratch, matrixSlots, cmd.storeSlot, blended)
      Matrix4.copyInto(currentMatrix, blended)
      hasBillboard = false
    elseif op == 0x08 or op == 0x0A then
      -- BBY and CALLDL. CALLDL would submit geometry from a display list this
      -- evaluator never sees, so ignoring it would silently drop draws; no model
      -- in the target world issues either.
      Errors.raise(
        "NSBMD_SBC_UNSUPPORTED_COMMAND",
        (cmd.name or "SBC command") .. " is not supported by SBC evaluation",
        { opcode = op, command = cmd.command, offset = cmd.offset, model = program.name }
      )
    elseif op == 0x0B then -- POSSCALE
      local scale = cmd.inverse and program.invPosScale or program.posScale
      Matrix4.scaleInto(scratch._mJointOp, scale, scale, scale)
      Matrix4.multiplyInto(scratch._mTmp, currentMatrix, scratch._mJointOp)
      Matrix4.copyInto(currentMatrix, scratch._mTmp)
    elseif op == 0x0D then -- PRJMAP
      -- PRJMAP selects projection-map texgen state (a matrix-palette entry;
      -- NNSi_G3dFuncSbc_PRJMAP in NitroSystem g3d/sbc.c reads two operands and
      -- touches only texture-side state). It reads and writes nothing on the
      -- position-matrix stack, so the replay ignores it. Three HGSS field
      -- models use it (interior_build_models member 177 obj_sylph, one
      -- placement on MAP_SAFFRON_SILPH_CO_HQ), so the terminal raise below
      -- must not subsume it.
    else
      Errors.raise(
        "NSBMD_SBC_UNKNOWN_OPCODE",
        (cmd.name or "SBC command") .. " is not handled by SBC evaluation",
        { opcode = op, command = cmd.command, offset = cmd.offset, model = program.name }
      )
    end
  end

  for i = activeCount + 1, #draws do
    draws[i] = nil
  end
  return scratch.result
end

---@param m number[]
---@return number[]
local function snapshotMatrix(m)
  local out = {}
  for i = 1, 16 do
    out[i] = m[i]
  end
  return out
end

---@param stacks table<integer, number[]>
---@return table<integer, number[]>
local function snapshotStacks(stacks)
  local out = {} ---@type table<integer, number[]>
  for slot, matrix in pairs(stacks) do
    out[slot] = snapshotMatrix(matrix)
  end
  return out
end

-- Replay the SBC stream of `program` with `poseProvider` and return the
-- ordered draw submissions plus the effective node state. The returned
-- evaluation is an independent snapshot: later evaluations never mutate it.
-- See evaluateInto for the billboard record split.
---@param program NsbmdSbcEvaluator.Program
---@param poseProvider NsbmdSbcEvaluator.PoseProvider
---@return SbcEvaluation
function NsbmdSbcEvaluator.evaluate(program, poseProvider)
  local live = NsbmdSbcEvaluator.evaluateInto(program, poseProvider, NsbmdSbcEvaluator.newScratch(program))
  local draws = {} ---@type SbcDraw[]
  for i, draw in ipairs(live.draws) do
    draws[i] = {
      nodeIndex = draw.nodeIndex,
      materialIndex = draw.materialIndex,
      shapeIndex = draw.shapeIndex,
      materialReapplied = draw.materialReapplied,
      matrix = snapshotMatrix(draw.matrix),
      restoreStack = snapshotStacks(draw.restoreStack),
      transformMode = draw.transformMode,
      baseTransform = draw.baseTransform and snapshotMatrix(draw.baseTransform) or nil,
    }
  end
  local nodeVisibility = {} ---@type table<integer, boolean>
  for nodeIndex, visible in pairs(live.nodeVisibility) do
    nodeVisibility[nodeIndex] = visible
  end
  return {
    draws = draws,
    nodeMatrices = snapshotStacks(live.nodeMatrices),
    nodeVisibility = nodeVisibility,
    matrixSlots = snapshotStacks(live.matrixSlots),
  }
end

return NsbmdSbcEvaluator
