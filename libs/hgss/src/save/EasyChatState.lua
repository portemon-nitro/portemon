-- The authoritative saved Easy Chat state: greeting and trendy unlock
-- bits plus four Battle Tower phrases and one independent Global
-- Terminal greeting. Fresh states initialize only the ROM-language
-- greeting; missing buckets admit source defaults while malformed
-- present buckets fail without reset. Reads and captures stay detached;
-- only this owner mutates the bits and phrases. Pure domain code: no
-- LÖVE, no script, no RNG.

local Errors = require("libs.errors.src.Errors")
local GameSaveErrors = require("libs.hgss.src.save.GameSaveErrors")

---@class EasyChatState
---@field _catalog table<string, unknown> borrowed message validator
---@field _greetings integer six greeting unlock bits
---@field _trendy integer thirty-two trendy unlock bits
---@field _towerMessages table<integer, table<string, unknown>> four detached Tower phrases
---@field _terminalGreeting table<string, unknown> detached Terminal phrase
local EasyChatState = {}
EasyChatState.__index = EasyChatState

EasyChatState.SCHEMA = "hgss-easy-chat-v1"
EasyChatState.NULL_WORD = 0xFFFF

-- Source initialization (src/easy_chat.c:176-187): only the ROM-language
-- greeting bit starts set; the trendy word comes from the Route 16
-- producer, never from initialization.
local LANGUAGE_BITS = {
  japanese = 0,
  english = 1,
  french = 2,
  italian = 3,
  german = 4,
  spanish = 5,
}

local DEFAULT_TOWER = {
  { bank = 0, number = 0, words = { 1113, 0xFFFF } },
  { bank = 1, number = 0, words = { 1139, 0xFFFF } },
  { bank = 2, number = 0, words = { 1403, 0xFFFF } },
  { bank = 1, number = 4, words = { 1107, 0xFFFF } },
}

local DEFAULT_TERMINAL = { bank = 4, number = 0, words = { 1281, 0xFFFF } }

---@param message table<string, unknown>
---@return table<string, unknown> detached copy
local function copyMessage(message)
  return { bank = message.bank, number = message.number, words = { message.words[1], message.words[2] } }
end

---@param self EasyChatState
---@param message table<string, unknown>
local function checkCompleteMessage(self, message)
  if type(message) ~= "table" then
    Errors.raise(GameSaveErrors.GAME_SAVE_BUCKET_INVALID, "easy chat phrases are records", {})
  end
  local status = self._catalog:messageStatus(message)
  if status ~= "complete" then
    Errors.raise(
      GameSaveErrors.GAME_SAVE_BUCKET_INVALID,
      "easy chat phrases are complete: " .. status,
      { bank = message.bank, number = message.number }
    )
  end
end

---@param self EasyChatState
---@param message table<string, unknown>
---@return table<string, unknown> normalized detached record
local function normalizeMessage(self, message)
  local template = self._catalog:template(message.bank, message.number)
  assert(template ~= nil, "complete phrases resolve their template")
  local words = { message.words[1], message.words[2] }
  for slot = template.wordCount + 1, 2 do
    words[slot] = EasyChatState.NULL_WORD
  end
  return { bank = message.bank, number = message.number, words = words }
end

---@param language string
---@return integer greeting bits
local function initialGreetings(language)
  local bit = LANGUAGE_BITS[language]
  if bit == nil then
    return 0
  end
  return (2 ^ bit) --[[@as integer]]
end

---@param language unknown
---@param catalog unknown
local function checkConstruction(language, catalog)
  assert(type(language) == "string" and language ~= "", "saved word state requires its semantic language")
  assert(
    type(catalog) == "table" and type(catalog.messageStatus) == "function",
    "saved word state borrows its message validator"
  )
end

