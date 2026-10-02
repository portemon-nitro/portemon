-- A production save-editor transaction must resume through the retail field runtime.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local Fixture = require("app.tests.support.SaveEditorAcceptanceFixture")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local FieldMapDataCache = require("libs.assets.src.field.FieldMapDataCache")
local FieldEventResolver = require("libs.hgss.src.interaction.FieldEventResolver")
local DisplayContext = require("libs.ui.src.DisplayContext")
local LayoutGeometry = require("libs.ui.src.LayoutGeometry")
local SaveFs = require("libs.storage.src.SaveFs")

local T = {
  metadata = {
    capabilities = { "rom_dump" },
    derivedAssets = {
      "field-planning",
      "field-runtime",
      "audio-bank:702",
      "audio-bank:709",
      "map-data:7",
      "map-data:48",
      "map-data:34",
      "map-data:47",
      "map-data:60",
      "map-data:67",
      "map-data:33",
      "map-data:63",
      "map:7",
      "map:33",
      "map:63",
      "audio-bank:730",
    },
    tags = { "save-editor", "location", "production" },
  },
  tests = {},
}

local function copy(value)
  if type(value) ~= "table" then
    return value
  end
  local result = {}
  for key, item in pairs(value) do
    result[key] = copy(item)
  end
  return result
end

local function readyHost()
  return {
    requestField = function()
      return true
    end,
    requestLogicalField = function()
      return true
    end,
    requestCell = function()
      return true
    end,
    ensureField = function()
      return true
    end,
    ensureLogicalField = function()
      return true
    end,
    ensureCell = function()
      return true
    end,
  }
end

local function withoutRendering(fn)
  local graphics = love.graphics
  local names = { "newShader", "newCanvas", "newImage", "newMesh", "newQuad", "draw", "setCanvas" }
  local originals, attempts = {}, 0
  for _, name in ipairs(names) do
    originals[name] = graphics[name]
    graphics[name] = function()
      attempts = attempts + 1
      error("save editor acceptance attempted love.graphics." .. name)
    end
  end
  local ok, result = xpcall(fn, debug.traceback)
  for _, name in ipairs(names) do
    graphics[name] = originals[name]
  end
  if not ok then
    error(result, 0)
  end
  Assert.equal(attempts, 0, "the editor acceptance path stops before GPU rendering")
end

local function locationServiceModule()
  local loaded, Service = pcall(require, "app.src.saveeditor.SaveEditorLocationService")
  Assert.isTrue(loaded, "the editor must resolve a source-safe destination through its headless location owner")
  return Service
end

local function openComposition(fixture, host)
  local Composition = require("app.src.saveeditor.SaveEditorComposition")
  local originalGlobal = SaveFs.global
  SaveFs.global = function(backend)
    Assert.isNil(backend, "the editor must use the isolated acceptance save backend")
    return fixture.saveFs
  end
  local ok, graphOrError = xpcall(function()
    return Composition.open({
      versionId = fixture.versionId,
      saveId = fixture.saveId,
      repositoryRoot = love.filesystem.getSourceBaseDirectory(),
      derivedAssets = host,
    })
  end, debug.traceback)
  SaveFs.global = originalGlobal
  if not ok then
    error(graphOrError, 0)
  end
  return graphOrError
end

