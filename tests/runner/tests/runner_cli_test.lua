-- Contract tests for the single test-command surface. `scripts/test.sh` is the
-- only test entrypoint, so one Lua module owns argument parsing, capability
-- requirements, the loud missing-ROM warning, and the combined exit status.
--
-- The rules under test:
--   * invalid layer/filter/source arguments exit 2 and never start a run;
--   * a default run without a dump is green but loudly warned, with the exact
--     skipped counts of the ROM-gated layers;
--   * a run that *requires* a dump (--layer rom, --layer acceptance, strict
--     mode, --rom-source) is an infrastructure failure when it is absent, never
--     a skip-success;
--   * strict graphics mode (PORTEMON_REQUIRE_GRAPHICS_TESTS) requires the
--     graphics capability when the selection includes the graphics layer, and
--     fails a whole-run selection that executed no graphics test;
--   * a failure in any layer, and a run that executed nothing at all, are
--     nonzero.

local Assert = require("tests.support.Assert")
local Cli = require("tests.runner.Cli")
local FakeCorpus = require("tests.runner.tests.support.FakeCorpus")
local Report = require("tests.runner.Report")
local TestRunner = require("tests.runner.TestRunner")

local T = {}

local function contains(text, needle, label)
  Assert.isTrue(
    tostring(text):find(needle, 1, true) ~= nil,
    (label or "text") .. " must mention " .. string.format("%q", needle) .. ", got: " .. tostring(text)
  )
end

function T.test_entrypoint_runs_the_incremental_builder_for_real_dependency_freshness()
  local handle = assert(io.open("scripts/test.sh", "rb"))
  local script = handle:read("*a")
  handle:close()

  contains(script, "love romdump/ --import-rom", "test entrypoint")
  contains(script, "love romdump/ --prepare-cache", "test entrypoint")
  contains(script, "--preparation-record", "test entrypoint")
  contains(script, "--dev", "test entrypoint")
  Assert.isNil(script:find("--check-derived-cache", 1, true))
end

function T.test_tooling_uses_run_scoped_temporary_directories()
  local handle = assert(io.open("scripts/test.sh", "rb"))
  local testScript = handle:read("*a")
  handle:close()

  contains(testScript, 'receipt_dir="$(mktemp -d -- "$test_root/preparation.XXXXXXXX")"', "test script")
  contains(testScript, 'fresh_root="$(mktemp -d)"', "test script")
  contains(testScript, 'run_dir="$(mktemp -d "${TMPDIR:-/tmp}/portemon-tests.XXXXXXXX")"', "test script")
end

-- The exhaustive corpus guard lives in the shell entrypoint: test.sh
-- notices the exact --full-corpus-census token, states the command is not
-- for regular work verification, warns about significant resource use,
-- demands an explicit yes, and only then reaches the runner. No other
-- option is inspected there; selection parsing stays in the runner.
function T.corpus_flag_requires_manual_confirmation_in_the_entrypoint()
  local handle = assert(io.open("scripts/test.sh", "rb"))
  local script = handle:read("*a")
  handle:close()

  contains(script, "--full-corpus-census", "corpus guard")
  contains(script, "NOT FOR REGULAR WORK VERIFICATION", "corpus guard")
  contains(script, "significant resources", "corpus guard")
  contains(script, "[y/N]", "corpus guard")
end

-- The shell must not re-implement option scanning: `scripts/test.sh` decides
-- whether to prepare the derived cache from the runner's machine-readable
-- plan response (`--plan`), not from a bash copy of the argument parser
-- coupled through exit codes.
function T.test_entrypoint_delegates_selection_to_the_runner()
  local handle = assert(io.open("scripts/test.sh", "rb"))
  local script = handle:read("*a")
  handle:close()

  contains(script, "--plan", "test entrypoint")
  Assert.isNil(script:find("rom_independent", 1, true), "no bash re-scan of --layer")
  Assert.isNil(script:find('case "${args[$index]}"', 1, true), "no bash option scanner")
  Assert.isNil(script:find("--slow", 1, true), "no bash re-scan of --slow")
  Assert.isNil(script:find("--tag", 1, true), "no bash re-scan of --tag")
end

-- Raises when parsing unexpectedly failed so a contract test fails on the
-- parser defect rather than on a nil index further down.
---@param argv string[]
---@param context table?
---@return TestPlan plan
local function parse(argv, context)
  local plan, message = Cli.parse(argv, context)
  Assert.isTrue(plan ~= nil, "expected a plan for " .. table.concat(argv, " ") .. ", got error: " .. tostring(message))
  return assert(plan)
end

