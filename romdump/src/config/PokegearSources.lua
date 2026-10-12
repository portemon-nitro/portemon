-- Source selectors for the HGSS Pokegear applications: the five core
-- graphics archives, the twenty sprite resource descriptor members, and the
-- whole-file phonebook. Member ranges are HeartGold evidence anchors kept
-- beside the producer; runtime records never carry them.

local PokegearSources = {}

PokegearSources.provenance = {
  decompRevision = "pret/pokeheartgold@9d8b7591f09b65804da2fb2dfd56f320633e0d36",
  symbols = {
    "src/application/pokegear/main/overlay_100_021E5900.c",
    "src/application/pokegear/main/overlay_100_021E6914.c",
    "src/phonebook_dat.c",
    "src/application/pokegear/phone/phone_script_defs.c",
    "src/application/pokegear/radio/overlay_101_021F57B8.c",
  },
}

-- The five core graphics archives with their closed selected member sets.
PokegearSources.archives = {
  shell = { path = "a/1/4/3", firstMember = 0, lastMember = 59, memberCount = 60 },
  map = { path = "a/1/4/4", firstMember = 0, lastMember = 69, memberCount = 70 },
  configure = { path = "a/1/4/5", firstMember = 0, lastMember = 27, memberCount = 28 },
  phone = { path = "a/1/4/6", firstMember = 0, lastMember = 51, memberCount = 52 },
  radio = { path = "a/1/4/7", firstMember = 0, lastMember = 45, memberCount = 46 },
}

-- The sprite resource descriptor archive and the twenty selected members:
-- CHAR/PLTT/CELL/ANIM resource lists plus the header member binding each
-- set to its graphics.
PokegearSources.spriteArchive = { path = "a/1/7/5", memberCount = 90 }

PokegearSources.spriteBindings = {
  map = { char = 34, palette = 35, cell = 33, anim = 32, header = 80 },
  configure = { char = 42, palette = 43, cell = 41, anim = 40, header = 82 },
  phone = { char = 46, palette = 47, cell = 45, anim = 44, header = 83 },
  radio = { char = 38, palette = 39, cell = 37, anim = 36, header = 81 },
}

PokegearSources.phonebook = { path = "tel/pmtel_book.dat", hgBytes = 1504, recordBytes = 20 }

-- The phonebook record is little-endian four bytes, four halfwords, eight
-- bytes: contact id, entry type, contact class, trainer; map, gift, local
-- script, greeting; rematch weekday, rematch time, category, four source
-- sort weights, and one spare byte.
PokegearSources.phonebookFields = {
  "id",
  "entryType",
  "contactClass",
  "trainer",
  "map",
  "gift",
  "localScript",
  "greeting",
  "rematchWeekday",
  "rematchTime",
  "category",
  "sortWeight0",
  "sortWeight1",
  "sortWeight2",
  "sortWeight3",
  "spare",
}

-- Resource-list descriptors hold a u32 resource type, six-u32 records, and
-- a six-word -2 sentinel; header sets hold eight-u32 records with an
-- eight-word -2 sentinel.
PokegearSources.resdatListWords = 6
PokegearSources.resdatHeaderWords = 8

-- Observed HeartGold header transfer modes use CPU transfer; the small
-- transfer-mode domain rejects garbage without enumerating every Nintendo
-- revision.
PokegearSources.supportedTransferModes = { [0] = true, [1] = true, [2] = true, [3] = true }

-- Source skin selectors for skin index s in 0..5. Shell, Configure, Phone,
-- and Radio members hold one chunk each; map members bundle their own
-- character, screen, and palette chunks, so map visuals render
-- self-contained members while the world base keeps its cross-member
-- character/screen selection.
PokegearSources.skins = { 0, 1, 2, 3, 4, 5 }

function PokegearSources.shellForeground(skin)
  return { char = 48 + skin, screen = 54 + skin, palette = 30 + skin }
end

function PokegearSources.shellInformation(skin)
  return { char = 36 + skin, screen = 42 + skin, palette = 24 + skin }
end

PokegearSources.shellCursor = { cell = 12, anim = 13 }

function PokegearSources.configureForeground(skin)
  return { char = 10 + skin, screen = 16 + skin, palette = 4 + skin }
end

