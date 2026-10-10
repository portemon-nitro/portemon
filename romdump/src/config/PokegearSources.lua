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

return PokegearSources
