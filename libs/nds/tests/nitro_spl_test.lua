-- Source-independent tests for the JN SPL APS particle container.

local Assert = require("tests.support.Assert")
local Spl = require("libs.nds.src.nitro.particle.Spl")

local T = {}

local function u16(value)
  return string.char(value % 256, math.floor(value / 256) % 256)
end

local function u32(value)
  return u16(value % 65536) .. u16(math.floor(value / 65536))
end

local function aps(emitterRecords, resourceRecords)
  return " APS12_1"
    .. u16(#emitterRecords)
    .. u16(#resourceRecords)
    .. string.rep("\0", 0x20 - 0x0c)
    .. table.concat(emitterRecords)
    .. table.concat(resourceRecords)
end

function T.decodes_emitter_sections_and_embedded_payloads()
  local emitterFlags = 0x00000200 + 0x01000000
  local emitter = u32(emitterFlags) .. string.rep("E", 0x58 - 4) .. string.rep("G", 0x0c) .. string.rep("C", 8)
  local texture = "TEX!"
  local palette = "PAL!"
  local resource = u32(0)
    .. u32(0)
    .. u32(#texture)
    .. u32(0x24)
    .. u32(#palette)
    .. u32(0)
    .. u32(0)
    .. u32(0x24 + #palette)
    .. texture
    .. palette
  local decoded = assert(Spl.decode(aps({ emitter }, { resource })))

  Assert.equal(decoded.format, "APS12_1")
  Assert.equal(#decoded.emitters, 1)
  Assert.equal(decoded.emitters[1].sections[1].role, "color")
  Assert.equal(decoded.emitters[1].calculations[1].role, "gravity")
  Assert.equal(#decoded.resources, 1)
  Assert.equal(decoded.resources[1].texture, texture)
  Assert.equal(decoded.resources[1].palette, palette)
end

function T.skips_the_source_flagged_child_emitter_section()
  local emitterFlags = 0x00010000
  local emitter = u32(emitterFlags) .. string.rep("E", 0x58 - 4)
  local childData = string.rep("C", 0x14)
  local texture = "TEX!"
  local resource = u32(0)
    .. u32(0)
    .. u32(#texture)
    .. u32(0)
    .. u32(0)
    .. u32(0)
    .. u32(0)
    .. u32(0x20 + #texture)
    .. texture
  local decoded = assert(Spl.decode(aps({ emitter .. childData }, { resource })))

  Assert.equal(decoded.resources[1].texture, texture)
end

function T.rejects_truncated_emitter_sections_and_resource_payloads()
  local emitterFlags = 0x00000200
  local truncatedEmitter = u32(emitterFlags) .. string.rep("E", 0x58 - 4)
  local decoded, err = Spl.decode(aps({ truncatedEmitter }, {}))
  Assert.isNil(decoded)
  Assert.equal(assert(err).code, "NITRO_SPL_INVALID")
end

function T.rejects_embedded_payloads_that_escape_the_resource_record()
  local texture = "TEX!"
  local tooShort = u32(0)
    .. u32(0)
    .. u32(#texture)
    .. u32(0)
    .. u32(0)
    .. u32(0)
    .. u32(0)
    .. u32(0x20 + #texture - 1)
    .. texture
  local decoded, err = Spl.decode(aps({}, { tooShort }))

  Assert.isNil(decoded)
  Assert.equal(assert(err).code, "NITRO_SPL_INVALID")
end

return { tests = T }
