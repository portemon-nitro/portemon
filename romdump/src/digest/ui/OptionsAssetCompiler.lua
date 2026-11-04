-- Compiles the native options application control states into the
-- existing generated field-UI family: the small/wide selected pills, the
-- left/right frame arrows, the Confirm/Quit action chrome, the unselected
-- baseline face patches, and the semantic labels with the frame preview
-- text — as one packed PNG atlas plus the strict semantic section the
-- runtime consumes. Source member selection lives in
-- romdump/src/config/OptionsSources.lua; resdat lists and headers are
-- cross-checked against those selectors before any pixel is rasterized.
-- The runtime consumes only the manifest and the generated file, never
-- this module. Pure module: no love dependency.

local Errors = require("libs.errors.src.Errors")
local Hashing = require("romdump.src.digest.Hashing")
local BinaryReader = require("libs.codec.src.BinaryReader")
local Lz10 = require("romdump.src.digest.Lz10")
local G2dDecoder = require("romdump.src.digest.ui.G2dDecoder")
local G2dRasterizer = require("romdump.src.digest.ui.G2dRasterizer")
local UiMessageBank = require("romdump.src.digest.ui.UiMessageBank")
local FieldUiAssetCache = require("libs.assets.src.field.FieldUiAssetCache")
local FieldMessageText = require("libs.assets.src.field.FieldMessageText")
local DisplayTiming = require("libs.nds.src.gx.DisplayTiming")
local PngWriter = require("romdump.src.digest.PngEncoder")
local OptionsSources = require("romdump.src.config.OptionsSources")
local charmap = require("romdump.src.catalog.hgss.charmap")

local OptionsAssetCompiler = {}

-- Named ownership of the compiler protocol error code; tests assert the
-- constant, never the raw string.
OptionsAssetCompiler.ERROR = {
  SOURCE_INVALID = "OPTIONS_SOURCE_INVALID",
}

---@alias OptionsAssetCompiler.CharData { depth: integer, tiles: string }
---@alias OptionsAssetCompiler.PaletteData { colors: { r: integer, g: integer, b: integer }[] }
---@alias OptionsAssetCompiler.ScreenData { width: integer, height: integer, entries: table[] }
---@alias OptionsAssetCompiler.CellData { cells: table[] }
---@alias OptionsAssetCompiler.AnimationData { anims: table[] }
---@alias OptionsAssetCompiler.G2dData OptionsAssetCompiler.CharData|OptionsAssetCompiler.PaletteData|OptionsAssetCompiler.ScreenData|OptionsAssetCompiler.CellData|OptionsAssetCompiler.AnimationData
---@alias OptionsAssetCompiler.ResourceSets { char: table<integer, integer>, palette: table<integer, integer>, cell: table<integer, integer>, animation: table<integer, integer> }
---@alias OptionsAssetCompiler.SpriteSet { charData: OptionsAssetCompiler.CharData, palette: OptionsAssetCompiler.PaletteData, cell: OptionsAssetCompiler.CellData }
---@alias OptionsAssetCompiler.AnimationFrame { cell: integer, duration: integer, element: string, translateX: integer, translateY: integer, scaleX: number, scaleY: number, rotation: number, userAttr?: integer }
---@alias OptionsAssetCompiler.Animation { frames: OptionsAssetCompiler.AnimationFrame[], playMode: string, loopStartFrameIdx: integer }
---@alias OptionsAssetCompiler.SequenceFrame { image: string, atlas: { x: number, y: number, width: number, height: number }, offset: { x: number, y: number }, ticks: integer }
---@alias OptionsAssetCompiler.CompiledSequence { frames: OptionsAssetCompiler.SequenceFrame[], loop: boolean, bounds: { x: number, y: number, width: number, height: number } }

local LIST_SENTINEL = 0xFFFFFFFE
local HEADER_SENTINEL = 0xFFFFFFFE
local HEADER_BLANK = 0xFFFFFFFF

---@param message string
---@param context Errors.Context?
---@noreturn
local function sourceError(message, context)
  Errors.raise(OptionsAssetCompiler.ERROR.SOURCE_INVALID, message, context)
end

---@param romFs RomFs
---@param alias string
---@return Narc, string
local function loadArchive(romFs, alias)
  local info = romFs:resolvedNarc(alias)
  if info == nil then
    sourceError("the options source archive does not resolve", { alias = alias })
  end
  assert(info ~= nil, "an unresolved options archive fails above")
  local archive = romFs:openNarc(alias)
  if archive == nil then
    sourceError("the options source archive does not open", { alias = alias })
  end
  assert(archive ~= nil, "an unopenable options archive fails above")
  local bytes = romFs:read(info.fileId)
  if bytes == nil then
    sourceError("the options source archive bytes are unreadable", { alias = alias })
  end
  assert(bytes ~= nil, "unreadable options archive bytes fail above")
  return archive, bytes
end

---@param archive Narc
---@param memberId integer
---@param label string
---@return string
local function decodeMember(archive, memberId, label)
  local bytes = archive:readMember(memberId)
  if bytes == nil then
    sourceError("the options source member is missing", { member = memberId, label = label })
  end
  assert(bytes ~= nil, "a missing options member fails above")
  if string.byte(bytes, 1) == 0x10 then
    local plain, lzErr = Lz10.decode(bytes)
    if not plain then
      sourceError(
        "the options source member is not valid LZ10",
        { member = memberId, label = label, cause = lzErr and lzErr.message }
      )
    end
    assert(plain ~= nil, "an undecodable options member fails above")
    bytes = plain
  end
  return bytes
end

---@param bytes string
---@param kind string
---@param memberId integer
---@return OptionsAssetCompiler.G2dData
local function decodeG2d(bytes, kind, memberId)
  local decoded, err = G2dDecoder[kind](bytes, { label = "options:" .. memberId })
  if decoded == nil then
    sourceError("the options source member does not decode", {
      member = memberId,
      kind = kind,
      cause = err and err.message,
    })
  end
  assert(decoded ~= nil, "an undecodable options member fails above")
  return decoded
end

