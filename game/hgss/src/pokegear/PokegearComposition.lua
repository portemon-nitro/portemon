-- Concrete pocket-gear composition for the retail field runtime: one owner
-- wires the durable companion state, the compiled catalog and asset
-- family, the civil clock, the audio boundary, the message references,
-- and the real world adapters into the normal screen factory, the
-- script host, the incoming-call owner, and the radio effect reader.
-- Construction order is fixed: shared state, calendar, and streams
-- first, then the catalog-backed world adapters, then the host, then
-- incoming, then the factories. Factories borrow shared state and read
-- live field owners only when a tab opens; the composition owns its
-- services; views own only their transient resources. Disposal releases
-- the owned services exactly once and never touches borrowed state,
-- committed contacts, gifts, markings, or surviving radio audio.
-- Source policy stays in the feature modules; this file only connects
-- owners. The bundle is closed, never a registry.
-- Pure wiring: no love dependency.

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.script.src.errors")
local FieldApplicationIds = require("libs.hgss.src.field.FieldApplicationIds")

---@class PokegearCompositionBundle
---@field screenFactory fun(entry: table<string, unknown>?): table<string, unknown>
---@field scriptHost table<string, unknown>
---@field incoming table<string, unknown>
---@field radioEffects table<string, unknown>
---@field dispose fun()
local PokegearComposition = {}

-- The unresolved-greeting identity behind scripted and notified calls. Phone
-- greeting refs are per-contact phone-bank entries whose bank mapping the
-- runtime never serves, and the shared host cannot hold per-contact refs
-- anyway. Composition never installs this identity: callers supply resolved
-- references, and any path that mistakes this sentinel for real text fails
-- loudly through message resolution (and at composition through the guard
-- below). It is never displayed on any composed path: the
-- scheduler lane never views, and the idle list places no calls.
local UNRESOLVED_GREETING = "phone.greeting.unresolved"

---@param value unknown
---@param what string
---@return table<string, unknown> the borrowed owner
local function checkOwner(value, what)
  if type(value) ~= "table" then
    Errors.raise(ScriptErrors.SCRIPT_SERVICE_MISSING, "companion composition borrows " .. what, {})
  end
  return value --[[@as table<string, unknown>]]
end

-- The ring tone owner over the composed field audio: the coordinator
-- speaks its source sequence identity while the runtime resolves the
-- audio symbol. Missing or partial audio (headless composition) means a
-- silent ring; the banner still notifies.
---@param audio table<string, unknown>?
---@return table<string, unknown>?
local function ringAudioFor(audio)
  if audio == nil then
    return nil
  end
  if type(audio.play) ~= "function" or type(audio.isEffectPlaying) ~= "function" or type(audio.stop) ~= "function" then
    return nil
  end
  local symbol = "SEQ_SE_GS_PHONE1"
  local function playRing(_, sequence)
    assert(sequence == "PHONE1", "the field ring tone plays its source sequence")
    audio:play(symbol)
  end
  local function isRingPlaying()
    return audio:isEffectPlaying(symbol)
  end
  local function stopRing()
    audio:stop(symbol)
  end
  return {
    playRing = playRing,
    isRingPlaying = isRingPlaying,
    stopRing = stopRing,
  }
end

