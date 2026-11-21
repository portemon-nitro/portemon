-- Script cache writer tests: one readable member bundle staged per member
-- through worker-owned preparations, single-transaction summary publication of
-- the active index plus the one aggregate coverage report, member/summary
-- readiness, and rollback on readback or publish failure.

local Assert = require("tests.support.Assert")
local ScriptCache = require("libs.assets.src.ScriptCache")
local ScriptCacheWriter = require("romdump.src.digest.script.ScriptCacheWriter")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local PreparedArtifact = require("romdump.src.build.PreparedArtifact")
local ResidentArtifactFixture = require("tests.support.ResidentArtifactFixture")

local T = {}
local GENERATION_A = string.rep("a", 40)
local GENERATION_B = string.rep("b", 40)

local function memberCoverage(memberId, ids)
  local scripts = {}
  for position, id in ipairs(ids) do
    scripts[#scripts + 1] = {
      sourceId = string.format("hgss.scr_seq.%04d.%03d", memberId, position - 1),
      publicId = id,
      status = "complete",
      unsupported = {},
    }
  end
  return {
    source = { repository = "portemon", romSha1 = "rom-sha" },
    totals = {
      members = 1,
      scripts = #ids,
      reachableInstructions = #ids,
      supportedInstructions = #ids,
      unsupportedInstructions = 0,
    },
    opcodes = {},
    scripts = scripts,
  }
end

-- Compiler-owned dependency facts arrive with every staged entry: the writer
-- persists exactly the provided record and never derives semantics from step
-- bodies, so builders carry explicit dependency arrays by default and only the
-- rejection tests below omit or corrupt them.
local function memberResource(memberId, id, scriptIndex, steps, directDependencies)
  return {
    id = id,
    member = memberId,
    scriptIndex = scriptIndex,
    directDependencies = directDependencies or { audioSequences = {}, scriptTargets = {}, assetNeeds = {} },
    resource = {
      api = 1,
      id = id,
      metadata = { generated = true },
      steps = steps or { { op = "stop" } },
    },
    report = { complete = true, unsupportedCount = 0 },
  }
end

local function member(memberId, id, generation, scriptIndex)
  return {
    memberId = memberId,
    marker = generation .. ":member:" .. tostring(memberId),
    coverage = memberCoverage(memberId, { id }),
    resources = { memberResource(memberId, id, scriptIndex or 0) },
  }
end

local function plan(generation, marker)
  local resources = {
    { id = "common.signpost", member = 3, scriptIndex = 0 },
    { id = "new_bark.lab_sign", member = 843, scriptIndex = 0 },
  }
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
      { memberId = 3, marker = generation .. ":member:3" },
      { memberId = 843, marker = generation .. ":member:843" },
    },
    resources = resources,
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
    resources = resources,
  }
  return result
end

local function preparation(cache, key, stageName, outerGeneration, epoch)
  return PreparedArtifact.new({
    cacheFs = cache,
    generationId = outerGeneration,
    epoch = epoch or 1,
    kind = "script-member",
    key = key,
    jobKey = "script-member:" .. key,
  })
end

local function publishMember(cache, currentPlan, staged, stageName, outerGeneration)
  local artifact = preparation(cache, tostring(staged.memberId), stageName, outerGeneration)
  local marker = assert(ScriptCacheWriter.stageMember(artifact, currentPlan, staged))
  Assert.equal(marker, staged.marker)
  artifact:finishSuccess({ marker = staged.marker })
  Assert.isTrue(ResidentArtifactFixture.materialize(artifact))
end

local function publishSummary(cache, currentPlan, stageName, outerGeneration)
  local artifact = preparation(cache, "global", stageName, outerGeneration)
  local marker = assert(ScriptCacheWriter.stageSummary(artifact, currentPlan))
  Assert.equal(marker, currentPlan.marker)
  artifact:finishSuccess({ marker = currentPlan.marker })
  Assert.isTrue(ResidentArtifactFixture.materialize(artifact))
