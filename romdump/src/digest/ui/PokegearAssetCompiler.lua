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
local PngWriter = require("romdump.src.digest.PngEncoder")
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

local function decode(kind, bytes, role, layout)
  ---@type table<string, string>
  local options = { label = "pokegear:" .. role }
  if layout ~= nil then
    assert(kind == "decodeScreen", "only screen decoding selects a layout")
    assert(type(layout) == "string", "screen layouts stay identities")
    options.layout = layout
  end
  local record, err = G2dDecoder[kind](bytes, options)
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

local function decodePaletteMember(archive, memberId, role)
  return decode("decodePalette", unpackMember(archive, memberId, role), role)
end

-- Source palette blend toward black with factor 8 (BlendColor(source, 0,
-- 8)): source + (((0 - source) * 8) >> 4), per 5-bit channel. Staged
-- colors expand 5-bit channels with floor((channel * 255 + 15) / 31),
-- which is injective, so each staged channel inverts to exactly one
-- source channel.
local function toSourceChannel(expanded)
  for channel = 0, 31 do
    if math.floor((channel * 255 + 15) / 31) == expanded then
      return channel
    end
  end
  error("pokegear dim blend needs a source 5-bit channel", 0)
end

local function dimChannel(expanded)
  local source = toSourceChannel(expanded)
  local blended = source + math.floor(((0 - source) * 8) / 16)
  return math.floor((blended * 255 + 15) / 31)
end

---@param color { r: integer, g: integer, b: integer }
---@return { r: integer, g: integer, b: integer }
local function dimColor(color)
  return { r = dimChannel(color.r), g = dimChannel(color.g), b = dimChannel(color.b) }
end

-- One decoded palette record with the given zero-based banks blended,
-- leaving the source record untouched for the bright variants sharing
-- the same member.
---@param record { colors: table[] }
---@param dimBanks table<integer, boolean> zero-based banks to darken
---@return { colors: table[] }
local function withDimmedBanks(record, dimBanks)
  local dimmed = { colors = {} }
  for index, color in ipairs(record.colors) do
    local bank = math.floor((index - 1) / 16)
    if dimBanks[bank] == true then
      dimmed.colors[index] = dimColor(color)
    else
      dimmed.colors[index] = { r = color.r, g = color.g, b = color.b }
    end
  end
  return dimmed
end