-- Parses one six-word resdat resource list: the leading resource-type
-- word, one row per curated member, and the six-word sentinel. Returns
-- resource id to archive member.
---@param bytes string
---@param memberId integer
---@param expectedCount integer
---@param label string
---@return table<integer, integer>
local function parseResourceList(bytes, memberId, expectedCount, label)
  local reader = BinaryReader.new(bytes, label)
  if #bytes < 4 + expectedCount * 24 + 24 then
    sourceError("the options resource list is shorter than its curated members", {
      member = memberId,
      label = label,
      size = #bytes,
    })
  end
  if (#bytes - 4) % 24 ~= 0 then
    sourceError("the options resource list does not fill whole six-word rows", {
      member = memberId,
      label = label,
      size = #bytes,
    })
  end
  local rows = {}
  local rowCount = (#bytes - 4) / 24
  for row = 0, rowCount - 2 do
    local base = 4 + row * 24
    local narcId = reader:u32le(base)
    local member = reader:u32le(base + 4)
    local resourceId = reader:u32le(base + 12)
    if narcId ~= OptionsSources.archive.narcId then
      sourceError("the options resource list names another archive", {
        member = memberId,
        label = label,
        row = row,
        narcId = narcId,
      })
    end
    rows[resourceId] = member
  end
  local sentinelBase = #bytes - 24
  for word = 0, 5 do
    if reader:u32le(sentinelBase + word * 4) ~= LIST_SENTINEL then
      sourceError("the options resource list misses its sentinel termination", {
        member = memberId,
        label = label,
        word = word,
      })
    end
  end
  local count = 0
  for _ in pairs(rows) do
    count = count + 1
  end
  if count ~= expectedCount then
    sourceError("the options resource list carries an unexpected record census", {
      member = memberId,
      label = label,
      records = count,
      expected = expectedCount,
    })
  end
  return rows
end

-- Parses the eight-word options header set: one row per resource set plus
-- the eight-word sentinel. Returns the char/palette/cell/animation
-- selection per set in order.
---@param bytes string
---@param memberId integer
---@param expectedSets integer
---@return table[]
local function parseHeaderSet(bytes, memberId, expectedSets)
  if #bytes % 32 ~= 0 then
    sourceError("the options header set does not fill whole eight-word rows", {
      member = memberId,
      size = #bytes,
    })
  end
  local reader = BinaryReader.new(bytes, "options-headers")
  local rowCount = #bytes / 32
  if rowCount < expectedSets + 1 then
    sourceError("the options header set is shorter than its curated sets", {
      member = memberId,
      rows = rowCount,
      expected = expectedSets,
    })
  end
  local sets = {}
  for row = 0, expectedSets - 1 do
    local base = row * 32
    sets[row + 1] = {
      char = reader:u32le(base),
      palette = reader:u32le(base + 4),
      cell = reader:u32le(base + 8),
      animation = reader:u32le(base + 12),
    }
    for word = 4, 5 do
      if reader:u32le(base + word * 4) ~= HEADER_BLANK then
        sourceError("the options header set carries an unexpected composite selection", {
          member = memberId,
          set = row,
          word = word,
        })
      end
    end
  end
  local sentinelBase = expectedSets * 32
  if rowCount > expectedSets then
    for word = 0, 7 do
      if reader:u32le(sentinelBase + word * 4) ~= HEADER_SENTINEL then
        sourceError("the options header set misses its sentinel termination", { member = memberId, word = word })
      end
    end
    if rowCount ~= expectedSets + 1 then
      sourceError("the options header set carries an unexpected record census", {
        member = memberId,
        rows = rowCount,
        expected = expectedSets + 1,
      })
    end
  end
  return sets
end

-- Cross-checks the curated selectors through the resdat lists and headers
-- and resolves every resource id the semantic sets name to its archive
-- member. Decoding follows the resdat resolution; the curated member lists
-- are the checked expectation, so selector drift fails loudly.
---@param romFs RomFs
---@param dependencies table[]
---@return OptionsAssetCompiler.ResourceSets resolved resource-id to archive-member maps per kind
local function resolveResourceSets(romFs, dependencies)
  local archive = loadArchive(romFs, OptionsSources.resdat.symbol)
  local lists = OptionsSources.resdat.lists
  local function list(memberId, expectedCount, label)
    local bytes = decodeMember(archive, memberId, label)
    dependencies[#dependencies + 1] = {
      name = OptionsSources.resdat.symbol .. ":member:" .. memberId,
      sha1 = Hashing.sha1hex(bytes),
    }
    return parseResourceList(bytes, memberId, expectedCount, label)
  end
  local animations = list(lists.animation, #OptionsSources.members.animations, "options-animations")
  local cells = list(lists.cell, #OptionsSources.members.cells, "options-cells")
  local chars = list(lists.char, #OptionsSources.members.chars, "options-chars")
  local palettes = list(lists.palette, #OptionsSources.members.palettes, "options-palettes")
  local headerBytes = decodeMember(archive, OptionsSources.resdat.headers, "options-headers")
  dependencies[#dependencies + 1] = {
    name = OptionsSources.resdat.symbol .. ":member:" .. OptionsSources.resdat.headers,
    sha1 = Hashing.sha1hex(headerBytes),
  }
  local headerSets = parseHeaderSet(headerBytes, OptionsSources.resdat.headers, 4)
  local setNames = { "pills", "leftArrow", "rightArrow", "actions" }
  for index, name in ipairs(setNames) do
    local curated = OptionsSources.sets[name]
    local decodedSet = headerSets[index]
    for _, key in ipairs({ "char", "palette", "cell", "animation" }) do
      if decodedSet[key] ~= curated[key] then
        sourceError("the options header set disagrees with the curated selectors", {
          set = name,
          role = key,
          decoded = decodedSet[key],
          curated = curated[key],
        })
      end
    end
  end
  local resolved = { char = {}, palette = {}, cell = {}, animation = {} }
  local curatedMembers = {
    char = OptionsSources.members.chars,
    palette = OptionsSources.members.palettes,
    cell = OptionsSources.members.cells,
    animation = OptionsSources.members.animations,
  }
  local idMaps = { char = chars, palette = palettes, cell = cells, animation = animations }
  for kind, members in pairs(curatedMembers) do
    local idMap = idMaps[kind]
    for resourceId = 0, #members - 1 do
      local member = idMap[resourceId]
      if member == nil then
        sourceError("the options resource list misses its curated resource id", {
          kind = kind,
          resourceId = resourceId,
        })
      end
      if member ~= members[resourceId + 1] then
        sourceError("the options resource list disagrees with the curated selectors", {
          kind = kind,
          resourceId = resourceId,
          decoded = member,
          curated = members[resourceId + 1],
        })
      end
      resolved[kind][resourceId] = member
    end
  end
  local info = romFs:resolvedNarc(OptionsSources.resdat.symbol)
  dependencies[#dependencies + 1] = {
    name = OptionsSources.resdat.symbol .. ":narc",
    sha1 = Hashing.sha1hex(assert(romFs:read(assert(info).fileId))),
  }
  return resolved
end

---@param archive Narc
---@param memberId integer
---@param kind string
---@return OptionsAssetCompiler.G2dData
local function decodeResource(archive, memberId, kind)
  local decoded = decodeG2d(decodeMember(archive, memberId, "options:" .. memberId), kind, memberId)
  if kind == "decodePalette" then
    if #decoded.colors < 16 then
      sourceError("the options palette member carries no usable bank", { member = memberId, colors = #decoded.colors })
    end
  end
  return decoded
end

---@param bank UiMessageBank.Bank decoded message bank
---@param slot integer zero-based message id
---@param role string
---@return { text: string, tokens: UiMessageBank.Token[] }
local function lowerLabel(bank, slot, role)
  local tokens, failure = UiMessageBank.tokens(bank, OptionsSources.messageBank, slot, charmap)
  if tokens == nil then
    assert(failure ~= nil, "a missing label stream carries its failure")
    sourceError("the options label does not lower", {
      slot = slot,
      role = role,
      stage = failure.stage,
      cause = failure.message,
    })
  end
  assert(tokens ~= nil, "a failed label lowering fails above")
  return { text = FieldMessageText.tokensToText(tokens), tokens = tokens }
end

-- Compiles one sprite state sequence: every frame of the selected
-- animation rasterized through the set's char/palette/cell selection with
-- its signed source offset and source tick duration. Looping follows the
-- decoded play mode; one-shot sequences terminate explicitly.
---@param set OptionsAssetCompiler.SpriteSet resolved { charData, palette, cell }
---@param animation OptionsAssetCompiler.Animation decoded animation sequence
---@param image string packed atlas path
---@param frames table[] packed atlas frames in draw order
---@param role string
---@return OptionsAssetCompiler.CompiledSequence sequence { frames, loop, bounds }
local function compileSequence(set, animation, image, frames, role)
  local loop
  if animation.playMode == "forward_loop" or animation.playMode == "reverse_loop" then
    loop = true
  elseif animation.playMode == "forward" or animation.playMode == "reverse" then
    loop = false
  else
    sourceError("the options animation carries an unsupported play mode", {
      role = role,
      playMode = animation.playMode,
    })
    loop = false
  end
  local sequence = { frames = {}, loop = loop, bounds = nil }
  local minX, minY, maxX, maxY = nil, nil, nil, nil
  for frameIndex = 1, #animation.frames do
    local duration = animation.frames[frameIndex].duration
    if type(duration) ~= "number" or duration % 1 ~= 0 or duration < 0 then
      sourceError("the options animation frame carries an invalid duration", {
        role = role,
        frame = frameIndex - 1,
        duration = duration,
      })
    end
    local raster = G2dRasterizer.renderAnimationFrame(
      set.charData,
      { colors = set.palette.colors },
      set.cell,
      animation,
      frameIndex,
      { asset = "options", role = role }
    )
    if
      type(raster.offset.x) ~= "number"
      or raster.offset.x % 1 ~= 0
      or type(raster.offset.y) ~= "number"
      or raster.offset.y % 1 ~= 0
    then
      sourceError("the options sprite frame carries a non-integral source offset", {
        role = role,
        frame = frameIndex - 1,
      })
    end
    local frame = {
      width = raster.width,
      height = raster.height,
      pixels = raster.pixels,
      offset = { x = raster.offset.x, y = raster.offset.y },
      ticks = duration,
    }
    frames[#frames + 1] = frame
    -- The atlas rect is assigned in the final packing pass; the sequence
    -- keeps the same table so the packed position lands here directly.
    local rect = { x = 0, y = 0, width = frame.width, height = frame.height }
    frame.rect = rect
    local x1, y1 = frame.offset.x, frame.offset.y
    local x2, y2 = x1 + frame.width, y1 + frame.height
    if minX == nil or x1 < minX then
      minX = x1
    end
    if minY == nil or y1 < minY then
      minY = y1
    end
    if maxX == nil or x2 > maxX then
      maxX = x2
    end
    if maxY == nil or y2 > maxY then
      maxY = y2
    end
    sequence.frames[#sequence.frames + 1] = {
      image = image,
      atlas = rect,
      offset = frame.offset,
      ticks = duration,
    }
  end
  local total = 0
  for _, frame in ipairs(sequence.frames) do
    total = total + frame.ticks
  end
  if total == 0 then
    sourceError("the options animation sequence never advances", { role = role })
  end
  assert(minX ~= nil and minY ~= nil and maxX ~= nil and maxY ~= nil, "a sequenced options frame bounds above")
  sequence.bounds = { x = minX, y = minY, width = maxX - minX, height = maxY - minY }
  return sequence
end

-- Renders one opaque 256x192 option backdrop from its audited base triple:
-- the full 256x256 source map with palette-zero normalized to the same
-- palette's opaque backdrop color, cropped to the top visible viewport.
-- Private to this module; the compiled bundle carries the staged bytes.
-- The decoded screen also returns for the row-plate builder so the MAIN
-- base decodes once and both outputs share the same source pixels.
---@param archive Narc
---@param dependencies table[]
---@param chars table<integer, OptionsAssetCompiler.CharData>
---@param palettes table<integer, OptionsAssetCompiler.PaletteData>
---@param base { paletteMember: integer, charMember: integer, screenMember: integer }
---@param image string staged output path
---@param role string
---@return string png
---@return { image: string, width: integer, height: integer }
---@return OptionsAssetCompiler.ScreenData decoded source screen
local function renderBackdrop(archive, dependencies, chars, palettes, base, image, role)
  local screenBytes = decodeMember(archive, base.screenMember, "options-backdrop:" .. base.screenMember)
  dependencies[#dependencies + 1] = {
    name = OptionsSources.archive.symbol .. ":member:" .. base.screenMember,
    sha1 = Hashing.sha1hex(screenBytes),
  }
  local screen = decodeG2d(screenBytes, "decodeScreen", base.screenMember) --[[@as OptionsAssetCompiler.ScreenData]]
  if screen.width ~= 256 or screen.height ~= 256 then
    sourceError("the options backdrop is not the audited 256x256 surface", {
      role = role,
      member = base.screenMember,
      width = screen.width,
      height = screen.height,
    })
  end
  local charData = chars[base.charMember]
  if charData == nil then
    sourceError("the options backdrop char is not decoded", { role = role, member = base.charMember })
  end
  local palette = palettes[base.paletteMember]
  if palette == nil then
    sourceError("the options backdrop palette is not decoded", { role = role, member = base.paletteMember })
  end
  assert(charData ~= nil and palette ~= nil, "a missing options backdrop bank fails above")
  local render = G2dRasterizer.renderScreen(
    charData,
    { colors = palette.colors },
    screen,
    { asset = "options backdrop", member = base.screenMember },
    { backdrop = true }
  )
  local rows = {}
  for y = 0, 191 do
    rows[#rows + 1] = render.pixels:sub(y * 256 * 4 + 1, (y + 1) * 256 * 4)
  end
  return PngWriter.encode(256, 192, table.concat(rows)), { image = image, width = 256, height = 192 }, screen
end

-- Copies one opaque 256x24 shell band from the decoded 256x256 MAIN
-- base: the listed source tile rows copied with their exact source
-- entries (no scrubbing), rasterized through the shared screen path with
-- palette-zero normalized to the opaque backdrop color. Private to this
-- module; the compiled bundle carries the staged bytes.
---@param charData OptionsAssetCompiler.CharData decoded MAIN base tiles
---@param palette OptionsAssetCompiler.PaletteData decoded MAIN base palette
---@param screen OptionsAssetCompiler.ScreenData decoded 256x256 MAIN base
---@param firstTileRow integer zero-based first source tile row copied
---@param tileRowCount integer count of source tile rows copied
---@param image string staged output path
---@param role string band role for failure detail
---@return string png
---@return { image: string, width: integer, height: integer }
local function renderBandFromScreen(charData, palette, screen, firstTileRow, tileRowCount, image, role)
  if tileRowCount <= 0 or firstTileRow < 0 or (firstTileRow + tileRowCount) * 8 > screen.height then
    sourceError("the options shell band leaves its audited source screen", {
      role = role,
      firstTileRow = firstTileRow,
      tileRowCount = tileRowCount,
      height = screen.height,
    })
  end
  local columns = screen.width / 8
  if columns ~= 32 or #screen.entries ~= (screen.width / 8) * (screen.height / 8) then
    sourceError("the options shell band leaves its audited source screen", {
      role = role,
      width = screen.width,
      height = screen.height,
      entries = #screen.entries,
    })
  end
  assert(columns == 32, "a bounded options shell band fails above")
  local entries = {}
  for tileRow = firstTileRow, firstTileRow + tileRowCount - 1 do
    for col = 0, columns - 1 do
      entries[#entries + 1] = screen.entries[tileRow * columns + col + 1]
    end
  end
  local height = tileRowCount * 8
  local render = G2dRasterizer.renderScreen(
    charData,
    { colors = palette.colors },
    { width = 256, height = height, entries = entries },
    { asset = "options " .. role, member = OptionsSources.members.faceScreen },
    { backdrop = true }
  )
  for offset = 4, #render.pixels, 4 do
    if string.byte(render.pixels, offset) ~= 255 then
      sourceError("the options shell band is not fully opaque", { role = role, pixel = math.floor(offset / 4) })
    end
  end
  return PngWriter.encode(256, height, render.pixels), { image = image, width = 256, height = height }
end

-- Renders one opaque 256x24 shell band from its audited base triple by
-- decoding the full source map once and slicing the requested tile rows
-- with exact source entries. Returns the decoded source screen alongside
-- the staged band so the header decode also serves the footer band and
-- the row plates without redecoding. Private to this module; the compiled
-- bundle carries the staged bytes.
---@param archive Narc
---@param dependencies table[]
---@param chars table<integer, OptionsAssetCompiler.CharData>
---@param palettes table<integer, OptionsAssetCompiler.PaletteData>
---@param base { paletteMember: integer, charMember: integer, screenMember: integer }
---@param firstTileRow integer zero-based first source tile row copied
---@param tileRowCount integer count of source tile rows copied
---@param image string staged output path
---@param role string
---@return string png
---@return { image: string, width: integer, height: integer }
---@return OptionsAssetCompiler.ScreenData decoded source screen
local function renderShellBand(archive, dependencies, chars, palettes, base, firstTileRow, tileRowCount, image, role)
  local screenBytes = decodeMember(archive, base.screenMember, "options-shell-band:" .. base.screenMember)
  dependencies[#dependencies + 1] = {
    name = OptionsSources.archive.symbol .. ":member:" .. base.screenMember,
    sha1 = Hashing.sha1hex(screenBytes),
  }
  local screen = decodeG2d(screenBytes, "decodeScreen", base.screenMember) --[[@as OptionsAssetCompiler.ScreenData]]
  if screen.width ~= 256 or screen.height ~= 256 then
    sourceError("the options shell band is not the audited 256x256 surface", {
      role = role,
      member = base.screenMember,
      width = screen.width,
      height = screen.height,
    })
  end
  local charData = chars[base.charMember]
  if charData == nil then
    sourceError("the options shell band char is not decoded", { role = role, member = base.charMember })
  end
  local palette = palettes[base.paletteMember]
  if palette == nil then
    sourceError("the options shell band palette is not decoded", { role = role, member = base.paletteMember })
  end
  assert(charData ~= nil and palette ~= nil, "a missing options shell band bank fails above")
  local png, asset = renderBandFromScreen(charData, palette, screen, firstTileRow, tileRowCount, image, role)
  return png, asset, screen
end

-- Copies one 8px source tile row into a full-width plate row, flattening
-- the whole control span to the backing entry observed at the interior
-- filler column of the same tile row. Native dividers, inter-pill
-- separators, and control-side backing are intentionally not preserved:
-- custom option layouts move controls freely, so a baked divider at a
-- fixed x would ghost under relocated chrome. The retained label and
-- edge spans keep their exact source entries. Private to this module;
-- the compiled bundle carries the staged bytes.
---@param screen OptionsAssetCompiler.ScreenData decoded 256x256 MAIN base
---@param tileRow integer zero-based source tile row copied for one plate row
---@param expectedFiller integer audited backing tile for this tile row
---@param role string plate role for failure detail
---@return table[] plate row entries across the full 256px width
local function scrubbedPlateRow(screen, tileRow, expectedFiller, role)
  local columns = screen.width / 8
  if columns ~= 32 or tileRow < 0 or tileRow * columns + columns > #screen.entries then
    sourceError("the options row band leaves its audited source screen", {
      role = role,
      tileRow = tileRow,
      width = screen.width,
      entries = #screen.entries,
    })
  end
  assert(columns == 32, "a bounded options tile row fails above")
  local plates = OptionsSources.rowPlates
  local filler = screen.entries[tileRow * columns + plates.fillerColumn + 1]
  if filler.tile ~= expectedFiller or filler.palette ~= 0 then
    sourceError("the options row band filler disagrees with the audited backing tile", {
      role = role,
      tileRow = tileRow,
      tile = filler.tile,
      palette = filler.palette,
      expected = expectedFiller,
    })
  end
  for col = 1, 11 do
    local entry = screen.entries[tileRow * columns + col + 1]
    if
      entry.tile ~= filler.tile
      or entry.palette ~= filler.palette
      or entry.flipH ~= filler.flipH
      or entry.flipV ~= filler.flipV
    then
      sourceError("the options row band interior is not uniform backing material", {
        role = role,
        tileRow = tileRow,
        column = col,
      })
    end
  end
  local row = {}
  for col = 0, columns - 1 do
    if col >= plates.faceFirstColumn and col <= plates.faceLastColumn then
      row[#row + 1] = { tile = filler.tile, palette = filler.palette, flipH = filler.flipH, flipV = filler.flipV }
    else
      local kept = screen.entries[tileRow * columns + col + 1]
      row[#row + 1] = { tile = kept.tile, palette = kept.palette, flipH = kept.flipH, flipV = kept.flipV }
    end
  end
  return row
end

-- Flattens the rendered plate interior to the source filler color so
-- relocated controls never inherit baked native trim: every pixel inside
-- the outer window frame (x4..251, y1..height-2) takes the mid-band filler
-- backing sampled from the plate's own render, discarding the divider
-- remnant at the label edge and the lighter edge-cap backing beside the
-- right border. The outer frame itself (top/bottom rows, left/right
-- border columns) keeps exact source pixels, so rows keep their
-- separators and window borders. No invented color ever ships: the flat
-- comes from the audited filler tile through the shared rasterizer.
---@param pixels string rendered 256-wide RGBA bytes
---@param height integer plate height in pixels
---@return string flattened 256-wide RGBA bytes
local function flattenInterior(pixels, height)
  assert(#pixels == 256 * height * 4, "a bounded options plate flattens above")
  local midY = math.floor(height / 2)
  local sample = (midY * 256 + 8) * 4
  local flat = string
    .char(string.byte(pixels, sample + 1), string.byte(pixels, sample + 2), string.byte(pixels, sample + 3), 255)
    :rep(248)
  local parts = {}
  for y = 0, height - 1 do
    local rowStart = y * 256 * 4
    if y == 0 or y == height - 1 then
      parts[#parts + 1] = pixels:sub(rowStart + 1, rowStart + 256 * 4)
    else
      parts[#parts + 1] = pixels:sub(rowStart + 1, rowStart + 4 * 4)
      parts[#parts + 1] = flat
      parts[#parts + 1] = pixels:sub(rowStart + 252 * 4 + 1, rowStart + 256 * 4)
    end
  end
  return table.concat(parts)
end

-- Clears the baseline backing blue out of an unselected face patch so the
-- printed pill blends onto any backing: the crop footprint spans the pill
-- plus the inter-pill spacing, whose backing ink would otherwise frame
-- every pill in the retail control-side color and ghost under relocated
-- controls. The trim color is sampled from the crop's own top-right
-- backing margin; a crop carrying no trimmable backing fails loudly
-- instead of shipping guessed art. RGB is preserved and only alpha
-- clears, so the packed atlas keeps its shape and no manifest contract
-- moves. Private to this module; the packed atlas carries the staged pixels.
---@param frame { width: integer, height: integer, pixels: string } packed face raster
---@param role string face role for failure detail
local function stripFaceTrim(frame, role)
  assert(frame.width > 0 and frame.height > 0, "a bounded options face strips above")
  assert(#frame.pixels == frame.width * frame.height * 4, "an options face carries its pixel census")
  local sample = (4 * frame.width + (frame.width - 1)) * 4
  local r = string.byte(frame.pixels, sample + 1)
  local g = string.byte(frame.pixels, sample + 2)
  local b = string.byte(frame.pixels, sample + 3)
  if string.byte(frame.pixels, sample + 4) ~= 255 then
    sourceError("the options face trim leaves its audited backing margin", { role = role })
  end
  local parts = {}
  local masked = 0
  for i = 1, #frame.pixels, 4 do
    if
      string.byte(frame.pixels, i) == r
      and string.byte(frame.pixels, i + 1) == g
      and string.byte(frame.pixels, i + 2) == b
    then
      masked = masked + 1
      parts[#parts + 1] = string.char(r, g, b, 0)
    else
      parts[#parts + 1] = frame.pixels:sub(i, i + 3)
    end
  end
  if masked == 0 then
    sourceError("the options face patch carries no backing trim to remove", { role = role })
  end
  frame.pixels = table.concat(parts)
end

-- Renders one fully opaque source-derived row plate: the listed source tile
-- rows scrubbed per row, rasterized through the shared screen path with
-- palette-zero normalized to the opaque backdrop color, then leveled to
-- the flat interior behind the kept source frame. The tile-level scrub
-- still removes the preprinted faces and still audits the filler backing;
-- the pixel flatten additionally erases the divider remnant and
-- edge-cap backing the tile grid cannot split. Private to this
-- module; the compiled bundle carries the staged bytes.
---@param charData OptionsAssetCompiler.CharData decoded MAIN base tiles
---@param palette OptionsAssetCompiler.PaletteData decoded MAIN base palette
---@param screen OptionsAssetCompiler.ScreenData decoded 256x256 MAIN base
---@param tileRows integer[] zero-based source tile rows in plate order
---@param expectedFillers integer[] audited backing tile per plate row
---@param image string staged output path
---@param role string plate role for failure detail
---@return string png
---@return { image: string, width: integer, height: integer }
local function renderRowPlate(charData, palette, screen, tileRows, expectedFillers, image, role)
  if #tileRows == 0 or #tileRows ~= #expectedFillers then
    sourceError("the options row plate carries no audited tile rows", { role = role })
  end
  local entries = {}
  for index, tileRow in ipairs(tileRows) do
    local row = scrubbedPlateRow(screen, tileRow, expectedFillers[index], role)
    for _, entry in ipairs(row) do
      entries[#entries + 1] = entry
    end
  end
  local height = #tileRows * 8
  local render = G2dRasterizer.renderScreen(
    charData,
    { colors = palette.colors },
    { width = 256, height = height, entries = entries },
    { asset = "options " .. role, member = OptionsSources.members.faceScreen },
    { backdrop = true }
  )
  for offset = 4, #render.pixels, 4 do
    if string.byte(render.pixels, offset) ~= 255 then
      sourceError("the options row plate is not fully opaque", { role = role, pixel = math.floor(offset / 4) })
    end
  end
  local flat = flattenInterior(render.pixels, height)
  return PngWriter.encode(256, height, flat), { image = image, width = 256, height = height }
end

-- Renders the transparent selected-row indicator from the separate MAIN
-- selection layer: the audited 256x56 source map rasterized with
-- palette-zero kept transparent, cropped to source rows 13..42. The
-- native indicator is a full rounded border box 30px tall, centered on
-- the 24px row with a 3px overhang on each side; cropping only the
-- middle rows would keep the side bars while dropping the top and
-- bottom borders. Private to this module; the compiled bundle carries
-- the staged bytes.
---@param archive Narc
---@param dependencies table[]
---@param chars table<integer, OptionsAssetCompiler.CharData>
---@param palettes table<integer, OptionsAssetCompiler.PaletteData>
---@param image string staged output path
---@param role string
---@return string png
---@return { image: string, width: integer, height: integer }
local function renderSelectionOverlay(archive, dependencies, chars, palettes, image, role)
  local screenMember = OptionsSources.selectionOverlayScreen
  local screenBytes = decodeMember(archive, screenMember, "options-selection-overlay")
  dependencies[#dependencies + 1] = {
    name = OptionsSources.archive.symbol .. ":member:" .. screenMember,
    sha1 = Hashing.sha1hex(screenBytes),
  }
  local screen = decodeG2d(screenBytes, "decodeScreen", screenMember) --[[@as OptionsAssetCompiler.ScreenData]]
  if screen.width ~= 256 or screen.height ~= 56 then
    sourceError("the options selection overlay is not the audited 256x56 surface", {
      role = role,
      member = screenMember,
      width = screen.width,
      height = screen.height,
    })
  end
  local charData = chars[OptionsSources.members.faceChar]
  if charData == nil then
    sourceError("the options selection overlay char is not decoded", { role = role })
  end
  local palette = palettes[OptionsSources.members.facePalette]
  if palette == nil then
    sourceError("the options selection overlay palette is not decoded", { role = role })
  end
  assert(charData ~= nil and palette ~= nil, "a missing options selection bank fails above")
  local render = G2dRasterizer.renderScreen(
    charData,
    { colors = palette.colors },
    screen,
    { asset = "options selection overlay", member = screenMember }
  )
  local strip = {}
  for y = 13, 42 do
    strip[#strip + 1] = render.pixels:sub(y * 256 * 4 + 1, (y + 1) * 256 * 4)
  end
  return PngWriter.encode(256, 30, table.concat(strip)), { image = image, width = 256, height = 30 }
end

---@param romFs RomFs
---@param versionId string
---@return table<string, unknown>? bundle
---@return Errors.Error? failure
function OptionsAssetCompiler.compile(romFs, versionId)
  assert(
    romFs and romFs.read and romFs.openNarc and romFs.resolvedNarc and romFs.metadata and romFs.version,
    "options compilation requires a RomFs-shaped object"
  )
  assert(type(versionId) == "string" and versionId ~= "", "options compilation requires its version identity")
  assert(
    versionId == romFs:version(),
    "options compilation refuses a version identity the source reader does not serve"
  )
  local ok, result = xpcall(function()
    local dependencies = {}
    local resolved = resolveResourceSets(romFs, dependencies)
    local archive, archiveBytes = loadArchive(romFs, OptionsSources.archive.symbol)
    dependencies[#dependencies + 1] = {
      name = OptionsSources.archive.symbol .. ":narc",
      sha1 = Hashing.sha1hex(archiveBytes),
    }
    local palettes = {}
    -- The sprite-bank palettes resolve through the resdat lists; the
    -- MAIN and SUB base palettes decode directly alongside them.
    local paletteMembers = { OptionsSources.members.facePalette, OptionsSources.members.previewPalette }
    for _, memberId in ipairs(OptionsSources.members.palettes) do
      paletteMembers[#paletteMembers + 1] = memberId
    end
    for _, memberId in ipairs(paletteMembers) do
      dependencies[#dependencies + 1] = {
        name = OptionsSources.archive.symbol .. ":member:" .. memberId,
        sha1 = Hashing.sha1hex(decodeMember(archive, memberId, "options-palette:" .. memberId)),
      }
      palettes[memberId] = decodeResource(archive, memberId, "decodePalette")
    end
    local chars = {}
    local charMembers = { OptionsSources.members.faceChar, OptionsSources.members.previewChar }
    for _, memberId in ipairs(OptionsSources.members.chars) do
      charMembers[#charMembers + 1] = memberId
    end
    for _, memberId in ipairs(charMembers) do
      dependencies[#dependencies + 1] = {
        name = OptionsSources.archive.symbol .. ":member:" .. memberId,
        sha1 = Hashing.sha1hex(decodeMember(archive, memberId, "options-char:" .. memberId)),
      }
      chars[memberId] = decodeResource(archive, memberId, "decodeChar")
    end
    local cells = {}
    for _, memberId in ipairs(OptionsSources.members.cells) do
      dependencies[#dependencies + 1] = {
        name = OptionsSources.archive.symbol .. ":member:" .. memberId,
        sha1 = Hashing.sha1hex(decodeMember(archive, memberId, "options-cell:" .. memberId)),
      }
      cells[memberId] = decodeResource(archive, memberId, "decodeCell")
    end
    local animations = {}
    for _, memberId in ipairs(OptionsSources.members.animations) do
      dependencies[#dependencies + 1] = {
        name = OptionsSources.archive.symbol .. ":member:" .. memberId,
        sha1 = Hashing.sha1hex(decodeMember(archive, memberId, "options-anim:" .. memberId)),
      }
      animations[memberId] = decodeResource(archive, memberId, "decodeAnimation")
    end
    local function setResources(set)
      return {
        charData = chars[resolved.char[set.char]],
        palette = palettes[resolved.palette[set.palette]],
        cell = cells[resolved.cell[set.cell]],
      }
    end
    local image = FieldUiAssetCache.assetDir() .. "/options-chrome.png"
    local packed = {}
    local function sequenceFor(setName, sequenceId, role)
      local set = OptionsSources.sets[setName]
      local animation = animations[resolved.animation[set.animation]].anims[sequenceId + 1]
      if animation == nil then
        sourceError("the options animation bank carries no compiled sequence", {
          set = setName,
          sequence = sequenceId,
        })
      end
      assert(animation ~= nil, "a missing options sequence fails above")
      return compileSequence(setResources(set), animation, image, packed, role)
    end
    -- The packed frame order is fixed: both pill sizes with their selected
    -- states, both arrow idle/pressed pairs, then the four footer action
    -- states. Packing is producer layout, never a runtime contract.
    local selectedSmall = sequenceFor("pills", 0, "options:pills:small")
    local selectedWide = sequenceFor("pills", 1, "options:pills:wide")
    local leftIdle = sequenceFor("leftArrow", 0, "options:arrow:left:idle")
    local leftPressed = sequenceFor("leftArrow", 1, "options:arrow:left:pressed")
    local rightIdle = sequenceFor("rightArrow", 0, "options:arrow:right:idle")
    local rightPressed = sequenceFor("rightArrow", 1, "options:arrow:right:pressed")
    local actionNormal = sequenceFor("actions", 0, "options:action:normal")
    local actionFocused = sequenceFor("actions", 1, "options:action:focused")
    local actionPressed = sequenceFor("actions", 2, "options:action:pressed")
    local actionPressedFocused = sequenceFor("actions", 3, "options:action:pressed-focused")
    -- The unselected face patches crop the baseline screen at the curated
    -- origins using the decoded pill frame footprints, never a guessed
    -- width, then clear the baseline backing trim to transparent so the
    -- prints blend onto the leveled plates. The atlas keeps the crop's
    -- screen position out of the frame record: the crop origin is producer
    -- layout, the frame is runtime art.
    local faceScreenBytes = decodeMember(archive, OptionsSources.members.faceScreen, "options-face-screen")
    dependencies[#dependencies + 1] = {
      name = OptionsSources.archive.symbol .. ":member:" .. OptionsSources.members.faceScreen,
      sha1 = Hashing.sha1hex(faceScreenBytes),
    }
    local faceScreen = decodeG2d(faceScreenBytes, "decodeScreen", OptionsSources.members.faceScreen) --[[@as OptionsAssetCompiler.ScreenData]]
    if faceScreen.width ~= 256 or faceScreen.height ~= 256 then
      sourceError("the options baseline face is not the audited 256x256 surface", {
        width = faceScreen.width,
        height = faceScreen.height,
      })
    end
    local faceImage = G2dRasterizer.renderScreen(
      chars[OptionsSources.members.faceChar],
      { colors = palettes[OptionsSources.members.facePalette].colors },
      faceScreen,
      { asset = "options baseline face", member = OptionsSources.members.faceScreen }
    )
    local pillSmall = selectedSmall.frames[1]
    local pillWide = selectedWide.frames[1]
    local function cropFace(origin, footprint, role)
      if
        origin.x < 0
        or origin.y < 0
        or origin.x + footprint.width > faceImage.width
        or origin.y + footprint.height > faceImage.height
      then
        sourceError("the options face patch leaves its baseline screen", {
          role = role,
          origin = origin,
          footprint = footprint,
          screen = { width = faceImage.width, height = faceImage.height },
        })
      end
      local rows = {}
      for y = 0, footprint.height - 1 do
        rows[#rows + 1] = faceImage.pixels:sub(
          ((origin.y + y) * faceImage.width + origin.x) * 4 + 1,
          ((origin.y + y) * faceImage.width + origin.x + footprint.width) * 4
        )
      end
      local frame = {
        width = footprint.width,
        height = footprint.height,
        pixels = table.concat(rows),
        offset = { x = 0, y = 0 },
        ticks = 1,
      }
      -- Unselected faces are the only cropFace callers: their footprints
      -- carry the baseline inter-pill backing, which must clear so the
      -- prints blend onto the leveled plates and any custom backing.
      stripFaceTrim(frame, role)
      packed[#packed + 1] = frame
      frame.rect = { x = 0, y = 0, width = 0, height = 0 }
      return {
        frames = {
          {
            image = image,
            atlas = frame.rect,
            offset = frame.offset,
            ticks = 1,
          },
        },
        loop = true,
        bounds = { x = 0, y = 0, width = frame.width, height = frame.height },
      }
    end
    local pillSmallFootprint = { width = pillSmall.atlas.width, height = pillSmall.atlas.height }
    local pillWideFootprint = { width = pillWide.atlas.width, height = pillWide.atlas.height }
    -- The packed atlas lists face patches before their selected pills so
    -- the unselected state of each size precedes its selected state.
    local unselectedSmall = cropFace(OptionsSources.faceOrigins.small, pillSmallFootprint, "options:face:small")
    local unselectedWide = cropFace(OptionsSources.faceOrigins.wide, pillWideFootprint, "options:face:wide")
    -- Labels lower through the shared message bank; the stored tokens keep
    -- the exact control stream the runtime text renderer consumes.
    local messageArchive = loadArchive(romFs, OptionsSources.messagesArchive.symbol)
    local bank, bankFailure =
      UiMessageBank.read(messageArchive, OptionsSources.messageBank, "options-labels", dependencies, "options-labels")
    if bank == nil then
      assert(bankFailure ~= nil, "a missing options label bank carries its failure")
      sourceError("the options label bank is unavailable", {
        bank = OptionsSources.messageBank,
        stage = bankFailure.stage,
        cause = bankFailure.message,
      })
    end
    assert(bank ~= nil, "an unavailable options label bank fails above")
    local slots = OptionsSources.messages
    local labels = {
      title = lowerLabel(bank, slots.title, "title"),
      textSpeed = lowerLabel(bank, slots.textSpeed, "textSpeed"),
      battleScene = lowerLabel(bank, slots.battleScene, "battleScene"),
      battleStyle = lowerLabel(bank, slots.battleStyle, "battleStyle"),
      soundMode = lowerLabel(bank, slots.soundMode, "soundMode"),
      textFrame = lowerLabel(bank, slots.textFrame, "textFrame"),
      confirm = lowerLabel(bank, slots.confirm, "confirm"),
      quit = lowerLabel(bank, slots.quit, "quit"),
      textSpeedValues = {
        mid = lowerLabel(bank, slots.textSpeedValues.mid, "textSpeedValues.mid"),
        fast = lowerLabel(bank, slots.textSpeedValues.fast, "textSpeedValues.fast"),
      },
      battleSceneValues = {
        on = lowerLabel(bank, slots.battleSceneValues.on, "battleSceneValues.on"),
        off = lowerLabel(bank, slots.battleSceneValues.off, "battleSceneValues.off"),
      },
      battleStyleValues = {
        shift = lowerLabel(bank, slots.battleStyleValues.shift, "battleStyleValues.shift"),
        set = lowerLabel(bank, slots.battleStyleValues.set, "battleStyleValues.set"),
      },
      soundModeValues = {
        stereo = lowerLabel(bank, slots.soundModeValues.stereo, "soundModeValues.stereo"),
        mono = lowerLabel(bank, slots.soundModeValues.mono, "soundModeValues.mono"),
      },
      frameValues = {},
    }
    for frame = 0, slots.frameValueCount - 1 do
      labels.frameValues[frame] = lowerLabel(bank, slots.firstFrameValue + frame, "frameValues[" .. frame .. "]")
    end
    local framePreviewText = {}
    for frame = 0, slots.framePreviewCount - 1 do
      framePreviewText[frame] = lowerLabel(bank, slots.firstFramePreview + frame, "framePreviewText[" .. frame .. "]")
    end
    -- Pack the atlas in one deterministic row in compile order: both
    -- selected pills, both arrow pairs, the footer actions, then both
    -- face patches. The order is producer layout, never a runtime contract.
    local atlasWidth, atlasHeight = 0, 0
    for _, frame in ipairs(packed) do
      atlasWidth = atlasWidth + frame.width
      atlasHeight = math.max(atlasHeight, frame.height)
    end
    local cursorX = 0
    for _, frame in ipairs(packed) do
      frame.rect.x, frame.rect.y = cursorX, 0
      frame.rect.width, frame.rect.height = frame.width, frame.height
      cursorX = cursorX + frame.width
    end
    local rows = {}
    for y = 0, atlasHeight - 1 do
      for _, frame in ipairs(packed) do
        if y < frame.height then
          rows[#rows + 1] = frame.pixels:sub(y * frame.width * 4 + 1, (y + 1) * frame.width * 4)
        else
          rows[#rows + 1] = string.rep(string.char(0, 0, 0, 0), frame.width)
        end
      end
    end
    -- The opaque header/footer shell bands plus the SUB preview: the
    -- MAIN base title rows (tile rows 0..2) and footer rows (tile rows
    -- 21..23) staged as their own 256x24 files, and the SUB base behind
    -- the preview, each staged as its own file and indexed asset beside
    -- the packed chrome atlas.
    local headerImage = FieldUiAssetCache.assetDir() .. "/options-header-background.png"
    local footerImage = FieldUiAssetCache.assetDir() .. "/options-footer-background.png"
    local previewImage = FieldUiAssetCache.assetDir() .. "/options-preview-background.png"
    local headerPng, headerAsset, controlsScreen = renderShellBand(
      archive,
      dependencies,
      chars,
      palettes,
      OptionsSources.bases.controls,
      0,
      3,
      headerImage,
      "options:backdrop:header"
    )
    local footerPng, footerAsset = renderBandFromScreen(
      chars[OptionsSources.bases.controls.charMember],
      palettes[OptionsSources.bases.controls.paletteMember],
      controlsScreen,
      21,
      3,
      footerImage,
      "options:backdrop:footer"
    )
    local previewPng, previewAsset = renderBackdrop(
      archive,
      dependencies,
      chars,
      palettes,
      OptionsSources.bases.preview,
      previewImage,
      "options:backdrop:preview"
    )
    local overlayImage = FieldUiAssetCache.assetDir() .. "/options-selection-overlay.png"
    local overlayPng, overlayAsset =
      renderSelectionOverlay(archive, dependencies, chars, palettes, overlayImage, "options:selection-overlay")
    -- The scrolling list row plates share the decoded MAIN base: the two
    -- native 24px bands as the alternating plates, and the 72px compound
    -- frame item as the odd selector band over five mid-band rows with
    -- the odd lower edge closing the item.
    local rowPlates = OptionsSources.rowPlates
    local oddTileRows = { rowPlates.oddBand.topTileRow, rowPlates.oddBand.midTileRow, rowPlates.oddBand.bottomTileRow }
    local evenTileRows =
      { rowPlates.evenBand.topTileRow, rowPlates.evenBand.midTileRow, rowPlates.evenBand.bottomTileRow }
    local frameTileRows = {
      rowPlates.oddBand.topTileRow,
      rowPlates.oddBand.midTileRow,
      rowPlates.oddBand.bottomTileRow,
      rowPlates.oddBand.midTileRow,
      rowPlates.oddBand.midTileRow,
      rowPlates.oddBand.midTileRow,
      rowPlates.oddBand.midTileRow,
      rowPlates.oddBand.midTileRow,
      rowPlates.oddBand.bottomTileRow,
    }
    local frameFillers = {
      rowPlates.oddFillers[1],
      rowPlates.oddFillers[2],
      rowPlates.oddFillers[3],
      rowPlates.oddFillers[2],
      rowPlates.oddFillers[2],
      rowPlates.oddFillers[2],
      rowPlates.oddFillers[2],
      rowPlates.oddFillers[2],
      rowPlates.oddFillers[3],
    }
    local plateChar = chars[OptionsSources.bases.controls.charMember]
    local platePalette = palettes[OptionsSources.bases.controls.paletteMember]
    if plateChar == nil or platePalette == nil then
      sourceError("the options row plate banks are not decoded", { role = "options:row-plates" })
    end
    assert(plateChar ~= nil and platePalette ~= nil, "a missing options plate bank fails above")
    local oddImage = FieldUiAssetCache.assetDir() .. "/options-row-odd.png"
    local evenImage = FieldUiAssetCache.assetDir() .. "/options-row-even.png"
    local frameImage = FieldUiAssetCache.assetDir() .. "/options-row-frame.png"
    local oddPng, oddAsset =
      renderRowPlate(plateChar, platePalette, controlsScreen, oddTileRows, rowPlates.oddFillers, oddImage, "row-odd")
    local evenPng, evenAsset = renderRowPlate(
      plateChar,
      platePalette,
      controlsScreen,
      evenTileRows,
      rowPlates.evenFillers,
      evenImage,
      "row-even"
    )
    local framePng, frameAsset =
      renderRowPlate(plateChar, platePalette, controlsScreen, frameTileRows, frameFillers, frameImage, "row-frame")
    local files = {
      [image] = PngWriter.encode(atlasWidth, atlasHeight, table.concat(rows)),
      [headerImage] = headerPng,
      [footerImage] = footerPng,
      [previewImage] = previewPng,
      [overlayImage] = overlayPng,
      [oddImage] = oddPng,
      [evenImage] = evenPng,
      [frameImage] = framePng,
    }
    local section = {
      version = 7,
      backdrops = {
        header = FieldUiAssetCache.ASSET.OPTIONS_HEADER_BACKGROUND,
        footer = FieldUiAssetCache.ASSET.OPTIONS_FOOTER_BACKGROUND,
        preview = FieldUiAssetCache.ASSET.OPTIONS_PREVIEW_BACKGROUND,
      },
      rowBackings = {
        odd = FieldUiAssetCache.ASSET.OPTIONS_ROW_ODD,
        even = FieldUiAssetCache.ASSET.OPTIONS_ROW_EVEN,
        frame = FieldUiAssetCache.ASSET.OPTIONS_ROW_FRAME,
      },
      selectionOverlay = FieldUiAssetCache.ASSET.OPTIONS_SELECTION_OVERLAY,
      labels = labels,
      choices = {
        small = { unselected = unselectedSmall, selected = selectedSmall },
        wide = { unselected = unselectedWide, selected = selectedWide },
      },
      arrows = {
        left = { idle = leftIdle, pressed = leftPressed },
        right = { idle = rightIdle, pressed = rightPressed },
      },
      actions = {
        normal = actionNormal,
        focused = actionFocused,
        pressed = actionPressed,
        pressedFocused = actionPressedFocused,
      },
      framePreviewText = framePreviewText,
      animationTickSeconds = 1 / DisplayTiming.REFRESH_HZ,
    }
    return {
      section = section,
      files = files,
      dependencies = dependencies,
      atlas = { image = image, width = atlasWidth, height = atlasHeight },
      backgrounds = {
        { key = FieldUiAssetCache.ASSET.OPTIONS_HEADER_BACKGROUND, asset = headerAsset },
        { key = FieldUiAssetCache.ASSET.OPTIONS_FOOTER_BACKGROUND, asset = footerAsset },
        { key = FieldUiAssetCache.ASSET.OPTIONS_PREVIEW_BACKGROUND, asset = previewAsset },
        { key = FieldUiAssetCache.ASSET.OPTIONS_SELECTION_OVERLAY, asset = overlayAsset },
        { key = FieldUiAssetCache.ASSET.OPTIONS_ROW_ODD, asset = oddAsset },
        { key = FieldUiAssetCache.ASSET.OPTIONS_ROW_EVEN, asset = evenAsset },
        { key = FieldUiAssetCache.ASSET.OPTIONS_ROW_FRAME, asset = frameAsset },
      },
    }
  end, function(err)
    if Errors.is(err) then
      return err
    end
    return { raw = err, trace = debug.traceback("", 2) }
  end)
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

return OptionsAssetCompiler
