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
  local frames = {}
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
  return frames
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
  local function frameOf(animationIndex, role, fileStem)
    local rendered = G2dRasterizer.renderAnimationFrame(
      decoded.character,
      decoded.palette,
      decoded.cell,
      decoded.animation.anims[animationIndex + 1],
      1,
      { role = role, frame = 0 },
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
    }
  end
  local arrows, cursors = {}, {}
  for side, animationIndex in pairs(members.animations) do
    arrows[side] = frameOf(animationIndex, "storage.arrows." .. side, "storage-arrow-" .. side)
  end
  for pose, animationIndex in pairs(PcSources.storageCursorAnimations) do
    cursors[pose] = frameOf(animationIndex, "storage.cursors." .. pose, "storage-cursor-" .. pose)
  end
  return arrows, cursors
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
  local colors = {}
  for logicalId = 0, source.count - 1 do
    colors[logicalId] = color(logicalId)
  end
  return { colors = colors, locked = color(source.lockedIndex) }
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
  local dependencies = { PcCache.FORMAT .. ":" .. PcCache.SCHEMA }
  local assets, archives, selections = {}, {}, {}
  local storageArchive
  storageArchive, archives.storage = openSource(romFs, "storage", dependencies)
  local mailboxArchive
  mailboxArchive, archives.mailbox = openSource(romFs, "mailbox", dependencies)
  local stationeryArchive
  stationeryArchive, archives.stationery = openSource(romFs, "stationery", dependencies)
  local photoArchive
  photoArchive, archives.photoAlbum = openSource(romFs, "photoAlbum", dependencies)

  local storageUi = {}
  for _, role in ipairs({ "boxPane", "infoPane", "partyTray", "markingPanel", "wallpaperBar" }) do
    local members = assert(PcSources.storageUiMembers[role], "Storage UI role has source members")
    selections["storage.ui." .. role] = {
      path = PcSources.archives.storage.path,
      fileId = archives.storage.fileId,
      members = members,
    }
    storageUi[role] = renderBackground(storageArchive, members, "storage-" .. role, assets, dependencies)
  end
  storageUi.arrows, storageUi.cursors = compileStorageSprites(storageArchive, assets, dependencies)
  storageUi.windowFrames =
    compileStorageWindowFrames(storageArchive, archives.storage.fileId, assets, dependencies, selections)
  storageUi.markings = compileStorageMarkings(storageArchive, archives.storage.fileId, assets, dependencies, selections)

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
      wallpaperSwatches = compileWallpaperSwatches(storageArchive, dependencies),
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
