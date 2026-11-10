-- Mart painting contracts against the source windows: the upper
-- description prints with no dialogue frame, and the quantity panel prints
-- its digits, owned readout, and total through the stock palette.

local Assert = require("tests.support.Assert")
local MartFixture = require("tests.support.MartFixture")
local MartRenderer = require("libs.hgss.src.ui.MartRenderer")

local T = {}

local function copy(value)
  if type(value) ~= "table" then
    return value
  end
  local result = {}
  for key, child in pairs(value) do
    result[key] = copy(child)
  end
  return result
end

local function palette()
  local entries = {}
  for index = 1, 16 do
    entries[index] = { r = index * 11 % 256, g = index * 57 % 256, b = index * 91 % 256 }
  end
  return entries
end

local function text()
  local recorded = {}
  local entries = palette()
  local fake = { recorded = recorded, fontDef = { palette = entries } }
  function fake:drawTextWithPalette(content, x, y, colors)
    recorded[#recorded + 1] = { text = content, x = x, y = y, palette = colors }
  end
  function fake:drawLineWithPalette(tokens, x, y, colors)
    recorded[#recorded + 1] = { tokens = tokens, x = x, y = y, palette = colors }
  end
  function fake:textWidth(content)
    return #content * 8
  end
  function fake:windowBackgroundColor()
    return { 1, 1, 1, 1 }
  end
  return fake
end

local function graphics()
  local fake = { drawn = {} }
  function fake.newImage(_)
    local image = {}
    function image:getDimensions()
      return 8, 8
    end
    function image:getWidth()
      return 8
    end
    function image:getHeight()
      return 8
    end
    function image:setFilter() end
    return image
  end
  function fake.newQuad()
    return {}
  end
  function fake.push() end
  function fake.pop() end
  function fake.origin() end
  function fake.intersectScissor() end
  function fake.translate() end
  function fake.scale() end
  function fake.setColor(...)
    fake.colors[#fake.colors + 1] = { ... }
  end
  fake.colors = {}
  function fake.draw(_, ...)
    fake.drawn[#fake.drawn + 1] = { ... }
  end
  function fake.rectangle(_, ...)
    fake.drawn[#fake.drawn + 1] = { rectangle = true, ... }
  end
  return fake
end

local function cacheFs()
  return {
    read = function(_self, _path)
      return "bytes"
    end,
  }
end

local function window()
  local calls = {}
  local fake = { calls = calls }
  function fake:drawWindow(box, frameIndex, background)
    calls[#calls + 1] = { box = box, frameIndex = frameIndex, background = background }
  end
  return fake
end

local function icons()
  return {
    quadFor = function()
      return {}
    end,
    dimensions = function()
      return { width = 32, height = 32 }
    end,
    handle = function()
      return nil
    end,
    image = function()
      return "atlas"
    end,
  }
end

local function uiManifest()
  local function row()
    return {
      normal = { asset = "prompt-atlas", rect = { x = 0, y = 0, width = 8, height = 8 } },
      selected = { asset = "prompt-atlas", rect = { x = 0, y = 8, width = 8, height = 8 } },
    }
  end
  return {
    assets = { ["prompt-atlas"] = { image = "prompt.png" } },
    yesNoPrompt = {
      shapes = { compact = { yes = row(), no = row() } },
    },
  }
end

local function manifest()
  local manifested = MartFixture.manifest()
  manifested.text.labels.ownedLabel = "In Bag"
  manifested.text.labels.buyLabel = "BUY"
  manifested.text.labels.cancelLabel = "CANCEL"
  return manifested
end

local function lowerPlan()
  return {
    panes = {
      {
        id = "lower",
        placement = {
          origin = { x = 0, y = 0 },
          clipRect = { x = 0, y = 0, width = 256, height = 192 },
          scale = 1,
        },
        interactive = true,
      },
    },
  }
end

local function stockForeground(content)
  return content.fontDef.palette[2]
end

local function systemForeground(content)
  return content.fontDef.palette[16]
end

local function textsWith(content, needle)
  local found = {}
  for _, entry in ipairs(content.recorded) do
    if entry.text == needle then
      found[#found + 1] = entry
    end
  end
  return found
end

function T.upper_description_draws_without_a_dialogue_frame()
  local content = text()
  local framed = window()
  local renderer = MartRenderer.new({
    cacheFs = cacheFs(),
    manifest = manifest(),
    uiManifest = uiManifest(),
    text = content,
    window = framed,
    frameIndex = 0,
    graphics = graphics(),
  })
  local status = {
    open = true,
    state = "browse",
    presentationKind = "items",
    lowerMode = "browse",
    page = 0,
    pageCount = 1,
    selection = 0,
    entryCount = 1,
    entries = {
      { entryIndex = 1 },
      { entryIndex = 2 },
      { entryIndex = 3 },
      { entryIndex = 4 },
      { entryIndex = 5 },
      { entryIndex = 6 },
    },
    currentEntry = {
      displayItemKey = "POTION",
      descriptionText = "Restores HP.",
      bindings = { itemName = "Potion", pocketName = "Medicine" },
    },
    description = "Restores HP.",
    balance = 1000,
    currency = "money",
    quantity = 1,
    maxQuantity = 1,
    messageLines = {},
    prompt = nil,
    controlFeedback = nil,
    amountAnimations = {},
    animationFrame = 0,
    animationRemaining = 0,
  }
  local full = lowerPlan()
  full.panes[#full.panes + 1] = {
    id = "upper",
    placement = {
      origin = { x = 0, y = 0 },
      clipRect = { x = 0, y = 0, width = 256, height = 192 },
      scale = 1,
    },
    interactive = false,
  }
  renderer:draw(status, full, { icons = icons() })
  Assert.equal(#framed.calls, 0, "the upper description prints with no dialogue frame")
  local descriptions = textsWith(content, "Restores HP.")
  Assert.isTrue(#descriptions > 0, "the upper description still prints its text")
  renderer:release()
end

-- The layout pads the opaque strip down to the 8px frame grid: the
-- renderer paints those rows with the per-family strip background blue
-- so the padded two-pane slot shows no transparent air.
function T.upper_strip_pads_down_with_the_background_blue()
  local content = text()
  local framed = window()
  local hostGraphics = graphics()
  local manifested = manifest()
  local renderer = MartRenderer.new({
    cacheFs = cacheFs(),
    manifest = manifested,
    uiManifest = uiManifest(),
    text = content,
    window = framed,
    frameIndex = 0,
    graphics = hostGraphics,
  })
  local function browseStatus(family)
    return {
      open = true,
      state = "browse",
      presentationKind = family,
      lowerMode = "browse",
      page = 0,
      pageCount = 1,
      selection = 0,
      entryCount = 1,
      entries = {
        { entryIndex = 1 },
        { entryIndex = 2 },
        { entryIndex = 3 },
        { entryIndex = 4 },
        { entryIndex = 5 },
        { entryIndex = 6 },
      },
      currentEntry = {
        displayItemKey = "POTION",
        descriptionText = "Restores HP.",
        bindings = { itemName = "Potion", pocketName = "Medicine" },
      },
      description = "Restores HP.",
      balance = 1000,
      currency = "money",
      quantity = 1,
      maxQuantity = 1,
      messageLines = {},
      prompt = nil,
      controlFeedback = nil,
      amountAnimations = {},
      animationFrame = 0,
      animationRemaining = 0,
    }
  end
  local full = lowerPlan()
  full.panes[#full.panes + 1] = {
    id = "upper",
    placement = {
      origin = { x = 0, y = 0 },
      clipRect = { x = 0, y = 0, width = 256, height = 192 },
      scale = 1,
    },
    interactive = false,
  }
  local function fills()
    local found = {}
    for _, call in ipairs(hostGraphics.drawn) do
      if call.rectangle == true then
        found[#found + 1] = call
      end
    end
    return found
  end
  renderer:draw(browseStatus("items"), full, { icons = icons() })
  local pad = assert(fills()[1], "the items strip pads its grid rows")
  Assert.deepEqual({ pad[1], pad[2], pad[3], pad[4] }, { 0, 192, 256, 5 }, "the pad sits below the strip")
  local padColor = assert(manifested.upper.padColor.items, "the fixture carries the items pad shade")
  local painted = false
  for _, color in ipairs(hostGraphics.colors) do
    if
      math.abs(color[1] - padColor.r / 255) < 0.01
      and math.abs(color[2] - padColor.g / 255) < 0.01
      and math.abs(color[3] - padColor.b / 255) < 0.01
    then
      painted = true
    end
  end
  Assert.isTrue(painted, "the pad uses the strip background shade of blue")
  renderer:draw(browseStatus("legacy_decorations"), full, { icons = icons() })
  local legacyPadColor = assert(manifested.upper.padColor.legacy, "the fixture carries the legacy pad shade")
  local legacyPainted = false
  for _, color in ipairs(hostGraphics.colors) do
    if
      math.abs(color[1] - legacyPadColor.r / 255) < 0.01
      and math.abs(color[2] - legacyPadColor.g / 255) < 0.01
      and math.abs(color[3] - legacyPadColor.b / 255) < 0.01
    then
      legacyPainted = true
    end
  end
  Assert.isTrue(legacyPainted, "the legacy strip pads with its own background shade")
  renderer:release()
end

-- The retail message windows fill white and print through the default
-- dark font colors (font 1 defaults fg 1, bg 15, shadow 2), so the
-- printer text uses the stock palette on both message boxes.
function T.message_prints_use_the_stock_palette_on_the_white_fill()
  local content = text()
  local renderer = MartRenderer.new({
    cacheFs = cacheFs(),
    manifest = manifest(),
    uiManifest = uiManifest(),
    text = content,
    window = window(),
    frameIndex = 0,
    graphics = graphics(),
  })
  local glyph = function(character)
    return { kind = "glyph", text = character }
  end
  local status = {
    open = true,
    state = "confirm",
    presentationKind = "items",
    lowerMode = "quantity",
    page = 0,
    pageCount = 1,
    selection = 0,
    entryCount = 1,
    entries = {
      { entryIndex = 1 },
      { entryIndex = 2 },
      { entryIndex = 3 },
      { entryIndex = 4 },
      { entryIndex = 5 },
      { entryIndex = 6 },
    },
    currentEntry = {
      displayItemKey = "POTION",
      descriptionText = "Restores HP.",
      bindings = { itemName = "Potion", pocketName = "Medicine" },
    },
    balance = 1000,
    currency = "money",
    quantity = 1,
    maxQuantity = 99,
    ownedTokens = { glyph("3") },
    totalTokens = { glyph("5") },
    messageRole = "moneyConfirm",
    messageLines = { { tokens = { glyph("F"), glyph("o"), glyph("r") } } },
    prompt = nil,
    controlFeedback = nil,
    amountAnimations = {},
    animationFrame = 0,
    animationRemaining = 0,
  }
  renderer:draw(status, lowerPlan(), { icons = icons() })
  local expected = stockForeground(content)
  local found = 0
  for _, entry in ipairs(content.recorded) do
    if entry.tokens ~= nil then
      found = found + 1
      Assert.deepEqual(entry.palette.foreground, expected, "message lines use the stock palette")
    end
  end
  Assert.isTrue(found > 0, "the confirmation message prints")
  renderer:release()
end

function T.quantity_panel_uses_the_stock_palette()
  local content = text()
  local renderer = MartRenderer.new({
    cacheFs = cacheFs(),
    manifest = manifest(),
    uiManifest = uiManifest(),
    text = content,
    window = window(),
    frameIndex = 0,
    graphics = graphics(),
  })
  local glyph = function(character)
    return { kind = "glyph", text = character }
  end
  local status = {
    open = true,
    state = "quantity",
    presentationKind = "items",
    lowerMode = "quantity",
    page = 0,
    pageCount = 1,
    selection = 0,
    entryCount = 1,
    entries = {
      { entryIndex = 1 },
      { entryIndex = 2 },
      { entryIndex = 3 },
      { entryIndex = 4 },
      { entryIndex = 5 },
      { entryIndex = 6 },
    },
    currentEntry = {
      displayItemKey = "POTION",
      descriptionText = "Restores HP.",
      bindings = { itemName = "Potion", pocketName = "Medicine" },
    },
    balance = 1000,
    currency = "money",
    quantity = 5,
    maxQuantity = 99,
    ownedTokens = { glyph("3") },
    totalTokens = { glyph("5"), glyph("0"), glyph("0") },
    messageLines = {},
    prompt = nil,
    controlFeedback = nil,
    amountAnimations = {},
    animationFrame = 0,
    animationRemaining = 0,
  }
  renderer:draw(status, lowerPlan(), { icons = icons() })
  local expected = stockForeground(content)
  local unexpected = systemForeground(content)
  local digits = textsWith(content, "0")
  Assert.isTrue(#digits > 0, "the quantity digits print")
  for _, entry in ipairs(digits) do
    Assert.deepEqual(entry.palette.foreground, expected, "quantity digits use the stock palette")
    Assert.isFalse(
      entry.palette.foreground.r == unexpected.r
        and entry.palette.foreground.g == unexpected.g
        and entry.palette.foreground.b == unexpected.b,
      "quantity digits avoid the system palette"
    )
  end
  local owned = textsWith(content, "In Bag")
  Assert.isTrue(#owned > 0, "the owned readout prints its label")
  for _, entry in ipairs(owned) do
    Assert.deepEqual(entry.palette.foreground, expected, "the owned label uses the stock palette")
  end
  local totals = 0
  for _, entry in ipairs(content.recorded) do
    if entry.tokens ~= nil then
      totals = totals + 1
      Assert.deepEqual(entry.palette.foreground, expected, "token readouts use the stock palette")
    end
  end
  Assert.isTrue(totals >= 2, "owned and total token readouts print")
  renderer:release()
end

-- The compact single-pane layout reuses the top-screen segment exactly:
-- the opaque strip art blits behind the description with the selected
-- item icon, and the text prints in the upper style at the strip-relative
-- position. The strip flips above the grid for the bottom row; two-pane
-- plans keep the natural upper strip.
local function drawsAt(drawn, x, y)
  -- Fake host draws record dot-call arguments: image, quad, x, y.
  local found = {}
  for _, call in ipairs(drawn) do
    if call[2] == x and call[3] == y then
      found[#found + 1] = call
    end
  end
  return found
end

function T.compact_browse_reuses_the_top_screen_segment()
  local content = text()
  local framed = window()
  local hostGraphics = graphics()
  local renderer = MartRenderer.new({
    cacheFs = cacheFs(),
    manifest = manifest(),
    uiManifest = uiManifest(),
    text = content,
    window = framed,
    frameIndex = 0,
    graphics = hostGraphics,
  })
  local function browseStatus(selection, boxY)
    return {
      open = true,
      state = "browse",
      presentationKind = "items",
      lowerMode = "browse",
      page = 0,
      pageCount = 1,
      selection = selection,
      entryCount = 1,
      entries = {
        { entryIndex = 1 },
        { entryIndex = 2 },
        { entryIndex = 3 },
        { entryIndex = 4 },
        { entryIndex = 5 },
        { entryIndex = 6 },
      },
      currentEntry = {
        displayItemKey = "POTION",
        descriptionText = "Restores HP.",
        bindings = { itemName = "Potion", pocketName = "Medicine" },
      },
      description = "Restores HP.",
      descriptionBox = {
        x = 0,
        y = boxY,
        width = 256,
        height = 51,
        fontId = 0,
        textX = 0,
        textY = 0,
        alignment = "left",
        paletteRole = "foreground",
      },
      balance = 1000,
      currency = "money",
      quantity = 1,
      maxQuantity = 1,
      messageLines = {},
      prompt = nil,
      controlFeedback = nil,
      amountAnimations = {},
      animationFrame = 0,
      animationRemaining = 0,
    }
  end
  renderer:draw(browseStatus(0, 141), lowerPlan(), { icons = icons() })
  Assert.equal(#framed.calls, 0, "the compact description reuses segment art, not a generic window")
  Assert.isTrue(#drawsAt(hostGraphics.drawn, 0, 0) > 0, "the bottom strip blits the source segment at its natural rows")
  Assert.isTrue(
    #drawsAt(hostGraphics.drawn, 6, 156) > 0,
    "the bottom strip carries the selected icon at its source anchor"
  )
  local descriptions = textsWith(content, "Restores HP.")
  Assert.isTrue(#descriptions > 0, "the compact description prints its text")
  for _, entry in ipairs(descriptions) do
    Assert.equal(entry.x, 40, "the compact text keeps the source items text column")
    Assert.equal(entry.y, 144, "the bottom compact text keeps the source text row")
    Assert.deepEqual(
      entry.palette.foreground,
      systemForeground(content),
      "the compact description uses the upper system palette"
    )
  end
  renderer:draw(browseStatus(4, 32), lowerPlan(), { icons = icons() })
  Assert.equal(#framed.calls, 0, "the lifted strip still avoids generic windows")
  Assert.isTrue(
    #drawsAt(hostGraphics.drawn, 0, -109) > 0,
    "the lifted strip relocates the source segment above the grid"
  )
  Assert.isTrue(#drawsAt(hostGraphics.drawn, 6, 47) > 0, "the lifted strip keeps the icon at the relocated anchor")
  -- The text fake accumulates across draws: one bottom row plus the lift.
  local liftedRows = {}
  for _, entry in ipairs(textsWith(content, "Restores HP.")) do
    liftedRows[#liftedRows + 1] = entry.y
  end
  Assert.deepEqual(liftedRows, { 144, 35 }, "the lifted text keeps the strip-relative row")
  local full = lowerPlan()
  full.panes[#full.panes + 1] = {
    id = "upper",
    placement = {
      origin = { x = 0, y = 0 },
      clipRect = { x = 0, y = 0, width = 256, height = 192 },
      scale = 1,
    },
    interactive = false,
  }
  renderer:draw(browseStatus(0, 141), full, { icons = icons() })
  Assert.equal(#framed.calls, 0, "two-pane plans keep the natural upper strip")
  renderer:release()
end

return { tests = T }