local function resolvedHousePlacement(graph, fixture, host)
  local LocationService = locationServiceModule()
  local houseMapId = graph.world.bySymbol.MAP_NEW_BARK_PLAYER_HOUSE_1F
  Assert.notNil(houseMapId, "the loaded supported version contains the symbolic Player House map")
  local worldIndex = assert(graph.world.byId[houseMapId])
  local worldRecord = assert(graph.world.maps[worldIndex])
  local fieldData = assert(graph.cacheFs:loadLua(FieldMapDataCache.fieldPath(houseMapId)))
  local service = LocationService.new({
    cacheFs = graph.cacheFs,
    world = graph.world,
    derivedAssets = host,
    savedObjects = copy(fixture.initial.world.objects),
  })
  local graphics = love.graphics
  local originals, trapped = {}, 0
  local names = { "newShader", "newCanvas", "newImage", "newMesh", "newQuad", "draw", "setCanvas" }
  for _, name in ipairs(names) do
    originals[name] = graphics[name]
    graphics[name] = function()
      trapped = trapped + 1
      error("headless location preparation attempted love.graphics." .. name)
    end
  end
  local ok, placement = xpcall(function()
    service:openMap(houseMapId)
    service:setViewport(4, 5, 1, 1)
    for _ = 1, 8 do
      service:update()
      local view = service:snapshot()
      if view.status.state == "ready" then
        local resolved = service:resolve(houseMapId, 4, 5, view.generation)
        Assert.notNil(resolved, "the source-defined Player House spawn tile resolves as an ordinary destination")
        return resolved
      end
    end
    local view = service:snapshot()
    error(
      "the production location owner did not prepare the known Player House spawn tile: "
        .. tostring(view.status.state)
        .. " / "
        .. tostring(view.status.reason),
      2
    )
  end, debug.traceback)
  for _, name in ipairs(names) do
    graphics[name] = originals[name]
  end
  if not ok then
    error(placement, 0)
  end
  Assert.equal(trapped, 0, "headless location preparation never requests GPU rendering")

  local function unavailableAtSourceEvent(mapId, event, reason, label)
    local fieldX, fieldZ = event.x, event.z
    service:openMap(mapId)
    service:setViewport(fieldX, fieldZ, 1, 1)
    local view
    for _ = 1, 8 do
      service:update()
      view = service:snapshot()
      if view.status.state == "ready" then
        break
      end
    end
    Assert.equal(
      assert(view).status.state,
      "ready",
      label .. " uses prepared production map data: " .. tostring(view.status.reason)
    )
    local resolved, resolution = service:resolve(mapId, fieldX, fieldZ, view.generation)
    Assert.isNil(resolved, label .. " cannot be selected as a save destination")
    Assert.equal(resolution.state, "unavailable", label .. " is classified as unavailable")
    Assert.equal(resolution.reason, reason, label .. " retains its source-event rejection reason")
  end

  if ok then
    local warp = assert(fieldData.events.warps[1], "Player House generated field data contains a source warp")
    unavailableAtSourceEvent(houseMapId, warp, "warp", "source warp")
    local coordinateMapId = assert(graph.world.bySymbol.MAP_BURNED_TOWER_1F)
    local coordinateFieldData = assert(graph.cacheFs:loadLua(FieldMapDataCache.fieldPath(coordinateMapId)))
    local coordinate = assert(
      coordinateFieldData.events.coordinates[1],
      "Burned Tower generated field data contains a source coordinate rectangle"
    )
    local oracleIntent = FieldEventResolver.resolveCoordinate(
      { mapId = coordinateMapId, fieldData = coordinateFieldData },
      { fieldX = coordinate.x, fieldZ = coordinate.z, facing = "south" },
      {
        getVar = function(_, variableId)
          Assert.equal(variableId, coordinate.variableId)
          return coordinate.requiredValue
        end,
      }
    )
    Assert.notNil(oracleIntent, "the retail field resolver recognizes the exact generated coordinate event")
    Assert.equal(oracleIntent.coordinate.event, coordinate, "the oracle identifies the source event directly")
    unavailableAtSourceEvent(
      coordinateMapId,
      coordinate,
      "coordinate_trigger",
      "source coordinate rectangle"
    )
    local actorMapId = assert(graph.world.bySymbol.MAP_ROUTE_29)
    local actorMapRecord = assert(graph.world.maps[assert(graph.world.byId[actorMapId])])
    Assert.isTrue(
      actorMapRecord.worldOriginX ~= 0 or actorMapRecord.worldOriginZ ~= 0,
      "the ROM hazard is checked on a map with a nonzero world origin"
    )
    local actorFieldData = assert(graph.cacheFs:loadLua(FieldMapDataCache.fieldPath(actorMapId)))
    local object = assert(
      actorFieldData.events.objects[1],
      "Route 29 generated field data contains a source actor event"
    )
    unavailableAtSourceEvent(actorMapId, object, "possible_actor", "source actor")
  end

  return service, placement
end

local function resolvedOutdoorPlacement(graph, service)
  local mapId = assert(graph.world.bySymbol.MAP_ROUTE_29)
  local origin = assert(graph.world.maps[assert(graph.world.byId[mapId])])
  local viewportX, viewportZ = origin.worldOriginX + 16, origin.worldOriginZ + 16
  service:openMap(mapId)
  service:setViewport(viewportX, viewportZ, 1, 1)
  local view
  for _ = 1, 8 do
    service:update()
    view = service:snapshot()
    if view.status.state == "ready" then
      break
    end
  end
  Assert.equal(assert(view).status.state, "ready", "the route source map prepares outdoor coverage")

  local viewportAnchorX = math.floor(viewportX / 32)
  local destinationX, destinationZ = 625, 400
  local placement, resolution = service:resolve(mapId, destinationX, destinationZ, view.generation)
  Assert.equal(resolution.state, "ready", "the known represented Route 29 destination resolves")
  Assert.notNil(placement)
  Assert.equal(math.floor(placement.fieldX / 32), viewportAnchorX)
  Assert.equal(placement.fieldZ, destinationZ)
  Assert.equal(placement.mapId, mapId)
  return placement
