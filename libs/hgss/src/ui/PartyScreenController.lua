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
-- target, pointer, epoch, and no drag.
--
-- Transient ownership lives in exactly one active mode record: each
-- variant carries only the data its state needs (menu entries, the owned
-- prompt, pending swap facts, targeting data), and return information
-- travels in value-only resume descriptors that never retain a prompt,
-- callback, or controller. Leaving a mode discards its payload in one
-- operation, so no stale menu, prompt, or swap outlives its state. The
-- controller owns transient focus, prompts, epoch, swap/alpha clocks, and
-- animation clocks; draw never advances them. Pure module: no love, no I/O.

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
---@field _mode PartyScreenController.Mode
---@field _cursorNode integer|"cancel"
---@field _footerColumn integer
---@field _epoch integer
---@field _transitionCount integer
---@field _pressId string?
---@field _pressCapture PartyScreenController.Capture?
---@field _pressEpoch integer?
---@field _tick integer
---@field _infoOverlay boolean?
---@field _seq integer[]
---@field _seqBase integer[]
---@field _panelSlide integer
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

---@class PartyScreenController.Resume
---@field kind "browse"|"menu"|"target_item"|"target_hp"
---@field flavor "context"|"item_context"|"mail_context"?
---@field slot integer?
---@field index integer?
---@field cursor integer|"cancel"
---@field entries PartyScreenController.MenuEntry[]?
---@field origin "menu"|"context"?
---@field donorSlot integer?
---@field donorMoveSlot integer?

---@class PartyScreenController.Mode
---@field kind "browse"|"menu"|"give_confirm"|"confirm"|"waiting_action"|"message"|"choose_swap"|"swapping"|"choosing_item_target"|"choose_hp_target"|"closing"|"closed"
---@field flavor "context"|"item_context"|"mail_context"?
---@field entries PartyScreenController.MenuEntry[]?
---@field index integer?
---@field slot integer?
---@field originSlot integer?
---@field target integer?
---@field prompt YesNoPromptController?
---@field entry PartyScreenController.MenuEntry?
---@field resume PartyScreenController.Resume?
---@field decline PartyScreenController.Result?
---@field intent table<string, unknown>?
---@field text string?
---@field source integer?
---@field destination integer?
---@field revision integer?
---@field step integer?
---@field origin "menu"|"context"?
---@field donorSlot integer?
---@field donorMoveSlot integer?
---@field result PartyScreenController.Result?

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
  ---@type PartyScreenController.Mode
  local mode = { kind = "browse" }
  if opts.context == "item_target" or opts.context == "give_target" then
    assert(opts.item ~= nil, "target contexts require the pending item identity")
    mode = { kind = "choosing_item_target", origin = "context" }
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
    local giveTarget = opts.initialFocus
    assert(type(giveTarget) == "number", "the replacement question targets a party slot")
    mode = { kind = "give_confirm", target = giveTarget }
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
    _mode = mode,
    _cursorNode = 0,
    _footerColumn = 1,
    _epoch = 0,
    _transitionCount = 0,
    _pressId = nil,
    _pressCapture = nil,
    _pressEpoch = nil,
    _tick = 0,
    _infoOverlay = false,
    _seq = {},
    _seqBase = {},
    _panelSlide = 0,
  }, PartyScreenController)
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

-- Reconciles a cursor the party may have invalidated without inventing a
-- mon: a still-selectable cursor stays, otherwise the nearest one wins.
---@param view PartyScreenController.View
---@param node integer|string
---@return integer|string
function PartyScreenController:_reconciledCursor(view, node)
  if self:_selectable(view, node) then
    ---@cast node integer|string
    return node
  end
  local reconciled = self:_nearestSelectable(view, node)
  if reconciled ~= nil then
    return reconciled
  end
  return self._cursorNode
end

---@return boolean
function PartyScreenController:cancellable()
  return self._cancellable
end

-- The public state string the parent flow and renderers observe. Menu
-- variants project their flavor; every other mode projects its kind.
---@return string
function PartyScreenController:_publicState()
  local mode = self._mode
  if mode.kind == "menu" then
    return assert(mode.flavor, "menu modes carry their flavor")
  end
  assert(mode.kind ~= "closed", "closed modes never project a state string")
  return mode.kind
end

