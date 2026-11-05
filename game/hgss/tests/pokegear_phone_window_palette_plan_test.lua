-- Window-palette plan contract for the phone card: the published plan payload carries
-- the per-skin window palette beside the list and tooltip palettes, so the
-- renderer can print the SUB_2 call windows through bank 1 of the
-- foreground NCLR member. Component scope with fixture assets and a real
-- controller: no ROM, no love globals, no production fallbacks.

local Assert = require("tests.support.Assert")

local T = {
  metadata = {
    tags = { "pokegear" },
  },
  tests = {},
}

---@param path string
---@return table visual record
local function visualRef(path)
  return { image = path, width = 32, height = 32, anchorX = 0, anchorY = 0 }
end

-- Sixteen-color palette bank with a recognizable base, one-based.
---@param base integer
---@return table
local function paletteBank(base)
  local bank = {}
  for index = 1, 16 do
    bank[index] = { r = base + index, g = 0, b = 0 }
  end
  return bank
end

---@return string[]
local function browseTooltips()
  return {
    "plan-tip-0",
    "plan-tip-1",
    "plan-tip-2",
    "plan-tip-3",
    "plan-tip-4",
    "plan-tip-5",
    "plan-tip-6",
    "plan-tip-7",
  }
end

---@return string[]
local function browseMenuLabels()
  return {
    "plan-menu-0",
    "plan-menu-1",
    "plan-menu-2",
    "plan-menu-3",
    "plan-menu-4",
    "plan-menu-5",
    "plan-menu-6",
    "plan-menu-7",
  }
end

---@return table world fixture with no rematch facts
local function worldFixture()
  return {
    queryRematch = function(_, _)
      return nil
    end,
    nativeSelectorFacts = function()
      return {}
    end,
  }
end

---@return table minimal catalog validating through the asset schema
local function fixtureCatalog()
  return {
    contacts = {
      { key = "custom.mom", family = "mother", sortWeight = 10 },
    },
    contactOrder = { "custom.mom" },
    callDefinitions = {},
    callTriggers = {},
    rematches = {},
    gifts = {},
    momPurchases = {},
    locations = {
      { key = "custom.new-bark" },
    },
    flypoints = {},
    regionMap = require("tests.support.PokegearRegionMapFixture").build(),
    reception = {},
    shows = {},
    radioEffects = {},
  }
end

---@return table fixture manifest validating through the asset schema
local function fixtureManifest()
  return {
    schema = "g4-pokegear-assets-v2",
    skins = { 0, 1, 2, 3, 4, 5 },
    shell = { foreground = visualRef("assets/generated/pokegear/shell-foreground-skin-0.png") },
    configure = { panel = visualRef("assets/generated/pokegear/configure-panel.png") },
    phone = { panel = visualRef("assets/generated/pokegear/phone-panel.png") },
    map = { base = visualRef("assets/generated/pokegear/map-base.png") },
    fly = { base = visualRef("assets/generated/pokegear/fly-base.png") },
    radio = { dial = visualRef("assets/generated/pokegear/radio-dial.png") },
    catalog = fixtureCatalog(),
    text = {},
    sequences = {},
  }
end

-- The plan payload carries the window palette for the active skin: the
-- renderer obligation behind the SUB_2 call windows.
function T.tests.plan_content_carries_the_per_skin_window_palette()
  local PokegearAssetSchema = require("libs.assets.src.PokegearAssetSchema")
  local record = PokegearAssetSchema.validate(fixtureManifest())
  Assert.notNil(record, "the synthetic catalog must validate through the asset schema")
  assert(record ~= nil, "synthetic catalog validated above")
  local PokegearState = require("libs.hgss.src.save.PokegearState")
  local PokegearRandom = require("game.hgss.src.pokegear.PokegearRandom")
  local PhoneController = require("game.hgss.src.pokegear.PhoneController")
  local state = PokegearState.new({ seed = 424242 }, { catalog = record.catalog })
  state:registerContact("custom.mom")
  local windowPalette = { [0] = paletteBank(200) }
  local controller = PhoneController.new({
    state = state,
    catalog = record.catalog,
    messages = { greeting = "custom.greeting" },
    world = worldFixture(),
    random = PokegearRandom.new(424242),
    tooltips = browseTooltips(),
    menuLabels = browseMenuLabels(),
    assets = {
      phone = {
        foreground = { [0] = visualRef("assets/generated/pokegear/phone-foreground-test.png") },
        upper = visualRef("assets/generated/pokegear/phone-upper-test.png"),
        sprites = {},
        listPalette = { [0] = paletteBank(0) },
        tooltipPalette = { [0] = paletteBank(100) },
        windowPalette = windowPalette,
      },
      fly = {
        menuTiles = visualRef("assets/generated/pokegear/fly-menu-test.png"),
        menuPalette = paletteBank(300),
      },
    },
  })
  local status = controller:status()
  local content = assert(status.presentation, "the phone status publishes its plan").content
  Assert.notNil(content, "the phone plan publishes its payload")
  assert(type(content) == "table", "the plan payload publishes above")
  Assert.deepEqual(
    content.windowPalette,
    windowPalette[0],
    "the plan carries the window palette for the active skin, never the list palette"
  )
  Assert.deepEqual(content.listPalette, paletteBank(0), "the plan keeps carrying the list palette beside it")
  controller:dispose()
end

return T
