-- Typed PC script operations dispatch only through their named HGSS services.

local Assert = require("tests.support.Assert")
local S = require("gen4.script")
local Runtime = require("libs.script.src.Runtime")
local ScriptErrors = require("libs.script.src.errors")

local T = { tests = {} }

local function harness()
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
  function services.pcTerminal:count(kind)
    calls[#calls + 1] = { "count", kind }
    return ({ mailbox = 4, photos = 2, seals = 0 })[kind]
  end
  function services.pcTerminal:openCapsules()
    calls[#calls + 1] = { "capsules" }
  end
  function services.pcTerminal:effect(action, prop)
    calls[#calls + 1] = { "effect", action, prop }
  end
  function services.pcTerminal:releaseEffect()
    calls[#calls + 1] = { "releaseEffect" }
  end
  function services.pcTerminal:hallOfFameStatus()
    calls[#calls + 1] = { "hofStatus" }
    return 3
  end
  function services.pcTerminal:openHallOfFame()
    calls[#calls + 1] = { "openHof" }
    error({ code = "FEATURE_UNAVAILABLE", message = "HOF viewer unavailable" })
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

function T.tests.count_and_status_nodes_write_the_source_results()
  local h = harness()
  Assert.equal(Runtime.executeNode({ op = "pc_count", kind = "mailbox", result = { id = "mail" } }, h.run), "continue")
  Assert.equal(Runtime.executeNode({ op = "pc_count", kind = "photos", result = { id = "photos" } }, h.run), "continue")
  Assert.equal(Runtime.executeNode({ op = "pc_count", kind = "seals", result = { id = "seals" } }, h.run), "continue")
  Assert.equal(Runtime.executeNode({ op = "pc_hof_status", result = { id = "hof" } }, h.run), "continue")
  Assert.deepEqual(h.writes, { mail = 4, photos = 2, seals = 0, hof = 3 })
  Assert.deepEqual(h.calls, {
    { "count", "mailbox" },
    { "count", "photos" },
    { "count", "seals" },
    { "hofStatus" },
  })
end

function T.tests.open_and_terminal_wait_use_the_registered_blocking_task()
  local h = harness()
  Assert.equal(Runtime.executeNode({ op = "pc_open", app = "storage", mode = 2 }, h.run), Runtime.OUTCOME_BLOCK)
  Assert.equal(h.run.blockTaskId, "task-1")
  Assert.deepEqual(h.tasks[1], {
    type = "pc_application",
    spec = { kind = "application", app = "storage", mode = 2 },
  })
  Assert.equal(
    Runtime.executeNode({ op = "pc_terminal_effect", action = "wait", prop = "pc_terminal" }, h.run),
    Runtime.OUTCOME_BLOCK
  )
  Assert.deepEqual(h.tasks[2], { type = "pc_application", spec = { kind = "terminal_wait" } })
end

function T.tests.capsules_and_terminal_effects_remain_synchronous_and_typed()
  local h = harness()
  Assert.equal(Runtime.executeNode({ op = "pc_capsules" }, h.run), Runtime.OUTCOME_CONTINUE)
  Assert.equal(
    Runtime.executeNode({ op = "pc_terminal_effect", action = "on", prop = "pc_terminal" }, h.run),
    Runtime.OUTCOME_CONTINUE
  )
  Assert.equal(Runtime.executeNode({ op = "pc_terminal_effect", action = "release" }, h.run), Runtime.OUTCOME_CONTINUE)
  Assert.deepEqual(h.calls, {
    { "capsules" },
    { "effect", "on", "pc_terminal" },
    { "releaseEffect" },
  })
end

function T.tests.unsupported_hall_of_fame_open_is_not_swallowed()
  local h = harness()
  local ok, err = pcall(Runtime.executeNode, { op = "pc_hof_open" }, h.run)
  Assert.isFalse(ok)
  Assert.equal(err.code, "FEATURE_UNAVAILABLE")
  Assert.deepEqual(h.calls, { { "openHof" } })
end

function T.tests.missing_pc_service_is_a_typed_composition_error()
  local h = harness()
  h.run.services.pcTerminal = nil
  local ok, err = pcall(Runtime.executeNode, { op = "pc_capsules" }, h.run)
  Assert.isFalse(ok)
  Assert.equal(err.code, ScriptErrors.SCRIPT_SERVICE_MISSING)
end

function T.tests.restore_overworld_is_a_foreground_return_boundary()
  local h = harness()
  Assert.deepEqual(S.restoreOverworld(), { op = "restore_overworld" })
  Assert.equal(Runtime.executeNode({ op = "restore_overworld" }, h.run), Runtime.OUTCOME_CONTINUE)
end

return T
