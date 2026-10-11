-- Source Apricorn-to-Ball conversion policy for Kurt.

local Errors = require("libs.errors.src.Errors")

local KurtConversions = {}

local BALL_BY_APRICORN = {
  RED_APRICORN = "LEVEL_BALL",
  YLW_APRICORN = "MOON_BALL",
  BLU_APRICORN = "LURE_BALL",
  GRN_APRICORN = "FRIEND_BALL",
  PNK_APRICORN = "LOVE_BALL",
  WHT_APRICORN = "FAST_BALL",
  BLK_APRICORN = "HEAVY_BALL",
}

---@param apricornKey string
---@return string
function KurtConversions.ballItemKey(apricornKey)
  local ballKey = BALL_BY_APRICORN[apricornKey]
  if ballKey == nil then
    Errors.raise("APRICORN_CONVERSION_INVALID", "Kurt has no Ball mapping for this Apricorn", {
      apricornKey = apricornKey,
    })
  end
  return assert(ballKey, "known Kurt Apricorn mappings always return a Ball key")
end

return KurtConversions
