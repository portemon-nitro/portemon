-- Player-facing source encoding: the field keeps facings as semantic
-- strings while generated scripts compare against numeric direction codes.
-- The semantic adapter owns that conversion; every cardinal facing maps to
-- its fixed code and anything else is an attributed fault, never a default.

local Assert = require("tests.support.Assert")
local RuntimeValues = require("libs.hgss.src.script.RuntimeValues")

local T = {}

local function run()
  return { instance = { scriptId = "test.facing" } }
end

T["cardinal facings encode to their source direction codes"] = function()
  local codes = { north = 0, south = 1, west = 2, east = 3 }
  for facing, code in pairs(codes) do
    Assert.equal(
      RuntimeValues.encodePlayerFacing(facing, run()),
      code,
      "facing " .. facing .. " must encode to " .. tostring(code)
    )
  end
end

T["unknown facings fail instead of encoding"] = function()
  for _, facing in ipairs({ "diagonal", "", 1, nil }) do
    local err = Assert.throws(function()
      RuntimeValues.encodePlayerFacing(facing, run())
    end)
    Assert.equal(err.code, "SCRIPT_INVALID_REFERENCE", "facing " .. tostring(facing) .. " must fault")
    Assert.equal(err.context.scriptId, "test.facing", "the fault must carry the script identity")
  end
end

return { tests = T }
