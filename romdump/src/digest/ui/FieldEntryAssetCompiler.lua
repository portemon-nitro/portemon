-- Compiles the generated HGSS field-entry class: the nine map-name banner
-- skins from the areawindow archive (source tiles 1..68 composed into a 17x4
-- grid, source-palette transparency preserved, and the decoded text-palette
-- roles published separately) and the distinct location-preview composites
-- selected by the pinned destination/time table (NCLR base, NCGR base+1,
-- NSCR base+2, palette index 0 kept as the opaque MAIN BG2 backdrop, NSCR
-- flips/geometry retained), all as decoded PNG surfaces plus the strict,
-- source-independent manifest. Source member selection lives in
-- romdump/src/config/FieldEntrySources.lua; this module owns the HGSS decode
-- and the normalized bundle. The runtime consumes only the manifest and the
-- generated files, never this module. Pure module: no love dependency.

local Errors = require("libs.errors.src.Errors")
local Hashing = require("romdump.src.digest.Hashing")
local Lz10 = require("romdump.src.digest.Lz10")
local PngWriter = require("libs.assets.src.PngWriter")
local G2dDecoder = require("romdump.src.digest.ui.G2dDecoder")
local G2dRasterizer = require("romdump.src.digest.ui.G2dRasterizer")
local MapCatalog = require("romdump.src.digest.map.MapCatalog")
local FieldEntryAssetCache = require("libs.assets.src.field.FieldEntryAssetCache")
local FieldEntrySources = require("romdump.src.config.FieldEntrySources")

local FieldEntryAssetCompiler = {}

---@alias FieldEntryAssetCompiler.CharData { depth: integer, tiles: string }
---@alias FieldEntryAssetCompiler.PaletteData { colors: { r: integer, g: integer, b: integer }[] }
---@alias FieldEntryAssetCompiler.ScreenData { width: integer, height: integer, entries: table[] }

-- Named ownership of the compiler protocol error codes; tests assert the
-- constant, never the raw string.
FieldEntryAssetCompiler.ERROR = {
  SOURCE_INVALID = "FIELD_ENTRY_SOURCE_INVALID",
}

---@generic T
---@param value T?
---@param err unknown?
---@return T
local function must(value, err)
  if value == nil then
    if err ~= nil then
      error(err, 0)
    end
    Errors.raise(FieldEntryAssetCompiler.ERROR.SOURCE_INVALID, "expected a decoded source value", {})
  end
  return value
end

---@param message string
---@param context Errors.Context?
---@return Errors.Error
local function sourceError(message, context)
  return Errors.new(FieldEntryAssetCompiler.ERROR.SOURCE_INVALID, message, context)
end

-- Decode a member that may be LZ10-wrapped. A missing member and a damaged
-- LZ10 stream are distinct typed source diagnostics.
---@param archive Narc
---@param memberId integer
---@param label string
---@return string
local function decodeMember(archive, memberId, label)
  local bytes = must(
    archive:readMember(memberId),
    sourceError("missing field-entry source member", { member = memberId, label = label })
  )
  if string.byte(bytes, 1) == 0x10 then
    local plain, lzErr = Lz10.decode(bytes)
    if not plain then
      error(lzErr, 0)
    end
    bytes = plain
  end
  return bytes
end

-- Resolve, open, and read one source archive; its whole-file hash is one
-- producer dependency. A missing alias/archive/member is a typed source
-- defect, never a silently smaller asset set.
---@param romFs RomFs
---@param alias string
---@return Narc
---@return string archiveBytes
local function loadArchive(romFs, alias)
  local info = must(romFs:resolvedNarc(alias), sourceError("unresolved field-entry NARC alias", { alias = alias }))
  local archive = must(romFs:openNarc(alias), sourceError("failed to open field-entry NARC", { alias = alias }))
  local archiveBytes =
    must(romFs:read(info.fileId), sourceError("missing field-entry archive bytes", { alias = alias }))
  return archive, archiveBytes
end

-- The banner composes source tiles 1..68 as a 17x4 grid in palette bank 0
-- with no flips, matching the retail copy from the NCGR tile run. Grid cell
-- `k` addresses source tile `k + 1`; tile 0 is never drawn.
---@return table[]
local function bannerEntries()
  local entries = {}
  for index = 1, (FieldEntryAssetCache.BANNER_WIDTH / 8) * (FieldEntryAssetCache.BANNER_HEIGHT / 8) do
    entries[index] = { tile = index, palette = 0, flipH = false, flipV = false }
  end
  return entries
end

