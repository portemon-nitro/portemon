-- The engine-owned native model bank holds one source model's ordered draw
-- list in a single compact file: each draw record keeps the DS display-list
-- command bytes the runtime GX decoder consumes, plus the normalized draw
-- state that is not already in the scene descriptor. These scenarios pin the
-- published contract (one file per source model, stable zero-based draw order,
-- bounded command spans, no ROM/source identity) and the loud rejection of a
-- malformed bank instead of a partially decoded one.

local Assert = require("tests.support.Assert")

local T = {}

local FORMAT_MODULE = "libs.assets.src.model.NativeGxFormat"

-- The bank format under test. Required lazily so a missing format reports the
-- missing behavior instead of a load error.
local function nativeFormat()
  local ok, mod = pcall(require, FORMAT_MODULE)
  Assert.isTrue(
    ok and type(mod) == "table",
    "the native model bank format is missing: a compiled source model must persist "
      .. "one bounded binary of ordered draw command spans instead of expanded meshes"
  )
  Assert.equal(type(mod.encode), "function", "the native model bank format must expose encode(record)")
  Assert.equal(type(mod.read), "function", "the native model bank format must expose read(bytes)")
  return mod --[[@as table]]
end

local function u32(value)
  return string.char(
    value % 256,
    math.floor(value / 256) % 256,
    math.floor(value / 65536) % 256,
    math.floor(value / 16777216) % 256
  )
end

-- One VTX_16 parameter word pair for model-unit { x, y, z } at 1.3.12 fixed
-- point, the parameter shape a DS display list carries.
local function vtx16(x, y, z)
  local function fx(value)
    return math.floor(value * 4096) % 0x10000
  end
  return u32(fx(x) + fx(y) * 0x10000) .. u32(fx(z))
end

-- BEGIN_VTXS(triangles), three positioned vertices, END_VTXS, packed in the
-- DS geometry FIFO's four-opcode groups with their parameters following.
local function triangleCommands(vertices)
  return string.char(0x40, 0x23, 0x23, 0x23)
    .. u32(0)
    .. vtx16(vertices[1][1], vertices[1][2], vertices[1][3])
    .. vtx16(vertices[2][1], vertices[2][2], vertices[2][3])
    .. vtx16(vertices[3][1], vertices[3][2], vertices[3][3])
    .. string.char(0x41, 0, 0, 0)
end

-- Published bytes cross as a string or as love Data; both satisfy the reader.
---@param value unknown
---@return string
local function rawBytes(value)
  if type(value) == "string" then
    return value
  end
  Assert.equal(type(value), "userdata", "the bank is published as bytes")
  ---@cast value love.Data
  return value:getString()
end

function T.one_bank_round_trips_ordered_draw_commands()
  local Format = nativeFormat()
  local first = triangleCommands({ { 0, 0, 0 }, { 2, 0, 0 }, { 0, 0, 6 } })
  local second = triangleCommands({ { 0, 3, 0 }, { 2, 3, 0 }, { 0, 3, 6 } })

  local encoded = rawBytes(Format.encode({
    draws = {
      {
        commands = first,
        nodeIndex = 0,
        materialIndex = 0,
        shapeIndex = 0,
        transformMode = "static",
        terrainBoundaryEligible = true,
      },
      {
        commands = second,
        nodeIndex = 1,
        materialIndex = 2,
        shapeIndex = 1,
        transformMode = "billboard",
        terrainBoundaryEligible = false,
      },
    },
  }))

  Assert.equal(encoded:sub(1, 4), "G4GX", "the published bank carries its own magic")
  Assert.isNil(encoded:find("land_data", 1, true), "a published bank carries no source archive identity")
  Assert.isNil(encoded:find("NARC", 1, true), "a published bank carries no container grammar")

  local bank, err = Format.read(encoded)
  Assert.isNil(err, "a well-formed bank reads without error")
  Assert.notNil(bank, "a well-formed bank yields a reader")
  Assert.equal(bank.drawCount, 2, "one bank keeps one record per draw of its source model")

  Assert.notNil(bank.draws[1], "draw records are addressed by their zero-based draw index")
  Assert.notNil(bank.draws[2], "draw records are addressed by their zero-based draw index")
  Assert.equal(rawBytes(bank.draws[1].commands), first, "the first draw's command span is preserved byte for byte")
  Assert.equal(rawBytes(bank.draws[2].commands), second, "the second draw's command span is preserved byte for byte")
  Assert.equal(bank.draws[1].nodeIndex, 0, "draw record keeps its node binding")
  Assert.equal(bank.draws[2].nodeIndex, 1, "draw record keeps its node binding")
  Assert.equal(bank.draws[1].materialIndex, 0, "draw record keeps its material binding")
  Assert.equal(bank.draws[2].materialIndex, 2, "draw record keeps its material binding")
  Assert.equal(bank.draws[2].transformMode, "billboard", "draw record keeps its transform mode")
  Assert.isTrue(bank.draws[1].terrainBoundaryEligible, "draw record keeps its terrain boundary eligibility")
  Assert.isFalse(bank.draws[2].terrainBoundaryEligible, "draw record keeps its terrain boundary eligibility")
end

---@param Format table
---@param bytes string
---@param label string
local function assertRejected(Format, bytes, label)
  local ok, bank, err = pcall(Format.read, bytes)
  Assert.isTrue(not ok or bank == nil, "a malformed bank is rejected instead of partially decoded: " .. label)
  Assert.isTrue(not ok or err ~= nil, "a rejected bank reports why: " .. label)
end

function T.malformed_banks_are_rejected()
  local Format = nativeFormat()
  local valid = rawBytes(Format.encode({
    draws = {
      {
        commands = triangleCommands({ { 0, 0, 0 }, { 2, 0, 0 }, { 0, 0, 6 } }),
        nodeIndex = 0,
        materialIndex = 0,
        shapeIndex = 0,
        transformMode = "static",
      },
    },
  }))

  assertRejected(Format, valid:sub(1, 4) .. string.char(9, 0) .. valid:sub(7), "unsupported version")
  assertRejected(Format, valid:sub(1, #valid - 4), "truncated payload")
  assertRejected(Format, valid:sub(1, 12) .. u32(99) .. valid:sub(17), "draw count beyond the payload")
end

return { tests = T }
