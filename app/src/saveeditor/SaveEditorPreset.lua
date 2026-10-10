-- Parses the bounded, data-only Save Editor preset format.

local Errors = require("libs.errors.src.Errors")

local SaveEditorPreset = {}
local MAX_SOURCE_BYTES = 128 * 1024
local MAX_ENTRIES = 1024
local MAX_DEPTH = 12
local MAX_SAFE_INTEGER = 9007199254740991

---@class SaveEditorPresetMonSpec
---@field species string
---@field level integer?
---@field form integer?
---@field heldItem string?
---@field fatefulEncounter boolean?
---@field eggLocation integer?

---@class SaveEditorPresetData
---@field schema string
---@field name string
---@field description string
---@field flags table<string, boolean>?
---@field variables table<string, integer>?
---@field items table<string, integer>?
---@field party { lead: SaveEditorPresetMonSpec?, contains: SaveEditorPresetMonSpec[]? }?
---@field location { map: string, x: integer, z: integer, facing: string? }?

local function invalid(message)
  error({ presetParseError = true, message = message }, 0)
end

local function validUtf8(source)
  local index = 1
  while index <= #source do
    local first = source:byte(index)
    local count, secondMinimum, secondMaximum
    if first <= 0x7F then
      count = 1
    elseif first >= 0xC2 and first <= 0xDF then
      count, secondMinimum, secondMaximum = 2, 0x80, 0xBF
    elseif first >= 0xE0 and first <= 0xEF then
      count, secondMinimum, secondMaximum = 3, 0x80, 0xBF
      if first == 0xE0 then
        secondMinimum = 0xA0
      end
      if first == 0xED then
        secondMaximum = 0x9F
      end
    elseif first >= 0xF0 and first <= 0xF4 then
      count, secondMinimum, secondMaximum = 4, 0x80, 0xBF
      if first == 0xF0 then
        secondMinimum = 0x90
      end
      if first == 0xF4 then
        secondMaximum = 0x8F
      end
    else
      return false
    end
    if count > 1 then
      local second = source:byte(index + 1)
      if second == nil or second < secondMinimum or second > secondMaximum then
        return false
      end
      for offset = 2, count - 1 do
        local continuation = source:byte(index + offset)
        if continuation == nil or continuation < 0x80 or continuation > 0xBF then
          return false
        end
      end
    end
    index = index + count
  end
  return true
end

