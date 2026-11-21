-- The save-owned gym mechanism union: the port's closed form of the source's
-- single tagged Union (include/gymmick.h, SaveMiscData). Only one retailed
-- mechanism is active at a time, so the bucket is one tagged kind plus that
-- kind's settled data:
--
--   none   {}                                     no gym is active
--   violet { raised = boolean }                   the lift's settled floor
--   azalea { endpoints = {0,1,2,7}, switchMask }  spider nodes, switch bits
--
-- The source installs a kind through Save_Gymmick_Init (gym init) and clears
-- the union on every non-connection map entry; here restore/initialize own the
-- same transitions. Capture is detached, a malformed bucket is reported and
-- never repaired, and no accessor answers outside its own kind. Pure domain
-- module: no love dependency.

local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.hgss.src.field.FieldErrors")

---@class GymMechanismState
---@field private _kind string
---@field private _data table<string, unknown>
local GymMechanismState = {}
GymMechanismState.__index = GymMechanismState

GymMechanismState.SCHEMA = "hgss-gymmick-v1"

GymMechanismState.NONE = "none"
GymMechanismState.VIOLET = "violet"
GymMechanismState.AZALEA = "azalea"

-- The source's spider slots and switch bits (include/gymmick.h).
GymMechanismState.SPIDER_SLOTS = 4
GymMechanismState.SWITCH_BITS = 2
GymMechanismState.SWITCH_MASK_MAX = (2 ^ GymMechanismState.SWITCH_BITS) - 1

-- src/gymmick_init.c::InitAzaleaGym and src/field/gymmick/azalea.c:spinarakInitialPositions.
GymMechanismState.AZALEA_INITIAL_ENDPOINTS = { 0, 1, 2, 7 }
GymMechanismState.ENDPOINT_COUNT = 12

-- The source switches are the only two the gym carries; anything else is the
-- source assertion (GF_ASSERT(FALSE)) and therefore a fault here.
GymMechanismState.FIRST_SWITCH = 0
GymMechanismState.LAST_SWITCH = 1

local KINDS = {
  [GymMechanismState.NONE] = true,
  [GymMechanismState.VIOLET] = true,
  [GymMechanismState.AZALEA] = true,
}

---@param message string
---@param context table<string, unknown>?
local function fail(message, context)
  Errors.raise(FieldErrors.FIELD_GYM_MECHANISM_INVALID, message, context or {})
end

---@param value unknown
---@return boolean
local function isInteger(value)
  return type(value) == "number" and value % 1 == 0
end

local function checkNoUnknownFields(record, allowed, where)
  for key in pairs(record) do
    if not allowed[key] then
      fail(where .. " carries an unknown field", { field = tostring(key) })
    end
  end
end

---@param endpoints unknown
---@return integer[]
local function checkEndpoints(endpoints)
  if type(endpoints) ~= "table" or #endpoints ~= GymMechanismState.SPIDER_SLOTS then
    fail("azalea endpoints must be one node per spider slot", { endpoints = tostring(endpoints) })
  end
  assert(type(endpoints) == "table", "endpoint validation reads the spider slots")
  local copy = {}
  local seen = {}
  for slot = 1, GymMechanismState.SPIDER_SLOTS do
    local endpoint = endpoints[slot]
    if not isInteger(endpoint) or endpoint < 0 or endpoint >= GymMechanismState.ENDPOINT_COUNT then
      fail("azalea endpoint is outside the source node range", { slot = slot, endpoint = tostring(endpoint) })
    end
    assert(isInteger(endpoint), "endpoint range validation requires an integer")
    if seen[endpoint] then
      fail("two spiders cannot stand on one endpoint", { endpoint = endpoint })
    end
    seen[endpoint] = true
    copy[slot] = endpoint
  end
  return copy
end

---@param data unknown
---@return table<string, unknown>
local function checkVioletData(data)
  if type(data) ~= "table" then
    fail("violet mechanism data must be a record", {})
  end
  assert(type(data) == "table", "violet data validation reads the record")
  if type(data.raised) ~= "boolean" then
    fail("violet raised flag must be a boolean", { raised = tostring(data.raised) })
  end
  checkNoUnknownFields(data, { raised = true }, "violet mechanism data")
  return { raised = data.raised }
end

---@param data unknown
---@return table<string, unknown>
local function checkAzaleaData(data)
  if type(data) ~= "table" then
    fail("azalea mechanism data must be a record", {})
  end
  assert(type(data) == "table", "azalea data validation reads the record")
  local switchMask = data.switchMask
  if not isInteger(switchMask) or switchMask < 0 or switchMask > GymMechanismState.SWITCH_MASK_MAX then
    fail("azalea switch mask is outside the source bit range", { switchMask = tostring(switchMask) })
  end
  assert(isInteger(switchMask), "switch mask validation requires an integer")
  checkNoUnknownFields(data, { endpoints = true, switchMask = true }, "azalea mechanism data")
  return { endpoints = checkEndpoints(data.endpoints), switchMask = switchMask }
end

---@param kind unknown
---@param data unknown
---@return table<string, unknown> detached record
local function checkUnion(kind, data)
  if type(kind) ~= "string" or not KINDS[kind] then
    fail("gym mechanism kind is not one of the port's closed kinds", { kind = tostring(kind) })
  end
  if kind == GymMechanismState.NONE then
    if type(data) ~= "table" then
      fail("an inactive gym union carries an empty data record", {})
    end
    assert(type(data) == "table", "inactive data validation reads the record")
    checkNoUnknownFields(data, {}, "inactive gym mechanism data")
    return {}
  end
  if kind == GymMechanismState.VIOLET then
    return checkVioletData(data)
  end
  return checkAzaleaData(data)
