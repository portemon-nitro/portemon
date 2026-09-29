-- Shared plain-text layout for the developer-facing preparation/loading
-- screens.

local Assert = require("tests.support.Assert")
local DevScreenLayout = require("game.hgss.src.ui.DevScreenLayout")

local T = { tests = {} }

function T.tests.exposes_the_shared_margin_and_line_height()
  Assert.equal(DevScreenLayout.MARGIN, 24)
  Assert.equal(DevScreenLayout.LINE_HEIGHT, 24)
end

return T
