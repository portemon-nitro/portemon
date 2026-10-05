-- Covered swaps translate destination-local coordinates and observe the
-- transition lifecycle while their caller owns the opaque screen cover.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.script.src.errors")
local FieldCoveredSwap = require("libs.hgss.src.transition.FieldCoveredSwap")
local FieldTransition = require("libs.hgss.src.transition.FieldTransition")

local T = {}

function T.covered_swap_rebases_coordinates_and_tracks_transition_ownership()
  local sourceMap = { mapId = 12 }
  local replacementSourceMap = { mapId = 13 }
  local loaderCalls = {}
  local transitionCalls = {}
  local transition = {
    phase = FieldTransition.PHASES.idle,
    sourceMap = nil,
    startCoveredSwap = function(self, source, trigger, facing)
      transitionCalls[#transitionCalls + 1] = {
        source = source,
        trigger = trigger,
        facing = facing,
      }
      self.phase = FieldTransition.PHASES.load_destination
      self.sourceMap = source
    end,
  }
  local loader = {
    load = function(_, map)
      loaderCalls[#loaderCalls + 1] = map
      return { mapId = 42, coordinateOrigin = { x = 680, z = 392 } }
    end,
  }
  local swap = FieldCoveredSwap.new({ loader = loader, transition = transition, sourceMap = sourceMap })

  swap:start({ map = "MAP_TEST", warp = 3, fieldX = 4, fieldZ = 5, facing = "north" })

  Assert.deepEqual(loaderCalls, { "MAP_TEST" }, "the swap resolves its destination through the supplied loader")
  Assert.equal(#transitionCalls, 1, "the swap starts exactly one owned transition")
  Assert.equal(transitionCalls[1].source, sourceMap, "the current source map reaches the transition by identity")
  Assert.deepEqual(transitionCalls[1].trigger, {
    warp = {
      index = 3,
      x = 684,
      z = 397,
      destinationMapId = 42,
      destinationWarpId = 3,
      direct = true,
    },
  })
  Assert.equal(transitionCalls[1].facing, "north")
  Assert.isFalse(swap:done(), "a transition that still owns its source is pending")
  Assert.isNil(swap:error())

  swap:setSourceMap(replacementSourceMap)
  transition.phase = FieldTransition.PHASES.idle
  transition.sourceMap = nil
  Assert.isTrue(swap:done(), "the swap completes after transition ownership returns to idle")
  Assert.isFalse(swap:done(), "completion is consumed once")
end

function T.covered_swap_captures_transition_failure_and_can_be_reused()
  local failure = { code = "transition failed" }
  local transition = {
    phase = FieldTransition.PHASES.load_destination,
    sourceMap = { mapId = 12 },
    startCoveredSwap = function() end,
  }
  local swap = FieldCoveredSwap.new({
    loader = {
      load = function()
        return { mapId = 42, coordinateOrigin = { x = 0, z = 0 } }
      end,
    },
    transition = transition,
    sourceMap = { mapId = 12 },
  })
  swap:start({ map = "MAP_TEST", fieldX = 1, fieldZ = 2, facing = "east" })

  transition.error = failure
  Assert.isTrue(swap:done(), "a failed transition settles the pending swap")
  Assert.equal(swap:error(), failure, "the transition failure remains attributable to the swap")
  Assert.isFalse(swap:done(), "failure completion is consumed once")

  transition.error = nil
  transition.phase = FieldTransition.PHASES.idle
  transition.sourceMap = nil
  swap:start({ map = "MAP_TEST", fieldX = 2, fieldZ = 3, facing = "east" })
  Assert.isNil(swap:error(), "starting a new swap clears the prior failure")
end

function T.covered_swap_rejects_an_unavailable_destination_as_a_script_error()
  local swap = FieldCoveredSwap.new({
    loader = {
      load = function()
        return nil
      end,
    },
    transition = {
      startCoveredSwap = function()
        error("transition must not start")
      end,
    },
    sourceMap = { mapId = 12 },
  })

  local err = Assert.throws(function()
    swap:start({ map = "MAP_MISSING", fieldX = 1, fieldZ = 2, facing = "south" })
  end)

  Assert.isTrue(Errors.is(err), "an unavailable generated destination is a structured error")
  Assert.equal(err.code, ScriptErrors.SCRIPT_INVALID_REFERENCE)
  Assert.isFalse(swap:done(), "a failed destination lookup never starts a pending transition")
end

return { tests = T }
