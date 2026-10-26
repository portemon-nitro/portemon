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
    .. string.char(1, 31, 0, textureIndex)
    .. string.char(1)
    .. string.rep("\0", 15)
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
      .. string.char(1, 31, 0, 8)
      .. string.char(1)
      .. string.rep("\0", 15)
  end
  parts[#parts + 1] = textureBlock()
  local compiled, err = OpeningParticleCompiler.compile(table.concat(parts), "assets/generated/startup/opening/4")
  Assert.isNil(compiled, "a dangling texture selection never stages")
  Assert.notNil(err, "the dangling texture reports its emitter context")
end

local function s16(v)
  v = v % 0x10000
  return string.char(v % 256, math.floor(v / 256) % 256)
end

local function s32(v)
  v = v % 0x100000000
  return string.char(
    v % 256,
    math.floor(v / 256) % 256,
    math.floor(v / 65536) % 256,
    math.floor(v / 16777216) % 256
  )
end

-- A base record with explicit source words: fixed-point magnitude words,
-- the aspect/start/rotation/lifespan/random words, and the generation and
-- texture words. Optional block bytes follow the base in source order.
local function tailedEmitter(flag, words, extra)
  local record = u32(flag)
    .. string.rep("\0", 12)
    .. s32(words.genNum or 4096)
    .. s32(words.radius or 4096)
    .. s32(words.length or 0)
    .. string.rep("\0", 6)
    .. u16(words.baseColor or 0x7FFF)
    .. s32(words.ivel or 0)
    .. s32(words.avel or 0)
    .. s32(words.bscl or 4096)
    .. s16(words.aspect or 4096)
    .. u16(words.start or 0)
    .. s16(words.rttMin or 0)
    .. s16(words.rttMax or 0)
    .. u16(words.initRtt or 0)
    .. u16(0)
    .. u16(words.emtrLife or 18)
    .. u16(words.ptclLife or 15)
    .. string.char(words.rndmBase or 0, words.rndmLife or 0, words.rndmVel or 0, 0)
    .. string.char(words.genIntvl or 1, words.baseAlp or 31, words.air or 0, words.texNo or 0)
    .. u32(words.word1 or 1)
    .. u32(words.word2 or 0)
    .. s16(words.offX or 0)
    .. s16(words.offY or 0)
    .. u32(0)
  Assert.equal(#record, 88, "the synthetic emitter base matches the retail base size")
  if extra ~= nil then
    record = record .. extra
  end
  return record
end

-- A plain emitter with no animation blocks, valid lifespans, and a
-- nonzero generation interval.
local function plainEmitter(textureIndex)
  return tailedEmitter(2, { texNo = textureIndex })
end

local function scaleBlock(s, n, e, inside, outside)
  return s16(s) .. s16(n) .. s16(e) .. string.char(inside, outside) .. u16(0) .. u16(0)
end

local function rgb(r, g, b)
  return r + g * 32 + b * 1024
end

local function colorBlock(cs, ce, inside, peak, outside, interpolate)
  local etc = interpolate and 4 or 0
  return u16(cs) .. u16(ce) .. string.char(inside, peak, outside, 0) .. u16(etc) .. u16(0)
end

local function alphaBlock(s, n, e, inside, outside)
  return u16(s + n * 32 + e * 1024) .. u16(0) .. string.char(inside, outside) .. u16(0)
end

local function spinField(rotation, axis)
  return u16(rotation) .. u16(axis)
end

local function ninePlainMember()
  local parts = { " APS12_1" .. u16(9) .. u16(9) .. string.rep("\0", 20) }
  for _ = 1, 9 do
    parts[#parts + 1] = plainEmitter(0)
  end
  for _ = 1, 9 do
    parts[#parts + 1] = textureBlock()
  end
  return table.concat(parts)
end

local function memberWithFirst(first)
  local parts = { " APS12_1" .. u16(9) .. u16(9) .. string.rep("\0", 20) }
  parts[#parts + 1] = first
  for _ = 2, 9 do
    parts[#parts + 1] = plainEmitter(0)
  end
  for _ = 1, 9 do
    parts[#parts + 1] = textureBlock()
  end
  return table.concat(parts)
end

function T.particle_compiler_decodes_animation_geometry_and_motion_records()
  local flag = 2 + 2 ^ 8 + 2 ^ 9 + 2 ^ 10 + 2 ^ 14 + 2 ^ 27
  local first = tailedEmitter(flag, {
    genNum = 20480,
    radius = 2132,
    ivel = 8192,
    bscl = 1638,
    emtrLife = 18,
    ptclLife = 15,
    rndmBase = 84,
    rndmLife = 0,
    rndmVel = 102,
    genIntvl = 1,
    baseAlp = 31,
    air = 129,
    texNo = 0,
    baseColor = rgb(17, 27, 31),
  }, scaleBlock(2048, 4096, 8192, 64, 192)
    .. colorBlock(rgb(31, 0, 0), rgb(0, 0, 31), 10, 100, 200, true)
    .. alphaBlock(5, 20, 10, 30, 220)
    .. spinField(2000, 2))
  local compiled, err = OpeningParticleCompiler.compile(
    memberWithFirst(first),
    "assets/generated/startup/opening/4"
  )
  Assert.notNil(compiled, "the animated member compiles: " .. tostring(err))
  local record = assert(compiled.particles.emitters[1], "the first emitter normalizes")
  Assert.equal(record.id, 0, "the first emitter keeps its source id")
  Assert.equal(record.group, "water", "the first emitter stays in its starter group")
  local scale = assert(record.animations.scale, "the scale block normalizes")
  Assert.equal(scale.startFx, 2048, "the scale keeps its start stage")
  Assert.equal(scale.normalFx, 4096, "the scale keeps its normal stage")
  Assert.equal(scale.finishFx, 8192, "the scale keeps its end stage")
  Assert.equal(scale.inTick, 64, "the scale keeps its entry threshold")
  Assert.equal(scale.outTick, 192, "the scale keeps its exit threshold")
  local color = assert(record.animations.color, "the color block normalizes")
  Assert.deepEqual(color.startRgb, { r = 31, g = 0, b = 0 }, "the color keeps its start channels")
  Assert.deepEqual(color.endRgb, { r = 0, g = 0, b = 31 }, "the color keeps its end channels")
  Assert.equal(color.inTick, 10, "the color keeps its entry threshold")
  Assert.equal(color.peakTick, 100, "the color keeps its peak threshold")
  Assert.equal(color.outTick, 200, "the color keeps its exit threshold")
  Assert.isTrue(color.interpolate, "the color keeps its interpolation flag")
  local alpha = assert(record.animations.alpha, "the alpha block normalizes")
  Assert.equal(alpha.start, 5, "the alpha keeps its start level")
  Assert.equal(alpha.normal, 20, "the alpha keeps its normal level")
  Assert.equal(alpha.finish, 10, "the alpha keeps its end level")
  Assert.equal(alpha.inTick, 30, "the alpha keeps its entry threshold")
  Assert.equal(alpha.outTick, 220, "the alpha keeps its exit threshold")
  Assert.equal(record.initPosType, 2, "the emitter keeps its placement kind")
  Assert.equal(record.circleAxis, 0, "the emitter keeps its circle axis")
  Assert.equal(record.drawType, 0, "the emitter keeps its draw kind")
  Assert.equal(record.generation.countFx, 20480, "the emitter keeps its exact generation count")
  Assert.equal(record.generation.interval, 1, "the emitter keeps its generation interval")
  Assert.equal(record.velocityFx.pos, 8192, "the emitter keeps its exact position velocity")
  Assert.equal(record.baseScaleFx, 1638, "the emitter keeps its exact base scale")
  Assert.equal(record.velRandom, 102, "the emitter keeps its velocity random range")
  Assert.equal(record.scaleRandom, 84, "the emitter keeps its scale random range")
  Assert.equal(record.airResist, 129, "the emitter keeps its air resistance")
  Assert.deepEqual(
    record.baseColorRgb,
    { r = 17, g = 27, b = 31 },
    "the emitter keeps its exact base color channels"
  )
  Assert.equal(#record.fields, 1, "the emitter keeps its spin field")
  Assert.equal(record.fields[1].kind, "spin", "the field keeps its spin kind")
  Assert.equal(record.fields[1].rotation, 2000, "the spin keeps its rotation step")
  Assert.equal(record.fields[1].axis, 2, "the spin keeps its rotation axis")
  Assert.isNil(record.child, "an emitter without a child block carries no child")
end

function T.particle_compiler_decodes_child_records()
  local flag = 2 + 2 ^ 8 + 2 ^ 9 + 2 ^ 10 + 2 ^ 14 + 2 ^ 16 + 2 ^ 27
  local child = u16(0x0006)
    .. s16(0)
    .. s16(5360)
    .. u16(7)
    .. string.char(0, 49)
    .. u16(0x7FFF)
    .. string.char(1, 0, 3, 8)
    .. string.char(5, 0, 0, 0)
  local first = tailedEmitter(flag, { texNo = 1 }, string.rep("\0", 12 + 12 + 8) .. child .. spinField(609, 2))
  local compiled, err = OpeningParticleCompiler.compile(
    memberWithFirst(first),
    "assets/generated/startup/opening/4"
  )
  Assert.notNil(compiled, "the child member compiles: " .. tostring(err))
  local record = assert(compiled.particles.emitters[1], "the first emitter normalizes")
  local childRecord = assert(record.child, "the child block normalizes")
  Assert.isTrue(childRecord.useScaleAnm, "the child keeps its scale animation flag")
  Assert.isTrue(childRecord.useAlphaAnm, "the child keeps its alpha animation flag")
  Assert.equal(childRecord.life, 7, "the child keeps its lifespan")
  Assert.equal(childRecord.sclRatio, 49, "the child keeps its scale ratio")
  Assert.equal(childRecord.genInterval, 3, "the child keeps its generation interval")
  Assert.equal(childRecord.texNo, 8, "the child keeps its texture selection")
end

function T.particle_compiler_rejects_a_zero_generation_interval()
  local first = tailedEmitter(2, { genIntvl = 0, texNo = 0 })
  local compiled, err =
    OpeningParticleCompiler.compile(memberWithFirst(first), "assets/generated/startup/opening/4")
  Assert.isNil(compiled, "a zero generation interval never compiles")
  Assert.notNil(err, "the zero interval reports its emitter context")
end

function T.particle_compiler_rejects_an_unsupported_draw_kind()
  local first = tailedEmitter(2 + 2 ^ 5, { texNo = 0 })
  local compiled, err =
    OpeningParticleCompiler.compile(memberWithFirst(first), "assets/generated/startup/opening/4")
  Assert.isNil(compiled, "a polygon draw kind never compiles")
  Assert.notNil(err, "the draw kind reports its emitter context")
end

function T.particle_compiler_rejects_mirrored_texture_coordinates()
  local first = tailedEmitter(2, { texNo = 0, word2 = 1 })
  local compiled, err =
    OpeningParticleCompiler.compile(memberWithFirst(first), "assets/generated/startup/opening/4")
  Assert.isNil(compiled, "a mirrored texture never compiles")
  Assert.notNil(err, "the mirror flag reports its emitter context")
end

return { tests = T }
