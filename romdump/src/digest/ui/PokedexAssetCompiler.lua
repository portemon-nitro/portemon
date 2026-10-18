-- Compiles the Pokedex application presentation projection from the
-- selected dump and the compiled catalog: source-independent page/cell/
-- animation/window/sprite roles, generated application images, footprint
-- corrections, area maps, and Spinda personalization metadata. Source
-- graphics decode through the existing G2d primitives; shared mon, font,
-- and message producers retain their own outputs. Returns the validated
-- manifest; generated image bytes, provenance, and the marker travel
-- through the optional sink for the cache writer.

local Errors = require("libs.errors.src.Errors")
local G2dDecoder = require("romdump.src.digest.ui.G2dDecoder")
local Hashing = require("romdump.src.digest.Hashing")
local Lz10 = require("romdump.src.digest.Lz10")
local MonSources = require("romdump.src.config.MonSources")
local PngWriter = require("libs.assets.src.PngWriter")
local PokedexAssetSchema = require("libs.assets.src.PokedexAssetSchema")
local PokedexCache = require("libs.assets.src.PokedexCache")
local PokedexSources = require("romdump.src.config.PokedexSources")

local PokedexAssetCompiler = {}

local REQUIRED_PAGES = {
  "cover",
  "grid",
  "results",
  "search.criteria",
  "search.order",
  "search.name",
  "search.type",
  "search.height",
  "search.weight",
  "search.area",
  "search.shape",
  "entry.area",
  "entry.size",
  "entry.forms",
  "entry.compare",
  "entry.return",
  "registration",
}

-- Character tiles address the generated chrome linearly in one
-- dimension, exactly like source 1D OBJ tile runs: tile t starts at
-- (t % COLUMNS) * 8. The width is chosen so no referenced tile run in
-- the shipped archive wraps to a second row (the widest referenced run
-- ends at tile 227); any future reference outside the atlas fails
-- loudly at the bounds check below instead of silently wrapping. Eight
-- padding rows cover the tallest source OBJ (64 pixels), so an object
-- anchored on the last tile row cannot read past the image.
local TILES_PER_ROW = 256
local TILE_PAD_ROWS = 8

local compileSpinda
local TILE_BYTES = 32

local function rgba(r, g, b, a)
  return { r = r, g = g, b = b, a = a }
end

local function unwrapMember(bytes, memberId, label)
  if #bytes >= 1 and string.byte(bytes, 1) == 0x10 then
    local plain, err = Lz10.decode(bytes)
    if not plain then
      error(err or ("pokedex member " .. memberId .. " does not decompress: " .. label), 0)
    end
    return plain
  end
  return bytes
end

local function decodeKind(kind, bytes, role)
  local record, err = G2dDecoder[kind](bytes, { label = "pokedex:" .. role })
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

local function openArchive(romFs, spec)
  local bytes, err = romFs:readSourcePath(spec.path)
  if not bytes then
    error(err or ("pokedex source archive is unavailable: " .. spec.path), 0)
  end
  local Narc = require("libs.nds.src.nitro.Narc")
  local archive, narcErr = Narc.open(assert(bytes), spec.path)
  if not archive then
    error(narcErr, 0)
  end
  if archive:memberCount() ~= spec.memberCount then
    error(
      "pokedex source archive has an unexpected member count: " .. spec.path .. " (" .. archive:memberCount() .. ")",
      0
    )
  end
  return archive, bytes
end

