-- Live-owner map markers: opening, reading, and reopening the region map
-- never moves a roamer, never draws a random stream, and never mutates
-- gear state. Only roamers active at creation appear, contact markers
-- follow the shared phone readiness policy, and a field battle only
-- becomes visible after a reopen: the already-open map keeps its refresh
-- snapshot. World owners are real; only the host audio boundary is
-- stubbed. No ROM data is required.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local OpeningLifecycle = require("tests.acceptance.support.OpeningLifecycle")
local EncounterSave = require("libs.hgss.src.save.EncounterSave")
local HgssRoamerState = require("libs.hgss.src.encounters.HgssRoamerState")
local Fixture = require("tests.support.PokegearMapFixture")
local PokegearAssetSchema = require("libs.assets.src.PokegearAssetSchema")
local PokegearRandom = require("game.hgss.src.pokegear.PokegearRandom")
local PokegearState = require("libs.hgss.src.save.PokegearState")
local PokegearJourneyFixture = require("tests.support.PokegearJourneyFixture")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")

local T = {
  metadata = {
    capabilities = { "rom_dump" },
    derivedAssets = {
      "field-runtime",
      "map:33",
      "map:63",
      "map:539",
      "map-data:33",
      "map-data:63",
      "map-data:539",
      "message-bank:273",
      "message-bank:279",
    },
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

-- Synthetic companion family with two registered callers and their map
-- locations over the synthetic region map, validated through the real
-- asset schema so the journey borrows only genuine semantic references.
---@return table
local function fixtureManifest()
  local manifest = Fixture.manifest()
  manifest.catalog.contacts = {
    { key = "test.caller.falkner", family = "gym", sortWeight = 10, rematchWeekday = 6, rematchTime = 0 },
    { key = "test.caller.mom", family = "mother", sortWeight = 20 },
  }
  manifest.catalog.contactOrder = { "test.caller.falkner", "test.caller.mom" }
  manifest.catalog.locations = {
    {
      key = "test.place.violet",
      fieldMap = "MAP_A",
      mapRef = 10,
      matrix = { x = 12 * 32 + 8, y = 8 * 32 + 8 },
      location = "test.location.a",
      section = "test.section.a",
      region = "johto",
    },
    {
      key = "test.place.new-bark",
      fieldMap = "MAP_B",
      mapRef = 11,
      matrix = { x = 14 * 32 + 8, y = 8 * 32 + 8 },
      location = "test.location.b",
      section = "test.section.b",
      region = "johto",
    },
    {
      key = "test.place.far",
      fieldMap = "MAP_KANTO",
      mapRef = 12,
      matrix = { x = 30 * 32 + 8, y = 10 * 32 + 8 },
      location = "test.location.far",
      section = "test.section.far",
      region = "kanto",
    },
  }
  return manifest
end

-- Three roamer records across lifecycles: one roaming, one never
-- activated, one already caught. Reference sets stay synthetic; only the
-- lifecycle vocabulary comes from the real owner.
---@return table state, table refs
local function roamerOwners()
  local refs = {
    species = { RAIKOU = true, ENTEI = true, SUICUNE = true },
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
      record("test.roamer.raikou", "RAIKOU", 11, "roaming"),
      record("test.roamer.entei", "ENTEI", 12, "inactive"),
      record("test.roamer.suicune", "SUICUNE", 22, "caught"),
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
  local function openMap()
    return MapController.new({
      state = state,
      assets = validated,
      mapContext = Fixture.context(),
      messages = Fixture.messages(),
      facts = Fixture.facts(),
      phoneProjection = phonePolicy(call, state, contactPlaces),
      roamerProjection = snapshotRoamers(roamers),
      wordEntry = Fixture.wordEntry(),
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
  local roamerSprites = once.view.sprites.roamers
  Assert.equal(#roamerSprites, 1, "exactly the active roamer projects")
  Assert.equal(roamerSprites[1].frame, 1, "the active roamer is Raikou")
  local sampledAt = { x = roamerSprites[1].x, y = roamerSprites[1].y }

  -- The staged rematch shows the battle icon for the selected location:
  -- the shared policy reports it ready on the player's map.
  Assert.isTrue(once.view.panel.battleIcon, "the staged rematch shows the panel battle icon")

  -- A field battle settles through the real owners: the roamer flees to
  -- a new map while the rematch resolves as a win. The already-open map
  -- keeps its refresh snapshot; nothing live-updates under it.
  roamers:prepareResult("test.roamer.raikou", "fled", 0, { location = 12 })
  call:resolveRematch("test.caller.falkner", "win")
  for _ = 1, 3 do
    Assert.deepEqual(first:status(), once, "settled battles never leak into the open map")
  end

  -- Reopening samples fresh owners: the fled roamer appears at its new
  -- map and the won rematch clears its icon.
  local second = openMap()
  local reopened = second:status()
  local roamerAgain = reopened.view.sprites.roamers
  Assert.equal(#roamerAgain, 1, "exactly one roamer projects after the battle")
  Assert.isTrue(
    roamerAgain[1].x ~= sampledAt.x or roamerAgain[1].y ~= sampledAt.y,
    "the reopened map samples the post-battle location"
  )
  Assert.isFalse(reopened.view.panel.battleIcon, "the won rematch clears its icon on reopen")
  first:dispose()
  second:dispose()
end

local NEW_BARK = "MAP_NEW_BARK"
local NEW_BARK_HOUSE = "MAP_NEW_BARK_PLAYER_HOUSE_1F"
local LEAGUE_WIFI_ROOM = "MAP_POKEMON_LEAGUE_ENTRANCE_WIFI_ROOM"

---@param game table
local function prepareMapCard(game)
  local state = assert(game.runtime.pokegearState, "the composed field owns Pokegear state")
  state:registerCard("map")
  state:setPreference("lastApp", "map")
  game:setWorldState({ flag = FieldScriptSymbols.flagsByName.FLAG_GOT_POKEGEAR })
end

---@param game table
---@return table view
local function openProductionMap(game)
  PokegearJourneyFixture.openGearThroughMenu(game)
  local gear =
    assert(game.runtime.applicationHost:status().application, "the Start Menu owns the open gear application")
  Assert.equal(gear.tab, "map", "the saved card selection opens the Map card")
  local child = assert(gear.child, "the gear shell publishes its active card")
  Assert.equal(child.tab, "map", "the production Map card owns the child")
  return assert(child.view, "the production Map card publishes its map view")
end

-- A source-known indoor header stays at the New Bark world cell through
-- the actual town door and the production Start Menu application path.
function T.tests.new_bark_house_uses_its_source_header_after_the_door_transition()
  PokegearJourneyFixture.withGame(NEW_BARK, function(game)
    prepareMapCard(game)
    local outside = openProductionMap(game)
    -- Source rows carry the map's two-row offset: world cell (21, 12) is row 14.
    Assert.deepEqual(outside.playerCell, { x = 21, y = 14 }, "New Bark's outdoor map resolves to its source world cell")
    Assert.deepEqual(outside.cell, outside.playerCell, "the selected cell begins on the player marker")
    PokegearJourneyFixture.closeGearThroughMenu(game)

    game:moveTo(PokegearJourneyFixture.TOWN_HOUSE_DOOR_APPROACH)
    game:step({ direction = "north" })
    local transition = game:waitForTransition()
    Assert.equal(transition.destination.mapSymbol, NEW_BARK_HOUSE, "the production door enters the player's house")
    OpeningLifecycle.completeOpeningHouseScene(game)
    Assert.isTrue(PokegearJourneyFixture.settleField(game), "the house scene must release the production field")
    local inside = openProductionMap(game)
    Assert.deepEqual(inside.playerCell, { x = 21, y = 14 }, "the house header keeps the player in New Bark")
    Assert.deepEqual(inside.cell, inside.playerCell, "the house selection stays aligned with the player marker")
    Assert.equal(game:renderAttempts(), 0, "the location journey stops before GPU rendering")
    PokegearJourneyFixture.closeGearThroughMenu(game)
  end)
end

-- The League entrance is a source-anchored exterior cell. A direct load
-- into the zero-header Wi-Fi room has no exterior evidence and the Map card
-- must refuse a guessed cell. The source disables saving in this room.
function T.tests.zero_header_direct_resume_refuses_an_unproven_world_cell()
  local defaultGameFactory = AcceptanceHarness.new().gameFactory
  local harness = AcceptanceHarness.new({
    gameFactory = function(versionId, map)
      local save = defaultGameFactory(versionId, map)
      -- The map's source init script starts its first-visit scene only
      -- while this scene variable is zero. This represents a valid save
      -- after that scene, with no recorded exterior position.
      save.worldState:setVar(FieldScriptSymbols.variablesByName.VAR_SCENE_POKECENTER_WIFI_BASEMENT, 1)
      return save
    end,
  })
  local game = harness:boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = LEAGUE_WIFI_ROOM,
    save = "fresh",
    fieldOptions = { recordingScriptHosts = true },
  })
  local ok, err = xpcall(function()
    game:waitForFieldEntry()
    Assert.isTrue(PokegearJourneyFixture.settleField(game), "the post-intro room scene must settle")
    prepareMapCard(game)
    local opened, openErr = pcall(openProductionMap, game)
    local errorText = tostring(openErr)
    Assert.isFalse(opened, "a direct resume into the zero-header room has no exterior fallback")
    Assert.isTrue(
      errorText:find("FEATURE_UNAVAILABLE", 1, true) ~= nil,
      "an unprovable zero-header position reports FEATURE_UNAVAILABLE: " .. errorText
    )
    Assert.isTrue(
      errorText:find(LEAGUE_WIFI_ROOM, 1, true) ~= nil,
      "the unavailable error names the current source map"
    )
    Assert.equal(game:renderAttempts(), 0, "the unavailable location is reported before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

return T
