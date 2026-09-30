-- Readiness, paths, and strict validation for the generated HGSS field-UI
-- class: one manifest (`ui.lua`) carrying the semantic surfaces and the
-- strict metadata sections, binary assets (PNG atlases) under the UI asset
-- root, and a completion marker written last with the ROM SHA-1 and producer
-- dependency hash. The manifest is the single mod-facing contract for
-- dialogue frames, signposts, the Start Menu, the Trainer Card, the normal
-- naming chrome, and the two-row choice prompt; it never
-- carries NARC/member ids. A UI class is ready only when the marker matches
-- exactly and every indexed file exists. Paths are cache-relative; all IO
-- goes through a CacheFs.

local Errors = require("libs.errors.src.Errors")
local Validate = require("libs.assets.src.Validate")
local Contract = require("libs.assets.src.DerivedAssetContract")

local FieldUiAssetCache = {}

---@class FieldUiAssetCache.Asset
---@field image string
---@field width integer
---@field height integer

---@class FieldUiAssetCache.PromptVisual
---@field asset string
---@field rect { x: integer, y: integer, width: integer, height: integer }

---@class FieldUiAssetCache.PromptRow
---@field normal FieldUiAssetCache.PromptVisual
---@field selected FieldUiAssetCache.PromptVisual

---@class FieldUiAssetCache.PromptShape
---@field width integer
---@field height integer
---@field yes FieldUiAssetCache.PromptRow
---@field no FieldUiAssetCache.PromptRow

---@class FieldUiAssetCache.PromptSection
---@field shapes { compact: FieldUiAssetCache.PromptShape }

---@class FieldUiAssetCache.Manifest
---@field schema string
---@field assets table<string, FieldUiAssetCache.Asset>
---@field yesNoPrompt FieldUiAssetCache.PromptSection
---@field [string] table<string, unknown>

FieldUiAssetCache.FORMAT = Contract.fieldUi.cacheFormat
FieldUiAssetCache.SCHEMA = Contract.fieldUi.schema

-- The audited HGSS field-UI geometry is a generated-class invariant,
-- not a tunable: dialogue and signpost frame members carry 18 tiles (a
-- 144x8 strip) and every wayfinding member carries 24 tiles but is
-- persisted as a precomposed 48x32 final surface (6 columns x 4 rows).
-- The producer arranges the raw 24 tiles into that surface at build time;
-- runtime draws a single rect. The validator enforces the final 48x32
-- shape. The two-row choice prompt buttons are the same 6x4-tile compact
-- geometry: one 48x32 surface per button state. The producer and validator
-- consume these numbers from this one protocol owner.
FieldUiAssetCache.GEOMETRY = {
  FRAME_TILES = 18,
  WAYFINDING_TILES = 24,
  WAYFINDING_COLUMNS = 6,
  WAYFINDING_ROWS = 4,
  WAYFINDING_WIDTH = 48,
  WAYFINDING_HEIGHT = 32,
  PROMPT_BUTTON_WIDTH = 48,
  PROMPT_BUTTON_HEIGHT = 32,
}

-- The generated field-UI asset protocol ids: one constant table so the
-- producer, the cache validation, and the renderers never repeat the raw
-- strings.
FieldUiAssetCache.ASSET = {
  DIALOGUE_FRAME_TILES = "hgss.dialogue_frame.tiles",
  DIALOGUE_CONTINUE_CURSOR = "hgss.dialogue_continue_cursor",
  SIGNPOST_TILES = "hgss.signpost.tiles",
  SIGNPOST_WAYFINDING = "hgss.signpost.wayfinding",
  START_MENU_BACKGROUND = "hgss.start_menu.background",
  START_MENU_CURSOR = "hgss.start_menu.cursor",
  START_MENU_ICONS = "hgss.start_menu.icons",
  START_MENU_ICON_PALETTE = "hgss.start_menu.icon_palette",
  START_MENU_POKE_ICONS = "hgss.start_menu.poke_icons",
  START_MENU_CHROME_SUB = "hgss.start_menu.chrome_sub",
  TRAINER_CARD_FRONT = "hgss.trainer_card.front",
  NAMING_SCREEN_BASE = "hgss.naming_screen.base",
  NAMING_SCREEN_PAGE_UPPER = "hgss.naming_screen.page_upper",
  NAMING_SCREEN_PAGE_LOWER = "hgss.naming_screen.page_lower",
  NAMING_SCREEN_PAGE_SYMBOLS = "hgss.naming_screen.page_symbols",
  NAMING_SCREEN_CONTROL_UPPER = "hgss.naming_screen.control_upper",
  NAMING_SCREEN_CONTROL_LOWER = "hgss.naming_screen.control_lower",
  NAMING_SCREEN_CONTROL_SYMBOLS = "hgss.naming_screen.control_symbols",
  NAMING_SCREEN_CONTROL_BACK = "hgss.naming_screen.control_back",
  NAMING_SCREEN_CONTROL_OK = "hgss.naming_screen.control_ok",
  NAMING_SCREEN_CONTROL_BACKING = "hgss.naming_screen.control_backing",
  NAMING_SCREEN_CURSOR_KEYBOARD = "hgss.naming_screen.cursor_keyboard",
  NAMING_SCREEN_CURSOR_KEYBOARD_MASK = "hgss.naming_screen.cursor_keyboard_mask",
  NAMING_SCREEN_CURSOR_HOME_UPPER = "hgss.naming_screen.cursor_home_upper",
  NAMING_SCREEN_CURSOR_HOME_UPPER_MASK = "hgss.naming_screen.cursor_home_upper_mask",
  NAMING_SCREEN_CURSOR_HOME_LOWER = "hgss.naming_screen.cursor_home_lower",
  NAMING_SCREEN_CURSOR_HOME_LOWER_MASK = "hgss.naming_screen.cursor_home_lower_mask",
  NAMING_SCREEN_CURSOR_HOME_SYMBOLS = "hgss.naming_screen.cursor_home_symbols",
  NAMING_SCREEN_CURSOR_HOME_SYMBOLS_MASK = "hgss.naming_screen.cursor_home_symbols_mask",
  NAMING_SCREEN_CURSOR_HOME_BACK = "hgss.naming_screen.cursor_home_back",
  NAMING_SCREEN_CURSOR_HOME_BACK_MASK = "hgss.naming_screen.cursor_home_back_mask",
  NAMING_SCREEN_CURSOR_HOME_OK = "hgss.naming_screen.cursor_home_ok",
  NAMING_SCREEN_CURSOR_HOME_OK_MASK = "hgss.naming_screen.cursor_home_ok_mask",
  NAMING_SCREEN_SLOT_NORMAL = "hgss.naming_screen.slot_normal",
  NAMING_SCREEN_SLOT_SELECTED = "hgss.naming_screen.slot_selected",
  NAMING_SCREEN_SUBJECT_MALE = "hgss.naming_screen.subject_male",
  NAMING_SCREEN_SUBJECT_FEMALE = "hgss.naming_screen.subject_female",
  NAMING_SCREEN_POKEMON_GENDER_MALE = "hgss.naming_screen.pokemon_gender_male",
  NAMING_SCREEN_POKEMON_GENDER_FEMALE = "hgss.naming_screen.pokemon_gender_female",
  YES_NO_PROMPT_YES_NORMAL = "hgss.yes_no_prompt.yes_normal",
  YES_NO_PROMPT_YES_SELECTED = "hgss.yes_no_prompt.yes_selected",
  YES_NO_PROMPT_NO_NORMAL = "hgss.yes_no_prompt.no_normal",
  YES_NO_PROMPT_NO_SELECTED = "hgss.yes_no_prompt.no_selected",
}

