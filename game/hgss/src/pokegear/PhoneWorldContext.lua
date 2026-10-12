-- Foreground phone projection over live game domains: world flags and
-- variables, mon and Dex knowledge, PC capacity, Bag capacity, and the
-- production state behind Kurt, Day Care, and Safari contact branches.
-- Every read borrows its owner and returns borrowed facts without copying
-- authoritative state or keeping long-lived caches. A branch that needs an
-- absent owner fails with an attributed dependency error naming that
-- domain; it never synthesizes an empty-world answer. Branches that need
-- no production state answer locally. Pure adapter: no love dependency.

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.script.src.errors")

---@class PhoneWorldContext
---@field private _owners table<string, unknown>
local PhoneWorldContext = {}
PhoneWorldContext.__index = PhoneWorldContext

---@param domain string
---@param message string
local function missingOwner(domain, message)
  local failure = Errors.new(
    ScriptErrors.FEATURE_UNAVAILABLE,
    "phone branch needs its missing " .. domain .. " owner: " .. message,
    { domain = domain }
  )
  error({ code = failure.code, message = failure.message, context = failure.context, domain = domain })
end

---@param owners unknown
---@return table<string, unknown>
local function checkOwners(owners)
  assert(type(owners) == "table", "phone world reads borrow their owners through a record")
  local borrowed = owners --[[@as table<string, unknown>]]
  assert(type(borrowed.state) == "table", "phone world reads borrow the companion state")
  return borrowed
end

-- Borrows the live owners behind phone branches. Only the companion state
-- is required; every other owner is optional and checked lazily by the
-- branch that reads it, so a local reply never demands a full world
-- simulation.
---@param owners { state: table<string, unknown> }
---@return PhoneWorldContext
function PhoneWorldContext.new(owners)
  return setmetatable({ _owners = checkOwners(owners) }, PhoneWorldContext)
end

-- Reads the native Mom selector facts from the live map-section and
-- event owners. The pinned selector compares PhoneBookEntry.mapId with
-- the player's map section and checks these two save flags in order.
---@param contact table<string, unknown>
---@return table<string, boolean> the native Mom selector facts
function PhoneWorldContext:nativeSelectorFacts(contact)
  assert(
    type(contact) == "table" and type(contact.map) == "number",
    "native phone selection reads the contact map section"
  )
  local runtime = self._owners.runtime
  assert(type(runtime) == "table", "native phone selection reads the live field runtime")
  local session = runtime.session
  local currentMap = type(session) == "table" and session.currentMap or runtime.runtimeMap
  assert(
    type(currentMap) == "table" and type(currentMap.mapSectionNativeId) == "number",
    "native phone selection reads the current map section"
  )
  local events = self._owners.flags
  assert(
    type(events) == "table" and type(events.isFlagSet) == "function",
    "native phone selection reads live story flags"
  )
  local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
  local flags = FieldScriptSymbols.flagsByName
  assert(type(flags) == "table", "native phone selection reads story flag identities")
  local isFlagSet = events.isFlagSet --[[@as fun(self: table<string, unknown>, flag: integer): boolean]]
  return {
    localMap = contact.map == currentMap.mapSectionNativeId,
    gaveRivalName = isFlagSet(events, flags.FLAG_GAVE_RIVAL_NAME_TO_OFFICER) == true,
    talkedAfterNamingRival = isFlagSet(events, flags.FLAG_TALKED_TO_MOM_AFTER_NAMING_RIVAL) == true,
    eggCallPending = isFlagSet(events, flags.FLAG_SYS_TRIGGER_EGG_CALL) == true,
  }
end

