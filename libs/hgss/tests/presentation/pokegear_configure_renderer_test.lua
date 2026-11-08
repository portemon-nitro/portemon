-- The setup card's focus cursor answers card focus, never the card alone:
-- while the shell strip owns focus the strip paints its own corners at
-- the focused cell, so the waiting setup card hides its cursor instead
-- of doubling the indicator. Direct draws without a shell keep the
-- historical card-owned frame.

local Assert = require("tests.support.Assert")
local PokegearConfigureRenderer = require("libs.hgss.src.presentation.PokegearConfigureRenderer")

local T = {
  metadata = {
    tags = { "pokegear" },
  },
  tests = {},
}

---@return table fake graphics recording corner sprite draws
local function recordingGraphics()
  local records = {}
  local graphics = {
    _records = records,
  }
  function graphics.setColor(_, _, _, _) end
  function graphics.rectangle(_, _, _, _, _) end
  function graphics.newQuad(_, _, _, _, _, _)
    return {}
  end
  return graphics --[[@as table]]
end

---@param graphics table the recording graphics namespace
---@param path string the staged image path behind the lease
---@return table lease recording its draws
local function recordingLease(graphics, path)
  return {
    draw = function(_, _, _, _)
      local records = graphics._records --[[@as table]]
      records[#records + 1] = path
    end,
  }
end

---@param graphics table the recording graphics namespace
---@return table images, table content the stub image set and plan payload
local function stubImages(graphics)
  local images = {}
  images["test-background"] = recordingLease(graphics, "test-background")
  local sprites = { configure = {} }
  for sequence = 1, 4 do
    local path = "test-corner-" .. sequence .. ".png"
    images[path] = recordingLease(graphics, path)
    sprites.configure[sequence] = {
      frames = {
        { image = path, width = 16, height = 16, anchorX = 0, anchorY = 0 },
      },
    }
  end
  local content = {
    configureForeground = "test-background",
    configureSprites = sprites,
  }
  return images, content
end

---@return table childView a detached setup view with the cursor on skin zero
local function setupView()
  local thumbnails = {}
  for skin = 0, 5 do
    thumbnails[skin] = { x = 24, y = 24, width = 48, height = 40 }
  end
  return {
    thumbnails = thumbnails,
    selectedSkin = 0,
    cursor = 0,
    menu = nil,
    menuOptions = nil,
    spotlight = nil,
  }
end

---@param shell table<string, unknown>? the shell snapshot carrying strip focus, when composed
---@return boolean whether the setup cursor corners painted
local function cursorPaints(shell)
  local graphics = recordingGraphics()
  local images, content = stubImages(graphics)
  PokegearConfigureRenderer.drawPane(
    graphics,
    images,
    nil,
    content,
    setupView(),
    { 0, 1, 2, 3, 4, 5 },
    shell
  )
  for _, path in ipairs(graphics._records) do
    if type(path) == "string" and path:find("test-corner-", 1, true) == 1 then
      return true
    end
  end
  return false
end

function T.tests.setup_cursor_answers_card_focus_not_the_card_alone()
  Assert.isTrue(cursorPaints(nil), "the shell-less setup card keeps its card-owned cursor")
  Assert.isTrue(cursorPaints({ entered = true }), "the entered setup card frames its focused cell")
  Assert.isFalse(cursorPaints({ entered = false }), "the strip-owned setup card hides its cursor")
end

-- The open context menu frames its options from the ROM list-menu tile
-- strip with palette text, exactly like every other framed app menu,
-- instead of invented fills and borders.
function T.tests.setup_menu_frames_from_rom_tiles()
  local graphics = recordingGraphics()
  local images, content = stubImages(graphics)
  local quadTiles = {}
  images["test-menu-tiles"] = {
    image = {
      getDimensions = function()
        return 256, 16
      end,
    },
    drawQuad = function(_, _, quad, _, _)
      quadTiles[#quadTiles + 1] = quad
    end,
    draw = function(_, _, _, _)
      local records = graphics._records --[[@as table]]
      records[#records + 1] = "test-menu-tiles"
    end,
  }
  local palette = {}
  for index = 1, 16 do
    palette[index] = { r = index * 16, g = index * 16, b = index * 16 }
  end
  content.menuTiles = "test-menu-tiles"
  content.menuPalette = palette
  local printed = {}
  local text = {
    drawTextWithPalette = function(_, line, _, _, _)
      printed[#printed + 1] = line
    end,
    textWidth = function(_, line)
      return #line * 8
    end,
  }
  local view = setupView()
  view.menu = { x = 80, y = 16, width = 64, height = 56 }
  view.frame = { x = 10, y = 2, width = 6 }
  view.menuOptions = { labels = { "CHANGE", "QUIT" }, cursor = 0 }
  view.spotlight = {}
  PokegearConfigureRenderer.drawPane(graphics, images, text, content, view, { 0, 1, 2, 3, 4, 5 }, {
    entered = true,
  })
  Assert.isTrue(#quadTiles > 0, "the menu frame paints from the ROM tile strip")
  Assert.deepEqual(printed, { "CHANGE", "QUIT" }, "the menu prints its options through the palette text")
end

return T
