-- Synthetic region-map companion for the map and fly suites: a small valid
-- manifest whose region map carries a handful of source-shaped locations and
-- flypoints, the matching catalog locations, message and flag fakes, and a
-- controller opener. Every value is synthetic; only the record shapes follow
-- the generated contract, so the suites never read ROM data.

local PokegearAssetSchema = require("libs.assets.src.PokegearAssetSchema")
local PokegearState = require("libs.hgss.src.save.PokegearState")

local PokegearMapFixture = {}

---@param path string
---@param width integer?
---@param height integer?
---@return table
local function visualRef(path, width, height)
  return { image = path, width = width or 32, height = height or 32, anchorX = 0, anchorY = 0 }
end

---@param colors integer
---@return table<integer, table<string, integer>>
local function paletteBank(colors)
  local bank = {}
  for index = 1, colors do
    bank[index] = { r = index * 10, g = index * 5, b = index * 3 }
  end
  return bank
end

---@param set string
---@param count integer
---@param frames integer
---@return table
local function spriteSet(set, count, frames)
  local sequences = {}
  for sequence = 1, count do
    local list = {}
    for frame = 1, frames do
      list[frame] = {
        image = "assets/generated/pokegear/map-sprite-" .. set .. "-" .. sequence .. "-" .. frame .. ".png",
        width = 16,
        height = 16,
        anchorX = -8,
        anchorY = -8,
        duration = 1,
      }
    end
    sequences[sequence] = { frames = list, playMode = "forward", loopStartFrameIdx = 0 }
  end
  return sequences
end

-- The synthetic source tables: location A (a 2x2 map with a preview, an
-- overlay highlight, and a flavor entry), B (one cell beside it), a hidden
-- Sinjoh Ruins entry placed first, and two flypoints.
---@return table regionMap
function PokegearMapFixture.regionMap()
  local function location(fields)
    local record = {
      mapId = fields.mapId,
      mapSymbol = fields.mapSymbol,
      x = fields.x,
      y = fields.y,
      width = fields.width or 1,
      height = fields.height or 1,
      objXOffset = fields.objXOffset or 0,
      objYOffset = fields.objYOffset or 0,
      flavorEntry = fields.flavorEntry or 5,
      previewBlock = fields.previewBlock or 0,
      sectionEntry = fields.sectionEntry or 40,
      overlay = fields.overlay or { srcX = 0, srcY = 0, width = 0, height = 0 },
    }
    return record
  end
  return {
    locations = {
      location({ mapId = 521, mapSymbol = "MAP_SINJOH_RUINS_EXTERIOR", x = 19, y = 2, width = 3, height = 3 }),
      location({
        mapId = 10,
        mapSymbol = "MAP_A",
        x = 12,
        y = 10,
        width = 2,
        height = 2,
        flavorEntry = 6,
        previewBlock = 3,
        sectionEntry = 41,
        overlay = { srcX = 10, srcY = 30, width = 3, height = 3 },
      }),
      location({ mapId = 11, mapSymbol = "MAP_B", x = 14, y = 10, flavorEntry = 7, sectionEntry = 42 }),
      location({ mapId = 12, mapSymbol = "MAP_KANTO", x = 30, y = 12, flavorEntry = 8, sectionEntry = 43 }),
    },
    flypoints = {
      {
        nameMapId = 10,
        nameSectionEntry = 41,
        warpMapId = 10,
        flypoint = 3,
        x = 12,
        y = 8,
        width = 2,
        height = 2,
        overlay = { srcX = 5, srcY = 20, destX = 1, destY = 1, width = 4, height = 4 },
      },
      {
        nameMapId = 75,
        nameSectionEntry = 44,
        warpMapId = 75,
        flypoint = 15,
        x = 5,
        y = 8,
        width = 1,
        height = 2,
        overlay = { srcX = 30, srcY = 24, destX = 1, destY = 1, width = 3, height = 4 },
      },
    },
  }
end

