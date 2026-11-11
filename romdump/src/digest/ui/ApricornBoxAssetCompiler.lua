-- Compiles the two visible Apricorn Box panes loaded by HGSS overlay 59.
-- Source basis: the retail ROM.

local Errors = require("libs.errors.src.Errors")
local Hashing = require("romdump.src.digest.Hashing")
local PngWriter = require("romdump.src.digest.PngEncoder")
local DerivedAssetContract = require("libs.assets.src.DerivedAssetContract")
local ApricornBoxAssetCache = require("libs.assets.src.ApricornBoxAssetCache")
local ApricornBoxSources = require("romdump.src.config.ApricornBoxSources")
local ItemSources = require("romdump.src.config.ItemSources")
local NarcCatalog = require("romdump.src.catalog.hgss.narcs")
local Lz10 = require("romdump.src.digest.Lz10")
local G2dDecoder = require("romdump.src.digest.ui.G2dDecoder")
local G2dRasterizer = require("romdump.src.digest.ui.G2dRasterizer")
local RgbaImage = require("romdump.src.digest.ui.RgbaImage")

local ApricornBoxAssetCompiler = {}

ApricornBoxAssetCompiler.ERROR = { SOURCE_INVALID = "APRICORN_BOX_SOURCE_INVALID" }

local BACKGROUNDS = ApricornBoxSources.backgroundArchive
local RESDAT = ApricornBoxSources.resdatArchive
local ACTION_MENU = ApricornBoxSources.actionMenuArchive
local PANE_ORDER = { "upper", "lower" }
local ROW_COUNT = 7

---@noreturn
local function sourceError(message, context)
  Errors.raise(ApricornBoxAssetCompiler.ERROR.SOURCE_INVALID, "Apricorn Box " .. message, context or {})
end

local function readMember(archive, archiveAlias, memberId, role, dependencies)
  local bytes, err = archive:readMember(memberId)
  if type(bytes) ~= "string" then
    sourceError("source member is unreadable: " .. role, { memberId = memberId, cause = err })
  end
  dependencies[#dependencies + 1] = {
    name = archiveAlias .. ":member:" .. memberId,
    role = role,
    sha1 = Hashing.sha1hex(bytes),
  }
  return bytes
end

local function decode(kind, bytes, role)
  local value, err = G2dDecoder[kind](bytes, { label = "apricorn-box:" .. role })
  if value == nil then
    sourceError("source resource does not decode: " .. role .. ": " .. tostring(err and err.message), { role = role })
  end
  return value
end

local function u32le(bytes, offset, role)
  if offset < 0 or offset + 4 > #bytes then
    sourceError("resource metadata is truncated", { role = role, sourceOffset = offset })
  end
  return string.byte(bytes, offset + 1)
    + string.byte(bytes, offset + 2) * 256
    + string.byte(bytes, offset + 3) * 65536
    + string.byte(bytes, offset + 4) * 16777216
end

-- One BG text ink as RGB triples from a decoded NCLR palette: palette slot
-- selects the 16-color ramp while foreground/shadow select its entries.
---@param palette G2dRasterizer.PaletteData
---@param spec { palette: integer, foreground: integer, shadow: integer }
---@param role string
---@return { foreground: { r: integer, g: integer, b: integer }, shadow: { r: integer, g: integer, b: integer } }
local function paletteInk(palette, spec, role)
  local function entry(index)
    local color = palette.colors[spec.palette * 16 + index + 1]
    if color == nil then
      sourceError("chrome ink references a missing palette entry", { role = role, index = index })
    end
    return { r = assert(color.r), g = assert(color.g), b = assert(color.b) }
  end
  return { foreground = entry(spec.foreground), shadow = entry(spec.shadow) }
end

