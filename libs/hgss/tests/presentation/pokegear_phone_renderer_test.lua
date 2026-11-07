-- Phone pane routing, dim selection, and font roles: the lower surface
-- always paints the contact list (bright while browsing, dimmed with
-- the fast-forward sprite during a live call, choice-dimmed behind a
-- synthetic choice menu), while the upper surface paints the static
-- plane alone while browsing and the caller windows only during a call.
-- Pure presentation mapping with recording (non-GPU) collaborators.

local Assert = require("tests.support.Assert")
local PokegearPhoneRenderer = require("libs.hgss.src.presentation.PokegearPhoneRenderer")

local T = {}

local LIST_X = 8
local ROW_WIDTH = 216

-- Source surface geometry: the six 24px contact rows ride the scrolled
-- window at screen y8 with the plane frame covering the window's left
-- edge, so the visible bands span x13..224/y8..152; the SUB_2 caller
-- windows and the fast-forward sprite keep their source positions.
local LIST_BAND = { x = 13, y = 8, width = 211, height = 144 }
local NAME_WINDOW = { x = 32, y = 128, width = 72, height = 16 }
local SPEECH_WINDOW = { x = 16, y = 152, width = 216, height = 32 }
local FAST_FORWARD_SOURCE = { x = 128, y = 160 }
local FAST_FORWARD_SEQUENCE = 9

