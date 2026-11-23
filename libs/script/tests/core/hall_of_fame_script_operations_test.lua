-- The source Hall of Fame script queries dispatch only through the PC
-- terminal: the showcase open suspends the script on the existing PC
-- application task, the entry-count query yields the one source tick it costs
-- and writes the newest recorded number, and the validity query answers in the
-- same tick.

local Assert = require("tests.support.Assert")
local Runtime = require("libs.script.src.Runtime")

local T = { tests = {} }

---@param options table terminal answers to serve
---@return table harness
local function harness(options)
  local writes = {}
  local tasks = {}
  local calls = {}
  local semantics = {
    evaluateValue = function(value)
      return value
    end,
    writeRef = function(ref, value)
      writes[ref.id] = value
    end,
  }
  local services = {
    pcApplications = {},
    pcTerminal = {},
  }
  function services.pcTerminal:hallOfFameCount()
    calls[#calls + 1] = { "hofCount" }
    return options.count
  end
  function services.pcTerminal:hallOfFameStatus()
    calls[#calls + 1] = { "hofStatus" }
    return options.status
  end
  -- The terminal's own open is the pre-existing synchronous entry; the source
  -- open must reach the blocking PC application task instead of it.
  function services.pcTerminal:openHallOfFame()
    calls[#calls + 1] = { "openHof" }
  end
  local run = {
    instance = { scriptId = "field.pc", mode = "foreground" },
    services = services,
    semantics = semantics,
    scheduler = {
      createTask = function(_, taskType, spec)
        tasks[#tasks + 1] = { type = taskType, spec = spec }
        return "task-1"
      end,
    },
    tick = 10,
    input = {},
  }
  return { calls = calls, run = run, tasks = tasks, writes = writes }
end

function T.tests.entry_count_yields_one_tick_and_writes_the_newest_recorded_number()
  local h = harness({ count = 7, status = 0 })
  Assert.equal(
    Runtime.executeNode({ op = "pc_hof_count", result = { id = "count" } }, h.run),
    Runtime.OUTCOME_YIELD_TICK,
    "the source entry-count query costs its one source tick"
  )
  Assert.deepEqual(h.writes, { count = 7 }, "the query publishes the newest recorded number")
  Assert.deepEqual(h.calls, { { "hofCount" } }, "the query borrows the PC terminal's own history")
end

function T.tests.entry_count_publishes_zero_for_an_unavailable_history()
  local h = harness({ count = 0, status = 1 })
  Assert.equal(
    Runtime.executeNode({ op = "pc_hof_count", result = { id = "count" } }, h.run),
    Runtime.OUTCOME_YIELD_TICK,
    "an unavailable history still costs its one source tick"
  )
  Assert.deepEqual(h.writes, { count = 0 }, "an unavailable history publishes zero")
end

function T.tests.showcase_open_waits_on_the_shared_pc_application_task()
  local h = harness({ count = 0, status = 0 })
  Assert.equal(
    Runtime.executeNode({ op = "pc_hof_open" }, h.run),
    Runtime.OUTCOME_BLOCK,
    "the source showcase open suspends the script instead of continuing the field"
  )
  Assert.equal(#h.tasks, 1, "the open creates exactly one blocking task")
  Assert.equal(h.tasks[1].type, "pc_application", "the open reuses the existing PC application task")
  Assert.equal(h.tasks[1].spec.app, "hallOfFame", "the task opens the showcase child with no mode")
  Assert.equal(h.tasks[1].spec.mode, nil, "the showcase child takes no application mode")
end

function T.tests.validity_query_answers_in_the_same_tick()
  local h = harness({ count = 0, status = 1 })
  Assert.equal(
    Runtime.executeNode({ op = "pc_hof_status", result = { id = "status" } }, h.run),
    Runtime.OUTCOME_CONTINUE,
    "the source validity query answers without waiting"
  )
  Assert.deepEqual(h.writes, { status = 1 }, "the query publishes its own status word")
end

return T
