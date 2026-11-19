-- Trainer defeat flags are ordinary numeric world-event flags: a source
-- trainer number resolves to the retail TRAINER_FLAG_BASE offset at runtime,
-- the set/clear/check commands read and write that one flag store, and the
-- check answers through native comparison state so the following branch
-- reads live state.

local Assert = require("tests.support.Assert")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local Registry = require("libs.script.src.Registry")
local Composition = require("libs.script.src.Composition")
local RuntimeValues = require("libs.hgss.src.script.RuntimeValues")
local S = require("gen4.script")
local Scheduler = require("libs.script.src.Scheduler")
local TaskRegistry = require("libs.script.src.TaskRegistry")
local WorldState = require("libs.hgss.src.script.WorldState")
local FakeServices = require("tests.support.script.FakeServices")

-- Retail `include/constants/flags.h::TRAINER_FLAG_BASE`.
local TRAINER_FLAG_BASE = 0x550

local CATALOGS = {
  flags = { FLAG_GOT_STARTER = 0x801 },
  variables = {
    VAR_TRAINER = 0x4005,
    VAR_FIRST_CHECK = 0x4006,
    VAR_SECOND_CHECK = 0x4007,
    VAR_GENERIC_SEEN = 0x4008,
    VAR_CLEARED = 0x4009,
  },
}

local T = {}

local function trainerFlag(trainer)
  return { value = "trainer_flag_id", trainer = trainer }
end

local function worldServices(world)
  return {
    isFlagSet = function(_, id)
      return world:isFlagSet(id)
    end,
    setFlag = function(_, id)
      world:setFlag(id)
    end,
    clearFlag = function(_, id)
      world:clearFlag(id)
    end,
    getVar = function(_, id)
      return world:getVar(id)
    end,
    setVar = function(_, id, value)
      world:setVar(id, value)
    end,
    addVar = function(_, id, amount)
      world:addVar(id, amount)
    end,
    subVar = function(_, id, amount)
      world:subVar(id, amount)
    end,
    rng = world.rng,
  }
end

-- The real scheduler over a WorldState-backed flag store and the HGSS script
-- semantics: the commands execute exactly as the composed field runs them.
local function harness()
  local world = WorldState.new({ catalogs = CATALOGS, seed = 42 })
  local services = FakeServices.new()
  services.world = worldServices(world) --[[@as FakeWorld]]
  local registry = Registry.new()
  local composition = Composition.new(registry)
  local scheduler = Scheduler.new({
    semantics = RuntimeValues,
    services = services,
    taskRegistry = TaskRegistry.new(),
    resolveComposition = function(id)
      return composition:effective(id)
    end,
  })
  return { world = world, registry = registry, composition = composition, scheduler = scheduler }
end

---@param h table harness
---@param id string script id
---@param steps table[] DSL steps
---@param tick integer|nil
local function run(h, id, steps, tick)
  local resource = S.script({ api = 1, id = id, steps = steps })
  h.registry:installBase(id, resource, "generated")
  local composed = assert(h.composition:effective(id), "the trainer flag script must compose")
  h.scheduler:createForeground(composed, nil, tick or 100)
  h.scheduler:step(tick or 100, nil)
end

-- A literal source trainer number resolves to base + number; a variable
-- operand resolves through the live variable.
function T.trainer_flag_value_adds_the_retail_base_to_the_source_number()
  local run_ = { instance = { scriptId = "test.trainer_flags" } }
  Assert.equal(RuntimeValues.evaluateValue(trainerFlag(0), run_), TRAINER_FLAG_BASE, "trainer zero names the base flag")
  Assert.equal(RuntimeValues.evaluateValue(trainerFlag(3), run_), TRAINER_FLAG_BASE + 3)
  Assert.equal(RuntimeValues.evaluateValue(trainerFlag(1000), run_), TRAINER_FLAG_BASE + 1000)

  local variableRun = {
    instance = { scriptId = "test.trainer_flags" },
    services = {
      world = {
        getVar = function(_, id)
          Assert.equal(id, "VAR_TRAINER")
          return 3
        end,
      },
    },
  }
  Assert.equal(
    RuntimeValues.evaluateValue(trainerFlag(S.var("VAR_TRAINER")), variableRun),
    TRAINER_FLAG_BASE + 3,
    "a variable trainer number resolves before the base is added"
  )
