-- Source-backed battle presentation production: the shared ordinary
-- menu/HUD definitions plus lazily compiled persistent BG3 scenes. Source
-- selection follows src/battle/battle_system.c:BattleSystem_SetBackground
-- (pret/pokeheartgold@9d8b7591f09b65804da2fb2dfd56f320633e0d36); container
-- and animation layouts follow GBATEK's "Nitro Character Tiles / BG Maps
-- Screens / OBJ Animations / OBJ Metatile Cells" pages. Decoding reuses the
-- existing G2D primitives (including the retail-tail producer option for
-- the background CHAR family); this module only selects members, bakes
-- terrain, and stages semantic records with image buffers. Pure module: no
-- LOVE objects, no filesystem writes; callers publish through the
-- battle-presentation cache paths.

local Errors = require("libs.errors.src.Errors")
local Hashing = require("romdump.src.digest.Hashing")
local Lz10 = require("romdump.src.digest.Lz10")
local MonSources = require("romdump.src.config.MonSources")
local G2dDecoder = require("romdump.src.digest.ui.G2dDecoder")
local G2dRasterizer = require("romdump.src.digest.ui.G2dRasterizer")
local PngWriter = require("libs.assets.src.PngWriter")
local FieldFontCache = require("libs.assets.src.field.FieldFontCache")
local BattlePresentationSources = require("romdump.src.config.BattlePresentationSources")
local BattlePresentationCache = require("libs.assets.src.battle.BattlePresentationCache")
local BattlePresentationSchema = require("libs.assets.src.battle.BattlePresentationSchema")

---@class BattlePresentationCompiler
local BattlePresentationCompiler = {}

local provenanceRoles

BattlePresentationCompiler.CANVAS_WIDTH = 512
BattlePresentationCompiler.CANVAS_HEIGHT = 256

local SUPPORTED_VERSIONS = { heartgold = true, soulsilver = true }

local Sources = BattlePresentationSources
local ROLES = Sources.ROLES

---@generic T
---@param value T?
---@param err unknown?
---@return T
local function must(value, err)
  if value == nil then
    error(err, 0)
  end
  return value
end

---@param romFs RomFs
---@param symbol string NARC symbol or alias
---@param role string diagnostic role
---@return Narc archive
local function openArchive(romFs, symbol, role)
  local archive, openErr = romFs:openNarc(symbol)
  if archive == nil then
    if Errors.is(openErr) then
      error(openErr, 0)
    end
    error(
      Errors.new(
        "BATTLE_ARCHIVE_UNAVAILABLE",
        "battle presentation archive " .. symbol .. " is unavailable (" .. role .. ")",
        {
          symbol = symbol,
          role = role,
        }
      ),
      0
    )
  end
  return archive
end

---@param archive Narc
---@param memberId integer
---@param label string source role for diagnostics
---@return string member bytes, LZ-unwrapped when wrapped
local function decodeMember(archive, memberId, label)
  local member, err = archive:readMember(memberId)
  if member == nil then
    if Errors.is(err) then
      error(err, 0)
    end
    error(
      Errors.new("BATTLE_MEMBER_MISSING", label .. " member " .. memberId .. " is absent", {
        member = memberId,
        label = label,
      }),
      0
    )
  end
  assert(member ~= nil, "the source member carries bytes")
  if string.byte(member, 1) == 0x10 then
    local plain, lzErr = Lz10.decode(member)
    if plain == nil then
      error(lzErr, 0)
    end
    return plain
  end
  return member
end

---@generic T
---@param decoded T?
---@param err unknown?
---@param label string
---@return T decoded payload
local function mustDecode(decoded, err, label)
  if decoded ~= nil then
    return decoded
  end
  local cause = "unknown"
  if type(err) == "table" and type(err.code) == "string" then
    cause = err.code
  end
  error(
    Errors.new("BATTLE_DECODE_FAILED", label .. " failed to decode (" .. cause .. ")", {
      label = label,
      cause = cause,
    }),
    0
  )
end

---@param archive Narc
---@param memberId integer
---@param label string
---@param charOpts { label: string, allowRetailTail: boolean }? decoder options (the retail-tail producer option for background chars)
---@return { depth: integer, tiles: string }
local function decodeChars(archive, memberId, label, charOpts)
  local bytes = decodeMember(archive, memberId, label)
  local decoded, err = G2dDecoder.decodeChar(bytes, charOpts or { label = label })
  return mustDecode(decoded, err, label)
end

---@param archive Narc
---@param memberId integer
---@param label string
---@return { width: integer, height: integer, entries: table[] }
local function decodeScreen(archive, memberId, label)
  local bytes = decodeMember(archive, memberId, label)
  local decoded, err = G2dDecoder.decodeScreen(bytes, { label = label })
  return mustDecode(decoded, err, label)
end

