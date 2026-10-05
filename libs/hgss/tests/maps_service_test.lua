-- ScriptMapsService: the script-facing map/warp abstraction. Source `Warp`
-- after a completed source screen fade must perform a covered map swap
-- (reusing transition preparation/commit without a second ordinary fade
-- pair), and the source special-spawn setter (opcode 582) must leave
-- observable semantic state instead of vanishing as a noop.

local Assert = require("tests.support.Assert")
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

-- Opcode 582's special-spawn setter must leave named, observable semantic
-- state on the maps service rather than disappearing as a noop.
function T.special_spawn_setter_records_source_location_and_is_observable()
  local service = ScriptMapsService.new({
    transition = { start = function() end },
    loader = fakeLoader(),
    sourceMap = fakeSourceMap(),
  })
  Assert.isNil(service:specialSpawn(), "no special spawn is recorded before the source setter runs")
  service:setSpecialSpawn({ map = "MAP_NEW_BARK", fieldX = 688, fieldZ = 393, warpId = -1, direction = "south" })
  Assert.deepEqual(service:specialSpawn(), {
    map = "MAP_NEW_BARK",
    fieldX = 688,
    fieldZ = 393,
    warpId = -1,
    direction = "south",
  })
end

return { tests = T }