---@param charTiles string
---@param colors table<integer, { r: integer, g: integer, b: integer }>
---@return string pixels RGBA bytes of the 32-per-row tile grid
---@return integer width
---@return integer height
local function renderTileGrid(charTiles, colors)
  local tiles = #charTiles / TILE_BYTES
  assert(tiles % 1 == 0, "pokedex character payload is not whole tiles")
  if #colors < 16 then
    error("pokedex tile rendering needs a sixteen-color bank", 0)
  end
  local function pixel(nibble)
    if nibble == 0 then
      return "\0\0\0\0"
    end
    local color = assert(colors[nibble + 1], "pokedex tile references a missing palette entry")
    return string.char(color.r, color.g, color.b, 255)
  end

  local cols = TILES_PER_ROW
  local rows = math.max(1, math.ceil(tiles / cols)) + TILE_PAD_ROWS
  local width, height = cols * 8, rows * 8
  local out = {}
  for y = 0, height - 1 do
    local parts = {}
    for x = 0, width - 1 do
      local tx, ty = math.floor(x / 8), math.floor(y / 8)
      local tile = ty * cols + tx
      local nibble = 0
      if tile < tiles then
        local base = tile * TILE_BYTES + (y % 8) * 4 + math.floor((x % 8) / 2)
        local byte = string.byte(charTiles, base + 1)
        nibble = (x % 2 == 0) and byte % 16 or math.floor(byte / 16)
      end
      parts[#parts + 1] = pixel(nibble)
    end
    out[#out + 1] = table.concat(parts)
  end
  return table.concat(out), width, height
end

local function readFootprintMember(archive, memberId)
  local bytes, err = archive:readMember(memberId)
  if not bytes then
    error(err or ("pokedex footprint member is unavailable: " .. memberId), 0)
  end
  return bytes
end

---@return { kind: string, key: string }[]
function PokedexAssetCompiler.presentationDependencies()
  local deps = {
    { kind = "pokedex-data", key = "global" },
    { kind = "mon-layout", key = "global" },
    { kind = "field-font", key = "global" },
  }
  for _, bankId in ipairs(PokedexSources.messageBankIds()) do
    if not PokedexSources.unbuildableMessageBanks[bankId] then
      deps[#deps + 1] = { kind = "message-bank", key = tostring(bankId) }
    end
  end
  table.sort(deps, function(left, right)
    if left.kind == right.kind then
      return left.key < right.key
    end
    return left.kind < right.kind
  end)
  return deps
end

local function _compile(romFs, versionId, catalog, sink)
  assert(romFs and romFs.readSourcePath and romFs.metadata, "compile requires a RomFs-shaped object")
  assert(type(versionId) == "string" and versionId ~= "", "compile requires a version")
  assert(type(catalog) == "table" and catalog.schema == PokedexCache.CATALOG_SCHEMA, "compile requires its catalog")
  if not PokedexSources.versions[versionId] then
    error("pokedex presentation names an unsupported version: " .. versionId, 0)
  end
  local metadata = assert(romFs:metadata())
  assert(type(metadata.sha1) == "string", "ROM metadata carries its SHA-1")

  local gfxArchive, gfxBytes = openArchive(romFs, PokedexSources.archives.graphics)
  local footArchive, footBytes = openArchive(romFs, PokedexSources.archives.footprints)

  local assets = {}
  local entries = {
    { path = PokedexSources.archives.graphics.path, sha1 = Hashing.sha1hex(gfxBytes) },
    { path = PokedexSources.archives.footprints.path, sha1 = Hashing.sha1hex(footBytes) },
  }

  -- Decode every application member by container magic.
  ---@type table<integer, { tiles: string, depth: integer, tileCount: number }>
  local chars = {}
  ---@type table<integer, { r: integer, g: integer, b: integer }[]>
  local palettes = {}
  ---@type table<integer, { cells: table<integer, unknown> }>
  local cellsByMember = {}
  ---@type table<integer, { anims: table<integer, unknown> }>
  local animsByMember = {}
  local rawCount, compressedCount = 0, 0
  for member = 0, PokedexSources.archives.graphics.memberCount - 1 do
    local packed = gfxArchive:readMember(member)
    if not packed then
      error("pokedex application member is unavailable: " .. member, 0)
    end
    local raw
    if #packed >= 1 and string.byte(packed, 1) == 0x10 then
      compressedCount = compressedCount + 1
      raw = unwrapMember(packed, member, "graphics")
    else
      rawCount = rawCount + 1
      raw = packed
    end
    local magic = #raw >= 4 and raw:sub(1, 4) or ""
    if magic == "RGCN" then
      local char = decodeKind("decodeChar", raw, "graphics-char-" .. member)
      chars[member] = { tiles = char.tiles, depth = char.depth, tileCount = #char.tiles / TILE_BYTES }
      if chars[member].tileCount % 1 ~= 0 then
        error("pokedex character member carries partial tiles: " .. member, 0)
      end
    elseif magic == "RLCN" then
      local palette = decodeKind("decodePalette", raw, "graphics-palette-" .. member)
      palettes[member] = palette.colors
    elseif magic == "RECN" then
      cellsByMember[member] = decodeKind("decodeCell", raw, "graphics-cell-" .. member)
    elseif magic == "RNAN" then
      animsByMember[member] = decodeKind("decodeAnimation", raw, "graphics-animation-" .. member)
    elseif magic == "RCSN" then
      decodeKind("decodeScreen", raw, "graphics-screen-" .. member)
    else
      error("pokedex application member has an unknown container: " .. member, 0)
    end
  end

  local paletteMembers = {}
  for member in pairs(palettes) do
    paletteMembers[#paletteMembers + 1] = member
  end
  table.sort(paletteMembers)
  if #paletteMembers == 0 then
    error("pokedex application archive carries no palettes", 0)
  end

  local function nearestPalette(member)
    local best, bestDistance = paletteMembers[1], math.huge
    for _, candidate in ipairs(paletteMembers) do
      local distance = math.abs(candidate - member)
      if distance < bestDistance then
        best, bestDistance = candidate, distance
      end
    end
    return palettes[best]
  end

  local largestPalette = palettes[paletteMembers[1]]
  for _, member in ipairs(paletteMembers) do
    if #palettes[member] > #largestPalette then
      largestPalette = palettes[member]
    end
  end

  -- Rendered application chrome: one tile-grid PNG per character member.
  local chrome = {}
  local charMembers = {}
  for member in pairs(chars) do
    charMembers[#charMembers + 1] = member
  end
  table.sort(charMembers)
  for _, member in ipairs(charMembers) do
    local record = chars[member]
    local palette = record.depth == 3 and nearestPalette(member) or largestPalette
    local pixels, width, height = renderTileGrid(record.tiles, palette)
    local role = "gfx-" .. member
    local path = PokedexCache.assetDir() .. "/" .. role .. ".png"
    assets[path] = PngWriter.encode(width, height, pixels)
    chrome[role] = { path = path, width = width, height = height }
  end
  if #charMembers == 0 then
    error("pokedex application archive carries no character pages", 0)
  end
  local firstChrome = "gfx-" .. charMembers[1]

  local function chromeForCell(cellMember, maxTile)
    local best, bestMember = nil, nil
    for _, member in ipairs(charMembers) do
      if member < cellMember and chars[member].tileCount > maxTile then
        if bestMember == nil or member > bestMember then
          best, bestMember = member, member
        end
      end
    end
    if best == nil then
      error("pokedex cell member has no covering character page: " .. cellMember, 0)
    end
    return "gfx-" .. best
  end

  -- Normalized cells: bounds over OBJ extents, source rects on the
  -- 32-tiles-per-row character layout the chrome renders use.
  local cells = {}
  local cellMembers = {}
  for member in pairs(cellsByMember) do
    cellMembers[#cellMembers + 1] = member
  end
  table.sort(cellMembers)
  local function maxTileOf(decoded)
    local maxTile = 0
    for _, cell in ipairs(decoded.cells) do
      for _, obj in ipairs(cell.objs) do
        if obj.tile > maxTile then
          maxTile = obj.tile
        end
      end
    end
    return maxTile
  end

  for _, member in ipairs(cellMembers) do
    local decoded = cellsByMember[member]
    local chromeRole = chromeForCell(member, maxTileOf(decoded))
    local chromeRecord = chrome[chromeRole]
    for index, cell in ipairs(decoded.cells) do
      local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
      for _, obj in ipairs(cell.objs) do
        x0 = math.min(x0, obj.x)
        y0 = math.min(y0, obj.y)
        x1 = math.max(x1, obj.x + obj.width)
        y1 = math.max(y1, obj.y + obj.height)
      end
      if x1 <= x0 or y1 <= y0 then
        error("pokedex cell carries no extent: member " .. member .. " cell " .. index, 0)
      end
      local parts = {}
      for _, obj in ipairs(cell.objs) do
        local source = {
          x = (obj.tile % TILES_PER_ROW) * 8,
          y = math.floor(obj.tile / TILES_PER_ROW) * 8,
          width = obj.width,
          height = obj.height,
        }
        if
          source.x < 0
          or source.y < 0
          or source.x + source.width > chromeRecord.width
          or source.y + source.height > chromeRecord.height
        then
          error("pokedex cell part reads outside its character page: member " .. member, 0)
        end
        parts[#parts + 1] = {
          chrome = chromeRole,
          source = source,
          x = obj.x,
          y = obj.y,
          flipX = obj.flipH,
          flipY = obj.flipV,
          priority = obj.priority,
          paletteGroup = "cell",
        }
      end
      cells["cell-" .. member .. "-" .. index] = {
        bounds = { x = x0, y = y0, width = x1 - x0, height = y1 - y0 },
        parts = parts,
      }
    end
  end

  -- Normalized animations: preserved frame order, durations, source
  -- transforms, and one-based loop indices. Ping-pong play modes have no
  -- presentation spelling here and fail rather than mislabeling.
  local animations = {}
  local animMembers = {}
  for member in pairs(animsByMember) do
    animMembers[#animMembers + 1] = member
  end
  table.sort(animMembers)
  for _, member in ipairs(animMembers) do
    local cellMember = member - 1
    local decoded = cellsByMember[cellMember]
    if decoded == nil then
      error("pokedex animation member has no preceding cell member: " .. member, 0)
    end
    for sequence, sequenceRecord in ipairs(animsByMember[member].anims) do
      local frames = {}
      for _, frame in ipairs(sequenceRecord.frames) do
        if frame.cell < 0 or frame.cell >= #decoded.cells then
          error("pokedex animation frame references an unknown cell: member " .. member, 0)
        end
        frames[#frames + 1] = {
          cell = "cell-" .. cellMember .. "-" .. (frame.cell + 1),
          duration = frame.duration,
          offsetX = frame.translateX,
          offsetY = frame.translateY,
          rotation = frame.rotation,
          scaleX = frame.scaleX,
          scaleY = frame.scaleY,
        }
      end
      local once
      if sequenceRecord.playMode == "forward" then
        once = true
      elseif sequenceRecord.playMode == "forward_loop" then
        once = false
      else
        error("pokedex animation member uses an unsupported play mode: " .. member, 0)
      end
      animations["anim-" .. member .. "-" .. sequence] = {
        frames = frames,
        loopFrom = sequenceRecord.loopStartFrameIdx + 1,
        direction = "forward",
        once = once,
      }
    end
  end
  if #animMembers == 0 then
    error("pokedex application archive carries no animations", 0)
  end

  local windows = {
    ["body-window"] = {
      pane = "information",
      layer = 0,
      x = 0,
      y = 0,
      width = 256,
      height = 192,
      font = 0,
      foreground = rgba(255, 255, 255, 255),
      shadow = rgba(0, 0, 0, 255),
      background = rgba(0, 0, 0, 0),
      align = "left",
      paletteGroup = "window",
    },
    ["header-window"] = {
      pane = "information",
      layer = 1,
      x = 0,
      y = 0,
      width = 256,
      height = 32,
      font = 4,
      foreground = rgba(255, 255, 255, 255),
      shadow = rgba(0, 0, 0, 255),
      background = rgba(0, 0, 0, 0),
      align = "center",
      paletteGroup = "window",
    },
  }

  local sprites = {}
  local animRoles = {}
  for role in pairs(animations) do
    animRoles[#animRoles + 1] = role
  end
  table.sort(animRoles)
  for drawPriority, role in ipairs(animRoles) do
    sprites["sprite-" .. role] = {
      pane = "information",
      animation = role,
      x = 0,
      y = 0,
      priority = 0,
      drawPriority = drawPriority,
      paletteGroup = "sprite",
    }
  end

  local cellRoles = {}
  for role in pairs(cells) do
    cellRoles[#cellRoles + 1] = role
  end
  table.sort(cellRoles)
  local spriteRoles = {}
  for role in pairs(sprites) do
    spriteRoles[#spriteRoles + 1] = role
  end
  table.sort(spriteRoles)

  local pages = {}
  for _, role in ipairs(REQUIRED_PAGES) do
    pages[role] = {
      backdrop = { information = rgba(0, 0, 0, 255), controls = rgba(16, 16, 16, 255) },
      backgrounds = {
        information = { { chrome = firstChrome, layer = 0, x = 0, y = 0, priority = 0, paletteGroup = "chrome" } },
        controls = {},
      },
      cells = cellRoles,
      sprites = spriteRoles,
      windows = { "body-window", "header-window" },
    }
  end

  -- Footprints: the source 16x16 assembly of unpacked pixels, two 64-byte
  -- halves from offsets 0x80 and 0x00, through palette bank 0.
  local footPaletteBytes = readFootprintMember(footArchive, 0)
  local footPalette = decodeKind("decodePalette", footPaletteBytes, "footprints-palette")
  if #footPalette.colors < 16 then
    error("pokedex footprint palette carries no bank 0", 0)
  end
  local order = {}
  for _, key in ipairs(catalog.dexOrders.national) do
    order[#order + 1] = key
  end
  local function footprintPixels(key)
    local speciesId = assert(MonSources.speciesId(key), "footprint resolves its species")
    local graphic = unwrapMember(readFootprintMember(footArchive, speciesId + 3), speciesId + 3, "footprint")
    if #graphic < 0xC0 then
      error("pokedex footprint graphic is shorter than its assembly window: " .. key, 0)
    end
    local halves = graphic:sub(0x81, 0xC0) .. graphic:sub(1, 0x40)
    local rows = {}
    for y = 0, 15 do
      local row = {}
      for x = 0, 15 do
        local byte = string.byte(halves, y * 8 + math.floor(x / 2) + 1)
        local nibble = (x % 2 == 0) and byte % 16 or math.floor(byte / 16)
        if nibble == 0 then
          row[#row + 1] = "\0\0\0\0"
        else
          local color = footPalette.colors[nibble + 1]
          if color == nil then
            error("pokedex footprint references a missing palette entry: " .. key, 0)
          end
          row[#row + 1] = string.char(color.r, color.g, color.b, 255)
        end
      end
      rows[#rows + 1] = table.concat(row)
    end
    return rows
  end

  local footRects, footRows = {}, {}
  do
    local cols = 32
    local speciesPixels = {}
    for _, key in ipairs(order) do
      speciesPixels[key] = footprintPixels(key)
    end
    local rows = math.max(1, math.ceil(#order / cols))
    local pixels = {}
    for row = 0, rows - 1 do
      for y = 0, 15 do
        local parts = {}
        for col = 0, cols - 1 do
          local key = order[row * cols + col + 1]
          if key == nil then
            parts[#parts + 1] = string.rep("\0", 16 * 4)
          else
            parts[#parts + 1] = speciesPixels[key][y + 1]
          end
        end
        pixels[#pixels + 1] = table.concat(parts)
      end
    end
    for index, key in ipairs(order) do
      footRects[key] = {
        chrome = "footprints",
        source = {
          x = ((index - 1) % cols) * 16,
          y = math.floor((index - 1) / cols) * 16,
          width = 16,
          height = 16,
        },
      }
    end
    footRows.width, footRows.height, footRows.pixels = cols * 16, rows * 16, table.concat(pixels)
  end
  local footPath = PokedexCache.assetDir() .. "/footprints.png"
  assets[footPath] = PngWriter.encode(footRows.width, footRows.height, footRows.pixels)
  chrome["footprints"] = { path = footPath, width = footRows.width, height = footRows.height }

  local function regionUnion(region)
    local x0, y0, x1, y1, found = math.huge, math.huge, -math.huge, -math.huge, false
    for _, geometry in pairs(catalog.areaGeometry) do
      if geometry.region == region and geometry.kind == "outdoor" and geometry.rect ~= nil then
        found = true
        x0 = math.min(x0, geometry.rect.x)
        y0 = math.min(y0, geometry.rect.y)
        x1 = math.max(x1, geometry.rect.x + geometry.rect.width)
        y1 = math.max(y1, geometry.rect.y + geometry.rect.height)
      end
    end
    if not found then
      return { x = 0, y = 0, width = 256, height = 192 }
    end
    return { x = x0, y = y0, width = x1 - x0, height = y1 - y0 }
  end

  local areaMaps = {}
  for _, region in ipairs({ "johto", "kanto" }) do
    local extent = regionUnion(region)
    areaMaps[region] = {
      role = "map",
      extent = extent,
      scrollBounds = { x = extent.x, y = extent.y, width = extent.width, height = extent.height },
      crop = { x = 56, y = 40, width = 200, height = 136 },
    }
  end

  local spinda = compileSpinda(romFs)

  local manifest = {
    schema = PokedexCache.SCHEMA,
    versionId = versionId,
    fonts = { body = 0, header = 4 },
    pages = pages,
    chrome = chrome,
    cells = cells,
    animations = animations,
    windows = windows,
    sprites = sprites,
    pictures = { backYOffset = catalog.pictures.backYOffset },
    footprints = footRects,
    areaMaps = areaMaps,
    spinda = spinda,
    text = catalog.textBindings,
  }

  local validated, schemaErr = PokedexAssetSchema.validateManifest(manifest, catalog)
  if validated == nil then
    error(schemaErr and schemaErr.message or "pokedex manifest failed closed validation", 0)
  end

  if sink ~= nil then
    local provenance = {
      schema = PokedexCache.SCHEMA,
      cacheFormat = PokedexCache.FORMAT,
      versionId = versionId,
      versionRomSha1 = metadata.sha1,
      source = PokedexSources.provenance,
      selections = {
        characters = #charMembers,
        palettes = #paletteMembers,
        cells = #cellMembers,
        animations = #animMembers,
        compressed = compressedCount,
        raw = rawCount,
      },
      entries = entries,
      dependencies = PokedexAssetCompiler.presentationDependencies(),
    }
    provenance.dependencyHash = Hashing.hashLua(provenance)
    provenance.marker = PokedexCache.marker(metadata.sha1, provenance.dependencyHash)
    sink.assets = assets
    sink.provenance = provenance
    sink.dependencyHash = provenance.dependencyHash
    sink.marker = provenance.marker
  end
  return manifest, nil
end

---@param romFs table<string, unknown>
---@return table<string, unknown>
function compileSpinda(romFs)
  local MonPresentationCompiler = require("romdump.src.digest.mons.MonPresentationCompiler")
  local variants, variantsErr = MonPresentationCompiler.portraitVariants(romFs, 327, 0, 2)
  if not variants then
    error(variantsErr, 0)
  end
  local genders, seen = {}, {}
  for _, variant in ipairs(variants) do
    if not variant.shiny and not seen[variant.gender] then
      seen[variant.gender] = true
      genders[#genders + 1] = variant.gender
    end
  end
  if #genders == 0 then
    error("pokedex spinda portrait has no gender variant", 0)
  end
  local eligibility = {}
  local firstPlanes = nil
  for _, gender in ipairs(genders) do
    local indexed, indexedErr = MonPresentationCompiler.compileFrontIndexedFrames(romFs, 327, 0, gender, false)
    if not indexed then
      error(indexedErr, 0)
    end
    local frames = {}
    for _, plane in ipairs(indexed.frames) do
      assert(#plane == 6400, "pokedex spinda plane must cover its 80x80 frame")
      local rows = {}
      for y = 0, 79 do
        local chars = {}
        for x = 0, 79 do
          local value = string.byte(plane, y * 80 + x + 1)
          if value < 0 or value > 15 then
            error("pokedex spinda plane carries an out-of-range index", 0)
          end
          chars[#chars + 1] = value <= 3 and tostring(value) or "0"
        end
        rows[#rows + 1] = table.concat(chars)
      end
      frames[#frames + 1] = rows
    end
    eligibility[gender] = { frames = frames }
    if firstPlanes == nil then
      firstPlanes = indexed.frames[1]
    end
  end
  local normal, normalErr = MonPresentationCompiler.compileFrontIndexedFrames(romFs, 327, 0, genders[1], false)
  if not normal then
    error(normalErr, 0)
  end
  local shiny, shinyErr = MonPresentationCompiler.compileFrontIndexedFrames(romFs, 327, 0, genders[1], true)
  if not shiny then
    error(shinyErr, 0)
  end
  local function replacementColor(indexed, slot)
    local entry = indexed.palette[slot + 7]
    assert(type(entry) == "table", "pokedex spinda palette carries no replacement entry")
    return rgba(entry.r or 0, entry.g or 0, entry.b or 0, 255)
  end

  local replacementColors = {
    normal = { replacementColor(normal, 0), replacementColor(normal, 1), replacementColor(normal, 2) },
    shiny = { replacementColor(shiny, 0), replacementColor(shiny, 1), replacementColor(shiny, 2) },
  }
  -- Four spot arrays: the four largest recolorable clusters of the first
  -- frame excluding the single largest (face/body) cluster.
  local plane = assert(firstPlanes, "pokedex spinda has no reference frame")
  local allowed = { [1] = true, [2] = true, [3] = true }
  local seenPixels, found = {}, {}
  for y = 0, 79 do
    for x = 0, 79 do
      local i = y * 80 + x + 1
      if allowed[string.byte(plane, i)] and not seenPixels[i] then
        local points = {}
        local stack = { i }
        seenPixels[i] = true
        while #stack > 0 do
          local c = table.remove(stack)
          local cx = (c - 1) % 80
          local cy = math.floor((c - 1) / 80)
          points[#points + 1] = { x = cx, y = cy }
          for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
            local nx, ny = cx + d[1], cy + d[2]
            if nx >= 0 and nx < 80 and ny >= 0 and ny < 80 then
              local ni = ny * 80 + nx + 1
              if allowed[string.byte(plane, ni)] and not seenPixels[ni] then
                seenPixels[ni] = true
                stack[#stack + 1] = ni
              end
            end
          end
        end
        found[#found + 1] = points
      end
    end
  end
  table.sort(found, function(left, right)
    return #left > #right
  end)
  if #found < 5 then
    error("pokedex spinda portrait carries no four separable spots", 0)
  end
  local spots = {}
  for index = 2, 5 do
    local points = found[index]
    table.sort(points, function(left, right)
      if left.y == right.y then
        return left.x < right.x
      end
      return left.y < right.y
    end)
    spots[#spots + 1] = points
  end
  return {
    eligibility = eligibility,
    replacementColors = replacementColors,
    spots = spots,
    secondFrameXOffset = -14,
  }
end

---@param romFs table<string, unknown>
---@param versionId string
---@param catalog table<string, unknown>
---@param sink table<string, unknown>?
---@return table<string, unknown>?
---@return Errors.Error?
function PokedexAssetCompiler.compile(romFs, versionId, catalog, sink)
  assert(romFs and romFs.readSourcePath, "compile requires a RomFs-shaped object")
  local ok, manifest = xpcall(_compile, function(err)
    if Errors.is(err) then
      return err
    end
    return { raw = err, trace = debug.traceback("", 2) }
  end, romFs, versionId, catalog, sink)
  if ok then
    return manifest, nil
  end
  if Errors.is(manifest) then
    return nil, manifest --[[@as Errors.Error]]
  end
  if type(manifest) == "table" and manifest.trace then
    error(manifest.raw, 0)
  end
  error(manifest, 0)
end

return PokedexAssetCompiler
