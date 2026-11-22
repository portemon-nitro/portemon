-- Transactional search criteria, ordered filtering, editor focus graphs,
-- and nonuniform slider recurrences for the browser. The controller owns
-- pages and input priority; this helper owns only the criteria record,
-- its editor backup discipline, and the ordered membership intersection.
-- Pure policy: no love, no I/O, no history mutation.

local Errors = require("libs.errors.src.Errors")

---@class PokedexSearch
---@field _catalog table<string, unknown> borrowed generated catalog
---@field _dex table<string, unknown> borrowed authoritative knowledge owner
---@field _mode string active dex mode for membership
---@field _profileName string frozen measurement profile for ordered sorts
---@field _nationalUnlocked boolean whether the kanto area choice is enabled
---@field _criteria table<string, unknown> live criteria record
---@field _editor table<string, unknown>? open editor transaction
---@field _sliderOpCount integer accepted arrow operations in the current hold
---@field _sliderAnim integer remaining authored arrow animation ticks
---@field _drag table<string, unknown>? in-progress slider handle drag
local PokedexSearch = {}
PokedexSearch.__index = PokedexSearch

PokedexSearch.ORDERS = { "numerical", "alphabetical", "heaviest", "lightest", "tallest", "shortest" }
PokedexSearch.MEASUREMENT_ORDERS = { heaviest = true, lightest = true, tallest = true, shortest = true }
PokedexSearch.SLIDER_MIN = 0
PokedexSearch.SLIDER_MAX = 152
PokedexSearch.SLIDER_OP_CAP = 24
-- The authored arrow animation each accepted step waits out before the
-- next operation may count; the step itself applies on acceptance.
PokedexSearch.SLIDER_ANIM_TICKS = 10
PokedexSearch.CRITERIA = { "order", "letter", "type", "height", "weight", "area", "shape" }

-- Source DpadMenuBox graphs (pokedex_input.c). Each node names its native
-- center, its four directional links, and the directions whose link carries
-- the 0x80 return flag. Node indices are the native dpad indices.
local function node(x, y, up, down, left, right, ret)
  return { x = x, y = y, up = up, down = down, left = left, right = right, ret = ret }
end

PokedexSearch.DIRECTION_KEYS = { up = "up", down = "down", left = "left", right = "right" }
local OPPOSITE = { up = "down", down = "up", left = "right", right = "left" }

