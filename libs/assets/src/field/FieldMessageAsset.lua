-- Compact indexed field-message bank (G4MS): the generated representation of
-- one normalized, tokenized field message bank. A bank is a fixed header, an
-- offset index into one u16 word stream, a sorted glyph dictionary that stores
-- each display string once, and the concatenated message records themselves.
-- Every normalized token is stored exactly once and indexed by its message, so
-- a runtime request decodes only the selected message. All integers are
-- explicit unsigned little-endian fields. Pure module: a rooted BinaryView owns
-- the bytes, no love dependency, and no source/ROM interpretation.

local ffi = require("ffi")
local BinaryView = require("libs.codec.src.BinaryView")
local Contract = require("libs.assets.src.DerivedAssetContract")
local Errors = require("libs.errors.src.Errors")
local FieldMessageText = require("libs.assets.src.field.FieldMessageText")

local FieldMessageAsset = {}

local MAGIC = "G4MS"
local HEADER_BYTES = 40
local INDEX_ENTRY_BYTES = 4
local GLYPH_ENTRY_BYTES = 8
local MAX_U16 = 0xFFFF
local MAX_U32 = 0xFFFFFFFF
local MAX_GLYPH_COUNT = 0x10000

-- Ordinary stream words below the escape value are glyph codes. The escape
-- value introduces a tagged record; the tag is what gives the following words
-- their meaning, so a tag code is never confused with a glyph code.
local ESCAPE = 0xFFFF
local ESCAPE_GLYPH_LAST = 0
local ESCAPE_EOS = 1
local ESCAPE_LINE_BREAK = 2
local ESCAPE_PROMPT_BREAK = 3
local ESCAPE_PAGE_BREAK = 4
local ESCAPE_CONTROL = 5
local ESCAPE_TRNAME = 6
local ESCAPE_OPAQUE_CONTROL = 7

FieldMessageAsset.MESSAGE_ASSET_INVALID = "MESSAGE_ASSET_INVALID"
FieldMessageAsset.MESSAGE_ID_OUT_OF_RANGE = "MESSAGE_ID_OUT_OF_RANGE"
FieldMessageAsset.MAGIC = MAGIC
FieldMessageAsset.HEADER_BYTES = HEADER_BYTES
FieldMessageAsset.BINARY_VERSION = Contract.messages.binaryVersion
FieldMessageAsset.SCHEMA = Contract.messages.schema

---@class FieldMessageAsset.Bank
---@field bankId integer
---@field messageCount integer
---@field messages table<integer, { tokens: FieldMessageText.Token[] }>

-- One selected message: plain Lua values with no reference to the bank view.
---@class FieldMessageAsset.Message
---@field bankId integer
---@field messageId integer
---@field text string
---@field tokens FieldMessageText.Token[]

---@class FieldMessageAsset.View
---@field bankId integer
---@field messageCount integer
---@field schema string
---@field _bytes BinaryView
---@field _messageIndexOffset integer
---@field _glyphCount integer
---@field _glyphTableOffset integer
---@field _glyphTextOffset integer
---@field _streamOffset integer
---@field _totalBytes integer
---@field _wordCount integer

---@class FieldMessageAsset.Plan
---@field bankId integer
---@field messageCount integer
---@field glyphCount integer
---@field codes integer[]
---@field texts table<integer, string>
---@field words integer[]
---@field glyphTableOffset integer
---@field glyphTextOffset integer
---@field streamOffset integer
---@field totalBytes integer

local View = {}
View.__index = View

-- Raising is invisible to the type checker, so the declared return keeps
-- rejection paths usable in return position.
---@param message string
---@param context Errors.Context?
---@return unknown
local function invalid(message, context)
  return Errors.raise(FieldMessageAsset.MESSAGE_ASSET_INVALID, message, context)
end

local function isFiniteInteger(value)
  return type(value) == "number"
    and value == value
    and value ~= math.huge
    and value ~= -math.huge
    and value == math.floor(value)
end

local function unsigned(value, max, name, context)
  if not isFiniteInteger(value) or value < 0 or value > max then
    invalid(name .. " must be an integer in 0.." .. max .. ", got " .. tostring(value), context)
  end
  return value
end