end

local function activateTarget(state, targetId)
  local view = state:view()
  local target = assert(view.layout.targets[targetId], "the product layout exposes " .. targetId)
  local targetRect = target.rect
  local pane
  for _, candidate in ipairs(assert(view.presentation).panes) do
    if candidate.interactive then
      pane = candidate
      break
    end
  end
  local interactivePane = assert(pane, "the editor publishes an interactive product pane")
  local hostX, hostY = LayoutGeometry.logicalToHost(
    interactivePane.placement,
    targetRect.x + targetRect.width / 2,
    targetRect.y + targetRect.height / 2
  )
  state:mousepressed(hostX, hostY, 1)
  state:mousereleased(hostX, hostY, 1)
end

local function editMon(session)
  local members = session:partySnapshot().members
  local draft, err
  if #members > 0 then
    draft, err = session:beginMonEdit(members[1].slot0)
  else
    draft, err = session:beginMonAdd("CHIKORITA", {
      location = 7,
      date = { year = 2000, month = 1, day = 1 },
    })
  end
  Assert.isNil(err, "the production mon service creates an isolated valid draft")
  draft = assert(draft)
  local record = draft:record()
  local friendship = record.friendship == 255 and 254 or record.friendship + 1
  Assert.isTrue(draft:setScalar("friendship", friendship), "a raw mon field is staged without changing derived values")
  local validated, validationError = draft:validate()
  Assert.isNil(validationError, "the chosen raw mon field remains valid under current production rules")
  Assert.notNil(validated)
  local result = session:applyMonDraft(draft)
  Assert.isTrue(result.ok, result.error and result.error.message)
end

