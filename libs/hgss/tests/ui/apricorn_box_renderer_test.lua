-- Box pane split against the retail screens: the upper display carries the
-- selected description while the lower touchscreen carries the header,
-- stock, cursor, and chrome. Empty rows draw neither a sprite nor a count.

local Assert = require("tests.support.Assert")
local ApricornBoxAssetCache = require("libs.assets.src.ApricornBoxAssetCache")
local ApricornBoxRenderer = require("libs.hgss.src.ui.ApricornBoxRenderer")

local T = { tests = {} }

local function fakeImage()
  local image = {}
  function image:setFilter() end
  function image:getWidth()
    return 64
  end
  function image:getHeight()
    return 64
  end
  return image
end

local function graphics()
  local fake = { draws = {}, colors = {}, texts = {} }
  function fake.newImage()
    return fakeImage()
  end
  function fake.newQuad()
    return {}
  end
  function fake.newShader()
    return {
      send = function() end,
    }
  end
  function fake.getShader()
    return nil
  end
  function fake.setShader() end
  function fake.setColor(...)
    fake.colors[#fake.colors + 1] = { ... }
  end
  function fake.draw(image, x, y)
    -- The suite only exercises quad-less blits, so every draw carries its
    -- resolved image plus placement.
    fake.draws[#fake.draws + 1] = { image = image, x = x, y = y }
  end
  return fake
end

local function fontDef()
  local palette = {}
  for slot = 0, 15 do
    palette[slot + 1] = { r = 0, g = 0, b = 0 }
  end
  palette[16] = { r = 255, g = 255, b = 255 }
  palette[3] = { r = 10, g = 20, b = 30 }
  palette[4] = { r = 40, g = 50, b = 60 }
  palette[6] = { r = 70, g = 80, b = 90 }
  return { palette = palette }
end

local function text()
  local fake = { plain = {}, paletted = {}, fontDef = fontDef() }
  function fake:drawText(content, x, y)
    self.plain[#self.plain + 1] = { text = content, x = x, y = y }
  end
  function fake:drawTextWithPalette(content, x, y, palette)
    self.paletted[#self.paletted + 1] = { text = content, x = x, y = y, palette = palette }
  end
  function fake:textWidth(content)
    return #content * 8
  end
  return fake
end

local function pool()
  local fake = {}
  function fake:request(path)
    return path
  end
  function fake:poll()
    return "ready"
  end
  function fake:acquire(token)
    local image = fakeImage()
    image.path = token
    return { image = image, width = 64, height = 64, token = token }
  end
  function fake:release() end
  return fake
end

local function iconFrame(index)
  return {
    image = ApricornBoxAssetCache.assetDir() .. "/apricorn-" .. index .. ".png",
    width = 32,
    height = 32,
    offsetX = -16,
    offsetY = -16,
    durationTicks = 2,
  }
end

local ROW_CENTERS = { { 27, 49 }, { 75, 65 }, { 27, 81 }, { 75, 97 }, { 27, 113 }, { 75, 129 }, { 27, 145 } }
local COUNT_WINDOWS = { { 5, 6 }, { 11, 8 }, { 5, 10 }, { 11, 12 }, { 5, 14 }, { 11, 16 }, { 5, 18 } }

local function manifest()
  local rows = {}
  for index = 1, 7 do
    local center = ROW_CENTERS[index]
    local window = COUNT_WINDOWS[index]
    rows[index] = {
      apricornKey = "APRICORN_" .. index,
      nameMessageId = index + 6,
      icon = {
        x = center[1],
        y = center[2],
        playMode = "forward_loop",
        frames = { iconFrame(index) },
        totalTicks = 2,
      },
      quantity = {
        window = { x = window[1], y = window[2], width = 2, height = 2 },
        alignment = "center",
        textWidth = 16,
        textHeight = 16,
        color = 2,
      },
    }
  end
  local cursorStates = {}
  for _, sequenceId in ipairs({ 0, 1, 2, 3, 4, 5, 24, 25, 26, 27, 28, 29, 30, 31 }) do
    local edge = sequenceId == 0 and 64 or 32
    cursorStates[sequenceId] = {
      playMode = "forward",
      totalTicks = 1,
      frames = {
        {
          image = ApricornBoxAssetCache.assetDir() .. "/cursor-" .. sequenceId .. ".png",
          width = edge,
          height = 32,
          offsetX = -edge / 2,
          offsetY = -16,
          durationTicks = 1,
        },
      },
    }
  end
  -- Arrow bounces replay across two frames like the source animation.
  for _, sequenceId in ipairs({ 24, 26 }) do
    local states = cursorStates[sequenceId]
    states.frames[#states.frames + 1] = {
      image = ApricornBoxAssetCache.assetDir() .. "/cursor-" .. sequenceId .. "b.png",
      width = 32,
      height = 32,
      offsetX = -16,
      offsetY = -16,
      durationTicks = 10,
    }
    states.totalTicks = 11
  end
  return {
    schema = ApricornBoxAssetCache.SCHEMA,
    upper = { image = ApricornBoxAssetCache.assetDir() .. "/upper-background.png", width = 256, height = 192 },
    lower = { image = ApricornBoxAssetCache.assetDir() .. "/lower-background.png", width = 256, height = 192 },
    actionMenu = { image = ApricornBoxAssetCache.assetDir() .. "/action-menu-tiles.png", width = 216, height = 8 },
    quantityPanel = {
      image = ApricornBoxAssetCache.assetDir() .. "/quantity-panel.png",
      width = 256,
      height = 192,
      offsetX = 0,
      offsetY = 0,
    },
    quantityLayout = {
      name = { x = 72, y = 56 },
      unitsDigit = { x = 98, y = 107 },
      tensDigit = { x = 80, y = 107 },
      extraMessage = { x = 114, y = 112 },
      confirmOk = { x = 136, y = 104, width = 48 },
      confirmClose = { x = 136, y = 128, width = 48 },
      buttonOkSprite = { x = 160, y = 112, sequence = 28, pressedSequence = 29 },
      buttonCloseSprite = { x = 160, y = 136, sequence = 30, pressedSequence = 31 },
      arrows = {
        { x = 103, y = 96, sequence = 24 },
        { x = 103, y = 136, sequence = 26 },
        { x = 81, y = 96, sequence = 24 },
        { x = 81, y = 136, sequence = 26 },
      },
    },
    messageBankId = 21,
    rows = rows,
    headerWindow = { x = 3, y = 1, width = 28, height = 2 },
    titleWindow = { x = 2, y = 21, width = 10, height = 2 },
    closeWindow = { x = 25, y = 21, width = 6, height = 2 },
    closeButton = { x = 224, y = 176 },
    closeInk = {
      foreground = { r = 200, g = 201, b = 202 },
      shadow = { r = 100, g = 101, b = 102 },
    },
    controls = {
      actions = {
        kurtSelect = { x = 17, y = 12, width = 8, windowCount = 2, messageIds = { 5, 6 } },
      },
    },
    selectedDetail = { window = { bg = 7, x = 2, y = 17, width = 28, height = 6 } },
    selectionCursor = {
      image = ApricornBoxAssetCache.assetDir() .. "/selection-cursor.png",
      width = 12,
      height = 12,
      states = cursorStates,
    },
  }
end

local function uiManifest()
  local function row()
    return {
      normal = { asset = "prompt", rect = { x = 0, y = 0, width = 8, height = 8 } },
      selected = { asset = "prompt", rect = { x = 0, y = 0, width = 8, height = 8 } },
    }
  end
  return {
    yesNoPrompt = { shapes = { compact = { yes = row(), no = row() } } },
    assets = { prompt = { image = ApricornBoxAssetCache.assetDir() .. "/prompt.png" } },
  }
end

local function view()
  return {
    mode = "browse",
    phase = "rows",
    rows = {
      { apricornKey = "APRICORN_1", quantity = 3 },
      { apricornKey = "APRICORN_2", quantity = 0 },
      { apricornKey = "APRICORN_3", quantity = 0 },
      { apricornKey = "APRICORN_4", quantity = 2 },
      { apricornKey = "APRICORN_5", quantity = 1 },
      { apricornKey = "APRICORN_6", quantity = 0 },
      { apricornKey = "APRICORN_7", quantity = 0 },
    },
    selectedIndex = 4,
    selectedName = "Grn Apricorn",
    selectedAction = 3,
    actionsEnabled = { false, false, true },
    actionLabels = { [2] = "USE", [3] = "TASTE", [4] = "CANCEL", [5] = "OK", [6] = "CLOSE" },
    headerText = "Collected Apricorns are inside.",
    descriptionText = "Grn Apricorn\nA green Apricorn.\nIt has a mysterious, aromatic scent.",
    titleText = "Apricorn Box",
    closeText = "CLOSE",
    quantity = 1,
    maximum = 2,
    confirmationPrompt = nil,
    cursorSequenceId = 3,
    cursorOffsetY = 0,
    animationTick = 0,
  }
end

local function renderer(textFake)
  local graphicsFake = graphics()
  local instance = ApricornBoxRenderer.new({
    cacheFs = {
      read = function()
        return "bytes"
      end,
    },
    manifest = manifest(),
    text = textFake,
    uiManifest = uiManifest(),
    graphics = graphicsFake,
    imagePool = pool(),
  })
  return instance, graphicsFake
end

local function hasPlain(calls, content, x, y)
  for _, call in ipairs(calls) do
    if call.text == content and call.x == x and call.y == y then
      return true
    end
  end
  return false
end

function T.tests.upper_pane_carries_the_selected_description()
  local textFake = text()
  local instance = renderer(textFake)
  instance:drawPane(view(), { id = "upper" })
  Assert.isTrue(hasPlain(textFake.plain, "Grn Apricorn", 16, 136), "description line one sits at the source window origin")
  Assert.isTrue(hasPlain(textFake.plain, "A green Apricorn.", 16, 152), "description line two advances one text row")
  Assert.isTrue(hasPlain(textFake.plain, "It has a mysterious, aromatic scent.", 16, 168), "description line three fills the window")
  Assert.isFalse(hasPlain(textFake.plain, "Collected Apricorns are inside.", 24, 8), "the header stays on the lower pane")
  for _, call in ipairs(textFake.paletted) do
    Assert.isFalse(call.text == "Apricorn Box", "the title stays on the lower pane")
  end
  instance:release()
end

function T.tests.lower_pane_carries_header_stock_and_chrome_but_skips_empty_rows()
  local textFake = text()
  local instance, graphicsFake = renderer(textFake)
  local status = view()
  instance:drawPane(status, { id = "lower" })
  Assert.isTrue(hasPlain(textFake.plain, "Collected Apricorns are inside.", 24, 8), "the header sits at the source window origin")
  Assert.isFalse(hasPlain(textFake.plain, "Grn Apricorn", 16, 136), "the description stays on the upper pane")
  local title, close = nil, nil
  for _, call in ipairs(textFake.paletted) do
    if call.text == "Apricorn Box" then
      title = call
    elseif call.text == "CLOSE" then
      close = call
    end
  end
  Assert.notNil(title, "the lower pane draws the source title")
  Assert.equal(title.palette.foreground.r, 255, "the chrome ink stays in shader byte range")
  Assert.equal(title.x, 16 + math.floor((80 - #"Apricorn Box" * 8) / 2), "the title centers in its source window")
  Assert.equal(title.y, 168, "the title sits on the lower chrome row")
  Assert.notNil(close, "the lower pane draws the source close label")
  Assert.equal(close.x, 200 + math.floor((48 - #"CLOSE" * 8) / 2), "the close label centers in its source window")
  Assert.equal(close.y, 168, "the close label sits on the lower chrome row")
  Assert.isTrue(hasPlain(textFake.plain, "3", 44, 48), "a stocked row draws its count")
  Assert.isTrue(hasPlain(textFake.plain, "2", 92, 96), "the selected row draws its count")
  for _, call in ipairs(textFake.plain) do
    Assert.isFalse(call.text == "0", "empty rows draw no count")
  end
  Assert.isTrue(#graphicsFake.draws > 0, "the lower pane draws sprites and chrome")
  instance:release()
end

-- Quad-less blits record as { x, y } behind the graphics handle, so the
-- first two entries carry the placement.
local function drawAt(draws, x, y)
  for _, call in ipairs(draws) do
    if call.x == x and call.y == y then
      return true
    end
  end
  return false
end

local function drawnImageAt(draws, x, y)
  for _, call in ipairs(draws) do
    if call.x == x and call.y == y then
      return assert(call.image and call.image.path, "draws resolve their image path")
    end
  end
  return nil
end

function T.tests.quantity_phase_layers_the_panel_digits_buttons_and_arrows()
  local textFake = text()
  local instance, graphicsFake = renderer(textFake)
  local status = view()
  status.phase = "quantity"
  status.quantity = 2
  status.maximum = 6
  status.panelMessage = ""
  status.arrowFlashes = {}
  instance:drawPane(status, { id = "lower" })
  Assert.isTrue(hasPlain(textFake.plain, "Grn Apricorn", 72, 56), "the name prints at its window origin")
  Assert.isTrue(hasPlain(textFake.plain, "2", 98, 107), "the units digit sits in its window")
  -- MAIN_1 carries the panel above the priority-2 stock sprites, so every
  -- dimmed apricorn blit lands before the occluding panel blit.
  local panelIndex, lastSpriteIndex = nil, nil
  for index, call in ipairs(graphicsFake.draws) do
    local path = (call.image and call.image.path) or ""
    if path:find("quantity-panel", 1, true) ~= nil then
      panelIndex = panelIndex or index
    end
    if path:find("box/apricorn-", 1, true) ~= nil then
      lastSpriteIndex = index
    end
  end
  Assert.notNil(panelIndex, "the quantity panel draws")
  Assert.notNil(lastSpriteIndex, "the dimmed stock draws")
  Assert.isTrue(lastSpriteIndex < panelIndex, "stock draws beneath the occluding panel")
  for _, call in ipairs(textFake.plain) do
    Assert.isFalse(call.x == 80 and call.y == 107, "a single digit hides the tens window")
    Assert.isFalse(call.x == 114 and call.y == 112, "the reserved empty line draws nothing")
  end
  status.quantity = 12
  status.maximum = 12
  instance:drawPane(status, { id = "lower" })
  Assert.isTrue(hasPlain(textFake.plain, "1", 80, 107), "large stock prints its tens digit")
  local okLabel, closeLabel = nil, nil
  for _, call in ipairs(textFake.paletted) do
    if call.text == "OK" then
      okLabel = call
    elseif call.text == "CLOSE" then
      closeLabel = call
    end
  end
  Assert.notNil(okLabel, "the quantity panel labels its confirm button")
  Assert.equal(okLabel.x, 136 + math.floor((48 - #"OK" * 8) / 2))
  Assert.equal(okLabel.y, 104)
  Assert.notNil(closeLabel, "the quantity panel labels its cancel button")
  Assert.equal(closeLabel.x, 136 + math.floor((48 - #"CLOSE" * 8) / 2))
  Assert.equal(closeLabel.y, 128)
  Assert.deepEqual(okLabel.palette.shadow, { r = 40, g = 50, b = 60 }, "OK resolves font slot 3")
  Assert.deepEqual(closeLabel.palette.shadow, { r = 70, g = 80, b = 90 }, "CANCEL resolves font slot 5")
  Assert.isTrue(drawAt(graphicsFake.draws, 144, 96), "the confirm sprite anchors its button")
  Assert.isTrue(drawAt(graphicsFake.draws, 144, 120), "the cancel sprite anchors its button")
  Assert.isTrue(drawAt(graphicsFake.draws, 87, 80), "the arrows sit around the digits")
  Assert.isTrue(drawAt(graphicsFake.draws, 65, 120), "the lower arrows sit around the digits")
  local dimmed = false
  for _, color in ipairs(graphicsFake.colors) do
    if color[4] == 0.5 then
      dimmed = true
    end
  end
  Assert.isTrue(dimmed, "the stock replays dimmed over the overlay")
  instance:release()
end

function T.tests.quantity_feedback_replays_pressed_art_bounce_and_dimming()
  local textFake = text()
  local instance, graphicsFake = renderer(textFake)
  local status = view()
  status.phase = "quantity"
  status.quantity = 2
  status.maximum = 6
  status.panelMessage = ""
  status.pressedAction = 1
  status.pressedElapsed = 2
  status.arrowFlashes = { [2] = 5 }
  instance:drawPane(status, { id = "lower" })
  local okPath = drawnImageAt(graphicsFake.draws, 144, 96)
  Assert.isTrue(
    okPath ~= nil and okPath:find("cursor-29", 1, true) ~= nil,
    "the pressed OK button draws its pressed sequence"
  )
  local closePath = drawnImageAt(graphicsFake.draws, 144, 120)
  Assert.isTrue(
    closePath ~= nil and closePath:find("cursor-30", 1, true) ~= nil,
    "the resting CANCEL button keeps its normal sequence"
  )
  local touched = drawnImageAt(graphicsFake.draws, 87, 120)
  Assert.isTrue(
    touched ~= nil and touched:find("cursor-26b", 1, true) ~= nil,
    "the touched arrow advances its bounce"
  )
  local resting = drawnImageAt(graphicsFake.draws, 87, 80)
  Assert.isTrue(
    resting ~= nil and resting:find("cursor-24.png", 1, true) ~= nil,
    "the untouched arrow rests on its first frame"
  )
  instance:release()
  local unfocusedText = text()
  local unfocused, unfocusedGraphics = renderer(unfocusedText)
  local unfocusedStatus = view()
  unfocusedStatus.phase = "quantity"
  unfocusedStatus.quantity = 1
  unfocusedStatus.maximum = 2
  unfocusedStatus.panelMessage = ""
  unfocusedStatus.arrowFlashes = {}
  unfocused:drawPane(unfocusedStatus, { id = "lower" })
  local dimmed = drawnImageAt(unfocusedGraphics.draws, 208, 160)
  Assert.isTrue(dimmed ~= nil and dimmed:find("cursor-2", 1, true) ~= nil, "focused close dims")
  unfocused:release()
end

function T.tests.stock_sprites_center_on_their_slots_and_chrome_sits_on_its_button()
  local textFake = text()
  local instance, graphicsFake = renderer(textFake)
  instance:drawPane(view(), { id = "lower" })
  -- Slot centers carry the OAM anchor while compiled frame offsets already
  -- encode centering, so the draw lands at anchor plus offset.
  Assert.isTrue(drawAt(graphicsFake.draws, 11, 33), "the first sprite centers on its slot")
  Assert.isTrue(drawAt(graphicsFake.draws, 59, 81), "the stocked fourth sprite centers on its slot")
  Assert.isFalse(drawAt(graphicsFake.draws, 59, 49), "the empty second row draws no sprite")
  Assert.isTrue(drawAt(graphicsFake.draws, 192, 160), "the close art centers on its source button")
  Assert.isTrue(drawAt(graphicsFake.draws, 63, 65), "the cursor anchors beside the selected slot")
  instance:release()
end

function T.tests.chrome_labels_use_their_source_inks()
  local textFake = text()
  local instance = renderer(textFake)
  instance:drawPane(view(), { id = "lower" })
  local title, close = nil, nil
  for _, call in ipairs(textFake.paletted) do
    if call.text == "Apricorn Box" then
      title = call
    elseif call.text == "CLOSE" then
      close = call
    end
  end
  Assert.notNil(title, "title draws")
  Assert.notNil(close, "close draws")
  Assert.deepEqual(title.palette.foreground, { r = 255, g = 255, b = 255 }, "title resolves font slot 15")
  Assert.deepEqual(title.palette.shadow, { r = 10, g = 20, b = 30 }, "title resolves font slot 2")
  Assert.deepEqual(close.palette.foreground, { r = 200, g = 201, b = 202 }, "CLOSE resolves the manifest close ink")
  Assert.deepEqual(close.palette.shadow, { r = 100, g = 101, b = 102 }, "CLOSE resolves its manifest shadow")
  instance:release()
end

function T.tests.title_falls_back_to_audited_retail_ink_without_a_font_palette()
  local bare = text()
  bare.fontDef = nil
  local instance = renderer(bare)
  instance:drawPane(view(), { id = "lower" })
  local title = nil
  for _, call in ipairs(bare.paletted) do
    if call.text == "Apricorn Box" then
      title = call
    end
  end
  Assert.notNil(title, "title draws")
  Assert.deepEqual(title.palette.foreground, { r = 255, g = 255, b = 255 }, "fallback title stays white")
  Assert.deepEqual(title.palette.shadow, { r = 173, g = 189, b = 189 }, "fallback shadow matches the retail font slot")
  instance:release()
end

return T
