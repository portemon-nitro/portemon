-- The model compiler's published geometry contract: one source model becomes
-- one engine-owned native bank of ordered draw command spans, and the same
-- immutable source model or texture pack always resolves to the same bank, no
-- matter which scene or family compiles it. Draw selection lives in the scene
-- descriptor as a draw index into that bank, never as one physical file per
-- draw.

local Assert = require("tests.support.Assert")
local GxDisplayList = require("libs.nds.src.gx.GxDisplayList")
local GxGeometryBuffer = require("libs.nds.src.gx.GxGeometryBuffer")
local MeshCompiler = require("romdump.src.digest.model.MeshCompiler")
local ModelAssetCompiler = require("romdump.src.digest.model.ModelAssetCompiler")
local NBs = require("tests.support.NitroBuilder")
local Nsbmd = require("libs.nds.src.nitro.g3d.Nsbmd")
local NsbmdFixture = require("tests.support.NsbmdFixture")
local Nsbtx = require("libs.nds.src.nitro.g3d.Nsbtx")
local SceneMesh = require("libs.hgss.src.presentation.SceneMesh")
local TF = require("tests.support.TextureFixtures")
local Tex0Fixture = require("tests.support.Tex0Fixture")
local ffi = require("ffi")

local T = {}

local BANK_MODULE = "libs.assets.src.model.NativeGxFormat"

-- The native bank reader under test, required lazily so a missing format
-- reports the missing behavior instead of a load error.
local function nativeFormat()
  local ok, mod = pcall(require, BANK_MODULE)
  Assert.isTrue(
    ok and type(mod) == "table",
    "the native model bank format is missing: compiled source models cannot be read as one bounded draw bank"
  )
  return mod --[[@as table]]
end

---@param value unknown
---@return string
local function rawBytes(value)
  if type(value) == "string" then
    return value
  end
  if type(value) == "table" and type(value.data) == "string" then
    return value.data
  end
  Assert.equal(type(value), "userdata", "compiled geometry travels as bytes")
  ---@cast value love.Data
  return value:getString()
end

local TEXEL = string.rep(string.char(0x11), 32)
local PALETTE = TF.palette({ TF.BLACK, TF.RED, TF.GREEN, TF.BLACK })

