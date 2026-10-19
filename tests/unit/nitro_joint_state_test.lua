-- Joint animation results retain bind-pose scale semantics for SBC evaluation.

local Assert = require("tests.support.Assert")
local JointAnimBlend = require("libs.nds.src.nitro.g3d.JointAnimBlend")
local NitroJointState = require("libs.nds.src.nitro.g3d.NitroJointState")

local T = {}

function T.model_unit_scale_remains_unit_scale()
  local bindSrt = {
    translation = { x = 0, y = 0, z = 0 },
    rotation = { 1, 0, 0, 0, 1, 0, 0, 0, 1 },
    scale = { x = 1, y = 1, z = 1 },
    inverseScale = nil,
    transZero = false,
    rotZero = false,
    scaleOne = true,
    matrixStackIndex = 0,
  }
  local result = {
    flags = JointAnimBlend.FROM_MODEL.scale,
    scale = { 0, 0, 0 },
    scaleEx = { 0, 0, 0 },
    rot = { 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    trans = { 0, 0, 0 },
  }

  local srt = NitroJointState.srtFromBlend(result, bindSrt)

  Assert.isTrue(srt.scaleOne, "the bind pose's unit scale remains explicit")
  Assert.isNil(srt.inverseScale, "unit scale does not require inverse-scale data")
end

return { tests = T }
