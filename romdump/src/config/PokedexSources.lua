-- Producer-only source selectors for the HGSS Pokedex family: archive
-- paths, bounded member layouts, measurement/profile mapping, search and
-- area mask semantics, form policies, completion exclusions, height
-- correction selectors, and fixed text roles. Native identities stop here;
-- runtime game code never requires this module.

local PokedexSources = {}

PokedexSources.provenance = {
  decompRevision = "ctrl-cheeb-del/pokeheartgold@98ebf77a3f4cebd6de953824550d962c971301b7",
  symbols = {
    "filesystem.mk",
    "include/constants/filesystem_files_def.h",
    "src/application/pokedex/pokedex_screen_setup.c",
    "src/application/pokedex/pokedex_main_seq.c",
    "src/application/pokedex/pokedex_sprites.c",
    "src/application/pokedex/pokedex_area_sprites.c",
    "src/application/pokedex/pokedex_size_check.c",
    "src/application/pokedex/pokedex_forms.c",
    "src/application/pokedex/pokedex_entry_popup.c",
    "src/application/pokedex/pokedex_windows.c",
    "asm/pokedex_rodata.s",
    "src/dex_mon_measures.c",
    "src/application/pokedex/pokedex_text_util.c",
    "src/pokemon.c",
    "src/application/pokedex/pokedex_app.c",
  },
}

PokedexSources.versions = { heartgold = true, soulsilver = true }

-- Native background layer priorities transcribed from the retail BG
-- templates (`.priority` per MAIN/SUB layer): MAIN layers render
-- 2/0/1/3, SUB layers 0/1/2/3. MAIN feeds the lower/touch `controls`
-- pane, SUB the upper `information` pane. This shared default matches the
-- list-browse assignment; screens with their own Set*BgPriorities call
-- carry an explicit override in `pagePriorities` below.
PokedexSources.bgPriority = {
  controls = { [0] = 2, [1] = 0, [2] = 1, [3] = 3 },
  information = { [0] = 0, [1] = 1, [2] = 2, [3] = 3 },
}

-- Per-screen native priority overrides. SetupScreen installs one
-- Set*BgPriorities assignment per screen alongside its graphics loader;
-- the area screen (case 1) uses SetAreaBgPriorities, which keeps the SUB
-- BG0 area map behind the SUB BG1 entry windows (BG0 pri 3 back vs BG1
-- pri 0 front). The SUB BG0 scroll plane is 512 wide and area setup pans
-- it to the settled region offsets (-72 Johto, +104 Kanto), so the bound
-- layer-0 composition stays the full pannable map shifted by the published
-- pan offset, never an X=0-state foreground over the windows.
PokedexSources.pagePriorities = {
  ["entry.area"] = {
    controls = { [0] = 1, [1] = 0, [2] = 2, [3] = 3 },
    information = { [0] = 3, [1] = 0, [2] = 1, [3] = 2 },
  },
}

