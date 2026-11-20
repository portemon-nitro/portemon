-- Animated and camera-facing model draws keep their pose/billboard semantics
-- while their geometry moves into the source model's native bank: the draw
-- record keeps the transform mode, the pose-derived position source (absent for
-- an already-baked billboard) and the material/polygon state the renderer
-- already reads, and the geometry it points at is a draw index into one shared
-- bank instead of an expanded mesh file.
--
-- The bank must also carry everything the reference mesh compile baked into the
-- vertices, so the runtime replay reproduces the same geometry: a billboard's
-- pose-independent post-BB matrix and the geometry-engine color/normal state
-- each draw's commands inherit.

local Assert = require("tests.support.Assert")
local DynamicModelCompiler = require("romdump.src.digest.model.DynamicModelCompiler")
local GxDisplayList = require("libs.nds.src.gx.GxDisplayList")
local GxGeometryBuffer = require("libs.nds.src.gx.GxGeometryBuffer")
local NativeGxFormat = require("libs.assets.src.model.NativeGxFormat")
local Nsbmd = require("libs.nds.src.nitro.g3d.Nsbmd")
local NsbmdDynamicModel = require("romdump.src.digest.model.NsbmdDynamicModel")
local NsbmdFixture = require("tests.support.NsbmdFixture")
local Tex0Fixture = require("tests.support.Tex0Fixture")

local T = {}

local MATCH_TOLERANCE = 1e-4

---@param value unknown
---@return string
local function rawBytes(value)
  if type(value) == "string" then
    return value
  end
  if type(value) == "table" and value.data ~= nil then
    return rawBytes(value.data)
  end
  Assert.equal(type(value), "userdata", "compiled geometry travels as bytes")
  ---@cast value love.Data
  return value:getString()
end

