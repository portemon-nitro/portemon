-- Synthetic tests for the scene 4 starter particle normalization. Hand-built
-- SPL members exercise the emitter count gate, the starter group mapping,
-- texture staging, and the fatal paths; no ROM bytes are committed.

local Assert = require("tests.support.Assert")
local OpeningParticleCompiler = require("romdump.src.digest.startup.OpeningParticleCompiler")

local T = {}

local function u16(v)
  v = v % 0x10000
  return string.char(v % 256, math.floor(v / 256) % 256)
end

local function u32(v)
  v = v % 0x100000000
  return string.char(v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256)
end

local function emitter(textureIndex)
  return u32(0)
    .. string.rep("\0", 56)
    .. u16(18)
    .. u16(15)
    .. string.rep("\0", 4)
    .. string.char(0, 0, 0, textureIndex)
    .. string.rep("\0", 16)
end

local function textureBlock()
  local texels = string.rep("\0", 1024)
  local palette = string.rep("\0", 2)
  local param = 6 + 2 * 16 + 2 * 256
  return u32(0x53505420)
    .. u32(param)
    .. u32(#texels)
    .. u32(32 + #texels)
    .. u32(#palette)
    .. string.rep("\0", 8)
    .. u32(32 + #texels + #palette)
    .. texels
    .. palette
end

local function nineEmitterMember()
  local parts = { " APS12_1" .. u16(9) .. u16(9) .. string.rep("\0", 20) }
  for _ = 1, 9 do
    parts[#parts + 1] = emitter(0)
  end
  for _ = 1, 9 do
    parts[#parts + 1] = textureBlock()
  end
  return table.concat(parts)
end

function T.particle_compiler_normalizes_nine_starter_emitters()
  local compiled, err = OpeningParticleCompiler.compile(nineEmitterMember(), "assets/generated/startup/opening/4")
  Assert.notNil(compiled, "the nine-emitter member compiles: " .. tostring(err))
  local particles = assert(compiled.particles, "the bundle carries its particle set")
  Assert.equal(particles.seed, 0, "the particle set keeps the deterministic source seed")
  Assert.equal(#particles.emitters, 9, "the particle set keeps all nine starter emitters")
  local groups = {
    [0] = "water",
    [1] = "water",
    [2] = "water",
    [3] = "fire",
    [4] = "fire",
    [5] = "fire",
    [6] = "grass",
    [7] = "grass",
    [8] = "grass",
  }
  for _, record in ipairs(particles.emitters) do
    Assert.equal(record.group, groups[record.id], "source emitter " .. record.id .. " stays in its starter group")
    Assert.isTrue(record.emitterLife > 0, "source emitter " .. record.id .. " keeps its lifespan")
    Assert.notNil(record.textureImage, "source emitter " .. record.id .. " keeps its staged texture")
  end
  local staged = 0
  for path in pairs(compiled.files) do
    Assert.isTrue(
      path:sub(1, #"assets/generated/startup/opening/4/") == "assets/generated/startup/opening/4/",
      "particle art stays under the scene 4 root: " .. path
    )
    staged = staged + 1
  end
  Assert.equal(staged, 9, "the nine particle textures stage")
end

function T.particle_compiler_rejects_a_wrong_emitter_count()
  local parts = { " APS12_1" .. u16(1) .. u16(1) .. string.rep("\0", 20), emitter(0), textureBlock() }
  local compiled, err = OpeningParticleCompiler.compile(table.concat(parts), "assets/generated/startup/opening/4")
  Assert.isNil(compiled, "a single-emitter member never reads as the starter set")
  Assert.notNil(err, "the wrong emitter count reports its cause")
end

function T.particle_compiler_rejects_an_unsupported_feature()
  local parts = { " APS12_1" .. u16(9) .. u16(9) .. string.rep("\0", 20) }
  for id = 1, 9 do
    local flag = id == 1 and 2 ^ 11 or 0
    parts[#parts + 1] = u32(flag)
      .. string.rep("\0", 56)
      .. u16(18)
      .. u16(15)
      .. string.rep("\0", 4)
      .. string.char(0, 0, 0, 0)
      .. string.rep("\0", 16)
  end
  for _ = 1, 9 do
    parts[#parts + 1] = textureBlock()
  end
  local compiled, err = OpeningParticleCompiler.compile(table.concat(parts), "assets/generated/startup/opening/4")
  Assert.isNil(compiled, "an unsupported emitter feature fails the build")
  Assert.notNil(err, "the unsupported feature reports its emitter context")
end

function T.particle_compiler_rejects_a_missing_texture_selection()
  local parts = { " APS12_1" .. u16(9) .. u16(1) .. string.rep("\0", 20) }
  for _ = 1, 9 do
    parts[#parts + 1] = u32(0)
      .. string.rep("\0", 56)
      .. u16(18)
      .. u16(15)
      .. string.rep("\0", 4)
      .. string.char(0, 0, 0, 8)
      .. string.rep("\0", 16)
  end
  parts[#parts + 1] = textureBlock()
  local compiled, err = OpeningParticleCompiler.compile(table.concat(parts), "assets/generated/startup/opening/4")
  Assert.isNil(compiled, "a dangling texture selection never stages")
  Assert.notNil(err, "the dangling texture reports its emitter context")
end

return { tests = T }
