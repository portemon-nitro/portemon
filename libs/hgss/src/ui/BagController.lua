-- Field-bag controller: pure browse navigation plus the inventory-local
-- action states. Browsing keeps the six-cell grid navigation over the
-- injected view model, pocket switching with per-pocket cursor memory, and
-- the constrained-topology description overlay. Confirming an item opens the
-- action menu built by the injected policy projection; the nested toss
-- quantity picker, the modal two-row confirmation prompt, its post-choice
-- acknowledgement, and manual move-target states mutate only through the
-- injected semantic commands, exactly once per acknowledgement, with a
-- stale-selection check after every refresh so an external revision can
-- never redirect a pending mutation onto a different item. Cancelling the
-- picker or rejecting the prompt returns straight to browsing without
-- mutation, and closing returns to the menu.
-- Occupied selection and scroll live in the borrowed field cursor through
-- its API only; browse focus is a private semantic node (a grid cell, a
-- pocket tab, or cancel) resolved through the shared focus graph, so empty
-- cells can own focus without inventing an item selection. Pointer
-- press/release capture shares the keyboard confirm path, so a drag or a
-- layout change can never activate a moved target. Modal confirmation input
-- belongs to the owned two-row prompt controller and its source geometry;
-- the Bag layout never names YES/NO targets. Results are one-shot
-- ({kind="closed"}) with no renderer state and no love dependency.

local BagSave = require("libs.hgss.src.save.BagSave")
local BagLayout = require("libs.hgss.src.ui.BagLayout")
local FocusGraph = require("libs.ui.src.FocusGraph")
local MenuTextTemplate = require("libs.hgss.src.ui.MenuTextTemplate")
local Utf8Glyphs = require("libs.assets.src.Utf8Glyphs")
local YesNoPromptController = require("libs.hgss.src.ui.YesNoPromptController")

-- Retail sound vocabulary for the post-selection bag path. The names stay
-- private; the semantic mapping is fixed and production resolves every
-- symbol through the composed audio service.
local EFFECT = {
  select = "SEQ_SE_DP_SELECT",
  cancel = "SEQ_SE_GS_GEARCANCEL",
  quantity = "SEQ_SE_DP_BAG_004",
  invalid = "SEQ_SE_DP_BOX03",
  promptDecision = "SEQ_SE_DP_BUTTON9",
  saleComplete = "SEQ_SE_DP_SELECT",
}

local validateBagEvent
local pressInsidePane

---@class BagControllerCommands semantic mutations bound to the live inventory service
---@field toss fun(itemKey: string, quantity: integer): boolean remove owned copies
---@field move fun(pocketKey: string, fromIndex: integer, toIndex: integer): boolean reorder by absolute pocket index
---@field register fun(itemKey: string): unknown claim a registration slot
---@field unregister fun(itemKey: string): boolean release a registration slot

---@class BagController
---@field _model { refresh: fun(): table<string, unknown> }
---@field _cursor BagCursor
---@field _resolveLayout fun(): table<string, unknown>
---@field _commands BagControllerCommands
---@field _resolveActions fun(view: table<string, unknown>): table<string, unknown>[]
---@field _view table<string, unknown>
---@field _observedRevision integer
---@field _focusNode string the private semantic browse focus node
---@field _lastSlot integer the most recent grid-cell focus, for tab/cancel return
---@field _overlay boolean
---@field _state "browsing"|"item_select"|"action_menu"|"toss_quantity"|"toss_confirm"|"toss_ack"|"move_select"|"sale_quantity"|"sale_offer"|"sale_result"|"sale_refusal"|"sale_ack"
---@field _context "inventory"|"field"|"pick_held"|"sell" the selection context for intent emission
---@field _saleSession table<string, unknown>?
---@field _salePrompt { x: integer, y: integer, shape: string, initialSelection: string }?
---@field _saleQuote table<string, unknown>?
---@field _saleToken unknown?
---@field _saleItem table<string, unknown>?
---@field _saleBalance integer
---@field _saleDisplayedTotal integer
---@field _isPickable (fun(itemKey: string): boolean)? the held-item eligibility probe for picker contexts
---@field _intent table<string, unknown>? the one-shot selection intent for the owning flow
---@field _prompt YesNoPromptController the owned modal prompt for toss confirmation
---@field _tossPrompt { x: integer, y: integer, shape: string, initialSelection: string } the generated semantic prompt placement
---@field _actions table<string, unknown>[]
---@field _actionNode integer
---@field _actionItemKey string?
---@field _actionPocket string?
---@field _itemSelectTicks integer the generated selection-entry total driving the transition clock
---@field _itemSelectElapsed integer ticks elapsed in the selection entry
---@field _quantity integer
---@field _quantityMax integer
---@field _effect (fun(sequence: string))? the optional injected semantic sound boundary
---@field _textPolicy { interGlyphDelay: integer, glyphBudget: integer, abAcceleration: boolean } the copied text-speed cadence
---@field _templates table<string, unknown> the generated lower-message templates
---@field _feedbackTicks integer the generated activation-feedback total
---@field _moveClipTotals { unchanged: integer, changed: integer } the generated move commit-clip totals
---@field _feedback { kind: string, elapsed: integer, total: integer, continuation: table<string, unknown> }? the latched activation record
---@field _message { full: string, glyphs: string[], revealed: integer, delay: integer }? the owned lower-message printer
---@field _tossBase "action"|"quantity"? the retained base while toss confirmation owns the screen
---@field _tossStage "confirm"|"prompt"|"result"? the confirmation sub-stage gating prompt and acknowledgement
---@field _moveClip { changed: boolean, elapsed: integer, total: integer }? the running move commit clip
---@field _moveFromKey string?
---@field _moveFromPos integer
---@field _moveTarget integer
---@field _result { kind: string }?
---@field _closed boolean
---@field _pressId string?
---@field _pressCapture table<string, unknown>?
---@field _quantityPressedControl integer?
---@field _quantityPressedTicks integer
local BagController = {}
BagController.__index = BagController

---@class BagController.Options
---@field model { refresh: fun(): table<string, unknown> } the injected view projection
---@field cursor BagCursor the borrowed runtime-only field cursor
---@field resolveLayout fun(): table<string, unknown> the injected layout resolver
---@field promptShape { width: integer, height: integer, yes: table<string, unknown>, no: table<string, unknown> } the validated compact prompt shape
---@field tossPrompt { x: integer, y: integer, shape: string, initialSelection: string } the generated semantic prompt placement
---@field commands BagControllerCommands semantic mutations bound to the live inventory service
---@field resolveActions fun(view: table<string, unknown>): table<string, unknown>[] the injected inventory-local menu projection over the refreshed view
---@field itemSelectTicks integer the generated selection-entry total; the controller owns the clock but never the frame visuals
---@field effect (fun(sequence: string))? the optional semantic sound boundary, silent when omitted
---@field textPolicy { interGlyphDelay: integer, glyphBudget: integer, abAcceleration: boolean } the copied text-speed cadence
---@field messages table<string, unknown>? the generated lower-message templates; direct unit construction falls back to the equivalent semantic defaults
---@field feedbackTicks integer? the generated activation-feedback total; direct unit construction falls back to a small positive total
---@field moveTransition table<string, unknown>? the generated move commit-clip totals; direct unit construction falls back to small positive totals
---@field context "inventory"|"field"|"pick_held"|"sell"? the selection context (defaults to inventory)
---@field saleSession table<string, unknown>? required for sell context
---@field salePrompt { x: integer, y: integer, shape: string, initialSelection: string }? required for sell context
---@field isPickable (fun(itemKey: string): boolean)? the held-item eligibility probe, required for pick_held

---@param value unknown
---@param what string
---@return integer
local function checkQuantity(value, what)
  assert(type(value) == "number" and value % 1 == 0 and value >= 1, what .. " must be a positive integer")
  return value
end

---@param value unknown
---@param what string
---@return integer
local function checkPositiveTicks(value, what)
  assert(type(value) == "number" and value % 1 == 0 and value >= 1, what .. " must be a positive integer")
  return value
end

-- Semantic lower-message defaults for direct unit construction: the same
-- text/item/quantity vocabulary production injects from the generated
-- manifest, so printer gating and reveal behavior stay identical.
local function defaultTemplates()
  return {
    selectedItem = {
      segments = {
        { kind = "text", value = "The " },
        { kind = "item" },
        { kind = "text", value = " is selected." },
      },
    },
    movePrompt = {
      segments = {
        { kind = "text", value = "Move " },
        { kind = "item" },
        { kind = "text", value = "?" },
      },
    },
    tossConfirm = {
      segments = {
        { kind = "text", value = "Toss " },
        { kind = "quantity" },
        { kind = "text", value = " " },
        { kind = "item" },
        { kind = "text", value = "?" },
      },
    },
    tossResult = {
      segments = {
        { kind = "text", value = "Threw away " },
        { kind = "quantity" },
        { kind = "text", value = " " },
        { kind = "item" },
        { kind = "text", value = "." },
      },
    },
  }
end

-- Browse focus node identities. Grid cells name their absolute zero-based
-- cell index, tabs name their pocket key, and cancel is a singleton; the
-- strings double as focus-graph node ids.
local CANCEL_NODE = "cancel"

local ACTION_NEIGHBORS = {
  [0] = { up = 2, down = 2, left = 1, right = 1 },
  [1] = { up = 3, down = 3, left = 0, right = 0 },
  [2] = { up = 0, down = 0, left = 4, right = 3 },
  [3] = { up = 1, down = 1, left = 2, right = 4 },
  [4] = { up = 4, down = 4, left = 3, right = 2 },
}

---@param actions table<string, unknown>[]
local function validateActions(actions)
  local seen = {}
  for _, action in ipairs(actions) do
    assert(type(action) == "table", "dynamic actions are records")
    assert(type(action.id) == "string" and action.id ~= "cancel", "dynamic actions carry supported ids")
    assert(
      type(action.slot) == "number" and action.slot % 1 == 0 and action.slot >= 0 and action.slot <= 3,
      "dynamic actions carry a valid physical slot"
    )
    assert(not seen[action.slot], "dynamic action slots are unique")
    seen[action.slot] = true
  end
end

---@param absolute integer
---@return string
local function slotNode(absolute)
  return "slot:" .. tostring(absolute)
end

---@param pocketKey string
---@return string
local function tabNode(pocketKey)
  return "tab:" .. pocketKey
end

---@param node unknown
---@return integer?
local function parseSlot(node)
  if type(node) ~= "string" then
    return nil
  end
  local absolute = node:match("^slot:(%d+)$")
  if absolute == nil then
    return nil
  end
  return math.floor(assert(tonumber(absolute), "slot nodes carry a numeric cell"))
end

---@param node unknown
---@return string?
local function parseTab(node)
  if type(node) ~= "string" then
    return nil
  end
  local pocketKey = node:match("^tab:(.+)$")
  if pocketKey == nil then
    return nil
  end
  for _, known in ipairs(BagSave.POCKET_ORDER) do
    if known == pocketKey then
      return pocketKey
    end
  end
  return nil
