-- Later-New-Game field-entry demand tests. While the Oak intro plays, the
-- opening bedroom closure (planning, runtime, exact bedroom location) is
-- enrolled at near urgency without ever blocking Oak; the handoff
-- preparation still promotes the same work to required and owns transfer.
-- These tests drive the leaf-local coordinator with a recording derived
-- host and spies on the location seams.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local FieldMapLoader = require("libs.hgss.src.world.FieldMapLoader")
local NewGameEntryPrewarm = require("game.hgss.src.newgame.NewGameEntryPrewarm")

local T = {}

local OPENING_ROOM = { mapSymbol = "MAP_NEW_BARK_PLAYER_HOUSE_2F", fieldX = 6, fieldZ = 6, facing = "south" }
local GLOBAL_BEDROOM = { x = 101, z = 202 }
local OTHER_ROOM = { mapSymbol = "MAP_NEW_BARK_PLAYER_HOUSE_1F", fieldX = 2, fieldZ = 3 }

-- A derived host stand-in with scripted per-milestone answers. Calls follow
-- the production host convention: plain function fields invoked without a
-- receiver, recording every name/urgency pair for exact-set assertions.
local function fakeHost(script)
  local calls = {}
  local host = {}
  function host.requestMilestone(name, urgency)
    calls[#calls + 1] = { name = name, urgency = urgency }
    if script.raiseMilestone ~= nil then
      error(script.raiseMilestone, 0)
    end
    if script.failures[name] ~= nil then
      return nil, script.failures[name]
    end
    if script.ready[name] then
      return true, nil
    end
    return nil, nil
  end
  return host, calls
end

local function readySet(names)
  local ready = {}
  for _, name in ipairs(names) do
    ready[name] = true
  end
  return ready
end

-- Replaces the loader constructor with a recording stand-in so tests observe
-- the coordinator's demand wiring: one construction, one local-to-global
-- conversion, then near-urgency location demand. Restored by withSpies.
local function spyLoader(script)
  local originalNew = FieldMapLoader.new
  local state = { constructions = {}, conversions = {}, demands = {}, releases = 0 }
  FieldMapLoader.new = function(cacheFs, world, options)
    state.constructions[#state.constructions + 1] = { cacheFs = cacheFs, world = world, options = options }
    local loader = {}
    function loader:globalPosition(symbol, localX, localZ)
      state.conversions[#state.conversions + 1] = { symbol = symbol, x = localX, z = localZ }
      return { x = GLOBAL_BEDROOM.x, z = GLOBAL_BEDROOM.z }
    end
    function loader:requestLocation(symbol, fieldX, fieldZ, urgency)
      state.demands[#state.demands + 1] = { symbol = symbol, x = fieldX, z = fieldZ, urgency = urgency }
      if script.locationFailure ~= nil then
        return nil, script.locationFailure
      end
      if script.locationRaise ~= nil then
        error(script.locationRaise, 0)
      end
      return true, nil
    end
    function loader:release()
      state.releases = state.releases + 1
    end
    return loader
  end
  return state, originalNew
end

local function withSpies(script, fn)
  local loaderState, originalNew = spyLoader(script)
  -- The structural world manifest is a filesystem fixture the component
  -- sandbox does not provide: stub the version-cache read so the
  -- coordinator's CacheFs/worldPath load reaches the spied loader
  -- constructor exactly as the production recipe prescribes.
  local originalForVersion = CacheFs.forVersion
  rawset(CacheFs, "forVersion", function(_)
    local cacheFs = {}
    function cacheFs.loadLua(_, path)
      Assert.equal(path, MapAssetCache.worldPath())
      return { schema = "fixture-world" }
    end
    return cacheFs
  end)
  local ok, err = xpcall(function()
    fn(loaderState)
  end, function(failure)
    return failure
  end)
  FieldMapLoader.new = originalNew
  rawset(CacheFs, "forVersion", originalForVersion)
  if not ok then
    error(err, 0)
  end
end

local function newPrewarm(host, openingLocation)
  return NewGameEntryPrewarm.new({
    versionId = "heartgold",
    derivedAssets = host,
    openingLocation = openingLocation or OPENING_ROOM,
  })
end

local function urgencies(calls, name)
  local found = {}
  for _, call in ipairs(calls) do
    if call.name == name then
      found[#found + 1] = call.urgency
    end
  end
  return found
end

function T.oak_boot_enrolls_planning_and_runtime_at_near_without_a_loader()
  local script = { ready = {}, failures = {} }
  withSpies(script, function(loaderState)
    local host, calls = fakeHost(script)
    local prewarm = newPrewarm(host)
    local enrolled = prewarm:poll()
    Assert.isFalse(enrolled == true, "nothing is enrolled while planning metadata is pending")
    Assert.deepEqual(urgencies(calls, "field-planning"), { "near" }, "planning enrolls speculative at boot")
    Assert.deepEqual(urgencies(calls, "field-runtime"), { "near" }, "runtime enrolls speculative at boot")
    Assert.equal(#loaderState.constructions, 0, "no planning loader exists before planning metadata is ready")
    Assert.equal(#loaderState.demands, 0, "no bedroom demand fires before planning metadata is ready")
    prewarm:dispose()
  end)
end

function T.ready_planning_builds_one_loader_and_enrolls_the_exact_bedroom_at_near()
  local script = { ready = readySet({ "field-planning", "field-runtime" }), failures = {} }
  withSpies(script, function(loaderState)
    local host, calls = fakeHost(script)
    local prewarm = newPrewarm(host)
    local enrolled = prewarm:poll()
    Assert.isTrue(enrolled == true, "the opening closure enrolls once planning metadata is ready")
    Assert.equal(#loaderState.constructions, 1, "one metadata-only planning loader serves the intro")
    Assert.deepEqual(loaderState.conversions, {
      { symbol = OPENING_ROOM.mapSymbol, x = OPENING_ROOM.fieldX, z = OPENING_ROOM.fieldZ },
    }, "map-local opening coordinates convert through the loader, never assumed global")
    Assert.deepEqual(loaderState.demands, {
      {
        symbol = OPENING_ROOM.mapSymbol,
        x = GLOBAL_BEDROOM.x,
        z = GLOBAL_BEDROOM.z,
        urgency = "near",
      },
    }, "the exact bedroom closure enrolls speculative, never required")
    for _, call in ipairs(calls) do
      Assert.equal(call.urgency, "near", "every milestone demand stays speculative")
    end
    prewarm:dispose()
  end)
end

function T.enrolled_closure_is_reaffirmed_while_the_intro_runs()
  local script = { ready = readySet({ "field-planning", "field-runtime" }), failures = {} }
  withSpies(script, function(loaderState)
    local host, _ = fakeHost(script)
    local prewarm = newPrewarm(host)
    prewarm:poll()
    prewarm:poll()
    prewarm:poll()
    Assert.equal(#loaderState.constructions, 1, "the planning loader is constructed once, not per poll")
    Assert.equal(#loaderState.conversions, 1, "the opening position is globalized once, not per poll")
    Assert.equal(#loaderState.demands, 3, "the enrolled closure is re-affirmed every poll so near interest persists")
    prewarm:dispose()
  end)
end

function T.pending_planning_for_the_whole_intro_enrolls_no_bedroom()
  local script = { ready = readySet({ "field-runtime" }), failures = {} }
  withSpies(script, function(loaderState)
    local host, calls = fakeHost(script)
    local prewarm = newPrewarm(host)
    for _ = 1, 5 do
      local enrolled = prewarm:poll()
      Assert.isFalse(enrolled == true, "polling never enrolls while planning stays pending")
    end
    Assert.equal(#loaderState.demands, 0, "pending planning leaves no speculative bedroom enrollment")
    Assert.deepEqual(urgencies(calls, "field-runtime"), {
      "near",
      "near",
      "near",
      "near",
      "near",
    }, "runtime interest is kept enrolled while the intro runs")
    prewarm:dispose()
  end)
end

function T.milestone_failures_never_abort_the_intro()
  local script = { ready = {}, failures = {}, raiseMilestone = "injected provisioner failure" }
  withSpies(script, function(loaderState)
    local host, _ = fakeHost(script)
    local prewarm = newPrewarm(host)
    local ok, enrolled = pcall(function()
      return prewarm:poll()
    end)
    Assert.isTrue(ok, "a raising provisioner host never escapes the speculative poll")
    Assert.isFalse(enrolled == true, "a failed poll enrolls nothing")
    Assert.equal(#loaderState.constructions, 0, "a failed poll builds no loader")
    prewarm:dispose()
  end)
end

function T.location_demand_failures_never_abort_the_intro()
  local script = {
    ready = readySet({ "field-planning", "field-runtime" }),
    failures = {},
    locationFailure = "bedroom plot is missing in the fixture",
  }
  withSpies(script, function(loaderState)
    local host, _ = fakeHost(script)
    local prewarm = newPrewarm(host)
    local ok, _ = pcall(function()
      return prewarm:poll()
    end)
    Assert.isTrue(ok, "a failing location demand never escapes the speculative poll")
    Assert.equal(#loaderState.demands, 1, "the demand was still expressed before it failed")
    prewarm:dispose()
  end)
end

function T.raising_location_demand_never_aborts_the_intro()
  local script = {
    ready = readySet({ "field-planning", "field-runtime" }),
    failures = {},
    locationRaise = "injected loader failure",
  }
  withSpies(script, function(_)
    local host, _ = fakeHost(script)
    local prewarm = newPrewarm(host)
    local ok, _ = pcall(function()
      return prewarm:poll()
    end)
    Assert.isTrue(ok, "a raising loader never escapes the speculative poll")
    prewarm:dispose()
  end)
end

function T.finalized_target_matching_the_enrolled_closure_needs_no_extra_demand()
  local script = { ready = readySet({ "field-planning", "field-runtime" }), failures = {} }
  withSpies(script, function(loaderState)
    local host, _ = fakeHost(script)
    local prewarm = newPrewarm(host)
    prewarm:poll()
    local demandsBefore = #loaderState.demands
    local ensured = prewarm:ensureFinalTarget({
      mapSymbol = OPENING_ROOM.mapSymbol,
      fieldX = OPENING_ROOM.fieldX,
      fieldZ = OPENING_ROOM.fieldZ,
    })
    Assert.isTrue(ensured == true, "the matching finalized target is already enrolled")
    Assert.equal(#loaderState.demands, demandsBefore, "a matching target enrolls no duplicate closure")
    prewarm:dispose()
  end)
end

function T.diverging_finalized_target_enrolls_before_the_handoff()
  local script = { ready = readySet({ "field-planning", "field-runtime" }), failures = {} }
  withSpies(script, function(loaderState)
    local host, _ = fakeHost(script)
    local prewarm = newPrewarm(host)
    prewarm:poll()
    local ensured = prewarm:ensureFinalTarget(OTHER_ROOM)
    Assert.isTrue(ensured == true, "a diverging finalized target still enrolls before the handoff")
    local last = loaderState.demands[#loaderState.demands]
    Assert.deepEqual(last, {
      symbol = OTHER_ROOM.mapSymbol,
      x = GLOBAL_BEDROOM.x,
      z = GLOBAL_BEDROOM.z,
      urgency = "near",
    }, "the finalized target enrolls speculative through the retained loader")
    prewarm:dispose()
  end)
end

function T.finalized_target_without_a_loader_leaves_the_handoff_to_required_demand()
  local script = { ready = {}, failures = {} }
  withSpies(script, function(_)
    local host, _ = fakeHost(script)
    local prewarm = newPrewarm(host)
    prewarm:poll()
    local ensured = prewarm:ensureFinalTarget(OTHER_ROOM)
    Assert.isFalse(ensured == true, "without planning metadata nothing can be enrolled early")
    local malformed = prewarm:ensureFinalTarget({ fieldX = 1, fieldZ = 2 })
    Assert.isFalse(malformed == true, "a location without a map symbol enrolls nothing")
    prewarm:dispose()
  end)
end

function T.disposal_releases_the_loader_once_and_blocks_later_polls()
  local script = { ready = readySet({ "field-planning", "field-runtime" }), failures = {} }
  withSpies(script, function(loaderState)
    local host, _ = fakeHost(script)
    local prewarm = newPrewarm(host)
    prewarm:poll()
    prewarm:dispose()
    Assert.equal(loaderState.releases, 1, "disposal releases the constructed planning loader")
    prewarm:dispose()
    Assert.equal(loaderState.releases, 1, "repeated disposal releases the loader exactly once")
    local ok, enrolled = pcall(function()
      return prewarm:poll()
    end)
    Assert.isTrue(ok, "polling after disposal stays safe")
    Assert.isFalse(enrolled == true, "a disposed coordinator enrolls nothing")
    Assert.isFalse(prewarm:ensureFinalTarget(OTHER_ROOM) == true, "a disposed coordinator ensures nothing")
  end)
end

function T.construction_validates_its_composition_inputs()
  local host, _ = fakeHost({ ready = {}, failures = {} })
  Assert.throws(function()
    NewGameEntryPrewarm.new({ versionId = "heartgold", openingLocation = OPENING_ROOM })
  end, "the coordinator requires its borrowed derived host")
  Assert.throws(function()
    NewGameEntryPrewarm.new({ derivedAssets = host, openingLocation = OPENING_ROOM })
  end, "the coordinator requires its selected version")
  Assert.throws(function()
    NewGameEntryPrewarm.new({ versionId = "heartgold", derivedAssets = host })
  end, "the coordinator requires its opening location")
  Assert.throws(function()
    NewGameEntryPrewarm.new({
      versionId = "heartgold",
      derivedAssets = host,
      openingLocation = { fieldX = 6, fieldZ = 6 },
    })
  end, "the coordinator requires a mapped opening location")
end

return { tests = T }