-- Replaces the active mode in one operation: the old payload is
-- discarded, a confirm's owned prompt is released exactly once, held
-- presses clear, and the transition identity ends the current input
-- batch even when the public state string stays equal.
---@param mode PartyScreenController.Mode
function PartyScreenController:_transition(mode)
  assert(type(mode) == "table" and type(mode.kind) == "string", "transitions install a complete mode")
  local current = self._mode
  if current.kind == "confirm" and current.prompt ~= nil then
    current.prompt:dispose()
    current.prompt = nil
  end
  self._mode = mode
  self._epoch = self._epoch + 1
  self._transitionCount = self._transitionCount + 1
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
---@param mode PartyScreenController.Mode
---@param direction string
function PartyScreenController:_moveMenu(mode, direction)
  assert(direction == "up" or direction == "down", "menus move vertically")
  assert(mode.kind == "menu", "menu motion needs an open menu")
  local index = assert(mode.index, "menu motion needs the focused entry")
  local count = #assert(mode.entries, "menu motion needs the open entries")
  if direction == "up" and index > 1 then
    mode.index = index - 1
  elseif direction == "down" and index < count then
    mode.index = index + 1
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

-- Captures a live menu mode as its value-only return descriptor: flavor,
-- slot, position, cursor, and a read-only snapshot of the background
-- entries the renderers keep showing behind prompts and messages.
---@param mode PartyScreenController.Mode
---@return PartyScreenController.Resume
function PartyScreenController:_menuResume(mode)
  assert(mode.kind == "menu", "menu returns resume an open menu")
  return {
    kind = "menu",
    flavor = assert(mode.flavor, "menu returns carry their flavor"),
    slot = assert(mode.slot, "menu returns carry their slot"),
    index = assert(mode.index, "menu returns carry their position"),
    cursor = self._cursorNode,
    entries = assert(mode.entries, "menu returns carry the background entries"),
  }
end

-- Opens the context menu over one occupied slot, remembering the origin
-- for the special return order.
---@param slot integer
function PartyScreenController:_openMenu(slot)
  local record = assert(self._view.slots[slot + 1], "context menus open over visible slots")
  self:_transition({
    kind = "menu",
    flavor = "context",
    entries = self:_menuFor(record),
    index = 1,
    slot = slot,
    originSlot = slot,
  })
end

-- Opens an item or mail submenu over the menu's slot.
---@param mode PartyScreenController.Mode
---@param menuKind "item"|"mail"
function PartyScreenController:_openSubmenu(mode, menuKind)
  assert(mode.kind == "menu", "submenus open from a context menu")
  local slot = assert(mode.slot, "submenus open from a context menu slot")
  local record = assert(self._view.slots[slot + 1], "submenus open over visible slots")
  local flavor = "item_context"
  if menuKind == "mail" then
    flavor = "mail_context"
  end
  self:_transition({
    kind = "menu",
    flavor = flavor,
    entries = self:_submenuFor(menuKind, record),
    index = 1,
    slot = slot,
    originSlot = mode.originSlot,
  })
end

-- Emits one value-only intent and parks in waiting_action; the flow
-- resolves it through completeAction. The final return descriptor rides
-- along now, so completion restores usable state without patching
-- anything after the fact.
---@param intent table<string, unknown>
---@param resume PartyScreenController.Resume
function PartyScreenController:_emitIntent(intent, resume)
  local mode = self._mode
  assert(mode.kind ~= "waiting_action" or mode.intent == nil, "an intent is already pending")
  assert(type(resume) == "table" and type(resume.kind) == "string", "emitted intents carry their return")
  self:_transition({ kind = "waiting_action", intent = intent, resume = resume })
end

-- Arms the owned yes/no confirm over one menu entry. The prompt opens at
-- the context window with a safe negative default; keyboard and pointer
-- rows share the prompt controller, which latches a choice and publishes
-- it after its confirmation interval. The tick-owned resolution step
-- below consumes the published result. The arming descriptor and the
-- decline outcome ride in the confirm mode, so neither path repairs
-- state after the fact.
---@param entry PartyScreenController.MenuEntry
---@param slot integer
---@param resume PartyScreenController.Resume
---@param decline table<string, unknown>?
function PartyScreenController:_openConfirm(entry, slot, resume, decline)
  local shape = assert(self._promptShape, "confirmation requires the injected prompt shape")
  local prompt = YesNoPromptController.new(shape)
  local layout = assert(self._layout(), "the party layout is required for prompt placement")
  local window = assert(layout.contextWindow, "the party layout carries the context window")
  prompt:open({ x = window.x, y = window.y, shape = "compact", initialSelection = "no" })
  self:_transition({ kind = "confirm", prompt = prompt, entry = entry, slot = slot, resume = resume, decline = decline })
