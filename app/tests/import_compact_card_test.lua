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
