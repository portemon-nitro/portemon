-- Generated script publication: one readable Lua bundle per nonempty source
-- member, ordered by source script index, with no per-script files, resource
-- hashes, per-member coverage sidecar, completion marker, or source provenance.

local Assert = require("tests.support.Assert")
local ScriptCache = require("libs.assets.src.ScriptCache")
local ScriptCacheBuildFixture = require("tests.support.ScriptCacheBuildFixture")
local ScriptFixture = require("tests.support.ScriptFixture")

local T = {}

local GENERATION = string.rep("a", 40)
local OUTER_GENERATION = "outer-generation-a"
local SCRIPT_MEMBER_ID = 0
local EMPTY_MEMBER_ID = 1

-- Three source scripts in one member: silence, a PlaySE, and silence again.
local function scriptMemberBytes()
  return ScriptFixture.member({
    scripts = {
      { offset = 0x20, instructions = { { op = 2, args = {} } } },
      {
        offset = 0x24,
        instructions = { { op = 73, args = { { value = 1500, width = 2 } } }, { op = 2, args = {} } },
      },
      { offset = 0x2C, instructions = { { op = 2, args = {} } } },
    },
  })
end

local function emptyMemberBytes()
  return ScriptFixture.member({ scripts = {} })
end

local function publishMemberAndSummary(romFs, cache, plan)
  local compiled = ScriptCacheBuildFixture.compileMember(romFs, plan, SCRIPT_MEMBER_ID)
  ScriptCacheBuildFixture.publishMember(cache, OUTER_GENERATION, plan, compiled, "member-bundle")
  ScriptCacheBuildFixture.publishSummary(cache, OUTER_GENERATION, plan, "member-bundle-summary")
  return compiled
end

local function readModules(cache, files)
  local bundles = {}
  local perScript = {}
  for _, path in ipairs(files) do
    if path:match("%.lua$") ~= nil then
      local module = cache:loadModule(path)
      if type(module) == "table" and module.kind == "field_script" then
        perScript[#perScript + 1] = path
      elseif
        type(module) == "table"
        and type(module.scripts) == "table"
        and type(module.scripts[1]) == "table"
        and module.scripts[1].steps ~= nil
      then
        bundles[#bundles + 1] = { path = path, module = module }
      end
    end
  end
  return bundles, perScript
end

function T.nonempty_member_publishes_one_ordered_bundle()
  local romFs = ScriptCacheBuildFixture.romFs({ scriptMemberBytes(), emptyMemberBytes() })
  local plan = ScriptCacheBuildFixture.plan(romFs, GENERATION)
  Assert.equal(#plan.members, 1, "the fixture plans one nonempty member")
  Assert.deepEqual(plan.skippedMembers, { EMPTY_MEMBER_ID }, "the fixture plans one empty member")

  local cache = ScriptCacheBuildFixture.cache()
  local compiled = publishMemberAndSummary(romFs, cache, plan)
  Assert.equal(#compiled.resources, 3, "the member job compiles every source script")

  local files = ScriptCacheBuildFixture.filesUnder(cache, ScriptCache.generationDir(GENERATION))
  local bundles, perScript = readModules(cache, files)
  Assert.equal(
    #bundles,
    1,
    "a nonempty script member publishes exactly one Lua bundle; published files: "
      .. table.concat(files, ", ")
  )
  Assert.equal(
    #perScript,
    0,
    "no script is published as its own Lua file; published files: " .. table.concat(files, ", ")
  )

  for _, path in ipairs(files) do
    local name = ScriptCacheBuildFixture.fileName(path)
    Assert.isTrue(name ~= "resource-hashes.lua", "no resource-hash sidecar is published: " .. path)
    Assert.isTrue(name ~= "coverage.lua", "no per-member coverage sidecar is published: " .. path)
    Assert.isTrue(name ~= "provenance.lua", "no per-member provenance file is published: " .. path)
    Assert.isTrue(name ~= "complete", "no per-member completion marker is published: " .. path)
  end

  local expected = plan.members[1].scripts
  local scripts = bundles[1].module.scripts
  Assert.equal(#scripts, #expected, "the bundle carries every source script")
  for position, entry in ipairs(expected) do
    local script = scripts[position]
    Assert.equal(script.id, entry.id, "bundle scripts keep their logical id in source order")
    Assert.equal(script.metadata.generated, true, "a generated script keeps the generated discriminator")
    Assert.isNil(script.metadata.source, "a generated script stores no source provenance")
    Assert.isNil(script.metadata.generator, "a generated script stores no generator provenance")
    Assert.isNil(script.metadata.coverage, "a generated script stores no per-resource coverage copy")
  end

  local active = assert(ScriptCache.loadActive(cache))
  Assert.equal(active.generation, GENERATION)
  local indexed = {}
  for _, entry in ipairs(active.index.resources) do
    if entry.member == SCRIPT_MEMBER_ID then
      indexed[#indexed + 1] = entry
    end
  end
  table.sort(indexed, function(left, right)
    return left.scriptIndex < right.scriptIndex
  end)
  Assert.equal(#indexed, 3, "the active index keeps the member's script count")
  for position, entry in ipairs(expected) do
    Assert.equal(indexed[position].id, entry.id, "the active index keeps the logical id")
    Assert.equal(indexed[position].scriptIndex, entry.scriptIndex, "the active index keeps the source script slot")
    Assert.isNil(indexed[position].resourceHash, "the active index stores no per-resource hash")
  end
end

return { metadata = { capabilities = {} }, tests = T }