---@param argv string[]
---@param context table?
---@return string
local function rejects(argv, context)
  local plan, message = Cli.parse(argv, context)
  Assert.isNil(plan, "expected no plan for: " .. table.concat(argv, " "))
  Assert.isTrue(type(message) == "string" and #message > 0, "a rejected argument list needs an actionable message")
  return assert(message)
end

local function hasCapability(plan, name)
  for _, required in ipairs(plan.requiredCapabilities) do
    if required == name then
      return true
    end
  end
  return false
end

-- The `prepare` value of a machine-readable plan response.
---@param lines string[]
---@return string
local function prepareOf(lines)
  for _, line in ipairs(lines) do
    local key, val = line:match("^([^=]+)=(.*)$")
    if key == "prepare" then
      return val
    end
  end
  error("plan has no prepare line", 2)
end

-- The de-duplicated union of capability declarations from listed suites that
-- have at least one selected test.
---@param listing table[]
---@return table<string, boolean>
local function selectedCapabilities(listing)
  local caps = {}
  for _, suite in ipairs(listing) do
    if #suite.tests > 0 then
      for _, name in ipairs(suite.capabilities) do
        caps[name] = true
      end
    end
  end
  return caps
end

-- A RunnerRun-shaped result. `layers` maps a layer name to its
-- passed/failed/skipped counts; totals and a matching `results` array are
-- derived so the same fixture drives both the exit policy and the report.
---@param layers table<string, { passed: integer|nil, failed: integer|nil, skipped: integer|nil }>
---@param extra table?
---@return RunnerRun
local function runOf(layers, extra)
  local run = {
    results = {},
    passed = 0,
    failed = 0,
    skipped = 0,
    duration = 0.5,
    byLayer = {},
    capabilities = {},
    selectedCapabilities = {},
    excludedCorpus = 0,
  }
  for layer, counts in pairs(layers) do
    local entry = { passed = counts.passed or 0, failed = counts.failed or 0, skipped = counts.skipped or 0 }
    entry.duration = 0.1
    run.byLayer[layer] = entry
    for _, status in ipairs({ "pass", "fail", "skip" }) do
      local field = status == "pass" and "passed" or (status == "fail" and "failed" or "skipped")
      for index = 1, entry[field] do
        run[field] = run[field] + 1
        run.results[#run.results + 1] = {
          module = layer .. "_" .. status .. "_test",
          test = status .. " " .. index,
          status = status,
          message = status == "pass" and "" or (status .. " reason"),
          layer = layer,
          duration = 0.01,
        }
      end
    end
  end
  for key, value in pairs(extra or {}) do
    run[key] = value
  end
  return run
end

local NO_DUMP = {}
local READY_DUMP = { rom_dump = true, derived_assets = true }

-- Every documented option parses into the plan the runner consumes.
function T.documented_options_parse()
  Assert.equal(parse({ "--layer", "unit" }).layer, "unit")
  Assert.equal(parse({ "--layer", "graphics" }).layer, "graphics")
  Assert.equal(parse({ "--filter", "warp" }).filter, "warp")
  Assert.equal(parse({ "--filter", "^libs%.rom" }).filter, "^libs%.rom")
  Assert.isTrue(parse({ "--list" }).list)

  local combined = parse({ "--test", "--layer", "unit", "--filter", "resolves door" })
  Assert.equal(combined.layer, "unit")
  Assert.equal(combined.filter, "resolves door")

  local context = {
    fileExists = function(path)
      return path == "/roms/hg.nds"
    end,
  }
  local sourced = parse({ "--rom-source", "/roms/hg.nds" }, context)
  Assert.equal(sourced.romSource, "/roms/hg.nds")
  Assert.isTrue(hasCapability(sourced, "rom_source"), "--rom-source requires the rom_source capability")

  Assert.equal(parse({ "--tag", "door" }).tag, "door", "--tag selects the tag")
  Assert.isTrue(parse({ "--full-corpus-census" }).fullCorpus, "--full-corpus-census selects the corpus tier")
  Assert.isFalse(parse({}).fullCorpus, "the default run is the regular tier")
  Assert.isNil(parse({}).tag, "no tag selection by default")
  Assert.isFalse(parse({}).serial, "concurrency defaults to automatic parallelism")
  Assert.isTrue(parse({ "--serial" }).serial, "--serial forces one-process execution")
  Assert.isTrue(parse({ "--serial", "--layer", "unit" }).serial, "redundant serial intent stays valid")
end

-- Invalid layer/filter/source arguments are rejected before anything
-- runs, with the usage exit status.
function T.invalid_arguments_are_rejected_with_exit_two()
  Assert.equal(Cli.EXIT_USAGE, 2)

  local exists = {
    fileExists = function()
      return true
    end,
  }
  local missing = {
    fileExists = function()
      return false
    end,
  }

  contains(rejects({ "--layer" }), "--layer", "missing layer value")
  contains(rejects({ "--layer", "bogus" }), "bogus", "unknown layer")
  contains(rejects({ "--layer", "--filter", "warp" }), "--layer", "layer consuming the next flag")
  contains(rejects({ "--filter" }), "--filter", "missing filter value")
  contains(rejects({ "--filter", "" }), "--filter", "empty filter")
  contains(rejects({ "--tag" }), "--tag", "missing tag value")
  contains(rejects({ "--tag", "" }), "--tag", "empty tag")
  contains(rejects({ "--tag", "--slow" }), "--tag", "tag consuming the next flag")
  contains(rejects({ "--rom-source" }, exists), "--rom-source", "missing source path")
  contains(rejects({ "--rom-source", "/no/such/rom.nds" }, missing), "/no/such/rom.nds", "unreadable source")
  contains(rejects({ "--layers", "unit" }), "--layers", "unknown option")
  contains(rejects({ "--jobs", "4" }), "--jobs", "removed worker-count option follows the generic unknown-option path")
  contains(rejects({ "--slow" }), "--slow", "removed slow-tier option follows the generic unknown-option path")
  contains(rejects({ "unit" }), "unit", "stray positional argument")
end

-- A filter is literal text, never a Lua pattern: metacharacters parse and
-- select literally instead of being diagnosed or interpreted.
function T.filter_metacharacters_are_literal_substrings()
  for _, filter in ipairs({ "(", "[", "%", "^libs%.rom", "warp" }) do
    Assert.equal(parse({ "--filter", filter }).filter, filter)
  end
end

-- With no dump, the default run stays green but says loudly what did
-- not run, with the exact skipped counts and both remediation commands.
function T.default_run_without_a_dump_is_green_and_loudly_warned()
  local plan = parse({})
  local run = runOf({
    unit = { passed = 1194 },
    component = { passed = 393 },
    graphics = { passed = 12 },
    rom = { skipped = 71 },
    acceptance = { skipped = 23 },
  })

  local outcome = Cli.outcome(plan, NO_DUMP, run)

  Assert.equal(outcome.exitCode, 0, "executed tests all passed, so the run is green")
  Assert.isNil(outcome.failure, "a missing optional capability is not an infrastructure failure")
  Assert.notNil(outcome.warning, "a skipped ROM-gated layer must never pass silently")
  contains(outcome.warning, "71", "warning reports the skipped ROM-conformance count")
  contains(outcome.warning, "23", "warning reports the skipped acceptance count")
  contains(outcome.warning, "scripts/buildcache.sh", "warning names the remediation command")
  contains(outcome.warning, "PORTEMON_REQUIRE_ROM_TESTS=1", "warning names the strict-mode command")
end

-- Strict mode turns the missing dump into an actionable failure.
function T.strict_mode_without_a_dump_fails()
  local plan = parse({}, { env = { PORTEMON_REQUIRE_ROM_TESTS = "1" } })
  local run = runOf(
    { unit = { passed = 1194 }, rom = { skipped = 71 }, acceptance = { skipped = 23 } },
    { selectedCapabilities = { rom_dump = true, derived_assets = true } }
  )

  local outcome = Cli.outcome(plan, NO_DUMP, run)

  Assert.isTrue(outcome.exitCode ~= 0, "strict mode must not exit zero when the ROM-gated layers were skipped")
  Assert.notNil(outcome.failure, "strict mode needs an actionable message")
  contains(outcome.failure, "rom_dump", "strict failure names the missing capability")
  contains(outcome.failure, "scripts/buildcache.sh", "strict failure names the remediation command")
end

-- Explicitly selecting a ROM-gated layer without a dump is an
-- infrastructure failure, not a green run of skips.
function T.selected_rom_gated_layer_without_a_dump_fails()
  for _, layer in ipairs({ "rom", "acceptance" }) do
    local plan = parse({ "--layer", layer })
    local run = runOf(
      { [layer] = { skipped = 23 } },
      { selectedCapabilities = { rom_dump = true, derived_assets = true } }
    )
    local outcome = Cli.outcome(plan, NO_DUMP, run)

    Assert.isTrue(outcome.exitCode ~= 0, "--layer " .. layer .. " without a dump must be nonzero")
    Assert.notNil(outcome.failure, "--layer " .. layer .. " without a dump needs an actionable message")
    Assert.isNil(outcome.warning, "a required capability reports a failure, not an optional-skip warning")
  end
end

-- Strict graphics mode turns an absent graphics capability into an actionable
-- failure instead of a green run of skips.
function T.graphics_strict_mode_without_the_capability_fails()
  local plan = parse({}, { env = { PORTEMON_REQUIRE_GRAPHICS_TESTS = "1" } })
  local run = runOf({ unit = { passed = 1194 }, graphics = { skipped = 45 } }, {
    selectedCapabilities = { graphics = true },
  })

  local outcome = Cli.outcome(plan, NO_DUMP, run)

  Assert.isTrue(outcome.exitCode ~= 0, "strict graphics mode must not exit zero when the graphics layer was skipped")
  Assert.notNil(outcome.failure, "strict graphics mode needs an actionable message")
  contains(outcome.failure, "graphics", "strict graphics failure names the missing capability")
end

-- Executed graphics tests satisfy the strict requirement whatever else runs.
function T.graphics_strict_run_with_executed_graphics_tests_stays_green()
  local plan = parse({}, { env = { PORTEMON_REQUIRE_GRAPHICS_TESTS = "1" } })
  local run = runOf({ unit = { passed = 1194 }, graphics = { passed = 45 } })

  local outcome = Cli.outcome(plan, { graphics = true }, run)

  Assert.equal(outcome.exitCode, 0, "executed graphics tests satisfy the strict requirement")
  Assert.isNil(outcome.failure)
end

-- Strict graphics mode is scoped to selections that include the graphics layer:
-- a `--layer unit` partial run and `--list` never trip it.
function T.graphics_strictness_does_not_trip_partial_runs_or_listing()
  local unitPlan = parse({ "--layer", "unit" }, { env = { PORTEMON_REQUIRE_GRAPHICS_TESTS = "1" } })
  Assert.isFalse(hasCapability(unitPlan, "graphics"), "a unit-only selection must not require the graphics capability")

  local unitOutcome = Cli.outcome(unitPlan, NO_DUMP, runOf({ unit = { passed = 1194 } }))
  Assert.equal(unitOutcome.exitCode, 0, "a unit-only partial run must stay green under strict graphics mode")
  Assert.isNil(unitOutcome.failure)

  local listing = parse({ "--list" }, { env = { PORTEMON_REQUIRE_GRAPHICS_TESTS = "1" } })
  Assert.isTrue(listing.list, "--list still parses under strict graphics mode")
end

-- The exit status is combined across layers -- a failure anywhere is a
-- failure of the run.
function T.exit_status_combines_failures_from_every_layer()
  for _, layer in ipairs({ "unit", "component", "graphics", "rom", "acceptance" }) do
    local run = runOf({ unit = { passed = 1194 }, [layer] = { passed = 3, failed = 1 } })
    local outcome = Cli.outcome(parse({}), READY_DUMP, run)
    Assert.equal(outcome.exitCode, 1, "a failure in the " .. layer .. " layer must exit nonzero")
  end
end

-- A run that executed nothing is never reported as success -- this is
-- what a filter that matches no test looks like.
function T.a_run_that_executed_nothing_is_not_success()
  local plan = parse({ "--filter", "no-such-test" })

  local outcome = Cli.outcome(plan, READY_DUMP, runOf({}))

  Assert.isTrue(outcome.exitCode ~= 0, "zero executed tests must not read as a green run")
  Assert.notNil(outcome.failure)
  contains(outcome.failure, "no-such-test", "the empty-selection failure names the filter")
end

-- The report names the ready game versions the run exercised.
function T.report_names_the_ready_versions_exercised()
  local run = runOf({ unit = { passed = 1 } }, { versions = { "heartgold", "soulsilver" } })

  local text = table.concat(Report.lines(run), "\n")

  contains(text, "heartgold", "report names the ready versions exercised")
  contains(text, "soulsilver", "report names the ready versions exercised")
end

-- `--full-corpus-census` runs only the full-corpus suites while keeping
-- nothing regular, and listings mark the corpus suites they include.
function T.full_corpus_flag_runs_only_corpus_suites_and_listing_marks_them()
  local plan = parse({ "--full-corpus-census" })
  Assert.isTrue(plan.fullCorpus, "--full-corpus-census is recorded in the plan")

  local corpus = FakeCorpus.new({
    ["fake/unit/fast_test.lua"] = { tests = { ["fast case"] = function() end } },
    ["fake/unit/census_test.lua"] = {
      metadata = { fullCorpus = true },
      tests = { ["census case"] = function() end },
    },
  })
  local roots = { corpus:root("fake/unit", "unit") }

  local run = TestRunner.run({ roots = roots, fs = corpus.fs, load = corpus.load, fullCorpus = plan.fullCorpus })

  Assert.equal(run.passed, 1, "--full-corpus-census runs only the corpus suite")
  Assert.equal(run.failed, 0, "excluding the regular suite is not a failure")
  Assert.equal(run.excludedCorpus, 0, "no corpus test is hidden under the corpus flag")

  local listing = TestRunner.list({ roots = roots, fs = corpus.fs, load = corpus.load, fullCorpus = true })

  Assert.equal(#listing, 1, "--list --full-corpus-census exposes only the corpus suite")
  Assert.isTrue(listing[1].fullCorpus == true, "the corpus suite is listed and flagged")
  contains(
    table.concat(Report.listingLines(listing), "\n"),
    "full-corpus",
    "listing output marks the corpus suite"
  )

  local regular = TestRunner.list({ roots = roots, fs = corpus.fs, load = corpus.load })

  Assert.equal(#regular, 1, "the default listing exposes only the regular suite")
  Assert.isNil(
    table.concat(Report.listingLines(regular), "\n"):find("full-corpus", 1, true),
    "regular listing output marks no tier"
  )
end

-- A focus that matches nothing fails with the empty-selection message.
function T.unmatched_focus_reports_an_empty_selection()
  local plan = parse({ "--filter", "census" })
  local run = runOf({})

  local outcome = Cli.outcome(plan, READY_DUMP, run)

  Assert.isTrue(outcome.exitCode ~= 0, "a selection matching nothing must not read as green")
  Assert.notNil(outcome.failure, "an empty focus needs an actionable message")
  contains(outcome.failure, "matched nothing", "the failure states the filter matched nothing")
end

-- A focus that only matches hidden full-corpus tests fails loudly with
-- the remediation instead of claiming nothing matched.
function T.corpus_only_focus_explains_the_corpus_gate()
  local plan = parse({ "--filter", "census" })
  local run = runOf({}, { excludedCorpus = 3 })

  local outcome = Cli.outcome(plan, READY_DUMP, run)

  Assert.isTrue(outcome.exitCode ~= 0, "a selection hidden by the corpus gate must not read as green")
  Assert.notNil(outcome.failure, "a corpus-only focus needs an actionable message")
  contains(outcome.failure, "full-corpus", "the failure names the corpus tier")
  contains(outcome.failure, "--full-corpus-census", "the failure instructs adding --full-corpus-census")
  Assert.isNil(
    tostring(outcome.failure):find("matched nothing", 1, true),
    "the failure must not claim the filter matched nothing, got: " .. tostring(outcome.failure)
  )
end

-- Cache preparation follows the suites actually selected: a narrowed
-- unit-only focus prepares nothing even with no explicit layer.
function T.narrow_unit_filter_plan_skips_cache_preparation()
  local corpus = FakeCorpus.new({
    ["fake/unit/alpha_test.lua"] = { tests = { ["unit case"] = function() end } },
    ["fake/rom/cache_test.lua"] = {
      metadata = { capabilities = { "rom_dump", "derived_assets" }, derivedAssets = { "map:7" } },
      tests = { ["cache case"] = function() end },
    },
  })
  local roots = { corpus:root("fake/rom", "rom"), corpus:root("fake/unit", "unit") }

  local plan = parse({ "--filter", "unit case" })
  Assert.isNil(plan.layer, "no explicit layer keeps the whole-run selection")

  local listing = TestRunner.list({ roots = roots, fs = corpus.fs, load = corpus.load, filter = plan.filter })

  Assert.equal(#listing, 1, "the filter selects only the unit suite")
  Assert.equal(
    prepareOf(Cli.renderPlan(plan, selectedCapabilities(listing), 1, TestRunner.selectedRequirements(listing))),
    "none",
    "a unit-only selection skips preparation"
  )
end

-- Explicit ROM strictness follows the selected capabilities: a raw-dump-only
-- focus prepares nothing and tolerates the absent prepared cache, while a
-- missing rom_dump still fails.
function T.raw_rom_focus_does_not_require_prepared_assets()
  local corpus = FakeCorpus.new({
    ["fake/rom/raw_test.lua"] = {
      metadata = { capabilities = { "rom_dump" } },
      tests = { ["raw case"] = function() end },
    },
  })
  local roots = { corpus:root("fake/rom", "rom") }

  local plan = parse({ "--layer", "rom", "--filter", "raw case" })
  local listing =
    TestRunner.list({ roots = roots, fs = corpus.fs, load = corpus.load, layer = plan.layer, filter = plan.filter })
  local caps = selectedCapabilities(listing)

  Assert.isTrue(caps.rom_dump == true, "the selection keeps rom_dump")
  Assert.isFalse(caps.derived_assets == true, "the selection omits derived_assets")
  Assert.equal(prepareOf(Cli.renderPlan(plan, caps, 1, {})), "none", "a raw-dump-only selection skips preparation")

  local run = runOf({ rom = { passed = 1 } }, { selectedCapabilities = { rom_dump = true } })

  local outcome = Cli.outcome(plan, { rom_dump = true }, run)

  Assert.equal(outcome.exitCode, 0, "a present rom_dump satisfies a raw-dump-only selection")
  Assert.isNil(outcome.failure)

  local missing = Cli.outcome(plan, {}, run)

  Assert.isTrue(missing.exitCode ~= 0, "an absent rom_dump still fails")
  contains(tostring(missing.failure), "rom_dump", "the failure names the missing capability")
end

-- Listing never prepares the derived cache, even when the listing includes
-- corpus cache consumers under the corpus flag.
function T.listing_never_prepares_the_cache_even_for_corpus_consumers()
  local corpus = FakeCorpus.new({
    ["fake/rom/cache_test.lua"] = {
      metadata = {
        capabilities = { "rom_dump", "complete_derived_cache" },
        derivedAssets = { "complete" },
        fullCorpus = true,
      },
      tests = { ["cache case"] = function() end },
    },
  })
  local roots = { corpus:root("fake/rom", "rom") }

  local plan = parse({ "--list", "--full-corpus-census" })
  local listing = TestRunner.list({ roots = roots, fs = corpus.fs, load = corpus.load, fullCorpus = plan.fullCorpus })

  Assert.equal(#listing, 1, "--list --full-corpus-census exposes the corpus cache consumer")
  Assert.equal(
    prepareOf(Cli.renderPlan(plan, selectedCapabilities(listing), 1, TestRunner.selectedRequirements(listing))),
    "none",
    "a listing executes nothing, so it prepares nothing"
  )
end

-- Suites that read the prebuilt generated cache declare it, so
-- selection-aware planning prepares the cache for them but not for a
-- raw-dump-only control.
function T.generated_cache_consumers_declare_scoped_requirements()
  local targets = {
    "field_message_cache_test",
    "field_dialogue_test",
    "following_mon_visual_resolution_test",
    "mon_version_coverage_test",
    "neighbor_traversal_test",
    "new_bark_filler_zone_identity_test",
  }
  local files = {}
  for _, name in ipairs(targets) do
    files["fake/rom/" .. name .. ".lua"] = require("tests.rom." .. name)
  end
  files["fake/rom/field_warps_test.lua"] = require("tests.rom.field_warps_test")
  files["fake/rom/field_messages_test.lua"] = require("tests.rom.field_messages_test")
  local corpus = FakeCorpus.new(files)
  local roots = { corpus:root("fake/rom", "rom") }

  local missing = {}
  local unprepared = {}
  for _, name in ipairs(targets) do
    local listing = TestRunner.list({ roots = roots, fs = corpus.fs, load = corpus.load, filter = name })
    Assert.equal(#listing, 1, "filter " .. name .. " selects exactly its suite")
    local caps = selectedCapabilities(listing)
    if caps.derived_assets ~= true then
      missing[#missing + 1] = name
    end
    local plan = parse({ "--filter", name })
    local scope = prepareOf(Cli.renderPlan(plan, caps, 1, TestRunner.selectedRequirements(listing)))
    if scope ~= "assets" and scope ~= "complete" then
      unprepared[#unprepared + 1] = name
    end
  end
  Assert.equal(#missing, 0, "suites missing derived_assets: " .. table.concat(missing, ", "))
  Assert.equal(#unprepared, 0, "suites whose selection skips preparation: " .. table.concat(unprepared, ", "))

  local control = TestRunner.list({ roots = roots, fs = corpus.fs, load = corpus.load, filter = "field_messages_test" })

  Assert.equal(#control, 1, "the control filter selects exactly its suite")
  local controlCaps = selectedCapabilities(control)
  Assert.isFalse(controlCaps.derived_assets == true, "a raw-dump-only control omits derived_assets")
  local controlPlan = parse({ "--filter", "field_messages_test" })
  Assert.equal(
    prepareOf(Cli.renderPlan(controlPlan, controlCaps, 1, TestRunner.selectedRequirements(control))),
    "none",
    "a raw-dump-only control skips preparation"
  )
end

-- A tag focus is an explicit narrowing like a filter: under strict
-- graphics it must not trip the whole-run execution counter when the
-- selection contains no graphics test.
function T.focused_tag_run_without_graphics_selection_stays_green_under_strict_graphics()
  local plan = parse({ "--tag", "door" }, { env = { PORTEMON_REQUIRE_GRAPHICS_TESTS = "1" } })
  local run = runOf({ unit = { passed = 1 } }, { selectedCapabilities = {} })

  local outcome = Cli.outcome(plan, { graphics = true }, run)

  Assert.equal(outcome.exitCode, 0, "a tag focus that selects no graphics test must stay green")
  Assert.isNil(outcome.failure)
end

-- A tag focus that matches only hidden corpus tests reports the corpus
-- gate, not a missing graphics execution, under strict graphics.
function T.corpus_only_tag_focus_reports_the_corpus_gate_not_missing_graphics()
  local plan = parse({ "--tag", "census" }, { env = { PORTEMON_REQUIRE_GRAPHICS_TESTS = "1" } })
  local run = runOf({}, { excludedCorpus = 3 })

  local outcome = Cli.outcome(plan, { graphics = true }, run)

  Assert.isTrue(outcome.exitCode ~= 0, "a selection hidden by the corpus gate must not read as green")
  Assert.notNil(outcome.failure, "a corpus-only focus needs an actionable message")
  contains(outcome.failure, "--full-corpus-census", "the failure instructs adding --full-corpus-census")
  Assert.isNil(
    tostring(outcome.failure):find("no graphics test was executed", 1, true),
    "the failure must not claim no graphics test executed, got: " .. tostring(outcome.failure)
  )
end

-- Selection-aware strictness is not a relaxation: when the selected work
-- declares the graphics capability, the absent capability still fails.
function T.selected_graphics_capability_is_still_required_under_strict_graphics()
  local plan = parse({}, { env = { PORTEMON_REQUIRE_GRAPHICS_TESTS = "1" } })
  local run = runOf({ graphics = { passed = 1 } }, { selectedCapabilities = { graphics = true } })

  local outcome = Cli.outcome(plan, NO_DUMP, run)

  Assert.isTrue(outcome.exitCode ~= 0, "selected graphics work without the capability must be nonzero")
  Assert.notNil(outcome.failure, "selected graphics work without the capability needs an actionable message")
  contains(outcome.failure, "graphics", "the failure names the missing capability")
end

-- The independent execution counter survives selection-awareness: an
-- unfiltered, untagged strict run that executed no graphics test fails even
-- when the capability is available and nothing selected graphics work.
function T.unfiltered_strict_run_with_no_executed_graphics_test_still_fails()
  local plan = parse({}, { env = { PORTEMON_REQUIRE_GRAPHICS_TESTS = "1" } })
  Assert.isNil(plan.filter, "the whole-run selection has no filter focus")
  Assert.isNil(plan.tag, "the whole-run selection has no tag focus")
  local run = runOf({ unit = { passed = 1 } }, { selectedCapabilities = {} })

  local outcome = Cli.outcome(plan, { graphics = true }, run)

  Assert.isTrue(outcome.exitCode ~= 0, "a whole run that executed no graphics test must fail under strict graphics")
  Assert.notNil(outcome.failure, "a whole run that executed no graphics test needs an actionable message")
  contains(outcome.failure, "no graphics test was executed", "the failure names the missing execution")
end

-- Raw field-message/font facts need no prepared cache, while the
-- cache-backed message sibling and the dialogue suite prepare exactly
-- their declared bounded closures.
function T.raw_message_focus_skips_cache_preparation_while_cache_backed_message_facts_prepare_it()
  local files = {
    ["fake/rom/field_messages_test.lua"] = require("tests.rom.field_messages_test"),
    ["fake/rom/field_dialogue_test.lua"] = require("tests.rom.field_dialogue_test"),
  }
  local corpus = FakeCorpus.new(files)
  local roots = { corpus:root("fake/rom", "rom") }

  local rawPlan = parse({ "--filter", "field_messages_test" })
  local rawListing = TestRunner.list({ roots = roots, fs = corpus.fs, load = corpus.load, filter = rawPlan.filter })
  Assert.equal(#rawListing, 1, "the raw message filter selects exactly its suite")
  local rawCaps = selectedCapabilities(rawListing)
  Assert.equal(
    prepareOf(Cli.renderPlan(rawPlan, rawCaps, 1, TestRunner.selectedRequirements(rawListing))),
    "none",
    "a raw message focus skips cache preparation"
  )

  local dialoguePlan = parse({ "--filter", "field_dialogue_test" })
  local dialogueListing =
    TestRunner.list({ roots = roots, fs = corpus.fs, load = corpus.load, filter = dialoguePlan.filter })
  Assert.equal(#dialogueListing, 1, "the dialogue filter selects exactly its suite")
  Assert.equal(
    prepareOf(
      Cli.renderPlan(
        dialoguePlan,
        selectedCapabilities(dialogueListing),
        1,
        TestRunner.selectedRequirements(dialogueListing)
      )
    ),
    "assets",
    "a cache-backed dialogue focus prepares its declared bounded closure"
  )

  files["fake/rom/field_message_cache_test.lua"] = require("tests.rom.field_message_cache_test")
  local cacheCorpus = FakeCorpus.new(files)
  local cacheRoots = { cacheCorpus:root("fake/rom", "rom") }
  local cachePlan = parse({ "--filter", "field_message_cache_test" })
  local cacheListing = TestRunner.list({
    roots = cacheRoots,
    fs = cacheCorpus.fs,
    load = cacheCorpus.load,
    filter = cachePlan.filter,
  })
  Assert.equal(#cacheListing, 1, "the cache message filter selects exactly its suite")
  Assert.equal(
    prepareOf(
      Cli.renderPlan(cachePlan, selectedCapabilities(cacheListing), 1, TestRunner.selectedRequirements(cacheListing))
    ),
    "assets",
    "a cache-backed message focus prepares its declared family closure"
  )
end

-- The follower producer corpus needs only the raw dump: its selection
-- carries rom_dump without derived_cache and skips cache preparation.
-- It is a full-corpus suite, so the selection needs the corpus flag.
function T.follower_producer_focus_needs_no_derived_cache()
  local corpus = FakeCorpus.new({
    ["fake/rom/following_mon_visual_corpus_test.lua"] = require("tests.rom.following_mon_visual_corpus_test"),
  })
  local roots = { corpus:root("fake/rom", "rom") }

  local plan = parse({ "--full-corpus-census", "--filter", "following_mon_visual_corpus_test" })
  local listing = TestRunner.list({
    roots = roots,
    fs = corpus.fs,
    load = corpus.load,
    fullCorpus = plan.fullCorpus,
    filter = plan.filter,
  })

  Assert.equal(#listing, 1, "the producer filter selects exactly its suite")
  local caps = selectedCapabilities(listing)
  Assert.isTrue(caps.rom_dump == true, "the selection keeps rom_dump")
  Assert.isFalse(caps.derived_cache == true, "a raw producer selection omits derived_cache")
  Assert.equal(
    prepareOf(Cli.renderPlan(plan, caps, 1, TestRunner.selectedRequirements(listing))),
    "none",
    "a raw producer selection skips preparation"
  )
end

-- The runner-only flag is an exclusive mode: it parses into the plan, stays
-- off by default, composes with listing and narrowing selectors, conflicts
-- with the corpus census and explicit sources, and prepares no product
-- fixture on its own.
function T.runner_only_flag_parses_as_an_exclusive_mode()
  Assert.isFalse(parse({}).selfTest, "the default run stays regular")
  Assert.isTrue(parse({ "--self-test" }).selfTest, "--self-test selects the runner-only mode")
  Assert.isTrue(parse({ "--self-test", "--list" }).selfTest, "listing composes with the runner-only mode")
  Assert.equal(
    parse({ "--self-test", "--filter", "runner_cli" }).filter,
    "runner_cli",
    "a filter narrows the chosen mode instead of opting into another one"
  )
  Assert.equal(
    prepareOf(Cli.renderPlan(parse({ "--self-test" }), {}, 1, {})),
    "none",
    "a runner-only selection prepares no product fixture"
  )

  contains(rejects({ "--self-test", "--full-corpus-census" }), "--full-corpus-census", "corpus conflict")
  local existing = {
    fileExists = function()
      return true
    end,
  }
  contains(
    rejects({ "--self-test", "--rom-source", "/roms/hg.nds" }, existing),
    "--rom-source",
    "source conflict"
  )
  contains(
    rejects({ "--self-test", "--rom-source", "/roms/hg.nds", "--fresh" }, existing),
    "--fresh",
    "cold-rerun conflict"
  )
end

-- A runner-only selection excluded the product graphics suites on purpose:
-- strict graphics mode must not fail it for executing no graphics test.
function T.runner_only_selection_is_exempt_from_the_whole_run_graphics_counter()
  local plan = parse({ "--self-test" }, { env = { PORTEMON_REQUIRE_GRAPHICS_TESTS = "1" } })
  local run = runOf({ unit = { passed = 3 } }, { selectedCapabilities = {} })

  local outcome = Cli.outcome(plan, NO_DUMP, run)

  Assert.equal(outcome.exitCode, 0, "an executed runner-only selection stays green under strict graphics")
  Assert.isNil(outcome.failure)
end

-- The actual entrypoint lists exactly the runner's own subtree in this mode:
-- every listed module lives beneath it, and the listing exits zero without
-- preparing a product fixture.
function T.self_test_list_mode_lists_only_the_runner_subtree()
  local handle = assert(io.popen("scripts/test.sh --self-test --list 2>&1; echo \"__exit=$?\""))
  local output = handle:read("*a")
  handle:close()

  local exit = output:match("__exit=(%d+)%s*$")
  Assert.equal(exit, "0", "self-test listing must exit zero, got:\n" .. tostring(output))

  local suites = 0
  -- Lua patterns have no alternation: capture the layer token plainly and
  -- accept only known layers, so header lines such as `Running tests...`
  -- never count as suites.
  local knownLayers = { unit = true, component = true, graphics = true, rom = true, acceptance = true }
  for line in tostring(output):gmatch("[^\n]+") do
    local module, layer = line:match("^(%S+)%s+(%a+)%s")
    if module ~= nil and knownLayers[layer] then
      suites = suites + 1
      Assert.isTrue(
        module:find("tests.runner.tests.", 1, true) == 1,
        "self-test listing exposes only the runner subtree, got: " .. module
      )
    end
  end
  Assert.isTrue(suites > 0, "self-test listing must expose at least one suite")
end

-- An explicit cold rerun is only meaningful against a named source: asking
-- for it without one is a usage error that names the missing source option.
function T.fresh_mode_requires_an_explicit_source()
  local plan, message = Cli.parse({ "--fresh" })

  Assert.isNil(plan, "--fresh without a source must not parse")
  Assert.isTrue(type(message) == "string" and #message > 0, "a rejected --fresh needs an actionable message")
  Assert.isTrue(
    tostring(message):find("--rom-source", 1, true) ~= nil,
    "the failure must name the required source option, got: " .. tostring(message)
  )
  Assert.isNil(
    tostring(message):find("unknown option", 1, true),
    "the failure must state the source rule, not an unknown option, got: " .. tostring(message)
  )
end

-- An explicit cold rerun alongside a source parses into the plan the shell
-- consumes, keeping every other selector untouched.
function T.fresh_mode_parses_alongside_an_explicit_source()
  local context = {
    fileExists = function(path)
      return path == "/roms/hg.nds"
    end,
  }
  local plan = parse({ "--rom-source", "/roms/hg.nds", "--fresh", "--filter", "dialogue" }, context)

  Assert.equal(plan.romSource, "/roms/hg.nds")
  Assert.isTrue(plan.fresh, "--fresh is recorded in the plan")
  Assert.equal(plan.filter, "dialogue", "a fresh rerun keeps the remaining selectors")
  Assert.isTrue(hasCapability(plan, "rom_source"), "--rom-source still requires the rom_source capability")
end

-- Suites declare the exact derived closures they need, so the runner can
-- union only what the actual selection covers: a narrowed focus carries its
-- own requirements while a hidden corpus suite contributes nothing.
function T.selected_suites_carry_their_declared_derived_requirements()
  local corpus = FakeCorpus.new({
    ["fake/rom/map_test.lua"] = {
      metadata = { capabilities = { "rom_dump" }, derivedAssets = { "map:7" } },
      tests = { ["map case"] = function() end },
    },
    ["fake/rom/census_audit_test.lua"] = {
      metadata = { capabilities = { "rom_dump" }, derivedAssets = { "complete" }, fullCorpus = true },
      tests = { ["audit case"] = function() end },
    },
  })
  local roots = { corpus:root("fake/rom", "rom") }

  local listing = TestRunner.list({ roots = roots, fs = corpus.fs, load = corpus.load, filter = "map case" })

  Assert.equal(#listing, 1, "the map filter selects exactly its suite")
  Assert.deepEqual(listing[1].derivedAssets, { "map:7" }, "the selected suite keeps its declared closure")

  local unfiltered = TestRunner.list({ roots = roots, fs = corpus.fs, load = corpus.load })

  Assert.equal(#unfiltered, 1, "the regular tier hides the corpus audit suite")
  Assert.deepEqual(unfiltered[1].derivedAssets, { "map:7" }, "a hidden corpus suite contributes no requirement")

  local full = TestRunner.list({ roots = roots, fs = corpus.fs, load = corpus.load, fullCorpus = true })

  Assert.equal(#full, 1, "--full-corpus-census exposes only the corpus suite")
  local union = {}
  for _, suite in ipairs(full) do
    for _, requirement in ipairs(suite.derivedAssets) do
      union[requirement] = true
    end
  end
  Assert.isNil(union["map:7"], "the corpus union keeps no regular closure")
  Assert.isTrue(union["complete"] == true, "the corpus union keeps the complete request")
end

-- The requirement union is deduplicated and sorted so repeated runs of the
-- same selection assemble identical preparation arguments.
function T.selected_requirements_are_deduplicated_and_sorted()
  local plan = parse({})
  local lines = Cli.renderPlan(plan, nil, 1, { "map:7", "map:7", "bootstrap" })
  local requires = {}
  for _, line in ipairs(lines) do
    local key, value = line:match("^([^=]+)=(.*)$")
    if key == "require" then
      requires[#requires + 1] = value
    end
  end
  Assert.deepEqual(requires, { "bootstrap", "map:7" }, "the union is deduplicated and sorted")
  Assert.equal(prepareOf(lines), "assets", "a partial union prepares its partial scope")
end

-- The historical cache capability name is not a requirement source: a suite
-- that still declares it instead of an explicit closure is malformed, so the
-- listing names the suite and the stale capability and plans no complete
-- preparation from it.
function T.stale_cache_capability_is_a_listing_error_not_a_complete_request()
  local corpus = FakeCorpus.new({
    ["fake/rom/stale_test.lua"] = {
      metadata = { capabilities = { "rom_dump", "derived_cache" } },
      tests = { ["stale case"] = function() end },
    },
  })
  local roots = { corpus:root("fake/rom", "rom") }
  local listing = TestRunner.list({ roots = roots, fs = corpus.fs, load = corpus.load, filter = "stale case" })

  Assert.equal(#listing, 1, "the stale filter selects exactly its suite")
  Assert.notNil(listing[1].error, "a stale capability declaration must fail the listing")
  contains(listing[1].error, "stale_test", "the failure names the suite")
  contains(listing[1].error, "derived_cache", "the failure names the stale capability")
  Assert.deepEqual(TestRunner.selectedRequirements(listing), {}, "a malformed suite contributes no requirement")
  local plan = parse({ "--filter", "stale case" })
  Assert.equal(
    prepareOf(Cli.renderPlan(plan, selectedCapabilities(listing), 1, TestRunner.selectedRequirements(listing))),
    "none",
    "a malformed selection prepares nothing"
  )
end

-- A scoped suite prepares exactly its declared closure: the plan carries
-- only the listed roots at the partial scope, never a complete request.
function T.scoped_suite_prepares_only_its_declared_closure()
  local corpus = FakeCorpus.new({
    ["fake/rom/map_test.lua"] = {
      metadata = { capabilities = { "rom_dump", "derived_assets" }, derivedAssets = { "map:7" } },
      tests = { ["map case"] = function() end },
    },
  })
  local roots = { corpus:root("fake/rom", "rom") }
  local listing = TestRunner.list({ roots = roots, fs = corpus.fs, load = corpus.load, filter = "map case" })

  Assert.equal(#listing, 1, "the map filter selects exactly its suite")
  Assert.isNil(listing[1].error, "a declared closure must list cleanly")
  local plan = parse({ "--filter", "map case" })
  local lines = Cli.renderPlan(plan, selectedCapabilities(listing), 1, TestRunner.selectedRequirements(listing))
  local requires = {}
  for _, line in ipairs(lines) do
    local key, value = line:match("^([^=]+)=(.*)$")
    if key == "require" then
      requires[#requires + 1] = value
    end
  end
  Assert.deepEqual(requires, { "map:7" }, "the plan carries only the declared closure")
  Assert.equal(prepareOf(lines), "assets", "a scoped selection prepares its partial scope")
end

-- A complete claim without the explicit corpus tier is malformed: the
-- listing names the offending suite instead of planning a complete
-- preparation for a regular selection.
function T.complete_claims_without_the_corpus_tier_are_listing_errors()
  local variants = {
    complete_capability_without_tier = {
      metadata = { capabilities = { "rom_dump", "complete_derived_cache" }, derivedAssets = { "complete" } },
    },
    complete_requirement_without_tier = {
      metadata = { capabilities = { "rom_dump", "derived_assets" }, derivedAssets = { "complete" } },
    },
  }
  for label, config in pairs(variants) do
    local corpus = FakeCorpus.new({
      ["fake/rom/" .. label .. "_test.lua"] = {
        metadata = config.metadata,
        tests = { ["mislabeled case"] = function() end },
      },
    })
    local roots = { corpus:root("fake/rom", "rom") }
    local listing = TestRunner.list({ roots = roots, fs = corpus.fs, load = corpus.load, filter = "mislabeled case" })
    Assert.equal(#listing, 1, label .. " selects exactly its suite")
    Assert.notNil(listing[1].error, label .. " must fail the listing without the corpus tier")
    contains(listing[1].error, label .. "_test", "the failure names the suite")
    Assert.deepEqual(TestRunner.selectedRequirements(listing), {}, label .. " contributes no requirement")
  end
end

-- The genuine corpus audit keeps its exhaustive request, but only under the
-- explicit corpus tier: the regular selection hides it and plans nothing
-- complete, while the corpus selection carries the declared request.
function T.corpus_selection_keeps_the_declared_complete_request()
  local corpus = FakeCorpus.new({
    ["fake/rom/audit_test.lua"] = {
      metadata = {
        capabilities = { "rom_dump", "complete_derived_cache" },
        derivedAssets = { "complete" },
        fullCorpus = true,
      },
      tests = { ["audit case"] = function() end },
    },
  })
  local roots = { corpus:root("fake/rom", "rom") }
  local regular = TestRunner.list({ roots = roots, fs = corpus.fs, load = corpus.load })
  Assert.equal(#regular, 0, "the regular selection hides the corpus audit")
  Assert.deepEqual(TestRunner.selectedRequirements(regular), {}, "a hidden audit contributes no requirement")

  local plan = parse({ "--full-corpus-census" })
  local listed = TestRunner.list({ roots = roots, fs = corpus.fs, load = corpus.load, fullCorpus = plan.fullCorpus })
  Assert.equal(#listed, 1, "the corpus selection exposes the audit")
  Assert.isNil(listed[1].error, "a tiered complete claim must list cleanly")
  local lines = Cli.renderPlan(plan, selectedCapabilities(listed), 1, TestRunner.selectedRequirements(listed))
  Assert.equal(prepareOf(lines), "complete", "the corpus selection prepares the complete scope")
end

-- Runner self-test modules verify the runner itself: even one that declares
-- a product requirement contributes nothing to a regular selection, while
-- the runner-only selection still exposes it.
function T.runner_self_test_suites_contribute_no_regular_requirements()
  local corpus = FakeCorpus.new({
    ["tests/runner/tests/fake_probe_test.lua"] = {
      metadata = { capabilities = { "rom_dump" }, derivedAssets = { "complete" } },
      tests = { ["probe case"] = function() end },
    },
  })
  local roots = { corpus:root("tests/runner/tests", "unit") }
  local regular = TestRunner.list({ roots = roots, fs = corpus.fs, load = corpus.load })
  Assert.equal(#regular, 0, "the regular selection excludes the runner self-test")
  Assert.deepEqual(TestRunner.selectedRequirements(regular), {}, "an excluded self-test contributes no requirement")

  local own = TestRunner.list({ roots = roots, fs = corpus.fs, load = corpus.load, selfTest = true })
  Assert.equal(#own, 1, "the runner-only selection exposes its own suite")
end

-- A malformed requirement never reaches preparation: the plan call fails
-- before any import.
function T.malformed_requirements_are_usage_failures_before_import()
  local plan = parse({})
  for _, bad in ipairs({ "", "plan.lua", "maps/7/complete", "map: 7", "map:7:extra", " :7" }) do
    local ok, err = pcall(Cli.renderPlan, plan, nil, 1, { bad })
    Assert.isFalse(ok, "requirement " .. string.format("%q", bad) .. " must not plan")
    Assert.isTrue(
      tostring(err):find("invalid cache requirement", 1, true) ~= nil,
      "the failure names the requirement, got: " .. tostring(err)
    )
  end
end

return { tests = T }
