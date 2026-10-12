-- Region map geometry and presentation: forward and inverse cell
-- transforms stay exact inverses over every selectable cell at both
-- discrete scales and all four host panes, negative offsets truncate the
-- source way, out-of-surface pointers select nothing, all six skins paint
-- distinctly with live region masking, and the marking entrance gates
-- input until both its fade and slide completions finish.

local Assert = require("tests.support.Assert")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local PokegearAssetSchema = require("libs.assets.src.PokegearAssetSchema")
local PokegearState = require("libs.hgss.src.save.PokegearState")

local T = {}

-- Loads a map module that does not exist yet at this baseline. The failure
-- names the missing behaviour instead of surfacing as a suite load error,
-- so the pre-implementation red stays attributable.
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

-- Synthetic companion family mirroring the published manifest shape: map
-- planes plus one location per region tier, validated through the real
-- asset schema so the scenarios borrow only genuine references. The map
-- foreground and upper chrome carry one prepared plane per source skin
-- while the world plane stays shared, exactly like the compiled family.
---@return table
local function fixtureManifest()
  local mapForeground, mapUpper = {}, {}
  for skin = 0, 5 do
    mapForeground[skin] = visualRef("assets/generated/pokegear/map-foreground-skin-" .. skin .. ".png", 256, 192)
    mapUpper[skin] = visualRef("assets/generated/pokegear/map-upper-skin-" .. skin .. ".png", 256, 192)
  end
  return {
    schema = "g4-pokegear-assets-v1",
    skins = { 0, 1, 2, 3, 4, 5 },
    shell = { foreground = visualRef("assets/generated/pokegear/shell-foreground-skin-0.png", 256, 192) },
    configure = { panel = visualRef("assets/generated/pokegear/configure-panel.png", 256, 192) },
    phone = { panel = visualRef("assets/generated/pokegear/phone-panel.png", 256, 192) },
    map = {
      foreground = mapForeground,
      upper = mapUpper,
      world = visualRef("assets/generated/pokegear/map-world.png", 512, 512),
      upperBase = visualRef("assets/generated/pokegear/map-upper-base.png", 256, 192),
    },
    fly = { pairs = { visualRef("assets/generated/pokegear/fly-pair-1.png", 256, 192) } },
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
        { key = "test.place.johto" },
        { key = "test.place.kanto" },
      },
      flypoints = {},
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