end

-- Shows a message over the originating flow state; acknowledgement
-- returns there without replaying anything.
---@param text string
---@param resume PartyScreenController.Resume
function PartyScreenController:_showMessage(text, resume)
  assert(type(text) == "string" and text ~= "", "messages carry display text")
  self:_transition({ kind = "message", text = text, resume = resume })
end

-- Starts the five-stage swap: the source, destination, and live revision
-- freeze now; the final tick revalidates before publishing once.
---@param source integer
---@param destination integer
function PartyScreenController:_beginSwap(source, destination)
  local port = assert(self._swap, "swapping requires the injected domain port")
  self:_transition({
    kind = "swapping",
    source = source,
    destination = destination,
    revision = port.partyRevision(),
    step = 0,
    resume = { kind = "browse", cursor = source },
  })
end

-- Abandons an uncommitted swap with no domain mutation, returning to the
-- browse cursor the swap mode captured when it armed.
function PartyScreenController:_abortSwap()
  local mode = self._mode
  assert(mode.kind == "choose_swap" or mode.kind == "swapping", "aborts unwind an armed or running swap")
  self:_resume(assert(mode.resume, "swap modes carry their return"))
end

-- Advances one swap tick. Only the final stage touches the domain: it
-- revalidates the frozen revision, publishes exactly once through the
-- injected port, then re-reads the live party and restores the cursor.
function PartyScreenController:_advanceSwap()
  local mode = self._mode
  assert(mode.kind == "swapping", "swap ticks require an armed operation")
  local port = assert(self._swap, "swapping requires the injected domain port")
  local step = assert(mode.step, "swap modes carry their stage") + 1
  mode.step = step
  if step < SWAP_COMMIT_STEP then
    return
  end
  if port.partyRevision() ~= mode.revision then
    self:_abortSwap()
    return
  end
  local source = assert(mode.source, "swap modes carry their source")
  local destination = assert(mode.destination, "swap modes carry their destination")
  assert(source >= 0 and source < 6 and destination >= 0 and destination < 6, "swap slots stay in 0..5")
  port.swapPartyMons(source, destination)
  local view = self:_refresh()
  assert(view.revision == mode.revision + 1, "a committed swap observes exactly one party revision increment")
  if self:_selectable(view, destination) then
    self._cursorNode = destination
  end
  self:_transition({ kind = "browse" })
end

-- Advances the top-panel slide one step toward its state's target.
function PartyScreenController:_advanceSlide()
  local target = 0
  if MENU_OPEN_STATES[self:_publicState()] then
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
---@param mode PartyScreenController.Mode
function PartyScreenController:_confirmSlotTarget(mode)
  local node = self._cursorNode
  if node == "cancel" then
    if self._context == "pick" then
      if self._cancellable then
        self:_transition({ kind = "closing", result = { kind = "cancelled" } })
      end
      return
    end
    if mode.origin == "context" then
      self:_transition({ kind = "closing", result = { kind = "cancelled" } })
      return
    end
    self._cursorNode = self:_reconciledCursor(self._view, mode.slot)
    self:_transition({ kind = "browse" })
    return
  end
  if mode.kind == "choose_hp_target" then
    if not self:_selectable(self._view, node) then
      return
    end
    assert(isSlotNode(node), "transfer targets resolve to party slots")
    local donor = assert(mode.donorSlot, "transfer targeting remembers its donor")
    ---@cast node integer
    self:_emitIntent({
      kind = "transfer_hp",
      slot = donor,
      partyRevision = self._observedRevision,
      moveSlot = mode.donorMoveSlot,
      targetSlot = node,
    }, {
      kind = "target_hp",
      origin = mode.origin,
      slot = mode.slot,
      donorSlot = mode.donorSlot,
      donorMoveSlot = mode.donorMoveSlot,
      cursor = self._cursorNode,
    })
    return
  end
  if not self:_selectable(self._view, node) then
    return
  end
  assert(isSlotNode(node), "targets resolve to party slots")
  if self._context == "pick" then
    ---@cast node integer
    self:_transition({ kind = "closing", result = { kind = "selected", slot = node } })
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
      { kind = "target_item", origin = mode.origin, slot = mode.slot, cursor = self._cursorNode }
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
    }, { kind = "target_item", origin = mode.origin, slot = mode.slot, cursor = self._cursorNode })
  else
    ---@cast node integer
    self:_emitIntent({
      kind = "give",
      slot = node,
      partyRevision = revision,
      bagRevision = item.bagRevision,
      item = item.key,
    }, { kind = "target_item", origin = mode.origin, slot = mode.slot, cursor = self._cursorNode })
  end
