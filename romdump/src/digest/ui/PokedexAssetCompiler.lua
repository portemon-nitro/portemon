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
  ---@type table<integer, { tiles: string, depth: integer, tileCount: integer }>
  local chars = {}
  ---@type table<integer, { r: integer, g: integer, b: integer }[]>
  local palettes = {}
  ---@type table<integer, { cells: table<integer, unknown> }>
  local cellsByMember = {}
  ---@type table<integer, { anims: table<integer, unknown> }>
  local animsByMember = {}
  ---@type table<integer, { width: integer, height: integer, entries: { tile: integer, flipH: boolean, flipV: boolean, palette: integer }[] }>
  local screensByMember = {}
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
      chars[member] = { tiles = char.tiles, depth = char.depth, tileCount = math.floor(#char.tiles / TILE_BYTES) }
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
      screensByMember[member] = decodeKind("decodeScreen", raw, "graphics-screen-" .. member)
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

  -- Exact NSCR rasterization: each screen entry addresses its tile in the
  -- paired NCGR payload (with two-axis flips) and its 16-color bank in
  -- the paired NCLR payload. Index 0 stays transparent; tile overruns,
  -- unknown palette banks and non-4bpp character data fail loudly.

  -- Rendered source art. OBJ tile grids are ordinal-named so no native
  -- member id crosses the runtime boundary; composed BG roles are named
  -- by page family, pane and layer, with content dedup across pages that
  -- share a native triple.
  local chrome = {}
  local charMembers = {}
  for member in pairs(chars) do
    charMembers[#charMembers + 1] = member
  end
  table.sort(charMembers)
  if #charMembers == 0 then
    error("pokedex application archive carries no character pages", 0)
  end
  local charOrdinal = {}
  for ordinal, member in ipairs(charMembers) do
    charOrdinal[member] = ordinal
  end

  ---@param charTiles string
  ---@param tileCount integer
  ---@param paletteColors { r: integer, g: integer, b: integer }[]
  ---@param screen { width: integer, height: integer, entries: { tile: integer, flipH: boolean, flipV: boolean, palette: integer }[] }
  ---@param label string
  ---@return string pixels RGBA bytes
  ---@return integer width
  ---@return integer height
  local function renderScreenMap(charTiles, tileCount, paletteColors, screen, label)
    local tilesWide = math.floor(screen.width / 8)
    for index, entry in ipairs(screen.entries) do
      if entry.tile >= tileCount then
        error("pokedex screen tile overruns its character payload: " .. label .. " entry " .. index, 0)
      end
      if (entry.palette + 1) * 16 > #paletteColors then
        error("pokedex screen palette bank exceeds its palette: " .. label .. " entry " .. index, 0)
      end
    end
    local out = {}
    for row = 0, math.floor(screen.height / 8) - 1 do
      for py = 0, 7 do
        local parts = {}
        for col = 0, tilesWide - 1 do
          for px = 0, 7 do
            local entry = screen.entries[row * tilesWide + col + 1]
            local sx = entry.flipH and (7 - px) or px
            local sy = entry.flipV and (7 - py) or py
            local byte = string.byte(charTiles, entry.tile * TILE_BYTES + sy * 4 + math.floor(sx / 2) + 1)
            local nibble = (sx % 2 == 0) and byte % 16 or math.floor(byte / 16)
            if nibble == 0 then
              parts[#parts + 1] = "\0\0\0\0"
            else
              local color = paletteColors[entry.palette * 16 + nibble + 1]
              parts[#parts + 1] = string.char(color.r, color.g, color.b, 255)
            end
          end
        end
        out[#out + 1] = table.concat(parts)
      end
    end
    return table.concat(out), screen.width, screen.height
  end

  ---@param tileBytes string exactly 32 bytes of 4bpp tile data
  ---@param bank0 { r: integer, g: integer, b: integer }[] sixteen palette colors
  ---@return string pixels RGBA bytes of the 256x192 tile-0 fill
  ---@return integer width
  ---@return integer height
  local function renderTileFill(tileBytes, bank0)
    local rows = {}
    for py = 0, 7 do
      local row = {}
      for px = 0, 7 do
        local byte = string.byte(tileBytes, py * 4 + math.floor(px / 2) + 1)
        local nibble = (px % 2 == 0) and byte % 16 or math.floor(byte / 16)
        if nibble == 0 then
          row[#row + 1] = "\0\0\0\0"
        else
          local color = bank0[nibble + 1]
          row[#row + 1] = string.char(color.r, color.g, color.b, 255)
        end
      end
      rows[#rows + 1] = table.concat(row)
    end
    local out = {}
    for _ = 1, 24 do
      for py = 1, 8 do
        local line = {}
        for _ = 1, 32 do
          line[#line + 1] = rows[py]
        end
        out[#out + 1] = table.concat(line)
      end
    end
    return table.concat(out), 256, 192
  end

  ---@param role string
  ---@param pixels string
  ---@param width integer
  ---@param height integer
  ---@return nil
  local function stageImage(role, pixels, width, height)
    local path = PokedexCache.assetDir() .. "/" .. role .. ".png"
    assets[path] = PngWriter.encode(width, height, pixels)
    chrome[role] = { path = path, width = width, height = height }
  end

  ---@param pageRole string
  ---@return string
  local function pageSlug(pageRole)
    return (pageRole:gsub("%.", "-"))
  end

  local bgRoleByTriple = {}
  local fillRoleByPair = {}

  ---@param pageRole string first page binding this triple, for role naming
  ---@param pane string
  ---@param layer integer
  ---@param charMember integer
  ---@param screenMember integer
  ---@param paletteMember integer
  ---@return string
  local function composedRole(pageRole, pane, layer, charMember, screenMember, paletteMember)
    local key = charMember .. ":" .. screenMember .. ":" .. paletteMember
    local role = bgRoleByTriple[key]
    if role == nil then
      role = "bg-" .. pageSlug(pageRole) .. "-" .. pane .. "-l" .. layer
      local charRecord = chars[charMember]
      if charRecord == nil then
        error("pokedex page references an unknown character member: " .. pageRole, 0)
      end
      if charRecord.depth ~= 3 then
        error("pokedex page character member is not 4bpp: " .. pageRole, 0)
      end
      local screenRecord = screensByMember[screenMember]
      if screenRecord == nil then
        error("pokedex page references an unknown screen member: " .. pageRole, 0)
      end
      local paletteRecord = palettes[paletteMember]
      if paletteRecord == nil then
        error("pokedex page references an unknown palette member: " .. pageRole, 0)
      end
      stageImage(role, renderScreenMap(charRecord.tiles, charRecord.tileCount, paletteRecord, screenRecord, pageRole))
      bgRoleByTriple[key] = role
    end
    return role
  end

  ---@param pageRole string first page binding this fill, for role naming
  ---@param pane string
  ---@param layer integer
  ---@param charMember integer
  ---@param paletteMember integer
  ---@return string
  local function fillRole(pageRole, pane, layer, charMember, paletteMember)
    local key = charMember .. ":" .. paletteMember
    local role = fillRoleByPair[key]
    if role == nil then
      role = "bg-" .. pageSlug(pageRole) .. "-" .. pane .. "-l" .. layer .. "-fill"
      local charRecord = chars[charMember]
      if charRecord == nil or charRecord.depth ~= 3 or charRecord.tileCount < 1 then
        error("pokedex fill references an unusable character member: " .. pageRole, 0)
      end
      local paletteRecord = palettes[paletteMember]
      if paletteRecord == nil or #paletteRecord < 16 then
        error("pokedex fill references an unusable palette member: " .. pageRole, 0)
      end
      local bank0 = {}
      for index = 1, 16 do
        bank0[index] = paletteRecord[index]
      end
      stageImage(role, renderTileFill(charRecord.tiles:sub(1, TILE_BYTES), bank0))
      fillRoleByPair[key] = role
    end
    return role
  end

  -- Stage a source triple under an explicit role without referencing it
  -- from any page: separately selectable variants (such as the
  -- national-mode area map) stay available to later mode-aware selection.
  ---@param role string explicit staged role, referenced by no page
  ---@param charMember integer
  ---@param screenMember integer
  ---@param paletteMember integer
  ---@return nil
  local function stageVariantImage(role, charMember, screenMember, paletteMember)
    local charRecord = chars[charMember]
    if charRecord == nil or charRecord.depth ~= 3 then
      error("pokedex variant references an unusable character member: " .. role, 0)
    end
    local screenRecord = screensByMember[screenMember]
    if screenRecord == nil then
      error("pokedex variant references an unknown screen member: " .. role, 0)
    end
    local paletteRecord = palettes[paletteMember]
    if paletteRecord == nil then
      error("pokedex variant references an unknown palette member: " .. role, 0)
    end
    stageImage(role, renderScreenMap(charRecord.tiles, charRecord.tileCount, paletteRecord, screenRecord, role))
  end

  local function chromeForCell(cellMember, maxTile)
    local bestMember = nil
    for _, member in ipairs(charMembers) do
      if member < cellMember and chars[member].tileCount > maxTile then
        if bestMember == nil or member > bestMember then
          bestMember = member
        end
      end
    end
    if bestMember == nil then
      error("pokedex cell member has no covering character page: " .. cellMember, 0)
    end
    return bestMember
  end

  -- Normalized cells: bounds over OBJ extents, source rects on the
  -- 32-tiles-per-row character layout the chrome renders use. Cell roles
  -- are ordinal-named; each covering tile grid stages through its
  -- explicit OBJ palette (bank 0).
  local cells = {}
  local cellMembers = {}
  for member in pairs(cellsByMember) do
    cellMembers[#cellMembers + 1] = member
  end
  table.sort(cellMembers)
  ---@type table<integer, string[]>
  local cellRolesByMember = {}
  ---@type table<integer, integer>
  local cellOrdinalByMember = {}
  local tilesRoleByChar = {}
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

  for ordinal, member in ipairs(cellMembers) do
    cellOrdinalByMember[member] = ordinal
    local decoded = cellsByMember[member]
    local coverMember = chromeForCell(member, maxTileOf(decoded))
    local tilesRole = tilesRoleByChar[coverMember]
    if tilesRole == nil then
      local paletteMember = PokedexSources.objPalettes[coverMember]
      if paletteMember == nil then
        error("pokedex OBJ character member names no palette: " .. coverMember, 0)
      end
      local paletteRecord = palettes[paletteMember]
      if paletteRecord == nil or #paletteRecord < 16 then
        error("pokedex OBJ palette member is unusable: " .. coverMember, 0)
      end
      local bank0 = {}
      for index = 1, 16 do
        bank0[index] = paletteRecord[index]
      end
      local coverRecord = chars[coverMember]
      tilesRole = string.format("tiles-%02d", charOrdinal[coverMember])
      local pixels, width, height = renderTileGrid(coverRecord.tiles, bank0)
      stageImage(tilesRole, pixels, width, height)
      tilesRoleByChar[coverMember] = tilesRole
    end
    local chromeRecord = chrome[tilesRole]
    local roles = {}
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
          chrome = tilesRole,
          source = source,
          x = obj.x,
          y = obj.y,
          flipX = obj.flipH,
          flipY = obj.flipV,
          priority = obj.priority,
          paletteGroup = "cell",
        }
      end
      local cellRole = string.format("cell-%02d-%d", ordinal, index)
      cells[cellRole] = {
        bounds = { x = x0, y = y0, width = x1 - x0, height = y1 - y0 },
        parts = parts,
      }
      roles[#roles + 1] = cellRole
    end
    cellRolesByMember[member] = roles
  end

  -- Normalized animations: preserved frame order, durations, source
  -- transforms, and one-based loop indices. Ping-pong play modes have no
  -- presentation spelling here and fail rather than mislabeling.
  local animations = {}
  ---@type table<integer, string[]>
  local animRolesByMember = {}
  local animMembers = {}
  for member in pairs(animsByMember) do
    animMembers[#animMembers + 1] = member
  end
  table.sort(animMembers)
  for ordinal, member in ipairs(animMembers) do
    local cellMember = member - 1
    local decoded = cellsByMember[cellMember]
    if decoded == nil then
      error("pokedex animation member has no preceding cell member: " .. member, 0)
    end
    local cellOrdinal = cellOrdinalByMember[cellMember]
    if cellOrdinal == nil then
      error("pokedex animation member has no indexed cell member: " .. member, 0)
    end
    local roles = {}
    for sequence, sequenceRecord in ipairs(animsByMember[member].anims) do
      local frames = {}
      for _, frame in ipairs(sequenceRecord.frames) do
        if frame.cell < 0 or frame.cell >= #decoded.cells then
          error("pokedex animation frame references an unknown cell: member " .. member, 0)
        end
        frames[#frames + 1] = {
          cell = string.format("cell-%02d-%d", cellOrdinal, frame.cell + 1),
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
      local animRole = string.format("anim-%02d-%d", ordinal, sequence)
      animations[animRole] = {
        frames = frames,
        loopFrom = sequenceRecord.loopStartFrameIdx + 1,
        direction = "forward",
        once = once,
      }
      roles[#roles + 1] = animRole
    end
    animRolesByMember[member] = roles
  end
  if #animMembers == 0 then
    error("pokedex application archive carries no animations", 0)
  end

  -- Authored window inventory: the contracted text slots owned by the
  -- producer table, copied verbatim into the generated manifest.
  local windows = {}
  for key, record in pairs(PokedexSources.windows) do
    windows[key] = {
      pane = record.pane,
      layer = record.layer,
      x = record.x,
      y = record.y,
      width = record.width,
      height = record.height,
      font = record.font,
      foreground = rgba(record.foreground.r, record.foreground.g, record.foreground.b, record.foreground.a),
      shadow = rgba(record.shadow.r, record.shadow.g, record.shadow.b, record.shadow.a),
      background = rgba(record.background.r, record.background.g, record.background.b, record.background.a),
      align = record.align,
      paletteGroup = record.paletteGroup,
    }
  end

  -- Page-local sprite roles: one sprite per referenced animation, owned by
  -- its page, so role identities never leak across pages.
  local sprites = {}

  -- Assembled pages: native per-layer backgrounds (composed screens or
  -- exact tile-0 fills), page-owned cell/sprite/window inventories, and
  -- the shared backdrop pair. A layer with no native binding carries an
  -- empty list.
  local isJapanese = catalog.nativeLanguage == "japanese"
  local pages = {}
  -- Page-local (cells, anims, sequence) to sprite role index behind
  -- the semantic subject bindings below.
  local roleByTriple = {}
  for _, role in ipairs(REQUIRED_PAGES) do
    local layerEntries = PokedexSources.pageLayers[role]
    if layerEntries == nil then
      error("pokedex source map misses the " .. role .. " page", 0)
    end
    local objPairs = PokedexSources.pageObjs[role]
    if objPairs == nil then
      error("pokedex OBJ map misses the " .. role .. " page", 0)
    end
    local windowKeys = PokedexSources.pageWindows[role]
    if windowKeys == nil then
      error("pokedex window map misses the " .. role .. " page", 0)
    end
    local backgrounds = { information = {}, controls = {} }
    for _, entry in ipairs(layerEntries) do
      if entry.pane ~= "information" and entry.pane ~= "controls" then
        error("pokedex source map names an unknown pane: " .. role, 0)
      end
      if type(entry.layer) ~= "number" or entry.layer < 0 or entry.layer > 3 then
        error("pokedex source map names an invalid BG layer: " .. role, 0)
      end
      local pagePriority = PokedexSources.pagePriorities[role]
      local panePriority = (pagePriority and pagePriority[entry.pane]) or PokedexSources.bgPriority[entry.pane]
      local priority = panePriority[entry.layer]
      local chromeRole
      if entry.screen == nil then
        chromeRole = fillRole(role, entry.pane, entry.layer, entry.char, entry.palette)
      else
        local screenMember = entry.screen
        if isJapanese and entry.screenJapanese ~= nil then
          screenMember = entry.screenJapanese
        end
        chromeRole = composedRole(role, entry.pane, entry.layer, entry.char, screenMember, entry.palette)
      end
      backgrounds[entry.pane][#backgrounds[entry.pane] + 1] =
        { chrome = chromeRole, layer = entry.layer, x = 0, y = 0, priority = priority, paletteGroup = "chrome" }
      if entry.screen ~= nil and entry.screenNational ~= nil then
        stageVariantImage(
          "bg-" .. pageSlug(role) .. "-" .. entry.pane .. "-l" .. entry.layer .. "-national",
          entry.char,
          entry.screenNational,
          entry.palette
        )
      end
    end
    local pageCells = {}
    local pageSprites = {}
    local tripleRoles = {}
    for _, pair in ipairs(objPairs) do
      local pairCells = cellRolesByMember[pair.cells]
      if pairCells == nil then
        error("pokedex OBJ map references an unknown cell member: " .. role, 0)
      end
      for _, cellRole in ipairs(pairCells) do
        pageCells[#pageCells + 1] = cellRole
      end
      local pairAnims = animRolesByMember[pair.anims]
      if pairAnims == nil then
        error("pokedex OBJ map references an unknown animation member: " .. role, 0)
      end
      local anchors = (PokedexSources.spriteAnchors[role] or {})[pair.anims] or {}
      for seqIndex, animRole in ipairs(pairAnims) do
        local spriteRole = "sprite-" .. pageSlug(role) .. "-" .. (#pageSprites + 1)
        local anchor = anchors[seqIndex]
        local x, y, pane = 0, 0, "information"
        if anchor ~= nil then
          x, y, pane = anchor.x, anchor.y, anchor.pane
        end
        sprites[spriteRole] = {
          pane = pane,
          animation = animRole,
          x = x,
          y = y,
          priority = 0,
          drawPriority = #pageSprites + 1,
          paletteGroup = "sprite",
        }
        pageSprites[#pageSprites + 1] = spriteRole
        tripleRoles[pair.cells .. ":" .. pair.anims .. ":" .. seqIndex] = spriteRole
      end
    end
    roleByTriple[role] = tripleRoles
    for _, key in ipairs(windowKeys) do
      if windows[key] == nil then
        error("pokedex window map references an unknown window: " .. role, 0)
      end
    end
    local pageWindows = {}
    for _, key in ipairs(windowKeys) do
      pageWindows[#pageWindows + 1] = key
    end
    pages[role] = {
      backdrop = { information = rgba(0, 0, 0, 255), controls = rgba(16, 16, 16, 255) },
      backgrounds = backgrounds,
      cells = pageCells,
      sprites = pageSprites,
      windows = pageWindows,
    }
  end

  -- Semantic type and trainer art: per-class tile grids staged under
  -- their source palettes with copied cell geometry, so live type and
  -- trainer subjects resolve through ordinary sprite roles instead of
  -- runtime member arithmetic. The synthesized roles stay out of the
  -- page sprite lists; the subject bindings below are their only
  -- authority, keeping the static page closure demand-driven.
  local synthesizedRoles = {}
  ---@param name string semantic art name behind the role
  ---@param charMember integer source character member behind the tiles
  ---@param paletteColors table<integer, { r: integer, g: integer, b: integer }> sixteen staged palette entries
  ---@param geometryMember integer source cell member behind the copied geometry
  ---@param sequenceRole string source animation role behind the copied timing
  ---@return string tilesRole staged chrome role behind the art
  ---@return table<string, string> copiedCellRoles new cell role per source cell index
  ---@return string copiedAnimRole new animation role carrying the copied timing
  local function synthesizeArt(name, charMember, paletteColors, geometryMember, sequenceRole)
    local charRecord = chars[charMember]
    if charRecord == nil then
      error("pokedex subject art references an unknown character member: " .. charMember, 0)
    end
    if charRecord.depth ~= 3 then
      error("pokedex subject art member is not 4bpp: " .. charMember, 0)
    end
    if #paletteColors < 16 then
      error("pokedex subject art needs a sixteen-color bank: " .. name, 0)
    end
    local tilesRole = name .. "-tiles"
    local pixels, width, height = renderTileGrid(charRecord.tiles, paletteColors)
    stageImage(tilesRole, pixels, width, height)
    local sourceCells = cellRolesByMember[geometryMember]
    if sourceCells == nil then
      error("pokedex subject art references an unknown cell member: " .. geometryMember, 0)
    end
    local sourceAnimation = animations[sequenceRole]
    if sourceAnimation == nil then
      error("pokedex subject art references an unknown animation: " .. sequenceRole, 0)
    end
    local copiedCells = {}
    for index, sourceCellRole in ipairs(sourceCells) do
      local sourceCell = cells[sourceCellRole]
      if sourceCell == nil then
        error("pokedex subject art references an unknown cell: " .. sourceCellRole, 0)
      end
      local copiedRole = name .. "-cell-" .. index
      local parts = {}
      for _, part in ipairs(assert(sourceCell.parts, "subject cells carry their parts")) do
        parts[#parts + 1] = {
          chrome = tilesRole,
          source = part.source,
          x = part.x,
          y = part.y,
          flipX = part.flipX,
          flipY = part.flipY,
          priority = part.priority,
          paletteGroup = part.paletteGroup,
        }
      end
      cells[copiedRole] = { bounds = sourceCell.bounds, parts = parts }
      copiedCells[#copiedCells + 1] = copiedRole
    end
    local copiedBySource = {}
    for index, sourceCellRole in ipairs(sourceCells) do
      copiedBySource[sourceCellRole] = copiedCells[index]
    end
    local copiedFrames = {}
    for _, frame in ipairs(assert(sourceAnimation.frames, "subject animations carry their frames")) do
      copiedFrames[#copiedFrames + 1] = {
        cell = assert(copiedBySource[frame.cell], "subject frames resolve their copied cell"),
        duration = frame.duration,
        offsetX = frame.offsetX,
        offsetY = frame.offsetY,
        rotation = frame.rotation,
        scaleX = frame.scaleX,
        scaleY = frame.scaleY,
      }
    end
    local copiedAnimRole = name .. "-anim"
    animations[copiedAnimRole] = {
      frames = copiedFrames,
      loopFrom = sourceAnimation.loopFrom,
      direction = sourceAnimation.direction,
      once = sourceAnimation.once,
    }
    return tilesRole, copiedCells, copiedAnimRole
  end

  -- One sixteen-color bank from a decoded palette member; type icons
  -- select their source bank while all other staged subject art keeps
  -- the pre-existing bank-0 spelling.
  ---@param member integer source palette member behind the bank
  ---@param bank integer zero-based sixteen-color bank behind the art
  ---@param label string art name behind failure attribution
  ---@return table<integer, { r: integer, g: integer, b: integer }> sixteen staged palette entries
  local function paletteBank(member, bank, label)
    local record = palettes[member]
    if record == nil or #record < (bank + 1) * 16 then
      error("pokedex subject art needs palette bank " .. bank .. " of member " .. member .. ": " .. label, 0)
    end
    local bankEntries = {}
    for index = 1, 16 do
      bankEntries[#bankEntries + 1] = record[bank * 16 + index]
    end
    return bankEntries
  end

  local typeGeometryAnims = animRolesByMember[34]
  if typeGeometryAnims == nil or #typeGeometryAnims ~= 1 then
    error("pokedex type icon geometry needs its single animation sequence", 0)
  end
  local trainerGeometryAnims = animRolesByMember[107]
  if trainerGeometryAnims == nil or #trainerGeometryAnims ~= 1 then
    error("pokedex trainer geometry needs its single animation sequence", 0)
  end
  local typePages = { grid = true, results = true, registration = true }
  for _, typeName in ipairs(PokedexSources.typeOrder) do
    local art = PokedexSources.typeIconArt[typeName]
    if art == nil then
      error("pokedex type icon art misses the " .. typeName .. " class", 0)
    end
    local bank = paletteBank(35, art.paletteBank, typeName)
    local _, _, animRole = synthesizeArt("type-" .. typeName, art.char, bank, 33, typeGeometryAnims[1])
    for pageRole in pairs(typePages) do
      local spriteRole = "sprite-" .. pageSlug(pageRole) .. "-type-" .. typeName
      sprites[spriteRole] = {
        pane = "information",
        animation = animRole,
        x = 0,
        y = 0,
        priority = 0,
        drawPriority = 0,
        paletteGroup = "sprite",
      }
      synthesizedRoles[pageRole] = synthesizedRoles[pageRole] or {}
      for _, subject in ipairs({ "type-1", "type-2" }) do
        synthesizedRoles[pageRole][subject] = synthesizedRoles[pageRole][subject] or {}
        synthesizedRoles[pageRole][subject][typeName] = spriteRole
      end
    end
  end
  for gender, art in pairs(PokedexSources.trainerArt) do
    if gender ~= "male" and gender ~= "female" then
      error("pokedex trainer art names an unknown gender: " .. tostring(gender), 0)
    end
    local bank = paletteBank(art.palette, 0, gender)
    local _, _, animRole = synthesizeArt("trainer-" .. gender, art.char, bank, 106, trainerGeometryAnims[1])
    local spriteRole = "sprite-entry-size-trainer-" .. gender
    sprites[spriteRole] = {
      pane = "information",
      animation = animRole,
      x = 0,
      y = 0,
      priority = 0,
      drawPriority = 0,
      paletteGroup = "sprite",
    }
    synthesizedRoles["entry.size"] = synthesizedRoles["entry.size"] or {}
    synthesizedRoles["entry.size"].trainer = synthesizedRoles["entry.size"].trainer or {}
    synthesizedRoles["entry.size"].trainer[gender] = spriteRole
  end

  -- Semantic subject bindings: every configured subject choice names
  -- its page-local sprite role. Plain entries resolve through the
  -- page-local (cells, anims, sequence) role index; type and trainer
  -- entries resolve through the synthesized role map. Unknown pages,
  -- sequences outside the page closure, and non-semantic entry shapes
  -- abort the whole compilation instead of publishing a dangling map.
  for pageRole, subjects in pairs(PokedexSources.nativeSpriteSubjects) do
    local page = pages[pageRole]
    if page == nil then
      error("pokedex subject map names an unknown page: " .. tostring(pageRole), 0)
    end
    if type(subjects) ~= "table" then
      error("pokedex subject map carries no subjects for page " .. tostring(pageRole), 0)
    end
    local triples = roleByTriple[pageRole]
    if triples == nil then
      error("pokedex subject map names a page without sprite roles: " .. tostring(pageRole), 0)
    end
    local bound = {}
    for subject, choices in pairs(subjects) do
      if type(subject) ~= "string" or subject == "" then
        error("pokedex subject map names no subject on page " .. tostring(pageRole), 0)
      end
      if type(choices) ~= "table" then
        error("pokedex subject map carries no choices for " .. tostring(subject) .. " on " .. tostring(pageRole), 0)
      end
      local boundChoices = {}
      for choice, entry in pairs(choices) do
        if type(choice) ~= "string" or choice == "" then
          error("pokedex subject map names no choice for " .. tostring(subject) .. " on " .. tostring(pageRole), 0)
        end
        if type(entry) ~= "table" then
          error(
            "pokedex subject map carries no binding for "
              .. tostring(subject)
              .. "/"
              .. tostring(choice)
              .. " on "
              .. tostring(pageRole),
            0
          )
        end
        local role, pane
        if entry.typeIcon ~= nil then
          local pageSynthesized = synthesizedRoles[pageRole] or {}
          local subjectSynthesized = pageSynthesized[subject] or {}
          role = subjectSynthesized[entry.typeIcon]
          pane = entry.pane
          if role == nil then
            error(
              "pokedex subject map names an unsynthesized type icon "
                .. tostring(entry.typeIcon)
                .. " for "
                .. tostring(subject)
                .. " on "
                .. tostring(pageRole),
              0
            )
          end
        elseif entry.trainer ~= nil then
          local pageSynthesized = synthesizedRoles[pageRole] or {}
          local subjectSynthesized = pageSynthesized[subject] or {}
          role = subjectSynthesized[entry.trainer]
          pane = entry.pane
          if role == nil then
            error(
              "pokedex subject map names an unsynthesized trainer "
                .. tostring(entry.trainer)
                .. " for "
                .. tostring(subject)
                .. " on "
                .. tostring(pageRole),
              0
            )
          end
        else
          if type(entry.cells) ~= "number" or type(entry.anims) ~= "number" or type(entry.seq) ~= "number" then
            error(
              "pokedex subject map carries no source triple for "
                .. tostring(subject)
                .. "/"
                .. tostring(choice)
                .. " on "
                .. tostring(pageRole),
              0
            )
          end
          role = triples[entry.cells .. ":" .. entry.anims .. ":" .. entry.seq]
          pane = entry.pane
          if role == nil then
            error(
              "pokedex subject map references an unplaced sequence ("
                .. tostring(entry.cells)
                .. "/"
                .. tostring(entry.anims)
                .. "/"
                .. tostring(entry.seq)
                .. ") for "
                .. tostring(subject)
                .. "/"
                .. tostring(choice)
                .. " on "
                .. tostring(pageRole),
              0
            )
          end
        end
        if pane ~= "information" and pane ~= "controls" then
          error(
            "pokedex subject map names an unknown pane for "
              .. tostring(subject)
              .. "/"
              .. tostring(choice)
              .. " on "
              .. tostring(pageRole),
            0
          )
        end
        boundChoices[choice] = { sprite = role, pane = pane }
      end
      bound[subject] = boundChoices
    end
    page.spriteSubjects = bound
  end
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
