-- Retail paint contracts for the battle wrapper pages (mon-menu, summary,
-- check-moves): sprites center on their staged anchors (honoring drawable
-- cell offsets), the HP bar fills green through the staged party palette,
-- the experience bar repaints its staged tiles, and disabled faces repaint
-- only genuinely empty slots. The real BattleSubflows projection feeds both
-- painters (paired BattleRenderer.drawPane and compact
-- BattleCompactInterface.render); recording asset/text/graphics stand-ins
-- observe every draw without GPU work.

local Assert = require("tests.support.Assert")
local BattleSubflows = require("game.hgss.src.battle.BattleSubflows")
local FakeGraphics = require("tests.support.FakeGraphics").new
local ItemFixture = require("libs.items.tests.item_fixture")
local PartyPresentationFixture = require("tests.support.PartyPresentationFixture")

local T = {}

local function coordinator(opts)
  local args = { launchId = "launch-painter-unit", itemCatalog = ItemFixture.makeCatalog() }
  if type(opts) == "table" then
    for key, value in pairs(opts) do
      args[key] = value
    end
  end
  if args.battleMenus == nil then
    args.battleMenus = { party = { manifest = PartyPresentationFixture.manifest() } }
  end
  return BattleSubflows.new(args)
end

local function switchOptions(reserve)
  return {
    requestId = 7,
    epoch = 3,
    controller = "player",
    kind = "action",
    actors = {
      {
        combatant = 1,
        activation = 5,
        kind = "action",
        choices = {
          {
            id = "switch:" .. tostring(reserve),
            role = "switch",
            enabled = true,
            reason = "refused",
            display = { combatant = reserve },
            choice = {
              actor = { combatant = 1, activation = 5 },
              kind = "switch",
              payload = { replacement = reserve },
            },
          },
        },
      },
    },
  }
end

local function partyIntent(opts)
  local intent = {
    kind = "party",
    purpose = "switch",
    launchId = "launch-painter-unit",
    requestId = 7,
    epoch = 3,
    controller = "player",
    cancellable = true,
    request = { requestId = 7, epoch = 3, controller = "player", kind = "action" },
    options = switchOptions(2),
    party = {},
    inventory = {},
  }
  for key, value in pairs(opts) do
    intent[key] = value
  end
  return intent
end

local function drive(flows, event)
  flows:update({ event })
  flows:tick()
end

local function settleWrapperPress(flows)
  for _ = 1, 3 do
    flows:tick()
  end
end

local function catalog()
  return {
    species = function(_, _)
      return { types = { "NORMAL", "FLYING" }, growthCurve = "MEDIUM_FAST" }
    end,
    growthCurve = function(_, _)
      return { [20] = 1000, [21] = 1100 }
    end,
  }
end

local function fullMoves()
  return {
    {
      move = "TACKLE",
      name = "Tackle",
      pp = 35,
      maxPp = 35,
      power = 35,
      accuracy = 100,
      category = "physical",
      type = "NORMAL",
      description = "A test tackle.",
    },
    {
      move = "GROWL",
      name = "Growl",
      pp = 40,
      maxPp = 40,
      power = 0,
      accuracy = 100,
      category = "status",
      type = "NORMAL",
      description = "A test growl.",
    },
    {
      move = "SWIFT",
      name = "Swift",
      pp = 20,
      maxPp = 20,
      power = 60,
      accuracy = 0,
      category = "special",
      type = "NORMAL",
      description = "A test swift.",
    },
    {
      move = "REST",
      name = "Rest",
      pp = 10,
      maxPp = 10,
      power = 0,
      accuracy = 0,
      category = "status",
      type = "PSYCHIC",
      description = "A test rest.",
    },
  }
end

local function leadRecord(overrides)
  local record = {
    combatant = 1,
    slot = 0,
    name = "LEAD",
    species = "EEVEE",
    form = 0,
    level = 20,
    hp = 30,
    maxHp = 30,
    experience = 1005,
    nextExp = 95,
    heldItem = "POTION",
    moves = fullMoves(),
  }
  if type(overrides) == "table" then
    for key, value in pairs(overrides) do
      record[key] = value
    end
  end
  return record
end

local function backRecord()
  return { combatant = 2, slot = 1, name = "BACK", level = 5, hp = 10, maxHp = 18 }
end

