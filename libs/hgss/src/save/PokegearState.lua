-- The single durable owner for gear-companion facts: registered cards and
-- preferences, phone contacts with pending rewards and triggers, four-slot
-- map markings, the civil calendar checkpoint with its shared daily seeds,
-- and the persisted draw-stream state. All mutations validate before
-- assignment, advance one revision per successful mutation, and return
-- detached records; staged candidates publish synchronously without
-- yielding. Pure domain module: no love dependency.

local Errors = require("libs.errors.src.Errors")
local U32 = require("libs.codec.src.U32")
local bit = require("bit")

---@class PokegearState
---@field private _data table<string, unknown>
---@field private _contacts table<string, boolean>
---@field private _locations table<string, boolean>
---@field private _revision integer
local PokegearState = {}
PokegearState.__index = PokegearState

PokegearState.SCHEMA = "hgss-pokegear-v1"
PokegearState.STATE_VERSION = 1

local CODE = "POKEGEAR_STATE_INVALID"
local STALE_CODE = "POKEGEAR_STALE_CANDIDATE"

local LAST_APPS = {
  phone = true,
  map = true,
  radio = true,
  configure = true,
}

local CARDS = {
  phone = true,
  map = true,
  radio = true,
}

local PREFERENCES = {
  lastApp = true,
  skin = true,
  unlockedSkins = true,
  mapUnlockLevel = true,
  mapZoomed = true,
  radioCursor = true,
}

local TOP_FIELDS = {
  schema = true,
  stateVersion = true,
  lastApp = true,
  skin = true,
  unlockedSkins = true,
  registeredCards = true,
  mapUnlockLevel = true,
  mapZoomed = true,
  radioCursor = true,
  contactOrder = true,
  markings = true,
  phone = true,
  calendar = true,
  random = true,
}

local PHONE_FIELDS = {
  contacts = true,
  triggers = true,
  history = true,
  rematches = true,
  mom = true,
  kenji = true,
}

local CALENDAR_FIELDS = {
  checkpoint = true,
  daySerial = true,
  dailyGroupSeed = true,
  outbreakSeed = true,
}

local MAX_MARKING_LOCATIONS = 100
local MARKING_SLOTS = 4
local MAX_ICON = 9
local MAX_MOM_GIFTS = 5

local MT_N = 624
local MT_INIT_MULTIPLIER = 1812433253

local PRANDOM_MULTIPLIER = 1812433253

-- The deterministic seed behind a fresh companion bucket when no session
-- seed is supplied. Fixed so companion state never depends on host time.
local DEFAULT_SEED = 1

---@param value number
---@return integer
local function toU32(value)
  if value < 0 then
    return math.floor(value + U32.MOD)
  end
  return math.floor(value)
end

---@param message string
---@param context table<string, unknown>?
local function fail(message, context)
  Errors.raise(CODE, message, context or {})
end

---@param value unknown
---@return boolean
local function isU32(value)
  return type(value) == "number" and value % 1 == 0 and value >= 0 and value <= U32.MAX
end

---@param value unknown
---@param what string
local function checkU32(value, what)
  if not isU32(value) then
    fail("pokegear " .. what .. " must be an unsigned 32-bit integer", {})
  end
end

---@param value unknown
---@param what string
local function checkIndex(value, what)
  if type(value) ~= "number" or value % 1 ~= 0 or value < 0 then
    fail("pokegear " .. what .. " must be a non-negative integer", {})
  end
end

