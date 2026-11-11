-- Saved word unlocks and phrases: fresh saves initialize only their own
-- language greeting with distinct default tower and terminal phrases,
-- missing buckets admit defaults, malformed present buckets fail without
-- resetting, learns are bounded idempotent bit sets, setters validate and
-- normalize before mutating, and every read and capture stays detached.
-- The catalog underneath is real over a small synthetic dataset, so the
-- state rules run without ROM data or product caches.

local Assert = require("tests.support.Assert")

local T = {
  metadata = {
    tags = { "easychat" },
  },
  tests = {},
}

local NULL_WORD = 0xFFFF
local MAX_TRENDY_BIT = 31
local HIGH_TRENDY_VALUE = 2147483648

local DEFAULT_TOWER = {
  { bank = 0, number = 0, words = { 1113, NULL_WORD } },
  { bank = 1, number = 0, words = { 1139, NULL_WORD } },
  { bank = 2, number = 0, words = { 1403, NULL_WORD } },
  { bank = 1, number = 4, words = { 1107, NULL_WORD } },
}
local DEFAULT_TERMINAL = { bank = 4, number = 0, words = { 1281, NULL_WORD } }
local LANGUAGE_BITS = {
  japanese = 0,
  english = 1,
  french = 2,
  italian = 3,
  german = 4,
  spanish = 5,
}

-- Loads the saved word state owner that does not exist yet at this
-- baseline. The failure names the missing behaviour instead of surfacing
-- as a suite load error, so the pre-implementation red stays attributable.
---@param moduleName string
---@param missingMessage string
---@return table
local function requireFeature(moduleName, missingMessage)
  local ok, mod = pcall(require, moduleName)
  if not ok then
    error(missingMessage, 0)
  end
  assert(type(mod) == "table", missingMessage)
  return mod --[[@as table]]
end

---@param id integer
---@return table word record
local function wordRecord(id)
  return { id = id, tokens = { { text = "word" } }, eligibility = "always" }
end

---@return table synthetic catalog data with the default identities
local function syntheticData()
  local words = {
    wordRecord(7),
    wordRecord(42),
    wordRecord(1107),
    wordRecord(1113),
    wordRecord(1139),
    wordRecord(1281),
    wordRecord(1403),
  }
  local templates = {
    { bank = 0, number = 0, wordCount = 1, tokens = {} },
    { bank = 0, number = 1, wordCount = 2, tokens = {} },
    { bank = 1, number = 0, wordCount = 1, tokens = {} },
    { bank = 1, number = 4, wordCount = 1, tokens = {} },
    { bank = 2, number = 0, wordCount = 1, tokens = {} },
    { bank = 4, number = 0, wordCount = 0, tokens = {} },
  }
  local groups = {}
  for index = 1, 12 do
    groups[index] = { key = "group" .. index, labelTokens = {}, wordIds = {} }
  end
  local initials = {}
  for index = 1, 27 do
    initials[index] = { labelTokens = {}, candidates = {} }
  end
  return {
    words = words,
    templates = templates,
    groups = groups,
    initials = initials,
    primoWords = {},
    unionAvatars = { choices = {}, rows = {} },
  }
end

---@return table stateModule, table catalog
local function ownerWithCatalog()
  local State = requireFeature(
    "libs.hgss.src.save.EasyChatState",
    "the shared word state has no save owner yet: unlocks and phrases cannot persist or admit"
  )
  local Catalog = requireFeature(
    "libs.hgss.src.ui.EasyChatCatalog",
    "the shared word state has no catalog yet: saved phrases cannot validate their words"
  )
  return State, Catalog.new(syntheticData())
end

