-- Compact field-message bank codec: normalized-token roundtrip through the
-- production encoder, selected-message decoding inside an indexed bank, and
-- rejection of a malformed sibling stream. Synthetic tokens only.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local FieldMessageAsset = require("libs.assets.src.field.FieldMessageAsset")
local FieldMessageFixture = require("tests.support.FieldMessageFixture")
local FieldMessageText = require("libs.assets.src.field.FieldMessageText")

local T = {}

local BANK_ID = 543

-- One display string shared by two glyph positions, a two-byte UTF-8 display
-- string, every break kind, known and unknown extended controls with different
-- argument counts, an opaque single-word control, a packed trainer name, an
-- empty message, and tokens that follow EOS.
local function fixtureMessages()
  local fixture = FieldMessageFixture
  return {
    -- 0: repeated multi-character glyph, UTF-8 glyph, line break, repeated glyph
    {
      fixture.glyph(0x0141, "th"),
      fixture.glyph(0x01DE, "é"),
      fixture.glyph(0x0150, "ll"),
      fixture.lineBreak(),
      fixture.glyph(0x0141, "th"),
      fixture.eos(),
    },
    -- 1: every break kind
    { fixture.lineBreak(), fixture.promptBreak(), fixture.pageBreak(), fixture.eos() },
    -- 2: known extended controls with their own argument counts
    {
      fixture.control(FieldMessageText.COLOR, { 1 }),
      fixture.control(FieldMessageText.SIZE, { 200 }),
      fixture.control(FieldMessageText.YESNO, { 0 }),
      fixture.control(FieldMessageText.STRVAR_1 + 3, { 0, 0 }),
      fixture.control(FieldMessageText.UNK_FF02, { 1, 0 }),
      fixture.eos(),
    },
    -- 3: controls outside the marker registry, with and without arguments
    { fixture.control(0x0240, { 1, 2, 3 }), fixture.control(0x0250, {}), fixture.eos() },
    -- 4: a control the tokenizer could not frame as an extended control
    { fixture.opaqueControl(0x0707), fixture.eos() },
    -- 5: packed trainer-name substitution keeps its exact source words
    { fixture.trainerName({ 0x1234, 0x5678 }), fixture.glyph(0x0142, "A"), fixture.eos() },
    -- 6: a zero-token message is valid
    {},
    -- 7: tokens after EOS stay in the stream even though the text stops there
    { fixture.glyph(0x0142, "A"), fixture.eos(), fixture.glyph(0x0143, "B"), fixture.lineBreak() },
    -- 8: last message is a single EOS record, so its stream span ends the payload
    { fixture.eos() },
  }
end

