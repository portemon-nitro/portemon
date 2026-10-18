-- Draws the production Storage child through FieldPresentationResources with
-- compiled PC graphics over each supported display arrangement.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local CacheFs = require("libs.storage.src.CacheFs")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local FakeCache = require("tests.support.FakeCache")
local FieldPresentationResources = require("game.hgss.src.field.FieldPresentationResources")
local FieldState = require("game.hgss.src.field.FieldState")
local FieldStatePresentationFixture = require("tests.support.FieldStatePresentationFixture")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local HgssBagService = require("libs.hgss.src.items.HgssBagService")
local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
local ItemFixture = require("libs.items.tests.item_fixture")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local MonsSave = require("libs.mons.src.MonsSave")
local Party = require("libs.mons.src.Party")
local PcApplicationHost = require("game.hgss.src.pc.PcApplicationHost")
local PcPresentationFixture = require("tests.support.PcPresentationFixture")
local PcStorageRenderer = require("libs.hgss.src.ui.PcStorageRenderer")
local PcStorageState = require("game.hgss.src.pc.StorageScreenState")
local PngWriter = require("libs.assets.src.PngWriter")
local ScreenTopology = require("libs.ui.src.ScreenTopology")
local SharedImagePoolFake = require("tests.support.SharedImagePoolFake")

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
      -- Readiness now waits for the admitted Storage visuals beside the
      -- mon icons: advance preparation the way the field update does
      -- until the host turns ready, then present the admitted view.
      local ready, failure
      local deadline = os.clock() + 120
      while true do
        ready, failure = state.presentationResources:preparePcApplication(host:status(), runtime)
        if ready or failure ~= nil then
          break
        end
        Assert.isTrue(os.clock() < deadline, layout.label .. " admits its Storage visuals without stalling")
        if love.timer ~= nil and love.timer.sleep ~= nil then
          love.timer.sleep(0.005)
        end
      end
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

-- A delayed wallpaper keeps real admitted pixels on the canvas: the
-- production Storage child draws through the real host onto a real canvas
-- while its replacement waits, using fixture wallpapers in distinct solid
-- colors (red admitted, green replacement) so the repainted surface proves
-- which view is presented. The shared image owner is synchronous with
-- main-thread-realized images, isolating the presentation transaction
-- from worker timing.
local PIXEL_SAMPLER = { wrapX = "clamp", wrapY = "clamp", minFilter = "nearest", magFilter = "nearest" }

local function pixelMonService()
  local catalog = CatalogFixture.makeCatalog()
  local service = HgssMonService.new({
    catalog = catalog,
    bucket = MonsSave.capture(
      Party.new():capture(),
      Lcrng.new(0x12345678):capture(),
      nil,
      nil
    ),
    profile = CatalogFixture.profile(),
    game = "heartgold",
    language = "english",
    charmap = CatalogFixture.CHARMAP,
    games = CatalogFixture.GAMES,
    languages = CatalogFixture.LANGUAGES,
    items = CatalogFixture.ITEMS,
    balls = CatalogFixture.BALLS,
  })
  local factory = CatalogFixture.makeFactory(0x87654321, catalog)
  Assert.isTrue(service:addMon(factory:createNormal(CatalogFixture.normalRequest({ species = "CHIKORITA" }))))
  return service
end

local function solidPng(red, green, blue, width, height)
  return PngWriter.encode(width, height, string.rep(string.char(red, green, blue, 255), width * height))
end