local function parseResourceList(bytes, role)
  local resources = {}
  local offset = 4
  while true do
    local narcId = u32le(bytes, offset, role)
    if narcId == 0xFFFFFFFE then
      return resources
    end
    local objectId = u32le(bytes, offset + 12, role)
    if resources[objectId] ~= nil then
      sourceError("resource list repeats an object id", { role = role, objectId = objectId })
    end
    local compressed = u32le(bytes, offset + 8, role)
    if compressed ~= 0 and compressed ~= 1 then
      sourceError(
        "resource list has an invalid compressed flag",
        { role = role, objectId = objectId, compressed = compressed }
      )
    end
    resources[objectId] = {
      narcId = narcId,
      fileId = u32le(bytes, offset + 4, role),
      compressed = compressed == 1,
    }
    offset = offset + 24
  end
end

local function resourceSetAt(bytes, resourceSet)
  local offset = resourceSet * 32
  local ids = {}
  for index, kind in ipairs({ "char", "palette", "cell", "animation" }) do
    ids[kind] = u32le(bytes, offset + (index - 1) * 4, "selection cursor header")
  end
  return ids
end

local function catalogEntry(narcId)
  for symbol, entry in pairs(NarcCatalog.entries) do
    if entry.narcId == narcId then
      return symbol, entry
    end
  end
  sourceError("resource table selects an unknown NARC identity", { narcId = narcId })
end

local function resolveSelectionResources(romFs, resourceTables, headerBytes, dependencies, knownArchives)
  local resourceSet = ApricornBoxSources.geometry.selectionCursorResourceSet
  local ids = resourceSetAt(headerBytes, resourceSet)
  local records = {}
  for _, kind in ipairs({ "char", "palette", "cell", "animation" }) do
    local record = resourceTables[kind][ids[kind]]
    if record == nil then
      sourceError("selection cursor resource is missing its table entry", {
        kind = kind,
        objectId = ids[kind],
        resourceSet = resourceSet,
      })
    end
    records[kind] = record
  end

  local archives = knownArchives
  local function decodeResource(kind)
    local record = records[kind]
    local archive = archives[record.narcId]
    if archive == nil then
      local symbol, expected = catalogEntry(record.narcId)
      local opened, openErr = romFs:openNarc(symbol)
      if opened == nil then
        sourceError("selection cursor resource archive is unavailable", {
          kind = kind,
          narcId = record.narcId,
          symbol = symbol,
          cause = openErr,
        })
      end
      local info = romFs:resolvedNarc(symbol)
      if info == nil or info.narcId ~= record.narcId or info.path ~= expected.path then
        sourceError("selection cursor resource archive disagrees with its catalog identity", {
          kind = kind,
          narcId = record.narcId,
          symbol = symbol,
        })
      end
      local resolvedInfo = assert(info, "resolved resource archive identity is verified")
      dependencies[#dependencies + 1] = {
        name = symbol .. ":narc",
        sha1 = Hashing.sha1hex(assert(romFs:read(resolvedInfo.fileId), "resolved resource NARC is readable")),
      }
      archive = { handle = opened, alias = symbol }
      archives[record.narcId] = archive
    end
    local bytes = readMember(archive.handle, archive.alias, record.fileId, "selection-cursor-" .. kind, dependencies)
    if record.compressed then
      local decodedBytes, decodeErr = Lz10.decode(bytes)
      if decodedBytes == nil then
        sourceError("selection cursor compressed resource is invalid", {
          kind = kind,
          narcId = record.narcId,
          fileId = record.fileId,
          cause = decodeErr,
        })
      end
      bytes = assert(decodedBytes, "invalid compressed resources fail above")
    end
    local decoder = {
      char = "decodeChar",
      palette = "decodePalette",
      cell = "decodeCell",
      animation = "decodeAnimation",
    }
    return decode(decoder[kind], bytes, "selection-cursor-" .. kind)
  end

  return decodeResource("char"), decodeResource("palette"), decodeResource("cell"), decodeResource("animation")
end

---@param image table<string, unknown>
---@param role string
---@param assets table<string, string>
---@return table<string, unknown>
local function imageAsset(image, role, assets)
  local path = ApricornBoxAssetCache.assetDir() .. "/" .. role .. ".png"
  assets[path] = PngWriter.encode(image.width, image.height, image.pixels)
  return { image = path, width = image.width, height = image.height, offsetX = 0, offsetY = 0 }
end

