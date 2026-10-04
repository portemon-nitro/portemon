-- Owns the mailbox child, sparse persistent-slot projection and read-only letter mode.
local Mail = require("libs.mons.src.gen4.Mail")
local MailboxInterface = require("game.hgss.src.pc.MailboxInterface")

local MailboxScreenState = {}
MailboxScreenState.__index = MailboxScreenState

local function copy(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for key, child in pairs(value) do
    out[key] = copy(child)
  end
  return out
end

function MailboxScreenState.new(opts)
  assert(type(opts) == "table", "mailbox state requires options")
  assert(opts.mode == "mailbox" or opts.mode == "read" or opts.mode == "confirm", "mailbox mode is explicit")
  local mailbox = opts.mode == "mailbox" and assert(opts.mailbox) or nil
  local state = setmetatable({
    mode = opts.mode,
    mailbox = mailbox,
    mailActions = opts.mailActions,
    menuActions = { "read", "erase", "give", "cancel" },
    letter = opts.mode == "read" and Mail.validate(assert(opts.letter)) or nil,
    manifest = assert(opts.manifest),
    itemCatalog = opts.mode == "mailbox" and assert(opts.itemCatalog) or nil,
    cacheFs = opts.cacheFs,
    monCatalog = opts.monCatalog,
    measureDisplay = assert(opts.measureDisplay),
    audio = assert(opts.audio),
    createPartyPicker = opts.createPartyPicker,
    page = 0,
    selectedSlot = nil,
    visibleSlots = {},
    phase = opts.mode == "read" and "viewer" or (opts.mode == "confirm" and "confirm" or "list"),
    prompt = opts.mode == "confirm" and assert(opts.prompt) or nil,
    actionIndex = 1,
    pending = nil,
    picker = nil,
    outcome = nil,
    captured = nil,
    closed = false,
    _intent = nil,
  }, MailboxScreenState)
  state:_refresh()
  return state
end

function MailboxScreenState:_refresh()
  if self.mode ~= "mailbox" then
    self.visibleSlots, self.selectedSlot = {}, nil
    return
  end
  local highestPage = 0
  for slot = 0, self.mailbox:count() - 1 do
    if self.mailbox:get(slot) ~= nil then
      highestPage = math.max(highestPage, math.floor(slot / 10))
    end
  end
  self.page = math.min(self.page, highestPage)
  self.visibleSlots = {}
  for slot = self.page * 10, math.min(self.page * 10 + 9, self.mailbox:count() - 1) do
    if self.mailbox:get(slot) ~= nil then
      self.visibleSlots[#self.visibleSlots + 1] = slot
    end
  end
  local present = false
  for _, slot in ipairs(self.visibleSlots) do
    present = present or slot == self.selectedSlot
  end
  if not present then
    self.selectedSlot = self.selectedSlot == nil and self.visibleSlots[1] or self.visibleSlots[#self.visibleSlots]
  end
end

function MailboxScreenState:updateFixed(events)
  assert(not self.disposed, "disposed mailbox state cannot update")
  assert(type(events) == "table", "mailbox state updates from an event list")
  if self.closed then
    return
  end
  if self.mode == "mailbox" then
    events = MailboxInterface.events(self:status().presentation, events)
  end
  if self.picker ~= nil then
    self.picker:updateFixed(events)
    local selected = self.picker:takeResult()
    if selected ~= nil then
      if selected.kind == "selected" then
        local revisions = self.captured
        local intent = self.mailActions:preview({
          kind = "giveMailboxMail",
          slot = revisions.slot,
          targetSlot = selected.slot,
          mailboxRevision = revisions.mailboxRevision,
          partyRevision = revisions.partyRevision,
          bagRevision = revisions.bagRevision,
        })
        self.outcome = intent.kind == "ready" and self.mailActions:commit(intent) or intent
        self.picker:dispose()
        self.picker = nil
        self.phase = "list"
        self:_refresh()
      elseif selected.kind == "cancelled" or selected.kind == "close" then
        self.picker:dispose()
        self.picker = nil
        self.phase = "list"
      else
        error("party picker returned an unsupported Mail result", 0)
      end
    end
    return
  end
  if self.mode == "read" or self.mode == "confirm" then
    for _, event in ipairs(events) do
      if event.type == "cancel" then
        self.closed = true
        self.closedKind = self.mode == "confirm" and "declined" or "closed"
      elseif event.type == "confirm" then
        self.closed = true
        self.closedKind = self.mode == "confirm" and "confirmed" or "closed"
      end
    end
    return
  end
  self:_refresh()
  for _, event in ipairs(events) do
    if event.type == "cancel" then
      if self.phase == "viewer" or self.phase == "action" then
        self.phase = "list"
        self.outcome = nil
      elseif self.phase == "confirm" then
        self.mailActions:commit(assert(self.pending), false)
        self.phase, self.pending = "action", nil
      else
        self.closed = true
      end
    elseif event.type == "page" then
      if event.direction == "next" then
        self.page = math.min(1, self.page + 1)
      elseif event.direction == "previous" then
        self.page = math.max(0, self.page - 1)
      else
        error("mailbox page direction is invalid", 0)
      end
      self:_refresh()
      self.selectedSlot = self.visibleSlots[1]
    elseif event.type == "navigate" then
      assert(
        event.direction == "up" or event.direction == "down" or event.direction == "left" or event.direction == "right",
        "mailbox navigation uses the four controller directions"
      )
      if event.direction == "left" or event.direction == "right" then
        self.page = math.max(0, math.min(1, self.page + (event.direction == "right" and 1 or -1)))
        self:_refresh()
        self.selectedSlot = self.visibleSlots[1]
      elseif self.phase == "action" then
        local delta = event.direction == "down" and 1 or -1
        self.actionIndex = math.max(1, math.min(#self.menuActions, self.actionIndex + delta))
      else
        local index = 1
        for position, slot in ipairs(self.visibleSlots) do
          if slot == self.selectedSlot then
            index = position
          end
        end
        index = math.max(1, math.min(#self.visibleSlots, index + (event.direction == "down" and 1 or -1)))
        self.selectedSlot = self.visibleSlots[index]
      end
    elseif event.type == "confirm" then
      if self.phase == "list" then
        if self.selectedSlot ~= nil then
          self.phase, self.actionIndex, self.outcome = "action", 1, nil
        end
      elseif self.phase == "action" then
        self:_activateAction()
      elseif self.phase == "viewer" then
        self.phase = "list"
      elseif self.phase == "confirm" then
        self.outcome = self.mailActions:commit(self.pending, true)
        self.pending = nil
        self.phase = "list"
        self:_refresh()
      end
    end
  end
end

function MailboxScreenState:_activateAction()
  local action = self.menuActions[self.actionIndex]
  if action == "cancel" then
    self.phase = "list"
    return
  end
  local slot = assert(self.selectedSlot, "Mailbox actions require a selected source slot")
  local letter = assert(self.mailbox:get(slot), "selected rows retain their Mailbox record")
  if action == "read" then
    self.letter = Mail.validate(letter)
    self.phase = "viewer"
    return
  end
  local revisions = self.mailActions:revisionSnapshot()
  local request = {
    kind = action == "erase" and "eraseMailboxMessage" or "giveMailboxMail",
    slot = slot,
    mailboxRevision = revisions.mailboxRevision,
    bagRevision = revisions.bagRevision,
    partyRevision = revisions.partyRevision,
  }
  if action == "erase" then
    self.pending = self.mailActions:preview(request)
    if self.pending.kind == "confirm" then
      self.prompt = "Erase this letter?"
      self.phase = "confirm"
    else
      self.outcome, self.phase = self.pending, "action"
    end
    return
  end
  assert(type(self.createPartyPicker) == "function", "giving Mail requires the composed party picker")
  self.captured = {
    slot = slot,
    mailboxRevision = revisions.mailboxRevision,
    partyRevision = revisions.partyRevision,
    bagRevision = revisions.bagRevision,
  }
  self.picker = self.createPartyPicker()
  self.phase = "picker"
end

function MailboxScreenState:status()
  self:_refresh()
  local rows = {}
  if self.mode == "mailbox" then
    for _, slot in ipairs(self.visibleSlots) do
      rows[#rows + 1] = { slot = slot, letter = self.mailbox:get(slot), selected = slot == self.selectedSlot }
    end
  end
  local viewer = self.mode == "read" or self.phase == "viewer"
  local letter = viewer and copy(self.letter) or nil
  local icons = {}
  if letter ~= nil then
    for index, icon in ipairs(letter.icons) do
      if icon ~= false then
        local monCatalog = assert(self.monCatalog, "captured Mail icons require the shared mon catalog")
        icons[index] = { iconKey = monCatalog:iconSelection(icon), descriptor = copy(icon) }
      end
    end
  end
  local projectedRows = {}
  for _, row in ipairs(rows) do
    local stationery = assert(self.manifest.mail.stationery[row.letter.type])
    local stationeryItem = assert(self.itemCatalog:item(stationery.itemKey))
    projectedRows[#projectedRows + 1] = {
      slot = row.slot,
      letter = row.letter,
      selected = row.selected,
      stationeryKey = stationery.itemKey,
      itemIconKey = stationeryItem.icon,
    }
  end
  return {
    mode = viewer and "read" or self.mode,
    viewMode = viewer and "read" or "mailbox",
    phase = self.phase,
    action = self.phase == "action" and self.menuActions[self.actionIndex] or nil,
    menuActions = self.phase == "action" and copy(self.menuActions) or {},
    actionIndex = self.actionIndex,
    outcome = copy(self.outcome),
    prompt = self.prompt,
    page = self.page,
    visibleSlots = copy(self.visibleSlots),
    selectedSlot = self.selectedSlot,
    rows = projectedRows,
    letter = letter,
    icons = icons,
    lines = letter and copy(letter.lines) or {},
    presentation = MailboxInterface.plan(self.measureDisplay(), self.mode, self.manifest),
  }
end

function MailboxScreenState:draw(resources, status)
  assert(type(resources) == "table", "mailbox drawing receives shared field presentation resources")
  if self.picker ~= nil then
    return self.picker:draw(resources)
  end
  local renderer = assert(resources.mailboxRenderer, "mailbox presentation provides its owned renderer")
  renderer:draw(status or self:status(), resources)
end

function MailboxScreenState:result()
  if self.closed then
    return { kind = self.closedKind or "closed" }
  end
  return nil
end

function MailboxScreenState:takeResult()
  if not self.closed or self.resultTaken then
    return nil
  end
  self.resultTaken = true
  return { kind = self.closedKind or "closed" }
end

function MailboxScreenState:takeIntent()
  return nil
end

function MailboxScreenState:cancel()
  if self.picker ~= nil then
    self.picker:cancel()
    return
  end
  self.closed = true
end

function MailboxScreenState:cancelPointerCapture() end

function MailboxScreenState:dispose()
  if self.disposed then
    return
  end
  self.disposed = true
  if self.pending ~= nil then
    self.mailActions:commit(self.pending, false)
    self.pending = nil
  end
  if self.picker ~= nil then
    self.picker:dispose()
    self.picker = nil
  end
end

function MailboxScreenState:isActive()
  return not self.closed
end

return MailboxScreenState
