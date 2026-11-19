-- SceneMesh.decode is the inverse of MeshWriter.encode: round-trip a known
-- batch and confirm every field survives, then exercise each validation guard.

local Assert = require("tests.support.Assert")
local ffi = require("ffi")
local MeshWriter = require("libs.assets.src.model.MeshWriter")
local G4MeshFormat = require("libs.assets.src.model.G4MeshFormat")
local SceneMesh = require("libs.hgss.src.presentation.SceneMesh")
local VertexFormat = require("libs.assets.src.model.VertexFormat")

-- The prepared vertex float count is derived from VertexFormat.LAYOUT (never
-- hand-copied), so a future layout change fails this test loudly instead of
-- silently packing the wrong stride.
local function componentsPerVertex()
  local total = 0
  for _, attribute in ipairs(VertexFormat.LAYOUT) do
    total = total + attribute[3]
  end
  return total
end

local function throwsCode(code, fn)
  local ok, err = pcall(fn)
  Assert.isFalse(ok, "expected error " .. code)
  Assert.equal(type(err) == "table" and err.code or err, code)
end

-- Two triangles (a quad), colors chosen so /255 round-trips exactly.
local function sampleBatch()
  local vertices = {}
  for i = 0, 3 do
    vertices[i + 1] = {
      x = i,
      y = i * 2,
      z = -i,
      u = 0.5,
      v = 0.25,
      nx = 0,
      ny = 1,
      nz = 0,
      r = 255,
      g = 0,
      b = 128,
      a = 255,
      colorSource = i % 3,
    }
  end
  return { vertices = vertices, indices = { 0, 1, 2, 0, 2, 3 } }
end

-- Overwrite one byte at a zero-based offset, keeping the total length fixed.
local function patchByte(bytes, zeroBasedOffset, value)
  return bytes:sub(1, zeroBasedOffset) .. string.char(value) .. bytes:sub(zeroBasedOffset + 2)
end

-- Probe shape for the negative GPU-object assertions below: prepareUpload
-- returns the packed upload buffers only, so the love handles must be absent.
---@class SceneMeshPreparedProbe : SceneMesh.PreparedMesh
---@field mesh unknown?
---@field image unknown?


-- ---- native model banks -------------------------------------------------
--
-- A G4GX bank keeps the display-list command bytes, so the runtime replays
-- them. These fixtures pin the work a bank operation performs: one replay per
-- distinct decode context and one terrain repair for the whole bank, whatever
-- number of draws a scene later selects.

local NativeGxFormat = require("libs.assets.src.model.NativeGxFormat")
local GxDisplayList = require("libs.nds.src.gx.GxDisplayList")
local TerrainBoundaryConformer = require("libs.hgss.src.presentation.TerrainBoundaryConformer")

local function gxU32(value)
  return string.char(
    value % 256,
    math.floor(value / 256) % 256,
    math.floor(value / 65536) % 256,
    math.floor(value / 16777216) % 256
  )
end

local function gxVertex(gx, x, y, z)
  return gxU32(gx.fixed(x) + gx.fixed(y) * 0x10000) .. gxU32(gx.fixed(z))
end

local GX_FIXED = {
  fixed = function(value)
    return math.floor(value * 4096) % 0x10000
  end,
}

