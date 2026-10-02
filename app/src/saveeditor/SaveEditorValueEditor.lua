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
---@field _query string?
---@field _group string?
---@field _page number?
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
    for index, option in ipairs(self._options) do
      if option.key == options.value then
        self._index = index
      end
    end
    self._query = ""
    self._group = nil
    self._page = 1
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
    self._page = 1
    self._index = 1
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
      self._buffer = self._base == "hex" and string.format("%X", candidate) or tostring(candidate)
      self._cursor = #self._buffer
      return true
    elseif action == "confirm" or action == "a" or action == "return" then
      return self:submit()
    end
  elseif self._kind == "choice" then
    local filtered = self:_filteredOptions()
    if #filtered == 0 then
      return false
    end
    local pageCount = math.max(1, math.ceil(#filtered / 8))
    if action == "page_next" or action == "pagedown" then
      self._page = self._page % pageCount + 1
      self._index = (self._page - 1) * 8 + 1
      return true
    elseif action == "page_previous" or action == "pageup" then
      self._page = (self._page - 2) % pageCount + 1
      self._index = (self._page - 1) * 8 + 1
      return true
    elseif action == "backspace" then
      local glyphs = {}
      for glyph in Utf8Glyphs.iter(self._query) do
        glyphs[#glyphs + 1] = glyph
      end
      table.remove(glyphs)
      self._query = table.concat(glyphs)
      self._index = 1
      self._page = 1
      return true
    elseif action == "clear_search" then
      self._query = ""
      self._index = 1
      self._page = 1
      return true
    elseif action == "group_next" or action == "group_previous" then
      local groups = self:_groups()
      local current = 1
      for index, group in ipairs(groups) do
        if group == self._group then
          current = index
          break
        end
      end
      local delta = action == "group_next" and 1 or -1
      self._group = groups[(current - 1 + delta) % #groups + 1]
      self._page, self._index = 1, 1
      return true
    end
    if action == "up" or action == "down" or action == "left" or action == "right" then
      local delta = (action == "up" or action == "left") and -1 or 1
      self._index = (self._index - 1 + delta) % #filtered + 1
      self._page = math.floor((self._index - 1) / 8) + 1
      return true
    elseif action == "confirm" or action == "a" then
      return self:submit()
    end
  elseif self._kind == "name" then
    if action == "backspace" then
      return self._name:deleteGlyph()
    end
    if action == "confirm" or action == "a" then
      return self:submit()
    end
    if action == "cancel" then
      return self:cancel()
    end
    return self._name:press(action)
  end
  return false
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
    return self._name:activateControl(targetId)
  elseif self._kind == "choice" then
    local options = self:_filteredOptions()
    for index, option in ipairs(options) do
      if option.key == targetId then
        self._index = index
        self._result = { kind = "confirm", value = option.key }
        return true
      end
    end
    if targetId == "group-next" then
      return self:press("group_next")
    end
    if targetId == "group-previous" then
      return self:press("group_previous")
    end
  elseif self._kind == "name" then
    local row, column = targetId:match("^(%d+):(%d+)$")
    if row then
      local rowIndex, columnIndex = assert(tonumber(row)), assert(tonumber(column))
      return self._name:activateAt(rowIndex --[[@as integer]], columnIndex --[[@as integer]])
    end
    if targetId == "confirm" then
      self._name:press("submit")
      local result = self._name:result()
      if result and result.kind == "submit" then
        self._result = { kind = "confirm", value = result.text }
      end
      return result ~= nil
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
    local groupMatches = self._group == nil or option.key:sub(1, 1):upper() == self._group
    if
      groupMatches
      and (query == "" or option.label:lower():find(query, 1, true) or option.key:lower():find(query, 1, true))
    then
      filtered[#filtered + 1] = option
    end
  end
  return filtered
end

function SaveEditorValueEditor:_groups()
  local groups = {}
  for _, option in ipairs(self._options) do
    groups[option.key:sub(1, 1):upper()] = true
  end
  local result = {}
  for group in pairs(groups) do
    result[#result + 1] = group
  end
  table.sort(result)
  if #result == 0 then
    result[1] = ""
  end
  return result
end

function SaveEditorValueEditor:result()
  if self._result == nil then
    return nil
  end
  return { kind = self._result.kind, value = self._result.value }
end

function SaveEditorValueEditor:snapshot()
  if self._kind == "integer" then
    return {
      kind = "integer",
      value = self._value,
      buffer = self._buffer,
      base = self._base,
      minimum = self._min,
      maximum = self._max,
      cursor = self._cursor,
      result = self:result(),
    }
  elseif self._kind == "choice" then
    local options = self:_filteredOptions()
    local selected = options[self._index]
    local pageItems = {}
    local first = (self._page - 1) * 8 + 1
    for index = first, math.min(first + 7, #options) do
      pageItems[#pageItems + 1] = options[index]
    end
    return {
      kind = "choice",
      options = pageItems,
      index = selected and (self._index - (self._page - 1) * 8) or 1,
      page = self._page,
      pageCount = math.max(1, math.ceil(#options / 8)),
      query = self._query,
      group = self._group,
      result = self:result(),
    }
  end
  return { kind = "name", naming = self._name:snapshot(), result = self:result() }
end

return SaveEditorValueEditor
