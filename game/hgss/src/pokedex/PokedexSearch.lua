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
PokedexSearch.CRITERIA = { "order", "letter", "type", "shape", "area", "height", "weight" }

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
  local editor = { kind = kind, backup = backup, focus = nil, previousColumn = "criteria" }
  if kind == "type" then
    local pending = {}
    if self._criteria.type1 ~= nil then
      pending[#pending + 1] = self._criteria.type1
    end
    if self._criteria.type2 ~= nil then
      pending[#pending + 1] = self._criteria.type2
    end
    editor.types = pending
    editor.focus = pending[1]
  elseif kind == "area" then
    editor.areaChoice = self._criteria.area
    editor.focus = self._criteria.area or "unrestricted"
  elseif kind == "height" or kind == "weight" then
    editor.endpoint = "min"
    self._sliderOpCount = 0
    self._sliderAnim = 0
    self._drag = nil
  else
    editor.focus = self._criteria[kind]
  end
  self._editor = editor
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

---@param kind string
---@return string[] option keys with unrestricted first
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
    local options = { "unrestricted" }
    for code = string.byte("A"), string.byte("Z") do
      options[#options + 1] = string.char(code)
    end
    return options
  end
  local criteria = catalog.criteria
  assert(type(criteria) == "table", "the catalog carries its search criteria")
  if kind == "type" then
    local options = { "unrestricted" }
    local types = checkTable(criteria.types, "type lists")
    local keys = {}
    for key in pairs(types) do
      keys[#keys + 1] = key
    end
    table.sort(keys)
    for _, key in ipairs(keys) do
      options[#options + 1] = key
    end
    return options
  end
  if kind == "shape" then
    local options = { "unrestricted" }
    local shapes = checkTable(criteria.shapes, "shape lists")
    local keys = {}
    for key in pairs(shapes) do
      keys[#keys + 1] = key
    end
    table.sort(keys)
    for _, key in ipairs(keys) do
      options[#options + 1] = key
    end
    return options
  end
  if kind == "area" then
    return { "unrestricted", "johto", "kanto", "unknown" }
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
          local inKanto = listHas(areas.kanto, key)
          local inUnknown = listHas(areas.unknown, key)
          local inJohto = listHas(areas.johto, key)
          if not ((inKanto or inUnknown) and not inJohto) then
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
  local view =
    { kind = kind, criterion = kind, focus = self._editor.focus, previousColumn = self._editor.previousColumn }
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
