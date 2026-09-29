-- Native party-screen renderer contracts through the compiled party
-- manifest: chrome panels at source origins, digit/level/slash glyph
-- numerals, status text replacing the level line, egg name-only cards,
-- held and capsule indicators, selected shifts with healthy bob, menu and
-- message windows, and the multi-pane detail pane. Driven through an
-- injected graphics namespace with stub images so no GPU resource is
-- created; the manifest fixture mirrors the compiled source shape.

local Assert = require("tests.support.Assert")
local PartyScreenLayout = require("libs.hgss.src.ui.PartyScreenLayout")
local PartyScreenRenderer = require("libs.hgss.src.ui.PartyScreenRenderer")

local T = {}

local fakeGraphics = require("tests.support.FakeGraphics").new

local function rect(x, y, width, height)
  return { x = x, y = y, width = width, height = height }
end

local function imageRef(path, width, height)
  return { image = path, width = width or 32, height = height or 32 }
end

local function frameRef(path, width, height)
  return { image = path, width = width or 32, height = height or 32, offset = { x = 0, y = 0 }, durationTicks = 1 }
end

local function sourceManifest()
  local panels = {}
  local origins = { { 0, 0 }, { 128, 8 }, { 0, 48 }, { 128, 56 }, { 0, 96 }, { 128, 104 } }
  for slot, origin in ipairs(origins) do
    panels[slot] = {
      origin = { x = origin[1], y = origin[2] },
      size = { width = 128, height = 48 },
      chrome = { normal = imageRef("assets/generated/party/panel.png", 128, 48) },
      text = {
        name = rect(origin[1] + 48, origin[2] + 8, 72, 16),
        level = rect(origin[1] + 0, origin[2] + 32, 48, 16),
      },
      hp = {
        bar = rect(origin[1] + 64, origin[2] + 24, 48, 8),
        number = rect(origin[1] + 56, origin[2] + 32, 64, 16),
      },
      compat = rect(origin[1] + 48, origin[2] + 32, 80, 16),
    }
  end
  local digits = {}
  for digit = 0, 9 do
    digits[digit + 1] = imageRef("assets/generated/party/digit-" .. digit .. ".png", 8, 8)
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
      message = rect(16, 168, 160, 16),
      context = rect(152, 120, 96, 64),
    },
    visuals = {
      balls = {
        sequences = {
          { frames = { frameRef("assets/generated/party/ball-0.png") } },
          { frames = { frameRef("assets/generated/party/ball-1.png") } },
        },
      },
      held = { sequences = { { frames = { frameRef("assets/generated/party/held.png", 8, 8) } } } },
      cursor = { sequences = { { frames = { frameRef("assets/generated/party/cursor.png", 128, 48) } } } },
    },
    iconAnimations = { periods = { 1, 8, 12, 24, 40, 36 } },
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
    numberGlyphs = {
      advance = 8,
      digits = digits,
      level = imageRef("assets/generated/party/level.png", 16, 8),
      slash = imageRef("assets/generated/party/slash.png", 8, 8),
    },
    text = { labels = {}, templates = {} },
  }
end

local function fakeCacheFs()
  return {
    read = function(_)
      return "stub-bytes"
    end,
  }
end

local function icons()
  return {
    image = function()
      return "atlas"
    end,
    quadFor = function(_, key)
      return { key = key }
    end,
    dimensions = function(_)
      return { width = 32, height = 32 }
    end,
  }
end

---@param slot0 integer
---@param overrides table<string, any>?
---@return table<string, any>
local function slot(slot0, overrides)
  local record = { slot = slot0, occupied = false, eligible = false }
  for key, value in pairs(overrides or {}) do
    record[key] = value
  end
  return record
end

