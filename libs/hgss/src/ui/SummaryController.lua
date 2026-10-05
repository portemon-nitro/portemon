-- The native summary interaction state machine: paired info/skills/performance
-- groups with source axes, move detail/reorder and ribbon detail substates,
-- picker selection with protected and prospective rows, fixed-tick picture
-- epochs with one-shot semantic effects, and revision-safe publication
-- through the injected reorder command. Root browsing answers Left/Right for
-- groups (wrapping over enabled groups) and Up/Down for members (bounded,
-- skipping eggs outside info). One source action branch resolves per native
-- update in Left, Right, Up, Down, Cancel, Confirm, then touch order;
-- transition states discard action edges. Production supplies a read-only
-- navigation sample for source press/repeat timing; callback-free unit tests
-- may submit explicit semantic navigate edges instead. Pure module: no love,
-- no I/O, no RNG, no domain writes outside the injected command.

local SummaryPicturePlayer = require("libs.hgss.src.ui.SummaryPicturePlayer")

---@class SummaryController
---@field _mode "summary"|"move_pick"
---@field _model table<string, unknown>
---@field _request table<string, unknown>?
---@field _reorderMoves fun(slot: integer, a: integer, b: integer, revision: integer): table<string, unknown>?
---@field _resolveLayout fun(): table<string, unknown>
---@field _manifest table<string, unknown>?
---@field _readNavigation fun(): table<string, unknown>?
---@field _allowReorder boolean
---@field _cancellable boolean
---@field _slot integer
---@field _group string
---@field _phase string
---@field _moveSlot integer?
---@field _detailEntry integer?
---@field _reorderSource integer?
---@field _sourceRevision integer?
---@field _sourceIdentity string?
---@field _ribbonIndex integer?
---@field _notice table<string, unknown>?
---@field _observedRevision integer?
---@field _observedContext unknown
---@field _slotCount integer?
---@field _view table<string, unknown>?
---@field _result table<string, unknown>?
---@field _closed boolean
---@field _effects table[]
---@field _pictureEpoch integer
---@field _pictureIdentity string?
---@field _player SummaryPicturePlayer?
---@field _playerFresh boolean?
---@field _pressId string?
---@field _transition integer?
---@field _navTick integer?
---@field _repeatStart integer?
---@field _repeatLast integer?
local SummaryController = {}
SummaryController.__index = SummaryController

SummaryController.GROUPS = { "info", "skills", "performance" }
SummaryController.REPEAT_START_TICKS = 8
SummaryController.REPEAT_INTERVAL_TICKS = 4
SummaryController.TRANSITION_TICKS = 2
SummaryController.ENTRY_CRY_WINDOW_TICKS = 3
-- Delay-zero cries drain within a bounded post-entry window instead of on the
-- entry tick: silent while the entry settles, then exactly once.

---@class SummaryController.Options
---@field mode "summary"|"move_pick"
---@field model table<string, unknown>
---@field request table<string, unknown>?
---@field reorderMoves fun(slot: integer, a: integer, b: integer, revision: integer): table<string, unknown>?
---@field resolveLayout fun(): table<string, unknown>
---@field manifest table<string, unknown>?
---@field readNavigation fun(): table<string, unknown>?
---@field allowReorder boolean?
---@field initialSlot integer?
---@field allowCancel boolean?

