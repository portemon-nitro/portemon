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

-- Reads the current native map header's directional phone permission.
---@param direction "incoming"|"outgoing"
---@return boolean
function PhoneWorldContext:canCall(direction)
  if direction ~= "incoming" and direction ~= "outgoing" then
    missingOwner("phone", "call admission received an unknown direction")
  end
  local runtime = self._owners.runtime
  if type(runtime) ~= "table" or type(runtime.session) ~= "table" then
    missingOwner("phone", "call admission needs the live field session")
  end
  local currentMap = runtime.session.currentMap
  if type(currentMap) ~= "table" or type(currentMap.mapId) ~= "number" or currentMap.mapId % 1 ~= 0 then
    missingOwner("phone", "call admission needs the current native map ID")
  end
  local catalog = self._owners.catalog
  if type(catalog) ~= "table" or type(catalog.callPermissions) ~= "table" then
    missingOwner("phone", "the native phone permission catalog is unavailable")
  end
  local permissions = catalog.callPermissions[currentMap.mapId]
  if type(permissions) ~= "table" then
    missingOwner("phone", "the current native map has no phone permission record")
  end
  local permitted = permissions[direction]
  if type(permitted) ~= "boolean" then
    missingOwner("phone", "the current native map has an invalid " .. direction .. " permission")
  end
  return permitted --[[@as boolean]]
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
  if contact.family == "trainer" then
    local events = self._owners.flags
    assert(type(events) == "table" and type(events.isFlagSet) == "function", "generic selectors read live event flags")
    local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
    local flags = FieldScriptSymbols.flagsByName
    assert(type(flags) == "table", "generic selectors use native story flag identities")
    local isFlagSet = events.isFlagSet --[[@as fun(self: table<string, unknown>, flag: integer): boolean]]
    facts.radioTowerBeaten = isFlagSet(events, flags.FLAG_BEAT_RADIO_TOWER_ROCKETS) == true
    facts.rocketTakeoverActive = isFlagSet(events, flags.FLAG_ROCKET_TAKEOVER_ACTIVE) == true
    facts.nationalParkCaller = contact.map == 96
    facts.bugContestActive = isFlagSet(events, flags.FLAG_BUG_CONTEST_ACTIVE) == true
    local queryRematch = self._owners.state.queryRematch
    assert(type(queryRematch) == "function", "generic selectors read persisted rematch state")
    local rematch = queryRematch(self._owners.state, contact.key --[[@as string]])
    facts.seeking = type(rematch) == "table" and rematch.stage > 0
    local readPhone = self._owners.state.readPhone
    assert(type(readPhone) == "function", "generic selectors read persisted contact rewards")
    local phone = readPhone(self._owners.state)
    assert(type(phone) == "table" and type(phone.contacts) == "table", "generic selectors read phone contacts")
    local savedContact = phone.contacts[
      contact.key --[[@as string]]
    ]
    facts.pendingGenericGift = type(savedContact) == "table" and savedContact.reward ~= nil
  end
  if contact.family == "friend" then
    local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
    local events = assert(self._owners.flags, "Friend calls read flypoint event flags")
    local isFlagSet = events.isFlagSet
    assert(type(isFlagSet) == "function", "Friend calls use the field event reader")
    local currentMap = runtime.session and runtime.session.currentMap or runtime.runtimeMap
    assert(
      type(currentMap) == "table" and type(currentMap.mapId) == "number",
      "Friend calls read the live native map ID"
    )
    local catalog = assert(self._owners.catalog, "Friend calls use the compiled catalog")
    local phrases = assert(catalog.friendMapPhrases, "Friend calls use compiled source phrase rows")
    local locationIndex = nil
    for _, phrase in ipairs(phrases) do
      if phrase.mapId == currentMap.mapId then
        locationIndex = phrase.sourceIndex
        break
      end
    end
    facts.friendMapIndex = locationIndex
    local preferences = self._owners.state:readPreferences()
    assert(
      type(preferences) == "table" and type(preferences.mapUnlockLevel) == "number",
      "Friend calls read saved map progression"
    )
    local firstFlypointFlag = FieldScriptSymbols.flagsByName.FLAG_SYS_FLYPOINT_PALLET
    local flypoint25Unlocked = isFlagSet(events, firstFlypointFlag + 25)
    local mapUnlocked = preferences.mapUnlockLevel > 0
    local eligiblePhrases = {}
    for _, phrase in ipairs(phrases) do
      local eligible = phrase.unlockGroup == 0
        or phrase.unlockGroup == 1 and flypoint25Unlocked
        or phrase.unlockGroup == 2 and mapUnlocked
      if eligible then
        eligiblePhrases[#eligiblePhrases + 1] = phrase.sourceIndex
      end
    end
    facts.friendEligiblePhraseIndices = eligiblePhrases
  end
  if contact.family == "elm" then
    local events = self._owners.flags
    if type(events) ~= "table" or type(events.isFlagSet) ~= "function" then
      missingOwner("flags", "Elm calls need their ordered story flags")
    end
    local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
    local flags = FieldScriptSymbols.flagsByName
    local isFlagSet = events.isFlagSet --[[@as fun(self: table<string, unknown>, flag: integer): boolean]]
    facts.elmPanicCallReceived = isFlagSet(events, flags.FLAG_GOT_ELMS_PANIC_CALL) == true
    facts.elmEggCallReceived = isFlagSet(events, flags.FLAG_GOT_PICK_UP_EGG_CALL_FROM_ELM) == true
    facts.elmEggReceived = isFlagSet(events, flags.FLAG_GOT_EGG_FROM_ELMS_ASSISTANT) == true
    facts.togePiEggHatched = isFlagSet(events, flags.FLAG_SYS_HATCHED_TOGEPI_EGG) == true
    facts.elmEverstoneReceived = isFlagSet(events, flags.FLAG_GOT_EVERSTONE_FROM_ELM) == true
    facts.elmSsTicketReceived = isFlagSet(events, flags.FLAG_GOT_SS_TICKET_FROM_ELM) == true
    facts.toldAboutPokerus = isFlagSet(events, flags.FLAG_WAS_TOLD_ABOUT_POKERUS) == true
    facts.gameClear = isFlagSet(events, flags.FLAG_GAME_CLEAR) == true
    facts.rocketTakeoverActive = isFlagSet(events, flags.FLAG_ROCKET_TAKEOVER_ACTIVE) == true
  end
  if contact.family == "kenji" then
    local readPhone = self._owners.state.readPhone
    assert(type(readPhone) == "function", "Kenji's native selector reads persisted caller facts")
    local phone = readPhone(self._owners.state)
    assert(type(phone) == "table" and type(phone.kenji) == "table", "Kenji's selector reads his saved record")
    local kenji = phone.kenji
    facts.kenjiWaitDays = kenji.waitDays
    facts.kenjiActive = kenji.active
    local queryRematch = self._owners.state.queryRematch
    assert(type(queryRematch) == "function", "Kenji's native selector reads rematch seeking state")
    local rematch = queryRematch(self._owners.state, contact.key --[[@as string]])
    facts.seeking = type(rematch) == "table" and rematch.stage > 0
  end
  if contact.family == "irwin" or contact.family == "buena" then
    local events = self._owners.flags
    if type(events) ~= "table" or type(events.isFlagSet) ~= "function" then
      missingOwner("flags", "this caller needs the live Rocket takeover flag")
    end
    assert(type(events) == "table", "native special callers read the live event owner")
    local flags = require("libs.assets.src.field.FieldScriptSymbols").flagsByName
    local isFlagSet = events.isFlagSet --[[@as fun(self: table<string, unknown>, flag: integer): boolean]]
    facts.rocketTakeoverActive = isFlagSet(events, flags.FLAG_ROCKET_TAKEOVER_ACTIVE) == true
    if contact.family == "irwin" then
      local playerData = runtime.playerData
      local profile = type(playerData) == "table" and playerData.profile or nil
      if type(profile) ~= "table" or type(profile.badges) ~= "number" then
        missingOwner("player", "Irwin's incoming selector needs the badge profile")
      end
      local PlayerProgression = require("libs.hgss.src.save.PlayerProgression")
      local progression = PlayerProgression.new(profile --[[@as table<string, unknown>]])
      facts.badges = progression:badgeCount()
      facts.plainBadge = progression:hasBadge("plain")
      facts.fogBadge = progression:hasBadge("fog")
      facts.marshBadge = progression:hasBadge("marsh")
      facts.risingBadge = progression:hasBadge("rising")
      facts.irwinInitialTrigger = isFlagSet(events, flags.FLAG_UNK_998) == true
      facts.irwinNationalBadgeMessageSeen = isFlagSet(events, flags.FLAG_UNK_9A4) == true
      facts.irwinMarshBadgeMessageSeen = isFlagSet(events, flags.FLAG_UNK_9A3) == true
      facts.irwinSnorlaxMessageSeen = isFlagSet(events, flags.FLAG_UNK_9A2) == true
      facts.irwinVermilionMessageSeen = isFlagSet(events, flags.FLAG_UNK_9A1) == true
      facts.irwinVermilionEvent = isFlagSet(events, flags.FLAG_UNK_087) == true
      facts.vermilionFlypoint = isFlagSet(events, flags.FLAG_SYS_FLYPOINT_VERMILION) == true
      facts.gameClear = isFlagSet(events, flags.FLAG_GAME_CLEAR) == true
      facts.irwinGameClearMessageSeen = isFlagSet(events, flags.FLAG_UNK_9A5) == true
      facts.radioTowerBeaten = isFlagSet(events, flags.FLAG_BEAT_RADIO_TOWER_ROCKETS) == true
      facts.rocketHideoutCleared = isFlagSet(events, flags.FLAG_ROCKET_HIDEOUT_CLEARED) == true
      facts.irwinHideoutMessageSeen = isFlagSet(events, flags.FLAG_UNK_9A0) == true
      facts.irwinUnknownProgress = isFlagSet(events, flags.FLAG_UNK_96A) == true
      facts.irwinUnknownProgressMessageSeen = isFlagSet(events, flags.FLAG_UNK_99F) == true
      facts.snorlaxMet = isFlagSet(events, flags.FLAG_SNORLAX_MEET) == true
    end
  end
  if contact.family == "kurt" and facts.localMap == false then
    local events = self._owners.flags
    local mart = runtime.martService
    local items = runtime.itemCatalog
    if type(events) ~= "table" or type(events.isFlagSet) ~= "function" then
      missingOwner("flags", "Kurt's call needs the caller and daily-work flags")
    end
    if type(mart) ~= "table" or type(mart.pendingKurt) ~= "function" then
      missingOwner("mart", "Kurt's call needs the pending Apricorn order")
    end
    if type(items) ~= "table" or type(items.item) ~= "function" then
      missingOwner("items", "Kurt's call needs the ordered Ball's item name")
    end
    local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
    local flags = FieldScriptSymbols.flagsByName
    local isFlagSet = events.isFlagSet --[[@as fun(self: table<string, unknown>, flag: integer): boolean]]
    local pendingKurt = mart.pendingKurt --[[@as fun(self: table<string, unknown>): table<string, unknown>?]]
    local order = pendingKurt(mart)
    facts.kurtRepeatCaller = isFlagSet(events, flags.FLAG_UNK_127) == true
    facts.kurtDailyWork = isFlagSet(events, flags.FLAG_DAILY_KURT_MAKING_BALLS) == true
    facts.kurtQuantity = type(order) == "table" and order.quantity or 0
    if type(order) == "table" and not facts.kurtDailyWork then
      local KurtConversions = require("game.hgss.src.apricorn.KurtConversions")
      local itemCatalog = items --[[@as table<string, unknown>]]
      local item = itemCatalog.item --[[@as fun(self: table<string, unknown>, key: string): table<string, unknown>]]
      local ballKey = KurtConversions.ballItemKey(order.apricornKey --[[@as string]])
      facts.kurtBallName = item(itemCatalog, ballKey).name
    end
  end
  if contact.family == "mother" then
    local readPhone = self._owners.state.readPhone
    assert(type(readPhone) == "function", "Mom's native call reads her persisted savings queue")
    local phone = readPhone(self._owners.state)
    assert(type(phone) == "table" and type(phone.mom) == "table", "Mom's native call reads her saved record")
    local mom = phone.mom
    assert(
      type(mom.balance) == "number" and type(mom.gifts) == "table",
      "Mom's native call reads the balance and pending gifts"
    )
    local events = self._owners.flags
    assert(type(events) == "table" and type(events.isFlagSet) == "function", "Mom's native call reads story flags")
    local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
    local savingsFlag = FieldScriptSymbols.flagsByName.FLAG_SYS_MOMS_SAVINGS
    assert(type(savingsFlag) == "number", "Mom's native call uses its source savings flag")
    facts.momSavingsBalance = mom.balance
    facts.momSavingsActive = events.isFlagSet(events, savingsFlag) == true
    facts.momGiftQueueFull = #mom.gifts >= 5
    local session = runtime.session
    local currentMap = type(session) == "table" and session.currentMap or runtime.runtimeMap
    local catalog = self._owners.catalog
    if
      type(currentMap) ~= "table"
      or type(currentMap.mapId) ~= "number"
      or type(catalog) ~= "table"
      or type(catalog.momCallIntroParameters) ~= "table"
    then
      missingOwner("phone", "Mom's scripted intro needs the current map and compiled map parameters")
    end
    local parameter = catalog.momCallIntroParameters[currentMap.mapId]
    if type(parameter) ~= "number" then
      missingOwner("phone", "Mom's current map has no compiled intro parameter")
    end
    facts.momIntroParameter = parameter
  end
  local playerData = runtime.playerData
  if type(playerData) == "table" and type(playerData.profile) == "table" then
    local profile = playerData.profile
    facts.money = profile.money
    facts.playerGender = profile.gender
    facts.nationalDexUnlocked = profile.nationalDex
    local badgeMask = profile.badges
    if type(badgeMask) == "number" and badgeMask % 1 == 0 and badgeMask >= 0 then
      local badges = 0
      while badgeMask > 0 do
        badges = badges + badgeMask % 2
        badgeMask = math.floor(badgeMask / 2)
      end
      facts.badges = badges
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
      facts.timeOfDay = hour >= 4 and hour < 10 and 0 or (hour >= 20 or hour < 4) and 2 or 1
      facts.hour = hour
    end
  end
  if contact.family == "baoba" then
    local events = self._owners.flags
    if type(events) ~= "table" or type(events.getVar) ~= "function" then
      missingOwner("flags", "Baoba calls need the Safari progression variable")
    end
    local symbols = require("libs.assets.src.field.FieldScriptSymbols")
    local variable = symbols.variablesByName.VAR_UNK_4057
    local getVar = events.getVar --[[@as fun(self: table<string, unknown>, variableId: integer): integer]]
    facts.baobaProgress = getVar(events, variable)
    local state = self._owners.state
    local readAreas = state.readSafariAreas
    assert(type(readAreas) == "function", "Baoba calls read the saved ordered Safari areas")
    facts.safariArrangementAreas = readAreas(state)
  end
  if contact.family == "daycare" then
    local daycare = self:_domainOwner("daycare")
    local readFacts = daycare.phoneFacts
    if type(readFacts) ~= "function" then
      missingOwner("daycare", "the saved Day Care facts cannot serve phone dialogue")
    end
    local factsForPhone = readFacts(daycare, assert(runtime.monCatalog, "Day Care reads the composed mon catalog"))
    facts.daycareMons = factsForPhone.mons
    facts.daycareEggPid = factsForPhone.eggPid
    facts.daycareCompatibility = factsForPhone.compatibility
  end
  if contact.family == "bill" then
    facts.pcFreeSlots = self:read("bill.pc-free")
    if type(facts.pcFreeSlots) == "number" and facts.pcFreeSlots > 0 then
      facts.pcBoxName = self:read("bill.pc-box-name")
    end
  end
  if contact.family == "buena" then
    local events = self._owners.flags
    assert(type(events) == "table" and type(events.isFlagSet) == "function", "Buena calls read the game-clear flag")
    local flags = require("libs.assets.src.field.FieldScriptSymbols").flagsByName
    facts.gameClear = events.isFlagSet(events, flags.FLAG_GAME_CLEAR) == true
    if type(facts.hour) == "number" then
      facts.passwordOnAir = facts.hour % 3 == 2
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
    if contact.family == "oak" then
      local dexNumbers = self._owners.summaryDexNumbers
      if type(dexNumbers) ~= "table" then
        missingOwner("dex", "Oak's calls need the compiled regional and National Dex numbers")
      end
      assert(type(dexNumbers) == "table", "Oak Dex counts use the compiled species number table")
      local counts = {
        nationalDexSeen = 0,
        nationalDexOwned = 0,
        johtoDexSeen = 0,
        johtoDexOwned = 0,
      }
      local function countSpecies(dexName, numberKey, field)
        for _, key in ipairs(bucket[field]) do
          local numbers = dexNumbers[key]
          assert(type(numbers) == "table", "the summary manifest numbers every known Dex species")
          local number = numbers[numberKey]
          if number ~= nil then
            assert(type(number) == "number" and number % 1 == 0 and number >= 0)
            if number > 0 then
              local suffix = field == "seen" and "Seen" or "Owned"
              local countKey = dexName .. "Dex" .. suffix
              counts[countKey] = counts[countKey] + 1
            end
          end
        end
      end
      countSpecies("national", "national", "seen")
      countSpecies("national", "national", "caught")
      countSpecies("johto", "regional", "seen")
      countSpecies("johto", "regional", "caught")
      facts.nationalDexSeen = counts.nationalDexSeen
      facts.nationalDexOwned = counts.nationalDexOwned
      facts.johtoDexSeen = counts.johtoDexSeen
      facts.johtoDexOwned = counts.johtoDexOwned
      facts.nationalSeen = counts.nationalDexSeen
      facts.nationalOwned = counts.nationalDexOwned
      facts.nationalComplete = dex:isNationalDexComplete()
      facts.johtoSeen = counts.johtoDexSeen
      facts.johtoOwned = counts.johtoDexOwned
      facts.johtoComplete = counts.johtoDexOwned > 253
    end
  end
  local eventState = self._owners.flags or runtime.eventState
  if type(eventState) == "table" and type(eventState.isFlagSet) == "function" then
    local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
    local isFlagSet = eventState.isFlagSet --[[@as fun(self: table<string, unknown>, flag: integer): boolean]]
    facts.acknowledgedJohto =
      isFlagSet(eventState, FieldScriptSymbols.flagsByName.FLAG_SYS_OAK_ACKNOWLEDGED_JOHTO_DEX_COMPLETION)
    facts.acknowledgedNational =
      isFlagSet(eventState, FieldScriptSymbols.flagsByName.FLAG_SYS_OAK_ACKNOWLEDGED_NATIONAL_DEX_COMPLETION)
  end
  if contact.family == "gym" then
    local state = self._owners.state
    local queryRematch = state.queryRematch
    if type(queryRematch) ~= "function" then
      missingOwner("phone", "gym calls need the durable rematch state")
    end
    assert(type(queryRematch) == "function", "gym calls read durable rematches")
    assert(type(contact.key) == "string", "gym calls retain their registered contact key")
    local rematch = queryRematch(state, contact.key)
    if rematch ~= nil then
      assert(
        type(rematch) == "table" and type(rematch.stage) == "number" and rematch.stage % 1 == 0,
        "gym rematches carry their staged progression"
      )
    end
    facts.seeking = type(rematch) == "table" and rematch.stage > 0
    -- The retail capacity routine examines one leader and compares the
    -- resulting count with five, so its native invitation path has room.
    facts.dojoHasRoom = true
  end
  return facts
end

-- Delegates the source type-one buffer selection to the field runtime,
-- which owns the composed trainer and encounter catalogs.
---@param contact table<string, unknown>
---@param random table<string, unknown>
---@param timeOfDay integer
---@return table<integer, string>
function PhoneWorldContext:genericTrainerSubstitutions(contact, random, timeOfDay)
  local runtime = self._owners.runtime
  if type(runtime) ~= "table" or type(runtime.genericTrainerPhoneSpecies) ~= "function" then
    missingOwner("trainers and encounters", "generic trainer dialogue needs the composed species selectors")
  end
  local selectSpecies = runtime.genericTrainerPhoneSpecies
  --[[@as fun(self: table<string, unknown>, contact: table<string, unknown>, timeOfDay: integer, random: table<string, unknown>): table<integer, string>]]
  return selectSpecies(runtime, contact, timeOfDay, random)
end

-- Writes Oak's completion acknowledgment through the field event owner.
---@param dex "johto"|"national"
function PhoneWorldContext:setOakAcknowledged(dex)
  assert(dex == "johto" or dex == "national", "Oak acknowledges one native Dex")
  local runtime = self._owners.runtime
  local flags = self._owners.flags or (type(runtime) == "table" and runtime.eventState or nil)
  if type(flags) ~= "table" then
    missingOwner("flags", "no live world flag owner is available")
  end
  assert(type(flags) == "table", "Oak acknowledgments write through a live event state")
  local setFlag = flags.setFlag
  assert(type(setFlag) == "function", "Oak acknowledgments write through FieldEventState")
  local symbols = require("libs.assets.src.field.FieldScriptSymbols")
  local flag = dex == "johto" and symbols.flagsByName.FLAG_SYS_OAK_ACKNOWLEDGED_JOHTO_DEX_COMPLETION
    or symbols.flagsByName.FLAG_SYS_OAK_ACKNOWLEDGED_NATIONAL_DEX_COMPLETION
  assert(type(flag) == "number", "Oak acknowledgment names a native event flag")
  setFlag(flags, flag --[[@as integer]])
end

-- Commits the one-shot story flags selected by Irwin's incoming native
-- script. These flags are consumed before the selected page is shown.
---@param effect { clearInitialTrigger: boolean, setOneShotFlag: string? }
function PhoneWorldContext:applyIrwinIncomingEffect(effect)
  assert(type(effect) == "table", "Irwin effects are a source-selected record")
  local events = self._owners.flags
  if type(events) ~= "table" or type(events.setFlag) ~= "function" or type(events.clearFlag) ~= "function" then
    missingOwner("flags", "Irwin's incoming selector needs the story flag writer")
  end
  assert(type(events) == "table", "Irwin effects write through the live event owner")
  local symbols = require("libs.assets.src.field.FieldScriptSymbols").flagsByName
  local setFlag = events.setFlag --[[@as fun(self: table<string, unknown>, flag: integer)]]
  local clearFlag = events.clearFlag --[[@as fun(self: table<string, unknown>, flag: integer)]]
  if effect.clearInitialTrigger then
    clearFlag(events, assert(symbols.FLAG_UNK_998) --[[@as integer]])
  end
  if effect.setOneShotFlag ~= nil then
    local flag = symbols[effect.setOneShotFlag]
    assert(type(flag) == "number", "Irwin one-shot effects name native flags")
    setFlag(events, flag --[[@as integer]])
  end
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

-- Builds the source-normalized map context from the current field map,
-- its compiled location record, and live global player coordinates only
-- on outdoor maps. Indoor headers remain authoritative; zero headers may
-- use only the exterior captured by a committed world swap.
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
  if record == nil then
    missingOwner("map", "no compiled location covers field map " .. field.mapSymbol)
  end
  assert(type(record) == "table", "map initialization resolves its compiled location")
  assert(type(record.location) == "string", "compiled locations carry their displayed location")
  assert(type(record.region) == "string", "compiled locations carry their region")
  local matrix = record.matrix
  assert(
    type(matrix) == "table" and type(matrix.x) == "number" and type(matrix.y) == "number",
    "compiled locations carry a source matrix anchor"
  )
  local state = self._owners.state
  assert(type(state) == "table", "phone world reads borrow the companion state")
  local preferences = state:readPreferences()
  assert(type(preferences) == "table", "map initialization reads the saved progression facts")
  local unlockLevel = preferences.mapUnlockLevel
  assert(type(unlockLevel) == "number", "the saved map unlock level is a number")
  local matrixX, matrixY = matrix.x, matrix.y
  if field.isOutdoor then
    matrixX, matrixY = field.playerX, field.playerZ
  end
  local runtime = self._owners.runtime
  local travel = type(runtime) == "table" and runtime.fieldTravel or nil
  assert(type(travel) == "table" and type(travel.lastExterior) == "function", "map reads field travel state")
  local lastExterior = travel:lastExterior()
  local specialSpawn
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
        pc = "monService",
        trainer = "_trainerFactory",
        daycare = "daycareState",
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
    if type(pc) == "table" and pc.freeSlots ~= nil and fact == "pc-free" then
      return pc.freeSlots
    end
    local capacity = self:_domainOwner("pc")
    if fact == "pc-free" then
      local boxCount = capacity.boxCount --[[@as fun(self: table<string, unknown>): integer]]
      local boxMon = capacity.boxMon --[[@as fun(self: table<string, unknown>, box: integer, slot: integer): table<string, unknown>?]]
      assert(type(boxCount) == "function" and type(boxMon) == "function", "Bill capacity reads all saved PC boxes")
      local count = boxCount(capacity)
      local Boxes = require("libs.mons.src.Boxes")
      local freeSlots = 0
      for box = 0, count - 1 do
        for slot = 0, Boxes.SLOTS_PER_BOX - 1 do
          if boxMon(capacity, box, slot) == nil then
            freeSlots = freeSlots + 1
          end
        end
      end
      return freeSlots
    elseif fact == "pc-box-name" then
      local activeBox = capacity.activeBox --[[@as fun(self: table<string, unknown>): integer]]
      local metadata = capacity.boxMetadata --[[@as fun(self: table<string, unknown>, box: integer): table<string, unknown>]]
      assert(type(activeBox) == "function" and type(metadata) == "function", "Bill's box label reads the active PC box")
      local box = activeBox(capacity)
      local details = metadata(capacity, box)
      if type(details.name) == "string" and details.name ~= "" then
        return details.name
      end
      local runtime = self._owners.runtime
      local menu = type(runtime) == "table" and runtime.pokemonMenu or nil
      local manifest = type(menu) == "table" and menu.pcManifest or nil
      local storage = type(manifest) == "table" and manifest.storage or nil
      local boxNames = type(storage) == "table" and storage.boxNames or nil
      if type(boxNames) == "table" and box < #boxNames then
        return boxNames[box + 1]
      end
      local format = type(storage) == "table" and storage.expansionNameFormat or nil
      if type(format) == "table" then
        local expansion = format --[[@as { prefix: string, firstNumber: integer, suffix: string }]]
        return expansion.prefix .. tostring(expansion.firstNumber + box) .. expansion.suffix
      end
      missingOwner("pc", "the active box has no saved or compiled name")
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

-- Prepares the source side effect attached to one selected numeric phone
-- definition. The returned commit publishes it only after native text
-- resolves; word definitions carry their selected caller-bank entry.
---@param contact string
---@param definition table<string, unknown>
---@param random table<string, unknown>
---@return { substitutions: table<string, integer>, commit: fun() } prepared native effect
function PhoneWorldContext:prepareCallDefinitionEffect(contact, definition, random)
  assert(type(contact) == "string" and contact ~= "", "phone definition effects identify their caller")
  assert(type(definition) == "table", "phone definition effects read a compiled source record")
  assert(type(random) == "table", "phone definition effects use the companion random streams")
  local kind = definition.kind
  local parameter0 = definition.param0
  local parameter1 = definition.param1
  if kind == "none" then
    local function commitNoEffect() end
    return { substitutions = {}, commit = commitNoEffect }
  elseif kind == "rematch" then
    local state = self._owners.state
    assert(type(state) == "table", "phone rematch effects use the save owner")
    local previous = state:queryRematch(contact)
    local wins = type(previous) == "table" and previous.wins or 0
    local function commitRematch()
      state:setRematch(contact, { stage = 1, wins = wins })
    end
    return {
      substitutions = {},
      commit = commitRematch,
    }
  elseif kind == "item" then
    assert(type(parameter1) == "number" and parameter1 % 1 == 0, "phone item effects carry a native item ID")
    local nativeItemId = parameter1
    local draw = random.mt --[[@as fun(self: table<string, unknown>, label: string): integer]]
    if nativeItemId == 149 then
      nativeItemId = 149 + draw(random, "phone-item-berry") % 10
    elseif nativeItemId == 1 then
      nativeItemId = 2 + draw(random, "phone-item-pokeball") % 3
    end
    local runtime = self._owners.runtime
    assert(type(runtime) == "table", "phone item effects read the live item catalog")
    local items = runtime.itemCatalog
    assert(
      type(items) == "table" and type(items.itemKeyByNativeId) == "function",
      "phone item effects resolve generated item identities"
    )
    local itemKey = items.itemKeyByNativeId --[[@as fun(self: table<string, unknown>, nativeId: integer): string]]
    local state = self._owners.state
    assert(
      type(state) == "table" and type(state.setContactReward) == "function",
      "phone gifts use the persisted contact reward owner"
    )
    local reward = { item = itemKey(items, nativeItemId), quantity = 1 }
    local function commitReward()
      state:setContactReward(contact, reward)
    end
    return {
      substitutions = {},
      commit = commitReward,
    }
  elseif kind == "flag" or kind == "flag-unknown" then
    assert(type(parameter0) == "number", "phone flag effects carry a native operation")
    local events = self._owners.flags
    assert(type(events) == "table", "phone flag effects use the event-state owner")
    local flag = parameter1
    if type(flag) == "string" then
      local symbols = require("libs.assets.src.field.FieldScriptSymbols").flagsByName
      flag = symbols[flag]
    end
    assert(type(flag) == "number", "phone flag effects resolve a native flag identity")
    local function commitFlag()
      if parameter0 ~= 0 then
        events:setFlag(flag)
      else
        events:clearFlag(flag)
      end
    end
    return {
      substitutions = {},
      commit = commitFlag,
    }
  elseif kind == "word" then
    assert(
      type(parameter0) == "number"
        and parameter0 % 1 == 0
        and parameter0 > 0
        and type(parameter1) == "number"
        and parameter1 % 1 == 0,
      "phone word effects carry a positive span and first native entry"
    )
    local draw = random.lc --[[@as fun(self: table<string, unknown>, label: string): integer]]
    local entry = parameter1 + draw(random, "phone-word-entry") % parameter0
    local function commitWord() end
    return { substitutions = { wordEntry = entry }, commit = commitWord }
  end
  error("phone definition effect has an unsupported source kind", 0)
end

-- Kenji's eligible daytime call atomically marks his native active flag
-- and the existing per-contact rematch seeking record.
---@param contact string
function PhoneWorldContext:applyKenjiActiveEffect(contact)
  local state = self._owners.state
  assert(
    type(state) == "table"
      and type(state.readPhone) == "function"
      and type(state.queryRematch) == "function"
      and type(state.prepare) == "function"
      and type(state.revision) == "function",
    "Kenji's native selector writes through the Pokegear save owner"
  )
  local phone = state:readPhone()
  assert(type(phone) == "table" and type(phone.kenji) == "table", "Kenji's write reads his saved facts")
  local kenji = phone.kenji
  local previous = state:queryRematch(contact)
  local wins = type(previous) == "table" and previous.wins or 0
  local candidate = state:prepare(state:revision(), function(edit)
    edit.setKenji(edit, { waitDays = kenji.waitDays, active = true })
    edit.setRematch(edit, contact, { stage = 1, wins = wins })
  end)
  assert(candidate.isCurrent, "Kenji's source effect publishes against the facts it selected")
  candidate.publish()
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

-- Commits the source one-time post-rival conversation flag when the
-- scripted Mom call is selected.
function PhoneWorldContext:setMomTalkedAfterNamingRival()
  local runtime = self._owners.runtime
  local flags = self._owners.flags or (type(runtime) == "table" and runtime.eventState or nil)
  if type(flags) ~= "table" then
    missingOwner("flags", "no live world flag owner is available")
  end
  assert(type(flags) == "table", "Mom's scripted call writes through a live event state")
  local symbols = require("libs.assets.src.field.FieldScriptSymbols")
  local flag = symbols.flagsByName.FLAG_TALKED_TO_MOM_AFTER_NAMING_RIVAL
  assert(type(flag) == "number", "Mom's scripted call writes the native follow-up flag")
  local setFlag = flags.setFlag
  assert(type(setFlag) == "function", "Mom's scripted call writes through FieldEventState")
  setFlag(flags, flag --[[@as integer]])
end

return PhoneWorldContext
