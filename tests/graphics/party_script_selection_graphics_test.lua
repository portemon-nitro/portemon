-- Script party pixels: an open script-owned selection paints native
-- party chrome through the real party renderer from its live host
-- status, proving the selector is visible. Real manifest, real screen,
-- real service; a test-local icon provider serves the fixture atlas
-- quad for every key (icon resolution belongs to the provider tests).
-- ROM and graphics capabilities required; stops at pixel reads.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local FieldUiFixture = require("tests.support.FieldUiFixture")
local GameVersion = require("romdump.src.source.GameVersion")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local MonCache = require("libs.assets.src.MonCache")
local PreparedMonIcons = require("tests.support.PreparedMonIcons")
local MonsSave = require("libs.mons.src.MonsSave")
local Party = require("libs.mons.src.Party")
local PartyCache = require("libs.assets.src.PartyCache")
local PartyScreenLayout = require("libs.hgss.src.ui.PartyScreenLayout")
local PartyScreenRenderer = require("libs.hgss.src.ui.PartyScreenRenderer")
local PngWriter = require("libs.assets.src.PngWriter")
local RomImporter = require("romdump.src.source.RomImporter")
local ScreenTopology = require("libs.ui.src.ScreenTopology")
local FieldTextRenderer = require("libs.hgss.src.ui.FieldTextRenderer")

local HOST_MODULE = "game.hgss.src.field.PartySelectionHost"

local T = {}

local function readyVersions()
  local versions = {}
  for _, versionId in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(versionId) then
      local cacheFs = CacheFs.forVersion(versionId)
      local marker = cacheFs:read(PartyCache.markerPath())
      if marker ~= nil and PartyCache.isReady(cacheFs, marker) then
        versions[#versions + 1] = versionId
      end
    end
  end
  return versions
end

local function openService()
  local catalog = CatalogFixture.makeCatalog()
  return HgssMonService.new({
    catalog = catalog,
    bucket = MonsSave.capture(Party.new():capture(), Lcrng.new(0xEEEEEEEE):capture()),
    profile = CatalogFixture.profile(),
    game = "heartgold",
    language = "english",
    charmap = CatalogFixture.CHARMAP,
    games = CatalogFixture.GAMES,
    languages = CatalogFixture.LANGUAGES,
    items = CatalogFixture.ITEMS,
    balls = CatalogFixture.BALLS,
  })
end

local function give(service, species)
  Assert.isTrue(
    service:giveMon({
      species = species,
      level = 5,
      heldItem = "NONE",
      form = 0,
      location = 7,
      date = CatalogFixture.metDate(),
    }),
    "setup gift must enter the party"
  )
end

local function quantize(value)
  return math.floor(value * 255 + 0.5)
end

function T.open_selection_paints_native_chrome(scope)
  for _, versionId in ipairs(readyVersions()) do
    local service = openService()
    give(service, "CHIKORITA")
    give(service, "TOTODILE")
    local Host = assert(require(HOST_MODULE))
    local cacheFs = CacheFs.forVersion(versionId)
    local host = Host.new({
      service = service,
      manifest = PartyCache.loadManifest(cacheFs),
      measureDisplay = function()
        return {
          width = 256,
          height = 192,
          topology = ScreenTopology.oneDisplay({
            id = "main",
            rect = { x = 0, y = 0, width = 256, height = 192 },
            role = "world",
            touch = true,
          }),
          pixelRatio = 1,
          signature = "stub:256x192",
        }
      end,
      uiManifest = FieldUiFixture.manifest(),
      prepareIcons = function(_)
        return true
      end,
      cancelIconPreparation = function() end,
    })
    local handle = host:open({ focus = 0, allowCancel = true, policy = "occupied" })
    host:step(handle, {})
    host:step(handle, { { type = "navigate", direction = "down" } })
    local status = assert(host:status(), "an open selection carries its status")
    Assert.notNil(status.presentation, "the open selection carries a visible plan")
    local text = scope:own(FieldTextRenderer.new({ cacheFs = FieldUiFixture.cacheWithFontAndFrames() }))
    local realProvider =
      scope:own(PreparedMonIcons.preparedProvider(PreparedMonIcons.iconCache(), { "MON0/f0" }))
    local fixtureImage = realProvider:image("MON0/f0")
    local fixtureQuad, fixtureW, fixtureH = nil, 32, 32
    do
      local quad = realProvider:quadFor("MON0/f0")
      local dims = realProvider:dimensions("MON0/f0")
      fixtureQuad, fixtureW, fixtureH = quad, dims.width or 32, dims.height or 32
    end
    local icons = {
      image = function(_)
        return fixtureImage
      end,
      quadFor = function(_)
        return fixtureQuad
      end,
      dimensions = function(_)
        return { width = fixtureW, height = fixtureH }
      end,
    }
    local manifest = PartyCache.loadManifest(cacheFs)
    local renderer = PartyScreenRenderer.new({
      graphics = love.graphics,
      cacheFs = cacheFs,
      manifest = manifest,
      text = text,
    })
    local layout = PartyScreenLayout.resolve({ manifest = manifest, cancellable = true })
    local canvas = scope:own(love.graphics.newCanvas(256, 192))
    love.graphics.setCanvas(canvas)
    love.graphics.clear(0, 0, 0, 0)
    renderer:draw(status, layout, icons)
    love.graphics.setCanvas()
    local image = scope:own(canvas:newImageData())
    local r0, g0, b0 = image:getPixel(0, 0)
    local painted = 0
    for _, point in ipairs({ { 2, 2 }, { 125, 2 }, { 2, 45 }, { 125, 45 } }) do
      local r, g, b = image:getPixel(point[1], point[2])
      if quantize(r) ~= quantize(r0) or quantize(g) ~= quantize(g0) or quantize(b) ~= quantize(b0) then
        painted = painted + 1
      end
    end
    Assert.isTrue(painted >= 1, versionId .. " paints party chrome for the script selection")
    host:close(handle)
  end
end

return GraphicsSmoke.suite(T, { tags = { "field", "party", "script" } })
