-- Generated field-message bank publication: one compact indexed payload per
-- source bank, without a completion marker or source provenance, and the
-- runtime provider renders the same lossless control stream from it.

local Assert = require("tests.support.Assert")
local FieldMessageAsset = require("libs.assets.src.field.FieldMessageAsset")
local FieldMessageBank = require("romdump.src.digest.ui.FieldMessageBank")
local FieldMessageCache = require("libs.assets.src.field.FieldMessageCache")
local FieldMessageCacheWriter = require("romdump.src.digest.ui.FieldMessageCacheWriter")
local FieldMessageCompiler = require("romdump.src.digest.ui.FieldMessageCompiler")
local FieldMessageProvider = require("libs.hgss.src.interaction.FieldMessageProvider")
local FieldMessageText = require("libs.assets.src.field.FieldMessageText")
local PreparedArtifact = require("romdump.src.build.PreparedArtifact")
local ScriptCacheBuildFixture = require("tests.support.ScriptCacheBuildFixture")
local ResidentArtifactFixture = require("tests.support.ResidentArtifactFixture")

local T = {}

local BANK_ID = 542
local BANK_KEY = 0x4F2F
local OTHER_BANK_ID = 543

-- Message 0 exercises every lossless control family the provider must still
-- render: UTF-8 glyphs, a page break, COLOR, SIZE stretch and reset, YESNO,
-- PAUSE, the WAIT callback and a player-name substitution.
local function controlMessage()
  return {
    0x0188,
    0x0131,
    0x25BD,
    0xFFFE,
    0xFF00,
    0x0001,
    0x0001,
    0x0141,
    0xFFFE,
    0xFF01,
    0x0001,
    0x00C8,
    0x0153,
    0xFFFE,
    0xFF01,
    0x0001,
    0x0064,
    0x0131,
    0xFFFE,
    0x0200,
    0x0001,
    0x0000,
    0xFFFE,
    0x0201,
    0x0001,
    0x0001,
    0xFFFE,
    0x0202,
    0x0001,
    0x0001,
    0xFFFE,
    0x0103,
    0x0002,
    0x0000,
    0x0000,
    0xFFFF,
  }
end

-- Message 1 carries an unknown printer control so the provider fault keeps its
-- bank and message attribution.
local function unknownControlMessage()
  return { 0x0131, 0xFFFE, 0x0707, 0x0001, 0x0009, 0xFFFF }
end