local function compileIconRow(char, palette, cell, animation, rowIndex, assets, dependencies)
  local source = ApricornBoxSources.geometry.rowIcons[rowIndex]
  local sequence = animation.anims[source.animation + 1]
  if type(sequence) ~= "table" or type(sequence.frames) ~= "table" or #sequence.frames == 0 then
    sourceError("Apricorn sprite sequence is missing frames", { animation = source.animation })
  end
  if sequence.playMode ~= "forward" and sequence.playMode ~= "forward_loop" then
    sourceError("Apricorn sprite sequence has an unsupported playback mode", {
      animation = source.animation,
      playMode = sequence.playMode,
    })
  end
  local frames = {}
  local totalTicks = 0
  for frameIndex, sourceFrame in ipairs(sequence.frames) do
    if type(sourceFrame.duration) ~= "number" or sourceFrame.duration < 1 or sourceFrame.duration % 1 ~= 0 then
      sourceError("Apricorn sprite frame duration is invalid", { animation = source.animation, frame = frameIndex - 1 })
    end
    -- No palette override: each row's cell carries its own NCLR slot, so the
    -- compiled sprite keeps its source tint instead of the chrome grayscale.
    local rendered = G2dRasterizer.renderAnimationFrame(
      char,
      palette,
      cell,
      sequence,
      frameIndex,
      { asset = "Apricorn Box", animation = source.animation, frame = frameIndex - 1 },
      nil
    )
    local path = ApricornBoxAssetCache.assetDir() .. "/apricorn-" .. rowIndex .. "-frame-" .. frameIndex .. ".png"
    assets[path] = PngWriter.encode(rendered.width, rendered.height, rendered.pixels)
    frames[#frames + 1] = {
      image = path,
      width = rendered.width,
      height = rendered.height,
      offsetX = rendered.offset.x,
      offsetY = rendered.offset.y,
      durationTicks = sourceFrame.duration,
    }
    totalTicks = totalTicks + sourceFrame.duration
  end
  dependencies[#dependencies + 1] = {
    name = "overlay59:row-animation:" .. source.animation,
    sha1 = Hashing.hashLua({ playMode = sequence.playMode, frames = sequence.frames, palette = "cell" }),
  }
  local itemId = assert(ApricornBoxSources.itemIds[rowIndex], "the Box row carries its native item identity")
  assert(
    ItemSources.itemKeys[itemId] == ApricornBoxSources.itemKeys[rowIndex],
    "the Box row item identity matches the item catalog"
  )
  return {
    apricornKey = ApricornBoxSources.itemKeys[rowIndex],
    itemId = itemId,
    nameMessageId = ApricornBoxSources.messages.itemNames[rowIndex],
    descriptionMessageId = ApricornBoxSources.messages.itemDescriptions[rowIndex],
    icon = {
      x = source.x,
      y = source.y,
      playMode = sequence.playMode,
      frames = frames,
      totalTicks = totalTicks,
    },
    quantity = {
      window = ApricornBoxSources.geometry.countWindows[rowIndex],
      alignment = ApricornBoxSources.geometry.countText.alignment,
      textWidth = ApricornBoxSources.geometry.countText.width,
      textHeight = ApricornBoxSources.geometry.countText.height,
      color = ApricornBoxSources.geometry.countText.color,
    },
  }
end

