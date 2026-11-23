-- ScriptMapsService: the script-facing map/warp abstraction. Source `Warp`
-- after a completed source screen fade must perform a covered map swap
-- (reusing transition preparation/commit without a second ordinary fade
-- pair), and the source special-spawn setter (opcode 582) delegates to the
-- durable travel owner instead of keeping transient scratch state.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local FieldTransition = require("libs.hgss.src.transition.FieldTransition")
local FieldTravelState = require("libs.hgss.src.field.FieldTravelState")
local ScriptMapsService = require("libs.hgss.src.script.ScriptMapsService")
local WarpSystem = require("libs.hgss.src.transition.WarpSystem")

local T = {}

local function fakeLoader()
  return {
    load = function(_, ref)
      return { mapId = ref, coordinateOrigin = { x = 600, z = 300 } }
    end,
    mapPlacement = function(_, _)
      return { id = 61, originX = 600, originZ = 300 }
    end,
  }
end

local function fakeSourceMap()
  return { mapId = "MAP_NEW_BARK" }
end

local function target()
  return { map = "MAP_NEW_BARK_ELMS_LAB_2F", warp = 0, fieldX = 12, fieldZ = 6, facing = "west" }
end

local function serviceWithTravel(travel)
  return ScriptMapsService.new({
    transition = { start = function() end },
    loader = fakeLoader(),
    sourceMap = fakeSourceMap(),
    travel = travel,
  })
end