PokedexSearch.FOCUS = {
  menu = {
    names = { "order", "letter", "type", "height", "weight", "area", "shape", "reset", "run", "back" },
    nodes = {
      node(172, 16, 0, 1, 0, 0),
      node(92, 40, 0, 2, 1, 6),
      node(116, 64, 1, 3, 2, 6),
      node(112, 88, 2, 4, 3, 6),
      node(136, 112, 3, 5, 4, 4),
      node(84, 136, 4, 8, 5, 5, { down = true }),
      node(224, 72, 0, 4, 1, 6, { left = true }),
      node(40, 176, 5, 7, 7, 8),
      node(128, 176, 5, 8, 7, 9),
      node(216, 176, 5, 9, 8, 9),
    },
  },
  order = {
    cells = 6,
    ok = 6,
    cancel = 7,
    nodes = {
      node(68, 56, 6, 2, 1, 1),
      node(188, 56, 7, 3, 0, 0),
      node(68, 88, 0, 4, 3, 3),
      node(188, 88, 1, 5, 2, 2),
      node(68, 120, 2, 6, 5, 5),
      node(188, 120, 3, 7, 4, 4),
      node(40, 176, 4, 0, 7, 7),
      node(216, 176, 5, 1, 6, 6),
    },
  },
  area = {
    cells = 4,
    ok = 4,
    cancel = 5,
    nodes = {
      node(76, 72, 4, 2, 1, 1),
      node(180, 72, 5, 3, 0, 0),
      node(76, 128, 0, 4, 3, 3),
      node(180, 128, 1, 5, 2, 2),
      node(40, 176, 2, 0, 5, 5),
      node(216, 176, 3, 1, 4, 4),
    },
  },
  height = {
    cells = 2,
    ok = 2,
    cancel = 3,
    nodes = {
      node(52, 60, 2, 1, 0, 0),
      node(204, 132, 0, 2, 1, 1, { down = true }),
      node(40, 176, 1, 0, 3, 3),
      node(216, 176, 1, 0, 2, 2),
    },
  },
  weight = {
    cells = 2,
    ok = 2,
    cancel = 3,
    nodes = {
      node(52, 60, 2, 1, 0, 0),
      node(204, 132, 0, 2, 1, 1, { down = true }),
      node(40, 176, 1, 0, 3, 3),
      node(216, 176, 1, 0, 2, 2),
    },
  },
  shape = {
    cells = 15,
    ok = 15,
    cancel = 16,
    nodes = {
      node(32, 56, 15, 5, 4, 1),
      node(80, 56, 15, 6, 0, 2),
      node(128, 56, 15, 7, 1, 3),
      node(176, 56, 16, 8, 2, 4),
      node(224, 56, 16, 9, 3, 0),
      node(32, 96, 0, 10, 9, 6),
      node(80, 96, 1, 11, 5, 7),
      node(128, 96, 2, 12, 6, 8),
      node(176, 96, 3, 13, 7, 9),
      node(224, 96, 4, 14, 8, 5),
      node(32, 136, 5, 15, 14, 11),
      node(80, 136, 6, 15, 10, 12),
      node(128, 136, 7, 15, 11, 13),
      node(176, 136, 8, 16, 12, 14),
      node(224, 136, 9, 16, 13, 10),
      node(40, 176, 10, 0, 16, 16),
      node(216, 176, 14, 4, 15, 15),
    },
  },
  type = {
    cells = 18,
    ok = 18,
    cancel = 19,
    nodes = {
      node(32, 48, 18, 4, 3, 1),
      node(96, 48, 18, 5, 0, 2),
      node(160, 48, 19, 6, 1, 3),
      node(224, 48, 19, 7, 2, 0),
      node(32, 72, 0, 8, 7, 5),
      node(96, 72, 1, 9, 4, 6),
      node(160, 72, 2, 10, 5, 7),
      node(224, 72, 3, 11, 6, 4),
      node(32, 96, 4, 12, 11, 9),
      node(96, 96, 5, 13, 8, 10),
      node(160, 96, 6, 14, 9, 11),
      node(224, 96, 7, 15, 10, 8),
      node(32, 120, 8, 16, 15, 13),
      node(96, 120, 9, 17, 12, 14),
      node(160, 120, 10, 19, 13, 15),
      node(224, 120, 11, 19, 14, 12),
      node(32, 144, 12, 18, 17, 17),
      node(96, 144, 13, 18, 16, 16),
      node(40, 176, 16, 0, 19, 19),
      node(216, 176, 15, 3, 18, 18),
    },
  },
  letter = {
    cells = 27,
    ok = 27,
    cancel = 28,
    nodes = {
      node(32, 48, 27, 7, 6, 1),
      node(64, 48, 27, 8, 0, 2),
      node(96, 48, 27, 9, 1, 3),
      node(128, 48, 27, 10, 2, 4),
      node(160, 48, 28, 11, 3, 5),
      node(192, 48, 28, 12, 4, 6),
      node(224, 48, 28, 13, 5, 0),
      node(32, 80, 0, 14, 13, 8),
      node(64, 80, 1, 15, 7, 9),
      node(96, 80, 2, 16, 8, 10),
      node(128, 80, 3, 17, 9, 11),
      node(160, 80, 4, 18, 10, 12),
      node(192, 80, 5, 19, 11, 13),
      node(224, 80, 6, 20, 12, 7),
      node(32, 112, 7, 21, 20, 15),
      node(64, 112, 8, 22, 14, 16),
      node(96, 112, 9, 23, 15, 17),
      node(128, 112, 10, 24, 16, 18),
      node(160, 112, 11, 25, 17, 19),
      node(192, 112, 12, 28, 18, 20),
      node(224, 112, 13, 26, 19, 14),
      node(32, 144, 14, 27, 26, 22),
      node(64, 144, 15, 27, 21, 23),
      node(96, 144, 16, 27, 22, 24),
      node(128, 144, 17, 27, 23, 25),
      node(160, 144, 18, 28, 24, 26),
      node(224, 144, 20, 28, 25, 21),
      node(40, 176, 21, 0, 28, 28),
      node(216, 176, 26, 6, 27, 27),
    },
  },
}

-- Returning from OK/cancel lands in the letter column the cursor left
-- (OnSearchNameGridMove).
local function letterHooks(state, source, target)
  if source ~= 27 and source ~= 28 then
    return
  end
  local column = state.column
  if type(column) ~= "number" then
    return
  end
  local nodes = PokedexSearch.FOCUS.letter.nodes
  local columnX = nodes[column + 1].x
  local first, last, step = 0, 26, 1
  if target == 21 or target == 26 then
    first, last, step = 26, 0, -1
  elseif target ~= 0 and target ~= 6 then
    return
  end
  for index = first, last, step do
    if nodes[index + 1].x == columnX then
      state.node = index
      state.returnInput = source
      return
    end
  end
end

-- Type rows remember which half-row the cursor came from
-- (OnSearchTypeGridMove).
local function typeHooks(state, source, target)
  local column = state.column
  if type(column) ~= "number" then
    column = 0
  end
  if source == 18 then
    if target == 0 then
      if column >= 16 and column <= 17 then
        column = column % 4
      elseif column < 0 or column > 1 then
        column = 0
      end
      state.node = column
      state.returnInput = 18
    elseif target == 16 then
      if column >= 0 and column <= 1 then
        column = column + 16
      elseif column < 16 or column > 17 then
        column = 16
      end
      state.node = column
      state.returnInput = 18
    end
  elseif source == 19 then
    if target == 3 then
      if column >= 14 and column <= 15 then
        column = column % 4
      elseif column < 2 or column > 3 then
        column = 3
      end
      state.node = column
      state.returnInput = 19
    elseif target == 15 then
      if column >= 2 and column <= 3 then
        column = column + 12
      elseif column < 14 or column > 15 then
        column = 15
      end
      state.node = column
      state.returnInput = 19
    end
  end
end

