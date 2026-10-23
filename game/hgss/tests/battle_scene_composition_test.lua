-- Paired battlefield composition through the production renderer: the
-- native plane order on the detail pane, strip-normalized quad sampling
-- for cell objects and bar tiles, entry-travel displacement from the
-- scene enrichment, and the declared compact bar adaptation beside the
-- full-size paired tiles. All fixtures are synthetic with recording
-- doubles; the real battle renderer carries the drawing.

local Assert = require("tests.support.Assert")
local BattleRenderer = require("game.hgss.src.battle.BattleRenderer")
local FakeGraphics = require("tests.support.FakeGraphics")
local ManifestFixture = require("tests.support.BattlePresentationManifestFixture")
local BattleScene = require("libs.hgss.src.presentation.BattleScene")

local T = {}

local function stagedDrawable(key)
  local hud = key:match("^hud:") ~= nil
  local image = { handle = key, width = hud and 1648 or 80, height = hud and 8 or 80 }
  function image:getWidth()
    return self.width
  end
  function image:getHeight()
    return self.height
  end
  function image:getDimensions()
    return self.width, self.height
  end
  function image:setFilter() end
  return image
end

---@param overrides table? battler fields replacing the healthy defaults
---@return table displayed battler facts for renderer draws
local function battler(overrides)
  local record = {
    combatant = 1,
    side = 1,
    hp = 30,
    maxHp = 30,
    visible = true,
    active = true,
    name = "LEAD",
    level = 9,
    portraitSelector = "LEAD/0/male/plain/back",
    shakeDx = 0,
    shadowSize = 1,
  }
  if overrides ~= nil then
    for key, value in pairs(overrides) do
      record[key] = value
    end
  end
  return record
end

---@param overrides table? snapshot fields replacing the healthy defaults
---@return table internal semantic snapshot for renderer draws
local function snapshot(overrides)
  local manifest = ManifestFixture.manifest()
  local function sourceCell(section, y)
    section.cells = {
      {
        objs = {
          { x = -64, y = y, tile = 0, width = 64, height = 64, palette = 0, priority = 0, affine = false, flipH = false, flipV = false, disabled = false, objMode = "normal", mosaic = false, colorMode = "16-color" },
          { x = 0, y = y, tile = 64, width = 64, height = 64, palette = 0, priority = 0, affine = false, flipH = false, flipV = false, disabled = false, objMode = "normal", mosaic = false, colorMode = "16-color" },
        },
      },
    }
    section.animation = { playMode = "forward_loop", loopStartFrameIdx = 0, frames = { { cell = 0, duration = 0 } } }
    return section
  end
  local doubles = {
    playerLeft = sourceCell(manifest.hud.doubles.playerLeft, -32),
    playerRight = sourceCell(manifest.hud.doubles.playerRight, -32),
    enemyLeft = sourceCell(manifest.hud.doubles.enemyLeft, -28),
    enemyRight = sourceCell(manifest.hud.doubles.enemyRight, -28),
  }
  local view = {
    slotGeometry = manifest.battlefield.slots,
    hudSections = {
      player = sourceCell(manifest.hud.player, -32),
      enemy = sourceCell(manifest.hud.enemy, -28),
      doubles = doubles,
    },
    hudPatchSpans = manifest.hud.patchSpans,
    mode = "command",
    selection = "fight",
    armed = nil,
    requestId = 7,
    message = "",
    battlers = {
      battler({ combatant = 1, side = 1 }),
      battler({
        combatant = 2,
        side = 2,
        name = "FOE",
        level = 5,
        hp = 12,
        maxHp = 12,
        portraitSelector = "FOE/0/male/plain/front",
      }),
    },
    commands = {},
    moves = {},
    partyRoster = {},
    foeCount = 1,
    arrowFrame = 0,
    effectInstances = {},
    childIntent = nil,
  }
  if overrides ~= nil then
    for key, value in pairs(overrides) do
      view[key] = value
    end
  end
  return view
end

