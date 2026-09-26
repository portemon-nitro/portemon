-- FieldMoveSources contract tests: verified source move/badge/map/object
-- policy facts stay producer-owned, with numeric source identities resolved
-- here and semantic keys crossing to runtime.

local Assert = require("tests.support.Assert")
local FieldMoveSources = require("romdump.src.config.FieldMoveSources")
local Spawns = require("romdump.src.reference.hgss.spawns")

local T = {}

function T.sixteen_moves_have_ordered_badge_gates()
  Assert.equal(#FieldMoveSources.MOVE_KEYS, 16)
  local gates = FieldMoveSources.badgeGate
  Assert.equal(gates.cut, "hive")
  Assert.equal(gates.fly, "storm")
  Assert.equal(gates.surf, "fog")
  Assert.equal(gates.strength, "plain")
  Assert.equal(gates.rock_smash, "zephyr")
  Assert.equal(gates.waterfall, "rising")
  Assert.equal(gates.rock_climb, "earth")
  Assert.equal(gates.whirlpool, "glacier")
  Assert.isNil(gates.flash)
  Assert.isNil(gates.headbutt)
end

function T.badge_order_matches_progression_order()
  Assert.deepEqual(FieldMoveSources.BADGE_ORDER, FieldMoveSources.BADGE_KEYS)
end

function T.badge_indexes_resolve_in_semantic_order()
  Assert.equal(FieldMoveSources.badgeKeyForIndex(0), "zephyr")
  Assert.equal(FieldMoveSources.badgeKeyForIndex(1), "hive")
  Assert.equal(FieldMoveSources.badgeKeyForIndex(7), "rising")
  Assert.equal(FieldMoveSources.badgeKeyForIndex(8), "boulder")
  Assert.equal(FieldMoveSources.badgeKeyForIndex(15), "earth")
  Assert.isNil(FieldMoveSources.badgeKeyForIndex(16))
  Assert.isNil(FieldMoveSources.badgeKeyForIndex(-1))
end

function T.mother_spawn_resolves_through_the_frozen_spawn_catalog()
  local id = FieldMoveSources.MOTHER_SPAWN_ID
  Assert.equal(Spawns.byId[id], "SPAWN_NEW_BARK")
  Assert.equal(FieldMoveSources.MOTHER_SPAWN_NAME, "SPAWN_NEW_BARK")
end

function T.flash_weather_ids_cover_the_dark_caves()
  local snowy = false
  for _, id in ipairs(FieldMoveSources.FLASH_WEATHER_IDS) do
    Assert.isTrue(type(id) == "number")
    if id == 11 then
      snowy = true
    end
  end
  Assert.isTrue(snowy)
end

function T.obstacle_kinds_form_a_closed_vocabulary()
  Assert.deepEqual(FieldMoveSources.OBSTACLE_KINDS, {
    "cut_tree",
    "smash_rock",
    "strength_boulder",
    "headbutt_tree",
  })
  Assert.equal(FieldMoveSources.obstacleKindForSprite(1), nil)
end

function T.obstacle_sprites_resolve_their_verified_kinds()
  Assert.equal(FieldMoveSources.obstacleKindForSprite(86), "cut_tree")
  Assert.equal(FieldMoveSources.obstacleKindForSprite(84), "strength_boulder")
  Assert.equal(FieldMoveSources.obstacleKindForSprite(85), "smash_rock")
end

function T.exception_maps_are_explicit_symbols()
  Assert.equal(FieldMoveSources.ICE_PATH_B2F_SYMBOL, "MAP_ICE_PATH_B2F")
  Assert.equal(FieldMoveSources.ALPH_FLASH_SYMBOL, "MAP_RUINS_OF_ALPH_UNDERGROUND_HALL")
end

function T.spawn_destinations_cover_every_frozen_spawn_name()
  local count = 0
  for id, name in pairs(Spawns.byId) do
    if name ~= "SPAWN_NONE" then
      local destination = assert(
        FieldMoveSources.spawnDestinationForKey(name),
        "every frozen spawn resolves: " .. name .. " (id " .. tostring(id) .. ")"
      )
      Assert.equal(type(destination.map), "string", name .. " names a map")
      count = count + 1
    end
  end
  Assert.equal(count, 30, "all thirty source spawns resolve")
end

function T.spawn_destinations_pin_mother_and_updated_history()
  local mother = FieldMoveSources.spawnDestinationForKey("SPAWN_NEW_BARK")
  Assert.deepEqual(mother, { map = "MAP_NEW_BARK", fieldX = 695, fieldZ = 397 })
  local goldenrod = FieldMoveSources.spawnDestinationForKey("SPAWN_GOLDENROD")
  Assert.deepEqual(goldenrod, { map = "MAP_GOLDENROD", fieldX = 352, fieldZ = 369 })
end

function T.spawn_destinations_answer_fresh_records_and_refuse_garbage()
  local first = assert(FieldMoveSources.spawnDestinationForKey("SPAWN_VIOLET"), "violet resolves")
  first.map = "MAP_MUTATED"
  local second = assert(FieldMoveSources.spawnDestinationForKey("SPAWN_VIOLET"), "violet resolves again")
  Assert.equal(second.map, "MAP_VIOLET", "callers receive copies, never the live table")
  Assert.isNil(FieldMoveSources.spawnDestinationForKey("SPAWN_NOWHERE"))
  Assert.isNil(FieldMoveSources.spawnDestinationForKey(nil))
  ---@diagnostic disable-next-line: param-type-mismatch -- the integer is the invalid input under test
  Assert.isNil(FieldMoveSources.spawnDestinationForKey(7))
end

return { tests = T }
