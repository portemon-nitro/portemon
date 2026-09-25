-- The bounded summary controller: closed Overview/Stats/Moves pages,
-- member navigation, move-row selection, protected picking, and owned
-- reordering over an injected facts view. Pages turn with up/down (the
-- body scrolls first when its estimate overflows), members change with
-- left/right, and move rows answer up/down with detail scroll at the row
-- ends. Reorder arms on first confirmation and publishes through the
-- injected command once; a same-slot gesture disarms silently, drift
-- drops the armed gesture, and move_pick mode never reorders. Results
-- are one-shot semantic records; protected choices surface a transient
-- notice and stay open. Pure module: no love, no I/O.

---@class SummaryController
---@field _mode "summary"|"move_pick"
---@field _model SummaryController.Model
---@field _request table<string, unknown>?
---@field _reorderMoves fun(slot: integer, a: integer, b: integer, revision: integer): table<string, unknown>?
---@field _resolveLayout fun(): table<string, unknown>
---@field _cancellable boolean
---@field _slot integer
---@field _page "overview"|"stats"|"moves"
---@field _moveIndex integer
---@field _bodyOffset integer
---@field _detailOffset integer
---@field _reorderSource integer?
---@field _sourceRevision integer?
---@field _notice table<string, unknown>?
---@field _observedRevision integer?
---@field _view table<string, unknown>?
---@field _result table<string, unknown>?
---@field _closed boolean
---@field _pressId string?
---@field _pressCapture table<string, unknown>?
local SummaryController = {}
SummaryController.__index = SummaryController

SummaryController.PAGES = { "overview", "stats", "moves" }
SummaryController.BODY_CAPACITY_LINES = 9
SummaryController.DETAIL_CAPACITY_LINES = 3

---@class SummaryController.Model
---@field refresh fun(slot: integer): table<string, unknown>

---@class SummaryController.Options
---@field mode "summary"|"move_pick"
---@field model SummaryController.Model
---@field request table<string, unknown>?
---@field reorderMoves fun(slot: integer, a: integer, b: integer, revision: integer): table<string, unknown>?
---@field resolveLayout fun(): table<string, unknown>
---@field initialSlot integer?
---@field allowCancel boolean?

---@param opts SummaryController.Options
---@return SummaryController
function SummaryController.new(opts)
  assert(type(opts) == "table", "the summary controller requires options")
  assert(
    opts.mode == "summary" or opts.mode == "move_pick",
    "the summary controller requires a summary or move_pick mode"
  )
  assert(
    type(opts.model) == "table" and type(opts.model.refresh) == "function",
    "the summary controller needs a facts model"
  )
  assert(type(opts.resolveLayout) == "function", "the summary controller needs its layout resolver")
  if opts.mode == "summary" then
    assert(opts.request == nil, "summary mode carries no picker request")
    assert(type(opts.reorderMoves) == "function", "summary mode reorders through the injected command")
  else
    assert(type(opts.request) == "table", "move_pick mode carries its picker request")
    assert(opts.reorderMoves == nil, "move_pick mode never reorders")
  end
  if opts.initialSlot ~= nil then
    assert(
      type(opts.initialSlot) == "number" and opts.initialSlot % 1 == 0 and opts.initialSlot >= 0,
      "the initial slot must be a non-negative party position"
    )
  end
  local cancellable = opts.allowCancel
  if cancellable == nil then
    cancellable = true
  end
  assert(type(cancellable) == "boolean", "cancel permission must be a boolean")
  local self = setmetatable({
    _mode = opts.mode,
    _model = opts.model,
    _request = opts.request,
    _reorderMoves = opts.reorderMoves,
    _resolveLayout = opts.resolveLayout,
    _cancellable = cancellable,
    _slot = opts.initialSlot or 0,
    _page = opts.mode == "move_pick" and "moves" or "overview",
    _moveIndex = 0,
    _bodyOffset = 0,
    _detailOffset = 0,
    _reorderSource = nil,
    _sourceRevision = nil,
    _notice = nil,
    _observedRevision = nil,
    _view = nil,
    _result = nil,
    _closed = false,
    _pressId = nil,
    _pressCapture = nil,
  }, SummaryController)
  return self
end