-- Forward and inverse geometry agree over every selectable source cell:
-- each cell center projects and pointer-maps back to its own cell at
-- both discrete scales, extreme pans, and all four host panes, with no
-- unreachable unlocked cell and no selection outside the world surface.
function T.forward_and_inverse_geometry_agree_over_every_selectable_cell()
  local MapProjection = requireFeature(
    "game.hgss.src.pokegear.MapProjection",
    "the region map has no projection owner yet: cell drawing and pointer selection cannot agree"
  )
  local pans = {
    { x = 0, y = 0 },
    { x = -40, y = -24 },
    { x = 248, y = 248 },
  }
  for paneName, pane in pairs(hostPanes()) do
    for _, cells in ipairs({ 8, 16 }) do
      local span = math.floor(512 / cells)
      for _, pan in ipairs(pans) do
        for cy = 0, span - 1 do
          for cx = 0, span - 1 do
            local point = MapProjection.forward({ x = cx, y = cy }, pan, cells, pane)
            Assert.notNil(point, paneName .. " projects cell " .. cx .. "," .. cy .. " at " .. cells .. "px")
            local back = MapProjection.inverse(point, pan, cells, pane)
            Assert.notNil(back, paneName .. " pointer-maps its own drawing at " .. cells .. "px")
            Assert.equal(back.x, cx, paneName .. " inverse keeps the column at " .. cells .. "px")
            Assert.equal(back.y, cy, paneName .. " inverse keeps the row at " .. cells .. "px")
          end
        end
      end
    end
  end

  -- Discrete doubling, not continuous zoom: adjacent cell centers sit
  -- exactly twice as far apart at sixteen pixels as at eight.
  do
    local pane = hostPanes().wide
    local pan = { x = 0, y = 0 }
    local a8 = MapProjection.forward({ x = 4, y = 4 }, pan, 8, pane)
    local b8 = MapProjection.forward({ x = 5, y = 4 }, pan, 8, pane)
    local a16 = MapProjection.forward({ x = 4, y = 4 }, pan, 16, pane)
    local b16 = MapProjection.forward({ x = 5, y = 4 }, pan, 16, pane)
    Assert.near((b16.x - a16.x), 2 * (b8.x - a8.x), 1e-6, "sixteen-pixel cells double the eight-pixel step")
  end

  -- Cell order never mirrors: increasing columns project rightward in
  -- every pane.
  for paneName, pane in pairs(hostPanes()) do
    local left = MapProjection.forward({ x = 2, y = 9 }, { x = 0, y = 0 }, 8, pane)
    local right = MapProjection.forward({ x = 6, y = 9 }, { x = 0, y = 0 }, 8, pane)
    Assert.isTrue(right.x > left.x, paneName .. " keeps column order")
  end

  -- Negative offsets truncate toward zero the source way: with a three
  -- pixel pan the surface origin still belongs to cell zero, where floor
  -- division would blame cell minus one.
  do
    local pane = hostPanes().wide
    local back = MapProjection.inverse({ x = pane.x, y = pane.y }, { x = 3, y = 3 }, 8, pane)
    Assert.notNil(back, "the truncated origin still selects a cell")
    Assert.equal(back.x, 0, "negative remainders truncate toward zero, never floor")
    Assert.equal(back.y, 0, "negative remainders truncate toward zero, never floor")
  end

  -- Pointers above and left of the world surface select nothing, so no
  -- hidden region answers through an invisible hitbox; pointers past the
  -- far edge still resolve to their valid surface cell.
  for paneName, pane in pairs(hostPanes()) do
    Assert.isNil(
      MapProjection.inverse({ x = pane.x - 20, y = pane.y - 20 }, { x = 0, y = 0 }, 8, pane),
      paneName .. " rejects pointers above and left of the surface"
    )
    local pastEdge = MapProjection.inverse(
      { x = pane.x + pane.width + 20, y = pane.y + pane.height + 20 },
      { x = 0, y = 0 },
      16,
      pane
    )
    Assert.deepEqual(
      pastEdge,
      { x = 17, y = 13 },
      paneName .. " maps past-edge pointers to their valid surface cell"
    )
  end
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

