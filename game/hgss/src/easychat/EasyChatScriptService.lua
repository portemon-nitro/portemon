-- Source word-command domain semantics over explicit parent data: editor
-- request mapping, separate Battle Tower and terminal save policies,
-- random trendy learning, fixed-phrase matching, and every deferred-parent
-- branch (fashion title, Union records and languages, Frontier intros,
-- Trainer House intros). The service owns domain decisions and save
-- policy only: no script variables, no UI, no network, no generic reward
-- plumbing. Parent records are source command envelopes supplied by the
-- caller, never a second save schema. Game-side leaf: never imported by
-- libs/script.

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.script.src.errors")

---@class EasyChatScriptService
---@field private _catalog table<string, unknown> borrowed shared word catalog
---@field private _state table<string, unknown> authoritative saved word state
---@field private _profile table<string, unknown> borrowed player profile
---@field private _mons table<string, unknown> borrowed live mon service
---@field private _world table<string, unknown> borrowed world state
---@field private _random table<string, unknown> labeled random stream
---@field private _provider table<string, unknown> message bank provider
---@field private _contexts table<string, unknown> explicit parent command envelopes
local EasyChatScriptService = {}
EasyChatScriptService.__index = EasyChatScriptService

EasyChatScriptService.NULL_WORD = 0xFFFF
EasyChatScriptService.TRENDY_BASE_WORD = 1440
EasyChatScriptService.TRENDY_WORD_COUNT = 32
EasyChatScriptService.FULL_TRENDY_MASK = 2 ^ 32 - 1
EasyChatScriptService.FIXED_PHRASE_BANK = 202
EasyChatScriptService.UNION_MESSAGE_BANK = 738
EasyChatScriptService.TRAINER_CLASS_BANK = 730
EasyChatScriptService.FRONTIER_RAW_BANK = 723
EasyChatScriptService.TRENDY_DRAW_LABEL = "easy-chat-trendy"

-- Source language greeting grants behind the partner language command:
-- languages 1, 2, 3, 4, 5, 7 grant bits 0..5 and read messages
-- 211..216; every other language reads the fallback message and grants
-- nothing. The sixth table entry stays empty the way the source table
-- carries -1 for language 6.
local UNION_LANGUAGE_GRANTS = {
  [1] = 0,
  [2] = 1,
  [3] = 2,
  [4] = 3,
  [5] = 4,
  [7] = 5,
}
EasyChatScriptService.UNION_LANGUAGE_BASE_MESSAGE = 211
EasyChatScriptService.UNION_LANGUAGE_FALLBACK_MESSAGE = 217

-- Source Trainer House default intro (overlay_25.c: the trainer-bank base
-- 1106 plus the match index 13): index 10 needs no parent context.
local TRAINER_HOUSE_DEFAULT_INTRO = { bank = 0, number = 3, words = { 1119, 0xFFFF } }

---@param args table<string, unknown>
---@return EasyChatScriptService
function EasyChatScriptService.new(args)
  assert(type(args) == "table", "word script service requires its owners")
  local catalog = assert(args.catalog, "word script service requires the shared word catalog")
  local state = assert(args.state, "word script service requires the saved word state")
  local profile = assert(args.profile, "word script service requires the player profile")
  local mons = assert(args.mons, "word script service requires the mon service")
  local world = assert(args.world, "word script service requires the world state")
  local random = assert(args.random, "word script service requires the random stream")
  local provider = assert(args.messageProvider, "word script service requires the message provider")
  assert(type(catalog) == "table", "word script service borrows the shared word catalog")
  assert(type(state) == "table", "word script service borrows the saved word state")
  assert(type(profile) == "table", "word script service borrows the player profile")
  assert(type(mons) == "table", "word script service borrows the mon service")
  assert(type(world) == "table", "word script service borrows the world state")
  assert(type(random.lc) == "function", "word script service draws through the labeled random stream")
  assert(type(provider.acquireBank) == "function", "word script service leases message banks")
  return setmetatable({
    _catalog = catalog,
    _state = state,
    _profile = profile,
    _mons = mons,
    _world = world,
    _random = random,
    _provider = provider,
    _contexts = args.contexts or {},
  }, EasyChatScriptService)
