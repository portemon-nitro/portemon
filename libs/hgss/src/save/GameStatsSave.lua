-- Persisted game-stats bucket: strict v5 shape, canonical detached
-- output, and evidence-preserving migration from a missing bucket or an
-- exact earlier bucket. v5 keeps the sorted registration set (freshness
-- authority), the blind unique-registration total (retail increments per
-- evolution publish, even for re-registrations), the bounded trainer-card
-- score, the bounded written-Mail total, the bounded steps-biked total
-- (GAME_STAT_STEPS_BIKED 1, behind the Bike Shop call), the bounded
-- League-win counter, and the two Day Care statistics: parents sent to the
-- Day Care and eggs hatched. Migration never invents registrations, counts,
-- score, wins, or care events from an absent bucket; an exact v1 bucket
-- migrates with zero written-Mail, biked, win, and care counts, an exact v2
-- bucket with zero biked, win, and care counts, an exact v3 bucket with zero
-- win and care counts, and an exact v4 bucket with the two zero care
-- counters. The hatch counter stays zero until its own hatch owner lands.
-- Pure data owner: no live state, no love dependency.
--
-- Retail sources (tmp/refs/pokeheartgold):
-- unique counter GAME_STAT_UNIQUE_MONS_CAUGHT 13 and score stat
-- GAME_STAT_SCORE 2 (include/constants/game_stats.h:4-14), register
-- score event SCORE_EVENT_REGISTER_SPECIES_CAUGHT 21
-- (include/constants/game_stats.h:87), its 20-point modifier
-- sScoreMods[21] (src/game_stats.c), and the 99999999 score ceiling in
-- GameStats_AddScore (src/game_stats.c:371-379), and the League-win counter
-- GameStats_Inc(GAME_STAT_LEAGUE_WINS) the ending awards
-- (src/game_clear.c::CallTask_GameClear).

local Errors = require("libs.errors.src.Errors")

---@class GameStatsSave
local GameStatsSave = {}

GameStatsSave.SCHEMA = "hgss-stats-v5"
GameStatsSave.STATE_VERSION = 5
GameStatsSave.V4_SCHEMA = "hgss-stats-v4"
GameStatsSave.V4_STATE_VERSION = 4
GameStatsSave.V3_SCHEMA = "hgss-stats-v3"
GameStatsSave.V3_STATE_VERSION = 3
GameStatsSave.V2_SCHEMA = "hgss-stats-v2"
GameStatsSave.V2_STATE_VERSION = 2
GameStatsSave.LEGACY_SCHEMA = "hgss-stats-v1"
GameStatsSave.LEGACY_STATE_VERSION = 1

-- Retail score ceiling enforced by GameStats_AddScore: the register
-- event adds its modifier but the total never exceeds 99999999.
GameStatsSave.SCORE_CAP = 99999999

-- GAME_STAT_STEPS_BIKED is an extra-wide word stat: GameStats_Inc
-- saturates it at 999999999 (src/game_stats.c GameStats_GetMaxValue).
GameStatsSave.STEPS_BIKED_CAP = 999999999

-- The source stores League wins in the same u16 statistic block
-- (GameStats_Inc caps at GAME_STAT_MAX 9999).
GameStatsSave.LEAGUE_WINS_CAP = 9999

-- GAME_STAT_MONS_SENT_TO_DAYCARE and GAME_STAT_EGGS_HATCHED live in the same
-- u16 statistic block, so they share the GAME_STAT_MAX ceiling.
GameStatsSave.DAYCARE_DEPOSITS_CAP = 9999
GameStatsSave.EGGS_HATCHED_CAP = 9999

local TOP_FIELDS = {
  schema = true,
  stateVersion = true,
  uniqueCaught = true,
  uniqueTotal = true,
  score = true,
  mailWritten = true,
  stepsBiked = true,
  leagueWins = true,
  daycareDeposits = true,
  eggsHatched = true,
}

---@param message string
---@param context table<string, unknown>
local function fail(message, context)
  Errors.raise("GAME_STATS_INVALID", message, context)
end

---@param refs unknown
local function checkRefs(refs)
  if type(refs) ~= "table" then
    fail("stats validation requires a reference record", {})
  end
  assert(type(refs) == "table", "reference checks read the refs record")
  if type(refs.species) ~= "table" then
    fail("stats validation requires a species reference set", {})
  end
  local empty = true
  for key, known in pairs(refs.species) do
    if type(key) ~= "string" or key == "" or known ~= true then
      fail("stats species must map keys to true", { species = key })
    end
    empty = false
  end
  if empty then
    fail("stats validation requires a non-empty species set", {})
  end
end

---@param value unknown
---@param what string
local function checkDenseList(value, what)
  if type(value) ~= "table" then
    fail("stats bucket " .. what .. " must be an array", {})
  end
  assert(type(value) == "table", "dense checks read the array record")
  local count = 0
  for key in pairs(value) do
    if type(key) ~= "number" or key % 1 ~= 0 or key < 1 then
      fail("stats bucket " .. what .. " must be a dense array", {})
    end
    count = count + 1
  end
  for index = 1, count do
    if value[index] == nil then
      fail("stats bucket " .. what .. " must be a dense array", {})
    end
  end