local function pixelVisualPaths(manifest)
  local storage = manifest.storage
  local all = {
    storage.backgrounds.default,
    storage.ui.boxPane,
    storage.ui.infoPane,
    storage.ui.partyTray,
    storage.ui.markingPanel,
    storage.ui.wallpaperBar,
    storage.ui.arrows.left,
    storage.ui.arrows.right,
    storage.ui.cursors.browse,
    storage.ui.cursors.menu,
    storage.ui.cursors.carry,
  }
  for _, visual in pairs(storage.wallpapers) do
    all[#all + 1] = visual
  end
  for _, pair in pairs(storage.ui.markings) do
    all[#all + 1] = pair.clear
    all[#all + 1] = pair.set
  end
  for _, style in pairs(storage.ui.windowFrames) do
    for _, visual in pairs(style) do
      all[#all + 1] = visual
    end
  end
  return all
end

local function countCanvasColors(data, width, height)
  local red, green, painted = 0, 0, 0
  for y = 0, height - 1, 4 do
    for x = 0, width - 1, 4 do
      local r, g, b, alpha = data:getPixel(x, y)
      if alpha > 0.5 then
        painted = painted + 1
        if r > 0.75 and g < 0.35 and b < 0.35 then
          red = red + 1
        elseif g > 0.75 and r < 0.35 and b < 0.35 then
          green = green + 1
        end
      end
    end
  end
  return red, green, painted
end

function T.pending_wallpaper_replacement_repaints_the_admitted_pixels(scope)
  local manifest = PcPresentationFixture.manifest()
  manifest.text = { banks = { [24] = {}, [25] = {} } }
  for bankId, bank in pairs(manifest.text.banks) do
    for messageId = 0, 100 do
      bank[messageId] = { { kind = "glyph", text = "b" .. bankId .. ":" .. messageId } }
    end
  end
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local white = PngWriter.encode(1, 1, string.char(255, 255, 255, 255))
  for _, visual in ipairs(pixelVisualPaths(manifest)) do
    cache:write(visual.image, white)
  end
  cache:write(manifest.storage.wallpapers[0].image, solidPng(255, 0, 0, 256, 192))
  cache:write(manifest.storage.wallpapers[2].image, solidPng(0, 255, 0, 256, 192))

  local inner = SharedImagePoolFake.new()
  for _, visual in ipairs(pixelVisualPaths(manifest)) do
    local bytes = assert(cache:read(visual.image), "fixture writes every visual")
    local image = love.graphics.newImage(love.filesystem.newFileData(bytes, visual.image))
    inner:seedPhysical(visual.image, PIXEL_SAMPLER, {
      image = image,
      width = image:getWidth(),
      height = image:getHeight(),
    })
  end
  local pendingPaths = {}
  local tokenPaths = {}
  local pool = {}
  function pool:request(path, sampler, priority)
    local token = inner:request(path, sampler, priority)
    tokenPaths[token] = path
    return token
  end
  function pool:poll(token)
    if pendingPaths[tokenPaths[token]] then
      return "pending"
    end
    return inner:poll(token)
  end
  function pool:acquire(token)
    return inner:acquire(token)
  end
  function pool:release(lease)
    return inner:release(lease)
  end
  function pool:cancel(token)
    tokenPaths[token] = nil
    return inner:cancel(token)
  end
  function pool:prune()
    return inner:prune()
  end
  function pool:stats()
    return inner:stats()
  end

  local renderer = PcStorageRenderer.new({
    graphics = love.graphics,
    cacheFs = cache,
    manifest = manifest,
    text = {
      drawText = function() end,
      textWidth = function()
        return 0
      end,
      windowBackgroundColor = function()
        return { 1, 1, 1, 1 }
      end,
    },
    imagePool = pool,
  })
  local mons = pixelMonService()
  local child = PcStorageState.new({
    mode = 1,
    mons = mons,
    bag = HgssBagService.new({ catalog = ItemFixture.makeCatalog() }),
    manifest = PcPresentationFixture.manifest(),
    measureDisplay = function()
      return {
        width = 512,
        height = 192,
        topology = ScreenTopology.oneDisplay({
          id = "main",
          rect = { x = 0, y = 0, width = 512, height = 192 },
          role = "world",
          touch = true,
        }),
        pixelRatio = 1,
        signature = "pc-pixel-test:wide",
      }
    end,
    audio = { play = function() end },
    dexNumber = function() end,
    charmap = CatalogFixture.CHARMAP,
    icons = {},
    portraits = {},
    childFactories = {},
  })
  local host = PcApplicationHost.new({
    createStorage = function()
      return child
    end,
    createMailbox = function()
      error("mailbox unused", 0)
    end,
    createPhotoAlbum = function()
      error("photo album unused", 0)
    end,
  })
  local handle = host:open({ app = "storage", mode = 1 })
  local preparation = setmetatable({
    monIconProvider = {
      prepareKeys = function()
        return true
      end,
    },
    itemIconProvider = {},
    storageRenderer = renderer,
    mailboxRenderer = {},
    photoAlbumRenderer = {},
    textRenderer = {},
    windowRenderer = {},
    bagRenderer = {},
    heroRenderer = {},
    applicationFrameIndex = 3,
  }, { __index = FieldPresentationResources })
  local resources = {
    storageRenderer = renderer,
    windowRenderer = {
      drawWindow = function(_, box)
        love.graphics.setColor(1, 1, 1, 1)
        love.graphics.rectangle("fill", box.x, box.y, box.width, box.height)
      end,
      drawStandardWindow = function(_, box)
        love.graphics.setColor(1, 1, 1, 1)
        love.graphics.rectangle("fill", box.x, box.y, box.width, box.height)
      end,
    },
    applicationFrameIndex = 3,
  }

  local ok, err = xpcall(function()
    local function tick(events)
      host:step(handle, events or {})
      local status = assert(host:status(), "the open child publishes its status")
      local ready, failure =
        FieldPresentationResources.preparePcApplication(preparation, status, { monCatalog = {} })
      host:setPresentationReady(handle, ready)
      return ready, failure
    end
    local function admit(message)
      local ready, failure = false, nil
      for _ = 1, 200 do
        ready, failure = tick({})
        if ready then
          break
        end
        Assert.isNil(failure, message .. ": admission reports no failure while pending")
      end
      Assert.isTrue(ready, message .. ": the box admits before drawing")
      Assert.isNil(failure, message .. ": admission reports no failure")
    end
    local canvas = scope:own(love.graphics.newCanvas(512, 192))
    local function present()
      love.graphics.setCanvas(canvas)
      love.graphics.clear(0, 0, 0, 0)
      host:draw(resources)
      love.graphics.setCanvas()
      return scope:own(canvas:newImageData())
    end

    admit("first open")
    local admittedRed, admittedGreen, admittedPainted = countCanvasColors(present(), 512, 192)
    Assert.isTrue(admittedRed > 200, "the admitted box paints its red wallpaper")
    Assert.equal(admittedGreen, 0, "the admitted box paints no replacement pixels")
    Assert.isTrue(admittedPainted > 200, "the admitted box paints a full surface")
    local admittedPlan = host:presentationPlan()
    Assert.notNil(admittedPlan, "the admitted box publishes its plan")

    pendingPaths[manifest.storage.wallpapers[2].image] = true
    local ready, failure = tick({ { type = "action", action = "wallpaper" } })
    Assert.isTrue(ready, "opening the chooser keeps the admitted view ready")
    ready, failure = tick({ { type = "wallpaper_choice", id = 2 } })
    Assert.isTrue(ready, "highlighting a choice keeps the admitted view ready")
    ready, failure = tick({ { type = "submit" } })
    Assert.isFalse(ready, "a pending wallpaper keeps the host unready")
    Assert.isNil(failure, "a pending wallpaper reports no failure")
    for _ = 1, 3 do
      ready, failure = tick({})
      Assert.isFalse(ready, "the replacement stays pending")
      Assert.isNil(failure, "the replacement reports no failure")
      local red, green, painted = countCanvasColors(present(), 512, 192)
      Assert.equal(red, admittedRed, "pending frames repaint the admitted wallpaper pixels")
      Assert.equal(green, 0, "pending frames paint no replacement pixels")
      Assert.isTrue(painted > 200, "pending frames keep a full surface")
      Assert.isTrue(host:presentationPlan() == admittedPlan, "pending frames keep the admitted plan")
    end

    pendingPaths[manifest.storage.wallpapers[2].image] = nil
    admit("wallpaper recovery")
    local red, green, painted = countCanvasColors(present(), 512, 192)
    Assert.isTrue(green > 200, "the admitted replacement paints its green wallpaper")
    Assert.equal(red, 0, "the admitted replacement paints no retired pixels")
    Assert.isTrue(painted > 200, "the admitted replacement paints a full surface")
  end, debug.traceback)
  host:dispose()
  renderer:dispose()
  if not ok then
    error(err, 0)
  end
end

local suite = GraphicsSmoke.suite(T, { capabilities = { "graphics", "rom_dump" }, tags = { "field", "pc" } })
suite.metadata.derivedAssets = REQUIRED_ASSETS
return suite
