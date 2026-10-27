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
    versionId = "soulsilver",
    startupPairIndex = 32,
    loading = presentation,
    loaderArtObserved = false,
    derivedAssets = {
      requestStartupWalker = function(urgency)
        artRequests = artRequests + 1
        Assert.equal(urgency, "near", "the decorative demand stays nonblocking")
        return false, "loader artwork unavailable"
      end,
      requestMilestone = function(_, priority)
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

-- A throwing decorative adoption must latch one cosmetic diagnostic while the
-- editor's own required milestones stay authoritative, and the latched
-- failure is never retried or rereleased.
function T.tests.throwing_loader_adoption_leaves_editor_opening_authoritative()
  local adoptCalls = 0
  local presentation = loading()
  function presentation:adoptGeneratedAssets(_)
    adoptCalls = adoptCalls + 1
    error("synthetic loader image failure", 0)
  end
  local artRequests = 0
  local requiredRequests = 0
  local state = setmetatable({
    status = "opening",
    versionId = "heartgold",
    startupPairIndex = 32,
    loading = presentation,
    loaderArtObserved = false,
    controller = {},
    _invalidatePublication = function() end,
    _settleScope = function() end,
    derivedAssets = {
      requestStartupWalker = function(urgency)
        artRequests = artRequests + 1
        Assert.equal(urgency, "near", "the decorative demand stays nonblocking")
        return true
      end,
      requestMilestone = function(_, priority)
        requiredRequests = requiredRequests + 1
        Assert.equal(priority, "required")
        return true
      end,
    },
  }, State)

  State._pollLoadingArt(state)
  Assert.equal(adoptCalls, 1, "the decorative adoption runs once before latching")
  Assert.isTrue(state.loaderArtObserved, "the cosmetic failure latches")
  Assert.isTrue(
    string.find(tostring(state.loaderArtFailure), "synthetic loader image failure", 1, true) ~= nil,
    "the cosmetic diagnostic is recorded"
  )
  Assert.isTrue(
    State._readyReadiness(state),
    "the adoption failure leaves the editor's required milestones authoritative"
  )
  State._pollLoadingArt(state)
  Assert.equal(adoptCalls, 1, "a latched cosmetic failure is never retried")
  Assert.equal(artRequests, 1, "a latched cosmetic failure never rerequests its milestone")

  State._openingFailed(state, Errors.new("SAVE_EDITOR_ASSET_PREPARATION_FAILED", "injected editor failure"))
  Assert.equal(state.status, "error")
  Assert.equal(state.errorMessage, "injected editor failure", "a genuine editor failure keeps its cause")
  Assert.equal(presentation.disposeCount, 1, "the error path releases the cover exactly once")
  State._openingFailed(state, Errors.new("SAVE_EDITOR_ASSET_PREPARATION_FAILED", "injected editor failure"))
  Assert.equal(presentation.disposeCount, 1, "a repeated error never rereleases the cover")
end

-- A pending decorative demand stays retryable, then a ready demand adopts
-- exactly once with no diagnostic and is never rerequested.
function T.tests.pending_loader_art_stays_retryable_then_adopts_successfully_once()
  local adoptCalls = 0
  local presentation = loading()
  function presentation:adoptGeneratedAssets(_)
    adoptCalls = adoptCalls + 1
    return true
  end
  local artRequests = 0
  local artReady = false
  local state = setmetatable({
    status = "opening",
    versionId = "soulsilver",
    startupPairIndex = 32,
    loading = presentation,
    loaderArtObserved = false,
    controller = {},
    _invalidatePublication = function() end,
    _settleScope = function() end,
    derivedAssets = {
      requestStartupWalker = function(urgency)
        artRequests = artRequests + 1
        Assert.equal(urgency, "near", "the decorative demand stays nonblocking")
        return artReady
      end,
      requestMilestone = function(_, priority)
        Assert.equal(priority, "required")
        return true
      end,
    },
  }, State)

  State._pollLoadingArt(state)
  State._pollLoadingArt(state)
  Assert.equal(artRequests, 2, "a pending decorative demand is rerequested")
  Assert.equal(adoptCalls, 0, "pending art never adopts")
  Assert.isFalse(state.loaderArtObserved, "pending art never latches")
  Assert.isNil(state.loaderArtFailure, "pending art records no diagnostic")
  artReady = true
  State._pollLoadingArt(state)
  Assert.isTrue(state.loaderArtObserved, "the ready demand is observed exactly once")
  Assert.equal(adoptCalls, 1, "the ready demand is adopted exactly once")
  Assert.isNil(state.loaderArtFailure, "a clean adoption records no diagnostic")
  State._pollLoadingArt(state)
  Assert.equal(artRequests, 3, "an observed demand is never rerequested")
  Assert.equal(adoptCalls, 1, "an observed demand is never readopted")
end

-- A successfully adopted cover is still released exactly once when the
-- required opening fails, and the genuine editor failure keeps its cause.
function T.tests.adopted_loader_art_is_released_once_on_opening_error()
  local presentation = loading()
  function presentation:adoptGeneratedAssets(_)
    return true
  end
  local state = setmetatable({
    status = "opening",
    versionId = "heartgold",
    startupPairIndex = 32,
    loading = presentation,
    loaderArtObserved = false,
    controller = {},
    _invalidatePublication = function() end,
    _settleScope = function() end,
    derivedAssets = {
      requestStartupWalker = function(urgency)
        Assert.equal(urgency, "near", "the decorative demand stays nonblocking")
        return true
      end,
      requestMilestone = function(_, priority)
        Assert.equal(priority, "required")
        return true
      end,
    },
  }, State)

  State._pollLoadingArt(state)
  Assert.isTrue(state.loaderArtObserved, "the ready demand is observed")
  Assert.isNil(state.loaderArtFailure, "a clean adoption records no diagnostic")
  State._openingFailed(state, Errors.new("SAVE_EDITOR_ASSET_PREPARATION_FAILED", "injected editor failure"))
  Assert.equal(state.status, "error")
  Assert.equal(state.errorMessage, "injected editor failure", "a genuine editor failure keeps its cause")
  Assert.isNil(state.loading, "the error path drops the adopted cover")
  Assert.equal(presentation.disposeCount, 1, "the error path releases the adopted cover exactly once")
  State._openingFailed(state, Errors.new("SAVE_EDITOR_ASSET_PREPARATION_FAILED", "injected editor failure"))
  Assert.equal(presentation.disposeCount, 1, "a repeated error never rereleases the cover")
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
