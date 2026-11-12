-- The semantic Mail <-> shared word catalog adapter: template key
-- parsing, numeric message conversion, strict new-composition admission,
-- and tolerant saved-line expansion. A faithful fake catalog stands in
-- for the shared catalog here; the production catalog proves the real
-- identities, and production acceptance reads through the real owner.

local Assert = require("tests.support.Assert")
local MailTemplate = require("libs.hgss.src.field.MailTemplate")

local T = {}

local NULL_WORD = 65535

-- Minimal source-faithful catalog double: bank0..4/message0..19
-- identities with zero-, one-, and two-substitution arities, flagged
-- word identities, NULL stop semantics, and one final EOS per fragment.
local function fakeCatalog()
  local arities = {
    ["0:0"] = 0,
    ["0:19"] = 1,
    ["1:7"] = 2,
    ["2:4"] = 2,
    ["3:1"] = 1,
    ["4:19"] = 2,
  }
  local known = { [0] = true, [1] = true, [5] = true, [0x8005] = true, [NULL_WORD] = true }
  local catalog = {}
  function catalog.template(_, bank, number)
    if type(bank) ~= "number" or type(number) ~= "number" then
      return nil
    end
    local arity = arities[bank .. ":" .. number]
    if arity == nil then
      return nil
    end
    return { bank = bank, number = number, wordCount = arity }
  end
  function catalog.messageStatus(_, message)
    if type(message) ~= "table" then
      return "invalid"
    end
    local template = catalog:template(message.bank, message.number)
    if template == nil then
      return "invalid"
    end
    if type(message.words) ~= "table" or type(message.words[1]) ~= "number" or type(message.words[2]) ~= "number" then
      return "invalid"
    end
    for _, id in ipairs(message.words) do
      if id < 0 or id > 0xFFFF or id % 1 ~= 0 then
        return "invalid"
      end
      if known[id] ~= true then
        return "invalid"
      end
    end
    for slot = 1, template.wordCount do
      if message.words[slot] == NULL_WORD then
        return "incomplete"
      end
    end
    return "complete"
  end
  local function wordTokens(id)
    if id == NULL_WORD then
      return {}
    end
    assert(known[id], "test words stay known")
    -- One fragment carries an internal terminator to prove the adapter
    -- never concatenates embedded terminators.
    if id == 5 then
      return { { kind = "glyph", text = "w5" }, { kind = "eos" } }
    end
    return { { kind = "glyph", text = "w" .. tostring(id % 4096) } }
  end
  function catalog.expandMessage(_, message)
    local template = catalog:template(message.bank, message.number)
    if template == nil then
      error("unknown sentence template", 0)
    end
    local out = {}
    local slot = 1
    for index = 1, template.wordCount + 1 do
      if index <= template.wordCount then
        local id = message.words[slot]
        if id == nil or id == NULL_WORD then
          break
        end
        for _, fragment in ipairs(wordTokens(id)) do
          if fragment.kind == "eos" then
            break
          end
          out[#out + 1] = fragment
        end
        slot = slot + 1
      else
        out[#out + 1] = { kind = "glyph", text = "tail" }
      end
    end
    out[#out + 1] = { kind = "eos" }
    return out
  end
  return catalog
end

local function author()
  return { trainerId = 123, name = "MISTY", gender = 1, language = 2, game = 8 }
end

local function makeLetter(lines)
  return {
    schema = "g4-mail-v2",
    type = 0,
    author = author(),
    icons = { "CHIKORITA/f0", false, false },
    lines = lines,
  }
end

local function snapshot(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for key, child in pairs(value) do
    out[key] = snapshot(child)
  end
  return out
end

function T.converts_persisted_lines_to_numeric_messages_verbatim()
  local message = MailTemplate.toMessage({ template = "mail-template:2:4", words = { "0", "1" } })
  Assert.deepEqual(message, { bank = 2, number = 4, words = { 0, 1 } })
  local nulls = MailTemplate.toMessage({ template = "mail-template:0:0", words = { false, false } })
  Assert.deepEqual(nulls, { bank = 0, number = 0, words = { NULL_WORD, NULL_WORD } })
  local flagged = MailTemplate.toMessage({ template = "mail-template:4:19", words = { "32773", false } })
  Assert.deepEqual(flagged.words, { 0x8005, NULL_WORD })
  local edges = MailTemplate.toMessage({ template = "mail-template:0:19", words = { "5", false } })
  Assert.deepEqual(edges, { bank = 0, number = 19, words = { 5, NULL_WORD } })
end

function T.rejects_malformed_template_keys_and_word_fields()
  Assert.throws(function()
    MailTemplate.toMessage({ template = "mail-template:5:0", words = { "0", false } })
  end)
  Assert.throws(function()
    MailTemplate.toMessage({ template = "mail-template:0:20", words = { "0", false } })
  end)
  Assert.throws(function()
    MailTemplate.toMessage({ template = "mail.line.first", words = { "0", false } })
  end)
  Assert.throws(function()
    MailTemplate.toMessage({ template = "mail-template:1:7", words = { "99999", false } })
  end)
  Assert.throws(function()
    MailTemplate.toMessage({ template = "mail-template:1:7", words = { "", false } })
  end)
end

function T.adapts_accepted_results_with_normalized_trailing_fields()
  local catalog = fakeCatalog()
  local adapted = MailTemplate.fromMessage({ bank = 1, number = 7, words = { 0, 1 } }, catalog)
  Assert.deepEqual(adapted, { template = "mail-template:1:7", words = { "0", "1" } })
  local single = MailTemplate.fromMessage({ bank = 3, number = 1, words = { 5, NULL_WORD } }, catalog)
  Assert.deepEqual(single, { template = "mail-template:3:1", words = { "5", false } })
  -- Unused trailing fields normalize to false even when the editor left
  -- them populated.
  local normalized = MailTemplate.fromMessage({ bank = 3, number = 1, words = { 5, 1 } }, catalog)
  Assert.deepEqual(normalized.words, { "5", false })
  local plain = MailTemplate.fromMessage({ bank = 0, number = 0, words = { 0, 1 } }, catalog)
  Assert.deepEqual(plain, { template = "mail-template:0:0", words = { false, false } })
  Assert.throws(function()
    MailTemplate.fromMessage({ bank = 2, number = 9, words = { 0, 1 } }, catalog)
  end)
end

function T.admits_complete_letters_and_rejects_blank_ones()
  local catalog = fakeCatalog()
  local plain = makeLetter({ { template = "mail-template:0:0", words = { false, false } }, false, false })
  Assert.isTrue(MailTemplate.checkComposed(plain, catalog))
  local full = makeLetter({
    { template = "mail-template:2:4", words = { "0", "1" } },
    { template = "mail-template:3:1", words = { "5", false } },
    false,
  })
  Assert.isTrue(MailTemplate.checkComposed(full, catalog))
  local blank = makeLetter({ false, false, false })
  local ok, reason = MailTemplate.checkComposed(blank, catalog)
  Assert.isFalse(ok)
  Assert.equal(reason, "incomplete")
  local blankBefore = snapshot(blank)
  Assert.deepEqual(blank, blankBefore, "rejected composition leaves the letter untouched")
end

function T.rejects_incomplete_required_words_and_trailing_garbage()
  local catalog = fakeCatalog()
  local partial = makeLetter({ { template = "mail-template:2:4", words = { "0", false } }, false, false })
  local ok, reason = MailTemplate.checkComposed(partial, catalog)
  Assert.isFalse(ok)
  Assert.equal(reason, "incomplete")
  local garbage = makeLetter({ { template = "mail-template:3:1", words = { "5", "1" } }, false, false })
  local garbageOk, garbageReason = MailTemplate.checkComposed(garbage, catalog)
  Assert.isFalse(garbageOk)
  Assert.equal(garbageReason, "invalid_letter")
  local unknown = makeLetter({ { template = "mail-template:2:4", words = { "0", "7" } }, false, false })
  local unknownOk, unknownReason = MailTemplate.checkComposed(unknown, catalog)
  Assert.isFalse(unknownOk)
  Assert.equal(unknownReason, "invalid_letter")
  local missing = makeLetter({ { template = "mail-template:9:9", words = { "0", false } }, false, false })
  local missingOk, missingReason = MailTemplate.checkComposed(missing, catalog)
  Assert.isFalse(missingOk)
  Assert.equal(missingReason, "invalid_letter")
  local short = makeLetter({ { template = "mail-template:1:7", words = { "0" } }, false, false })
  local shortOk = MailTemplate.checkComposed(short, catalog)
  Assert.isFalse(shortOk)
end

function T.expands_saved_lines_tolerantly_without_rewriting_them()
  local catalog = fakeCatalog()
  -- A missing required substitution stops buffering but stays readable.
  local partial = MailTemplate.expandLine({ template = "mail-template:2:4", words = { "0", false } }, catalog)
  Assert.equal(partial[1].text, "w0")
  Assert.equal(partial[#partial].kind, "eos")
  -- An extra saved substitution never reaches the expansion.
  local extra = MailTemplate.expandLine({ template = "mail-template:3:1", words = { "5", "1" } }, catalog)
  local texts = {}
  for _, token in ipairs(extra) do
    Assert.isFalse(token.kind == "substitution", "expanded lines carry no substitution markers")
    if token.kind == "glyph" then
      texts[#texts + 1] = token.text
    end
  end
  Assert.deepEqual(texts, { "w5", "tail" })
  -- Embedded word terminators never concatenate into the expansion.
  for _, token in ipairs(extra) do
    Assert.isFalse(token.text == "w5eos", "embedded terminators stay stripped")
  end
  Assert.throws(function()
    MailTemplate.expandLine({ template = "mail-template:9:9", words = { "0", false } }, catalog)
  end)
end

function T.returns_detached_expansions()
  local catalog = fakeCatalog()
  local line = { template = "mail-template:2:4", words = { "0", "1" } }
  local before = snapshot(line)
  local tokens = MailTemplate.expandLine(line, catalog)
  Assert.isTrue(type(tokens) == "table" and #tokens > 0, "expansion detaches its token list")
  tokens[#tokens + 1] = { kind = "glyph", text = "MUTATED" }
  tokens[1] = { kind = "glyph", text = "MUTATED" }
  Assert.deepEqual(line, before, "expansion never mutates the stored line")
end

return { tests = T }