-- Resolves the live normalized map context for the region map tab: the
-- current field map, global outdoor position, and profile gender through
-- the shared phone projection, never through display labels.
---@param runtime table<string, unknown>
---@param world table<string, unknown>
---@param catalog table<string, unknown>
---@return table<string, unknown> the normalized map context
local function liveMapContext(runtime, world, catalog)
  local session = checkOwner(runtime.session, "the live field session")
  local currentMap = checkOwner(session.currentMap, "the live field map")
  local mapSymbol = currentMap.mapSymbol
  if type(mapSymbol) ~= "string" or mapSymbol == "" then
    Errors.raise(ScriptErrors.FEATURE_UNAVAILABLE, "the region map needs its live map symbol", {})
  end
  local player = checkOwner(runtime.player, "the live player")
  local playerData = checkOwner(runtime.playerData, "the live player data")
  local fieldData = checkOwner(currentMap.fieldData, "the live field map data")
  local profile = playerData.profile
  assert(type(profile) == "table", "the region map reads the live profile")
  local playerGender = ({ [0] = "male", [1] = "female" })[profile.gender]
  if playerGender == nil then
    Errors.raise(ScriptErrors.FEATURE_UNAVAILABLE, "the region map needs a known player gender", {})
  end
  local mapInit = world.mapInit --[[@as fun(self: table<string, unknown>, field: table<string, unknown>, catalog: table<string, unknown>): table<string, unknown>]]
  assert(type(mapInit) == "function", "map contexts resolve through the shared phone projection")
  return mapInit(world, {
    mapSymbol = mapSymbol,
    playerX = assert(player.fieldX, "the region map reads the live player column"),
    playerZ = assert(player.fieldZ, "the region map reads the live player row"),
    isOutdoor = fieldData.transitionEnvironment == "outdoors",
    playerGender = playerGender,
  }, catalog)
end

-- Derives contact placements from the compiled phonebook: each contact's
-- native map resolves through the compiled location table. Contacts on
-- unmapped maps project nothing rather than a fabricated location.
---@param catalog table<string, unknown>
---@return table<string, string> contact key to location key
local function contactPlaces(catalog)
  local contacts = assert(catalog.contacts, "placements read the compiled contacts")
  assert(type(contacts) == "table", "placements read the compiled contact list")
  local locations = assert(catalog.locations, "placements read the compiled locations")
  assert(type(locations) == "table", "placements read the compiled location list")
  local locationByMapRef = {}
  for _, record in
    ipairs(locations --[[@as table<integer, unknown>]])
  do
    local entry = record --[[@as table<string, unknown>]]
    if type(entry.mapRef) == "number" and type(entry.key) == "string" then
      locationByMapRef[entry.mapRef] = entry.key
    end
  end
  local places = {}
  for _, record in
    ipairs(contacts --[[@as table<integer, unknown>]])
  do
    local entry = record --[[@as table<string, unknown>]]
    if type(entry.key) == "string" and type(entry.map) == "number" then
      local location = locationByMapRef[entry.map]
      if location ~= nil then
        places[entry.key] = location
      end
    end
  end
  return places
end

-- Samples the live roamer records once for the region map tab: only key,
-- species, location, and lifecycle cross the boundary, sorted by key for a
-- deterministic snapshot. The map never moves a roamer and never draws;
-- reopening samples fresh owners. A runtime without a roamer owner fails
-- loudly instead of projecting an empty map.
---@param runtime table<string, unknown>
---@return table<integer, table<string, unknown>> the creation-time roamer snapshot
local function roamerSnapshot(runtime)
  local roamers = checkOwner(runtime.roamerState, "the live roamer state")
  local capture = roamers.capture --[[@as fun(self: table<string, unknown>): table<string, unknown>]]
  assert(type(capture) == "function", "roamer snapshots read through the encounter owner")
  local taken = capture(roamers)
  assert(type(taken) == "table", "roamer snapshots read the encounter capture")
  local records = (taken --[[@as table<string, unknown>]]).roamers
  assert(type(records) == "table", "roamer snapshots read the roamer records")
  local projection = {}
  for key, record in
    pairs(records --[[@as table<string, table<string, unknown>>]])
  do
    assert(type(record) == "table", "the roamer capture carries records")
    local mon = record.mon
    assert(type(mon) == "table", "roamer records carry their mon")
    projection[#projection + 1] = {
      key = key,
      species = (mon --[[@as table<string, unknown>]]).species,
      location = record.location,
      lifecycle = record.lifecycle,
    }
  end
  table.sort(projection, function(first, second)
    return (first --[[@as table<string, unknown>]]).key < (second --[[@as table<string, unknown>]]).key
  end)
  return projection
end

