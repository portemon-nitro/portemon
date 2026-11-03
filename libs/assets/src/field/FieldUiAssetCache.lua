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
local Contract = require("libs.assets.src.DerivedAssetContract")
local Checks = require("libs.assets.src.field.FieldUiManifestChecks")
local StartMenuValidation = require("libs.assets.src.field.FieldUiStartMenuValidation")
local NamingValidation = require("libs.assets.src.field.FieldUiNamingValidation")

local reject = Checks.reject
local checkInteger = Checks.checkInteger
local checkAtlasRect = Checks.checkAtlasRect
local checkStrip = Checks.checkStrip
local checkPalette16 = Checks.checkPalette16
local demandCount = Checks.demandCount
local demandDenseSequence = Checks.demandDenseSequence
local checkFrameOffset = Checks.checkFrameOffset
local checkSignedPoint = Checks.checkSignedPoint
local RECT_FIELDS = Checks.RECT_FIELDS

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
  START_MENU_ICONS = "hgss.start_menu.icons",
  START_MENU_ICON_PALETTE = "hgss.start_menu.icon_palette",
  START_MENU_RINGING = "hgss.start_menu.ringing",
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
  NAMING_SCREEN_CONTROL_UPPER_SELECTED = "hgss.naming_screen.control_upper_selected",
  NAMING_SCREEN_CONTROL_LOWER_SELECTED = "hgss.naming_screen.control_lower_selected",
  NAMING_SCREEN_CONTROL_SYMBOLS_SELECTED = "hgss.naming_screen.control_symbols_selected",
  NAMING_SCREEN_CONTROL_BACK_PRESSED = "hgss.naming_screen.control_back_pressed",
  NAMING_SCREEN_CONTROL_OK_PRESSED = "hgss.naming_screen.control_ok_pressed",
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
  OPTIONS_CHROME = "hgss.options.chrome",
  OPTIONS_CONTROLS_BACKGROUND = "hgss.options.controls_background",
  OPTIONS_PREVIEW_BACKGROUND = "hgss.options.preview_background",
  OPTIONS_SELECTION_OVERLAY = "hgss.options.selection_overlay",
  OPTIONS_ROW_ODD = "hgss.options.row_odd",
  OPTIONS_ROW_EVEN = "hgss.options.row_even",
  OPTIONS_ROW_FRAME = "hgss.options.row_frame",
}

-- One error code for every malformed generated class: the manifest is the
-- single strict structural boundary, so all violations share the code while
-- the message names the exact broken field.
local MANIFEST_INVALID = Checks.MANIFEST_INVALID

local DATA_DIR = "data/generated/field/ui"
local ASSET_DIR = "assets/generated/field/ui"

-- Strict manifest validation: required arrays, strict enums, and every
-- rectangle/size/index finite, integral, non-negative, and inside its
-- atlas. Private checks reject malformed data through one owned error;
-- validateManifest is the only boundary that translates it into the public
-- false-plus-error result, so unrelated failures still propagate to the
-- caller. Validation reports the first violation in section order and never
-- mutates the manifest.
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

local function checkDialogueFrames(s, atlases)
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

local function checkSignposts(s, atlases)
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

local function checkTrainerCard(s, atlases)
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
local function checkYesNoPrompt(s, atlases)
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

-- The generated option-control section: the semantic labels with their
-- lowered token streams, the small/wide choice pills with their
-- unselected baseline faces, the left/right frame arrows, the footer
-- action chrome, and the frame preview text. Every visual state is a
-- sequence with logical union bounds and ordered frames carrying the atlas
-- image, the packed atlas rectangle, the signed source-cell offset, and
-- the integer source tick duration; looping versus one-shot termination is
-- explicit. The tick rate records the native display-frame duration, not
-- a guessed loop timing. The manifest carries no source archive or member
-- identities.
local function checkOptionsLabel(record, what)
  if type(record) ~= "table" then
    reject(what .. " must be a table", { what = what })
  end
  demandCount(record, 2, what .. " must carry exactly its display text and token stream", { what = what })
  if type(record.text) ~= "string" or record.text == "" then
    reject(what .. " must carry non-empty display text", { what = what })
  end
  if type(record.tokens) ~= "table" or #record.tokens == 0 then
    reject(what .. " must carry a non-empty token stream", { what = what })
  end
