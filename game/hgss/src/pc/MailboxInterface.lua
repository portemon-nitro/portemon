-- Owns the retail Mailbox list geometry and fits its native 256x192
-- surface into the current display. The list, the action menu, the yes/no
-- prompts, and the read letter are one screen here: every mode resolves a
-- single interactive pane, so the interface is scaled, centered, and framed
-- like the other PC applications instead of drawing at raw host origin.

local ApplicationLayout = require("libs.ui.src.ApplicationLayout")
local LogicalSurface = require("libs.ui.src.LogicalSurface")
local NativeDisplay = require("libs.ui.src.NativeDisplay")

local MailboxInterface = {}

local DISPLAY = { id = "mailbox", width = NativeDisplay.WIDTH, height = NativeDisplay.HEIGHT }
local ZERO_CROP = { left = 0, right = 0, top = 0, bottom = 0 }

-- Mail/read geometry follows overlay_103's window records and list-menu
-- construction (`ov103_021EEEC4`, `ov103_021ECF68`, `ov103_021EE930`).
MailboxInterface.geometry = {
  pageControls = {
    -- The retained hitboxes center on the retail page-arrow anchors
    -- (24,176)/(56,176): the compiled arrow frames draw centered on
    -- these boxes and hide per side at the page ends.
    previous = { x = 8, y = 160, width = 32, height = 32 },
    next = { x = 40, y = 160, width = 32, height = 32 },
  },
  -- Retail cursor grid (MoveCursor :1594-1601, MoveCursorToCloseButton
  -- :1353-1356), mirroring PcSources.mailboxSpriteRoles.cursorGrid
  -- locally because runtime packages must not import romdump: inputs
  -- 0-9 are the mail cells at x 64/192, y 16+32k; input 10 is CLOSE
  -- at (224,176) and selects cursor anim 4, every other input anim 5.
  -- Cells are 1-based so cells[inputId + 1] is the input's anchor.
  -- Each cell anchor is the center of its nameplate cell: columns at
  -- tile x 1/17 (px 8/136) with width 14 tiles (112 px), rows at tile
  -- y 4k (px 32k) with height 4 tiles (32 px).
  cursorGrid = {
    closeInput = 10,
    cells = {
      { x = 64, y = 16 },
      { x = 192, y = 16 },
      { x = 64, y = 48 },
      { x = 192, y = 48 },
      { x = 64, y = 80 },
      { x = 192, y = 80 },
      { x = 64, y = 112 },
      { x = 192, y = 112 },
      { x = 64, y = 144 },
      { x = 192, y = 144 },
      { x = 224, y = 176 },
    },
  },
  -- Decoded gMailboxGridHitboxes touch bytes (top, bottom, left, right):
  -- rows span y 0x00-0x1F, 0x20-0x3F, 0x40-0x5F, 0x60-0x7F, 0x80-0x9F;
  -- the left column spans x 0x08-0x77, the right column x 0x88-0xF4;
  -- CLOSE spans y 0xA0-0xBF, x 0xC0-0xFF. Retail hit-tests these
  -- rectangles, so pointer selection follows the same 11-cell grid.
  mailCells = {
    { x = 8, y = 0, width = 112, height = 32 },
    { x = 136, y = 0, width = 109, height = 32 },
    { x = 8, y = 32, width = 112, height = 32 },
    { x = 136, y = 32, width = 109, height = 32 },
    { x = 8, y = 64, width = 112, height = 32 },
    { x = 136, y = 64, width = 109, height = 32 },
    { x = 8, y = 96, width = 112, height = 32 },
    { x = 136, y = 96, width = 109, height = 32 },
    { x = 8, y = 128, width = 112, height = 32 },
    { x = 136, y = 128, width = 109, height = 32 },
  },
  closeButton = { x = 192, y = 160, width = 64, height = 32 },
  -- The framed message box (window template 24: MAIN_0, 2, 19, 27x4):
  -- erase prompts, hold prompts, erase results, and the action-menu
  -- question all print here.
  confirmation = { x = 16, y = 152, width = 216, height = 32 },
  -- The action menu is the shared touchscreen list menu
  -- (MailboxApp_OpenMailMenu): 11 middle tiles framed from tile column 18,
  -- which the four actions start at tile row 5 and the two-action variant
  -- (empty party) starts at tile row 11. Retail highlights only the frame
  -- at the cursor.
  actionMenu = { x = 18, y = 5, width = 11, emptyPartyY = 11 },
  -- The Yes / No pair beside the confirmation box, mirroring the
  -- Storage YES/NO rects beside its message window.
  yesNo = {
    yes = { x = 184, y = 116, width = 56, height = 24 },
    no = { x = 184, y = 144, width = 56, height = 24 },
  },
}