---@param paletteData FieldEntryAssetCompiler.PaletteData
---@param paletteMember integer
---@return FieldEntryAssetCache.BannerTextPalette
local function textPalette(paletteData, paletteMember)
  -- The source window text roles are palette index 1 (font foreground),
  -- index 2 (shadow), and index 0 (background). A palette the decoded data
  -- cannot cover is malformed source, never a silent default color.
  local missing = sourceError("the banner palette must cover the text roles", {
    member = paletteMember,
    available = #paletteData.colors,
  })
  local foreground = must(paletteData.colors[2], missing)
  local shadow = must(paletteData.colors[3], missing)
  local background = must(paletteData.colors[1], missing)
  return {
    foreground = { r = foreground.r, g = foreground.g, b = foreground.b },
    shadow = { r = shadow.r, g = shadow.g, b = shadow.b },
    background = { r = background.r, g = background.g, b = background.b },
  }
end

-- The 1-based source area icon selects banner graphic `areaIcon - 1`, but only
-- where retail would draw the area-name banner at all. `bannerStyleByMapId`
-- mirrors that eligibility so the runtime banner controller gates on
-- membership alone. Source: the retail ROM's in-building check (map types INTERIOR and
-- POKEMON_CENTER) and map-name animation.
local function bannerStyleFor(record)
  if record.mapType == "INTERIOR" or record.mapType == "POKEMON_CENTER" then
    return nil
  end
  local areaIcon = record.areaIcon
  if type(areaIcon) == "number" and areaIcon >= 1 and areaIcon <= FieldEntrySources.BANNER_STYLE_COUNT then
    return areaIcon - 1
  end
  return nil
end

