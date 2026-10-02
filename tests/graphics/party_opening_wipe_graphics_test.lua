-- The party reveal paints sequential downward black covers above both panes
-- through the real host composition: panes start fully black, the top edge
-- clears first, one pane finishes before the other starts, and the finished
-- screen shows the pane content with no black left. Synthetic geometry with
-- a flat white pane painter keeps the proof on the cover behavior itself.

local ApplicationLayout = require("libs.ui.src.ApplicationLayout")
local Assert = require("tests.support.Assert")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local PartyScreenInterface = require("game.hgss.src.field.PartyScreenInterface")
local ScreenTopology = require("libs.ui.src.ScreenTopology")

local T = {}

local function manifest()
  local panels = {}
  local origins = { { 0, 0 }, { 128, 8 }, { 0, 48 }, { 128, 56 }, { 0, 96 }, { 128, 104 } }
  for slot, origin in ipairs(origins) do
    panels[slot] = {
      origin = { x = origin[1], y = origin[2] },
      size = { width = 128, height = 48 },
      chrome = {},
      text = {},
      hp = {},
      compat = {},
    }
  end
  local function dpadBox(up, down, leftNeighbor, rightNeighbor)
    return {
      left = 0,
      top = 0,
      width = 0,
      height = 0,
      up = up,
      down = down,
      leftNeighbor = leftNeighbor,
      rightNeighbor = rightNeighbor,
    }
  end
  local function touch(top, bottom, left, right)
    return { top = top, bottom = bottom, left = left, right = right }
  end
  return {
    panels = panels,
    windows = {
      message = { x = 16, y = 168, width = 160, height = 16 },
      context = { x = 152, y = 120, width = 96, height = 64 },
      prompt = { x = 200, y = 80 },
    },
    navigation = {
      dpad = {
        default = {
          dpadBox(7, 2, 7, 1),
          dpadBox(7, 3, 0, 2),
          dpadBox(0, 4, 1, 3),
          dpadBox(1, 5, 2, 4),
          dpadBox(2, 7, 3, 5),
          dpadBox(3, 7, 4, 7),
          dpadBox(0, 0, 0, 0),
          dpadBox(5, 1, 5, 0),
        },
      },
    },
    hitboxes = {
      touch = {
        default = {
          touch(0, 48, 0, 128),
          touch(8, 56, 128, 0),
          touch(48, 96, 0, 128),
          touch(56, 104, 128, 0),
          touch(96, 144, 0, 128),
          touch(104, 152, 128, 0),
          touch(152, 192, 200, 0),
        },
      },
    },
    iconAnimations = { periods = { 1, 8, 12, 24, 40, 36 } },
  }
end

local function widePlan()
  local interfaces = PartyScreenInterface.defaults(manifest())
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
    signature = "party-reveal-graphics:1280x720",
  }
  local selection = ApplicationLayout.selectSurfaces(measured)
  local context = {
    measurement = measured,
    configuration = "wide",
    primary = selection.primary,
    secondary = selection.secondary,
    nativeLikeInterface = interfaces.nativeLike,
  }
  return interfaces.wide(context, { cancellable = true, cursorNode = 0 })
end

---@param image love.ImageData
---@param placement table<string, unknown>
---@param lx number
---@param ly number
---@return number r
---@return number g
---@return number b
local function sample(image, placement, lx, ly)
  local frame = assert(placement.frame, "the pane carries its host frame")
  local origin = placement.origin or frame
  local scale = assert(placement.scale, "the pane carries its render scale")
  local x = math.floor(origin.x + lx * scale)
  local y = math.floor(origin.y + ly * scale)
  local r, g, b = image:getPixel(x, y)
  return r, g, b
end

---@param r number
---@param g number
---@param b number
---@return boolean
local function isPane(r, g, b)
  return r > 0.9 and g > 0.9 and b > 0.9
end

---@param r number
---@param g number
---@param b number
---@return boolean
local function isCover(r, g, b)
  return r < 0.1 and g < 0.1 and b < 0.1
end

