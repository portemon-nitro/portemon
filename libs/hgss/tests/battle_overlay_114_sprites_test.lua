local Assert = require("tests.support.Assert")
local Overlay114Effect = require("libs.hgss.src.transition.battle.Overlay114Effect")
local Overlay114Sprites = require("libs.hgss.src.transition.battle.Overlay114Sprites")

local T = {}

function T.rasterizes_pinned_obj_tile_order_and_transparency()
  local chars = { depth = 3, tiles = string.char(0x10) .. string.rep(string.char(0x11), 31) }
  local palette = { colors = { { r = 9, g = 8, b = 7 }, { r = 240, g = 20, b = 10 } } }
  local cell = { objs = { { tile = 0, width = 8, height = 8, x = -2, y = 3, palette = 0 } } }
  local image = Overlay114Sprites.renderCell(chars, palette, cell, 0)
  Assert.equal(image.width, 8, "one source OBJ has its source width")
  Assert.equal(image.height, 8, "one source OBJ has its source height")
  Assert.equal(image.origin.x, -2, "cell preserves the signed source x origin")
  Assert.equal(image.origin.y, 3, "cell preserves the signed source y origin")
  Assert.equal(string.byte(image.pixels, 4), 0, "OBJ palette color zero remains transparent")
  Assert.equal(string.byte(image.pixels, 8), 255, "nonzero color has full source alpha")
  Assert.equal(string.byte(image.pixels, 5), 240, "low nibble is the first 4bpp pixel")
  Assert.equal(string.byte(image.pixels, 9), 240, "high nibble is the second 4bpp pixel")
end

