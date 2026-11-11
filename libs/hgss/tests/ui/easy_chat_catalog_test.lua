-- Shared word catalog semantics: identity decoding through the low
-- twelve bits, detached fragment copies, borrowed template records,
-- message classification, selection-blind sentence expansion, and
-- per-open availability snapshots. Synthetic records only; no ROM data.

local Assert = require("tests.support.Assert")
local EasyChatCatalog = require("libs.hgss.src.ui.EasyChatCatalog")

local T = {
  metadata = {
    tags = { "easychat" },
  },
  tests = {},
}

local NULL_WORD = 0xFFFF

---@param id integer
---@param eligibility table?
---@return table word record
local function wordRecord(id, eligibility)
  return {
    id = id,
    tokens = { { kind = "glyph", code = 1, text = "w" .. id, raw = { 1 } }, { kind = "eos", raw = { 0xFFFF } } },
    eligibility = eligibility or { kind = "always" },
  }
end

---@return table synthetic catalog data
local function syntheticData()
  local words = {
    wordRecord(7),
    wordRecord(42),
    wordRecord(25, { kind = "seen", speciesKey = "PIKACHU" }),
    wordRecord(26, { kind = "seen", speciesKey = "RAICHU" }),
    wordRecord(500, { kind = "gameClear" }),
    wordRecord(1107),
    wordRecord(1113),
    wordRecord(1139),
    wordRecord(1182, { kind = "greeting", bit = 0 }),
    wordRecord(1183, { kind = "greeting", bit = 1 }),
    wordRecord(1281),
    wordRecord(1403),
    wordRecord(1440, { kind = "trendy", bit = 0 }),
    wordRecord(1441, { kind = "trendy", bit = 1 }),
    wordRecord(1472),
  }
  local function glyph(text)
    return { kind = "glyph", code = 1, text = text, raw = { 1 } }
  end
  local function slot(selector)
    return {
      kind = "substitution",
      control = 0x100,
      name = "STRVAR_1",
      args = { selector },
      raw = { 0xFFFE, 0x100, 1, selector },
    }
  end
  local templates = {
    { bank = 0, number = 0, wordCount = 1, tokens = { glyph("T"), slot(0), { kind = "eos", raw = { 0xFFFF } } } },
    { bank = 0, number = 1, wordCount = 2, tokens = { slot(0), slot(1), { kind = "eos", raw = { 0xFFFF } } } },
    { bank = 1, number = 0, wordCount = 1, tokens = { slot(0), { kind = "eos", raw = { 0xFFFF } } } },
    { bank = 1, number = 4, wordCount = 1, tokens = { slot(0), { kind = "eos", raw = { 0xFFFF } } } },
    { bank = 2, number = 0, wordCount = 1, tokens = { slot(0), { kind = "eos", raw = { 0xFFFF } } } },
    { bank = 4, number = 0, wordCount = 0, tokens = { glyph("Z"), { kind = "eos", raw = { 0xFFFF } } } },
  }
  local groups = {}
  for index = 1, 12 do
    groups[index] = { key = string.format("group%02d", index - 1), labelTokens = {}, wordIds = {} }
  end
  groups[1].wordIds = { 25, 26 }
  groups[6].wordIds = { 42 }
  groups[3].wordIds = { 500 }
  groups[7].wordIds = { 1182, 1183, 7 }
  groups[11].wordIds = { 1440, 1441 }
  local initials = {}
  for index = 1, 27 do
    initials[index] = { key = string.format("initial%02d", index - 1), labelTokens = {}, candidates = {} }
  end
  initials[1].candidates = { 25, { 500, 42 }, 7 }
  initials[2].candidates = { { 1182, 1183 } }
  local grid = {}
  for index = 1, 27 do
    grid[index] =
      { char = index, x = index, y = 0, up = 0xFE, down = 0, left = 0, right = 0, belowBack = 0, aboveBack = 0 }
  end
  return {
    words = words,
    templates = templates,
    groups = groups,
    initials = initials,
    primoWords = { 1107, 1113 },
    unionAvatars = { choices = {}, rows = {} },
    gridCells = grid,
  }
