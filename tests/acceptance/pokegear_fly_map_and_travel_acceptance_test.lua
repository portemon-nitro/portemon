-- Standalone Town and Fly map journeys through the real companion
-- script host with the real field-move runtime and eligibility policy
-- underneath. A view-only Town map opens, confirms locations, and
-- closes back to its script without emitting any field travel; a genuine
-- Fly confirmation travels exactly once through the named world handoff
-- carrying a semantic flypoint key, never raw coordinates; and a
-- destination acquisition failure surfaces its original error while the
-- source field stays usable. Only host audio and the world adapter are
-- fakes; maps, eligibility, and ownership are real. No ROM data is
-- required.

local Assert = require("tests.support.Assert")
local PokegearAssetSchema = require("libs.assets.src.PokegearAssetSchema")

local T = {
  metadata = {
    tags = { "pokegear" },
  },
  tests = {},
}

---@param path string
---@return table
local function visualRef(path)
  return { image = path, width = 32, height = 32, anchorX = 0, anchorY = 0 }
end

-- Synthetic companion catalog with two semantic fly destinations,
-- validated through the real asset schema so the journeys borrow only
-- genuine semantic references.
---@return table
local function fixtureManifest()
  return {
    schema = "g4-pokegear-assets-v1",
    skins = { 0, 1, 2, 3, 4, 5 },
    shell = { foreground = visualRef("assets/generated/pokegear/shell-foreground-skin-0.png") },
    configure = { panel = visualRef("assets/generated/pokegear/configure-panel.png") },
    phone = { panel = visualRef("assets/generated/pokegear/phone-panel.png") },
    map = { base = visualRef("assets/generated/pokegear/map-base.png") },
    fly = { base = visualRef("assets/generated/pokegear/fly-base.png") },
    radio = { dial = visualRef("assets/generated/pokegear/radio-dial.png") },
    catalog = {
      contacts = {},
      contactOrder = {},
      callDefinitions = {},
      callTriggers = {},
      rematches = {},
      gifts = {},
      momPurchases = {},
      locations = {
        { key = "test.place.violet" },
        { key = "test.place.new-bark" },
      },
      flypoints = {
        { key = "test.fly.violet" },
        { key = "test.fly.new-bark" },
      },
      reception = {},
      shows = {},
      radioEffects = {},
    },
    text = {},
    sequences = {},
  }
end

-- Source-normalized map context for an outdoor main-matrix cell. Field
-- values stay synthetic; only the record shape follows the map contract.
---@return table
local function outdoorContext()
  return {
    fieldMap = "test.field.new-bark",
    location = "test.place.new-bark",
    matrixX = 96,
    matrixY = 64,
    region = "johto",
    unlockLevel = 1,
    specialMode = nil,
    playerGender = "boy",
  }
end

-- Eligibility context satisfying the real badge, map-policy, and escort
-- checks for Fly: the storm badge bit, a fly-permitting map, and no
-- follower, costume, safari, or park restriction.
---@return table
local function eligibleFlyContext()
  return {
    badges = 16,
    fieldUse = { flyAllowed = true },
    humanFollower = false,
    rocketCostume = false,
    safari = false,
    palPark = false,
  }
end

---@return table audio stub with only host-boundary tones
local function stubAudio()
  return {
    isEffectWaitComplete = function()
      return true
    end,
  }
end

-- Opens the real companion script host over durable gear state, the
-- validated catalog, and a real-shaped world carrying a fixed player
-- position the journeys assert never moves without travel.
---@param record table
---@param world table
---@return table host, table state
local function openHost(record, world)
  local PokegearScriptHost = require("game.hgss.src.pokegear.PokegearScriptHost")
  local PokegearState = require("libs.hgss.src.save.PokegearState")
  local PokegearRandom = require("game.hgss.src.pokegear.PokegearRandom")
  local state = PokegearState.new({ seed = 9177 }, { catalog = record.catalog })
  local host = PokegearScriptHost.new({
    state = state,
    catalog = record.catalog,
    messages = {},
    world = world,
    audio = stubAudio(),
    random = PokegearRandom.new(9177),
  })
  return host, state
