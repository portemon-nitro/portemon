-- Draws the production Storage child through FieldPresentationResources with
-- compiled PC graphics while a replacement wallpaper stays pending.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local FakeCache = require("tests.support.FakeCache")
local FieldPresentationResources = require("game.hgss.src.field.FieldPresentationResources")
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
local PngWriter = require("tests.support.PngEncoder")
local ScreenTopology = require("libs.ui.src.ScreenTopology")
local SharedImagePoolFake = require("tests.support.SharedImagePoolFake")

local T = {}

local REQUIRED_ASSETS = {
  "field-runtime",
  "pc:global",
}

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
    bucket = MonsSave.capture(Party.new():capture(), Lcrng.new(0x12345678):capture(), nil, nil),
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
    storage.ui.partyTrayMove,
    storage.ui.markingPanel,
    storage.ui.wallpaperBar,
    storage.ui.movesPanel,
    storage.ui.itemPanel,
    storage.ui.boxTray,
    storage.ui.depositBoxTray,
    storage.ui.arrows.left,
    storage.ui.arrows.right,
    storage.ui.tray.prev,
    storage.ui.tray.next,
    storage.ui.tray.marker,
    storage.ui.tray.cursor,
    storage.ui.tray.wallpaperCursor,
    storage.ui.tray.label,
  }
  for _, pose in pairs(storage.ui.cursors) do
    for _, frame in ipairs(pose.frames) do
      all[#all + 1] = frame
    end
  end
  all[#all + 1] = storage.ui.infoGlyphs.lv
  all[#all + 1] = storage.ui.infoGlyphs.no
  for _, key in ipairs({ "yesNormal", "yesSelected", "noNormal", "noSelected" }) do
    all[#all + 1] = storage.ui.yesNo[key]
  end
  for _, visual in pairs(storage.wallpaperSwatchArt.variants) do
    all[#all + 1] = visual
  end
  all[#all + 1] = storage.wallpaperSwatchArt.locked
  for _, visual in pairs(storage.boxThumbnail.variants) do
    all[#all + 1] = visual
  end
  all[#all + 1] = storage.boxThumbnail.locked
  for _, visual in pairs(storage.wallpapers) do
    all[#all + 1] = visual
  end
  for _, set in ipairs({ storage.ui.markings, storage.ui.panelMarkings }) do
    for _, pair in pairs(set) do
      all[#all + 1] = pair.clear
      all[#all + 1] = pair.set
    end
  end
  for _, plate in pairs(storage.ui.plates) do
    all[#all + 1] = plate.left
    all[#all + 1] = plate.middle
    all[#all + 1] = plate.right
  end
  for _, style in pairs(storage.ui.windowFrames) do
    if type(style) == "table" and style.image == nil then
      for _, visual in pairs(style) do
        if type(visual) == "table" and type(visual.image) == "string" then
          all[#all + 1] = visual
        end
      end
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
  -- The selected mon's top-screen info borrows the shared portrait and
  -- move-icon families; seed the fixture's exact selector and types.
  local portraitEntries = {}
  for _, gender in ipairs({ "male", "female" }) do
    for _, shiny in ipairs({ "plain", "shiny" }) do
      portraitEntries["CHIKORITA/f0/" .. gender .. "/" .. shiny] =
        { pageId = 0, frames = { { x = 0, y = 0, width = 80, height = 80 } }, width = 80, height = 80 }
    end
  end
  cache:write("data/generated/mon/portraits.lua", "return { entries = {" .. (function()
    local parts = {}
    for selector in pairs(portraitEntries) do
      parts[#parts + 1] = string.format(
        "[%q] = { pageId = 0, frames = { { x = 0, y = 0, width = 80, height = 80 } }, width = 80, height = 80 }",
        selector
      )
    end
    return table.concat(parts, ",")
  end)() .. "}, pages = { [0] = { width = 80, height = 80 } } }")
  local portraitPath = "assets/generated/mon/portraits/0.png"
  cache:write(portraitPath, solidPng(10, 20, 30, 80, 80))
  local typePaths = {}
  for _, typeKey in ipairs({ "grass", "poison" }) do
    local path = "assets/generated/move-icons/type-" .. typeKey .. ".png"
    typePaths[#typePaths + 1] = path
    cache:write(path, solidPng(40, 50, 60, 32, 16))
  end
  cache:write(
    "data/generated/move-icons/manifest.lua",
    "return { schema = 'g4-move-icons-v1', types = { grass = { image = '"
      .. typePaths[1]
      .. "', width = 32, height = 16, offset = { x = -16, y = -8 } }, poison = { image = '"
      .. typePaths[2]
      .. "', width = 32, height = 16, offset = { x = -16, y = -8 } } }, categories = {} }"
  )

  local inner = SharedImagePoolFake.new()
  local seeded = {}
  for _, visual in ipairs(pixelVisualPaths(manifest)) do
    seeded[visual.image] = true
    local bytes = assert(cache:read(visual.image), "fixture writes every visual")
    local image = love.graphics.newImage(love.filesystem.newFileData(bytes, visual.image))
    inner:seedPhysical(visual.image, PIXEL_SAMPLER, {
      image = image,
      width = image:getWidth(),
      height = image:getHeight(),
    })
  end
  for _, path in ipairs({ portraitPath, typePaths[1], typePaths[2] }) do
    if not seeded[path] then
      local bytes = assert(cache:read(path), "fixture writes the info images")
      local image = love.graphics.newImage(love.filesystem.newFileData(bytes, path))
      inner:seedPhysical(path, PIXEL_SAMPLER, {
        image = image,
        width = image:getWidth(),
        height = image:getHeight(),
      })
    end
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
    createHallOfFame = function()
      error("Hall of Fame is unused", 0)
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
    partyScreenRenderer = {},
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
      local ready, failure = FieldPresentationResources.preparePcApplication(preparation, status, { monCatalog = {} })
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