-- One error code for every malformed generated class: the manifest is the
-- single strict structural boundary, so all violations share the code while
-- the message names the exact broken field.
local MANIFEST_INVALID = "FIELD_UI_MANIFEST_INVALID"

local DATA_DIR = "data/generated/field/ui"
local ASSET_DIR = "assets/generated/field/ui"

-- Fixed validation key sets, built once: rectangle fields, color channels,
-- icon states, navigation directions, and animation play modes are shared
-- by every row/frame/position instead of being rebuilt per record.
local RECT_FIELDS = { "x", "y", "width", "height" }
local RGB_CHANNELS = { "r", "g", "b" }
local ICON_STATES = { "normal", "selected" }
local NAV_DIRECTIONS = { "up", "down", "left", "right" }
local ANIMATION_PLAY_MODES = { forward = true, forward_loop = true, reverse = true, reverse_loop = true }

-- The retail icon-sprite contract: thirteen icon rows (Lua index = retail
-- icon index + 1) with per-row art kind and label data. Sprite rows carry
-- source-composed normal/selected visuals (the Bag row carries the female
-- pair as a first-class variant); text and poke-icon rows carry no art.
local VALID_ICON_ARTS = { sprite = true, text = true, poke_icon = true }
local VALID_ICON_LABEL_KINDS = { static = true, player_name = true }

local NAMING_CONTROL_ANCHORS = {
  upper = { x = 26, y = 68 },
  lower = { x = 58, y = 68 },
  symbols = { x = 90, y = 68 },
  back = { x = 158, y = 68 },
  ok = { x = 198, y = 68 },
  backing = { x = 22, y = 56 },
}

-- Strict manifest validation: required arrays, strict enums, and every
-- rectangle/size/index finite, integral, non-negative, and inside its
-- atlas. Private checks reject malformed data through one owned error;
-- validateManifest is the only boundary that translates it into the public
-- false-plus-error result, so unrelated failures still propagate to the
-- caller. Validation reports the first violation in section order and never
-- mutates the manifest. Every helper below is forward-declared here so the
-- public entry points and the section-level checkers can read top-to-bottom
-- as the file's main flow, with progressively more generic helpers below
-- the functions that use them.
local reject
local checkInteger, checkByteColor, checkRect, checkAtlasRect, checkStrip
local demandSection, demandCount, checkPalette16, demandDenseSequence
local checkFrameOffset, checkSpriteVisual, checkLabelRole, checkCanonicalPoint
local isSignedInteger, checkSignedPoint, checkNamingSprite, checkAnimationRecord
local checkManifest
local checkDialogueFrames, checkSignposts, checkStartMenu, checkTrainerCard, checkNamingScreen, checkYesNoPrompt
local checkStartMenuCursor, checkStartMenuIconRow, checkStartMenuIconTable, checkStartMenuIconPalette
local checkStartMenuContexts, checkStartMenuActionIcons, checkStartMenuInteractivePosition, checkStartMenuInteractive
local checkStartMenuChrome, checkStartMenuLabelPalette
local checkNamingScreenBaseAndPlacement, checkNamingScreenText, checkNamingScreenControls, checkNamingScreenCursor
local checkNamingScreenEntrySlots, checkNamingScreenPlayerSubjects
local checkNamingScreenPokemonSubjectPart, checkNamingScreenPokemonSubjectFrame, checkNamingScreenPokemonSubject
local checkNamingScreenGenderMarkers

function FieldUiAssetCache.dir()
  return DATA_DIR
end
function FieldUiAssetCache.assetDir()
  return ASSET_DIR
end
function FieldUiAssetCache.manifestPath()
  return DATA_DIR .. "/ui.lua"
end
function FieldUiAssetCache.provenancePath()
  return DATA_DIR .. "/provenance.lua"
end
function FieldUiAssetCache.markerPath()
  return DATA_DIR .. "/complete"
end

function FieldUiAssetCache.marker(romSha1, depHash)
  return string.format("%s:%s:%s", FieldUiAssetCache.FORMAT, romSha1, depHash)
end

---@param manifest table<string, unknown>
---@return boolean, Errors.Error?
function FieldUiAssetCache.validateManifest(manifest)
  local ok, result = pcall(checkManifest, manifest)
  if ok then
    return true
  end
  if Errors.is(result) then
    ---@cast result Errors.Error
    if result.code == MANIFEST_INVALID then
      return false, result
    end
  end
  error(result, 0)
end

-- Every generated file the manifest indexes must exist for the class to be
-- ready. The marker must also match exactly and the persisted manifest must
-- still satisfy the current consumer-safe contract: publication proved the
-- staged bytes, not that the live files remain intact, so readiness
-- revalidates the persisted structure before checking file closure.
function FieldUiAssetCache.isReady(cacheFs, expectedMarker)
  if cacheFs:read(FieldUiAssetCache.markerPath()) ~= expectedMarker then
    return false
  end
  local manifest = cacheFs:loadLua(FieldUiAssetCache.manifestPath())
  if type(manifest) ~= "table" then
    return false
  end
  local valid = FieldUiAssetCache.validateManifest(manifest)
  if not valid then
    return false
  end
  for _, entry in pairs(manifest.assets) do
    if not cacheFs:exists(entry.image, "file") then
      return false
    end
  end
  return true
end

checkManifest = function(manifest)
  if type(manifest) ~= "table" then
    reject("manifest is not a table", {})
  end
  if manifest.schema ~= FieldUiAssetCache.SCHEMA then
    reject("manifest schema mismatch", {
      schema = manifest.schema,
      expected = FieldUiAssetCache.SCHEMA,
    })
  end
  if type(manifest.reference) ~= "table" or manifest.reference.width ~= 256 or manifest.reference.height ~= 192 then
    reject("manifest reference must be the 256x192 field screen", {
      reference = manifest.reference,
    })
  end
  if type(manifest.assets) ~= "table" or next(manifest.assets) == nil then
    reject("manifest assets must be a non-empty table", {})
  end
  local atlases = {}
  for key, entry in pairs(manifest.assets) do
    if type(key) ~= "string" or key == "" then
      reject("asset key must be a non-empty string", {})
    end
    if type(entry) ~= "table" or type(entry.image) ~= "string" or entry.image == "" then
      reject("asset " .. key .. " must name an image path", { key = key })
    end
    if
      type(entry.width) ~= "number"
      or entry.width % 1 ~= 0
      or entry.width < 1
      or type(entry.height) ~= "number"
      or entry.height % 1 ~= 0
      or entry.height < 1
    then
      reject("asset " .. key .. " needs positive integral dimensions", {
        key = key,
      })
    end
    atlases[key] = { width = entry.width, height = entry.height }
  end
  checkDialogueFrames(demandSection(manifest, "dialogueFrames"), atlases)
  checkSignposts(demandSection(manifest, "signposts"), atlases)
  checkStartMenu(demandSection(manifest, "startMenu"), atlases)
  checkTrainerCard(demandSection(manifest, "trainerCard"), atlases)
  checkNamingScreen(demandSection(manifest, "namingScreen"), atlases)
  checkYesNoPrompt(demandSection(manifest, "yesNoPrompt"), atlases)