end

-- The real field-move runtime over the real eligibility policy and a
-- recording world adapter. The adapter answers the named semantic
-- destination handoff and records every travel call; arrivals happen
-- only through it, never through direct coordinate assignment.
---@param planFly fun(self: table, flypointKey: string, context: table): table
---@return table runtime, table world
local function ownedRuntime(planFly)
  local FieldMoveRuntime = require("libs.hgss.src.field.FieldMoveRuntime")
  local FieldMovePolicy = require("libs.hgss.src.field.FieldMovePolicy")
  local world = { calls = {} }
  function world:cancelMotion(_)
    self.calls[#self.calls + 1] = { op = "cancelMotion" }
  end
  local adapter = setmetatable({ calls = world.calls }, { __index = world })
  function adapter:planFly(flypointKey, context)
    self.calls[#self.calls + 1] = { op = "planFly", flypointKey = flypointKey, context = context }
    return planFly(self, flypointKey, context)
  end
  local policy = {
    check = function(move, context)
      return FieldMovePolicy.check(move, context)
    end,
  }
  return FieldMoveRuntime.new({ policy = policy, world = adapter }), adapter
end

-- Steps the host until it reports a terminal result. The bound only
-- guards against a stuck host; a healthy map settles in a few fixed
-- steps with no wall-clock waits.
---@param host table
---@param handle table
---@return table terminal result
local function settleHost(host, handle)
  for _ = 1, 40 do
    local result = host:result(handle)
    if result ~= nil then
      return result --[[@as table]]
    end
    host:step(handle, { { type = "advance" } })
  end
  error("the companion map never reached its terminal result", 0)
end

-- A view-only Town map opened through the real script entry confirms
-- locations and closes back to its script with no field travel: the
-- real runtime never admits an operation, the player position never
-- moves, and the terminal carries no destination of any kind.
function T.tests.view_only_town_map_closes_without_travel()
  local record = PokegearAssetSchema.validate(fixtureManifest())
  Assert.notNil(record, "the synthetic companion catalog must validate through the asset schema")
  assert(record ~= nil, "synthetic catalog validated above")
  local world = { player = { x = 5, y = 7 } }
  local host, _ = openHost(record, world)
  local runtime, adapter = ownedRuntime(function(_, _, _)
    error("a view-only town map never reaches the destination handoff", 0)
  end)

  local handle = host:open({ mode = "townMap", parentOwner = "script:test-townmap" })
  Assert.isTrue(host:isActive(), "the view-only map holds the feature lease while open")
  Assert.isFalse(host:isStableForSave(), "an open map denies save capture")
  host:step(handle, { { type = "confirm" } })
  host:step(handle, { { type = "cancel" } })
  local terminal = settleHost(host, handle)
  Assert.isNil(terminal.destination, "a view-only close carries no destination")
  Assert.isNil(terminal.flypointKey, "a view-only close carries no flypoint key")
  Assert.isFalse(runtime:isBusy(), "no field travel operation was ever admitted")
  Assert.deepEqual(adapter.calls, {}, "no destination handoff was ever attempted")
  Assert.deepEqual(world.player, { x = 5, y = 7 }, "confirming locations never moves the field player")
  host:close(handle)
  Assert.isFalse(host:isActive(), "closing the map releases the lease")
  Assert.isTrue(host:isStableForSave(), "a closed map captures saves again")
  host:dispose()
end

-- A genuine Fly confirmation travels exactly once through the named
-- world handoff: the terminal carries a semantic flypoint key with no
-- raw coordinates, the handoff resolves it to the existing destination
-- record, and money, items, move PP, and phone state are untouched
-- because selection publishes a choice, not a mutation.
function T.tests.confirmed_fly_selection_arrives_through_the_field_move_owner()
  local record = PokegearAssetSchema.validate(fixtureManifest())
  Assert.notNil(record, "the synthetic companion catalog must validate through the asset schema")
  assert(record ~= nil, "synthetic catalog validated above")
  local world = { player = { x = 5, y = 7 } }
  local host, _ = openHost(record, world)
  local runtime, adapter = ownedRuntime(function(_, flypointKey, _)
    Assert.equal(flypointKey, "test.fly.violet", "the handoff receives the confirmed semantic flypoint")
    return { map = "test.field.violet", warp = 0, fieldX = 11, fieldZ = 23, facing = "south" }
  end)

  local admitted = runtime:queue({ move = "fly", slot = 0, partyRevision = 7, context = eligibleFlyContext() })
  Assert.equal(admitted.kind, "accepted", "an eligible fly request is admitted through the real policy")
  Assert.isTrue(runtime:isBusy(), "the runtime holds its busy gate across destination selection")

  local handle = host:open({
    mode = "fly",
    parentOwner = "field-move:test-fly",
    selection = {
      slot = 0,
      partyRevision = 7,
      mapContext = outdoorContext(),
      destinations = { "test.fly.violet", "test.fly.new-bark" },
    },
  })
  host:step(handle, { { type = "confirm", flypoint = "test.fly.violet" } })
  local terminal = settleHost(host, handle)
  Assert.keySet(
    terminal,
    "flypointKey,kind,operationId",
    "the fly terminal carries a semantic flypoint key, never raw coordinates"
  )
  Assert.equal(terminal.kind, "destination", "confirmation reports a destination")
  Assert.equal(terminal.flypointKey, "test.fly.violet", "the terminal names the confirmed semantic flypoint")

  local destination = adapter:planFly(terminal.flypointKey, {
    slot = 0,
    partyRevision = 7,
    mapContext = outdoorContext(),
  })
  Assert.equal(destination.map, "test.field.violet", "the handoff resolves the semantic key to its map")
  Assert.equal(#adapter.calls, 1, "selection performs exactly one validated destination handoff")
  Assert.equal(adapter.calls[1].op, "planFly", "arrival routes through the named semantic handoff")
  Assert.equal(adapter.calls[1].flypointKey, "test.fly.violet", "the handoff carries the confirmed key")
  host:close(handle)
  runtime:dispose()
  Assert.isFalse(runtime:isBusy(), "the completed travel releases the runtime busy gate")
  host:dispose()
end

-- A destination acquisition failure preserves the source field: the
-- original handoff error surfaces unchanged, no arrival is recorded,
-- the runtime settles idle, and a fresh fly request is admitted
-- afterwards, proving the failed operation left nothing half-published.
function T.tests.failed_destination_acquisition_preserves_the_source_field()
  local Errors = require("libs.errors.src.Errors")
  local record = PokegearAssetSchema.validate(fixtureManifest())
  Assert.notNil(record, "the synthetic companion catalog must validate through the asset schema")
  assert(record ~= nil, "synthetic catalog validated above")
  local world = { player = { x = 5, y = 7 } }
  local host, _ = openHost(record, world)
  local runtime, adapter = ownedRuntime(function(_, flypointKey, _)
    Errors.raise(
      "SCRIPT_INVALID_REFERENCE",
      "unknown flypoint spawn has no cited landing destination: " .. tostring(flypointKey),
      { spawn = flypointKey }
    )
  end)

  local admitted = runtime:queue({ move = "fly", slot = 0, partyRevision = 7, context = eligibleFlyContext() })
  Assert.equal(admitted.kind, "accepted", "an eligible fly request is admitted through the real policy")
  local handle = host:open({
    mode = "fly",
    parentOwner = "field-move:test-failing-fly",
    selection = {
      slot = 0,
      partyRevision = 7,
      mapContext = outdoorContext(),
      destinations = { "test.fly.violet", "test.fly.new-bark" },
    },
  })
  host:step(handle, { { type = "confirm", flypoint = "test.fly.violet" } })
  local terminal = settleHost(host, handle)
  Assert.equal(terminal.flypointKey, "test.fly.violet", "selection still resolves before acquisition runs")

  local failure = Assert.throws(function()
    adapter:planFly(terminal.flypointKey, { slot = 0, partyRevision = 7, mapContext = outdoorContext() })
  end, "a failing destination acquisition raises instead of arriving")
  local message = tostring((type(failure) == "table" and failure.message) or failure)
  Assert.notNil(
    message:find("test.fly.violet", 1, true),
    "the original acquisition error surfaces with its flypoint context"
  )
  for _, call in ipairs(adapter.calls) do
    Assert.isTrue(call.op ~= "arrive", "no arrival is ever recorded past the failed acquisition")
  end
  Assert.deepEqual(world.player, { x = 5, y = 7 }, "the failed acquisition never moves the field player")
  host:close(handle)
  runtime:dispose()
  Assert.isFalse(runtime:isBusy(), "the failed operation settles the runtime idle")
  Assert.isTrue(host:isStableForSave(), "the failed operation leaves save capture stable")
  local retry = runtime:queue({ move = "fly", slot = 0, partyRevision = 7, context = eligibleFlyContext() })
  Assert.equal(retry.kind, "accepted", "the source field stays usable for a fresh operation")
  runtime:dispose()
  host:dispose()
end

-- Malformed script combinations fail before any effect: a view-only map
-- never accepts a selection or a call request, Fly never opens without
-- its field-move selection or with an out-of-range slot, and unknown
-- modes never open. Every rejection takes no lease and leaves save
-- capture stable.
function T.tests.fly_script_entry_rejects_malformed_combinations()
  local record = PokegearAssetSchema.validate(fixtureManifest())
  Assert.notNil(record, "the synthetic companion catalog must validate through the asset schema")
  assert(record ~= nil, "synthetic catalog validated above")
  local world = { player = { x = 5, y = 7 } }
  local host, _ = openHost(record, world)
  local function selectionWith(slot)
    return {
      slot = slot,
      partyRevision = 7,
      mapContext = outdoorContext(),
      destinations = { "test.fly.violet", "test.fly.new-bark" },
    }
  end
  local townSelection = Assert.throws(function()
    host:open({ mode = "townMap", parentOwner = "script:test-map", selection = selectionWith(0) })
  end, "a view-only map never accepts a selection")
  Assert.equal(townSelection.code, "SCRIPT_INVALID_REFERENCE", "the refusal carries its closed vocabulary")
  local townRequest = Assert.throws(function()
    host:open({
      mode = "townMap",
      parentOwner = "script:test-map",
      request = { id = "map-1", contact = "test.contact", direction = "outgoing", kind = "ordinary" },
    })
  end, "a view-only map never accepts a call request")
  Assert.equal(townRequest.code, "SCRIPT_INVALID_REFERENCE", "the refusal carries its closed vocabulary")
  local selectionless = Assert.throws(function()
    host:open({ mode = "fly", parentOwner = "field-move:test-fly" })
  end, "fly never opens without its field-move selection")
  Assert.equal(selectionless.code, "SCRIPT_INVALID_REFERENCE", "the refusal carries its closed vocabulary")
  local badSlot = Assert.throws(function()
    host:open({ mode = "fly", parentOwner = "field-move:test-fly", selection = selectionWith(9) })
  end, "fly never opens with an out-of-range slot")
  Assert.equal(badSlot.code, "SCRIPT_INVALID_REFERENCE", "the refusal carries its closed vocabulary")
  local unknown = Assert.throws(function()
    host:open({ mode = "radio", parentOwner = "script:test-map" })
  end, "unknown modes never open")
  Assert.equal(unknown.code, "SCRIPT_INVALID_REFERENCE", "the refusal carries its closed vocabulary")
  Assert.isFalse(host:isActive(), "rejected opens take no lease")
  Assert.isTrue(host:isStableForSave(), "rejected opens leave save capture stable")
  Assert.deepEqual(world.player, { x = 5, y = 7 }, "rejected opens never move the field player")
  host:dispose()
end

return T
