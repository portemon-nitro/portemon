-- Synthetic tests for generic Nitro G2D resource-bank decoding.

local Assert = require("tests.support.Assert")
local MultiCell = require("libs.nds.src.nitro.g2d.MultiCell")
local MultiCellAnimation = require("libs.nds.src.nitro.g2d.MultiCellAnimation")
local NitroBuilder = require("tests.support.NitroBuilder")

local T = {}

local function swapped(value)
  return string.reverse(value)
end

local function file(magic, blockMagic, body)
  local blockSize = 8 + #body
  local fileSize = 0x10 + blockSize
  return swapped(magic)
    .. NitroBuilder.u16(0xFEFF)
    .. NitroBuilder.u16(0x0100)
    .. NitroBuilder.u32(fileSize)
    .. NitroBuilder.u16(0x10)
    .. NitroBuilder.u16(1)
    .. swapped(blockMagic)
    .. NitroBuilder.u32(blockSize)
    .. body
end

function T.decodes_multicell_bank_entries()
  local body = NitroBuilder.u16(1)
    .. NitroBuilder.u16(0)
    .. NitroBuilder.u32(20)
    .. NitroBuilder.u32(28)
    .. NitroBuilder.u32(0)
    .. NitroBuilder.u32(0)
    .. NitroBuilder.u16(2)
    .. NitroBuilder.u16(0)
    .. NitroBuilder.u32(0)
    .. "data"
  local bank = assert(MultiCell.decode(file("NMCR", "MCBK", body)))
  Assert.equal(bank.cellCount, 1)
  Assert.equal(bank.cells[1].count, 2)
  Assert.equal(bank.cells[1].dataOffset, 28)
  Assert.equal(bank.cells[1].data, "data")
end

function T.decodes_multicell_animation_bank_references()
  local body = NitroBuilder.u16(1)
    .. NitroBuilder.u16(1)
    .. NitroBuilder.u32(24)
    .. NitroBuilder.u32(40)
    .. NitroBuilder.u32(48)
    .. NitroBuilder.u32(0)
    .. NitroBuilder.u32(0)
    .. NitroBuilder.u16(1)
    .. NitroBuilder.u16(0)
    .. NitroBuilder.u32(0x00010001)
    .. NitroBuilder.u32(0)
    .. NitroBuilder.u32(0)
    .. NitroBuilder.u32(0)
    .. NitroBuilder.u16(5)
    .. NitroBuilder.u16(0)
    .. NitroBuilder.u16(17)
  local bank = assert(MultiCellAnimation.decode(file("NANR", "ABNK", body)))
  Assert.equal(bank.animationCount, 1)
  Assert.equal(bank.frameCount, 1)
  Assert.equal(bank.animations[1].frameCount, 1)
  Assert.equal(bank.animations[1].frames[1].duration, 5)
end

function T.rejects_a_multicell_resource_without_its_bank()
  local decoded, err = MultiCell.decode(file("NMCR", "NOPE", string.rep("\0", 20)))
  Assert.isNil(decoded)
  Assert.equal(assert(err).code, "NITRO_G2D_BANK_MISSING")
end

return { tests = T }
