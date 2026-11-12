-- CPU picture-source copies: bound index frames and base palettes feed
-- native copy operations, front-Spinda personalization follows the
-- source spot rows, and the static char buffer packs the six native
-- tile rectangles in order. Live animation frames never leak into
-- copies; unbound activations keep the established live behavior.

local Assert = require("tests.support.Assert")
local BattleScene = require("libs.hgss.src.presentation.BattleScene")

local T = {}

local function sceneWithPair()
  local scene = BattleScene.new()
  scene:observe({
    { combatant = 1, activation = 1, visible = true },
    { combatant = 3, activation = 3, visible = true },
  })
  return scene
end

local function flatPlane(value)
  local parts = {}
  for _ = 1, 6400 do
    parts[#parts + 1] = string.char(value)
  end
  return table.concat(parts)
end

local function sourceWith(frame0, frame1, palette)
  return {
    width = 80,
    height = 80,
    indexFrames = { frame0, frame1 },
    basePaletteRgb555 = palette or { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 },
    personalization = nil,
  }
end

local function spindaSource(frame0)
  local MonSources = require("romdump.src.config.MonSources")
  local source = sourceWith(frame0, flatPlane(0))
  source.personalization = {
    kind = "spinda",
    spotRows = MonSources.SPINDA_SPOT_ROWS,
    secondFrameXOffset = -14,
  }
  return source
end

function T.unbound_activations_snapshot_no_static_copy()
  local scene = sceneWithPair()
  local activation = { combatant = 1, activation = 1 }
  Assert.isNil(scene:pictureSource(activation), "no binding reads back before appearance binds it")
  Assert.isNil(scene:materializeCopyChar(activation), "copies need a bound source")
end

function T.bound_sources_snapshot_the_static_first_frame()
  local scene = sceneWithPair()
  local activation = { combatant = 1, activation = 1 }
  local first = flatPlane(3)
  local second = flatPlane(9)
  scene:setPictureSource(activation, sourceWith(first, second))
  local bound = assert(scene:pictureSource(activation), "the binding reads back")
  Assert.equal(#bound.indexFrames[1], 6400, "the first frame keeps its exact indices")
  Assert.equal(#bound.basePaletteRgb555, 16, "the base palette keeps sixteen words")
  local snapshot = assert(scene:materializeCopyChar(activation), "the bound copy materializes")
  Assert.equal(#snapshot.charBuffer, 3200, "the static char buffer packs six tile rectangles")
  Assert.equal(#snapshot.basePaletteRgb555, 16, "the snapshot carries a fresh base palette")
end

function T.copy_slots_snapshot_the_creation_time_portrait_selector()
  -- The managed copy freezes the creation-time portrait selector for
  -- the renderer: later live frame, palette, form, or visibility
  -- mutations move only the source-defined follow transform, never the
  -- copy's pixels.
  local scene = sceneWithPair()
  local activation = { combatant = 1, activation = 1 }
  scene:setPictureSource(activation, sourceWith(flatPlane(2), flatPlane(0)))
  scene:applyPictureState(activation, { portraitSelector = "LEAD/0/male/plain/back" })
  scene:setBattlerSpriteSlot("probe:1", 0, activation, true)
  local frozen = nil
  for _, view in ipairs(scene:effectViews()) do
    if type(view.picture) == "table" and view.picture.frozenSelector ~= nil then
      frozen = view.picture
    end
  end
  Assert.notNil(frozen, "the bound copy carries its frozen selector")
  Assert.equal(
    frozen.frozenSelector,
    "LEAD/0/male/plain/back",
    "the frozen selector is the creation-time portrait"
  )
  Assert.equal(frozen.follow, true, "the slot retains the source follow flag")
  -- A later live mutation of the same activation never rewrites the
  -- frozen copy.
  scene:applyPictureState(activation, { portraitSelector = "LEAD/1/male/plain/back" })
  local refrozen = nil
  for _, view in ipairs(scene:effectViews()) do
    if type(view.picture) == "table" and view.picture.frozenSelector ~= nil then
      refrozen = view.picture
    end
  end
  Assert.equal(
    refrozen.frozenSelector,
    "LEAD/0/male/plain/back",
    "the frozen copy ignores later live portrait changes"
  )
end

function T.copy_slots_snapshot_bound_sources_and_ignore_unbound_ones()
  local scene = sceneWithPair()
  local boundActivation = { combatant = 1, activation = 1 }
  scene:setPictureSource(boundActivation, sourceWith(flatPlane(2), flatPlane(0)))
  scene:setBattlerSpriteSlot("probe:1", 0, boundActivation, false)
  local views = scene:effectViews()
  Assert.isTrue(#views >= 1, "the copy stages its effect record")
  local pictured = false
  for _, view in ipairs(views) do
    if type(view.picture) == "table" and view.picture.sourceChar ~= nil then
      pictured = true
      Assert.equal(#view.picture.sourceChar, 3200, "the slot snapshots the static char buffer")
      Assert.equal(#view.picture.sourcePalette, 16, "the slot snapshots the fresh base palette")
    end
  end
  Assert.isTrue(pictured, "the bound copy carries its static snapshot")
  scene:setBattlerSpriteSlot("probe:1", 1, { combatant = 3, activation = 3 }, false)
  local bare = 0
  for _, view in ipairs(scene:effectViews()) do
    if type(view.picture) == "table" and view.picture.sourceChar == nil then
      bare = bare + 1
    end
  end
  Assert.isTrue(bare >= 1, "unbound activations keep the established live behavior")
end

-- Personality zero shifts every spot by (-8, -8): spot set 0 row
-- {15,27,30} lands on (19..22, 7). Indices 1,2,3 become 6,7,8 while 4
-- and 9 stay, exercising the once-only overlap rule on distinct pixels.
local function pidZeroPlane()
  local bytes = {}
  for _ = 1, 6400 do
    bytes[#bytes + 1] = 0
  end
  bytes[7 * 80 + 19 + 1] = 1
  bytes[7 * 80 + 20 + 1] = 2
  bytes[7 * 80 + 21 + 1] = 4
  bytes[7 * 80 + 22 + 1] = 9
  local parts = {}
  for index = 1, 6400 do
    parts[index] = string.char(bytes[index])
  end
  return table.concat(parts)
end

-- Points (19..22, 7) sit in tile (2, 0) of the leading 8x8 rectangle:
-- tile byte 29 carries x=18/19 and byte 30 carries x=20/21, so packed
-- bytes 94 and 95 hold the four spot outcomes.
function T.spinda_spots_follow_personality_bytes_once_only()
  local scene = sceneWithPair()
  local activation = { combatant = 1, activation = 1 }
  scene:setPictureSource(activation, spindaSource(pidZeroPlane()))
  local snapshot = assert(scene:materializeCopyChar(activation, 0), "pid zero personalizes")
  local buffer = snapshot.charBuffer
  Assert.equal(#buffer, 3200, "personalization keeps the packed size")
  Assert.equal(string.byte(buffer, 94), 0x60, "spot index 1 becomes 6 at its packed nibble")
  Assert.equal(string.byte(buffer, 95), 0x47, "spot index 2 becomes 7 while 4 stays")
end

-- Personality 0xFFFFFFFF shifts every spot by (+7, +7): spot set 0 row
-- {15,27,30} lands on (34..37, 22), tile (4, 2), packed bytes 666/667.
function T.spinda_extreme_personality_shifts_spots_by_seven()
  local scene = sceneWithPair()
  local activation = { combatant = 1, activation = 1 }
  local bytes = {}
  for _ = 1, 6400 do
    bytes[#bytes + 1] = 0
  end
  bytes[22 * 80 + 34 + 1] = 1
  bytes[22 * 80 + 35 + 1] = 2
  bytes[22 * 80 + 36 + 1] = 3
  bytes[22 * 80 + 37 + 1] = 4
  local parts = {}
  for index = 1, 6400 do
    parts[index] = string.char(bytes[index])
  end
  scene:setPictureSource(activation, spindaSource(table.concat(parts)))
  local snapshot = assert(scene:materializeCopyChar(activation, 0xFFFFFFFF), "extreme pid personalizes")
  local buffer = snapshot.charBuffer
  Assert.equal(string.byte(buffer, 666), 0x76, "shifted spots 1 and 2 become 6 and 7")
  Assert.equal(string.byte(buffer, 667), 0x48, "shifted spot 3 becomes 8 while 4 stays")
end

function T.tile_packing_follows_the_six_native_rectangles()
  local scene = sceneWithPair()
  local activation = { combatant = 1, activation = 1 }
  -- One distinct index per rectangle origin tile: the packed order
  -- reveals the rectangle sequence.
  local cells = {}
  for _ = 1, 6400 do
    cells[#cells + 1] = 0
  end
  local function mark(x, y, value)
    cells[y * 80 + x + 1] = value
  end
  mark(0, 0, 1)
  mark(64, 0, 2)
  mark(64, 32, 3)
  mark(0, 64, 4)
  mark(32, 64, 5)
  mark(64, 64, 6)
  local parts = {}
  for index = 1, 6400 do
    parts[index] = string.char(cells[index])
  end
  scene:setPictureSource(activation, sourceWith(table.concat(parts), flatPlane(0)))
  local snapshot = assert(scene:materializeCopyChar(activation), "the tile origins pack")
  local buffer = snapshot.charBuffer
  local function tileLead(rectangleBytes)
    return string.byte(buffer, rectangleBytes + 1) or 0
  end
  -- Rectangle byte sizes: 8x8 tiles (2048), two 2x4 strips (256 each),
  -- two 4x2 strips (256 each) and the 2x2 tail (128).
  Assert.equal(tileLead(0), 1, "the full 8x8 rect leads")
  Assert.equal(tileLead(2048), 2, "the top-right strip follows")
  Assert.equal(tileLead(2048 + 256), 3, "the middle-right strip follows")
  Assert.equal(tileLead(2048 + 512), 4, "the bottom-left strip follows")
  Assert.equal(tileLead(2048 + 768), 5, "the bottom-middle strip follows")
  Assert.equal(tileLead(2048 + 1024), 6, "the bottom-right tail closes")
end

return { tests = T }
