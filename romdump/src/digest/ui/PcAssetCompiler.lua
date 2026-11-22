-- Compiles the retained PC backgrounds and stationery into source-independent
-- images. Source selectors follow the pinned HGSS overlay loaders in
-- romdump/src/config/PcSources.lua.

local Hashing = require("romdump.src.digest.Hashing")
local Lz10 = require("romdump.src.digest.Lz10")
local Errors = require("libs.errors.src.Errors")
local G2dDecoder = require("romdump.src.digest.ui.G2dDecoder")
local G2dRasterizer = require("romdump.src.digest.ui.G2dRasterizer")
local PngWriter = require("romdump.src.digest.PngEncoder")
local PcAssetSchema = require("libs.assets.src.PcAssetSchema")
local PcCache = require("libs.assets.src.PcCache")
local PcSources = require("romdump.src.config.PcSources")
local FieldMessageBank = require("romdump.src.digest.ui.FieldMessageBank")
local FieldMessageTokenizer = require("romdump.src.digest.ui.FieldMessageTokenizer")
local charmap = require("romdump.src.catalog.hgss.charmap")

local PcAssetCompiler = {}

local function unpackMember(archive, memberId)
  local bytes, err = archive:readMember(memberId)
  if not bytes then
    error(err or ("PC source member " .. memberId .. " is unavailable"), 0)
  end
  if string.byte(bytes, 1) == 0x10 then
    local plain, decodeError = Lz10.decode(bytes)
    if not plain then
      error(decodeError, 0)
    end
    return plain, Hashing.sha1hex(bytes)
  end
  return bytes, Hashing.sha1hex(bytes)
end

local function decode(kind, bytes, role)
  local record, err = G2dDecoder[kind](bytes, { label = "pc:" .. role })
  if not record then
    error(err, 0)
  end
  return record
end