-- Producer-only page/layer source map. Each entry names a native engine
-- pane, a native BG layer, and the exact NCGR/NSCR/NCLR member triple the
-- retail loader for that page binds (MAIN layers use NCLR member 2, SUB
-- layers NCLR member 18; member ids stop here and never reach the
-- runtime). An entry without `screen` is a char-only layer: cleared
-- hardware tilemaps show tile 0 of the loaded character data, so the
-- compiler stages an exact tile-0 fill rather than inventing art. Layers
-- with neither character nor screen data carry no entry.
--
-- Load-call anchors (public pret/pokeheartgold overlay snapshot): list
-- family 021E6868 (MAIN_0 char 1 + raw screen 0 scroll map, MAIN_2 char 4,
-- MAIN_3 char 3, SUB_0 char 17 + screen 16, SUB_3 char 19 + screen 20/21);
-- search loader 021E7048 with editor swaps 021E71D0 cases 0..7 (screens
-- 57,62,63,64,65,66,67,68 on MAIN_2 over char 58; SUB_3 screen 59 and
-- SUB_2 screen 60 over char 58); area loader 021E7BD0 (MAIN_0 char 83 +
-- screen 80, or 81 in national mode; MAIN_3 char 83 + screen 82;
-- SUB_3 char 85 + screen 84; SUB_0 char 87 + screen 86); size loader
-- 021E7D90 (MAIN_3 char 90 + screen 89; SUB_2 char 92 + screen 91); forms
-- loader 021E800C (MAIN_0/3 char 93 + screens 95/96; SUB_3 char 94 +
-- screen 97); compare loader 021E81A8 (MAIN_3 char 93 + screen 98;
-- SUB_3 char 94 + screen 99); back loader 021E7ED8 (MAIN_3 char 102 +
-- screen 101; SUB_2 char 104 + screen 103). The registration popup
-- triple (NCGR 19 + NSCR 20, NCLR 18, battle Main engine) follows the
-- pinned native source; the popup init is not in the reachable
-- public snapshot.
--
-- `screenJapanese` selects the foreign-language list variant (NSCR 21)
-- when the dump is not English; `screenNational` stages the
-- national-mode area variant (NSCR 81) as a separately selectable image
-- while the default johto variant (NSCR 80) stays referenced.
local listLayers = {
  { pane = "controls", layer = 0, char = 1, screen = 0, palette = 2 },
  { pane = "controls", layer = 2, char = 4, palette = 2 },
  { pane = "controls", layer = 3, char = 3, palette = 2 },
  { pane = "information", layer = 0, char = 17, screen = 16, palette = 18 },
  { pane = "information", layer = 3, char = 19, screen = 20, screenJapanese = 21, palette = 18 },
}

-- Grid depicts the scrolled entry-view state, not the list-browse state the
-- loader leaves behind. SUB BG0 is a 512-wide map carrying art on its left
-- half only; the list/entry sequences scroll MAIN BG0 and SUB BG0 together
-- to X=256 on entry (open/resume and list-to-entry slides) and back to X=0
-- on return to the list. At X=256 SUB BG0 shows its cleared half (clear
-- fill tile 0 of the loaded character data is fully blank), so the SUB BG1
-- header windows stay visible; at X=0 the dial art covers them at priority
-- 0. The grid information pane therefore binds no layer-0 composition while
-- the windowless cover keeps the loaded art.
local gridLayers = {
  { pane = "controls", layer = 0, char = 1, screen = 0, palette = 2 },
  { pane = "controls", layer = 2, char = 4, palette = 2 },
  { pane = "controls", layer = 3, char = 3, palette = 2 },
  { pane = "information", layer = 3, char = 19, screen = 20, screenJapanese = 21, palette = 18 },
}

local searchBaseLayers = {
  { pane = "controls", layer = 1, char = 4, palette = 2 },
  { pane = "controls", layer = 3, char = 3, palette = 2 },
  { pane = "information", layer = 2, char = 58, screen = 60, palette = 18 },
  { pane = "information", layer = 3, char = 58, screen = 59, palette = 18 },
}

