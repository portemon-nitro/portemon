-- Structured Generation-IV authored Mail carried by a Mon.
local MonsErrors = require("libs.mons.src.errors")
local Utf8Glyphs = require("libs.assets.src.Utf8Glyphs")

local Mail = {}
Mail.SCHEMA = "g4-mail-v1"

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

function Mail.validate(value, context)
  if type(value) ~= "table" then
    fail("mail must be a record")
  end
  if next(value) == nil then
    return {}
  end
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
    if icon ~= false then
      keys(icon, { species = true, form = true, palette = true }, "mail icon")
      if type(icon.species) ~= "string" or icon.species == "" then
        fail("mail icon species is invalid")
      end
      integer(icon.form, 0, 31, "mail icon form")
      integer(icon.palette, 0, 255, "mail icon palette")
      if context and context.catalog then
        context.catalog:form(icon.species, icon.form)
      end
    end
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

function Mail.copy(value)
  return Mail.validate(value)
end

return Mail
