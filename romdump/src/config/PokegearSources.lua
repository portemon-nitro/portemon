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
    "src/mom_gift.c",
    "include/constants/phone_contacts.h",
    "include/constants/items.h",
    "src/application/pokegear/radio/overlay_101_021F57B8.c",
    "src/application/pokegear/radio/pokegear_radio.c",
    "src/map_header.c",
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

-- Native caller class labels use message bank 0730 for standard trainer
-- classes and bank 0271 for the special phone-only classes. These values
-- follow overlay_101_021F1D74.c and message_format.c at the pinned source.
PokegearSources.phoneClassLabels = {
  motherClass = 200,
  professorClass = 201,
  specialBank = 271,
  specialFirstEntry = 38,
  trainerBank = 730,
  landmarkBank = 279,
  landmarkFallbackBank = 280,
  landmarkFallbackEntry = 2,
}

-- The phonebook record is little-endian four bytes, four halfwords, eight
-- bytes: contact id, entry type, contact class, trainer class; map, gift, local
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

-- The contact list window prints with background palette bank 2 of the
-- phone foreground palette, sixteen colors per skin.
PokegearSources.phoneListPaletteBank = 2

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

-- Map planes follow the source background layers. The lower screen holds
-- the chrome (26+s tiles, screen 32+s), the 512x512 world (shared world
-- tiles, screen 11) on the main palette 20+s, and the marking-mode panel
-- (screen 38+s) and backdrop (screen 44+s) which draw from the chrome
-- tiles. The upper screen holds the information chrome (50+s tiles, screen
-- 56+s) and the 7x7 location-preview atlas (shared tiles 12, screen 13),
-- both on the sub palette 14+s.
function PokegearSources.mapForeground(skin)
  return { char = 26 + skin, screen = 32 + skin, palette = 20 + skin }
end

function PokegearSources.mapWorld(skin)
  return { char = 10, screen = 11, palette = 20 + skin }
end

function PokegearSources.mapMarkingPanel(skin)
  return { char = 26 + skin, screen = 38 + skin, palette = 20 + skin }
end

function PokegearSources.mapMarkingBackdrop(skin)
  return { char = 26 + skin, screen = 44 + skin, palette = 20 + skin }
end

function PokegearSources.mapUpper(skin)
  return { char = 50 + skin, screen = 56 + skin, palette = 14 + skin }
end

function PokegearSources.mapPreviews(skin)
  return { char = 12, screen = 13, palette = 14 + skin }
end

-- The message bank behind the region map's panel strings, location flavor
-- text, and Fly prompts (landmark names read from the phone landmark bank).
PokegearSources.regionMapMessageBank = 273

-- Text colors of the map windows: the upper windows print with sub palette
-- bank 1 (member 14+s), the marking-mode landmark name with main palette
-- bank 10 (member 20+s), and the marking word text objects with object
-- palette member 0 bank 3. Fly uses members 62 (upper) and 63 (lower).
PokegearSources.mapTextBanks = { upper = 1, lower = 10, word = 3, wordMember = 0 }

function PokegearSources.mapTextMembers(skin)
  return { upper = 14 + skin, lower = 20 + skin }
end

PokegearSources.flyTextMembers = { upper = 62, lower = 63 }

-- The touchscreen list menu graphics the Fly context menu draws with: the
-- shared sbox_gra archive's palette (member 0) and character tiles (member 1).
PokegearSources.listMenu = { path = "a/1/6/5", palette = 0, char = 1 }

-- The Fly entry loads its own skin-independent planes: main palette 63 for
-- the chrome and world, sub palette 62 for the upper screen.
PokegearSources.fly = {
  world = { char = 10, screen = 11, palette = 63 },
  foreground = { char = 66, screen = 67, palette = 63 },
  top = { char = 64, screen = 65, palette = 62 },
  upper = { char = 68, screen = 69, palette = 62 },
  previews = { char = 12, screen = 13, palette = 62 },
}

-- Map-app OBJ sprite sets of a/1/4/4, every set drawn with the shared OBJ
-- palette member 0 (11 banks). The set names follow the retail object
-- resource lists (sprite resource sets 0, 1, and 2 are members 4-6, 1-3,
-- and 7-9). `banks` gives the zero-based NCLR bank each source sequence
-- (one-based, as compiled) draws with; unlisted sequences use bank 0. The
-- map app overrides the OBJ palette number to 4 + bank and the Fly entry to
-- the bank itself. The word plate is the OBJ footprint of the marking word
-- text, which the app draws with OBJ palette 7 (bank 3).
PokegearSources.mapSpritePalette = 0

