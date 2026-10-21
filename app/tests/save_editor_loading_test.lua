-- Save Editor loader artwork remains optional to the editor's own readiness.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local State = require("app.src.saveeditor.SaveEditorState")

local T = { tests = {} }

local function loading()
  local value = { drawn = {}, updateCount = 0, disposeCount = 0 }
  function value:update()
    self.updateCount = self.updateCount + 1
  end
  function value:draw(status)
    self.drawn[#self.drawn + 1] = status
  end
  function value:dispose()
    self.disposeCount = self.disposeCount + 1
  end
  return value
end

function T.tests.pending_or_failed_loader_art_does_not_change_editor_readiness_or_error()
  local artRequests = 0
  local requiredRequests = 0
  local presentation = loading()
  local state = setmetatable({
    status = "opening",
    message = "Preparing save data",
    loading = presentation,
    loaderArtObserved = false,
    derivedAssets = {
      requestMilestone = function(name, priority)
        if name == "startup-loader" then
          artRequests = artRequests + 1
          Assert.equal(priority, "near")
          return false, "loader artwork unavailable"
        end
        requiredRequests = requiredRequests + 1
        Assert.equal(priority, "required")
        return true
      end,
    },
  }, State)

  State._pollLoadingArt(state)
  Assert.equal(state.loaderArtFailure, "loader artwork unavailable")
  Assert.isTrue(
    State._readyReadiness(state),
    "optional art failure leaves the editor's required milestones authoritative"
  )
  Assert.equal(artRequests, 1)
  Assert.equal(requiredRequests, 2)
  State.draw(state)
  Assert.equal(presentation.drawn[1].message, "Preparing save data")
  Assert.equal(state.status, "opening")
end

function T.tests.editor_error_and_dispose_each_release_the_loading_owner_once()
  local presentation = loading()
  local state = setmetatable({
    status = "opening",
    loading = presentation,
    controller = {},
    _invalidatePublication = function() end,
    _settleScope = function() end,
  }, State)
  State._openingFailed(state, Errors.new("SAVE_EDITOR_ASSET_PREPARATION_FAILED", "required editor asset failed"))
  Assert.equal(state.status, "error")
  Assert.equal(presentation.disposeCount, 1)

  local closingPresentation = loading()
  local closing = setmetatable({
    generation = 0,
    loading = closingPresentation,
    _finishPreset = function() end,
    presentation = { dispose = function() end },
    renderer = { dispose = function() end },
    modalStack = { dispose = function() end },
  }, State)
  State.dispose(closing)
  State.dispose(closing)
  Assert.equal(closingPresentation.disposeCount, 1)
end

return T