end

-- Activates the focused context-menu entry through its kind.
---@param mode PartyScreenController.Mode
function PartyScreenController:_confirmMenuEntry(mode)
  assert(mode.kind == "menu", "menu activation needs an open menu")
  local entries = assert(mode.entries, "menu activation needs the open entries")
  local index = assert(mode.index, "menu activation needs a focused entry")
  local entry = assert(entries[index], "menu activation focuses a real entry")
  assert(type(entry.kind) == "string", "menu entries carry a kind")
  local slot = assert(mode.slot, "menu activation remembers its slot")
  local revision = self._observedRevision
  if entry.kind == "quit" then
    self:_transition({ kind = "closing", result = { kind = "closed" } })
    return
  end
  if entry.kind == "switch" then
    self:_transition({ kind = "choose_swap", source = slot, resume = { kind = "browse", cursor = slot } })
    return
  end
  if entry.kind == "item" or entry.kind == "mail" then
    self:_openSubmenu(mode, entry.kind)
    return
  end
  if entry.kind == "summary" then
    ---@cast slot integer
    self:_emitIntent({ kind = "summary", slot = slot, partyRevision = revision }, self:_menuResume(mode))
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
    }, self:_menuResume(mode))
    return
  end
  if entry.kind == "transfer_hp" then
    self:_transition({
      kind = "choose_hp_target",
      origin = "menu",
      slot = slot,
      donorSlot = slot,
      donorMoveSlot = entry.moveSlot,
    })
    return
  end
  if entry.confirm == true then
    self:_openConfirm(entry, slot, self:_menuResume(mode), nil)
    return
  end
  self:_emitEntryIntent(entry, slot, revision, self:_menuResume(mode))
end

-- Emits the intent for a directly activated menu entry.
---@param entry PartyScreenController.MenuEntry
---@param slot integer
---@param revision integer
---@param resume PartyScreenController.Resume
function PartyScreenController:_emitEntryIntent(entry, slot, revision, resume)
  local item = self._pendingItem
  if entry.kind == "give" or entry.kind == "take" then
    if entry.kind == "give" and item == nil then
      -- Picker-bound give: the owning flow opens the held-item picker
      -- for the captured slot, and the picked identity arrives with the
      -- later pick intent. Screens with a pending item keep their
      -- richer identity below.
      self:_emitIntent({ kind = entry.kind, slot = slot, partyRevision = revision }, resume)
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
    self:_emitIntent(intent, resume)
    return
  end
  if entry.kind == "read_mail" or entry.kind == "take_mail" then
    self:_emitIntent({ kind = entry.kind, slot = slot, partyRevision = revision }, resume)
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
    }, resume)
    return
  end
  error("unknown menu entry kind " .. tostring(entry.kind), 2)
end

-- Confirms the focused browse slot: occupied slots open their context
-- menu, cancel closes.
function PartyScreenController:_confirmBrowse()
  local node = self._cursorNode
  if node == "cancel" then
    self:_transition({ kind = "closing", result = { kind = "closed" } })
    return
  end
  if self:_selectable(self._view, node) then
    assert(isSlotNode(node), "menus open over party slots")
    ---@cast node integer
    self:_openMenu(node)
  end
end

---@param mode PartyScreenController.Mode
function PartyScreenController:_confirm(mode)
  if self._context == "pick" then
    self:_confirmSlotTarget(mode)
    return
  end
  if mode.kind == "browse" then
    self:_confirmBrowse()
    return
  end
  if mode.kind == "menu" then
    self:_confirmMenuEntry(mode)
    return
  end
  if mode.kind == "choose_swap" then
    self:_confirmSwapDestination(mode)
    return
  end
  if mode.kind == "choosing_item_target" or mode.kind == "choose_hp_target" then
    self:_confirmSlotTarget(mode)
    return
  end
  if mode.kind == "message" then
    self:_acknowledgeMessage(mode)
    return
  end
end