end

---@return table catalog
local function owner()
  return EasyChatCatalog.new(syntheticData())
end

function T.tests.null_word_carries_no_fragment_and_identities_decode_through_the_low_twelve_bits()
  local catalog = owner()
  Assert.deepEqual(catalog:wordTokens(NULL_WORD), {}, "the null word carries no fragment")
  local plain = catalog:wordTokens(42)
  Assert.isTrue(#plain > 0, "a known identity resolves its fragments")
  Assert.deepEqual(catalog:wordTokens(42 + 0x1000), plain, "display resolution uses the low twelve bits")
  local ok = pcall(catalog.wordTokens, catalog, 0x0FFF)
  Assert.isFalse(ok, "an unknown decoded identity fails loudly")
end

function T.tests.word_tokens_come_back_detached()
  local catalog = owner()
  local first = catalog:wordTokens(42)
  first[1].text = "mutated"
  first[#first + 1] = { kind = "glyph" }
  local second = catalog:wordTokens(42)
  Assert.equal(second[1].text, "w42", "mutating a fragment leaves the catalog alone")
  Assert.equal(#second, 2, "appending to a fragment leaves the catalog alone")
end

function T.tests.templates_borrow_their_immutable_identity_and_slot_counts()
  local catalog = owner()
  local one = catalog:template(0, 0)
  Assert.notNil(one, "a known identity resolves")
  assert(one ~= nil, "template checked above")
  Assert.equal(one.bank, 0, "the template keeps its logical bank")
  Assert.equal(one.number, 0, "the template keeps its logical number")
  Assert.equal(one.wordCount, 1, "the template keeps its slot count")
  Assert.isTrue(catalog:template(0, 0) == one, "templates borrow their immutable record")
  Assert.equal(catalog:template(0, 1).wordCount, 2, "two-slot templates keep both fields")
  Assert.equal(catalog:template(4, 0).wordCount, 0, "zero-slot templates complete without words")
  Assert.isNil(catalog:template(3, 7), "an unknown identity reads nil")
  Assert.isNil(catalog:template(-1, 0), "an out-of-range bank reads nil")
  Assert.isNil(catalog:template(0, 20), "an out-of-range number reads nil")
end

function T.tests.message_status_classifies_shape_words_templates_and_required_fields()
  local catalog = owner()
  Assert.equal(
    catalog:messageStatus({ bank = 0, number = 0, words = { 42, NULL_WORD } }),
    "complete",
    "a filled slot reads complete"
  )
  Assert.equal(
    catalog:messageStatus({ bank = 0, number = 0, words = { NULL_WORD, NULL_WORD } }),
    "incomplete",
    "a null required field reads incomplete"
  )
  Assert.equal(
    catalog:messageStatus({ bank = 0, number = 1, words = { 42, NULL_WORD } }),
    "incomplete",
    "a half-filled pair reads incomplete"
  )
  Assert.equal(
    catalog:messageStatus({ bank = 4, number = 0, words = { NULL_WORD, NULL_WORD } }),
    "complete",
    "a zero-slot template completes without words"
  )
  Assert.equal(
    catalog:messageStatus({ bank = 0, number = 0, words = { 42, 7 } }),
    "complete",
    "populated unused fields never change the verdict"
  )
  Assert.equal(
    catalog:messageStatus({ bank = 0, number = 0, words = { 99999, NULL_WORD } }),
    "invalid",
    "unknown words read invalid"
  )
  Assert.equal(
    catalog:messageStatus({ bank = 3, number = 7, words = { 42, NULL_WORD } }),
    "invalid",
    "unknown templates read invalid"
  )
  Assert.equal(
    catalog:messageStatus({ bank = 0, number = 0, words = { 42 } }),
    "invalid",
    "malformed shapes read invalid"
  )
  Assert.equal(catalog:messageStatus(nil), "invalid", "a missing message reads invalid")
end

function T.tests.sentence_expansion_ignores_locks_strips_terminators_and_stops_at_the_first_null()
  local catalog = owner()
  local tokens = catalog:expandMessage({ bank = 0, number = 0, words = { 42, NULL_WORD } })
  Assert.isTrue(#tokens > 0, "a complete sentence expands to fragments")
  for _, token in ipairs(tokens) do
    Assert.isTrue(token.kind ~= "eos", "embedded word terminators never concatenate")
  end
  local stopped = catalog:expandMessage({ bank = 0, number = 1, words = { NULL_WORD, 42 } })
  Assert.equal(#stopped, 0, "buffering stops at the first null field")
  local ok = pcall(catalog.expandMessage, catalog, { bank = 3, number = 7, words = { 42, NULL_WORD } })
  Assert.isFalse(ok, "unknown templates fail at the expansion boundary")
  local first = catalog:expandMessage({ bank = 0, number = 1, words = { 42, 7 } })
  first[#first + 1] = { kind = "glyph" }
  local second = catalog:expandMessage({ bank = 0, number = 1, words = { 42, 7 } })
  Assert.equal(#second, #first - 1, "expansions stay detached")
end

function T.tests.menus_filter_by_snapshot_keep_source_order_and_duplicates()
  local catalog = owner()
  local locked = catalog:buildMenu({ gameCleared = false, seen = {}, greetings = 0, trendy = 0 })
  Assert.equal(#locked.groups, 12, "the menu keeps twelve categories")
  Assert.equal(#locked.groups[1].wordIds, 0, "unseen species stay out of their menu")
  Assert.equal(#locked.groups[3].wordIds, 0, "move words wait for game clear")
  Assert.equal(#locked.groups[7].wordIds, 1, "only always-offered greetings survive without bits")
  Assert.equal(locked.groups[7].wordIds[1], 7, "the surviving greeting keeps its identity")
  Assert.equal(#locked.groups[11].wordIds, 0, "trendy words wait for learned bits")
  local cleared = catalog:buildMenu({ gameCleared = true, seen = { PIKACHU = true }, greetings = 3, trendy = 2 })
  Assert.deepEqual(cleared.groups[1].wordIds, { 25 }, "seen species join their category")
  Assert.deepEqual(cleared.groups[3].wordIds, { 500 }, "cleared play offers move words")
  Assert.deepEqual(cleared.groups[7].wordIds, { 1182, 1183, 7 }, "learned greetings join with order kept")
  Assert.deepEqual(cleared.groups[11].wordIds, { 1441 }, "one learned trendy word joins its category")
end

function T.tests.initial_lists_resolve_first_known_alternatives_and_stay_detached()
  local catalog = owner()
  local menu = catalog:buildMenu({ gameCleared = false, seen = { PIKACHU = true }, greetings = 0, trendy = 0 })
  Assert.equal(#menu.initials, 27, "the menu keeps twenty-seven initial lists")
  Assert.deepEqual(
    menu.initials[1].candidates,
    { 25, 42, 7 },
    "singles pass and alternative groups take the first known entry"
  )
  Assert.deepEqual(menu.initials[2].candidates, {}, "an alternative group with no known entry offers nothing")
  menu.initials[1].candidates[1] = 99999
  menu.groups[1].wordIds[1] = 99999
  menu.grid[1].char = 99999
  local rebuilt = catalog:buildMenu({ gameCleared = false, seen = { PIKACHU = true }, greetings = 0, trendy = 0 })
  Assert.deepEqual(rebuilt.initials[1].candidates, { 25, 42, 7 }, "mutating a snapshot leaves later snapshots alone")
  Assert.deepEqual(rebuilt.groups[1].wordIds, { 25 }, "mutating a category leaves later snapshots alone")
  Assert.equal(rebuilt.grid[1].char, 1, "mutating grid geometry leaves later snapshots alone")
  Assert.isTrue(rebuilt.grid ~= menu.grid, "the grid snapshot owns its array")
  Assert.isTrue(rebuilt.grid[1] ~= menu.grid[1], "grid cells stay detached")
end

function T.tests.seen_species_keys_come_back_in_ascending_word_order()
  local catalog = owner()
  Assert.deepEqual(
    catalog:seenSpeciesKeys(),
    { "PIKACHU", "RAICHU" },
    "the open enumerates its seen universe in word order"
  )
end

return T
