-- Script generation publication contract: members stage through
-- worker-owned preparations, the summary activates only a complete
-- generation, and a failed member leaves the last active generation complete
-- and usable while the failed generation remains inert.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local Errors = require("libs.errors.src.Errors")
local FakeCache = require("tests.support.FakeCache")
local PreparedArtifact = require("romdump.src.build.PreparedArtifact")
local ScriptCache = require("libs.assets.src.ScriptCache")
local ScriptCacheWriter = require("romdump.src.digest.script.ScriptCacheWriter")
local LuaWriter = require("libs.codec.src.LuaWriter")
local ResidentArtifactFixture = require("tests.support.ResidentArtifactFixture")

local T = {}
local GENERATION_A = string.rep("a", 40)
local GENERATION_B = string.rep("b", 40)

local function resource(id)
  return {
    api = 1,
    id = id,
    metadata = { generated = true },
    steps = { { op = "stop" } },
  }
end

local function member(memberId, id, generation)
  return {
    memberId = memberId,
    marker = generation .. ":member:" .. tostring(memberId),
    coverage = {
      source = { repository = "portemon", romSha1 = generation },
      totals = {
        members = 1,
        scripts = 1,
        reachableInstructions = 1,
        supportedInstructions = 1,
        unsupportedInstructions = 0,
      },
      opcodes = {},
      scripts = {
        {
          sourceId = string.format("hgss.scr_seq.%04d.%03d", memberId, 0),
          publicId = id,
          status = "complete",
          unsupported = {},
        },
      },
    },
    resources = {
      {
        id = id,
        member = memberId,
        scriptIndex = 0,
        resource = resource(id),
        report = { complete = true, unsupportedCount = 0 },
        directDependencies = { audioSequences = {}, scriptTargets = {}, assetNeeds = {} },
      },
    },
  }
end

local function plan(generation, marker)
  local result = {
    generationKey = generation,
    marker = marker,
    version = "heartgold",
    sourcePath = "romfs/a/0/1/2",
    romSha1 = "rom-sha",
    dependencies = {
      cacheFormat = ScriptCache.FORMAT,
      versionRomSha1 = "rom-sha",
      scrSeqNarc = { path = "a/0/1/2", sha1 = "archive-sha" },
    },
    memberCount = 2,
    members = {
      { memberId = 0, marker = generation .. ":member:0" },
      { memberId = 1, marker = generation .. ":member:1" },
    },
    resources = {
      { id = "stable.script", member = 0, scriptIndex = 0 },
      { id = "second.script", member = 1, scriptIndex = 0 },
    },
  }
  result.index = {
    schema = ScriptCache.INDEX_SCHEMA,
    version = "heartgold",
    generation = generation,
    marker = marker,
    memberCount = 2,
    scriptMemberCount = 2,
    skippedMemberCount = 0,
    scriptCount = 2,
    resourceCount = 2,
    resources = result.resources,
  }
  return result
end

local function preparation(cache, key, outerGeneration, epoch)
  return PreparedArtifact.new({
    cacheFs = cache,
    generationId = outerGeneration,
    epoch = epoch or 1,
    kind = "script-member",
    key = key,
    jobKey = "script-member:" .. key,
  })
end

local function publishMember(cache, currentPlan, staged, outerGeneration)
  local artifact = preparation(cache, tostring(staged.memberId), outerGeneration)
  Assert.isTrue(ScriptCacheWriter.stageMember(artifact, currentPlan, staged))
  artifact:finishSuccess({ marker = staged.marker })
  Assert.isTrue(ResidentArtifactFixture.materialize(artifact))
end

local function publishSummary(cache, currentPlan, outerGeneration)
  local artifact = preparation(cache, "global", outerGeneration)
  Assert.isTrue(ScriptCacheWriter.stageSummary(artifact, currentPlan) ~= nil)
  artifact:finishSuccess({ marker = currentPlan.marker })
  Assert.isTrue(ResidentArtifactFixture.materialize(artifact))
end

