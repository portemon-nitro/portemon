-- Day Care custody persistence: the strict current bucket, detached canonical
-- parent copies, and the one-use deposit/withdrawal/step candidates. The
-- canonical mon validator is injected exactly like the runtime passes the mon
-- service's own boundary, so a stored parent that fails mon validation refuses
-- the bucket instead of being normalized.

local Assert = require("tests.support.Assert")
local DaycareState = require("libs.hgss.src.save.DaycareState")

local T = {}

local function mon(speciesKey, extra)
  local record = {
    schema = "g4-mon-v2",
    species = speciesKey,
    form = 0,
    personality = 1,
    experience = 1000,
    friendship = 70,
    ability = "OVERGROW",
    heldItem = "NONE",
    markings = 0,
    evs = { hp = 0, attack = 0, defense = 0, speed = 0, specialAttack = 0, specialDefense = 0 },
    contest = { cool = 0, beauty = 0, cute = 0, smart = 0, tough = 0, sheen = 0 },
    moves = { { move = "TACKLE", pp = 35, ppUps = 0 } },
    ivs = { hp = 1, attack = 1, defense = 1, speed = 1, specialAttack = 1, specialDefense = 1 },
    isEgg = false,
    ribbons = { ds1 = 0, gba = 0, ds2 = 0 },
    fatefulEncounter = false,
    shinyLeaves = 0,
    egg = { location = 0 },
    met = { location = 1, date = { year = 2000, month = 1, day = 1 }, level = 5, terrain = 0 },
    origin = {
      trainerId = 1,
      trainerName = "GOLD",
      trainerGender = 0,
      game = 7,
      ball = "POKE_BALL",
      language = 2,
    },
    pokerus = 0,
    mood = 0,
    condition = { currentHp = 20, effects = {} },
    capsule = { id = 0, seals = {} },
  }
  for key, value in pairs(extra or {}) do
    record[key] = value
  end
  return record
end

-- The injected canonical validator: this fixture answers a detached copy and
-- refuses records missing their species, which is the whole contract the state
-- owner relies on.
local function validateMon(record)
  Assert.isTrue(type(record) == "table", "stored parents are records")
  Assert.isTrue(type(record.species) == "string", "stored parents name their species")
  local copy = {}
  for key, value in pairs(record) do
    copy[key] = value
  end
  return copy
end

local function stateWith(bucket)
  return DaycareState.restore(bucket or DaycareState.initial(), validateMon)
end

function T.initial_bucket_is_the_defined_empty_day_care()
  Assert.deepEqual(DaycareState.initial(), {
    schema = DaycareState.SCHEMA,
    slots = {},
    pendingEggPid = 0,
    eggCycleCounter = 0,
  })
  local state = stateWith(nil)
  Assert.equal(state:count(), 0)
  Assert.equal(state:state(), DaycareState.STATE_EMPTY)
  Assert.equal(state:revision(), 0)
  Assert.isNil(state:tailSlot(), "an empty Day Care has no tail parent")
end

function T.restore_copies_the_bucket_and_never_aliases_it()
  local bucket = DaycareState.initial()
  bucket.slots[1] = { mon = mon("CHIKORITA"), steps = 7 }
  bucket.slots[2] = { mon = mon("TOTODILE"), steps = 3 }
  bucket.pendingEggPid = 0
  bucket.eggCycleCounter = 0
  local state = stateWith(bucket)
  Assert.equal(state:count(), 2)
  Assert.equal(state:state(), DaycareState.STATE_TWO_MONS)
  Assert.equal(state:tailSlot(), 1)
  Assert.equal(state:steps(0), 7)
  Assert.equal(state:steps(1), 3)
  bucket.slots[1].steps = 99
  Assert.equal(state:steps(0), 7, "the restored state owns its counters")
  local read = assert(state:mon(0))
  read.steps = 1
  read.species = "CHANGED"
  Assert.equal(state:mon(0).species, "CHIKORITA", "a read is a detached parent copy")
end

function T.a_pending_egg_identity_outranks_the_parent_count()
  local bucket = DaycareState.initial()
  bucket.slots[1] = { mon = mon("CHIKORITA"), steps = 0 }
  bucket.pendingEggPid = 42
  local state = stateWith(bucket)
  Assert.equal(state:state(), DaycareState.STATE_EGG_READY)
  Assert.equal(state:pendingEggPid(), 42)
end