-- The narrow word-selector handoff behind map markings: opens the real
-- single-word selector over the compiled word family when a marking edit
-- asks for it. The family resolves lazily at open; a missing family
-- fails loudly instead of offering a fabricated list.
---@param runtime table<string, unknown>
---@param assets table<string, unknown>
---@return table<string, unknown> the handoff with open, step, result, cancel
function PokegearComposition.wordEntryHandoff(runtime, assets)
  local selector = nil
  local function ensureSelector(request)
    if selector ~= nil then
      return selector --[[@as table<string, unknown>]]
    end
    local cacheFs = checkOwner(runtime.cacheFs, "the derived asset cache")
    local PokegearCache = require("libs.assets.src.PokegearCache")
    local section = cacheFs:loadLua(PokegearCache.wordEntryManifestPath())
    assert(type(section) == "table", "the word family carries its compiled section")
    local WordEntryScreenState = require("game.hgss.src.pokegear.WordEntryScreenState")
    local made = WordEntryScreenState.new({
      operationId = assert(request.operationId, "word edits carry their operation identity"),
      selectedWord = request.oldWord or false,
      wordCatalog = assert(section.groups, "the word family carries its compiled groups"),
      availability = {},
      assets = assets,
      presentation = { mode = "single-word", layout = "dual" },
    })
    selector = made
    return made
  end
  local function openHandoff(request)
    assert(type(request) == "table", "word edits open through their request")
    ensureSelector(request --[[@as table<string, unknown>]])
  end
  local function stepHandoff(events)
    assert(type(events) == "table", "word edits step their event batch")
    assert(selector ~= nil, "word edits open before they step");
    (selector --[[@as table<string, unknown>]]).updateFixed(selector, events)
  end
  local function readHandoffResult()
    assert(selector ~= nil, "word edits open before they read back")
    local takeResult = (selector --[[@as table<string, unknown>]]).takeResult
    assert(type(takeResult) == "function", "word edits read back through their selector")
    return takeResult(selector)
  end
  local function cancelHandoff(reason)
    assert(type(reason) == "string", "word edits cancel with a reason")
    if selector == nil then
      return
    end
    local dispose = (selector --[[@as table<string, unknown>]]).dispose
    if type(dispose) == "function" then
      dispose(selector)
    end
    selector = nil
  end
  return {
    open = openHandoff,
    step = stepHandoff,
    result = readHandoffResult,
    cancel = cancelHandoff,
  }
end

-- The broadcast world projection behind the radio card: daily identity,
-- field events, swarm facts, dex, and bag through their live owners.
-- Every dependency is required; a missing owner fails loudly instead of
-- inventing broadcast facts.
---@param runtime table<string, unknown>
---@param state table<string, unknown>
---@param calendar table<string, unknown>
---@return table<string, unknown> the broadcast world projection
function PokegearComposition.radioWorld(runtime, state, calendar)
  local RadioWorldContext = require("game.hgss.src.pokegear.RadioWorldContext")
  local scripts = checkOwner(runtime.scripts, "the live field scripts")
  local roamers = checkOwner(runtime.roamerState, "the live roamer state")
  local swarm = roamers.isSwarmActive --[[@as fun(self: table<string, unknown>): boolean]]
  assert(type(swarm) == "function", "broadcast facts read the live swarm fact")
  return RadioWorldContext.new({
    state = state,
    calendar = calendar,
    eventState = checkOwner(scripts.worldState, "the live world event store"),
    encounters = { swarm = swarm(roamers) == true },
    dex = checkOwner(runtime.dexKnowledge, "the live dex knowledge"),
    bag = checkOwner(runtime.bagService, "the live bag service"),
  })
end

