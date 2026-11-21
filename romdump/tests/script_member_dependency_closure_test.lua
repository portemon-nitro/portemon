-- Whole-generation script dependency closure: the summary derives each
-- member's transitive audio and asset-need closure from the published member
-- payloads, converges across cross-script cycles, and refuses a script target
-- that no planned resource provides.

local Assert = require("tests.support.Assert")
local ScriptCache = require("libs.assets.src.ScriptCache")
local ScriptCacheBuildFixture = require("tests.support.ScriptCacheBuildFixture")
local ScriptCacheWriter = require("romdump.src.digest.script.ScriptCacheWriter")
local ScriptCompileSession = require("romdump.src.digest.script.ScriptCompileSession")

local T = {}

local GENERATION = string.rep("a", 40)
local OUTER_GENERATION = "outer-generation-a"
local MARKER = "script-cache:rom-sha:" .. GENERATION

local function coverageFor(memberId, scripts)
  local records = {}
  for _, script in ipairs(scripts) do
    records[#records + 1] = {
      sourceId = string.format("hgss.scr_seq.%04d.%03d", memberId, script.scriptIndex),
      publicId = script.id,
      status = "complete",
      unsupported = {},
    }
  end
  return {
    source = { repository = "portemon", romSha1 = "rom-sha" },
    totals = {
      members = 1,
      scripts = #scripts,
      reachableInstructions = #scripts,
      supportedInstructions = #scripts,
      unsupportedInstructions = 0,
      malformedInstructions = 0,
    },
    opcodes = {},
    scripts = records,
  }
end

-- One compiler-shaped member resource: the dependency facts come from the
-- producer's own extraction over the final steps, never from a hand-written
-- expectation.
local function compiledResource(memberId, scriptIndex, id, steps)
  return {
    id = id,
    member = memberId,
    scriptIndex = scriptIndex,
    directDependencies = ScriptCompileSession.directDependencies(steps, {}, { memberId = memberId, id = id }),
    resource = {
      api = 1,
      id = id,
      metadata = {
        generated = true,
        source = { member = memberId, scriptIndex = scriptIndex },
        coverage = { complete = true, unsupportedCount = 0 },
      },
      steps = steps,
    },
    report = { complete = true, unsupportedCount = 0 },
  }
end