end

---@param value unknown
---@param refs table<string, unknown>
---@return string[] validated sorted copy
local function checkUniqueCaught(value, refs)
  checkDenseList(value, "unique registrations")
  assert(type(value) == "table", "registration checks read the validated array")
  local allowed = refs.species --[[@as table<string, boolean>]]
  local known = {}
  local checked = {}
  for _, species in ipairs(value) do
    if type(species) ~= "string" or allowed[species] ~= true then
      fail("stats bucket unique registrations name an unknown species", { species = species })
    end
    if known[species] == true then
      fail("stats bucket unique registrations name a duplicate species", { species = species })
    end
    known[species] = true
    checked[#checked + 1] = species
  end
  table.sort(checked)
  return checked
end

---@param value unknown
---@return integer validated written-Mail total
local function checkMailWritten(value)
  if type(value) ~= "number" or value % 1 ~= 0 or value < 0 or value > 999999 then
    fail("stats bucket mail written must be an integer in 0..999999", { mailWritten = value })
  end
  return value --[[@as integer]]
end

---@param value unknown
---@return integer validated steps-biked total
local function checkStepsBiked(value)
  if type(value) ~= "number" or value % 1 ~= 0 or value < 0 or value > GameStatsSave.STEPS_BIKED_CAP then
    fail(
      "stats bucket steps biked must be an integer in 0.." .. tostring(GameStatsSave.STEPS_BIKED_CAP),
      { stepsBiked = value }
    )
  end
  return value --[[@as integer]]
end

---@param value unknown
---@return integer validated blind unique total
local function checkUniqueTotal(value)
  if type(value) ~= "number" or value % 1 ~= 0 or value < 0 then
    fail("stats bucket unique total must be a non-negative integer", { uniqueTotal = value })
  end
  return value --[[@as integer]]
end

---@param value unknown
---@return integer validated score
local function checkScore(value)
  if type(value) ~= "number" or value % 1 ~= 0 or value < 0 or value > GameStatsSave.SCORE_CAP then
    fail("stats bucket score must be an integer in 0.." .. tostring(GameStatsSave.SCORE_CAP), { score = value })
  end
  return value --[[@as integer]]
end

---@param value unknown
---@return integer validated League-win total
local function checkLeagueWins(value)
  if type(value) ~= "number" or value % 1 ~= 0 or value < 0 or value > GameStatsSave.LEAGUE_WINS_CAP then
    fail(
      "stats bucket League wins must be an integer in 0.." .. tostring(GameStatsSave.LEAGUE_WINS_CAP),
      { leagueWins = value }
    )
  end
  return value --[[@as integer]]
end

---@param value unknown
---@return integer validated Day Care deposit total
local function checkDaycareDeposits(value)
  if type(value) ~= "number" or value % 1 ~= 0 or value < 0 or value > GameStatsSave.DAYCARE_DEPOSITS_CAP then
    fail(
      "stats bucket Day Care deposits must be an integer in 0.." .. tostring(GameStatsSave.DAYCARE_DEPOSITS_CAP),
      { daycareDeposits = value }
    )
  end
  return value --[[@as integer]]
end

---@param value unknown
---@return integer validated hatch total
local function checkEggsHatched(value)
  if type(value) ~= "number" or value % 1 ~= 0 or value < 0 or value > GameStatsSave.EGGS_HATCHED_CAP then
    fail(
      "stats bucket hatched eggs must be an integer in 0.." .. tostring(GameStatsSave.EGGS_HATCHED_CAP),
      { eggsHatched = value }
    )
  end
  return value --[[@as integer]]
end

-- The stored registration array without a catalog: dense string entries, no
-- species resolution. Only the save envelope's own schema advance uses this
-- shape; the owning runtime restore always validates the set against the
-- generated species catalog.
---@param value unknown
---@return string[] detached stored copy
local function copyRegistrations(value)
  checkDenseList(value, "unique registrations")
  assert(type(value) == "table", "registration checks read the validated array")
  local checked = {}
  for _, species in ipairs(value) do
    if type(species) ~= "string" or species == "" then
      fail("stats bucket unique registrations name no species", {})
    end
    checked[#checked + 1] = species
  end
  return checked
end

---@param bucket table<string, unknown> validated shape record
---@param refs table<string, unknown>?
---@return table<string, unknown> detached canonical v5 bucket
local function canonicalize(bucket, refs)
  return {
    schema = GameStatsSave.SCHEMA,
    stateVersion = GameStatsSave.STATE_VERSION,
    uniqueCaught = refs ~= nil and checkUniqueCaught(bucket.uniqueCaught, refs)
      or copyRegistrations(bucket.uniqueCaught),
    uniqueTotal = checkUniqueTotal(bucket.uniqueTotal),
    score = checkScore(bucket.score),
    mailWritten = checkMailWritten(bucket.mailWritten),
    stepsBiked = checkStepsBiked(bucket.stepsBiked),
    leagueWins = checkLeagueWins(bucket.leagueWins),
    daycareDeposits = checkDaycareDeposits(bucket.daycareDeposits),
    eggsHatched = checkEggsHatched(bucket.eggsHatched),
  }
end

-- Rejects any field outside an exact legacy shape before migrating it.
---@param bucket table<string, unknown>
---@param fields table<string, boolean>
local function checkLegacyFields(bucket, fields)
  for key in pairs(bucket) do
    if fields[key] ~= true then
      fail("stats bucket carries an unsupported schema", { schema = bucket.schema })
    end
  end
end

---@param bucket table<string, unknown>
---@param refs { species: table<string, boolean> }
---@return table<string, unknown> detached canonical v5 bucket
function GameStatsSave.validate(bucket, refs)
  checkRefs(refs)
  if type(bucket) ~= "table" then
    fail("stats bucket must be a table", {})
  end
  assert(type(bucket) == "table", "validation reads the bucket record")
  for key in pairs(bucket) do
    if TOP_FIELDS[key] ~= true then
      fail("stats bucket contains an unknown field", { field = key })
    end
  end
  if bucket.schema ~= GameStatsSave.SCHEMA then
    fail("stats schema must be " .. GameStatsSave.SCHEMA, { schema = bucket.schema })
  end
  if bucket.stateVersion ~= GameStatsSave.STATE_VERSION then
    fail("stats bucket carries an incompatible state version", { stateVersion = bucket.stateVersion })
  end
  return canonicalize(bucket, refs)
end

-- Migrates one stored bucket to the current schema. The species reference set
-- owns the canonical registration check; a caller without a catalog passes nil
-- and receives the same current-shape bucket with the stored registrations
-- copied verbatim, which the owning runtime restore then validates. Only the
-- save envelope's own schema advance takes that path.
---@param bucket table<string, unknown>?
---@param refs { species: table<string, boolean> }?
---@return table<string, unknown> detached canonical v5 bucket
function GameStatsSave.migrate(bucket, refs)
  if refs ~= nil then
    checkRefs(refs)
  end
  if bucket == nil then
    return canonicalize(GameStatsSave.initial(), refs)
  end
  if type(bucket) ~= "table" then
    fail("stats bucket must be a table", {})
  end
  assert(type(bucket) == "table", "migration reads the bucket record")
  if bucket.schema == GameStatsSave.SCHEMA and bucket.stateVersion == GameStatsSave.STATE_VERSION then
    return canonicalize(bucket, refs)
  end
  -- Exact legacy buckets migrate with zero counts for the totals they
  -- never tracked: no historical count can be inferred. Malformed current
  -- buckets fail in canonicalize above.
  local legacyFields = { schema = true, stateVersion = true, uniqueCaught = true, uniqueTotal = true, score = true }
  local mailWritten = 0
  local stepsBiked = 0
  local leagueWins = 0
  if bucket.schema == GameStatsSave.V4_SCHEMA and bucket.stateVersion == GameStatsSave.V4_STATE_VERSION then
    legacyFields.mailWritten = true
    legacyFields.stepsBiked = true
    legacyFields.leagueWins = true
    mailWritten = bucket.mailWritten
    stepsBiked = bucket.stepsBiked
    leagueWins = bucket.leagueWins
  elseif bucket.schema == GameStatsSave.V3_SCHEMA and bucket.stateVersion == GameStatsSave.V3_STATE_VERSION then
    legacyFields.mailWritten = true
    legacyFields.stepsBiked = true
    mailWritten = bucket.mailWritten
    stepsBiked = bucket.stepsBiked
  elseif bucket.schema == GameStatsSave.V2_SCHEMA and bucket.stateVersion == GameStatsSave.V2_STATE_VERSION then
    legacyFields.mailWritten = true
    mailWritten = bucket.mailWritten
  elseif bucket.schema == GameStatsSave.LEGACY_SCHEMA and bucket.stateVersion == GameStatsSave.LEGACY_STATE_VERSION then
    mailWritten = 0
  else
    fail("stats bucket carries an unsupported schema", { schema = bucket.schema })
  end
  checkLegacyFields(bucket, legacyFields)
  return canonicalize({
    schema = GameStatsSave.SCHEMA,
    stateVersion = GameStatsSave.STATE_VERSION,
    uniqueCaught = bucket.uniqueCaught,
    uniqueTotal = bucket.uniqueTotal,
    score = bucket.score,
    mailWritten = mailWritten,
    stepsBiked = stepsBiked,
    leagueWins = leagueWins,
    daycareDeposits = 0,
    eggsHatched = 0,
  }, refs)
end

---@return table<string, unknown> the defined source initial state
function GameStatsSave.initial()
  return {
    schema = GameStatsSave.SCHEMA,
    stateVersion = GameStatsSave.STATE_VERSION,
    uniqueCaught = {},
    uniqueTotal = 0,
    score = 0,
    mailWritten = 0,
    stepsBiked = 0,
    leagueWins = 0,
    daycareDeposits = 0,
    eggsHatched = 0,
  }
end

return GameStatsSave
