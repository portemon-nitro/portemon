-- Producer-only source selectors for the HGSS Pokedex family: archive
-- paths, bounded member layouts, measurement/profile mapping, search and
-- area mask semantics, form policies, completion exclusions, height
-- correction selectors, and fixed text roles. Native identities stop here;
-- runtime game code never requires this module.

local PokedexSources = {}

PokedexSources.provenance = {
  decompRevision = "ctrl-cheeb-del/pokeheartgold@6d2947303134256e90144b6aaedc5c3cf6e92a568",
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

-- Per-screen native priority vectors: one dense BG0..BG3 assignment per
-- pane for every native page (MAIN feeds the controls pane, SUB the
-- information pane). SetupScreen installs one Set*BgPriorities assignment
-- per screen alongside its graphics loader: the list/cover/results family
-- keeps 2/0/1/3 + 0/1/2/3, the search editors install 1/0/2/3 + 0/1/2/3,
-- area installs 1/0/2/3 + 3/0/1/2 (the SUB BG0 area map stays behind the
-- SUB BG1 entry windows), size and return install 1/0/2/3 + 0/1/3/2,
-- forms and compare install 1/0/2/3 + 0/1/2/3, and the registration
-- popup runs the battle Main engine at 0/1/2/3. The SUB BG0 scroll plane
-- is 512 wide and area setup pans it to the settled region offsets
-- (-72 Johto, +104 Kanto), so the bound layer-0 composition stays the
-- full pannable map shifted by the published pan offset, never an
-- X=0-state foreground over the windows.
PokedexSources.pagePriorities = {
  cover = {
    controls = { [0] = 2, [1] = 0, [2] = 1, [3] = 3 },
    information = { [0] = 0, [1] = 1, [2] = 2, [3] = 3 },
  },
  grid = {
    controls = { [0] = 2, [1] = 0, [2] = 1, [3] = 3 },
    information = { [0] = 0, [1] = 1, [2] = 2, [3] = 3 },
  },
  results = {
    controls = { [0] = 2, [1] = 0, [2] = 1, [3] = 3 },
    information = { [0] = 0, [1] = 1, [2] = 2, [3] = 3 },
  },
  ["search.criteria"] = {
    controls = { [0] = 1, [1] = 0, [2] = 2, [3] = 3 },
    information = { [0] = 0, [1] = 1, [2] = 2, [3] = 3 },
  },
  ["search.order"] = {
    controls = { [0] = 1, [1] = 0, [2] = 2, [3] = 3 },
    information = { [0] = 0, [1] = 1, [2] = 2, [3] = 3 },
  },
  ["search.name"] = {
    controls = { [0] = 1, [1] = 0, [2] = 2, [3] = 3 },
    information = { [0] = 0, [1] = 1, [2] = 2, [3] = 3 },
  },
  ["search.type"] = {
    controls = { [0] = 1, [1] = 0, [2] = 2, [3] = 3 },
    information = { [0] = 0, [1] = 1, [2] = 2, [3] = 3 },
  },
  ["search.height"] = {
    controls = { [0] = 1, [1] = 0, [2] = 2, [3] = 3 },
    information = { [0] = 0, [1] = 1, [2] = 2, [3] = 3 },
  },
  ["search.weight"] = {
    controls = { [0] = 1, [1] = 0, [2] = 2, [3] = 3 },
    information = { [0] = 0, [1] = 1, [2] = 2, [3] = 3 },
  },
  ["search.area"] = {
    controls = { [0] = 1, [1] = 0, [2] = 2, [3] = 3 },
    information = { [0] = 0, [1] = 1, [2] = 2, [3] = 3 },
  },
  ["search.shape"] = {
    controls = { [0] = 1, [1] = 0, [2] = 2, [3] = 3 },
    information = { [0] = 0, [1] = 1, [2] = 2, [3] = 3 },
  },
  ["entry.area"] = {
    controls = { [0] = 1, [1] = 0, [2] = 2, [3] = 3 },
    information = { [0] = 3, [1] = 0, [2] = 1, [3] = 2 },
  },
  ["entry.size"] = {
    controls = { [0] = 1, [1] = 0, [2] = 2, [3] = 3 },
    information = { [0] = 0, [1] = 1, [2] = 3, [3] = 2 },
  },
  ["entry.forms"] = {
    controls = { [0] = 1, [1] = 0, [2] = 2, [3] = 3 },
    information = { [0] = 0, [1] = 1, [2] = 2, [3] = 3 },
  },
  ["entry.compare"] = {
    controls = { [0] = 1, [1] = 0, [2] = 2, [3] = 3 },
    information = { [0] = 0, [1] = 1, [2] = 2, [3] = 3 },
  },
  ["entry.return"] = {
    controls = { [0] = 1, [1] = 0, [2] = 2, [3] = 3 },
    information = { [0] = 0, [1] = 1, [2] = 3, [3] = 2 },
  },
  registration = {
    controls = { [0] = 0, [1] = 1, [2] = 2, [3] = 3 },
    information = { [0] = 0, [1] = 1, [2] = 2, [3] = 3 },
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
-- when the dump is not English; `screenEmpty` selects the empty slot
-- past the list length (NSCR 22). The runtime chooses among the bound
-- native/foreign/empty roles by selected language and list position.
-- `screenNational` stages the
-- national-mode area variant (NSCR 81) as a separately selectable image
-- while the default johto variant (NSCR 80) stays referenced.
-- `screenPatch` stages the single-observed-form replacement tilemap
-- (NSCR 100) beside the multi-form base art on the forms page.
local numberStripCells = {
  { screen = 10, x = 0, y = 0 },
  { screen = 10, x = 0, y = 5 },
  { screen = 10, x = 0, y = 10 },
  { screen = 10, x = 0, y = 15 },
  { screen = 10, x = 0, y = 20 },
}

---@param buttonCells table[] MAIN2 bottom-strip cells behind one list page
---@return table[] page layers binding the shared 512-wide scroll plane
local function listLayers(buttonCells)
  return {
    { pane = "controls", layer = 0, char = 1, screen = 0, palette = 2, scroll = "cover" },
    { pane = "controls", layer = 2, char = 4, palette = 2, cells = buttonCells },
    { pane = "controls", layer = 3, char = 3, palette = 2, cells = numberStripCells },
    { pane = "information", layer = 0, char = 17, screen = 16, palette = 18, scroll = "cover" },
    { pane = "information", layer = 3, char = 19, screen = 20, screenJapanese = 21, screenEmpty = 22, palette = 18 },
  }
end

local searchBaseLayers = {
  { pane = "controls", layer = 1, char = 4, palette = 2 },
  { pane = "controls", layer = 3, char = 3, palette = 2 },
  { pane = "information", layer = 2, char = 58, screen = 60, palette = 18 },
  { pane = "information", layer = 3, char = 58, screen = 59, palette = 18 },
}

---@param screenMember integer
---@return { pane: string, layer: integer, char: integer, screen: integer|nil, screenJapanese: integer|nil, screenNational: integer|nil, screenEmpty: integer|nil, screenPatch: integer|nil, palette: integer }[]
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
  cover = listLayers({ { screen = 5, x = 0, y = 19 } }),
  grid = listLayers({ { screen = 9, x = 0, y = 15 }, { screen = 6, x = 0, y = 19 } }),
  results = listLayers({ { screen = 9, x = 0, y = 15 }, { screen = 71, x = 0, y = 19 } }),
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
    { pane = "information", layer = 0, char = 87, screen = 86, palette = 18, scroll = "areaPan", mirrorUnlock = true },
    { pane = "information", layer = 3, char = 85, screen = 84, palette = 18 },
  },
  ["entry.size"] = {
    { pane = "controls", layer = 1, char = 4, palette = 2 },
    { pane = "controls", layer = 3, char = 90, screen = 89, palette = 2 },
    { pane = "information", layer = 2, char = 92, screen = 91, palette = 18 },
  },
  ["entry.forms"] = {
    { pane = "controls", layer = 0, char = 93, screen = 95, screenPatch = 100, palette = 2 },
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

-- Producer-only pressed-control flash patches: per-action tile-row
-- palette-bank mutations on one BG layer. Each record names the flash
-- action the controller publishes, the target pane/layer, the source
-- triple to re-render, the native tile rows to mutate with the flash
-- bank (tile IDs, flips, geometry and transparency preserved), and the
-- plane rect the renderer replaces while the flash is active. The
-- search bottom buttons flash the MAIN2 strip rows 19..23 from bank 0
-- to bank 6 (FlashBottomButton); unmapped actions keep their base art
-- with no overlay.
PokedexSources.pageFlashes = {
  ["search.criteria"] = {
    {
      action = "search-run",
      pane = "controls",
      layer = 2,
      char = 58,
      screen = 57,
      palette = 2,
      x = 88,
      y = 152,
      width = 80,
      height = 40,
      bankRows = { 19, 20, 21, 22, 23 },
      flashBank = 6,
    },
    {
      action = "search-reset",
      pane = "controls",
      layer = 2,
      char = 58,
      screen = 57,
      palette = 2,
      x = 0,
      y = 152,
      width = 80,
      height = 40,
      bankRows = { 19, 20, 21, 22, 23 },
      flashBank = 6,
    },
    {
      action = "search-back",
      pane = "controls",
      layer = 2,
      char = 58,
      screen = 57,
      palette = 2,
      x = 176,
      y = 152,
      width = 80,
      height = 40,
      bankRows = { 19, 20, 21, 22, 23 },
      flashBank = 6,
    },
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

local listTrack = {
  [5] = { x = 242, y = 76, pane = "controls" },
}
local searchTrack = { [14] = listTrack }

PokedexSources.spriteAnchors = {
  grid = searchTrack,
  results = searchTrack,
  ["search.criteria"] = searchTrack,
  ["search.order"] = searchTrack,
  ["search.name"] = searchTrack,
  ["search.type"] = searchTrack,
  ["search.height"] = searchTrack,
  ["search.weight"] = searchTrack,
  ["search.area"] = searchTrack,
  ["entry.area"] = {
    [14] = {
      [27] = { x = 32, y = 108, pane = "controls" },
      [64] = { x = 242, y = 96, pane = "controls" },
    },
  },
  ["entry.forms"] = {
    [14] = {
      [64] = { x = 242, y = 64, pane = "controls" },
    },
  },
  ["search.shape"] = {
    [74] = shapeAnchors,
    [14] = listTrack,
  },
  registration = {
    [31] = {
      [1] = { x = 112, y = 32, pane = "information" },
    },
  },
}

-- Producer-only per-type icon character files: the type icon character
-- member per internal type id with its palette bank in member 35
-- (sTypeIconCharFiles/sTypeIconPaletteNums in pokedex_rodata.s;
-- PokedexApp_GetTypeIconCharFile/PokedexApp_GetTypeIconPalette in
-- pokedex_text_util.c). Both list type icons and popup card icons draw
-- geometry from cells 33/animations 34 while the character payload
-- swaps per type. Member ids stop here and never reach the runtime.
PokedexSources.typeIconArt = {
  normal = { char = 36, paletteBank = 0 },
  fighting = { char = 42, paletteBank = 2 },
  flying = { char = 50, paletteBank = 0 },
  poison = { char = 46, paletteBank = 3 },
  ground = { char = 44, paletteBank = 1 },
  rock = { char = 41, paletteBank = 1 },
  bug = { char = 47, paletteBank = 3 },
  ghost = { char = 43, paletteBank = 2 },
  steel = { char = 45, paletteBank = 0 },
  fire = { char = 37, paletteBank = 2 },
  water = { char = 39, paletteBank = 2 },
  grass = { char = 38, paletteBank = 1 },
  electric = { char = 40, paletteBank = 1 },
  psychic = { char = 51, paletteBank = 1 },
  ice = { char = 49, paletteBank = 0 },
  dragon = { char = 52, paletteBank = 2 },
  dark = { char = 48, paletteBank = 3 },
}

-- Producer-only size-trainer character files: the gender-specific
-- trainer payload with its palette member
-- (PokedexApp_LoadSizeCheckResources in pokedex_size_check.c: male
-- members 105/108, female members 109/110; geometry stays cells 106
-- with animations 107 for both). Member ids stop here and never reach
-- the runtime.
PokedexSources.trainerArt = {
  male = { char = 105, palette = 108, standingChar = 111, standingCells = 112, standingAnims = 113 },
  female = { char = 109, palette = 110, standingChar = 114, standingCells = 112, standingAnims = 113 },
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
  [109] = 110,
  [111] = 108,
  [114] = 110,
  [115] = 118,
  [119] = 122,
}

-- Source sprite palette banks per page animation member. `default` is the
-- sequence bank, and numeric keys override individual sequences (the exact
-- `template->pal` / explicit `SetPaletteOverride` slot for that family).
PokedexSources.spriteBanks = {
  cover = {},
  grid = { [14] = { default = 1, [2] = 0, [4] = 4 } },
  results = { [14] = { default = 1, [2] = 0, [4] = 4 } },
  ["search.criteria"] = { [14] = { default = 0 } },
  ["search.order"] = { [14] = { default = 0 } },
  ["search.name"] = { [14] = { default = 0 } },
  ["search.type"] = { [14] = { default = 0 } },
  ["search.height"] = {
    [14] = { default = 0, [42] = 1, [43] = 1, [54] = 1, [56] = 1, [57] = 1, [59] = 1, [68] = 1, [69] = 1 },
  },
  ["search.weight"] = {
    [14] = { default = 0, [42] = 1, [43] = 1, [54] = 1, [56] = 1, [57] = 1, [59] = 1, [68] = 1, [69] = 1 },
  },
  ["search.area"] = { [14] = { default = 0 } },
  ["search.shape"] = { [14] = { default = 0 }, [74] = { default = 0 } },
  ["entry.area"] = {
    [14] = { default = 1, [4] = 4, [27] = 3, [28] = 0 },
    [117] = { default = 0 },
    [121] = { default = 0 },
  },
  ["entry.size"] = { [14] = { default = 1, [4] = 4 }, [113] = { default = 0 } },
  ["entry.forms"] = { [14] = { default = 1, [4] = 4, [67] = 0 } },
  ["entry.compare"] = { [14] = { default = 1, [4] = 4, [67] = 0 } },
  ["entry.return"] = { [14] = { default = 1, [4] = 4 } },
  registration = { [31] = { default = 0 }, [34] = { default = 0 }, [79] = { default = 0 } },
}

-- Source OBJ priority (the template's bgPriority) per page animation
-- member. Origin-anchored and live subjects use their own choice priority.
PokedexSources.spritePriorities = {
  cover = {},
  grid = { [14] = { default = 3, [24] = 0, [25] = 0, [26] = 0 } },
  results = { [14] = { default = 3, [24] = 0, [25] = 0, [26] = 0 } },
  ["search.criteria"] = { [14] = { default = 0 }, [25] = { default = 3 }, [74] = { default = 0 } },
  ["search.order"] = { [14] = { default = 0 }, [25] = { default = 3 } },
  ["search.name"] = { [14] = { default = 0 }, [25] = { default = 3 } },
  ["search.type"] = { [14] = { default = 0 }, [25] = { default = 3 } },
  ["search.height"] = { [14] = { default = 0 }, [25] = { default = 3 } },
  ["search.weight"] = { [14] = { default = 0 }, [25] = { default = 3 } },
  ["search.area"] = { [14] = { default = 0 }, [25] = { default = 3 } },
  ["search.shape"] = { [14] = { default = 0 }, [25] = { default = 3 }, [74] = { default = 0 } },
  ["entry.area"] = { [14] = { default = 0 }, [117] = { default = 3 }, [121] = { default = 3 } },
  ["entry.size"] = { [14] = { default = 1, [4] = 0 }, [113] = { default = 1 } },
  ["entry.forms"] = { [14] = { default = 0 } },
  ["entry.compare"] = { [14] = { default = 0 } },
  ["entry.return"] = { [14] = { default = 0 } },
  registration = { [31] = { default = 0 }, [34] = { default = 0 }, [79] = { default = 0 } },
}

---@param spec table<integer|string, integer>? bank or priority specification
---@param sequence integer one-based sequence
---@return integer bank or priority
function PokedexSources.spriteSpecValue(spec, sequence)
  if type(spec) ~= "table" then
    return 0
  end
  local value = spec[sequence]
  if type(value) == "number" then
    return value
  end
  return type(spec.default) == "number" and spec.default or 0
end

-- Runtime dex-mode label cells: MAIN0 char member 1 with NSCR 7 (JOHTO)
-- or NSCR 8 (NATIONAL), a 22x4 cell block drawn at tile (5,3) = (40,24).
PokedexSources.dexModeLabel = {
  johto = { char = 1, screen = 7, palette = 2 },
  national = { char = 1, screen = 8, palette = 2 },
  x = 40,
  y = 24,
  -- Locked national mode erases the switch row of the scroll plane before
  -- the label cell is drawn: `PokedexApp_LoadListGraphics` fills the
  -- MAIN0 tilemap rect at tile (3,15) size 26x2 with tile 0x16 keeping
  -- each cell's palette bits, and `SetupListSprites` hides the switch
  -- sprite. The compiled patch reproduces that fill from the same char
  -- member and scroll map.
  locked = {
    char = 1,
    screen = 0,
    palette = 2,
    tile = 0x16,
    tileX = 3,
    tileY = 15,
    tilesWide = 26,
    tilesHigh = 2,
  },
}

-- Runtime dex-number glyphs from MAIN3 char member 3 with palette member 2,
-- palette bank 1: caught digits start at tile 3, seen digits at tile 14,
-- and the caught marker is tile 2 (PokedexApp_3DigitNumToTiles ORs the
-- 0x1000 palette bit).
PokedexSources.numberAtlas = {
  char = 3,
  palette = 2,
  bank = 1,
  caughtBase = 3,
  seenBase = 14,
  marker = 2,
  digits = 10,
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
  unknown = 0x01,
  johto = 0x02,
  kanto = 0x04,
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
-- persists caught variants. Spinda is an ordinary gender-row species in
-- the forms screen (pokedex_screen_setup.c has no Spinda form case) but
-- still persists its first personality for its generated spot picture.
-- Pichu carries three fixed gender/form variants; additional forms use
-- ID = form + 1 so unrelated additions never renumber saved variants.
PokedexSources.orderedPolicies = {
  UNOWN = { capacity = 28, rememberCaughtVariants = true },
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

-- Native automatic families expose every declared variant unconditionally
-- (pokedex_screen_setup.c hard-codes Castform = 4 rows, Cherrim = 2) and
-- persist no automatic form history.
PokedexSources.automaticFamilies = { CASTFORM = 4, CHERRIM = 2 }

-- Spinda has no form list in the source forms screen but persists the first
-- personality behind its generated spot picture.
PokedexSources.personalityFamilies = { SPINDA = true }

-- Fixed Pichu gender/form variants: normal male, normal female, then the
-- spiky-eared form, which is always female. Additional forms use
-- ID = form + 1.
PokedexSources.pichuVariants = {
  { id = 0, form = 0, gender = "male" },
  { id = 1, form = 0, gender = "female" },
  { id = 2, form = 1, gender = "female" },
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
    -- The registration card's own banner text (bank 802 entry 144,
    -- "Pokédex registration completed."); the entry popup prints it
    -- verbatim and no battle/trainer message supplies it.
    registrationHeader = { bankId = 802, messageId = 144 },
    -- The battle line printed before the card (bank 197 entry 871,
    -- "{name}'s data was added to the Pokédex.").
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
  -- Height/weight summary templates behind the search editor: bank-802
  -- entries 175 (height, feet and two-digit inches) and 38 (weight,
  -- integer pounds and tenths), expanded with STRVAR fields 0 and 1.
  local measureTemplates = { height = 175, weight = 38 }
  return {
    criteria = { order = 26, letter = 27, type = 28, height = 29, weight = 30, area = 31, shape = 32 },
    orders = { numerical = 41, alphabetical = 42, heaviest = 43, lightest = 44, tallest = 45, shortest = 46 },
    letters = letters,
    types = types,
    areas = { johto = 65, kanto = 66, unknown = 67, unrestricted = 68 },
    buttons = { run = 36, reset = 35, back = 37 },
    editorButtons = { ok = 39, cancel = 40 },
    measureTemplates = measureTemplates,
    timeBase = 129,
    returnCancel = 173,
    returnAction = 174,
    -- List/result captions and count marks (bank 802 entries 0/1/8/10/11)
    -- and the two-line search help window (`PokedexApp_DrawSearchMessage`):
    -- line 1 names the mode or the result page, line 2 the active page's
    -- instruction, the searching label, or the empty-result notice.
    list = { seen = 0, caught = 1, info = 8, heightMark = 10, weightMark = 11 },
    help = {
      title = 12,
      criteria = 13,
      resultsTitle = 14,
      resultsCount = 15,
      order = 16,
      name = 17,
      type = 18,
      height = 20,
      weight = 19,
      area = 22,
      shape = 21,
      searching = 25,
      noResultsTitle = 23,
      noResultsDetail = 24,
    },
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
    banks[#banks + 1] = bindings.registrationHeader.bankId
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
-- Every window carries its source-resolved ink triple: the NCLR palette
-- member behind its native engine (member 2 for MAIN-engine prints,
-- member 18 for SUB-engine prints and the popup Main card, which loads
-- member 18 into its Main palette), the template palette bank, and the
-- MAKE_TEXT_COLOR foreground/shadow indices from the print call that
-- paints it (pokedex_windows.c, pokedex_entry_popup.c). The member follows
-- the native engine, not the projected pane: the size weight caption
-- prints on MAIN but projects to the information pane. The compiler
-- resolves each triple through its decoded NCLR palette; no window
-- carries a default color. The compact inspector entries are
-- host-adapted (no native window paints them) and carry an explicit
-- deliberate white/black triple instead.

---@param pane string
---@param layer integer
---@param x integer
---@param y integer
---@param width integer
---@param height integer
---@param font integer
---@param align string
---@param paletteSlot integer
---@param printX integer? native local print origin x (defaults to the alignment anchor)
---@param printY integer? native local print origin y (defaults to 0)
---@param lineAdvance integer? native line step (defaults to 16)
---@param textRole string? prepared message role behind the window (defaults to the window key)
---@param ink { member: integer, bank: integer, fg: integer, sh: integer } source-resolved NCLR bank and print color indices (required, no default)
---@return { pane: string, layer: integer, x: integer, y: integer, width: integer, height: integer, font: integer, ink: { member: integer, bank: integer, fg: integer, sh: integer }, background: { r: integer, g: integer, b: integer, a: integer }, align: string, paletteGroup: string, printX: integer, printY: integer, lineAdvance: integer, textRole: string? }
local function dexWindow(
  pane,
  layer,
  x,
  y,
  width,
  height,
  font,
  align,
  paletteSlot,
  printX,
  printY,
  lineAdvance,
  textRole,
  ink
)
  assert(type(ink) == "table", "pokedex windows carry their source ink triple")
  assert(
    type(ink.member) == "number" and ink.member % 1 == 0 and (ink.member == 2 or ink.member == 18),
    "pokedex ink names its engine NCLR member"
  )
  assert(
    type(ink.bank) == "number" and ink.bank % 1 == 0 and ink.bank >= 0 and ink.bank <= 15,
    "pokedex ink names its template palette bank"
  )
  assert(
    type(ink.fg) == "number" and ink.fg % 1 == 0 and ink.fg >= 0 and ink.fg <= 15,
    "pokedex ink names its print foreground index"
  )
  assert(
    type(ink.sh) == "number" and ink.sh % 1 == 0 and ink.sh >= 0 and ink.sh <= 15,
    "pokedex ink names its print shadow index"
  )
  local originX = printX
  if originX == nil then
    if align == "right" then
      originX = width
    elseif align == "center" then
      originX = math.floor(width / 2)
    else
      originX = 0
    end
  end
  return {
    pane = pane,
    layer = layer,
    x = x,
    y = y,
    width = width,
    height = height,
    font = font,
    ink = { member = ink.member, bank = ink.bank, fg = ink.fg, sh = ink.sh },
    background = { r = 0, g = 0, b = 0, a = 0 },
    align = align,
    paletteGroup = "window-" .. paletteSlot,
    printX = originX,
    printY = printY or 0,
    lineAdvance = lineAdvance or 16,
    textRole = textRole,
  }
end

PokedexSources.windows = {
  ["grid.seen-caption"] = dexWindow("controls", 0, 16, 72, 96, 16, 0, "right", 0, nil, nil, nil, nil, { member = 2, bank = 9, fg = 15, sh = 8 }),
  ["grid.caught-caption"] = dexWindow("controls", 0, 144, 72, 96, 16, 0, "right", 0, nil, nil, nil, nil, { member = 2, bank = 9, fg = 15, sh = 8 }),
  ["grid.seen-count"] = dexWindow("controls", 0, 88, 92, 24, 16, 0, "left", 9, nil, nil, nil, nil, { member = 2, bank = 9, fg = 15, sh = 8 }),
  ["grid.caught-count"] = dexWindow("controls", 0, 216, 92, 24, 16, 0, "left", 9, nil, nil, nil, nil, { member = 2, bank = 9, fg = 15, sh = 8 }),
  ["grid.selected-number"] = dexWindow("information", 1, 121, 24, 31, 16, 4, "left", 0, nil, nil, nil, nil, { member = 18, bank = 0, fg = 2, sh = 1 }),
  ["grid.selected-name"] = dexWindow("information", 1, 152, 24, 72, 16, 4, "left", 0, nil, nil, nil, nil, { member = 18, bank = 0, fg = 2, sh = 1 }),
  ["grid.info-label"] = dexWindow("information", 1, 16, 0, 64, 16, 4, "left", 2, nil, nil, nil, nil, { member = 18, bank = 2, fg = 2, sh = 1 }),
  ["grid.category"] = dexWindow("information", 1, 104, 40, 140, 16, 4, "right", 0, nil, nil, nil, nil, { member = 18, bank = 0, fg = 2, sh = 1 }),
  ["grid.flavor"] = dexWindow("information", 1, 16, 136, 224, 48, 0, "center", 1, nil, nil, nil, nil, { member = 18, bank = 1, fg = 2, sh = 1 }),
  ["grid.height-mark"] = dexWindow("information", 1, 144, 88, 40, 16, 0, "center", 2, nil, nil, nil, nil, { member = 18, bank = 1, fg = 2, sh = 1 }),
  ["grid.height"] = dexWindow("information", 1, 188, 88, 64, 16, 0, "left", 2, nil, nil, nil, nil, { member = 18, bank = 1, fg = 2, sh = 1 }),
  ["grid.weight-mark"] = dexWindow("information", 1, 144, 104, 40, 16, 0, "center", 2, nil, nil, nil, nil, { member = 18, bank = 1, fg = 2, sh = 1 }),
  ["grid.weight"] = dexWindow("information", 1, 188, 104, 64, 16, 0, "left", 2, nil, nil, nil, nil, { member = 18, bank = 1, fg = 2, sh = 1 }),
  ["grid.name-bar"] = dexWindow("controls", 1, 80, 128, 88, 16, 0, "center", 0, nil, nil, nil, nil, { member = 2, bank = 0, fg = 2, sh = 1 }),
  ["entry.species-name"] = dexWindow("information", 1, 0, 128, 72, 16, 0, "center", 1, nil, nil, nil, nil, { member = 18, bank = 1, fg = 2, sh = 1 }),
  ["entry.dex-number"] = dexWindow("information", 1, 121, 24, 31, 16, 4, "left", 0, nil, nil, nil, nil, { member = 18, bank = 0, fg = 2, sh = 1 }),
  ["entry.category"] = dexWindow("information", 1, 104, 40, 140, 16, 4, "right", 0, nil, nil, nil, nil, { member = 18, bank = 0, fg = 2, sh = 1 }),
  ["entry.flavor"] = dexWindow("information", 1, 16, 136, 224, 48, 0, "center", 1, nil, nil, nil, nil, { member = 18, bank = 1, fg = 2, sh = 1 }),
  ["entry.height"] = dexWindow("information", 1, 56, 168, 64, 16, 0, "center", 2, nil, nil, nil, nil, { member = 18, bank = 2, fg = 2, sh = 1 }),
  -- Compact-inspector-only weight slot (host-adapted; no native list
  -- window uses this rect, and no native page list paints it). The ink
  -- is deliberate host-adapted white over black, not a native print.
  ["entry.weight"] = dexWindow("controls", 1, 56, 184, 64, 16, 0, "center", 1, nil, nil, nil, nil, { member = 2, bank = 1, fg = 15, sh = 2 }),
  ["search.criteria"] = dexWindow("controls", 0, 128, 8, 88, 16, 4, "center", 2, nil, nil, nil, nil, { member = 2, bank = 2, fg = 2, sh = 1 }),
  ["search.feedback"] = dexWindow("information", 1, 16, 158, 224, 16, 0, "center", 2, nil, nil, nil, nil, { member = 18, bank = 2, fg = 2, sh = 1 }),
  ["search.feedback-detail"] = dexWindow("information", 1, 16, 174, 224, 16, 0, "center", 2, nil, nil, nil, nil, { member = 18, bank = 2, fg = 2, sh = 1 }),
  ["search.results"] = dexWindow("information", 1, 16, 0, 64, 16, 4, "left", 2, nil, nil, nil, nil, { member = 18, bank = 2, fg = 2, sh = 1 }),
  ["area.time"] = dexWindow("information", 1, 8, 24, 56, 16, 0, "center", 1, nil, nil, nil, nil, { member = 18, bank = 1, fg = 2, sh = 1 }),
  ["area.location"] = dexWindow("controls", 2, 80, 40, 144, 16, 4, "center", 1, nil, nil, nil, nil, { member = 2, bank = 1, fg = 15, sh = 12 }),
  ["size.title"] = dexWindow("information", 1, 16, 0, 72, 16, 4, "left", 2, nil, nil, nil, nil, { member = 18, bank = 2, fg = 2, sh = 1 }),
  ["forms.selected"] = dexWindow("information", 1, 104, 40, 120, 16, 0, "center", 1, nil, nil, nil, nil, { member = 18, bank = 1, fg = 2, sh = 1 }),
  ["forms.compare-left"] = dexWindow("controls", 1, 0, 96, 128, 16, 0, "center", 1, nil, nil, nil, nil, { member = 2, bank = 1, fg = 5, sh = 9 }),
  ["forms.compare-right"] = dexWindow("controls", 1, 128, 96, 128, 16, 0, "center", 1, nil, nil, nil, nil, { member = 2, bank = 1, fg = 5, sh = 9 }),
  ["return.title"] = dexWindow("information", 1, 16, 0, 72, 16, 4, "left", 2, nil, nil, nil, nil, { member = 18, bank = 2, fg = 2, sh = 1 }),
  -- Registration popup windows transcribed from the native popup window
  -- templates and print calls (sEntryPopupWindowTemplates,
  -- pokedex_entry_popup.c): the header centers on local x 112 in bank 2,
  -- number/name/category print from bank 0, the flavor block centers on
  -- its widest line in bank 1, marks center on local x 20 and values print
  -- at local x 4 in bank 1.
  ["registration.header"] = dexWindow(
    "information",
    1,
    16,
    0,
    224,
    16,
    4,
    "center",
    2,
    112,
    0,
    16,
    "registration.header",
    { member = 18, bank = 2, fg = 2, sh = 1 }
  ),
  ["registration.dex-number"] = dexWindow(
    "information",
    1,
    120,
    24,
    32,
    16,
    4,
    "left",
    0,
    1,
    0,
    16,
    "registration.dex-number",
    { member = 18, bank = 0, fg = 2, sh = 1 }
  ),
  ["registration.species-name"] = dexWindow(
    "information",
    1,
    152,
    24,
    72,
    16,
    4,
    "left",
    0,
    0,
    0,
    16,
    "registration.species-name",
    { member = 18, bank = 0, fg = 2, sh = 1 }
  ),
  ["registration.category"] = dexWindow(
    "information",
    1,
    104,
    40,
    144,
    16,
    4,
    "right",
    0,
    140,
    0,
    16,
    "registration.category",
    { member = 18, bank = 0, fg = 2, sh = 1 }
  ),
  ["registration.flavor"] = dexWindow(
    "information",
    1,
    16,
    136,
    224,
    48,
    0,
    "block-center",
    1,
    0,
    0,
    16,
    "registration.flavor",
    { member = 18, bank = 1, fg = 2, sh = 1 }
  ),
  ["registration.mark-height"] = dexWindow(
    "information",
    1,
    144,
    88,
    40,
    16,
    0,
    "center",
    1,
    20,
    0,
    16,
    "registration.mark-height",
    { member = 18, bank = 1, fg = 2, sh = 1 }
  ),
  ["registration.height"] = dexWindow(
    "information",
    1,
    184,
    88,
    64,
    16,
    0,
    "left",
    1,
    4,
    0,
    16,
    "registration.height",
    { member = 18, bank = 1, fg = 2, sh = 1 }
  ),
  ["registration.mark-weight"] = dexWindow(
    "information",
    1,
    144,
    104,
    40,
    16,
    0,
    "center",
    1,
    20,
    0,
    16,
    "registration.mark-weight",
    { member = 18, bank = 1, fg = 2, sh = 1 }
  ),
  ["registration.weight"] = dexWindow(
    "information",
    1,
    184,
    104,
    64,
    16,
    0,
    "left",
    1,
    4,
    0,
    16,
    "registration.weight",
    { member = 18, bank = 1, fg = 2, sh = 1 }
  ),
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
-- palette slots (`MAKE_TEXT_COLOR` fg/sh/bg); every record below carries
-- its source-resolved (bank, fg, sh) triple, and the compiler resolves
-- each triple through the decoded NCLR palette. Menu labels/values and
-- the return-slot summary share tile geometry on
-- different panes (MAIN vs SUB), so captions/values exist twice: once
-- for the menu rects, once for the summary rects.
do
  -- Menu labels (search templates 20-26, MAIN BG0; prints font 0,
  -- color (2,1,0), centered on the print x).
  PokedexSources.windows["search.caption-order"] = dexWindow("controls", 0, 32, 8, 72, 16, 0, "center", 2, nil, nil, nil, nil, { member = 2, bank = 2, fg = 2, sh = 1 })
  PokedexSources.windows["search.caption-letter"] = dexWindow("controls", 0, 8, 32, 40, 16, 0, "center", 2, nil, nil, nil, nil, { member = 2, bank = 2, fg = 2, sh = 1 })
  PokedexSources.windows["search.caption-type"] = dexWindow("controls", 0, 8, 56, 40, 16, 0, "center", 2, nil, nil, nil, nil, { member = 2, bank = 2, fg = 2, sh = 1 })
  PokedexSources.windows["search.caption-height"] = dexWindow("controls", 0, 8, 80, 40, 16, 0, "center", 2, nil, nil, nil, nil, { member = 2, bank = 2, fg = 2, sh = 1 })
  PokedexSources.windows["search.caption-weight"] = dexWindow("controls", 0, 8, 104, 40, 16, 0, "center", 2, nil, nil, nil, nil, { member = 2, bank = 2, fg = 2, sh = 1 })
  PokedexSources.windows["search.caption-area"] = dexWindow("controls", 0, 8, 128, 40, 16, 0, "center", 2, nil, nil, nil, nil, { member = 2, bank = 2, fg = 2, sh = 1 })
  PokedexSources.windows["search.caption-shape"] = dexWindow("controls", 0, 200, 32, 48, 16, 0, "center", 2, nil, nil, nil, nil, { member = 2, bank = 2, fg = 2, sh = 1 })
  -- Menu values (templates 27-35; order/letter/height/weight/area print
  -- centered in font 4, types print at x=29 in font 4).
  PokedexSources.windows["search.value-order"] = dexWindow("controls", 0, 128, 8, 88, 16, 4, "center", 2, nil, nil, nil, nil, { member = 2, bank = 2, fg = 2, sh = 1 })
  PokedexSources.windows["search.value-letter"] = dexWindow("controls", 0, 56, 32, 72, 16, 4, "center", 2, nil, nil, nil, nil, { member = 2, bank = 2, fg = 2, sh = 1 })
  PokedexSources.windows["search.value-type-1"] = dexWindow("controls", 0, 56, 56, 58, 16, 4, "center", 2, nil, nil, nil, nil, { member = 2, bank = 2, fg = 2, sh = 1 })
  PokedexSources.windows["search.value-type-2"] = dexWindow("controls", 0, 120, 56, 58, 16, 4, "center", 2, nil, nil, nil, nil, { member = 2, bank = 2, fg = 2, sh = 1 })
  PokedexSources.windows["search.value-height-min"] = dexWindow("controls", 0, 56, 80, 48, 16, 4, "center", 2, nil, nil, nil, nil, { member = 2, bank = 2, fg = 2, sh = 1 })
  PokedexSources.windows["search.value-height-max"] = dexWindow("controls", 0, 120, 80, 48, 16, 4, "center", 2, nil, nil, nil, nil, { member = 2, bank = 2, fg = 2, sh = 1 })
  PokedexSources.windows["search.value-weight-min"] = dexWindow("controls", 0, 56, 104, 72, 16, 4, "center", 2, nil, nil, nil, nil, { member = 2, bank = 2, fg = 2, sh = 1 })
  PokedexSources.windows["search.value-weight-max"] = dexWindow("controls", 0, 144, 104, 72, 16, 4, "center", 2, nil, nil, nil, nil, { member = 2, bank = 2, fg = 2, sh = 1 })
  PokedexSources.windows["search.value-area"] = dexWindow("controls", 0, 56, 128, 56, 16, 4, "center", 2, nil, nil, nil, nil, { member = 2, bank = 2, fg = 2, sh = 1 })
  -- Menu and editor commit buttons (templates 17-19, MAIN BG1, palette
  -- slot 4; labels centered in font 4 over the 8-tile button frame).
  PokedexSources.windows["search.button-run"] = dexWindow("controls", 1, 8, 8, 64, 16, 4, "center", 4, nil, nil, nil, nil, { member = 2, bank = 4, fg = 2, sh = 1 })
  PokedexSources.windows["search.button-reset"] = dexWindow("controls", 1, 96, 8, 64, 16, 4, "center", 4, nil, nil, nil, nil, { member = 2, bank = 4, fg = 2, sh = 1 })
  PokedexSources.windows["search.button-back"] = dexWindow("controls", 1, 184, 8, 64, 16, 4, "center", 4, nil, nil, nil, nil, { member = 2, bank = 4, fg = 2, sh = 1 })
  PokedexSources.windows["search.button-ok"] = dexWindow("controls", 1, 8, 8, 64, 16, 4, "center", 4, nil, nil, nil, nil, { member = 2, bank = 4, fg = 2, sh = 1 })
  PokedexSources.windows["search.button-cancel"] = dexWindow("controls", 1, 184, 8, 64, 16, 4, "center", 4, nil, nil, nil, nil, { member = 2, bank = 4, fg = 2, sh = 1 })
  -- Return-slot summary captions (templates 1-7, SUB BG1; same tiles as
  -- the menu labels, same font 0 centered prints).
  PokedexSources.windows["search.summary-caption-order"] = dexWindow("information", 1, 32, 8, 72, 16, 0, "center", 2, nil, nil, nil, nil, { member = 18, bank = 2, fg = 2, sh = 1 })
  PokedexSources.windows["search.summary-caption-letter"] = dexWindow("information", 1, 8, 32, 40, 16, 0, "center", 2, nil, nil, nil, nil, { member = 18, bank = 2, fg = 2, sh = 1 })
  PokedexSources.windows["search.summary-caption-type"] = dexWindow("information", 1, 8, 56, 40, 16, 0, "center", 2, nil, nil, nil, nil, { member = 18, bank = 2, fg = 2, sh = 1 })
  PokedexSources.windows["search.summary-caption-height"] = dexWindow("information", 1, 8, 80, 40, 16, 0, "center", 2, nil, nil, nil, nil, { member = 18, bank = 2, fg = 2, sh = 1 })
  PokedexSources.windows["search.summary-caption-weight"] = dexWindow("information", 1, 8, 104, 40, 16, 0, "center", 2, nil, nil, nil, nil, { member = 18, bank = 2, fg = 2, sh = 1 })
  PokedexSources.windows["search.summary-caption-area"] = dexWindow("information", 1, 8, 128, 40, 16, 0, "center", 2, nil, nil, nil, nil, { member = 18, bank = 2, fg = 2, sh = 1 })
  PokedexSources.windows["search.summary-caption-shape"] = dexWindow("information", 1, 200, 32, 48, 16, 0, "center", 2, nil, nil, nil, nil, { member = 18, bank = 2, fg = 2, sh = 1 })
  -- Return-slot summary values (templates 8-16; same content as the
  -- menu values, SUB BG1 rects).
  PokedexSources.windows["search.summary-value-order"] = dexWindow("information", 1, 128, 8, 88, 16, 4, "center", 2, nil, nil, nil, nil, { member = 18, bank = 2, fg = 2, sh = 1 })
  PokedexSources.windows["search.summary-value-letter"] = dexWindow("information", 1, 56, 32, 72, 16, 4, "center", 2, nil, nil, nil, nil, { member = 18, bank = 2, fg = 2, sh = 1 })
  PokedexSources.windows["search.summary-value-type-1"] = dexWindow("information", 1, 56, 56, 58, 16, 4, "center", 2, nil, nil, nil, nil, { member = 18, bank = 2, fg = 2, sh = 1 })
  PokedexSources.windows["search.summary-value-type-2"] = dexWindow("information", 1, 120, 56, 58, 16, 4, "center", 2, nil, nil, nil, nil, { member = 18, bank = 2, fg = 2, sh = 1 })
  PokedexSources.windows["search.summary-value-height-min"] =
    dexWindow("information", 1, 56, 80, 48, 16, 4, "center", 2, nil, nil, nil, nil, { member = 18, bank = 2, fg = 2, sh = 1 })
  PokedexSources.windows["search.summary-value-height-max"] =
    dexWindow("information", 1, 120, 80, 48, 16, 4, "center", 2, nil, nil, nil, nil, { member = 18, bank = 2, fg = 2, sh = 1 })
  PokedexSources.windows["search.summary-value-weight-min"] =
    dexWindow("information", 1, 56, 104, 72, 16, 4, "center", 2, nil, nil, nil, nil, { member = 18, bank = 2, fg = 2, sh = 1 })
  PokedexSources.windows["search.summary-value-weight-max"] =
    dexWindow("information", 1, 144, 104, 72, 16, 4, "center", 2, nil, nil, nil, nil, { member = 18, bank = 2, fg = 2, sh = 1 })
  PokedexSources.windows["search.summary-value-area"] = dexWindow("information", 1, 56, 128, 56, 16, 4, "center", 2, nil, nil, nil, nil, { member = 18, bank = 2, fg = 2, sh = 1 })
  -- Order editor: title 36, current value 37, six options 38-43.
  PokedexSources.windows["search.title-order"] = dexWindow("controls", 0, 24, 8, 88, 16, 0, "center", 2, nil, nil, nil, nil, { member = 2, bank = 2, fg = 2, sh = 1 })
  PokedexSources.windows["search.current-order"] = dexWindow("controls", 0, 144, 8, 88, 16, 4, "center", 2, nil, nil, nil, nil, { member = 2, bank = 2, fg = 2, sh = 1 })
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
      dexWindow("controls", 0, rect[1], rect[2], 88, 16, 4, "center", 2, nil, nil, nil, nil, { member = 2, bank = 2, fg = 2, sh = 1 })
  end
  -- Letter editor: title 65, current value 66, and the 27 marks sharing
  -- window 67 (origin (8,40)). Each mark prints at column*32+24,
  -- row*32 in font 4 centered, where column/row come from
  -- sLetterGridCells (identity except the empty mark at cell 27); the
  -- logical cell (24+column*32, 40+row*32, 16, 16) matches both the
  -- print center and the 2x2-tile highlight rect.
  PokedexSources.windows["search.title-letter"] = dexWindow("controls", 0, 56, 8, 48, 16, 0, "center", 2, nil, nil, nil, nil, { member = 2, bank = 2, fg = 2, sh = 1 })
  PokedexSources.windows["search.current-letter"] = dexWindow("controls", 0, 120, 8, 72, 16, 4, "center", 2, nil, nil, nil, nil, { member = 2, bank = 2, fg = 2, sh = 1 })
  for position = 0, 26 do
    local label = position < 26 and string.char(string.byte("A") + position) or "unrestricted"
    local cell = position < 26 and position or 27
    local column, row = cell % 7, math.floor(cell / 7)
    PokedexSources.windows["search.option-letter-" .. label] =
      dexWindow("controls", 0, 24 + column * 32, 40 + row * 32, 16, 16, 4, "center", 2, nil, nil, nil, nil, { member = 2, bank = 2, fg = 2, sh = 1 })
  end
  -- Type editor: title 44, current values 45-46, and the 18 marks in a
  -- 4-column grid (windows 47-64 in `typeOrder` sequence with the empty
  -- mark last, per `sSearchTypeMsgIds`).
  PokedexSources.windows["search.title-type"] = dexWindow("controls", 0, 24, 8, 56, 16, 0, "center", 2, nil, nil, nil, nil, { member = 2, bank = 2, fg = 2, sh = 1 })
  PokedexSources.windows["search.current-type-1"] = dexWindow("controls", 0, 104, 8, 58, 16, 4, "center", 2, nil, nil, nil, nil, { member = 2, bank = 2, fg = 2, sh = 1 })
  PokedexSources.windows["search.current-type-2"] = dexWindow("controls", 0, 168, 8, 70, 16, 4, "center", 2, nil, nil, nil, nil, { member = 2, bank = 2, fg = 2, sh = 1 })
  for index, name in ipairs(PokedexSources.typeOrder) do
    local column, row = (index - 1) % 4, math.floor((index - 1) / 4)
    PokedexSources.windows["search.option-type-" .. name] =
      dexWindow("controls", 0, column * 64, 40 + row * 24, 64, 16, 4, "center", 2, nil, nil, nil, nil, { member = 2, bank = 2, fg = 2, sh = 1 })
  end
  PokedexSources.windows["search.option-type-unrestricted"] = dexWindow("controls", 0, 64, 136, 64, 16, 4, "center", 2, nil, nil, nil, nil, { member = 2, bank = 2, fg = 2, sh = 1 })
  -- Height/weight editors: titles 68/71 plus the staged min/max bounds
  -- (69-70, 72-73; the native integer slider values).
  PokedexSources.windows["search.title-height"] = dexWindow("controls", 0, 24, 8, 40, 16, 0, "center", 2, nil, nil, nil, nil, { member = 2, bank = 2, fg = 2, sh = 1 })
  PokedexSources.windows["search.current-height-min"] = dexWindow("controls", 0, 80, 8, 56, 16, 4, "center", 2, nil, nil, nil, nil, { member = 2, bank = 2, fg = 2, sh = 1 })
  PokedexSources.windows["search.current-height-max"] = dexWindow("controls", 0, 152, 8, 56, 16, 4, "center", 2, nil, nil, nil, nil, { member = 2, bank = 2, fg = 2, sh = 1 })
  PokedexSources.windows["search.title-weight"] = dexWindow("controls", 0, 8, 8, 48, 16, 0, "center", 2, nil, nil, nil, nil, { member = 2, bank = 2, fg = 2, sh = 1 })
  PokedexSources.windows["search.current-weight-min"] = dexWindow("controls", 0, 64, 8, 72, 16, 4, "center", 2, nil, nil, nil, nil, { member = 2, bank = 2, fg = 2, sh = 1 })
  PokedexSources.windows["search.current-weight-max"] = dexWindow("controls", 0, 152, 8, 72, 16, 4, "center", 2, nil, nil, nil, nil, { member = 2, bank = 2, fg = 2, sh = 1 })
  -- Area editor: title 74, staged value 75, four scopes 76-79.
  PokedexSources.windows["search.title-area"] = dexWindow("controls", 0, 56, 8, 48, 16, 0, "center", 2, nil, nil, nil, nil, { member = 2, bank = 2, fg = 2, sh = 1 })
  PokedexSources.windows["search.current-area"] = dexWindow("controls", 0, 128, 8, 56, 16, 4, "center", 2, nil, nil, nil, nil, { member = 2, bank = 2, fg = 2, sh = 1 })
  local areaEditorNames = { "johto", "kanto", "unknown", "unrestricted" }
  local areaEditorRects = { { 48, 64 }, { 152, 64 }, { 48, 120 }, { 152, 120 } }
  for index, name in ipairs(areaEditorNames) do
    local rect = areaEditorRects[index]
    PokedexSources.windows["search.option-area-" .. name] =
      dexWindow("controls", 0, rect[1], rect[2], 56, 16, 4, "center", 2, nil, nil, nil, nil, { member = 2, bank = 2, fg = 2, sh = 1 })
  end
  -- Shape editor: the title window 80 only; the 14 silhouettes are OBJ
  -- art (see `spriteAnchors`) and the source prints no option labels.
  PokedexSources.windows["search.title-shape"] = dexWindow("controls", 0, 64, 8, 48, 24, 0, "center", 2, nil, nil, nil, nil, { member = 2, bank = 2, fg = 2, sh = 1 })
  -- Area screen: title 0 (msg 142), daypart 1, unknown banner 3
  -- (msg 128, shown when the list holds only the region entry), caption
  -- 4 (msg 132), region tabs (5/7 national, 6 solo), rows 8-13.
  -- `area.time` and `area.location` keep their oracle records above;
  -- `area.location` is the first visible row window.
  PokedexSources.windows["area.title"] = dexWindow("information", 1, 16, 0, 72, 16, 4, "left", 2, nil, nil, nil, nil, { member = 18, bank = 2, fg = 2, sh = 1 })
  PokedexSources.windows["area.unknown"] = dexWindow("information", 1, 104, 96, 112, 16, 0, "center", 2, nil, nil, nil, nil, { member = 18, bank = 1, fg = 2, sh = 1 })
  PokedexSources.windows["area.caption"] = dexWindow("controls", 1, 8, 40, 48, 16, 0, "center", 1, nil, nil, nil, nil, { member = 2, bank = 1, fg = 5, sh = 9 })
  PokedexSources.windows["area.tab-johto"] = dexWindow("controls", 1, 72, 8, 56, 16, 4, "center", 1, nil, nil, nil, nil, { member = 2, bank = 1, fg = 15, sh = 12 })
  PokedexSources.windows["area.tab-kanto"] = dexWindow("controls", 1, 192, 8, 56, 16, 4, "center", 1, nil, nil, nil, nil, { member = 2, bank = 1, fg = 15, sh = 12 })
  PokedexSources.windows["area.tab-johto-solo"] = dexWindow("controls", 1, 144, 8, 56, 16, 0, "center", 1, nil, nil, nil, nil, { member = 2, bank = 1, fg = 5, sh = 9 })
  for row = 2, 6 do
    PokedexSources.windows["area.row-" .. row] =
      dexWindow("controls", 2, 80, 40 + (row - 1) * 24, 144, 16, 4, "center", 1, nil, nil, nil, nil, { member = 2, bank = 1, fg = 15, sh = 12 })
  end
  -- Size screen: title 0 (143), species name 1, player name 2, height
  -- caption 3 (136), height marks 4/6 (10), gender height 7 (138/139),
  -- weight caption 8 (137), weight marks 9/11 (11), gender weight 12
  -- (140/141). `entry.height` is the species height window 5;
  -- `entry.weight` keeps its oracle record.
  PokedexSources.windows["size.species-name"] = dexWindow("information", 1, 32, 24, 64, 16, 0, "center", 1, nil, nil, nil, nil, { member = 18, bank = 1, fg = 2, sh = 1 })
  PokedexSources.windows["size.player-name"] = dexWindow("information", 1, 160, 24, 64, 16, 0, "center", 1, nil, nil, nil, nil, { member = 18, bank = 1, fg = 2, sh = 1 })
  PokedexSources.windows["size.caption-height"] = dexWindow("information", 1, 80, 48, 96, 16, 0, "center", 1, nil, nil, nil, nil, { member = 18, bank = 1, fg = 2, sh = 1 })
  PokedexSources.windows["size.mark-height-left"] = dexWindow("information", 1, 16, 168, 32, 16, 0, "center", 1, nil, nil, nil, nil, { member = 18, bank = 2, fg = 2, sh = 1 })
  PokedexSources.windows["size.mark-height-right"] = dexWindow("information", 1, 136, 168, 32, 16, 0, "center", 1, nil, nil, nil, nil, { member = 18, bank = 2, fg = 2, sh = 1 })
  PokedexSources.windows["size.gender-height"] = dexWindow("information", 1, 176, 168, 64, 16, 0, "center", 1, nil, nil, nil, nil, { member = 18, bank = 2, fg = 2, sh = 1 })
  -- The weight caption prints on the MAIN engine (template 8, bank 1)
  -- even though it projects to the information pane.
  PokedexSources.windows["size.caption-weight"] = dexWindow("information", 1, 80, 8, 96, 16, 0, "center", 1, nil, nil, nil, nil, { member = 2, bank = 1, fg = 5, sh = 9 })
  PokedexSources.windows["size.mark-weight-left"] = dexWindow("controls", 1, 16, 136, 32, 16, 0, "center", 1, nil, nil, nil, nil, { member = 2, bank = 1, fg = 15, sh = 5 })
  PokedexSources.windows["size.mark-weight-right"] = dexWindow("controls", 1, 136, 136, 32, 16, 0, "center", 1, nil, nil, nil, nil, { member = 2, bank = 1, fg = 15, sh = 5 })
  -- Species weight on the size page is its own lower-pane window 10;
  -- the entry-page `entry.weight` rect would overflow the lower screen.
  PokedexSources.windows["size.species-weight"] = dexWindow("controls", 1, 56, 136, 64, 16, 0, "center", 1, nil, nil, nil, nil, { member = 2, bank = 1, fg = 15, sh = 5 })
  PokedexSources.windows["size.gender-weight"] = dexWindow("controls", 1, 176, 136, 64, 16, 0, "center", 1, nil, nil, nil, nil, { member = 2, bank = 1, fg = 15, sh = 5 })
  -- Forms screen: title 0 (170), species header 1 (167 + species name),
  -- selected form 2, caption 4 (168, only above one form), six list
  -- rows 10-15. `forms.selected` keeps its oracle record above.
  PokedexSources.windows["forms.title"] = dexWindow("information", 1, 16, 0, 72, 16, 4, "left", 2, nil, nil, nil, nil, { member = 18, bank = 2, fg = 2, sh = 1 })
  PokedexSources.windows["forms.header"] = dexWindow("information", 1, 32, 40, 72, 16, 0, "right", 1, nil, nil, nil, nil, { member = 18, bank = 1, fg = 2, sh = 1 })
  PokedexSources.windows["forms.caption"] = dexWindow("controls", 1, 168, 136, 80, 16, 4, "left", 1, nil, nil, nil, nil, { member = 2, bank = 1, fg = 15, sh = 12 })
  for row = 1, 6 do
    PokedexSources.windows["forms.row-" .. row] =
      dexWindow("controls", 2, 64, 8 + (row - 1) * 24, 144, 16, 4, "left", 1, nil, nil, nil, nil, { member = 2, bank = 1, fg = 15, sh = 12 })
  end
  -- Compare screen: title 0 (170, shared with `forms.title`), species
  -- header 3 (169 + species name), caption 5 (170), side labels 8-9
  -- (171/172). `forms.compare-left/right` keep their oracle records.
  PokedexSources.windows["forms.compare-header"] = dexWindow("information", 1, 56, 40, 144, 16, 0, "center", 1, nil, nil, nil, nil, { member = 18, bank = 1, fg = 2, sh = 1 })
  PokedexSources.windows["forms.compare-caption"] = dexWindow("controls", 1, 104, 16, 48, 16, 0, "center", 1, nil, nil, nil, nil, { member = 2, bank = 1, fg = 5, sh = 9 })
  PokedexSources.windows["forms.compare-label-left"] = dexWindow("controls", 1, 24, 164, 96, 16, 4, "center", 1, nil, nil, nil, nil, { member = 2, bank = 1, fg = 15, sh = 12 })
  PokedexSources.windows["forms.compare-label-right"] = dexWindow("controls", 1, 144, 164, 96, 16, 4, "center", 1, nil, nil, nil, nil, { member = 2, bank = 1, fg = 15, sh = 12 })
  -- Back tab: title 0 (173); the message 1 (174) replaces the invented
  -- cancel/action split with the single authored return-to-list line.
  PokedexSources.windows["return.action"] = dexWindow("controls", 1, 80, 80, 120, 16, 4, "center", 1, nil, nil, nil, nil, { member = 2, bank = 1, fg = 15, sh = 12 })
  -- Compact inspector detail slots (host-adapted; no native window
  -- paints them). The ink is deliberate host-adapted white over black,
  -- not a native print.
  local detailWindows = {
    ["compact.detail-number"] = dexWindow("information", 1, 120, 80, 32, 14, 4, "left", 0, nil, nil, nil, nil, { member = 18, bank = 6, fg = 14, sh = 15 }),
    ["compact.detail-name"] = dexWindow("information", 1, 152, 80, 72, 14, 4, "left", 0, nil, nil, nil, nil, { member = 18, bank = 6, fg = 14, sh = 15 }),
    ["compact.detail-category"] = dexWindow("information", 1, 104, 96, 120, 14, 4, "right", 0, nil, nil, nil, nil, { member = 18, bank = 6, fg = 14, sh = 15 }),
    ["compact.detail-flavor"] = dexWindow("information", 1, 16, 130, 224, 48, 0, "left", 1, nil, nil, nil, nil, { member = 18, bank = 6, fg = 14, sh = 15 }),
    ["compact.detail-height"] = dexWindow("information", 1, 56, 112, 64, 14, 0, "center", 2, nil, nil, nil, nil, { member = 18, bank = 6, fg = 14, sh = 15 }),
    ["compact.detail-weight"] = dexWindow("information", 1, 136, 112, 64, 14, 0, "center", 2, nil, nil, nil, nil, { member = 18, bank = 6, fg = 14, sh = 15 }),
  }
  for role, record in pairs(detailWindows) do
    PokedexSources.windows[role] = record
  end
end

-- Every window resolves its prepared message through its own key unless
-- the record names a shared role: the registration popup keys are already
-- page-qualified, so their role is their key.
for key, record in pairs(PokedexSources.windows) do
  if record.textRole == nil then
    record.textRole = key
  end
end

-- The footprint assembly anchors on the native NCER part origin: the
-- 16x16 assembly stages with its top-left eight pixels left and above the
-- published specimen center, so the prepared offset is (-8,-8) for every
-- staged species.
PokedexSources.footprintAnchor = { x = -8, y = -8 }

-- Page-local window inventories over the contracted slots. Menu labels
-- and values keep the menu rects; each editor carries its own title and
-- current-value rects; the results return slot shows the criteria summary
-- (native hides it once a species highlights); entry pages carry the
-- native page windows. The selected detail family stays out of the
-- grid/results paint: its prepared strings are data for the adapted
-- inspector surface, and the native list pages never paint entry details.
-- The inventory records above remain their generated backing.
local gridWindows = {
  "grid.info-label",
  "grid.selected-number",
  "grid.selected-name",
  "grid.category",
  "grid.flavor",
  "grid.height-mark",
  "grid.height",
  "grid.weight-mark",
  "grid.weight",
  "grid.name-bar",
}
local searchCriteriaWindows = { "search.criteria", "search.feedback", "search.feedback-detail" }
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
local searchOrderWindows = {
  "search.criteria",
  "search.feedback",
  "search.feedback-detail",
  "search.title-order",
  "search.current-order",
  "search.button-ok",
  "search.button-cancel",
}
for _, name in ipairs({ "numerical", "alphabetical", "heaviest", "lightest", "tallest", "shortest" }) do
  searchOrderWindows[#searchOrderWindows + 1] = "search.option-order-" .. name
end
local searchLetterWindows =
  { "search.criteria", "search.feedback", "search.feedback-detail", "search.title-letter", "search.current-letter" }
for position = 0, 26 do
  local label = position < 26 and string.char(string.byte("A") + position) or "unrestricted"
  searchLetterWindows[#searchLetterWindows + 1] = "search.option-letter-" .. label
end
searchLetterWindows[#searchLetterWindows + 1] = "search.button-ok"
searchLetterWindows[#searchLetterWindows + 1] = "search.button-cancel"
local searchTypeWindows = {
  "search.criteria",
  "search.feedback",
  "search.feedback-detail",
  "search.title-type",
  "search.current-type-1",
  "search.current-type-2",
}
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
    "search.feedback-detail",
    "search.title-" .. criterion,
    "search.current-" .. criterion .. "-min",
    "search.current-" .. criterion .. "-max",
    "search.button-ok",
    "search.button-cancel",
  }
end
local searchAreaWindows = {
  "search.criteria",
  "search.feedback",
  "search.feedback-detail",
  "search.title-area",
  "search.current-area",
  "search.button-ok",
  "search.button-cancel",
}
for _, name in ipairs({ "johto", "kanto", "unknown", "unrestricted" }) do
  searchAreaWindows[#searchAreaWindows + 1] = "search.option-area-" .. name
end
local searchShapeWindows = {
  "search.criteria",
  "search.feedback",
  "search.feedback-detail",
  "search.title-shape",
  "search.button-ok",
  "search.button-cancel",
}
local resultsWindows = {
  "search.results",
  "grid.selected-number",
  "grid.selected-name",
  "grid.category",
  "grid.flavor",
  "grid.height-mark",
  "grid.height",
  "grid.weight-mark",
  "grid.weight",
  "grid.name-bar",
  "grid.seen-caption",
  "grid.caught-caption",
  "grid.seen-count",
  "grid.caught-count",
}
for _, role in ipairs(searchSummaryWindows) do
  resultsWindows[#resultsWindows + 1] = role
end
-- The cover page carries the two count labels and their quantities: the
-- native list-family windows sit on MAIN0 (the 512-wide cover/list scroll
-- plane) at plane x16/144, so they ride the cover half and slide out with
-- it. The list view itself keeps its counts on the fixed-address MAIN3
-- number strip instead.
local coverWindows = {
  "grid.seen-caption",
  "grid.caught-caption",
  "grid.seen-count",
  "grid.caught-count",
}
PokedexSources.pageWindows = {
  cover = coverWindows,
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
    "registration.mark-height",
    "registration.height",
    "registration.mark-weight",
    "registration.weight",
  },
}

-- Producer-only live-sprite subject map: the actually instantiated
-- native OBJ subjects per page with their animation choice bindings.
-- Each entry names the source NCER/NANR member pair, the 1-based
-- sequence within the animation member (decomp SetSpriteAnim index +
-- 1), and the authored engine pane (source MAIN drives the touch
-- controls pane, source SUB the upper information pane, the battle
-- MAIN popup card the information pane). Positions and visibility live
-- in the runtime projection; only sequence selection stays here.
--
-- Sequence evidence (ctrl-cheeb-del/pokeheartgold, pinned revision):
-- list cursor/arrows/scrollbar in pokedex_sprites.c
-- (MoveSpriteToListCursor, UpdateListPageArrows with anims 7/5 and
-- 10/8, GetListScrollbarSizeAnim with anims 11+i); caught mark in
-- UpdateCaughtMarkSprite; body-type icon in UpdateBodyTypeSprite and
-- SetBodyTypeSpriteLayout (sprite 28, anim = criterion); slider
-- handles/digits/limits in UpdateSliderSprites, DrawHeightDigits,
-- DrawWeightDigits and UpdateSliderLimitSprites (anims 67/68, 41/42,
-- digit + 43, limit anims 58/53, 56/55); search feedback in
-- pokedex_main_seq.c MAINSEQ_26 (sprite 27 anim 2, sprite 26 anim 1,
-- retract anim 3); entry tab cursor in MoveEntryTabCursor (anim 3);
-- area player/time/scrollbar/arrows in pokedex_area_sprites.c
-- (SetPlayerMarkerAnim male 0/female 1/inside +2, UpdateTimeOfDayCursor,
-- SetScrollbarSizeAnim base 14, UpdateScrollArrows) with marker shapes
-- 0..11 from GetOverworldMarkerPos/GetDungeonMarkerPos; size pans and
-- beam in UpdateScalePans (sprites 8/9, fixed sprites 6/7);
-- forms/compare selector in UpdateFormCompareSelector with the frame
-- sprites 9..13 and scrollbar/arrows in ShowFormListSprites;
-- popup type icons and footprint in pokedex_entry_popup.c
-- (type sprites at (168,72)/(217,72), footprint at (120,80)).
-- Shared language-icon choices over the list/sub language family (cells
-- 54, animations 55: LoadLanguageIconResources/Sub in pokedex_sprites.c
-- stage the same pair on both engines). Dex flags run japanese 0,
-- english 1, french 2, german 3, italian 4, spanish 5
-- (pokedex_language.c); UpdateLanguageIcons highlights the shown
-- language with anim flag and dims the rest with anim flag + 6, so the
-- 1-based choices span sequences 1..12. The animation member carries
-- exactly twelve sequences in the shipped archive.
local DEX_FLAG_ORDER = { "japanese", "english", "french", "german", "italian", "spanish" }

---@param pane string authored engine pane behind the icons
---@return table<string, table<string, unknown>> semantic choices behind the flag row
local function languageFlagSubjects(pane)
  local choices = {}
  for flag, name in ipairs(DEX_FLAG_ORDER) do
    choices[name] = { cells = 54, anims = 55, seq = flag, pane = pane }
    choices[name .. "-dim"] = { cells = 54, anims = 55, seq = flag + 6, pane = pane }
  end
  return choices
end

---@return table<string, table<string, unknown>> semantic choices behind the current-language icon
local function languageCurrentSubjects()
  local choices = {}
  for flag, name in ipairs(DEX_FLAG_ORDER) do
    choices[name] = { cells = 54, anims = 55, seq = flag, pane = "controls" }
  end
  return choices
end

local gridSubjects = {
  cursor = {
    active = { cells = 13, anims = 14, seq = 2, pane = "controls" },
  },
  ["arrow-up"] = {
    enabled = { cells = 13, anims = 14, seq = 6, pane = "controls" },
    disabled = { cells = 13, anims = 14, seq = 8, pane = "controls" },
  },
  ["arrow-down"] = {
    enabled = { cells = 13, anims = 14, seq = 9, pane = "controls" },
    disabled = { cells = 13, anims = 14, seq = 11, pane = "controls" },
  },
  scrollbar = {
    size0 = { cells = 13, anims = 14, seq = 12, pane = "controls" },
    size1 = { cells = 13, anims = 14, seq = 13, pane = "controls" },
    size2 = { cells = 13, anims = 14, seq = 14, pane = "controls" },
    size3 = { cells = 13, anims = 14, seq = 15, pane = "controls" },
    size4 = { cells = 13, anims = 14, seq = 16, pane = "controls" },
    size5 = { cells = 13, anims = 14, seq = 17, pane = "controls" },
    size6 = { cells = 13, anims = 14, seq = 18, pane = "controls" },
    size7 = { cells = 13, anims = 14, seq = 19, pane = "controls" },
    size8 = { cells = 13, anims = 14, seq = 20, pane = "controls" },
    size9 = { cells = 13, anims = 14, seq = 21, pane = "controls" },
    size10 = { cells = 13, anims = 14, seq = 22, pane = "controls" },
    size11 = { cells = 13, anims = 14, seq = 23, pane = "controls" },
  },
  ["caught-mark"] = {
    shown = { cells = 30, anims = 31, seq = 1, pane = "information" },
  },
  ["dex-mode"] = {
    shown = { cells = 13, anims = 14, seq = 24, pane = "controls" },
  },
  placeholder = {
    shown = { cells = 27, anims = 28, seq = 1, pane = "information" },
  },
  ["intl-pair"] = {
    left = { cells = 13, anims = 14, seq = 25, pane = "controls" },
    right = { cells = 13, anims = 14, seq = 26, pane = "controls" },
  },
}

-- Shared digit choices: height and weight editors spell their handle
-- values with digit sprites (DrawHeightDigits, DrawWeightDigits: digit
-- sprite anim = digit + 43, i.e. 1-based sequence 44 + digit).
local function digitChoices()
  local choices = {}
  for digit = 0, 9 do
    choices["d" .. digit] = { cells = 13, anims = 14, seq = 44 + digit, pane = "controls" }
  end
  return choices
end

-- Shared limit-arrow choices: sprite 1/3 carry the near arrow, sprites
-- 2/4 the far arrow (UpdateSliderLimitSprites: value 0 selects anims
-- 58/53, value 152 selects anims 56/55, anything else 56/53).
local nearLimitChoices = {
  ["at-min"] = { cells = 13, anims = 14, seq = 59, pane = "controls" },
  mid = { cells = 13, anims = 14, seq = 57, pane = "controls" },
  ["at-max"] = { cells = 13, anims = 14, seq = 57, pane = "controls" },
}
local farLimitChoices = {
  ["at-min"] = { cells = 13, anims = 14, seq = 54, pane = "controls" },
  mid = { cells = 13, anims = 14, seq = 54, pane = "controls" },
  ["at-max"] = { cells = 13, anims = 14, seq = 56, pane = "controls" },
}

-- Shared slider subjects for the height and weight editors: the cursor
-- follows the max handle, handle art differs per editor
-- (SetSpriteAnim 67/68 on height, 41/42 on weight), digits ride the
-- handle columns and limits reflect the slider ends.
local function sliderSubjects(digitCount)
  local subjects = {
    ["slider-max"] = {
      height = { cells = 13, anims = 14, seq = 68, pane = "controls" },
      weight = { cells = 13, anims = 14, seq = 42, pane = "controls" },
    },
    ["slider-min"] = {
      height = { cells = 13, anims = 14, seq = 69, pane = "controls" },
      weight = { cells = 13, anims = 14, seq = 43, pane = "controls" },
    },
    ["limit-max-left"] = nearLimitChoices,
    ["limit-max-right"] = farLimitChoices,
    ["limit-min-left"] = nearLimitChoices,
    ["limit-min-right"] = farLimitChoices,
  }
  for _, handle in ipairs({ "digit-max-", "digit-min-" }) do
    for position = 1, digitCount do
      subjects[handle .. position] = digitChoices()
    end
  end
  return subjects
end

-- Shared list chrome: the result grid reuses the list cursor, arrows
-- and thumb bindings (MAINSEQ_57 drives cursor sprite 0 with anim 1
-- and scrollbar/arrows sprites 18..20 like the list sprites 1..3).
-- Shared body-type icon: sprite 28 shows the current shape class
-- wherever the criterion is set (UpdateBodyTypeSprite on the menu,
-- SetBodyTypeSpriteLayout on the shape page). The choice sprites share
-- the menu art family, whose fourteen sequences match the fourteen
-- shape classes one for one.
local function bodyIconSubjects()
  local choices = {}
  for index, name in ipairs(PokedexSources.shapeOrder) do
    choices[name] = { cells = 73, anims = 74, seq = index, pane = "controls" }
  end
  return { ["body-icon"] = choices }
end

local function tabCursorSubjects()
  return {
    ["tab-cursor"] = {
      active = { cells = 13, anims = 14, seq = 4, pane = "controls" },
    },
  }
end

local function smallScrollbarSubjects()
  local choices = {}
  for bucket = 0, 8 do
    choices["size" .. bucket] = { cells = 13, anims = 14, seq = 15 + bucket, pane = "controls" }
  end
  return { scrollbar = choices }
end

-- Shared type icon choices: one semantic choice per source type class
-- resolved to the page-local synthesized type role by the compiler.
local function typeIconSubjects()
  local first, second = {}, {}
  for _, name in ipairs(PokedexSources.typeOrder) do
    first[name] = { typeIcon = name, pane = "information" }
    second[name] = { typeIcon = name, pane = "information" }
  end
  return { ["type-1"] = first, ["type-2"] = second }
end

-- Area marker shape choices: the twelve overworld/dungeon silhouettes
-- (UpdateAreaMarkers selects SetSpriteAnim shape, 0..11).
local function areaMarkerSubjects()
  local choices = {}
  for shape = 0, 11 do
    for bank = 0, 1 do
      choices["shape" .. shape .. "-" .. bank] =
        { cells = 120, anims = 121, seq = shape + 1, pane = "information", bank = bank }
    end
  end
  return { marker = choices }
end

local areaSubjects = {
  ["tab-cursor"] = {
    active = { cells = 13, anims = 14, seq = 4, pane = "controls" },
  },
  player = {
    male = { cells = 116, anims = 117, seq = 1, pane = "information" },
    female = { cells = 116, anims = 117, seq = 2, pane = "information" },
    ["male-here"] = { cells = 116, anims = 117, seq = 3, pane = "information" },
    ["female-here"] = { cells = 116, anims = 117, seq = 4, pane = "information" },
  },
  ["time-cursor"] = {
    active = { cells = 13, anims = 14, seq = 28, pane = "information" },
  },
  ["arrow-up"] = gridSubjects["arrow-up"],
  ["arrow-down"] = gridSubjects["arrow-down"],
  scrollbar = smallScrollbarSubjects().scrollbar,
  marker = areaMarkerSubjects().marker,
}

local sizeSubjects = {
  ["tab-cursor"] = {
    active = { cells = 13, anims = 14, seq = 4, pane = "controls" },
  },
  ["pan-left"] = {
    active = { cells = 13, anims = 14, seq = 33, pane = "controls" },
  },
  ["pan-right"] = {
    active = { cells = 13, anims = 14, seq = 33, pane = "controls" },
  },
  ["beam-top"] = {
    active = { cells = 13, anims = 14, seq = 34, pane = "controls" },
  },
  ["beam-bottom"] = {
    active = { cells = 13, anims = 14, seq = 32, pane = "controls" },
  },
  trainer = {
    male = { trainer = "male", pane = "information" },
    female = { trainer = "female", pane = "information" },
  },
  -- The weight-check trainer figure uses the same character/cell family
  -- as the standing height portrait but rides its own weight pan.
  ["trainer-figure"] = {
    male = { trainer = "male", pane = "information" },
    female = { trainer = "female", pane = "information" },
  },
}

local formsSubjects = {
  ["tab-cursor"] = {
    active = { cells = 13, anims = 14, seq = 4, pane = "controls" },
  },
  ["arrow-up"] = gridSubjects["arrow-up"],
  ["arrow-down"] = gridSubjects["arrow-down"],
  scrollbar = smallScrollbarSubjects().scrollbar,
  ["compare-frame"] = {
    tl = { cells = 13, anims = 14, seq = 65, pane = "controls" },
    tr = { cells = 13, anims = 14, seq = 65, pane = "controls" },
    bl = { cells = 13, anims = 14, seq = 66, pane = "controls" },
    br = { cells = 13, anims = 14, seq = 66, pane = "controls" },
  },
  ["compare-side"] = {
    left = { cells = 13, anims = 14, seq = 67, pane = "controls" },
    right = { cells = 13, anims = 14, seq = 67, pane = "controls" },
  },
}

local compareSubjects = {
  ["tab-cursor"] = tabCursorSubjects()["tab-cursor"],
  ["compare-frame"] = formsSubjects["compare-frame"],
  ["compare-side"] = formsSubjects["compare-side"],
}

local feedbackSubjects = {
  feedback = {
    label = { cells = 24, anims = 25, seq = 3, pane = "information" },
    rise = { cells = 24, anims = 25, seq = 2, pane = "information" },
    retract = { cells = 24, anims = 25, seq = 4, pane = "information" },
  },
}

-- Source search cursor sequences (sSearch*CursorAnims, one-based). The
-- cursor family is the page's main OBJ pair (cells 13 / anims 14); each
-- focus node selects its authored highlight animation.
local function cursorChoices(sequences)
  local choices = {}
  for index, sequence in ipairs(sequences) do
    choices["n" .. (index - 1)] = { cells = 13, anims = 14, seq = sequence, pane = "controls" }
  end
  return choices
end

local menuCursor = cursorChoices({ 40, 36, 37, 60, 61, 39, 35, 36, 36, 36 })
local orderCursor = cursorChoices({ 40, 40, 40, 40, 40, 40, 36, 36 })
local areaCursor = cursorChoices({ 39, 39, 39, 39, 36, 36 })
local sliderCursor = cursorChoices({ 63, 63, 36, 36 })
local shapeCursor = cursorChoices({ 35, 35, 35, 35, 35, 35, 35, 35, 35, 35, 35, 35, 35, 35, 35, 36, 36 })
local typeCursor = cursorChoices({
  39,
  39,
  39,
  39,
  39,
  39,
  39,
  39,
  39,
  39,
  39,
  39,
  39,
  39,
  39,
  39,
  39,
  39,
  36,
  36,
})
local letterCursor = cursorChoices({
  41,
  41,
  41,
  41,
  41,
  41,
  41,
  41,
  41,
  41,
  41,
  41,
  41,
  41,
  41,
  41,
  41,
  41,
  41,
  41,
  41,
  41,
  41,
  41,
  41,
  41,
  41,
  36,
  36,
})

local function searchSubjects(extra)
  local subjects = {
    feedback = feedbackSubjects.feedback,
  }
  for subject, choices in pairs(extra) do
    subjects[subject] = choices
  end
  return subjects
end

local function withCursor(subjects, cursor)
  subjects.cursor = cursor
  subjects["dex-mode"] = {
    shown = { cells = 13, anims = 14, seq = 24, pane = "controls" },
  }
  return subjects
end

local heightSubjects = withCursor(searchSubjects(sliderSubjects(4)), sliderCursor)
local weightSubjects = withCursor(searchSubjects(sliderSubjects(5)), sliderCursor)
local shapeSubjects = withCursor(searchSubjects(bodyIconSubjects()), shapeCursor)
local criteriaSubjects = withCursor(searchSubjects(bodyIconSubjects()), menuCursor)

local gridTypes = typeIconSubjects()
gridSubjects["type-1"] = gridTypes["type-1"]
gridSubjects["type-2"] = gridTypes["type-2"]
gridSubjects["lang-flag"] = languageFlagSubjects("information")
gridSubjects["lang-current"] = languageCurrentSubjects()
local resultTypes = typeIconSubjects()
local registrationTypes = typeIconSubjects()

PokedexSources.nativeSpriteSubjects = {
  grid = gridSubjects,
  results = {
    cursor = gridSubjects.cursor,
    ["arrow-up"] = gridSubjects["arrow-up"],
    ["arrow-down"] = gridSubjects["arrow-down"],
    scrollbar = gridSubjects.scrollbar,
    ["caught-mark"] = gridSubjects["caught-mark"],
    ["type-1"] = resultTypes["type-1"],
    ["type-2"] = resultTypes["type-2"],
    ["lang-flag"] = gridSubjects["lang-flag"],
    ["lang-current"] = gridSubjects["lang-current"],
    ["dex-mode"] = gridSubjects["dex-mode"],
    placeholder = gridSubjects.placeholder,
    ["intl-pair"] = gridSubjects["intl-pair"],
  },
  ["search.criteria"] = criteriaSubjects,
  ["search.order"] = withCursor(searchSubjects({}), orderCursor),
  ["search.name"] = withCursor(searchSubjects({}), letterCursor),
  ["search.type"] = withCursor(searchSubjects({}), typeCursor),
  ["search.height"] = heightSubjects,
  ["search.weight"] = weightSubjects,
  ["search.area"] = withCursor(searchSubjects({}), areaCursor),
  ["search.shape"] = shapeSubjects,
  ["entry.area"] = areaSubjects,
  ["entry.size"] = sizeSubjects,
  ["entry.forms"] = formsSubjects,
  ["entry.compare"] = compareSubjects,
  ["entry.return"] = tabCursorSubjects(),
  registration = registrationTypes,
}

-- Source OBJ priorities (template bgPriority) per page subject. A
-- subject family that shares an animation member with another priority
-- family carries it explicitly here (language flags vs the current
-- language icon, search feedback vs the search cursor).
local SUBJECT_PRIORITY = {
  grid = {
    cursor = 3,
    ["arrow-up"] = 3,
    ["arrow-down"] = 3,
    scrollbar = 3,
    ["caught-mark"] = 3,
    ["type-1"] = 3,
    ["type-2"] = 3,
    ["lang-flag"] = 3,
    ["lang-current"] = 0,
    ["dex-mode"] = 0,
    placeholder = 3,
    ["intl-pair"] = 0,
  },
  results = {
    cursor = 3,
    ["arrow-up"] = 3,
    ["arrow-down"] = 3,
    scrollbar = 3,
    ["caught-mark"] = 3,
    ["type-1"] = 3,
    ["type-2"] = 3,
    ["lang-flag"] = 3,
    ["lang-current"] = 0,
    ["dex-mode"] = 0,
    placeholder = 3,
    ["intl-pair"] = 0,
  },
  ["search.criteria"] = { cursor = 0, feedback = 3, ["body-icon"] = 0 },
  ["search.order"] = { cursor = 0, feedback = 3 },
  ["search.name"] = { cursor = 0, feedback = 3 },
  ["search.type"] = { cursor = 0, feedback = 3 },
  ["search.height"] = { cursor = 0, feedback = 3 },
  ["search.weight"] = { cursor = 0, feedback = 3 },
  ["search.area"] = { cursor = 0, feedback = 3 },
  ["search.shape"] = { cursor = 0, feedback = 3, ["body-icon"] = 0 },
  ["entry.area"] = {
    ["tab-cursor"] = 0,
    player = 3,
    ["time-cursor"] = 0,
    ["arrow-up"] = 0,
    ["arrow-down"] = 0,
    scrollbar = 0,
    marker = 3,
  },
  ["entry.size"] = {
    ["tab-cursor"] = 0,
    ["pan-left"] = 1,
    ["pan-right"] = 1,
    ["beam-top"] = 1,
    ["beam-bottom"] = 1,
    trainer = 0,
    ["trainer-figure"] = 0,
    ["trainer-height"] = 1,
  },
  ["entry.forms"] = {
    ["tab-cursor"] = 0,
    ["arrow-up"] = 0,
    ["arrow-down"] = 0,
    scrollbar = 0,
    ["compare-frame"] = 0,
    ["compare-side"] = 0,
  },
  ["entry.compare"] = { ["tab-cursor"] = 0, ["compare-frame"] = 0, ["compare-side"] = 0 },
  ["entry.return"] = { ["tab-cursor"] = 0 },
  registration = { ["type-1"] = 0, ["type-2"] = 0 },
}

for page, subjects in pairs(PokedexSources.nativeSpriteSubjects) do
  local overrides = SUBJECT_PRIORITY[page] or {}
  for subject, choices in pairs(subjects) do
    local priority = overrides[subject]
    if type(priority) ~= "number" then
      priority = 0
    end
    for _, entry in pairs(choices) do
      if entry.priority == nil then
        entry.priority = priority
      end
    end
  end
end

return PokedexSources
