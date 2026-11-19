-- Animated and camera-facing model draws keep their pose/billboard semantics
-- while their geometry moves into the source model's native bank: the draw
-- record keeps the transform mode, the pose-derived position source and the
-- material/polygon state the renderer already reads, and the geometry it points
-- at is a draw index into one shared bank instead of an expanded mesh file.

local Assert = require("tests.support.Assert")
local DynamicModelCompiler = require("romdump.src.digest.model.DynamicModelCompiler")
local Nsbmd = require("libs.nds.src.nitro.g3d.Nsbmd")
local NsbmdFixture = require("tests.support.NsbmdFixture")
local Tex0Fixture = require("tests.support.Tex0Fixture")

local T = {}

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

-- A billboard quad drawn from an SBC billboard node, with the model's embedded
-- texture pack and one compiled animation clip so the descriptor keeps both
-- the camera-facing transform and the animated binding.
function T.billboard_and_animation_draws_survive_the_native_bank()
  local decoded = assert(Nsbmd.decode(NsbmdFixture.buildBillboardQuad({
    origWidth = 8,
    origHeight = 8,
    embeddedTex0 = Tex0Fixture.block({ textures = { "tex0" }, palettes = { "pal0" } }),
  })))
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
    decoded.models[1],
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
    Assert.notNil(batch.positionSource, "the pose-derived position source is preserved")
    Assert.notNil(batch.nodeIndex, "the node binding is preserved")
    Assert.notNil(batch.materialIndex, "the material binding is preserved")
  end

  Assert.equal(descriptor.kind, "nitro-dynamic", "animated models keep their dynamic descriptor kind")
  Assert.notNil(descriptor.dynamic.transformProgram, "the pose transform program is preserved")
  Assert.isTrue(#descriptor.dynamic.nodes > 0, "the pose node graph is preserved")
  Assert.equal(descriptor.animations[1].id, "fixture:pose", "the compiled animation binding is preserved")

  local banks = compiledBanks(meshes)
  Assert.equal(#banks, 1, "one native model bank carries every draw of the animated source model")
end

return { tests = T }
