-- Compiles the retained PC backgrounds and stationery into source-independent
-- images. Source selectors follow the pinned HGSS overlay loaders in
-- romdump/src/config/PcSources.lua.

local Hashing = require("romdump.src.digest.Hashing")
local Lz10 = require("romdump.src.digest.Lz10")
local Errors = require("libs.errors.src.Errors")
local G2dDecoder = require("romdump.src.digest.ui.G2dDecoder")
local G2dRasterizer = require("romdump.src.digest.ui.G2dRasterizer")
local PngWriter = require("libs.assets.src.PngWriter")
local PcAssetSchema = require("libs.assets.src.PcAssetSchema")
local PcCache = require("libs.assets.src.PcCache")
local PcSources = require("romdump.src.config.PcSources")
local FieldMessageBank = require("romdump.src.digest.ui.FieldMessageBank")
local FieldMessageTokenizer = require("romdump.src.digest.ui.FieldMessageTokenizer")
local charmap = require("romdump.src.reference.hgss.charmap")

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

local function renderBackground(archive, selection, role, assets, dependencies)
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
    { role = role }
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
  local ids = { PcSources.mailText.albumBank, PcSources.mailText.landmarkBank, 24, 25, 232, 292, 293, 294, 295, 296 }
  for _, wordBank in ipairs(PcSources.mailText.wordBanks) do
    ids[#ids + 1] = wordBank.messageBank
  end
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
    local expectedWords
    for _, wordBank in ipairs(PcSources.mailText.wordBanks) do
      if wordBank.messageBank == bankId then
        expectedWords = wordBank.wordCount
        break
      end
    end
    if expectedWords ~= nil and #bank.messages ~= expectedWords then
      error(
        "PC Easy Chat source bank " .. bankId .. " has " .. #bank.messages .. " entries; expected " .. expectedWords,
        0
      )
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
  local wordDictionary, templates = {}, {}
  for mailBankIndex, bankId in ipairs(PcSources.mailText.lineBanks) do
    local bank = assert(banks[bankId], "every MailMessage source bank is compiled")
    for messageIndex, tokens in ipairs(bank) do
      templates["mail-template:" .. (mailBankIndex - 1) .. ":" .. (messageIndex - 1)] = tokens
    end
  end
  for _, wordBank in ipairs(PcSources.mailText.wordBanks) do
    local bank = assert(banks[wordBank.messageBank], "every source Easy Chat bank is compiled")
    for messageIndex = 0, wordBank.wordCount - 1 do
      local wordId = wordBank.firstWordId + messageIndex
      wordDictionary[tostring(wordId)] = assert(bank[messageIndex], "Easy Chat word has a decoded source message")
    end
  end
  return { banks = banks },
    boxNames,
    {
      prefix = first.prefix,
      suffix = first.suffix,
      firstNumber = 1,
    },
    wordDictionary,
    templates
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
  for index, members in ipairs(PcSources.storageUiMembers) do
    local role = index == 1 and "boxPane" or "partyPane"
    selections["storage.ui." .. role] = {
      path = PcSources.archives.storage.path,
      fileId = archives.storage.fileId,
      members = members,
    }
    storageUi[role] = renderBackground(storageArchive, members, "storage-" .. role, assets, dependencies)
  end
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

  local text, boxNames, expansionNameFormat, wordDictionary, mailTemplates = compileText(romFs, dependencies)
  local sequences = mergeSequences(albumSequences, mailboxSequences)

  local defaultWallpaper = assert(wallpapers[0])
  local defaultStationery = assert(stationery[0])
  local manifest = {
    schema = PcAssetSchema.SCHEMA,
    storage = {
      backgrounds = { default = defaultWallpaper },
      wallpapers = wallpapers,
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
      text = { sourceBanks = PcSources.mailText.lineBanks, templates = mailTemplates },
      wordDictionary = wordDictionary,
    },
    photoAlbum = {
      ui = albumUi,
    },
    text = text,
    sequences = sequences,
    terminal = PcSources.terminal,
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
