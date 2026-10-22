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

return GraphicsSmoke.suite(T)
