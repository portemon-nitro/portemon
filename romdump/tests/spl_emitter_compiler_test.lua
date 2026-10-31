-- Synthetic tests for the shared SPL emitter normalization. Hand-built SPL
-- members (layout per the retail SPL resource structs) exercise the caller
-- seams (texture paths, groups, required count) and the record fields that
-- appear only when the source sets them; no ROM bytes are committed.

local Assert = require("tests.support.Assert")
local SplEmitterCompiler = require("romdump.src.digest.particle.SplEmitterCompiler")

local T = {}

local SELF_DEST = 2 ^ 14
local USE_SCALE, USE_COLOR, USE_ALPHA, USE_TEX = 2 ^ 8, 2 ^ 9, 2 ^ 10, 2 ^ 11

local function u16(v)
  v = v % 0x10000
  return string.char(v % 256, math.floor(v / 256) % 256)
end

local function u32(v)
  v = v % 0x100000000
  return string.char(v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256)
end

-- An 88-byte emitter base with valid lifespans and interval; `texNo` selects
-- the texture, `word2`/`offX` the mirror and UV offset words.
local function emitterBase(flag, texNo, word2, offX)
  return u32(flag)
    .. string.rep("\0", 56)
    .. u16(18)
    .. u16(15)
    .. string.rep("\0", 4)
    .. string.char(1, 31, 0, texNo)
    .. u32(1)
    .. u32(word2 or 0)
    .. u16(offX or 0)
    .. u16(0)
    .. u32(0)
end

