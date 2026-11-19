-- ModelAssetCompiler terrain routing: only the terrain roles (map and
-- neighbor) mark their filled-surface draws as taking part in boundary repair.
-- Repair itself runs at runtime over those grouped draws; the producer's
-- decision travels in the native model bank so the runtime never re-derives
-- which source model owned the seam.

local Assert = require("tests.support.Assert")
local ModelAssetCompiler = require("romdump.src.digest.model.ModelAssetCompiler")
local NativeGxFormat = require("libs.assets.src.model.NativeGxFormat")
local Nsbmd = require("libs.nds.src.nitro.g3d.Nsbmd")
local NsbmdFixture = require("tests.support.NsbmdFixture")
local Nsbtx = require("libs.nds.src.nitro.g3d.Nsbtx")
local TF = require("tests.support.TextureFixtures")
local Tex0Fixture = require("tests.support.Tex0Fixture")

local T = {}

local TEXEL = string.rep(string.char(0x11), 32)
local PALETTE = TF.palette({ TF.BLACK, TF.RED, TF.GREEN, TF.BLACK })

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

local function compileFor(role)
  local model, pack = fixtures()
  local meshes, textures = {}, {}
  local result = ModelAssetCompiler.compileModel(model, pack, meshes, textures, {
    mapId = 61,
    role = role,
    textureArchive = "map_textures",
    textureMemberId = 3,
    modelArchive = "land_data",
    modelMemberId = 244,
    modelName = "map0",
  })
  local key, bytes = next(meshes)
  Assert.notNil(key, "the role compiles one native model bank")
  local bank = assert(NativeGxFormat.read(assert(bytes)))
  return result, bank
end

function T.terrain_roles_mark_their_filled_draws_for_boundary_repair()
  for _, role in ipairs({ "map", "neighbor" }) do
    local result, bank = compileFor(role)
    Assert.isTrue(bank.drawCount > 0, role .. " compiles at least one draw")
    Assert.equal(bank.drawCount, #result.batches, role .. " keeps one batch per bank draw")
    for index, draw in ipairs(bank.draws) do
      Assert.isTrue(draw.terrainBoundaryEligible, role .. " draw " .. (index - 1) .. " takes part in repair")
    end
  end
end

function T.non_terrain_roles_never_take_part_in_boundary_repair()
  for _, role in ipairs({ "building", "actor" }) do
    local _, bank = compileFor(role)
    Assert.isTrue(bank.drawCount > 0, role .. " compiles the model")
    for index, draw in ipairs(bank.draws) do
      Assert.isFalse(draw.terrainBoundaryEligible, role .. " draw " .. (index - 1) .. " stays out of repair")
    end
  end
end

return { tests = T }
