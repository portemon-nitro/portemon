-- Native party-screen renderer contracts through the compiled party
-- manifest: chrome panels at source origins, digit/level/slash glyph
-- numerals, status text replacing the level line, egg name-only cards,
-- held and capsule indicators, selected shifts with healthy bob, menu and
-- message windows, and the multi-pane detail pane. Driven through an
-- injected graphics namespace with stub images so no GPU resource is
-- created; the manifest fixture mirrors the compiled source shape.

local Assert = require("tests.support.Assert")
local FieldDialogueFixture = require("tests.support.FieldDialogueFixture")
local PartyPresentationFixture = require("tests.support.PartyPresentationFixture")
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
        gender = { x = origin[1] + 112, y = origin[2] + 8 },
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
  local v3 = PartyPresentationFixture.manifest()
  return {
    panels = panels,
    windows = {
      browse = rect(16, 168, 160, 16),
      context = rect(152, 120, 96, 64),
      action = rect(8, 136, 176, 48),
      prompt = { x = 200, y = 80 },
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
    controls = {
      cancel = {
        anchor = { x = 232, y = 176 },
        label = v3.controls.cancel.label,
        textRect = rect(208, 168, 40, 16),
        align = "center",
      },
    },
    detail = {
      iconAnchor = { x = 30, y = 200 },
      statusAnchor = { x = 50, y = 220 },
      nicknameTextOrigin = { x = 56, y = 192 },
      heldItemTextOrigin = { x = 138, y = 212 },
    },
    iconAnimations = v3.iconAnimations,
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
      height = 8,
      digits = digits,
      level = imageRef("assets/generated/party/level.png", 16, 8),
      slash = imageRef("assets/generated/party/slash.png", 8, 8),
      placement = v3.numberGlyphs.placement,
    },
    text = v3.text,
    contextMenu = v3.contextMenu,
  }
end

-- Source-complete presentation shape the renderer must consume: semantic
-- context text roles selected by generated entry style, source message
-- windows, bank-7 switch-selection chrome, and the generated empty-take
-- template. Values stay synthetic; only the contract shape is under test.
-- The six-entry top-level section carries a field-style entry at index 5,
-- matching the producer rule that entries past the first four resolve the
-- field ink while the fixed cancel entry keeps command ink.
local function v5Manifest()
  local manifest = sourceManifest()
  manifest.schema = "g4-party-presentation-v5"
  manifest.windows = {
    browse = rect(16, 168, 160, 16),
    context = rect(16, 152, 104, 32),
    action = rect(16, 152, 216, 32),
    prompt = { x = 200, y = 80 },
  }
  local function triple(fr, fg, fb, sr, sg, sb, br, bg, bb)
    return {
      foreground = { r = fr, g = fg, b = fb },
      shadow = { r = sr, g = sg, b = sb },
      background = { r = br, g = bg, b = bb },
    }
  end
  local contextMenu = assert(manifest.contextMenu, "the v4 manifest carries context menus")
  contextMenu.textPalette = nil
  contextMenu.fillPalette = nil
  contextMenu.textRoles = {
    command = {
      raised = triple(248, 248, 248, 136, 136, 136, 64, 64, 64),
      depressed = triple(255, 255, 255, 80, 80, 80, 16, 16, 16),
    },
    field = {
      raised = triple(144, 192, 248, 40, 80, 160, 64, 64, 64),
      depressed = triple(160, 208, 255, 32, 64, 144, 16, 16, 16),
    },
    cancel = {
      raised = triple(248, 248, 248, 136, 136, 136, 64, 64, 64),
      depressed = triple(255, 255, 255, 80, 80, 80, 16, 16, 16),
    },
  }
  contextMenu.topLevel[6][5].style = "field"
  for _, panel in ipairs(assert(manifest.panels, "the v4 manifest carries panels")) do
    assert(panel.chrome, "panels carry chrome").switchSelection =
      imageRef("assets/generated/party/panel-switch-selection.png", 128, 48)
  end
  local templates = assert(manifest.text.templates, "the v4 manifest carries templates")
  templates.takeNoItem = {
    segments = {
      { kind = "text", value = "EMPTY" },
      { kind = "lineBreak" },
      { kind = "name" },
      { kind = "text", value = "!" },
    },
  }
  templates.giveTarget = { segments = { { kind = "text", value = "GIVE TARGET" } } }
  templates.moveTarget = { segments = { { kind = "text", value = "MOVE TARGET" } } }
  manifest.text.messageRole = {
    foreground = { r = 250, g = 246, b = 217, a = 255 },
    shadow = { r = 144, g = 128, b = 96, a = 255 },
    background = { r = 48, g = 40, b = 32, a = 255 },
  }
  return manifest
end

local function v5Layout(manifest)
  return PartyScreenLayout.resolve({ manifest = manifest, cancellable = true })
end

local function fakeCacheFs()
  local fonts = FieldDialogueFixture.cacheWithFontId(4)
  return {
    read = function(_, path)
      return fonts:read(path) or "stub-bytes"
    end,
    loadLua = function(_, path)
      return fonts:loadLua(path)
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
    heldItemName = "None",
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
    anim = { tick = 0, sequences = {}, sequenceTicks = {}, panelSlide = 0 },
    view = { revision = 1, slots = {} },
    cancellable = true,
  }
  for index = 1, 6 do
    status.view.slots[index] = slot(index - 1)
    status.anim.sequences[index] = 1
    status.anim.sequenceTicks[index] = 0
  end
  for key, value in pairs(overrides or {}) do
    status[key] = value
  end
  return status
end

local function layout()
  return PartyScreenLayout.resolve({ manifest = v5Manifest(), cancellable = true })
end

local function newRenderer(graphics, texts, manifest)
  return PartyScreenRenderer.new({
    graphics = graphics,
    cacheFs = fakeCacheFs(),
    manifest = manifest or v5Manifest(),
    text = texts,
  })
end