end

---@param opts BagController.Options
---@return BagController
function BagController.new(opts)
  assert(type(opts) == "table", "the bag controller requires options")
  assert(
    type(opts.model) == "table" and type(opts.model.refresh) == "function",
    "the bag controller needs a view model"
  )
  assert(type(opts.cursor) == "table", "the bag controller needs the runtime bag cursor")
  assert(type(opts.resolveLayout) == "function", "the bag controller needs its layout resolver")
  assert(type(opts.commands) == "table", "the bag controller needs its mutation commands")
  assert(type(opts.commands.toss) == "function", "the bag controller needs its toss command")
  assert(type(opts.commands.move) == "function", "the bag controller needs its move command")
  assert(type(opts.commands.register) == "function", "the bag controller needs its register command")
  assert(type(opts.commands.unregister) == "function", "the bag controller needs its unregister command")
  assert(type(opts.resolveActions) == "function", "the bag controller needs its action policy")
  local context = opts.context or "inventory"
  assert(
    context == "inventory" or context == "field" or context == "pick_held" or context == "sell",
    "the bag controller needs a named inventory, field, or pick_held context"
  )
  local isPickable = opts.isPickable
  if context == "pick_held" then
    assert(type(isPickable) == "function", "the held-item picker needs its eligibility probe")
  end
  if context == "sell" then
    assert(type(opts.saleSession) == "table", "the selling bag needs its sale session")
    assert(type(opts.saleSession.view) == "function", "the selling bag needs sale balance reads")
    assert(type(opts.saleSession.quoteSell) == "function", "the selling bag needs sale quotes")
    assert(type(opts.saleSession.commit) == "function", "the selling bag needs sale commits")
    assert(type(opts.salePrompt) == "table", "the selling bag needs its compact prompt placement")
  end
  assert(type(opts.promptShape) == "table", "the bag controller needs its modal prompt shape")
  assert(type(opts.tossPrompt) == "table", "the bag controller needs its toss prompt template")
  assert(
    type(opts.itemSelectTicks) == "number" and opts.itemSelectTicks % 1 == 0 and opts.itemSelectTicks >= 1,
    "the bag controller needs its positive selection-entry total"
  )
  assert(opts.effect == nil or type(opts.effect) == "function", "the bag effect boundary must be a function")
  local textPolicy = assert(opts.textPolicy, "the bag controller needs its copied text-speed policy")
  assert(type(textPolicy) == "table", "the bag controller needs its copied text-speed policy")
  assert(
    type(textPolicy.interGlyphDelay) == "number"
      and textPolicy.interGlyphDelay % 1 == 0
      and textPolicy.interGlyphDelay >= 0,
    "the text policy carries a non-negative glyph delay"
  )
  assert(
    type(textPolicy.glyphBudget) == "number" and textPolicy.glyphBudget % 1 == 0 and textPolicy.glyphBudget >= 1,
    "the text policy carries a positive glyph budget"
  )
  assert(type(textPolicy.abAcceleration) == "boolean", "the text policy carries its acceleration flag")
  local templates = opts.messages
  if templates == nil then
    templates = defaultTemplates()
  end
  assert(type(templates) == "table", "the bag controller needs its lower-message templates")
  for _, key in ipairs({ "selectedItem", "movePrompt", "tossConfirm", "tossResult" }) do
    assert(type(templates[key]) == "table", "the bag controller needs its " .. key .. " template")
  end
  if context == "sell" then
    assert(type(templates.sale) == "table", "the selling bag needs its sale message templates")
    for _, key in ipairs({ "notSellable", "quantity", "offer", "result" }) do
      assert(type(templates.sale[key]) == "table", "the selling bag needs its " .. key .. " template")
    end
  end
  local feedbackTicks = opts.feedbackTicks or 4
  checkPositiveTicks(feedbackTicks, "the activation-feedback total")
  local moveTransition = opts.moveTransition or { unchanged = { totalTicks = 3 }, changed = { totalTicks = 5 } }
  assert(type(moveTransition) == "table", "the bag controller needs its move commit-clip totals")
  local unchangedTicks = checkPositiveTicks(
    type(moveTransition.unchanged) == "table" and moveTransition.unchanged.totalTicks,
    "the unchanged move clip total"
  )
  local changedTicks = checkPositiveTicks(
    type(moveTransition.changed) == "table" and moveTransition.changed.totalTicks,
    "the changed move clip total"
  )
  -- The modal prompt is bound once and owned for the controller lifetime:
  -- opening the supplied template here proves a malformed placement fails
  -- construction instead of falling back to action slots, and disposing
  -- leaves no active prompt behind.
  local prompt = YesNoPromptController.new(opts.promptShape, opts.effect)
  prompt:open(opts.tossPrompt)
  prompt:dispose()
  local self = setmetatable({
    _model = opts.model,
    _cursor = opts.cursor,
    _resolveLayout = opts.resolveLayout,
    _commands = opts.commands,
    _resolveActions = opts.resolveActions,
    _context = context,
    _saleSession = opts.saleSession,
    _salePrompt = opts.salePrompt,
    _saleQuote = nil,
    _saleToken = nil,
    _saleItem = nil,
    _saleBalance = 0,
    _saleDisplayedTotal = 0,
    _saleCommitted = false,
    _saleSoundAttempted = false,
    _salePostCommitBusy = false,
    _isPickable = isPickable,
    _intent = nil,
    _focusNode = slotNode(0),
    _lastSlot = 0,
    _overlay = false,
    _state = "browsing",
    _actions = {},
    _actionNode = 4,
    _actionItemKey = nil,
    _actionPocket = nil,
    _itemSelectTicks = opts.itemSelectTicks,
    _itemSelectElapsed = 0,
    _quantity = 1,
    _quantityMax = 1,
    _effect = opts.effect,
    _textPolicy = {
      interGlyphDelay = textPolicy.interGlyphDelay,
      glyphBudget = textPolicy.glyphBudget,
      abAcceleration = textPolicy.abAcceleration,
    },
    _templates = templates,
    _feedbackTicks = feedbackTicks,
    _moveClipTotals = { unchanged = unchangedTicks, changed = changedTicks },
    _feedback = nil,
    _message = nil,
    _tossBase = nil,
    _tossStage = nil,
    _moveClip = nil,
    _moveFromKey = nil,
    _moveFromPos = 0,
    _moveTarget = 0,
    _result = nil,
    _closed = false,
    _pressId = nil,
    _pressCapture = nil,
    _quantityPressedControl = nil,
    _quantityPressedTicks = 0,
    _prompt = prompt,
    _tossPrompt = opts.tossPrompt,
  }, BagController)
  self._view = self:_refresh()
  self:_reconcile()
  -- Browse focus starts on the top-left cell of the current visible window
  -- while the borrowed per-pocket scroll is left alone; an occupied start
  -- cell also becomes the borrowed selection.
  local pocket = self:_pocket()
  local start = self._cursor:scroll(pocket)
  self._focusNode = slotNode(start)
  self._lastSlot = start
  if start < self:_count() then
    self._cursor:setPosition(pocket, start)
    self:_refresh()
  end
  return self
end

---@return table<string, unknown>
function BagController:_refresh()
  local view = self._model.refresh()
  assert(type(view) == "table" and type(view.slots) == "table", "the bag view needs its pocket slots")
  assert(type(view.pocket) == "string", "the bag view needs its pocket key")
  self._view = view
  self._observedRevision = view.revision
  return view
end

---@return integer
function BagController:_count()
  return #assert(self._view.slots, "the bag view needs its pocket slots")
end

---@return string
function BagController:_pocket()
  return assert(self._view.pocket, "the bag view needs its pocket key")
end

-- The state the renderer and the pointer hit test observe: the description
-- overlay wins over every nested state, and the two overlays stay mutually
-- exclusive.
---@return string
function BagController:_visibleState()
  if self._overlay then
    return "description_overlay"
  end
  return self._state
end

-- Clamps the borrowed cursor to the current pocket so it never points past
-- the last occupied cell and the window always covers the selection.
function BagController:_reconcile()
  local pocket = self:_pocket()
  local count = self:_count()
  local cursor = self._cursor
  if count == 0 then
    cursor:setPosition(pocket, 0)
    cursor:setScroll(pocket, 0)
    return
  end
  if cursor:position(pocket) > count - 1 then
    cursor:setPosition(pocket, count - 1)
  end
  local start = cursor:scroll(pocket)
  if start > count - 1 then
    start = count - 1
  end
  cursor:setScroll(pocket, start - (start % 2))
  self:_ensureVisible()
end

-- Slides the window to cover the selected absolute index, one row at a
-- time, so every occupied slot stays reachable in exact item order.
function BagController:_ensureVisible()
  local pocket = self:_pocket()
  local cursor = self._cursor
  local selected = cursor:position(pocket)
  local start = cursor:scroll(pocket)
  while selected < start do
    start = start - 2
  end
  while selected >= start + 6 do
    start = start + 2
  end
  if start ~= cursor:scroll(pocket) then
    cursor:setScroll(pocket, start)
  end
end

-- Enters a pocket through the cursor API: the stored per-pocket offsets
-- return, clamped to whatever the pocket holds now. Focus stays with the
-- caller, so keyboard tab travel keeps tab focus while pointer activation
-- moves to the grid explicitly at its own call site. The remembered grid
-- cell follows the clamped per-pocket cursor position either way, so a
-- later vertical return from the tabs or Cancel lands on the remembered
-- selection instead of the window top-left diverging from it.
---@param pocketKey string
function BagController:_enterPocket(pocketKey)
  self._cursor:setPocket(pocketKey)
  self:_refresh()
  self:_reconcile()
  self._lastSlot = self._cursor:position(pocketKey)
  self:_normalizeFocus()
  -- Focus is caller-owned; do not mutate self._focusNode here.
end

-- The logical browse grid covers the six currently visible cells and
-- otherwise pads occupied items to a complete two-column row, so a
-- visible trailing cell can own focus without inventing inventory.
---@return integer
function BagController:_logicalSlotCount()
  local padded = math.max(6, math.ceil(self:_count() / 2) * 2)
  local start = assert(self._view.visibleStart, "the bag view needs its visible window start")
  return math.max(padded, start + 6)
end

