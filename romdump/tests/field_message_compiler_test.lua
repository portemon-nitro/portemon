-- Deterministic message-bank compilation and cache readiness/rollback using a
-- synthetic encrypted bank member.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local FieldMessageBank = require("romdump.src.digest.ui.FieldMessageBank")
local FieldMessageCompiler = require("romdump.src.digest.ui.FieldMessageCompiler")
local FieldMessageCacheWriter = require("romdump.src.digest.ui.FieldMessageCacheWriter")
local FieldMessageAsset = require("libs.assets.src.field.FieldMessageAsset")
local FieldMessageText = require("libs.assets.src.field.FieldMessageText")
local FieldMessageCache = require("libs.assets.src.field.FieldMessageCache")
local FieldMessageProvider = require("libs.hgss.src.interaction.FieldMessageProvider")
local CacheFs = require("libs.storage.src.CacheFs")
local ResidentCache = require("libs.storage.src.ResidentCache")
local FakeCache = require("tests.support.FakeCache")
local LuaWriter = require("libs.codec.src.LuaWriter")
local MapCatalog = require("romdump.src.digest.map.MapCatalog")
local ScriptMembers = require("romdump.src.catalog.hgss.script_members")
local PokegearSources = require("romdump.src.config.PokegearSources")
local BattleSources = require("romdump.src.config.BattleSources")
local MenuProtocol = require("libs.assets.src.MenuProtocol")

local T = {}

