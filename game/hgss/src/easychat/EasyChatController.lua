-- The retail word editor policy for all three modes: the per-open draft,
-- focus graph, authored browser, confirmation protocol, input modality,
-- and source transition counters. The controller owns no resources, no
-- saves, and no presentation geometry; it projects a detached view for
-- the screen and latches one terminal result. Transition counts follow
-- src/application/easy_chat_app.c and its panel commands; neighbor
-- tables follow the source grid records.

local YesNoPromptController = require("libs.hgss.src.ui.YesNoPromptController")

---@class EasyChatController
---@field _catalog table<string, unknown> borrowed message validator
---@field _request table<string, unknown> open request
---@field _mode integer open editor mode
---@field _original table<string, unknown> detached entry payload
---@field _draft table<string, unknown> per-open mutable draft
---@field _menu table<string, unknown> detached per-open menu snapshot
---@field _fontMetrics table<string, unknown>? borrowed font1 advance facts
---@field _promptShape table<string, unknown> generated compact prompt shape
---@field _effect (fun(sequence: string))? optional semantic sound boundary
---@field _observe (fun(): table<string, unknown>?)? read-only navigation observation
---@field _ticks integer fixed-tick lifetime clock
---@field _level string visible editor level
---@field _focus integer composition focus index
---@field _slot integer edited word field
---@field _tab string browser tab
---@field _group integer browser group cursor
---@field _prevGroup integer browser group cursor before BACK
---@field _list table<string, unknown>? active word list cursor
---@field _transition integer pending source transition ticks
---@field _pendingLevel string? level applied when the transition ends
---@field _prompt table<string, unknown>? active prompt controller
---@field _promptKind string? active prompt kind
---@field _terminal table<string, unknown>? latched terminal payload
---@field _terminalAt integer? tick that latched the terminal payload
---@field _exitTicks integer settled exit ticks
---@field _inputMode string entry modality
---@field _touchHeld boolean touch capture held
---@field _sliderHeld boolean slider capture held
---@field _sliderDragX number slider drag anchor x
---@field _repeatDirection string? held repeat direction
---@field _repeatStart integer tick the held repeat started
---@field _repeatLast integer tick the held repeat last fired
---@field _disposed boolean released policy owner
local EasyChatController = {}
EasyChatController.__index = EasyChatController

EasyChatController.NULL_WORD = 0xFFFF
EasyChatController.BACK = 0xFE

local SELECT_SOUND = "SEQ_SE_DP_SELECT"
local TAB_SOUND = "SEQ_SE_DP_BUTTON9"
local DISABLED_SOUND = "SEQ_SE_DP_CUSTOM06"

-- Initial repeat delay then continuous interval for held directions,
-- matching the source eight/two cadence counted on new frames.
local REPEAT_DELAY = 8
local REPEAT_INTERVAL = 4

-- Category grid neighbors {up, down, left, right} for groups 0..11 with
-- the thirteenth entry behind the back button
-- (src/application/easy_chat_app.c:sEasyChatCategoryGridNeighbors).
local CATEGORY_NEIGHBORS = {
  { 0xFE, 3, 2, 1 },
  { 0xFE, 4, 0, 2 },
  { 0xFE, 5, 1, 0 },
  { 0, 6, 5, 4 },
  { 1, 7, 3, 5 },
  { 2, 8, 4, 3 },
  { 3, 9, 8, 7 },
  { 4, 10, 6, 8 },
  { 5, 11, 7, 6 },
  { 6, 0xFE, 11, 10 },
  { 7, 0xFE, 9, 11 },
  { 8, 0xFE, 10, 9 },
}

---@param value unknown
---@return boolean
local function isU16(value)
  return type(value) == "number" and value % 1 == 0 and value >= 0 and value <= 0xFFFF
end

---@param request table<string, unknown>
---@param catalog table<string, unknown> borrowed message validator
---@return table<string, unknown> normalized payload copy
local function checkRequest(request, catalog)
  assert(type(request) == "table", "the editor requires its open request")
  local mode = request.mode
  assert(mode == 0 or mode == 1 or mode == 2, "the editor opens modes 0, 1, or 2")
  assert(request.promptId == 0, "the editor opens only the ordinary prompt")
  assert(request.alwaysConfirm == true or request.alwaysConfirm == false, "the editor requires its confirmation policy")
  assert(request.inputMode == "buttons" or request.inputMode == "touch", "the editor requires its entry modality")
  if mode == 2 then
    local message = request.message
    assert(type(message) == "table", "sentence mode requires its message")
    assert(
      type(message.bank) == "number" and type(message.number) == "number" and type(message.words) == "table",
      "sentence mode requires a banked message"
    )
    assert(isU16(message.words[1]) and isU16(message.words[2]), "sentence words are u16 identities")
    assert(catalog:template(message.bank, message.number) ~= nil, "sentence mode requires a known template")
    if
      catalog:messageStatus({
        bank = message.bank,
        number = message.number,
        words = { message.words[1], message.words[2] },
      }) == "invalid"
    then
      error("sentence mode requires known words and template", 0)
    end
    return {
      mode = 2,
      message = { bank = message.bank, number = message.number, words = { message.words[1], message.words[2] } },
    }
  end
  local words = request.words
  assert(type(words) == "table" and isU16(words[1]) and isU16(words[2]), "word modes require their word pair")
  if mode == 0 then
    assert(words[2] == 0xFFFF, "single-word mode carries no second word")
  end
  for slot = 1, 2 do
    if words[slot] ~= 0xFFFF then
      catalog:wordTokens(words[slot])
    end
  end
  return { mode = mode, words = { words[1], words[2] } }