end

---@param words table<string, unknown>
---@return table<string, unknown> detached sentence
local function copySentence(words)
  return { bank = words.bank, number = words.number, words = { words.words[1], words.words[2] } }
end

-- Maps one wrapper launch kind to its shared-editor request: pair kinds
-- open the two-word editor with initialized empty words, tower kinds open
-- the sentence editor over the matching saved slot with unconditional
-- confirmation, and any other kind takes the single-word source default.
---@param kind integer evaluated launch kind
---@param inputMode string entry modality
---@return table<string, unknown> editor request
function EasyChatScriptService:requestForKind(kind, inputMode)
  local null = EasyChatScriptService.NULL_WORD
  if kind == 1 then
    return { mode = 1, words = { null, null }, promptId = 0, alwaysConfirm = false, inputMode = inputMode }
  end
  if type(kind) == "number" and kind % 1 == 0 and kind >= 2 and kind <= 5 then
    return {
      mode = 2,
      message = self._state:towerMessage(kind - 1),
      promptId = 0,
      alwaysConfirm = true,
      inputMode = inputMode,
    }
  end
  return { mode = 0, words = { null, null }, promptId = 0, alwaysConfirm = false, inputMode = inputMode }
end

-- The terminal greeting request: the sentence editor over the separate
-- terminal phrase with unconditional confirmation.
---@param inputMode string entry modality
---@return table<string, unknown> editor request
function EasyChatScriptService:requestForGreeting(inputMode)
  return {
    mode = 2,
    message = self._state:terminalGreeting(),
    promptId = 0,
    alwaysConfirm = true,
    inputMode = inputMode,
  }
end

-- Commits an accepted-and-changed tower phrase before its first word is
-- published: cancellation and unchanged acceptance save nothing, and
-- wrapper commits never touch the terminal phrase.
---@param kind integer launch kind
---@param result table<string, unknown> terminal editor result
function EasyChatScriptService:commitWrapper(kind, result)
  assert(type(result) == "table", "wrapper commits read the terminal result")
  if result.cancelled == true or result.changed ~= true then
    return
  end
  if type(kind) == "number" and kind % 1 == 0 and kind >= 2 and kind <= 5 then
    self._state:setTowerMessage(kind - 1, result.message)
  end
end

-- Commits any terminal greeting acceptance, even unchanged: cancellation
-- saves nothing, acceptance saves the accepted phrase back.
---@param result table<string, unknown> terminal editor result
function EasyChatScriptService:commitGreeting(result)
  assert(type(result) == "table", "greeting commits read the terminal result")
  if result.cancelled == true then
    return
  end
  self._state:setTerminalGreeting(result.message)
end