---@return table fake graphics recording fills and image draws
local function recordingGraphics()
  local records = {}
  local graphics = {}
  function graphics.setColor(r, g, b, a)
    graphics._color = { r = r, g = g, b = b, a = a }
  end
  function graphics.rectangle(mode, x, y, width, height)
    records[#records + 1] =
      { op = "rect", mode = mode, x = x, y = y, width = width, height = height, color = graphics._color }
  end
  function graphics.push(_) end
  function graphics.pop() end
  function graphics.origin() end
  function graphics.translate(_, _) end
  function graphics.scale(_, _) end
  function graphics.intersectScissor(x, y, width, height)
    records[#records + 1] = { op = "scissor", x = x, y = y, width = width, height = height }
  end
  function graphics.transformPoint(x, y)
    return x, y
  end
  graphics._records = records
  return graphics --[[@as table]]
end

---@param role string the font role the renderer must route through ("name" or "class")
---@param width number measured text width
---@return table stub text renderer recording palette draws with its role
local function recordingText(role, width)
  local calls = {}
  return {
    role = role,
    textWidth = function(_, _)
      return width or 40
    end,
    drawText = function(self, line, x, y)
      calls[#calls + 1] = { role = self.role, plain = true, line = line, x = x, y = y }
    end,
    drawTextWithPalette = function(self, line, x, y, palette)
      calls[#calls + 1] = { role = self.role, plain = false, line = line, x = x, y = y, palette = palette }
    end,
    _calls = calls,
  }
end

---@return table stub text renderer recording nothing
local function stubText()
  return {
    drawText = function(_, _, _, _) end,
    drawTextWithPalette = function(_, _, _, _, _) end,
  }
end

-- Sixteen list colors with distinct red channels so fills map back to indices.
---@return table palette
local function distinctPalette()
  local palette = {}
  for index = 0, 15 do
    palette[index + 1] = { r = index, g = 0, b = 0 }
  end
  return palette
end

-- Sixteen dimmed colors with a distinct red offset so dimmed fills map
-- back to the dimmed role instead of the bright list palette.
---@return table palette
local function dimPalette()
  local palette = {}
  for index = 0, 15 do
    palette[index + 1] = { r = 100 + index, g = 0, b = 0 }
  end
  return palette
end

-- Compiled phone OBJ sequences with distinct staged paths per sequence;
-- the fast-forward sequence keeps an explicit anchor so sprite paints
-- pin the source position through it.
---@param prefix string staged path prefix distinguishing the sprite set
---@return table sequences by one-based compiled id
local function spriteSequences(prefix)
  local sequences = {}
  for sequence = 1, 9 do
    local anchorX, anchorY = -8, -8
    if sequence == FAST_FORWARD_SEQUENCE then
      anchorX, anchorY = -120, -24
    end
    sequences[sequence] = {
      frames = {
        {
          image = prefix .. sequence .. "-1.png",
          width = 16,
          height = 16,
          anchorX = anchorX,
          anchorY = anchorY,
          duration = 1,
        },
      },
      playMode = "forward",
      loopStartFrameIdx = 0,
    }
  end
  return sequences
end

-- Prepared image leases behind every plane and sprite path the draws
-- below resolve: the source always loads all planes before the first
-- paint, so every draw composes them and never exercises a fallback.
---@return table images
local function stubImages()
  local images = {}
  local function lease(path, drawQuad)
    local entry = {
      draw = function(_, graphics, x, y)
        local records = (graphics --[[@as table]])._records
        if records ~= nil then
          records[#records + 1] = { op = "image", path = path, x = x, y = y }
        end
      end,
    }
    if drawQuad then
      entry.drawQuad = function(_, graphics, _, x, y)
        local records = (graphics --[[@as table]])._records
        if records ~= nil then
          records[#records + 1] = { op = "quad", path = path, x = x, y = y }
        end
      end
      entry.image = {
        getDimensions = function()
          return 256, 16
        end,
      }
    end
    images[path] = entry
  end
  lease("test-foreground")
  lease("test-foreground-dim")
  lease("test-foreground-dim-choice")
  lease("test-upper")
  lease("menu-tiles", true)
  for sequence = 1, 9 do
    lease("test-sprite-" .. sequence .. "-1.png")
    lease("test-sprite-dim-" .. sequence .. "-1.png")
  end
  return images
end

-- The plan payload behind the draws below: bright and dimmed planes,
-- bright and dimmed palettes, bright and dimmed sprite sets, and the
-- shared menu tiles, all with mutually distinct colors and paths so a
-- wrong variant is a mismatch, never a wash.
---@return table content
local function contentFixture()
  return {
    skin = 0,
    foreground = "test-foreground",
    foregroundDim = "test-foreground-dim",
    foregroundDimChoice = "test-foreground-dim-choice",
    upper = "test-upper",
    listPalette = distinctPalette(),
    listPaletteDim = dimPalette(),
    tooltipPalette = distinctPalette(),
    windowPalette = dimPalette(),
    sprites = { phone = spriteSequences("test-sprite-") },
    spritesDim = { phone = spriteSequences("test-sprite-dim-") },
    menuTiles = "menu-tiles",
    menuPalette = distinctPalette(),
  }
end

---@param count integer
---@return table rows with settled slots
local function settledRows(count)
  local rows = {}
  for slot = 0, count - 1 do
    rows[#rows + 1] = { absolute = slot, slot = slot, contact = "c" .. slot, label = "N", class = "C" }
  end
  return rows
end

---@param overrides table? list fields replacing the settled defaults
---@return table view carrying one detached list projection
local function browseView(overrides)
  local view = {
    list = {
      rows = settledRows(6),
      selected = 0,
      scrollOffset = 0,
      firstBgColor = 0,
      manual = false,
      total = 6,
      cursorVisible = false,
    },
  }
  if type(overrides) == "table" then
    for key, value in pairs(overrides) do
      view[key] = value
    end
  end
  return view
end

---@return table a live conversation projection with dim state
local function liveCall()
  return {
    name = "MOM",
    lines = { { text = "hello" } },
    page = 1,
    dim = true,
  }
end

---@param graphics table
---@param firstBg integer
local function drawLowerList(graphics, firstBg)
  local list = {
    rows = settledRows(6),
    selected = 0,
    scrollOffset = 0,
    firstBgColor = firstBg,
    manual = false,
    total = 6,
    cursorVisible = false,
  }
  PokegearPhoneRenderer.draw(
    { graphics = graphics, images = stubImages(), textRenderer = stubText() },
    { list = list },
    {
      skin = 0,
      sprites = { phone = spriteSequences("test-sprite-") },
      foreground = "test-foreground",
      listPalette = distinctPalette(),
    }
  )
end

---@param graphics table
---@param slot integer zero-based slot
---@return number? red channel of the 216x24 band fill at that slot
local function bandRed(graphics, slot)
  for _, fill in ipairs(graphics._records) do
    if
      fill.op == "rect"
      and fill.width == ROW_WIDTH
      and fill.height == 24
      and fill.x == LIST_X
      and fill.y == 8 + slot * 24
    then
      return fill.color.r
    end
  end
  return nil
end

-- Source row set 0 carries palette index 14, set 1 carries 11
-- (PokegearPhoneRenderer ROW_COLORS fill1 entries).
function T.band_colors_follow_slot_parity_not_absolute_index()
  local graphics = recordingGraphics()
  drawLowerList(graphics, 0)
  Assert.equal(bandRed(graphics, 0), 14 / 255, "slot 0 paints the set-1 band")
  Assert.equal(bandRed(graphics, 1), 11 / 255, "slot 1 paints the set-0 band")
  Assert.equal(bandRed(graphics, 2), 14 / 255, "slot 2 paints the set-1 band")
end

---@param graphics table
---@param y number
---@return number? red channel of the 216x24 band fill at that surface y
local function bandRedAt(graphics, y)
  for _, fill in ipairs(graphics._records) do
    if fill.op == "rect" and fill.width == ROW_WIDTH and fill.height == 24 and fill.x == LIST_X and fill.y == y then
      return fill.color.r
    end
  end
  return nil
end

function T.sliding_bands_travel_with_their_rows()
  local graphics = recordingGraphics()
  local rows = {}
  for slot = 0, 6 do
    rows[#rows + 1] = { absolute = slot, slot = slot, contact = "c" .. slot, label = "N", class = "C" }
  end
  local list = {
    rows = rows,
    selected = 6,
    scrollOffset = 1,
    firstBgColor = 0,
    slide = { first = 0, from = 0, direction = 1, pixels = -8 },
    manual = false,
    -- Six contacts keep the chrome quiet so the band fills speak alone.
    total = 6,
    cursorVisible = false,
  }
  PokegearPhoneRenderer.draw(
    { graphics = graphics, images = stubImages(), textRenderer = stubText() },
    { list = list },
    {
      skin = 0,
      sprites = { phone = spriteSequences("test-sprite-") },
      foreground = "test-foreground",
      listPalette = distinctPalette(),
    }
  )
  Assert.equal(bandRedAt(graphics, 8 - 8), 14 / 255, "the outgoing row keeps its band one tick in")
  Assert.equal(bandRedAt(graphics, 8 + 24 - 8), 11 / 255, "the next traveling row keeps its alternating band")
  Assert.equal(bandRedAt(graphics, 8 + 2 * 24 - 8), 14 / 255, "a further traveling row keeps its band one tick in")
end

function T.scroll_flip_flag_inverts_every_band()
  local graphics = recordingGraphics()
  drawLowerList(graphics, 1)
  Assert.equal(bandRed(graphics, 0), 11 / 255, "slot 0 paints the set-0 band while flipped")
  Assert.equal(bandRed(graphics, 1), 14 / 255, "slot 1 paints the set-1 band while flipped")
end

---@param record table a recorded palette line
---@return string its printed line
local function recordedLine(record)
  return record.line
end

-- The source prints the contact name with font 4 and the class with
-- font 0 (PrintNameAndClass): the name cell draws through the borrowed
-- name-font renderer and the class cell through the class renderer,
-- never one shared path.
function T.list_name_and_class_print_through_their_source_fonts()
  local graphics = recordingGraphics()
  local nameText = recordingText("name")
  local classText = recordingText("class")
  local list = {
    rows = { { absolute = 0, slot = 0, contact = "mom", label = "NAME-1", class = "CLASS-1" } },
    selected = 0,
    scrollOffset = 0,
    firstBgColor = 0,
    manual = false,
    total = 1,
    cursorVisible = false,
  }
  PokegearPhoneRenderer.draw(
    { graphics = graphics, images = stubImages(), textRenderer = classText, phoneNameTextRenderer = nameText },
    { list = list },
    {
      skin = 0,
      sprites = { phone = spriteSequences("test-sprite-") },
      foreground = "test-foreground",
      listPalette = distinctPalette(),
    }
  )
  Assert.equal(#nameText._calls, 1, "the name cell prints once through the name font")
  Assert.equal(recordedLine(nameText._calls[1]), "NAME-1", "the name cell prints the contact name")
  Assert.equal(nameText._calls[1].role, "name", "the name cell routes through the borrowed name renderer")
  Assert.equal(#classText._calls, 1, "the class cell prints once through the class font")
  Assert.equal(recordedLine(classText._calls[1]), "CLASS-1", "the class cell prints the contact class")
  Assert.equal(classText._calls[1].role, "class", "the class cell routes through the borrowed class renderer")
end

---@param record table a recorded paint operation
---@param area table pixel rect with x/y/width/height fields
---@return boolean
local function rectHitsArea(record, area)
  return record.x < area.x + area.width
    and record.x + record.width > area.x
    and record.y < area.y + area.height
    and record.y + record.height > area.y
end

---@param record table a recorded text operation
---@param area table pixel rect with x/y/width/height fields
---@return boolean
local function textHitsArea(record, area)
  return record.x >= area.x
    and record.x < area.x + area.width
    and record.y >= area.y
    and record.y < area.y + area.height
end

---@param graphics table
---@return integer contact row band fills
local function rowBandFills(graphics)
  local count = 0
  for _, record in ipairs(graphics._records) do
    if
      record.op == "rect"
      and record.mode == "fill"
      and record.x == LIST_X
      and record.width == ROW_WIDTH
      and record.height == 24
    then
      count = count + 1
    end
  end
  return count
end

-- Text draws record into their font recorder's _calls list, never the
-- graphics log, so the text counters below scan the recorders the draw
-- received.
---@param recorders table[] text recorders exposing _calls lists
---@return integer palette text draws inside the contact rows but outside the caller windows
local function rowTextDraws(recorders)
  local count = 0
  for _, recorder in ipairs(recorders) do
    for _, record in ipairs(recorder._calls or {}) do
      if
        record.plain == false
        and textHitsArea(record, LIST_BAND)
        and not textHitsArea(record, SPEECH_WINDOW)
        and not textHitsArea(record, NAME_WINDOW)
      then
        count = count + 1
      end
    end
  end
  return count
end

---@param recorders table[] text recorders exposing _calls lists
---@return integer palette text draws inside the caller windows
local function callTextDraws(recorders)
  local count = 0
  for _, recorder in ipairs(recorders) do
    for _, record in ipairs(recorder._calls or {}) do
      if textHitsArea(record, SPEECH_WINDOW) or textHitsArea(record, NAME_WINDOW) then
        count = count + 1
      end
    end
  end
  return count
end

---@param graphics table
---@param pathPrefix string staged sprite path prefix of the dimmed set
---@return table paint records for the fast-forward sequence
local function fastForwardPaints(graphics, pathPrefix)
  local paints = {}
  for _, record in ipairs(graphics._records) do
    if
      (record.op == "image" or record.op == "quad")
      and type(record.path) == "string"
      and record.path:find(pathPrefix .. FAST_FORWARD_SEQUENCE .. "-", 1, true) ~= nil
    then
      paints[#paints + 1] = record
    end
  end
  return paints
end

---@param graphics table
---@return string? staged path of the drawn lower plane
local function drawnLowerPlane(graphics)
  for _, record in ipairs(graphics._records) do
    if
      record.op == "image"
      and type(record.path) == "string"
      and record.path:find("test-foreground", 1, true) ~= nil
    then
      return record.path
    end
  end
  return nil
end

-- The lower surface keeps the contact list during a live call: the same
-- row bands and row text paint from the dimmed palette, the dimmed
-- lower plane composes underneath, the fast-forward sprite paints at
-- its source position, and no caller window leaks below.
function T.lower_list_survives_the_live_call_with_dim_and_sprite()
  local graphics = recordingGraphics()
  local nameText = recordingText("name")
  local classText = recordingText("class")
  PokegearPhoneRenderer.draw(
    { graphics = graphics, images = stubImages(), textRenderer = classText, phoneNameTextRenderer = nameText },
    browseView({ call = liveCall() }),
    contentFixture()
  )
  Assert.equal(drawnLowerPlane(graphics), "test-foreground-dim", "the live call composes the dimmed lower plane")
  Assert.isTrue(rowBandFills(graphics) > 0, "the live call keeps the contact row bands below")
  Assert.equal(bandRed(graphics, 0), (100 + 14) / 255, "the live call darkens the row bands from the dimmed palette")
  Assert.isTrue(rowTextDraws({ nameText, classText }) > 0, "the live call keeps the contact row text below")
  -- Caller windows use their own exact fills (72x16 name, 216x32
  -- speech), distinct from the 216x24 row bands, so their absence
  -- proves no call surface leaks below even where row text overlaps
  -- the window rects.
  local windowFills = 0
  for _, record in ipairs(graphics._records) do
    if record.op == "rect" and record.mode == "fill" then
      if
        (
          record.x == NAME_WINDOW.x
          and record.y == NAME_WINDOW.y
          and record.width == NAME_WINDOW.width
          and record.height == NAME_WINDOW.height
        )
        or (
          record.x == SPEECH_WINDOW.x
          and record.y == SPEECH_WINDOW.y
          and record.width == SPEECH_WINDOW.width
          and record.height == SPEECH_WINDOW.height
        )
      then
        windowFills = windowFills + 1
      end
    end
  end
  Assert.equal(windowFills, 0, "no caller window leaks onto the lower surface")
  local paints = fastForwardPaints(graphics, "test-sprite-dim-")
  Assert.isTrue(#paints > 0, "the live call paints the dimmed fast-forward sprite")
  for _, paint in ipairs(paints) do
    Assert.equal(
      paint.x,
      FAST_FORWARD_SOURCE.x - 120,
      "the fast-forward sprite keeps its source x through its compiled anchor"
    )
    Assert.equal(
      paint.y,
      FAST_FORWARD_SOURCE.y - 24,
      "the fast-forward sprite keeps its source y through its compiled anchor"
    )
  end
  local brightPaints = fastForwardPaints(graphics, "test-sprite-")
  local dimOnly = 0
  for _, paint in ipairs(brightPaints) do
    local isDim = false
    for _, dim in ipairs(paints) do
      if dim.path == paint.path then
        isDim = true
      end
    end
    if not isDim then
      dimOnly = dimOnly + 1
    end
  end
  Assert.equal(dimOnly, 0, "the live call sprite paints from the dimmed set, never the bright one")
end

-- The upper surface paints the static plane alone while browsing: no
-- row bands, no row text, no caller windows.
function T.upper_browse_paints_no_rows_or_call_windows()
  local graphics = recordingGraphics()
  local nameText = recordingText("name")
  local classText = recordingText("class")
  PokegearPhoneRenderer.drawInformation(
    { graphics = graphics, images = stubImages(), textRenderer = classText, phoneNameTextRenderer = nameText },
    browseView(),
    contentFixture()
  )
  local plane = nil
  for _, record in ipairs(graphics._records) do
    if record.op == "image" and record.path == "test-upper" then
      plane = record.path
    end
  end
  Assert.equal(plane, "test-upper", "the browse information paints its static upper plane")
  Assert.equal(rowBandFills(graphics), 0, "the browse information never paints contact row bands")
  Assert.equal(rowTextDraws({ nameText, classText }), 0, "the browse information never paints contact row text")
  Assert.equal(callTextDraws({ nameText, classText }), 0, "the browse information never paints caller windows")
end

-- The upper surface paints only the caller windows during a live call:
-- the name and speech windows fill from the window palette, both lines
-- print through the class font at the window-local origin, and no
-- contact row ever appears above.
function T.upper_call_paints_only_the_caller_windows()
  local graphics = recordingGraphics()
  local nameText = recordingText("name")
  local classText = recordingText("class")
  PokegearPhoneRenderer.drawInformation(
    { graphics = graphics, images = stubImages(), textRenderer = classText, phoneNameTextRenderer = nameText },
    browseView({ call = liveCall() }),
    contentFixture()
  )
  Assert.equal(rowBandFills(graphics), 0, "the call information never paints contact row bands")
  Assert.equal(rowTextDraws({ nameText, classText }), 0, "the call information never paints contact row text")
  -- Palette index 0 is the transparent pen on the SUB_2 windows: the
  -- static upper plane already carries the message box art, so the
  -- caller windows paint text only and never fill their rects.
  for _, record in ipairs(graphics._records) do
    if record.op == "rect" and record.mode == "fill" then
      Assert.isTrue(
        not (
            record.x == NAME_WINDOW.x
            and record.y == NAME_WINDOW.y
            and record.width == NAME_WINDOW.width
            and record.height == NAME_WINDOW.height
          ),
        "the call name window paints no opaque fill"
      )
      Assert.isTrue(
        not (
            record.x == SPEECH_WINDOW.x
            and record.y == SPEECH_WINDOW.y
            and record.width == SPEECH_WINDOW.width
            and record.height == SPEECH_WINDOW.height
          ),
        "the call speech window paints no opaque fill"
      )
    end
  end
  Assert.isTrue(callTextDraws({ nameText, classText }) > 0, "the call information paints the caller name and speech")
  Assert.equal(#nameText._calls, 0, "no call line borrows the name font")
  local byLine = {}
  for _, line in ipairs(classText._calls) do
    byLine[line.line] = line
  end
  local nameLine = assert(byLine["MOM"], "the caller name prints through the class font")
  Assert.equal(nameLine.x, NAME_WINDOW.x, "the caller name prints at the window-local x origin")
  Assert.equal(nameLine.y, NAME_WINDOW.y, "the caller name prints at the window-local y origin")
  local speechLine = assert(byLine["hello"], "the call speech prints through the class font")
  Assert.equal(speechLine.x, SPEECH_WINDOW.x, "the call speech prints at the window-local x origin")
  Assert.equal(speechLine.y, SPEECH_WINDOW.y, "the call speech prints at the window-local y origin")
end

-- The in-call choice menu is a synthetic detached projection: the lower
-- surface swaps to the choice-dimmed plane (menu banks bright again),
-- hides the fast-forward sprite, and frames the menu through the shared
-- tiles. No source choice identity is required to paint it.
function T.choice_menu_uses_the_choice_plane_and_hides_the_sprite()
  local graphics = recordingGraphics()
  function graphics.newQuad(_, _, _, _, _, _, _)
    return {}
  end
  local menu = {
    options = { "first", "second" },
    cursor = 0,
    frame = { x = 7, y = 11, width = 22, height = 7 },
  }
  PokegearPhoneRenderer.draw(
    { graphics = graphics, images = stubImages(), textRenderer = recordingText("class") },
    browseView({ call = liveCall(), callMenu = menu }),
    contentFixture()
  )
  Assert.equal(
    drawnLowerPlane(graphics),
    "test-foreground-dim-choice",
    "the open choice composes the choice-dimmed lower plane"
  )
  Assert.equal(#fastForwardPaints(graphics, "test-sprite-dim-"), 0, "the open choice hides the fast-forward sprite")
  Assert.equal(#fastForwardPaints(graphics, "test-sprite-"), 0, "the open choice draws no bright sprite either")
  local framePaints = 0
  for _, record in ipairs(graphics._records) do
    if (record.op == "image" or record.op == "quad") and record.path == "menu-tiles" then
      framePaints = framePaints + 1
    end
  end
  Assert.isTrue(framePaints > 0, "the choice menu frames through the shared menu tiles")
  Assert.isTrue(rowBandFills(graphics) > 0, "the choice menu keeps the dimmed contact rows behind it")
end

-- Ending the call restores the browse look: the bright plane composes
-- again with bright row bands, and the sprite disappears with the
-- conversation.
function T.call_end_restores_bright_planes()
  local graphics = recordingGraphics()
  PokegearPhoneRenderer.draw(
    { graphics = graphics, images = stubImages(), textRenderer = stubText() },
    browseView(),
    contentFixture()
  )
  Assert.equal(drawnLowerPlane(graphics), "test-foreground", "the settled list composes the bright lower plane")
  Assert.equal(bandRed(graphics, 0), 14 / 255, "the settled list restores the bright row bands")
  Assert.equal(#fastForwardPaints(graphics, "test-sprite-dim-"), 0, "the settled list draws no dimmed sprite")
  Assert.equal(#fastForwardPaints(graphics, "test-sprite-"), 0, "the settled list draws no fast-forward sprite")
  local upper = recordingGraphics()
  local settledText = recordingText("class")
  PokegearPhoneRenderer.drawInformation(
    { graphics = upper, images = stubImages(), textRenderer = settledText },
    browseView(),
    contentFixture()
  )
  Assert.equal(callTextDraws({ settledText }), 0, "the settled information drops the caller windows")
end

-- Dimming never paints a whole-surface black mask: every lower fill
-- stays inside a source window, row, or menu rect, and the caller text
-- keeps its exact window palette colors undimmed above.
function T.dimming_never_paints_a_fullscreen_mask()
  local graphics = recordingGraphics()
  PokegearPhoneRenderer.draw(
    { graphics = graphics, images = stubImages(), textRenderer = stubText() },
    browseView({ call = liveCall() }),
    contentFixture()
  )
  for _, record in ipairs(graphics._records) do
    if record.op == "rect" and record.mode == "fill" then
      Assert.isTrue(not (record.width == 256 and record.height == 192), "no lower fill covers the whole surface")
    end
  end
  local upper = recordingGraphics()
  local classText = recordingText("class")
  PokegearPhoneRenderer.drawInformation(
    { graphics = upper, images = stubImages(), textRenderer = classText, phoneNameTextRenderer = recordingText("name") },
    browseView({ call = liveCall() }),
    contentFixture()
  )
  for _, line in ipairs(classText._calls) do
    Assert.equal(line.palette.foreground.r, 100 + 1, "the undimmed caller text keeps its window foreground")
    Assert.equal(line.palette.shadow.r, 100 + 2, "the undimmed caller text keeps its window shadow")
    Assert.equal(line.palette.background.a, 0, "the undimmed caller text keeps a transparent background pen")
  end
end

-- The full-strip tooltip bar (y160..192, palette 10) behind the prompt
-- centered in the 3/2/5 combination.
local TOOLTIP_STRIP = { x = 0, y = 160, width = 256, height = 32 }

function T.tooltip_paints_its_strip_behind_centered_text()
  local graphics = recordingGraphics()
  local text = recordingText("class", 100)
  local list = {
    rows = settledRows(6),
    selected = 0,
    scrollOffset = 0,
    firstBgColor = 0,
    manual = false,
    total = 6,
    cursorVisible = false,
  }
  PokegearPhoneRenderer.draw(
    { graphics = graphics, images = stubImages(), textRenderer = text },
    { list = list, tooltip = "tip" },
    {
      skin = 0,
      sprites = { phone = spriteSequences("test-sprite-") },
      foreground = "test-foreground",
      listPalette = distinctPalette(),
      tooltipPalette = distinctPalette(),
    }
  )
  local strip = nil
  for _, fill in ipairs(graphics._records) do
    if
      fill.op == "rect"
      and fill.x == TOOLTIP_STRIP.x
      and fill.y == TOOLTIP_STRIP.y
      and fill.width == TOOLTIP_STRIP.width
      and fill.height == TOOLTIP_STRIP.height
    then
      strip = fill
    end
  end
  Assert.notNil(strip, "the tooltip paints its windows[3] strip")
  assert(strip ~= nil, "the tooltip strip painted above")
  Assert.equal(strip.color.r, 5 / 255, "the strip fills with palette index 5")
  local prompt = nil
  for _, line in ipairs(text._calls) do
    if line.line == "tip" then
      prompt = line
    end
  end
  Assert.notNil(prompt, "the tooltip prints its prompt")
  assert(prompt ~= nil, "the tooltip prompt printed above")
  Assert.equal(prompt.x, 78, "the prompt centers in the surface")
  Assert.equal(prompt.y, 168, "the prompt prints at the strip top")
  Assert.equal(prompt.palette.foreground.r, 3, "the prompt foreground is palette index 3")
  Assert.equal(prompt.palette.shadow.r, 2, "the prompt shadow is palette index 2")
  Assert.equal(prompt.palette.background.r, 5, "the prompt background is palette index 5")
end

-- The context menu keeps tile geometry end-to-end: sContextMenuParam
-- tiles reach the shared list-menu frame with no pixel round-trip, so
-- width 16 frames the interior sixteen tiles (eighteen total).
function T.context_menu_frame_stays_in_tiles()
  local graphics = recordingGraphics()
  function graphics.newQuad(_, _, _, _, _, _, _)
    return {}
  end
  local tileDraws = {}
  local lease = {
    image = {
      getDimensions = function()
        return 256, 16
      end,
    },
    drawQuad = function(_, _, _, x, y)
      tileDraws[#tileDraws + 1] = { x = x, y = y }
    end,
  }
  local images = stubImages()
  images["menu-tiles"] = lease
  local text = recordingText("class", 40)
  local list = {
    rows = settledRows(6),
    selected = 0,
    scrollOffset = 0,
    firstBgColor = 0,
    manual = false,
    total = 6,
    cursorVisible = false,
  }
  PokegearPhoneRenderer.draw({
    graphics = graphics,
    images = images,
    textRenderer = text,
  }, {
    list = list,
    contextMenu = {
      options = { "a", "b", "c" },
      cursor = 0,
      frame = { x = 13, y = 9, width = 16, height = 10 },
    },
  }, {
    skin = 0,
    sprites = { phone = spriteSequences("test-sprite-") },
    foreground = "test-foreground",
    listPalette = distinctPalette(),
    menuTiles = "menu-tiles",
    menuPalette = distinctPalette(),
  })
  local topLeft = nil
  for _, tile in ipairs(tileDraws) do
    if tile.x == 13 * 8 and tile.y == 9 * 8 then
      topLeft = tile
    end
  end
  Assert.notNil(topLeft, "the frame paints its top-left tile at the tile origin")
  local entry = nil
  for _, fill in ipairs(graphics._records) do
    if fill.op == "rect" and fill.x == 14 * 8 and fill.y == 13 * 8 and fill.width == 128 and fill.height == 16 then
      entry = fill
    end
  end
  Assert.notNil(entry, "the deselected entry fills inside the tile frame")
  assert(entry ~= nil, "the deselected entry filled above")
  Assert.equal(entry.color.r, 3 / 255, "the deselected entry fills with palette index 3")
end

-- The scrolled list viewport clips to the plane frame interior: the
-- MAIN_2 plane covers the window's top 16px scroll offset and its left
-- 5px behind the frame, so rows paint at screen y8 behind a
-- x13/y5/211x152 clip instead of the bare window origin.
function T.list_viewport_clips_to_the_plane_frame_interior()
  local graphics = recordingGraphics()
  drawLowerList(graphics, 0)
  local clip = nil
  for _, record in ipairs(graphics._records) do
    if record.op == "scissor" and record.x == 13 and record.y == 5 and record.width == 211 and record.height == 152 then
      clip = record
    end
  end
  Assert.notNil(clip, "the list viewport clips to the frame interior x13/y5/211x152")
end

-- Manual-move chevrons track the selected row at the source sprite
-- position: the 32px chevron centers on the row's source center, so
-- with the scrolled rows the selected chevron paints through its
-- compiled anchor from (12, 16) for the first slot.
function T.manual_move_chevrons_track_their_source_positions()
  local graphics = recordingGraphics()
  local list = {
    rows = settledRows(2),
    selected = 0,
    scrollOffset = 0,
    firstBgColor = 0,
    manual = true,
    total = 2,
    cursorVisible = false,
  }
  PokegearPhoneRenderer.draw(
    { graphics = graphics, images = stubImages(), textRenderer = stubText() },
    { list = list },
    {
      skin = 0,
      sprites = { phone = spriteSequences("test-sprite-") },
      foreground = "test-foreground",
      listPalette = distinctPalette(),
    }
  )
  local paint = nil
  for _, record in ipairs(graphics._records) do
    if record.op == "image" and record.path == "test-sprite-8-1.png" then
      paint = record
    end
  end
  Assert.notNil(paint, "the selected row paints its selected chevron")
  assert(paint ~= nil, "the chevron painted above")
  Assert.equal(paint.x, 12 - 8, "the chevron centers on the source x through its anchor")
  Assert.equal(paint.y, 16 - 8, "the chevron centers on the scrolled row through its anchor")
end

---@param role string the font role the renderer must route through
---@param charWidth number measured width per character cell
---@return table stub text renderer measuring advance per character
local function measuringText(role, charWidth)
  local calls = {}
  return {
    role = role,
    textWidth = function(_, line)
      return #tostring(line) * charWidth
    end,
    drawTextWithPalette = function(self, line, x, y, palette)
      calls[#calls + 1] = { role = self.role, plain = false, line = line, x = x, y = y, palette = palette }
    end,
    _calls = calls,
  }
end

-- Source line breaks become window rows: the speech page prints each
-- source line on its own 16px row from the speech origin instead of
-- concatenating them into one clipped line.
function T.call_speech_breaks_source_lines_into_window_rows()
  local graphics = recordingGraphics()
  local classText = recordingText("class")
  local call = liveCall()
  call.lines = { { text = "first\nsecond" } }
  call.page = 1
  PokegearPhoneRenderer.drawInformation(
    { graphics = graphics, images = stubImages(), textRenderer = classText },
    browseView({ call = call }),
    contentFixture()
  )
  local rows = {}
  for _, line in ipairs(classText._calls) do
    if line.line == "first" or line.line == "second" then
      rows[#rows + 1] = line
    end
  end
  Assert.equal(#rows, 2, "both source lines print")
  Assert.equal(rows[1].x, SPEECH_WINDOW.x, "the first row prints at the speech x origin")
  Assert.equal(rows[1].y, SPEECH_WINDOW.y, "the first row prints at the speech y origin")
  Assert.equal(rows[2].x, SPEECH_WINDOW.x, "the second row prints at the speech x origin")
  Assert.equal(rows[2].y, SPEECH_WINDOW.y + 16, "the second row prints one text row below")
end

-- Long speech rows wrap inside the 216px speech window instead of
-- running past its edge: the wrapped rows rejoin to the source row.
function T.call_speech_wraps_long_rows_inside_its_window()
  local graphics = recordingGraphics()
  local classText = measuringText("class", 10)
  local call = liveCall()
  call.lines = { { text = "aaa bbb ccc ddd eee fff ggg" } }
  call.page = 1
  PokegearPhoneRenderer.drawInformation(
    { graphics = graphics, images = stubImages(), textRenderer = classText },
    browseView({ call = call }),
    contentFixture()
  )
  local speech = {}
  for _, line in ipairs(classText._calls) do
    if line.y >= SPEECH_WINDOW.y then
      speech[#speech + 1] = line
    end
  end
  Assert.isTrue(#speech >= 2, "an overlong row wraps instead of clipping")
  local joined = {}
  for _, line in ipairs(speech) do
    Assert.isTrue(line.x >= SPEECH_WINDOW.x, "wrapped rows stay inside the speech window")
    Assert.isTrue(line.x < SPEECH_WINDOW.x + SPEECH_WINDOW.width, "wrapped rows start inside the speech window")
    Assert.isTrue(#line.line * 10 <= SPEECH_WINDOW.width, "no wrapped row overruns the speech width")
    joined[#joined + 1] = line.line
  end
  Assert.equal(table.concat(joined, " "), "aaa bbb ccc ddd eee fff ggg", "the wrapped rows rejoin to the source row")
end

-- Call text types behind the reveal count: only the revealed glyph
-- prefix of the page prints, with source breaks intact, while a page
-- past its total prints whole.
function T.call_speech_types_behind_the_reveal_count()
  local graphics = recordingGraphics()
  local classText = recordingText("class")
  local tokens = {}
  for index = 1, 5 do
    tokens[#tokens + 1] = { kind = "glyph", code = index, text = ("hello"):sub(index, index), raw = { index } }
  end
  local call = liveCall()
  call.lines = { { text = "hello", tokens = tokens } }
  call.page = 1
  call.revealed = 2
  call.total = 5
  PokegearPhoneRenderer.drawInformation(
    { graphics = graphics, images = stubImages(), textRenderer = classText },
    browseView({ call = call }),
    contentFixture()
  )
  local speech = {}
  for _, line in ipairs(classText._calls) do
    if line.y >= SPEECH_WINDOW.y then
      speech[#speech + 1] = line
    end
  end
  Assert.equal(#speech, 1, "the typing page prints one speech row")
  Assert.equal(speech[1].line, "he", "only the revealed glyph prefix prints")
  call.revealed = 5
  local doneText = recordingText("class")
  PokegearPhoneRenderer.drawInformation(
    { graphics = graphics, images = stubImages(), textRenderer = doneText },
    browseView({ call = call }),
    contentFixture()
  )
  local doneSpeech = {}
  for _, line in ipairs(doneText._calls) do
    if line.y >= SPEECH_WINDOW.y then
      doneSpeech[#doneSpeech + 1] = line
    end
  end
  Assert.equal(#doneSpeech, 1, "a completed page prints one speech row")
  Assert.equal(doneSpeech[1].line, "hello", "a completed page prints whole")
end

-- The selected-row corners answer card focus, never the list alone:
-- while the shell strip owns focus the strip paints its own corners
-- at the focused cell, so the waiting list hides its frame instead of
-- doubling the indicator. Direct draws without a shell keep the
-- card-owned frame.
function T.list_corners_answer_card_focus_not_the_list_alone()
  local function cornerPaints(shell)
    local graphics = recordingGraphics()
    local list = {
      rows = settledRows(2),
      selected = 0,
      scrollOffset = 0,
      firstBgColor = 0,
      manual = false,
      total = 2,
      cursorVisible = true,
    }
    PokegearPhoneRenderer.draw(
      { graphics = graphics, images = stubImages(), textRenderer = stubText() },
      { list = list },
      {
        skin = 0,
        sprites = { phone = spriteSequences("test-sprite-") },
        foreground = "test-foreground",
        listPalette = distinctPalette(),
      },
      shell
    )
    for _, record in ipairs(graphics._records) do
      if
        record.op == "image"
        and (
          record.path == "test-sprite-3-1.png"
          or record.path == "test-sprite-4-1.png"
          or record.path == "test-sprite-5-1.png"
          or record.path == "test-sprite-6-1.png"
        )
      then
        return true
      end
    end
    return false
  end
  Assert.isTrue(cornerPaints(nil), "the shell-less list keeps its card-owned frame")
  Assert.isTrue(cornerPaints({ entered = true }), "the entered card frames its selected row")
  Assert.isFalse(
    cornerPaints({ entered = false }),
    "the strip-owned list hides its frame so only the strip corners show"
  )
end

return { tests = T }
