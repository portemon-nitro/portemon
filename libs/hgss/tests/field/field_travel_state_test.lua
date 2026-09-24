-- FieldTravelState contract tests: semantic respawn and escape-entrance
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

function T.escape_entrance_round_trips_and_clears()
  local state = FieldTravelState.new(travel())
  Assert.isNil(state:capture().escapeEntrance)
  local entrance = { map = "MAP_UNION_CAVE_1F", fieldX = 10, fieldZ = 20, facing = "north" }
  state:setEscapeEntrance(entrance)
  Assert.deepEqual(state:capture().escapeEntrance, entrance)
  entrance.fieldX = 999
  Assert.equal(state:capture().escapeEntrance.fieldX, 10)
  state:clearEscapeEntrance()
  Assert.isNil(state:capture().escapeEntrance)
end

function T.escape_entrance_rejects_malformed_records()
  local state = FieldTravelState.new(travel())
  Assert.throws(function()
    state:setEscapeEntrance({ map = "", fieldX = 1, fieldZ = 2, facing = "north" })
  end)
  Assert.throws(function()
    state:setEscapeEntrance({ map = "MAP_X", fieldX = 1, fieldZ = 2, facing = "up" })
  end)
  Assert.throws(function()
    state:setEscapeEntrance({ map = "MAP_X", fieldX = -1, fieldZ = 2, facing = "north" })
  end)
  Assert.isNil(state:capture().escapeEntrance)
end

function T.constructor_rejects_malformed_save_data()
  Assert.throws(function()
    FieldTravelState.new({})
  end)
  Assert.throws(function()
    FieldTravelState.new(travel({ lastHealSpawn = "" }))
  end)
end

return { tests = T }