-- The live radio facts behind channel selection: the current map facts
-- and the live story-flag set. The region resolves through the compiled
-- location table by field-map symbol, the same mechanism the shared phone
-- projection uses; special-map membership (Alph, Mahogany) and the map
-- radio permission resolve through the compiled reception sets behind the
-- native channel-selection order. A map with no compiled record at all
-- fails loudly instead of defaulting to Johto; a map carrying any record
-- resolves truthfully (a region-less special map still tunes its own
-- table, and a forbidden map tunes nothing without needing a region).
-- Story facts read through the borrowed field event store, the same
-- adapter the broadcast projection uses. This only ever selects a named
-- table, never real audio.
---@param runtime table<string, unknown>
---@param catalog table<string, unknown> the borrowed compiled map catalog
---@return { map: table<string, unknown>, flags: table<string, unknown> }
function PokegearComposition.radioFacts(runtime, catalog)
  local session = checkOwner(runtime.session, "the live field session")
  local currentMap = checkOwner(session.currentMap, "the live field map")
  local mapSymbol = currentMap.mapSymbol
  if type(mapSymbol) ~= "string" or mapSymbol == "" then
    Errors.raise(ScriptErrors.FEATURE_UNAVAILABLE, "channel selection needs its live map", {})
  end
  assert(
    type(catalog) == "table" and type(catalog.locations) == "table",
    "channel selection reads its compiled location table"
  )
  local reception = catalog.reception --[[@as table<string, unknown>]]
  assert(
    type(reception) == "table"
      and type(reception.alph) == "table"
      and type(reception.mahogany) == "table"
      and type(reception.forbidden) == "table",
    "channel selection reads its compiled reception sets"
  )
  local region = nil
  local located = false
  for _, record in
    ipairs(catalog.locations --[[@as table<integer, unknown>]])
  do
    local entry = record --[[@as table<string, unknown>]]
    if type(entry) == "table" and entry.fieldMap == mapSymbol then
      located = true
      if type(entry.region) == "string" then
        region = entry.region
        break
      end
    end
  end
  local function inReceptionSet(set)
    for _, symbol in
      ipairs(set --[[@as table<integer, unknown>]])
    do
      if symbol == mapSymbol then
        return true
      end
    end
    return false
  end
  local inAlph = inReceptionSet(reception.alph)
  local inMahogany = inReceptionSet(reception.mahogany)
  local forbidden = inReceptionSet(reception.forbidden)
  if located ~= true and inAlph ~= true and inMahogany ~= true and forbidden ~= true then
    Errors.raise(
      ScriptErrors.FEATURE_UNAVAILABLE,
      "channel selection needs compiled coverage for map " .. mapSymbol,
      { map = mapSymbol }
    )
  end
  local scripts = checkOwner(runtime.scripts, "the live field scripts")
  local events = checkOwner(scripts.worldState, "the live world event store")
  local isFlagSet = events.isFlagSet --[[@as fun(self: table<string, unknown>, flag: integer): boolean]]
  assert(type(isFlagSet) == "function", "channel selection reads story facts through the field event store")
  local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
  local flagsByName = FieldScriptSymbols.flagsByName
  assert(type(flagsByName) == "table", "channel selection reads its field flag identities")
  return {
    map = { key = mapSymbol, region = region, allowsRadio = forbidden ~= true, alph = inAlph, mahogany = inMahogany },
    flags = {
      powerRestored = isFlagSet(events, flagsByName.FLAG_RESTORED_POWER) == true,
      kantoExpansion = isFlagSet(events, flagsByName.FLAG_GOT_EXPN_CARD) == true,
      hideoutCleared = isFlagSet(events, flagsByName.FLAG_ROCKET_HIDEOUT_CLEARED) == true,
      rocketTakeover = isFlagSet(events, flagsByName.FLAG_ROCKET_TAKEOVER_ACTIVE) == true,
    },
  }
end