-- Shape rows remember which five-column block the cursor came from
-- (OnSearchFormGridMove).
local function shapeHooks(state, source, target)
  local column = state.column
  if type(column) ~= "number" then
    column = 0
  end
  if source == 15 then
    if target == 0 then
      if column >= 0 and column <= 2 then
        column = column
      elseif column >= 10 and column <= 12 then
        column = column % 5
      else
        column = 0
      end
      state.node = column
      state.returnInput = 15
    elseif target == 10 then
      if column >= 0 and column <= 2 then
        column = column + 10
      elseif column < 10 or column > 12 then
        column = 10
      end
      state.node = column
      state.returnInput = 15
    end
  elseif source == 16 then
    if target == 4 then
      if column >= 3 and column <= 4 then
        column = column
      elseif column >= 13 and column <= 14 then
        column = column % 5
      else
        column = 4
      end
      state.node = column
      state.returnInput = 16
    elseif target == 14 then
      if column >= 3 and column <= 4 then
        column = column + 10
      elseif column < 13 or column > 14 then
        column = 14
      end
      state.node = column
      state.returnInput = 16
    end
  end
end

PokedexSearch.FOCUS.letter.hooks = letterHooks
PokedexSearch.FOCUS.type.hooks = typeHooks
PokedexSearch.FOCUS.shape.hooks = shapeHooks

-- Source dpad graphs read the cell the cursor stood on before it entered
-- OK or cancel (the native prevGridInput), so `state.column` names the last
-- focus cell and survives the move out of it.
---@param state table<string, unknown> focus state under traversal
---@param graph table<string, unknown> focus graph under traversal
---@param direction string up/down/left/right
---@param enabled (fun(nodeIndex: integer): boolean)|nil node enable predicate
---@return boolean moved whether the focus changed
function PokedexSearch.moveFocus(graph, state, direction, enabled)
  local nodes = assert(graph.nodes, "focus graphs carry their nodes")
  local key = assert(PokedexSearch.DIRECTION_KEYS[direction], "focus directions name a dpad direction")
  local current = assert(state.node, "focus state carries its node")
  local row = assert(nodes[current + 1], "focus state addresses its node")
  local link = assert(row[key], "focus nodes carry their directional links")
  local target = link
  local ret = row.ret
  if type(ret) == "table" and ret[key] == true then
    target = state.returnInput or link
  end
  local landed = true
  local function isEnabled(index)
    if type(enabled) == "function" then
      return enabled(index) == true
    end
    return true
  end
  while isEnabled(target) ~= true do
    landed = false
    local walk = assert(nodes[target + 1], "focus links address their node")
    local nextIndex = assert(walk[key], "disabled focus nodes carry their links")
    if nextIndex == target or nextIndex == current then
      target = current
      break
    end
    target = nextIndex
  end
  if target == current then
    return false
  end
  local back = nodes[target + 1].ret
  if landed and type(back) == "table" and back[OPPOSITE[key]] == true then
    state.returnInput = current
  else
    state.returnInput = nil
  end
  local source = current
  state.node = target
  if type(graph.cells) == "number" and source < graph.cells then
    state.column = source
  end
  local hooks = graph.hooks
  if type(hooks) == "function" then
    hooks(state, source, target)
  end
  return true
end

local function fail(message, context)
  Errors.raise("POKEDEX_INVALID", message, context)
end

---@param value unknown
---@param what string
---@return table<string, unknown>
local function checkTable(value, what)
  if type(value) ~= "table" then
    fail("search needs " .. what, {})
  end
  assert(type(value) == "table", "search reads its borrowed state")
  return value
end

---@param value unknown
---@return table<string, unknown> detached copy
local function copyCriteria(value)
  local source = checkTable(value, "a criteria record")
  local height = checkTable(source.height, "height bounds")
  local weight = checkTable(source.weight, "weight bounds")
  return {
    order = source.order,
    letter = source.letter,
    type1 = source.type1,
    type2 = source.type2,
    shape = source.shape,
    area = source.area,
    height = { min = height.min, max = height.max },
    weight = { min = weight.min, max = weight.max },
  }
end

---@return table<string, unknown> fresh default criteria
local function defaultCriteria()
  return {
    order = "numerical",
    letter = nil,
    type1 = nil,
    type2 = nil,
    shape = nil,
    area = nil,
    height = { min = 0, max = 152 },
    weight = { min = 0, max = 152 },
  }
end

---@param catalog table<string, unknown>
local function checkCatalog(catalog)
  checkTable(catalog, "the generated catalog")
  assert(type(catalog) == "table", "search reads its borrowed catalog")
  for _, field in ipairs({ "dexOrders", "sortOrders", "measurementProfiles", "criteria", "sliderSteps", "species" }) do
    if type(catalog[field]) ~= "table" then
      fail("search catalog is missing its " .. field, {})
    end
  end
end

---@param args { catalog: table<string, unknown>, dex: table<string, unknown> }
---@return PokedexSearch
function PokedexSearch.new(args)
  if type(args) ~= "table" then
    fail("search needs a construction record", {})
  end
  assert(type(args) == "table", "search reads its construction record")
  checkCatalog(args.catalog)
  if type(args.dex) ~= "table" then
    fail("search needs the knowledge owner", {})
  end
  local self = setmetatable({
    _catalog = args.catalog,
    _dex = args.dex,
    _mode = "national",
    _profileName = "base",
    _nationalUnlocked = false,
    _criteria = defaultCriteria(),
    _editor = nil,
    _sliderOpCount = 0,
    _sliderAnim = 0,
    _drag = nil,
  }, PokedexSearch)
  return self
