-- Owns the mailbox child, sparse persistent-slot projection, the native
-- read leaf, and the erased-stationery follow-up. Erase commits first at
-- its own boundary; the hold follow-up then composes a genuinely new
-- letter (current author, three blank lines, current icon snapshot)
-- through the shared composer and the existing Party give controller.
-- Stored-letter Give keeps its existing move semantics and earns no
-- written-letter statistics.
local Mail = require("libs.mons.src.gen4.Mail")
local MailboxInterface = require("game.hgss.src.pc.MailboxInterface")
local MailViewInterface = require("game.hgss.src.pc.MailViewInterface")
local Mon = require("libs.mons.src.Mon")

---@class MailboxScreenState
---@field mode string mailbox, read, or confirm presentation
---@field mailbox table<string, unknown>? live Mailbox owner in mailbox mode
---@field mailActions table<string, unknown> custody coordinator
---@field makeMailComposer fun(request: table<string, unknown>): table<string, unknown>? fresh-letter factory for the hold follow-up
---@field mons table<string, unknown>? live mon service for give targets
---@field menuActions string[]? available grid actions for party-backed mailboxes
---@field letter table<string, unknown>? detached read normalized through the catalog
---@field manifest table<string, unknown> the PC manifest carrying compiled stationery
---@field itemCatalog table<string, unknown>? item catalog for stationery facts
---@field cacheFs table<string, unknown>? generated asset filesystem
---@field monCatalog table<string, unknown>? icon catalog for legacy admission and reads
---@field measureDisplay fun(): table<string, unknown> display facts for the native plan
---@field audio table<string, unknown>? production sound boundary
---@field createPartyPicker fun(role: string, facts: table<string, unknown>?): table<string, unknown>? parked Party picker factory
---@field prepareIcons fun(iconKeys: string[]): boolean, string? borrowed icon preparation
---@field prepareMail fun(status: table<string, unknown>): boolean, string? borrowed Mail preparation
---@field page number visible ten-slot page
---@field selectedSlot number? persistent selected slot or nil on CLOSE/empty
---@field cursorInput number? retail grid cursor 0..10
---@field visibleSlots integer[] occupied slots on the visible page
---@field closeFlash { ticks: integer, kind: string }? quit palette-flash stage
---@field phase string list, viewer, confirm, action, picker, compose, erased, holdMail, or result
---@field prompt table<string, unknown>? compiled bank-232/300 message reference
---@field lastPage integer last settled page for cursor adoption
---@field holdMail table<string, unknown>? erased stationery awaiting the hold question
---@field compose MailComposeState? live Mail composer while drafting a fresh letter
---@field staged table<string, unknown>? parked composition request across the picker
---@field preparing boolean Mail preparation is not yet ready
---@field preparationError string? last preparation failure
---@field actionIndex number selected grid action
---@field pending table<string, unknown>? unconfirmed erase intent
---@field picker table<string, unknown>? live Party picker while selecting or composing
---@field pickerRole string? compose or stored picker behavior
---@field outcome table<string, unknown>? last committed custody outcome
---@field captured table<string, unknown>? revision capture across picker and composer
---@field closed boolean close was reported
---@field _intent table<string, unknown>? retained one-use intent
---@field uiInput string? current input profile for the host
---@field closedKind string? stored close kind reported once the flash completes
---@field feedbackPending boolean? acknowledged give feedback returns to the list
---@field disposed boolean lifetime ended
---@field resultTaken boolean published result was drained
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
  local monCatalog = opts.monCatalog
  local readLetter = nil
  if opts.mode == "read" then
    -- Reads normalize explicit legacy letters through the supplied
    -- catalog; the stored selector strings then draw without inference.
    local context = monCatalog ~= nil and { catalog = monCatalog } or nil
    readLetter = Mail.normalize(assert(opts.letter), context)
  end
  local state = setmetatable({
    mode = opts.mode,
    mailbox = mailbox,
    mailActions = opts.mailActions,
    makeMailComposer = opts.makeMailComposer,
    mons = opts.mons,
    menuActions = menuActions,
    letter = readLetter,
    manifest = assert(opts.manifest),
    itemCatalog = opts.mode == "mailbox" and assert(opts.itemCatalog) or nil,
    cacheFs = opts.cacheFs,
    monCatalog = monCatalog,
    measureDisplay = assert(opts.measureDisplay),
    audio = assert(opts.audio),
    createPartyPicker = opts.createPartyPicker,
    prepareIcons = opts.prepareIcons,
    prepareMail = opts.prepareMail,
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
    staged = nil,
    preparing = false,
    preparationError = nil,
    actionIndex = 1,
    pending = nil,
    picker = nil,
    pickerRole = nil,
    outcome = nil,
    captured = nil,
    closed = false,
    _intent = nil,
    uiInput = nil,
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

-- Polls the read leaf preparation: the three stored icon selectors plus
-- the stationery visual. Readiness gates input; the failure cause rides
-- status until a later update recovers.
---@return boolean ready
function MailboxScreenState:_pollReadPreparation()
  local prepareIcons, prepareMail = self.prepareIcons, self.prepareMail
  if prepareIcons == nil and prepareMail == nil then
    self.preparing = false
    self.preparationError = nil
    return true
  end
  local letter = assert(self.letter, "read preparation carries its authored letter")
  if prepareIcons ~= nil then
    local selectors = {}
    for _, icon in ipairs(letter.icons) do
      if icon ~= false then
        selectors[#selectors + 1] = icon
      end
    end
    local ok, ready, failure = pcall(prepareIcons, selectors)
    if not ok then
      self.preparing = true
      self.preparationError = tostring(ready)
      return false
    end
    if not ready then
      self.preparing = true
      self.preparationError = failure
      return false
    end
  end
  if prepareMail ~= nil then
    local ok, ready, failure =
      pcall(prepareMail, { viewMode = "read", stationeryType = assert(letter.type, "reads prepare their type") })
    if not ok then
      self.preparing = true
      self.preparationError = tostring(ready)
      return false
    end
    if not ready then
      self.preparing = true
      self.preparationError = failure
      return false
    end
  end
  self.preparing = false
  self.preparationError = nil
  return true
end

-- Builds the Party give feedback for a committed fresh letter through the
-- existing template descriptors: the swap result when an ordinary held
-- item returned, otherwise the plain give result.
---@param targetSlot integer
---@param outcome table<string, unknown> committed Mail custody result
---@return table<string, unknown> completion
function MailboxScreenState:_giveFeedback(targetSlot, outcome)
  local mons = assert(self.mons, "give feedback reads the live party")
  local before = assert(outcome.before, "committed letters carry their display facts")
  local itemCatalog = assert(self.itemCatalog, "give feedback names its stationery")
  local monCatalog = assert(self.monCatalog, "give feedback names its recipient")
  local displayName = Mon.displayName(mons:partyMon(targetSlot), monCatalog)
  local newItem = itemCatalog:item(assert(outcome.itemKey, "give feedback names its item"))
  if before.heldItem ~= "NONE" then
    local oldItem = itemCatalog:item(before.heldItem)
    return {
      kind = "changed",
      disposition = "bag",
      message = {
        templateKey = "switchHeldResult",
        displayName = displayName,
        itemNames = {
          assert(oldItem.name, "the item catalog publishes its display name"),
          assert(newItem.name, "the item catalog publishes its display name"),
        },
      },
    }
  end
  return {
    kind = "changed",
    disposition = "bag",
    message = {
      templateKey = "giveHeldItem",
      displayName = displayName,
      itemNames = { assert(newItem.name, "the item catalog publishes its display name") },
    },
  }
end

-- Builds the replacement question for a fresh-letter recipient holding
-- an ordinary item, through the existing Party controller prompt.
---@param targetSlot integer
---@param reason string
---@return table<string, unknown> completion
function MailboxScreenState:_refusalCompletion(targetSlot, reason)
  if reason == "bag_full" then
    return { kind = "bag_full", disposition = "bag", message = { templateKey = "bagFull" } }
  end
  if reason == "recipient_holds_mail" then
    return { kind = "recipient_holds_mail", disposition = "bag", message = { templateKey = "heldMail" } }
  end
  if reason == "needs_confirmation" then
    local mons = assert(self.mons, "replacement questions read the live party")
    local monCatalog = assert(self.monCatalog, "replacement questions name their recipient")
    local itemCatalog = assert(self.itemCatalog, "replacement questions name the held item")
    local heldKey = assert(mons:partyMon(targetSlot).heldItem, "the target mon carries its held item")
    local heldItem = itemCatalog:item(heldKey)
    return {
      kind = "needs_confirmation",
      disposition = "bag",
      message = {
        templateKey = "switchHeldPrompt",
        displayName = Mon.displayName(mons:partyMon(targetSlot), monCatalog),
        itemNames = { assert(heldItem.name, "the item catalog publishes its display name") },
      },
    }
  end
  return { kind = reason, disposition = "bag" }
end

-- Drains one give-target picker intent through the Mail preflight: the
-- replacement question returns through the existing Party controller,
-- readiness parks the picker and stages the fresh composer, and a
-- structured refusal either reports visibly or resumes the erase result.
---@param intent table<string, unknown>
function MailboxScreenState:_routeComposeIntent(intent)
  local slot = assert(intent.slot, "compose intents name their recipient slot")
  local staged = {
    targetSlot = slot,
    itemKey = assert(intent.item, "compose intents carry their stationery"),
    partyRevision = assert(intent.partyRevision, "compose intents carry the party revision"),
    bagRevision = assert(intent.bagRevision, "compose intents carry the bag revision"),
    confirmed = intent.confirmed == true or nil,
  }
  local decision = self.mailActions:previewComposition(staged)
  if decision.kind == "needs_confirmation" or decision.kind == "ready" then
    local picker = assert(self.picker, "composition parks its live picker")
    picker:cancelPointerCapture()
  end
  if decision.kind == "needs_confirmation" then
    self.picker:completeAction(self:_refusalCompletion(slot, "needs_confirmation"))
    return
  end
  if decision.kind ~= "ready" then
    if decision.reason == "bag_full" or decision.reason == "recipient_holds_mail" then
      self.picker:completeAction(self:_refusalCompletion(slot, decision.reason))
      return
    end
    -- Any other refusal ends the follow-up with the committed erase
    -- outcome standing: the stationery already returned or discarded.
    self.picker:dispose()
    self.picker, self.pickerRole, self.captured = nil, nil, nil
    self.phase = "result"
    cue(self, "SEQ_SE_DP_DECIDE")
    return
  end
  local factory = assert(self.makeMailComposer, "fresh follow-ups borrow the Mail factory")
  local ok, composer = pcall(factory, staged)
  if not ok then
    self.preparationError = tostring(composer)
    return
  end
  self.staged = staged
  self.compose = composer
  self.phase = "compose"
  cue(self, "SEQ_SE_DP_DECIDE")
end

-- Drains one finished letter: an accepted letter previews and commits
-- exactly once through MailActions and feeds the give feedback back to
-- the parked Party child; a cancelled letter closes the follow-up with
-- the committed erase outcome standing.
---@param finished table<string, unknown> composer one-shot result
function MailboxScreenState:_routeComposeResult(finished)
  local staged = assert(self.staged, "submitted letters carry their staged request")
  if finished.kind ~= "submitted" then
    self:_disposeCompose()
    self.picker:dispose()
    self.picker, self.pickerRole, self.captured, self.staged = nil, nil, nil, nil
    self.phase = "result"
    cue(self, "SEQ_SE_DP_DECIDE")
    return
  end
  local intent = self.mailActions:preview({
    kind = "composeGiveMail",
    targetSlot = staged.targetSlot,
    itemKey = staged.itemKey,
    partyRevision = staged.partyRevision,
    bagRevision = staged.bagRevision,
    confirmed = staged.confirmed,
    letter = assert(finished.letter, "submitted letters carry their authored value"),
  })
  if intent.kind == "needs_confirmation" then
    self:_disposeCompose()
    self.picker:completeAction(self:_refusalCompletion(staged.targetSlot, "needs_confirmation"))
    self.phase = "picker"
    self.staged = nil
    cue(self, "SEQ_SE_DP_DECIDE")
    return
  end
  if intent.kind ~= "ready" then
    self:_disposeCompose()
    if intent.reason == "bag_full" or intent.reason == "recipient_holds_mail" then
      self.picker:completeAction(self:_refusalCompletion(staged.targetSlot, intent.reason))
      self.phase = "picker"
    else
      self.picker:dispose()
      self.picker, self.pickerRole, self.captured = nil, nil, nil
      self.phase = "result"
    end
    self.staged = nil
    cue(self, "SEQ_SE_DP_DECIDE")
    return
  end
  local outcome = self.mailActions:commit(intent)
  self:_disposeCompose()
  if outcome.kind ~= "changed" then
    self.picker:completeAction(self:_refusalCompletion(staged.targetSlot, outcome.reason or outcome.kind))
    self.phase = "picker"
    self.staged = nil
    cue(self, "SEQ_SE_DP_DECIDE")
    return
  end
  outcome.itemKey = staged.itemKey
  self.picker:completeAction(self:_giveFeedback(staged.targetSlot, outcome))
  self.feedbackPending = true
  self.staged = nil
  self.phase = "picker"
  cue(self, "SEQ_SE_DP_DECIDE")
end

function MailboxScreenState:_disposeCompose()
  local composer = self.compose
  if composer ~= nil then
    self.compose = nil
    composer:dispose()
  end
  self.uiInput = nil
end

function MailboxScreenState:updateFixed(events)
  assert(not self.disposed, "disposed mailbox state cannot update")
  assert(type(events) == "table", "mailbox state updates from an event list")
  if self.closed then
    return
  end
  if self.closeFlash ~= nil then
    local flash = assert(self.closeFlash, "quit flash carries its stage")
    flash.ticks = flash.ticks + 1
    if flash.ticks >= CLOSE_FLASH_TICKS then
      self.closeFlash = nil
      self.closed = true
      self.closedKind = flash.kind
    end
    return
  end
  -- Active children own their batches exclusively: the composer maps
  -- its own MailView input and the picker maps its own Party input.
  -- Neither a launch batch reaches the newly opened child nor a closing
  -- trailing batch reaches the parent.
  if self.compose ~= nil then
    self.compose:updateFixed(events)
    self.uiInput = self.compose.uiInput
    local finished = self.compose:takeResult()
    if finished ~= nil then
      self:_routeComposeResult(finished)
    end
    return
  end
  if self.picker ~= nil then
    self.picker:updateFixed(events)
    self.uiInput = self.picker.uiInput
    local intent = nil
    if self.pickerRole == "compose" and type(self.picker.takeIntent) == "function" then
      intent = self.picker:takeIntent()
    end
    if intent ~= nil then
      self:_routeComposeIntent(intent)
      return
    end
    local selected = self.picker:takeResult()
    if selected ~= nil then
      self:_routePickerResult(selected)
    end
    return
  end
  self.uiInput = nil
  if self.mode == "mailbox" or self.mode == "confirm" then
    events = MailboxInterface.events(self:status().presentation, events, self.phase)
  end
  if self.mode == "read" then
    if not self:_pollReadPreparation() then
      return
    end
    local plan = MailViewInterface.plan(self.measureDisplay(), "read", {})
    local mapped = MailViewInterface.events(plan, events, {})
    for _, event in ipairs(mapped) do
      if event.type == "close" then
        self:_beginClose("closed")
        cue(self, "SEQ_SE_DP_DECIDE")
        break
      end
    end
    return
  end
  if self.mode == "confirm" then
    for _, event in ipairs(events) do
      if event.type == "cancel" then
        self:_beginClose("declined")
      elseif event.type == "confirm" then
        self:_beginClose("confirmed")
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
            -- Retail touch both moves the cursor there and confirms it.
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
      elseif self.phase == "viewer" then
        self.phase = "list"
        cue(self, "SEQ_SE_DP_DECIDE")
      elseif self.phase == "action" then
        self:_activateAction()
      elseif self.phase == "viewer" then
        self.phase = "list"
        cue(self, "SEQ_SE_DP_DECIDE")
      elseif self.phase == "confirm" then
        local pending = assert(self.pending, "erase confirmation carries its intent")
        -- The committed erase precedes the hold question: canceling the
        -- recipient or the fresh draft never resurrects erased content.
        -- Only the erased stationery key rides the follow-up; the erased
        -- author and lines never do.
        local erasedItemKey = assert(pending.itemKey, "erase intents carry their stationery")
        self.outcome = self.mailActions:commit(pending, true)
        self.pending = nil
        cue(self, "SEQ_SE_DP_DECIDE")
        if type(self.outcome) == "table" and self.outcome.kind == "changed" then
          self.phase = "erased"
          self.holdMail = { itemKey = erasedItemKey }
        else
          self.phase = "list"
        end
        self:_refresh()
      elseif self.phase == "erased" then
        -- Source bank-232 msg 12: "Let a Pokémon hold this Mail?"
        self.prompt = { bank = 232, id = 12 }
        self.phase = "holdMail"
        cue(self, "SEQ_SE_DP_DECIDE")
      elseif self.phase == "holdMail" then
        local revisions = self.mailActions:revisionSnapshot()
        local held = assert(self.holdMail, "the hold follow-up carries its erased stationery")
        self.captured = {
          kind = "hold",
          mailboxRevision = revisions.mailboxRevision,
          partyRevision = revisions.partyRevision,
          bagRevision = revisions.bagRevision,
        }
        assert(type(self.createPartyPicker) == "function", "holding Mail requires the composed party picker")
        self.picker = self.createPartyPicker("compose", {
          itemKey = assert(held.itemKey, "the hold follow-up carries its erased stationery"),
          bagRevision = revisions.bagRevision,
        })
        self.pickerRole = "compose"
        self.phase = "picker"
        cue(self, "SEQ_SE_DP_DECIDE")
      elseif self.phase == "result" then
        self.phase, self.outcome, self.holdMail = "list", nil, nil
        cue(self, "SEQ_SE_DP_DECIDE")
      end
    end
  end
end

-- Drains one parked picker result: stored-letter selections move through
-- the existing custody path, feedback acknowledgements return to the
-- list, and declines resume the erase result or the list.
---@param selected table<string, unknown>
function MailboxScreenState:_routePickerResult(selected)
  if selected.kind == "selected" then
    local revisions = assert(self.captured, "picker selections resolve their capture")
    if revisions.kind == "hold" then
      -- Give-target pickers report through intents; a bare selection
      -- cannot arrive here.
      error("the hold follow-up picker resolves through intents", 0)
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
      self.picker, self.pickerRole = nil, nil
      self.captured, self.holdMail = nil, nil
      self.phase = "list"
      self:_refresh()
    end
  elseif selected.kind == "cancelled" or selected.kind == "close" then
    self.picker:dispose()
    self.picker, self.pickerRole = nil, nil
    self.captured = nil
    if self.feedbackPending then
      self.feedbackPending = false
      self.captured, self.holdMail = nil, nil
      self.phase = "list"
      self:_refresh()
      cue(self, "SEQ_SE_DP_DECIDE")
      return
    end
    -- Declining the hold-mail picker still reports the erase
    -- outcome, matching the source bag-result step.
    if self.holdMail ~= nil then
      self.phase = "result"
    else
      self.phase = "list"
    end
  elseif selected.kind == "give_complete" then
    -- Acknowledged fresh-letter feedback returns to the list with the
    -- committed letter attached and the erase outcome cleared.
    self.picker:dispose()
    self.picker, self.pickerRole = nil, nil
    self.captured, self.holdMail = nil, nil
    self.phase = "list"
    self:_refresh()
    cue(self, "SEQ_SE_DP_DECIDE")
  else
    error("party picker returned an unsupported Mail result", 0)
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
    self.letter = Mail.normalize(letter, self.monCatalog ~= nil and { catalog = self.monCatalog } or nil)
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
  local picker = self.createPartyPicker("stored")
  self.captured = {
    kind = "give",
    slot = slot,
    mailboxRevision = revisions.mailboxRevision,
    partyRevision = revisions.partyRevision,
    bagRevision = revisions.bagRevision,
  }
  self.picker = picker
  self.pickerRole = "stored"
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
        icons[index] = { iconKey = icon }
      end
    end
  end
  local projectedRows = {}
  for _, row in ipairs(rows) do
    local stationery = assert(self.manifest.mail.stationery[row.letter.type])
    -- Page-relative retail grid input (0-9) behind the row.
    projectedRows[#projectedRows + 1] = {
      slot = row.slot,
      input = row.slot - self.page * 10,
      letter = row.letter,
      selected = row.selected,
      stationeryKey = stationery.itemKey,
      itemIconKey = stationery.itemKey,
    }
  end
  local presentation
  if viewer then
    presentation = MailViewInterface.plan(self.measureDisplay(), "read", {})
  else
    presentation = MailboxInterface.plan(self.measureDisplay(), self.mode, self.manifest)
  end
  local readView = nil
  if viewer and letter ~= nil then
    readView = {
      mode = "read",
      stationeryType = letter.type,
      letter = letter,
      icons = icons,
      closeLabel = self.closeFlash == nil or self.closeFlash.ticks % 2 == 0,
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
    preparing = self.preparing,
    preparationError = self.preparationError,
    uiInput = self.compose ~= nil and "mail-view" or nil,
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
    view = readView,
    presentation = presentation,
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
  local value = status or self:status()
  if value.viewMode == "read" and value.view ~= nil then
    return assert(resources.mailboxRenderer, "Mailbox borrows its owned renderer"):drawMailPane(
      value.view,
      nil,
      resources
    )
  end
  local renderer = assert(resources.mailboxRenderer, "mailbox presentation provides its owned renderer")
  renderer:draw(value, resources)
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

function MailboxScreenState:cancelPointerCapture()
  local composer = self.compose
  if composer ~= nil then
    composer:cancelPointerCapture()
  end
  local picker = self.picker
  if picker ~= nil and type(picker.cancelPointerCapture) == "function" then
    picker:cancelPointerCapture()
  end
end

function MailboxScreenState:dispose()
  if self.disposed then
    return
  end
  self.disposed = true
  if self.pending ~= nil then
    self.mailActions:commit(self.pending, false)
    self.pending = nil
  end
  self:_disposeCompose()
  if self.picker ~= nil then
    self.picker:dispose()
    self.picker = nil
  end
end

function MailboxScreenState:isActive()
  return not self.closed
end

return MailboxScreenState