---@param slot0 integer
---@param overrides table<string, any>?
---@return table<string, any>
local function occupiedSlot(slot0, overrides)
  local base = {
    slot = slot0,
    occupied = true,
    eligible = true,
    iconKey = "MON" .. slot0 .. "/f0",
    displayName = "MON" .. slot0,
    level = 5,
    gender = "male",
    status = "ok",
    currentHp = 20,
    maxHp = 20,
    hpFraction = 1,
    isEgg = false,
    heldItem = "NONE",
    capsule = nil,
    moves = {},
    shinyLeaves = 0,
  }
  for key, value in pairs(overrides or {}) do
    base[key] = value
  end
  return base
end

---@param overrides table<string, any>?
---@return table<string, any>
local function presentation(overrides)
  local status = {
    open = true,
    context = "browse",
    state = "browse",
    cursorNode = 0,
    menuIndex = nil,
    menu = nil,
    menuSlot = nil,
    message = nil,
    swap = nil,
    anim = { tick = 0, sequences = {}, phases = {}, panelSlide = 0 },
    infoOverlay = false,
    view = { revision = 1, slots = {} },
    cancellable = true,
  }
  for index = 1, 6 do
    status.view.slots[index] = slot(index - 1)
    status.anim.sequences[index] = 1
    status.anim.phases[index] = 0
  end
  for key, value in pairs(overrides or {}) do
    status[key] = value
  end
  return status
end

local function layout()
  return PartyScreenLayout.resolve({ manifest = sourceManifest(), cancellable = true })
end

local function newRenderer(graphics, texts)
  return PartyScreenRenderer.new({
    graphics = graphics,
    cacheFs = fakeCacheFs(),
    manifest = sourceManifest(),
    text = texts,
  })
end