end

---@param context { mode?: string, profileName?: string, nationalUnlocked?: boolean }
function PokedexSearch:setContext(context)
  if type(context) ~= "table" then
    fail("search context must be a record", {})
  end
  assert(type(context) == "table", "search reads its context record")
  if context.mode ~= nil then
    if context.mode ~= "johto" and context.mode ~= "national" then
      fail("search context names an unknown mode", { mode = context.mode })
    end
    self._mode = context.mode
  end
  if context.profileName ~= nil then
    self._profileName = context.profileName
  end
  if context.nationalUnlocked ~= nil then
    self._nationalUnlocked = context.nationalUnlocked == true
  end
end

function PokedexSearch:reset()
  self._criteria = defaultCriteria()
  self._editor = nil
  self._sliderOpCount = 0
  self._sliderAnim = 0
  self._drag = nil
end

---@return table<string, unknown> detached criteria copy
function PokedexSearch:criteria()
  return copyCriteria(self._criteria)
end

---@return boolean
function PokedexSearch:isEditorOpen()
  return self._editor ~= nil
end

---@return string?
function PokedexSearch:editorKind()
  if self._editor == nil then
    return nil
  end
  return self._editor.kind
end

---@param kind string
function PokedexSearch:openEditor(kind)
  local known = false
  for _, name in ipairs(PokedexSearch.CRITERIA) do
    if name == kind then
      known = true
    end
  end
  if not known then
    fail("search names an unknown editor", { editor = kind })
  end
  local backup = copyCriteria(self._criteria)
  local editor = { kind = kind, backup = backup, focus = nil, node = 0, returnInput = nil, column = nil }
  if kind == "type" then
    local pending = {}
    if self._criteria.type1 ~= nil then
      pending[#pending + 1] = self._criteria.type1
    end
    if self._criteria.type2 ~= nil then
      pending[#pending + 1] = self._criteria.type2
    end
    editor.types = pending
  elseif kind == "area" then
    editor.areaChoice = self._criteria.area
  elseif kind == "height" or kind == "weight" then
    -- The native slider grids start on the upper (maximum) handle.
    editor.endpoint = "max"
    self._sliderOpCount = 0
    self._sliderAnim = 0
    self._drag = nil
  end
  self._editor = editor
  if kind ~= "height" and kind ~= "weight" then
    -- Every native option grid is created at initial position 0: the
    -- first projected cell, never the currently stored criterion.
    local options = self:editorOptions(kind)
    assert(type(options) == "table" and #options > 0, "search editors publish at least one option")
    editor.focus = options[1]
  end
  editor.column = 0
end

---@param editor table<string, unknown> open editor under sync
---@param options string[]? option keys behind an option editor
local function syncEditorFocus(editor, options)
  local graph = assert(PokedexSearch.FOCUS[editor.kind], "search editors carry a source focus graph")
  local nodeIndex = assert(editor.node, "search editors carry their focus node")
  if editor.kind == "height" or editor.kind == "weight" then
    if nodeIndex == 0 then
      editor.endpoint = "max"
    elseif nodeIndex == 1 then
      editor.endpoint = "min"
    end
    return
  end
  if nodeIndex < graph.cells then
    assert(type(options) == "table", "option editors carry their option keys")
    local option = options[nodeIndex + 1]
    assert(type(option) == "string", "search focus cells resolve their option")
    editor.focus = option
  end
end

-- Moves the open editor focus through the source 2D dpad graph. A self
-- neighbour stays silent and leaves the cursor in place.
---@param direction string up/down/left/right
---@return boolean moved whether the focus changed
function PokedexSearch:moveEditorFocus(direction)
  if self._editor == nil then
    fail("search moves focus inside an open editor", {})
  end
  assert(type(self._editor) == "table", "search reads its open editor")
  local kind = self._editor.kind
  local graph = assert(PokedexSearch.FOCUS[kind], "search editors carry a source focus graph")
  local moved = PokedexSearch.moveFocus(graph, self._editor, direction, function(nodeIndex)
    return kind ~= "area" or nodeIndex ~= 1 or self._nationalUnlocked == true
  end)
  if moved ~= true then
    return false
  end
  if kind ~= "height" and kind ~= "weight" then
    syncEditorFocus(self._editor, self:editorOptions(kind))
  else
    syncEditorFocus(self._editor, nil)
  end
  return true
end

-- Sets the open editor focus directly from a touch hitbox index.
---@param nodeIndex integer zero-based source dpad node
function PokedexSearch:focusNode(nodeIndex)
  if self._editor == nil then
    fail("search focuses a node inside an open editor", {})
  end
  assert(type(self._editor) == "table", "search reads its open editor")
  local kind = self._editor.kind
  local graph = assert(PokedexSearch.FOCUS[kind], "search editors carry a source focus graph")
  if type(nodeIndex) ~= "number" or nodeIndex % 1 ~= 0 or graph.nodes[nodeIndex + 1] == nil then
    fail("search focus nodes address the source graph", { editor = kind, node = nodeIndex })
  end
  self._editor.node = nodeIndex
  self._editor.returnInput = nil
  if nodeIndex < graph.cells then
    self._editor.column = nodeIndex
  end
  if kind ~= "height" and kind ~= "weight" then
    syncEditorFocus(self._editor, self:editorOptions(kind))
  else
    syncEditorFocus(self._editor, nil)
  end
end

---@param commit boolean true retains, false restores the backup
function PokedexSearch:closeEditor(commit)
  if self._editor == nil then
    return
  end
  local editor = self._editor
  assert(type(editor) == "table", "search closes its open editor")
  if commit == true and editor.kind == "type" then
    local pending = editor.types
    assert(type(pending) == "table", "the type editor keeps its pending slots")
    if #pending == 2 and pending[1] == pending[2] then
      self._criteria.type1 = pending[1]
      self._criteria.type2 = nil
    else
      self._criteria.type1 = pending[1]
      self._criteria.type2 = pending[2]
    end
  end
  if commit ~= true then
    self._criteria = copyCriteria(editor.backup)
  end
  self._editor = nil
  self._sliderOpCount = 0
  self._sliderAnim = 0
  self._drag = nil
end

---@param value unknown borrowed published option order behind one editor
---@param what string option family behind the order
---@return string[] detached option keys in the published order
local function copyOptionOrder(value, what)
  if type(value) ~= "table" then
    fail("search needs the published " .. what .. " order", {})
  end
  assert(type(value) == "table", "search reads its published option order")
  local options = {}
  for index = 1, #value do
    local option = value[index]
    if type(option) ~= "string" then
      fail("search needs a dense published " .. what .. " order", {})
    end
    options[#options + 1] = option
  end
  for key in pairs(value) do
    if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > #value then
      fail("search needs a dense published " .. what .. " order", {})
    end
  end
  if #options == 0 then
    fail("search needs a nonempty published " .. what .. " order", {})
  end
  return options
end

---@param kind string
---@return string[] option keys in source order with unrestricted last
function PokedexSearch:editorOptions(kind)
  local catalog = self._catalog
  assert(type(catalog) == "table", "search reads its borrowed catalog")
  if kind == "order" then
    local options = {}
    for _, name in ipairs(PokedexSearch.ORDERS) do
      options[#options + 1] = name
    end
    return options
  end
  if kind == "letter" then
    local options = {}
    for code = string.byte("A"), string.byte("Z") do
      options[#options + 1] = string.char(code)
    end
    options[#options + 1] = "unrestricted"
    return options
  end
  local criteria = catalog.criteria
  assert(type(criteria) == "table", "the catalog carries its search criteria")
  if kind == "type" then
    return copyOptionOrder(criteria.typeOptionOrder, "type")
  end
  if kind == "shape" then
    return copyOptionOrder(criteria.shapeOptionOrder, "shape")
  end
  if kind == "area" then
    return { "johto", "kanto", "unknown", "unrestricted" }
  end
  fail("search names an unknown option editor", { editor = kind })
  error("unreachable", 0)
end

---@param choice string
function PokedexSearch:choose(choice)
  if self._editor == nil then
    fail("search chooses inside an open editor", {})
  end
  assert(type(self._editor) == "table", "search reads its open editor")
  local kind = self._editor.kind
  if type(choice) ~= "string" or choice == "" then
    fail("search choices name an option", { editor = kind })
  end
  if kind == "order" then
    local known = false
    for _, name in ipairs(PokedexSearch.ORDERS) do
      if name == choice then
        known = true
      end
    end
    if not known then
      fail("search order names an unknown sort", { order = choice })
    end
    self._criteria.order = choice
    self._editor.focus = choice
    return
  end
  if kind == "letter" then
    if choice == "unrestricted" then
      self._criteria.letter = nil
    else
      if #choice ~= 1 or choice:upper() ~= choice or choice < "A" or choice > "Z" then
        fail("search letters name A through Z", { letter = choice })
      end
      self._criteria.letter = choice:lower()
    end
    self._editor.focus = choice
    return
  end
  if kind == "shape" then
    if choice == "unrestricted" then
      self._criteria.shape = nil
    else
      local shapes = checkTable(self._catalog.criteria.shapes, "shape lists")
      if shapes[choice] == nil then
        fail("search shapes name a declared class", { shape = choice })
      end
      self._criteria.shape = choice
    end
    self._editor.focus = choice
    return
  end
  if kind == "area" then
    if choice == "kanto" and self._nationalUnlocked ~= true then
      return
    end
    if choice ~= "unrestricted" and choice ~= "johto" and choice ~= "kanto" and choice ~= "unknown" then
      fail("search areas name a declared scope", { area = choice })
    end
    if choice == "unrestricted" then
      self._criteria.area = nil
    else
      self._criteria.area = choice
    end
    self._editor.areaChoice = self._criteria.area
    self._editor.focus = choice
    return
  end
  if kind == "type" then
    if choice == "unrestricted" then
      local pending = self._editor.types
      assert(type(pending) == "table", "the type editor keeps its pending slots")
      if #pending > 1 then
        table.remove(pending, 2)
      elseif #pending > 0 then
        table.remove(pending, 1)
      end
      self._editor.focus = choice
      return
    end
    local types = checkTable(self._catalog.criteria.types, "type lists")
    if types[choice] == nil then
      fail("search types name a declared key", { choice = choice })
    end
    local pending = self._editor.types
    assert(type(pending) == "table", "the type editor keeps its pending slots")
    if #pending == 2 and pending[2] == choice then
      return
    end
    if #pending < 2 then
      local duplicate = false
      for _, held in ipairs(pending) do
        if held == choice then
          duplicate = true
        end
      end
      if not duplicate then
        pending[#pending + 1] = choice
      end
    else
      pending[1] = pending[2]
      pending[2] = choice
    end
    self._editor.focus = choice
    return
  end
  fail("search choices need an option editor", { editor = kind })
end

-- Moves the open editor focus without staging anything: keyboard and
-- gamepad navigation walk the projected option list while touch chooses
-- directly. The locked Kanto scope never takes focus.
---@param choice string option to focus
function PokedexSearch:focusOption(choice)
  if self._editor == nil then
    fail("search focuses inside an open editor", {})
  end
  assert(type(self._editor) == "table", "search reads its open editor")
  local kind = self._editor.kind
  if kind == "height" or kind == "weight" then
    fail("search slider editors focus their endpoint instead", { editor = kind })
  end
  local known = false
  for _, option in ipairs(self:editorOptions(kind)) do
    if option == choice then
      known = true
    end
  end
  if not known then
    fail("search focuses a projected option", { editor = kind })
  end
  if kind == "area" and choice == "kanto" and self._nationalUnlocked ~= true then
    return
  end
  self._editor.focus = choice
end

-- Switches the open slider endpoint without moving its bound: up/down
-- navigation selects which bound arrows and drags adjust.
---@param endpoint string min or max endpoint
function PokedexSearch:setSliderEndpoint(endpoint)
  if self._editor == nil then
    fail("search endpoints switch inside an open slider editor", {})
  end
  assert(type(self._editor) == "table", "search reads its open editor")
  local kind = self._editor.kind
  if kind ~= "height" and kind ~= "weight" then
    fail("search endpoints switch inside a slider editor", { editor = kind })
  end
  if endpoint ~= "min" and endpoint ~= "max" then
    fail("search sliders name a min or max endpoint", { endpoint = endpoint })
  end
  self._editor.endpoint = endpoint
end

---@param count integer completed operations including the new one
---@return integer authored step for that operation
local function arrowStep(count)
  if count >= 24 then
    return 32
  end
  if count >= 16 then
    return 16
  end
  if count >= 8 then
    return 8
  end
  return 1
end

---@param criterion string "height" or "weight"
---@param endpoint string "min" or "max"
---@param direction integer -1 or 1
function PokedexSearch:stepSlider(criterion, endpoint, direction)
  if self._editor == nil or (self._editor.kind ~= "height" and self._editor.kind ~= "weight") then
    fail("search steps inside an open slider editor", {})
  end
  assert(type(self._editor) == "table", "search reads its open slider editor")
  if criterion ~= self._editor.kind then
    fail("search steps match the open slider", { editor = self._editor.kind, criterion = criterion })
  end
  if endpoint ~= "min" and endpoint ~= "max" then
    fail("search sliders name a min or max endpoint", { endpoint = endpoint })
  end
  if direction ~= 1 and direction ~= -1 then
    fail("search slider steps move by signed direction", { direction = direction })
  end
  self._editor.endpoint = endpoint
  if self._sliderOpCount < PokedexSearch.SLIDER_OP_CAP then
    self._sliderOpCount = self._sliderOpCount + 1
  end
  local step = arrowStep(self._sliderOpCount)
  local bounds = self._criteria[criterion]
  assert(type(bounds) == "table", "search reads its slider bounds")
  local other = bounds[endpoint == "min" and "max" or "min"]
  assert(type(other) == "number", "search reads the opposing endpoint")
  local value = bounds[endpoint]
  assert(type(value) == "number", "search reads the active endpoint")
  value = value + step * direction
  if value < PokedexSearch.SLIDER_MIN then
    value = PokedexSearch.SLIDER_MIN
  end
  if value > PokedexSearch.SLIDER_MAX then
    value = PokedexSearch.SLIDER_MAX
  end
  if endpoint == "min" and value > other then
    value = other
  end
  if endpoint == "max" and value < other then
    value = other
  end
  bounds[endpoint] = value
  self._sliderAnim = PokedexSearch.SLIDER_ANIM_TICKS
end

function PokedexSearch:resetOpCount()
  self._sliderOpCount = 0
end

---@param criterion string "height" or "weight"
---@param endpoint string "min" or "max"
---@param value integer dragged position
function PokedexSearch:beginDrag(criterion, endpoint, value)
  if self._editor == nil or self._editor.kind ~= criterion then
    fail("search drags inside the matching slider editor", { criterion = criterion })
  end
  assert(type(self._editor) == "table", "search reads its open slider editor")
  if endpoint ~= "min" and endpoint ~= "max" then
    fail("search drags name a min or max endpoint", { endpoint = endpoint })
  end
  if type(value) ~= "number" or value % 1 ~= 0 then
    fail("search drags carry an integer position", { value = value })
  end
  self._editor.endpoint = endpoint
  local bounds = self._criteria[criterion]
  assert(type(bounds) == "table", "search reads its slider bounds")
  local preDrag = bounds[endpoint]
  if value < PokedexSearch.SLIDER_MIN then
    value = PokedexSearch.SLIDER_MIN
  end
  if value > PokedexSearch.SLIDER_MAX then
    value = PokedexSearch.SLIDER_MAX
  end
  self._drag = { criterion = criterion, endpoint = endpoint, preDrag = preDrag }
  bounds[endpoint] = value
  self._sliderOpCount = 0
  self._sliderAnim = 0
end

---@param value integer dragged position
function PokedexSearch:moveDrag(value)
  if self._drag == nil then
    fail("search moves an active drag", {})
  end
  assert(type(self._drag) == "table", "search reads its active drag")
  if type(value) ~= "number" or value % 1 ~= 0 then
    fail("search drags carry an integer position", { value = value })
  end
  if value < PokedexSearch.SLIDER_MIN then
    value = PokedexSearch.SLIDER_MIN
  end
  if value > PokedexSearch.SLIDER_MAX then
    value = PokedexSearch.SLIDER_MAX
  end
  local criterion = self._drag.criterion
  local bounds = self._criteria[criterion]
  assert(type(bounds) == "table", "search reads its slider bounds")
  bounds[self._drag.endpoint] = value
end

---@param commit boolean true keeps a valid release, false restores
function PokedexSearch:endDrag(commit)
  if self._drag == nil then
    return
  end
  assert(type(self._drag) == "table", "search reads its active drag")
  local criterion = self._drag.criterion
  local endpoint = self._drag.endpoint
  local preDrag = self._drag.preDrag
  self._drag = nil
  local bounds = self._criteria[criterion]
  assert(type(bounds) == "table", "search reads its slider bounds")
  if commit ~= true then
    bounds[endpoint] = preDrag
    return
  end
  if bounds.min > bounds.max then
    bounds[endpoint] = preDrag
  end
end

function PokedexSearch:cancelDrag()
  self:endDrag(false)
end

---@return boolean
function PokedexSearch:isDragging()
  return self._drag ~= nil
end

-- Names the captured slider endpoint behind the active drag, if any.
-- The mapper routes every continuation of the gesture to this target;
-- a continuation naming any other endpoint is stale and must not move
-- the bound.
---@return string? captured criterion-endpoint target behind the active drag
function PokedexSearch:dragTarget()
  if self._drag == nil then
    return nil
  end
  assert(type(self._drag) == "table", "search reads its active drag")
  return self._drag.criterion .. "-" .. self._drag.endpoint
end

function PokedexSearch:tick()
  if self._sliderAnim > 0 then
    self._sliderAnim = self._sliderAnim - 1
  end
end

---@param dex table<string, unknown>
---@param speciesKey string
---@return boolean
local function dexHas(dex, speciesKey)
  local seen = dex.isSeen
  assert(type(seen) == "function", "search reads knowledge through its owner")
  return seen(dex, speciesKey) == true
end

---@param dex table<string, unknown>
---@param speciesKey string
---@return boolean
local function dexCaught(dex, speciesKey)
  local caught = dex.isCaught
  assert(type(caught) == "function", "search reads knowledge through its owner")
  return caught(dex, speciesKey) == true
end

---@param list unknown
---@param speciesKey string
---@return boolean
local function listHas(list, speciesKey)
  if type(list) ~= "table" then
    return false
  end
  for _, key in ipairs(list) do
    if key == speciesKey then
      return true
    end
  end
  return false
end

---@return string[] result species keys in the selected order
function PokedexSearch:run()
  local catalog = self._catalog
  assert(type(catalog) == "table", "search reads its borrowed catalog")
  local dex = self._dex
  local orders = checkTable(catalog.dexOrders, "dex orders")
  local activeOrder = orders[self._mode]
  if type(activeOrder) ~= "table" then
    fail("search membership names an unknown mode", { mode = self._mode })
  end
  assert(type(activeOrder) == "table", "search reads the active regional membership")
  local membership = activeOrder
  local criteriaLists = checkTable(catalog.criteria, "criteria lists")
  local orderName = self._criteria.order
  local orderArray
  if orderName == "numerical" then
    orderArray = membership
  elseif orderName == "alphabetical" then
    orderArray = checkTable(catalog.sortOrders, "sort orders").alphabetical
  else
    local profiles = checkTable(catalog.measurementProfiles, "measurement profiles")
    local profile = checkTable(profiles[self._profileName], "the frozen profile")
    local sorts = checkTable(profile.sorts, "profile sorts")
    orderArray = checkTable(sorts[orderName], "the ordered sort")
  end
  local needsCaught = PokedexSearch.MEASUREMENT_ORDERS[orderName] == true
  if self._criteria.type1 ~= nil or self._criteria.type2 ~= nil then
    needsCaught = true
  end
  local height = self._criteria.height
  assert(type(height) == "table", "search reads its height bounds")
  local weight = self._criteria.weight
  assert(type(weight) == "table", "search reads its weight bounds")
  if height.min > 0 or height.max < PokedexSearch.SLIDER_MAX then
    needsCaught = true
  end
  if weight.min > 0 or weight.max < PokedexSearch.SLIDER_MAX then
    needsCaught = true
  end
  local steps = checkTable(catalog.sliderSteps, "slider steps")
  local heightLow, heightHigh, weightLow, weightHigh
  if needsCaught == true or height.min > 0 or height.max < PokedexSearch.SLIDER_MAX then
    local lowStep = checkTable(steps[height.min + 1], "the height low step")
    local highStep = checkTable(steps[height.max + 1], "the height high step")
    heightLow = lowStep.heightDm
    heightHigh = highStep.heightDm
  end
  if needsCaught == true or weight.min > 0 or weight.max < PokedexSearch.SLIDER_MAX then
    local lowStep = checkTable(steps[weight.min + 1], "the weight low step")
    local highStep = checkTable(steps[weight.max + 1], "the weight high step")
    weightLow = lowStep.weightHg
    weightHigh = highStep.weightHg
  end
  local profiles = catalog.measurementProfiles
  assert(type(profiles) == "table", "search reads its measurement profiles")
  local profile = profiles[self._profileName]
  assert(type(profile) == "table", "search reads the frozen profile")
  local measurements = profile.measurements
  assert(type(measurements) == "table", "search reads profile measurements")
  local memberSet = {}
  for _, key in ipairs(membership) do
    memberSet[key] = true
  end
  local results = {}
  for _, key in ipairs(orderArray) do
    if memberSet[key] == true and dexHas(dex, key) then
      local eligible = true
      if needsCaught == true and not dexCaught(dex, key) then
        eligible = false
      end
      if eligible == true and self._criteria.letter ~= nil then
        local letters = criteriaLists.letters
        assert(type(letters) == "table", "search reads letter memberships")
        if not listHas(letters[self._criteria.letter], key) then
          eligible = false
        end
      end
      if eligible == true and (self._criteria.type1 ~= nil or self._criteria.type2 ~= nil) then
        local types = criteriaLists.types
        assert(type(types) == "table", "search reads type memberships")
        for _, slot in ipairs({ self._criteria.type1, self._criteria.type2 }) do
          if slot ~= nil and not listHas(types[slot], key) then
            eligible = false
          end
        end
      end
      if eligible == true and self._criteria.shape ~= nil then
        local shapes = criteriaLists.shapes
        assert(type(shapes) == "table", "search reads shape memberships")
        if not listHas(shapes[self._criteria.shape], key) then
          eligible = false
        end
      end
      if eligible == true and self._criteria.area ~= nil then
        local areas = criteriaLists.areas
        assert(type(areas) == "table", "search reads area memberships")
        local scope = self._criteria.area
        if scope == "johto" then
          if not listHas(areas.johto, key) then
            eligible = false
          end
        elseif scope == "kanto" then
          if not listHas(areas.kanto, key) then
            eligible = false
          end
        elseif scope == "unknown" then
          if not listHas(areas.unknown, key) then
            eligible = false
          end
        else
          fail("search areas name a declared scope", { area = scope })
        end
      end
      if eligible == true and (height.min > 0 or height.max < PokedexSearch.SLIDER_MAX) then
        local row = measurements[key]
        if type(row) ~= "table" or type(row.heightDm) ~= "number" then
          fail("search needs the legal height row", { species = key })
        end
        if row.heightDm < heightLow or row.heightDm > heightHigh then
          eligible = false
        end
      end
      if eligible == true and (weight.min > 0 or weight.max < PokedexSearch.SLIDER_MAX) then
        local row = measurements[key]
        if type(row) ~= "table" or type(row.weightHg) ~= "number" then
          fail("search needs the legal weight row", { species = key })
        end
        if row.weightHg < weightLow or row.weightHg > weightHigh then
          eligible = false
        end
      end
      if eligible == true then
        results[#results + 1] = key
      end
    end
  end
  return results
end

---@return table<string, unknown>? detached editor projection
function PokedexSearch:editorView()
  if self._editor == nil then
    return nil
  end
  assert(type(self._editor) == "table", "search reads its open editor")
  local kind = self._editor.kind
  -- The projection carries both spellings: criteria transactions read
  -- `criterion` while the touch interface, compact rows, and role
  -- projections read `kind`.
  local graph = assert(PokedexSearch.FOCUS[kind], "search editors carry a source focus graph")
  local view = {
    kind = kind,
    criterion = kind,
    focus = self._editor.focus,
    node = self._editor.node or 0,
    cells = graph.cells,
    ok = graph.ok,
    cancel = graph.cancel,
    column = self._editor.column,
  }
  if kind == "type" then
    local pending = self._editor.types
    assert(type(pending) == "table", "the type editor keeps its pending slots")
    local types = {}
    for _, key in ipairs(pending) do
      types[#types + 1] = key
    end
    view.types = types
  end
  if kind == "area" then
    view.areaChoice = self._editor.areaChoice
    view.choices = {
      johto = { enabled = true },
      kanto = { enabled = self._nationalUnlocked == true },
      unknown = { enabled = true },
      unrestricted = { enabled = true },
    }
  end
  if kind == "height" or kind == "weight" then
    local bounds = self._criteria[kind]
    assert(type(bounds) == "table", "search reads its slider bounds")
    view.endpoint = self._editor.endpoint or "min"
    view.slider = {
      criterion = kind,
      endpoint = self._editor.endpoint or "min",
      value = bounds[self._editor.endpoint or "min"],
      bounds = { min = bounds.min, max = bounds.max },
      min = PokedexSearch.SLIDER_MIN,
      max = PokedexSearch.SLIDER_MAX,
      operationCount = self._sliderOpCount,
      captured = self._drag ~= nil,
    }
  end
  return view
end

---@return table<string, unknown>? detached slider projection for height/weight editors
function PokedexSearch:sliderView()
  local editor = self:editorView()
  if editor == nil then
    return nil
  end
  return editor.slider
end

return PokedexSearch
