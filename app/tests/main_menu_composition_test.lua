-- Menu resource acquisition and cleanup stay together at the app boundary.

local Assert = require("tests.support.Assert")

local T = { tests = {} }

local function withCompositionStubs(fn)
  local names = {
    "app.src.mainmenu.MainMenuComposition",
    "libs.storage.src.SaveFs",
    "libs.storage.src.CacheFs",
    "libs.hgss.src.save.GameSaveStore",
    "libs.hgss.src.ui.FieldTextRenderer",
    "libs.ui.src.DisplayContext",
    "app.src.mainmenu.MainMenuRenderer",
    "app.src.mainmenu.MainMenuState",
  }
  local previous = {}
  for _, name in ipairs(names) do
    previous[name] = package.loaded[name]
    package.loaded[name] = nil
  end

  local observed = {
    displayContextCreated = 0,
    textCreated = 0,
    textReleased = 0,
    rendererCreated = 0,
    rendererDisposed = 0,
  }
  local textRenderer = {}
  function textRenderer.new(options)
    Assert.equal(options.cacheFs.versionId, "heartgold")
    observed.textCreated = observed.textCreated + 1
    local text = {}
    function text:release()
      observed.textReleased = observed.textReleased + 1
    end
    return text
  end

  local mainMenuRenderer = {}
  function mainMenuRenderer.new(options)
    Assert.equal(options.versionId, "heartgold")
    if observed.rendererFailure then
      error(observed.rendererFailure, 0)
    end
    Assert.isTrue(options.text ~= nil, "the renderer receives its acquired text resource")
    observed.rendererCreated = observed.rendererCreated + 1
    local renderer = {}
    function renderer:dispose()
      observed.rendererDisposed = observed.rendererDisposed + 1
      options.text:release()
    end
    return renderer
  end

  local mainMenuState = {}
  function mainMenuState.new(options)
    Assert.equal(options.saveStore, "shallow global save store")
    if observed.stateFailure then
      error(observed.stateFailure, 0)
    end
    local state = { renderer = options.renderer }
    function state:dispose()
      self.renderer:dispose()
    end
    return state
  end

  package.loaded["libs.storage.src.SaveFs"] = { global = function() return "global save root" end }
  package.loaded["libs.storage.src.CacheFs"] = {
    forVersion = function(versionId)
      return { versionId = versionId }
    end,
  }
  package.loaded["libs.hgss.src.save.GameSaveStore"] = {
    new = function(root, options)
      Assert.equal(root, "global save root")
      Assert.isNil(options, "product cards use shallow metadata listing")
      return "shallow global save store"
    end,
  }
  package.loaded["libs.hgss.src.ui.FieldTextRenderer"] = textRenderer
  package.loaded["libs.ui.src.DisplayContext"] = {
    new = function()
      observed.displayContextCreated = observed.displayContextCreated + 1
      if observed.displayContextFailure then
        error(observed.displayContextFailure, 0)
      end
      return "display context"
    end,
  }
  package.loaded["app.src.mainmenu.MainMenuRenderer"] = mainMenuRenderer
  package.loaded["app.src.mainmenu.MainMenuState"] = mainMenuState

  local ok, result = xpcall(function()
    fn(observed)
  end, debug.traceback)
  for _, name in ipairs(names) do
    package.loaded[name] = previous[name]
  end
  if not ok then
    error(result, 0)
  end
end

function T.tests.menu_composition_preserves_resource_ownership_on_success_and_failure()
  withCompositionStubs(function(observed)
    local ok, Composition = pcall(require, "app.src.mainmenu.MainMenuComposition")
    Assert.isTrue(ok, "the app must provide a menu composition owner")

    local onResult = function() end
    observed.displayContextFailure = "injected display context construction failure"
    local displayOk, displayError = pcall(Composition.new, {
      versionId = "heartgold",
      onResult = onResult,
    })
    Assert.isFalse(displayOk, "display context failure must propagate")
    Assert.isTrue(tostring(displayError):find(observed.displayContextFailure, 1, true) ~= nil)
    Assert.equal(observed.textCreated, 0, "display context construction precedes resource acquisition")
    observed.displayContextFailure = nil

    local state = Composition.new({ versionId = "heartgold", onResult = onResult })
    Assert.equal(observed.textCreated, 1)
    Assert.equal(observed.rendererCreated, 1)
    state:dispose()
    Assert.equal(observed.rendererDisposed, 1, "the returned state owns renderer disposal")
    Assert.equal(observed.textReleased, 1, "the renderer releases its text exactly once")

    observed.rendererFailure = "injected renderer construction failure"
    local rendererOk, rendererError = pcall(Composition.new, {
      versionId = "heartgold",
      onResult = onResult,
    })
    Assert.isFalse(rendererOk, "renderer failure must propagate")
    Assert.isTrue(tostring(rendererError):find(observed.rendererFailure, 1, true) ~= nil)
    Assert.equal(observed.textReleased, 2, "renderer failure releases the acquired text once")
    Assert.equal(observed.rendererDisposed, 1, "no renderer exists to dispose after its constructor fails")

    observed.rendererFailure = nil
    observed.stateFailure = "injected state construction failure"
    local stateOk, stateError = pcall(Composition.new, {
      versionId = "heartgold",
      onResult = onResult,
    })
    Assert.isFalse(stateOk, "state failure must propagate")
    Assert.isTrue(tostring(stateError):find(observed.stateFailure, 1, true) ~= nil)
    Assert.equal(observed.rendererDisposed, 2, "state failure disposes the created renderer once")
    Assert.equal(observed.textReleased, 3, "renderer disposal releases the owned text once")
  end)
end

return T
