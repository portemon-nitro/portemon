-- Word-script domain semantics against explicit parent data: the
-- script service maps editor kinds to shared-editor requests, owns the
-- separate Tower and terminal save policies, learns trendy words through
-- the existing random stream with exactly one draw per grant, matches
-- fixed phrases against cold message banks, and resolves every
-- deferred-parent branch (fashion title, Union records and languages,
-- Frontier intros, Trainer House intros) without fabricating parent
-- gameplay. Synthetic catalogs, banks, and contexts only; no dump data.

local Assert = require("tests.support.Assert")

local T = {
  metadata = {
    tags = { "easychat" },
  },
  tests = {},
}

local NULL_WORD = 0xFFFF

-- Loads a word-script module that does not exist yet at this baseline.
-- The failure names the missing behaviour instead of surfacing as a
-- suite load error, so the pre-implementation red stays attributable.
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

---@return table service module
local function requireService()
  return requireFeature(
    "game.hgss.src.easychat.EasyChatScriptService",
    "the field script has no word domain service yet: no word command can resolve its operands, results, or save policy"
  )
end

---@param id integer
---@param code integer
---@param text string
---@return table word record
local function wordRecord(id, code, text)
  return {
    id = id,
    tokens = {
      { kind = "glyph", code = code, text = text, raw = { code } },
      { kind = "eos", raw = { 0xFFFF } },
    },
  }
end

---@return table synthetic catalog data
local function syntheticData()
  local words = {
    wordRecord(41, 0x51, "Q"),
    wordRecord(42, 0x52, "R"),
    wordRecord(1107, 0x61, "a"),
    wordRecord(1113, 0x62, "b"),
    wordRecord(1139, 0x63, "c"),
    wordRecord(1281, 0x64, "d"),
    wordRecord(1403, 0x65, "e"),
  }
  for bit = 0, 5 do
    words[#words + 1] = {
      id = 1182 + bit,
      tokens = {
        { kind = "glyph", code = 0x70 + bit, text = "G" .. bit, raw = { 0x70 + bit } },
        { kind = "eos", raw = { 0xFFFF } },
      },
      eligibility = { kind = "greeting", bit = bit },
    }
  end
  for bit = 0, 31 do
    words[#words + 1] = {
      id = 1440 + bit,
      tokens = {
        { kind = "glyph", code = 0x100 + bit, text = "T" .. bit, raw = { 0x100 + bit } },
        { kind = "eos", raw = { 0xFFFF } },
      },
      eligibility = { kind = "trendy", bit = bit },
    }
  end
  local function glyph(code, text)
    return { kind = "glyph", code = code, text = text, raw = { code } }
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
    { bank = 0, number = 0, wordCount = 1, tokens = { slot(0), { kind = "eos", raw = { 0xFFFF } } } },
    { bank = 0, number = 1, wordCount = 2, tokens = { slot(0), slot(1), { kind = "eos", raw = { 0xFFFF } } } },
    { bank = 1, number = 0, wordCount = 1, tokens = { slot(0), { kind = "eos", raw = { 0xFFFF } } } },
    { bank = 1, number = 4, wordCount = 1, tokens = { slot(0), { kind = "eos", raw = { 0xFFFF } } } },
    { bank = 2, number = 0, wordCount = 1, tokens = { slot(0), { kind = "eos", raw = { 0xFFFF } } } },
    { bank = 4, number = 0, wordCount = 0, tokens = { glyph(0x5A, "Z"), { kind = "eos", raw = { 0xFFFF } } } },
  }
  local groups = {}
  for index = 1, 12 do
    groups[index] = { key = string.format("group%02d", index - 1), labelTokens = {}, wordIds = {} }
  end
  local initials = {}
  for index = 1, 27 do
    initials[index] = { key = string.format("initial%02d", index - 1), labelTokens = {}, candidates = {} }
  end
  local grid = {}
  for index = 1, 27 do
    grid[index] =
      { char = index, x = index, y = 0, up = 0xFE, down = 0, left = 0, right = 0, belowBack = 0, aboveBack = 0 }
  end
  local rows = {}
  for index = 1, 16 do
    rows[index] = { 0, 0, 0 }
  end
  local choices = {}
  for index = 1, 8 do
    choices[index] = { index - 1, index + 7, index + 15, index + 23 }
  end
  return {
    words = words,
    templates = templates,
    groups = groups,
    initials = initials,
    primoWords = { 1107, 1113 },
    unionAvatars = { choices = choices, rows = rows },
    gridCells = grid,
  }