---@param language string semantic mon language key
---@param catalog table<string, unknown> borrowed catalog validator
---@return EasyChatState
function EasyChatState.new(language, catalog)
  checkConstruction(language, catalog)
  local tower = {}
  for slot = 1, 4 do
    tower[slot] = copyMessage(DEFAULT_TOWER[slot])
  end
  return setmetatable({
    _catalog = catalog,
    _greetings = initialGreetings(language),
    _trendy = 0,
    _towerMessages = tower,
    _terminalGreeting = copyMessage(DEFAULT_TERMINAL),
  }, EasyChatState)
end

---@param value unknown
---@param what string
---@param upper integer inclusive bound
---@return integer validated bits
local function checkBits(value, what, upper)
  if type(value) ~= "number" or value % 1 ~= 0 or value < 0 or value > upper then
    Errors.raise(GameSaveErrors.GAME_SAVE_BUCKET_INVALID, "easy chat " .. what .. " bits are out of range", {})
  end
  return value --[[@as integer]]
end

---@param message unknown
---@param catalog table<string, unknown>
---@param what string
---@return table<string, unknown> validated phrase bucket record
local function checkBucketMessage(message, catalog, what)
  if type(message) ~= "table" then
    Errors.raise(GameSaveErrors.GAME_SAVE_BUCKET_INVALID, "easy chat " .. what .. " is not a record", {})
  end
  local probe = setmetatable({ _catalog = catalog }, EasyChatState)
  checkCompleteMessage(probe, message --[[@as table]])
  -- Canonical saved records keep the second field null unless the
  -- template requires both fields; the first field always rides the
  -- stored phrase (the fresh Terminal greeting keeps its word on a
  -- slot-less template). Trailing normalization stays with the setters.
  local template = catalog:template(message.bank, message.number)
  assert(template ~= nil, "complete phrases resolve their template")
  if template.wordCount < 2 and message.words[2] ~= EasyChatState.NULL_WORD then
    Errors.raise(GameSaveErrors.GAME_SAVE_BUCKET_INVALID, "easy chat " .. what .. " carries a non-null unused word", {})
  end
  return message --[[@as table]]
end

-- Restores the owner from a persisted bucket, or initializes source
-- defaults when no bucket exists yet. A present bucket must carry the
-- current schema, bounded bit sets, exactly four dense complete Tower
-- records, and one normalized Terminal record; anything else fails
-- without mutating the owner.
---@param bucket table<string, unknown>?
---@param language string semantic mon language key
---@param catalog table<string, unknown> borrowed catalog validator
---@return EasyChatState
function EasyChatState.restore(bucket, language, catalog)
  checkConstruction(language, catalog)
  if bucket == nil then
    return EasyChatState.new(language, catalog)
  end
  if type(bucket) ~= "table" then
    Errors.raise(GameSaveErrors.GAME_SAVE_BUCKET_INVALID, "easy chat bucket is not a record", {})
  end
  if bucket.schema ~= EasyChatState.SCHEMA then
    Errors.raise(
      GameSaveErrors.GAME_SAVE_BUCKET_INVALID,
      "easy chat bucket schema is not current",
      { schema = bucket.schema }
    )
  end
  local greetings = checkBits(bucket.greetings, "greeting", 63)
  local trendy = checkBits(bucket.trendy, "trendy", 0xFFFFFFFF)
  if type(bucket.towerMessages) ~= "table" then
    Errors.raise(GameSaveErrors.GAME_SAVE_BUCKET_INVALID, "easy chat tower phrases are not a record", {})
  end
  local count = 0
  for key in pairs(bucket.towerMessages) do
    if type(key) ~= "number" or key % 1 ~= 0 or key < 1 then
      Errors.raise(GameSaveErrors.GAME_SAVE_BUCKET_INVALID, "easy chat tower phrases are not dense", {})
    end
    count = count + 1
  end
  if count ~= 4 then
    Errors.raise(
      GameSaveErrors.GAME_SAVE_BUCKET_INVALID,
      "easy chat tower phrases carry " .. count .. " records; expected 4",
      {}
    )
  end
  local tower = {}
  for slot = 1, 4 do
    if bucket.towerMessages[slot] == nil then
      Errors.raise(GameSaveErrors.GAME_SAVE_BUCKET_INVALID, "easy chat tower phrases are not dense", {})
    end
    local record = checkBucketMessage(bucket.towerMessages[slot], catalog, "towerMessages[" .. slot .. "]")
    tower[slot] = copyMessage(record)
  end
  local terminal = checkBucketMessage(bucket.terminalGreeting, catalog, "terminalGreeting")
  return setmetatable({
    _catalog = catalog,
    _greetings = greetings,
    _trendy = trendy,
    _towerMessages = tower,
    _terminalGreeting = copyMessage(terminal),
  }, EasyChatState)