-- The canonical normalized tokens the producer normalizes to: derived control
-- kinds/names, canonical raw words, and dictionary display text.
local function expectedMessages()
  local fixture = FieldMessageFixture
  return {
    [0] = {
      { kind = "glyph", code = 0x0141, text = "th", raw = { 0x0141 } },
      { kind = "glyph", code = 0x01DE, text = "é", raw = { 0x01DE } },
      { kind = "glyph", code = 0x0150, text = "ll", raw = { 0x0150 } },
      { kind = "line_break", raw = { FieldMessageText.CHAR_LF } },
      { kind = "glyph", code = 0x0141, text = "th", raw = { 0x0141 } },
      { kind = "eos", raw = { FieldMessageText.EOS } },
    },
    [1] = {
      { kind = "line_break", raw = { FieldMessageText.CHAR_LF } },
      { kind = "prompt_break", raw = { FieldMessageText.PROMPT_BREAK } },
      { kind = "page_break", raw = { FieldMessageText.PAGE_BREAK } },
      { kind = "eos", raw = { FieldMessageText.EOS } },
    },
    [2] = {
      {
        kind = "style",
        control = FieldMessageText.COLOR,
        name = "COLOR",
        args = { 1 },
        raw = { 0xFFFE, 0xFF00, 1, 1 },
      },
      {
        kind = "style",
        control = FieldMessageText.SIZE,
        name = "SIZE",
        args = { 200 },
        raw = { 0xFFFE, 0xFF01, 1, 200 },
      },
      {
        kind = "focus_indicator",
        control = FieldMessageText.YESNO,
        name = "YESNO",
        args = { 0 },
        raw = { 0xFFFE, 0x0200, 1, 0 },
      },
      {
        kind = "substitution",
        control = 0x0103,
        name = "STRVAR_1",
        args = { 0, 0 },
        raw = { 0xFFFE, 0x0103, 2, 0, 0 },
      },
      {
        kind = "style",
        control = FieldMessageText.UNK_FF02,
        name = "UNK_FF02",
        args = { 1, 0 },
        raw = { 0xFFFE, 0xFF02, 2, 1, 0 },
      },
      { kind = "eos", raw = { FieldMessageText.EOS } },
    },
    [3] = {
      { kind = "unsupported_control", control = 0x0240, args = { 1, 2, 3 }, raw = { 0xFFFE, 0x0240, 3, 1, 2, 3 } },
      { kind = "unsupported_control", control = 0x0250, args = {}, raw = { 0xFFFE, 0x0250, 0 } },
      { kind = "eos", raw = { FieldMessageText.EOS } },
    },
    [4] = {
      { kind = "unsupported_control", control = 0x0707, args = {}, raw = { 0x0707 } },
      { kind = "eos", raw = { FieldMessageText.EOS } },
    },
    [5] = {
      {
        kind = "substitution",
        control = FieldMessageText.TRNAME,
        name = "TRNAME",
        args = {},
        raw = { FieldMessageText.TRNAME, 0x1234, 0x5678 },
      },
      { kind = "glyph", code = 0x0142, text = "A", raw = { 0x0142 } },
      { kind = "eos", raw = { FieldMessageText.EOS } },
    },
    [6] = {},
    [7] = {
      { kind = "glyph", code = 0x0142, text = "A", raw = { 0x0142 } },
      { kind = "eos", raw = { FieldMessageText.EOS } },
      { kind = "glyph", code = 0x0143, text = "B", raw = { 0x0143 } },
      { kind = "line_break", raw = { FieldMessageText.CHAR_LF } },
    },
    [8] = { { kind = "eos", raw = { FieldMessageText.EOS } } },
  }
end

local function occurrenceCount(bytes, needle)
  local count = 0
  local position = 1
  while true do
    local found = bytes:find(needle, position, true)
    if found == nil then
      return count
    end
    count = count + 1
    position = found + #needle
  end
end

-- The locked header's exact payload byte count, a little-endian u32 at the
-- zero-based header offset 36.
local function totalBytesOf(bytes)
  local b1, b2, b3, b4 = bytes:byte(37, 40)
  return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
end

local function assertStructuredError(code, fn, label)
  local err = Assert.throws(fn, label)
  Assert.isTrue(Errors.is(err), label .. " must raise a structured error, got " .. tostring(err))
  Assert.equal(assert(err).code, code, label)
  return err
end

local function u16(value)
  return string.char(value % 256, math.floor(value / 256) % 256)
end

local function u32(value)
  return string.char(
    value % 256,
    math.floor(value / 256) % 256,
    math.floor(value / 65536) % 256,
    math.floor(value / 16777216) % 256
  )
end