end

---@return table catalog, table state
local function catalogAndState()
  local EasyChatCatalog = require("libs.hgss.src.ui.EasyChatCatalog")
  local EasyChatState = require("libs.hgss.src.save.EasyChatState")
  local catalog = EasyChatCatalog.new(syntheticData())
  return catalog, EasyChatState.restore(nil, "english", catalog)
end

---@return table world state resolving retail variable names
local function testWorld()
  local WorldState = require("libs.hgss.src.script.WorldState")
  local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
  return WorldState.new({
    catalogs = { flags = FieldScriptSymbols.flagsByName, variables = FieldScriptSymbols.variablesByName },
  })
end

---@param tokens table[]
---@return table bank artifact
local function glyphBank(bankId, messages)
  local FieldMessageCache = require("libs.assets.src.field.FieldMessageCache")
  local packed = {}
  local count = 0
  for id, glyphs in pairs(messages) do
    local tokens = {}
    for _, code in ipairs(glyphs) do
      tokens[#tokens + 1] = { kind = "glyph", code = code, text = string.char(64 + (code % 26)), raw = { code } }
    end
    tokens[#tokens + 1] = { kind = "eos", raw = { 0xFFFF } }
    packed[id] = { id = id, raw = {}, text = "bank" .. bankId .. "/" .. id, tokens = tokens }
    count = count + 1
  end
  return {
    schema = FieldMessageCache.SCHEMA,
    bankId = bankId,
    messageCount = count,
    source = { narc = "NARC_msgdata_msg", memberId = bankId, memberSha1 = "synthetic" },
    messages = packed,
  }
end

-- Message banks behind the deferred-parent branches: the fixed-phrase
-- pair, the raw Frontier intro bank, the trainer-class name bank, and
-- the Union language bank. Word glyph codes match the synthetic
-- catalog so fixed-phrase comparison has a shared alphabet.
---@return table provider
local function providerWith(banks)
  local CacheFs = require("libs.storage.src.CacheFs")
  local FakeCache = require("tests.support.FakeCache")
  local FieldMessageCache = require("libs.assets.src.field.FieldMessageCache")
  local FieldMessageProvider = require("libs.hgss.src.interaction.FieldMessageProvider")
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  for bankId, artifact in pairs(banks) do
    cache:writeLua(FieldMessageCache.bankPath(bankId), artifact)
  end
  return assert(FieldMessageProvider.new(cache))
end

---@return table provider with the fixed-phrase pair
local function fixedPhraseProvider()
  local FieldMessageCache = require("libs.assets.src.field.FieldMessageCache")
  local pair = {
    schema = FieldMessageCache.SCHEMA,
    bankId = 202,
    messageCount = 2,
    source = { narc = "NARC_msgdata_msg", memberId = 202, memberSha1 = "synthetic" },
    messages = {
      [0] = {
        id = 0,
        raw = {},
        text = "reference",
        tokens = {
          { kind = "glyph", code = 0x51, text = "Q", raw = { 0x51 } },
          { kind = "glyph", code = 0x52, text = "R", raw = { 0x52 } },
          { kind = "eos", raw = { 0xFFFF } },
        },
      },
      [1] = {
        id = 1,
        raw = {},
        text = "candidate",
        tokens = {
          { kind = "substitution", control = 0x0100, args = { 0, 0 }, raw = { 0xFFFE, 0x100, 1, 0 } },
          { kind = "substitution", control = 0x0100, args = { 1, 0 }, raw = { 0xFFFE, 0x100, 1, 1 } },
          { kind = "eos", raw = { 0xFFFF } },
        },
      },
    },
  }
  return providerWith({ [202] = pair })
end

-- A scripted random stream answering the service's single labeled draw
-- with queued values while recording every draw it performs.
---@param draws integer[]
---@return table random, table record
local function stubRandom(draws)
  local record = { calls = {}, keys = {} }
  local random = {}
  function random:lc(key)
    record.calls[#record.calls + 1] = key
    record.keys[key] = (record.keys[key] or 0) + 1
    local value = table.remove(draws, 1)
    assert(value ~= nil, "the trendy draw ran without a queued value for " .. tostring(key))
    return value
  end
  return random, record
end

---@param overrides table?
---@return table service arguments
local function serviceArgs(overrides)
  local catalog, state = catalogAndState()
  local args = {
    catalog = catalog,
    state = state,
    profile = { name = "GOLD", gender = 0, avatarSprite = 0, language = "english" },
    mons = {},
    world = testWorld(),
    random = stubRandom({}),
    messageProvider = fixedPhraseProvider(),
    contexts = {},
  }
  for key, value in pairs(overrides or {}) do
    args[key] = value
  end
  return args
end

-- Editor kinds map to shared-editor requests with initialized empty
-- words: outside kinds take the single-word default, pair and tower
-- kinds take their modes, and the invalid single-output wrapper kind
-- fails before anything opens.
function T.tests.editor_kinds_map_to_initialized_requests()
  local Service = requireService()
  local args = serviceArgs()
  local service = Service.new(args)
  local single = service:requestForKind(0, "buttons")
  Assert.equal(single.mode, 0, "kind zero opens the single-word editor")
  Assert.deepEqual(single.words, { NULL_WORD, NULL_WORD }, "launch initializes empty words")
  Assert.equal(single.inputMode, "buttons", "the request carries its entry modality")
  local tower = service:requestForKind(3, "touch")
  Assert.equal(tower.mode, 2, "tower kinds open the sentence editor")
  Assert.deepEqual(tower.message, args.state:towerMessage(2), "tower kinds load their saved slot")
  Assert.isTrue(tower.alwaysConfirm, "tower requests confirm unconditionally")
  local pair = service:requestForKind(1, "buttons")
  Assert.equal(pair.mode, 1, "the pair kind opens the two-word editor")
  Assert.deepEqual(pair.words, { NULL_WORD, NULL_WORD }, "pair launch initializes both words")
  local fallback = service:requestForKind(99, "buttons")
  Assert.equal(fallback.mode, 0, "an out-of-range kind takes the source default")
end

-- The wrapper commits only accepted-and-changed tower phrases, while the
-- greeting commits any acceptance: unchanged acceptance and
-- cancellation leave saved phrases alone.
function T.tests.wrapper_and_greeting_commits_keep_distinct_save_policies()
  local Service = requireService()
  local args = serviceArgs()
  local service = Service.new(args)
  local before = args.state:capture()
  service:commitWrapper(3, { mode = 2, cancelled = true, changed = false })
  service:commitWrapper(3, { mode = 2, cancelled = false, changed = false })
  Assert.deepEqual(args.state:capture(), before, "cancelled and unchanged wrappers save nothing")
  local edited = { bank = 1, number = 4, words = { 1107, NULL_WORD } }
  service:commitWrapper(3, { mode = 2, message = edited, cancelled = false, changed = true })
  Assert.deepEqual(args.state:towerMessage(2), edited, "an accepted-and-changed wrapper saves its tower slot")
  Assert.deepEqual(
    args.state:terminalGreeting(),
    before.terminalGreeting,
    "wrapper commits never touch the terminal phrase"
  )
  service:commitGreeting({ mode = 2, cancelled = true, changed = false })
  Assert.deepEqual(args.state:terminalGreeting(), before.terminalGreeting, "a cancelled greeting saves nothing")
  service:commitGreeting({ mode = 2, message = args.state:towerMessage(1), cancelled = false, changed = false })
  Assert.deepEqual(
    args.state:terminalGreeting(),
    args.state:towerMessage(1),
    "an unchanged greeting acceptance still saves"
  )
end

-- Trendy learning draws exactly once per grant and picks the drawn
-- rank among the still-locked words: every rank is reachable, the top
-- bit uses unsigned-safe arithmetic, and exhaustion draws nothing.
function T.tests.trendy_learning_draws_once_and_covers_every_rank()
  local Service = requireService()
  for target = 0, 31 do
    local args = serviceArgs()
    local mask = (2 ^ 32 - 1) - 2 ^ target
    for bit = 0, 31 do
      if bit ~= target then
        args.state:learnTrendy(bit)
      end
    end
    Assert.equal(args.state:readUnlocks().trendy, mask, "the fixture locks every word but the target rank")
    local random, record = stubRandom({ 0 })
    args.random = random
    local service = Service.new(args)
    local index, effects = service:unlockTrendy()
    Assert.equal(index, target, "a zero draw grants rank " .. target)
    Assert.equal(#record.calls, 1, "a grant draws exactly once")
    Assert.equal(record.calls[1], "easy-chat-trendy", "the grant draws from the labeled word stream")
    Assert.isTrue(args.state:readUnlocks().trendy == 2 ^ 32 - 1, "the grant learns its word")
    local buffered = 0
    for _, effect in pairs(effects) do
      buffered = buffered + 1
      Assert.equal(effect.value, 1440 + target, "the grant buffers the learned global word")
    end
    Assert.equal(buffered, 1, "the grant buffers exactly one learned word")
  end
  local exhausted = serviceArgs()
  for bit = 0, 31 do
    exhausted.state:learnTrendy(bit)
  end
  local random, record = stubRandom({})
  exhausted.random = random
  local service = Service.new(exhausted)
  local index, effects = service:unlockTrendy()
  Assert.equal(index, 0xFFFF, "exhaustion reports no word")
  Assert.equal(#record.calls, 0, "exhaustion performs no draw")
  Assert.deepEqual(effects, {}, "exhaustion buffers nothing")
end

-- The learned-words query answers exactly when all thirty-two bits
-- are set.
function T.tests.learned_words_query_answers_only_on_the_full_mask()
  local Service = requireService()
  local args = serviceArgs()
  local service = Service.new(args)
  Assert.equal(service:allTrendyUnlocked(), 0, "an empty mask is not complete")
  args.state:learnTrendy(31)
  Assert.equal(service:allTrendyUnlocked(), 0, "one learned word is not complete")
  for bit = 0, 30 do
    args.state:learnTrendy(bit)
  end
  Assert.equal(service:allTrendyUnlocked(), 1, "the full mask answers learned")
end

-- Fixed phrases compare the expanded candidate against the reference
-- character sequence: order matters, and no case folding or trimming
-- can rescue a mismatch.
function T.tests.fixed_phrases_compare_exact_character_sequences()
  local Service = requireService()
  local args = serviceArgs()
  local service = Service.new(args)
  Assert.equal(service:fixedPhraseMatches({ 41, 42, NULL_WORD, NULL_WORD }), 1, "the matching phrase answers one")
  Assert.equal(service:fixedPhraseMatches({ 42, 41, NULL_WORD, NULL_WORD }), 0, "a reordered phrase answers zero")
  Assert.equal(service:fixedPhraseMatches({ 41, 41, NULL_WORD, NULL_WORD }), 0, "a repeated word answers zero")
end

-- Fashion titles mutate only the first word of the validated entry and
-- keep its number; invalid entries and missing owners fail instead of
-- fabricating a title.
function T.tests.fashion_titles_mutate_only_the_first_word()
  local Service = requireService()
  local entry = { valid = true, mailMessage = { bank = 2, number = 7, words = { 41, 42 } } }
  local args = serviceArgs({ contexts = { fashion = { entry0 = entry } } })
  local service = Service.new(args)
  service:fashionTitleWord(1107)
  Assert.equal(entry.mailMessage.words[1], 1107, "the title sets the first word")
  Assert.equal(entry.mailMessage.words[2], 42, "the title keeps the second word")
  Assert.equal(entry.mailMessage.number, 7, "the title keeps the message number")
  Assert.equal(entry.mailMessage.bank, 2, "the title keeps the message bank")
  service:fashionTitleWord(NULL_WORD)
  Assert.equal(entry.mailMessage.words[1], NULL_WORD, "the title reset clears the first word")
  local bad = serviceArgs({ contexts = { fashion = { entry0 = { valid = false } } } })
  local badService = Service.new(bad)
  Assert.isFalse(pcall(badService.fashionTitleWord, badService, 41), "an invalid fashion entry fails")
  local missing = serviceArgs({ contexts = {} })
  local missingService = Service.new(missing)
  Assert.isFalse(pcall(missingService.fashionTitleWord, missingService, 41), "a missing fashion owner fails")
end

---@return table union room contexts
local function unionContexts(overrides)
  local contexts = {
    unionRoom = {
      records = { false, false, false, false, false, false, false, false, false, false },
      ownChatMessage = { bank = NULL_WORD, number = 0, words = { NULL_WORD, NULL_WORD } },
      profile = { name = "GOLD", gender = 0, avatarSprite = 0, language = "english" },
      parents = {},
      connectedPartner = nil,
    },
  }
  for key, value in pairs(overrides or {}) do
    contexts.unionRoom[key] = value
  end
  return contexts
end

-- Union own-message branches select their contextual message: an
-- occupied record wins, then the uninitialized own message, then the
-- avatar class read, then the Battle Tower sentence with its source
-- clamp. The clamp never mutates the parent record.
function T.tests.union_own_message_selects_contextual_branches()
  local Service = requireService()
  local banks = {
    [730] = glyphBank(730, { [0] = { 0x4C, 0x41, 0x53, 0x53 }, [1] = { 0x58 } }),
  }
  local args = serviceArgs()
  args.messageProvider = providerWith(banks)
  args.contexts = unionContexts()
  local service = Service.new(args)
  local empty = service:unionOwnChatMessage()
  Assert.equal(empty.message.bank, NULL_WORD, "an uninitialized own message keeps its bank")
  Assert.equal(empty.message.number, 167, "an uninitialized own message selects its branch")
  Assert.deepEqual(empty.buffers, {}, "the uninitialized branch buffers nothing")
  args.contexts = unionContexts({
    records = { false, false, { occupied = true }, false, false, false, false, false, false, false },
  })
  local occupied = Service.new(args):unionOwnChatMessage()
  Assert.equal(occupied.message.number, 166, "any occupied record selects its branch")
  args.contexts = unionContexts({ ownChatMessage = { bank = 0, number = 0, words = { 41, 42 } } })
  local classed = Service.new(args):unionOwnChatMessage()
  Assert.equal(classed.message.number, 168, "an initialized non-tower message selects the class branch")
  Assert.equal(classed.buffers[0].text, "literal_text", "the class branch buffers literal text")
  Assert.notNil(classed.buffers[0].value, "the class branch buffers the resolved class name")
  local towerMessage = { bank = 4, number = 2, words = { 41, 42 } }
  args.contexts = unionContexts({ ownChatMessage = towerMessage })
  local towered = Service.new(args):unionOwnChatMessage()
  Assert.equal(towered.message.number, 169 + 2, "a tower message selects its numbered branch")
  local clampedMessage = { bank = 4, number = 25, words = { 41, 42 } }
  args.contexts = unionContexts({ ownChatMessage = clampedMessage })
  local clamped = Service.new(args):unionOwnChatMessage()
  Assert.equal(clamped.message.number, 169, "an out-of-range tower number clamps to zero")
  Assert.equal(clampedMessage.number, 25, "the clamp never mutates the parent record")
  local missing = serviceArgs({ contexts = {} })
  Assert.isFalse(
    pcall(function()
      return Service.new(missing):unionOwnChatMessage()
    end),
    "a missing union owner fails"
  )
end

-- Union partner languages grant exactly the six mapped greetings with
-- partner, local, and language buffers; other languages take the
-- fallback message with no grant, a missing partner is a no-op, and a
-- foreign party mon never implies a greeting on its own.
function T.tests.union_partner_languages_grant_only_mapped_greetings()
  local Service = requireService()
  local languages = {}
  for id = 211, 217 do
    languages[id] = { 0x40 + id }
  end
  local args = serviceArgs()
  args.messageProvider = providerWith({ [738] = glyphBank(738, languages) })
  args.mons = { { species = "PIKACHU", language = "japanese" } }
  local grants = { [1] = 0, [2] = 1, [3] = 2, [4] = 3, [5] = 4, [7] = 5 }
  for language, bit in pairs(grants) do
    local fresh = serviceArgs()
    fresh.messageProvider = args.messageProvider
    fresh.mons = args.mons
    fresh.contexts = unionContexts({ connectedPartner = { name = "SILVER", language = language } })
    local service = Service.new(fresh)
    local outcome = service:unionPartnerLanguage(1, 0)
    Assert.equal(outcome.message.number, 211 + bit, "language " .. language .. " selects its message")
    Assert.equal(outcome.buffers[0].value, "SILVER", "the partner name buffers into slot zero")
    Assert.equal(outcome.buffers[1].value, "GOLD", "the local name buffers into slot one")
    Assert.notNil(outcome.buffers[2].value, "the language name buffers into slot two")
    local unlocks = fresh.state:readUnlocks()
    Assert.isTrue(math.floor(unlocks.greetings / 2 ^ bit) % 2 == 1, "language " .. language .. " grants its greeting")
  end
  local parented = serviceArgs()
  parented.messageProvider = args.messageProvider
  parented.contexts = unionContexts({ parents = { [0] = { name = "DAD", language = 1 } } })
  local parentService = Service.new(parented)
  local parented_outcome = parentService:unionPartnerLanguage(0, 1)
  Assert.equal(parented_outcome.message.number, 211, "mode zero reads the interacted parent profile")
  Assert.equal(parented_outcome.buffers[0].value, "DAD", "the parent name buffers into slot zero")
  for _, language in ipairs({ 6, 9 }) do
    local fresh = serviceArgs()
    fresh.messageProvider = args.messageProvider
    fresh.mons = args.mons
    fresh.contexts = unionContexts({ connectedPartner = { name = "SILVER", language = language } })
    local before = fresh.state:readUnlocks().greetings
    local service = Service.new(fresh)
    local outcome = service:unionPartnerLanguage(1, 0)
    Assert.equal(outcome.message.number, 217, "language " .. language .. " takes the fallback message")
    Assert.equal(fresh.state:readUnlocks().greetings, before, "language " .. language .. " grants no greeting")
  end
  local absent = serviceArgs()
  absent.messageProvider = args.messageProvider
  absent.contexts = unionContexts({ connectedPartner = nil })
  local beforeAbsent = absent.state:readUnlocks().greetings
  local absentService = Service.new(absent)
  Assert.isNil(absentService:unionPartnerLanguage(3, 0), "a missing partner is a silent no-op")
  Assert.equal(absent.state:readUnlocks().greetings, beforeAbsent, "a missing partner grants nothing")
end

-- Frontier intros resolve their source variants: absent context is a
-- silent no-op, an empty bank reads the raw intro bank, and anything
-- else returns its sentence for ordinary printing.
function T.tests.frontier_intros_resolve_source_variants()
  local Service = requireService()
  local args = serviceArgs()
  local service = Service.new(args)
  Assert.isNil(service:frontierIntro(0), "an absent frontier context is a silent no-op")
  local opponents = {
    { introMessage = { bank = NULL_WORD, number = 5, words = { 41, 42 } } },
    { introMessage = { bank = 0, number = 0, words = { 41, NULL_WORD } } },
  }
  local fronted = serviceArgs({ contexts = { frontier = { opponents = opponents } } })
  local frontedService = Service.new(fronted)
  local raw = frontedService:frontierIntro(0)
  Assert.equal(raw.message.bank, 723, "an empty intro bank reads the raw intro bank")
  Assert.equal(raw.message.number, 5, "the raw intro keeps its message number")
  local sentence = frontedService:frontierIntro(1)
  Assert.deepEqual(sentence.message, opponents[2].introMessage, "a sentence intro returns its sentence")
end

-- Trainer House intros return saved sentences and the source default:
-- the default needs no parent context and carries the documented
-- trainer-bank identity.
function T.tests.trainer_house_intros_return_saved_and_default_sentences()
  local Service = requireService()
  local sets = {}
  for index = 1, 10 do
    sets[index] = { trainer = { introMessage = { bank = 0, number = 0, words = { 40 + index, NULL_WORD } } } }
  end
  local args = serviceArgs({ contexts = { trainerHouse = { sets = sets } } })
  local service = Service.new(args)
  for index = 0, 9 do
    local outcome = service:trainerHouseIntro(index)
    Assert.deepEqual(
      outcome.message,
      sets[index + 1].trainer.introMessage,
      "trainer index " .. index .. " returns its saved intro"
    )
  end
  local defaulted = service:trainerHouseIntro(10)
  Assert.deepEqual(
    defaulted.message,
    { bank = 0, number = 3, words = { 1119, NULL_WORD } },
    "the out-of-range index returns the source default intro"
  )
  local bare = Service.new(serviceArgs({ contexts = {} }))
  local bareDefault = bare:trainerHouseIntro(10)
  Assert.deepEqual(
    bareDefault.message,
    { bank = 0, number = 3, words = { 1119, NULL_WORD } },
    "the default intro needs no parent context"
  )
  Assert.isFalse(pcall(bare.trainerHouseIntro, bare, 2), "a saved intro without its owner fails")
end

-- Buffered word text resolves through the shared catalog and the null
-- identity stays empty: later variable writes cannot move an already
-- buffered snapshot.
function T.tests.buffered_word_text_resolves_through_the_shared_catalog()
  requireService()
  local Dsl = require("libs.script.src.Dsl")
  local ScriptDialogueHost = require("libs.hgss.src.script.ScriptDialogueHost")
  local FieldYesNoController = require("libs.hgss.src.ui.FieldYesNoController")
  local catalog, _ = catalogAndState()
  local provider = providerWith({})
  local controller = {
    open = function(self, request)
      self.request = request
    end,
    close = function(self)
      self.request = nil
    end,
  }
  local hostObject = ScriptDialogueHost.new({
    controller = controller,
    yesNoController = FieldYesNoController.new(),
    provider = provider,
    layout = function(formatted)
      return formatted
    end,
    fontDef = { charmap = {} },
    player = {
      name = function()
        return "GOLD"
      end,
    },
    easyChatCatalog = catalog,
  })
  local resolved = hostObject:resolveMessage(Dsl.easyChatMessage(0, 0, 41, NULL_WORD), {}, {})
  Assert.deepEqual(resolved.tokens, catalog:wordTokens(41), "a buffered word resolves its catalog fragments")
  local empty = hostObject:resolveMessage(Dsl.easyChatMessage(0, 0, NULL_WORD, NULL_WORD), {}, {})
  Assert.deepEqual(empty.tokens, {}, "the null identity buffers no fragments")
end

-- An explicitly requested instant word message reveals its whole
-- authored content in the same tick and waits print-complete like any
-- ordinary message; ordinary word printing keeps its cadence.
function T.tests.instant_word_messages_reveal_same_tick_while_typed_keeps_cadence()
  requireService()
  local FieldDialogueController = require("libs.hgss.src.ui.FieldDialogueController")
  local catalog, _ = catalogAndState()
  local first = assert(catalog:wordTokens(41)[1], "the fixture word carries its glyph")
  local second = assert(catalog:wordTokens(42)[1], "the second fixture word carries its glyph")
  local glyphs = { first, second }
  local function page()
    return { lines = { { tokens = glyphs, width = 0 } }, breakKind = "eos" }
  end
  local function controller()
    return FieldDialogueController.new({
      layout = function()
        return { pages = { page() }, warnings = {}, lineHeight = 16, lineSpacing = 0 }
      end,
      policy = { interGlyphDelay = 7, glyphBudget = 1, abAcceleration = true },
      audio = { play = function() end },
      continueCursor = {
        cycle = { 0, 1, 2, 3 },
        framePrinterTicks = 9,
        placement = { x = 0, y = 0, width = 16, height = 16 },
      },
    })
  end
  local function message()
    return {
      bankId = 0,
      messageId = 0,
      text = "",
      tokens = glyphs,
      hadUnresolvedSubstitutions = false,
    }
  end
  local instant = controller()
  instant:open({ id = "instant", message = message(), allowCancel = false, instant = true })
  Assert.equal(instant:status().revealedGlyphs, #glyphs, "an instant request reveals its whole content same tick")
  local typed = controller()
  typed:open({ id = "typed", message = message(), allowCancel = false })
  typed:step({})
  Assert.isTrue(typed:status().revealedGlyphs < #glyphs, "ordinary word printing keeps its typed cadence")
end

return T