end

checkDialogueFrames = function(s, atlases)
  checkInteger(s.count, 1, nil, "dialogueFrames.count must be a positive integer", {})
  if type(s.frameTiles) ~= "table" then
    reject("dialogueFrames.frameTiles must be a table", {})
  end
  for frame = 0, s.count - 1 do
    checkStrip(
      s.frameTiles[frame],
      atlases,
      FieldUiAssetCache.ASSET.DIALOGUE_FRAME_TILES,
      "frame " .. frame .. " tiles",
      FieldUiAssetCache.GEOMETRY.FRAME_TILES * 8
    )
  end
  if type(s.palettes) ~= "table" then
    reject("dialogueFrames.palettes must be a table", {})
  end
  for frame = 0, s.count - 1 do
    local palette = s.palettes[frame]
    if type(palette) ~= "table" then
      reject("dialogue frame " .. frame .. " palette must be a table", { frame = frame })
    end
    -- A dialogue slot that is present but misshapen reports the same
    -- missing-slot diagnostic as an absent one.
    checkPalette16(palette, "dialogue frame " .. frame .. " palette", { frame = frame })
  end
  local standard = s.standardFrame
  if type(standard) ~= "table" then
    reject("dialogueFrames.standardFrame must be a table", {})
  end
  for key in pairs(standard) do
    if key ~= "frameTiles" and key ~= "palette" then
      reject("dialogueFrames.standardFrame has an unknown field", { field = key })
    end
  end
  demandCount(standard, 2, "dialogueFrames.standardFrame requires exactly frameTiles and palette", {})
  checkStrip(
    standard.frameTiles,
    atlases,
    FieldUiAssetCache.ASSET.DIALOGUE_FRAME_TILES,
    "standard Yes/No frame tiles",
    72
  )
  checkPalette16(standard.palette, "standard Yes/No frame palette")
  -- The single dialogue strip is the only frame authority: the same
  -- row rectangles index the one atlas for ordinary windows and
  -- application decoration alike.
  local cursor = s.continueCursor
  if type(cursor) ~= "table" then
    reject("dialogueFrames.continueCursor must be a table", {})
  end
  local cursorAsset = cursor.asset
  local asset = atlases[cursorAsset]
  if cursorAsset ~= FieldUiAssetCache.ASSET.DIALOGUE_CONTINUE_CURSOR or not asset then
    reject("dialogueFrames.continueCursor.asset is invalid", {})
  end
  if asset.width ~= 48 or asset.height ~= s.count * 16 then
    reject("dialogue continuation cursor atlas has invalid dimensions", {})
  end
  if type(cursor.cycle) ~= "table" or #cursor.cycle ~= 4 then
    reject("dialogue continuation cursor cycle is invalid", {})
  end
  for index = 1, 4 do
    checkInteger(cursor.cycle[index], 0, 2, "dialogue continuation cursor cycle must name phases 0..2", {})
  end
  checkInteger(cursor.framePrinterTicks, 1, nil, "dialogue continuation cursor timing must be positive", {})
  local placement = cursor.placement
  if type(placement) ~= "table" then
    reject("dialogue continuation cursor placement is invalid", {})
  end
  for _, field in ipairs(RECT_FIELDS) do
    checkInteger(placement[field], 0, nil, "dialogue continuation cursor placement " .. field .. " is invalid", {})
  end
  if placement.width == 0 or placement.height == 0 then
    reject("dialogue continuation cursor placement is invalid", {})
  end
  if type(cursor.styles) ~= "table" then
    reject("dialogue continuation cursor styles are missing", {})
  end
  for style = 0, s.count - 1 do
    local styleEntry = cursor.styles[style]
    if type(styleEntry) ~= "table" or type(styleEntry.phases) ~= "table" then
      reject("dialogue continuation cursor style is missing", { style = style })
    end
    for phase = 0, 2 do
      local rect = styleEntry.phases[phase]
      local expected = { x = phase * 16, y = style * 16, width = 16, height = 16 }
      if
        type(rect) ~= "table"
        or rect.x ~= expected.x
        or rect.y ~= expected.y
        or rect.width ~= expected.width
        or rect.height ~= expected.height
      then
        reject("dialogue continuation cursor phase is invalid", {
          style = style,
          phase = phase,
        })
      end
      checkAtlasRect(rect, atlases, cursorAsset, "dialogue continuation cursor phase")
    end
  end
end

checkSignposts = function(s, atlases)
  -- v5 schema requires textColors: the source palette slot assignments.
  if type(s.textColors) ~= "table" then
    reject("signposts.textColors must be a table", {})
  end
  for _, name in ipairs({ "foreground", "shadow", "background" }) do
    checkInteger(s.textColors[name], 0, 15, "signposts.textColors." .. name .. " must be an integral slot 0..15", {
      name = name,
      value = s.textColors[name],
    })
  end

  if type(s.types) ~= "table" then
    reject("signposts.types must be a table", {})
  end
  for key, typeEntry in pairs(s.types) do
    checkInteger(key, 0, nil, "signpost type keys must be non-negative integers", { key = key })
    if type(typeEntry) ~= "table" or typeEntry.sourceType ~= key then
      reject("signpost type entries must be keyed by their own sourceType", {
        key = key,
      })
    end

    -- v5: per-type palette (16 colors, 0..15, each with r/g/b 0..255).
    checkPalette16(typeEntry.palette, "signpost type " .. key .. " palette", { type = key })
    -- v5: per-type frameTiles (must be exactly 144x8 in the tiles atlas).
    if type(typeEntry.frameTiles) ~= "table" then
      reject("signpost type " .. key .. " frameTiles must be a table", {
        type = key,
      })
    end
    checkStrip(
      typeEntry.frameTiles,
      atlases,
      FieldUiAssetCache.ASSET.SIGNPOST_TILES,
      "signpost type " .. key .. " frameTiles",
      FieldUiAssetCache.GEOMETRY.FRAME_TILES * 8
    )

    if typeEntry.wayfinding ~= nil then
      -- A type either has per-map wayfinding or none: the producer omits
      -- the field for types without a map graphic, so an empty table is a
      -- producer bug, not a plausible contract state. Each wayfinding rect
      -- is a precomposed final 48x32 surface, not the old 192x8 strip.
      if type(typeEntry.wayfinding) ~= "table" or next(typeEntry.wayfinding) == nil then
        reject("signpost wayfinding must be a non-empty per-map table", {})
      end
      for map, rect in pairs(typeEntry.wayfinding) do
        checkInteger(map, 0, nil, "signpost wayfinding map keys must be non-negative integers", { map = map })
        checkAtlasRect(rect, atlases, FieldUiAssetCache.ASSET.SIGNPOST_WAYFINDING, "signpost wayfinding map " .. map)
        if
          rect.width ~= FieldUiAssetCache.GEOMETRY.WAYFINDING_WIDTH
          or rect.height ~= FieldUiAssetCache.GEOMETRY.WAYFINDING_HEIGHT
        then
          reject("signpost wayfinding map " .. map .. " must be the 48x32 final surface", {
            what = "signpost wayfinding map " .. map,
            width = rect.width,
            height = rect.height,
          })
        end
      end
    end
  end
