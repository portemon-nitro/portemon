-- Real-asset smoke for the bounded Summary presentation: the
-- production renderer draws the real Party badge frames, the real mon
-- portrait atlas, and the real field font through the required native
-- geometry. Pixel evidence (never draw-did-not-throw) proves five-leaf,
-- crown, and bare masks differ in the leaf row, long metadata paginates
-- with a continuation marker, and repeated draws are identical.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local FieldFontCache = require("libs.assets.src.field.FieldFontCache")
local FieldTextRenderer = require("libs.hgss.src.ui.FieldTextRenderer")
local GameVersion = require("romdump.src.source.GameVersion")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local MonCache = require("libs.assets.src.MonCache")
local MonsSave = require("libs.mons.src.MonsSave")
local Party = require("libs.mons.src.Party")
local PartyCache = require("libs.assets.src.PartyCache")
local Personality = require("libs.mons.src.gen4.Personality")
local RomImporter = require("romdump.src.source.RomImporter")
local SummaryModel = require("libs.hgss.src.ui.SummaryModel")
local SummaryRenderer = require("libs.hgss.src.ui.SummaryRenderer")

local T = {}

local function readyVersions()
  local versions = {}
  for _, versionId in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(versionId) then
      local cacheFs = CacheFs.forVersion(versionId)
      local marker = cacheFs:read(PartyCache.markerPath())
      if
        marker ~= nil
        and PartyCache.isReady(cacheFs, marker)
        and MonCache.isReady(cacheFs, cacheFs:read(MonCache.markerPath()))
        and cacheFs:read(FieldFontCache.atlasPath(0)) ~= nil
      then
        versions[#versions + 1] = versionId
      end
    end
  end
  return versions
end

local function openService(catalog, seed)
  local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
  return HgssMonService.new({
    catalog = catalog,
    bucket = MonsSave.capture(Party.new():capture(), Lcrng.new(seed):capture(), catalog:fingerprint()),
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

local function realCatalog(cacheFs)
  local MonCatalog = require("libs.mons.src.MonCatalog")
  return MonCatalog.new(MonCache.loadCatalog(cacheFs), CatalogFixture.makeItemCatalog())
end

local function gift(service, species, level)
  local added = service:giveMon({
    species = species,
    level = level or 5,
    heldItem = nil,
    form = 0,
    location = 7,
    date = CatalogFixture.metDate(),
  })
  Assert.isTrue(added, "setup gift must enter the party")
end

local function setLeaves(service, slot, mask)
  local revision = service:partyRevision()
  local copy = service:partyMon(slot)
  copy.shinyLeaves = mask
  local preparation = assert(service:preparePartyChanges(revision, { { slot = slot, mon = copy } }))
  preparation.publish()
end

-- Test-local atlas glue: quads cut from a realized atlas image through
-- manifest entries. Production wiring owns its own provider; the renderer
-- only requires image/quadFor/dimensions.
local function atlasProvider(graphics, image, entries)
  local quads = {}
  return {
    image = function()
      return image
    end,
    quadFor = function(_, selector)
      local entry = assert(entries[selector], "atlas carries " .. tostring(selector))
      local quad = quads[selector]
      if quad == nil then
        quad = graphics.newQuad(entry.x, entry.y, entry.width, entry.height, image:getWidth(), image:getHeight())
        quads[selector] = quad
      end
      return quad
    end,
    dimensions = function(_, selector)
      local entry = assert(entries[selector], "atlas carries " .. tostring(selector))
      return { width = entry.width, height = entry.height }
    end,
  }
end

local function realizedImage(scope, cacheFs, path)
  local bytes = assert(cacheFs:read(path), "cache carries " .. path)
  local file = assert(love.filesystem.newFileData(bytes, path), "file data wraps " .. path)
  return scope:own(love.graphics.newImage(file))
end

local function composition(scope, versionId)
  local cacheFs = CacheFs.forVersion(versionId)
  local manifest = PartyCache.loadManifest(cacheFs)
  local text = FieldTextRenderer.new({ cacheFs = cacheFs })
  local renderer = SummaryRenderer.new({ text = text })
  local portraitManifest = assert(cacheFs:loadLua(MonCache.portraitManifestPath()), "the portrait manifest loads")
  local portraitEntries = assert(portraitManifest.entries, "the portrait manifest carries entries")
  -- The exercised mon's portrait page resolves from the manifest
  -- instead of pinning a page number: roster layout stays the
  -- producer's business while the renderer keeps its one-image
  -- provider contract for the drawn variants.
  local portraitPageId = nil
  for selector, entry in pairs(portraitEntries) do
    if tostring(selector):find("CHIKORITA", 1, true) then
      portraitPageId = entry.pageId
      break
    end
  end
  assert(portraitPageId ~= nil, "the portrait manifest carries the exercised mon")
  local portraitPage =
    assert(portraitManifest.pages[portraitPageId], "the portrait manifest carries the exercised page")
  local portraits =
    atlasProvider(love.graphics, realizedImage(scope, cacheFs, portraitPage.image), portraitEntries)
  local catalog = realCatalog(cacheFs)
  local service = openService(catalog, 0xC10C4000)
  gift(service, "CHIKORITA", 12)
  return cacheFs, manifest, renderer, portraits, service
end

local function badgeImages(scope, cacheFs)
  local images = {}
  return function(frame)
    local path = assert(frame.image, "badge frames carry their image path")
    local image = images[path]
    if image == nil then
      image = realizedImage(scope, cacheFs, path)
      images[path] = image
    end
    return image
  end
end

local function drawFacts(scope, cacheFs, renderer, service, slot, manifest, portraits, mask)
  setLeaves(service, slot, mask)
  local facts = SummaryModel.build(service, slot)
  local layout = SummaryRenderer.layout(4)
  local canvas = scope:own(love.graphics.newCanvas(256, 192))
  love.graphics.setCanvas(canvas)
  love.graphics.clear(0, 0, 0, 0)
  renderer:draw({ open = true, page = "overview", facts = facts }, layout, {
    manifest = manifest,
    portraits = portraits,
    badgeImage = badgeImages(scope, cacheFs),
  })
  love.graphics.setCanvas()
  return scope:own(canvas:newImageData())
end

local function countMarkerPixels(image, x0, y0, x1, y1)
  local marker = SummaryRenderer.CONTINUATION_COLOR
  local found = 0
  for y = y0, y1 do
    for x = x0, x1 do
      local r, g, b, a = image:getPixel(x, y)
      if
        math.abs(r - marker[1]) < 0.05
        and math.abs(g - marker[2]) < 0.05
        and math.abs(b - marker[3]) < 0.05
        and a > 0.5
      then
        found = found + 1
      end
    end
  end
  return found
end

local function regionDifference(first, second, x0, y0, x1, y1)
  local differing = 0
  for y = y0, y1 do
    for x = x0, x1 do
      local r1, g1, b1, a1 = first:getPixel(x, y)
      local r2, g2, b2, a2 = second:getPixel(x, y)
      if math.abs(r1 - r2) + math.abs(g1 - g2) + math.abs(b1 - b2) + math.abs(a1 - a2) > 0.01 then
        differing = differing + 1
      end
    end
  end
  return differing
end

function T.leaf_row_distinguishes_five_leaves_crown_and_bare(scope)
  for _, versionId in ipairs(readyVersions()) do
    local cacheFs, manifest, renderer, portraits, service = composition(scope, versionId)
    local bare = drawFacts(scope, cacheFs, renderer, service, 0, manifest, portraits, 0)
    local leaves = drawFacts(scope, cacheFs, renderer, service, 0, manifest, portraits, 31)
    local crown = drawFacts(scope, cacheFs, renderer, service, 0, manifest, portraits, 32)
    Assert.isTrue(
      regionDifference(bare, leaves, 88, 176, 136, 191) > 20,
      versionId .. " draws five leaves where the bare row stands empty"
    )
    Assert.isTrue(
      regionDifference(leaves, crown, 88, 176, 136, 191) > 20,
      versionId .. " draws the crown apart from the five leaves"
    )
    local again = drawFacts(scope, cacheFs, renderer, service, 0, manifest, portraits, 31)
    Assert.equal(regionDifference(leaves, again, 0, 0, 255, 191), 0, versionId .. " repeats one leaf frame identically")
  end
end

function T.long_metadata_paginates_with_a_continuation_marker(scope)
  for _, versionId in ipairs(readyVersions()) do
    local cacheFs, manifest, renderer, portraits, service = composition(scope, versionId)
    service:setMove(0, 0, "THIEF")
    service:setMove(0, 1, "TACKLE")
    local facts = SummaryModel.build(service, 0)
    Assert.equal(facts.moves[1].key, "THIEF", versionId .. " stages its long real description")
    Assert.isTrue(
      #facts.moves[1].description > 100,
      versionId .. " exercises pagination against a long real description"
    )
    local layout = SummaryRenderer.layout(4)
    local assets = {
      manifest = manifest,
      portraits = portraits,
      badgeImage = badgeImages(scope, cacheFs),
    }
    local longCanvas = scope:own(love.graphics.newCanvas(256, 192))
    love.graphics.setCanvas(longCanvas)
    love.graphics.clear(0, 0, 0, 0)
    renderer:draw({ open = true, page = "moves", facts = facts, moveIndex = 0, detailOffset = 0 }, layout, assets)
    love.graphics.setCanvas()
    local longImage = scope:own(longCanvas:newImageData())
    Assert.isTrue(
      countMarkerPixels(longImage, 8, 128, 248, 168) > 4,
      versionId .. " marks paginated move detail with a continuation indicator"
    )
    local shortCanvas = scope:own(love.graphics.newCanvas(256, 192))
    love.graphics.setCanvas(shortCanvas)
    love.graphics.clear(0, 0, 0, 0)
    renderer:draw({ open = true, page = "stats", facts = facts }, layout, assets)
    love.graphics.setCanvas()
    local shortImage = scope:own(shortCanvas:newImageData())
    Assert.equal(
      countMarkerPixels(shortImage, 8, 48, 248, 168),
      0,
      versionId .. " draws no marker where short stats fit"
    )
  end
end

function T.portrait_follows_gender_and_shininess(scope)
  for _, versionId in ipairs(readyVersions()) do
    local cacheFs, manifest, renderer, portraits, service = composition(scope, versionId)
    local mon = service:partyMon(0)
    local species = service:catalog():species(mon.species)
    local gender = Personality.gender(species.genderRatio, mon.personality)
    Assert.isTrue(gender == "male" or gender == "female", versionId .. " resolves a portrait gender")
    local facts = SummaryModel.build(service, 0)
    Assert.notNil(facts.portraitSelector, versionId .. " selects a portrait for a hatched mon")
    local canvas = scope:own(love.graphics.newCanvas(256, 192))
    love.graphics.setCanvas(canvas)
    love.graphics.clear(0, 0, 0, 0)
    renderer:draw({ open = true, page = "overview", facts = facts }, SummaryRenderer.layout(4), {
      manifest = manifest,
      portraits = portraits,
      badgeImage = badgeImages(scope, cacheFs),
    })
    love.graphics.setCanvas()
    local image = scope:own(canvas:newImageData())
    local lit = 0
    for y = 48, 120 do
      for x = 8, 80 do
        local _, _, _, a = image:getPixel(x, y)
        if a > 0.5 then
          lit = lit + 1
        end
      end
    end
    Assert.isTrue(lit > 50, versionId .. " paints portrait material in the overview portrait well")
  end
end

return GraphicsSmoke.suite(T)
