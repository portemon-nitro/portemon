-- Opening-state lifecycle contracts over the borrowed asset host.

local Assert = require("tests.support.Assert")
local Fixture = require("app.tests.support.SaveEditorAcceptanceFixture")
local DisplayContext = require("libs.ui.src.DisplayContext")
local SaveFs = require("libs.storage.src.SaveFs")

local function copy(value)
  if type(value) ~= "table" then
    return value
  end
  local result = {}
  for key, child in pairs(value) do
    result[key] = copy(child)
  end
  return result
end

local T = {
  metadata = {
    capabilities = { "rom_dump" },
    derivedAssets = { "field-runtime", "map-data:7", "map:7", "audio-bank:730" },
    tags = { "product", "save-editor", "lifecycle" },
  },
  tests = {},
}

local function stateModule()
  local loaded, State = pcall(require, "app.src.saveeditor.SaveEditorState")
  Assert.isTrue(loaded, "Edit must provide an opening State before publishing a save session")
  Assert.equal(type(State.new), "function", "the product opening State must be constructible")
  return State
end

local function stateHasRole(value, role, seen)
  if type(value) ~= "table" then
    return false
  end
  seen = seen or {}
  if seen[value] then
    return false
  end
  seen[value] = true
  if value.role == role then
    return true
  end
  for _, child in pairs(value) do
    if stateHasRole(child, role, seen) then
      return true
    end
  end
  return false
end