---@param mode PartyScreenController.Mode
function PartyScreenController:_cancel(mode)
  if mode.kind == "browse" then
    if self._context == "pick" then
      if self._cancellable then
        self:_transition({ kind = "closing", result = { kind = "cancelled" } })
      end
      return
    end
    if self._cancellable then
      self:_transition({ kind = "closing", result = { kind = "closed" } })
    end
    return
  end
  if mode.kind == "menu" then
    local origin = mode.originSlot
    if origin ~= nil and self:_selectable(self._view, origin) then
      self._cursorNode = origin
    end
    self:_transition({ kind = "browse" })
    return
  end
  if mode.kind == "choose_swap" or mode.kind == "swapping" then
    self:_abortSwap()
    return
  end
  if mode.kind == "choosing_item_target" or mode.kind == "choose_hp_target" then
    if mode.origin == "context" then
      self:_transition({ kind = "closing", result = { kind = "cancelled" } })
      return
    end
    self._cursorNode = self:_reconciledCursor(self._view, mode.slot)
    self:_transition({ kind = "browse" })
    return
  end
  if mode.kind == "message" then
    self:_acknowledgeMessage(mode)
    return
  end
end

-- Confirms the swap destination: the source itself or cancel abandons,
-- another occupied slot arms the delayed commit. The source is required
-- mode data: its absence is a programming error, never a silent return
-- to browse.
---@param mode PartyScreenController.Mode
function PartyScreenController:_confirmSwapDestination(mode)
  assert(mode.kind == "choose_swap", "swap destinations resolve in the destination pick")
  local node = self._cursorNode
  local source = assert(mode.source, "swap targeting remembers its source")
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
-- entry authorizes the exchange, and the slot rides the confirm mode so
-- the affirmative intent resolves without an open menu. Declining ends
-- in a single cancellation result because there is no arming menu.
---@param mode PartyScreenController.Mode
function PartyScreenController:_openGiveConfirm(mode)
  assert(mode.kind == "give_confirm", "the replacement question opens from its captured target")
  local target = assert(mode.target, "the replacement question answers for a party slot")
  assert(self:_selectable(self._view, target), "the replacement question answers for an occupied slot")
  local item = assert(self._pendingItem, "the replacement question names its pending item")
  self:_openConfirm(
    { kind = "give", label = item.key, confirmed = true },
    target,
    { kind = "browse", cursor = target },
    { kind = "cancelled" }
  )
end

-- Consumes one published prompt result after the tick-owned prompt step:
-- YES publishes the armed entry intent with the arming descriptor that
-- rode in, NO returns through that same descriptor or ends in the
-- confirm's decline result. Either way the prompt releases exactly once
-- through the transition out of confirm.
---@param mode PartyScreenController.Mode
function PartyScreenController:_resolvePrompt(mode)
  assert(mode.kind == "confirm", "prompt resolution needs its owned prompt")
  local prompt = assert(mode.prompt, "prompt resolution needs its owned prompt")
  local result = prompt:takeResult()
  if result == nil then
    return
  end
  local entry = assert(mode.entry, "prompt resolution remembers its entry")
  local slot = assert(mode.slot, "prompt intents remember their slot")
  local resume = assert(mode.resume, "prompt paths carry their return")
  local decline = mode.decline
  if result == "yes" then
    ---@cast slot integer
    self:_emitEntryIntent(entry, slot, self._observedRevision, resume)
    return
  end
  assert(result == "no", "prompts resolve yes or no")
  if decline ~= nil then
    self:_transition({ kind = "closing", result = decline })
    return
  end
  self:_resume(resume)
end

-- Declines the owned confirm without publishing: control returns through
-- the arming descriptor, or the confirm's decline result when the
-- replacement question has no arming menu. Declining mutates nothing, so
-- it never waits for the confirmation interval.
---@param mode PartyScreenController.Mode
function PartyScreenController:_declinePrompt(mode)
  assert(mode.kind == "confirm", "declining needs the owned prompt")
  assert(mode.prompt ~= nil, "declining needs the owned prompt")
  local resume = assert(mode.resume, "prompt paths carry their return")
  local decline = mode.decline
  if decline ~= nil then
    self:_transition({ kind = "closing", result = decline })
    return
  end
  self:_resume(resume)
end

