-- Compiles the HGSS number-entry keypad into source-free generated assets.
-- Source authority: src/field/number_entry.c (NumberEntry_Init,
-- NumberEntry_LoadBgGraphics, NumberEntry_LoadSpriteResources and the sRodata
-- geometry) plus msg_0196's three button labels. The BG layer is the source's
-- own char/screen/palette set rendered once; each sprite frame is the source
-- animation sequence's first frame rendered through the shared G2D rasterizer.

local Errors = require("libs.errors.src.Errors")
local Hashing = require("romdump.src.digest.Hashing")
local Lz10 = require("romdump.src.digest.Lz10")
local PngWriter = require("romdump.src.digest.PngEncoder")
local BankAssetSchema = require("libs.assets.src.BankAssetSchema")
local BankCache = require("libs.assets.src.BankCache")
local BankSources = require("romdump.src.config.BankSources")
local FieldMessageBank = require("romdump.src.digest.ui.FieldMessageBank")
local FieldMessageText = require("libs.assets.src.field.FieldMessageText")
local FieldMessageTokenizer = require("romdump.src.digest.ui.FieldMessageTokenizer")
local charmap = require("romdump.src.catalog.hgss.charmap")
local G2dDecoder = require("romdump.src.digest.ui.G2dDecoder")
local G2dRasterizer = require("romdump.src.digest.ui.G2dRasterizer")

local BankAssetCompiler = {}

BankAssetCompiler.ERROR = {
  SOURCE_INVALID = "BANK_SOURCE_INVALID",
  PROVENANCE_INVALID = "BANK_PROVENANCE_INVALID",
}

local function sourceError(message, context)
  Errors.raise(BankAssetCompiler.ERROR.SOURCE_INVALID, "bank " .. message, context or {})
end

---@param archive table
---@param memberId integer
---@param role string
---@param archiveName string
---@param dependencies table[]
---@return string
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
  local value, err = G2dDecoder[kind](bytes, { label = "bank:" .. role })
  if not value then
    sourceError("resource does not decode: " .. role .. ": " .. tostring(err and err.message), { role = role })
  end
  return value
end

---@param charData table
---@param paletteData table
---@param cellData table
---@param animationData table
---@param sequence integer one-based source animation sequence
---@param role string
---@return { width: integer, height: integer, pixels: string }
local function renderSprite(charData, paletteData, cellData, animationData, sequence, role)
  local animation = animationData.anims[sequence + 1]
  if animation == nil then
    sourceError("sprite animation sequence is absent: " .. role, { role = role, sequence = sequence })
  end
  animation = assert(animation)
  local image, err = G2dRasterizer.renderAnimationFrame(charData, paletteData, cellData, animation, 1, role)
  if not image then
    sourceError("sprite frame does not rasterize: " .. role .. ": " .. tostring(err and err.message), {
      role = role,
      sequence = sequence,
    })
  end
  return image
end

-- One atlas row per sprite frame: the frames keep their own pixel size and the
-- atlas packs them left to right, wrapping at the display width.
---@param frames { role: string, image: { width: integer, height: integer, pixels: string } }[]
---@return { width: integer, height: integer, pixels: string }, table<string, { x: integer, y: integer, width: integer, height: integer }>
local function packAtlas(frames)
  local width = BankSources.display.width
  local positions = {}
  local x, y, rowHeight = 0, 0, 0
  for _, frame in ipairs(frames) do
    local image = frame.image
    if x + image.width > width then
      x = 0
      y = y + rowHeight
      rowHeight = 0
    end
    positions[frame.role] = { x = x, y = y, width = image.width, height = image.height }
    x = x + image.width
    if image.height > rowHeight then
      rowHeight = image.height
    end
  end
  local height = y + rowHeight
  local rowBytes = width * 4
  local rows = {}
  for index = 1, height do
    rows[index] = string.rep("\0", rowBytes)
  end
  for _, frame in ipairs(frames) do
    local position = assert(positions[frame.role], "a packed frame has a position")
    local image = frame.image
    for row = 0, image.height - 1 do
      local target = rows[position.y + row + 1]
      assert(type(target) == "string", "the atlas holds its rows")
      local source = image.pixels:sub(row * image.width * 4 + 1, (row + 1) * image.width * 4)
      rows[position.y + row + 1] = target:sub(1, position.x * 4) .. source .. target:sub((position.x + image.width) * 4 + 1)
    end
  end
  return { width = width, height = height, pixels = table.concat(rows) }, positions
end

