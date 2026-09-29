-- Owns process-level test sharding policy and the disposable worker result protocol.

local LuaWriter = require("libs.codec.src.LuaWriter")

local Parallel = {}

Parallel.RUN_DIR_ENV = "PORTEMON_TEST_RUN_DIR"
Parallel.WORKERS_ENV = "PORTEMON_TEST_WORKERS"
Parallel.WORKER_ENV = "PORTEMON_TEST_WORKER"
Parallel.AGGREGATE_ENV = "PORTEMON_TEST_AGGREGATE"
Parallel.FRAGMENT_SCHEMA = "g4-test-worker-v1"

local function positiveInteger(value, what)
  assert(type(value) == "number" and value % 1 == 0 and value > 0, what .. " must be a positive integer")
  return value
end

local function positiveIntegerString(value, what)
  assert(type(value) == "string" and value:match("^[1-9][0-9]*$") ~= nil, what .. " must be a positive integer")
  return tonumber(value)
end

local function nonNegativeInteger(value, what)
  assert(type(value) == "number" and value % 1 == 0 and value >= 0, what .. " must be a non-negative integer")
end

local DEFAULT_FULL_RUN_JOBS = 4

local function isFocused(plan)
  return plan.layer ~= nil or plan.filter ~= nil or plan.tag ~= nil
end

---@param plan TestPlan
---@param selectedSuiteCount integer
---@param processorCount integer
---@return integer
function Parallel.effectiveJobs(plan, selectedSuiteCount, processorCount)
  assert(type(plan) == "table", "job policy needs a plan")
  nonNegativeInteger(selectedSuiteCount, "selected suite count")
  positiveInteger(processorCount, "processor count")
  local suiteBound = math.max(1, selectedSuiteCount)
  if plan.list or plan.serial or plan.selfTest or isFocused(plan) then
    return 1
  end
  return math.min(DEFAULT_FULL_RUN_JOBS, processorCount, suiteBound)
end

---@param env table<string, string>
---@return table
function Parallel.context(env)
  assert(type(env) == "table", "parallel environment must be a table")
  local runDir = env[Parallel.RUN_DIR_ENV]
  local workers = env[Parallel.WORKERS_ENV]
  local worker = env[Parallel.WORKER_ENV]
  local aggregate = env[Parallel.AGGREGATE_ENV]
  if runDir == nil and workers == nil and worker == nil and aggregate == nil then
    return { kind = "normal" }
  end
  assert(type(runDir) == "string" and runDir ~= "" and runDir:sub(1, 1) == "/", "parallel run directory is invalid")
  local count = positiveIntegerString(workers, "parallel worker count")
  assert(count <= DEFAULT_FULL_RUN_JOBS, "parallel worker count is unsupported")
  if aggregate ~= nil then
    assert(aggregate == "1" and worker == nil, "parallel aggregate environment is contradictory")
    return { kind = "aggregate", runDir = runDir, count = count }
  end
  local index = positiveIntegerString(worker, "parallel worker index")
  assert(index <= count, "parallel worker index is out of range")
  return { kind = "worker", runDir = runDir, index = index, count = count }
end

---@param entry { module: string, layer: string, path: string }
---@param shard { index: integer, count: integer }
---@return integer
function Parallel.workerFor(entry, shard)
  assert(type(entry) == "table" and type(entry.layer) == "string", "worker ownership needs a discovery entry")
  assert(type(shard) == "table", "worker ownership needs a shard")
  local count = positiveInteger(shard.count, "worker count")
  assert(shard.index >= 1 and shard.index <= count, "worker index is out of range")
  if count == 1 then
    return 1
  end
  if entry.layer == "graphics" then
    return 1
  elseif entry.layer == "acceptance" then
    return math.min(2, count)
  elseif entry.layer == "rom" then
    return math.min(3, count)
  elseif entry.layer == "unit" or entry.layer == "component" then
    return count
  end
  error("unknown test layer " .. entry.layer, 0)
end

function Parallel.owns(entry, shard)
  return Parallel.workerFor(entry, shard) == shard.index
end

function Parallel.fragmentPath(runDir, index)
  assert(type(runDir) == "string" and runDir ~= "", "fragment run directory is required")
  positiveInteger(index, "fragment worker index")
  return runDir .. "/worker-" .. index .. ".lua"
end

local function validateWrapper(wrapper, expectedIndex, expectedCount)
  assert(type(wrapper) == "table" and wrapper.schema == Parallel.FRAGMENT_SCHEMA, "invalid worker fragment schema")
  assert(type(wrapper.worker) == "table", "worker fragment identity is missing")
  local index = positiveInteger(wrapper.worker.index, "fragment worker index")
  local count = positiveInteger(wrapper.worker.count, "fragment worker count")
  assert(index == expectedIndex and count == expectedCount, "worker fragment identity does not match")
  assert(type(wrapper.run) == "table", "worker fragment run is missing")
  return wrapper
end

