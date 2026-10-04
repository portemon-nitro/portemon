-- Compiles the HGSS mart source catalog and presentation into source-free
-- generated assets. Source resources follow the pinned pret/pokeheartgold
-- mart command and shop overlay tables.

local Errors = require("libs.errors.src.Errors")
local Hashing = require("romdump.src.digest.Hashing")
local Lz10 = require("romdump.src.digest.Lz10")
local PngWriter = require("libs.assets.src.PngWriter")
local MartAssetSchema = require("libs.assets.src.MartAssetSchema")
local MartCache = require("libs.assets.src.MartCache")
local ItemSources = require("romdump.src.config.ItemSources")
local MartSources = require("romdump.src.config.MartSources")
local G2dDecoder = require("romdump.src.digest.ui.G2dDecoder")
local G2dRasterizer = require("romdump.src.digest.ui.G2dRasterizer")
local RgbaImage = require("romdump.src.digest.ui.RgbaImage")
local FieldMessageBank = require("romdump.src.digest.ui.FieldMessageBank")
local FieldMessageTokenizer = require("romdump.src.digest.ui.FieldMessageTokenizer")
local FieldMessageText = require("libs.assets.src.field.FieldMessageText")
local charmap = require("romdump.src.reference.hgss.charmap")

local MartAssetCompiler = {}

MartAssetCompiler.ERROR = { SOURCE_INVALID = "MART_SOURCE_INVALID" }

local function sourceError(message, context)
  Errors.raise(MartAssetCompiler.ERROR.SOURCE_INVALID, "mart " .. message, context or {})
end

local function readMember(archive, memberId, role, archiveName, dependencies)
  local bytes, err = archive:readMember(memberId)
  if not bytes then
    sourceError("member is unreadable: " .. role, {
      archive = archiveName,
      memberId = memberId,
      role = role,
      cause = err,
    })
  end
  dependencies[#dependencies + 1] = {
    name = archiveName .. ":member:" .. memberId,
    role = role,
    sha1 = Hashing.sha1hex(bytes),
  }
  if string.byte(bytes, 1) == 0x10 then
    local plain, decodeError = Lz10.decode(bytes)
    if not plain then
      error(decodeError, 0)
    end
    return plain
  end
  return bytes
end

local function decode(kind, bytes, role)
  local value, err = G2dDecoder[kind](bytes, { label = "mart:" .. role })
  if not value then
    sourceError("resource does not decode: " .. role .. ": " .. tostring(err and err.message), { role = role })
  end
  return value
end

local function imageAsset(image, role, assets)
  local path = MartCache.assetDir() .. "/" .. role .. ".png"
  assets[path] = PngWriter.encode(image.width, image.height, image.pixels)
  return { image = path, width = image.width, height = image.height, offsetX = 0, offsetY = 0 }
end

