-- FieldTravelState contract tests: semantic respawn and special-spawn
-- values owned as copied records, never live pointers.

local Assert = require("tests.support.Assert")
local FieldTravelState = require("libs.hgss.src.field.FieldTravelState")

local T = {}

local function travel(overrides)
  local value = { lastHealSpawn = "SPAWN_NEW_BARK" }
  for key, item in pairs(overrides or {}) do
    value[key] = item
  end
  return value
end

function T.default_spawn_is_the_documented_mother_spawn()
  Assert.equal(FieldTravelState.DEFAULT_LAST_HEAL_SPAWN, "SPAWN_NEW_BARK")
end

function T.capture_returns_a_copy()
  local state = FieldTravelState.new(travel())
  local snapshot = state:capture()
  Assert.deepEqual(snapshot, { lastHealSpawn = "SPAWN_NEW_BARK" })
  snapshot.lastHealSpawn = "SPAWN_PALLET"
  Assert.equal(state:capture().lastHealSpawn, "SPAWN_NEW_BARK")
end

function T.heal_spawn_updates_explicitly_only()
  local state = FieldTravelState.new(travel())
  state:setLastHealSpawn("SPAWN_GOLDENROD")
  Assert.equal(state:capture().lastHealSpawn, "SPAWN_GOLDENROD")
  Assert.throws(function()
    state:setLastHealSpawn("")
  end)
  Assert.throws(function()
    ---@diagnostic disable-next-line: param-type-mismatch -- test deliberately exercises an invalid call
    state:setLastHealSpawn(7)
  end)
  Assert.equal(state:capture().lastHealSpawn, "SPAWN_GOLDENROD")
end

function T.trusted_restore_takes_ownership_copies()
  local special = { map = "MAP_UNION_CAVE_1F", fieldX = 10, fieldZ = 20, warpId = -1, direction = "north" }
  local snapshot = travel({ lastHealSpawn = "SPAWN_GOLDENROD", specialSpawn = special })
  local state = FieldTravelState.new(snapshot)
  snapshot.lastHealSpawn = "SPAWN_PALLET"
  snapshot.specialSpawn.fieldX = 999
  Assert.equal(state:capture().lastHealSpawn, "SPAWN_GOLDENROD", "restore copies the spawn value")
  Assert.equal(state:capture().specialSpawn.fieldX, 10, "restore copies the special spawn record")
  Assert.deepEqual(state:capture(), {
    lastHealSpawn = "SPAWN_GOLDENROD",
    specialSpawn = { map = "MAP_UNION_CAVE_1F", fieldX = 10, fieldZ = 20, warpId = -1, direction = "north" },
  })
end

function T.constructor_rejects_malformed_save_data()
  Assert.throws(function()
    FieldTravelState.new({})
  end)
  Assert.throws(function()
    FieldTravelState.new(travel({ lastHealSpawn = "" }))
  end)
end

function T.special_spawn_defaults_to_nil_and_round_trips_a_copied_record()
  local state = FieldTravelState.new(travel())
  Assert.isNil(state:specialSpawn())
  Assert.isNil(state:capture().specialSpawn)
  local input = { map = "MAP_NEW_BARK", fieldX = 688, fieldZ = 393, warpId = -1, direction = "south" }
  state:setSpecialSpawn(input)
  Assert.deepEqual(state:specialSpawn(), input)
  Assert.deepEqual(state:capture().specialSpawn, input)
  input.fieldX = 999
  Assert.equal(state:specialSpawn().fieldX, 688, "later caller mutation must not reach travel state")
  local observed = state:specialSpawn()
  observed.map = "MAP_MUTATED"
  Assert.equal(state:specialSpawn().map, "MAP_NEW_BARK", "getter results share no identity with the owner")
  local snapshot = state:capture()
  snapshot.specialSpawn.direction = "north"
  Assert.equal(state:specialSpawn().direction, "south", "captures share no identity with the owner")
end

function T.special_spawn_rejects_malformed_records_without_mutating_prior_value()
  local state = FieldTravelState.new(travel())
  local malformed = {
    { map = "", fieldX = 1, fieldZ = 2, warpId = -1, direction = "south" },
    { map = 7, fieldX = 1, fieldZ = 2, warpId = -1, direction = "south" },
    { map = "MAP_X", fieldX = -1, fieldZ = 2, warpId = -1, direction = "south" },
    { map = "MAP_X", fieldX = 1.5, fieldZ = 2, warpId = -1, direction = "south" },
    { map = "MAP_X", fieldX = 1, fieldZ = 2, warpId = 0.5, direction = "south" },
    { map = "MAP_X", fieldX = 1, fieldZ = 2, warpId = "-1", direction = "south" },
    { map = "MAP_X", fieldX = 1, fieldZ = 2, warpId = -1, direction = "up" },
  }
  for _, record in ipairs(malformed) do
    Assert.throws(function()
      state:setSpecialSpawn(record)
    end)
  end
  Assert.isNil(state:specialSpawn(), "failed updates leave the unset value unchanged")
  local established = { map = "MAP_NEW_BARK", fieldX = 688, fieldZ = 393, warpId = -1, direction = "south" }
  state:setSpecialSpawn(established)
  for _, record in ipairs(malformed) do
    Assert.throws(function()
      state:setSpecialSpawn(record)
    end)
  end
  Assert.deepEqual(state:specialSpawn(), established, "failed updates preserve the prior record")
end