local function memberPayload(memberId, specs)
  local resources = {}
  for _, spec in ipairs(specs) do
    resources[#resources + 1] = compiledResource(memberId, spec.scriptIndex, spec.id, spec.steps)
  end
  return {
    memberId = memberId,
    marker = GENERATION .. ":member:" .. tostring(memberId),
    coverage = coverageFor(memberId, specs),
    resources = resources,
  }
end

-- A three-script chain across two members with a cycle between members and a
-- sound plus an asset need declared below the cycle.
local function planFor()
  local resources = {
    { id = "alpha.first", member = 0, scriptIndex = 0 },
    { id = "alpha.second", member = 0, scriptIndex = 1 },
    { id = "beta.third", member = 1, scriptIndex = 0 },
  }
  local result = {
    generationKey = GENERATION,
    marker = MARKER,
    version = "heartgold",
    sourcePath = "romfs/scr_seq.narc",
    romSha1 = "rom-sha",
    dependencies = {
      cacheFormat = ScriptCache.FORMAT,
      versionRomSha1 = "rom-sha",
      scrSeqNarc = { path = "scr_seq.narc", sha1 = "archive-sha" },
    },
    memberCount = 2,
    members = {
      { memberId = 0, marker = GENERATION .. ":member:0" },
      { memberId = 1, marker = GENERATION .. ":member:1" },
    },
    resources = resources,
  }
  result.index = {
    schema = ScriptCache.INDEX_SCHEMA,
    version = "heartgold",
    generation = GENERATION,
    marker = MARKER,
    memberCount = 2,
    scriptMemberCount = 2,
    skippedMemberCount = 0,
    scriptCount = #resources,
    resourceCount = #resources,
    resources = resources,
  }
  return result
end

local function chainMember0()
  return memberPayload(0, {
    {
      scriptIndex = 0,
      id = "alpha.first",
      steps = {
        { op = "play_music", music = "SEQ_GS_TITLE" },
        { op = "call", target = "alpha.second" },
        { op = "stop" },
      },
    },
    {
      scriptIndex = 1,
      id = "alpha.second",
      steps = {
        { op = "call_common", target = "beta.third" },
        { op = "stop" },
      },
    },
  })
end

local function chainMember1()
  return memberPayload(1, {
    {
      scriptIndex = 0,
      id = "beta.third",
      steps = {
        { op = "play_music", music = "SEQ_GS_NAMINORI" },
        { op = "call", target = "alpha.second" },
        { op = "legend_cutscene_bell_begin" },
        { op = "stop" },
      },
    },
  })
end

-- Drop the per-resource hash sidecar a lean publication no longer writes. The
-- summary must derive the closures from the published member payloads alone.
local function removeLegacySidecars(cache)
  for _, path in ipairs(ScriptCacheBuildFixture.filesUnder(cache, ScriptCache.generationDir(GENERATION))) do
    if ScriptCacheBuildFixture.fileName(path) == "resource-hashes.lua" then
      cache:remove(path)
    end
  end
end

local function publishMembers(cache, plan)
  ScriptCacheBuildFixture.publishMember(cache, OUTER_GENERATION, plan, chainMember0(), "chain-member-0")
  ScriptCacheBuildFixture.publishMember(cache, OUTER_GENERATION, plan, chainMember1(), "chain-member-1")
end

function T.transitive_closures_survive_sidecar_removal()
  local cache = ScriptCacheBuildFixture.cache()
  local plan = planFor()
  publishMembers(cache, plan)
  removeLegacySidecars(cache)

  ScriptCacheBuildFixture.publishSummary(cache, OUTER_GENERATION, plan, "summary")
  Assert.equal(assert(ScriptCache.loadActive(cache)).marker, MARKER, "the published summary activates its generation")

  local active = assert(ScriptCache.loadActive(cache))
  Assert.deepEqual(
    ScriptCache.audioSequencesForMember(active.index, 0),
    { "SEQ_GS_NAMINORI", "SEQ_GS_TITLE" },
    "the cycle converges to the complete sorted audio closure"
  )
  Assert.deepEqual(
    ScriptCache.audioSequencesForMember(active.index, 1),
    { "SEQ_GS_NAMINORI" },
    "a member reached through the cycle keeps its own sound and nothing it cannot reach"
  )
  Assert.deepEqual(
    ScriptCache.assetNeedsForMember(active.index, 0),
    { "field-effect:ho_oh_appearance" },
    "an asset need declared below the cycle reaches the member that can reach it"
  )
  Assert.deepEqual(
    ScriptCache.assetNeedsForMember(active.index, 1),
    { "field-effect:ho_oh_appearance" },
    "the declaring member keeps its own asset need"
  )
end

function T.unknown_script_target_fails_the_summary()
  local cache = ScriptCacheBuildFixture.cache()
  local plan = planFor()
  local member0 = chainMember0()
  member0.resources[2].directDependencies = {
    audioSequences = {},
    scriptTargets = { "nope.missing" },
    assetNeeds = {},
  }
  ScriptCacheBuildFixture.publishMember(cache, OUTER_GENERATION, plan, member0, "unknown-target-member-0")
  ScriptCacheBuildFixture.publishMember(cache, OUTER_GENERATION, plan, chainMember1(), "unknown-target-member-1")

  local ok, err = pcall(ScriptCacheBuildFixture.publishSummary, cache, OUTER_GENERATION, plan, "unknown-target-summary")
  Assert.isFalse(ok, "a summary with an unresolvable script target must fail")
  err = err --[[@as { code: string, context: table }]]
  Assert.equal(err.code, "SCRIPT_SUMMARY_INCOMPLETE")
  Assert.equal(err.context.id, "alpha.second", "the failure names the script holding the unknown target")
end

return { metadata = { capabilities = {} }, tests = T }