function T.covered_scripted_warps_can_be_reused_after_success()
  local calls = {}
  local transition = {
    phase = FieldTransition.PHASES.idle,
    sourceMap = nil,
    startCoveredSwap = function(self, sourceMap)
      calls[#calls + 1] = sourceMap
      self.phase = FieldTransition.PHASES.load_destination
      self.sourceMap = sourceMap
    end,
  }
  local service = ScriptMapsService.new({
    transition = transition,
    loader = fakeLoader(),
    sourceMap = fakeSourceMap(),
    screen = {
      isOpaque = function()
        return true
      end,
    },
  })

  service:startWarp(target())
  Assert.isFalse(service:warpDone(), "a covered warp stays pending while it owns its source map")
  transition.phase = FieldTransition.PHASES.idle
  transition.sourceMap = nil
  Assert.isTrue(service:warpDone(), "the first covered warp completes after transition ownership returns")
  Assert.isFalse(service:warpDone(), "a completed warp is consumed once")

  local replacementSourceMap = { mapId = "MAP_NEW_BARK_ELMS_LAB_2F" }
  service:setSourceMap(replacementSourceMap)
  service:startWarp(target())

  Assert.equal(#calls, 2, "the same service starts the next covered warp")
  Assert.equal(calls[2], replacementSourceMap, "the next covered warp uses the rebound source map")
end

function T.covered_scripted_warp_failure_is_exposed_and_does_not_poison_reuse()
  local calls = 0
  local transition = {
    phase = FieldTransition.PHASES.load_destination,
    sourceMap = fakeSourceMap(),
    startCoveredSwap = function(self)
      calls = calls + 1
      self.phase = FieldTransition.PHASES.load_destination
      self.sourceMap = fakeSourceMap()
    end,
  }
  local service = ScriptMapsService.new({
    transition = transition,
    loader = fakeLoader(),
    sourceMap = fakeSourceMap(),
    screen = {
      isOpaque = function()
        return true
      end,
    },
  })
  local failure = { code = "transition failed" }

  service:startWarp(target())
  transition.error = failure
  Assert.isTrue(service:warpDone(), "a failed covered transition completes its warp task")
  Assert.equal(service:pendingError(), failure, "the exact transition failure remains available to the script task")

  transition.error = nil
  transition.phase = FieldTransition.PHASES.idle
  transition.sourceMap = nil
  service:startWarp(target())

  Assert.equal(calls, 2, "a covered failure does not prevent a later warp from starting")
end

-- A covered scripted swap must not start the ordinary FieldTransition fade
-- lifecycle when the source screen already owns opaque cover; it must use a
-- dedicated covered-swap entry point instead.
function T.a_covered_scripted_swap_never_starts_the_ordinary_transition_fade()
  local calls = {}
  local fakeTransition = {
    start = function()
      calls[#calls + 1] = "start"
    end,
    startCoveredSwap = function(_, sourceMap, trigger, facing)
      calls[#calls + 1] = {
        method = "startCoveredSwap",
        sourceMap = sourceMap,
        trigger = trigger,
        facing = facing,
      }
    end,
  }
  local screen = {
    isOpaque = function()
      return true
    end,
  }
  local sourceMap = fakeSourceMap()
  local service = ScriptMapsService.new({
    transition = fakeTransition,
    loader = fakeLoader(),
    sourceMap = sourceMap,
    screen = screen,
  })
  service:startWarp(target())
  Assert.equal(#calls, 1, "a covered scripted warp starts exactly one transition")
  Assert.equal(calls[1].method, "startCoveredSwap", "the opaque source screen stays owned by its caller")
  Assert.equal(calls[1].sourceMap, sourceMap, "the current source map is retained")
  Assert.deepEqual(calls[1].trigger, {
    warp = {
      index = 0,
      x = 612,
      z = 306,
      destinationMapId = 61,
      destinationWarpId = 0,
      direct = true,
    },
  }, "the structural placement resolves the record without building assets")
  Assert.equal(calls[1].facing, "west")
end

-- A covered swap without opaque cover is an explicit failure, never a
-- silently inserted ordinary fade.
function T.a_covered_scripted_swap_without_opaque_cover_fails_explicitly()
  local loaderCalls = 0
  local transitionCalls = 0
  local fakeTransition = {
    start = function()
      transitionCalls = transitionCalls + 1
    end,
    startCoveredSwap = function()
      transitionCalls = transitionCalls + 1
    end,
  }
  local screen = {
    isOpaque = function()
      return false
    end,
  }
  local service = ScriptMapsService.new({
    transition = fakeTransition,
    loader = {
      load = function(_, ref)
        loaderCalls = loaderCalls + 1
        return { mapId = ref, coordinateOrigin = { x = 600, z = 300 } }
      end,
    },
    sourceMap = fakeSourceMap(),
    screen = screen,
  })
  local ok = pcall(function()
    service:startWarp(target())
  end)
  Assert.isFalse(ok, "a covered swap must require opaque screen cover before committing, not silently proceed")
  Assert.equal(loaderCalls, 0, "the opaque-cover precondition is checked before acquiring a destination")
  Assert.equal(transitionCalls, 0, "the transition remains untouched without opaque cover")
end

-- Opcode 582's special-spawn setter writes the durable travel owner: the
-- value is observable through the owner and survives its capture.
function T.special_spawn_setter_writes_the_injected_travel_owner()
  local travel = FieldTravelState.new({ lastHealSpawn = "SPAWN_NEW_BARK" })
  local service = serviceWithTravel(travel)
  Assert.isNil(service:specialSpawn(), "no special spawn is recorded before the source setter runs")
  local input = { map = "MAP_NEW_BARK", fieldX = 688, fieldZ = 393, warpId = -1, direction = "south" }
  service:setSpecialSpawn(input)
  Assert.deepEqual(service:specialSpawn(), input)
  Assert.deepEqual(travel:specialSpawn(), input, "the setter writes the durable travel owner")
  Assert.deepEqual(travel:capture().specialSpawn, input, "the delegated value survives travel capture")
  input.map = "MAP_MUTATED"
  Assert.equal(travel:specialSpawn().map, "MAP_NEW_BARK", "delegation copies across the boundary")
end

-- Retail opcode 582 nodes carry numeric map ids; the setter resolves them
-- to the semantic symbol before the unchanged durable write. The stored
-- record is a copy: mutating the caller input or the observed output
-- leaves the owner unchanged.
function T.numeric_map_id_resolves_to_the_semantic_record_before_the_durable_write()
  local travel = FieldTravelState.new({ lastHealSpawn = "SPAWN_NEW_BARK" })
  local service = ScriptMapsService.new({
    transition = { start = function() end },
    loader = {
      load = function(_, ref)
        return { mapId = ref, coordinateOrigin = { x = 600, z = 300 } }
      end,
      mapSymbol = function(_, id)
        assert(id == 60, "unexpected map id")
        return "MAP_NEW_BARK"
      end,
    },
    sourceMap = fakeSourceMap(),
    travel = travel,
  })
  local input = { map = 60, fieldX = 688, fieldZ = 393, warpId = -1, direction = "south" }
  service:setSpecialSpawn(input)
  local expected = { map = "MAP_NEW_BARK", fieldX = 688, fieldZ = 393, warpId = -1, direction = "south" }
  Assert.deepEqual(service:specialSpawn(), expected)
  Assert.deepEqual(travel:specialSpawn(), expected, "the resolved record reaches the durable travel owner")
  Assert.deepEqual(travel:capture().specialSpawn, expected, "the resolved record survives travel capture")
  input.map = 61
  input.fieldX = 0
  Assert.equal(
    travel:specialSpawn().map,
    "MAP_NEW_BARK",
    "the write copies the resolved record, never the caller table"
  )
  local observed = service:specialSpawn()
  observed.map = "MAP_MUTATED"
  Assert.equal(travel:specialSpawn().map, "MAP_NEW_BARK", "getter results share no identity with the owner")
end

-- An unknown numeric id raises loudly with the prior travel value intact.
function T.unknown_numeric_map_id_raises_without_changing_the_prior_value()
  local travel = FieldTravelState.new({ lastHealSpawn = "SPAWN_NEW_BARK" })
  local established = { map = "MAP_NEW_BARK", fieldX = 688, fieldZ = 393, warpId = -1, direction = "south" }
  local service = ScriptMapsService.new({
    transition = { start = function() end },
    loader = {
      load = function(_, ref)
        return { mapId = ref, coordinateOrigin = { x = 600, z = 300 } }
      end,
      mapSymbol = function(_, id)
        if id == 60 then
          return "MAP_NEW_BARK"
        end
        error(Errors.new("FIELD_MAP_UNKNOWN", "no runtime map for " .. tostring(id), { key = id }))
      end,
    },
    sourceMap = fakeSourceMap(),
    travel = travel,
  })
  service:setSpecialSpawn(established)
  Assert.throws(function()
    service:setSpecialSpawn({ map = 999, fieldX = 1, fieldZ = 2, warpId = -1, direction = "south" })
  end)
  Assert.deepEqual(travel:specialSpawn(), established, "a failed numeric write preserves the prior record")
  Assert.deepEqual(travel:capture().specialSpawn, established)
end

-- Warp-only consumers stay valid without travel; only special-spawn access
-- faults loudly.
function T.special_spawn_without_travel_faults_while_warp_use_stays_valid()
  local service = ScriptMapsService.new({
    transition = { start = function() end },
    loader = fakeLoader(),
    sourceMap = fakeSourceMap(),
  })
  service:startWarp(target())
  Assert.throws(function()
    service:setSpecialSpawn({ map = "MAP_NEW_BARK", fieldX = 1, fieldZ = 2, warpId = -1, direction = "south" })
  end)
  Assert.throws(function()
    service:specialSpawn()
  end)
end

-- The source dynamic destination (SetDynamicWarp) is its own durable travel
-- value: numeric source map ids resolve to the record symbol, and the write
-- never aliases the special spawn.
function T.dynamic_warp_setter_writes_a_separate_durable_destination()
  local travel = FieldTravelState.new({ lastHealSpawn = "SPAWN_NEW_BARK" })
  local service = ScriptMapsService.new({
    transition = { start = function() end },
    loader = {
      load = function(_, ref)
        return { mapId = ref, coordinateOrigin = { x = 600, z = 300 } }
      end,
      mapSymbol = function(_, id)
        if id == 60 then
          return "MAP_GOLDENROD_RADIO_TOWER_5F"
        end
        error(Errors.new("FIELD_MAP_UNKNOWN", "no runtime map for " .. tostring(id), { key = id }))
      end,
    },
    sourceMap = fakeSourceMap(),
    travel = travel,
  })
  local special = { map = "MAP_NEW_BARK", fieldX = 688, fieldZ = 393, warpId = -1, direction = "south" }
  service:setSpecialSpawn(special)

  Assert.isNil(travel:dynamicWarp(), "no dynamic destination exists before the source setter runs")
  service:setDynamicWarp({ map = 60, warpId = 2, fieldX = 10, fieldZ = 20, direction = "north" })
  local expected = {
    map = "MAP_GOLDENROD_RADIO_TOWER_5F",
    warpId = 2,
    fieldX = 10,
    fieldZ = 20,
    direction = "north",
  }
  Assert.deepEqual(travel:dynamicWarp(), expected, "the resolved destination reaches the durable travel owner")
  Assert.deepEqual(travel:capture().dynamicWarp, expected, "the destination survives travel capture")
  Assert.deepEqual(travel:specialSpawn(), special, "the special spawn stays its own value")

  Assert.throws(function()
    service:setDynamicWarp({ map = 999, warpId = 0, fieldX = 1, fieldZ = 2, direction = "north" })
  end)
  Assert.deepEqual(travel:dynamicWarp(), expected, "an unknown source map leaves the prior destination intact")
end

-- A scripted dynamic warp reads its direction through ScriptGetVar, so the
-- evaluated source code reaches the durable record as its cardinal direction;
-- a code outside the source set never overwrites the established destination.
function T.dynamic_warp_setter_normalizes_the_source_direction_code()
  local travel = FieldTravelState.new({ lastHealSpawn = "SPAWN_NEW_BARK" })
  local service = ScriptMapsService.new({
    transition = { start = function() end },
    loader = fakeLoader(),
    sourceMap = fakeSourceMap(),
    travel = travel,
  })
  service:setDynamicWarp({
    map = "MAP_GOLDENROD_DEPARTMENT_STORE_2F",
    warpId = 1,
    fieldX = 4,
    fieldZ = 5,
    direction = 1,
  })
  Assert.equal(assert(travel:dynamicWarp()).direction, "south", "the evaluated code becomes its source direction")

  local err = Assert.throws(function()
    service:setDynamicWarp({
      map = "MAP_GOLDENROD_DEPARTMENT_STORE_2F",
      warpId = 1,
      fieldX = 4,
      fieldZ = 5,
      direction = 9,
    })
  end)
  Assert.isTrue(Errors.is(err), "a direction outside the source set is an attributed failure")
  Assert.equal(assert(travel:dynamicWarp()).direction, "south", "a rejected write keeps the prior destination")
end

-- The floor answer is the pinned source map table, not a guess from the map
-- name: several source elevators skip or restart their numbering.
function T.dynamic_warp_floor_follows_the_source_map_table()
  local travel = FieldTravelState.new({ lastHealSpawn = "SPAWN_NEW_BARK" })
  local service = ScriptMapsService.new({
    transition = { start = function() end },
    loader = fakeLoader(),
    sourceMap = fakeSourceMap(),
    travel = travel,
  })
  local expected = {
    { "MAP_GOLDENROD_RADIO_TOWER_5F", 0 },
    { "MAP_GOLDENROD_RADIO_TOWER_OBSERVATION_DECK", 1 },
    { "MAP_OLIVINE_LIGHTHOUSE_1F", 0 },
    { "MAP_OLIVINE_LIGHTHOUSE_LIGHT_ROOM", 1 },
    { "MAP_SAFFRON_SILPH_CO_HQ", 0 },
    { "MAP_SAFFRON_SILPH_CO_ROTOM_ROOM", 1 },
    { "MAP_GOLDENROD_DEPARTMENT_STORE_1F", 1 },
    { "MAP_GOLDENROD_DEPARTMENT_STORE_2F", 2 },
    { "MAP_GOLDENROD_DEPARTMENT_STORE_BASEMENT", 0 },
    { "MAP_GOLDENROD_DEPARTMENT_STORE_6F", 6 },
    { "MAP_CELADON_DEPARTMENT_STORE_1F", 0 },
    { "MAP_CELADON_DEPARTMENT_STORE_ROOF", 5 },
    { "MAP_CELADON_CONDOMINIUMS_3F", 2 },
    { "MAP_CELADON_CONDOMINIUMS_ROOF", 3 },
  }
  for _, row in ipairs(expected) do
    service:setDynamicWarp({ map = row[1], warpId = 0, fieldX = 1, fieldZ = 2, direction = "north" })
    Assert.equal(service:dynamicWarpFloor(), row[2], "the floor of " .. row[1] .. " follows the source table")
  end

  local err = Assert.throws(function()
    service:setDynamicWarp({ map = "MAP_NEW_BARK", warpId = 0, fieldX = 1, fieldZ = 2, direction = "north" })
    return service:dynamicWarpFloor()
  end)
  Assert.isTrue(Errors.is(err), "a map outside the source elevator table is an attributed failure")

  local unset = ScriptMapsService.new({
    transition = { start = function() end },
    loader = fakeLoader(),
    sourceMap = fakeSourceMap(),
    travel = FieldTravelState.new({ lastHealSpawn = "SPAWN_NEW_BARK" }),
  })
  Assert.throws(function()
    unset:dynamicWarpFloor()
  end, "an unestablished destination answers no floor instead of the current map's")
end

-- MoveWarp relocates the live warp event of the current map instance: the
-- runtime map's warp list is already expressed in the field domain the trigger
-- reads, so only the named event moves to the script's local cell converted
-- through the map origin; the player is untouched and the shared source map
-- data keeps its original coordinates.
function T.move_warp_event_relocates_only_the_live_current_map_event()
  local cachedWarps = {
    { index = 0, x = 610, z = 320, destinationMapId = 60, destinationWarpId = 0 },
    { index = 1, x = 630, z = 340, destinationMapId = 60, destinationWarpId = 1 },
  }
  local sourceMap = {
    mapId = "MAP_NEW_BARK",
    coordinateOrigin = { x = 600, z = 300 },
    fieldData = { events = { warps = cachedWarps } },
  }
  local transitionStarts = 0
  local service = ScriptMapsService.new({
    transition = {
      start = function()
        transitionStarts = transitionStarts + 1
      end,
    },
    loader = fakeLoader(),
    sourceMap = sourceMap,
  })

  service:moveWarpEvent(0, 5, 6)
  Assert.notNil(WarpSystem.findAt(sourceMap, 605, 306), "the moved warp answers at its new field cell")
  Assert.equal(WarpSystem.findAt(sourceMap, 605, 306).index, 0, "the moved event keeps its source warp index")
  Assert.isNil(WarpSystem.findAt(sourceMap, 610, 320), "the original cell no longer triggers the warp")
  Assert.deepEqual(
    WarpSystem.findAt(sourceMap, 630, 340),
    cachedWarps[2],
    "a sibling warp event keeps its field coordinates and every other record field"
  )
  Assert.equal(assert(WarpSystem.findAt(sourceMap, 630, 340)).index, 1, "sibling warp events stay at their own cell")
  Assert.equal(cachedWarps[1].x, 610, "the shared source map data keeps its original coordinate")
  Assert.equal(cachedWarps[1].z, 320, "the shared source map data keeps its original coordinate")
  Assert.equal(transitionStarts, 0, "moving a warp event never travels")
  Assert.isNil(service.pendingWarp, "moving a warp event starts no scripted warp")

  local err = Assert.throws(function()
    service:moveWarpEvent(9, 1, 2)
  end)
  Assert.isTrue(Errors.is(err), "an unknown warp index is an attributed failure")
  Assert.notNil(WarpSystem.findAt(sourceMap, 605, 306), "a failed move leaves the live event where it was")
end

-- The map origin never applies twice: a nonzero origin with field-domain
-- siblings must leave every other warp at its own field cell instead of
-- displacing the whole list by the origin.
function T.move_warp_event_leaves_field_domain_siblings_untouched_at_a_nonzero_origin()
  local siblings = {
    { index = 1, x = 648, z = 372, destinationMapId = 60, destinationWarpId = 1 },
    { index = 2, x = 656, z = 388, destinationMapId = 60, destinationWarpId = 2 },
  }
  local sourceMap = {
    mapId = "MAP_ECRUTEAK",
    coordinateOrigin = { x = 640, z = 360 },
    fieldData = {
      events = {
        warps = {
          { index = 0, x = 645, z = 366, destinationMapId = 60, destinationWarpId = 0 },
          siblings[1],
          siblings[2],
        },
      },
    },
  }
  local service = ScriptMapsService.new({
    transition = { start = function() end },
    loader = fakeLoader(),
    sourceMap = sourceMap,
  })

  service:moveWarpEvent(0, 2, 3)
  Assert.notNil(WarpSystem.findAt(sourceMap, 642, 363), "the moved warp lands at origin + source cell")
  Assert.deepEqual(WarpSystem.findAt(sourceMap, 648, 372), siblings[1], "the first sibling keeps its field coordinates")
  Assert.deepEqual(
    WarpSystem.findAt(sourceMap, 656, 388),
    siblings[2],
    "the second sibling keeps its field coordinates"
  )
end

return { tests = T }
