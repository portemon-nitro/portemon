-- Continue entry presents the selected edition's living walker stage from
-- creation: decorative art is requested by selected pair, the first frame
-- is drawn before an otherwise-ready transfer, a cosmetic art failure never
-- blocks the semantic field gates, and the stage is released exactly once.
-- The New Game field handoff owns the same selected stage.

local Assert = require("tests.support.Assert")
local FieldPreparationState = require("game.hgss.src.field.FieldPreparationState")

local T = {}

local PAIR_INDEX = 32
local VERSION_ID = "soulsilver"

local function keyedHost(behavior)
  behavior = behavior or {}
  local calls = { walker = {}, milestones = {} }
  local host = {}
  -- The typed pair demand is a plain dot call carrying the caller's 1..32
  -- selection; anything else (including a colon-passed self) fails the
  -- pair identity assertions below.
  function host.requestStartupWalker(pairIndex, urgency)
    calls.walker[#calls.walker + 1] = { pairIndex = pairIndex, urgency = urgency }
    if behavior.walkerFailure ~= nil then
      return nil, behavior.walkerFailure
    end
    if behavior.walkerReady then
      return true
    end
    return false
  end
  function host.requestMilestone(name, urgency)
    calls.milestones[#calls.milestones + 1] = { name = name, urgency = urgency }
    if name == "field-planning" then
      if behavior.planningFailure ~= nil then
        return false, behavior.planningFailure
      end
      return behavior.planning == true
    end
    if name == "field-runtime" then
      if behavior.runtimeFailure ~= nil then
        return false, behavior.runtimeFailure
      end
      return behavior.runtime == true
    end
    return false
  end
  return host, calls
end

local function geometryLoader(behavior)
  local loader = { requests = 0 }
  function loader:globalPosition(_, fieldX, fieldZ)
    return { x = fieldX, z = fieldZ }
  end
  function loader:requestLocation(_, _, _, _)
    self.requests = self.requests + 1
    if behavior.locationFailure ~= nil then
      return false, behavior.locationFailure
    end
    if behavior.locationReady == false then
      return false
    end
    return true
  end
  return loader
end

local function continueEntry(host, geometryBehavior, callbacks)
  callbacks = callbacks or {}
  local counts = { transfers = 0, cancels = 0 }
  local state = FieldPreparationState.new({
    kind = "continue",
    saveId = "save-00000002",
    versionId = VERSION_ID,
    startupPairIndex = PAIR_INDEX,
    derivedAssets = host,
    saveStore = {
      load = function(_, _)
        return { mapId = 60, fieldX = 684, fieldZ = 393 }
      end,
    },
    createLoader = function()
      return geometryLoader(geometryBehavior or {})
    end,
    enterField = function()
      counts.transfers = counts.transfers + 1
      if callbacks.onTransfer ~= nil then
        callbacks.onTransfer()
      end
    end,
    onCancel = function()
      counts.cancels = counts.cancels + 1
    end,
  })
  return state, counts
end

-- Records genuine draws and releases on the owned stage without changing
-- what it paints: the wrapper calls through to the real presentation.
local function watchStage(state)
  local watch = { draws = {}, disposes = 0 }
  local loading = state.loading
  if loading == nil then
    return watch
  end
  local originalDraw = loading.draw
  function loading.draw(self, status)
    watch.draws[#watch.draws + 1] = status
    return originalDraw(self, status)
  end
  local originalDispose = loading.dispose
  function loading.dispose(self)
    watch.disposes = watch.disposes + 1
    return originalDispose(self)
  end
  return watch
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

function T.draws_one_loader_frame_before_an_otherwise_ready_continue_transfer()
  local behavior = { planning = true, runtime = true }
  local host, calls = keyedHost(behavior)
  local state, counts = continueEntry(host, {})
  Assert.notNil(state.loading, "continue entry owns its themed loading stage from creation")
  Assert.equal(
    state.loading.pairIndex,
    PAIR_INDEX,
    "the continue stage names the selected pair"
  )
  local watch = watchStage(state)
  state:update(1 / 60)
  Assert.equal(counts.transfers, 0, "an otherwise-ready entry never transfers before its first loader draw")
  state:draw()
  Assert.isTrue(#watch.draws >= 1, "activation paints the themed loader at least once")
  state:update(1 / 60)
  state:update(1 / 60)
  Assert.equal(counts.transfers, 1, "readiness transfers exactly once after the first loader draw")
  Assert.equal(watch.disposes, 1, "the transfer releases the entry stage exactly once")
  assertOnlySelectedPair(calls)
  assertNoLegacyGlobalMilestone(calls)
end

function T.failed_pair_art_stays_cosmetic_while_continue_transfers()
  local behavior = { planning = true, runtime = true, walkerFailure = "injected walker failure" }
  local host = keyedHost(behavior)
  local state, counts = continueEntry(host, {})
  Assert.notNil(state.loading, "continue entry owns its themed loading stage from creation")
  local watch = watchStage(state)
  state:update(1 / 60)
  Assert.equal(counts.transfers, 0, "an otherwise-ready entry never transfers before its first loader draw")
  Assert.equal(
    state.loaderArtFailure,
    "injected walker failure",
    "the pair failure is recorded as a cosmetic diagnostic"
  )
  state:draw()
  Assert.isTrue(#watch.draws >= 1, "the stage keeps animating behind the failed art")
  state:update(1 / 60)
  Assert.equal(counts.transfers, 1, "the failed art never blocks the semantic field transfer")
  Assert.equal(watch.disposes, 1, "the transfer still releases the stage exactly once")
end

function T.pending_pair_art_never_blocks_continue_readiness()
  local behavior = { planning = true, runtime = true, walkerReady = false }
  local host, calls = keyedHost(behavior)
  local state, counts = continueEntry(host, {})
  Assert.notNil(state.loading, "continue entry owns its themed loading stage from creation")
  local watch = watchStage(state)
  state:update(1 / 60)
  state:update(1 / 60)
  Assert.isTrue(#calls.walker >= 1, "the pending decorative demand is rerequested")
  Assert.isFalse(state.loaderArtObserved, "pending art never latches the cosmetic flag")
  state:draw()
  state:update(1 / 60)
  Assert.equal(counts.transfers, 1, "pending art never holds the transfer past its first loader draw")
  Assert.equal(watch.disposes, 1, "the transfer releases the entry stage exactly once")
end

function T.newgame_field_handoff_owns_the_same_selected_stage()
  local host = keyedHost({ planning = true, runtime = true })
  local state = FieldPreparationState.new({
    kind = "newgame",
    candidate = {
      location = { mapSymbol = "MAP_NEW_BARK_PLAYER_HOUSE_2F", fieldX = 6, fieldZ = 6 },
    },
    versionId = VERSION_ID,
    startupPairIndex = PAIR_INDEX,
    derivedAssets = host,
    createLoader = function()
      return geometryLoader({})
    end,
    enterField = function() end,
    onCancel = function() end,
  })
  Assert.notNil(state.loading, "the new-game field handoff owns its themed loading stage from creation")
  Assert.equal(
    state.loading.pairIndex,
    PAIR_INDEX,
    "the handoff stage names the same selected pair"
  )
  state:dispose()
end

function T.escape_disposes_the_stage_once_and_never_transfers_late()
  local behavior = { planning = false, runtime = false }
  local host = keyedHost(behavior)
  local state, counts = continueEntry(host, { locationReady = false })
  Assert.notNil(state.loading, "continue entry owns its themed loading stage from creation")
  local watch = watchStage(state)
  state:update(1 / 60)
  state:keypressed("escape")
  Assert.equal(counts.cancels, 1, "cancellation returns to the menu once")
  Assert.equal(watch.disposes, 1, "cancellation releases the entry stage exactly once")
  behavior.planning = true
  behavior.runtime = true
  state:update(1 / 60)
  state:update(1 / 60)
  Assert.equal(counts.transfers, 0, "late readiness never transfers a cancelled entry")
  Assert.equal(watch.disposes, 1, "a cancelled entry is never released twice")
  state:dispose()
  Assert.equal(watch.disposes, 1, "disposing a cancelled entry never rereleases the stage")
end

function T.product_entry_forwards_the_selected_pair_into_continue_preparation()
  local HgssGame = require("game.hgss.src.HgssGame")
  local GameSaveStore = require("libs.hgss.src.save.GameSaveStore")
  local seen = {}
  local originalPreparationNew = FieldPreparationState.new
  rawset(FieldPreparationState, "new", function(options)
    seen[#seen + 1] = options
    return originalPreparationNew(options)
  end)
  local originalStoreNew = GameSaveStore.new
  rawset(GameSaveStore, "new", function()
    return {
      load = function(_, _)
        return { mapId = 60, fieldX = 684, fieldZ = 393 }
      end,
    }
  end)
  local ok, gameOrError = pcall(HgssGame.new, {
    versionId = VERSION_ID,
    entry = { kind = "continue", saveId = "save-00000002" },
    onExit = function() end,
    derivedAssets = {},
    startupPairIndex = PAIR_INDEX,
  })
  rawset(FieldPreparationState, "new", originalPreparationNew)
  rawset(GameSaveStore, "new", originalStoreNew)
  Assert.isTrue(ok, "the product entry composes: " .. tostring(gameOrError))
  Assert.equal(#seen, 1, "continue entry builds exactly one pending preparation")
  Assert.equal(
    seen[1].startupPairIndex,
    PAIR_INDEX,
    "the product entry forwards its selected pair without reselection"
  )
end

return { tests = T }