-- The source touch regions, transcribed once from sRodata so the runtime reads
-- them from the generated manifest instead of carrying its own copy.
---@return table<string, unknown>
local function keyTable()
  local digits = {}
  local grid = BankSources.digitGrid
  for digit = 0, 9 do
    local column = digit % grid.columns
    local row = (digit - column) / grid.columns
    digits[digit + 1] = {
      digit = digit,
      x = grid.originX + column * grid.cell,
      y = grid.originY + row * grid.cell,
      width = grid.cell,
      height = grid.cell,
    }
  end
  local actions = {}
  for _, key in ipairs(BankSources.actionRow.keys) do
    actions[#actions + 1] = {
      key = key.key,
      x = key.x,
      y = BankSources.actionRow.y,
      width = key.width,
      height = BankSources.actionRow.height,
    }
  end
  local strips = {}
  for count = 1, BankSources.maxDigits do
    local offsets = assert(BankSources.digitCellOffsets[count], "the digit-cell offsets cover every count")
    local row = {}
    for index = 1, count do
      row[index] = {
        x = offsets[index] - BankSources.cursorStrip.width / 2,
        y = BankSources.cursorStrip.top,
        width = BankSources.cursorStrip.width,
        height = BankSources.cursorStrip.height,
      }
    end
    strips[count] = row
  end
  return { digits = digits, actions = actions, dpad = BankSources.dpadBoxes, cursorStrips = strips }
end

-- The three button labels NumberEntry_CreateButtonLabels prints into its lower
-- windows: BACK, CONFIRM and QUIT from bank 196.
---@param romFs table
---@param dependencies table[]
---@return table<string, string>
local function readLabels(romFs, dependencies)
  local messages = BankSources.messages
  local archive, err = romFs:openNarc(messages.archive.alias)
  if not archive then
    sourceError("message archive is unavailable", { cause = err and err.code })
  end
  local info = assert(romFs:resolvedNarc(messages.archive.alias), "bank message NARC resolves")
  dependencies[#dependencies + 1] = {
    name = messages.archive.alias .. ":narc",
    sha1 = Hashing.sha1hex(assert(romFs:read(info.fileId), "bank message NARC bytes are readable")),
  }
  local bytes = readMember(archive, messages.bank, "button-labels", messages.archive.alias, dependencies)
  local bank = FieldMessageBank.decode(bytes, { label = "bank button labels" })
  if not bank then
    sourceError("button-label bank does not decode", { bank = messages.bank })
  end
  bank = assert(bank)
  local labels = {}
  for role, messageIndex in pairs(messages.roles) do
    local row = bank.messages[messageIndex + 1]
    if row == nil then
      sourceError("button label is absent", { bank = messages.bank, messageId = messageIndex })
    end
    row = assert(row)
    local tokens, tokenErr = FieldMessageTokenizer.tokenize(row.raw, charmap, {})
    if not tokens then
      sourceError("button label cannot be tokenized", { messageId = messageIndex, cause = tokenErr and tokenErr.code })
    end
    local text = FieldMessageText.tokensToText(assert(tokens))
    if type(text) ~= "string" or text == "" then
      sourceError("button label has no text", { bank = messages.bank, messageId = messageIndex })
    end
    labels[role] = text
  end
  return labels
end

-- The manifest of one compiled bundle, validated before publication.
---@param bundle table<string, unknown>
local function validateManifest(bundle)
  local ok, err = pcall(BankAssetSchema.validate, bundle.manifest)
  if not ok then
    local detail = type(err) == "table" and (tostring(err.message) .. " " .. tostring(err.code)) or tostring(err)
    Errors.raise(BankAssetCompiler.ERROR.PROVENANCE_INVALID, "compiled bank manifest is invalid: " .. detail, {})
  end
  local references = BankCache.referencedPaths(bundle.manifest)
  if #references == 0 then
    Errors.raise(BankAssetCompiler.ERROR.PROVENANCE_INVALID, "compiled bank manifest references no image", {})
  end
  for _, path in ipairs(references) do
    if type(bundle.assets[path]) ~= "string" then
      Errors.raise(BankAssetCompiler.ERROR.PROVENANCE_INVALID, "compiled bank bundle is missing " .. path, {
        path = path,
      })
    end
  end
end