end

local function publishGeneration(cache, generation, marker, prefix, outerGeneration)
  local currentPlan = plan(generation, marker)
  publishMember(cache, currentPlan, member(3, "common.signpost", generation), prefix .. "-member-3", outerGeneration)
  publishMember(
    cache,
    currentPlan,
    member(843, "new_bark.lab_sign", generation),
    prefix .. "-member-843",
    outerGeneration
  )
  publishSummary(cache, currentPlan, prefix .. "-summary", outerGeneration)
  return currentPlan
end

-- Every published file of one generation, sorted.
local function generationFiles(cache, generation)
  local directory = ScriptCache.generationDir(generation) .. "/"
  local prefix = cache:prefix() .. directory
  local files = {}
  for path in pairs(cache.backend.files) do
    if path:sub(1, #prefix) == prefix then
      files[#files + 1] = path:sub(#cache:prefix() + #directory + 1)
    end
  end
  table.sort(files)
  return files
end

local function resourceWithSteps(memberId, id, scriptIndex, steps, directDependencies)
  return memberResource(memberId, id, scriptIndex, steps, directDependencies)
end

local function stagedWithSteps(memberId, id, scriptIndex, steps, generation, directDependencies)
  local staged = member(memberId, id, generation, scriptIndex)
  staged.resources = { resourceWithSteps(memberId, id, scriptIndex, steps, directDependencies) }
  return staged
end

local function directFactsOf(cache, generation, memberId, scriptIndex)
  local bundle = assert(cache:loadModule(ScriptCache.memberPath(generation, memberId)))
  return bundle.direct[scriptIndex]
end

local function cycleCoverage(memberId, specs)
  local ids = {}
  for _, spec in ipairs(specs) do
    ids[spec.scriptIndex + 1] = spec.id
  end
  return memberCoverage(memberId, ids)
end

local function cycleMember(memberId, specs, generation)
  local staged = {
    memberId = memberId,
    marker = generation .. ":member:" .. tostring(memberId),
    coverage = cycleCoverage(memberId, specs),
    resources = {},
  }
  for _, spec in ipairs(specs) do
    staged.resources[#staged.resources + 1] =
      resourceWithSteps(memberId, spec.id, spec.scriptIndex, spec.steps, spec.deps)
  end
  return staged
end

local function cyclePlan(generation, marker)
  local resources = {
    { id = "alpha.first", member = 0, scriptIndex = 0 },
    { id = "alpha.second", member = 0, scriptIndex = 1 },
    { id = "beta.third", member = 1, scriptIndex = 0 },
  }
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
    resources = resources,
  }
  result.index = {
    schema = ScriptCache.INDEX_SCHEMA,
    version = "heartgold",
    generation = generation,
    marker = marker,
    memberCount = 2,
    scriptMemberCount = 2,
    skippedMemberCount = 0,
    scriptCount = 3,
    resourceCount = 3,
    resources = resources,
  }
  return result
end

-- 1. Each member publishes exactly one bundle and the summary publishes the
-- single active index plus the one aggregate coverage report; isReady then
-- reports the class complete.
T["member and summary publication completes the class"] = function()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local marker = "script-cache-v6:rom-sha:dep-sha"
  local currentPlan = publishGeneration(cache, GENERATION_A, marker, "complete", "outer-a")

  Assert.deepEqual(
    generationFiles(cache, GENERATION_A),
    { "0003.lua", "0843.lua" },
    "one readable bundle per nonempty member and nothing else"
  )
  local signpost = cache:loadModule(ScriptCache.memberPath(GENERATION_A, 3))
  Assert.equal(signpost.schema, ScriptCache.MEMBER_SCHEMA)
  Assert.equal(signpost.scripts[1].kind, "field_script")
  Assert.equal(signpost.scripts[1].id, "common.signpost")

  local active = assert(ScriptCache.loadActive(cache))
  Assert.equal(active.generation, GENERATION_A)
  Assert.equal(active.marker, marker)
  Assert.equal(active.index.resourceCount, 2)
  Assert.deepEqual(active.index.memberAudioSequences, { ["3"] = {}, ["843"] = {} })
  Assert.deepEqual(active.index.memberAssetNeeds, { ["3"] = {}, ["843"] = {} })

  local coverage = assert(cache:read(ScriptCache.coverageReportPath()))
  Assert.isTrue(coverage:find("| Members | 2 |", 1, true) ~= nil)
  Assert.isTrue(coverage:find("| Scripts | 2 |", 1, true) ~= nil)
  Assert.isTrue(ScriptCache.isReady(cache, marker))
  Assert.equal(currentPlan.marker, marker)
end

-- 2. A missing member bundle fails readiness.
T["readiness requires every indexed member bundle"] = function()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local marker = "script-cache-v6:rom-sha:dep-sha"
  publishGeneration(cache, GENERATION_A, marker, "ready", "outer-a")
  cache:remove(ScriptCache.memberPath(GENERATION_A, 843))
  Assert.isFalse(ScriptCache.isReady(cache, marker))
end

-- 3. A readback failure fails the member stage before anything is published.
T["readback failure stages no member"] = function()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local currentPlan = plan(GENERATION_A, "script-cache-v6:rom-sha:dep-sha")
  local bad = member(3, "common.signpost", GENERATION_A)
  bad.resources[1].resource = { api = 1, id = "other", steps = {} }
  local artifact = preparation(cache, "3", "bad-member", "outer-a")
  Assert.throws(function()
    ScriptCacheWriter.stageMember(artifact, currentPlan, bad)
  end)
  artifact:abort()
  Assert.isNil(cache:read(ScriptCache.memberPath(GENERATION_A, 3)))
  Assert.isNil(cache:loadLua(ScriptCache.activeIndexPath()))
end

-- 6. Member readiness proves the live member bundle: a published member reads
-- ready, while a missing bundle, an unknown member, a foreign generation, or a
-- corrupt bundle does not.
T["member readiness proves the live member bundle"] = function()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local marker = "script-cache-v6:rom-sha:dep-sha"
  local currentPlan = publishGeneration(cache, GENERATION_A, marker, "member-ready", "outer-a")
  Assert.isTrue(ScriptCacheWriter.isMemberReady(cache, currentPlan, 3))
  Assert.isTrue(ScriptCacheWriter.isMemberReady(cache, currentPlan, "843"))
  cache:remove(ScriptCache.memberPath(GENERATION_A, 843))
  local damaged, damagedReason = ScriptCacheWriter.isMemberReady(cache, currentPlan, 843)
  Assert.isFalse(damaged, "a member with a missing bundle is not ready")
  Assert.isTrue(type(damagedReason) == "string" and damagedReason ~= "", "the refusal names its cause")
  local unknown, unknownReason = ScriptCacheWriter.isMemberReady(cache, currentPlan, 999)
  Assert.isFalse(unknown, "an unplanned member is not ready")
  Assert.isTrue(type(unknownReason) == "string" and unknownReason ~= "", "the refusal names its cause")
  local foreignPlan = plan(GENERATION_B, "script-cache-v6:rom-sha:other-dep-sha")
  Assert.isFalse(
    ScriptCacheWriter.isMemberReady(cache, foreignPlan, 3),
    "a foreign generation bundle is not ready in this cache"
  )
  cache:write(ScriptCache.memberPath(GENERATION_A, 3), "not a lua bundle{{{")
  Assert.isFalse(ScriptCacheWriter.isMemberReady(cache, currentPlan, 3), "a corrupt bundle is not ready")
end

-- 7. The published bundle carries the compiler's direct dependency facts
-- verbatim, so the summary can join them without re-deriving semantics.
T["a member bundle carries the direct dependency facts"] = function()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local marker = "script-cache-v6:rom-sha:dep-sha"
  local currentPlan = plan(GENERATION_A, marker)
  local stages = {
    { op = "play_music", music = "SEQ_GS_NAMINORI" },
    { op = "label", name = "loop" },
    { op = "call", target = "loop" },
    { op = "call_common", target = "common.other" },
    { op = "goto_script", script = "common.third" },
    { op = "stop" },
  }
  publishMember(
    cache,
    currentPlan,
    stagedWithSteps(3, "common.signpost", 0, stages, GENERATION_A, {
      audioSequences = { "SEQ_GS_NAMINORI" },
      scriptTargets = { "common.other", "common.third" },
      assetNeeds = {},
    }),
    "deps-member-3",
    "outer-a"
  )
  local record = directFactsOf(cache, GENERATION_A, 3, 0)
  Assert.deepEqual(record.audioSequences, { "SEQ_GS_NAMINORI" }, "direct audio is the sorted unique symbol set")
  Assert.deepEqual(
    record.scriptTargets,
    { "common.other", "common.third" },
    "cross-script targets name the declared target ids"
  )
end

-- 8. Staging without compiler dependency metadata fails before anything is
-- published: persistence cannot repair a compiler omission.
T["staging without compiler dependency metadata fails and publishes no member"] = function()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local marker = "script-cache-v6:rom-sha:dep-sha"
  local currentPlan = plan(GENERATION_A, marker)
  local staged = stagedWithSteps(3, "common.signpost", 0, { { op = "stop" } }, GENERATION_A)
  staged.resources[1].directDependencies = nil
  local artifact = preparation(cache, "3", "missing-deps", "outer-a")
  Assert.throws(function()
    ScriptCacheWriter.stageMember(artifact, currentPlan, staged)
  end, "a missing dependency record must fail staging")
  artifact:abort()
  Assert.isNil(cache:read(ScriptCache.memberPath(GENERATION_A, 3)))
end

-- 9. Asset needs are mandatory compiler facts like the audio and target lists:
-- a record without them, or with an unsorted list, never reaches the stage.
T["staging without or with malformed asset needs fails and publishes no member"] = function()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local marker = "script-cache-v6:rom-sha:dep-sha"
  local currentPlan = plan(GENERATION_A, marker)
  local missing = stagedWithSteps(3, "common.signpost", 0, { { op = "stop" } }, GENERATION_A, {
    audioSequences = {},
    scriptTargets = {},
  })
  local first = preparation(cache, "3", "missing-needs", "outer-a")
  Assert.throws(function()
    ScriptCacheWriter.stageMember(first, currentPlan, missing)
  end, "a record without asset needs must fail staging")
  first:abort()
  local unsorted = stagedWithSteps(3, "common.signpost", 0, { { op = "stop" } }, GENERATION_A, {
    audioSequences = {},
    scriptTargets = {},
    assetNeeds = { "field-effect:b", "field-effect:a" },
  })
  local second = preparation(cache, "3", "unsorted-needs", "outer-a")
  Assert.throws(function()
    ScriptCacheWriter.stageMember(second, currentPlan, unsorted)
  end, "an unsorted asset need list must fail staging")
  second:abort()
  Assert.isNil(cache:read(ScriptCache.memberPath(GENERATION_A, 3)))
end

-- 10. Staging with malformed dependency metadata fails before anything is
-- published: unsorted arrays and non-array fields are not dependency facts.
T["staging with malformed dependency metadata fails and publishes no member"] = function()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local marker = "script-cache-v6:rom-sha:dep-sha"
  local currentPlan = plan(GENERATION_A, marker)
  local unsorted = stagedWithSteps(3, "common.signpost", 0, { { op = "stop" } }, GENERATION_A, {
    audioSequences = { "SEQ_GS_TITLE", "SEQ_GS_NAMINORI" },
    scriptTargets = {},
    assetNeeds = {},
  })
  local first = preparation(cache, "3", "unsorted-deps", "outer-a")
  Assert.throws(function()
    ScriptCacheWriter.stageMember(first, currentPlan, unsorted)
  end, "an unsorted dependency array must fail staging")
  first:abort()
  local mistyped = stagedWithSteps(3, "common.signpost", 0, { { op = "stop" } }, GENERATION_A, {
    audioSequences = {},
    scriptTargets = "common.other",
    assetNeeds = {},
  })
  local second = preparation(cache, "3", "mistyped-deps", "outer-a")
  Assert.throws(function()
    ScriptCacheWriter.stageMember(second, currentPlan, mistyped)
  end, "a non-array dependency field must fail staging")
  second:abort()
  Assert.isNil(cache:read(ScriptCache.memberPath(GENERATION_A, 3)))
end

-- 11. Transitive audio is a fixed point over the member graph: a cycle plus an
-- outgoing audio-bearing target converges to the complete closure for every
-- member with sorted unique sequences.
T["cyclic script graphs converge to the same transitive closure"] = function()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local marker = "script-cache-v6:rom-sha:dep-sha"
  local currentPlan = cyclePlan(GENERATION_A, marker)
  publishMember(
    cache,
    currentPlan,
    cycleMember(0, {
      {
        id = "alpha.first",
        scriptIndex = 0,
        steps = {
          { op = "play_music", music = "SEQ_GS_TITLE" },
          { op = "call", target = "alpha.second" },
          { op = "stop" },
        },
        deps = { audioSequences = { "SEQ_GS_TITLE" }, scriptTargets = { "alpha.second" }, assetNeeds = {} },
      },
      {
        id = "alpha.second",
        scriptIndex = 1,
        steps = {
          { op = "call_common", target = "beta.third" },
          { op = "stop" },
        },
        deps = { audioSequences = {}, scriptTargets = { "beta.third" }, assetNeeds = {} },
      },
    }, GENERATION_A),
    "cycle-member-0",
    "outer-a"
  )
  publishMember(
    cache,
    currentPlan,
    cycleMember(1, {
      {
        id = "beta.third",
        scriptIndex = 0,
        steps = {
          { op = "play_music", music = "SEQ_GS_NAMINORI" },
          { op = "call", target = "alpha.second" },
          { op = "stop" },
        },
        deps = {
          audioSequences = { "SEQ_GS_NAMINORI" },
          scriptTargets = { "alpha.second" },
          assetNeeds = { "field-effect:ho_oh_appearance" },
        },
      },
    }, GENERATION_A),
    "cycle-member-1",
    "outer-a"
  )
  publishSummary(cache, currentPlan, "cycle-summary", "outer-a")
  local active = assert(ScriptCache.loadActive(cache))
  Assert.deepEqual(
    active.index.memberAudioSequences,
    { ["0"] = { "SEQ_GS_NAMINORI", "SEQ_GS_TITLE" }, ["1"] = { "SEQ_GS_NAMINORI" } },
    "transitive closure converges through the cycle with sorted unique sequences"
  )
  Assert.deepEqual(
    active.index.memberAssetNeeds,
    { ["0"] = { "field-effect:ho_oh_appearance" }, ["1"] = { "field-effect:ho_oh_appearance" } },
    "asset needs reach every member that can reach the declaring script, through the same cycle"
  )
end

-- 12. A resource with no audio operations or cross-script calls publishes
-- explicit empty dependency arrays, never missing fields.
T["a silent resource publishes explicit empty dependencies"] = function()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local marker = "script-cache-v6:rom-sha:dep-sha"
  local currentPlan = plan(GENERATION_A, marker)
  publishMember(
    cache,
    currentPlan,
    stagedWithSteps(3, "common.signpost", 0, { { op = "stop" } }, GENERATION_A),
    "silent-member-3",
    "outer-a"
  )
  local record = directFactsOf(cache, GENERATION_A, 3, 0)
  Assert.deepEqual(record.audioSequences, {}, "silence carries an explicit empty audio set")
  Assert.deepEqual(record.scriptTargets, {}, "silence reaches no other script")
  Assert.deepEqual(record.assetNeeds, {}, "silence needs no assets")
end

-- 13. A declared cross-script target that resolves to no planned resource
-- fails the summary before any selector is replaced.
T["a summary over an unknown script target is refused"] = function()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local marker = "script-cache-v6:rom-sha:dep-sha"
  local currentPlan = plan(GENERATION_A, marker)
  publishMember(cache, currentPlan, member(3, "common.signpost", GENERATION_A), "known-member-3", "outer-a")
  publishMember(
    cache,
    currentPlan,
    stagedWithSteps(843, "new_bark.lab_sign", 0, {
      { op = "call_common", target = "nope.missing" },
      { op = "stop" },
    }, GENERATION_A, { audioSequences = {}, scriptTargets = { "nope.missing" }, assetNeeds = {} }),
    "dangling-member-843",
    "outer-a"
  )
  local summary = preparation(cache, "global", "dangling-summary", "outer-a")
  local failure = Assert.throws(function()
    ScriptCacheWriter.stageSummary(summary, currentPlan)
  end, "an unknown script target must refuse the summary")
  failure = failure --[[@as { code: string, context: table }]]
  Assert.equal(failure.code, "SCRIPT_SUMMARY_INCOMPLETE")
  Assert.equal(failure.context.id, "new_bark.lab_sign", "the refusal names the script holding the unknown target")
  summary:abort()
end

-- 14. A resource that targets itself converges: its own audio appears exactly
-- once in its member closure.
T["a self-targeting resource converges to its own audio"] = function()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local marker = "script-cache-v6:rom-sha:dep-sha"
  local currentPlan = cyclePlan(GENERATION_A, marker)
  publishMember(
    cache,
    currentPlan,
    cycleMember(0, {
      {
        id = "alpha.first",
        scriptIndex = 0,
        steps = {
          { op = "play_music", music = "SEQ_GS_TITLE" },
          { op = "call", target = "alpha.first" },
          { op = "stop" },
        },
        deps = { audioSequences = { "SEQ_GS_TITLE" }, scriptTargets = { "alpha.first" }, assetNeeds = {} },
      },
      {
        id = "alpha.second",
        scriptIndex = 1,
        steps = { { op = "stop" } },
      },
    }, GENERATION_A),
    "self-member-0",
    "outer-a"
  )
  publishMember(
    cache,
    currentPlan,
    cycleMember(1, {
      {
        id = "beta.third",
        scriptIndex = 0,
        steps = { { op = "stop" } },
      },
    }, GENERATION_A),
    "self-member-1",
    "outer-a"
  )
  publishSummary(cache, currentPlan, "self-summary", "outer-a")
  local active = assert(ScriptCache.loadActive(cache))
  Assert.deepEqual(
    active.index.memberAudioSequences,
    { ["0"] = { "SEQ_GS_TITLE" }, ["1"] = {} },
    "a self-cycle converges without duplication"
  )
end

-- 15. A summary over an incomplete member set is refused and the previous
-- active selection survives untouched.
T["a summary over incomplete members is refused and keeps the previous selection"] = function()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local marker = "script-cache-v6:rom-sha:dep-sha"
  publishGeneration(cache, GENERATION_A, marker, "refused-summary", "outer-a")
  local currentPlan = plan(GENERATION_A, marker)
  cache:remove(ScriptCache.memberPath(GENERATION_A, 3))
  local beforeIndex = cache:read(ScriptCache.activeIndexPath())
  local beforeReport = cache:read(ScriptCache.coverageReportPath())
  local err = Assert.throws(function()
    publishSummary(cache, currentPlan, "refused-summary", "outer-a")
  end)
  Assert.notNil(err, "a summary over an incomplete member set must be refused")
  Assert.equal(cache:read(ScriptCache.activeIndexPath()), beforeIndex, "the previous index survives a refused summary")
  Assert.equal(
    cache:read(ScriptCache.coverageReportPath()),
    beforeReport,
    "the previous report survives a refused summary"
  )
end

return { tests = T }
