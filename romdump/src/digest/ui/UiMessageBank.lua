-- Producer-private message-bank read/digest/decode/tokenize plumbing shared by
-- the Bag, Party and Summary asset compilers. Each compiler keeps its own
-- archive selection and error namespace; this helper only records the exact
-- messages:member:{bankId} dependency (role plus raw-byte digest) before
-- decoding through the authoritative FieldMessageBank, and tokenizes single
-- messages through the authoritative FieldMessageTokenizer. Failures return
-- small tagged descriptors (stage read, decode, missing_message or tokenize,
-- with the source bank and the underlying error fields) so callers can raise
-- their own protocol errors; the helper never raises a feature protocol code.
-- Pure module: no love dependency.

local Errors = require("libs.errors.src.Errors")
local Hashing = require("romdump.src.digest.Hashing")
local FieldMessageBank = require("romdump.src.digest.ui.FieldMessageBank")
local FieldMessageTokenizer = require("romdump.src.digest.ui.FieldMessageTokenizer")

---@class UiMessageBank.Message
---@field messageId integer zero-based message id
---@field raw integer[] decrypted code units
---@field length integer

---@class UiMessageBank.Bank
---@field messageCount integer
---@field messages UiMessageBank.Message[]

---@class UiMessageBank.Failure
---@field stage string read, decode, missing_message or tokenize
---@field bank integer zero-based message member id
---@field role string?
---@field index integer?
---@field message string?
---@field code string?

-- Token record shape follows FieldMessageText.Token, the authoritative token
-- vocabulary produced by FieldMessageTokenizer.
---@class UiMessageBank.Token
---@field kind string
---@field text string?
---@field code integer?
---@field control integer?
---@field name string?
---@field args number[]?
---@field raw number[]?

---@class UiMessageBank
local UiMessageBank = {}

---@param archive Narc source archive exposing readMember
---@param bankId integer zero-based message member id
---@param role string dependency role recorded alongside the digest
---@param dependencies table<string, unknown>[] ordered producer dependency records
---@param decodeLabel string label handed to the message-bank decoder
---@return UiMessageBank.Bank? decoded bank on success, nil with a failure descriptor below
---@return UiMessageBank.Failure? failure descriptor with stage, bank, role, message and code fields
function UiMessageBank.read(archive, bankId, role, dependencies, decodeLabel)
  local bytes, err = archive:readMember(bankId)
  if not bytes then
    ---@type string?
    local code = nil
    if Errors.is(err) then
      local failure = err --[[@as Errors.Error]]
      code = failure.code
    end
    return nil, { stage = "read", bank = bankId, role = role, message = Errors.format(err), code = code }
  end
  dependencies[#dependencies + 1] = { name = "messages:member:" .. bankId, role = role, sha1 = Hashing.sha1hex(bytes) }
  local bank, bankErr = FieldMessageBank.decode(bytes, { label = decodeLabel })
  if not bank then
    assert(bankErr)
    return nil, { stage = "decode", bank = bankId, role = role, message = bankErr.message, code = bankErr.code }
  end
  return bank
end

---@param bank UiMessageBank.Bank decoded message bank
---@param bankId integer zero-based message member id
---@param index integer zero-based message id
---@param charmap { glyphs: table<integer, string> } frozen charmap reference
---@return UiMessageBank.Token[]? token stream on success, nil with a failure descriptor below
---@return UiMessageBank.Failure? failure descriptor with stage, bank, index, message and code fields
function UiMessageBank.tokens(bank, bankId, index, charmap)
  local message = bank.messages[index + 1]
  if not message then
    return nil, { stage = "missing_message", bank = bankId, index = index }
  end
  local stream, err = FieldMessageTokenizer.tokenize(message.raw, charmap, { bankId = bankId, messageId = index })
  if not stream then
    assert(err)
    return nil, { stage = "tokenize", bank = bankId, index = index, message = err.message, code = err.code }
  end
  return stream
end

return UiMessageBank
