-- Native battle scene composition at the production renderer boundary: exact
-- picture centers with signed height displacement and shadows, all six
-- slot geometries with stable health-box anchors, source background
-- scroll fidelity, integer health/experience tile behavior, palette-aware
-- health-box fields, hostile-graphics neutrality with an explicit compact
-- adaptation, and appearance/affine survival across substitute, transform
-- and restore. Expected vectors come from the pinned native sources
-- (pret/pokeheartgold@9d8b7591): battle_hp_bar.c health-box templates,
-- unk_0208805C.c bar color arithmetic, battle_hp_bar_data.h component
-- rows, pokepic.c center-minus-half plus shadow quads, and the overlay-7
-- spawn tables. Draws run through the real battle renderer with recording
-- doubles, never through a reimplementation of it.

local Assert = require("tests.support.Assert")
local ManifestFixture = require("tests.support.BattlePresentationManifestFixture")
local BattleRenderer = require("game.hgss.src.battle.BattleRenderer")
local FakeGraphics = require("tests.support.FakeGraphics")

local T = {}
local function fakeDrawableWidth(image)
  return image.width
end

local function fakeDrawableHeight(image)
  return image.height
end

local function fakeDrawableDimensions(image)
  return image.width, image.height
end

local function fakeDrawableFilter() end

local function stagedDrawable(key)
  local hud = key:match("^hud:") ~= nil
  return {
    handle = key,
    width = hud and 1648 or 256,
    height = hud and 8 or 256,
    getWidth = fakeDrawableWidth,
    getHeight = fakeDrawableHeight,
    getDimensions = fakeDrawableDimensions,
    setFilter = fakeDrawableFilter,
  }
end

-- Settled picture centers in native logical pixels, from the native
-- slot geometry: single player, single opponent, then the four double
-- slots keyed by side type.
local SINGLE_PLAYER = { x = 64, y = 112 }
local SINGLE_FOE = { x = 192, y = 50 }
local DOUBLES_SETTLED = {
  { side = 2, x = 40, y = 112 },
  { side = 4, x = 80, y = 120 },
  { side = 3, x = 216, y = 50 },
  { side = 5, x = 176, y = 42 },
}
local DOUBLES_HUD = {
  { side = 2, x = 192, y = 103 },
  { side = 4, x = 198, y = 132 },
  { side = 3, x = 64, y = 16 },
  { side = 5, x = 58, y = 45 },
}

-- The interim enemy anchor the native composition replaces.
local INTERIM_FOE = { x = 192, y = 56 }

-- Nominal picture edge and its half inset: the final 80x80 image origin
-- is the adjusted center minus this inset (pokepic.c draw path).
local PICTURE_HALF = 40

-- Native shadow quad geometry: 64x16 centered on the battler center
-- (pokepic.c shadow draw).
local SHADOW_WIDTH = 64
local SHADOW_HEIGHT = 16

-- Native bar capacities in pixels, from the health-box task arithmetic
-- (battle_hp_bar.c tilesWide 6 for health, 12 for experience, eight
-- pixels per tile): 48 health pixels and 96 experience pixels. Bar
-- fill extents below follow hp * 48 / maxHp with the minimum-visible
-- nonzero rule, and exp * 96 / maxExp with level-boundary resets.

-- Interim bar tints the native tile composition replaces.
local INTERIM_TINTS = {
  { 0.2, 0.8, 0.2, 1 },
  { 0.9, 0.8, 0.2, 1 },
  { 0.9, 0.2, 0.2, 1 },
}

---@param color table recorded color under inspection
---@return boolean true while the color is one of the interim bar tints
local function isInterimTint(color)
  if type(color) ~= "table" then
    return false
  end
  for _, tint in ipairs(INTERIM_TINTS) do
    local matches = true
    for channel = 1, 4 do
      if color[channel] ~= tint[channel] then
        matches = false
        break
      end
    end
    if matches then
      return true
    end
  end
  return false
end

---@param height number|nil signed height displacement under test driving
---@return number effective displacement, baseline when absent
local function displacementOf(height)
  if type(height) == "number" then
    return height
  end
  return 0
end

