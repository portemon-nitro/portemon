-- Synthetic tests for the retail SPL resource byte decoder. Builds minimal
-- resource members by hand and checks emitter/texture walking, the closed
-- supported-feature gate, and the fatal error paths. No ROM bytes are
-- committed: every blob here is constructed, never extracted.

local Assert = require("tests.support.Assert")
local SplResource = require("libs.nds.src.nitro.spl.SplResource")

local T = {}

local function u16(v)
  v = v % 0x10000
  return string.char(v % 256, math.floor(v / 256) % 256)
end

local function u32(v)
  v = v % 0x100000000
  return string.char(v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256)
end

local function header(resNum, texNum)
  return " APS12_1" .. u16(resNum) .. u16(texNum) .. string.rep("\0", 20)
end

local function emitter(flag, emtrLife, ptclLife, textureIndex)
  local parts = {}
  parts[#parts + 1] = u32(flag)
  parts[#parts + 1] = string.rep("\0", 56)
  parts[#parts + 1] = u16(emtrLife or 10)
  parts[#parts + 1] = u16(ptclLife or 20)
  parts[#parts + 1] = string.rep("\0", 4)
  parts[#parts + 1] = string.char(0, 0, 0, textureIndex or 0)
  parts[#parts + 1] = string.rep("\0", 16)
  local record = table.concat(parts)
  Assert.equal(#record, 88, "the synthetic emitter base matches the retail base size")
  return record
end

-- One 32x32 A5I3 texture block with blank texels and a one-entry palette.
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

local function blob(resNum, texNum, emitters, textures)
  local parts = { header(resNum, texNum) }
  for _, record in ipairs(emitters) do
    parts[#parts + 1] = record
  end
  for _, block in ipairs(textures) do
    parts[#parts + 1] = block
  end
  return table.concat(parts)
end

function T.spl_decoder_walks_one_plain_emitter_and_texture()
  local member = blob(1, 1, { emitter(0, 18, 15, 0) }, { textureBlock() })
  local decoded, err = SplResource.decode(member)
  Assert.notNil(decoded, "the minimal member decodes: " .. tostring(err))
  Assert.equal(#decoded.emitters, 1, "the member carries one emitter")
  Assert.equal(decoded.emitters[1].id, 0, "the emitter keeps its source index")
  Assert.equal(decoded.emitters[1].emitterLife, 18, "the emitter keeps its source lifespan")
  Assert.equal(decoded.emitters[1].particleLife, 15, "the emitter keeps its particle lifespan")
  Assert.equal(decoded.emitters[1].textureIndex, 0, "the emitter keeps its texture selection")
  Assert.equal(#decoded.textures, 1, "the member carries one texture")
  Assert.equal(decoded.textures[1].format, 6, "the texture keeps its texel format")
  Assert.equal(decoded.textures[1].width, 32, "the texture keeps its width")
  Assert.equal(decoded.textures[1].height, 32, "the texture keeps its height")
end

function T.spl_decoder_rejects_an_unexpected_magic()
  local member = "XXXXXXXX" .. u16(1) .. u16(1) .. string.rep("\0", 20) .. emitter(0) .. textureBlock()
  local decoded, err = SplResource.decode(member)
  Assert.isNil(decoded, "a foreign magic never decodes as an SPL resource")
  Assert.notNil(err, "the foreign magic reports its cause")
end

function T.spl_decoder_rejects_implausible_counts()
  local empty = blob(0, 0, {}, {})
  local decoded, err = SplResource.decode(empty)
  Assert.isNil(decoded, "an emitterless member is not a starter resource")
  Assert.notNil(err, "the empty member reports its cause")
end

function T.spl_decoder_rejects_unsupported_animation_and_field_flags()
  for _, flag in ipairs({ 2 ^ 11, 2 ^ 15, 2 ^ 20, 2 ^ 25, 2 ^ 28, 2 ^ 29, 2 ^ 30, 2 ^ 31 }) do
    local member = blob(1, 1, { emitter(flag) }, { textureBlock() })
    local decoded, err = SplResource.decode(member)
    Assert.isNil(decoded, "an unsupported feature bit never decodes silently: " .. tostring(flag))
    Assert.notNil(err, "the unsupported feature reports its emitter context")
  end
end

function T.spl_decoder_accepts_the_observed_anchor_feature_set()
  -- Scale, color, and alpha animation blocks plus a child pointer and the
  -- gravity, magnet, and spin fields are the observed retail vocabulary.
  local flag = 2 ^ 8 + 2 ^ 9 + 2 ^ 10 + 2 ^ 16 + 2 ^ 24 + 2 ^ 26 + 2 ^ 27
  local record = emitter(flag, 18, 15, 0) .. string.rep("\0", 12 + 12 + 8 + 20 + 8 + 16 + 4)
  local member = blob(1, 1, { record }, { textureBlock() })
  local decoded, err = SplResource.decode(member)
  Assert.notNil(decoded, "the observed anchor set decodes: " .. tostring(err))
  Assert.equal(#decoded.emitters[1].fields, 3, "the three observed fields normalize")
end

function T.spl_decoder_rejects_truncation_and_trailing_bytes()
  local member = blob(1, 1, { emitter(0) }, { textureBlock() })
  local cut, cutErr = SplResource.decode(member:sub(1, #member - 10))
  Assert.isNil(cut, "a truncated member never decodes")
  Assert.notNil(cutErr, "the truncation reports its cause")
  local padded, padErr = SplResource.decode(member .. "\0")
  Assert.isNil(padded, "trailing bytes never decode silently")
  Assert.notNil(padErr, "the trailing bytes report their cause")
end

function T.spl_decoder_rejects_a_bad_texture_magic()
  local member = blob(1, 1, { emitter(0) }, { textureBlock() })
  local bad = member:sub(1, 0x20 + 88) .. "XXXX" .. member:sub(0x20 + 88 + 5)
  local decoded, err = SplResource.decode(bad)
  Assert.isNil(decoded, "a corrupt texture block never decodes")
  Assert.notNil(err, "the corrupt texture reports its cause")
end

return { tests = T }
