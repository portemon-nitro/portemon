-- The native party-screen controller: one fixed-tick state machine over an
-- injected immutable view. Named contexts (browse, pick, item_target,
-- give_target, give_confirm) replace the legacy view/select modes. Browse opens
-- source-ordered context menus (summary, switch, item-or-mail, quit, then
-- field moves in move-slot order; eggs get summary, switch, quit) with a
-- separate item/mail submenu mapping; switch reorders through the
-- five-stage delayed swap that commits swapPartyMons exactly once at its
-- final tick. Domain actions emit one-shot value-only intents
-- (takeIntent) and resolve through completeAction; take routes through an
-- owned yes/no confirm. Every transition carries a semantic input epoch:
-- pointer captures store the press epoch and activate only for the same
-- target, pointer, epoch, and no drag. The controller owns transient
-- focus, prompts, epoch, swap/alpha clocks, and animation clocks; draw
-- never advances them. Pure module: no love, no I/O.

local FocusGraph = require("libs.ui.src.FocusGraph")
local PartyScreenTheme = require("libs.hgss.src.ui.PartyScreenTheme")
local YesNoPromptController = require("libs.hgss.src.ui.YesNoPromptController")

---@class PartyScreenController
---@field _context "browse"|"pick"|"item_target"|"give_target"|"give_confirm"
---@field _model PartyScreenController.Model
---@field _layout fun(): table<string, unknown>
---@field _swap PartyScreenController.SwapPort?
---@field _policy table<string, unknown>
---@field _promptShape table<string, unknown>?
---@field _pendingItem { key: string, bagRevision: integer }?
---@field _cancellable boolean
---@field _view PartyScreenController.View
---@field _observedRevision integer
---@field _state string
---@field _cursorNode integer|"cancel"
---@field _menu PartyScreenController.MenuEntry[]?
---@field _menuIndex integer?
---@field _menuSlot integer?
---@field _originSlot integer?
---@field _footerColumn integer
---@field _epoch integer
---@field _pressId string?
---@field _pressCapture PartyScreenController.Capture?
---@field _pressEpoch integer?
---@field _swapOp { source: integer, destination: integer, revision: integer, step: integer }?
---@field _intent table<string, unknown>?
---@field _origin PartyScreenController.Origin?
---@field _message string?
---@field _messageReturn string
---@field _prompt YesNoPromptController?
---@field _promptReturn string
---@field _promptEntry PartyScreenController.MenuEntry?
---@field _result PartyScreenController.Result?
---@field _closed boolean
---@field _tick integer
---@field _donorSlot integer?
---@field _donorMoveSlot integer?
---@field _infoOverlay boolean?
---@field _swapSource integer?
---@field _seq integer[]
---@field _seqBase integer[]
---@field _panelSlide integer
---@field _targetOrigin "menu"|"context"?
local PartyScreenController = {}
PartyScreenController.__index = PartyScreenController

---@class PartyScreenController.View
---@field revision integer
---@field slots table[]

---@class PartyScreenController.Model
---@field refresh fun(): PartyScreenController.View

---@class PartyScreenController.SwapPort
---@field partyRevision fun(): integer
---@field swapPartyMons fun(a: integer, b: integer)

---@class PartyScreenController.MenuEntry
---@field kind string
---@field label string
---@field move string?
---@field moveSlot integer?
---@field confirm boolean?
---@field confirmed boolean?

---@class PartyScreenController.Capture
---@field kind "slot"|"menu"|"cancel"|"info"|"prompt"
---@field slot integer?
---@field index integer?
---@field choice string?

---@class PartyScreenController.Origin
---@field state string
---@field cursorNode integer|"cancel"
---@field menuIndex integer?

---@class PartyScreenController.Result
---@field kind "closed"|"selected"|"cancelled"
---@field slot integer?

---@class PartyScreenController.Options
---@field context "browse"|"pick"|"item_target"|"give_target"|"give_confirm"
---@field initialFocus integer|"cancel"?
---@field allowCancel boolean?
---@field model PartyScreenController.Model
---@field layout fun(): table<string, unknown>
---@field swap PartyScreenController.SwapPort?
---@field actionPolicy table<string, unknown>?
---@field promptShape table<string, unknown>?
---@field item { key: string, bagRevision: integer }?

-- The five swap stages in update invocations after entering the swap
-- subtask: one start tick, sixteen 8px outgoing steps, one midpoint tick
-- exchanging only temporary draw records, sixteen incoming steps, and one
-- final commit tick. Pixel offsets slide the two records leftward out and
-- back in with exchanged content.
local SWAP_MIDPOINT_STEP = 18
local SWAP_COMMIT_STEP = 35
local SWAP_PIXEL_STEP = 8
local SWAP_FULL_OFFSET = 128

-- The top-panel show/hide slide in source pixels.
local PANEL_SLIDE_STEPS = { 0, 12, 24, 36, 40 }

-- States that keep the context menu open (slide target 40); every other
-- open state targets 0.
local MENU_OPEN_STATES = { context = true, item_context = true, mail_context = true, confirm = true }

---@param node integer|string
---@return boolean
local function isSlotNode(node)
  return type(node) == "number"
end

-- Compiles layout single-target links into FocusGraph candidate lists.
-- Every direction key resolves to a (possibly empty) ordered list so the
-- shared graph mechanics apply without touching layout topology.
---@param neighbors table<integer|string, table<string, integer|string>>
---@return table<integer|string, table<string, (integer|string)[]>>
local function compileGraph(neighbors)
  local graph = {}
  for node, links in pairs(neighbors) do
    assert(type(links) == "table", "neighbor links arrive as records")
    local compiled = {}
    for _, direction in ipairs({ "up", "down", "left", "right" }) do
      local target = links[direction]
      if target == nil then
        compiled[direction] = {}
      else
        compiled[direction] = { target }
      end
    end
    graph[node] = compiled
  end
  return graph
end

