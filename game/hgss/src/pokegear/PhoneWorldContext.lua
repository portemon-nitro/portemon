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

-- Reads the native Mom selector facts from the live map and event
-- owners. The pinned selector compares the phonebook map header with
-- the player's map header and checks these two save flags in order.
---@param contact table<string, unknown>
---@return table<string, boolean> the native Mom selector facts
function PhoneWorldContext:nativeSelectorFacts(contact)
  assert(
    type(contact) == "table" and type(contact.mapId) == "number",
    "native phone selection reads the contact map identity"
  )
  local runtime = self._owners.runtime
  assert(type(runtime) == "table", "native phone selection reads the live field runtime")
  local session = runtime.session
  local currentMap = type(session) == "table" and session.currentMap or runtime.runtimeMap
  assert(
    type(currentMap) == "table" and type(currentMap.mapId) == "number",
    "native phone selection reads the current map identity"
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
    localMap = contact.mapId == currentMap.mapId,
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
    -- Buena and friend handlers print gendered intros behind the
    -- profile gender, mirroring PhoneCallMessagePrint_Gendered.
    facts.playerGender = playerData.profile.gender
    -- Retail counts profile badges for the Elm gate; a missing badge
    -- set reads as zero exactly like a fresh profile.
    local badges = playerData.profile.badges
    if type(badges) == "table" then
      local count = 0
      for _, owned in pairs(badges) do
        if owned == true then
          count = count + 1
        end
      end
      facts.badges = count
    end
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
      facts.hour = hour
      facts.timeOfDay = hour >= 4 and hour < 10 and 0 or (hour >= 20 or hour < 4) and 2 or 1
    end
  end
  local party = runtime.monService
  if type(party) == "table" and type(party.partyCount) == "function" then
    facts.partyCount = party:partyCount()
  end
  local dex = runtime.dexKnowledge
  if type(dex) == "table" and type(dex.countSeen) == "function" then
    assert(type(dex.countCaught) == "function", "phone calls read explicit Dex counts")
    assert(type(dex.hasNationalDex) == "function", "phone calls read Dex ownership")
    facts.dexSeen = dex:countSeen("national")
    facts.dexCaught = dex:countCaught("national")
    facts.nationalDex = dex:hasNationalDex()
  end
  -- Generic header gates read the tower, takeover, and contest facts
  -- through the live event state: the radio-tower flag, the takeover
  -- scene variable in its active window, and the bug-contest flag. An
  -- event state without variable reads omits the takeover fact, which
  -- the gates treat like the unset source value.
  local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
  local flagNames = FieldScriptSymbols.flagsByName
  assert(type(flagNames) == "table", "phone calls read story flag identities")
  local events = self._owners.flags
  if type(events) == "table" and type(events.isFlagSet) == "function" then
    local readFlag = events.isFlagSet --[[@as fun(self: table<string, unknown>, flag: integer): boolean]]
    facts.towerCleared = readFlag(events, flagNames.FLAG_BEAT_RADIO_TOWER_ROCKETS) == true
    facts.bugContest = readFlag(events, flagNames.FLAG_UNK_996) == true
    -- The Elm chain reads its story flags in source order: the panic
    -- call, the rival naming, the egg call and gift, the hatch and
    -- Everstone, the ticket, and Pokerus. Pending-event facts invert
    -- their flags (the call fires while the flag is unset); state
    -- facts read their flags directly.
    facts.panicCall = readFlag(events, flagNames.FLAG_GOT_ELMS_PANIC_CALL) ~= true
    facts.eggEvent = readFlag(events, flagNames.FLAG_GOT_PICK_UP_EGG_CALL_FROM_ELM) ~= true
    facts.eggGift = readFlag(events, flagNames.FLAG_GOT_EGG_FROM_ELMS_ASSISTANT) ~= true
    facts.eggHatched = readFlag(events, flagNames.FLAG_SYS_HATCHED_TOGEPI_EGG) == true
    facts.everstone = readFlag(events, flagNames.FLAG_GOT_EVERSTONE_FROM_ELM) == true
    facts.ssTicket = readFlag(events, flagNames.FLAG_GOT_SS_TICKET_FROM_ELM) == true
    facts.pokerus = readFlag(events, flagNames.FLAG_WAS_TOLD_ABOUT_POKERUS) == true
    facts.gameClear = readFlag(events, flagNames.FLAG_GAME_CLEAR) == true
    -- The Kurt status flags behind the dynamic status line: the
    -- order flag and the ball-making flag.
    facts.kurtFlag127 = readFlag(events, flagNames.FLAG_UNK_127) == true
    facts.kurtMaking = readFlag(events, flagNames.FLAG_DAILY_KURT_MAKING_BALLS) == true
    -- The Oak johto acknowledgement behind the dynamic menu identity.
    facts.oakJohtoAcked = readFlag(events, flagNames.FLAG_SYS_OAK_ACKNOWLEDGED_JOHTO_DEX_COMPLETION) == true
    -- The region-1 flypoint behind friend outgoing region messages.
    facts.flypoint25 = readFlag(events, flagNames.FLAG_UNK_9C9) == true
    if type(events.getVar) == "function" then
      local varNames = FieldScriptSymbols.variablesByName
      assert(type(varNames) == "table", "phone calls read story variable identities")
      local scene = events.getVar(events, varNames.VAR_SCENE_ROCKET_TAKEOVER)
      facts.takeover = type(scene) == "number" and scene >= 2 and scene <= 4
      -- Retail always returns Var4057 plus the base Baoba script: a
      -- missing var reads as zero exactly like the source zero-init.
      local safariVar = events.getVar(events, varNames.VAR_UNK_4057)
      facts.safariTest = type(safariVar) == "number" and safariVar or 0
    end
  end
  -- The Kenji errand wait and activity ride the durable companion
  -- counters: retail zero-inits the same persistent record, so absent
  -- fields read as zero and false.
  local phoneState = self._owners.state
  if type(phoneState) == "table" and type(phoneState.readPhone) == "function" then
    local phone = phoneState:readPhone()
    local kenji = type(phone) == "table" and phone.kenji or nil
    facts.kenjiWaitDays = type(kenji) == "table" and kenji.waitDays or 0
    facts.kenjiActive = type(kenji) == "table" and kenji.active == true
  end
  -- The friend outgoing region messages key the saved map unlock
  -- level, mirroring Pokegear_GetMapUnlockLevel.
  if type(phoneState) == "table" and type(phoneState.readPreferences) == "function" then
    local preferences = phoneState:readPreferences()
    local unlockLevel = type(preferences) == "table" and preferences.mapUnlockLevel or nil
    if type(unlockLevel) == "number" and unlockLevel % 1 == 0 then
      facts.unlockLevel = unlockLevel
    end
  end
  -- Mom intro param joins the current map id onto the static map-header
  -- catalog (romdump maps.lua momCallIntroParam, zero-based map ids).
  -- Absent maps or headers omit the fact; the call defaults to 10.
  local session = runtime.session
  local currentMap = type(session) == "table" and session.currentMap or runtime.runtimeMap
  local mapId = type(currentMap) == "table" and currentMap.mapId or nil
  if type(mapId) == "number" and mapId % 1 == 0 then
    -- The friend incoming location message keys off the current
    -- native map identity, the same header the selector compares.
    facts.mapId = mapId
    local okMaps, maps = pcall(require, "romdump.src.catalog.hgss.maps")
    if okMaps and type(maps) == "table" then
      local byId = (maps --[[@as table<string, unknown>]]).byId
      if type(byId) == "table" then
        local header = (byId --[[@as table<integer, unknown>]])[mapId]
        if type(header) == "table" then
          local param = (header --[[@as table<string, unknown>]]).momCallIntroParam
          if type(param) == "number" and param % 1 == 0 then
            facts.momCallIntroParam = param
          end
        end
      end
    end
  end
  return facts
end

-- Reads the map call signal behind call setup: the header flag for
-- the requested direction, exactly like MapHeader_CanPlacePhoneCalls
-- and MapHeader_CanReceivePhoneCalls. A missing header fails loudly
-- instead of inventing coverage.
---@param direction string incoming or outgoing
---@return boolean signaled
function PhoneWorldContext:phoneSignal(direction)
  assert(direction == "incoming" or direction == "outgoing", "phone signal reads a known direction")
  local runtime = self._owners.runtime
  assert(type(runtime) == "table", "phone signal reads the live field runtime")
  local session = runtime.session
  local currentMap = type(session) == "table" and session.currentMap or runtime.runtimeMap
  local mapId = type(currentMap) == "table" and currentMap.mapId or nil
  assert(type(mapId) == "number" and mapId % 1 == 0, "phone signal reads the current map")
  local okMaps, maps = pcall(require, "romdump.src.catalog.hgss.maps")
  assert(okMaps and type(maps) == "table", "phone signal reads the static map-header catalog")
  local byId = (maps --[[@as table<string, unknown>]]).byId
  assert(type(byId) == "table", "phone signal reads indexed map headers")
  local header = (byId --[[@as table<integer, unknown>]])[mapId]
  assert(type(header) == "table", "phone signal needs a header for the current map")
  local flag = direction == "incoming" and "incomingCalls" or "outgoingCalls"
  local signaled = (header --[[@as table<string, unknown>]])[flag]
  assert(type(signaled) == "boolean", "phone signal headers carry their call coverage")
  return signaled
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

-- The native fisherman trainer class behind the good-rod encounter
-- slot rule (TRAINERCLASS_FISHERMAN).
PhoneWorldContext.FISHERMAN_CLASS = 11

-- Lists the trainer party species keys behind generic phone chatter:
-- the same compiled trainer template the battle factory materializes,
-- read by native trainer number. Absent trainer data fails with
-- attribution instead of inventing a party.
---@param trainerId integer native trainer number
---@return string[] species keys in team order
function PhoneWorldContext:trainerPartySpecies(trainerId)
  assert(type(trainerId) == "number" and trainerId % 1 == 0, "trainer parties read their native trainer number")
  local runtime = self._owners.runtime
  local catalog = type(runtime) == "table" and runtime._trainerCatalog or nil
  if type(catalog) ~= "table" then
    missingOwner("trainers", "no compiled trainer catalog backs phone chatter")
  end
  assert(type(catalog) == "table", "trainer parties read the compiled trainer catalog")
  local HgssTrainerCatalog = require("libs.hgss.src.battle.HgssTrainerCatalog")
  local template = HgssTrainerCatalog.trainer(catalog, trainerId)
  if type(template) ~= "table" then
    local failure = Errors.new(
      ScriptErrors.FEATURE_UNAVAILABLE,
      "phone chatter names a compiled trainer, got " .. tostring(trainerId),
      { trainer = trainerId }
    )
    error({ code = failure.code, message = failure.message, context = failure.context, domain = "phone" })
  end
  assert(type(template) == "table", "trainer templates resolve through the compiled catalog")
  local members = (template --[[@as table<string, unknown>]]).members
  assert(type(members) == "table" and #members > 0, "trainer templates carry their party")
  local keys = {}
  for _, member in
    ipairs(members --[[@as table<integer, unknown>]])
  do
    local species = (member --[[@as table<string, unknown>]]).species
    assert(type(species) == "string" and species ~= "", "trainer parties name their species")
    keys[#keys + 1] = species
  end
  return keys
end

-- Lists one land time band's encounter species keys behind generic
-- phone chatter: the compiled encounter member for the map with a
-- neutral rod and radio, mirroring the raw table the source reads.
-- Fishermen read the good-rod slots; every other class reads the land
-- slots for the time band. Absent encounter data fails with attribution.
---@param mapId integer native map identity
---@param timeOfDay string morning, day, or night
---@param trainerClass integer native trainer class
---@return string[] species keys in slot order
function PhoneWorldContext:encounterSpecies(mapId, timeOfDay, trainerClass)
  assert(type(mapId) == "number" and mapId % 1 == 0, "encounter slots read their native map")
  assert(timeOfDay == "morning" or timeOfDay == "day" or timeOfDay == "night", "encounter slots read a known time band")
  assert(type(trainerClass) == "number" and trainerClass % 1 == 0, "encounter slots read the caller class")
  local runtime = self._owners.runtime
  local catalog = type(runtime) == "table" and runtime._encounterCatalog or nil
  if type(catalog) ~= "table" then
    missingOwner("encounters", "no compiled encounter catalog backs phone chatter")
  end
  assert(type(catalog) == "table", "encounter slots read the compiled encounter catalog")
  local member = catalog:tableFor(mapId, {
    timeOfDay = timeOfDay,
    radio = "none",
    rod = trainerClass == PhoneWorldContext.FISHERMAN_CLASS and "good_rod" or nil,
    game = type(runtime) == "table" and runtime.versionId or nil,
  })
  assert(type(member) == "table", "encounter tables resolve through the compiled catalog")
  local slots = nil
  if trainerClass == PhoneWorldContext.FISHERMAN_CLASS then
    slots = (member --[[@as table<string, unknown>]]).goodRod
  else
    slots = (member --[[@as table<string, unknown>]])[timeOfDay]
  end
  assert(type(slots) == "table" and #slots > 0, "encounter tables carry slots for the caller")
  local keys = {}
  for _, slot in
    ipairs(slots --[[@as table<integer, unknown>]])
  do
    local species = (slot --[[@as table<string, unknown>]]).species
    assert(type(species) == "string" and species ~= "", "encounter slots name their species")
    keys[#keys + 1] = species
  end
  return keys
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

-- Maps a matrix cell without the source row offset to the displayed region
-- name behind unmapped field maps: Johto cells read as Johto, every other
-- cell reads as Kanto, matching the compiled location records (Indigo
-- Plateau itself is recorded as Kanto).
---@param cellX integer matrix column
---@param cellY integer matrix row
---@return string region "johto"|"kanto"
local function fallbackRegion(cellX, cellY)
  local MapLocations = require("game.hgss.src.pokegear.map.MapLocations")
  if MapLocations.regionOf(cellX, cellY) == MapLocations.REGION.JOHTO then
    return "johto"
  end
  return "kanto"
end

-- Builds the source-normalized map context from the current field map,
-- its compiled location record, and live global player coordinates only
-- on outdoor maps. Indoor headers remain authoritative; zero headers may
-- use only the exterior captured by a committed world swap. Field maps
-- without a compiled location still open the region map instead of
-- refusing it: outdoor maps center on the live world position with the
-- cell's region, indoor maps hold the last exterior (or special spawn)
-- exactly like zero-coordinate headers, and maps with neither show the
-- origin corner rather than crashing the gear.
---@param field { mapSymbol: string, playerX: number, playerZ: number, isOutdoor: boolean, playerGender: string }
---@param catalog table<string, unknown> the borrowed compiled map catalog
---@return { fieldMap: string, location: string, matrixX: number, matrixY: number, explicitX: integer?, explicitY: integer?, lastExterior: { x: integer, y: integer }?, specialSpawn: { x: integer, y: integer }?, region: string, unlockLevel: integer, specialMode: string?, playerGender: string }
function PhoneWorldContext:mapInit(field, catalog)
  assert(type(field) == "table", "map initialization reads the field map and player facts")
  assert(type(field.mapSymbol) == "string" and field.mapSymbol ~= "", "map initialization names the actual field map")
  assert(
    type(field.playerX) == "number" and type(field.playerZ) == "number",
    "map initialization carries the world player position"
  )
  assert(
    type(field.playerGender) == "string" and field.playerGender ~= "",
    "map initialization names the player gender"
  )
  assert(type(field.isOutdoor) == "boolean", "map initialization distinguishes global outdoor coordinates")
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
  local state = self._owners.state
  assert(type(state) == "table", "phone world reads borrow the companion state")
  local preferences = state:readPreferences()
  assert(type(preferences) == "table", "map initialization reads the saved progression facts")
  local unlockLevel = preferences.mapUnlockLevel
  assert(type(unlockLevel) == "number", "the saved map unlock level is a number")
  local runtime = self._owners.runtime
  local worldSwapCoordinator = type(runtime) == "table" and runtime.worldSwapCoordinator or nil
  local lastExterior = nil
  if type(worldSwapCoordinator) == "table" then
    local cell = worldSwapCoordinator.pokegearLastExterior
    if cell ~= nil then
      assert(
        type(cell) == "table"
          and type(cell.x) == "number"
          and cell.x % 1 == 0
          and type(cell.y) == "number"
          and cell.y % 1 == 0,
        "the committed exterior carries an integral world cell"
      )
      lastExterior = { x = cell.x, y = cell.y }
    end
  end
  local specialSpawn
  local travel = type(runtime) == "table" and runtime.fieldTravel or nil
  if type(travel) == "table" and type(travel.specialSpawn) == "function" then
    local spawn = travel:specialSpawn()
    if type(spawn) == "table" and type(spawn.map) == "string" then
      for _, entry in ipairs(catalog.locations) do
        if type(entry) == "table" and entry.fieldMap == spawn.map then
          local x, y = entry.explicitX, entry.explicitY
          if type(x) == "number" and x % 1 == 0 and type(y) == "number" and y % 1 == 0 and (x ~= 0 or y ~= 0) then
            specialSpawn = { x = x, y = y }
          end
          break
        end
      end
    end
  end
  if record == nil then
    local matrixX, matrixY = 0, 0
    local region = "johto"
    if field.isOutdoor then
      matrixX, matrixY = field.playerX, field.playerZ
      region = fallbackRegion(math.floor(matrixX / 32), math.floor(matrixY / 32))
    elseif lastExterior ~= nil then
      region = fallbackRegion(lastExterior.x, lastExterior.y)
    elseif specialSpawn ~= nil then
      region = fallbackRegion(specialSpawn.x, specialSpawn.y)
    end
    return {
      fieldMap = field.mapSymbol,
      location = field.mapSymbol,
      matrixX = matrixX,
      matrixY = matrixY,
      explicitX = field.isOutdoor and nil or 0,
      explicitY = field.isOutdoor and nil or 0,
      lastExterior = lastExterior,
      specialSpawn = specialSpawn,
      region = region,
      unlockLevel = unlockLevel,
      specialMode = nil,
      playerGender = field.playerGender,
    }
  end
  assert(type(record.location) == "string", "compiled locations carry their displayed location")
  assert(type(record.region) == "string", "compiled locations carry their region")
  local matrix = record.matrix
  assert(
    type(matrix) == "table" and type(matrix.x) == "number" and type(matrix.y) == "number",
    "compiled locations carry a source matrix anchor"
  )
  local matrixX, matrixY = matrix.x, matrix.y
  if field.isOutdoor then
    matrixX, matrixY = field.playerX, field.playerZ
  end
  return {
    fieldMap = field.mapSymbol,
    location = record.location,
    matrixX = matrixX,
    matrixY = matrixY,
    explicitX = record.explicitX,
    explicitY = record.explicitY,
    lastExterior = lastExterior,
    specialSpawn = specialSpawn,
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
        markers[#markers + 1] = {
          contact = contact,
          trainerId = marker.trainerId,
          ready = marker.ready,
          gift = gift,
        }
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
        daycare = "daycare",
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
    if fact == "pending" then
      -- The handed Kurt order behind the dynamic status line: the
      -- live apricorn service's pending order, or an empty handed
      -- count when nothing is staged. An absent apricorn service
      -- fails with attribution instead of an invented empty box.
      local runtime = self._owners.runtime
      local mart = type(runtime) == "table" and runtime.martService or self._owners.kurt
      if type(mart) ~= "table" or type(mart.pendingKurt) ~= "function" then
        missingOwner("kurt", "no live apricorn owner is available")
      end
      assert(type(mart) == "table", "kurt orders read the live apricorn service")
      local pending = mart:pendingKurt()
      if type(pending) ~= "table" then
        return { quantity = 0 }
      end
      local order = pending --[[@as table<string, unknown>]]
      local quantity = order.quantity
      assert(type(quantity) == "number" and quantity % 1 == 0 and quantity >= 0, "kurt orders read the handed count")
      local apricorn = order.apricornKey
      if quantity > 0 then
        assert(type(apricorn) == "string" and apricorn ~= "", "a kurt order names its apricorn")
      end
      return { quantity = quantity, apricorn = apricorn }
    end
    return self:_domainOwner("kurt")
  end
  if domain == "daycare" then
    local service = self:_domainOwner("daycare")
    if fact == "status" then
      -- The Day Care Man's call reads one detached status projection of the
      -- custody owner: the stabled count with its nicknames and level growth,
      -- the pending egg, and the breeding compatibility. Nothing here caches a
      -- parent or advances custody.
      assert(
        type(service.storedNicknames) == "function"
          and type(service.hasEgg) == "function"
          and type(service.compatibilityCategory) == "function"
          and type(service.growth) == "function",
        "daycare status reads the live Day Care service"
      )
      local nicknames = {}
      local growths = {}
      local buffers = service:storedNicknames()
      assert(type(buffers) == "table", "daycare status reads its stabled nicknames")
      local count = 0
      for slot0 = 0, 1 do
        local nickname = (buffers --[[@as table<integer, string>]])[slot0]
        if nickname ~= nil then
          count = count + 1
          nicknames[count] = nickname
          growths[count] = service:growth(slot0).growth
        end
      end
      local compatibility = count == 2 and service:compatibilityCategory() or 0
      return {
        count = count,
        egg = service:hasEgg() == true,
        compatibility = compatibility,
        nicknames = nicknames,
        growths = growths,
      }
    end
    return service
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
    if fact == "seen" then
      assert(type(dex.countSeen) == "function", "phone Dex reads its live knowledge counts")
      return dex:countSeen("national")
    end
    if fact == "caught" then
      assert(type(dex.countCaught) == "function", "phone Dex reads its live knowledge counts")
      return dex:countCaught("national")
    end
    if fact == "johto-seen" then
      assert(type(dex.countSeen) == "function", "phone Dex reads its live knowledge counts")
      return dex:countSeen("johto")
    end
    if fact == "johto-caught" then
      assert(type(dex.countCaught) == "function", "phone Dex reads its live knowledge counts")
      return dex:countCaught("johto")
    end
    if fact == "national-owned-ex-mythical" then
      assert(type(dex.countOwnedExcludeMythical) == "function", "phone Dex reads its rating counts")
      return dex:countOwnedExcludeMythical("national")
    end
    if fact == "johto-owned-ex-mythical" then
      assert(type(dex.countOwnedExcludeMythical) == "function", "phone Dex reads its rating counts")
      return dex:countOwnedExcludeMythical("johto")
    end
    if fact == "national-complete" then
      assert(type(dex.isNationalDexComplete) == "function", "phone Dex reads its completion")
      return dex:isNationalDexComplete()
    end
    if fact == "johto-complete" then
      assert(type(dex.isJohtoDexComplete) == "function", "phone Dex reads its completion")
      return dex:isJohtoDexComplete()
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

-- Whether one native trainer is already defeated: the source trainer flag
-- (TRAINER_FLAG_BASE + trainer number) read from the live event state.
---@param trainerNo integer native trainer identity
---@return boolean defeated
function PhoneWorldContext:trainerDefeated(trainerNo)
  assert(type(trainerNo) == "number" and trainerNo % 1 == 0, "trainer defeats read a native trainer number")
  local RuntimeValues = require("libs.hgss.src.script.RuntimeValues")
  local events = self._owners.flags
  assert(
    type(events) == "table" and type(events.isFlagSet) == "function",
    "trainer defeats read the live event state"
  )
  local isFlagSet = events.isFlagSet --[[@as fun(state: table<string, unknown>, flag: integer): boolean]]
  return isFlagSet(events, RuntimeValues.trainerFlagId(trainerNo)) == true
end

-- Whether one native rematch group is unlocked: source
-- EventFlagCheck_RematchGroup reads FLAG_UNK_97B + rematch number.
---@param rematchNo integer native rematch number 1..5
---@return boolean unlocked
function PhoneWorldContext:rematchGroupUnlocked(rematchNo)
  assert(
    type(rematchNo) == "number" and rematchNo % 1 == 0 and rematchNo >= 1 and rematchNo <= 5,
    "rematch groups read a native rematch number"
  )
  local events = self._owners.flags
  assert(
    type(events) == "table" and type(events.isFlagSet) == "function",
    "rematch groups read the live event state"
  )
  local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
  local flagBase = FieldScriptSymbols.flagsByName.FLAG_UNK_97B
  assert(type(flagBase) == "number", "rematch groups read the source group flag base")
  local isFlagSet = events.isFlagSet --[[@as fun(state: table<string, unknown>, flag: integer): boolean]]
  return isFlagSet(events, flagBase + rematchNo) == true
end

-- Reads the player's text speed option behind call text typing: the
-- live player-data gameplay option when the runtime carries one,
-- otherwise the production default for option-less worlds. Retail
-- prints call pages behind Options_GetTextFrameDelay.
---@return string a supported text speed
function PhoneWorldContext:textSpeed()
  local PlayerData = require("libs.hgss.src.save.PlayerData")
  local runtime = self._owners.runtime
  local playerData = type(runtime) == "table" and runtime.playerData or nil
  local options = type(playerData) == "table" and playerData.options or nil
  local speed = type(options) == "table" and options.textSpeed or nil
  if PlayerData.TEXT_SPEEDS[speed] == nil then
    return PlayerData.defaultOptions().textSpeed
  end
  return speed --[[@as string]]
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

--- Writes the Kenji errand activity through durable companion state,
--- preserving the staged wait days. Retail sets the same persistent
--- active flag beside the seeking invitation on the day and morning
--- branches.
---@param active boolean errand activity
function PhoneWorldContext:setKenjiActive(active)
  assert(type(active) == "boolean", "kenji errand activity is a boolean")
  local state = self._owners.state
  assert(
    type(state) == "table" and type(state.readPhone) == "function" and type(state.setKenjiErrand) == "function",
    "kenji errands write durable companion state"
  )
  local phone = state:readPhone()
  local kenji = type(phone) == "table" and phone.kenji or nil
  local waitDays = type(kenji) == "table" and kenji.waitDays or 0
  assert(type(waitDays) == "number", "kenji errands carry integral wait days")
  state:setKenjiErrand(waitDays, active)
end

-- Applies the Baoba incoming trigger side effects behind the native
-- selector (PhoneCall_GetScriptId_Baoba): 142 stages safari test 4,
-- 143/144 raise the object unlock level with the unlock time, 145/146
-- raise it by four, and every numbered trigger stages safari test 7.
-- The Var4057 writes ride the live event state today; the arrangement
-- unlock levels need the safari arrangement owner, so 143..146 fail
-- with attribution until that owner is composed. Non-142..146 scripts
-- resolve statically with no effect.
---@param scriptId integer incoming trigger script identity
function PhoneWorldContext:applyBaobaTrigger(scriptId)
  assert(type(scriptId) == "number" and scriptId % 1 == 0, "baoba triggers apply their source script identity")
  local runtime = self._owners.runtime
  local flags = self._owners.flags or (type(runtime) == "table" and runtime.eventState or nil)
  if type(flags) ~= "table" or type(flags.setVar) ~= "function" then
    missingOwner("vars", "no live world variable owner stages the safari test")
  end
  assert(type(flags) == "table", "baoba triggers write through a live event state")
  local setVar = flags.setVar --[[@as fun(self: table<string, unknown>, var: integer, value: integer)]]
  local symbols = require("libs.assets.src.field.FieldScriptSymbols")
  local var4057 = symbols.variablesByName.VAR_UNK_4057
  assert(type(var4057) == "number", "baoba triggers stage the safari test var")
  if scriptId == 142 then
    setVar(flags, var4057 --[[@as integer]], 4)
    return
  end
  if scriptId < 143 or scriptId > 146 then
    return
  end
  missingOwner("safari", "no live safari arrangement owner stages unlock levels")
end

-- Writes one story flag through the event-state owner behind static
-- flag-kind scripts (PhoneCall_ApplyGenericNPCcallSideEffect
-- PHONESCRIPTTYPE_FLAG) and the professor acknowledgement branches. The
-- compiled phone table and the caller name flags semantically; this
-- boundary is the single place their identities resolve. Absent event
-- state fails with attribution instead of staging a silent no-op.
---@param name string semantic story flag name
function PhoneWorldContext:setFlag(name)
  self:_writeFlag(name, true)
end

-- Clears one story flag through the event-state owner.
---@param name string semantic story flag name
function PhoneWorldContext:clearFlag(name)
  self:_writeFlag(name, false)
end

---@param name string semantic story flag name
---@param set boolean whether the flag is written or cleared
function PhoneWorldContext:_writeFlag(name, set)
  assert(type(name) == "string" and name ~= "", "phone flag writes name a story flag")
  local runtime = self._owners.runtime
  local flags = self._owners.flags or (type(runtime) == "table" and runtime.eventState or nil)
  if type(flags) ~= "table" then
    missingOwner("flags", "no live world flag owner is available")
  end
  assert(type(flags) == "table", "phone flag writes go through a live event state")
  local symbols = require("libs.assets.src.field.FieldScriptSymbols")
  local flag = symbols.flagsByName[name]
  assert(type(flag) == "number", "phone flag writes name a catalogued story flag: " .. name)
  local write = set and flags.setFlag or flags.clearFlag
  assert(
    type(flags.setFlag) == "function" and type(flags.clearFlag) == "function",
    "phone flag writes go through FieldEventState"
  )
  write(flags, flag --[[@as integer]])
end

-- Writes Mother's source flag through the event-state owner. The save
-- choice has one authoritative representation; no phone-local shadow is
-- published.
---@param saving boolean
function PhoneWorldContext:setMomSavingsChoice(saving)
  assert(type(saving) == "boolean", "Mother savings choice is a boolean")
  if saving then
    self:setFlag("FLAG_SYS_MOMS_SAVINGS")
  else
    self:clearFlag("FLAG_SYS_MOMS_SAVINGS")
  end
end

return PhoneWorldContext
