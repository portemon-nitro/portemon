-- Structured Generation-IV authored Mail carried by a Mon.
-- Icons are semantic mon-icon selector strings (the same values the
-- shared icon provider resolves), never raw source file/palette pairs:
-- the old viewer never consumed the persisted palette, so v1 records
-- migrate through the same catalog choice the renderer displays.
local MonsErrors = require("libs.mons.src.errors")
local Utf8Glyphs = require("libs.assets.src.Utf8Glyphs")

local Mail = {}
Mail.SCHEMA = "g4-mail-v2"
Mail.LEGACY_SCHEMA = "g4-mail-v1"

local function fail(message)
  MonsErrors.raise(MonsErrors.RECORD_INVALID, message, {})
end

local function keys(value, allowed, what)
  if type(value) ~= "table" then
    fail(what .. " must be a record")
  end
  for key in pairs(value) do
    if not allowed[key] then
      fail(what .. " has an unknown field " .. tostring(key))
    end
  end
end

local function integer(value, low, high, what)
  if type(value) ~= "number" or value % 1 ~= 0 or value < low or value > high then
    fail(what .. " is out of range")
  end
end

local function array(value, length, what)
  if type(value) ~= "table" then
    fail(what .. " must be an array")
  end
  for key in pairs(value) do
    if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > length then
      fail(what .. " must have exact length " .. length)
    end
  end
  for index = 1, length do
    if value[index] == nil then
      fail(what .. " must have exact length " .. length)
    end
  end
end