-- Reads current source facts at call entry. Runtime-owned services are
-- looked up here instead of being frozen during early Pokegear boot.
---@param contact table<string, unknown>
---@return table<string, unknown>
function PhoneWorldContext:callFacts(contact)
  local runtime = self._owners.runtime
  assert(type(runtime) == "table", "phone calls read the live field runtime")
  local facts = self:nativeSelectorFacts(contact) --[[@as table<string, unknown>]]
  local playerData = runtime.playerData
  if type(playerData) == "table" and type(playerData.profile) == "table" then
    facts.money = playerData.profile.money
  end
  local clock = runtime.localClock
  if type(clock) == "table" and type(clock.nowLocal) == "function" then
    local sample = clock:nowLocal()
    assert(type(sample) == "table", "phone calls read a civil clock sample")
    if
      type(sample.year) == "number"
      and type(sample.month) == "number"
      and type(sample.day) == "number"
      and type(sample.hour) == "number"
    then
      local CivilDate = require("libs.hgss.src.field.CivilDate")
      local _, weekday = CivilDate.parts({ year = sample.year, month = sample.month, day = sample.day })
      facts.weekday = weekday
      local hour = math.floor(sample.hour)
      facts.timeOfDay = hour >= 4 and hour < 10 and 0 or (hour >= 20 or hour < 4) and 2 or 1
    end
  end
  local party = runtime.monService
  if type(party) == "table" and type(party.partyCount) == "function" then
    facts.partyCount = party:partyCount()
  end
  local dex = runtime.dexKnowledge
  if type(dex) == "table" and type(dex.bucket) == "function" then
    local bucket = dex:bucket()
    assert(type(bucket) == "table", "phone calls read the Dex bucket")
    facts.dexSeen = #bucket.seen
    facts.dexCaught = #bucket.caught
    facts.nationalDex = dex:isNationalDexComplete()
  end
  return facts
end

---@param contact string
---@return table<string, unknown>
function PhoneWorldContext:rematchFacts(contact)
  local catalog = self._owners.catalog
  assert(type(catalog) == "table" and type(catalog.contacts) == "table", "rematch windows read the contact catalog")
  for _, entry in ipairs(catalog.contacts) do
    if type(entry) == "table" and entry.key == contact then
      return self:callFacts(entry)
    end
  end
  missingOwner("phone", "no catalog contact describes rematch window " .. contact)
  error("unreachable", 0)
end

---@param key unknown
---@return string domain, string fact
local function splitKey(key)
  assert(type(key) == "string" and key ~= "", "phone world reads name their domain fact")
  local domain, fact = key:match("^([^.]+)%.(.+)$")
  assert(domain ~= nil and fact ~= nil, "phone world reads name their domain fact")
  return domain, --[[@as string]]
    fact --[[@as string]]
end

-- Builds the source-normalized map context for the region map from the
-- actual field map and player reads plus the compiled location table:
-- the field map symbol resolves its displayed location, region, and
-- special mode through the catalog, never through display labels or
-- cached menu views. Matrix coordinates are the live world player
-- position. Header-derived coordinates travel inside the compiled
-- location record, which the projection owner reads; live
-- last-exterior and special-spawn travel facts have no room in the
-- normalized context and stay with their travel owner. The unlocked
-- tier reuses the saved map progression fact, starting at Johto when
-- unset. Feature-local: existing world owners stay authoritative and no
-- long-lived caches are kept.
---@param field { mapSymbol: string, playerX: number, playerZ: number, playerGender: string }
---@param catalog table<string, unknown> the borrowed compiled map catalog
---@return { fieldMap: string, location: string, matrixX: number, matrixY: number, region: string, unlockLevel: integer, specialMode: string?, playerGender: string }
function PhoneWorldContext:mapInit(field, catalog)
  assert(type(field) == "table", "map initialization reads the field map, header, and travel facts")
  assert(type(field.mapSymbol) == "string" and field.mapSymbol ~= "", "map initialization names the actual field map")
  assert(
    type(field.playerX) == "number" and type(field.playerZ) == "number",
    "map initialization carries the world player position"
  )
  assert(
    type(field.playerGender) == "string" and field.playerGender ~= "",
    "map initialization names the player gender"
  )
  assert(
    type(catalog) == "table" and type(catalog.locations) == "table",
    "map initialization borrows its location table"
  )
  local record = nil
  for _, entry in ipairs(catalog.locations) do
    if type(entry) == "table" and entry.fieldMap == field.mapSymbol then
      record = entry
      break
    end
  end
  if record == nil then
    missingOwner("map", "no compiled location covers field map " .. field.mapSymbol)
  end
  assert(type(record) == "table", "map initialization resolves its compiled location")
  assert(type(record.location) == "string", "compiled locations carry their displayed location")
  assert(type(record.region) == "string", "compiled locations carry their region")
  local state = self._owners.state
  assert(type(state) == "table", "phone world reads borrow the companion state")
  local preferences = state:readPreferences()
  assert(type(preferences) == "table", "map initialization reads the saved progression facts")
  local unlockLevel = preferences.mapUnlockLevel
  if type(unlockLevel) ~= "number" or unlockLevel < 1 then
    unlockLevel = 1
  end
  return {
    fieldMap = field.mapSymbol,
    location = record.location,
    matrixX = field.playerX,
    matrixY = field.playerZ,
    region = record.region,
    unlockLevel = unlockLevel,
    specialMode = record.special,
    playerGender = field.playerGender,
  }