end

-- Option-control frames name their packed atlas by generated image path, not
-- by asset id, so resolve the path to its indexed asset before the shared
-- atlas-bound check. The image path stays the draw-time lookup the pooled
-- lease was acquired with.
local function optionsAtlasKey(assets, image, frameWhat)
  if type(image) ~= "string" or image == "" then
    reject(frameWhat .. " must name its atlas image path", { what = frameWhat })
  end
  for key, entry in pairs(assets) do
    if type(entry) == "table" and entry.image == image then
      return key
    end
  end
  reject(frameWhat .. " must reference an indexed asset", { what = frameWhat })
end

local function checkOptionsSequence(sequence, what, atlases, assets)
  if type(sequence) ~= "table" then
    reject(what .. " must be a table", { what = what })
  end
  demandCount(sequence, 3, what .. " must carry exactly its frames, loop flag, and bounds", { what = what })
  if type(sequence.loop) ~= "boolean" then
    reject(what .. " loop must be a boolean", { what = what })
  end
  local bounds = sequence.bounds
  if type(bounds) ~= "table" then
    reject(what .. " bounds must be a table", { what = what })
  end
  demandCount(bounds, 4, what .. " bounds must carry exactly its origin and extent", { what = what })
  checkSignedPoint({ x = bounds.x, y = bounds.y }, what .. " bounds origin must be a signed integral point")
  checkInteger(bounds.width, 1, nil, what .. " bounds width must be a positive integer", {})
  checkInteger(bounds.height, 1, nil, what .. " bounds height must be a positive integer", {})
  if type(sequence.frames) ~= "table" then
    reject(what .. " frames must be a table", { what = what })
  end
  local count = demandDenseSequence(sequence.frames, what .. " frames must be a dense non-empty array", {})
  local total = 0
  for index = 1, count do
    local frame = sequence.frames[index]
    local frameWhat = what .. " frame " .. index
    if type(frame) ~= "table" then
      reject(frameWhat .. " must be a table", { what = frameWhat })
    end
    demandCount(frame, 4, frameWhat .. " must carry exactly its image, atlas, offset, and ticks", {})
    local atlasKey = optionsAtlasKey(assets, frame.image, frameWhat)
    checkAtlasRect(frame.atlas, atlases, atlasKey, frameWhat .. " atlas rect")
    checkFrameOffset(frame.offset, frameWhat .. " must carry an integral frame offset", { what = frameWhat })
    checkInteger(frame.ticks, 0, nil, frameWhat .. " ticks must be a non-negative integer", {})
    total = total + frame.ticks
  end
  if total == 0 then
    reject(what .. " animation must advance", { what = what })
  end
end

