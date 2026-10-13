-- Live-owner map markers: opening, reading, and reopening the region map
-- never moves a roamer, never draws a random stream, and never mutates
-- gear state. Only roamers active at creation appear, contact markers
-- follow the shared phone readiness policy, and a field battle only
-- becomes visible after a reopen: the already-open map keeps its refresh
-- snapshot. World owners are real; only the host audio boundary is
-- stubbed. No ROM data is required.

local Assert = require("tests.support.Assert")
local EncounterSave = require("libs.hgss.src.save.EncounterSave")
local HgssRoamerState = require("libs.hgss.src.encounters.HgssRoamerState")
local PokegearAssetSchema = require("libs.assets.src.PokegearAssetSchema")
local PokegearRandom = require("game.hgss.src.pokegear.PokegearRandom")
local PokegearState = require("libs.hgss.src.save.PokegearState")

local T = {
  metadata = {
    tags = { "pokegear" },
  },
  tests = {},
}

-- Loads the map controller that does not exist yet at this baseline. The
-- failure names the missing behaviour instead of surfacing as a suite
-- load error, so the pre-implementation red stays attributable.
---@param moduleName string
---@param missingMessage string
---@return table
local function requireFeature(moduleName, missingMessage)
  local ok, mod = pcall(require, moduleName)
  if not ok then
    error(missingMessage, 0)
  end
  assert(type(mod) == "table", missingMessage)
  return mod --[[@as table]]
end

---@param path string
---@return table
local function visualRef(path)
  return { image = path, width = 32, height = 32, anchorX = 0, anchorY = 0 }
end

-- Synthetic companion catalog with two registered callers and their map
-- locations, validated through the real asset schema so the journey
-- borrows only genuine semantic references.
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
      contacts = {
        { key = "test.caller.falkner", family = "gym", sortWeight = 10, rematchWeekday = 6, rematchTime = 0 },
        { key = "test.caller.mom", family = "mother", sortWeight = 20 },
      },
      contactOrder = { "test.caller.falkner", "test.caller.mom" },
      callDefinitions = {},
      callTriggers = {},
      rematches = {},
      gifts = {},
      momPurchases = {},
      locations = {
        { key = "test.place.violet" },
        { key = "test.place.new-bark" },
      },
      flypoints = {},
      reception = {},
      shows = {},
      radioEffects = {},
    },
    text = {},
    sequences = {},
  }
end

-- Three roamer records across lifecycles: one roaming, one never
-- activated, one already caught. Reference sets stay synthetic; only the
-- lifecycle vocabulary comes from the real owner.
---@return table state, table refs
local function roamerOwners()
  local refs = {
    species = { ["test.raikou"] = true, ["test.entei"] = true, ["test.suicune"] = true },
    maps = { [11] = true, [12] = true, [22] = true },
  }
  local function record(key, species, location, lifecycle)
    return {
      key = key,
      stateVersion = EncounterSave.STATE_VERSION,
      mon = { species = species },
      location = location,
      lifecycle = lifecycle,
      revision = 0,
    }
  end
  local state = HgssRoamerState.new({
    records = {
      record("test.roamer.raikou", "test.raikou", 11, "roaming"),
      record("test.roamer.entei", "test.entei", 12, "inactive"),
      record("test.roamer.suicune", "test.suicune", 22, "caught"),
    },
    species = refs.species,
    maps = refs.maps,
  })
  return state, refs
end

-- Real-shaped world fixture for the shared phone policy: story tier,
-- weekday clock inside the source eligibility window, and a tier team
-- owner. Only the host audio boundary is stubbed.
---@return table world
local function phoneWorld()
  local rematches = {}
  return {
    storyTier = 2,
    weekday = "saturday",
    morning = true,
    teamsByTier = {
      [2] = { tier = 2, members = { { species = "test.pidgeotto", level = 13 } } },
    },
    rematchReady = {},
    queryRematch = function(_, contact)
      return rematches[contact]
    end,
    setRematch = function(_, contact, record)
      rematches[contact] = record
    end,
  }
