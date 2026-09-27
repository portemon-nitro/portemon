-- The derived-cache job vocabulary is one closed literal set shared by the
-- generation session, the compiler workers, and the common batch client. A
-- kind outside the set is rejected at the validation boundary; there is no
-- runtime registration surface that could let producers diverge.

local Assert = require("tests.support.Assert")
local ArtifactJobs = require("romdump.src.build.ArtifactJobs")
local ArtifactState = require("romdump.src.build.ArtifactState")
local AudioCompiler = require("romdump.src.digest.audio.AudioCompiler")
local AudioCacheWriter = require("romdump.src.digest.audio.AudioCacheWriter")
local Hashing = require("romdump.src.digest.Hashing")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local MenuProtocol = require("libs.assets.src.MenuProtocol")
local SdatFixture = require("tests.support.SdatFixture")
local SseqFixture = require("tests.support.SseqFixture")
local SbnkFixture = require("tests.support.SbnkFixture")
local SwarFixture = require("tests.support.SwarFixture")

local T = {}

-- Canonical selectors keyed exactly as the worker channel addresses each
-- family. Coarse families and summaries use the global key; paged and
-- per-member families use their canonical selectors.
local CANONICAL_KEYS = {
  ["world-catalog"] = "global",
  ["field-cell-index"] = "global",
  ["field-camera"] = "global",
  ["field-weather"] = "global",
  ["field-effects"] = "global",
  ["field-emotes"] = "global",
  ["field-ui"] = "global",
  ["field-font"] = "global",
  ["intro"] = "global",
  ["new-game-init"] = "global",
  ["actors"] = "global",
  ["starter-choice"] = "global",
  ["items"] = "global",
  ["bag"] = "global",
  ["mon-catalog"] = "global",
  ["mon-layout"] = "global",
  ["mon-icon-page"] = "3",
  ["mon-portrait-page"] = "12",
  ["mon-summary"] = "global",
  ["message-bank"] = "219",
  ["message-summary"] = "global",
  ["audio-bank"] = "7",
  ["audio-catalog"] = "global",
  ["audio-summary"] = "global",
  ["script-member"] = "149",
  ["script-summary"] = "global",
  ["map-data"] = "7",
  ["field-cell"] = "12-5",
  ["map"] = "7",
}

function T.every_family_key_shape_resolves_to_a_receipt_path()
  for kind, key in pairs(CANONICAL_KEYS) do
    local path = assert(ArtifactState.path(kind, key))
    Assert.equal(path, "data/generated/jobs/" .. kind .. "/" .. key .. ".lua")
  end
end

function T.unknown_kinds_are_rejected_before_planning()
  for _, kind in ipairs({ "world", "field-map-data", "portrait", "maps", "", "MAP" }) do
    local ok = pcall(ArtifactState.path, kind, "global")
    Assert.isFalse(ok, "kind must be rejected: " .. tostring(kind))
  end
end

function T.malformed_keys_are_rejected_for_their_kind()
  local cases = {
    { kind = "map", key = "" },
    { kind = "map", key = "1-2" },
    { kind = "map", key = "seven" },
    { kind = "field-cell", key = "12" },
    { kind = "field-cell", key = "abc" },
    { kind = "field-cell", key = "1-2-3" },
    { kind = "mon-icon-page", key = "3-4" },
    { kind = "message-bank", key = "bank" },
    { kind = "script-member", key = "-1" },
    { kind = "audio-bank", key = "01" },
  }
  for _, case in ipairs(cases) do
    local ok = pcall(ArtifactState.path, case.kind, case.key)
    Assert.isFalse(ok, "key must be rejected: " .. case.kind .. "/" .. tostring(case.key))
  end
end

function T.vocabulary_has_no_runtime_registration_surface()
  -- Both the accepted vocabulary and the job dispatcher are closed by
  -- construction; read them as open maps to prove no registration
  -- surface exists.
  ---@type table<string, unknown>
  local vocabulary = ArtifactState
  Assert.isNil(vocabulary.register)
  Assert.isNil(vocabulary.extend)
  Assert.isNil(vocabulary.addKind)
  ---@type table<string, unknown>
  local dispatcher = ArtifactJobs
  Assert.isNil(dispatcher.register)
  Assert.isNil(dispatcher.extend)
  Assert.isNil(dispatcher.addKind)
end

-- Unknown dynamic membership is incomplete, never an empty final list;
-- known-empty lists are complete. Callers may record and wake from
-- incomplete edges but never dispatch a parent from them.
function T.dependencies_report_completeness_for_unknown_and_known_empty_membership()
  local mapOk, mapDeps, mapComplete = pcall(ArtifactJobs.dependencies, "map", "7", {})
  Assert.isTrue(mapOk, "unknown map membership reports instead of raising")
  Assert.isFalse(mapComplete, "unknown map membership is incomplete")
  Assert.isTrue(type(mapDeps) == "table", "incomplete planning still reports its known edges")
  local mapSet = {}
  for _, dep in ipairs(assert(mapDeps, "incomplete planning reports known edges")) do
    mapSet[dep.kind .. ":" .. dep.key] = true
  end
  Assert.isTrue(mapSet["world-catalog:global"] == true, "incomplete map planning keeps its catalog edge")
  Assert.isTrue(mapSet["field-cell-index:global"] == true, "incomplete map planning keeps its index edge")

  local summaryDeps, summaryComplete =
    ArtifactJobs.dependencies("mon-summary", "global", { iconPageIds = {}, portraitPageIds = {} })
  Assert.isTrue(summaryComplete, "known-empty page membership is complete")
  local summarySet = {}
  for _, dep in ipairs(assert(summaryDeps, "complete planning reports its edges")) do
    summarySet[dep.kind .. ":" .. dep.key] = true
  end
  Assert.isTrue(summarySet["mon-catalog:global"] == true, "the complete summary keeps its catalog edge")
  Assert.isTrue(summarySet["mon-layout:global"] == true, "the complete summary keeps its layout edge")

  local messageDeps, messageComplete = ArtifactJobs.dependencies("message-summary", "global", { messageBankIds = {} })
  Assert.isTrue(messageComplete, "a known-empty bank closure is complete")
  Assert.deepEqual(messageDeps, {}, "a known-empty closure carries no child edges")

  local scriptOk, _, scriptComplete = pcall(ArtifactJobs.dependencies, "script-summary", "global", {})
  Assert.isTrue(scriptOk, "unknown script membership reports instead of raising")
  Assert.isFalse(scriptComplete, "unknown script membership is incomplete")

  local audioOk, _, audioComplete = pcall(ArtifactJobs.dependencies, "audio-summary", "global", {})
  Assert.isTrue(audioOk, "unknown audio membership reports instead of raising")
  Assert.isFalse(audioComplete, "unknown audio membership is incomplete")
