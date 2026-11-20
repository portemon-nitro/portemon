-- Reads generated compiler assets through their production contracts: the
-- native model bank a compiled batch selects, the runtime geometry one
-- selected draw decodes to, and the named texel/palette pairing one material
-- selects out of its native texture bank.

local ModelAsset = require("libs.assets.src.model.ModelAsset")
local NativeGxFormat = require("libs.assets.src.model.NativeGxFormat")
local NativeTextureBank = require("libs.assets.src.model.NativeTextureBank")
local SceneMesh = require("libs.hgss.src.presentation.SceneMesh")
local TextureDecoder = require("libs.nds.src.gx.TextureDecoder")

local CompiledAsset = {}

---@param data string|love.Data
---@return string
function CompiledAsset.bytes(data)
  if type(data) == "string" then
    return data
  end
  assert(type(data) == "userdata" and type(data.getString) == "function", "compiled asset must be bytes")
  ---@cast data love.Data
  return data:getString()
end

-- Every generated asset one descriptor references exists in the compile
-- bundle: model banks land in `meshes`, texture banks and retained PNGs in
-- `textures`.
---@param bundle table<string, unknown>
---@param desc table<string, unknown>
---@param label string
function CompiledAsset.assertReferences(bundle, desc, label)
  for _, path in ipairs(ModelAsset.referencedPaths(desc)) do
    local key = assert(path:match("/([^/]+)%.([^/]+)$"), label .. " references a malformed generated path: " .. path)
    local meshes, textures = bundle.meshes, bundle.textures
    ---@cast meshes table<string, unknown>
    ---@cast textures table<string, unknown>
    if path:match("%.g4gx$") ~= nil then
      assert(meshes[key], label .. " compiled model bank exists: " .. path)
    elseif path:match("%.g4tx$") ~= nil or path:match("%.png$") ~= nil then
      assert(textures[key], label .. " compiled texture exists: " .. path)
    else
      error(label .. " references an unknown generated asset: " .. path, 0)
    end
  end
end

-- The compiled bank bytes one batch geometry reference selects, from the
-- compile bundle's `meshes` accumulator.
---@param assets table<string, unknown>
---@param geometry string|table
---@return string bytes
---@return string file cache-relative bank path
function CompiledAsset.bankBytes(assets, geometry)
  local file = ModelAsset.geometryFile(geometry)
  local key = assert(file:match("([^/]+)%.g4gx$"), "batch geometry names a native model bank: " .. tostring(file))
  local meshes = assets.meshes --[[@as table<string, string|love.Data> ]]
  return CompiledAsset.bytes(assert(meshes[key], "batch geometry present in the bundle: " .. file)), file
end

-- One batch's source model bank as the format reader returns it.
---@param assets table<string, unknown>
---@param geometry string|table
---@return NativeGxFormat.Bank
function CompiledAsset.bank(assets, geometry)
  return assert(NativeGxFormat.read(CompiledAsset.bankBytes(assets, geometry)))
end

-- The runtime geometry one batch selects: the draw the batch's drawIndex names,
-- decoded through the production replay (including terrain-boundary repair).
---@param assets table<string, unknown>
---@param geometry string|table
---@return SceneMesh.NativeDecoded
function CompiledAsset.draw(assets, geometry)
  local bytes, file = CompiledAsset.bankBytes(assets, geometry)
  local drawIndex = assert(geometry.drawIndex)
  local decoded = SceneMesh.decodeNativeBank(bytes, file).draws[drawIndex + 1]
  assert(decoded ~= nil, "native model bank has no draw " .. tostring(drawIndex) .. " in " .. file)
  return decoded --[[@as SceneMesh.NativeDecoded]]
end

-- The native texture bank one material's texture reference names, out of a map
-- keyed by bank key (the bank file's basename), such as a compile bundle's
-- `textures` accumulator.
---@param assets table<string, unknown>
---@param selector ModelAsset.TextureReference
---@param label string
---@return NativeTextureBank.Bank
function CompiledAsset.textureBank(assets, selector, label)
  local file = ModelAsset.textureFile(selector)
  local key = assert(file:match("([^/]+)%.g4tx$"), label .. " selects a native texture bank: " .. tostring(file))
  local bank = assets[key]
  return assert(
    NativeTextureBank.read(CompiledAsset.bytes(assert(bank, label .. " stages its texture bank: " .. file)))
  )
end

-- The RGBA the named texel/palette pairing one material selects decodes to,
-- together with the bank record it came from.
---@param assets table<string, unknown>
---@param selector ModelAsset.TextureReference
---@param label string
---@return { width: integer, height: integer, pixels: string, alphaUsage: table<string, boolean>, texture: NativeTextureBank.Texture }
function CompiledAsset.texturePixels(assets, selector, label)
  local bank = CompiledAsset.textureBank(assets, selector, label)
  local texture = assert(bank:texture(selector.textureName), label .. " bank holds texture " .. selector.textureName)
  local palette = nil
  if selector.paletteName ~= nil then
    palette = assert(bank:palette(selector.paletteName), label .. " bank holds palette " .. selector.paletteName)
  end
  local decoded = TextureDecoder.decode({
    format = texture.formatRaw,
    width = texture.width,
    height = texture.height,
    color0Transparent = texture.color0Transparent,
    texel = texture.texels,
    indexData = texture.indexData,
    palette = palette and palette.data,
  })
  return {
    width = decoded.width,
    height = decoded.height,
    pixels = decoded.pixels,
    alphaUsage = decoded.alphaUsage,
    texture = texture,
  }
end

-- The model-space AABB of a descriptor's decoded draws (the loader stamps the
-- same numbers onto a placement).
---@param assets table<string, unknown>
---@param desc table<string, unknown>
---@return { minX: number, maxX: number, minY: number, maxY: number, minZ: number, maxZ: number }
function CompiledAsset.footprint(assets, desc)
  local batches = desc.kind == "static" and desc.batches or desc.dynamic.batches
  local minX, maxX, minY, maxY, minZ, maxZ
  for _, batch in ipairs(batches) do
    for _, v in ipairs(CompiledAsset.draw(assets, batch.geometry).vertices) do
      minX = minX == nil and v[1] or math.min(minX, v[1])
      maxX = maxX == nil and v[1] or math.max(maxX, v[1])
      minY = minY == nil and v[2] or math.min(minY, v[2])
      maxY = maxY == nil and v[2] or math.max(maxY, v[2])
      minZ = minZ == nil and v[3] or math.min(minZ, v[3])
      maxZ = maxZ == nil and v[3] or math.max(maxZ, v[3])
    end
  end
  return {
    minX = minX or 0,
    maxX = maxX or 0,
    minY = minY or 0,
    maxY = maxY or 0,
    minZ = minZ or 0,
    maxZ = maxZ or 0,
  }
end

return CompiledAsset