function PokegearSources.configurePatch(skin)
  return { char = 10 + skin, screen = 22 + skin, palette = 4 + skin }
end

function PokegearSources.phoneForeground(skin)
  return { char = 28 + skin, screen = 34 + skin, palette = 10 + skin }
end

function PokegearSources.phoneUpper(skin)
  return { char = 16 + skin, screen = 22 + skin, palette = 4 + skin }
end

function PokegearSources.radioMain(skin)
  return { char = 16 + skin, screen = 22 + skin, palette = 10 + skin }
end

function PokegearSources.radioSecond(skin)
  return { char = 16 + skin, screen = 28 + skin, palette = 10 + skin }
end

function PokegearSources.radioUpper(skin)
  return { char = 34 + skin, screen = 40 + skin, palette = 4 + skin }
end

-- Map foreground, upper, and patch planes share the skin foreground
-- tileset: foreground pairs tiles 26+s with the first skin-varying
-- screen run, upper pairs tiles 50+s with the shared screen 13, and each
-- patch pairs the same skin tileset with its source patch screen.
function PokegearSources.mapForeground(skin)
  return { char = 26 + skin, screen = 32 + skin, palette = 20 + skin }
end

function PokegearSources.mapUpper(skin)
  return { chars = { 50 + skin, 12 }, screen = 13, palette = 14 + skin }
end

PokegearSources.mapUpperBase = { char = 12, screen = 13, palette = 14 }

PokegearSources.mapPatchBases = { 32, 38, 44, 56 }

function PokegearSources.mapPatchScreen(skin, patchIndex)
  return PokegearSources.mapPatchBases[patchIndex] + skin
end

function PokegearSources.mapPatch(skin, patchIndex)
  return { screen = PokegearSources.mapPatchScreen(skin, patchIndex) }
end

PokegearSources.mapWorld = { char = 10, screen = 11 }

function PokegearSources.mapWorldPalette(skin)
  return 14 + skin
end

PokegearSources.flyPairs = {
  { char = 64, screen = 65 },
  { char = 66, screen = 67 },
  { char = 68, screen = 69 },
}
PokegearSources.flyPalette = 62

-- Native radio broadcast programs in source program order with the
-- executable station schedule and the version-qualified daily and text
-- constants the producer validates. Message bank/entry references are
-- compiled token identities; no broadcast prose lives here. The runtime
-- show modules own the matching retail policy constants; the pinned
-- password token and reply references are proven to agree by the
-- broadcast conformance vectors.
PokegearSources.broadcastVersions = { heartgold = true, soulsilver = true }

PokegearSources.broadcastShows = {
  { key = "radio.music", versions = { heartgold = true, soulsilver = true } },
  { key = "radio.talk", versions = { heartgold = true, soulsilver = true } },
  { key = "radio.search-party", versions = { heartgold = true, soulsilver = true } },
  { key = "radio.serial-drama", versions = { heartgold = true, soulsilver = true } },
  { key = "radio.buena", versions = { heartgold = true, soulsilver = true } },
  { key = "radio.trainer-profiles", versions = { heartgold = true, soulsilver = true } },
  { key = "radio.town-people", versions = { heartgold = true, soulsilver = true } },
  { key = "radio.poke-flute", versions = { heartgold = true, soulsilver = true } },
  { key = "radio.unown", versions = { heartgold = true, soulsilver = true } },
  { key = "radio.rocket", versions = { heartgold = true, soulsilver = true } },
  { key = "radio.mahogany", versions = { heartgold = true, soulsilver = true } },
  { key = "radio.commercial", versions = { heartgold = true, soulsilver = true } },
}

-- Executable station schedule: fixed stations keep one show, one station
-- alternates two shows by even/odd hour, and one cycles three shows by
-- hour modulo three.
PokegearSources.broadcastSchedule = {
  fixed = {
    [0] = "radio.music",
    [1] = "radio.talk",
    [4] = "radio.poke-flute",
    [5] = "radio.unown",
    [6] = "radio.rocket",
    [7] = "radio.mahogany",
  },
  alternating = { station = 2, period = 2, shows = { "radio.trainer-profiles", "radio.town-people" } },
  cycling = { station = 3, period = 3, shows = { "radio.search-party", "radio.serial-drama", "radio.buena" } },
}

