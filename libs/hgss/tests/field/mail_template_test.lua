-- Shared compiled Mail template checks: substitution counts, composed
-- admission, and stored line expansion used by composition and custody.

local Assert = require("tests.support.Assert")
local MailTemplate = require("libs.hgss.src.field.MailTemplate")

local T = {}

local function text(value)
  return { kind = "text", value = value }
end

local function substitution()
  return { kind = "substitution" }
end

local function templateSet()
  return {
    ["plain"] = { text("hello") },
    ["one"] = { text("hi"), substitution() },
    ["two"] = { text("hi"), substitution(), substitution() },
    ["three"] = { text("hi"), substitution(), substitution(), substitution() },
  }
end

local function dictionary()
  return {
    ["0"] = { text("PIKA") },
    ["1"] = { text("CHU") },
  }
end

local function mailText()
  return { templates = templateSet() }
end

local function author()
  return { trainerId = 123, name = "MISTY", gender = 1, language = 2, game = 8 }
end

local function makeLine(templateKey, first, second)
  return { template = templateKey, words = { first, second } }
end

local function makeLetter(lines)
  return {
    schema = "g4-mail-v1",
    type = 0,
    author = author(),
    icons = { false, false, false },
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

function T.counts_template_substitution_slots()
  Assert.equal(MailTemplate.substitutionCount(templateSet()["plain"]), 0)
  Assert.equal(MailTemplate.substitutionCount(templateSet()["one"]), 1)
  Assert.equal(MailTemplate.substitutionCount(templateSet()["two"]), 2)
  Assert.equal(MailTemplate.substitutionCount(templateSet()["three"]), 3)
end

function T.malformed_template_tokens_are_invariant_errors()
  Assert.throws(function()
    MailTemplate.substitutionCount({ {} })
  end)
  Assert.throws(function()
    MailTemplate.substitutionCount({ false })
  end)
end

function T.admits_complete_zero_one_and_two_slot_letters()
  local texts = mailText()
  local words = dictionary()
  local plain = makeLetter({ makeLine("plain", false, false), false, false })
  Assert.isTrue(MailTemplate.checkComposed(plain, texts, words))
  local single = makeLetter({ makeLine("one", "0", false), false, false })
  Assert.isTrue(MailTemplate.checkComposed(single, texts, words))
  local full = makeLetter({ makeLine("two", "0", "1"), false, false })
  Assert.isTrue(MailTemplate.checkComposed(full, texts, words))
end

function T.refuses_three_slot_templates_even_when_stored_fields_are_filled()
  local texts = mailText()
  local words = dictionary()
  local before = snapshot(texts)
  local letter = makeLetter({ makeLine("three", "0", "1"), false, false })
  local letterBefore = snapshot(letter)
  local ok, reason = MailTemplate.checkComposed(letter, texts, words)
  Assert.isFalse(ok, "three substitutions cannot fit the two stored fields")
  Assert.equal(reason, "invalid_letter")
  Assert.deepEqual(letter, letterBefore, "rejected composition leaves the letter untouched")
  Assert.deepEqual(texts, before, "rejected composition leaves compiled text untouched")
end

function T.reports_missing_required_words_as_incomplete()
  local texts = mailText()
  local words = dictionary()
  local ok, reason = MailTemplate.checkComposed(makeLetter({ makeLine("two", "0", false), false, false }), texts, words)
  Assert.isFalse(ok)
  Assert.equal(reason, "incomplete")
  local emptyOk, emptyReason =
    MailTemplate.checkComposed(makeLetter({ makeLine("one", false, false), false, false }), texts, words)
  Assert.isFalse(emptyOk)
  Assert.equal(emptyReason, "incomplete")
end

function T.refuses_unknown_words_and_trailing_garbage_without_mutation()
  local texts = mailText()
  local words = dictionary()
  local unknown = makeLetter({ makeLine("two", "0", "9999"), false, false })
  local unknownBefore = snapshot(unknown)
  local unknownOk, unknownReason = MailTemplate.checkComposed(unknown, texts, words)
  Assert.isFalse(unknownOk)
  Assert.equal(unknownReason, "invalid_letter")
  Assert.deepEqual(unknown, unknownBefore, "unknown words leave the letter untouched")
  local garbage = makeLetter({ makeLine("one", "0", "1"), false, false })
  local garbageOk, garbageReason = MailTemplate.checkComposed(garbage, texts, words)
  Assert.isFalse(garbageOk)
  Assert.equal(garbageReason, "invalid_letter")
  local missing = makeLetter({ makeLine("missing-template", "0", false), false, false })
  local missingOk, missingReason = MailTemplate.checkComposed(missing, texts, words)
  Assert.isFalse(missingOk)
  Assert.equal(missingReason, "invalid_letter")
  local short = makeLetter({ { template = "one", words = { "0" } }, false, false })
  local shortOk, shortReason = MailTemplate.checkComposed(short, texts, words)
  Assert.isFalse(shortOk)
  Assert.equal(shortReason, "invalid_letter")
end

function T.expands_present_words_and_skips_missing_stored_words()
  local texts = mailText()
  local words = dictionary()
  local tokens = MailTemplate.expandLine(makeLine("two", "0", false), texts, words)
  local kinds = {}
  for _, token in ipairs(tokens) do
    Assert.notNil(token.kind)
    kinds[#kinds + 1] = token.kind
    Assert.isFalse(token.kind == "substitution", "expanded lines carry no substitution markers")
  end
  Assert.equal(tokens[1].value, "hi")
  Assert.equal(tokens[2].value, "PIKA")
  Assert.equal(#tokens, 2, "a missing stored word contributes no tokens")
  local both = MailTemplate.expandLine(makeLine("two", "0", "1"), texts, words)
  Assert.equal(#both, 3)
  Assert.equal(both[3].value, "CHU")
  local plain = MailTemplate.expandLine(makeLine("plain", false, false), texts, words)
  Assert.equal(#plain, 1)
  Assert.equal(plain[1].value, "hello")
end

function T.rejects_corrupt_stored_lines_instead_of_hiding_them()
  local texts = mailText()
  local words = dictionary()
  Assert.throws(function()
    MailTemplate.expandLine(makeLine("three", "0", "1"), texts, words)
  end)
  Assert.throws(function()
    MailTemplate.expandLine(makeLine("two", "0", "9999"), texts, words)
  end)
  Assert.throws(function()
    MailTemplate.expandLine(makeLine("one", "0", "1"), texts, words)
  end)
  Assert.throws(function()
    MailTemplate.expandLine(makeLine("missing-template", "0", false), texts, words)
  end)
end

function T.returns_detached_tokens_leaving_templates_and_dictionary_intact()
  local texts = mailText()
  local words = dictionary()
  local templateBefore = snapshot(texts.templates["two"])
  local wordBefore = snapshot(words["0"])
  local tokens = MailTemplate.expandLine(makeLine("two", "0", "1"), texts, words)
  Assert.isTrue(tokens ~= texts.templates["two"], "expansion detaches from the template array")
  Assert.isTrue(tokens ~= words["0"], "expansion detaches from the dictionary array")
  tokens[#tokens + 1] = text("MUTATED")
  tokens[1] = text("MUTATED")
  Assert.deepEqual(texts.templates["two"], templateBefore, "expansion never mutates the template")
  Assert.deepEqual(words["0"], wordBefore, "expansion never mutates the dictionary")
end

return { tests = T }