---@param screenMember integer
---@return { pane: string, layer: integer, char: integer, screen: integer|nil, screenJapanese: integer|nil, screenNational: integer|nil, palette: integer }[]
local function searchLayers(screenMember)
  local layers = {
    { pane = "controls", layer = 2, char = 58, screen = screenMember, palette = 2 },
  }
  for _, entry in ipairs(searchBaseLayers) do
    layers[#layers + 1] = entry
  end
  return layers
end

PokedexSources.pageLayers = {
  cover = listLayers,
  grid = gridLayers,
  results = listLayers,
  ["search.criteria"] = searchLayers(57),
  ["search.order"] = searchLayers(62),
  ["search.name"] = searchLayers(63),
  ["search.type"] = searchLayers(64),
  ["search.height"] = searchLayers(65),
  ["search.weight"] = searchLayers(66),
  ["search.area"] = searchLayers(67),
  ["search.shape"] = searchLayers(68),
  ["entry.area"] = {
    { pane = "controls", layer = 0, char = 83, screen = 80, screenNational = 81, palette = 2 },
    { pane = "controls", layer = 1, char = 4, palette = 2 },
    { pane = "controls", layer = 3, char = 83, screen = 82, palette = 2 },
    { pane = "information", layer = 0, char = 87, screen = 86, palette = 18 },
    { pane = "information", layer = 3, char = 85, screen = 84, palette = 18 },
  },
  ["entry.size"] = {
    { pane = "controls", layer = 1, char = 4, palette = 2 },
    { pane = "controls", layer = 3, char = 90, screen = 89, palette = 2 },
    { pane = "information", layer = 2, char = 92, screen = 91, palette = 18 },
  },
  ["entry.forms"] = {
    { pane = "controls", layer = 0, char = 93, screen = 95, palette = 2 },
    { pane = "controls", layer = 1, char = 4, palette = 2 },
    { pane = "controls", layer = 3, char = 93, screen = 96, palette = 2 },
    { pane = "information", layer = 3, char = 94, screen = 97, palette = 18 },
  },
  ["entry.compare"] = {
    { pane = "controls", layer = 3, char = 93, screen = 98, palette = 2 },
    { pane = "information", layer = 3, char = 94, screen = 99, palette = 18 },
  },
  ["entry.return"] = {
    { pane = "controls", layer = 1, char = 4, palette = 2 },
    { pane = "controls", layer = 3, char = 102, screen = 101, palette = 2 },
    { pane = "information", layer = 2, char = 104, screen = 103, palette = 18 },
  },
  registration = {
    { pane = "information", layer = 2, char = 19, screen = 20, palette = 18 },
  },
}

-- Producer-only page OBJ bindings as explicit NCER/NANR member pairs,
-- one pair per sprite family the page's native screen setup loads. Icon
-- and mon-picture sprites resolve their cells outside this archive and
-- bind no pair here. Member ids stop here and never reach the runtime.
--
-- Load-call anchors: list SetupListSprites loads main objects 12-15,
-- sub objects 26-31, type icons 33-36, language icons 53-56 and the
-- footprint 77-79 (sPokedexListSpriteTemplates, sPokedexListSprite9/10Template,
-- sTypeIconSpriteTemplate, sLanguageIconSpriteTemplate,
-- sFootprintSpriteTemplate); search SetupSearchSprites loads main
-- objects, language icons, menu objects 72-75 on both engines and
-- body-type icons 23-25 (sPokedexSearchSpriteTemplates,
-- sPokedexSearchSprite26/27Template, sPokedexBodyTypeIconSpriteTemplate,
-- sPokedexSearchSprite43Template), with the result entry adding sub
-- objects, type icons, the footprint and sub language icons
-- (CreateSearchEntrySprites); area SetupAreaSprites loads main objects,
-- marker objects 115-118 and area markers 119-122
-- (sPokedexAreaSpriteTemplates, sAreaMarkerSpriteTemplate); size
-- SetupSizeCheckSprites loads main objects, scale objects 106/107 and
-- 112-114 (sPokedexSizeCheckSpriteTemplates); forms SetupFormsSprites
-- loads main objects only (sPokedexFormsSpriteTemplates; pictures and
-- list icons resolve outside this archive); the entry menu creates only
-- the tab cursor from main objects (CreateEntryTabCursor); the popup
-- loads the banner 29-32, type icons 33-36 and the footprint 77-79
-- (PokedexEntryPopup_InitSprites). Cover binds no family: it has no
-- native sprite setup.
local listObjs = {
  { cells = 13, anims = 14 },
  { cells = 27, anims = 28 },
  { cells = 30, anims = 31 },
  { cells = 33, anims = 34 },
  { cells = 54, anims = 55 },
  { cells = 78, anims = 79 },
}
local searchObjs = {
  { cells = 13, anims = 14 },
  { cells = 24, anims = 25 },
  { cells = 54, anims = 55 },
  { cells = 73, anims = 74 },
}
local mainObjs = { { cells = 13, anims = 14 } }

PokedexSources.pageObjs = {
  cover = {},
  grid = listObjs,
  results = {
    { cells = 13, anims = 14 },
    { cells = 24, anims = 25 },
    { cells = 27, anims = 28 },
    { cells = 30, anims = 31 },
    { cells = 33, anims = 34 },
    { cells = 54, anims = 55 },
    { cells = 73, anims = 74 },
    { cells = 78, anims = 79 },
  },
  ["search.criteria"] = searchObjs,
  ["search.order"] = searchObjs,
  ["search.name"] = searchObjs,
  ["search.type"] = searchObjs,
  ["search.height"] = searchObjs,
  ["search.weight"] = searchObjs,
  ["search.area"] = searchObjs,
  ["search.shape"] = searchObjs,
  ["entry.area"] = {
    { cells = 13, anims = 14 },
    { cells = 116, anims = 117 },
    { cells = 120, anims = 121 },
  },
  ["entry.size"] = {
    { cells = 13, anims = 14 },
    { cells = 106, anims = 107 },
    { cells = 112, anims = 113 },
  },
  ["entry.forms"] = mainObjs,
  ["entry.compare"] = mainObjs,
  ["entry.return"] = mainObjs,
  registration = {
    { cells = 30, anims = 31 },
    { cells = 33, anims = 34 },
    { cells = 78, anims = 79 },
  },
}

-- Producer-only static OBJ anchors: per-page, per-animation-family,
-- per-sequence screen centers for sprites whose art, position, and page
-- visibility are all fixed. The shape choice grid shows choice art k at
-- grid slot k while the shape editor is open (CreateSearchSprites
-- body-type loop in pokedex_sprites.c: x = 32 + 48 * (choice % 5),
-- y = 56 + 40 * (choice / 5), MAIN engine via SpriteSystem_NewSprite;
-- the menu art family is cells 73/animations 74 through
-- sPokedexBodyTypeIconSpriteTemplate). The registration banner emblem
-- sits at (112, 32) on the popup card
-- (PokedexEntryPopup_CreateBannerSprite in pokedex_entry_popup.c, banner
-- cells 30/animations 31, staged on the information surface). Anchors
-- reuse the sprite record's own x/y/pane fields, so the manifest shape
-- is unchanged; the origin (0, 0) stays the unplaced sentinel and no
-- anchor may sit on it. Every other page sprite stays origin-anchored:
-- cursors, arrows, scrollbars, tab cursors, digits, type/footprint/
-- mon-picture art and language icons all vary art, position, or
-- visibility by live state (cursor slots, page arrows, scrollbar sync,
-- per-species icons, caught languages), so no static anchor can place
-- them without inventing content.
local shapeAnchors = {}
for slot = 0, 13 do
  shapeAnchors[slot + 1] = {
    x = 32 + 48 * (slot % 5),
    y = 56 + 40 * math.floor(slot / 5),
    pane = "controls",
  }
end

PokedexSources.spriteAnchors = {
  ["search.shape"] = {
    [74] = shapeAnchors,
  },
  registration = {
    [31] = {
      [1] = { x = 112, y = 32, pane = "information" },
    },
  },
}

-- Producer-only OBJ character palettes: the tile grids backing cell art
-- render through the palette member adjacent to each OBJ character run
-- (bank 0; multi-bank OBJ records have no manifest spelling and keep
-- the pre-existing bank-0 staging). Keys are character members.
PokedexSources.objPalettes = {
  [12] = 15,
  [23] = 18,
  [26] = 32,
  [29] = 32,
  [53] = 56,
  [72] = 75,
  [76] = 75,
  [77] = 75,
  [105] = 108,
  [109] = 108,
  [111] = 110,
  [114] = 110,
  [115] = 118,
  [119] = 118,
}

-- Native application/data source archives with their verified HG member
-- counts. Physical file IDs are evidence anchors, not runtime arithmetic.
PokedexSources.archives = {
  graphics = { path = "a/0/6/8", memberCount = 123 },
  footprints = { path = "a/0/6/9", memberCount = 497 },
  measuresOrigin = { path = "a/0/7/4", memberCount = 102 },
  measuresBase = { path = "a/2/1/4", memberCount = 102 },
  slider = { path = "a/0/7/5", memberCount = 2 },
  habitat = { path = "a/1/3/3", memberCount = 3962 },
  johtoInverse = { path = "a/1/3/8", memberCount = 1 },
  portraitY = { path = "a/0/0/5", memberCount = 1976 },
  portraitYAlt = { path = "a/1/1/7", memberCount = 160 },
}

-- Numeric Giratina mapping: file 343 (a/2/1/4) is the base profile
-- (45dm/7500hg), file 203 (a/0/7/4) is the origin profile (69dm/6500hg).
-- The application chooses one profile per open; the mislabeled decomp
-- branch name never overrides the observed numeric selector.
PokedexSources.measureProfiles = { base = "a/2/1/4", giratina_origin = "a/0/7/4" }

PokedexSources.sliderRows = 153
PokedexSources.speciesSlots = 494
PokedexSources.areaSlots = 495

-- Zero-based NARC member ids of the habitat encounter lists for species
-- slot S (0..494): dungeon morning/day/night, outdoor morning/day/night,
-- dungeon other, outdoor other. List values are 1-based area ids with a
-- zero terminator; slot 0 is the show-everything row, slot 494 is unused.
PokedexSources.habitatBases = { 2, 497, 992, 1487, 1982, 2477, 2972, 3467 }

-- Search mask bits of file 204 member 1 (one byte per species slot).
PokedexSources.maskBits = {
  johto = 0x02,
  kanto = 0x04,
  unknown = 0x10,
  unrestricted = 0x80,
}

-- Type lists of file 203/343 members 62..78 in source order (mystery has
-- no list). Positions are zero-based member offsets from member 62.
PokedexSources.typeOrder = {
  "normal",
  "fighting",
  "flying",
  "poison",
  "ground",
  "rock",
  "bug",
  "ghost",
  "steel",
  "fire",
  "water",
  "grass",
  "electric",
  "psychic",
  "ice",
  "dragon",
  "dark",
}

-- Body-shape lists of members 79..92 in source order.
PokedexSources.shapeOrder = {
  "quadruped",
  "bipedal without tail",
  "bipedal with tail",
  "serpentine",
  "multiple wings",
  "two wings",
  "insectoid",
  "head/torso",
  "head/arms",
  "head/legs",
  "tentacles",
  "fins",
  "head only",
  "multiple bodies",
}

-- Letter lists of members 18..43 (A..Z) in source order.
PokedexSources.letterOrder = {
  "a",
  "b",
  "c",
  "d",
  "e",
  "f",
  "g",
  "h",
  "i",
  "j",
  "k",
  "l",
  "m",
  "n",
  "o",
  "p",
  "q",
  "r",
  "s",
  "t",
  "u",
  "v",
  "w",
  "x",
  "y",
  "z",
}

-- Exact vanilla completion exclusions (event mythicals): national order
-- minus these nine is the 484 requirement set; johto order minus Mew and
-- Celebi is the 254 requirement set.
PokedexSources.completionExclusions = {
  national = { "MEW", "CELEBI", "JIRACHI", "DEOXYS", "PHIONE", "MANAPHY", "DARKRAI", "SHAYMIN", "ARCEUS" },
  johto = { "MEW", "CELEBI" },
}

-- Native ordered form families (fixed logical variant IDs). Unown alone
-- persists caught variants; Spinda alone persists its first personality.
-- Pichu carries three fixed gender/form variants; additional forms use
-- ID = form + 1 so unrelated additions never renumber saved variants.
PokedexSources.orderedPolicies = {
  UNOWN = { capacity = 28, rememberCaughtVariants = true },
  SPINDA = { capacity = 1, rememberFirstPersonality = true },
  DEOXYS = { capacity = 4 },
  BURMY = { capacity = 3 },
  WORMADAM = { capacity = 3 },
  SHELLOS = { capacity = 2 },
  GASTRODON = { capacity = 2 },
  GIRATINA = { capacity = 2 },
  SHAYMIN = { capacity = 2 },
  ROTOM = { capacity = 6 },
  PICHU = { capacity = 2, gendered = true },
}

-- Native automatic families expose every declared variant once seen and
-- persist no automatic form history.
PokedexSources.automaticFamilies = { CASTFORM = true, CHERRIM = true }

-- Fixed Pichu gender/form variants: normal male, normal female, then the
-- spiky form. Additional forms use ID = form + 1.
PokedexSources.pichuVariants = {
  { id = 0, form = 0, gender = "male" },
  { id = 1, form = 0, gender = "female" },
  { id = 2, form = 1 },
}

-- Ordinary portrait Y member in a/0/0/5 for a species, facing (0 back,
-- 2 front), and image gender: 4*S + facing + (female and 0 or 1).
---@param speciesId integer
---@param facing integer
---@param female boolean
---@return integer
function PokedexSources.ordinaryHeightMember(speciesId, facing, female)
  return 4 * speciesId + facing + (female and 0 or 1)
end

-- Alternate portrait Y members in a/1/1/7. Each entry names the native
-- form range the alternate branch covers; forms outside the native range
-- fall back to the ordinary member. Facing is 0 (back) or 2 (front).
PokedexSources.altHeightFamilies = {
  DEOXYS = { base = 0, halfFacing = true, stride = 2, forms = 4 },
  UNOWN = { base = 0x08, halfFacing = true, stride = 2, forms = 28 },
  CASTFORM = { base = 0x40, doubleFacing = true, stride = 1, forms = 4 },
  BURMY = { base = 0x48, halfFacing = true, stride = 2, forms = 3 },
  WORMADAM = { base = 0x4E, halfFacing = true, stride = 2, forms = 3 },
  SHELLOS = { base = 0x54, stride = 1, forms = 2 },
  GASTRODON = { base = 0x58, stride = 1, forms = 2 },
  CHERRIM = { base = 0x5C, stride = 1, forms = 2 },
  ARCEUS = { base = 0x60, halfFacing = true, stride = 2, forms = 18 },
  SHAYMIN = { base = 0x88, halfFacing = true, stride = 2, forms = 2 },
  ROTOM = { base = 0x8C, halfFacing = true, stride = 2, forms = 6 },
  GIRATINA = { base = 0x98, halfFacing = true, stride = 2, forms = 2 },
  PICHU = { base = 0x9C, halfFacing = true, stride = 2, forms = 2 },
}

---@param speciesKey string
---@param form integer
---@param facing integer
---@return integer?
function PokedexSources.altHeightMember(speciesKey, form, facing)
  local family = PokedexSources.altHeightFamilies[speciesKey]
  if family == nil then
    return nil
  end
  if form < 0 or form >= family.forms then
    return nil
  end
  if family.halfFacing then
    return family.base + math.floor(facing / 2) + family.stride * form
  end
  if family.doubleFacing then
    return family.base + 2 * facing + family.stride * form
  end
  return family.base + facing + family.stride * form
end

-- Fixed message roles. The native flavor bank follows the game version;
-- every other role is version-independent.
---@param versionId string
---@return table<string, unknown>
function PokedexSources.textBindings(versionId)
  assert(PokedexSources.versions[versionId], "pokedex text bindings need a supported version")
  return {
    ui = { bankId = 802 },
    entryByLanguage = {
      native = {
        nameBankId = 237,
        categoryBankId = 816,
        flavorBankId = versionId == "heartgold" and 803 or 804,
      },
      japanese = { nameBankId = 822, categoryBankId = 828, flavorBankId = 810 },
      english = { nameBankId = 817, categoryBankId = 823, flavorBankId = 805 },
      french = { nameBankId = 818, categoryBankId = 824, flavorBankId = 806 },
      german = { nameBankId = 819, categoryBankId = 825, flavorBankId = 807 },
      italian = { nameBankId = 820, categoryBankId = 826, flavorBankId = 808 },
      spanish = { nameBankId = 821, categoryBankId = 827, flavorBankId = 809 },
    },
    measureByProfile = {
      base = { heightBankId = 815, weightBankId = 813 },
      giratina_origin = { heightBankId = 814, weightBankId = 812 },
    },
    registrationAnnouncement = { bankId = 197, messageId = 871 },
  }
end

-- Message banks the presentation scope waits for. The fixed text roles
-- name every language bank, but the three Japanese entry banks cannot
-- compile against the frozen reference charmap (MESSAGE_GLYPH_UNMAPPED
-- for their control codes), a pre-existing toolchain gap unrelated to
-- this family. The presentation job therefore waits for the buildable
-- closure; the catalog still binds every language and the gap is
-- reported as a blocked capability for Japanese-locale text.
PokedexSources.unbuildableMessageBanks = { [810] = true, [822] = true, [828] = true }

---@return integer[]
function PokedexSources.messageBankIds()
  local seen, ids = {}, {}
  for _, versionId in ipairs({ "heartgold", "soulsilver" }) do
    local bindings = PokedexSources.textBindings(versionId)
    local banks = { bindings.ui.bankId }
    for _, entry in pairs(bindings.entryByLanguage) do
      banks[#banks + 1] = entry.nameBankId
      banks[#banks + 1] = entry.categoryBankId
      banks[#banks + 1] = entry.flavorBankId
    end
    for _, entry in pairs(bindings.measureByProfile) do
      banks[#banks + 1] = entry.heightBankId
      banks[#banks + 1] = entry.weightBankId
    end
    banks[#banks + 1] = bindings.registrationAnnouncement.bankId
    for _, bankId in ipairs(banks) do
      if not seen[bankId] then
        seen[bankId] = true
        ids[#ids + 1] = bankId
      end
    end
  end
  table.sort(ids)
  return ids
end

-- Producer-owned window inventory for the contracted text slots. Each
-- slot carries the tile coordinates (in logical pixels), BG layer,
-- body/header font role, alignment and text palette slot of the native
-- window template that draws it: list ids from sListWindowTemplates,
-- search ids from sSearchWindowTemplates, area ids from
-- sAreaWindowTemplates, size ids from sSizeCheckWindowTemplates,
-- entry-menu id 0 from sPokedexEntryMenuWindowTemplates, forms ids
-- from sFormsWindowTemplates and popup ids from
-- sEntryPopupWindowTemplates. Count slots anchor on their digit windows
-- (the captions share the slot's backing windows); value slots anchor
-- on their value windows; shared entry keys anchor on the canonical
-- entry view or the first native page that draws them. The popup is a
-- Main-engine card staged on the information surface, so its windows
-- project to the information pane at their native Main layer.
---@param pane string
---@param layer integer
---@param x integer
---@param y integer
---@param width integer
---@param height integer
---@param font integer
---@param align string
---@param paletteSlot integer
---@return { pane: string, layer: integer, x: integer, y: integer, width: integer, height: integer, font: integer, foreground: { r: integer, g: integer, b: integer, a: integer }, shadow: { r: integer, g: integer, b: integer, a: integer }, background: { r: integer, g: integer, b: integer, a: integer }, align: string, paletteGroup: string }
local function dexWindow(pane, layer, x, y, width, height, font, align, paletteSlot)
  return {
    pane = pane,
    layer = layer,
    x = x,
    y = y,
    width = width,
    height = height,
    font = font,
    foreground = { r = 255, g = 255, b = 255, a = 255 },
    shadow = { r = 0, g = 0, b = 0, a = 255 },
    background = { r = 0, g = 0, b = 0, a = 0 },
    align = align,
    paletteGroup = "window-" .. paletteSlot,
  }
end

PokedexSources.windows = {
  ["grid.seen-count"] = dexWindow("controls", 0, 88, 88, 24, 16, 0, "left", 9),
  ["grid.caught-count"] = dexWindow("controls", 0, 216, 88, 24, 16, 0, "left", 9),
  ["grid.selected-number"] = dexWindow("information", 1, 120, 24, 32, 16, 4, "left", 0),
  ["grid.selected-name"] = dexWindow("information", 1, 152, 24, 72, 16, 4, "left", 0),
  ["entry.species-name"] = dexWindow("information", 1, 0, 128, 72, 16, 0, "center", 1),
  ["entry.dex-number"] = dexWindow("information", 1, 120, 24, 32, 16, 4, "left", 0),
  ["entry.category"] = dexWindow("information", 1, 104, 40, 144, 16, 4, "right", 0),
  ["entry.flavor"] = dexWindow("information", 1, 16, 136, 224, 48, 0, "left", 1),
  ["entry.height"] = dexWindow("information", 1, 56, 168, 64, 16, 0, "center", 2),
  ["entry.weight"] = dexWindow("controls", 1, 56, 184, 64, 16, 0, "center", 1),
  ["search.criteria"] = dexWindow("controls", 0, 128, 8, 88, 16, 4, "center", 2),
  ["search.feedback"] = dexWindow("information", 1, 16, 152, 224, 40, 0, "center", 2),
  ["search.results"] = dexWindow("information", 1, 16, 0, 64, 16, 4, "left", 2),
  ["area.time"] = dexWindow("information", 1, 8, 24, 56, 16, 0, "center", 1),
  ["area.location"] = dexWindow("controls", 2, 80, 40, 144, 16, 4, "center", 1),
  ["size.title"] = dexWindow("information", 1, 16, 0, 72, 16, 4, "left", 2),
  ["forms.selected"] = dexWindow("information", 1, 104, 40, 120, 16, 0, "center", 1),
  ["forms.compare-left"] = dexWindow("controls", 1, 0, 96, 128, 16, 0, "center", 1),
  ["forms.compare-right"] = dexWindow("controls", 1, 128, 96, 128, 16, 0, "center", 1),
  ["return.title"] = dexWindow("information", 1, 16, 0, 72, 16, 4, "left", 2),
  ["registration.header"] = dexWindow("information", 1, 16, 0, 224, 16, 4, "center", 2),
  ["registration.dex-number"] = dexWindow("information", 1, 120, 24, 32, 16, 4, "left", 0),
  ["registration.species-name"] = dexWindow("information", 1, 152, 24, 72, 16, 4, "left", 0),
  ["registration.category"] = dexWindow("information", 1, 104, 40, 144, 16, 4, "right", 0),
  ["registration.flavor"] = dexWindow("information", 1, 16, 136, 224, 48, 0, "left", 1),
  ["registration.height"] = dexWindow("information", 1, 184, 88, 64, 16, 0, "left", 1),
  ["registration.weight"] = dexWindow("information", 1, 184, 104, 64, 16, 0, "left", 1),
}

-- Page-local window inventories over the contracted slots.
local gridWindows = { "grid.seen-count", "grid.caught-count", "grid.selected-number", "grid.selected-name" }
local searchEditorWindows = { "search.criteria", "search.feedback" }

PokedexSources.pageWindows = {
  cover = {},
  grid = gridWindows,
  results = { "search.results", "grid.selected-number", "grid.selected-name" },
  ["search.criteria"] = searchEditorWindows,
  ["search.order"] = searchEditorWindows,
  ["search.name"] = searchEditorWindows,
  ["search.type"] = searchEditorWindows,
  ["search.height"] = searchEditorWindows,
  ["search.weight"] = searchEditorWindows,
  ["search.area"] = searchEditorWindows,
  ["search.shape"] = searchEditorWindows,
  ["entry.area"] = { "entry.species-name", "entry.dex-number", "area.time", "area.location" },
  ["entry.size"] = { "size.title", "entry.species-name", "entry.height", "entry.weight" },
  ["entry.forms"] = { "forms.selected", "entry.species-name", "entry.dex-number" },
  ["entry.compare"] = { "forms.compare-left", "forms.compare-right" },
  ["entry.return"] = { "return.title" },
  registration = {
    "registration.header",
    "registration.dex-number",
    "registration.species-name",
    "registration.category",
    "registration.flavor",
    "registration.height",
    "registration.weight",
  },
}

return PokedexSources