-- One quad display list in source units that first replaces the draw matrix
-- with the identity, the way a shape re-homes its own transform: the vertices
-- then land in source units whatever the SBC draw matrix held.
---@param verts number[][] four { x, y, z } corners in source units
---@return string
local function identityReplacedQuadDL(verts)
  local function appendVertex(params, v)
    params[#params + 1] = NBs.vtx16xy(v[1], v[2])
    params[#params + 1] = math.floor(v[3] * 4096) % 0x10000
  end
  local first = { 1 } -- BEGIN_VTXS(quads)
  appendVertex(first, verts[1])
  appendVertex(first, verts[2])
  local second = {}
  appendVertex(second, verts[3])
  appendVertex(second, verts[4])
  return NBs.gxPack({
    { { 0x15, 0x40, 0x23, 0x23 }, first },
    { { 0x23, 0x23, 0x41, 0x00 }, second },
  })
end

-- One source model with two SBC draws of its single shape, bound to one named
-- texture and palette.
local function fixtures()
  local modelBytes = NsbmdFixture.build({
    modelName = "map0",
    materialName = "m_grass",
    textureName = "flower01",
    paletteName = "map_pal",
    origWidth = 8,
    origHeight = 8,
    triangle = { { 0, 0, 0 }, { 2, 0, 0 }, { 0, 0, 3 } },
  })
  local model = assert(Nsbmd.decode(modelBytes, { alias = "land_data", memberId = 244 })).models[1]
  local packBytes = Tex0Fixture.btx0({
    textures = { { name = "flower01", texel = TEXEL } },
    palettes = { { name = "map_pal", palette = PALETTE } },
  })
  local pack = assert(Nsbtx.decode(packBytes, { alias = "map_textures", memberId = 3 }))
  return model, pack
end

local function compileContext(overrides)
  local context = {
    mapId = 61,
    role = "map",
    textureArchive = "map_textures",
    textureMemberId = 3,
    modelArchive = "land_data",
    modelMemberId = 244,
    modelName = "map0",
  }
  for key, value in pairs(overrides or {}) do
    context[key] = value
  end
  return context
end

-- The one compiled native model bank in an output accumulator, found by its
-- own magic so the accumulator's internal key spelling stays the producer's.
local function compiledBank(outputs)
  local found = {}
  for key, value in pairs(outputs) do
    local bytes
    if type(value) == "string" then
      bytes = value
    elseif type(value) == "userdata" and type(value.getString) == "function" then
      bytes = value:getString()
    elseif type(value) == "table" and type(value.data) == "string" then
      bytes = value.data
    end
    if type(bytes) == "string" then
      Assert.isNil(
        bytes:sub(1, 4) == "G4M2" and "expanded mesh" or nil,
        "a source model's draws persist one native draw bank, not an expanded mesh per draw: " .. tostring(key)
      )
      if bytes:sub(1, 4) == "G4GX" then
        found[#found + 1] = { key = key, bytes = bytes }
      end
    end
  end
  return found
end

function T.one_native_bank_per_source_model_with_stable_draw_indices()
  local model, pack = fixtures()
  local meshes, textures = {}, {}
  local result = ModelAssetCompiler.compileModel(model, pack, meshes, textures, compileContext())

  Assert.equal(#result.batches, 2, "the fixture source submits two draws of one model")
  local bankFile, drawIndices = nil, {}
  for _, batch in ipairs(result.batches) do
    local geometry = batch.geometry
    Assert.equal(type(geometry), "table", "each draw references its native model bank by selector")
    local path = assert(geometry.file, "a geometry selector names its bank file")
    Assert.isTrue(
      path:sub(-5) == ".g4gx",
      "a geometry selector names the native model bank rather than an expanded mesh: " .. tostring(path)
    )
    if bankFile == nil then
      bankFile = path
    end
    Assert.equal(path, bankFile, "every draw of one source model references the same physical bank")
    local drawIndex = assert(geometry.drawIndex, "a geometry selector names its zero-based draw index")
    Assert.equal(type(drawIndex), "number", "the draw index is a number")
    Assert.equal(drawIndex % 1, 0, "the draw index is an integer")
    Assert.isNil(drawIndices[drawIndex], "draw indices are distinct inside one bank")
    drawIndices[drawIndex] = true
  end
  Assert.equal(drawIndices[0], true, "draw indices start at zero")
  Assert.equal(drawIndices[1], true, "the second draw keeps its own stable index")

  local banks = compiledBank(meshes)
  Assert.equal(#banks, 1, "one native model bank is compiled for one source model")
  local Format = nativeFormat()
  local bank = assert(Format.read(banks[1].bytes))
  Assert.equal(bank.drawCount, 2, "the bank carries one draw record per compiled draw")
  local sourceCommands = rawBytes(model.shapes[1].displayListBytes)
  Assert.equal(
    rawBytes(bank.draws[1].commands),
    sourceCommands,
    "the bank preserves the source display-list command bytes instead of a triangulated copy"
  )
  Assert.equal(
    rawBytes(bank.draws[2].commands),
    sourceCommands,
    "every draw record keeps the source command bytes, stored once per distinct stream"
  )
end

function T.shared_source_model_and_texture_reuse_one_bank_across_compiles()
  local model, pack = fixtures()
  local firstMeshes, firstTextures = {}, {}
  local secondMeshes, secondTextures = {}, {}
  local first = ModelAssetCompiler.compileModel(model, pack, firstMeshes, firstTextures, compileContext({
    mapId = 61,
    role = "map",
  }))
  local second = ModelAssetCompiler.compileModel(model, pack, secondMeshes, secondTextures, compileContext({
    mapId = 84,
    role = "neighbor",
  }))

  local firstBanks = compiledBank(firstMeshes)
  local secondBanks = compiledBank(secondMeshes)
  Assert.equal(#firstBanks, 1, "one native model bank is compiled for the source model")
  Assert.equal(#secondBanks, 1, "one native model bank is compiled for the source model")
  Assert.equal(
    firstBanks[1].key,
    secondBanks[1].key,
    "an unchanged source model keeps one immutable bank identity across scenes"
  )
  Assert.equal(
    firstBanks[1].bytes,
    secondBanks[1].bytes,
    "an unchanged source model produces byte-identical bank content"
  )
  Assert.equal(
    first.batches[1].geometry.file,
    second.batches[1].geometry.file,
    "both scene descriptors reference the one shared physical bank"
  )

  -- Instances keep their own logical bindings: sharing immutable decode
  -- sources never merges per-instance draw selection or material state.
  Assert.equal(first.batches[1].material, second.batches[1].material)
  Assert.equal(first.batches[1].node, second.batches[1].node)
  Assert.equal(first.materials[1].id, second.materials[1].id)

  local firstTextureKeys = {}
  for key in pairs(firstTextures) do
    firstTextureKeys[#firstTextureKeys + 1] = key
  end
  Assert.equal(#firstTextureKeys, 1, "one texture bank is compiled for the source texture pack")
  Assert.notNil(secondTextures[firstTextureKeys[1]], "both compiles resolve the same shared texture bank")
end

-- The geometry engine carries its color/normal state from one shape call to the
-- next. A draw's recorded seed must therefore describe what the *stream
-- inherits*, not a default: two draws of a shape that issues no COLOR/NORMAL
-- keep the material's seeded color, and the second draw inherits exactly the
-- state the first one left behind.
function T.sequenced_shape_draws_record_the_carried_engine_state()
  -- NODEDESC(root), NODE(0, visible), POSSCALE, MAT 0, SHP 0, SHP 0, RET: the
  -- second submission reapplies no material, so it inherits the first shape's
  -- final state.
  local sbc = string.char(0x06, 0, 0, 0)
    .. string.char(0x02, 0, 1)
    .. string.char(0x0B)
    .. string.char(0x04, 0)
    .. string.char(0x05, 0)
    .. string.char(0x05, 0)
    .. string.char(0x01)
  local modelBytes = NsbmdFixture.buildWithSbc(sbc, {
    modelName = "carry0",
    materialName = "m_grass",
    textureName = "flower01",
    paletteName = "map_pal",
    origWidth = 8,
    origHeight = 8,
    triangle = { { 0, 0, 0 }, { 2, 0, 0 }, { 0, 0, 3 } },
  })
  local model = assert(Nsbmd.decode(modelBytes, { alias = "land_data", memberId = 244 })).models[1]
  local packBytes = Tex0Fixture.btx0({
    textures = { { name = "flower01", texel = TEXEL } },
    palettes = { { name = "map_pal", palette = PALETTE } },
  })
  local pack = assert(Nsbtx.decode(packBytes, { alias = "map_textures", memberId = 3 }))
  local meshes, textures = {}, {}
  local result = ModelAssetCompiler.compileModel(model, pack, meshes, textures, compileContext())
  Assert.equal(#result.batches, 2, "the fixture SBC submits two draws of one shape")

  local banks = compiledBank(meshes)
  Assert.equal(#banks, 1, "both draws of one source model share one native bank")
  local bank = assert(nativeFormat().read(banks[1].bytes))
  Assert.equal(bank.drawCount, 2, "the bank carries one record per submitted draw")
  local materialSeed = assert(MeshCompiler.materialState(model.materials[1]).seed)
  for index, draw in ipairs(bank.draws) do
    Assert.equal(
      draw.seedColorSource,
      materialSeed.colorSource,
      "draw " .. index .. " inherits the material's color source"
    )
    Assert.deepEqual(draw.seedColor, materialSeed.color, "draw " .. index .. " inherits the material's seeded color")
  end
  Assert.deepEqual(
    bank.draws[2].seedNormal,
    { 0, 1, 0 },
    "the second draw inherits the geometry engine's carried normal instead of reporting a zero default"
  )

  -- Replaying the published seeds reproduces the carried state: both draws emit
  -- the same seeded vertex color.
  local arena = GxGeometryBuffer.new()
  local scratch = GxDisplayList.newScratch()
  local seen = {}
  for index, draw in ipairs(bank.draws) do
    local geom = assert(GxDisplayList.decode(rawBytes(draw.commands), {
      arena = arena,
      scratch = scratch,
      initialState = { color = draw.seedColor, normal = draw.seedNormal, colorSource = draw.seedColorSource },
      matrix = draw.matrix,
    }), "draw " .. index .. " replays")
    local attrib = geom.slice.arena.attrib[geom.slice.vertexOffset]
    seen[index] = { r = attrib.r, g = attrib.g, b = attrib.b, colorSource = attrib.colorSource }
  end
  Assert.deepEqual(seen[1], {
    r = materialSeed.color[1],
    g = materialSeed.color[2],
    b = materialSeed.color[3],
    colorSource = materialSeed.colorSource,
  }, "the first draw uses the material seed")
  Assert.deepEqual(seen[2], seen[1], "the second draw reproduces the carried state")
end

-- A shape that replaces the draw matrix with the identity lands its vertices in
-- source units, exactly like the DS geometry engine. The runtime replay must
-- still convert them to runtime tiles, because the reference mesh compile
-- converts whatever the commands produced -- not whatever the draw seeded. The
-- producer keeps the draw matrix in the bank either way, so the conversion
-- cannot ride on that matrix.
function T.runtime_replay_scales_positions_the_shape_matrix_commands_replace()
  local verts = { { 1, 0, 0 }, { 3, 0, 0 }, { 3, 0, 2 }, { 1, 0, 2 } }
  local modelBytes = NsbmdFixture.buildStaticQuad({
    modelName = "matrix0",
    materialName = "m_ground",
    textureName = "flower01",
    paletteName = "map_pal",
    origWidth = 8,
    origHeight = 8,
    posScale = 16,
    quad = { verts = verts, uvs = { { 0, 0 }, { 8, 0 }, { 8, 8 }, { 0, 8 } } },
    displayList = identityReplacedQuadDL(verts),
  })
  local model = assert(Nsbmd.decode(modelBytes, { alias = "land_data", memberId = 244 })).models[1]
  local packBytes = Tex0Fixture.btx0({
    textures = { { name = "flower01", texel = TEXEL } },
    palettes = { { name = "map_pal", palette = PALETTE } },
  })
  local pack = assert(Nsbtx.decode(packBytes, { alias = "map_textures", memberId = 3 }))
  local meshes, textures = {}, {}
  local compiled = ModelAssetCompiler.compileModel(model, pack, meshes, textures, compileContext())
  Assert.equal(#compiled.batches, 1, "the fixture source submits one draw")

  -- The reference compile over the same source model is the tile-space ground
  -- truth the runtime replay has to reproduce.
  local reference = MeshCompiler.compile(model)
  Assert.equal(#reference, 1, "the reference compile produces one batch")
  local expected = assert(reference[1])
  local banks = compiledBank(meshes)
  Assert.equal(#banks, 1, "the source model compiles one native bank")
  local prepared = SceneMesh.prepareNativeBank(banks[1].bytes, "matrix-replacement")
  local draw = assert(prepared.draws[1])
  Assert.equal(draw.vertexCount, expected.vertexCount, "the replay decodes the same vertex count")

  local components = 13 -- position, texcoord, normal, colour, colour source
  local floats = ffi.cast("float *", draw.vertexData:getFFIPointer())
  local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge
  for offset = 0, expected.vertexCount - 1 do
    local want = expected.arena.numeric[expected.vertexOffset + offset]
    local base = offset * components
    Assert.near(floats[base], want.x, 1e-6, "replayed x of vertex " .. offset .. " matches the reference compile")
    Assert.near(floats[base + 1], want.y, 1e-6, "replayed y of vertex " .. offset .. " matches the reference compile")
    Assert.near(floats[base + 2], want.z, 1e-6, "replayed z of vertex " .. offset .. " matches the reference compile")
    minX, maxX = math.min(minX, want.x), math.max(maxX, want.x)
    minZ, maxZ = math.min(minZ, want.z), math.max(maxZ, want.z)
  end
  -- The source units are 16 model units per tile, so the quad spans 1/16 to
  -- 3/16 of a tile on each axis; a replay that skipped the conversion would
  -- report 16x that.
  Assert.near(minX, 1 / 16, 1e-6, "the replayed quad starts at its source-unit tile")
  Assert.near(maxX, 3 / 16, 1e-6, "the replayed quad ends at its source-unit tile")
  Assert.near(minZ, 0, 1e-6, "the replayed quad keeps its source-unit depth extent")
  Assert.near(maxZ, 2 / 16, 1e-6, "the replayed quad keeps its source-unit depth extent")
  Assert.near(draw.minX, minX, 1e-6, "the upload packet's reported bounds match the replayed positions")
  Assert.near(draw.maxX, maxX, 1e-6, "the upload packet's reported bounds match the replayed positions")
  Assert.near(draw.minZ, minZ, 1e-6, "the upload packet's reported bounds match the replayed positions")
  Assert.near(draw.maxZ, maxZ, 1e-6, "the upload packet's reported bounds match the replayed positions")
end

return { tests = T }
