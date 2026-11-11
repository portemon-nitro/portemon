-- The shared Easy Chat word, sentence, and menu semantics: canonical
-- identity decoding, template slot interpretation, sentence expansion,
-- and availability-filtered curated menus. The catalog borrows its
-- validated generated records and never mutates them; every query
-- returns detached caller-owned tables except template, which borrows
-- its immutable record. Pure module: no love, no I/O, no save mutation.

---@class EasyChatCatalog
---@field _data table<string, unknown> borrowed validated generated family
---@field _gridCells table<integer, table<string, unknown>> borrowed initial grid geometry
---@field _words table<integer, table<string, unknown>> borrowed dense word rows by identity
---@field _templates table<integer, table<integer, table<string, unknown>>> borrowed template records by bank then number
---@field _groups table<integer, table<string, unknown>> borrowed curated category records
---@field _initials table<integer, table<string, unknown>> borrowed authored initial-list records
---@field primoWords integer[] borrowed ordered password word identities
---@field unionAvatars table<string, unknown> borrowed avatar choice/attribute records
---@field interface table<string, unknown>? borrowed interface text
local EasyChatCatalog = {}
EasyChatCatalog.__index = EasyChatCatalog

EasyChatCatalog.NULL_WORD = 0xFFFF
EasyChatCatalog.DISPLAY_MASK = 0xFFF

---@param data table<string, unknown> validated generated family
---@return EasyChatCatalog
function EasyChatCatalog.new(data)
  assert(type(data) == "table", "the shared catalog borrows its generated records")
  assert(type(data.words) == "table", "the shared catalog carries its dictionary rows")
  assert(type(data.templates) == "table", "the shared catalog carries its templates")
  assert(type(data.groups) == "table", "the shared catalog carries its categories")
  assert(type(data.initials) == "table", "the shared catalog carries its initial lists")
  local words = {}
  for _, record in ipairs(data.words) do
    assert(type(record) == "table" and type(record.id) == "number", "word rows carry their identity")
    words[record.id] = record
  end
  local templates = {}
  for _, record in ipairs(data.templates) do
    assert(type(record) == "table", "templates carry their records")
    local bank = record.bank
    local number = record.number
    assert(type(bank) == "number" and type(number) == "number", "templates carry their identity")
    templates[bank] = templates[bank] or {}
    assert(templates[bank][number] == nil, "template identity repeats")
    templates[bank][number] = record
  end
  return setmetatable({
    _data = data,
    _gridCells = data.gridCells,
    _words = words,
    _templates = templates,
    _groups = data.groups,
    _initials = data.initials,
    primoWords = data.primoWords,
    unionAvatars = data.unionAvatars,
    interface = data.interface,
  }, EasyChatCatalog)
end

---@param token table<string, unknown>
---@return table<string, unknown> detached token copy
local function copyToken(token)
  local out = {}
  for key, value in pairs(token) do
    if type(value) == "table" then
      local items = {}
      for index, item in ipairs(value) do
        items[index] = item
      end
      out[key] = items
    else
      out[key] = value
    end
  end
  return out
end

---@param tokens table<integer, table<string, unknown>>
---@return table<integer, table<string, unknown>> detached token copy
local function copyTokens(tokens)
  local out = {}
  for index, token in ipairs(tokens) do
    out[index] = copyToken(token)
  end
  return out
end

-- Resolves one display fragment stream: the null word carries no
-- fragment, every other identity decodes through its low twelve bits
-- (easy_chat.c:GetECWordMsgNoById) while the full identity stays in
-- transport and storage. Unknown decoded rows fail loudly.
---@param id integer
---@return table<integer, table<string, unknown>> detached fragment tokens
function EasyChatCatalog:wordTokens(id)
  assert(type(id) == "number" and id % 1 == 0 and id >= 0 and id <= 0xFFFF, "word identities are u16")
  if id == EasyChatCatalog.NULL_WORD then
    return {}
  end
  local decoded = id % 4096
  local record = self._words[decoded]
  if record == nil then
    error("unknown word identity: " .. id, 0)
  end
  return copyTokens(record.tokens)
end