-- Per-show message token references by semantic show key. Banks and
-- entries are field message identities, one-based entry numbers.
PokegearSources.broadcastMessages = {
  ["radio.music"] = {
    title = { bank = 500, entry = 1 },
    intro = { bank = 500, entry = 2 },
    march = { bank = 500, entry = 10 },
    lullaby = { bank = 500, entry = 11 },
    hoenn = { bank = 500, entry = 12 },
    sinnoh = { bank = 500, entry = 13 },
    cardSelection = { bank = 500, entry = 14 },
    marchAlternate = { bank = 500, entry = 15 },
  },
  ["radio.talk"] = {
    title = { bank = 501, entry = 1 },
    intro = { bank = 501, entry = 2 },
    outbreak = { bank = 501, entry = 3 },
    detail = { bank = 501, entry = 5 },
    pairBase = { bank = 502, entryBase = 1, pairCount = 5 },
  },
  ["radio.search-party"] = {
    title = { bank = 503, entry = 1 },
    lines = { bank = 503, firstEntry = 2, lineCount = 4 },
  },
  ["radio.serial-drama"] = {
    title = { bank = 504, entry = 1 },
    lines = { bank = 504, firstEntry = 2, lineCount = 4 },
  },
  ["radio.buena"] = {
    intro = { bank = 411, entry = 1 },
    introContinue = { bank = 411, entry = 2 },
    message4 = { bank = 411, entry = 3 },
    tokenBank = 66,
    tokenBase = 40,
    replyBank = 411,
    replyWithCard = 4,
    replyWithoutCard = 5,
  },
  ["radio.trainer-profiles"] = {
    title = { bank = 505, entry = 1 },
    lines = { bank = 505, firstEntry = 2, lineCount = 4 },
  },
  ["radio.town-people"] = {
    title = { bank = 506, entry = 1 },
    lines = { bank = 506, firstEntry = 2, lineCount = 4 },
  },
  ["radio.poke-flute"] = {
    title = { bank = 507, entry = 1 },
    lines = { bank = 507, firstEntry = 2, lineCount = 2 },
  },
  ["radio.unown"] = {
    title = { bank = 508, entry = 1 },
    lines = { bank = 508, firstEntry = 2, lineCount = 2 },
  },
  ["radio.rocket"] = {
    title = { bank = 509, entry = 1 },
    lines = { bank = 509, firstEntry = 2, lineCount = 2 },
    takeoverLines = { bank = 509, firstEntry = 4, lineCount = 2 },
  },
  ["radio.mahogany"] = {
    title = { bank = 510, entry = 1 },
    lines = { bank = 510, firstEntry = 2, lineCount = 2 },
  },
  ["radio.commercial"] = {
    title = { bank = 511, entry = 1 },
    lines = { bank = 511, firstEntry = 2, lineCount = 2 },
  },
}

-- Daily broadcast constants: the shared password identity modulus, the
-- card-selection table shape, and the talk flavor moduli.
PokegearSources.broadcastDaily = {
  passwordModulo = 30,
  cardSelectionDivisor = 25000,
  cardSelectionSlice = 1000,
  cardSelectionEntries = 25,
  talkPairs = 5,
  talkStepDivisor = 3,
  talkPhraseModulo = 13,
}

-- Talk broadcast landmark selection: the eligible landmark token set with
-- its explicit filter list and the flypoint-gated tokens, which stay shut
-- without the real flypoint facts.
PokegearSources.broadcastTalkMaps = {
  eligible = { 3, 5, 6, 9, 11, 14, 15, 19, 21, 22, 26, 29, 47, 48 },
  filtered = { [9] = true, [22] = true },
  gated = { [47] = true, [48] = true },
}

-- Line progression and reception constants: the initial print delay, the
-- in-episode scroll cadence, the post-episode tail, and the reception
-- static parameter applied to the display copy only.
PokegearSources.broadcastText = {
  initialDelayFrames = 45,
  scrollFrames = 8,
  postEpisodeScrollFrames = 16,
  postEpisodeDelayFrames = 15,
  staticParameter = 70,
}

