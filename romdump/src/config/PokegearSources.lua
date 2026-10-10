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

return PokegearSources