-- The shared cursor resource also carries the close-button states, the hand
-- cursor, and the quantity chrome: close frames 0-2, hand frames 3-5, arrow
-- frames 24-27, and confirm-button frames 28-31. They compile through the
-- same states map so the renderer addresses them by source sequence.
local function compileSelectionCursor(char, palette, cell, animation, assets, dependencies)
  local states = {}
  for _, sequenceId in ipairs({ 0, 1, 2, 3, 4, 5, 24, 25, 26, 27, 28, 29, 30, 31 }) do
    local sequence = animation.anims[sequenceId + 1]
    if type(sequence) ~= "table" or type(sequence.frames) ~= "table" or #sequence.frames == 0 then
      sourceError("selection cursor animation sequence is missing frames", { animation = sequenceId })
    end
    local frames = {}
    local totalTicks = 0
    for frameIndex, sourceFrame in ipairs(sequence.frames) do
      if type(sourceFrame.duration) ~= "number" or sourceFrame.duration < 1 or sourceFrame.duration % 1 ~= 0 then
        sourceError("selection cursor frame duration is invalid", { animation = sequenceId, frame = frameIndex - 1 })
      end
      -- Close (0-2) and confirm-button (28-31) cells carry their own blue
      -- NCLR slots (11 and 12); only the hand (3-5) and arrows (24-27)
      -- live in the grayscale chrome slot zero, so only those pin it.
      local paletteOverride = nil
      if (sequenceId >= 3 and sequenceId <= 5) or (sequenceId >= 24 and sequenceId <= 27) then
        paletteOverride = 0
      end
      local rendered = G2dRasterizer.renderAnimationFrame(char, palette, cell, sequence, frameIndex, {
        asset = "Apricorn Box",
        role = "selection-cursor",
        resourceHeader = RESDAT.members.header,
        animation = sequenceId,
      }, paletteOverride)
      local path = ApricornBoxAssetCache.assetDir()
        .. "/selection-cursor-sequence-"
        .. sequenceId
        .. "-frame-"
        .. frameIndex
        .. ".png"
      assets[path] = PngWriter.encode(rendered.width, rendered.height, rendered.pixels)
      frames[#frames + 1] = {
        image = path,
        width = rendered.width,
        height = rendered.height,
        offsetX = rendered.offset.x,
        offsetY = rendered.offset.y,
        durationTicks = sourceFrame.duration,
      }
      totalTicks = totalTicks + sourceFrame.duration
    end
    states[sequenceId] = { frames = frames, totalTicks = totalTicks, playMode = sequence.playMode }
    dependencies[#dependencies + 1] = {
      name = RESDAT.alias .. ":selection-cursor:header:" .. RESDAT.members.header .. ":animation:" .. sequenceId,
      sha1 = Hashing.hashLua({
        playMode = sequence.playMode,
        frames = sequence.frames,
        palette = paletteOverride == nil and "source" or "slot0",
      }),
    }
  end
  local initial = states[0].frames[1]
  local initialPath = ApricornBoxAssetCache.assetDir() .. "/selection-cursor.png"
  assets[initialPath] = assets[initial.image]
  return {
    image = initialPath,
    width = initial.width,
    height = initial.height,
    offsetX = initial.offsetX,
    offsetY = initial.offsetY,
    states = states,
  }
end