-- Borrows the immutable template record for one logical identity, or nil
-- for an unknown identity.
---@param bank integer
---@param number integer
---@return table<string, unknown>? borrowed template record
function EasyChatCatalog:template(bank, number)
  if type(bank) ~= "number" or type(number) ~= "number" then
    return nil
  end
  if bank % 1 ~= 0 or number % 1 ~= 0 or bank < 0 or bank > 4 or number < 0 or number > 19 then
    return nil
  end
  local byBank = self._templates[bank]
  if byBank == nil then
    return nil
  end
  return byBank[number]
end

---@param value unknown
---@return boolean
local function isU16(value)
  return type(value) == "number" and value % 1 == 0 and value >= 0 and value <= 0xFFFF
end

---@param self EasyChatCatalog
---@param wordId integer
---@return boolean known
local function isKnownWord(self, wordId)
  if wordId == EasyChatCatalog.NULL_WORD then
    return true
  end
  return self._words[wordId % 4096] ~= nil
end

-- Classifies one sentence: invalid for malformed shape, unknown words,
-- or unknown templates; incomplete when a required field stays null;
-- complete otherwise. Unused trailing fields may stay populated in a
-- draft without changing the verdict.
---@param message table<string, unknown>
---@return "invalid"|"incomplete"|"complete" status sentence classification
function EasyChatCatalog:messageStatus(message)
  if type(message) ~= "table" then
    return "invalid"
  end
  local bank, number, words = message.bank, message.number, message.words
  if type(bank) ~= "number" or bank % 1 ~= 0 or bank < 0 or bank > 4 then
    return "invalid"
  end
  if type(number) ~= "number" or number % 1 ~= 0 or number < 0 or number > 19 then
    return "invalid"
  end
  if type(words) ~= "table" or not isU16(words[1]) or not isU16(words[2]) then
    return "invalid"
  end
  local template = self:template(bank, number)
  if template == nil then
    return "invalid"
  end
  for slot = 1, 2 do
    if not isKnownWord(self, words[slot]) then
      return "invalid"
    end
  end
  for slot = 1, template.wordCount do
    if words[slot] == EasyChatCatalog.NULL_WORD then
      return "incomplete"
    end
  end
  return "complete"
end

