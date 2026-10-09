-- Tests for MenuProtocol: the project-owned list-menu protocol constants.
-- Script lowering (romdump) and the script menu host
-- consume this contract, so the source-bound values live in one place.

local Assert = require("tests.support.Assert")
local MenuProtocol = require("libs.assets.src.MenuProtocol")

local T = {}

function T.protocol_constants_are_stable()
  Assert.equal(MenuProtocol.STANDARD_MESSAGE_BANK, 191)
  Assert.equal(MenuProtocol.START_MENU_MESSAGE_BANK, 196)
  Assert.equal(MenuProtocol.CANCEL_RESULT, 0xFFFE)
end

return { tests = T }