-- Region-map location and flypoint records for the compiled map catalog.
-- Identities stay in five distinct roles because several places share a
-- label: the field map symbol, the world-matrix anchor, the displayed
-- location, the map section, and the flypoint. Outdoor main-matrix maps
-- carry a matrix anchor in world coordinates and no header coordinates;
-- their world cell is the anchor divided by thirty-two. Indoor and cave
-- maps carry their explicit header world coordinates verbatim from the
-- frozen map-header reference (romdump/src/reference/hgss/maps.lua); a
-- map with both header coordinates zero resolves through the
-- last-exterior fallback instead. The four special locations keep their
-- tabled source coordinates: Mt Silver and Indigo resolve through the
-- header coordinates tabled for their areas rather than matrix division,
-- and the Sinjoh and S.S. Aqua maps keep their tabled coordinates
-- regardless of exterior state. Matrix anchors for outdoor maps are the
-- destination-global arrival coordinates transcribed in
-- FieldMoveSources.SPAWN_DESTINATIONS; indoor matrix anchors repeat the
-- explicit coordinates times thirty-two so the anchor divided by
-- thirty-two stays the header cell. mapRef is the numeric map-header id
-- from the same frozen reference, letting runtime marker projections
-- match encounter map facts without parsing ROM data. Region follows the
-- header region field. Flypoint keys name the retail fly destinations
-- among these locations; other locations carry no flypoint.
PokegearSources.mapVersions = { heartgold = true, soulsilver = true }

PokegearSources.mapLocations = {
  {
    key = "hg.place.new-bark",
    fieldMap = "MAP_NEW_BARK",
    mapRef = 60,
    matrix = { x = 695, y = 397 },
    location = "hg.location.new-bark-town",
    section = "hg.section.new-bark-town",
    region = "johto",
    flypoint = "hg.flypoint.new-bark",
  },
  {
    key = "hg.place.violet",
    fieldMap = "MAP_VIOLET",
    mapRef = 73,
    matrix = { x = 497, y = 272 },
    location = "hg.location.violet-city",
    section = "hg.section.violet-city",
    region = "johto",
    flypoint = "hg.flypoint.violet",
  },
  {
    key = "hg.place.route-26",
    fieldMap = "MAP_ROUTE_26",
    mapRef = 30,
    matrix = { x = 909, y = 297 },
    location = "hg.location.route-26",
    section = "hg.section.route-26",
    region = "kanto",
    flypoint = false,
  },
  {
    key = "hg.place.pallet",
    fieldMap = "MAP_PALLET",
    mapRef = 49,
    matrix = { x = 1033, y = 364 },
    location = "hg.location.pallet-town",
    section = "hg.section.pallet-town",
    region = "kanto",
    flypoint = "hg.flypoint.pallet",
  },
  {
    key = "hg.place.mount-silver",
    fieldMap = "MAP_MOUNT_SILVER",
    mapRef = 90,
    matrix = { x = 820, y = 266 },
    location = "hg.location.mount-silver",
    section = "hg.section.mount-silver",
    region = "johto",
    flypoint = "hg.flypoint.mount-silver",
    explicitX = 25,
    explicitY = 8,
    special = "mt-silver",
  },
  {
    key = "hg.place.indigo-plateau",
    fieldMap = "MAP_INDIGO_PLATEAU",
    mapRef = 58,
    matrix = { x = 912, y = 201 },
    location = "hg.location.indigo-plateau",
    section = "hg.section.indigo-plateau",
    region = "kanto",
    flypoint = "hg.flypoint.indigo-plateau",
    explicitX = 28,
    explicitY = 6,
    special = "indigo",
  },
  {
    key = "hg.place.sinjoh-ruins",
    fieldMap = "MAP_SINJOH_RUINS_EXTERIOR",
    mapRef = 521,
    matrix = { x = 640, y = 32 },
    location = "hg.location.sinjoh-ruins",
    section = "hg.section.sinjoh-ruins",
    region = "johto",
    flypoint = false,
    explicitX = 20,
    explicitY = 1,
    special = "sinjoh",
  },
  {
    key = "hg.place.ss-aqua",
    fieldMap = "MAP_SS_AQUA_1F",
    mapRef = 307,
    matrix = { x = 800, y = 448 },
    location = "hg.location.ss-aqua",
    section = "hg.section.ss-aqua",
    region = "johto",
    flypoint = false,
    explicitX = 25,
    explicitY = 14,
    special = "aqua",
  },
  {
    key = "hg.place.new-bark-player-house",
    fieldMap = "MAP_NEW_BARK_PLAYER_HOUSE_1F",
    mapRef = 63,
    matrix = { x = 672, y = 384 },
    location = "hg.location.new-bark-town",
    section = "hg.section.new-bark-town",
    region = "johto",
    flypoint = false,
    explicitX = 21,
    explicitY = 12,
  },
  {
    key = "hg.place.ecruteak-gym",
    fieldMap = "MAP_ECRUTEAK_GYM",
    mapRef = 80,
    matrix = { x = 352, y = 160 },
    location = "hg.location.ecruteak-city",
    section = "hg.section.ecruteak-city",
    region = "johto",
    flypoint = false,
    explicitX = 11,
    explicitY = 5,
  },
  {
    key = "hg.place.league-wifi-room",
    fieldMap = "MAP_POKEMON_LEAGUE_ENTRANCE_WIFI_ROOM",
    mapRef = 539,
    matrix = { x = 896, y = 192 },
    location = "hg.location.pokemon-league",
    section = "hg.section.pokemon-league",
    region = "johto",
    flypoint = false,
    explicitX = 0,
    explicitY = 0,
  },
}

