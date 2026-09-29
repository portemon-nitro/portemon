-- The single shared native pane resolution every fixed-size HGSS layout
-- fits against.

local Assert = require("tests.support.Assert")
local NativeDisplay = require("libs.ui.src.NativeDisplay")

local T = {}

function T.exposes_the_canonical_ds_resolution()
  Assert.equal(NativeDisplay.WIDTH, 256)
  Assert.equal(NativeDisplay.HEIGHT, 192)
end

return { tests = T }
