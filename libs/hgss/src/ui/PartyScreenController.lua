-- The native party-screen controller: one fixed-tick state machine over an
-- injected immutable view. Named contexts (browse, pick, item_target,
-- give_target, give_resume) replace the legacy view/select modes. Browse opens
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
---@field _context "browse"|"pick"|"item_target"|"give_target"|"give_resume"
---@field _model PartyScreenController.Model
---@field _layout fun(): table<string, unknown>
---@field _swap PartyScreenController.SwapPort?
---@field _effect fun(sequence: string)? the borrowed swap sound boundary; swap stays silent without it
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
---@field _transitionCount integer
---@field _pressId string?
---@field _pressCapture PartyScreenController.Capture?
---@field _pressEpoch integer?
---@field _swapOp { source: integer, destination: integer, revision: integer, phase: string, xOffset: integer, exchanged: boolean }?
---@field _intent table<string, unknown>?
---@field _origin PartyScreenController.Origin?
---@field _message string|{ templateKey: string, displayName: string?, itemNames: string[]? }?
---@field _messageReturn string
---@field _prompt YesNoPromptController?
---@field _promptReturn string
---@field _promptEntry PartyScreenController.MenuEntry?
---@field _result PartyScreenController.Result?
---@field _closed boolean
---@field _tick integer
---@field _donorSlot integer?
---@field _donorMoveSlot integer?
---@field _menuPress { index: integer, timer: integer }? the armed source press gate: two pressed ticks, two selected ticks, then exactly one semantic dispatch
---@field _swapSource integer?
---@field _seq integer[]
---@field _seqBase integer[]
---@field _panelSlide integer
---@field _targetOrigin "menu"|"context"?
---@field _giveDisposition "party"|"bag"?
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
---@field kind "slot"|"menu"|"cancel"|"prompt"
---@field slot integer?
---@field index integer?
---@field choice string?

---@class PartyScreenController.Origin
---@field state string
---@field cursorNode integer|"cancel"
---@field menuIndex integer?
---@field menuSlot integer?
---@field partyRevision integer

---@class PartyScreenController.Result
---@field kind "closed"|"selected"|"cancelled"|"give_complete"
---@field slot integer?

---@class PartyScreenController.Options
---@field context "browse"|"pick"|"item_target"|"give_target"|"give_resume"
---@field initialFocus integer|"cancel"?
---@field allowCancel boolean?
---@field model PartyScreenController.Model
---@field layout fun(): table<string, unknown>
---@field swap PartyScreenController.SwapPort?
---@field actionPolicy table<string, unknown>?
---@field promptShape table<string, unknown>?
---@field item { key: string, bagRevision: integer }?
---@field effect fun(sequence: string)? the borrowed swap sound boundary; swap stays silent without it
---@field initialMessage { templateKey: "giveHeldItem", displayName: string, itemNames: string[] }? initial Party-owned held-item result