-- Builds the closed card-factory set over the shared owners. Factories
-- stay lazy: controllers construct at open, never at composition, so an
-- unopened tab costs nothing. Bodies assert their live owners at open
-- and fail loudly when production cannot supply them.
---@param runtime table<string, unknown>
---@param shared table<string, unknown>
---@return table<string, fun(context: table<string, unknown>): table<string, unknown>>
local function cardFactories(runtime, shared)
  local state = shared.state --[[@as table<string, unknown>]]
  local catalog = shared.catalog --[[@as table<string, unknown>]]
  local assets = shared.assets --[[@as table<string, unknown>]]
  local messages = shared.messages --[[@as table<string, unknown>]]
  local world = shared.world --[[@as table<string, unknown>]]
  local audio = shared.audio
  local random = shared.random
  local clock = shared.clock --[[@as table<string, unknown>]]
  local function phone(_)
    local PhoneController = require("game.hgss.src.pokegear.PhoneController")
    return PhoneController.new({
      state = state,
      catalog = catalog,
      messages = messages,
      world = world,
      audio = audio,
      random = random,
      assets = assets,
    })
  end
  local function map(_)
    local MapController = require("game.hgss.src.pokegear.MapController")
    local PhoneCall = require("game.hgss.src.pokegear.PhoneCall")
    local phoneEngine = PhoneCall.new({
      state = state,
      catalog = catalog,
      messages = messages,
      world = world,
      audio = audio,
      random = random,
    })
    local markers = world.locationMarkers --[[@as fun(self: table<string, unknown>, location: string, phone: table<string, unknown>, places: table<string, string>): table]]
    assert(type(markers) == "function", "contact markers resolve through the shared phone projection")
    local places = contactPlaces(catalog)
    local function phoneProjection(location)
      return markers(world, location, phoneEngine, places)
    end
    return MapController.new({
      state = state,
      assets = assets,
      mapContext = liveMapContext(runtime, world, catalog),
      phoneProjection = phoneProjection,
      roamerProjection = roamerSnapshot(runtime),
      wordEntry = PokegearComposition.wordEntryHandoff(runtime, assets),
    })
  end
  local function radio(_)
    local RadioController = require("game.hgss.src.pokegear.RadioController")
    local RadioProgram = require("game.hgss.src.pokegear.RadioProgram")
    local RadioReception = require("game.hgss.src.pokegear.RadioReception")
    local provider = checkOwner(runtime.messageProvider, "the live message provider")
    local getMessage = provider.get --[[@as fun(self: table<string, unknown>, bank: integer, id: integer): table<string, unknown>?]]
    assert(type(getMessage) == "function", "broadcast lines resolve through the message provider")
    local function readBroadcastLine(_, bank, entry)
      local template = getMessage(provider, bank, entry)
      assert(type(template) == "table", "broadcast lines resolve their compiled message")
      return (template --[[@as table<string, unknown>]]).text
    end
    local lineMessages = {
      line = readBroadcastLine,
    }
    local program = RadioProgram.new({
      catalog = catalog,
      world = PokegearComposition.radioWorld(
        runtime,
        state,
        checkOwner(runtime.pokegearCalendar, "the companion civil calendar")
      ),
      clock = clock,
      random = random,
      audio = audio,
      messages = lineMessages,
    })
    local facts = PokegearComposition.radioFacts(runtime, catalog)
    local PokegearInterface = require("game.hgss.src.pokegear.PokegearInterface")
    return RadioController.new({
      state = state,
      catalog = catalog,
      program = program,
      reception = RadioReception,
      presentation = PokegearInterface.defaults(),
      map = facts.map,
      flags = facts.flags,
    })
  end
  local function configure(_)
    local ConfigureController = require("game.hgss.src.pokegear.ConfigureController")
    local play = nil
    if type(audio) == "table" and type(audio.play) == "function" then
      local playAudio = audio.play --[[@as fun(self: table<string, unknown>, sequence: unknown)]]
      local function playConfigureEffect(sequence)
        playAudio(audio, sequence)
      end
      play = playConfigureEffect
    end
    return ConfigureController.new({
      state = state,
      assets = assets,
      effect = play,
    })
  end
  return { phone = phone, map = map, radio = radio, configure = configure }
end