local function romFs()
  local members = {
    [BANK_ID] = FieldMessageBank.encodeForTests({ controlMessage(), unknownControlMessage() }, BANK_KEY),
    [OTHER_BANK_ID] = FieldMessageBank.encodeForTests({ { 0x0131, 0xFFFF } }, 0x1142),
  }
  local reads = {}
  local result = {
    readMemberIds = reads,
    resolvedNarc = function(_, alias)
      assert(alias == "messages", "unexpected NARC alias: " .. tostring(alias))
      return { symbol = "NARC_msgdata_msg", alias = "messages", narcId = 27, fileId = 77, path = "a/0/2/7" }
    end,
    read = function(_, fileId)
      assert(fileId == 77, "unexpected ROM file id: " .. tostring(fileId))
      return "archive-bytes"
    end,
    openNarc = function(_, alias)
      assert(alias == "messages", "unexpected NARC alias: " .. tostring(alias))
      return {
        readMember = function(_, memberId)
          reads[#reads + 1] = memberId
          local member = members[memberId]
          assert(member ~= nil, "unexpected message bank " .. tostring(memberId))
          return member
        end,
      }
    end,
    metadata = function()
      return { sha1 = "rom-sha" }
    end,
    version = function()
      return "heartgold"
    end,
  }
  return result --[[@as RomFs]]
end

-- Compiler session -> per-bank stage -> publication, the production path for one
-- independent bank job.
local function publishBank()
  local source = romFs()
  local session = assert(FieldMessageCompiler.newSession(source))
  local bundle = assert(session:compileBank(BANK_ID))
  session:close()
  local cache = ScriptCacheBuildFixture.cache()
  local key = tostring(BANK_ID)
  local artifact = PreparedArtifact.new({
    cacheFs = cache,
    generationId = "outer-generation-a",
    epoch = 1,
    kind = "message-bank",
    key = key,
    jobKey = "message-bank:" .. key,
  })
  local marker = assert(FieldMessageCacheWriter.stageBank(artifact, bundle))
  artifact:finishSuccess({ marker = marker })
  assert(ResidentArtifactFixture.materialize(artifact))
  return cache, source
end

-- Every published file belonging to this bank: its payload plus any metadata
-- a bank job still writes next to it.
local function bankFiles(cache)
  local bankPath = FieldMessageCache.bankPath(BANK_ID)
  local bankDir = assert(bankPath:match("^(.*)/[^/]+$"))
  local name = FieldMessageCache.bankPath(BANK_ID):match("([^/]+)%.g4msg$")
  local files = {}
  for _, path in ipairs(ScriptCacheBuildFixture.allFiles(cache)) do
    local pathDir = path:match("^(.*)/[^/]+$")
    local pathName = ScriptCacheBuildFixture.fileName(path)
    if pathDir == bankDir and pathName:sub(1, #name) == name then
      files[#files + 1] = path
    end
  end
  table.sort(files)
  return files
end

function T.published_bank_is_one_lean_compact_file()
  local cache = publishBank()
  local bankPath = FieldMessageCache.bankPath(BANK_ID)
  local files = bankFiles(cache)
  Assert.equal(
    #files,
    1,
    "a message bank publishes exactly one file; published bank files: " .. table.concat(files, ", ")
  )
  Assert.equal(files[1], bankPath, "the one published bank file carries the bank payload")

  local bytes = assert(cache:read(bankPath), "the published bank is readable bytes")
  Assert.equal(bytes:sub(1, 4), FieldMessageAsset.MAGIC, "the published bank is the compact payload")
  local view = assert(FieldMessageAsset.open(bytes, BANK_ID))
  Assert.equal(view.schema, FieldMessageCache.SCHEMA)
  Assert.equal(view.bankId, BANK_ID)
  Assert.equal(view.messageCount, 2)
  Assert.isTrue(FieldMessageAsset.validate(bytes, BANK_ID), "the published payload is a complete compact bank")

  for messageId = 0, 1 do
    local message = assert(FieldMessageAsset.message(view, messageId), "the bank stores message " .. messageId)
    Assert.isNil((message --[[@as table<string, unknown>]]).id, "a stored message repeats no index-derived id")
    Assert.isNil((message --[[@as table<string, unknown>]]).raw, "a stored message keeps no second raw code-unit copy")
    Assert.equal(type(message.text), "string", "a selected message carries readable text")
    Assert.equal(type(message.tokens), "table", "a selected message carries its lossless token stream")
    Assert.equal(
      message.text,
      FieldMessageText.tokensToText(message.tokens),
      "the derived text stays the canonical control-marker rendering of its tokens"
    )
  end
end

function T.provider_keeps_control_semantics_from_the_compact_bank()
  local cache, source = publishBank()
  Assert.deepEqual(source.readMemberIds, { BANK_ID }, "one bank job reads no sibling bank")

  local provider = assert(FieldMessageProvider.new(cache))
  assert(provider:acquireBank(BANK_ID))
  local template = assert(provider:get(BANK_ID, 0))
  Assert.equal(template.bankId, BANK_ID)
  Assert.equal(template.messageId, 0)
  Assert.equal(type(template.text), "string", "the provider returns readable text without a font definition")
  local published = assert(cache:read(FieldMessageCache.bankPath(BANK_ID)))
  local publishedView = assert(FieldMessageAsset.open(published, BANK_ID))
  local publishedTokens = assert(FieldMessageAsset.message(publishedView, 0)).tokens
  Assert.equal(#template.tokens, #publishedTokens)
  Assert.isNil(template.raw, "the runtime template stores no second raw code-unit copy")

  local formatted = provider:format(template, {}, {})
  Assert.isTrue(formatted.hadUnresolvedSubstitutions, "the player-name substitution stays visible")
  local glyphs, kinds, controls = {}, {}, {}
  for _, token in ipairs(formatted.tokens) do
    kinds[token.kind] = true
    if token.control ~= nil then
      controls[token.control] = true
    end
    if token.kind == "glyph" then
      glyphs[#glyphs + 1] = token
    end
  end
  Assert.isTrue(kinds.glyph, "formatted text keeps its glyphs")
  Assert.isTrue(kinds.focus_indicator, "formatted text keeps yes/no focus placement")
  Assert.isTrue(kinds.substitution, "formatted text keeps the unresolved substitution")
  Assert.isTrue(kinds.pause, "formatted text keeps the pause control")
  Assert.isTrue(kinds.printer_callback, "formatted text keeps the wait callback")
  Assert.isTrue(kinds.page_break, "formatted text keeps the page break")
  Assert.isTrue(controls[FieldMessageText.COLOR], "formatted text keeps the color control")
  Assert.isTrue(controls[FieldMessageText.SIZE], "formatted text keeps the size control")

  local accented = glyphs[1]
  Assert.isTrue(#accented.text > 1, "a multi-byte UTF-8 glyph survives tokenization")
  Assert.equal(accented.colorIndex, 0, "a glyph before the color control keeps the default color")
  Assert.equal(glyphs[2].colorIndex, 0, "a glyph before the color control keeps the default color")
  Assert.equal(glyphs[3].colorIndex, 1, "a glyph after the color control carries the selected color")
  Assert.isTrue(glyphs[4].stretched, "a glyph after the stretched size control stays stretched")
  Assert.isNil(glyphs[5].stretched, "the size reset stops stretching")
  Assert.equal(glyphs[5].colorIndex, 1, "the selected color survives the size reset")

  local unknown = assert(provider:get(BANK_ID, 1))
  local ok, err = pcall(function()
    provider:format(unknown, {}, {})
  end)
  Assert.isFalse(ok, "an unknown printer control fails playback")
  err = err --[[@as { code: string, context: table }]]
  Assert.equal(err.code, FieldMessageProvider.MESSAGE_CONTROL_UNSUPPORTED)
  Assert.equal(err.context.bankId, BANK_ID, "the control fault names its bank")
  Assert.equal(err.context.messageId, 1, "the control fault names its message")
  Assert.equal(err.context.control, 0x0707, "the control fault names the offending control")
end

return { metadata = { capabilities = {} }, tests = T }