---@param value unknown
---@return unknown
local function detach(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for key, child in pairs(value) do
    out[key] = detach(child)
  end
  return out
end

---@param seed integer
---@return table<integer, integer> the initialized source state array
local function initMtState(seed)
  assert(isU32(seed), "companion draw state starts from an unsigned 32-bit seed")
  local state = { seed }
  for index = 1, MT_N - 1 do
    local previous = state[index]
    assert(type(previous) == "number", "companion draw state initializes in order")
    local mixed = toU32(bit.bxor(previous, bit.rshift(previous, 30)))
    state[index + 1] = U32.add(U32.mul(MT_INIT_MULTIPLIER, mixed), index)
  end
  return state
end

-- Builds the detached initial draw-stream bucket both the save owner and
-- the live draw adapter start from, so the source recurrence is
-- initialized once. The twist/temper/draw behaviour stays with the live
-- adapter; this owner only carries scalar state.
---@param seed integer
---@return table<string, unknown>
function PokegearState.freshRandom(seed)
  checkU32(seed, "draw seed")
  return {
    lc = { state = seed, calls = 0 },
    mt = { index = MT_N, state = initMtState(seed) },
  }
end

-- Validates a draw-stream snapshot, returning its canonical detached copy.
-- Unknown or malformed persisted draw state fails instead of drawing.
---@param snapshot unknown
---@return table<string, unknown>
function PokegearState.validateRandomBucket(snapshot)
  if type(snapshot) ~= "table" then
    fail("pokegear draw state must be a table", {})
  end
  assert(type(snapshot) == "table", "draw validation reads the snapshot record")
  for key in pairs(snapshot) do
    if key ~= "lc" and key ~= "mt" then
      fail("pokegear draw state contains an unknown field", { field = key })
    end
  end
  local lc = snapshot.lc
  if type(lc) ~= "table" then
    fail("pokegear draw state carries no linear stream", {})
  end
  assert(type(lc) == "table", "draw validation reads the linear stream")
  for key in pairs(lc) do
    if key ~= "state" and key ~= "calls" then
      fail("pokegear linear stream contains an unknown field", { field = key })
    end
  end
  if not isU32(lc.state) then
    fail("pokegear linear stream state must be an unsigned 32-bit integer", {})
  end
  checkIndex(lc.calls, "linear stream call count")
  local mt = snapshot.mt
  if type(mt) ~= "table" then
    fail("pokegear draw state carries no source stream", {})
  end
  assert(type(mt) == "table", "draw validation reads the source stream")
  for key in pairs(mt) do
    if key ~= "index" and key ~= "state" then
      fail("pokegear source stream contains an unknown field", { field = key })
    end
  end
  if type(mt.index) ~= "number" or mt.index % 1 ~= 0 or mt.index < 0 or mt.index > MT_N then
    fail("pokegear source stream position must lie within its state array", {})
  end
  if type(mt.state) ~= "table" then
    fail("pokegear source stream carries no state array", {})
  end
  assert(type(mt.state) == "table", "draw validation reads the state array")
  local count = 0
  for key in pairs(mt.state) do
    count = count + 1
    if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > MT_N then
      fail("pokegear source state must hold exactly its indexed entries", {})
    end
  end
  if count ~= MT_N then
    fail("pokegear source state must hold exactly its indexed entries", { count = count })
  end
  for index = 1, MT_N do
    if not isU32(mt.state[index]) then
      fail("pokegear source state entries must be unsigned 32-bit integers", { index = index })
    end
  end
  return detach(snapshot)
end

---@param refs unknown
---@return table<string, boolean> contactKeys, table<string, boolean> locationKeys
local function checkCatalogRefs(refs)
  if type(refs) ~= "table" or type(refs.catalog) ~= "table" then
    fail("pokegear validation requires contact and location reference sets", {})
  end
  assert(type(refs) == "table" and type(refs.catalog) == "table", "reference validation reads the catalog")
  local catalog = refs.catalog
  assert(type(catalog) == "table", "reference validation reads the catalog record")
  if type(catalog.contacts) ~= "table" or type(catalog.locations) ~= "table" then
    fail("pokegear validation requires contact and location reference sets", {})
  end
  local contacts, locations = {}, {}
  for _, contact in ipairs(catalog.contacts) do
    if type(contact) ~= "table" or type(contact.key) ~= "string" or contact.key == "" then
      fail("pokegear contact references must carry semantic keys", {})
    end
    contacts[contact.key] = true
  end
  for _, location in ipairs(catalog.locations) do
    if type(location) ~= "table" or type(location.key) ~= "string" or location.key == "" then
      fail("pokegear location references must carry semantic keys", {})
    end
    locations[location.key] = true
  end
  return contacts, locations
end

---@param value unknown
---@param what string
local function checkSemanticKey(value, what)
  if type(value) ~= "string" or value == "" then
    fail("pokegear " .. what .. " must carry a semantic key", {})
  end
end

---@param reward unknown
---@return table<string, unknown>?
local function checkReward(reward)
  if reward == nil then
    return nil
  end
  if type(reward) ~= "table" then
    fail("pokegear contact reward must be an item record", {})
  end
  assert(type(reward) == "table", "reward validation reads the reward record")
  for key in pairs(reward) do
    if key ~= "item" and key ~= "quantity" then
      fail("pokegear contact reward contains an unknown field", { field = key })
    end
  end
  if type(reward.item) ~= "string" or reward.item == "" then
    fail("pokegear contact reward carries no item", {})
  end
  if type(reward.quantity) ~= "number" or reward.quantity % 1 ~= 0 or reward.quantity < 1 then
    fail("pokegear contact reward quantity must be a positive integer", {})
  end
  return { item = reward.item, quantity = reward.quantity }
end

---@param marking unknown
---@return table<string, unknown>
local function checkMarking(marking)
  if type(marking) ~= "table" then
    fail("pokegear marking must carry icon and word slots", {})
  end
  assert(type(marking) == "table", "marking validation reads the marking record")
  for key in pairs(marking) do
    if key ~= "icons" and key ~= "words" then
      fail("pokegear marking contains an unknown field", { field = key })
    end
  end
  local icons, words = marking.icons, marking.words
  if type(icons) ~= "table" or type(words) ~= "table" then
    fail("pokegear marking must carry icon and word slots", {})
  end
  assert(type(icons) == "table" and type(words) == "table", "marking validation reads both slot lists")
  for _, slot in ipairs({ "icons", "words" }) do
    local count = 0
    for _ in pairs(marking[slot]) do
      count = count + 1
    end
    if count ~= MARKING_SLOTS then
      fail("pokegear marking must carry exactly four " .. slot .. " slots", {})
    end
  end
  local cleanIcons = {}
  for index = 1, MARKING_SLOTS do
    local entry = icons[index]
    if entry ~= false then
      if type(entry) ~= "number" or entry % 1 ~= 0 or entry < 1 or entry > MAX_ICON then
        fail("pokegear icon slots carry native icon identities or the empty sentinel", { index = index })
      end
      cleanIcons[index] = entry
    else
      cleanIcons[index] = false
    end
  end
  local cleanWords = {}
  for index = 1, MARKING_SLOTS do
    local entry = words[index]
    if entry ~= false then
      if type(entry) ~= "string" or entry == "" then
        fail("pokegear word slots carry word keys or the empty sentinel", { index = index })
      end
      cleanWords[index] = entry
    else
      cleanWords[index] = false
    end
  end
  return { icons = cleanIcons, words = cleanWords }
end

---@param value unknown
---@return table<integer, integer> the canonical skin list
local function checkUnlockedSkins(value)
  if type(value) ~= "table" then
    fail("pokegear unlocked skins must be a list", {})
  end
  assert(type(value) == "table", "skin validation reads the skin list")
  local count = 0
  for _ in pairs(value) do
    count = count + 1
  end
  if count == 0 then
    fail("pokegear unlocked skins must grant at least one skin", {})
  end
  local seen, clean = {}, {}
  for index = 1, count do
    local skin = value[index]
    if type(skin) ~= "number" or skin % 1 ~= 0 or skin < 0 or skin > 5 or seen[skin] then
      fail("pokegear unlocked skins must list distinct source skin identities", {})
    end
    seen[skin] = true
    clean[index] = skin
  end
  return clean
end

---@param value unknown
---@return table<string, integer> the canonical tuner position
local function checkRadioCursor(value)
  if type(value) ~= "table" then
    fail("pokegear tuner position must be a record", {})
  end
  assert(type(value) == "table", "cursor validation reads the tuner position")
  for key in pairs(value) do
    if key ~= "x" and key ~= "y" then
      fail("pokegear tuner position contains an unknown field", { field = key })
    end
  end
  if
    type(value.x) ~= "number"
    or value.x % 1 ~= 0
    or value.x < 0
    or value.x > 255
    or type(value.y) ~= "number"
    or value.y % 1 ~= 0
    or value.y < 0
    or value.y > 255
  then
    fail("pokegear tuner coordinates must be integral dial positions", {})
  end
  return { x = value.x, y = value.y }
end

---@param moment unknown
---@return table<string, integer>?
local function checkCivil(moment)
  if moment == nil then
    return nil
  end
  if type(moment) ~= "table" then
    fail("pokegear calendar checkpoint must be a civil record", {})
  end
  assert(type(moment) == "table", "checkpoint validation reads the civil record")
  for key in pairs(moment) do
    if key ~= "year" and key ~= "month" and key ~= "day" and key ~= "hour" and key ~= "minute" and key ~= "second" then
      fail("pokegear calendar checkpoint contains an unknown field", { field = key })
    end
  end
  local fields = { "year", "month", "day", "hour", "minute", "second" }
  for _, key in ipairs(fields) do
    if type(moment[key]) ~= "number" or moment[key] % 1 ~= 0 then
      fail("pokegear calendar checkpoint carries integral civil fields", { field = key })
    end
  end
  assert(
    type(moment.year) == "number"
      and type(moment.month) == "number"
      and type(moment.day) == "number"
      and type(moment.hour) == "number"
      and type(moment.minute) == "number"
      and type(moment.second) == "number",
    "checkpoint validation reads civil fields"
  )
  if moment.year < 1 or moment.month < 1 or moment.month > 12 then
    fail("pokegear calendar checkpoint carries an invalid civil date", {})
  end
  local leap = moment.year % 4 == 0 and (moment.year % 100 ~= 0 or moment.year % 400 == 0)
  local monthDays = { 31, leap and 29 or 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
  if moment.day < 1 or moment.day > monthDays[moment.month] then
    fail("pokegear calendar checkpoint carries an invalid civil date", {})
  end
  if moment.hour < 0 or moment.hour > 23 or moment.minute < 0 or moment.minute > 59 then
    fail("pokegear calendar checkpoint carries an invalid civil time", {})
  end
  if moment.second < 0 or moment.second > 59 then
    fail("pokegear calendar checkpoint carries an invalid civil time", {})
  end
  return {
    year = moment.year,
    month = moment.month,
    day = moment.day,
    hour = moment.hour,
    minute = moment.minute,
    second = moment.second,
  }
end

---@param mom unknown
---@return table<string, unknown> the canonical savings record
local function checkMom(mom)
  if type(mom) ~= "table" then
    fail("pokegear savings state must be a record", {})
  end
  assert(type(mom) == "table", "savings validation reads the savings state")
  for key in pairs(mom) do
    if key ~= "balance" and key ~= "purchases" and key ~= "gifts" then
      fail("pokegear savings state contains an unknown field", { field = key })
    end
  end
  if type(mom.balance) ~= "number" or mom.balance % 1 ~= 0 or mom.balance < 0 then
    fail("pokegear savings balance must be a non-negative integer", {})
  end
  local purchases = mom.purchases
  if type(purchases) ~= "table" then
    fail("pokegear savings purchases and gifts must be records", {})
  end
  assert(type(purchases) == "table", "savings validation reads claimed purchase flags")
  local cleanFlags = {}
  for flag, claimed in pairs(purchases) do
    if type(flag) ~= "string" or flag == "" or claimed ~= true then
      fail("pokegear savings purchases carry claimed item flags", { flag = flag })
    end
    cleanFlags[flag] = true
  end
  local gifts = mom.gifts
  if type(gifts) ~= "table" then
    fail("pokegear savings purchases and gifts must be records", {})
  end
  assert(type(gifts) == "table", "savings validation reads the gift queue")
  local count = 0
  for _ in pairs(gifts) do
    count = count + 1
  end
  if count > MAX_MOM_GIFTS then
    fail("pokegear savings gifts hold at most five entries", { count = count })
  end
  local cleanGifts = {}
  for index = 1, count do
    cleanGifts[index] = checkReward(gifts[index])
    if cleanGifts[index] == nil then
      fail("pokegear savings gifts carry item records", { index = index })
    end
  end
  return { balance = mom.balance, purchases = cleanFlags, gifts = cleanGifts }
end

---@param data table<string, unknown>
---@param contacts table<string, boolean>
---@param locations table<string, boolean>
local function checkRestorable(data, contacts, locations)
  for key in pairs(data) do
    if TOP_FIELDS[key] ~= true then
      fail("pokegear state contains an unknown field", { field = key })
    end
  end
  if data.schema ~= PokegearState.SCHEMA then
    fail("pokegear schema must be " .. PokegearState.SCHEMA, { schema = data.schema })
  end
  if data.stateVersion ~= PokegearState.STATE_VERSION then
    fail("pokegear state version must be " .. PokegearState.STATE_VERSION, { stateVersion = data.stateVersion })
  end
  if LAST_APPS[data.lastApp] ~= true then
    fail("pokegear application must be a known companion application", { lastApp = data.lastApp })
  end
  if type(data.skin) ~= "number" or data.skin % 1 ~= 0 or data.skin < 0 or data.skin > 5 then
    fail("pokegear skin must be a source skin identity", {})
  end
  data.unlockedSkins = checkUnlockedSkins(data.unlockedSkins)
  if type(data.registeredCards) ~= "table" then
    fail("pokegear registered cards must be a record", {})
  end
  assert(type(data.registeredCards) == "table", "restoration reads the card set")
  for key, value in pairs(data.registeredCards) do
    if CARDS[key] ~= true or value ~= true then
      fail("pokegear registered cards carry only acquired card bits", { card = key })
    end
  end
  if data.registeredCards.phone ~= true then
    fail("pokegear registered cards always carry the base companion card", {})
  end
  if type(data.mapUnlockLevel) ~= "number" or data.mapUnlockLevel % 1 ~= 0 or data.mapUnlockLevel < 0 then
    fail("pokegear map tier must be a non-negative integer", {})
  end
  if type(data.mapZoomed) ~= "boolean" then
    fail("pokegear map zoom must be a boolean", {})
  end
  data.radioCursor = checkRadioCursor(data.radioCursor)
  if type(data.contactOrder) ~= "table" then
    fail("pokegear contact order must be a list", {})
  end
  assert(type(data.contactOrder) == "table", "restoration reads the contact order")
  do
    local order = data.contactOrder
    assert(type(order) == "table", "restoration counts the contact order")
    local count = 0
    for _ in pairs(order) do
      count = count + 1
    end
    local seen = {}
    for index = 1, count do
      local contactKey = order[index]
      if type(contactKey) ~= "string" then
        fail("pokegear contact order carries contact keys", {})
      end
      if contacts[contactKey] ~= true then
        fail("pokegear contact order references missing contact " .. contactKey, { key = contactKey })
      end
      if seen[contactKey] then
        fail("pokegear contact order repeats a contact", { key = contactKey })
      end
      seen[contactKey] = true
    end
  end
  if type(data.markings) ~= "table" then
    fail("pokegear markings must be a record", {})
  end
  assert(type(data.markings) == "table", "restoration reads the markings")
  do
    local count = 0
    for locationKey, marking in pairs(data.markings) do
      count = count + 1
      if locations[locationKey] ~= true then
        fail("pokegear markings reference missing location " .. tostring(locationKey), { key = locationKey })
      end
      data.markings[locationKey] = checkMarking(marking)
    end
    if count > MAX_MARKING_LOCATIONS then
      fail("pokegear markings hold at most one hundred locations", { count = count })
    end
  end
  if type(data.phone) ~= "table" then
    fail("pokegear phone state must be a record", {})
  end
  assert(type(data.phone) == "table", "restoration reads the phone state")
  local phone = data.phone
  assert(type(phone) == "table", "restoration reads phone fields")
  for key in pairs(phone) do
    if PHONE_FIELDS[key] ~= true then
      fail("pokegear phone state contains an unknown field", { field = key })
    end
  end
  if type(phone.contacts) ~= "table" then
    fail("pokegear phone contacts must be a record", {})
  end
  assert(type(phone.contacts) == "table", "restoration reads phone contacts")
  for _, contactKey in ipairs(data.contactOrder) do
    if phone.contacts[contactKey] == nil then
      fail("pokegear contact order references an unregistered contact " .. contactKey, { key = contactKey })
    end
  end
  for contactKey, entry in pairs(phone.contacts) do
    if contacts[contactKey] ~= true then
      fail("pokegear phone contacts reference missing contact " .. tostring(contactKey), { key = contactKey })
    end
    local ordered = false
    for _, orderedKey in ipairs(data.contactOrder) do
      if orderedKey == contactKey then
        ordered = true
        break
      end
    end
    if not ordered then
      fail("pokegear phone contacts stay in registration order", { key = contactKey })
    end
    if type(entry) ~= "table" then
      fail("pokegear phone contact must be a record", { key = contactKey })
    end
    assert(type(entry) == "table", "restoration reads contact entries")
    for key in pairs(entry) do
      if key ~= "reward" then
        fail("pokegear phone contact contains an unknown field", { key = contactKey, field = key })
      end
    end
    if entry.reward ~= nil then
      entry.reward = checkReward(entry.reward)
    end
  end
  if type(phone.triggers) ~= "table" then
    fail("pokegear phone triggers must be a record", {})
  end
  assert(type(phone.triggers) == "table", "restoration reads phone triggers")
  for key, value in pairs(phone.triggers) do
    if type(key) ~= "string" or key == "" or value ~= true then
      fail("pokegear phone triggers carry only active trigger keys", { key = key })
    end
  end
  if type(phone.history) ~= "table" or type(phone.rematches) ~= "table" then
    fail("pokegear phone history and rematch state must be records", {})
  end
  assert(type(phone.history) == "table" and type(phone.rematches) == "table", "restoration reads phone journals")
  for key, entry in pairs(phone.rematches) do
    if type(key) ~= "string" or key == "" or type(entry) ~= "table" then
      fail("pokegear rematch state carries challenger records", { key = key })
    end
    assert(type(entry) == "table", "restoration reads rematch entries")
    for field in pairs(entry) do
      if field ~= "stage" and field ~= "wins" then
        fail("pokegear rematch entry contains an unknown field", { key = key, field = field })
      end
    end
    if
      type(entry.stage) ~= "number"
      or entry.stage % 1 ~= 0
      or entry.stage < 0
      or type(entry.wins) ~= "number"
      or entry.wins % 1 ~= 0
      or entry.wins < 0
    then
      fail("pokegear rematch entry carries non-negative counters", { key = key })
    end
  end
  phone.mom = checkMom(phone.mom)
  if type(phone.kenji) ~= "table" then
    fail("pokegear caller counters must be a record", {})
  end
  assert(type(phone.kenji) == "table", "restoration reads caller counters")
  for key in pairs(phone.kenji) do
    if key ~= "calls" then
      fail("pokegear caller counters contain an unknown field", { field = key })
    end
  end
  if type(phone.kenji.calls) ~= "number" or phone.kenji.calls % 1 ~= 0 or phone.kenji.calls < 0 then
    fail("pokegear caller counters must be non-negative integers", {})
  end
  if type(data.calendar) ~= "table" then
    fail("pokegear calendar state must be a record", {})
  end
  assert(type(data.calendar) == "table", "restoration reads the calendar state")
  for key in pairs(data.calendar) do
    if CALENDAR_FIELDS[key] ~= true then
      fail("pokegear calendar state contains an unknown field", { field = key })
    end
  end
  data.calendar.checkpoint = checkCivil(data.calendar.checkpoint)
  if data.calendar.daySerial ~= nil then
    if type(data.calendar.daySerial) ~= "number" or data.calendar.daySerial % 1 ~= 0 then
      fail("pokegear calendar day must be an integral day serial", {})
    end
  end
  if (data.calendar.checkpoint == nil) ~= (data.calendar.daySerial == nil) then
    fail("pokegear calendar checkpoint and day advance together", {})
  end
  checkU32(data.calendar.dailyGroupSeed, "daily group seed")
  checkU32(data.calendar.outbreakSeed, "outbreak seed")
  data.random = PokegearState.validateRandomBucket(data.random)
end

---@param seed integer
---@param dailyGroupSeed integer?
---@param outbreakSeed integer?
---@return table<string, unknown> calendar defaults with deterministic seeds
local function defaultCalendar(seed, dailyGroupSeed, outbreakSeed)
  local group = dailyGroupSeed
  if group == nil then
    group = U32.add(U32.mul(seed, PRANDOM_MULTIPLIER), 1)
  end
  local outbreak = outbreakSeed
  if outbreak == nil then
    outbreak = U32.add(U32.mul(group, PRANDOM_MULTIPLIER), 1)
  end
  return {
    checkpoint = nil,
    daySerial = nil,
    dailyGroupSeed = group,
    outbreakSeed = outbreak,
  }
end

---@param seed integer
---@return table<string, unknown> source defaults with deterministic seeds
local function defaults(seed)
  return {
    schema = PokegearState.SCHEMA,
    stateVersion = PokegearState.STATE_VERSION,
    lastApp = "phone",
    skin = 0,
    unlockedSkins = { 0 },
    registeredCards = { phone = true },
    mapUnlockLevel = 0,
    mapZoomed = false,
    radioCursor = { x = 128, y = 128 },
    contactOrder = {},
    markings = {},
    phone = {
      contacts = {},
      triggers = {},
      history = {},
      rematches = {},
      mom = { balance = 0, purchases = {}, gifts = {} },
      kenji = { calls = 0 },
    },
    calendar = defaultCalendar(seed),
    random = PokegearState.freshRandom(seed),
  }
end

---@param data table<string, unknown>
---@param contacts table<string, boolean>
---@param locations table<string, boolean>
---@return PokegearState
local function build(data, contacts, locations)
  return setmetatable({ _data = data, _contacts = contacts, _locations = locations, _revision = 0 }, PokegearState)
end

-- Creates the source-default companion bucket, optionally seeded from the
-- save/session seed boundary. Reference sets only validate construction;
-- the state never retains the borrowed catalog.
---@param initial { seed: integer?, dailyGroupSeed: integer?, outbreakSeed: integer? }?
---@param refs { catalog: table<string, unknown> }?
---@return PokegearState
function PokegearState.new(initial, refs)
  local seed, dailyGroupSeed, outbreakSeed = DEFAULT_SEED, nil, nil
  if initial ~= nil then
    if type(initial) ~= "table" then
      fail("pokegear initial state must be a record", {})
    end
    for key in pairs(initial) do
      if key ~= "seed" and key ~= "dailyGroupSeed" and key ~= "outbreakSeed" then
        fail("pokegear initial state contains an unknown field", { field = key })
      end
    end
    if initial.seed ~= nil then
      checkU32(initial.seed, "initial seed")
      assert(type(initial.seed) == "number", "initial seeds stay unsigned integers")
      seed = math.floor(initial.seed)
    end
    if initial.dailyGroupSeed ~= nil then
      checkU32(initial.dailyGroupSeed, "daily group seed")
      assert(type(initial.dailyGroupSeed) == "number", "initial seeds stay unsigned integers")
      dailyGroupSeed = math.floor(initial.dailyGroupSeed)
    end
    if initial.outbreakSeed ~= nil then
      checkU32(initial.outbreakSeed, "outbreak seed")
      assert(type(initial.outbreakSeed) == "number", "initial seeds stay unsigned integers")
      outbreakSeed = math.floor(initial.outbreakSeed)
    end
  end
  local contacts, locations = {}, {}
  if refs ~= nil then
    contacts, locations = checkCatalogRefs(refs)
  end
  local data = defaults(seed)
  data.calendar = defaultCalendar(seed, dailyGroupSeed, outbreakSeed)
  return build(data, contacts, locations)
end

-- Restores a persisted bucket exactly: corrupted data fails with its
-- domain, never resets to defaults. Unknown referenced entries fail naming
-- their semantic key; unrelated catalog growth stays compatible.
---@param bucket unknown
---@param refs { catalog: table<string, unknown> }
---@return PokegearState
function PokegearState.restore(bucket, refs)
  if type(bucket) ~= "table" then
    fail("pokegear state must be a table", {})
  end
  assert(type(bucket) == "table", "restoration reads the persisted bucket")
  if refs == nil then
    fail("pokegear restoration requires contact and location reference sets", {})
  end
  local contacts, locations = checkCatalogRefs(refs)
  local data = detach(bucket)
  assert(type(data) == "table", "restoration validates a detached copy")
  checkRestorable(data, contacts, locations)
  return build(data, contacts, locations)
end

---@return table<string, unknown> the detached persisted bucket
function PokegearState:capture()
  return detach(self._data)
end

---@return integer the count of successful mutations so far
function PokegearState:revision()
  return self._revision
end

-- The detached phone projection: registration order, per-contact pending
-- rewards, triggers, journals, savings, and caller counters. Mutating the
-- projection never touches the owner.
---@return table<string, unknown>
function PokegearState:readPhone()
  local data = self._data
  assert(type(data) == "table" and type(data.phone) == "table", "phone reads require restored state")
  local phone = data.phone
  assert(type(phone) == "table", "phone reads copy the phone record")
  return {
    contactOrder = detach(data.contactOrder),
    contacts = detach(phone.contacts),
    triggers = detach(phone.triggers),
    history = detach(phone.history),
    rematches = detach(phone.rematches),
    mom = detach(phone.mom),
    kenji = detach(phone.kenji),
  }
end

-- The detached preference projection: remembered application, skin,
-- map tier/zoom, and tuner position. Mutating it never touches the owner.
---@return table<string, unknown>
function PokegearState:readPreferences()
  local data = self._data
  assert(type(data) == "table", "preference reads require restored state")
  return {
    lastApp = data.lastApp,
    skin = data.skin,
    unlockedSkins = detach(data.unlockedSkins),
    mapUnlockLevel = data.mapUnlockLevel,
    mapZoomed = data.mapZoomed,
    radioCursor = detach(data.radioCursor),
  }
end

-- The detached calendar record: checkpoint, last processed day, and both
-- shared daily seeds. Mutating it never touches the owner.
---@return table<string, unknown>
function PokegearState:readCalendar()
  local data = self._data
  assert(type(data) == "table" and type(data.calendar) == "table", "calendar reads require restored state")
  return detach(data.calendar)
end

-- The detached shared daily identity radio and encounters resolve through:
-- both daily seeds plus the last processed local day.
---@return { dailyGroupSeed: integer, outbreakSeed: integer, daySerial: integer? }
function PokegearState:readDailyIdentity()
  local data = self._data
  assert(type(data) == "table" and type(data.calendar) == "table", "daily reads require restored state")
  local calendar = data.calendar
  assert(type(calendar) == "table", "daily reads copy the calendar record")
  return {
    dailyGroupSeed = calendar.dailyGroupSeed,
    outbreakSeed = calendar.outbreakSeed,
    daySerial = calendar.daySerial,
  }
end

-- Commits the calendar checkpoint and daily identity after a validated
-- observation. One successful commit advances the revision once.
---@param next { checkpoint: table<string, integer>?, daySerial: integer?, dailyGroupSeed: integer, outbreakSeed: integer }
---@return table<string, unknown> the detached state after the commit
function PokegearState:commitCalendar(next)
  if type(next) ~= "table" then
    fail("pokegear calendar update must be a record", {})
  end
  assert(type(next) == "table", "calendar commits read the update record")
  for key in pairs(next) do
    if CALENDAR_FIELDS[key] ~= true then
      fail("pokegear calendar update contains an unknown field", { field = key })
    end
  end
  local checkpoint = checkCivil(next.checkpoint)
  if next.daySerial ~= nil and (type(next.daySerial) ~= "number" or next.daySerial % 1 ~= 0) then
    fail("pokegear calendar day must be an integral day serial", {})
  end
  if (checkpoint == nil) ~= (next.daySerial == nil) then
    fail("pokegear calendar checkpoint and day advance together", {})
  end
  checkU32(next.dailyGroupSeed, "daily group seed")
  checkU32(next.outbreakSeed, "outbreak seed")
  local data = self._data
  assert(type(data) == "table" and type(data.calendar) == "table", "calendar commits require restored state")
  data.calendar = {
    checkpoint = checkpoint,
    daySerial = next.daySerial,
    dailyGroupSeed = next.dailyGroupSeed,
    outbreakSeed = next.outbreakSeed,
  }
  self._revision = self._revision + 1
  return detach(data)
end

-- Internal named mutations below operate on an explicit bucket so the live
-- owner and staged candidates share one implementation. Each validates
-- before assignment and reports whether the bucket changed.

---@param data table<string, unknown>
---@param card unknown
---@return boolean changed
local function applyRegisterCard(data, card)
  if type(card) ~= "string" or CARDS[card] ~= true then
    fail("pokegear card registration names a known companion card, got " .. tostring(card), { card = card })
  end
  assert(type(data) == "table" and type(data.registeredCards) == "table", "card registration reads the card set")
  local cards = data.registeredCards
  assert(type(cards) == "table", "card registration edits the card set")
  if card == "phone" then
    if cards.phone == true and cards.map == nil and cards.radio == nil then
      return false
    end
    data.registeredCards = { phone = true }
    return true
  end
  if cards[card] == true then
    return false
  end
  cards[card] = true
  return true
end

---@param data table<string, unknown>
---@param contacts table<string, boolean>
---@param key unknown
---@return boolean changed
local function applyRegisterContact(data, contacts, key)
  checkSemanticKey(key, "contact registration")
  assert(type(key) == "string", "contact registration reads the contact key")
  if contacts[key] ~= true then
    fail("pokegear contact registration references missing contact " .. key, { key = key })
  end
  assert(type(data) == "table" and type(data.phone) == "table", "contact registration reads phone state")
  local phone = data.phone
  assert(type(phone) == "table" and type(phone.contacts) == "table", "contact registration edits contacts")
  if phone.contacts[key] ~= nil then
    return false
  end
  phone.contacts[key] = {}
  assert(type(data.contactOrder) == "table", "contact registration edits the contact order")
  local order = data.contactOrder
  assert(type(order) == "table", "contact registration appends to the order")
  order[#order + 1] = key
  return true
end

---@param data table<string, unknown>
---@param name unknown
---@param value unknown
---@return boolean changed
local function applySetPreference(data, name, value)
  if type(name) ~= "string" or PREFERENCES[name] ~= true then
    fail("pokegear preference names a known companion preference, got " .. tostring(name), { preference = name })
  end
  assert(type(data) == "table", "preference writes read companion state")
  if name == "lastApp" then
    if type(value) ~= "string" or LAST_APPS[value] ~= true then
      fail("pokegear application must be a known companion application", { lastApp = value })
    end
    if data.lastApp == value then
      return false
    end
    data.lastApp = value
    return true
  elseif name == "skin" then
    if type(value) ~= "number" or value % 1 ~= 0 or value < 0 or value > 5 then
      fail("pokegear skin must be a source skin identity", {})
    end
    if data.skin == value then
      return false
    end
    data.skin = value
    return true
  elseif name == "unlockedSkins" then
    local clean = checkUnlockedSkins(value)
    local count = #clean
    local current = data.unlockedSkins
    assert(type(current) == "table", "preference writes compare the skin list")
    if #current == count then
      local same = true
      for index = 1, count do
        if current[index] ~= clean[index] then
          same = false
          break
        end
      end
      if same then
        return false
      end
    end
    data.unlockedSkins = clean
    return true
  elseif name == "mapUnlockLevel" then
    if type(value) ~= "number" or value % 1 ~= 0 or value < 0 then
      fail("pokegear map tier must be a non-negative integer", {})
    end
    if data.mapUnlockLevel == value then
      return false
    end
    data.mapUnlockLevel = value
    return true
  elseif name == "mapZoomed" then
    if type(value) ~= "boolean" then
      fail("pokegear map zoom must be a boolean", {})
    end
    if data.mapZoomed == value then
      return false
    end
    data.mapZoomed = value
    return true
  else
    assert(name == "radioCursor", "preference writes cover the closed preference set")
    local clean = checkRadioCursor(value)
    local current = data.radioCursor
    assert(type(current) == "table", "preference writes compare the tuner position")
    if current.x == clean.x and current.y == clean.y then
      return false
    end
    data.radioCursor = clean
    return true
  end
end

---@param history unknown
---@return table<string, boolean> the canonical caller set
local function checkCallHistory(history)
  if type(history) ~= "table" then
    fail("pokegear call history must be a caller set", {})
  end
  assert(type(history) == "table", "history writes read the caller set")
  local clean = {}
  for contactKey, value in pairs(history) do
    if type(contactKey) ~= "string" or contactKey == "" or value ~= true then
      fail("pokegear call history carries only called contact keys", { key = contactKey })
    end
    clean[contactKey] = true
  end
  return clean
end

---@param data table<string, unknown>
---@param history unknown
---@return boolean changed
local function applySetCallHistory(data, history)
  local clean = checkCallHistory(history)
  assert(type(data) == "table" and type(data.phone) == "table", "history writes read phone state")
  local phone = data.phone
  assert(type(phone) == "table" and type(phone.history) == "table", "history writes edit the call journal")
  local current = phone.history
  assert(type(current) == "table", "history writes compare the call journal")
  local same = true
  for contactKey in pairs(clean) do
    if current[contactKey] ~= true then
      same = false
      break
    end
  end
  if same then
    for contactKey in pairs(current) do
      if clean[contactKey] ~= true then
        same = false
        break
      end
    end
  end
  if same then
    return false
  end
  phone.history = clean
  return true
end

---@param data table<string, unknown>
---@param savings unknown
---@return boolean changed
local function applySetMom(data, savings)
  local clean = checkMom(savings)
  assert(type(data) == "table" and type(data.phone) == "table", "savings writes read phone state")
  local phone = data.phone
  assert(type(phone) == "table" and type(phone.mom) == "table", "savings writes edit the savings record")
  local current = phone.mom
  assert(type(current) == "table", "savings writes compare the savings record")
  local sameBalance = current.balance == clean.balance
  local sameFlags = true
  local currentPurchases = current.purchases
  assert(type(currentPurchases) == "table", "savings writes compare claimed purchase flags")
  for flag in pairs(clean.purchases) do
    if currentPurchases[flag] ~= true then
      sameFlags = false
      break
    end
  end
  if sameFlags then
    for flag in pairs(currentPurchases) do
      if clean.purchases[flag] ~= true then
        sameFlags = false
        break
      end
    end
  end
  local sameGifts = true
  local currentGifts = current.gifts
  assert(type(currentGifts) == "table", "savings writes compare the gift queue")
  if #currentGifts ~= #clean.gifts then
    sameGifts = false
  else
    for index = 1, #clean.gifts do
      local have = currentGifts[index]
      local want = clean.gifts[index]
      assert(type(have) == "table" and type(want) == "table", "savings writes compare gift entries")
      if have.item ~= want.item or have.quantity ~= want.quantity then
        sameGifts = false
        break
      end
    end
  end
  if sameBalance and sameFlags and sameGifts then
    return false
  end
  phone.mom = clean
  return true
end

---@param data table<string, unknown>
---@param key unknown
---@param active unknown
---@return boolean changed
local function applySetTrigger(data, key, active)
  checkSemanticKey(key, "phone trigger")
  assert(type(key) == "string", "trigger writes read the trigger key")
  if type(active) ~= "boolean" then
    fail("pokegear phone trigger switches a boolean", { key = key })
  end
  assert(type(data) == "table" and type(data.phone) == "table", "trigger writes read phone state")
  local phone = data.phone
  assert(type(phone) == "table" and type(phone.triggers) == "table", "trigger writes edit the trigger set")
  if active then
    if phone.triggers[key] == true then
      return false
    end
    phone.triggers[key] = true
    return true
  end
  if phone.triggers[key] == nil then
    return false
  end
  phone.triggers[key] = nil
  return true
end

---@param data table<string, unknown>
---@param contacts table<string, boolean>
---@param key unknown
---@param reward unknown
---@return boolean changed
local function applySetContactReward(data, contacts, key, reward)
  checkSemanticKey(key, "contact reward")
  assert(type(key) == "string", "reward writes read the contact key")
  if contacts[key] ~= true then
    fail("pokegear contact reward references missing contact " .. key, { key = key })
  end
  assert(type(data) == "table" and type(data.phone) == "table", "reward writes read phone state")
  local phone = data.phone
  assert(type(phone) == "table" and type(phone.contacts) == "table", "reward writes edit contacts")
  local entry = phone.contacts[key]
  if entry == nil then
    fail("pokegear contact reward needs registered contact " .. key, { key = key })
  end
  assert(type(entry) == "table", "reward writes edit the contact entry")
  local clean = checkReward(reward)
  local current = entry.reward
  if clean == nil and current == nil then
    return false
  end
  if clean ~= nil and current ~= nil and current.item == clean.item and current.quantity == clean.quantity then
    return false
  end
  entry.reward = clean
  return true
end

---@param data table<string, unknown>
---@param contacts table<string, boolean>
---@param order unknown
---@return boolean changed
local function applySetContactOrder(data, contacts, order)
  if type(order) ~= "table" then
    fail("pokegear contact order must be a list", {})
  end
  assert(type(order) == "table", "contact order writes read the order list")
  assert(type(data) == "table" and type(data.phone) == "table", "contact order writes read phone state")
  local registered = (data.phone --[[@as table<string, unknown>]]).contacts
  assert(type(registered) == "table", "contact order writes read registered contacts")
  local count = 0
  for _ in pairs(order) do
    count = count + 1
  end
  local seen = {}
  for index = 1, count do
    local contactKey = order[index]
    if type(contactKey) ~= "string" then
      fail("pokegear contact order carries contact keys", {})
    end
    if contacts[contactKey] ~= true then
      fail("pokegear contact order references missing contact " .. contactKey, { key = contactKey })
    end
    if registered[contactKey] == nil then
      fail("pokegear contact order references an unregistered contact " .. contactKey, { key = contactKey })
    end
    if seen[contactKey] then
      fail("pokegear contact order repeats a contact", { key = contactKey })
    end
    seen[contactKey] = true
  end
  for contactKey in
    pairs(registered --[[@as table<string, unknown>]])
  do
    if seen[contactKey] ~= true then
      fail("pokegear phone contacts stay in registration order", { key = contactKey })
    end
  end
  local current = data.contactOrder
  assert(type(current) == "table", "contact order writes read the saved order")
  local same = true
  if #current ~= count then
    same = false
  else
    for index = 1, count do
      if current[index] ~= order[index] then
        same = false
        break
      end
    end
  end
  if same then
    return false
  end
  local clean = {}
  for index = 1, count do
    clean[index] = order[index]
  end
  data.contactOrder = clean
  return true
end

---@param data table<string, unknown>
---@param locations table<string, boolean>
---@param locationKey unknown
---@param marking unknown
---@return boolean changed
local function applySetMarking(data, locations, locationKey, marking)
  checkSemanticKey(locationKey, "map marking")
  assert(type(locationKey) == "string", "marking writes read the location key")
  if locations[locationKey] ~= true then
    fail("pokegear markings reference missing location " .. locationKey, { key = locationKey })
  end
  assert(type(data) == "table" and type(data.markings) == "table", "marking writes read markings")
  local markings = data.markings
  assert(type(markings) == "table", "marking writes edit markings")
  if marking == nil then
    if markings[locationKey] == nil then
      return false
    end
    markings[locationKey] = nil
    return true
  end
  local clean = checkMarking(marking)
  local current = markings[locationKey]
  if current ~= nil then
    assert(type(current) == "table", "marking writes compare marking slots")
    local same = true
    for index = 1, MARKING_SLOTS do
      if current.icons[index] ~= clean.icons[index] or current.words[index] ~= clean.words[index] then
        same = false
        break
      end
    end
    if same then
      return false
    end
  else
    local count = 0
    for _ in pairs(markings) do
      count = count + 1
    end
    if count >= MAX_MARKING_LOCATIONS then
      fail("pokegear markings hold at most one hundred locations", { count = count + 1 })
    end
  end
  markings[locationKey] = clean
  return true
end

---@param changed boolean
---@return table<string, unknown> the detached state after the mutation
function PokegearState:_commit(changed)
  if changed then
    self._revision = self._revision + 1
  end
  return detach(self._data)
end

-- Registers an acquired companion card. Registering the base card clears
-- the optional card bits; registering an optional card adds only that bit.
-- Repeat registration never moves the revision.
---@param card string
---@return table<string, unknown>
function PokegearState:registerCard(card)
  return self:_commit(applyRegisterCard(self._data, card))
end

-- Registers a catalog contact idempotently: the first registration appends
-- in order, a repeat keeps one entry and never moves the revision.
-- Unknown contacts fail naming their key.
---@param key string
---@return table<string, unknown>
function PokegearState:registerContact(key)
  return self:_commit(applyRegisterContact(self._data, self._contacts, key))
end

-- Assigns one closed companion preference after validation. Writing the
-- current value never moves the revision.
---@param name string
---@param value unknown
---@return table<string, unknown>
function PokegearState:setPreference(name, value)
  return self:_commit(applySetPreference(self._data, name, value))
end

-- Replaces the savings record with a validated one: balance, claimed
-- purchase flags, and gift queue. Writing the current record never moves
-- the revision. Reward candidates publish through this operation so the
-- durable owner validates every staged savings write.
---@param savings table<string, unknown>
---@return table<string, unknown>
function PokegearState:setMom(savings)
  return self:_commit(applySetMom(self._data, savings))
end

-- Switches one call trigger. Repeating the current switch never moves the
-- revision.
---@param key string
---@param active boolean
---@return table<string, unknown>
function PokegearState:setTrigger(key, active)
  return self:_commit(applySetTrigger(self._data, key, active))
end

-- Replaces the called-contact journal with a validated set. Recording an
-- already-listed caller, or clearing an already-empty journal, never moves
-- the revision. The incoming-call owner records ordinary callers here at
-- acceptance and drops pool-covering entries before filtering.
---@param history table<string, boolean>
---@return table<string, unknown>
function PokegearState:setCallHistory(history)
  return self:_commit(applySetCallHistory(self._data, history))
end

-- Stages a pending item reward for a registered contact, retaining item
-- and quantity until the owning reward flow collects it. A nil reward
-- clears the pending entry. Writing the current reward never moves the
-- revision.
---@param key string
---@param reward { item: string, quantity: integer }?
---@return table<string, unknown>
function PokegearState:setContactReward(key, reward)
  return self:_commit(applySetContactReward(self._data, self._contacts, key, reward))
end

-- Stores the four icon and four word slots for a catalog location, using
-- explicit false for empty slots. A nil marking clears the location.
-- Writing identical slots never moves the revision.
---@param locationKey string
---@param marking { icons: table<integer, integer|false>, words: table<integer, string|false> }?
---@return table<string, unknown>
function PokegearState:setMarking(locationKey, marking)
  return self:_commit(applySetMarking(self._data, self._locations, locationKey, marking))
end

-- Replaces the saved contact order with a validated permutation. Every
-- registered contact stays listed exactly once and unknown or repeated
-- keys fail naming their key; writing the current order never moves the
-- revision. Registration stays append-only: this is the manual-reorder
-- write path, not a second registration.
---@param order string[]
---@return table<string, unknown>
function PokegearState:setContactOrder(order)
  return self:_commit(applySetContactOrder(self._data, self._contacts, order))
end

-- Stages a revisioned candidate: the draft function edits a detached copy
-- through the named operations, so a throwing or invalid draft leaves the
-- committed state intact. Publication is synchronous and non-yielding,
-- validates currency before any swap, and advances the revision once per
-- published batch. A candidate publishes exactly once.
---@param expectedRevision integer
---@param mutate fun(edit: table<string, fun()>)
---@return { isCurrent: boolean, publish: fun(): table<string, unknown> }
function PokegearState:prepare(expectedRevision, mutate)
  if type(expectedRevision) ~= "number" or expectedRevision % 1 ~= 0 or expectedRevision < 0 then
    fail("pokegear candidates expect the live revision", {})
  end
  if type(mutate) ~= "function" then
    fail("pokegear candidates need a draft function", {})
  end
  local draft = detach(self._data)
  assert(type(draft) == "table", "candidates stage a detached copy")
  local contacts, locations = self._contacts, self._locations
  local function editRegisterCard(_, card)
    applyRegisterCard(draft, card)
  end
  local function editRegisterContact(_, key)
    applyRegisterContact(draft, contacts, key)
  end
  local function editSetPreference(_, name, value)
    applySetPreference(draft, name, value)
  end
  local function editSetMom(_, savings)
    applySetMom(draft, savings)
  end
  local function editSetTrigger(_, key, active)
    applySetTrigger(draft, key, active)
  end
  local function editSetContactReward(_, key, reward)
    applySetContactReward(draft, contacts, key, reward)
  end
  local function editSetMarking(_, locationKey, marking)
    applySetMarking(draft, locations, locationKey, marking)
  end
  local edit = {
    registerCard = editRegisterCard,
    registerContact = editRegisterContact,
    setPreference = editSetPreference,
    setMom = editSetMom,
    setTrigger = editSetTrigger,
    setContactReward = editSetContactReward,
    setMarking = editSetMarking,
  }
  mutate(edit)
  checkRestorable(draft, contacts, locations)
  local box = {
    draft = draft,
    expectedRevision = expectedRevision,
    preparedRevision = self._revision,
    published = false,
  }
  local selfRef = self
  local function publishCandidate()
    return selfRef:_publishCandidate(box)
  end
  return {
    isCurrent = expectedRevision == self._revision,
    publish = publishCandidate,
  }
end

-- Swaps one staged candidate into the committed bucket after checking
-- currency, exactly once. Synchronous and non-yielding: validation ran at
-- preparation, so only the revision check precedes the swap.
---@param box { draft: table<string, unknown>, expectedRevision: integer, preparedRevision: integer, published: boolean }
---@return table<string, unknown> the detached state after publication
function PokegearState:_publishCandidate(box)
  if box.published or box.expectedRevision ~= self._revision or self._revision ~= box.preparedRevision then
    Errors.raise(STALE_CODE, "pokegear candidate is stale and cannot publish", {})
  end
  box.published = true
  self._data = box.draft
  self._revision = self._revision + 1
  return detach(self._data)
end

return PokegearState
