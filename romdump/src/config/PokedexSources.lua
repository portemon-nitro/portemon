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
    -- Map-section display names behind the area rows
    -- (`BufferLandmarkName`): bank 279 by map-section id, falling back
    -- to bank 280 entry 2 when the section id is zero or past the bank.
    landmarks = { bankId = 279, fallbackBankId = 280, fallbackMessageId = 2 },
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

-- Native search/entry UI message identities behind the contracted text
-- slots: every id is a bank-802 entry (see the pinned
-- `pokedex_windows.c` draw methods and `sSearchTypeMsgIds`). Criteria
-- captions 26..32, criteria buttons 35..37, editor commit buttons
-- 39..40, sort labels 41..46 in criteria-declaration sequence, type
-- marks in `typeOrder` sequence with 64 for the empty mark, area scopes
-- 65..68, letter marks 69..94 (A..Z) with 113 for the empty mark,
-- daypart marks from 129 (morning), and the back-tab actions 173..174.
-- Runtime code never reads these ids directly; the catalog compiler
-- projects them into `searchText` and the browser reads that projection.
---@return { criteria: table<string, integer>, orders: table<string, integer>, letters: table<string, integer>, types: table<string, integer>, areas: table<string, integer>, buttons: table<string, integer>, editorButtons: table<string, integer>, timeBase: integer, returnCancel: integer, returnAction: integer }
function PokedexSources.searchText()
  local typeIds = { 58, 50, 60, 56, 54, 48, 63, 53, 59, 61, 62, 51, 55, 49, 52, 57, 47 }
  assert(#typeIds == #PokedexSources.typeOrder, "type marks cover every search type")
  local types = { unrestricted = 64 }
  for index, name in ipairs(PokedexSources.typeOrder) do
    types[name] = typeIds[index]
  end
  local letters = { unrestricted = 113 }
  for code = string.byte("A"), string.byte("Z") do
    letters[string.char(code)] = 68 + (code - string.byte("A") + 1)
  end
  return {
    criteria = { order = 26, letter = 27, type = 28, height = 29, weight = 30, area = 31, shape = 32 },
    orders = { numerical = 41, alphabetical = 42, heaviest = 43, lightest = 44, tallest = 45, shortest = 46 },
    letters = letters,
    types = types,
    areas = { johto = 65, kanto = 66, unknown = 67, unrestricted = 68 },
    buttons = { run = 36, reset = 35, back = 37 },
    editorButtons = { ok = 39, cancel = 40 },
    timeBase = 129,
    returnCancel = 173,
    returnAction = 174,
  }
end

-- Native area/size/forms/back-tab UI message identities behind the entry
-- text slots: every id is a bank-802 entry (see the pinned
-- `pokedex_windows.c` setup/draw methods). Area title 142, caption 132,
-- unknown banner 128, region-entry names 134/135; size title 143, height
-- caption 136, height marks 10, male/female height words 138/139, weight
-- caption 137, weight marks 11, male/female weight words 140/141; forms
-- title 170, species header 167, multi-form caption 168, compare header
-- 169, compare side labels 171/172. Runtime code never reads these ids
-- directly; the catalog compiler projects them into `entryText`.
---@return table<string, integer>
function PokedexSources.entryText()
  return {
    areaTitle = 142,
    areaCaption = 132,
    areaUnknown = 128,
    areaRegionJohto = 134,
    areaRegionKanto = 135,
    sizeTitle = 143,
    sizeCaptionHeight = 136,
    sizeMarkHeight = 10,
    sizeMaleHeight = 138,
    sizeFemaleHeight = 139,
    sizeCaptionWeight = 137,
    sizeMarkWeight = 11,
    sizeMaleWeight = 140,
    sizeFemaleWeight = 141,
    formsTitle = 170,
    formsHeader = 167,
    formsCaption = 168,
    formsCompareHeader = 169,
    formsCompareLeft = 171,
    formsCompareRight = 172,
  }
end

-- Species-specific form-name policy transcribed from
-- `PokedexApp_GetFormNameMsg`: the bank-802 message naming one seen form
-- of the species. `base` names the first message of a contiguous run
-- indexed by form id with `count` valid forms; `fixed` names one message
-- for every form; `male`/`female` name the gendered rows of species
-- without a form run while `generic` carries the species name for the
-- rest; `pichu` maps its form ids with `other` for anything beyond.
-- Runtime code never reads these ids directly; the catalog compiler
-- projects them into `formNames` and the browser applies the policy.
---@return { fixed: table<string, integer>, base: table<string, integer>, count: table<string, integer>, pichu: table<integer|string, integer>, male: integer, female: integer, generic: integer }
function PokedexSources.formNameMessages()
  local base = {
    SHELLOS = 116,
    GASTRODON = 116,
    BURMY = 118,
    WORMADAM = 118,
    DEOXYS = 145,
    SHAYMIN = 149,
    GIRATINA = 151,
    ROTOM = 153,
    CASTFORM = 160,
    CHERRIM = 164,
  }
  local count = {
    SHELLOS = 2,
    GASTRODON = 2,
    BURMY = 3,
    WORMADAM = 3,
    DEOXYS = 4,
    SHAYMIN = 2,
    GIRATINA = 2,
    ROTOM = 6,
    CASTFORM = 4,
    CHERRIM = 2,
  }
  return {
    fixed = { UNOWN = 121 },
    base = base,
    count = count,
    pichu = { [0] = 114, [1] = 115, other = 166 },
    male = 114,
    female = 115,
    generic = 159,
  }
end

-- Habitat area ids to the retail map identities behind their landmark
-- names, transcribed from `sOverworldMapIDs`/`sDungeonMapIDs`: outdoor id
-- v (1-based) reads entry v, dungeon id v reads entry v, with entry 0
-- and the trailing entries holding the 0xFFFF sentinel for no map.
-- A nil entry means the area id addresses no retail map.
---@return { outdoor: (string|nil)[], dungeon: (string|nil)[] }
function PokedexSources.areaMapSymbols()
  local outdoor = {
    [1] = "MAP_NEW_BARK",
    [2] = "MAP_ROUTE_29",
    [3] = "MAP_CHERRYGROVE",
    [4] = "MAP_ROUTE_30",
    [5] = "MAP_ROUTE_31",
    [6] = "MAP_VIOLET",
    [7] = "MAP_ROUTE_32",
    [8] = "MAP_ROUTE_33",
    [9] = "MAP_ROUTE_34",
    [10] = "MAP_ROUTE_35",
    [11] = "MAP_ROUTE_36",
    [12] = "MAP_ROUTE_37",
    [13] = "MAP_ECRUTEAK",
    [14] = "MAP_ROUTE_38",
    [15] = "MAP_ROUTE_39",
    [16] = "MAP_OLIVINE",
    [17] = "MAP_ROUTE_40",
    [18] = "MAP_ROUTE_41",
    [19] = "MAP_CIANWOOD",
    [20] = "MAP_ROUTE_42",
    [21] = "MAP_ROUTE_43",
    [22] = "MAP_LAKE_OF_RAGE",
    [23] = "MAP_ROUTE_44",
    [24] = "MAP_BLACKTHORN",
    [25] = "MAP_ROUTE_45",
    [26] = "MAP_ROUTE_46",
    [27] = "MAP_ROUTE_47",
    [28] = "MAP_MOUNT_SILVER",
    [29] = "MAP_ROUTE_12",
    [30] = "MAP_ROUTE_19",
    [31] = "MAP_ROUTE_20",
    [32] = "MAP_PALLET",
    [33] = "MAP_VIRIDIAN",
    [34] = "MAP_CERULEAN",
    [35] = "MAP_VERMILION",
    [36] = "MAP_CELADON",
    [37] = "MAP_FUCHSIA",
    [38] = "MAP_CINNABAR_ISLAND",
    [39] = "MAP_ROUTE_48",
    [40] = "MAP_ROUTE_26",
    [41] = "MAP_ROUTE_27",
    [42] = "MAP_ROUTE_28",
    [43] = "MAP_ROUTE_1",
    [44] = "MAP_ROUTE_2",
    [45] = "MAP_ROUTE_3",
    [46] = "MAP_ROUTE_4",
    [47] = "MAP_ROUTE_5",
    [48] = "MAP_ROUTE_6",
    [49] = "MAP_ROUTE_7",
    [50] = "MAP_ROUTE_8",
    [51] = "MAP_ROUTE_9",
    [52] = "MAP_ROUTE_10",
    [53] = "MAP_ROUTE_11",
    [54] = "MAP_ROUTE_13",
    [55] = "MAP_ROUTE_14",
    [56] = "MAP_ROUTE_15",
    [57] = "MAP_ROUTE_16_EAST",
    [58] = "MAP_ROUTE_17",
    [59] = "MAP_ROUTE_18",
    [60] = "MAP_ROUTE_21",
    [61] = "MAP_ROUTE_22",
    [62] = "MAP_ROUTE_24",
    [63] = "MAP_ROUTE_25",
    [64] = "MAP_ROUTE_2_EAST",
    [65] = "MAP_PEWTER",
    [66] = "MAP_AZALEA",
    [67] = "MAP_SAFARI_ZONE_GATE",
    [68] = "MAP_ROUTE_16",
  }
  local dungeon = {
    [1] = "MAP_SPROUT_TOWER_2F",
    [2] = "MAP_RUINS_OF_ALPH",
    [3] = "MAP_UNION_CAVE_1F",
    [4] = "MAP_SLOWPOKE_WELL_B1F",
    [5] = "MAP_ILEX_FOREST",
    [6] = "MAP_NATIONAL_PARK",
    [7] = "MAP_BURNED_TOWER_1F",
    [8] = "MAP_BELL_TOWER_2F",
    [9] = "MAP_WHIRL_ISLANDS_1F",
    [10] = "MAP_MOUNT_MORTAR_1F_ENTRANCE",
    [11] = "MAP_ICE_PATH_1F",
    [12] = "MAP_DRAGONS_DEN",
    [13] = "MAP_DARK_CAVE_ROUTE_31_SIDE",
    [14] = "MAP_MOUNT_MOON_SQUARE",
    [15] = "MAP_SEAFOAM_ISLANDS_1F",
    [16] = "MAP_MOUNT_SILVER_CAVE_MOLTRES_CHAMBER",
    [17] = "MAP_CLIFF_EDGE_GATE",
    [18] = "MAP_CLIFF_CAVE",
    [19] = "MAP_SS_AQUA_OLIVINE_PORT_INTERIOR",
    [20] = "MAP_ROCK_TUNNEL_1F",
    [21] = "MAP_VICTORY_ROAD_1F",
    [22] = "MAP_TOHJO_FALLS",
    [23] = "MAP_DIGLETT_CAVE",
    [24] = "MAP_VIRIDIAN_FOREST",
    [25] = "MAP_CERULEAN_CAVE_1F",
  }
  return { outdoor = outdoor, dungeon = dungeon }
end

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
    if type(bindings.landmarks) == "table" then
      banks[#banks + 1] = bindings.landmarks.bankId
      banks[#banks + 1] = bindings.landmarks.fallbackBankId
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
  ["return.action"] = dexWindow("information", 1, 128, 150, 120, 14, 4, "center", 2),
  ["registration.header"] = dexWindow("information", 1, 16, 0, 224, 16, 4, "center", 2),
  ["registration.dex-number"] = dexWindow("information", 1, 120, 24, 32, 16, 4, "left", 0),
  ["registration.species-name"] = dexWindow("information", 1, 152, 24, 72, 16, 4, "left", 0),
  ["registration.category"] = dexWindow("information", 1, 104, 40, 144, 16, 4, "right", 0),
  ["registration.flavor"] = dexWindow("information", 1, 16, 136, 224, 48, 0, "left", 1),
  ["registration.height"] = dexWindow("information", 1, 184, 88, 64, 16, 0, "left", 1),
  ["registration.weight"] = dexWindow("information", 1, 184, 104, 64, 16, 0, "left", 1),
}

-- Source-transcribed text-run windows for the search/entry bindings above.
-- Each record carries the native `WindowTemplate` tile origin (in logical
-- 256x192 pixels), BG layer, body/header font role, text palette slot, and
-- the per-print x/y + alignment from the `pokedex_windows.c` draw method
-- that paints it (pinned decomp revision in `provenance`): the logical
-- sub-window rect reproduces the print placement through the existing
-- renderer (left prints anchor at the print x, right prints end at it,
-- centered prints center on it), so no schema `runs` shape or renderer
-- change is needed. Template ids equal window ids: search templates
-- 0-100, area 0-13, size-check 0-12, forms 0-15, entry-menu 0-1.
-- bgId 0/1/2 are MAIN BG0/BG1/BG2 (controls pane layers 0/1/2) and bgId 5
-- is SUB BG1 (information pane layer 1). Native print colors name window
-- palette slots (`MAKE_TEXT_COLOR` fg/sh/bg); the runtime keeps the
-- established white/black/transparent triple, recorded per family here.
-- Menu labels/values and the return-slot summary share tile geometry on
-- different panes (MAIN vs SUB), so captions/values exist twice: once
-- for the menu rects, once for the summary rects.
do
  -- Menu labels (search templates 20-26, MAIN BG0; prints font 0,
  -- color (2,1,0), centered on the print x).
  PokedexSources.windows["search.caption-order"] = dexWindow("controls", 0, 32, 8, 72, 16, 0, "center", 2)
  PokedexSources.windows["search.caption-letter"] = dexWindow("controls", 0, 8, 32, 40, 16, 0, "center", 2)
  PokedexSources.windows["search.caption-type"] = dexWindow("controls", 0, 8, 56, 40, 16, 0, "center", 2)
  PokedexSources.windows["search.caption-height"] = dexWindow("controls", 0, 8, 80, 40, 16, 0, "center", 2)
  PokedexSources.windows["search.caption-weight"] = dexWindow("controls", 0, 8, 104, 40, 16, 0, "center", 2)
  PokedexSources.windows["search.caption-area"] = dexWindow("controls", 0, 8, 128, 40, 16, 0, "center", 2)
  PokedexSources.windows["search.caption-shape"] = dexWindow("controls", 0, 200, 32, 48, 16, 0, "center", 2)
  -- Menu values (templates 27-35; order/letter/height/weight/area print
  -- centered in font 4, types print at x=29 in font 4).
  PokedexSources.windows["search.value-order"] = dexWindow("controls", 0, 128, 8, 88, 16, 4, "center", 2)
  PokedexSources.windows["search.value-letter"] = dexWindow("controls", 0, 56, 32, 72, 16, 4, "center", 2)
  PokedexSources.windows["search.value-type-1"] = dexWindow("controls", 0, 56, 56, 58, 16, 4, "center", 2)
  PokedexSources.windows["search.value-type-2"] = dexWindow("controls", 0, 120, 56, 58, 16, 4, "center", 2)
  PokedexSources.windows["search.value-height-min"] = dexWindow("controls", 0, 56, 80, 48, 16, 4, "center", 2)
  PokedexSources.windows["search.value-height-max"] = dexWindow("controls", 0, 120, 80, 48, 16, 4, "center", 2)
  PokedexSources.windows["search.value-weight-min"] = dexWindow("controls", 0, 56, 104, 48, 16, 4, "center", 2)
  PokedexSources.windows["search.value-weight-max"] = dexWindow("controls", 0, 120, 104, 48, 16, 4, "center", 2)
  PokedexSources.windows["search.value-area"] = dexWindow("controls", 0, 56, 128, 56, 16, 4, "center", 2)
  -- Menu and editor commit buttons (templates 17-19, MAIN BG1, palette
  -- slot 4; labels centered in font 4 over the 8-tile button frame).
  PokedexSources.windows["search.button-run"] = dexWindow("controls", 1, 8, 8, 64, 16, 4, "center", 4)
  PokedexSources.windows["search.button-reset"] = dexWindow("controls", 1, 96, 8, 64, 16, 4, "center", 4)
  PokedexSources.windows["search.button-back"] = dexWindow("controls", 1, 184, 8, 64, 16, 4, "center", 4)
  PokedexSources.windows["search.button-ok"] = dexWindow("controls", 1, 8, 8, 64, 16, 4, "center", 4)
  PokedexSources.windows["search.button-cancel"] = dexWindow("controls", 1, 184, 8, 64, 16, 4, "center", 4)
  -- Return-slot summary captions (templates 1-7, SUB BG1; same tiles as
  -- the menu labels, same font 0 centered prints).
  PokedexSources.windows["search.summary-caption-order"] = dexWindow("information", 1, 32, 8, 72, 16, 0, "center", 2)
  PokedexSources.windows["search.summary-caption-letter"] = dexWindow("information", 1, 8, 32, 40, 16, 0, "center", 2)
  PokedexSources.windows["search.summary-caption-type"] = dexWindow("information", 1, 8, 56, 40, 16, 0, "center", 2)
  PokedexSources.windows["search.summary-caption-height"] = dexWindow("information", 1, 8, 80, 40, 16, 0, "center", 2)
  PokedexSources.windows["search.summary-caption-weight"] =
    dexWindow("information", 1, 8, 104, 40, 16, 0, "center", 2)
  PokedexSources.windows["search.summary-caption-area"] = dexWindow("information", 1, 8, 128, 40, 16, 0, "center", 2)
  PokedexSources.windows["search.summary-caption-shape"] =
    dexWindow("information", 1, 200, 32, 48, 16, 0, "center", 2)
  -- Return-slot summary values (templates 8-16; same content as the
  -- menu values, SUB BG1 rects).
  PokedexSources.windows["search.summary-value-order"] = dexWindow("information", 1, 128, 8, 88, 16, 4, "center", 2)
  PokedexSources.windows["search.summary-value-letter"] =
    dexWindow("information", 1, 56, 32, 72, 16, 4, "center", 2)
  PokedexSources.windows["search.summary-value-type-1"] =
    dexWindow("information", 1, 56, 56, 58, 16, 4, "center", 2)
  PokedexSources.windows["search.summary-value-type-2"] =
    dexWindow("information", 1, 120, 56, 58, 16, 4, "center", 2)
  PokedexSources.windows["search.summary-value-height-min"] =
    dexWindow("information", 1, 56, 80, 48, 16, 4, "center", 2)
  PokedexSources.windows["search.summary-value-height-max"] =
    dexWindow("information", 1, 120, 80, 48, 16, 4, "center", 2)
  PokedexSources.windows["search.summary-value-weight-min"] =
    dexWindow("information", 1, 56, 104, 48, 16, 4, "center", 2)
  PokedexSources.windows["search.summary-value-weight-max"] =
    dexWindow("information", 1, 120, 104, 48, 16, 4, "center", 2)
  PokedexSources.windows["search.summary-value-area"] =
    dexWindow("information", 1, 56, 128, 56, 16, 4, "center", 2)
  -- Order editor: title 36, current value 37, six options 38-43.
  PokedexSources.windows["search.title-order"] = dexWindow("controls", 0, 24, 8, 88, 16, 0, "center", 2)
  PokedexSources.windows["search.current-order"] = dexWindow("controls", 0, 144, 8, 88, 16, 4, "center", 2)
  local orderNames = { "numerical", "alphabetical", "heaviest", "lightest", "tallest", "shortest" }
  local orderRects = {
    { 24, 48 },
    { 144, 48 },
    { 24, 80 },
    { 144, 80 },
    { 24, 112 },
    { 144, 112 },
  }
  for index, name in ipairs(orderNames) do
    local rect = orderRects[index]
    PokedexSources.windows["search.option-order-" .. name] =
      dexWindow("controls", 0, rect[1], rect[2], 88, 16, 4, "center", 2)
  end
  -- Letter editor: title 65, current value 66, and the 27 marks sharing
  -- window 67 (origin (8,40)). Each mark prints at column*32+24,
  -- row*32 in font 4 centered, where column/row come from
  -- sLetterGridCells (identity except the empty mark at cell 27); the
  -- logical cell (24+column*32, 40+row*32, 16, 16) matches both the
  -- print center and the 2x2-tile highlight rect.
  PokedexSources.windows["search.title-letter"] = dexWindow("controls", 0, 56, 8, 48, 16, 0, "center", 2)
  PokedexSources.windows["search.current-letter"] = dexWindow("controls", 0, 120, 8, 72, 16, 4, "center", 2)
  for position = 0, 26 do
    local label = position < 26 and string.char(string.byte("A") + position) or "unrestricted"
    local cell = position < 26 and position or 27
    local column, row = cell % 7, math.floor(cell / 7)
    PokedexSources.windows["search.option-letter-" .. label] =
      dexWindow("controls", 0, 24 + column * 32, 40 + row * 32, 16, 16, 4, "center", 2)
  end
  -- Type editor: title 44, current values 45-46, and the 18 marks in a
  -- 4-column grid (windows 47-64 in `typeOrder` sequence with the empty
  -- mark last, per `sSearchTypeMsgIds`).
  PokedexSources.windows["search.title-type"] = dexWindow("controls", 0, 24, 8, 56, 16, 0, "center", 2)
  PokedexSources.windows["search.current-type-1"] = dexWindow("controls", 0, 104, 8, 58, 16, 4, "center", 2)
  PokedexSources.windows["search.current-type-2"] = dexWindow("controls", 0, 168, 8, 70, 16, 4, "center", 2)
  for index, name in ipairs(PokedexSources.typeOrder) do
    local column, row = (index - 1) % 4, math.floor((index - 1) / 4)
    PokedexSources.windows["search.option-type-" .. name] =
      dexWindow("controls", 0, column * 64, 40 + row * 24, 64, 16, 4, "center", 2)
  end
  PokedexSources.windows["search.option-type-unrestricted"] = dexWindow("controls", 0, 64, 136, 64, 16, 4, "center", 2)
  -- Height/weight editors: titles 68/71 plus the staged min/max bounds
  -- (69-70, 72-73; the native integer slider values).
  PokedexSources.windows["search.title-height"] = dexWindow("controls", 0, 24, 8, 40, 16, 0, "center", 2)
  PokedexSources.windows["search.current-height-min"] = dexWindow("controls", 0, 80, 8, 56, 16, 4, "center", 2)
  PokedexSources.windows["search.current-height-max"] = dexWindow("controls", 0, 152, 8, 56, 16, 4, "center", 2)
  PokedexSources.windows["search.title-weight"] = dexWindow("controls", 0, 8, 8, 48, 16, 0, "center", 2)
  PokedexSources.windows["search.current-weight-min"] = dexWindow("controls", 0, 64, 8, 72, 16, 4, "center", 2)
  PokedexSources.windows["search.current-weight-max"] = dexWindow("controls", 0, 152, 8, 72, 16, 4, "center", 2)
  -- Area editor: title 74, staged value 75, four scopes 76-79.
  PokedexSources.windows["search.title-area"] = dexWindow("controls", 0, 56, 8, 48, 16, 0, "center", 2)
  PokedexSources.windows["search.current-area"] = dexWindow("controls", 0, 128, 8, 56, 16, 4, "center", 2)
  local areaEditorNames = { "johto", "kanto", "unknown", "unrestricted" }
  local areaEditorRects = { { 48, 64 }, { 152, 64 }, { 48, 120 }, { 152, 120 } }
  for index, name in ipairs(areaEditorNames) do
    local rect = areaEditorRects[index]
    PokedexSources.windows["search.option-area-" .. name] =
      dexWindow("controls", 0, rect[1], rect[2], 56, 16, 4, "center", 2)
  end
  -- Shape editor: the title window 80 only; the 14 silhouettes are OBJ
  -- art (see `spriteAnchors`) and the source prints no option labels.
  PokedexSources.windows["search.title-shape"] = dexWindow("controls", 0, 64, 8, 48, 24, 0, "center", 2)
  -- Area screen: title 0 (msg 142), daypart 1, unknown banner 3
  -- (msg 128, shown when the list holds only the region entry), caption
  -- 4 (msg 132), region tabs (5/7 national, 6 solo), rows 8-13.
  -- `area.time` and `area.location` keep their oracle records above;
  -- `area.location` is the first visible row window.
  PokedexSources.windows["area.title"] = dexWindow("information", 1, 16, 0, 72, 16, 4, "left", 2)
  PokedexSources.windows["area.unknown"] = dexWindow("information", 1, 104, 96, 112, 16, 0, "center", 2)
  PokedexSources.windows["area.caption"] = dexWindow("information", 1, 8, 40, 48, 16, 0, "center", 1)
  PokedexSources.windows["area.tab-johto"] = dexWindow("information", 1, 72, 8, 56, 16, 4, "center", 1)
  PokedexSources.windows["area.tab-kanto"] = dexWindow("information", 1, 192, 8, 56, 16, 4, "center", 1)
  PokedexSources.windows["area.tab-johto-solo"] = dexWindow("information", 1, 144, 8, 56, 16, 0, "center", 1)
  for row = 2, 6 do
    PokedexSources.windows["area.row-" .. row] =
      dexWindow("controls", 2, 80, 40 + (row - 1) * 24, 144, 16, 4, "center", 1)
  end
  -- Size screen: title 0 (143), species name 1, player name 2, height
  -- caption 3 (136), height marks 4/6 (10), gender height 7 (138/139),
  -- weight caption 8 (137), weight marks 9/11 (11), gender weight 12
  -- (140/141). `entry.height` is the species height window 5;
  -- `entry.weight` keeps its oracle record.
  PokedexSources.windows["size.species-name"] = dexWindow("information", 1, 32, 24, 64, 16, 0, "center", 1)
  PokedexSources.windows["size.player-name"] = dexWindow("information", 1, 160, 24, 64, 16, 0, "center", 1)
  PokedexSources.windows["size.caption-height"] = dexWindow("information", 1, 80, 48, 96, 16, 0, "center", 1)
  PokedexSources.windows["size.mark-height-left"] = dexWindow("information", 1, 16, 168, 32, 16, 0, "center", 1)
  PokedexSources.windows["size.mark-height-right"] = dexWindow("information", 1, 136, 168, 32, 16, 0, "center", 1)
  PokedexSources.windows["size.gender-height"] = dexWindow("information", 1, 176, 168, 64, 16, 0, "center", 1)
  PokedexSources.windows["size.caption-weight"] = dexWindow("information", 1, 80, 8, 96, 16, 0, "center", 1)
  PokedexSources.windows["size.mark-weight-left"] = dexWindow("controls", 1, 16, 136, 32, 16, 0, "center", 1)
  PokedexSources.windows["size.mark-weight-right"] = dexWindow("controls", 1, 136, 136, 32, 16, 0, "center", 1)
  -- Species weight on the size page is its own lower-pane window 10;
  -- the entry-page `entry.weight` rect would overflow the lower screen.
  PokedexSources.windows["size.species-weight"] = dexWindow("controls", 1, 56, 136, 64, 16, 0, "center", 1)
  PokedexSources.windows["size.gender-weight"] = dexWindow("controls", 1, 176, 136, 64, 16, 0, "center", 1)
  -- Forms screen: title 0 (170), species header 1 (167 + species name),
  -- selected form 2, caption 4 (168, only above one form), six list
  -- rows 10-15. `forms.selected` keeps its oracle record above.
  PokedexSources.windows["forms.title"] = dexWindow("information", 1, 16, 0, 72, 16, 4, "left", 2)
  PokedexSources.windows["forms.header"] = dexWindow("information", 1, 32, 40, 72, 16, 0, "right", 1)
  PokedexSources.windows["forms.caption"] = dexWindow("information", 1, 168, 136, 80, 16, 4, "left", 1)
  for row = 1, 6 do
    PokedexSources.windows["forms.row-" .. row] =
      dexWindow("controls", 2, 64, 8 + (row - 1) * 24, 144, 16, 4, "left", 1)
  end
  -- Compare screen: title 0 (170, shared with `forms.title`), species
  -- header 3 (169 + species name), caption 5 (170), side labels 8-9
  -- (171/172). `forms.compare-left/right` keep their oracle records.
  PokedexSources.windows["forms.compare-header"] = dexWindow("information", 1, 56, 40, 144, 16, 0, "center", 1)
  PokedexSources.windows["forms.compare-caption"] = dexWindow("information", 1, 104, 16, 48, 16, 0, "center", 1)
  PokedexSources.windows["forms.compare-label-left"] = dexWindow("controls", 1, 24, 164, 96, 16, 4, "center", 1)
  PokedexSources.windows["forms.compare-label-right"] = dexWindow("controls", 1, 144, 164, 96, 16, 4, "center", 1)
  -- Back tab: title 0 (173); the message 1 (174) replaces the invented
  -- cancel/action split with the single authored return-to-list line.
  PokedexSources.windows["return.action"] = dexWindow("information", 1, 80, 80, 120, 16, 4, "center", 1)
  local detailWindows = {
    ["compact.detail-number"] = dexWindow("information", 1, 120, 80, 32, 14, 4, "left", 0),
    ["compact.detail-name"] = dexWindow("information", 1, 152, 80, 72, 14, 4, "left", 0),
    ["compact.detail-category"] = dexWindow("information", 1, 104, 96, 120, 14, 4, "right", 0),
    ["compact.detail-flavor"] = dexWindow("information", 1, 16, 130, 224, 48, 0, "left", 1),
    ["compact.detail-height"] = dexWindow("information", 1, 56, 112, 64, 14, 0, "center", 2),
    ["compact.detail-weight"] = dexWindow("information", 1, 136, 112, 64, 14, 0, "center", 2),
  }
  for role, record in pairs(detailWindows) do
    PokedexSources.windows[role] = record
  end
end

-- Page-local window inventories over the contracted slots. Menu labels
-- and values keep the menu rects; each editor carries its own title and
-- current-value rects; the results return slot shows the criteria summary
-- (native hides it once a species highlights); entry pages carry the
-- native page windows. The selected detail family stays out of the
-- grid/results paint: its prepared strings are data for the adapted
-- inspector surface, and the native list pages never paint entry details.
-- The inventory records above remain their generated backing.
local gridWindows = { "grid.seen-count", "grid.caught-count", "grid.selected-number", "grid.selected-name" }
local searchCriteriaWindows = { "search.criteria", "search.feedback" }
for _, name in ipairs({ "order", "letter", "type", "height", "weight", "area", "shape" }) do
  searchCriteriaWindows[#searchCriteriaWindows + 1] = "search.caption-" .. name
end
for _, role in ipairs({
  "search.value-order",
  "search.value-letter",
  "search.value-type-1",
  "search.value-type-2",
  "search.value-height-min",
  "search.value-height-max",
  "search.value-weight-min",
  "search.value-weight-max",
  "search.value-area",
  "search.button-run",
  "search.button-reset",
  "search.button-back",
}) do
  searchCriteriaWindows[#searchCriteriaWindows + 1] = role
end
local searchSummaryWindows = {}
for _, name in ipairs({ "order", "letter", "type", "height", "weight", "area", "shape" }) do
  searchSummaryWindows[#searchSummaryWindows + 1] = "search.summary-caption-" .. name
end
for _, role in ipairs({
  "search.summary-value-order",
  "search.summary-value-letter",
  "search.summary-value-type-1",
  "search.summary-value-type-2",
  "search.summary-value-height-min",
  "search.summary-value-height-max",
  "search.summary-value-weight-min",
  "search.summary-value-weight-max",
  "search.summary-value-area",
}) do
  searchSummaryWindows[#searchSummaryWindows + 1] = role
end
local searchOrderWindows =
  { "search.criteria", "search.feedback", "search.title-order", "search.current-order", "search.button-ok", "search.button-cancel" }
for _, name in ipairs({ "numerical", "alphabetical", "heaviest", "lightest", "tallest", "shortest" }) do
  searchOrderWindows[#searchOrderWindows + 1] = "search.option-order-" .. name
end
local searchLetterWindows = { "search.criteria", "search.feedback", "search.title-letter", "search.current-letter" }
for position = 0, 26 do
  local label = position < 26 and string.char(string.byte("A") + position) or "unrestricted"
  searchLetterWindows[#searchLetterWindows + 1] = "search.option-letter-" .. label
end
searchLetterWindows[#searchLetterWindows + 1] = "search.button-ok"
searchLetterWindows[#searchLetterWindows + 1] = "search.button-cancel"
local searchTypeWindows =
  { "search.criteria", "search.feedback", "search.title-type", "search.current-type-1", "search.current-type-2" }
for _, name in ipairs(PokedexSources.typeOrder) do
  searchTypeWindows[#searchTypeWindows + 1] = "search.option-type-" .. name
end
searchTypeWindows[#searchTypeWindows + 1] = "search.option-type-unrestricted"
searchTypeWindows[#searchTypeWindows + 1] = "search.button-ok"
searchTypeWindows[#searchTypeWindows + 1] = "search.button-cancel"
local function searchSliderWindows(criterion)
  return {
    "search.criteria",
    "search.feedback",
    "search.title-" .. criterion,
    "search.current-" .. criterion .. "-min",
    "search.current-" .. criterion .. "-max",
    "search.button-ok",
    "search.button-cancel",
  }
end
local searchAreaWindows =
  { "search.criteria", "search.feedback", "search.title-area", "search.current-area", "search.button-ok", "search.button-cancel" }
for _, name in ipairs({ "johto", "kanto", "unknown", "unrestricted" }) do
  searchAreaWindows[#searchAreaWindows + 1] = "search.option-area-" .. name
end
local searchShapeWindows =
  { "search.criteria", "search.feedback", "search.title-shape", "search.button-ok", "search.button-cancel" }
local resultsWindows = { "search.results", "grid.selected-number", "grid.selected-name" }
for _, role in ipairs(searchSummaryWindows) do
  resultsWindows[#resultsWindows + 1] = role
end
PokedexSources.pageWindows = {
  cover = {},
  grid = gridWindows,
  results = resultsWindows,
  ["search.criteria"] = searchCriteriaWindows,
  ["search.order"] = searchOrderWindows,
  ["search.name"] = searchLetterWindows,
  ["search.type"] = searchTypeWindows,
  ["search.height"] = searchSliderWindows("height"),
  ["search.weight"] = searchSliderWindows("weight"),
  ["search.area"] = searchAreaWindows,
  ["search.shape"] = searchShapeWindows,
  ["entry.area"] = {
    "area.title",
    "entry.species-name",
    "entry.dex-number",
    "area.time",
    "area.caption",
    "area.tab-johto",
    "area.tab-kanto",
    "area.tab-johto-solo",
    "area.unknown",
    "area.location",
    "area.row-2",
    "area.row-3",
    "area.row-4",
    "area.row-5",
    "area.row-6",
  },
  ["entry.size"] = {
    "size.title",
    "size.species-name",
    "size.player-name",
    "size.caption-height",
    "size.mark-height-left",
    "entry.height",
    "size.mark-height-right",
    "size.gender-height",
    "size.caption-weight",
    "size.mark-weight-left",
    "size.species-weight",
    "size.mark-weight-right",
    "size.gender-weight",
  },
  ["entry.forms"] = {
    "forms.title",
    "forms.header",
    "forms.selected",
    "forms.caption",
    "entry.species-name",
    "entry.dex-number",
    "forms.row-1",
    "forms.row-2",
    "forms.row-3",
    "forms.row-4",
    "forms.row-5",
    "forms.row-6",
  },
  ["entry.compare"] = {
    "forms.title",
    "forms.compare-header",
    "forms.compare-caption",
    "forms.compare-label-left",
    "forms.compare-label-right",
    "forms.compare-left",
    "forms.compare-right",
  },
  ["entry.return"] = { "return.title", "return.action" },
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
