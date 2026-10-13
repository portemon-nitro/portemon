-- Stable thirty-slot boxes with copied snapshots and staged replacements.
local MonsErrors = require("libs.mons.src.errors")
local StorageConfig = require("libs.mons.src.gen4.StorageConfig")
local Utf8Glyphs = require("libs.assets.src.Utf8Glyphs")

---@class Boxes
---@field private _boxes table<string, unknown>[]
---@field private _activeBox integer
---@field private _bonusUnlocks boolean[]
---@field private _revision integer
local Boxes = {}
Boxes.__index = Boxes
Boxes.SLOTS_PER_BOX = 30

---@class BoxesPreparation
---@field changed boolean
---@field isCurrent fun(): boolean
---@field publish fun()

local function fail(message, context)
  MonsErrors.raise(MonsErrors.SAVE_INVALID, message, context or {})
end

local function integer(value, minimum)
  return type(value) == "number"
    and value == value
    and value ~= math.huge
    and value ~= -math.huge
    and value % 1 == 0
    and value >= minimum
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

local function emptyBox(index)
  local slots = {}
  for slot = 1, Boxes.SLOTS_PER_BOX do
    slots[slot] = false
  end
  return { wallpaperId = (index - 1) % 16, slots = slots }
end

local function validateSnapshot(snapshot, context)
  if type(snapshot) ~= "table" or snapshot.schema ~= "g4-boxes-v1" then
    fail("boxes snapshot schema is invalid")
  end
  if not integer(snapshot.boxCount, 1) or type(snapshot.boxes) ~= "table" then
    fail("boxes snapshot count is invalid")
  end
  for index = 1, snapshot.boxCount do
    local box = snapshot.boxes[index]
    if type(box) ~= "table" then
      fail("box record is invalid", { box = index - 1 })
    end
    if box.name ~= nil then
      if type(box.name) ~= "string" then
        fail("box name must be text", { box = index - 1 })
      end
      if context and context.charmap then
        local glyphs = 0
        for glyph in Utf8Glyphs.iter(box.name) do
          if context.charmap[glyph] == nil then
            fail("box name has an unencodable glyph", { box = index - 1 })
          end
          glyphs = glyphs + 1
        end
        if glyphs > 19 then
          fail("box name exceeds nineteen glyphs", { box = index - 1 })
        end
      end
    end
    local wallpaper = box.wallpaperId
    if not integer(wallpaper, 0) or not (wallpaper <= 15 or (wallpaper >= 32 and wallpaper <= 39)) then
      fail("box wallpaper is invalid", { box = index - 1 })
    end
    if type(box.slots) ~= "table" then
      fail("box slots are required", { box = index - 1 })
    end
    for slot = 1, Boxes.SLOTS_PER_BOX do
      if box.slots[slot] == nil or (box.slots[slot] ~= false and type(box.slots[slot]) ~= "table") then
        fail("box must contain exactly thirty slots", { box = index - 1, slot = slot - 1 })
      end
    end
  end
  if not integer(snapshot.activeBox, 0) or snapshot.activeBox >= snapshot.boxCount then
    fail("active box is out of range")
  end
  if type(snapshot.bonusUnlocks) ~= "table" then
    fail("bonus wallpaper unlocks are required")
  end
  for index = 1, 8 do
    if type(snapshot.bonusUnlocks[index]) ~= "boolean" then
      fail("bonus wallpaper unlocks must have eight entries")
    end
  end
end

local function validateConfiguredCount(count)
  if not integer(count, 1) then
    fail("configured box count must be a positive finite integer", { count = count })
  end
end

