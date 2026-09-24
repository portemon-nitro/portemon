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

function T.exception_maps_are_explicit_symbols()
  Assert.equal(FieldMoveSources.ICE_PATH_B2F_SYMBOL, "MAP_ICE_PATH_B2F")
  Assert.equal(FieldMoveSources.ALPH_FLASH_SYMBOL, "MAP_RUINS_OF_ALPH_UNDERGROUND_HALL")
end

return { tests = T }