function T.constructor_copies_an_optional_special_spawn_and_rejects_malformed_persisted_values()
  local persisted = { map = "MAP_NEW_BARK", fieldX = 688, fieldZ = 393, warpId = -1, direction = "south" }
  local state = FieldTravelState.new(travel({ specialSpawn = persisted }))
  Assert.deepEqual(state:specialSpawn(), persisted)
  persisted.map = "MAP_MUTATED"
  Assert.equal(state:specialSpawn().map, "MAP_NEW_BARK", "construction copies the persisted record")
  Assert.throws(function()
    FieldTravelState.new(travel({
      specialSpawn = { map = "", fieldX = 1, fieldZ = 2, warpId = -1, direction = "south" },
    }))
  end)
end

function T.constructor_copies_an_optional_special_spawn_and_rejects_malformed_persisted_values()
  local persisted = { map = "MAP_NEW_BARK", fieldX = 688, fieldZ = 393, warpId = -1, direction = "south" }
  local state = FieldTravelState.new(travel({ specialSpawn = persisted }))
  Assert.deepEqual(state:specialSpawn(), persisted)
  persisted.map = "MAP_MUTATED"
  Assert.equal(state:specialSpawn().map, "MAP_NEW_BARK", "construction copies the persisted record")
  Assert.throws(function()
    FieldTravelState.new(travel({
      specialSpawn = { map = "", fieldX = 1, fieldZ = 2, warpId = -1, direction = "south" },
    }))
  end)
end

-- The source dynamic warp (SetDynamicWarp) is a durable destination written by
-- scripts and read back by floor queries. It is a separate record from the
-- special spawn and from the last-heal spawn, and it starts unestablished.
local function dynamicWarp(overrides)
  local value = {
    map = "MAP_GOLDENROD_RADIO_TOWER_5F",
    warpId = 2,
    fieldX = 10,
    fieldZ = 20,
    direction = "north",
  }
  for key, item in pairs(overrides or {}) do
    value[key] = item
  end
  return value
end

function T.dynamic_warp_is_a_separate_durable_record()
  local state = FieldTravelState.new(travel())
  Assert.isNil(state:dynamicWarp(), "an existing save establishes no dynamic destination")
  Assert.isNil(state:capture().dynamicWarp)

  local input = dynamicWarp()
  state:setDynamicWarp(input)
  Assert.deepEqual(state:dynamicWarp(), input)
  Assert.deepEqual(state:capture().dynamicWarp, input, "the destination survives travel capture")
  Assert.isNil(state:specialSpawn(), "the dynamic destination never becomes the special spawn")
  Assert.equal(state:capture().lastHealSpawn, "SPAWN_NEW_BARK", "the last-heal spawn is untouched")

  input.fieldX = 999
  Assert.equal(state:dynamicWarp().fieldX, 10, "later caller mutation must not reach travel state")
  local observed = assert(state:dynamicWarp())
  observed.map = "MAP_MUTATED"
  Assert.equal(
    state:dynamicWarp().map,
    "MAP_GOLDENROD_RADIO_TOWER_5F",
    "getter results share no identity with the owner"
  )
  local snapshot = state:capture()
  snapshot.dynamicWarp.direction = "south"
  Assert.equal(state:dynamicWarp().direction, "north", "captures share no identity with the owner")
end

function T.dynamic_warp_restore_accepts_buckets_without_it_and_rejects_malformed_records()
  local special = { map = "MAP_UNION_CAVE_1F", fieldX = 10, fieldZ = 20, warpId = -1, direction = "north" }
  local restored = FieldTravelState.new(travel({ specialSpawn = special }))
  Assert.isNil(restored:dynamicWarp(), "a save without a dynamic destination stays unestablished")
  Assert.deepEqual(restored:specialSpawn(), special, "the restored special spawn is unaffected")

  local persisted = dynamicWarp()
  local state = FieldTravelState.new(travel({ dynamicWarp = persisted, specialSpawn = special }))
  Assert.deepEqual(state:dynamicWarp(), persisted, "construction copies the persisted destination")
  persisted.map = "MAP_MUTATED"
  Assert.equal(state:dynamicWarp().map, "MAP_GOLDENROD_RADIO_TOWER_5F")

  local malformed = {
    { map = "", warpId = 2, fieldX = 10, fieldZ = 20, direction = "north" },
    { map = 7, warpId = 2, fieldX = 10, fieldZ = 20, direction = "north" },
    { map = "MAP_X", warpId = 2, fieldX = -1, fieldZ = 20, direction = "north" },
    { map = "MAP_X", warpId = 2, fieldX = 10.5, fieldZ = 20, direction = "north" },
    { map = "MAP_X", warpId = 2, fieldX = 10, fieldZ = 20.5, direction = "north" },
    { map = "MAP_X", warpId = "2", fieldX = 10, fieldZ = 20, direction = "north" },
    { map = "MAP_X", warpId = 2, fieldX = 10, fieldZ = 20, direction = "up" },
  }
  for _, record in ipairs(malformed) do
    Assert.throws(function()
      FieldTravelState.new(travel({ dynamicWarp = record }))
    end, "a malformed persisted dynamic destination is rejected")
    Assert.throws(function()
      state:setDynamicWarp(record)
    end, "a malformed dynamic destination write is rejected")
  end
  Assert.deepEqual(state:dynamicWarp(), dynamicWarp(), "failed writes preserve the prior destination")
  Assert.deepEqual(state:specialSpawn(), special, "failed dynamic writes never touch the special spawn")
end

return { tests = T }
