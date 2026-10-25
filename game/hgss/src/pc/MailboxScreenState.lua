-- Owns the mailbox child, sparse persistent-slot projection and read-only letter mode.
local Mail = require("libs.mons.src.gen4.Mail")
local MailComposeState = require("game.hgss.src.pc.MailComposeState")
local MailboxInterface = require("game.hgss.src.pc.MailboxInterface")

local MailboxScreenState = {}
MailboxScreenState.__index = MailboxScreenState

-- Retail close/quit path runs a palette flash on sprite 3 before
-- reporting closed (StartSpriteFlash -> PALETTE_FLASH -> QUIT/CLOSE_MAIL:
-- 1 tick on the first palette, 4 ticks on the second, 2 ticks to settle).
local CLOSE_FLASH_TICKS = 8

-- Decoded gMailboxGridBoxes neighbor links (buttonUp/Down/Left/Right per
-- input). Edges link to themselves except the bottom row, whose down link
-- is CLOSE (10); CLOSE links to itself except up, which the task pins to
-- row 8 (the 0x89 up link is the forced return to the origin row).
local GRID_NEIGHBOR = {
  up = { [0] = 0, [1] = 1, [2] = 0, [3] = 1, [4] = 2, [5] = 3, [6] = 4, [7] = 5, [8] = 6, [9] = 7, [10] = 8 },
  down = { [0] = 2, [1] = 3, [2] = 4, [3] = 5, [4] = 6, [5] = 7, [6] = 8, [7] = 9, [8] = 10, [9] = 10, [10] = 10 },
  left = { [0] = 0, [1] = 0, [2] = 2, [3] = 2, [4] = 4, [5] = 4, [6] = 6, [7] = 6, [8] = 8, [9] = 8, [10] = 10 },
  right = { [0] = 1, [1] = 1, [2] = 3, [3] = 3, [4] = 5, [5] = 5, [6] = 7, [7] = 7, [8] = 9, [9] = 9, [10] = 10 },
}

local function occupiedInput(self, input)
  return input >= 0 and input <= 9 and self.mailbox:get(self.page * 10 + input) ~= nil
end

-- Moves the grid cursor one retail neighbor step, skipping empty cells:
-- left/right take a single column step onto occupied mail; up/down walk
-- the column past empty cells, then fall back to the nearest occupied
-- cell in the movement direction. The bottom row downs to CLOSE and
-- CLOSE ups back to row 8; every edge otherwise holds the cursor.
local function moveCursor(self, direction)
  local cursor = assert(self.cursorInput, "grid navigation carries a resolved cursor")
  if direction == "left" or direction == "right" then
    if cursor ~= 10 then
      local target = GRID_NEIGHBOR[direction][cursor]
      if occupiedInput(self, target) then
        self.cursorInput = target
      end
    end
    self:_resolveCursor()
    return
  end
  if cursor == 10 then
    if direction ~= "up" then
      return
    end
    -- Up from CLOSE returns to row 8 per the decoded return link;
    -- only a sparse row 8 falls through to the upward scan.
    if occupiedInput(self, 8) then
      self.cursorInput = 8
      self:_resolveCursor()
      return
    end
    if occupiedInput(self, 9) then
      self.cursorInput = 9
      self:_resolveCursor()
      return
    end
    cursor = 8
  end
  if direction == "up" then
    if cursor <= 1 then
      return
    end
    for input = cursor - 2, 0, -2 do
      if occupiedInput(self, input) then
        self.cursorInput = input
        self:_resolveCursor()
        return
      end
    end
    for input = cursor - 1, 0, -1 do
      if occupiedInput(self, input) then
        self.cursorInput = input
        self:_resolveCursor()
        return
      end
    end
  else
    if cursor >= 8 then
      self.cursorInput = 10
      self:_resolveCursor()
      return
    end
    for input = cursor + 2, 9, 2 do
      if occupiedInput(self, input) then
        self.cursorInput = input
        self:_resolveCursor()
        return
      end
    end
    for input = cursor + 1, 9 do
      if occupiedInput(self, input) then
        self.cursorInput = input
        self:_resolveCursor()
        return
      end
    end
  end
