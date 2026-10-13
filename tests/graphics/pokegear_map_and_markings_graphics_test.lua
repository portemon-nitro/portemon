-- The gear region-map presentation in pixels: the world layer shows through
-- the chrome opening under its scroll and zoom, objects draw under the
-- chrome, the information pane composes the frame, preview and panel
-- sprites, marking mode swaps in its backdrop and panel with the source
-- slide, and every skin paints its own prepared planes. Every plane is a
-- solid host-boundary fake hung on a genuine validated manifest path, so
-- pixel comparisons never copy commercial bytes and a wrong plane is a
-- colour mismatch.

local Assert = require("tests.support.Assert")
local Fixture = require("tests.support.PokegearMapFixture")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")

local T = {}

---@param node table
---@param out table<string, table>
local function collectVisuals(node, out)
  if type(node) ~= "table" then
    return
  end
  if type(node.image) == "string" then
    out[node.image] = node
    return
  end
  for _, child in pairs(node) do
    collectVisuals(child, out)
  end
end

-- The deterministic colour of a path, so a test can name the plane it
-- expects at a pixel.
---@param path string
---@return number red
---@return number green
---@return number blue
local function colorOf(path)
  local hash = 7
  for index = 1, #path do
    hash = (hash * 31 + path:byte(index)) % 9973
  end
  return (hash % 13) / 14 + 0.05, (math.floor(hash / 13) % 13) / 14 + 0.05, (math.floor(hash / 169) % 13) / 14 + 0.05
end

-- Solid fakes with two structured exceptions: the world planes encode their
-- own layer coordinates in red and green so a pixel names the world point it
-- shows, and the chrome planes keep the source's transparent map opening.
---@param scope table
---@param manifest table
---@return table resources
local function renderResources(scope, manifest)
  local visuals = {}
  collectVisuals(manifest, visuals)
  local images = {}
  for path, visual in pairs(visuals) do
    local data = scope:own(love.image.newImageData(visual.width, visual.height))
    local red, green, blue = colorOf(path)
    local isWorld = path:find("map%-world") ~= nil
    local isChrome = path:find("map%-foreground") ~= nil
    data:mapPixel(function(x, y)
      if isWorld then
        return (x % 256) / 255, (y % 256) / 255, 0.5, 1
      elseif isChrome and x >= 8 and x < 200 and y >= 8 and y < 152 then
        return 0, 0, 0, 0
      end
      return red, green, blue, 1
    end)
    images[path] = scope:own(love.graphics.newImage(data))
  end
  return { graphics = love.graphics, images = images }
end

---@param scope table
---@param resources table
---@param controller table
---@param pane string "controls" or "information"
---@param shell table?
---@return table imageData
local function draw(scope, resources, controller, pane, shell)
  local status = controller:status()
  local plan = status.presentation
  local canvas = scope:own(love.graphics.newCanvas(256, 192))
  love.graphics.setCanvas(canvas)
  love.graphics.clear(0, 0, 0, 0)
  love.graphics.setColor(1, 1, 1, 1)
  if pane == "controls" then
    plan.render(resources, status, plan, shell or { entered = true })
  else
    plan.renderInformation(resources, status, plan)
  end
  love.graphics.setCanvas()
  return scope:own(canvas:newImageData())
end

---@param data table
---@param x integer
---@param y integer
---@return string key a coarse colour identity
local function pixelKey(data, x, y)
  local red, green, blue, alpha = data:getPixel(x, y)
  return string.format("%.2f/%.2f/%.2f/%.0f", red, green, blue, alpha)
end

---@param path string
---@return string
local function keyOf(path)
  local red, green, blue = colorOf(path)
  return string.format("%.2f/%.2f/%.2f/1", red, green, blue)
end

local function skinPath(section, skin)
  return "assets/generated/pokegear/" .. section .. "-skin-" .. skin .. ".png"
end

---@param data table
---@param view table
---@param x number screen x
---@param y number screen y
---@return number worldX
---@return number worldY
local function worldPoint(view, x, y)
  local world = view.world
  local r = world.ratio
  return (x + world.scrollX + world.xOffset + (r - 1) * world.affineX) / r,
    (y + world.scrollY + (r - 1) * world.affineY) / r
end

