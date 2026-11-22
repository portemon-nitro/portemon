-- Script runtime coverage for the Rocket hideout's own operations and the
-- follower inhibit write: the trap and the alarm block on the shared native
-- action task, the powered-prop projection and the map event key settle in
-- their own tick, and the costume and inhibit commands mutate exactly the one
-- owner they name.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local Runtime = require("libs.script.src.Runtime")
local RuntimeValues = require("libs.hgss.src.script.RuntimeValues")

local T = {}

local function runWith(services)
  local created = {}
  local run = {
    instance = { scriptId = "test.rocket", mode = "foreground", locals = {}, textArgs = {} },
    node = { nodeId = "n1" },
    tick = 1,
    input = {},
    services = services,
    semantics = RuntimeValues,
    scheduler = {
      createTask = function(_, taskType, spec)
        created[#created + 1] = { taskType = taskType, spec = spec }
        return #created
      end,
    },
  }
  return { run = run, created = created }
end

local function worldWith(vars, flags)
  return {
    vars = vars or {},
    flags = flags or {},
    getVar = function(self, id)
      return self.vars[id] or 0
    end,
    setVar = function(self, id, value)
      self.vars[id] = value
    end,
    isFlagSet = function(self, id)
      return self.flags[id] == true
    end,
    setFlag = function(self, id)
      self.flags[id] = true
    end,
    clearFlag = function(self, id)
      self.flags[id] = nil
    end,
  }
end

local function var(id)
  return { value = "var", id = id }
end

function T.the_trap_effect_blocks_the_script_on_its_own_effect()
  local rocket = { begins = {} }
  function rocket:begin(action, operands)
    self.begins[#self.begins + 1] = { action = action, kind = operands and operands.kind }
  end
  local fixture = runWith({ rocketHideout = rocket })
  local outcome = Runtime.executeNode({ op = "rocket_trap_effect", kind = 2 }, fixture.run)
  Assert.equal(outcome, Runtime.OUTCOME_BLOCK, "the trap effect blocks the running script")
  Assert.equal(fixture.created[1].taskType, "gym_mechanism", "the trap rides the shared native-action task")
  Assert.equal(fixture.created[1].spec.action, "rocket_trap")
  Assert.equal(fixture.created[1].spec.kind, 2, "the evaluated source kind rides the task spec")
end

function T.a_variable_trap_selector_is_evaluated_before_the_effect_starts()
  local rocket = {}
  function rocket:begin() end
  local world = worldWith({ [0x4007] = 1 })
  local fixture = runWith({ rocketHideout = rocket, world = world })
  Runtime.executeNode({ op = "rocket_trap_effect", kind = var(0x4007) }, fixture.run)
  Assert.equal(fixture.created[1].spec.kind, 1, "the runtime reads the variable, never the raw reference")
end

function T.the_alarm_blocks_the_script_on_the_shared_task()
  local rocket = {}
  function rocket:begin() end
  local fixture = runWith({ rocketHideout = rocket })
  local outcome = Runtime.executeNode({ op = "rocket_alarm" }, fixture.run)
  Assert.equal(outcome, Runtime.OUTCOME_BLOCK)
  Assert.equal(fixture.created[1].spec.action, "rocket_alarm")
end

function T.the_power_prop_projection_settles_in_its_own_tick()
  local rocket = { syncs = 0 }
  function rocket:syncPowerProps()
    self.syncs = self.syncs + 1
  end
  local fixture = runWith({ rocketHideout = rocket })
  Assert.equal(Runtime.executeNode({ op = "rocket_power_props" }, fixture.run), Runtime.OUTCOME_CONTINUE)
  Assert.equal(rocket.syncs, 1, "one projection per ask")
end

function T.the_map_event_key_writes_through_the_effect_owner()
  local rocket = { writes = {} }
  function rocket:writeMapEventKey(slot, action)
    self.writes[#self.writes + 1] = { slot = slot, action = action }
  end
  local world = worldWith({ [0x4007] = 3 })
  local fixture = runWith({ rocketHideout = rocket, world = world })
  Assert.equal(
    Runtime.executeNode({ op = "map_event_key", slot = var(0x4007), action = 1 }, fixture.run),
    Runtime.OUTCOME_CONTINUE
  )
  Assert.equal(rocket.writes[1].slot, 3, "the runtime evaluates the source key slot")
  Assert.equal(rocket.writes[1].action, 1, "the raw action byte rides unchanged")
end

function T.the_costume_commands_write_only_their_own_flag()
  local world = worldWith({}, {})
  local fixture = runWith({ world = world })
  Runtime.executeNode(
    { op = "rocket_costume_action", flag = "FLAG_SYS_ROCKET_COSTUME", mode = 1 },
    fixture.run
  )
  Assert.isTrue(world.flags.FLAG_SYS_ROCKET_COSTUME == true, "a nonzero mode sets the costume flag")
  Runtime.executeNode({ op = "rocket_costume_check", flag = "FLAG_SYS_ROCKET_COSTUME", result = var(7) }, fixture.run)
  Assert.equal(world.vars[7], 1, "the check answers the live flag")
  Runtime.executeNode({ op = "rocket_costume_action", flag = "FLAG_SYS_ROCKET_COSTUME", mode = 0 }, fixture.run)
  Assert.isNil(world.flags.FLAG_SYS_ROCKET_COSTUME, "a zero mode clears the costume flag")
  Assert.equal(world.vars[7], 1, "a check never mutates the flag it reads")
end

function T.the_follower_inhibit_write_answers_the_following_owner()
  local following = { writes = {} }
  function following:setInhibited(inhibited)
    self.writes[#self.writes + 1] = inhibited
  end
  local fixture = runWith({ followingMon = following })
  Runtime.executeNode({ op = "follower_set_inhibited", inhibited = 1 }, fixture.run)
  Runtime.executeNode({ op = "follower_set_inhibited", inhibited = 0 }, fixture.run)
  Assert.deepEqual(following.writes, { true, false }, "the raw byte maps to the durable boolean")
end

function T.a_missing_rocket_owner_is_an_attributed_fault()
  local fixture = runWith({})
  local err = Assert.throws(function()
    Runtime.executeNode({ op = "rocket_power_props" }, fixture.run)
  end)
  Assert.isTrue(Errors.is(err))
  Assert.equal(err.code, "SCRIPT_SERVICE_MISSING")
end

return { tests = T }
