-- Compiles the shared type and damage-category icon sprites from the move
-- icon archive: one static realization per semantic key over the shared
-- palette, cell, and animation. Source basis: asm/unk_02077678.s (member
-- and palette-bank selectors) at the audited decomp pin of MoveIconSources.

local Errors = require("libs.errors.src.Errors")
local Hashing = require("romdump.src.digest.Hashing")
local Lz10 = require("romdump.src.digest.Lz10")
local G2dDecoder = require("romdump.src.digest.ui.G2dDecoder")
local G2dRasterizer = require("romdump.src.digest.ui.G2dRasterizer")
local MonSources = require("romdump.src.config.MonSources")
local MoveIconAssetSchema = require("libs.assets.src.MoveIconAssetSchema")
local MoveIconCache = require("libs.assets.src.MoveIconCache")
local MoveIconSources = require("romdump.src.config.MoveIconSources")
local PngWriter = require("libs.assets.src.PngWriter")

local MoveIconAssetCompiler = {}

MoveIconAssetCompiler.ERROR = { SOURCE_INVALID = "MOVE_ICON_SOURCE_INVALID" }

---@noreturn
local function sourceError(message, context)
  Errors.raise(MoveIconAssetCompiler.ERROR.SOURCE_INVALID, "move icons " .. message, context or {})
end

-- Members may be LZ10-packed; the packed marker is the first byte.
local function readMember(archive, memberId, role, dependencies)
  local member, err = archive:readMember(memberId)
  if not member then
    sourceError("member " .. memberId .. " is unreadable: " .. Errors.format(err), { role = role, memberId = memberId })
  end
  assert(member ~= nil, "unreadable members fail above")
  dependencies[#dependencies + 1] =
    { name = "move-icons:member:" .. memberId, role = role, sha1 = Hashing.sha1hex(member) }
  if string.byte(member, 1) == 0x10 then
    local plain, lzErr = Lz10.decode(member)
    if not plain then
      sourceError(role .. " does not unpack: " .. Errors.format(lzErr), { role = role })
    end
    member = plain
  end
  return member
end

local function decode(kind, bytes, role)
  local record, err = G2dDecoder[kind](bytes, { label = "move-icons:" .. role })
  if not record then
    assert(err)
    sourceError(role .. " does not decode: " .. err.message, { role = role, cause = err.code })
  end
  return record
end

local function compileSet(prefix, keys, chars, banks, shared, archive, dependencies, assets)
  local set = {}
  for id = 0, #banks - 1 do
    local key = assert(keys[id], "move icon semantic key is missing")
    local role = prefix .. "-" .. key
    local charData = decode(
      "decodeChar",
      readMember(archive, assert(chars[id], "move icon member is missing"), role, dependencies),
      role
    )
    local sequence = shared.animation.anims[MoveIconSources.shared.frame + 1]
    if sequence == nil or #sequence.frames ~= 1 then
      sourceError(role .. " selects no single-frame animation sequence", { frame = MoveIconSources.shared.frame })
    end
    local ok, rendered = pcall(
      G2dRasterizer.renderAnimationFrame,
      charData,
      shared.palette,
      shared.cell,
      sequence,
      1,
      { role = role, animation = MoveIconSources.shared.frame, frame = 0 },
      banks[id + 1]
    )
    if not ok then
      if Errors.is(rendered) then
        ---@cast rendered Errors.Error
        sourceError(role .. " does not rasterize: " .. rendered.message, { role = role, cause = rendered.code })
      end
      error(rendered, 0)
    end
    local path = MoveIconCache.assetDir() .. "/" .. role .. ".png"
    assets[path] = PngWriter.encode(rendered.width, rendered.height, rendered.pixels)
    local visual = { image = path, width = rendered.width, height = rendered.height }
    if rendered.offset.x ~= 0 or rendered.offset.y ~= 0 then
      visual.offset = { x = rendered.offset.x, y = rendered.offset.y }
    end
    set[key] = visual
  end
  return set
end

---@param romFs RomFs
---@return table<string, unknown>|nil bundle
---@return Errors.Error?
function MoveIconAssetCompiler.compile(romFs)
  assert(romFs and romFs.metadata and romFs.openNarc and romFs.resolvedNarc, "compile requires a RomFs-shaped object")
  local ok, result = xpcall(function()
    local metadata = romFs:metadata()
    local symbol = MoveIconSources.archive.symbol
    local archive, openErr = romFs:openNarc(symbol)
    if not archive then
      sourceError("archive does not open: " .. Errors.format(openErr), { alias = symbol })
    end
    assert(archive ~= nil, "unopenable archives fail above")
    local info = romFs:resolvedNarc(symbol)
    if info == nil then
      sourceError("archive has no resolution", { alias = symbol })
    end
    assert(info ~= nil, "unresolved archives fail above")
    local dependencies = { { name = "assetContract", sha1 = MoveIconCache.FORMAT .. ":" .. MoveIconCache.SCHEMA } }
    local narcBytes = romFs:read(info.fileId)
    if narcBytes == nil then
      sourceError("archive bytes are unavailable", { alias = symbol })
    end
    dependencies[#dependencies + 1] = { name = "narc8:narc", sha1 = Hashing.sha1hex(narcBytes) }
    local facts = MoveIconSources.shared
    local shared = {
      palette = decode("decodePalette", readMember(archive, facts.palette, "palette", dependencies), "palette"),
      cell = decode("decodeCell", readMember(archive, facts.cell, "cell", dependencies), "cell"),
      animation = decode(
        "decodeAnimation",
        readMember(archive, facts.animation, "animation", dependencies),
        "animation"
      ),
    }
    local assets = {}
    local manifest = {
      schema = MoveIconCache.SCHEMA,
      types = compileSet(
        "type",
        MonSources.typeKeys,
        MoveIconSources.typeChars,
        MoveIconSources.typePaletteOverrides,
        shared,
        archive,
        dependencies,
        assets
      ),
      categories = compileSet(
        "category",
        MonSources.damageCategories,
        MoveIconSources.categoryChars,
        MoveIconSources.categoryPaletteOverrides,
        shared,
        archive,
        dependencies,
        assets
      ),
    }
    local valid, schemaErr = pcall(MoveIconAssetSchema.assertManifest, manifest)
    if not valid then
      sourceError("manifest is invalid: " .. Errors.format(schemaErr), {})
    end
    local dependencyHash = Hashing.hashLua(dependencies)
    return {
      manifest = manifest,
      assets = assets,
      provenance = {
        cacheFormat = MoveIconCache.FORMAT,
        schema = MoveIconCache.SCHEMA,
        versionRomSha1 = metadata.sha1,
        dependencyHash = dependencyHash,
        source = { archive = { alias = symbol, narcId = info.narcId, path = info.path } },
        dependencies = dependencies,
      },
      marker = MoveIconCache.marker(metadata.sha1, dependencyHash),
    }
  end, function(e)
    if Errors.is(e) then
      return e
    end
    return { raw = e, trace = debug.traceback("", 2) }
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

return MoveIconAssetCompiler
