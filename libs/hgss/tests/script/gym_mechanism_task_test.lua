-- The blocking gym mechanism task: one script frame per source ride or switch
-- flip, its completion only after the mechanism settled, cancellation through
-- the same owner, and the serialization refusal an active lease owes.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local GymMechanismTask = require("libs.hgss.src.script.tasks.GymMechanismTask")

local T = {}

local function newContext(statuses)
  local mechanism = { begins = {}, steps = 0, cancellations = {} }
  function mechanism:begin(action, operands)
    self.begins[#self.begins + 1] = { action = action, operands = operands }
  end
  function mechanism:step()
    self.steps = self.steps + 1
    return statuses[self.steps] or "complete"
  end
  function mechanism:cancelRide(reason)
    self.cancellations[#self.cancellations + 1] = reason
  end
  return { services = { gymMechanism = mechanism } }, mechanism
end

function T.the_task_blocks_until_the_mechanism_reports_its_settlement()
  local ctx, mechanism = newContext({ "riding", "riding", "complete" })
  local state = GymMechanismTask.create({ action = "spinarak", selector = 7 }, ctx)
  Assert.deepEqual(mechanism.begins, { { action = "spinarak", operands = { selector = 7 } } })
  Assert.equal(state.phase, "wait")
  Assert.isFalse(GymMechanismTask.poll(state, ctx).complete, "the ride still owns the script")
  Assert.isFalse(GymMechanismTask.poll(state, ctx).complete)
  local done = GymMechanismTask.poll(state, ctx)
  Assert.isTrue(done.complete, "the script resumes after the ride settled")
  Assert.equal(state.phase, "complete")
  Assert.isTrue(GymMechanismTask.poll(state, ctx).complete, "a completed task never replays its ride")
  Assert.equal(mechanism.steps, 3, "a completed task stops polling the mechanism")
end

function T.the_switch_flip_carries_its_source_operand()
  local ctx, mechanism = newContext({ "riding", "complete" })
  GymMechanismTask.create({ action = "switch", switchNumber = 1 }, ctx)
  Assert.deepEqual(mechanism.begins[1].operands, { switchNumber = 1 })
end

-- Cancellation restores the mechanism's own settled state, and a repeated
-- cancellation is a clean no-op.
function T.cancellation_releases_the_mechanism_exactly_once()
  local ctx, mechanism = newContext({ "riding" })
  local state = GymMechanismTask.create({ action = "elevator" }, ctx)
  GymMechanismTask.cancel(state, "the script was cancelled", ctx)
  Assert.deepEqual(mechanism.cancellations, { "the script was cancelled" })
  Assert.equal(state.phase, "complete")
  GymMechanismTask.cancel(state, "again", ctx)
  Assert.equal(#mechanism.cancellations, 1, "a second cancellation is a no-op")
  Assert.isNil(GymMechanismTask.validate(state), "a cancelled task serializes as complete")
end

-- Serialization: an active ride owns a transport, presentation and sound
-- lease, so only its completed state may be restored.
function T.an_active_ride_is_unserializable()
  local ctx = newContext({ "riding", "riding" })
  local state = GymMechanismTask.create({ action = "elevator" }, ctx)
  local err = GymMechanismTask.validate(state)
  Assert.isTrue(Errors.is(err), "an active ride is refused")
  Assert.equal(err.code, "SCRIPT_TASK_UNSERIALIZABLE")
  Assert.equal(err.context.phase, "wait")
  Assert.equal(err.context.action, "elevator")
  state.phase = "complete"
  Assert.isNil(GymMechanismTask.validate(state), "the completed state restores")
  Assert.equal(GymMechanismTask.validate({ phase = "wait" }).code, "SCRIPT_TASK_UNSERIALIZABLE")
end

return { tests = T }