local function sourceReferenceBankIds()
  local ids = {}
  for map in MapCatalog.all() do
    ids[assert(map.messageMemberId)] = true
  end
  for _, bankId in pairs(ScriptMembers.banks) do
    ids[assert(bankId)] = true
  end
  ids[MenuProtocol.STANDARD_MESSAGE_BANK] = true
  -- The in-field Start Menu labels resolve from this bank through the
  -- protocol constant; see FieldMessageCompiler's required bank set.
  ids[MenuProtocol.START_MENU_MESSAGE_BANK] = true
  -- Oak's scripted opening introduction reads directly from this bank; see
  -- FieldMessageCompiler's OAK_INTRO_MESSAGE_BANK.
  ids[219] = true
  -- The friend-name buffer command reads the opposite protagonist's name
  -- from this bank through the player gender; see FieldMessageCompiler's
  -- opposite-protagonist name bank.
  ids[445] = true
  -- The rival naming screen defaults an empty entry from this bank row; see
  -- FieldMessageCompiler's naming-screen bank.
  ids[254] = true
  ids[40] = true
  -- GetItemUseErrorMessage reads the Bag bank's bike and escort refusals.
  ids[10] = true
  ids[265] = true
  -- GetStdMsgNaix addresses these msgdata banks by immediate std index;
  -- bank 211 already rides a member association.
  ids[752] = true
  ids[30] = true
  ids[435] = true
  -- The Apricorn Box source config addresses its labels in the retail ROM's Apricorn Box message file.
  ids[21] = true
  -- The Kurt confirm header pluralizes through this bank; see
  -- FieldMessageCompiler's explicit plural bank set.
  ids[224] = true
  -- Retail blackout.c reads this global recovery message bank outside script
  -- bytecode; see FieldMessageCompiler's runtime-protocol bank set.
  ids[203] = true
  -- Per-caller phone greeting banks ride the demandable pipeline through
  -- the compiled pokegear catalog; see FieldMessageCompiler's explicit
  -- phone bank set.
  for _, bankId in ipairs(PokegearSources.phoneMessageBankIds()) do
    ids[bankId] = true
  end
  ids[PokegearSources.phoneClassLabels.specialBank] = true
  ids[PokegearSources.phoneClassLabels.trainerBank] = true
  ids[PokegearSources.phoneClassLabels.landmarkBank] = true
  ids[PokegearSources.phoneClassLabels.landmarkFallbackBank] = true
  -- The generic time-of-day phone greeting lives in bank 640 behind the
  -- source greeting table; see FieldMessageCompiler's explicit phone
  -- greeting bank set.
  ids[640] = true
  -- The compiled region map names its places from this bank.
  ids[PokegearSources.regionMapMessageBank] = true
  -- The setup card reads its CHANGE/QUIT context labels from this bank.
  ids[PokegearSources.configureMessageBank] = true
  -- Word-command text reads its code-addressed banks through the script
  -- host: the fixed-phrase pair, the raw Frontier intro bank, the plain
  -- and article-bearing trainer class banks, and the Union language bank.
  ids[202] = true
  ids[723] = true
  ids[730] = true
  ids[731] = true
  ids[738] = true
  -- Native trainer field speech resolves through the trainer message pair
  -- table, which names its message in this bank; see FieldMessageCompiler's
  -- required bank set.
  ids[BattleSources.trainerFieldMessages.messageBank] = true
  local out = {}
  for bankId in pairs(ids) do
    out[#out + 1] = bankId
  end
  table.sort(out)
  return out
end

local function fixture()
  local messages = {
    { 0x0141, 0x0153, 0x015B, 0x01AD, 0x01DE, 0xFFFF },
    {
      0x013A,
      0x0156,
      0x0153,
      0x014A,
      0x0149,
      0x0157,
      0x0157,
      0x0153,
      0x0156,
      0x01DE,
      0xFFFE,
      0x0103,
      0x0002,
      0x0000,
      0x0000,
      0xFFFF,
    },
  }
  local members = {
    [542] = FieldMessageBank.encodeForTests(messages, 0x4F2F),
    [543] = FieldMessageBank.encodeForTests({
      { 0x012F, 0x0150, 0x0151, 0x01DE, 0x0131, 0x0148, 0x01DE, 0xFFFF },
    }, 0xB447),
  }
  local function generatedMember(bankId)
    return FieldMessageBank.encodeForTests({
      { 0x012F, 0x0150, 0x0151, 0x01DE, 0xFFFF },
    }, 0x4000 + bankId)
  end
  -- Bank 191 (the standard menu-items bank) and bank 219 (Oak's opening
  -- introduction) are both required regardless of the map/script reference
  -- set; serve them the same way, one short message each with its own key.
  members[191] = FieldMessageBank.encodeForTests({
    { 0x012F, 0x0150, 0x0151, 0x01DE, 0xFFFF },
  }, 0xD191)
  members[219] = FieldMessageBank.encodeForTests({
    { 0x012F, 0x0150, 0x0151, 0x01DE, 0xFFFF },
  }, 0xD219)
  local romFs = {
    resolvedNarc = function(_, alias)
      Assert.equal(alias, "messages")
      return { symbol = "NARC_msgdata_msg", alias = "messages", narcId = 27, fileId = 77, path = "a/0/2/7" }
    end,
    read = function(_, fileId)
      Assert.equal(fileId, 77)
      return "archive-bytes"
    end,
    openNarc = function(_, alias)
      Assert.equal(alias, "messages")
      return {
        readMember = function(_, memberId)
          members[memberId] = members[memberId] or generatedMember(memberId)
          return members[memberId]
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
  ---@cast romFs RomFs
  local function sha1(bytes)
    for bankId, memberBytes in pairs(members) do
      if bytes == memberBytes then
        return string.format("member-%d-sha", bankId)
      end
    end
    return "archive-sha"
  end
  return romFs, sha1, function()
    return "dependency-sha"
  end
end

-- Publish one compiled corpus the way the per-bank jobs and the family
-- summary job do: each bank's payload through its own transaction, then the
-- family index.
local ResidentArtifactFixture = require("tests.support.ResidentArtifactFixture")

-- Publish one bank through its real stage function.
local function publishBank(cache, bundle)
  return ResidentArtifactFixture.publish(cache, "message-bank", tostring(bundle.bankId), function(artifact)
    return FieldMessageCacheWriter.stageBank(artifact, bundle)
  end)
end

local function publishBundle(cache, bundle)
  local bankMarkers = {}
  for _, bankId in ipairs(bundle.index.bankIds) do
    local marker = FieldMessageCache.marker("rom-sha", "dependency-sha-" .. tostring(bankId))
    bankMarkers[bankId] = marker
    publishBank(cache, {
      bankId = bankId,
      data = assert(bundle.banks[bankId], "the compiled corpus is missing bank " .. tostring(bankId)),
      marker = marker,
    })
  end
  return ResidentArtifactFixture.publish(cache, "message-summary", "global", function(artifact)
    return FieldMessageCacheWriter.stageSummary(artifact, bundle.index, bankMarkers)
  end)
end

-- A payload that does not open as its bank: the stage refuses it before any
-- ownership changes.
local function refusedBank(bankId, marker)
  return {
    bankId = bankId,
    data = love.data.newByteData("not a message bank payload"),
    marker = marker,
  }
end

function T.compiles_tokenized_lossless_banks()
  local romFs, sha1, hashLua = fixture()
  local bundle = assert(FieldMessageCompiler.compile(romFs, sha1, hashLua))
  Assert.deepEqual(bundle.index.bankIds, sourceReferenceBankIds())
  Assert.equal(bundle.index.schema, FieldMessageCache.INDEX_SCHEMA)

  local bank = assert(bundle.banks[542], "the compiled corpus carries bank 542")
  local view = assert(FieldMessageAsset.open(bank, 542))
  Assert.equal(view.schema, FieldMessageCache.SCHEMA)
  Assert.equal(view.bankId, 542)
  Assert.equal(view.messageCount, 2)
  -- The payload carries no source identity and no second raw copy: the
  -- dependency record owns provenance and the indexed stream owns the tokens.
  Assert.isTrue(FieldMessageAsset.validate(bank, 542), "the payload is a complete compact bank")
  local first = assert(FieldMessageAsset.message(view, 0))
  Assert.deepEqual(first.tokens[1].raw, { 0x0141 })
  Assert.equal(first.tokens[#first.tokens].kind, "eos")
  -- Display text is derived from the selected message's tokens.
  Assert.equal(first.text, "Wow, ")
  local second = assert(FieldMessageAsset.message(view, 1))
  Assert.equal(second.text, "Professor {STRVAR_1 3, 0, 0}")
  Assert.equal(second.tokens[11].kind, "substitution")
  Assert.equal(second.tokens[11].control, 0x0103)
  Assert.deepEqual(second.tokens[11].args, { 0x0000, 0x0000 })
  Assert.equal(second.tokens[#second.tokens].kind, "eos")

  Assert.equal(bundle.dependencies.messageNarc.narcId, 27)
  ---@type table<string, unknown>
  local dependencyShas = bundle.dependencies
  Assert.equal(dependencyShas.bank542MemberSha1, "member-542-sha")
  Assert.equal(dependencyShas.bank543MemberSha1, "member-543-sha")
  for _, bankId in ipairs(bundle.index.bankIds) do
    Assert.equal(bundle.dependencies["bank" .. bankId .. "MemberSha1"], "member-" .. bankId .. "-sha")
  end
  Assert.equal(bundle.marker, "field-message-cache-v5:rom-sha:dependency-sha")
end

function T.source_references_form_one_sorted_bank_set()
  Assert.equal(
    type(FieldMessageCompiler.requiredBankIds),
    "function",
    "the compiler must expose source-derived bank selection"
  )
  local required = FieldMessageCompiler.requiredBankIds()
  Assert.deepEqual(required, sourceReferenceBankIds())

  local seen = {}
  for index, bankId in ipairs(required) do
    Assert.equal(type(bankId), "number")
    Assert.isNil(seen[bankId], "a source bank must be emitted only once")
    if index > 1 then
      Assert.isTrue(required[index - 1] < bankId, "source bank IDs must be ascending")
    end
    seen[bankId] = true
  end

  local repeated = FieldMessageCompiler.requiredBankIds()
  Assert.isFalse(required == repeated, "each selection call must return a fresh array")
  Assert.deepEqual(repeated, required)
end

-- The provider consumes the installed resident view and borrows each bank's
-- bytes through the selected acquirer: install the published banks the test just
-- wrote and serve them from that view.
---@param cache CacheFs
---@param bankIds integer[]
---@return FieldMessageProvider
local function residentProvider(cache, bankIds)
  local sourceId = "base:message-provider-test"
  local store = ResidentCache.new("heartgold", sourceId)
  local entries = {}
  for _, bankId in ipairs(bankIds) do
    local path = FieldMessageCache.bankPath(bankId)
    local bytes = assert(cache:read(path), "published bank " .. tostring(bankId))
    entries[#entries + 1] = {
      path = path,
      data = assert(love.data.newByteData(bytes)),
      size = #bytes,
      sourceId = sourceId,
      contentId = "heartgold\0" .. path,
    }
  end
  store:commit(store:prepare(entries))
  local reader = CacheFs.fromStore(store)
  return assert(FieldMessageProvider.new(reader, {
    acquireSource = function(reference)
      local lease = { value = assert(reference).data }
      function lease:release()
        self.value = nil
      end
      return lease
    end,
  }))
end

function T.route_29_bank_is_published_and_served_by_the_provider()
  local route29 = MapCatalog.require("MAP_ROUTE_29")
  Assert.equal(route29.messageMemberId, 373)

  local romFs, sha1, hashLua = fixture()
  local bundle = assert(FieldMessageCompiler.compile(romFs, sha1, hashLua))
  local occurrences = 0
  for _, bankId in ipairs(bundle.index.bankIds) do
    if bankId == route29.messageMemberId then
      occurrences = occurrences + 1
    end
  end
  Assert.equal(occurrences, 1, "Route 29's message bank must be indexed exactly once")

  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  publishBundle(cache, bundle)
  local provider = residentProvider(cache, bundle.index.bankIds)
  local bank, err = provider:acquireBank(route29.messageMemberId)
  Assert.notNil(bank, err and err.message or "Route 29 message bank must be generated")
  Assert.equal(assert(bank).schema, FieldMessageCache.SCHEMA)
  Assert.equal(assert(bank).bankId, route29.messageMemberId)
  Assert.equal(provider:stats().loads, 1)
  provider:releaseBank(route29.messageMemberId)
end

function T.compilation_is_deterministic()
  local romFs, sha1, hashLua = fixture()
  local a = assert(FieldMessageCompiler.compile(romFs, sha1, hashLua))
  local b = assert(FieldMessageCompiler.compile(romFs, sha1, hashLua))
  Assert.equal(LuaWriter.encode(a.index), LuaWriter.encode(b.index))
  Assert.equal(a.banks[542]:getString(), b.banks[542]:getString())
  Assert.equal(a.marker, b.marker)
end

function T.writer_publishes_each_bank_payload_and_the_family_index()
  local romFs, sha1, hashLua = fixture()
  local bundle = assert(FieldMessageCompiler.compile(romFs, sha1, hashLua))
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  Assert.equal(
    publishBundle(cache, bundle),
    FieldMessageCacheWriter.summaryMarker(
      bundle.index,
      (function()
        local markers = {}
        for _, bankId in ipairs(bundle.index.bankIds) do
          markers[bankId] = FieldMessageCache.marker("rom-sha", "dependency-sha-" .. tostring(bankId))
        end
        return markers
      end)()
    )
  )
  Assert.isTrue(FieldMessageCache.isReady(cache))
  for _, bankId in ipairs(bundle.index.bankIds) do
    local bytes = assert(cache:read(FieldMessageCache.bankPath(bankId)))
    local view = assert(FieldMessageAsset.open(bytes, bankId))
    Assert.equal(view.bankId, bankId)
    Assert.equal(view.schema, FieldMessageCache.SCHEMA)
  end
end

function T.writer_failure_publishes_no_bank_payload()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  Assert.throws(function()
    publishBank(cache, refusedBank(542, FieldMessageCache.marker("rom-sha", "refused")))
  end)
  Assert.isNil(cache:read(FieldMessageCache.bankPath(542)), "a failed bank publishes no payload")
  Assert.isFalse(FieldMessageCache.isReady(cache), "a failed bank leaves no complete family index")
end

function T.failed_rebuild_preserves_the_previous_messages()
  local romFs, sha1, hashLua = fixture()
  local first = assert(FieldMessageCompiler.compile(romFs, sha1, hashLua))
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  publishBundle(cache, first)
  local previous = assert(cache:read(FieldMessageCache.bankPath(542)))
  local second = assert(FieldMessageCompiler.compile(romFs, sha1, hashLua))
  Assert.throws(function()
    publishBank(cache, refusedBank(542, FieldMessageCache.marker("rom-sha", "new-dep-hash")))
  end)
  Assert.isTrue(FieldMessageCache.isReady(cache), "the previous messages remain ready")
  Assert.equal(cache:read(FieldMessageCache.bankPath(542)), previous, "the previous bank payload survives")
  publishBundle(cache, second)
  Assert.isTrue(FieldMessageCache.isReady(cache), "a retry publishes the new messages")
end

-- The compiled corpus publishes compact payload bytes that the production
-- provider serves, and a failed replacement never damages the bank that is
-- already live.
function T.compact_publication_serves_dialogue_and_preserves_the_previous_bank()
  local romFs, sha1, hashLua = fixture()
  local bundle = assert(FieldMessageCompiler.compile(romFs, sha1, hashLua))
  local backend = FakeCache.new()
  local cache = CacheFs.forVersion("heartgold", backend)
  local bankPath = FieldMessageCache.bankPath(542)

  local payload = assert(bundle.banks[542])
  Assert.equal(type(payload.getString), "function", "a compiled bank is compact payload bytes")
  local view = assert(FieldMessageAsset.open(payload, 542))
  Assert.equal(view.bankId, 542)
  Assert.equal(view.messageCount, 2)

  publishBank(cache, {
    bankId = 542,
    data = payload,
    marker = FieldMessageCache.marker("rom-sha", "dependency-sha-542"),
    dependencies = bundle.dependencies,
  })
  Assert.equal(assert(cache:read(bankPath)), payload:getString(), "publication writes the encoded bytes unchanged")
  Assert.isTrue(FieldMessageCache.isBankReady(cache, 542), "the published bank reads ready")

  local provider = residentProvider(cache, { 542 })
  assert(provider:acquireBank(542))
  local glyphMessage = assert(provider:get(542, 0))
  local firstText = glyphMessage.text
  Assert.equal(firstText, FieldMessageText.tokensToText(glyphMessage.tokens))
  local substitutionMessage = assert(provider:get(542, 1))
  local substitution
  for _, token in ipairs(substitutionMessage.tokens) do
    if token.kind == "substitution" then
      substitution = token
    end
  end
  Assert.notNil(substitution, "the compiled message keeps its substitution token")
  Assert.equal(assert(substitution).control, 0x0103)
  Assert.deepEqual(assert(substitution).args, { 0, 0 })
  local fontDef = { charmap = { G = 0x0131, O = 0x013B, L = 0x0138, D = 0x012E } }
  local formatted = provider:format(substitutionMessage, {}, {
    [0x0103] = function()
      return FieldMessageProvider.asciiGlyphTokens("GOLD", fontDef)
    end,
  })
  Assert.isFalse(formatted.hadUnresolvedSubstitutions)
  Assert.isTrue(formatted.text:find("GOLD", 1, true) ~= nil, "the substitution resolves inside the served message")
  provider:releaseBank(542)

  -- Publication owns its bytes: it never reopens the payload it just wrote.
  local reads = {}
  local storedRead = backend.read
  backend.read = function(self, path)
    reads[#reads + 1] = path
    return storedRead(self, path)
  end
  publishBank(cache, {
    bankId = 543,
    data = assert(bundle.banks[543]),
    marker = FieldMessageCache.marker("rom-sha", "dependency-sha-543"),
    dependencies = bundle.dependencies,
  })
  backend.read = storedRead
  for _, path in ipairs(reads) do
    Assert.isFalse(path:find("banks/0543", 1, true) ~= nil, "publishing bank 543 must not read it back: " .. path)
  end

  -- A refused replacement must leave the previous bank live and readable.
  local previous = assert(cache:read(bankPath))
  Assert.throws(function()
    publishBank(cache, refusedBank(542, FieldMessageCache.marker("rom-sha", "replacement")))
  end)
  Assert.equal(cache:read(bankPath), previous, "a failed replacement leaves the previous bank payload intact")
  Assert.isTrue(FieldMessageCache.isBankReady(cache, 542), "the previous bank stays ready")
  assert(provider:acquireBank(542))
  Assert.equal(assert(provider:get(542, 0)).text, firstText, "the previous bank still serves its messages")
  provider:releaseBank(542)
  provider:dispose()
end

function T.unmapped_glyph_fails_compilation_with_context()
  local messages = { { 0x0001, 0xFFFF } } -- kana code outside the charmap
  local member = FieldMessageBank.encodeForTests(messages, 0x1234)
  local function validMember(bankId)
    return FieldMessageBank.encodeForTests({ { 0x012F, 0xFFFF } }, 0x5000 + bankId)
  end
  local romFs = {
    _version = "heartgold",
    _metadata = { sha1 = "rom-sha" },
    resolvedNarc = function()
      return { symbol = "NARC_msgdata_msg", alias = "messages", narcId = 27, fileId = 77, path = "a/0/2/7" }
    end,
    read = function()
      return "archive-bytes"
    end,
    openNarc = function()
      return {
        readMember = function(_, memberId)
          if memberId == 542 then
            return member
          end
          return validMember(memberId)
        end,
      }
    end,
    metadata = function()
      return { sha1 = "rom-sha" }
    end,
    version = function()
      return "heartgold"
    end,
  } --[[@as RomFs]]
  local bundle, err = FieldMessageCompiler.compile(romFs --[[@as RomFs]])
  Assert.isNil(bundle, "expected a failure result")
  Assert.isTrue(Errors.is(err))
  Assert.equal(assert(err).code, "MESSAGE_GLYPH_UNMAPPED")
  Assert.equal(assert(err).context.bankId, 542)
  Assert.equal(assert(err).context.messageId, 0)
end

-- One worker source session compiles a single selected bank: only the
-- chosen member is read and decoded, the bank record matches the aggregate
-- normalization exactly, the result never retains the whole corpus, and the
-- session closes idempotently and compiles nothing afterwards.
function T.session_compiles_a_selected_bank_without_its_siblings()
  Assert.equal(type(FieldMessageCompiler.newSession), "function", "per-bank production reuses one source session")
  local romFs, sha1, hashLua = fixture()
  local reads = {}
  local innerOpen = romFs.openNarc
  romFs.openNarc = function(_, alias)
    local archive = assert(innerOpen(romFs, alias), "the message archive opens in the test fixture")
    local innerRead = archive.readMember
    return {
      readMember = function(_, memberId)
        reads[memberId] = (reads[memberId] or 0) + 1
        return innerRead(archive, memberId)
      end,
    }
  end
  local session = assert(FieldMessageCompiler.newSession(romFs, sha1, hashLua))
  Assert.equal(type(session.compileBank), "function", "the session compiles one bank at a time")
  local one = assert(session:compileBank(542))
  Assert.equal(one.bankId, 542)
  -- A one-bank result carries no corpus; read it as an open map to prove
  -- the field is absent.
  ---@type table<string, unknown>
  local oneShape = one
  Assert.isNil(oneShape.banks, "a one-bank result must not retain the whole corpus")
  Assert.notNil(reads[542], "the selected bank is decoded")
  Assert.isNil(reads[543], "compiling one bank must not decode its siblings")
  local whole = assert(FieldMessageCompiler.compile(romFs, sha1, hashLua))
  Assert.equal(
    one.data:getString(),
    whole.banks[542]:getString(),
    "the one-bank payload matches the aggregate normalization"
  )
  session:close()
  session:close()
  Assert.isNil(session:compileBank(542), "a closed session compiles nothing")
end

-- A malformed bank fails alone with its bank/message context while valid
-- banks from the same session stay usable: one bad member never poisons the
-- session and never stands in as an empty success.
function T.malformed_bank_fails_alone_without_poisoning_the_session()
  Assert.equal(type(FieldMessageCompiler.newSession), "function", "per-bank production reuses one source session")
  local valid = FieldMessageBank.encodeForTests({ { 0x012F, 0xFFFF } }, 0x1700)
  local malformed = FieldMessageBank.encodeForTests({ { 0x0001, 0xFFFF } }, 0x1701)
  local romFs = {
    resolvedNarc = function()
      return { symbol = "NARC_msgdata_msg", alias = "messages", narcId = 27, fileId = 77, path = "a/0/2/7" }
    end,
    read = function()
      return "archive-bytes"
    end,
    openNarc = function()
      return {
        readMember = function(_, memberId)
          if memberId == 700 then
            return valid
          end
          if memberId == 701 then
            return malformed
          end
          error("unexpected bank " .. tostring(memberId))
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
  ---@cast romFs RomFs
  local session = assert(FieldMessageCompiler.newSession(romFs --[[@as RomFs]]))
  local first = assert(session:compileBank(700))
  Assert.equal(first.bankId, 700)
  local missing, err = session:compileBank(701)
  Assert.isNil(missing, "a malformed bank must not produce a bank record")
  err = assert(err, "a malformed bank must report its structured failure")
  Assert.isTrue(Errors.is(err))
  Assert.equal(err.code, "MESSAGE_GLYPH_UNMAPPED")
  Assert.equal(err.context.bankId, 701)
  Assert.equal(err.context.messageId, 0)
  local second = assert(session:compileBank(700), "the session keeps serving valid banks after a failure")
  Assert.equal(second.data:getString(), first.data:getString())
  session:close()
end

-- Bank keys are validated at the session boundary: a malformed key is a
-- programming fault, never a structured source failure, and rejecting it
-- never poisons the session for valid banks.
function T.bank_keys_are_validated_at_the_session_boundary()
  local romFs = fixture()
  local session = assert(FieldMessageCompiler.newSession(romFs))
  for _, badKey in ipairs({ -1, 1.5, "542" }) do
    Assert.throws(function()
      session:compileBank(badKey)
    end)
  end
  local valid = assert(session:compileBank(542), "rejected keys never poison the session")
  Assert.equal(valid.bankId, 542)
  session:close()
end

return { tests = T }
