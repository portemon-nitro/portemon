-- Pinned numeric trainer-class identities: the header byte of the native
-- 20-byte trainer record resolves to these semantic class keys, one per
-- numeric identity. Pure tables; no ROM access.

local Assert = require("tests.support.Assert")

local T = {}

local function sources()
  return require("romdump.src.config.BattleSources")
end

function T.numeric_trainer_classes_cover_every_native_identity_exactly_once()
  local keys = assert(sources().trainerClassKeys, "the pinned class table must exist")
  local count = 0
  local seen = {}
  for id, key in pairs(keys) do
    Assert.isTrue(type(id) == "number" and id % 1 == 0 and id >= 0 and id <= 128, "class identities stay in 0..128")
    Assert.isTrue(type(key) == "string" and key ~= "", "class identities name their semantic key")
    Assert.isNil(seen[key], "semantic class keys never repeat")
    seen[key] = true
    count = count + 1
  end
  Assert.equal(count, 129, "the class table holds all 129 native identities")
  for id = 0, 128 do
    Assert.notNil(keys[id], "native class identity " .. id .. " is inventoried")
  end
end

function T.special_trainer_classes_keep_their_source_identities()
  local keys = sources().trainerClassKeys
  Assert.equal(keys[23], "RIVAL", "the rival keeps its class identity")
  Assert.equal(keys[119], "PASSERBY", "the passerby keeps its class identity")
  Assert.equal(keys[86], "CHAMPION", "the champion keeps its class identity")
  Assert.equal(keys[109], "PKMN_TRAINER_RED", "the final challenge keeps its class identity")
  Assert.equal(keys[123], "PKMN_TRAINER_LANCE", "the leaderboard keeps its class identity")
  Assert.equal(keys[110], "LEADER_BLUE", "the Viridian leader keeps its class identity")
  Assert.equal(keys[66], "LEADER_FALKNER", "the first gym leader keeps its class identity")
  Assert.equal(keys[98], "LEADER_BROCK", "the Pewter leader keeps its class identity")
  Assert.equal(keys[103], "LEADER_MISTY", "the Cerulean leader keeps its class identity")
  Assert.equal(keys[87], "ELITE_FOUR_WILL", "the first elite keeps its class identity")
  Assert.equal(keys[89], "ELITE_FOUR_KOGA", "the second elite keeps its class identity")
  Assert.equal(keys[112], "ELITE_FOUR_BRUNO", "the third elite keeps its class identity")
  Assert.equal(keys[88], "ELITE_FOUR_KAREN", "the fourth elite keeps its class identity")
  Assert.equal(keys[55], "TEAM_ROCKET", "rocket grunts keep their class identity")
  Assert.equal(keys[62], "TEAM_ROCKET_F", "the second grunt identity stays distinct")
  Assert.equal(keys[116], "EXECUTIVE_ARCHER", "the first executive keeps its class identity")
  Assert.equal(keys[114], "EXECUTIVE_ARIANA", "the second executive keeps its class identity")
  Assert.equal(keys[117], "EXECUTIVE_PROTON", "the third executive keeps its class identity")
  Assert.equal(keys[118], "EXECUTIVE_PETREL", "the fourth executive keeps its class identity")
  Assert.equal(keys[124], "ROCKET_BOSS", "the rocket boss keeps its class identity")
  Assert.equal(keys[47], "KIMONO_GIRL", "the kimono girl keeps her class identity")
  Assert.equal(keys[2], "YOUNGSTER", "an ordinary class keeps its class identity")
end

function T.kanto_variant_classes_keep_distinct_identities()
  local keys = sources().trainerClassKeys
  Assert.equal(keys[24], "ACE_TRAINER_M", "the Johto ace keeps its class identity")
  Assert.equal(keys[53], "ACE_TRAINER_M_GS", "the Kanto ace variant stays a distinct identity")
  Assert.equal(keys[30], "BIRD_KEEPER", "the Johto bird keeper keeps its class identity")
  Assert.equal(keys[69], "BIRD_KEEPER_GS", "the Kanto bird keeper variant stays a distinct identity")
  Assert.equal(keys[41], "SCIENTIST", "the Johto scientist keeps its class identity")
  Assert.equal(keys[113], "SCIENTIST_GS", "the Kanto scientist variant stays a distinct identity")
  Assert.isNil(keys[200], "phone contact aliases stay outside the battle class table")
  Assert.isNil(keys[207], "the last phone contact alias stays outside the battle class table")
end

return { tests = T }
