-- The pristine launcher entry is authored UI: it must render independently
-- of a ROM/cache and offer a usable pointer target on desktop and touch hosts.

local Assert = require("tests.support.Assert")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local Errors = require("libs.errors.src.Errors")
local ImportState = require("app.src.launcher.ImportState")

local T = {}

-- A scriptable importer stand-in. The real importer vocabulary is reused
-- for status states; drops and busy are scripted per test.
local function idleImporter()
  local importer = { busy = false, drops = 0, snapshot = { state = "idle" } }
  function importer:isBusy()
    return self.busy
  end
  function importer:status()
    return self.snapshot
  end
  function importer:filedropped(_)
    self.drops = self.drops + 1
  end
  return importer
end

local function stubDimensions(width, height)
  local original = love.graphics.getDimensions
  love.graphics.getDimensions = function()
    return width, height
  end
  return original
end

-- Records every print/printf line one draw produces, then restores the
-- graphics text entrypoints on both paths.
local function renderedCopy(draw)
  local lg = love.graphics
  local originalPrint, originalPrintf = lg.print, lg.printf
  local rendered = {}
  lg.print = function(value, ...)
    rendered[#rendered + 1] = tostring(value)
    return originalPrint(value, ...)
  end
  lg.printf = function(value, ...)
    rendered[#rendered + 1] = tostring(value)
    return originalPrintf(value, ...)
  end
  local ok, err = xpcall(draw, debug.traceback)
  lg.print, lg.printf = originalPrint, originalPrintf
  if not ok then
    error(err, 0)
  end
  return table.concat(rendered, "\n")
end

function T.pristine_entry_fills_common_window_shapes_without_a_rom(scope)
  local importer = {
    status = function()
      return { state = "idle" }
    end,
  }
  local state = ImportState.new(importer, nil)

  for _, dimensions in ipairs({ { 480, 360 }, { 800, 450 }, { 360, 640 } }) do
    local width, height = dimensions[1], dimensions[2]
    local canvas = scope:own(love.graphics.newCanvas(width, height))
    love.graphics.setCanvas(canvas)
    love.graphics.clear(0, 0, 0, 0)
    state:draw()
    love.graphics.setCanvas()
    local image = canvas:newImageData()
    local _, _, _, alpha = image:getPixel(0, 0)
    Assert.isTrue(alpha > 0, "the authored entry must cover the full drawable")
  end
end

-- The pristine card names what it accepts without naming an edition.
function T.pristine_card_names_supported_formats_without_edition_or_loader_copy(_)
  local state = ImportState.new(idleImporter(), nil)
  local copy = renderedCopy(function()
    state:draw()
  end)
  Assert.isTrue(copy:find("%.nds") ~= nil, "the card names the supported ROM file")
  Assert.isTrue(copy:find("%.zip") ~= nil, "the card names the supported ROM archive")
  for _, forbidden in ipairs({
    "HeartGold",
    "SoulSilver",
    "heartgold",
    "soulsilver",
    "Switch edition",
    "Choose ROM file",
    "Drag and drop also works",
    "Enraging the lake",
  }) do
    Assert.isTrue(
      copy:find(forbidden, 1, true) == nil,
      "the first card stays neutral, found: " .. forbidden
    )
  end
end

-- One centered card is the only activation target: distinct interior
-- points each open the picker exactly once, and a corner outside the card
-- opens nothing. Interior points are small offsets around the window
-- center so they hold for any centered card across window shapes.
function T.whole_card_opens_the_available_picker_without_an_inner_target(_)
  for _, dimensions in ipairs({ { 800, 600 }, { 360, 640 } }) do
    local width, height = dimensions[1], dimensions[2]
    local original = stubDimensions(width, height)
    local ok, err = xpcall(function()
      local pickerCalls = 0
      local state = ImportState.new(idleImporter(), nil, {
        pickerAvailable = true,
        onPick = function()
          pickerCalls = pickerCalls + 1
        end,
      })
      local centerX = width / 2
      state:mousepressed(centerX, height * 0.46, 1)
      state:touchpressed("touch", centerX, height * 0.54, 0, 0, 1)
      Assert.equal(pickerCalls, 2, "every interior point of the single card activates once")
      state:mousepressed(16, 16, 1)
      state:touchpressed("touch", 16, 16, 0, 0, 1)
      Assert.equal(pickerCalls, 2, "gestures outside the card open nothing")
      state:keypressed("return")
      Assert.equal(pickerCalls, 3, "keyboard activation matches pointer activation")
    end, debug.traceback)
    love.graphics.getDimensions = original
    if not ok then
      error(err, 0)
    end
  end
end

-- Without a usable native bridge the card is an honest drop area: no
-- pointer or keyboard gesture opens a picker, while drops still import.
function T.unavailable_picker_leaves_card_inert_but_keeps_file_drop(_)
  local original = stubDimensions(800, 600)
  local ok, err = xpcall(function()
    local pickerCalls = 0
    local importer = idleImporter()
    local state = ImportState.new(importer, nil, {
      pickerAvailable = false,
      onPick = function()
        pickerCalls = pickerCalls + 1
      end,
    })
    state:mousepressed(400, 300, 1)
    state:touchpressed("touch", 400, 300, 0, 0, 1)
    state:keypressed("return")
    state:keypressed("space")
    Assert.equal(pickerCalls, 0, "without a native bridge no gesture opens a picker")
    state:filedropped({ getFilename = function()
      return "dropped.nds"
    end })
    Assert.equal(importer.drops, 1, "file drops still reach the importer")
  end, debug.traceback)
  love.graphics.getDimensions = original
  if not ok then
    error(err, 0)
  end
end

-- Hit-testing follows the live drawable size: one state activates through the
-- card at both window shapes, so no hard-coded geometry is frozen at build.
function T.card_activation_tracks_the_live_drawable_size(_)
  local original = stubDimensions(800, 600)
  local ok, err = xpcall(function()
    local pickerCalls = 0
    local state = ImportState.new(idleImporter(), nil, {
      pickerAvailable = true,
      onPick = function()
        pickerCalls = pickerCalls + 1
      end,
    })
    state:mousepressed(400, 300, 1)
    love.graphics.getDimensions = function()
      return 360, 640
    end
    state:resize(360, 640)
    state:mousepressed(180, 320, 1)
    Assert.equal(pickerCalls, 2, "the same card activates after a resize")
  end, debug.traceback)
  love.graphics.getDimensions = original
  if not ok then
    error(err, 0)
  end
end

-- While an import is running, further card or keyboard activation must not
-- open a second picker dialog.
function T.busy_importer_suppresses_repeat_picker_activation(_)
  local original = stubDimensions(800, 600)
  local ok, err = xpcall(function()
    local pickerCalls = 0
    local importer = idleImporter()
    importer.busy = true
    local state = ImportState.new(importer, nil, {
      pickerAvailable = true,
      onPick = function()
        pickerCalls = pickerCalls + 1
      end,
    })
    state:mousepressed(400, 300, 1)
    state:keypressed("return")
    Assert.equal(pickerCalls, 0, "a busy importer opens no duplicate picker")
  end, debug.traceback)
  love.graphics.getDimensions = original
  if not ok then
    error(err, 0)
  end
end

-- Genuine verification failures stay visible with their real detail; a
-- native-dialog problem is never painted as an import banner.
function T.import_errors_show_verifier_detail_without_a_picker_strip(_)
  local failing = idleImporter()
  failing.snapshot =
    { state = "error", errorCode = "IMPORT_NOT_NDS", error = Errors.new("IMPORT_NOT_NDS", "not a Nintendo DS ROM") }
  local detail = renderedCopy(function()
    ImportState.new(failing, nil, { pickerAvailable = true }):draw()
  end)
  Assert.isTrue(detail:find("IMPORT_NOT_NDS", 1, true) ~= nil, "the verifier code stays visible")
  Assert.isTrue(detail:find("not a Nintendo DS ROM", 1, true) ~= nil, "the verifier detail stays visible")

  local idle = renderedCopy(function()
    ImportState.new(idleImporter(), nil, { pickerError = "native bridge exploded" }):draw()
  end)
  Assert.isTrue(
    idle:find("native bridge exploded", 1, true) == nil,
    "a native-dialog problem is not painted as an import banner"
  )
end

-- Edition targeting never adds edition chrome to the first card, and the
-- edition switch affordance is gone from this surface.
function T.targeted_options_never_add_edition_chrome_to_the_first_card(_)
  local switches = 0
  local state = ImportState.new(idleImporter(), nil, {
    targetVersion = "heartgold",
    pickerAvailable = true,
    onPick = function() end,
    onSwitchEdition = function()
      switches = switches + 1
    end,
  })
  local copy = renderedCopy(function()
    state:draw()
  end)
  for _, forbidden in ipairs({ "HeartGold", "heartgold", "Switch edition" }) do
    Assert.isTrue(copy:find(forbidden, 1, true) == nil, "no edition chrome, found: " .. forbidden)
  end
  state:keypressed("tab")
  Assert.equal(switches, 0, "the first card has no edition switch binding")
end

-- Verification progress names the real stage; loader jokes stay off the
-- first-import surface.
function T.verification_progress_names_the_real_stage_without_loader_flavor(_)
  local importer = idleImporter()
  importer.snapshot = { state = "verifying" }
  local copy = renderedCopy(function()
    ImportState.new(importer, nil):draw()
  end)
  Assert.isTrue(
    copy:find("Verifying cartridge identity", 1, true) ~= nil,
    "the real verification stage stays visible"
  )
  Assert.isTrue(
    copy:find("Enraging the lake", 1, true) == nil,
    "loader jokes stay off the first-import surface"
  )
end

-- The copy block (title, instructions and transient status rows) stays grouped
-- in the middle of the card's usable area instead of clinging to its top:
-- the space above the first row matches the space below the last wrapped
-- row, and neither reaches into the progress band kept at the bottom edge.

---@param r number
---@param g number
---@param b number
---@param cr number
---@param cg number
---@param cb number
---@return boolean
local function matchesColor(r, g, b, cr, cg, cb)
  return math.abs(r - cr) < 0.03 and math.abs(g - cg) < 0.03 and math.abs(b - cb) < 0.03
end

---@param r number
---@param g number
---@param b number
---@return boolean whether the pixel belongs to the card body or its border
local function isCardPixel(r, g, b)
  return matchesColor(r, g, b, 0.10, 0.16, 0.20) or matchesColor(r, g, b, 0.35, 0.55, 0.58)
end

---@param r number
---@param g number
---@param b number
---@return boolean whether the pixel belongs to the progress track bed
local function isTrackPixel(r, g, b)
  return matchesColor(r, g, b, 0.22, 0.30, 0.32)
end

---@param image love.ImageData
---@param width number
---@param height number
---@return table box with left, top, right, bottom card edges in pixels
local function detectCardBox(image, width, height)
  local centerX = math.floor(width / 2)
  local top = nil
  for y = 0, height - 1 do
    local red, green, blue = image:getPixel(centerX, y)
    if isCardPixel(red, green, blue) then
      top = y
      break
    end
  end
  Assert.notNil(top, "the import view draws one card above its background")
  local bottom = nil
  for y = height - 1, 0, -1 do
    local red, green, blue = image:getPixel(centerX, y)
    if isCardPixel(red, green, blue) then
      bottom = y
      break
    end
  end
  Assert.notNil(bottom, "the drawn card has a bottom edge")
  local middleY = math.floor((top + bottom) / 2)
  local left = nil
  for x = 0, width - 1 do
    local red, green, blue = image:getPixel(x, middleY)
    if isCardPixel(red, green, blue) then
      left = x
      break
    end
  end
  Assert.notNil(left, "the drawn card has a left edge")
  local right = nil
  for x = width - 1, 0, -1 do
    local red, green, blue = image:getPixel(x, middleY)
    if isCardPixel(red, green, blue) then
      right = x
      break
    end
  end
  Assert.notNil(right, "the drawn card has a right edge")
  return { left = left, top = top, right = right, bottom = bottom }
end

---@param image love.ImageData
---@param box table detected card box
---@return number? top row of the progress track bed, or nil when unpainted
local function detectTrackTop(image, box)
  local low = math.max(box.top, box.bottom - 40)
  local high = math.max(low, box.bottom - 8)
  for y = low, high do
    local count = 0
    for x = box.left, box.right do
      local red, green, blue = image:getPixel(x, y)
      if isTrackPixel(red, green, blue) then
        count = count + 1
      end
    end
    if count >= 10 then
      return y
    end
  end
  return nil
end

---@param recorded table[] text rows with value, y and limit
---@return number firstY
---@return number lastBottom
local function measuredBlock(recorded)
  local font = love.graphics.getFont()
  local lineHeight = font:getHeight()
  local firstY = nil
  local lastBottom = nil
  for _, row in ipairs(recorded) do
    if firstY == nil or row.y < firstY then
      firstY = row.y
    end
    local lines = 1
    if row.limit ~= nil then
      local _, wrapped = font:getWrap(row.value, row.limit)
      lines = math.max(1, #wrapped)
    end
    local bottom = row.y + lines * lineHeight
    if lastBottom == nil or bottom > lastBottom then
      lastBottom = bottom
    end
  end
  Assert.notNil(firstY, "the card draws at least one text row")
  assert(lastBottom ~= nil, "the card draws at least one text row")
  return firstY, lastBottom
end

---@param state table import card under test
---@param scope GraphicsScope
---@param width number
---@param height number
---@param drawArg table? status override passed to draw
---@return table[] recorded text rows
---@return love.ImageData pixels of the rendered card
local function renderCard(state, scope, width, height, drawArg)
  local originalDimensions = love.graphics.getDimensions
  love.graphics.getDimensions = function()
    return width, height
  end
  local recorded = {}
  local lg = love.graphics
  local originalPrint, originalPrintf = lg.print, lg.printf
  lg.print = function(value, x, y, ...)
    recorded[#recorded + 1] = { value = tostring(value), y = y }
    return originalPrint(value, x, y, ...)
  end
  lg.printf = function(value, x, y, limit, ...)
    recorded[#recorded + 1] = { value = tostring(value), y = y, limit = limit }
    return originalPrintf(value, x, y, limit, ...)
  end
  local canvas = scope:own(love.graphics.newCanvas(width, height))
  love.graphics.push("all")
  love.graphics.setCanvas(canvas)
  love.graphics.clear(0, 0, 0, 0)
  local ok, err = xpcall(function()
    state:draw(drawArg)
  end, debug.traceback)
  love.graphics.setCanvas()
  love.graphics.pop()
  lg.print, lg.printf = originalPrint, originalPrintf
  love.graphics.getDimensions = originalDimensions
  if not ok then
    error(err, 0)
  end
  return recorded, scope:own(canvas:newImageData())
end

function T.centered_copy_leaves_balanced_space_on_the_real_card(scope)
  local cases = {
    { name = "idle", snapshot = { state = "idle" }, bar = false, drawArg = nil },
    { name = "verifying", snapshot = { state = "verifying", progress = 0.5 }, bar = true, drawArg = nil },
    {
      name = "artwork",
      snapshot = { state = "complete", progress = 1 },
      bar = true,
      drawArg = { stage = "artwork" },
    },
  }
  for _, dimensions in ipairs({ { 800, 600 }, { 360, 640 } }) do
    local width, height = dimensions[1], dimensions[2]
    for _, picker in ipairs({ false, true }) do
      for _, case in ipairs(cases) do
        local where = width .. "x" .. height .. " picker=" .. tostring(picker) .. " " .. case.name
        local importer = idleImporter()
        importer.snapshot = case.snapshot
        local options = nil
        if picker then
          options = { pickerAvailable = true, onPick = function() end }
        end
        local recorded, image = renderCard(ImportState.new(importer, nil, options), scope, width, height, case.drawArg)
        local box = detectCardBox(image, width, height)
        Assert.isTrue(box.right - box.left <= 400, where .. ": the import card stays compact")
        local reservedTop
        if case.bar then
          local trackTop = detectTrackTop(image, box)
          Assert.notNil(trackTop, where .. ": the progress track stays drawn at the card bottom")
          Assert.isTrue(
            math.abs(trackTop - (box.bottom - 30)) <= 2,
            where .. ": the progress track keeps its bottom edge"
          )
          reservedTop = trackTop
        else
          Assert.isTrue(
            detectTrackTop(image, box) == nil,
            where .. ": an idle card paints no progress bar in its reserved band"
          )
          reservedTop = box.bottom - 30
        end
        local firstY, lastBottom = measuredBlock(recorded)
        local topPad = firstY - (box.top + 16)
        local bottomPad = reservedTop - lastBottom
        Assert.isTrue(
          lastBottom <= reservedTop + 1,
          where .. ": copy overlaps the reserved progress band"
        )
        Assert.isTrue(
          topPad >= 8,
          where .. ": copy still starts at the top inset instead of moving toward the center, top pad "
            .. tostring(topPad)
        )
        Assert.isTrue(
          math.abs(topPad - bottomPad) <= 12,
          where .. ": copy leaves unbalanced space, top pad " .. tostring(topPad) .. " bottom pad " .. tostring(bottomPad)
        )
      end
    end
  end
  for _, dimensions in ipairs({ { 800, 600 }, { 360, 640 } }) do
    local width, height = dimensions[1], dimensions[2]
    local original = stubDimensions(width, height)
    local ok, err = xpcall(function()
      local pickerCalls = 0
      local state = ImportState.new(idleImporter(), nil, {
        pickerAvailable = true,
        onPick = function()
          pickerCalls = pickerCalls + 1
        end,
      })
      state:mousepressed(width / 2, height / 2, 1)
      Assert.equal(pickerCalls, 1, "the card center still activates the picker")
      state:mousepressed(8, 8, 1)
      Assert.equal(pickerCalls, 1, "a press outside the card still opens nothing")
    end, debug.traceback)
    love.graphics.getDimensions = original
    if not ok then
      error(err, 0)
    end
  end
end

-- The compact card acknowledges a dropped file on the very first frame:
-- modest geometry around its copy plus a visible receipt naming the file,
-- never a premature acceptance claim.
function T.compact_card_acknowledges_the_dropped_file_on_the_first_frame(scope)
  local importer = idleImporter()
  local state = ImportState.new(importer, nil)
  state:filedropped({
    getFilename = function()
      return "soulsilver.nds"
    end,
  })
  Assert.equal(importer.drops, 1, "the drop still reaches the importer")
  local width, height = 800, 600
  local canvas = scope:own(love.graphics.newCanvas(width, height))
  love.graphics.push("all")
  love.graphics.setCanvas(canvas)
  love.graphics.clear(0, 0, 0, 0)
  state:draw()
  love.graphics.setCanvas()
  love.graphics.pop()
  local image = scope:own(canvas:newImageData())
  -- The card fill is the horizontal run of card pixels across the middle
  -- row; the background fill covers the full drawable instead.
  local middleY = math.floor(height / 2)
  local cardRun = 0
  for x = 0, width - 1 do
    local red, green, blue = image:getPixel(x, middleY)
    local isCard = math.abs(red - 0.10) < 0.02 and math.abs(green - 0.16) < 0.02
      and math.abs(blue - 0.20) < 0.02
    if isCard then
      cardRun = cardRun + 1
    end
  end
  Assert.isTrue(cardRun > 0, "the import view draws one card above its background")
  Assert.isTrue(cardRun <= 400, "the import card stays compact, got run " .. tostring(cardRun))
  local copy = renderedCopy(function()
    state:draw()
  end)
  Assert.isTrue(
    copy:find("File received", 1, true) ~= nil,
    "the first post-input frame acknowledges the file, got: " .. copy
  )
  Assert.isTrue(copy:find("soulsilver.nds", 1, true) ~= nil, "the receipt names the dropped file")
  Assert.isTrue(
    copy:find("ROM accepted", 1, true) == nil,
    "an unvalidated receipt never claims acceptance"
  )
end

return GraphicsSmoke.suite(T)