function T.tests.combined_editor_save_reloads_and_resumes_at_the_resolved_destination()
  local fixture = Fixture.new()
  local host = readyHost()
  local graph, service, resume
  local ok, err = xpcall(function()
    graph = openComposition(fixture, host)
    local session = graph.session
    local original = copy(fixture.initial)
    local housePlacement
    service, housePlacement = resolvedHousePlacement(graph, fixture, host)
    local placement = resolvedOutdoorPlacement(graph, service)

    local locationBeforeBrowse = session:captureCandidate()
    Assert.deepEqual(locationBeforeBrowse, original, "loading and browsing a destination make no save edits")
    Assert.isTrue(type(session.setLocation) == "function", "a fully resolved tuple reaches the existing save transaction")

    local money = original.playerData.profile.money + 1
    Assert.isTrue(session:setMoney(money).ok)
    local flagName = "FLAG_HIDDENITEM_D42R0101_HYPER_POTION"
    local flagId = assert(FieldScriptSymbols.flagsByName[flagName])
    local flagValue = not (original.world.flags[flagId] == true)
    Assert.isTrue(session:setFlag(flagName, flagValue).ok)
    editMon(session)
    local oldQuantity = session:bagSnapshot("items")
    local quantity = 1
    for _, item in ipairs(oldQuantity) do
      if item.item == "POKE_BALL" then
        quantity = item.quantity + 1
        break
      end
    end
    Assert.isTrue(session:setBagQuantity("POKE_BALL", quantity).ok, "the authoritative bag owner accepts the staged quantity")
    Assert.isTrue(session:setLocation(placement).ok, "the resolved location tuple stages atomically")

    local expected = session:captureCandidate()
    Assert.equal(expected.playerData.profile.money, money)
    Assert.equal(expected.world.flags[flagId] == true, flagValue)
    Assert.deepEqual(expected.world.variables, original.world.variables, "location and flag edits preserve variables")
    Assert.deepEqual(expected.world.objects, original.world.objects, "location changes never reset field actors")
    Assert.deepEqual(expected.world.rng, original.world.rng, "location changes preserve world RNG")
    Assert.deepEqual(expected.fieldTravel, original.fieldTravel, "location changes preserve heal and travel state")
    Assert.equal(expected.facing, original.facing, "location changes preserve facing")
    Assert.deepEqual(expected.playerData.options, original.playerData.options)
    Assert.equal(expected.playTimeSeconds, original.playTimeSeconds)
    Assert.equal(expected.saveId, original.saveId)
    Assert.equal(expected.schema, original.schema)

    local backend = fixture.saveFs.backend
    local originalWrite = backend.write
    local failMainWrite = true
    backend.write = function(self, path, data)
      if failMainWrite and path:match("games/.*%.lua%.tmp$") then
        failMainWrite = false
        return false, "acceptance injected main-save failure"
      end
      return originalWrite(self, path, data)
    end
    local failed = session:save()
    Assert.isFalse(failed.ok, "a failed atomic write reports failure")
    Assert.deepEqual(assert(fixture.store:load(fixture.saveId)), original, "failed publication preserves the original save")
    Assert.deepEqual(session:captureCandidate(), expected, "failed publication retains the full staged transaction")
    backend.write = originalWrite
    Assert.isTrue(session:discard(), "Discard restores the complete published baseline after a failed combined save")
    Assert.deepEqual(session:captureCandidate(), original, "combined Discard restores every edited domain and location field")
    Assert.deepEqual(assert(fixture.store:load(fixture.saveId)), original, "Discard leaves the published canonical save unchanged")

    Assert.isTrue(session:setMoney(money).ok)
    Assert.isTrue(session:setFlag(flagName, flagValue).ok)
    editMon(session)
    Assert.isTrue(session:setBagQuantity("POKE_BALL", quantity).ok)
    Assert.isTrue(session:setLocation(placement).ok)
    Assert.deepEqual(session:captureCandidate(), expected, "the same combined edit can be staged again after Discard")
    Assert.isTrue(session:save().ok, "the complete combined edit saves after Discard")

    local published = assert(fixture.store:load(fixture.saveId))
    Assert.deepEqual(published, expected, "the real GameSaveStore reloads all five edited sections")
    Assert.equal(published.mapId, placement.mapId)
    Assert.equal(published.fieldX, placement.fieldX)
    Assert.equal(published.fieldZ, placement.fieldZ)
    Assert.equal(published.surfaceId, placement.surfaceId)
    Assert.equal(published.worldY, placement.worldY)
    Assert.equal(published.terrainDependencyHash, placement.terrainDependencyHash)

    service:dispose()
    graph = nil

    local resumeHarness = AcceptanceHarness.new({
      versions = { fixture.versionId },
      gameFactory = function()
        return copy(published)
      end,
    })
    resume = resumeHarness:boot({ versionId = fixture.versionId, save = "edited" })
    resume:waitForFieldReady()
    local runtime = resume.runtime
    Assert.equal(runtime.player.currentMap.mapId, placement.mapId, "FieldRuntime resumes on the edited map")
    Assert.equal(runtime.player.fieldX, placement.fieldX)
    Assert.equal(runtime.player.fieldZ, placement.fieldZ)
    Assert.equal(runtime.player.surfaceId, placement.surfaceId, "resume consumes the resolved surface identity")
    Assert.near(runtime.player.worldY, placement.worldY, 1e-6, "resume consumes the resolved terrain height")
    Assert.equal(runtime.player.facing, original.facing)
    local resumed = assert(runtime:captureGameSave())
    Assert.equal(resumed.playerData.profile.money, money)
    Assert.equal(resumed.world.flags[flagId] == true, flagValue)
    local objectSpriteVariable = assert(FieldScriptSymbols.variablesByName.VAR_OBJ_1)
    Assert.notNil(
      resumed.world.variables[objectSpriteVariable],
      "FieldRuntime initializes the source object's runtime-owned variable sprite on the Route 29 map"
    )
    local savedVariables = copy(original.world.variables)
    local runtimeVariables = copy(resumed.world.variables)
    savedVariables[objectSpriteVariable] = nil
    runtimeVariables[objectSpriteVariable] = nil
    Assert.deepEqual(runtimeVariables, savedVariables, "resume preserves every variable outside the runtime sprite default")
    Assert.deepEqual(resumed.world.rng, original.world.rng)
    Assert.isNil(
      runtime:_playerOccupantAt({
        fieldX = runtime.player.fieldX,
        fieldZ = runtime.player.fieldZ,
        surfaceId = runtime.player.surfaceId,
      }),
      "resuming at the edited tile does not create a phantom actor collision"
    )
    Assert.deepEqual(resumed.fieldTravel, original.fieldTravel)
    Assert.deepEqual(resumed.mons, published.mons)
    Assert.deepEqual(resumed.bag, published.bag)
    Assert.equal(resume:renderAttempts(), 0, "the real resume assertion stops before GPU rendering")

    session = nil
  end, debug.traceback)

  if resume then
    pcall(function()
      resume:close()
    end)
  end
  if service then
    pcall(function()
      service:dispose()
    end)
  end
  fixture.cleanup()
  if not ok then
    error(err, 0)
  end