-- Composes the one concrete feature bundle. The caller supplies real
-- required owners through the record; calendars, streams, and live field
-- owners additionally ride the runtime. Nothing here falls back to a
-- silent locator: a missing owner fails the composition with its name
-- attached.
---@param runtime table<string, unknown> the owning field runtime
---@param owners { state: table<string, unknown>, catalog: table<string, unknown>, assets: table<string, unknown>, clock: table<string, unknown>, audio: table<string, unknown>?, messages: table<string, unknown>, world: table<string, unknown>? }
---@return PokegearCompositionBundle
function PokegearComposition.compose(runtime, owners)
  assert(type(runtime) == "table", "companion composition needs its owning runtime")
  assert(type(owners) == "table", "companion composition needs its owners")
  local state = checkOwner(owners.state, "the durable companion state")
  local catalog = checkOwner(owners.catalog, "the compiled contact catalog")
  assert(type(catalog.contacts) == "table", "the contact catalog carries its contacts")
  local assets = checkOwner(owners.assets, "the compiled asset family")
  local clock = checkOwner(owners.clock, "the civil-time boundary")
  assert(type(clock.nowLocal) == "function", "the clock answers civil samples")
  local audio = owners.audio
  assert(audio == nil or type(audio) == "table", "the audio boundary stays a record")
  local random = checkOwner(runtime.pokegearRandom, "the live companion draw streams")
  local calendar = checkOwner(runtime.pokegearCalendar, "the companion civil calendar")
  local messages = checkOwner(owners.messages, "the shared message references")
  assert(
    messages.greeting ~= UNRESOLVED_GREETING,
    "callers supply resolved greeting references, never the unresolved sentinel"
  )
  local PhoneWorldContext = require("game.hgss.src.pokegear.PhoneWorldContext")
  local world = owners.world
    or PhoneWorldContext.new({ state = state, runtime = runtime, flags = runtime.eventState, catalog = catalog })
  assert(type(world) == "table", "world reads stay a record")

  local PokegearScriptHost = require("game.hgss.src.pokegear.PokegearScriptHost")
  local host = PokegearScriptHost.new({
    state = state,
    catalog = catalog,
    messages = messages,
    world = world,
    audio = audio,
    random = random,
  })

  local IncomingCalls = require("game.hgss.src.pokegear.IncomingCalls")
  local incoming = IncomingCalls.new({
    state = state,
    catalog = catalog,
    calendar = calendar,
    random = random,
    world = world,
    messages = messages,
    host = host,
    audio = ringAudioFor(audio),
  })

  -- The bound radio effect reader: the runtime owns the one
  -- sequence-to-effect mapping, so this service only binds it.
  local function queryRadioMusic(_, effect)
    assert(type(effect) == "string", "radio music queries compare a semantic effect")
    local query = runtime.radioMusicIs --[[@as fun(self: table<string, unknown>, effect: string): boolean]]
    assert(type(query) == "function", "radio queries read through the runtime boundary")
    return query(runtime, effect)
  end
  local radioEffects = {
    musicIs = queryRadioMusic,
  }

  local PokegearInterface = require("game.hgss.src.pokegear.PokegearInterface")
  local shared = {
    state = state,
    catalog = catalog,
    assets = assets,
    messages = messages,
    world = world,
    audio = audio,
    random = random,
    clock = clock,
  }
  local children = cardFactories(runtime, shared)
  local PokegearScreenState = require("game.hgss.src.pokegear.PokegearScreenState")
  local disposed = false
  local function screenFactory(entry)
    if disposed then
      Errors.raise(ScriptErrors.FEATURE_UNAVAILABLE, "a disposed companion composition opens nothing", {})
    end
    if host:isActive() then
      Errors.raise(
        ScriptErrors.FEATURE_UNAVAILABLE,
        "a scripted companion application holds the feature lease",
        { application = FieldApplicationIds.POKEGEAR }
      )
    end
    local display = runtime.presentationDisplay
    assert(type(display) == "table", "gear screens measure their display")
    local play = nil
    if type(audio) == "table" and type(audio.play) == "function" then
      local playAudio = audio.play --[[@as fun(self: table<string, unknown>, sequence: unknown)]]
      local function playScreenEffect(sequence)
        playAudio(audio, sequence)
      end
      play = playScreenEffect
    end
    local function measurePresentationDisplay()
      return runtime.presentationDisplay
    end
    return PokegearScreenState.new({
      state = state,
      assets = assets,
      clock = clock,
      children = children,
      presentation = PokegearInterface.defaults(),
      effect = play,
      entry = entry or { kind = "browse" },
      measureDisplay = measurePresentationDisplay,
    })
  end

  local function dispose()
    if disposed then
      return
    end
    disposed = true
    host:dispose()
    incoming:dispose()
  end

  return {
    screenFactory = screenFactory,
    scriptHost = host,
    incoming = incoming,
    radioEffects = radioEffects,
    dispose = dispose,
  }
end

return PokegearComposition