---@param romFs RomFs
---@return table<string, unknown>
function ApricornBoxAssetCompiler.compile(romFs)
  local metadata = romFs:metadata()
  assert(type(metadata) == "table" and type(metadata.sha1) == "string", "Apricorn Box source needs a ROM SHA-1")
  local archive, archiveErr = romFs:openNarc(BACKGROUNDS.alias)
  if archive == nil then
    sourceError("UI archive is unavailable", { cause = archiveErr })
  end
  local uiArchive = assert(archive, "Apricorn Box UI archive availability was checked")
  local archiveInfo = assert(romFs:resolvedNarc(BACKGROUNDS.alias), "Apricorn Box background archive alias resolves")
  if archiveInfo.narcId ~= BACKGROUNDS.narcId or archiveInfo.path ~= BACKGROUNDS.path then
    sourceError("UI archive does not match the overlay source identity", {
      narcId = archiveInfo.narcId,
      path = archiveInfo.path,
    })
  end
  if uiArchive:memberCount() <= BACKGROUNDS.members.apricornSprite.animation then
    sourceError("UI archive is missing a source member", { memberCount = uiArchive:memberCount() })
  end

  local resdat, resdatErr = romFs:openNarc(RESDAT.alias)
  if resdat == nil then
    sourceError("sprite resource archive is unavailable", { cause = resdatErr })
  end
  local resourceArchive = assert(resdat, "Apricorn Box sprite archive availability was checked")
  local resdatInfo = assert(romFs:resolvedNarc(RESDAT.alias), "Apricorn Box sprite resdat alias resolves")
  if resdatInfo.narcId ~= RESDAT.narcId or resdatInfo.path ~= RESDAT.path then
    sourceError("sprite resource archive does not match overlay source identity", {
      narcId = resdatInfo.narcId,
      path = resdatInfo.path,
    })
  end
  local actionMenuArchive, actionMenuErr = romFs:openNarc(ACTION_MENU.alias)
  if actionMenuArchive == nil then
    sourceError("action menu archive is unavailable", { cause = actionMenuErr })
  end
  local menuArchive = assert(actionMenuArchive, "Apricorn Box action menu archive availability was checked")
  local menuInfo = assert(romFs:resolvedNarc(ACTION_MENU.alias), "Apricorn Box action menu alias resolves")
  if menuInfo.narcId ~= ACTION_MENU.narcId or menuInfo.path ~= ACTION_MENU.path then
    sourceError("action menu archive does not match the touchscreen list source", {
      narcId = menuInfo.narcId,
      path = menuInfo.path,
    })
  end
  if menuArchive:memberCount() ~= 2 then
    sourceError("touchscreen list art has an unexpected member count", { memberCount = menuArchive:memberCount() })
  end
  local resdatMemberIds = {
    RESDAT.members.animation,
    RESDAT.members.cell,
    RESDAT.members.char,
    RESDAT.members.palette,
    RESDAT.members.header,
  }
  if resourceArchive:memberCount() <= RESDAT.members.header then
    sourceError("sprite resource archive is missing a source member", { memberCount = resourceArchive:memberCount() })
  end

  local archiveBytes = assert(romFs:read(archiveInfo.fileId), "Apricorn Box NARC bytes are readable")
  local dependencies = {
    {
      name = "assetContract",
      sha1 = ApricornBoxAssetCache.FORMAT .. ":" .. ApricornBoxAssetCache.SCHEMA,
    },
    { name = BACKGROUNDS.alias .. ":narc", sha1 = Hashing.sha1hex(archiveBytes) },
    {
      name = RESDAT.alias .. ":narc",
      sha1 = Hashing.sha1hex(assert(romFs:read(resdatInfo.fileId), "sprite resdat NARC bytes are readable")),
    },
    {
      name = ACTION_MENU.alias .. ":narc",
      sha1 = Hashing.sha1hex(assert(romFs:read(menuInfo.fileId), "touchscreen list NARC bytes are readable")),
    },
    { name = "sourceConfig", sha1 = Hashing.hashLua(ApricornBoxSources) },
    { name = "assetContractIdentity", sha1 = Hashing.hashLua(DerivedAssetContract.apricornBox) },
  }
  local menuPalette = decode(
    "decodePalette",
    readMember(menuArchive, ACTION_MENU.alias, ACTION_MENU.members.palette, "action-menu-palette", dependencies),
    "action-menu-palette"
  )
  ---@cast menuPalette G2dRasterizer.PaletteData
  local menuChar = decode(
    "decodeChar",
    readMember(menuArchive, ACTION_MENU.alias, ACTION_MENU.members.char, "action-menu-char", dependencies),
    "action-menu-char"
  )
  ---@cast menuChar G2dRasterizer.CharData
  if menuChar.depth ~= 3 or #menuPalette.colors ~= 16 then
    sourceError("touchscreen list art is not the source NCLR/4bpp NCGR pair", {
      depth = menuChar.depth,
      paletteColors = #menuPalette.colors,
    })
  end
  local menuTiles = {}
  for tileIndex = 0, 26 do
    menuTiles[#menuTiles + 1] = tileIndex
  end
  local menuTileImage = G2dRasterizer.renderTiles(menuChar, menuPalette, menuTiles, {
    asset = "TouchscreenListMenu",
    member = ACTION_MENU.members.char,
    role = "NARC165-button-tiles",
  })
  local resdatMembers = {}
  for _, memberId in ipairs(resdatMemberIds) do
    resdatMembers[memberId] =
      readMember(resourceArchive, RESDAT.alias, memberId, "sprite-resdat-" .. memberId, dependencies)
  end
  local spriteMembers = BACKGROUNDS.members.apricornSprite
  local spriteChar = decode(
    "decodeChar",
    readMember(uiArchive, BACKGROUNDS.alias, spriteMembers.char, "apricorn-sprite-char", dependencies),
    "apricorn-sprite-char"
  )
  local spritePalette = decode(
    "decodePalette",
    readMember(uiArchive, BACKGROUNDS.alias, spriteMembers.palette, "apricorn-sprite-palette", dependencies),
    "apricorn-sprite-palette"
  )
  local spriteCell = decode(
    "decodeCell",
    readMember(uiArchive, BACKGROUNDS.alias, spriteMembers.cell, "apricorn-sprite-cell", dependencies),
    "apricorn-sprite-cell"
  )
  local spriteAnimation = decode(
    "decodeAnimation",
    readMember(uiArchive, BACKGROUNDS.alias, spriteMembers.animation, "apricorn-sprite-animation", dependencies),
    "apricorn-sprite-animation"
  )
  local assets = {}
  local panes = {}
  local lowerTiles = nil
  for _, paneName in ipairs(PANE_ORDER) do
    local members = BACKGROUNDS.members[paneName]
    local palette = decode(
      "decodePalette",
      readMember(uiArchive, BACKGROUNDS.alias, members.palette, paneName .. "-palette", dependencies),
      paneName .. "-palette"
    )
    ---@cast palette G2dRasterizer.PaletteData
    local char = decode(
      "decodeChar",
      readMember(uiArchive, BACKGROUNDS.alias, members.char, paneName .. "-char", dependencies),
      paneName .. "-char"
    )
    ---@cast char G2dRasterizer.CharData
    local screen = decode(
      "decodeScreen",
      readMember(uiArchive, BACKGROUNDS.alias, members.screen, paneName .. "-screen", dependencies),
      paneName .. "-screen"
    )
    ---@cast screen G2dRasterizer.ScreenData
    if screen.width < 256 or screen.height < 192 then
      sourceError("background does not cover one native display", {
        pane = paneName,
        width = screen.width,
        height = screen.height,
      })
    end
    local rendered = G2dRasterizer.renderScreen(char, palette, screen, {
      asset = "Apricorn Box",
      member = members.screen,
      role = paneName .. "-background",
    }, { transparentZero = false })
    rendered = RgbaImage.crop(rendered, { x = 0, y = 0, width = 256, height = 192 }, paneName .. " native display")
    panes[paneName] = imageAsset(rendered, paneName .. "-background", assets)
    if paneName == "lower" then
      lowerTiles = { char = char, palette = palette }
    end
  end
  -- The Kurt quantity overlay shares the lower display tiles and palettes.
  local panelScreen = decode(
    "decodeScreen",
    readMember(uiArchive, BACKGROUNDS.alias, BACKGROUNDS.members.quantityPanel, "quantity-panel-screen", dependencies),
    "quantity-panel-screen"
  )
  ---@cast panelScreen G2dRasterizer.ScreenData
  if panelScreen.width < 256 or panelScreen.height < 192 then
    sourceError("quantity panel does not cover one native display", {
      width = panelScreen.width,
      height = panelScreen.height,
    })
  end
  local lower = assert(lowerTiles, "the lower display tiles back the quantity overlay")
  local panelRendered = G2dRasterizer.renderScreen(lower.char, lower.palette, panelScreen, {
    asset = "Apricorn Box",
    member = BACKGROUNDS.members.quantityPanel,
    role = "quantity-panel",
  }, { transparentZero = true })
  panelRendered = RgbaImage.crop(panelRendered, { x = 0, y = 0, width = 256, height = 192 }, "quantity panel display")
  local quantityPanel = imageAsset(panelRendered, "quantity-panel", assets)

  local rows = {}
  for rowIndex = 1, ROW_COUNT do
    rows[rowIndex] =
      compileIconRow(spriteChar, spritePalette, spriteCell, spriteAnimation, rowIndex, assets, dependencies)
  end
  local resourceTables = {
    animation = parseResourceList(resdatMembers[RESDAT.members.animation], "selection cursor animation table"),
    cell = parseResourceList(resdatMembers[RESDAT.members.cell], "selection cursor cell table"),
    char = parseResourceList(resdatMembers[RESDAT.members.char], "selection cursor character table"),
    palette = parseResourceList(resdatMembers[RESDAT.members.palette], "selection cursor palette table"),
  }
  local selectionChar, selectionPalette, selectionCell, selectionAnimation = resolveSelectionResources(
    romFs,
    resourceTables,
    resdatMembers[RESDAT.members.header],
    dependencies,
    { [archiveInfo.narcId] = { handle = uiArchive, alias = BACKGROUNDS.alias } }
  )
  local selectionCursor =
    compileSelectionCursor(selectionChar, selectionPalette, selectionCell, selectionAnimation, assets, dependencies)

  local menuPath = ApricornBoxAssetCache.assetDir() .. "/action-menu-tiles.png"
  assets[menuPath] = PngWriter.encode(menuTileImage.width, menuTileImage.height, menuTileImage.pixels)

  local closeInk = paletteInk(lower.palette, ApricornBoxSources.geometry.closeInk, "close-label")

  local dependencyHash = Hashing.hashLua(dependencies)
  local manifest = {
    schema = ApricornBoxAssetCache.SCHEMA,
    upper = panes.upper,
    lower = panes.lower,
    actionMenu = {
      image = menuPath,
      width = menuTileImage.width,
      height = menuTileImage.height,
      offsetX = 0,
      offsetY = 0,
      charOffset = ApricornBoxSources.geometry.touchMenu.actionCharOffset,
    },
    messageBankId = ApricornBoxSources.messages.bankId,
    pluralBankId = ItemSources.messageBanks.namePlural,
    rows = rows,
    selectionCursor = selectionCursor,
    quantityPanel = quantityPanel,
    quantityLayout = ApricornBoxSources.geometry.quantityLayout,
    panelMessageId = ApricornBoxSources.messages.panelMessage,
    rowHitboxes = ApricornBoxSources.geometry.rowHitboxes,
    closeButton = ApricornBoxSources.geometry.closeButton,
    headerWindow = ApricornBoxSources.geometry.headerWindow,
    titleWindow = ApricornBoxSources.geometry.titleWindow,
    closeWindow = ApricornBoxSources.geometry.closeWindow,
    closeInk = closeInk,
    titleMessageId = ApricornBoxSources.messages.title,
    closeMessageId = ApricornBoxSources.messages.close,
    browseHeaderMessageId = ApricornBoxSources.messages.browseHeader,
    selectedDetail = ApricornBoxSources.geometry.selectedDetail,
    controls = {
      sourceTable = ApricornBoxSources.geometry.touchMenu.sourceTable,
      windowCount = ApricornBoxSources.geometry.touchMenu.windowCount,
      windowOriginTiles = ApricornBoxSources.geometry.touchMenu.windowOriginTiles,
      windowWidthTiles = ApricornBoxSources.geometry.touchMenu.windowWidthTiles,
      selection = ApricornBoxSources.geometry.touchMenu.selection,
      quantityHitboxes = ApricornBoxSources.geometry.touchMenu.quantityHitboxes,
      actions = ApricornBoxSources.geometry.touchMenu.actions,
    },
    actionMessageIds = ApricornBoxSources.messages.actionLabels,
    flowMessageIds = ApricornBoxSources.messages.flowMessages,
    modeMessages = ApricornBoxSources.messages.modeMessages,
  }
  local provenance = {
    cacheFormat = ApricornBoxAssetCache.FORMAT,
    schema = ApricornBoxAssetCache.SCHEMA,
    versionRomSha1 = metadata.sha1,
    dependencyHash = dependencyHash,
    source = {
      backgrounds = { alias = BACKGROUNDS.alias, narcId = archiveInfo.narcId, path = archiveInfo.path },
      resources = { alias = RESDAT.alias, narcId = resdatInfo.narcId, path = resdatInfo.path },
      actionMenu = { alias = ACTION_MENU.alias, narcId = menuInfo.narcId, path = menuInfo.path },
    },
    dependencies = dependencies,
  }
  return {
    manifest = manifest,
    assets = assets,
    provenance = provenance,
    marker = ApricornBoxAssetCache.marker(metadata.sha1, dependencyHash),
  }
end

return ApricornBoxAssetCompiler