local function renderBackground(archive, selection, role, assets, dependencies, options)
  local charBytes, charHash = unpackMember(archive, selection.character)
  local paletteBytes, paletteHash = unpackMember(archive, selection.palette)
  local screenBytes, screenHash = unpackMember(archive, selection.screen)
  dependencies[#dependencies + 1] = { role = role .. ".character", sha1 = charHash }
  dependencies[#dependencies + 1] = { role = role .. ".palette", sha1 = paletteHash }
  dependencies[#dependencies + 1] = { role = role .. ".screen", sha1 = screenHash }
  local image = G2dRasterizer.renderScreen(
    decode("decodeChar", charBytes, role .. ".character"),
    decode("decodePalette", paletteBytes, role .. ".palette"),
    decode("decodeScreen", screenBytes, role .. ".screen"),
    { role = role },
    options
  )
  local path = PcCache.assetDir() .. "/" .. role .. ".png"
  assets[path] = PngWriter.encode(image.width, image.height, image.pixels)
  return { image = path, width = image.width, height = image.height, anchorX = 0, anchorY = 0 }
end

local function compileStorageWindowFrames(archive, fileId, assets, dependencies, selections)
  local source = PcSources.storageWindowFrames
  local characterBytes, characterHash = unpackMember(archive, source.character)
  local paletteBytes, paletteHash = unpackMember(archive, source.palette)
  dependencies[#dependencies + 1] = { role = "storage.windowFrames.character", sha1 = characterHash }
  dependencies[#dependencies + 1] = { role = "storage.windowFrames.palette", sha1 = paletteHash }
  local character = decode("decodeChar", characterBytes, "storage.windowFrames.character")
  local palette = decode("decodePalette", paletteBytes, "storage.windowFrames.palette")
  local tileBytes = character.depth == 3 and 32 or 64
  local frames = {} ---@type table<string, table>
  for styleName, style in pairs(source.styles) do
    assert(
      style.characterByteOffset % tileBytes == 0,
      "Storage window-frame source offsets start on a complete character tile"
    )
    local firstTile = style.characterByteOffset / tileBytes
    local styleFrames = {}
    for paletteBank = 0, source.paletteBankCount - 1 do
      local image = G2dRasterizer.renderTileStrip(
        character,
        palette,
        firstTile,
        source.tileCount,
        paletteBank,
        { role = "storage.windowFrames." .. styleName .. ".paletteBank" .. paletteBank }
      )
      local path = PcCache.assetDir() .. "/storage-window-frame-" .. styleName .. "-palette-" .. paletteBank .. ".png"
      assets[path] = PngWriter.encode(image.width, image.height, image.pixels)
      styleFrames["paletteBank" .. paletteBank] = {
        image = path,
        width = image.width,
        height = image.height,
        anchorX = 0,
        anchorY = 0,
      }
      selections["storage.windowFrames." .. styleName .. ".paletteBank" .. paletteBank] = {
        path = PcSources.archives.storage.path,
        fileId = fileId,
        members = { character = source.character, palette = source.palette },
        characterByteOffset = style.characterByteOffset,
        sourcePaletteBank = paletteBank,
        destinationPaletteSlot = source.destinationPaletteBase + paletteBank,
      }
    end
    frames[styleName] = styleFrames
  end
  local function entry(role, index)
    local color = assert(palette.colors[index + 1], "Storage window-frame palette covers " .. role)
    return { r = color.r, g = color.g, b = color.b }
  end
  frames.fill = entry("fill", source.fillEntry)
  frames.accentFill = entry("accentFill", source.accentFillEntry)
  return frames
end

-- Composes the member-14 plate roles (the tray MOVE/SORT ITEMS tab and the box
-- tray SUMMARY plate) as three 8x24 strips the renderer tiles across a rect:
-- an 8px left cap, a repeatable 8px middle and an 8px right cap, each with one
-- source tile per 8px row.
local function compileStoragePlates(archive, fileId, assets, dependencies, selections)
  local palettes = {}
  local character
  local plates = {}
  for roleName, role in pairs(PcSources.storagePlateRoles) do
    local paletteKey = "storage.plates." .. roleName .. ".palette"
    local characterKey = "storage.plates." .. roleName .. ".character"
    if palettes[role.palette] == nil then
      local paletteBytes, paletteHash = unpackMember(archive, role.palette)
      dependencies[#dependencies + 1] = { role = paletteKey, sha1 = paletteHash }
      palettes[role.palette] = decode("decodePalette", paletteBytes, paletteKey)
    end
    local characterBytes, characterHash = unpackMember(archive, role.character or 14)
    dependencies[#dependencies + 1] = { role = characterKey, sha1 = characterHash }
    if character == nil then
      character = decode("decodeChar", characterBytes, characterKey)
    end
    local plate = {}
    for _, part in ipairs({ "left", "middle", "right" }) do
      local image = G2dRasterizer.renderScreen(character, palettes[role.palette], {
        width = 8,
        height = 24,
        entries = {
          { tile = role[part][1], palette = role.paletteBank, flipH = false, flipV = false },
          { tile = role[part][2], palette = role.paletteBank, flipH = false, flipV = false },
          { tile = role[part][3], palette = role.paletteBank, flipH = false, flipV = false },
        },
      }, { role = "storage.plates." .. roleName .. "." .. part })
      local path = PcCache.assetDir() .. "/storage-plate-" .. roleName .. "-" .. part .. ".png"
      assets[path] = PngWriter.encode(image.width, image.height, image.pixels)
      plate[part] = { image = path, width = image.width, height = image.height, anchorX = 0, anchorY = 0 }
      selections["storage.plates." .. roleName .. "." .. part] = {
        path = PcSources.archives.storage.path,
        fileId = fileId,
        members = { character = role.character or 14, palette = role.palette },
        tiles = { role[part][1], role[part][2], role[part][3] },
        paletteBank = role.paletteBank,
      }
    end
    plates[roleName] = plate
  end
  return plates
end

-- The marking editor's own mark set: member 14 mark tiles through member 4 bank
-- 1, drawn one 8x8 tile per well inside the member-10 panel.
local function compileStoragePanelMarkings(archive, fileId, assets, dependencies, selections)
  local source = PcSources.storagePanelMarkings
  local characterBytes, characterHash = unpackMember(archive, source.character)
  local paletteBytes, paletteHash = unpackMember(archive, source.palette)
  dependencies[#dependencies + 1] = { role = "storage.panelMarkings.character", sha1 = characterHash }
  dependencies[#dependencies + 1] = { role = "storage.panelMarkings.palette", sha1 = paletteHash }
  local character = decode("decodeChar", characterBytes, "storage.panelMarkings.character")
  local palette = decode("decodePalette", paletteBytes, "storage.panelMarkings.palette")
  local markings = {}
  for bit = 0, source.count - 1 do
    local pair = {}
    for _, state in ipairs({ "clear", "set" }) do
      local tileId = (state == "clear" and source.clearTileBase or source.setTileBase) + bit
      local image = G2dRasterizer.renderTileStrip(
        character,
        palette,
        tileId,
        1,
        source.paletteBank,
        { role = "storage.panelMarkings." .. bit .. "." .. state }
      )
      local path = PcCache.assetDir() .. "/storage-panel-marking-" .. bit .. "-" .. state .. ".png"
      assets[path] = PngWriter.encode(image.width, image.height, image.pixels)
      pair[state] = { image = path, width = image.width, height = image.height, anchorX = 0, anchorY = 0 }
      selections["storage.panelMarkings." .. bit .. "." .. state] = {
        path = PcSources.archives.storage.path,
        fileId = fileId,
        members = { character = source.character, palette = source.palette },
        tileId = tileId,
        paletteBank = source.paletteBank,
      }
    end
    markings[bit] = pair
  end
  return markings
end

-- The info panel's raw 16x8 "Lv."/"No." bitmaps: the message-printer glyph
-- bank stores them as 4bpp tiles whose pixel values are palette indices
-- (1 ink, 2 shadow, 0 clear) into the font palette the info windows use.
local function compileStorageInfoGlyphs(fontArchive, fileId, assets, dependencies, selections)
  local source = PcSources.storageInfoGlyphs
  local characterBytes, characterHash = unpackMember(fontArchive, source.character)
  local paletteBytes, paletteHash = unpackMember(fontArchive, source.palette)
  dependencies[#dependencies + 1] = { role = "storage.infoGlyphs.character", sha1 = characterHash }
  dependencies[#dependencies + 1] = { role = "storage.infoGlyphs.palette", sha1 = paletteHash }
  local character = decode("decodeChar", characterBytes, "storage.infoGlyphs.character")
  local palette = decode("decodePalette", paletteBytes, "storage.infoGlyphs.palette")
  local glyphs = {}
  for role, entry in pairs(source.tiles) do
    local image = G2dRasterizer.renderTileStrip(
      character,
      palette,
      entry[1],
      entry[2],
      source.paletteBank,
      { role = "storage.infoGlyphs." .. role }
    )
    local path = PcCache.assetDir() .. "/storage-info-" .. role .. ".png"
    assets[path] = PngWriter.encode(image.width, image.height, image.pixels)
    glyphs[role] = { image = path, width = image.width, height = image.height, anchorX = 0, anchorY = 0 }
    selections["storage.infoGlyphs." .. role] = {
      path = PcSources.archives.font.path,
      fileId = fileId,
      members = { character = source.character, palette = source.palette },
      tileId = entry[1],
      tileCount = entry[2],
      paletteBank = source.paletteBank,
    }
  end
  return glyphs
end

-- The shared two-row confirmation prompt (PCBox_ShowYesNoPrompt): four 48x32
-- baked button tilemaps. YES reads the first palette bank and NO the second;
-- the selected variant replaces the idle art while that row is highlighted.
local function compileStorageYesNo(promptArchive, fileId, assets, dependencies, selections)
  local source = PcSources.storageYesNo
  local paletteBytes, paletteHash = unpackMember(promptArchive, source.paletteMember)
  local characterBytes, characterHash = unpackMember(promptArchive, source.charMember)
  dependencies[#dependencies + 1] = { role = "storage.yesNo.palette", sha1 = paletteHash }
  dependencies[#dependencies + 1] = { role = "storage.yesNo.character", sha1 = characterHash }
  local palette = decode("decodePalette", paletteBytes, "storage.yesNo.palette")
  local character = decode("decodeChar", characterBytes, "storage.yesNo.character")
  local buttons = {}
  for _, button in ipairs({
    { key = "yesNormal", member = source.yesNormalScreen, bank = source.paletteBanks[1] },
    { key = "yesSelected", member = source.yesSelectedScreen, bank = source.paletteBanks[1] },
    { key = "noNormal", member = source.noNormalScreen, bank = source.paletteBanks[2] },
    { key = "noSelected", member = source.noSelectedScreen, bank = source.paletteBanks[2] },
  }) do
    local screenBytes, screenHash = unpackMember(promptArchive, button.member)
    dependencies[#dependencies + 1] = { role = "storage.yesNo." .. button.key, sha1 = screenHash }
    local screen = decode("decodeScreen", screenBytes, "storage.yesNo." .. button.key)
    local entries = {}
    for index, entry in ipairs(screen.entries) do
      entries[index] = { tile = entry.tile, palette = button.bank, flipH = entry.flipH, flipV = entry.flipV }
    end
    local image = G2dRasterizer.renderScreen(character, palette, {
      width = screen.width,
      height = screen.height,
      entries = entries,
    }, { role = "storage.yesNo." .. button.key })
    assert(
      image.width == 48 and image.height == 32,
      "the Storage confirmation button is the compact 48x32 surface: " .. button.key
    )
    local path = PcCache.assetDir() .. "/storage-yesno-" .. button.key .. ".png"
    assets[path] = PngWriter.encode(image.width, image.height, image.pixels)
    buttons[button.key] = { image = path, width = image.width, height = image.height, anchorX = 0, anchorY = 0 }
    selections["storage.yesNo." .. button.key] = {
      path = PcSources.archives.touch_subwindow.path,
      fileId = fileId,
      members = { character = source.charMember, palette = source.paletteMember, screen = button.member },
      paletteBank = button.bank,
    }
  end
  return buttons
end

local function compileStorageMarkings(archive, fileId, assets, dependencies, selections)
  local source = PcSources.storageMarkings
  local characterBytes, characterHash = unpackMember(archive, source.character)
  local paletteBytes, paletteHash = unpackMember(archive, source.palette)
  dependencies[#dependencies + 1] = { role = "storage.markings.character", sha1 = characterHash }
  dependencies[#dependencies + 1] = { role = "storage.markings.palette", sha1 = paletteHash }
  local character = decode("decodeChar", characterBytes, "storage.markings.character")
  local palette = decode("decodePalette", paletteBytes, "storage.markings.palette")
  local markings = {}
  for bit = 0, source.count - 1 do
    local pair = {}
    for _, state in ipairs({ "clear", "set" }) do
      local tileId = (state == "clear" and source.clearTileBase or source.setTileBase) + bit
      local image = G2dRasterizer.renderTileStrip(
        character,
        palette,
        tileId,
        1,
        source.paletteBank,
        { role = "storage.markings." .. bit .. "." .. state }
      )
      local role = "storage-marking-" .. bit .. "-" .. state
      local path = PcCache.assetDir() .. "/" .. role .. ".png"
      assets[path] = PngWriter.encode(image.width, image.height, image.pixels)
      pair[state] = { image = path, width = image.width, height = image.height, anchorX = 0, anchorY = 0 }
      selections["storage.markings." .. bit .. "." .. state] = {
        path = PcSources.archives.storage.path,
        fileId = fileId,
        members = { character = source.character, palette = source.palette },
        tileId = tileId,
        paletteBank = source.paletteBank,
      }
    end
    markings[bit] = pair
  end
  return markings
end

-- Copies a decoded palette with one entry replaced by a concrete color. The
-- thumbnail and swatch sources encode the wallpaper fill as a palette index;
-- the retail code rewrites that index to a wallpaper color slot before upload.
---@param palette table<string, unknown>
---@param index integer zero-based color index
---@param color { r: integer, g: integer, b: integer }
---@return table<string, unknown>
local function paletteWithColor(palette, index, color)
  local colors = {}
  for position, entry in ipairs(palette.colors) do
    colors[position] = { r = entry.r, g = entry.g, b = entry.b }
  end
  assert(colors[index + 1] ~= nil, "PC source palette covers the recolored entry " .. index)
  colors[index + 1] = { r = color.r, g = color.g, b = color.b }
  return { colors = colors }
end

-- Box tray thumbnails: a 32x32 character tile grid whose fill index is the
-- box wallpaper color, plus the ten BASE_COLOR dot colors used for each mon.
---@param archive Narc
---@param swatchColors { colors: table<integer, { r: integer, g: integer, b: integer }>, locked: { r: integer, g: integer, b: integer } }
---@param assets table<string, string>
---@param dependencies table<integer, table<string, unknown>>
---@return table<string, unknown>
local function compileStorageBoxThumbnails(archive, swatchColors, assets, dependencies)
  local source = PcSources.storageBoxThumbnail
  local characterBytes, characterHash = unpackMember(archive, source.character)
  local paletteBytes, paletteHash = unpackMember(archive, source.palette)
  dependencies[#dependencies + 1] = { role = "storage.boxThumbnail.character", sha1 = characterHash }
  dependencies[#dependencies + 1] = { role = "storage.boxThumbnail.palette", sha1 = paletteHash }
  local character = decode("decodeChar", characterBytes, "storage.boxThumbnail.character")
  local palette = decode("decodePalette", paletteBytes, "storage.boxThumbnail.palette")
  local variants = {}
  for logicalId = 0, 23 do
    local color = assert(swatchColors.colors[logicalId], "wallpaper color covers logical " .. logicalId)
    local image = G2dRasterizer.renderTileGrid(
      character,
      paletteWithColor(palette, source.fillIndex, color),
      0,
      source.columns,
      source.rows,
      0,
      { role = "storage.boxThumbnail." .. logicalId }
    )
    local path = PcCache.assetDir() .. "/storage-box-thumbnail-" .. logicalId .. ".png"
    assets[path] = PngWriter.encode(image.width, image.height, image.pixels)
    variants[logicalId] = { image = path, width = image.width, height = image.height, anchorX = 0, anchorY = 0 }
  end
  local lockedImage = G2dRasterizer.renderTileGrid(
    character,
    paletteWithColor(palette, source.fillIndex, swatchColors.locked),
    0,
    source.columns,
    source.rows,
    0,
    { role = "storage.boxThumbnail.locked" }
  )
  local lockedPath = PcCache.assetDir() .. "/storage-box-thumbnail-locked.png"
  assets[lockedPath] = PngWriter.encode(lockedImage.width, lockedImage.height, lockedImage.pixels)
  local dots = {}
  local function isZero(entry)
    return entry == nil or (entry.r == 0 and entry.g == 0 and entry.b == 0)
  end
  for color = 0, #source.dotColors - 1 do
    -- The source indexes the dot colours through the second OBJ palette slot
    -- (0x20). This member is one 16-colour bank, so the dot entries live at
    -- their own indexes; read the slot-offset entry when that VRAM half is
    -- present and fall back to the member's own bank otherwise.
    local base = source.dotColors[color + 1] + 1
    local entry = palette.colors[base + source.dotPaletteBase]
    if isZero(entry) then
      entry = palette.colors[base]
    end
    dots[color] = { r = assert(entry).r, g = entry.g, b = entry.b }
  end
  return {
    variants = variants,
    locked = { image = lockedPath, width = lockedImage.width, height = lockedImage.height, anchorX = 0, anchorY = 0 },
    dots = dots,
    dotOrigin = { x = source.dotOrigin.x, y = source.dotOrigin.y },
    dotStep = source.dotStep,
  }
end

-- Wallpaper list swatches: the 24x24 character shape with its fill index
-- replaced by the same canonical wallpaper colors, rasterized through the
-- source cell's four objects.
---@param archive Narc
---@param swatchColors { colors: table<integer, { r: integer, g: integer, b: integer }>, locked: { r: integer, g: integer, b: integer } }
---@param assets table<string, string>
---@param dependencies table<integer, table<string, unknown>>
---@return table<string, unknown>
local function compileStorageWallpaperSwatchSprites(archive, swatchColors, assets, dependencies)
  local source = PcSources.storageWallpaperSwatch
  local characterBytes, characterHash = unpackMember(archive, source.character)
  local paletteBytes, paletteHash = unpackMember(archive, source.palette)
  dependencies[#dependencies + 1] = { role = "storage.wallpaperSwatch.character", sha1 = characterHash }
  dependencies[#dependencies + 1] = { role = "storage.wallpaperSwatch.palette", sha1 = paletteHash }
  local character = decode("decodeChar", characterBytes, "storage.wallpaperSwatch.character")
  local palette = decode("decodePalette", paletteBytes, "storage.wallpaperSwatch.palette")
  local cellBytes, cellHash = unpackMember(archive, source.cell)
  dependencies[#dependencies + 1] = { role = "storage.wallpaperSwatch.cell", sha1 = cellHash }
  local cell = decode("decodeCell", cellBytes, "storage.wallpaperSwatch.cell")
  local variants = {}
  -- The swatch is one four-object NCER cell, so the art comes from the cell
  -- layout rather than from a row-major tile grid.
  local function render(color, role)
    local image = G2dRasterizer.renderCell(
      character,
      paletteWithColor(palette, source.fillIndex, color),
      assert(cell.cells[1], "wallpaper swatch cell carries its object list"),
      { role = "storage.wallpaperSwatch." .. role }
    )
    local path = PcCache.assetDir() .. "/storage-wallpaper-swatch-" .. role .. ".png"
    assets[path] = PngWriter.encode(image.width, image.height, image.pixels)
    return {
      image = path,
      width = image.width,
      height = image.height,
      anchorX = image.origin.x,
      anchorY = image.origin.y,
    }
  end
  for logicalId = 0, 23 do
    variants[logicalId] = render(swatchColors.colors[logicalId], tostring(logicalId))
  end
  return {
    variants = variants,
    locked = render(swatchColors.locked, "locked"),
  }
end

local function compileStorageSprites(archive, assets, dependencies)
  local members = PcSources.storageArrows
  local decoded = {}
  for _, role in ipairs({ "character", "palette", "cell", "animation" }) do
    local bytes, digest = unpackMember(archive, members[role])
    dependencies[#dependencies + 1] = { role = "storage.sprites." .. role, sha1 = digest }
    local kind = role == "character" and "decodeChar"
      or role == "palette" and "decodePalette"
      or role == "cell" and "decodeCell"
      or "decodeAnimation"
    decoded[role] = decode(kind, bytes, "storage.sprites." .. role)
  end
  local cellBytes = unpackMember(archive, members.cell)
  local mapping = assert(G2dDecoder.decodeCellMapping(cellBytes, { label = "storage.sprites.cell" }))
  -- One rendered frame of an NCER/NANR animation, anchored at its cell
  -- origin. Static roles keep their first frame; the hand poses carry every
  -- frame with its source tick duration so a two-frame pulse animates.
  local function frameOf(animationIndex, role, fileStem, frameIndex)
    local animation = assert(decoded.animation.anims[animationIndex + 1], "Storage sprite animation exists: " .. role)
    local sourceFrame = assert(animation.frames[frameIndex], "Storage sprite animation frame exists: " .. role)
    local rendered = G2dRasterizer.renderAnimationFrame(
      decoded.character,
      decoded.palette,
      decoded.cell,
      animation,
      frameIndex,
      { role = role, frame = frameIndex - 1 },
      nil,
      mapping
    )
    local path = PcCache.assetDir() .. "/" .. fileStem .. ".png"
    assets[path] = PngWriter.encode(rendered.width, rendered.height, rendered.pixels)
    return {
      image = path,
      width = rendered.width,
      height = rendered.height,
      anchorX = rendered.offset.x,
      anchorY = rendered.offset.y,
      duration = assert(sourceFrame.duration, "Storage sprite frames carry their source tick duration"),
    }
  end
  local function sequenceOf(animationIndex, role, fileStem)
    local animation = assert(decoded.animation.anims[animationIndex + 1], "Storage sprite animation exists: " .. role)
    local frames = {}
    for frameIndex = 1, #animation.frames do
      frames[#frames + 1] = frameOf(animationIndex, role, fileStem .. "-" .. (frameIndex - 1), frameIndex)
    end
    return { frames = frames, loop = animation.playMode == "forward_loop" }
  end
  local arrows, cursors, tray = {}, {}, {}
  for side, animationIndex in pairs(members.animations) do
    local visual = frameOf(animationIndex, "storage.arrows." .. side, "storage-arrow-" .. side, 1)
    visual.duration = nil
    arrows[side] = visual
  end
  for pose, animationIndex in pairs(PcSources.storageCursorAnimations) do
    cursors[pose] = sequenceOf(animationIndex, "storage.cursors." .. pose, "storage-cursor-" .. pose)
  end
  for role, animationIndex in pairs(PcSources.storageTrayAnimations) do
    local visual = frameOf(animationIndex, "storage.tray." .. role, "storage-tray-" .. role, 1)
    visual.duration = nil
    tray[role] = visual
  end
  return arrows, cursors, tray
end

local function compileWallpaperSwatches(archive, dependencies)
  local source = PcSources.storageWallpaperSwatches
  local bytes, digest = unpackMember(archive, source.palette)
  dependencies[#dependencies + 1] = { role = "storage.wallpaperSwatches.palette", sha1 = digest }
  local palette = decode("decodePalette", bytes, "storage.wallpaperSwatches.palette")
  local function color(index)
    local entry = assert(palette.colors[index + 1], "wallpaper swatch palette covers entry " .. index)
    return { r = entry.r, g = entry.g, b = entry.b }
  end
  -- PCBox_ColorWallpaperThumbnail maps logical wallpaper n to palette entry
  -- n + 16, i.e. the palette's second bank holds the sixteen regular wallpaper
  -- colours. The bonus entries (n >= 16) and the locked marker (0x28) resolve
  -- past this member through VRAM the loader never installs, so they fall back
  -- to the member's own band instead of inventing a colour.
  local count = #palette.colors
  local available = count - source.colorBase
  assert(available > 0, "wallpaper colour palette carries its wallpaper band")
  local function entryFor(logicalId)
    local index = source.colorBase + logicalId
    if index >= count then
      index = source.colorBase + (logicalId % available)
    end
    return index
  end
  local colors = {}
  for logicalId = 0, source.count - 1 do
    colors[logicalId] = color(assert(entryFor(logicalId)))
  end
  local lockedIndex = source.lockedColorIndex
  if lockedIndex >= count then
    lockedIndex = count - 1
  end
  return { colors = colors, locked = color(lockedIndex) }
end

local function compileAlbumAnimations(archive, assets, dependencies)
  local members = PcSources.photoAlbumSpriteMembers
  local decoded = {}
  for role, memberId in pairs(members) do
    local bytes, digest = unpackMember(archive, memberId)
    dependencies[#dependencies + 1] = { role = "photoAlbum.sprite." .. role, sha1 = digest }
    local kind = role == "character" and "decodeChar"
      or role == "palette" and "decodePalette"
      or role == "cell" and "decodeCell"
      or "decodeAnimation"
    decoded[role] = decode(kind, bytes, "photoAlbum.sprite." .. role)
  end

  local animationData = decoded.animation
  if #animationData.anims ~= 10 then
    error("photo album sprite resource does not contain ten animations", 0)
  end
  local animations, sequences, frameCount, totalDuration = {}, {}, 0, 0
  for animationId, sourceSequence in ipairs(animationData.anims) do
    local frames = {}
    for frameIndex, frame in ipairs(sourceSequence.frames) do
      local rendered = G2dRasterizer.renderAnimationFrame(
        decoded.character,
        decoded.palette,
        decoded.cell,
        sourceSequence,
        frameIndex,
        { role = "photoAlbum.animation." .. (animationId - 1), frame = frameIndex - 1 }
      )
      local path = PcCache.assetDir()
        .. "/photo-album-animation-"
        .. (animationId - 1)
        .. "-"
        .. (frameIndex - 1)
        .. ".png"
      assets[path] = PngWriter.encode(rendered.width, rendered.height, rendered.pixels)
      frames[frameIndex] = {
        image = path,
        width = rendered.width,
        height = rendered.height,
        anchorX = rendered.offset.x,
        anchorY = rendered.offset.y,
        duration = frame.duration,
      }
      frameCount = frameCount + 1
      totalDuration = totalDuration + frame.duration
    end
    local sequenceKey = "photoAlbum.animation." .. (animationId - 1)
    local loops = sourceSequence.playMode == "forward_loop" or sourceSequence.playMode == "reverse_loop"
    animations[animationId - 1] = { frames = frames }
    sequences[sequenceKey] = { frames = frames, loop = loops }
  end
  if frameCount ~= 14 or totalDuration ~= 25 then
    error("photo album animations do not match the source 14-frame, 25-tick table", 0)
  end

  local sprites = {}
  for spriteIndex = 1, 5 do
    sprites[spriteIndex] = {
      animationSpeed = 0x1000,
      initiallyAnimating = spriteIndex ~= 1,
      initiallyVisible = spriteIndex ~= 2,
    }
  end
  return { animations = animations, sprites = sprites }, sequences
end

local function compileMailboxAnimations(archive, assets, dependencies)
  local members = PcSources.mailboxUiMembers
  local decoded = {}
  for role, memberId in pairs(members) do
    local bytes, digest = unpackMember(archive, memberId)
    dependencies[#dependencies + 1] = { role = "mailbox.sprite." .. role, sha1 = digest }
    local kind = role == "character" and "decodeChar"
      or role == "palette" and "decodePalette"
      or role == "cell" and "decodeCell"
      or "decodeAnimation"
    decoded[role] = decode(kind, bytes, "mailbox.sprite." .. role)
  end

  local animationData = decoded.animation
  local animations, sequences = {}, {}
  for animationId, sourceSequence in ipairs(animationData.anims) do
    local frames = {}
    for frameIndex, frame in ipairs(sourceSequence.frames) do
      local rendered = G2dRasterizer.renderAnimationFrame(
        decoded.character,
        decoded.palette,
        decoded.cell,
        sourceSequence,
        frameIndex,
        { role = "mailbox.animation." .. (animationId - 1), frame = frameIndex - 1 }
      )
      local path = PcCache.assetDir() .. "/mailbox-animation-" .. (animationId - 1) .. "-" .. (frameIndex - 1) .. ".png"
      assets[path] = PngWriter.encode(rendered.width, rendered.height, rendered.pixels)
      frames[frameIndex] = {
        image = path,
        width = rendered.width,
        height = rendered.height,
        anchorX = rendered.offset.x,
        anchorY = rendered.offset.y,
        duration = frame.duration,
      }
    end
    local sequenceKey = "mailbox.animation." .. (animationId - 1)
    local loops = sourceSequence.playMode == "forward_loop" or sourceSequence.playMode == "reverse_loop"
    animations[animationId - 1] = { frames = frames }
    sequences[sequenceKey] = { frames = frames, loop = loops }
  end
  return { animations = animations }, sequences
end

-- Compiles the shared touchscreen list-menu strip and its first palette
-- bank: the Mailbox action menu frames its options with these 8x8 tiles and
-- prints the labels in this palette (touchscreen_list_menu.c).
local function compileListMenu(romFs, assets, dependencies, selections)
  local source = PcSources.listMenu
  local archiveBytes, readError = romFs:readSourcePath(source.path)
  if archiveBytes == nil then
    error(readError or ("list-menu archive is unavailable: " .. source.path), 0)
  end
  local Narc = require("libs.nds.src.nitro.Narc")
  local archive, narcError = Narc.open(archiveBytes, source.path)
  if archive == nil then
    error(narcError, 0)
  end
  local charBytes, charHash = unpackMember(archive, source.char)
  local paletteBytes, paletteHash = unpackMember(archive, source.palette)
  dependencies[#dependencies + 1] = { role = "listMenu.character", sha1 = charHash }
  dependencies[#dependencies + 1] = { role = "listMenu.palette", sha1 = paletteHash }
  selections["mailbox.listMenu"] = {
    path = source.path,
    members = { char = source.char, palette = source.palette },
  }
  local charData = decode("decodeChar", charBytes, "listMenu.character")
  local paletteData = decode("decodePalette", paletteBytes, "listMenu.palette")
  local tileIndices = {}
  for index = 0, math.floor(#charData.tiles / 32) - 1 do
    tileIndices[#tileIndices + 1] = index
  end
  local image = G2dRasterizer.renderTiles(charData, paletteData, tileIndices, { role = "mailbox.listMenu" })
  local path = PcCache.assetDir() .. "/list-menu-tiles.png"
  assets[path] = PngWriter.encode(image.width, image.height, image.pixels)
  local palette = {}
  for index = 1, 16 do
    local color = paletteData.colors[index]
    assert(color ~= nil, "the list menu palette carries its first bank")
    palette[index] = { r = color.r, g = color.g, b = color.b }
  end
  return {
    tiles = { image = path, width = image.width, height = image.height, anchorX = 0, anchorY = 0 },
    palette = palette,
  }
end

local function mergeSequences(first, second)
  for key, value in pairs(second) do
    assert(first[key] == nil, "PC sequence roles are unique")
    first[key] = value
  end
  return first
end

-- 4bpp character pixel index through one decoded tile set, honoring the
-- entry flips. Follows the shared rasterizer's tile layout exactly
-- (depth 3 selects 32 bytes per tile, four bytes per row).
local function charPixelIndex(charData, entry, x, y)
  assert(charData.depth == 3, "stationery write chrome uses 4bpp tiles")
  local tileBytes = 32
  local tileCount = math.floor(#charData.tiles / tileBytes)
  if entry.tile < 0 or entry.tile >= tileCount then
    error("stationery write chrome references tile " .. entry.tile .. " of " .. tileCount, 0)
  end
  local lx, ly = x, y
  if entry.flipH then
    lx = 7 - x
  end
  if entry.flipV then
    ly = 7 - y
  end
  local byte = string.byte(charData.tiles, entry.tile * tileBytes + ly * 4 + math.floor(lx / 2) + 1)
  assert(byte ~= nil, "stationery write chrome tile bytes are present")
  if lx % 2 == 0 then
    return byte % 16
  end
  return math.floor(byte / 16)
end

-- Exact RGB5 blend-to-white (decomp BlendColor): new = old + ((31 - old) *
-- level >> 4) per channel, computed in 5-bit source space from the
-- decoded 8-bit palette colors.
local function blendChannelToWhite(channel, level)
  local channel5 = math.floor((channel * 31 + 127) / 255)
  if channel5 < 0 then
    channel5 = 0
  elseif channel5 > 31 then
    channel5 = 31
  end
  local blended5 = channel5 + (math.floor((31 - channel5) * level / 16))
  if blended5 > 31 then
    blended5 = 31
  end
  return math.floor((blended5 * 255 + 15) / 31)
end

local function blendColorToWhite(color, level)
  return {
    r = blendChannelToWhite(color.r, level),
    g = blendChannelToWhite(color.g, level),
    b = blendChannelToWhite(color.b, level),
  }
end

-- Compiles one stationery type's write chrome: the native BG2-over-BG3
-- composite background, the repeated top-display backdrop, the five
-- cursor-ordered cropped highlight frame sets, and the five rect-local
-- touch masks. Source basis: application/mail_view.c
-- MailView_LoadBgGraphics (write palette bytes 0x60..0x7F at display
-- bank 1, shared member-36 button tilemap over the type character set,
-- G2_SetBlendAlpha(BG2, BG3, 16, 4) after hardware saturation, SUB
-- tile-1/palette-2 backdrop fill, cursor pulse on display entry
-- 0x22+cursorPos, touch rejection on BG2 pixel index 1).
---@param archive Narc the decoded stationery NARC
---@param fileId integer selected archive file identity for provenance
---@param stationeryType integer
---@param assets table<string, string> generated image accumulator
---@param dependencies table<string, unknown>[] generated provenance accumulator
---@param selections table<string, table<string, unknown>> generated selection accumulator
---@return table<string, unknown> write record { background, backdrop, highlights, hitMasks }
local function compileStationeryWrite(archive, fileId, stationeryType, assets, dependencies, selections)
  local write = PcSources.stationeryWrite
  local function memberRecord(memberId, kind, role)
    local bytes, digest = unpackMember(archive, memberId)
    dependencies[#dependencies + 1] = { role = role, sha1 = digest }
    return decode(kind, bytes, role)
  end
  local role = "mail.write." .. stationeryType
  local palData =
    memberRecord(PcSources.stationeryMembers.paletteBase + stationeryType, "decodePalette", role .. ".palette")
  local charData =
    memberRecord(PcSources.stationeryMembers.characterBase + stationeryType, "decodeChar", role .. ".character")
  local bgScreen =
    memberRecord(PcSources.stationeryMembers.screenBase + stationeryType, "decodeScreen", role .. ".background")
  local buttonScreen = memberRecord(write.buttonScreen, "decodeScreen", role .. ".buttons")
  selections[role] = {
    path = PcSources.archives.stationery.path,
    fileId = fileId,
    members = {
      palette = PcSources.stationeryMembers.paletteBase + stationeryType,
      character = PcSources.stationeryMembers.characterBase + stationeryType,
      screen = PcSources.stationeryMembers.screenBase + stationeryType,
      buttons = write.buttonScreen,
    },
  }
  if #palData.colors < 64 then
    error("stationery write palette carries fewer than 64 source colors", 0)
  end
  if bgScreen.width ~= 256 or bgScreen.height ~= 192 then
    error("stationery background screen is not the native 256x192 surface", 0)
  end
  if buttonScreen.width ~= 256 or buttonScreen.height ~= 192 then
    error("stationery button screen is not the native 256x192 surface", 0)
  end
  if #bgScreen.entries ~= 768 or #buttonScreen.entries ~= 768 then
    error("stationery write screens carry incomplete tilemaps", 0)
  end
  -- Display palette view: the write mode reseats source bytes 0x60..0x7F
  -- (decoded colors 48..63) at display bank 1 (indices 16..31).
  local view = {}
  for index, color in ipairs(palData.colors) do
    view[index] = color
  end
  for bankIndex = 0, 15 do
    view[17 + bankIndex] = assert(palData.colors[49 + bankIndex], "stationery write palette covers bytes 0x60..0x7F")
  end
  local function screenEntry(screen, x, y)
    return screen.entries[math.floor(y / 8) * 32 + math.floor(x / 8) + 1]
  end
  local function layerColor(screen, x, y)
    local entry = screenEntry(screen, x, y)
    local index = charPixelIndex(charData, entry, x % 8, y % 8)
    if index == 0 then
      return nil, index
    end
    local color = view[entry.palette * 16 + index + 1]
    if color == nil then
      error("stationery write chrome references an uncovered palette entry", 0)
    end
    return color, index
  end
  -- Native write composite: BG2 over BG3 with the saturated hardware
  -- coefficients (16, 4) over a divisor of 16, clamped to the byte.
  local composite = {}
  for y = 0, 191 do
    composite[y + 1] = {}
    for x = 0, 255 do
      local top, _ = layerColor(buttonScreen, x, y)
      local bottom, _ = layerColor(bgScreen, x, y)
      local pixel
      if top ~= nil then
        local base = bottom or view[1]
        pixel = {
          r = math.min(255, math.floor((top.r * write.blendEvA + base.r * write.blendEvB) / write.blendDivisor)),
          g = math.min(255, math.floor((top.g * write.blendEvA + base.g * write.blendEvB) / write.blendDivisor)),
          b = math.min(255, math.floor((top.b * write.blendEvA + base.b * write.blendEvB) / write.blendDivisor)),
        }
      elseif bottom ~= nil then
        pixel = { r = bottom.r, g = bottom.g, b = bottom.b }
      else
        local backdrop = view[1]
        pixel = { r = backdrop.r, g = backdrop.g, b = backdrop.b }
      end
      composite[y + 1][x + 1] = pixel
    end
  end
  local function encodeRgba(pixels, width, height, transparent)
    local parts = {}
    for y = 1, height do
      for x = 1, width do
        local pixel = pixels[y][x]
        if pixel == nil then
          parts[#parts + 1] = transparent
        else
          parts[#parts + 1] = string.char(pixel.r, pixel.g, pixel.b, 255)
        end
      end
    end
    return table.concat(parts)
  end
  local backgroundPath = PcCache.assetDir() .. "/stationery-" .. stationeryType .. "-write-background.png"
  assets[backgroundPath] = PngWriter.encode(256, 192, encodeRgba(composite, 256, 192))
  -- Top-display backdrop: source tile 1 at palette 2, repeated over the
  -- native surface with tile transparency preserved.
  local backdropTile = {}
  for y = 0, 7 do
    backdropTile[y + 1] = {}
    for x = 0, 7 do
      local index = charPixelIndex(charData, { tile = write.backdropTile, flipH = false, flipV = false }, x, y)
      if index == 0 then
        backdropTile[y + 1][x + 1] = nil
      else
        local color = view[write.backdropPalette * 16 + index + 1]
        if color == nil then
          error("stationery backdrop references an uncovered palette entry", 0)
        end
        backdropTile[y + 1][x + 1] = { r = color.r, g = color.g, b = color.b }
      end
    end
  end
  local backdrop = {}
  for y = 1, 192 do
    backdrop[y] = {}
    for x = 1, 256 do
      backdrop[y][x] = backdropTile[(y - 1) % 8 + 1][(x - 1) % 8 + 1]
    end
  end
  local backdropPath = PcCache.assetDir() .. "/stationery-" .. stationeryType .. "-write-backdrop.png"
  assets[backdropPath] = PngWriter.encode(256, 192, encodeRgba(backdrop, 256, 192, string.char(0, 0, 0, 0)))
  -- Touch masks: five rect-local binary strings in cursor order, eligible
  -- unless the decoded BG2 character pixel index is the rejected 1.
  local hitMasks = {}
  for _, control in ipairs(write.controls) do
    local rows = {}
    for y = 0, control.height - 1 do
      local bits = {}
      for x = 0, control.width - 1 do
        local entry = screenEntry(buttonScreen, control.x + x, control.y + y)
        local index = charPixelIndex(charData, entry, (control.x + x) % 8, (control.y + y) % 8)
        bits[#bits + 1] = index == write.touchRejectIndex and "0" or "1"
      end
      rows[#rows + 1] = table.concat(bits)
    end
    hitMasks[#hitMasks + 1] = {
      x = control.x,
      y = control.y,
      width = control.width,
      height = control.height,
      rows = rows,
    }
  end
  -- Focus highlights: the changed pixels are the BG2 users of the
  -- control's pulse entry, cropped to their actual bounding rectangle
  -- (never the assumed button bounds); each of the 14 levels blends
  -- that entry to white and recomposites the frame.
  local highlights = {}
  for position = 0, 4 do
    local entry = write.highlightEntryBase + position
    local bank = math.floor(entry / 16)
    local value = entry % 16
    local minX, minY, maxX, maxY = 256, 192, -1, -1
    local changed = {}
    for y = 0, 191 do
      for x = 0, 255 do
        local screenEntryValue = screenEntry(buttonScreen, x, y)
        if screenEntryValue.palette == bank then
          local index = charPixelIndex(charData, screenEntryValue, x % 8, y % 8)
          if index == value and index ~= 0 then
            changed[y * 256 + x] = true
            if x < minX then
              minX = x
            end
            if x > maxX then
              maxX = x
            end
            if y < minY then
              minY = y
            end
            if y > maxY then
              maxY = y
            end
          end
        end
      end
    end
    if maxX < minX then
      error("stationery write highlight has no source pixels for cursor position " .. position, 0)
    end
    local width, height = maxX - minX + 1, maxY - minY + 1
    local frames = {}
    for level = 0, write.highlightLevelMax do
      local blended = blendColorToWhite(view[entry + 1], level)
      local frame = {}
      for y = 0, height - 1 do
        frame[y + 1] = {}
        for x = 0, width - 1 do
          local gx, gy = minX + x, minY + y
          if changed[gy * 256 + gx] then
            local bottom, bottomIndex = layerColor(bgScreen, gx, gy)
            if bottomIndex == 0 then
              bottom = view[1]
            end
            assert(bottom ~= nil, "stationery highlight resolves its backdrop color")
            frame[y + 1][x + 1] = {
              r = math.min(
                255,
                math.floor((blended.r * write.blendEvA + bottom.r * write.blendEvB) / write.blendDivisor)
              ),
              g = math.min(
                255,
                math.floor((blended.g * write.blendEvA + bottom.g * write.blendEvB) / write.blendDivisor)
              ),
              b = math.min(
                255,
                math.floor((blended.b * write.blendEvA + bottom.b * write.blendEvB) / write.blendDivisor)
              ),
            }
          else
            frame[y + 1][x + 1] = nil
          end
        end
      end
      local framePath = PcCache.assetDir()
        .. "/stationery-"
        .. stationeryType
        .. "-highlight-"
        .. position
        .. "-"
        .. level
        .. ".png"
      assets[framePath] = PngWriter.encode(width, height, encodeRgba(frame, width, height, string.char(0, 0, 0, 0)))
      frames[#frames + 1] = {
        image = framePath,
        width = width,
        height = height,
        anchorX = 0,
        anchorY = 0,
      }
    end
    highlights[#highlights + 1] = { x = minX, y = minY, width = width, height = height, frames = frames }
  end
  return {
    background = { image = backgroundPath, width = 256, height = 192, anchorX = 0, anchorY = 0 },
    backdrop = { image = backdropPath, width = 256, height = 192, anchorX = 0, anchorY = 0 },
    highlights = highlights,
    hitMasks = hitMasks,
  }
end

local function openSource(romFs, key, dependencies)
  local spec = PcSources.archives[key]
  local archive, err = romFs:openNarc(spec.alias)
  if not archive then
    error(err or ("PC source archive is unavailable: " .. spec.path), 0)
  end
  local fileId = assert(romFs:fileIdForPath(spec.path), "selected PC archive path resolves to a file ID")
  if archive:memberCount() ~= spec.memberCount then
    error("PC source archive has an unexpected member count: " .. spec.path .. " (" .. archive:memberCount() .. ")", 0)
  end
  local archiveBytes = assert(romFs:read(fileId), "selected PC archive bytes are readable")
  dependencies[#dependencies + 1] = { role = key .. ".archive", sha1 = Hashing.sha1hex(archiveBytes) }
  for memberId = 0, spec.memberCount - 1 do
    local member, memberError = archive:readMember(memberId)
    if not member then
      error(memberError or ("PC source member is unavailable: " .. key .. ":" .. memberId), 0)
    end
    dependencies[#dependencies + 1] = {
      role = key .. ".member." .. memberId,
      sha1 = Hashing.sha1hex(member),
    }
  end
  return archive,
    {
      path = spec.path,
      fileId = fileId,
      memberCount = spec.memberCount,
      selectedMemberCount = spec.selectedMemberCount,
    }
end

local function compileText(romFs, dependencies)
  local archive, err = romFs:openNarc("messages")
  if not archive then
    error(err or "PC message archive is unavailable", 0)
  end
  local banks, boxLabels = {}, {}
  -- The Easy Chat word/template catalog belongs to the shared Easy Chat
  -- family: PC text compiles only its own chrome banks, including the
  -- four MailView messages on bank 233.
  local ids = {
    PcSources.mailText.albumBank,
    PcSources.mailText.landmarkBank,
    24,
    25,
    232,
    PcSources.mailText.mailViewBank,
    PcSources.mailText.partyMailBank,
  }
  table.sort(ids)
  for _, bankId in ipairs(ids) do
    local bytes, memberError = archive:readMember(bankId)
    if not bytes then
      error(memberError or ("PC message bank is unavailable: " .. bankId), 0)
    end
    dependencies[#dependencies + 1] = { role = "message-bank-" .. bankId, sha1 = Hashing.sha1hex(bytes) }
    local bank, decodeError = FieldMessageBank.decode(bytes, { label = "pc-message-bank-" .. bankId })
    if not bank then
      error(decodeError, 0)
    end
    local output = {}
    for messageId, message in ipairs(bank.messages) do
      local tokens, tokenError =
        FieldMessageTokenizer.tokenize(message.raw, charmap, { bankId = bankId, messageId = messageId - 1 })
      if not tokens then
        error(tokenError, 0)
      end
      local textParts = {}
      for _, token in ipairs(tokens) do
        if token.kind == "glyph" then
          textParts[#textParts + 1] = token.text
        elseif token.kind == "line_break" then
          textParts[#textParts + 1] = "\n"
        end
      end
      local text = table.concat(textParts)
      if bankId == 24 and text:find("BOX", 1, true) then
        local prefix, ordinal, suffix = text:match("^(.-)(%d+)(.-)$")
        if prefix and ordinal and suffix then
          boxLabels[tonumber(ordinal)] = { text = text, prefix = prefix, suffix = suffix }
        end
      end
      output[messageId - 1] = tokens
    end
    banks[bankId] = output
  end
  if #boxLabels ~= 18 then
    error("PC source message bank 24 does not resolve eighteen default BOX labels", 0)
  end
  local first = assert(boxLabels[1], "source BOX labels start at 1")
  local boxNames = {}
  for ordinal = 1, 18 do
    local label = boxLabels[ordinal]
    if not label or label.prefix ~= first.prefix or label.suffix ~= first.suffix then
      error("PC source BOX labels do not share one ordinal template", 0)
    end
    boxNames[ordinal] = label.text
  end
  return { banks = banks }, boxNames, {
    prefix = first.prefix,
    suffix = first.suffix,
    firstNumber = 1,
  }
end

local function _compile(romFs)
  assert(romFs and romFs.metadata and romFs.openNarc and romFs.fileIdForPath, "compile requires a RomFs")
  local metadata = assert(romFs:metadata())
  assert(type(metadata.sha1) == "string", "ROM metadata carries its SHA-1")
  local dependencies = { PcCache.FORMAT .. ":" .. PcCache.SCHEMA } ---@type (string|table)[]
  local assets, archives, selections = {}, {}, {}
  local storageArchive
  storageArchive, archives.storage = openSource(romFs, "storage", dependencies)
  local mailboxArchive
  mailboxArchive, archives.mailbox = openSource(romFs, "mailbox", dependencies)
  local stationeryArchive
  stationeryArchive, archives.stationery = openSource(romFs, "stationery", dependencies)
  local photoArchive
  photoArchive, archives.photoAlbum = openSource(romFs, "photoAlbum", dependencies)
  local fontArchive
  fontArchive, archives.font = openSource(romFs, "font", dependencies)
  local promptArchive
  promptArchive, archives.touch_subwindow = openSource(romFs, "touch_subwindow", dependencies)

  local storageUi = {} ---@type table<string, unknown>
  for _, role in ipairs({
    "boxPane",
    "infoPane",
    "partyTray",
    "partyTrayMove",
    "markingPanel",
    "wallpaperBar",
    "movesPanel",
    "itemPanel",
    "boxTray",
    "depositBoxTray",
  }) do
    local members = assert(PcSources.storageUiMembers[role], "Storage UI role has source members")
    selections["storage.ui." .. role] = {
      path = PcSources.archives.storage.path,
      fileId = archives.storage.fileId,
      members = members,
    }
    storageUi[role] = renderBackground(storageArchive, members, "storage-" .. role, assets, dependencies)
  end
  storageUi.arrows, storageUi.cursors, storageUi.tray = compileStorageSprites(storageArchive, assets, dependencies)
  storageUi.infoGlyphs = compileStorageInfoGlyphs(fontArchive, archives.font.fileId, assets, dependencies, selections)
  storageUi.yesNo =
    compileStorageYesNo(promptArchive, archives.touch_subwindow.fileId, assets, dependencies, selections)
  storageUi.windowFrames =
    compileStorageWindowFrames(storageArchive, archives.storage.fileId, assets, dependencies, selections)
  storageUi.plates = compileStoragePlates(storageArchive, archives.storage.fileId, assets, dependencies, selections)
  storageUi.panelMarkings =
    compileStoragePanelMarkings(storageArchive, archives.storage.fileId, assets, dependencies, selections)
  storageUi.markings = compileStorageMarkings(storageArchive, archives.storage.fileId, assets, dependencies, selections)
  do
    local fillSource = PcSources.storageItemPanelFill
    local fillBytes, fillHash = unpackMember(storageArchive, fillSource.palette)
    dependencies[#dependencies + 1] = { role = "storage.itemPanelFill.palette", sha1 = fillHash }
    local fillPalette = decode("decodePalette", fillBytes, "storage.itemPanelFill.palette")
    local index = fillSource.paletteBank * 16 + fillSource.entry
    local color = assert(fillPalette.colors[index + 1], "the item panel fill palette covers its entry")
    storageUi.itemPanelFill = { r = color.r, g = color.g, b = color.b }
  end

  local wallpaperSwatches = compileWallpaperSwatches(storageArchive, dependencies)
  local boxThumbnail = compileStorageBoxThumbnails(storageArchive, wallpaperSwatches, assets, dependencies)
  local wallpaperSwatchArt =
    compileStorageWallpaperSwatchSprites(storageArchive, wallpaperSwatches, assets, dependencies)

  local wallpapers = {}
  for _, wallpaperId in ipairs(PcSources.wallpaperIds) do
    local artOrdinal = PcSources.geometry.wallpaperArtOrdinals(wallpaperId)
    local members = {
      character = PcSources.wallpaperMembers.characterBase + artOrdinal,
      palette = PcSources.wallpaperMembers.paletteBase + artOrdinal,
      screen = PcSources.wallpaperMembers.screen,
    }
    selections["storage.wallpapers." .. wallpaperId] = {
      path = PcSources.archives.storage.path,
      fileId = archives.storage.fileId,
      members = members,
    }
    wallpapers[wallpaperId] =
      renderBackground(storageArchive, members, "wallpaper-" .. wallpaperId, assets, dependencies)
  end

  selections["storage.backgrounds.default"] = {
    path = PcSources.archives.storage.path,
    fileId = archives.storage.fileId,
    members = PcSources.storageBaseMembers,
  }
  -- The base is the touch screen's backdrop: untouched pixels show palette color 0.
  local storageBase = renderBackground(
    storageArchive,
    PcSources.storageBaseMembers,
    "storage-base",
    assets,
    dependencies,
    { backdrop = true }
  )

  local stationery = {}
  for _, stationeryType in ipairs(PcSources.stationeryTypes) do
    local members = {
      palette = PcSources.stationeryMembers.paletteBase + stationeryType,
      character = PcSources.stationeryMembers.characterBase + stationeryType,
      screen = PcSources.stationeryMembers.screenBase + stationeryType,
    }
    selections["mail.stationery." .. stationeryType] = {
      path = PcSources.archives.stationery.path,
      fileId = archives.stationery.fileId,
      members = members,
    }
    stationery[stationeryType] = {
      background = renderBackground(stationeryArchive, members, "stationery-" .. stationeryType, assets, dependencies),
      itemKey = assert(PcSources.stationeryItemKeys[stationeryType + 1]),
      write = compileStationeryWrite(
        stationeryArchive,
        archives.stationery.fileId,
        stationeryType,
        assets,
        dependencies,
        selections
      ),
    }
  end

  local mailboxMembers = PcSources.mailboxBackground
  selections["mailbox.background"] = {
    path = PcSources.archives.mailbox.path,
    fileId = archives.mailbox.fileId,
    members = { character = mailboxMembers.character, screen = mailboxMembers.screen, palette = mailboxMembers.palette },
    engine = mailboxMembers.engine,
    bg = mailboxMembers.bg,
  }
  for _, role in ipairs(PcSources.mailboxLoaderRoles.ov103_021ECC1C) do
    selections["mailbox.loader.ov103_021ECC1C." .. role.role] = {
      path = PcSources.archives.mailbox.path,
      fileId = archives.mailbox.fileId,
      members = { character = role.character, screen = role.screen, palette = role.palette },
      engine = role.engine,
      bg = role.bg,
    }
  end
  local mailboxBackground = renderBackground(
    mailboxArchive,
    { character = mailboxMembers.character, palette = mailboxMembers.palette, screen = mailboxMembers.screen },
    "mailbox-background",
    assets,
    dependencies
  )
  local mailboxUi, mailboxSequences = compileMailboxAnimations(mailboxArchive, assets, dependencies)
  local mailboxUiBackgrounds = {}
  for _, role in ipairs(PcSources.mailboxLoaderRoles.ov103_021ECC1C) do
    if role.screen ~= nil and role.palette ~= nil and role.role ~= mailboxMembers.role then
      local members = { character = role.character, palette = role.palette, screen = role.screen }
      mailboxUiBackgrounds[role.role] =
        renderBackground(mailboxArchive, members, "mailbox-" .. role.role, assets, dependencies)
    end
  end
  mailboxUi.backgrounds = mailboxUiBackgrounds
  mailboxUi.listMenu = compileListMenu(romFs, assets, dependencies, selections)

  local albumUi, albumSequences = compileAlbumAnimations(photoArchive, assets, dependencies)
  local albumBackgrounds = {}
  for _, role in ipairs(PcSources.photoAlbumBackgrounds) do
    local members = { character = role.character, palette = role.palette, screen = role.screen }
    selections["photoAlbum.background." .. role.role] = {
      path = PcSources.archives.photoAlbum.path,
      fileId = archives.photoAlbum.fileId,
      members = members,
      bg = role.bg,
    }
    albumBackgrounds[role.role] =
      renderBackground(photoArchive, members, "photo-album-" .. role.role, assets, dependencies)
  end
  albumUi.backgrounds = albumBackgrounds

  local text, boxNames, expansionNameFormat = compileText(romFs, dependencies)
  local sequences = mergeSequences(albumSequences, mailboxSequences)

  local defaultStationery = assert(stationery[0])
  local manifest = {
    schema = PcAssetSchema.SCHEMA,
    storage = {
      backgrounds = { default = storageBase },
      wallpapers = wallpapers,
      wallpaperSwatches = wallpaperSwatches,
      wallpaperSwatchArt = wallpaperSwatchArt,
      boxThumbnail = boxThumbnail,
      ui = storageUi,
      boxNames = boxNames,
      expansionNameFormat = expansionNameFormat,
      geometry = {
        wallpaperMap = PcSources.geometry.wallpaperMap,
      },
    },
    mailbox = {
      background = { main = mailboxBackground },
      ui = mailboxUi,
      geometry = { visibleLetters = PcSources.geometry.mailboxPageSize },
      pageSize = PcSources.geometry.mailboxPageSize,
    },
    mail = {
      stationery = stationery,
      geometry = { iconSlots = 3, iconLocations = PcSources.geometry.stationeryIconLocations },
    },
    photoAlbum = {
      ui = albumUi,
    },
    text = text,
    sequences = sequences,
    terminal = { slots = PcSources.terminal.slots },
  }
  assert(defaultStationery, "stationery zero has a source image")
  PcAssetSchema.assertManifest(manifest)
  local provenance = {
    schema = PcCache.SCHEMA,
    cacheFormat = PcCache.FORMAT,
    versionRomSha1 = metadata.sha1,
    source = PcSources.provenance,
    archives = archives,
    selections = selections,
    dependencies = dependencies,
  }
  local dependencyHash = Hashing.hashLua(provenance)
  provenance.dependencyHash = dependencyHash
  return { manifest = manifest, assets = assets, provenance = provenance, dependencyHash = dependencyHash }
end

---@param romFs RomFs
---@return table<string, unknown>|nil bundle
---@return Errors.Error?
function PcAssetCompiler.compile(romFs)
  assert(romFs and romFs.read and romFs.openNarc, "compile requires a RomFs-shaped object")
  local ok, result = xpcall(_compile, function(err)
    if Errors.is(err) then
      return err
    end
    return { raw = err, trace = debug.traceback("", 2) }
  end, romFs)
  if ok then
    return result
  end
  if Errors.is(result) then
    return nil, result --[[@as Errors.Error]]
  end
  if type(result) == "table" and result.trace then
    error(result.raw, 0)
  end
  error(result, 0)
end

return PcAssetCompiler
