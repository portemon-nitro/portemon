-- Focused ownership for deferred field-entry planning: the preparation
-- state polls its planning and runtime prerequisites with no loader,
-- builds its planning loader exactly once after readiness, overlaps
-- target demand with a pending runtime, never retries a failed build,
-- and never releases the borrowed loader on disposal.

local Assert = require("tests.support.Assert")
local FieldPreparationState = require("game.hgss.src.field.FieldPreparationState")

local T = {}

local function readyGeometryLoader(calls)
  local loader = {}
  function loader:globalPosition(_, fieldX, fieldZ)
    return { x = fieldX, z = fieldZ }
  end
  function loader:requestLocation(_, _, _, _)
    calls.requests = (calls.requests or 0) + 1
    return true
  end
  return loader
end

local function continueOptions(overrides)
  local options = {
    kind = "continue",
    saveId = "save-00000002",
    versionId = "heartgold",
    derivedAssets = {
      requestMilestone = function()
        return true
      end,
      requestLogicalField = function()
        return true
      end,
    },
    saveStore = {
      load = function(_, _)
        return { mapId = 60, fieldX = 684, fieldZ = 393 }
      end,
    },
    createLoader = function()
      return readyGeometryLoader({})
    end,
    enterField = function() end,
    onCancel = function() end,
  }
  if overrides ~= nil then
    for key, value in pairs(overrides) do
      options[key] = value
    end
  end
  return options
end

local function settle(state)
  for _ = 1, 10 do
    state:update(1 / 60)
  end
end