local function writeGeneration(cache, generation, marker, prefix, outerGeneration)
  local currentPlan = plan(generation, marker)
  publishMember(cache, currentPlan, member(0, "stable.script", generation), outerGeneration)
  publishMember(cache, currentPlan, member(1, "second.script", generation), outerGeneration)
  publishSummary(cache, currentPlan, outerGeneration)
end

function T.failed_member_keeps_the_previous_active_generation_ready()
  Assert.isTrue(
    type(ScriptCacheWriter.stageMember) == "function",
    "generation publication must expose a member staging boundary"
  )
  Assert.isTrue(
    type(ScriptCacheWriter.stageSummary) == "function",
    "generation publication must expose a summary staging boundary"
  )
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  writeGeneration(cache, GENERATION_A, "marker-a", "initial", "outer-a")
  Assert.isTrue(ScriptCache.isReady(cache, "marker-a"), "the initial generation must be ready")

  local nextPlan = plan(GENERATION_B, "marker-b")
  publishMember(cache, nextPlan, member(0, "stable.script", GENERATION_B), "outer-b")

  local failed = member(1, "second.script", GENERATION_B)
  failed.resources[1].resource.id = "wrong.script"
  local artifact = preparation(cache, "1", "outer-b")
  local failure = Assert.throws(function()
    ScriptCacheWriter.stageMember(artifact, nextPlan, failed)
  end, "a malformed member must fail before summary publication")
  failure = failure --[[@as { code: string }]]
  Assert.isTrue(Errors.is(failure))
  artifact:abort()

  local summary = preparation(cache, "global", "outer-b")
  local summaryFailure = Assert.throws(function()
    ScriptCacheWriter.stageSummary(summary, nextPlan)
  end, "an incomplete generation must not publish a summary")
  summaryFailure = summaryFailure --[[@as { code: string }]]
  Assert.equal(summaryFailure.code, "SCRIPT_SUMMARY_INCOMPLETE")
  summary:abort()
  Assert.equal(
    assert(ScriptCache.loadActive(cache)).marker,
    "marker-a",
    "member failure must not replace active selection"
  )
  Assert.isTrue(ScriptCache.isReady(cache, "marker-a"), "the previous generation remains complete and readable")
  Assert.isFalse(ScriptCache.isReady(cache, "marker-b"), "the failed generation is never active-ready")
end

function T.failed_repair_stage_leaves_the_live_member_untouched()
  local backend = FakeCache.new()
  local cache = CacheFs.forVersion("heartgold", backend)
  writeGeneration(cache, GENERATION_A, "marker-a", "initial", "outer-a")
  local original = assert(cache:read(ScriptCache.memberPath(GENERATION_A, 0)))
  local rebuild = member(0, "stable.script", GENERATION_A)
  local realWrite = backend.write
  backend.write = function(self, path, data)
    if path:find("/generations/", 1, true) then
      error("injected repair failure")
    end
    return realWrite(self, path, data)
  end
  local artifact = preparation(cache, "0", "outer-a")
  Assert.throws(function()
    ScriptCacheWriter.stageMember(artifact, rebuild, plan(GENERATION_A, "marker-a"))
  end, "a failed repair stage must not complete")
  backend.write = realWrite
  artifact:abort()
  Assert.equal(
    cache:read(ScriptCache.memberPath(GENERATION_A, 0)),
    original,
    "a failed repair stage must preserve the live member bundle"
  )
  Assert.equal(assert(ScriptCache.loadActive(cache)).marker, "marker-a", "the active selection must remain current")
  Assert.isTrue(ScriptCache.isReady(cache, "marker-a"), "the last-known-good generation remains ready")
end

-- The member stage reads its own emitted bundle back before it returns a
-- marker, so a bundle that does not load refuses the whole member.
function T.member_completion_requires_resource_readback_before_marker()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local currentPlan = plan(GENERATION_A, "marker-a")
  local LuaEmitter = require("romdump.src.digest.script.LuaEmitter")
  local realEmitMember = LuaEmitter.emitMember
  LuaEmitter.emitMember = function()
    return "this is not a generated bundle {{{"
  end

  local artifact = preparation(cache, "0", "outer-a")
  local ok = pcall(
    ScriptCacheWriter.stageMember,
    artifact,
    currentPlan,
    member(0, "stable.script", GENERATION_A)
  )
  LuaEmitter.emitMember = realEmitMember
  Assert.isFalse(ok, "a member must not complete when its emitted bundle fails readback")
  artifact:abort()
  Assert.isNil(cache:read(ScriptCache.memberPath(GENERATION_A, 0)), "a failed readback publishes no member")
