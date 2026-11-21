-- The persisted gym mechanism union: one tagged kind at a time, the source
-- defaults each gym's init installs, and a strict detached capture/restore
-- that never repairs malformed buckets.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.hgss.src.field.FieldErrors")
local GymMechanismState = require("libs.hgss.src.field.GymMechanismState")

local T = {}

local function azaleaBucket(overrides)
  local bucket = {
    schema = GymMechanismState.SCHEMA,
    kind = "azalea",
    data = { endpoints = { 0, 1, 2, 7 }, switchMask = 0 },
  }
  for key, value in pairs(overrides or {}) do
    bucket[key] = value
  end
  return bucket
end

function T.the_union_starts_inactive_and_round_trips_each_closed_kind()
  local empty = GymMechanismState.restore(nil)
  Assert.equal(empty:kind(), "none", "a save without the bucket carries no active mechanism")
  Assert.deepEqual(empty:capture(), { schema = GymMechanismState.SCHEMA, kind = "none", data = {} })

  local violet =
    GymMechanismState.restore({ schema = GymMechanismState.SCHEMA, kind = "violet", data = { raised = true } })
  Assert.equal(violet:kind(), "violet")
  Assert.isTrue(violet:violetRaised(), "the settled lift height survives the round trip")
  Assert.deepEqual(violet:capture(), {
    schema = GymMechanismState.SCHEMA,
    kind = "violet",
    data = { raised = true },
  })

  local azalea = GymMechanismState.restore(azaleaBucket())
  Assert.equal(azalea:kind(), "azalea")
  Assert.deepEqual(azalea:spiderEndpoints(), { 0, 1, 2, 7 }, "the four spider endpoints survive the round trip")
  Assert.equal(azalea:switchMask(), 0)
end

-- The capture is detached: mutating the live owner after a capture never
-- rewrites the record that was handed to the save, and a restored owner never
-- shares its endpoint array with the bucket it read.
function T.capture_and_restore_are_detached_from_their_source()
  local bucket = azaleaBucket()
  local state = GymMechanismState.restore(bucket)
  local captured = state:capture()
  state:setSpiderEndpoint(1, 5)
  state:toggleSwitch(0)
  Assert.deepEqual(bucket.data.endpoints, { 0, 1, 2, 7 }, "restore never aliases the persisted endpoints")
  Assert.deepEqual(captured.data.endpoints, { 0, 1, 2, 7 }, "an earlier capture stays detached")
  Assert.equal(captured.data.switchMask, 0)
  Assert.deepEqual(state:capture().data.endpoints, { 5, 1, 2, 7 })
  Assert.equal(state:switchMask(), 1)
end

-- The gym init command resets the union exactly like Save_Gymmick_Init: one
-- kind wins and every other kind's data is gone.
function T.initializing_a_kind_replaces_the_previous_union()
  local state = GymMechanismState.restore(azaleaBucket())
  state:initialize("violet")
  Assert.equal(state:kind(), "violet")
  Assert.isFalse(state:violetRaised(), "a fresh violet union starts on the lower floor")
  state:setVioletRaised(true)
  state:initialize("azalea")
  Assert.equal(state:kind(), "azalea")
  Assert.deepEqual(state:spiderEndpoints(), { 0, 1, 2, 7 }, "the azalea init installs the source spider endpoints")
  Assert.equal(state:switchMask(), 0, "the azalea init installs the source switch mask")
  state:setSpiderEndpoint(3, 9)
  state:initialize("violet")
  Assert.isFalse(state:violetRaised(), "replacing the union drops the previous kind's settled state")
  Assert.throws(function()
    state:spiderEndpoints()
  end, "the azalea accessors are unavailable outside their kind")
end

