-- Standalone Fly map presentation: the Fly entry paints its own
-- chrome, window, and confirmation composition from the shared asset
-- family, sharing only region geometry and semantic destination keys
-- with the Map tab. Every skin paints distinctly, every host layout
-- carries opaque Fly content that never matches the Map tab rendering,
-- the Fly view exposes no tab strip and no marking controls while the
-- Map tab keeps its own marking entry, and only Fly mode offers
-- confirmation: the Town view never does. The entry is therefore never
-- a fifth gear tab.

local Assert = require("tests.support.Assert")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local PokegearAssetSchema = require("libs.assets.src.PokegearAssetSchema")
local PokegearState = require("libs.hgss.src.save.PokegearState")

local T = {}

-- Loads a fly module that does not exist yet at this baseline. The
-- failure names the missing behaviour instead of surfacing as a suite
-- load error, so the pre-implementation red stays attributable.
---@param moduleName string
---@param missingMessage string
---@return table
local function requireFeature(moduleName, missingMessage)
  local ok, mod = pcall(require, moduleName)
  if not ok then
    error(missingMessage, 0)
  end
  assert(type(mod) == "table", missingMessage)
  return mod --[[@as table]]
end

---@param path string
---@param width integer
---@param height integer
---@return table
local function visualRef(path, width, height)
  return { image = path, width = width, height = height, anchorX = 0, anchorY = 0 }
end

-- Synthetic companion family mirroring the published manifest shape:
-- the Fly section carries its own plane, window, cursor, and
-- confirmation visuals on paths disjoint from every Map visual, plus
-- two semantic fly destinations, validated through the real asset
-- schema so the scenarios borrow only genuine references.
---@return table
local function fixtureManifest()
  return {
    schema = "g4-pokegear-assets-v1",
    skins = { 0, 1, 2, 3, 4, 5 },
    shell = { foreground = visualRef("assets/generated/pokegear/shell-foreground-skin-0.png", 256, 192) },
    configure = { panel = visualRef("assets/generated/pokegear/configure-panel.png", 256, 192) },
    phone = { panel = visualRef("assets/generated/pokegear/phone-panel.png", 256, 192) },
    map = {
      foreground = visualRef("assets/generated/pokegear/map-foreground.png", 256, 192),
      upper = visualRef("assets/generated/pokegear/map-upper.png", 256, 192),
      world = visualRef("assets/generated/pokegear/map-world.png", 512, 512),
      upperBase = visualRef("assets/generated/pokegear/map-upper-base.png", 256, 192),
    },
    fly = {
      foreground = visualRef("assets/generated/pokegear/fly-foreground.png", 256, 192),
      base = visualRef("assets/generated/pokegear/fly-base.png", 256, 192),
      window = visualRef("assets/generated/pokegear/fly-window.png", 256, 192),
      cursor = visualRef("assets/generated/pokegear/fly-cursor.png", 32, 32),
    },
    radio = { dial = visualRef("assets/generated/pokegear/radio-dial.png", 256, 192) },
    catalog = {
      contacts = {},
      contactOrder = {},
      callDefinitions = {},
      callTriggers = {},
      rematches = {},
      gifts = {},
      momPurchases = {},
      locations = {
        { key = "test.place.violet" },
        { key = "test.place.new-bark" },
      },
      flypoints = {
        { key = "test.fly.violet" },
        { key = "test.fly.new-bark" },
      },
      reception = {},
      shows = {},
      radioEffects = {},
    },
    text = {},
    sequences = {},
  }
end

-- The four host panes from the locked layout contract, expressed as
-- viewport rectangles over the shared source surfaces: wide keeps
-- information left of controls, tall stacks it above, the physical pair
-- splits screens, and the near-native frame centers the source geometry.
---@return table<string, table> name to viewport rect
local function hostPanes()
  return {
    wide = { x = 0, y = 0, width = 256, height = 192 },
    tall = { x = 0, y = 192, width = 256, height = 192 },
    dual = { x = 0, y = 0, width = 256, height = 192 },
    nativeLike = { x = 128, y = 96, width = 256, height = 192 },
  }
end