end

-- The readback compares the bundle against the plan, so a bundle carrying a
-- different resource identity refuses the whole member.
function T.member_readback_requires_the_planned_resource_identity()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local currentPlan = plan(GENERATION_A, "marker-a")
  local LuaEmitter = require("romdump.src.digest.script.LuaEmitter")
  local realEmitMember = LuaEmitter.emitMember
  LuaEmitter.emitMember = function(stagedMember)
    return (realEmitMember(stagedMember):gsub('id = "stable.script"', 'id = "wrong.script"'))
  end

  local artifact = preparation(cache, "0", "outer-a")
  local ok = pcall(
    ScriptCacheWriter.stageMember,
    artifact,
    currentPlan,
    member(0, "stable.script", GENERATION_A)
  )
  LuaEmitter.emitMember = realEmitMember
  Assert.isFalse(ok, "a member must not complete when its serialized resource identity is wrong")
  artifact:abort()
  Assert.isNil(cache:read(ScriptCache.memberPath(GENERATION_A, 0)), "a mismatched readback publishes no member")
end

function T.repaired_member_stages_into_the_private_stage_without_touching_live()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local currentPlan = plan(GENERATION_A, "marker-a")
  writeGeneration(cache, GENERATION_A, "marker-a", "initial", "outer-a")
  local liveBefore = assert(cache:read(ScriptCache.memberPath(GENERATION_A, 0)))

  local artifact = preparation(cache, "0", "outer-a")
  local staged = ScriptCacheWriter.stageMember(artifact, currentPlan, member(0, "stable.script", GENERATION_A))
  Assert.equal(staged, GENERATION_A .. ":member:0", "repair staging returns the exact member marker")
  Assert.equal(
    cache:read(ScriptCache.memberPath(GENERATION_A, 0)),
    liveBefore,
    "repair staging must not rewrite the live member"
  )
  local stagedBundle = artifact:loadModule(ScriptCache.memberPath(GENERATION_A, 0))
  Assert.equal(stagedBundle.scripts[1].id, "stable.script", "the repair lands in the private stage")
  artifact:abort()
end

function T.summary_attests_member_coverage_and_plan_identity()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local currentPlan = plan(GENERATION_A, "marker-a")
  publishMember(cache, currentPlan, member(0, "stable.script", GENERATION_A), "outer-a")
  publishMember(cache, currentPlan, member(1, "second.script", GENERATION_A), "outer-a")

  local published = assert(cache:read(ScriptCache.memberPath(GENERATION_A, 0)))
  local drifted, replacements = published:gsub('id = "stable.script"', 'id = "wrong.script"', 1)
  Assert.equal(replacements, 1, "the drift edits the published resource identity")
  cache:write(ScriptCache.memberPath(GENERATION_A, 0), drifted)
  local summary = preparation(cache, "global", "outer-a")
  local failure = Assert.throws(function()
    ScriptCacheWriter.stageSummary(summary, currentPlan)
  end, "summary staging must attest the published member against the plan")
  failure = failure --[[@as { code: string }]]
  Assert.equal(failure.code, "SCRIPT_SUMMARY_INCOMPLETE")
  summary:abort()

  cache:write(ScriptCache.memberPath(GENERATION_A, 0), published)
  currentPlan.index.resources[1].id = "wrong.script"
  local mismatch = preparation(cache, "global", "outer-a")
  Assert.throws(function()
    ScriptCacheWriter.stageSummary(mismatch, currentPlan)
  end, "summary staging must attest the complete plan identity")
  mismatch:abort()
end