end

-- The audio catalog is a heavy closed job: it plans the normalized index
-- without compiling banks and stages only the runtime index plus its
-- catalog completion.
function T.audio_catalog_maps_to_the_heavy_lane()
  Assert.equal(ArtifactJobs.sizeClass("audio-catalog"), "heavy")
  local path = assert(ArtifactState.path("audio-catalog", "global"))
  Assert.equal(path, "data/generated/jobs/audio-catalog/global.lua")
end

local function oakAudioPlan()
  return {
    index = {
      sequences = {
        [2] = { id = 2, bankId = 10 },
        [100] = { id = 100, symbol = "SEQ_GS_STARTING", bankId = 20 },
        [101] = { id = 101, symbol = "SEQ_GS_STARTING2", bankId = 20 },
        [102] = { id = 102, symbol = "SEQ_SE_DP_BOWA2", bankId = 30 },
        [103] = { id = 103, symbol = "SEQ_SE_DP_SELECT", bankId = 30 },
        [104] = { id = 104, symbol = "SEQ_SE_GS_HERO_SHUKUSHOU", bankId = 40 },
      },
      sequenceBySymbol = {
        SEQ_GS_STARTING = 100,
        SEQ_GS_STARTING2 = 101,
        SEQ_SE_DP_BOWA2 = 102,
        SEQ_SE_DP_SELECT = 103,
        SEQ_SE_GS_HERO_SHUKUSHOU = 104,
      },
    },
  }
end

-- Final New Game intro membership is exactly the static Oak closure plus
-- the deduplicated audio-bank closures behind the six semantic sequence
-- references and the direct Marill cry bank: unrelated banks, the full
-- audio summary, and field geometry never join.
function T.new_game_intro_membership_resolves_only_exact_oak_audio_closures()
  local jobs, complete = ArtifactJobs.newGameIntroJobs(oakAudioPlan())
  Assert.isTrue(complete, "resolved audio membership is final")
  local set = {}
  for _, job in ipairs(jobs) do
    local key = job.kind .. ":" .. job.key
    Assert.isNil(set[key], "intro membership carries no duplicate: " .. key)
    set[key] = true
  end
  for _, expected in ipairs({
    "source-plan:global",
    "field-ui:global",
    "field-font:global",
    "intro:global",
    "new-game-init:global",
    "mon-catalog:global",
    "items:global",
    "message-bank:219",
    "audio-catalog:global",
    "audio-bank:10",
    "audio-bank:20",
    "audio-bank:30",
    "audio-bank:40",
    "audio-bank:184",
  }) do
    Assert.isTrue(set[expected] == true, "intro membership carries " .. expected)
  end
  Assert.isNil(set["audio-bank:999"], "unrelated banks stay out of the intro closure")
  Assert.isNil(set["audio-summary:global"], "the full audio summary stays out of the intro closure")
  Assert.isNil(set["actors:global"], "field actors stay out of the intro closure")
end

-- Without source audio membership the roster stays unresolved: static
-- members plus the source-plan owner, never final.
function T.new_game_intro_without_source_audio_is_unresolved()
  local jobs, complete = ArtifactJobs.newGameIntroJobs(nil)
  Assert.isFalse(complete, "unresolved audio membership is unresolved")
  local set = {}
  for _, job in ipairs(jobs) do
    set[job.kind .. ":" .. job.key] = true
  end
  Assert.isTrue(set["source-plan:global"] == true, "the unresolved roster keeps its source owner")
  Assert.isTrue(set["audio-catalog:global"] == true, "the unresolved roster keeps the catalog")
  Assert.isNil(set["audio-bank:184"], "no bank closure is final before source adoption")
end

