-- Retail greeting and word-reference arithmetic: the bank-640 entry
-- index and the staged word bank/entry parse. Pure source-table rules
-- with no collaborators.

local Assert = require("tests.support.Assert")
local PhoneGreetingSets = require("game.hgss.src.pokegear.PhoneGreetingSets")

local T = {
  metadata = {
    tags = { "pokegear" },
  },
  tests = {},
}

function T.tests.greeting_entries_index_by_direction_time_and_gender()
  Assert.equal(PhoneGreetingSets.entry(0, 0, false, 0), 0, "outgoing morning male opens the set")
  Assert.equal(PhoneGreetingSets.entry(0, 0, false, 1), 1, "outgoing morning female follows")
  Assert.equal(PhoneGreetingSets.entry(0, 2, false, 0), 4, "outgoing night male reads the third pair")
  Assert.equal(PhoneGreetingSets.entry(0, 0, true, 0), 6, "incoming morning male reads the second group")
  Assert.equal(PhoneGreetingSets.entry(0, 2, true, 1), 11, "incoming night female closes the set")
  Assert.equal(PhoneGreetingSets.entry(2, 1, false, 0), 73, "repeated sets share the day entries")
  Assert.throws(function()
    PhoneGreetingSets.entry(8, 0, false, 0)
  end, "an unknown greeting set fails")
  Assert.throws(function()
    PhoneGreetingSets.entry(0, 3, false, 0)
  end, "an unknown time band fails")
end

function T.tests.word_references_parse_their_bank_entry_and_offset()
  local bank, entry = PhoneGreetingSets.wordEntry("msg_0680_00023", 4)
  Assert.equal(bank, 680, "the word reference names its bank")
  Assert.equal(entry, 27, "the drawn pick offsets the staged entry")
  local bank2, entry2 = PhoneGreetingSets.wordEntry("msg_0669_00016", 0)
  Assert.equal(bank2, 669, "a zero pick keeps the staged entry")
  Assert.equal(entry2, 16, "a zero pick keeps the staged entry number")
  Assert.throws(function()
    PhoneGreetingSets.wordEntry("msg_0680_00023", -1)
  end, "a negative pick fails")
  Assert.throws(function()
    PhoneGreetingSets.wordEntry("bank-680-entry-23", 0)
  end, "a non-reference word identity fails")
end

return T