-- Source-normalized map context for an outdoor main-matrix cell. Field
-- values stay synthetic; only the record shape follows the map contract.
---@return table
local function outdoorContext()
  return {
    fieldMap = "test.field.new-bark",
    location = "test.place.new-bark",
    matrixX = 96,
    matrixY = 64,
    region = "johto",
    unlockLevel = 1,
    specialMode = nil,
    playerGender = "boy",
  }
end

---@param manifest table
---@return table<string, table> image path to visual
local function collectVisuals(manifest)
  local out = {}
  local function walk(node)
    if type(node) ~= "table" then
      return
    end
    if type(node.image) == "string" then
      out[node.image] = node
      return
    end
    for _, child in pairs(node) do
      walk(child)
    end
  end
  walk(manifest)
  return out
end

-- One solid in-memory image per manifest path. Host-boundary handles
-- only; the manifest itself stays the borrowed immutable record.
---@param scope table
---@param manifest table
---@return table resources
local function renderResources(scope, manifest)
  local images = {}
  local seed = 0
  for path, visual in pairs(collectVisuals(manifest)) do
    seed = seed + 1
    local canvas = scope:own(love.graphics.newCanvas(visual.width, visual.height))
    love.graphics.setCanvas(canvas)
    love.graphics.setColor((seed * 0.37) % 1, (seed * 0.61) % 1, (seed * 0.83) % 1, 1)
    love.graphics.rectangle("fill", 0, 0, visual.width, visual.height)
    love.graphics.setCanvas()
    images[path] = scope:own(love.graphics.newImage(scope:own(canvas:newImageData())))
  end
  return { graphics = love.graphics, images = images }
end

-- Samples a cross of the canvas so a repaint anywhere changes the
-- signature.
---@param data table
---@return string
local function paintSignature(data)
  local parts = {}
  for _, point in ipairs({ { 10, 10 }, { 200, 60 }, { 60, 140 }, { 180, 150 }, { 128, 96 } }) do
    local red, green, blue, alpha = data:getPixel(point[1], point[2])
    parts[#parts + 1] = string.format(
      "%d:%d:%d:%d",
      math.floor(red * 255 + 0.5),
      math.floor(green * 255 + 0.5),
      math.floor(blue * 255 + 0.5),
      math.floor(alpha * 255 + 0.5)
    )
  end
  return table.concat(parts, "|")
end

---@param resources table
---@param draw fun()
---@return string signature of the painted canvas
local function captureDraw(scope, resources, draw)
  local _ = resources
  local canvas = scope:own(love.graphics.newCanvas(256, 192))
  love.graphics.setCanvas(canvas)
  love.graphics.clear(0, 0, 0, 0)
  draw()
  love.graphics.setCanvas()
  return paintSignature(scope:own(canvas:newImageData()))
end

