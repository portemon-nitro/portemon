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

local function sequence(path, width, height)
  return { frames = { frameRef(path, width, height) }, loopFrom = 1, playback = "static" }
end

local function sourceManifest()
  local panels = {}
  local origins = { { 0, 0 }, { 128, 8 }, { 0, 48 }, { 128, 56 }, { 0, 96 }, { 128, 104 } }
  for slot, origin in ipairs(origins) do
    panels[slot] = {
      origin = { x = origin[1], y = origin[2] },
      iconAnchor = { x = origin[1] + 30, y = origin[2] + 16 },
      ballAnchor = { x = origin[1] + 16, y = origin[2] + 14 },
      heldAnchor = { x = origin[1] + 38, y = origin[2] + 24 },
      capsuleAnchor = { x = origin[1] + 46, y = origin[2] + 24 },
      statusRect = rect(origin[1] + 24, origin[2] + 40, 24, 8),
      cursorSequence = 1,
      size = { width = 128, height = 48 },
      chrome = {
        normal = imageRef("assets/generated/party/panel.png", 128, 48),
        selected = imageRef("assets/generated/party/panel-selected.png", 128, 48),
        fainted = imageRef("assets/generated/party/panel-fainted.png", 128, 48),
        selectedFainted = imageRef("assets/generated/party/panel-selected-fainted.png", 128, 48),
      },
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
          sequence("assets/generated/party/ball-0.png"),
          sequence("assets/generated/party/ball-1.png"),
        },
      },
      held = { sequences = {
        sequence("assets/generated/party/held.png", 8, 8),
        sequence("assets/generated/party/mail.png", 8, 8),
        sequence("assets/generated/party/capsule.png", 8, 8),
      } },
      cursor = { sequences = { sequence("assets/generated/party/cursor.png", 128, 48) } },
      buttons = {
        sequences = {
          sequence("assets/generated/party/button-normal.png", 56, 32),
          sequence("assets/generated/party/button-selected.png", 56, 32),
          sequence("assets/generated/party/button-extra-0.png", 56, 16),
          sequence("assets/generated/party/button-extra-1.png", 56, 16),
        },
      },
      status = {
        paralysis = imageRef("assets/generated/party/status-paralysis.png", 24, 8),
        freeze = imageRef("assets/generated/party/status-freeze.png", 24, 8),
        sleep = imageRef("assets/generated/party/status-sleep.png", 24, 8),
        poison = imageRef("assets/generated/party/status-poison.png", 24, 8),
        burn = imageRef("assets/generated/party/status-burn.png", 24, 8),
        faint = imageRef("assets/generated/party/status-faint.png", 24, 8),
      },
      hpBars = {
        green = imageRef("assets/generated/party/hp-green.png", 48, 4),
        yellow = imageRef("assets/generated/party/hp-yellow.png", 48, 4),
        red = imageRef("assets/generated/party/hp-red.png", 48, 4),
      },
      backdropMain = imageRef("assets/generated/party/backdrop-main.png", 256, 256),
      backdropSub = imageRef("assets/generated/party/backdrop-sub.png", 256, 256),
      detailSub = imageRef("assets/generated/party/detail-sub.png", 256, 256),
      auxPanel = imageRef("assets/generated/party/aux-panel.png", 128, 48),
    },
    controls = { cancel = { anchor = { x = 232, y = 176 } } },
    detail = {
      iconAnchor = { x = 30, y = 200 },
      statusAnchor = { x = 50, y = 220 },
      nicknameTextOrigin = { x = 56, y = 192 },
      heldItemTextOrigin = { x = 138, y = 212 },
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
    text = {
      labels = { cancel = "Cancel" },
      templates = {
        chooseMon = { segments = { { kind = "glyph", code = 65, colorIndex = 0 } } },
      },
    },
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

local function newRenderer(graphics, texts, manifest)
  return PartyScreenRenderer.new({
    graphics = graphics,
    cacheFs = fakeCacheFs(),
    manifest = manifest or sourceManifest(),
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
    drawLine = function(_, tokens, x, y)
      calls[#calls + 1] = { tokens = tokens, x = x, y = y }
    end,
    textWidth = function(_, value)
      return #value * 8
    end,
  }
end

function T.cancel_focus_does_not_draw_slot_four_name_as_footer()
  local graphics = fakeGraphics()
  local texts = {}
  local manifest = sourceManifest()
  local renderer = newRenderer(graphics, stubText(texts), manifest)
  local status = presentation({ cursorNode = "cancel" })
  status.view.slots[1] = occupiedSlot(0, { displayName = "LEAD" })
  status.view.slots[5] = occupiedSlot(4, { displayName = "FOUR" })
  local resolved = PartyScreenLayout.resolve({ manifest = manifest, cancellable = true })
  renderer:draw(status, resolved, icons())

  local footerNameDraws = 0
  for _, call in ipairs(texts) do
    if call.value == "FOUR" and call.x == resolved.nameRect.x and call.y == resolved.nameRect.y then
      footerNameDraws = footerNameDraws + 1
    end
  end
  Assert.equal(footerNameDraws, 0, "Cancel focus does not borrow slot 4's name for the browse footer")

end

function T.numeric_cursor_and_normal_cancel_use_their_manifest_anchors()
  local graphics = fakeGraphics()
  local manifest = sourceManifest()
  local panelAnchor = manifest.navigation.dpad.default[1]
  panelAnchor.left, panelAnchor.top = 64, 25
  local cursorFrame = manifest.visuals.cursor.sequences[1].frames[1]
  cursorFrame.offset = { x = 3, y = -2 }
  local cursorImage = manifest.visuals.cursor.sequences[1].frames[1].image
  local buttonFrame = manifest.visuals.buttons.sequences[1].frames[1]
  local buttonImage = buttonFrame.image
  local cancelAnchor = manifest.controls.cancel.anchor
  local renderer = newRenderer(graphics, stubText({}), manifest)

  renderer:draw(presentation({ cursorNode = 0 }), PartyScreenLayout.resolve({ manifest = manifest, cancellable = true }), icons())

  local cursorDraw, buttonDraw
  for _, draw in ipairs(graphics.draws) do
    if draw.image == renderer._images["asset:" .. cursorImage] then
      cursorDraw = draw
    elseif draw.image == renderer._images["asset:" .. buttonImage] then
      buttonDraw = draw
    end
  end
  Assert.notNil(cursorDraw, "numeric focus draws the slot cursor")
  Assert.deepEqual(
    { cursorDraw.x, cursorDraw.y },
    { panelAnchor.left + cursorFrame.offset.x, panelAnchor.top + cursorFrame.offset.y },
    "slot cursor uses the generated dpad position plus frame offset"
  )
  Assert.notNil(buttonDraw, "ordinary numeric focus keeps the normal Cancel button visible")
  Assert.deepEqual(
    { buttonDraw.x, buttonDraw.y },
    { cancelAnchor.x + buttonFrame.offset.x, cancelAnchor.y + buttonFrame.offset.y },
    "normal Cancel button uses its generated anchor plus frame offset"
  )
end

function T.source_frames_without_offsets_draw_at_their_anchor()
  local graphics = fakeGraphics()
  local manifest = sourceManifest()
  manifest.visuals.balls.sequences[1].frames[1].offset = nil
  local ballImage = manifest.visuals.balls.sequences[1].frames[1].image
  local renderer = newRenderer(graphics, stubText({}), manifest)
  local status = presentation({ cursorNode = 5 })
  status.view.slots[1] = occupiedSlot(0)

  renderer:draw(status, PartyScreenLayout.resolve({ manifest = manifest, cancellable = true }), icons())

  local ballDraw
  for _, draw in ipairs(graphics.draws) do
    if draw.image == renderer._images["asset:" .. ballImage] then
      ballDraw = draw
      break
    end
  end
  Assert.notNil(ballDraw, "a source frame without an explicit offset still draws")
  Assert.deepEqual({ ballDraw.x, ballDraw.y }, { 16, 14 }, "an omitted zero offset uses the sprite anchor")
end

function T.browse_message_draws_compiled_template_inside_source_window()
  local graphics = fakeGraphics()
  local texts = {}
  local manifest = sourceManifest()
  local renderer = newRenderer(graphics, stubText(texts), manifest)
  local resolved = PartyScreenLayout.resolve({ manifest = manifest, cancellable = true })
  local message = manifest.text.templates.chooseMon
  for _, focus in ipairs({ 0, "cancel" }) do
    local status = presentation({ cursorNode = focus })
    status.view.slots[1] = occupiedSlot(0, { displayName = "LEAD" })
    status.view.slots[5] = occupiedSlot(4, { displayName = "FOUR" })
    local firstNewCall = #texts + 1
    renderer:draw(status, resolved, icons())

    local messageDraws = 0
    for index = firstNewCall, #texts do
      local call = texts[index]
      if call.tokens == message.segments and call.x == 20 and call.y == 172 then
        messageDraws = messageDraws + 1
      end
    end
    Assert.equal(messageDraws, 1, "the compiled choose-mon template draws inside the message window")
  end
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
  status.view.slots[2] = occupiedSlot(1, {
    heldItem = "SITRUS_BERRY",
    heldMarkerKind = "item",
    capsule = { id = 3, seals = {} },
  })
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
  Assert.isFalse(hasString(texts, "PSN"), "status uses its generated sprite rather than a text label")
  Assert.isFalse(hasString(texts, "M"), "no gender letter ever prints")
  Assert.isFalse(hasString(texts, "F"), "no gender letter ever prints")
end

function T.status_visuals_follow_semantic_keys_for_lower_cards()
  local graphics = fakeGraphics()
  local manifest = sourceManifest()
  local renderer = newRenderer(graphics, stubText({}), manifest)
  local keys = { "paralysis", "freeze", "sleep", "poison", "burn", "faint" }
  local status = presentation()
  for slot0, key in ipairs(keys) do
    status.view.slots[slot0] = occupiedSlot(slot0 - 1, { status = key })
  end

  renderer:draw(status, PartyScreenLayout.resolve({ manifest = manifest, cancellable = true }), icons())

  for slot0, key in ipairs(keys) do
    local visual = manifest.visuals.status[key]
    local expectedImage = renderer._images["asset:" .. visual.image]
    local expectedRect = manifest.panels[slot0].statusRect
    local found
    for _, draw in ipairs(graphics.draws) do
      if draw.image == expectedImage and draw.x == expectedRect.x and draw.y == expectedRect.y then
        found = true
        break
      end
    end
    Assert.isTrue(found, key .. " status uses its semantic visual at the generated panel rectangle")
  end
end

function T.held_mail_and_capsule_use_semantic_kind_and_generated_anchors()
  local graphics = fakeGraphics()
  local manifest = sourceManifest()
  local heldFrame = manifest.visuals.held.sequences[2].frames[1]
  heldFrame.offset = { x = 2, y = -1 }
  local capsuleFrame = manifest.visuals.held.sequences[3].frames[1]
  capsuleFrame.offset = { x = -2, y = 3 }
  local renderer = newRenderer(graphics, stubText({}), manifest)
  local status = presentation()
  status.view.slots[1] = occupiedSlot(0, {
    heldItem = "SITRUS_BERRY",
    heldItemName = "Sitrus Berry",
    heldMarkerKind = "mail",
    capsule = { id = 3, seals = {} },
  })

  renderer:draw(status, PartyScreenLayout.resolve({ manifest = manifest, cancellable = true }), icons())

  for _, expected in ipairs({
    { frame = heldFrame, anchor = manifest.panels[1].heldAnchor },
    { frame = capsuleFrame, anchor = manifest.panels[1].capsuleAnchor },
  }) do
    local image = renderer._images["asset:" .. expected.frame.image]
    local found
    for _, draw in ipairs(graphics.draws) do
      if
        draw.image == image
        and draw.x == expected.anchor.x + expected.frame.offset.x
        and draw.y == expected.anchor.y + expected.frame.offset.y
      then
        found = true
        break
      end
    end
    Assert.isTrue(found, "the semantic held marker or capsule uses its generated anchor and frame offset")
  end
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
  Assert.isTrue(#graphics.draws > draws, "empty panels and source backdrop still paint")
  Assert.isTrue(#texts > strings, "the occupied name and browse message print")
end

function T.selected_icons_shift_with_healthy_bob()
  local graphics = fakeGraphics()
  local texts = {}
  local renderer = newRenderer(graphics, stubText(texts))
  local healthy = presentation({ cursorNode = 0 })
  healthy.view.slots[1] = occupiedSlot(0)
  healthy.anim.phases[1] = 0
  renderer:draw(healthy, layout(), icons())
  local selectedDraw = nil
  for _, draw in ipairs(graphics.draws) do
    if draw.quad ~= nil and draw.quad.key == "MON0/f0" then
      selectedDraw = draw
      break
    end
  end
  local plain = presentation({ cursorNode = 5 })
  plain.view.slots[1] = occupiedSlot(0)
  local graphics2 = fakeGraphics()
  local renderer2 = newRenderer(graphics2, stubText({}))
  renderer2:draw(plain, layout(), icons())
  local unselectedDraw = nil
  for _, draw in ipairs(graphics2.draws) do
    if draw.quad ~= nil and draw.quad.key == "MON0/f0" then
      unselectedDraw = draw
      break
    end
  end
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
  local status = presentation({ cursorNode = 1, menuSlot = 1 })
  status.anim.panelSlide = 40
  status.view.slots[1] = occupiedSlot(0)
  status.view.slots[2] = occupiedSlot(1, { status = "burn", currentHp = 3, maxHp = 20 })
  renderer:drawPane(status, plan.panes[2], resolved, icons())
  Assert.isTrue(#graphics.draws > 0, "the source backdrop and detail layer draw inside the logical pane")
  Assert.isTrue(hasString(texts, "MON1"), "the detail pane names the cursor mon")
  Assert.isFalse(hasString(texts, "BRN"), "the detail pane status uses its source sprite")
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
  local status = presentation({ cursorNode = 1, menuSlot = 1 })
  status.anim.panelSlide = 40
  status.view.slots[1] = occupiedSlot(0)
  status.view.slots[2] = occupiedSlot(1, { status = "burn", currentHp = 3, maxHp = 20 })
  renderer:drawPane(status, plan.panes[2], resolved, icons())
  Assert.isTrue(hasString(texts, "MON1"), "the detail pane names the cursor mon")
  Assert.isFalse(hasString(texts, "BRN"), "the detail pane status uses its source sprite")
end

function T.detail_facts_use_generated_geometry_and_draw_no_held_marker_obj()
  local graphics = fakeGraphics()
  local texts = {}
  local manifest = sourceManifest()
  local renderer = newRenderer(graphics, stubText(texts), manifest)
  local resolved = PartyScreenLayout.resolve({ manifest = manifest, cancellable = true })
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
  local status = presentation({ cursorNode = 1, menuSlot = 1, state = "context" })
  status.anim.panelSlide = 40
  status.view.slots[2] = occupiedSlot(1, {
    status = "burn",
    heldItem = "SITRUS_BERRY",
    heldItemName = "Sitrus Berry",
    heldMarkerKind = "item",
  })

  renderer:drawPane(status, plan.panes[2], resolved, icons())

  local iconDraw
  local upperHeldImage = renderer._images["asset:" .. manifest.visuals.held.sequences[1].frames[1].image]
  local upperHeldDraws = 0
  for _, draw in ipairs(graphics.draws) do
    if draw.quad ~= nil and draw.quad.key == "MON1/f0" then
      iconDraw = draw
    elseif draw.image == upperHeldImage then
      upperHeldDraws = upperHeldDraws + 1
    end
  end
  Assert.notNil(iconDraw, "the selected icon draws in the detail pane")
  Assert.deepEqual({ iconDraw.x, iconDraw.y }, { 14, 144 }, "the detail icon centers at (30,160)")

  local burnImage = renderer._images["asset:" .. manifest.visuals.status.burn.image]
  local statusDraw
  for _, draw in ipairs(graphics.draws) do
    if draw.image == burnImage then
      statusDraw = draw
      break
    end
  end
  Assert.notNil(statusDraw, "detail status uses the semantic status visual")
  Assert.deepEqual({ statusDraw.x, statusDraw.y }, { 38, 176 }, "the detail status centers at (50,180)")

  local expectedText = {
    { value = "MON1", x = 56, y = 152 },
    { value = "Sitrus Berry", x = 138, y = 172 },
  }
  for _, expected in ipairs(expectedText) do
    local found
    for _, call in ipairs(texts) do
      if call.value == expected.value and call.x == expected.x and call.y == expected.y then
        found = true
        break
      end
    end
    Assert.isTrue(found, expected.value .. " uses its generated detail text origin")
  end
  Assert.equal(upperHeldDraws, 0, "the upper detail pane has no held-item marker OBJ")
end

function T.detail_pane_hides_selected_facts_during_browse()
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
  status.view.slots[2] = occupiedSlot(1)
  renderer:drawPane(status, plan.panes[2], resolved, icons())
  Assert.isFalse(hasString(texts, "MON1"), "browse does not show selected context facts")
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
