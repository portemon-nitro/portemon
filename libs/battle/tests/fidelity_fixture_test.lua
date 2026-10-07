-- Independent fixture and provenance validation: complete records pass,
-- every incomplete provenance variant fails, execution validates before
-- running, and comparison reports structural divergence with both sides
-- attached.

local Assert = require("tests.support.Assert")
local Fixture = require("tests.support.BattleFidelityFixture")

local T = {}

---@return table<string, unknown> complete provenance for a source-derived oracle
local function provenance()
  return {
    basis = "source-derived",
    sourceRevision = "fixture-revision",
    sourceLocation = "fixture location",
    evidenceIdentity = "fixture evidence",
    oracleMethod = "hand transcription",
  }
end

---@param overrides table<string, unknown>? provenance fields to replace
---@return table<string, unknown> complete fixture record under test
local function record(overrides)
  local candidate = {
    provenance = provenance(),
    input = { seed = 1 },
    expected = { draws = { 1, 2 }, capture = { state = 3, calls = 2 } },
  }
  for key, value in pairs(overrides or {}) do
    candidate.provenance[key] = value
  end
  return candidate
end

function T.fixture_records_require_complete_provenance_input_and_expectations()
  Assert.isTrue(Fixture.validate(record()), "complete records validate")
  Assert.throws(function()
    Fixture.validate({ input = {}, expected = {} })
  end, "records without provenance never validate")
  Assert.throws(function()
    Fixture.validate({ provenance = { basis = "unknown-basis" }, input = {}, expected = {} })
  end, "records with an unknown basis never validate")
  for _, field in ipairs({ "sourceRevision", "sourceLocation", "oracleMethod" }) do
    Assert.throws(function()
      Fixture.validate(record({ [field] = "" }))
    end, "records with an empty " .. field .. " never validate")
  end
  Assert.throws(function()
    Fixture.validate(record({ basis = "observed-rom", evidenceIdentity = "" }))
  end, "dump-observed records without evidence identity never validate")
  Assert.isTrue(
    Fixture.validate(record({ basis = "observed-rom", evidenceIdentity = "ready dump member" })),
    "dump-observed records with evidence identity validate"
  )
  Assert.isTrue(Fixture.validate(record({ basis = "secondary-cross-check" })), "secondary cross-checks validate")
  local withoutInput = record()
  withoutInput.input = nil
  Assert.throws(function()
    Fixture.validate(withoutInput)
  end, "records without input never validate")
  local withoutExpected = record()
  withoutExpected.expected = nil
  Assert.throws(function()
    Fixture.validate(withoutExpected)
  end, "records without expectations never validate")
  Assert.throws(function()
    Fixture.validate("not-a-record")
  end, "scalar records never validate")
end

function T.fixture_execution_validates_first_and_returns_the_actual()
  local calls = 0
  local actual = Fixture.run(function()
    calls = calls + 1
    return { draws = { 1, 2 } }
  end, { provenance = provenance(), input = {}, expected = { draws = { 1, 2 } } })
  Assert.equal(calls, 1, "execution runs the oracle body exactly once")
  Assert.deepEqual(actual, { draws = { 1, 2 } }, "execution returns the oracle actual")

  local skipped = 0
  Assert.throws(function()
    Fixture.run(function()
      skipped = skipped + 1
      return {}
    end, { input = {}, expected = {} })
  end, "execution never runs under incomplete provenance")
  Assert.equal(skipped, 0, "invalid records never reach the oracle body")
  Assert.throws(function()
    Fixture.run("not-a-body", record())
  end, "execution requires its oracle body")
end

function T.fixture_comparison_reports_structural_divergence_with_both_sides()
  local expected = { draws = { 1, 2 }, nested = { amount = 48 } }
  Assert.isNil(
    Fixture.compare({ draws = { 1, 2 }, nested = { amount = 48 } }, { expected = expected }),
    "matching structures report no mismatch"
  )
  local leaf = Fixture.compare({ draws = { 1, 3 }, nested = { amount = 48 } }, { expected = expected })
  Assert.isTrue(type(leaf) == "table", "leaf divergence reports its mismatch")
  Assert.deepEqual(leaf.expected, expected, "mismatches carry the expected side")
  Assert.deepEqual(leaf.actual, { draws = { 1, 3 }, nested = { amount = 48 } }, "mismatches carry the actual side")
  local extra = Fixture.compare({ draws = { 1, 2 }, nested = { amount = 48 }, spare = true }, { expected = expected })
  Assert.isTrue(type(extra) == "table", "extra actual keys report their mismatch")
  local shorter = Fixture.compare({ draws = { 1 } }, { expected = expected })
  Assert.isTrue(type(shorter) == "table", "missing actual positions report their mismatch")
  Assert.throws(function()
    Fixture.compare({ draws = { 1, 2 } }, {})
  end, "comparisons without expectations never run")
end

return { tests = T }