---@param groups table<string, unknown>?
---@return string[]
local function groupList(groups)
  local names = {}
  for _, name in ipairs(SummaryController.GROUPS) do
    if groups == nil or groups[name] ~= nil then
      names[#names + 1] = name
    end
  end
  return names
end

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
  if opts.manifest ~= nil then
    assert(type(opts.manifest) == "table", "the summary manifest arrives as a record")
  end
  if opts.readNavigation ~= nil then
    assert(type(opts.readNavigation) == "function", "the navigation sample arrives as a callback")
  end
  local allowReorder = opts.allowReorder
  if allowReorder == nil then
    allowReorder = true
  end
  assert(type(allowReorder) == "boolean", "reorder permission must be a boolean")
  local cancellable = opts.allowCancel
  if cancellable == nil then
    cancellable = true
  end
  assert(type(cancellable) == "boolean", "cancel permission must be a boolean")
  local manifestGroups = nil
  if type(opts.manifest) == "table" then
    manifestGroups = opts.manifest.groups
    if manifestGroups ~= nil then
      assert(type(manifestGroups) == "table", "the summary manifest carries its groups")
    end
  end
  if #groupList(manifestGroups) == 0 then
    error("the summary needs at least one enabled group", 0)
  end
  local self = setmetatable({
    _mode = opts.mode,
    _model = opts.model,
    _request = opts.request,
    _reorderMoves = opts.reorderMoves,
    _resolveLayout = opts.resolveLayout,
    _manifest = opts.manifest,
    _readNavigation = opts.readNavigation,
    _allowReorder = allowReorder,
    _cancellable = cancellable,
    _slot = opts.initialSlot or 0,
    _group = opts.mode == "move_pick" and "skills" or "info",
    _phase = "root",
    _moveSlot = opts.mode == "move_pick" and 0 or nil,
    _detailEntry = nil,
    _reorderSource = nil,
    _sourceRevision = nil,
    _sourceIdentity = nil,
    _ribbonIndex = nil,
    _notice = nil,
    _observedRevision = nil,
    _observedContext = nil,
    _slotCount = nil,
    _view = nil,
    _result = nil,
    _closed = false,
    _effects = {},
    _pictureEpoch = 0,
    _pictureIdentity = nil,
    _player = nil,
    _pressId = nil,
    _transition = nil,
    _navTick = nil,
    _repeatStart = nil,
    _repeatLast = nil,
  }, SummaryController)
  return self
end

---@param row unknown
---@return boolean
local function isOccupied(row)
  return type(row) == "table" and row.kind ~= "empty"
end

---@param view table<string, unknown>
---@return table<integer, table<string, unknown>>
local function viewMoves(view)
  local moves = view.moves
  assert(type(moves) == "table", "facts carry their move rows")
  return moves
end

---@param view table<string, unknown>
---@return table<integer, table<string, unknown>>
local function viewRibbons(view)
  local ribbons = view.ribbons
  if ribbons == nil then
    return {}
  end
  assert(type(ribbons) == "table", "facts carry their ribbon records")
  return ribbons
end

---@param view table<string, unknown>
---@return string
local function identityKey(view)
  local parts = { tostring(view.pictureKey) }
  local identity = view.identity
  if type(identity) == "table" then
    parts[#parts + 1] = tostring(identity.species)
    parts[#parts + 1] = tostring(identity.form)
    parts[#parts + 1] = tostring(identity.personality)
  end
  return table.concat(parts, "|")
end

---@param self SummaryController
---@param view table<string, unknown>
---@return table<string, unknown>?
local function pictureDefinition(self, view)
  if type(self._manifest) ~= "table" then
    return nil
  end
  local pictures = self._manifest.pictures
  if type(pictures) ~= "table" then
    return nil
  end
  local key = view.pictureKey
  if type(key) ~= "string" then
    return nil
  end
  local definition = pictures[key]
  if type(definition) ~= "table" then
    return nil
  end
  if view.isEgg == true then
    local silent = {}
    for name, value in pairs(definition) do
      silent[name] = value
    end
    silent.cryDelayTicks = nil
    return silent
  end
  if definition.cryDelayTicks == 0 then
    local windowed = {}
    for name, value in pairs(definition) do
      windowed[name] = value
    end
    windowed.cryDelayTicks = SummaryController.ENTRY_CRY_WINDOW_TICKS
    return windowed
  end
  return definition
end

---@param self SummaryController
---@param view table<string, unknown>
local function rebuildPlayer(self, view)
  local definition = pictureDefinition(self, view)
  if definition == nil then
    self._player = nil
    return
  end
  local player = SummaryPicturePlayer.new(definition, self._pictureEpoch)
  player:start()
  self._player = player
  self._playerFresh = true
end

---@param self SummaryController
local function dropOldCries(self)
  local kept = {}
  for _, effect in ipairs(self._effects) do
    if type(effect) ~= "table" or effect.kind ~= "cry" then
      kept[#kept + 1] = effect
    end
  end
  self._effects = kept
end

-- Refreshes facts for the current slot and reconciles transient state: an
-- emptied party recovers once as cancelled, revision or identity drift drops
-- an armed reorder gesture, and member or appearance changes advance the
-- picture epoch with a fresh player. Returns false when the instance
-- terminally recovered.
---@param self SummaryController
---@return boolean
local function reconcile(self)
  local refresh = assert(self._model.refresh, "the summary controller needs a facts model")
  assert(type(refresh) == "function", "the facts model refreshes by slot")
  local ok, view = pcall(refresh, self._slot)
  if not ok or type(view) ~= "table" then
    if not self._closed then
      self._result = { kind = "cancelled" }
      self._closed = true
    end
    return false
  end
  local slotCount = assert(view.slotCount, "facts carry their member count")
  assert(type(slotCount) == "number" and slotCount >= 1, "facts carry a positive member count")
  slotCount = math.floor(slotCount)
  self._slotCount = slotCount
  if self._slot > slotCount - 1 then
    self._slot = slotCount - 1
    return reconcile(self)
  end
  local revision = assert(view.revision, "facts carry their party revision")
  assert(type(revision) == "number", "revisions are numeric")
  revision = math.floor(revision)
  if self._observedRevision ~= nil and revision ~= self._observedRevision then
    if self._reorderSource ~= nil then
      self._notice = { reason = "stale" }
    end
    self._reorderSource = nil
    self._sourceRevision = nil
    self._sourceIdentity = nil
    if self._phase == "move_reorder" then
      self._phase = "move_detail"
    end
  end
  self._observedRevision = revision
  self._observedContext = view.contextKey
  local identity = identityKey(view)
  local epochKey = self._slot .. "|" .. identity
  if self._pictureIdentity == nil then
    self._pictureIdentity = epochKey
    rebuildPlayer(self, view)
  elseif epochKey ~= self._pictureIdentity then
    if self._reorderSource ~= nil then
      self._notice = { reason = "stale" }
    end
    self._reorderSource = nil
    self._sourceRevision = nil
    self._sourceIdentity = nil
    if self._phase == "move_reorder" then
      self._phase = "move_detail"
    end
    self._pictureIdentity = epochKey
    self._pictureEpoch = self._pictureEpoch + 1
    dropOldCries(self)
    rebuildPlayer(self, view)
  end
  self._view = view
  return true
end

---@param self SummaryController
---@return string[]
local function enabledGroups(self)
  local groups = nil
  if type(self._manifest) == "table" then
    local manifestGroups = self._manifest.groups
    if type(manifestGroups) == "table" then
      groups = manifestGroups
    end
  end
  local names = groupList(groups)
  local view = self._view
  if type(view) == "table" and view.isEgg == true then
    local infoOnly = {}
    for _, name in ipairs(names) do
      if name == "info" then
        infoOnly[#infoOnly + 1] = name
      end
    end
    return infoOnly
  end
  return names
end

---@param self SummaryController
---@return boolean
local function isEggSelected(self)
  local view = self._view
  return type(view) == "table" and view.isEgg == true
end

---@param self SummaryController
---@param slot integer
---@return boolean
local function isSlotEligible(self, slot)
  if self._group == "info" then
    return true
  end
  local view = assert(self._view, "member scans need current facts")
  local roster = view.roster
  if type(roster) == "table" then
    local member = roster[slot + 1]
    if type(member) == "table" then
      return member.isEgg ~= true
    end
  end
  if slot == self._slot then
    return view.isEgg ~= true
  end
  return true
end

---@param self SummaryController
---@param direction integer
local function cycleGroup(self, direction)
  local names = enabledGroups(self)
  assert(#names >= 1, "the summary needs at least one enabled group")
  local at = nil
  for index, name in ipairs(names) do
    if name == self._group then
      at = index
    end
  end
  if at == nil then
    self._group = names[1]
    self._moveSlot = nil
    self._ribbonIndex = nil
    self._notice = nil
    return
  end
  local next = names[(at - 1 + direction) % #names + 1]
  if next == self._group then
    return
  end
  self._group = next
  self._moveSlot = nil
  self._ribbonIndex = nil
  self._notice = nil
end

---@param self SummaryController
---@param direction integer
local function scanMember(self, direction)
  local count = assert(self._slotCount, "member scans need the party size")
  local slot = self._slot + direction
  while slot >= 0 and slot < count and not isSlotEligible(self, slot) do
    slot = slot + direction
  end
  if slot < 0 or slot >= count or slot == self._slot then
    return
  end
  self._slot = slot
  self._moveSlot = nil
  self._ribbonIndex = nil
  self._notice = nil
  reconcile(self)
end

---@param moves table<integer, table<string, unknown>>
---@return integer?
local function firstExisting(moves)
  for index = 1, #moves do
    if isOccupied(moves[index]) then
      return index - 1
    end
  end
  return nil
end

---@param moves table<integer, table<string, unknown>>
---@param from integer
---@param direction integer
---@return integer?
local function nextExisting(moves, from, direction)
  local occupied = {}
  for index = 1, #moves do
    if isOccupied(moves[index]) then
      occupied[#occupied + 1] = index - 1
    end
  end
  if #occupied == 0 then
    return nil
  end
  local at = nil
  for position, slot in ipairs(occupied) do
    if slot == from then
      at = position
    end
  end
  if at == nil then
    return occupied[1]
  end
  return occupied[(at - 1 + direction) % #occupied + 1]
end

---@param self SummaryController
---@param row integer?
local function openMoveDetail(self, row)
  self._phase = "move_opening"
  self._transition = SummaryController.TRANSITION_TICKS
  self._detailEntry = row
  self._moveSlot = row
  self._ribbonIndex = nil
  self._notice = nil
end

---@param self SummaryController
---@param index integer
local function openRibbonDetail(self, index)
  self._phase = "ribbon_opening"
  self._transition = SummaryController.TRANSITION_TICKS
  self._ribbonIndex = index
  self._moveSlot = nil
  self._notice = nil
end

---@param self SummaryController
local function closeToRoot(self)
  self._phase = "root"
  self._transition = nil
  self._moveSlot = self._mode == "move_pick" and (self._moveSlot or 0) or nil
  self._detailEntry = nil
  self._reorderSource = nil
  self._sourceRevision = nil
  self._sourceIdentity = nil
  self._ribbonIndex = nil
  self._notice = nil
end

---@param self SummaryController
---@param result table<string, unknown>
local function terminate(self, result)
  self._result = result
  self._closed = true
end

---@param self SummaryController
local function cancel(self)
  if self._notice ~= nil then
    self._notice = nil
    return
  end
  if not self._cancellable then
    return
  end
  if self._phase == "move_detail" then
    self._group = "skills"
    closeToRoot(self)
    return
  end
  if self._phase == "move_reorder" then
    self._phase = "move_detail"
    self._reorderSource = nil
    self._sourceRevision = nil
    self._sourceIdentity = nil
    return
  end
  if self._phase == "ribbon_detail" then
    self._group = "performance"
    closeToRoot(self)
    return
  end
  if self._mode == "move_pick" then
    terminate(self, { kind = "cancelled" })
    return
  end
  terminate(self, { kind = "return", slot = self._slot })
end

---@param self SummaryController
local function armOrCompleteReorder(self)
  if self._notice ~= nil then
    self._notice = nil
    return
  end
  if not self._allowReorder then
    return
  end
  local cursor = self._moveSlot
  if cursor == nil then
    return
  end
  cursor = math.floor(cursor)
  if self._reorderSource == nil then
    local entry = self._detailEntry
    if entry == nil then
      return
    end
    self._reorderSource = entry
    self._sourceRevision = self._observedRevision
    local view = assert(self._view, "arming needs current facts")
    self._sourceIdentity = identityKey(view)
    self._phase = "move_reorder"
    self._moveSlot = entry
    return
  end
  local source = self._reorderSource
  self._reorderSource = nil
  source = math.floor(assert(source, "completion needs its source"))
  if source == cursor then
    self._sourceRevision = nil
    self._sourceIdentity = nil
    self._phase = "move_detail"
    return
  end
  local view = assert(self._view, "completion needs current facts")
  if view.revision ~= self._sourceRevision or identityKey(view) ~= self._sourceIdentity then
    self._sourceRevision = nil
    self._sourceIdentity = nil
    self._phase = "move_detail"
    self._notice = { reason = "stale" }
    return
  end
  local reorder = assert(self._reorderMoves, "summary mode reorders through its command")
  local liveRevision = assert(view.revision, "completion needs current facts")
  assert(type(liveRevision) == "number", "revisions are numeric")
  local outcome = reorder(self._slot, source, cursor, math.floor(liveRevision))
  assert(type(outcome) == "table", "the reorder command answers a record")
  if outcome.kind == "changed" then
    self._sourceRevision = nil
    self._sourceIdentity = nil
    self._phase = "move_detail"
    self._notice = nil
    if reconcile(self) then
      self._observedRevision = assert(self._view.revision, "facts carry their party revision")
    end
    return
  end
  if outcome.kind == "stale" then
    self._sourceRevision = nil
    self._sourceIdentity = nil
    self._phase = "move_detail"
    self._notice = { reason = "stale" }
    reconcile(self)
    return
  end
  error("unknown reorder outcome " .. tostring(outcome.kind), 0)
end

---@param self SummaryController
local function confirmRoot(self)
  self._notice = nil
  if self._group == "skills" then
    local moves = viewMoves(assert(self._view, "move detail needs current facts"))
    openMoveDetail(self, firstExisting(moves))
    return
  end
  if self._group == "performance" then
    local ribbons = viewRibbons(assert(self._view, "ribbon detail needs current facts"))
    if #ribbons == 0 then
      return
    end
    openRibbonDetail(self, 0)
  end
end

---@param self SummaryController
---@return integer
local function pickerMaxRow(self)
  local request = assert(self._request, "move_pick mode carries its request")
  if request.context == "replace_machine" and request.prospectiveMove ~= nil then
    return 4
  end
  return 3
end

---@param self SummaryController
local function confirmPickerRow(self)
  if self._notice ~= nil then
    return
  end
  local cursor = assert(self._moveSlot, "the picker carries its cursor")
  local request = assert(self._request, "move_pick mode carries its request")
  if request.context == "replace_machine" and request.prospectiveMove ~= nil and cursor == 4 then
    terminate(self, { kind = "cancelled" })
    return
  end
  local moves = viewMoves(assert(self._view, "picker selection needs current facts"))
  local row = moves[cursor + 1]
  if not isOccupied(row) then
    self._notice = { reason = "empty", moveSlot = cursor }
    return
  end
  local protected = request.protected
  if type(protected) == "table" then
    local reason = protected[cursor + 1]
    if reason ~= nil then
      self._notice = { reason = reason, moveSlot = cursor }
      return
    end
  end
  terminate(self, {
    kind = "move_selected",
    slot = self._slot,
    moveSlot = cursor,
    partyRevision = assert(self._view.revision, "facts carry their party revision"),
  })
end

---@param self SummaryController
local function confirm(self)
  if self._mode == "move_pick" then
    confirmPickerRow(self)
    return
  end
  if self._phase == "root" then
    confirmRoot(self)
    return
  end
  if self._phase == "move_detail" or self._phase == "move_reorder" then
    armOrCompleteReorder(self)
  end
end

---@param self SummaryController
---@param direction string
local function navigateRoot(self, direction)
  if direction == "left" then
    if isEggSelected(self) then
      return
    end
    cycleGroup(self, -1)
    return
  end
  if direction == "right" then
    if isEggSelected(self) then
      return
    end
    cycleGroup(self, 1)
    return
  end
  if direction == "up" then
    scanMember(self, -1)
    return
  end
  scanMember(self, 1)
end

---@param self SummaryController
---@param direction string
local function navigateMoveDetail(self, direction)
  if direction ~= "up" and direction ~= "down" then
    return
  end
  local moves = viewMoves(assert(self._view, "move detail needs current facts"))
  local step = direction == "down" and 1 or -1
  local cursor = self._moveSlot
  if cursor == nil then
    self._moveSlot = firstExisting(moves)
    return
  end
  self._moveSlot = nextExisting(moves, cursor, step)
end

---@param self SummaryController
---@param direction string
local function navigateRibbonDetail(self, direction)
  local ribbons = viewRibbons(assert(self._view, "ribbon detail needs current facts"))
  if #ribbons == 0 then
    return
  end
  local cursor = self._ribbonIndex or 0
  local step = 1
  if direction == "left" then
    step = -1
  elseif direction == "up" then
    step = -3
  elseif direction == "down" then
    step = 3
  end
  local next = cursor + step
  if next < 0 then
    next = 0
  end
  if next > #ribbons - 1 then
    next = #ribbons - 1
  end
  self._ribbonIndex = next
end

---@param self SummaryController
---@param direction string
local function navigatePicker(self, direction)
  if direction ~= "up" and direction ~= "down" then
    return
  end
  local cursor = assert(self._moveSlot, "the picker carries its cursor")
  local maxRow = pickerMaxRow(self)
  if direction == "down" then
    self._moveSlot = math.min(cursor + 1, maxRow)
    return
  end
  self._moveSlot = math.max(cursor - 1, 0)
end

---@param self SummaryController
---@param direction string
local function navigate(self, direction)
  if self._mode == "move_pick" then
    navigatePicker(self, direction)
    return
  end
  if self._phase == "root" then
    navigateRoot(self, direction)
    return
  end
  if self._phase == "move_detail" or self._phase == "move_reorder" then
    navigateMoveDetail(self, direction)
    return
  end
  if self._phase == "ribbon_detail" then
    navigateRibbonDetail(self, direction)
  end
end

---@param self SummaryController
---@param target table<string, unknown>
local function activateRoot(self, target)
  local kind = target.kind
  if kind == "group" then
    if self._mode == "move_pick" then
      return
    end
    local group = target.group
    if group ~= "info" and group ~= "skills" and group ~= "performance" then
      return
    end
    if isEggSelected(self) and group ~= "info" then
      return
    end
    local names = enabledGroups(self)
    local allowed = false
    for _, name in ipairs(names) do
      if name == group then
        allowed = true
      end
    end
    if not allowed then
      return
    end
    if group ~= self._group then
      self._group = group
      self._moveSlot = nil
      self._ribbonIndex = nil
      self._notice = nil
    end
    return
  end
  if kind == "member" then
    if self._mode == "move_pick" then
      return
    end
    local slot = target.slot
    if type(slot) ~= "number" or slot % 1 ~= 0 then
      return
    end
    slot = math.floor(slot)
    local count = assert(self._slotCount, "member touches need the party size")
    if slot < 0 or slot >= count or slot == self._slot then
      return
    end
    if not isSlotEligible(self, slot) then
      return
    end
    self._slot = slot
    self._moveSlot = nil
    self._ribbonIndex = nil
    self._notice = nil
    reconcile(self)
    return
  end
  if kind == "move" then
    local index = target.index
    if type(index) ~= "number" or index % 1 ~= 0 then
      return
    end
    index = math.floor(index)
    local moves = viewMoves(assert(self._view, "move touches need current facts"))
    if index < 0 or index >= #moves or not isOccupied(moves[index + 1]) then
      return
    end
    if self._mode == "move_pick" then
      local maxRow = pickerMaxRow(self)
      if index > maxRow then
        return
      end
      self._moveSlot = index
      confirmPickerRow(self)
      return
    end
    if self._group ~= "skills" then
      return
    end
    openMoveDetail(self, index)
    return
  end
  if kind == "ribbon" then
    if self._mode == "move_pick" or self._group ~= "performance" then
      return
    end
    local index = target.index
    if type(index) ~= "number" or index % 1 ~= 0 then
      return
    end
    index = math.floor(index)
    local ribbons = viewRibbons(assert(self._view, "ribbon touches need current facts"))
    if index < 0 or index >= #ribbons then
      return
    end
    openRibbonDetail(self, index)
    return
  end
  if kind == "return" then
    cancel(self)
  end
end

---@param self SummaryController
---@param event table<string, unknown>
local function pointerDown(self, event)
  if event.pointerId == nil then
    return
  end
  if self._phase ~= "root" then
    return
  end
  local layout = assert(self._resolveLayout(), "the summary layout is required for pointer input")
  local hitTest = assert(layout.hitTest, "the summary layout carries a hit test")
  assert(type(event.x) == "number" and type(event.y) == "number", "pointer presses carry coordinates")
  local target = hitTest(event.x, event.y)
  if type(target) ~= "table" then
    return
  end
  self._pressId = event.pointerId
  activateRoot(self, target)
end

---@param self SummaryController
---@param event table<string, unknown>
local function pointerUp(self, event)
  if event.pointerId ~= nil and event.pointerId == self._pressId then
    self._pressId = nil
  end
end

-- Derives one navigation direction from the read-only field sample. Root
-- browsing applies the source press/held policy (fresh presses act once,
-- held directions repeat after eight ticks and every four after); detail,
-- ribbon and picker phases answer fresh presses only. Duplicate ticks and
-- releases never replay an edge.
---@param self SummaryController
---@param freshOnly boolean
---@return string?
local function sampleNavigation(self, freshOnly)
  local read = self._readNavigation
  if read == nil then
    return nil
  end
  local sample = read()
  if type(sample) ~= "table" then
    return nil
  end
  if sample.active ~= true then
    self._repeatStart = nil
    self._repeatLast = nil
    return nil
  end
  local tick = sample.tick
  assert(type(tick) == "number" and tick % 1 == 0 and tick >= 0, "navigation samples carry their tick")
  if tick == self._navTick then
    return nil
  end
  self._navTick = tick
  local pressed = sample.pressedDirection
  if type(pressed) == "string" then
    assert(
      pressed == "up" or pressed == "down" or pressed == "left" or pressed == "right",
      "samples carry cardinal input"
    )
    self._repeatStart = tick
    self._repeatLast = tick
    return pressed
  end
  if freshOnly then
    return nil
  end
  local held = sample.heldDirection
  if type(held) ~= "string" then
    self._repeatStart = nil
    self._repeatLast = nil
    return nil
  end
  assert(held == "up" or held == "down" or held == "left" or held == "right", "samples carry cardinal input")
  if self._repeatStart == nil then
    self._repeatStart = tick
  end
  local start = assert(self._repeatStart, "held input carries its gesture start")
  if tick - start < SummaryController.REPEAT_START_TICKS then
    return nil
  end
  if self._repeatLast ~= nil and tick - self._repeatLast < SummaryController.REPEAT_INTERVAL_TICKS then
    return nil
  end
  self._repeatLast = tick
  return held
end

-- One fixed tick over the tick's UI events plus the optional read-only
-- navigation sample. Exactly one source action branch resolves per tick in
-- Left, Right, Up, Down, Cancel, Confirm, then touch order; transition and
-- gated states discard action edges without replaying them. A terminal
-- instance ignores further input.
---@param uiInput table[]
---@param gates { interactive: boolean, playback: boolean }?
function SummaryController:updateFixed(uiInput, gates)
  assert(type(uiInput) == "table", "the summary input must be an event list")
  if self._closed then
    return
  end
  local interactive = true
  local playback = true
  if gates ~= nil then
    assert(type(gates) == "table", "summary gates arrive as a record")
    if gates.interactive ~= nil then
      assert(type(gates.interactive) == "boolean", "the interactive gate is a boolean")
      interactive = gates.interactive
    end
    if gates.playback ~= nil then
      assert(type(gates.playback) == "boolean", "the playback gate is a boolean")
      playback = gates.playback
    end
  end
  if not reconcile(self) then
    return
  end
  local transitional = self._transition ~= nil
  if transitional then
    local remaining = assert(self._transition, "transitions count their ticks")
    if remaining <= 1 then
      self._transition = nil
      if self._phase == "move_opening" then
        self._phase = "move_detail"
      elseif self._phase == "ribbon_opening" then
        self._phase = "ribbon_detail"
      end
    else
      self._transition = remaining - 1
    end
  end
  local player = self._player
  if playback and player ~= nil then
    if self._playerFresh then
      self._playerFresh = false
    else
      player:updateFixed()
      for _, effect in ipairs(player:takeEffects()) do
        if type(effect) == "table" and effect.kind == "cry" then
          self._effects[#self._effects + 1] =
            { kind = "cry", slot = self._slot, pictureEpoch = self._pictureEpoch, delayApplied = true }
        end
      end
    end
  end
  if not interactive or transitional then
    sampleNavigation(self, false)
    return
  end
  local freshOnly = self._mode == "move_pick" or self._phase ~= "root"
  local sampled = sampleNavigation(self, freshOnly)
  local navs = {}
  local hasCancel = false
  local hasConfirm = false
  local touches = {}
  for _, event in ipairs(uiInput) do
    assert(type(event) == "table" and type(event.type) == "string", "summary events need a type")
    if event.type == "navigate" then
      -- Edges stay eligible behind a live sample: a non-nil sample
      -- still wins below, while a nil sample falls back to the batch
      -- edges instead of dropping them. Production behavior is
      -- unchanged: an active sample always outranks the batch.
      local direction = event.direction
      assert(type(direction) == "string", "navigation needs a cardinal direction")
      assert(
        direction == "up" or direction == "down" or direction == "left" or direction == "right",
        "navigation needs a cardinal direction"
      )
      navs[#navs + 1] = direction
    elseif event.type == "confirm" then
      hasConfirm = true
    elseif event.type == "cancel" or event.type == "dismiss" then
      hasCancel = true
    elseif event.type == "pointer_down" then
      touches[#touches + 1] = event
    elseif event.type == "pointer_up" then
      pointerUp(self, event)
    elseif event.type == "pointer_move" or event.type == "pointer_scroll" or event.type == "menu" then
      -- Hover, scroll and the host menu edge never drive the summary.
    elseif event.type == "pointer_cancel" then
      self:cancelPointerCapture()
    else
      error("unknown summary event type " .. tostring(event.type), 2)
    end
  end
  if sampled ~= nil then
    navigate(self, sampled)
    return
  end
  local priority = { left = 1, right = 2, up = 3, down = 4 }
  local best = nil
  local bestRank = 5
  for _, direction in ipairs(navs) do
    assert(type(direction) == "string", "navigation needs a cardinal direction")
    local rank = priority[direction]
    assert(type(rank) == "number", "navigation needs a cardinal direction")
    if rank < bestRank then
      bestRank = rank
      best = direction
    end
  end
  if best ~= nil then
    navigate(self, best)
    return
  end
  if hasCancel then
    cancel(self)
    return
  end
  if hasConfirm then
    confirm(self)
    return
  end
  local first = touches[1]
  if type(first) == "table" then
    pointerDown(self, first)
  end
end

-- The presentation snapshot: open flag, mode, native group/phase/cursors,
-- transition sample, picture epoch and sample, transient notice, capability
-- flags, and the current immutable facts. Absent selections are nil.
---@return table<string, unknown>
function SummaryController:status()
  if self._closed then
    return { open = false }
  end
  local picture = nil
  local player = self._player
  if player ~= nil then
    local snapshot = player:status()
    assert(type(snapshot) == "table", "picture playback carries its snapshot")
    -- The blend crosses one more boundary by nested copy, so mutating
    -- the returned status can never reach the player sample.
    local blend = nil
    if snapshot.paletteBlend ~= nil then
      local source = assert(snapshot.paletteBlend, "picture blends are records")
      assert(type(source) == "table", "picture blends are records")
      local target = assert(source.target, "picture blends carry a target")
      assert(type(target) == "table", "picture blend targets are records")
      blend = {
        coefficient = source.coefficient,
        target = { r = target.r, g = target.g, b = target.b },
      }
    end
    picture = {
      sampleIndex = snapshot.sampleIndex,
      frameIndex = snapshot.frameIndex,
      offsetX = snapshot.offsetX,
      offsetY = snapshot.offsetY,
      scaleX = snapshot.scaleX,
      scaleY = snapshot.scaleY,
      rotationTurns = snapshot.rotationTurns,
      visible = snapshot.visible,
      paletteBlend = blend,
    }
  end
  local transition = nil
  if self._transition ~= nil then
    transition = { phase = self._phase, ticksLeft = self._transition }
  end
  local ribbonPage = nil
  if self._ribbonIndex ~= nil then
    ribbonPage = math.floor(self._ribbonIndex / 9)
  end
  return {
    open = true,
    mode = self._mode,
    group = self._group,
    phase = self._phase,
    slot = self._slot,
    moveSlot = self._moveSlot,
    reorderSource = self._reorderSource,
    ribbonIndex = self._ribbonIndex,
    ribbonPage = ribbonPage,
    notice = self._notice,
    facts = self._view,
    pictureEpoch = self._pictureEpoch,
    picture = picture,
    transition = transition,
    allowCancel = self._cancellable,
    allowReorder = self._allowReorder,
  }
end

-- Transfers the queued one-shot semantic effects once; drained effects
-- never repeat.
---@return table[]
function SummaryController:takeEffects()
  local effects = self._effects
  self._effects = {}
  return effects
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

-- Idempotent release of the logical lifetime: a pending result or effect is
-- discarded and no completion is reported after disposal.
function SummaryController:dispose()
  self._result = nil
  self._effects = {}
  self._pressId = nil
  local player = self._player
  if player ~= nil then
    player:dispose()
  end
  self._closed = true
end

-- A press held across a layout change must not activate a different
-- post-layout target, so placement changes cancel the pointer capture.
function SummaryController:cancelPointerCapture()
  self._pressId = nil
end

return SummaryController
