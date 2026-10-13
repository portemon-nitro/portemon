-- Compiles the Pokegear shell, Configure, Phone, map, standalone Fly, and
-- Radio presentation plus the semantic catalog into source-independent
-- images and records. Source selectors follow romdump/src/config/
-- PokegearSources.lua. The compiler returns staged records only; cache
-- publication belongs to PokegearCacheWriter.

local Errors = require("libs.errors.src.Errors")
local Hashing = require("romdump.src.digest.Hashing")
local Lz10 = require("romdump.src.digest.Lz10")
local G2dDecoder = require("romdump.src.digest.ui.G2dDecoder")
local G2dRasterizer = require("romdump.src.digest.ui.G2dRasterizer")
local PngWriter = require("libs.assets.src.PngWriter")
local PokegearAssetSchema = require("libs.assets.src.PokegearAssetSchema")
local PokegearCache = require("libs.assets.src.PokegearCache")
local PokegearCatalogCompiler = require("romdump.src.digest.ui.PokegearCatalogCompiler")
local PokegearSources = require("romdump.src.config.PokegearSources")

local PokegearAssetCompiler = {}

local function unpackMember(archive, memberId, label)
  local bytes, err = archive:readMember(memberId)
  if not bytes then
    error(err or ("pokegear source member " .. memberId .. " is unavailable: " .. label), 0)
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
  local record, err = G2dDecoder[kind](bytes, { label = "pokegear:" .. role })
  if not record then
    if Errors.is(err) then
      local attributed = err --[[@as Errors.Error]]
      attributed.context.role = role
      error(attributed, 0)
    end
    error(err, 0)
  end
  return record
end

