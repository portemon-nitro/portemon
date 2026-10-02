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
    errorText = nil,
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
  Assert.isNil(state.runtime.errorText, "pending preparation is not a field failure")
  FieldState.update(state, 0)
  Assert.isTrue(state._namingPresentationReady, "later readiness publishes the naming presentation")
  Assert.deepEqual(calls.readiness, { false, true }, "naming state receives each readiness result")
end

function T.permanent_preparation_failure_sets_terminal_error_without_retry()
  local state, calls = stateFor({ { false, "page failed" }, { true, nil } })
  FieldState.update(state, 0)
  Assert.isFalse(state._namingPresentationReady, "failed naming presentation stays hidden")
  Assert.equal(
    state.runtime.errorText,
    "Pokemon naming presentation failed: page failed",
    "provider failure uses the terminal field error surface"
  )
  FieldState.update(state, 0)
  Assert.equal(calls.preparations, 1, "terminal runtime state never retries naming preparation")
  Assert.deepEqual(calls.readiness, { false }, "the failed naming state remains not ready")
end

return { tests = T }