-- Fresh saves initialize only their own language greeting, start with no
-- trendy unlocks, and carry four tower phrases plus one separate terminal
-- phrase at their source defaults.
function T.tests.fresh_state_initializes_only_the_own_language_greeting_and_distinct_phrases()
  local State, catalog = ownerWithCatalog()
  for language, bit in pairs(LANGUAGE_BITS) do
    local state = State.new(language, catalog)
    local unlocks = state:readUnlocks()
    Assert.equal(unlocks.greetings, 2 ^ bit, language .. " initializes only its own greeting bit")
    Assert.equal(unlocks.trendy, 0, language .. " starts with no trendy unlocks")
    for slot = 1, 4 do
      Assert.deepEqual(state:towerMessage(slot), DEFAULT_TOWER[slot], language .. " tower phrase " .. slot)
    end
    Assert.deepEqual(state:terminalGreeting(), DEFAULT_TERMINAL, language .. " terminal phrase")
  end
  local other = State.new("korean", catalog)
  Assert.equal(other:readUnlocks().greetings, 0, "a language outside the source set grants no greeting")

  -- Tower and terminal phrases are separate records, never aliases.
  local state = State.new("english", catalog)
  local tower = state:towerMessage(1)
  tower.words[1] = 7
  Assert.deepEqual(state:towerMessage(1), DEFAULT_TOWER[1], "mutating a tower read leaves the record alone")
  Assert.deepEqual(state:terminalGreeting(), DEFAULT_TERMINAL, "tower reads never alias the terminal phrase")
end

-- A missing bucket initializes source defaults; every mutation stays
-- inside this owner and captures detach from it.
function T.tests.missing_bucket_restores_source_defaults_with_detached_capture()
  local State, catalog = ownerWithCatalog()
  local state = State.restore(nil, "english", catalog)
  Assert.deepEqual(state:readUnlocks(), State.new("english", catalog):readUnlocks(), "nil admits defaults")
  Assert.deepEqual(state:capture(), State.new("english", catalog):capture(), "nil capture matches defaults")

  state:learnGreeting(2)
  local capture = state:capture()
  capture.greetings = 0
  capture.towerMessages[1].words[1] = 7
  Assert.equal(state:readUnlocks().greetings, 2 + 4, "mutating a capture leaves the owner alone")
  Assert.deepEqual(state:towerMessage(1), DEFAULT_TOWER[1], "mutating a capture leaves tower phrases alone")

  local roundtripped = State.restore(state:capture(), "english", catalog)
  Assert.deepEqual(roundtripped:capture(), state:capture(), "capture restores byte for byte")
end

-- Malformed present buckets fail admission without resetting, and failed
-- setters validate before mutating so the old record survives.
function T.tests.malformed_present_bucket_fails_without_reset_and_setters_validate_first()
  local State, catalog = ownerWithCatalog()
  local state = State.new("english", catalog)
  local valid = state:capture()

  ---@param mutate fun(bucket: table)
  ---@param why string
  local function assertInvalidBucket(mutate, why)
    local bucket = State.new("english", catalog):capture()
    mutate(bucket)
    local ok = pcall(State.restore, bucket, "english", catalog)
    Assert.isFalse(ok, why)
  end

  assertInvalidBucket(function(bucket)
    bucket.schema = "bogus-schema"
  end, "an unknown schema fails")
  assertInvalidBucket(function(bucket)
    bucket.trendy = nil
  end, "a missing field fails")
  assertInvalidBucket(function(bucket)
    bucket.greetings = 64
  end, "an out-of-range greeting bitset fails")
  assertInvalidBucket(function(bucket)
    bucket.trendy = -1
  end, "a negative trendy bitset fails")
  assertInvalidBucket(function(bucket)
    bucket.towerMessages[4] = nil
  end, "three tower records fail")
  assertInvalidBucket(function(bucket)
    bucket.towerMessages[5] = { bank = 0, number = 0, words = { 42, NULL_WORD } }
  end, "five tower records fail")
  assertInvalidBucket(function(bucket)
    bucket.towerMessages[1] = { bank = 0, number = 1, words = { 42, NULL_WORD } }
  end, "an incomplete tower record fails")
  assertInvalidBucket(function(bucket)
    bucket.towerMessages[1] = { bank = 0, number = 0, words = { 42, 7 } }
  end, "a non-null unused tower word fails")
  assertInvalidBucket(function(bucket)
    bucket.towerMessages[1] = { bank = 0, number = 0, words = { 99999, NULL_WORD } }
  end, "an unknown tower word fails")
  assertInvalidBucket(function(bucket)
    bucket.towerMessages[1] = { bank = 3, number = 7, words = { 42, NULL_WORD } }
  end, "an unknown tower template fails")
  Assert.deepEqual(state:capture(), valid, "rejected buckets never touch the owner")

  local badComplete = { bank = 0, number = 1, words = { 42, NULL_WORD } }
  local ok = pcall(state.setTowerMessage, state, 1, badComplete)
  Assert.isFalse(ok, "an incomplete setter fails")
  Assert.deepEqual(state:towerMessage(1), DEFAULT_TOWER[1], "a failed setter keeps the old record")
  local badWord = { bank = 0, number = 0, words = { 99999, NULL_WORD } }
  local okWord = pcall(state.setTerminalGreeting, state, badWord)
  Assert.isFalse(okWord, "an unknown-word setter fails")
  Assert.deepEqual(state:terminalGreeting(), DEFAULT_TERMINAL, "a failed terminal setter keeps the old record")