---@return table manifest a schema-valid synthetic companion family
function PokegearMapFixture.manifest()
  local foreground, world, markingPanel, markingBackdrop, upper, previews, textPalette = {}, {}, {}, {}, {}, {}, {}
  for skin = 0, 5 do
    local suffix = "-skin-" .. skin .. ".png"
    foreground[skin] = visualRef("assets/generated/pokegear/map-foreground" .. suffix, 256, 296)
    world[skin] = visualRef("assets/generated/pokegear/map-world" .. suffix, 512, 512)
    markingPanel[skin] = visualRef("assets/generated/pokegear/map-marking-panel" .. suffix, 256, 192)
    markingBackdrop[skin] = visualRef("assets/generated/pokegear/map-marking-backdrop" .. suffix, 256, 192)
    upper[skin] = visualRef("assets/generated/pokegear/map-upper" .. suffix, 256, 192)
    previews[skin] = visualRef("assets/generated/pokegear/map-previews" .. suffix, 256, 280)
    textPalette[skin] = { upper = paletteBank(16), lower = paletteBank(16) }
  end
  return {
    schema = "g4-pokegear-assets-v2",
    skins = { 0, 1, 2, 3, 4, 5 },
    shell = { foreground = visualRef("assets/generated/pokegear/shell-foreground-skin-0.png") },
    configure = { panel = visualRef("assets/generated/pokegear/configure-panel.png") },
    phone = { panel = visualRef("assets/generated/pokegear/phone-panel.png") },
    map = {
      foreground = foreground,
      world = world,
      markingPanel = markingPanel,
      markingBackdrop = markingBackdrop,
      upper = upper,
      previews = previews,
      textPalette = textPalette,
      wordPalette = paletteBank(16),
      sprites = {
        markers = spriteSet("markers", 2, 9),
        mapObjects = spriteSet("mapObjects", 12, 4),
        wordPlate = spriteSet("wordPlate", 1, 1),
      },
    },
    fly = {
      world = visualRef("assets/generated/pokegear/fly-world.png", 512, 512),
      foreground = visualRef("assets/generated/pokegear/fly-foreground.png", 256, 256),
      top = visualRef("assets/generated/pokegear/fly-top.png", 256, 192),
      upper = visualRef("assets/generated/pokegear/fly-upper.png", 256, 192),
      previews = visualRef("assets/generated/pokegear/fly-previews.png", 256, 280),
      menuTiles = visualRef("assets/generated/pokegear/fly-menu-tiles.png", 216, 8),
      menuPalette = paletteBank(16),
      textPalette = { upper = paletteBank(16), lower = paletteBank(16) },
    },
    radio = { dial = visualRef("assets/generated/pokegear/radio-dial.png") },
    catalog = {
      contacts = { { key = "test.caller.falkner", sortWeight = 10 } },
      contactOrder = { "test.caller.falkner" },
      callDefinitions = {},
      callTriggers = {},
      rematches = {},
      gifts = {},
      momPurchases = {},
      locations = {
        {
          key = "test.place.a",
          fieldMap = "MAP_A",
          mapRef = 10,
          matrix = { x = 12 * 32 + 8, y = 8 * 32 + 8 },
          location = "test.location.a",
          section = "test.section.a",
          region = "johto",
        },
        {
          key = "test.place.far",
          fieldMap = "MAP_FAR",
          mapRef = 99,
          matrix = { x = 3 * 32, y = 3 * 32 },
          location = "test.location.far",
          section = "test.section.far",
          region = "johto",
        },
      },
      flypoints = {},
      regionMap = PokegearMapFixture.regionMap(),
      reception = {},
      shows = {},
      radioEffects = {},
    },
    text = {},
    sequences = {},
  }
end

-- Message fakes with source-shaped entry arguments: landmark names by section
-- entry, flavor by entry, regions by name, and the fly prompt strings.
---@return table
function PokegearMapFixture.messages()
  return {
    region = function(name)
      return name == "johto" and "Johto" or "Kanto"
    end,
    landmark = function(entry)
      return "Landmark " .. tostring(entry)
    end,
    flavor = function(entry)
      return "Flavor " .. tostring(entry) .. "\nsecond line"
    end,
    word = function(key)
      return "Word " .. key
    end,
    flyPrompt = function(landmark)
      return landmark == nil and "Choose your destination." or ("Fly to " .. landmark .. "?")
    end,
    close = function()
      return "Close"
    end,
    menuLabel = function(index)
      return index == 0 and "Fly" or "Quit"
    end,
  }
end

---@param visited table<integer, boolean>?
---@return table facts
function PokegearMapFixture.facts(visited)
  visited = visited or { [3] = true, [15] = true }
  return {
    flypointVisited = function(index)
      return visited[index] == true
    end,
  }
end

-- A scripted word selector handoff; the suites answer through the
-- controller's acceptWordResult instead.
---@return table
function PokegearMapFixture.wordEntry()
  return {
    open = function() end,
    step = function() end,
    result = function()
      return nil
    end,
    cancel = function() end,
  }
end

---@return table the source-normalized context standing on location A
function PokegearMapFixture.context()
  return {
    fieldMap = "MAP_A",
    location = "test.location.a",
    matrixX = 12 * 32 + 8,
    matrixY = 8 * 32 + 8,
    region = "johto",
    unlockLevel = 2,
    specialMode = nil,
    playerGender = "male",
  }
end

---@param manifest table?
---@return table record the validated asset record
function PokegearMapFixture.record(manifest)
  local record, err = PokegearAssetSchema.validate(manifest or PokegearMapFixture.manifest())
  assert(record ~= nil, "the synthetic map family validates: " .. tostring(err and err.message or err))
  return record
end

---@param params table?
---@return table box { controller, state, record }
function PokegearMapFixture.openMap(params)
  params = params or {}
  local MapController = require("game.hgss.src.pokegear.MapController")
  local record = params.record or PokegearMapFixture.record()
  local state = params.state or PokegearState.new({ seed = 4177 }, { catalog = record.catalog })
  state:registerCard("map")
  local controller = MapController.new({
    state = state,
    assets = record,
    mapContext = params.mapContext or PokegearMapFixture.context(),
    messages = params.messages or PokegearMapFixture.messages(),
    facts = params.facts or PokegearMapFixture.facts(),
    phoneProjection = params.phoneProjection or function()
      return {}
    end,
    roamerProjection = params.roamerProjection or {},
    wordEntry = params.wordEntry or PokegearMapFixture.wordEntry(),
    switched = params.switched,
    effect = params.effect,
  })
  return { controller = controller, state = state, record = record }
end

---@param controller table
---@param count integer?
function PokegearMapFixture.tick(controller, count)
  for _ = 1, count or 1 do
    controller:updateFixed({})
  end
end

return PokegearMapFixture