-- The native switch task slides each travelling slot out from its own
-- column and back: sixteen tile-steps to full exit, eight pixels per
-- step. Even slots exit left, odd slots exit right. The list sound fires
-- on the opening task and again when the visible records exchange; only
-- the final task publishes the authoritative order.
local SWAP_MAX_OFFSET = 16
local SWAP_PIXEL_STEP = 8
local SWAP_SOUND = "SEQ_SE_DP_POKELIST_001"
local CANCEL_SOUND = "SEQ_SE_GS_GEARCANCEL"

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
      or opts.context == "give_resume",
    "the party controller requires a named browse, pick, item_target, give_target, or give_resume context"
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
  if opts.initialMessage ~= nil then
    local message = opts.initialMessage
    assert(opts.context == "browse", "initial result messages enter only the browse context")
    assert(
      type(message) == "table" and message.templateKey == "giveHeldItem",
      "initial result uses the Party held-item template"
    )
    assert(
      type(message.displayName) == "string" and type(message.itemNames) == "table" and #message.itemNames == 1,
      "held-item result names its mon and item"
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
  if opts.effect ~= nil then
    assert(type(opts.effect) == "function", "the swap sound boundary is a function")
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
    _state = opts.initialMessage ~= nil and "message" or "browse",
    _cursorNode = 0,
    _menu = nil,
    _menuIndex = nil,
    _menuSlot = nil,
    _originSlot = nil,
    _footerColumn = 1,
    _epoch = 0,
    _transitionCount = 0,
    _pressId = nil,
    _pressCapture = nil,
    _pressEpoch = nil,
    _swapOp = nil,
    _intent = nil,
    _origin = nil,
    _message = opts.initialMessage,
    _messageReturn = "browse",
    _prompt = nil,
    _promptReturn = "browse",
    _promptEntry = nil,
    _result = nil,
    _closed = false,
    _tick = 0,
    _donorSlot = nil,
    _donorMoveSlot = nil,
    _menuPress = nil,
    _swapSource = nil,
    _effect = opts.effect,
    _seq = {},
    _seqBase = {},
    _panelSlide = 0,
    _targetOrigin = nil,
    _giveDisposition = opts.context == "give_resume" and "party" or (opts.context == "give_target" and "bag" or nil),
  }, PartyScreenController)
  if opts.context == "item_target" or opts.context == "give_target" then
    assert(opts.item ~= nil, "target contexts require the pending item identity")
    self._state = "choosing_item_target"
    self._targetOrigin = "context"
  elseif opts.context == "give_resume" then
    assert(opts.item ~= nil, "the give continuation names its pending item")
    assert(
      type(opts.initialFocus) == "number"
        and opts.initialFocus % 1 == 0
        and opts.initialFocus >= 0
        and opts.initialFocus < 6,
      "the give continuation targets a party slot"
    )
    self._state = "give_resume"
  end
  local view = self:_refresh()
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
  if opts.context == "give_resume" then
    assert(self:_selectable(view, opts.initialFocus), "the give continuation targets an occupied slot")
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

-- Tracks icon animation sequences per slot: the sequence clock starts on
-- first observation and restarts only when the sequence changes, so
-- steady health holds its rhythm while a new sequence starts at zero.
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

-- Keeps a valid selection or moves to the nearest live slot.
---@param view PartyScreenController.View
---@param node integer|string
---@return integer|string
function PartyScreenController:_reconciledCursor(view, node)
  if self:_selectable(view, node) then
    return node
  end
  local reconciled = self:_nearestSelectable(view, node)
  return reconciled or self._cursorNode
end

---@return boolean
function PartyScreenController:cancellable()
  return self._cancellable
end

-- State changes dispose prompts, disarm the menu press gate, and
-- invalidate any held pointer press, even when the public state name
-- stays the same.
---@param state string
function PartyScreenController:_transition(state)
  if self._state == "confirm" and state ~= "confirm" then
    self:_closePrompt()
  end
  self._state = state
  if state == "closed" then
    self._closed = true
  end
  self._epoch = self._epoch + 1
  self._transitionCount = self._transitionCount + 1
  self._pressId = nil
  self._pressCapture = nil
  self._pressEpoch = nil
  self._menuPress = nil
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

