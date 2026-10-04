-- Projects Mailbox child presentation into the current display topology.
local MailboxInterface = {}

-- Mail/read geometry follows overlay_103's window records and list-menu
-- construction (`ov103_021EEEC4`, `ov103_021ECF68`, `ov103_021EE930`).
MailboxInterface.defaults = {
  pageControls = {
    previous = { x = 8, y = 160, width = 32, height = 32 },
    next = { x = 40, y = 160, width = 32, height = 32 },
  },
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
    letter = MailboxInterface.defaults.letter,
    confirmation = MailboxInterface.defaults.confirmation,
    actionMenu = MailboxInterface.defaults.actionMenu,
  }
end

function MailboxInterface.events(plan, events)
  local routed = {}
  for _, event in ipairs(events) do
    if event.type == "pointer_down" or event.type == "touch" then
      local x, y = event.x, event.y
      local previous = plan.pageControls.previous
      local nextPage = plan.pageControls.next
      local target
      if
        x >= previous.x
        and x < previous.x + previous.width
        and y >= previous.y
        and y < previous.y + previous.height
      then
        target = "previous"
      elseif
        x >= nextPage.x
        and x < nextPage.x + nextPage.width
        and y >= nextPage.y
        and y < nextPage.y + nextPage.height
      then
        target = "next"
      end
      if target ~= nil then
        routed[#routed + 1] = { type = "page", direction = target }
      end
    else
      routed[#routed + 1] = event
    end
  end
  return routed
end

return MailboxInterface