function T.tests.pending_opening_can_cancel_and_ignores_late_readiness()
  local State = stateModule()
  local readiness = "pending"
  local requests = {}
  local hostDisposals = 0
  local results = {}
  local host = {
    dispose = function()
      hostDisposals = hostDisposals + 1
    end,
    retire = function()
      hostDisposals = hostDisposals + 1
    end,
    requestMilestone = function(name, urgency)
      requests[#requests + 1] = { name = name, urgency = urgency }
      if readiness == "ready" then
        return true
      end
      return false
    end,
  }
  local state = State.new({
    versionId = "heartgold",
    saveId = "save-00000001",
    width = 256,
    height = 192,
    derivedAssets = host,
    repositoryRoot = love.filesystem.getSourceBaseDirectory(),
    displayContext = DisplayContext.new({}),
    onResult = function(result)
      results[#results + 1] = result
    end,
  })

  state:update(0)
  state:keypressed("right")
  state:keypressed("return")
  Assert.isFalse(state:requestClose("back"), "a pending clean editor can leave without a dirty-work veto")
  state:dispose()
  state:dispose()
  readiness = "ready"
  state:update(0)

  local requested = {}
  for _, request in ipairs(requests) do
    requested[request.name] = request.urgency
  end
  Assert.equal(requested["field-planning"], "required", "opening waits for field planning")
  Assert.equal(requested["field-runtime"], "required", "opening waits for field runtime")
  Assert.equal(#results, 1, "late readiness cannot publish another result")
  Assert.equal(results[1].kind, "main_menu", "Back returns to the existing product menu")
  Assert.equal(hostDisposals, 0, "the editor never retires its borrowed readiness host")
end

function T.tests.failed_borrowed_readiness_can_retry_into_a_real_session()
  local State = stateModule()
  local fixture = Fixture.new()
  local originalGlobal = SaveFs.global
  SaveFs.global = function(backend)
    Assert.isNil(backend, "the editor uses the isolated global SaveFs selected by this fixture")
    return fixture.saveFs
  end
  local failed = true
  local hostRequests = 0
  local hostDisposals = 0
  local results = {}
  local host = {
    requestMilestone = function(name, urgency)
      hostRequests = hostRequests + 1
      Assert.equal(urgency, "required")
      Assert.isTrue(name == "field-planning" or name == "field-runtime")
      if failed then
        return false, "derived cache preparation failed"
      end
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
    dispose = function()
      hostDisposals = hostDisposals + 1
    end,
    retire = function()
      hostDisposals = hostDisposals + 1
    end,
  }
  local state
  local ok, err = xpcall(function()
    state = State.new({
      versionId = fixture.versionId,
      saveId = fixture.saveId,
      width = 256,
      height = 192,
      derivedAssets = host,
      repositoryRoot = love.filesystem.getSourceBaseDirectory(),
      displayContext = DisplayContext.new({}),
      onResult = function(result)
        results[#results + 1] = result
      end,
    })

    state:update(0)
    Assert.isTrue(hostRequests > 0, "opening must observe the borrowed host's terminal failure")
    Assert.equal(state:view().status, "error", "the production readiness failure becomes visible immediately")
    Assert.equal(
      state:view().errorMessage,
      "derived cache preparation failed",
      "the original readiness error is retained for the user"
    )
    Assert.isTrue(type(state:view().errorMessage) == "string", "the error page remains observable before Recheck")
    local failedRequests = hostRequests
    state:keypressed("return")
    state:keyreleased("return")
    state:update(0)
    Assert.isTrue(hostRequests > failedRequests, "Recheck issues the same borrowed readiness request")
    Assert.equal(state:view().status, "error", "a latched failure remains an error after Recheck")
    Assert.equal(state:view().errorMessage, "derived cache preparation failed")
    failed = false
    state:keypressed("return")
    state:keyreleased("return")
    state:update(0)
    Assert.isTrue(hostRequests > 1, "Retry requests readiness again from the borrowed host")
    local opened = state:view()
    Assert.notNil(opened.session, "successful retry installs a live Session")
    state.controller:setSection("Player")
    Assert.isTrue(stateHasRole(state:view(), "integer value"), "successful retry installs a real editable Session")
    Assert.equal(#results, 0, "Retry keeps the editor open after publishing its Session")
    Assert.equal(hostDisposals, 0, "failed and successful attempts never retire the borrowed cache host")
  end, debug.traceback)
  if state then
    pcall(function()
      state:dispose()
    end)
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

function T.tests.open_exposes_borrowed_location_inputs_and_saved_actor_snapshot()
  local fixture = Fixture.new()
  local Composition = require("app.src.saveeditor.SaveEditorComposition")
  local host = { requestMilestone = function() return true end }
  local originalGlobal = SaveFs.global
  SaveFs.global = function(backend)
    Assert.isNil(backend, "the editor uses the isolated composition fixture save backend")
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
  fixture.cleanup()
  if not ok then
    error(graphOrError, 0)
  end

  local graph = graphOrError
  Assert.isNil(graph.mapLoader, "composition leaves headless loader ownership to the location reader")
  Assert.notNil(graph.cacheFs, "location composition borrows the version cache filesystem")
  Assert.notNil(graph.world, "location composition borrows the structural world snapshot")
  Assert.equal(graph.derivedAssets, host, "location composition borrows the opening readiness host")
  Assert.deepEqual(graph.savedObjects, fixture.initial.world.objects, "location composition receives the save's actor snapshot")
  Assert.isFalse(graph.savedObjects == fixture.initial.world.objects, "the actor snapshot is separately owned")
  Assert.isFalse(
    graph.savedObjects.rng == fixture.initial.world.objects.rng,
    "nested saved-object snapshots are copied as well"
  )
end

function T.tests.compatible_legacy_saves_open_without_writes_and_publish_only_after_an_edit()
  local fixture = Fixture.new()
  local State = stateModule()
  local originalGlobal = SaveFs.global
  SaveFs.global = function(backend)
    Assert.isNil(backend, "the editor uses the fixture's isolated save backend")
    return fixture.saveFs
  end

  local legacy = copy(fixture.initial)
  legacy.schema = "g4-game-save-v3"
  legacy.fieldTravel = nil
  legacy.playerData.profile.badges = nil
  local function publishLegacy(record)
    fixture.saveFs:writeLua("games/" .. fixture.saveId .. ".lua", record)
    return assert(fixture.saveFs:read("games/" .. fixture.saveId .. ".lua"))
  end

  local beforeOpen = publishLegacy(legacy)
  local state
  local results = {}
  local host = {
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
  local ok, err = xpcall(function()
    state = State.new({
      versionId = fixture.versionId,
      saveId = fixture.saveId,
      width = 256,
      height = 192,
      derivedAssets = host,
      repositoryRoot = love.filesystem.getSourceBaseDirectory(),
      displayContext = DisplayContext.new({}),
      onResult = function(result)
        results[#results + 1] = result
      end,
    })
    state:update(0)
    Assert.equal(state:view().status, "ready", "the selected authoritative validator accepts quiescent v3 data")
    Assert.equal(state.session:captureCandidate().schema, "g4-game-save-v4")
    state:requestClose("back")
    Assert.equal(#results, 1, "Cancel returns from the editor without publishing the migration")
    Assert.equal(results[1].kind, "main_menu")
    Assert.equal(
      assert(fixture.saveFs:read("games/" .. fixture.saveId .. ".lua")),
      beforeOpen,
      "opening and canceling preserve the exact legacy payload"
    )
    Assert.isNil(fixture.saveFs:read("games/" .. fixture.saveId .. ".lua.bak"), "open does not create a backup")
  end, debug.traceback)
  if state then
    pcall(function()
      state:dispose()
    end)
  end

  if ok then
    SaveFs.global = originalGlobal
    local editedFixture = Fixture.new()
    local editOk, editErr = xpcall(function()
      local editedLegacy = copy(editedFixture.initial)
      editedLegacy.schema = "g4-game-save-v3"
      editedLegacy.fieldTravel = nil
      editedLegacy.playerData.profile.badges = nil
      editedFixture.saveFs:writeLua("games/" .. editedFixture.saveId .. ".lua", editedLegacy)
      SaveFs.global = function(backend)
        Assert.isNil(backend, "the editor uses the second fixture's isolated save backend")
        return editedFixture.saveFs
      end
      local graph = require("app.src.saveeditor.SaveEditorComposition").open({
        versionId = editedFixture.versionId,
        saveId = editedFixture.saveId,
        repositoryRoot = love.filesystem.getSourceBaseDirectory(),
        derivedAssets = host,
      })
      Assert.isTrue(graph.session:setMoney(editedFixture.initialMoney + 1).ok)
      Assert.isTrue(graph.session:save().ok, "a supported edit publishes through the normal save transaction")
      Assert.equal(
        assert(editedFixture.store:load(editedFixture.saveId)).schema,
        "g4-game-save-v4",
        "the first real edit writes the canonical representation"
      )
    end, debug.traceback)
    editedFixture.cleanup()
    if not editOk then
      ok, err = false, editErr
    end
  end

  SaveFs.global = originalGlobal
  fixture.cleanup()
  if not ok then
    error(err, 0)
  end
end

function T.tests.active_invalid_and_mismatched_records_are_refused_without_rewrites()
  local fixture = Fixture.new()
  local Composition = require("app.src.saveeditor.SaveEditorComposition")
  local originalGlobal = SaveFs.global
  SaveFs.global = function(backend)
    Assert.isNil(backend, "the editor uses the fixture's isolated save backend")
    return fixture.saveFs
  end
  local active = copy(fixture.initial)
  active.schema = "g4-game-save-v3"
  active.fieldTravel = nil
  active.playerData.profile.badges = nil
  active.scripts.tasks = {
    {
      taskId = 1,
      taskType = "field_move",
      taskVersion = 1,
      ownerInstanceId = 1,
      environmentId = 1,
      state = {},
    },
  }
  local invalid = copy(fixture.initial)
  invalid.world.variables = "malformed"
  local mismatched = copy(fixture.initial)
  mismatched.saveId = "save-00000999"
  local cases = { active, invalid, mismatched }
  local ok, err = xpcall(function()
    for _, record in ipairs(cases) do
      fixture.saveFs:writeLua("games/" .. fixture.saveId .. ".lua", record)
      local before = assert(fixture.saveFs:read("games/" .. fixture.saveId .. ".lua"))
      local opened = pcall(function()
        Composition.open({
          versionId = fixture.versionId,
          saveId = fixture.saveId,
          repositoryRoot = love.filesystem.getSourceBaseDirectory(),
          derivedAssets = { requestMilestone = function() return true end },
        })
      end)
      Assert.isFalse(opened, "unsafe or mismatched data is refused before Session publication")
      Assert.equal(
        assert(fixture.saveFs:read("games/" .. fixture.saveId .. ".lua")),
        before,
        "failed validation leaves the saved bytes untouched"
      )
    end
  end, debug.traceback)
  SaveFs.global = originalGlobal
  fixture.cleanup()
  if not ok then
    error(err, 0)
  end
end

return T
