-- Owns the fixed thirty-six-slot saved field-photo bucket.
local Errors = require("libs.errors.src.Errors")
local GameSaveErrors = require("libs.hgss.src.save.GameSaveErrors")

local PhotoAlbum = {}
PhotoAlbum.__index = PhotoAlbum
PhotoAlbum.SCHEMA = "g4-photo-album-v1"
PhotoAlbum.CAPACITY = 36

local function invalid(message)
  Errors.raise(GameSaveErrors.GAME_SAVE_BUCKET_INVALID, message, { bucket = "photoAlbum" })
end

local function copy(value)
  if type(value) ~= "table" then
    return value
  end
  local result = {}
  for key, child in pairs(value) do
    result[key] = copy(child)
  end
  return result
end

local function integer(value, low, high)
  return type(value) == "number" and value % 1 == 0 and value >= low and value <= high
end

local function nonEmptyString(value)
  return type(value) == "string" and value ~= ""
end

local function checkMon(mon, context)
  if
    type(mon) ~= "table"
    or not nonEmptyString(mon.species)
    or not integer(mon.form, 0, 31)
    or not integer(mon.gender, 0, 2)
    or type(mon.shiny) ~= "boolean"
  then
    invalid("photo party subject is invalid")
  end
  if context and context.monCatalog then
    context.monCatalog:form(mon.species, mon.form)
  end
end

local function checkRecord(photo, context)
  if type(photo) ~= "table" or photo.schema ~= "g4-photo-v1" then
    invalid("photo schema is invalid")
  end
  local date = photo.date
  if
    not integer(photo.icon, 0, 255)
    or type(photo.playerName) ~= "string"
    or type(photo.leadNickname) ~= "string"
    or not integer(photo.playerGender, 0, 1)
    or type(photo.avatarState) ~= "string"
    or not nonEmptyString(photo.mapSymbol)
    or not integer(photo.fieldX, 0, 65535)
    or not integer(photo.fieldZ, 0, 65535)
    or type(date) ~= "table"
    or not integer(date.year, 2000, 2255)
    or not integer(date.month, 1, 12)
    or not integer(date.day, 1, 31)
    or not integer(date.weekday, 0, 6)
    or not integer(photo.hour, 0, 23)
    or not integer(photo.minute, 0, 59)
    or (photo.subjectSprite ~= nil and not nonEmptyString(photo.subjectSprite))
    or not integer(photo.sourcePartyCount, 0, 6)
  then
    invalid("photo identity, location, or time is invalid")
  end
  if type(photo.party) ~= "table" or type(photo.hiddenPropModels) ~= "table" then
    invalid("photo party snapshot is invalid")
  end
  for index = 1, 6 do
    local mon = photo.party[index]
    if mon ~= false then
      checkMon(mon, context)
    end
  end
  for index = 1, 2 do
    local model = photo.hiddenPropModels[index]
    if model ~= false and type(model) ~= "string" then
      invalid("photo prop model is invalid")
    end
  end
end

local function validate(snapshot, context)
  if type(snapshot) ~= "table" or snapshot.schema ~= PhotoAlbum.SCHEMA or type(snapshot.slots) ~= "table" then
    invalid("photo album schema is invalid")
  end
  local result = {}
  for index = 1, PhotoAlbum.CAPACITY do
    local photo = snapshot.slots[index]
    if photo ~= false then
      checkRecord(photo, context)
      result[index] = copy(photo)
    else
      result[index] = false
    end
  end
  return result
end

function PhotoAlbum.new(snapshot)
  local slots = {}
  if snapshot == nil then
    for index = 1, PhotoAlbum.CAPACITY do
      slots[index] = false
    end
  else
    slots = validate(snapshot)
  end
  return setmetatable({ _slots = slots, _revision = 0 }, PhotoAlbum)
end

function PhotoAlbum:revision()
  return self._revision
end
function PhotoAlbum:count()
  return PhotoAlbum.CAPACITY
end
function PhotoAlbum:usedCount()
  local count = 0
  for _, photo in ipairs(self._slots) do
    if photo ~= false then
      count = count + 1
    end
  end
  return count
end

function PhotoAlbum:get(slot)
  if not integer(slot, 0, PhotoAlbum.CAPACITY - 1) then
    invalid("photo slot is out of range")
  end
  local value = self._slots[slot + 1]
  if value == false then
    return nil
  end
  return copy(value)
end
function PhotoAlbum:capture()
  return copy({ schema = PhotoAlbum.SCHEMA, slots = self._slots })
end

local function deepEqual(left, right)
  if left == right then
    return true
  end
  if type(left) ~= "table" or type(right) ~= "table" then
    return false
  end
  for key, value in pairs(left) do
    if not deepEqual(value, right[key]) then
      return false
    end
  end
  for key in pairs(right) do
    if left[key] == nil then
      return false
    end
  end
  return true
end

function PhotoAlbum:prepareChanges(expectedRevision, updates)
  assert(type(updates) == "table", "photo updates must be an array")
  if expectedRevision ~= self._revision then
    return nil, "stale"
  end
  local candidate, changed, seen = copy(self._slots), false, {}
  for _, update in ipairs(updates) do
    if type(update) ~= "table" or not integer(update.slot, 0, PhotoAlbum.CAPACITY - 1) then
      invalid("photo update slot is invalid")
    end
    if seen[update.slot] then
      invalid("photo slot is written twice")
    end
    seen[update.slot] = true
    local value = update.value
    if value ~= false then
      checkRecord(value)
      value = copy(value)
    end
    if not deepEqual(candidate[update.slot + 1], value) then
      candidate[update.slot + 1], changed = copy(value), true
    end
  end
  local revision, consumed = self._revision + (changed and 1 or 0), false
  local function isCurrent()
    return self._revision == expectedRevision
  end
  local function publish()
    assert(not consumed, "photo preparation publishes exactly once")
    consumed = true
    if changed then
      self._slots, self._revision = candidate, revision
    end
  end
  return { changed = changed, isCurrent = isCurrent, publish = publish }
end

function PhotoAlbum.validate(snapshot, context)
  validate(snapshot, context)
  return true
end

return PhotoAlbum