end

---@param state table
---@param catalog table
---@param world table
---@return table call
local function openCall(state, catalog, world)
  local PhoneCall = require("game.hgss.src.pokegear.PhoneCall")
  return PhoneCall.new({
    state = state,
    catalog = catalog,
    messages = { invitation = "test.invitation", accept = "test.accept" },
    world = world,
    audio = {
      isEffectWaitComplete = function()
        return true
      end,
    },
    random = PokegearRandom.new(90210),
  })
end

-- Builds the detached roamer snapshot the map samples once at creation:
-- only key, species, location, and lifecycle cross the boundary, and the
-- copy is never persisted back.
---@param roamers table
---@return table projection
local function snapshotRoamers(roamers)
  local capture = roamers:capture()
  local projection = {}
  for key, record in pairs(capture.roamers) do
    assert(type(record) == "table", "the roamer capture carries records")
    projection[#projection + 1] = {
      key = key,
      species = record.mon.species,
      location = record.location,
      lifecycle = record.lifecycle,
    }
  end
  table.sort(projection, function(a, b)
    return a.key < b.key
  end)
  return projection
end

-- The shared phone policy behind the map's contact markers: rematch
-- readiness from the conversation owner plus durable pending gifts from
-- gear state, resolved per location without caching a separate copy.
---@param call table
---@param state table
---@param contactPlaces table<string, string> contact to location
---@return fun(location: string): table
local function phonePolicy(call, state, contactPlaces)
  return function(location)
    local markers = {}
    for contact, place in pairs(contactPlaces) do
      if place == location then
        local marker = call:rematchMarker(contact)
        local pending = state:capture().phone.contacts[contact]
        local gift = pending ~= nil and pending.reward or nil
        if marker.ready == true or gift ~= nil then
          markers[#markers + 1] = { contact = contact, tier = marker.tier, ready = marker.ready, gift = gift }
        end
      end
    end
    return markers
  end
end

---@param view table
---@param kind string
---@return table markers of that kind
local function markersOf(view, kind)
  local found = {}
  for _, marker in ipairs(assert(view.markers, "the map view publishes its markers")) do
    if marker.kind == kind then
      found[#found + 1] = marker
    end
  end
  return found
end

-- Opening, reading, and reopening the map moves no roamer, draws no
-- random stream, and mutates no gear state; markers match the refresh
-- snapshot, and a field battle only appears after a reopen.
function T.tests.live_owner_markers_stay_read_only_across_battle_and_reopen()
  local MapController = requireFeature(
    "game.hgss.src.pokegear.MapController",
    "the region map has no controller yet: live roamer and contact markers cannot project without moving their owners"
  )
  local validated = PokegearAssetSchema.validate(fixtureManifest())
  Assert.notNil(validated, "the synthetic companion catalog must validate through the asset schema")
  assert(validated ~= nil, "synthetic catalog validated above")
  local catalog = validated.catalog

  local roamers = roamerOwners()
  local state = PokegearState.new({ seed = 90210 }, { catalog = catalog })
  state:registerContact("test.caller.falkner")
  state:registerContact("test.caller.mom")
  local world = phoneWorld()
  world.weekday = 6
  world.timeOfDay = 0
  world.queryRematch = function(_, contact)
    return state:queryRematch(contact)
  end
  world.setRematch = function(_, contact, record)
    return state:setRematch(contact, record)
  end
  local call = openCall(state, catalog, world)
  state:setRematch("test.caller.falkner", { stage = 1, wins = 0 })
  state:setContactReward("test.caller.mom", { item = "test.potion", quantity = 1 })

  local contactPlaces = {
    ["test.caller.falkner"] = "test.place.violet",
    ["test.caller.mom"] = "test.place.new-bark",
  }
  local mapContext = {
    fieldMap = "test.field.violet",
    location = "test.place.violet",
    matrixX = 64,
    matrixY = 32,
    region = "johto",
    unlockLevel = 1,
    specialMode = nil,
    playerGender = "boy",
  }
  local function openMap()
    return MapController.new({
      state = state,
      assets = validated,
      mapContext = mapContext,
      phoneProjection = phonePolicy(call, state, contactPlaces),
      roamerProjection = snapshotRoamers(roamers),
      wordEntry = {
        open = function(_) end,
        step = function() end,
        result = function()
          return nil
        end,
        cancel = function() end,
      },
    })
  end

  local roamersBefore = roamers:capture()
  local gearBefore = state:capture()
  local revisionBefore = state:revision()

  -- Opening and repeated status reads change nothing: identical view
  -- snapshots, untouched roamer records, and a frozen gear revision.
  -- The map holds no random stream of its own; drawing reads only.
  local first = openMap()
  local once = first:status()
  for _ = 1, 5 do
    Assert.deepEqual(first:status(), once, "map status reads perform no mutation")
  end
  Assert.deepEqual(roamers:capture(), roamersBefore, "opening the map moves no roamer")
  Assert.deepEqual(state:capture(), gearBefore, "opening the map writes no gear state")
  Assert.equal(state:revision(), revisionBefore, "opening the map moves no gear revision")

  -- Only the roamer active at creation appears, at its sampled location;
  -- the inactive and caught records never project.
  local roamerMarkers = markersOf(once.view, "roamer")
  Assert.equal(#roamerMarkers, 1, "exactly the active roamer projects")
  Assert.equal(roamerMarkers[1].key, "test.roamer.raikou", "the active roamer projects")
  Assert.equal(roamerMarkers[1].location, 11, "the marker carries the creation snapshot location")

  -- Contact markers follow the shared policy: the staged rematch shows
  -- ready at its tier, the pending gift shows without readiness, and an
  -- unstaged contact shows nothing.
  local contactMarkers = markersOf(once.view, "contact")
  local byContact = {}
  for _, marker in ipairs(contactMarkers) do
    byContact[marker.contact] = marker
  end
  Assert.notNil(byContact["test.caller.falkner"], "the staged rematch projects a marker")
  Assert.equal(byContact["test.caller.falkner"].ready, true, "the rematch marker reports readiness")
  Assert.equal(byContact["test.caller.falkner"].tier, 2, "the rematch marker projects the queried tier")
  Assert.notNil(byContact["test.caller.mom"], "the pending gift projects a marker")
  Assert.notNil(byContact["test.caller.mom"].gift, "the gift marker carries the pending reward")

  -- A field battle settles through the real owners: the roamer flees to
  -- a new map while the rematch resolves as a win. The already-open map
  -- keeps its refresh snapshot; nothing live-updates under it.
  roamers:prepareResult("test.roamer.raikou", "fled", 0, { location = 12 })
  call:resolveRematch("test.caller.falkner", "win")
  for _ = 1, 3 do
    Assert.deepEqual(first:status(), once, "settled battles never leak into the open map")
  end

  -- Reopening samples fresh owners: the fled roamer appears at its new
  -- map, the won rematch marker clears, and the pending gift still waits.
  local second = openMap()
  local reopened = second:status()
  local roamerAgain = markersOf(reopened.view, "roamer")
  Assert.equal(#roamerAgain, 1, "exactly one roamer projects after the battle")
  Assert.equal(roamerAgain[1].location, 12, "the reopened map samples the post-battle location")
  local contactsAgain = {}
  for _, marker in ipairs(markersOf(reopened.view, "contact")) do
    contactsAgain[marker.contact] = marker
  end
  Assert.isNil(contactsAgain["test.caller.falkner"], "the won rematch clears on reopen")
  Assert.notNil(contactsAgain["test.caller.mom"], "the pending gift still waits after reopen")
  first:dispose()
  second:dispose()
end

return T
