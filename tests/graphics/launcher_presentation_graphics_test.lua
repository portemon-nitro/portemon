-- Real offscreen graphics smoke for the ROM-independent launcher resources.
-- It proves the pinned fonts/icons and neutral loader draw without a ROM or
-- generated cache; visual comparison and audio provenance remain manual gates.

local Assert = require("tests.support.Assert")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local Sha256 = require("libs.script.src.Sha256")
local RepoFs = require("libs.storage.src.RepoFs")
local LauncherAssets = require("app.src.launcher.LauncherAssets")

local T = {}

local FONT_HASHES = {
  ["assets/fonts/galmuri/Galmuri11.ttf"] = "e24256f42e43713d2ea086a1e1669d78b968f5b3cc547e5c157f0606ffa5def1",
  ["assets/fonts/galmuri/Galmuri11-Bold.ttf"] = "45d901e379138dd91873af157640f60aa4cf6beaa885c3efd2a8c279e039a237",
  ["assets/fonts/mplus1p/MPLUS1p-Regular.ttf"] = "2f294ad496432b1608f070d310e3aa2adcf1de4af429f4901df97ec4bd361ed1",
}

local REQUIRED_FILES = {
  "assets/fonts/galmuri/Galmuri11.ttf",
  "assets/fonts/galmuri/Galmuri11-Bold.ttf",
  "assets/fonts/galmuri/LICENSE.txt",
  "assets/fonts/mplus1p/MPLUS1p-Regular.ttf",
  "assets/fonts/mplus1p/OFL.txt",
  "assets/ui/launcher/LICENSE.txt",
  "assets/ui/launcher/icons/add-game.png",
  "assets/ui/launcher/icons/play.png",
  "assets/ui/launcher/icons/back.png",
  "assets/ui/launcher/icons/check.png",
  "assets/ui/launcher/icons/warning.png",
  "assets/ui/launcher/icons/close.png",
  "assets/audio/launcher/boot.ogg",
  "assets/audio/launcher/focus.ogg",
  "assets/audio/launcher/confirm.ogg",
  "assets/audio/launcher/back.ogg",
  "assets/audio/launcher/error.ogg",
}

local function render(scope, width, height, draw)
  local canvas = scope:own(love.graphics.newCanvas(width, height, { format = "rgba8", readable = true }))
  love.graphics.push("all")
  love.graphics.setCanvas(canvas)
  love.graphics.clear(0, 0, 0, 0)
  draw()
  love.graphics.setCanvas()
  love.graphics.pop()
  return scope:own(canvas:newImageData())
end