local function hitRect(rect, x, y)
  return x >= rect.x and x < rect.x + rect.width and y >= rect.y and y < rect.y + rect.height
end

local function render(resources, view, plan)
  local renderer = assert(resources.mailboxRenderer, "Mailbox presentation borrows its owned renderer")
  local graphics = assert(resources.graphics, "Mailbox drawing borrows the host graphics namespace")
  local geometry = assert(plan.content.geometry, "Mailbox plans carry their geometry")
  for _, pane in ipairs(plan.panes) do
    LogicalSurface.draw(graphics, pane.placement, function()
      renderer:draw(view, resources, geometry)
    end)
  end
end

-- Projects one already-placed logical press: the confirmation pair
-- answers on the prompt, page arrows page, the mail grid selects its cell
-- (CLOSE reports input 10), and the read leaf closes on any press.
---@param event table<string, unknown>
---@param view table<string, unknown>
---@param plan table<string, unknown>
---@return table<string, unknown>?
local function mapInput(event, view, plan)
  if event.type ~= "pointer_down" and event.type ~= "touch" then
    return event
  end
  local geometry = plan.content.geometry
  if event.outside == true or type(event.x) ~= "number" or type(event.y) ~= "number" then
    return nil
  end
  if view.viewMode == "read" then
    return { type = "close", source = "touch" }
  end
  local x, y = event.x, event.y
  if view.phase == "confirm" then
    if hitRect(geometry.yesNo.yes, x, y) then
      return { type = "confirm" }
    end
    if hitRect(geometry.yesNo.no, x, y) then
      return { type = "cancel" }
    end
    return nil
  end
  -- Only the list services its own controls: the action menu, the prompts,
  -- and the read letter never page or reselect behind their own screen.
  if view.phase ~= "list" then
    return nil
  end
  if hitRect(geometry.pageControls.previous, x, y) then
    return { type = "page", direction = "previous" }
  end
  if hitRect(geometry.pageControls.next, x, y) then
    return { type = "page", direction = "next" }
  end
  for index, cell in ipairs(geometry.mailCells) do
    if hitRect(cell, x, y) then
      return { type = "grid", input = index - 1 }
    end
  end
  if hitRect(geometry.closeButton, x, y) then
    return { type = "grid", input = 10 }
  end
  return nil
end

-- Fits the native surface as the one interactive pane: every Mailbox
-- mode is one 256x192 screen here, so a wide, tall, or dual-display host
-- frames the same application instead of splitting the list and the
-- letter across screens.
---@param context ApplicationLayout.Context
---@param view table<string, unknown>
---@return table<string, unknown>
local function fit(context, view)
  local layout = ApplicationLayout.coverOrFrame(context, DISPLAY, { maxOverdraw = ZERO_CROP })
  local pane = layout.placements[DISPLAY.id]
  local mode = assert(view.mode, "Mailbox plans carry their mode")
  if pane == nil then
    return {
      panes = {},
      frames = layout.frames or {},
      content = { mode = mode, geometry = MailboxInterface.geometry },
      inputKey = "mailbox-inactive",
      render = render,
      mapInput = mapInput,
    }
  end
  return {
    panes = { { id = DISPLAY.id, placement = pane, interactive = true } },
    frames = layout.frames or {},
    content = { mode = mode, geometry = MailboxInterface.geometry },
    inputKey = "mailbox",
    render = render,
    mapInput = mapInput,
  }
end

-- The Mailbox presents one fitted native surface: unlike the Storage and
-- MailView pairs, its list, prompts, and read letter never split across
-- two displays, so every classification resolves the same resolver.
---@return table<string, fun(context: ApplicationLayout.Context, view: table<string, unknown>): table<string, unknown>>
function MailboxInterface.defaults()
  return { dualDisplay = fit, nativeLike = fit, wide = fit, tall = fit }
end

return MailboxInterface