local function parser(source)
  local position, line, column, entries = 1, 1, 1, 0
  local length = #source

  local function advance()
    local byte = source:byte(position)
    position = position + 1
    if byte == 10 then
      line, column = line + 1, 1
    else
      column = column + 1
    end
    return byte and string.char(byte) or ""
  end

  local function fail(message)
    invalid(string.format("line %d, column %d: %s", line, column, message))
  end

  local function skipSpace()
    while position <= length do
      local char = source:sub(position, position)
      if char:match("%s") then
        advance()
      elseif source:sub(position, position + 1) == "--" then
        advance()
        advance()
        while position <= length and source:sub(position, position) ~= "\n" do
          advance()
        end
      else
        break
      end
    end
  end

  local function quotedString()
    local quote = advance()
    local parts = {}
    while position <= length do
      local char = advance()
      if char == quote then
        return table.concat(parts)
      elseif char == "\\" then
        if position > length then
          fail("unterminated string escape")
        end
        local escaped = advance()
        local simple = {
          ["a"] = "\a",
          ["b"] = "\b",
          ["f"] = "\f",
          ["n"] = "\n",
          ["r"] = "\r",
          ["t"] = "\t",
          ["v"] = "\v",
          ["\\"] = "\\",
          ['"'] = '"',
          ["'"] = "'",
        }
        if simple[escaped] == nil then
          fail("unsupported string escape")
        end
        parts[#parts + 1] = simple[escaped]
      elseif char == "\n" or char == "\r" then
        fail("newline in quoted string")
      else
        parts[#parts + 1] = char
      end
    end
    fail("unterminated string")
  end

  local function identifier()
    local start = position
    while position <= length and source:sub(position, position):match("[%w_]") do
      advance()
    end
    return source:sub(start, position - 1)
  end

  local function integer()
    local start = position
    while position <= length and source:sub(position, position):match("%d") do
      advance()
    end
    local digits = source:sub(start, position - 1)
    local value = tonumber(digits)
    if value == nil or value > MAX_SAFE_INTEGER then
      fail("integer is too large")
    end
    return value
  end

  local parseValue
  local function parseTable(depth)
    if depth > MAX_DEPTH then
      fail("table nesting exceeds the limit")
    end
    advance()
    skipSpace()
    local result, mode, implicitIndex = {}, nil, 1
    while position <= length and source:sub(position, position) ~= "}" do
      local key, value
      if source:sub(position, position) == "[" then
        advance()
        skipSpace()
        if source:sub(position, position) ~= '"' and source:sub(position, position) ~= "'" then
          fail("table keys must be strings")
        end
        key = quotedString()
        skipSpace()
        if advance() ~= "]" then
          fail("expected ] after table key")
        end
        skipSpace()
        if advance() ~= "=" then
          fail("expected = after table key")
        end
        mode = mode or "map"
        if mode ~= "map" then
          fail("table cannot mix array and keyed entries")
        end
        skipSpace()
        value = parseValue(depth + 1)
      else
        local char = source:sub(position, position)
        if char:match("[A-Za-z_]") then
          local savedPosition, savedLine, savedColumn = position, line, column
          local name = identifier()
          skipSpace()
          if source:sub(position, position) == "=" then
            advance()
            mode = mode or "map"
            if mode ~= "map" then
              fail("table cannot mix array and keyed entries")
            end
            key = name
            if result[key] ~= nil then
              fail("duplicate table key " .. key)
            end
            skipSpace()
            value = parseValue(depth + 1)
          else
            position, line, column = savedPosition, savedLine, savedColumn
            mode = mode or "array"
            if mode ~= "array" then
              fail("table cannot mix array and keyed entries")
            end
            value = parseValue(depth + 1)
            key = implicitIndex
            implicitIndex = implicitIndex + 1
          end
        else
          mode = mode or "array"
          if mode ~= "array" then
            fail("table cannot mix array and keyed entries")
          end
          value = parseValue(depth + 1)
          key = implicitIndex
          implicitIndex = implicitIndex + 1
        end
      end
      if result[key] ~= nil then
        fail("duplicate table key " .. tostring(key))
      end
      entries = entries + 1
      if entries > MAX_ENTRIES then
        fail("table entry count exceeds the limit")
      end
      result[key] = value
      skipSpace()
      local separator = advance()
      if separator == "}" then
        return result
      elseif separator ~= "," and separator ~= ";" then
        fail("expected a table separator or }")
      end
      skipSpace()
      if source:sub(position, position) == "}" then
        advance()
        return result
      end
    end
    if position > length then
      fail("unterminated table")
    end
    advance()
    return result
  end

  parseValue = function(depth)
    skipSpace()
    local char = source:sub(position, position)
    if char == "{" then
      return parseTable(depth)
    elseif char == '"' or char == "'" then
      return quotedString()
    elseif char:match("%d") then
      return integer()
    elseif char:match("[A-Za-z_]") then
      local name = identifier()
      if name == "true" then
        return true
      elseif name == "false" then
        return false
      end
      fail("unsupported value " .. name)
    end
    fail("expected a literal value")
  end

  skipSpace()
  if identifier() ~= "return" then
    fail("expected one return table")
  end
  skipSpace()
  if source:sub(position, position) ~= "{" then
    fail("return value must be a table")
  end
  local value = parseTable(1)
  skipSpace()
  if position <= length then
    fail("unexpected content after return table")
  end
  return value
end

local function isInteger(value, minimum, maximum)
  return type(value) == "number" and value == math.floor(value) and value >= minimum and value <= maximum
end

local function keysAllowed(value, allowed, path)
  if type(value) ~= "table" then
    invalid(path .. " must be a table")
  end
  for key in pairs(value) do
    if type(key) ~= "string" or allowed[key] ~= true then
      invalid(path .. " has an unsupported key " .. tostring(key))
    end
  end
end

local function nonemptyString(value, path, maximum)
  if type(value) ~= "string" or value == "" or #value > maximum then
    invalid(path .. " must be a nonempty string of at most " .. maximum .. " bytes")
  end
end

local function validateMap(value, path, validate)
  if type(value) ~= "table" or next(value) == nil then
    invalid(path .. " must be a nonempty map")
  end
  for key, item in pairs(value) do
    if type(key) ~= "string" or key == "" then
      invalid(path .. " keys must be nonempty strings")
    end
    validate(item, path .. "." .. key)
  end
end

local function validateMon(value, path)
  keysAllowed(value, {
    species = true,
    level = true,
    form = true,
    heldItem = true,
    fatefulEncounter = true,
    eggLocation = true,
  }, path)
  nonemptyString(value.species, path .. ".species", 128)
  if value.level ~= nil and not isInteger(value.level, 1, 100) then
    invalid(path .. ".level must be an integer in 1..100")
  end
  if value.form ~= nil and not isInteger(value.form, 0, MAX_SAFE_INTEGER) then
    invalid(path .. ".form must be a non-negative integer")
  end
  if value.heldItem ~= nil then
    nonemptyString(value.heldItem, path .. ".heldItem", 128)
  end
  if value.fatefulEncounter ~= nil and type(value.fatefulEncounter) ~= "boolean" then
    invalid(path .. ".fatefulEncounter must be a boolean")
  end
  if value.eggLocation ~= nil and not isInteger(value.eggLocation, 0, 65535) then
    invalid(path .. ".eggLocation must be an integer in 0..65535")
  end
end

local function validate(sourceValue)
  keysAllowed(sourceValue, {
    schema = true,
    name = true,
    description = true,
    flags = true,
    variables = true,
    items = true,
    party = true,
    location = true,
  }, "preset")
  if sourceValue.schema ~= "portemon-save-preset-v1" then
    invalid("preset.schema must be portemon-save-preset-v1")
  end
  nonemptyString(sourceValue.name, "preset.name", 128)
  nonemptyString(sourceValue.description, "preset.description", 1024)
  local hasSection = false
  if sourceValue.flags ~= nil then
    hasSection = true
    validateMap(sourceValue.flags, "preset.flags", function(value, path)
      if type(value) ~= "boolean" then
        invalid(path .. " must be a boolean")
      end
    end)
  end
  if sourceValue.variables ~= nil then
    hasSection = true
    validateMap(sourceValue.variables, "preset.variables", function(value, path)
      if not isInteger(value, 0, 65535) then
        invalid(path .. " must be an integer in 0..65535")
      end
    end)
  end
  if sourceValue.items ~= nil then
    hasSection = true
    validateMap(sourceValue.items, "preset.items", function(value, path)
      if not isInteger(value, 1, MAX_SAFE_INTEGER) then
        invalid(path .. " must be a positive integer")
      end
    end)
  end
  if sourceValue.party ~= nil then
    hasSection = true
    keysAllowed(sourceValue.party, { lead = true, contains = true }, "preset.party")
    if next(sourceValue.party) == nil then
      invalid("preset.party must not be empty")
    end
    if sourceValue.party.lead ~= nil then
      validateMon(sourceValue.party.lead, "preset.party.lead")
    end
    if sourceValue.party.contains ~= nil then
      local list = sourceValue.party.contains
      if type(list) ~= "table" or #list == 0 then
        invalid("preset.party.contains must be a nonempty array")
      end
      for key in pairs(list) do
        if not isInteger(key, 1, #list) then
          invalid("preset.party.contains must be a dense array")
        end
      end
      for index, mon in ipairs(list) do
        validateMon(mon, "preset.party.contains[" .. index .. "]")
      end
    end
  end
  if sourceValue.location ~= nil then
    hasSection = true
    keysAllowed(sourceValue.location, { map = true, x = true, z = true, facing = true }, "preset.location")
    nonemptyString(sourceValue.location.map, "preset.location.map", 128)
    if not isInteger(sourceValue.location.x, 0, 65535) then
      invalid("preset.location.x must be an integer in 0..65535")
    end
    if not isInteger(sourceValue.location.z, 0, 65535) then
      invalid("preset.location.z must be an integer in 0..65535")
    end
    local facing = sourceValue.location.facing
    if facing ~= nil and facing ~= "north" and facing ~= "south" and facing ~= "east" and facing ~= "west" then
      invalid("preset.location.facing must be north, south, east, or west")
    end
  end
  if not hasSection then
    invalid("preset must contain at least one patch section")
  end
  return sourceValue
end

---@param source string
---@return SaveEditorPresetData?, Errors.Error?
function SaveEditorPreset.parse(source)
  if type(source) ~= "string" then
    return nil, Errors.new("SAVE_EDITOR_PRESET_INVALID", "Preset content must be text.", {})
  end
  if #source > MAX_SOURCE_BYTES then
    return nil, Errors.new("SAVE_EDITOR_PRESET_INVALID", "Preset exceeds the 128 KiB size limit.", {})
  end
  if not validUtf8(source) then
    return nil, Errors.new("SAVE_EDITOR_PRESET_INVALID", "Preset content must be valid UTF-8.", {})
  end
  local ok, value = pcall(function()
    return validate(parser(source))
  end)
  if ok then
    return value, nil
  end
  if type(value) == "table" and value.presetParseError == true then
    return nil, Errors.new("SAVE_EDITOR_PRESET_INVALID", value.message, {})
  end
  error(value, 0)
end

return SaveEditorPreset
