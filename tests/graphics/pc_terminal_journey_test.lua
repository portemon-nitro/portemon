-- Draws the production Storage child through FieldPresentationResources with
-- compiled PC graphics over each supported display arrangement.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local FieldState = require("game.hgss.src.field.FieldState")
local FieldStatePresentationFixture = require("tests.support.FieldStatePresentationFixture")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local ScreenTopology = require("libs.ui.src.ScreenTopology")

local T = {}

local REQUIRED_ASSETS = {
  "field-runtime",
  "audio-bank:700",
  "audio-bank:702",
  "audio-bank:730",
  "audio-bank:759",
  "map-data:7",
  "map:7",
  "pc:global",
}

local function savedField()
  local derivedAssets = FieldStatePresentationFixture.iconHost().derivedAssets
  local game = AcceptanceHarness.new():boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = "MAP_BURNED_TOWER_1F",
    save = "fresh",
    fieldOptions = { derivedAssets = derivedAssets },
  })
  local ok, record = pcall(function()
    game:waitForFieldEntry()
    return assert(game.runtime:captureGameSave(), "the settled production field can be captured")
  end)
  game:close()
  if not ok then
    error(record, 0)
  end
  return record, derivedAssets
end

local function display(width, height)
  return {
    width = width,
    height = height,
    topology = ScreenTopology.oneDisplay({
      id = "main",
      rect = { x = 0, y = 0, width = width, height = height },
      touch = true,
      role = "world",
    }),
  }
end

local function assertPainted(data, width, height, label)
  local painted = 0
  for y = 0, height - 1, 8 do
    for x = 0, width - 1, 8 do
      local _, _, _, alpha = data:getPixel(x, y)
      if alpha > 0 then
        painted = painted + 1
      end
    end
  end
  Assert.isTrue(painted > 8, label .. " draws compiled Storage pixels")
end

local function assertTransparent(data, width, height, label)
  for y = 0, height - 1, 8 do
    for x = 0, width - 1, 8 do
      local _, _, _, alpha = data:getPixel(x, y)
      Assert.equal(alpha, 0, label .. " has no fixed surface without a 1x fit")
    end
  end
end

function T.production_storage_draws_with_real_pc_graphics_across_layouts(scope)
  local record, derivedAssets = savedField()
  local state = FieldState.new(record, { derivedAssets = derivedAssets })
  local runtime = state.runtime
  local host = assert(runtime.pcApplicationHost, "the production runtime owns the PC child host")
  local handle = host:open({ app = "storage", mode = 0 })
  local layouts = {
    { label = "native-like", display = display(256, 192) },
    { label = "wide", display = display(512, 192) },
    { label = "tall", display = display(192, 512) },
    {
      label = "dual-display",
      display = {
        width = 512,
        height = 384,
        topology = ScreenTopology.dualDisplay(
          { id = "upper", rect = { x = 0, y = 0, width = 256, height = 192 }, touch = false, role = "world" },
          { id = "lower", rect = { x = 256, y = 0, width = 256, height = 192 }, touch = true, role = "auxiliary" }
        ),
      },
    },
  }

  local ok, err = xpcall(function()
    for _, layout in ipairs(layouts) do
      local measured = layout.display
      runtime:resizePresentation(measured.width, measured.height, measured.topology)
      host:setPresentationReady(handle, true)
      host:step(handle, {})
      local ready, failure = state.presentationResources:preparePcApplication(host:status(), runtime)
      Assert.isNil(failure, layout.label .. " prepares without a graphics failure")
      Assert.isTrue(ready, layout.label .. " has all visible Storage icons ready")
      host:setPresentationReady(handle, ready)

      local canvas = scope:own(love.graphics.newCanvas(measured.width, measured.height))
      love.graphics.setCanvas(canvas)
      love.graphics.clear(0, 0, 0, 0)
      state.presentationResources:drawPcApplication(host, runtime)
      love.graphics.setCanvas()
      local imageData = scope:own(canvas:newImageData())
      if layout.label == "tall" then
        assertTransparent(imageData, measured.width, measured.height, layout.label)
      else
        assertPainted(imageData, measured.width, measured.height, layout.label)
      end
    end
  end, debug.traceback)
  host:dispose()
  state:dispose()
  if not ok then
    error(err, 0)
  end
end

local suite = GraphicsSmoke.suite(T, { capabilities = { "graphics", "rom_dump" }, tags = { "field", "pc" } })
suite.metadata.derivedAssets = REQUIRED_ASSETS
return suite
