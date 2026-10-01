-- Source script continuation for battle results: starting records a
-- pending launch, polling observes the injected host once per completion,
-- validation pins the persisted shape, and result reads back the outcome
-- without running anything twice.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local BattleTask = require("libs.hgss.src.script.tasks.BattleTask")

local T = {}

local function hostWith(statusByLaunch)
  return {
    launches = {},
    launchBattle = function(self, spec)
      self.launches[#self.launches + 1] = spec
      return (spec.launchId or "battle") .. "#" .. tostring(#self.launches)
    end,
    battleStatus = function(_, launchId)
      return statusByLaunch[launchId]
    end,
  }
end

local function ctxWith(host)
  return { services = { battle = host } }
end

function T.start_records_a_pending_launch_without_touching_the_host()
  local host = hostWith({})
  local state = BattleTask.start({ launchId = "launch-1", kind = "wild", details = {} }, { services = {} })
  Assert.equal(state.launchId, "launch-1")
  Assert.equal(state.kind, "wild")
  Assert.isFalse(state.completed == true)
  Assert.equal(#host.launches, 0, "starting with a bare identity records without launching")
end

function T.start_issues_a_unique_identity_through_the_host()
  local host = hostWith({})
  local first = BattleTask.start({ launchId = "site", kind = "trainer" }, ctxWith(host))
  local second = BattleTask.start({ launchId = "site", kind = "trainer" }, ctxWith(host))
  Assert.isTrue(first.launchId ~= second.launchId, "two runs of one site never share a launch")
  Assert.equal(#host.launches, 2)
end

function T.start_rejects_malformed_specs()
  local host = hostWith({})
  Assert.isTrue(Errors.is(Assert.throws(function()
    BattleTask.start({ kind = "wild" }, { services = {} })
  end)), "a launch without identity or issuing host fails")
  Assert.isTrue(Errors.is(Assert.throws(function()
    BattleTask.start({ launchId = "x", kind = "safari" }, ctxWith(host))
  end)))
  Assert.isTrue(Errors.is(Assert.throws(function()
    BattleTask.start({ launchId = "", kind = "wild" }, ctxWith(host))
  end)))
end

function T.poll_stays_pending_until_the_host_commits()
  local statusByLaunch = { ["launch-2"] = { phase = "running", committed = false } }
  local host = hostWith(statusByLaunch)
  local state = BattleTask.start({ launchId = "launch-2", kind = "wild" }, { services = {} })
  local pending = BattleTask.poll(state, ctxWith(host))
  Assert.isFalse(pending.complete)
  statusByLaunch["launch-2"] = { phase = "complete", committed = true, result = "win" }
  local done = BattleTask.poll(state, ctxWith(host))
  Assert.isTrue(done.complete)
  Assert.equal(done.result, BattleTask.SOURCE_WON)
  Assert.isTrue(state.completed)
end

function T.poll_records_completion_exactly_once()
  local statusByLaunch = { ["launch-3"] = { phase = "complete", committed = true, result = "loss" } }
  local host = hostWith(statusByLaunch)
  local state = BattleTask.start({ launchId = "launch-3", kind = "wild" }, { services = {} })
  local first = BattleTask.poll(state, ctxWith(host))
  local second = BattleTask.poll(state, ctxWith(host))
  Assert.isTrue(first.complete and second.complete)
  Assert.equal(first.result, BattleTask.SOURCE_NOT_WON)
  local read = BattleTask.result({ launchId = "launch-3" })
  Assert.equal(read.result, "loss")
  Assert.isTrue(read.committed)
end

function T.poll_faults_precisely_without_a_host_or_launch()
  local state = BattleTask.start({ launchId = "launch-4", kind = "wild" }, { services = {} })
  Assert.isTrue(Errors.is(Assert.throws(function()
    BattleTask.poll(state, { services = {} })
  end)))
  Assert.isTrue(Errors.is(Assert.throws(function()
    BattleTask.poll(state, ctxWith(hostWith({})))
  end)))
end

function T.poll_rejects_unknown_outcome_words()
  local statusByLaunch = { ["launch-5"] = { phase = "complete", committed = true, result = "triumph" } }
  local host = hostWith(statusByLaunch)
  local state = BattleTask.start({ launchId = "launch-5", kind = "wild" }, { services = {} })
  Assert.isTrue(Errors.is(Assert.throws(function()
    BattleTask.poll(state, ctxWith(host))
  end)))
end

function T.validate_pins_the_persisted_shape()
  Assert.isNil(BattleTask.validate({ launchId = "launch-6", kind = "trainer", completed = false }))
  Assert.isNil(
    BattleTask.validate({ launchId = "launch-6", completed = true, result = "draw", sourceResult = 0 })
  )
  Assert.isTrue(Errors.is(BattleTask.validate({ kind = "wild" })))
  Assert.isTrue(Errors.is(BattleTask.validate({ launchId = "launch-6", kind = "safari" })))
  Assert.isTrue(Errors.is(BattleTask.validate({ launchId = "launch-6", result = "triumph" })))
  Assert.isTrue(Errors.is(BattleTask.validate({ launchId = "launch-6", sourceResult = 7 })))
end

function T.result_reads_are_pure_and_cover_pending_and_receipt_paths()
  local pending = BattleTask.result({ launchId = "launch-never-seen" })
  Assert.equal(pending.result, "pending")
  Assert.isFalse(pending.committed)
  local host = hostWith({ ["launch-7"] = { phase = "complete", committed = true, result = "win" } })
  local state = BattleTask.start({ launchId = "launch-7", kind = "wild" }, { services = {} })
  BattleTask.poll(state, ctxWith(host))
  local first = BattleTask.result({ launchId = "launch-7" })
  local second = BattleTask.result({ launchId = "launch-7" })
  Assert.deepEqual(first, second, "result reads never re-run the outcome")
  Assert.equal(first.result, "win")
  Assert.equal(first.sourceResult, BattleTask.SOURCE_WON)
end

function T.task_registry_contract_holds_create_poll_and_validate()
  Assert.equal(BattleTask.type, "battle")
  Assert.equal(BattleTask.version, 1)
  Assert.isTrue(BattleTask.create == BattleTask.start, "creation starts the pending launch")
end

return { tests = T }
