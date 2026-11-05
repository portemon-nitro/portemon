-- Failure-policy and window-palette contracts for the phone renderer:
-- a missing foreground plane fails loudly instead of painting a silent
-- skin fill, a missing upper plane fails loudly instead of painting
-- nothing, and the call speech/name windows print through the dedicated
-- window palette instead of reusing the list palette. Pure presentation
-- mapping with asset-less fixture content: no love globals, borrowed
-- collaborators only.

local Assert = require("tests.support.Assert")
local PokegearPhoneRenderer = require("libs.hgss.src.presentation.PokegearPhoneRenderer")

local T = {}

local LIST_X = 8
local ROW_WIDTH = 216
local NAME_WINDOW = { x = 32, y = 128, width = 72, height = 16 }

---@return table fake graphics recording fills
local function recordingGraphics()
  local fills = {}
  local graphics = {}
  function graphics.setColor(r, g, b, a)
    graphics._color = { r = r, g = g, b = b, a = a }
  end
  function graphics.rectangle(mode, x, y, width, height)
    fills[#fills + 1] = { mode = mode, x = x, y = y, width = width, height = height, color = graphics._color }
  end
  function graphics.push(_)
  end
  function graphics.pop()
  end
  function graphics.origin()
  end
  function graphics.translate(_, _)
  end
  function graphics.scale(_, _)
  end
  function graphics.intersectScissor(_, _, _, _)
  end
  function graphics.transformPoint(x, y)
    return x, y
  end
  graphics._fills = fills
  return graphics --[[@as table]]
end

---@return table stub text renderer recording nothing
local function stubText()
  return {
    drawText = function(_, _, _, _)
    end,
    drawTextWithPalette = function(_, _, _, _, _)
    end,
  }
end

-- Sixteen colors with distinct red channels so fills map back to indices.
---@param base integer red-channel base
---@return table palette
local function distinctPalette(base)
  local palette = {}
  for index = 0, 15 do
    palette[index + 1] = { r = (base or 0) + index, g = 0, b = 0 }
  end
  return palette
end

---@return table settled six-row list projection
local function settledList()
  local rows = {}
  for slot = 0, 5 do
    rows[#rows + 1] = { absolute = slot, slot = slot, contact = "c" .. slot, label = "N", class = "C" }
  end
  return {
    rows = rows,
    selected = 0,
    scrollOffset = 0,
    firstBgColor = 0,
    manual = false,
    total = 6,
    cursorVisible = false,
  }
end

-- A missing foreground plane is a broken plan, never a fallback fill:
-- the draw fails loudly and names its missing plane.
function T.missing_foreground_fails_loudly()
  local graphics = recordingGraphics()
  local ok, err = pcall(
    PokegearPhoneRenderer.draw,
    { graphics = graphics, images = {}, textRenderer = stubText() },
    { list = settledList() },
    { skin = 0, sprites = {}, listPalette = distinctPalette(0) }
  )
  Assert.isFalse(ok, "a phone draw without its foreground plane fails instead of painting a fallback fill")
  Assert.isTrue(
    tostring(err):find("foreground") ~= nil,
    "the foreground failure names its missing plane, got: " .. tostring(err)
  )
end

-- A missing upper plane follows the same policy: the information pane
-- fails loudly instead of painting nothing behind the live list.
function T.missing_upper_fails_loudly()
  local graphics = recordingGraphics()
  local ok, err = pcall(
    PokegearPhoneRenderer.drawInformation,
    { graphics = graphics, images = {}, textRenderer = stubText() },
    { skin = 0, sprites = {}, listPalette = distinctPalette(0) }
  )
  Assert.isFalse(ok, "information without its upper plane fails instead of painting nothing")
  Assert.isTrue(
    tostring(err):find("upper") ~= nil,
    "the upper failure names its missing plane, got: " .. tostring(err)
  )
end

-- The call speech/name windows resolve through the dedicated window
-- palette (bank 1 of the foreground NCLR member behind the SUB_2
-- windows[0,1]), never through the list palette behind MAIN_3 windows[2].
function T.call_windows_print_through_the_window_palette()
  local graphics = recordingGraphics()
  local listPalette = distinctPalette(0)
  local windowPalette = distinctPalette(100)
  local foregroundLease = {
    draw = function(_, _, _, _)
    end,
  }
  PokegearPhoneRenderer.draw(
    { graphics = graphics, images = { ["test-foreground"] = foregroundLease }, textRenderer = stubText() },
    {
      call = {
        name = "MOM",
        lines = { { text = "hello" } },
        page = 1,
      },
    },
    {
      skin = 0,
      sprites = {},
      foreground = "test-foreground",
      listPalette = listPalette,
      windowPalette = windowPalette,
    }
  )
  local nameFill = nil
  for _, fill in ipairs(graphics._fills) do
    if
      fill.x == NAME_WINDOW.x
      and fill.y == NAME_WINDOW.y
      and fill.width == NAME_WINDOW.width
      and fill.height == NAME_WINDOW.height
    then
      nameFill = fill
    end
  end
  Assert.notNil(nameFill, "the call name window paints its fill")
  assert(nameFill ~= nil, "the name fill painted above")
  Assert.equal(
    nameFill.color.r,
    (100 + 0) / 255,
    "the name window fills with the window palette, never the list palette"
  )
end

return { tests = T }