---@param snapshot MonsSave.BoxesSnapshot?
---@param options { configuredCount?: integer }?
---@return Boxes
function Boxes.new(snapshot, options)
  options = options or {}
  local configuredCount = options.configuredCount
  if configuredCount == nil then
    configuredCount = StorageConfig.BOX_COUNT
  end
  validateConfiguredCount(configuredCount)
  local boxes, activeBox, unlocks = {}, 0, { false, false, false, false, false, false, false, false }
  if snapshot ~= nil then
    validateSnapshot(snapshot)
    local copied = copy(snapshot)
    boxes, activeBox, unlocks = copied.boxes, copied.activeBox, copied.bonusUnlocks
    for index = #boxes, copied.boxCount + 1, -1 do
      boxes[index] = nil
    end
  end
  local count = math.max(configuredCount, #boxes)
  for index = #boxes + 1, count do
    boxes[index] = emptyBox(index)
  end
  if activeBox >= count then
    fail("active box is out of range")
  end
  return setmetatable({ _boxes = boxes, _activeBox = activeBox, _bonusUnlocks = unlocks, _revision = 0 }, Boxes)
end

---@return integer
function Boxes:count()
  return #self._boxes
end
---@return integer
function Boxes:revision()
  return self._revision
end
---@return integer
function Boxes:activeBox()
  return self._activeBox
end

local function boxAt(self, box)
  if not integer(box, 0) or box >= #self._boxes then
    fail("box index is out of range", { box = box })
  end
  return self._boxes[box + 1]
end

local function checkArray(value, what)
  if type(value) ~= "table" then
    fail(what .. " must be an array")
  end
  local count = #value
  return count
end

---@param box integer
---@param slot integer
---@return table<string, unknown>|nil
function Boxes:mon(box, slot)
  local record = boxAt(self, box)
  if not integer(slot, 0) or slot >= Boxes.SLOTS_PER_BOX then
    fail("box slot is out of range", { box = box, slot = slot })
  end
  local mon = record.slots[slot + 1]
  if mon == false then
    return nil
  end
  return copy(mon)
end

---@param box integer
---@return { name: string?, wallpaperId: integer }
function Boxes:metadata(box)
  local record = boxAt(self, box)
  return { name = record.name, wallpaperId = record.wallpaperId }
end

function Boxes:bonusUnlocks()
  return copy(self._bonusUnlocks)
end

---@return MonsSave.BoxesSnapshot
function Boxes:capture()
  return copy({
    schema = "g4-boxes-v1",
    boxCount = #self._boxes,
    activeBox = self._activeBox,
    bonusUnlocks = self._bonusUnlocks,
    boxes = self._boxes,
  })
end

---@param expectedRevision integer
---@param changes table<string, unknown>
---@return BoxesPreparation|nil, string|nil
function Boxes:prepareChanges(expectedRevision, changes)
  assert(type(changes) == "table", "box changes must be a record")
  if expectedRevision ~= self._revision then
    return nil, "stale"
  end
  -- Staged copy-on-write candidate: the boxes array is a shallow copy
  -- referencing untouched live boxes, which stay immutable-by-contract
  -- until cloned below on first write to that box.
  local boxCount = #self._boxes
  local candidateBoxes = {}
  for index = 1, boxCount do
    candidateBoxes[index] = self._boxes[index]
  end
  local candidateActive = self._activeBox
  local candidateUnlocks = self._bonusUnlocks
  local cloned = {}
  local function stagedBox(box)
    if not cloned[box] then
      local live = self._boxes[box + 1]
      local slots = {}
      for slot = 1, Boxes.SLOTS_PER_BOX do
        slots[slot] = live.slots[slot]
      end
      candidateBoxes[box + 1] = { name = live.name, wallpaperId = live.wallpaperId, slots = slots }
      cloned[box] = true
    end
    return candidateBoxes[box + 1]
  end
  local changed = false
  local written = {}
  local updates = changes.updates or {}
  for index = 1, checkArray(updates, "box updates") do
    local update = updates[index]
    if type(update) ~= "table" then
      fail("box update must be a record")
    end
    local box, slot = update.box, update.slot
    boxAt(self, box)
    if not integer(slot, 0) or slot >= Boxes.SLOTS_PER_BOX then
      fail("box slot is out of range", { box = box, slot = slot })
    end
    local address = box .. ":" .. slot
    if written[address] then
      fail("box slot is written twice", { box = box, slot = slot })
    end
    written[address] = true
    if update.mon ~= false and type(update.mon) ~= "table" then
      fail("box update requires a mon or false")
    end
    local wanted = update.mon == false and false or update.mon
    if not deepEqual(candidateBoxes[box + 1].slots[slot + 1], wanted) then
      stagedBox(box).slots[slot + 1] = update.mon == false and false or copy(update.mon)
      changed = true
    end
  end
  local metadataSeen = {}
  local metadata = changes.metadata or {}
  for index = 1, checkArray(metadata, "box metadata updates") do
    local update = metadata[index]
    if type(update) ~= "table" then
      fail("box metadata update must be a record")
    end
    if update.clearName ~= nil and type(update.clearName) ~= "boolean" then
      fail("box clear-name flag must be a boolean")
    end
    if update.clearName == true and update.name ~= nil then
      fail("box metadata cannot set and clear its name")
    end
    local box = update.box
    boxAt(self, box)
    if metadataSeen[box] then
      fail("box metadata is written twice", { box = box })
    end
    metadataSeen[box] = true
    local current = candidateBoxes[box + 1]
    if update.clearName then
      if current.name ~= nil then
        stagedBox(box).name = nil
        changed = true
      end
    elseif update.name ~= nil then
      if type(update.name) ~= "string" then
        fail("box name must be text", { box = box })
      end
      if current.name ~= update.name then
        stagedBox(box).name = update.name
        changed = true
      end
    end
    if update.wallpaperId ~= nil then
      local wallpaper = update.wallpaperId
      if not integer(wallpaper, 0) or not (wallpaper <= 15 or (wallpaper >= 32 and wallpaper <= 39)) then
        fail("box wallpaper is invalid", { box = box })
      end
      if current.wallpaperId ~= wallpaper then
        stagedBox(box).wallpaperId = wallpaper
        changed = true
      end
    end
  end
  if changes.activeBox ~= nil then
    boxAt(self, changes.activeBox)
    if candidateActive ~= changes.activeBox then
      candidateActive = changes.activeBox
      changed = true
    end
  end
  if changes.bonusUnlocks ~= nil then
    local unlocks = changes.bonusUnlocks
    if type(unlocks) ~= "table" then
      fail("bonus unlocks must be an array")
    end
    for index = 1, 8 do
      if type(unlocks[index]) ~= "boolean" then
        fail("bonus unlocks must contain eight booleans")
      end
    end
    if not deepEqual(candidateUnlocks, unlocks) then
      candidateUnlocks = copy(unlocks)
      changed = true
    end
  end
  local revision = self._revision + (changed and 1 or 0)
  local consumed = false
  local function isCurrent()
    return self._revision == expectedRevision
  end
  local function publish()
    assert(not consumed, "box preparation publishes exactly once")
    consumed = true
    if changed then
      self._boxes, self._activeBox, self._bonusUnlocks, self._revision =
        candidateBoxes, candidateActive, candidateUnlocks, revision
    end
  end
  return { changed = changed, isCurrent = isCurrent, publish = publish }
end

---@param snapshot MonsSave.BoxesSnapshot
---@param options { configuredCount?: integer }?
---@return Boxes
function Boxes.restore(snapshot, options)
  return Boxes.new(snapshot, options)
end

function Boxes.validate(snapshot, context)
  validateSnapshot(snapshot, context)
  return true
end

return Boxes