-- Builds the ephemeral browse graph over the current pocket, item count,
-- tab order, and remembered cell. Grid adjacency is absolute: same-row
-- siblings sideways (missing neighbors stay put, never wrap), two cells
-- vertically, the top row up to the active-pocket tab, and the last
-- logical row down to Cancel. Tabs wrap through the pocket order and
-- travel vertically back to the remembered cell, as does Cancel upward.
---@return table<string, table<string, string[]>>
function BagController:_browseGraph()
  local pocket = self:_pocket()
  local slotCount = self:_logicalSlotCount()
  local remembered = slotNode(self._lastSlot)
  local graph = {}
  for absolute = 0, slotCount - 1 do
    local id = slotNode(absolute)
    local left = absolute % 2 == 1 and { slotNode(absolute - 1) } or {}
    local right = absolute % 2 == 0 and absolute + 1 < slotCount and { slotNode(absolute + 1) } or {}
    local up = absolute - 2 >= 0 and { slotNode(absolute - 2) } or { tabNode(pocket) }
    local down = absolute + 2 < slotCount and { slotNode(absolute + 2) } or { CANCEL_NODE }
    graph[id] = { up = up, down = down, left = left, right = right }
  end
  local order = BagSave.POCKET_ORDER
  for position, pocketKey in ipairs(order) do
    local previous = order[((position - 2) % #order) + 1]
    local following = order[(position % #order) + 1]
    graph[tabNode(pocketKey)] = {
      left = { tabNode(previous) },
      right = { tabNode(following) },
      up = { remembered },
      down = { remembered },
    }
  end
  graph[CANCEL_NODE] = { up = { remembered }, down = {}, left = {}, right = {} }
  return graph
end

-- Repairs focus after an external revision shrank the logical grid: an
-- out-of-range cell falls back to the nearest valid one, and anything that
-- is no longer a browse node at all returns to the remembered cell. A
-- valid-but-empty cell is kept, so removal never steals a visible focus.
function BagController:_normalizeFocus()
  local slotCount = self:_logicalSlotCount()
  if self._lastSlot < 0 or self._lastSlot >= slotCount then
    self._lastSlot = math.max(slotCount - 1, 0)
  end
  local absolute = parseSlot(self._focusNode)
  if absolute ~= nil then
    if absolute < 0 or absolute >= slotCount then
      self._focusNode = slotNode(self._lastSlot)
    end
    return
  end
  if parseTab(self._focusNode) == nil and self._focusNode ~= CANCEL_NODE then
    self._focusNode = slotNode(self._lastSlot)
  end
end

-- While plain browsing, an outside revision may have filled the focused
-- cell without travelling through focus input. Carry the borrowed cursor
-- to the newly occupied focus so selection names the same item before any
-- consumer observes the refreshed view. Empty focus keeps no selection and
-- nested states keep their snapshotted item; neither is retargeted here.
function BagController:_reconcileBrowseSelection()
  if self._state ~= "browsing" or self._overlay then
    return
  end
  local absolute = parseSlot(self._focusNode)
  if absolute == nil or absolute >= self:_count() then
    return
  end
  local pocket = self:_pocket()
  if self._cursor:position(pocket) == absolute then
    return
  end
  self._cursor:setPosition(pocket, absolute)
  self:_ensureVisible()
  self:_refresh()
end

-- Focuses one absolute grid cell: the window slides in row steps until the
-- cell is visible, an occupied cell also becomes the borrowed selection,
-- and an empty cell leaves the borrowed cursor alone. Requests past the
-- logical grid clamp to its last cell, so a tap beyond the padded row can
-- never produce a node the graph does not know.
---@param absolute integer
function BagController:_focusSlot(absolute)
  local pocket = self:_pocket()
  local slotCount = self:_logicalSlotCount()
  local clamped = math.min(math.max(absolute, 0), slotCount - 1)
  self._focusNode = slotNode(clamped)
  self._lastSlot = clamped
  local cursor = self._cursor
  local start = cursor:scroll(pocket)
  while clamped < start do
    start = start - 2
  end
  while clamped >= start + 6 do
    start = start + 2
  end
  if start ~= cursor:scroll(pocket) then
    cursor:setScroll(pocket, start)
  end
  if clamped < self:_count() then
    cursor:setPosition(pocket, clamped)
  end
  self:_refresh()
end

-- Applies one resolved browse node and its side effects: grid cells focus
-- through the shared slot path, while tabs and Cancel only move focus.
---@param node string
function BagController:_applyFocusNode(node)
  local absolute = parseSlot(node)
  if absolute ~= nil then
    self:_focusSlot(absolute)
    return
  end
  assert(parseTab(node) ~= nil or node == CANCEL_NODE, "focus nodes stay inside the browse graph")
  self._focusNode = node
end

---@param direction string
function BagController:_move(direction)
  assert(
    direction == "up" or direction == "down" or direction == "left" or direction == "right",
    "unknown UI direction"
  )
  self:_normalizeFocus()
  local target = FocusGraph.move(self:_browseGraph(), self._focusNode, direction)
  assert(type(target) == "string", "bag browse nodes are string ids")
  self:_applyFocusNode(target)
end

-- The focused absolute cell while plain browsing, or nil on tabs/Cancel.
-- This is focus identity, not item identity: it may name an empty cell.
---@return integer?
function BagController:_focusedSlotAbsolute()
  if self:_visibleState() ~= "browsing" then
    return nil
  end
  return parseSlot(self._focusNode)
end

-- The focused cell when it actually holds an item: the only browse focus
-- that may open the description or the action menu.
---@return integer?
function BagController:_focusedOccupiedAbsolute()
  local absolute = self:_focusedSlotAbsolute()
  if absolute == nil or absolute >= self:_count() then
    return nil
  end
  return absolute
end

-- Drops every nested action frame and returns to plain browsing. Mutations
-- never ride this path: callers refresh first and commit explicitly. The
-- owned prompt resets with the menu, so no capture or result survives the
-- return.
function BagController:_toBrowsing()
  self:cancelPointerCapture()
  self._prompt:dispose()
  self._state = "browsing"
  self._actions = {}
  self._actionNode = 4
  self._actionItemKey = nil
  self._actionPocket = nil
  self._itemSelectElapsed = 0
  self._quantity = 1
  self._quantityMax = 1
  self._quantityPressedControl = nil
  self._quantityPressedTicks = 0
  self._feedback = nil
  self._message = nil
  self._tossBase = nil
  self._tossStage = nil
  self._saleQuote = nil
  self._saleToken = nil
  self._saleItem = nil
  self._saleBalance = 0
  self._saleDisplayedTotal = 0
  self._saleCommitted = false
  self._saleSoundAttempted = false
  self._salePostCommitBusy = false
  self._saleFailed = false
  self._moveClip = nil
  self._moveFromKey = nil
  self._moveFromPos = 0
  self._moveTarget = 0
end

-- Emits one semantic sound through the injected boundary; pure unit
-- construction without a boundary stays silent.
---@param sequence string
function BagController:_play(sequence)
  if self._effect ~= nil then
    self._effect(sequence)
  end
end

-- Outside dismissal still sounds like its cancel equivalent while a
-- cancellable nested menu owns the tick; the close itself stays terminal
-- and never unwinds one level or mutates.
function BagController:_playDismissSound()
  if self._state == "action_menu" or self._state == "toss_quantity" or self._state == "move_select" then
    self:_play(EFFECT.cancel)
  end
end

-- Resolves the display name for a lower message: the singular form for
-- one copy, the plural form otherwise, falling back to the singular name
-- when a test fake carries no plural.
---@param quantity integer
---@return string
function BagController:_displayName(quantity)
  local selected =
    assert(self._context == "sell" and self._saleItem or self._view.selected, "lower messages need their selected item")
  local name = assert(selected.name, "lower messages need the selected display name")
  assert(type(name) == "string" and name ~= "", "lower messages need the selected display name")
  if quantity == 1 then
    return name
  end
  local plural = selected.namePlural
  if type(plural) == "string" and plural ~= "" then
    return plural
  end
  return name
end

---@param template table<string, unknown>
---@param itemName string
---@param quantity integer?
---@return string
function BagController:_formatMessage(template, itemName, quantity)
  local bindings = { item = itemName }
  if quantity ~= nil then
    bindings.quantity = quantity
  end
  if self._saleQuote ~= nil then
    bindings.total = assert(self._saleQuote.total, "a sale quote carries its total")
  end
  return MenuTextTemplate.format(template, bindings, "bag message")
end

-- Starts the owned lower-message printer over the full formatted text.
-- Instant messages reveal everything at once; typed messages reveal
-- nothing until fixed ticks advance them.
---@param fullText string
---@param instant boolean
function BagController:_startMessage(fullText, instant)
  assert(type(fullText) == "string" and fullText ~= "", "lower messages carry visible text")
  local glyphs = {}
  local nextGlyph = Utf8Glyphs.iter(fullText)
  while true do
    local glyph = nextGlyph()
    if glyph == nil then
      break
    end
    glyphs[#glyphs + 1] = glyph
  end
  assert(#glyphs >= 1, "lower messages carry at least one glyph")
  self._message = {
    full = fullText,
    glyphs = glyphs,
    revealed = instant and #glyphs or 0,
    delay = 0,
  }
end

---@return boolean true once every glyph is visible
function BagController:_messageComplete()
  local message = self._message
  if message == nil then
    return true
  end
  return message.revealed >= #message.glyphs
end

-- Advances the owned printer one fixed tick. Acceleration input reveals
-- the remainder at once when the copied policy allows it; otherwise the
-- tick reveals up to one glyph budget after the inter-glyph delay.
---@param accelerate boolean
function BagController:_stepMessage(accelerate)
  local message = assert(self._message, "the printer steps only while a message is active")
  if message.revealed >= #message.glyphs then
    return
  end
  if accelerate and self._textPolicy.abAcceleration then
    message.revealed = #message.glyphs
    return
  end
  if message.delay > 0 then
    message.delay = message.delay - 1
    return
  end
  message.revealed = math.min(#message.glyphs, message.revealed + self._textPolicy.glyphBudget)
  message.delay = self._textPolicy.interGlyphDelay
end

---@return string the currently visible prefix, glyph-safe
function BagController:_visibleMessageText()
  local message = assert(self._message, "visible text reads only while a message is active")
  local parts = {}
  for index = 1, message.revealed do
    parts[#parts + 1] = message.glyphs[index]
  end
  return table.concat(parts)
end

-- Latches one activation behind the generated palette-flash cadence: the
-- sound plays now, the captured semantic continuation runs only after the
-- feedback total elapses. Conflicting activation while latched is ignored.
---@param kind string the latched control identity for the renderer phase
---@param continuation table<string, unknown> the pending semantic transition
function BagController:_startFeedback(kind, continuation)
  assert(type(kind) == "string" and kind ~= "", "feedback latches a named control")
  assert(type(continuation) == "table", "feedback latches its semantic continuation")
  if self._feedback ~= nil then
    return
  end
  self._feedback = { kind = kind, elapsed = 0, total = self._feedbackTicks, continuation = continuation }
end

-- Advances latched activation one fixed tick and runs the captured
-- continuation exactly once when the generated total elapses.
function BagController:_stepFeedback()
  local feedback = assert(self._feedback, "feedback steps only while latched")
  feedback.elapsed = feedback.elapsed + 1
  if feedback.elapsed < feedback.total then
    return
  end
  local continuation = feedback.continuation
  self._feedback = nil
  self:_runContinuation(continuation)
end

-- Runs one captured post-feedback continuation after revalidating the
-- pending selection. A stale selection reconciles safely instead of
-- redirecting the transition onto another item.
---@param continuation table<string, unknown>
function BagController:_runContinuation(continuation)
  local kind = assert(continuation.kind, "continuations carry their kind")
  if kind == "toBrowsing" then
    self:_toBrowsing()
    return
  end
  self:_refresh()
  if not self:_selectionMatchesAction() then
    self:_toBrowsing()
    return
  end
  if kind == "enterQuantity" then
    self:_enterQuantity()
  elseif kind == "enterMove" then
    self:_enterMoveSelect()
  elseif kind == "enterToss" then
    self:_enterTossConfirm()
  elseif kind == "enterSaleOffer" then
    self:_prepareSaleOffer()
  elseif kind == "register" then
    self:_commitRegistration(continuation.register == true)
  elseif kind == "intent" then
    local itemKey = assert(self._actionItemKey, "field actions snapshot their item")
    self:_toBrowsing()
    self:_emitIntent(assert(continuation.intent, "intent continuations carry their kind"), itemKey)
  else
    error("unknown bag continuation " .. tostring(kind), 2)
  end
end

-- The pending selection still names the same semantic item in the same
-- pocket after the latest refresh. An external revision that moved or
-- removed it aborts the pending mutation instead of redirecting it.
---@return boolean
function BagController:_selectionMatchesAction()
  local view = self._view
  if view.pocket ~= self._actionPocket then
    return false
  end
  local selected = view.selected
  if type(selected) ~= "table" then
    return false
  end
  return selected.item == self._actionItemKey
end

---@return table<string, unknown>[]
function BagController:_currentActions()
  local actions = self._resolveActions(self._view)
  assert(type(actions) == "table", "the action policy returns dynamic actions")
  validateActions(actions)
  return actions
end

-- Confirming an item resolves the inventory-local menu for the refreshed
-- view and snapshots the semantic selection the nested states verify
-- against. Only an occupied focused cell may enter; an empty focus is a
-- no-op, never an error. Entry parks in the source selection transition
-- with its clock at zero; the stable action menu opens only once the
-- generated total elapses.
function BagController:_openActionMenu()
  local absolute = self:_focusedOccupiedAbsolute()
  if absolute == nil then
    return
  end
  local selected = self._view.slots[absolute + 1]
  if type(selected) ~= "table" or type(selected.item) ~= "string" then
    return
  end
  local actions = self:_currentActions()
  self._actions = actions
  self._actionNode = 4
  for _, action in ipairs(actions) do
    if action.slot < self._actionNode then
      self._actionNode = action.slot
    end
  end
  self._actionItemKey = selected.item
  self._actionPocket = self:_pocket()
  self._overlay = false
  self._itemSelectElapsed = 0
  self._state = "item_select"
  self:_play(EFFECT.select)
end

-- Emits one value-only selection intent for the owning flow: the item
-- identity and service revision snapshot at emission, pointer capture
-- clears on the ownership change, and the caller stops the batch so the
-- replacement child never sees the launching input.
---@param kind string
---@param itemKey string
function BagController:_emitIntent(kind, itemKey)
  assert(self._intent == nil, "a bag intent is already pending")
  assert(type(itemKey) == "string" and itemKey ~= "", "a bag intent snapshots its item key")
  self._intent = { kind = kind, item = itemKey, bagRevision = self._observedRevision }
  self:cancelPointerCapture()
end

-- The one-shot intent contract: nil until a selection emits, then exactly
-- one value-only record for the flow to route.
---@return table<string, unknown>?
function BagController:takeIntent()
  local intent = self._intent
  self._intent = nil
  return intent
end

---@param node integer physical action node
function BagController:_chooseActionNode(node)
  assert(node >= 0 and node <= 4 and node % 1 == 0, "action focus is a physical node")
  if self._feedback ~= nil then
    return
  end
  -- An external revision may have moved the selection under the open menu:
  -- re-resolve onto the current selection instead of dispatching the
  -- snapshotted action at a ghost. An empty pocket simply closes the menu.
  self:_refresh()
  if not self:_selectionMatchesAction() then
    self:_toBrowsing()
    self:_openActionMenu()
    return
  end
  self._actions = self:_currentActions()
  if node == 4 then
    self:_play(EFFECT.cancel)
    self:_startFeedback("cancel", { kind = "toBrowsing" })
    return
  end
  local action
  for _, candidate in ipairs(self._actions) do
    if candidate.slot == node then
      action = candidate
    end
  end
  if type(action) ~= "table" or type(action.id) ~= "string" then
    return
  end
  local id = action.id
  -- Move entry stays immediate: only the reorder commit waits for its
  -- clip. Every other activation latches behind the generated
  -- palette-flash cadence before its semantic transition runs.
  if id == "move" then
    self:_play(EFFECT.select)
    self:_enterMoveSelect()
    return
  end
  self:_play(EFFECT.select)
  if id == "use" or id == "give" then
    self:_startFeedback("action:" .. node, { kind = "intent", intent = id })
    return
  end
  if id == "toss" then
    self:_startFeedback("action:" .. node, { kind = "enterQuantity" })
  elseif id == "register" then
    self:_startFeedback("action:" .. node, { kind = "register", register = true })
  elseif id == "unregister" then
    self:_startFeedback("action:" .. node, { kind = "register", register = false })
  end
end

---@param direction string
function BagController:_moveAction(direction)
  assert(ACTION_NEIGHBORS[self._actionNode][direction], "unknown action direction")
  local next = ACTION_NEIGHBORS[self._actionNode][direction]
  if next ~= self._actionNode then
    self._actionNode = next
    self:_play(EFFECT.select)
  end
end

-- Enters the quantity picker for the snapshotted item, preselecting one
-- copy. The range always ends at the freshly observed owned quantity. A
-- lone owned copy skips the picker and confirms through the modal prompt
-- directly.
function BagController:_enterQuantity()
  self:_refresh()
  if not self:_selectionMatchesAction() then
    self:_toBrowsing()
    return
  end
  local selected = assert(self._view.selected, "a matched selection carries its record")
  local owned = checkQuantity(selected.quantity, "selected slots carry a quantity")
  self._quantityMax = owned
  self._quantity = 1
  if owned == 1 then
    self:_enterTossConfirm()
    return
  end
  self._state = "toss_quantity"
end

---@param direction string
function BagController:_adjustQuantity(direction)
  local before = self._quantity
  if direction == "up" then
    self._quantity = self._quantity == self._quantityMax and 1 or self._quantity + 1
  elseif direction == "down" then
    self._quantity = self._quantity == 1 and self._quantityMax or self._quantity - 1
  elseif direction == "left" then
    self._quantity = math.max(1, self._quantity - 10)
  elseif direction == "right" then
    self._quantity = math.min(self._quantityMax, self._quantity + 10)
  end
  if self._quantity ~= before then
    self:_play(EFFECT.quantity)
  end
end

---@param delta integer
function BagController:_adjustQuantityByTouch(delta)
  assert(
    delta == -100 or delta == -10 or delta == -1 or delta == 1 or delta == 10 or delta == 100,
    "quantity touch deltas are source controls"
  )
  local before = self._quantity
  if delta > 0 then
    self._quantity = self._quantity == self._quantityMax and 1 or math.min(self._quantityMax, self._quantity + delta)
  else
    self._quantity = self._quantity == 1 and self._quantityMax or math.max(1, self._quantity + delta)
  end
  if self._quantity ~= before then
    self:_play(EFFECT.quantity)
  end
end

---@param delta integer
---@param touch boolean
function BagController:_adjustSaleQuantity(delta, touch)
  assert(delta == -10 or delta == -1 or delta == 1 or delta == 10, "sale quantity uses two-digit controls")
  local before = self._quantity
  if touch then
    if delta > 0 then
      self._quantity = self._quantity == self._quantityMax and 1 or math.min(self._quantityMax, self._quantity + delta)
    else
      self._quantity = self._quantity == 1 and self._quantityMax or math.max(1, self._quantity + delta)
    end
  elseif delta == 1 then
    self._quantity = self._quantity == self._quantityMax and 1 or self._quantity + 1
  elseif delta == -1 then
    self._quantity = self._quantity == 1 and self._quantityMax or self._quantity - 1
  else
    self._quantity = math.min(self._quantityMax, math.max(1, self._quantity + delta))
  end
  if before ~= self._quantity then
    self:_play(EFFECT.quantity)
  end
end

function BagController:_clearQuantityPress()
  self._quantityPressedControl = nil
  self._quantityPressedTicks = 0
end

---@param controlIndex integer
function BagController:_pressQuantityControl(controlIndex)
  assert(controlIndex >= 0 and controlIndex <= 5 and controlIndex % 1 == 0, "quantity control index is physical")
  local layout = self._resolveLayout()
  local ticks = assert(layout.quantityPressTicks, "the quantity layout carries press ticks")
  assert(ticks > 0 and ticks % 1 == 0, "quantity press ticks are positive")
  self._quantityPressedControl = controlIndex
  self._quantityPressedTicks = ticks
end

function BagController:_pressSaleControl(controlIndex)
  assert(controlIndex >= 0 and controlIndex <= 3 and controlIndex % 1 == 0, "sale control index is physical")
  local layout = self._resolveLayout()
  local ticks = assert(layout.salePressTicks, "the sale layout carries press ticks")
  assert(ticks > 0 and ticks % 1 == 0, "sale press ticks are positive")
  self._quantityPressedControl = controlIndex
  self._quantityPressedTicks = ticks
end

-- Confirms the picked quantity into the modal confirmation state, clamping
-- to whatever the latest refresh still observes. A vanished selection
-- aborts instead of carrying a stale quantity forward. The retained base
-- records which surface the confirmation owns while the typed
-- confirmation message prints; the modal prompt opens only after the
-- message completes, never in the same tick.
function BagController:_enterTossConfirm()
  self:_refresh()
  if not self:_selectionMatchesAction() then
    self:_toBrowsing()
    return
  end
  local selected = assert(self._view.selected, "a matched selection carries its record")
  local owned = checkQuantity(selected.quantity, "selected slots carry a quantity")
  self._quantityMax = owned
  self._quantity = math.min(self._quantity, owned)
  self._tossBase = self._state == "toss_quantity" and "quantity" or "action"
  self._tossStage = "confirm"
  self:_clearQuantityPress()
  self:cancelPointerCapture()
  self._prompt:dispose()
  local quantity = self._quantity
  self:_startMessage(self:_formatMessage(self._templates.tossConfirm, self:_displayName(quantity), quantity), false)
  self._state = "toss_confirm"
end

-- Consumes one modal prompt result after the tick-owned prompt step:
-- NO returns straight to browsing, YES closes the prompt and starts the
-- typed result message in the same lower window. Accepting YES never
-- mutates; only acknowledgement after the result completes commits.
function BagController:_resolveTossPrompt()
  local result = self._prompt:takeResult()
  if result == nil then
    return
  end
  if result == "no" then
    self:_toBrowsing()
  elseif result == "yes" then
    self:_refresh()
    if not self:_selectionMatchesAction() then
      self:_toBrowsing()
      return
    end
    self._prompt:dispose()
    self:cancelPointerCapture()
    local quantity = self._quantity
    self:_startMessage(self:_formatMessage(self._templates.tossResult, self:_displayName(quantity), quantity), false)
    self._tossStage = "result"
  end
end

-- The single toss commit: exactly one service call for one confirmation.
-- A failure after the refresh shows the refreshed model instead of faking
-- success; either way the menu collapses back to browsing.
function BagController:_commitToss()
  self:_refresh()
  if not self:_selectionMatchesAction() then
    self:_toBrowsing()
    return
  end
  local selected = assert(self._view.selected, "a matched selection carries its record")
  local owned = checkQuantity(selected.quantity, "selected slots carry a quantity")
  local quantity = math.min(self._quantity, owned)
  self._commands.toss(assert(self._actionItemKey, "a toss commits its snapshotted item"), quantity)
  self:_refresh()
  self:_reconcile()
  self:_normalizeFocus()
  self:_toBrowsing()
end

-- Sale begins only after the shared selected-item entry has finished. The
-- sale session owns eligibility and price rules; the controller only chooses
-- whether a quantity picker is needed and presents the returned terms.
function BagController:_beginSaleSelection()
  self:_refresh()
  if not self:_selectionMatchesAction() then
    self:_toBrowsing()
    return
  end
  local selected = assert(self._view.selected, "sale selection carries its item")
  self._saleItem = selected
  local owned = checkQuantity(selected.quantity, "selected slots carry a quantity")
  self._quantityMax = math.min(owned, 99)
  self._quantity = 1
  self._saleQuote = nil
  self._saleToken = nil
  self._saleDisplayedTotal = 0
  self._saleCommitted = false
  self._saleSoundAttempted = false
  self._salePostCommitBusy = false
  self._saleBalance = assert(self._saleSession:view().balance, "sale session exposes the current balance")
  if owned == 1 then
    self:_prepareSaleOffer()
  else
    self:_startMessage(self:_formatMessage(self._templates.sale.quantity, self:_displayName(1)), false)
    self._state = "sale_quantity"
  end
end

-- A quote captures the item identity and current revisions in the sale session. A
-- failed quote never enters the confirmation prompt and is shown as a
-- refusal; a valid quote owns the displayed total until replaced or cleared.
function BagController:_prepareSaleOffer()
  local itemKey = assert(self._actionItemKey, "a sale snapshots its item key")
  local token, termsOrReason = self._saleSession:quoteSell(itemKey, self._quantity)
  if token == nil then
    self._saleQuote = nil
    self._saleToken = nil
    self:_startMessage(self:_formatMessage(self._templates.sale.notSellable, self:_displayName(self._quantity)), false)
    self._state = "sale_refusal"
    self._saleFailed = true
    return
  end
  local terms = assert(termsOrReason, "a successful sale quote carries terms")
  self._saleToken = token
  self._saleQuote = terms
  self._saleDisplayedTotal = assert(terms.total, "sale quote terms carry their total")
  self._saleBalance = assert(self._saleSession:view().balance, "sale session exposes the current balance")
  self:_startMessage(self:_formatMessage(self._templates.sale.offer, self:_displayName(self._quantity)), true)
  self._prompt:open(assert(self._salePrompt, "sale offers carry their compact prompt placement"))
  self._state = "sale_offer"
end

function BagController:_enterSaleResult()
  assert(self._saleQuote ~= nil, "a confirmed offer carries its quote")
  self:_startMessage(self:_formatMessage(self._templates.sale.result, self:_displayName(self._quantity)), false)
  self._state = "sale_result"
end

function BagController:_commitSale()
  local token = assert(self._saleToken, "a printed sale result carries its quote token")
  local _, reason = self._saleSession:commit(token)
  if reason ~= nil then
    self._saleToken = nil
    self._saleQuote = nil
    self:_startMessage(self:_formatMessage(self._templates.sale.notSellable, self:_displayName(self._quantity)), false)
    self._saleFailed = true
    self._state = "sale_refusal"
    return
  end
  self._saleToken = nil
  self._saleQuote = nil
  self._saleCommitted = true
  self:_finishCommittedSale()
end

-- The sale is already committed before its cue and view refresh run. Keep
-- that fact published across collaborator failures so a later tick can
-- resume presentation without replaying the transaction or sound.
function BagController:_finishCommittedSale()
  assert(self._saleCommitted, "postcommit presentation follows a committed sale")
  if self._salePostCommitBusy then
    return
  end
  self._salePostCommitBusy = true
  local ok, err = pcall(function()
    if not self._saleSoundAttempted then
      self._saleSoundAttempted = true
      self:_play(EFFECT.saleComplete)
    end
    self:_refresh()
    self:_reconcile()
    self:_normalizeFocus()
    self._saleBalance = assert(self._saleSession:view().balance, "sale session exposes the current balance")
    self._saleCommitted = false
    self._saleSoundAttempted = false
    self._state = "sale_ack"
    self._saleFailed = false
  end)
  self._salePostCommitBusy = false
  if not ok then
    error(err, 0)
  end
end

function BagController:_stepSaleQuantity(uiInput)
  if self._message ~= nil then
    if not self:_messageComplete() then
      local accelerate = false
      for _, event in ipairs(uiInput) do
        validateBagEvent(event)
        if event.type == "dismiss" then
          self._result = { kind = "closed" }
          self._closed = true
          return
        elseif event.type == "confirm" or event.type == "cancel" or event.type == "pointer_down" then
          accelerate = true
        elseif event.type == "pointer_cancel" then
          self:cancelPointerCapture()
        end
      end
      self:_stepMessage(accelerate)
      return
    end
    self._message = nil
    return
  end
  for _, event in ipairs(uiInput) do
    validateBagEvent(event)
    if event.type == "navigate" then
      assert(
        event.direction == "up" or event.direction == "down" or event.direction == "left" or event.direction == "right",
        "sale quantity navigation has a cardinal direction"
      )
      self:_adjustSaleQuantity(
        event.direction == "up" and 1 or event.direction == "down" and -1 or event.direction == "left" and -10 or 10,
        false
      )
    elseif event.type == "confirm" then
      self:_confirm()
    elseif event.type == "cancel" then
      self:_cancel()
    elseif event.type == "dismiss" then
      self._result = { kind = "closed" }
      self._closed = true
      return
    elseif event.type == "pointer_down" then
      self:_pointerDown(event)
    elseif event.type == "pointer_up" then
      self:_pointerUp(event)
    elseif event.type == "pointer_move" then
      self:_pointerMove(event)
    elseif event.type == "pointer_cancel" then
      self:cancelPointerCapture()
    end
  end
end

function BagController:_stepSaleOffer(uiInput)
  if self:_consumeDismiss(uiInput) then
    return
  end
  if not self:_messageComplete() then
    local accelerate = false
    for _, event in ipairs(uiInput) do
      if event.type == "confirm" or event.type == "cancel" or event.type == "pointer_down" then
        accelerate = true
        break
      end
    end
    self:_stepMessage(accelerate)
    return
  end
  local promptStatus = self._prompt:status()
  if not promptStatus.active then
    self._prompt:open(assert(self._salePrompt, "sale offers carry their compact prompt placement"))
    self:cancelPointerCapture()
    return
  end
  self._prompt:updateFixed(uiInput)
  local result = self._prompt:takeResult()
  if result == "yes" then
    self._prompt:dispose()
    self:cancelPointerCapture()
    self:_enterSaleResult()
  elseif result == "no" then
    self:_toBrowsing()
  end
end

function BagController:_stepSaleResult(uiInput)
  if self:_consumeDismiss(uiInput) then
    return
  end
  if not self:_messageComplete() then
    local accelerate = false
    for _, event in ipairs(uiInput) do
      if event.type == "confirm" or event.type == "cancel" or event.type == "pointer_down" then
        accelerate = true
        break
      end
    end
    self:_stepMessage(accelerate)
    if not self:_messageComplete() then
      return
    end
  end
  if self._saleFailed then
    self._state = "sale_refusal"
    return
  end
  if self._saleCommitted then
    self:_finishCommittedSale()
  else
    self:_commitSale()
  end
end

function BagController:_stepSaleRefusal(uiInput)
  if self:_consumeDismiss(uiInput) then
    return
  end
  if not self:_messageComplete() then
    self:_stepMessage(false)
    return
  end
  self._message = nil
  self._state = "sale_ack"
end

function BagController:_stepSaleAck(uiInput)
  local acknowledge, dismiss = self:_scanAcknowledgement(uiInput)
  if dismiss then
    self._result = { kind = "closed" }
    self._closed = true
  elseif acknowledge then
    self:_toBrowsing()
  end
end

-- Enters manual move-target selection, capturing the moved item by semantic
-- key and absolute position. Navigation moves the insertion target through
-- the pocket's ordered items; the cursor follows so the window tracks it.
-- The instant lower message names the moved item; the upper description
-- stays intact.
function BagController:_enterMoveSelect()
  self:_refresh()
  if not self:_selectionMatchesAction() then
    self:_toBrowsing()
    return
  end
  local pocket = self:_pocket()
  self._moveFromKey = self._actionItemKey
  self._moveFromPos = self._cursor:position(pocket)
  self._moveTarget = self._moveFromPos
  self._moveClip = nil
  local selected = assert(self._view.selected, "a matched selection carries its record")
  local name = assert(selected.name, "lower messages need the selected display name")
  self:_startMessage(self:_formatMessage(self._templates.movePrompt, name), true)
  self._state = "move_select"
end

-- Starts the generated move commit clip: the unchanged clip when the
-- target equals the source, the changed clip otherwise. The reorder
-- itself runs only when the clip completes, exactly once.
---@param changed boolean
function BagController:_startMoveClip(changed)
  if self._moveClip ~= nil then
    return
  end
  local total = changed and self._moveClipTotals.changed or self._moveClipTotals.unchanged
  self._moveClip = { changed = changed, elapsed = 0, total = total }
end

-- Advances the running move clip one fixed tick. Completion restores
-- browsing for an identity reorder or commits the reorder once for a
-- changed target; a stale source reconciles without mutation.
function BagController:_stepMoveClip()
  local clip = assert(self._moveClip, "the move clip steps only while running")
  clip.elapsed = clip.elapsed + 1
  if clip.elapsed < clip.total then
    return
  end
  self._moveClip = nil
  if not clip.changed then
    self:_toBrowsing()
    return
  end
  self:_commitMove()
end

---@param target integer zero-based absolute index
function BagController:_setMoveTarget(target)
  local count = self:_count()
  if count == 0 then
    return
  end
  local clamped = math.min(math.max(target, 0), count - 1)
  if clamped == self._moveTarget then
    self:_play(EFFECT.invalid)
    return
  end
  local pocket = self:_pocket()
  self._cursor:setPosition(pocket, clamped)
  self:_ensureVisible()
  self:_refresh()
  self._moveTarget = self._cursor:position(pocket)
  self:_play(EFFECT.select)
end

---@param direction string
function BagController:_moveTargetStep(direction)
  local delta = 0
  if direction == "left" then
    delta = -1
  elseif direction == "right" then
    delta = 1
  elseif direction == "up" then
    delta = -2
  elseif direction == "down" then
    delta = 2
  else
    return
  end
  self:_setMoveTarget(self._moveTarget + delta)
end

-- The single reorder commit after the generated commit clip completes,
-- addressed by absolute pocket index so window scroll never changes its
-- meaning. The moved item stays selected at its new absolute position; a
-- stale source aborts without mutation.
function BagController:_commitMove()
  self:_refresh()
  local pocket = self:_pocket()
  local fromIndex = nil
  for index, slot in ipairs(assert(self._view.slots, "the bag view needs its pocket slots")) do
    if type(slot) == "table" and slot.item == self._moveFromKey then
      fromIndex = index
      break
    end
  end
  if fromIndex == nil then
    self:_reconcile()
    self:_toBrowsing()
    return
  end
  local count = self:_count()
  local toIndex = math.min(math.max(self._moveTarget + 1, 1), count)
  local moved = self._commands.move(pocket, fromIndex, toIndex)
  self:_refresh()
  if moved then
    -- The moved item stays selected at its new position, and browse focus
    -- follows it there.
    self:_focusSlot(toIndex - 1)
  else
    self:_reconcile()
    self:_normalizeFocus()
  end
  self:_toBrowsing()
end

-- Cancelling a pending move restores the cursor the target tracking
-- borrowed, without touching the inventory.
function BagController:_cancelMove()
  local pocket = self:_pocket()
  self._cursor:setPosition(pocket, math.min(self._moveFromPos, math.max(self:_count() - 1, 0)))
  self:_ensureVisible()
  self:_refresh()
  self:_normalizeFocus()
  self:_toBrowsing()
end

-- The single registration commit in either direction: the service owns the
-- two-slot decision, the refreshed model shows the shifted order, and the
-- menu collapses back to browsing.
---@param register boolean true for register, false for unregister
function BagController:_commitRegistration(register)
  self:_refresh()
  if not self:_selectionMatchesAction() then
    self:_toBrowsing()
    return
  end
  local itemKey = assert(self._actionItemKey, "registration commits its snapshotted item")
  if register then
    self._commands.register(itemKey)
  else
    self._commands.unregister(itemKey)
  end
  self:_refresh()
  self:_reconcile()
  self:_normalizeFocus()
  self:_toBrowsing()
end

-- Reconciles a nested state against the latest refresh: a selection the
-- outside world removed aborts the whole menu, and the picker range tracks
-- the observed quantity. Returns false when the caller must stop.
---@return boolean
function BagController:_syncNested()
  if self._state == "browsing" then
    return true
  end
  if self._state == "action_menu" then
    -- An outside revision that moved or removed the pending selection
    -- collapses the stale menu instead of offering a ghost's actions.
    if not self:_selectionMatchesAction() then
      self:_toBrowsing()
      return false
    end
    self._actions = self:_currentActions()
    return true
  end
  if self._state == "item_select" then
    -- The finite entry keeps its snapshotted actions intact until the
    -- clock completes; a selection the outside world removed aborts the
    -- pending menu instead of animating one item into another's actions.
    if not self:_selectionMatchesAction() then
      self:_toBrowsing()
      return false
    end
    return true
  end
  if self._state == "move_select" then
    local found = false
    for _, slot in ipairs(assert(self._view.slots, "the bag view needs its pocket slots")) do
      if type(slot) == "table" and slot.item == self._moveFromKey then
        found = true
        break
      end
    end
    if not found then
      self:_toBrowsing()
      return false
    end
    return true
  end
  if self._context == "sell" then
    if self._state == "sale_quantity" then
      if not self:_selectionMatchesAction() then
        self:_toBrowsing()
        return false
      end
      local selected = assert(self._view.selected, "sale quantity selection carries its item")
      self._quantityMax = math.min(checkQuantity(selected.quantity, "selected slots carry a quantity"), 99)
      self._quantity = math.min(self._quantity, self._quantityMax)
    end
    return true
  end
  if not self:_selectionMatchesAction() then
    self:_toBrowsing()
    return false
  end
  local selected = assert(self._view.selected, "a matched selection carries its record")
  local owned = checkQuantity(selected.quantity, "selected slots carry a quantity")
  self._quantityMax = owned
  self._quantity = math.min(math.max(self._quantity, 1), owned)
  return true
end

function BagController:_confirm()
  if self._overlay then
    self._overlay = false
    return
  end
  if self._context == "pick_held" and self._state == "browsing" and parseSlot(self._focusNode) ~= nil then
    -- Picker item activation selects directly with no nested menu;
    -- tabs and cancel keep their ordinary browsing behavior.
    local absolute = self:_focusedOccupiedAbsolute()
    if absolute == nil then
      return
    end
    local selected = assert(self._view.selected, "an occupied focus carries its record")
    local itemKey = assert(selected.item, "selected slots carry their item key")
    local probe = assert(self._isPickable, "the picker carries its eligibility probe")
    if probe(itemKey) then
      self:_emitIntent("pick", itemKey)
    end
    return
  end
  if self._state == "action_menu" then
    self:_chooseActionNode(self._actionNode)
  elseif self._state == "sale_quantity" then
    if self._feedback ~= nil then
      return
    end
    self:_play(EFFECT.select)
    self:_startFeedback("quantityConfirm", { kind = "enterSaleOffer" })
  elseif self._state == "sale_offer" then
    return
  elseif self._state == "sale_ack" then
    self:_toBrowsing()
  elseif self._state == "sale_refusal" then
    return
  elseif self._state == "toss_quantity" then
    if self._feedback ~= nil then
      return
    end
    self:_play(EFFECT.select)
    self:_startFeedback("quantityConfirm", { kind = "enterToss" })
  elseif self._state == "toss_confirm" then
    -- The modal prompt owns its fixed ticks; input from a batch that
    -- opens it here waits for the next update instead of reusing it.
    return
  elseif self._state == "move_select" then
    if self._moveClip ~= nil then
      return
    end
    self:_refresh()
    if self._moveFromKey == nil then
      self:_toBrowsing()
      return
    end
    self:_play(EFFECT.select)
    self:_startMoveClip(self._moveTarget ~= self._moveFromPos)
  elseif self._focusNode == CANCEL_NODE then
    self:_play(EFFECT.cancel)
    self._result = { kind = "closed" }
    self._closed = true
  elseif parseTab(self._focusNode) ~= nil then
    local candidate = assert(parseTab(self._focusNode), "tab focus carries a pocket")
    if candidate ~= self:_pocket() then
      self:_enterPocket(candidate)
    end
    -- Keep tab focus. A commits selection; it does not return to the item grid.
  else
    self:_openActionMenu()
  end
end

function BagController:_cancel()
  if self._overlay then
    self._overlay = false
    return
  end
  if self._state == "action_menu" then
    if self._feedback ~= nil then
      return
    end
    self:_play(EFFECT.cancel)
    self:_startFeedback("cancel", { kind = "toBrowsing" })
  elseif self._state == "sale_quantity" then
    if self._feedback ~= nil then
      return
    end
    self:_play(EFFECT.cancel)
    self:_toBrowsing()
  elseif self._state == "sale_offer" then
    return
  elseif self._state == "sale_ack" then
    self:_toBrowsing()
  elseif self._state == "sale_refusal" then
    return
  elseif self._state == "toss_quantity" then
    if self._feedback ~= nil then
      return
    end
    self:_play(EFFECT.cancel)
    self:_startFeedback("quantityCancel", { kind = "toBrowsing" })
  elseif self._state == "toss_confirm" then
    -- The modal prompt owns its fixed ticks; input from a batch that
    -- opens it here waits for the next update instead of reusing it.
    return
  elseif self._state == "move_select" then
    if self._moveClip ~= nil then
      return
    end
    self:_play(EFFECT.cancel)
    self:_cancelMove()
  else
    self:_play(EFFECT.cancel)
    self._result = { kind = "closed" }
    self._closed = true
  end
end

-- The info action opens the selected-item description overlay, but only
-- where the hero pane cannot show it: the constrained interactive-only
-- topology. Everywhere else the description already has its pane. Nested
-- action states own the info key, so it never disturbs a pending menu.
function BagController:_info()
  if self._overlay then
    self._overlay = false
    return
  end
  if self._state ~= "browsing" then
    return
  end
  if self:_focusedOccupiedAbsolute() == nil then
    return
  end
  local layout = self._resolveLayout()
  if type(layout) == "table" and layout.heroVisible == false then
    self._overlay = true
  end
end

---@param page integer -1 for previous, 1 for next
function BagController:_page(page)
  local count = self:_count()
  if count <= 6 then
    return
  end
  local pocket = self:_pocket()
  local cursor = self._cursor
  local start = cursor:scroll(pocket) + page * 6
  local maxStart = count - 1
  start = math.min(math.max(start, 0), maxStart)
  cursor:setScroll(pocket, start - (start % 2))
  cursor:setPosition(pocket, cursor:scroll(pocket))
  self:_ensureVisible()
  self:_refresh()
  -- Paging carries browse focus with the window to its top-left cell.
  self._focusNode = slotNode(cursor:scroll(pocket))
  self._lastSlot = cursor:scroll(pocket)
end

---@param a table<string, unknown>?
---@param b table<string, unknown>?
---@return boolean
local function sameTarget(a, b)
  if a == nil or b == nil then
    return a == b
  end
  return a.kind == b.kind
    and a.pocket == b.pocket
    and a.visibleIndex == b.visibleIndex
    and a.actionNode == b.actionNode
    and a.quantityControlIndex == b.quantityControlIndex
    and a.delta == b.delta
end

---@return table<string, unknown>
function BagController:_pointerState()
  return {
    state = self:_visibleState(),
    visibleSlots = self._view.visibleSlots,
  }
end

-- Activates one hit-test target through the shared paths. In nested action
-- states the same geometric targets carry the nested meaning: action
-- buttons choose, grid cells steer the move target, and Cancel pops one
-- level exactly like the cancel key.
---@param target table<string, unknown>?
function BagController:_activate(target)
  if target == nil then
    return
  end
  local state = self:_visibleState()
  if state == "description_overlay" then
    if target.kind == "description" then
      self._overlay = false
    end
    return
  end
  if state == "action_menu" then
    if target.kind == "action" then
      assert(type(target.actionNode) == "number", "action targets name their physical node")
      self._actionNode = target.actionNode
      self:_chooseActionNode(target.actionNode)
    elseif target.kind == "cancel" then
      self:_cancel()
    end
    return
  end
  if state == "toss_quantity" then
    if target.kind == "quantity_delta" then
      local delta = assert(target.delta, "quantity targets carry their step")
      self:_adjustQuantityByTouch(delta)
      self:_pressQuantityControl(assert(target.quantityControlIndex, "quantity targets name their control"))
    elseif target.kind == "confirm" then
      -- Pointer confirm shares the keyboard feedback gate.
      if self._feedback == nil then
        self:_play(EFFECT.select)
        self:_startFeedback("quantityConfirm", { kind = "enterToss" })
      end
    elseif target.kind == "cancel" then
      self:_cancel()
    end
    return
  end
  if state == "sale_quantity" then
    if target.kind == "quantity_delta" then
      local delta = assert(target.delta, "sale quantity targets carry their step")
      self:_adjustSaleQuantity(delta, true)
      self:_pressSaleControl(assert(target.quantityControlIndex, "sale targets name their physical control"))
    elseif target.kind == "confirm" then
      self:_confirm()
    elseif target.kind == "cancel" then
      self:_cancel()
    end
    return
  end
  if state == "move_select" then
    if target.kind == "item" then
      assert(type(target.visibleIndex) == "number", "item targets name their cell")
      local view = self._view
      local start = assert(view.visibleStart, "the bag view needs its window start")
      assert(type(start) == "number", "the bag view needs its window start")
      self:_setMoveTarget(start + target.visibleIndex)
    elseif target.kind == "confirm" then
      -- Pointer confirm shares the keyboard commit-clip gate.
      if self._moveClip == nil and self._moveFromKey ~= nil then
        self:_play(EFFECT.select)
        self:_startMoveClip(self._moveTarget ~= self._moveFromPos)
      end
    elseif target.kind == "cancel" then
      self:_cancel()
    end
    return
  end
  if target.kind == "description" then
    self._overlay = false
    return
  end
  if target.kind == "cancel" then
    self:_cancel()
    return
  end
  if target.kind == "pocket" then
    assert(type(target.pocket) == "string", "pocket targets name their pocket")
    if target.pocket ~= self:_pocket() then
      self:_enterPocket(target.pocket)
    end
    local view = self._view
    local start = assert(view.visibleStart, "the bag view needs its window start")
    assert(type(start) == "number", "the bag view needs its window start")
    self:_focusSlot(start)
    return
  end
  if target.kind == "item" then
    assert(type(target.visibleIndex) == "number", "item targets name their cell")
    local view = self._view
    local start = assert(view.visibleStart, "the bag view needs its window start")
    assert(type(start) == "number", "the bag view needs its window start")
    local absolute = start + target.visibleIndex
    if parseSlot(self._focusNode) == absolute then
      -- Activating the focused cell confirms through the shared path, so
      -- an empty focus stays a no-op instead of opening a ghost menu.
      self:_confirm()
    else
      self:_focusSlot(absolute)
    end
  end
end

-- The event types the Bag boundary accepts from its application and
-- session input path. Modal tick owners validate against this set before
-- delegating, so unknown types fail here instead of disappearing inside
-- a child controller that only understands its narrower subset.
local BAG_EVENT_TYPES = {
  navigate = true,
  confirm = true,
  cancel = true,
  dismiss = true,
  menu = true,
  pointer_down = true,
  pointer_move = true,
  pointer_up = true,
  pointer_cancel = true,
  pointer_scroll = true,
}

---@param event table<string, unknown>
local function validateBagEventImpl(event)
  assert(type(event) == "table" and type(event.type) == "string", "bag events need a type")
  if not BAG_EVENT_TYPES[event.type] then
    error("unknown bag event type " .. tostring(event.type), 2)
  end
end
validateBagEvent = validateBagEventImpl

-- A fresh press inside the interaction pane acknowledges the post-choice
-- state; anything outside it is not an acknowledgement.
---@param event table<string, unknown>
---@return boolean
local function pressInsidePaneImpl(event)
  return type(event.x) == "number"
    and type(event.y) == "number"
    and event.x >= 0
    and event.x < BagLayout.PANE_WIDTH
    and event.y >= 0
    and event.y < BagLayout.PANE_HEIGHT
end
pressInsidePane = pressInsidePaneImpl

---@param event table<string, unknown>
function BagController:_pointerDown(event)
  if self._state == "toss_confirm" then
    -- The modal prompt owns its fixed ticks; input from a batch that
    -- opens it here waits for the next update instead of reusing it.
    return
  end
  if self._pressId ~= nil then
    return
  end
  assert(type(event.pointerId) == "string", "pointer down needs a pointer id")
  self._pressId = event.pointerId
  local layout = self._resolveLayout()
  local hitTest = assert(layout.hitTest, "the bag layout must carry its hit test")
  local target = hitTest(event.x, event.y, self:_pointerState())
  if target == nil then
    self._pressCapture = nil
  else
    self._pressCapture = {
      kind = target.kind,
      pocket = target.pocket,
      visibleIndex = target.visibleIndex,
      actionNode = target.actionNode,
      quantityControlIndex = target.quantityControlIndex,
      delta = target.delta,
    }
  end
end

---@param event table<string, unknown>
function BagController:_pointerMove(event)
  if self._pressId ~= nil then
    return
  end
  if self:_visibleState() ~= "browsing" or self._overlay then
    return
  end
  local layout = self._resolveLayout()
  local hitTest = assert(layout.hitTest, "the bag layout must carry its hit test")
  local target = hitTest(event.x, event.y, self:_pointerState())
  if target ~= nil and target.kind == "item" and not self._overlay then
    local view = self._view
    local start = assert(view.visibleStart, "the bag view needs its window start")
    assert(type(start) == "number", "the bag view needs its window start")
    assert(type(target.visibleIndex) == "number", "item targets name their cell")
    self:_focusSlot(start + target.visibleIndex)
  end
end

---@param event table<string, unknown>
function BagController:_pointerUp(event)
  if self._state == "toss_confirm" then
    -- The modal prompt owns its fixed ticks; input from a batch that
    -- opens it here waits for the next update instead of reusing it.
    return
  end
  if event.pointerId ~= self._pressId then
    return
  end
  local down = self._pressCapture
  self._pressId = nil
  self._pressCapture = nil
  if event.dragged == true then
    return
  end
  local layout = self._resolveLayout()
  local hitTest = assert(layout.hitTest, "the bag layout must carry its hit test")
  local up = hitTest(event.x, event.y, self:_pointerState())
  if sameTarget(down, up) then
    self:_activate(up)
  end
end

---@param event table<string, unknown>
function BagController:_handleNavigate(event)
  if self._overlay then
    return
  end
  if self._state == "toss_confirm" then
    -- The modal prompt owns its fixed ticks; input from a batch that
    -- opens it here waits for the next update instead of reusing it.
    return
  end
  if self._state == "action_menu" then
    self:_moveAction(event.direction)
  elseif self._state == "toss_quantity" then
    self:_adjustQuantity(event.direction)
  elseif self._state == "move_select" then
    self:_moveTargetStep(event.direction)
  elseif self._state == "browsing" then
    self:_move(event.direction)
  end
end

-- Owns one fixed tick inside the source selection entry: the transition
-- clock advances exactly once, mapped navigation/confirm/cancel/action
-- input stays inert so the pending menu cannot be steered mid-animation,
-- and the precomputed snapshot opens as the stable action menu exactly
-- once the generated total elapses. Terminal dismissal still closes, and
-- pointer-cancel bookkeeping still clears a held capture.
---@param uiInput table[]
function BagController:_stepItemSelect(uiInput)
  self._itemSelectElapsed = self._itemSelectElapsed + 1
  for _, event in ipairs(uiInput) do
    validateBagEvent(event)
    if event.type == "dismiss" then
      self._result = { kind = "closed" }
      self._closed = true
      return
    elseif event.type == "pointer_cancel" then
      self:cancelPointerCapture()
    end
  end
  if self._closed then
    return
  end
  if self._itemSelectElapsed >= self._itemSelectTicks then
    if self._context == "sell" then
      self:_beginSaleSelection()
    else
      self._state = "action_menu"
      local selected = assert(self._view.selected, "the action menu needs its selected item")
      local name = assert(selected.name, "lower messages need the selected display name")
      self:_startMessage(self:_formatMessage(self._templates.selectedItem, name), true)
    end
  end
end

-- Owns one fixed tick inside toss confirmation: terminal dismissal closes
-- without mutation, an incomplete message consumes the batch for
-- acceleration only, a completed confirmation message opens the modal
-- prompt on its own tick, a completed result message hands off to the
-- acknowledgement state, and only an open prompt sees prompt input.
---@param uiInput table[]
function BagController:_stepTossConfirm(uiInput)
  if self:_consumeDismiss(uiInput) then
    return
  end
  if not self:_messageComplete() then
    local accelerate = false
    for _, event in ipairs(uiInput) do
      if event.type == "confirm" or event.type == "cancel" or event.type == "pointer_down" then
        accelerate = true
        break
      end
    end
    self:_stepMessage(accelerate)
    return
  end
  local promptStatus = self._prompt:status()
  if not promptStatus.active then
    if self._tossStage == "result" then
      -- The result already completed on an earlier tick, so this batch
      -- is a genuine acknowledgement, never the event that finished
      -- printing: hand it straight to the acknowledgement step.
      self._state = "toss_ack"
      self:_stepTossAck(uiInput)
      return
    end
    self._prompt:open(self._tossPrompt)
    self:cancelPointerCapture()
    self._tossStage = "prompt"
    return
  end
  self._prompt:updateFixed(uiInput)
  self:_resolveTossPrompt()
end

-- Consumes a terminal dismissal ahead of message work: validates the batch
-- in order and closes without mutation, reporting whether the tick is
-- fully handled. Events after dismissal stay unprocessed.
---@param uiInput table[]
---@return boolean
function BagController:_consumeDismiss(uiInput)
  for _, event in ipairs(uiInput) do
    validateBagEvent(event)
    if event.type == "dismiss" then
      self._result = { kind = "closed" }
      self._closed = true
      return true
    end
  end
  return false
end

-- Scans one acknowledgement batch in order: dismissal stays terminal,
-- confirmation/cancellation or a fresh in-pane press acknowledges, and
-- every other known event waits. Unknown events stay programming errors
-- through validation. The scan finishes before any terminal action so
-- batch position never decides the outcome. Returns the two flags for
-- the caller to complete with its own flow policy.
---@param uiInput table[]
---@return boolean acknowledge
---@return boolean dismiss
function BagController:_scanAcknowledgement(uiInput)
  local acknowledge, dismiss = false, false
  for _, event in ipairs(uiInput) do
    validateBagEvent(event)
    if event.type == "dismiss" then
      dismiss = true
    elseif event.type == "confirm" or event.type == "cancel" then
      acknowledge = true
    elseif event.type == "pointer_down" and pressInsidePane(event) then
      acknowledge = true
    end
  end
  return acknowledge, dismiss
end

-- Owns one fixed tick that begins in the post-choice acknowledgement
-- state: dismissal closes without mutation, A/B or a fresh in-pane press
-- commits exactly once, and anything else waits. The caller returns before
-- the ordinary loop so the newly entered browsing state never sees this
-- batch.
---@param uiInput table[]
function BagController:_stepTossAck(uiInput)
  local acknowledge, dismiss = self:_scanAcknowledgement(uiInput)
  if dismiss then
    self._result = { kind = "closed" }
    self._closed = true
    return
  end
  if acknowledge then
    self:_commitToss()
  end
end

-- Owns one fixed tick inside the active exclusive context and reports
-- whether a context owned the tick. The two contexts stay explicit:
-- latched activation feedback still clears a held pointer capture while a
-- running move commit clip accepts only terminal dismissal. Both close
-- terminally with the cancel-equivalent sound and otherwise wait for
-- their generated total, so no input replays into the flow below.
-- Feedback keeps priority over the move clip, matching the previous
-- check order.
---@param uiInput table[]
---@return boolean
function BagController:_stepExclusiveClip(uiInput)
  local feedback = self._feedback ~= nil
  local moveClip = not feedback and self._state == "move_select" and self._moveClip ~= nil
  if not feedback and not moveClip then
    return false
  end
  for _, event in ipairs(uiInput) do
    validateBagEvent(event)
    if event.type == "dismiss" then
      self:_playDismissSound()
      self._result = { kind = "closed" }
      self._closed = true
      return true
    elseif feedback and event.type == "pointer_cancel" then
      self:cancelPointerCapture()
    end
  end
  if feedback then
    self:_stepFeedback()
  else
    self:_stepMoveClip()
  end
  return true
end

-- Closed per-tick dispatch for the states with dedicated step methods.
-- Feedback and the move commit clip keep priority above this map in
-- updateFixed; every other state falls through to ordinary event
-- processing. The table holds immutable code references only.
local SUBFLOW_STEPS = {
  item_select = BagController._stepItemSelect,
  sale_quantity = BagController._stepSaleQuantity,
  sale_offer = BagController._stepSaleOffer,
  sale_result = BagController._stepSaleResult,
  sale_refusal = BagController._stepSaleRefusal,
  sale_ack = BagController._stepSaleAck,
  toss_confirm = BagController._stepTossConfirm,
  toss_ack = BagController._stepTossAck,
}

---@param uiInput table[]
function BagController:updateFixed(uiInput)
  assert(type(uiInput) == "table", "the bag input must be an event list")
  if self._closed then
    return
  end
  if self._quantityPressedTicks > 0 then
    self._quantityPressedTicks = self._quantityPressedTicks - 1
    if self._quantityPressedTicks == 0 then
      self:_clearQuantityPress()
    end
  end
  local previousRevision = self._observedRevision
  local view = self:_refresh()
  if view.revision ~= previousRevision then
    self:_reconcile()
  end
  self:_normalizeFocus()
  self:_reconcileBrowseSelection()
  if not self:_syncNested() then
    return
  end
  -- Latched activation and move commit clips own their ticks ahead of
  -- subflow dispatch; the closed map below owns the stepped sale, toss,
  -- and selection-entry states.
  if self:_stepExclusiveClip(uiInput) then
    return
  end
  local subflow = SUBFLOW_STEPS[self._state]
  if subflow ~= nil then
    subflow(self, uiInput)
    return
  end
  for _, event in ipairs(uiInput) do
    if self._closed then
      break
    end
    if self._intent ~= nil then
      break
    end
    validateBagEvent(event)
    if event.type == "navigate" then
      self:_handleNavigate(event)
    elseif event.type == "confirm" then
      self:_confirm()
    elseif event.type == "cancel" then
      self:_cancel()
    elseif event.type == "dismiss" then
      -- Terminal outside dismissal: close immediately without unwinding
      -- nested action/toss/move/overlay state through _cancel.
      self:_playDismissSound()
      self._result = { kind = "closed" }
      self._closed = true
    elseif event.type == "menu" then
      self:_info()
    elseif event.type == "pointer_down" then
      self:_pointerDown(event)
    elseif event.type == "pointer_move" then
      self:_pointerMove(event)
    elseif event.type == "pointer_up" then
      self:_pointerUp(event)
    elseif event.type == "pointer_cancel" then
      self:cancelPointerCapture()
    elseif event.type == "pointer_scroll" then
      if self._state == "browsing" and not self._overlay and type(event.dy) == "number" and event.dy ~= 0 then
        self:_page(event.dy > 0 and 1 or -1)
      end
    else
      error("unknown bag event type " .. tostring(event.type), 2)
    end
  end
end

-- Read-only flow presentation for the renderer: each helper copies the
-- current flow facts onto the record without stepping clocks, opening
-- prompts, or reconciling inventory. The dispatch conditions stay at the
-- caller so overlay and per-state visibility never change.
---@param record table<string, unknown>
function BagController:_presentActionMenu(record)
  record.actions = self._actions
  record.actionNode = self._actionNode
end

---@param record table<string, unknown>
function BagController:_presentItemSelect(record)
  record.itemSelectElapsed = self._itemSelectElapsed
  record.itemSelectTotal = self._itemSelectTicks
end

---@param record table<string, unknown>
function BagController:_presentToss(record)
  record.quantity = self._quantity
  record.quantityMax = self._quantityMax
  if self._state == "toss_quantity" and self._quantityPressedTicks > 0 then
    record.quantityPressedControl = self._quantityPressedControl
  end
  if self._state == "toss_confirm" or self._state == "toss_ack" then
    record.tossBase = self._tossBase
    local promptStatus = self._prompt:status()
    if promptStatus.active then
      record.yesNoPrompt = promptStatus
    end
  end
end

---@param record table<string, unknown>
function BagController:_presentSaleQuantity(record)
  record.quantity = self._quantity
  record.quantityMax = self._quantityMax
  record.saleBalance = self._saleBalance
  record.saleTotal = self._saleDisplayedTotal
  if self._quantityPressedTicks > 0 then
    record.quantityPressedControl = self._quantityPressedControl
  end
end

---@param record table<string, unknown>
function BagController:_presentSaleFlow(record)
  record.saleQuantity = self._quantity
  record.saleBalance = self._saleBalance
  record.saleTotal = self._saleDisplayedTotal
  if self._state == "sale_offer" then
    local promptStatus = self._prompt:status()
    if promptStatus.active then
      record.yesNoPrompt = promptStatus
    end
  end
end

---@param record table<string, unknown>
function BagController:_presentMoveSelect(record)
  record.moveTarget = self._moveTarget
  record.moveOrigin = self._moveFromPos
  if self._moveClip ~= nil then
    record.moveTransition = {
      kind = self._moveClip.changed and "changed" or "unchanged",
      elapsed = self._moveClip.elapsed,
      total = self._moveClip.total,
    }
  end
end

---@return table<string, unknown>
function BagController:status()
  if self._closed then
    return { open = false }
  end
  local view = self._view
  -- The legacy focus category and tab candidate derive from the semantic
  -- node; grid focus additionally publishes its absolute and visible cell
  -- so the renderer can frame an empty cell without an item selection.
  local focus = "items"
  local candidate = self:_pocket()
  local focusedAbsolute = parseSlot(self._focusNode)
  if focusedAbsolute ~= nil then
    focus = "items"
  elseif self._focusNode == CANCEL_NODE then
    focus = "cancel"
    focusedAbsolute = nil
  else
    focus = "tabs"
    focusedAbsolute = nil
    candidate = assert(parseTab(self._focusNode), "tab focus carries a pocket")
  end
  -- Browse selection follows the focused cell when it holds an item and is
  -- absent on an empty focus, even though the borrowed cursor keeps its
  -- last valid occupied position. Nested action states keep the occupied
  -- contract they snapshotted.
  local selected = view.selected
  local selectedAbsoluteIndex = view.selectedAbsoluteIndex
  ---@type integer?
  local focusedVisible = nil
  if focusedAbsolute ~= nil then
    local start = assert(view.visibleStart, "the bag view needs its window start")
    assert(type(start) == "number", "the bag view needs its window start")
    focusedVisible = focusedAbsolute - start
    if self:_visibleState() == "browsing" and focusedAbsolute >= self:_count() then
      selected = nil
      selectedAbsoluteIndex = nil
    end
  end
  if
    self._context == "sell"
    and self._saleItem ~= nil
    and self._state ~= "browsing"
    and self._state ~= "item_select"
  then
    selected = self._saleItem
  end
  local record = {
    open = true,
    state = self:_visibleState(),
    focus = focus,
    revision = view.revision,
    pocket = view.pocket,
    tabFocusPocket = candidate,
    pocketNativeId = view.pocketNativeId,
    pocketName = view.pocketName,
    pockets = view.pockets,
    slots = view.slots,
    selectedAbsoluteIndex = selectedAbsoluteIndex,
    visibleStart = view.visibleStart,
    visibleSlots = view.visibleSlots,
    page = view.page,
    selected = selected,
    focusedAbsoluteIndex = focusedAbsolute,
    focusedVisibleIndex = focusedVisible,
  }
  -- The value-only lower message for pure rendering: the visible prefix
  -- plus the full formatted text. The renderer never recomputes reveal.
  if self._message ~= nil and not self._overlay then
    record.lowerMessage = { visibleText = self:_visibleMessageText(), fullText = self._message.full }
  end
  if self._feedback ~= nil and not self._overlay then
    record.feedback = { kind = self._feedback.kind, elapsed = self._feedback.elapsed, total = self._feedback.total }
  end
  if self._state == "action_menu" and not self._overlay then
    self:_presentActionMenu(record)
  elseif self._state == "item_select" and not self._overlay then
    self:_presentItemSelect(record)
  elseif
    (self._state == "toss_quantity" or self._state == "toss_confirm" or self._state == "toss_ack")
    and not self._overlay
  then
    self:_presentToss(record)
  elseif self._state == "sale_quantity" and not self._overlay then
    self:_presentSaleQuantity(record)
  elseif
    self._state == "sale_offer"
    or self._state == "sale_result"
    or self._state == "sale_refusal"
    or self._state == "sale_ack"
  then
    self:_presentSaleFlow(record)
  elseif self._state == "move_select" and not self._overlay then
    self:_presentMoveSelect(record)
  end
  return record
end

---@return { kind: "closed" }?
function BagController:takeResult()
  local result = self._result
  self._result = nil
  if result ~= nil then
    self._closed = true
  end
  return result
end

function BagController:dispose()
  self:_clearQuantityPress()
  self._prompt:dispose()
  self._feedback = nil
  self._message = nil
  self._tossBase = nil
  self._tossStage = nil
  self._moveClip = nil
  self._result = nil
  self._closed = true
end

-- Held Bag pointer capture is controller-local: placement changes and
-- transitions that change hit-test meaning or hand pointer ownership to
-- the modal prompt invalidate it, so a later release can never resolve
-- against a different state.
function BagController:cancelPointerCapture()
  self._pressId = nil
  self._pressCapture = nil
end

return BagController