-- The complete inventory enumerates incrementally through one canonical
-- iterator: draining it covers exactly the materialized list, each job
-- exactly once, under canonical identity. The interactive session consumes
-- the same iterator a bounded chunk at a time instead of materializing
-- the whole corpus in one update.
local function sweepPlans()
  local matrices = {}
  for matrixMemberId = 1, 3 do
    local cells = {}
    for index = 0, 9 do
      cells[#cells + 1] = { matrixMemberId = matrixMemberId, index = index }
    end
    matrices[#matrices + 1] = { matrixMemberId = matrixMemberId, cells = cells }
  end
  return {
    messageBankIds = { 1, 219 },
    audioBankIds = { 3, 7 },
    scriptMemberIds = { 5, 149 },
    iconPageIds = { 0, 1 },
    portraitPageIds = { 0 },
    mapDataIds = { 2, 4 },
    indexBundle = { index = { matrices = matrices }, indexMarker = "sweep-index-marker" },
    mapIds = { 7, 9 },
  }
end

function T.complete_inventory_drains_the_incremental_enumerator()
  local plans = sweepPlans()
  local expected = ArtifactJobs.completeJobs(plans)
  Assert.isTrue(#expected > 40, "the sweep fixture spans dozens of jobs")
  local iterate = ArtifactJobs.completeIterator(plans)
  Assert.isTrue(type(iterate) == "function", "the producer inventory enumerates incrementally")
  local seen = {}
  local count = 0
  while true do
    local job = iterate()
    if job == nil then
      break
    end
    count = count + 1
    Assert.isNil(seen[job.jobKey], "the enumerator visits each job once: " .. tostring(job.jobKey))
    seen[job.jobKey] = true
    Assert.equal(job.jobKey, job.kind .. ":" .. job.key, "enumerated identities stay canonical")
  end
  Assert.equal(count, #expected, "the enumerator covers the complete inventory")
  for _, job in ipairs(expected) do
    Assert.isTrue(seen[job.jobKey] == true, "the enumerator visits " .. job.jobKey)
  end
end

-- A published message bank validates warm through the worker-facing
-- wrapper without a source reader: the authoritative family rule decides
-- reuse, and a missing bank validates cold. No ROM handle is opened.
local function publishWarmBank(cacheFs, generation, bankId)
  local FieldMessageCache = require("libs.assets.src.field.FieldMessageCache")
  local marker = "worker-warm-marker-" .. tostring(bankId)
  cacheFs:writeLua(ArtifactState.path("message-bank", tostring(bankId)), {
    schema = ArtifactState.RECEIPT_SCHEMA,
    generationId = generation,
    kind = "message-bank",
    key = tostring(bankId),
    marker = marker,
  })
  cacheFs:write(FieldMessageCache.bankMarkerPath(bankId), marker)
  cacheFs:writeLua(FieldMessageCache.bankPath(bankId), {
    schema = FieldMessageCache.SCHEMA,
    bankId = bankId,
  })
end

function T.worker_validation_reuses_published_families_without_source()
  local producerId = "d" .. string.rep("3", 64)
  local generation = "worker-validation-generation"
  local cacheFs = CacheFs.forVersion("heartgold", FakeCache.new())
  publishWarmBank(cacheFs, generation, 219)
  local context = { cacheFs = cacheFs, versionId = "heartgold" }
  local warm = {
    kind = "message-bank",
    key = "219",
    generationId = generation,
    producerFingerprint = producerId,
  }
  Assert.isTrue(ArtifactJobs.validateCurrent(warm, context) == true, "a published bank validates warm without source")
  Assert.isNil(context.romFs, "warm validation opens no source reader")
  local cold = {
    kind = "message-bank",
    key = "220",
    generationId = generation,
    producerFingerprint = producerId,
  }
  Assert.isFalse(ArtifactJobs.validateCurrent(cold, context), "a missing bank validates cold")
end

-- The worker-local source-plan memo reads the published inventory once
-- per worker generation: two lookups share one read, an identity change
-- re-reads, and a mismatched identity is rejected without poisoning
-- the memo.
local function warmSourceCache(generation, producerId)
  local SourcePlan = require("romdump.src.build.SourcePlan")
  local cacheFs = CacheFs.forVersion("heartgold", FakeCache.new())
  cacheFs:writeLua(SourcePlan.PATH, {
    schema = SourcePlan.SCHEMA,
    versionId = "heartgold",
    romSha1 = string.rep("b", 40),
    generationId = generation,
    producerId = producerId,
    world = { maps = { { id = 7 } }, analysis = { excluded = {} } },
    fieldCellIndexBundle = { index = { matrices = {} }, indexMarker = "memo-index-marker" },
    scriptPlan = { members = { { memberId = 1 } }, generationKey = "memo-script-generation" },
    audioPlan = { index = { version = "heartgold" }, bankPlans = {} },
    audioIdentity = { romSha1 = string.rep("b", 40), sdatSha1 = string.rep("e", 40), sdatFileId = 11 },
    mapCellKeys = { [7] = {} },
  })
  return cacheFs
end

function T.worker_source_plan_memo_reads_once_per_generation()
  local SourcePlan = require("romdump.src.build.SourcePlan")
  local producerId = "d" .. string.rep("3", 64)
  local generation = "memo-generation"
  local cacheFs = warmSourceCache(generation, producerId)
  local reads = 0
  local realRead = SourcePlan.read
  SourcePlan.read = function(cache, identity)
    reads = reads + 1
    return realRead(cache, identity)
  end
  local ok, failure = pcall(function()
    local context = { cacheFs = cacheFs, versionId = "heartgold" }
    local identity = { versionId = "heartgold", generationId = generation, producerId = producerId }
    local first = assert(ArtifactJobs.sourcePlanForContext(context, identity))
    local second = assert(ArtifactJobs.sourcePlanForContext(context, identity))
    Assert.isTrue(first == second, "the same generation memoizes its record")
    Assert.equal(reads, 1, "two source-plan-dependent lookups read once")
    local stale = { versionId = "heartgold", generationId = generation, producerId = "d" .. string.rep("9", 64) }
    local rejected, reason = ArtifactJobs.sourcePlanForContext(context, stale)
    Assert.isNil(rejected, "a mismatched producer identity is rejected")
    Assert.notNil(reason, "the rejection names its cause")
    local rotatedGeneration = "memo-generation-next"
    local rotatedCache = warmSourceCache(rotatedGeneration, producerId)
    context.cacheFs = rotatedCache
    local rotated = { versionId = "heartgold", generationId = rotatedGeneration, producerId = producerId }
    Assert.notNil(ArtifactJobs.sourcePlanForContext(context, rotated), "a replaced generation reads its own record")
    Assert.equal(reads, 3, "identity changes re-read through the validating reader")
  end)
  SourcePlan.read = realRead
  if not ok then
    error(failure, 0)
  end
end

-- A missing Oak audio reference fails loudly naming the semantic
-- reference instead of silently omitting its bank.
function T.new_game_intro_names_its_missing_audio_reference()
  local plan = oakAudioPlan()
  plan.index.sequenceBySymbol.SEQ_SE_DP_SELECT = nil
  local ok, err = pcall(ArtifactJobs.newGameIntroJobs, plan)
  Assert.isFalse(ok, "a missing Oak sequence reference fails membership")
  Assert.isTrue(
    tostring(err):find("SEQ_SE_DP_SELECT", 1, true) ~= nil,
    "the failure names the missing semantic reference: " .. tostring(err)
  )
end

-- A one-bank synthetic archive with real decodable payloads: one used
-- sequence on bank zero backed by one wave archive member.
local function leafSourceBytes()
  local spec = {
    sequences = { [0] = { bankId = 0, volume = 120, channelPriority = 127, playerPriority = 64, playerId = 0 } },
    banks = { [0] = { waveArchives = { 0, 0xFFFF, 0xFFFF, 0xFFFF } } },
    waveArchives = { [0] = {} },
    players = { [0] = { maxSequences = 2, channelMask = 0xC000, heapSize = 0x5E88 } },
    extraFiles = 0,
  }
  local _, layout = SdatFixture.build(spec)
  spec.payloads = {
    [layout.fileIds.sequences[0]] = SseqFixture.build({ { op = "fin" } }),
    [layout.fileIds.banks[0]] = SbnkFixture.build({
      {
        type = 1,
        param = {
          swav = 0,
          swarSlot = 0,
          rootKey = 60,
          attack = 120,
          decay = 60,
          sustain = 80,
          release = 100,
          pan = 64,
        },
      },
    }),
    [layout.fileIds.waveArchives[0]] = SwarFixture.build({
      SwarFixture.pcm8({ -128, -64, 0, 64, 127, -1, 1, 2 }, { sampleRate = 16000 }),
    }),
  }
  return SdatFixture.build(spec)
end

local function leafRomFs(bytes)
  return {
    readSourcePath = function(_, path)
      Assert.equal(path, "data/sound/gs_sound_data.sdat")
      return bytes
    end,
    metadata = function()
      return { sha1 = string.rep("c", 40) }
    end,
    version = function()
      return "heartgold"
    end,
    fileIdForPath = function(_, _)
      return 7
    end,
  }
end

-- Leaf audio jobs consume the published generation source plan instead of
-- re-planning the archive: bank, catalog, and summary executions all route
-- through the worker source-plan memo while the standalone planners stay
-- silent, and an unknown bank fails with its own identity.
function T.audio_leaf_jobs_consume_the_published_generation_plan()
  local SourcePlan = require("romdump.src.build.SourcePlan")
  local bytes = leafSourceBytes()
  local romFs = leafRomFs(bytes)
  local catalog = assert(AudioCompiler.plan(romFs))
  local generation = "leaf-generation"
  local producerId = "d" .. string.rep("3", 64)
  local identity = { romSha1 = string.rep("c", 40), sdatSha1 = Hashing.sha1hex(bytes), sdatFileId = 7 }
  local cacheFs = CacheFs.forVersion("heartgold", FakeCache.new())
  cacheFs:writeLua(SourcePlan.PATH, {
    schema = SourcePlan.SCHEMA,
    versionId = "heartgold",
    romSha1 = string.rep("c", 40),
    generationId = generation,
    producerId = producerId,
    world = { maps = { { id = 7 } }, analysis = { excluded = {} } },
    fieldCellIndexBundle = { index = { matrices = {} }, indexMarker = "leaf-index-marker" },
    scriptPlan = { members = {}, generationKey = "leaf-script-generation" },
    audioPlan = { index = catalog.index, bankPlans = catalog.bankPlans },
    audioIdentity = identity,
    mapCellKeys = { [7] = {} },
  })
  for _, bankPlan in ipairs(catalog.bankPlans) do
    Assert.notNil(AudioCacheWriter.writeBank(cacheFs, romFs, bankPlan), "the live cache stages the planned bank")
  end
  Assert.notNil(AudioCacheWriter.writeCatalog(cacheFs, catalog, identity), "the live cache stages the planned catalog")
  local planCalls, identityCalls = 0, 0
  local realPlan, realSoundIdentity = AudioCompiler.plan, AudioCompiler.soundIdentity
  AudioCompiler.plan = function(source)
    planCalls = planCalls + 1
    return realPlan(source)
  end
  AudioCompiler.soundIdentity = function(source)
    identityCalls = identityCalls + 1
    return realSoundIdentity(source)
  end
  local ok, failure = pcall(function()
    local context = { cacheFs = cacheFs, romFs = romFs, versionId = "heartgold" }
    local function execute(kind, key, stageName)
      return ArtifactJobs.execute({
        kind = kind,
        key = key,
        generationId = generation,
        producerFingerprint = producerId,
        stageName = stageName,
        epoch = 1,
      }, context)
    end
    local bank = execute("audio-bank", "0", "leaf-bank-stage")
    Assert.notNil(bank.result.marker, "the planned bank stages its marker")
    local staged = execute("audio-catalog", "global", "leaf-catalog-stage")
    Assert.notNil(staged.result.marker, "the planned catalog stages its marker")
    local summary = execute("audio-summary", "global", "leaf-summary-stage")
    Assert.notNil(summary.result.marker, "the planned summary stages its marker")
    local unknown, unknownErr = pcall(execute, "audio-bank", "7", "leaf-unknown-stage")
    Assert.isFalse(unknown, "a bank outside the published membership fails")
    Assert.isTrue(
      tostring(unknownErr):find("7", 1, true) ~= nil,
      "the failure names the requested bank: " .. tostring(unknownErr)
    )
    Assert.equal(planCalls, 0, "leaf jobs never re-plan the archive")
    Assert.equal(identityCalls, 0, "leaf jobs never re-derive the sound identity")
  end)
  AudioCompiler.plan, AudioCompiler.soundIdentity = realPlan, realSoundIdentity
  if not ok then
    error(failure, 0)
  end
end

-- The bounded field runtime keeps the icon layout/catalog prerequisites but
-- never blanket icon pages (its exact roster pins this); the complete mon
-- summary still covers every declared page for batch.
function T.mon_summary_covers_every_declared_page_for_batch()
  local summaryDeps = ArtifactJobs.dependencies("mon-summary", "global", {
    iconPageIds = { 3, 4 },
    portraitPageIds = { 5 },
  })
  local summary = {}
  for _, dep in ipairs(summaryDeps) do
    summary[dep.kind .. ":" .. dep.key] = true
  end
  Assert.isTrue(summary["mon-icon-page:3"] == true, "the complete summary still covers page 3")
  Assert.isTrue(summary["mon-icon-page:4"] == true, "the complete summary still covers page 4")
end

-- The bounded field runtime guarantees both synchronously consumed menu
-- protocol banks without widening to whole-family message/audio summaries.
function T.field_runtime_covers_both_menu_protocol_banks_without_family_summaries()
  local set = {}
  for _, job in ipairs(ArtifactJobs.fieldRuntimeJobs()) do
    set[job.kind .. ":" .. job.key] = true
  end
  Assert.isTrue(
    set["message-bank:" .. tostring(MenuProtocol.STANDARD_MESSAGE_BANK)] == true,
    "field runtime carries the standard list-menu bank"
  )
  Assert.isTrue(
    set["message-bank:" .. tostring(MenuProtocol.START_MENU_MESSAGE_BANK)] == true,
    "field runtime carries the start menu bank"
  )
  Assert.isNil(set["message-summary:global"], "field runtime enrolls no message summary")
  Assert.isNil(set["audio-summary:global"], "field runtime enrolls no audio summary")
  for key in pairs(set) do
    local bank = key:match("^message%-bank:(.+)$")
    if bank ~= nil then
      Assert.isTrue(
        bank == tostring(MenuProtocol.STANDARD_MESSAGE_BANK) or bank == tostring(MenuProtocol.START_MENU_MESSAGE_BANK),
        "field runtime carries no message bank beyond the two protocol banks: " .. key
      )
    end
  end
end

-- Fixture seeding for the non-world record audit below: every family the
-- canonical walk reaches before map-data must be genuinely usable, so the
-- walk names the deliberately missing inventory record instead of an
-- earlier gap. Each helper stages the smallest usable payload through its
-- real writer and validator; no commercial bytes are involved.
local AUDIT_GENERATION = "non-world-audit-generation"

local function writeAuditReceipt(cache, kind, key, marker)
  cache:writeLua(ArtifactState.path(kind, key), {
    schema = ArtifactState.RECEIPT_SCHEMA,
    generationId = AUDIT_GENERATION,
    kind = kind,
    key = key,
    marker = marker,
  })
end

local function publishAuditCellIndex(cache, marker)
  local FieldCellCache = require("libs.assets.src.field.FieldCellCache")
  local index = { schema = FieldCellCache.INDEX_SCHEMA, matrices = {} }
  Assert.isTrue(FieldCellCache.validateIndex(index), "the synthetic index must validate")
  cache:writeLua(FieldCellCache.indexPath(), index)
  cache:write(FieldCellCache.indexMarkerPath(), marker)
  writeAuditReceipt(cache, "field-cell-index", "global", marker)
end

local function publishAuditCameraFamily(cache, marker)
  local FieldCameraCache = require("libs.assets.src.field.FieldCameraCache")
  cache:write(FieldCameraCache.profilesPath(), "profiles")
  cache:write(FieldCameraCache.provenancePath(), "provenance")
  cache:write(FieldCameraCache.markerPath(), marker)
  writeAuditReceipt(cache, "field-camera", "global", marker)
end

local function publishAuditFontFamily(cache, marker)
  local FontCache = require("libs.assets.src.field.FieldFontCache")
  for _, fontId in ipairs(FontCache.REQUIRED_FONT_IDS) do
    cache:write(FontCache.defPath(fontId), "def")
    cache:write(FontCache.atlasPath(fontId), "atlas")
    cache:write(FontCache.maskAtlasPath(fontId), "mask")
    cache:write(FontCache.focusIndicatorsPath(fontId), "focus")
  end
  cache:write(FontCache.markerPath(), marker)
  writeAuditReceipt(cache, "field-font", "global", marker)
end

local function publishAuditWeatherFamily(cache)
  local WeatherCache = require("libs.assets.src.field.FieldWeatherCache")
  local Compiler = require("romdump.src.digest.field.FieldWeatherCompiler")
  local Writer = require("romdump.src.digest.field.FieldWeatherCacheWriter")
  local bundle = assert(Compiler.compile())
  Assert.isTrue(Writer.write(cache, bundle))
  Assert.isTrue(WeatherCache.isReady(cache, bundle.marker), "the compiled weather class must read ready")
  writeAuditReceipt(cache, "field-weather", "global", bundle.marker)
end

local function publishAuditBagFamily(cache)
  local BagCache = require("libs.assets.src.BagCache")
  local Writer = require("romdump.src.digest.ui.BagCacheWriter")
  local BagPresentationFixture = require("tests.support.BagPresentationFixture")
  local manifest = BagPresentationFixture.manifest()
  local marker = BagCache.marker("test-rom", "test-dep")
  local assets = {}
  for _, assetPath in ipairs(BagCache.referencedPaths(manifest)) do
    assets[assetPath] = "payload:" .. assetPath
  end
  local ok, err = pcall(Writer.write, cache, {
    marker = marker,
    manifest = manifest,
    dependencies = { cacheFormat = BagCache.FORMAT, schema = BagCache.SCHEMA, fixture = true },
    assets = assets,
  })
  Assert.isTrue(ok, tostring(err))
  Assert.isTrue(BagCache.isReady(cache, marker), "the synthetic bag class must read ready")
  writeAuditReceipt(cache, "bag", "global", marker)
end

local function publishAuditUiFamily(cache)
  local UiCache = require("libs.assets.src.field.FieldUiAssetCache")
  local FieldUiFixture = require("tests.support.FieldUiFixture")
  local manifest = FieldUiFixture.manifest()
  manifest.reference = { width = 256, height = 192 }
  FieldUiFixture.addStartMenuIconContract(manifest)
  FieldUiFixture.addNamingSemantics(manifest)
  local valid, manifestErr = UiCache.validateManifest(manifest)
  Assert.isTrue(valid, "the current field-UI fixture validates: " .. tostring(manifestErr and manifestErr.message))
  local marker = UiCache.marker("test-rom", "test-dep")
  cache:writeLua(UiCache.manifestPath(), manifest)
  for _, entry in pairs(manifest.assets) do
    cache:write(entry.image, "png")
  end
  cache:write(UiCache.markerPath(), marker)
  local ready, readyErr = UiCache.isReady(cache, marker)
  Assert.isTrue(ready, tostring(readyErr))
  writeAuditReceipt(cache, "field-ui", "global", marker)
end

local function publishAuditIntroFamily(cache)
  local IntroCache = require("libs.assets.src.newgame.IntroAssetCache")
  local playback = {
    ball_open = true,
    marill_appear = true,
    marill = true,
    gender_male = true,
    gender_female = true,
    naming_male = true,
    naming_female = true,
  }
  local centered = { gender_male = true, gender_female = true, ball_open = true, marill_appear = true, marill = true }
  local widgets = {}
  for _, id in ipairs(IntroCache.REQUIRED_ASSETS) do
    local image = "assets/generated/intro/" .. id .. ".png"
    local widget = {
      image = image,
      width = 8,
      height = 8,
      sampling = "nearest",
      anchor = { x = 0, y = 0 },
      sourceBounds = { x = 0, y = 0, width = 8, height = 8 },
      frames = {
        { image = image, width = 8, height = 8, duration = 1 },
      },
    }
    if centered[id] then
      widget.sourceCenter = { x = 10, y = 10 }
    end
    if playback[id] then
      widget.playMode = "forward"
      widget.loopStartFrameIdx = 0
      widget.frames[1].element = id .. ".element"
      widget.frames[1].translateX = 0
      widget.frames[1].translateY = 0
      widget.frames[1].scaleX = 1
      widget.frames[1].scaleY = 1
      widget.frames[1].rotation = 0
    end
    widgets[id] = widget
  end
  local backgroundImage = "assets/generated/intro/background.png"
  local manifest = {
    schemaVersion = IntroCache.SCHEMA_VERSION,
    variant = "heartgold",
    sourceReference = { width = 256, height = 192 },
    background = { image = backgroundImage, width = 1, height = 192, sampling = "linear" },
    genderSelector = {
      defaultTone = { r = 0, g = 0, b = 0 },
      buttons = {
        male = { bounds = { x = 0, y = 0, width = 10, height = 10 } },
        female = { bounds = { x = 20, y = 0, width = 10, height = 10 } },
      },
    },
    widgets = widgets,
  }
  local marker = IntroCache.marker("test-rom", "test-dep")
  cache:writeLua(IntroCache.manifestPath(), manifest)
  cache:writeLua(IntroCache.provenancePath(), { schema = IntroCache.PROVENANCE_SCHEMA, source = {}, dependencies = {} })
  cache:write(backgroundImage, "png")
  for _, widget in pairs(widgets) do
    cache:write(widget.image, "png")
  end
  cache:write(IntroCache.markerPath(), marker)
  local ready, readyErr = IntroCache.isReady(cache, marker)
  Assert.isTrue(ready, tostring(readyErr))
  writeAuditReceipt(cache, "intro", "global", marker)
end

local function publishAuditActorFamily(cache)
  local FieldActorCache = require("libs.assets.src.field.FieldActorCache")
  local Writer = require("romdump.src.digest.actor.FieldActorCacheWriter")
  local Fixture = require("tests.support.FieldActorFixture")
  local states = {
    "walking",
    "cycling",
    "surfing",
    "rocket",
    "watering",
    "fishing",
    "poketch",
    "saving",
    "heal",
    "ladder",
    "rocket_heal",
    "rocket_saving",
    "pokeathlon",
    "apricorn_shake",
  }
  local function capability(id, gender, spriteIds)
    local named = {}
    for i, name in ipairs(states) do
      named[name] = spriteIds[((i - 1) % #spriteIds) + 1]
    end
    return { id = id, gender = gender, states = named }
  end
  local bundle = {
    marker = FieldActorCache.marker("test-rom", "test-dep"),
    index = {
      schema = FieldActorCache.INDEX_SCHEMA,
      romVersion = "heartgold",
      spriteIds = { 0 },
      variableSprites = {},
      recordCount = 3,
      runtime = {
        avatars = { capability("hero", 0, { 0 }), capability("heroine", 1, { 0 }) },
        variableSprites = { first = 101, last = 117, variableBase = 0x4020 },
      },
    },
    visuals = { [0] = Fixture.visual(0, { frameCount = 8 }) },
    atlases = { [0] = { width = 4, height = 1, pixels = string.rep("\0", 16) } },
    provenance = { schema = "g4-field-actor-provenance-v1" },
    dependencies = {},
  }
  Assert.equal(Writer.write(cache, bundle), bundle.marker)
  Assert.isTrue(FieldActorCache.isReady(cache, bundle.marker), "the synthetic actor class must read ready")
  writeAuditReceipt(cache, "actors", "global", bundle.marker)
end

local function publishAuditItemFamily(cache)
  local ItemCache = require("libs.assets.src.ItemCache")
  local Writer = require("romdump.src.digest.items.ItemCacheWriter")
  local PngWriter = require("libs.assets.src.PngWriter")
  local ItemFixture = require("libs.items.tests.item_fixture")
  local marker = ItemCache.marker("test-rom", "test-dep")
  local pixels = string.rep("\0", 32 * 32 * 4)
  local catalog = ItemFixture.buildAssetRoot()
  local entries = {}
  for key in pairs(catalog.items) do
    entries[key] = { x = 0, y = 0, width = 32, height = 32 }
  end
  local bundle = {
    marker = marker,
    index = {
      schema = "g4-item-index-v1",
      version = { id = "heartgold", language = "en" },
      catalogHash = Hashing.hashLua(catalog),
      iconHash = Hashing.sha1hex(PngWriter.encode(32, 32, pixels)),
      catalog = ItemCache.catalogPath(),
      icons = ItemCache.iconImagePath(),
      iconManifest = ItemCache.iconManifestPath(),
    },
    catalog = catalog,
    icons = { width = 32, height = 32, pixels = pixels },
    iconManifest = {
      schema = "g4-item-icons-v1",
      atlas = ItemCache.iconImagePath(),
      entries = entries,
      representative = { "POTION" },
    },
    provenance = {},
  }
  Writer.write(cache, bundle)
  Assert.isTrue(ItemCache.isReady(cache, marker), "the synthetic item class must read ready")
  writeAuditReceipt(cache, "items", "global", marker)
end

local function publishAuditEmoteFamily(cache)
  local EmoteCache = require("libs.assets.src.field.FieldEmoteAssetCache")
  local Writer = require("romdump.src.digest.actor.FieldActorEmoteCacheWriter")
  local ModelAsset = require("libs.assets.src.model.ModelAsset")
  local PngWriter = require("libs.assets.src.PngWriter")
  local marker = "field-emotes-cache-v2:test-rom:test-dep"
  local ok, err = pcall(Writer.write, cache, {
    marker = marker,
    model = {
      schema = "g4-field-emote-v1",
      anchorOffset = { x = 0, y = 2, z = 0.0625 },
      model = {
        schema = ModelAsset.SCHEMA,
        key = "field-emote:exclamation",
        kind = "static",
        batches = {
          {
            geometry = EmoteCache.geometryPath("mesh-key"),
            cullMode = "back",
            polygonMode = "modulation",
            polygonId = 0,
            translucentDepthWrite = false,
            depthEqual = false,
            polygonAlpha = 31,
            lightMask = 5,
            fogEnabled = false,
          },
        },
        materials = {
          {
            id = 0,
            name = "exclamation",
            texture = EmoteCache.texturePath("texture-key"),
            textureFormat = 3,
            wrap = { x = "clamp", y = "clamp" },
            flip = { x = false, y = false },
            diffuse = { r = 255, g = 255, b = 255, a = 255 },
          },
        },
      },
    },
    meshes = {
      ["mesh-key"] = {
        getSize = function()
          return 12
        end,
        getString = function()
          return "encoded-mesh"
        end,
      },
    },
    textures = { ["texture-key"] = { width = 1, height = 1, data = PngWriter.encode(1, 1, "rgba") } },
  })
  Assert.isTrue(ok, tostring(err))
  Assert.isTrue(EmoteCache.isReady(cache, marker), "the synthetic emote class must read ready")
  writeAuditReceipt(cache, "field-emotes", "global", marker)
end

local function publishAuditEffectFamily(cache)
  local EffectCache = require("libs.assets.src.field.FieldEffectAssetCache")
  local Writer = require("romdump.src.digest.field.FieldEntranceIndicatorCacheWriter")
  local ModelAsset = require("libs.assets.src.model.ModelAsset")
  local MeshWriter = require("libs.assets.src.model.MeshWriter")
  local PngWriter = require("libs.assets.src.PngWriter")
  local Contract = require("libs.assets.src.DerivedAssetContract")
  local function staticModel(key)
    return {
      schema = ModelAsset.SCHEMA,
      key = key,
      kind = "static",
      batches = {
        {
          geometry = EffectCache.geometryPath("mesh-key"),
          cullMode = "back",
          polygonMode = "modulation",
          polygonId = 0,
          translucentDepthWrite = false,
          depthEqual = false,
          polygonAlpha = 31,
          lightMask = 5,
          fogEnabled = false,
        },
      },
      materials = {
        {
          id = 0,
          name = "effect",
          texture = EffectCache.texturePath("texture-key"),
          textureFormat = 3,
          wrap = { x = "clamp", y = "clamp" },
          flip = { x = false, y = false },
          diffuse = { r = 255, g = 255, b = 255, a = 255 },
        },
      },
    }
  end
  local function dynamicModel(key)
    return {
      schema = ModelAsset.SCHEMA,
      key = key,
      kind = "nitro-dynamic",
      dynamic = { nodes = {}, transformProgram = {}, batches = {} },
      animations = {
        {
          id = key .. ".clip",
          name = key .. ".clip",
          category = "joint",
          kind = "trs",
          frameCount = 4,
          tracks = { { target = 0, targetIndex = 0 } },
          semanticNames = { key .. ".clip" },
          compiled = {
            anmFlags = 0,
            rotData = {},
            pivotData = { { 0, 0, 0, 0, 0 } },
            targets = {
              {
                nodeIndex = 0,
                channels = {
                  trans = {
                    x = { source = "constant", value = 0 },
                    y = { source = "constant", value = 0 },
                    z = { source = "constant", value = 0 },
                  },
                  rot = { source = "constant", value = 0 },
                  scale = {
                    x = { source = "constant", value = 0 },
                    y = { source = "constant", value = 0 },
                    z = { source = "constant", value = 0 },
                  },
                },
              },
            },
          },
        },
      },
      materials = {
        {
          id = 0,
          name = "effect",
          baseColor = { r = 255, g = 255, b = 255, a = 255 },
          colors = {
            diffuse = { r = 255, g = 255, b = 255 },
            ambient = { r = 255, g = 255, b = 255 },
            specular = { r = 255, g = 255, b = 255 },
            emission = { r = 0, g = 0, b = 0 },
          },
          alphaMode = "opaque",
          polygonMode = "modulation",
          doubleSided = false,
          polygonAlpha = 31,
          texMtxMode = 0,
          texWidth = 64,
          texHeight = 64,
          wrap = { x = "clamp", y = "clamp" },
          flip = { x = false, y = false },
          diffuse = { r = 255, g = 255, b = 255, a = 255 },
        },
      },
    }
  end
  local marker = EffectCache.marker("test-rom", "test-dep")
  local bundle = {
    marker = marker,
    index = {
      schema = Contract.fieldEffects.indexSchema,
      effects = {
        warp_entrance = {
          path = EffectCache.definitionPath("warp_entrance"),
          definition = "warp_entrance",
          kind = "model",
        },
        tall_grass = {
          path = EffectCache.definitionPath("tall_grass"),
          definition = "tall_grass",
          kind = "animated_model",
        },
        very_tall_grass = {
          path = EffectCache.definitionPath("very_tall_grass"),
          definition = "very_tall_grass",
          kind = "animated_model",
        },
        trainer_reveal = {
          path = EffectCache.definitionPath("trainer_reveal"),
          definition = "trainer_reveal",
          kind = "animated_model",
        },
        surf_attachment = {
          path = EffectCache.definitionPath("surf_attachment"),
          definition = "surf_attachment",
          kind = "model",
        },
        follower_transition = {
          path = EffectCache.definitionPath("follower_transition"),
          definition = "follower_transition",
          kind = "transition",
        },
      },
    },
    effects = {
      warp_entrance = { model = staticModel("field-effect:warp-entrance"), lifetime = 1 },
      tall_grass = {
        model = dynamicModel("field-effect:tall-grass"),
        lifecycle = { mode = "hold_until_owner_moves", holdFrame = 2 },
        placementOffset = { x = 0, y = 0, z = 0.625 },
      },
      very_tall_grass = {
        model = dynamicModel("field-effect:very-tall-grass"),
        lifecycle = { mode = "hold_until_owner_moves", holdFrame = 2 },
        placementOffset = { x = 0, y = 0, z = 0.625 },
      },
      trainer_reveal = {
        model = dynamicModel("field-effect:trainer-reveal"),
        lifecycle = { mode = "once", frameCount = 4 },
        placementOffset = { x = 0, y = 0, z = 0.5 },
      },
      surf_attachment = {
        model = staticModel("field-effect:surf-attachment"),
        presentation = {
          initialPlayerOffset = { x = 0, y = 4 / 16, z = 4 / 16 },
          oscillator = { initialY = 1 / 16, minY = 1 / 16, maxY = 4 / 16, stepY = (1 / 4) / 16 },
          playerBaseOffset = { x = 0, y = 4 / 16, z = 4 / 16 },
          attachmentBaseOffset = { x = 0, y = -1 / 16, z = 0 },
          yawDegrees = { north = 180, south = 0, west = 270, east = 90 },
        },
      },
      follower_transition = {
        models = { staticModel("field-effect:transition-companion"), dynamicModel("field-effect:transition-lead") },
        lifecycle = { mode = "once", frameCount = 4, preludeTicks = 2 },
        placementOffset = { x = 0, y = 0.375, z = 0 },
      },
    },
    meshes = { ["mesh-key"] = {} },
    textures = { ["texture-key"] = { width = 1, height = 1, data = PngWriter.encode(1, 1, "rgba") } },
  }
  local oldEncode = MeshWriter.encode
  MeshWriter.encode = function()
    return "encoded-mesh"
  end
  local ok, err = pcall(Writer.write, cache, bundle)
  MeshWriter.encode = oldEncode
  Assert.isTrue(ok, tostring(err))
  local ready, readyErr = EffectCache.isReady(cache, marker)
  Assert.isTrue(ready, tostring(readyErr))
  writeAuditReceipt(cache, "field-effects", "global", marker)
end

local function publishAuditAudioFamily(cache, marker)
  local AudioCache = require("libs.assets.src.audio.AudioCache")
  cache:write(AudioCache.markerPath(), marker)
  cache:writeLua(AudioCache.indexPath(), {
    schema = AudioCache.INDEX_SCHEMA,
    sequences = {},
    banks = {},
    players = {},
    sequenceBySymbol = {},
    bankBySymbol = {},
  })
  cache:write(AudioCache.catalogMarkerPath(), marker)
  writeAuditReceipt(cache, "audio-catalog", "global", marker)
  writeAuditReceipt(cache, "audio-summary", "global", marker)
end

local function publishAuditMapDataRecord(cache, mapId, marker)
  local FieldMapData = require("libs.assets.src.field.FieldMapDataCache")
  cache:writeLua(FieldMapData.fieldPath(mapId), {
    schema = FieldMapData.FIELD_SCHEMA,
    mapId = mapId,
    events = { background = {}, objects = {}, warps = {}, coordinates = {} },
    music = {},
    soundplates = {},
    initScripts = {},
    transitionEnvironment = "outdoors",
  })
  cache:writeLua(FieldMapData.dependenciesPath(mapId), { generated = true })
  cache:write(FieldMapData.markerPath(mapId), marker)
  writeAuditReceipt(cache, "map-data", tostring(mapId), marker)
end

-- Supported field records are enumerated from the authoritative source
-- rule, never narrowed to the visual world: a supported record absent
-- from a small synthetic world is still scheduled, and the exhaustive
-- audit names exactly that leaf when its payload is missing.
function T.complete_inventory_covers_supported_records_absent_from_the_world()
  local SourcePlan = require("romdump.src.build.SourcePlan")
  local FieldMessageCompiler = require("romdump.src.digest.ui.FieldMessageCompiler")
  local FieldMapDataCompiler = require("romdump.src.digest.field.FieldMapDataCompiler")
  local DerivedCacheAudit = require("romdump.src.DerivedCacheAudit")
  local FieldMapDataCache = require("libs.assets.src.field.FieldMapDataCache")
  local supported = FieldMapDataCompiler.supportedMapIds()
  Assert.isTrue(#supported >= 2, "the source rule keeps supported records")
  local outside = nil
  for _, mapId in ipairs(supported) do
    if mapId ~= 7 and mapId ~= 9 then
      outside = mapId
      break
    end
  end
  Assert.notNil(outside, "some supported record lives outside the small world")
  outside = assert(outside, "some supported record lives outside the small world")
  local present = supported[1]
  if present == outside then
    present = assert(supported[2], "the source rule keeps supported records")
  end
  local generation = "slim-world-generation"
  local producerId = "d" .. string.rep("3", 64)
  local recordIdentity = { versionId = "heartgold", generationId = generation, producerId = producerId }
  local recordCache = CacheFs.forVersion("heartgold", FakeCache.new())
  recordCache:writeLua(SourcePlan.PATH, {
    schema = "g4-source-plan-v3",
    versionId = "heartgold",
    romSha1 = string.rep("a", 40),
    generationId = generation,
    producerId = producerId,
    world = {
      maps = { { id = 7 }, { id = 9 } },
      analysis = { excluded = { { id = 3, reason = "placeholder header" } } },
    },
    fieldCellIndexBundle = { index = { matrices = {} }, indexMarker = "synthetic-index-marker" },
    scriptPlan = { members = {}, generationKey = "synthetic-generation" },
    audioPlan = { index = { version = "heartgold" }, bankPlans = {} },
    audioIdentity = { romSha1 = string.rep("a", 40), sdatSha1 = string.rep("e", 40), sdatFileId = 11 },
    mapCellKeys = { [7] = {}, [9] = {} },
  })
  local accepted, acceptReason = ArtifactJobs.sourcePlanForContext({ cacheFs = recordCache }, recordIdentity)
  Assert.notNil(accepted, "the slim inventory is accepted: " .. tostring(acceptReason))
  local record = assert(accepted, "the slim inventory is accepted")
  local schedulerPlans = {
    indexBundle = record.fieldCellIndexBundle,
    scriptPlan = record.scriptPlan,
    audioPlan = record.audioPlan,
    messageBankIds = FieldMessageCompiler.requiredBankIds(),
    audioBankIds = {},
    scriptMemberIds = {},
    iconPageIds = {},
    portraitPageIds = {},
    mapDataIds = FieldMapDataCompiler.supportedMapIds(),
    mapIds = { 7, 9 },
    mapCellKeys = record.mapCellKeys,
    world = record.world,
  }
  Assert.deepEqual(schedulerPlans.mapDataIds, supported, "scheduler records cover the authoritative universe")
  Assert.deepEqual(schedulerPlans.mapIds, { 7, 9 }, "the visual world stays narrow")
  local seen = {}
  for _, job in ipairs(ArtifactJobs.completeJobs(schedulerPlans)) do
    seen[job.jobKey] = true
  end
  Assert.isTrue(seen["map-data:" .. tostring(outside)] == true, "the canonical inventory covers the non-world record")
  Assert.isNil(seen["map:" .. tostring(outside)], "the visual world never gains the non-world record")
  local iterate = ArtifactJobs.completeIterator(schedulerPlans)
  local iterated = {}
  while true do
    local job = iterate()
    if job == nil then
      break
    end
    iterated[job.jobKey] = true
  end
  Assert.isTrue(
    iterated["map-data:" .. tostring(outside)] == true,
    "the incremental enumerator covers the non-world record"
  )
  local backend = FakeCache.new()
  local auditCache = CacheFs.forVersion("heartgold", backend)
  publishAuditCellIndex(auditCache, "non-world-index-marker")
  publishAuditCameraFamily(auditCache, "non-world-camera-marker")
  publishAuditFontFamily(auditCache, "non-world-font-marker")
  publishAuditWeatherFamily(auditCache)
  publishAuditBagFamily(auditCache)
  publishAuditUiFamily(auditCache)
  publishAuditIntroFamily(auditCache)
  publishAuditActorFamily(auditCache)
  publishAuditItemFamily(auditCache)
  publishAuditEmoteFamily(auditCache)
  publishAuditEffectFamily(auditCache)
  publishAuditAudioFamily(auditCache, "non-world-audio-marker")
  publishAuditMapDataRecord(auditCache, present, FieldMapDataCache.marker("test-rom", present, "test-dep"))
  local auditPlans = {
    indexBundle = { index = { matrices = {} } },
    scriptPlan = { generationKey = string.rep("e", 40), members = {}, resources = {} },
    messageBankIds = {},
    audioBankIds = {},
    scriptMemberIds = {},
    iconPageIds = {},
    portraitPageIds = {},
    mapDataIds = { present, outside },
    mapIds = {},
  }
  for _, premise in ipairs({
    { kind = "actors", key = "global" },
    { kind = "audio-catalog", key = "global" },
    { kind = "audio-summary", key = "global" },
    { kind = "bag", key = "global" },
    { kind = "field-camera", key = "global" },
    { kind = "field-cell-index", key = "global" },
    { kind = "field-effects", key = "global" },
    { kind = "field-emotes", key = "global" },
    { kind = "field-font", key = "global" },
    { kind = "field-ui", key = "global" },
    { kind = "field-weather", key = "global" },
    { kind = "intro", key = "global" },
    { kind = "items", key = "global" },
    { kind = "map-data", key = tostring(present) },
  }) do
    Assert.isTrue(
      ArtifactJobs.validate(auditCache, AUDIT_GENERATION, premise.kind, premise.key, auditPlans),
      "premise job must be usable: " .. premise.kind .. ":" .. premise.key
    )
  end
  local function snapshot()
    local copy = {}
    for path, data in pairs(backend.files) do
      copy[path] = data
    end
    return copy
  end
  local before = snapshot()
  local auditIdentity = { versionId = "heartgold", generationId = AUDIT_GENERATION, producerId = "audit-producer" }
  local available, auditReason = DerivedCacheAudit.isAvailable(auditCache, auditIdentity, auditPlans)
  Assert.deepEqual(snapshot(), before, "a read-only audit performs no writes")
  Assert.isFalse(available, "the audit must fail on the missing inventory record")
  Assert.isTrue(
    auditReason ~= nil and auditReason:find("map-data:" .. tostring(outside), 1, true) ~= nil,
    "the failure names the exact map-data key, got: " .. tostring(auditReason)
  )
end

return { metadata = { capabilities = {} }, tests = T }