end

---@param bucket unknown
---@return GymMechanismState
function GymMechanismState.restore(bucket)
  if bucket == nil then
    return setmetatable({ _kind = GymMechanismState.NONE, _data = {} }, GymMechanismState)
  end
  if type(bucket) ~= "table" then
    fail("gym mechanism bucket must be a record", {})
  end
  assert(type(bucket) == "table", "bucket validation reads the record")
  if bucket.schema ~= GymMechanismState.SCHEMA then
    fail("gym mechanism bucket schema must be " .. GymMechanismState.SCHEMA, { schema = tostring(bucket.schema) })
  end
  checkNoUnknownFields(bucket, { schema = true, kind = true, data = true }, "gym mechanism bucket")
  local data = checkUnion(bucket.kind, bucket.data)
  return setmetatable({ _kind = bucket.kind, _data = data }, GymMechanismState)
end

-- The source Save_Gymmick_Init: clear the union and install one kind's own
-- defaults. Every other kind's settled data is dropped.
---@param kind string
function GymMechanismState:initialize(kind)
  self._kind = kind
  self._data = checkUnion(kind, kind == GymMechanismState.AZALEA and {
    endpoints = GymMechanismState.AZALEA_INITIAL_ENDPOINTS,
    switchMask = 0,
  } or (kind == GymMechanismState.VIOLET and { raised = false } or {}))
end

---@return string
function GymMechanismState:kind()
  return self._kind
end

---@param expected string
local function requireKind(self, expected)
  if self._kind ~= expected then
    fail("the active gym mechanism is not " .. expected, { kind = self._kind })
  end
end

---@return boolean
function GymMechanismState:violetRaised()
  requireKind(self, GymMechanismState.VIOLET)
  local raised = self._data.raised
  assert(type(raised) == "boolean", "a violet union always carries its raised flag")
  return raised
end

---@param raised boolean
function GymMechanismState:setVioletRaised(raised)
  requireKind(self, GymMechanismState.VIOLET)
  if type(raised) ~= "boolean" then
    fail("violet raised flag must be a boolean", { raised = tostring(raised) })
  end
  self._data.raised = raised
end

---@return integer[]
function GymMechanismState:spiderEndpoints()
  requireKind(self, GymMechanismState.AZALEA)
  local endpoints = assert(self._data.endpoints, "an azalea union always carries its endpoints") --[[@as integer[] ]]
  return { endpoints[1], endpoints[2], endpoints[3], endpoints[4] }
end

---@param endpoint integer
---@return integer? spiderSlot one-based spider slot standing on that endpoint
function GymMechanismState:spiderAtEndpoint(endpoint)
  requireKind(self, GymMechanismState.AZALEA)
  if not isInteger(endpoint) or endpoint < 0 or endpoint >= GymMechanismState.ENDPOINT_COUNT then
    fail("azalea endpoint selector is outside the source node range", { endpoint = tostring(endpoint) })
  end
  assert(isInteger(endpoint), "endpoint lookup requires an integer")
  local endpoints = assert(self._data.endpoints, "an azalea union always carries its endpoints") --[[@as integer[] ]]
  for slot = 1, GymMechanismState.SPIDER_SLOTS do
    if endpoints[slot] == endpoint then
      return slot
    end
  end
  return nil
end

---@param slot integer one-based spider slot
---@param endpoint integer
function GymMechanismState:setSpiderEndpoint(slot, endpoint)
  requireKind(self, GymMechanismState.AZALEA)
  if not isInteger(slot) or slot < 1 or slot > GymMechanismState.SPIDER_SLOTS then
    fail("azalea spider slot is outside the source quartet", { slot = tostring(slot) })
  end
  if not isInteger(endpoint) or endpoint < 0 or endpoint >= GymMechanismState.ENDPOINT_COUNT then
    fail("azalea endpoint is outside the source node range", { endpoint = tostring(endpoint) })
  end
  assert(isInteger(slot) and isInteger(endpoint), "endpoint writes require integers")
  local endpoints = assert(self._data.endpoints, "an azalea union always carries its endpoints") --[[@as integer[] ]]
  for other = 1, GymMechanismState.SPIDER_SLOTS do
    if other ~= slot and endpoints[other] == endpoint then
      fail("two spiders cannot stand on one endpoint", { endpoint = endpoint })
    end
  end
  endpoints[slot] = endpoint
end

---@return integer
function GymMechanismState:switchMask()
  requireKind(self, GymMechanismState.AZALEA)
  local mask = self._data.switchMask
  assert(isInteger(mask), "an azalea union always carries its switch mask")
  return mask
end

-- FlipAzaleaGymSwitch: switch 0 owns bit 0 and switch 1 bit 1.
---@param switchNumber integer
function GymMechanismState:toggleSwitch(switchNumber)
  requireKind(self, GymMechanismState.AZALEA)
  if switchNumber ~= GymMechanismState.FIRST_SWITCH and switchNumber ~= GymMechanismState.LAST_SWITCH then
    fail("azalea switch selector is outside the source pair", { switchNumber = tostring(switchNumber) })
  end
  local mask = self:switchMask()
  local bit = 2 ^ switchNumber
  local flipped = (math.floor(mask / bit) % 2) == 1 and mask - bit or mask + bit
  self._data.switchMask = flipped
end

---@return table<string, unknown> detached bucket
function GymMechanismState:capture()
  return {
    schema = GymMechanismState.SCHEMA,
    kind = self._kind,
    data = checkUnion(self._kind, self._data),
  }
end

return GymMechanismState