function T.the_world_shows_through_the_chrome_opening_at_its_transform(scope)
  local manifest = Fixture.manifest()
  local resources = renderResources(scope, manifest)
  local box = Fixture.openMap({ record = Fixture.record(manifest) })
  for _, zoom in ipairs({ false, true }) do
    if zoom then
      box.controller:updateFixed({ { type = "menu" } })
      Fixture.tick(box.controller, 4)
    end
    local view = box.controller:status().view
    local data = draw(scope, resources, box.controller, "controls")
    Assert.equal(pixelKey(data, 4, 4), keyOf(skinPath("map-foreground", 0)), "the chrome frame draws over the world")
    -- A pixel inside the opening names the world point under the transform.
    local x, y = 60, 40
    local worldX, worldY = worldPoint(view, x, y)
    local red, green = data:getPixel(x, y)
    Assert.isTrue(
      math.abs(red - (math.floor(worldX) % 256) / 255) < 0.02
        and math.abs(green - (math.floor(worldY) % 256) / 255) < 0.02,
      (zoom and "zoomed" or "unzoomed") .. " opening shows the world point under the layer transform"
    )
  end
end

function T.the_cursor_sprite_draws_under_the_chrome_on_its_cell(scope)
  local manifest = Fixture.manifest()
  local resources = renderResources(scope, manifest)
  local box = Fixture.openMap({ record = Fixture.record(manifest) })
  local view = box.controller:status().view
  local cursor = view.sprites.cursor
  local data = draw(scope, resources, box.controller, "controls")
  local frame = box.controller:status().presentation.content.sprites.mapObjects[1].frames[1].image
  Assert.equal(
    pixelKey(data, math.floor(cursor.x), math.floor(cursor.y)),
    keyOf(frame),
    "the cursor sprite draws on its selected cell"
  )
  local hidden = draw(scope, resources, box.controller, "controls", { entered = false })
  Assert.isTrue(
    pixelKey(hidden, math.floor(cursor.x), math.floor(cursor.y)) ~= keyOf(frame),
    "the cursor sprite hides while focus is on the tab strip"
  )
end

function T.the_information_pane_composes_frame_preview_and_markers(scope)
  local manifest = Fixture.manifest()
  local resources = renderResources(scope, manifest)
  local box = Fixture.openMap({ record = Fixture.record(manifest) })
  box.state:setMarking("MAP_A", { icons = { 2, false, false, false }, words = { false, false, false, false } })
  local data = draw(scope, resources, box.controller, "information")
  -- The frame plane covers the panel rows; the preview block sits behind its frame
  -- hole, so only the frame plane's colour shows in the solid fake.
  Assert.equal(pixelKey(data, 4, 120), keyOf(skinPath("map-upper", 0)), "the info frame draws its rows")
  -- The first marker sprite lands at its rest position under the frame.
  local marker = box.controller:status().presentation.content.sprites.markers[1].frames[2].image
  Assert.equal(pixelKey(data, 32, 155), keyOf(marker), "the saved icon draws at its panel marker position")
end

function T.marking_mode_swaps_in_its_backdrop_and_slides_its_panel(scope)
  local manifest = Fixture.manifest()
  local resources = renderResources(scope, manifest)
  local box = Fixture.openMap({ record = Fixture.record(manifest) })
  box.controller:updateFixed({ { type = "confirm" } })
  local sawHidden, sawShown = false, false
  for _ = 1, 40 do
    Fixture.tick(box.controller)
    local view = box.controller:status().view
    if view.mode == "marking" then
      local data = draw(scope, resources, box.controller, "controls")
      if view.bottomSlide >= 112 then
        sawHidden = true
        Assert.equal(
          pixelKey(data, 10, 50),
          keyOf(skinPath("map-marking-backdrop", 0)),
          "the hidden panel leaves only the backdrop"
        )
      elseif view.bottomSlide == 0 then
        sawShown = true
        Assert.equal(
          pixelKey(data, 10, 50),
          keyOf(skinPath("map-marking-panel", 0)),
          "the settled panel covers the top of the screen"
        )
      end
    end
    if not box.controller:status().busy then
      break
    end
  end
  Assert.isTrue(sawHidden and sawShown, "the panel slides from hidden to shown")
end

function T.every_skin_paints_its_own_prepared_planes(scope)
  local manifest = Fixture.manifest()
  local resources = renderResources(scope, manifest)
  local seen = {}
  for skin = 0, 5 do
    local record = Fixture.record(manifest)
    local box = Fixture.openMap({ record = record })
    box.state:setPreference("skin", skin)
    local data = draw(scope, resources, box.controller, "controls")
    local key = pixelKey(data, 4, 4)
    Assert.equal(key, keyOf(skinPath("map-foreground", skin)), "skin " .. skin .. " draws its own chrome")
    Assert.isNil(seen[key], "skin " .. skin .. " paints distinctly from the others")
    seen[key] = true
  end
end

local suite = GraphicsSmoke.suite(T, { tags = { "pokegear" } })
return suite