---@return table<string, unknown> the refreshed facts for the current slot
function SummaryController:_refresh()
  local view = self._model.refresh(self._slot)
  assert(type(view) == "table", "the facts model returns a record")
  self._view = view
  return view
end

-- Reconciles transient selection against fresh facts: a changed revision
-- drops an armed reorder gesture (never applied to new moves) and resets
-- scrolled offsets; an out-of-range slot or move clamps back.
---@param view table<string, unknown>
local function reconcile(self, view)
  local revision = assert(view.revision, "facts carry their party revision")
  assert(type(revision) == "number", "revisions are numeric")
  if self._observedRevision ~= nil and revision ~= self._observedRevision then
    if self._reorderSource ~= nil then
      self._notice = { reason = "stale" }
    end
    self._reorderSource = nil
    self._sourceRevision = nil
    self._bodyOffset = 0
    self._detailOffset = 0
  end
  self._observedRevision = revision
  local slotCount = assert(view.slotCount, "facts carry their member count")
  assert(type(slotCount) == "number" and slotCount >= 1, "facts carry a positive member count")
  if self._slot > slotCount - 1 then
    self._slot = slotCount - 1
  end
  local moves = assert(view.moves, "facts carry their move rows")
  assert(type(moves) == "table", "move rows arrive as an array")
  if self._moveIndex > #moves - 1 then
    self._moveIndex = math.max(#moves - 1, 0)
  end
end

---@return number
local function bodyEstimate(self)
  local estimate = self._view.bodyLineEstimate
  if type(estimate) ~= "number" then
    return 0
  end
  return estimate
end

---@return number
local function detailEstimate(self)
  local moves = self._view.moves
  local row = moves[self._moveIndex + 1]
  if type(row) ~= "table" then
    return 0
  end
  local estimate = row.detailLines
  if type(estimate) ~= "number" then
    return 0
  end
  return estimate
end

local function clearTransient(self)
  self._notice = nil
end

---@param direction integer
local function changeMember(self, direction)
  local slotCount = assert(self._view.slotCount, "facts carry their member count")
  self._slot = (self._slot + direction) % slotCount
  self._moveIndex = 0
  self._bodyOffset = 0
  self._detailOffset = 0
  self._reorderSource = nil
  self._sourceRevision = nil
  clearTransient(self)
  self:_refresh()
  reconcile(self, self._view)
end

---@param direction integer
local function turnPage(self, direction)
  local pages = SummaryController.PAGES
  local at = 1
  for index, page in ipairs(pages) do
    if page == self._page then
      at = index
    end
  end
  self._page = pages[(at - 1 + direction) % #pages + 1]
  self._moveIndex = 0
  self._bodyOffset = 0
  self._detailOffset = 0
  self._reorderSource = nil
  self._sourceRevision = nil
  clearTransient(self)
end

local function scrollBody(self, direction)
  local overflow = bodyEstimate(self) - SummaryController.BODY_CAPACITY_LINES
  if overflow <= 0 then
    turnPage(self, direction)
    return
  end
  local next = math.min(math.max(self._bodyOffset + direction, 0), overflow)
  if next == self._bodyOffset then
    turnPage(self, direction)
    return
  end
  self._bodyOffset = next
end

local function scrollDetail(self, direction)
  local overflow = detailEstimate(self) - SummaryController.DETAIL_CAPACITY_LINES
  if overflow > 0 then
    local next = math.min(math.max(self._detailOffset + direction, 0), overflow)
    if next ~= self._detailOffset then
      self._detailOffset = next
      return true
    end
  end
  return false
end

---@param direction integer
local function moveSelection(self, direction)
  local moves = assert(self._view.moves, "facts carry their move rows")
  if #moves == 0 then
    return
  end
  local next = self._moveIndex + direction
  if next < 0 then
    if not scrollDetail(self, -1) then
      self._moveIndex = #moves - 1
      self._detailOffset = 0
    end
    return
  end
  if next > #moves - 1 then
    if not scrollDetail(self, 1) then
      self._moveIndex = 0
      self._detailOffset = 0
    end
    return
  end
  self._moveIndex = next
  self._detailOffset = 0
end

---@param direction integer
local function navigate(self, direction)
  if self._mode == "move_pick" then
    if direction == "left" or direction == "right" then
      return
    end
  end
  if direction == "left" then
    changeMember(self, -1)
    return
  end
  if direction == "right" then
    changeMember(self, 1)
    return
  end
  local step = direction == "down" and 1 or -1
  if self._page == "moves" then
    moveSelection(self, step)
    return
  end
  scrollBody(self, step)
end

local function finishPick(self)
  local moves = assert(self._view.moves, "facts carry their move rows")
  local row = moves[self._moveIndex + 1]
  if row == nil then
    self._notice = { reason = "empty", moveSlot = self._moveIndex }
    return
  end
  local request = assert(self._request, "move_pick mode carries its request")
  local protected = request.protected
  local reason = nil
  if type(protected) == "table" then
    reason = protected[self._moveIndex + 1]
  end
  if reason ~= nil then
    self._notice = { reason = reason, moveSlot = self._moveIndex }
    return
  end
  self._result = {
    kind = "move_selected",
    slot = self._slot,
    moveSlot = self._moveIndex,
    partyRevision = assert(self._view.revision, "facts carry their party revision"),
  }
  self._closed = true
end

local function finishReorder(self)
  local moves = assert(self._view.moves, "facts carry their move rows")
  if self._moveIndex + 1 > #moves then
    return
  end
  if self._reorderSource == nil then
    self._reorderSource = self._moveIndex
    self._sourceRevision = assert(self._view.revision, "facts carry their party revision")
    clearTransient(self)
    return
  end
  local source = self._reorderSource
  self._reorderSource = nil
  if source == self._moveIndex then
    self._sourceRevision = nil
    clearTransient(self)
    return
  end
  local view = self:_refresh()
  reconcile(self, view)
  if view.revision ~= self._sourceRevision then
    self._sourceRevision = nil
    self._notice = { reason = "stale" }
    return
  end
  self._sourceRevision = nil
  local reorder = assert(self._reorderMoves, "summary mode reorders through its command")
  local outcome = reorder(self._slot, source, self._moveIndex, view.revision)
  assert(type(outcome) == "table", "the reorder command answers a record")
  if outcome.kind == "changed" then
    local refreshed = self:_refresh()
    reconcile(self, refreshed)
    clearTransient(self)
    return
  end
  if outcome.kind == "stale" then
    local refreshed = self:_refresh()
    reconcile(self, refreshed)
    self._notice = { reason = "stale" }
    return
  end
  error("unknown reorder outcome " .. tostring(outcome.kind), 0)
end

local function confirm(self)
  clearTransient(self)
  if self._page ~= "moves" then
    return
  end
  if self._mode == "move_pick" then
    finishPick(self)
    return
  end
  finishReorder(self)
end

local function cancel(self)
  if self._page == "moves" and self._mode == "summary" then
    self._page = "overview"
    self._moveIndex = 0
    self._bodyOffset = 0
    self._detailOffset = 0
    self._reorderSource = nil
    self._sourceRevision = nil
    clearTransient(self)
    return
  end
  if self._mode == "move_pick" then
    self._result = { kind = "cancelled" }
    self._closed = true
    return
  end
  self._result = { kind = "return", slot = self._slot }
  self._closed = true
end

---@param target table<string, unknown>?
local function activate(self, target)
  if target == nil then
    return
  end
  local kind = target.kind
  if kind == "tab" then
    if self._mode == "move_pick" then
      return
    end
    self._page = assert(target.page, "tab targets carry their page")
    self._moveIndex = 0
    self._bodyOffset = 0
    self._detailOffset = 0
    self._reorderSource = nil
    self._sourceRevision = nil
    clearTransient(self)
    return
  end
  if kind == "member" then
    if self._mode == "move_pick" then
      return
    end
    changeMember(self, assert(target.direction, "member targets carry their direction"))
    return
  end
  if kind == "move" then
    local index = assert(target.index, "move targets carry their row")
    assert(type(index) == "number", "move targets carry a numeric row")
    local moves = assert(self._view.moves, "facts carry their move rows")
    if index < 0 or index >= #moves then
      return
    end
    self._moveIndex = index
    self._detailOffset = 0
    confirm(self)
    return
  end
  if kind == "return" then
    if self._mode == "move_pick" then
      cancel(self)
      return
    end
    self._result = { kind = "return", slot = self._slot }
    self._closed = true
    return
  end
end

local function sameTarget(left, right)
  if left == nil or right == nil then
    return false
  end
  if left.kind ~= right.kind then
    return false
  end
  return left.slot == right.slot
    and left.action == right.action
    and left.index == right.index
    and left.page == right.page
    and left.direction == right.direction
end

---@param event table<string, unknown>
function SummaryController:_pointerDown(event)
  if event.pointerId == nil then
    return
  end
  local layout = assert(self._resolveLayout(), "the summary layout is required for pointer input")
  local hitTest = assert(layout.hitTest, "the summary layout carries a hit test")
  assert(type(event.x) == "number" and type(event.y) == "number", "pointer presses carry coordinates")
  local target = hitTest(event.x, event.y)
  if target == nil then
    return
  end
  self._pressId = event.pointerId
  self._pressCapture = target
end

---@param event table<string, unknown>
function SummaryController:_pointerUp(event)
  if event.pointerId ~= self._pressId then
    return
  end
  local down = self._pressCapture
  self._pressId = nil
  self._pressCapture = nil
  if event.dragged == true then
    return
  end
  local layout = assert(self._resolveLayout(), "the summary layout is required for pointer input")
  local hitTest = assert(layout.hitTest, "the summary layout carries a hit test")
  assert(type(event.x) == "number" and type(event.y) == "number", "pointer releases carry coordinates")
  local up = hitTest(event.x, event.y)
  if sameTarget(down, up) then
    activate(self, up)
  end
end

-- One fixed tick over the tick's UI events (navigate/confirm/cancel,
-- dismiss, plus pointer_down/pointer_move/pointer_up in layout
-- coordinates). A terminal event ends the tick; a completed controller
-- ignores further input.
---@param uiInput table[]
function SummaryController:updateFixed(uiInput)
  assert(type(uiInput) == "table", "the summary input must be an event list")
  if self._closed then
    return
  end
  local view = self:_refresh()
  reconcile(self, view)
  for _, event in ipairs(uiInput) do
    if self._closed then
      break
    end
    assert(type(event) == "table" and type(event.type) == "string", "summary events need a type")
    if event.type == "navigate" then
      assert(
        event.direction == "up" or event.direction == "down" or event.direction == "left" or event.direction == "right",
        "navigation needs a cardinal direction"
      )
      navigate(self, event.direction)
    elseif event.type == "confirm" then
      confirm(self)
    elseif event.type == "cancel" or event.type == "dismiss" then
      cancel(self)
    elseif event.type == "pointer_down" then
      self:_pointerDown(event)
    elseif event.type == "pointer_move" then
      -- Hover carries no selection; release compares against the press.
    elseif event.type == "pointer_up" then
      self:_pointerUp(event)
    elseif event.type == "pointer_cancel" then
      self:cancelPointerCapture()
    elseif event.type == "menu" or event.type == "pointer_scroll" then
      -- A child application's own input policy applies: the synthesized
      -- menu edge and scroll events never drive the summary.
    else
      error("unknown summary event type " .. tostring(event.type), 2)
    end
  end
end

-- The presentation snapshot: open flag, mode, page, slot, move cursor,
-- scroll offsets, armed reorder source, transient notice, and the
-- current immutable facts. The facts record is the model's own fresh
-- value; callers must not mutate it.
---@return table<string, unknown>
function SummaryController:status()
  if self._closed then
    return { open = false }
  end
  return {
    open = true,
    mode = self._mode,
    page = self._page,
    slot = self._slot,
    moveIndex = self._moveIndex,
    bodyOffset = self._bodyOffset,
    detailOffset = self._detailOffset,
    reorderSource = self._reorderSource,
    notice = self._notice,
    facts = self._view,
    cancellable = self._cancellable,
  }
end

-- The one-shot result contract: nil until a terminal event, then exactly
-- one semantic record.
---@return table<string, unknown>?
function SummaryController:takeResult()
  local result = self._result
  self._result = nil
  if result ~= nil then
    self._closed = true
  end
  return result
end

-- Idempotent release of the logical lifetime: a pending result is
-- discarded and no completion is reported after disposal.
function SummaryController:dispose()
  self._result = nil
  self._closed = true
end

-- A press held across a layout change must not activate a different
-- post-layout target, so placement changes cancel the pointer capture.
function SummaryController:cancelPointerCapture()
  self._pressId = nil
  self._pressCapture = nil
end

return SummaryController