local function openArchive(romFs, spec, entries)
  local bytes, err = romFs:readSourcePath(spec.path)
  if not bytes then
    error(err or ("pokegear source archive is unavailable: " .. spec.path), 0)
  end
  local Narc = require("libs.nds.src.nitro.Narc")
  local archive, narcErr = Narc.open(assert(bytes), spec.path)
  if not archive then
    error(narcErr, 0)
  end
  if archive:memberCount() ~= spec.memberCount then
    error(
      "pokegear source archive has an unexpected member count: " .. spec.path .. " (" .. archive:memberCount() .. ")",
      0
    )
  end
  for memberId = spec.firstMember, spec.lastMember do
    local member, memberErr = archive:readMember(memberId)
    if not member then
      error(memberErr or ("pokegear source member is unavailable: " .. spec.path .. ":" .. memberId), 0)
    end
    entries[#entries + 1] = { path = spec.path, member = memberId, sha1 = Hashing.sha1hex(member) }
  end
  return archive
end

local function stageVisual(assets, name, image)
  local path = PokegearCache.assetDir() .. "/" .. name .. ".png"
  assets[path] = PngWriter.encode(image.width, image.height, image.pixels)
  return { image = path, width = image.width, height = image.height, anchorX = 0, anchorY = 0 }
end

-- The sixteen colors of one palette bank as zero-based-index 0..255 RGB
-- records, in source color order.
local function paletteBank(archive, memberId, bank, role)
  local palette = decode("decodePalette", unpackMember(archive, memberId, role), role)
  local colors = {}
  for index = 1, 16 do
    local color = palette.colors[bank * 16 + index]
    if color == nil then
      error("pokegear palette bank is out of range: " .. role, 0)
    end
    colors[index] = { r = color.r, g = color.g, b = color.b }
  end
  return colors
end

local function renderTriple(archive, selection, role, assets, assetName)
  local charMembers = selection.chars ~= nil and selection.chars or { selection.char }
  local tiles, depth = {}, nil
  for _, charMember in ipairs(charMembers) do
    local charBytes = unpackMember(archive, charMember, role .. ".character")
    local char = decode("decodeChar", charBytes, role .. ".character")
    if depth == nil then
      depth = char.depth
    elseif char.depth ~= depth then
      error("pokegear combined character members have mismatched depths: " .. role, 0)
    end
    tiles[#tiles + 1] = char.tiles
  end
  local screenBytes = unpackMember(archive, selection.screen, role .. ".screen")
  local paletteBytes = unpackMember(archive, selection.palette, role .. ".palette")
  local ok, image = pcall(
    G2dRasterizer.renderScreen,
    { depth = depth, tiles = table.concat(tiles) },
    decode("decodePalette", paletteBytes, role .. ".palette"),
    decode("decodeScreen", screenBytes, role .. ".screen"),
    { role = role }
  )
  if not ok then
    if Errors.is(image) then
      local attributed = image --[[@as Errors.Error]]
      attributed.context.role = role
      error(attributed, 0)
    end
    error(image, 0)
  end
  return stageVisual(assets, assetName, image)
end

local function compileCursorAnimation(archive, assets)
  local charBytes = unpackMember(archive, 6, "shell.cursor.character")
  local paletteBytes = unpackMember(archive, 0, "shell.cursor.palette")
  local cellBytes = unpackMember(archive, PokegearSources.shellCursor.cell, "shell.cursor.cell")
  local animBytes = unpackMember(archive, PokegearSources.shellCursor.anim, "shell.cursor.animation")
  local character = decode("decodeChar", charBytes, "shell.cursor.character")
  local palette = decode("decodePalette", paletteBytes, "shell.cursor.palette")
  local cells = decode("decodeCell", cellBytes, "shell.cursor.cell")
  local animation = decode("decodeAnimation", animBytes, "shell.cursor.animation")
  local sequences = {}
  for animationId, sourceSequence in ipairs(animation.anims) do
    local frames = {}
    for frameIndex, frame in ipairs(sourceSequence.frames) do
      local rendered = G2dRasterizer.renderAnimationFrame(
        character,
        palette,
        cells,
        sourceSequence,
        frameIndex,
        { role = "shell.cursor." .. animationId, frame = frameIndex - 1 }
      )
      local path = PokegearCache.assetDir() .. "/shell-cursor-" .. animationId .. "-" .. frameIndex .. ".png"
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
    sequences["shell.cursor." .. animationId] = {
      frames = frames,
      playMode = sourceSequence.playMode,
      loopStartFrameIdx = sourceSequence.loopStartFrameIdx,
    }
  end
  return sequences
end

-- One-based animation sequences of a map-app OBJ set, each frame drawn with
-- the set's per-sequence palette bank and the cell bank's OBJ mapping mode.
local function compileMapSpriteSet(archive, assets, setName, selection)
  local role = "map.sprites." .. setName
  local character =
    decode("decodeChar", unpackMember(archive, selection.char, role .. ".character"), role .. ".character")
  local palette = decode(
    "decodePalette",
    unpackMember(archive, PokegearSources.mapSpritePalette, role .. ".palette"),
    role .. ".palette"
  )
  local cellBytes = unpackMember(archive, selection.cell, role .. ".cell")
  local cells = decode("decodeCell", cellBytes, role .. ".cell")
  local mapping, mappingErr = G2dDecoder.decodeCellMapping(cellBytes, { label = "pokegear:" .. role .. ".cell" })
  if mapping == nil then
    error(mappingErr, 0)
  end
  local animation =
    decode("decodeAnimation", unpackMember(archive, selection.anim, role .. ".animation"), role .. ".animation")
  local sequences = {}
  for sequenceIndex, sourceSequence in ipairs(animation.anims) do
    local frames = {}
    for frameIndex, frame in ipairs(sourceSequence.frames) do
      local rendered = G2dRasterizer.renderAnimationFrame(
        character,
        palette,
        cells,
        sourceSequence,
        frameIndex,
        { role = role .. "." .. sequenceIndex, frame = frameIndex - 1 },
        selection.banks[sequenceIndex] or 0,
        mapping
      )
      local path = PokegearCache.assetDir()
        .. "/map-sprite-"
        .. setName
        .. "-"
        .. sequenceIndex
        .. "-"
        .. frameIndex
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
    end
    sequences[sequenceIndex] = {
      frames = frames,
      playMode = sourceSequence.playMode,
      loopStartFrameIdx = sourceSequence.loopStartFrameIdx,
    }
  end
  return sequences
end

local function _compile(romFs, versionId)
  assert(romFs and romFs.readSourcePath and romFs.metadata, "compile requires a RomFs-shaped object")
  assert(type(versionId) == "string" and versionId ~= "", "compile requires a version")
  local metadata = assert(romFs:metadata())
  assert(type(metadata.sha1) == "string", "ROM metadata carries its SHA-1")
  local entries = {}
  local assets = {}
  local selections = {}

  local shellArchive = openArchive(romFs, PokegearSources.archives.shell, entries)
  local mapArchive = openArchive(romFs, PokegearSources.archives.map, entries)
  local configureArchive = openArchive(romFs, PokegearSources.archives.configure, entries)
  local phoneArchive = openArchive(romFs, PokegearSources.archives.phone, entries)
  local radioArchive = openArchive(romFs, PokegearSources.archives.radio, entries)

  local shellForeground, shellInformation = {}, {}
  local configureForeground, configurePatch = {}, {}
  local phoneForeground, phoneUpper, phoneListPalette = {}, {}, {}
  local radioMain, radioSecond, radioUpper = {}, {}, {}
  local mapForeground, mapWorld, mapMarkingPanel, mapMarkingBackdrop, mapUpper, mapPreviews = {}, {}, {}, {}, {}, {}
  local mapTextPalette = {}
  for _, skin in ipairs(PokegearSources.skins) do
    local shellFg = PokegearSources.shellForeground(skin)
    selections["shell.foreground.skin" .. skin] = { path = PokegearSources.archives.shell.path, members = shellFg }
    shellForeground[skin] =
      renderTriple(shellArchive, shellFg, "shell.foreground.skin" .. skin, assets, "shell-foreground-skin-" .. skin)
    local shellInfo = PokegearSources.shellInformation(skin)
    selections["shell.information.skin" .. skin] = { path = PokegearSources.archives.shell.path, members = shellInfo }
    shellInformation[skin] =
      renderTriple(shellArchive, shellInfo, "shell.information.skin" .. skin, assets, "shell-information-skin-" .. skin)

    local configureFg = PokegearSources.configureForeground(skin)
    selections["configure.foreground.skin" .. skin] =
      { path = PokegearSources.archives.configure.path, members = configureFg }
    configureForeground[skin] = renderTriple(
      configureArchive,
      configureFg,
      "configure.foreground.skin" .. skin,
      assets,
      "configure-foreground-skin-" .. skin
    )
    local configurePatchSel = PokegearSources.configurePatch(skin)
    selections["configure.patch.skin" .. skin] =
      { path = PokegearSources.archives.configure.path, members = configurePatchSel }
    configurePatch[skin] = renderTriple(
      configureArchive,
      configurePatchSel,
      "configure.patch.skin" .. skin,
      assets,
      "configure-patch-skin-" .. skin
    )

    local phoneFg = PokegearSources.phoneForeground(skin)
    selections["phone.foreground.skin" .. skin] = { path = PokegearSources.archives.phone.path, members = phoneFg }
    phoneForeground[skin] =
      renderTriple(phoneArchive, phoneFg, "phone.foreground.skin" .. skin, assets, "phone-foreground-skin-" .. skin)
    phoneListPalette[skin] =
      paletteBank(phoneArchive, phoneFg.palette, PokegearSources.phoneListPaletteBank, "phone.listPalette.skin" .. skin)
    local phoneUp = PokegearSources.phoneUpper(skin)
    selections["phone.upper.skin" .. skin] = { path = PokegearSources.archives.phone.path, members = phoneUp }
    phoneUpper[skin] =
      renderTriple(phoneArchive, phoneUp, "phone.upper.skin" .. skin, assets, "phone-upper-skin-" .. skin)

    local radioMainSel = PokegearSources.radioMain(skin)
    selections["radio.main.skin" .. skin] = { path = PokegearSources.archives.radio.path, members = radioMainSel }
    radioMain[skin] =
      renderTriple(radioArchive, radioMainSel, "radio.main.skin" .. skin, assets, "radio-main-skin-" .. skin)
    local radioSecondSel = PokegearSources.radioSecond(skin)
    selections["radio.second.skin" .. skin] = { path = PokegearSources.archives.radio.path, members = radioSecondSel }
    radioSecond[skin] =
      renderTriple(radioArchive, radioSecondSel, "radio.second.skin" .. skin, assets, "radio-second-skin-" .. skin)
    local radioUp = PokegearSources.radioUpper(skin)
    selections["radio.upper.skin" .. skin] = { path = PokegearSources.archives.radio.path, members = radioUp }
    radioUpper[skin] =
      renderTriple(radioArchive, radioUp, "radio.upper.skin" .. skin, assets, "radio-upper-skin-" .. skin)

    local mapFg = PokegearSources.mapForeground(skin)
    selections["map.foreground.skin" .. skin] = { path = PokegearSources.archives.map.path, members = mapFg }
    mapForeground[skin] =
      renderTriple(mapArchive, mapFg, "map.foreground.skin" .. skin, assets, "map-foreground-skin-" .. skin)
    for _, plane in ipairs({
      { target = mapWorld, role = "world", name = "map-world", selector = PokegearSources.mapWorld },
      {
        target = mapMarkingPanel,
        role = "markingPanel",
        name = "map-marking-panel",
        selector = PokegearSources.mapMarkingPanel,
      },
      {
        target = mapMarkingBackdrop,
        role = "markingBackdrop",
        name = "map-marking-backdrop",
        selector = PokegearSources.mapMarkingBackdrop,
      },
      { target = mapUpper, role = "upper", name = "map-upper", selector = PokegearSources.mapUpper },
      { target = mapPreviews, role = "previews", name = "map-previews", selector = PokegearSources.mapPreviews },
    }) do
      local selection = plane.selector(skin)
      selections["map." .. plane.role .. ".skin" .. skin] =
        { path = PokegearSources.archives.map.path, members = selection }
      plane.target[skin] = renderTriple(
        mapArchive,
        selection,
        "map." .. plane.role .. ".skin" .. skin,
        assets,
        plane.name .. "-skin-" .. skin
      )
    end
    local textMembers = PokegearSources.mapTextMembers(skin)
    mapTextPalette[skin] = {
      upper = paletteBank(
        mapArchive,
        textMembers.upper,
        PokegearSources.mapTextBanks.upper,
        "map.textPalette.upper.skin" .. skin
      ),
      lower = paletteBank(
        mapArchive,
        textMembers.lower,
        PokegearSources.mapTextBanks.lower,
        "map.textPalette.lower.skin" .. skin
      ),
    }
  end

  local fly = {}
  local textBanks = PokegearSources.mapTextBanks
  local flyText = PokegearSources.flyTextMembers
  fly.textPalette = {
    upper = paletteBank(mapArchive, flyText.upper, textBanks.upper, "fly.textPalette.upper"),
    lower = paletteBank(mapArchive, flyText.lower, textBanks.lower, "fly.textPalette.lower"),
  }
  do
    local listMenu = PokegearSources.listMenu
    local menuBytes, menuErr = romFs:readSourcePath(listMenu.path)
    if menuBytes == nil then
      error(menuErr or ("pokegear list menu archive is unavailable: " .. listMenu.path), 0)
    end
    local menuArchive, menuNarcErr = require("libs.nds.src.nitro.Narc").open(menuBytes, listMenu.path)
    if menuArchive == nil then
      error(menuNarcErr, 0)
    end
    local menuChar =
      decode("decodeChar", unpackMember(menuArchive, listMenu.char, "fly.menu.character"), "fly.menu.character")
    local menuPalette =
      decode("decodePalette", unpackMember(menuArchive, listMenu.palette, "fly.menu.palette"), "fly.menu.palette")
    local tileIndices = {}
    for index = 0, math.floor(#menuChar.tiles / 32) - 1 do
      tileIndices[#tileIndices + 1] = index
    end
    selections["fly.menu"] = { path = listMenu.path, members = { char = listMenu.char, palette = listMenu.palette } }
    fly.menuTiles = stageVisual(
      assets,
      "fly-menu-tiles",
      G2dRasterizer.renderTiles(menuChar, menuPalette, tileIndices, { role = "fly.menu" })
    )
    fly.menuPalette = {}
    for index = 1, 16 do
      local color = assert(menuPalette.colors[index], "the list menu palette carries its first bank")
      fly.menuPalette[index] = { r = color.r, g = color.g, b = color.b }
    end
  end
  for role, selection in pairs(PokegearSources.fly) do
    selections["fly." .. role] = { path = PokegearSources.archives.map.path, members = selection }
    fly[role] = renderTriple(mapArchive, selection, "fly." .. role, assets, "fly-" .. role)
  end

  local mapSprites = {}
  for setName, selection in pairs(PokegearSources.mapSprites) do
    selections["map.sprites." .. setName] = {
      path = PokegearSources.archives.map.path,
      members = {
        char = selection.char,
        cell = selection.cell,
        anim = selection.anim,
        palette = PokegearSources.mapSpritePalette,
        banks = selection.banks,
      },
    }
    mapSprites[setName] = compileMapSpriteSet(mapArchive, assets, setName, selection)
  end

  local sequences = compileCursorAnimation(shellArchive, assets)

  local catalogBundle, catalogErr = PokegearCatalogCompiler.compile(romFs, versionId)
  if catalogBundle == nil then
    error(catalogErr, 0)
  end
  entries[#entries + 1] = { name = PokegearSources.phonebook.path, sha1 = catalogBundle.phonebook.sha1 }
  entries[#entries + 1] = { name = "pokegear-phone-catalog", sha1 = catalogBundle.phonebook.sourceHash }

  local Narc = require("libs.nds.src.nitro.Narc")
  local spriteBytes, spriteErr = romFs:readSourcePath(PokegearSources.spriteArchive.path)
  if spriteBytes == nil then
    error(spriteErr or ("pokegear sprite archive is unavailable: " .. PokegearSources.spriteArchive.path), 0)
  end
  local spriteArchive, spriteNarcErr = Narc.open(assert(spriteBytes), PokegearSources.spriteArchive.path)
  if spriteArchive == nil then
    error(spriteNarcErr, 0)
  end
  if spriteArchive:memberCount() ~= PokegearSources.spriteArchive.memberCount then
    error("pokegear sprite archive has an unexpected member count: " .. PokegearSources.spriteArchive.path, 0)
  end
  for _, binding in pairs(PokegearSources.spriteBindings) do
    for _, memberId in ipairs({ binding.char, binding.palette, binding.cell, binding.anim, binding.header }) do
      local member, memberErr = spriteArchive:readMember(memberId)
      if member == nil then
        error(memberErr or ("pokegear sprite member is unavailable: " .. memberId), 0)
      end
      entries[#entries + 1] =
        { path = PokegearSources.spriteArchive.path, member = memberId, sha1 = Hashing.sha1hex(member) }
    end
  end

  local skins = {}
  for _, skin in ipairs(PokegearSources.skins) do
    skins[skin] = assert(shellForeground[skin])
  end
  local manifest = {
    schema = PokegearAssetSchema.SCHEMA,
    skins = skins,
    shell = { foreground = shellForeground, information = shellInformation },
    configure = { foreground = configureForeground, patch = configurePatch },
    phone = { foreground = phoneForeground, upper = phoneUpper, listPalette = phoneListPalette },
    map = {
      foreground = mapForeground,
      world = mapWorld,
      markingPanel = mapMarkingPanel,
      markingBackdrop = mapMarkingBackdrop,
      upper = mapUpper,
      previews = mapPreviews,
      sprites = mapSprites,
      textPalette = mapTextPalette,
      wordPalette = paletteBank(
        mapArchive,
        PokegearSources.mapTextBanks.wordMember,
        PokegearSources.mapTextBanks.word,
        "map.wordPalette"
      ),
    },
    fly = fly,
    radio = { main = radioMain, second = radioSecond, upper = radioUpper },
    catalog = catalogBundle.catalog,
    text = catalogBundle.text,
    sequences = sequences,
  }
  local validated, schemaErr = PokegearAssetSchema.validate(manifest)
  if validated == nil then
    error(schemaErr, 0)
  end
  local provenance = {
    schema = PokegearCache.SCHEMA,
    cacheFormat = PokegearCache.FORMAT,
    versionId = versionId,
    versionRomSha1 = metadata.sha1,
    source = PokegearSources.provenance,
    selections = selections,
    entries = entries,
    dependencies = { PokegearCache.FORMAT .. ":" .. PokegearCache.SCHEMA },
  }
  local dependencyHash = Hashing.hashLua(provenance)
  provenance.dependencyHash = dependencyHash
  local marker = PokegearCache.marker(metadata.sha1, dependencyHash)
  return {
    manifest = manifest,
    assets = assets,
    files = assets,
    provenance = provenance,
    dependencyHash = dependencyHash,
    marker = marker,
  }
end

---@param romFs table<string, unknown> RomFs-shaped source filesystem
---@param versionId string
---@return table<string, unknown>|nil bundle
---@return Errors.Error?
function PokegearAssetCompiler.compile(romFs, versionId)
  assert(romFs and romFs.readSourcePath, "compile requires a RomFs-shaped object")
  local ok, result = xpcall(_compile, function(err)
    if Errors.is(err) then
      return err
    end
    return { raw = err, trace = debug.traceback("", 2) }
  end, romFs, versionId)
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

return PokegearAssetCompiler
