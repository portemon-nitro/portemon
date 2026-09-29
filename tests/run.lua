-- Aggregate entry point of the test suite, invoked via `love app/ --test`
-- (`scripts/test.sh`). It owns only the approved discovery roots and their
-- default layers plus the wiring of argument parsing, capability detection,
-- execution, and reporting; those live in `tests/runner/`. There is no module
-- registry: a suite runs because the file exists.

local Capabilities = require("tests.runner.Capabilities")
local Cli = require("tests.runner.Cli")
local Progress = require("tests.runner.Progress")
local Parallel = require("tests.runner.Parallel")
local RepoFiles = require("tests.runner.RepoFiles")
local Report = require("tests.runner.Report")
local TestRunner = require("tests.runner.TestRunner")

-- The process environment, read lazily. Passed explicitly into the pure command
-- modules so their behavior never depends on an ambient lookup.
local ENV = setmetatable({}, {
  __index = function(_, name)
    return os.getenv(name)
  end,
})

-- `options` accepts roots, selection fields, and capabilities; `main` parses
-- the command mode and chooses roots before discovery.
---@param options table|nil
---@return table
local function runnerOptions(options)
  options = options or {}
  return {
    fs = RepoFiles.new(love.filesystem.getSourceBaseDirectory()),
    roots = options.roots,
    capabilities = options.capabilities,
    layer = options.layer,
    filter = options.filter,
    tag = options.tag,
    fullCorpus = options.fullCorpus,
    onResult = options.onResult,
    shard = options.shard,
  }
end

-- Discovery without execution, for `--list`.
---@param options table|nil
---@return table[] listing
local function list(options)
  return TestRunner.list(runnerOptions(options))
end

local function rootsFor(plan)
  if plan.selfTest then
    return { { path = "tests/runner/tests", layer = "unit" } }
  end
  return nil
end

-- The de-duplicated union of capability declarations from listed suites that
-- have at least one selected test. Load-error rows carry no tests, so they
-- contribute nothing.
---@param listing table[]
---@return table<string, boolean>
local function unionSelectedCapabilities(listing)
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

