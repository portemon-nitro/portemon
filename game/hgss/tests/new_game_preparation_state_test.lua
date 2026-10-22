-- The pending New Game transition requests its semantic milestone as
-- required, transfers exactly once on readiness, and cancels safely back
-- to the menu without composing Oak or reserving a candidate.

local Assert = require("tests.support.Assert")
local NewGamePreparationState = require("game.hgss.src.newgame.NewGamePreparationState")

local T = {}

local PAIR_INDEX = 32
local VERSION_ID = "soulsilver"

local function pendingHost()
  local calls = {}
  return {
    calls = calls,
    requestStartupWalker = function(pairIndex, urgency)
      calls[#calls + 1] = { pairIndex = pairIndex, urgency = urgency }
      return false
    end,
    requestMilestone = function(name, urgency)
      calls[#calls + 1] = { name = name, urgency = urgency }
      return false
    end,
    milestoneStatus = function()
      return { state = "pending", ready = 0, total = nil }
    end,
  }
end

local function entryOptions(host, overrides)
  local options = {
    versionId = VERSION_ID,
    startupPairIndex = PAIR_INDEX,
    derivedAssets = host,
    onReady = function() end,
    onCancel = function() end,
  }
  if overrides ~= nil then
    for key, value in pairs(overrides) do
      options[key] = value
    end
  end
  return options
end

function T.pending_preparation_requests_the_intro_milestone_without_transferring()
  local host = pendingHost()
  local readyCalls = 0
  local state = NewGamePreparationState.new(entryOptions(host, {
    onReady = function()
      readyCalls = readyCalls + 1
    end,
  }))
  state:update(0)
  state:update(0)
  local milestones = {}
  for _, call in ipairs(host.calls) do
    if call.name ~= nil then
      milestones[#milestones + 1] = call
    end
  end
  Assert.equal(#milestones, 2, "every update polls the semantic milestone")
  for _, call in ipairs(milestones) do
    Assert.equal(call.name, "new-game-intro")
    Assert.equal(call.urgency, "required")
  end
  Assert.equal(readyCalls, 0, "no candidate or Oak transfer happens while pending")
  local pairDemands = 0
  for _, call in ipairs(host.calls) do
    if call.pairIndex ~= nil then
      pairDemands = pairDemands + 1
      Assert.equal(call.pairIndex, PAIR_INDEX, "the decorative demand names the selected pair")
      Assert.equal(call.urgency, "near", "the decorative demand stays nonblocking")
    end
  end
  Assert.isTrue(pairDemands >= 1, "pending entry keeps polling its selected pair decoratively")
end

function T.ready_preparation_transfers_exactly_once()
  local host = pendingHost()
  local ready = false
  host.requestMilestone = function(name, urgency)
    Assert.equal(name, "new-game-intro")
    Assert.equal(urgency, "required")
    return ready
  end
  local readyCalls = 0
  local state = NewGamePreparationState.new(entryOptions(host, {
    onReady = function()
      readyCalls = readyCalls + 1
    end,
  }))
  state:update(0)
  Assert.equal(readyCalls, 0, "no transfer happens while pending")
  ready = true
  state:update(0)
  Assert.equal(readyCalls, 0, "an otherwise-ready entry never transfers before its first loader draw")
  state:draw()
  state:update(0)
  state:update(0)
  state:update(0)
  Assert.equal(readyCalls, 1, "readiness transfers exactly once after the first loader draw")
end

function T.failed_preparation_raises_without_transferring()
  local host = {
    requestStartupWalker = function()
      return false
    end,
    requestMilestone = function()
      return false, "intro milestone failed"
    end,
    milestoneStatus = function()
      return { state = "pending", ready = 0, total = nil }
    end,
  }
  local readyCalls = 0
  local state = NewGamePreparationState.new(entryOptions(host, {
    onReady = function()
      readyCalls = readyCalls + 1
    end,
  }))
  local ok, err = pcall(function()
    state:update(0)
  end)
  Assert.isFalse(ok, "a failed milestone raises instead of latching a failed phase")
  Assert.isTrue(
    string.find(tostring(err), "intro milestone failed", 1, true) ~= nil,
    "the milestone failure is preserved"
  )
  Assert.equal(readyCalls, 0, "a failed milestone never transfers")
end

function T.escape_cancels_back_to_menu_without_a_later_transfer()
  local host = pendingHost()
  local readyCalls, cancelCalls = 0, 0
  local state = NewGamePreparationState.new(entryOptions(host, {
    onReady = function()
      readyCalls = readyCalls + 1
    end,
    onCancel = function()
      cancelCalls = cancelCalls + 1
    end,
  }))
  state:update(0)
  state:keypressed("escape")
  Assert.equal(cancelCalls, 1, "cancellation returns to the menu once")
  Assert.isNil(state.loading, "cancellation releases the entry stage")
  host.requestMilestone = function()
    return true
  end
  state:update(0)
  Assert.equal(readyCalls, 0, "a cancelled state never fires its ready callback later")
  Assert.equal(cancelCalls, 1, "a second escape never cancels twice")
  state:keypressed("escape")
  Assert.equal(cancelCalls, 1, "a second escape never cancels twice")
end

function T.disposed_preparation_never_transfers()
  local host = pendingHost()
  local readyCalls = 0
  local state = NewGamePreparationState.new(entryOptions(host, {
    onReady = function()
      readyCalls = readyCalls + 1
    end,
  }))
  state:dispose()
  host.requestMilestone = function()
    return true
  end
  state:update(0)
  Assert.equal(readyCalls, 0, "a disposed state never transfers")
end

function T.constructor_validates_its_composition()
  Assert.throws(function()
    ---@diagnostic disable-next-line: param-type-mismatch -- the missing composition is the invalid input under test
    NewGamePreparationState.new("nope")
  end)
  Assert.throws(function()
    local options = { derivedAssets = {}, onReady = function() end }
    options.onCancel = "menu"
    ---@diagnostic disable-next-line: param-type-mismatch -- the mistyped callback is the invalid input under test
    NewGamePreparationState.new(options)
  end)
  Assert.throws(function()
    NewGamePreparationState.new(entryOptions(pendingHost(), { versionId = "" }))
  end, "a missing versionId is rejected")
  Assert.throws(function()
    local options = entryOptions(pendingHost())
    options.startupPairIndex = nil
    NewGamePreparationState.new(options)
  end, "a missing walking pair is rejected, never generated")
  Assert.throws(function()
    NewGamePreparationState.new(entryOptions(pendingHost(), { startupPairIndex = 33 }))
  end, "a pair outside 1..32 is rejected")
end

-- Records the status payload the owned themed stage is drawn with, without
-- changing what it paints: the wrapper calls through to the real
-- presentation.
local function captureStageStatus(state)
  local seen = {}
  local loading = assert(state.loading, "the entry owns its themed stage from creation")
  local originalDraw = loading.draw
  function loading.draw(self, status)
    seen[#seen + 1] = status
    return originalDraw(self, status)
  end
  return seen
end

function T.preparation_renders_progress_from_the_intro_milestone_only()
  local snapshot = { state = "pending", ready = 3, total = 8 }
  local host = {
    requestStartupWalker = function()
      return false
    end,
    requestMilestone = function(name, urgency)
      Assert.equal(name, "new-game-intro")
      Assert.equal(urgency, "required")
      return false
    end,
    milestoneStatus = function(name)
      Assert.equal(name, "new-game-intro")
      return snapshot
    end,
  }
  local readyCalls = 0
  local state = NewGamePreparationState.new(entryOptions(host, {
    onReady = function()
      readyCalls = readyCalls + 1
    end,
  }))
  state:update(0)
  Assert.equal(state.phase, "pending")
  Assert.deepEqual(state.progress, snapshot, "the update retains the milestone-local snapshot")
  Assert.equal(readyCalls, 0, "progress observation never triggers the transfer")
  local seen = captureStageStatus(state)
  state:draw()
  Assert.equal(#seen, 1, "the pending entry paints its themed stage")
  Assert.equal(seen[1].message, "Preparing your adventure", "the stage carries the entry status line")
  Assert.near(seen[1].fraction, 3 / 8, 1e-9, "the status fraction tracks ready over total")
end

function T.preparation_renders_an_empty_bar_while_membership_is_unknown()
  local host = {
    requestStartupWalker = function()
      return false
    end,
    requestMilestone = function()
      return false
    end,
    milestoneStatus = function()
      return { state = "pending", ready = 0, total = nil }
    end,
  }
  local state = NewGamePreparationState.new(entryOptions(host))
  state:update(0)
  Assert.equal(state.phase, "pending")
  local seen = captureStageStatus(state)
  state:draw()
  Assert.equal(#seen, 1, "an unknown denominator still paints the themed stage")
  Assert.isNil(seen[1].fraction, "an unknown denominator carries no status fraction")
end

function T.preparation_failure_raises_before_any_draw()
  local host = {
    requestStartupWalker = function()
      return false
    end,
    requestMilestone = function()
      return false, "intro milestone failed"
    end,
    milestoneStatus = function()
      return { state = "failed", ready = 1, total = 8, failure = "intro milestone failed" }
    end,
  }
  local readyCalls = 0
  local state = NewGamePreparationState.new(entryOptions(host, {
    onReady = function()
      readyCalls = readyCalls + 1
    end,
  }))
  local ok = pcall(function()
    state:update(0)
  end)
  Assert.isFalse(ok, "the milestone failure raises instead of latching a drawable failed phase")
  Assert.equal(readyCalls, 0, "a failed milestone never transfers")
end

return { tests = T }