---@param opts PartyScreenController.Options
---@return PartyScreenController
function PartyScreenController.new(opts)
  assert(type(opts) == "table", "the party controller requires options")
  assert(
    opts.context == "browse"
      or opts.context == "pick"
      or opts.context == "item_target"
      or opts.context == "give_target"
      or opts.context == "give_confirm",
    "the party controller requires a named browse, pick, item_target, give_target, or give_confirm context"
  )
  assert(
    type(opts.model) == "table" and type(opts.model.refresh) == "function",
    "the party controller needs a view model"
  )
  assert(type(opts.layout) == "function", "the party controller needs its layout resolver")
  if opts.context == "browse" then
    assert(
      type(opts.swap) == "table"
        and type(opts.swap.partyRevision) == "function"
        and type(opts.swap.swapPartyMons) == "function",
      "browse mode swaps through the injected domain port"
    )
  elseif opts.swap ~= nil then
    assert(
      type(opts.swap.partyRevision) == "function" and type(opts.swap.swapPartyMons) == "function",
      "the swap port carries revision and publication"
    )
  end
  if opts.initialFocus ~= nil then
    assert(
      (
        type(opts.initialFocus) == "number"
        and opts.initialFocus % 1 == 0
        and opts.initialFocus >= 0
        and opts.initialFocus < 6
      ) or opts.initialFocus == "cancel",
      "the initial focus must be a party position in 0..5 or cancel"
    )
  end
  local cancellable = opts.allowCancel
  if cancellable == nil then
    cancellable = true
  end
  assert(type(cancellable) == "boolean", "cancel permission must be a boolean")
  if opts.item ~= nil then
    assert(type(opts.item.key) == "string", "the pending item names its semantic key")
    assert(
      type(opts.item.bagRevision) == "number" and opts.item.bagRevision % 1 == 0,
      "the pending item carries its bag revision"
    )
  end
  local self = setmetatable({
    _context = opts.context,
    _model = opts.model,
    _layout = opts.layout,
    _swap = opts.swap,
    _policy = opts.actionPolicy,
    _promptShape = opts.promptShape,
    _pendingItem = opts.item,
    _cancellable = cancellable,
    _state = "browse",
    _cursorNode = 0,
    _menu = nil,
    _menuIndex = nil,
    _menuSlot = nil,
    _originSlot = nil,
    _footerColumn = 1,
    _epoch = 0,
    _pressId = nil,
    _pressCapture = nil,
    _pressEpoch = nil,
    _swapOp = nil,
    _intent = nil,
    _origin = nil,
    _message = nil,
    _messageReturn = "browse",
    _prompt = nil,
    _promptReturn = "browse",
    _promptEntry = nil,
    _result = nil,
    _closed = false,
    _tick = 0,
    _donorSlot = nil,
    _donorMoveSlot = nil,
    _infoOverlay = false,
    _swapSource = nil,
    _seq = {},
    _seqBase = {},
    _panelSlide = 0,
    _targetOrigin = nil,
  }, PartyScreenController)
  if opts.context == "item_target" or opts.context == "give_target" then
    assert(opts.item ~= nil, "target contexts require the pending item identity")
    self._state = "choosing_item_target"
    self._targetOrigin = "context"
  elseif opts.context == "give_confirm" then
    -- The replacement question records its target now but opens its
    -- prompt on the first fixed update: presentation layout is not
    -- resolved during controller construction, and the opening batch
    -- must never activate the new prompt.
    assert(opts.item ~= nil, "the replacement question names its pending item")
    assert(
      type(opts.initialFocus) == "number"
        and opts.initialFocus % 1 == 0
        and opts.initialFocus >= 0
        and opts.initialFocus < 6,
      "the replacement question targets a party slot"
    )
    self._state = "give_confirm"
  end
  local view = self:_refresh()
  self:_resetSequences(view)
  ---@type integer|string?
  local start = opts.initialFocus
  if start == "cancel" and not self:_selectable(view, start) then
    start = nil
  end
  if start == nil or not self:_selectable(view, start) then
    start = self:_nearestSelectable(view, start)
  end
  if start == nil then
    error("the party screen has no selectable slot", 2)
  end
  self._cursorNode = start
  if opts.context == "give_confirm" then
    assert(self:_selectable(view, opts.initialFocus), "the replacement question targets an occupied slot")
    self._cursorNode = opts.initialFocus
  end
  return self
end

