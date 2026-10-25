-- Projects Mailbox child presentation into the current display topology.
local MailboxInterface = {}

-- Mail/read geometry follows overlay_103's window records and list-menu
-- construction (`ov103_021EEEC4`, `ov103_021ECF68`, `ov103_021EE930`).
MailboxInterface.defaults = {
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
  letter = {
    author = { x = 32, y = 8 },
    lines = {
      { x = 24, y = 24, width = 208, height = 32 },
      { x = 24, y = 64, width = 208, height = 32 },
      { x = 24, y = 104, width = 208, height = 32 },
    },
  },
  confirmation = { x = 16, y = 152, width = 216, height = 32 },
  actionMenu = { x = 72, y = 40, width = 88, height = 96, rowHeight = 16 },
  -- The Yes / No pair beside the confirmation box, mirroring the
  -- Storage YES/NO rects beside its message window.
  yesNo = {
    yes = { x = 184, y = 116, width = 56, height = 24 },
    no = { x = 184, y = 144, width = 56, height = 24 },
  },
}

function MailboxInterface.plan(display, mode, manifest)
  assert(type(display) == "table", "mailbox presentation needs display facts")
  assert(mode == "mailbox" or mode == "read" or mode == "confirm", "mailbox presentation mode is explicit")
  assert(type(manifest) == "table", "mailbox presentation needs its manifest")
  return {
    mode = mode,
    width = display.width,
    height = display.height,
    topology = display.topology,
    pixelRatio = display.pixelRatio,
    pageControls = MailboxInterface.defaults.pageControls,
    cursorGrid = MailboxInterface.defaults.cursorGrid,
    mailCells = MailboxInterface.defaults.mailCells,
    closeButton = MailboxInterface.defaults.closeButton,
    letter = MailboxInterface.defaults.letter,
    confirmation = MailboxInterface.defaults.confirmation,
    actionMenu = MailboxInterface.defaults.actionMenu,
    yesNo = MailboxInterface.defaults.yesNo,
  }
end

local function hitRect(rect, x, y)
  return x >= rect.x and x < rect.x + rect.width and y >= rect.y and y < rect.y + rect.height
end

function MailboxInterface.events(plan, events, phase)
  local routed = {}
  for _, event in ipairs(events) do
    if event.type == "pointer_down" or event.type == "touch" then
      local x, y = event.x, event.y
      -- YesNoPrompt answers on the confirm box: YES confirms, NO
      -- declines, matching the retained confirm=yes key semantics.
      if phase == "confirm" and plan.yesNo ~= nil then
        if hitRect(plan.yesNo.yes, x, y) then
          routed[#routed + 1] = { type = "confirm" }
        elseif hitRect(plan.yesNo.no, x, y) then
          routed[#routed + 1] = { type = "cancel" }
        end
      else
        local previous = plan.pageControls.previous
        local nextPage = plan.pageControls.next
        local target
        if hitRect(previous, x, y) then
          target = "previous"
        elseif hitRect(nextPage, x, y) then
          target = "next"
        end
        if target ~= nil then
          routed[#routed + 1] = { type = "page", direction = target }
        elseif phase == "list" and plan.mailCells ~= nil then
          -- Retail touch selects through the grid hitboxes: tapping a
          -- mail cell moves the cursor there (GridOnTouch), tapping
          -- CLOSE reports input 10. The state resolves occupancy.
          local tapped = false
          for input, cell in ipairs(plan.mailCells) do
            if hitRect(cell, x, y) then
              routed[#routed + 1] = { type = "grid", input = input - 1 }
              tapped = true
              break
            end
          end
          if not tapped and plan.closeButton ~= nil and hitRect(plan.closeButton, x, y) then
            routed[#routed + 1] = { type = "grid", input = 10 }
          end
        elseif phase == "viewer" and plan.closeButton ~= nil and hitRect(plan.closeButton, x, y) then
          -- The read view closes through the same CLOSE hitbox retail
          -- checks in MailboxApp_IsCloseMailInput.
          routed[#routed + 1] = { type = "cancel" }
        end
      end
    else
      routed[#routed + 1] = event
    end
  end
  return routed
end

return MailboxInterface