-- Builds one payload from explicit sections so a test can produce layouts the
-- encoder never writes. Every header field may be overridden, which is how the
-- section-arithmetic cases stay readable.
local function craft(spec)
  local index = spec.index or { 0 }
  local glyphs = spec.glyphs or {}
  local stream = spec.stream or {}
  local messageCount = spec.messageCount or (#index - 1)
  local glyphCount = spec.glyphCount or #glyphs
  local glyphTableOffset = 40 + 4 * #index
  local glyphTextOffset = glyphTableOffset + 8 * glyphCount
  local entries, texts, textBytes = {}, spec.texts or {}, 0
  for position, glyph in ipairs(glyphs) do
    entries[position] = u16(glyph.code) .. u16(#glyph.text) .. u32(textBytes)
    texts[#texts + 1] = glyph.text
    textBytes = textBytes + #glyph.text
  end
  for position, entry in ipairs(spec.entries or {}) do
    entries[position] = entry
  end
  local text = table.concat(texts)
  local streamOffset = glyphTextOffset + #text
  if streamOffset % 2 == 1 then
    text = text .. "\0"
    streamOffset = streamOffset + 1
  end
  local words = {}
  for position, word in ipairs(stream) do
    words[position] = u16(word)
  end
  local totalBytes = streamOffset + 2 * #stream
  local header = (spec.magic or "G4MS")
    .. u16(spec.formatVersion or 1)
    .. u16(spec.headerBytes or 40)
    .. u32(spec.bankId or BANK_ID)
    .. u32(messageCount)
    .. u32(glyphCount)
    .. u32(spec.messageIndexOffset or 40)
    .. u32(spec.glyphTableOffset or glyphTableOffset)
    .. u32(spec.glyphTextOffset or glyphTextOffset)
    .. u32(spec.streamOffset or streamOffset)
    .. u32(spec.totalBytes or totalBytes)
  local indexBytes = {}
  for position, offset in ipairs(index) do
    indexBytes[position] = u32(offset)
  end
  return table.concat({ header, table.concat(indexBytes), table.concat(entries), text, table.concat(words) })
end

function T.compact_bank_round_trips_every_normalized_token()
  local messages = fixtureMessages()
  local expected = expectedMessages()
  local bank = FieldMessageFixture.bank(BANK_ID, messages)
  local size = FieldMessageAsset.encodedSize(bank)
  local data = FieldMessageFixture.encode(bank)
  local bytes = data:getString()
  Assert.equal(#bytes, size, "the encoded payload is exactly the size the encoder declares")

  local view = assert(FieldMessageAsset.open(data, BANK_ID))
  Assert.equal(view.bankId, BANK_ID)
  Assert.equal(view.messageCount, #messages)

  for messageId = 0, view.messageCount - 1 do
    local template = assert(FieldMessageAsset.message(view, messageId))
    Assert.equal(template.bankId, BANK_ID)
    Assert.equal(template.messageId, messageId)
    Assert.deepEqual(template.tokens, expected[messageId], "message " .. messageId .. " tokens")
    Assert.equal(template.text, FieldMessageText.tokensToText(expected[messageId]), "message " .. messageId .. " text")
  end

  -- Display text renders from the stored glyph dictionary, and the first EOS
  -- ends it while the remaining tokens stay in the stream.
  Assert.equal(assert(FieldMessageAsset.message(view, 0)).text, "théll\nth")
  local afterEos = assert(FieldMessageAsset.message(view, 7))
  Assert.equal(afterEos.text, "A", "display text stops at the first EOS")
  Assert.equal(#afterEos.tokens, 4, "tokens after EOS remain in the decoded stream")

  Assert.isTrue(FieldMessageAsset.validate(data, BANK_ID), "the complete bank validates")

  -- Re-encoding the same normalized input produces the same bytes: the layout
  -- is deterministic and carries no per-run state.
  Assert.equal(FieldMessageFixture.encode(FieldMessageFixture.bank(BANK_ID, fixtureMessages())):getString(), bytes)

  -- Display strings are stored once per bank, never per message: this
  -- dictionary entry is used by two glyph tokens yet appears once in the
  -- payload.
  Assert.equal(occurrenceCount(bytes, "th"), 1, "a repeated glyph's display text is stored once")
end

function T.selected_message_ignores_a_malformed_sibling()
  local messages = fixtureMessages()
  local bytes = FieldMessageFixture.encode(FieldMessageFixture.bank(BANK_ID, messages)):getString()
  local totalBytes = totalBytesOf(bytes)
  Assert.equal(totalBytes, #bytes, "the header carries the exact payload length")

  -- Corrupt only the last message: its single-word EOS escape becomes an
  -- extended-control escape with no following words, a truncated record. The
  -- header, index, dictionary, and every other message stay valid.
  local corrupted = bytes:sub(1, totalBytes - 4) .. string.char(5, 0) .. bytes:sub(totalBytes - 1)

  local view = assert(FieldMessageAsset.open(corrupted, BANK_ID))
  local sibling = assert(FieldMessageAsset.message(view, 0))
  Assert.deepEqual(
    sibling.tokens,
    expectedMessages()[0],
    "a selected message decodes inside a bank with a malformed sibling"
  )

  assertStructuredError(FieldMessageAsset.MESSAGE_ASSET_INVALID, function()
    return FieldMessageAsset.message(view, 8)
  end, "selecting the malformed message must reject it")
  assertStructuredError(FieldMessageAsset.MESSAGE_ASSET_INVALID, function()
    return FieldMessageAsset.validate(corrupted, BANK_ID)
  end, "explicit validation must reject the malformed sibling")

  assertStructuredError(FieldMessageAsset.MESSAGE_ID_OUT_OF_RANGE, function()
    return FieldMessageAsset.message(view, view.messageCount)
  end, "a message id at the message count is out of range")
end

-- Zero-message banks, zero-length messages, and messages that start on an odd
-- word offset are all legal layouts.
function T.empty_banks_and_messages_are_valid()
  local emptyBank = FieldMessageFixture.bank(BANK_ID, {})
  local emptyBytes = FieldMessageFixture.encode(emptyBank):getString()
  Assert.equal(#emptyBytes, 40 + 4, "a zero-message bank is its header and one index entry")
  local emptyView = assert(FieldMessageAsset.open(emptyBytes, BANK_ID))
  Assert.equal(emptyView.messageCount, 0)
  Assert.isTrue(FieldMessageAsset.validate(emptyBytes, BANK_ID))
  assertStructuredError(FieldMessageAsset.MESSAGE_ID_OUT_OF_RANGE, function()
    return FieldMessageAsset.message(emptyView, 0)
  end, "a zero-message bank has no message 0")

  -- The first message is one word long, so the second message starts on an odd
  -- word offset.
  local messages = {
    { FieldMessageFixture.glyph(0x0141, "A") },
    { FieldMessageFixture.eos() },
    {},
  }
  local bytes = FieldMessageFixture.encode(FieldMessageFixture.bank(BANK_ID, messages)):getString()
  local view = assert(FieldMessageAsset.open(bytes, BANK_ID))
  Assert.equal(#assert(FieldMessageAsset.message(view, 0)).tokens, 1)
  Assert.equal(#assert(FieldMessageAsset.message(view, 1)).tokens, 1, "a message may begin on an odd word offset")
  local empty = assert(FieldMessageAsset.message(view, 2))
  Assert.equal(#empty.tokens, 0, "adjacent equal index offsets mean an empty message")
  Assert.equal(empty.text, "")
  Assert.isTrue(FieldMessageAsset.validate(bytes, BANK_ID))
end

-- A glyph code that collides with a control constant stays a glyph because the
-- stream framing, not the code, decides the meaning.
function T.glyph_codes_that_match_control_constants_stay_glyphs()
  local fixtures = FieldMessageFixture
  local messages = {
    { fixtures.glyph(FieldMessageText.EXT_CTRL_CODE_BEGIN, "ext"), fixtures.glyph(65535, "last"), fixtures.eos() },
  }
  local data = FieldMessageFixture.encode(FieldMessageFixture.bank(BANK_ID, messages))
  local view = assert(FieldMessageAsset.open(data, BANK_ID))
  local tokens = assert(FieldMessageAsset.message(view, 0)).tokens
  Assert.equal(#tokens, 3)
  Assert.equal(tokens[1].kind, "glyph")
  Assert.equal(tokens[1].code, FieldMessageText.EXT_CTRL_CODE_BEGIN)
  Assert.equal(tokens[1].text, "ext")
  Assert.equal(tokens[2].kind, "glyph")
  Assert.equal(tokens[2].code, 65535)
  Assert.equal(tokens[2].text, "last")
  Assert.equal(tokens[3].kind, "eos")
  Assert.isTrue(FieldMessageAsset.validate(data, BANK_ID))
end

-- The view roots its backing bytes: dropping the caller's local copy cannot
-- invalidate a later read.
function T.an_open_view_keeps_its_backing_bytes_alive()
  local data = FieldMessageFixture.encode(FieldMessageFixture.bank(BANK_ID, fixtureMessages()))
  local view = assert(FieldMessageAsset.open(data, BANK_ID))
  data = nil
  collectgarbage()
  collectgarbage()
  Assert.equal(assert(FieldMessageAsset.message(view, 0)).text, "théll\nth", "the view owns its bytes")
end

-- The malformed-layout class: every case is a payload the encoder never writes
-- and the reader must reject with its named identity instead of misreading.
function T.malformed_layouts_are_rejected()
  local cases = {
    { label = "wrong magic", bytes = craft({ magic = "G4MX" }) },
    { label = "unknown format version", bytes = craft({ formatVersion = 2 }) },
    { label = "wrong header size", bytes = craft({ headerBytes = 36 }) },
    { label = "a different bank id", bytes = craft({}), expectedBankId = BANK_ID + 1 },
    { label = "a truncated header", bytes = craft({}):sub(1, 24) },
    { label = "a truncated payload", bytes = craft({}):sub(1, -2) },
    { label = "a payload longer than its declared size", bytes = craft({ totalBytes = 48 }) },
    { label = "a message index away from its section", bytes = craft({ messageIndexOffset = 44 }) },
    { label = "a glyph table away from its section", bytes = craft({ glyphTableOffset = 48 }) },
    { label = "a glyph text section away from its section", bytes = craft({ glyphTextOffset = 48 }) },
    { label = "an odd stream offset", bytes = craft({ streamOffset = 49 }) },
    { label = "a glyph count above the format limit", bytes = craft({ glyphCount = 65537 }) },
    { label = "an index that does not start at zero", bytes = craft({ index = { 1, 1 }, stream = { 65535, 1 } }) },
    { label = "an index that decreases", bytes = craft({ index = { 0, 2, 1 }, stream = { 65535, 1, 65535, 1 } }) },
    {
      label = "an index that ends before the stream",
      bytes = craft({ index = { 0, 1 }, stream = { 65535, 1, 65535, 1 } }),
    },
    { label = "an index that ends past the stream", bytes = craft({ index = { 0, 3 }, stream = { 65535, 1 } }) },
    {
      label = "a zero-length glyph display string",
      bytes = craft({ glyphs = { { code = 1, text = "" } }, index = { 0, 1 }, stream = { 1 } }),
    },
    {
      label = "a glyph table with descending codes",
      bytes = craft({
        entries = { u16(2) .. u16(1) .. u32(0), u16(1) .. u16(1) .. u32(1) },
        texts = { "a", "b" },
        glyphCount = 2,
        index = { 0, 1 },
        stream = { 2 },
      }),
    },
    {
      label = "a glyph table with a repeated code",
      bytes = craft({
        entries = { u16(1) .. u16(1) .. u32(0), u16(1) .. u16(1) .. u32(1) },
        texts = { "a", "b" },
        glyphCount = 2,
        index = { 0, 1 },
        stream = { 1 },
      }),
    },
    {
      label = "glyph text that is not packed contiguously",
      bytes = craft({
        entries = { u16(1) .. u16(1) .. u32(0), u16(2) .. u16(1) .. u32(2) },
        texts = { "a", "b" },
        glyphCount = 2,
        index = { 0, 1 },
        stream = { 1 },
      }),
    },
    {
      label = "a glyph text span past the dictionary",
      bytes = craft({
        entries = { u16(1) .. u16(9) .. u32(0) },
        texts = { "ab" },
        glyphCount = 1,
        index = { 0, 1 },
        stream = { 1 },
      }),
    },
    { label = "an unknown escape tag", bytes = craft({ index = { 0, 2 }, stream = { 65535, 9 } }) },
    { label = "a truncated escape", bytes = craft({ index = { 0, 1 }, stream = { 65535 } }) },
    {
      label = "an extended control with a missing argument",
      bytes = craft({ index = { 0, 5 }, stream = { 65535, 5, 0xFF00, 2, 1 } }),
    },
    {
      label = "an opaque control without its word",
      bytes = craft({ index = { 0, 2 }, stream = { 65535, 7 } }),
    },
    {
      label = "a trainer-name record without raw words",
      bytes = craft({ index = { 0, 3 }, stream = { 65535, 6, 0 } }),
    },
    {
      label = "a trainer-name record that does not begin with its code",
      bytes = craft({ index = { 0, 4 }, stream = { 65535, 6, 2, 0x1234, 0x5678 } }),
    },
    { label = "a glyph with no dictionary entry", bytes = craft({ index = { 0, 1 }, stream = { 7 } }) },
  }

  for _, case in ipairs(cases) do
    local expectedBankId = case.expectedBankId or BANK_ID
    assertStructuredError(FieldMessageAsset.MESSAGE_ASSET_INVALID, function()
      return FieldMessageAsset.validate(case.bytes, expectedBankId)
    end, "validation must reject " .. case.label)
    local opened, openErr = pcall(FieldMessageAsset.open, case.bytes, expectedBankId)
    if not opened then
      Assert.isTrue(Errors.is(openErr), "opening must fail structurally for " .. case.label)
      Assert.equal(assert(openErr).code, FieldMessageAsset.MESSAGE_ASSET_INVALID, case.label)
    end
  end

  -- The truncated escape is only visible to a caller that reads the stream: a
  -- bounded open accepts the header, while the indexed lookup rejects the
  -- record it cannot finish.
  local truncated = craft({ index = { 0, 1 }, stream = { 65535 } })
  local view = assert(FieldMessageAsset.open(truncated, BANK_ID))
  assertStructuredError(FieldMessageAsset.MESSAGE_ASSET_INVALID, function()
    return FieldMessageAsset.message(view, 0)
  end, "a truncated escape is rejected by the selected read")
end

-- The encoder rejects input the persisted format cannot express, and a
-- mismatch between the caller's buffer capacity and the declared size is a
-- programming fault rather than a readable payload.
function T.encoder_rejects_unencodable_input()
  local fixtures = FieldMessageFixture
  local cases = {
    {
      label = "a bank without its declared messages",
      bank = { bankId = BANK_ID, messageCount = 2, messages = { [0] = { tokens = {} } } },
    },
    {
      label = "a bank with an id outside its count",
      bank = { bankId = BANK_ID, messageCount = 1, messages = { [1] = { tokens = {} } } },
    },
    {
      label = "a sparse token array",
      bank = { bankId = BANK_ID, messageCount = 1, messages = { [0] = { tokens = { [2] = fixtures.eos() } } } },
    },
    { label = "a bank id beyond the format", bank = { bankId = 2 ^ 32, messageCount = 0, messages = {} } },
    { label = "a message count beyond any payload", bank = { bankId = BANK_ID, messageCount = 2 ^ 31, messages = {} } },
    {
      label = "a glyph code beyond the format",
      bank = FieldMessageFixture.bank(BANK_ID, { { fixtures.glyph(70000, "A") } }),
    },
    {
      label = "a glyph without display text",
      bank = FieldMessageFixture.bank(BANK_ID, { { { kind = "glyph", code = 1, text = "" } } }),
    },
    {
      label = "a glyph whose display text exceeds the format",
      bank = FieldMessageFixture.bank(BANK_ID, { { fixtures.glyph(1, string.rep("a", 65536)) } }),
    },
    {
      label = "one glyph code with two display strings",
      bank = FieldMessageFixture.bank(BANK_ID, { { fixtures.glyph(1, "A"), fixtures.glyph(1, "B") } }),
    },
    {
      label = "an unknown token kind",
      bank = FieldMessageFixture.bank(BANK_ID, { { { kind = "nonsense" } } }),
    },
    {
      label = "an extended control with a mismatched raw array",
      bank = FieldMessageFixture.bank(BANK_ID, {
        { { kind = "style", control = FieldMessageText.COLOR, args = { 1 }, raw = { 1, 2 } } },
      }),
    },
    {
      label = "an extended control with an argument outside the format",
      bank = FieldMessageFixture.bank(BANK_ID, {
        { { kind = "style", control = FieldMessageText.COLOR, args = { 70000 } } },
      }),
    },
    {
      label = "an extended control with the wrong canonical kind",
      bank = FieldMessageFixture.bank(
        BANK_ID,
        { { { kind = "style", control = FieldMessageText.COLOR + 8, args = {} } } }
      ),
    },
    {
      label = "an opaque control with arguments",
      bank = FieldMessageFixture.bank(BANK_ID, {
        { { kind = "unsupported_control", control = 0x0707, args = { 1 }, raw = { 0x0707 } } },
      }),
    },
    {
      label = "a substitution control without its raw words",
      bank = FieldMessageFixture.bank(BANK_ID, {
        { { kind = "substitution", control = FieldMessageText.TRNAME, args = {} } },
      }),
    },
    {
      label = "a trainer-name record that does not begin with its code",
      bank = FieldMessageFixture.bank(BANK_ID, {
        { { kind = "substitution", control = FieldMessageText.TRNAME, args = {}, raw = { 0x1234 } } },
      }),
    },
  }

  for _, case in ipairs(cases) do
    assertStructuredError(FieldMessageAsset.MESSAGE_ASSET_INVALID, function()
      return FieldMessageAsset.encodedSize(case.bank)
    end, "encoding must reject " .. case.label)
    local output = love.data.newByteData(64)
    assertStructuredError(FieldMessageAsset.MESSAGE_ASSET_INVALID, function()
      return FieldMessageAsset.encodeInto(case.bank, output:getFFIPointer(), 64)
    end, "writing must reject " .. case.label)
  end

  local valid = FieldMessageFixture.bank(BANK_ID, { { fixtures.eos() } })
  local size = FieldMessageAsset.encodedSize(valid)
  local data = love.data.newByteData(size)
  Assert.throws(function()
    FieldMessageAsset.encodeInto(valid, data:getFFIPointer(), size + 1)
  end, "a capacity other than the declared size is a programming fault")
  Assert.throws(function()
    FieldMessageAsset.encodeInto(valid, nil, size)
  end, "a nil output pointer is a programming fault")
  Assert.equal(FieldMessageAsset.encodeInto(valid, data:getFFIPointer(), size), size)
end

return { tests = T }
