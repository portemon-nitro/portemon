-- One aggregate script coverage report per published generation: its totals
-- match the verifier records the compiler produced, it keeps the unsupported
-- opcode detail, and no per-resource generated script carries provenance or a
-- second coverage copy.

local Assert = require("tests.support.Assert")
local Coverage = require("romdump.src.digest.script.Coverage")
local ScriptCache = require("libs.assets.src.ScriptCache")
local ScriptCacheBuildFixture = require("tests.support.ScriptCacheBuildFixture")
local ScriptFixture = require("tests.support.ScriptFixture")

local T = {}

local GENERATION = string.rep("a", 40)
local OUTER_GENERATION = "outer-generation-a"

local function supportedMemberBytes()
  return ScriptFixture.member({
    scripts = {
      {
        offset = 0x20,
        instructions = { { op = 73, args = { { value = 1500, width = 2 } } }, { op = 2, args = {} } },
      },
      { offset = 0x28, instructions = { { op = 2, args = {} } } },
    },
  })
end

-- SetTrainerFlag stays an explicit unsupported node, so the aggregate report
-- has one unsupported instruction to account for.
local function partiallySupportedMemberBytes()
  return ScriptFixture.member({
    scripts = {
      {
        offset = 0x20,
        instructions = {
          { op = 36, args = { { value = 1, width = 2 }, { value = 2, width = 2 } } },
          { op = 2, args = {} },
        },
      },
      { offset = 0x2C, instructions = { { op = 2, args = {} } } },
    },
  })
end

local function reportFiles(cache)
  local reports = {}
  for _, path in ipairs(ScriptCacheBuildFixture.allFiles(cache)) do
    if path:match("^staging/") == nil then
      local name = ScriptCacheBuildFixture.fileName(path)
      if name == "coverage.md" or name == "coverage.json" then
        reports[#reports + 1] = path
      end
    end
  end
  table.sort(reports)
  return reports
end

local function metricsOf(markdown)
  local metrics = {}
  for line in markdown:gmatch("[^\n]+") do
    local label, count = line:match("^| ([%a ]+) | (%d+) |$")
    if label ~= nil then
      metrics[label] = tonumber(count)
    end
  end
  return metrics
end

-- Every generated script body that was published for the generation, whether a
-- single resource or a member bundle.
local function publishedScripts(cache)
  local scripts = {}
  for _, path in ipairs(ScriptCacheBuildFixture.filesUnder(cache, ScriptCache.generationDir(GENERATION))) do
    if path:match("%.lua$") ~= nil then
      local module = cache:loadModule(path)
      if type(module) == "table" and module.kind == "field_script" then
        scripts[#scripts + 1] = module
      elseif
        type(module) == "table"
        and type(module.scripts) == "table"
        and type(module.scripts[1]) == "table"
        and module.scripts[1].steps ~= nil
      then
        for _, script in ipairs(module.scripts) do
          scripts[#scripts + 1] = script
        end
      end
    end
  end
  return scripts
end

function T.one_aggregate_report_matches_the_verifier_totals()
  local romFs = ScriptCacheBuildFixture.romFs({ supportedMemberBytes(), partiallySupportedMemberBytes() })
  local plan, cache, compiled =
    ScriptCacheBuildFixture.publishGeneration(romFs, GENERATION, OUTER_GENERATION, "coverage-report")
  Assert.equal(#plan.members, 2, "both members compile as independent jobs")

  local expected = Coverage.aggregate({
    compiled[plan.members[1].memberId].coverage,
    compiled[plan.members[2].memberId].coverage,
  })

  local reports = reportFiles(cache)
  Assert.equal(
    #reports,
    1,
    "exactly one aggregate coverage report persists; published reports: " .. table.concat(reports, ", ")
  )

  local markdown = cache:read(reports[1]) --[[@as string]]
  Assert.notNil(markdown, "the coverage report is readable text: " .. reports[1])
  local metrics = metricsOf(markdown)
  Assert.equal(metrics["Members"], expected.totals.members)
  Assert.equal(metrics["Scripts"], expected.totals.scripts)
  Assert.equal(metrics["Reachable instructions"], expected.totals.reachableInstructions)
  Assert.equal(metrics["Supported instructions"], expected.totals.supportedInstructions)
  Assert.equal(metrics["Unsupported instructions"], expected.totals.unsupportedInstructions)
  Assert.equal(metrics["Malformed instructions"], expected.totals.malformedInstructions)
  Assert.equal(metrics["Unsupported instructions"], 1, "the unsupported fixture instruction is reported once")
  Assert.isTrue(markdown:find("SetTrainerFlag", 1, true) ~= nil, "the report keeps unsupported opcode detail")

  local scripts = publishedScripts(cache)
  Assert.equal(#scripts, 4, "the generation publishes every source script body")
  for _, script in ipairs(scripts) do
    Assert.equal(script.metadata.generated, true, "a generated script keeps the generated discriminator")
    Assert.isNil(script.metadata.source, "a generated script stores no source provenance")
    Assert.isNil(script.metadata.generator, "a generated script stores no generator provenance")
    Assert.isNil(script.metadata.coverage, "a generated script stores no per-resource coverage copy")
  end
end

return { metadata = { capabilities = {} }, tests = T }