-- BEGIN_VTXS(quads), one normal plus one VTX_16 per corner, END_VTXS, packed
-- into the geometry FIFO's four-opcode groups.
local function gxQuad(vertices)
  local ops, params = { 0x40 }, { gxU32(1) }
  for _, vertex in ipairs(vertices) do
    ops[#ops + 1], params[#params + 1] = 0x21, gxU32(0x00000FFF)
    ops[#ops + 1], params[#params + 1] = 0x22, gxU32(0)
    ops[#ops + 1], params[#params + 1] = 0x23, gxVertex(GX_FIXED, vertex[1], vertex[2], vertex[3])
  end
  ops[#ops + 1], params[#params + 1] = 0x41, ""
  while #ops % 4 ~= 0 do
    ops[#ops + 1], params[#params + 1] = 0x00, ""
  end
  local out = {}
  for group = 0, #ops / 4 - 1 do
    local opcodeBytes = {}
    for slot = 1, 4 do
      opcodeBytes[slot] = string.char(ops[group * 4 + slot])
    end
    out[#out + 1] = table.concat(opcodeBytes)
    for slot = 1, 4 do
      out[#out + 1] = params[group * 4 + slot]
    end
  end
  return table.concat(out)
end

-- One terrain bank: two eligible draws sharing the boundary x=0 (the coarse
-- side's z span is broken at z=2 by the fine neighbour) plus a third eligible
-- draw and one ineligible draw that must not take part in the repair.
local function terrainBank()
  return NativeGxFormat.encode({
    draws = {
      {
        commands = gxQuad({ { -4, 1, 0 }, { 0, 1, 0 }, { 0, 1, 4 }, { -4, 1, 4 } }),
        nodeIndex = 0,
        materialIndex = 0,
        shapeIndex = 0,
        transformMode = "static",
        terrainBoundaryEligible = true,
      },
      {
        commands = gxQuad({ { 0, 1, 0 }, { 4, 1, 0 }, { 4, 1, 2 }, { 0, 1, 2 } })
          .. gxQuad({ { 0, 1, 2 }, { 4, 1, 2 }, { 4, 1, 4 }, { 0, 1, 4 } }),
        nodeIndex = 0,
        materialIndex = 1,
        shapeIndex = 0,
        transformMode = "static",
        terrainBoundaryEligible = true,
      },
      {
        commands = gxQuad({ { -8, 1, 0 }, { -4, 1, 0 }, { -4, 1, 4 }, { -8, 1, 4 } }),
        nodeIndex = 0,
        materialIndex = 2,
        shapeIndex = 0,
        transformMode = "static",
        terrainBoundaryEligible = true,
      },
      {
        commands = gxQuad({ { 8, 2, 0 }, { 12, 2, 0 }, { 12, 2, 4 }, { 8, 2, 4 } }),
        nodeIndex = 0,
        materialIndex = 3,
        shapeIndex = 0,
        transformMode = "static",
      },
    },
  })
end

-- Runs `fn` with the GX replay and the terrain repair counted, so a bank
-- operation's work multiplicity is observable without asserting internals.
local function countingBankWork(fn)
  local decode = GxDisplayList.decode
  local conform = TerrainBoundaryConformer.conform
  local counts = { replay = 0, conform = 0 }
  GxDisplayList.decode = function(...)
    counts.replay = counts.replay + 1
    return decode(...)
  end
  TerrainBoundaryConformer.conform = function(...)
    counts.conform = counts.conform + 1
    return conform(...)
  end
  local ok, result = pcall(fn)
  GxDisplayList.decode = decode
  TerrainBoundaryConformer.conform = conform
  if not ok then
    error(result, 0)
  end
  return result, counts
end

return {
  tests = {
    ["round-trips a batch through encode/decode"] = function()
      local decoded = SceneMesh.decode(MeshWriter.encode(sampleBatch()))
      Assert.equal(decoded.vertexCount, 4)
      Assert.equal(decoded.indexCount, 6)
      Assert.equal(decoded.indexWidth, 2)
      Assert.deepEqual(decoded.indices, { 0, 1, 2, 0, 2, 3 })
      local v = decoded.vertices[2]
      Assert.equal(v[1], 1) -- x
      Assert.equal(v[2], 2) -- y
      Assert.equal(v[3], -1) -- z
      Assert.equal(v[4], 0.5) -- u
      Assert.equal(v[6], 0) -- nx
      Assert.equal(v[7], 1) -- ny
      Assert.equal(v[9], 1) -- r 255/255
      Assert.equal(v[11], 128 / 255) -- b
      Assert.equal(v[12], 1) -- a
      Assert.equal(v[13], 1) -- colorSource (vertex 2 -> i=1)
    end,

    ["rejects a bad magic"] = function()
      local bytes = MeshWriter.encode(sampleBatch())
      throwsCode("MESH_BAD_MAGIC", function()
        SceneMesh.decode("XXXX" .. bytes:sub(5))
      end)
    end,

    ["rejects a truncated file"] = function()
      local bytes = MeshWriter.encode(sampleBatch())
      throwsCode("MESH_BAD_LENGTH", function()
        SceneMesh.decode(bytes:sub(1, #bytes - 4))
      end)
    end,

    ["rejects trailing bytes"] = function()
      throwsCode("MESH_BAD_LENGTH", function()
        SceneMesh.decode(MeshWriter.encode(sampleBatch()) .. "\0\0\0\0")
      end)
    end,

    ["rejects a header-only truncation"] = function()
      throwsCode("MESH_TOO_SMALL", function()
        SceneMesh.decode("G4M2")
      end)
    end,

    ["rejects a G4M1 file as a stale version"] = function()
      local bytes = MeshWriter.encode(sampleBatch())
      throwsCode("MESH_BAD_MAGIC", function()
        SceneMesh.decode("G4M1" .. bytes:sub(5))
      end)
    end,

    ["rejects a G4M3 file as an unknown magic"] = function()
      local bytes = MeshWriter.encode(sampleBatch())
      throwsCode("MESH_BAD_MAGIC", function()
        SceneMesh.decode("G4M3" .. bytes:sub(5))
      end)
    end,

    ["prepareUpload packs the same vertices/indices/geometry as decode, without a GPU object"] = function()
      local bytes = MeshWriter.encode(sampleBatch())
      local decoded = SceneMesh.decode(bytes)
      local prepared = SceneMesh.prepareUpload(bytes)
      ---@cast prepared SceneMeshPreparedProbe

      Assert.equal(prepared.vertexCount, decoded.vertexCount)
      Assert.equal(prepared.indexCount, decoded.indexCount)
      Assert.equal(prepared.indexType, "uint16", "a 2-byte decoded index width packs as uint16")
      Assert.isNil(prepared.mesh, "prepareUpload never creates a love Mesh")
      Assert.isNil(prepared.image, "prepareUpload never creates a love Image")

      local components = componentsPerVertex()
      Assert.equal(prepared.vertexData:getSize(), decoded.vertexCount * components * ffi.sizeof("float"))
      local floats = ffi.cast("float *", prepared.vertexData:getFFIPointer())
      for vertexIndex = 1, decoded.vertexCount do
        local vertex = decoded.vertices[vertexIndex]
        for component = 1, components do
          Assert.near(
            floats[(vertexIndex - 1) * components + (component - 1)],
            vertex[component],
            1e-6,
            "packed component " .. component .. " of vertex " .. vertexIndex .. " matches decode"
          )
        end
      end

      Assert.equal(prepared.indexData:getSize(), decoded.indexCount * 2)
      local indices = ffi.cast("uint16_t *", prepared.indexData:getFFIPointer())
      for i = 1, decoded.indexCount do
        Assert.equal(indices[i - 1], decoded.indices[i], "packed index " .. i .. " stays zero-based like decode")
      end

      Assert.deepEqual(
        { prepared.centerX, prepared.centerY, prepared.centerZ },
        { 1.5, 3, -1.5 },
        "prepared center matches the geometry fold over decode's vertices"
      )
      Assert.equal(prepared.minX, 0)
      Assert.equal(prepared.maxX, 3)
      Assert.equal(prepared.minY, 0)
      Assert.equal(prepared.maxY, 6)
      Assert.equal(prepared.minZ, -3)
      Assert.equal(prepared.maxZ, 0)
    end,

    ["prepareUpload packs a 32-bit index width as uint32"] = function()
      local vertices = {}
      -- A vertex count above the 16-bit index encoder ceiling forces
      -- MeshWriter to emit 4-byte indices.
      for i = 0, 70000 do
        vertices[i + 1] = {
          x = 0,
          y = 0,
          z = 0,
          u = 0,
          v = 0,
          nx = 0,
          ny = 1,
          nz = 0,
          r = 0,
          g = 0,
          b = 0,
          a = 0,
          colorSource = 0,
        }
      end
      local bytes = MeshWriter.encode({ vertices = vertices, indices = { 0, 70000, 1 } })
      local decoded = SceneMesh.decode(bytes)
      Assert.equal(decoded.indexWidth, 4, "the fixture forces a 32-bit index width")
      local prepared = SceneMesh.prepareUpload(bytes)
      Assert.equal(prepared.indexType, "uint32")
      Assert.equal(prepared.indexData:getSize(), decoded.indexCount * 4)
      local indices = ffi.cast("uint32_t *", prepared.indexData:getFFIPointer())
      for i = 1, decoded.indexCount do
        Assert.equal(indices[i - 1], decoded.indices[i])
      end
    end,

    ["prepareUpload rejects the same malformed input decode rejects"] = function()
      local bytes = MeshWriter.encode(sampleBatch())
      throwsCode("MESH_BAD_MAGIC", function()
        SceneMesh.prepareUpload("XXXX" .. bytes:sub(5))
      end)
    end,

    ["prepareUpload rejects every malformed shape decode rejects with the same code"] = function()
      local valid = MeshWriter.encode(sampleBatch())
      local indexAt = G4MeshFormat.HEADER_SIZE + 4 * G4MeshFormat.STRIDE
      local header = G4MeshFormat.HEADER_SIZE
      local miscounted = patchByte(valid, 12, 4):sub(1, #valid - 4)
      local malformed = {
        "XXXX" .. valid:sub(5),
        patchByte(valid, 4, 9),
        patchByte(valid, 16, 41),
        patchByte(valid, 18, 8),
        valid:sub(1, #valid - 4),
        valid .. "\0",
        valid:sub(1, 10),
        patchByte(valid, indexAt, 4),
        patchByte(valid, header + 36, 7),
        patchByte(patchByte(patchByte(patchByte(valid, 8, 255), 9, 255), 10, 255), 11, 255),
        miscounted,
      }
      for caseIndex, malformedBytes in ipairs(malformed) do
        local decodeOk, decodeErr = pcall(SceneMesh.decode, malformedBytes)
        Assert.isFalse(decodeOk, "decode rejects malformed case " .. caseIndex)
        local decodeCode = type(decodeErr) == "table" and decodeErr.code or decodeErr
        local prepareOk, prepareErr = pcall(SceneMesh.prepareUpload, malformedBytes)
        Assert.isFalse(prepareOk, "direct preparation rejects malformed case " .. caseIndex)
        local prepareCode = type(prepareErr) == "table" and prepareErr.code or prepareErr
        Assert.equal(prepareCode, decodeCode, "direct preparation keeps the decode error for case " .. caseIndex)
      end
      Assert.equal(#malformed, 11, "every malformed shape stays covered")
    end,

    ["prepareUpload keeps non-finite positions exactly like decode"] = function()
      local bytes = MeshWriter.encode(sampleBatch())
      local at = G4MeshFormat.HEADER_SIZE + 1
      local patched = bytes:sub(1, at - 1) .. string.char(0, 0, 0x80, 0x7F) .. bytes:sub(at + 4)
      local decoded = SceneMesh.decode(patched)
      Assert.equal(decoded.vertices[1][1], math.huge)
      local prepared = SceneMesh.prepareUpload(patched)
      Assert.equal(prepared.vertexCount, decoded.vertexCount)
      Assert.equal(prepared.minX, 1)
      Assert.equal(prepared.maxX, math.huge)
      Assert.equal(prepared.centerX, math.huge)
      Assert.equal(prepared.minY, 0)
      Assert.equal(prepared.maxY, 6)
      Assert.equal(prepared.centerY, 3)
      local floats = ffi.cast("float *", prepared.vertexData:getFFIPointer())
      Assert.equal(floats[0], math.huge, "the packed x of the patched vertex stays infinite")
    end,

    ["prepareUpload rejects an empty batch with the geometry error"] = function()
      local headerBytes = "G4M2" .. string.char(2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 40, 0, 2, 0, 0, 0, 0, 0)
      Assert.equal(#headerBytes, G4MeshFormat.HEADER_SIZE)
      local decoded = SceneMesh.decode(headerBytes)
      Assert.equal(decoded.vertexCount, 0)
      Assert.equal(decoded.indexCount, 0)
      throwsCode("SCENE_DESC_EMPTY_MESH", function()
        SceneMesh.prepareUpload(headerBytes)
      end)
    end,

    ["decode trusts producer-validated vertices without a per-vertex finiteness rescan"] = function()
      local bytes = MeshWriter.encode(sampleBatch())
      -- Patch vertex 1 x (first float of the vertex payload) to +inf bits.
      local at = G4MeshFormat.HEADER_SIZE + 1
      local patched = bytes:sub(1, at - 1) .. string.char(0, 0, 0x80, 0x7F) .. bytes:sub(at + 4)
      local decoded = SceneMesh.decode(patched)
      Assert.equal(decoded.vertices[1][1], math.huge)
    end,

    ["encode rejects an out-of-range color source at the producer"] = function()
      local batch = sampleBatch()
      batch.vertices[1].colorSource = 7
      throwsCode("MESH_UNRESOLVED_COLOR_SOURCE", function()
        MeshWriter.encode(batch)
      end)
    end,

    ["rejects a bad stride before allocating"] = function()
      local bytes = patchByte(patchByte(MeshWriter.encode(sampleBatch()), 16, 41), 17, 0)
      throwsCode("MESH_BAD_STRIDE", function()
        SceneMesh.decode(bytes)
      end)
    end,

    ["rejects a bad index width before allocating"] = function()
      local bytes = patchByte(patchByte(MeshWriter.encode(sampleBatch()), 18, 8), 19, 0)
      throwsCode("MESH_BAD_INDEX_WIDTH", function()
        SceneMesh.decode(bytes)
      end)
    end,

    ["rejects an out-of-range index before GPU upload"] = function()
      local bytes = MeshWriter.encode(sampleBatch())
      local indexAt = G4MeshFormat.HEADER_SIZE + 4 * G4MeshFormat.STRIDE
      bytes = patchByte(patchByte(bytes, indexAt, 244), indexAt + 1, 1)
      throwsCode("MESH_INDEX_OUT_OF_RANGE", function()
        SceneMesh.decode(bytes)
      end)
    end,

    ["rejects a huge advertised count before allocating"] = function()
      local bytes = MeshWriter.encode(sampleBatch())
      bytes = patchByte(patchByte(patchByte(patchByte(bytes, 8, 255), 9, 255), 10, 255), 11, 255)
      throwsCode("MESH_BAD_LENGTH", function()
        SceneMesh.decode(bytes)
      end)
    end,

    ["rejects an out-of-range color source"] = function()
      local bytes = patchByte(MeshWriter.encode(sampleBatch()), G4MeshFormat.HEADER_SIZE + 36, 7)
      throwsCode("MESH_BAD_COLOR_SOURCE", function()
        SceneMesh.decode(bytes)
      end)
    end,

    ["a native bank replays each draw once and repairs its terrain group once"] = function()
      local bytes = terrainBank()
      local prepared, prepareWork = countingBankWork(function()
        return SceneMesh.prepareNativeBank(bytes, "scene-mesh-bank")
      end)
      Assert.equal(#prepared.draws, 4, "every draw of the bank comes back as one upload packet")
      Assert.equal(prepareWork.replay, 4, "each distinct draw context is replayed exactly once")
      Assert.equal(prepareWork.conform, 1, "the whole eligible group is repaired in one pass")
      Assert.equal(prepared.draws[1].vertexCount, 5, "the coarse draw adopts the neighbour's breakpoint")
      Assert.equal(prepared.draws[1].indexCount, 9, "the repaired draw expresses the shared breakpoint once")
      Assert.equal(prepared.draws[2].indexCount, 12, "the already-segmented neighbour keeps its four triangles")
      Assert.equal(prepared.draws[4].indexCount, 6, "the ineligible draw is decoded without sibling repair")
      Assert.isNil(prepared.draws[1].mesh, "preparation never realizes a GPU object")

      local decoded, decodeWork = countingBankWork(function()
        return SceneMesh.decodeNativeBank(bytes, "scene-mesh-bank")
      end)
      Assert.equal(decodeWork.replay, 4, "the reference path performs the same single replay per draw")
      Assert.equal(decodeWork.conform, 1, "the reference path repairs the group once")
      Assert.equal(decoded.draws[1].vertexCount, 5, "both paths report the same repaired topology")
      Assert.equal(decoded.draws[1].indexCount, prepared.draws[1].indexCount)
      Assert.equal(decoded.draws[2].indexCount, prepared.draws[2].indexCount)
    end,

    ["a native bank replays one shared command stream for every pose segment"] = function()
      -- One shape whose display list restores matrix slot 2 halfway through:
      -- the transform-preserving replay splits it into two segments, and each
      -- segment draw selects one of them without replaying the shape.
      local commands = gxQuad({ { 0, 1, 0 }, { 4, 1, 0 }, { 4, 1, 1 }, { 0, 1, 1 } })
        .. string.char(0x14, 0, 0, 0)
        .. gxU32(2)
        .. gxQuad({ { 0, 2, 0 }, { 4, 2, 0 }, { 4, 2, 1 }, { 0, 2, 1 } })
      local bytes = NativeGxFormat.encode({
        draws = {
          {
            commands = commands,
            nodeIndex = 0,
            materialIndex = 0,
            shapeIndex = 0,
            transformMode = "static",
            segmentIndex = 0,
            positionScale = 1,
          },
          {
            commands = commands,
            nodeIndex = 0,
            materialIndex = 0,
            shapeIndex = 0,
            transformMode = "static",
            segmentIndex = 1,
            positionScale = 1,
          },
        },
      })
      local prepared, work = countingBankWork(function()
        return SceneMesh.prepareNativeBank(bytes, "scene-mesh-segments")
      end)
      Assert.equal(work.replay, 1, "both pose segments of one shape come from a single replay")
      Assert.equal(#prepared.draws, 2, "each segment draw still gets its own upload packet")
      Assert.equal(prepared.draws[1].indexCount, 6, "the first segment carries its own quad")
      Assert.equal(prepared.draws[2].indexCount, 6, "the second segment carries its own quad")
    end,

    ["a native bank rejects a draw that names a pose segment its shape lacks"] = function()
      local bytes = NativeGxFormat.encode({
        draws = {
          {
            commands = gxQuad({ { 0, 1, 0 }, { 4, 1, 0 }, { 4, 1, 1 }, { 0, 1, 1 } }),
            nodeIndex = 0,
            materialIndex = 0,
            shapeIndex = 0,
            transformMode = "static",
            segmentIndex = 3,
          },
        },
      })
      throwsCode("SCENE_MESH_NATIVE_SEGMENT_MISSING", function()
        SceneMesh.prepareNativeBank(bytes, "scene-mesh-segments")
      end)
    end,
  },
}