function T.runtime_assets_exist_at_the_launcher_contract_paths()
  local repo = RepoFs.new(love.filesystem.getSourceBaseDirectory())
  for _, path in ipairs(REQUIRED_FILES) do
    local bytes = repo:read(path)
    Assert.isTrue(type(bytes) == "string" and #bytes > 0, "required launcher asset is missing: " .. path)
    local data = LauncherAssets.read(path)
    Assert.notNil(data, "production asset data loads: " .. path)
    Assert.equal(data:getString(), bytes, "production data preserves repository bytes: " .. path)
  end
  for path, expected in pairs(FONT_HASHES) do
    local bytes = assert(repo:read(path), "pinned font is readable")
    Assert.equal(Sha256.hex(bytes), expected, "pinned font bytes match the asset contract: " .. path)
  end
end

function T.renderer_draws_all_button_states_with_bundled_fonts_and_icons(scope)
  local LauncherRenderer = require("app.src.launcher.LauncherRenderer")
  local renderer = LauncherRenderer.new()
  scope:own({
    release = function()
      renderer:dispose()
    end,
  })
  local states = {
    { focused = false, pressed = false, disabled = false },
    { focused = true, pressed = false, disabled = false },
    { focused = true, pressed = true, disabled = false },
    { focused = false, pressed = false, disabled = true },
  }
  local frames = {}
  for index, visual in ipairs(states) do
    frames[index] = render(scope, 128, 48, function()
      renderer:drawButton({ x = 0, y = 0, width = 128, height = 44 }, "Portémon Nitro", "play", visual)
    end):getString()
  end
  Assert.isTrue(frames[1] ~= frames[2], "focus changes the rendered button")
  Assert.isTrue(frames[2] ~= frames[3], "pressed treatment changes the rendered button")
  Assert.isTrue(frames[1] ~= frames[4], "disabled treatment changes the rendered button")
end

function T.renderer_constructor_failure_releases_every_prior_host_resource(scope)
  local LauncherRenderer = require("app.src.launcher.LauncherRenderer")
  local graphics = love.graphics
  local originalNewFont, originalNewImage = graphics.newFont, graphics.newImage
  local acquired = {}
  local images = 0
  local function track(resource)
    local proxy = { released = 0 }
    function proxy:release()
      self.released = self.released + 1
      resource:release()
    end
    function proxy:getWidth()
      return resource:getWidth()
    end
    function proxy:getHeight()
      return resource:getHeight()
    end
    function proxy:getDimensions()
      return resource:getDimensions()
    end
    function proxy:getWrap(...)
      return resource:getWrap(...)
    end
    function proxy:setFilter(...)
      return resource:setFilter(...)
    end
    acquired[#acquired + 1] = proxy
    return proxy
  end
  graphics.newFont = function(...)
    return track(assert(originalNewFont(...)))
  end
  graphics.newImage = function(...)
    images = images + 1
    if images == 2 then
      error("synthetic icon acquisition failure", 0)
    end
    return track(assert(originalNewImage(...)))
  end
  local ok, failure = pcall(LauncherRenderer.new)
  graphics.newFont, graphics.newImage = originalNewFont, originalNewImage
  Assert.isFalse(ok, "a partial renderer construction fails instead of publishing a half-usable owner")
  Assert.isTrue(tostring(failure):find("icon acquisition failure", 1, true) ~= nil)
  Assert.isTrue(#acquired >= 2, "the failure happens after earlier resources were acquired")
  for _, resource in ipairs(acquired) do
    Assert.equal(resource.released, 1, "partial construction releases each prior resource exactly once")
  end
end

function T.neutral_loader_animates_and_does_not_release_the_borrowed_renderer(scope)
  local LauncherRenderer = require("app.src.launcher.LauncherRenderer")
  local LauncherLoadingPresentation = require("app.src.launcher.LauncherLoadingPresentation")
  local renderer = LauncherRenderer.new()
  local cancellations = 0
  local presentation = LauncherLoadingPresentation.new({
    renderer = renderer,
    versionId = "heartgold",
    label = "HeartGold",
    width = 320,
    height = 240,
    onCancel = function()
      cancellations = cancellations + 1
    end,
  })
  scope:own({
    release = function()
      presentation:dispose()
    end,
  })
  local first = render(scope, 320, 240, function()
    presentation:draw()
  end):getString()
  presentation:update(0.12)
  local second = render(scope, 320, 240, function()
    presentation:draw()
  end):getString()
  Assert.isTrue(first ~= second, "the four-square loader advances on its 120 ms beat")
  presentation:dispose()
  presentation:dispose()
  local afterDispose = render(scope, 320, 240, function()
    presentation:draw()
  end):getString()
  Assert.equal(afterDispose, string.rep("\0", 320 * 240 * 4), "a disposed loader draws nothing")
  Assert.equal(cancellations, 0, "drawing and disposal never invoke the borrowed cancellation route")
  renderer:drawButton({ x = 0, y = 0, width = 128, height = 44 }, "Play", "play", {})
  renderer:dispose()
end

function T.dual_surface_selection_draws_summary_and_auxiliary_actions(scope)
  local LauncherRenderer = require("app.src.launcher.LauncherRenderer")
  local GameSelectState = require("app.src.launcher.GameSelectState")
  local DisplayContext = require("libs.ui.src.DisplayContext")
  local renderer = LauncherRenderer.new()
  local context = DisplayContext.new({
    graphics = love.graphics,
    topologyProvider = function()
      return {
        surfaces = {
          {
            id = "main",
            role = "world",
            rect = { x = 0, y = 0, width = 256, height = 192 },
            touch = true,
          },
          {
            id = "aux",
            role = "auxiliary",
            rect = { x = 256, y = 0, width = 256, height = 192 },
            touch = true,
          },
        },
      }
    end,
  })
  local library = GameSelectState.new({
    games = {
      { gameId = "heartgold", versionId = "heartgold", label = "HeartGold", ready = true, hasSave = true },
    },
    initialGameId = "heartgold",
    renderer = renderer,
    audio = { play = function() end },
    displayContext = context,
    width = 512,
    height = 192,
    onPlay = function() end,
    onPick = function() end,
    onCancelImport = function() end,
    onDismissError = function() end,
    onQuit = function() end,
  })
  scope:own({
    release = function()
      library:dispose()
    end,
  })
  local pixels = render(scope, 512, 192, function()
    library:draw()
  end)
  local _, _, _, primaryAlpha = pixels:getPixel(128, 96)
  local _, _, _, auxiliaryAlpha = pixels:getPixel(384, 96)
  Assert.isTrue(primaryAlpha > 0, "the primary summary surface paints")
  Assert.isTrue(auxiliaryAlpha > 0, "the auxiliary interactive surface paints")
  renderer:dispose()
end

return GraphicsSmoke.suite(T)
