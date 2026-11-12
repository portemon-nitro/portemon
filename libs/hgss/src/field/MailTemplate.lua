-- The single semantic Mail <-> Easy Chat adapter. Persisted lines carry
-- template keys of the exact shape "mail-template:B:N" (logical bank
-- 0..4, message 0..19) with exactly two word fields holding false or
-- canonical decimal u16 strings; numeric C02 messages never escape into
-- persisted Mail. New composition is strict (at least one complete
-- initialized line, no unused-field garbage); reading saved letters is
-- tolerant (known extra or missing substitutions render without
-- rewriting the stored fields).

local Mail = require("libs.mons.src.gen4.Mail")

local MailTemplate = {}

local NULL_WORD = 65535

-- Parses one persisted semantic template key into its logical C01
-- identity, or nil when the key has the wrong shape. Identity values
-- pass through verbatim: no availability filtering, no ID shifting.
---@param key unknown
---@return number? bank
---@return number? number
local function parseTemplateKey(key)
  if type(key) ~= "string" then
    return nil, nil
  end
  local bankText, numberText = key:match("^mail%-template:(%d+):(%d+)$")
  if bankText == nil or numberText == nil then
    return nil, nil
  end
  local bank, number = tonumber(bankText), tonumber(numberText)
  assert(bank ~= nil and number ~= nil, "template identity parses its decimal parts")
  if bank % 1 ~= 0 or bank < 0 or bank > 4 then
    return nil, nil
  end
  if number % 1 ~= 0 or number < 0 or number > 19 then
    return nil, nil
  end
  return bank, number
end

-- Parses one persisted word field: false is the stored NULL, otherwise
-- a canonical decimal u16 string. High display flags are never stripped
-- from persisted input here; C02 resolution handles display itself.
---@param word unknown
---@return number? wordId
local function parseWord(word)
  if word == false then
    return NULL_WORD
  end
  if type(word) ~= "string" then
    return nil
  end
  local id = tonumber(word)
  if id == nil or id % 1 ~= 0 or id < 0 or id > 0xFFFF then
    return nil
  end
  return id
end

-- Converts one nonfalse semantic line into its detached numeric C02
-- message. Unknown template keys or invalid word identities fail; the
-- caller owns the malformed-letter verdict.
---@param line table<string, unknown> one nonfalse semantic Mail line
---@return table<string, unknown> detached numeric message { bank, number, words = { u16, u16 } }
function MailTemplate.toMessage(line)
  assert(type(line) == "table", "message conversion requires a semantic line")
  assert(type(line.template) == "string", "message conversion requires a semantic template key")
  local bank, number = parseTemplateKey(line.template)
  if bank == nil or number == nil then
    error("stored mail template has an unknown identity: " .. tostring(line.template), 0)
  end
  assert(type(line.words) == "table" and #line.words == 2, "stored mail keeps its two word fields")
  local words = {}
  for position = 1, 2 do
    local id = parseWord(line.words[position])
    if id == nil then
      error("stored mail word is invalid", 0)
    end
    words[position] = id
  end
  return { bank = bank, number = number, words = words }
end

-- Adapts one accepted C02 result back into a persisted semantic line.
-- The template key spells the accepted message identity; trailing
-- fields the template never uses normalize to false (NULL becomes
-- false), so only the edited line's unused slots are cleared.
---@param message table<string, unknown> complete accepted C02 result message
---@param catalog table<string, unknown> the shared word catalog
---@return table<string, unknown> detached semantic line
function MailTemplate.fromMessage(message, catalog)
  assert(type(message) == "table", "line adaptation requires an accepted message")
  assert(type(message.bank) == "number" and type(message.number) == "number", "line adaptation needs its identity")
  assert(type(message.words) == "table", "line adaptation needs its word fields")
  assert(catalog ~= nil and type(catalog.template) == "function", "line adaptation needs the shared catalog")
  local template = catalog:template(message.bank, message.number)
  if template == nil then
    error("accepted mail template has an unknown identity", 0)
  end
  local arity = assert(template.wordCount, "catalog templates carry their field count")
  assert(type(arity) == "number" and arity >= 0 and arity <= 2, "mail template arity fits the stored fields")
  local words = {}
  for position = 1, 2 do
    if position <= arity then
      local id = message.words[position]
      assert(
        type(id) == "number" and id % 1 == 0 and id >= 0 and id <= 0xFFFF,
        "accepted mail words are numeric identities"
      )
      words[position] = id == NULL_WORD and false or tostring(id)
    else
      words[position] = false
    end
  end
  return {
    template = "mail-template:" .. message.bank .. ":" .. message.number,
    words = words,
  }
end

---@param status string
---@return boolean
local function isComplete(status)
  return status == "complete"
end

-- Validates one composed letter for final submission: Mail shape, then
-- at least one initialized line, then required-word completeness per
-- line through the catalog, rejecting nonfalse unused trailing fields.
-- Saved extra/missing substitutions are a read-time concern and never
-- reach this strict path.
---@param letter table<string, unknown> the composed Mail record
---@param catalog table<string, unknown> the shared word catalog
---@return boolean admitted
---@return string? reason "incomplete" for a missing required word, "invalid_letter" otherwise
function MailTemplate.checkComposed(letter, catalog)
  if not pcall(Mail.validate, letter) then
    return false, "invalid_letter"
  end
  if catalog == nil or type(catalog.messageStatus) ~= "function" then
    return false, "invalid_letter"
  end
  local initialized = false
  for _, line in ipairs(letter.lines) do
    if line ~= false then
      local okMessage, message = pcall(MailTemplate.toMessage, line)
      if not okMessage then
        return false, "invalid_letter"
      end
      local status = catalog:messageStatus(message)
      if status == "invalid" then
        return false, "invalid_letter"
      end
      if not isComplete(status) then
        return false, "incomplete"
      end
      initialized = true
      -- A complete line still needs normalized trailing fields: the
      -- template's unused slots must be false, never leftover words.
      local template = catalog:template(message.bank, message.number)
      assert(template ~= nil, "a complete message resolves its template")
      for position = template.wordCount + 1, 2 do
        if line.words[position] ~= false then
          return false, "invalid_letter"
        end
      end
    end
  end
  if not initialized then
    return false, "incomplete"
  end
  return true
end

-- Expands one stored line through the shared catalog for display,
-- ignoring selection availability. Known extra or missing saved
-- substitutions render tolerantly: buffering stops at the first NULL
-- exactly like the source expander, and empty substitutions contribute
-- no words. Unknown template keys or invalid word identities fail at
-- this admission boundary.
---@param line table<string, unknown> the stored Mail line
---@param catalog table<string, unknown> the shared word catalog
---@return table[] detached expanded token list
function MailTemplate.expandLine(line, catalog)
  assert(type(line) == "table", "stored mail line is a record")
  assert(catalog ~= nil and type(catalog.expandMessage) == "function", "mail expansion needs the shared catalog")
  local message = MailTemplate.toMessage(line)
  return catalog:expandMessage(message)
end

return MailTemplate
