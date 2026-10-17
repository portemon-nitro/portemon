-- Script fade covers follow the selected source display surfaces and leave
-- the surrounding presentation geometry untouched.

local Assert = require("tests.support.Assert")
local FakeGraphics = require("tests.support.FakeGraphics")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local FieldState = require("game.hgss.src.field.FieldState")
local ScreenTopology = require("libs.ui.src.ScreenTopology")

local T = {}

local MAIN = { x = 0, y = 0, width = 512, height = 384 }
local AUXILIARY = { x = 0, y = 384, width = 512, height = 384 }

local function drawCover(screenScope, topology)
  local graphics = FakeGraphics.new()
  local priorGraphics = love.graphics
  love.graphics = graphics
  local state = setmetatable({
    runtime = {
      screenTopology = topology,
      screenFade = {
        presentationOverlay = function()
          return { r = 1, g = 1, b = 1, a = 0.5, screenScope = screenScope }
        end,
      },
    },
  }, FieldState)
  local ok, err = xpcall(function()
    state:_drawScriptScreenFadeIfNeeded()
  end, debug.traceback)
  love.graphics = priorGraphics
  if not ok then
    error(err, 0)
  end
  return graphics.rectangles
end

local function assertRect(rect, x, y, message)
  Assert.equal(rect.mode, "fill", message .. " mode")
  Assert.equal(rect.x, x, message .. " x")
  Assert.equal(rect.y, y, message .. " y")
  Assert.equal(rect.w, 512, message .. " width")
  Assert.equal(rect.h, 384, message .. " height")
end

function T.main_scope_covers_only_main_while_both_scope_covers_every_surface()
  local single = ScreenTopology.oneDisplay({ id = "main", rect = MAIN, role = "world", touch = false })
  local singleRects = drawCover("both", single)
  Assert.equal(#singleRects, 1, "a single-screen field receives one full-surface cover")
  assertRect(singleRects[1], 0, 0, "single screen geometry")

  local dual = ScreenTopology.dualDisplay(
    { id = "main", rect = MAIN, role = "world", touch = false },
    { id = "auxiliary", rect = AUXILIARY, role = "auxiliary", touch = true }
  )
  local mainRects = drawCover("main", dual)
  Assert.equal(#mainRects, 1, "the source main scope leaves the auxiliary surface visible")
  assertRect(mainRects[1], 0, 0, "main screen geometry")

  local bothRects = drawCover("both", dual)
  Assert.equal(#bothRects, 2, "the ordinary two-screen fade covers both surfaces")
  assertRect(bothRects[1], 0, 0, "main screen geometry")
  assertRect(bothRects[2], 0, 384, "auxiliary screen geometry")
end

return GraphicsSmoke.suite(T)
