-- Product shell acceptance contracts for save editing and safe exit.

local Assert = require("tests.support.Assert")
local App = require("app.src.App")
local Fixture = require("app.tests.support.SaveEditorFixture")
local HgssGame = require("game.hgss.src.HgssGame")
local MainMenuComposition = require("app.src.mainmenu.MainMenuComposition")
local MainMenuState = require("app.src.mainmenu.MainMenuState")
local FieldTextRenderer = require("libs.hgss.src.ui.FieldTextRenderer")
local Session = require("app.src.saveeditor.SaveEditorSession")

local T = {
  metadata = {
    capabilities = { "rom_dump" },
    derivedAssets = { "field-runtime" },
    tags = { "product", "save-editor" },
  },
  tests = {},
}

local function emptyRenderer()
  return {
    draw = function() end,
    dispose = function() end,
  }
end

local function resetApp()
  App.setState(nil)
  App.importer = nil
  App.provisioner = nil
  App.pendingQuiesce = nil
  App.epoch = 0
  App.opts = { dev = false }
end

local function withAppMenu(fn)
  resetApp()
  local fixture = Fixture.new()
  local host = {
    requestMilestone = function(name)
      return name ~= "field-runtime"
    end,
  }
  local provisionerDisposals = 0
  local provisioner = {
    gameHost = function()
      return host
    end,
    startBackgroundWarmup = function() end,
    dispose = function()
      provisionerDisposals = provisionerDisposals + 1
    end,
  }
  App.provisioner = provisioner
  App.epoch = 41

  local originalMenuNew = MainMenuComposition.new
  local originalGameNew = HgssGame.new
  local originalTextNew = FieldTextRenderer.new
  local launches = {}
  MainMenuComposition.new = function(options)
    return MainMenuState.new({
      saveStore = fixture.store,
      readyVersions = { options.versionId },
      width = 800,
      height = 600,
      renderer = emptyRenderer(),
      onResult = options.onResult,
    })
  end
  FieldTextRenderer.new = function()
    return {
      drawText = function() end,
      release = function() end,
    }
  end
  HgssGame.new = function(options)
    launches[#launches + 1] = options
    return emptyRenderer()
  end

  local ok, err = xpcall(function()
    App._launchMenuWithProvisioner("heartgold")
    fn(fixture, host, provisioner, launches, function()
      return provisionerDisposals
    end)
  end, debug.traceback)
  MainMenuComposition.new = originalMenuNew
  HgssGame.new = originalGameNew
  FieldTextRenderer.new = originalTextNew
  resetApp()
  if not ok then
    error(err, 0)
  end
end

function T.tests.edit_action_enters_the_product_editor_and_keeps_the_selected_epoch()
  withAppMenu(function(_, _, provisioner, launches, disposalCount)
    local menu = assert(App.state, "the selected version must open its real Main Menu state")
    Assert.equal(getmetatable(menu).__index, MainMenuState)
    menu:keypressed("right")
    menu:keypressed("return")
    menu:keypressed("return")

    Assert.isFalse(App.state == menu, "Edit must enter the app-owned editor state directly")
    Assert.equal(#launches, 0, "Edit must not construct HgssGame")
    Assert.equal(App.provisioner, provisioner, "the editor borrows the selected provisioner")
    Assert.equal(App.epoch, 41, "opening the editor must preserve the selected cache epoch")
    Assert.equal(disposalCount(), 0, "opening the editor must not retire its borrowed host")
  end)
end

function T.tests.continue_and_delete_keep_their_existing_menu_routes()
  withAppMenu(function(fixture, _, provisioner, launches)
    local menu = assert(App.state)
    menu:keypressed("return")
    Assert.equal(#launches, 1, "the save card's primary action must still Continue")
    Assert.equal(launches[1].entry.kind, "continue")
    Assert.equal(launches[1].entry.saveId, fixture.saveId)
    Assert.equal(App.provisioner, provisioner)

    App._restoreMenuWithProvisioner("heartgold")
    menu = assert(App.state)
    menu:keypressed("right")
    menu:keypressed("return")
    menu:keypressed("down")
    menu:keypressed("return")
    menu:keypressed("right")
    menu:keypressed("return")

    local remaining = fixture.store:listMetadata()
    Assert.equal(#remaining, 0, "the overflow Delete action must still delete its selected save")
    Assert.equal(#launches, 1, "Delete must not enter the retail game")
  end)
end

function T.tests.root_quit_veto_preserves_a_dirty_session_and_selected_host()
  resetApp()
  local originalAppLoad = App.load
  local originalLoveLoad = love.load
  local originalLoveQuit = love.quit
  App.load = function() end
  local entrypoint = assert(loadfile(love.filesystem.getSourceBaseDirectory() .. "/app/main.lua"))
  entrypoint()
  love.load({})
  App.load = originalAppLoad

  local fixture = Fixture.new()
  local session = Session.new({
    record = fixture.initial,
    context = fixture.context,
    saveStore = fixture.store,
    saveFs = fixture.saveFs,
    validateRecord = fixture.validateRecord,
    symbols = fixture.symbols,
  })
  Assert.isTrue(session:setMoney(4200).ok)

  local quitRequests = 0
  local disposed = 0
  App.state = {
    requestClose = function(_, reason)
      quitRequests = quitRequests + 1
      Assert.equal(reason, "quit")
      return session:isDirty()
    end,
    dispose = function()
      disposed = disposed + 1
    end,
  }
  local retired = 0
  App.provisioner = { dispose = function() retired = retired + 1 end }
  local shutdown = 0
  App.service = { shutdown = function() shutdown = shutdown + 1 end }

  local veto = love.quit()
  local dirtyAfterAttempt = session:isDirty()
  local disposalsAfterAttempt, retirementsAfterAttempt, shutdownsAfterAttempt = disposed, retired, shutdown
  App.load = originalAppLoad
  love.load = originalLoveLoad
  love.quit = originalLoveQuit
  resetApp()
  Assert.isTrue(veto, "a dirty editor's quit veto must reach the LÖVE root")
  Assert.equal(quitRequests, 1, "root quit must ask the editor's close policy")
  Assert.equal(disposalsAfterAttempt, 0, "a veto must retain the dirty editor state")
  Assert.equal(retirementsAfterAttempt, 0, "a veto must keep the borrowed cache selection")
  Assert.equal(shutdownsAfterAttempt, 0, "a veto must keep the process service alive")
  Assert.isTrue(dirtyAfterAttempt, "a close attempt must preserve uncommitted session state")
end

function T.tests.rom_drop_is_reported_and_ignored_while_the_editor_is_open()
  resetApp()
  local notices, imports, retired = 0, 0, 0
  local editor = {
    onImportAttempt = function()
      notices = notices + 1
    end,
  }
  App.state = editor
  App.provisioner = { dispose = function() retired = retired + 1 end }
  App.service = { quiesce = function() return nil end }
  local originalStartImport = App._startImport
  App._startImport = function()
    imports = imports + 1
    App.importer = { filedropped = function() end }
  end

  App.filedropped({})
  App._startImport = originalStartImport
  local editorRetained = App.state == editor
  resetApp()

  Assert.equal(notices, 1, "the editor must explain that it ignored the ROM drop")
  Assert.equal(imports, 0, "a dropped ROM must not start or queue provisioning")
  Assert.equal(retired, 0, "the drop must not retire the selected epoch")
  Assert.isTrue(editorRetained, "the editor remains active after a ROM drop")
end

return T
