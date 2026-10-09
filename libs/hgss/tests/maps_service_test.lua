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

local T = {}

local function fakeLoader()
  return {
    load = function(_, ref)
      return { mapId = ref, coordinateOrigin = { x = 600, z = 300 } }
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
      destinationMapId = "MAP_NEW_BARK_ELMS_LAB_2F",
      destinationWarpId = 0,
      direct = true,
    },
  }, "script coordinates remain destination-local until the covered swap rebases them")
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

return { tests = T }
