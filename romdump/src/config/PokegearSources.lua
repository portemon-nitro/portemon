-- Source selectors for the HGSS Pokegear applications: the five core
-- graphics archives, the twenty sprite resource descriptor members, and the
-- whole-file phonebook. Member ranges are HeartGold evidence anchors kept
-- beside the producer; runtime records never carry them.

local PokegearSources = {}

PokegearSources.provenance = {
  romAudit = "retail ROM",
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
-- follow overlay_101_021F1D74.c and message_format.c.
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

-- The phonebook record follows the native PhoneBookEntry struct exactly:
-- id, entry type, unused byte, trainer class, trainer id, map id, gift
-- item, local phone-script selector, greeting set, rematch weekday,
-- rematch time of day, random-call group, and four sort bytes. Member
-- order is the struct order; contact keys keep the historical
-- trainer.map.contact shape over the trainer-class and trainer-id
-- bytes.
PokegearSources.phonebookFields = {
  "id",
  "entryType",
  "unused",
  "trainerClass",
  "trainerId",
  "mapId",
  "gift",
  "phoneScriptIfLocal",
  "greetingMsgSet",
  "rematchWeekday",
  "rematchTimeOfDay",
  "randomCallGroup",
  "sortWeight0",
  "sortWeight1",
  "sortWeight2",
  "sortWeight3",
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

-- The call speech and name windows (windows[0,1] on SUB_2) print with
-- background palette bank 1 of the upper SUB palette member selected by
-- phoneUpper(skin) (member 4+skin, loaded to SUB_BG by
-- PokegearPhone_LoadPalettes): fill 0 behind both windows, text in
-- colors (1,2,0) (PokegearPhone_AddWindows and
-- PokegearPhone_SetTouchscreenDimState in pokegear_phone_gfx.c). This
-- bank number is NCLR-local to the upper member, never to the
-- foreground member below.
PokegearSources.phoneWindowPaletteBank = 1

-- The context-menu tooltip window (windows[3]) prints with background
-- palette bank 10 of the same phone foreground palette: fill 5 behind
-- the prompt in text colors 3/2/5 (PrintContextMenuTooltip). The palette
-- member loads fourteen banks, so bank 10 rides the same member as the
-- list palette.
PokegearSources.phoneTooltipPaletteBank = 10

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
-- both on the sub palette 14+s. The world screen stores row-major: retail
-- never uploads it as a VRAM hardware image but reads it piece-wise
-- through CopyToBgTilemapRect with stride width/8 behind
-- PokegearMap_DrawMapTilemap, so its selection carries layout "linear"
-- to skip the hardware-block deswizzle.
function PokegearSources.mapForeground(skin)
  return { char = 26 + skin, screen = 32 + skin, palette = 20 + skin }
end

function PokegearSources.mapWorld(skin)
  return { char = 10, screen = 11, palette = 20 + skin, layout = "linear" }
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

-- The setup card reads its CHANGE/QUIT context labels from this bank.
PokegearSources.configureMessageBank = 270

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
-- the chrome and world, sub palette 62 for the upper screen. Its world
-- shares the map screen member and its row-major layout.
PokegearSources.fly = {
  world = { char = 10, screen = 11, palette = 63, layout = "linear" },
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

-- Card-app OBJ sprite sets of the setup archive a/1/4/5 and the phone
-- archive a/1/4/6, every set drawn with its card palette member 0. The
-- sprite resource descriptors of archive a/1/7/5 bind these members:
-- setup descriptors 40-43 point at setup archive members 3/2/1/0 and
-- phone descriptors 44-47 at phone archive members 3/2/1/0. Per-sequence
-- palette banks are untranscribed for the setup card, so every setup
-- sequence draws with bank 0 following the unlisted-sequence convention
-- below. The phone card transcribes the sSpriteTemplates palette slots
-- from pokegear_phone_gfx.c. The templates name hardware OBJ palette
-- slots, while the source uploads NCLR member 0 at hardware color entry
-- 0x40 (slot 4, four banks per sixteen colors), so each template slot
-- maps to an NCLR-local bank by subtracting the upload base: hardware 6
-- becomes local 2 and hardware 7 becomes local 3. `banks` therefore
-- carries NCLR-local banks, never hardware slots: compiled sequences
-- 1-2 (animations 0-1, scroll arrows) ride local 3, sequences 3-6
-- (animations 2-5, corners and move chevron) ride local 2, and
-- sequence 7 (animation 6, plain move chevron) rides local 3.
-- Animation 7 (sequence 8) has no template behind it and keeps bank 0.
-- Animation 8 (sequence 9, the fast-forward sprite) runs in paletteMode
-- 1, which keeps the NCER cell palette attribution instead of forcing
-- an override: it names no bank here and `paletteMode1` marks it so
-- the compiler passes no override for it.
PokegearSources.configureSpritePalette = 0
PokegearSources.phoneSpritePalette = 0

PokegearSources.configureSprites = {
  configure = { char = 1, cell = 2, anim = 3, banks = {} },
}

PokegearSources.phoneSprites = {
  phone = {
    char = 1,
    cell = 2,
    anim = 3,
    banks = { [1] = 3, [2] = 3, [3] = 2, [4] = 2, [5] = 2, [6] = 2, [7] = 3 },
    paletteMode1 = { [9] = true },
  },
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
-- frozen map-header reference (romdump/src/catalog/hgss/maps.lua); a
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
    key = "hg.place.cherrygrove",
    fieldMap = "MAP_CHERRYGROVE",
    mapRef = 67,
    matrix = { x = 564, y = 392 },
    location = "hg.location.cherrygrove-city",
    section = "hg.section.cherrygrove-city",
    region = "johto",
    flypoint = "hg.flypoint.cherrygrove",
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
  { key = "hg.flypoint.cherrygrove" },
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
-- name their PHONE_CONTACT_* family (trailing names); every other
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
-- sPhoneMessageGmm table behind GetPhoneMessageGmm,
-- mapping each phonebook contact to the message bank holding that
-- caller's script messages. Position i + 1 carries contact i's bank.
-- The per-contact greeting number beside it in the catalog record is the
-- source phone-script selector (PhoneBookEntry.phoneScriptIfLocal), not a
-- bank entry: the script table (gPhoneCallScriptDef, 455 scripts) maps
-- each selector onto its bank message pair, so a greeting number only
-- resolves as a direct bank entry where the script table maps it onto
-- itself. Every bank falls in msg_0641..msg_0716; msg_0668 has no caller
-- and is absent. Trailing names are the PHONE_CONTACT_*
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

-- The full thirteen-slot retail trigger table behind
-- GearPhoneRingManager (sPhoneCallTriggers order): caller, incoming
-- script identity, and the force-pickup flag per slot. Caller contacts
-- ride the corpus phonebook triples. GearPhoneRingManager always
-- launches a picked trigger with isScriptedCall 3, and the source
-- launch (FieldSystem_InitPokegearArgs) reads that marker: a 3 clears
-- the launched trigger's flag, and only a 0 records a recent caller. A
-- trigger therefore never records one, and every trigger -- Mom gift
-- and the forced calls alike -- clears at its own launch. Scripts still
-- own their flag setters (the Pokecenter heal, Day-Care, and Mom-gift
-- scripts set and clear their slots); an early script clear only makes
-- the launch clear a flag that is already down.
PokegearSources.phoneTriggers = {
  { slot = 0, key = "gear.trigger.0", contact = "hg.trainer.201.map.0.contact.1", callScriptID = 13 },
  { slot = 1, key = "gear.trigger.1", contact = "hg.trainer.201.map.0.contact.1", callScriptID = 7 },
  {
    slot = 2,
    key = "gear.trigger.2",
    contact = "hg.trainer.205.map.0.contact.15",
    forcePickUp = true,
    callScriptID = 85,
  },
  {
    slot = 3,
    key = "gear.trigger.3",
    contact = "hg.trainer.206.map.0.contact.9",
    forcePickUp = true,
    callScriptID = 93,
  },
  { slot = 4, key = "gear.trigger.4", contact = "hg.trainer.201.map.0.contact.2" },
  { slot = 5, key = "gear.trigger.5", contact = "hg.trainer.204.map.0.contact.6" },
  { slot = 6, key = "gear.trigger.6", contact = "hg.trainer.207.map.0.contact.24" },
  {
    slot = 7,
    key = "gear.trigger.7",
    contact = "hg.trainer.207.map.0.contact.24",
    forcePickUp = true,
    callScriptID = 142,
  },
  {
    slot = 8,
    key = "gear.trigger.8",
    contact = "hg.trainer.207.map.0.contact.24",
    forcePickUp = true,
    callScriptID = 143,
  },
  {
    slot = 9,
    key = "gear.trigger.9",
    contact = "hg.trainer.207.map.0.contact.24",
    forcePickUp = true,
    callScriptID = 144,
  },
  {
    slot = 10,
    key = "gear.trigger.10",
    contact = "hg.trainer.207.map.0.contact.24",
    forcePickUp = true,
    callScriptID = 145,
  },
  {
    slot = 11,
    key = "gear.trigger.11",
    contact = "hg.trainer.207.map.0.contact.24",
    forcePickUp = true,
    callScriptID = 146,
  },
  {
    slot = 12,
    key = "gear.trigger.12",
    contact = "hg.trainer.200.map.0.contact.0",
    callScriptID = 27,
  },
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
-- producer error, never an empty trigger set. The records carry only
-- what the source table holds: the caller, its script identity, and the
-- pickup flag; the launch marker is the source constant 3 for every
-- trigger. Returns detached copies; mutating them never touches the
-- producer table.
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
    assert(
      entry.callScriptID == nil or (type(entry.callScriptID) == "number" and entry.callScriptID % 1 == 0),
      "phone triggers carry their source script identity"
    )
    records[#records + 1] = {
      slot = entry.slot,
      key = entry.key,
      contact = entry.contact,
      forcePickUp = entry.forcePickUp == true,
      callScriptID = entry.callScriptID,
    }
  end
  assert(#records > 0, "phone trigger records cover the observed trigger set for " .. versionId)
  return records
end

-- Retail generic-call header tables per phonebook contact, transcribed from
-- the source sGenericPhoneCallHeaders const data (eight outgoing rows then
-- eight incoming rows per contact; only contacts with at least one gated
-- row are listed). Each row names the gate type, its percent chance, the
-- conversation script type, and the phone-script id. Gate types follow the
-- native GenericPhoneCallType order (0 nil, 1 random, 2 rematch-until-tower,
-- 3 rematch window, 4 contest days, 5 takeover, 6 random, 7 rematch outside
-- contest, 8 gift outside contest, 255 terminator).
PokegearSources.phoneGenericHeaders = {
  [10] = { -- PHONE_CONTACT_JOEY
    outgoing = {
      { 7, 100, 0, 34 },
      { 3, 100, 0, 33 },
      { 1, 100, 1, 35 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
    },
    incoming = {
      { 2, 60, 0, 33 },
      { 1, 40, 1, 30 },
      { 1, 40, 1, 31 },
      { 1, 100, 1, 32 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
    },
  },
  [11] = { -- PHONE_CONTACT_RALPH
    outgoing = {
      { 7, 100, 0, 51 },
      { 3, 100, 0, 50 },
      { 1, 100, 0, 52 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
    },
    incoming = {
      { 2, 50, 0, 50 },
      { 1, 40, 1, 47 },
      { 1, 40, 1, 48 },
      { 1, 100, 1, 49 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
    },
  },
  [12] = { -- PHONE_CONTACT_LIZ
    outgoing = {
      { 7, 100, 0, 58 },
      { 3, 100, 0, 57 },
      { 1, 30, 1, 60 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
    },
    incoming = {
      { 1, 25, 0, 56 },
      { 2, 25, 0, 57 },
      { 1, 100, 2, 59 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
    },
  },
  [13] = { -- PHONE_CONTACT_WADE
    outgoing = {
      { 7, 100, 0, 41 },
      { 8, 100, 0, 44 },
      { 3, 100, 0, 40 },
      { 4, 100, 0, 45 },
      { 1, 100, 0, 42 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
    },
    incoming = {
      { 8, 100, 0, 44 },
      { 7, 100, 0, 41 },
      { 2, 50, 0, 43 },
      { 2, 50, 0, 40 },
      { 1, 40, 1, 38 },
      { 1, 40, 1, 39 },
      { 1, 100, 1, 37 },
      { 255, 0, 0, 0 },
    },
  },
  [14] = { -- PHONE_CONTACT_ANTHONY
    outgoing = {
      { 7, 100, 0, 66 },
      { 3, 100, 0, 65 },
      { 1, 100, 0, 67 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
    },
    incoming = {
      { 2, 50, 0, 65 },
      { 1, 40, 1, 62 },
      { 1, 40, 1, 63 },
      { 1, 100, 1, 64 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
    },
  },
  [19] = { -- PHONE_CONTACT_JACK
    outgoing = {
      { 7, 100, 0, 110 },
      { 3, 100, 0, 109 },
      { 1, 100, 0, 111 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
    },
    incoming = {
      { 2, 25, 0, 109 },
      { 1, 100, 2, 108 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
    },
  },
  [20] = { -- PHONE_CONTACT_CHAD
    outgoing = {
      { 7, 100, 0, 118 },
      { 3, 100, 0, 116 },
      { 1, 100, 0, 119 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
    },
    incoming = {
      { 2, 25, 0, 116 },
      { 1, 100, 2, 117 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
    },
  },
  [21] = { -- PHONE_CONTACT_BRENT
    outgoing = {
      { 7, 100, 0, 126 },
      { 3, 100, 0, 125 },
      { 1, 100, 0, 127 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
    },
    incoming = {
      { 2, 25, 0, 125 },
      { 1, 100, 2, 124 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
    },
  },
  [22] = { -- PHONE_CONTACT_TODD
    outgoing = {
      { 7, 100, 0, 132 },
      { 3, 100, 0, 131 },
      { 1, 100, 0, 133 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
    },
    incoming = {
      { 2, 50, 0, 131 },
      { 1, 50, 1, 129 },
      { 1, 100, 1, 130 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
    },
  },
  [23] = { -- PHONE_CONTACT_ARNIE
    outgoing = {
      { 7, 100, 0, 138 },
      { 3, 100, 0, 137 },
      { 1, 100, 0, 139 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
    },
    incoming = {
      { 2, 50, 0, 137 },
      { 1, 50, 1, 135 },
      { 1, 100, 1, 136 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
    },
  },
  [40] = { -- PHONE_CONTACT_HUEY
    outgoing = {
      { 7, 100, 0, 194 },
      { 3, 100, 0, 193 },
      { 1, 100, 0, 195 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
    },
    incoming = {
      { 2, 60, 0, 193 },
      { 1, 50, 1, 191 },
      { 1, 100, 1, 192 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
    },
  },
  [41] = { -- PHONE_CONTACT_GAVEN
    outgoing = {
      { 7, 100, 0, 201 },
      { 3, 100, 0, 200 },
      { 1, 100, 0, 202 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
    },
    incoming = {
      { 2, 50, 0, 200 },
      { 1, 40, 1, 197 },
      { 1, 40, 1, 198 },
      { 1, 100, 1, 199 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
    },
  },
  [42] = { -- PHONE_CONTACT_JAMIE
    outgoing = {
      { 7, 100, 0, 208 },
      { 3, 100, 0, 207 },
      { 1, 100, 0, 209 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
    },
    incoming = {
      { 2, 50, 0, 207 },
      { 1, 40, 1, 204 },
      { 1, 40, 1, 205 },
      { 1, 100, 1, 206 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
    },
  },
  [43] = { -- PHONE_CONTACT_REENA
    outgoing = {
      { 7, 100, 0, 215 },
      { 3, 100, 0, 214 },
      { 1, 100, 0, 216 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
    },
    incoming = {
      { 2, 50, 0, 214 },
      { 1, 30, 1, 211 },
      { 1, 30, 1, 212 },
      { 1, 100, 1, 213 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
    },
  },
  [44] = { -- PHONE_CONTACT_VANCE
    outgoing = {
      { 7, 100, 0, 221 },
      { 3, 100, 0, 220 },
      { 1, 100, 0, 222 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
    },
    incoming = {
      { 2, 60, 0, 220 },
      { 1, 50, 1, 218 },
      { 1, 100, 1, 219 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
    },
  },
  [45] = { -- PHONE_CONTACT_PARRY
    outgoing = {
      { 7, 100, 0, 227 },
      { 3, 50, 0, 226 },
      { 1, 100, 0, 228 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
    },
    incoming = {
      { 2, 60, 0, 226 },
      { 1, 50, 1, 224 },
      { 1, 100, 1, 225 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
    },
  },
  [46] = { -- PHONE_CONTACT_ERIN
    outgoing = {
      { 7, 100, 0, 234 },
      { 3, 50, 0, 233 },
      { 1, 100, 0, 235 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
    },
    incoming = {
      { 2, 60, 0, 233 },
      { 1, 40, 1, 231 },
      { 1, 40, 1, 232 },
      { 1, 100, 1, 230 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
    },
  },
  [47] = { -- PHONE_CONTACT_BEVERLY
    outgoing = {
      { 8, 100, 0, 241 },
      { 1, 100, 0, 239 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
    },
    incoming = {
      { 2, 25, 0, 240 },
      { 1, 50, 1, 237 },
      { 1, 100, 1, 238 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
    },
  },
  [48] = { -- PHONE_CONTACT_JOSE
    outgoing = {
      { 7, 100, 0, 247 },
      { 8, 100, 0, 250 },
      { 3, 100, 0, 246 },
      { 1, 100, 0, 248 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
    },
    incoming = {
      { 7, 100, 0, 247 },
      { 8, 100, 0, 250 },
      { 2, 30, 0, 249 },
      { 2, 30, 0, 246 },
      { 1, 30, 1, 244 },
      { 1, 30, 1, 245 },
      { 1, 100, 1, 243 },
      { 255, 0, 0, 0 },
    },
  },
  [49] = { -- PHONE_CONTACT_GINA
    outgoing = {
      { 5, 100, 0, 259 },
      { 7, 100, 0, 255 },
      { 8, 100, 0, 258 },
      { 3, 100, 0, 254 },
      { 1, 100, 0, 256 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
    },
    incoming = {
      { 5, 100, 0, 259 },
      { 7, 100, 0, 255 },
      { 8, 100, 0, 258 },
      { 2, 30, 0, 254 },
      { 2, 10, 0, 257 },
      { 1, 50, 1, 252 },
      { 1, 100, 1, 253 },
      { 255, 0, 0, 0 },
    },
  },
  [50] = { -- PHONE_CONTACT_ALAN
    outgoing = {
      { 7, 100, 0, 264 },
      { 8, 100, 0, 267 },
      { 3, 100, 0, 263 },
      { 1, 100, 0, 265 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
    },
    incoming = {
      { 2, 10, 0, 266 },
      { 2, 30, 0, 263 },
      { 1, 50, 1, 262 },
      { 1, 100, 1, 261 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
    },
  },
  [51] = { -- PHONE_CONTACT_DANA
    outgoing = {
      { 7, 100, 0, 272 },
      { 8, 100, 0, 275 },
      { 3, 100, 0, 271 },
      { 1, 100, 0, 273 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
    },
    incoming = {
      { 2, 10, 0, 274 },
      { 2, 30, 0, 271 },
      { 7, 100, 0, 272 },
      { 8, 100, 0, 275 },
      { 1, 50, 1, 269 },
      { 1, 100, 1, 270 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
    },
  },
  [52] = { -- PHONE_CONTACT_DEREK
    outgoing = {
      { 8, 100, 0, 281 },
      { 4, 100, 0, 282 },
      { 1, 100, 0, 279 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
    },
    incoming = {
      { 2, 25, 0, 280 },
      { 4, 100, 0, 282 },
      { 1, 50, 1, 277 },
      { 1, 100, 1, 278 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
    },
  },
  [53] = { -- PHONE_CONTACT_TULLY
    outgoing = {
      { 7, 100, 0, 287 },
      { 8, 100, 0, 290 },
      { 3, 100, 0, 286 },
      { 1, 100, 0, 288 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
    },
    incoming = {
      { 2, 30, 0, 286 },
      { 2, 10, 0, 289 },
      { 1, 50, 1, 284 },
      { 1, 100, 1, 285 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
    },
  },
  [54] = { -- PHONE_CONTACT_TIFFANY
    outgoing = {
      { 8, 100, 0, 299 },
      { 7, 100, 0, 295 },
      { 3, 100, 0, 294 },
      { 1, 100, 0, 297 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
    },
    incoming = {
      { 1, 25, 0, 296 },
      { 2, 30, 0, 294 },
      { 2, 10, 0, 298 },
      { 1, 50, 1, 292 },
      { 1, 100, 1, 293 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
    },
  },
  [55] = { -- PHONE_CONTACT_WILTON
    outgoing = {
      { 7, 100, 0, 304 },
      { 8, 100, 0, 307 },
      { 3, 100, 0, 303 },
      { 1, 100, 0, 305 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
    },
    incoming = {
      { 2, 50, 0, 303 },
      { 2, 50, 0, 306 },
      { 1, 50, 1, 301 },
      { 1, 100, 1, 302 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
    },
  },
  [56] = { -- PHONE_CONTACT_KRISE
    outgoing = {
      { 7, 100, 0, 313 },
      { 3, 100, 0, 312 },
      { 1, 100, 0, 314 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
    },
    incoming = {
      { 2, 30, 0, 312 },
      { 1, 30, 1, 309 },
      { 1, 30, 1, 310 },
      { 1, 100, 1, 311 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
    },
  },
  [57] = { -- PHONE_CONTACT_IAN
    outgoing = {
      { 7, 100, 0, 320 },
      { 3, 100, 0, 319 },
      { 1, 100, 0, 321 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
    },
    incoming = {
      { 2, 30, 0, 319 },
      { 1, 30, 1, 316 },
      { 1, 30, 1, 317 },
      { 1, 100, 1, 318 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
    },
  },
  [58] = { -- PHONE_CONTACT_WALT
    outgoing = {
      { 7, 100, 0, 327 },
      { 3, 100, 0, 326 },
      { 4, 100, 0, 329 },
      { 1, 100, 0, 328 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
    },
    incoming = {
      { 4, 50, 0, 329 },
      { 2, 30, 0, 326 },
      { 1, 30, 1, 323 },
      { 1, 30, 1, 324 },
      { 1, 100, 1, 325 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
    },
  },
  [59] = { -- PHONE_CONTACT_ALFRED
    outgoing = {
      { 7, 100, 0, 335 },
      { 3, 100, 0, 334 },
      { 1, 100, 0, 336 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
    },
    incoming = {
      { 2, 30, 0, 334 },
      { 1, 30, 1, 331 },
      { 1, 30, 1, 332 },
      { 1, 100, 1, 333 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
    },
  },
  [60] = { -- PHONE_CONTACT_DOUG
    outgoing = {
      { 7, 100, 0, 342 },
      { 8, 100, 0, 345 },
      { 3, 100, 0, 341 },
      { 1, 100, 0, 343 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
    },
    incoming = {
      { 2, 30, 0, 341 },
      { 2, 50, 0, 344 },
      { 1, 30, 1, 338 },
      { 1, 30, 1, 339 },
      { 1, 100, 1, 340 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
    },
  },
  [61] = { -- PHONE_CONTACT_ROB
    outgoing = {
      { 7, 100, 0, 351 },
      { 8, 100, 0, 354 },
      { 3, 100, 0, 350 },
      { 1, 100, 0, 352 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
    },
    incoming = {
      { 2, 30, 0, 350 },
      { 2, 50, 0, 353 },
      { 1, 30, 1, 347 },
      { 1, 30, 1, 348 },
      { 1, 100, 1, 349 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
    },
  },
  [62] = { -- PHONE_CONTACT_KYLE
    outgoing = {
      { 7, 100, 0, 360 },
      { 3, 100, 0, 359 },
      { 1, 100, 0, 361 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
    },
    incoming = {
      { 2, 30, 0, 359 },
      { 1, 30, 1, 356 },
      { 1, 30, 1, 357 },
      { 1, 100, 1, 358 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
    },
  },
  [63] = { -- PHONE_CONTACT_KYLER
    outgoing = {
      { 7, 100, 0, 367 },
      { 3, 100, 0, 366 },
      { 1, 100, 0, 368 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
    },
    incoming = {
      { 2, 30, 0, 366 },
      { 1, 30, 1, 363 },
      { 1, 30, 1, 364 },
      { 1, 100, 1, 365 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
    },
  },
  [64] = { -- PHONE_CONTACT_TIM_AND_SUE
    outgoing = {
      { 7, 100, 0, 374 },
      { 3, 100, 0, 373 },
      { 1, 100, 0, 375 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
    },
    incoming = {
      { 2, 30, 0, 373 },
      { 1, 30, 1, 370 },
      { 1, 30, 1, 371 },
      { 1, 100, 1, 372 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
    },
  },
  [65] = { -- PHONE_CONTACT_KENNY
    outgoing = {
      { 7, 100, 0, 381 },
      { 3, 100, 0, 380 },
      { 1, 100, 0, 382 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
    },
    incoming = {
      { 2, 30, 0, 380 },
      { 1, 30, 1, 377 },
      { 1, 30, 1, 378 },
      { 1, 100, 1, 379 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
    },
  },
  [66] = { -- PHONE_CONTACT_TANNER
    outgoing = {
      { 8, 100, 0, 391 },
      { 7, 100, 0, 388 },
      { 3, 100, 0, 387 },
      { 1, 100, 0, 389 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
    },
    incoming = {
      { 2, 30, 0, 387 },
      { 2, 10, 0, 390 },
      { 1, 30, 1, 384 },
      { 1, 30, 1, 385 },
      { 1, 100, 1, 386 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
    },
  },
  [67] = { -- PHONE_CONTACT_JOSH
    outgoing = {
      { 8, 100, 0, 400 },
      { 7, 100, 0, 397 },
      { 3, 100, 0, 396 },
      { 1, 100, 0, 398 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
    },
    incoming = {
      { 2, 30, 0, 396 },
      { 2, 10, 0, 399 },
      { 1, 30, 1, 393 },
      { 1, 30, 1, 394 },
      { 1, 100, 1, 395 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
    },
  },
  [68] = { -- PHONE_CONTACT_TORIN
    outgoing = {
      { 7, 100, 0, 406 },
      { 3, 100, 0, 405 },
      { 1, 100, 0, 407 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
    },
    incoming = {
      { 2, 30, 0, 405 },
      { 1, 30, 1, 402 },
      { 1, 30, 1, 403 },
      { 1, 100, 1, 404 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
    },
  },
  [69] = { -- PHONE_CONTACT_HILLARY
    outgoing = {
      { 7, 100, 0, 414 },
      { 3, 100, 0, 413 },
      { 1, 100, 0, 415 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
    },
    incoming = {
      { 1, 25, 0, 409 },
      { 2, 30, 0, 413 },
      { 1, 20, 1, 410 },
      { 1, 30, 1, 411 },
      { 1, 100, 1, 412 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
    },
  },
  [70] = { -- PHONE_CONTACT_BILLY
    outgoing = {
      { 7, 100, 0, 419 },
      { 3, 100, 0, 418 },
      { 1, 20, 0, 420 },
      { 1, 100, 2, 417 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
    },
    incoming = {
      { 2, 30, 0, 418 },
      { 1, 100, 2, 417 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
    },
  },
  [71] = { -- PHONE_CONTACT_KAY_AND_TIA
    outgoing = {
      { 7, 100, 0, 426 },
      { 8, 100, 0, 429 },
      { 3, 100, 0, 425 },
      { 1, 100, 0, 427 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
    },
    incoming = {
      { 2, 10, 0, 428 },
      { 2, 30, 0, 425 },
      { 1, 30, 1, 422 },
      { 1, 30, 1, 423 },
      { 1, 100, 1, 424 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
    },
  },
  [72] = { -- PHONE_CONTACT_REESE
    outgoing = {
      { 8, 100, 0, 438 },
      { 7, 100, 0, 435 },
      { 3, 100, 0, 434 },
      { 1, 100, 0, 436 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
    },
    incoming = {
      { 2, 30, 0, 434 },
      { 2, 10, 0, 437 },
      { 1, 30, 1, 431 },
      { 1, 30, 1, 432 },
      { 1, 100, 1, 433 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
    },
  },
  [73] = { -- PHONE_CONTACT_AIDEN
    outgoing = {
      { 8, 100, 0, 447 },
      { 7, 100, 0, 444 },
      { 3, 100, 0, 443 },
      { 1, 100, 0, 445 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
    },
    incoming = {
      { 2, 30, 0, 443 },
      { 2, 10, 0, 446 },
      { 1, 30, 1, 440 },
      { 1, 30, 1, 441 },
      { 1, 100, 1, 442 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
    },
  },
  [74] = { -- PHONE_CONTACT_ERNEST
    outgoing = {
      { 7, 100, 0, 454 },
      { 3, 100, 0, 453 },
      { 1, 100, 0, 455 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
    },
    incoming = {
      { 2, 30, 0, 453 },
      { 1, 15, 0, 449 },
      { 1, 30, 1, 450 },
      { 1, 30, 1, 451 },
      { 1, 100, 1, 452 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
      { 255, 0, 0, 0 },
    },
  },
}

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