---@param scope GraphicsScope
---@param opening { subStep: integer, mainStep: integer }? the reveal progress, or nil once interactive
---@return love.ImageData image
---@return ApplicationPlan plan
local function renderPair(scope, opening)
  local plan = widePlan()
  Assert.equal(#plan.panes, 2, "the paired plan under test carries both panes")
  local canvas = scope:own(love.graphics.newCanvas(1280, 720))
  love.graphics.setCanvas(canvas)
  love.graphics.clear(0, 0, 0, 0)
  local resources = {
    graphics = love.graphics,
    partyScreenRenderer = {
      drawPane = function()
        love.graphics.setColor(1, 1, 1, 1)
        love.graphics.rectangle("fill", 0, 0, 256, 192)
      end,
    },
    icons = {},
  }
  plan.render(resources, { cancellable = true, cursorNode = 0, opening = opening }, plan)
  love.graphics.setCanvas()
  return scope:own(canvas:newImageData()), plan
end

---@param image love.ImageData
---@param plan ApplicationPlan
---@param index integer
---@return string top and bottom probe state, one of "pane-pane", "pane-cover", or "cover-cover"
local function probePane(image, plan, index)
  local placement = assert(plan.panes[index].placement, "the pane carries its placement")
  local topR, topG, topB = sample(image, placement, 128, 16)
  local bottomR, bottomG, bottomB = sample(image, placement, 128, 176)
  local top = isPane(topR, topG, topB) and "pane" or (isCover(topR, topG, topB) and "cover" or "other")
  local bottom = isPane(bottomR, bottomG, bottomB) and "pane"
    or (isCover(bottomR, bottomG, bottomB) and "cover" or "other")
  return top .. "-" .. bottom
end

function T.reveal_covers_both_panes_then_clears_first_before_second(scope)
  local start, startPlan = renderPair(scope, { subStep = 0, mainStep = 0 })
  Assert.equal(probePane(start, startPlan, 1), "cover-cover", "the first pane starts fully covered")
  Assert.equal(probePane(start, startPlan, 2), "cover-cover", "the second pane starts fully covered")

  local midFirst, midFirstPlan = renderPair(scope, { subStep = 3, mainStep = 0 })
  local firstProbe = probePane(midFirst, midFirstPlan, 1)
  local secondProbe = probePane(midFirst, midFirstPlan, 2)
  Assert.isTrue(
    (firstProbe == "pane-cover" and secondProbe == "cover-cover")
      or (firstProbe == "cover-cover" and secondProbe == "pane-cover"),
    "midway through the first leg one pane clears from the top while the other stays covered"
  )
  local firstLeg = firstProbe == "pane-cover" and 1 or 2

  local subDone, subDonePlan = renderPair(scope, { subStep = 6, mainStep = 0 })
  Assert.equal(
    probePane(subDone, subDonePlan, firstLeg),
    "pane-pane",
    "the first leg fully clears one pane before the other starts"
  )
  Assert.equal(
    probePane(subDone, subDonePlan, 3 - firstLeg),
    "cover-cover",
    "the remaining pane stays covered until the first leg completes"
  )

  local midSecond, midSecondPlan = renderPair(scope, { subStep = 6, mainStep = 3 })
  Assert.equal(
    probePane(midSecond, midSecondPlan, firstLeg),
    "pane-pane",
    "the cleared pane stays clear while the second leg runs"
  )
  Assert.equal(
    probePane(midSecond, midSecondPlan, 3 - firstLeg),
    "pane-cover",
    "the second leg clears the remaining pane from the top"
  )

  local done, donePlan = renderPair(scope, { subStep = 6, mainStep = 6 })
  Assert.equal(probePane(done, donePlan, 1), "pane-pane", "the completed reveal leaves no cover behind")
  Assert.equal(probePane(done, donePlan, 2), "pane-pane", "the completed reveal leaves no cover behind")

  local settled, settledPlan = renderPair(scope, nil)
  Assert.equal(probePane(settled, settledPlan, 1), "pane-pane", "the interactive screen carries no cover")
  Assert.equal(probePane(settled, settledPlan, 2), "pane-pane", "the interactive screen carries no cover")
end

function T.reveal_boundary_moves_downward_across_first_leg_steps(scope)
  local mid, midPlan = renderPair(scope, { subStep = 3, mainStep = 0 })
  local firstLeg = probePane(mid, midPlan, 1) == "pane-cover" and 1 or 2
  local states = {}
  for subStep = 0, 6 do
    local image, imagePlan = renderPair(scope, { subStep = subStep, mainStep = 0 })
    local placement = assert(imagePlan.panes[firstLeg].placement, "the pane carries its placement")
    local r, g, b = sample(image, placement, 128, 80)
    states[#states + 1] = isCover(r, g, b) and "cover" or (isPane(r, g, b) and "pane" or "other")
  end
  Assert.deepEqual(
    states,
    { "cover", "cover", "cover", "pane", "pane", "pane", "pane" },
    "the first-leg boundary passes the middle row monotonically from the top"
  )
end

return GraphicsSmoke.suite(T, { tags = { "party" } })