-- Standalone Fly chrome shares data but never a tab: every skin paints
-- distinctly from prepared assets, every host layout carries opaque Fly
-- content that never matches the Map tab rendering, the Fly view
-- exposes no tab strip and no marking controls while the Map tab keeps
-- its own marking entry, only Fly mode offers confirmation, and the Fly
-- markers carry exactly the semantic destination keys from the shared
-- catalog.
function T.standalone_fly_chrome_shares_data_but_never_adds_a_tab(scope)
  local FlyMapController = requireFeature(
    "game.hgss.src.pokegear.FlyMapController",
    "there is no standalone fly selector yet: its chrome, window, and confirmation composition cannot be captured"
  )
  local PokegearFlyMapRenderer = requireFeature(
    "libs.hgss.src.presentation.PokegearFlyMapRenderer",
    "there is no standalone fly renderer yet: its plane, window, and sprite stack cannot be captured"
  )
  local MapController = require("game.hgss.src.pokegear.MapController")
  local PokegearMapRenderer = require("libs.hgss.src.presentation.PokegearMapRenderer")
  local manifest = fixtureManifest()
  local record = PokegearAssetSchema.validate(manifest)
  Assert.notNil(record, "the synthetic companion catalog must validate through the asset schema")
  assert(record ~= nil, "synthetic catalog validated above")
  local state = PokegearState.new({ seed = 1207 }, { catalog = record.catalog })
  local resources = renderResources(scope, manifest)
  local blank = "0:0:0:0|0:0:0:0|0:0:0:0|0:0:0:0|0:0:0:0"

  local destinations = { "test.fly.violet", "test.fly.new-bark" }
  ---@param mode string
  ---@param pane table
  ---@return table
  local function openFly(mode, pane)
    return FlyMapController.new({
      mode = mode,
      operationId = "fly-graphics-" .. mode,
      context = outdoorContext(),
      destinations = destinations,
      assets = record,
      presentation = { pane = pane },
    })
  end
  local function openMap()
    return MapController.new({
      state = state,
      assets = record,
      mapContext = outdoorContext(),
      phoneProjection = function(_)
        return {}
      end,
      roamerProjection = {},
      wordEntry = { open = function(_) end, step = function() end, result = function()
        return nil
      end, cancel = function() end },
    })
  end

  -- Every skin paints distinctly from the same prepared assets: six
  -- commits through one painting path yield six signatures with no
  -- asset rebuild between draws, and none is blank.
  local fly = openFly("fly", hostPanes().wide)
  local seen = {}
  for skin = 0, 5 do
    local status = fly:status()
    local signature = captureDraw(scope, resources, function()
      PokegearFlyMapRenderer.draw(resources, status, skin)
    end)
    Assert.isTrue(signature ~= blank, "fly skin " .. skin .. " paints opaque content")
    Assert.isNil(seen[signature], "fly skin " .. skin .. " paints distinctly from prepared assets")
    seen[signature] = skin
  end

  -- Every host layout carries opaque Fly content that never matches the
  -- Map tab rendering from the same prepared assets: the Fly entry owns
  -- its chrome in wide, tall, dual-screen, and near-native placement.
  local map = openMap()
  for paneName, pane in pairs(hostPanes()) do
    local paneFly = openFly("fly", pane)
    local flySignature = captureDraw(scope, resources, function()
      PokegearFlyMapRenderer.draw(resources, paneFly:status(), 0)
    end)
    local mapSignature = captureDraw(scope, resources, function()
      PokegearMapRenderer.draw(resources, map:status(), 0)
    end)
    Assert.isTrue(flySignature ~= blank, paneName .. " paints opaque fly content")
    Assert.isTrue(
      flySignature ~= mapSignature,
      paneName .. " renders fly chrome distinct from the map tab"
    )
    paneFly:dispose()
  end

  -- Never a fifth tab: the Fly view exposes no tab strip and no marking
  -- controls, while the Map tab keeps its own marking entry, so the
  -- distinction is observable in both directions.
  local flyView = assert(fly:status().view, "the fly view is published")
  Assert.isNil(flyView.tabs, "the fly view exposes no tab strip")
  Assert.isNil(flyView.tabStrip, "the fly view exposes no tab strip under any name")
  Assert.isNil(flyView.markingsButton, "the fly view leaves shell marking controls out")
  Assert.isNil(flyView.markingPanel, "the fly view leaves shell marking controls out")
  local mapView = assert(map:status().view, "the map view is published")
  Assert.notNil(mapView.markingsButton, "the map tab keeps its own marking entry")

  -- Mode rules: only Fly mode offers confirmation; the Town view never
  -- does, so a view-only map cannot confirm travel.
  local confirm = assert(flyView.confirmButton, "fly mode publishes its confirmation control")
  Assert.isTrue(
    type(confirm.x) == "number" and type(confirm.y) == "number",
    "the fly confirmation control carries its hit point"
  )
  Assert.isTrue(
    type(confirm.width) == "number" and type(confirm.height) == "number",
    "the fly confirmation control carries its hit area"
  )
  local town = openFly("townMap", hostPanes().wide)
  local townView = assert(town:status().view, "the town view is published")
  Assert.isNil(townView.confirmButton, "the view-only town map offers no confirmation control")
  Assert.isNil(town:takeResult(), "the unconfirmed town map publishes no result")

  -- Shared data: the Fly markers carry exactly the semantic destination
  -- keys from the shared catalog, in order, so geometry and catalog
  -- references stay shared while the chrome stays separate.
  local catalogKeys = {}
  for _, flypoint in ipairs(record.catalog.flypoints) do
    catalogKeys[#catalogKeys + 1] = flypoint.key
  end
  local markers = assert(flyView.markers, "the fly view publishes its destination markers")
  Assert.equal(#markers, #destinations, "the fly view marks every destination exactly once")
  for index, marker in ipairs(markers) do
    Assert.equal(marker.key, destinations[index], "fly marker " .. index .. " names its semantic destination")
    local shared = false
    for _, key in ipairs(catalogKeys) do
      if key == marker.key then
        shared = true
      end
    end
    Assert.isTrue(shared, "fly marker " .. marker.key .. " resolves through the shared catalog")
  end

  fly:dispose()
  town:dispose()
  map:dispose()
end

-- View-only Town chrome paints without confirmation: every host layout
-- carries opaque Town content that never matches the Fly rendering from
-- the same prepared assets, and the Town view offers no confirmation
-- control in any layout.
function T.view_only_town_chrome_paints_without_confirmation(scope)
  local FlyMapController = requireFeature(
    "game.hgss.src.pokegear.FlyMapController",
    "there is no standalone town selector yet: its chrome composition cannot be captured"
  )
  local PokegearFlyMapRenderer = requireFeature(
    "libs.hgss.src.presentation.PokegearFlyMapRenderer",
    "there is no standalone town renderer yet: its plane and window stack cannot be captured"
  )
  local manifest = fixtureManifest()
  local record = PokegearAssetSchema.validate(manifest)
  Assert.notNil(record, "the synthetic companion catalog must validate through the asset schema")
  assert(record ~= nil, "synthetic catalog validated above")
  local resources = renderResources(scope, manifest)
  local blank = "0:0:0:0|0:0:0:0|0:0:0:0|0:0:0:0|0:0:0:0"
  local destinations = { "test.fly.violet", "test.fly.new-bark" }
  for paneName, pane in pairs(hostPanes()) do
    local town = FlyMapController.new({
      mode = "townMap",
      operationId = "town-graphics-" .. paneName,
      assets = record,
      presentation = { pane = pane },
    })
    local fly = FlyMapController.new({
      mode = "fly",
      operationId = "fly-graphics-" .. paneName,
      context = outdoorContext(),
      destinations = destinations,
      assets = record,
      presentation = { pane = pane },
    })
    local townSignature = captureDraw(scope, resources, function()
      PokegearFlyMapRenderer.draw(resources, town:status(), 0)
    end)
    local flySignature = captureDraw(scope, resources, function()
      PokegearFlyMapRenderer.draw(resources, fly:status(), 0)
    end)
    Assert.isTrue(townSignature ~= blank, paneName .. " paints opaque town content")
    Assert.isTrue(
      townSignature ~= flySignature,
      paneName .. " renders town chrome distinct from the fly composition"
    )
    local townView = assert(town:status().view, "the town view is published")
    Assert.isNil(townView.confirmButton, "the view-only town map offers no confirmation control")
    Assert.isNil(town:takeResult(), "the unconfirmed town map publishes no result")
    town:dispose()
    fly:dispose()
  end
end

-- Absent prepared planes fail instead of inventing geography: an empty
-- resolved content record throws the attributed error rather than
-- painting procedural bands, and a resolved path with no prepared image
-- throws the same established error.
function T.absent_prepared_planes_fail_instead_of_inventing_geography(scope)
  local _ = scope
  local PokegearFlyMapRenderer = requireFeature(
    "libs.hgss.src.presentation.PokegearFlyMapRenderer",
    "there is no standalone fly renderer yet: its plane, window, and sprite stack cannot be captured"
  )
  local resources = { graphics = {}, images = {} }
  local empty = Assert.throws(function()
    PokegearFlyMapRenderer.draw(resources, { view = { markers = {}, content = {} } }, 0)
  end, "absent fly planes fail instead of inventing geography")
  Assert.isTrue(
    tostring(empty):find("prepared planes", 1, true) ~= nil,
    "the empty content failure names the missing prepared planes"
  )
  local missing = Assert.throws(function()
    PokegearFlyMapRenderer.draw(
      resources,
      { view = { markers = {}, content = { background = "assets/generated/pokegear/fly-base.png" } } },
      0
    )
  end, "an unresolved fly plane fails instead of inventing geography")
  Assert.isTrue(
    tostring(missing):find("prepared plane image", 1, true) ~= nil,
    "the unresolved plane failure names the missing prepared image"
  )
end

return GraphicsSmoke.suite(T, { tags = { "pokegear" } })
