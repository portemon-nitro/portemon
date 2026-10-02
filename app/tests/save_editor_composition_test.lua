-- Opening-state lifecycle contracts over the borrowed asset host.

local Assert = require("tests.support.Assert")
local Fixture = require("app.tests.support.SaveEditorAcceptanceFixture")
local DisplayContext = require("libs.ui.src.DisplayContext")
local SaveFs = require("libs.storage.src.SaveFs")

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
      return nil
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
        return { state = "failed", failure = "derived cache preparation failed" }
      end
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
    failed = false
    state:keypressed("return")
    state:update(0)
    Assert.isTrue(hostRequests > 1, "Retry requests readiness again from the borrowed host")
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

return T
