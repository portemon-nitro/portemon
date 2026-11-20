-- Test-only construction of compact field-message banks. Inputs are normalized
-- token streams (the producer's own tokenizer output shape, minus the stored
-- display text); the bytes come from the production encoder, so a fixture can
-- never invent a representation the runtime cannot read.

local FieldMessageAsset = require("libs.assets.src.field.FieldMessageAsset")
local FieldMessageCache = require("libs.assets.src.field.FieldMessageCache")
local FieldMessageText = require("libs.assets.src.field.FieldMessageText")

local FieldMessageFixture = {}

-- One bank in the producer's input shape: `messages` is a 1..n array whose
-- position is the zero-based message ID, matching the producer's iteration.
---@param bankId integer
---@param messages FieldMessageText.Token[][]
---@return table
function FieldMessageFixture.bank(bankId, messages)
  local bank = { bankId = bankId, messageCount = #messages, messages = {} }
  for index, tokens in ipairs(messages) do
    bank.messages[index - 1] = { tokens = tokens }
  end
  return bank
end

-- Encodes one bank into rooted compact bytes. The returned Data owns the
-- backing allocation, so a fixture may drop the token graph afterwards.
---@param bank table
---@return love.Data
function FieldMessageFixture.encode(bank)
  local size = FieldMessageAsset.encodedSize(bank)
  local data = love.data.newByteData(size)
  local written = FieldMessageAsset.encodeInto(bank, data:getFFIPointer(), size)
  assert(written == size, "compact encoding wrote " .. tostring(written) .. " of " .. tostring(size) .. " bytes")
  return data
end

-- Writes one bank to the cache at its current logical path, exactly as the
-- producer publishes it, and returns the rooted bytes.
---@param cache CacheFs
---@param bankId integer
---@param messages FieldMessageText.Token[][]
---@return love.Data
function FieldMessageFixture.write(cache, bankId, messages)
  local data = FieldMessageFixture.encode(FieldMessageFixture.bank(bankId, messages))
  cache:write(FieldMessageCache.bankPath(bankId), data)
  return data
end

-- The token spellings the producer's tokenizer emits. Ordinary tokens leave
-- their canonical `raw` array to the encoder; only the opaque single-word
-- control and the packed trainer name carry one, because those carry the
-- information the encoder cannot derive.
---@param code integer
---@param text string
---@return FieldMessageText.Token
function FieldMessageFixture.glyph(code, text)
  return { kind = "glyph", code = code, text = text }
end

---@return FieldMessageText.Token
function FieldMessageFixture.eos()
  return { kind = "eos" }
end

---@return FieldMessageText.Token
function FieldMessageFixture.lineBreak()
  return { kind = "line_break" }
end

---@return FieldMessageText.Token
function FieldMessageFixture.promptBreak()
  return { kind = "prompt_break" }
end

---@return FieldMessageText.Token
function FieldMessageFixture.pageBreak()
  return { kind = "page_break" }
end

-- An extended control: framing, kind, and canonical name all follow the
-- control code, exactly as the tokenizer classifies it.
---@param control integer
---@param args integer[]|nil
---@return FieldMessageText.Token
function FieldMessageFixture.control(control, args)
  return { kind = FieldMessageText.controlKind(control), control = control, args = args or {} }
end

-- A control the tokenizer could not frame as an extended control: one opaque
-- word, distinguished by its single-word raw array.
---@param control integer
---@return FieldMessageText.Token
function FieldMessageFixture.opaqueControl(control)
  return { kind = "unsupported_control", control = control, args = {}, raw = { control } }
end

-- A trainer-name substitution: its packed source words are diagnostics only,
-- so they survive verbatim.
---@param packedWords integer[]
---@return FieldMessageText.Token
function FieldMessageFixture.trainerName(packedWords)
  local raw = { FieldMessageText.TRNAME }
  for _, word in ipairs(packedWords) do
    raw[#raw + 1] = word
  end
  return { kind = "substitution", control = FieldMessageText.TRNAME, name = "TRNAME", args = {}, raw = raw }
end

return FieldMessageFixture