-- Two-gate host for the overlapped entry contract: planning and runtime
-- readiness are independent interests, and every milestone demand is
-- logged so tests can prove demand ordering and urgency.
local function gatedHost(gates, log)
  return {
    requestMilestone = function(name, urgency)
      log[#log + 1] = { name = name, urgency = urgency }
      if name == "field-planning" then
        return gates.planning, gates.planningFailure
      end
      if name == "field-runtime" then
        return gates.runtime, gates.runtimeFailure
      end
      if name == "new-game-intro" then
        return true
      end
      return false
    end,
    requestLogicalField = function(mapId, urgency)
      gates.logicalCalls = gates.logicalCalls or {}
      gates.logicalCalls[#gates.logicalCalls + 1] = { mapId = mapId, urgency = urgency }
      if gates.logicalFailure ~= nil then
        return false, gates.logicalFailure
      end
      if gates.logical == nil then
        return true
      end
      return gates.logical
    end,
  }
end

local function gatedLoader(calls, behavior)
  local loader = {}
  function loader:globalPosition(_, fieldX, fieldZ)
    return { x = fieldX, z = fieldZ }
  end
  function loader:requestLocation(_, _, _, _)
    calls.requests = (calls.requests or 0) + 1
    return behavior.ready, behavior.failure
  end
  return loader
end

local function newGameOptions(gates, log, calls, behavior, overrides)
  local options = {
    kind = "newgame",
    candidate = {
      location = { mapSymbol = "MAP_NEW_BARK_PLAYER_HOUSE_2F", fieldX = 6, fieldZ = 6 },
    },
    versionId = "heartgold",
    derivedAssets = gatedHost(gates, log),
    createLoader = function()
      return gatedLoader(calls, behavior)
    end,
    enterField = function()
      calls.transfers = (calls.transfers or 0) + 1
    end,
    onCancel = function() end,
  }
  if overrides ~= nil then
    for key, value in pairs(overrides) do
      options[key] = value
    end
  end
  return options
end

function T.construction_builds_no_loader_while_readiness_is_pending()
  local builds = 0
  local pending = true
  local state = FieldPreparationState.new(continueOptions({
    derivedAssets = {
      requestMilestone = function()
        return not pending
      end,
      requestLogicalField = function()
        return true
      end,
    },
    createLoader = function()
      builds = builds + 1
      return readyGeometryLoader({})
    end,
  }))
  Assert.equal(state.phase, "assets")
  settle(state)
  Assert.equal(builds, 0, "pending core never builds the planning loader")
  pending = false
  settle(state)
  Assert.equal(builds, 1, "readiness builds the planning loader exactly once")
  Assert.equal(state.phase, "done")
  state:dispose()
end

function T.geometry_polling_reuses_the_single_built_loader()
  local builds = 0
  local geometryPolls = 0
  local geometryReady = false
  local backing = {}
  local state = FieldPreparationState.new(continueOptions({
    createLoader = function()
      builds = builds + 1
      local loader = readyGeometryLoader(backing)
      function loader:requestLocation(_, _, _, _)
        geometryPolls = geometryPolls + 1
        return geometryReady
      end
      return loader
    end,
  }))
  settle(state)
  Assert.equal(builds, 1, "readiness builds the planning loader exactly once")
  Assert.equal(state.phase, "location")
  for _ = 1, 5 do
    state:update(1 / 60)
  end
  Assert.equal(builds, 1, "geometry polling never rebuilds the loader")
  Assert.isTrue(geometryPolls >= 5, "geometry polling reuses the retained loader")
  geometryReady = true
  settle(state)
  Assert.equal(builds, 1, "transfer still owns exactly one loader")
  Assert.equal(state.phase, "done")
  state:dispose()
end

function T.escape_before_readiness_never_builds_a_loader()
  local builds = 0
  local cancelled = 0
  local state = FieldPreparationState.new(continueOptions({
    derivedAssets = {
      requestMilestone = function()
        return false
      end,
      requestLogicalField = function()
        return true
      end,
    },
    createLoader = function()
      builds = builds + 1
      return readyGeometryLoader({})
    end,
    onCancel = function()
      cancelled = cancelled + 1
    end,
  }))
  settle(state)
  state:keypressed("escape")
  Assert.equal(builds, 0, "escape before readiness never builds a loader")
  Assert.equal(cancelled, 1)
  settle(state)
  Assert.equal(builds, 0, "a cancelled preparation never builds late")
  state:dispose()
end

function T.failed_loader_build_raises_directly()
  local builds = 0
  local state = FieldPreparationState.new(continueOptions({
    createLoader = function()
      builds = builds + 1
      error("injected world metadata failure", 0)
    end,
  }))
  local ok, err = pcall(settle, state)
  Assert.isFalse(ok, "a failed build raises instead of latching a failed phase")
  Assert.isTrue(
    string.find(tostring(err), "injected world metadata failure", 1, true) ~= nil,
    "the original build error is preserved"
  )
  Assert.equal(builds, 1, "the failed build ran exactly once")
  state:dispose()
end

function T.new_game_demands_its_target_while_runtime_is_still_pending()
  local log = {}
  local calls = {}
  local gates = { planning = true, runtime = false }
  local state = FieldPreparationState.new(newGameOptions(gates, log, calls, { ready = false }))
  settle(state)
  Assert.isTrue((calls.requests or 0) >= 1, "planning readiness starts target location demand")
  Assert.equal(calls.transfers or 0, 0, "a pending runtime never transfers early")
  Assert.equal(state.phase, "location", "the state waits on the target while runtime is pending")
  state:dispose()
end

function T.transfer_waits_for_target_and_runtime_together()
  local log = {}
  local calls = {}
  local gates = { planning = true, runtime = false }
  local behavior = { ready = true }
  local state = FieldPreparationState.new(newGameOptions(gates, log, calls, behavior))
  settle(state)
  Assert.equal(calls.transfers or 0, 0, "a ready target alone never transfers")
  gates.runtime = true
  settle(state)
  Assert.equal(calls.transfers or 0, 1, "the transfer runs once both closures are ready")
  Assert.equal(state.phase, "done")
  settle(state)
  Assert.equal(calls.transfers or 0, 1, "settling never transfers twice")
  state:dispose()
end

function T.runtime_failure_raises_while_the_target_is_pending()
  local log = {}
  local calls = {}
  local gates = { planning = true, runtime = false, runtimeFailure = "injected runtime failure" }
  local state = FieldPreparationState.new(newGameOptions(gates, log, calls, { ready = false }))
  local ok, err = pcall(settle, state)
  Assert.isFalse(ok, "a runtime failure raises instead of latching a failed phase")
  Assert.isTrue(
    string.find(tostring(err), "injected runtime failure", 1, true) ~= nil,
    "the runtime cause is preserved"
  )
  Assert.equal(calls.transfers or 0, 0, "a failed runtime never transfers")
  state:dispose()
end

function T.target_failure_raises_while_runtime_is_pending()
  local log = {}
  local calls = {}
  local gates = { planning = true, runtime = false }
  local state =
    FieldPreparationState.new(newGameOptions(gates, log, calls, { ready = false, failure = "injected target failure" }))
  local ok, err = pcall(settle, state)
  Assert.isFalse(ok, "a target failure raises instead of latching a failed phase")
  Assert.isTrue(
    string.find(tostring(err), "injected target failure", 1, true) ~= nil,
    "the target cause is preserved"
  )
  Assert.equal(calls.transfers or 0, 0, "a failed target never transfers")
  state:dispose()
end

function T.cancelled_preparation_never_transfers_on_late_readiness()
  local log = {}
  local calls = {}
  local gates = { planning = false, runtime = false }
  local behavior = { ready = false }
  local state = FieldPreparationState.new(newGameOptions(gates, log, calls, behavior))
  settle(state)
  Assert.equal(calls.transfers or 0, 0, "nothing transfers while both closures are pending")
  state:keypressed("escape")
  gates.planning = true
  gates.runtime = true
  behavior.ready = true
  settle(state)
  Assert.equal(calls.transfers or 0, 0, "late readiness never transfers a cancelled preparation")
  state:dispose()
end

function T.continue_rejects_a_save_without_a_field_location()
  local transfers = 0
  local state = FieldPreparationState.new(continueOptions({
    saveStore = {
      load = function(_, _)
        return { mapId = nil, fieldX = nil, fieldZ = nil }
      end,
    },
    enterField = function()
      transfers = transfers + 1
    end,
  }))
  local ok = pcall(settle, state)
  Assert.isFalse(ok, "an unvalidated save raises instead of latching a failed phase")
  Assert.equal(transfers, 0, "an unvalidated save never transfers")
  state:dispose()
end

function T.disposal_drops_references_without_releasing_the_borrowed_loader()
  local releases = 0
  local loader = readyGeometryLoader({})
  function loader:release()
    releases = releases + 1
  end
  local state = FieldPreparationState.new(continueOptions({
    createLoader = function()
      return loader
    end,
  }))
  settle(state)
  Assert.equal(state.phase, "done")
  state:dispose()
  Assert.equal(releases, 0, "the borrowed loader is never released by state disposal")
end

-- The destination closure has exactly one owner: the planning loader's
-- location demand. Preparation never inspects loader world metadata and
-- never enrolls a second direct logical demand alongside it, so these hosts
-- offer no direct logical channel at all: any such call fails the test run.
local function singleOwnerHost(gates, log)
  local host = gatedHost(gates, log)
  host.requestLogicalField = nil
  return host
end

local function singleOwnerOptions(gates, log, calls, behavior, loaderWorld)
  local loader = gatedLoader(calls, behavior)
  loader.world = loaderWorld
  return newGameOptions(gates, log, calls, behavior, {
    createLoader = function()
      return loader
    end,
  })
end

local function assertNoDirectLogicalDemand(host)
  Assert.isNil(host.requestLogicalField, "preparation hosts offer no direct logical channel")
end

function T.geometry_polling_demands_the_destination_through_location_only()
  local log = {}
  local calls = {}
  local gates = { planning = true, runtime = true }
  local host = singleOwnerHost(gates, log)
  assertNoDirectLogicalDemand(host)
  local options = singleOwnerOptions(gates, log, calls, { ready = false }, {
    bySymbol = { MAP_NEW_BARK_PLAYER_HOUSE_2F = 64 },
    maps = {},
  })
  options.derivedAssets = host
  local state = FieldPreparationState.new(options)
  settle(state)
  Assert.isTrue((calls.requests or 0) >= 1, "pending geometry is demanded through location")
  Assert.equal(calls.transfers or 0, 0, "pending geometry never transfers")
  Assert.equal(state.phase, "location")
  state:dispose()
end

function T.transfer_waits_for_location_and_runtime_together()
  local log = {}
  local calls = {}
  local gates = { planning = true, runtime = true }
  local host = singleOwnerHost(gates, log)
  assertNoDirectLogicalDemand(host)
  local location = { ready = false }
  local options = singleOwnerOptions(gates, log, calls, location, {
    bySymbol = { MAP_NEW_BARK_PLAYER_HOUSE_2F = 64 },
    maps = {},
  })
  options.derivedAssets = host
  local state = FieldPreparationState.new(options)
  settle(state)
  Assert.equal(calls.transfers or 0, 0, "pending location holds the transfer")
  Assert.equal(state.phase, "location")
  location.ready = true
  settle(state)
  Assert.equal(calls.transfers or 0, 1, "the transfer runs once location and runtime are ready")
  Assert.equal(state.phase, "done")
  state:dispose()
end

function T.location_failure_raises_before_transfer()
  local log = {}
  local calls = {}
  local gates = { planning = true, runtime = true }
  local host = singleOwnerHost(gates, log)
  assertNoDirectLogicalDemand(host)
  local options = singleOwnerOptions(gates, log, calls, { ready = false, failure = "injected location failure" }, {
    bySymbol = { MAP_NEW_BARK_PLAYER_HOUSE_2F = 64 },
    maps = {},
  })
  options.derivedAssets = host
  local state = FieldPreparationState.new(options)
  local ok, err = pcall(settle, state)
  Assert.isFalse(ok, "a location failure raises instead of latching a failed phase")
  Assert.isTrue(
    string.find(tostring(err), "injected location failure", 1, true) ~= nil,
    "the location cause is preserved"
  )
  Assert.equal(calls.transfers or 0, 0, "a failed location never transfers")
  state:dispose()
end

local function continueGatedOptions(gates, log, storeCalls, loaderCalls, behavior, storeBehavior)
  return continueOptions({
    derivedAssets = gatedHost(gates, log),
    saveStore = {
      load = function(_, _)
        storeCalls.loads = (storeCalls.loads or 0) + 1
        if storeBehavior ~= nil and storeBehavior.failure ~= nil then
          error(storeBehavior.failure, 0)
        end
        return { mapId = 60, fieldX = 684, fieldZ = 393 }
      end,
    },
    createLoader = function()
      loaderCalls.builds = (loaderCalls.builds or 0) + 1
      return gatedLoader(loaderCalls, behavior)
    end,
    enterField = function()
      loaderCalls.transfers = (loaderCalls.transfers or 0) + 1
    end,
  })
end

local function recordPreparationDraw(draw)
  local calls = { prints = {} }
  local previousLove = rawget(_G, "love")
  rawset(_G, "love", {
    graphics = {
      setColor = function() end,
      print = function(text, _, _)
        calls.prints[#calls.prints + 1] = tostring(text)
      end,
      printf = function(text, _, _, _)
        calls.prints[#calls.prints + 1] = tostring(text)
      end,
      getWidth = function()
        return 640
      end,
    },
  })
  local ok, err = pcall(draw)
  rawset(_G, "love", previousLove)
  return { ok = ok, err = err, prints = calls.prints }
end

local function printedMatching(prints, pattern)
  for _, text in ipairs(prints) do
    if text:find(pattern) ~= nil then
      return true
    end
  end
  return false
end

function T.continue_loads_the_saved_record_while_both_closures_are_still_pending()
  local log = {}
  local storeCalls = {}
  local loaderCalls = {}
  local gates = { planning = false, runtime = false }
  local state = FieldPreparationState.new(continueGatedOptions(gates, log, storeCalls, loaderCalls, { ready = false }))
  settle(state)
  Assert.equal(storeCalls.loads or 0, 1, "the saved record loads once while both closures are pending")
  Assert.notNil(state.record, "the loaded record is retained while closures are pending")
  Assert.notNil(state.target, "the destination is known while closures are pending")
  Assert.equal(loaderCalls.builds or 0, 0, "no loader is built before the entry closure is ready")
  Assert.equal(loaderCalls.transfers or 0, 0, "nothing transfers while closures are pending")
  settle(state)
  Assert.equal(storeCalls.loads, 1, "repeated updates never reload the saved record")
  state:dispose()
end

function T.continue_demands_its_destination_while_runtime_is_still_pending()
  local log = {}
  local storeCalls = {}
  local loaderCalls = {}
  local gates = { planning = true, runtime = false }
  local behavior = { ready = false }
  local state = FieldPreparationState.new(continueGatedOptions(gates, log, storeCalls, loaderCalls, behavior))
  settle(state)
  Assert.equal(storeCalls.loads or 0, 1, "the saved record loads without waiting for the runtime")
  Assert.isTrue((loaderCalls.requests or 0) >= 1, "entry-closure readiness starts destination demand")
  Assert.equal(loaderCalls.transfers or 0, 0, "a pending runtime never transfers early")
  Assert.equal(state.phase, "location", "the state waits on the destination while runtime is pending")
  behavior.ready = true
  gates.runtime = true
  settle(state)
  Assert.equal(loaderCalls.transfers or 0, 1, "the transfer runs once destination and runtime are ready")
  Assert.equal(state.phase, "done")
  settle(state)
  Assert.equal(loaderCalls.transfers or 0, 1, "settling never transfers twice")
  Assert.equal(storeCalls.loads, 1, "the transfer path never reloads the saved record")
  state:dispose()
end

function T.continue_save_failure_raises_while_closures_are_still_pending()
  local log = {}
  local storeCalls = {}
  local loaderCalls = {}
  local gates = { planning = false, runtime = false }
  local state = FieldPreparationState.new(
    continueGatedOptions(gates, log, storeCalls, loaderCalls, { ready = false }, { failure = "injected save failure" })
  )
  local ok, err = pcall(settle, state)
  Assert.isFalse(ok, "a save failure raises even while closures are pending")
  Assert.isTrue(
    string.find(tostring(err), "injected save failure", 1, true) ~= nil,
    "the save cause is preserved"
  )
  Assert.equal(loaderCalls.transfers or 0, 0, "a failed save never transfers")
  Assert.equal(storeCalls.loads or 0, 1, "the failed load ran exactly once")
  state:dispose()
end

function T.cancelled_continue_never_transfers_on_late_readiness()
  local log = {}
  local storeCalls = {}
  local loaderCalls = {}
  local gates = { planning = false, runtime = false }
  local behavior = { ready = false }
  local state = FieldPreparationState.new(continueGatedOptions(gates, log, storeCalls, loaderCalls, behavior))
  settle(state)
  Assert.equal(storeCalls.loads or 0, 1, "the saved record loads before cancellation")
  Assert.equal(loaderCalls.transfers or 0, 0, "nothing transfers while both closures are pending")
  state:keypressed("escape")
  gates.planning = true
  gates.runtime = true
  behavior.ready = true
  settle(state)
  Assert.equal(loaderCalls.transfers or 0, 0, "late readiness never transfers a cancelled preparation")
  state:dispose()
end

function T.preparation_draw_names_pending_closures_and_destination_truthfully()
  local log = {}
  local storeCalls = {}
  local loaderCalls = {}
  local gates = { planning = false, runtime = false }
  local behavior = { ready = false }
  local state = FieldPreparationState.new(continueGatedOptions(gates, log, storeCalls, loaderCalls, behavior))
  settle(state)
  local pending = recordPreparationDraw(function()
    state:draw()
  end)
  Assert.isTrue(pending.ok, "drawing while closures are pending never fails: " .. tostring(pending.err))
  Assert.isFalse(
    printedMatching(pending.prints, "planning"),
    "the closure wait never claims the entry-closure name"
  )
  Assert.isTrue(printedMatching(pending.prints, "assets"), "the closure wait names the pending closures")
  gates.planning = true
  settle(state)
  local destined = recordPreparationDraw(function()
    state:draw()
  end)
  Assert.isTrue(destined.ok, "drawing while the destination is pending never fails: " .. tostring(destined.err))
  Assert.isFalse(
    printedMatching(destined.prints, "planning"),
    "the destination wait never claims the entry-closure name"
  )
  Assert.isTrue(printedMatching(destined.prints, "location"), "the destination wait names the destination")
  state:dispose()
end

return { tests = T }