end

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
  local menuActions
  if opts.mode == "mailbox" then
    assert(type(opts.partyHasMembers) == "boolean", "mailbox mode requires partyHasMembers")
    menuActions = opts.partyHasMembers and { "read", "erase", "give", "cancel" } or { "read", "cancel" }
  end
  local mailbox = opts.mode == "mailbox" and assert(opts.mailbox) or nil
  local state = setmetatable({
    mode = opts.mode,
    mailbox = mailbox,
    mailActions = opts.mailActions,
    menuActions = menuActions,
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
    -- Retail grid cursor (0-9 mail cells, 10 CLOSE). The cursor is the
    -- source of truth; the selected persistent slot derives from it and
    -- stays nil on CLOSE or while pointing at an empty cell.
    cursorInput = nil,
    visibleSlots = {},
    -- Quit/close palette-flash stage ({ ticks, kind }): while set, the
    -- sprite-3 flash plays and no other transition runs; closed (with
    -- the stored result kind) is reported only once it completes.
    closeFlash = nil,
    phase = opts.mode == "read" and "viewer" or (opts.mode == "confirm" and "confirm" or "list"),
    -- Prompts are compiled bank references ({ bank = 232|300, id = n }),
    -- never invented English, resolved to tokens by the renderer.
    prompt = opts.mode == "confirm" and (function()
      local claimed = assert(opts.prompt, "confirm mode carries its source prompt")
      assert(
        type(claimed) == "table" and (claimed.bank == 232 or claimed.bank == 300) and type(claimed.id) == "number",
        "mailbox prompts reference compiled bank-232/300 messages"
      )
      return { bank = claimed.bank, id = claimed.id }
    end)() or nil,
    lastPage = 0,
    holdMail = nil,
    compose = nil,
    composeTarget = nil,
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

local function cue(self, sequence)
  local audio = self.audio
  if type(audio) == "table" and type(audio.play) == "function" then
    audio.play(sequence)
  end
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
  self.lastPage = highestPage
  self.page = math.min(self.page, highestPage)
  self.visibleSlots = {}
  for slot = self.page * 10, math.min(self.page * 10 + 9, self.mailbox:count() - 1) do
    if self.mailbox:get(slot) ~= nil then
      self.visibleSlots[#self.visibleSlots + 1] = slot
    end
  end
  self:_resolveCursor()
end

-- Pins the list selection to the grid cursor: an unset cursor takes the
-- first visible row (CLOSE on an empty page), a cursor on a removed mail
-- falls back to the last visible row (CLOSE when none remains), and an
-- explicit CLOSE focus survives while rows are present.
function MailboxScreenState:_resolveCursor()
  if self.cursorInput == nil then
    if #self.visibleSlots > 0 then
      self.cursorInput = self.visibleSlots[1] - self.page * 10
    else
      self.cursorInput = 10
    end
  elseif self.cursorInput ~= 10 then
    if self.mailbox:get(self.page * 10 + self.cursorInput) == nil then
      if #self.visibleSlots > 0 then
        self.cursorInput = self.visibleSlots[#self.visibleSlots] - self.page * 10
      else
        self.cursorInput = 10
      end
    end
  end
  if self.cursorInput == 10 then
    self.selectedSlot = nil
  else
    self.selectedSlot = self.page * 10 + self.cursorInput
  end
end

-- Starts the retail quit/close flash: sprite 3 blinks for
-- CLOSE_FLASH_TICKS updates, then closed is reported with the stored kind.
function MailboxScreenState:_beginClose(kind)
  assert(type(kind) == "string", "close carries its existing result kind")
  self.closeFlash = { ticks = 0, kind = kind }
end

function MailboxScreenState:updateFixed(events)
  assert(not self.disposed, "disposed mailbox state cannot update")
  assert(type(events) == "table", "mailbox state updates from an event list")
  if self.closed then
    return
  end
  if self.closeFlash ~= nil then
    local flash = self.closeFlash
    flash.ticks = flash.ticks + 1
    if flash.ticks >= CLOSE_FLASH_TICKS then
      self.closeFlash = nil
      self.closed = true
      self.closedKind = flash.kind
    end
    return
  end
  if self.mode == "mailbox" or self.mode == "confirm" then
    events = MailboxInterface.events(self:status().presentation, events, self.phase)
  end
  if self.compose ~= nil then
    self.compose:updateFixed(events)
    local finished = self.compose:takeResult()
    if finished ~= nil then
      if finished.kind == "submitted" then
        local revisions = assert(self.captured, "composition carries its hold capture")
        local intent = self.mailActions:preview({
          kind = "composeGiveMail",
          targetSlot = assert(self.composeTarget, "composition carries its recipient"),
          letter = finished.letter,
          itemKey = revisions.itemKey,
          partyRevision = revisions.partyRevision,
          bagRevision = revisions.bagRevision,
        })
        self.outcome = intent.kind == "ready" and self.mailActions:commit(intent) or intent
        self.compose, self.composeTarget, self.captured, self.holdMail = nil, nil, nil, nil
        self.phase = "list"
        self:_refresh()
        cue(self, "SEQ_SE_DP_DECIDE")
      else
        -- Cancelling composition skips giving with custody unchanged:
        -- the erase outcome still stands on the result step.
        self.compose, self.composeTarget, self.captured = nil, nil, nil
        self.phase = "result"
        cue(self, "SEQ_SE_DP_DECIDE")
      end
    end
    return
  end
  if self.picker ~= nil then
    self.picker:updateFixed(events)
    local selected = self.picker:takeResult()
    if selected ~= nil then
      if selected.kind == "selected" then
        local revisions = self.captured
        if revisions.kind == "hold" then
          -- Retail composes a new letter on the erased stationery instead
          -- of reattaching the erased text: the picker recipient feeds the
          -- word-composition child, which submits the custody intent.
          local retained = assert(self.holdMail, "hold-mail keeps its erased letter").letter
          local templates = {}
          for index = 1, 3 do
            local line = retained.lines[index]
            templates[index] = line and line.template or false
          end
          self.composeTarget = selected.slot
          self.compose = MailComposeState.new({
            manifest = self.manifest,
            stationeryType = retained.type,
            author = retained.author,
            templates = templates,
            measureDisplay = self.measureDisplay,
            audio = self.audio,
          })
          self.picker:dispose()
          self.picker = nil
          self.phase = "compose"
          cue(self, "SEQ_SE_DP_DECIDE")
        else
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
          self.captured, self.holdMail = nil, nil
          self.phase = "list"
          self:_refresh()
        end
      elseif selected.kind == "cancelled" or selected.kind == "close" then
        self.picker:dispose()
        self.picker = nil
        self.captured = nil
        -- Declining the hold-mail picker still reports the erase
        -- outcome, matching the source bag-result step.
        if self.holdMail ~= nil then
          self.phase = "result"
        else
          self.phase = "list"
        end
      else
        error("party picker returned an unsupported Mail result", 0)
      end
    end
    return
  end
  if self.mode == "read" or self.mode == "confirm" then
    for _, event in ipairs(events) do
      if event.type == "cancel" then
        self:_beginClose(self.mode == "confirm" and "declined" or "closed")
        if self.mode == "read" then
          cue(self, "SEQ_SE_DP_DECIDE")
        end
      elseif event.type == "confirm" then
        self:_beginClose(self.mode == "confirm" and "confirmed" or "closed")
        cue(self, "SEQ_SE_DP_DECIDE")
      end
    end
    return
  end
  self:_refresh()
  for _, event in ipairs(events) do
    if event.type == "cancel" then
      if self.phase == "viewer" then
        self.phase = "list"
        self.outcome = nil
        cue(self, "SEQ_SE_DP_DECIDE")
      elseif self.phase == "action" then
        self.phase = "list"
        self.outcome = nil
      elseif self.phase == "confirm" then
        self.mailActions:commit(assert(self.pending), false)
        self.phase, self.pending = "action", nil
      elseif self.phase == "result" then
        self.phase, self.outcome, self.holdMail = "list", nil, nil
      elseif self.phase == "holdMail" then
        self.phase = "result"
      else
        self:_beginClose("closed")
        cue(self, "SEQ_SE_DP_DECIDE")
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
      if #self.visibleSlots > 0 then
        self.cursorInput = self.visibleSlots[1] - self.page * 10
      else
        self.cursorInput = 10
      end
      self:_resolveCursor()
      cue(self, "SEQ_SE_DP_SELECT")
    elseif event.type == "grid" then
      if self.phase == "list" then
        local input = event.input
        assert(
          type(input) == "number" and input % 1 == 0 and input >= 0 and input <= 10,
          "mailbox grid selection uses retail inputs 0-10"
        )
        if input == 10 then
          self:_beginClose("closed")
          cue(self, "SEQ_SE_DP_DECIDE")
        else
          local slot = self.page * 10 + input
          if self.mailbox:get(slot) ~= nil then
            -- Retail touch both moves to the cell and confirms it.
            self.cursorInput = input
            self.selectedSlot = slot
            self.phase, self.actionIndex, self.outcome = "action", 1, nil
            cue(self, "SEQ_SE_DP_DECIDE")
          end
        end
      end
    elseif event.type == "navigate" then
      assert(
        event.direction == "up" or event.direction == "down" or event.direction == "left" or event.direction == "right",
        "mailbox navigation uses the four controller directions"
      )
      if self.phase == "action" then
        local delta = event.direction == "down" and 1 or -1
        self.actionIndex = math.max(1, math.min(#self.menuActions, self.actionIndex + delta))
        cue(self, "SEQ_SE_DP_SELECT")
      else
        moveCursor(self, event.direction)
        cue(self, "SEQ_SE_DP_SELECT")
      end
    elseif event.type == "confirm" then
      if self.phase == "list" then
        if self.cursorInput == 10 then
          self:_beginClose("closed")
          cue(self, "SEQ_SE_DP_DECIDE")
        elseif self.selectedSlot ~= nil then
          self.phase, self.actionIndex, self.outcome = "action", 1, nil
          cue(self, "SEQ_SE_DP_DECIDE")
        end
      elseif self.phase == "action" then
        self:_activateAction()
      elseif self.phase == "viewer" then
        self.phase = "list"
        cue(self, "SEQ_SE_DP_DECIDE")
      elseif self.phase == "confirm" then
        local pending = assert(self.pending, "erase confirmation carries its intent")
        -- Retain the erased custody before the commit consumes it: the
        -- hold-mail question needs the letter and its stationery.
        self.holdMail = { letter = copy(pending.letter), itemKey = pending.itemKey }
        self.outcome = self.mailActions:commit(pending, true)
        self.pending = nil
        cue(self, "SEQ_SE_DP_DECIDE")
        if type(self.outcome) == "table" and self.outcome.kind == "changed" then
          self.phase = "erased"
        else
          self.holdMail = nil
          self.phase = "list"
        end
        self:_refresh()
      elseif self.phase == "erased" then
        -- Source bank-232 msg 12: "Let a Pokémon hold this Mail?"
        self.prompt = { bank = 232, id = 12 }
        self.phase = "holdMail"
        cue(self, "SEQ_SE_DP_DECIDE")
      elseif self.phase == "holdMail" then
        assert(type(self.createPartyPicker) == "function", "holding Mail requires the composed party picker")
        local revisions = self.mailActions:revisionSnapshot()
        self.captured = {
          kind = "hold",
          letter = copy(assert(self.holdMail, "hold-mail keeps its erased letter").letter),
          itemKey = assert(self.holdMail, "hold-mail keeps its stationery").itemKey,
          mailboxRevision = revisions.mailboxRevision,
          partyRevision = revisions.partyRevision,
          bagRevision = revisions.bagRevision,
        }
        self.picker = self.createPartyPicker()
        self.phase = "picker"
        cue(self, "SEQ_SE_DP_DECIDE")
      elseif self.phase == "result" then
        self.phase, self.outcome, self.holdMail = "list", nil, nil
        cue(self, "SEQ_SE_DP_DECIDE")
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
    cue(self, "SEQ_SE_DP_DECIDE")
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
      -- Source bank-232 msg 10: "The message will be lost. Is that OK?"
      self.prompt = { bank = 232, id = 10 }
      self.phase = "confirm"
    else
      self.outcome, self.phase = self.pending, "action"
    end
    cue(self, "SEQ_SE_DP_DECIDE")
    return
  end
  assert(type(self.createPartyPicker) == "function", "giving Mail requires the composed party picker")
  self.captured = {
    kind = "give",
    slot = slot,
    mailboxRevision = revisions.mailboxRevision,
    partyRevision = revisions.partyRevision,
    bagRevision = revisions.bagRevision,
  }
  self.picker = self.createPartyPicker()
  self.phase = "picker"
  cue(self, "SEQ_SE_DP_DECIDE")
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
      -- Page-relative retail grid input (0-9) behind the row.
      input = row.slot - self.page * 10,
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
    prompt = copy(self.prompt),
    compose = self.compose ~= nil and self.compose:status() or nil,
    page = self.page,
    lastPage = self.lastPage,
    visibleSlots = copy(self.visibleSlots),
    selectedSlot = self.selectedSlot,
    cursorInput = self.mode == "mailbox" and self.cursorInput or nil,
    closeFlash = self.closeFlash ~= nil and { ticks = self.closeFlash.ticks } or nil,
    rows = projectedRows,
    letter = letter,
    icons = icons,
    lines = letter and copy(letter.lines) or {},
    presentation = MailboxInterface.plan(self.measureDisplay(), self.mode, self.manifest),
  }
end

function MailboxScreenState:draw(resources, status)
  assert(type(resources) == "table", "mailbox drawing receives shared field presentation resources")
  if self.compose ~= nil then
    return self.compose:draw(resources)
  end
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
  if self.compose ~= nil then
    self.compose:cancel()
    return
  end
  if self.picker ~= nil then
    self.picker:cancel()
    return
  end
  if self.closeFlash ~= nil then
    -- Host teardown during the flash reports the stored kind at once.
    self.closed = true
    self.closedKind = self.closeFlash.kind
    self.closeFlash = nil
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
  if self.compose ~= nil then
    self.compose:dispose()
    self.compose = nil
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
