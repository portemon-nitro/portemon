-- The real Shift prompt record behind the optional replacement offer:
-- bank 197 message 835 tokenizes and carries exactly the three
-- substitution buffers (trainer class, trainer name, incoming mon) the
-- battle screen stages for its Yes/No question.

local Assert = require("tests.support.Assert")
local BattlePresentationSources = require("romdump.src.config.BattlePresentationSources")
local RomSuite = require("tests.rom.support.RomSuite")
local UiMessageBank = require("romdump.src.digest.ui.UiMessageBank")
local charmap = require("romdump.src.catalog.hgss.charmap")

local T = {}

function T.shift_offer_record_carries_three_prompt_buffers(romFs, versionId)
  local archive, openErr = romFs:openNarc(BattlePresentationSources.MENU_MESSAGE_BANK)
  Assert.isTrue(archive ~= nil, versionId .. ": the message archive opens (" .. tostring(openErr) .. ")")
  local record = BattlePresentationSources.MESSAGE_RECORDS["battle/prompt/shift-offer"]
  Assert.equal(record.bank, "scriptController", "the shift offer reads the script-controller bank")
  Assert.equal(record.messageId, 835, "the shift offer reads the replacement-subscript record")
  local memberId = BattlePresentationSources.MESSAGE_BANKS[record.bank]
  local bank, failure = UiMessageBank.read(archive, memberId, "shift offer prompt", {}, "shift-offer")
  Assert.isTrue(bank ~= nil, versionId .. ": the bank decodes (" .. tostring(failure and failure.message) .. ")")
  local tokens, tokenFailure = UiMessageBank.tokens(bank, memberId, record.messageId, charmap)
  Assert.isTrue(
    tokens ~= nil,
    versionId .. ": the shift offer tokenizes (" .. tostring(tokenFailure and tokenFailure.message) .. ")"
  )
  local substitutions = 0
  local sawFocus = false
  local sawEnd = false
  for _, token in ipairs(tokens) do
    if token.kind == "substitution" then
      substitutions = substitutions + 1
    elseif token.kind == "focus_indicator" then
      sawFocus = true
    elseif token.kind == "eos" then
      sawEnd = true
    end
  end
  Assert.equal(substitutions, 3, versionId .. ": the shift offer stages three prompt buffers")
  Assert.isTrue(sawFocus, versionId .. ": the shift offer ends in a Yes/No choice")
  Assert.isTrue(sawEnd, versionId .. ": the shift offer terminates its record")
end

local suite = RomSuite.fromFacts(T)
suite.metadata.capabilities = { "rom_dump" }
return suite