-- The persisted framing of the value-carrying records and the canonical raw
-- word each one stands for in the normalized token stream.
local BREAK_TAGS = {
  eos = ESCAPE_EOS,
  line_break = ESCAPE_LINE_BREAK,
  prompt_break = ESCAPE_PROMPT_BREAK,
  page_break = ESCAPE_PAGE_BREAK,
}
local BREAK_RAW = {
  eos = FieldMessageText.EOS,
  line_break = FieldMessageText.CHAR_LF,
  prompt_break = FieldMessageText.PROMPT_BREAK,
  page_break = FieldMessageText.PAGE_BREAK,
}

local function sameWords(actual, expected)
  if type(actual) ~= "table" or #actual ~= #expected then
    return false
  end
  for index = 1, #expected do
    if actual[index] ~= expected[index] then
      return false
    end
  end
  return true
end

local function writeU16LE(ptr, offset, value)
  ptr[offset] = value % 256
  ptr[offset + 1] = math.floor(value / 256)
end

local function writeU32LE(ptr, offset, value)
  ptr[offset] = value % 256
  ptr[offset + 1] = math.floor(value / 256) % 256
  ptr[offset + 2] = math.floor(value / 65536) % 256
  ptr[offset + 3] = math.floor(value / 16777216)
end

-- Emits the words of one normalized token through `emit`. The same function
-- both sizes and writes a bank, so the persisted length and the persisted
-- stream can never disagree.
---@param token FieldMessageText.Token
---@param store { bankId: integer, messageId: integer, tokenIndex: integer, glyphs: table<integer, string> }
---@param emit fun(word: integer)
local function encodeToken(token, store, emit)
  local context = {
    bankId = store.bankId,
    messageId = store.messageId,
    tokenIndex = store.tokenIndex - 1,
  }
  ---@cast context Errors.Context
  if type(token) ~= "table" then
    invalid("each message token must be a table", context)
  end
  local kind = token.kind
  local function reject(message)
    invalid(message, context)
  end

  if kind == "glyph" then
    local code = unsigned(token.code, MAX_U16, "glyph code", context)
    local text = token.text
    if type(text) ~= "string" or #text == 0 then
      reject("a glyph token requires non-empty display text")
    end
    if #text > MAX_U16 then
      reject("glyph display text exceeds " .. MAX_U16 .. " bytes")
    end
    local known = store.glyphs[code]
    if known == nil then
      store.glyphs[code] = text
    elseif known ~= text then
      reject(string.format("glyph code 0x%04X carries two display strings", code))
    end
    if token.raw ~= nil and not sameWords(token.raw, { code }) then
      reject("a glyph token's raw array must be its own code")
    end
    if code == ESCAPE then
      emit(ESCAPE)
      emit(ESCAPE_GLYPH_LAST)
    else
      emit(code)
    end
    return
  end

  local tag = BREAK_TAGS[kind]
  if tag ~= nil then
    if token.raw ~= nil and not sameWords(token.raw, { BREAK_RAW[kind] }) then
      reject("a " .. kind .. " token's raw array must be its canonical code word")
    end
    emit(ESCAPE)
    emit(tag)
    return
  end

  if type(token.control) == "number" and token.control == FieldMessageText.TRNAME then
    if kind ~= "substitution" then
      reject("the trainer-name substitution code requires the substitution kind")
    end
    local raw = token.raw
    if type(raw) ~= "table" or #raw == 0 then
      reject("a trainer-name token requires its raw words")
    end
    ---@cast raw integer[]
    if raw[1] ~= FieldMessageText.TRNAME then
      reject("a trainer-name token's raw array must begin with its code")
    end
    if token.args ~= nil and #token.args ~= 0 then
      reject("a trainer-name token carries no arguments")
    end
    if token.name ~= nil and token.name ~= "TRNAME" then
      reject("a trainer-name token's name must be TRNAME")
    end
    emit(ESCAPE)
    emit(ESCAPE_TRNAME)
    emit(#raw)
    for _, word in ipairs(raw) do
      emit(unsigned(word, MAX_U16, "trainer-name raw word", context))
    end
    return
  end

  local control = unsigned(token.control, MAX_U16, "control code", context)
  local args = token.args or {}
  if type(args) ~= "table" then
    reject("control arguments must be a table")
  end
  local raw = token.raw
  if type(raw) == "table" and #raw == 1 then
    -- One opaque word: a control the source tokenizer could not frame as an
    -- extended control. Its code is never reinterpreted as a known control.
    if raw[1] ~= control or kind ~= "unsupported_control" or #args ~= 0 or token.name ~= nil then
      reject("an opaque control carries one raw word, no arguments, and no name")
    end
    emit(ESCAPE)
    emit(ESCAPE_OPAQUE_CONTROL)
    emit(control)
    return
  end
  if kind ~= FieldMessageText.controlKind(control) then
    reject("control " .. string.format("0x%04X", control) .. " must carry its canonical kind")
  end
  local name = FieldMessageText.controlName(control)
  if token.name ~= nil and token.name ~= name then
    reject("control " .. string.format("0x%04X", control) .. " must carry its canonical name")
  end
  local canonical = { FieldMessageText.EXT_CTRL_CODE_BEGIN, control, #args }
  for _, argument in ipairs(args) do
    canonical[#canonical + 1] = unsigned(argument, MAX_U16, "control argument", context)
  end
  if raw ~= nil and not sameWords(raw, canonical) then
    reject("an extended control's raw array must be its canonical framing")
  end
  emit(ESCAPE)
  emit(ESCAPE_CONTROL)
  emit(control)
  emit(#args)
  for position = 4, #canonical do
    emit(canonical[position])
  end
end

-- The private layout for one encodable bank: the sorted glyph dictionary, the
-- word count of every message, and the resulting section offsets.
---@param bank FieldMessageAsset.Bank
---@return FieldMessageAsset.Plan
local function plan(bank)
  if type(bank) ~= "table" then
    invalid("a compact message bank must be a table")
  end
  local bankId = unsigned(bank.bankId, MAX_U32, "bankId")
  local messageCount = unsigned(bank.messageCount, MAX_U32, "messageCount")
  if type(bank.messages) ~= "table" then
    invalid("bank " .. bankId .. " carries no message table", { bankId = bankId })
  end

  local glyphs = {}
  local words = {}
  local present = 0
  local totalWords = 0
  for messageId, message in pairs(bank.messages) do
    if not isFiniteInteger(messageId) or messageId < 0 or messageId > messageCount - 1 then
      invalid("bank " .. bankId .. " carries message id " .. tostring(messageId) .. " outside its message count", {
        bankId = bankId,
        messageId = messageId,
        messageCount = messageCount,
      })
    end
    if type(message) ~= "table" or type(message.tokens) ~= "table" then
      invalid("message " .. tostring(messageId) .. " carries no token stream", {
        bankId = bankId,
        messageId = messageId,
      })
    end
    local tokens = message.tokens
    local dense = 0
    for key in pairs(tokens) do
      if not isFiniteInteger(key) or key < 1 or key > #tokens then
        invalid("message " .. tostring(messageId) .. " token stream is not a dense sequence", {
          bankId = bankId,
          messageId = messageId,
        })
      end
      dense = dense + 1
    end
    if dense ~= #tokens then
      invalid("message " .. tostring(messageId) .. " token stream is not a dense sequence", {
        bankId = bankId,
        messageId = messageId,
      })
    end
    local store = { bankId = bankId, messageId = messageId, tokenIndex = 0, glyphs = glyphs }
    local count = 0
    for index, token in ipairs(tokens) do
      store.tokenIndex = index
      encodeToken(token, store, function()
        count = count + 1
      end)
    end
    words[messageId + 1] = count
    totalWords = totalWords + count
    present = present + 1
  end
  if present ~= messageCount then
    invalid(
      "bank " .. bankId .. " declares " .. messageCount .. " messages but carries " .. present,
      { bankId = bankId, messageCount = messageCount, present = present }
    )
  end

  local codes = {}
  for code in pairs(glyphs) do
    codes[#codes + 1] = code
  end
  table.sort(codes)
  local glyphCount = #codes
  if glyphCount > MAX_GLYPH_COUNT then
    invalid("bank " .. bankId .. " exceeds " .. MAX_GLYPH_COUNT .. " distinct glyphs", { bankId = bankId })
  end
  local textBytes = 0
  for _, code in ipairs(codes) do
    textBytes = textBytes + #glyphs[code]
  end

  local glyphTableOffset = HEADER_BYTES + INDEX_ENTRY_BYTES * (messageCount + 1)
  local glyphTextOffset = glyphTableOffset + GLYPH_ENTRY_BYTES * glyphCount
  local streamOffset = glyphTextOffset + textBytes
  if streamOffset % 2 == 1 then
    streamOffset = streamOffset + 1
  end
  local totalBytes = streamOffset + 2 * totalWords
  if totalBytes > MAX_U32 then
    invalid("bank " .. bankId .. " exceeds the 32-bit compact payload size", { bankId = bankId })
  end
  if glyphTableOffset > MAX_U32 or glyphTextOffset > MAX_U32 then
    invalid("bank " .. bankId .. " exceeds the 32-bit section offsets", { bankId = bankId })
  end

  return {
    bankId = bankId,
    messageCount = messageCount,
    glyphCount = glyphCount,
    codes = codes,
    texts = glyphs,
    words = words,
    glyphTableOffset = glyphTableOffset,
    glyphTextOffset = glyphTextOffset,
    streamOffset = streamOffset,
    totalBytes = totalBytes,
  }
end

-- The exact persisted size of one normalized bank.
---@param bank FieldMessageAsset.Bank
---@return integer
function FieldMessageAsset.encodedSize(bank)
  return plan(bank).totalBytes
end

---@param bank FieldMessageAsset.Bank
---@param outPtr ffi.cdata*
---@param outLength integer
---@return integer
function FieldMessageAsset.encodeInto(bank, outPtr, outLength)
  local layout = plan(bank)
  assert(outPtr ~= nil, "compact message encoding requires an output pointer")
  assert(
    isFiniteInteger(outLength) and outLength == layout.totalBytes,
    "compact message encoding requires exactly " .. layout.totalBytes .. " output bytes"
  )
  local out = ffi.cast("uint8_t *", outPtr)

  out[0], out[1], out[2], out[3] = string.byte(MAGIC, 1, 4)
  writeU16LE(out, 4, FieldMessageAsset.BINARY_VERSION)
  writeU16LE(out, 6, HEADER_BYTES)
  writeU32LE(out, 8, layout.bankId)
  writeU32LE(out, 12, layout.messageCount)
  writeU32LE(out, 16, layout.glyphCount)
  writeU32LE(out, 20, HEADER_BYTES)
  writeU32LE(out, 24, layout.glyphTableOffset)
  writeU32LE(out, 28, layout.glyphTextOffset)
  writeU32LE(out, 32, layout.streamOffset)
  writeU32LE(out, 36, layout.totalBytes)

  local wordOffset = 0
  for messageId = 0, layout.messageCount - 1 do
    writeU32LE(out, HEADER_BYTES + INDEX_ENTRY_BYTES * messageId, wordOffset)
    wordOffset = wordOffset + layout.words[messageId + 1]
  end
  writeU32LE(out, HEADER_BYTES + INDEX_ENTRY_BYTES * layout.messageCount, wordOffset)

  local textOffset = 0
  for position, code in ipairs(layout.codes) do
    local text = layout.texts[code]
    local entry = layout.glyphTableOffset + GLYPH_ENTRY_BYTES * (position - 1)
    writeU16LE(out, entry, code)
    writeU16LE(out, entry + 2, #text)
    writeU32LE(out, entry + 4, textOffset)
    ffi.copy(out + layout.glyphTextOffset + textOffset, text, #text)
    textOffset = textOffset + #text
  end

  local position = layout.streamOffset
  for messageId = 0, layout.messageCount - 1 do
    local message = assert(bank.messages[messageId], "message " .. messageId .. " is missing")
    local store = { bankId = layout.bankId, messageId = messageId, tokenIndex = 0, glyphs = {} }
    for index, token in ipairs(message.tokens) do
      store.tokenIndex = index
      encodeToken(token, store, function(word)
        writeU16LE(out, position, word)
        position = position + 2
      end)
    end
  end
  assert(position == layout.totalBytes, "compact message encoding wrote " .. position .. " bytes")
  return position
end

---@param data string|BinaryDataLike|BinaryView
---@return BinaryView
local function toBinaryView(data)
  if type(data) == "string" then
    return BinaryView.fromString(data, "message bank")
  end
  if type(data) == "table" and type(data.u16le) == "function" and type(data.slice) == "function" then
    return data --[[@as BinaryView]]
  end
  if type(data) == "table" or type(data) == "userdata" then
    if type(data.getFFIPointer) == "function" and type(data.getSize) == "function" then
      return BinaryView.fromData(data --[[@as BinaryDataLike]], "message bank")
    end
  end
  return invalid("a compact message bank must be bytes, a Data object, or a binary view")
end

-- Converts a persisted-layout read failure into the codec's own identity,
-- keeping the byte position the view reported.
---@param fn fun(): unknown
---@return unknown
local function guarded(fn)
  local ok, result = pcall(fn)
  if ok then
    return result
  end
  if Errors.is(result) then
    local err = result --[[@as Errors.Error]]
    if err.code == "READ_OUT_OF_BOUNDS" then
      local context = {
        offset = err.context.offset,
        length = err.context.length,
        field = err.context.field,
      }
      ---@cast context Errors.Context
      invalid("compact message bank read exceeds its payload", context)
    end
  end
  error(result, 0)
end

-- Opens one compact bank without enumerating its messages. The returned view
-- roots the exact backing bytes that produced it.
---@param data string|BinaryDataLike|BinaryView
---@param expectedBankId integer
---@return FieldMessageAsset.View
function FieldMessageAsset.open(data, expectedBankId)
  if not isFiniteInteger(expectedBankId) or expectedBankId < 0 or expectedBankId > MAX_U32 then
    invalid("a compact bank open requires the expected bank id, got " .. tostring(expectedBankId))
  end
  return guarded(function()
    local bytes = toBinaryView(data)
    if bytes:length() < HEADER_BYTES then
      invalid("a compact message bank is shorter than its header", { available = bytes:length() })
    end
    if bytes:toString(0, 4) ~= MAGIC then
      invalid("a compact message bank does not start with " .. MAGIC)
    end
    local formatVersion = bytes:u16le(4)
    if formatVersion ~= FieldMessageAsset.BINARY_VERSION then
      invalid("compact message bank format version " .. formatVersion .. " is not current", {
        formatVersion = formatVersion,
        expected = FieldMessageAsset.BINARY_VERSION,
      })
    end
    local headerBytes = bytes:u16le(6)
    if headerBytes ~= HEADER_BYTES then
      invalid("compact message bank header is " .. headerBytes .. " bytes", { headerBytes = headerBytes })
    end
    local bankId = bytes:u32le(8)
    if bankId ~= expectedBankId then
      invalid("compact message bank carries bank " .. bankId, { bankId = bankId, expected = expectedBankId })
    end
    local messageCount = bytes:u32le(12)
    local glyphCount = bytes:u32le(16)
    if glyphCount > MAX_GLYPH_COUNT then
      invalid("compact message bank declares " .. glyphCount .. " glyphs", { glyphCount = glyphCount })
    end
    local messageIndexOffset = bytes:u32le(20)
    local glyphTableOffset = bytes:u32le(24)
    local glyphTextOffset = bytes:u32le(28)
    local streamOffset = bytes:u32le(32)
    local totalBytes = bytes:u32le(36)
    local context = { bankId = bankId }
    if messageIndexOffset ~= HEADER_BYTES then
      invalid("compact message bank index does not follow its header", context)
    end
    if glyphTableOffset ~= HEADER_BYTES + INDEX_ENTRY_BYTES * (messageCount + 1) then
      invalid("compact message bank glyph table is not where its message count puts it", context)
    end
    if glyphTextOffset ~= glyphTableOffset + GLYPH_ENTRY_BYTES * glyphCount then
      invalid("compact message bank glyph text is not where its glyph count puts it", context)
    end
    if streamOffset < glyphTextOffset or streamOffset % 2 ~= 0 then
      invalid("compact message bank stream does not start at an even offset after its dictionary", context)
    end
    if streamOffset > totalBytes or (totalBytes - streamOffset) % 2 ~= 0 then
      invalid("compact message bank stream is not a whole number of words", context)
    end
    if totalBytes ~= bytes:length() then
      invalid("compact message bank declares " .. totalBytes .. " bytes", {
        bankId = bankId,
        totalBytes = totalBytes,
        available = bytes:length(),
      })
    end
    return setmetatable({
      bankId = bankId,
      messageCount = messageCount,
      schema = FieldMessageAsset.SCHEMA,
      _messageIndexOffset = messageIndexOffset,
      _bytes = bytes,
      _glyphCount = glyphCount,
      _glyphTableOffset = glyphTableOffset,
      _glyphTextOffset = glyphTextOffset,
      _streamOffset = streamOffset,
      _totalBytes = totalBytes,
      _wordCount = (totalBytes - streamOffset) / 2,
    }, View)
  end) --[[@as FieldMessageAsset.View]]
end

-- Resolves one glyph code through the sorted dictionary, memoizing repeated
-- display strings only for the current call.
---@param view FieldMessageAsset.View
---@param code integer
---@param memo table<integer, string>
---@param context Errors.Context
---@return string
local function glyphText(view, code, memo, context)
  local cached = memo[code]
  if cached ~= nil then
    return cached
  end
  local bytes = view._bytes
  local low, high = 0, view._glyphCount - 1
  while low <= high do
    local middle = math.floor((low + high) / 2)
    local entry = view._glyphTableOffset + GLYPH_ENTRY_BYTES * middle
    local entryCode = bytes:u16le(entry)
    if entryCode == code then
      local length = bytes:u16le(entry + 2)
      local textStart = view._glyphTextOffset + bytes:u32le(entry + 4)
      if length == 0 or textStart < view._glyphTextOffset or textStart + length > view._streamOffset then
        invalid(string.format("glyph 0x%04X display text exceeds the compact dictionary", code), context)
      end
      local text = bytes:toString(textStart, length)
      memo[code] = text
      return text
    end
    if entryCode < code then
      low = middle + 1
    else
      high = middle - 1
    end
  end
  return invalid(string.format("glyph 0x%04X has no compact dictionary entry", code), context)
end

-- Walks one message's bounded word span and hands every decoded token to
-- `sink`. The same walker serves selected reads, the explicit audit, and the
-- human-readable export, so the framing has exactly one interpretation.
---@param view FieldMessageAsset.View
---@param messageId integer
---@param sink fun(token: FieldMessageText.Token)
local function walkMessage(view, messageId, sink)
  local bytes = view._bytes
  local context = { bankId = view.bankId, messageId = messageId }
  ---@cast context Errors.Context
  local indexOffset = view._messageIndexOffset + INDEX_ENTRY_BYTES * messageId
  local startWord = bytes:u32le(indexOffset)
  local endWord = bytes:u32le(indexOffset + INDEX_ENTRY_BYTES)
  if startWord > endWord or endWord > view._wordCount then
    invalid("message " .. messageId .. " does not address a bounded part of the word stream", context)
  end
  local startByte = view._streamOffset + startWord * 2
  local endByte = view._streamOffset + endWord * 2

  local function readWord(position, what)
    if position + 2 > endByte then
      invalid("message " .. messageId .. " ends inside " .. what, context)
    end
    return bytes:u16le(position), position + 2
  end

  local memo = {}
  local offset = startByte
  while offset < endByte do
    local code
    code, offset = readWord(offset, "a message record")
    local token
    if code ~= ESCAPE then
      token = {
        kind = "glyph",
        code = code,
        text = glyphText(view, code, memo, context),
        raw = { code },
      }
    else
      local tag
      tag, offset = readWord(offset, "a message escape")
      if tag == ESCAPE_GLYPH_LAST then
        token = {
          kind = "glyph",
          code = ESCAPE,
          text = glyphText(view, ESCAPE, memo, context),
          raw = { ESCAPE },
        }
      elseif tag == ESCAPE_EOS then
        token = { kind = "eos", raw = { FieldMessageText.EOS } }
      elseif tag == ESCAPE_LINE_BREAK then
        token = { kind = "line_break", raw = { FieldMessageText.CHAR_LF } }
      elseif tag == ESCAPE_PROMPT_BREAK then
        token = { kind = "prompt_break", raw = { FieldMessageText.PROMPT_BREAK } }
      elseif tag == ESCAPE_PAGE_BREAK then
        token = { kind = "page_break", raw = { FieldMessageText.PAGE_BREAK } }
      elseif tag == ESCAPE_CONTROL then
        local control, argumentCount
        control, offset = readWord(offset, "an extended control")
        argumentCount, offset = readWord(offset, "an extended control's argument count")
        local args, raw = {}, { FieldMessageText.EXT_CTRL_CODE_BEGIN, control, argumentCount }
        for position = 1, argumentCount do
          local argument
          argument, offset = readWord(offset, "an extended control argument")
          args[position] = argument
          raw[position + 3] = argument
        end
        token = {
          kind = FieldMessageText.controlKind(control),
          control = control,
          name = FieldMessageText.controlName(control),
          args = args,
          raw = raw,
        }
      elseif tag == ESCAPE_TRNAME then
        local rawCount
        rawCount, offset = readWord(offset, "a trainer-name record")
        if rawCount == 0 then
          invalid("message " .. messageId .. " carries an empty trainer-name record", context)
        end
        local raw = {}
        for position = 1, rawCount do
          local word
          word, offset = readWord(offset, "a trainer-name word")
          raw[position] = word
        end
        if raw[1] ~= FieldMessageText.TRNAME then
          invalid("message " .. messageId .. " carries a trainer-name record without its code", context)
        end
        token = {
          kind = "substitution",
          control = FieldMessageText.TRNAME,
          name = "TRNAME",
          args = {},
          raw = raw,
        }
      elseif tag == ESCAPE_OPAQUE_CONTROL then
        local control
        control, offset = readWord(offset, "an opaque control")
        token = { kind = "unsupported_control", control = control, args = {}, raw = { control } }
      else
        invalid("message " .. messageId .. " carries unknown escape tag " .. tag, context)
      end
    end
    sink(token)
  end
end

-- Expands exactly one indexed message. The returned template owns its text and
-- tokens and never references the bank view, so it outlives any release.
---@param view FieldMessageAsset.View
---@param messageId integer
---@return FieldMessageAsset.Message
function FieldMessageAsset.message(view, messageId)
  if not isFiniteInteger(messageId) or messageId < 0 or messageId >= view.messageCount then
    Errors.raise(
      FieldMessageAsset.MESSAGE_ID_OUT_OF_RANGE,
      "message " .. tostring(messageId) .. " is outside bank " .. tostring(view.bankId) .. "'s messages",
      { bankId = view.bankId, messageId = messageId, messageCount = view.messageCount }
    )
  end
  return guarded(function()
    local tokens = {}
    walkMessage(view, messageId, function(token)
      tokens[#tokens + 1] = token
    end)
    return {
      bankId = view.bankId,
      messageId = messageId,
      text = FieldMessageText.tokensToText(tokens),
      tokens = tokens,
    }
  end)
end

-- The explicit audit: bounded open plus the full index, dictionary, and
-- message-stream layout. Tooling and tests only; gameplay reads one message.
---@param data string|BinaryDataLike|BinaryView
---@param expectedBankId integer
---@return true
function FieldMessageAsset.validate(data, expectedBankId)
  return guarded(function()
    local view = FieldMessageAsset.open(data, expectedBankId)
    local bytes = view._bytes
    local previousWord = 0
    for messageId = 0, view.messageCount do
      local wordOffset = bytes:u32le(view._messageIndexOffset + INDEX_ENTRY_BYTES * messageId)
      if messageId == 0 and wordOffset ~= 0 then
        invalid("compact message bank index does not begin at its stream start", { bankId = view.bankId })
      end
      if wordOffset < previousWord then
        invalid("compact message bank index decreases at message " .. messageId, {
          bankId = view.bankId,
          messageId = messageId,
        })
      end
      previousWord = wordOffset
    end
    if previousWord ~= view._wordCount then
      invalid("compact message bank index does not cover its word stream", {
        bankId = view.bankId,
        wordCount = view._wordCount,
        indexEnd = previousWord,
      })
    end

    local expectedTextOffset = 0
    local previousCode = -1
    for position = 0, view._glyphCount - 1 do
      local entry = view._glyphTableOffset + GLYPH_ENTRY_BYTES * position
      local code = bytes:u16le(entry)
      local length = bytes:u16le(entry + 2)
      local textOffset = bytes:u32le(entry + 4)
      if code <= previousCode then
        invalid("compact glyph dictionary is not strictly ascending at code " .. code, { bankId = view.bankId })
      end
      if length == 0 then
        invalid(string.format("compact glyph dictionary stores no text for code 0x%04X", code), {
          bankId = view.bankId,
        })
      end
      if textOffset ~= expectedTextOffset then
        invalid(string.format("compact glyph dictionary text for code 0x%04X is not packed", code), {
          bankId = view.bankId,
        })
      end
      previousCode = code
      expectedTextOffset = textOffset + length
    end
    local textBytes = view._streamOffset - view._glyphTextOffset
    if expectedTextOffset ~= textBytes and expectedTextOffset + 1 ~= textBytes then
      invalid("compact glyph dictionary text does not fill its section", { bankId = view.bankId })
    end
    if expectedTextOffset + 1 == textBytes and bytes:u8(view._glyphTextOffset + textBytes - 1) ~= 0 then
      invalid("compact glyph dictionary padding is not a zero byte", { bankId = view.bankId })
    end

    for messageId = 0, view.messageCount - 1 do
      walkMessage(view, messageId, function() end)
    end
    return true
  end) --[[@as true]]
end

return FieldMessageAsset
