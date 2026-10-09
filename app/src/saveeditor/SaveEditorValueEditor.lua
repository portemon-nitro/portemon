-- Owns transient numeric, choice, and real-subject name editing.

local NamingScreenController = require("libs.hgss.src.ui.NamingScreenController")
local Utf8Glyphs = require("libs.assets.src.Utf8Glyphs")

---@class SaveEditorChoiceOption
---@field key string
---@field label string

---@class SaveEditorChoiceProjection
---@field query string
---@field revision integer
---@field queryRevision integer
---@field options SaveEditorChoiceOption[]
---@field rowTargets string[]
---@field indexByTarget table<string, integer>
---@field idAt fun(index: integer): string?
---@field indexOf fun(targetId: string): integer?
---@field rowAt fun(index: integer): SaveEditorChoiceOption?

---@class SaveEditorChoiceFilterTask
---@field query string
---@field foldedQuery string
---@field queryRevision integer
---@field cursor integer
---@field options SaveEditorChoiceOption[]
---@field rowTargets string[]
---@field indexByTarget table<string, integer>

---@class SaveEditorValueEditor
---@field _kind string
---@field _result { kind: string, value: unknown? }?
---@field _value number?
---@field _min number?
---@field _max number?
---@field _base string?
---@field _buffer string?
---@field _cursor number?
---@field _hasInput boolean?
---@field _radix integer?
---@field _digitCount integer?
---@field _selectedPlace integer?
---@field _options { key: string, label: string }[]?
---@field _index number?
---@field _selectedKey string?
---@field _query string?
---@field _filteredCache SaveEditorChoiceProjection?
---@field _filterTask SaveEditorChoiceFilterTask?
---@field _queryRevision integer?
---@field _name NamingScreenController?
---@field _nameKind "player"|"pokemon"|nil
---@field _nameMaxLength integer?
---@field _nameCharmap table<string, integer>?
---@field _disposed boolean
---@field dispose fun(self: SaveEditorValueEditor)
---@field retry fun(self: SaveEditorValueEditor): boolean
local SaveEditorValueEditor = {}
SaveEditorValueEditor.__index = SaveEditorValueEditor

local function parseInteger(text, base)
  if text == "" then
    return nil
  end
  if base == "hex" then
    local digits = text:gsub("^0[xX]", "")
    if digits == "" or not digits:match("^[%da-fA-F]+$") then
      return nil
    end
    return tonumber(digits, 16)
  end
  if not text:match("^%d+$") then
    return nil
  end
  return tonumber(text, 10)
end

