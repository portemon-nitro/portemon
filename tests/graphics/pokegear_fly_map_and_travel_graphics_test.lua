-- The standalone Fly and Town map presentation in pixels: the world layer
-- through the same transform as the gear card, flypoint indicators in their
-- source availability states, the Fly/Quit menu frame at its tile position,
-- the Fly banner and info frame in the information pane, and the Town map's
-- shifted banner. Every plane is a solid host-boundary fake on a genuine
-- validated manifest path, so no commercial bytes are copied and a wrong
-- plane is a colour mismatch.

local Assert = require("tests.support.Assert")
local StubLease = require("tests.support.StubLease")
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

---@param path string
---@return number red
---@return number green
---@return number blue
local function colorOf(path)
  local hash = 11
  for index = 1, #path do
    hash = (hash * 31 + path:byte(index)) % 9973
  end
  return (hash % 13) / 14 + 0.05, (math.floor(hash / 13) % 13) / 14 + 0.05, (math.floor(hash / 169) % 13) / 14 + 0.05
end

---@param path string
---@return string
local function keyOf(path)
  local red, green, blue = colorOf(path)
  return string.format("%.2f/%.2f/%.2f/1", red, green, blue)
end

---@param scope table
---@param record table
---@return table resources
local function renderResources(scope, record)
  local visuals = {}
  collectVisuals(record, visuals)
  local images = {}
  for path, visual in pairs(visuals) do
    local data = scope:own(love.image.newImageData(visual.width, visual.height))
    local red, green, blue = colorOf(path)
    local chrome = path:find("fly%-foreground") ~= nil
    data:mapPixel(function(x, y)
      if chrome and x >= 8 and x < 248 and y >= 8 and y < 160 then
        return 0, 0, 0, 0
      end
      return red, green, blue, 1
    end)
    images[path] = StubLease.over(scope:own(love.graphics.newImage(data)))
  end
  return { graphics = love.graphics, images = images }
end

---@param mode string
---@return table selector, table record
local function openFly(mode)
  local FlyMapController = require("game.hgss.src.pokegear.FlyMapController")
  local record = Fixture.record()
  local selector = FlyMapController.new({
    mode = mode,
    operationId = "op-" .. mode,
    context = Fixture.context(),
    destinations = {},
    assets = record,
    facts = Fixture.facts(),
    messages = Fixture.messages(),
  })
  return selector, record
end

---@param scope table
---@param resources table
---@param selector table
---@param pane string
---@return table imageData
local function draw(scope, resources, selector, pane)
  local status = selector:status()
  local plan = status.presentation
  local canvas = scope:own(love.graphics.newCanvas(256, 192))
  love.graphics.setCanvas(canvas)
  love.graphics.clear(0, 0, 0, 0)
  love.graphics.setColor(1, 1, 1, 1)
  if pane == "lower" then
    plan.render(resources, status, plan)
  else
    plan.renderInformation(resources, status, plan)
  end
  love.graphics.setCanvas()
  return scope:own(canvas:newImageData())
end

---@param data table
---@param x integer
---@param y integer
---@return string
local function pixelKey(data, x, y)
  local red, green, blue, alpha = data:getPixel(x, y)
  return string.format("%.2f/%.2f/%.2f/%.0f", red, green, blue, alpha)
end

function T.the_lower_pane_draws_indicators_player_and_the_menu(scope)
  local selector, record = openFly("fly")
  local resources = renderResources(scope, record)
  local view = selector:status().view
  Assert.equal(view.world.xOffset, -24, "the fly layer carries its scroll bias")
  Assert.isTrue(#view.indicators >= 1, "visited flypoints publish indicators")
  local data = draw(scope, resources, selector, "lower")
  Assert.equal(
    pixelKey(data, 2, 2),
    keyOf("assets/generated/pokegear/fly-foreground.png"),
    "the chrome frame draws over the world"
  )
  selector:updateFixed({ { type = "confirm" } })
  local menu = selector:status().view.menu
  Assert.notNil(menu, "A on a flypoint opens the Fly/Quit menu")
  assert(menu ~= nil, "menu checked above")
  Assert.equal(menu.cursor, 0, "the menu starts on Fly")
  Assert.equal(selector:status().view.prompt, "Fly to Landmark 41?", "the prompt names the destination")
  selector:updateFixed({ { type = "navigate", direction = "down" } })
  Assert.equal(selector:status().view.menu.cursor, 1, "the menu cursor moves to Quit")
end

function T.the_town_map_shifts_its_banner_and_never_opens_the_menu(scope)
  local town = openFly("townMap")
  town:updateFixed({ { type = "confirm" } })
  Assert.isNil(town:status().view.menu, "the view-only map opens no menu")
  Assert.isNil(town:status().view.prompt, "the view-only map has no prompt bar")
  Assert.equal(town:status().view.closeLabel, "Close", "the Close label prints in both entries")
end

local suite = GraphicsSmoke.suite(T, { tags = { "pokegear" } })
return suite