-- Owns one fixed tick inside the yes/no confirm: unknown events raise
-- in prompt states exactly like ordinary states, dismiss and cancel
-- decline immediately without publishing, and every other event batch
-- drives the owned prompt exactly once before the tick-owned resolution
-- consumes a published result. Prompt rows latch on press through the
-- owned prompt; the release never activates by itself.
---@param mode PartyScreenController.Mode
---@param uiInput table[]
function PartyScreenController:_stepPrompt(mode, uiInput)
  for _, event in ipairs(uiInput) do
    assert(type(event) == "table" and type(event.type) == "string", "party events need a type")
    if event.type == "dismiss" or event.type == "cancel" then
      self:_declinePrompt(mode)
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
  local live = self._mode
  assert(live.kind == "confirm", "prompt ticks need the owned prompt")
  assert(live.prompt ~= nil, "prompt ticks need the owned prompt")
  live.prompt:updateFixed(uiInput)
  self:_resolvePrompt(live)
end

-- Acknowledges the message and returns through its descriptor without
-- replaying anything.
---@param mode PartyScreenController.Mode
function PartyScreenController:_acknowledgeMessage(mode)
  assert(mode.kind == "message", "acknowledgement needs the shown message")
  self:_resume(assert(mode.resume, "messages carry their return"))
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
---@param mode PartyScreenController.Mode
---@param target table<string, unknown>?
function PartyScreenController:_activate(mode, target)
  if target == nil then
    return
  end
  if mode.kind == "browse" then
    if target.kind == "cancel" then
      self:_cancel(mode)
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
          self:_confirmSlotTarget(mode)
        else
          self:_confirmBrowse()
        end
      end
    end
    return
  end
  if mode.kind == "menu" then
    if target.kind == "menu" and type(target.index) == "number" then
      local entries = assert(mode.entries, "menu activation needs its open entries")
      if target.index >= 1 and target.index <= #entries then
        mode.index = target.index
        self:_confirmMenuEntry(mode)
      end
    end
    return
  end
  if mode.kind == "choose_swap" or mode.kind == "choosing_item_target" or mode.kind == "choose_hp_target" then
    if target.kind == "slot" and isSlotNode(target.slot) then
      if self:_selectable(self._view, target.slot) then
        self._cursorNode = target.slot
        if mode.kind == "choose_swap" then
          self:_confirmSwapDestination(mode)
        else
          self:_confirmSlotTarget(mode)
        end
      end
    elseif target.kind == "cancel" then
      self:_cancel(mode)
    end
    return
  end
  if mode.kind == "message" then
    self:_acknowledgeMessage(mode)
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

