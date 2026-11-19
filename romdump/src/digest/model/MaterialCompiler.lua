-- Compiles a model's materials into normalized render records and binds each
-- referenced texture to its source texture pack's named native texture bank.
-- Texture/palette names are matched exactly against the supplied pack (an area
-- texture pack or a model's embedded TEX0). A name the pack does not define
-- yields an untextured material, listed in `unresolved` for the caller to
-- report: no HGSS material stores a texture format or address of its own --
-- every one is zero until a successful bind writes it -- so Nitro's name-based
-- bind failing leaves the DS drawing that material with no texture at all. A
-- visible texture is the selected texture name plus palette name against one
-- immutable bank, so the same texels serve every palette without an expanded
-- image per pairing. Pure domain module.

local Hashing = require("romdump.src.digest.Hashing")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local NativeTextureBank = require("libs.assets.src.model.NativeTextureBank")
local Nsbtx = require("libs.nds.src.nitro.g3d.Nsbtx")
local TextureDecoder = require("libs.nds.src.gx.TextureDecoder")

local MaterialCompiler = {}

-- Bumped whenever the decode or the staged bank presentation changes in a
-- cache-breaking way; part of the content-addressed bank identity so the model
-- cache invalidates.
local DECODER_VERSION = "texdec-v3"

-- A palette record carries the bytes a decoder may index for any format, so
-- the slice is bounded by the largest palette a DS format can select and by
-- the source palette block itself.
local MAX_PALETTE_BYTES = 256 * 2

-- Derived, immutable facts about one decoded pack: its encoded bank and the
-- alpha usage of the texture/palette pairings materials bind. Keyed by the
-- pack table the caller already owns, so a pack is encoded once however many
-- materials, variants, or terrain swaps resolve against it.
local packFacts = setmetatable({}, { __mode = "k" })

local function paletteSlice(pack, palette)
  local bytes = pack.bytes
  local blockEnd = pack.offsets and pack.offsets.plttDataEnd or #bytes
  local start = palette.dataAbsolute + 1
  local stop = math.min(palette.dataAbsolute + MAX_PALETTE_BYTES, blockEnd)
  if stop < start then
    stop = start - 1
  end
  return bytes:sub(start, stop)
end

---@param pack table<string, unknown>
---@return { key: string, bytes: string }
local function bankFor(pack)
  local facts = packFacts[pack]
  if facts ~= nil then
    return facts.bank
  end
  local textures, palettes = {}, {}
  for _, texture in
    ipairs(pack.textures --[[@as table[] ]])
  do
    local record = {
      name = texture.name,
      formatRaw = texture.formatRaw,
      width = texture.width,
      height = texture.height,
      color0Transparent = texture.color0Transparent,
      texels = assert(pack.bytes):sub(texture.dataAbsolute + 1, texture.dataAbsolute + texture.dataSize),
    }
    if texture.formatRaw == 5 then
      local length = math.floor(texture.dataSize / 2)
      record.indexData = assert(pack.bytes):sub(texture.compressedInfoOffset + 1, texture.compressedInfoOffset + length)
    end
    textures[#textures + 1] = record
  end
  for _, palette in
    ipairs(pack.palettes --[[@as table[] ]])
  do
    palettes[#palettes + 1] = { name = palette.name, data = paletteSlice(pack, palette) }
  end
  local bytes = NativeTextureBank.encode({ textures = textures, palettes = palettes })
  local bank = { key = Hashing.sha1hex(DECODER_VERSION .. bytes), bytes = bytes }
  packFacts[pack] = { bank = bank, alphaByPair = {} }
  return bank
end

-- Alpha usage of one resolved texture/palette pairing: the same RGBA scan the
-- material classifier always consumed, decoded transiently so no expanded
-- image is persisted.
---@param pack table<string, unknown>
---@param texture table<string, unknown>
---@param palette table<string, unknown>|nil
---@return { hasOpaque: boolean, hasZero: boolean, hasPartial: boolean }
local function alphaUsageFor(pack, texture, palette)
  local facts = packFacts[pack]
  local pairKey = tostring(texture.name) .. "\0" .. tostring(palette and palette.name or "")
  local cached = facts.alphaByPair[pairKey]
  if cached ~= nil then
    return cached
  end
  local decoderOpts = Nsbtx.decoderOpts(pack, texture, palette)
  local scratch = TextureDecoder.newScratch()
  local rgba = love.data.newByteData(texture.width * texture.height * 4)
  local pointer = assert(rgba:getFFIPointer(), "texture RGBA Data has no FFI pointer")
  local size = rgba:getSize()
  ---@cast size integer
  local usage = TextureDecoder.decodeInto(decoderOpts, pointer, size, scratch, { name = texture.name })
  facts.alphaByPair[pairKey] = usage
  return usage
end

-- Paletted formats require a palette; direct color (7) and none (0) do not.
local function needsPalette(formatRaw)
  return formatRaw >= 1 and formatRaw <= 6
end

local function wrapMode(repeats)
  return repeats and "repeat" or "clamp"
end

-- "building_textures member 7" -- names the resource that was actually searched,
-- so a miss is attributable without re-running the audit.
local function describeSource(context)
  if not (context and context.textureArchive) then
    return "the supplied pack"
  end
  if not context.textureMemberId then
    return context.textureArchive
  end
  return context.textureArchive .. " member " .. context.textureMemberId
end

-- Resolve one (textureName, paletteName) bind against `pack` and bind it into
-- the shared texture-bank accumulator. Returns the record fields
-- { texture = selector, textureFormat, texWidth, texHeight, alphaUsage } with
-- texture nil when the bind fails (the pack does not define the name, or a
-- paletted texture's palette is missing); such failures also append to
-- `unresolved` when that table is supplied. Shared by the model material
-- compile and the NSBTP variant resolution (which binds against the model's
-- embedded TEX0).
function MaterialCompiler.resolveTexture(mat, pack, textures, unresolved, opts)
  opts = opts or {}
  local record = { texture = nil }
  local tex = mat.textureName and pack.textureByName[mat.textureName] or nil
  local pal
  if mat.textureName and not tex then
    if unresolved then
      unresolved[#unresolved + 1] =
        { material = mat.name, kind = "texture", name = mat.textureName, source = describeSource(opts.context) }
    end
  elseif tex and needsPalette(tex.formatRaw) then
    pal = mat.paletteName and pack.paletteByName[mat.paletteName] or nil
    if not pal then
      if unresolved then
        unresolved[#unresolved + 1] = {
          material = mat.name,
          kind = "palette",
          name = mat.paletteName,
          source = describeSource(opts.context),
        }
      end
      tex = nil
    end
  end

  if tex then
    local bank = bankFor(pack)
    textures[bank.key] = bank.bytes
    record.texture = {
      file = MapAssetCache.textureBankPath(bank.key),
      textureName = tex.name,
      paletteName = pal and pal.name or nil,
    }
    record.textureFormat = tex.formatRaw
    -- DS texcoords are in texel units; the geometry step divides by these to
    -- normalize UVs to [0,1]. Not serialized into the scene material.
    record.texWidth = tex.width
    record.texHeight = tex.height
    record.alphaUsage = alphaUsageFor(pack, tex, pal)
  end
  return record
end

-- Bind one derived texture payload -- a source texture's format and extent
-- carrying substitute texel/index bytes under one palette -- into the shared
-- texture-bank accumulator and return its selector. Terrain texture animation
-- steps are exactly this: the base texture's register state with a replacement
-- frame's texels, so the step resolves through one bank like any other
-- material instead of an expanded image per frame.
---@param texture table<string, unknown> source texture whose format/extent the payload keeps
---@param texels string replacement texel bytes
---@param indexData string|nil replacement 4x4 index region
---@param paletteName string|nil
---@param paletteData string|nil
---@param textures table<string, string> texture-bank accumulator: bank key to encoded bytes
---@return ModelAsset.TextureReference texture selector
function MaterialCompiler.derivedTextureBank(texture, texels, indexData, paletteName, paletteData, textures)
  local palettes = {}
  if paletteName ~= nil then
    palettes[1] = { name = paletteName, data = assert(paletteData) }
  end
  local bytes = NativeTextureBank.encode({
    textures = {
      {
        name = texture.name,
        formatRaw = texture.formatRaw,
        width = texture.width,
        height = texture.height,
        color0Transparent = texture.color0Transparent,
        texels = texels,
        indexData = indexData,
      },
    },
    palettes = palettes,
  })
  local key = Hashing.sha1hex(DECODER_VERSION .. bytes)
  textures[key] = bytes
  return {
    file = MapAssetCache.textureBankPath(key),
    textureName = texture.name,
    paletteName = paletteName,
  }
end

-- materials: list of { index, name, textureName?, paletteName? }.
-- pack: an Nsbtx.decode result. Returns { materials = {...}, textures = { [bankKey]
-- = <bank bytes> }, unresolved = { {material,kind,name,source} } }.
function MaterialCompiler.compile(materials, pack, opts)
  opts = opts or {}
  local records, textures, unresolved = {}, {}, {}

  for _, mat in ipairs(materials) do
    local record = {
      id = mat.index,
      name = mat.name,
      texture = nil,
      wrap = { x = "clamp", y = "clamp" },
      flip = { x = false, y = false },
      diffuse = { r = 255, g = 255, b = 255, a = 255 },
    }

    -- Wrap/flip come from the material's texImageParam (what the DS programs per
    -- material), not the NSBTX texture template -- the template reads clamp for
    -- map textures, which collapses tiling UVs (e.g. flowers). A failed bind
    -- leaves them as the material stored them, so they are read unconditionally.
    if mat.textureName then
      record.wrap = { x = wrapMode(mat.repeatX), y = wrapMode(mat.repeatY) }
      record.flip = { x = mat.flipX or false, y = mat.flipY or false }
    end

    local resolved = MaterialCompiler.resolveTexture(mat, pack, textures, unresolved, { context = opts.context })
    record.texture = resolved.texture
    record.textureFormat = resolved.textureFormat
    record.texWidth = resolved.texWidth
    record.texHeight = resolved.texHeight
    record.alphaUsage = resolved.alphaUsage

    if resolved.texture then
      -- The block was located right iff the material's stored original size
      -- matches the texture it binds; a mismatch means a parse offset is wrong.
      if mat.origWidth then
        local tex = pack.textureByName[mat.textureName]
        assert(
          mat.origWidth == tex.width and mat.origHeight == tex.height,
          "material " .. mat.name .. " origWH does not match bound texture " .. mat.textureName
        )
      end
    end

    records[#records + 1] = record
  end

  return { materials = records, textures = textures, unresolved = unresolved }
end

MaterialCompiler.DECODER_VERSION = DECODER_VERSION

return MaterialCompiler
