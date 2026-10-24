-- The gear setup card's skin selection: six fixed thumbnail cells on a
-- two-row grid, locked-cell confirmation as a no-op, a context menu that
-- spotlights its window plus the selected thumbnail, and exactly one saved
-- skin write at the confirmation boundary. Source fade and selection state
-- stay transient; the controller owns preference writes and nothing else.
-- Pure module: no love, no I/O.

---@class ConfigureController
---@field _state table<string, unknown> the borrowed durable companion owner
---@field _assets table<string, unknown> the borrowed compiled asset family
---@field _labels table<string, string> the CHANGE/QUIT menu labels
---@field _effect fun(sequence: string)? source UI sound effect boundary
---@field _cursor integer the focused skin, 0..5
---@field _menuCursor integer the focused menu option, 0 for CHANGE and 1 for QUIT
---@field _menuOpen boolean
---@field _disposed boolean
local ConfigureController = {}
ConfigureController.__index = ConfigureController

-- Six fixed cells: x48/128/208, y44/116 centers, each 48 wide and 40 tall.
local CELL_COLUMNS = { 24, 104, 184 }
local CELL_ROWS = { 24, 96 }
local CELL_WIDTH = 48
local CELL_HEIGHT = 40

local SURFACE_WIDTH = 256
local SURFACE_HEIGHT = 192

-- The context window sits by the selected cell at the source tile
-- origins (sContextMenuParam): the two right-column cells anchor their
-- right edge, the rest their left edge. The window frames two sixteen-
-- pixel text rows exactly like the shared list menu.
local MENU_ORIGINS = {
  { x = 10, y = 2, right = false },
  { x = 20, y = 2, right = false },
  { x = 22, y = 2, right = true },
  { x = 10, y = 11, right = false },
  { x = 20, y = 11, right = false },
  { x = 22, y = 11, right = true },
}
local MENU_ROW_PITCH = 24
local MENU_TEXT_TOP = 8
local MENU_TEXT_HEIGHT = 16
local MENU_FRAME_ROWS = 7

