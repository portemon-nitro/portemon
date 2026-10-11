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
local Experience = require("libs.mons.src.gen4.Experience")
local App = require("app.src.App")

local T = {
  metadata = {
    capabilities = { "rom_dump" },
    derivedAssets = {
      "field-planning",
      "field-runtime",
      "encounters:global",
      "trainers:global",
      "items:global",
      "bag:global",
      "party:global",
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
      "map-data:49",
      "map-data:9",
      "map-data:25",
      "map-data:93",
      "map-data:180",
      "map-data:117",
      "map:7",
      "map:33",
      "map:63",
      "map:49",
      "map:180",
      "map:117",
      "audio-bank:730",
      "field-cell:0-534",
      "field-cell:0-538",
      "field-cell:0-581",
      "field-cell:0-585",
      "field-cell:0-628",
      "field-cell:0-632",
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
    requestMilestone = function()
      return true
    end,
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
    for _ = 1, 5000 do
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
    for _ = 1, 5000 do
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
    unavailableAtSourceEvent(coordinateMapId, coordinate, "coordinate_trigger", "source coordinate rectangle")
    local actorMapId = assert(graph.world.bySymbol.MAP_ROUTE_29)
    local actorMapRecord = assert(graph.world.maps[assert(graph.world.byId[actorMapId])])
    Assert.isTrue(
      actorMapRecord.worldOriginX ~= 0 or actorMapRecord.worldOriginZ ~= 0,
      "the ROM hazard is checked on a map with a nonzero world origin"
    )
    local actorFieldData = assert(graph.cacheFs:loadLua(FieldMapDataCache.fieldPath(actorMapId)))
    local object =
      assert(actorFieldData.events.objects[1], "Route 29 generated field data contains a source actor event")
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
  for _ = 1, 5000 do
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

local function advanceEditorUntil(state, predicate, label)
  for _ = 1, 5000 do
    state:update(0)
    local view = state:view()
    if predicate(view) then
      return view
    end
  end
  error("the production editor did not reach " .. label, 2)
end

local function rectInside(inner, outer)
  return inner.x >= outer.x
    and inner.y >= outer.y
    and inner.x + inner.width <= outer.x + outer.width
    and inner.y + inner.height <= outer.y + outer.height
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
    Assert.isTrue(
      type(session.setLocation) == "function",
      "a fully resolved tuple reaches the existing save transaction"
    )

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
    Assert.isTrue(
      session:setBagQuantity("POKE_BALL", quantity).ok,
      "the authoritative bag owner accepts the staged quantity"
    )
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
    Assert.deepEqual(
      assert(fixture.store:load(fixture.saveId)),
      original,
      "failed publication preserves the original save"
    )
    Assert.deepEqual(session:captureCandidate(), expected, "failed publication retains the full staged transaction")
    backend.write = originalWrite
    Assert.isTrue(session:discard(), "Discard restores the complete published baseline after a failed combined save")
    Assert.deepEqual(
      session:captureCandidate(),
      original,
      "combined Discard restores every edited domain and location field"
    )
    Assert.deepEqual(
      assert(fixture.store:load(fixture.saveId)),
      original,
      "Discard leaves the published canonical save unchanged"
    )

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
    Assert.deepEqual(
      runtimeVariables,
      savedVariables,
      "resume preserves every variable outside the runtime sprite default"
    )
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

function T.tests.in_place_save_clears_the_cached_dirty_projection()
  local fixture = Fixture.new()
  local State = require("app.src.saveeditor.SaveEditorState")
  local originalGlobal = SaveFs.global
  local state
  SaveFs.global = function(backend)
    Assert.isNil(backend, "the editor uses the isolated acceptance save backend")
    return fixture.saveFs
  end

  local ok, err = xpcall(function()
    local function actionEnabled(layout, id)
      for _, action in ipairs(layout.actions) do
        if action.id == id then
          return action.enabled
        end
      end
      error("the product layout publishes the " .. id .. " action")
    end

    state = State.new({
      versionId = fixture.versionId,
      saveId = fixture.saveId,
      width = 640,
      height = 480,
      derivedAssets = readyHost(),
      repositoryRoot = love.filesystem.getSourceBaseDirectory(),
      displayContext = DisplayContext.new({}),
      onResult = function() end,
    })
    state:update(0)
    Assert.equal(state:view().status, "ready", "production Save Editor composition opens the isolated save")

    withoutRendering(function()
      local money = fixture.initialMoney + 1
      Assert.isTrue(state.session:setMoney(money).ok, "the production Session stages a money edit")
      Assert.isTrue(state:view().dirty, "the editor initially publishes the dirty projection")
      Assert.isTrue(actionEnabled(state:view().layout, "save"), "Save is enabled before publication")

      activateTarget(state, "save")

      Assert.equal(assert(fixture.store:load(fixture.saveId)).playerData.profile.money, money)
      local saved = state:view()
      Assert.isFalse(saved.dirty, "the in-place Save immediately clears the published dirty state")
      for _, section in ipairs({ "money", "frame", "flags", "party", "bag", "location" }) do
        Assert.isFalse(saved.dirtySections[section], "the saved " .. section .. " section is clean")
      end
      Assert.isFalse(actionEnabled(saved.layout, "save"), "Save is disabled after publication")
      Assert.isFalse(actionEnabled(saved.layout, "discard"), "Discard is disabled after publication")

      Assert.isTrue(state.session:setMoney(money + 1).ok, "a later edit stages normally")
      local edited = state:view()
      Assert.isTrue(edited.dirty, "a later revision invalidates the clean projection")
      Assert.isTrue(edited.dirtySections.money, "the later money edit is dirty")
      Assert.isTrue(actionEnabled(edited.layout, "save"), "Save is enabled for the later edit")
    end)
  end, debug.traceback)
  if state then
    pcall(function()
      state:dispose()
    end)
  end
  SaveFs.global = originalGlobal
  fixture.cleanup()
  if not ok then
    error(err, 0)
  end
end

function T.tests.relocated_save_publishes_synchronously_and_preserves_store_conflicts()
  local fixture = Fixture.new()
  local baseHost = readyHost()
  local graph, service, state
  local originalGlobal = SaveFs.global
  local originalQuit = love.event.quit
  local quitCalls = 0
  love.event.quit = function()
    quitCalls = quitCalls + 1
  end
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

  local ok, err = xpcall(function()
    graph = openComposition(fixture, baseHost)
    local housePlacement
    service, housePlacement = resolvedHousePlacement(graph, fixture, baseHost)
    local placement = resolvedOutdoorPlacement(graph, service)

    local State = require("app.src.saveeditor.SaveEditorState")
    local results = {}
    state = State.new({
      versionId = fixture.versionId,
      saveId = fixture.saveId,
      width = 640,
      height = 480,
      derivedAssets = baseHost,
      repositoryRoot = love.filesystem.getSourceBaseDirectory(),
      displayContext = DisplayContext.new({}),
      onResult = function(result)
        results[#results + 1] = result
      end,
    })
    state:update(0)
    withoutRendering(function()
      Assert.equal(state:view().status, "ready", "the production editor opens against the real selected save")
      local browserMapId = assert(
        state:view().locationNavigation.mapId,
        "the browser remembers the saved map while the section opens on the map list"
      )
      Assert.equal(browserMapId, state.session:snapshot().location.mapId, "the browser opens on the saved map")
      Assert.isTrue(state.session:setLocation(placement).ok, "the existing Session stages a resolved outdoor tuple")
      local expected = state.session:captureCandidate()
      state.controller:setSection("Player")
      activateTarget(state, "save")
      state:update(0)
      Assert.equal(recordWrites, 1, "one Save intent publishes exactly one save")
      Assert.deepEqual(assert(fixture.store:load(fixture.saveId)), expected, "the authorized tuple and edits publish")
      Assert.equal(
        state:view().locationNavigation.mapId,
        placement.mapId,
        "the direct save synchronizes the browser to the staged destination"
      )
      Assert.equal(#results, 0, "Save keeps the editor open")

      Assert.isTrue(state.session:setLocation(assert(housePlacement)).ok)
      state:requestClose("quit")
      local externalRecord = assert(fixture.store:load(fixture.saveId))
      externalRecord.playerData.profile.money = externalRecord.playerData.profile.money + 2
      fixture.store:save(externalRecord)
      Assert.equal(recordWrites, 2, "the external change publishes through the real store")
      activateTarget(state, "save")
      state:update(0)
      local failureView = state:view()
      Assert.equal(
        failureView.errorMessage,
        "This save changed after the editor opened. Reopen it before saving.",
        "the synchronous save exposes the structured Session conflict; got " .. tostring(failureView.errorMessage)
      )
      Assert.isTrue(failureView.dirty, "the rejected editor transaction remains dirty")
      Assert.equal(recordWrites, 2, "the rejected editor save does not publish over the external record")
      Assert.deepEqual(
        assert(fixture.store:load(fixture.saveId)),
        externalRecord,
        "the canonical record remains the external version"
      )
      Assert.equal(#results, 0, "a close-save conflict does not return to the main menu")
      Assert.equal(quitCalls, 0, "a close-save conflict does not request process exit")
      Assert.equal(state.closeRequest.reason, "quit", "the failed close retains its original intent")
      Assert.equal(state.closeRequest.phase, "confirm", "the close decision remains available after failure")
      Assert.equal(state.controller.modal, "leave", "the leave decision is restored after failure")
      activateTarget(state, "cancel")
      Assert.isTrue(state:view().dirty, "canceling the leave decision returns to the recoverable editor")
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
  love.event.quit = originalQuit
  fixture.cleanup()
  if not ok then
    error(err, 0)
  end
end

local function openBagEditor(fixture, host)
  local originalGlobal = SaveFs.global
  SaveFs.global = function(backend)
    Assert.isNil(backend, "the editor uses the isolated acceptance save backend")
    return fixture.saveFs
  end
  local State = require("app.src.saveeditor.SaveEditorState")
  local state
  local ok, stateError = xpcall(function()
    state = State.new({
      versionId = fixture.versionId,
      saveId = fixture.saveId,
      width = 800,
      height = 600,
      derivedAssets = host,
      repositoryRoot = love.filesystem.getSourceBaseDirectory(),
      displayContext = DisplayContext.new({}),
      onResult = function() end,
    })
    state:update(0)
    Assert.equal(state:view().status, "ready", "the production editor opens the real save")
  end, debug.traceback)
  SaveFs.global = originalGlobal
  if not ok then
    if state then
      pcall(function()
        state:dispose()
      end)
    end
    error(stateError, 0)
  end
  assert(state).controller:setSection("Bag")
  local catalogUpdates = 0
  while state._bagCatalogMetadata == nil do
    catalogUpdates = catalogUpdates + 1
    Assert.isTrue(catalogUpdates <= 5000, "the bounded Bag catalog reaches readiness")
    state:update(0)
  end
  local potionPocket = assert(state.dependencies.context.itemCatalog:item("POTION")).pocket
  assert(state).controller:selectBagPocket(potionPocket)
  local seeded = assert(state).session:setBagQuantity("POTION", 20)
  Assert.isTrue(seeded.ok, "the production Bag service seeds the acceptance item")
  Assert.isTrue(state.session:save().ok, "the fixture begins from a published save containing that item")
  return state
end

function T.tests.bag_item_actions_and_quantity_commit_are_staged_until_outer_save()
  local fixture = Fixture.new()
  local host = readyHost()
  local state
  local ok, err = xpcall(function()
    state = openBagEditor(fixture, host)
    withoutRendering(function()
      local initial = state.session:captureCandidate()
      local view = state:view()
      local row = assert(view.bagPageRows[1], "the production Bag page publishes a card to edit")
      local item = assert(view.bagRows[1], "the production Bag catalog supplies item limits")
      local originalQuantity = row.quantity
      local itemTarget = "bag:item:" .. row.item

      activateTarget(state, itemTarget)
      view = state:view()
      Assert.equal(view.modal, "bag-item", "activating a Bag card opens its item action modal")
      Assert.notNil(view.layout.targets["bag:quantity"], "the item modal offers Quantity")
      Assert.notNil(view.layout.targets["bag:remove"], "the item modal offers Remove")
      Assert.notNil(view.layout.targets.cancel, "the item modal offers Cancel")
      Assert.isNil(view.layout.targets.save, "the item modal owns focus without exposing the shell")

      activateTarget(state, "cancel")
      Assert.isNil(state:view().modal, "Cancel returns to the selected item")
      Assert.deepEqual(state.session:captureCandidate(), initial, "Cancel leaves the staged Bag unchanged")

      activateTarget(state, itemTarget)
      activateTarget(state, "bag:quantity")
      Assert.equal(state:view().valueEditor.kind, "number", "Quantity opens the shared number editor")
      local expected = math.max(1, originalQuantity)
      state:keypressed("up")
      state:keyreleased("up")
      expected = math.min(expected + 1, item.maxQuantity or 999)
      Assert.equal(state:view().valueEditor.value, expected, "Up changes transient quantity by one")
      state:keypressed("left")
      state:keyreleased("left")
      Assert.equal(state:view().valueEditor.value, expected, "Left selects the tens place")
      state:keypressed("up")
      state:keyreleased("up")
      expected = math.min(expected + 10, item.maxQuantity or 999)
      Assert.equal(state:view().valueEditor.value, expected, "Up adjusts the selected tens place")
      state:keypressed("escape")
      Assert.notNil(state:view().valueEditor, "Escape from a digit first keeps Quantity open")
      Assert.equal(state:view().focus, "cancel", "Escape focuses the visible Back action")
      state:keyreleased("escape")
      state:keypressed("escape")
      Assert.equal(
        state.session:bagSnapshot(view.bagPocket)[1].quantity,
        originalQuantity,
        "Cancel publishes no quantity"
      )

      activateTarget(state, "bag:quantity")
      state:keypressed("up")
      state:keyreleased("up")
      activateTarget(state, "confirm")
      Assert.equal(
        state.session:bagSnapshot(state.controller.bagPocket)[1].quantity,
        originalQuantity + 1,
        "Confirm stages the quantity in the editor session"
      )
      Assert.equal(
        assert(fixture.store:load(fixture.saveId)).bag.pockets[view.bagPocket][1].quantity,
        initial.bag.pockets[view.bagPocket][1].quantity,
        "the canonical save remains unchanged before outer Save"
      )
      Assert.isTrue(state.session:save().ok, "the existing outer Save publishes the staged Bag quantity")
      Assert.equal(
        assert(fixture.store:load(fixture.saveId)).bag.pockets[state.controller.bagPocket][1].quantity,
        originalQuantity + 1
      )
    end)
  end, debug.traceback)
  if state then
    pcall(function()
      state:dispose()
    end)
  end
  fixture.cleanup()
  if not ok then
    error(err, 0)
  end
end

function T.tests.bag_add_uses_search_then_quantity_and_returns_without_cancel_mutation()
  local fixture = Fixture.new()
  local host = readyHost()
  local state
  local ok, err = xpcall(function()
    state = openBagEditor(fixture, host)
    withoutRendering(function()
      local initial = state.session:captureCandidate()
      activateTarget(state, "bag:add")
      local choice = assert(state:view().valueEditor, "Add opens the searchable item picker")
      Assert.equal(choice.kind, "choice")
      Assert.isNil(choice.groups, "the Add picker has no groups")
      Assert.isNil(choice.clearTarget, "the Add picker has no visible Clear action")
      state:textinput("POTION")
      choice = state:view().valueEditor
      Assert.equal(choice.query, "POTION", "typing filters the Add catalog")
      local updates = 0
      while choice.pending do
        updates = updates + 1
        Assert.isTrue(updates <= 5000, "the bounded Add query publishes a result")
        state:update(0)
        choice = assert(state:view().valueEditor)
      end
      state:keypressed("return")
      local quantity = assert(state:view().valueEditor, "choosing an item opens quantity entry")
      local expected = assert(quantity.parsedValue or quantity.value) + 1
      state:keypressed("up")
      state:keyreleased("up")
      quantity = state:view().valueEditor
      Assert.equal(quantity.parsedValue or quantity.value, expected, "Up changes transient quantity by one")
      state:keypressed("left")
      state:keyreleased("left")
      Assert.equal(quantity.parsedValue or quantity.value, expected, "Left selects the tens place")
      state:keypressed("up")
      state:keyreleased("up")
      quantity = state:view().valueEditor
      Assert.equal(quantity.parsedValue or quantity.value, expected + 10, "Up adjusts the selected tens place")
      state:keypressed("escape")
      Assert.notNil(state:view().valueEditor, "Escape from a digit first keeps Add quantity open")
      Assert.equal(state:view().focus, "cancel", "Escape focuses the visible Back action")
      state:keyreleased("escape")
      state:keypressed("escape")
      Assert.deepEqual(state.session:captureCandidate(), initial, "canceling Add quantity leaves inventory unchanged")
      Assert.equal(state:view().focus, "bag:add", "cancel returns to the separate Add control")

      activateTarget(state, "bag:add")
      state:textinput("POTION")
      local updates = 0
      local choice = assert(state:view().valueEditor)
      while choice.pending do
        updates = updates + 1
        Assert.isTrue(updates <= 5000, "the bounded Add query publishes a result")
        state:update(0)
        choice = assert(state:view().valueEditor)
      end
      state:keypressed("return")
      activateTarget(state, "confirm")
      Assert.equal(
        state.session:bagSnapshot(state.controller.bagPocket)[1].quantity,
        21,
        "confirming Add stages the new quantity in the session"
      )
      Assert.equal(
        assert(fixture.store:load(fixture.saveId)).bag.pockets[state.controller.bagPocket][1].quantity,
        initial.bag.pockets[state.controller.bagPocket][1].quantity,
        "the canonical save remains unchanged before outer Save"
      )
    end)
  end, debug.traceback)
  if state then
    pcall(function()
      state:dispose()
    end)
  end
  fixture.cleanup()
  if not ok then
    error(err, 0)
  end
end

function T.tests.party_stats_edit_uses_number_modal_and_keeps_draft_staged()
  local fixture = Fixture.new()
  local host = readyHost()
  local state
  local originalGlobal = SaveFs.global
  SaveFs.global = function(backend)
    Assert.isNil(backend, "the editor uses the isolated acceptance save backend")
    return fixture.saveFs
  end
  local ok, err = xpcall(function()
    local State = require("app.src.saveeditor.SaveEditorState")
    state = State.new({
      versionId = fixture.versionId,
      saveId = fixture.saveId,
      width = 800,
      height = 600,
      derivedAssets = host,
      repositoryRoot = love.filesystem.getSourceBaseDirectory(),
      displayContext = DisplayContext.new({}),
      onResult = function() end,
    })
    state:update(0)
    Assert.equal(state:view().status, "ready", "the production editor opens the isolated save")

    local members = state.session:partySnapshot().members
    if #members == 0 then
      local draft, draftError = state.session:beginMonAdd("CHIKORITA", {
        location = 7,
        date = { year = 2000, month = 1, day = 1 },
      })
      Assert.isNil(draftError, "the production Mon service creates a valid Party fixture")
      local monCatalog = state.dependencies.context.monCatalog
      local species = monCatalog:species("CHIKORITA")
      local curve = monCatalog:growthCurve(species.growthCurve)
      Assert.isTrue(assert(draft):setScalar("experience", Experience.expFor(curve, 100)))
      Assert.isTrue(assert(draft):setMet("level", 100))
      local result = state.session:applyMonDraft(assert(draft))
      Assert.isTrue(result.ok, result.error and result.error.message)
      Assert.isTrue(state.session:save().ok, "the editor opens a published production Party record")
    end

    withoutRendering(function()
      state.controller:setSection("Party")
      activateTarget(state, "party:slot:0")
      local detail = state:view()
      Assert.isNil(detail.layout.targets["party:move-up"], "the simplified detail has no reorder-up action")
      Assert.isNil(detail.layout.targets["party:move-down"], "the simplified detail has no reorder-down action")
      for _, target in pairs(detail.layout.targets) do
        Assert.isFalse(target.label == "Party list", "the redundant Party list action is removed")
      end
      Assert.isNil(detail.layout.targets["party:edit"], "selecting a member edits immediately without an Edit action")
      Assert.isNil(detail.layout.targets["party:apply"], "the member editor has no local Apply action")
      Assert.isNil(detail.layout.targets["party:back"], "the member editor has no local Back action")
      Assert.isNil(detail.layout.targets["party:subpage:Stats"], "the member editor has no top subpage tab bar")
      Assert.notNil(detail.layout.targets["party:page:previous"], "the bottom pager exposes the previous page arrow")
      Assert.notNil(detail.layout.targets["party:page:next"], "the bottom pager exposes the next page arrow")
      Assert.equal(detail.partyTab, "Stats", "the selected member opens on the Stats page")

      local view = state:view()
      local stats = assert(view.partyStats, "Stats exposes one structured header plus IV/EV table")
      Assert.equal(#stats.rows, 6, "the table has exactly one row per stat")

      local initialPublished = assert(fixture.store:load(fixture.saveId))
      local row = assert(stats.rows[2], "Attack is the second Stats row")
      local originalIv = row.iv

      for _ = 1, 10 do
        if state:view().layout.targets["party:field:iv:attack"] ~= nil then
          break
        end
        state:wheelmoved(0, -1)
      end
      activateTarget(state, "party:field:iv:attack")
      Assert.equal(state:view().valueEditor.kind, "number", "an IV cell opens the shared number modal")
      for _ = 1, 31 do
        state:keypressed(originalIv < 31 and "up" or "down")
        state:keyreleased(originalIv < 31 and "up" or "down")
      end
      activateTarget(state, "confirm")

      local edited = originalIv < 31 and 31 or 0
      view = state:view()
      Assert.equal(assert(view.partyStats.rows[2]).iv, edited, "the table shows the edited raw IV")
      Assert.equal(
        state.session:partySnapshot().members[1].mon.ivs.attack,
        originalIv,
        "the live Party remains unchanged while the member draft is open"
      )
      Assert.deepEqual(
        assert(fixture.store:load(fixture.saveId)),
        initialPublished,
        "confirming the modal keeps the canonical save unchanged before staging"
      )

      activateTarget(state, "section:Player")
      Assert.equal(state.controller.section, "Player", "leaving the member switches section")
      local staged = state.session:captureCandidate()
      Assert.equal(
        staged.mons.party.mons[1].ivs.attack,
        edited,
        "leaving the member stages the raw IV through the member draft"
      )
      Assert.deepEqual(
        assert(fixture.store:load(fixture.saveId)),
        initialPublished,
        "the canonical save remains unchanged before the outer Save"
      )
      Assert.deepEqual(
        state.session:captureCandidate(),
        staged,
        "the staged draft survives the section switch without publishing"
      )
    end)
  end, debug.traceback)
  if state then
    pcall(function()
      state:dispose()
    end)
  end
  SaveFs.global = originalGlobal
  fixture.cleanup()
  if not ok then
    error(err, 0)
  end
end

function T.tests.real_map_browsing_suggests_a_valid_initial_cursor_without_changing_the_save()
  local fixture = Fixture.new()
  local State = require("app.src.saveeditor.SaveEditorState")
  local originalGlobal = SaveFs.global
  local state
  SaveFs.global = function(backend)
    Assert.isNil(backend, "the editor must use the isolated acceptance save backend")
    return fixture.saveFs
  end

  local ok, err = xpcall(function()
    state = State.new({
      versionId = fixture.versionId,
      saveId = fixture.saveId,
      width = 640,
      height = 480,
      derivedAssets = readyHost(),
      repositoryRoot = love.filesystem.getSourceBaseDirectory(),
      displayContext = DisplayContext.new({}),
      onResult = function() end,
    })
    state:update(0)

    withoutRendering(function()
      local openingView = state:view()
      Assert.equal(
        openingView.status,
        "ready",
        "production Save Editor composition opens the selected save: " .. tostring(openingView.errorMessage)
      )
      local originalLocation = copy(state.session:snapshot().location)
      local world = assert(state.dependencies.world)
      local selectedMaps = {
        assert(world.bySymbol.MAP_NEW_BARK_PLAYER_HOUSE_1F),
        assert(world.bySymbol.MAP_ROUTE_29),
      }

      local firstMap = assert(world.maps[assert(world.byId[selectedMaps[1]])])
      state.controller:chooseLocationMap(selectedMaps[1], firstMap.worldOriginX + 16, firstMap.worldOriginZ + 16)
      state:update(0)
      Assert.equal(
        assert(state:view().location).status.state,
        "pending",
        "the first browse request remains cancellable while its preparation is pending"
      )
      local replacementMap = assert(world.maps[assert(world.byId[selectedMaps[2]])])
      state.controller:chooseLocationMap(
        selectedMaps[2],
        replacementMap.worldOriginX + 16,
        replacementMap.worldOriginZ + 16
      )
      state:update(0)
      Assert.equal(
        assert(state:view().location).mapId,
        selectedMaps[2],
        "a replacement browse request owns the service after cancellation"
      )
      state.controller:chooseLocationMap(selectedMaps[1], firstMap.worldOriginX + 16, firstMap.worldOriginZ + 16)
      state:update(0)
      Assert.equal(
        assert(state:view().location).mapId,
        selectedMaps[1],
        "the canceled map can be re-entered without accepting a stale result"
      )

      local finalSuggestion
      for mapIndex, mapId in ipairs(selectedMaps) do
        state:_performDeferred({ kind = "location-map-select", mapId = mapId })
        state:update(0)

        local updates = 0
        local view = assert(state:view().location)
        local requestGeneration = assert(view.initialCursor).generation
        while view.status.state == "pending" do
          updates = updates + 1
          Assert.isTrue(updates <= 5000, "map preparation reaches a semantic ready or failure state")
          state:update(0)
          view = assert(state:view().location)
        end
        Assert.equal(
          view.status.state,
          "ready",
          "the selected source map is prepared: " .. tostring(view.status.reason)
        )

        local suggestion = view.initialCursor
        Assert.notNil(suggestion, "real map browsing publishes its suggested initial cursor")
        Assert.equal(
          suggestion.state,
          "ready",
          "the suggestion is selectable in " .. tostring(view.symbol) .. ": " .. tostring(suggestion.state)
        )
        Assert.equal(suggestion.mapId, mapId, "the suggestion remains bound to the selected map")
        Assert.equal(
          suggestion.generation,
          requestGeneration,
          "the suggestion remains bound to the active browse request"
        )
        local resolved, resolution =
          state.locationService:resolve(mapId, assert(suggestion.fieldX), assert(suggestion.fieldZ), view.generation)
        Assert.notNil(resolved, "the suggested coordinate passes the production placement classifier")
        Assert.equal(resolution.state, "ready", "the suggestion is fully prepared for explicit selection")
        if mapIndex == 1 then
          Assert.deepEqual(
            assert(state:view().locationNavigation.cursor),
            { fieldX = suggestion.fieldX, fieldZ = suggestion.fieldZ },
            "the production browse flow centers the cursor on its valid-tile suggestion"
          )
          local beforeMove = assert(state:view().locationNavigation.cursor)
          state:keypressed("right")
          state:keyreleased("right")
          Assert.equal(
            assert(state:view().locationNavigation.cursor).fieldX,
            beforeMove.fieldX + 1,
            "the centered grid remains responsive to movement"
          )
        elseif mapIndex == 2 then
          local navigation = assert(state:view().locationNavigation)
          local originalCenter = copy(navigation.center)
          local originalCursor = copy(navigation.cursor)
          local moves = 0
          while
            state:view().locationNavigation.center.fieldX == originalCenter.fieldX
            and state:view().locationNavigation.center.fieldZ == originalCenter.fieldZ
          do
            moves = moves + 1
            Assert.isTrue(moves <= 100, "manual grid navigation pans the real map viewport")
            state:keypressed("right")
            state:keyreleased("right")
            state:update(0)
          end
          local remembered = assert(state:view().locationNavigation)
          Assert.isFalse(
            remembered.cursor.fieldX == originalCursor.fieldX and remembered.cursor.fieldZ == originalCursor.fieldZ,
            "manual navigation changes the preview cursor"
          )
          Assert.isFalse(
            remembered.center.fieldX == originalCenter.fieldX and remembered.center.fieldZ == originalCenter.fieldZ,
            "manual navigation changes the preview viewport"
          )

          local previousGeneration = assert(state:view().location).generation
          state:_requestBack()
          state:update(0)
          Assert.isFalse(
            state:view().locationNavigation.page == "grid",
            "Back leaves coordinate selection before the same map is re-entered"
          )
          state:_performDeferred({ kind = "location-map-select", mapId = mapId })
          state:update(0)
          local reentered = assert(state:view().location)
          Assert.isFalse(
            reentered.generation == previousGeneration,
            "re-entering the same map starts a new C05 browse generation"
          )
          local reentryUpdates = 0
          while reentered.status.state == "pending" do
            reentryUpdates = reentryUpdates + 1
            Assert.isTrue(reentryUpdates <= 5000, "the re-entered map completes C05 preparation")
            state:update(0)
            reentered = assert(state:view().location)
          end
          Assert.equal(reentered.status.state, "ready", "C05 revalidates the remembered preview point")
          local _, revalidation = state.locationService:resolve(
            mapId,
            remembered.cursor.fieldX,
            remembered.cursor.fieldZ,
            reentered.generation
          )
          Assert.isTrue(
            revalidation.state == "ready" or revalidation.state == "unavailable",
            "C05 classifies the restored preview point for the active generation"
          )
          Assert.deepEqual(
            state:view().locationNavigation.cursor,
            remembered.cursor,
            "point revalidation does not replace the user's preview cursor"
          )
          Assert.deepEqual(
            state:view().locationNavigation.center,
            remembered.center,
            "point revalidation does not replace the user's viewport center"
          )
        end
        Assert.deepEqual(
          state.session:snapshot().location,
          originalLocation,
          "browsing and cursor suggestion never stage or mutate the saved destination"
        )
        finalSuggestion = suggestion
      end

      local accepted = assert(finalSuggestion, "the final browse request publishes a suggestion")
      state:_performDeferred({ kind = "location-map-select", mapId = accepted.mapId })
      local activationView = assert(state:view().location)
      local activationUpdates = 0
      while activationView.status.state == "pending" do
        activationUpdates = activationUpdates + 1
        Assert.isTrue(activationUpdates <= 5000, "the production map selection prepares the activation viewport")
        state:update(0)
        activationView = assert(state:view().location)
      end
      Assert.equal(activationView.status.state, "ready", "the activation point is prepared before selection")
      state:_performDeferred({ kind = "select_tile", fieldX = accepted.fieldX, fieldZ = accepted.fieldZ })
      local stagedLocation = assert(state.session:snapshot().location)
      Assert.equal(stagedLocation.mapId, accepted.mapId, "explicit activation accepts the suggested map")
      Assert.equal(stagedLocation.fieldX, accepted.fieldX, "explicit activation accepts the suggested x coordinate")
      Assert.equal(stagedLocation.fieldZ, accepted.fieldZ, "explicit activation accepts the suggested z coordinate")
      Assert.isTrue(state.session:snapshot().locationChanged, "acceptance stages the destination only after activation")
    end)
  end, debug.traceback)

  if state then
    pcall(function()
      state:dispose()
    end)
  end
  SaveFs.global = originalGlobal
  fixture.cleanup()
  if not ok then
    error(err, 0)
  end
end

function T.tests.stable_editor_views_reuse_the_session_snapshot_until_owner_or_revision_changes()
  local fixture = Fixture.new()
  local host = readyHost()
  local state
  local originalGlobal = SaveFs.global
  SaveFs.global = function(backend)
    Assert.isNil(backend, "the editor uses the isolated acceptance save backend")
    return fixture.saveFs
  end
  local ok, err = xpcall(function()
    local State = require("app.src.saveeditor.SaveEditorState")
    local Session = require("app.src.saveeditor.SaveEditorSession")
    state = State.new({
      versionId = fixture.versionId,
      saveId = fixture.saveId,
      width = 800,
      height = 600,
      derivedAssets = host,
      repositoryRoot = love.filesystem.getSourceBaseDirectory(),
      displayContext = DisplayContext.new({}),
      onResult = function() end,
    })
    state:update(0)
    Assert.equal(state:view().status, "ready", "the production editor opens the isolated save")

    local firstSession = assert(state.session)
    local firstOriginalSnapshot = firstSession.snapshot
    local firstSnapshotRequests = 0
    firstSession.snapshot = function(self)
      firstSnapshotRequests = firstSnapshotRequests + 1
      return firstOriginalSnapshot(self)
    end
    state.controller:setSection("Progress")
    local initial = state:_snapshot()
    local initialFlags = copy(initial.session.flags)
    local initialPlan = state:_resolve(initial)
    state:_reconcileFocus(nil, initialPlan.content.layout)
    local initialRequests = firstSnapshotRequests

    withoutRendering(function()
      for _ = 1, 12 do
        local view = state:view()
        Assert.deepEqual(view.session.flags, initialFlags, "stable Progress views preserve visible flags")
        state:_resolve(state:_snapshot())
        state:_reconcileFocus(nil, view.layout)
        state:update(0)
      end
    end)
    Assert.equal(
      firstSnapshotRequests,
      initialRequests,
      "steady view, layout, focus, and update requests do not recopy an unchanged session revision"
    )

    local candidate = firstSession:captureCandidate()
    local replacement = assert(Session.new({
      record = candidate,
      context = assert(state.dependencies).context,
      saveStore = state.dependencies.saveStore,
      saveFs = state.dependencies.saveFs,
    }))
    local replacementOriginalSnapshot = replacement.snapshot
    local replacementSnapshotRequests = 0
    replacement.snapshot = function(self)
      replacementSnapshotRequests = replacementSnapshotRequests + 1
      return replacementOriginalSnapshot(self)
    end
    Assert.equal(replacement:revision(), firstSession:revision(), "replacement starts at the same numeric revision")
    state.session = replacement
    local replacedView = state:view()
    Assert.equal(replacementSnapshotRequests, 1, "a different session owner refreshes the State projection")

    local flagId = assert(FieldScriptSymbols.flagsByName.FLAG_GOT_POKEDEX)
    local wasSet = replacedView.session.flags[flagId] == true
    local changed = replacement:setFlag("FLAG_GOT_POKEDEX", not wasSet)
    Assert.isTrue(changed.ok and changed.changed, "the production session stages a field-flag edit")
    local updatedView = state:view()
    Assert.equal(replacementSnapshotRequests, 2, "a changed session revision refreshes once")
    Assert.equal(updatedView.session.flags[flagId], not wasSet, "the changed flag is visible immediately")

    local directFirst = replacement:snapshot()
    local directSecond = replacement:snapshot()
    Assert.isFalse(rawequal(directFirst, directSecond), "each public snapshot returns an independent root table")
    Assert.isFalse(rawequal(directFirst.flags, directSecond.flags), "each public snapshot owns its flags table")
    directFirst.flags[flagId] = wasSet
    directFirst.location.fieldX = directFirst.location.fieldX + 1
    local stored = replacement:snapshot()
    Assert.equal(directSecond.flags[flagId], not wasSet, "mutating one snapshot does not change another")
    Assert.equal(stored.flags[flagId], not wasSet, "mutating a public snapshot does not change session state")
    Assert.isFalse(stored.location.fieldX == directFirst.location.fieldX, "nested snapshot records are detached")
  end, debug.traceback)
  SaveFs.global = originalGlobal
  if state then
    pcall(function()
      state:dispose()
    end)
  end
  fixture.cleanup()
  if not ok then
    error(err, 0)
  end
end

function T.tests.production_lists_fit_measured_content_and_keyboard_focus_stays_visible()
  local fixture = Fixture.new()
  local State = require("app.src.saveeditor.SaveEditorState")
  local originalGlobal = SaveFs.global
  local state
  SaveFs.global = function(backend)
    Assert.isNil(backend, "the editor uses the isolated acceptance save backend")
    return fixture.saveFs
  end

  local ok, err = xpcall(function()
    state = State.new({
      versionId = fixture.versionId,
      saveId = fixture.saveId,
      width = 800,
      height = 600,
      derivedAssets = readyHost(),
      repositoryRoot = love.filesystem.getSourceBaseDirectory(),
      displayContext = DisplayContext.new({}),
      onResult = function() end,
    })
    state:update(0)
    Assert.equal(state:view().status, "ready", "production Save Editor composition opens the isolated save")

    withoutRendering(function()
      state.controller:setSection("Location")
      local rootView = advanceEditorUntil(state, function(view)
        local list = view.layout.lists["location:root"]
        return list ~= nil and #list.rowTargets > 0 and not list.pending
      end, "the production Map root list")
      state:resize(256, 192)
      rootView = advanceEditorUntil(state, function(view)
        local list = view.layout.lists["location:root"]
        return list ~= nil and #list.rowTargets > 0 and not list.pending
      end, "the compact production Map root list")
      local rootMapList = assert(rootView.layout.lists["location:root"])

      local groupTarget, groupSize
      local rootMapModel = assert(rootView.location).mapModel
      for rowIndex = 1, #rootMapList.rowTargets do
        local row = assert(rootMapModel.rowAt(rowIndex))
        if row.kind == "group" then
          local matchingMaps = 0
          for _, map in ipairs(assert(row.maps)) do
            if map.displayName:lower():find("r", 1, true) ~= nil then
              matchingMaps = matchingMaps + 1
            end
          end
          if groupSize == nil or matchingMaps > groupSize then
            groupTarget, groupSize = row.targetId, matchingMaps
          end
        end
      end
      local selectedGroup = assert(groupTarget, "the production Map root has a selectable group")
      local rootGroupCursor = selectedGroup
      state.controller:setFocus(selectedGroup)
      state:keypressed("return")
      state:keyreleased("return")
      local groupView = advanceEditorUntil(state, function(view)
        local list = view.locationNavigation.page == "group" and view.layout.lists[assert(view.location).mapListId]
        return list ~= nil and #list.rowTargets > 0 and not list.pending
      end, "the selected production Map group")
      local groupListId = assert(groupView.location).mapListId
      local groupList = assert(groupView.layout.lists[groupListId])
      Assert.equal(groupView.locationNavigation.groupId, selectedGroup, "confirm enters the selected group identity")

      state:textinput("r")
      groupView = advanceEditorUntil(state, function(view)
        local list = view.layout.lists[groupListId]
        return list ~= nil and list.query == "r" and not list.pending
      end, "the filtered production Map group")
      groupList = assert(groupView.layout.lists[groupListId])
      local groupViewport = assert(groupView.layout.viewports[groupListId])
      local targetIndex = groupViewport.lastIndex + 1
      Assert.isTrue(targetIndex <= #groupList.rowTargets, "the Map group has a row beyond its compact viewport")
      local rememberedMap = groupList.rowTargets[targetIndex]
      for _ = 1, targetIndex do
        if state.controller.focus == rememberedMap then
          break
        end
        state:keypressed("down")
        state:keyreleased("down")
      end
      Assert.equal(state.controller.focus, rememberedMap, "keyboard selection reaches the offscreen map identity")
      local focusedGroupView = state:view()
      local focusedGroupViewport = assert(focusedGroupView.layout.viewports[groupListId])
      Assert.isTrue(
        focusedGroupViewport.firstIndex <= targetIndex and targetIndex <= focusedGroupViewport.lastIndex,
        "the production Map State reveals its focused logical row"
      )
      local rememberedQuery = state.controller.query
      local rememberedScroll = state.controller.scrollOffset

      state:keypressed("escape")
      state:keyreleased("escape")
      Assert.equal(state.controller.focus, rootGroupCursor, "Back from a nested Map row restores the root group cursor")
      Assert.equal(state.controller.locationPage, "root", "Back from a nested Map list ascends one level")

      state:keypressed("escape")
      state:keyreleased("escape")
      Assert.equal(state.controller.focus, "section:Location", "root-list Back transfers focus to Location")
      Assert.equal(state.controller.locationPage, "root", "root-list Back keeps the Map hierarchy at its root")

      state:keypressed("tab")
      Assert.equal(state.controller.focus, rootGroupCursor, "Tab re-enters the remembered root group row")
      state:keypressed("return")
      state:keyreleased("return")
      local restoredGroupView = advanceEditorUntil(state, function(view)
        return view.locationNavigation.page == "group"
          and view.locationNavigation.groupId == selectedGroup
          and view.location.mapListId == groupListId
      end, "the remembered production Map group")
      Assert.equal(state.controller.focus, rememberedMap, "re-entering the group restores the remembered Map row")
      Assert.equal(state.controller.query, rememberedQuery, "re-entering the group restores its query")
      Assert.equal(state.controller.scrollOffset, rememberedScroll, "re-entering the group restores its scroll")
      local restoredViewport = assert(restoredGroupView.layout.viewports[groupListId])
      Assert.isTrue(
        restoredViewport.firstIndex <= targetIndex and targetIndex <= restoredViewport.lastIndex,
        "re-entering the Map group reveals the remembered row"
      )
      for _, row in ipairs(restoredGroupView.layout.rows) do
        if groupList.indexByTarget[row.targetId] ~= nil then
          Assert.isNil(row.value, "Map rows use their complete label without a trailing value")
          Assert.isNil(row.valueRect, "Map rows do not reserve a trailing value cell")
          local rowTarget = assert(restoredGroupView.layout.targets[row.targetId]).rect
          Assert.isTrue(
            row.labelRect.x + row.labelRect.width >= rowTarget.x + rowTarget.width - 12,
            "Map labels reach the full text width after the marker inset"
          )
        end
      end

      state:keypressed("escape")
      state:keyreleased("escape")
      local returnedRootView = advanceEditorUntil(state, function(view)
        return view.locationNavigation.page == "root"
      end, "the Map root after Back from its group")
      Assert.equal(state.controller.focus, rootGroupCursor, "Back from the group restores the root cursor")
      for _, row in ipairs(returnedRootView.layout.rows) do
        if rootMapList.indexByTarget[row.targetId] ~= nil then
          Assert.isNil(row.value, "Map group rows use their complete label without a trailing value")
          Assert.isNil(row.valueRect, "Map group rows do not reserve a trailing value cell")
          local rowTarget = assert(returnedRootView.layout.targets[row.targetId]).rect
          Assert.isTrue(
            row.labelRect.x + row.labelRect.width >= rowTarget.x + rowTarget.width - 12,
            "Map group labels reach the full text width after the marker inset"
          )
        end
      end
      local mapUsesAvailableWidth = rootMapList.surfaceRect.width == returnedRootView.layout.content.width

      state.controller:setSection("Progress")
      local flagView = advanceEditorUntil(state, function(view)
        local list = view.layout.lists.flags
        return list ~= nil and #list.rowTargets > 0 and not list.pending
      end, "the production Flags list")
      local flagList = assert(flagView.layout.lists.flags)
      local flagsUseAvailableWidth = flagList.surfaceRect.width == flagView.layout.content.width
      local flagsStartAtContentEdge = flagList.surfaceRect.x == flagView.layout.content.x

      local initialViewport = assert(flagView.layout.viewports.flags)
      local targetIndex = math.min(#flagList.rowTargets, initialViewport.lastIndex + 2)
      Assert.isTrue(targetIndex > initialViewport.lastIndex, "the real Flags catalog has an offscreen logical row")
      state:keypressed("return")
      for _ = 1, targetIndex do
        if state.controller.focus == flagList.rowTargets[targetIndex] then
          break
        end
        state:keypressed("down")
        state:keyreleased("down")
      end

      local focused = state.controller.focus
      Assert.equal(focused, flagList.rowTargets[targetIndex], "keyboard navigation preserves the chosen flag identity")
      local revealed = state:view()
      local viewport = assert(revealed.layout.viewports.flags)
      Assert.isTrue(
        viewport.firstIndex <= targetIndex and targetIndex <= viewport.lastIndex,
        "the keyboard-focused logical flag is revealed by the production State"
      )
      Assert.isTrue(
        rectInside(assert(revealed.layout.rowMarkers[focused]), viewport.clip),
        "the focused flag marker remains wholly inside the actual viewport"
      )
      Assert.isTrue(
        rectInside(assert(revealed.layout.rowLabelRects[focused]), viewport.clip),
        "the focused flag label remains wholly inside the actual viewport"
      )
      Assert.isTrue(mapUsesAvailableWidth, "the Map root surface uses the full available editor body width")
      Assert.isTrue(flagsUseAvailableWidth, "the Flags surface uses the full available body width")
      Assert.isTrue(flagsStartAtContentEdge, "the full-width Flags surface aligns to its available body")
    end)
  end, debug.traceback)
  if state then
    pcall(function()
      state:dispose()
    end)
  end
  SaveFs.global = originalGlobal
  fixture.cleanup()
  if not ok then
    error(err, 0)
  end
end

function T.tests.pallet_and_azalea_map_placement_stays_conservative_with_real_rom_data()
  local fixture = Fixture.new()
  local host = readyHost()
  local graph, service
  local ok, err = xpcall(function()
    graph = openComposition(fixture, host)
    local palletMapId = assert(graph.world.bySymbol.MAP_PALLET, "the real world catalog contains Pallet Town")
    local azaleaGymMapId = assert(graph.world.bySymbol.MAP_AZALEA_GYM, "the real world catalog contains Azalea Gym")
    service = locationServiceModule().new({
      cacheFs = graph.cacheFs,
      world = graph.world,
      derivedAssets = host,
      savedObjects = copy(fixture.initial.world.objects),
    })

    local function browse(mapId, fieldX, fieldZ, width, height)
      service:openMap(mapId, { purpose = "browse" })
      service:setViewport(fieldX, fieldZ, width, height)
      local view
      for _ = 1, 5000 do
        service:update()
        view = service:snapshot()
        if view.status.state == "ready" and service.objectEvents ~= nil then
          return view
        end
      end
      error("the real map did not finish browse preparation: " .. tostring(view and view.status.reason), 2)
    end

    local palletView = browse(palletMapId, 1033, 364, 3, 3)
    local suggestion = assert(palletView.initialCursor, "the real map suggestion publishes its selected safe point")
    Assert.equal(suggestion.state, "ready", "Pallet Town's map suggestion finds an actually selectable tile")
    local palletPlacement, palletResult =
      service:resolve(palletMapId, assert(suggestion.fieldX), assert(suggestion.fieldZ), palletView.generation)
    Assert.notNil(palletPlacement, "the suggested Pallet destination passes production classification")
    Assert.equal(palletResult.state, "ready", "the surveyed Pallet destination is ready to stage")

    local beforeInvalidAttempt = graph.session:captureCandidate()
    local azaleaView = browse(azaleaGymMapId, 32, 7, 1, 1)
    local invalidPlacement, invalidReason = service:resolve(azaleaGymMapId, 32, 7, azaleaView.generation)
    Assert.isNil(invalidPlacement, "Azalea Gym's out-of-permission tile cannot be selected")
    Assert.equal(invalidReason.state, "unavailable", "Azalea Gym rejects the uncovered point normally")
    Assert.equal(invalidReason.reason, "outside_map", "the uncovered point retains its normal placement reason")
    Assert.deepEqual(
      graph.session:captureCandidate(),
      beforeInvalidAttempt,
      "rejecting the invalid point does not change the candidate save"
    )

    Assert.isTrue(
      graph.session:setLocation(palletPlacement).ok,
      "a valid Pallet tuple stages through the production Session"
    )
    Assert.isTrue(graph.session:save().ok, "the valid tuple saves through the production composition")
    local published = assert(fixture.store:load(fixture.saveId))
    Assert.equal(published.mapId, palletPlacement.mapId, "the native save retains the selected map identity")
    Assert.equal(published.fieldX, palletPlacement.fieldX, "the native save retains the selected field X")
    Assert.equal(published.fieldZ, palletPlacement.fieldZ, "the native save retains the selected field Z")
    Assert.equal(published.surfaceId, palletPlacement.surfaceId, "the native save retains the resolved surface")
    Assert.equal(
      published.terrainDependencyHash,
      palletPlacement.terrainDependencyHash,
      "the native save retains the resolved terrain dependency"
    )
  end, debug.traceback)
  if service then
    pcall(function()
      service:dispose()
    end)
  end
  if graph then
    pcall(function()
      graph:close()
    end)
  end
  fixture.cleanup()
  if not ok then
    error(err, 0)
  end
end

function T.tests.dropped_location_preset_resolves_stages_and_saves_through_the_editor()
  local fixture = Fixture.new()
  local originalGlobal = SaveFs.global
  local originalDialog = love.window.showMessageBox
  local originalAppState = App.state
  local dialogs = {}
  love.window.showMessageBox = function(title, message, kind)
    dialogs[#dialogs + 1] = { title = title, message = message, kind = kind }
    return true
  end
  SaveFs.global = function(backend)
    Assert.isNil(backend, "the editor uses the isolated acceptance save backend")
    return fixture.saveFs
  end

  local state
  local ok, err = xpcall(function()
    local State = require("app.src.saveeditor.SaveEditorState")
    state = State.new({
      versionId = fixture.versionId,
      saveId = fixture.saveId,
      width = 640,
      height = 480,
      derivedAssets = readyHost(),
      repositoryRoot = love.filesystem.getSourceBaseDirectory(),
      displayContext = DisplayContext.new({}),
      onResult = function() end,
    })
    state:update(0)
    Assert.equal(state:view().status, "ready", "production Save Editor composition opens the isolated save")
    App.state = state

    local source = [=[return {
      schema = "portemon-save-preset-v1",
      name = "Acceptance location",
      description = "Resolve a real destination before staging.",
      flags = { FLAG_BEAT_RADIO_TOWER_ROCKETS = true },
      variables = { VAR_UNK_40FE = 0 },
      items = { POTION = 3 },
      location = { map = "MAP_NEW_BARK_PLAYER_HOUSE_1F", x = 4, z = 5, facing = "north" },
    }]=]
    local function droppedFile(bytes, filename)
      return {
        opened = 0,
        closed = 0,
        getFilename = function()
          return filename or "acceptance.lua"
        end,
        getSize = function()
          return #bytes
        end,
        open = function(self, mode)
          Assert.equal(mode, "r", "the dropped file opens for reading")
          self.opened = self.opened + 1
          return true
        end,
        read = function(_, format, size)
          Assert.equal(format, "string", "the dropped file is read as bytes")
          Assert.equal(size, #bytes, "the bounded read uses the reported file size")
          return bytes
        end,
        close = function(self)
          self.closed = self.closed + 1
          return true
        end,
      }
    end
    local file = droppedFile(source)

    withoutRendering(function()
      local before = state.session:captureCandidate()
      App.filedropped(file)
      for _ = 1, 5000 do
        if #dialogs > 0 then
          break
        end
        state:update(0)
      end
      Assert.equal(file.opened, 1, "the accepted drop opens once")
      Assert.equal(file.closed, 1, "the accepted drop closes once")
      Assert.equal(#dialogs, 1, "the terminal import shows one confirmation")
      Assert.equal(dialogs[1].title, "Preset imported", "the verified preset is accepted")
      Assert.equal(dialogs[1].kind, "info", "success uses an informational OK dialog")
      Assert.isTrue(dialogs[1].message:find("staged", 1, true) ~= nil, "confirmation explains changes are staged")
      Assert.isTrue(dialogs[1].message:find("Save", 1, true) ~= nil, "confirmation directs the user to Save")

      local staged = state.session:captureCandidate()
      Assert.isFalse(staged.mapId == before.mapId, "the resolved preset changes the staged destination")
      Assert.equal(staged.mapId, assert(state.dependencies.world.bySymbol.MAP_NEW_BARK_PLAYER_HOUSE_1F))
      Assert.equal(staged.fieldX, 4)
      Assert.equal(staged.fieldZ, 5)
      Assert.equal(staged.facing, "north")
      Assert.equal(staged.world.variables[assert(FieldScriptSymbols.variablesByName.VAR_UNK_40FE)] or 0, 0)
      Assert.isTrue(state:view().dirty, "the import remains an unsaved editor change")
      Assert.deepEqual(assert(fixture.store:load(fixture.saveId)), fixture.initial, "the drop does not write the save")

      local celebiSource = [=[return {
        schema = "portemon-save-preset-v1",
        name = "Ilex Forest Celebi",
        description = "Stage the shrine approach through production location verification.",
        flags = {
          FLAG_BEAT_RADIO_TOWER_ROCKETS = true,
          FLAG_HIDE_ILEX_FOREST_FRIEND = true,
        },
        variables = { VAR_UNK_40FE = 0 },
        party = { lead = { species = "CELEBI", fatefulEncounter = true, eggLocation = 0 } },
        location = { map = "MAP_ILEX_FOREST", x = 16, z = 56, facing = "north" },
      }]=]
      local celebiFile = droppedFile(celebiSource, "celebi.lua")
      App.filedropped(celebiFile)
      for _ = 1, 5000 do
        if #dialogs > 1 then
          break
        end
        state:update(0)
      end
      Assert.equal(celebiFile.opened, 1, "the Celebi preset opens once")
      Assert.equal(celebiFile.closed, 1, "the Celebi preset closes once")
      Assert.equal(#dialogs, 2, "the verified Celebi preset has one terminal result")
      Assert.equal(
        dialogs[2].title,
        "Preset imported",
        "the verified shrine approach is accepted: " .. dialogs[2].title .. " / " .. dialogs[2].message
      )
      Assert.equal(dialogs[2].kind, "info", "the verified preset uses an informational dialog")
      Assert.isNil(state.pendingPreset, "the completed preset verification releases its service")
      local celebiStaged = state.session:captureCandidate()
      Assert.equal(celebiStaged.mapId, assert(state.dependencies.world.bySymbol.MAP_ILEX_FOREST))
      Assert.equal(celebiStaged.fieldX, 16)
      Assert.equal(celebiStaged.fieldZ, 56)
      Assert.equal(celebiStaged.facing, "north")
      Assert.isTrue(celebiStaged.surfaceId >= 0, "the staged destination retains its resolved surface")
      Assert.isTrue(type(celebiStaged.worldY) == "number", "the staged destination retains its resolved height")
      Assert.isTrue(
        type(celebiStaged.terrainDependencyHash) == "string" and celebiStaged.terrainDependencyHash ~= "",
        "the staged destination retains its verified terrain dependency"
      )
      Assert.equal(
        celebiStaged.world.flags[assert(FieldScriptSymbols.flagsByName.FLAG_BEAT_RADIO_TOWER_ROCKETS)],
        true
      )
      Assert.equal(
        celebiStaged.world.flags[assert(FieldScriptSymbols.flagsByName.FLAG_HIDE_ILEX_FOREST_FRIEND)],
        true
      )
      Assert.equal(
        celebiStaged.world.variables[assert(FieldScriptSymbols.variablesByName.VAR_UNK_40FE)] or 0,
        0
      )
      Assert.equal(celebiStaged.mons.party.mons[1].species, "CELEBI")
      Assert.isTrue(celebiStaged.mons.party.mons[1].fatefulEncounter)
      Assert.equal(celebiStaged.mons.party.mons[1].egg.location, 0)
      Assert.deepEqual(assert(fixture.store:load(fixture.saveId)), fixture.initial, "the verified drop still waits for Save")

      local beforeMalformed = state.session:captureCandidate()
      local malformedFile = droppedFile("return { schema = 'unsupported' }", "malformed.lua")
      App.filedropped(malformedFile)
      Assert.equal(malformedFile.opened, 1, "the rejected drop opens once")
      Assert.equal(malformedFile.closed, 1, "the rejected drop closes once")
      Assert.equal(#dialogs, 3, "the invalid attempt has one terminal dialog")
      Assert.equal(dialogs[3].title, "Preset rejected", "the malformed document is rejected explicitly")
      Assert.deepEqual(state.session:captureCandidate(), beforeMalformed, "rejection preserves prior staged changes")
      Assert.deepEqual(assert(fixture.store:load(fixture.saveId)), fixture.initial, "rejection leaves disk untouched")

      activateTarget(state, "save")
      state:update(0)
      local published = assert(fixture.store:load(fixture.saveId))
      Assert.equal(published.mapId, celebiStaged.mapId, "manual Save publishes the verified map")
      Assert.equal(published.fieldX, 16, "manual Save publishes the verified field X")
      Assert.equal(published.fieldZ, 56, "manual Save publishes the verified field Z")
      Assert.equal(published.facing, "north", "manual Save publishes staged facing")
      Assert.equal(published.surfaceId, celebiStaged.surfaceId, "manual Save publishes the verified surface")
      Assert.equal(published.worldY, celebiStaged.worldY, "manual Save publishes the verified surface height")
      Assert.equal(
        published.terrainDependencyHash,
        celebiStaged.terrainDependencyHash,
        "manual Save publishes the verified terrain dependency"
      )
      Assert.equal(
        published.world.flags[assert(FieldScriptSymbols.flagsByName.FLAG_BEAT_RADIO_TOWER_ROCKETS)],
        true
      )
      Assert.equal(
        published.world.flags[assert(FieldScriptSymbols.flagsByName.FLAG_HIDE_ILEX_FOREST_FRIEND)],
        true
      )
      Assert.equal(
        published.world.variables[assert(FieldScriptSymbols.variablesByName.VAR_UNK_40FE)] or 0,
        0
      )
      Assert.equal(published.mons.party.mons[1].species, "CELEBI")
      Assert.isTrue(published.mons.party.mons[1].fatefulEncounter)
      Assert.equal(published.mons.party.mons[1].egg.location, 0)
      Assert.equal(state:view().dirty, false, "ordinary Save clears staged dirty state")
    end)
  end, debug.traceback)

  if state then
    pcall(function()
      state:dispose()
    end)
  end
  App.state = originalAppState
  love.window.showMessageBox = originalDialog
  SaveFs.global = originalGlobal
  fixture.cleanup()
  if not ok then
    error(err, 0)
  end
end

function T.tests.relocated_destination_saves_synchronously_and_resumes_without_rechecking()
  local fixture = Fixture.new()
  local host = readyHost()
  local graph, service, state, resume
  local originalGlobal = SaveFs.global
  SaveFs.global = function(backend)
    Assert.isNil(backend, "the editor uses the isolated acceptance save backend")
    return fixture.saveFs
  end
  local ok, err = xpcall(function()
    graph = openComposition(fixture, host)
    local _
    service, _ = resolvedHousePlacement(graph, fixture, host)
    local placement = resolvedOutdoorPlacement(graph, service)

    local State = require("app.src.saveeditor.SaveEditorState")
    local results = {}
    state = State.new({
      versionId = fixture.versionId,
      saveId = fixture.saveId,
      width = 640,
      height = 480,
      derivedAssets = host,
      repositoryRoot = love.filesystem.getSourceBaseDirectory(),
      displayContext = DisplayContext.new({}),
      onResult = function(result)
        results[#results + 1] = result
      end,
    })
    state:update(0)
    withoutRendering(function()
      Assert.equal(state:view().status, "ready", "the production editor opens the isolated save")
      Assert.isTrue(state.session:setLocation(placement).ok, "the resolved outdoor tuple stages")
      local expected = state.session:captureCandidate()
      activateTarget(state, "save")
      state:update(0)
      Assert.isFalse(state:view().dirty, "the published relocated save clears the dirty projection")
      Assert.deepEqual(results, {}, "the in-place save keeps the editor open")
      Assert.deepEqual(
        assert(fixture.store:load(fixture.saveId)),
        expected,
        "the staged tuple publishes through the real store"
      )

      service:dispose()
      service = nil
      graph = nil
      SaveFs.global = originalGlobal
      local resumeHarness = AcceptanceHarness.new({
        versions = { fixture.versionId },
        gameFactory = function()
          return copy(assert(fixture.store:load(fixture.saveId)))
        end,
      })
      local bootOk, bootErr = xpcall(function()
        resume = resumeHarness:boot({ versionId = fixture.versionId, save = "edited" })
        resume:waitForFieldReady()
        local runtime = resume.runtime
        Assert.equal(runtime.player.currentMap.mapId, placement.mapId, "field resume keeps the saved map")
        Assert.equal(runtime.player.fieldX, placement.fieldX, "field resume keeps the saved field X")
        Assert.equal(runtime.player.fieldZ, placement.fieldZ, "field resume keeps the saved field Z")
        Assert.equal(runtime.player.surfaceId, placement.surfaceId, "field resume keeps the resolved surface")
        Assert.equal(resume:renderAttempts(), 0, "the resume assertion stops before GPU rendering")
      end, debug.traceback)
      if resume ~= nil then
        pcall(function()
          assert(resume):close()
        end)
        resume = nil
      end
      if not bootOk then
        error(bootErr, 0)
      end
    end)
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
  if state then
    pcall(function()
      state:dispose()
    end)
  end
  SaveFs.global = originalGlobal
  fixture.cleanup()
  if not ok then
    error(err, 0)
  end
end

function T.tests.unfamiliar_real_map_opens_near_its_owned_cells_without_staging_a_save()
  local fixture = Fixture.new()
  local State = require("app.src.saveeditor.SaveEditorState")
  local originalGlobal = SaveFs.global
  local state
  SaveFs.global = function(backend)
    Assert.isNil(backend, "the editor must use the isolated acceptance save backend")
    return fixture.saveFs
  end

  local ok, err = xpcall(function()
    state = State.new({
      versionId = fixture.versionId,
      saveId = fixture.saveId,
      width = 640,
      height = 480,
      derivedAssets = readyHost(),
      repositoryRoot = love.filesystem.getSourceBaseDirectory(),
      displayContext = DisplayContext.new({}),
      onResult = function() end,
    })
    state:update(0)

    withoutRendering(function()
      local openingView = state:view()
      Assert.equal(
        openingView.status,
        "ready",
        "production Save Editor composition opens the selected save: " .. tostring(openingView.errorMessage)
      )
      local originalLocation = copy(state.session:snapshot().location)
      local world = assert(state.dependencies.world)
      local mapId = assert(world.bySymbol.MAP_ROUTE_29)
      Assert.isFalse(originalLocation.mapId == mapId, "route selection starts from a map the save has never staged")

      state:_performDeferred({ kind = "location-map-select", mapId = mapId })
      state:update(0)

      local seenSeeded, seed, updates = false, nil, 0
      local view = assert(state:view().location)
      while view.status.state == "pending" and updates < 1500 do
        updates = updates + 1
        state:update(0)
        view = assert(state:view().location)
        if view.initialCursor ~= nil and view.initialCursor.state == "seeded" then
          seenSeeded = true
          seed = view.initialCursor
        end
        Assert.deepEqual(
          state.session:snapshot().location,
          originalLocation,
          "browsing never stages or mutates the saved destination"
        )
      end
      Assert.isTrue(seenSeeded, "production browse publishes a map-owned seed before its safe suggestion completes")
      seed = assert(seed, "the published seed belongs to the selected map")
      Assert.equal(seed.mapId, mapId, "the seed remains bound to the selected map")
      -- Route 29's structural origin is genuinely on-map (measured), so the
      -- owned-cell proof is membership, not origin inequality; the synthetic
      -- misleading-origin case stays covered by the component seed tests.
      local domain = state.locationService.loader:mapCellDomain(mapId)
      local owned, domainDone, domainGuard = {}, false, 0
      while not domainDone and domainGuard < 10000 do
        domainGuard = domainGuard + 1
        local _, selected, complete = domain:advance(1024)
        for _, descriptor in ipairs(selected) do
          if descriptor.mapHeaderId == mapId then
            owned[#owned + 1] = descriptor
          end
        end
        domainDone = complete
      end
      Assert.isTrue(domainDone, "the owned-cell walk completes")
      Assert.isTrue(#owned > 0, "the selected map owns physical cells")
      local seedCellX, seedCellZ = math.floor(seed.fieldX / 32), math.floor(seed.fieldZ / 32)
      local seedOwned = false
      for _, cell in ipairs(owned) do
        if cell.x == seedCellX and cell.z == seedCellZ then
          seedOwned = true
        end
      end
      Assert.isTrue(seedOwned, "the seed lies inside a physical cell owned by the selected map")
      while view.status.state == "pending" and updates < 5000 do
        updates = updates + 1
        state:update(0)
        view = assert(state:view().location)
      end
      Assert.equal(view.status.state, "ready", "the selected source map is prepared")
      local suggestion = view.initialCursor
      Assert.notNil(suggestion, "real map browsing publishes its initial cursor")
      if suggestion.state == "ready" then
        local resolved, resolution =
          state.locationService:resolve(mapId, assert(suggestion.fieldX), assert(suggestion.fieldZ), view.generation)
        Assert.notNil(resolved, "the suggested coordinate passes the production placement classifier")
        Assert.equal(resolution.state, "ready", "the suggestion is fully prepared for explicit selection")
      end
      Assert.deepEqual(
        state.session:snapshot().location,
        originalLocation,
        "browsing and hinting never stage or mutate the saved destination"
      )
    end)
  end, debug.traceback)

  if state then
    pcall(function()
      state:dispose()
    end)
  end
  SaveFs.global = originalGlobal
  fixture.cleanup()
  if not ok then
    error(err, 0)
  end
end

return T