function T.member_with_no_resources_stages_without_a_fake_job()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local currentPlan = plan(GENERATION_A, "marker-a")
  currentPlan.members[2].memberId = 7
  currentPlan.members[2].marker = GENERATION_A .. ":member:7"
  currentPlan.resources = { { id = "stable.script", member = 0, scriptIndex = 0 } }
  currentPlan.index.resources = currentPlan.resources
  currentPlan.index.scriptCount = 1
  currentPlan.index.resourceCount = 1
  publishMember(cache, currentPlan, member(0, "stable.script", GENERATION_A), "outer-a")

  local empty = {
    memberId = 7,
    marker = GENERATION_A .. ":member:7",
    coverage = {
      source = { repository = "portemon", romSha1 = GENERATION_A },
      totals = {
        members = 1,
        scripts = 0,
        reachableInstructions = 0,
        supportedInstructions = 0,
        unsupportedInstructions = 0,
      },
      opcodes = {},
      scripts = {},
    },
    resources = {},
  }
  local artifact = preparation(cache, "7", "outer-a")
  Assert.equal(ScriptCacheWriter.stageMember(artifact, currentPlan, empty), GENERATION_A .. ":member:7")
  artifact:finishSuccess({ marker = GENERATION_A .. ":member:7" })
  Assert.isTrue(ResidentArtifactFixture.materialize(artifact))
  publishSummary(cache, currentPlan, "outer-a")
  Assert.isTrue(ScriptCache.isReady(cache, "marker-a"))
end

