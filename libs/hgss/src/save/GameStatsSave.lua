-- Persisted game-stats bucket: strict v1 shape, canonical detached
-- output, and evidence-preserving migration from a missing bucket. v1
-- keeps the sorted registration set (freshness authority), the blind
-- unique-registration total (retail increments per evolution publish,
-- even for re-registrations), and the bounded trainer-card score.
-- Migration never invents registrations, counts, or score from an
-- absent bucket. Pure data owner: no live state, no love dependency.
--
-- Retail sources (tmp/refs/pokeheartgold):
-- unique counter GAME_STAT_UNIQUE_MONS_CAUGHT 13 and score stat
-- GAME_STAT_SCORE 2 (include/constants/game_stats.h:4-14), register
-- score event SCORE_EVENT_REGISTER_SPECIES_CAUGHT 21
-- (include/constants/game_stats.h:87), its 20-point modifier
-- sScoreMods[21] (src/game_stats.c), and the 99999999 score ceiling in
-- GameStats_AddScore (src/game_stats.c:371-379).

local Errors = require("libs.errors.src.Errors")

---@class GameStatsSave
local GameStatsSave = {}

GameStatsSave.SCHEMA = "hgss-stats-v1"
GameStatsSave.STATE_VERSION = 1

-- Retail score ceiling enforced by GameStats_AddScore: the register
-- event adds its modifier but the total never exceeds 99999999.
GameStatsSave.SCORE_CAP = 99999999

local TOP_FIELDS = { schema = true, stateVersion = true, uniqueCaught = true, uniqueTotal = true, score = true }

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

---@param bucket table<string, unknown> validated shape record
---@param refs table<string, unknown>
---@return table<string, unknown> detached canonical v1 bucket
local function canonicalize(bucket, refs)
  return {
    schema = GameStatsSave.SCHEMA,
    stateVersion = GameStatsSave.STATE_VERSION,
    uniqueCaught = checkUniqueCaught(bucket.uniqueCaught, refs),
    uniqueTotal = checkUniqueTotal(bucket.uniqueTotal),
    score = checkScore(bucket.score),
  }
end

---@param bucket table<string, unknown>
---@param refs { species: table<string, boolean> }
---@return table<string, unknown> detached canonical v1 bucket
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

---@param bucket table<string, unknown>?
---@param refs { species: table<string, boolean> }
---@return table<string, unknown> detached canonical v1 bucket
function GameStatsSave.migrate(bucket, refs)
  checkRefs(refs)
  if bucket == nil then
    return canonicalize({
      schema = GameStatsSave.SCHEMA,
      stateVersion = GameStatsSave.STATE_VERSION,
      uniqueCaught = {},
      uniqueTotal = 0,
      score = 0,
    }, refs)
  end
  if type(bucket) ~= "table" then
    fail("stats bucket must be a table", {})
  end
  assert(type(bucket) == "table", "migration reads the bucket record")
  if bucket.schema == GameStatsSave.SCHEMA and bucket.stateVersion == GameStatsSave.STATE_VERSION then
    return canonicalize(bucket, refs)
  end
  fail("stats bucket carries an unsupported schema", { schema = bucket.schema })
  error("unreachable", 0)
end

---@return table<string, unknown> the defined source initial state
function GameStatsSave.initial()
  return {
    schema = GameStatsSave.SCHEMA,
    stateVersion = GameStatsSave.STATE_VERSION,
    uniqueCaught = {},
    uniqueTotal = 0,
    score = 0,
  }
end

return GameStatsSave