local function descriptionText(bank, messageId, role)
  local message = bank.messages[messageId + 1]
  if message == nil then
    sourceError("description message is absent", { role = role, messageId = messageId, count = bank.messageCount })
  end
  message = assert(message)
  local tokens, tokenErr = FieldMessageTokenizer.tokenize(message.raw, charmap, {})
  if not tokens then
    sourceError(
      "description message cannot be tokenized",
      { role = role, messageId = messageId, cause = tokenErr and tokenErr.code }
    )
  end
  tokens = assert(tokens)
  local text = {}
  for _, token in ipairs(tokens) do
    if token.kind == "glyph" then
      text[#text + 1] = token.text
    elseif token.kind == "line_break" then
      text[#text + 1] = "\n"
    elseif token.kind == "prompt_break" then
      text[#text + 1] = "\r"
    elseif token.kind == "page_break" then
      text[#text + 1] = "\f"
    elseif token.kind ~= "eos" and token.kind ~= "style" then
      sourceError("description message contains an unsupported control", {
        role = role,
        messageId = messageId,
        kind = token.kind,
        control = token.control,
      })
    end
  end
  return table.concat(text)
end

local function catalogFromSources(descriptionBanks)
  local source = MartSources.stockTables
  local catalog = {
    schema = MartCache.CATALOG_SCHEMA,
    normalTiers = source.normalTiers,
    specialStocks = {},
    athleteStocks = {},
    dataCardStocks = {},
    sealStocks = {},
    decorationStocks = {},
    cards = {},
    apricorns = {},
    seals = {},
    decorations = {},
  }
  local function catalogPrices(sourceLists)
    local lists = {}
    for listIndex, sourceList in ipairs(sourceLists) do
      local list = {}
      for _, itemKey in ipairs(sourceList) do
        list[#list + 1] = { subjectKey = itemKey, price = { kind = "catalog" } }
      end
      lists[listIndex] = list
    end
    return lists
  end
  local function fixedPrices(sourceLists)
    local lists = {}
    for listIndex, sourceList in ipairs(sourceLists) do
      local list = {}
      for _, entry in ipairs(sourceList) do
        list[#list + 1] = { subjectKey = entry[1], price = { kind = "fixed", value = entry[2] } }
      end
      lists[listIndex] = list
    end
    return lists
  end
  catalog.specialStocks = catalogPrices(source.specialStocks)
  catalog.athleteStocks = fixedPrices(source.athleteStocks)
  catalog.dataCardStocks = fixedPrices(source.dataCardStocks)
  catalog.sealStocks = catalogPrices(source.sealStocks)
  catalog.decorationStocks = catalogPrices(source.decorationStocks)
  for ownershipIndex = 0, 26 do
    local itemKey = assert(ItemSources.itemKeys[505 + ownershipIndex], "Data Card source identity has no semantic key")
    catalog.cards[itemKey] = { itemKey = itemKey, ownershipIndex = ownershipIndex }
  end
  for _, itemKey in ipairs({
    "RED_APRICORN",
    "BLU_APRICORN",
    "YLW_APRICORN",
    "GRN_APRICORN",
    "PNK_APRICORN",
    "WHT_APRICORN",
    "BLK_APRICORN",
  }) do
    catalog.apricorns[itemKey] = itemKey:lower()
  end
  for _, sealList in ipairs(source.sealStocks) do
    for _, sealKey in ipairs(sealList) do
      if catalog.seals[sealKey] == nil then
        local sourceId = source.sealIds[sealKey]
        if sourceId == nil then
          sourceError("seal has no audited semantic source id", { seal = sealKey })
        end
        local displayItemKey = ItemSources.itemKeys[sourceId]
        if displayItemKey == nil then
          sourceError("seal has no source item-art alias", { seal = sealKey, sourceId = sourceId })
        end
        local descriptionSource = MartSources.messages.descriptionSources.seals
        local description = descriptionText(
          descriptionBanks[descriptionSource.bank],
          sourceId + descriptionSource.indexOffset,
          "seal:" .. sealKey
        )
        catalog.seals[sealKey] = { displayItemKey = displayItemKey, description = description }
      end
    end
  end
  for _, decorationList in ipairs(source.decorationStocks) do
    for _, decorationKey in ipairs(decorationList) do
      if catalog.decorations[decorationKey] == nil then
        local sourceId = source.decorationIds[decorationKey]
        if sourceId == nil then
          sourceError("decoration has no audited semantic source id", { decoration = decorationKey })
        end
        local displayItemKey = ItemSources.itemKeys[sourceId]
        if displayItemKey == nil then
          sourceError("decoration has no source item-art alias", { decoration = decorationKey, sourceId = sourceId })
        end
        local descriptionSource = MartSources.messages.descriptionSources.decorations
        local description = descriptionText(
          descriptionBanks[descriptionSource.bank],
          sourceId + descriptionSource.indexOffset,
          "decoration:" .. decorationKey
        )
        catalog.decorations[decorationKey] = { displayItemKey = displayItemKey, description = description }
      end
    end
  end
  return catalog
end

local function sameArguments(actual, expected)
  if type(actual) ~= "table" or #actual ~= #expected then
    return false
  end
  for index, value in ipairs(expected) do
    if actual[index] ~= value then
      return false
    end
  end
  return true
end

local function compileMessageProgram(tokens, role)
  local parts, literal = {}, {}
  local bindings = MartSources.messages.bindings[role] or {}
  local substitutionIndex = 0
  local function flush()
    if #literal > 0 then
      parts[#parts + 1] = { kind = "literal", value = table.concat(literal) }
      literal = {}
    end
  end
  for _, token in ipairs(tokens) do
    if token.kind == "glyph" then
      literal[#literal + 1] = token.text
    elseif token.kind == "line_break" then
      flush()
      parts[#parts + 1] = { kind = "line" }
    elseif token.kind == "prompt_break" then
      flush()
      parts[#parts + 1] = { kind = "clear" }
    elseif token.kind == "page_break" then
      flush()
      parts[#parts + 1] = { kind = "scroll" }
    elseif token.kind == "substitution" then
      flush()
      substitutionIndex = substitutionIndex + 1
      local expected = bindings[substitutionIndex]
      local actualVariable = token.control - FieldMessageText.STRVAR_1
      if
        expected == nil
        or token.name ~= "STRVAR_1"
        or actualVariable ~= expected.variable
        or not sameArguments(token.args, expected.args)
      then
        sourceError("message substitution does not match its role specification", {
          role = role,
          substitutionIndex = substitutionIndex,
          expected = expected,
          actual = { name = token.name, variable = actualVariable, args = token.args },
        })
      end
      local binding = assert(expected, "validated source binding exists")
      parts[#parts + 1] = { kind = "binding", name = binding.name }
    elseif token.kind == "wait" then
      flush()
      parts[#parts + 1] = { kind = "callback", name = "transaction_received" }
    elseif token.kind == "printer_callback" and token.control == MartSources.messages.transactionReceivedControl then
      flush()
      parts[#parts + 1] = { kind = "callback", name = "transaction_received" }
    elseif token.kind == "style" then
      -- Color and alignment are represented by the owning textbox palette and
      -- alignment; they carry no independent message content.
    elseif token.kind ~= "eos" then
      sourceError("message contains an unsupported control", {
        role = role,
        kind = token.kind,
        control = token.control,
      })
    end
  end
  flush()
  if substitutionIndex ~= #bindings then
    sourceError("message is missing a role substitution", {
      role = role,
      expectedCount = #bindings,
      actualCount = substitutionIndex,
      nextExpected = bindings[substitutionIndex + 1],
    })
  end
  return { parts = parts }
end

local function compileMessages(archive, dependencies)
  local member = readMember(archive, MartSources.messages.bank, "mart-message-bank", "messages", dependencies)
  local bank, err = FieldMessageBank.decode(member, { label = "mart messages" })
  if not bank then
    sourceError("message bank does not decode", { cause = err and err.code })
  end
  bank = assert(bank)
  local templates, labels = {}, {}
  for role, messageIndex in pairs(MartSources.messages.roles) do
    local message = bank.messages[messageIndex + 1]
    if message == nil then
      sourceError("message role is absent", { role = role, messageIndex = messageIndex })
    end
    message = assert(message)
    local tokens, tokenErr = FieldMessageTokenizer.tokenize(message.raw, charmap, {})
    if not tokens then
      sourceError("message role cannot be tokenized", { role = role, cause = tokenErr and tokenErr.code })
    end
    tokens = assert(tokens)
    templates[role] = compileMessageProgram(tokens, role)
    labels[role] = FieldMessageText.tokensToText(tokens)
  end
  local descriptionBanks = { [MartSources.messages.bank] = bank }
  for _, kind in ipairs({ "seals", "decorations" }) do
    local source = MartSources.messages.descriptionSources[kind]
    local raw =
      readMember(archive, source.bank, kind .. "-descriptions", MartSources.messages.archive.alias, dependencies)
    local descriptionBank, descriptionErr = FieldMessageBank.decode(raw, { label = "mart " .. kind .. " descriptions" })
    if not descriptionBank then
      sourceError("description bank does not decode", { role = kind, cause = descriptionErr and descriptionErr.code })
    end
    descriptionBanks[source.bank] = assert(descriptionBank)
  end
  return templates, labels, descriptionBanks
end

local function copyRecord(value)
  if type(value) ~= "table" then
    return value
  end
  local result = {}
  for key, entry in pairs(value) do
    result[key] = copyRecord(entry)
  end
  return result
end

local function rgba(palette, index)
  local color = assert(palette.colors[index + 1], "source text color is present")
  return { color.r, color.g, color.b, 255 }
end

local function _compile(romFs)
  assert(
    romFs
      and type(romFs.metadata) == "function"
      and type(romFs.read) == "function"
      and type(romFs.openNarc) == "function"
      and type(romFs.resolvedNarc) == "function",
    "mart compilation needs RomFs"
  )
  local metadata = romFs:metadata()
  assert(type(metadata) == "table" and type(metadata.sha1) == "string", "mart source metadata needs a ROM SHA-1")
  local dependencies = {
    { name = "assetContract", sha1 = MartCache.FORMAT .. ":" .. MartCache.CATALOG_SCHEMA .. ":" .. MartCache.SCHEMA },
    { name = "martSources", sha1 = Hashing.hashLua(MartSources) },
    { name = "itemKeys", sha1 = Hashing.hashLua(ItemSources.itemKeys) },
  }
  local assets = {}
  local archive, archiveErr = romFs:openNarc(MartSources.archive.alias)
  if not archive then
    sourceError("resource archive is unavailable", { cause = archiveErr and archiveErr.code })
  end
  local archiveInfo = assert(romFs:resolvedNarc(MartSources.archive.alias), "mart NARC alias resolves")
  dependencies[#dependencies + 1] = {
    name = MartSources.archive.alias .. ":narc",
    sha1 = Hashing.sha1hex(assert(romFs:read(archiveInfo.fileId), "mart NARC bytes are readable")),
  }
  local resdatArchive, resdatErr = romFs:openNarc(MartSources.resdat.alias)
  if not resdatArchive then
    sourceError("resdat correlation archive is unavailable", { cause = resdatErr and resdatErr.code })
  end
  for _, memberId in ipairs({
    MartSources.resdat.members.animation,
    MartSources.resdat.members.cell,
    MartSources.resdat.members.char,
    MartSources.resdat.members.palette,
    MartSources.resdat.members.header,
  }) do
    readMember(resdatArchive, memberId, "resdat-correlation-" .. memberId, MartSources.resdat.alias, dependencies)
  end
  local resdatInfo = assert(romFs:resolvedNarc(MartSources.resdat.alias), "resdat alias resolves")
  dependencies[#dependencies + 1] = {
    name = MartSources.resdat.alias .. ":narc",
    sha1 = Hashing.sha1hex(assert(romFs:read(resdatInfo.fileId), "resdat NARC bytes are readable")),
  }
  local members = MartSources.archive.resources
  local char = decode(
    "decodeChar",
    readMember(archive, members.main.char, "main-char", MartSources.archive.alias, dependencies),
    "main-char"
  )
  local palette = decode(
    "decodePalette",
    readMember(archive, members.main.palette, "main-palette", MartSources.archive.alias, dependencies),
    "main-palette"
  )
  local lowerChar = decode(
    "decodeChar",
    readMember(archive, members.lower.char, "lower-char", MartSources.archive.alias, dependencies),
    "lower-char"
  )
  local lowerPalette = decode(
    "decodePalette",
    readMember(archive, members.lower.palette, "lower-palette", MartSources.archive.alias, dependencies),
    "lower-palette"
  )
  local controlChar = decode(
    "decodeChar",
    readMember(archive, members.controls.char, "control-char", MartSources.archive.alias, dependencies),
    "control-char"
  )
  local controlPalette = decode(
    "decodePalette",
    readMember(archive, members.controls.palette, "control-palette", MartSources.archive.alias, dependencies),
    "control-palette"
  )
  local cellData = decode(
    "decodeCell",
    readMember(archive, members.controls.cell, "control-cell", MartSources.archive.alias, dependencies),
    "control-cell"
  )
  local animation = decode(
    "decodeAnimation",
    readMember(archive, members.controls.animation, "control-animation", MartSources.archive.alias, dependencies),
    "control-animation"
  )
  local itemsScreen = decode(
    "decodeScreen",
    readMember(archive, members.main.itemsScreen, "main-items-screen", MartSources.archive.alias, dependencies),
    "main-items-screen"
  )
  local legacyScreen = decode(
    "decodeScreen",
    readMember(archive, members.main.legacyScreen, "main-legacy-screen", MartSources.archive.alias, dependencies),
    "main-legacy-screen"
  )
  local chromeMembers = {
    { memberId = members.main.chromeChars[1], role = "main-chrome-char-primary" },
    { memberId = members.main.chromeScreens[1], role = "main-chrome-screen-items" },
    { memberId = members.main.chromeScreens[2], role = "main-chrome-screen-legacy" },
    { memberId = members.main.chromeChars[2], role = "main-chrome-char-secondary" },
    { memberId = members.main.chromeScreens[3], role = "main-chrome-screen-secondary-items" },
    { memberId = members.main.chromeScreens[4], role = "main-chrome-screen-secondary-legacy" },
    { memberId = members.main.chromePalette, role = "main-chrome-palette" },
  }
  for _, resource in ipairs(chromeMembers) do
    readMember(archive, resource.memberId, resource.role, MartSources.archive.alias, dependencies)
  end
  local upperItems = G2dRasterizer.renderScreen(char, palette, itemsScreen, { role = "main-items" })
  local upperLegacy = G2dRasterizer.renderScreen(char, palette, legacyScreen, { role = "main-legacy" })
  local manifest = {
    schema = MartCache.SCHEMA,
    upper = {
      backgrounds = {
        items = imageAsset(upperItems, "upper-items", assets),
        legacy = imageAsset(upperLegacy, "upper-legacy", assets),
      },
      description = copyRecord(MartSources.geometry.upper.description),
      itemAnchor = copyRecord(MartSources.geometry.upper.itemAnchor),
    },
  }

  local lowerBrowse = decode(
    "decodeScreen",
    readMember(archive, members.lower.browseScreen, "lower-browse", MartSources.archive.alias, dependencies),
    "lower-browse"
  )
  local countLayer = decode(
    "decodeScreen",
    readMember(archive, members.lower.countLayerScreen, "lower-count-layer", MartSources.archive.alias, dependencies),
    "lower-count-layer"
  )
  local function countVariant(count)
    local entries = {}
    for index, entry in ipairs(countLayer.entries) do
      entries[index] = {
        tile = entry.tile,
        flipH = entry.flipH,
        flipV = entry.flipV,
        palette = entry.palette,
      }
    end
    local width = countLayer.width / 8
    for _, patch in ipairs(MartSources.countPatches[count]) do
      if patch.kind == "fill" then
        for y = patch.y, patch.y + patch.height - 1 do
          for x = patch.x, patch.x + patch.width - 1 do
            entries[y * width + x + 1] = { tile = 0, flipH = false, flipV = false, palette = 0 }
          end
        end
      elseif patch.kind == "copy" then
        for y = 0, patch.height - 1 do
          for x = 0, patch.width - 1 do
            local sourceIndex = (patch.sourceY + y) * width + patch.sourceX + x + 1
            local destIndex = (patch.destY + y) * width + patch.destX + x + 1
            entries[destIndex] = entries[sourceIndex]
          end
        end
      else
        sourceError("count patch kind is unknown", { count = count, kind = patch.kind })
      end
    end
    local patched = { width = countLayer.width, height = countLayer.height, entries = entries }
    local base = G2dRasterizer.renderScreen(lowerChar, lowerPalette, lowerBrowse, { role = "lower-browse" })
    local overlay = G2dRasterizer.renderScreen(lowerChar, lowerPalette, patched, { role = "lower-count" })
    if overlay.width ~= base.width or overlay.height ~= base.height then
      if overlay.height ~= base.height or overlay.width < base.width then
        sourceError("count layer does not cover the visible browse background", {
          count = count,
          overlayWidth = overlay.width,
          overlayHeight = overlay.height,
          browseWidth = base.width,
          browseHeight = base.height,
        })
      end
      overlay = RgbaImage.crop(overlay, { x = 0, y = 0, width = base.width, height = base.height }, "mart count layer")
    end
    return RgbaImage.compose({ base, overlay }, "lower browse count " .. count)
  end
  manifest.lower = { backgrounds = { browse = {}, quantity = nil, confirm = nil }, focus = {} }
  for count = 0, 6 do
    manifest.lower.backgrounds.browse[count] = imageAsset(countVariant(count), "browse-" .. count, assets)
  end
  local quantity = decode(
    "decodeScreen",
    readMember(archive, members.lower.quantityScreen, "lower-quantity", MartSources.archive.alias, dependencies),
    "lower-quantity"
  )
  local confirm = decode(
    "decodeScreen",
    readMember(archive, members.lower.confirmScreen, "lower-confirm", MartSources.archive.alias, dependencies),
    "lower-confirm"
  )
  manifest.lower.backgrounds.quantity = imageAsset(
    G2dRasterizer.renderScreen(lowerChar, lowerPalette, quantity, { role = "lower-quantity" }),
    "quantity",
    assets
  )
  manifest.lower.backgrounds.confirm = imageAsset(
    G2dRasterizer.renderScreen(lowerChar, lowerPalette, confirm, { role = "lower-confirm" }),
    "confirm",
    assets
  )

  local function controlVisual(cellId, name, paletteOverride)
    local cell = assert(cellData.cells[cellId + 1], "control cell exists")
    if #cell.objs == 0 then
      local path = MartCache.assetDir() .. "/" .. name .. ".png"
      assets[path] = PngWriter.encode(1, 1, string.char(0, 0, 0, 0))
      return { image = path, width = 1, height = 1, offsetX = 0, offsetY = 0 }
    end
    local source = { role = name }
    local options = {}
    if paletteOverride ~= nil then
      options.paletteOverride = paletteOverride
    end
    local rendered = G2dRasterizer.renderCell(controlChar, controlPalette, cell, source, options)
    local visual = imageAsset(rendered, name, assets)
    visual.offsetX, visual.offsetY = rendered.origin.x, rendered.origin.y
    return visual
  end
  local controls = MartSources.controls
  local palettes = controls.paletteOverrides
  manifest.lower.focus = {
    item = controlVisual(controls.browseFocus.cell, "focus-item", palettes.focus),
    page = controlVisual(controls.pageFocus.cell, "focus-page", palettes.focus),
    cancel = controlVisual(controls.cancelFocus.cell, "focus-cancel", palettes.focus),
  }
  local pairSpecs = {
    pagePrevious = { normal = controls.pagePrevious.cell, selected = controls.pagePrevious.cell, feedback = true },
    pageNext = { normal = controls.pageNext.cell, selected = controls.pageNext.cell, feedback = true },
    cancel = { normal = controls.cancel.cell, selected = controls.cancel.cell, feedback = true },
    increment = { normal = controls.increment.cell, selected = controls.incrementSelected.cell },
    decrement = { normal = controls.decrement.cell, selected = controls.decrementSelected.cell },
    confirm = { normal = controls.confirm.cell, selected = controls.confirm.cell, feedback = true },
    quantityCancel = {
      normal = controls.quantityCancel.cell,
      selected = controls.quantityCancel.cell,
      feedback = true,
    },
  }
  manifest.controls = {}
  for name, cells in pairs(pairSpecs) do
    manifest.controls[name] = {
      normal = controlVisual(cells.normal, name .. "-normal", cells.feedback and palettes.restored or nil),
      selected = controlVisual(cells.selected, name .. "-selected", cells.feedback and palettes.selected or nil),
    }
  end
  local function animationClip(selector, name)
    local sequence = animation.anims[selector + 1]
    if sequence == nil then
      sourceError("animation selector is outside the source bank", { name = name, selector = selector })
    end
    sequence = assert(sequence)
    local frames, totalTicks = {}, 0
    local reverse = sequence.playMode == "reverse" or sequence.playMode == "reverse_loop"
    local looping = sequence.playMode == "forward_loop" or sequence.playMode == "reverse_loop"
    if not reverse and sequence.playMode ~= "forward" and sequence.playMode ~= "forward_loop" then
      sourceError("animation play mode is unsupported", { name = name, playMode = sequence.playMode })
    end
    for playbackIndex = 1, #sequence.frames do
      local frameIndex = reverse and (#sequence.frames - playbackIndex + 1) or playbackIndex
      local frame = assert(sequence.frames[frameIndex], "animation sequence frame exists")
      local source = { role = name, animation = selector, frame = frameIndex - 1 }
      local cell = assert(cellData.cells[frame.cell + 1], "animation references an existing cell")
      local rendered
      if #cell.objs == 0 then
        rendered = {
          width = 1,
          height = 1,
          pixels = string.char(0, 0, 0, 0),
          offset = { x = frame.translateX, y = frame.translateY },
        }
      else
        rendered =
          G2dRasterizer.renderAnimationFrame(controlChar, controlPalette, cellData, sequence, frameIndex, source)
      end
      local visual = imageAsset(rendered, name .. "-" .. (frameIndex - 1), assets)
      visual.offsetX, visual.offsetY = rendered.offset.x, rendered.offset.y
      frames[#frames + 1] = { visual = visual, ticks = frame.duration }
      totalTicks = totalTicks + frame.duration
    end
    return { playback = looping and "loop" or "once", frames = frames, totalTicks = totalTicks }
  end
  manifest.animations = {
    selectionEntry = animationClip(MartSources.controls.animations.selectionEntry, "selection-entry"),
    increment = animationClip(MartSources.controls.animations.increment, "increment"),
    decrement = animationClip(MartSources.controls.animations.decrement, "decrement"),
  }

  local messageArchive, messageErr = romFs:openNarc(MartSources.messages.archive.alias)
  if not messageArchive then
    sourceError("message archive is unavailable", { cause = messageErr and messageErr.code })
  end
  local templates, labels, descriptionBanks = compileMessages(messageArchive, dependencies)
  local geometry = MartSources.geometry
  manifest.upper.description = copyRecord(geometry.upper.description)
  manifest.upper.itemAnchor = copyRecord(geometry.upper.itemAnchor)
  manifest.lower.slots = copyRecord(geometry.browse.slots)
  manifest.lower.pagePrevious = copyRecord(geometry.browse.pagePrevious)
  manifest.lower.pageNext = copyRecord(geometry.browse.pageNext)
  manifest.lower.cancel = copyRecord(geometry.browse.cancel)
  manifest.lower.balance = copyRecord(geometry.browse.balance)
  manifest.lower.cancelLabelBox = copyRecord(geometry.browse.cancelLabelBox)
  manifest.lower.pageBox = copyRecord(geometry.browse.pageBox)
  manifest.lower.messages = {
    short = copyRecord(geometry.browse.messages.short),
    tall = copyRecord(geometry.browse.messages.tall),
    confirm = copyRecord(geometry.quantity.messages.confirm),
  }
  manifest.lower.yesNo = copyRecord(geometry.browse.yesNo)
  manifest.lower.quantity = copyRecord(geometry.quantity)
  manifest.lower.quantity.source = nil
  manifest.lower.quantity.messages = nil
  local textColors = {
    foreground = rgba(controlPalette, 13),
    shadow = rgba(controlPalette, 12),
    background = rgba(controlPalette, 15),
  }
  manifest.text = { palettes = textColors, labels = labels, templates = templates }
  manifest.feedback = {
    dispatchTicks = controls.feedback.dispatchTicks,
    selectedTicks = controls.feedback.selectedTicks,
    restoredTicks = controls.feedback.restoredTicks,
  }

  local catalog = catalogFromSources(descriptionBanks)
  local ok, schemaErr = pcall(MartAssetSchema.assertCatalog, catalog)
  if not ok then
    sourceError("catalog violates its generated contract: " .. Errors.format(schemaErr), {})
  end
  ok, schemaErr = pcall(MartAssetSchema.assertManifest, manifest)
  if not ok then
    sourceError("manifest violates its generated contract: " .. Errors.format(schemaErr), {})
  end
  local provenance = {
    cacheFormat = MartCache.FORMAT,
    catalogSchema = MartCache.CATALOG_SCHEMA,
    schema = MartCache.SCHEMA,
    versionRomSha1 = metadata.sha1,
    source = MartSources.provenance,
    dependencies = dependencies,
  }
  provenance.dependencyHash = Hashing.hashLua(provenance.dependencies)
  return {
    catalog = catalog,
    manifest = manifest,
    assets = assets,
    provenance = provenance,
    marker = MartCache.marker(provenance.versionRomSha1, provenance.dependencyHash),
  }
end

---@param romFs RomFs
---@return table<string, unknown>|nil
---@return Errors.Error|string|nil
function MartAssetCompiler.compile(romFs)
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
    return nil, result
  end
  if type(result) == "table" and result.trace then
    error(result.raw, 0)
  end
  error(result, 0)
end

return MartAssetCompiler