---@param skin integer
---@param labels table<string, string>
---@return table<string, integer> the menu window rectangle
local function menuRect(skin, labels)
  local origin = assert(MENU_ORIGINS[skin + 1], "the setup menu anchors every skin")
  local width = (math.max(#labels.change, #labels.quit) + 2) * 8
  local height = MENU_FRAME_ROWS * 8
  local x = origin.x * 8
  if origin.right then
    x = x - width
  end
  return { x = x, y = origin.y * 8, width = width, height = height }
end

---@param menu table<string, integer> the menu window rectangle
---@param index integer zero-based option row
---@return table<string, integer> the row touch rectangle
local function menuRowRect(menu, index)
  return {
    x = menu.x,
    y = menu.y + MENU_TEXT_TOP + MENU_ROW_PITCH * index,
    width = menu.width,
    height = MENU_TEXT_HEIGHT,
  }
end

---@param skin integer
---@return table<string, integer> the fixed cell rectangle
local function cellRect(skin)
  local row = math.floor(skin / 3)
  local column = skin % 3
  return { x = CELL_COLUMNS[column + 1], y = CELL_ROWS[row + 1], width = CELL_WIDTH, height = CELL_HEIGHT }
end

---@param rect table<string, integer>
---@return table<string, integer>
local function copyRect(rect)
  return { x = rect.x, y = rect.y, width = rect.width, height = rect.height }
end

-- The pieces of one rectangle outside one cut, in integer arithmetic: top
-- and bottom bands first, then left and right middles, so the first piece
-- is always the upper band. Non-overlapping and exact, so dim coverage
-- never double-dims or leaks.
---@param rect table<string, integer>
---@param cut table<string, integer>
---@return table<string, integer>[]
local function subtractRect(rect, cut)
  local innerX0 = math.max(rect.x, cut.x)
  local innerY0 = math.max(rect.y, cut.y)
  local innerX1 = math.min(rect.x + rect.width, cut.x + cut.width)
  local innerY1 = math.min(rect.y + rect.height, cut.y + cut.height)
  if innerX0 >= innerX1 or innerY0 >= innerY1 then
    return { copyRect(rect) }
  end
  local pieces = {}
  if innerY0 > rect.y then
    pieces[#pieces + 1] = { x = rect.x, y = rect.y, width = rect.width, height = innerY0 - rect.y }
  end
  if innerY1 < rect.y + rect.height then
    pieces[#pieces + 1] = { x = rect.x, y = innerY1, width = rect.width, height = rect.y + rect.height - innerY1 }
  end
  if innerX0 > rect.x then
    pieces[#pieces + 1] = { x = rect.x, y = innerY0, width = innerX0 - rect.x, height = innerY1 - innerY0 }
  end
  if innerX1 < rect.x + rect.width then
    pieces[#pieces + 1] =
      { x = innerX1, y = innerY0, width = rect.x + rect.width - innerX1, height = innerY1 - innerY0 }
  end
  return pieces
end

-- The spotlight behind an open menu: everything dimmed except the menu
-- window and the selected thumbnail.
---@param menu table<string, integer>
---@param selected table<string, integer>
---@return table<string, integer>[]
local function spotlightRects(menu, selected)
  local rects = { { x = 0, y = 0, width = SURFACE_WIDTH, height = SURFACE_HEIGHT } }
  for _, cut in ipairs({ menu, selected }) do
    local nextRects = {}
    for _, rect in ipairs(rects) do
      for _, piece in ipairs(subtractRect(rect, cut)) do
        nextRects[#nextRects + 1] = piece
      end
    end
    rects = nextRects
  end
  return rects
end

---@param unlocked table<integer, integer>
---@param skin integer
---@return boolean
local function isUnlocked(unlocked, skin)
  for _, entry in ipairs(unlocked) do
    if entry == skin then
      return true
    end
  end
  return false
end

---@param skin integer
---@return boolean
local function isSkin(skin)
  return type(skin) == "number" and skin % 1 == 0 and skin >= 0 and skin <= 5
end

---@param assets table<string, unknown>
---@return integer[] the source palette in identity order
local function sourceSkins(assets)
  local compiled = assert(assets.skins, "the setup card reads its compiled source skins")
  assert(type(compiled) == "table", "the setup card borrows its compiled source palette")
  local skins = {}
  for key, value in pairs(compiled) do
    local skin = value
    if type(value) ~= "number" then
      skin = key
    end
    assert(isSkin(skin), "compiled setup skins carry source identities")
    skins[#skins + 1] = skin --[[@as integer]]
  end
  table.sort(skins)
  assert(#skins == 6, "the setup card uses all six compiled source skins")
  for index, skin in ipairs(skins) do
    assert(skin == index - 1, "the compiled setup palette has each source skin once")
  end
  return skins
end

-- The two-row directional grid behind the six cells: left and right
-- wrap within their row, up and down cross to the same column of the
-- other row (source sCursorButtons: every horizontal edge stays in its
-- row, every vertical edge toggles rows). A fixed exploration from any
-- cell reaches every cell.
---@param cursor integer
---@param direction string
---@return integer
local function stepCursor(cursor, direction)
  local row = math.floor(cursor / 3)
  local column = cursor % 3
  if direction == "right" then
    return row * 3 + ((column + 1) % 3)
  elseif direction == "left" then
    return row * 3 + ((column + 2) % 3)
  elseif direction == "down" or direction == "up" then
    return ((row + 1) % 2) * 3 + column
  end
  return cursor
end

---@class ConfigureController.Options
---@field state table<string, unknown> the durable companion owner
---@field assets table<string, unknown> the borrowed compiled asset family
---@field labels table<string, string> the CHANGE/QUIT menu labels in message-bank order
---@field effect fun(sequence: string)? source UI sound effect boundary

---@param opts ConfigureController.Options
---@return ConfigureController
function ConfigureController.new(opts)
  assert(type(opts) == "table", "the setup card requires its options")
  assert(
    type(opts.state) == "table"
      and type(opts.state.readPreferences) == "function"
      and type(opts.state.setPreference) == "function",
    "the setup card requires the durable companion owner"
  )
  assert(type(opts.assets) == "table", "the setup card requires its compiled asset family")
  assert(
    type(opts.labels) == "table"
      and type(opts.labels.change) == "string"
      and opts.labels.change ~= ""
      and type(opts.labels.quit) == "string"
      and opts.labels.quit ~= "",
    "the setup card names its CHANGE/QUIT menu labels"
  )
  assert(opts.effect == nil or type(opts.effect) == "function", "the setup sound boundary must be a function")
  local preferences = opts.state:readPreferences()
  assert(type(preferences) == "table", "the setup card reads its saved preferences")
  local unlocked = sourceSkins(opts.assets)
  local cursor = preferences.skin
  if not isSkin(cursor) or not isUnlocked(unlocked, cursor) then
    cursor = unlocked[1]
  end
  assert(isSkin(cursor), "the setup cursor starts on a valid skin")
  return setmetatable({
    _state = opts.state,
    _assets = opts.assets,
    _labels = { change = opts.labels.change, quit = opts.labels.quit },
    _effect = opts.effect,
    _cursor = cursor,
    _menuCursor = 0,
    _menuOpen = false,
    _disposed = false,
  }, ConfigureController)
end

---@return table<integer, integer>
function ConfigureController:_unlocked()
  return sourceSkins(self._assets --[[@as table<string, unknown>]])
end

-- The source UI tones on the setup card: cursor motion, menu
-- decisions, and cancellation.
local CURSOR_SOUND = "SEQ_SE_GS_GEARCURSOR"
local DECIDE_SOUND = "SEQ_SE_GS_GEARDECIDE"
local CANCEL_SOUND = "SEQ_SE_GS_GEARCANCEL"

---@param sequence string
function ConfigureController:_play(sequence)
  if self._effect ~= nil then
    self._effect(sequence)
  end
end

-- Opens the context menu over the focused cell: the cursor restarts on
-- CHANGE, matching the source spawn.
function ConfigureController:_openMenu()
  self._menuCursor = 0
  self._menuOpen = true
  self:_play(DECIDE_SOUND)
end

-- Chooses the focused menu option: CHANGE commits the focused skin,
-- QUIT returns without writing.

-- One fixed tick: directional input walks the six grid positions while no
-- menu is open; confirming or tapping an unlocked cell opens its CHANGE/
-- QUIT context menu; confirming CHANGE commits exactly once while QUIT,
-- cancelling, and outside taps close it without writing; every motion
-- and decision plays its source tone through the sound boundary.
---@param uiInput table[]
function ConfigureController:updateFixed(uiInput)
  assert(not self._disposed, "a disposed setup card steps nothing")
  assert(type(uiInput) == "table", "the setup card input must be an event list")
  for _, event in ipairs(uiInput) do
    if type(event) == "table" and type(event.type) == "string" then
      self:_handle(event)
    end
  end
end

---@param event table<string, unknown>
function ConfigureController:_handle(event)
  if event.type == "navigate" and type(event.direction) == "string" then
    if self._menuOpen then
      if event.direction == "up" or event.direction == "down" then
        self._menuCursor = (self._menuCursor + 1) % 2
        self:_play(CURSOR_SOUND)
      end
    else
      local moved = stepCursor(self._cursor, event.direction)
      if moved ~= self._cursor then
        self._cursor = moved
        self:_play(CURSOR_SOUND)
      end
    end
  elseif event.type == "confirm" then
    if self._menuOpen then
      if self._menuCursor == 0 then
        self._state:setPreference("skin", self._cursor)
        self:_play(DECIDE_SOUND)
      end
      self._menuOpen = false
    elseif isUnlocked(self:_unlocked(), self._cursor) then
      self:_openMenu()
    end
  elseif event.type == "cancel" then
    if self._menuOpen then
      self._menuOpen = false
      self:_play(CANCEL_SOUND)
    end
  elseif event.type == "pointer_down" and type(event.x) == "number" and type(event.y) == "number" then
    if self._menuOpen then
      local menu = menuRect(self._cursor, self._labels)
      for index = 0, 1 do
        local row = menuRowRect(menu, index)
        if event.x >= row.x and event.x < row.x + row.width and event.y >= row.y and event.y < row.y + row.height then
          self._menuCursor = index
          if index == 0 then
            self._state:setPreference("skin", self._cursor)
            self:_play(DECIDE_SOUND)
          end
          self._menuOpen = false
          return
        end
      end
    else
      for skin = 0, 5 do
        local rect = cellRect(skin)
        if
          event.x >= rect.x
          and event.x < rect.x + rect.width
          and event.y >= rect.y
          and event.y < rect.y + rect.height
        then
          -- A tap on a locked cell settles nothing and never moves the
          -- cursor; a tap on an unlocked cell focuses it and opens its
          -- menu at once, matching the source touch path.
          if isUnlocked(self:_unlocked(), skin) then
            self._cursor = skin
            self:_openMenu()
          end
          return
        end
      end
    end
  end
end

-- The detached selection view: all six fixed thumbnail cells at their
-- source rectangles, the semantic selected skin, and, while the menu is
-- open, the per-skin window rectangle, its CHANGE/QUIT options with the
-- focused option, plus the exact spotlight coverage. Fresh tables per
-- call.
---@return table<string, unknown>
function ConfigureController:view()
  local thumbnails = {}
  for skin = 0, 5 do
    thumbnails[skin] = cellRect(skin)
  end
  local out = {
    thumbnails = thumbnails,
    selectedSkin = self._cursor,
    menu = nil,
    menuOptions = nil,
    spotlight = nil,
  }
  if self._menuOpen then
    local menu = menuRect(self._cursor, self._labels)
    out.menu = menu
    out.menuOptions = {
      labels = { self._labels.change, self._labels.quit },
      cursor = self._menuCursor,
    }
    out.spotlight = spotlightRects(menu, cellRect(self._cursor))
  end
  return out
end

-- The presentation snapshot: the card identity and lifetime flags the shell
-- routes on, the cursor and menu state, and the detached selection view.
-- Fresh tables per call; status performs no mutation.
---@return table<string, unknown>
function ConfigureController:status()
  return {
    open = true,
    tab = "configure",
    busy = false,
    dismissible = true,
    nestedCancel = self._menuOpen,
    cursor = self._cursor,
    menuOpen = self._menuOpen,
    cursorFrozen = self._menuOpen,
    view = self:view(),
  }
end

-- The setup card never closes itself: the shell owns dismissal.
---@return nil
function ConfigureController:takeResult()
  return nil
end

-- Idempotent release of the logical lifetime: closes any open menu and
-- reports nothing further.
function ConfigureController:dispose()
  self._menuOpen = false
  self._disposed = true
end

return ConfigureController