---@param archive Narc
---@param memberId integer
---@param label string
---@return { colors: table[] }
local function decodePalette(archive, memberId, label)
  local bytes = decodeMember(archive, memberId, label)
  local decoded, err = G2dDecoder.decodePalette(bytes, { label = label })
  return mustDecode(decoded, err, label)
end

---@param archive Narc
---@param memberId integer
---@param label string
---@return { cells: table[] }
local function decodeCells(archive, memberId, label)
  local bytes = decodeMember(archive, memberId, label)
  local decoded, err = G2dDecoder.decodeCell(bytes, { label = label })
  return mustDecode(decoded, err, label)
end

---@param archive Narc
---@param memberId integer
---@param label string
---@return { anims: table[] }
local function decodeAnimation(archive, memberId, label)
  local bytes = decodeMember(archive, memberId, label)
  local decoded, err = G2dDecoder.decodeAnimation(bytes, { label = label })
  return mustDecode(decoded, err, label)
end

---@param versionId string
local function checkVersion(versionId)
  if SUPPORTED_VERSIONS[versionId] ~= true then
    error(
      Errors.new(
        "BATTLE_VERSION_UNSUPPORTED",
        "battle presentation has no source contract for " .. tostring(versionId),
        { versionId = versionId }
      ),
      0
    )
  end
end

---@param record { colors: { r: integer, g: integer, b: integer }[] } decoded G2D record
---@param expected integer
---@param label string
local function checkColorCount(record, expected, label)
  if #record.colors ~= expected then
    error(
      Errors.new(
        "BATTLE_SOURCE_UNEXPECTED",
        label .. " carries " .. #record.colors .. " colors, expected " .. expected,
        {
          label = label,
          available = #record.colors,
          expected = expected,
        }
      ),
      0
    )
  end
end

---@param record { width: integer, height: integer }
---@param width integer
---@param height integer
---@param label string
local function checkScreenSize(record, width, height, label)
  if record.width ~= width or record.height ~= height then
    error(
      Errors.new(
        "BATTLE_SOURCE_UNEXPECTED",
        label .. " is " .. record.width .. "x" .. record.height .. ", expected " .. width .. "x" .. height,
        { label = label, width = record.width, height = record.height }
      ),
      0
    )
  end
end

-- One sprite triple (animation, cells, characters) through the shared
-- decoders with its palette association kept alongside the geometry.
---@param archive Narc
---@param role { nanr: integer, ncer: integer, ncgr: integer }
---@param palette { colors: table[] }
---@param label string
---@return { anims: table[], cells: table[], chars: { depth: integer, tiles: string }, palette: { colors: table[] } }
local function decodeTriple(archive, role, palette, label)
  local animation = decodeAnimation(archive, role.nanr, label .. " animation")
  local cells = decodeCells(archive, role.ncer, label .. " cells")
  local chars = decodeChars(archive, role.ncgr, label .. " characters")
  if chars.depth ~= 3 then
    error(
      Errors.new(
        "BATTLE_SOURCE_UNEXPECTED",
        label .. " characters are not 4bpp",
        { label = label, depth = chars.depth }
      ),
      0
    )
  end
  return { anims = animation.anims, cells = cells.cells, chars = chars, palette = palette }
end

---@param anim { frames: { cell: integer, duration: integer }[], playMode: string, loopStartFrameIdx: integer } decoded animation
---@return { playMode: string, loopStartFrameIdx: integer, frames: table[] }
local function summarizeAnimation(anim)
  local frames = {}
  for _, frame in ipairs(anim.frames) do
    frames[#frames + 1] = { cell = frame.cell, duration = frame.duration }
  end
  return { playMode = anim.playMode, loopStartFrameIdx = anim.loopStartFrameIdx, frames = frames }
end

---@param triple { anims: table[] }
---@param animIndex integer|nil 1-based animation selection (defaults to the only animation)
---@return { playMode: string, loopStartFrameIdx: integer, frames: table[] }
local function selectAnimation(triple, animIndex)
  if animIndex == nil then
    if #triple.anims ~= 1 then
      error(
        Errors.new(
          "BATTLE_SOURCE_UNEXPECTED",
          "sprite keeps " .. #triple.anims .. " animations, expected exactly one",
          { animations = #triple.anims }
        ),
        0
      )
    end
    animIndex = 1
  end
  return summarizeAnimation(must(triple.anims[animIndex], "sprite animation is missing"))
end

-- The evidenced player arrow: six cells with durations 0, 4, 4, 4, 16, 6.
-- The authored zero opening frame is preserved, never rewritten.
local ARROW_DURATIONS = { 0, 4, 4, 4, 16, 6 }

---@param triple { anims: table[], cells: table[], chars: { depth: integer, tiles: string }, palette: { colors: table[] } }
local function checkArrow(triple)
  if #triple.anims ~= 1 then
    error(
      Errors.new("BATTLE_SOURCE_UNEXPECTED", "arrow keeps " .. #triple.anims .. " animations, expected one", {
        animations = #triple.anims,
      }),
      0
    )
  end
  local frames = triple.anims[1].frames
  if #frames ~= #ARROW_DURATIONS then
    error(
      Errors.new("BATTLE_SOURCE_UNEXPECTED", "arrow keeps " .. #frames .. " cells, expected six", {
        frames = #frames,
      }),
      0
    )
  end
  for index, frame in ipairs(frames) do
    if frame.cell ~= index - 1 or frame.duration ~= ARROW_DURATIONS[index] then
      error(
        Errors.new(
          "BATTLE_SOURCE_UNEXPECTED",
          "arrow frame "
            .. (index - 1)
            .. " is cell "
            .. frame.cell
            .. "/"
            .. frame.duration
            .. " ticks, expected cell "
            .. (index - 1)
            .. "/"
            .. ARROW_DURATIONS[index]
            .. " ticks",
          { cell = frame.cell, duration = frame.duration }
        ),
        0
      )
    end
  end