local function compiledBanks(meshes)
  local banks = {}
  for key, value in pairs(meshes) do
    local ok, bytes = pcall(rawBytes, value)
    if ok and type(bytes) == "string" then
      Assert.isNil(
        bytes:sub(1, 4) == "G4M2" and "expanded mesh" or nil,
        "a source model draw persists a native bank record, not an expanded mesh: " .. tostring(key)
      )
      if bytes:sub(1, 4) == "G4GX" then
        banks[#banks + 1] = bytes
      end
    end
  end
  return banks
end

local function billboardFixture()
  return assert(Nsbmd.decode(NsbmdFixture.buildBillboardQuad({
    origWidth = 8,
    origHeight = 8,
    embeddedTex0 = Tex0Fixture.block({ textures = { "tex0" }, palettes = { "pal0" } }),
  })))
end

-- The bank's replay contract is the reference mesh compile: one native bank
-- carries every draw of the animated source model, the descriptor keeps the
-- camera-facing transform, the animated binding and the material/node
-- bindings, and replaying each bank record lands on the same vertices the
-- compile baked (positions including the billboard bake, normals, UVs, vertex
-- colors and color sources).
---@param label string
---@param segment table the pose segment the draw keeps
---@param mesh table reference mesh compiled from the same source model
---@param draw NativeGxFormat.Draw bank record under test
---@param texture { width: integer, height: integer } the reference material's extent
local function assertSegmentMatchesReference(label, segment, mesh, draw, texture)
  Assert.equal(segment.vertexCount, mesh.batch.vertexCount, label .. " keeps its vertex count")
  local positionScale = draw.positionScale or 1
  local uScale = 1 / assert(draw.texWidth)
  local vScale = 1 / assert(draw.texHeight)
  for offset = 0, segment.vertexCount - 1 do
    local actual = segment.arena.numeric[segment.vertexOffset + offset]
    local actualAttrib = segment.arena.attrib[segment.vertexOffset + offset]
    local expected = mesh.batch.arena.numeric[mesh.batch.vertexOffset + offset]
    local expectedAttrib = mesh.batch.arena.attrib[mesh.batch.vertexOffset + offset]

    -- The bank's texture extent is the UV divisor the replay needs, so a
    -- dropped or wrong extent shows up as a scaled UV.
    Assert.near(actual.x * positionScale, expected.x, MATCH_TOLERANCE, label .. " position x")
    Assert.near(actual.y * positionScale, expected.y, MATCH_TOLERANCE, label .. " position y")
    Assert.near(actual.z * positionScale, expected.z, MATCH_TOLERANCE, label .. " position z")
    Assert.near(actual.u * uScale, expected.u / texture.width, MATCH_TOLERANCE, label .. " normalized u")
    Assert.near(actual.v * vScale, expected.v / texture.height, MATCH_TOLERANCE, label .. " normalized v")

    -- Normals compare by direction: the two replays may differ in length.
    local actualLength = math.sqrt(actual.nx * actual.nx + actual.ny * actual.ny + actual.nz * actual.nz)
    local expectedLength = math.sqrt(expected.nx * expected.nx + expected.ny * expected.ny + expected.nz * expected.nz)
    Assert.isTrue(actualLength > 0 and expectedLength > 0, label .. " carries a direction")
    local function direction(value, length)
      return value / length
    end
    Assert.near(direction(actual.nx, actualLength), direction(expected.nx, expectedLength), 1e-5, label .. " normal x")
    Assert.near(direction(actual.ny, actualLength), direction(expected.ny, expectedLength), 1e-5, label .. " normal y")
    Assert.near(direction(actual.nz, actualLength), direction(expected.nz, expectedLength), 1e-5, label .. " normal z")

    Assert.equal(actualAttrib.r, expectedAttrib.r, label .. " seeded red")
    Assert.equal(actualAttrib.g, expectedAttrib.g, label .. " seeded green")
    Assert.equal(actualAttrib.b, expectedAttrib.b, label .. " seeded blue")
    Assert.equal(actualAttrib.colorSource, expectedAttrib.colorSource, label .. " color source")
  end
end

function T.billboard_draws_survive_the_native_bank_as_replayable_geometry()
  local decoded = billboardFixture()
  local model = decoded.models[1]
  local poseClip = {
    id = "fixture:pose",
    name = "pose",
    category = "model",
    kind = "pose",
    frameCount = 2,
    tracks = {},
    semanticNames = {},
  }
  local meshes, textures = {}, {}
  local descriptor = DynamicModelCompiler.compile(
    model,
    decoded,
    decoded.embeddedTextures,
    { clips = { poseClip } },
    { role = "actor", modelArchive = "fixture", modelMemberId = 1, modelName = "billboard" },
    1,
    textures,
    meshes
  )

  local batches = descriptor.dynamic.batches
  Assert.isTrue(#batches > 0, "the dynamic model compiles at least one visible draw")
  local seen = {}
  for _, batch in ipairs(batches) do
    local geometry = batch.geometry
    Assert.equal(type(geometry), "table", "a dynamic draw references its model bank by selector")
    Assert.isTrue(
      tostring(geometry.file):sub(-5) == ".g4gx",
      "a dynamic draw selects its native model bank rather than an expanded mesh"
    )
    Assert.equal(type(geometry.drawIndex), "number", "a dynamic draw keeps its zero-based draw index")
    Assert.isNil(seen[geometry.drawIndex], "each dynamic draw keeps its own bank record")
    seen[geometry.drawIndex] = true
    Assert.equal(batch.transformMode, "billboard", "the camera-facing transform mode is preserved")
    Assert.isNil(batch.positionSource, "a billboard draw is fully baked, so it names no runtime position source")
    Assert.notNil(batch.nodeIndex, "the node binding is preserved")
    Assert.notNil(batch.materialIndex, "the material binding is preserved")
  end

  Assert.equal(descriptor.kind, "nitro-dynamic", "animated models keep their dynamic descriptor kind")
  Assert.notNil(descriptor.dynamic.transformProgram, "the pose transform program is preserved")
  Assert.isTrue(#descriptor.dynamic.nodes > 0, "the pose node graph is preserved")
  Assert.equal(descriptor.animations[1].id, "fixture:pose", "the compiled animation binding is preserved")

  local banks = compiledBanks(meshes)
  Assert.equal(#banks, 1, "one native model bank carries every draw of the animated source model")
  local bank = assert(NativeGxFormat.read(banks[1]))
  local reference = NsbmdDynamicModel.compile(model)
  Assert.equal(bank.drawCount, #reference.meshes, "the bank keeps one draw record per compiled segment")

  local referenceByDraw = {}
  for _, mesh in ipairs(reference.meshes) do
    referenceByDraw[mesh.id] = mesh
  end
  local arena = GxGeometryBuffer.new()
  local scratch = GxDisplayList.newScratch()
  for index, draw in ipairs(bank.draws) do
    local record = descriptor.dynamic.batches[index]
    local mesh = assert(referenceByDraw[record.id], "bank draw " .. index .. " matches a compiled mesh")
    local label = "bank draw " .. record.id

    -- The billboard's pose-independent post-BB matrix is what makes the shape
    -- the authored size (the fixture folds posScale 8 in), so it travels in
    -- the bank rather than being re-derived at draw time.
    Assert.notNil(draw.matrix, label .. " carries its pose-independent bake matrix")
    Assert.equal(draw.matrix[1], 8, label .. " bakes the model's POSSCALE into the replay")
    Assert.notNil(draw.seedColorSource, label .. " inherits a resolved engine color source")

    local replay = assert(
      GxDisplayList.decode(rawBytes(draw.commands), {
        arena = arena,
        scratch = scratch,
        collectCommands = false,
        dynamic = true,
        matrix = draw.matrix,
        initialState = { color = draw.seedColor, normal = draw.seedNormal, colorSource = draw.seedColorSource },
      }),
      label .. " replays its command stream"
    )
    local segment = assert(replay.segments[draw.segmentIndex + 1], label .. " keeps its pose segment")
    local texture = assert(reference.textureSizes[mesh.materialIndex])
    assertSegmentMatchesReference(label, segment, mesh, draw, texture)
  end
end

return { tests = T }
