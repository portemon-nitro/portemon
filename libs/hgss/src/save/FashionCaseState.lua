-- Owns the persisted quantities for the narrow HGSS Fashion Case state.

---@class FashionCaseState
---@field private counts integer[]
local FashionCaseState = {}
FashionCaseState.__index = FashionCaseState

FashionCaseState.SCHEMA = "hgss-fashion-case-v1"

local ACCESSORY_COUNT = 100

---@param accessoryId integer
local function checkAccessoryId(accessoryId)
  assert(
    type(accessoryId) == "number" and accessoryId % 1 == 0 and accessoryId >= 0 and accessoryId < ACCESSORY_COUNT,
    "Fashion Case accessory id must be an integer in 0..99"
  )
end

---@param accessoryId integer
---@return integer
local function accessoryCap(accessoryId)
  return accessoryId <= 60 and 9 or 1
end

---@param record unknown
---@return table<string, unknown>
function FashionCaseState.validate(record)
  assert(type(record) == "table", "Fashion Case record must be a table")
  local fields = 0
  for key in pairs(record) do
    assert(key == "schema" or key == "counts", "Fashion Case record has an unknown field")
    fields = fields + 1
  end
  assert(fields == 2, "Fashion Case record requires exactly schema and counts")
  assert(record.schema == FashionCaseState.SCHEMA, "Fashion Case schema is unsupported")
  assert(type(record.counts) == "table", "Fashion Case counts must be an array")

  local countFields = 0
  for key in pairs(record.counts) do
    assert(
      type(key) == "number" and key % 1 == 0 and key >= 1 and key <= ACCESSORY_COUNT,
      "Fashion Case counts must have exactly 100 entries"
    )
    countFields = countFields + 1
  end
  assert(countFields == ACCESSORY_COUNT, "Fashion Case counts must have exactly 100 entries")

  local counts = {}
  for index = 1, ACCESSORY_COUNT do
    local quantity = record.counts[index]
    local accessoryId = index - 1
    assert(
      type(quantity) == "number" and quantity % 1 == 0 and quantity >= 0 and quantity <= accessoryCap(accessoryId),
      "Fashion Case quantity is outside its accessory cap"
    )
    counts[index] = quantity
  end
  return { schema = FashionCaseState.SCHEMA, counts = counts }
end

---@return table<string, unknown>
function FashionCaseState.empty()
  local counts = {}
  for index = 1, ACCESSORY_COUNT do
    counts[index] = 0
  end
  return { schema = FashionCaseState.SCHEMA, counts = counts }
end

---@param record table<string, unknown>
---@return FashionCaseState
function FashionCaseState.new(record)
  local canonical = FashionCaseState.validate(record)
  return setmetatable({ counts = canonical.counts }, FashionCaseState)
end

---@param accessoryId integer
---@return integer
function FashionCaseState:quantity(accessoryId)
  checkAccessoryId(accessoryId)
  return self.counts[accessoryId + 1]
end

---@param accessoryId integer
---@return boolean
function FashionCaseState:tryAdd(accessoryId)
  checkAccessoryId(accessoryId)
  local index = accessoryId + 1
  if self.counts[index] >= accessoryCap(accessoryId) then
    return false
  end
  self.counts[index] = self.counts[index] + 1
  return true
end

---@return table<string, unknown>
function FashionCaseState:capture()
  local counts = {}
  for index = 1, ACCESSORY_COUNT do
    counts[index] = self.counts[index]
  end
  return { schema = FashionCaseState.SCHEMA, counts = counts }
end

return FashionCaseState
