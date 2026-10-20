-- The asset-needs registry maps a need kind to a preparer, steps live jobs
-- within a time budget, isolates failures, and cancels jobs whose need is no
-- longer wanted, each exactly once.

local Assert = require("tests.support.Assert")
local AssetNeedsRegistry = require("libs.hgss.src.field.AssetNeedsRegistry")

local T = { tests = {} }

-- A manual clock the fake jobs advance, so budgets are deterministic.
local function newClock()
  local clock = { now = 0 }
  function clock.read()
    return clock.now
  end
  return clock
end

-- A preparer whose jobs need `steps` calls to finish, each costing one clock
-- unit; it records every start, step and cancel.
local function newPreparer(clock, steps, log)
  local preparer = {}
  function preparer.start(id)
    log[#log + 1] = "start:" .. id
    local remaining = steps
    local job = {}
    function job.step()
      clock.now = clock.now + 1
      remaining = remaining - 1
      log[#log + 1] = "step:" .. id
      return remaining <= 0
    end
    function job.cancel()
      log[#log + 1] = "cancel:" .. id
    end
    return job
  end
  return preparer
end

local function clear(log)
  for index = #log, 1, -1 do
    log[index] = nil
  end
end

local function count(log, entry)
  local total = 0
  for _, line in ipairs(log) do
    if line == entry then
      total = total + 1
    end
  end
  return total
end

function T.tests.enrolling_an_unregistered_kind_returns_false()
  local registry = AssetNeedsRegistry.new()
  Assert.isFalse(registry:enroll("field-effect:ho_oh_appearance"))
end

function T.tests.enrolling_a_malformed_key_raises()
  local registry = AssetNeedsRegistry.new()
  Assert.throws(function()
    registry:enroll("nocolon")
  end)
end

function T.tests.registering_a_kind_twice_raises()
  local registry = AssetNeedsRegistry.new()
  local clock, log = newClock(), {}
  registry:register("a", newPreparer(clock, 1, log))
  Assert.throws(function()
    registry:register("a", newPreparer(clock, 1, log))
  end)
end

function T.tests.enrolling_twice_starts_one_job()
  local clock, log = newClock(), {}
  local registry = AssetNeedsRegistry.new({ clock = clock.read })
  registry:register("a", newPreparer(clock, 2, log))
  Assert.isTrue(registry:enroll("a:x"))
  Assert.isTrue(registry:enroll("a:x"))
  Assert.equal(count(log, "start:x"), 1)
end

function T.tests.a_preparer_that_declines_an_id_is_not_enrolled()
  local registry = AssetNeedsRegistry.new()
  registry:register("a", {
    start = function()
      return nil
    end,
  })
  Assert.isFalse(registry:enroll("a:x"))
end

function T.tests.step_runs_jobs_in_enrollment_order_within_the_budget()
  local clock, log = newClock(), {}
  local registry = AssetNeedsRegistry.new({ clock = clock.read })
  registry:register("a", newPreparer(clock, 3, log))
  registry:enroll("a:first")
  registry:enroll("a:second")
  clear(log)
  registry:step(2)
  Assert.deepEqual(log, { "step:first", "step:first" }, "the budget of two units is spent on the first job")
  clear(log)
  registry:step(3)
  Assert.deepEqual(
    log,
    { "step:first", "step:second", "step:second" },
    "the first job finishes, the second continues until the budget is spent"
  )
end

function T.tests.finished_jobs_are_polled_once_per_step_and_can_resume()
  local clock, log = newClock(), {}
  local registry = AssetNeedsRegistry.new({ clock = clock.read })
  local ready = true
  registry:register("a", {
    start = function(id)
      local job = {}
      function job.step()
        clock.now = clock.now + 1
        log[#log + 1] = "step:" .. id
        if ready then
          return true
        end
        ready = true
        return false
      end
      function job.cancel()
        log[#log + 1] = "cancel:" .. id
      end
      return job
    end,
  })
  registry:enroll("a:x")
  registry:step(10)
  Assert.equal(count(log, "step:x"), 1, "a job that is ready after one unit is done")
  registry:step(10)
  Assert.equal(count(log, "step:x"), 2, "a finished job is polled exactly once per step")
  ready = false
  registry:step(10)
  Assert.equal(count(log, "step:x"), 4, "a finished job that reports unfinished resumes until it is ready again")
  Assert.equal(count(log, "cancel:x"), 0, "a finished job is kept until its need goes away")
end

function T.tests.retain_cancels_dropped_jobs_once()
  local clock, log = newClock(), {}
  local registry = AssetNeedsRegistry.new({ clock = clock.read })
  registry:register("a", newPreparer(clock, 2, log))
  registry:enroll("a:keep")
  registry:enroll("a:drop")
  registry:retain({ ["a:keep"] = true })
  Assert.equal(count(log, "cancel:drop"), 1)
  Assert.equal(count(log, "cancel:keep"), 0)
  registry:retain({ ["a:keep"] = true })
  Assert.equal(count(log, "cancel:drop"), 1, "a dropped job is cancelled exactly once")
  clear(log)
  registry:step(10)
  Assert.equal(count(log, "step:drop"), 0, "a dropped job is never stepped")
  Assert.isTrue(registry:enroll("a:drop"), "a dropped need can be enrolled again")
end

function T.tests.unregister_cancels_that_kinds_jobs_only()
  local clock, log = newClock(), {}
  local registry = AssetNeedsRegistry.new({ clock = clock.read })
  registry:register("a", newPreparer(clock, 2, log))
  registry:register("b", newPreparer(clock, 2, log))
  registry:enroll("a:x")
  registry:enroll("b:y")
  registry:unregister("a")
  Assert.equal(count(log, "cancel:x"), 1)
  Assert.equal(count(log, "cancel:y"), 0)
  Assert.isFalse(registry:enroll("a:x"), "the kind is gone")
end

function T.tests.dispose_cancels_every_job_once()
  local clock, log = newClock(), {}
  local registry = AssetNeedsRegistry.new({ clock = clock.read })
  registry:register("a", newPreparer(clock, 2, log))
  registry:enroll("a:x")
  registry:enroll("a:y")
  registry:dispose()
  registry:dispose()
  Assert.equal(count(log, "cancel:x"), 1)
  Assert.equal(count(log, "cancel:y"), 1)
end

function T.tests.a_failing_job_is_isolated_and_reported()
  local clock, log = newClock(), {}
  local registry = AssetNeedsRegistry.new({ clock = clock.read })
  registry:register("bad", {
    start = function(id)
      local job = {}
      function job.step()
        error("boom " .. id, 0)
      end
      function job.cancel()
        log[#log + 1] = "cancel:" .. id
      end
      return job
    end,
  })
  registry:register("a", newPreparer(clock, 1, log))
  registry:enroll("bad:x")
  registry:enroll("a:ok")
  registry:step(10)
  Assert.deepEqual(registry:failures(), { { key = "bad:x", message = "boom x" } })
  Assert.equal(count(log, "cancel:x"), 1, "the failed job is cancelled once")
  Assert.equal(count(log, "step:ok"), 1, "other jobs still run")
  registry:step(10)
  Assert.equal(count(log, "cancel:x"), 1, "a failed job is not retried")
  Assert.isFalse(registry:enroll("bad:x"), "a failed need is not restarted until it is dropped")
  registry:retain({})
  Assert.deepEqual(registry:failures(), {}, "dropping the need clears the failure")
end

function T.tests.a_failing_start_is_isolated_and_reported()
  local registry = AssetNeedsRegistry.new()
  registry:register("a", {
    start = function()
      error("no start", 0)
    end,
  })
  Assert.isFalse(registry:enroll("a:x"))
  Assert.deepEqual(registry:failures(), { { key = "a:x", message = "no start" } })
end

return T