-- Moves within the open menu through the generated source neighbor map
-- for the active menu class and count. Absent links (subcontext lateral
-- input) hold focus; activation policy lives with the entry kind.
---@param direction string
function PartyScreenController:_moveMenu(direction)
  assert(
    direction == "up" or direction == "down" or direction == "left" or direction == "right",
    "unknown menu direction"
  )
  local index = assert(self._menuIndex, "menu motion needs an open menu")
  local entries = self:_menuLayoutFor()
  local entry = assert(entries[index], "menu motion focuses a real entry")
  local next = entry[direction]
  if next ~= nil then
    assert(next % 1 == 0 and next >= 1 and next <= #entries, "menu neighbors address real entries")
    self._menuIndex = next
  end
end

-- Names the generated menu section for the open menu state.
---@return "topLevel"|"subcontext"
function PartyScreenController:_menuKind()
  if self._state == "item_context" or self._state == "mail_context" then
    return "subcontext"
  end
  assert(self._state == "context", "menu geometry needs an open menu state")
  return "topLevel"
end

-- Resolves the generated source records for the open menu, failing loudly
-- when the entry count leaves the audited source range.
---@return table[]
function PartyScreenController:_menuLayoutFor()
  local menu = assert(self._menu, "menu geometry needs an open menu")
  local layout = assert(self._layout(), "the party layout is required for menu geometry")
  local lookup = assert(layout.menuLayout, "the party layout carries generated menu records")
  return lookup(self:_menuKind(), #menu)
end

-- Arms the source press gate over the focused menu entry: the semantic
-- entry, index, and state freeze now while pointer capture invalidates
-- through the normal epoch rules. A focused quit row requests the single
-- cancel effect here at initiation. Dispatch waits for the visual cadence
-- (two pressed ticks, two selected ticks) owned by the fixed update.
function PartyScreenController:_beginMenuPress()
  assert(self._menuPress == nil, "menu presses arm exactly once")
  local menu = assert(self._menu, "menu activation needs an open menu")
  local index = assert(self._menuIndex, "menu activation needs a focused entry")
  local entry = assert(menu[index], "menu activation focuses a real entry")
  assert(type(entry.kind) == "string", "menu entries carry a kind")
  self:_menuLayoutFor()
  if entry.kind == "quit" then
    self:_requestCancelSound()
  end
  self._menuPress = { index = index, timer = 0 }
  self._pressId = nil
  self._pressCapture = nil
  self._pressEpoch = nil
  self._epoch = self._epoch + 1
end

-- Advances the armed press one fixed tick; the step past the selected
-- half dispatches the captured entry exactly once through the existing
-- semantic path.
function PartyScreenController:_advanceMenuPress()
  local armed = assert(self._menuPress, "press ticks require an armed press")
  armed.timer = armed.timer + 1
  if armed.timer < 4 then
    return
  end
  local index = armed.index
  self._menuPress = nil
  self._menuIndex = index
  self:_confirmMenuEntry()
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
-- for the special return order. Counts outside the generated source
-- range fail before anything arms.
---@param slot integer
function PartyScreenController:_openMenu(slot)
  local record = assert(self._view.slots[slot + 1], "context menus open over visible slots")
  local menu = self:_menuFor(record)
  local layout = assert(self._layout(), "the party layout is required for menu geometry")
  local lookup = assert(layout.menuLayout, "the party layout carries generated menu records")
  lookup("topLevel", #menu)
  self._menu = menu
  self._menuIndex = 1
  self._menuSlot = slot
  self._originSlot = slot
  self:_transition("context")
end

-- Opens an item or mail submenu over the menu's slot.
---@param menuKind "item"|"mail"
function PartyScreenController:_openSubmenu(menuKind)
  local slot = assert(self._menuSlot, "submenus open from a context menu slot")
  local record = assert(self._view.slots[slot + 1], "submenus open over visible slots")
  local menu = self:_submenuFor(menuKind, record)
  local layout = assert(self._layout(), "the party layout is required for menu geometry")
  local lookup = assert(layout.menuLayout, "the party layout carries generated menu records")
  lookup("subcontext", #menu)
  self._menu = menu
  self._menuIndex = 1
  if menuKind == "mail" then
    self:_transition("mail_context")
  else
    self:_transition("item_context")
  end
end

-- Emits one value-only intent and parks in waiting_action; the flow
-- resolves it through completeAction. The origin restores cursor and menu
-- position once the outcome lands.
---@param intent table<string, unknown>
function PartyScreenController:_emitIntent(intent)
  assert(self._intent == nil, "an intent is already pending")
  self._intent = intent
  self._origin = {
    state = self._state,
    cursorNode = self._cursorNode,
    partyRevision = self._observedRevision,
    menuSlot = self._menuSlot,
    menuIndex = self._menuIndex,
  }
  self:_transition("waiting_action")
end

-- Arms the owned yes/no confirm over one menu entry. The prompt opens at
-- the generated native anchor with a safe negative default; keyboard and pointer
-- rows share the prompt controller, which latches a choice and publishes
-- it after its confirmation interval. The tick-owned resolution step
-- below consumes the published result.
---@param entry PartyScreenController.MenuEntry
---@param returnState string
function PartyScreenController:_openConfirm(entry, returnState)
  local shape = assert(self._promptShape, "confirmation requires the injected prompt shape")
  local prompt = YesNoPromptController.new(shape)
  local layout = assert(self._layout(), "the party layout is required for prompt placement")
  local anchor = assert(layout.promptAnchor, "the party layout carries the native prompt anchor")
  prompt:open({
    x = assert(anchor.x, "the prompt anchor carries x"),
    y = assert(anchor.y, "the prompt anchor carries y"),
    shape = "compact",
    initialSelection = "no",
  })
  self._prompt = prompt
  self._promptEntry = entry
  self._promptReturn = returnState
  self:_transition("confirm")
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
-- returns there without replaying anything. Either existing literal text
-- or a generated-template descriptor the renderer expands.
---@param text string|{ templateKey: string, displayName: string?, itemNames: string[]? }
---@param returnState string
function PartyScreenController:_showMessage(text, returnState)
  if type(text) == "table" then
    assert(type(text.templateKey) == "string" and text.templateKey ~= "", "descriptors name their template")
    assert(text.displayName == nil or type(text.displayName) == "string", "descriptors carry an optional display name")
    if text.itemNames ~= nil then
      assert(type(text.itemNames) == "table", "descriptors carry ordered item names")
      for _, itemName in ipairs(text.itemNames) do
        assert(type(itemName) == "string", "descriptors carry ordered item names")
      end
    end
  else
    assert(type(text) == "string" and text ~= "", "messages carry display text")
  end
  self._message = text
  self._messageReturn = returnState
  self:_transition("message")
end

-- Private operation semantics, not a public schema.
-- start: sound/no motion; outward: xOffset 1..16; exchange: swap visible
-- records + sound; inward: xOffset 15..0; commit: validate and publish
-- authoritative party order.
-- Starts the column-parity swap: the source, destination, and live revision
-- freeze now; arming stays silent and the opening tick carries the sound.
-- The exchange tick swaps only temporary draw records and the final tick
-- revalidates before publishing once.
---@param source integer
---@param destination integer
function PartyScreenController:_beginSwap(source, destination)
  local port = assert(self._swap, "swapping requires the injected domain port")
  self._swapOp = {
    source = source,
    destination = destination,
    revision = port.partyRevision(),
    phase = "start",
    xOffset = 0,
    exchanged = false,
  }
  self:_transition("swapping")
end

-- Requests one list sound through the borrowed effect boundary when the
-- owning flow supplied one; screens without the boundary stay silent and
-- still reorder exactly once.
function PartyScreenController:_requestSwapSound()
  local effect = self._effect
  if effect ~= nil then
    effect(SWAP_SOUND)
  end
end

-- Requests the source cancel sound through the borrowed effect boundary.
function PartyScreenController:_requestCancelSound()
  local effect = self._effect
  if effect ~= nil then
    effect(CANCEL_SOUND)
  end
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
  self:_transition("browse")
end

-- Advances exactly one swap phase per tick. The opening tick sounds with
-- no motion, outward ticks climb 1..16, the exchange tick swaps only
-- temporary draw records with the second sound, inward ticks descend
-- 15..0, and only the final tick touches the domain: it revalidates the
-- frozen revision, publishes exactly once through the injected port, then
-- re-reads the live party and restores the cursor.
function PartyScreenController:_advanceSwap()
  local op = assert(self._swapOp, "swap ticks require an armed operation")
  local port = assert(self._swap, "swapping requires the injected domain port")
  if op.phase == "start" then
    self:_requestSwapSound()
    op.phase = "outward"
    return
  end
  if op.phase == "outward" then
    op.xOffset = op.xOffset + 1
    assert(op.xOffset >= 0 and op.xOffset <= SWAP_MAX_OFFSET, "swap offsets stay within full exit")
    if op.xOffset >= SWAP_MAX_OFFSET then
      op.phase = "exchange"
    end
    return
  end
  if op.phase == "exchange" then
    op.exchanged = true
    self:_requestSwapSound()
    op.phase = "inward"
    return
  end
  if op.phase == "inward" then
    op.xOffset = op.xOffset - 1
    assert(op.xOffset >= 0 and op.xOffset <= SWAP_MAX_OFFSET, "swap offsets stay within full exit")
    if op.xOffset <= 0 then
      op.phase = "commit"
    end
    return
  end
  assert(op.phase == "commit", "swap ticks run start, outward, exchange, inward, then commit")
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
  self:_transition("browse")
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
        self:_transition("closing")
      end
      return
    end
    if self._targetOrigin == "context" then
      self._result = { kind = "cancelled" }
      self:_transition("closing")
      return
    end
    self:_transition("browse")
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
    self:_transition("closing")
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

-- Dismisses an open context menu back to browse with no result or
-- intent: menu state cleared, the origin slot restored when still
-- selectable. This is the silent semantic completion after the press
-- gate; the cancel effect was already requested when the quit press
-- was armed.
function PartyScreenController:_dismissMenu()
  assert(
    self._state == "context" or self._state == "item_context" or self._state == "mail_context",
    "menu dismissal needs an open context menu"
  )
  local slot = self._originSlot
  self._menu = nil
  self._menuIndex = nil
  self._menuSlot = nil
  self._originSlot = nil
  if slot ~= nil and self:_selectable(self._view, slot) then
    self._cursorNode = slot
  end
  self:_transition("browse")
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
    self:_dismissMenu()
    return
  end
  if entry.kind == "switch" then
    self._swapSource = slot
    self._menu = nil
    self._menuIndex = nil
    self:_transition("choose_swap")
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
    self:_transition("choose_hp_target")
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
    self:_requestCancelSound()
    self._result = { kind = "closed" }
    self:_transition("closing")
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
    self:_beginMenuPress()
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
        self:_transition("closing")
      end
      return
    end
    if self._cancellable then
      self:_requestCancelSound()
      self._result = { kind = "closed" }
      self:_transition("closing")
    end
    return
  end
  if self._state == "context" or self._state == "item_context" or self._state == "mail_context" then
    local menu = assert(self._menu, "menu cancellation needs its open menu")
    local quitIndex = nil
    for index, entry in ipairs(menu) do
      assert(type(entry.kind) == "string", "menu entries carry a kind")
      if entry.kind == "quit" then
        quitIndex = index
      end
    end
    assert(quitIndex ~= nil, "context menus cancel through their quit row")
    self._menuIndex = assert(quitIndex, "menu cancellation focuses its quit row")
    self:_beginMenuPress()
    return
  end
  if self._state == "choose_swap" or self._state == "swapping" then
    self:_abortSwap()
    return
  end
  if self._state == "choosing_item_target" or self._state == "choose_hp_target" then
    if self._targetOrigin == "context" then
      self._result = { kind = "cancelled" }
      self:_transition("closing")
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
    self:_transition("browse")
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
    self:_transition("browse")
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
  if self._giveDisposition ~= nil then
    self:_finishGive()
    return
  end
  self:_transition(returnState)
end

-- Declines the owned confirm without publishing: the prompt closes
-- exactly once and control returns to the arming menu. The replacement
-- question declines with a single cancellation result instead.
-- Declining mutates nothing, so it never waits for the confirmation
-- interval.
function PartyScreenController:_declinePrompt()
  local returnState = self._promptReturn
  self:_closePrompt()
  if self._giveDisposition ~= nil then
    self:_finishGive()
    return
  end
  self:_transition(returnState)
end

-- Finishes the caller-specific held-item transaction after its question
-- or result message has been acknowledged.
function PartyScreenController:_finishGive()
  local disposition = assert(self._giveDisposition, "held-item feedback records its caller")
  self._giveDisposition = nil
  self._pendingItem = nil
  self._menu = nil
  self._menuIndex = nil
  self._menuSlot = nil
  self._originSlot = nil
  self._origin = nil
  if disposition == "party" then
    self._context = "browse"
    self._result = { kind = "give_complete" }
    self:_transition("browse")
  else
    self._result = { kind = "cancelled" }
    self:_transition("closing")
  end
end

-- Owns one fixed tick inside the yes/no confirm: unknown events raise
-- in prompt states exactly like ordinary states, cancel
-- declines immediately without publishing, and every other event batch
-- drives the owned prompt exactly once before the tick-owned resolution
-- consumes a published result. Prompt rows latch on press through the
-- owned prompt; the release never activates by itself.
---@param uiInput table[]
function PartyScreenController:_stepPrompt(uiInput)
  for _, event in ipairs(uiInput) do
    assert(type(event) == "table" and type(event.type) == "string", "party events need a type")
    if event.type == "cancel" then
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
  local origin = self._origin
  if origin ~= nil then
    self._origin = nil
    self:_restoreOrigin(origin)
  else
    if self._messageReturn == "give_result" then
      self:_finishGive()
    else
      self:_transition(self._messageReturn)
    end
  end
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
-- the active state's targets consult: slots in picking states, menu entries
-- in menu states, prompt rows in confirm, cancel in browse.
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
        self:_beginMenuPress()
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

-- Resolves the generated touch target under a pointer for the open menu.
---@param controller PartyScreenController
---@param layout table<string, unknown>
---@param x unknown
---@param y unknown
---@return table<string, unknown>?
local function hitMenu(controller, layout, x, y)
  local menu = assert(controller._menu, "menu presses need the open menu")
  local menuHit = assert(layout.menuHit, "the party layout carries generated menu hit targets")
  if type(x) ~= "number" or type(y) ~= "number" then
    return nil
  end
  local hit = menuHit(controller:_menuKind(), #menu, x, y)
  if hit == nil then
    return nil
  end
  return { kind = "menu", index = assert(hit.index, "menu hits resolve an entry") }
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
  if self._pressId ~= nil or self._menuPress ~= nil then
    return
  end
  assert(type(event.pointerId) == "string", "pointer down needs a pointer id")
  self._pressId = event.pointerId
  self._pressEpoch = self._epoch
  local layout = assert(self._layout(), "the party layout is required for pointer input")
  if self._state == "context" or self._state == "item_context" or self._state == "mail_context" then
    local hit = hitMenu(self, layout, event.x, event.y)
    self._pressCapture = hit
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
  if event.pointerId ~= self._pressId or self._menuPress ~= nil then
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
    up = hitMenu(self, layout, event.x, event.y)
  else
    up = hitSlots(layout, event.x, event.y)
  end
  if sameTarget(down, up) then
    self:_activate(up)
  end
end

-- One fixed tick over the tick's UI events. Clocks advance first: icon
-- sequence ticks and the panel slide step once per tick while open. A
-- valid outside dismiss for a normal context then closes terminally
-- before the armed menu press, an armed swap, the owned prompt, the
-- held-item continuation, or ordinary state handling can run for this
-- tick. At most one state consumes an event batch: the batch ends when a
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
  do
    local foundDismiss = false
    for _, event in ipairs(uiInput) do
      assert(type(event) == "table" and type(event.type) == "string", "party events need a type")
      if event.type == "dismiss" then
        foundDismiss = true
      elseif
        event.type ~= "navigate"
        and event.type ~= "confirm"
        and event.type ~= "cancel"
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
    if foundDismiss then
      self:_dismiss()
      return
    end
  end
  if self._menuPress ~= nil then
    local transitionsBefore = self._transitionCount
    self:_advanceMenuPress()
    if self._transitionCount ~= transitionsBefore then
      return
    end
  end
  if self._state == "swapping" then
    self:_advanceSwap()
    return
  end
  if self._state == "confirm" then
    self:_stepPrompt(uiInput)
    return
  end
  if self._state == "give_resume" then
    local item = assert(self._pendingItem, "give continuations retain their item")
    local slot = assert(self._cursorNode, "give continuations retain their original slot")
    assert(isSlotNode(slot), "give continuations target a party slot")
    self:_emitIntent({
      kind = "give",
      slot = slot,
      partyRevision = self._observedRevision,
      bagRevision = item.bagRevision,
      item = item.key,
    })
    return
  end
  if self._state == "give_question" then
    self:_openGiveConfirm()
    return
  end
  if view.revision ~= previousRevision and self._swapOp == nil then
    -- Reconcile a cursor the party change may have invalidated without
    -- inventing a mon: keep a still-selectable cursor, else the nearest one.
    -- An armed press never survives a party change: the captured entry is
    -- stale, so the gate disarms and the menu rebuilds (or closes when its
    -- slot no longer qualifies).
    if self._menuPress ~= nil then
      self._menuPress = nil
      local slot = self._menuSlot
      local record = slot ~= nil and view.slots[slot + 1] or nil
      if record ~= nil and record.occupied then
        if self._state == "context" then
          self._menu = self:_menuFor(record)
        elseif self._state == "item_context" or self._state == "mail_context" then
          self._menu = self:_submenuFor(self._state == "mail_context" and "mail" or "item", record)
        end
        if self._menu ~= nil then
          self:_menuLayoutFor()
          self._menuIndex = math.min(self._menuIndex or 1, #self._menu)
        end
      end
      if self._menu == nil then
        self._menu = nil
        self._menuIndex = nil
        self._menuSlot = nil
        self._originSlot = nil
        self:_transition("browse")
      end
    end
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
    local transitionsBefore = self._transitionCount
    if self._menuPress ~= nil then
      -- The armed press owns the tick: further navigation, activation,
      -- cancellation, and pointer presses wait for its single dispatch.
      -- Pointer cancellation still clears a held capture without
      -- duplicating or hurrying the armed entry.
      if event.type == "pointer_cancel" then
        self:cancelPointerCapture()
      elseif event.type == "menu" or event.type == "pointer_scroll" then
        -- A child application's own input policy applies.
      elseif
        event.type ~= "navigate"
        and event.type ~= "confirm"
        and event.type ~= "cancel"
        and event.type ~= "dismiss"
        and event.type ~= "pointer_down"
        and event.type ~= "pointer_move"
        and event.type ~= "pointer_up"
      then
        error("unknown party event type " .. tostring(event.type), 2)
      end
    elseif event.type == "navigate" then
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
    if self._transitionCount ~= transitionsBefore then
      break
    end
  end
end

-- Routes directional input: menu lists follow their generated source
-- neighbors, slot states walk the compiled graph.
---@param event table<string, unknown>
function PartyScreenController:_navigate(event)
  if self._state == "context" or self._state == "item_context" or self._state == "mail_context" then
    assert(self._menu ~= nil, "menu motion needs the open menu")
    self:_moveMenu(assert(event.direction, "navigation needs a direction"))
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

-- Interprets an outside pointer-down as a silent terminal close for a
-- normal context, independent of nested menu, target, swap, prompt,
-- message, waiting, or continuation state. Script selection never emits
-- this edge.
function PartyScreenController:_dismiss()
  if self._context == "pick" then
    error("party dismiss is a browse-flow edge; pick context never emits it", 2)
  end
  self._result = { kind = "closed" }
  self:_transition("closing")
end

-- The presentation snapshot: context, state, cursor, open menu, pending
-- swap visuals, animation clocks, and the current immutable view. The
-- view is the model's own fresh record; callers must not mutate it.
-- Animation numbers are read-only presentation facts: draw never
-- advances them.
---@class PartyScreenController.Status
---@field open boolean
---@field context "browse"|"pick"|"item_target"|"give_target"|"give_resume"?
---@field state string?
---@field mode "browse"|"pick"|"item_target"|"give_target"|"give_resume"?
---@field action string?
---@field cursorNode integer|"cancel"?
---@field menuIndex integer?
---@field menu PartyScreenController.MenuEntry[]?
---@field menuSlot integer?
---@field menuPress { index: integer, phase: "pressed"|"selected" }? the armed press gate presentation
---@field message string|{ templateKey: string, displayName: string? }?
---@field switchSelect { source: integer, candidate: integer|"cancel" }? the locked switch source and current candidate
---@field prompt table<string, unknown>?
---@field swap table<string, unknown>?
---@field anim table<string, unknown>? tick, per-slot icon sequences and sequence-local ticks, panel slide
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
    assert(op.source >= 0 and op.source < 6 and op.destination >= 0 and op.destination < 6, "swap slots stay in 0..5")
    local xOffset = op.xOffset
    assert(xOffset % 1 == 0 and xOffset >= 0 and xOffset <= SWAP_MAX_OFFSET, "swap offsets stay within full exit")
    local exchanged = op.exchanged
    local offsets = {}
    local directions = {}
    for _, slot0 in ipairs({ op.source, op.destination }) do
      local direction = (slot0 % 2 == 0) and -1 or 1
      local pixelOffset = direction * xOffset * SWAP_PIXEL_STEP
      directions[slot0] = direction
      offsets[slot0] = pixelOffset
    end
    swapStatus = {
      source = op.source,
      destination = op.destination,
      xOffset = xOffset,
      offsets = offsets,
      directions = directions,
      exchanged = exchanged,
    }
  end
  local sequences = {}
  local sequenceTicks = {}
  for slot0 = 0, 5 do
    local sequence = self._seq[slot0 + 1] or 1
    if swapStatus ~= nil and (slot0 == swapStatus.source or slot0 == swapStatus.destination) then
      sequence = 0
    end
    sequences[slot0 + 1] = sequence
    sequenceTicks[slot0 + 1] = self._tick - (self._seqBase[slot0 + 1] or self._tick)
  end
  local menuPress
  if self._menuPress ~= nil then
    menuPress = {
      index = self._menuPress.index,
      phase = self._menuPress.timer < 2 and "pressed" or "selected",
    }
  end
  local switchSelect
  if self._state == "choose_swap" and self._swapSource ~= nil then
    switchSelect = { source = self._swapSource, candidate = self._cursorNode }
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
    menuPress = menuPress,
    message = self._message,
    switchSelect = switchSelect,
    prompt = self._prompt and self._prompt:status() or nil,
    swap = swapStatus,
    anim = {
      tick = self._tick,
      sequences = sequences,
      sequenceTicks = sequenceTicks,
      panelSlide = self._panelSlide,
    },
    view = self._view,
    cancellable = self._cancellable,
  }
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
-- intent; a text outcome shows its text over the originating state, a
-- template-descriptor outcome shows the generated template over browse
-- refocused on the acting slot, and any other outcome returns silently.
-- Outcomes for another state are a programming error.
---@param outcome table<string, unknown>
function PartyScreenController:completeAction(outcome)
  assert(type(outcome) == "table", "action completion carries an outcome")
  assert(self._state == "waiting_action", "action completion resolves a pending intent")
  assert(self._intent == nil, "the flow takes the intent before completing it")
  local origin = assert(self._origin, "waiting remembers its origin")
  self:_refresh()
  self._origin = nil
  if self._giveDisposition ~= nil then
    self._cursorNode = self:_reconciledCursor(self._view, origin.cursorNode)
    if type(outcome.disposition) == "string" then
      assert(outcome.disposition == self._giveDisposition, "held-item completion preserves its caller")
    end
    if outcome.kind == "needs_confirmation" then
      assert(type(outcome.message) == "table", "replacement questions carry generated message data")
      self:_showMessage(outcome.message, "give_question")
      return
    end
    if type(outcome.message) == "table" then
      self:_showMessage(outcome.message, "give_result")
      return
    end
    self:_finishGive()
    return
  end
  if outcome.kind == "no_op" then
    self:_restoreOrigin(origin)
    return
  end
  if type(outcome.message) == "table" then
    self._cursorNode = origin.cursorNode
    self:_showMessage(outcome.message, "browse")
    return
  end
  if type(outcome.text) == "string" and outcome.text ~= "" then
    self._origin = origin
    self._cursorNode = origin.cursorNode
    self:_showMessage(outcome.text, origin.state)
    return
  end
  self:_restoreOrigin(origin)
end

-- Restores the pre-intent cursor and menu position after an outcome.
---@param origin PartyScreenController.Origin
function PartyScreenController:_restoreOrigin(origin)
  local view = self._view
  self._cursorNode = self:_reconciledCursor(view, origin.cursorNode)
  if view.revision ~= origin.partyRevision then
    self._menu = nil
    self._menuIndex = nil
    self._menuSlot = nil
    self._originSlot = nil
    self._donorSlot = nil
    self._donorMoveSlot = nil
    self:_transition("browse")
    return
  end
  if origin.state == "context" or origin.state == "item_context" or origin.state == "mail_context" then
    local slot = origin.menuSlot
    local record = slot ~= nil and view.slots[slot + 1] or nil
    if record ~= nil and record.occupied then
      local menu
      if origin.state == "context" then
        menu = self:_menuFor(record)
      else
        menu = self:_submenuFor(origin.state == "mail_context" and "mail" or "item", record)
      end
      if #menu > 0 then
        local kind = origin.state == "context" and "topLevel" or "subcontext"
        local layout = assert(self._layout(), "the party layout is required for menu geometry")
        local lookup = assert(layout.menuLayout, "the party layout carries generated menu records")
        lookup(kind, #menu)
        self._menu = menu
        self._menuSlot = slot
        self._originSlot = slot
        self._menuIndex = math.min(origin.menuIndex or 1, #menu)
        self:_transition(origin.state)
        return
      end
    end
  end
  self._menu = nil
  self._menuIndex = nil
  self._menuSlot = nil
  self._originSlot = nil
  self._donorSlot = nil
  self._donorMoveSlot = nil
  self:_transition("browse")
end

-- The one-shot result contract: nil until a terminal event, then exactly
-- one semantic record.
---@return { kind: "closed"|"selected"|"cancelled"|"give_complete", slot?: integer }?
function PartyScreenController:takeResult()
  local result = self._result
  self._result = nil
  if result ~= nil and result.kind ~= "give_complete" then
    self:_transition("closed")
  end
  return result
end

-- Idempotent release of the logical lifetime: a pending result is
-- discarded and no completion is reported after disposal.
function PartyScreenController:dispose()
  self._result = nil
  self:_transition("closed")
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