end

-- Learns are bounded idempotent bit sets, including the top trendy bit as
-- an unsigned value; out-of-range learns fail.
function T.tests.learns_are_bounded_idempotent_bit_sets()
  local State, catalog = ownerWithCatalog()
  local state = State.new("english", catalog)
  state:learnGreeting(2)
  state:learnGreeting(2)
  Assert.equal(state:readUnlocks().greetings, 2 + 4, "learning a greeting twice sets its bit once")
  state:learnTrendy(MAX_TRENDY_BIT)
  state:learnTrendy(MAX_TRENDY_BIT)
  Assert.equal(state:capture().trendy, HIGH_TRENDY_VALUE, "the top trendy bit stays unsigned")
  local okGreeting = pcall(state.learnGreeting, state, 6)
  Assert.isFalse(okGreeting, "a greeting learn past the source set fails")
  local okTrendy = pcall(state.learnTrendy, state, 32)
  Assert.isFalse(okTrendy, "a trendy learn past the bitset fails")
  Assert.equal(state:capture().trendy, HIGH_TRENDY_VALUE, "failed learns never touch the bitsets")
end

-- Setters store detached complete records and normalize unused trailing
-- fields to null through the catalog slot counts.
function T.tests.setters_store_detached_complete_records_with_normalized_trailing_fields()
  local State, catalog = ownerWithCatalog()
  local state = State.new("english", catalog)

  local message = { bank = 0, number = 0, words = { 42, 7 } }
  state:setTowerMessage(1, message)
  message.words[1] = 99999
  Assert.deepEqual(
    state:towerMessage(1),
    { bank = 0, number = 0, words = { 42, NULL_WORD } },
    "the setter copies its input and normalizes the unused word"
  )
  state:setTerminalGreeting({ bank = 4, number = 0, words = { 42, 7 } })
  Assert.deepEqual(
    state:terminalGreeting(),
    { bank = 4, number = 0, words = { NULL_WORD, NULL_WORD } },
    "the zero-slot setter clears both words"
  )
  state:setTowerMessage(2, { bank = 0, number = 1, words = { 42, 7 } })
  Assert.deepEqual(
    state:towerMessage(2),
    { bank = 0, number = 1, words = { 42, 7 } },
    "a two-slot setter keeps both words"
  )
  Assert.deepEqual(state:towerMessage(1), { bank = 0, number = 0, words = { 42, NULL_WORD } }, "slots stay independent")

  local badSlot = pcall(state.towerMessage, state, 0)
  Assert.isFalse(badSlot, "tower slot zero fails")
  local badHigh = pcall(state.towerMessage, state, 5)
  Assert.isFalse(badHigh, "tower slot five fails")
end

return T