end

---@param catalog table<string, unknown>
---@param payload table<string, unknown>
---@param other table<string, unknown> compared payload
---@return boolean changed
local function payloadChanged(catalog, payload, other)
  if payload.mode ~= other.mode then
    return true
  end
  if payload.mode == 2 then
    local a, b = payload.message, other.message
    if a.bank ~= b.bank or a.number ~= b.number then
      return true
    end
    local arity = 2
    local template = catalog:template(a.bank, a.number)
    if template ~= nil then
      arity = template.wordCount
    end
    for slot = 1, 2 do
      if slot <= arity and a.words[slot] ~= b.words[slot] then
        return true
      end
    end
    return false
  end
  if payload.words[1] ~= other.words[1] then
    return true
  end
  if payload.mode == 1 and payload.words[2] ~= other.words[2] then
    return true
  end
  return false
end

---@param catalog table<string, unknown>
---@param message table<string, unknown>
---@return table<string, unknown> normalized copy with unused fields cleared
local function normalizeMessage(catalog, message)
  local template = catalog:template(message.bank, message.number)
  local words = { message.words[1], message.words[2] }
  if template ~= nil then
    for slot = template.wordCount + 1, 2 do
      words[slot] = 0xFFFF
    end
  end
  return { bank = message.bank, number = message.number, words = words }
end

---@class EasyChatController.Options
---@field catalog table<string, unknown> borrowed message validator
---@field request table<string, unknown> open request
---@field menu table<string, unknown> detached per-open menu snapshot
---@field fontMetrics table<string, unknown>? borrowed font1 advance facts
---@field promptShape table<string, unknown> generated compact prompt shape
---@field effect (fun(sequence: string))? optional semantic sound boundary
---@field observe (fun(): table<string, unknown>?)? read-only navigation observation

---@param opts EasyChatController.Options
---@return EasyChatController
function EasyChatController.new(opts)
  assert(type(opts) == "table", "the editor requires its construction record")
  local catalog = assert(opts.catalog, "the editor borrows its catalog")
  assert(type(catalog.template) == "function", "the editor validates through its catalog")
  local payload = checkRequest(assert(opts.request, "the editor requires its request"), catalog)
  local menu = assert(opts.menu, "the editor requires its per-open menu snapshot")
  assert(type(menu.groups) == "table" and type(menu.initials) == "table", "the menu carries its lists")
  assert(type(opts.promptShape) == "table", "the editor requires its compact prompt shape")
  assert(opts.effect == nil or type(opts.effect) == "function", "the editor sound boundary must be a function")
  assert(opts.observe == nil or type(opts.observe) == "function", "the editor observation must be a function")
  local draft
  if payload.mode == 2 then
    draft = {
      bank = payload.message.bank,
      number = payload.message.number,
      words = { payload.message.words[1], payload.message.words[2] },
    }
  else
    draft = { payload.words[1], payload.words[2] }
  end
  local original
  if payload.mode == 2 then
    original = { bank = draft.bank, number = draft.number, words = { draft.words[1], draft.words[2] } }
  else
    original = { draft[1], draft[2] }
  end
  local self = setmetatable({
    _catalog = catalog,
    _request = opts.request,
    _mode = payload.mode,
    _original = original,
    _draft = draft,
    _menu = menu,
    _fontMetrics = opts.fontMetrics,
    _promptShape = opts.promptShape,
    _effect = opts.effect,
    _observe = opts.observe,
    _ticks = 0,
    _level = "composition",
    _focus = 1,
    _slot = 1,
    _tab = "groups",
    _group = 0,
    _prevGroup = 0,
    _list = nil,
    _transition = 0,
    _pendingLevel = nil,
    _prompt = nil,
    _promptKind = nil,
    _terminal = nil,
    _terminalAt = nil,
    _exitTicks = 0,
    _inputMode = opts.request.inputMode,
    _touchHeld = false,
    _sliderHeld = false,
    _sliderDragX = 0,
    _repeatDirection = nil,
    _repeatStart = 0,
    _repeatLast = 0,
    _disposed = false,
  }, EasyChatController)
  self:_clampFocus()
  return self
end

---@param self EasyChatController
---@param sequence string
function EasyChatController:_play(sequence)
  if self._effect ~= nil then
    self._effect(sequence)
  end
end

