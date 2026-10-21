-- Production Save Editor smoke: open a save, publish one edit, then verify the dirty state clears.

local Assert = require("tests.support.Assert")
local DisplayContext = require("libs.ui.src.DisplayContext")
local LayoutGeometry = require("libs.ui.src.LayoutGeometry")
local SaveFs = require("libs.storage.src.SaveFs")
local Fixture = require("app.tests.support.SaveEditorFixture")

local T = {
  metadata = {
    capabilities = { "rom_dump" },
    derivedAssets = {
      "items:global",
      "bag:global",
      "mon-catalog:global",
      "field-font:global",
      "field-ui:global",
      "world-catalog:global",
      "map:60",
      "map-data:60",
    },
    tags = { "save-editor", "production" },
  },
  tests = {},
}

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
      error("save editor smoke attempted love.graphics." .. name)
    end
  end
  local ok, err = xpcall(fn, debug.traceback)
  for _, name in ipairs(names) do
    graphics[name] = originals[name]
  end
  if not ok then
    error(err, 0)
  end
  Assert.equal(attempts, 0, "the Save Editor smoke stops before GPU rendering")
end

local function activateSave(state)
  local view = state:view()
  local target = assert(view.layout.targets.save, "the product layout exposes Save")
  local pane
  for _, candidate in ipairs(assert(view.presentation).panes) do
    if candidate.interactive then
      pane = candidate
      break
    end
  end
  local interactivePane = assert(pane, "the editor publishes an interactive pane")
  local hostX, hostY = LayoutGeometry.logicalToHost(
    interactivePane.placement,
    target.rect.x + target.rect.width / 2,
    target.rect.y + target.rect.height / 2
  )
  state:mousepressed(hostX, hostY, 1)
  state:mousereleased(hostX, hostY, 1)
end

function T.tests.production_editor_saves_an_edit()
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
      versionId = fixture.initial.versionId,
      saveId = fixture.saveId,
      width = 640,
      height = 480,
      derivedAssets = readyHost(),
      repositoryRoot = love.filesystem.getSourceBaseDirectory(),
      displayContext = DisplayContext.new({}),
      onResult = function() end,
    })
    state:update(0)
    Assert.equal(state:view().status, "ready", "production composition opens the isolated save")

    withoutRendering(function()
      local money = fixture.initial.playerData.profile.money + 1
      Assert.isTrue(state.session:setMoney(money).ok, "the production session stages a money edit")
      Assert.isTrue(state:view().dirty, "the staged edit appears dirty")
      activateSave(state)
      Assert.equal(assert(fixture.store:load(fixture.saveId)).playerData.profile.money, money)
      Assert.isFalse(state:view().dirty, "saving clears the dirty state")
    end)
  end, debug.traceback)

  if state ~= nil then
    pcall(function()
      state:dispose()
    end)
  end
  SaveFs.global = originalGlobal
  if not ok then
    error(err, 0)
  end
end

return T