---@param value unknown
---@return unknown
local function copy(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for key, child in pairs(value) do
    out[key] = copy(child)
  end
  return out
end

function Mail.isWritten(value)
  return type(value) == "table" and next(value) ~= nil
end

-- Admits one current icon: false or a nonempty semantic selector string.
-- Selector spelling belongs to the mon catalog/icon provider owners;
-- Mail never parses the string or invents a fallback image.
---@param icon unknown
local function checkIcon(icon)
  if icon == false then
    return
  end
  if type(icon) ~= "string" or icon == "" then
    fail("mail icon must be false or a semantic icon selector")
  end
end

---@param value table<string, unknown>
---@param context table<string, unknown>?
---@return table<string, unknown>
local function checkCurrent(value, context)
  keys(value, { schema = true, type = true, author = true, icons = true, lines = true }, "mail")
  if value.schema ~= Mail.SCHEMA then
    fail("mail schema is invalid")
  end
  integer(value.type, 0, 11, "mail type")
  keys(value.author, { trainerId = true, name = true, gender = true, language = true, game = true }, "mail author")
  integer(value.author.trainerId, 0, 4294967295, "mail author trainer id")
  if type(value.author.name) ~= "string" or value.author.name == "" then
    fail("mail author name is invalid")
  end
  if context and context.charmap then
    local glyphs = 0
    for glyph in Utf8Glyphs.iter(value.author.name) do
      if context.charmap[glyph] == nil then
        fail("mail author name has an unencodable glyph")
      end
      glyphs = glyphs + 1
    end
    if glyphs > 8 then
      fail("mail author name exceeds eight glyphs")
    end
  end
  integer(value.author.gender, 0, 1, "mail author gender")
  integer(value.author.language, 1, 8, "mail author language")
  integer(value.author.game, 1, 8, "mail author game")
  array(value.icons, 3, "mail icons")
  for _, icon in ipairs(value.icons) do
    checkIcon(icon)
  end
  array(value.lines, 3, "mail lines")
  for _, line in ipairs(value.lines) do
    if line ~= false then
      keys(line, { template = true, words = true }, "mail line")
      if type(line.template) ~= "string" or line.template == "" then
        fail("mail template is invalid")
      end
      array(line.words, 2, "mail words")
      for _, word in ipairs(line.words) do
        if word ~= false and (type(word) ~= "string" or word == "") then
          fail("mail word is invalid")
        end
      end
    end
  end
  return copy(value)
end

-- Admits one predecessor icon record and resolves it through the same
-- catalog choice the old renderer displayed. The persisted palette is
-- deliberately dropped: the old viewer never consumed it.
---@param icon unknown
---@param context table<string, unknown>?
---@return string|boolean
local function normalizeLegacyIcon(icon, context)
  if icon == false then
    return false
  end
  if type(icon) ~= "table" then
    fail("legacy mail icon must be a record or false")
  end
  keys(icon, { species = true, form = true, palette = true }, "mail icon")
  if type(icon.species) ~= "string" or icon.species == "" then
    fail("mail icon species is invalid")
  end
  integer(icon.form, 0, 31, "mail icon form")
  integer(icon.palette, 0, 255, "mail icon palette")
  local catalog = context ~= nil and context.catalog or nil
  if catalog == nil then
    fail("legacy mail icons require an icon catalog")
  end
  assert(type(catalog) == "table", "legacy mail icons require an icon catalog")
  local selector = catalog:iconSelection(icon)
  if type(selector) ~= "string" or selector == "" then
    fail("legacy mail icon has no catalog selector")
  end
  return selector
end

---@param value table<string, unknown>
---@param context table<string, unknown>?
---@return table<string, unknown>
local function normalizeLegacy(value, context)
  keys(value, { schema = true, type = true, author = true, icons = true, lines = true }, "mail")
  if value.schema ~= Mail.LEGACY_SCHEMA then
    fail("mail schema is invalid")
  end
  integer(value.type, 0, 11, "mail type")
  keys(value.author, { trainerId = true, name = true, gender = true, language = true, game = true }, "mail author")
  integer(value.author.trainerId, 0, 4294967295, "mail author trainer id")
  if type(value.author.name) ~= "string" or value.author.name == "" then
    fail("mail author name is invalid")
  end
  if context and context.charmap then
    local glyphs = 0
    for glyph in Utf8Glyphs.iter(value.author.name) do
      if context.charmap[glyph] == nil then
        fail("mail author name has an unencodable glyph")
      end
      glyphs = glyphs + 1
    end
    if glyphs > 8 then
      fail("mail author name exceeds eight glyphs")
    end
  end
  integer(value.author.gender, 0, 1, "mail author gender")
  integer(value.author.language, 1, 8, "mail author language")
  integer(value.author.game, 1, 8, "mail author game")
  array(value.icons, 3, "mail icons")
  local icons = {}
  for index, icon in ipairs(value.icons) do
    icons[index] = normalizeLegacyIcon(icon, context)
  end
  array(value.lines, 3, "mail lines")
  local lines = {}
  for index, line in ipairs(value.lines) do
    if line == false then
      lines[index] = false
    else
      keys(line, { template = true, words = true }, "mail line")
      if type(line.template) ~= "string" or line.template == "" then
        fail("mail template is invalid")
      end
      array(line.words, 2, "mail words")
      local words = {}
      for position, word in ipairs(line.words) do
        if word ~= false and (type(word) ~= "string" or word == "") then
          fail("mail word is invalid")
        end
        words[position] = word
      end
      lines[index] = { template = line.template, words = words }
    end
  end
  local author = {}
  for key, field in pairs(value.author) do
    author[key] = field
  end
  return {
    schema = Mail.SCHEMA,
    type = value.type,
    author = author,
    icons = icons,
    lines = lines,
  }
end

-- Normalizes explicit legacy Mail into the current semantic icon shape.
-- Empty Mail passes through untouched; current v2 records validate
-- without rewriting; explicit v1 records migrate type/author/lines
-- verbatim and resolve only their icons through the supplied catalog.
-- No catalog is needed for empty Mail or for v1 Mail whose icons are
-- all false; unknown schemas fail.
---@param value table<string, unknown>
---@param context table<string, unknown>?
---@return table<string, unknown>
function Mail.normalize(value, context)
  if type(value) ~= "table" then
    fail("mail must be a record")
  end
  if next(value) == nil then
    return {}
  end
  if value.schema == Mail.SCHEMA then
    return checkCurrent(value, context)
  end
  if value.schema == Mail.LEGACY_SCHEMA then
    return normalizeLegacy(value, context)
  end
  fail("mail schema is invalid")
  error("unreachable", 0)
end

function Mail.validate(value, context)
  if type(value) ~= "table" then
    fail("mail must be a record")
  end
  if next(value) == nil then
    return {}
  end
  return checkCurrent(value, context)
end

function Mail.copy(value)
  return Mail.validate(value)
end

return Mail