function T.generic_callbacks_keep_one_versus_four_real_source_cells()
  local resources = {
    palette = { colors = { { r = 0, g = 0, b = 0 }, { r = 240, g = 20, b = 10 } } },
    characters = { depth = 3, tiles = string.rep(string.char(0x11), 32) },
    cells = {
      cells = {
        { objs = { { tile = 0, width = 8, height = 8, x = -4, y = -4, palette = 0 } } },
      },
    },
    animation = {
      anims = {
        {
          frames = { { cell = 0, duration = 1, translateX = 0, translateY = 0, scaleX = 1, scaleY = 1, rotation = 0 } },
        },
      },
    },
  }
  local loaded = {
    paletteKey = resources.palette,
    charsKey = resources.characters,
    cellKey = resources.cells,
    animKey = resources.animation,
  }
  local trainer = Overlay114Sprites.createForRoute({
    role = "generic-trainer-transition",
    assetGroups = {
      sprite = { palette = "paletteKey", character = "charsKey", cell = "cellKey", animation = "animKey" },
    },
  }, loaded)
  local wild = Overlay114Sprites.createForRoute({
    role = "generic-wild-transition",
    assetGroups = {
      sprite = { palette = "paletteKey", character = "charsKey", cell = "cellKey", animation = "animKey" },
    },
  }, loaded)
  Assert.equal(#trainer, 1, "trainer callback creates one sprite")
  Assert.equal(#wild, 4, "wild callback creates four sprites")
  for _, sprite in ipairs({ trainer[1], wild[1], wild[2], wild[3], wild[4] }) do
    Assert.equal(sprite.image.width, 8, "each callback renders the declared source cell")
    Assert.equal(string.byte(sprite.image.pixels, 4), 255, "source cell color reaches the rendered sprite")
    Assert.equal(sprite.affine.scaleX, 1, "source affine scale is retained")
    Assert.equal(sprite.affine.rotation, 0, "source affine rotation is retained")
  end
end

function T.generic_wild_callback_keeps_four_sprites_through_affine_task_and_disposes_at_state_seven()
  local resources = {
    palette = {
      colors = { { r = 0, g = 0, b = 0 }, { r = 240, g = 20, b = 10 }, { r = 10, g = 240, b = 20 } },
    },
    characters = { depth = 3, tiles = string.rep(string.char(0x11), 32) .. string.rep(string.char(0x22), 32) },
    cells = {
      cells = {
        { objs = { { tile = 0, width = 8, height = 8, x = -4, y = -4, palette = 0 } } },
        { objs = { { tile = 1, width = 8, height = 8, x = -4, y = -4, palette = 0 } } },
      },
    },
    animation = {
      anims = {
        {
          frames = {
            { cell = 0, duration = 1, translateX = 0, translateY = 0, scaleX = 1, scaleY = 1, rotation = 0 },
            { cell = 1, duration = 2, translateX = 1, translateY = 0, scaleX = 1, scaleY = 1, rotation = 0 },
          },
        },
      },
    },
  }
  local effect = Overlay114Effect.new({
    role = "generic-wild-transition",
    assetGroups = { sprite = { palette = "p", character = "c", cell = "n", animation = "a" } },
  }, { p = resources.palette, c = resources.characters, n = resources.cells, a = resources.animation })
  effect:start()
  Assert.equal(effect:stepSourceTick(), false, "wild callback state zero creates sprites")
  local frame = effect:frame()
  Assert.equal(frame.sourcePhase, 1, "wild callback advances from source state zero")
  Assert.equal(#frame.sprites, 4, "wild callback creates four source sprites")
  Assert.equal(frame.sprites[4].visible, false, "wild sprites remain hidden through task setup")
  Assert.equal(frame.sprites[4].position.x, 0x80000, "wild source sprites share the callback x coordinate")
  Assert.equal(frame.sprites[4].position.y, 0x60000, "wild source sprites share the callback y coordinate")
  Assert.equal(frame.sprites[4].image.width, 8, "all four sprites carry the decoded source cell pixels")
  Assert.equal(
    string.byte(frame.sprites[4].image.pixels, 5),
    10,
    "native sprite task advances to its declared second cell"
  )
  local ticks = 0
  while effect:frame().sourcePhase < 3 and ticks < 30 do
    effect:stepSourceTick()
    ticks = ticks + 1
  end
  Assert.equal(effect:frame().sourcePhase, 3, "wild callback waits for its source HBlank task")
  Assert.equal(ticks < 30, true, "wild child task terminates from its source loop count")
  effect:stepSourceTick()
  Assert.equal(effect:frame().sourcePhase, 4, "wild callback shows sprites before its affine task")
  Assert.equal(effect:frame().sprites[1].visible, true, "wild source state three shows sprite objects")
  effect:stepSourceTick()
  Assert.equal(effect:frame().matrices[1][1], 0x80000, "first sprite keeps its source x position at frame zero")
  Assert.equal(effect:frame().matrices[1][2], 0x60000, "first sprite keeps its source y position at frame zero")
  effect:stepSourceTick()
  Assert.equal(
    effect:frame().matrices[1][2],
    0x60000 - 33075,
    "quadratic helper preserves the source fixed-point rounding at frame one"
  )
  Assert.equal(
    effect:frame().matrices[3][1],
    0x80000 - 41267,
    "vertical helper uses its independent source velocity and endpoint"
  )
  for _ = 1, 3 do
    effect:stepSourceTick()
  end
  Assert.equal(effect:frame().sourcePhase, 5, "four-tick affine helper completes before palette fade")
  Assert.equal(effect:frame().affineValue, 0xA0000, "wild matrix task reaches its source terminal coefficient")
  Assert.equal(
    effect:frame().matrices[1][2],
    0x60000 - 0x80000,
    "first sprite position reaches the source negative x endpoint"
  )
  Assert.equal(
    effect:frame().matrices[4][1],
    0x80000 + 0xA0000,
    "fourth sprite position reaches the source positive y endpoint"
  )
  effect:stepSourceTick()
  Assert.equal(effect:frame().sourcePhase, 6, "wild source enters its mirrored-sector fade")
  Assert.equal(effect:frame().wipe.kind, "mirrored-sector", "wild route selects the source FadeFunc_34 geometry")
  Assert.equal(effect:frame().wipe.step, 0, "wild sector fade begins at its source starting phase")
  Assert.equal(effect:frame().wipe.rows[1][1][1], 1, "source sector begins at its left screen edge")
  Assert.equal(effect:frame().wipe.rows[1][1][2], 128, "source sector begins at the center seam")
  Assert.equal(effect:frame().wipe.rows[1][2][1], 128, "second source window starts at the center seam")
  Assert.equal(effect:frame().wipe.rows[1][2][2], 255, "second source window reaches its right edge")
  effect:stepSourceTick()
  Assert.equal(effect:frame().wipe.step, 1, "source fade advances by one field tick")
  Assert.equal(effect:frame().wipe.rows[1][1][2], 119, "first sector edge follows the pinned tangent step")
  Assert.equal(effect:frame().wipe.rows[1][2][1], 137, "opposing sector edge follows the pinned tangent step")
  for _ = 1, 11 do
    if effect:stepSourceTick() then
      break
    end
  end
  Assert.equal(effect:frame().sourcePhase, 7, "wild callback completes after palette fade and cleanup")
  Assert.equal(#effect:frame().sprites, 0, "wild callback releases all four owned sprites")
  Assert.equal(effect:frame().ownsResources, false, "wild callback releases all decoded resources")
end

return { tests = T }