-- Ordered composition focus entries for the current draft: word fields,
-- then CONFIRM, then CANCEL. Zero-slot sentences offer no fields.
---@param self EasyChatController
---@return string[] entries
function EasyChatController:_compositionEntries()
  local entries = {}
  if self._mode == 2 then
    local template = self._catalog:template(self._draft.bank, self._draft.number)
    local arity = template ~= nil and template.wordCount or 0
    for slot = 1, arity do
      entries[#entries + 1] = "field" .. slot
    end
  else
    entries[#entries + 1] = "field1"
    if self._mode == 1 then
      entries[#entries + 1] = "field2"
    end
  end
  entries[#entries + 1] = "confirm"
  entries[#entries + 1] = "cancel"
  return entries
end

---@param self EasyChatController
function EasyChatController:_clampFocus()
  local entries = self:_compositionEntries()
  if self._focus < 1 then
    self._focus = 1
  end
  if self._focus > #entries then
    self._focus = #entries
  end
end

---@param self EasyChatController
---@return string? focused entry
function EasyChatController:_focusedEntry()
  local entries = self:_compositionEntries()
  return entries[self._focus]
end

-- Pre-confirmation change test over the unnormalized draft: mode-aware
-- identity equality where retained unused words still count.
---@param self EasyChatController
---@return boolean changed
function EasyChatController:_hasChanged()
  if self._mode == 2 then
    return payloadChanged(self._catalog, { mode = 2, message = self._draft }, { mode = 2, message = self._original })
  end
  return payloadChanged(
    self._catalog,
    { mode = self._mode, words = self._draft },
    { mode = self._mode, words = self._original }
  )
end

-- Completeness over required fields only; unused fields may stay set in
-- the draft.
---@param self EasyChatController
---@return boolean complete
function EasyChatController:_isComplete()
  if self._mode == 2 then
    local template = self._catalog:template(self._draft.bank, self._draft.number)
    if template == nil then
      return false
    end
    for slot = 1, template.wordCount do
      if self._draft.words[slot] == 0xFFFF then
        return false
      end
    end
    return true
  end
  if self._draft[1] == 0xFFFF then
    return false
  end
  if self._mode == 1 and self._draft[2] == 0xFFFF then
    return false
  end
  return true
end

---@param self EasyChatController
---@return table<string, unknown> detached original payload
function EasyChatController:_originalPayload()
  if self._mode == 2 then
    return {
      mode = 2,
      message = {
        bank = self._original.bank,
        number = self._original.number,
        words = { self._original.words[1], self._original.words[2] },
      },
    }
  end
  return { mode = self._mode, words = { self._original[1], self._original[2] } }
end

---@param self EasyChatController
---@return table<string, unknown> detached accepted payload with unused fields normalized
function EasyChatController:_acceptedPayload()
  if self._mode == 2 then
    return { mode = 2, message = normalizeMessage(self._catalog, self._draft) }
  end
  local words = { self._draft[1], self._draft[2] }
  if self._mode == 0 then
    words[2] = 0xFFFF
  end
  return { mode = self._mode, words = words }
end

---@param self EasyChatController
---@param kind string answer or quit
---@param initialSelection string
function EasyChatController:_openPrompt(kind, initialSelection)
  local prompt = YesNoPromptController.new(self._promptShape, function(sequence)
    self:_play(sequence)
  end)
  prompt:open({ x = 200, y = 96, shape = "compact", initialSelection = initialSelection })
  self._prompt = prompt
  self._promptKind = kind
  self._level = "prompt"
end

---@param self EasyChatController
function EasyChatController:_confirmComposition()
  local changed = self:_hasChanged()
  local forced = self._request.alwaysConfirm == true
  local complete = self:_isComplete()
  if (changed or forced) and complete then
    self:_openPrompt("answer", "yes")
    return
  end
  if (changed or forced) and not complete then
    self._level = "notice"
    return
  end
  self:_openPrompt("quit", "no")
end

-- Applies one resolved prompt verdict to the draft or lifetime.
---@param self EasyChatController
---@param verdict string yes or no
function EasyChatController:_applyPrompt(verdict)
  local kind = self._promptKind
  self._prompt = nil
  self._promptKind = nil
  if kind == "answer" then
    if verdict == "yes" then
      local accepted = self:_acceptedPayload()
      local changed
      if accepted.mode == 2 then
        changed = payloadChanged(self._catalog, accepted, { mode = 2, message = self._original })
      else
        changed = payloadChanged(self._catalog, accepted, { mode = accepted.mode, words = self._original })
      end
      accepted.cancelled = false
      accepted.changed = changed
      accepted.inputMode = self._inputMode
      self._terminal = accepted
      self._terminalAt = self._ticks
      self._level = "exit"
    else
      self._level = "composition"
    end
    return
  end
  if verdict == "yes" then
    local cancelled = self:_originalPayload()
    cancelled.cancelled = true
    cancelled.changed = false
    cancelled.inputMode = self._inputMode
    self._terminal = cancelled
    self._terminalAt = self._ticks
    self._level = "exit"
  else
    self._level = "composition"
  end
end

-- Opens the retail browser over the current field: categories first with
-- the group cursor at zero, matching the source entry state.
---@param self EasyChatController
function EasyChatController:_openBrowser()
  self._tab = "groups"
  self._group = 0
  self._list = nil
  self._transition = 6
  self._pendingLevel = "categories"
end

---@param self EasyChatController
---@return table[] offered word identities behind the browser cursor
function EasyChatController:_browserOffered()
  if self._tab == "groups" then
    local group = self._menu.groups[self._group + 1]
    if group == nil then
      return {}
    end
    return group.wordIds
  end
  local initial = self._menu.initials[self._group + 1]
  if initial == nil then
    return {}
  end
  return initial.candidates
end

---@param self EasyChatController
---@return boolean nonempty
function EasyChatController:_browserHasWords()
  return #self:_browserOffered() > 0
end

-- Opens the word list over a nonempty browser selection; empty groups
-- reject in place with the disabled tone.
---@param self EasyChatController
function EasyChatController:_openList()
  if not self:_browserHasWords() then
    self:_play(DISABLED_SOUND)
    return
  end
  self._list = { row = 0, col = 0, topRow = 0, quit = false, scrollFrom = 0, scrollTo = 0, scrollTick = 0 }
  self._transition = 12
  self._pendingLevel = "list"
  self._level = "transition"
end

---@param _ table<string, unknown> unused list cursor
---@param count integer
---@return integer maxTopRow
local function maxTopRowFor(_, count)
  if count > 10 then
    return math.floor((count - 10) / 2) + (count % 2)
  end
  return 0
end

---@param self EasyChatController
---@param index integer zero-based word offset
---@return boolean present
function EasyChatController:_listIndexPresent(index)
  return index >= 0 and index < #self:_browserOffered()
end

---@param self EasyChatController
---@param list table<string, unknown>
---@param direction string cursor step
function EasyChatController:_moveListCursor(list, direction)
  local count = #self:_browserOffered()
  if count == 0 then
    return
  end
  if list.quit then
    if direction == "up" then
      list.quit = false
      self:_play(SELECT_SOUND)
    end
    return
  end
  if direction == "up" then
    if list.row > 0 then
      list.row = list.row - 1
      self:_play(SELECT_SOUND)
    elseif list.topRow > 0 then
      list.topRow = list.topRow - 1
      self:_play(SELECT_SOUND)
    end
  elseif direction == "down" then
    local lastRow = math.ceil((count - list.topRow * 2) / 2) - 1
    if lastRow > 4 then
      lastRow = 4
    end
    if list.row < lastRow then
      local next = list.row + 1
      local index = list.topRow * 2 + next * 2 + list.col
      if list.col == 1 and not self:_listIndexPresent(index) then
        list.col = 0
      end
      list.row = next
      self:_play(SELECT_SOUND)
    elseif list.topRow < maxTopRowFor(list, count) then
      list.topRow = list.topRow + 1
      local index = list.topRow * 2 + list.row * 2 + list.col
      if list.col == 1 and not self:_listIndexPresent(index) then
        list.col = 0
      end
      self:_play(SELECT_SOUND)
    else
      list.quit = true
      self:_play(SELECT_SOUND)
    end
  elseif direction == "left" or direction == "right" then
    local other = list.col == 0 and 1 or 0
    local index = list.topRow * 2 + list.row * 2 + other
    if self:_listIndexPresent(index) then
      list.col = other
      self:_play(SELECT_SOUND)
    end
  end
end

---@param self EasyChatController
---@param list table<string, unknown>
---@param pages integer signed page steps
function EasyChatController:_pageList(list, pages)
  local count = #self:_browserOffered()
  local maxTop = maxTopRowFor(list, count)
  local next = list.topRow + pages * 5
  if next < 0 then
    next = 0
  end
  if next > maxTop then
    next = maxTop
  end
  if next ~= list.topRow then
    list.topRow = next
    list.row = 0
    list.col = 0
    self:_play(SELECT_SOUND)
  end
end

---@param self EasyChatController
---@return integer index zero-based selected template 0..99
function EasyChatController:_templateIndex()
  return self._draft.bank * 20 + self._draft.number
end

---@param self EasyChatController
---@param delta integer signed template steps with 99/0 wrap
function EasyChatController:_moveTemplate(delta)
  local index = (self:_templateIndex() + delta) % 100
  self._draft.bank = math.floor(index / 20)
  self._draft.number = index % 20
  self:_play(SELECT_SOUND)
end

-- Chooses the focused list word into the edited field and returns to
-- composition without publishing.
---@param self EasyChatController
function EasyChatController:_chooseListWord()
  local list = assert(self._list, "word choices resolve their list")
  if list.quit then
    self._list = nil
    self._transition = 12
    self._pendingLevel = "categories"
    return
  end
  local index = list.topRow * 2 + list.row * 2 + list.col
  local offered = self:_browserOffered()
  local wordId = offered[index + 1]
  if wordId == nil then
    return
  end
  if self._mode == 2 then
    self._draft.words[self._slot] = wordId
  else
    self._draft[self._slot] = wordId
  end
  self:_play(SELECT_SOUND)
  self._list = nil
  self._transition = 12
  self._pendingLevel = "composition"
end

---@param self EasyChatController
---@param direction string
function EasyChatController:_moveComposition(direction)
  local entries = self:_compositionEntries()
  if direction == "up" then
    if self._focus > 1 then
      self._focus = self._focus - 1
      self:_play(SELECT_SOUND)
    end
  elseif direction == "down" then
    if self._focus < #entries then
      self._focus = self._focus + 1
      self:_play(SELECT_SOUND)
    end
  elseif direction == "left" or direction == "right" then
    if self._mode == 2 then
      self:_moveTemplate(direction == "left" and -1 or 1)
    end
  end
end

---@param self EasyChatController
function EasyChatController:_activateComposition()
  local entry = self:_focusedEntry()
  if entry == "confirm" then
    self:_confirmComposition()
    return
  end
  if entry == "cancel" then
    self:_openPrompt("quit", "no")
    return
  end
  assert(type(entry) == "string", "composition commands resolve their focused entry")
  local slot = assert(tonumber(entry:match("field(%d)")) --[[@as integer]], "word fields carry their slot")
  if slot ~= nil then
    self._slot = slot
    self:_openBrowser()
  end
end

---@param self EasyChatController
---@param direction string
function EasyChatController:_moveCategories(direction)
  if self._tab == "groups" then
    if self._group == 0xFE then
      if direction == "up" then
        self._group = (self._prevGroup % 3) + 9
        self:_play(SELECT_SOUND)
      elseif direction == "down" then
        self._group = self._prevGroup % 3
        self:_play(SELECT_SOUND)
      end
      return
    end
    local neighbors = CATEGORY_NEIGHBORS[self._group + 1]
    if neighbors == nil then
      return
    end
    local slot = direction == "up" and 1 or direction == "down" and 2 or direction == "left" and 3 or 4
    local next = neighbors[slot]
    if next ~= nil then
      if self._group ~= 0xFE then
        self._prevGroup = self._group
      end
      self._group = next
      self:_play(SELECT_SOUND)
    end
    return
  end
  self:_moveInitialCell(direction)
end

---@param cells table<integer, table<string, unknown>>
---@param index integer
---@return table<string, unknown>? cell record
local function gridCellAt(cells, index)
  if index == 0xFE then
    return nil
  end
  return cells[index + 1]
end

---@param self EasyChatController
---@param direction string
function EasyChatController:_moveInitialCell(direction)
  local grid = assert(self._menu.grid, "the per-open menu carries its initial grid geometry")
  if self._group == 0xFE then
    local prev = grid[self._prevGroup + 1]
    if prev ~= nil then
      if direction == "up" then
        self._group = prev.aboveBack
        self:_play(SELECT_SOUND)
      elseif direction == "down" then
        self._group = prev.belowBack
        self:_play(SELECT_SOUND)
      end
    end
    return
  end
  local cell = gridCellAt(grid, self._group)
  if cell == nil then
    return
  end
  local slot = direction == "up" and "up" or direction == "down" and "down" or direction == "left" and "left" or "right"
  local next = cell[slot]
  if next == 0xFF or next == nil then
    return
  end
  self._prevGroup = self._group
  self._group = next
  self:_play(SELECT_SOUND)
end

---@param self EasyChatController
function EasyChatController:_activateBrowser()
  if self._group == 0xFE then
    self._level = "composition"
    return
  end
  self:_openList()
end

---@param self EasyChatController
function EasyChatController:_backBrowser()
  if self._tab == "groups" or self._tab == "abc" then
    if self._list ~= nil then
      -- Handled by the list level; unreachable here.
      return
    end
    self._transition = 16
    self._pendingLevel = "composition"
  end
end

---@param self EasyChatController
function EasyChatController:_switchTab()
  self._tab = self._tab == "groups" and "abc" or "groups"
  self._group = 0
  self._transition = 16
  self._pendingLevel = "categories"
  self:_play(TAB_SOUND)
end

-- Steps the open prompt with the prompt-owned event vocabulary and
-- applies its verdict once published.
---@param self EasyChatController
---@param events table[]
function EasyChatController:_stepPrompt(events)
  local prompt = assert(self._prompt, "prompt steps resolve their controller")
  local forwarded = {}
  for _, event in ipairs(events) do
    if type(event) == "table" and type(event.type) == "string" then
      if event.type == "touch" and event.phase == "down" then
        forwarded[#forwarded + 1] = { type = "pointer_down", x = event.x, y = event.y, pointerId = event.pointerId }
      elseif
        event.type == "confirm"
        or event.type == "cancel"
        or event.type == "navigate"
        or event.type == "button"
      then
        forwarded[#forwarded + 1] = event
      end
    end
  end
  prompt:updateFixed(forwarded)
  local verdict = prompt:takeResult()
  if verdict ~= nil then
    self:_applyPrompt(verdict)
  end
end

---@param self EasyChatController
---@param events table[]
---@param observation table<string, unknown>? read-only navigation sample
function EasyChatController:_stepComposition(events, observation)
  for _, event in ipairs(events) do
    if type(event) == "table" and type(event.type) == "string" then
      local kind = event.type
      if kind == "confirm" then
        self:_activateComposition()
        return
      elseif kind == "cancel" then
        self:_openPrompt("quit", "no")
        return
      elseif kind == "navigate" and observation == nil then
        self:_moveComposition(event.direction)
      elseif kind == "button" then
        self:_pressButton(event.button)
      elseif kind == "touch" then
        if event.phase == "down" then
          if self:_pressCompositionTouch(event.x, event.y) then
            if self._transition > 0 or self._level ~= "composition" then
              return
            end
          end
        elseif (event.phase == "move" or event.phase == "up" or event.phase == "cancel") and self._sliderHeld then
          self:_dragSliderTouch(event.x, event.y, event.phase)
          if self._transition > 0 or self._level ~= "composition" then
            return
          end
        end
      end
    end
  end
  if observation ~= nil then
    self:_stepHeldDirections(observation, function(direction)
      self:_moveComposition(direction)
    end)
  end
end

---@param self EasyChatController
---@param observation table<string, unknown>
---@param apply fun(direction: string)
function EasyChatController:_stepHeldDirections(observation, apply)
  if observation.pressedDirection ~= nil then
    self._repeatDirection = observation.pressedDirection
    self._repeatStart = self._ticks
    self._repeatLast = self._ticks
    apply(observation.pressedDirection)
    return
  end
  local held = observation.heldDirection
  if held == nil or held ~= self._repeatDirection then
    if held == nil then
      self._repeatDirection = nil
    end
    return
  end
  if self._ticks - self._repeatStart >= REPEAT_DELAY and self._ticks - self._repeatLast >= REPEAT_INTERVAL then
    self._repeatLast = self._ticks
    apply(held)
  end
end

---@param self EasyChatController
---@param button string
function EasyChatController:_pressButton(button)
  if self._level == "composition" then
    if self._mode == 1 and (button == "l" or button == "r") then
      self._slot = self._slot == 1 and 2 or 1
      self._focus = self._slot
      self:_play(SELECT_SOUND)
    elseif button == "start" and (self._mode == 0 or self._mode == 1) then
      local entries = self:_compositionEntries()
      for index, entry in ipairs(entries) do
        if entry == "confirm" then
          self._focus = index
          break
        end
      end
      self:_play(SELECT_SOUND)
    elseif self._mode == 2 and (button == "l" or button == "r") then
      self:_moveTemplate(button == "l" and -1 or 1)
    end
  elseif self._level == "list" then
    local list = self._list
    if list ~= nil and (button == "l" or button == "r") then
      self:_pageList(list, button == "l" and -1 or 1)
    elseif button == "select" then
      self:_switchTab()
    end
  elseif self._level == "categories" or self._level == "abc" then
    if button == "select" then
      self:_switchTab()
    end
  end
end

-- Hit rectangles are half-open native facts shared with the renderer:
-- main CONFIRM x192..256/y112..128, CANCEL x192..256/y136..152, word
-- fields per mode, template arrows, browser QUIT, tabs, categories,
-- list cells, and the ABC grid.
---@param x number
---@param y number
---@param rect integer[] { x0, x1, y0, y1 }
---@return boolean
local function inBox(x, y, rect)
  return x >= rect[1] and x < rect[2] and y >= rect[3] and y < rect[4]
end

---@param self EasyChatController
---@param x number
---@param y number
---@param phase string touch release phase
function EasyChatController:_dragSliderTouch(x, y, phase)
  if self._mode ~= 2 then
    self._sliderHeld = false
    return
  end
  if phase == "up" or phase == "cancel" then
    self._sliderHeld = false
    return
  end
  if type(x) ~= "number" or type(y) ~= "number" then
    self._sliderHeld = false
    return
  end
  -- Retail drag window (IsTouchInSliderRange): x 18..236 with the
  -- pointer near the thumb row. Leaving it releases the capture.
  if x < 18 or x >= 236 or y < 40 or y >= 88 then
    self._sliderHeld = false
    return
  end
  local clamped = x
  if clamped < 28 then
    clamped = 28
  elseif clamped > 226 then
    clamped = 226
  end
  local distance = clamped - (self._sliderDragX or clamped)
  if distance < 0 then
    distance = -distance
  end
  if distance < 2 then
    return
  end
  self._sliderDragX = clamped
  local index = math.floor((clamped - 28) / 2)
  if index < 0 then
    index = 0
  elseif index > 99 then
    index = 99
  end
  local bank = math.floor(index / 20)
  local number = index % 20
  if bank ~= self._draft.bank or number ~= self._draft.number then
    self._draft.bank = bank
    self._draft.number = number
    self:_play(SELECT_SOUND)
  end
end

---@param self EasyChatController
---@param x number
---@param y number
---@return boolean consumed
function EasyChatController:_pressCompositionTouch(x, y)
  if inBox(x, y, { 192, 256, 112, 128 }) then
    local entries = self:_compositionEntries()
    for index, entry in ipairs(entries) do
      if entry == "confirm" then
        self._focus = index
        break
      end
    end
    self:_confirmComposition()
    return true
  end
  if inBox(x, y, { 192, 256, 136, 152 }) then
    self:_openPrompt("quit", "no")
    return true
  end
  -- Word slots live on either pane: the renderer draws the sentence on
  -- both surfaces, so a controls-only touch journey must also open the
  -- browser without reaching for the information pane.
  if self._mode == 0 then
    if inBox(x, y, { 80, 176, 16, 32 }) then
      self._slot = 1
      self._focus = 1
      self:_openBrowser()
      return true
    end
    return false
  end
  if self._mode == 1 then
    if inBox(x, y, { 24, 120, 16, 32 }) then
      self._slot = 1
      self._focus = 1
      self:_openBrowser()
      return true
    end
    if inBox(x, y, { 136, 232, 16, 32 }) then
      self._slot = 2
      self._focus = 2
      self:_openBrowser()
      return true
    end
    return false
  end
  -- Sentence mode: template arrows, slider-thumb drag start, then the
  -- sentence strip halves for the one or two word slots.
  if inBox(x, y, { 8, 40, 52, 76 }) then
    self:_moveTemplate(-1)
    return true
  end
  if inBox(x, y, { 216, 248, 52, 76 }) then
    self:_moveTemplate(1)
    return true
  end
  local thumbX = self:_templateIndex() * 2 + 28
  if x >= thumbX - 10 and x < thumbX + 10 and y >= 64 - 12 and y < 64 + 12 then
    self._sliderHeld = true
    self._sliderDragX = x
    self:_play(SELECT_SOUND)
    return true
  end
  local template = self._catalog:template(self._draft.bank, self._draft.number)
  local arity = template ~= nil and template.wordCount or 0
  if arity == 1 then
    if inBox(x, y, { 24, 232, 8, 48 }) then
      self._slot = 1
      self:_openBrowser()
      return true
    end
  elseif arity == 2 then
    if inBox(x, y, { 24, 136, 8, 48 }) then
      self._slot = 1
      self:_openBrowser()
      return true
    end
    if inBox(x, y, { 136, 232, 8, 48 }) then
      self._slot = 2
      self:_openBrowser()
      return true
    end
  end
  return false
end

---@param self EasyChatController
---@param x number
---@param y number
---@return boolean consumed
function EasyChatController:_pressBrowserTouch(x, y)
  if inBox(x, y, { 196, 252, 164, 186 }) then
    self:_play(SELECT_SOUND)
    self:_backBrowser()
    return true
  end
  if inBox(x, y, { 16, 104, 0, 42 }) then
    if self._tab ~= "groups" then
      self._tab = "groups"
      self._group = 0
      self._prevGroup = 0
      self._transition = 16
      self._pendingLevel = "categories"
      self:_play(TAB_SOUND)
      return true
    end
    return false
  end
  if inBox(x, y, { 152, 240, 0, 42 }) then
    if self._tab ~= "abc" then
      self._tab = "abc"
      self._group = 0
      self._prevGroup = 0
      self._transition = 16
      self._pendingLevel = "categories"
      self:_play(TAB_SOUND)
      return true
    end
    return false
  end
  if self._tab == "groups" then
    for row = 0, 3 do
      for col = 0, 2 do
        if inBox(x, y, { 12 + col * 80, 12 + col * 80 + 72, 56 + row * 24, 56 + row * 24 + 16 }) then
          local index = row * 3 + col
          if self._group ~= 0xFE then
            self._prevGroup = self._group
          end
          self._group = index
          self:_openList()
          return true
        end
      end
    end
    return false
  end
  local grid = assert(self._menu.grid, "the per-open menu carries its initial grid geometry")
  for index = 0, 26 do
    local cell = grid[index + 1]
    if cell ~= nil and type(cell.x) == "number" and type(cell.y) == "number" then
      if inBox(x, y, { cell.x + 20, cell.x + 20 + 16, cell.y + 64, cell.y + 64 + 16 }) then
        if self._group ~= 0xFE then
          self._prevGroup = self._group
        end
        self._group = index
        self:_openList()
        return true
      end
    end
  end
  return false
end

---@param self EasyChatController
---@param index integer zero-based word offset
---@return boolean consumed
function EasyChatController:_chooseListIndex(index)
  local offered = self:_browserOffered()
  local wordId = offered[index + 1]
  if wordId == nil then
    return false
  end
  if self._mode == 2 then
    self._draft.words[self._slot] = wordId
  else
    self._draft[self._slot] = wordId
  end
  self:_play(SELECT_SOUND)
  self._list = nil
  self._transition = 12
  self._pendingLevel = "composition"
  return true
end

---@param self EasyChatController
---@param x number
---@param y number
---@return boolean consumed
function EasyChatController:_pressListTouch(x, y)
  local list = assert(self._list, "list touches resolve their cursor")
  if inBox(x, y, { 196, 252, 164, 186 }) then
    self:_play(SELECT_SOUND)
    self._list = nil
    self._transition = 12
    self._pendingLevel = "categories"
    self._level = "transition"
    return true
  end
  if inBox(x, y, { 16, 104, 0, 42 }) then
    if self._tab ~= "groups" then
      self:_play(TAB_SOUND)
      self._list = nil
      self._tab = "groups"
      self._group = 0
      self._transition = 16
      self._pendingLevel = "categories"
      self._level = "transition"
      return true
    end
    return false
  end
  if inBox(x, y, { 152, 240, 0, 42 }) then
    if self._tab ~= "abc" then
      self:_play(TAB_SOUND)
      self._list = nil
      self._tab = "abc"
      self._group = 0
      self._transition = 16
      self._pendingLevel = "categories"
      self._level = "transition"
      return true
    end
    return false
  end
  if inBox(x, y, { 228, 252, 48, 104 }) then
    self:_pageList(list, -1)
    return true
  end
  if inBox(x, y, { 228, 252, 104, 160 }) then
    self:_pageList(list, 1)
    return true
  end
  local topRow = list.topRow or 0
  for row = 0, 4 do
    for col = 0, 1 do
      if inBox(x, y, { 32 + col * 104, 32 + col * 104 + 72, 48 + row * 24, 48 + row * 24 + 16 }) then
        return self:_chooseListIndex(topRow * 2 + row * 2 + col)
      end
    end
  end
  return false
end

---@param self EasyChatController
---@param events table[]
---@param observation table<string, unknown>? read-only navigation sample
function EasyChatController:_stepBrowser(events, observation)
  for _, event in ipairs(events) do
    if type(event) == "table" and type(event.type) == "string" then
      local kind = event.type
      if kind == "confirm" then
        self:_activateBrowser()
        return
      elseif kind == "cancel" then
        self:_backBrowser()
        return
      elseif kind == "navigate" and observation == nil then
        self:_moveCategories(event.direction)
      elseif kind == "button" then
        self:_pressButton(event.button)
      elseif kind == "touch" and event.phase == "down" then
        if self:_pressBrowserTouch(event.x, event.y) then
          return
        end
      end
    end
  end
  if observation ~= nil then
    self:_stepHeldDirections(observation, function(direction)
      self:_moveCategories(direction)
    end)
  end
end

---@param self EasyChatController
---@param events table[]
---@param observation table<string, unknown>? read-only navigation sample
function EasyChatController:_stepList(events, observation)
  local list = assert(self._list, "list steps resolve their cursor")
  for _, event in ipairs(events) do
    if type(event) == "table" and type(event.type) == "string" then
      local kind = event.type
      if kind == "confirm" then
        self:_chooseListWord()
        return
      elseif kind == "cancel" then
        self._list = nil
        self._transition = 12
        self._pendingLevel = "categories"
        self._level = "transition"
        return
      elseif kind == "navigate" and observation == nil then
        self:_moveListCursor(list, event.direction)
      elseif kind == "button" then
        self:_pressButton(event.button)
      elseif kind == "touch" and event.phase == "down" then
        if self:_pressListTouch(event.x, event.y) then
          return
        end
      end
    end
  end
  if observation ~= nil then
    self:_stepHeldDirections(observation, function(direction)
      self:_moveListCursor(self._list, direction)
    end)
  end
end

---@param buttonsHeld boolean
---@param touchDown boolean
function EasyChatController:_arbitrateModality(buttonsHeld, touchDown)
  if touchDown then
    self._touchHeld = true
    if not buttonsHeld then
      self._inputMode = "touch"
    end
    return
  end
  if buttonsHeld and self._touchHeld then
    self._inputMode = "buttons"
  end
end

---@param events table[]
function EasyChatController:updateFixed(events)
  assert(not self._disposed, "a disposed editor steps nothing")
  assert(type(events) == "table", "the editor input must be an event list")
  self._ticks = self._ticks + 1
  if self._terminal ~= nil then
    return
  end
  if self._transition > 0 then
    self._transition = self._transition - 1
    if self._transition <= 0 then
      self._level = self._pendingLevel or self._level
      self._pendingLevel = nil
    end
    return
  end
  local observation = nil
  if self._observe ~= nil then
    local ok, sample = pcall(self._observe)
    if ok and type(sample) == "table" and sample.active == true then
      observation = sample
    end
  end
  local buttonsHeld = observation ~= nil and observation.buttonsHeld == true
  if self._level == "prompt" then
    self:_stepPrompt(events)
    return
  end
  if self._level == "notice" then
    for _, event in ipairs(events) do
      if type(event) == "table" and type(event.type) == "string" then
        local kind = event.type
        if kind == "confirm" or kind == "cancel" or kind == "navigate" then
          self._level = "composition"
          break
        elseif kind == "touch" and event.phase == "down" then
          self._level = "composition"
          break
        end
      end
    end
    return
  end
  for _, event in ipairs(events) do
    if type(event) == "table" and event.type == "touch" then
      if event.phase == "down" then
        self:_arbitrateModality(buttonsHeld, true)
      elseif event.phase == "up" or event.phase == "cancel" then
        self._touchHeld = false
        if buttonsHeld then
          self._inputMode = "buttons"
        end
      end
    end
  end
  if self._level == "composition" then
    self:_stepComposition(events, observation)
  elseif self._level == "categories" or self._level == "abc" then
    if self._tab == "abc" and self._level ~= "abc" then
      self._level = "abc"
    elseif self._tab == "groups" and self._level ~= "categories" then
      self._level = "categories"
    end
    self:_stepBrowser(events, observation)
  elseif self._level == "list" then
    self:_stepList(events, observation)
  end
end

-- The detached editor projection: mode, level, focus, browser, prompt,
-- template, timing, and modality facts. Fresh tables per call; status
-- performs no mutation and never publishes the terminal result.
---@return table<string, unknown>
function EasyChatController:view()
  local view = {
    mode = self._mode,
    level = self._level,
    time = self._ticks,
    inputMode = self._inputMode,
  }
  if self._mode == 2 then
    view.template = { bank = self._draft.bank, number = self._draft.number }
    view.words = { self._draft.words[1], self._draft.words[2] }
  else
    view.words = { self._draft[1], self._draft[2] }
  end
  if self._level == "composition" then
    view.focus = self:_focusedEntry()
    view.slot = self._slot
  elseif self._level == "categories" or self._level == "abc" then
    view.browser = { tab = self._tab, group = self._group }
  elseif self._level == "list" then
    local list = self._list or { row = 0, col = 0, topRow = 0, quit = false }
    view.list = { row = list.row, col = list.col, topRow = list.topRow, quit = list.quit }
    view.browser = { tab = self._tab, group = self._group }
  elseif self._level == "prompt" then
    local prompt = self._prompt
    view.prompt = {
      kind = self._promptKind,
      selected = prompt ~= nil and prompt:status().selected or "yes",
    }
  elseif self._level == "notice" then
    view.level = "prompt"
    view.prompt = { kind = "incomplete", selected = "yes" }
  elseif self._level == "exit" then
    view.exiting = true
  end
  return view
end

-- Latches nothing and publishes the terminal payload exactly once after
-- the exit fade completes: seven updates after acceptance, matching the
-- source unload-then-complete sequencing.
---@return table<string, unknown>? detached terminal result
function EasyChatController:takeResult()
  if self._terminal == nil or self._terminalAt == nil then
    return nil
  end
  if self._ticks - self._terminalAt < 7 then
    return nil
  end
  local result = assert(self._terminal, "terminal payloads publish exactly once")
  self._terminal = nil
  if result.mode == 2 then
    return {
      mode = result.mode,
      message = {
        bank = result.message.bank,
        number = result.message.number,
        words = { result.message.words[1], result.message.words[2] },
      },
      cancelled = result.cancelled,
      changed = result.changed,
      inputMode = result.inputMode,
    }
  end
  return {
    mode = result.mode,
    words = { result.words[1], result.words[2] },
    cancelled = result.cancelled,
    changed = result.changed,
    inputMode = result.inputMode,
  }
end

-- Drops held touch/slider capture so a stale release never activates
-- after focus loss or an input-mode change.
function EasyChatController:cancelPointerCapture()
  self._touchHeld = false
  self._sliderHeld = false
end

-- Idempotent release of the per-open editor policy; the borrowed menu
-- and catalog outlive the view.
function EasyChatController:dispose()
  self._disposed = true
  self._terminal = nil
  if self._prompt ~= nil then
    self._prompt:dispose()
    self._prompt = nil
  end
end

return EasyChatController