-- Switch 0 owns the low bit and switch 1 the high bit; any other selector is
-- a source assertion failure, never a silent no-op.
function T.switches_toggle_only_their_own_source_bit()
  local state = GymMechanismState.restore(azaleaBucket())
  state:toggleSwitch(0)
  Assert.equal(state:switchMask(), 1)
  state:toggleSwitch(1)
  Assert.equal(state:switchMask(), 3)
  state:toggleSwitch(0)
  Assert.equal(state:switchMask(), 2)
  state:toggleSwitch(1)
  Assert.equal(state:switchMask(), 0)
  local err = Assert.throws(function()
    state:toggleSwitch(2)
  end)
  Assert.isTrue(Errors.is(err))
  Assert.equal(err.code, FieldErrors.FIELD_GYM_MECHANISM_INVALID)
end

function T.the_spider_lookup_answers_the_node_each_spider_stands_on()
  local state = GymMechanismState.restore(azaleaBucket())
  Assert.equal(state:spiderAtEndpoint(0), 1, "the first spider stands on the first endpoint")
  Assert.equal(state:spiderAtEndpoint(7), 4)
  Assert.isNil(state:spiderAtEndpoint(4), "an unoccupied endpoint owns no spider")
  local err = Assert.throws(function()
    state:spiderAtEndpoint(12)
  end)
  Assert.equal(err.code, FieldErrors.FIELD_GYM_MECHANISM_INVALID)
end

function T.malformed_buckets_are_rejected_without_repair()
  local cases = {
    { bucket = { kind = "violet", data = {} } },
    { bucket = { schema = "hgss-gymmick-v2", kind = "violet", data = { raised = false } } },
    { bucket = { schema = GymMechanismState.SCHEMA, kind = "ecruteak", data = {} } },
    { bucket = { schema = GymMechanismState.SCHEMA, kind = "ecruteak", data = { candles = { false, false, false } } } },
    {
      bucket = {
        schema = GymMechanismState.SCHEMA,
        kind = "ecruteak",
        data = { candles = { false, false, false, 1 } },
      },
    },
    {
      bucket = {
        schema = GymMechanismState.SCHEMA,
        kind = "ecruteak",
        data = { candles = { false, false, false, false }, winchRaised = true },
      },
    },
    { bucket = { schema = GymMechanismState.SCHEMA, kind = "cianwood", data = {} } },
    { bucket = { schema = GymMechanismState.SCHEMA, kind = "cianwood", data = { winchRaised = "yes" } } },
    { bucket = { schema = GymMechanismState.SCHEMA, kind = "none", data = { raised = false } } },
    { bucket = { schema = GymMechanismState.SCHEMA, kind = "violet", data = { raised = "yes" } } },
    { bucket = { schema = GymMechanismState.SCHEMA, kind = "violet", data = { raised = false, extra = 1 } } },
    { bucket = azaleaBucket({ data = { endpoints = { 0, 1, 2 }, switchMask = 0 } }) },
    { bucket = azaleaBucket({ data = { endpoints = { 0, 1, 2, 12 }, switchMask = 0 } }) },
    { bucket = azaleaBucket({ data = { endpoints = { 0, 1, 2, 1.5 }, switchMask = 0 } }) },
    { bucket = azaleaBucket({ data = { endpoints = { 0, 1, 2, 7 }, switchMask = 4 } }) },
    { bucket = azaleaBucket({ data = { endpoints = { 0, 1, 2, 7 } } }) },
  }
  for index, case in ipairs(cases) do
    local err = Assert.throws(function()
      GymMechanismState.restore(case.bucket)
    end)
    Assert.isTrue(Errors.is(err), "case " .. index .. " raises a structured error")
    Assert.equal(err.code, FieldErrors.FIELD_GYM_MECHANISM_INVALID, "case " .. index .. " keeps the bucket invalid")
  end
end

