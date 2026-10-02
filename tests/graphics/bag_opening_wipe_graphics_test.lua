-- Bag's source opening reveals the hero/sub pane through six downward steps,
-- then reveals the interaction/main pane through a separate six-step leg.
-- A white pane painter makes the production covers directly observable.

local ApplicationLayout = require("libs.ui.src.ApplicationLayout")
local Assert = require("tests.support.Assert")
local BagInterface = require("game.hgss.src.field.BagInterface")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local LogicalSurface = require("libs.ui.src.LogicalSurface")
local ScreenTopology = require("libs.ui.src.ScreenTopology")

local T = {}

local function rect()
  return { x = 0, y = 0, width = 1, height = 1 }
end

local function manifest()
  local tabs, slots, actions = {}, {}, {}
  for index = 1, 8 do
    tabs[index] = { rect = rect() }
  end
  for index = 1, 6 do
    slots[index] = { rect = rect() }
  end
  for index = 1, 4 do
    actions[index] = { hitRect = rect() }
  end
  local controls = {}
  for index, delta in ipairs({ -100, -10, -1, 1, 10, 100 }) do
    controls[index] = { hitRect = rect(), delta = delta, role = index <= 3 and "decrement" or "increment" }
  end
  return {
    interactive = {
      pocketTabs = { rects = tabs },
      itemSlots = { slots = slots },
      cancel = { rect = rect() },
      overlays = {
        descriptionFallback = { frame = rect(), textRect = rect() },
        actionMenu = { slots = actions },
        quantity = {
          controls = controls,
          cancelHitRect = rect(),
          confirm = { hitRect = rect() },
          pressTicks = 1,
        },
      },
    },
  }
end

local function widePlan()
  local interfaces = BagInterface.defaults(manifest())
  local measured = {
    width = 1280,
    height = 720,
    topology = ScreenTopology.oneDisplay({
      id = "main",
      rect = { x = 0, y = 0, width = 1280, height = 720 },
      role = "world",
      touch = false,
    }),
    pixelRatio = 1,
    signature = "bag-opening-graphics:1280x720",
  }
  local selection = ApplicationLayout.selectSurfaces(measured)
  local context = {
    measurement = measured,
    configuration = "wide",
    primary = selection.primary,
    secondary = selection.secondary,
    nativeLikeInterface = interfaces.nativeLike,
  }
  return interfaces.wide(context, {})
end

---@param scope GraphicsScope
---@param opening { subStep: integer, mainStep: integer }
---@return love.ImageData image
---@return ApplicationPlan plan
local function renderPair(scope, opening)
  local plan = widePlan()
  Assert.equal(#plan.panes, 2, "the Bag paired layout carries hero and interaction panes")
  local canvas = scope:own(love.graphics.newCanvas(1280, 720))
  love.graphics.setCanvas(canvas)
  love.graphics.clear(0, 0, 0, 0)
  for _, pane in ipairs(plan.panes) do
    LogicalSurface.draw(love.graphics, pane.placement, function()
      love.graphics.setColor(1, 1, 1, 1)
      love.graphics.rectangle("fill", 0, 0, 256, 192)
    end)
  end
  plan.render({
    graphics = love.graphics,
    bagRenderer = { draw = function() end },
    icons = {},
  }, { opening = opening }, plan)
  love.graphics.setCanvas()
  return scope:own(canvas:newImageData()), plan
end

---@param image love.ImageData
---@param pane table<string, unknown>
---@param lx number
---@param ly number
---@return string
local function sampleState(image, pane, lx, ly)
  local placement = assert(pane.placement)
  local origin = placement.origin or placement.frame
  local scale = assert(placement.scale)
  local r, g, b = image:getPixel(math.floor(origin.x + lx * scale), math.floor(origin.y + ly * scale))
  if r > 0.9 and g > 0.9 and b > 0.9 then
    return "pane"
  end
  if r < 0.1 and g < 0.1 and b < 0.1 then
    return "cover"
  end
  return "other"
end

---@param image love.ImageData
---@param plan ApplicationPlan
---@param paneId string
---@return string top and bottom pixel state
local function probePane(image, plan, paneId)
  local pane = nil
  for _, candidate in ipairs(plan.panes) do
    if candidate.id == paneId then
      pane = candidate
      break
    end
  end
  assert(pane ~= nil, "the plan carries " .. paneId)
  return sampleState(image, pane, 128, 16) .. "-" .. sampleState(image, pane, 128, 176)
end

function T.bag_reveals_hero_first_and_holds_interaction_until_leg_two(scope)
  local firstStart, firstStartPlan = renderPair(scope, { subStep = 0, mainStep = 0 })
  Assert.equal(probePane(firstStart, firstStartPlan, "hero"), "cover-cover", "the hero starts fully covered")
  Assert.equal(
    probePane(firstStart, firstStartPlan, "interaction"),
    "cover-cover",
    "the interaction pane stays covered at opening"
  )

  local heroMid, heroMidPlan = renderPair(scope, { subStep = 3, mainStep = 0 })
  Assert.equal(probePane(heroMid, heroMidPlan, "hero"), "pane-cover", "the hero clears from the top first")
  Assert.equal(
    probePane(heroMid, heroMidPlan, "interaction"),
    "cover-cover",
    "the interaction pane remains covered throughout the hero leg"
  )

  local heroDone, heroDonePlan = renderPair(scope, { subStep = 6, mainStep = 0 })
  Assert.equal(probePane(heroDone, heroDonePlan, "hero"), "pane-pane", "the hero leg completes first")
  Assert.equal(
    probePane(heroDone, heroDonePlan, "interaction"),
    "cover-cover",
    "the interaction cover remains full until leg two"
  )

  local interactionMid, interactionMidPlan = renderPair(scope, { subStep = 6, mainStep = 3 })
  Assert.equal(
    probePane(interactionMid, interactionMidPlan, "hero"),
    "pane-pane",
    "the completed hero stays clear during the interaction leg"
  )
  Assert.equal(
    probePane(interactionMid, interactionMidPlan, "interaction"),
    "pane-cover",
    "the interaction pane clears only during leg two"
  )

  local done, donePlan = renderPair(scope, { subStep = 6, mainStep = 6 })
  Assert.equal(probePane(done, donePlan, "hero"), "pane-pane", "the final hero pane has no cover")
  Assert.equal(probePane(done, donePlan, "interaction"), "pane-pane", "the final interaction pane has no cover")
end

return GraphicsSmoke.suite(T, { tags = { "bag" } })