PokegearSources.mapSprites = {
  markers = { char = 4, cell = 5, anim = 6, banks = {} },
  mapObjects = { char = 1, cell = 2, anim = 3, banks = { [6] = 2, [7] = 2, [8] = 2, [9] = 2 } },
  wordPlate = { char = 7, cell = 8, anim = 9, banks = { [1] = 3 } },
}

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

-- Per-contact phone message banks in phonebook-id order: the exact
-- sPhoneMessageGmm table behind GetPhoneMessageGmm (src/phonebook_dat.c),
-- mapping each phonebook contact to the message bank holding that
-- caller's script messages. Position i + 1 carries contact i's bank.
-- The per-contact greeting number beside it in the catalog record is the
-- source phone-script selector (PhoneBookEntry.phoneScriptIfLocal), not a
-- bank entry: the script table (gPhoneCallScriptDef, 455 scripts) maps
-- each selector onto its bank message pair, so a greeting number only
-- resolves as a direct bank entry where the script table maps it onto
-- itself. Every bank falls in msg_0641..msg_0716; msg_0668 has no caller
-- and is absent. Trailing names are the decomp PHONE_CONTACT_*
-- identities in table order.
PokegearSources.phoneMessageBanks = {
  664, -- mother
  716, -- elm
  666, -- oak
  662, -- ethan
  663, -- lyra
  643, -- kurt
  661, -- day-care man
  660, -- day-care lady
  641, -- buena
  665, -- bill
  675, -- joey
  712, -- ralph
  680, -- liz
  684, -- wade
  711, -- anthony
  642, -- bike shop
  706, -- kenji
  644, -- whitney
  648, -- falkner
  704, -- jack
  685, -- chad
  688, -- brent
  713, -- todd
  714, -- arnie
  667, -- baoba
  691, -- irwin
  645, -- janine
  649, -- clair
  646, -- erika
  650, -- misty
  651, -- blaine
  647, -- blue
  656, -- chuck
  657, -- brock
  658, -- bugsy
  655, -- sabrina
  652, -- lt. surge
  653, -- morty
  654, -- jasmine
  659, -- pryce
  674, -- huey
  705, -- gaven
  677, -- jamie
  698, -- reena
  696, -- vance
  708, -- parry
  672, -- erin
  690, -- beverly
  671, -- jose
  695, -- gina
  689, -- alan
  700, -- dana
  693, -- derek
  694, -- tully
  669, -- tiffany
  676, -- wilton
  715, -- krise
  703, -- ian
  710, -- walt
  670, -- alfred
  692, -- doug
  681, -- rob
  697, -- kyle
  687, -- kyler
  702, -- tim and sue
  699, -- kenny
  707, -- tanner
  682, -- josh
  673, -- torin
  686, -- hillary
  683, -- billy
  679, -- kay and tia
  701, -- reese
  709, -- aiden
  678, -- ernest
}

-- Distinct message banks referenced by the per-contact phone index, in
-- stable order, for the demandable bank pipeline. The set deduplicates
-- against source-referenced banks (msg_0666 already rides the script
-- bank set); msg_0668 stays absent with no caller behind it.
---@return integer[]
function PokegearSources.phoneMessageBankIds()
  local seen = {}
  local ids = {}
  for _, bank in ipairs(PokegearSources.phoneMessageBanks) do
    assert(type(bank) == "number" and bank % 1 == 0 and bank >= 0, "phone message banks stay bank ids")
    if seen[bank] ~= true then
      seen[bank] = true
      ids[#ids + 1] = bank
    end
  end
  table.sort(ids)
  return ids
end

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
  { slot = 12, key = "gear.trigger.12", contact = "hg.trainer.200.map.0.contact.0", kind = 3, clearOnPickup = true },
}

