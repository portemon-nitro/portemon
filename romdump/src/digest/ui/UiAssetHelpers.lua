-- Shared front-end for the UI asset compilers: archive member reads with
-- optional LZ10 decompression, G2D decode, screen rasterization, message
-- bank reads, single-message tokenization, and the guarded compile entry.
-- Bag, party, and summary compilers keep their own error codes, label
-- words, and lowering; only the identical mechanical plumbing lives here.
-- Every label is an explicit parameter so generated provenance never
-- changes behind a caller. Pure module: no love dependency.

local Errors = require("libs.errors.src.Errors")
local Hashing = require("romdump.src.digest.Hashing")
local Lz10 = require("romdump.src.digest.Lz10")
local G2dDecoder = require("romdump.src.digest.ui.G2dDecoder")
local G2dRasterizer = require("romdump.src.digest.ui.G2dRasterizer")
local UiMessageBank = require("romdump.src.digest.ui.UiMessageBank")
local charmap = require("romdump.src.catalog.hgss.charmap")

---@class UiAssetHelpers
local UiAssetHelpers = {}

-- Reads one archive member, records its provenance dependency, and
-- transparently decompresses LZ10-framed members. Raises through the
-- compiler's source error on unreadable members.
---@param archive Narc source archive exposing readMember
---@param memberId integer member under read
---@param role string dependency role recorded alongside the digest
---@param dependencies table<string, unknown>[] ordered producer dependency records
---@param archiveLabel string provenance namespace recorded before the member id
---@param sourceError fun(message: string, context: table<string, unknown>?) compiler-specific source failure
---@return string member bytes, decompressed when LZ10-framed
function UiAssetHelpers.readMember(archive, memberId, role, dependencies, archiveLabel, sourceError)
  local member, err = archive:readMember(memberId)
  if not member then
    sourceError("member " .. memberId .. " is unreadable: " .. Errors.format(err), { role = role, memberId = memberId })
  end
  assert(member ~= nil, "unreadable members fail above")
  dependencies[#dependencies + 1] =
    { name = archiveLabel .. ":member:" .. memberId, role = role, sha1 = Hashing.sha1hex(member) }
  if string.byte(member, 1) == 0x10 then
    local plain, lzErr = Lz10.decode(member)
    if not plain then
      error(lzErr, 0)
    end
    member = plain
  end
  return member
end

-- Decodes one G2D record under the compiler's label namespace. Raises
-- through the compiler's source error on undecodable members.
---@param kind string G2D decoder entry under use
---@param bytes string member bytes under decode
---@param role string dependency role recorded alongside the digest
---@param kindWord string compiler label word namespacing the decode label
---@param sourceError fun(message: string, context: table<string, unknown>?) compiler-specific source failure
---@return table<string, unknown> decoded record
function UiAssetHelpers.decode(kind, bytes, role, kindWord, sourceError)
  local record, err = G2dDecoder[kind](bytes, { label = kindWord .. ":" .. role })
  if not record then
    assert(err)
    sourceError(role .. " does not decode: " .. err.message, { role = role, cause = err.code })
  end
  return record
end

-- Renders one decoded screen with native entry palette indices. Raises
-- through the compiler's source error on unrasterizable screens.
---@param charData string raw character bytes
---@param palette table<string, unknown> raw palette colors
---@param screen table<string, unknown> decoded screen record
---@param role string dependency role recorded alongside failures
---@param sourceError fun(message: string, context: table<string, unknown>?) compiler-specific source failure
---@return { width: integer, height: integer, pixels: string } rendered image
function UiAssetHelpers.rasterizeScreen(charData, palette, screen, role, sourceError)
  local ok, image = pcall(G2dRasterizer.renderScreen, charData, { colors = palette }, screen, { role = role })
  if not ok then
    if Errors.is(image) then
      ---@cast image Errors.Error
      sourceError(role .. " does not rasterize: " .. image.message, { role = role, cause = image.code })
    end
    error(image, 0)
  end
  return image
end

-- Reads one UI message bank under the compiler's bank namespace. Raises
-- through the compiler's source error on unreadable banks.
---@param archive Narc source archive exposing readMember
---@param bankId integer zero-based message bank member id
---@param role string dependency role recorded alongside the digest
---@param dependencies table<string, unknown>[] ordered producer dependency records
---@param kindWord string compiler label word namespacing the bank label
---@param sourceError fun(message: string, context: table<string, unknown>?) compiler-specific source failure
---@return UiMessageBank.Bank decoded message bank
function UiAssetHelpers.readMessageBank(archive, bankId, role, dependencies, kindWord, sourceError)
  local bank, failure = UiMessageBank.read(archive, bankId, role, dependencies, kindWord .. "-message-bank-" .. bankId)
  if not bank then
    assert(failure)
    if failure.stage == "read" then
      sourceError("message bank " .. bankId .. " is unreadable: " .. failure.message, { role = role, bank = bankId })
    else
      sourceError("message bank " .. bankId .. " does not decode: " .. failure.message, {
        role = role,
        bank = bankId,
        cause = failure.code,
      })
    end
  end
  assert(bank ~= nil, "unreadable message banks fail above")
  return bank
end

-- Tokenizes one bank message. Raises through the compiler's source error
-- on missing or untokenizable messages.
---@param bank UiMessageBank.Bank decoded message bank
---@param bankId integer zero-based message bank member id
---@param index integer zero-based message index
---@param role string dependency role recorded alongside the digest
---@param kindWord string compiler label word for tokenize diagnostics
---@param sourceError fun(message: string, context: table<string, unknown>?) compiler-specific source failure
---@return UiMessageBank.Token[] token stream
function UiAssetHelpers.messageTokens(bank, bankId, index, role, kindWord, sourceError)
  local tokens, failure = UiMessageBank.tokens(bank, bankId, index, charmap)
  if not tokens then
    assert(failure)
    if failure.stage == "missing_message" then
      sourceError(
        "message bank " .. bankId .. " carries no message " .. index,
        { role = role, bank = bankId, index = index }
      )
    else
      sourceError(
        kindWord .. " message does not tokenize: " .. failure.message,
        { role = role, bank = bankId, index = index }
      )
    end
  end
  assert(tokens ~= nil, "untokenizable " .. kindWord .. " messages fail above")
  return tokens
end

-- Runs one compiler entry behind the shared failure boundary: structured
-- source errors report nil plus the error, while unexpected Lua failures
-- keep their traceback and raise.
---@param compileFn fun(romFs: RomFs): table<string, unknown>?, Errors.Error? compiler body under guard
---@param romFs RomFs RomFs-shaped object under compile
---@return table<string, unknown>? compiled bundle, nil with a structured source error below
---@return Errors.Error? structured source error when the compile reports one
function UiAssetHelpers.compileWithGuard(compileFn, romFs)
  local ok, result = xpcall(compileFn, function(e)
    if Errors.is(e) then
      return e
    end
    return { raw = e, trace = debug.traceback("", 2) }
  end, romFs)
  if ok then
    return result
  end
  if Errors.is(result) then
    return nil, result --[[@as Errors.Error]]
  end
  if type(result) == "table" and result.trace then
    error(result.raw, 0)
  end
  error(result, 0)
end

return UiAssetHelpers
