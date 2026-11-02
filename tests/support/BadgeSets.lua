-- Badge set fixtures for the open player badge store. The empty set is a
-- badge-less profile, all() covers the sixteen canonical retail keys in
-- native order, and first(n) owns the first n of those keys. Test-only.

local PlayerProgression = require("libs.hgss.src.save.PlayerProgression")

local BadgeSets = {}

---@return table<string, true>
function BadgeSets.empty()
  return {}
end

---@return table<string, true>
function BadgeSets.all()
  return BadgeSets.first(#PlayerProgression.BADGE_ORDER)
end

---@param count integer how many canonical retail keys to own, in native order
---@return table<string, true>
function BadgeSets.first(count)
  assert(
    type(count) == "number" and count % 1 == 0 and count >= 0 and count <= #PlayerProgression.BADGE_ORDER,
    "badge fixtures own 0..16 canonical keys"
  )
  local badges = {}
  for index = 1, count do
    badges[PlayerProgression.BADGE_ORDER[index]] = true
  end
  return badges
end

return BadgeSets