local function checkOptions(s, atlases, assets)
  if type(s.version) ~= "number" or s.version ~= 4 then
    reject("options.version must be 4", { version = s.version })
  end
  demandCount(
    s,
    10,
    "options must carry exactly its version, backdrops, row plates, selection overlay, labels, choices, arrows, actions, frame previews, and tick rate",
    {}
  )
  local backdrops = s.backdrops
  if type(backdrops) ~= "table" then
    reject("options.backdrops must be a table", {})
  end
  demandCount(backdrops, 2, "options.backdrops must carry exactly the controls and preview roles", {})
  local expectedRoles = {
    controls = FieldUiAssetCache.ASSET.OPTIONS_CONTROLS_BACKGROUND,
    preview = FieldUiAssetCache.ASSET.OPTIONS_PREVIEW_BACKGROUND,
  }
  for role, assetKey in pairs(expectedRoles) do
    if backdrops[role] ~= assetKey then
      reject("options.backdrops." .. role .. " must reference its indexed backdrop asset", {
        role = role,
        value = backdrops[role],
      })
    end
    local dims = atlases[assetKey]
    if type(dims) ~= "table" then
      reject("options.backdrops." .. role .. " must reference an indexed asset", { role = role })
    end
    if dims.width ~= 256 or dims.height ~= 192 then
      reject("options.backdrops." .. role .. " must be the 256x192 field screen", {
        role = role,
        width = dims.width,
        height = dims.height,
      })
    end
  end
  for role in pairs(backdrops) do
    if expectedRoles[role] == nil then
      reject("options.backdrops carries an unknown role", { role = role })
    end
  end
  local rowBackings = s.rowBackings
  if type(rowBackings) ~= "table" then
    reject("options.rowBackings must be a table", {})
  end
  demandCount(rowBackings, 3, "options.rowBackings must carry exactly the odd, even, and frame plates", {})
  local expectedPlates = {
    odd = { key = FieldUiAssetCache.ASSET.OPTIONS_ROW_ODD, height = 24 },
    even = { key = FieldUiAssetCache.ASSET.OPTIONS_ROW_EVEN, height = 24 },
    frame = { key = FieldUiAssetCache.ASSET.OPTIONS_ROW_FRAME, height = 64 },
  }
  for role, plate in pairs(expectedPlates) do
    if rowBackings[role] ~= plate.key then
      reject("options.rowBackings." .. role .. " must reference its indexed row plate asset", {
        role = role,
        value = rowBackings[role],
      })
    end
    local dims = atlases[plate.key]
    if type(dims) ~= "table" then
      reject("options.rowBackings." .. role .. " must reference an indexed asset", { role = role })
    end
    if dims.width ~= 256 or dims.height ~= plate.height then
      reject("options.rowBackings." .. role .. " must be the 256-wide scrolling plate", {
        role = role,
        width = dims.width,
        height = dims.height,
      })
    end
  end
  for role in pairs(rowBackings) do
    if expectedPlates[role] == nil then
      reject("options.rowBackings carries an unknown role", { role = role })
    end
  end
  if s.selectionOverlay ~= FieldUiAssetCache.ASSET.OPTIONS_SELECTION_OVERLAY then
    reject("options.selectionOverlay must reference its indexed selected-row strip asset", {
      value = s.selectionOverlay,
    })
  end
  local strip = atlases[FieldUiAssetCache.ASSET.OPTIONS_SELECTION_OVERLAY]
  if type(strip) ~= "table" then
    reject("options.selectionOverlay must reference an indexed asset", {})
  end
  if strip.width ~= 256 or strip.height ~= 24 then
    reject("options.selectionOverlay must be the 256x24 selected-row strip", {
      width = strip.width,
      height = strip.height,
    })
  end
  if
    type(s.animationTickSeconds) ~= "number"
    or s.animationTickSeconds ~= s.animationTickSeconds
    or s.animationTickSeconds <= 0
    or s.animationTickSeconds >= math.huge
  then
    reject("options.animationTickSeconds must be a positive finite duration", {})
  end
  local labels = s.labels
  if type(labels) ~= "table" then
    reject("options.labels must be a table", {})
  end
  demandCount(labels, 13, "options.labels must carry exactly the curated label roles", {})
  for _, key in ipairs({
    "title",
    "textSpeed",
    "battleScene",
    "battleStyle",
    "soundMode",
    "textFrame",
    "confirm",
    "quit",
  }) do
    checkOptionsLabel(labels[key], "options.labels." .. key)
  end
  local valueKeys = { textSpeedValues = { "mid", "fast" }, battleSceneValues = { "on", "off" } }
  valueKeys.battleStyleValues = { "shift", "set" }
  valueKeys.soundModeValues = { "stereo", "mono" }
  for group, keys in pairs(valueKeys) do
    local values = labels[group]
    if type(values) ~= "table" then
      reject("options.labels." .. group .. " must be a table", {})
    end
    demandCount(values, 2, "options.labels." .. group .. " must carry exactly its two offered values", {})
    for _, key in ipairs(keys) do
      checkOptionsLabel(values[key], "options.labels." .. group .. "." .. key)
    end
  end
  if type(labels.frameValues) ~= "table" then
    reject("options.labels.frameValues must be a table", {})
  end
  demandCount(labels.frameValues, 20, "options.labels.frameValues must carry all twenty frame values", {})
  for frame = 0, 19 do
    checkOptionsLabel(labels.frameValues[frame], "options.labels.frameValues[" .. frame .. "]")
  end
  local choices = s.choices
  if type(choices) ~= "table" then
    reject("options.choices must be a table", {})
  end
  demandCount(choices, 2, "options.choices must carry exactly the small and wide controls", {})
  for _, size in ipairs({ "small", "wide" }) do
    local control = choices[size]
    if type(control) ~= "table" then
      reject("options.choices." .. size .. " must be a table", {})
    end
    demandCount(control, 2, "options.choices." .. size .. " must carry its unselected and selected states", {})
    checkOptionsSequence(control.unselected, "options.choices." .. size .. ".unselected", atlases, assets)
    checkOptionsSequence(control.selected, "options.choices." .. size .. ".selected", atlases, assets)
  end
  local arrows = s.arrows
  if type(arrows) ~= "table" then
    reject("options.arrows must be a table", {})
  end
  demandCount(arrows, 2, "options.arrows must carry exactly the left and right arrows", {})
  for _, side in ipairs({ "left", "right" }) do
    local arrow = arrows[side]
    if type(arrow) ~= "table" then
      reject("options.arrows." .. side .. " must be a table", {})
    end
    demandCount(arrow, 2, "options.arrows." .. side .. " must carry its idle and pressed states", {})
    checkOptionsSequence(arrow.idle, "options.arrows." .. side .. ".idle", atlases, assets)
    checkOptionsSequence(arrow.pressed, "options.arrows." .. side .. ".pressed", atlases, assets)
  end
  local actions = s.actions
  if type(actions) ~= "table" then
    reject("options.actions must be a table", {})
  end
  demandCount(
    actions,
    4,
    "options.actions must carry exactly the normal, focused, pressed, and pressed-focused states",
    {}
  )
  for _, state in ipairs({ "normal", "focused", "pressed", "pressedFocused" }) do
    checkOptionsSequence(actions[state], "options.actions." .. state, atlases, assets)
  end
  if type(s.framePreviewText) ~= "table" then
    reject("options.framePreviewText must be a table", {})
  end
  demandCount(s.framePreviewText, 20, "options.framePreviewText must carry all twenty frame previews", {})
  for frame = 0, 19 do
    checkOptionsLabel(s.framePreviewText[frame], "options.framePreviewText[" .. frame .. "]")
  end
  local forbidden = {
    member = true,
    memberId = true,
    narc = true,
    narcId = true,
    alias = true,
    fileId = true,
    bank = true,
    bankId = true,
    index = true,
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
    reject("the options section leaks source detail", { field = leaked })
  end
end

local function demandSection(manifest, name)
  local sectionData = manifest[name]
  if type(sectionData) ~= "table" then
    reject("manifest section " .. name .. " must be a table", {
      section = name,
    })
  end
  return sectionData
end

local function checkManifest(manifest)
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
  StartMenuValidation.validate(
    demandSection(manifest, "startMenu"),
    atlases,
    FieldUiAssetCache.ASSET,
    FieldUiAssetCache.GEOMETRY
  )
  checkTrainerCard(demandSection(manifest, "trainerCard"), atlases)
  NamingValidation.validate(
    demandSection(manifest, "namingScreen"),
    atlases,
    FieldUiAssetCache.ASSET,
    FieldUiAssetCache.GEOMETRY
  )
  checkYesNoPrompt(demandSection(manifest, "yesNoPrompt"), atlases)
  checkOptions(demandSection(manifest, "options"), atlases, manifest.assets)
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

return FieldUiAssetCache
