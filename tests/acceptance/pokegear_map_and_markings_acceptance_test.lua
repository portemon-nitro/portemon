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
local PartyActions = require("libs.hgss.src.field.PartyActions")
local PlayerProgression = require("libs.hgss.src.save.PlayerProgression")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local FieldMoveSources = require("romdump.src.config.FieldMoveSources")
local CacheFs = require("libs.storage.src.CacheFs")
local MapAssetCache = require("libs.assets.src.MapAssetCache")

local T = {
  metadata = {
    capabilities = { "rom_dump" },
    derivedAssets = {
      "field-runtime",
      "map:30",
      "map:27",
      "map:299",
      "map:124",
      "map:178",
      "map:179",
      "map:300",
      "map:58",
      "map:33",
      "map:63",
      "map:539",
      "map:49",
      "map:503",
      "map-data:33",
      "map-data:30",
      "map-data:31",
      "map-data:32",
      "map-data:47",
      "map-data:48",
      "map-data:49",
      "map-data:503",
      "map-data:9",
      "map-data:93",
      "map-data:27",
      "map-data:299",
      "map-data:124",
      "map-data:178",
      "map-data:179",
      "map-data:300",
      "map-data:58",
      "map:60",
      "map-data:60",
      "map-data:63",
      "map-data:539",
      "message-bank:3",
      "message-bank:128",
      "message-bank:267",
      "message-bank:273",
      "message-bank:279",
      "message-bank:361",
      "message-bank:365",
      "message-bank:521",
      "message-bank:522",
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

local function prepareFlyParty(game)
  local runtime = game.runtime
  PlayerProgression.new(assert(runtime.playerData).profile):awardBadge("storm")
  runtime.eventState:setFlag(FieldScriptSymbols.flagsByName.FLAG_SYS_FLYPOINT_PALLET)
  runtime.eventState:setFlag(FieldScriptSymbols.flagsByName.FLAG_SYS_FLYPOINT_INDIGO)
  local mons = assert(runtime.monService, "the field owns the live party")
  Assert.isTrue(
    mons:giveMon({ species = "PIDGEY", level = 5, heldItem = "NONE", form = 0, location = 7 }),
    "Fly user joins the party"
  )
  local bag = assert(runtime.bagService, "the field owns the live bag")
  Assert.isTrue(bag:add("HM02", 1), "Fly setup stocks the native HM")
  local actions = PartyActions.new({ mons = mons, bag = bag })
  local taught = actions:commit({
    kind = "teach_move",
    slot = 0,
    partyRevision = mons:partyRevision(),
    bagRevision = bag:revision(),
    item = "HM02",
  })
  Assert.equal(taught.kind, "changed", "the source Fly user learns from HM02")
  assert(runtime.pokegearState, "the field owns Pokegear state"):setPreference("mapUnlockLevel", 2)
end

local childView, drainOpen, focusSlot, activateMenuRow

local function chooseFly(game)
  local runtime = game.runtime
  runtime:bindPartyIconPreparation(function(_)
    return true
  end, function() end)
  local flow = assert(runtime.pokemonMenu, "the production Pokemon menu exists"):makePartyFlow()
  drainOpen(flow)
  focusSlot(flow, 0)
  activateMenuRow(flow, function(row)
    return row.move == "FLY"
  end, "Fly")
  local terminal = flow:takeResult()
  if terminal == nil then
    local status = flow:status()
    local child = status.child
    error(
      "Fly produced no party result (page="
        .. tostring(status.page)
        .. ", open="
        .. tostring(status.open)
        .. ", childPhase="
        .. tostring(child and child.phase)
        .. ", cursor="
        .. tostring(child and child.cursorNode)
        .. ", menuIndex="
        .. tostring(child and child.menuIndex)
        .. ", menuPress="
        .. tostring(child and child.menuPress)
        .. ")",
      0
    )
  end
  Assert.equal(terminal.kind, "field_action", "Fly emits the typed field action")
  runtime:_admitFieldAction(terminal.actionId, terminal.request)
  flow:dispose()
end

childView = function(flow)
  local status = flow:status()
  Assert.isTrue(status.open, "the party flow stays open")
  return assert(status.child, "the party flow holds a live child")
end

drainOpen = function(flow)
  for _ = 1, 30 do
    local child = flow:status().child
    if child ~= nil and child.phase == "interactive" then
      break
    end
    flow:updateFixed({})
  end
  flow:updateFixed({})
  flow:updateFixed({})
end

focusSlot = function(flow, slot)
  for _ = 1, 30 do
    if childView(flow).cursorNode ~= nil then
      break
    end
    flow:updateFixed({})
  end
  Assert.equal(childView(flow).cursorNode, slot, "the Fly user occupies the selected party slot")
end

activateMenuRow = function(flow, match, what)
  flow:updateFixed({ { type = "confirm" } })
  local seen = {}
  local escapes = { "right", "left", "up" }
  local escapeNext = 1
  for _ = 1, 40 do
    local child = childView(flow)
    local menu = assert(child.menu, "slot confirm must open the action menu")
    local index = assert(child.menuIndex, "the open menu carries focus")
    local row = menu[index]
    if row ~= nil and match(row) then
      flow:updateFixed({})
      flow:updateFixed({})
      child = childView(flow)
      menu = assert(child.menu, "the settled action menu remains open")
      index = assert(child.menuIndex, "the settled menu retains focus")
      Assert.isTrue(match(menu[index]), "the action menu retains the intended row before activation")
      flow:updateFixed({ { type = "confirm" } })
      for _ = 1, 20 do
        local status = flow:status()
        if not status.open then
          return
        end
        flow:updateFixed({})
      end
      if not flow:status().open then
        return
      end
      local status = flow:status()
      local activeChild = status.child
      error(
        "the gated menu entry never dispatched "
          .. what
          .. " (state="
          .. tostring(activeChild and activeChild.state)
          .. ", index="
          .. tostring(activeChild and activeChild.menuIndex)
          .. ", press="
          .. tostring(activeChild and activeChild.menuPress)
          .. ", message="
          .. tostring(activeChild and activeChild.message)
          .. ")",
        0
      )
    end
    local direction = "down"
    if seen[index] then
      direction = escapes[escapeNext]
      escapeNext = escapeNext % #escapes + 1
    end
    seen[index] = true
    flow:updateFixed({ { type = "navigate", direction = direction } })
  end
  error("the action menu never offered " .. what, 0)
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
local LEAGUE_ENTRANCE = "MAP_POKEMON_LEAGUE_ENTRANCE"
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

local function settleLeagueEntry(game)
  local scheduler = game.runtime.scripts.scheduler
  local skippedTutorial = false
  for _ = 1, 1200 do
    local snapshot = game:snapshot()
    local foreground = scheduler:foregroundEnvironmentId()
    local introInstanceId
    for _, instance in ipairs(scheduler:instances()) do
      if instance.environmentId == foreground and instance.scriptId == "common.teala_first_intro" then
        introInstanceId = instance.instanceId
      end
    end
    local tutorialMenu
    if not skippedTutorial and introInstanceId ~= nil then
      for _, task in ipairs(scheduler:tasks()) do
        if task.ownerInstanceId == introInstanceId and task.taskType == "menu" and task.status == "active" then
          tutorialMenu = task
          break
        end
      end
    end
    if tutorialMenu ~= nil then
      if game.runtime.menuHost:isModal() then
        game.runtime:press("south")
        game:step()
        game.runtime:release("south")
        PokegearJourneyFixture.pressActionEdge(game)
        skippedTutorial = true
      else
        game:step()
      end
    elseif game.runtime.scripts.dialogueHost:yesNoPresentation() ~= nil or snapshot.dialogue.modal then
      PokegearJourneyFixture.pressActionEdge(game)
    elseif game.runtime.session.mapEntryStage == nil and foreground == nil and not snapshot.fieldLocked then
      return
    else
      game:step()
    end
  end
  error("the authored League entry prompt never settled", 0)
end

---@param game table
---@param sourceMapId integer
---@param destinationMapId integer
---@param destinationMapSymbol string
---@param classifyFromPlayer boolean?
---@return { x: integer, y: integer }? source exterior cell observed after commit
---@return { x: integer, y: integer } cell occupied by the production player before the transition
local function takeNativeTransitionTo(game, sourceMapId, destinationMapId, destinationMapSymbol)
  local sourceMap = assert(game.runtime.runtimeMap, "the production source map is active")
  Assert.equal(sourceMap.mapId, sourceMapId, "the expected source map is active")
  local player = assert(game.runtime.player, "the production field player is active")
  local warps = assert(sourceMap.fieldData.events.warps, "the source map publishes native warp records")
  local warp = nil
  for _, candidate in ipairs(warps) do
    if candidate.destinationMapId == destinationMapId then
      warp = candidate
      break
    end
  end
  warp = assert(warp, "the source map has a native warp to map " .. tostring(destinationMapId))
  local trigger = { warp = warp }
  local facing = player.facing
  local sourceCell = {
    x = math.floor(player.fieldX / 32),
    y = math.floor(player.fieldZ / 32),
  }

  -- The selected route warp stays source-authored. FieldTransition owns
  -- destination resolution, preparation, and the world-swap commit.
  game.runtime.transition:start(sourceMap, trigger, facing)
  game:waitForTransition()
  Assert.equal(game:snapshot().mapSymbol, destinationMapSymbol, "the native warp commits its expected destination")
  local settle = destinationMapSymbol == LEAGUE_WIFI_ROOM and settleLeagueEntry or PokegearJourneyFixture.settleArrival
  local settled, settleErr = pcall(settle, game, destinationMapSymbol)
  if not settled then
    local snapshot = game:snapshot()
    local stage = game.runtime.session.mapEntryStage
    local foreground = game.runtime.scripts.scheduler:foregroundEnvironmentId()
    local activeScripts = {}
    local instanceIds = {}
    local activeScriptState = {}
    for _, instance in ipairs(game.runtime.scripts.scheduler:instances()) do
      if instance.environmentId == foreground then
        instanceIds[instance.instanceId] = true
        local frame = instance:topFrame()
        activeScripts[#activeScripts + 1] = table.concat({
          tostring(instance.scriptId),
          tostring(instance.status),
          tostring(instance.endReason),
        }, ":")
        activeScriptState[#activeScriptState + 1] = table.concat({
          "node=" .. tostring(frame and frame.nodeId),
          "yield=" .. tostring(instance.yieldReason),
          "waitingTask=" .. tostring(instance.waitingTaskId),
        }, ",")
      end
    end
    local activeTasks = {}
    for _, record in ipairs(game:recordsNamed("script.task_started")) do
      local payload = record.payload or {}
      if instanceIds[payload.instanceId] then
        activeTasks[#activeTasks + 1] = tostring(payload.taskType)
      end
    end
    error(
      "settling arrival at "
        .. destinationMapSymbol
        .. " failed while active on "
        .. tostring(game:snapshot().mapSymbol)
        .. " (stage="
        .. tostring(stage and stage.kind)
        .. ", fieldLocked="
        .. tostring(snapshot.fieldLocked)
        .. ", modal="
        .. tostring(snapshot.dialogue.modal)
        .. ", foreground="
        .. tostring(foreground)
        .. ", activeScripts="
        .. table.concat(activeScripts, "|")
        .. ", activeTasks="
        .. table.concat(activeTasks, "|")
        .. ", scriptState="
        .. table.concat(activeScriptState, "|")
        .. ", runtimeError="
        .. tostring(game.runtime.errorText)
        .. ")"
        .. ": "
        .. tostring(settleErr),
      0
    )
  end
  Assert.equal(game:snapshot().mapSymbol, destinationMapSymbol, "settling entry keeps the expected route map active")

  local lastExterior = game.runtime.fieldTravel:lastExterior()
  if lastExterior ~= nil then
    return { x = lastExterior.x, y = lastExterior.y }, sourceCell
  end
  return nil, sourceCell
end

local function flyToIndigo(game)
  local flyRequest = game.runtime.pokegear.fieldMoveFlyRequest()
  Assert.equal(flyRequest.mapContext.fieldMap, "MAP_PALLET", "Fly admission captures Pallet as its source map")
  Assert.isTrue(
    table.concat(flyRequest.destinations, ","):find("hg.flypoint.indigo-plateau", 1, true) ~= nil,
    "the live source flypoint facts permit the prepared Indigo destination"
  )
  chooseFly(game)
  local host = assert(game.runtime.pokegear.scriptHost, "the composed field owns its Fly selector")
  game:advanceUntil("the Fly selector opens", function()
    return host:activeHandle() ~= nil
  end, 120)
  local handle = assert(host:activeHandle(), "the Fly selector owns its handle")
  local assets = assert(game.runtime.pokegearManifest, "the Fly selector borrows compiled assets")
  local regionMap = assert(assets.catalog.regionMap, "the compiled region map is available")
  local flypoints = assert(regionMap.flypoints, "the compiled region map has flypoints")
  local indigo = nil
  for _, flypoint in ipairs(flypoints) do
    if flypoint.warpMapId == 58 then
      indigo = flypoint
      break
    end
  end
  indigo = assert(indigo, "the compiled source catalog identifies Indigo Plateau's flypoint")
  local indigoKey = nil
  for _, location in ipairs(assets.catalog.locations) do
    if location.fieldMap == "MAP_INDIGO_PLATEAU" then
      indigoKey = location.flypoint
      break
    end
  end
  Assert.equal(indigoKey, "hg.flypoint.indigo-plateau", "the compiled location identifies Indigo's semantic key")
  local targetX, targetY = indigo.x, indigo.y + 2
  local current = nil
  for _, location in ipairs(regionMap.locations) do
    if location.mapId == 49 then
      current = location
      break
    end
  end
  current = assert(current, "the compiled region map identifies Pallet")
  local currentX, currentY = current.x, current.y
  local function move(direction, count)
    for _ = 1, count do
      host:step(handle, { { type = "navigate", direction = direction } })
      game:step()
      game:step()
    end
  end
  move(targetX < currentX and "left" or "right", math.abs(targetX - currentX))
  move(targetY < currentY and "up" or "down", math.abs(targetY - currentY))
  host:step(handle, { { type = "confirm" } })
  host:step(handle, { { type = "confirm" } })
  local choice = assert(host:result(handle), "the Fly selector publishes a terminal choice")
  Assert.equal(choice.kind, "destination", "the production selector confirms a destination")
  Assert.equal(choice.flypointKey, indigoKey, "the Fly choice names Indigo Plateau's semantic flypoint")
  for _ = 1, 1200 do
    if game:snapshot().mapSymbol == "MAP_INDIGO_PLATEAU" and game:snapshot().player.motion == "idle" then
      break
    end
    game:step()
  end
  local flySnapshot = game:snapshot()
  local scriptInstances = {}
  for _, instance in ipairs(game.runtime.scripts.scheduler:instances()) do
    scriptInstances[#scriptInstances + 1] =
      tostring(instance.scriptId) .. ":" .. tostring(instance.status) .. ":" .. tostring(instance.endReason)
  end
  local taskResults = {}
  for _, record in ipairs(game:recordsNamed("script.task_ended")) do
    local payload = record.payload or {}
    local result = payload.result or {}
    taskResults[#taskResults + 1] = table.concat({
      tostring(payload.taskType),
      tostring(result.kind),
      tostring(result.error),
    }, ":")
  end
  Assert.equal(
    flySnapshot.mapSymbol,
    "MAP_INDIGO_PLATEAU",
    "native Fly commits Indigo Plateau's source destination (motion="
      .. tostring(flySnapshot.player.motion)
      .. ", locked="
      .. tostring(flySnapshot.fieldLocked)
      .. ", foreground="
      .. tostring(flySnapshot.foregroundScript)
      .. ", transition="
      .. tostring(flySnapshot.transition.phase)
      .. ", fieldMoveBusy="
      .. tostring(game.runtime.pokemonMenu.fieldMoves:isBusy())
      .. ", scripts="
      .. table.concat(scriptInstances, "|")
      .. ", tasks="
      .. table.concat(taskResults, "|")
      .. ")"
  )
  local settled, settleErr = pcall(PokegearJourneyFixture.settleArrival, game, "MAP_INDIGO_PLATEAU")
  if not settled then
    error("settling the Indigo Plateau Fly arrival failed: " .. tostring(settleErr), 0)
  end
  game:advanceUntil("the Fly task releases its scheduler claim", function()
    return game.runtime.scripts.scheduler:foregroundEnvironmentId() == nil
  end, 1200)
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
      if map == "MAP_INDIGO_PLATEAU" then
        -- The native Indigo spawn is field cell (912, 201); this legacy
        -- harness location is map-local to MAP_INDIGO_PLATEAU's origin.
        save.location.fieldX = 16
        save.location.fieldZ = 9
        save.location.facing = "north"
      end
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
    OpeningLifecycle.seedNewBarkWestExitScene(game)
    OpeningLifecycle.settleNewBarkFriendScene(game)
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

-- A source-qualified outdoor transition survives the intervening native
-- route to the zero-header room and remains available after field save/restore.
function T.tests.zero_header_map_keeps_the_committed_exterior_after_save_restore()
  local defaultGameFactory = AcceptanceHarness.new().gameFactory
  local spawn = FieldMoveSources.SPAWN_DESTINATIONS.SPAWN_PALLET
  local spawnCache = CacheFs.forVersion(AcceptanceHarness.defaultVersion())
  local palletScene = assert(
    spawnCache:loadLua(MapAssetCache.mapDir(49) .. "/scene.lua"),
    "the generated Pallet scene provides the runtime coordinate origin"
  )
  local palletOrigin = assert(palletScene.matrix, "the generated Pallet scene publishes its matrix origin")
  local harness = AcceptanceHarness.new({
    gameFactory = function(versionId, map)
      local save = defaultGameFactory(versionId, map)
      if map == "MAP_PALLET" then
        save.location.fieldX = spawn.fieldX - palletOrigin.worldOriginX
        save.location.fieldZ = spawn.fieldZ - palletOrigin.worldOriginZ
        save.location.facing = "south"
      end
      return save
    end,
  })
  local game = harness:boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = "MAP_PALLET",
    save = "fresh",
    fieldOptions = { recordingScriptHosts = true },
  })
  local ok, err = xpcall(function()
    game:waitForFieldEntry()
    local settled, settleErr = pcall(PokegearJourneyFixture.settleArrival, game, "MAP_PALLET")
    if not settled then
      error(
        "settling Pallet entry failed while active on "
          .. tostring(game:snapshot().mapSymbol)
          .. ": "
          .. tostring(settleErr),
        0
      )
    end
    Assert.equal(game:snapshot().mapSymbol, "MAP_PALLET", "the test starts on the source-defined Pallet spawn")
    Assert.equal(game:snapshot().player.fieldX, spawn.fieldX, "the runtime origin restores the source Pallet X")
    Assert.equal(game:snapshot().player.fieldZ, spawn.fieldZ, "the runtime origin restores the source Pallet Z")
    prepareFlyParty(game)
    local expectedCell, spawnCell = takeNativeTransitionTo(game, 49, 503, "MAP_PALLET_TOWN_REDS_HOUSE_1F")
    Assert.notNil(
      expectedCell,
      "the committed Pallet to Red's House swap publishes its source exterior"
    )
    Assert.deepEqual(expectedCell, spawnCell, "the published source cell matches the source-defined Pallet spawn")
    Assert.deepEqual(
      game.runtime.fieldTravel:lastExterior(),
      expectedCell,
      "the committed outdoors-to-building transition stores its source world cell"
    )
    Assert.deepEqual(
      takeNativeTransitionTo(game, 503, 49, "MAP_PALLET"),
      expectedCell,
      "the native house exit preserves the committed Pallet exterior"
    )
    flyToIndigo(game)
    Assert.deepEqual(
      takeNativeTransitionTo(game, 58, 300, LEAGUE_ENTRANCE),
      expectedCell,
      "the source-unqualified Indigo transition preserves Pallet's committed exterior"
    )
    Assert.deepEqual(
      takeNativeTransitionTo(game, 300, 539, LEAGUE_WIFI_ROOM),
      expectedCell,
      "the League entrance keeps the committed exterior into the zero-header room"
    )
    Assert.equal(game:snapshot().mapSymbol, LEAGUE_WIFI_ROOM, "the native warp route enters the zero-header room")
    prepareMapCard(game)

    local beforeSave = openProductionMap(game)
    local expectedMapCell = { x = expectedCell.x, y = expectedCell.y + 2 }
    Assert.deepEqual(beforeSave.playerCell, expectedMapCell, "the room Map applies its source row offset to the committed exterior")
    Assert.deepEqual(beforeSave.cell, expectedMapCell, "the selected room Map cell matches the offset exterior marker")
    PokegearJourneyFixture.closeGearThroughMenu(game)

    game:setWorldState({ flag = FieldScriptSymbols.flagsByName.FLAG_GOT_SAVE_BUTTON })
    local saveId = game.runtime.saveId
    local captured = assert(game.runtime:captureGameSave(), "the field save owner captures a stable indoor save")
    local capturedTravel = assert(captured.fieldTravel, "the production save carries the field travel record")
    Assert.deepEqual(capturedTravel.lastExterior, expectedCell, "the real field save owns the committed exterior cell")
    PokegearJourneyFixture.saveAndReload(game)
    Assert.equal(game:snapshot().mapSymbol, LEAGUE_WIFI_ROOM, "restore continues in the same zero-header room")
    local persisted = assert(game.runtime.saveStore:load(saveId), "the actual save store reloads the production record")
    local persistedTravel = assert(persisted.fieldTravel, "the stored record carries field travel state")
    Assert.deepEqual(persistedTravel.lastExterior, expectedCell, "the save store retains the committed exterior")
    Assert.deepEqual(
      game.runtime.fieldTravel:lastExterior(),
      expectedCell,
      "the restored field travel state retains the committed exterior"
    )
    prepareMapCard(game)

    local afterRestore = openProductionMap(game)
    Assert.deepEqual(afterRestore.playerCell, expectedMapCell, "the restored Map keeps the offset exterior marker")
    Assert.deepEqual(afterRestore.cell, expectedMapCell, "the restored selection stays on the offset exterior cell")
    Assert.equal(game:renderAttempts(), 0, "the save/restore location journey stops before GPU rendering")
    PokegearJourneyFixture.closeGearThroughMenu(game)
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

return T
