-- Owns transient numeric, choice, and real-subject name editing.

local NamingScreenController = require("libs.hgss.src.ui.NamingScreenController")
local Utf8Glyphs = require("libs.assets.src.Utf8Glyphs")

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
---@field _options { key: string, label: string }[]?
---@field _index number?
---@field _selectedKey string?
---@field _query string?
---@field _name NamingScreenController?
---@field _nameKind "player"|"pokemon"|nil
---@field _nameMaxLength integer?
---@field _nameCharmap table<string, integer>?
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
  local self = setmetatable({ _kind = options.kind, _result = nil }, SaveEditorValueEditor)
  if options.kind == "integer" then
    assert(type(options.value) == "number" and options.value % 1 == 0)
    assert(type(options.min) == "number" and type(options.max) == "number" and options.min <= options.max)
    assert(options.base == "decimal" or options.base == "hex")
    self._value = options.value
    self._min = options.min
    self._max = options.max
    self._base = options.base
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
    self:_reconcileSelection()
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
    elseif action == "left" then
      self._cursor = math.max(0, self._cursor - 1)
      return true
    elseif action == "right" then
      self._cursor = math.min(#self._buffer, self._cursor + 1)
      return true
    elseif action == "up" or action == "down" then
      local value = parseInteger(self._buffer, self._base)
      if value == nil then
        return false
      end
      local place = self._base == "hex" and 16 ^ math.max(0, #self._buffer - self._cursor)
        or 10 ^ math.max(0, #self._buffer - self._cursor)
      local candidate = value + (action == "up" and place or -place)
      if candidate < self._min or candidate > self._max then
        return false
      end
      local significance = math.max(0, #self._buffer - self._cursor)
      self._buffer = self._base == "hex" and string.format("%X", candidate) or tostring(candidate)
      self._cursor = math.max(0, #self._buffer - significance)
      return true
    elseif action == "confirm" or action == "a" or action == "return" then
      return self:submit()
    end
  elseif self._kind == "choice" then
    local filtered = self:_filteredOptions()
    if action == "backspace" then
      local glyphs = {}
      for glyph in Utf8Glyphs.iter(self._query) do
        glyphs[#glyphs + 1] = glyph
      end
      table.remove(glyphs)
      self._query = table.concat(glyphs)
      self:_reconcileSelection()
      return true
    elseif action == "clear_search" then
      self._query = ""
      self:_reconcileSelection()
      return true
    end
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

function SaveEditorValueEditor:moveChoice(delta)
  assert(type(delta) == "number" and delta % 1 == 0 and delta ~= 0, "choice movement must be a non-zero integer")
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
    local options = self:_filteredOptions()
    for index, option in ipairs(options) do
      if option.key == targetId then
        self._index, self._selectedKey = index, option.key
        self._result = { kind = "confirm", value = option.key }
        return true
      end
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
  if self._result ~= nil then
    return false
  end
  if self._kind == "integer" then
    local value = parseInteger(self._buffer, self._base)
    if value == nil or value < self._min or value > self._max then
      return false, "Enter a whole number within the allowed range."
    end
    self._result = { kind = "confirm", value = value }
  elseif self._kind == "choice" then
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
  if self._result then
    return false
  end
  self._result = { kind = "cancel" }
  return true
end

function SaveEditorValueEditor:retry()
  if self._result == nil or self._result.kind ~= "confirm" then
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
  local filtered = {}
  local query = self._query:lower()
  for _, option in ipairs(self._options) do
    if query == "" or option.label:lower():find(query, 1, true) or option.key:lower():find(query, 1, true) then
      filtered[#filtered + 1] = option
    end
  end
  return filtered
end

function SaveEditorValueEditor:_reconcileSelection()
  local filtered = self:_filteredOptions()
  for index, option in ipairs(filtered) do
    if option.key == self._selectedKey then
      self._index = index
      return
    end
  end
  if #filtered == 0 then
    self._index = 0
    return
  end
  self._index = 1
  self._selectedKey = filtered[1] and filtered[1].key or nil
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
    return {
      kind = "integer",
      value = self._value,
      buffer = self._buffer,
      base = self._base,
      minimum = self._min,
      maximum = self._max,
      parsedValue = parsedValue,
      valid = parsedValue ~= nil and parsedValue >= self._min and parsedValue <= self._max,
      cursor = self._cursor,
      result = self:result(),
    }
  elseif self._kind == "choice" then
    local options = self:_filteredOptions()
    local selected
    for index, option in ipairs(options) do
      if option.key == self._selectedKey then
        selected = index
        break
      end
    end
    return {
      kind = "choice",
      options = options,
      index = selected or 0,
      selectedKey = self._selectedKey,
      query = self._query,
      empty = #options == 0,
      result = self:result(),
    }
  end
  return { kind = "name", naming = self._name:snapshot(), result = self:result() }
end

return SaveEditorValueEditor