local function recordContextText(renderer, calls)
  local text = renderer._contextText
  local drawText = text.drawTextWithPalette
  text.drawTextWithPalette = function(self, value, x, y, palette)
    calls[#calls + 1] = { kind = "palette", value = value, x = x, y = y, palette = palette }
    drawText(self, value, x, y, palette)
  end
end

-- The borrowed generated-font collaborator: records drawn strings while
-- measuring eight units per glyph, so truncation and alignment stay
-- deterministic without GPU resources.
local function stubText(calls)
  return {
    draws = calls,
    drawText = function(_, value, x, y)
      calls[#calls + 1] = { kind = "plain", value = value, x = x, y = y }
    end,
    drawLine = function(_, tokens, x, y)
      calls[#calls + 1] = { kind = "line", tokens = tokens, x = x, y = y }
    end,
    textWidth = function(_, value)
      return #value * 8
    end,
    drawTextWithPalette = function(_, value, x, y, palette)
      calls[#calls + 1] = { kind = "palette", value = value, x = x, y = y, palette = palette }
    end,
    drawLineWithPalette = function(_, tokens, x, y, palette)
      calls[#calls + 1] = { kind = "paletteLine", tokens = tokens, x = x, y = y, palette = palette }
    end,
    windowBackgroundColor = function(_)
      return { 0, 0, 0, 1 }
    end,
  }
end

function T.cancel_focus_does_not_draw_slot_four_name_as_footer()
  local graphics = fakeGraphics()
  local texts = {}
  local manifest = v5Manifest()
  local renderer = newRenderer(graphics, stubText(texts), manifest)
  local status = presentation({ cursorNode = "cancel" })
  status.view.slots[1] = occupiedSlot(0, { displayName = "LEAD" })
  status.view.slots[5] = occupiedSlot(4, { displayName = "FOUR" })
  local resolved = PartyScreenLayout.resolve({ manifest = manifest, cancellable = true })
  renderer:draw(status, resolved, icons())

  local ownPanel = manifest.panels[5].text.name
  for _, call in ipairs(texts) do
    if call.value == "FOUR" then
      Assert.deepEqual(
        { call.x, call.y },
        { ownPanel.x, ownPanel.y },
        "Cancel focus keeps slot 4's name inside its own panel, never a shared footer"
      )
    end
  end
end

function T.numeric_cursor_and_normal_cancel_use_their_manifest_anchors()
  local graphics = fakeGraphics()
  local manifest = v5Manifest()
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
  local manifest = v5Manifest()
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
  local manifest = v5Manifest()
  local renderer = newRenderer(graphics, stubText(texts), manifest)
  local resolved = PartyScreenLayout.resolve({ manifest = manifest, cancellable = true })
  local window = manifest.windows.browse
  local template = assert(manifest.text.templates.chooseMon, "the manifest carries chooseMon")
  local expected = assert(template.segments[1].value, "chooseMon carries display text")
  for _, focus in ipairs({ 0, "cancel" }) do
    local status = presentation({ cursorNode = focus })
    status.view.slots[1] = occupiedSlot(0, { displayName = "LEAD" })
    status.view.slots[5] = occupiedSlot(4, { displayName = "FOUR" })
    local firstNewCall = #texts + 1
    renderer:draw(status, resolved, icons())

    local messageDraws = 0
    local messageRole = assert(manifest.text.messageRole, "the manifest carries the lower-message role")
    local function normalizedBand(band)
      local out = { r = band.r, g = band.g, b = band.b }
      if band.a ~= nil then
        out.a = band.a > 1 and band.a / 255 or band.a
      end
      return out
    end
    local expectedPalette = {
      foreground = normalizedBand(messageRole.foreground),
      shadow = normalizedBand(messageRole.shadow),
      background = normalizedBand(messageRole.background),
    }
    for index = firstNewCall, #texts do
      local call = texts[index]
      if call.kind == "palette" and call.value == expected and call.x == window.x and call.y == window.y then
        Assert.deepEqual(call.palette, expectedPalette, "browse copy uses the lower-message role")
        messageDraws = messageDraws + 1
      end
    end
    Assert.equal(messageDraws, 1, "the compiled choose-mon template draws inside the browse window")
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
  local manifest = v5Manifest()
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
  local manifest = v5Manifest()
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
  healthy.anim.sequenceTicks[1] = 0
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
    swap = {
      source = 0,
      destination = 1,
      xOffset = 9,
      offsets = { [0] = -72, [1] = 72 },
      directions = { [0] = -1, [1] = 1 },
      exchanged = false,
    },
  })
  status.view.slots[1] = occupiedSlot(0)
  status.view.slots[2] = occupiedSlot(1)
  renderer:draw(status, layout(), icons())
  Assert.isTrue(#graphics.draws > 0, "offset records still draw")
  local mid = presentation({
    state = "swapping",
    swap = {
      source = 0,
      destination = 1,
      xOffset = 16,
      offsets = { [0] = -128, [1] = 128 },
      directions = { [0] = -1, [1] = 1 },
      exchanged = true,
    },
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
  local menuFrames = renderer._manifest.contextMenu.frames.standard
  local frameImages = {}
  for _, frame in pairs(menuFrames) do
    frameImages[renderer._images["asset:" .. frame.image]] = true
  end
  local drawnFrames = 0
  for _, draw in ipairs(graphics.draws) do
    if frameImages[draw.image] then
      drawnFrames = drawnFrames + 1
    end
  end
  Assert.equal(drawnFrames, #menu, "menu labels keep one generated frame per entry")
end

function T.context_menu_fills_only_the_text_window()
  local graphics = fakeGraphics()
  local manifest = v5Manifest()
  local renderer = newRenderer(graphics, stubText({}), manifest)
  local menu = {
    { kind = "summary", label = "SUMMARY" },
    { kind = "switch", label = "SWITCH" },
    { kind = "quit", label = "QUIT" },
  }
  local status = presentation({ state = "context", menu = menu, menuIndex = 2, menuSlot = 0 })
  status.view.slots[1] = occupiedSlot(0)
  renderer:draw(status, layout(), icons())

  local entries = layout().menuLayout("topLevel", #menu)
  for index, entry in ipairs(entries) do
    local textRect = entry.textRect
    local frameRect = entry.frameRect
    local fill
    for _, rectangle in ipairs(graphics.rectangles) do
      if
        rectangle.mode == "fill"
        and rectangle.x == textRect.x
        and rectangle.y == textRect.y
        and rectangle.w == textRect.width
        and rectangle.h == textRect.height
      then
        fill = rectangle
      end
      Assert.isFalse(
        rectangle.mode == "fill"
          and rectangle.x == frameRect.x
          and rectangle.y == frameRect.y
          and rectangle.w == frameRect.width
          and rectangle.h == frameRect.height,
        "menu fills never cover the outer frame rectangle"
      )
    end
    Assert.isTrue(fill ~= nil, "each menu button fill matches its text window")
  end
end

function T.target_and_swap_states_draw_their_source_lower_prompts()
  local manifest = v5Manifest()
  local expected = {
    { state = "choosing_item_target", prompt = "GIVE TARGET" },
    { state = "choose_swap", prompt = "MOVE TARGET" },
    { state = "swapping", prompt = "MOVE TARGET" },
  }
  for _, case in ipairs(expected) do
    local graphics = fakeGraphics()
    local texts = {}
    local renderer = newRenderer(graphics, stubText(texts), manifest)
    local status = presentation({ state = case.state })
    status.swap = case.state == "swapping" and {
      source = 0,
      destination = 1,
      xOffset = 4,
      offsets = { [0] = -32, [1] = 32 },
      directions = { [0] = -1, [1] = 1 },
      exchanged = false,
    } or nil
    renderer:draw(status, v5Layout(manifest), icons())
    Assert.isTrue(hasString(texts, case.prompt), case.state .. " draws its lower-window prompt")
  end
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
  local manifest = v5Manifest()
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

function T.itemless_detail_draws_name_at_generated_origin_without_held_obj()
  local graphics = fakeGraphics()
  local texts = {}
  local manifest = v5Manifest()
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
  status.view.slots[2] = occupiedSlot(1)

  renderer:drawPane(status, plan.panes[2], resolved, icons())

  local detail = manifest.detail
  local expected = {
    value = "None",
    x = detail.heldItemTextOrigin.x,
    y = detail.heldItemTextOrigin.y - 40,
  }
  local found
  for _, call in ipairs(texts) do
    if call.value == expected.value and call.x == expected.x and call.y == expected.y then
      found = true
      break
    end
  end
  Assert.isTrue(found, "itemless display name uses the generated detail origin and slide")

  local heldImages = {}
  for sequenceIndex = 1, 2 do
    local path = manifest.visuals.held.sequences[sequenceIndex].frames[1].image
    heldImages[renderer._images["asset:" .. path]] = true
  end
  local heldDraws = 0
  for _, draw in ipairs(graphics.draws) do
    if heldImages[draw.image] then
      heldDraws = heldDraws + 1
    end
  end
  Assert.equal(heldDraws, 0, "itemless detail draws no held-item or mail marker OBJ")
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

-- Native rendering through the compiled-shape manifest: exact icon
-- timeline frames with per-frame translation and frame-gated selected
-- bob, palette-role text with gender marks, fixed numeric fields,
-- source pass ordering, generated context buttons with press phases,
-- native message windows, generated Cancel labeling, and no synthetic
-- info pixels.
-- Borrowed window-decoration double: records every framed-window request
-- so tests can prove lower messages route through shared composition
-- with caller-supplied geometry instead of manual fills.
local function recordingWindow(calls)
  return {
    draws = calls,
    drawWindow = function(_, box, frameIndex, background)
      calls[#calls + 1] = { box = box, frameIndex = frameIndex, background = background }
    end,
  }
end

-- Graphics proxy that preserves every FakeGraphics record while adding one
-- unified call sequence across rectangle fills and image draws, so tests
-- can pin layer order (brightening between content and menu layers).
local function sequenceGraphics()
  local base = fakeGraphics()
  local proxy = { sequence = {}, base = base }
  for key, value in pairs(base) do
    proxy[key] = value
  end
  function proxy.rectangle(mode, x, y, width, height, rx, ry)
    base.rectangle(mode, x, y, width, height, rx, ry)
    proxy.sequence[#proxy.sequence + 1] = { kind = "rectangle", index = #base.rectangles }
  end
  function proxy.draw(image, quad, x, y, rotation, sx, sy)
    base.draw(image, quad, x, y, rotation, sx, sy)
    proxy.sequence[#proxy.sequence + 1] = { kind = "draw", index = #base.draws }
  end
  return proxy
end

-- A translucent white fill is the brightening step composited over already
-- rendered content; opaque flats and fully transparent clears are not.
local function isBrighteningFill(record)
  local color = record.color
  return record.mode == "fill"
    and type(color) == "table"
    and color[1] >= 0.85
    and color[2] >= 0.85
    and color[3] >= 0.85
    and color[4] ~= nil
    and color[4] > 0
    and color[4] < 1
end

local function rectCovers(record, x, y)
  local width = record.width or record.w
  local height = record.height or record.h
  return x >= record.x and x < record.x + width and y >= record.y and y < record.y + height
end

-- Palette-aware font double: records plain and palette draws separately
-- so tests can tell source-role drawing from synthetic color drawing.
local function paletteText(calls)
  return {
    draws = calls,
    drawText = function(_, value, x, y)
      calls[#calls + 1] = { kind = "plain", value = value, x = x, y = y }
    end,
    drawLine = function(_, tokens, x, y)
      calls[#calls + 1] = { kind = "line", tokens = tokens, x = x, y = y }
    end,
    textWidth = function(_, value)
      return #value * 8
    end,
    drawTextWithPalette = function(_, value, x, y, palette)
      calls[#calls + 1] = { kind = "palette", value = value, x = x, y = y, palette = palette }
    end,
    drawLineWithPalette = function(_, tokens, x, y, palette)
      calls[#calls + 1] = { kind = "paletteLine", tokens = tokens, x = x, y = y, palette = palette }
    end,
    windowBackgroundColor = function(_)
      return { 0, 0, 0, 1 }
    end,
  }
end

local function frameIcons(calls)
  return {
    image = function()
      return "atlas"
    end,
    quadFor = function(_, key, frameIndex)
      calls[#calls + 1] = { key = key, frameIndex = frameIndex }
      return { key = key, frameIndex = frameIndex }
    end,
    dimensions = function(_)
      return { width = 32, height = 32 }
    end,
  }
end

local function contextStatus(overrides)
  local status = presentation({
    state = "context",
    menu = {
      { kind = "summary", label = "SUMMARY" },
      { kind = "switch", label = "SWITCH" },
      { kind = "quit", label = "QUIT" },
    },
    menuIndex = 1,
    menuSlot = 0,
    cursorNode = 5,
  })
  for key, value in pairs(overrides or {}) do
    status[key] = value
  end
  return status
end

local function iconDrawsFor(graphics, key)
  local out = {}
  for _, draw in ipairs(graphics.draws) do
    if draw.quad ~= nil and draw.quad.key == key then
      out[#out + 1] = draw
    end
  end
  return out
end

function T.icon_frames_resolve_from_the_generated_timeline_with_source_translation()
  local manifest = v5Manifest()
  local graphics = fakeGraphics()
  local iconCalls = {}
  local renderer = newRenderer(graphics, paletteText({}), manifest)
  -- Sequence 1 spans eight ticks: frame 1 for ticks 0..3, frame 2 with a
  -- +1 x-shift for ticks 4..7.
  local status = contextStatus({
    anim = { tick = 5, sequences = { 1, 1, 1, 1, 1, 1 }, sequenceTicks = { 5, 0, 0, 0, 0, 0 }, panelSlide = 0 },
  })
  status.view.slots[1] = occupiedSlot(0)
  renderer:draw(status, v5Layout(manifest), frameIcons(iconCalls))
  Assert.equal(#iconCalls, 1, "the visible slot resolves exactly one icon frame")
  Assert.equal(iconCalls[1].frameIndex, 2, "tick 5 of the eight-tick timeline selects atlas frame 2")
  local anchor = manifest.panels[1].iconAnchor
  local draws = iconDrawsFor(graphics, "MON0/f0")
  Assert.equal(#draws, 1)
  Assert.deepEqual(
    { draws[1].x, draws[1].y },
    { anchor.x - 16 + 1, anchor.y - 16 },
    "the unselected icon sits at its anchor plus the frame translation"
  )
end

function T.selected_healthy_bob_follows_the_resolved_frame_not_the_coarse_phase()
  local manifest = v5Manifest()
  local graphics = fakeGraphics()
  local renderer = newRenderer(graphics, paletteText({}), manifest)
  local status = contextStatus({
    cursorNode = 0,
    anim = { tick = 9, sequences = { 1, 1, 1, 1, 1, 1 }, sequenceTicks = { 4, 0, 0, 0, 0, 0 }, panelSlide = 0 },
  })
  status.view.slots[1] = occupiedSlot(0)
  renderer:draw(status, v5Layout(manifest), frameIcons({}))
  local anchor = manifest.panels[1].iconAnchor
  local draws = iconDrawsFor(graphics, "MON0/f0")
  Assert.equal(#draws, 1)
  Assert.deepEqual(
    { draws[1].x, draws[1].y },
    { anchor.x - 16 + 2 + 1, anchor.y - 16 + 2 + 1 },
    "frame 2 of a selected healthy icon shifts from the selected base by the source +1 bob"
  )
end

function T.status_sequences_draw_without_healthy_bob()
  local manifest = v5Manifest()
  local graphics = fakeGraphics()
  local iconCalls = {}
  local renderer = newRenderer(graphics, paletteText({}), manifest)
  local status = contextStatus({
    cursorNode = 0,
    anim = { tick = 3, sequences = { 5, 1, 1, 1, 1, 1 }, phases = { 1, 0, 0, 0, 0, 0 }, sequenceTicks = { 3, 0, 0, 0, 0, 0 }, panelSlide = 0 },
  })
  status.view.slots[1] = occupiedSlot(0, { status = "poison", currentHp = 4, maxHp = 20, hpFraction = 0.2 })
  renderer:draw(status, v5Layout(manifest), frameIcons(iconCalls))
  Assert.equal(iconCalls[1].frameIndex, 1, "tick 3 of the status timeline still resolves its own frame")
  local anchor = manifest.panels[1].iconAnchor
  local draws = iconDrawsFor(graphics, "MON0/f0")
  Assert.deepEqual(
    { draws[1].x, draws[1].y },
    { anchor.x - 16 + 2, anchor.y - 16 + 2 },
    "a selected status icon rests at the selected base with no healthy bob"
  )
end

function T.names_draw_full_length_with_the_ordinary_role()
  local manifest = v5Manifest()
  local graphics = fakeGraphics()
  local texts = {}
  local renderer = newRenderer(graphics, paletteText(texts), manifest)
  local status = contextStatus()
  status.view.slots[1] = occupiedSlot(0, { displayName = "ABCDEFGHIJKL" })
  renderer:draw(status, v5Layout(manifest), frameIcons({}))
  local nameRect = manifest.panels[1].text.name
  local full = nil
  for _, call in ipairs(texts) do
    if type(call.value) == "string" and call.value:find("…", 1, true) ~= nil then
      error("names never synthesize an ellipsis", 0)
    end
    if call.kind == "palette" and call.value == "ABCDEFGHIJKL" and call.y == nameRect.y then
      full = call
    end
  end
  Assert.notNil(full, "the overlong name draws in full through the palette path")
  Assert.deepEqual(full.palette, manifest.text.roles.ordinary, "names use the ordinary text role")
  Assert.deepEqual({ full.x, full.y }, { nameRect.x, nameRect.y }, "names start at the name-window origin")
end

function T.gender_marks_draw_at_the_fixed_origin_with_their_role()
  local manifest = v5Manifest()
  local graphics = fakeGraphics()
  local texts = {}
  local renderer = newRenderer(graphics, paletteText(texts), manifest)
  local status = contextStatus()
  status.view.slots[1] = occupiedSlot(0, { genderSymbol = "female" })
  renderer:draw(status, v5Layout(manifest), frameIcons({}))
  local mark = nil
  for _, call in ipairs(texts) do
    if call.kind == "palette" and call.value == manifest.text.labels.female then
      mark = call
    end
  end
  Assert.notNil(mark, "the female symbol draws through the palette path")
  Assert.deepEqual(mark.palette, manifest.text.roles.female, "the female symbol uses the female role")
  local genderOrigin = manifest.panels[1].text.gender
  Assert.deepEqual({ mark.x, mark.y }, { genderOrigin.x, genderOrigin.y }, "the symbol sits at its fixed origin")
end

function T.hp_numerals_use_fixed_source_fields()
  local manifest = v5Manifest()
  local graphics = fakeGraphics()
  local renderer = newRenderer(graphics, paletteText({}), manifest)
  local status = contextStatus()
  status.view.slots[1] = occupiedSlot(0, { level = 7, currentHp = 5, maxHp = 20, hpFraction = 0.25 })
  renderer:draw(status, v5Layout(manifest), frameIcons({}))
  local number = manifest.panels[1].hp.number
  local placement = manifest.numberGlyphs.placement
  local advance = manifest.numberGlyphs.advance
  local function drawFor(image)
    for _, draw in ipairs(graphics.draws) do
      if draw.image == image then
        return draw
      end
    end
    return nil
  end
  local current = assert(drawFor(renderer._images["digit:5"]), "the current value draws its digit")
  Assert.deepEqual(
    { current.x, current.y },
    { number.x + placement.current.x + 2 * advance, number.y + placement.current.y },
    "a one-digit current value right-aligns inside its three-digit field"
  )
  local slash = assert(drawFor(renderer._images.slash), "the slash draws")
  Assert.deepEqual(
    { slash.x, slash.y },
    { number.x + placement.slash.x, number.y + placement.slash.y },
    "the slash keeps its fixed field position"
  )
  local tens = assert(drawFor(renderer._images["digit:2"]), "the max value draws its tens")
  Assert.deepEqual(
    { tens.x, tens.y },
    { number.x + placement.max.x, number.y + placement.max.y },
    "the max value left-aligns at its fixed field position"
  )
end

function T.selected_chrome_paints_under_text_and_sprite_layers()
  local manifest = v5Manifest()
  local graphics = fakeGraphics()
  local texts = {}
  local renderer = newRenderer(graphics, paletteText(texts), manifest)
  local status = contextStatus({ cursorNode = 0 })
  status.view.slots[1] = occupiedSlot(0)
  renderer:draw(status, v5Layout(manifest), frameIcons({}))
  local orderOf = function(image)
    for index, draw in ipairs(graphics.draws) do
      if draw.image == image then
        return index
      end
    end
    return nil
  end
  local chromeImage = renderer._images["asset:" .. manifest.panels[1].chrome.selected.image]
  local ballImage = renderer._images["asset:" .. manifest.visuals.balls.sequences[2].frames[1].image]
  local cursorImage = renderer._images["asset:" .. manifest.visuals.cursor.sequences[1].frames[1].image]
  local chromeAt = assert(orderOf(chromeImage), "the selected chrome draws")
  local ballAt = assert(orderOf(ballImage), "the selected ball draws")
  local cursorAt = assert(orderOf(cursorImage), "the slot cursor draws")
  local iconAt = nil
  for index, draw in ipairs(graphics.draws) do
    if draw.quad ~= nil and draw.quad.key == "MON0/f0" then
      iconAt = index
      break
    end
  end
  Assert.notNil(iconAt, "the icon draws")
  Assert.isTrue(chromeAt < cursorAt, "panel chrome paints before the focus cursor")
  Assert.isTrue(cursorAt < ballAt, "the focus cursor paints under the ball sprite")
  Assert.isTrue(ballAt < iconAt, "the ball paints under the icon")
  local textAt = nil
  for index, call in ipairs(texts) do
    if call.value == "MON0" then
      textAt = index
      break
    end
  end
  Assert.notNil(textAt, "the name draws")
end

function T.context_menu_draws_generated_buttons_without_a_shared_window()
  local manifest = v5Manifest()
  local graphics = fakeGraphics()
  local texts = {}
  local renderer = newRenderer(graphics, paletteText(texts), manifest)
  recordContextText(renderer, texts)
  local status = contextStatus({ menuIndex = 2 })
  status.view.slots[1] = occupiedSlot(0)
  renderer:draw(status, v5Layout(manifest), frameIcons({}))
  local entries = v5Layout(manifest).menuLayout("topLevel", #status.menu)
  for _, entry in ipairs(entries) do
    local textRect = entry.textRect
    local filled = false
    for _, rect in ipairs(graphics.rectangles) do
      if
        rect.mode == "fill"
        and rect.x == textRect.x
        and rect.y == textRect.y
        and rect.w == textRect.width
        and rect.h == textRect.height
      then
        filled = true
        break
      end
    end
    Assert.isTrue(filled, "each menu entry fills only its source text window")
  end
  local raisedImage = renderer._images["asset:" .. manifest.contextMenu.frames.standard.raised.image]
  local selectedImage = renderer._images["asset:" .. manifest.contextMenu.frames.standard.selected.image]
  local raised, selected = 0, 0
  for _, draw in ipairs(graphics.draws) do
    if draw.image == raisedImage then
      raised = raised + 1
    elseif draw.image == selectedImage then
      selected = selected + 1
    end
  end
  Assert.equal(raised, 2, "unfocused entries draw the raised button frame")
  Assert.equal(selected, 1, "the focused entry draws the selected button frame")
  -- Entry ink follows the generated style, never one flat pair: the two
  -- leading entries resolve the command role while the fixed cancel entry
  -- keeps command ink through its own role.
  local roles = assert(manifest.contextMenu.textRoles, "the v4 manifest carries semantic roles")
  local palettes = {}
  for _, call in ipairs(texts) do
    if call.kind == "palette" then
      palettes[call.value] = call.palette
    end
  end
  Assert.deepEqual(palettes.SUMMARY, roles.command.raised, "unfocused command entries use the raised command role")
  Assert.deepEqual(
    palettes.SWITCH,
    roles.command.depressed,
    "the focused command entry uses the depressed command role"
  )
  Assert.deepEqual(palettes.QUIT, roles.cancel.raised, "cancel resolves its own role at the same ink")
  Assert.deepEqual(roles.cancel.raised, roles.command.raised, "cancel keeps command ink")
  for _, call in ipairs(texts) do
    if call.value == "QUIT" then
      local textRect = entries[3].textRect
      Assert.equal(call.y, textRect.y + 4, "context Cancel uses the source font y offset")
      Assert.equal(
        call.x,
        textRect.x + math.floor((textRect.width - renderer._contextText:textWidth("QUIT")) / 2),
        "context Cancel uses integer centering"
      )
    end
  end
end

function T.press_phases_drive_pressed_then_selected_button_frames()
  local manifest = v5Manifest()
  local selectedImage = manifest.contextMenu.frames.standard.selected.image
  local pressedImage = manifest.contextMenu.frames.standard.pressed.image
  local graphics = fakeGraphics()
  local renderer = newRenderer(graphics, paletteText({}), manifest)
  local status = contextStatus({ menuPress = { index = 1, phase = "pressed" } })
  status.view.slots[1] = occupiedSlot(0)
  renderer:draw(status, v5Layout(manifest), frameIcons({}))
  local pressed, selected = 0, 0
  for _, draw in ipairs(graphics.draws) do
    if draw.image == renderer._images["asset:" .. pressedImage] then
      pressed = pressed + 1
    elseif draw.image == renderer._images["asset:" .. selectedImage] then
      selected = selected + 1
    end
  end
  Assert.equal(pressed, 1, "the first press half draws the pressed button frame")
  Assert.equal(selected, 0, "the first press half draws no selected frame")
  local graphics2 = fakeGraphics()
  local renderer2 = newRenderer(graphics2, paletteText({}), manifest)
  local held = contextStatus({ menuPress = { index = 1, phase = "selected" } })
  held.view.slots[1] = occupiedSlot(0)
  renderer2:draw(held, v5Layout(manifest), frameIcons({}))
  local pressed2, selected2 = 0, 0
  for _, draw in ipairs(graphics2.draws) do
    if draw.image == renderer2._images["asset:" .. pressedImage] then
      pressed2 = pressed2 + 1
    elseif draw.image == renderer2._images["asset:" .. selectedImage] then
      selected2 = selected2 + 1
    end
  end
  Assert.equal(pressed2, 0, "the second press half draws no pressed frame")
  Assert.equal(selected2, 1, "the second press half draws the selected button frame")
end

function T.open_context_message_uses_the_context_window()
  local manifest = v5Manifest()
  local graphics = fakeGraphics()
  local texts = {}
  local window = recordingWindow({})
  local renderer = PartyScreenRenderer.new({
    graphics = graphics,
    cacheFs = fakeCacheFs(),
    manifest = manifest,
    text = paletteText(texts),
    window = window,
    frameIndex = 1,
  })
  local status = contextStatus()
  status.view.slots[1] = occupiedSlot(0, { displayName = "LEAD" })
  renderer:draw(status, v5Layout(manifest), frameIcons({}))
  local box = assert(manifest.windows.context, "the v4 manifest carries the context window")
  Assert.equal(#window.draws, 1, "the open-context message composes one shared window")
  Assert.deepEqual(window.draws[1].box, box, "open context explains itself in the context window")
  local named = false
  for _, call in ipairs(texts) do
    local inside = type(call.x) == "number"
      and call.x >= box.x
      and call.x < box.x + box.width
      and type(call.y) == "number"
      and call.y >= box.y
      and call.y < box.y + box.height
    if inside and type(call.value) == "string" and call.value:find("LEAD", 1, true) ~= nil then
      named = true
    end
  end
  Assert.isTrue(named, "the open context names its slot inside the context window")
end

function T.browse_message_paints_through_the_generated_browse_window()
  local manifest = v5Manifest()
  local graphics = fakeGraphics()
  local texts = {}
  local renderer = newRenderer(graphics, paletteText(texts), manifest)
  local status = presentation({ cursorNode = 0 })
  status.view.slots[1] = occupiedSlot(0)
  renderer:draw(status, v5Layout(manifest), frameIcons({}))
  local window = manifest.windows.browse
  local painted = false
  for _, call in ipairs(texts) do
    if
      type(call.x) == "number"
      and call.x >= window.x
      and call.x < window.x + window.width
      and type(call.y) == "number"
      and call.y >= window.y
      and call.y < window.y + window.height
    then
      painted = true
    end
  end
  Assert.isTrue(painted, "the browse message paints inside the generated browse window")
end

function T.content_paints_no_info_pixels()
  local manifest = v5Manifest()
  local resolved = v5Layout(manifest)
  -- The retired host affordance corner: native layout exposes no target
  -- here, so content must paint nothing in this box with or without any
  -- host overlay flag supplied by callers. The context brightening step
  -- spans the full generated backdrop and reaches this corner by contract,
  -- so only that step may touch it.
  local info = { x = 184, y = 172, width = 8, height = 16 }
  local function render(status)
    local graphics = fakeGraphics()
    local texts = {}
    local renderer = newRenderer(graphics, paletteText(texts), manifest)
    renderer:draw(status, resolved, frameIcons({}))
    return graphics, texts
  end
  local status = contextStatus()
  status.view.slots[1] = occupiedSlot(0)
  local graphics, texts = render(status)
  local overlaid = contextStatus({ infoOverlay = true })
  overlaid.view.slots[1] = occupiedSlot(0)
  local graphics2, texts2 = render(overlaid)
  local function touchesInfo(graphicsCalls, textCalls)
    for _, rect in ipairs(graphicsCalls.rectangles) do
      if
        not isBrighteningFill(rect)
        and rect.x < info.x + info.width
        and info.x < rect.x + rect.w
        and rect.y < info.y + info.height
        and info.y < rect.y + rect.h
      then
        return true
      end
    end
    for _, call in ipairs(textCalls) do
      if
        type(call.x) == "number"
        and type(call.y) == "number"
        and call.x >= info.x
        and call.x < info.x + info.width
        and call.y >= info.y
        and call.y < info.y + info.height
      then
        return true
      end
    end
    return false
  end
  Assert.isFalse(touchesInfo(graphics, texts), "browse content paints no host pixels in the retired rect")
  Assert.isFalse(touchesInfo(graphics2, texts2), "a host overlay flag paints no host pixels either")
  Assert.equal(#graphics.draws, #graphics2.draws, "native content ignores the host overlay flag")
end

function T.cancel_uses_the_generated_label_without_a_slot_cursor()
  local manifest = v5Manifest()
  local graphics = fakeGraphics()
  local texts = {}
  local font = paletteText(texts)
  local renderer = newRenderer(graphics, font, manifest)
  local status = contextStatus({ cursorNode = "cancel" })
  status.view.slots[1] = occupiedSlot(0)
  renderer:draw(status, v5Layout(manifest), frameIcons({}))
  local cancel = manifest.controls.cancel
  local labeled = false
  for _, call in ipairs(texts) do
    if call.value == cancel.label then
      labeled = true
      Assert.equal(
        call.x,
        cancel.textRect.x + math.floor((cancel.textRect.width - font:textWidth(call.value)) / 2),
        "the Cancel label is centered integrally in its generated text rectangle"
      )
    end
  end
  Assert.isTrue(labeled, "Cancel draws its generated semantic label")
  local cursorImage = renderer._images["asset:" .. manifest.visuals.cursor.sequences[1].frames[1].image]
  for _, draw in ipairs(graphics.draws) do
    Assert.isTrue(draw.image ~= cursorImage, "Cancel focus draws no slot cursor")
  end
end

function T.context_frame_images_acquire_once_and_release_idempotently()
  local manifest = v5Manifest()
  local graphics = fakeGraphics()
  local renderer = newRenderer(graphics, paletteText({}), manifest)
  local acquired = {}
  for _, shape in ipairs({ "standard", "cancel" }) do
    for _, state in ipairs({ "raised", "selected", "pressed" }) do
      local path = manifest.contextMenu.frames[shape][state].image
      local image = renderer._images["asset:" .. path]
      Assert.notNil(image, shape .. " " .. state .. " frame resolves once")
      acquired[#acquired + 1] = image
    end
  end
  Assert.equal(#acquired, 6, "both button shapes carry three states")
  renderer:release()
  for _, image in ipairs(acquired) do
    Assert.equal(image.releaseCount, 1, "release publishes every owned image exactly once")
  end
  renderer:release()
  for _, image in ipairs(acquired) do
    Assert.equal(image.releaseCount, 1, "a second release publishes nothing more")
  end
end

function T.acquisition_failure_releases_every_image_acquired_before_it()
  local probe = fakeGraphics()
  local bound = newRenderer(probe, paletteText({}), v5Manifest())
  local total = #probe.images
  Assert.equal(total, 49, "setup binds font 4 plus panel chrome, frames, and glyphs")
  bound:release()
  for _, image in ipairs(probe.images) do
    Assert.equal(image.releaseCount, 1, "setup release publishes every owned image exactly once")
  end
  for _, failCall in ipairs({ 1, total }) do
    local graphics = fakeGraphics({ failOnImageCall = failCall })
    Assert.throws(function()
      PartyScreenRenderer.new({
        graphics = graphics,
        cacheFs = fakeCacheFs(),
        manifest = v5Manifest(),
        text = paletteText({}),
      })
    end, "an acquisition failure unwinds the images acquired before it")
    Assert.equal(#graphics.images, failCall - 1, "only the images before the failure exist")
    for _, image in ipairs(graphics.images) do
      Assert.equal(image.releaseCount, 1, "every acquired image releases exactly once")
    end
  end
end

-- Context presentation consumes the generated semantic roles and confines
-- source brightness below the menu: command entries resolve command ink,
-- later entries resolve field ink, cancel keeps command ink, and a
-- translucent white step covers already-rendered content before the menu
-- button frames draw, never after them. Browse rendering stays silent.
function T.context_menu_uses_semantic_roles_with_brightness_confined_below_the_menu()
  local manifest = v5Manifest()
  local graphics = sequenceGraphics()
  local texts = {}
  local renderer = newRenderer(graphics, paletteText(texts), manifest)
  recordContextText(renderer, texts)
  local resolved = v5Layout(manifest)
  local menu = {
    { kind = "summary", label = "CMD_ONE" },
    { kind = "summary", label = "CMD_TWO" },
    { kind = "summary", label = "CMD_THREE" },
    { kind = "summary", label = "CMD_FOUR" },
    { kind = "field_move", label = "FIELD_FIVE" },
    { kind = "quit", label = "QUIT" },
  }
  local roles = assert(manifest.contextMenu.textRoles, "the v4 manifest carries semantic roles")
  local status = contextStatus({ menu = menu, menuIndex = 5, menuSlot = 0 })
  status.view.slots[1] = occupiedSlot(0)
  renderer:draw(status, resolved, frameIcons({}))
  local palettes = {}
  for _, call in ipairs(texts) do
    if call.kind == "palette" then
      palettes[call.value] = call.palette
    end
  end
  Assert.deepEqual(
    palettes.CMD_ONE,
    roles.command.raised,
    "unfocused command entries use the raised command role"
  )
  Assert.deepEqual(
    palettes.FIELD_FIVE,
    roles.field.depressed,
    "the focused field entry uses the depressed field role"
  )
  Assert.deepEqual(palettes.QUIT, roles.cancel.raised, "cancel keeps command ink through its own role")
  Assert.isTrue(
    roles.command.raised.foreground.r ~= roles.field.raised.foreground.r,
    "command and field ink stay distinct"
  )
  local texts2 = {}
  local renderer2 = newRenderer(sequenceGraphics(), paletteText(texts2), manifest)
  recordContextText(renderer2, texts2)
  local refocused = contextStatus({ menu = menu, menuIndex = 1, menuSlot = 0 })
  refocused.view.slots[1] = occupiedSlot(0)
  renderer2:draw(refocused, resolved, frameIcons({}))
  local palettes2 = {}
  for _, call in ipairs(texts2) do
    if call.kind == "palette" then
      palettes2[call.value] = call.palette
    end
  end
  Assert.deepEqual(
    palettes2.CMD_ONE,
    roles.command.depressed,
    "the focused command entry uses the depressed command role"
  )
  Assert.deepEqual(
    palettes2.FIELD_FIVE,
    roles.field.raised,
    "unfocused field entries use the raised field role"
  )
  local fills = {}
  for _, entry in ipairs(graphics.sequence) do
    if entry.kind == "rectangle" and isBrighteningFill(graphics.base.rectangles[entry.index]) then
      fills[#fills + 1] = entry.index
    end
  end
  Assert.isTrue(#fills >= 1, "opening a context menu brightens the underlying content toward white")
  for _, fillIndex in ipairs(fills) do
    local record = graphics.base.rectangles[fillIndex]
    Assert.isTrue(rectCovers(record, 8, 8), "the brightening step covers content above the menu")
    Assert.isTrue(rectCovers(record, 200, 140), "the brightening step covers content below the menu")
  end
  local frames = manifest.contextMenu.frames.standard
  local frameImages = {}
  for _, state in ipairs({ "raised", "selected", "pressed" }) do
    frameImages[renderer._images["asset:" .. assert(frames[state], "menu frames carry " .. state).image]] = true
  end
  local firstMenuDraw = nil
  for seqIndex, entry in ipairs(graphics.sequence) do
    if entry.kind == "draw" and frameImages[graphics.base.draws[entry.index].image] then
      firstMenuDraw = seqIndex
      break
    end
  end
  Assert.notNil(firstMenuDraw, "menu button frames draw")
  for seqIndex, entry in ipairs(graphics.sequence) do
    if entry.kind == "rectangle" and isBrighteningFill(graphics.base.rectangles[entry.index]) then
      Assert.isTrue(
        seqIndex < firstMenuDraw,
        "brightening stays at the content/context boundary, never over the menu"
      )
    end
  end
  local browseGraphics = sequenceGraphics()
  local browse = presentation({ cursorNode = 0 })
  browse.view.slots[1] = occupiedSlot(0)
  newRenderer(browseGraphics, paletteText({}), manifest):draw(browse, resolved, frameIcons({}))
  for _, entry in ipairs(browseGraphics.sequence) do
    if entry.kind == "rectangle" then
      Assert.isFalse(
        isBrighteningFill(browseGraphics.base.rectangles[entry.index]),
        "closing the menu ceases brightness immediately"
      )
    end
  end
end

-- Context brightness covers the full generated backdrop surface at the
-- content boundary: the translucent white step spans the backdrop
-- dimensions from the origin, reaches the backdrop strip below the slot
-- panels without touching later menu layers, and stays absent in browse.
function T.context_brightness_covers_the_full_generated_backdrop()
  local manifest = v5Manifest()
  local backdrop = assert(manifest.visuals.backdropMain, "the manifest carries the main backdrop")
  local backdropWidth = assert(backdrop.width, "the backdrop carries its width")
  local backdropHeight = assert(backdrop.height, "the backdrop carries its height")
  Assert.isTrue(backdropWidth > 0, "the backdrop width stays positive")
  Assert.isTrue(backdropHeight > 0, "the backdrop height stays positive")
  local panelBottom = 0
  for _, panel in ipairs(assert(manifest.panels, "the manifest carries panels")) do
    local origin = assert(panel.origin, "panels carry origins")
    local size = assert(panel.size, "panels carry sizes")
    panelBottom =
      math.max(panelBottom, assert(origin.y, "origins carry y") + assert(size.height, "sizes carry height"))
  end
  Assert.isTrue(panelBottom < backdropHeight, "the panel union ends above the backdrop edge")
  local resolved = v5Layout(manifest)
  local menu = {
    { kind = "summary", label = "CMD_ONE" },
    { kind = "switch", label = "CMD_TWO" },
    { kind = "quit", label = "QUIT" },
  }
  local entries = assert(resolved.menuLayout("topLevel", #menu), "the layout carries menu records")
  local function insideBox(x, y, box)
    return x >= box.x and x < box.x + box.width and y >= box.y and y < box.y + box.height
  end
  -- Left-margin probe below the panels: left of every lower window and
  -- below every menu frame, so only the backdrop brightening may change it.
  local probeX, probeY = 8, panelBottom + 8
  for _, box in ipairs({ manifest.windows.browse, manifest.windows.context, manifest.windows.action }) do
    Assert.isFalse(insideBox(probeX, probeY, box), "the lower probe stays clear of message windows")
  end
  for _, generated in ipairs(entries) do
    local frameRect = assert(generated.frameRect, "menu entries carry frame rectangles")
    local frameBox = { x = frameRect.x, y = frameRect.y, width = frameRect.width, height = frameRect.height }
    Assert.isFalse(insideBox(probeX, probeY, frameBox), "the lower probe stays clear of menu frames")
  end
  local graphics = sequenceGraphics()
  local renderer = newRenderer(graphics, paletteText({}), manifest)
  local status = contextStatus({ menu = menu, menuIndex = 1, menuSlot = 0 })
  status.view.slots[1] = occupiedSlot(0)
  renderer:draw(status, resolved, frameIcons({}))
  local fills = {}
  for _, entry in ipairs(graphics.sequence) do
    if entry.kind == "rectangle" and isBrighteningFill(graphics.base.rectangles[entry.index]) then
      fills[#fills + 1] = graphics.base.rectangles[entry.index]
    end
  end
  Assert.equal(#fills, 1, "an open menu brightens the content surface exactly once")
  local fill = fills[1]
  Assert.deepEqual(
    { fill.x, fill.y, fill.w, fill.h },
    { 0, 0, backdropWidth, backdropHeight },
    "the brightening step spans the full generated backdrop from the origin"
  )
  Assert.isTrue(rectCovers(fill, probeX, probeY), "the brightening step reaches below the panel union")
  local frames = manifest.contextMenu.frames.standard
  local frameImages = {}
  for _, state in ipairs({ "raised", "selected", "pressed" }) do
    frameImages[renderer._images["asset:" .. assert(frames[state], "menu frames carry " .. state).image]] = true
  end
  local fillSeq, firstMenuDraw = nil, nil
  for seqIndex, entry in ipairs(graphics.sequence) do
    if entry.kind == "rectangle" and isBrighteningFill(graphics.base.rectangles[entry.index]) then
      fillSeq = seqIndex
    elseif entry.kind == "draw" and frameImages[graphics.base.draws[entry.index].image] then
      if firstMenuDraw == nil then
        firstMenuDraw = seqIndex
      end
    end
  end
  Assert.notNil(firstMenuDraw, "menu button frames draw")
  Assert.isTrue(
    fillSeq < firstMenuDraw,
    "brightening stays at the content boundary, never over the menu"
  )
  local browseGraphics = sequenceGraphics()
  local browse = presentation({ cursorNode = 0 })
  browse.view.slots[1] = occupiedSlot(0)
  newRenderer(browseGraphics, paletteText({}), manifest):draw(browse, resolved, frameIcons({}))
  for _, entry in ipairs(browseGraphics.sequence) do
    if entry.kind == "rectangle" then
      Assert.isFalse(
        isBrighteningFill(browseGraphics.base.rectangles[entry.index]),
        "closing the menu ceases brightness immediately"
      )
    end
  end
end

-- Lower messages route through shared composition with source geometry:
-- browse through window 32, the open-context explanation through window
-- 33, transient messages through window 34, each at its window-local
-- origin with no manual fill over the window.
function T.lower_messages_route_through_shared_composition_with_source_windows()
  local manifest = v5Manifest()
  local graphics = fakeGraphics()
  local texts = {}
  local window = recordingWindow({})
  local renderer = PartyScreenRenderer.new({
    graphics = graphics,
    cacheFs = fakeCacheFs(),
    manifest = manifest,
    text = paletteText(texts),
    window = window,
    frameIndex = 1,
  })
  local resolved = v5Layout(manifest)
  local browse = presentation({ cursorNode = 0 })
  browse.view.slots[1] = occupiedSlot(0)
  renderer:draw(browse, resolved, frameIcons({}))
  Assert.equal(#window.draws, 1, "the browse message composes one shared window")
  Assert.deepEqual(window.draws[1].box, manifest.windows.browse, "browse uses source window 32")
  local chooseMon = assert(manifest.text.templates.chooseMon, "the manifest carries chooseMon")
  local chooseText = assert(chooseMon.segments[1].value, "chooseMon carries display text")
  local browseBox = assert(manifest.windows.browse, "the manifest carries the browse window")
  local browseOrigin = false
  for _, call in ipairs(texts) do
    if call.kind == "palette" and call.value == chooseText and call.x == browseBox.x and call.y == browseBox.y then
      browseOrigin = true
    end
  end
  Assert.isTrue(browseOrigin, "browse text starts at the window-local origin")
  local open = contextStatus()
  open.view.slots[1] = occupiedSlot(0, { displayName = "LEAD" })
  renderer:draw(open, resolved, frameIcons({}))
  Assert.equal(#window.draws, 2, "the open-context message composes one shared window")
  Assert.deepEqual(window.draws[2].box, manifest.windows.context, "open context uses source window 33")
  local acted = presentation({ cursorNode = 0, state = "message", message = "SENT ON" })
  acted.view.slots[1] = occupiedSlot(0)
  renderer:draw(acted, resolved, frameIcons({}))
  Assert.equal(#window.draws, 3, "the transient message composes one shared window")
  local actionBox = assert(manifest.windows.action, "the manifest carries the action window")
  Assert.deepEqual(window.draws[3].box, actionBox, "transient messages use source window 34")
  local actionOrigin = false
  for _, call in ipairs(texts) do
    if call.kind == "palette" and call.value == "SENT ON" and call.x == actionBox.x and call.y == actionBox.y then
      actionOrigin = true
    end
  end
  Assert.isTrue(actionOrigin, "transient text starts at the window-local origin")
  for _, record in ipairs(graphics.rectangles) do
    for _, box in ipairs({ browseBox, manifest.windows.context, actionBox }) do
      local same = record.x == box.x and record.y == box.y and record.w == box.width and record.h == box.height
      Assert.isFalse(record.mode == "fill" and same, "lower messages never paint manual fills")
    end
  end
end

-- Lower messages print and fill through the generated lower-message
-- role: browse and transient windows compose the shared window with the
-- role background and palette text, without consulting the field font
-- background. The text-only fallback keeps the same role when no
-- borrowed window is present.
function T.lower_messages_use_the_generated_message_role()
  local manifest = v5Manifest()
  manifest.text.messageRole = {
    foreground = { r = 250, g = 246, b = 217, a = 255 },
    shadow = { r = 144, g = 128, b = 96, a = 255 },
    background = { r = 48, g = 40, b = 32, a = 255 },
  }
  local expected = assert(manifest.text.messageRole, "the manifest carries the lower-message role")
  local graphics = fakeGraphics()
  local texts = {}
  local fieldCalls = 0
  local textDouble = paletteText(texts)
  function textDouble.windowBackgroundColor(_)
    fieldCalls = fieldCalls + 1
    error("lower messages must not read the field window background", 0)
  end
  local window = recordingWindow({})
  local renderer = PartyScreenRenderer.new({
    graphics = graphics,
    cacheFs = fakeCacheFs(),
    manifest = manifest,
    text = textDouble,
    window = window,
    frameIndex = 1,
  })
  local resolved = v5Layout(manifest)
  local function roleMatches(palette, record)
    for _, position in ipairs({ "foreground", "shadow", "background" }) do
      local band = assert(palette[position], "the drawn palette carries " .. position)
      local want = assert(record[position], "the role carries " .. position)
      if band.r ~= want.r or band.g ~= want.g or band.b ~= want.b then
        return false
      end
      if band.a ~= nil and band.a ~= 1 and band.a ~= want.a then
        return false
      end
    end
    return true
  end
  local function backgroundMatches(array, record)
    local function channel(value, byte)
      return value == byte or math.abs(value - byte / 255) < 0.01
    end
    return channel(array[1], record.r) and channel(array[2], record.g) and channel(array[3], record.b)
  end
  local browse = presentation({ cursorNode = 0 })
  browse.view.slots[1] = occupiedSlot(0)
  renderer:draw(browse, resolved, frameIcons({}))
  Assert.equal(fieldCalls, 0, "the browse message never consults the field background")
  Assert.equal(#window.draws, 1, "the browse message composes one shared window")
  Assert.deepEqual(window.draws[1].box, manifest.windows.browse, "browse keeps its source window")
  Assert.isTrue(
    backgroundMatches(window.draws[1].background, expected.background),
    "the browse fill matches the lower-message background"
  )
  local chooseMon = assert(manifest.text.templates.chooseMon, "the manifest carries chooseMon")
  local chooseText = assert(chooseMon.segments[1].value, "chooseMon carries display text")
  local browseBox = assert(manifest.windows.browse, "the manifest carries the browse window")
  local browseRole = false
  for _, call in ipairs(texts) do
    if call.kind == "palette" and call.value == chooseText and call.x == browseBox.x and call.y == browseBox.y then
      browseRole = roleMatches(call.palette, expected)
    end
  end
  Assert.isTrue(browseRole, "browse text prints through the lower-message role")
  local acted = presentation({ cursorNode = 0, state = "message", message = "SENT ON" })
  acted.view.slots[1] = occupiedSlot(0)
  renderer:draw(acted, resolved, frameIcons({}))
  Assert.equal(fieldCalls, 0, "transient messages never consult the field background")
  local actionBox = assert(manifest.windows.action, "the manifest carries the action window")
  Assert.deepEqual(window.draws[#window.draws].box, actionBox, "transient messages keep the action window")
  local actionRole = false
  for _, call in ipairs(texts) do
    if call.kind == "palette" and call.value == "SENT ON" and call.x == actionBox.x and call.y == actionBox.y then
      actionRole = roleMatches(call.palette, expected)
    end
  end
  Assert.isTrue(actionRole, "transient text prints through the lower-message role")
  local fallbackTexts = {}
  local fallbackDouble = paletteText(fallbackTexts)
  function fallbackDouble.windowBackgroundColor(_)
    fieldCalls = fieldCalls + 1
    error("lower messages must not read the field window background", 0)
  end
  local fallback = PartyScreenRenderer.new({
    graphics = fakeGraphics(),
    cacheFs = fakeCacheFs(),
    manifest = manifest,
    text = fallbackDouble,
  })
  local plain = presentation({ cursorNode = 0 })
  plain.view.slots[1] = occupiedSlot(0)
  fallback:draw(plain, resolved, frameIcons({}))
  Assert.equal(fieldCalls, 0, "the text-only fallback never consults the field background")
  local fallbackRole = false
  for _, call in ipairs(fallbackTexts) do
    if call.kind == "palette" and call.value == chooseText and call.x == browseBox.x and call.y == browseBox.y then
      fallbackRole = roleMatches(call.palette, expected)
    end
  end
  Assert.isTrue(fallbackRole, "the fallback prints through the lower-message role")
end

-- Switch selection paints generated bank-7 chrome: the locked source and
-- the current candidate resolve switchSelection even when fainted, while
-- uninvolved slots keep their normal and fainted chrome.
function T.switch_selection_uses_generated_bank_seven_chrome()
  local manifest = v5Manifest()
  local graphics = fakeGraphics()
  local renderer = newRenderer(graphics, paletteText({}), manifest)
  local switchPath = "assets/generated/party/panel-switch-selection.png"
  local switchImage = renderer._images["asset:" .. switchPath]
  Assert.notNil(switchImage, "bank-7 switch-selection chrome acquires")
  local status = presentation({
    cursorNode = 3,
    state = "choose_swap",
    switchSelect = { source = 0, candidate = 3 },
  })
  status.view.slots[1] = occupiedSlot(0, { status = "faint", currentHp = 0, maxHp = 20 })
  status.view.slots[2] = occupiedSlot(1, { status = "faint", currentHp = 0, maxHp = 20 })
  status.view.slots[3] = occupiedSlot(2)
  status.view.slots[4] = occupiedSlot(3)
  renderer:draw(status, v5Layout(manifest), frameIcons({}))
  local function chromeDrawn(image, slot0)
    local panel = manifest.panels[slot0 + 1]
    for _, draw in ipairs(graphics.draws) do
      if draw.image == image and draw.x == panel.origin.x and draw.y == panel.origin.y then
        return true
      end
    end
    return false
  end
  Assert.isTrue(chromeDrawn(switchImage, 0), "the locked source uses switch-selection chrome even fainted")
  Assert.isTrue(chromeDrawn(switchImage, 3), "the current candidate uses switch-selection chrome")
  local faintedImage = renderer._images["asset:" .. manifest.panels[2].chrome.fainted.image]
  Assert.isTrue(chromeDrawn(faintedImage, 1), "uninvolved fainted slots keep fainted chrome")
  Assert.isFalse(
    chromeDrawn(faintedImage, 0),
    "the fainted source never falls back to fainted chrome plus tint"
  )
  local normalImage = renderer._images["asset:" .. manifest.panels[3].chrome.normal.image]
  Assert.isTrue(chromeDrawn(normalImage, 2), "uninvolved healthy slots keep normal chrome")
end

-- Action descriptors resolve generated templates in the action window:
-- the empty-take template expands with its display name, and unknown
-- keys fail instead of defaulting to invented text.
function T.generated_action_descriptors_render_in_the_action_window()
  local manifest = v5Manifest()
  manifest.text.templates.giveHeldItem = {
    segments = {
      { kind = "name" },
      { kind = "text", value = " was given the " },
      { kind = "item" },
      { kind = "text", value = " to hold." },
    },
  }
  manifest.text.templates.switchHeldResult = {
    segments = {
      { kind = "name" },
      { kind = "text", value = " held " },
      { kind = "item" },
      { kind = "text", value = " for " },
      { kind = "item" },
    },
  }
  local graphics = fakeGraphics()
  local texts = {}
  local window = recordingWindow({})
  local renderer = PartyScreenRenderer.new({
    graphics = graphics,
    cacheFs = fakeCacheFs(),
    manifest = manifest,
    text = paletteText(texts),
    window = window,
    frameIndex = 1,
  })
  local resolved = v5Layout(manifest)
  local status = presentation({
    cursorNode = 0,
    state = "message",
    message = { templateKey = "takeNoItem", displayName = "LEAD" },
  })
  status.view.slots[1] = occupiedSlot(0)
  renderer:draw(status, resolved, frameIcons({}))
  local box = assert(manifest.windows.action, "the manifest carries the action window")
  Assert.equal(#window.draws, 1, "the descriptor composes through the shared window")
  Assert.deepEqual(window.draws[1].box, box, "descriptors render in the action window")
  local function inside(value)
    for _, call in ipairs(texts) do
      if
        call.kind == "palette"
        and call.value == value
        and type(call.x) == "number"
        and call.x >= box.x
        and call.x < box.x + box.width
        and type(call.y) == "number"
        and call.y >= box.y
        and call.y < box.y + box.height
      then
        return true
      end
    end
    return false
  end
  Assert.isTrue(inside("EMPTY"), "the generated template text draws")
  Assert.isTrue(inside("LEAD"), "the display name expands inside the template")
  local give = presentation({
    cursorNode = 0,
    state = "message",
    message = { templateKey = "giveHeldItem", displayName = "LEAD", itemNames = { "GREAT BALL" } },
  })
  give.view.slots[1] = occupiedSlot(0)
  renderer:draw(give, resolved, frameIcons({}))
  Assert.isTrue(inside("GREAT BALL"), "the source item substitution expands in the action window")
  local swap = presentation({
    cursorNode = 0,
    state = "message",
    message = {
      templateKey = "switchHeldResult",
      displayName = "LEAD",
      itemNames = { "CHERI BERRY", "SITRUS BERRY" },
    },
  })
  swap.view.slots[1] = occupiedSlot(0)
  renderer:draw(swap, resolved, frameIcons({}))
  local itemCalls = {}
  for _, call in ipairs(texts) do
    if call.kind == "palette" and (call.value == "CHERI BERRY" or call.value == "SITRUS BERRY") then
      itemCalls[#itemCalls + 1] = call.value
    end
  end
  Assert.deepEqual(itemCalls, { "CHERI BERRY", "SITRUS BERRY" }, "old and new held items expand in source order")
  local missing = presentation({
    cursorNode = 0,
    state = "message",
    message = { templateKey = "switchHeldResult", displayName = "LEAD", itemNames = { "CHERI BERRY" } },
  })
  missing.view.slots[1] = occupiedSlot(0)
  Assert.throws(function()
    renderer:draw(missing, resolved, frameIcons({}))
  end, "each item segment has a matching item name")
  local bad = presentation({ cursorNode = 0, state = "message", message = { templateKey = "noSuchTemplate" } })
  bad.view.slots[1] = occupiedSlot(0)
  local err = Assert.throws(function()
    renderer:draw(bad, resolved, frameIcons({}))
  end, "unknown template keys fail instead of defaulting")
  Assert.isTrue(
    tostring(err):find("noSuchTemplate", 1, true) ~= nil,
    "the failure names the unknown template key"
  )
end

-- The generated empty-take template leads with the acting mon's name:
-- a descriptor carrying that display name expands inside the action
-- window, while a descriptor without it fails instead of drawing a
-- blank name.
function T.leading_name_template_expands_the_supplied_display_name()
  local manifest = v5Manifest()
  manifest.text.templates.takeNoItem = {
    segments = {
      { kind = "name" },
      { kind = "text", value = " is empty." },
    },
  }
  local graphics = fakeGraphics()
  local texts = {}
  local window = recordingWindow({})
  local renderer = PartyScreenRenderer.new({
    graphics = graphics,
    cacheFs = fakeCacheFs(),
    manifest = manifest,
    text = paletteText(texts),
    window = window,
    frameIndex = 1,
  })
  local resolved = v5Layout(manifest)
  local status = presentation({
    cursorNode = 0,
    state = "message",
    message = { templateKey = "takeNoItem", displayName = "LEAD" },
  })
  status.view.slots[1] = occupiedSlot(0)
  renderer:draw(status, resolved, frameIcons({}))
  local box = assert(manifest.windows.action, "the manifest carries the action window")
  Assert.equal(#window.draws, 1, "the leading-name descriptor composes through the shared window")
  local named = false
  for _, call in ipairs(texts) do
    if
      call.kind == "palette"
      and call.value == "LEAD"
      and type(call.x) == "number"
      and call.x >= box.x
      and call.x < box.x + box.width
      and type(call.y) == "number"
      and call.y >= box.y
      and call.y < box.y + box.height
    then
      named = true
    end
  end
  Assert.isTrue(named, "the leading name expands to the supplied display name")
  local nameless = presentation({
    cursorNode = 0,
    state = "message",
    message = { templateKey = "takeNoItem" },
  })
  nameless.view.slots[1] = occupiedSlot(0)
  Assert.throws(function()
    renderer:draw(nameless, resolved, frameIcons({}))
  end, "a leading name without a display name fails instead of drawing blanks")
end

-- Switch motion moves each slot outward from its own column: panel chrome
-- and text rows clip to the home panel rectangle while ball, icon, status,
-- and held markers share the same slide under the viewport. Swap records
-- carry the per-slot contract: an integral tile-step clock plus a
-- direction map keyed by slot.
local function swappingStatus(source, destination, xOffset, exchanged)
  local directions = {}
  directions[source] = (source % 2 == 0) and -1 or 1
  directions[destination] = (destination % 2 == 0) and -1 or 1
  local offsets = {}
  offsets[source] = directions[source] * xOffset * 8
  offsets[destination] = directions[destination] * xOffset * 8
  local status = presentation({
    cursorNode = "cancel",
    state = "swapping",
    swap = {
      source = source,
      destination = destination,
      xOffset = xOffset,
      offsets = offsets,
      directions = directions,
      exchanged = exchanged == true,
    },
  })
  status.view.slots[source + 1] = occupiedSlot(source)
  status.view.slots[destination + 1] = occupiedSlot(destination)
  return status
end

local function chromeDrawX(graphics, image, y)
  for _, draw in ipairs(graphics.draws) do
    if draw.image == image and draw.y == y then
      return draw.x
    end
  end
  return nil
end

local function iconDrawX(graphics, key)
  for _, draw in ipairs(graphics.draws) do
    if draw.quad ~= nil and draw.quad.key == key then
      return draw.x
    end
  end
  return nil
end

local function textDrawX(calls, value)
  for _, call in ipairs(calls) do
    if call.value == value then
      return call.x
    end
  end
  return nil
end

function T.switch_animation_translates_each_column_outward()
  local manifest = v5Manifest()
  local resolved = PartyScreenLayout.resolve({ manifest = manifest, cancellable = true })
  local graphics = fakeGraphics()
  local renderer = newRenderer(graphics, stubText({}), manifest)
  renderer:draw(swappingStatus(0, 1, 4, false), resolved, icons())
  local chromeImage = renderer._images["asset:" .. manifest.panels[1].chrome.normal.image]
  Assert.notNil(chromeImage, "the panel chrome resolves its generated art")
  Assert.equal(
    chromeDrawX(graphics, chromeImage, manifest.panels[1].origin.y),
    manifest.panels[1].origin.x - 32,
    "the even slot exits left by eight units per step"
  )
  Assert.equal(
    chromeDrawX(graphics, chromeImage, manifest.panels[2].origin.y),
    manifest.panels[2].origin.x + 32,
    "the odd slot exits right by eight units per step"
  )
  local sameColumn = fakeGraphics()
  local sameRenderer = newRenderer(sameColumn, stubText({}), manifest)
  sameRenderer:draw(swappingStatus(0, 2, 4, false), resolved, icons())
  local sameChrome = sameRenderer._images["asset:" .. manifest.panels[1].chrome.normal.image]
  Assert.equal(
    chromeDrawX(sameColumn, sameChrome, manifest.panels[1].origin.y),
    manifest.panels[1].origin.x - 32,
    "the even source exits left with its column"
  )
  Assert.equal(
    chromeDrawX(sameColumn, sameChrome, manifest.panels[3].origin.y),
    manifest.panels[3].origin.x - 32,
    "the even destination exits left with its column"
  )
end

function T.switch_animation_moves_slot_text_and_icons_with_their_panels()
  local manifest = v5Manifest()
  local resolved = PartyScreenLayout.resolve({ manifest = manifest, cancellable = true })
  local plainGraphics = fakeGraphics()
  local plainRenderer = newRenderer(plainGraphics, stubText({}), manifest)
  local plain = swappingStatus(0, 1, 4, false)
  plain.swap = nil
  plain.state = "browse"
  plainRenderer:draw(plain, resolved, icons())
  local baseIconX = iconDrawX(plainGraphics, "MON1/f0")
  Assert.notNil(baseIconX, "the baseline draws the odd slot icon")
  local graphics = fakeGraphics()
  local texts = {}
  local renderer = newRenderer(graphics, stubText(texts), manifest)
  renderer:draw(swappingStatus(0, 1, 4, false), resolved, icons())
  local nameRect = manifest.panels[2].text.name
  Assert.equal(
    textDrawX(texts, "MON1"),
    nameRect.x + 32,
    "the odd slot name exits right with its panel"
  )
  local movedIconX = iconDrawX(graphics, "MON1/f0")
  Assert.notNil(movedIconX, "the animation still draws the odd slot icon")
  Assert.equal(movedIconX - baseIconX, 32, "the odd slot icon exits right with its panel")
end

function T.switch_midpoint_presents_exchanged_records_in_home_slots()
  local manifest = v5Manifest()
  local resolved = PartyScreenLayout.resolve({ manifest = manifest, cancellable = true })
  local graphics = fakeGraphics()
  local texts = {}
  local renderer = newRenderer(graphics, stubText(texts), manifest)
  local status = swappingStatus(0, 1, 16, true)
  renderer:draw(status, resolved, icons())
  Assert.equal(
    textDrawX(texts, "MON1"),
    manifest.panels[1].text.name.x - 128,
    "the midpoint shows the exchanged record exiting left with the even column"
  )
  Assert.equal(
    textDrawX(texts, "MON0"),
    manifest.panels[2].text.name.x + 128,
    "the midpoint shows the exchanged record exiting right with the odd column"
  )
  Assert.equal(status.view.slots[1].displayName, "MON0", "the exchange never rewrites the domain view")
  Assert.equal(status.view.slots[2].displayName, "MON1", "the exchange never rewrites the domain view")
end

local function scissorKey(scissor)
  if scissor == nil then
    return "outer"
  end
  return table.concat({ scissor[1], scissor[2], scissor[3], scissor[4] }, ",")
end

local function homeKey(panel)
  local size = assert(panel.size, "panels carry sizes")
  local width = assert(size.width, "sizes carry width")
  local height = assert(size.height, "sizes carry height")
  return table.concat({ panel.origin.x, panel.origin.y, width, height }, ",")
end

function T.switch_moving_panels_clip_while_sprites_travel_free()
  local manifest = v5Manifest()
  local resolved = PartyScreenLayout.resolve({ manifest = manifest, cancellable = true })
  local base = fakeGraphics()
  local imageScissors = {}
  local originalDraw = base.draw
  base.draw = function(image, quad, x, y, rotation, sx, sy)
    local drawQuad, drawX, drawY = quad, x, y
    if type(quad) == "number" then
      drawQuad, drawX, drawY = nil, quad, x
      rotation, sx, sy = y, rotation, sx
    end
    local clipX, clipY, clipW, clipH = base.getScissor()
    local current = nil
    if clipX ~= nil then
      current = { clipX, clipY, clipW, clipH }
    end
    imageScissors[#imageScissors + 1] = { image = image, quad = drawQuad, x = drawX, y = drawY, scissor = current }
    return originalDraw(image, quad, x, y, rotation, sx, sy)
  end
  local textCalls = {}
  local textScissors = {}
  local recordingText = {
    drawText = function(_, value, x, y)
      local clipX, clipY, clipW, clipH = base.getScissor()
      local current = nil
      if clipX ~= nil then
        current = { clipX, clipY, clipW, clipH }
      end
      textCalls[#textCalls + 1] = { value = value, x = x, y = y }
      textScissors[#textScissors + 1] = { value = value, scissor = current }
    end,
    drawLine = function(_, _, _, _)
      error("switch text draws through the palette path", 0)
    end,
    textWidth = function(_, value)
      return #value * 8
    end,
    drawTextWithPalette = function(_, value, x, y, palette)
      local clipX, clipY, clipW, clipH = base.getScissor()
      local current = nil
      if clipX ~= nil then
        current = { clipX, clipY, clipW, clipH }
      end
      textCalls[#textCalls + 1] = { value = value, x = x, y = y, palette = palette }
      textScissors[#textScissors + 1] = { value = value, scissor = current }
    end,
    drawLineWithPalette = function(_, _, _, _, _)
      error("switch text draws one string at a time", 0)
    end,
    windowBackgroundColor = function(_)
      return { 0, 0, 0, 1 }
    end,
  }
  local renderer = PartyScreenRenderer.new({
    graphics = base,
    cacheFs = fakeCacheFs(),
    manifest = manifest,
    text = recordingText,
  })
  local status = presentation({ cursorNode = "cancel", state = "swapping" })
  status.view.slots[1] = occupiedSlot(0, {
    status = "poison",
    currentHp = 7,
    maxHp = 20,
    heldItem = "SITRUS_BERRY",
    heldMarkerKind = "item",
    capsule = { id = 3, seals = {} },
  })
  status.view.slots[2] = occupiedSlot(1, {
    status = "burn",
    currentHp = 11,
    maxHp = 20,
    heldItem = "GRASS_MAIL",
    heldMarkerKind = "mail",
    capsule = { id = 5, seals = {} },
  })
  status.swap = {
    source = 0,
    destination = 1,
    xOffset = 4,
    offsets = { [0] = -32, [1] = 32 },
    directions = { [0] = -1, [1] = 1 },
    exchanged = false,
  }
  renderer:draw(status, resolved, icons())
  local panel0 = manifest.panels[1]
  local panel1 = manifest.panels[2]
  local chrome0 = renderer._images["asset:" .. panel0.chrome.normal.image]
  local chrome1 = renderer._images["asset:" .. panel1.chrome.normal.image]
  local chromeBySlot = { [0] = nil, [1] = nil }
  for _, record in ipairs(imageScissors) do
    if record.image == chrome0 and record.y == panel0.origin.y then
      chromeBySlot[0] = record
    elseif record.image == chrome1 and record.y == panel1.origin.y then
      chromeBySlot[1] = record
    end
  end
  Assert.notNil(chromeBySlot[0], "the even panel chrome draws")
  Assert.notNil(chromeBySlot[1], "the odd panel chrome draws")
  Assert.equal(chromeBySlot[0].x, panel0.origin.x - 32, "the even chrome exits left by the signed offset")
  Assert.equal(chromeBySlot[1].x, panel1.origin.x + 32, "the odd chrome exits right by the signed offset")
  Assert.equal(
    scissorKey(chromeBySlot[0].scissor),
    homeKey(panel0),
    "the even panel chrome draws inside its home panel"
  )
  Assert.equal(
    scissorKey(chromeBySlot[1].scissor),
    homeKey(panel1),
    "the odd panel chrome draws inside its home panel"
  )
  for _, record in ipairs(textScissors) do
    if record.value == "MON0" then
      Assert.equal(scissorKey(record.scissor), homeKey(panel0), "the even name draws inside its home panel")
    elseif record.value == "MON1" then
      Assert.equal(scissorKey(record.scissor), homeKey(panel1), "the odd name draws inside its home panel")
    end
  end
  local panelImages = {}
  for _, zone in ipairs({ "green", "yellow", "red" }) do
    panelImages[renderer._images["asset:" .. manifest.visuals.hpBars[zone].image]] = true
  end
  for digit = 0, 9 do
    panelImages[renderer._images["digit:" .. digit]] = true
  end
  panelImages[renderer._images.slash] = true
  local homeKeys = { [homeKey(panel0)] = true, [homeKey(panel1)] = true }
  local hpDraws = 0
  for _, record in ipairs(imageScissors) do
    if panelImages[record.image] then
      hpDraws = hpDraws + 1
      Assert.isTrue(
        homeKeys[scissorKey(record.scissor)],
        "HP numerals and bars draw inside their home panel"
      )
    end
  end
  Assert.isTrue(hpDraws >= 4, "HP numerals and bars draw through the clipped text pass")
  local ballImage = renderer._images["asset:" .. manifest.visuals.balls.sequences[1].frames[1].image]
  local heldItemImage = renderer._images["asset:" .. manifest.visuals.held.sequences[1].frames[1].image]
  local heldMailImage = renderer._images["asset:" .. manifest.visuals.held.sequences[2].frames[1].image]
  local capsuleImage = renderer._images["asset:" .. manifest.visuals.held.sequences[3].frames[1].image]
  local poisonImage = renderer._images["asset:" .. manifest.visuals.status.poison.image]
  local burnImage = renderer._images["asset:" .. manifest.visuals.status.burn.image]
  local spriteImages = {
    [ballImage] = true,
    [heldItemImage] = true,
    [heldMailImage] = true,
    [capsuleImage] = true,
    [poisonImage] = true,
    [burnImage] = true,
  }
  local spriteDraws = 0
  for _, record in ipairs(imageScissors) do
    if spriteImages[record.image] then
      spriteDraws = spriteDraws + 1
      Assert.isNil(record.scissor, "sprites travel under the outer viewport instead of the home panel")
    end
    if record.quad ~= nil and type(record.quad.key) == "string" then
      spriteDraws = spriteDraws + 1
      Assert.isNil(record.scissor, "icons travel under the outer viewport instead of the home panel")
    end
  end
  Assert.isTrue(spriteDraws >= 8, "ball, icon, status, held, and capsule sprites all draw")
  local ballBySlot = { [0] = nil, [1] = nil }
  for _, record in ipairs(imageScissors) do
    if record.image == ballImage then
      if record.x == panel0.ballAnchor.x - 32 then
        ballBySlot[0] = record
      elseif record.x == panel1.ballAnchor.x + 32 then
        ballBySlot[1] = record
      end
    end
  end
  Assert.notNil(ballBySlot[0], "the even ball shares the signed panel offset")
  Assert.notNil(ballBySlot[1], "the odd ball shares the signed panel offset")
  Assert.isNil(base.getScissor(), "the switch frame restores the prior scissor")
end

function T.switch_clipped_panel_restores_the_prior_scissor_when_its_draw_fails()
  local manifest = v5Manifest()
  local resolved = PartyScreenLayout.resolve({ manifest = manifest, cancellable = true })
  local graphics = fakeGraphics({ scissor = { 1, 2, 3, 4 } })
  local throwingText = stubText({})
  function throwingText.drawTextWithPalette()
    error("injected panel text failure", 0)
  end
  local renderer = newRenderer(graphics, throwingText, manifest)
  Assert.throws(function()
    renderer:draw(swappingStatus(0, 1, 4, false), resolved, icons())
  end, "a failing clipped panel draw still propagates its error")
  local x, y, width, height = graphics.getScissor()
  Assert.deepEqual(
    { x, y, width, height },
    { 1, 2, 3, 4 },
    "the failed clip restores the exact prior scissor"
  )
end

function T.switch_settled_zero_offset_keeps_the_cursor_hidden()
  local manifest = v5Manifest()
  local resolved = PartyScreenLayout.resolve({ manifest = manifest, cancellable = true })
  local graphics = fakeGraphics()
  local renderer = newRenderer(graphics, stubText({}), manifest)
  local status = presentation({ cursorNode = 1, state = "swapping" })
  status.view.slots[1] = occupiedSlot(0)
  status.view.slots[2] = occupiedSlot(1)
  status.swap = {
    source = 0,
    destination = 1,
    xOffset = 0,
    offsets = { [0] = 0, [1] = 0 },
    directions = { [0] = -1, [1] = 1 },
    exchanged = true,
  }
  renderer:draw(status, resolved, icons())
  local cursorImage = renderer._images["asset:" .. manifest.visuals.cursor.sequences[1].frames[1].image]
  for _, draw in ipairs(graphics.draws) do
    Assert.isTrue(draw.image ~= cursorImage, "the cursor stays hidden while the swap record survives")
  end
end

return { tests = T }