---@param center table<string, number> native settled center under test driving
---@param height number|nil signed height displacement under test driving
---@return number expected nominal image left edge
---@return number expected nominal image top edge
local function nominalOrigin(center, height)
  return center.x - PICTURE_HALF, center.y - PICTURE_HALF + displacementOf(height)
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
    exp = nil,
    condition = nil,
    portraitSelector = "LEAD/0/male/plain/back",
    shakeDx = 0,
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
  local view = {
    mode = "command",
    battleKind = "wild",
    selection = "fight",
    armed = nil,
    requestId = 7,
    message = "",
    messageId = nil,
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
    commands = {
      { id = "fight", enabled = true },
      { id = "bag", enabled = true },
      { id = "pokemon", enabled = true },
      { id = "run", enabled = true },
    },
    moves = {},
    partyRoster = {
      { slot = 0, hp = 30, maxHp = 30 },
    },
    foeCount = 1,
    arrowFrame = 0,
    effectInstances = {},
    slotGeometry = ManifestFixture.manifest().battlefield.slots,
    hudPatchSpans = ManifestFixture.manifest().hud.patchSpans,
    textPalettes = {
      narration = ManifestFixture.manifest().messages.roles.narration.palette,
      hud = ManifestFixture.manifest().messages.roles.hud.palette,
      menu = ManifestFixture.manifest().messages.roles.menu.palette,
    },
    menuText = { pp = "PP", cancel = "CANCEL" },
    hudSections = {
      player = ManifestFixture.manifest().hud.player,
      enemy = ManifestFixture.manifest().hud.enemy,
      doubles = ManifestFixture.manifest().hud.doubles,
    },
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
  function text.drawTextForRole(role, content, x, y, palette)
    text.draws[#text.draws + 1] = { role = role, content = tostring(content), x = x, y = y, palette = palette }
  end
  function text.measureForRole(_, content)
    return { width = 8 * #tostring(content), height = 16 }
  end
  return text
end

---@return table recording window boundary behind one draw
local function recordingWindows()
  local windows = { boxes = {}, background = { 0, 0, 0, 1 } }
  function windows.drawWindow(box, frameKey, background)
    windows.boxes[#windows.boxes + 1] = { box = box, frame = frameKey, background = background }
  end
  function windows.drawApplicationFrame(box, frameIndex)
    windows.boxes[#windows.boxes + 1] = { box = box, frame = frameIndex }
  end
  return windows
end

---@return table staged sprite section with one valid 64x64 source cell
local function stubSection()
  return {
    animation = { frames = { { cell = 0 } } },
    cells = {
      {
        objs = {
          {
            tile = 0,
            width = 64,
            height = 64,
            x = 0,
            y = 0,
            affine = false,
            flipH = false,
            flipV = false,
            palette = 0,
            mosaic = false,
            objMode = "normal",
            colorMode = "16-color",
            disabled = false,
          },
        },
      },
    },
  }
end

---@return table staged role sections behind doubled draws
local function stubDoublesHud()
  return ManifestFixture.manifest().hud.doubles
end

---@param view table internal semantic snapshot under drawing
---@param opts table? graphics color, held keys, compact content
---@return table graphics, text, windows and requests behind one detail draw
local function drawnDetail(view, opts)
  opts = opts or {}
  local graphics = FakeGraphics.new({ color = opts.color })
  if type(opts.observeDraw) == "function" then
    local draw = graphics.draw
    graphics.draw = function(...)
      opts.observeDraw(...)
      return draw(...)
    end
  end
  local text = recordingText()
  local windows = recordingWindows()
  local requests = {}
  local missing = {}
  for _, key in ipairs(opts.held or {}) do
    missing[key] = true
  end
  local resources = {
    graphics = graphics,
    text = text,
    windows = windows,
    assets = {
      drawable = function(_, key)
        requests[#requests + 1] = key
        if missing[key] then
          return nil
        end
        return stagedDrawable(key)
      end,
      shadowRegion = function(_, size)
        return ManifestFixture.manifest().pictures.shadow.regions[size + 1]
      end,
      renderPictures = function(_, drawGraphics, pictures)
        for _, picture in ipairs(pictures) do
          if type(opts.observePicture) == "function" then
            opts.observePicture(picture)
          end
          local width = assert(picture.width, "the picture pass receives normalized width")
          local height = assert(picture.height, "the picture pass receives normalized height")
          drawGraphics.draw(
            picture.image,
            picture.centerX + (picture.xOffset or 0) + (picture.xOffset2 or 0) - width / 2,
            picture.centerY
              - (picture.shadowHeight or 0)
              + (picture.yOffset or 0)
              + (picture.yOffset2 or 0)
              - height / 2,
            picture.rotation or 0,
            width / 80,
            height / 80
          )
        end
        return { handle = "picture-composite" }
      end,
      release = function(_, _) end,
    },
    doublesHud = stubDoublesHud(),
    frameKey = "scene-test-frame",
    sceneImageKey = opts.sceneImageKey or "scene:test",
  }
  BattleRenderer.drawPane(resources, view, "detail", {})
  return { graphics = graphics, text = text, windows = windows, requests = requests }
end

function T.pokepic_transform_uses_the_source_center_plus_pivot()
  local calls = {}
  local drawn = drawnDetail(
    snapshot({
      battlers = {
        battler({
          combatant = 1,
          side = 1,
          rotation = 0.25,
          scaleX = 1.5,
          scaleY = 0.75,
          pivotX = 7,
          pivotY = -3,
        }),
        battler({ combatant = 2, side = 2, portraitSelector = "FOE/0/male/plain/front" }),
      },
    }),
    {
      observePicture = function(picture)
        if type(picture.image) == "table" and picture.image.handle == "mon:LEAD/0/male/plain/back" then
          calls[#calls + 1] = picture
        end
      end,
    }
  )
  Assert.isTrue(#drawn.graphics.draws > 0, "the native scene still draws its picture planes")
  Assert.deepEqual(
    {
      calls[1].centerX,
      calls[1].centerY,
      calls[1].rotation,
      calls[1].width,
      calls[1].height,
      calls[1].pivotX,
      calls[1].pivotY,
    },
    { 64, 112, 0.25, 120, 60, 7, -3 },
    "the picture pass receives source center, affine size and pivot for the native transform"
  )
end

function T.pokepic_affine_dimensions_use_native_eight_bit_fractional_scale()
  local calls = {}
  drawnDetail(
    snapshot({
      battlers = {
        battler({
          combatant = 1,
          side = 1,
          affineMode = true,
          affineWidth = 0x180,
          affineHeight = 0x80,
        }),
        battler({ combatant = 2, side = 2, portraitSelector = "FOE/0/male/plain/front" }),
      },
    }),
    {
      observePicture = function(picture)
        if type(picture.image) == "table" and picture.image.handle == "mon:LEAD/0/male/plain/back" then
          calls[#calls + 1] = picture
        end
      end,
    }
  )
  Assert.deepEqual(
    { calls[1].centerX, calls[1].centerY, calls[1].width, calls[1].height },
    { 64, 112, 120, 40 },
    "Pokepic affine dimensions are 8.8 scales around the picture center"
  )
end

function T.pokepic_polygon_alpha_uses_the_native_five_bit_range()
  local pictureAlpha = nil
  local drawn = drawnDetail(
    snapshot({
      battlers = {
        battler({ combatant = 1, side = 1, polygonAlpha = 16 }),
        battler({ combatant = 2, side = 2, portraitSelector = "FOE/0/male/plain/front" }),
      },
    }),
    {
      observePicture = function(picture)
        if type(picture.image) == "table" and picture.image.handle == "mon:LEAD/0/male/plain/back" then
          pictureAlpha = picture.alpha
        end
      end,
    }
  )
  Assert.isTrue(#drawn.graphics.draws > 0, "the alpha-modulated source picture remains present")
  Assert.equal(pictureAlpha, 16 / 31, "Pokepic polygon alpha maps from five bits to host alpha")
end

function T.pokepic_vanished_picture_keeps_its_hud_but_draws_no_picture_or_shadow()
  local drawn = drawnDetail(snapshot({
    battlers = {
      battler({
        combatant = 1,
        side = 1,
        name = "LEAD",
        portraitSelector = "LEAD/0/male/plain/back",
        vanished = true,
      }),
      battler({ combatant = 2, side = 2, portraitSelector = "FOE/0/male/plain/front", shadowSize = 1 }),
    },
  }))
  local leadPictures, shadows = 0, 0
  for _, entry in ipairs(drawn.graphics.draws) do
    if type(entry.image) == "table" then
      if entry.image.handle == "mon:LEAD/0/male/plain/back" then
        leadPictures = leadPictures + 1
      elseif entry.image.handle == "shadow" then
        shadows = shadows + 1
      end
    end
  end
  Assert.equal(leadPictures, 0, "vanished source picture does not draw")
  Assert.equal(shadows, 1, "vanished source picture has no shadow quad")
  Assert.equal(drawn.text.draws[1].content, "LEAD", "picture visibility does not hide the health-box name")
end

---@param draws table[] recorded draws under inspection
---@param handle string artwork identity under inspection
---@return table[] draws carrying that artwork identity
local function drawsOf(draws, handle)
  local found = {}
  for _, entry in ipairs(draws) do
    if type(entry.image) == "table" and entry.image.handle == handle then
      found[#found + 1] = entry
    end
  end
  return found
end

---@param draws table[] recorded draws under inspection
---@param rect table host rectangle under census
---@return integer draws with a quad inside the rectangle
local function quadDrawsIn(draws, rect)
  local count = 0
  for _, entry in ipairs(draws) do
    if entry.quad ~= nil then
      local x = entry.x --[[@as number]]
      local y = entry.y --[[@as number]]
      if x >= rect.x and x < rect.x + rect.width and y >= rect.y and y < rect.y + rect.height then
        count = count + 1
      end
    end
  end
  return count
end

---@param draws table[] recorded draws under inspection
---@param rect table host rectangle under census
---@return integer draws of any kind inside the rectangle
local function drawsIn(draws, rect)
  local count = 0
  for _, entry in ipairs(draws) do
    local x = entry.x --[[@as number]]
    local y = entry.y --[[@as number]]
    if
      type(x) == "number"
      and type(y) == "number"
      and x >= rect.x
      and x < rect.x + rect.width
      and y >= rect.y
      and y < rect.y + rect.height
    then
      count = count + 1
    end
  end
  return count
end

---@param quad table recorded quad under inspection
---@return integer strip tile index behind the quad
local function quadTile(quad)
  return math.floor(quad.x --[[@as number]] / 8)
end

---@param draws table[] recorded draws under inspection
---@return integer[] sorted strip tile indices behind every quad draw
local function sampledTiles(draws)
  local tiles = {}
  for _, entry in ipairs(draws) do
    if entry.quad ~= nil then
      tiles[#tiles + 1] = quadTile(entry.quad)
    end
  end
  table.sort(tiles)
  return tiles
end

-- Printer digits sampled from one health-box strip, as a sorted string:
-- level digits draw twice (their upper and lower halves).
---@param draws table[] recorded draws under inspection
---@param handle string health-box strip identity
---@return string sorted printed digits
local function printedDigits(draws, handle)
  local digitBase = ManifestFixture.manifest().hud.player.digitBase
  local digits = {}
  for _, entry in ipairs(draws) do
    if type(entry.image) == "table" and entry.image.handle == handle and entry.quad ~= nil then
      local digit = quadTile(entry.quad) - digitBase
      if digit >= 0 and digit <= 9 then
        digits[#digits + 1] = tostring(digit)
      end
    end
  end
  table.sort(digits)
  return table.concat(digits)
end

---@param ... string printed strings, each with its draw count
---@return string sorted digits the strings print
local function expectedDigits(...)
  local digits = {}
  for _, content in ipairs({ ... }) do
    for digit in content:gmatch("%d") do
      digits[#digits + 1] = digit
    end
  end
  table.sort(digits)
  return table.concat(digits)
end

---@param text table recording text boundary under inspection
---@param content string wording under search
---@return table[] draws carrying that exact wording
local function textsOf(text, content)
  local found = {}
  for _, entry in ipairs(text.draws) do
    if entry.content == content then
      found[#found + 1] = entry
    end
  end
  return found
end

---@param text table recording text boundary under inspection
---@param rect table host rectangle under census
---@return table[] wording draws inside the rectangle
local function textsIn(text, rect)
  local found = {}
  for _, entry in ipairs(text.draws) do
    if entry.x >= rect.x and entry.x < rect.x + rect.width and entry.y >= rect.y and entry.y < rect.y + rect.height then
      found[#found + 1] = entry
    end
  end
  return found
end

-- Single battler pictures anchor at the native centers with the nominal
-- half inset and signed height displacement, in every gender, form and
-- finish, each with its source shadow; the foe never sits at the interim
-- anchor and no center doubles as an image origin.
function T.single_portraits_use_native_centers_height_and_shadow()
  local drawn = drawnDetail(snapshot({
    battlers = {
      battler({ combatant = 1, side = 1, shadowSize = 1 }),
      battler({ combatant = 2, side = 2, portraitSelector = "FOE/0/male/plain/front", shadowSize = 1 }),
    },
  }))
  local foeHandle = "mon:FOE/0/male/plain/front"
  local leadHandle = "mon:LEAD/0/male/plain/back"
  local foe = drawsOf(drawn.graphics.draws, foeHandle)
  Assert.isTrue(#foe >= 1, "the foe portrait draws")
  local foeX, foeY = nominalOrigin(SINGLE_FOE, 0)
  Assert.equal(foe[1].x, foeX, "the foe portrait left edge sits one half inset left of its center")
  Assert.equal(foe[1].y, foeY, "the foe portrait top edge sits one half inset above its Y=50 baseline")
  Assert.isTrue(
    foe[1].x ~= INTERIM_FOE.x or foe[1].y ~= INTERIM_FOE.y,
    "the foe portrait never uses the interim anchor as its origin"
  )
  local lead = drawsOf(drawn.graphics.draws, leadHandle)
  Assert.isTrue(#lead >= 1, "the player portrait draws")
  local leadX, leadY = nominalOrigin(SINGLE_PLAYER, 0)
  Assert.equal(lead[1].x, leadX, "the player portrait left edge sits one half inset left of its center")
  Assert.equal(lead[1].y, leadY, "the player portrait top edge sits one half inset above its baseline")

  local tall = drawnDetail(snapshot({
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
        height = 12,
      }),
    },
  }))
  local tallFoe = drawsOf(tall.graphics.draws, foeHandle)
  Assert.isTrue(#tallFoe >= 1, "the displaced foe portrait draws")
  local _, tallY = nominalOrigin(SINGLE_FOE, 12)
  Assert.equal(tallFoe[1].y, tallY, "a nonzero height displaces the foe portrait upward by its displacement")
  Assert.equal(tallFoe[1].x, foeX, "height displacement never moves the portrait horizontally")

  for _, variant in ipairs({
    { selector = "LEAD/0/female/plain/back", side = 1, label = "the player gender variant" },
    { selector = "FOE/1/male/plain/front", side = 2, label = "the foe form variant" },
    { selector = "FOE/0/male/shiny/front", side = 2, label = "the foe shiny variant" },
  }) do
    local center = variant.side == 1 and SINGLE_PLAYER or SINGLE_FOE
    local view = snapshot({
      battlers = {
        battler({ combatant = 1, side = 1, portraitSelector = "LEAD/0/male/plain/back" }),
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
    })
    view.battlers[variant.side].portraitSelector = variant.selector
    local alternative = drawnDetail(view)
    local handle = "mon:" .. variant.selector
    local pictures = drawsOf(alternative.graphics.draws, handle)
    Assert.isTrue(#pictures >= 1, variant.label .. " draws through its own appearance selector")
    local originX, originY = nominalOrigin(center, 0)
    Assert.equal(pictures[1].x, originX, variant.label .. " keeps the native left edge")
    Assert.equal(pictures[1].y, originY, variant.label .. " keeps the native top edge")
  end

  -- The foe footprint stops above the player health-box rows so only
  -- the foe picture and its shadow can land inside it.
  local pictureRect = { x = foeX, y = foeY, width = 80, height = 74 }
  Assert.isTrue(
    drawsIn(drawn.graphics.draws, pictureRect) >= 2,
    "the foe footprint carries both its picture and its shadow"
  )
  local leadRect = { x = leadX, y = leadY, width = 80, height = 80 }
  Assert.isTrue(
    drawsIn(drawn.graphics.draws, leadRect) >= 2,
    "the player footprint carries both its picture and its shadow"
  )
  -- The native shadow is its own 64x16 quad centered on the battler
  -- center, never the picture drawn twice and never a neighboring
  -- health-box row: nothing else draws at this exact origin today.
  local shadowX = SINGLE_FOE.x - SHADOW_WIDTH / 2
  local shadowY = SINGLE_FOE.y - SHADOW_HEIGHT / 2
  local shadowed = false
  for _, entry in ipairs(drawn.graphics.draws) do
    if entry.x == shadowX and entry.y == shadowY then
      shadowed = true
      break
    end
  end
  Assert.isTrue(shadowed, "a shadow draw centers on the foe center with native shadow geometry")
end

-- All four double slots draw at their native settled centers and
-- health-box anchors, keep them while a partner hides or switches, and
-- carry height, shadow and tile health bars; the switch arrival starts
-- displaced toward its source spawn side and settles exactly.
function T.doubles_slots_keep_native_geometry_through_hide_switch_and_entry()
  local view = snapshot({
    battlers = {
      battler({ combatant = 1, side = 1, position = 0, activation = 11 }),
      battler({
        combatant = 4,
        side = 1,
        position = 1,
        activation = 14,
        name = "ALLY",
        level = 7,
        hp = 20,
        maxHp = 22,
        portraitSelector = "ALLY/0/male/plain/back",
      }),
      battler({
        combatant = 2,
        side = 2,
        position = 2,
        activation = 12,
        name = "FOE-A",
        level = 4,
        hp = 8,
        maxHp = 12,
        portraitSelector = "FOEA/0/male/plain/front",
      }),
      battler({
        combatant = 3,
        side = 2,
        position = 3,
        activation = 13,
        name = "FOE-B",
        level = 6,
        hp = 12,
        maxHp = 12,
        portraitSelector = "FOEB/0/male/plain/front",
      }),
    },
  })
  local drawn = drawnDetail(view)
  local slots = {
    { position = 0, handle = "mon:LEAD/0/male/plain/back" },
    { position = 1, handle = "mon:ALLY/0/male/plain/back" },
    { position = 2, handle = "mon:FOEA/0/male/plain/front" },
    { position = 3, handle = "mon:FOEB/0/male/plain/front" },
  }
  local settled = {}
  for _, slot in ipairs(slots) do
    local geometry = DOUBLES_SETTLED[slot.position + 1]
    local pictures = drawsOf(drawn.graphics.draws, slot.handle)
    Assert.isTrue(#pictures >= 1, "the position " .. slot.position .. " portrait draws")
    local originX, originY = nominalOrigin(geometry, 0)
    Assert.equal(pictures[1].x, originX, "position " .. slot.position .. " keeps its settled left edge")
    Assert.equal(pictures[1].y, originY, "position " .. slot.position .. " keeps its settled top edge")
    settled[slot.handle] = tostring(pictures[1].x) .. ":" .. tostring(pictures[1].y)
    local anchor = DOUBLES_HUD[slot.position + 1]
    Assert.equal(anchor.side, geometry.side, "position " .. slot.position .. " pairs one side type")
    local hudCell = { x = anchor.x - 64, y = anchor.y - 64, width = 192, height = 128 }
    Assert.isTrue(
      quadDrawsIn(drawn.graphics.draws, hudCell) >= 1,
      "position " .. slot.position .. " draws its health-box cell at its native anchor"
    )
  end
  Assert.equal(#drawn.graphics.rectangles, 0, "doubled health bars never use painted rectangles")

  local gapped = snapshot({
    battlers = {
      battler({ combatant = 1, side = 1, position = 0, activation = 11 }),
      battler({
        combatant = 4,
        side = 1,
        position = 1,
        activation = 14,
        name = "ALLY",
        level = 7,
        hp = 20,
        maxHp = 22,
        portraitSelector = "ALLY/0/male/plain/back",
      }),
      battler({
        combatant = 2,
        side = 2,
        position = 2,
        activation = 12,
        name = "FOE-A",
        level = 4,
        hp = 8,
        maxHp = 12,
        portraitSelector = "FOEA/0/male/plain/front",
      }),
      battler({
        combatant = 3,
        side = 2,
        position = 3,
        activation = 13,
        visible = false,
        name = "FOE-B",
        level = 6,
        hp = 12,
        maxHp = 12,
        portraitSelector = "FOEB/0/male/plain/front",
      }),
    },
  })
  local partial = drawnDetail(gapped)
  local survivors = 0
  for handle, origin in pairs(settled) do
    local pictures = drawsOf(partial.graphics.draws, handle)
    if handle ~= "mon:FOEB/0/male/plain/front" then
      Assert.equal(#pictures, 1, "the " .. handle .. " survivor keeps drawing while one partner hides")
      Assert.equal(
        tostring(pictures[1].x) .. ":" .. tostring(pictures[1].y),
        origin,
        "the " .. handle .. " survivor keeps its settled origin mid-transition"
      )
      survivors = survivors + 1
    else
      Assert.equal(#pictures, 0, "the hidden partner portrait draws nothing")
    end
  end
  Assert.equal(survivors, 3, "three survivors keep drawing while one partner hides")

  local switched = snapshot({
    battlers = {
      battler({ combatant = 1, side = 1, position = 0, activation = 11 }),
      battler({
        combatant = 4,
        side = 1,
        position = 1,
        activation = 14,
        name = "ALLY",
        level = 7,
        hp = 20,
        maxHp = 22,
        portraitSelector = "ALLY/0/male/plain/back",
      }),
      battler({
        combatant = 2,
        side = 2,
        position = 2,
        activation = 12,
        name = "FOE-A",
        level = 4,
        hp = 8,
        maxHp = 12,
        portraitSelector = "FOEA/0/male/plain/front",
      }),
      battler({
        combatant = 5,
        side = 2,
        position = 3,
        activation = 21,
        name = "FOE-C",
        level = 8,
        hp = 18,
        maxHp = 18,
        portraitSelector = "FOEC/0/male/plain/front",
      }),
    },
  })
  local arrival = drawnDetail(switched)
  local newcomer = drawsOf(arrival.graphics.draws, "mon:FOEC/0/male/plain/front")
  Assert.isTrue(#newcomer >= 1, "the switched arrival draws at its own slot")
  local settledX = nominalOrigin(DOUBLES_SETTLED[4], 0)
  Assert.equal(newcomer[1].x, settledX, "the switched arrival keeps its slot settled edge once placed")
end

-- Ordinary scenes honor viewport scroll on the decoded background layer
-- while portraits stay layer-independent, and the renderer draws only
-- the ordinary scene identity it was given.
function T.ordinary_scenes_honor_scroll_on_their_own_layer()
  local scrolled = drawnDetail(snapshot({ bgScroll = { x = 24, y = 16 } }))
  local scene = drawsOf(scrolled.graphics.draws, "scene:test")
  Assert.isTrue(#scene >= 1, "the ordinary scene draws")
  Assert.equal(scene[1].x, -24, "a horizontal scroll shifts the background layer left by its scroll")
  Assert.equal(scene[1].y, -16, "a vertical scroll shifts the background layer up by its scroll")
  local foe = drawsOf(scrolled.graphics.draws, "mon:FOE/0/male/plain/front")
  Assert.isTrue(#foe >= 1, "the foe portrait still draws under scroll")
  local foeX, foeY = nominalOrigin(SINGLE_FOE, 0)
  Assert.equal(foe[1].x, foeX, "background scroll never moves the foe portrait")
  Assert.equal(foe[1].y, foeY, "background scroll never lifts the foe portrait")

  local plain = drawnDetail(snapshot())
  local still = drawsOf(plain.graphics.draws, "scene:test")
  Assert.isTrue(#still >= 1, "the ordinary scene draws without scroll")
  Assert.equal(still[1].x, 0, "no scroll keeps the background layer at its viewport origin")
  Assert.equal(still[1].y, 0, "no scroll keeps the background layer at its viewport top")
  for _, key in ipairs(plain.requests) do
    Assert.isNil(tostring(key):find("effect", 1, true), "the ordinary scene draw never aliases an effect background")
  end
end

-- Health and experience draw as native tile work at integer pixel
-- capacities with the native color selection and level-boundary resets:
-- no painted rectangles, no printed experience totals, neutral image
-- tint, and tile selection that follows the value.
function T.health_and_experience_draw_as_native_tile_work()
  local vectors = {
    { hp = 30, maxHp = 30, label = "full health" },
    { hp = 1, maxHp = 30, label = "the minimum visible nonzero health" },
    { hp = 7, maxHp = 30, label = "health indivisible by the bar capacity" },
    { hp = 24, maxHp = 48, label = "health just below the green boundary" },
    { hp = 25, maxHp = 48, label = "health just above the green boundary" },
    { hp = 10, maxHp = 48, label = "health just above the yellow boundary" },
    { hp = 9, maxHp = 48, label = "health just below the yellow boundary" },
    { hp = 0, maxHp = 48, label = "zero health" },
    { hp = 5, maxHp = 7, label = "small health indivisible by the bar capacity" },
    { hp = 48, maxHp = 48, label = "maximum health" },
  }
  local greenTiles, redTiles = nil, nil
  for _, vector in ipairs(vectors) do
    local drawn = drawnDetail(snapshot({
      battlers = {
        battler({ combatant = 1, side = 1, hp = vector.hp, maxHp = vector.maxHp, exp = 1234 }),
        battler({
          combatant = 2,
          side = 2,
          name = "FOE",
          level = 5,
          hp = vector.hp,
          maxHp = vector.maxHp,
          portraitSelector = "FOE/0/male/plain/front",
        }),
      },
    }))
    Assert.equal(
      #drawn.graphics.rectangles,
      0,
      vector.label .. " draws no painted rectangle anywhere on the battlefield"
    )
    Assert.equal(#textsOf(drawn.text, "1234"), 0, vector.label .. " never prints the accumulated experience total")
    for _, entry in ipairs(drawn.graphics.draws) do
      Assert.isFalse(isInterimTint(entry.color), vector.label .. " never tints artwork with an interim bar shade")
    end
    for _, entry in ipairs(drawn.graphics.rectangles) do
      Assert.isFalse(isInterimTint(entry.color), vector.label .. " never paints bar shades as rectangles")
    end
    if vector.hp == 30 and vector.maxHp == 30 then
      greenTiles = sampledTiles(drawn.graphics.draws)
    end
    if vector.hp == 9 and vector.maxHp == 48 then
      redTiles = sampledTiles(drawn.graphics.draws)
    end
  end
  Assert.notNil(greenTiles, "the full-health capture sampled its tiles")
  Assert.notNil(redTiles, "the critical-health capture sampled its tiles")
  Assert.isFalse(
    (function()
      if #greenTiles ~= #redTiles then
        return false
      end
      for index, tile in ipairs(greenTiles) do
        if tile ~= redTiles[index] then
          return false
        end
      end
      return true
    end)(),
    "full and critical health sample different bar tiles through the native color selection"
  )

  local hits = { 30, 22, 15, 9 }
  local previous = nil
  for _, hp in ipairs(hits) do
    local drawn = drawnDetail(snapshot({
      battlers = {
        battler({ combatant = 1, side = 1, hp = hp, maxHp = 30 }),
        battler({
          combatant = 2,
          side = 2,
          name = "FOE",
          level = 5,
          hp = hp,
          maxHp = 30,
          portraitSelector = "FOE/0/male/plain/front",
        }),
      },
    }))
    Assert.equal(#drawn.graphics.rectangles, 0, "multi-hit checkpoint " .. hp .. " draws no rectangles")
    Assert.equal(
      printedDigits(drawn.graphics.draws, "hud:player"),
      expectedDigits(tostring(hp), "30", "9", "9"),
      "multi-hit checkpoint " .. hp .. " prints its current HP, maximum HP, and level digits"
    )
    local tiles = sampledTiles(drawn.graphics.draws)
    if previous ~= nil then
      local same = #tiles == #previous
      if same then
        for index, tile in ipairs(tiles) do
          if tile ~= previous[index] then
            same = false
            break
          end
        end
      end
      Assert.isFalse(same, "multi-hit checkpoint " .. hp .. " advances its sampled bar tiles")
    end
    previous = tiles
  end

  local leveled = drawnDetail(snapshot({
    battlers = {
      battler({ combatant = 1, side = 1, level = 11, exp = 40 }),
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
  Assert.equal(#textsOf(leveled.text, "40"), 0, "experience across a level boundary never prints its total")
  Assert.equal(
    printedDigits(leveled.graphics.draws, "hud:player"),
    expectedDigits("30", "30", "11", "11"),
    "the new level prints after a multi-level gain"
  )

  local capped = drawnDetail(snapshot({
    battlers = {
      battler({ combatant = 1, side = 1, level = 100, exp = 8000 }),
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
  Assert.equal(#textsOf(capped.text, "8000"), 0, "a capped level never prints experience")
end

-- Health-box fields render every native fact through source component
-- tiles inside their spans: gender and caught marks appear, status stays,
-- long names never overlap their neighbors, and the foe hides private
-- health facts.
function T.health_box_fields_render_every_native_fact_in_span()
  local function hudBoxTexts(view)
    return drawnDetail(view)
  end
  local base = snapshot()
  local baseDrawn = hudBoxTexts(base)
  local baseEnemy = textsOf(baseDrawn.text, "FOE")
  local basePlayer = textsOf(baseDrawn.text, "LEAD")
  Assert.isTrue(#baseEnemy > 0, "the foe box carries its name wording")
  Assert.isTrue(#basePlayer > 0, "the player box carries its name wording")
  Assert.isTrue(printedDigits(baseDrawn.graphics.draws, "hud:enemy") ~= "", "the foe level uses source printer tiles")
  Assert.isTrue(
    printedDigits(baseDrawn.graphics.draws, "hud:player") ~= "",
    "the player values use source printer tiles"
  )
  for _, entry in ipairs(baseEnemy) do
    Assert.notNil(entry.palette, "foe box wording carries its native palette")
  end

  local function nativeMarks(drawn, artKey)
    local tiles = {}
    for _, entry in ipairs(drawn.graphics.draws) do
      if
        type(entry.image) == "table"
        and entry.image.handle == artKey
        and entry.quad ~= nil
        and entry.quad.x >= 128 * 8
      then
        local relative = quadTile(entry.quad) - 128
        -- Health and experience tiles occupy relative 0..37 (at most
        -- the red base plus a full fill, then the experience base plus
        -- a full fill); status marks start above them, and printer
        -- digits follow the 78 components.
        if relative >= 38 and relative < 78 then
          tiles[#tiles + 1] = relative
        end
      end
    end
    table.sort(tiles)
    return tiles
  end

  Assert.deepEqual(nativeMarks(baseDrawn, "hud:enemy"), { 38, 39, 40 }, "healthy status uses native mark tiles")
  Assert.deepEqual(nativeMarks(baseDrawn, "hud:player"), { 38, 39, 40 }, "healthy status uses native mark tiles")
  for _, entry in ipairs(basePlayer) do
    Assert.notNil(entry.palette, "player box wording carries its native palette")
  end

  local gendered = snapshot({
    battlers = {
      battler({ combatant = 1, side = 1, gender = "female" }),
      battler({
        combatant = 2,
        side = 2,
        name = "FOE",
        level = 5,
        hp = 12,
        maxHp = 12,
        gender = "male",
        portraitSelector = "FOE/0/male/plain/front",
      }),
    },
  })
  local genderedDrawn = hudBoxTexts(gendered)
  Assert.deepEqual(
    nativeMarks(genderedDrawn, "hud:player"),
    { 38, 39, 40, 60, 61, 72, 73 },
    "female and healthy marks use native component tiles"
  )
  Assert.deepEqual(
    nativeMarks(genderedDrawn, "hud:enemy"),
    { 38, 39, 40, 62, 63, 74, 75 },
    "male and healthy marks use native component tiles"
  )

  local caught = snapshot({
    battlers = {
      battler({ combatant = 1, side = 1 }),
      battler({
        combatant = 2,
        side = 2,
        name = "FOE",
        level = 5,
        hp = 12,
        maxHp = 12,
        caught = true,
        portraitSelector = "FOE/0/male/plain/front",
      }),
    },
  })
  local caughtDrawn = hudBoxTexts(caught)
  Assert.deepEqual(
    nativeMarks(caughtDrawn, "hud:enemy"),
    { 38, 39, 40, 59 },
    "caught state uses its native component tile"
  )

  local trainer = snapshot({
    battleKind = "trainer",
    battlers = {
      battler({ combatant = 1, side = 1 }),
      battler({
        combatant = 2,
        side = 2,
        name = "FOE",
        level = 5,
        hp = 12,
        maxHp = 12,
        caught = true,
        portraitSelector = "FOE/0/male/plain/front",
      }),
    },
  })
  local trainerDrawn = hudBoxTexts(trainer)
  Assert.deepEqual(
    nativeMarks(trainerDrawn, "hud:enemy"),
    { 38, 39, 40 },
    "trainer health boxes omit the caught icon field"
  )

  local uncaught = snapshot({
    battlers = {
      battler({ combatant = 1, side = 1 }),
      battler({
        combatant = 2,
        side = 2,
        name = "FOE",
        level = 5,
        hp = 12,
        maxHp = 12,
        caught = false,
        portraitSelector = "FOE/0/male/plain/front",
      }),
    },
  })
  local uncaughtDrawn = hudBoxTexts(uncaught)
  Assert.deepEqual(
    nativeMarks(uncaughtDrawn, "hud:enemy"),
    { 38, 38, 39, 40 },
    "uncaught state uses its native alternate component tile"
  )

  local ill = snapshot({
    battlers = {
      battler({ combatant = 1, side = 1, condition = "poison" }),
      battler({
        combatant = 2,
        side = 2,
        name = "FOE",
        level = 5,
        hp = 12,
        maxHp = 12,
        condition = "sleep",
        portraitSelector = "FOE/0/male/plain/front",
      }),
    },
  })
  local illDrawn = hudBoxTexts(ill)
  Assert.deepEqual(nativeMarks(illDrawn, "hud:player"), { 44, 45, 46 }, "poison uses its native component tiles")
  Assert.deepEqual(nativeMarks(illDrawn, "hud:enemy"), { 53, 54, 55 }, "sleep uses its native component tiles")

  local long = snapshot({
    battlers = {
      battler({ combatant = 1, side = 1, name = "EXCEEDINGLYLONGNAME" }),
      battler({
        combatant = 2,
        side = 2,
        name = "ANOTHEROVERLONGFOENAME",
        level = 5,
        hp = 12,
        maxHp = 12,
        portraitSelector = "FOE/0/male/plain/front",
      }),
    },
  })
  local longDrawn, longEnemy, longPlayer = hudBoxTexts(long)
  local _, _, _ = longDrawn, longEnemy, longPlayer
  -- Names print only through their sixteen window tiles, each print
  -- clipped to its own tile, so overlong names never pass the window.
  Assert.equal(#textsOf(longDrawn.text, "EXCEEDINGLYLONGNAME"), 16, "the player name prints per window tile")
  Assert.equal(#textsOf(longDrawn.text, "ANOTHEROVERLONGFOENAME"), 16, "the foe name prints per window tile")

  local private_ = snapshot()
  local privateDrawn = drawnDetail(private_)
  Assert.equal(
    printedDigits(privateDrawn.graphics.draws, "hud:enemy"),
    expectedDigits("5", "5"),
    "the foe box prints only its level, never numeric health"
  )
  Assert.equal(
    printedDigits(privateDrawn.graphics.draws, "hud:player"),
    expectedDigits("30", "30", "9", "9"),
    "the player box prints separate current and maximum HP digits"
  )
end

-- Native layering survives hostile incoming graphics state on both the
-- paired and compact compositions, and the compact adaptation reflows
-- real source parts instead of whole tile strips with numeric
-- experience.
function T.layers_survive_hostile_state_with_explicit_compact_adaptation()
  local poison = { 0.3, 0.4, 0.9, 1 }
  local drawn = drawnDetail(snapshot(), { color = poison })
  local graphics = drawn.graphics
  Assert.isTrue(#graphics.draws > 0, "the battlefield draws under hostile incoming color")
  for _, entry in ipairs(graphics.draws) do
    Assert.deepEqual(entry.color, { 1, 1, 1, 1 }, "battle artwork draws under neutral image tint")
  end
  local red, green, blue, alpha = graphics.getColor()
  Assert.deepEqual(
    { red, green, blue, alpha },
    poison,
    "the hostile incoming color is restored after the battlefield draw"
  )
  Assert.equal(#graphics.rectangles, 0, "hostile state never recovers painted rectangles")
  local scene = drawsOf(graphics.draws, "scene:test")
  Assert.isTrue(#scene >= 1, "the scene layer draws under hostile state")
  Assert.equal(scene[1].x, 0, "the scene layer keeps its viewport origin under hostile state")

  local ApplicationPresentation = require("libs.ui.src.ApplicationPresentation")
  local BattleScreenInterface = require("game.hgss.src.battle.BattleScreenInterface")
  local ScreenTopology = require("libs.ui.src.ScreenTopology")
  local view = snapshot({
    battlers = {
      battler({ combatant = 1, side = 1, exp = 1234 }),
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
    signature = "scene-compact-probe",
  }
  local session = ApplicationPresentation.new(BattleScreenInterface.defaults(), nil)
  local plan = session:resolve(measurement, view)
  Assert.isTrue(plan.content.compact == true, "the small display resolves the compact adaptation")
  local compactGraphics = FakeGraphics.new({ color = poison })
  local compactText = recordingText()
  local compactWindows = recordingWindows()
  local compactResources = {
    graphics = compactGraphics,
    text = compactText,
    windows = compactWindows,
    assets = {
      drawable = function(_, key)
        return stagedDrawable(key)
      end,
      release = function(_, _) end,
    },
    frameKey = "scene-test-frame",
    sceneImageKey = "scene:test",
  }
  BattleRenderer.drawPane(compactResources, view, "compact", plan.content)
  for _, entry in ipairs(compactGraphics.draws) do
    if type(entry.image) == "table" and entry.image.handle ~= nil then
      local handle = entry.image.handle --[[@as string]]
      if handle == "hud:enemy" or handle == "hud:player" then
        Assert.notNil(entry.quad, "the compact " .. handle .. " reflows source parts, never a whole strip")
      end
      Assert.deepEqual(entry.color, { 1, 1, 1, 1 }, "compact artwork draws under neutral image tint")
    end
  end
  local hud = assert(plan.content.hud, "the compact plan carries its health boxes")
  for _, side in ipairs({ { box = hud.enemy, label = "enemy" }, { box = hud.player, label = "player" } }) do
    local regions = assert(side.box.regions, "the compact " .. side.label .. " box publishes its regions")
    local seen = {}
    for _, region in ipairs(regions) do
      if region.id == "hp" then
        seen[region.id] = true
      elseif type(region.text) == "string" and region.text ~= "" then
        seen[region.id] = region.text
      end
    end
    Assert.notNil(seen["name"], "the compact " .. side.label .. " box keeps its name field")
    Assert.notNil(seen["hp"], "the compact " .. side.label .. " box keeps its health field")
  end
  local expText = nil
  for _, region in ipairs(hud.player.regions) do
    if region.id == "exp" then
      expText = region.text
    end
  end
  Assert.isTrue(
    expText == nil or tostring(expText):find("^%d+$", 1) == nil,
    "the compact player box never prints numeric experience"
  )
end

-- The substitute doll is drawn by native animation roots 25/26; C05 hides
-- the replaced mon and never requests an invented static doll drawable.
function T.substitute_picture_is_owned_by_the_native_animation_route()
  local base = snapshot()
  local before = drawnDetail(base)
  local foeHandle = "mon:FOE/0/male/plain/front"
  local leadHandle = "mon:LEAD/0/male/plain/back"

  local substituted = snapshot({
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
        substitute = true,
        rotation = 0.5,
        scaleX = 1.5,
        scaleY = 1.5,
      }),
    },
  })
  local changed = drawnDetail(substituted)
  Assert.equal(#drawsOf(changed.graphics.draws, foeHandle), 0, "an active substitute hides the replaced mon picture")
  Assert.equal(
    #drawsOf(changed.graphics.draws, "substitute"),
    0,
    "the scene does not draw a static substitute outside its native animation task"
  )
  for _, key in ipairs(changed.requests) do
    Assert.isFalse(key == "substitute", "the scene requests no fabricated substitute drawable")
  end
  local leadBefore = drawsOf(before.graphics.draws, leadHandle)
  local leadAfter = drawsOf(changed.graphics.draws, leadHandle)
  Assert.deepEqual(leadAfter, leadBefore, "the unrelated player activation draws identically")

  local transformed = snapshot({
    battlers = {
      battler({
        combatant = 1,
        side = 1,
        portraitSelector = "FOE/0/male/plain/back",
        height = 6,
      }),
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
  })
  local morphed = drawnDetail(transformed)
  local copied = drawsOf(morphed.graphics.draws, "mon:FOE/0/male/plain/back")
  Assert.isTrue(#copied >= 1, "a transformed battler draws through its copied appearance selector")
  local copiedX, copiedY = nominalOrigin(SINGLE_PLAYER, 6)
  Assert.equal(copied[1].x, copiedX, "a transformed battler keeps the native left edge")
  Assert.equal(copied[1].y, copiedY, "a transformed battler applies its new height displacement")

  local restored = drawnDetail(base)
  Assert.deepEqual(
    restored.graphics.draws,
    before.graphics.draws,
    "restore returns the exact original battlefield draws"
  )
  Assert.deepEqual(restored.text.draws, before.text.draws, "restore returns the exact original wording")
end

function T.pokepic_shadow_uses_source_adjustment_flags_and_picture_position()
  local calls = {}
  drawnDetail(
    snapshot({
      battlers = {
        battler({
          combatant = 1,
          side = 1,
          sourceHeight = 4,
          shakeDx = 3,
          pictureXOffset = 2,
          pictureYOffset = -1,
          shadowSize = 1,
          shadowOffsetX = 5,
          shadowOffsetY = 6,
          shadowAdjustX = true,
          shadowAdjustY = true,
        }),
        battler({ combatant = 2, side = 2, portraitSelector = "FOE/0/male/plain/front" }),
      },
    }),
    {
      observeDraw = function(image, x, y)
        if type(image) == "table" and image.handle == "shadow" then
          calls[#calls + 1] = { x, y }
        end
      end,
    }
  )
  -- pokepic.c: shadow.y = yCenter + yOffset + shadow.yOffset, where
  -- yCenter = settled row + picture height; the 16-pixel quad centers on it.
  Assert.deepEqual(calls[1], { 42, 113 }, "adjusted shadow follows the source picture center and offsets")

  local fixed = {}
  drawnDetail(
    snapshot({
      battlers = {
        battler({
          combatant = 1,
          side = 1,
          shadowSize = 1,
          shadowX = 130,
          shadowY = 90,
          shadowAdjustX = false,
          shadowAdjustY = false,
        }),
        battler({ combatant = 2, side = 2, portraitSelector = "FOE/0/male/plain/front" }),
      },
    }),
    {
      observeDraw = function(image, x, y)
        if type(image) == "table" and image.handle == "shadow" then
          fixed[#fixed + 1] = { x, y }
        end
      end,
    }
  )
  Assert.deepEqual(fixed[1], { 98, 82 }, "disabled source adjustment uses the explicit shadow center")
end

return { tests = T }
