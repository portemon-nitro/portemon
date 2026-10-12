-- The one shared broadcast-sequence-to-gameplay-effect mapping. Every tuned
-- music latch resolves here: encounters, the script music query, and the
-- tuner lifecycle all read the audio latch through this function, so no
-- caller keeps an independent copy. Sequence identities are the semantic
-- radio vocabulary, including the gameboy-card replays of march and
-- lullaby; the tune-in jingle, card filler, and anything unknown or absent
-- resolve to no effect. Pure function: no allocation, no randomness.

local Music = require("game.hgss.src.pokegear.radio.Music")
local Special = require("game.hgss.src.pokegear.radio.Special")

---@class PokegearRadioEffects
local PokegearRadioEffects = {}

local EFFECTS = {
  [Music.MARCH_SEQUENCE] = "march",
  [Music.LULLABY_SEQUENCE] = "lullaby",
  [Music.HOENN_SEQUENCE] = "hoenn",
  [Music.SINNOH_SEQUENCE] = "sinnoh",
  ["radio.music.card.21"] = "march",
  ["radio.music.card.22"] = "lullaby",
  [Special.FLUTE_SEQUENCE] = "pokeflute",
  [Special.UNOWN_SEQUENCE] = "unown",
}

-- Resolves one latched sequence identity to its closed gameplay effect:
-- march, lullaby, hoenn, sinnoh, unown, pokeflute, or none. Reads the
-- latch only, never the cursor, visible text, tab, volume, or note state.
-- Numeric latches outside the semantic vocabulary read as no effect
-- until provider-backed id resolution arrives; unknown or absent reads
-- the same way.
---@param sequenceKey string|integer? the latched audio sequence identity
---@return string the semantic music effect
function PokegearRadioEffects.fromSequence(sequenceKey)
  if type(sequenceKey) ~= "string" then
    return "none"
  end
  local effect = EFFECTS[sequenceKey]
  if effect == nil then
    return "none"
  end
  return effect
end

return PokegearRadioEffects