end

checkStartMenu = function(s, atlases)
  checkAtlasRect(s.background, atlases, FieldUiAssetCache.ASSET.START_MENU_BACKGROUND, "start menu background")
  checkStartMenuCursor(s.cursor, atlases)
  checkStartMenuIconTable(s.iconTable, atlases)
  checkStartMenuIconPalette(s.iconPalette, s.pokeIcons, atlases)
  checkStartMenuContexts(s.contexts, s.iconTable)
  checkStartMenuActionIcons(s.actionIcons, s.iconTable)
  checkStartMenuInteractive(s.interactive)
  checkStartMenuChrome(s.chrome, atlases)
  checkStartMenuLabelPalette(s.labelPalette)
end

checkTrainerCard = function(s, atlases)
  checkAtlasRect(s.front, atlases, FieldUiAssetCache.ASSET.TRAINER_CARD_FRONT, "trainer card front")
end

-- Normal naming chrome: one opaque 256x192 base plus exactly the three
-- normal page overlays (upper, lower, symbols), each 256x112, drawn at the
-- canonical y=80 placement over the base. Every entry references its image
-- through the shared asset index by semantic id; the manifest carries no
-- source archive or member identities. The semantic layer adds the
-- source-window text geometry (the entered-name origin plus the five
-- thirteen-column keyboard text rows), the six OAM-composed controls with
-- their canonical anchors, the stepping keyboard cursor with its five
-- home-row variants, the stepping entry slots with normal/selected
-- visuals, and the anchored male/female player subjects. Every sprite
-- record draws at anchor plus the generated frame offset.
checkNamingScreen = function(s, atlases)
  checkNamingScreenBaseAndPlacement(s, atlases)
  checkNamingScreenText(s.text)
  checkNamingScreenControls(s.controls, atlases)
  checkNamingScreenCursor(s.cursor, atlases)
  checkNamingScreenEntrySlots(s.entrySlots, atlases)
  checkNamingScreenPlayerSubjects(s.playerSubjects, atlases)
  checkNamingScreenPokemonSubject(s.pokemonSubject)
  checkNamingScreenGenderMarkers(s.pokemonGenderMarkers, atlases)
end

-- The two-row choice prompt: exactly the compact shape, one 48x32 button
-- per row with a normal and a selected visual each. Every visual resolves
-- through the shared asset index by semantic id; the section carries no
-- source archive, member, tile, palette, or background identities.
checkYesNoPrompt = function(s, atlases)
  if type(s.shapes) ~= "table" then
    reject("yesNoPrompt.shapes must be a table", {})
  end
  demandCount(s.shapes, 1, "yesNoPrompt.shapes must carry exactly the compact shape", {})
  if type(s.shapes.compact) ~= "table" then
    reject("yesNoPrompt.shapes must carry exactly the compact shape", {})
  end
  local compact = s.shapes.compact
  if compact.width ~= FieldUiAssetCache.GEOMETRY.PROMPT_BUTTON_WIDTH then
    reject("the compact prompt width must be 48", {})
  end
  if compact.height ~= FieldUiAssetCache.GEOMETRY.PROMPT_BUTTON_HEIGHT then
    reject("the compact prompt height must be 32", {})
  end
  for _, row in ipairs({ "yes", "no" }) do
    local states = compact[row]
    if type(states) ~= "table" then
      reject("the compact prompt " .. row .. " row must be a table", { row = row })
    end
    for _, state in ipairs({ "normal", "selected" }) do
      local visual = states[state]
      if type(visual) ~= "table" then
        reject(
          "the compact prompt " .. row .. " row must carry its " .. state .. " visual",
          { row = row, state = state }
        )
      end
      if type(visual.asset) ~= "string" or atlases[visual.asset] == nil then
        reject(
          "the compact prompt " .. row .. " " .. state .. " visual must reference an indexed asset",
          { row = row, state = state }
        )
      end
      checkAtlasRect(visual.rect, atlases, visual.asset, "the compact prompt " .. row .. " " .. state .. " rect")
      if
        visual.rect.width ~= FieldUiAssetCache.GEOMETRY.PROMPT_BUTTON_WIDTH
        or visual.rect.height ~= FieldUiAssetCache.GEOMETRY.PROMPT_BUTTON_HEIGHT
      then
        reject(
          "the compact prompt " .. row .. " " .. state .. " rect must be the 48x32 button surface",
          { row = row, state = state }
        )
      end
    end
  end
  local forbidden = {
    member = true,
    memberId = true,
    narc = true,
    narcId = true,
    alias = true,
    fileId = true,
    bgId = true,
    tileStart = true,
    plttSlot = true,
    paletteSlot = true,
    sourcePath = true,
  }
  local function scan(value)
    if type(value) ~= "table" then
      return nil
    end
    for key, nested in pairs(value) do
      if type(key) == "string" and forbidden[key] then
        return key
      end
      local leaked = scan(nested)
      if leaked ~= nil then
        return leaked
      end
    end
    return nil
  end
  local leaked = scan(s)
  if leaked ~= nil then
    reject("the two-row prompt manifest leaks source detail", { field = leaked })
  end
end

checkStartMenuCursor = function(cursor, atlases)
  if type(cursor) ~= "table" or type(cursor.frames) ~= "table" or #cursor.frames < 1 then
    reject("startMenu.cursor must carry at least one frame", {})
  end
  for _, frameEntry in ipairs(cursor.frames) do
    checkAtlasRect(frameEntry, atlases, FieldUiAssetCache.ASSET.START_MENU_CURSOR, "start menu cursor frame")
    checkInteger(frameEntry.duration, 1, nil, "cursor frame duration must be a positive integer", {})
  end
end

checkStartMenuIconTable = function(iconTable, atlases)
  if type(iconTable) ~= "table" then
    reject("startMenu.iconTable must be a table", {})
  end
  demandCount(iconTable, 13, "startMenu.iconTable must carry all thirteen retail rows", {})
  for index = 1, 13 do
    checkStartMenuIconRow(iconTable[index], index, atlases)
  end
end

