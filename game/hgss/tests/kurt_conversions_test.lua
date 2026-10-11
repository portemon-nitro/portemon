-- Kurt's source Apricorn-to-Ball semantic mapping.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local KurtConversions = require("game.hgss.src.apricorn.KurtConversions")

local T = {}

function T.maps_each_apricorn_to_its_source_ball_key()
  local expected = {
    RED_APRICORN = "LEVEL_BALL",
    YLW_APRICORN = "MOON_BALL",
    BLU_APRICORN = "LURE_BALL",
    GRN_APRICORN = "FRIEND_BALL",
    PNK_APRICORN = "LOVE_BALL",
    WHT_APRICORN = "FAST_BALL",
    BLK_APRICORN = "HEAVY_BALL",
  }

  for apricornKey, ballKey in pairs(expected) do
    Assert.equal(KurtConversions.ballItemKey(apricornKey), ballKey, apricornKey)
  end
end

function T.rejects_an_unknown_apricorn_key_as_a_structured_error()
  local err = Assert.throws(function()
    KurtConversions.ballItemKey("PURPLE_APRICORN")
  end)

  Assert.isTrue(Errors.is(err), "invalid semantic key uses the structured error path")
  Assert.equal(err.code, "APRICORN_CONVERSION_INVALID")
  Assert.equal(err.context.apricornKey, "PURPLE_APRICORN")
end

return { tests = T }
