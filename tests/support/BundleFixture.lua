-- Minimal self-consistent compiled-map bundle for exercising MapCacheWriter and
-- MapAssetCache without the real ROM pipeline: one native model bank with one
-- draw, one native texture bank with one texture, one model descriptor (the
-- explicit static schema/kind), and a scene that selects from both banks, plus
-- a normalized collision grid and a marker.

local MapAssetCache = require("libs.assets.src.MapAssetCache")
local ModelAsset = require("libs.assets.src.model.ModelAsset")
local NativeGxFormat = require("libs.assets.src.model.NativeGxFormat")
local NativeTextureBank = require("libs.assets.src.model.NativeTextureBank")

local BundleFixture = {}

local function u32(value)
  return string.char(
    value % 256,
    math.floor(value / 256) % 256,
    math.floor(value / 65536) % 256,
    math.floor(value / 16777216) % 256
  )
end

-- One VTX_16 parameter word pair for model-unit { x, y, z } at 1.3.12.
local function vtx16(x, y, z)
  local function fx(value)
    return math.floor(value * 4096) % 0x10000
  end
  return u32(fx(x) + fx(y) * 0x10000) .. u32(fx(z))
end

-- BEGIN_VTXS(triangles), three positioned vertices, END_VTXS, packed in the
-- DS geometry FIFO's four-opcode groups with their parameters following.
local function triangleCommands(vertices)
  return string.char(0x40, 0x23, 0x23, 0x23)
    .. u32(0)
    .. vtx16(vertices[1][1], vertices[1][2], vertices[1][3])
    .. vtx16(vertices[2][1], vertices[2][2], vertices[2][3])
    .. vtx16(vertices[3][1], vertices[3][2], vertices[3][3])
    .. string.char(0x41, 0, 0, 0)
end

local function collisionGrid(width, height)
  local cells = {}
  for index = 1, width * height do
    cells[index] = { behavior = 0, terrainResponseId = 0, blocked = false }
  end
  return { width = width, height = height, cells = cells }
end

function BundleFixture.minimal(mapId)
  mapId = mapId or 61
  local meshSha = "mesh0000000000000000000000000000000000aa"
  local texSha = "tex00000000000000000000000000000000000bb"
  local modelKey = "indoor:1:abc123abc123"

  local scene = {
    schema = MapAssetCache.SCENE_SCHEMA,
    mapId = mapId,
    mapBatches = {
      { geometry = { file = MapAssetCache.modelBankPath(meshSha), drawIndex = 0 }, material = 0, node = 0 },
    },
    materials = {
      {
        id = 0,
        name = "m0",
        texture = { file = MapAssetCache.textureBankPath(texSha), textureName = "t0" },
        texWidth = 8,
        texHeight = 8,
        texMtxMode = 0,
      },
    },
    buildingInstances = { { placementIndex = 0, modelKey = modelKey } },
    neighbors = {},
    terrainAnimations = { textureSrt = false },
  }

  return {
    mapId = mapId,
    marker = MapAssetCache.marker("romsha1", mapId, "dephash"),
    scene = scene,
    dependencies = { cacheFormat = MapAssetCache.FORMAT },
    collision = collisionGrid(32, 32),
    terrain = {
      schema = "g4-terrain-surfaces-v1",
      source = { landDataMemberId = 0, bdhcOffset = 0, bdhcSize = 16, bdhcSha1 = "bdhcsha1" },
      points = {},
      slopes = {},
      heights = {},
      plates = {},
      strips = {},
      accessEntries = {},
    },
    meshes = {
      [meshSha] = NativeGxFormat.encode({
        draws = {
          {
            commands = triangleCommands({ { 0, 0, 0 }, { 1, 0, 0 }, { 0, 0, 1 } }),
            nodeIndex = 0,
            materialIndex = 0,
            shapeIndex = 0,
            transformMode = "static",
          },
        },
      }),
    },
    textures = {
      [texSha] = NativeTextureBank.encode({
        textures = {
          {
            name = "t0",
            formatRaw = 7,
            width = 8,
            height = 8,
            color0Transparent = false,
            texels = string.rep(string.char(0x1F, 0x00), 64),
          },
        },
        palettes = {},
      }),
    },
    models = {
      [modelKey] = {
        schema = ModelAsset.SCHEMA,
        key = modelKey,
        memberId = 1,
        kind = "static",
        materials = {},
        batches = {},
      },
    },
  }
end

return BundleFixture