local function renderTriple(archive, selection, role, assets, assetName, paletteRecord)
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
  local palette = paletteRecord
  if palette == nil then
    local paletteBytes = unpackMember(archive, selection.palette, role .. ".palette")
    palette = decode("decodePalette", paletteBytes, role .. ".palette")
  end
  -- Row-major screens (the world planes) declare their layout on the
  -- selection; every other plane keeps the hardware-block default.
  local screenLayout = selection.layout
  if screenLayout ~= nil then
    assert(type(screenLayout) == "string", "screen layouts stay identities: " .. role)
  end
  local ok, image = pcall(
    G2dRasterizer.renderScreen,
    { depth = depth, tiles = table.concat(tiles) },
    palette,
    decode("decodeScreen", screenBytes, role .. ".screen", screenLayout),
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

-- The shell OBJ set (clock digits, colon, weekday, reception, strip
-- corners) is skinned: character members 6+skin and palette members
-- 0+skin share cell member 12 and animation member 13
-- (PokegearSources.shellCursor), matching PokegearUIManager_LoadSkinGfx.
-- Every skin compiles its own frames under sequences
-- ["shell.cursor.skins"][skin]; the legacy flat shell.cursor.<id> entries
-- keep the skin-zero frames so older readers and caches keep working.
---@param archive table<string, unknown> the opened shell source NARC
---@param assets table<string, string> the staged asset bytes by path
---@return table<integer, table<string, unknown>> per-skin animation maps
local function compileCursorSkinAnimations(archive, assets)
  local cellBytes = unpackMember(archive, PokegearSources.shellCursor.cell, "shell.cursor.cell")
  local animBytes = unpackMember(archive, PokegearSources.shellCursor.anim, "shell.cursor.animation")
  local cells = decode("decodeCell", cellBytes, "shell.cursor.cell")
  local animation = decode("decodeAnimation", animBytes, "shell.cursor.animation")
  local perSkin = {}
  for _, skin in ipairs(PokegearSources.skins) do
    local role = "shell.cursor.skin" .. skin
    local charBytes = unpackMember(archive, 6 + skin, role .. ".character")
    local paletteBytes = unpackMember(archive, 0 + skin, role .. ".palette")
    local character = decode("decodeChar", charBytes, role .. ".character")
    local palette = decode("decodePalette", paletteBytes, role .. ".palette")
    local map = {}
    for animationId, sourceSequence in ipairs(animation.anims) do
      local frames = {}
      for frameIndex, frame in ipairs(sourceSequence.frames) do
        local rendered = G2dRasterizer.renderAnimationFrame(
          character,
          palette,
          cells,
          sourceSequence,
          frameIndex,
          { role = role .. "." .. animationId, frame = frameIndex - 1 }
        )
        local path = PokegearCache.assetDir()
          .. "/shell-cursor-skin-"
          .. skin
          .. "-"
          .. animationId
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
      map["shell.cursor." .. animationId] = {
        frames = frames,
        playMode = sourceSequence.playMode,
        loopStartFrameIdx = sourceSequence.loopStartFrameIdx,
      }
    end
    perSkin[skin] = map
  end
  return perSkin
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
  sequences["shell.cursor.skins"] = compileCursorSkinAnimations(archive, assets)
  return sequences
end

-- One-based animation sequences of one card-app OBJ set, each frame drawn
-- with the set's per-sequence palette bank and the cell bank's OBJ mapping
-- mode. Map sets read the shared map palette member; card sets read their
-- own card palette member. `filePrefix` names the staged frame images.
-- `selection.banks` carries NCLR-local banks (hardware template slots
-- minus the 0x40 upload base); sequences marked in
-- `selection.paletteMode1` name no override so the NCER cell palette
-- applies, while every other unlisted sequence draws with bank 0.
-- `paletteRecord` optionally replaces the member decode so dimmed
-- variants rasterize from a blended palette without touching the source.
---@param archive table<string, unknown> the opened source NARC
---@param assets table<string, string> the staged asset bytes by path
---@param role string the provenance role behind the set
---@param filePrefix string the staged image name prefix
---@param selection table<string, unknown> the char/cell/anim/banks member selection
---@param paletteMember integer the palette member behind the set
---@param paletteRecord { colors: table[] }? pre-decoded palette record replacing the member decode
---@return table<integer, table<string, unknown>> one-based animation sequences
local function compileSpriteSet(archive, assets, role, filePrefix, selection, paletteMember, paletteRecord)
  local character =
    decode("decodeChar", unpackMember(archive, selection.char, role .. ".character"), role .. ".character")
  local palette = paletteRecord
  if palette == nil then
    palette = decode("decodePalette", unpackMember(archive, paletteMember, role .. ".palette"), role .. ".palette")
  end
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
      local override = selection.banks[sequenceIndex]
      if override == nil then
        local mode1 = selection.paletteMode1
        if not (type(mode1) == "table" and mode1[sequenceIndex] == true) then
          override = 0
        end
      end
      local rendered = G2dRasterizer.renderAnimationFrame(
        character,
        palette,
        cells,
        sourceSequence,
        frameIndex,
        { role = role .. "." .. sequenceIndex, frame = frameIndex - 1 },
        override,
        mapping
      )
      local path = PokegearCache.assetDir() .. "/" .. filePrefix .. "-" .. sequenceIndex .. "-" .. frameIndex .. ".png"
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
  local phoneForeground, phoneUpper, phoneListPalette, phoneTooltipPalette, phoneWindowPalette = {}, {}, {}, {}, {}
  local phoneForegroundDim, phoneForegroundDimChoice, phoneDimShellForeground, phoneListPaletteDim = {}, {}, {}, {}
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
    phoneTooltipPalette[skin] = paletteBank(
      phoneArchive,
      phoneFg.palette,
      PokegearSources.phoneTooltipPaletteBank,
      "phone.tooltipPalette.skin" .. skin
    )
    local phoneUp = PokegearSources.phoneUpper(skin)
    selections["phone.upper.skin" .. skin] = { path = PokegearSources.archives.phone.path, members = phoneUp }
    phoneUpper[skin] =
      renderTriple(phoneArchive, phoneUp, "phone.upper.skin" .. skin, assets, "phone-upper-skin-" .. skin)
    -- The call windows print through the upper SUB member, not the
    -- foreground MAIN member: bank 1 of phoneUpper(skin).palette.
    phoneWindowPalette[skin] = paletteBank(
      phoneArchive,
      phoneUp.palette,
      PokegearSources.phoneWindowPaletteBank,
      "phone.windowPalette.skin" .. skin
    )
    -- The live call darkens MAIN_BG banks 0..10 (color entries 0..0xB0)
    -- with factor 8; the in-call choice restores banks 1 and 10 while
    -- keeping the rest dark. The shared strip lives on the shell
    -- member, whose MAIN_BG banks 14..15 (entries 0xE0..0x100) darken
    -- with it. All variants render from nonmutating palette copies so
    -- the bright planes sharing each member stay exact.
    local phoneFgPalette = decodePaletteMember(phoneArchive, phoneFg.palette, "phone.foregroundPalette.skin" .. skin)
    local dimBanks = {}
    for bank = 0, 10 do
      dimBanks[bank] = true
    end
    phoneForegroundDim[skin] = renderTriple(
      phoneArchive,
      phoneFg,
      "phone.foregroundDim.skin" .. skin,
      assets,
      "phone-foreground-dim-skin-" .. skin,
      withDimmedBanks(phoneFgPalette, dimBanks)
    )
    local choiceBanks = {}
    for bank = 0, 10 do
      choiceBanks[bank] = true
    end
    choiceBanks[1] = nil
    choiceBanks[10] = nil
    phoneForegroundDimChoice[skin] = renderTriple(
      phoneArchive,
      phoneFg,
      "phone.foregroundDimChoice.skin" .. skin,
      assets,
      "phone-foreground-dim-choice-skin-" .. skin,
      withDimmedBanks(phoneFgPalette, choiceBanks)
    )
    if phoneFgPalette.colors[2 * 16 + 16] == nil then
      error("pokegear palette bank is out of range: phone.listPaletteDim.skin" .. skin, 0)
    end
    local dimList = {}
    for index = 1, 16 do
      dimList[index] = dimColor(phoneFgPalette.colors[2 * 16 + index])
    end
    phoneListPaletteDim[skin] = dimList
    local shellFgPalette = decodePaletteMember(shellArchive, shellFg.palette, "shell.foregroundPalette.skin" .. skin)
    if shellFgPalette.colors[15 * 16 + 16] == nil then
      error("pokegear palette bank is out of range: phone.dimShellForeground.skin" .. skin, 0)
    end
    phoneDimShellForeground[skin] = renderTriple(
      shellArchive,
      shellFg,
      "phone.dimShellForeground.skin" .. skin,
      assets,
      "phone-dim-shell-foreground-skin-" .. skin,
      withDimmedBanks(shellFgPalette, { [14] = true, [15] = true })
    )

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
    mapSprites[setName] = compileSpriteSet(
      mapArchive,
      assets,
      "map.sprites." .. setName,
      "map-sprite-" .. setName,
      selection,
      PokegearSources.mapSpritePalette
    )
  end

  -- The setup and phone OBJ sets follow the map sprite shape exactly:
  -- one named set per card from its own card archive and palette.
  local configureSprites = {}
  for setName, selection in pairs(PokegearSources.configureSprites) do
    selections["configure.sprites." .. setName] = {
      path = PokegearSources.archives.configure.path,
      members = {
        char = selection.char,
        cell = selection.cell,
        anim = selection.anim,
        palette = PokegearSources.configureSpritePalette,
        banks = selection.banks,
      },
    }
    configureSprites[setName] = compileSpriteSet(
      configureArchive,
      assets,
      "configure.sprites." .. setName,
      "configure-sprite-" .. setName,
      selection,
      PokegearSources.configureSpritePalette
    )
  end

  local phoneSprites = {}
  for setName, selection in pairs(PokegearSources.phoneSprites) do
    selections["phone.sprites." .. setName] = {
      path = PokegearSources.archives.phone.path,
      members = {
        char = selection.char,
        cell = selection.cell,
        anim = selection.anim,
        palette = PokegearSources.phoneSpritePalette,
        banks = selection.banks,
      },
    }
    phoneSprites[setName] = compileSpriteSet(
      phoneArchive,
      assets,
      "phone.sprites." .. setName,
      "phone-sprite-" .. setName,
      selection,
      PokegearSources.phoneSpritePalette
    )
  end

  local phoneSpritesDim = {}
  -- The live call darkens MAIN_OBJ entries 0x60..0x80 and 0..0x40
  -- with factor 8. The phone OBJ member uploads at entry 0x40, so
  -- only hardware slots 6..7 land inside this member as NCLR-local
  -- banks 2..3; the 0..0x40 range falls outside it. Dimmed frames keep
  -- the corrected bank mapping, geometry, and durations of the bright
  -- set under distinct staged paths.
  local phoneObjPalette =
    decodePaletteMember(phoneArchive, PokegearSources.phoneSpritePalette, "phone.spritesDim.palette")
  for setName, selection in pairs(PokegearSources.phoneSprites) do
    phoneSpritesDim[setName] = compileSpriteSet(
      phoneArchive,
      assets,
      "phone.spritesDim." .. setName,
      "phone-sprite-dim-" .. setName,
      selection,
      PokegearSources.phoneSpritePalette,
      withDimmedBanks(phoneObjPalette, { [2] = true, [3] = true })
    )
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
    configure = { foreground = configureForeground, patch = configurePatch, sprites = configureSprites },
    phone = {
      foreground = phoneForeground,
      foregroundDim = phoneForegroundDim,
      foregroundDimChoice = phoneForegroundDimChoice,
      dimShellForeground = phoneDimShellForeground,
      upper = phoneUpper,
      listPalette = phoneListPalette,
      listPaletteDim = phoneListPaletteDim,
      tooltipPalette = phoneTooltipPalette,
      windowPalette = phoneWindowPalette,
      sprites = phoneSprites,
      spritesDim = phoneSpritesDim,
    },
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