---@return PartyScreenController.View
function PartyScreenController:_refresh()
  local view = self._model.refresh()
  assert(type(view) == "table" and type(view.slots) == "table", "the party view needs six slot records")
  assert(#view.slots == 6, "the party view needs six slot records")
  self._view = view
  self._observedRevision = view.revision
  return view
end

-- Tracks icon animation sequences per slot: the phase restarts only when
-- the sequence changes, so steady health holds its rhythm.
---@param view PartyScreenController.View
function PartyScreenController:_resetSequences(view)
  for slot0 = 0, 5 do
    local record = view.slots[slot0 + 1]
    local sequence = 1
    if type(record) == "table" and record.occupied then
      local zone = PartyScreenTheme.hpZone(
        assert(record.currentHp, "occupied slots carry current HP"),
        assert(record.maxHp, "occupied slots carry max HP")
      )
      sequence = PartyScreenTheme.iconSequence(zone, assert(record.status, "occupied slots carry a status"))
    end
    self._seq[slot0 + 1] = sequence
    self._seqBase[slot0 + 1] = self._tick
  end
end

---@param view PartyScreenController.View
function PartyScreenController:_trackSequences(view)
  for slot0 = 0, 5 do
    local record = view.slots[slot0 + 1]
    local sequence = 1
    if type(record) == "table" and record.occupied then
      local zone = PartyScreenTheme.hpZone(
        assert(record.currentHp, "occupied slots carry current HP"),
        assert(record.maxHp, "occupied slots carry max HP")
      )
      sequence = PartyScreenTheme.iconSequence(zone, assert(record.status, "occupied slots carry a status"))
    end
    if sequence ~= self._seq[slot0 + 1] then
      self._seq[slot0 + 1] = sequence
      self._seqBase[slot0 + 1] = self._tick
    end
  end
end

---@param view PartyScreenController.View
---@param node integer|string
---@return boolean
function PartyScreenController:_selectable(view, node)
  if node == "cancel" then
    return self._cancellable
  end
  if not isSlotNode(node) then
    return false
  end
  local record = view.slots[node + 1]
  if record == nil or not record.occupied then
    return false
  end
  if self._context == "pick" and not record.eligible then
    return false
  end
  return true
end

---@param view PartyScreenController.View
---@param from integer|string?
---@return integer|string?
function PartyScreenController:_nearestSelectable(view, from)
  local start = 0
  if type(from) == "number" then
    start = from
  end
  for offset = 0, 5 do
    local candidate = (start + offset) % 6
    if self:_selectable(view, candidate) then
      return candidate
    end
  end
  if self._cancellable then
    return "cancel"
  end
  return nil
end

---@return boolean
function PartyScreenController:cancellable()
  return self._cancellable
end

-- Every state transition carries a semantic input epoch and releases any
-- held press: a press held across a transition must never activate a
-- post-transition target, even on identical rectangles.
---@param state string
function PartyScreenController:_setState(state)
  self._state = state
  self._epoch = self._epoch + 1
  self._pressId = nil
  self._pressCapture = nil
  self._pressEpoch = nil
end

-- Walks one direction through the compiled FocusGraph, skipping
-- unselectable nodes with Party's footer-column memory: dropping into
-- cancel remembers the column, and rising from cancel restores it instead
-- of the layout's fixed return.
---@param direction string
function PartyScreenController:_move(direction)
  assert(
    direction == "up" or direction == "down" or direction == "left" or direction == "right",
    "unknown UI direction"
  )
  local layout = assert(self._layout(), "the party layout is required for navigation")
  local graph = compileGraph(assert(layout.neighbors, "the party layout must carry directional neighbors"))
  local node = self._cursorNode
  if node == "cancel" and direction == "up" then
    local remembered = 4 + self._footerColumn
    if self:_selectable(self._view, remembered) then
      self._cursorNode = remembered
      return
    end
    node = remembered
  end
  local seen = { [self._cursorNode] = true }
  for _ = 1, 8 do
    local next = FocusGraph.move(graph, node, direction)
    if next == nil or next == node or seen[next] then
      return
    end
    seen[next] = true
    if next == "cancel" and isSlotNode(node) then
      self._footerColumn = node % 2
    end
    if self:_selectable(self._view, next) then
      self._cursorNode = next
      return
    end
    node = next
  end
end

-- Moves within the open menu list, clamped at its ends. Menu entries stay
-- focusable so their labels remain visible; activation policy lives with
-- the entry kind.
---@param direction string
---@param count integer
function PartyScreenController:_moveMenu(direction, count)
  assert(direction == "up" or direction == "down", "menus move vertically")
  local index = assert(self._menuIndex, "menu motion needs an open menu")
  if direction == "up" and index > 1 then
    self._menuIndex = index - 1
  elseif direction == "down" and index < count then
    self._menuIndex = index + 1
  end
end

---@param slotFacts table<string, unknown>
---@return PartyScreenController.MenuEntry[]
function PartyScreenController:_menuFor(slotFacts)
  local policy = assert(self._policy, "browse menus require the injected action policy")
  local menuFor = assert(policy.menuFor, "the action policy builds source-ordered menus")
  local menu = menuFor(slotFacts, self._context)
  assert(type(menu) == "table" and #menu >= 2, "context menus carry at least two entries")
  return menu
end

---@param menuKind "item"|"mail"
---@param slotFacts table<string, unknown>
---@return PartyScreenController.MenuEntry[]
function PartyScreenController:_submenuFor(menuKind, slotFacts)
  local policy = assert(self._policy, "submenus require the injected action policy")
  local submenuFor = assert(policy.submenuFor, "the action policy builds item and mail submenus")
  local menu = submenuFor(slotFacts, menuKind)
  assert(type(menu) == "table" and #menu >= 2, "submenus carry at least two entries")
  return menu
end

-- Opens the context menu over one occupied slot, remembering the origin
-- for the special return order.
---@param slot integer
function PartyScreenController:_openMenu(slot)
  local record = assert(self._view.slots[slot + 1], "context menus open over visible slots")
  self._menu = self:_menuFor(record)
  self._menuIndex = 1
  self._menuSlot = slot
  self._originSlot = slot
  self:_setState("context")
end

-- Opens an item or mail submenu over the menu's slot.
---@param menuKind "item"|"mail"
function PartyScreenController:_openSubmenu(menuKind)
  local slot = assert(self._menuSlot, "submenus open from a context menu slot")
  local record = assert(self._view.slots[slot + 1], "submenus open over visible slots")
  self._menu = self:_submenuFor(menuKind, record)
  self._menuIndex = 1
  if menuKind == "mail" then
    self:_setState("mail_context")
  else
    self:_setState("item_context")
  end
end

-- Emits one value-only intent and parks in waiting_action; the flow
-- resolves it through completeAction. The origin restores cursor and menu
-- position once the outcome lands.
---@param intent table<string, unknown>
function PartyScreenController:_emitIntent(intent)
  assert(self._intent == nil, "an intent is already pending")
  self._intent = intent
  self._origin = { state = self._state, cursorNode = self._cursorNode, menuIndex = self._menuIndex }
  self:_setState("waiting_action")
end

-- Arms the owned yes/no confirm over one menu entry. The prompt opens at
-- the context window with a safe negative default; keyboard and pointer
-- rows share the prompt controller, which latches a choice and publishes
-- it after its confirmation interval. The tick-owned resolution step
-- below consumes the published result.
---@param entry PartyScreenController.MenuEntry
---@param returnState string
function PartyScreenController:_openConfirm(entry, returnState)
  local shape = assert(self._promptShape, "confirmation requires the injected prompt shape")
  local prompt = YesNoPromptController.new(shape)
  local layout = assert(self._layout(), "the party layout is required for prompt placement")
  local window = assert(layout.contextWindow, "the party layout carries the context window")
  prompt:open({ x = window.x, y = window.y, shape = "compact", initialSelection = "no" })
  self._prompt = prompt
  self._promptEntry = entry
  self._promptReturn = returnState
  self:_setState("confirm")
end

-- Closes the owned prompt exactly once, whatever opened it.
function PartyScreenController:_closePrompt()
  if self._prompt ~= nil then
    self._prompt:dispose()
    self._prompt = nil
  end
  self._promptEntry = nil
end

-- Shows a message over the originating flow state; acknowledgement
-- returns there without replaying anything.
---@param text string
---@param returnState string
function PartyScreenController:_showMessage(text, returnState)
  assert(type(text) == "string" and text ~= "", "messages carry display text")
  self._message = text
  self._messageReturn = returnState
  self:_setState("message")
end

-- Starts the five-stage swap: the source, destination, and live revision
-- freeze now; the final tick revalidates before publishing once.
---@param source integer
---@param destination integer
function PartyScreenController:_beginSwap(source, destination)
  local port = assert(self._swap, "swapping requires the injected domain port")
  self._swapOp = { source = source, destination = destination, revision = port.partyRevision(), step = 0 }
  self:_setState("swapping")
end

-- Abandons an uncommitted swap with no domain mutation.
function PartyScreenController:_abortSwap()
  self._swapOp = nil
  local view = self:_refresh()
  local source = self._originSlot
  if source ~= nil and self:_selectable(view, source) then
    self._cursorNode = source
  end
  self._menu = nil
  self._menuIndex = nil
  self._menuSlot = nil
  self._originSlot = nil
  self:_setState("browse")
end

-- Advances one swap tick. Only the final stage touches the domain: it
-- revalidates the frozen revision, publishes exactly once through the
-- injected port, then re-reads the live party and restores the cursor.
function PartyScreenController:_advanceSwap()
  local op = assert(self._swapOp, "swap ticks require an armed operation")
  local port = assert(self._swap, "swapping requires the injected domain port")
  op.step = op.step + 1
  if op.step < SWAP_COMMIT_STEP then
    return
  end
  if port.partyRevision() ~= op.revision then
    self:_abortSwap()
    return
  end
  assert(op.source >= 0 and op.source < 6 and op.destination >= 0 and op.destination < 6, "swap slots stay in 0..5")
  port.swapPartyMons(op.source, op.destination)
  self._swapOp = nil
  local view = self:_refresh()
  assert(view.revision == op.revision + 1, "a committed swap observes exactly one party revision increment")
  if self:_selectable(view, op.destination) then
    self._cursorNode = op.destination
  end
  self._menu = nil
  self._menuIndex = nil
  self._menuSlot = nil
  self._originSlot = nil
  self:_setState("browse")
end

-- Advances the top-panel slide one step toward its state's target.
function PartyScreenController:_advanceSlide()
  local target = 0
  if MENU_OPEN_STATES[self._state] then
    target = PANEL_SLIDE_STEPS[#PANEL_SLIDE_STEPS]
  end
  local current = self._panelSlide
  if current == target then
    return
  end
  if current < target then
    for _, step in ipairs(PANEL_SLIDE_STEPS) do
      if step > current then
        self._panelSlide = math.min(step, target)
        return
      end
    end
  else
    for index = #PANEL_SLIDE_STEPS, 1, -1 do
      local step = PANEL_SLIDE_STEPS[index]
      if step < current then
        self._panelSlide = math.max(step, target)
        return
      end
    end
  end
end

-- Confirms the focused slot in a picking state: pick completes the
-- semantic result, target states evaluate compatibility before emitting.
function PartyScreenController:_confirmSlotTarget()
  local node = self._cursorNode
  if node == "cancel" then
    if self._context == "pick" then
      if self._cancellable then
        self._result = { kind = "cancelled" }
        self:_setState("closing")
      end
      return
    end
    if self._targetOrigin == "context" then
      self._result = { kind = "cancelled" }
      self:_setState("closing")
      return
    end
    self:_setState("browse")
    return
  end
  if self._state == "choose_hp_target" then
    if not self:_selectable(self._view, node) then
      return
    end
    assert(isSlotNode(node), "transfer targets resolve to party slots")
    local donor = assert(self._donorSlot, "transfer targeting remembers its donor")
    ---@cast node integer
    self:_emitIntent({
      kind = "transfer_hp",
      slot = donor,
      partyRevision = self._observedRevision,
      moveSlot = self._donorMoveSlot,
      targetSlot = node,
    })
    return
  end
  if not self:_selectable(self._view, node) then
    return
  end
  assert(isSlotNode(node), "targets resolve to party slots")
  if self._context == "pick" then
    ---@cast node integer
    self._result = { kind = "selected", slot = node }
    self:_setState("closing")
    return
  end
  local record = assert(self._view.slots[node + 1], "targeting reads visible slots")
  local policy = assert(self._policy, "targeting requires the injected action policy")
  local evaluateTarget = assert(policy.evaluateTarget, "the action policy evaluates targets")
  local verdict = evaluateTarget(record, self._context)
  assert(type(verdict) == "table", "target evaluation returns a verdict")
  if verdict.compatible ~= true then
    self:_showMessage(
      assert(verdict.note, "incompatible targets explain instead of committing"),
      "choosing_item_target"
    )
    return
  end
  local item = assert(self._pendingItem, "target contexts carry the pending item")
  local revision = self._observedRevision
  if self._context == "item_target" then
    ---@cast node integer
    self:_emitIntent({
      kind = "use_item",
      slot = node,
      partyRevision = revision,
      bagRevision = item.bagRevision,
      item = item.key,
    })
  else
    ---@cast node integer
    self:_emitIntent({
      kind = "give",
      slot = node,
      partyRevision = revision,
      bagRevision = item.bagRevision,
      item = item.key,
    })
  end
end

-- Activates the focused context-menu entry through its kind.
function PartyScreenController:_confirmMenuEntry()
  local menu = assert(self._menu, "menu activation needs an open menu")
  local index = assert(self._menuIndex, "menu activation needs a focused entry")
  local entry = assert(menu[index], "menu activation focuses a real entry")
  assert(type(entry.kind) == "string", "menu entries carry a kind")
  local slot = assert(self._menuSlot, "menu activation remembers its slot")
  local revision = self._observedRevision
  if entry.kind == "quit" then
    self._result = { kind = "closed" }
    self:_setState("closing")
    return
  end
  if entry.kind == "switch" then
    self._swapSource = slot
    self._menu = nil
    self._menuIndex = nil
    self:_setState("choose_swap")
    return
  end
  if entry.kind == "item" or entry.kind == "mail" then
    self:_openSubmenu(entry.kind)
    return
  end
  if entry.kind == "summary" then
    ---@cast slot integer
    self:_emitIntent({ kind = "summary", slot = slot, partyRevision = revision })
    return
  end
  if entry.kind == "field_move" then
    ---@cast slot integer
    self:_emitIntent({
      kind = "field_move",
      slot = slot,
      partyRevision = revision,
      move = assert(entry.move, "field entries carry their move"),
      moveSlot = assert(entry.moveSlot, "field entries carry their move slot"),
    })
    return
  end
  if entry.kind == "transfer_hp" then
    self._donorSlot = slot
    self._donorMoveSlot = entry.moveSlot
    self._targetOrigin = "menu"
    self._menu = nil
    self._menuIndex = nil
    self:_setState("choose_hp_target")
    return
  end
  if entry.confirm == true then
    self:_openConfirm(entry, self._state)
    return
  end
  self:_emitEntryIntent(entry, slot, revision)
end

-- Emits the intent for a directly activated menu entry.
---@param entry PartyScreenController.MenuEntry
---@param slot integer
---@param revision integer
function PartyScreenController:_emitEntryIntent(entry, slot, revision)
  local item = self._pendingItem
  if entry.kind == "give" or entry.kind == "take" then
    if entry.kind == "give" and item == nil then
      -- Picker-bound give: the owning flow opens the held-item picker
      -- for the captured slot, and the picked identity arrives with the
      -- later pick intent. Screens with a pending item keep their
      -- richer identity below.
      self:_emitIntent({ kind = entry.kind, slot = slot, partyRevision = revision })
      return
    end
    if entry.kind == "give" then
      assert(item ~= nil, "giving names its pending item")
    end
    local intent = { kind = entry.kind, slot = slot, partyRevision = revision }
    if item ~= nil then
      intent.bagRevision = item.bagRevision
      intent.item = item.key
    end
    -- Only the affirmative replacement entry carries this flag: every
    -- other menu entry omits it, so ordinary intents never claim it.
    if entry.confirmed == true then
      intent.confirmed = true
    end
    self:_emitIntent(intent)
    return
  end
  if entry.kind == "read_mail" or entry.kind == "take_mail" then
    self:_emitIntent({ kind = entry.kind, slot = slot, partyRevision = revision })
    return
  end
  if entry.kind == "use_item" or entry.kind == "teach_move" then
    assert(item ~= nil, "item operations name their pending item")
    local _ = item
    self:_emitIntent({
      kind = entry.kind,
      slot = slot,
      partyRevision = revision,
      bagRevision = item.bagRevision,
      item = item.key,
    })
    return
  end
  error("unknown menu entry kind " .. tostring(entry.kind), 2)
end

-- Confirms the focused browse slot: occupied slots open their context
-- menu, cancel closes.
function PartyScreenController:_confirmBrowse()
  local node = self._cursorNode
  if node == "cancel" then
    self._result = { kind = "closed" }
    self:_setState("closing")
    return
  end
  if self:_selectable(self._view, node) then
    assert(isSlotNode(node), "menus open over party slots")
    ---@cast node integer
    self:_openMenu(node)
  end
end

function PartyScreenController:_confirm()
  if self._context == "pick" then
    self:_confirmSlotTarget()
    return
  end
  if self._state == "browse" then
    self:_confirmBrowse()
    return
  end
  if self._state == "context" or self._state == "item_context" or self._state == "mail_context" then
    self:_confirmMenuEntry()
    return
  end
  if self._state == "choose_swap" then
    self:_confirmSwapDestination()
    return
  end
  if self._state == "choosing_item_target" or self._state == "choose_hp_target" then
    self:_confirmSlotTarget()
    return
  end
  if self._state == "message" then
    self:_acknowledgeMessage()
    return
  end
end

function PartyScreenController:_cancel()
  if self._state == "browse" then
    if self._context == "pick" then
      if self._cancellable then
        self._result = { kind = "cancelled" }
        self:_setState("closing")
      end
      return
    end
    if self._cancellable then
      self._result = { kind = "closed" }
      self:_setState("closing")
    end
    return
  end
  if self._state == "context" or self._state == "item_context" or self._state == "mail_context" then
    local slot = self._originSlot
    self._menu = nil
    self._menuIndex = nil
    self._menuSlot = nil
    self._originSlot = nil
    if slot ~= nil and self:_selectable(self._view, slot) then
      self._cursorNode = slot
    end
    self:_setState("browse")
    return
  end
  if self._state == "choose_swap" or self._state == "swapping" then
    self:_abortSwap()
    return
  end
  if self._state == "choosing_item_target" or self._state == "choose_hp_target" then
    if self._targetOrigin == "context" then
      self._result = { kind = "cancelled" }
      self:_setState("closing")
      return
    end
    local slot = self._menuSlot
    self._menu = nil
    self._menuIndex = nil
    self._menuSlot = nil
    self._originSlot = nil
    self._donorSlot = nil
    self._donorMoveSlot = nil
    if slot ~= nil and self:_selectable(self._view, slot) then
      self._cursorNode = slot
    end
    self:_setState("browse")
    return
  end
  if self._state == "message" then
    self:_acknowledgeMessage()
    return
  end
end

-- Confirms the swap destination: the source itself or cancel abandons,
-- another occupied slot arms the delayed commit.
function PartyScreenController:_confirmSwapDestination()
  local node = self._cursorNode
  local source = self._swapSource
  if source == nil then
    local menu = self._menu
    if menu ~= nil then
      self._menu = nil
      self._menuIndex = nil
      self._menuSlot = nil
      self._originSlot = nil
    end
    self:_setState("browse")
    return
  end
  if node == "cancel" or node == source then
    self:_abortSwap()
    return
  end
  if self:_selectable(self._view, node) then
    assert(isSlotNode(node), "swap destinations are party slots")
    ---@cast node integer
    self:_beginSwap(source, node)
  end
end

-- Opens the replacement question on its captured target: the synthetic
-- entry authorizes the exchange, and the slot rides the controller so
-- the affirmative intent resolves without an open menu.
function PartyScreenController:_openGiveConfirm()
  local node = self._cursorNode
  assert(isSlotNode(node), "the replacement question answers for a party slot")
  ---@cast node integer
  local item = assert(self._pendingItem, "the replacement question names its pending item")
  self._menuSlot = node
  self:_openConfirm({ kind = "give", label = item.key, confirmed = true }, "browse")
end

-- Consumes one published prompt result after the tick-owned prompt step:
-- YES publishes the armed entry intent, NO returns to the arming menu.
-- The replacement question has no arming menu: NO declines the exchange
-- with a single cancellation result instead. Either way the prompt
-- closes exactly once.
function PartyScreenController:_resolvePrompt()
  local prompt = assert(self._prompt, "prompt resolution needs its owned prompt")
  local result = prompt:takeResult()
  if result == nil then
    return
  end
  local entry = assert(self._promptEntry, "prompt resolution remembers its entry")
  local returnState = self._promptReturn
  self:_closePrompt()
  if result == "yes" then
    local slot = assert(self._menuSlot, "prompt intents remember their slot")
    ---@cast slot integer
    self:_emitEntryIntent(entry, slot, self._observedRevision)
    -- The emitted intent parks in waiting_action, but its origin must be
    -- the arming menu: completion restores the menu, never the closed
    -- prompt state, or the next tick would step a prompt that no longer
    -- exists.
    local origin = assert(self._origin, "emitted intents park their origin")
    origin.state = returnState
    return
  end
  assert(result == "no", "prompts resolve yes or no")
  if self._context == "give_confirm" then
    self._result = { kind = "cancelled" }
    self:_setState("closing")
    return
  end
  self:_setState(returnState)
end

-- Declines the owned confirm without publishing: the prompt closes
-- exactly once and control returns to the arming menu. The replacement
-- question declines with a single cancellation result instead.
-- Declining mutates nothing, so it never waits for the confirmation
-- interval.
function PartyScreenController:_declinePrompt()
  local returnState = self._promptReturn
  self:_closePrompt()
  if self._context == "give_confirm" then
    self._result = { kind = "cancelled" }
    self:_setState("closing")
    return
  end
  self:_setState(returnState)
end

-- Owns one fixed tick inside the yes/no confirm: unknown events raise
-- in prompt states exactly like ordinary states, dismiss and cancel
-- decline immediately without publishing, and every other event batch
-- drives the owned prompt exactly once before the tick-owned resolution
-- consumes a published result. Prompt rows latch on press through the
-- owned prompt; the release never activates by itself.
---@param uiInput table[]
function PartyScreenController:_stepPrompt(uiInput)
  for _, event in ipairs(uiInput) do
    assert(type(event) == "table" and type(event.type) == "string", "party events need a type")
    if event.type == "dismiss" or event.type == "cancel" then
      self:_declinePrompt()
      return
    end
    if
      event.type ~= "navigate"
      and event.type ~= "confirm"
      and event.type ~= "pointer_down"
      and event.type ~= "pointer_move"
      and event.type ~= "pointer_up"
      and event.type ~= "pointer_cancel"
      and event.type ~= "menu"
      and event.type ~= "pointer_scroll"
    then
      error("unknown party event type " .. tostring(event.type), 2)
    end
  end
  local prompt = assert(self._prompt, "prompt ticks need the owned prompt")
  prompt:updateFixed(uiInput)
  self:_resolvePrompt()
end

-- Acknowledges the message and returns to its caller state without
-- replaying anything.
function PartyScreenController:_acknowledgeMessage()
  self._message = nil
  self:_setState(self._messageReturn)
end

---@param a table<string, unknown>?
---@param b table<string, unknown>?
---@return boolean
local function sameTarget(a, b)
  if a == nil or b == nil then
    return a == b
  end
  return a.kind == b.kind and a.slot == b.slot and a.action == b.action and a.index == b.index
end

-- Activates one hit-test target through the shared confirm path. Only
-- the active state's targets consult: slots in picking states, menu rows
-- in menu states, prompt rows in confirm, cancel and info in browse.
---@param target table<string, unknown>?
function PartyScreenController:_activate(target)
  if target == nil then
    return
  end
  if self._state == "browse" then
    if target.kind == "cancel" then
      self:_cancel()
      return
    end
    if target.kind == "info" then
      self._infoOverlay = not self._infoOverlay
      self._epoch = self._epoch + 1
      return
    end
    if target.kind == "slot" and isSlotNode(target.slot) then
      if self:_selectable(self._view, target.slot) then
        self._cursorNode = target.slot
        -- Pointer taps share the keyboard confirm dispatch: a picking
        -- context completes the semantic result instead of opening a menu.
        if self._context == "pick" then
          self:_confirmSlotTarget()
        else
          self:_confirmBrowse()
        end
      end
    end
    return
  end
  if self._state == "context" or self._state == "item_context" or self._state == "mail_context" then
    if target.kind == "menu" and type(target.index) == "number" then
      local menu = assert(self._menu, "menu activation needs its open menu")
      if target.index >= 1 and target.index <= #menu then
        self._menuIndex = target.index
        self:_confirmMenuEntry()
      end
    end
    return
  end
  if self._state == "choose_swap" or self._state == "choosing_item_target" or self._state == "choose_hp_target" then
    if target.kind == "slot" and isSlotNode(target.slot) then
      if self:_selectable(self._view, target.slot) then
        self._cursorNode = target.slot
        if self._state == "choose_swap" then
          self:_confirmSwapDestination()
        else
          self:_confirmSlotTarget()
        end
      end
    elseif target.kind == "cancel" then
      self:_cancel()
    end
    return
  end
  if self._state == "message" then
    self:_acknowledgeMessage()
    return
  end
end

---@param layout table<string, unknown>
---@param x number
---@param y number
---@return table<string, unknown>?
local function hitSlots(layout, x, y)
  local hitTest = assert(layout.hitTest, "the party layout must carry its hit test")
  return hitTest(x, y)
end

---@param event table<string, unknown>
function PartyScreenController:_pointerDown(event)
  if self._pressId ~= nil then
    return
  end
  assert(type(event.pointerId) == "string", "pointer down needs a pointer id")
  self._pressId = event.pointerId
  self._pressEpoch = self._epoch
  local layout = assert(self._layout(), "the party layout is required for pointer input")
  if self._state == "context" or self._state == "item_context" or self._state == "mail_context" then
    local rows = assert(layout.menuRows, "the party layout carries menu rows")
    local menu = assert(self._menu, "menu presses need the open menu")
    local hit = rows(#menu)
    for index, rect in ipairs(hit) do
      if
        type(event.x) == "number"
        and type(event.y) == "number"
        and event.x >= rect.x
        and event.x < rect.x + rect.width
        and event.y >= rect.y
        and event.y < rect.y + rect.height
      then
        self._pressCapture = { kind = "menu", index = index }
        return
      end
    end
    self._pressCapture = nil
    return
  end
  local hit = hitSlots(layout, event.x, event.y)
  if hit == nil then
    self._pressCapture = nil
  else
    self._pressCapture = { kind = hit.kind, slot = hit.slot, index = hit.index }
  end
end

---@param event table<string, unknown>
function PartyScreenController:_pointerMove(event)
  if self._pressId ~= nil then
    return
  end
  local layout = assert(self._layout(), "the party layout is required for pointer input")
  local target = hitSlots(layout, event.x, event.y)
  if target ~= nil and target.kind == "slot" and isSlotNode(target.slot) then
    if self:_selectable(self._view, target.slot) then
      self._cursorNode = target.slot
    end
  end
end

---@param event table<string, unknown>
function PartyScreenController:_pointerUp(event)
  if event.pointerId ~= self._pressId then
    return
  end
  local down = self._pressCapture
  local epoch = self._pressEpoch
  self._pressId = nil
  self._pressCapture = nil
  self._pressEpoch = nil
  if event.dragged == true then
    return
  end
  if epoch ~= self._epoch then
    return
  end
  local layout = assert(self._layout(), "the party layout is required for pointer input")
  local up
  if self._state == "context" or self._state == "item_context" or self._state == "mail_context" then
    local rows = assert(layout.menuRows, "the party layout carries menu rows")
    local menu = assert(self._menu, "menu presses need the open menu")
    local hit = rows(#menu)
    up = nil
    if type(event.x) == "number" and type(event.y) == "number" then
      for index, rect in ipairs(hit) do
        if
          event.x >= rect.x
          and event.x < rect.x + rect.width
          and event.y >= rect.y
          and event.y < rect.y + rect.height
        then
          up = { kind = "menu", index = index }
          break
        end
      end
    end
  else
    up = hitSlots(layout, event.x, event.y)
  end
  if sameTarget(down, up) then
    self:_activate(up)
  end
end

-- One fixed tick over the tick's UI events. Clocks advance first: icon
-- phases, the panel slide, and an armed swap all step once per tick while
-- open. At most one state consumes an event batch: the batch ends when a
-- transition fires, an intent emits, a message acknowledges, or a
-- terminal result records. A completed controller ignores further input.
---@param uiInput table[]
function PartyScreenController:updateFixed(uiInput)
  assert(type(uiInput) == "table", "the party input must be an event list")
  if self._closed then
    return
  end
  self._tick = self._tick + 1
  local previousRevision = self._observedRevision
  local view = self:_refresh()
  self:_trackSequences(view)
  self:_advanceSlide()
  if self._state == "swapping" then
    self:_advanceSwap()
    return
  end
  if self._state == "confirm" then
    self:_stepPrompt(uiInput)
    return
  end
  if self._state == "give_confirm" then
    -- First fixed update with a resolved layout: open the replacement
    -- question and ignore this batch, so the transition that opened the
    -- page can never answer its own prompt.
    self:_openGiveConfirm()
    return
  end
  if view.revision ~= previousRevision and self._swapOp == nil then
    -- Reconcile a cursor the party change may have invalidated without
    -- inventing a mon: keep a still-selectable cursor, else the nearest one.
    if not self:_selectable(view, self._cursorNode) then
      local reconciled = self:_nearestSelectable(view, self._cursorNode)
      if reconciled ~= nil then
        self._cursorNode = reconciled
      end
    end
  end
  for _, event in ipairs(uiInput) do
    if self._closed then
      break
    end
    assert(type(event) == "table" and type(event.type) == "string", "party events need a type")
    local stateBefore = self._state
    local intentBefore = self._intent
    local resultBefore = self._result
    if event.type == "navigate" then
      self:_navigate(event)
    elseif event.type == "confirm" then
      self:_confirm()
    elseif event.type == "cancel" then
      self:_cancel()
    elseif event.type == "dismiss" then
      self:_dismiss()
    elseif event.type == "pointer_down" then
      self:_pointerDown(event)
    elseif event.type == "pointer_move" then
      self:_pointerMove(event)
    elseif event.type == "pointer_up" then
      self:_pointerUp(event)
    elseif event.type == "pointer_cancel" then
      self:cancelPointerCapture()
    elseif event.type == "menu" or event.type == "pointer_scroll" then
      -- A child application's own input policy applies: the synthesized
      -- menu edge and scroll events never drive the party screen.
    else
      error("unknown party event type " .. tostring(event.type), 2)
    end
    if self._closed then
      break
    end
    if self._state ~= stateBefore or self._intent ~= intentBefore or self._result ~= resultBefore then
      break
    end
  end
end

-- Routes directional input: menu lists move vertically clamped, slot
-- states walk the compiled graph.
---@param event table<string, unknown>
function PartyScreenController:_navigate(event)
  if self._state == "context" or self._state == "item_context" or self._state == "mail_context" then
    local menu = assert(self._menu, "menu motion needs the open menu")
    self:_moveMenu(assert(event.direction, "navigation needs a direction"), #menu)
    return
  end
  if
    self._state == "browse"
    or self._state == "choose_swap"
    or self._state == "choosing_item_target"
    or self._state == "choose_hp_target"
  then
    self:_move(assert(event.direction, "navigation needs a direction"))
    return
  end
end

-- Interprets outside dismissal by owning state: normal browse flows
-- close, target and confirmation flows cancel their operation without
-- committing, gated animation and waiting states ignore it.
function PartyScreenController:_dismiss()
  if
    self._state == "browse"
    or self._state == "context"
    or self._state == "item_context"
    or self._state == "mail_context"
  then
    if self._context == "pick" then
      error("party dismiss is a browse-flow edge; pick context never emits it", 2)
    end
    self._result = { kind = "closed" }
    self:_setState("closing")
    return
  end
  if self._state == "choose_swap" or self._state == "choosing_item_target" or self._state == "choose_hp_target" then
    self:_cancel()
    return
  end
  if self._state == "message" then
    self:_acknowledgeMessage()
    return
  end
end

-- The presentation snapshot: context, state, cursor, open menu, pending
-- swap visuals, animation clocks, and the current immutable view. The
-- view is the model's own fresh record; callers must not mutate it.
-- Animation numbers are read-only presentation facts: draw never
-- advances them.
---@class PartyScreenController.Status
---@field open boolean
---@field context "browse"|"pick"|"item_target"|"give_target"|"give_confirm"?
---@field state string?
---@field mode "browse"|"pick"|"item_target"|"give_target"|"give_confirm"?
---@field action string?
---@field cursorNode integer|"cancel"?
---@field menuIndex integer?
---@field menu PartyScreenController.MenuEntry[]?
---@field menuSlot integer?
---@field message string?
---@field prompt table<string, unknown>?
---@field swap table<string, unknown>?
---@field anim table<string, unknown>?
---@field infoOverlay boolean?
---@field view PartyScreenController.View?
---@field cancellable boolean?
---@field layout PartyScreenLayoutResolved? resolved layout injected by the application state for hit testing and rendering
---@field preparationState "pending"|"ready"|"failed"? icon preparation attached by the party application state, never the controller
---@field preparationError string? visible preparation failure attached by the party application state
---@return PartyScreenController.Status
function PartyScreenController:status()
  if self._closed then
    return { open = false }
  end
  local swapStatus
  if self._swapOp ~= nil then
    local op = assert(self._swapOp, "swap status reads an armed operation")
    local stage = "start"
    local offsetPx = 0
    local exchanged = false
    if op.step >= SWAP_MIDPOINT_STEP then
      stage = "in"
      exchanged = true
      offsetPx = -SWAP_FULL_OFFSET + (op.step - SWAP_MIDPOINT_STEP) * SWAP_PIXEL_STEP
    elseif op.step >= 2 then
      stage = "out"
      offsetPx = -(op.step - 1) * SWAP_PIXEL_STEP
    end
    swapStatus = {
      source = op.source,
      destination = op.destination,
      step = op.step,
      stage = stage,
      offsetPx = offsetPx,
      exchanged = exchanged,
    }
  end
  local periods = self:_iconPeriods()
  local sequences = {}
  local phases = {}
  for slot0 = 0, 5 do
    local sequence = self._seq[slot0 + 1] or 1
    sequences[slot0 + 1] = sequence
    local period = periods[sequence + 1] or 1
    assert(type(period) == "number" and period >= 1, "icon sequences carry positive periods")
    phases[slot0 + 1] = (self._tick - (self._seqBase[slot0 + 1] or self._tick)) % period
  end
  return {
    open = true,
    context = self._context,
    state = self._state,
    mode = self._context,
    action = self._state,
    cursorNode = self._cursorNode,
    menuIndex = self._menuIndex,
    menu = self._menu,
    menuSlot = self._menuSlot,
    message = self._message,
    prompt = self._prompt and self._prompt:status() or nil,
    swap = swapStatus,
    anim = {
      tick = self._tick,
      sequences = sequences,
      phases = phases,
      panelSlide = self._panelSlide,
    },
    infoOverlay = self._infoOverlay == true,
    view = self._view,
    cancellable = self._cancellable,
  }
end

---@return integer[]
function PartyScreenController:_iconPeriods()
  -- The layout resolves through the live session plan, which does not
  -- exist before the state's first resolution: animation starts at phase
  -- zero until then. Later layout failures stay loud at their input
  -- boundary; only the missing first plan falls back here.
  local ok, layout = pcall(self._layout)
  if ok and type(layout) == "table" then
    local periods = layout.iconPeriods
    if type(periods) == "table" and #periods == 6 then
      return periods
    end
  end
  return { 1, 8, 12, 24, 40, 36 }
end

-- The one-shot intent contract: nil until an entry emits, then exactly
-- one value-only record for the flow to complete.
---@return table<string, unknown>?
function PartyScreenController:takeIntent()
  local intent = self._intent
  self._intent = nil
  return intent
end

-- Resolves the pending intent from the flow. The presentation-only no-op
-- returns to the originating state with no message, mutation, or new
-- intent; any other outcome shows its text when present and otherwise
-- returns silently. Outcomes for another state are a programming error.
---@param outcome table<string, unknown>
function PartyScreenController:completeAction(outcome)
  assert(type(outcome) == "table", "action completion carries an outcome")
  assert(self._state == "waiting_action", "action completion resolves a pending intent")
  assert(self._intent == nil, "the flow takes the intent before completing it")
  local origin = assert(self._origin, "waiting remembers its origin")
  self._origin = nil
  if outcome.kind == "no_op" then
    self:_restoreOrigin(origin)
    return
  end
  if type(outcome.text) == "string" and outcome.text ~= "" then
    self._cursorNode = origin.cursorNode
    self:_showMessage(outcome.text, origin.state)
    return
  end
  self:_restoreOrigin(origin)
end

-- Restores the pre-intent cursor and menu position after an outcome.
---@param origin PartyScreenController.Origin
function PartyScreenController:_restoreOrigin(origin)
  self._cursorNode = origin.cursorNode
  if origin.state == "context" or origin.state == "item_context" or origin.state == "mail_context" then
    local slot = self._menuSlot
    if slot ~= nil then
      local record = self._view.slots[slot + 1]
      if record ~= nil and record.occupied then
        local menu
        if origin.state == "context" then
          menu = self:_menuFor(record)
        else
          menu = self:_submenuFor(origin.state == "mail_context" and "mail" or "item", record)
        end
        if #menu > 0 then
          self._menu = menu
          ---@type integer?
          local index = origin.menuIndex
          if type(index) ~= "number" or index < 1 or index > #menu then
            index = 1
          end
          self._menuIndex = index
          self:_setState(origin.state)
          return
        end
      end
    end
  end
  self._menu = nil
  self._menuIndex = nil
  self._menuSlot = nil
  self._originSlot = nil
  self:_setState(origin.state == "closing" and "browse" or origin.state)
end

-- The one-shot result contract: nil until a terminal event, then exactly
-- one semantic record.
---@return { kind: "closed"|"selected"|"cancelled", slot?: integer }?
function PartyScreenController:takeResult()
  local result = self._result
  self._result = nil
  if result ~= nil then
    self._closed = true
  end
  return result
end

-- Idempotent release of the logical lifetime: a pending result is
-- discarded and no completion is reported after disposal.
function PartyScreenController:dispose()
  self:_closePrompt()
  self._result = nil
  self._closed = true
end

-- A press held across a layout change must not activate a different
-- post-layout target, so placement changes cancel the pointer capture and
-- advance the epoch past any in-flight press.
function PartyScreenController:cancelPointerCapture()
  self._pressId = nil
  self._pressCapture = nil
  self._pressEpoch = nil
  self._epoch = self._epoch + 1
end

return PartyScreenController