end

-- The shared contact availability query behind the map's contact markers:
-- rematch readiness from the borrowed conversation owner plus durable
-- pending gifts from gear state, resolved per location without caching a
-- separate copy. contactPlaces maps registered contacts to their map
-- locations. Only contacts with a ready rematch or a pending gift
-- project; unstaged contacts show nothing.
---@param location string
---@param phone table<string, unknown> the borrowed conversation owner
---@param contactPlaces table<string, string> contact key to map location
---@return table<integer, table<string, unknown>> markers
function PhoneWorldContext:locationMarkers(location, phone, contactPlaces)
  assert(type(location) == "string" and location ~= "", "contact markers name their map location")
  assert(
    type(phone) == "table" and type(phone.rematchMarker) == "function",
    "contact markers read the shared conversation owner"
  )
  assert(type(contactPlaces) == "table", "contact markers read the contact placement facts")
  local state = self._owners.state
  assert(type(state) == "table", "phone world reads borrow the companion state")
  local bucket = state:capture()
  assert(type(bucket) == "table" and type(bucket.phone) == "table", "contact markers read the phone facts")
  local contacts = (bucket --[[@as table<string, unknown>]]).phone.contacts
  assert(type(contacts) == "table", "contact markers read the registered contacts")
  local markers = {}
  for contact, place in pairs(contactPlaces) do
    if place == location then
      local marker = phone:rematchMarker(contact)
      assert(type(marker) == "table", "the conversation owner projects its rematch marker")
      local pending = contacts[contact]
      local gift = type(pending) == "table" and pending.reward or nil
      if marker.ready == true or gift ~= nil then
        markers[#markers + 1] = { contact = contact, tier = marker.tier, ready = marker.ready, gift = gift }
      end
    end
  end
  table.sort(markers, function(a, b)
    return a.contact < b.contact
  end)
  return markers
end

---@param domain string
---@return table<string, unknown> the borrowed domain owner
function PhoneWorldContext:_domainOwner(domain)
  local owner = self._owners[domain]
  if type(owner) ~= "table" then
    local runtime = self._owners.runtime
    if type(runtime) == "table" then
      local runtimeFields = {
        party = "monService",
        dex = "dexKnowledge",
        bag = "bagService",
        pc = "pcService",
        trainer = "_trainerFactory",
      }
      local field = runtimeFields[domain]
      if field ~= nil then
        owner = runtime[field]
      end
    end
  end
  if type(owner) ~= "table" then
    missingOwner(domain, "no live " .. domain .. " simulation is available")
  end
  assert(type(owner) == "table", "phone world reads borrow a live domain owner")
  return owner --[[@as table<string, unknown>]]
end

-- Reads one typed world fact for the chosen source branch. Present facts
-- are borrowed references or scalars; an absent owner raises an
-- attributed dependency error before any effect; an unset fact inside a
-- present owner reads as nil rather than a fabricated default. Reads
-- never draw, mutate, or cache.
---@param key string
---@return unknown the borrowed fact, or nil when the owner carries no value for it
function PhoneWorldContext:read(key)
  local domain, fact = splitKey(key)
  if domain == "kurt" then
    if fact == "local-greeting" then
      return { key = "kurt.local-greeting" }
    end
    return self:_domainOwner("kurt")
  end
  if domain == "daycare" then
    return self:_domainOwner("daycare")
  end
  if domain == "safari" then
    return self:_domainOwner("safari")
  end
  if domain == "bill" then
    local pc = self._owners.pc
    if type(pc) ~= "table" then
      missingOwner("pc", "no live box capacity owner is available")
    end
    assert(type(pc) == "table", "phone box reads borrow the live capacity owner")
    local capacity = pc --[[@as table<string, unknown>]]
    if fact == "pc-free" then
      return capacity.freeSlots
    end
    assert(false, "phone box reads name a known bill fact")
  end
  if domain == "mom" then
    local runtime = self._owners.runtime
    local flags = self._owners.flags or (type(runtime) == "table" and runtime.eventState or nil)
    if type(flags) ~= "table" then
      missingOwner("flags", "no live world flag owner is available")
    end
    assert(type(flags) == "table", "phone flag reads borrow the live flag owner")
    if fact == "savings-choice" then
      local symbols = require("libs.assets.src.field.FieldScriptSymbols")
      local flag = symbols.flagsByName.FLAG_SYS_MOMS_SAVINGS
      assert(type(flag) == "number", "Mother savings reads the native event flag")
      local isFlagSet = flags.isFlagSet --[[@as fun(self: table<string, unknown>, flag: integer): boolean]]
      assert(type(isFlagSet) == "function", "Mother savings reads the event state")
      return isFlagSet(flags, flag --[[@as integer]])
    end
    assert(false, "phone flag reads name a known mom fact")
  end
  if domain == "dex" then
    local dex = self:_domainOwner("dex")
    if fact == "seen" or fact == "caught" then
      local bucket = dex.bucket --[[@as fun(self: table<string, unknown>): table<string, unknown>]]
      assert(type(bucket) == "function", "phone Dex reads its current knowledge bucket")
      local data = bucket(dex)
      assert(type(data) == "table" and type(data[fact]) == "table", "phone Dex reads sorted knowledge")
      return #data[fact] --[[@as table<integer, unknown>]]
    end
    assert(false, "phone dex reads name a known dex fact")
  end
  if domain == "party" then
    local party = self:_domainOwner("party")
    if fact == "count" then
      local count = party.partyCount --[[@as fun(self: table<string, unknown>): integer]]
      assert(type(count) == "function", "phone party reads the live party service")
      return count(party)
    end
    assert(false, "phone party reads name a known party fact")
  end
  if domain == "bag" then
    local bag = self:_domainOwner("bag")
    if fact == "free-slots" then
      local capture = bag.capture --[[@as fun(self: table<string, unknown>): table<string, unknown>]]
      assert(type(capture) == "function", "phone Bag reads the live inventory")
      local inventory = capture(bag)
      local pockets = inventory.pockets --[[@as table<string, unknown>]]
      local catalog = bag.catalog --[[@as fun(self: table<string, unknown>): table<string, unknown>]]
      assert(type(catalog) == "function", "phone Bag reads its pocket capacities")
      local itemCatalog = catalog(bag)
      local BagSave = require("libs.hgss.src.save.BagSave")
      local free = 0
      for _, pocketKey in ipairs(BagSave.POCKET_ORDER) do
        local definition = itemCatalog:pocket(pocketKey)
        local slots = pockets[pocketKey]
        assert(type(slots) == "table", "phone Bag reads captured pocket slots")
        free = free + math.max(0, definition.capacity - #slots)
      end
      return free
    end
    assert(false, "phone bag reads name a known bag fact")
  end
  error("phone world reads name a known domain", 0)
end

---@param contact string
---@return { stage: integer, wins: integer }?
function PhoneWorldContext:queryRematch(contact)
  local state = self._owners.state
  assert(
    type(state) == "table" and type(state.queryRematch) == "function",
    "phone rematches read durable companion state"
  )
  return state:queryRematch(contact)
end

---@param contact string
---@param record { stage: integer, wins: integer }?
function PhoneWorldContext:setRematch(contact, record)
  local state = self._owners.state
  assert(
    type(state) == "table" and type(state.setRematch) == "function",
    "phone rematches write durable companion state"
  )
  state:setRematch(contact, record)
end

-- Writes Mother's source flag through the event-state owner. The save
-- choice has one authoritative representation; no phone-local shadow is
-- published.
---@param saving boolean
function PhoneWorldContext:setMomSavingsChoice(saving)
  assert(type(saving) == "boolean", "Mother savings choice is a boolean")
  local runtime = self._owners.runtime
  local flags = self._owners.flags or (type(runtime) == "table" and runtime.eventState or nil)
  if type(flags) ~= "table" then
    missingOwner("flags", "no live world flag owner is available")
  end
  assert(type(flags) == "table", "Mother savings writes through a live event state")
  local symbols = require("libs.assets.src.field.FieldScriptSymbols")
  local flag = symbols.flagsByName.FLAG_SYS_MOMS_SAVINGS
  assert(type(flag) == "number", "Mother savings writes the native event flag")
  local setFlag, clearFlag = flags.setFlag, flags.clearFlag
  assert(type(setFlag) == "function" and type(clearFlag) == "function", "Mother savings writes through FieldEventState")
  if saving then
    setFlag(flags, flag --[[@as integer]])
  else
    clearFlag(flags, flag --[[@as integer]])
  end
end

return PhoneWorldContext