-- Native Mom purchases and resistance-berry choices from mom_gift.c.
-- Item IDs are resolved through ItemCatalog before entering saved state.
PokegearSources.momPurchases = {
  { sourceIndex = 0, nativeItemId = 26, threshold = 900, cost = 600 },
  { sourceIndex = 1, nativeItemId = 79, threshold = 4000, cost = 270 },
  { sourceIndex = 2, nativeItemId = 26, threshold = 7000, cost = 600 },
  { sourceIndex = 3, nativeItemId = 251, threshold = 10000, cost = 100 },
  { sourceIndex = 4, nativeItemId = 81, threshold = 15000, cost = 3000 },
  { sourceIndex = 5, nativeItemId = 25, threshold = 19000, cost = 900 },
  { sourceIndex = 6, nativeItemId = 287, threshold = 30000, cost = 200 },
  { sourceIndex = 7, nativeItemId = 266, threshold = 40000, cost = 200 },
  { sourceIndex = 8, nativeItemId = 275, threshold = 50000, cost = 200 },
}

PokegearSources.momBerryItemIds = {
  149,
  150,
  151,
  152,
  153,
  154,
  155,
  156,
  157,
  158,
  159,
  160,
  161,
  162,
  163,
  164,
  165,
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
  local seenSlots = {}
  for _, entry in ipairs(PokegearSources.phoneTriggers) do
    assert(not seenSlots[entry.slot], "phone trigger slots are unique")
    seenSlots[entry.slot] = true
    assert(type(entry.key) == "string" and entry.key ~= "", "phone triggers carry semantic keys")
    assert(type(entry.contact) == "string" and entry.contact ~= "", "phone triggers carry their owning contact")
    records[#records + 1] = {
      slot = entry.slot,
      key = entry.key,
      contact = entry.contact,
      kind = entry.kind,
      clearOnPickup = entry.clearOnPickup == true,
    }
  end
  assert(#records > 0, "phone trigger records cover the observed trigger set for " .. versionId)
  return records
end

---@param versionId string
---@return table<string, table<integer, table<string, integer>>> source purchase and berry vectors
function PokegearSources.momPurchaseRecords(versionId)
  assert(
    type(versionId) == "string" and PokegearSources.mapVersions[versionId] == true,
    "Mom purchases need a supported version"
  )
  local records = {}
  for index, entry in ipairs(PokegearSources.momPurchases) do
    assert(entry.sourceIndex == index - 1, "Mom purchase indices preserve source order")
    records[#records + 1] = {
      kind = "purchase",
      sourceIndex = entry.sourceIndex,
      nativeItemId = entry.nativeItemId,
      threshold = entry.threshold,
      cost = entry.cost,
    }
  end
  for index, nativeItemId in ipairs(PokegearSources.momBerryItemIds) do
    records[#records + 1] = {
      kind = "berry",
      sourceIndex = index - 1,
      nativeItemId = nativeItemId,
      threshold = 0,
      cost = 100,
    }
  end
  assert(
    #PokegearSources.momPurchases == 9 and #PokegearSources.momBerryItemIds == 17,
    "Mom gift source vectors stay complete"
  )
  return records
end

-- Native radio reception sets in source order. Alph (5) and Mahogany (17)
-- are the exact sAlphMaps/sMahoganyMaps lists behind Radio_IsInSpecialMap:
-- section membership does not reproduce them (RUINS_OF_ALPH covers 21
-- header maps, MAHOGANY_TOWN covers 8, while the source lists 5 and 17
-- across four sections including Rocket HQ, Route 43, and Lake of Rage).
-- Forbidden (34) is every header map with radioSignal false, the exact
-- predicate behind MapHeader_CanReceiveRadioSignal. Region itself stays on
-- the header region field the runtime already reads; no region set is
-- compiled here. Policy order (forbidden, Alph, Kanto/power/EXPN,
-- Mahogany/hideout, takeover, Johto) stays in RadioReception.
PokegearSources.radioAlphMaps = {
  "MAP_RUINS_OF_ALPH_UNDERGROUND_HALL",
  "MAP_RUINS_OF_ALPH_HALL_ENTRANCE",
  "MAP_RUINS_OF_ALPH_UNDERGROUND_HALL_SINJOH_EVENT",
  "MAP_RUINS_OF_ALPH_HALL_ENTRANCE_SINJOH_EVENT",
  "MAP_RUINS_OF_ALPH_UNDERGROUND_HALL_SINJOH_EVENT_2",
}

PokegearSources.radioMahoganyMaps = {
  "MAP_MAHOGANY",
  "MAP_MAHOGANY_EAST_HOUSE",
  "MAP_MAHOGANY_GYM_LEADER_ROOM",
  "MAP_MAHOGANY_GYM_ROOM_2",
  "MAP_MAHOGANY_GYM_ROOM_1",
  "MAP_MAHOGANY_POKECENTER_1F",
  "MAP_MAHOGANY_POKECENTER_B1F",
  "MAP_MAHOGANY_SOUVENIR_SHOP",
  "MAP_TEAM_ROCKET_HEADQUARTERS_B1F",
  "MAP_TEAM_ROCKET_HEADQUARTERS_B2F",
  "MAP_TEAM_ROCKET_HEADQUARTERS_B3F",
  "MAP_ROUTE_43",
  "MAP_ROUTE_43_MAHOGANY_GATEHOUSE",
  "MAP_ROUTE_43_GATEHOUSE",
  "MAP_LAKE_OF_RAGE",
  "MAP_LAKE_OF_RAGE_HIDDEN_POWER_HOUSE",
  "MAP_LAKE_OF_RAGE_FISHING_GURU_HOUSE",
}

PokegearSources.radioForbiddenMaps = {
  "MAP_EVERYWHERE",
  "MAP_NOTHING",
  "MAP_UNION",
  "MAP_UNDERGROUND",
  "MAP_WIFI_SINGLE_BATTLE_AREA",
  "MAP_WIFI_MULTI_BATTLE_AREA",
  "MAP_WHIRL_ISLANDS_B3F_LUGIA_CAVE",
  "MAP_BATTLE_TOWER_ELEVATOR",
  "MAP_BATTLE_TOWER_UNUSED_1",
  "MAP_BATTLE_TOWER_UNUSED_2",
  "MAP_BATTLE_TOWER_UNUSED_3",
  "MAP_BATTLE_TOWER_UNUSED_4",
  "MAP_BATTLE_FRONTIER_BATTLE_FACTORY",
  "MAP_BATTLE_FRONTIER_BATTLE_HALL",
  "MAP_BATTLE_FRONTIER_BATTLE_CASTLE",
  "MAP_BATTLE_FRONTIER_BATTLE_ARCADE",
  "MAP_BELL_TOWER_ROOF",
  "MAP_SAFARI_ZONE_01",
  "MAP_SAFARI_ZONE_02",
  "MAP_SAFARI_ZONE_03",
  "MAP_SAFARI_ZONE_04",
  "MAP_SAFARI_ZONE_05",
  "MAP_SAFARI_ZONE_06",
  "MAP_SAFARI_ZONE_07",
  "MAP_SAFARI_ZONE_08",
  "MAP_SAFARI_ZONE_09",
  "MAP_SAFARI_ZONE_10",
  "MAP_SAFARI_ZONE_11",
  "MAP_SAFARI_ZONE_12",
  "MAP_SAFARI_ZONE_13",
  "MAP_SAFARI_ZONE_14",
  "MAP_WIFI_PLAZA_WARP_ROOM",
  "MAP_SINJOH_RUINS_MYSTRI_STAGE",
  "MAP_UNUSED",
}

-- Version-qualified catalog radio reception sets for one game version.
-- Unknown versions fail loudly; a version carrying no set is a producer
-- error, never an empty reception table. Both versions share the same
-- header-derived sets; the version is still validated so an unsupported
-- version fails loudly instead of compiling an empty map.
-- Returns detached copies; mutating them never touches the producer tables.
---@param versionId string
---@return { alph: string[], mahogany: string[], forbidden: string[] }
function PokegearSources.radioReceptionRecords(versionId)
  assert(type(versionId) == "string" and versionId ~= "", "radio reception records need a game version")
  assert(
    PokegearSources.mapVersions[versionId] == true,
    "radio reception records name a supported game version, got " .. versionId
  )
  local function copy(list)
    local out = {}
    for index, symbol in ipairs(list) do
      assert(type(symbol) == "string" and symbol ~= "", "reception sets carry map symbols")
      out[index] = symbol
    end
    return out
  end
  local records = {
    alph = copy(PokegearSources.radioAlphMaps),
    mahogany = copy(PokegearSources.radioMahoganyMaps),
    forbidden = copy(PokegearSources.radioForbiddenMaps),
  }
  assert(
    #records.alph > 0 and #records.mahogany > 0 and #records.forbidden > 0,
    "radio reception records cover the source sets for " .. versionId
  )
  return records
end

return PokegearSources