end

-- An unusable trainer number is an attributed reference fault, never a
-- silently wrapped flag id.
function T.invalid_trainer_numbers_fault()
  local run_ = { instance = { scriptId = "test.trainer_flags" } }
  -- A usable trainer resolves first, so the faults below are about the
  -- trainer value rather than a missing value kind.
  Assert.equal(RuntimeValues.evaluateValue(trainerFlag(3), run_), TRAINER_FLAG_BASE + 3)
  for _, trainer in ipairs({ -1, 2.5, "RIVAL", 0 / 0 }) do
    local err = Assert.throws(function()
      RuntimeValues.evaluateValue(trainerFlag(trainer), run_)
    end)
    Assert.equal(err and err.code, "SCRIPT_INVALID_REFERENCE", "trainer " .. tostring(trainer) .. " must fault")
  end
end

-- The computed defeat flag must stay inside the flag store's unsigned
-- 16-bit id domain: the largest referenceable source number resolves to the
-- last flag id, and one past it faults at the reference instead of becoming
-- an invalid flag id later.
function T.trainer_number_edges_bound_the_computed_flag_id()
  local run_ = { instance = { scriptId = "test.trainer_flags" } }
  local lastTrainer = 0xFFFF - TRAINER_FLAG_BASE
  local lastFlag = RuntimeValues.evaluateValue(trainerFlag(lastTrainer), run_)
  Assert.equal(lastFlag, 0xFFFF, "the largest referenceable trainer resolves to the last flag id")
  local store = FieldEventState.new()
  store:setFlag(lastFlag)
  Assert.isTrue(store:isFlagSet(lastFlag), "the flag store accepts the edge flag id")
  local err = Assert.throws(function()
    RuntimeValues.evaluateValue(trainerFlag(lastTrainer + 1), run_)
  end)
  Assert.equal(err and err.code, "SCRIPT_INVALID_REFERENCE", "one past the flag domain faults at the reference")
end

-- The check reads the live flag through native comparison state: the first
-- check sees an unbeaten trainer, the set writes the very same numeric flag,
-- and the second check sees the win.
function T.set_flag_and_check_share_the_one_numeric_flag()
  local h = harness()
  run(h, "test.trainer_flags", {
    S.compare({ left = S.flagValue(trainerFlag(3)), right = 1 }),
    S.gotoCompared({ operator = "eq", target = "beaten" }),
    S.setVar({ variable = S.var("VAR_FIRST_CHECK"), value = 0 }),
    S.setFlag({ flag = trainerFlag(3) }),
    S.compare({ left = S.flagValue(trainerFlag(3)), right = 1 }),
    S.gotoCompared({ operator = "eq", target = "beaten" }),
    S.setVar({ variable = S.var("VAR_SECOND_CHECK"), value = 0 }),
    S.stop(),
    S.label({ name = "beaten" }),
    S.setVar({ variable = S.var("VAR_SECOND_CHECK"), value = 1 }),
    S.stop(),
  })
  Assert.equal(h.world:getVar("VAR_FIRST_CHECK"), 0, "the first check of an unbeaten trainer is false")
  Assert.equal(h.world:getVar("VAR_SECOND_CHECK"), 1, "the check after the set is true")
  Assert.isTrue(h.world:events():isFlagSet(TRAINER_FLAG_BASE + 3), "the event store holds the numeric flag")
  Assert.isTrue(h.world:isFlagSet(TRAINER_FLAG_BASE + 3), "a generic flag read observes the same bit")
end

-- A generic source flag write is what the trainer check reads: there is no
-- second trainer bitset.
function T.generic_flag_write_is_visible_to_the_trainer_check()
  local h = harness()
  run(h, "test.trainer_generic", {
    S.setFlag({ flag = TRAINER_FLAG_BASE + 3 }),
    S.compare({ left = S.flagValue(trainerFlag(3)), right = 1 }),
    S.gotoCompared({ operator = "eq", target = "hit" }),
    S.setVar({ variable = S.var("VAR_GENERIC_SEEN"), value = 0 }),
    S.stop(),
    S.label({ name = "hit" }),
    S.setVar({ variable = S.var("VAR_GENERIC_SEEN"), value = 1 }),
    S.stop(),
  })
  Assert.equal(h.world:getVar("VAR_GENERIC_SEEN"), 1, "the trainer check reads the generic numeric flag")
