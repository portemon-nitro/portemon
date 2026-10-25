-- The phone card's list, sorting, and foreground call owner. Browses the
-- acquired contacts in session order with six-row clipping and bounded
-- scrolling, applies the source automatic sorts with stable ties as
-- view-only reorderings, arms manual move with its own arrow input, and
-- delegates every call stage to one owned conversation engine. A menu
-- call names an outgoing request whose kind follows the rematch-capable
-- contact rule; a direct request entry hides ordinary selection and
-- starts the incoming path at once. Choosing a call plays the 1+6+1
-- panel timeline over the live conversation. Views are detached; status
-- never mutates. Pure module: no love dependency.

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.script.src.errors")

local PhoneCall = require("game.hgss.src.pokegear.PhoneCall")
local TrainerPhonePrograms = require("game.hgss.src.pokegear.phone.TrainerPhonePrograms")

---@class PhoneController
---@field _state table<string, unknown> the borrowed durable companion owner
---@field _catalog table<string, unknown> the borrowed contact catalog
---@field _messages table<string, unknown> the borrowed message references
---@field _world table<string, unknown> the borrowed world
---@field _audio table<string, unknown>? the borrowed audio boundary
---@field _random table<string, unknown>? the borrowed companion streams
---@field _assets table<string, unknown>? the borrowed compiled asset family
---@field _call PhoneCall the owned conversation engine
---@field _order string[] the session contact order
---@field _weights table<string, integer[]> source sort weights by contact
---@field _labels table<string, string> row labels by contact
---@field _classes table<string, string> row class tokens by contact
---@field _records table<string, table<string, unknown>> catalog contact records by key
---@field _selected integer zero-based absolute selection
---@field _scroll integer zero-based top offset into the order
---@field _scrollAnim { remaining: integer, from: integer, to: integer }? the running viewport slide
---@field _mode string list, menu, sort, manual, or call
---@field _entryOwner string menu or host, fixed by the initial entry path
---@field _menuCursor integer zero-based menu cursor
---@field _grab integer? the grabbed absolute index while moving
---@field _callHandle table<string, unknown>? the live conversation handle
---@field _callId integer conversation counter for stable runtime ids
---@field _panelTicks integer? ticks since the menu call started
---@field _result table<string, unknown>? the peekable terminal result
---@field _choiceCursor integer zero-based call choice cursor
---@field _held table<string, unknown>? the captured pointer press, when present
---@field _effect fun(sequence: string)? source UI sound effect boundary
---@field _disposed boolean
local PhoneController = {}
PhoneController.__index = PhoneController

local ROW_HEIGHT = 24
local VISIBLE_ROWS = 6
local ROW_X0 = 8
local ROW_X1 = 224
local SCROLL_X0 = 224
local SCROLL_X1 = 248
-- The manual-move arrow strip spans the source touch column x4..36.
local MOVE_STRIP_X0 = 4
local MOVE_STRIP_X1 = 36
local LIST_TOP = 8

local MENU_OPTIONS = { "Call", "Sort", "Quit" }
local SORT_OPTIONS = { "Title", "Alphabet", "Location", "Move", "Quit" }

-- Source context-menu frames in tiles (sContextMenuParam): the list
-- menu sizes to its longest entry, so the window frames two
-- sixteen-pixel text rows per option exactly like the shared list menu.
local MENU_FRAMES = {
  menu = { x = 13, y = 9, width = 16, options = 3 },
  sort = { x = 13, y = 3, width = 16, options = 5 },
}
local MENU_ROW_PITCH = 24
local MENU_TEXT_TOP = 8
local MENU_TEXT_HEIGHT = 16

-- Source tooltip lines (msg_0271 entries 20-27): the bottom bar names
-- the open menu's first prompt, and the sort menu tracks its cursor.
local TOOLTIPS = {
  "Please select the next search.",
  "Select where you wish to move.",
  "What will you do?",
  "Sort by Trainer type",
  "Sort by alphabet",
  "Sort by location",
  "Manual sort",
  "Finish sorting",
}

-- Source UI tones on the phone card: cursor motion, list decisions and
-- scrolling, and cancellation.
local CURSOR_SOUND = "SEQ_SE_GS_GEARCURSOR"
local DECIDE_SOUND = "SEQ_SE_GS_GEARDECIDE"
local CANCEL_SOUND = "SEQ_SE_GS_GEARCANCEL"

-- The list-to-call panel timeline: closed for one tick, open for six,
-- closed again. Cells are source sprite identities, not generic frames.
local PANEL_TIMELINE = { 10, 11, 11, 11, 11, 11, 11, 10 }

---@param value unknown
---@return boolean
local function isNonEmptyString(value)
  return type(value) == "string" and value ~= ""
end

---@param self PhoneController
---@param contact string
---@return boolean rematch-capable through the menu call path
local function isRematchCapable(self, contact)
  -- Invitation-capable callers are the gym leaders and Kenji behind
  -- their generated families; every other contact places an ordinary
  -- menu call. The family rides the catalog record, never key
  -- substrings, so native keys resolve exactly like fixture keys.
  local record = (self._records --[[@as table<string, table<string, unknown>>]])[contact]
  if type(record) ~= "table" then
    return false
  end
  return record.family == "gym" or record.family == "kenji"
end

