-- Compiles the generated HGSS field-move cut-in banner class: the BG3
-- banner surface of the move cut-in, selected per edition (HeartGold
-- members 0/1/2, SoulSilver members 3/4/5) from the choose_starter_sub_res
-- archive. Source member selection lives in
-- romdump/src/config/FieldMoveCutInBannerSources.lua; this module owns the
-- HGSS decode and the normalized bundle. The retail loader places the
-- sixteen NCLR colors at hardware BG palette slot 12 and rewrites the whole
-- 32x32 tilemap to that slot, so every NSCR entry renders through the
-- loaded bank 0 here; source-zero pixels stay transparent per the hardware
-- text-layer role. The runtime consumes only the manifest and the generated
-- file, never this module. Pure module: no love dependency.

local Errors = require("libs.errors.src.Errors")
local Hashing = require("romdump.src.digest.Hashing")
local Lz10 = require("romdump.src.digest.Lz10")
local PngWriter = require("romdump.src.digest.PngEncoder")
local G2dDecoder = require("romdump.src.digest.ui.G2dDecoder")
local G2dRasterizer = require("romdump.src.digest.ui.G2dRasterizer")
local FieldMoveCutInBannerAssetCache = require("libs.assets.src.field.FieldMoveCutInBannerAssetCache")
local BannerSources = require("romdump.src.config.FieldMoveCutInBannerSources")

local FieldMoveCutInBannerCompiler = {}

---@alias FieldMoveCutInBannerCompiler.CharData { depth: integer, tiles: string }
---@alias FieldMoveCutInBannerCompiler.PaletteData { colors: { r: integer, g: integer, b: integer }[] }
---@alias FieldMoveCutInBannerCompiler.ScreenData { width: integer, height: integer, entries: table[] }

-- Named ownership of the compiler protocol error codes; tests assert the
-- constant, never the raw string.
FieldMoveCutInBannerCompiler.ERROR = {
  SOURCE_INVALID = "FIELD_MOVE_CUT_IN_BANNER_SOURCE_INVALID",
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
    Errors.raise(FieldMoveCutInBannerCompiler.ERROR.SOURCE_INVALID, "expected a decoded source value", {})
  end
  return value
end

---@param message string
---@param context Errors.Context?
---@return Errors.Error
local function sourceError(message, context)
  return Errors.new(FieldMoveCutInBannerCompiler.ERROR.SOURCE_INVALID, message, context)
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
    sourceError("missing cut-in banner source member", { member = memberId, label = label })
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
  local info = must(romFs:resolvedNarc(alias), sourceError("unresolved cut-in banner NARC alias", { alias = alias }))
  local archive = must(romFs:openNarc(alias), sourceError("failed to open cut-in banner NARC", { alias = alias }))
  local archiveBytes =
    must(romFs:read(info.fileId), sourceError("missing cut-in banner archive bytes", { alias = alias }))
  return archive, archiveBytes
end

local function compileAll(romFs, sha1hex, hashLua)
  local versionId = must(romFs:version(), sourceError("cut-in banner compilation requires a game version", {}))
  local members = BannerSources.bannerMembers(versionId)
  local assets = {}
  local deps = {
    {
      name = "assetContract",
      sha1 = FieldMoveCutInBannerAssetCache.FORMAT .. ":" .. FieldMoveCutInBannerAssetCache.SCHEMA,
    },
  }

  local archive, archiveBytes = loadArchive(romFs, BannerSources.ARCHIVE_ALIAS)
  deps[#deps + 1] = { name = BannerSources.ARCHIVE_ALIAS .. ":narc", sha1 = sha1hex(archiveBytes) }

  local charBytes = decodeMember(archive, members.char, "banner char")
  local screenBytes = decodeMember(archive, members.screen, "banner screen")
  local paletteBytes = decodeMember(archive, members.palette, "banner palette")
  deps[#deps + 1] = {
    archive = BannerSources.ARCHIVE_ALIAS,
    memberId = members.char,
    role = "banner-char",
    sha1 = sha1hex(charBytes),
  }
  deps[#deps + 1] = {
    archive = BannerSources.ARCHIVE_ALIAS,
    memberId = members.screen,
    role = "banner-screen",
    sha1 = sha1hex(screenBytes),
  }
  deps[#deps + 1] = {
    archive = BannerSources.ARCHIVE_ALIAS,
    memberId = members.palette,
    role = "banner-palette",
    sha1 = sha1hex(paletteBytes),
  }

  local decodedChar, charErr = G2dDecoder.decodeChar(charBytes, { label = "cut-in banner char" })
  local charData = must(decodedChar, charErr) --[[@as FieldMoveCutInBannerCompiler.CharData]]
  if charData.depth ~= 3 then
    error(
      sourceError("the cut-in banner char bank must be 4bpp tiles", {
        member = members.char,
        depth = charData.depth,
      }),
      0
    )
  end
  local decodedScreen, screenErr = G2dDecoder.decodeScreen(screenBytes, { label = "cut-in banner screen" })
  local screenData = must(decodedScreen, screenErr) --[[@as FieldMoveCutInBannerCompiler.ScreenData]]
  if screenData.width ~= BannerSources.BANNER_WIDTH or screenData.height ~= BannerSources.BANNER_HEIGHT then
    error(
      sourceError("the cut-in banner tilemap must cover the 32x32 BG3 tilemap", {
        member = members.screen,
        width = screenData.width,
        height = screenData.height,
      }),
      0
    )
  end
  local decodedPalette, paletteErr = G2dDecoder.decodePalette(paletteBytes, { label = "cut-in banner palette" })
  local paletteData = must(decodedPalette, paletteErr) --[[@as FieldMoveCutInBannerCompiler.PaletteData]]
  if #paletteData.colors < 16 then
    error(
      sourceError("the cut-in banner palette must carry sixteen colors", {
        member = members.palette,
        colors = #paletteData.colors,
      }),
      0
    )
  end
  local bankColors = {}
  for slot = 1, 16 do
    bankColors[slot] = paletteData.colors[slot]
  end

  -- Retail rewrites the whole tilemap to hardware palette slot 12 after
  -- loading the sixteen NCLR colors there, so the stored per-entry palette
  -- numbers never reach the display: every entry renders through the loaded
  -- bank 0 here.
  local entries = {}
  for index, entry in ipairs(screenData.entries) do
    entries[index] = { tile = entry.tile, palette = 0, flipH = entry.flipH, flipV = entry.flipV }
  end
  local image = G2dRasterizer.renderScreen(charData, { colors = bankColors }, {
    width = screenData.width,
    height = screenData.height,
    entries = entries,
  }, {
    asset = "cut-in banner",
    member = members.screen,
  })

  local path = FieldMoveCutInBannerAssetCache.assetDir() .. "/banner.png"
  assets[path] = PngWriter.encode(image.width, image.height, image.pixels)

  local manifest = {
    schema = FieldMoveCutInBannerAssetCache.SCHEMA,
    reference = { width = BannerSources.BANNER_WIDTH, height = BannerSources.BANNER_HEIGHT },
    assets = {
      banner = { image = path, width = image.width, height = image.height },
    },
    banner = "banner",
    paletteSlot = BannerSources.PALETTE_SLOT,
  }
  local ok, err = FieldMoveCutInBannerAssetCache.validateManifest(manifest)
  if not ok then
    error(err, 0)
  end
  local marker = FieldMoveCutInBannerAssetCache.marker(romFs:metadata().sha1, hashLua(deps))
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
function FieldMoveCutInBannerCompiler.compile(romFs, sha1hex, hashLua)
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

return FieldMoveCutInBannerCompiler