local function textureBlock()
  local texels = string.rep("\0", 1024)
  local palette = string.rep("\0", 2)
  return u32(0x53505420)
    .. u32(6 + 2 * 16 + 2 * 256)
    .. u32(#texels)
    .. u32(32 + #texels)
    .. u32(#palette)
    .. string.rep("\0", 8)
    .. u32(32 + #texels + #palette)
    .. texels
    .. palette
end

-- One member holding the given pre-built emitter records and `textures` textures.
local function member(emitters, textures)
  local parts = { " APS12_1" .. u16(#emitters) .. u16(textures) .. string.rep("\0", 20) }
  for _, record in ipairs(emitters) do
    parts[#parts + 1] = record
  end
  for _ = 1, textures do
    parts[#parts + 1] = textureBlock()
  end
  return table.concat(parts)
end

local function options(extra)
  local result = {
    texturePath = function(textureId)
      return "out/texture" .. textureId .. ".png"
    end,
  }
  for key, value in pairs(extra or {}) do
    result[key] = value
  end
  return result
end

local function compileOne(record, textures, extra)
  return SplEmitterCompiler.compile(member({ record }, textures or 1), options(extra))
end

function T.compile_stages_textures_under_the_caller_paths_and_omits_unused_fields()
  local compiled, err = compileOne(emitterBase(SELF_DEST, 0), 2)
  Assert.notNil(compiled, "a plain emitter compiles: " .. tostring(err))
  local record = compiled.particles.emitters[1]
  Assert.equal(record.textureImage, "out/texture0.png", "the emitter names its staged texture by the caller path")
  Assert.notNil(compiled.files["out/texture1.png"], "every member texture stages")
  Assert.isNil(record.group, "no group is assigned without a group mapping")
  Assert.isNil(record.textureAnim, "an emitter without a texture animation carries none")
  Assert.isNil(record.textureOffset, "an emitter without a UV offset carries none")
  Assert.isNil(next(record.animations), "an emitter without animation blocks carries none")
end

function T.compile_can_carry_raw_texture_pixels_instead_of_staged_images()
  local compiled, err = SplEmitterCompiler.compile(member({ emitterBase(SELF_DEST, 0) }, 2), { embedPixels = true })
  Assert.notNil(compiled, "an embedding caller needs no texture paths: " .. tostring(err))
  Assert.isNil(next(compiled.files), "embedded textures stage no files")
  for index, texture in ipairs(compiled.particles.textures) do
    Assert.equal(texture.id, index - 1, "textures keep their source order")
    Assert.equal(#texture.pixels, texture.width * texture.height * 4, "each texture carries its RGBA pixels")
    Assert.isNil(texture.image, "an embedded texture names no staged image")
  end
  Assert.isNil(compiled.particles.emitters[1].textureImage, "an embedded emitter names no staged image")
end

function T.compile_enforces_the_caller_emitter_count_and_groups()
  local bytes = member({ emitterBase(SELF_DEST, 0), emitterBase(SELF_DEST, 0) }, 1)
  local compiled = SplEmitterCompiler.compile(
    bytes,
    options({
      emitterCount = 2,
      group = function(id)
        return "g" .. id
      end,
    })
  )
  Assert.notNil(compiled, "a matching count compiles")
  Assert.equal(compiled.particles.emitters[2].group, "g1", "each emitter takes its caller group")
  local wrong, err = SplEmitterCompiler.compile(bytes, options({ emitterCount = 3 }))
  Assert.isNil(wrong, "a different emitter count never compiles")
  Assert.notNil(err, "the count mismatch reports its cause")
  local ungrouped = SplEmitterCompiler.compile(
    bytes,
    options({
      group = function()
        return nil
      end,
    })
  )
  Assert.isNil(ungrouped, "an emitter the group mapping rejects never compiles")
end

function T.compile_accepts_every_placement_kind_and_rejects_unknown_ones()
  for placement = 0, 9 do
    local compiled, err = compileOne(emitterBase(SELF_DEST + placement, 0))
    Assert.notNil(compiled, "placement " .. placement .. " compiles: " .. tostring(err))
    Assert.equal(compiled.particles.emitters[1].initPosType, placement, "the placement kind is kept")
  end
  Assert.isNil(compileOne(emitterBase(SELF_DEST + 10, 0)), "an unreplayed placement kind fails")
end

function T.compile_requires_a_self_destroying_emitter()
  local compiled = compileOne(emitterBase(0, 0))
  Assert.isNil(compiled, "an emitter that never retires has no replay semantics")
end

function T.compile_records_the_texture_animation()
  local anim = string.char(2, 0, 1, 0, 0, 0, 0, 0) .. string.char(3, 40) .. u16(2)
  local compiled, err = compileOne(emitterBase(SELF_DEST + USE_TEX, 7) .. anim, 3)
  Assert.notNil(compiled, "a texture-animated emitter compiles: " .. tostring(err))
  local record = compiled.particles.emitters[1]
  Assert.deepEqual(
    record.textureAnim,
    { textures = { 2, 0, 1 }, diff = 40, random = false, loop = true },
    "the texture animation keeps its sequence, width, and flags"
  )
  Assert.equal(record.texture, 2, "an animated emitter starts on the first animation texture")
  Assert.equal(record.textureImage, "out/texture2.png", "the first animation texture names the emitter image")
  local random = string.char(0, 1, 0, 0, 0, 0, 0, 0) .. string.char(2, 10) .. u16(1)
  local randomRecord = compileOne(emitterBase(SELF_DEST + USE_TEX, 0) .. random, 2)
  Assert.isTrue(randomRecord.particles.emitters[1].textureAnim.random, "the random pick flag is kept")
  local missing = string.char(5, 0, 0, 0, 0, 0, 0, 0) .. string.char(1, 10) .. u16(0)
  Assert.isNil(compileOne(emitterBase(SELF_DEST + USE_TEX, 0) .. missing, 2), "a missing animation texture fails")
end

function T.compile_records_loop_and_random_flags_only_when_set()
  local scale = u16(0) .. u16(4096) .. u16(0) .. string.char(10, 200) .. u16(1) .. u16(0)
  local color = u16(31) .. u16(0) .. string.char(10, 100, 200, 0) .. u16(1 + 2) .. u16(0)
  local alpha = u16(0) .. u16(256 + 5) .. string.char(10, 200) .. u16(0)
  local flag = SELF_DEST + USE_SCALE + USE_COLOR + USE_ALPHA
  local compiled, err = compileOne(emitterBase(flag, 0) .. scale .. color .. alpha)
  Assert.notNil(compiled, "looping blocks compile: " .. tostring(err))
  local animations = compiled.particles.emitters[1].animations
  Assert.isTrue(animations.scale.loop, "the scale loop flag is kept")
  Assert.isTrue(animations.color.loop, "the color loop flag is kept")
  Assert.isTrue(animations.color.random, "the random color pick is kept")
  Assert.isTrue(animations.alpha.loop, "the alpha loop flag is kept")
  Assert.equal(animations.alpha.flick, 5, "the alpha flicker stays independent of the loop bit")
  local plainColor = u16(31) .. u16(0) .. string.char(10, 100, 200, 0) .. u16(4) .. u16(0)
  local plain = compileOne(emitterBase(SELF_DEST + USE_COLOR, 0) .. plainColor)
  Assert.isNil(plain.particles.emitters[1].animations.color.random, "an unset random pick stays absent")
  Assert.isNil(plain.particles.emitters[1].animations.color.loop, "an unset loop stays absent")
end

function T.compile_records_the_texture_offset()
  local compiled, err = compileOne(emitterBase(SELF_DEST, 0, 2 * 4, 2048))
  Assert.notNil(compiled, "an offset emitter compiles: " .. tostring(err))
  Assert.deepEqual(
    compiled.particles.emitters[1].textureOffset,
    { mode = 2, x = 0.5, y = 0 },
    "the UV offset keeps its mode and fixed-point offsets"
  )
end

function T.compile_records_child_first_drawing_only_when_set()
  local first = compileOne(emitterBase(SELF_DEST + 2 ^ 21, 0))
  Assert.isTrue(first.particles.emitters[1].drawChildFirst, "the child-first draw flag is kept")
  local plain = compileOne(emitterBase(SELF_DEST, 0))
  Assert.isNil(plain.particles.emitters[1].drawChildFirst, "an unset child-first flag stays absent")
end

-- One 20-byte child block: `flag` selects the child behaviors, with a
-- five-tick life and one particle per tick over texture 0.
local function childBlock(flag)
  return u16(flag) .. u16(0) .. u16(0) .. u16(5) .. string.char(0, 30) .. u16(0) .. u32(1 + 2 ^ 16) .. u32(0)
end

function T.compile_records_the_child_rotation_inheritance_only_when_set()
  local USE_CHILD = 2 ^ 16
  local plain = compileOne(emitterBase(SELF_DEST + USE_CHILD, 0) .. childBlock(0))
  Assert.isNil(plain.particles.emitters[1].child.rotationType, "a child with no rotation carries no rotation type")
  for rotationType = 1, 2 do
    local compiled, err = compileOne(emitterBase(SELF_DEST + USE_CHILD, 0) .. childBlock(rotationType * 8))
    Assert.notNil(compiled, "child rotation type " .. rotationType .. " compiles: " .. tostring(err))
    Assert.equal(
      compiled.particles.emitters[1].child.rotationType,
      rotationType,
      "the child keeps how it inherits the parent rotation"
    )
  end
  Assert.isNil(
    compileOne(emitterBase(SELF_DEST + USE_CHILD, 0) .. childBlock(3 * 8)),
    "a child rotation type the retail generator never handles fails"
  )
end

function T.compile_rejects_mirrored_texture_coordinates()
  Assert.isNil(compileOne(emitterBase(SELF_DEST, 0, 1)), "a mirrored emitter texture fails")
end

-- An emitter base whose axis vector (s16 fixed point, offset 28) is set.
local function emitterBaseWithAxis(flag, x, y, z)
  local base = emitterBase(flag, 0)
  return base:sub(1, 28) .. u16(x) .. u16(y) .. u16(z) .. base:sub(35)
end

function T.compile_accepts_the_emitter_axis_circle_only_with_an_axis_direction()
  local circleAxis3 = SELF_DEST + 3 * 64
  local oriented, err = compileOne(emitterBaseWithAxis(circleAxis3, 0, 4096, 0))
  Assert.notNil(oriented, "an emitter-axis circle with a direction compiles: " .. tostring(err))
  Assert.equal(oriented.particles.emitters[1].circleAxis, 3, "the emitter-axis circle is kept")
  Assert.deepEqual(oriented.particles.emitters[1].axis, { x = 0, y = 1, z = 0 }, "its axis stays in the record")
  Assert.isNil(compileOne(emitterBase(circleAxis3, 0)), "an emitter-axis circle without an axis never compiles")
end

-- A 20-byte child block with the given flag word.
local function childBlock(flag)
  return u16(flag) .. u16(0) .. u16(0) .. u16(10) .. string.char(0, 0) .. u16(0) .. string.char(1, 0, 1, 0) .. u32(0)
end

function T.compile_keeps_child_draw_and_rotation_kinds_and_rejects_the_rest()
  local USE_CHILD = 2 ^ 16
  local plain = compileOne(emitterBase(SELF_DEST + USE_CHILD, 0) .. childBlock(0))
  Assert.equal(plain.particles.emitters[1].child.drawType, 0, "a billboard child keeps draw kind 0")
  Assert.isNil(plain.particles.emitters[1].child.rotationType, "an unrotated child carries no rotation kind")
  local directional = compileOne(emitterBase(SELF_DEST + USE_CHILD, 0) .. childBlock(1 * 128 + 2 * 8))
  Assert.equal(directional.particles.emitters[1].child.drawType, 1, "a directional child keeps its draw kind")
  Assert.equal(directional.particles.emitters[1].child.rotationType, 2, "a spinning child keeps its rotation kind")
  Assert.isNil(
    compileOne(emitterBase(SELF_DEST + USE_CHILD, 0) .. childBlock(2 * 128)),
    "a polygon child never compiles"
  )
  Assert.isNil(
    compileOne(emitterBase(SELF_DEST + USE_CHILD, 0) .. childBlock(3 * 8)),
    "an unknown child rotation kind never compiles"
  )
end

return { tests = T }
