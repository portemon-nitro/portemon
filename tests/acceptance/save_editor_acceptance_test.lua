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
      "map:7",
      "map:33",
      "map:63",
      "map:49",
      "map:180",
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

function T.tests.one_save_intent_keeps_the_browser_and_publishes_after_destination_readiness()
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
      local browserMapId = assert(
        state:view().locationNavigation.mapId,
        "the browser remembers the saved map while the section opens on the map list"
      )
      Assert.isTrue(state.session:setLocation(placement).ok, "the existing Session stages a resolved outdoor tuple")
      local expected = state.session:captureCandidate()
      state.controller:setSection("Player")
      activateTarget(state, "save")
      state:update(0)
      Assert.equal(recordWrites, 0, "the Save intent waits while destination data is pending")
      Assert.equal(
        state:view().locationNavigation.mapId,
        browserMapId,
        "a pending destination check does not replace the user's browser map"
      )

      destinationReady = true
      local updates = 0
      while recordWrites == 0 do
        updates = updates + 1
        Assert.isTrue(updates <= 5000, "the ready destination publishes the pending save")
        state:update(0)
      end
      Assert.equal(recordWrites, 1, "one Save intent publishes exactly one save after readiness")
      Assert.deepEqual(assert(fixture.store:load(fixture.saveId)), expected, "the authorized tuple and edits publish")
      Assert.equal(
        state:view().locationNavigation.mapId,
        browserMapId,
        "verification leaves the browser selection untouched"
      )
      Assert.equal(#results, 0, "Save keeps the editor open")

      Assert.isTrue(state.session:setLocation(assert(housePlacement)).ok)
      destinationMapId = housePlacement.mapId
      destinationReady = false
      state:requestClose("quit")
      activateTarget(state, "save")
      state:update(0)
      Assert.notNil(state:view().locationSave, "the second Save owns one pending verification")
      Assert.equal(recordWrites, 1, "the replacement destination is still waiting")

      local externalRecord = assert(fixture.store:load(fixture.saveId))
      externalRecord.playerData.profile.money = externalRecord.playerData.profile.money + 2
      fixture.store:save(externalRecord)
      Assert.equal(recordWrites, 2, "the canonical save changes through the real store")

      destinationReady = true
      local updates = 0
      while state:view().locationSave ~= nil do
        updates = updates + 1
        Assert.isTrue(updates <= 5000, "the ready verifier completes the final save attempt")
        state:update(0)
      end
      local failureView = state:view()
      Assert.isNil(failureView.locationSave, "the ready verifier is disposed after the final save attempt")
      Assert.equal(
        failureView.errorMessage,
        "This save changed after the editor opened. Reopen it before saving.",
        "the asynchronous save exposes the structured Session conflict; got " .. tostring(failureView.errorMessage)
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
      Assert.equal(
        state.session:bagSnapshot(view.bagPocket)[1].quantity,
        originalQuantity,
        "Cancel publishes no quantity"
      )

      activateTarget(state, "bag:quantity")
      state:keypressed("up")
      state:keyreleased("up")
      state:keypressed("return")
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
      state:keypressed("return")
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
      state:keypressed("return")

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

function T.tests.real_map_browsing_surveys_a_valid_initial_cursor_without_changing_the_save()
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
        Assert.notNil(suggestion, "real map browsing publishes its surveyed initial cursor")
        Assert.equal(
          suggestion.state,
          "ready",
          "the survey finds a selectable tile in " .. tostring(view.symbol) .. ": " .. tostring(suggestion.state)
        )
        Assert.equal(suggestion.mapId, mapId, "the suggestion remains bound to the selected map")
        Assert.equal(
          suggestion.generation,
          requestGeneration,
          "the suggestion remains bound to the active browse request"
        )
        local resolved, resolution =
          state.locationService:resolve(mapId, assert(suggestion.fieldX), assert(suggestion.fieldZ), view.generation)
        Assert.notNil(resolved, "the surveyed coordinate passes the production placement classifier")
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
          while state:view().locationNavigation.center.fieldX == originalCenter.fieldX
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
            remembered.cursor.fieldX == originalCursor.fieldX
              and remembered.cursor.fieldZ == originalCursor.fieldZ,
            "manual navigation changes the preview cursor"
          )
          Assert.isFalse(
            remembered.center.fieldX == originalCenter.fieldX
              and remembered.center.fieldZ == originalCenter.fieldZ,
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
          "browsing and surveying never stage or mutate the saved destination"
        )
        finalSuggestion = suggestion
      end

      local accepted = assert(finalSuggestion, "the final browse request publishes a suggestion")
      state.controller:chooseLocationMap(accepted.mapId, assert(accepted.fieldX), assert(accepted.fieldZ))
      state:update(0)
      state:_performDeferred({ kind = "select_tile", fieldX = accepted.fieldX, fieldZ = accepted.fieldZ })
      local stagedLocation = assert(state.session:snapshot().location)
      Assert.equal(stagedLocation.mapId, accepted.mapId, "explicit activation accepts the surveyed map")
      Assert.equal(stagedLocation.fieldX, accepted.fieldX, "explicit activation accepts the surveyed x coordinate")
      Assert.equal(stagedLocation.fieldZ, accepted.fieldZ, "explicit activation accepts the surveyed z coordinate")
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
    Assert.isFalse(
      stored.location.fieldX == directFirst.location.fieldX,
      "nested snapshot records are detached"
    )
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
      local rootView = advanceEditorUntil(state, function(view)
        local list = view.layout.lists["location:root"]
        return list ~= nil and #list.rowTargets > 0 and not list.pending
      end, "the production Map root list")
      local mapList = assert(rootView.layout.lists["location:root"])
      local mapFitsMeasuredContent = mapList.surfaceRect.width < rootView.layout.content.width

      state.controller:setSection("Progress")
      local flagView = advanceEditorUntil(state, function(view)
        local list = view.layout.lists.flags
        return list ~= nil and #list.rowTargets > 0 and not list.pending
      end, "the production Flags list")
      local flagList = assert(flagView.layout.lists.flags)
      local flagsFitMeasuredContent = flagList.surfaceRect.width < flagView.layout.content.width
      local flagsAreCentered = math.abs(
        flagList.surfaceRect.x
          + flagList.surfaceRect.width / 2
          - (flagView.layout.content.x + flagView.layout.content.width / 2)
      ) < 1

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
      Assert.isTrue(
        mapFitsMeasuredContent,
        "the Map root surface uses measured labels instead of filling the full editor body"
      )
      Assert.isTrue(flagsFitMeasuredContent, "the Flags surface reserves only measured label and ON/OFF content")
      Assert.isTrue(flagsAreCentered, "the narrower Flags surface stays centered in its available body")
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
    local palletPlacement
    local sawAmbiguousSource = false
    for _, tile in ipairs(palletView.tiles) do
      local placement, result = service:resolve(palletMapId, tile.fieldX, tile.fieldZ, palletView.generation)
      if placement ~= nil then
        palletPlacement = placement
        break
      end
      sawAmbiguousSource = sawAmbiguousSource or result.reason == "ambiguous_source_actor"
    end
    Assert.isTrue(
      palletPlacement ~= nil or sawAmbiguousSource,
      "Pallet Town either exposes a valid source-safe destination or reports an ambiguous identity conservatively"
    )

    local beforeInvalidAttempt = graph.session:captureCandidate()
    local azaleaView = browse(azaleaGymMapId, 32, 7, 1, 1)
    local invalidPlacement, invalidReason = service:resolve(
      azaleaGymMapId,
      32,
      7,
      azaleaView.generation
    )
    Assert.isNil(invalidPlacement, "Azalea Gym's out-of-permission tile cannot be selected")
    Assert.equal(invalidReason.state, "unavailable", "Azalea Gym rejects the uncovered point normally")
    Assert.equal(invalidReason.reason, "outside_map", "the uncovered point retains its normal placement reason")
    Assert.deepEqual(
      graph.session:captureCandidate(),
      beforeInvalidAttempt,
      "rejecting the invalid point does not change the candidate save"
    )

    if palletPlacement ~= nil then
      Assert.isTrue(graph.session:setLocation(palletPlacement).ok, "a valid Pallet tuple stages through the production Session")
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
    end
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

return T
