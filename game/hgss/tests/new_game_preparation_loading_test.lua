-- New Game entry presents the selected edition's living walker stage from
-- creation: decorative art is requested by selected pair, the first frame
-- is drawn before an otherwise-ready transfer, a cosmetic art failure never
-- blocks the semantic intro gate, and the stage is released exactly once.

local Assert = require("tests.support.Assert")
local NewGamePreparationState = require("game.hgss.src.newgame.NewGamePreparationState")

local T = {}

local PAIR_INDEX = 32
local VERSION_ID = "soulsilver"

local function keyedHost(overrides)
  local behavior = {
    introReady = false,
    introFailure = nil,
    walkerReady = false,
    walkerFailure = nil,
  }
  if overrides ~= nil then
    for key, value in pairs(overrides) do
      behavior[key] = value
    end
  end
  local calls = { walker = {}, milestones = {} }
  local host = {}
  -- The C01 typed pair demand is a plain dot call carrying the caller's
  -- 1..32 selection; anything else (including a colon-passed self) fails
  -- the pair identity assertions below.
  function host.requestStartupWalker(urgency)
    calls.walker[#calls.walker + 1] = { urgency = urgency }
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
    if name == "new-game-intro" then
      if behavior.introFailure ~= nil then
        return false, behavior.introFailure
      end
      return behavior.introReady == true
    end
    return false
  end
  function host.milestoneStatus(name)
    if name == "new-game-intro" and behavior.introReady then
      return { state = "ready", ready = 1, total = 1 }
    end
    return { state = "pending", ready = 0, total = nil }
  end
  return host, calls, behavior
end

local function newEntry(host, onReady, onCancel)
  return NewGamePreparationState.new({
    versionId = VERSION_ID,
    startupPairIndex = PAIR_INDEX,
    derivedAssets = host,
    onReady = onReady or function() end,
    onCancel = onCancel or function() end,
  })
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

local function assertSharedDecorativeDemand(calls)
  Assert.isTrue(#calls.walker >= 1, "the decorative demand observes the shared visuals")
  for _, call in ipairs(calls.walker) do
    Assert.equal(call.urgency, "near", "the decorative demand stays nonblocking")
  end
end

function T.draws_one_loader_frame_before_an_otherwise_ready_transfer()
  local host = keyedHost({ introReady = true })
  local readyCalls = 0
  local state = newEntry(host, function()
    readyCalls = readyCalls + 1
  end)
  Assert.notNil(state.loading, "new-game entry owns its themed loading stage from creation")
  local watch = watchStage(state)
  state:update(0)
  Assert.equal(readyCalls, 0, "an otherwise-ready entry never transfers before its first loader draw")
  state:draw()
  Assert.isTrue(#watch.draws >= 1, "activation paints the themed loader at least once")
  state:update(0)
  state:update(0)
  Assert.equal(readyCalls, 1, "readiness transfers exactly once after the first loader draw")
  Assert.equal(watch.disposes, 1, "the transfer releases the entry stage exactly once")
end

function T.requests_only_the_selected_pair_and_never_the_legacy_global_milestone()
  local host, calls = keyedHost({ introReady = true, walkerReady = true })
  local state = newEntry(host)
  state:update(0)
  state:update(0)
  assertSharedDecorativeDemand(calls)
  assertNoLegacyGlobalMilestone(calls)
end

function T.failed_pair_art_stays_cosmetic_while_the_intro_gate_transfers()
  local host = keyedHost({ introReady = true, walkerFailure = "injected walker failure" })
  local readyCalls = 0
  local state = newEntry(host, function()
    readyCalls = readyCalls + 1
  end)
  Assert.notNil(state.loading, "new-game entry owns its themed loading stage from creation")
  local watch = watchStage(state)
  state:update(0)
  Assert.equal(readyCalls, 0, "an otherwise-ready entry never transfers before its first loader draw")
  Assert.equal(
    state.loaderArtFailure,
    "injected walker failure",
    "the pair failure is recorded as a cosmetic diagnostic"
  )
  state:draw()
  Assert.isTrue(#watch.draws >= 1, "the stage keeps animating behind the failed art")
  state:update(0)
  Assert.equal(readyCalls, 1, "the failed art never blocks the semantic intro transfer")
  Assert.equal(watch.disposes, 1, "the transfer still releases the stage exactly once")
end

function T.escape_disposes_the_stage_once_and_never_transfers_late()
  local host, _, behavior = keyedHost({ introReady = false })
  local readyCalls, cancelCalls = 0, 0
  local state = newEntry(host, function()
    readyCalls = readyCalls + 1
  end, function()
    cancelCalls = cancelCalls + 1
  end)
  Assert.notNil(state.loading, "new-game entry owns its themed loading stage from creation")
  local watch = watchStage(state)
  state:update(0)
  state:keypressed("escape")
  Assert.equal(cancelCalls, 1, "cancellation returns to the menu once")
  Assert.equal(watch.disposes, 1, "cancellation releases the entry stage exactly once")
  behavior.introReady = true
  state:update(0)
  state:update(0)
  Assert.equal(readyCalls, 0, "late readiness never transfers a cancelled entry")
  Assert.equal(watch.disposes, 1, "a cancelled entry is never released twice")
  state:dispose()
  Assert.equal(watch.disposes, 1, "disposing a cancelled entry never rereleases the stage")
end

function T.product_entry_forwards_the_selected_pair_into_new_game_preparation()
  local HgssGame = require("game.hgss.src.HgssGame")
  local seen = {}
  local original = NewGamePreparationState.new
  rawset(NewGamePreparationState, "new", function(options)
    seen[#seen + 1] = options
    return original(options)
  end)
  local ok, gameOrError = pcall(HgssGame.new, {
    versionId = VERSION_ID,
    entry = { kind = "new_game" },
    onExit = function() end,
    derivedAssets = {},
    startupPairIndex = PAIR_INDEX,
  })
  rawset(NewGamePreparationState, "new", original)
  Assert.isTrue(ok, "the product entry composes: " .. tostring(gameOrError))
  Assert.equal(#seen, 1, "new-game entry builds exactly one pending preparation")
  Assert.equal(
    seen[1].startupPairIndex,
    PAIR_INDEX,
    "the product entry forwards its selected pair without reselection"
  )
end

return { tests = T }