function T.duplicate_resource_ids_fail_member_staging()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local currentPlan = plan(GENERATION_A, "marker-a")
  local duplicated = member(0, "stable.script", GENERATION_A)
  duplicated.resources[#duplicated.resources + 1] = duplicated.resources[1]
  local artifact = preparation(cache, "0", "outer-a")
  local failure = Assert.throws(function()
    ScriptCacheWriter.stageMember(artifact, currentPlan, duplicated)
  end, "a member with duplicate resource ids must fail before any write")
  failure = failure --[[@as { code: string }]]
  Assert.equal(failure.code, "SCRIPT_MEMBER_INVALID")
  artifact:abort()
  Assert.isNil(cache:read(ScriptCache.memberPath(GENERATION_A, 0)))
end

function T.malformed_coverage_fails_member_staging()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local currentPlan = plan(GENERATION_A, "marker-a")
  local malformed = member(0, "stable.script", GENERATION_A)
  malformed.coverage.totals.scripts = 7
  local artifact = preparation(cache, "0", "outer-a")
  local failure = Assert.throws(function()
    ScriptCacheWriter.stageMember(artifact, currentPlan, malformed)
  end, "a member with malformed coverage must fail before any write")
  failure = failure --[[@as { code: string }]]
  Assert.equal(failure.code, "SCRIPT_MEMBER_COVERAGE_INVALID")
  artifact:abort()
  Assert.isNil(cache:read(ScriptCache.memberPath(GENERATION_A, 0)))
end

-- A staged summary owns its bytes until the caller publishes them: the active
-- generation stays cold while the private output is open, and the committed
-- bytes activate exactly once. Stale-generation and stale-epoch rejection is
-- the publishing controller's rule, proven by the compiler-pool retirement
-- cases.
function T.staged_summary_activates_only_after_its_publication()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local currentPlan = plan(GENERATION_A, "marker-a")
  publishMember(cache, currentPlan, member(0, "stable.script", GENERATION_A), "outer-a")
  publishMember(cache, currentPlan, member(1, "second.script", GENERATION_A), "outer-a")

  local artifact = preparation(cache, "global", "outer-a")
  local marker = ScriptCacheWriter.stageSummary(artifact, currentPlan)
  Assert.notNil(marker, "summary staging produces its marker")
  artifact:finishSuccess({ marker = currentPlan.marker })
  Assert.isFalse(ScriptCache.isReady(cache, "marker-a"), "a staged summary is not live before publication")
  Assert.isTrue(ResidentArtifactFixture.materialize(artifact))
  Assert.isTrue(ScriptCache.isReady(cache, "marker-a"), "the committed summary publication activates")
end

function T.stale_dependency_metadata_is_rejected()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local currentPlan = plan(GENERATION_A, "marker-a")
  publishMember(cache, currentPlan, member(0, "stable.script", GENERATION_A), "outer-a")
  publishMember(cache, currentPlan, member(1, "second.script", GENERATION_A), "outer-a")
  -- Rewind the published bundle to a shape without usable dependency facts:
  -- every script body still decodes, so only the missing facts can refuse it.
  local published = assert(cache:read(ScriptCache.memberPath(GENERATION_A, 0)))
  local drifted, replacements = published:gsub("assetNeeds = {},", 'assetNeeds = "not a need list",', 1)
  Assert.equal(replacements, 1, "the drift edits the published dependency facts")
  cache:write(ScriptCache.memberPath(GENERATION_A, 0), drifted)
  local ready, reason = ScriptCacheWriter.isMemberReady(cache, currentPlan, 0)
  Assert.isFalse(ready, "a bundle without usable dependency facts must not attest its member")
  Assert.isTrue(type(reason) == "string" and reason ~= "", "the refusal names its cause")
  local summary = preparation(cache, "global", "outer-a")
  local failure = Assert.throws(function()
    ScriptCacheWriter.stageSummary(summary, currentPlan)
  end, "a summary over stale dependency metadata must be refused")
  failure = failure --[[@as { code: string }]]
  Assert.equal(failure.code, "SCRIPT_SUMMARY_INCOMPLETE")
  summary:abort()
end

function T.summary_publishes_explicit_empty_member_audio_closure_deterministically()
  local first = CacheFs.forVersion("heartgold", FakeCache.new())
  local second = CacheFs.forVersion("heartgold", FakeCache.new())
  local firstPlan = plan(GENERATION_A, "marker-a")
  publishMember(first, firstPlan, member(0, "stable.script", GENERATION_A), "outer-a")
  publishMember(first, firstPlan, member(1, "second.script", GENERATION_A), "outer-a")
  publishSummary(first, firstPlan, "outer-a")
  local secondPlan = plan(GENERATION_A, "marker-a")
  publishMember(second, secondPlan, member(0, "stable.script", GENERATION_A), "outer-a")
  publishMember(second, secondPlan, member(1, "second.script", GENERATION_A), "outer-a")
  publishSummary(second, secondPlan, "outer-a")
  local firstIndex = assert(first:loadLua(ScriptCache.activeIndexPath()))
  local secondIndex = assert(second:loadLua(ScriptCache.activeIndexPath()))
  Assert.deepEqual(
    firstIndex.memberAudioSequences,
    { ["0"] = {}, ["1"] = {} },
    "audio-free members carry an explicit empty closure"
  )
  Assert.equal(
    LuaWriter.encode(firstIndex),
    LuaWriter.encode(secondIndex),
    "two identical summary publications are byte-equivalent"
  )
end

function T.summary_reads_each_member_bundle_once()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local currentPlan = plan(GENERATION_A, "marker-a")
  publishMember(cache, currentPlan, member(0, "stable.script", GENERATION_A), "outer-a")
  publishMember(cache, currentPlan, member(1, "second.script", GENERATION_A), "outer-a")
  local rawLoad = cache.loadModule
  local memberLoads = 0
  cache.loadModule = function(self, path)
    if type(path) == "string" and path:find("/generations/", 1, true) ~= nil then
      memberLoads = memberLoads + 1
    end
    return rawLoad(self, path)
  end
  local summary = preparation(cache, "global", "outer-a")
  Assert.isTrue(ScriptCacheWriter.stageSummary(summary, currentPlan) ~= nil)
  cache.loadModule = rawLoad
  summary:finishSuccess({ marker = currentPlan.marker })
  Assert.isTrue(ResidentArtifactFixture.materialize(summary))
  -- The summary proves and joins each member from one bundle read: 2 members,
  -- one load each, no second scan of the published payloads.
  Assert.equal(memberLoads, 2, "one bundle read per member for the whole summary")
  local index = assert(cache:loadLua(ScriptCache.activeIndexPath()))
  for _, entry in ipairs(index.resources) do
    Assert.isNil(entry.resourceHash, "the active index stores no per-resource hash: " .. tostring(entry.id))
  end
  Assert.deepEqual(index.memberAudioSequences, { ["0"] = {}, ["1"] = {} })
end

return { tests = T }