-- Fail before suite setup when a prepared run escapes the private data home
-- selected by the shell.
---@param preparedRequirements string|nil
---@return string|nil failure
local function checkDataHome(preparedRequirements)
  if type(preparedRequirements) ~= "string" or preparedRequirements == "" then
    return nil
  end
  local dataHome = ENV.XDG_DATA_HOME
  if type(dataHome) ~= "string" or dataHome == "" then
    return "prepared requirements have no private XDG_DATA_HOME"
  end
  if dataHome:sub(1, 1) ~= "/" then
    return "the private XDG_DATA_HOME must be an absolute path"
  end
  local saveDirectory = love.filesystem.getSaveDirectory()
  if saveDirectory == dataHome or saveDirectory:sub(1, #dataHome + 1) == dataHome .. "/" then
    return nil
  end
  return "the save directory " .. tostring(saveDirectory) .. " escaped the private test root " .. dataHome
end

-- The whole command: parse, detect capabilities, run or list, report, and
-- return the process exit status.
---@param argv string[]
---@return integer exitCode
local function main(argv)
  local ok, context = pcall(Parallel.context, ENV)
  if not ok then
    io.stderr:write("test: parallel infrastructure failure: " .. tostring(context) .. "\n")
    return 1
  end
  local plan, message = Cli.parse(argv, { env = ENV })
  if plan == nil then
    io.stderr:write("test: " .. tostring(message) .. "\n")
    return Cli.EXIT_USAGE
  end

  if plan.planMode then
    -- Machine-readable orchestration response for the shell entrypoint; a
    -- parse failure above already answered with the usage status. Planning
    -- discovers the same selected suites execution would run so cache
    -- preparation follows the selection, not the layer.
    if context.kind ~= "normal" then
      io.stderr:write("test: parallel infrastructure failure: plan mode cannot use a worker context\n")
      return 1
    end
    local roots = rootsFor(plan)
    local listing = list({ roots = roots, layer = plan.layer, filter = plan.filter, tag = plan.tag, fullCorpus = plan.fullCorpus })
    local processorCount = 1
    if love.system ~= nil and love.system.getProcessorCount ~= nil then
      processorCount = math.max(1, love.system.getProcessorCount())
    end
    local jobs = Parallel.effectiveJobs(plan, #listing, processorCount)
    local planOk, lines =
      pcall(Cli.renderPlan, plan, unionSelectedCapabilities(listing), jobs, TestRunner.selectedRequirements(listing))
    if not planOk then
      io.stderr:write("test: " .. tostring(lines) .. "\n")
      return Cli.EXIT_USAGE
    end
    print(table.concat(lines, "\n"))
    return 0
  end

  local shard = nil
  if context.kind == "worker" then
    shard = { index = context.index, count = context.count }
  end
  local preparedRequirements = ENV.PORTEMON_TEST_PREPARED_REQUIREMENTS
  local preparationError = checkDataHome(preparedRequirements)
  local function detect()
    local capabilities, versions = Capabilities.detect({
      env = ENV,
    })
    if plan.romSource ~= nil then
      capabilities.rom_source = true
    end
    return capabilities, versions
  end

  if context.kind == "worker" then
    local workerOk, workerError = pcall(function()
      if preparationError ~= nil then
        error("test: " .. preparationError, 0)
      end
      local capabilities = detect()
      local result = TestRunner.run(runnerOptions({
        capabilities = capabilities,
        layer = plan.layer,
        filter = plan.filter,
        tag = plan.tag,
        fullCorpus = plan.fullCorpus,
        roots = rootsFor(plan),
        shard = { index = context.index, count = context.count },
      }))
      Parallel.writeFragment(context.runDir, context.index, context.count, result)
    end)
    if not workerOk then
      io.stderr:write("test: parallel worker failure: " .. tostring(workerError) .. "\n")
      return 1
    end
    return 0
  end

  if context.kind == "aggregate" then
    local aggregateOk, aggregateError = pcall(function()
      local capabilities, versions = detect()
      local result = Parallel.merge(Parallel.readFragments(context.runDir, context.count))
      result.capabilities = capabilities
      result.versions = versions
      print(table.concat(Report.lines(result), "\n"))
      io.stdout:flush()
      local outcome = Cli.outcome(plan, capabilities, result)
      if outcome.warning ~= nil then
        io.stderr:write(outcome.warning .. "\n")
      end
      if outcome.failure ~= nil then
        io.stderr:write("test: " .. outcome.failure .. "\n")
      end
      return outcome.exitCode
    end)
    if not aggregateOk then
      io.stderr:write("test: parallel infrastructure failure: " .. tostring(aggregateError) .. "\n")
      return 1
    end
    return aggregateError
  end

  local capabilities, versions = detect()

  if plan.list then
    print(table.concat(Report.listingLines(list({
      roots = rootsFor(plan),
      layer = plan.layer,
      filter = plan.filter,
      tag = plan.tag,
      fullCorpus = plan.fullCorpus,
    })), "\n"))
    return 0
  end

  if preparationError ~= nil then
    io.stderr:write("test: " .. preparationError .. "\n")
    return 1
  end
  local progress = Progress.new(function(text)
    io.write(text)
    io.stdout:flush()
  end)
  local result = TestRunner.run(runnerOptions({
    capabilities = capabilities,
    layer = plan.layer,
    filter = plan.filter,
    tag = plan.tag,
    fullCorpus = plan.fullCorpus,
    roots = rootsFor(plan),
    onResult = function(entry)
      progress:record(entry)
    end,
  }))
  progress:finish()
  result.versions = versions
  print(table.concat(Report.lines(result), "\n"))

  -- Flush first so the warning banner cannot land inside the buffered report.
  io.stdout:flush()

  local outcome = Cli.outcome(plan, capabilities, result)
  if outcome.warning ~= nil then
    io.stderr:write(outcome.warning .. "\n")
  end
  if outcome.failure ~= nil then
    io.stderr:write("test: " .. outcome.failure .. "\n")
  end
  return outcome.exitCode
end

return { main = main, list = list }