end

-- Detached capture of the persisted bucket shape.
---@return table<string, unknown> bucket
function EasyChatState:capture()
  local tower = {}
  for slot = 1, 4 do
    tower[slot] = copyMessage(self._towerMessages[slot])
  end
  return {
    schema = EasyChatState.SCHEMA,
    greetings = self._greetings,
    trendy = self._trendy,
    towerMessages = tower,
    terminalGreeting = copyMessage(self._terminalGreeting),
  }
end

-- Detached read of the bounded unlock bit sets.
---@return { greetings: integer, trendy: integer }
function EasyChatState:readUnlocks()
  return { greetings = self._greetings, trendy = self._trendy }
end

-- Bounded idempotent greeting learn for one of the six source bits.
---@param bit integer 0..5
function EasyChatState:learnGreeting(bit)
  if type(bit) ~= "number" or bit % 1 ~= 0 or bit < 0 or bit > 5 then
    Errors.raise(GameSaveErrors.GAME_SAVE_BUCKET_INVALID, "greeting learns name bits 0..5", { bit = bit })
  end
  local flag = (2 ^ bit) --[[@as integer]]
  if math.floor(self._greetings / flag) % 2 == 0 then
    self._greetings = self._greetings + flag
  end
end

-- Bounded idempotent trendy learn for one of the thirty-two word bits.
---@param index integer 0..31
function EasyChatState:learnTrendy(index)
  if type(index) ~= "number" or index % 1 ~= 0 or index < 0 or index > 31 then
    Errors.raise(GameSaveErrors.GAME_SAVE_BUCKET_INVALID, "trendy learns name bits 0..31", { index = index })
  end
  local flag = (2 ^ index) --[[@as integer]]
  if math.floor(self._trendy / flag) % 2 == 0 then
    self._trendy = self._trendy + flag
  end
end

---@param slot integer 1..4
---@return table<string, unknown> detached phrase
function EasyChatState:towerMessage(slot)
  if type(slot) ~= "number" or slot % 1 ~= 0 or slot < 1 or slot > 4 then
    Errors.raise(GameSaveErrors.GAME_SAVE_BUCKET_INVALID, "tower phrases live in slots 1..4", { slot = slot })
  end
  return copyMessage(self._towerMessages[slot])
end

---@param slot integer 1..4
---@param message table<string, unknown> complete phrase
function EasyChatState:setTowerMessage(slot, message)
  if type(slot) ~= "number" or slot % 1 ~= 0 or slot < 1 or slot > 4 then
    Errors.raise(GameSaveErrors.GAME_SAVE_BUCKET_INVALID, "tower phrases live in slots 1..4", { slot = slot })
  end
  checkCompleteMessage(self, message)
  self._towerMessages[slot] = normalizeMessage(self, message)
end

---@return table<string, unknown> detached phrase
function EasyChatState:terminalGreeting()
  return copyMessage(self._terminalGreeting)
end

---@param message table<string, unknown> complete phrase
function EasyChatState:setTerminalGreeting(message)
  checkCompleteMessage(self, message)
  self._terminalGreeting = normalizeMessage(self, message)
end

return EasyChatState