checkStartMenuIconRow = function(row, index, atlases)
  if type(row) ~= "table" then
    reject("startMenu.iconTable row " .. index .. " must be a table", {})
  end
  if VALID_ICON_ARTS[row.art] ~= true then
    reject("startMenu.iconTable row " .. index .. " art is invalid", {})
  end
  if row.art == "sprite" then
    for _, key in ipairs(ICON_STATES) do
      local visual = type(row.visual) == "table" and row.visual[key] or nil
      checkSpriteVisual(visual, atlases, "start menu icon row " .. index .. " " .. key .. " visual")
    end
  end
  checkInteger(row.label, 0, nil, "startMenu.iconTable row " .. index .. " label must be a label-bank id", {})
  if VALID_ICON_LABEL_KINDS[row.labelKind] ~= true then
    reject("startMenu.iconTable row " .. index .. " labelKind is invalid", {})
  end
  if row.variants ~= nil then
    if type(row.variants) ~= "table" then
      reject("startMenu.iconTable row " .. index .. " variants must be a table", {})
    end
    demandCount(row.variants, 1, "startMenu.iconTable row " .. index .. " carries only the female variant", {})
    if type(row.variants.female) ~= "table" then
      reject("startMenu.iconTable row " .. index .. " carries only the female variant", {})
    end
    for _, key in ipairs(ICON_STATES) do
      checkSpriteVisual(
        row.variants.female[key],
        atlases,
        "start menu icon row " .. index .. " female " .. key .. " visual"
      )
    end
  end
end

checkStartMenuIconPalette = function(palette, pokeIcons, atlases)
  if type(palette) ~= "table" or type(palette.asset) ~= "string" or atlases[palette.asset] == nil then
    reject("startMenu.iconPalette must reference an indexed asset", {})
  end
  if
    type(palette.banks) ~= "number"
    or palette.banks % 1 ~= 0
    or palette.banks < 1
    or type(palette.selectionBank) ~= "number"
    or palette.selectionBank % 1 ~= 0
    or palette.selectionBank < 1
    or palette.selectionBank > palette.banks
  then
    reject("startMenu.iconPalette banks are invalid", {})
  end
  if pokeIcons ~= nil then
    if type(pokeIcons) ~= "table" or type(pokeIcons.asset) ~= "string" or atlases[pokeIcons.asset] == nil then
      reject("startMenu.pokeIcons must reference an indexed asset", {})
    end
  end
end

checkStartMenuContexts = function(contexts, iconTable)
  if type(contexts) ~= "table" then
    reject("startMenu.contexts must be a table", {})
  end
  demandCount(contexts, 7, "startMenu.contexts must carry all seven retail rows", {})
  for index = 1, 7 do
    local row = contexts[index]
    if type(row) ~= "table" then
      reject("startMenu.contexts row " .. index .. " must be a table", {})
    end
    demandCount(row, 7, "startMenu.contexts row " .. index .. " must map one icon per sprite slot", {})
    for slot = 1, 7 do
      local icon = row[slot]
      if icon ~= false then
        if type(icon) ~= "number" or icon % 1 ~= 0 or icon < 0 or icon > 12 or iconTable[icon + 1] == nil then
          reject("startMenu.contexts row " .. index .. " entry " .. slot .. " is invalid", {})
        end
      end
    end
  end
end

checkStartMenuActionIcons = function(actionIcons, iconTable)
  if type(actionIcons) ~= "table" then
    reject("startMenu.actionIcons must be a table", {})
  end
  for actionId, icon in pairs(actionIcons) do
    if type(actionId) ~= "string" then
      reject("startMenu.actionIcons keys must be action ids", {})
    end
    local row = type(icon) == "number" and iconTable[icon + 1] or nil
    if row == nil or row.art ~= "sprite" then
      reject("startMenu.actionIcons " .. actionId .. " must map to a sprite icon row", {})
    end
  end
end

-- The normal interactive selector: exactly the seven source positions 0..6,
-- each carrying its action anchor, label window, touch hit rectangle, and
-- four ordered three-candidate navigation lists, plus the cancel/header hit
-- rectangle. Anchors are integral canonical points; label and hit rectangles
-- stay inside the canonical 256x192 surface; every candidate names a normal
-- position.
checkStartMenuInteractive = function(interactive)
  if type(interactive) ~= "table" then
    reject("startMenu.interactive must be a table", {})
  end
  checkRect(
    interactive.cancelHitRect,
    "start menu cancel hit rectangle",
    256,
    192,
    "start menu cancel hit rectangle must stay inside the 256x192 surface",
    {
      what = "start menu cancel hit rectangle",
    }
  )
  if type(interactive.positions) ~= "table" then
    reject("startMenu.interactive.positions must be a table", {})
  end
  demandCount(interactive.positions, 7, "startMenu.interactive must carry exactly the seven normal positions", {})
  for position = 0, 6 do
    checkStartMenuInteractivePosition(interactive.positions[position], position)
  end
end

checkStartMenuInteractivePosition = function(record, position)
  if type(record) ~= "table" then
    reject("startMenu.interactive position " .. position .. " must be a table", {})
  end
  if
    type(record.anchor) ~= "table"
    or type(record.anchor.x) ~= "number"
    or record.anchor.x % 1 ~= 0
    or type(record.anchor.y) ~= "number"
    or record.anchor.y % 1 ~= 0
  then
    reject("startMenu.interactive position " .. position .. " anchor must be an integral point", {})
  end
  local labelWhat = "start menu position " .. position .. " label window"
  checkRect(record.labelWindow, labelWhat, 256, 192, labelWhat .. " must stay inside the 256x192 surface", {
    what = labelWhat,
  })
  local hitWhat = "start menu position " .. position .. " hit rectangle"
  checkRect(record.hitRect, hitWhat, 256, 192, hitWhat .. " must stay inside the 256x192 surface", {
    what = hitWhat,
  })
  if type(record.navigation) ~= "table" then
    reject("startMenu.interactive position " .. position .. " navigation must be a table", {})
  end
  demandCount(
    record.navigation,
    4,
    "startMenu.interactive position " .. position .. " carries four navigation directions",
    {}
  )
  for _, direction in ipairs(NAV_DIRECTIONS) do
    local candidates = record.navigation[direction]
    if type(candidates) ~= "table" or #candidates ~= 3 then
      reject("startMenu.interactive position " .. position .. " " .. direction .. " must list three candidates", {})
    end
    for _, candidate in ipairs(candidates) do
      checkInteger(
        candidate,
        0,
        6,
        "startMenu.interactive position " .. position .. " " .. direction .. " candidates must name normal positions 0..6",
        {}
      )
    end
  end
end

checkStartMenuChrome = function(chrome, atlases)
  if type(chrome) ~= "table" or type(chrome.main) ~= "table" or type(chrome.sub) ~= "table" then
    reject("startMenu.chrome must carry its main and sub sets", {})
  end
  for _, key in ipairs({ "main", "sub" }) do
    local set = chrome[key]
    if type(set.asset) ~= "string" or atlases[set.asset] == nil then
      reject("startMenu.chrome." .. key .. " must reference an indexed asset", {})
    end
  end
  checkInteger(chrome.main.transparentAboveY, 1, nil, "startMenu.chrome.main must name its transparency boundary", {})
end

-- The Start Menu label palette is a required generated record: the source
-- label-window roles as byte RGB with compositing alpha. Ink stays opaque
-- while the background stays transparent, so glyph background-class pixels
-- reveal the already-rendered chrome instead of repainting it.
checkStartMenuLabelPalette = function(labelPalette)
  if type(labelPalette) ~= "table" then
    reject("startMenu.labelPalette must be a table", {})
  end
  demandCount(labelPalette, 3, "startMenu.labelPalette must carry exactly foreground, shadow, and background", {})
  if labelPalette.foreground == nil or labelPalette.shadow == nil or labelPalette.background == nil then
    reject("startMenu.labelPalette must carry exactly foreground, shadow, and background", {})
  end
  checkLabelRole(labelPalette, "foreground", 1)
  checkLabelRole(labelPalette, "shadow", 1)
  checkLabelRole(labelPalette, "background", 0)
