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
  local matrix = { 8, 0, 0, 0, 0, 8, 0, 0, 0, 0, 8, 0, 1, 2, 3, 1 }

  local encoded = rawBytes(Format.encode({
    draws = {
      {
        commands = first,
        nodeIndex = 0,
        materialIndex = 0,
        shapeIndex = 0,
        transformMode = "static",
        terrainBoundaryEligible = true,
        seedColorSource = 1,
        seedColor = { 12, 34, 56 },
        seedNormal = { 0, 1, 0 },
      },
      {
        commands = second,
        nodeIndex = 1,
        materialIndex = 2,
        shapeIndex = 1,
        transformMode = "billboard",
        terrainBoundaryEligible = false,
        segmentIndex = 2,
        positionScale = 0.0625,
        matrix = matrix,
        seedColorSource = 2,
        seedColor = { 1, 2, 3 },
        seedNormal = { 0, 0.5, -1 },
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

  local firstDraw, secondDraw = bank.draws[1], bank.draws[2]
  Assert.notNil(firstDraw, "draw records are addressed by their zero-based draw index")
  Assert.notNil(secondDraw, "draw records are addressed by their zero-based draw index")
  Assert.equal(rawBytes(firstDraw.commands), first, "the first draw's command span is preserved byte for byte")
  Assert.equal(rawBytes(secondDraw.commands), second, "the second draw's command span is preserved byte for byte")
  Assert.equal(firstDraw.nodeIndex, 0, "draw record keeps its node binding")
  Assert.equal(secondDraw.nodeIndex, 1, "draw record keeps its node binding")
  Assert.equal(firstDraw.materialIndex, 0, "draw record keeps its material binding")
  Assert.equal(secondDraw.materialIndex, 2, "draw record keeps its material binding")
  Assert.equal(secondDraw.transformMode, "billboard", "draw record keeps its transform mode")
  Assert.isTrue(firstDraw.terrainBoundaryEligible, "draw record keeps its terrain boundary eligibility")
  Assert.isFalse(secondDraw.terrainBoundaryEligible, "draw record keeps its terrain boundary eligibility")

  -- The resolved replay state a draw inherits: the geometry-engine color
  -- source, color and normal, the pose segment, the baked pose-independent
  -- matrix, and the source-to-runtime scale.
  Assert.equal(firstDraw.seedColorSource, 1, "the inherited color source survives the round trip")
  Assert.deepEqual(firstDraw.seedColor, { 12, 34, 56 }, "the inherited color survives the round trip")
  Assert.deepEqual(firstDraw.seedNormal, { 0, 1, 0 }, "the inherited normal survives the round trip")
  Assert.isNil(firstDraw.segmentIndex, "a static draw keeps no pose segment")
  Assert.equal(secondDraw.seedColorSource, 2, "each draw keeps its own inherited color source")
  Assert.deepEqual(secondDraw.seedColor, { 1, 2, 3 }, "each draw keeps its own inherited color")
  Assert.deepEqual(secondDraw.seedNormal, { 0, 0.5, -1 }, "each draw keeps its own inherited normal")
  Assert.equal(secondDraw.segmentIndex, 2, "the pose segment survives the round trip")
  Assert.near(secondDraw.positionScale, 0.0625, 1e-9, "the position scale survives the round trip")
  Assert.deepEqual(secondDraw.matrix, matrix, "the baked matrix survives the round trip")
end

-- Several draws of one bank legitimately share one command stream (the
-- segments of one transform-preserving draw, a shape resubmitted under another
-- state). The bank stores and decodes that stream once.
function T.repeated_command_streams_are_stored_and_decoded_once()
  local Format = nativeFormat()
  local shared = triangleCommands({ { 0, 0, 0 }, { 2, 0, 0 }, { 0, 0, 6 } })
  local other = triangleCommands({ { 0, 3, 0 }, { 2, 3, 0 }, { 0, 3, 6 } })
  local drawsFor = function(second)
    return Format.encode({
      draws = {
        { commands = shared, nodeIndex = 0, materialIndex = 0, shapeIndex = 0 },
        { commands = second, nodeIndex = 0, materialIndex = 1, shapeIndex = 0 },
      },
    })
  end
  local duplicated = drawsFor(shared)
  local distinct = drawsFor(other)
  Assert.equal(#duplicated + #shared, #distinct, "a bank stores one copy of a command stream two draws share")

  local bank = assert(Format.read(duplicated))
  Assert.equal(bank.drawCount, 2, "both draws still keep their own record")
  Assert.equal(rawBytes(bank.draws[1].commands), shared, "the first draw reads its shared stream")
  Assert.equal(rawBytes(bank.draws[2].commands), shared, "the second draw reads the same shared stream")
  Assert.equal(bank.draws[1].materialIndex, 0, "sharing a stream never merges per-draw state")
  Assert.equal(bank.draws[2].materialIndex, 1, "sharing a stream never merges per-draw state")
end

---@param Format table
---@param bytes string
---@param label string
local function assertRejected(Format, bytes, label)
  local ok, bank, err = pcall(Format.read, bytes)
  Assert.isTrue(not ok or bank == nil, "a malformed bank is rejected instead of partially decoded: " .. label)
  Assert.isTrue(not ok or err ~= nil, "a rejected bank reports why: " .. label)
end

-- Runtime model replay borrows the draw command spans out of the caller's own
-- bank bytes: two draws that share one stored stream also share one parsed
-- span, distinct streams stay distinct, and every span addresses the source
-- buffer rather than a copied command string. The authoring reader keeps its
-- string payload for the tooling consumers that still expect it.
function T.view_borrows_command_spans_from_the_source_bytes()
  local Format = nativeFormat()
  Assert.equal(type(Format.view), "function", "runtime model replay must borrow command spans instead of copying them")
  local shared = triangleCommands({ { 0, 0, 0 }, { 2, 0, 0 }, { 0, 0, 6 } })
  local other = triangleCommands({ { 0, 3, 0 }, { 2, 3, 0 }, { 0, 3, 6 } })
  local encoded = rawBytes(Format.encode({
    draws = {
      { commands = shared, nodeIndex = 0, materialIndex = 0, shapeIndex = 0, transformMode = "static" },
      { commands = shared, nodeIndex = 0, materialIndex = 1, shapeIndex = 0, transformMode = "static" },
    },
  }))
  local source = assert(love.data.newByteData(encoded), "published bank bytes must be admissible as Data")
  local bank = assert(Format.view(source))
  Assert.equal(bank.drawCount, 2, "a borrowed bank keeps both draws")
  local first, second = bank.draws[1], bank.draws[2]
  Assert.notNil(first, "draw records stay addressable by their zero-based draw index")
  Assert.notNil(second, "draw records stay addressable by their zero-based draw index")
  Assert.isTrue(first.commands == second.commands, "two draws of one stored stream share one parsed span")
  Assert.equal(first.materialIndex, 0, "borrowing a stream never merges per-draw state")
  Assert.equal(second.materialIndex, 1, "borrowing a stream never merges per-draw state")

  local BinaryView = require("libs.codec.src.BinaryView")
  local ffi = require("ffi")
  local whole = BinaryView.fromData(source, "bank")
  local function assertBorrowed(span, expected, label)
    Assert.equal(type(span.pointer), "function", label .. " is a bounded view, not a copied command string")
    Assert.equal(span:toString(), expected, label .. " carries the same bytes")
    local offset = ffi.cast("const char *", span:pointer()) - ffi.cast("const char *", whole:pointer())
    Assert.isTrue(offset >= 0, label .. " addresses the source buffer instead of a copy")
    Assert.isTrue(offset + span:length() <= source:getSize(), label .. " stays inside the source buffer")
  end
  assertBorrowed(first.commands, shared, "the shared command span")

  local distinctSource = assert(love.data.newByteData(rawBytes(Format.encode({
    draws = {
      { commands = shared, nodeIndex = 0, materialIndex = 0, shapeIndex = 0 },
      { commands = other, nodeIndex = 0, materialIndex = 1, shapeIndex = 0 },
    },
  }))))
  local distinct = assert(Format.view(distinctSource))
  Assert.isFalse(
    distinct.draws[1].commands == distinct.draws[2].commands,
    "distinct stored streams keep distinct spans"
  )

  -- Pose and binding metadata are unchanged by borrowing, and the authoring
  -- reader still hands out copied command strings for its own consumers.
  local matrix = { 8, 0, 0, 0, 0, 8, 0, 0, 0, 0, 8, 0, 1, 2, 3, 1 }
  local posed = assert(Format.view(assert(love.data.newByteData(rawBytes(Format.encode({
    draws = {
      {
        commands = shared,
        nodeIndex = 1,
        materialIndex = 2,
        shapeIndex = 1,
        transformMode = "billboard",
        segmentIndex = 2,
        positionScale = 0.0625,
        matrix = matrix,
      },
    },
  }))))))
  local posedDraw = assert(posed.draws[1])
  Assert.equal(posedDraw.transformMode, "billboard", "the borrowed draw keeps its transform mode")
  Assert.equal(posedDraw.segmentIndex, 2, "the borrowed draw keeps its pose segment")
  Assert.near(posedDraw.positionScale, 0.0625, 1e-9, "the borrowed draw keeps its position scale")
  Assert.deepEqual(posedDraw.matrix, matrix, "the borrowed draw keeps its baked matrix")

  local readBank = assert(Format.read(encoded))
  Assert.equal(type(readBank.draws[1].commands), "string", "the authoring reader keeps its string payload")
  Assert.equal(readBank.draws[1].commands, shared, "the authoring reader reads the same bytes")
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