end

-- The check alone never writes the flag it reads.
function T.check_alone_leaves_the_flag_untouched()
  local h = harness()
  run(h, "test.trainer_check_only", {
    S.compare({ left = S.flagValue(trainerFlag(3)), right = 1 }),
    S.stop(),
  })
  Assert.isFalse(h.world:isFlagSet(TRAINER_FLAG_BASE + 3), "the check never sets the flag it reads")
end

-- Clearing through a variable trainer number makes the trainer eligible
-- again under the following source check.
function T.clear_flag_with_a_variable_trainer_number_resets_the_check()
  local h = harness()
  run(h, "test.trainer_clear", {
    S.setVar({ variable = S.var("VAR_TRAINER"), value = 3 }),
    S.setFlag({ flag = trainerFlag(S.var("VAR_TRAINER")) }),
    S.clearFlag({ flag = trainerFlag(S.var("VAR_TRAINER")) }),
    S.compare({ left = S.flagValue(trainerFlag(S.var("VAR_TRAINER"))), right = 1 }),
    S.gotoCompared({ operator = "eq", target = "still_beaten" }),
    S.setVar({ variable = S.var("VAR_CLEARED"), value = 1 }),
    S.stop(),
    S.label({ name = "still_beaten" }),
    S.setVar({ variable = S.var("VAR_CLEARED"), value = 0 }),
    S.stop(),
  })
  Assert.equal(h.world:getVar("VAR_CLEARED"), 1, "the cleared trainer checks as unbeaten")
  Assert.isFalse(h.world:isFlagSet(TRAINER_FLAG_BASE + 3))
end

-- The flag store is the authority: clearing a trainer that was never set
-- leaves it eligible, and repeated writes of the same trainer converge on the
-- one numeric event flag.
function T.repeated_trainer_flag_writes_converge_on_one_event_flag()
  local h = harness()
  run(h, "test.trainer_idempotent", {
    S.clearFlag({ flag = trainerFlag(3) }),
    S.compare({ left = S.flagValue(trainerFlag(3)), right = 1 }),
    S.gotoCompared({ operator = "eq", target = "beaten" }),
    S.setVar({ variable = S.var("VAR_CLEARED"), value = 1 }),
    S.stop(),
    S.label({ name = "beaten" }),
    S.setVar({ variable = S.var("VAR_CLEARED"), value = 0 }),
    S.stop(),
  })
  Assert.equal(h.world:getVar("VAR_CLEARED"), 1, "a trainer cleared before it was set stays unbeaten")

  local second = harness()
  run(second, "test.trainer_set_twice", {
    S.setFlag({ flag = trainerFlag(3) }),
    S.setFlag({ flag = trainerFlag(3) }),
    S.clearFlag({ flag = trainerFlag(3) }),
    S.clearFlag({ flag = trainerFlag(3) }),
    S.compare({ left = S.flagValue(trainerFlag(3)), right = 1 }),
    S.gotoCompared({ operator = "eq", target = "beaten" }),
    S.setVar({ variable = S.var("VAR_CLEARED"), value = 1 }),
    S.stop(),
    S.label({ name = "beaten" }),
    S.setVar({ variable = S.var("VAR_CLEARED"), value = 0 }),
    S.stop(),
  })
  Assert.equal(second.world:getVar("VAR_CLEARED"), 1, "repeated writes leave one cleared event flag")
  Assert.isFalse(second.world:isFlagSet(TRAINER_FLAG_BASE + 3))
end

-- The trainer flag is persisted world state: a save capture carries it and a
-- restore reads it back.
function T.trainer_flag_survives_the_world_save_round_trip()
  local h = harness()
  run(h, "test.trainer_save", {
    S.setFlag({ flag = trainerFlag(3) }),
    S.stop(),
  })
  local record = h.world:capture()
  local restored = WorldState.restore(record, { catalogs = CATALOGS })
  Assert.isTrue(restored:isFlagSet(TRAINER_FLAG_BASE + 3), "the restored world still holds the defeat flag")
  Assert.isFalse(
    FieldEventState.new():isFlagSet(TRAINER_FLAG_BASE + 3),
    "a fresh event store starts without a defeated trainer"
  )
end

return { tests = T }
