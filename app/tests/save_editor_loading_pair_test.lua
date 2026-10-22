-- Save Editor opening presents the same selected pair stage as game entry:
-- decorative art is requested by selected pair, the choice survives an
-- opening retry with a fresh stage, a cosmetic art failure never blocks the
-- editor's own readiness, and the stage is released exactly once.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local State = require("app.src.saveeditor.SaveEditorState")

local T = { tests = {} }

local PAIR_INDEX = 32
local VERSION_ID = "soulsilver"

local function fakeLoading()
  local art = {
    drawn = {},
    updateCount = 0,
    disposeCount = 0,
    adoptCalls = 0,
    adoptResult = true,
    adoptFailure = nil,
  }
  function art:update(dt)
    self.updateCount = self.updateCount + 1
  end
  function art:draw(status)
    self.drawn[#self.drawn + 1] = status
  end
  function art:adoptGeneratedAssets(_)
    self.adoptCalls = self.adoptCalls + 1
    if self.adoptResult then
      return true
    end
    return false, self.adoptFailure
  end
  function art:dispose()
    self.disposeCount = self.disposeCount + 1
  end
  return art
end

local function keyedHost(behavior)
  behavior = behavior or {}
  local calls = { walker = {}, milestones = {} }
  local host = {
    calls = calls,
    -- The typed pair demand is a plain dot call carrying the caller's
    -- 1..32 selection; anything else (including a colon-passed self)
    -- fails the pair identity assertions below.
    requestStartupWalker = function(pairIndex, urgency)
      calls.walker[#calls.walker + 1] = { pairIndex = pairIndex, urgency = urgency }
      if behavior.walkerFailure ~= nil then
        return nil, behavior.walkerFailure
      end
      if behavior.walkerReady then
        return true
      end
      return false
    end,
    requestMilestone = function(name, priority)
      calls.milestones[#calls.milestones + 1] = { name = name, priority = priority }
      if name == "startup-loader" then
        return false
      end
      if behavior.requiredFailure ~= nil then
        return false, behavior.requiredFailure
      end
      return true
    end,
  }
  return host, calls
end

local function openingState(overrides)
  overrides = overrides or {}
  local host, calls = keyedHost(overrides.behavior)
  local art = overrides.loading or fakeLoading()
  local state = setmetatable({
    status = "opening",
    message = "Preparing save data",
    versionId = VERSION_ID,
    width = 480,
    height = 360,
    startupPairIndex = PAIR_INDEX,
    loading = art,
    loaderArtObserved = false,
    derivedAssets = host,
    controller = {},
    _invalidatePublication = function() end,
    _settleScope = function() end,
  }, State)
  return state, art, calls
end

local function assertNoLegacyGlobalMilestone(calls)
  for _, call in ipairs(calls.milestones) do
    Assert.isTrue(
      call.name ~= "startup-loader",
      "the legacy global loader milestone is never demanded"
    )
  end
end

local function assertOnlySelectedPair(calls)
  Assert.isTrue(#calls.walker >= 1, "the decorative demand names the selected pair")
  for _, call in ipairs(calls.walker) do
    Assert.equal(call.pairIndex, PAIR_INDEX, "every decorative demand names the same selected pair")
    Assert.equal(call.urgency, "near", "the decorative demand stays nonblocking")
  end
end

function T.tests.opening_names_only_the_selected_pair_and_never_the_global_milestone()
  local state, art, calls = openingState({ behavior = { walkerReady = true } })
  State._pollLoadingArt(state)
  State._pollLoadingArt(state)
  assertOnlySelectedPair(calls)
  assertNoLegacyGlobalMilestone(calls)
  Assert.isTrue(state.loaderArtObserved, "the ready demand is observed exactly once")
  Assert.equal(art.adoptCalls, 1, "the ready demand is adopted exactly once")
  Assert.isNil(state.loaderArtFailure, "a clean adoption records no diagnostic")
end

function T.tests.pending_art_stays_retryable_then_adopts_once_without_rerequest()
  local state, art, calls = openingState({ behavior = { walkerReady = false } })
  State._pollLoadingArt(state)
  State._pollLoadingArt(state)
  Assert.equal(#calls.walker, 2, "a pending decorative demand is rerequested")
  Assert.equal(art.adoptCalls, 0, "pending art never adopts")
  Assert.isFalse(state.loaderArtObserved, "pending art never latches")
  Assert.isNil(state.loaderArtFailure, "pending art records no diagnostic")
end

function T.tests.failed_art_stays_cosmetic_while_required_milestones_stay_authoritative()
  local state, art, calls =
    openingState({ behavior = { walkerFailure = "injected walker failure" } })
  State._pollLoadingArt(state)
  assertOnlySelectedPair(calls)
  assertNoLegacyGlobalMilestone(calls)
  Assert.isTrue(state.loaderArtObserved, "the cosmetic failure latches")
  Assert.equal(
    state.loaderArtFailure,
    "injected walker failure",
    "the pair failure is recorded as a cosmetic diagnostic"
  )
  Assert.isTrue(
    State._readyReadiness(state),
    "the art failure leaves the editor's required milestones authoritative"
  )
  State._pollLoadingArt(state)
  Assert.equal(#calls.walker, 1, "a latched cosmetic failure is never rerequested")
  State.draw(state)
  Assert.equal(#art.drawn, 1, "the opening cover still draws behind the failed art")
  Assert.equal(state.status, "opening", "the editor stays in its opening state")
end

function T.tests.retry_open_reuses_the_same_selected_pair_with_a_fresh_stage()
  local Presentation = require("libs.hgss.src.ui.HgssLoadingPresentation")
  local originalNew = Presentation.new
  local captured = {}
  rawset(Presentation, "new", function(options)
    captured[#captured + 1] = options
    return fakeLoading()
  end)
  local state
  local ok, err = pcall(function()
    local host = keyedHost({ walkerReady = true })
    state = setmetatable({
      status = "error",
      errorMessage = "injected editor failure",
      versionId = VERSION_ID,
      width = 480,
      height = 360,
      startupPairIndex = PAIR_INDEX,
      loading = nil,
      loaderArtObserved = true,
      loaderArtFailure = "injected walker failure",
      generation = 1,
      derivedAssets = host,
    }, State)
    State._dispatchActivationAction(state, { kind = "editor.retry-open" }, {})
    Assert.equal(state.status, "opening", "retry returns the editor to its opening state")
    Assert.isNil(state.errorMessage, "retry clears the previous opening error")
    Assert.equal(state.generation, 2, "retry advances the opening generation")
    Assert.equal(state.startupPairIndex, PAIR_INDEX, "retry keeps the selected pair")
    Assert.isFalse(state.loaderArtObserved, "retry rearms the decorative latch")
    Assert.isNil(state.loaderArtFailure, "retry clears the cosmetic diagnostic")
    Assert.equal(#captured, 1, "retry builds exactly one fresh stage")
    Assert.equal(
      captured[1].pairIndex,
      PAIR_INDEX,
      "the retried stage names the same selected pair"
    )
    State._pollLoadingArt(state)
    Assert.equal(
      host.calls.walker[1].pairIndex,
      PAIR_INDEX,
      "the retried opening demands the same selected pair again"
    )
  end)
  rawset(Presentation, "new", originalNew)
  Assert.isTrue(ok, "the retry path composes: " .. tostring(err))
end

function T.tests.adopted_stage_is_released_exactly_once_on_opening_error()
  local state, art = openingState({ behavior = { walkerReady = true } })
  State._pollLoadingArt(state)
  Assert.isTrue(state.loaderArtObserved, "the ready demand is observed")
  State._openingFailed(state, Errors.new("SAVE_EDITOR_ASSET_PREPARATION_FAILED", "injected editor failure"))
  Assert.equal(state.status, "error", "a genuine editor failure keeps its cause")
  Assert.isNil(state.loading, "the error path drops the adopted cover")
  Assert.equal(art.disposeCount, 1, "the error path releases the adopted cover exactly once")
  State._openingFailed(state, Errors.new("SAVE_EDITOR_ASSET_PREPARATION_FAILED", "injected editor failure"))
  Assert.equal(art.disposeCount, 1, "a repeated error never rereleases the cover")
end

return T