---@param trendy integer learned bit set
---@return integer[] unset bit ranks in ascending order
local function unsetTrendyRanks(trendy)
  local ranks = {}
  for bit = 0, EasyChatScriptService.TRENDY_WORD_COUNT - 1 do
    if math.floor(trendy / (2 ^ bit)) % 2 == 0 then
      ranks[#ranks + 1] = bit
    end
  end
  return ranks
end

-- Learns exactly one still-locked trendy word: one labeled draw modulo
-- the remaining ranks selects the nth unset bit, the word is learned, and
-- the granted global word buffers at the requested slot. Exhaustion draws
-- nothing and buffers nothing.
---@param slot integer? buffer slot, defaults to zero
---@return integer learned local index, or 0xFFFF when exhausted
---@return table<integer, table<string, unknown>> slot to buffered word descriptor
function EasyChatScriptService:unlockTrendy(slot)
  local at = slot
  if at == nil then
    at = 0
  end
  if type(at) ~= "number" or at % 1 ~= 0 or at < 0 or at > 7 then
    Errors.raise(ScriptErrors.SCRIPT_INVALID_REFERENCE, "trendy unlock buffers slots 0..7", { slot = slot })
  end
  local ranks = unsetTrendyRanks(self._state:readUnlocks().trendy)
  if #ranks == 0 then
    return EasyChatScriptService.NULL_WORD, {}
  end
  local draw = self._random:lc(EasyChatScriptService.TRENDY_DRAW_LABEL)
  assert(type(draw) == "number" and draw % 1 == 0 and draw >= 0, "trendy unlock draws an unsigned rank")
  local rank = ranks[(draw % #ranks) + 1]
  self._state:learnTrendy(rank)
  return rank,
    {
      [at] = {
        text = "easy_chat_word",
        value = EasyChatScriptService.TRENDY_BASE_WORD + rank,
      },
    }
end

-- Answers exactly when all thirty-two trendy words are learned.
---@return integer 1 or 0
function EasyChatScriptService:allTrendyUnlocked()
  if self._state:readUnlocks().trendy == EasyChatScriptService.FULL_TRENDY_MASK then
    return 1
  end
  return 0
end

-- Reads one code-addressed message bank with scoped ownership: the lease
-- releases on every exit, including failures.
---@param bankId integer
---@return fun() bank lease release function
local function acquireMessageBank(self, bankId)
  local acquired, acquireErr = self._provider:acquireBank(bankId)
  if not acquired then
    error(acquireErr, 0)
  end
  local function releaseBank()
    self._provider:releaseBank(bankId)
  end
  return releaseBank
end

-- Compares the expanded fixed-phrase candidate against the reference as
-- source character sequences: only glyph code units compare, display-only
-- metadata never rescues a mismatch.
---@param candidateTokens table<integer, table<string, unknown>>
---@param referenceTokens table<integer, table<string, unknown>>
---@return boolean
local function sameGlyphSequence(candidateTokens, referenceTokens)
  local candidate, reference = {}, {}
  for _, token in ipairs(candidateTokens) do
    if token.kind == "glyph" then
      candidate[#candidate + 1] = token.code
    end
  end
  for _, token in ipairs(referenceTokens) do
    if token.kind == "glyph" then
      reference[#reference + 1] = token.code
    end
  end
  if #candidate ~= #reference then
    return false
  end
  for index = 1, #candidate do
    if candidate[index] ~= reference[index] then
      return false
    end
  end
  return true
end

-- Matches four evaluated words against the fixed phrase: the candidate
-- expands message 1 through the four buffered identities and compares
-- against message 0. Reads the leased bank through the existing token
-- formatter on every path and releases it on every exit.
---@param words integer[] four evaluated word identities
---@return integer 1 on an exact match, else 0
function EasyChatScriptService:fixedPhraseMatches(words)
  assert(type(words) == "table" and #words == 4, "fixed phrases compare four words")
  local bankId = EasyChatScriptService.FIXED_PHRASE_BANK
  local release = acquireMessageBank(self, bankId)
  local ok, matched = pcall(function()
    local template, templateErr = self._provider:get(bankId, 1)
    if not template then
      error(templateErr, 0)
    end
    local reference, referenceErr = self._provider:get(bankId, 0)
    if not reference then
      error(referenceErr, 0)
    end
    local catalog = self._catalog
    local calls = 0
    local function resolveBufferedWord()
      calls = calls + 1
      local word = words[calls]
      if word == nil or word == EasyChatScriptService.NULL_WORD then
        return {}
      end
      return catalog:wordTokens(word)
    end
    local resolvers = {
      [0x100] = resolveBufferedWord,
    }
    local formatted, formatErr = self._provider.format(self._provider, template, {}, resolvers)
    if not formatted then
      error(formatErr, 0)
    end
    return sameGlyphSequence(formatted.tokens, reference.tokens)
  end)
  release()
  if not ok then
    error(matched, 0)
  end
  if matched == true then
    return 1
  end
  return 0
end

---@param what string parent owner name for attribution
---@return table<string, unknown> fashion parent envelope
local function fashionContext(self, what)
  local fashion = self._contexts.fashion
  if type(fashion) ~= "table" or type(fashion.entry0) ~= "table" then
    Errors.raise(ScriptErrors.FEATURE_UNAVAILABLE, what .. " requires its fashion entry", { owner = "fashion" })
  end
  return fashion.entry0 --[[@as table<string, unknown>]]
end

-- Sets the fashion title's first word on the validated entry, keeping its
-- number, bank, and second word. Invalid entries and missing owners fail
-- instead of fabricating a title.
---@param word integer evaluated title word
function EasyChatScriptService:fashionTitleWord(word)
  if type(word) ~= "number" or word % 1 ~= 0 or word < 0 or word > 0xFFFF then
    Errors.raise(ScriptErrors.SCRIPT_INVALID_REFERENCE, "fashion titles set a u16 word", { word = word })
  end
  local entry = fashionContext(self, "fashion titles")
  if entry.valid ~= true then
    Errors.raise(ScriptErrors.FEATURE_UNAVAILABLE, "fashion titles require a valid entry", { owner = "fashion" })
  end
  local message = entry.mailMessage
  if type(message) ~= "table" or type(message.words) ~= "table" then
    Errors.raise(ScriptErrors.FEATURE_UNAVAILABLE, "fashion titles require their entry message", { owner = "fashion" })
  end
  message.words[1] = word
end

---@param what string parent owner name for attribution
---@return table<string, unknown> union parent envelope
local function unionContext(self, what)
  local unionRoom = self._contexts.unionRoom
  if type(unionRoom) ~= "table" then
    Errors.raise(ScriptErrors.FEATURE_UNAVAILABLE, what .. " requires its Union Room records", { owner = "unionRoom" })
  end
  return unionRoom --[[@as table<string, unknown>]]
end

-- Maps one trainer sprite to its class through the shared avatar rows:
-- the gender half is searched for the sprite and the source row zero
-- answers when no row carries it.
---@param catalog table<string, unknown> borrowed shared word catalog
---@param gender integer player gender half
---@param spriteId integer trainer sprite identity
---@param attribute integer 1 or 2
---@return integer attribute value
local function avatarClassBySprite(catalog, gender, spriteId, attribute)
  local avatars = assert(catalog.unionAvatars, "avatar attributes read the shared avatar rows")
  local rows = assert(avatars.rows, "avatar attributes read sixteen attribute rows")
  local half = (gender == 1) and 8 or 0
  local found = 0
  for index = 0, 7 do
    local row = rows[half + index + 1]
    if type(row) == "table" and row[1] == spriteId then
      found = half + index
      break
    end
  end
  local row = assert(rows[found + 1], "avatar attributes fall back to the source row zero")
  if attribute == 2 then
    return assert(row[2], "avatar attributes carry their class")
  end
  return assert(row[3], "avatar attributes carry their second attribute")
end

-- Reads one plain class name from its generated bank with scoped
-- ownership: the lease releases on every exit, including failures.
---@param classId integer trainer class identity
---@return string plain class name
local function trainerClassName(self, classId)
  local bankId = EasyChatScriptService.TRAINER_CLASS_BANK
  local release = acquireMessageBank(self, bankId)
  local ok, name = pcall(function()
    local template, templateErr = self._provider:get(bankId, classId)
    if not template then
      error(templateErr, 0)
    end
    assert(type(template.text) == "string", "trainer classes carry their plain name")
    return template.text
  end)
  release()
  if not ok then
    error(name, 0)
  end
  return name --[[@as string]]
end

-- Selects the contextual own message: any occupied record wins, then the
-- uninitialized message, then the avatar class with its buffered name,
-- then the Tower sentence with its source clamp. The clamp never mutates
-- the parent record; only the selected branches buffer.
---@return { message: table<string, unknown>, buffers: table<integer, table<string, unknown>> }
function EasyChatScriptService:unionOwnChatMessage()
  local unionRoom = unionContext(self, "Union messages")
  local records = unionRoom.records
  if type(records) ~= "table" then
    Errors.raise(ScriptErrors.FEATURE_UNAVAILABLE, "Union messages require their ten records", { owner = "unionRoom" })
  end
  for _, record in pairs(records) do
    if record ~= nil and record ~= false then
      return {
        message = { bank = EasyChatScriptService.UNION_MESSAGE_BANK, number = 166 },
        buffers = {},
      }
    end
  end
  local own = unionRoom.ownChatMessage
  if type(own) ~= "table" then
    Errors.raise(ScriptErrors.FEATURE_UNAVAILABLE, "Union messages require their own message", { owner = "unionRoom" })
  end
  if own.bank == EasyChatScriptService.NULL_WORD then
    return { message = { bank = own.bank, number = 167 }, buffers = {} }
  end
  if own.bank ~= 4 then
    local profile = unionRoom.profile
    if type(profile) ~= "table" then
      Errors.raise(
        ScriptErrors.FEATURE_UNAVAILABLE,
        "Union messages require their own profile",
        { owner = "unionRoom" }
      )
    end
    local classId = avatarClassBySprite(self._catalog, profile.gender or 0, profile.avatarSprite or 0, 2)
    return {
      message = { bank = EasyChatScriptService.UNION_MESSAGE_BANK, number = 168 },
      buffers = { [0] = { text = "literal_text", value = trainerClassName(self, classId) } },
    }
  end
  local msgNo = own.number
  if type(msgNo) ~= "number" or msgNo < 0 or msgNo % 1 ~= 0 then
    Errors.raise(ScriptErrors.SCRIPT_INVALID_REFERENCE, "Union tower numbers are u16", { number = msgNo })
  end
  if msgNo >= 20 then
    msgNo = 0
  end
  local buffers = {}
  local words = own.words
  if type(words) == "table" and words[1] ~= nil and words[1] ~= EasyChatScriptService.NULL_WORD then
    buffers[0] = { text = "easy_chat_word", value = words[1] }
  end
  return {
    message = { bank = EasyChatScriptService.UNION_MESSAGE_BANK, number = 169 + msgNo },
    buffers = buffers,
  }
end

-- Reads one language display line from its generated bank with scoped
-- ownership: the lease releases on every exit, including failures.
---@param messageId integer language message number
---@return string plain language line
local function unionLanguageLine(self, messageId)
  local bankId = EasyChatScriptService.UNION_MESSAGE_BANK
  local release = acquireMessageBank(self, bankId)
  local ok, line = pcall(function()
    local template, templateErr = self._provider:get(bankId, messageId)
    if not template then
      error(templateErr, 0)
    end
    assert(type(template.text) == "string", "Union language lines carry their plain text")
    return template.text
  end)
  release()
  if not ok then
    error(line, 0)
  end
  return line --[[@as string]]
end

-- Buffers the partner's language: partner, local, and language names ride
-- slots zero through two while the six mapped languages grant their
-- greeting. A missing partner is the source silent no-op; anything else
-- missing is an attributed fault. Party mons never imply a greeting.
---@param mode integer source mode selector
---@param objectId integer? interacted object identity behind mode zero
---@return { message: table<string, unknown>, buffers: table<integer, table<string, unknown>> }? nil on a missing partner
function EasyChatScriptService:unionPartnerLanguage(mode, objectId)
  local unionRoom = unionContext(self, "Union languages")
  local partner = nil
  if mode == 0 then
    local parents = unionRoom.parents
    if type(parents) ~= "table" then
      Errors.raise(
        ScriptErrors.FEATURE_UNAVAILABLE,
        "Union languages require their parent profiles",
        { owner = "unionRoom" }
      )
    end
    if type(objectId) ~= "number" then
      Errors.raise(ScriptErrors.SCRIPT_INVALID_REFERENCE, "Union mode zero reads an object identity", {})
    end
    partner = parents[objectId - 1]
  else
    partner = unionRoom.connectedPartner
  end
  if partner == nil then
    return nil
  end
  if type(partner) ~= "table" or type(partner.name) ~= "string" then
    Errors.raise(ScriptErrors.SCRIPT_INVALID_REFERENCE, "Union partners carry their name", { owner = "unionRoom" })
  end
  local profile = unionRoom.profile
  if type(profile) ~= "table" or type(profile.name) ~= "string" then
    Errors.raise(ScriptErrors.FEATURE_UNAVAILABLE, "Union languages require their own profile", { owner = "unionRoom" })
  end
  local language = partner.language
  local bit = UNION_LANGUAGE_GRANTS[language]
  local messageId = EasyChatScriptService.UNION_LANGUAGE_FALLBACK_MESSAGE
  if bit ~= nil then
    messageId = EasyChatScriptService.UNION_LANGUAGE_BASE_MESSAGE + bit
    self._state:learnGreeting(bit)
  end
  return {
    message = { bank = EasyChatScriptService.UNION_MESSAGE_BANK, number = messageId },
    buffers = {
      [0] = { text = "literal_text", value = partner.name },
      [1] = { text = "literal_text", value = profile.name },
      [2] = { text = "literal_text", value = unionLanguageLine(self, messageId) },
    },
  }
end

-- Resolves the Frontier intro: an absent context is the source silent
-- no-op, an empty bank reads the raw intro bank, and anything else
-- returns its sentence for ordinary printing.
---@param index integer zero-based opponent index
---@return { message: table<string, unknown>, buffers: table<integer, table<string, unknown>> }? nil without its context
function EasyChatScriptService:frontierIntro(index)
  local frontier = self._contexts.frontier
  if frontier == nil then
    return nil
  end
  if type(frontier.opponents) ~= "table" then
    Errors.raise(ScriptErrors.FEATURE_UNAVAILABLE, "Frontier intros require their opponents", { owner = "frontier" })
  end
  if type(index) ~= "number" or index % 1 ~= 0 or index < 0 then
    Errors.raise(ScriptErrors.SCRIPT_INVALID_REFERENCE, "Frontier intros read a zero-based index", { index = index })
  end
  local opponent = frontier.opponents[index + 1]
  if type(opponent) ~= "table" or type(opponent.introMessage) ~= "table" then
    Errors.raise(
      ScriptErrors.FEATURE_UNAVAILABLE,
      "Frontier intros require their opponent message",
      { owner = "frontier", index = index }
    )
  end
  local intro = opponent.introMessage
  if intro.bank == EasyChatScriptService.NULL_WORD then
    return {
      message = { bank = EasyChatScriptService.FRONTIER_RAW_BANK, number = intro.number },
      buffers = {},
    }
  end
  return { message = copySentence(intro), buffers = {} }
end

-- Returns the Trainer House intro: saved sentences for indices zero
-- through nine, the source default for index ten. Saved intros need
-- their owner; the default needs nothing.
---@param index integer evaluated trainer index
---@return { message: table<string, unknown>, buffers: table<integer, table<string, unknown>> }
function EasyChatScriptService:trainerHouseIntro(index)
  if index == 10 then
    return { message = copySentence(TRAINER_HOUSE_DEFAULT_INTRO), buffers = {} }
  end
  if type(index) ~= "number" or index % 1 ~= 0 or index < 0 or index > 9 then
    Errors.raise(ScriptErrors.SCRIPT_INVALID_REFERENCE, "Trainer House intros read indices 0..10", { index = index })
  end
  local house = self._contexts.trainerHouse
  if type(house) ~= "table" or type(house.sets) ~= "table" then
    Errors.raise(
      ScriptErrors.FEATURE_UNAVAILABLE,
      "Trainer House intros require their saved sets",
      { owner = "trainerHouse" }
    )
  end
  local set = house.sets[index + 1]
  if type(set) ~= "table" or type(set.trainer) ~= "table" or type(set.trainer.introMessage) ~= "table" then
    Errors.raise(
      ScriptErrors.FEATURE_UNAVAILABLE,
      "Trainer House intros require their saved intro",
      { owner = "trainerHouse", index = index }
    )
  end
  return { message = copySentence(set.trainer.introMessage), buffers = {} }
end

return EasyChatScriptService