-- The Ecruteak union is four candle bits; the source init clears them and only
-- the candle's own index may change.
function T.the_ecruteak_union_carries_four_candle_states()
  local state = GymMechanismState.restore(nil)
  state:initialize("ecruteak")
  Assert.equal(state:kind(), "ecruteak")
  Assert.deepEqual(state:ecruteakCandles(), { false, false, false, false }, "InitEcruteakGym clears every candle")
  state:setEcruteakCandle(3, true)
  Assert.deepEqual(state:ecruteakCandles(), { false, false, true, false })
  Assert.deepEqual(state:capture().data, { candles = { false, false, true, false } }, "the settled bit is saved")
  local captured = state:capture()
  state:setEcruteakCandle(1, true)
  Assert.deepEqual(captured.data.candles, { false, false, true, false }, "a capture stays detached")

  for _, index in ipairs({ 0, 5, 1.5 }) do
    local err = Assert.throws(function()
      state:setEcruteakCandle(index, true)
    end)
    Assert.equal(err.code, FieldErrors.FIELD_GYM_MECHANISM_INVALID, "candle index " .. tostring(index) .. " is refused")
  end
  Assert.throws(function()
    state:cianwoodWinchRaised()
  end, "the winch accessor is unavailable outside its kind")
end

-- The Cianwood union is the one-shot winch bit, lowered by its own init.
function T.the_cianwood_union_carries_the_winch_bit()
  local state = GymMechanismState.restore({
    schema = GymMechanismState.SCHEMA,
    kind = "cianwood",
    data = { winchRaised = true },
  })
  Assert.isTrue(state:cianwoodWinchRaised(), "the raised winch survives the round trip")
  Assert.deepEqual(state:capture().data, { winchRaised = true })
  state:setCianwoodWinchRaised(false)
  Assert.isFalse(state:cianwoodWinchRaised())
  state:initialize("cianwood")
  Assert.isFalse(state:cianwoodWinchRaised(), "InitCianwoodGym installs a lowered winch")
  Assert.throws(function()
    state:ecruteakCandles()
  end, "the candle accessor is unavailable outside its kind")
end

-- The Blackthorn union is the three source platform anchors; its own init
-- places them, a move writes one anchor and a turn advances one rotation.
function T.the_blackthorn_union_carries_the_three_platform_anchors()
  local state = GymMechanismState.restore(nil)
  state:initialize("blackthorn")
  Assert.equal(state:kind(), "blackthorn")
  Assert.deepEqual(state:blackthornPlatforms(), {
    { x = 13, z = 75, rotation = 0 },
    { x = 9, z = 58, rotation = 1 },
    { x = 14, z = 32, rotation = 0 },
  }, "InitBlackthornGym places the three source platforms")
  Assert.deepEqual(state:capture(), {
    schema = GymMechanismState.SCHEMA,
    kind = "blackthorn",
    data = {
      platforms = {
        { x = 13, z = 75, rotation = 0 },
        { x = 9, z = 58, rotation = 1 },
        { x = 14, z = 32, rotation = 0 },
      },
    },
  }, "the settled anchors are saved as three platform tuples")

  state:setBlackthornPlatformPosition(1, 18, 75)
  Assert.deepEqual(state:blackthornPlatforms()[1], { x = 18, z = 75, rotation = 0 }, "a move writes its anchor")
  state:advanceBlackthornRotation(2)
  Assert.deepEqual(state:blackthornPlatforms()[2], { x = 9, z = 58, rotation = 2 }, "a turn advances one quarter")
  state:advanceBlackthornRotation(2)
  state:advanceBlackthornRotation(2)
  state:advanceBlackthornRotation(2)
  state:advanceBlackthornRotation(2)
  Assert.equal(state:blackthornPlatforms()[2].rotation, 2, "four quarter turns wrap back to the same quarter")

  -- A captured record never aliases the live anchors.
  local captured = state:capture()
  state:setBlackthornPlatformPosition(1, 1, 2)
  Assert.deepEqual(captured.data.platforms[1], { x = 18, z = 75, rotation = 0 }, "a capture stays detached")

  for _, index in ipairs({ 0, 4, 1.5 }) do
    local err = Assert.throws(function()
      state:setBlackthornPlatformPosition(index, 1, 1)
    end)
    Assert.equal(
      err.code,
      FieldErrors.FIELD_GYM_MECHANISM_INVALID,
      "platform index " .. tostring(index) .. " is refused"
    )
  end
  Assert.throws(function()
    state:setBlackthornPlatformPosition(1, -1, 1)
  end, "an anchor outside the source tile range is refused")
  Assert.throws(function()
    state:violetRaised()
  end, "the lift accessor is unavailable outside its kind")