---@param options table<string, unknown>
---@return SaveEditorValueEditor
function SaveEditorValueEditor.new(options)
  assert(type(options) == "table", "value editor options are required")
  local self = setmetatable({ _kind = options.kind, _result = nil, _disposed = false }, SaveEditorValueEditor)
  if options.kind == "integer" then
    assert(type(options.value) == "number" and options.value % 1 == 0)
    assert(type(options.min) == "number" and type(options.max) == "number" and options.min <= options.max)
    assert(options.base == "decimal" or options.base == "hex")
    assert(options.min >= 0 and options.max <= 0xFFFFFFFF, "integer editor ranges are unsigned 32-bit values")
    self._value = options.value
    self._min = options.min
    self._max = options.max
    self._base = options.base
    self._radix = options.base == "hex" and 16 or 10
    self._digitCount = 1
    local placeValue = self._radix
    while placeValue <= options.max do
      self._digitCount = self._digitCount + 1
      placeValue = placeValue * self._radix
    end
    self._selectedPlace = 0
    self._buffer = options.base == "hex" and string.format("%X", options.value) or tostring(options.value)
    self._cursor = #self._buffer
    self._hasInput = false
  elseif options.kind == "choice" then
    assert(type(options.options) == "table" and #options.options > 0)
    self._options = {}
    for i, option in ipairs(options.options) do
      assert(type(option) == "table" and type(option.key) == "string")
      self._options[i] = { key = option.key, label = option.label or option.key }
    end
    self._index = 1
    local seen = {}
    for index, option in ipairs(self._options) do
      assert(not seen[option.key], "choice option keys must be unique")
      seen[option.key] = true
      if option.key == options.value then
        self._index = index
        self._selectedKey = option.key
      end
    end
    self._selectedKey = self._selectedKey or self._options[1].key
    self._query = ""
    local rowTargets, indexByTarget = {}, {}
    for index, option in ipairs(self._options) do
      local targetId = "choice:" .. option.key
      rowTargets[index] = targetId
      indexByTarget[targetId] = index
    end
    ---@type SaveEditorChoiceProjection
    local cache
    cache = {
      query = "",
      revision = 1,
      queryRevision = 0,
      options = self._options,
      rowTargets = rowTargets,
      indexByTarget = indexByTarget,
      idAt = function(index)
        return cache.rowTargets[index]
      end,
      indexOf = function(targetId)
        return cache.indexByTarget[targetId]
      end,
      rowAt = function(index)
        return cache.options[index]
      end,
    }
    self._filteredCache = cache
    self._queryRevision = 0
    self._index = assert(indexByTarget["choice:" .. self._selectedKey])
  elseif options.kind == "name" then
    self._nameKind = options.nameKind
    self._nameMaxLength = options.maxLength
    self._nameCharmap = options.charmap
    self._name = NamingScreenController.new({
      kind = options.nameKind,
      maxLength = options.maxLength,
      initialText = options.initialText,
      charmap = options.charmap,
      subject = options.subject,
    })
  else
    error("unknown Save Editor value editor kind", 2)
  end
  return self
end

function SaveEditorValueEditor:textinput(text)
  assert(type(text) == "string", "value editor text must be a string")
  if self._result then
    return false
  end
  if self._kind == "integer" then
    if text == "" or text:find("[%c]") then
      return false
    end
    if not self._hasInput then
      self._buffer = ""
      self._cursor = 0
      self._hasInput = true
    end
    self._buffer = self._buffer .. text
    self._cursor = #self._buffer
    return true
  elseif self._kind == "choice" then
    self._query = self._query .. text
    self:_beginFilter()
    return true
  end
  return self._name:inputText(text)
end

function SaveEditorValueEditor:press(action)
  assert(type(action) == "string", "value editor action is required")
  if self._result then
    return false
  end
  if action == "cancel" or action == "escape" or action == "b" or action == "back" then
    return self:cancel()
  end
  if self._kind == "integer" then
    if action == "backspace" then
      if self._buffer == "" then
        return true
      end
      self._buffer = self._buffer:sub(1, -2)
      self._cursor = #self._buffer
      self._hasInput = true
      return true
    elseif action == "up" or action == "down" or action == "left" or action == "right" then
      if action == "up" or action == "down" then
        return self:adjustPlace(action == "up" and 1 or -1)
      end
      local place = assert(self._selectedPlace)
      local direction = action == "left" and 1 or -1
      return self:selectPlace(math.max(0, math.min(assert(self._digitCount) - 1, place + direction)))
    elseif action == "confirm" or action == "a" or action == "return" then
      return self:submit()
    end
  elseif self._kind == "choice" then
    if action == "backspace" then
      local glyphs = {}
      for glyph in Utf8Glyphs.iter(self._query) do
        glyphs[#glyphs + 1] = glyph
      end
      table.remove(glyphs)
      self._query = table.concat(glyphs)
      self:_beginFilter()
      return true
    elseif action == "clear_search" then
      self._query = ""
      self:_beginFilter()
      return true
    end
    if self._filterTask ~= nil then
      return false
    end
    local filtered = self:_filteredOptions()
    if #filtered == 0 then
      return false
    end
    if action == "up" or action == "down" then
      return self:moveChoice(action == "up" and -1 or 1)
    elseif action == "confirm" or action == "a" then
      return self:submit()
    end
  elseif self._kind == "name" then
    if action == "backspace" then
      return self._name:deleteGlyph()
    end
    if action == "confirm" or action == "a" then
      local cursor = self._name:snapshot().cursor
      local activated = self._name:activateAt(cursor.row, cursor.column)
      self:_collectNameResult()
      return activated
    end
    if action == "cancel" then
      return self:cancel()
    end
    return self._name:press(action)
  end
  return false
end

---@param place integer Zero-based place from the least-significant digit.
---@return boolean selected
function SaveEditorValueEditor:selectPlace(place)
  assert(self._kind == "integer" and type(place) == "number" and place % 1 == 0, "numeric place must be an integer")
  assert(place >= 0 and place < assert(self._digitCount), "numeric place is outside the descriptor")
  self._selectedPlace = place
  return true
end

---@param sign -1|1
---@return boolean changed
function SaveEditorValueEditor:adjustPlace(sign)
  assert(self._kind == "integer" and (sign == -1 or sign == 1), "place adjustment sign must be -1 or 1")
  local current = parseInteger(self._buffer, self._base)
  if current == nil or current < self._min or current > self._max then
    current = math.floor(assert(self._value, "integer editor retains its last valid value"))
  end
  local increment = assert(self._radix) ^ assert(self._selectedPlace)
  local nextValue = math.max(self._min, math.min(self._max, current + sign * increment))
  local nextBuffer = self:_formatInteger(nextValue)
  local changed = nextValue ~= self._value or nextBuffer ~= self._buffer
  self._value = nextValue
  self._buffer = nextBuffer
  self._cursor = #self._buffer
  self._hasInput = true
  return changed
end

function SaveEditorValueEditor:_formatInteger(value)
  local format = self._base == "hex" and "%0" .. tostring(self._digitCount) .. "X"
    or "%0" .. tostring(self._digitCount) .. "d"
  return string.format(format, value)
end

function SaveEditorValueEditor:moveChoice(delta)
  assert(type(delta) == "number" and delta % 1 == 0 and delta ~= 0, "choice movement must be a non-zero integer")
  if self._filterTask ~= nil then
    return false
  end
  local filtered = self:_filteredOptions()
  if #filtered == 0 then
    self._index = 0
    self._selectedKey = nil
    return false
  end
  self:_reconcileSelection()
  self._index = math.max(1, math.min(#filtered, self._index + delta))
  self._selectedKey = filtered[self._index].key
  return true
end

function SaveEditorValueEditor:activateTarget(targetId)
  if targetId == "cancel" or targetId == "back" then
    return self:cancel()
  end
  if self._kind == "integer" then
    if targetId == "confirm" then
      return self:press("confirm")
    end
    if targetId == "cancel" then
      return self:cancel()
    end
    return false
  elseif self._kind == "choice" then
    if self._filterTask ~= nil then
      return false
    end
    local options = self:_filteredOptions()
    local index = assert(self._filteredCache).indexByTarget["choice:" .. targetId]
    if index ~= nil and options[index] ~= nil and options[index].key == targetId then
      self._index, self._selectedKey = index, targetId
      self._result = { kind = "confirm", value = targetId }
      return true
    end
  elseif self._kind == "name" then
    local row, column = targetId:match("^(%d+):(%d+)$")
    if row then
      local rowIndex, columnIndex = assert(tonumber(row)), assert(tonumber(column))
      local activated = self._name:activateAt(rowIndex --[[@as integer]], columnIndex --[[@as integer]])
      self:_collectNameResult()
      return activated
    end
    if
      targetId == "upper"
      or targetId == "lower"
      or targetId == "symbols"
      or targetId == "back"
      or targetId == "ok"
    then
      local activated = self._name:activateControl(targetId)
      self:_collectNameResult()
      return activated
    end
    if targetId == "confirm" then
      return self:submit()
    end
    if targetId == "cancel" then
      return self:cancel()
    end
  end
  return false
end

function SaveEditorValueEditor:submit()
  if self._disposed or self._result ~= nil then
    return false
  end
  if self._kind == "integer" then
    local value = parseInteger(self._buffer, self._base)
    if value == nil or value < self._min or value > self._max then
      return false, "Enter a whole number within the allowed range."
    end
    self._result = { kind = "confirm", value = value }
  elseif self._kind == "choice" then
    if self._filterTask ~= nil then
      return false, "Wait for the filtered choices to finish."
    end
    local filtered = self:_filteredOptions()
    local option = filtered[self._index]
    if option == nil then
      return false, "Choose an available option."
    end
    self._result = { kind = "confirm", value = option.key }
  else
    assert(self._name ~= nil)
    if not self._name:press("submit") then
      return false, "The name could not be submitted."
    end
    local result = self._name:result()
    assert(result ~= nil and result.kind == "submit")
    self._result = { kind = "confirm", value = result.text }
  end
  return true
end

function SaveEditorValueEditor:cancel()
  if self._disposed or self._result then
    return false
  end
  self._result = { kind = "cancel" }
  return true
end

function SaveEditorValueEditor:dispose()
  if self._disposed then
    return
  end
  self._disposed = true
  self._filterTask = nil
  self._result = nil
end

function SaveEditorValueEditor:retry()
  if self._disposed or self._result == nil or self._result.kind ~= "confirm" then
    return false
  end
  if self._kind == "name" then
    local naming = assert(self._name):snapshot()
    self._name = NamingScreenController.new({
      kind = assert(self._nameKind),
      maxLength = assert(self._nameMaxLength),
      initialText = assert(naming.text),
      charmap = assert(self._nameCharmap),
      subject = assert(naming.subject),
    })
  end
  self._result = nil
  return true
end

function SaveEditorValueEditor:_filteredOptions()
  return assert(self._filteredCache).options
end

function SaveEditorValueEditor:_beginFilter()
  if self._query == assert(self._filteredCache).query then
    self._filterTask = nil
    return
  end
  local query = assert(self._query)
  ---@type SaveEditorChoiceFilterTask
  local task = {
    query = query,
    queryRevision = (self._queryRevision or 0) + 1,
    foldedQuery = query:lower(),
    cursor = 1,
    options = {},
    rowTargets = {},
    indexByTarget = {},
  }
  self._filterTask = task
  self._queryRevision = task.queryRevision
end

---@param rowBudget integer
---@return integer visited
function SaveEditorValueEditor:update(rowBudget)
  if self._disposed then
    return 0
  end
  assert(type(rowBudget) == "number" and rowBudget >= 0 and rowBudget % 1 == 0)
  if self._kind ~= "choice" or self._filterTask == nil then
    return 0
  end
  local task = assert(self._filterTask)
  local options = assert(self._options)
  local visited = 0
  while task.cursor <= #options and visited < rowBudget do
    local option = options[task.cursor]
    if
      task.foldedQuery == ""
      or option.label:lower():find(task.foldedQuery, 1, true)
      or option.key:lower():find(task.foldedQuery, 1, true)
    then
      local index = #task.options + 1
      task.options[index] = option
      local targetId = "choice:" .. option.key
      task.rowTargets[index] = targetId
      task.indexByTarget[targetId] = index
    end
    task.cursor = task.cursor + 1
    visited = visited + 1
  end
  if task.cursor > #options then
    local previousIndex = self._index or 1
    local selectedIndex = task.indexByTarget["choice:" .. tostring(self._selectedKey)]
    if selectedIndex == nil and #task.options > 0 then
      selectedIndex = math.min(previousIndex, #task.options) --[[@as integer]]
    end
    ---@type SaveEditorChoiceProjection
    local cache
    cache = {
      query = task.query,
      revision = assert(self._filteredCache).revision + 1,
      queryRevision = task.queryRevision,
      options = task.options,
      rowTargets = task.rowTargets,
      indexByTarget = task.indexByTarget,
      idAt = function(index)
        return cache.rowTargets[index]
      end,
      indexOf = function(targetId)
        return cache.indexByTarget[targetId]
      end,
      rowAt = function(index)
        return cache.options[index]
      end,
    }
    self._filteredCache = cache
    self._index = selectedIndex or 0
    if selectedIndex ~= nil then
      self._selectedKey = task.options[selectedIndex].key
    end
    self._filterTask = nil
  end
  return visited
end

---@param key string
---@return boolean selected
function SaveEditorValueEditor:selectChoice(key)
  assert(self._kind == "choice" and type(key) == "string", "choice selection needs a key")
  if self._filterTask ~= nil then
    return false
  end
  local targetId = "choice:" .. key
  local index = assert(self._filteredCache).indexByTarget[targetId]
  if index == nil then
    return false
  end
  self._index, self._selectedKey = index, key
  return true
end

---@return string[] rowTargets
function SaveEditorValueEditor:_filteredRowTargets()
  self:_filteredOptions()
  return assert(self._filteredCache).rowTargets
end

---@return table<string, integer> indexByTarget
function SaveEditorValueEditor:_filteredIndexByTarget()
  self:_filteredOptions()
  return assert(self._filteredCache).indexByTarget
end

function SaveEditorValueEditor:_reconcileSelection()
  local index = assert(self._filteredCache).indexByTarget["choice:" .. tostring(self._selectedKey)]
  if index ~= nil then
    self._index = index
  elseif #self._filteredCache.options == 0 then
    self._index = 0
  else
    self._index = 1
    self._selectedKey = self._filteredCache.options[1].key
  end
end

function SaveEditorValueEditor:_collectNameResult()
  local result = assert(self._name):result()
  if result and result.kind == "submit" then
    self._result = { kind = "confirm", value = result.text }
  end
end

function SaveEditorValueEditor:result()
  if self._result == nil then
    return nil
  end
  return { kind = self._result.kind, value = self._result.value }
end

function SaveEditorValueEditor:snapshot()
  if self._kind == "integer" then
    local parsedValue = parseInteger(self._buffer, self._base)
    local displayValue = parsedValue ~= nil
        and parsedValue >= self._min
        and parsedValue <= self._max
        and self:_formatInteger(parsedValue)
      or assert(self._buffer, "integer editor owns its input buffer")
    local digits = {}
    for index = 1, assert(self._digitCount) do
      local start = math.max(1, #displayValue - self._digitCount + index)
      digits[index] = displayValue:sub(start, start)
      if digits[index] == "" then
        digits[index] = "0"
      end
    end
    return {
      kind = "number",
      value = self._value,
      buffer = self._buffer,
      base = self._base,
      minimum = self._min,
      maximum = self._max,
      radix = self._radix,
      digitCount = self._digitCount,
      digits = digits,
      selectedPlace = self._selectedPlace,
      parsedValue = parsedValue,
      valid = parsedValue ~= nil and parsedValue >= self._min and parsedValue <= self._max,
      cursor = self._cursor,
      result = self:result(),
    }
  elseif self._kind == "choice" then
    local cache = assert(self._filteredCache)
    return {
      kind = "choice",
      revision = cache.revision,
      queryRevision = self._queryRevision,
      count = #cache.options,
      idAt = cache.idAt,
      indexOf = cache.indexOf,
      rowAt = cache.rowAt,
      options = cache.options,
      rowTargets = cache.rowTargets,
      indexByTarget = cache.indexByTarget,
      index = self._index or 0,
      selectedKey = self._selectedKey,
      query = self._query,
      empty = #cache.options == 0 and self._filterTask == nil,
      pending = self._filterTask ~= nil,
      result = self:result(),
    }
  end
  return { kind = "name", naming = self._name:snapshot(), result = self:result() }
end

return SaveEditorValueEditor