---@param node unknown
---@return string? path
local function firstImage(node)
  if type(node) ~= "table" then
    return nil
  end
  assert(type(node) == "table", "phone visual scans read record nodes")
  local record = node --[[@as table<string, unknown>]]
  if type(record.image) == "string" then
    return record.image --[[@as string]]
  end
  local keys = {}
  for key in pairs(record) do
    keys[#keys + 1] = key
  end
  table.sort(keys, function(a, b)
    return tostring(a) < tostring(b)
  end)
  for _, key in ipairs(keys) do
    local found = firstImage(record[key])
    if found ~= nil then
      return found
    end
  end
  return nil
end

---@param node unknown
---@param skin integer
---@return string? path
local function skinImage(node, skin)
  if type(node) ~= "table" then
    return nil
  end
  assert(type(node) == "table", "phone visual scans read record nodes")
  local record = node --[[@as table<string, unknown>]]
  if type(record.image) == "string" then
    return record.image --[[@as string]]
  end
  for _, key in ipairs({ skin, 0 }) do
    local entry = record[key]
    if
      type(entry) == "table" and type((entry --[[@as table<string, unknown>]]).image) == "string"
    then
      return (entry --[[@as table<string, unknown>]]).image --[[@as string]]
    end
  end
  return firstImage(record)
end

-- The published-plan render entry: draws the detached phone view over the
-- resolved plan payload. Named so the presentation table carries an alias.
---@param resources table<string, unknown> borrowed host collaborators
---@param snapshot table<string, unknown> the card status carrying the detached view
---@param plan table<string, unknown> the published plan carrying the payload
local function renderPhonePresentation(resources, snapshot, plan)
  local PokegearPhoneRenderer = require("libs.hgss.src.presentation.PokegearPhoneRenderer")
  PokegearPhoneRenderer.draw(resources, snapshot.view, plan.content)
end

-- The information-pane half: the phone's upper plane.
---@param resources table<string, unknown> borrowed host collaborators
---@param plan table<string, unknown> the published plan carrying the payload
local function renderPhoneInformation(resources, _, plan)
  local PokegearPhoneRenderer = require("libs.hgss.src.presentation.PokegearPhoneRenderer")
  PokegearPhoneRenderer.drawInformation(resources, plan.content)
end

---@class PhoneController.Options
---@field state table<string, unknown> the durable companion owner
---@field catalog table<string, unknown> the borrowed contact catalog
---@field messages table<string, unknown> the borrowed message references
---@field world table<string, unknown> the borrowed world
---@field audio table<string, unknown>? the audio boundary
---@field random table<string, unknown>? the companion streams
---@field assets table<string, unknown>? the compiled asset family
---@field request { id: string, contact: string, direction: string, kind: string }? direct call entry

---@param opts PhoneController.Options
---@return PhoneController
function PhoneController.new(opts)
  assert(type(opts) == "table", "the phone card requires its options")
  assert(
    type(opts.state) == "table"
      and type(opts.state.readPhone) == "function"
      and type(opts.state.setContactOrder) == "function",
    "the phone card requires the durable companion owner"
  )
  assert(
    type(opts.catalog) == "table"
      and type(opts.catalog.contacts) == "table"
      and type(opts.catalog.contactOrder) == "table",
    "the phone card borrows the contact catalog"
  )
  assert(type(opts.messages) == "table", "the phone card borrows its message references")
  assert(type(opts.world) == "table", "the phone card borrows its world")
  assert(opts.audio == nil or type(opts.audio) == "table", "the phone card uses the audio boundary as a record")
  assert(opts.random == nil or type(opts.random) == "table", "the phone card draws through the companion streams")
  assert(opts.assets == nil or type(opts.assets) == "table", "the phone card borrows its asset family as a record")
  -- UI tones ride the shared one-shot effect boundary when the audio
  -- owner plays named sequences; toneless fakes simply stay silent.
  local effect = nil
  if type(opts.audio) == "table" and type(opts.audio.play) == "function" then
    local owner = opts.audio --[[@as table<string, unknown>]]
    local playAudio = opts.audio.play --[[@as fun(self: table<string, unknown>, sequence: unknown)]]
    local function playPhoneEffect(sequence)
      playAudio(owner, sequence)
    end
    effect = playPhoneEffect
  end
  local self = setmetatable({
    _state = opts.state,
    _catalog = opts.catalog,
    _messages = opts.messages,
    _world = opts.world,
    _audio = opts.audio,
    _random = opts.random,
    _assets = opts.assets,
    _call = PhoneCall.new({
      state = opts.state,
      catalog = opts.catalog,
      messages = opts.messages,
      world = opts.world,
      audio = opts.audio,
      random = opts.random,
    }),
    _order = {},
    _weights = {},
    _labels = {},
    _classes = {},
    _records = {},
    _selected = 0,
    _scroll = 0,
    _scrollAnim = nil,
    _mode = "list",
    _entryOwner = opts.request == nil and "menu" or "host",
    _menuCursor = 0,
    _grab = nil,
    _callHandle = nil,
    _callId = 0,
    _panelTicks = nil,
    _result = nil,
    _choiceCursor = 0,
    _held = nil,
    _effect = effect,
    _disposed = false,
  }, PhoneController)
  self:_readCatalog()
  if opts.request ~= nil then
    local request = opts.request
    assert(type(request) == "table", "direct phone entry carries its request record")
    for _, name in ipairs({ "id", "contact", "direction", "kind" }) do
      if not isNonEmptyString(request[name]) then
        Errors.raise(ScriptErrors.SCRIPT_INVALID_REFERENCE, "direct phone entry names its " .. name, { field = name })
      end
    end
    self:_beginCall(request.contact, request.direction, request.kind, request.id, false)
  end
  return self
end

-- Reads the canonical saved order for registered contacts. Weights,
-- labels, and class tokens ride along from the same catalog records.
function PhoneController:_readCatalog()
  local phone = (self._state --[[@as table<string, unknown>]]).readPhone(self._state)
  assert(type(phone) == "table", "the phone card reads its registered contacts")
  local registered = (phone --[[@as table<string, unknown>]]).contacts
  assert(type(registered) == "table", "the phone card reads its registered contacts")
  local saved = (phone --[[@as table<string, unknown>]]).contactOrder --[[@as string[] ]]
  assert(type(saved) == "table", "the phone card reads its saved contact order")
  local contacts = (self._catalog --[[@as table<string, unknown>]]).contacts --[[@as table[] ]]
  local byKey = {}
  for _, entry in ipairs(contacts) do
    assert(type(entry) == "table", "catalog contacts stay records")
    local record = entry --[[@as table<string, unknown>]]
    assert(isNonEmptyString(record.key), "catalog contacts carry semantic keys")
    local key = record.key --[[@as string]]
    byKey[key] = record
    local weights = record.sortWeights
    if type(weights) == "table" then
      local list = {}
      for _, weight in
        ipairs(weights --[[@as table[] ]])
      do
        list[#list + 1] = weight
      end
      self._weights[key] = list
    elseif record.sortWeight ~= nil then
      assert(type(record.sortWeight) == "number", "catalog sort weights stay numeric")
      self._weights[key] = {
        record.sortWeight --[[@as integer]],
      }
    else
      self._weights[key] = {}
    end
    self._records[key] = record
    local label = record.name or record.label or key
    if type(label) == "table" then
      local resolveName = self._messages.resolveName
      assert(type(resolveName) == "function", "native phone names resolve through the field message provider")
      label = resolveName(self._messages, key)
    end
    assert(type(label) == "string", "contact rows carry their label")
    self._labels[key] = label --[[@as string]]
    local class = record.className or record.class or record.classNameRef or ""
    if type(class) == "table" then
      local resolveClass = self._messages.resolveClass
      assert(type(resolveClass) == "function", "native phone classes resolve through the field message provider")
      class = resolveClass(self._messages, key)
    end
    assert(type(class) == "string", "contact rows carry their class token")
    self._classes[key] = class --[[@as string]]
  end
  local order, seen = {}, {}
  for _, key in ipairs(saved) do
    assert(isNonEmptyString(key), "saved phone order entries carry contact keys")
    assert(registered[key] ~= nil, "saved phone order entries are registered")
    assert(byKey[key] ~= nil, "saved phone order entries resolve through the catalog")
    assert(not seen[key], "saved phone order contains each contact once")
    seen[key] = true
    order[#order + 1] = key
  end
  local registeredCount = 0
  for _ in pairs(registered) do
    registeredCount = registeredCount + 1
  end
  assert(#order == registeredCount, "saved phone order contains every registered contact")
  self._order = order
  self._selected = 0
  self._scroll = 0
end

---@param contact string
---@param way integer 1-based automatic sort way
---@return integer source weight, defaulting to zero
function PhoneController:_weight(contact, way)
  local weights = self._weights[contact]
  if
    type(weights) == "table" and type((weights --[[@as integer[] ]])[way]) == "number"
  then
    return (weights --[[@as integer[] ]])[way]
  end
  return 0
end

---@return integer the bounded bottom scroll offset
function PhoneController:_maxScroll()
  return math.max(0, #self._order - 6)
end

-- Keeps the absolute selection inside the list and the viewport behind
-- it: scrolling follows the cursor but never exceeds its bound. A
-- viewport shift starts its source slide right away: three eight-pixel
-- ticks per row, so a page chains six singles while the end state lands
-- at once and input gates until the slide settles.
---@param selected integer
function PhoneController:_moveSelection(selected)
  local count = #self._order
  if count == 0 then
    self._selected = 0
    self._scroll = 0
    self._scrollAnim = nil
    return
  end
  self._selected = math.min(math.max(selected, 0), count - 1)
  local from = self._scroll
  if self._selected < self._scroll then
    self._scroll = self._selected
  elseif self._selected > self._scroll + 5 then
    self._scroll = self._selected - 5
  end
  self._scroll = math.min(math.max(self._scroll, 0), self:_maxScroll())
  if self._scroll ~= from then
    self._scrollAnim = { remaining = 3 * math.abs(self._scroll - from), from = from, to = self._scroll }
  end
end

-- Drops held pointer capture: mode changes, menu travel, and call stages
-- never fire a stale release, so a drag across a transition selects
-- nothing.
function PhoneController:cancelPointerCapture()
  self._held = nil
end

-- Starts one foreground conversation on the owned engine. Failures keep
-- their attribution and take no lease; the caller keeps its mode.
---@param contact string
---@param direction string
---@param kind string
---@param id string stable runtime id
---@param panel boolean whether the menu panel timeline runs over the start
function PhoneController:_beginCall(contact, direction, kind, id, panel)
  assert(self._callHandle == nil, "one foreground call owns the phone line")
  local ok, handle = pcall(function()
    return self._call:begin({ id = id, contact = contact, direction = direction, kind = kind })
  end)
  if not ok then
    if Errors.is(handle) then
      error(handle, 0)
    end
    Errors.raise(
      ScriptErrors.FEATURE_UNAVAILABLE,
      "phone call construction failed: " .. tostring(handle),
      { contact = contact }
    )
  end
  assert(type(handle) == "table", "conversation construction returns its handle")
  self._callHandle = handle
  self._mode = "call"
  self._choiceCursor = 0
  self._result = nil
  self._held = nil
  if panel then
    self._panelTicks = 0
  end
  if self._call:result(handle) ~= nil then
    self:_finishCall()
  end
end

-- Publishes one terminal call according to the entry owner. Menu calls
-- release their handle and restore the contact list; host calls retain
-- the handle and result until PokegearScriptHost closes them.
---@return boolean whether a terminal handoff occurred
function PhoneController:_finishCall()
  local handle = self._callHandle
  assert(handle ~= nil, "terminal phone calls retain their owner until handoff")
  local result = self._call:result(handle)
  if result == nil then
    return false
  end
  if self._entryOwner == "host" then
    self._result = result
  else
    self._call:release(handle)
    self._callHandle = nil
    self._mode = "list"
    self._panelTicks = nil
    self._held = nil
    self._choiceCursor = 0
  end
  return true
end

-- Names the menu call kind for one contact: rematch-capable contacts
-- inside their source window place invitation calls, every other contact
-- places an ordinary call. Owned here because the menu path is this
-- controller's entry; the engine resolves the program from the kind.
---@param contact string
---@return string kind
function PhoneController:_menuKind(contact)
  if
    isRematchCapable(self, contact)
    and TrainerPhonePrograms.eligible(contact, self._world, self._catalog --[[@as table<string, unknown>]])
  then
    return "rematch"
  end
  return "ordinary"
end

-- The detached menu frame in pixels for touch and presentation.
---@param kind string "menu" or "sort"
---@return table<string, integer>
local function menuFrame(kind)
  local spec = assert(MENU_FRAMES[kind], "phone context menus stay known")
  local height = (2 * spec.options + 3) * 8
  return { x = spec.x * 8, y = spec.y * 8, width = spec.width * 8, height = height }
end

---@param self PhoneController
---@param sequence string
local function playEffect(self, sequence)
  if self._effect ~= nil then
    self._effect(sequence)
  end
end

-- Opens the context menu over the selected row: the source hides the
-- list cursors and prints the menu tooltip behind it.
---@param self PhoneController
local function openMenu(self)
  self._mode = "menu"
  self._menuCursor = 0
  self._held = nil
  playEffect(self, DECIDE_SOUND)
end

-- Applies one automatic sort way as a view-only reordering: the source
-- weights order the session with stable ties, and the viewport returns
-- to the top. Saved order is untouched; manual move owns persistence.
---@param way integer 1-based automatic sort way
function PhoneController:_applySort(way)
  local decorated = {}
  for position, key in ipairs(self._order) do
    decorated[#decorated + 1] = { key = key, weight = self:_weight(key, way), position = position }
  end
  table.sort(decorated, function(first, second)
    if first.weight ~= second.weight then
      return first.weight < second.weight
    end
    return first.position < second.position
  end)
  local order = {}
  for _, entry in ipairs(decorated) do
    order[#order + 1] = entry.key
  end
  self._order = order
  self._selected = 0
  self._scroll = 0
  self._scrollAnim = nil
  self._mode = "list"
  self._held = nil
end

-- Places the grabbed contact at the cursor and persists the manual order
-- through the durable owner without touching contact identities.
function PhoneController:_dropManual()
  local grab = assert(self._grab, "manual placement grabs a contact first")
  local at = self._selected
  local key = self._order[grab + 1]
  assert(key ~= nil, "manual placement grabs a listed contact")
  table.remove(self._order, grab + 1)
  if at > #self._order then
    at = #self._order
  end
  table.insert(self._order, at + 1, key)
  local copy = {}
  for index, entry in ipairs(self._order) do
    copy[index] = entry
  end
  local setOrder = (self._state --[[@as table<string, unknown>]]).setContactOrder
  assert(type(setOrder) == "function", "manual moves persist through the companion state")
  setOrder(self._state, copy)
  self._grab = nil
  self._mode = "list"
  self._held = nil
  self:_moveSelection(at)
end

---@param x number
---@param y number
---@return integer? absolute row index under the row body, when the point overlaps a row
function PhoneController:_rowAt(x, y)
  if x < ROW_X0 or x >= ROW_X1 then
    return nil
  end
  local slot = math.floor((y - LIST_TOP) / ROW_HEIGHT)
  if slot < 0 or slot >= VISIBLE_ROWS then
    return nil
  end
  local absolute = self._scroll + slot
  if absolute < 0 or absolute >= #self._order then
    return nil
  end
  return absolute
end

-- Handles one tap release: ordinary row taps select and open the row's
-- context menu at once, scroll-strip taps walk, and manual arrows move
-- the move cursor. Row bodies never open menus in manual mode and
-- manual row bodies never select.
---@param x number
---@param y number
function PhoneController:_tap(x, y)
  if self._mode == "manual" then
    if x >= MOVE_STRIP_X0 and x < MOVE_STRIP_X1 then
      local slot = math.floor((y - LIST_TOP) / ROW_HEIGHT)
      if slot >= 0 and slot < VISIBLE_ROWS and self._scroll + slot < #self._order then
        local before = self._selected
        self:_moveSelection(self._scroll + slot)
        if self._selected ~= before then
          playEffect(self, DECIDE_SOUND)
        end
      end
    end
    return
  end
  if self._mode ~= "list" then
    return
  end
  local row = self:_rowAt(x, y)
  if row ~= nil then
    self:_moveSelection(row)
    openMenu(self)
    return
  end
  if x >= SCROLL_X0 and x < SCROLL_X1 then
    -- The scroll strip pages exactly like the edge keys.
    if y < LIST_TOP + (VISIBLE_ROWS * ROW_HEIGHT) / 2 then
      if self._scroll > 0 then
        self:_moveSelection(self._selected - VISIBLE_ROWS)
        playEffect(self, CURSOR_SOUND)
      end
    elseif self._scroll < self:_maxScroll() then
      self:_moveSelection(self._selected + VISIBLE_ROWS)
      playEffect(self, CURSOR_SOUND)
    end
  end
end

---@param event table<string, unknown>
function PhoneController:_handleList(event)
  if event.type == "navigate" and type(event.direction) == "string" then
    if event.direction == "up" or event.direction == "down" then
      local before = self._selected
      self:_moveSelection(self._selected + (event.direction == "down" and 1 or -1))
      if self._selected ~= before then
        playEffect(self, CURSOR_SOUND)
      end
    elseif event.direction == "left" then
      if self._scroll > 0 then
        self:_moveSelection(self._selected - VISIBLE_ROWS)
        playEffect(self, CURSOR_SOUND)
      end
    elseif event.direction == "right" then
      if self._scroll < self:_maxScroll() then
        self:_moveSelection(self._selected + VISIBLE_ROWS)
        playEffect(self, CURSOR_SOUND)
      end
    end
  elseif event.type == "confirm" then
    if #self._order > 0 then
      openMenu(self)
    end
  elseif event.type == "pointer_down" then
    if type(event.x) == "number" and type(event.y) == "number" then
      self._held = { id = event.pointerId, x = event.x, y = event.y }
    end
  elseif event.type == "pointer_up" then
    local held = self._held
    self._held = nil
    if
      held ~= nil
      and held.id == event.pointerId
      and type(event.x) == "number"
      and type(event.y) == "number"
      and math.abs(event.x - held.x --[[@as number]]) <= 8
      and math.abs(event.y - held.y --[[@as number]]) <= 8
    then
      self:_tap(event.x, event.y)
    end
  elseif event.type == "pointer_move" then
    local held = self._held
    if
      held ~= nil
      and held.id == event.pointerId
      and type(event.x) == "number"
      and type(event.y) == "number"
      and (
        math.abs(event.x - held.x --[[@as number]]) > 8 or math.abs(event.y - held.y --[[@as number]]) > 8
      )
    then
      self._held = nil
    end
  elseif event.type == "pointer_cancel" then
    self._held = nil
  elseif event.type == "pointer_scroll" then
    if event.direction == "up" then
      self:_moveSelection(self._selected - 1)
    elseif event.direction == "down" then
      self:_moveSelection(self._selected + 1)
    end
  end
end

---@param option integer zero-based main-menu option
function PhoneController:_chooseMain(option)
  if option == 0 then
    local contact = self._order[self._selected + 1]
    assert(contact ~= nil, "menu calls name the selected contact")
    self._callId = self._callId + 1
    self:_beginCall(contact, "outgoing", self:_menuKind(contact), "phone-menu-" .. self._callId, true)
    playEffect(self, DECIDE_SOUND)
  elseif option == 1 then
    self._mode = "sort"
    self._menuCursor = 0
    self._held = nil
    playEffect(self, DECIDE_SOUND)
  else
    self._mode = "list"
    self._held = nil
  end
end

-- The zero-based menu row under a tap release, if the tap lands on one.
---@param frame table<string, integer> the menu window frame
---@param x number
---@param y number
---@return integer? zero-based option row
local function menuRowAt(frame, x, y)
  if x < frame.x or x >= frame.x + frame.width then
    return nil
  end
  local slot = math.floor((y - frame.y - MENU_TEXT_TOP) / MENU_ROW_PITCH)
  local rowTop = frame.y + MENU_TEXT_TOP + MENU_ROW_PITCH * slot
  if slot < 0 or y < rowTop or y >= rowTop + MENU_TEXT_HEIGHT then
    return nil
  end
  return slot
end

-- The shared menu press window: captures the press, drops it when
-- either axis travels past 8px, and resolves a release to its menu row.
-- Clearing happens before the caller runs its choice, so a choice that
-- changes mode never fires a stale release. Never chooses actions.
---@param self PhoneController
---@param event table<string, unknown>
---@param kind string "menu" or "sort"
---@param count integer option count
---@return integer? zero-based option row
local function menuPointerRow(self, event, kind, count)
  if event.type == "pointer_down" then
    if type(event.x) == "number" and type(event.y) == "number" then
      self._held = { id = event.pointerId, x = event.x, y = event.y }
    end
    return nil
  end
  if event.type == "pointer_move" then
    local held = self._held
    if
      held ~= nil
      and held.id == event.pointerId
      and type(event.x) == "number"
      and type(event.y) == "number"
      and (
        math.abs(event.x - held.x --[[@as number]]) > 8 or math.abs(event.y - held.y --[[@as number]]) > 8
      )
    then
      self._held = nil
    end
    return nil
  end
  if event.type == "pointer_up" then
    local held = self._held
    self._held = nil
    if held == nil or held.id ~= event.pointerId then
      return nil
    end
    if type(event.x) ~= "number" or type(event.y) ~= "number" then
      return nil
    end
    if
      math.abs(event.x - held.x --[[@as number]]) > 8 or math.abs(event.y - held.y --[[@as number]]) > 8
    then
      return nil
    end
    local row = menuRowAt(menuFrame(kind), event.x, event.y)
    if row == nil or row < 0 or row >= count then
      return nil
    end
    return row
  end
  return nil
end

---@param event table<string, unknown>
function PhoneController:_handleMenu(event)
  if event.type == "navigate" and type(event.direction) == "string" then
    if event.direction == "up" then
      self._menuCursor = (self._menuCursor - 1) % #MENU_OPTIONS
      playEffect(self, CURSOR_SOUND)
    elseif event.direction == "down" then
      self._menuCursor = (self._menuCursor + 1) % #MENU_OPTIONS
      playEffect(self, CURSOR_SOUND)
    end
  elseif event.type == "confirm" then
    self:_chooseMain(self._menuCursor)
  elseif event.type == "cancel" then
    self._mode = "list"
    self._held = nil
    playEffect(self, CANCEL_SOUND)
  elseif event.type == "pointer_cancel" then
    self._mode = "list"
    self._held = nil
  elseif event.type == "pointer_down" or event.type == "pointer_move" then
    menuPointerRow(self, event, "menu", #MENU_OPTIONS)
  elseif event.type == "pointer_up" then
    local row = menuPointerRow(self, event, "menu", #MENU_OPTIONS)
    if row ~= nil then
      self:_chooseMain(row)
    end
  end
end

---@param option integer zero-based sort-menu option
function PhoneController:_chooseSort(option)
  if option <= 2 then
    self:_applySort(option + 1)
    playEffect(self, DECIDE_SOUND)
  elseif option == 3 then
    self._mode = "manual"
    self._grab = nil
    self._held = nil
    playEffect(self, DECIDE_SOUND)
  else
    self._mode = "menu"
    self._menuCursor = 1
    self._held = nil
  end
end

---@param event table<string, unknown>
function PhoneController:_handleSort(event)
  if event.type == "navigate" and type(event.direction) == "string" then
    if event.direction == "up" then
      self._menuCursor = (self._menuCursor - 1) % #SORT_OPTIONS
      playEffect(self, CURSOR_SOUND)
    elseif event.direction == "down" then
      self._menuCursor = (self._menuCursor + 1) % #SORT_OPTIONS
      playEffect(self, CURSOR_SOUND)
    end
  elseif event.type == "confirm" then
    self:_chooseSort(self._menuCursor)
  elseif event.type == "cancel" then
    self._mode = "menu"
    self._menuCursor = 1
    self._held = nil
    playEffect(self, CANCEL_SOUND)
  elseif event.type == "pointer_cancel" then
    self._mode = "menu"
    self._menuCursor = 1
    self._held = nil
  elseif event.type == "pointer_down" or event.type == "pointer_move" then
    menuPointerRow(self, event, "sort", #SORT_OPTIONS)
  elseif event.type == "pointer_up" then
    local row = menuPointerRow(self, event, "sort", #SORT_OPTIONS)
    if row ~= nil then
      self:_chooseSort(row)
    end
  end
end

---@param event table<string, unknown>
function PhoneController:_handleManual(event)
  if event.type == "navigate" and type(event.direction) == "string" then
    if event.direction == "up" or event.direction == "down" then
      local before = self._selected
      self:_moveSelection(self._selected + (event.direction == "down" and 1 or -1))
      if self._selected ~= before then
        playEffect(self, CURSOR_SOUND)
      end
    elseif event.direction == "left" then
      if self._scroll > 0 then
        self:_moveSelection(self._selected - VISIBLE_ROWS)
        playEffect(self, CURSOR_SOUND)
      end
    elseif event.direction == "right" then
      if self._scroll < self:_maxScroll() then
        self:_moveSelection(self._selected + VISIBLE_ROWS)
        playEffect(self, CURSOR_SOUND)
      end
    end
  elseif event.type == "confirm" then
    if self._grab == nil then
      self._grab = self._selected
      self._held = nil
    else
      self:_dropManual()
    end
  elseif event.type == "cancel" or event.type == "pointer_cancel" then
    self._grab = nil
    self._mode = "list"
    self._held = nil
  elseif event.type == "pointer_down" then
    if type(event.x) == "number" and type(event.y) == "number" then
      self._held = { id = event.pointerId, x = event.x, y = event.y }
    end
  elseif event.type == "pointer_up" then
    local held = self._held
    self._held = nil
    if
      held ~= nil
      and held.id == event.pointerId
      and type(event.x) == "number"
      and type(event.y) == "number"
      and math.abs(event.x - held.x --[[@as number]]) <= 8
      and math.abs(event.y - held.y --[[@as number]]) <= 8
    then
      self:_tap(event.x, event.y)
    end
  elseif event.type == "pointer_move" then
    local held = self._held
    if
      held ~= nil
      and held.id == event.pointerId
      and type(event.x) == "number"
      and type(event.y) == "number"
      and (
        math.abs(event.x - held.x --[[@as number]]) > 8 or math.abs(event.y - held.y --[[@as number]]) > 8
      )
    then
      self._held = nil
    end
  end
end

-- Routes one tick of call input to the owned engine: advancing edges
-- fast-forward the conversation, choice input answers the owed choice,
-- and cancellation hangs up. Navigation, pointer, and move input never
-- reach the list, the tabs, or the field behind the call.
---@param event table<string, unknown>
---@return table<string, unknown>? the engine edge, if the event carries one
function PhoneController:_callEdge(event)
  local handle = self._callHandle
  assert(handle ~= nil, "call input steps a live conversation")
  local shown = self._call:view(handle --[[@as table<string, unknown>]])
  local waiting = shown.stage == "choice" and type(shown.choices) == "table"
  if event.type == "advance" then
    return { advance = true }
  end
  if event.type == "confirm" then
    if waiting then
      local choices = shown.choices --[[@as string[] ]]
      local cursor = math.min(math.max(self._choiceCursor, 0), #choices - 1)
      return { choice = choices[cursor + 1] }
    end
    return { confirm = true }
  end
  if event.type == "cancel" then
    return { cancel = true }
  end
  if event.type == "navigate" and waiting and type(event.direction) == "string" then
    local choices = shown.choices --[[@as string[] ]]
    if event.direction == "up" then
      self._choiceCursor = (self._choiceCursor - 1) % #choices
    elseif event.direction == "down" then
      self._choiceCursor = (self._choiceCursor + 1) % #choices
    end
  end
  return nil
end

---@param event table<string, unknown>
function PhoneController:_handleCall(event)
  local handle = self._callHandle
  assert(handle ~= nil, "call input steps a live conversation")
  if event.type == "pointer_cancel" then
    self._held = nil
    return
  end
  local edge = self:_callEdge(event)
  if edge == nil then
    return
  end
  local ok, fault = pcall(function()
    self._call:step(handle --[[@as table<string, unknown>]], edge)
  end)
  if not ok then
    if Errors.is(fault) then
      error(fault, 0)
    end
    Errors.raise(ScriptErrors.FEATURE_UNAVAILABLE, "phone conversation failed: " .. tostring(fault), { stage = "call" })
  end
  local shown = self._call:view(handle --[[@as table<string, unknown>]])
  if shown.result ~= nil or shown.stage == "completed" then
    self:_finishCall()
  end
end

-- One fixed tick: exactly one owner consumes the batch. List, menu, sort,
-- and manual modes own their navigation; the live call owns everything
-- behind it. The panel timeline advances once per tick behind the call.
---@param uiInput table[]
function PhoneController:updateFixed(uiInput)
  assert(not self._disposed, "a disposed phone card steps nothing")
  assert(type(uiInput) == "table", "the phone card input must be an event list")
  -- The panel timeline advances once per completed tick behind the call,
  -- never on the choosing tick itself: a call chosen in this batch reads
  -- the closed cell until this tick settles.
  local panelRunning = self._panelTicks ~= nil
  for _, event in ipairs(uiInput) do
    -- A running viewport slide gates all key and touch input, mirroring
    -- the fly cursor-tween gate: the slide still settles below.
    if self._scrollAnim ~= nil then
      break
    end
    if type(event) == "table" and type(event.type) == "string" then
      local previousMode = self._mode
      local previousCallId = self._callId
      local previousCall = nil
      if previousMode == "call" and self._callHandle ~= nil then
        previousCall = self._call:view(self._callHandle --[[@as table<string, unknown>]])
      end
      local record = event --[[@as table<string, unknown>]]
      if self._mode == "call" then
        if self._result ~= nil then
          break
        end
        self:_handleCall(record)
      elseif self._mode == "menu" then
        self:_handleMenu(record)
      elseif self._mode == "sort" then
        self:_handleSort(record)
      elseif self._mode == "manual" then
        self:_handleManual(record)
      else
        self:_handleList(record)
      end
      if previousMode ~= "call" and self._mode == "call" then
        break
      end
      if self._callId ~= previousCallId then
        break
      end
      if previousCall ~= nil then
        if self._callHandle == nil or self._result ~= nil then
          break
        end
        local nextCall = self._call:view(self._callHandle --[[@as table<string, unknown>]])
        if previousCall.stage ~= nextCall.stage or previousCall.page ~= nextCall.page then
          break
        end
      end
    end
  end
  if panelRunning and self._panelTicks ~= nil then
    self._panelTicks = self._panelTicks --[[@as integer]] + 1
  end
  local anim = self._scrollAnim
  if anim ~= nil then
    anim.remaining = anim.remaining - 1
    if anim.remaining <= 0 then
      self._scrollAnim = nil
    end
  end
end

---@return table<string, unknown> the detached contact list projection
function PhoneController:_listView()
  local rows = {}
  for slot = 0, VISIBLE_ROWS - 1 do
    local key = self._order[self._scroll + slot + 1]
    if key ~= nil then
      rows[#rows + 1] = {
        contact = key,
        label = self._labels[key],
        class = self._classes[key],
        y = ROW_HEIGHT * slot + 2,
      }
    end
  end
  -- The running slide offset in pixels: the full row count times
  -- twenty-four at the start, decaying eight pixels per tick to the
  -- settled viewport. Positive slides the rows down, negative up.
  local pixels = 0
  local anim = self._scrollAnim
  if anim ~= nil then
    pixels = (anim.to > anim.from and 1 or -1) * anim.remaining * 8
  end
  return {
    rows = rows,
    selected = self._selected,
    scrollOffset = self._scroll,
    scrollPixels = pixels,
    firstBgColor = self._scroll % 2,
    manual = self._mode == "manual",
    total = #self._order,
    -- The source frames the selected row with four corner sprites and
    -- shows the scroll arrows only while the plain list owns the card:
    -- menus hide the corners, manual mode swaps them for move arrows.
    cursorVisible = self._mode == "list",
  }
end

---@return table<string, unknown>? the detached menu projection, if open
function PhoneController:_menuView()
  if self._mode == "menu" then
    local options = {}
    for index, option in ipairs(MENU_OPTIONS) do
      options[index] = option
    end
    return { options = options, cursor = self._menuCursor, frame = menuFrame("menu") }
  end
  if self._mode == "sort" then
    local options = {}
    for index, option in ipairs(SORT_OPTIONS) do
      options[index] = option
    end
    return {
      options = options,
      cursor = self._menuCursor,
      frame = menuFrame("sort"),
    }
  end
  return nil
end

---@return table<string, unknown>? the detached conversation projection, if live
function PhoneController:_callView()
  local handle = self._callHandle
  if handle == nil then
    return nil
  end
  local shown = self._call:view(handle --[[@as table<string, unknown>]])
  local detached = {}
  for key, value in pairs(shown) do
    detached[key] = value
  end
  detached.name = self._labels[
    shown.contact --[[@as string]]
  ]
  detached.className = self._classes[
    shown.contact --[[@as string]]
  ]
  detached.choiceCursor = self._choiceCursor
  return detached
end

---@return table<string, unknown>? the detached panel projection across the transition
function PhoneController:_panelView()
  local ticks = self._panelTicks
  if ticks == nil or ticks < 1 or ticks > #PANEL_TIMELINE then
    return nil
  end
  return { cell = PANEL_TIMELINE[ticks] }
end

-- The detached source view: list, context menu, call, panel, and
-- transition projections. Fresh tables per call; status performs no
-- mutation and never exposes live contact records.
---@return table<string, unknown>
function PhoneController:view()
  local panel = self:_panelView()
  local transition = nil
  if panel ~= nil then
    transition = { kind = "panel" }
  end
  -- The bottom bar names the open menu's prompt: the first tooltip
  -- behind the Call menu, the cursor-tracking sort tooltip behind the
  -- sort menu. The bar stays empty everywhere else.
  local tooltip = nil
  if self._mode == "menu" then
    tooltip = TOOLTIPS[1]
  elseif self._mode == "sort" then
    tooltip = TOOLTIPS[4 + self._menuCursor]
  end
  return {
    list = self:_listView(),
    contextMenu = self:_menuView(),
    call = self:_callView(),
    panel = panel,
    transition = transition,
    tooltip = tooltip,
  }
end

---@param skin integer
---@return table<string, unknown> the plan payload with resolved image paths
function PhoneController:_planContent(skin)
  local content = { skin = skin }
  local assets = self._assets
  if type(assets) ~= "table" then
    return content
  end
  local phone = (assets --[[@as table<string, unknown>]]).phone
  if type(phone) ~= "table" then
    return content
  end
  local section = phone --[[@as table<string, unknown>]]
  content.foreground = skinImage(section.foreground, skin)
  content.upper = skinImage(section.upper, skin)
  content.sprites = section.sprites
  local palettes = section.listPalette
  if type(palettes) == "table" then
    content.listPalette = (palettes --[[@as table<integer, table>]])[skin]
  end
  local panel = section.panel
  if type(panel) == "table" then
    local cells = panel --[[@as table<string, unknown>]]
    local closed = cells.closed or cells[PANEL_TIMELINE[1]]
    local open = cells.open or cells[PANEL_TIMELINE[2]]
    if
      type(closed) == "table" and type((closed --[[@as table<string, unknown>]]).image) == "string"
    then
      content.panelClosed = (closed --[[@as table<string, unknown>]]).image
    elseif type(closed) == "string" then
      content.panelClosed = closed
    end
    if
      type(open) == "table" and type((open --[[@as table<string, unknown>]]).image) == "string"
    then
      content.panelOpen = (open --[[@as table<string, unknown>]]).image
    elseif type(open) == "string" then
      content.panelOpen = open
    end
    if content.panelClosed == nil then
      content.panelClosed = firstImage(cells)
    end
    if content.panelOpen == nil then
      content.panelOpen = firstImage(cells)
    end
  end
  return content
end

-- The presentation snapshot: card identity and lifetime flags the shell
-- routes on, the detached view, and the published 256x192 plan. Fresh
-- tables per call; status performs no mutation.
---@return table<string, unknown>
function PhoneController:status()
  local preferences = (self._state --[[@as table<string, unknown>]]).readPreferences(self._state)
  assert(type(preferences) == "table", "the phone card reads its saved preferences")
  local skin = (preferences --[[@as table<string, unknown>]]).skin
  if type(skin) ~= "number" then
    skin = 0
  end
  local inCall = self._callHandle ~= nil and self._result == nil
  local inMenu = self._mode == "menu" or self._mode == "sort" or self._mode == "manual"
  local view = self:view()
  local content = self:_planContent(skin --[[@as integer]])
  local presentation = {
    width = 256,
    height = 192,
    content = content,
    render = renderPhonePresentation,
    renderInformation = renderPhoneInformation,
  }
  return {
    open = true,
    tab = "phone",
    busy = inCall,
    dismissible = not inCall,
    nestedCancel = inMenu or inCall,
    skin = skin,
    view = view,
    presentation = presentation,
  }
end

-- Reports the terminal call result to the owning shell or host. The read
-- is a peek: the result stays available until disposal, so both entry
-- paths observe the same result without consuming each other's outcome.
---@return table<string, unknown>?
function PhoneController:takeResult()
  local result = self._result
  if result == nil then
    return nil
  end
  local detached = {}
  for key, value in pairs(result) do
    detached[key] = value
  end
  return detached
end

-- Idempotent release of the logical lifetime: drops pointer capture,
-- releases the owned conversation exactly once, and discards any pending
-- result so disposal reports nothing further.
function PhoneController:dispose()
  if self._disposed then
    return
  end
  self._disposed = true
  self._held = nil
  self._panelTicks = nil
  local handle = self._callHandle
  self._callHandle = nil
  if handle ~= nil then
    pcall(function()
      self._call:release(handle)
    end)
  end
  self._result = nil
end

return PhoneController
