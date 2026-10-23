-- Compact first-import card: modest geometry, same-frame drop receipt, and
-- honest verification/artwork progress. The card surrounds its copy with
-- padding instead of dominating the window, acknowledges a dropped file
-- before validation runs, draws a monotonic verification bar without
-- internal registration jargon, and switches to an indeterminate pending
-- state once verification completes while the walking pair is still pending.

local Assert = require("tests.support.Assert")
local ImportState = require("app.src.launcher.ImportState")

local T = {}

local CARD_MAX_WIDTH = 400
local CARD_MAX_HEIGHT = 200

---@return table scripted importer stand-in reusing the real status vocabulary
local function scriptImporter()
  local importer = { busy = false, drops = {}, snapshot = { state = "idle" } }
  function importer:isBusy()
    return self.busy
  end
  function importer:status()
    return self.snapshot
  end
  function importer:filedropped(file)
    self.drops[#self.drops + 1] = file:getFilename()
  end
  return importer
end

---@param width number
---@param height number
---@param draw fun()
---@return table[] fill rectangles drawn, { mode, x, y, width, height }
---@return string rendered text copy
local function captureDraw(width, height, draw)
  local lg = love.graphics
  local saved = {
    getDimensions = lg.getDimensions,
    setColor = lg.setColor,
    rectangle = lg.rectangle,
    print = lg.print,
    printf = lg.printf,
  }
  local rects = {}
  local copy = {}
  lg.getDimensions = function()
    return width, height
  end
  lg.setColor = function() end
  lg.rectangle = function(mode, x, y, rectWidth, rectHeight)
    rects[#rects + 1] = { mode = mode, x = x, y = y, width = rectWidth, height = rectHeight }
  end
  lg.print = function(value)
    copy[#copy + 1] = tostring(value)
  end
  lg.printf = function(value)
    copy[#copy + 1] = tostring(value)
  end
  local ok, err = xpcall(draw, debug.traceback)
  lg.getDimensions = saved.getDimensions
  lg.setColor = saved.setColor
  lg.rectangle = saved.rectangle
  lg.print = saved.print
  lg.printf = saved.printf
  if not ok then
    error(err, 0)
  end
  return rects, table.concat(copy, "\n")
end

---@param rects table[]
---@param width number
---@param height number
---@return table? the card fill: the largest fill rect that is not the background
local function cardFill(rects, width, height)
  local best = nil
  for _, rect in ipairs(rects) do
    if rect.mode == "fill" then
      local isBackground = rect.x == 0 and rect.y == 0 and rect.width == width and rect.height == height
      if not isBackground and (best == nil or rect.width * rect.height > best.width * best.height) then
        best = rect
      end
    end
  end
  return best
end

function T.compact_card_fits_its_copy_with_modest_padding()
  for _, dimensions in ipairs({ { 800, 600 }, { 360, 640 } }) do
    local width, height = dimensions[1], dimensions[2]
    local state = ImportState.new(scriptImporter(), nil)
    local rects = captureDraw(width, height, function()
      state:draw()
    end)
    local card = cardFill(rects, width, height)
    Assert.notNil(card, "the import view draws one card above its background")
    Assert.isTrue(
      card.width <= CARD_MAX_WIDTH,
      "the import card stays compact, got width " .. tostring(card.width)
    )
    Assert.isTrue(
      card.height <= CARD_MAX_HEIGHT,
      "the import card stays content-fit, got height " .. tostring(card.height)
    )
    Assert.isTrue(card.x > 0 and card.y > 0, "the compact card keeps padding from the window edges")
    Assert.isTrue(
      card.x + card.width < width and card.y + card.height < height,
      "the compact card never touches the far window edges"
    )
  end
end

function T.dropped_file_is_acknowledged_on_the_first_frame()
  local importer = scriptImporter()
  local state = ImportState.new(importer, nil)
  state:filedropped({
    getFilename = function()
      return "soulsilver.nds"
    end,
  })
  Assert.equal(#importer.drops, 1, "the drop still reaches the importer")
  -- No importer tick runs between the drop and this draw: the receipt must
  -- already be visible.
  local _, copy = captureDraw(800, 600, function()
    state:draw()
  end)
  Assert.isTrue(
    copy:find("File received", 1, true) ~= nil,
    "the first post-input frame acknowledges the file, got: " .. copy
  )
  Assert.isTrue(copy:find("soulsilver.nds", 1, true) ~= nil, "the receipt names the dropped file")
  for _, premature in ipairs({ "accepted", "verified", "complete" }) do
    Assert.isTrue(
      copy:lower():find(premature, 1, true) == nil,
      "an unvalidated receipt never claims success, found: " .. premature
    )
  end
end

function T.drop_and_picker_share_one_receipt_seam()
  local state = ImportState.new(scriptImporter(), nil)
  Assert.equal(
    type(state.markReceived),
    "function",
    "the import card exposes one receipt seam shared by the drop and picker channels"
  )
  state:markReceived("soulsilver.nds")
  local _, copy = captureDraw(800, 600, function()
    state:draw()
  end)
  Assert.isTrue(
    copy:find("File received", 1, true) ~= nil,
    "the shared receipt seam drives the same visible acknowledgement"
  )
  Assert.isTrue(copy:find("soulsilver.nds", 1, true) ~= nil, "the shared seam names the received file")
end

function T.rejected_drop_reports_a_concise_failure_on_the_first_frame()
  local RomImporter = require("romdump.src.source.RomImporter")
  local importer = RomImporter.new({
    onComplete = function() end,
  })
  local state = ImportState.new(importer, nil)
  state:filedropped({
    getFilename = function()
      return "notes.txt"
    end,
  })
  local _, copy = captureDraw(800, 600, function()
    state:draw()
  end)
  Assert.isTrue(
    copy:find("notes.txt", 1, true) ~= nil,
    "the rejection names the dropped file, got: " .. copy
  )
  Assert.isTrue(
    copy:lower():find("not a", 1, true) ~= nil or copy:lower():find("rejected", 1, true) ~= nil,
    "the rejection states the file was not accepted"
  )
  Assert.isTrue(
    copy:find("File received", 1, true) == nil,
    "a rejected file is never acknowledged as received"
  )
end

function T.busy_import_rejects_a_second_drop_without_resetting_progress()
  local importer = scriptImporter()
  importer.busy = true
  importer.snapshot = { state = "verifying", progress = 0.6 }
  local state = ImportState.new(importer, nil)
  state:filedropped({
    getFilename = function()
      return "second.nds"
    end,
  })
  Assert.equal(#importer.drops, 0, "a busy importer never sees the second drop")
  local _, copy = captureDraw(800, 600, function()
    state:draw()
  end)
  local lowered = copy:lower()
  Assert.isTrue(
    lowered:find("reject", 1, true) ~= nil,
    "a busy drop reports its rejection on the first frame, got: " .. copy
  )
  Assert.isTrue(
    copy:find("File received", 1, true) == nil,
    "a rejected drop never claims receipt"
  )
  Assert.isTrue(
    copy:find("Verifying ROM", 1, true) ~= nil,
    "the rejection preserves the running verification progress, got: " .. copy
  )
end

function T.verification_progress_is_a_monotonic_bar_without_internal_jargon()
  local importer = scriptImporter()
  local state = ImportState.new(importer, nil)
  local previousSignature = nil
  local previousWidest = nil
  for _, progress in ipairs({ 0, 0.25, 0.6, 0.9 }) do
    importer.snapshot = { state = "verifying", progress = progress }
    local rects, copy = captureDraw(800, 600, function()
      state:draw()
    end)
    Assert.isTrue(
      copy:lower():find("registering", 1, true) == nil,
      "verification progress never exposes registration jargon, got: " .. copy
    )
    local card = assert(cardFill(rects, 800, 600), "the card stays drawn behind the bar")
    local signature = {}
    local widest = 0
    for _, rect in ipairs(rects) do
      if rect.mode == "fill" then
        local isBackground = rect.x == 0 and rect.y == 0 and rect.width == 800 and rect.height == 600
        if not isBackground then
          Assert.isTrue(
            rect.x >= card.x and rect.x + rect.width <= card.x + card.width,
            "progress chrome stays inside the compact card"
          )
          signature[#signature + 1] = string.format("%d:%d:%d:%d", rect.x, rect.y, rect.width, rect.height)
          widest = math.max(widest, rect.width)
        end
      end
    end
    table.sort(signature)
    local flat = table.concat(signature, "|")
    if previousSignature ~= nil then
      Assert.isTrue(
        flat ~= previousSignature,
        "verification progress visibly advances its bar between ticks"
      )
      Assert.isTrue(widest >= previousWidest, "the verification bar never moves backwards")
    end
    previousSignature = flat
    previousWidest = widest
  end
  Assert.isTrue(previousSignature ~= nil, "verification progress is visible as a bar")
end

function T.receipt_truncates_long_names_and_replaces_control_characters()
  local state = ImportState.new(scriptImporter(), nil)
  state:markReceived("soulsilver-very-long-edition-name-with-extra-words.nds")
  local shown = state:receivedName()
  assert(shown ~= nil, "a named file latches its receipt")
  Assert.isTrue(#shown <= 50, "the receipt stays on one card row, got: " .. shown)
  Assert.isTrue(shown:sub(-3) == "…", "a truncated receipt marks its cut, got: " .. shown)
  state:markReceived("soulsilver.nds")
  Assert.equal(state:receivedName(), "soulsilver.nds", "a short name keeps its file kind visible")
  state:markReceived("evil\nname.nds")
  local clean = assert(state:receivedName(), "a hostile name still latches visibly")
  Assert.isTrue(clean:find("\n", 1, true) == nil, "control characters never reach the card")
  local _, copy = captureDraw(800, 600, function()
    state:draw()
  end)
  Assert.isTrue(copy:find(clean, 1, true) ~= nil, "the drawn receipt matches the sanitized name")
end

function T.enabled_picker_card_stays_compact()
  for _, dimensions in ipairs({ { 800, 600 }, { 360, 640 } }) do
    local width, height = dimensions[1], dimensions[2]
    local state = ImportState.new(scriptImporter(), nil, {
      pickerAvailable = true,
      onPick = function() end,
    })
    local rects, copy = captureDraw(width, height, function()
      state:draw()
    end)
    local card = cardFill(rects, width, height)
    Assert.notNil(card, "the picker card draws above its background")
    Assert.isTrue(card.width <= CARD_MAX_WIDTH, "the picker card stays compact")
    Assert.isTrue(card.height <= CARD_MAX_HEIGHT, "the picker card stays content-fit")
    Assert.isTrue(card.x > 0 and card.y > 0, "the picker card keeps padding from the window edges")
    Assert.isTrue(
      card.x + card.width < width and card.y + card.height < height,
      "the picker card never touches the far window edges"
    )
    Assert.isTrue(copy:find("browse", 1, true) ~= nil, "the picker card names its browse path")
  end
end

function T.receipt_names_basenames_without_leaking_paths()
  local App = require("app.src.App")
  Assert.equal(
    App._receiptName("path", "C:\\fakepath\\soulsilver.nds"),
    "soulsilver.nds",
    "a picked path acknowledges only its basename"
  )
  Assert.equal(
    App._receiptName("path", "/home/player/dumps/heartgold.nds"),
    "heartgold.nds",
    "a posix picked path acknowledges only its basename"
  )
  local long = App._receiptName("path", "/home/player/" .. string.rep("a", 80) .. ".nds")
  assert(long ~= nil, "a long picked name still acknowledges")
  Assert.isTrue(#long <= 50, "a long picked name truncates to one card row")
  Assert.isNil(App._receiptName("path", nil), "an unnamed pick acknowledges nothing")
  Assert.isNil(App._receiptName("drop", nil), "an unnamed drop acknowledges nothing")
end

-- The copy block (title, instructions and transient status rows) is measured
-- through the same draw calls production emits: every text row's y plus its
-- wrapped height from the live font, the drawn card rectangle, and the
-- reserved progress band above the card's bottom edge. A rigid vertical
-- shift keeps the block's own height fixed, so a centered block leaves the
-- same space above it as below it.

---@class TextRow
---@field value string
---@field y number
---@field limit number?

---@param width number
---@param height number
---@param draw fun()
---@return table[] fill and line rectangles drawn
---@return TextRow[] text rows in draw order with their y positions
local function captureTextLayout(width, height, draw)
  local lg = love.graphics
  local saved = {
    getDimensions = lg.getDimensions,
    setColor = lg.setColor,
    rectangle = lg.rectangle,
    print = lg.print,
    printf = lg.printf,
  }
  local rects = {}
  local rows = {}
  lg.getDimensions = function()
    return width, height
  end
  lg.setColor = function() end
  lg.rectangle = function(mode, x, y, rectWidth, rectHeight)
    rects[#rects + 1] = { mode = mode, x = x, y = y, width = rectWidth, height = rectHeight }
  end
  lg.print = function(value, x, y)
    rows[#rows + 1] = { value = tostring(value), y = y }
  end
  lg.printf = function(value, x, y, limit)
    rows[#rows + 1] = { value = tostring(value), y = y, limit = limit }
  end
  local ok, err = xpcall(draw, debug.traceback)
  lg.getDimensions = saved.getDimensions
  lg.setColor = saved.setColor
  lg.rectangle = saved.rectangle
  lg.print = saved.print
  lg.printf = saved.printf
  if not ok then
    error(err, 0)
  end
  return rects, rows
end

---@return number live font line height, or the card row step when no font answers
local function liveLineHeight()
  local lg = love.graphics
  if lg ~= nil and lg.getFont ~= nil then
    local okFont, font = pcall(lg.getFont)
    if okFont and font ~= nil and font.getHeight ~= nil then
      local okHeight, height = pcall(font.getHeight, font)
      if okHeight and type(height) == "number" then
        return height
      end
    end
  end
  return 20
end

---@param value string
---@param limit number?
---@return number wrapped line count for this row at its drawn width
local function wrappedLines(value, limit)
  if limit == nil then
    return 1
  end
  local lg = love.graphics
  if lg == nil or lg.getFont == nil then
    return 1
  end
  local okFont, font = pcall(lg.getFont)
  if not okFont or font == nil or font.getWrap == nil then
    return 1
  end
  local okWrap, _, wrapped = pcall(font.getWrap, font, value, limit)
  if not okWrap or type(wrapped) ~= "table" then
    return 1
  end
  return math.max(1, #wrapped)
end

---@param rows TextRow[]
---@return number firstY top of the first text row
---@return number lastBottom bottom of the lowest wrapped text row
local function textBlock(rows)
  local lineHeight = liveLineHeight()
  local firstY = nil
  local lastBottom = nil
  for _, row in ipairs(rows) do
    if firstY == nil or row.y < firstY then
      firstY = row.y
    end
    local bottom = row.y + wrappedLines(row.value, row.limit) * lineHeight
    if lastBottom == nil or bottom > lastBottom then
      lastBottom = bottom
    end
  end
  assert(firstY ~= nil and lastBottom ~= nil, "the card draws at least one text row")
  return firstY, lastBottom
end

---@param rects table[]
---@param card table drawn card fill
---@return table? the widest 8px-tall fill inside the card: the progress track bed
local function trackBackground(rects, card)
  local best = nil
  for _, rect in ipairs(rects) do
    if rect.mode == "fill" and rect.height == 8 and rect.width > 8 then
      if rect.x >= card.x and rect.x + rect.width <= card.x + card.width then
        if rect.y >= card.y and rect.y + rect.height <= card.y + card.height then
          if best == nil or rect.y > best.y or (rect.y == best.y and rect.width > best.width) then
            best = rect
          end
        end
      end
    end
  end
  return best
end

---@param width number
---@param height number
---@param body fun()
local function withStubbedDimensions(width, height, body)
  local lg = love.graphics
  local original = lg.getDimensions
  lg.getDimensions = function()
    return width, height
  end
  local ok, err = xpcall(body, debug.traceback)
  lg.getDimensions = original
  if not ok then
    error(err, 0)
  end
end

---@param where string matrix position for diagnostics
---@param card table drawn card fill
---@param firstY number
---@param lastBottom number
---@param reservedTop number top of the reserved progress band
local function assertBalancedCopy(where, card, firstY, lastBottom, reservedTop)
  local contentTop = card.y + 16
  local topPad = firstY - contentTop
  local bottomPad = reservedTop - lastBottom
  Assert.isTrue(
    lastBottom <= reservedTop + 1,
    where .. ": copy overlaps the reserved progress band"
  )
  Assert.isTrue(
    topPad >= 8,
    where .. ": copy still starts at the top inset instead of moving toward the center, top pad " .. tostring(topPad)
  )
  Assert.isTrue(
    math.abs(topPad - bottomPad) <= 12,
    where .. ": copy leaves unbalanced space, top pad " .. tostring(topPad) .. " bottom pad " .. tostring(bottomPad)
  )
end

local CENTER_SIZES = { { 800, 600 }, { 960, 540 }, { 360, 640 } }

---@param picker boolean
---@return table? construction options
local function pickerOptions(picker)
  if picker then
    return { pickerAvailable = true, onPick = function() end }
  end
  return nil
end

function T.copy_block_is_vertically_centered_above_the_progress_track()
  local cases = {
    { name = "idle", snapshot = { state = "idle" }, bar = false },
    { name = "received", snapshot = { state = "idle" }, received = "soulsilver.nds", bar = false },
    { name = "reading", snapshot = { state = "reading", progress = 0.3 }, bar = true },
    { name = "verifying", snapshot = { state = "verifying", progress = 0.5 }, bar = true },
    {
      name = "artwork",
      snapshot = { state = "complete", progress = 1 },
      override = { stage = "artwork" },
      bar = true,
    },
  }
  for _, dimensions in ipairs(CENTER_SIZES) do
    local width, height = dimensions[1], dimensions[2]
    for _, picker in ipairs({ false, true }) do
      for _, case in ipairs(cases) do
        local where = width .. "x" .. height .. " picker=" .. tostring(picker) .. " " .. case.name
        local importer = scriptImporter()
        importer.snapshot = case.snapshot
        local state = ImportState.new(importer, nil, pickerOptions(picker))
        if case.received ~= nil then
          state:markReceived(case.received)
        end
        local rects, rows = captureTextLayout(width, height, function()
          state:draw(case.override)
        end)
        local card = cardFill(rects, width, height)
        Assert.notNil(card, where .. ": the import view draws one card above its background")
        local copy = ""
        for _, row in ipairs(rows) do
          copy = copy .. "\n" .. row.value
        end
        if case.name == "received" then
          Assert.isTrue(copy:find("File received", 1, true) ~= nil, where .. ": the receipt stays visible")
          Assert.isTrue(copy:find("soulsilver.nds", 1, true) ~= nil, where .. ": the receipt names the file")
        elseif case.name == "reading" then
          Assert.isTrue(copy:find("Checking ROM", 1, true) ~= nil, where .. ": the reading stage stays visible")
        elseif case.name == "verifying" then
          Assert.isTrue(copy:find("Verifying ROM", 1, true) ~= nil, where .. ": the verifying stage stays visible")
          Assert.isTrue(
            copy:find("Verifying cartridge identity", 1, true) ~= nil,
            where .. ": the verification detail stays visible"
          )
        elseif case.name == "artwork" then
          Assert.isTrue(
            copy:find("Preparing walking sprites", 1, true) ~= nil,
            where .. ": the artwork wait stays visible"
          )
        else
          Assert.isTrue(
            copy:find("File received", 1, true) == nil
              and copy:find("Verifying ROM", 1, true) == nil
              and copy:find("Checking ROM", 1, true) == nil,
            where .. ": an idle card shows no transient status, got:" .. copy
          )
        end
        local reservedTop
        if case.bar then
          local track = trackBackground(rects, card)
          Assert.notNil(track, where .. ": the progress track stays drawn at the card bottom")
          Assert.near(track.y, card.y + card.height - 30, 1, where .. ": the progress track keeps its bottom edge")
          reservedTop = track.y
        else
          Assert.isTrue(
            trackBackground(rects, card) == nil,
            where .. ": an idle card paints no progress bar in its reserved band"
          )
          reservedTop = card.y + card.height - 30
        end
        local firstY, lastBottom = textBlock(rows)
        assertBalancedCopy(where, card, firstY, lastBottom, reservedTop)
      end
    end
  end
  withStubbedDimensions(800, 600, function()
    local pickerCalls = 0
    local state = ImportState.new(scriptImporter(), nil, {
      pickerAvailable = true,
      onPick = function()
        pickerCalls = pickerCalls + 1
      end,
    })
    state:mousepressed(400, 300, 1)
    Assert.equal(pickerCalls, 1, "the card center still activates the picker")
    state:mousepressed(16, 16, 1)
    Assert.equal(pickerCalls, 1, "a press outside the card still opens nothing")
  end)
end

function T.failure_copy_stays_legible_inside_the_card()
  local importer = scriptImporter()
  importer.snapshot =
    { state = "error", errorCode = "IMPORT_NOT_NDS", error = "not a Nintendo DS ROM" }
  do
    local state = ImportState.new(importer, nil)
    local rects, rows = captureTextLayout(800, 600, function()
      state:draw()
    end)
    local card = assert(cardFill(rects, 800, 600), "the failing card still draws above its background")
    local copy = ""
    for _, row in ipairs(rows) do
      copy = copy .. "\n" .. row.value
    end
    Assert.isTrue(copy:find("IMPORT_NOT_NDS", 1, true) ~= nil, "the verifier code stays visible")
    Assert.isTrue(copy:find("not a Nintendo DS ROM", 1, true) ~= nil, "the verifier detail stays visible")
    local firstY, lastBottom = textBlock(rows)
    Assert.isTrue(
      firstY - (card.y + 16) >= 8,
      "failure copy still starts at the top inset instead of moving toward the center"
    )
    Assert.isTrue(lastBottom <= card.y + card.height - 8, "failure copy stays inside the card")
  end
  do
    local narrow = scriptImporter()
    narrow.snapshot =
      { state = "error", errorCode = "IMPORT_NOT_NDS", error = "not a Nintendo DS ROM cartridge image" }
    local state = ImportState.new(narrow, nil, pickerOptions(true))
    local rects, rows = captureTextLayout(240, 480, function()
      state:draw()
    end)
    local card = assert(cardFill(rects, 240, 480), "the narrow failing card still draws")
    local copy = ""
    for _, row in ipairs(rows) do
      copy = copy .. "\n" .. row.value
    end
    Assert.isTrue(copy:find("IMPORT_NOT_NDS", 1, true) ~= nil, "the narrow failure keeps its code")
    local firstY, lastBottom = textBlock(rows)
    Assert.isTrue(firstY >= card.y + 16, "narrow failure copy never starts above the top inset")
    Assert.isTrue(lastBottom <= card.y + card.height - 4, "narrow failure copy stays inside the card")
  end
  do
    local failing = scriptImporter()
    failing.snapshot = { state = "complete", progress = 1 }
    local state = ImportState.new(failing, nil)
    local rects, rows = captureTextLayout(800, 600, function()
      state:draw({ stage = "artwork", failure = "texture adoption failed" })
    end)
    local card = assert(cardFill(rects, 800, 600), "the artwork failure still draws its card")
    local copy = ""
    for _, row in ipairs(rows) do
      copy = copy .. "\n" .. row.value
    end
    Assert.isTrue(
      copy:find("Walking sprites hit an error", 1, true) ~= nil,
      "the artwork failure names its pending step"
    )
    Assert.isTrue(copy:find("Press R", 1, true) ~= nil, "the artwork failure keeps its retry path")
    local firstY, lastBottom = textBlock(rows)
    Assert.isTrue(firstY >= card.y + 16, "artwork failure copy never starts above the top inset")
    Assert.isTrue(lastBottom <= card.y + card.height - 4, "artwork failure copy stays inside the card")
  end
  do
    local busy = scriptImporter()
    busy.busy = true
    busy.snapshot = { state = "verifying", progress = 0.6 }
    local state = ImportState.new(busy, nil)
    state:filedropped({
      getFilename = function()
        return "second.nds"
      end,
    })
    local rects, rows = captureTextLayout(800, 600, function()
      state:draw()
    end)
    local card = assert(cardFill(rects, 800, 600), "the busy card still draws")
    local copy = ""
    for _, row in ipairs(rows) do
      copy = copy .. "\n" .. row.value
    end
    Assert.isTrue(copy:lower():find("reject", 1, true) ~= nil, "the busy rejection stays visible")
    Assert.isTrue(copy:find("Verifying ROM", 1, true) ~= nil, "the running verification keeps its stage")
    local track = trackBackground(rects, card)
    Assert.notNil(track, "the running verification keeps its progress track")
    local _, lastBottom = textBlock(rows)
    Assert.isTrue(lastBottom <= track.y + 1, "busy copy never covers the progress track")
  end
  do
    local narrow = ImportState.new(scriptImporter(), nil)
    narrow:markReceived("evil\nname.nds")
    local shown = assert(narrow:receivedName(), "a hostile name still latches visibly")
    Assert.isTrue(shown:find("\n", 1, true) == nil, "control characters never reach the card")
    local _, rows = captureTextLayout(240, 480, function()
      narrow:draw()
    end)
    local copy = ""
    for _, row in ipairs(rows) do
      copy = copy .. "\n" .. row.value
    end
    Assert.isTrue(copy:find(shown, 1, true) ~= nil, "the narrow card draws the sanitized receipt")
  end
end

function T.pointer_activation_matches_the_drawn_card()
  for _, dimensions in ipairs({ { 800, 600 }, { 360, 640 }, { 240, 480 } }) do
    local width, height = dimensions[1], dimensions[2]
    local where = width .. "x" .. height
    withStubbedDimensions(width, height, function()
      local pickerCalls = 0
      local state = ImportState.new(scriptImporter(), nil, {
        pickerAvailable = true,
        onPick = function()
          pickerCalls = pickerCalls + 1
        end,
      })
      local centerX, centerY = width / 2, height / 2
      state:mousepressed(centerX, centerY, 1)
      state:mousepressed(centerX - 60, centerY - 50, 1)
      state:mousepressed(centerX + 60, centerY + 50, 1)
      Assert.equal(pickerCalls, 3, where .. ": interior points of the single card each activate once")
      state:mousepressed(8, 8, 1)
      state:mousepressed(width - 8, height - 8, 1)
      Assert.equal(pickerCalls, 3, where .. ": presses outside the card open nothing")
      state:keypressed("return")
      Assert.equal(pickerCalls, 4, where .. ": keyboard activation matches pointer activation")
    end)
  end
  withStubbedDimensions(800, 600, function()
    local pickerCalls = 0
    local inert = ImportState.new(scriptImporter(), nil, {
      pickerAvailable = false,
      onPick = function()
        pickerCalls = pickerCalls + 1
      end,
    })
    inert:mousepressed(400, 300, 1)
    Assert.equal(pickerCalls, 0, "without a usable bridge no gesture opens a picker")
    local busyImporter = scriptImporter()
    busyImporter.busy = true
    local busyCalls = 0
    local busy = ImportState.new(busyImporter, nil, {
      pickerAvailable = true,
      onPick = function()
        busyCalls = busyCalls + 1
      end,
    })
    busy:mousepressed(400, 300, 1)
    Assert.equal(busyCalls, 0, "a busy importer opens no duplicate picker")
  end)
  withStubbedDimensions(800, 600, function()
    local pickerCalls = 0
    local state = ImportState.new(scriptImporter(), nil, {
      pickerAvailable = true,
      onPick = function()
        pickerCalls = pickerCalls + 1
      end,
    })
    state:mousepressed(400, 300, 1)
    withStubbedDimensions(360, 640, function()
      state:resize(360, 640)
      state:mousepressed(180, 320, 1)
    end)
    Assert.equal(pickerCalls, 2, "the same card activates after a resize")
  end)
end

function T.verified_source_waits_on_artwork_without_claiming_completion()
  local importer = scriptImporter()
  importer.snapshot = { state = "complete", progress = 1 }
  local state = ImportState.new(importer, nil)
  local _, copy = captureDraw(800, 600, function()
    state:draw({ stage = "artwork" })
  end)
  Assert.isTrue(
    copy:find("Preparing walking sprites", 1, true) ~= nil,
    "verified artwork wait names its pending step, got: " .. copy
  )
  Assert.isTrue(copy:find("100%%") == nil, "no completion fraction is shown before the pair is resident")
  for _, premature in ipairs({ "ROM accepted", "complete" }) do
    Assert.isTrue(
      copy:find(premature, 1, true) == nil,
      "artwork wait never claims the handoff, found: " .. premature
    )
  end
end

return { tests = T }
