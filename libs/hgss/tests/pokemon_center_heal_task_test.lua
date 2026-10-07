local Assert = require("tests.support.Assert")
local Task = require("libs.hgss.src.script.tasks.PokemonCenterHealTask")

local T = { tests = {} }

function T.tests.starts_once_and_poll_only_observes_serializable_state()
  local starts, updates = 0, 0
  local flow = {}
  function flow:start(count)
    starts = starts + 1
    self.count = count
  end
  function flow:status()
    return { phase = "waiting", balls = {}, count = self.count }
  end
  function flow:updateFixed()
    updates = updates + 1
  end
  local state = Task.create({ count = 3 }, { services = { pokemonCenterHeal = flow } })
  local result = Task.poll(state, { services = { pokemonCenterHeal = flow } })
  Assert.isFalse(result.complete, "active flow keeps the script blocked")
  Assert.equal(starts, 1, "the task starts the flow once")
  Assert.equal(updates, 0, "polling the task does not advance the flow")
  Assert.equal(state.count, 3)
  Assert.isNil(state.ballHandle, "task state contains no model or audio handles")
  Assert.isNil(Task.validate(state))
end

function T.tests.propagates_structured_flow_failure_to_scheduler()
  local failure = { code = "FLOW_FAILED" }
  local flow = {
    start = function() end,
    status = function()
      return { phase = "failed", error = failure }
    end,
  }
  local state = Task.create({ count = 0 }, { services = { pokemonCenterHeal = flow } })
  local result = Task.poll(state, { services = { pokemonCenterHeal = flow } })
  Assert.equal(result.result.termination, "faulted")
  Assert.equal(result.result.error, failure)
end

return T