function Parallel.writeFragment(runDir, index, count, run)
  positiveInteger(index, "fragment worker index")
  positiveInteger(count, "fragment worker count")
  assert(index <= count, "fragment worker index is out of range")
  local path = Parallel.fragmentPath(runDir, index)
  local temporary = path .. ".tmp"
  local encoded = LuaWriter.encode({
    schema = Parallel.FRAGMENT_SCHEMA,
    worker = { index = index, count = count },
    run = run,
  })
  local handle, openError = io.open(temporary, "w")
  assert(handle ~= nil, "cannot open worker fragment: " .. tostring(openError))
  local ok, message = pcall(function()
    assert(handle:write(encoded))
    local closed, closeError = handle:close()
    handle = nil
    assert(closed, tostring(closeError))
  end)
  if not ok then
    if handle ~= nil then
      handle:close()
    end
    os.remove(temporary)
    error(message, 0)
  end
  local renamed, renameError = os.rename(temporary, path)
  if not renamed then
    os.remove(temporary)
    error("cannot publish worker fragment: " .. tostring(renameError), 0)
  end
end

function Parallel.readFragment(runDir, index, count)
  local path = Parallel.fragmentPath(runDir, index)
  local handle, openError = io.open(path, "r")
  assert(handle ~= nil, "cannot read worker fragment: " .. tostring(openError))
  local source = handle:read("*a")
  handle:close()
  local chunk, loadError
  if loadstring ~= nil then
    chunk, loadError = loadstring(source, "@" .. path)
    assert(chunk ~= nil, "cannot compile worker fragment: " .. tostring(loadError))
    setfenv(chunk, {})
  else
    chunk, loadError = load(source, "@" .. path, "t", {})
    assert(chunk ~= nil, "cannot compile worker fragment: " .. tostring(loadError))
  end
  local ok, wrapper = pcall(chunk)
  assert(ok, "cannot evaluate worker fragment: " .. tostring(wrapper))
  return validateWrapper(wrapper, index, count)
end

function Parallel.readFragments(runDir, count)
  positiveInteger(count, "worker count")
  local fragments = {}
  for index = 1, count do
    fragments[index] = Parallel.readFragment(runDir, index, count)
  end
  return fragments
end

local function resultRank(test)
  if test == "<load>" then
    return 1
  elseif test == "<beforeAll>" then
    return 2
  elseif test == "<afterAll>" then
    return 4
  end
  return 3
end

local function union(into, values)
  for name, enabled in pairs(values) do
    if enabled then
      into[name] = true
    end
  end
end

function Parallel.merge(fragments)
  assert(type(fragments) == "table" and #fragments > 0, "worker fragments are required")
  local count = nil
  local seen = {}
  local entries = {}
  local merged = {
    results = {},
    passed = 0,
    failed = 0,
    skipped = 0,
    duration = 0,
    workerCriticalPath = 0,
    byLayer = {},
    capabilities = {},
    selectedCapabilities = {},
    excludedCorpus = 0,
    suiteTimings = {},
  }
  local orderedFragments = {}
  for _, wrapper in ipairs(fragments) do
    assert(type(wrapper) == "table" and type(wrapper.worker) == "table", "worker fragment identity is missing")
    local workerCount = positiveInteger(wrapper.worker.count, "worker count")
    if count == nil then
      count = workerCount
    end
    local index = positiveInteger(wrapper.worker.index, "fragment worker index")
    assert(index <= count and workerCount == count, "worker fragment identity does not match")
    local checked = validateWrapper(wrapper, index, count)
    assert(not seen[index], "duplicate worker fragment")
    seen[index] = true
    orderedFragments[#orderedFragments + 1] = checked
  end
  assert(#fragments == count, "worker fragments are incomplete")
  for index = 1, count do
    assert(seen[index], "worker fragments are incomplete")
  end
  table.sort(orderedFragments, function(a, b)
    return a.worker.index < b.worker.index
  end)
  for _, wrapper in ipairs(orderedFragments) do
    local index = wrapper.worker.index
    local run = wrapper.run
    merged.passed = merged.passed + run.passed
    merged.failed = merged.failed + run.failed
    merged.skipped = merged.skipped + run.skipped
    merged.excludedCorpus = merged.excludedCorpus + run.excludedCorpus
    merged.duration = math.max(merged.duration, run.duration)
    merged.workerCriticalPath = merged.duration
    union(merged.selectedCapabilities, run.selectedCapabilities)
    for _, entry in ipairs(run.results) do
      entries[#entries + 1] = { entry = entry, worker = index }
    end
    for layer, counts in pairs(run.byLayer) do
      local target = merged.byLayer[layer]
      if target == nil then
        target = { passed = 0, failed = 0, skipped = 0, duration = 0 }
        merged.byLayer[layer] = target
      end
      target.passed = target.passed + counts.passed
      target.failed = target.failed + counts.failed
      target.skipped = target.skipped + counts.skipped
      target.duration = target.duration + counts.duration
    end
    for _, timing in ipairs(run.suiteTimings) do
      merged.suiteTimings[#merged.suiteTimings + 1] = timing
    end
  end
  table.sort(entries, function(a, b)
    if a.entry.module ~= b.entry.module then
      return a.entry.module < b.entry.module
    end
    local aRank, bRank = resultRank(a.entry.test), resultRank(b.entry.test)
    if aRank ~= bRank then
      return aRank < bRank
    end
    if a.entry.test ~= b.entry.test then
      return a.entry.test < b.entry.test
    end
    return a.worker < b.worker
  end)
  for _, item in ipairs(entries) do
    merged.results[#merged.results + 1] = item.entry
  end
  return merged
end

return Parallel