local function compileAll(romFs, sha1hex, hashLua)
  local assets = {}
  local manifestAssets = {}
  local deps = {
    { name = "assetContract", sha1 = FieldEntryAssetCache.FORMAT .. ":" .. FieldEntryAssetCache.SCHEMA },
  }

  local areaArchive, areaBytes = loadArchive(romFs, FieldEntrySources.AREA_WINDOWS_ALIAS)
  deps[#deps + 1] = { name = FieldEntrySources.AREA_WINDOWS_ALIAS .. ":narc", sha1 = sha1hex(areaBytes) }

  local bannerStyles = {}
  local bannerTextPalettes = {}
  local bannerScreen = {
    width = FieldEntryAssetCache.BANNER_WIDTH,
    height = FieldEntryAssetCache.BANNER_HEIGHT,
    entries = bannerEntries(),
  }
  for style = 0, FieldEntrySources.BANNER_STYLE_COUNT - 1 do
    local charMember, paletteMember = FieldEntrySources.bannerMemberIds(style)
    local charBytes = decodeMember(areaArchive, charMember, "banner char")
    local paletteBytes = decodeMember(areaArchive, paletteMember, "banner palette")
    local decodedChar, charErr = G2dDecoder.decodeChar(charBytes, { label = "banner char" })
    local charData = must(decodedChar, charErr) --[[@as FieldEntryAssetCompiler.CharData]]
    local decodedPalette, paletteErr = G2dDecoder.decodePalette(paletteBytes, { label = "banner palette" })
    local paletteData = must(decodedPalette, paletteErr) --[[@as FieldEntryAssetCompiler.PaletteData]]
    local image = G2dRasterizer.renderScreen(charData, { colors = paletteData.colors }, bannerScreen, {
      asset = "banner",
      member = charMember,
    })
    local key = "banner/" .. style
    local path = FieldEntryAssetCache.assetDir() .. "/banner-" .. style .. ".png"
    assets[path] = PngWriter.encode(image.width, image.height, image.pixels)
    manifestAssets[key] = { image = path, width = image.width, height = image.height }
    bannerStyles[style] = key
    bannerTextPalettes[style] = textPalette(paletteData, paletteMember)
    deps[#deps + 1] =
      { name = FieldEntrySources.AREA_WINDOWS_ALIAS .. ":member:" .. charMember, sha1 = sha1hex(charBytes) }
    deps[#deps + 1] = {
      name = FieldEntrySources.AREA_WINDOWS_ALIAS .. ":member:" .. paletteMember,
      sha1 = sha1hex(paletteBytes),
    }
  end

  local previewArchive, previewBytes = loadArchive(romFs, FieldEntrySources.PREVIEWS_ALIAS)
  deps[#deps + 1] = { name = FieldEntrySources.PREVIEWS_ALIAS .. ":narc", sha1 = sha1hex(previewBytes) }

  -- One semantic preview key and one PNG per distinct source triple base. The
  -- ordinal is the position of the base in the ascending selected set, so
  -- duplicated time slots and shared map headers reuse one image.
  local ordinalByBase = {}
  for position, base in ipairs(FieldEntrySources.uniqueBases()) do
    local ordinal = position - 1
    ordinalByBase[base] = ordinal
    local paletteBytes = decodeMember(previewArchive, base, "preview palette")
    local charBytes = decodeMember(previewArchive, base + 1, "preview char")
    local screenBytes = decodeMember(previewArchive, base + 2, "preview screen")
    local decodedPalette, paletteErr = G2dDecoder.decodePalette(paletteBytes, { label = "preview palette" })
    local paletteData = must(decodedPalette, paletteErr) --[[@as FieldEntryAssetCompiler.PaletteData]]
    local decodedChar, charErr = G2dDecoder.decodeChar(charBytes, { label = "preview char" })
    local charData = must(decodedChar, charErr) --[[@as FieldEntryAssetCompiler.CharData]]
    local decodedScreen, screenErr = G2dDecoder.decodeScreen(screenBytes, { label = "preview screen" })
    local screen = must(decodedScreen, screenErr) --[[@as FieldEntryAssetCompiler.ScreenData]]
    local image = G2dRasterizer.renderScreen(
      charData,
      { colors = paletteData.colors },
      screen,
      { asset = "preview", member = base + 2 },
      { backdrop = true }
    )
    local key = "preview/" .. ordinal
    local path = FieldEntryAssetCache.assetDir() .. "/preview-" .. ordinal .. ".png"
    assets[path] = PngWriter.encode(image.width, image.height, image.pixels)
    manifestAssets[key] = { image = path, width = image.width, height = image.height }
    deps[#deps + 1] = { name = FieldEntrySources.PREVIEWS_ALIAS .. ":member:" .. base, sha1 = sha1hex(paletteBytes) }
    deps[#deps + 1] = {
      name = FieldEntrySources.PREVIEWS_ALIAS .. ":member:" .. (base + 1),
      sha1 = sha1hex(charBytes),
    }
    deps[#deps + 1] = {
      name = FieldEntrySources.PREVIEWS_ALIAS .. ":member:" .. (base + 2),
      sha1 = sha1hex(screenBytes),
    }
  end

  local previewByMapId = {}
  for _, destination in ipairs(FieldEntrySources.DESTINATIONS) do
    local mapId = MapCatalog.idForSymbol(destination.symbol)
    assert(mapId ~= nil, "field-entry destination is not in the map catalog: " .. destination.symbol)
    local slots = {}
    for slot = 0, FieldEntryAssetCache.PREVIEW_SLOTS - 1 do
      local base = destination.bases[slot + 1]
      local ordinal = ordinalByBase[base]
      assert(ordinal ~= nil, "field-entry preview base is not selected: " .. tostring(base))
      slots[slot] = "preview/" .. ordinal
    end
    previewByMapId[mapId] = slots
  end

  local bannerStyleByMapId = {}
  for record in MapCatalog.all() do
    local style = bannerStyleFor(record)
    if style ~= nil then
      bannerStyleByMapId[record.id] = style
    end
  end

  local manifest = {
    schema = FieldEntryAssetCache.SCHEMA,
    reference = { width = FieldEntryAssetCache.PREVIEW_WIDTH, height = FieldEntryAssetCache.PREVIEW_HEIGHT },
    assets = manifestAssets,
    bannerStyles = bannerStyles,
    bannerTextPalettes = bannerTextPalettes,
    bannerStyleByMapId = bannerStyleByMapId,
    previewByMapId = previewByMapId,
  }
  local ok, err = FieldEntryAssetCache.validateManifest(manifest)
  if not ok then
    error(err, 0)
  end
  local marker = FieldEntryAssetCache.marker(romFs:metadata().sha1, hashLua(deps))
  return {
    marker = marker,
    manifest = manifest,
    assets = assets,
    dependencies = deps,
  }
end

---@param romFs RomFs
---@param sha1hex? fun(bytes: string): string|nil
---@param hashLua? fun(value: unknown): string|nil
---@return table<string, unknown>|nil bundle
---@return Errors.Error?
function FieldEntryAssetCompiler.compile(romFs, sha1hex, hashLua)
  assert(romFs and romFs.read and romFs.openNarc and romFs.resolvedNarc, "compile requires a RomFs-shaped object")
  sha1hex = sha1hex or Hashing.sha1hex
  hashLua = hashLua or Hashing.hashLua
  local ok, result = xpcall(compileAll, function(e)
    if Errors.is(e) then
      return e
    end
    return { raw = e, trace = debug.traceback("", 2) }
  end, romFs, sha1hex, hashLua)
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

return FieldEntryAssetCompiler
