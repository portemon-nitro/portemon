-- The ordered radio channel decision behind the tuner. Priority follows the
-- native available-channels order: a map that forbids radio tunes nothing;
-- the ruins of Alph keep their own table; Kanto tunes nothing before the
-- restored power and splits on the expansion card after it; Mahogany holds
-- its table only while the hideout stands uncleared; the Rocket takeover
-- takes its table; every other map tunes Johto. Map-set membership (which
-- map is Alph, which is Mahogany, which region a map is in) resolves at
-- composition from map headers into these semantic facts; this policy only
-- orders them. Pure function of its two fact records: no allocation beyond
-- the returned key, no randomness.

---@class RadioReception
local RadioReception = {}

---@param mapFacts table<string, unknown>? semantic map signal facts
---@param worldFlags table<string, unknown>? live story flags
---@return string the compiled reception key
function RadioReception.forContext(mapFacts, worldFlags)
  if type(mapFacts) ~= "table" then
    error("radio channel selection requires map signal facts", 0)
  end
  assert(type(mapFacts) == "table", "channel selection reads its map facts")
  if type(mapFacts.key) ~= "string" or mapFacts.key == "" then
    error("radio channel selection requires a named map", 0)
  end
  if type(mapFacts.allowsRadio) ~= "boolean" then
    error("radio channel selection requires the map radio permission", 0)
  end
  local flags = worldFlags or {}
  assert(type(flags) == "table", "channel selection reads its story flags")
  if mapFacts.allowsRadio ~= true then
    return "none"
  end
  if mapFacts.alph == true then
    return "alph"
  end
  if mapFacts.region == "kanto" then
    if flags.powerRestored ~= true then
      return "none"
    elseif flags.kantoExpansion == true then
      return "kanto-expn"
    end
    return "kanto"
  end
  if mapFacts.mahogany == true and flags.hideoutCleared ~= true then
    return "mahogany"
  end
  if flags.rocketTakeover == true then
    return "rocket"
  end
  return "johto"
end

return RadioReception