---@param mode PartyScreenController.Mode
---@param event table<string, unknown>
function PartyScreenController:_pointerDown(mode, event)
  if self._pressId ~= nil then
    return
  end
  assert(type(event.pointerId) == "string", "pointer down needs a pointer id")
  self._pressId = event.pointerId
  self._pressEpoch = self._epoch
  local layout = assert(self._layout(), "the party layout is required for pointer input")
  if mode.kind == "menu" then
    local rows = assert(layout.menuRows, "the party layout carries menu rows")
    local entries = assert(mode.entries, "menu presses need the open entries")
    local hit = rows(#entries)
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

---@param mode PartyScreenController.Mode
---@param event table<string, unknown>
function PartyScreenController:_pointerUp(mode, event)
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
  if mode.kind == "menu" then
    local rows = assert(layout.menuRows, "the party layout carries menu rows")
    local entries = assert(mode.entries, "menu presses need the open entries")
    local hit = rows(#entries)
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
    self:_activate(mode, up)
  end
end

-- One fixed tick over the tick's UI events. Clocks advance first: icon
-- phases, the panel slide, and an armed swap all step once per tick while
-- open. At most one state consumes an event batch: the batch ends when a
-- transition fires, even when the public state string stays equal. A
-- completed controller ignores further input.
---@param uiInput table[]
function PartyScreenController:updateFixed(uiInput)
  assert(type(uiInput) == "table", "the party input must be an event list")
  if self._mode.kind == "closed" then
    return
  end
  self._tick = self._tick + 1
  local previousRevision = self._observedRevision
  local view = self:_refresh()
  self:_trackSequences(view)
  self:_advanceSlide()
  local mode = self._mode
  if mode.kind == "swapping" then
    self:_advanceSwap()
    return
  end
  if mode.kind == "confirm" then
    self:_stepPrompt(mode, uiInput)
    return
  end
  if mode.kind == "give_confirm" then
    -- First fixed update with a resolved layout: open the replacement
    -- question and ignore this batch, so the transition that opened the
    -- page can never answer its own prompt.
    self:_openGiveConfirm(mode)
    return
  end
  if view.revision ~= previousRevision then
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
    if self._mode.kind == "closed" then
      break
    end
    assert(type(event) == "table" and type(event.type) == "string", "party events need a type")
    local transitionsBefore = self._transitionCount
    local live = self._mode
    if event.type == "navigate" then
      self:_navigate(live, event)
    elseif event.type == "confirm" then
      self:_confirm(live)
    elseif event.type == "cancel" then
      self:_cancel(live)
    elseif event.type == "dismiss" then
      self:_dismiss(live)
    elseif event.type == "pointer_down" then
      self:_pointerDown(live, event)
    elseif event.type == "pointer_move" then
      self:_pointerMove(event)
    elseif event.type == "pointer_up" then
      self:_pointerUp(live, event)
    elseif event.type == "pointer_cancel" then
      self:cancelPointerCapture()
    elseif event.type == "menu" or event.type == "pointer_scroll" then
      -- A child application's own input policy applies: the synthesized
      -- menu edge and scroll events never drive the party screen.
    else
      error("unknown party event type " .. tostring(event.type), 2)
    end
    if self._mode.kind == "closed" then
      break
    end
    if self._transitionCount ~= transitionsBefore then
      break
    end
  end
end

-- Routes directional input: menu lists move vertically clamped, slot
-- states walk the compiled graph.
---@param mode PartyScreenController.Mode
---@param event table<string, unknown>
function PartyScreenController:_navigate(mode, event)
  if mode.kind == "menu" then
    self:_moveMenu(mode, assert(event.direction, "navigation needs a direction"))
    return
  end
  if
    mode.kind == "browse"
    or mode.kind == "choose_swap"
    or mode.kind == "choosing_item_target"
    or mode.kind == "choose_hp_target"
  then
    self:_move(assert(event.direction, "navigation needs a direction"))
    return
  end
end

-- Interprets outside dismissal by owning state: normal browse flows
-- close, target and confirmation flows cancel their operation without
-- committing, gated animation and waiting states ignore it.
---@param mode PartyScreenController.Mode
function PartyScreenController:_dismiss(mode)
  if mode.kind == "browse" or mode.kind == "menu" then
    if self._context == "pick" then
      error("party dismiss is a browse-flow edge; pick context never emits it", 2)
    end
    self:_transition({ kind = "closing", result = { kind = "closed" } })
    return
  end
  if mode.kind == "choose_swap" or mode.kind == "choosing_item_target" or mode.kind == "choose_hp_target" then
    self:_cancel(mode)
    return
  end
  if mode.kind == "message" then
    self:_acknowledgeMessage(mode)
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
  local mode = self._mode
  if mode.kind == "closed" then
    return { open = false }
  end
  local state = self:_publicState()
  local swapStatus
  if mode.kind == "swapping" then
    local step = assert(mode.step, "swap status reads an armed operation")
    local stage = "start"
    local offsetPx = 0
    local exchanged = false
    if step >= SWAP_MIDPOINT_STEP then
      stage = "in"
      exchanged = true
      offsetPx = -SWAP_FULL_OFFSET + (step - SWAP_MIDPOINT_STEP) * SWAP_PIXEL_STEP
    elseif step >= 2 then
      stage = "out"
      offsetPx = -(step - 1) * SWAP_PIXEL_STEP
    end
    swapStatus = {
      source = assert(mode.source, "swap status reads an armed operation"),
      destination = assert(mode.destination, "swap status reads an armed operation"),
      step = step,
      stage = stage,
      offsetPx = offsetPx,
      exchanged = exchanged,
    }
  end
  local menu = nil
  local menuIndex = nil
  local menuSlot = nil
  local message = nil
  local prompt = nil
  if mode.kind == "menu" then
    menu = mode.entries
    menuIndex = mode.index
    menuSlot = mode.slot
  elseif mode.kind == "confirm" then
    menuSlot = mode.slot
    local owned = assert(mode.prompt, "confirm states carry the prompt status")
    prompt = owned:status()
    local resume = assert(mode.resume, "prompt paths carry their return")
    if resume.kind == "menu" then
      menu = resume.entries
      menuIndex = resume.index
    end
  elseif mode.kind == "waiting_action" or mode.kind == "message" then
    local resume = assert(mode.resume, "waiting and message states carry their return")
    if resume.kind == "menu" then
      menu = resume.entries
      menuIndex = resume.index
      menuSlot = resume.slot
    elseif resume.kind == "target_item" or resume.kind == "target_hp" then
      if resume.origin == "menu" then
        menuSlot = resume.slot
      end
    end
    if mode.kind == "message" then
      message = mode.text
    end
  elseif mode.kind == "choose_swap" or mode.kind == "swapping" then
    menuSlot = mode.source
  elseif mode.kind == "choose_hp_target" then
    if mode.origin == "menu" then
      menuSlot = mode.slot
    end
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
    state = state,
    mode = self._context,
    action = state,
    cursorNode = self._cursorNode,
    menuIndex = menuIndex,
    menu = menu,
    menuSlot = menuSlot,
    message = message,
    prompt = prompt,
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
  local mode = self._mode
  if mode.kind ~= "waiting_action" then
    return nil
  end
  local intent = mode.intent
  mode.intent = nil
  return intent
end

-- Resolves the pending intent from the flow. The presentation-only no-op
-- returns through the waiting return descriptor with no message,
-- mutation, or new intent; any other outcome shows its text when present
-- and otherwise returns the same way. Outcomes for another state are a
-- programming error.
---@param outcome table<string, unknown>
function PartyScreenController:completeAction(outcome)
  assert(type(outcome) == "table", "action completion carries an outcome")
  local mode = self._mode
  assert(mode.kind == "waiting_action", "action completion resolves a pending intent")
  assert(mode.intent == nil, "the flow takes the intent before completing it")
  local resume = assert(mode.resume, "waiting remembers its return")
  if outcome.kind == "no_op" then
    self:_resume(resume)
    return
  end
  if type(outcome.text) == "string" and outcome.text ~= "" then
    self:_showMessage(outcome.text, resume)
    return
  end
  self:_resume(resume)
end

-- Returns through one value-only descriptor, rebuilt from the latest
-- party facts: menus reopen only over a still-occupied slot with live
-- entries, targets restore their origin, and anything unusable falls
-- back to browse with a reconciled cursor. A menu state without its
-- menu is impossible.
---@param resume PartyScreenController.Resume
function PartyScreenController:_resume(resume)
  assert(type(resume) == "table" and type(resume.kind) == "string", "resumption carries a return descriptor")
  local view = self._view
  if resume.kind == "browse" then
    self._cursorNode = self:_reconciledCursor(view, resume.cursor)
    self:_transition({ kind = "browse" })
    return
  end
  if resume.kind == "menu" then
    local slot = assert(resume.slot, "menu returns carry their slot")
    local record = view.slots[slot + 1]
    if record ~= nil and record.occupied then
      local entries
      if resume.flavor == "context" then
        entries = self:_menuFor(record)
      else
        entries = self:_submenuFor(resume.flavor == "mail_context" and "mail" or "item", record)
      end
      if #entries > 0 then
        local index = resume.index
        if type(index) ~= "number" or index < 1 or index > #entries then
          index = 1
        end
        self._cursorNode = self:_reconciledCursor(view, resume.cursor)
        self:_transition({
          kind = "menu",
          flavor = resume.flavor,
          entries = entries,
          index = index,
          slot = slot,
          originSlot = slot,
        })
        return
      end
    end
    self._cursorNode = self:_reconciledCursor(view, resume.cursor)
    self:_transition({ kind = "browse" })
    return
  end
  if resume.kind == "target_item" then
    self._cursorNode = self:_reconciledCursor(view, resume.cursor)
    self:_transition({ kind = "choosing_item_target", origin = resume.origin, slot = resume.slot })
    return
  end
  if resume.kind == "target_hp" then
    self._cursorNode = self:_reconciledCursor(view, resume.cursor)
    self:_transition({
      kind = "choose_hp_target",
      origin = resume.origin,
      slot = resume.slot,
      donorSlot = resume.donorSlot,
      donorMoveSlot = resume.donorMoveSlot,
    })
    return
  end
  error("unknown return descriptor " .. tostring(resume.kind), 2)
end

-- The one-shot result contract: nil until a terminal event, then exactly
-- one semantic record that closes the controller.
---@return { kind: "closed"|"selected"|"cancelled", slot?: integer }?
function PartyScreenController:takeResult()
  local mode = self._mode
  if mode.kind ~= "closing" then
    return nil
  end
  local result = assert(mode.result, "closing carries its terminal result")
  self:_transition({ kind = "closed" })
  return result
end

-- Idempotent release of the logical lifetime: a pending result is
-- discarded and no completion is reported after disposal.
function PartyScreenController:dispose()
  self:_transition({ kind = "closed" })
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