PokegearSources.mapFlypoints = {
  { key = "hg.flypoint.new-bark" },
  { key = "hg.flypoint.violet" },
  { key = "hg.flypoint.pallet" },
  { key = "hg.flypoint.mount-silver" },
  { key = "hg.flypoint.indigo-plateau" },
}

-- Version-qualified catalog location records for one game version. Both
-- versions share the same geography; the version is still validated so an
-- unsupported version fails loudly instead of compiling an empty map.
-- Returns detached copies; mutating them never touches the producer table.
---@param versionId string
---@return table<integer, table<string, unknown>>
function PokegearSources.mapLocationRecords(versionId)
  assert(type(versionId) == "string" and versionId ~= "", "map location records need a game version")
  assert(
    PokegearSources.mapVersions[versionId] == true,
    "map location records name a supported game version, got " .. versionId
  )
  local records = {}
  for _, entry in ipairs(PokegearSources.mapLocations) do
    local copy = { matrix = { x = entry.matrix.x, y = entry.matrix.y } }
    for key, value in pairs(entry) do
      if key ~= "matrix" then
        copy[key] = value
      end
    end
    records[#records + 1] = copy
  end
  assert(#records > 0, "map location records cover the region map for " .. versionId)
  return records
end

-- Version-qualified catalog flypoint records for one game version.
-- Returns detached copies; mutating them never touches the producer table.
---@param versionId string
---@return table<integer, table<string, string>>
function PokegearSources.mapFlypointRecords(versionId)
  assert(type(versionId) == "string" and versionId ~= "", "map flypoint records need a game version")
  assert(
    PokegearSources.mapVersions[versionId] == true,
    "map flypoint records name a supported game version, got " .. versionId
  )
  local records = {}
  for _, entry in ipairs(PokegearSources.mapFlypoints) do
    records[#records + 1] = { key = entry.key }
  end
  assert(#records > 0, "map flypoint records cover the fly destinations for " .. versionId)
  return records
end

-- Version-qualified catalog show records for one game version, in source
-- program order. Unknown versions fail loudly; a version carrying no
-- show is a producer error, never an empty broadcast band.
---@param versionId string
---@return table<integer, table<string, string>>
function PokegearSources.broadcastShowRecords(versionId)
  assert(type(versionId) == "string" and versionId ~= "", "broadcast show records need a game version")
  assert(
    PokegearSources.broadcastVersions[versionId] == true,
    "broadcast show records name a supported game version, got " .. versionId
  )
  local records = {}
  for _, show in ipairs(PokegearSources.broadcastShows) do
    assert(type(show.key) == "string" and show.key ~= "", "broadcast shows carry semantic keys")
    if show.versions[versionId] == true then
      records[#records + 1] = { key = show.key }
    end
  end
  assert(#records > 0, "broadcast show records cover the native program set for " .. versionId)
  return records
end

-- Per-contact conversation families in phonebook-id order: the closed
-- caller-family disposition behind the foreground phone dispatch, in the
-- same contact order as the message-bank table below. Special callers
-- name their decomp PHONE_CONTACT_* family (trailing names); every other
-- native contact follows the ordinary trainer conversation. Position
-- i + 1 carries contact i's family. The runtime resolves programs from
-- this generated type, never from key substrings.
PokegearSources.phoneContactFamilies = {
  "mother", -- mother
  "elm", -- elm
  "oak", -- oak
  "friend", -- ethan
  "friend", -- lyra
  "kurt", -- kurt
  "daycare", -- day-care man
  "daycare", -- day-care lady
  "buena", -- buena
  "bill", -- bill
  "trainer", -- joey
  "trainer", -- ralph
  "trainer", -- liz
  "trainer", -- wade
  "trainer", -- anthony
  "bike", -- bike shop
  "kenji", -- kenji
  "gym", -- whitney
  "gym", -- falkner
  "trainer", -- jack
  "trainer", -- chad
  "trainer", -- brent
  "trainer", -- todd
  "trainer", -- arnie
  "baoba", -- baoba
  "irwin", -- irwin
  "gym", -- janine
  "gym", -- clair
  "gym", -- erika
  "gym", -- misty
  "gym", -- blaine
  "gym", -- blue
  "gym", -- chuck
  "gym", -- brock
  "gym", -- bugsy
  "gym", -- sabrina
  "gym", -- lt. surge
  "gym", -- morty
  "gym", -- jasmine
  "gym", -- pryce
  "trainer", -- huey
  "trainer", -- gaven
  "trainer", -- jamie
  "trainer", -- reena
  "trainer", -- vance
  "trainer", -- parry
  "trainer", -- erin
  "trainer", -- beverly
  "trainer", -- jose
  "trainer", -- gina
  "trainer", -- alan
  "trainer", -- dana
  "trainer", -- derek
  "trainer", -- tully
  "trainer", -- tiffany
  "trainer", -- wilton
  "trainer", -- krise
  "trainer", -- ian
  "trainer", -- walt
  "trainer", -- alfred
  "trainer", -- doug
  "trainer", -- rob
  "trainer", -- kyle
  "trainer", -- kyler
  "trainer", -- tim and sue
  "trainer", -- kenny
  "trainer", -- tanner
  "trainer", -- josh
  "trainer", -- torin
  "trainer", -- hillary
  "trainer", -- billy
  "trainer", -- kay and tia
  "trainer", -- reese
  "trainer", -- aiden
  "trainer", -- ernest
}

-- Corpus-observed phone-trigger slots: the full script census carries
-- exactly one trigger-mutation site (the Pokecenter heal script clears
-- slot 1 beside its heal operation) and no script ever sets a trigger.
-- The slot reads as the phonebook contact identity the sibling clear
-- sites corroborate (slot 12 clears inside the Mom-gift script, slot 5
-- inside the Day-Care egg-call script); slot 1 is Elm's contact,
-- registered through the town-exit script. Only observed slots are
-- listed: an unobserved slot would invent a caller the source never
-- switches.
PokegearSources.phoneTriggers = {
  { slot = 1, key = "gear.trigger.1", contact = "hg.trainer.201.map.0.contact.1", kind = 0 },
}

-- Version-qualified catalog phone-trigger records for one game version.
-- Unknown versions fail loudly; a version carrying no trigger is a
-- producer error, never an empty trigger set. Kind 0 is the ordinary
-- callback the incoming-call contract records in history at acceptance.
-- Returns detached copies; mutating them never touches the producer table.
---@param versionId string
---@return table<integer, table<string, unknown>>
function PokegearSources.phoneTriggerRecords(versionId)
  assert(type(versionId) == "string" and versionId ~= "", "phone trigger records need a game version")
  assert(
    PokegearSources.mapVersions[versionId] == true,
    "phone trigger records name a supported game version, got " .. versionId
  )
  local records = {}
  for _, entry in ipairs(PokegearSources.phoneTriggers) do
    assert(type(entry.key) == "string" and entry.key ~= "", "phone triggers carry semantic keys")
    assert(type(entry.contact) == "string" and entry.contact ~= "", "phone triggers carry their owning contact")
    records[#records + 1] = { key = entry.key, contact = entry.contact, kind = entry.kind }
  end
  assert(#records > 0, "phone trigger records cover the observed trigger set for " .. versionId)
  return records
end

return PokegearSources
