-- ROM-backed material compilation keeps native texture-bank identities and
-- alpha classification: one source texture pack persists as one named bank of
-- compact texels and palettes, and the bank decodes to the same pixels the
-- source pack does.

local Assert = require("tests.support.Assert")
local ffi = require("ffi")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local NativeTextureBank = require("libs.assets.src.model.NativeTextureBank")
local AreaData = require("romdump.src.digest.map.AreaData")
local MapAssetCompiler = require("romdump.src.digest.map.MapAssetCompiler")
local MapResolver = require("romdump.src.digest.map.MapResolver")
local LandData = require("romdump.src.digest.map.LandData")
local Nsbmd = require("libs.nds.src.nitro.g3d.Nsbmd")
local Nsbtx = require("libs.nds.src.nitro.g3d.Nsbtx")
local TextureDecoder = require("libs.nds.src.gx.TextureDecoder")
local RomSuite = require("tests.rom.support.RomSuite")

local T = {}

local function readMember(romFs, archive, memberId)
  return assert(romFs:openNarc(archive):readMember(memberId))
end

local function sourceMaterial(romFs)
  local resolved = assert(MapResolver.resolve(romFs, "MAP_NEW_BARK"))
  local area = assert(AreaData.decode(readMember(romFs, "area_data", resolved.areaDataMemberId)))
  local land = assert(LandData.decode(readMember(romFs, "land_data", resolved.landDataMemberId)))
  local model = assert(Nsbmd.decode(land.mapModelBytes)).models[1]
  local pack = assert(Nsbtx.decode(readMember(romFs, "map_textures", area.mapTexturePackId)))

  for index, material in ipairs(model.materials) do
    local texture = material.textureName and pack.textureByName[material.textureName] or nil
    local palette = material.paletteName and pack.paletteByName[material.paletteName] or nil
    if texture and palette and texture.formatRaw >= 1 and texture.formatRaw <= 6 then
      return index, material, texture, palette, pack
    end
  end
  error("New Bark Town has no indexed map material", 0)
end

local function bankKey(path)
  local prefix = "assets/generated/maps/texture-banks/"
  local suffix = ".g4tx"
  Assert.isTrue(path:sub(1, #prefix) == prefix, "map material uses the generated texture-bank root")
  Assert.isTrue(path:sub(-#suffix) == suffix, "map material selects a native texture bank")
  return path:sub(#prefix + 1, -#suffix - 1)
end

-- The RGBA pixels one named texel/palette pairing inside a bank decodes to.
local function bankPixels(bytes, textureName, paletteName)
  local bank = assert(NativeTextureBank.read(bytes))
  local texture = assert(bank:texture(textureName), "the bank holds the bound texture")
  local palette = assert(bank:palette(paletteName), "the bank holds the bound palette")
  return TextureDecoder.decode({
    format = texture.formatRaw,
    width = texture.width,
    height = texture.height,
    color0Transparent = texture.color0Transparent,
    texel = texture.texels,
    indexData = texture.indexData,
    palette = palette.data,
  })
end

function T.map_material_bundle_carries_final_texture_bank(romFs)
  local bundle = assert(MapAssetCompiler.compile(romFs, "MAP_NEW_BARK"))
  local materialIndex, _, texture, palette, pack = sourceMaterial(romFs)
  local sceneMaterial = assert(bundle.scene.materials[materialIndex])
  Assert.equal(type(sceneMaterial.texture), "table", "the scene material binds a native texture bank selector")
  local file = assert(sceneMaterial.texture.file, "the selector names the bank file")
  local key = bankKey(file)
  Assert.equal(#key, 40, "texture bank identity remains a content key")
  Assert.equal(file, MapAssetCache.textureBankPath(key), "the scene points at the content-addressed bank")
  Assert.equal(sceneMaterial.texture.textureName, texture.name, "the selector keeps the source texture name")
  Assert.equal(sceneMaterial.texture.paletteName, palette.name, "the selector keeps the source palette name")

  local bytes = assert(bundle.textures[key], "the compiled map bundle carries the referenced texture bank")
  Assert.equal(type(bytes), "string", "the cache bundle carries the bank bytes")
  Assert.isTrue(bytes:sub(1, 4) == NativeTextureBank.MAGIC, "the bound texture is a native bank, not a PNG")

  local actual = bankPixels(bytes, texture.name, palette.name)
  local reference = TextureDecoder.decode(Nsbtx.decoderOpts(pack, texture, palette))
  Assert.equal(actual.width, reference.width, "the bank keeps the source texture width")
  Assert.equal(actual.height, reference.height, "the bank keeps the source texture height")
  Assert.equal(
    ffi.string(actual.pixels, #actual.pixels),
    ffi.string(reference.pixels, #reference.pixels),
    "the bank decodes to the same pixels the source pack does"
  )
  Assert.deepEqual(sceneMaterial.alphaUsage, reference.alphaUsage, "material alpha classification remains unchanged")
end

local suite = RomSuite.fromFacts(T)
suite.metadata.capabilities = { "rom_dump" }
suite.metadata.tags = { "producer", "material", "texture" }
return suite
