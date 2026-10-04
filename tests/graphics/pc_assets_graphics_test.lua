-- Independent decoded G2D fixture projection for PC presentation graphics.

local Assert = require("tests.support.Assert")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local G2dRasterizer = require("romdump.src.digest.ui.G2dRasterizer")
local PcGraphicsFixture = require("tests.support.PcGraphicsFixture")

local T = {}

local function solidRgba(r, g, b, width, height)
  return string.char(r, g, b, 255):rep(width * height)
end

function T.pc_assets_preserve_independent_decoded_graphics()
  local fixture = PcGraphicsFixture.new()
  local screen = G2dRasterizer.renderScreen(fixture.char, fixture.palette, fixture.screen)
  Assert.equal(screen.width, 8)
  Assert.equal(screen.height, 8)
  Assert.equal(screen.pixels, solidRgba(255, 0, 0, 8, 8), "screen tile color comes from palette slot one")

  local frame = G2dRasterizer.renderAnimationFrame(fixture.char, fixture.palette, fixture.cell, fixture.animation, 1)
  Assert.equal(frame.width, 8)
  Assert.equal(frame.height, 8)
  Assert.deepEqual(frame.offset, { x = -2, y = 3 }, "negative cell anchor survives rasterization")
  Assert.equal(frame.pixels, solidRgba(255, 0, 0, 8, 8), "cell tile color comes from palette slot one")
end

function T.g2d_tile_strip_keeps_source_tile_order_and_palette_bank()
  local fixture = PcGraphicsFixture.new()
  local colors = {}
  for index = 1, 18 do
    colors[index] = { r = 0, g = 0, b = 0 }
  end
  colors[2] = { r = 255, g = 0, b = 0 }
  colors[3] = { r = 0, g = 255, b = 0 }
  colors[19] = { r = 0, g = 0, b = 255 }
  fixture.palette.colors = colors

  local strip = G2dRasterizer.renderTileStrip(fixture.char, fixture.palette, 0, 2, 0)
  Assert.equal(strip.width, 16, "selected source tiles retain their row order")
  Assert.equal(strip.height, 8, "tile strips are one source tile high")
  Assert.equal(strip.pixels:sub(1, 4), string.char(255, 0, 0, 255), "first source tile is retained")
  Assert.equal(strip.pixels:sub(8 * 4 + 1, 8 * 4 + 4), string.char(0, 255, 0, 255), "second source tile follows")

  local accent = G2dRasterizer.renderTileStrip(fixture.char, fixture.palette, 1, 1, 1)
  Assert.equal(accent.width, 8, "starting tile offset is honored")
  Assert.equal(accent.height, 8)
  Assert.equal(accent.pixels:sub(1, 4), string.char(0, 0, 255, 255), "selected palette bank is honored")
end

local suite = GraphicsSmoke.suite(T)
suite.metadata.capabilities = { "graphics" }
return suite