---@return table recording text boundary behind one draw
local function recordingText()
  local text = { draws = {} }
  function text.measure(content)
    return { width = 8 * #tostring(content), height = 16 }
  end
  function text.drawText(content, x, y)
    text.draws[#text.draws + 1] = { content = tostring(content), x = x, y = y, palette = nil }
  end
  function text.drawTextWithPalette(content, x, y, palette)
    text.draws[#text.draws + 1] = { content = tostring(content), x = x, y = y, palette = palette }
  end
  return text
end

---@param graphics table fake drawing API
---@param opts table? record of the submitted picture instances
---@return fun(self: table, drawGraphics: table, pictures: table[]): table picture-layer handle
local function pictureRenderer(graphics, opts)
  return function(_, drawGraphics, pictures)
    graphics.pictureItems = pictures
    if opts ~= nil then
      opts.pictureItems = pictures
    end
    for _, picture in ipairs(pictures) do
      local x, y
      if picture.kind == "shadow" then
        x = picture.centerX - picture.width / 2 + (picture.shadowOffsetX or 0)
        y = picture.centerY - picture.height / 2 + (picture.shadowOffsetY or 0)
      elseif picture.pictureVisible then
        x = picture.centerX - 40 + (picture.xOffset or 0) + (picture.xOffset2 or 0)
        y = picture.centerY - 40 + (picture.yOffset or 0) + (picture.yOffset2 or 0) - (picture.shadowHeight or 0)
      else
        x = picture.centerX - picture.width / 2 + (picture.xOffset or 0)
        y = picture.centerY - picture.height / 2 + (picture.yOffset or 0) - (picture.shadowHeight or 0)
      end
      drawGraphics.draw(picture.image, nil, x, y)
    end
    return { handle = "picture-depth-layer" }
  end
end

---@param view table internal semantic snapshot under drawing
---@param opts table? test image records
---@return table graphics behind one detail draw
local function drawnDetail(view, opts)
  opts = opts or {}
  local graphics = FakeGraphics.new({})
  local text = recordingText()
  opts.text = text
  local resources = {
    graphics = graphics,
    text = text,
    windows = { drawWindow = function() end, drawApplicationFrame = function() end },
    doublesHud = opts.doublesHud or view.hudSections.doubles,
    assets = {
      drawable = function(_, key)
        if key == "scene:test" and opts.backgroundRaster ~= nil then
          opts.sceneFallbackRequested = true
        end
        if key == "mon:LEAD/0/male/plain/back" and opts.pictureFrames ~= nil then
          return { frames = opts.pictureFrames }
        end
        return stagedDrawable(key)
      end,
      background = function(_, raster)
        opts.backgroundRasterUsed = raster
        return { handle = "composed-bg3" }
      end,
      shadowRegion = function(_, size)
        return { size = size, x = 0, y = size * 16, width = 64, height = 16 }
      end,
      release = function(_, _)
      end,
    },
    frameKey = "composition-frame",
    sceneImageKey = "scene:test",
  }
  resources.assets.renderPictures = pictureRenderer(graphics, opts)
  BattleRenderer.drawPane(resources, view, "detail", {})
  return graphics
end

function T.single_player_hp_numbers_follow_the_native_character_tile_spans()
  local view = snapshot()
  view.battlers[1].hp, view.battlers[1].maxHp = 16, 64
  local opts = {}
  local graphics = drawnDetail(view, opts)
  local numericDraws = {}
  for _, draw in ipairs(opts.text.draws) do
    if draw.content == "16" or draw.content == "64" then
      numericDraws[draw.content] = { x = draw.x, y = draw.y }
    end
  end
  Assert.deepEqual(numericDraws, {
    ["16"] = { x = 200, y = 124 },
    ["64"] = { x = 224, y = 124 },
  }, "current HP right-aligns and maximum HP left-aligns in their source tile spans")
  local numberClips = {}
  for _, clip in ipairs(graphics.scissorIntersections) do
    if clip.requested[3] == 24 and clip.requested[4] == 8 then
      numberClips[#numberClips + 1] = { x = clip.requested[1], y = clip.requested[2] }
    end
  end
  Assert.deepEqual(numberClips, { { x = 192, y = 124 }, { x = 224, y = 124 } }, "each numeral stays inside its native span")
end

function T.source_gauge_task_tile_patches_override_the_static_hud_checkpoint()
  local view = snapshot({
    gaugePatchTiles = {
      [0] = {
        health = {
          { tile = 97, sourceTile = 2, fill = 8 },
          { tile = 98, sourceTile = 2, fill = 8 },
          { tile = 99, sourceTile = 2, fill = 8 },
          { tile = 100, sourceTile = 2, fill = 8 },
          { tile = 101, sourceTile = 2, fill = 8 },
          { tile = 102, sourceTile = 2, fill = 8 },
        },
      },
    },
  })
  local graphics = drawnDetail(view)
  local sourceTiles = {}
  for _, draw in ipairs(graphics.draws) do
    if type(draw.image) == "table" and draw.image.handle == "hud:player" and draw.quad ~= nil then
      if draw.quad.w == 8 and draw.quad.h == 8 and draw.quad.x < 128 * 8 then
        sourceTiles[#sourceTiles + 1] = draw.quad.x / 8
      end
    end
  end
  Assert.deepEqual(sourceTiles, { 2, 2, 2, 2, 2, 2 }, "active health-task characters replace static HP tiles in the production HUD")
end

function T.source_experience_task_tile_patches_override_the_level_snapshot()
  local view = snapshot({
    gaugePatchTiles = {
      [0] = {
        experience = {
          { tile = 51, sourceTile = 2, fill = 8 },
          { tile = 52, sourceTile = 2, fill = 8 },
          { tile = 53, sourceTile = 2, fill = 8 },
          { tile = 54, sourceTile = 2, fill = 8 },
          { tile = 55, sourceTile = 2, fill = 8 },
          { tile = 112, sourceTile = 2, fill = 8 },
          { tile = 113, sourceTile = 2, fill = 8 },
          { tile = 114, sourceTile = 2, fill = 8 },
          { tile = 115, sourceTile = 2, fill = 8 },
          { tile = 116, sourceTile = 2, fill = 8 },
          { tile = 117, sourceTile = 2, fill = 8 },
          { tile = 118, sourceTile = 2, fill = 8 },
        },
      },
    },
  })
  local graphics = drawnDetail(view)
  local taskTiles = 0
  for _, draw in ipairs(graphics.draws) do
    if type(draw.image) == "table" and draw.image.handle == "hud:player" and draw.quad ~= nil then
      if draw.quad.w == 8 and draw.quad.h == 8 and draw.quad.x == 2 * 8 then
        taskTiles = taskTiles + 1
      end
    end
  end
  Assert.equal(taskTiles, 12, "the active level task draws its source checkpoint across both native spans")
end

function T.doubles_player_hp_numbers_follow_each_native_side_type_span()
  local view = snapshot({
    battlers = {
      battler({ combatant = 1, side = 1, position = 0, hp = 17, maxHp = 64, healthBoxMode = "numbers" }),
      battler({
        combatant = 3,
        side = 1,
        position = 1,
        hp = 23,
        maxHp = 100,
        portraitSelector = "ALLY2/0/male/plain/back",
        healthBoxMode = "numbers",
      }),
      battler({ combatant = 2, side = 2, position = 2, hp = 30, maxHp = 50, portraitSelector = "FOE/0/male/plain/front" }),
      battler({ combatant = 4, side = 2, position = 3, hp = 40, maxHp = 50, portraitSelector = "FOE2/0/male/plain/front" }),
    },
  })
  local opts = {}
  local graphics = drawnDetail(view, opts)
  local numericDraws = {}
  for _, draw in ipairs(opts.text.draws) do
    if draw.content == "17" or draw.content == "64" or draw.content == "23" or draw.content == "100" then
      numericDraws[draw.content] = { x = draw.x, y = draw.y }
    end
  end
  Assert.deepEqual(numericDraws, {
    ["17"] = { x = 200, y = 103 },
    ["64"] = { x = 224, y = 103 },
    ["23"] = { x = 206, y = 132 },
    ["100"] = { x = 230, y = 132 },
  }, "each doubles player uses its side-type tile span and native cell anchor")
  local hiddenEnemyNumbers = {}
  for _, draw in ipairs(opts.text.draws) do
    if draw.content == "30" or draw.content == "50" then
      hiddenEnemyNumbers[draw.content] = true
    end
  end
  Assert.deepEqual(hiddenEnemyNumbers, {}, "enemy doubles omit current and maximum HP numerals")
  local numberClips = {}
  for _, clip in ipairs(graphics.scissorIntersections) do
    if clip.requested[3] == 24 and clip.requested[4] == 8 then
      numberClips[#numberClips + 1] = { x = clip.requested[1], y = clip.requested[2] }
    end
  end
  Assert.deepEqual(
    numberClips,
    { { x = 192, y = 103 }, { x = 224, y = 103 }, { x = 198, y = 132 }, { x = 230, y = 132 } },
    "both doubles player numeral windows clip to their side-type tile spans"
  )
end

-- The retained mutable BG3 layer is the scene actually presented. Its
-- cached raster is uploaded through the asset owner and receives the
-- source scroll, while the static PNG path stays unused.
function T.detail_draws_the_owned_bg3_raster_with_scroll()
  local raster = { marker = "patched-raster" }
  local opts = { backgroundRaster = raster }
  local graphics = drawnDetail(snapshot({ backgroundRaster = raster, bgScroll = { x = 7, y = 3 } }), opts)
  Assert.equal(opts.backgroundRasterUsed, raster, "the scene owner raster reaches the uploader")
  Assert.isTrue(not opts.sceneFallbackRequested, "the static PNG is not requested")
  local scene = 0
  for index, draw in ipairs(graphics.draws) do
    if type(draw.image) == "table" and draw.image.handle == "composed-bg3" then
      scene = index
      break
    end
  end
  Assert.isTrue(scene > 0, "the composed BG3 image draws")
  Assert.equal(graphics.draws[scene].x, -7, "BG3 horizontal scroll reaches its draw origin")
  Assert.equal(graphics.draws[scene].y, -3, "BG3 vertical scroll reaches its draw origin")
end

function T.single_hud_tiles_follow_the_published_cell_object_coordinates()
  local manifest = ManifestFixture.manifest()
  local cellObject = {
    x = 5,
    y = 7,
    tile = 97,
    width = 48,
    height = 8,
    flipH = false,
    flipV = false,
    palette = 0,
    priority = 0,
    affine = false,
    disabled = false,
    mosaic = false,
    objMode = "normal",
    colorMode = "16-color",
  }
  local hud = manifest.hud.player
  hud.cells = {
    {
      objs = {
        cellObject,
        { x = -64, y = -32, tile = 0, width = 64, height = 64, flipH = false, flipV = false, palette = 0, priority = 0, affine = false, disabled = false, mosaic = false, objMode = "normal", colorMode = "16-color" },
        { x = 0, y = -32, tile = 64, width = 64, height = 64, flipH = false, flipV = false, palette = 0, priority = 0, affine = false, disabled = false, mosaic = false, objMode = "normal", colorMode = "16-color" },
      },
    },
  }
  hud.animation = { playMode = "once", loopStartFrameIdx = 0, frames = { { cell = 0, duration = 0 } } }
  local view = snapshot()
  view.hudSections.player = hud
  view.battlers[1].level = 100
  local graphics = drawnDetail(view)
  local patchPosition
  for _, draw in ipairs(graphics.draws) do
    if type(draw.image) == "table" and draw.image.handle == "hud:player" and draw.quad ~= nil then
      if draw.quad.w == 8 and draw.quad.h == 8 and draw.quad.x == 80 then
        patchPosition = patchPosition or { x = draw.x, y = draw.y }
      end
    end
  end
  Assert.deepEqual(
    patchPosition,
    { x = 197, y = 123 },
    "the patched character tile follows its NCER object from the native HUD anchor"
  )
end

function T.doubles_hud_objects_draw_back_to_front_by_native_obj_priority()
  local manifest = ManifestFixture.manifest()
  local section = manifest.hud.doubles.playerLeft
  section.cells[1].objs = {
    { x = 0, y = 0, tile = 2, flipH = false, flipV = false, palette = 0, shape = 0, size = 0, width = 8, height = 8, affine = false, disabled = false, objMode = "normal", mosaic = false, colorMode = "16-color", priority = 0 },
    { x = 0, y = 0, tile = 1, flipH = false, flipV = false, palette = 0, shape = 0, size = 0, width = 8, height = 8, affine = false, disabled = false, objMode = "normal", mosaic = false, colorMode = "16-color", priority = 3 },
    { x = -64, y = -32, tile = 0, width = 64, height = 64, affine = false, disabled = false, flipH = false, flipV = false, palette = 0, priority = 0, shape = 1, size = 3, objMode = "normal", mosaic = false, colorMode = "16-color" },
    { x = 0, y = -32, tile = 64, width = 64, height = 64, affine = false, disabled = false, flipH = false, flipV = false, palette = 0, priority = 0, shape = 1, size = 3, objMode = "normal", mosaic = false, colorMode = "16-color" },
  }
  local view = snapshot({
    battlers = {
      battler({ combatant = 1, side = 1, position = 0 }),
      battler({ combatant = 3, side = 1, position = 1, portraitSelector = "ALLY2/0/male/plain/back" }),
      battler({ combatant = 2, side = 2, position = 2, name = "FOE", portraitSelector = "FOE/0/male/plain/front" }),
      battler({ combatant = 4, side = 2, position = 3, name = "FOE2", portraitSelector = "FOE2/0/male/plain/front" }),
    },
  })
  for _, record in ipairs(view.battlers) do
    record.hp = 0
  end
  view.hudSections.doubles.playerLeft = section
  local graphics = drawnDetail(view, { doublesHud = view.hudSections.doubles })
  local tiles = {}
  for _, draw in ipairs(graphics.draws) do
    if type(draw.image) == "table" and draw.image.handle == "hud:player-left" then
      tiles[#tiles + 1] = draw.quad.x
      if #tiles == 2 then
        break
      end
    end
  end
  Assert.deepEqual(tiles, { 8, 16 }, "lower-priority OBJ paints behind higher-priority OBJ")
end

function T.doubles_hud_cells_follow_published_native_priorities()
  local manifest = ManifestFixture.manifest()
  local slots = manifest.battlefield.slots
  for _, row in ipairs(slots) do
    if row.sideType == 2 then row.hudPriority = 28 end
    if row.sideType == 4 then row.hudPriority = 26 end
    if row.sideType == 3 then row.hudPriority = 25 end
    if row.sideType == 5 then row.hudPriority = 27 end
  end
  local view = snapshot({
    slotGeometry = slots,
    battlers = {
      battler({ combatant = 1, side = 1, position = 0 }),
      battler({ combatant = 3, side = 1, position = 1, portraitSelector = "ALLY2/0/male/plain/back" }),
      battler({ combatant = 2, side = 2, position = 2, name = "FOE", portraitSelector = "FOE/0/male/plain/front" }),
      battler({ combatant = 4, side = 2, position = 3, name = "FOE2", portraitSelector = "FOE2/0/male/plain/front" }),
    },
  })
  for _, record in ipairs(view.battlers) do
    record.hp = 0
  end
  local graphics = drawnDetail(view, { doublesHud = view.hudSections.doubles })
  local order = {}
  for _, draw in ipairs(graphics.draws) do
    local handle = type(draw.image) == "table" and draw.image.handle or nil
    if type(handle) == "string" and handle:match("^hud:.*%-left$") or type(handle) == "string" and handle:match("^hud:.*%-right$") then
      if #order == 0 or order[#order] ~= handle then
        order[#order + 1] = handle
      end
    end
  end
  Assert.deepEqual(order, { "hud:player-left", "hud:enemy-right", "hud:player-right", "hud:enemy-left" })
end

function T.detail_picture_centers_follow_published_slot_geometry()
  local geometry = ManifestFixture.manifest().battlefield.slots
  geometry[1].settledX, geometry[1].settledY = 70, 110
  geometry[2].settledX, geometry[2].settledY = 180, 60
  local graphics = drawnDetail(snapshot({ slotGeometry = geometry }))
  local portraitOrigins = {}
  for _, draw in ipairs(graphics.draws) do
    if type(draw.image) == "table" and type(draw.image.handle) == "string" then
      if draw.image.handle == "mon:LEAD/0/male/plain/back" or draw.image.handle == "mon:FOE/0/male/plain/front" then
        portraitOrigins[draw.image.handle] = { x = draw.x, y = draw.y }
      end
    end
  end
  Assert.deepEqual(portraitOrigins["mon:LEAD/0/male/plain/back"], { x = 30, y = 70 })
  Assert.deepEqual(portraitOrigins["mon:FOE/0/male/plain/front"], { x = 140, y = 20 })
end

function T.doubles_shadow_and_picture_passes_follow_native_pokepic_depth()
  local view = snapshot({
    battlers = {
      battler({ combatant = 1, side = 1, position = 0 }),
      battler({ combatant = 3, side = 1, position = 1, name = "ALLY2", portraitSelector = "ALLY2/0/male/plain/back" }),
      battler({ combatant = 2, side = 2, position = 2, name = "FOE", portraitSelector = "FOE/0/male/plain/front" }),
      battler({ combatant = 4, side = 2, position = 3, name = "FOE2", portraitSelector = "FOE2/0/male/plain/front" }),
    },
  })
  local graphics = drawnDetail(view, { doublesHud = view.hudSections.doubles })
  local pictureOrder = {}
  local shadows = 0
  for _, picture in ipairs(graphics.pictureItems) do
    local handle = type(picture.image) == "table" and picture.image.handle or nil
    if picture.kind == "shadow" then
      shadows = shadows + 1
      Assert.equal(picture.zCenter, BattleScene.SHADOW_DEPTH, "shadow planes carry native fixed Z")
    elseif type(handle) == "string" and handle:match("^mon:") then
      pictureOrder[#pictureOrder + 1] = handle
    end
  end
  Assert.deepEqual(pictureOrder, {
    "mon:FOE2/0/male/plain/front",
    "mon:LEAD/0/male/plain/back",
    "mon:FOE/0/male/plain/front",
    "mon:ALLY2/0/male/plain/back",
  }, "pictures draw back to front by each source slot's Pokepic depth")
  Assert.equal(shadows, 4, "every live source slot submits its own shadow plane")
end

---@param graphics table recording graphics boundary under inspection
---@param handle string artwork identity under search
---@return integer first draw index carrying that identity, 0 when absent
local function firstIndexOf(graphics, handle)
  for index, entry in ipairs(graphics.draws) do
    if type(entry.image) == "table" and entry.image.handle == handle then
      return index
    end
  end
  return 0
end

-- The detail pane layers back to front: the scene, each shadow under
-- its picture, pictures before their health-box cells, and bar tiles
-- after the cells they patch.
function T.detail_layers_order_back_to_front()
  local graphics = drawnDetail(snapshot())
  local scene = firstIndexOf(graphics, "scene:test")
  local shadow = firstIndexOf(graphics, "shadow")
  local foe = firstIndexOf(graphics, "mon:FOE/0/male/plain/front")
  local lead = firstIndexOf(graphics, "mon:LEAD/0/male/plain/back")
  local enemyHud = firstIndexOf(graphics, "hud:enemy")
  local playerHud = firstIndexOf(graphics, "hud:player")
  for _, index in ipairs({ scene, shadow, foe, lead, enemyHud, playerHud }) do
    Assert.isTrue(index > 0, "every native layer draws")
  end
  Assert.isTrue(scene < shadow, "the scene sits behind the shadows")
  Assert.isTrue(shadow < foe and shadow < lead, "shadows sit behind their pictures")
  Assert.isTrue(foe < enemyHud and lead < playerHud, "pictures sit behind their health boxes")
  -- Each health box patches its own cells before its bar tiles: cells
  -- and tiles share one sprite whose character buffer the patch spans
  -- update in place.
  for _, handle in ipairs({ "hud:enemy", "hud:player" }) do
    local lastCell, firstTile = 0, nil
    for index, entry in ipairs(graphics.draws) do
      if type(entry.image) == "table" and entry.image.handle == handle and type(entry.quad) == "table" then
        if entry.quad.w == 8 and entry.quad.h == 8 then
          if firstTile == nil then
            firstTile = index
          end
        else
          lastCell = index
        end
      end
    end
    Assert.notNil(firstTile, "the " .. handle .. " bar tiles draw")
    Assert.isTrue(lastCell < firstTile, "the " .. handle .. " tiles patch after their cells")
  end
end

-- Cell objects sample the strip row-major from their base tile while
-- bar tiles sample the color base plus their fill level.
function T.quads_sample_the_strip_at_normalized_tile_origins()
  local graphics = drawnDetail(snapshot({ battlers = {
    battler({ combatant = 1, side = 1, hp = 13, maxHp = 52 }),
    battler({
      combatant = 2,
      side = 2,
      name = "FOE",
      level = 5,
      hp = 13,
      maxHp = 52,
      portraitSelector = "FOE/0/male/plain/front",
    }),
  } }))
  local cells, tiles = {}, {}
  for _, entry in ipairs(graphics.draws) do
    if
      type(entry.image) == "table"
      and type(entry.image.handle) == "string"
      and entry.image.handle:sub(1, 4) == "hud:"
      and type(entry.quad) == "table"
    then
      if entry.quad.w == 8 and entry.quad.h == 8 and entry.quad.x < 128 * 8 then
        tiles[#tiles + 1] = entry.quad.x
      else
        cells[#cells + 1] = entry.quad.x
      end
    end
  end
  Assert.isTrue(#cells > 0, "cell objects draw")
  for _, x in ipairs(cells) do
    Assert.equal(x % 8, 0, "cell bands start on tile bounds")
  end
  -- Thirteen of fifty-two fills twelve pixels from the yellow base: one
  -- full tile plus a four-pixel tile on each side.
  table.sort(tiles)
  Assert.deepEqual(
    tiles,
    { 120, 120, 152, 152 },
    "bar tiles sample the color base plus their fill level on both sides"
  )
end

-- Scene enrichment travels pictures and shadows together: entry
-- displacement shifts both by the same offset while settled records
-- draw at their nominal origins.
function T.entry_travel_shifts_pictures_with_their_shadows()
  local settled = drawnDetail(snapshot())
  local traveling = drawnDetail(snapshot({
    battlers = {
      battler({ combatant = 1, side = 1, entryDx = -276, entryDy = 0 }),
      battler({
        combatant = 2,
        side = 2,
        name = "FOE",
        level = 5,
        hp = 12,
        maxHp = 12,
        portraitSelector = "FOE/0/male/plain/front",
      }),
    },
  }))
  local function positions(graphics, handle)
    local found = {}
    for _, entry in ipairs(graphics.draws) do
      if type(entry.image) == "table" and entry.image.handle == handle then
        found[#found + 1] = { x = entry.x, y = entry.y }
      end
    end
    return found
  end
  local settledLead = positions(settled, "mon:LEAD/0/male/plain/back")
  local travelingLead = positions(traveling, "mon:LEAD/0/male/plain/back")
  Assert.equal(#settledLead, 1, "the settled lead draws once")
  Assert.equal(#travelingLead, 1, "the traveling lead draws once")
  Assert.equal(
    travelingLead[1].x,
    settledLead[1].x - 276,
    "entry travel shifts the picture by its displacement"
  )
  Assert.equal(travelingLead[1].y, settledLead[1].y, "entry travel keeps the settled row")
  local settledShadow = positions(settled, "shadow")
  local travelingShadow = positions(traveling, "shadow")
  Assert.equal(#settledShadow, 2, "both shadows draw while settled")
  Assert.equal(#travelingShadow, 2, "both shadows draw while traveling")
  local shifted = 0
  for _, shadow in ipairs(travelingShadow) do
    for _, parked in ipairs(settledShadow) do
      if shadow.x == parked.x - 276 and shadow.y == parked.y then
        shifted = shifted + 1
      end
    end
  end
  Assert.equal(shifted, 1, "exactly the traveling shadow follows its picture")
end

function T.source_picture_height_shifts_the_nominal_origin()
  local graphics = drawnDetail(snapshot({ battlers = {
    battler({ combatant = 1, side = 1, sourceHeight = 17 }),
    battler({
      combatant = 2,
      side = 2,
      name = "FOE",
      level = 5,
      hp = 12,
      maxHp = 12,
      portraitSelector = "FOE/0/male/plain/front",
    }),
  } }))
  for _, entry in ipairs(graphics.draws) do
    if type(entry.image) == "table" and entry.image.handle == "mon:LEAD/0/male/plain/back" then
      Assert.equal(entry.y, 112 - 40 - 17, "the source picture height displaces its center-based origin")
      return
    end
  end
  error("the source-height battler draws", 0)
end

function T.authored_picture_offset_moves_the_picture_and_its_shadow()
  local graphics = drawnDetail(snapshot({ battlers = {
    battler({ combatant = 1, side = 1, pictureXOffset = -5 }),
    battler({
      combatant = 2,
      side = 2,
      name = "FOE",
      level = 5,
      hp = 12,
      maxHp = 12,
      portraitSelector = "FOE/0/male/plain/front",
    }),
  } }))
  local pictureX, shadowX
  for _, entry in ipairs(graphics.draws) do
    if type(entry.image) == "table" and entry.image.handle == "mon:LEAD/0/male/plain/back" then
      pictureX = entry.x
    elseif type(entry.image) == "table" and entry.image.handle == "shadow" then
      shadowX = entry.x
    end
  end
  Assert.equal(pictureX, 64 - 40 - 5, "Pokepic xOffset displaces the portrait")
  Assert.equal(shadowX, 64 - 32 - 5, "Pokepic xOffset displaces the shadow with its picture")
end

function T.authored_picture_frame_selects_its_matching_portrait_pixels()
  local graphics = drawnDetail(snapshot({ battlers = {
    battler({ combatant = 1, side = 1, pictureFrame = 1 }),
    battler({
      combatant = 2,
      side = 2,
      name = "FOE",
      level = 5,
      hp = 12,
      maxHp = 12,
      portraitSelector = "FOE/0/male/plain/front",
    }),
  } }), { pictureFrames = { stagedDrawable("lead-frame-0"), stagedDrawable("lead-frame-1") } })
  local selectedFrame
  for _, picture in ipairs(graphics.pictureItems) do
    if picture.kind ~= "shadow" and picture.image.handle == "lead-frame-1" then
      selectedFrame = picture.image
      break
    end
  end
  Assert.notNil(selectedFrame, "frame index one reaches the second staged portrait crop")
end

-- Compact singles sample the same tile selection as the paired view but
-- declare their adaptation: tiles shrink vertically into the compact bar
-- row instead of patching full tile rows.
function T.compact_bars_declare_their_vertical_adaptation()
  local ApplicationPresentation = require("libs.ui.src.ApplicationPresentation")
  local BattleScreenInterface = require("game.hgss.src.battle.BattleScreenInterface")
  local ScreenTopology = require("libs.ui.src.ScreenTopology")
  local view = snapshot({
    battlers = {
      battler({ combatant = 1, side = 1, hp = 13, maxHp = 52 }),
      battler({
        combatant = 2,
        side = 2,
        name = "FOE",
        level = 5,
        hp = 13,
        maxHp = 52,
        portraitSelector = "FOE/0/male/plain/front",
      }),
    },
  })
  local measurement = {
    width = 256,
    height = 192,
    topology = ScreenTopology.oneDisplay({
      id = "main",
      rect = { x = 0, y = 0, width = 256, height = 192 },
      touch = true,
      role = "world",
    }),
    pixelRatio = 1,
    signature = "composition-compact-probe",
  }
  local session = ApplicationPresentation.new(BattleScreenInterface.defaults(), nil)
  local plan = session:resolve(measurement, view)
  local graphics = FakeGraphics.new({})
  local text = recordingText()
  local resources = {
    graphics = graphics,
    text = text,
    windows = { drawWindow = function() end, drawApplicationFrame = function() end },
    assets = {
      drawable = function(_, key)
        return stagedDrawable(key)
      end,
      shadowRegion = function(_, size)
        return { size = size, x = 0, y = size * 16, width = 64, height = 16 }
      end,
      renderPictures = pictureRenderer(graphics),
      release = function(_, _)
      end,
    },
    frameKey = "composition-frame",
    sceneImageKey = "scene:test",
  }
  ApplicationPresentation.draw(graphics, resources, view, plan)
  local tiles = {}
  local sourceCellScales = {}
  for _, entry in ipairs(graphics.draws) do
    if
      type(entry.image) == "table"
      and type(entry.image.handle) == "string"
      and entry.image.handle:sub(1, 4) == "hud:"
      and type(entry.quad) == "table"
      and entry.quad.w == 64
      and entry.quad.h == 8
    then
      sourceCellScales[entry.image.handle] = entry.sy
    end
    if
      type(entry.image) == "table"
      and type(entry.image.handle) == "string"
      and entry.image.handle:sub(1, 4) == "hud:"
      and type(entry.quad) == "table"
      and entry.quad.w == 8
      and entry.quad.h == 8
      and entry.quad.x < 128 * 8
    then
      tiles[#tiles + 1] = { x = entry.quad.x, sy = entry.sy, key = entry.image.handle }
    end
  end
  table.sort(tiles, function(a, b)
    return a.x < b.x
  end)
  local sampled = {}
  for _, tile in ipairs(tiles) do
    sampled[#sampled + 1] = tile.x
    local sourceCellScale = assert(sourceCellScales[tile.key], "each dynamic tile belongs to source cell art")
    Assert.equal(tile.sy, sourceCellScale, "each dynamic tile uses its own HUD cell's compact transform")
  end
  table.sort(sampled)
  Assert.deepEqual(sampled, { 120, 120, 152, 152 }, "compact tiles sample the same selection per side")
  local paired = drawnDetail(view)
  local pairedTiles = 0
  for _, entry in ipairs(paired.draws) do
    if
      type(entry.image) == "table"
      and type(entry.image.handle) == "string"
      and entry.image.handle:sub(1, 4) == "hud:"
      and type(entry.quad) == "table"
      and entry.quad.w == 8
      and entry.quad.h == 8
      and entry.quad.x < 128 * 8
    then
      pairedTiles = pairedTiles + 1
      Assert.isTrue(entry.sy == nil or entry.sy == 1, "paired tiles patch full tile rows")
    end
  end
  Assert.equal(pairedTiles, 4, "the paired view draws the same four partial tiles unscaled")
end

return { tests = T }