-- Minimal staged windows behind the painters: summary carries its retail
-- AddWindow geometry (palette included), mon-menu and check-moves carry
-- valid boxes at the indices the transcribed text layout reads.
local function stagedWindows()
  local function box(left, top, width, height, palette)
    return { left = left, top = top, width = width, height = height, palette = palette }
  end
  local summary = {
    box(5, 1, 9, 2, 13),
    box(1, 9, 11, 2, 13),
    box(1, 11, 18, 4, 13),
    box(4, 16, 12, 2, 13),
    box(24, 4, 7, 2, 13),
    box(28, 7, 3, 2, 13),
    box(28, 9, 3, 2, 13),
    box(28, 15, 3, 2, 13),
    box(28, 11, 3, 2, 13),
    box(28, 13, 3, 2, 13),
    box(25, 6, 6, 1, 9),
    box(5, 4, 3, 2, 13),
    box(13, 6, 6, 2, 13),
    box(21, 4, 2, 2, 13),
    box(21, 7, 6, 2, 13),
    box(21, 9, 6, 2, 13),
    box(21, 15, 6, 2, 13),
    box(21, 11, 6, 2, 13),
    box(21, 13, 6, 2, 13),
    box(1, 4, 4, 2, 13),
    box(1, 6, 11, 2, 13),
    box(13, 20, 11, 3, 9),
  }
  local monMenu = {
    box(10, 4, 12, 3, 9),
    box(11, 12, 10, 3, 9),
    box(1, 20, 11, 3, 9),
    box(14, 20, 11, 3, 9),
  }
  local checkMoves = {
    box(5, 1, 9, 2, 13),
    box(1, 6, 14, 5, 9),
    box(17, 6, 14, 5, 9),
    box(1, 12, 14, 5, 9),
    box(17, 12, 14, 5, 9),
    box(13, 20, 11, 3, 9),
  }
  local moveDetail = {}
  for _ = 1, 12 do
    moveDetail[#moveDetail + 1] = box(1, 1, 8, 2, 13)
  end
  return { monMenu = monMenu, summary = summary, checkMoves = checkMoves, moveDetail = moveDetail }
end

-- Staged button rects behind disabled/pressed faces: the decomp tile-unit
-- rects for every button the wrapper pages repaint.
local function stagedButtonRects()
  local rects = {}
  local function at(button, x, y, w, h)
    rects[button + 1] = { x = x, y = y, w = w, h = h }
  end
  at(6, 27, 19, 5, 5)
  at(7, 1, 1, 30, 17)
  at(8, 0, 19, 13, 5)
  at(10, 13, 19, 13, 5)
  at(11, 12, 19, 13, 5)
  at(12, 0, 19, 5, 5)
  at(13, 5, 19, 5, 5)
  at(14, 0, 6, 16, 6)
  at(15, 16, 6, 16, 6)
  at(16, 0, 12, 16, 6)
  at(17, 16, 12, 16, 6)
  at(9, 12, 19, 13, 5)
  return rects
end

local function partySection()
  return { windows = stagedWindows(), buttonRects = stagedButtonRects() }
end

local function openMonMenu(flows, slot)
  Assert.isTrue(
    flows:open(partyIntent({ party = { leadRecord(), backRecord() }, options = switchOptions(2) })),
    "the party opens"
  )
  Assert.isTrue(flows:activateControl("party:" .. tostring(slot)), "the slot takes its tap")
  flows:tick()
  local view = flows:status().childView
  Assert.equal(view.partyPage, "mon_menu", "selecting the slot opens its menu")
  return view
end

local function openSummary(flows, slot)
  openMonMenu(flows, slot)
  drive(flows, { type = "navigate", direction = "down" })
  drive(flows, { type = "confirm" })
  for _ = 1, 8 do
    flows:tick()
  end
  local view = flows:status().childView
  Assert.equal(view.partyPage, "summary", "SUMMARY opens the summary page")
  return view
end

local function openMoves(flows, slot)
  openSummary(flows, slot)
  Assert.isTrue(flows:activateControl("summary:moves"), "the summary moves button takes its tap")
  flows:tick()
  settleWrapperPress(flows)
  local view = flows:status().childView
  Assert.equal(view.partyPage, "moves", "CHECK MOVES opens the move list")
  return view
end

-- Recording asset stand-ins: every drawable lookup is logged, sprites
-- report their native extents and staged cell offsets.
local function fakeAssets(log)
  local sizes = {
    ["battle:icon"] = { width = 32, height = 32 },
    ["battle:move-type-icon"] = { width = 32, height = 16, offset = { x = -16, y = -8 } },
    ["battle:move-category-icon"] = { width = 32, height = 16, offset = { x = -16, y = -8 } },
    ["battle:status-icon"] = { width = 24, height = 8 },
    ["battle:item-icon"] = { width = 24, height = 24 },
    ["battle:cursor"] = { width = 16, height = 16 },
    ["party:button"] = { width = 64, height = 32 },
    ["party:exp"] = { width = 8, height = 8 },
    ["party:page"] = { width = 256, height = 192 },
  }
  local function stub(key, width, height, offset)
    local art = { key = key, width = width, height = height, offset = offset }
    function art:getDimensions()
      return self.width, self.height
    end
    return art
  end
  return {
    drawable = function(_, key)
      log.lookups[#log.lookups + 1] = key
      if key:match("^party:page/") ~= nil then
        local size = sizes["party:page"]
        return stub(key, size.width, size.height)
      end
      local button, frame = key:match("^party:button:(%d+):(%d+)$")
      if button ~= nil then
        local size = sizes["party:button"]
        if button == "12" or button == "13" or button == "6" then
          return stub(key, 40, 40)
        end
        if button == "7" then
          return stub(key, 240, 136)
        end
        if button == "8" or button == "10" or button == "9" or button == "11" then
          return stub(key, 104, 40)
        end
        return stub(key, size.width, size.height)
      end
      local level = key:match("^party:exp:(%d+)$")
      if level ~= nil then
        local size = sizes["party:exp"]
        return stub(key, size.width, size.height)
      end
      local iconKey = key:match("^battle:icon:(.+):frame:(%d+)$")
      if iconKey ~= nil then
        local size = sizes["battle:icon"]
        return stub(key, size.width, size.height)
      end
      local typeKey = key:match("^battle:move%-type%-icon:(.+)$")
      if typeKey ~= nil then
        local size = sizes["battle:move-type-icon"]
        return stub(key, size.width, size.height, size.offset)
      end
      local categoryKey = key:match("^battle:move%-category%-icon:(.+)$")
      if categoryKey ~= nil then
        local size = sizes["battle:move-category-icon"]
        return stub(key, size.width, size.height, size.offset)
      end
      local itemKey = key:match("^battle:item%-icon:(.+)$")
      if itemKey ~= nil then
        local size = sizes["battle:item-icon"]
        return stub(key, size.width, size.height)
      end
      if key:match("^battle:cursor%-") ~= nil then
        local size = sizes["battle:cursor"]
        return stub(key, size.width, size.height)
      end
      return nil
    end,
    renderPictures = function(_, graphics, frame)
      local planes = type(frame) == "table" and frame.planes or {}
      for _, plane in pairs(planes) do
        if type(plane) == "table" and type(plane.draw) == "function" then
          plane.draw()
        end
      end
      return { key = "test-layer" }
    end,
  }
end

local function fakeText(log)
  return {
    drawTextForRole = function(role, content, x, y, palette)
      log.roleText[#log.roleText + 1] = { role = role, content = content, x = x, y = y, palette = palette }
    end,
    measureForRole = function(_, content)
      return { width = #tostring(content) * 8 }
    end,
    drawText = function(content, x, y)
      log.text[#log.text + 1] = { content = content, x = x, y = y }
    end,
    measure = function(content)
      return { width = #tostring(content) * 8 }
    end,
  }
end

-- Staged party palettes with unique colors per slot so assertions name
-- the exact bank and slot behind every fill.
local function fakePartyPalette()
  local colors = {}
  for index = 1, 224 do
    colors[index] = { r = (index * 37) % 256, g = (index * 91) % 256, b = (index * 53) % 256 }
  end
  return { colors = colors }
end

local function slotColor(palette, bank, slot)
  local color = palette.colors[bank * 16 + slot + 1]
  return { color.r / 255, color.g / 255, color.b / 255, 1 }
end

local function freshLogs()
  return { lookups = {}, roleText = {}, text = {} }
end

local function pairedResources(log, graphics)
  return {
    assets = fakeAssets(log),
    graphics = graphics,
    text = fakeText(log),
    windows = {
      drawWindow = function(_, _, _, _)
        log.windowed = (log.windowed or 0) + 1
      end,
    },
    battleMenus = {},
    frameKey = "default",
  }
end

local function pairedView(childView, palette)
  return {
    mode = "child",
    childView = childView,
    textPalettes = { party = palette, narration = palette, menu = palette },
  }
end

local function drawPaired(childView, palette)
  local BattleRenderer = require("game.hgss.src.battle.BattleRenderer")
  local graphics = FakeGraphics()
  local log = freshLogs()
  local view = pairedView(childView, palette or fakePartyPalette())
  BattleRenderer.drawPane(pairedResources(log, graphics), view, "interaction", {}, {})
  return graphics, log
end

local function drawCompact(childView, palette)
  local BattleCompactInterface = require("game.hgss.src.battle.BattleCompactInterface")
  local graphics = FakeGraphics()
  local log = freshLogs()
  local view = {
    mode = "child",
    childView = childView,
    textPalettes = { party = palette or fakePartyPalette() },
    requestId = 0,
  }
  local resources = {
    assets = fakeAssets(log),
    graphics = graphics,
    text = fakeText(log),
    windows = { background = { 0, 0, 0, 1 } },
    battleMenus = {},
    frameKey = "default",
  }
  local plan = {
    content = { child = { kind = childView.kind, focusId = childView.focusId } },
    panes = { { placement = { frame = { x = 0, y = 0, width = 256, height = 192 }, scale = 1 } } },
  }
  BattleCompactInterface.render(resources, view, plan)
  return graphics, log
end

---@param draws table[] recorded FakeGraphics draws
---@param key string drawable key under lookup
---@return table[] draws of that drawable in order
local function drawsOf(draws, key)
  local found = {}
  for _, draw in ipairs(draws) do
    if type(draw.image) == "table" and draw.image.key == key then
      found[#found + 1] = draw
    end
  end
  return found
end

local function assertDrawsCentered(draws, key, anchorX, anchorY, width, height, what)
  local found = drawsOf(draws, key)
  Assert.equal(#found, 1, what .. " draws once")
  Assert.equal(found[1].x, anchorX - math.floor(width / 2), what .. " centers horizontally on its anchor")
  Assert.equal(found[1].y, anchorY - math.floor(height / 2), what .. " centers vertically on its anchor")
end

function T.mon_menu_centers_the_mon_sprite_on_its_anchor()
  for _, painter in ipairs({ "paired", "compact" }) do
    local flows = coordinator({ monCatalog = catalog(), partySection = partySection() })
    local childView = openMonMenu(flows, 0)
    local graphics, log = nil, nil
    if painter == "paired" then
      graphics, log = drawPaired(childView)
    else
      graphics, log = drawCompact(childView)
    end
    local iconKey = nil
    for _, sprite in ipairs(childView.pageSprites) do
      if sprite.kind == "icon" then
        iconKey = "battle:icon:" .. tostring(sprite.key) .. ":frame:1"
      end
    end
    Assert.isTrue(iconKey ~= nil, painter .. " projects the mon-menu icon")
    assertDrawsCentered(graphics.draws, iconKey, 128, 72, 32, 32, painter .. " mon-menu icon")
    flows:dispose()
  end
end

function T.summary_centers_sprites_on_their_retail_anchors()
  for _, painter in ipairs({ "paired", "compact" }) do
    local flows = coordinator({ monCatalog = catalog(), partySection = partySection() })
    local childView = openSummary(flows, 0)
    local graphics, _ = nil, nil
    if painter == "paired" then
      graphics, _ = drawPaired(childView)
    else
      graphics, _ = drawCompact(childView)
    end
    local iconKey, typeKeys = nil, {}
    for _, sprite in ipairs(childView.pageSprites) do
      if sprite.kind == "icon" then
        iconKey = "battle:icon:" .. tostring(sprite.key) .. ":frame:1"
      elseif sprite.kind == "mon-type" then
        typeKeys[#typeKeys + 1] = "battle:move-type-icon:" .. tostring(sprite.key):lower()
      end
    end
    Assert.isTrue(iconKey ~= nil, painter .. " projects the summary icon")
    Assert.equal(#typeKeys, 2, painter .. " projects both mon types")
    assertDrawsCentered(graphics.draws, iconKey, 24, 12, 32, 32, painter .. " summary icon")
    assertDrawsCentered(graphics.draws, typeKeys[1], 130, 16, 32, 16, painter .. " first summary type")
    assertDrawsCentered(graphics.draws, typeKeys[2], 164, 16, 32, 16, painter .. " second summary type")
    flows:dispose()
  end
end

function T.summary_fills_a_normalized_green_hp_bar()
  for _, painter in ipairs({ "paired", "compact" }) do
    local flows = coordinator({ monCatalog = catalog(), partySection = partySection() })
    local childView = openSummary(flows, 0)
    local palette = fakePartyPalette()
    local graphics, _ = nil, nil
    if painter == "paired" then
      graphics, _ = drawPaired(childView, palette)
    else
      graphics, _ = drawCompact(childView, palette)
    end
    -- Window 10 rides tiles (25, 6): the 48-pixel bar at (200, 48).
    local light = slotColor(palette, 9, 2)
    local dark = slotColor(palette, 9, 1)
    local function hasRect(x, y, w, h, color, what)
      for _, rect in ipairs(graphics.rectangles) do
        if
          rect.mode == "fill"
          and rect.x == x
          and rect.y == y
          and rect.w == w
          and rect.h == h
          and rect.color[1] == color[1]
          and rect.color[2] == color[2]
          and rect.color[3] == color[3]
        then
          return true
        end
      end
      Assert.isTrue(false, painter .. " paints " .. what)
      return false
    end
    hasRect(200, 49, 48, 1, light, "the light top bar row")
    hasRect(200, 50, 48, 2, dark, "the dark middle bar rows")
    hasRect(200, 52, 48, 1, light, "the light bottom bar row")
    for _, rect in ipairs(graphics.rectangles) do
      if rect.mode == "fill" and rect.w == 48 and rect.h <= 2 then
        Assert.isTrue(
          rect.color[1] <= 1 and rect.color[2] <= 1 and rect.color[3] <= 1,
          painter .. " normalizes bar ink"
        )
      end
    end
    flows:dispose()
  end
end

function T.summary_repaints_the_staged_experience_tiles()
  for _, painter in ipairs({ "paired", "compact" }) do
    local flows = coordinator({ monCatalog = catalog(), partySection = partySection() })
    local childView = openSummary(flows, 0)
    local graphics, log = nil, nil
    if painter == "paired" then
      graphics, log = drawPaired(childView)
    else
      graphics, log = drawCompact(childView)
    end
    -- 5 earned over a span of 100 fills 3 of 64 pixels: tile level 3
    -- then seven empty tiles across (80, 64).
    local seen = {}
    for _, key in ipairs(log.lookups) do
      local level = key:match("^party:exp:(%d+)$")
      if level ~= nil then
        seen[#seen + 1] = tonumber(level)
      end
    end
    Assert.deepEqual(seen, { 3, 0, 0, 0, 0, 0, 0, 0 }, painter .. " reads the staged exp tiles in track order")
    for column = 0, 7 do
      local level = column == 0 and 3 or 0
      local found = drawsOf(graphics.draws, "party:exp:" .. tostring(level))
      local atColumn = false
      for _, draw in ipairs(found) do
        if draw.x == 80 + column * 8 and draw.y == 64 then
          atColumn = true
        end
      end
      Assert.isTrue(atColumn, painter .. " paints exp tile " .. tostring(column) .. " on the staged track")
    end
    flows:dispose()
  end
end

function T.check_moves_centers_move_type_icons_and_repaints_only_empty_slots()
  for _, painter in ipairs({ "paired", "compact" }) do
    local flows = coordinator({ monCatalog = catalog(), partySection = partySection() })
    local childView = openMoves(flows, 0)
    local graphics, log = nil, nil
    if painter == "paired" then
      graphics, log = drawPaired(childView)
    else
      graphics, log = drawCompact(childView)
    end
    local anchors = { { 24, 80 }, { 152, 80 }, { 24, 128 }, { 152, 128 } }
    local index = 0
    for _, sprite in ipairs(childView.pageSprites) do
      if sprite.kind == "move-type" then
        index = index + 1
        local key = "battle:move-type-icon:" .. tostring(sprite.key):lower()
        local anchor = anchors[index]
        local found = drawsOf(graphics.draws, key)
        local placed = false
        for _, draw in ipairs(found) do
          if draw.x == anchor[1] - 16 and draw.y == anchor[2] - 8 then
            placed = true
          end
        end
        Assert.isTrue(placed, painter .. " centers move type " .. tostring(index) .. " on its anchor")
      end
    end
    Assert.equal(index, 4, painter .. " projects all four move types")
    local disabled = {}
    for _, key in ipairs(log.lookups) do
      local button, frame = key:match("^party:button:(%d+):(%d+)$")
      if button ~= nil and frame == "3" then
        disabled[#disabled + 1] = tonumber(button)
      end
    end
    Assert.deepEqual(disabled, {}, painter .. " repaints no disabled face over occupied move slots")
    flows:dispose()
  end
end

function T.check_moves_repaints_disabled_faces_only_behind_missing_moves()
  for _, painter in ipairs({ "paired", "compact" }) do
    local flows = coordinator({ monCatalog = catalog(), partySection = partySection() })
    local roster = { leadRecord({ moves = { fullMoves()[1] } }), backRecord() }
    Assert.isTrue(flows:open(partyIntent({ party = roster, options = switchOptions(2) })), "the party opens")
    Assert.isTrue(flows:activateControl("party:0"), "the lead takes its tap")
    flows:tick()
    drive(flows, { type = "navigate", direction = "down" })
    drive(flows, { type = "confirm" })
    for _ = 1, 8 do
      flows:tick()
    end
    Assert.isTrue(flows:activateControl("summary:moves"), "the summary moves button takes its tap")
    flows:tick()
    settleWrapperPress(flows)
    local childView = flows:status().childView
    Assert.equal(childView.partyPage, "moves", "CHECK MOVES opens the move list")
    local graphics, log = nil, nil
    if painter == "paired" then
      graphics, log = drawPaired(childView)
    else
      graphics, log = drawCompact(childView)
    end
    local disabled = {}
    for _, key in ipairs(log.lookups) do
      local button, frame = key:match("^party:button:(%d+):(%d+)$")
      if button ~= nil and frame == "3" then
        disabled[#disabled + 1] = tonumber(button)
      end
    end
    table.sort(disabled)
    Assert.deepEqual(disabled, { 15, 16, 17 }, painter .. " repaints disabled faces only behind missing moves")
    flows:dispose()
  end
end

-- The wrapper d-pad cursor frames the focused box with the staged
-- corner pulse: the first animation frame offsets the top-left corner
-- while a focus move restarts the shimmer at zero offset.
function T.wrapper_cursor_shimmers_around_the_focused_box()
  local function cursorView(tick, cursor)
    return {
      kind = "party",
      partyPage = "summary",
      pageCursor = cursor,
      cursorActive = true,
      pageCursorBoxes = { { left = 8, top = 160, right = 32, bottom = 184 } },
      pageSprites = {},
      pageWindows = {},
    }
  end
  local function cornerFrames()
    local frames = {}
    for _, corner in ipairs({ "tl", "tr", "bl", "br" }) do
      frames[corner] = {
        frames = {
          { duration = 4, x = 1, y = 2 },
          { duration = 4, x = -1, y = -2 },
        },
      }
    end
    return frames
  end
  local BattleRenderer = require("game.hgss.src.battle.BattleRenderer")
  local graphics = FakeGraphics()
  local log = freshLogs()
  local view = pairedView(cursorView(0, 0), fakePartyPalette())
  view.wrapperCursorTick = 0
  view.wrapperCursorFrames = cornerFrames()
  BattleRenderer.drawPane(pairedResources(log, graphics), view, "interaction", {}, {})
  local pulsed = nil
  for _, draw in ipairs(graphics.draws) do
    if type(draw.image) == "table" and draw.image.key == "battle:cursor-tl" then
      pulsed = draw
    end
  end
  Assert.notNil(pulsed, "the active cursor draws its top-left corner")
  assert(pulsed ~= nil, "the cursor corner drew")
  Assert.equal(pulsed.x, 8 - 8 + 1, "the shimmer offsets the corner horizontally")
  Assert.equal(pulsed.y, 160 - 8 + 2, "the shimmer offsets the corner vertically")
  local hidden = FakeGraphics()
  local idle = cursorView(0, 0)
  idle.cursorActive = false
  local idleView = pairedView(idle, fakePartyPalette())
  idleView.wrapperCursorTick = 0
  idleView.wrapperCursorFrames = cornerFrames()
  BattleRenderer.drawPane(pairedResources(freshLogs(), hidden), idleView, "interaction", {}, {})
  for _, draw in ipairs(hidden.draws) do
    Assert.isTrue(
      type(draw.image) ~= "table" or draw.image.key ~= "battle:cursor-tl",
      "an inactive cursor draws no corner"
    )
  end
end

return { tests = T }