end

-- A saved blackthorn bucket round-trips, and a malformed one is rejected rather
-- than repaired.
function T.the_blackthorn_union_is_strict_about_its_three_anchors()
  local bucket = {
    schema = GymMechanismState.SCHEMA,
    kind = "blackthorn",
    data = {
      platforms = {
        { x = 18, z = 75, rotation = 3 },
        { x = 9, z = 54, rotation = 2 },
        { x = 14, z = 32, rotation = 0 },
      },
    },
  }
  local restored = GymMechanismState.restore(bucket)
  Assert.deepEqual(restored:blackthornPlatforms(), bucket.data.platforms, "the settled anchors survive a reload")

  local cases = {
    { data = {} },
    { data = { platforms = {} } },
    { data = { platforms = { { x = 1, z = 1, rotation = 0 } } } },
    { data = { platforms = { { x = 1, z = 1, rotation = 0 }, { x = 2, z = 2, rotation = 0 } } } },
    {
      data = {
        platforms = { { x = 1, z = 1, rotation = 0 }, { x = 2, z = 2, rotation = 0 }, { x = 3, z = 3, rotation = 4 } },
      },
    },
    { data = { platforms = { { x = 1, z = 1, rotation = 0 }, { x = 2, z = 2, rotation = 0 }, { x = 3, z = 3 } } } },
    {
      data = {
        platforms = {
          { x = 1, z = 1, rotation = 0 },
          { x = 2, z = 2, rotation = 0 },
          { x = 3, z = 3, rotation = 0, extra = true },
        },
      },
    },
    {
      data = {
        platforms = { { x = 1.5, z = 1, rotation = 0 }, { x = 2, z = 2, rotation = 0 }, { x = 3, z = 3, rotation = 0 } },
      },
    },
    {
      data = {
        platforms = { { x = 1, z = 1, rotation = 0 }, { x = 2, z = 2, rotation = 0 }, { x = 3, z = 3, rotation = 0 } },
        extra = 1,
      },
    },
  }
  for index, case in ipairs(cases) do
    local err = Assert.throws(function()
      GymMechanismState.restore({ schema = GymMechanismState.SCHEMA, kind = "blackthorn", data = case.data })
    end)
    Assert.equal(err.code, FieldErrors.FIELD_GYM_MECHANISM_INVALID, "case " .. index .. " keeps the bucket invalid")
  end
end

-- The previous kinds still round-trip unchanged beside the new ones.
function T.the_new_kinds_do_not_disturb_the_previous_union()
  local state = GymMechanismState.restore(azaleaBucket())
  state:initialize("ecruteak")
  state:initialize("azalea")
  Assert.deepEqual(state:spiderEndpoints(), { 0, 1, 2, 7 }, "the azalea init still installs its source defaults")
  local violet = GymMechanismState.restore({
    schema = GymMechanismState.SCHEMA,
    kind = "violet",
    data = { raised = true },
  })
  Assert.isTrue(violet:violetRaised())
  state:initialize("blackthorn")
  state:setBlackthornPlatformPosition(3, 20, 32)
  state:initialize("azalea")
  Assert.deepEqual(state:spiderEndpoints(), { 0, 1, 2, 7 }, "a blackthorn union never leaks into the next kind")
end

return { tests = T }