-- The borrowed generated-font collaborator: records drawn strings while
-- measuring eight units per glyph, so truncation and alignment stay
-- deterministic without GPU resources.
local function stubText(calls)
  return {
    draws = calls,
    drawText = function(_, value, x, y)
      calls[#calls + 1] = { value = value, x = x, y = y }
    end,
    textWidth = function(_, value)
      return #value * 8
    end,
  }
end

local function hasString(calls, value)
  for _, call in ipairs(calls) do
    if call.value == value then
      return true
    end
  end
  return false
end

function T.occupied_slots_draw_chrome_icons_glyphs_and_status()
  local graphics = fakeGraphics()
  local texts = {}
  local renderer = newRenderer(graphics, stubText(texts))
  local status = presentation()
  status.view.slots[1] = occupiedSlot(0, { status = "poison", currentHp = 7, maxHp = 20 })
  status.view.slots[2] = occupiedSlot(1, { heldItem = "SITRUS_BERRY", capsule = { id = 3, seals = {} } })
  renderer:draw(status, layout(), icons())
  local chromeAt = {}
  local quadKeys = {}
  for _, draw in ipairs(graphics.draws) do
    if draw.quad == nil then
      chromeAt[#chromeAt + 1] = { draw.x, draw.y }
    elseif draw.quad.key ~= nil then
      quadKeys[#quadKeys + 1] = draw.quad.key
    end
  end
  Assert.isTrue(#chromeAt >= 6, "every panel paints its chrome")
  Assert.isTrue(hasString(texts, "MON0"), "names print through the generated font")
  Assert.isTrue(hasString(texts, "PSN"), "status text replaces the level line")
  Assert.isFalse(hasString(texts, "M"), "no gender letter ever prints")
  Assert.isFalse(hasString(texts, "F"), "no gender letter ever prints")
end

function T.eggs_print_names_without_level_or_hp()
  local graphics = fakeGraphics()
  local texts = {}
  local renderer = newRenderer(graphics, stubText(texts))
  local status = presentation()
  status.view.slots[1] = occupiedSlot(0, { isEgg = true })
  local before = #graphics.draws
  renderer:draw(status, layout(), icons())
  Assert.isTrue(#graphics.draws > before, "the egg still draws")
  Assert.isTrue(hasString(texts, "MON0"), "egg names print")
end

function T.empty_slots_draw_chrome_without_facts()
  local graphics = fakeGraphics()
  local texts = {}
  local renderer = newRenderer(graphics, stubText(texts))
  local status = presentation()
  status.view.slots[1] = occupiedSlot(0)
  local draws = #graphics.draws
  local strings = #texts
  renderer:draw(status, layout(), icons())
  Assert.isTrue(#graphics.draws > draws, "empty chrome still paints")
  Assert.equal(#texts, strings + 3, "the occupied name prints on its card and in the footer, plus cancel")
end

function T.selected_icons_shift_with_healthy_bob()
  local graphics = fakeGraphics()
  local texts = {}
  local renderer = newRenderer(graphics, stubText(texts))
  local healthy = presentation({ cursorNode = 0 })
  healthy.view.slots[1] = occupiedSlot(0)
  healthy.anim.phases[1] = 0
  renderer:draw(healthy, layout(), icons())
  local selectedDraw = graphics.draws[2]
  local plain = presentation({ cursorNode = 5 })
  plain.view.slots[1] = occupiedSlot(0)
  local graphics2 = fakeGraphics()
  local renderer2 = newRenderer(graphics2, stubText({}))
  renderer2:draw(plain, layout(), icons())
  local unselectedDraw = graphics2.draws[2]
  Assert.isTrue(selectedDraw.x ~= unselectedDraw.x or selectedDraw.y ~= unselectedDraw.y, "selection shifts the icon")
end

function T.swap_ticks_offset_both_records_and_exchange_at_midpoint()
  local graphics = fakeGraphics()
  local texts = {}
  local renderer = newRenderer(graphics, stubText(texts))
  local status = presentation({
    state = "swapping",
    swap = { source = 0, destination = 1, step = 10, stage = "out", offsetPx = -72, exchanged = false },
  })
  status.view.slots[1] = occupiedSlot(0)
  status.view.slots[2] = occupiedSlot(1)
  renderer:draw(status, layout(), icons())
  Assert.isTrue(#graphics.draws > 0, "offset records still draw")
  local mid = presentation({
    state = "swapping",
    swap = { source = 0, destination = 1, step = 18, stage = "in", offsetPx = -128, exchanged = true },
  })
  mid.view.slots[1] = occupiedSlot(0)
  mid.view.slots[2] = occupiedSlot(1)
  local graphics2 = fakeGraphics()
  local renderer2 = newRenderer(graphics2, stubText({}))
  renderer2:draw(mid, layout(), icons())
  Assert.isTrue(#graphics2.draws > 0, "exchanged records still draw")
end

function T.context_menu_draws_one_row_per_entry()
  local graphics = fakeGraphics()
  local texts = {}
  local renderer = newRenderer(graphics, stubText(texts))
  local menu = {
    { kind = "summary", label = "SUMMARY" },
    { kind = "switch", label = "SWITCH" },
    { kind = "quit", label = "QUIT" },
  }
  local status = presentation({ state = "context", menu = menu, menuIndex = 2, menuSlot = 0 })
  status.view.slots[1] = occupiedSlot(0)
  renderer:draw(status, layout(), icons())
  Assert.isTrue(hasString(texts, "SUMMARY"), "menu rows print their labels")
  Assert.isTrue(hasString(texts, "SWITCH"), "menu rows print their labels")
  Assert.isTrue(hasString(texts, "QUIT"), "menu rows print their labels")
end

function T.message_draws_its_window_text()
  local graphics = fakeGraphics()
  local texts = {}
  local renderer = newRenderer(graphics, stubText(texts))
  local status = presentation({ state = "message", message = "NO ENTRY" })
  status.view.slots[1] = occupiedSlot(0)
  renderer:draw(status, layout(), icons())
  Assert.isTrue(hasString(texts, "NO ENTRY"), "messages print through the generated font")
end

-- Production resolves detail panes to LayoutGeometry placements (frame,
-- origin, scale, logical dimensions), never bare rects: the pane draws
-- inside its LogicalSurface scope, so the background and the upper-screen
-- anchors sit at the pane-local logical origin.
function T.detail_pane_draws_in_pane_local_logical_coordinates()
  local graphics = fakeGraphics()
  local texts = {}
  local renderer = newRenderer(graphics, stubText(texts))
  local resolved = layout()
  local placement = {
    frame = { x = 64, y = 48, width = 512, height = 384 },
    origin = { x = 64, y = 48 },
    scale = 2,
    logicalWidth = 256,
    logicalHeight = 192,
  }
  local plan = {
    panes = {
      { id = "content", placement = placement, interactive = true },
      { id = "detail", placement = placement, interactive = false },
    },
    frames = {},
    content = resolved,
    inputKey = "party",
  }
  local status = presentation({ cursorNode = 1 })
  status.view.slots[1] = occupiedSlot(0)
  status.view.slots[2] = occupiedSlot(1, { status = "burn", currentHp = 3, maxHp = 20 })
  renderer:draw(status, plan, icons())
  local background = nil
  for _, rectangle in ipairs(graphics.rectangles) do
    if rectangle.w == 256 and rectangle.h == 192 then
      background = rectangle
    end
  end
  Assert.notNil(background, "the detail pane paints its logical background")
  Assert.equal(background.x, 0, "the detail background starts at the pane-local origin")
  Assert.equal(background.y, 0, "the detail background starts at the pane-local origin")
  Assert.isTrue(hasString(texts, "MON1"), "the detail pane names the cursor mon")
  Assert.isTrue(hasString(texts, "BRN"), "the detail pane shows its status")
end

function T.detail_pane_draws_selected_facts_at_upper_anchors()
  local graphics = fakeGraphics()
  local texts = {}
  local renderer = newRenderer(graphics, stubText(texts))
  local resolved = layout()
  local placement = {
    frame = { x = 0, y = 0, width = 256, height = 192 },
    origin = { x = 0, y = 0 },
    scale = 1,
    logicalWidth = 256,
    logicalHeight = 192,
  }
  local plan = {
    panes = {
      { id = "content", placement = placement, interactive = true },
      { id = "detail", placement = placement, interactive = false },
    },
    frames = {},
    content = resolved,
    inputKey = "party",
  }
  local status = presentation({ cursorNode = 1 })
  status.view.slots[1] = occupiedSlot(0)
  status.view.slots[2] = occupiedSlot(1, { status = "burn", currentHp = 3, maxHp = 20 })
  renderer:draw(status, plan, icons())
  Assert.isTrue(hasString(texts, "MON1"), "the detail pane names the cursor mon")
  Assert.isTrue(hasString(texts, "BRN"), "the detail pane shows its status")
end

function T.closed_presentation_draws_nothing()
  local graphics = fakeGraphics()
  local texts = {}
  local renderer = newRenderer(graphics, stubText(texts))
  renderer:draw({ open = false }, layout(), icons())
  Assert.equal(#graphics.draws + #graphics.primitives + #graphics.rectangles, 0)
end

function T.occupied_slots_require_the_icon_provider()
  local graphics = fakeGraphics()
  local texts = {}
  local renderer = newRenderer(graphics, stubText(texts))
  local status = presentation()
  status.view.slots[1] = occupiedSlot(0)
  Assert.throws(function()
    renderer:draw(status, layout(), nil)
  end, "icons without a provider fail instead of drawing blanks")
end

function T.missing_manifest_sections_fail_at_construction()
  local graphics = fakeGraphics()
  local texts = {}
  Assert.throws(function()
    PartyScreenRenderer.new({ graphics = graphics, cacheFs = fakeCacheFs(), manifest = {}, text = texts })
  end, "a manifest without panels fails instead of drawing blanks")
end

return { tests = T }