---@param tokens table<integer, table<string, unknown>>
---@return table<integer, table<string, unknown>> fragment tokens without the terminal marker
local function stripTerminal(tokens)
  local out = {}
  for _, token in ipairs(tokens) do
    if token.kind == "eos" then
      break
    end
    out[#out + 1] = token
  end
  return out
end

-- Expands one sentence to its display fragment stream through the same
-- template and word resolver, ignoring selection locks. Buffering stops
-- at the first null field; embedded word terminators never concatenate.
---@param message table<string, unknown>
---@return table<integer, table<string, unknown>> detached fragment tokens
function EasyChatCatalog:expandMessage(message)
  assert(type(message) == "table", "sentence expansion requires its message")
  local template = self:template(message.bank, message.number)
  if template == nil then
    error("unknown sentence template bank " .. tostring(message.bank) .. " number " .. tostring(message.number), 0)
  end
  local words = assert(message.words, "sentence expansion requires its words")
  local out = {}
  local slot = 1
  for _, token in ipairs(template.tokens) do
    if token.kind == "substitution" then
      local wordId = words[slot]
      if wordId == nil or wordId == EasyChatCatalog.NULL_WORD then
        break
      end
      for _, fragment in ipairs(stripTerminal(self:wordTokens(wordId))) do
        out[#out + 1] = fragment
      end
      slot = slot + 1
    else
      if token.kind ~= "eos" then
        out[#out + 1] = token
      end
    end
  end
  return out
end

---@param eligibility table<string, unknown>
---@param availability table<string, unknown>
---@return boolean eligible
local function isEligible(eligibility, availability)
  local kind = eligibility.kind
  if kind == "always" then
    return true
  end
  if kind == "gameClear" then
    return availability.gameCleared == true
  end
  if kind == "seen" then
    local seen = availability.seen
    return type(seen) == "table" and seen[eligibility.speciesKey] == true
  end
  if kind == "greeting" then
    local greetings = availability.greetings or 0
    return (math.floor(greetings / (2 ^ eligibility.bit)) % 2) == 1
  end
  if kind == "trendy" then
    local trendy = availability.trendy or 0
    return (math.floor(trendy / (2 ^ (eligibility.bit % 32))) % 2) == 1
  end
  return false
end

---@param availability unknown
local function checkAvailability(availability)
  assert(type(availability) == "table", "menu snapshots require their availability")
  assert(
    availability.gameCleared == true or availability.gameCleared == false,
    "menu snapshots carry the game-clear fact"
  )
  assert(type(availability.seen) == "table", "menu snapshots carry the seen species set")
  assert(
    type(availability.greetings) == "number"
      and availability.greetings % 1 == 0
      and availability.greetings >= 0
      and availability.greetings <= 63,
    "menu snapshots carry the bounded greeting bits"
  )
  assert(
    type(availability.trendy) == "number"
      and availability.trendy % 1 == 0
      and availability.trendy >= 0
      and availability.trendy <= 0xFFFFFFFF,
    "menu snapshots carry the bounded trendy bits"
  )
end

-- Builds one detached per-open menu snapshot: the twelve curated
-- category lists filtered by the snapshot's availability, then the
-- twenty-seven authored initial lists filtered by the known-word set
-- the categories establish. Source order and curated duplicates are
-- preserved; empty groups keep their positions.
-- The detached universe of species keys behind seen-gated words: the
-- per-open availability snapshot probes exactly these through the live
-- Dex owner, so composition never needs the mon catalog at open.
---@return string[] detached species keys in ascending word order
function EasyChatCatalog:seenSpeciesKeys()
  local keys = {}
  local words = self._data ~= nil and self._data.words or nil
  local ordered = {}
  if type(words) == "table" then
    for _, record in ipairs(words) do
      ordered[#ordered + 1] = record
    end
  else
    for _, record in pairs(self._words) do
      ordered[#ordered + 1] = record
    end
    table.sort(ordered, function(a, b)
      return a.id < b.id
    end)
  end
  for _, record in ipairs(ordered) do
    local eligibility = record.eligibility
    if type(eligibility) == "table" and eligibility.kind == "seen" then
      keys[#keys + 1] = eligibility.speciesKey
    end
  end
  return keys
end

---@param availability { gameCleared: boolean, seen: table<string, boolean>, greetings: integer, trendy: integer }
---@return { groups: table<integer, table<string, unknown>>, initials: table<integer, table<string, unknown>>, grid: table<integer, table<string, unknown>> }
function EasyChatCatalog:buildMenu(availability)
  checkAvailability(availability)
  local known = {}
  local groups = {}
  for index, group in ipairs(self._groups) do
    local wordIds = {}
    for _, wordId in ipairs(group.wordIds) do
      local record = self._words[wordId % 4096]
      -- The known-word set follows the offered set exactly: each retail
      -- builder marks only the words it offers, so ABC lists never see
      -- a word the categories withhold.
      if record ~= nil and isEligible(record.eligibility, availability) then
        known[wordId] = true
        wordIds[#wordIds + 1] = wordId
      end
    end
    groups[index] = { key = group.key, labelTokens = group.labelTokens, wordIds = wordIds }
  end
  local initials = {}
  for index, initial in ipairs(self._initials) do
    local offered = {}
    for _, candidate in ipairs(initial.candidates) do
      if type(candidate) == "table" then
        for _, alternative in ipairs(candidate) do
          if known[alternative] == true then
            offered[#offered + 1] = alternative
            break
          end
        end
      elseif known[candidate] == true then
        offered[#offered + 1] = candidate
      end
    end
    initials[index] = { key = initial.key, labelTokens = initial.labelTokens, candidates = offered }
  end
  local grid = {}
  for index, cell in ipairs(self._gridCells) do
    grid[index] = {
      char = cell.char,
      x = cell.x,
      y = cell.y,
      up = cell.up,
      down = cell.down,
      left = cell.left,
      right = cell.right,
      belowBack = cell.belowBack,
      aboveBack = cell.aboveBack,
    }
  end
  return { groups = groups, initials = initials, grid = grid }
end

return EasyChatCatalog
