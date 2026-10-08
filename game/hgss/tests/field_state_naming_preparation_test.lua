-- Naming preparation coordinates pending icon pages and terminal page failures.

local Assert = require("tests.support.Assert")
local FieldState = require("game.hgss.src.field.FieldState")

local T = {}

local function stateFor(preparationResults)
  local calls = { preparations = 0, readiness = {} }
  local naming = {
    isActive = function()
      return true
    end,
    status = function()
      return { snapshot = { subject = { iconKey = "species:1:form:0" } } }
    end,
    setPresentationReady = function(_, ready)
      calls.readiness[#calls.readiness + 1] = ready
    end,
  }
  local runtime = {
    pokemonNaming = naming,
    update = function(_) end,
  }
  local resources = {
    preparePokemonNamingSubject = function(_, _)
      calls.preparations = calls.preparations + 1
      local result = table.remove(preparationResults, 1)
      return result[1], result[2]
    end,
  }
  local state = setmetatable({
    runtime = runtime,
    presentationResources = resources,
    actorPresentation = { sync = function(_) end },
  }, FieldState)
  state._advanceStarterPreparation = function(_) end
  state._syncStarterPresentationInput = function(_) end
  state._advanceEntryCover = function(_, _) end
  state._sampleOverlayFps = function(_, _) end
  return state, calls
end

function T.pending_preparation_can_become_ready()
  local state, calls = stateFor({ { false, nil }, { true, nil } })
  FieldState.update(state, 0)
  Assert.isFalse(state._namingPresentationReady, "pending naming presentation stays hidden")
  FieldState.update(state, 0)
  Assert.isTrue(state._namingPresentationReady, "later readiness publishes the naming presentation")
  Assert.deepEqual(calls.readiness, { false, true }, "naming state receives each readiness result")
end

function T.permanent_preparation_failure_propagates_to_the_host()
  local state, calls = stateFor({ { false, "page failed" }, { true, nil } })
  local ok, failure = pcall(function()
    FieldState.update(state, 0)
  end)
  Assert.isFalse(state._namingPresentationReady, "failed naming presentation stays hidden")
  Assert.isFalse(ok, "a permanent naming preparation failure reaches LÖVE's callback error handler")
  Assert.equal(tostring(failure), "Pokemon naming presentation failed: page failed")
  Assert.equal(calls.preparations, 1, "the callback stops at the failed preparation")
  Assert.deepEqual(calls.readiness, { false }, "the failed naming state remains not ready")
end

return { tests = T }