end

function T.tests.one_save_intent_keeps_the_browser_and_publishes_after_destination_readiness()
  local fixture = Fixture.new()
  local baseHost = readyHost()
  local graph, service, state
  local originalGlobal = SaveFs.global
  SaveFs.global = function(backend)
    Assert.isNil(backend, "the editor uses the isolated acceptance save backend")
    return fixture.saveFs
  end
  local originalWrite = fixture.saveFs.backend.write
  local recordWrites = 0
  fixture.saveFs.backend.write = function(backend, path, data)
    if path:match("games/.*%.lua%.tmp$") then
      recordWrites = recordWrites + 1
    end
    return originalWrite(backend, path, data)
  end

  local destinationMapId = nil
  local destinationReady = false
  local controlledHost = {
    requestMilestone = function()
      return true
    end,
    requestField = function(mapId)
      return mapId ~= destinationMapId or destinationReady
    end,
    requestLogicalField = function(mapId)
      return mapId ~= destinationMapId or destinationReady
    end,
    requestCell = function()
      return true
    end,
    ensureField = function()
      return true
    end,
    ensureLogicalField = function()
      return true
    end,
    ensureCell = function()
      return true
    end,
  }
  local ok, err = xpcall(function()
    graph = openComposition(fixture, baseHost)
    local housePlacement
    service, housePlacement = resolvedHousePlacement(graph, fixture, baseHost)
    local placement = resolvedOutdoorPlacement(graph, service)
    destinationMapId = placement.mapId

    local State = require("app.src.saveeditor.SaveEditorState")
    local results = {}
    state = State.new({
      versionId = fixture.versionId,
      saveId = fixture.saveId,
      width = 640,
      height = 480,
      derivedAssets = controlledHost,
      repositoryRoot = love.filesystem.getSourceBaseDirectory(),
      displayContext = DisplayContext.new({}),
      onResult = function(result)
        results[#results + 1] = result
      end,
    })
    state:update(0)
    withoutRendering(function()
      Assert.equal(state:view().status, "ready", "the production editor opens against the real selected save")
      local browserMapId = assert(state:view().location.mapId)
      Assert.isTrue(state.session:setLocation(placement).ok, "the existing Session stages a resolved outdoor tuple")
      local expected = state.session:captureCandidate()
      state.controller:setSection("Player")
      activateTarget(state, "save")
      state:update(0)
      Assert.equal(recordWrites, 0, "the Save intent waits while destination data is pending")
      Assert.equal(
        state:view().location.mapId,
        browserMapId,
        "a pending destination check does not replace the user's browser map"
      )

      destinationReady = true
      for _ = 1, 8 do
        state:update(0)
        if recordWrites > 0 then
          break
        end
      end
      Assert.equal(recordWrites, 1, "one Save intent publishes exactly one save after readiness")
      Assert.deepEqual(assert(fixture.store:load(fixture.saveId)), expected, "the authorized tuple and edits publish")
      Assert.equal(state:view().location.mapId, browserMapId, "verification leaves the browser selection untouched")
      Assert.equal(#results, 0, "Save keeps the editor open")

      Assert.isTrue(state.session:setLocation(assert(housePlacement)).ok)
      destinationMapId = housePlacement.mapId
      destinationReady = false
      activateTarget(state, "save")
      state:update(0)
      Assert.notNil(state:view().locationSave, "the second Save owns one pending verification")
      Assert.equal(recordWrites, 1, "the replacement destination is still waiting")

      Assert.isTrue(state.session:setMoney(fixture.initialMoney + 2).ok, "a later edit changes the session revision")
      state:update(0)
      Assert.isNil(state:view().locationSave, "the stale verification is canceled after an edit")
      destinationReady = true
      for _ = 1, 8 do
        state:update(0)
      end
      Assert.equal(recordWrites, 1, "readiness cannot publish after the authorized revision changes")
    end)
  end, debug.traceback)
  if state then
    pcall(function()
      state:dispose()
    end)
  end
  if service then
    pcall(function()
      service:dispose()
    end)
  end
  fixture.saveFs.backend.write = originalWrite
  SaveFs.global = originalGlobal
  fixture.cleanup()
  if not ok then
    error(err, 0)
  end
end

return T