end

checkNamingScreenBaseAndPlacement = function(s, atlases)
  if type(s.base) ~= "table" then
    reject("namingScreen.base must be a table", {})
  end
  local baseAsset = atlases[s.base.asset]
  if type(s.base.asset) ~= "string" or not baseAsset then
    reject("namingScreen.base must reference an indexed asset", {})
  end
  if s.base.width ~= 256 or s.base.height ~= 192 or baseAsset.width ~= 256 or baseAsset.height ~= 192 then
    reject("namingScreen.base must be the opaque 256x192 surface", {})
  end
  if type(s.pages) ~= "table" then
    reject("namingScreen.pages must be a table", {})
  end
  local pageKeys = { "upper", "lower", "symbols" }
  demandCount(s.pages, #pageKeys, "namingScreen.pages must carry exactly upper, lower, and symbols", {})
  for _, key in ipairs(pageKeys) do
    local page = s.pages[key]
    if type(page) ~= "table" then
      reject("namingScreen.pages." .. key .. " must be a table", {})
    end
    local pageAsset = atlases[page.asset]
    if type(page.asset) ~= "string" or not pageAsset then
      reject("namingScreen.pages." .. key .. " must reference an indexed asset", {})
    end
    if page.width ~= 256 or page.height ~= 112 or pageAsset.width ~= 256 or pageAsset.height ~= 112 then
      reject("namingScreen.pages." .. key .. " must be the 256x112 overlay", {})
    end
  end
  local placement = s.placement
  if
    type(placement) ~= "table"
    or placement.x ~= 11
    or placement.y ~= 80
    or placement.width ~= 256
    or placement.height ~= 112
  then
    reject("namingScreen.placement must be the x=11 y=80 overlay", {})
  end
end

checkNamingScreenText = function(text)
  if type(text) ~= "table" then
    reject("namingScreen.text must be a table", {})
  end
  if type(text.name) ~= "table" or text.name.x ~= 80 or text.name.y ~= 24 or text.name.advanceX ~= 12 then
    reject("namingScreen.text.name must be the (80,24)+12px entry origin", {})
  end
  if type(text.keyboard) ~= "table" or type(text.keyboard.cells) ~= "table" then
    reject("namingScreen.text.keyboard.cells must be a table", {})
  end
  demandCount(text.keyboard.cells, 5, "namingScreen.text.keyboard must carry five source rows", {})
  for row = 1, 5 do
    local cells = text.keyboard.cells[row]
    if type(cells) ~= "table" then
      reject("namingScreen.text.keyboard row " .. row .. " is missing", {})
    end
    demandCount(cells, 13, "namingScreen.text.keyboard row " .. row .. " must carry thirteen cells", {})
    for column = 1, 13 do
      local cell = cells[column]
      if
        type(cell) ~= "table"
        or not Validate.isNonNegativeInteger(cell.x)
        or not Validate.isNonNegativeInteger(cell.y)
        or cell.width ~= 16
        or cell.x + cell.width > 256
        or cell.y > 191
      then
        reject("namingScreen.text.keyboard row " .. row .. " column " .. column .. " must be a 16px canonical cell", {})
      end
    end
  end
end

checkNamingScreenControls = function(controls, atlases)
  if type(controls) ~= "table" then
    reject("namingScreen.controls must be a table", {})
  end
  demandCount(controls, 6, "namingScreen.controls must carry six source visuals", {})
  for id, anchor in pairs(NAMING_CONTROL_ANCHORS) do
    checkNamingSprite(controls[id], atlases, "namingScreen.controls." .. id)
    local recordAnchor = controls[id].anchor
    if recordAnchor.x ~= anchor.x or recordAnchor.y ~= anchor.y then
      reject("namingScreen.controls." .. id .. " must keep its source anchor", {})
    end
  end
end

checkNamingScreenCursor = function(cursor, atlases)
  if type(cursor) ~= "table" then
    reject("namingScreen.cursor must be a table", {})
  end
  local keyboardCursor = cursor.keyboard
  checkAnimationRecord(keyboardCursor, atlases, "namingScreen.cursor.keyboard", true)
  if
    type(keyboardCursor.origin) ~= "table"
    or keyboardCursor.origin.x ~= 26
    or keyboardCursor.origin.y ~= 91
    or keyboardCursor.stepX ~= 16
    or keyboardCursor.stepY ~= 19
  then
    reject("namingScreen.cursor.keyboard must step 16px by 19px from (26,91)", {})
  end
  if type(cursor.home) ~= "table" then
    reject("namingScreen.cursor.home must be a table", {})
  end
  demandCount(cursor.home, 5, "namingScreen.cursor.home must carry five control variants", {})
  for _, id in ipairs({ "upper", "lower", "symbols", "back", "ok" }) do
    checkAnimationRecord(cursor.home[id], atlases, "namingScreen.cursor.home." .. id, true)
    checkCanonicalPoint(cursor.home[id].anchor, "namingScreen.cursor.home." .. id .. " anchor")
  end
end

checkNamingScreenEntrySlots = function(entrySlots, atlases)
  if type(entrySlots) ~= "table" then
    reject("namingScreen.entrySlots must be a table", {})
  end
  if
    type(entrySlots.origin) ~= "table"
    or entrySlots.origin.x ~= 80
    or entrySlots.origin.y ~= 39
    or entrySlots.stepX ~= 12
  then
    reject("namingScreen.entrySlots must start at (80,39) stepping 12px", {})
  end
  checkNamingSprite(entrySlots.normal, atlases, "namingScreen.entrySlots.normal")
  checkAnimationRecord(entrySlots.selected, atlases, "namingScreen.entrySlots.selected", false)
end

checkNamingScreenPlayerSubjects = function(playerSubjects, atlases)
  if type(playerSubjects) ~= "table" then
    reject("namingScreen.playerSubjects must be a table", {})
  end
  demandCount(playerSubjects, 2, "namingScreen.playerSubjects must carry male and female", {})
  for _, id in ipairs({ "male", "female" }) do
    checkAnimationRecord(playerSubjects[id], atlases, "namingScreen.playerSubjects." .. id, false)
    local anchor = playerSubjects[id].anchor
    if type(anchor) ~= "table" or anchor.x ~= 24 or anchor.y ~= 8 then
      reject("namingScreen.playerSubjects." .. id .. " must anchor at (24,8)", {})
    end
  end
end

checkNamingScreenPokemonSubject = function(pokemonSubject)
  if type(pokemonSubject) ~= "table" then
    reject("namingScreen.pokemonSubject must be a table", {})
  end
  checkSignedPoint(pokemonSubject.anchor, "namingScreen.pokemonSubject anchor must be a signed integer point")
  if ANIMATION_PLAY_MODES[pokemonSubject.playMode] ~= true then
    reject("namingScreen.pokemonSubject carries an unsupported play mode", {})
  end
  if type(pokemonSubject.frames) ~= "table" then
    reject("namingScreen.pokemonSubject must carry animation frames", {})
  end
  local pokemonFrameCount = demandDenseSequence(
    pokemonSubject.frames,
    "namingScreen.pokemonSubject frames must be a dense nonempty sequence",
    {}
  )
  checkInteger(
    pokemonSubject.loopStartFrameIdx,
    0,
    pokemonFrameCount - 1,
    "namingScreen.pokemonSubject loop start is outside its frames",
    {}
  )
  for index = 1, pokemonFrameCount do
    checkNamingScreenPokemonSubjectFrame(pokemonSubject.frames[index], index)
  end
end

checkNamingScreenPokemonSubjectFrame = function(frame, index)
  local frameWhat = "namingScreen.pokemonSubject frame " .. index
  if type(frame) ~= "table" then
    reject(frameWhat .. " must be a table", {})
  end
  checkInteger(frame.duration, 1, nil, frameWhat .. " has an invalid duration", {})
  if type(frame.parts) ~= "table" then
    reject(frameWhat .. " must carry icon parts", {})
  end
  local partCount = demandDenseSequence(frame.parts, frameWhat .. " must carry a dense nonempty part sequence", {})
  for partIndex = 1, partCount do
    checkNamingScreenPokemonSubjectPart(frame.parts[partIndex], frameWhat .. " part " .. partIndex)
  end
  if frame.offset ~= nil or frame.iconFrame ~= nil or frame.asset ~= nil or frame.rect ~= nil then
    reject("namingScreen.pokemonSubject frames carry no flattened icon record", {})
  end
end

checkNamingScreenPokemonSubjectPart = function(part, partWhat)
  if
    type(part) ~= "table"
    or part.iconFrame ~= 1
    or type(part.offset) ~= "table"
    or not isSignedInteger(part.offset.x)
    or not isSignedInteger(part.offset.y)
  then
    reject(partWhat .. " is invalid", {})
  end
  if
    part.asset ~= nil
    or part.image ~= nil
    or part.rect ~= nil
    or part.pulseRect ~= nil
    or part.width ~= nil
    or part.height ~= nil
  then
    reject(partWhat .. " carries generated pixels", {})
  end
end

checkNamingScreenGenderMarkers = function(genderMarkers, atlases)
  if type(genderMarkers) ~= "table" then
    reject("namingScreen.pokemonGenderMarkers must be a table", {})
  end
  checkSignedPoint(genderMarkers.anchor, "namingScreen.pokemonGenderMarkers anchor must be a signed integer point")
  for _, gender in ipairs({ "male", "female" }) do
    checkAnimationRecord(genderMarkers[gender], atlases, "namingScreen.pokemonGenderMarkers." .. gender, false)
  end
end

-- Below this point are the generic, source-independent validation
-- primitives: the most reusable and least specific to this file's own
-- domain, so they sit last, under every function that uses them.

demandSection = function(manifest, name)
  local sectionData = manifest[name]
  if type(sectionData) ~= "table" then
    reject("manifest section " .. name .. " must be a table", {
      section = name,
    })
  end
  return sectionData
end

-- One generated animation record: decoded playback mode, zero-based
-- loop start, and dense frames each naming an indexed atlas rect with
-- the compositor offset and a positive duration. Cursor records
-- additionally name their pulse-mask atlas and carry a same-size mask
-- rect per frame; subject records carry no pulse fields.
checkAnimationRecord = function(record, atlases, what, isCursor)
  if type(record) ~= "table" then
    reject(what .. " must be a table", { what = what })
  end
  if ANIMATION_PLAY_MODES[record.playMode] ~= true then
    reject(what .. " carries an unsupported play mode", { what = what })
  end
  if type(record.frames) ~= "table" then
    reject(what .. " must carry animation frames", { what = what })
  end
  local frameCount = demandDenseSequence(record.frames, what .. " frames must be a dense sequence", { what = what })
  checkInteger(record.loopStartFrameIdx, 0, frameCount - 1, what .. " loop start is outside its frames", {
    what = what,
  })
  local pulseAsset = nil
  if isCursor then
    pulseAsset = record.pulseAsset
    if type(pulseAsset) ~= "string" or atlases[pulseAsset] == nil then
      reject(what .. " must reference its indexed pulse-mask atlas", { what = what })
    end
  elseif record.pulseAsset ~= nil then
    reject(what .. " carries no pulse-mask role", { what = what })
  end
  for index = 1, frameCount do
    local frame = record.frames[index]
    local frameWhat = what .. " frame " .. index
    if type(frame) ~= "table" then
      reject(frameWhat .. " must be a table", { what = frameWhat })
    end
    if type(frame.asset) ~= "string" or atlases[frame.asset] == nil then
      reject(frameWhat .. " must reference an indexed atlas", { what = frameWhat })
    end
    checkAtlasRect(frame.rect, atlases, frame.asset, frameWhat .. " rect")
    checkFrameOffset(frame.offset, frameWhat .. " must carry the generated frame offset", { what = frameWhat })
    checkInteger(frame.duration, 1, nil, frameWhat .. " duration must be a positive integer", { what = frameWhat })
    if isCursor then
      checkAtlasRect(frame.pulseRect, atlases, pulseAsset, frameWhat .. " pulse rect")
      if frame.pulseRect.width ~= frame.rect.width or frame.pulseRect.height ~= frame.rect.height then
        reject(frameWhat .. " pulse rect must match its frame size", { what = frameWhat })
      end
    elseif frame.pulseRect ~= nil then
      reject(frameWhat .. " carries no pulse-mask role", { what = frameWhat })
    end
  end
end

-- One OAM-composed visual: a generated image drawn at its canonical
-- anchor plus the compositor's frame offset. The asset must be indexed
-- with matching dimensions; the offset may be negative (a cell whose
-- objects start below the source origin shifts the frame).
checkNamingSprite = function(record, atlases, what)
  if type(record) ~= "table" then
    reject(what .. " must be a table", { what = what })
  end
  local asset = atlases[record.asset]
  if type(record.asset) ~= "string" or not asset then
    reject(what .. " must reference an indexed asset", { what = what })
  end
  if record.width ~= asset.width or record.height ~= asset.height then
    reject(what .. " dimensions must match its indexed asset", { what = what })
  end
  if record.width < 1 or record.height < 1 then
    reject(what .. " must be non-empty", { what = what })
  end
  checkCanonicalPoint(record.anchor, what .. " anchor")
  checkFrameOffset(record.offset, what .. " must carry the generated frame offset", { what = what })
end

checkSignedPoint = function(point, message)
  if type(point) ~= "table" or not isSignedInteger(point.x) or not isSignedInteger(point.y) then
    reject(message, {})
  end
end

-- One signed integral coordinate: icon parts and Pokemon anchors may extend
-- left/up of their source origin, so only finite integrality is required.
isSignedInteger = function(value)
  return type(value) == "number" and value % 1 == 0 and value ~= math.huge and value ~= -math.huge
end

checkCanonicalPoint = function(point, what)
  if
    type(point) ~= "table"
    or not Validate.isNonNegativeInteger(point.x)
    or not Validate.isNonNegativeInteger(point.y)
  then
    reject(what .. " must be a canonical integer point", { what = what })
  end
end

checkLabelRole = function(labelPalette, role, expectedAlpha)
  local color = labelPalette[role]
  if type(color) ~= "table" then
    reject("startMenu.labelPalette." .. role .. " must be a table", {})
  end
  for _, component in ipairs(RGB_CHANNELS) do
    checkInteger(
      color[component],
      0,
      255,
      "startMenu.labelPalette." .. role .. "." .. component .. " must be an integral byte 0..255",
      {}
    )
  end
  if color.a ~= expectedAlpha then
    reject("startMenu.labelPalette." .. role .. " alpha must be " .. expectedAlpha .. " for label compositing", {})
  end
end

-- One composed sprite visual: an indexed atlas asset, a non-negative
-- in-atlas rect, and the compositor's frame offset. The offset is a
-- signed integral pair: a frame may extend left/up of its source anchor.
checkSpriteVisual = function(visual, atlases, what)
  if type(visual) ~= "table" then
    reject(what .. " must be a table", { what = what })
  end
  if type(visual.asset) ~= "string" or atlases[visual.asset] == nil then
    reject(what .. " must reference an indexed asset", { what = what })
  end
  checkAtlasRect(visual.rect, atlases, visual.asset, what .. " rect")
  checkFrameOffset(visual.offset, what .. " must carry an integral frame offset", { what = what })
end

-- One generated frame offset: a signed integral pair. A frame may extend
-- left/up of its source anchor, so only integrality is required here.
checkFrameOffset = function(offset, message, context)
  if
    type(offset) ~= "table"
    or type(offset.x) ~= "number"
    or offset.x % 1 ~= 0
    or type(offset.y) ~= "number"
    or offset.y % 1 ~= 0
  then
    reject(message, context)
  end
end

-- Rejects unless `t` is a dense, non-empty array (no holes, no non-integer
-- keys). Returns its length. Animation frame lists and per-frame icon
-- parts share this shape.
demandDenseSequence = function(t, message, context)
  local count = 0
  for _ in pairs(t) do
    count = count + 1
  end
  if count == 0 or count ~= #t then
    reject(message, context)
  end
  return count
end

-- Rejects unless `palette` carries exactly slots 0..15, each an integral
-- byte-RGB color. Dialogue frames, the standard Yes/No frame, and every
-- signpost type share this exact 16-slot palette shape. `extraContext`
-- fields (such as the owning frame/type) are merged into every reported
-- diagnostic alongside the failing slot.
checkPalette16 = function(palette, what, extraContext)
  if type(palette) ~= "table" then
    reject(what .. " must be a table", {})
  end
  local function context(slot)
    local merged = { slot = slot }
    if extraContext ~= nil then
      for key, value in pairs(extraContext) do
        merged[key] = value
      end
    end
    return merged
  end
  for slot = 0, 15 do
    local missing = what .. " slot " .. slot .. " is missing"
    checkByteColor(
      palette[slot],
      missing,
      missing,
      what .. " slot " .. slot .. " must have byte RGB",
      context(slot),
      "component"
    )
  end
  for slot in pairs(palette) do
    checkInteger(slot, 0, 15, what .. " has an invalid slot", context(slot))
  end
end

-- Rejects unless `t` has exactly `count` pairs. The generated manifest names
-- several fixed-size tables (retail row/context/position counts, navigation
-- direction sets, per-record field sets); this is their single shared arity
-- gate instead of a repeated counting loop per call site.
demandCount = function(t, count, message, context)
  local actual = 0
  for _ in pairs(t) do
    actual = actual + 1
  end
  if actual ~= count then
    reject(message, context)
  end
end

-- A rect must be an exact HGSS strip (`width` x 8) inside its atlas.
-- Dialogue/signpost frames are the 18-tile 144x8 row; wayfinding rects
-- are validated separately as 48x32 final surfaces. The atlas-bound check
-- additionally proves the rect is addressable in its PNG.
checkStrip = function(rect, atlases, atlasKey, what, width)
  checkAtlasRect(rect, atlases, atlasKey, what)
  if rect.width ~= width or rect.height ~= 8 then
    reject(what .. " must be the " .. width .. "x8 HGSS strip", {
      what = what,
      width = rect.width,
      height = rect.height,
    })
  end
end

checkAtlasRect = function(rect, atlases, atlasKey, what)
  local atlas = atlases[atlasKey]
  local message = what .. " escapes its atlas " .. atlasKey
  local context = { what = what, atlas = atlasKey }
  if atlas == nil then
    reject(message, context)
  else
    checkRect(rect, what, atlas.width, atlas.height, message, context)
  end
end

checkRect = function(rect, what, limitWidth, limitHeight, outsideMessage, outsideContext)
  if type(rect) ~= "table" then
    reject(what .. " must be a rectangle", { what = what })
  end
  for _, field in ipairs(RECT_FIELDS) do
    checkInteger(rect[field], 0, nil, what .. " " .. field .. " must be a non-negative integer", {
      what = what,
      field = field,
    })
  end
  if rect.width == 0 or rect.height == 0 then
    reject(what .. " must be non-empty", { what = what })
  end
  if rect.x + rect.width > limitWidth or rect.y + rect.height > limitHeight then
    reject(outsideMessage, outsideContext)
  end
end

-- Rejects unless `color` carries integral byte RGB channels. An absent
-- slot reports `nilMessage`; a present-but-misshapen slot reports
-- `shapeMessage`; a bad channel reports `channelMessage`. `context`
-- carries the fixed diagnostic fields and gains the failing channel under
-- `channelKey` when one is named.
checkByteColor = function(color, nilMessage, shapeMessage, channelMessage, context, channelKey)
  if color == nil then
    reject(nilMessage, context)
  end
  if type(color) ~= "table" then
    reject(shapeMessage, context)
  end
  for _, channel in ipairs(RGB_CHANNELS) do
    local value = color[channel]
    if type(value) ~= "number" or value % 1 ~= 0 or value < 0 or value > 255 then
      if channelKey ~= nil then
        local failure = { [channelKey] = channel }
        for key, entry in pairs(context) do
          failure[key] = entry
        end
        reject(channelMessage, failure)
      end
      reject(channelMessage, context)
    end
  end
end

-- Single scalar gate: every integral domain in this validator funnels
-- through here. Unbounded non-negative integers reuse the shared predicate;
-- any other bound stays explicit per domain.
checkInteger = function(value, minimum, maximum, message, context)
  local valid
  if minimum == 0 and maximum == nil then
    valid = Validate.isNonNegativeInteger(value)
  else
    valid = type(value) == "number"
      and value % 1 == 0
      and (minimum == nil or value >= minimum)
      and (maximum == nil or value <= maximum)
  end
  if not valid then
    reject(message, context)
  end
end

---@param message string
---@param context Errors.Context?
---@noreturn
reject = function(message, context)
  Errors.raise(MANIFEST_INVALID, message, context)
end

return FieldUiAssetCache