-- One source archive read yields the complete keypad: the composited BG layer,
-- the sprite atlas with its frames, the source key geometry and the labels.
---@param romFs table
---@return table<string, unknown> bundle
function BankAssetCompiler.compile(romFs)
  assert(type(romFs) == "table" and type(romFs.openNarc) == "function", "bank compilation needs a source reader")
  local dependencies = {}
  local archiveName = BankSources.archive.alias
  local archive, archiveErr = romFs:openNarc(archiveName)
  if not archive then
    sourceError("resource archive is unavailable", { cause = archiveErr and archiveErr.code })
  end
  local info = assert(romFs:resolvedNarc(archiveName), "bank NARC alias resolves")
  dependencies[#dependencies + 1] = {
    name = archiveName .. ":narc",
    sha1 = Hashing.sha1hex(assert(romFs:read(info.fileId), "bank NARC bytes are readable")),
  }

  local resources = BankSources.archive.resources
  local bgChar = decode("decodeChar", readMember(archive, resources.bg.char, "bg-char", archiveName, dependencies), "bg-char")
  local bgPalette =
    decode("decodePalette", readMember(archive, resources.bg.palette, "bg-palette", archiveName, dependencies), "bg-palette")
  local bgScreen = decode("decodeScreen", readMember(archive, resources.bg.screen, "bg-screen", archiveName, dependencies), "bg-screen")
  local layer, layerErr = G2dRasterizer.renderScreen(bgChar, bgPalette, bgScreen, { role = "bank-keypad" })
  if not layer then
    sourceError("keypad layer does not rasterize: " .. tostring(layerErr and layerErr.message), {})
  end

  local function loadSpriteSet(name)
    local members = assert(resources[name], "the bank sprite set is named")
    return {
      char = decode("decodeChar", readMember(archive, members.char, name .. "-char", archiveName, dependencies), name .. "-char"),
      palette = decode(
        "decodePalette",
        readMember(archive, members.palette, name .. "-palette", archiveName, dependencies),
        name .. "-palette"
      ),
      cell = decode("decodeCell", readMember(archive, members.cell, name .. "-cell", archiveName, dependencies), name .. "-cell"),
      animation = decode(
        "decodeAnimation",
        readMember(archive, members.animation, name .. "-animation", archiveName, dependencies),
        name .. "-animation"
      ),
    }
  end
  local pad = loadSpriteSet("pad")
  local digit = loadSpriteSet("digit")

  local frames = {}
  local function addSprite(role, set, sequence)
    frames[#frames + 1] = {
      role = role,
      image = renderSprite(set.char, set.palette, set.cell, set.animation, sequence, role),
    }
  end
  local specs = BankSources.sprites
  addSprite("cursor", pad, specs.cursor.animation)
  addSprite("cursorButton", pad, specs.cursorButton.animation)
  addSprite("underline", pad, specs.underline.animation)
  addSprite("back", pad, specs.back.animation)
  addSprite("confirm", pad, specs.confirm.animation)
  addSprite("quit", pad, specs.quit.animation)
  for digitValue = 0, 9 do
    addSprite("digit" .. tostring(digitValue), digit, specs.digitFirstAnimation + digitValue)
  end
  local atlas, positions = packAtlas(frames)

  local assets = {}
  local atlasPath = BankCache.assetDir() .. "/sprites.png"
  assets[atlasPath] = PngWriter.encode(atlas.width, atlas.height, atlas.pixels)
  local layerPath = BankCache.assetDir() .. "/keypad.png"
  assets[layerPath] = PngWriter.encode(layer.width, layer.height, layer.pixels)

  local function frame(role)
    local position = assert(positions[role], "the compiled frame exists: " .. role)
    return { image = atlasPath, x = position.x, y = position.y, width = position.width, height = position.height }
  end
  local digits = {}
  for digitValue = 0, 9 do
    local entry = frame("digit" .. tostring(digitValue))
    entry.digit = digitValue
    digits[digitValue + 1] = entry
  end

  local manifest = {
    schema = BankAssetSchema.SCHEMA,
    display = { width = BankSources.display.width, height = BankSources.display.height },
    layer = { image = layerPath, width = layer.width, height = layer.height },
    sprites = {
      atlas = atlasPath,
      atlasWidth = atlas.width,
      atlasHeight = atlas.height,
      cursor = frame("cursor"),
      cursorButton = frame("cursorButton"),
      underline = frame("underline"),
      back = frame("back"),
      confirm = frame("confirm"),
      quit = frame("quit"),
      digits = digits,
    },
    keys = keyTable(),
    labels = readLabels(romFs, dependencies),
    timing = {
      blinkFirstTicks = BankSources.blink.firstTicks,
      blinkSecondTicks = BankSources.blink.secondTicks,
      maxDigits = BankSources.maxDigits,
    },
  }

  local dependencyHash = Hashing.hashLua(dependencies)
  local metadata = romFs:metadata()
  if type(metadata) ~= "table" or type(metadata.sha1) ~= "string" then
    Errors.raise(BankAssetCompiler.ERROR.PROVENANCE_INVALID, "the source reader carries no ROM identity", {})
  end

  local bundle = {
    manifest = manifest,
    assets = assets,
    provenance = {
      cacheFormat = BankCache.FORMAT,
      schema = BankCache.SCHEMA,
      versionRomSha1 = metadata.sha1,
      source = BankSources.provenance,
      dependencies = dependencies,
      dependencyHash = dependencyHash,
    },
  }
  validateManifest(bundle)
  bundle.marker = BankCache.marker(bundle.provenance.versionRomSha1, dependencyHash)
  return bundle
end

return BankAssetCompiler