-- Map layers and panel slides match source order with gated input: every
-- skin paints distinctly through its own prepared chrome, region masking
-- repaints across unlock levels, and marking-mode input stays gated until
-- both the fade and the slide completions finish.
function T.map_layers_and_panel_slides_match_source_order_with_gated_input(scope)
  local MapController = requireFeature(
    "game.hgss.src.pokegear.MapController",
    "the region map has no controller yet: layer painting and slide gating cannot be captured"
  )
  local PokegearMapRenderer = requireFeature(
    "libs.hgss.src.presentation.PokegearMapRenderer",
    "the region map has no renderer yet: world, panel, and sprite layers cannot be captured"
  )
  local manifest = fixtureManifest()
  local record = PokegearAssetSchema.validate(manifest)
  Assert.notNil(record, "the synthetic companion catalog must validate through the asset schema")
  assert(record ~= nil, "synthetic catalog validated above")
  local state = PokegearState.new({ seed = 1207 }, { catalog = record.catalog })
  local mapContext = {
    fieldMap = "test.field.johto",
    location = "test.place.johto",
    matrixX = 96,
    matrixY = 64,
    region = "johto",
    unlockLevel = 1,
    specialMode = nil,
    playerGender = "boy",
  }
  local controller = MapController.new({
    state = state,
    assets = record,
    mapContext = mapContext,
    phoneProjection = function(_)
      return {}
    end,
    roamerProjection = {},
    wordEntry = { open = function(_) end, step = function() end, result = function()
      return nil
    end, cancel = function() end },
  })
  local resources = renderResources(scope, manifest)

  -- Every skin paints distinctly through its own prepared chrome: six
  -- commits through one painting path yield six signatures with no
  -- asset rebuild between draws. The skin preference behind each status
  -- resolves that skin's foreground and upper planes, so distinct
  -- signatures prove distinct prepared art, never tint modulation.
  local seen = {}
  for skin = 0, 5 do
    state:setPreference("skin", skin)
    local status = controller:status()
    local canvas = scope:own(love.graphics.newCanvas(256, 192))
    love.graphics.setCanvas(canvas)
    love.graphics.clear(0, 0, 0, 0)
    PokegearMapRenderer.draw(resources, status, skin)
    love.graphics.setCanvas()
    local signature = paintSignature(scope:own(canvas:newImageData()))
    Assert.isNil(seen[signature], "skin " .. skin .. " paints distinctly through its prepared chrome")
    seen[signature] = skin
  end

  -- Region masking repaints across unlock levels: the locked Johto view
  -- and the fully unlocked view differ over a material area while both
  -- keep opaque world and panel content.
  local function drawUnlocked(level)
    local unlocked = MapController.new({
      state = state,
      assets = record,
      mapContext = {
        fieldMap = mapContext.fieldMap,
        location = mapContext.location,
        matrixX = mapContext.matrixX,
        matrixY = mapContext.matrixY,
        region = mapContext.region,
        unlockLevel = level,
        specialMode = nil,
        playerGender = mapContext.playerGender,
      },
      phoneProjection = function(_)
        return {}
      end,
      roamerProjection = {},
      wordEntry = { open = function(_) end, step = function() end, result = function()
        return nil
      end, cancel = function() end },
    })
    local canvas = scope:own(love.graphics.newCanvas(256, 192))
    love.graphics.setCanvas(canvas)
    love.graphics.clear(0, 0, 0, 0)
    PokegearMapRenderer.draw(resources, unlocked:status(), 0)
    love.graphics.setCanvas()
    local data = scope:own(canvas:newImageData())
    unlocked:dispose()
    return data
  end
  local locked = drawUnlocked(1)
  local open = drawUnlocked(3)
  local changed, opaque = 0, 0
  for y = 0, 191 do
    for x = 0, 255 do
      local r1, g1, b1, a1 = locked:getPixel(x, y)
      local r2, g2, b2, _ = open:getPixel(x, y)
      if
        math.floor(r1 * 255 + 0.5) ~= math.floor(r2 * 255 + 0.5)
        or math.floor(g1 * 255 + 0.5) ~= math.floor(g2 * 255 + 0.5)
        or math.floor(b1 * 255 + 0.5) ~= math.floor(b2 * 255 + 0.5)
      then
        changed = changed + 1
      end
      if a1 > 0.5 then
        opaque = opaque + 1
      end
    end
  end
  Assert.isTrue(changed > 500, "unlocking the hidden region repaints its masked patches")
  Assert.isTrue(opaque > 1000, "the masked map keeps opaque world and panel content")

  -- The marking entrance gates input until both completions: taps during
  -- the fade/slide change nothing and publish nothing, while the same
  -- tap after both completions enters the panel.
  local view = assert(controller:status().view, "the map view is published")
  local button = assert(view.markingsButton, "the map view publishes its markings entry")
  local bx, by = button.x + button.width / 2, button.y + button.height / 2
  controller:updateFixed({ { type = "pointer_down", pointerId = "touch:1", x = bx, y = by } })
  controller:updateFixed({ { type = "pointer_up", pointerId = "touch:1", x = bx, y = by } })
  local entering = controller:status()
  Assert.notNil(entering.transition, "the marking entrance runs a transition")
  local gated = controller:status()
  controller:updateFixed({ { type = "pointer_down", pointerId = "touch:2", x = 8, y = 8 } })
  controller:updateFixed({ { type = "pointer_up", pointerId = "touch:2", x = 8, y = 8 } })
  Assert.deepEqual(controller:status().view, gated.view, "entrance input changes no view state")
  Assert.isNil(controller:takeResult(), "gated input publishes no result")
  for _ = 1, 120 do
    local transition = controller:status().transition
    if transition == nil or transition.completed == true then
      break
    end
    controller:updateFixed({})
  end
  local settled = controller:status()
  local transition = settled.transition
  Assert.isTrue(transition == nil or transition.completed == true, "both entrance completions finish")
  Assert.notNil(settled.view.markingPanel, "the settled entrance publishes the marking panel")
  controller:dispose()
end

return GraphicsSmoke.suite(T, { tags = { "pokegear" } })