function T.strict_current_buckets_are_refused()
  local cases = {
    { label = "unknown top-level field", mutate = function(bucket)
      bucket.gift = { species = "TOGEPI" }
    end },
    { label = "unknown slot field", mutate = function(bucket)
      bucket.slots[1] = { mon = mon("CHIKORITA"), steps = 0, level = 5 }
    end },
    { label = "negative steps", mutate = function(bucket)
      bucket.slots[1] = { mon = mon("CHIKORITA"), steps = -1 }
    end },
    { label = "steps above the unsigned 32-bit range", mutate = function(bucket)
      bucket.slots[1] = { mon = mon("CHIKORITA"), steps = 0x100000000 }
    end },
    { label = "non-dense slots", mutate = function(bucket)
      bucket.slots[2] = { mon = mon("CHIKORITA"), steps = 0 }
    end },
    { label = "more than two parents", mutate = function(bucket)
      for index = 1, 3 do
        bucket.slots[index] = { mon = mon("CHIKORITA"), steps = 0 }
      end
    end },
    { label = "egg pid above the unsigned 32-bit range", mutate = function(bucket)
      bucket.pendingEggPid = 0x100000000
    end },
    { label = "cycle counter above its byte", mutate = function(bucket)
      bucket.eggCycleCounter = 256
    end },
    { label = "invalid schema", mutate = function(bucket)
      bucket.schema = "hgss-daycare-v0"
    end },
    { label = "invalid stored parent", mutate = function(bucket)
      bucket.slots[1] = { mon = { schema = "g4-mon-v2" }, steps = 0 }
    end },
  }
  for _, case in ipairs(cases) do
    local bucket = DaycareState.initial()
    case.mutate(bucket)
    Assert.throws(function()
      DaycareState.restore(bucket, validateMon)
    end, "the Day Care bucket refuses " .. case.label)
  end
  Assert.throws(function()
    DaycareState.restore(nil, validateMon)
  end, "a current save without a Day Care bucket is malformed, not empty")
end

function T.deposit_stages_the_first_free_slot_with_a_zero_counter()
  local state = stateWith(nil)
  local prepared, reason = state:prepareDeposit(state:revision(), mon("CHIKORITA"))
  assert(prepared ~= nil, "a current revision stages the deposit: " .. tostring(reason))
  Assert.isTrue(prepared.changed)
  Assert.equal(state:count(), 0, "staging never mutates live custody")
  prepared.publish()
  Assert.equal(state:count(), 1)
  Assert.equal(state:steps(0), 0)
  Assert.equal(state:revision(), 1)
  Assert.isFalse(prepared.isCurrent(), "publication moves the revision past the candidate")
  Assert.throws(function()
    prepared.publish()
  end, "a repeated publication is a programming error")
  Assert.equal(state:revision(), 1)
end

function T.deposit_refuses_a_stale_revision_and_a_full_day_care()
  local state = stateWith(nil)
  local stale, reason = state:prepareDeposit(state:revision() + 1, mon("CHIKORITA"))
  Assert.isNil(stale)
  Assert.equal(reason, "stale")
  assert(state:prepareDeposit(state:revision(), mon("CHIKORITA"))).publish()
  assert(state:prepareDeposit(state:revision(), mon("TOTODILE"))).publish()
  local full, fullReason = state:prepareDeposit(state:revision(), mon("EEVEE"))
  Assert.isNil(full)
  Assert.equal(fullReason, "full")
  Assert.equal(state:count(), 2)
end

function T.withdraw_hands_out_the_parent_and_compacts_the_second_slot()
  local bucket = DaycareState.initial()
  bucket.slots[1] = { mon = mon("CHIKORITA"), steps = 5 }
  bucket.slots[2] = { mon = mon("TOTODILE"), steps = 9 }
  local state = stateWith(bucket)
  local staged, reason = state:prepareWithdraw(state:revision(), 1)
  assert(staged ~= nil, "a current revision stages the withdrawal: " .. tostring(reason))
  Assert.equal(staged.mon.species, "TOTODILE")
  Assert.equal(staged.steps, 9, "the candidate hands out the stored steps")
  Assert.equal(state:count(), 2, "staging never removes the parent")
  staged.prepared.publish()
  Assert.equal(state:count(), 1)
  Assert.equal(state:mon(0).species, "CHIKORITA", "the remaining parent keeps its slot")
  Assert.equal(state:tailSlot(), 0)
  local missing, missingReason = state:prepareWithdraw(state:revision(), 1)
  Assert.isNil(missing)
  Assert.equal(missingReason, "empty")
end

function T.step_advance_counts_every_parent_once_and_saturates()
  local bucket = DaycareState.initial()
  bucket.slots[1] = { mon = mon("CHIKORITA"), steps = 0 }
  bucket.slots[2] = { mon = mon("TOTODILE"), steps = 0xFFFFFFFF }
  local state = stateWith(bucket)
  local prepared = assert(state:prepareStepAdvance(state:revision()))
  Assert.isTrue(prepared.changed)
  prepared.publish()
  Assert.equal(state:steps(0), 1, "one committed step advances the first parent once")
  Assert.equal(state:steps(1), 0xFFFFFFFF, "the unsigned counter saturates at its ceiling")
  local revision = state:revision()
  local empty = stateWith(nil)
  local preparedEmpty = assert(empty:prepareStepAdvance(empty:revision()))
  Assert.isFalse(preparedEmpty.changed, "an empty Day Care stages nothing")
  preparedEmpty.publish()
  Assert.equal(empty:revision(), 0)
  Assert.isTrue(revision > 0)
end

function T.capture_is_a_detached_current_bucket()
  local bucket = DaycareState.initial()
  bucket.slots[1] = { mon = mon("CHIKORITA"), steps = 4 }
  bucket.eggCycleCounter = 3
  local state = stateWith(bucket)
  local captured = state:capture()
  Assert.deepEqual(captured, bucket)
  captured.slots[1].steps = 99
  Assert.equal(state:steps(0), 4, "a capture never aliases live custody")
  Assert.equal(state:eggCycleCounter(), 3)
  local restored = stateWith(state:capture())
  Assert.equal(restored:steps(0), 4)
  Assert.equal(restored:eggCycleCounter(), 3)
end

return { tests = T }
