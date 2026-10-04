-- Owns the fixed twenty-slot authored Mail bucket.
local Errors = require("libs.errors.src.Errors")
local GameSaveErrors = require("libs.hgss.src.save.GameSaveErrors")
local Mail = require("libs.mons.src.gen4.Mail")

local Mailbox = {}
Mailbox.__index = Mailbox
Mailbox.SCHEMA = "g4-mailbox-v1"
Mailbox.CAPACITY = 20

local function invalid(message)
  Errors.raise(GameSaveErrors.GAME_SAVE_BUCKET_INVALID, message, { bucket = "mailbox" })
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

local function validate(snapshot, context)
  if type(snapshot) ~= "table" or snapshot.schema ~= Mailbox.SCHEMA then
    invalid("mailbox schema is invalid")
  end
  for key in pairs(snapshot) do
    if key ~= "schema" and key ~= "slots" then
      invalid("mailbox has an unknown field")
    end
  end
  local slots = snapshot.slots
  if type(slots) ~= "table" then
    invalid("mailbox slots are required")
  end
  for key in pairs(slots) do
    if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > Mailbox.CAPACITY then
      invalid("mailbox slots must be dense")
    end
  end
  local result = {}
  for index = 1, Mailbox.CAPACITY do
    local value = slots[index]
    if value == nil then
      invalid("mailbox must contain exactly twenty slots")
    end
    if value == false then
      result[index] = false
    else
      local ok, checked = pcall(Mail.validate, value, context)
      if not ok then
        invalid("mailbox slot contains invalid Mail")
      end
      if not Mail.isWritten(checked) then
        invalid("mailbox slots require authored Mail")
      end
      result[index] = checked
    end
  end
  return result
end

function Mailbox.new(snapshot)
  local slots = {}
  if snapshot == nil then
    for index = 1, Mailbox.CAPACITY do
      slots[index] = false
    end
  else
    slots = validate(snapshot)
  end
  return setmetatable({ _slots = slots, _revision = 0 }, Mailbox)
end

function Mailbox:revision()
  return self._revision
end
function Mailbox:count()
  return Mailbox.CAPACITY
end

function Mailbox:get(slot)
  if type(slot) ~= "number" or slot % 1 ~= 0 or slot < 0 or slot >= Mailbox.CAPACITY then
    invalid("mailbox slot is out of range")
  end
  local value = self._slots[slot + 1]
  if value == false then
    return nil
  end
  return copy(value)
end

function Mailbox:capture()
  return copy({ schema = Mailbox.SCHEMA, slots = self._slots })
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

function Mailbox:prepareChanges(expectedRevision, updates)
  assert(type(updates) == "table", "mailbox updates must be an array")
  if expectedRevision ~= self._revision then
    return nil, "stale"
  end
  local candidate, changed, seen = copy(self._slots), false, {}
  for _, update in ipairs(updates) do
    if
      type(update) ~= "table"
      or type(update.slot) ~= "number"
      or update.slot % 1 ~= 0
      or update.slot < 0
      or update.slot >= Mailbox.CAPACITY
    then
      invalid("mailbox update slot is invalid")
    end
    if seen[update.slot] then
      invalid("mailbox slot is written twice")
    end
    seen[update.slot] = true
    local value
    if update.value == false then
      value = false
    else
      value = Mail.validate(update.value)
    end
    if value ~= false and not Mail.isWritten(value) then
      invalid("mailbox slots require authored Mail")
    end
    if not deepEqual(candidate[update.slot + 1], value) then
      candidate[update.slot + 1], changed = copy(value), true
    end
  end
  local revision = self._revision + (changed and 1 or 0)
  local consumed = false
  local function isCurrent()
    return self._revision == expectedRevision
  end
  local function publish()
    assert(not consumed, "mailbox preparation publishes exactly once")
    consumed = true
    if changed then
      self._slots, self._revision = candidate, revision
    end
  end
  return { changed = changed, isCurrent = isCurrent, publish = publish }
end

function Mailbox.validate(snapshot, context)
  validate(snapshot, context)
  return true
end

return Mailbox