end

local function concatChars(chars)
  -- string.char/unpack are limited by the Lua stack; build in row chunks.
  local out = {}
  for i = 1, #chars, 4096 do
    out[#out + 1] = string.char(unpack(chars, i, math.min(i + 4095, #chars)))
  end
  return table.concat(out)
end

---@param pixels string RGBA image buffer
---@param width integer image width in pixels
---@param height integer image height in pixels
---@param name string slice name for diagnostics
---@return string staged PNG bytes
local function encodeImage(pixels, width, height, name)
  if #pixels ~= width * height * 4 then
    error(
      Errors.new(
        "BATTLE_IMAGE_INVALID",
        name .. " carries " .. #pixels .. " bytes, expected " .. (width * height * 4),
        {
          name = name,
          bytes = #pixels,
        }
      ),
      0
    )
  end
  return PngWriter.encode(width, height, pixels)
end

---@param palette { colors: table[] }
---@return table[] color records
local function paletteRecords(palette)
  local colors = {}
  for _, color in ipairs(palette.colors) do
    colors[#colors + 1] = { r = color.r, g = color.g, b = color.b }
  end
  return colors
end

-- Producer provenance beside the staged global manifest: every selected
-- role with its archive symbol and member. Native identities live here
-- and in the producer configuration only, never in the runtime manifest.
function provenanceRoles()
  local roles = {
    lowerChars = { narc = Sources.LOWER_NARC, member = ROLES.lowerChars },
    lowerPalette = { narc = Sources.LOWER_NARC, member = ROLES.lowerPalette },
    hudPalette = { narc = Sources.SCENE_NARC, member = ROLES.hudPalette },
    lowerObjPalette = { narc = Sources.SCENE_NARC, member = ROLES.lowerObjPalette },
    backdropScreen = { narc = Sources.LOWER_NARC, member = ROLES.backdropScreen },
    terrainCells0 = { narc = Sources.SCENE_NARC, member = ROLES.terrainCells0 },
    terrainAnim0 = { narc = Sources.SCENE_NARC, member = ROLES.terrainAnim0 },
    terrainCells1 = { narc = Sources.SCENE_NARC, member = ROLES.terrainCells1 },
    terrainAnim1 = { narc = Sources.SCENE_NARC, member = ROLES.terrainAnim1 },
    battleFont = { narc = "font", member = Sources.BATTLE_FONT_ID },
  }
  local function screenRoles(field, members, narc)
    local list = {}
    for _, memberId in ipairs(members) do
      list[#list + 1] = { narc = narc, member = memberId }
    end
    roles[field] = list
  end
  screenRoles("commandScreens", ROLES.commandScreens, Sources.LOWER_NARC)
  screenRoles("fightScreens", ROLES.fightScreens, Sources.LOWER_NARC)
  screenRoles("targetScreens", ROLES.targetScreens, Sources.LOWER_NARC)
  screenRoles("twoOptionScreens", ROLES.twoOptionScreens, Sources.LOWER_NARC)
  local function tripleRoles(field, role)
    roles[field] = {
      nanr = { narc = Sources.SCENE_NARC, member = role.nanr },
      ncer = { narc = Sources.SCENE_NARC, member = role.ncer },
      ncgr = { narc = Sources.SCENE_NARC, member = role.ncgr },
    }
  end
  tripleRoles("playerHud", ROLES.playerHud)
  tripleRoles("enemyHud", ROLES.enemyHud)
  tripleRoles("arrow", ROLES.arrow)
  roles.gauges = {}
  for _, family in ipairs(ROLES.gauges) do
    roles.gauges[#roles.gauges + 1] = {
      nanr = { narc = Sources.SCENE_NARC, member = family.nanr },
      ncer = { narc = Sources.SCENE_NARC, member = family.ncer },
      ncgr = { narc = Sources.SCENE_NARC, member = family.ncgr },
    }
  end
  roles.baseChars = {}
  roles.basePalettes = {}
  for backgroundId = 0, 17 do
    roles.baseChars[#roles.baseChars + 1] = { narc = Sources.LOWER_NARC, member = Sources.baseCharMember(backgroundId) }
    local variants = backgroundId < Sources.OUTDOOR_BACKGROUNDS and 2 or 0
    for variant = 0, variants do
      roles.basePalettes[#roles.basePalettes + 1] =
        { narc = Sources.LOWER_NARC, member = Sources.basePaletteMember(backgroundId, variant) }
    end
  end
  return roles
end

-- Compile the shared ordinary battle UI: menu compositions, health-box
-- and arrow sprites with their animations, party gauges, terrain bake
-- inputs, lower palettes per background, font/audio references, and the
-- supported scene inventory. Returns the verified manifest, the staged
-- image buffers by slice name, and the producer provenance beside it.
---@param romFs RomFs
---@param opts? { versionId?: string }
---@return { manifest: table<string, unknown>, images: table<string, { width: integer, height: integer, pixels: string }>, provenance: table<string, unknown> }|nil bundle
---@return unknown|nil reason
function BattlePresentationCompiler.compileGlobal(romFs, opts)
  opts = opts or {}
  local versionId = opts.versionId or romFs:version()
  checkVersion(versionId)
  local ok, bundle = pcall(function()
    local lower = openArchive(romFs, Sources.LOWER_NARC, "lower screen")
    local sceneArchive = openArchive(romFs, Sources.SCENE_NARC, "battle scene")
    local fontArchive = openArchive(romFs, "font", "battle font")
    local lowerChars = decodeChars(lower, ROLES.lowerChars, "shared lower characters")
    if lowerChars.depth ~= 3 or #lowerChars.tiles ~= 32768 then
      error(
        Errors.new("BATTLE_SOURCE_UNEXPECTED", "shared lower characters carry an unexpected tile region", {
          depth = lowerChars.depth,
          bytes = #lowerChars.tiles,
        }),
        0
      )
    end
    local lowerPalette = decodePalette(lower, ROLES.lowerPalette, "base lower palette")
    checkColorCount(lowerPalette, 256, "base lower palette")
    local hudPalette = decodePalette(sceneArchive, ROLES.hudPalette, "ordinary HUD palette")
    checkColorCount(hudPalette, 16, "ordinary HUD palette")
    local lowerObjPalette = decodePalette(sceneArchive, ROLES.lowerObjPalette, "lower OBJ palette")
    checkColorCount(lowerObjPalette, 112, "lower OBJ palette")
    local images = {}
    local function stageSlice(name, pixels, width, height)
      images[name] = { width = width, height = height, pixels = pixels }
    end
    local lowerStrip = G2dRasterizer.renderTileStrip(lowerChars, lowerPalette, 0, Sources.LOWER_USED_TILES, 0, {
      asset = Sources.LOWER_NARC,
      role = "shared lower characters",
    })
    stageSlice("lower-chars", lowerStrip.pixels, lowerStrip.width, lowerStrip.height)
    -- One menu descriptor per lower composition: the staged screen slices
    -- with the source template/priority facts where the source pins them.
    local function compileMenu(roleMembers, names, label, templates, priorities)
      local screens = {}
      for index, memberId in ipairs(roleMembers) do
        local screen = decodeScreen(lower, memberId, label .. " screen " .. index)
        checkScreenSize(screen, 256, 256, label .. " screen " .. index)
        local raster = G2dRasterizer.renderScreen(lowerChars, lowerPalette, screen, {
          asset = Sources.LOWER_NARC,
          role = label .. " screen " .. index,
        })
        local name = names[index]
        stageSlice(name, raster.pixels, raster.width, raster.height)
        local entry = {
          image = BattlePresentationCache.globalImagePath(name),
          width = raster.width,
          height = raster.height,
        }
        if templates ~= nil then
          entry.template = templates[index]
          entry.priority = priorities[index]
        end
        screens[#screens + 1] = entry
      end
      return { image = screens[1].image, screens = screens }
    end
    -- Command composition pins template buffer indices 1, 2, 0 with
    -- priorities 2, 3, 3; the fourth buffer stays unused at priority 0.
    local command = compileMenu(ROLES.commandScreens, {
      "menu-command-1",
      "menu-command-2",
      "menu-command-3",
    }, "command", { 1, 2, 0 }, { 2, 3, 3 })
    local moves = compileMenu(ROLES.fightScreens, { "menu-fight-1", "menu-fight-2" }, "fight")
    local target = compileMenu(ROLES.targetScreens, {
      "menu-target-1",
      "menu-target-2",
      "menu-target-3",
    }, "target")
    local twoOption = compileMenu(ROLES.twoOptionScreens, {
      "menu-two-option-1",
      "menu-two-option-2",
    }, "two-option")
    -- Background-dependent lower palettes: backgrounds 0..16 read base
    -- 247+b with touch 271+b; background 17 reads base 288, touch 289.
    local lowerVariants = {}
    for backgroundId = 0, 17 do
      local background = Sources.BACKGROUNDS[backgroundId + 1]
      -- Variant palettes carry what the source carries (sixteen or
      -- thirty-two colors depending on the background); the manifest
      -- records the association without normalizing the counts.
      local base = decodePalette(lower, Sources.lowerBasePaletteMember(backgroundId), background .. " lower palette")
      local touch = decodePalette(lower, Sources.lowerTouchPaletteMember(backgroundId), background .. " touch palette")
      lowerVariants[background] =
        { base = { colors = paletteRecords(base) }, touch = { colors = paletteRecords(touch) } }
    end
    -- Single-battle sprites: HUD boxes through the HUD palette, the arrow
    -- and party gauges through the lower OBJ palette. Associations are
    -- never swapped.
    local function compileSprite(triple, name, label, animIndex)
      local strip =
        G2dRasterizer.renderTileStrip(triple.chars, triple.palette, 0, math.floor(#triple.chars.tiles / 32), 0, {
          asset = Sources.SCENE_NARC,
          role = label,
        })
      stageSlice(name, strip.pixels, strip.width, strip.height)
      return {
        image = BattlePresentationCache.globalImagePath(name),
        cells = triple.cells,
        animation = selectAnimation(triple, animIndex),
        palette = { colors = paletteRecords(triple.palette) },
      }
    end
    local playerTriple = decodeTriple(sceneArchive, ROLES.playerHud, hudPalette, "player HUD")
    local enemyTriple = decodeTriple(sceneArchive, ROLES.enemyHud, hudPalette, "enemy HUD")
    local arrowTriple = decodeTriple(sceneArchive, ROLES.arrow, lowerObjPalette, "player arrow")
    checkArrow(arrowTriple)
    local playerHud = compileSprite(playerTriple, "hud-player-chars", "player HUD")
    local enemyHud = compileSprite(enemyTriple, "hud-enemy-chars", "enemy HUD")
    local arrow = compileSprite(arrowTriple, "arrow-chars", "player arrow")
    local partyGauges = {}
    for familyIndex, family in ipairs(ROLES.gauges) do
      local triple = decodeTriple(sceneArchive, family, lowerObjPalette, "party gauges " .. familyIndex)
      local section =
        compileSprite(triple, "gauges-" .. (familyIndex - 1) .. "-chars", "party gauges " .. familyIndex, 1)
      local animations = {}
      for _, anim in ipairs(triple.anims) do
        animations[#animations + 1] = summarizeAnimation(anim)
      end
      section.animations = animations
      partyGauges[#partyGauges + 1] = section
    end
    local type0Cells = decodeCells(sceneArchive, ROLES.terrainCells0, "terrain type-0 cells")
    local type0Anim = decodeAnimation(sceneArchive, ROLES.terrainAnim0, "terrain type-0 animation")
    local type1Cells = decodeCells(sceneArchive, ROLES.terrainCells1, "terrain type-1 cells")
    local type1Anim = decodeAnimation(sceneArchive, ROLES.terrainAnim1, "terrain type-1 animation")
    -- Battle narration uses source font 1, whose member bytes are
    -- identical to the published message font 0: the narration role
    -- references the existing generated font, never a replacement.
    local fontZero = must(fontArchive:readMember(0), "font member 0 is absent")
    local fontOne = must(fontArchive:readMember(Sources.BATTLE_FONT_ID), "battle font member is absent")
    if fontOne ~= fontZero then
      error(Errors.new("BATTLE_FONT_UNMATCHED", "battle font 1 no longer matches generated font 0", {}), 0)
    end
    local narrationFont = FieldFontCache.defPath(0)
    local manifest = {
      schema = BattlePresentationSchema.MANIFEST_SCHEMA,
      version = { id = versionId, language = assert(MonSources.versionLanguages[versionId]) },
      verified = true,
      scenes = BattlePresentationCache.sceneInventory(),
      images = {},
      command = command,
      moves = moves,
      target = target,
      twoOption = twoOption,
      lower = {
        image = BattlePresentationCache.globalImagePath("lower-chars"),
        palette = { colors = paletteRecords(lowerPalette) },
        variants = lowerVariants,
      },
      playerHud = playerHud,
      enemyHud = enemyHud,
      arrow = arrow,
      partyGauges = partyGauges,
      terrain = {
        type0 = { cells = type0Cells.cells, animation = selectAnimation({ anims = type0Anim.anims }) },
        type1 = { cells = type1Cells.cells, animation = selectAnimation({ anims = type1Anim.anims }) },
      },
      textRoles = {
        narration = { font = narrationFont, sourceFontId = Sources.BATTLE_FONT_ID },
        menu = { font = narrationFont },
        hud = { font = narrationFont },
      },
      audioRoles = {
        wild = Sources.AUDIO_ROLES.wild,
        trainer = Sources.AUDIO_ROLES.trainer,
        rival = Sources.AUDIO_ROLES.rival,
        select = Sources.AUDIO_ROLES.select,
        narrationBank = Sources.NARRATION_BANK,
        cries = "species",
      },
    }
    for name, image in pairs(images) do
      manifest.images[BattlePresentationCache.globalImagePath(name)] = { width = image.width, height = image.height }
    end
    local manifestOk, manifestErr = pcall(BattlePresentationSchema.assertManifest, manifest)
    if not manifestOk then
      error(
        Errors.new("BATTLE_MANIFEST_INVALID", "compiled battle manifest failed its own schema", {
          cause = tostring(manifestErr),
        }),
        0
      )
    end
    return {
      manifest = manifest,
      images = images,
      provenance = {
        source = Sources.provenance,
        rom = { version = versionId, sha1 = romFs:metadata().sha1 },
        roles = provenanceRoles(),
      },
    }
  end)
  if not ok then
    if Errors.is(bundle) then
      return nil, bundle
    end
    error(bundle, 0)
  end
  return bundle
end

---@param bytes string
---@return integer[] 1-based byte array
local function byteArray(bytes)
  local values = {}
  for start = 1, #bytes, 4096 do
    local stop = math.min(start + 4095, #bytes)
    local chunk = { string.byte(bytes, start, stop) }
    for _, value in ipairs(chunk) do
      values[#values + 1] = value
    end
  end
  return values
end

---@param cells string 0x1000 terrain 4bpp bytes
---@param position integer 0-based byte position
---@return integer byte value
local function cellByte(cells, position)
  local value = string.byte(cells, position + 1)
  return must(value, "terrain cells end before their documented extent")
end

-- Bake terrain type-1 over destination tiles x=16..31, y=20..27. The left
-- 64-pixel chunk reads objY * 0x100 + objX * 0x20 + i / 2; the right chunk
-- adds the source 0x700 term first. A zero nibble leaves the destination
-- unchanged; any other nibble writes nibble + 0x70.
---@param dest integer[] destination 8bpp bytes
---@param cells string terrain 4bpp bytes
local function bakeType1(dest, cells)
  for bgY = 20, 27 do
    for bgX = 16, 31 do
      local objX, objY = bgX - 16, bgY - 20
      local base = 0
      if objX >= 8 then
        base = 0x700
        objX = objX - 8
      end
      for i = 0, 63 do
        local byte = cellByte(cells, base + objY * 0x100 + objX * 0x20 + math.floor(i / 2))
        local nibble = byte % 16
        if i % 2 == 1 then
          nibble = math.floor(byte / 16)
        end
        if nibble ~= 0 then
          dest[bgY * 0x800 + bgX * 0x40 + i + 1] = nibble + 0x70
        end
      end
    end
  end
end

-- Bake terrain type-0: the first 0x800 unpacked pixels at byte offset
-- 0x9800, then the remainder over tiles x=0..23, y=28..31 reading
-- 0x400 + floor(objX / 8) * 0x400 + (objX % 8) * 0x20 + objY * 0x100 + i / 2.
---@param dest integer[] destination 8bpp bytes
---@param cells string terrain 4bpp bytes
local function bakeType0(dest, cells)
  for k = 0, 0x7FF do
    local byte = cellByte(cells, math.floor(k / 2))
    local nibble = byte % 16
    if k % 2 == 1 then
      nibble = math.floor(byte / 16)
    end
    if nibble ~= 0 then
      dest[0x9800 + k + 1] = nibble + 0x70
    end
  end
  for bgY = 28, 31 do
    for bgX = 0, 23 do
      local objX, objY = bgX, bgY - 28
      local base = 0x400 + math.floor(objX / 8) * 0x400
      for i = 0, 63 do
        local byte = cellByte(cells, base + (objX % 8) * 0x20 + objY * 0x100 + math.floor(i / 2))
        local nibble = byte % 16
        if i % 2 == 1 then
          nibble = math.floor(byte / 16)
        end
        if nibble ~= 0 then
          dest[bgY * 0x800 + bgX * 0x40 + i + 1] = nibble + 0x70
        end
      end
    end
  end
end

-- Compile the exact requested persistent scene: the background base with
-- its time-variant palette, the terrain bake, and the common screen
-- rasterized over the result. Returns the source-canvas record with its
-- composed RGBA image; callers stage the record with its PNG.
---@param romFs RomFs
---@param opts? { versionId?: string }
---@param sceneKey string semantic scene key
---@return { schema: string, key: string, background: string, terrain: string, time: string, canvasWidth: integer, canvasHeight: integer, viewport: { x: integer, y: integer, width: integer, height: integer }, image: string, imagePath: string }|nil scene
---@return unknown|nil reason
function BattlePresentationCompiler.compileScene(romFs, opts, sceneKey)
  opts = opts or {}
  local versionId = opts.versionId or romFs:version()
  checkVersion(versionId)
  local parsed = Sources.parseSceneKey(sceneKey)
  if parsed == nil then
    return nil,
      Errors.new("BATTLE_SCENE_UNKNOWN", "unknown battle scene key: " .. tostring(sceneKey), {
        sceneKey = sceneKey,
      })
  end
  local ok, scene = pcall(function()
    local backgroundId = must(Sources.backgroundId(parsed.background), "scene background has no identity")
    local terrain = must(Sources.TERRAIN[parsed.terrain], "scene terrain has no recipe")
    local variant = must(Sources.paletteVariant(parsed.background, parsed.time), "scene time has no variant")
    local lower = openArchive(romFs, Sources.LOWER_NARC, "persistent backdrop")
    local sceneArchive = openArchive(romFs, Sources.SCENE_NARC, "persistent terrain")
    local baseChars =
      decodeChars(lower, Sources.baseCharMember(backgroundId), parsed.background .. " base characters", {
        label = parsed.background .. " base characters",
        allowRetailTail = true,
      })
    if baseChars.depth ~= 4 or #baseChars.tiles ~= 65536 then
      error(
        Errors.new("BATTLE_SOURCE_UNEXPECTED", parsed.background .. " base carries an unexpected tile region", {
          depth = baseChars.depth,
          bytes = #baseChars.tiles,
        }),
        0
      )
    end
    local basePalette =
      decodePalette(lower, Sources.basePaletteMember(backgroundId, variant), parsed.background .. " base palette")
    checkColorCount(basePalette, 256, parsed.background .. " base palette")
    -- Indoor and special backgrounds keep palette variant zero: the day
    -- terrain member regardless of the requested time.
    local terrainMember = must(terrain[parsed.time], "scene time has no terrain member")
    if not Sources.isOutdoor(parsed.background) then
      terrainMember = terrain.day
    end
    local terrainPalette = decodePalette(sceneArchive, terrainMember, parsed.terrain .. " terrain palette")
    checkColorCount(terrainPalette, 16, parsed.terrain .. " terrain palette")
    local type0 = decodeChars(sceneArchive, terrain.type0, parsed.terrain .. " type-0 cells")
    local type1 = decodeChars(sceneArchive, terrain.type1, parsed.terrain .. " type-1 cells")
    for _, sized in ipairs({ { type0, "type-0" }, { type1, "type-1" } }) do
      if sized[1].depth ~= 3 or #sized[1].tiles ~= 4096 then
        error(
          Errors.new(
            "BATTLE_SOURCE_UNEXPECTED",
            parsed.terrain .. " " .. sized[2] .. " cells carry an unexpected region",
            {
              depth = sized[1].depth,
              bytes = #sized[1].tiles,
            }
          ),
          0
        )
      end
    end
    local screen = decodeScreen(lower, ROLES.backdropScreen, "persistent backdrop screen")
    checkScreenSize(
      screen,
      BattlePresentationCompiler.CANVAS_WIDTH,
      BattlePresentationCompiler.CANVAS_HEIGHT,
      "persistent backdrop screen"
    )
    local dest = byteArray(baseChars.tiles)
    bakeType1(dest, type1.tiles)
    bakeType0(dest, type0.tiles)
    local combined = {}
    for _, color in ipairs(basePalette.colors) do
      combined[#combined + 1] = { r = color.r, g = color.g, b = color.b }
    end
    for index, color in ipairs(terrainPalette.colors) do
      combined[0x70 + index] = { r = color.r, g = color.g, b = color.b }
    end
    local raster = G2dRasterizer.renderScreen({ depth = 4, tiles = concatChars(dest) }, { colors = combined }, screen, {
      asset = Sources.LOWER_NARC,
      role = "persistent scene " .. sceneKey,
    }, { transparentZero = false })
    local record = {
      schema = BattlePresentationSchema.SCENE_SCHEMA,
      key = sceneKey,
      background = parsed.background,
      terrain = parsed.terrain,
      time = parsed.time,
      canvasWidth = raster.width,
      canvasHeight = raster.height,
      viewport = { x = 0, y = 0, width = raster.width, height = raster.height },
      image = raster.pixels,
      imagePath = BattlePresentationCache.sceneImagePath(sceneKey),
    }
    local sceneOk, sceneErr = pcall(BattlePresentationSchema.assertScene, {
      schema = record.schema,
      key = record.key,
      background = record.background,
      terrain = record.terrain,
      time = record.time,
      canvasWidth = record.canvasWidth,
      canvasHeight = record.canvasHeight,
      viewport = record.viewport,
      imagePath = record.imagePath,
    })
    if not sceneOk then
      error(
        Errors.new("BATTLE_SCENE_INVALID", "composed battle scene failed its own schema", {
          cause = tostring(sceneErr),
        }),
        0
      )
    end
    return record
  end)
  if not ok then
    if Errors.is(scene) then
      return nil, scene
    end
    error(scene, 0)
  end
  return scene
end

-- Stage one compiled global bundle through a worker artifact: the verified
-- manifest, the producer provenance, every staged slice PNG, and the
-- completion marker. Returns the marker.
---@param artifact PreparedArtifact
---@param bundle { manifest: table<string, unknown>, images: table<string, { width: integer, height: integer, pixels: string }>, provenance: table<string, unknown> } compileGlobal bundle
---@param marker string completion marker
---@return string marker
function BattlePresentationCompiler.stageGlobal(artifact, bundle, marker)
  assert(type(marker) == "string" and marker ~= "", "global staging requires its marker")
  local stage = artifact:stageFs()
  artifact:addOwnedRoot(BattlePresentationCache.manifestPath())
  artifact:addOwnedRoot(BattlePresentationCache.provenancePath())
  artifact:addOwnedRoot(BattlePresentationCache.markerPath())
  stage:writeLua(BattlePresentationCache.manifestPath(), bundle.manifest)
  stage:writeLua(BattlePresentationCache.provenancePath(), bundle.provenance)
  local names = {}
  for name in pairs(bundle.images) do
    names[#names + 1] = name
  end
  table.sort(names)
  for _, name in ipairs(names) do
    local image = bundle.images[name]
    local path = BattlePresentationCache.globalImagePath(name)
    artifact:addOwnedRoot(path)
    stage:write(path, encodeImage(image.pixels, image.width, image.height, name))
  end
  stage:write(BattlePresentationCache.markerPath(), marker)
  return marker
end

-- The content identity behind the global completion marker: the verified
-- manifest plus the staged image bytes.
---@param romSha1 string
---@param bundle { manifest: table<string, unknown>, images: table<string, { width: integer, height: integer, pixels: string }>, provenance: table<string, unknown> } compileGlobal bundle
---@return string marker
function BattlePresentationCompiler.globalMarker(romSha1, bundle)
  local imageHashes = {}
  for name, image in pairs(bundle.images) do
    imageHashes[name] = Hashing.sha1hex(image.pixels)
  end
  return BattlePresentationCache.marker(romSha1, Hashing.hashLua({ manifest = bundle.manifest, images = imageHashes }))
end

-- Stage one composed scene through a worker artifact: the schema-valid
-- record without its pixels, the staged scene PNG, and the completion
-- marker. Returns the marker.
---@param artifact PreparedArtifact
---@param scene { schema: string, key: string, background: string, terrain: string, time: string, canvasWidth: integer, canvasHeight: integer, viewport: { x: integer, y: integer, width: integer, height: integer }, image: string, imagePath: string } compileScene record
---@param marker string completion marker
---@return string marker
function BattlePresentationCompiler.stageScene(artifact, scene, marker)
  assert(type(marker) == "string" and marker ~= "", "scene staging requires its marker")
  local stage = artifact:stageFs()
  artifact:addOwnedRoot(BattlePresentationCache.scenePath(scene.key))
  artifact:addOwnedRoot(BattlePresentationCache.sceneImagePath(scene.key))
  artifact:addOwnedRoot(BattlePresentationCache.sceneMarkerPath(scene.key))
  stage:writeLua(BattlePresentationCache.scenePath(scene.key), {
    schema = scene.schema,
    key = scene.key,
    background = scene.background,
    terrain = scene.terrain,
    time = scene.time,
    canvasWidth = scene.canvasWidth,
    canvasHeight = scene.canvasHeight,
    viewport = scene.viewport,
    imagePath = scene.imagePath,
  })
  stage:write(
    BattlePresentationCache.sceneImagePath(scene.key),
    encodeImage(scene.image, scene.canvasWidth, scene.canvasHeight, scene.key)
  )
  stage:write(BattlePresentationCache.sceneMarkerPath(scene.key), marker)
  return marker
end

-- The content identity behind one scene completion marker.
---@param romSha1 string
---@param scene { schema: string, key: string, background: string, terrain: string, time: string, canvasWidth: integer, canvasHeight: integer, viewport: { x: integer, y: integer, width: integer, height: integer }, image: string, imagePath: string } compileScene record
---@return string marker
function BattlePresentationCompiler.sceneMarker(romSha1, scene)
  return BattlePresentationCache.marker(
    romSha1,
    Hashing.hashLua({
      key = scene.key,
      canvasWidth = scene.canvasWidth,
      canvasHeight = scene.canvasHeight,
      viewport = scene.viewport,
      image = Hashing.sha1hex(scene.image),
    })
  )
end

return BattlePresentationCompiler
