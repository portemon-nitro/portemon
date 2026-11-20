-- Decoder for the project's binary mesh batches (see libs/assets/src/MeshWriter),
-- the inverse of that encoder. Splits cleanly: decode() is pure and validates a
-- batch into plain vertex/index arrays (usable under bare LuaJIT and testable
-- without love); build() turns a decoded batch into a persistent love Mesh.
-- prepareUpload() fills the same floats and indices straight into Data upload
-- buffers in one pass, without building any per-vertex table, and is the
-- entry point the asset preparation worker uses.
--
-- Vertices come out in the render vertex layout order (x,y,z, u,v, nx,ny,nz,
-- r,g,b,a, colorSource) with colors normalized to 0..1 and colorSource kept
-- as a raw 0/1/2 float. Indices stay zero-based as stored, and build()
-- rebases them to love's 1-based vertex map.

local Errors = require("libs.errors.src.Errors")
local GxDisplayList = require("libs.nds.src.gx.GxDisplayList")
local GxGeometryBuffer = require("libs.nds.src.gx.GxGeometryBuffer")
local NativeGxFormat = require("libs.assets.src.model.NativeGxFormat")
local TerrainBoundaryConformer = require("libs.hgss.src.presentation.TerrainBoundaryConformer")
local FieldErrors = require("libs.hgss.src.field.FieldErrors")
local BinaryReader = require("libs.codec.src.BinaryReader")
local G4MeshFormat = require("libs.assets.src.model.G4MeshFormat")
local VertexFormat = require("libs.assets.src.model.VertexFormat")
local SceneDescriptor = require("libs.hgss.src.presentation.SceneDescriptor")
local ffi = require("ffi")

local SceneMesh = {}

local HEADER = G4MeshFormat.HEADER_SIZE -- magic, u16 ver, u16 flags, u32 vcount, u32 icount, u16 stride, u16 iwidth, u32 reserved
local MAGIC = G4MeshFormat.MAGIC
local VERSION = G4MeshFormat.VERSION
local STRIDE = G4MeshFormat.STRIDE

-- The one shared G4M2 header guard: checks magic, version, stride, index
-- width, triangularity and exact body length, and hands both decoding routes
-- the validated counts plus the reader positioned over the same bytes.
-- Raises the same structured error on any malformed field. Pure.
---@param bytes string
---@param context unknown?
---@return { reader: BinaryReader, vertexCount: integer, indexCount: integer, indexWidth: integer }
local function readHeader(bytes, context)
  assert(type(bytes) == "string", "SceneMesh requires a string batch")
  if #bytes < HEADER then
    Errors.raise(FieldErrors.MESH_TOO_SMALL, "mesh shorter than header", { size = #bytes, source = context })
  end
  local r = BinaryReader.new(bytes, "g4mesh")
  local magic = r:ascii(0, 4)
  if magic ~= MAGIC then
    Errors.raise(FieldErrors.MESH_BAD_MAGIC, "expected " .. MAGIC .. " magic, got " .. magic, { source = context })
  end
  local version = r:u16le(4)
  if version ~= VERSION then
    Errors.raise(FieldErrors.MESH_BAD_VERSION, "unsupported mesh version " .. version, { source = context })
  end
  local vertexCount = r:u32le(8)
  local indexCount = r:u32le(12)
  local stride = r:u16le(16)
  local indexWidth = r:u16le(18)
  if stride ~= STRIDE then
    Errors.raise(FieldErrors.MESH_BAD_STRIDE, "expected stride " .. STRIDE .. ", got " .. stride, { source = context })
  end
  if indexWidth ~= G4MeshFormat.indexWidths[1] and indexWidth ~= G4MeshFormat.indexWidths[2] then
    Errors.raise(
      FieldErrors.MESH_BAD_INDEX_WIDTH,
      "index width must be 2 or 4, got " .. indexWidth,
      { source = context }
    )
  end
  if indexCount % 3 ~= 0 then
    Errors.raise(
      FieldErrors.MESH_BAD_INDEX_COUNT,
      "index count not a multiple of 3: " .. indexCount,
      { source = context }
    )
  end

  local expected = HEADER + vertexCount * STRIDE + indexCount * indexWidth
  if expected ~= #bytes then
    Errors.raise(FieldErrors.MESH_BAD_LENGTH, "expected " .. expected .. " bytes, got " .. #bytes, { source = context })
  end
  return { reader = r, vertexCount = vertexCount, indexCount = indexCount, indexWidth = indexWidth }
end

-- Validate and unpack a G4M2 batch into { format, vertexCount, indexCount,
-- vertices, indices }. Raises a structured error on any malformed field. Pure.
function SceneMesh.decode(bytes, context)
  local header = readHeader(bytes, context)
  local r = header.reader
  local vertexCount, indexCount, indexWidth = header.vertexCount, header.indexCount, header.indexWidth

  local vertices = {}
  local off = HEADER
  for i = 1, vertexCount do
    local x, y, z = r:f32le(off), r:f32le(off + 4), r:f32le(off + 8)
    local u, v = r:f32le(off + 12), r:f32le(off + 16)
    local nx, ny, nz = r:f32le(off + 20), r:f32le(off + 24), r:f32le(off + 28)
    local red = r:u8(off + 32) / 255
    local green = r:u8(off + 33) / 255
    local blue = r:u8(off + 34) / 255
    local alpha = r:u8(off + 35) / 255
    local colorSource = r:u8(off + 36)
    if colorSource > 2 then
      Errors.raise(FieldErrors.MESH_BAD_COLOR_SOURCE, "color source out of range at vertex " .. i, { source = context })
    end
    vertices[i] = { x, y, z, u, v, nx, ny, nz, red, green, blue, alpha, colorSource }
    off = off + STRIDE
  end

  local indices = {}
  for i = 1, indexCount do
    local value = (indexWidth == 2) and r:u16le(off) or r:u32le(off)
    if value >= vertexCount then
      Errors.raise(
        FieldErrors.MESH_INDEX_OUT_OF_RANGE,
        "index " .. value .. " >= vertex count " .. vertexCount,
        { source = context }
      )
    end
    indices[i] = value
    off = off + indexWidth
  end

  return {
    format = "g4m2",
    vertexCount = vertexCount,
    indexCount = indexCount,
    indexWidth = indexWidth,
    vertices = vertices,
    indices = indices,
  }
end

-- Build a persistent, static love Mesh from a decoded batch. Rebases the
-- zero-based file indices to love's 1-based vertex map. love-coupled.
function SceneMesh.build(decoded)
  local mesh = love.graphics.newMesh(VertexFormat.LAYOUT, decoded.vertices, "triangles", "static")
  local map = {}
  for i = 1, decoded.indexCount do
    map[i] = decoded.indices[i] + 1
  end
  mesh:setVertexMap(map)
  return mesh
end

-- The packed float count of one render vertex, derived from the authoritative
-- vertex layout so a layout change fails loudly at the pack assertion below
-- instead of silently writing the wrong stride.
local function layoutComponents()
  local total = 0
  for _, attribute in ipairs(VertexFormat.LAYOUT) do
    total = total + attribute[3]
  end
  return total
end

---@class SceneMesh.PreparedMesh
---@field vertexData love.ByteData contiguous float upload buffer in VertexFormat.LAYOUT order
---@field indexData love.ByteData zero-based index upload buffer
---@field vertexCount integer
---@field indexCount integer
---@field indexType "uint16"|"uint32"
---@field centerX number
---@field centerY number
---@field centerZ number
---@field minX number
---@field maxX number
---@field minY number
---@field maxY number
---@field minZ number
---@field maxZ number

-- Decode a G4M2 batch and pack it into Data upload buffers without creating
-- any GPU object: vertices as contiguous floats in VertexFormat.LAYOUT order
-- and indices zero-based at the decoded 16/32-bit width, plus the same
-- model-space center/AABB the GPU pool caches per geometry path. Pure apart
-- from the Data allocation, so it runs on a worker thread.
---@param bytes string
---@param context unknown?
---@return SceneMesh.PreparedMesh
function SceneMesh.prepareUpload(bytes, context)
  local header = readHeader(bytes, context)
  local vertexCount, indexCount, indexWidth = header.vertexCount, header.indexCount, header.indexWidth
  -- An empty batch carries no vertices to fold, so the shared geometry fold
  -- reports it exactly like the synchronous pool path instead of letting
  -- the empty upload allocation fail with a host error.
  if vertexCount == 0 then
    SceneDescriptor.meshGeometry({})
  end
  local components = layoutComponents()
  local vertexData = love.data.newByteData(vertexCount * components * ffi.sizeof("float"))
  local indexData = love.data.newByteData(indexCount * indexWidth)
  -- The input string stays referenced as a parameter for the whole call,
  -- so this borrowed byte view and the two owned upload buffers below are
  -- alive for every read and write. No pointer survives the return.
  local source = ffi.cast("const uint8_t *", bytes)
  local floats = ffi.cast("float *", vertexData:getFFIPointer())
  local r = header.reader
  local minx, miny, minz = math.huge, math.huge, math.huge
  local maxx, maxy, maxz = -math.huge, -math.huge, -math.huge
  for vertexIndex = 0, vertexCount - 1 do
    local off = HEADER + vertexIndex * STRIDE
    -- Floats come from the bounds-checked little-endian reader (exact and
    -- safe on unaligned packed offsets); the single bytes below are plain
    -- aligned-safe byte loads through the borrowed view.
    local x, y, z = r:f32le(off), r:f32le(off + 4), r:f32le(off + 8)
    local u, v = r:f32le(off + 12), r:f32le(off + 16)
    local nx, ny, nz = r:f32le(off + 20), r:f32le(off + 24), r:f32le(off + 28)
    local red = source[off + 32] / 255
    local green = source[off + 33] / 255
    local blue = source[off + 34] / 255
    local alpha = source[off + 35] / 255
    local colorSource = source[off + 36]
    if colorSource > 2 then
      Errors.raise(FieldErrors.MESH_BAD_COLOR_SOURCE, "color source out of range at vertex " .. (vertexIndex + 1), {
        source = context,
      })
    end
    local base = vertexIndex * components
    floats[base] = x
    floats[base + 1] = y
    floats[base + 2] = z
    floats[base + 3] = u
    floats[base + 4] = v
    floats[base + 5] = nx
    floats[base + 6] = ny
    floats[base + 7] = nz
    floats[base + 8] = red
    floats[base + 9] = green
    floats[base + 10] = blue
    floats[base + 11] = alpha
    floats[base + 12] = colorSource
    -- Same fold order as the shared geometry helper so non-finite
    -- positions settle identically.
    minx = math.min(minx, x)
    maxx = math.max(maxx, x)
    miny = math.min(miny, y)
    maxy = math.max(maxy, y)
    minz = math.min(minz, z)
    maxz = math.max(maxz, z)
  end
  local indexBase = HEADER + vertexCount * STRIDE
  if indexWidth == 2 then
    local indices = ffi.cast("uint16_t *", indexData:getFFIPointer())
    for i = 0, indexCount - 1 do
      local off = indexBase + i * 2
      local value = tonumber(source[off]) + tonumber(source[off + 1]) * 0x100
      if value >= vertexCount then
        Errors.raise(
          FieldErrors.MESH_INDEX_OUT_OF_RANGE,
          "index " .. value .. " >= vertex count " .. vertexCount,
          { source = context }
        )
      end
      indices[i] = value
    end
  else
    local indices = ffi.cast("uint32_t *", indexData:getFFIPointer())
    for i = 0, indexCount - 1 do
      local off = indexBase + i * 4
      local value = tonumber(source[off])
        + tonumber(source[off + 1]) * 0x100
        + tonumber(source[off + 2]) * 0x10000
        + tonumber(source[off + 3]) * 0x1000000
      if value >= vertexCount then
        Errors.raise(
          FieldErrors.MESH_INDEX_OUT_OF_RANGE,
          "index " .. value .. " >= vertex count " .. vertexCount,
          { source = context }
        )
      end
      indices[i] = value
    end
  end
  return {
    vertexData = vertexData,
    indexData = indexData,
    vertexCount = vertexCount,
    indexCount = indexCount,
    indexType = indexWidth == 2 and "uint16" or "uint32",
    centerX = (minx + maxx) / 2,
    centerY = (miny + maxy) / 2,
    centerZ = (minz + maxz) / 2,
    minX = minx,
    maxX = maxx,
    minY = miny,
    maxY = maxy,
    minZ = minz,
    maxZ = maxz,
  }
end

-- ---------------------------------------------------------------------------
-- Native model banks
--
-- A G4GX draw keeps the source display-list command bytes, so the runtime
-- replays them through the shared GX decoder instead of loading expanded
-- triangles. One bank operation reads the bank once and keeps one slice per
-- draw, so selecting several draws of one bank never repeats the bank's decode:
--
--   * each static draw is replayed once, under its own matrix/restore/seed
--     context;
--   * transform-preserving draws that share a command stream, a baked matrix
--     and inherited engine state are replayed once, and each segment draw keeps
--     the pose segment it names;
--   * every terrain-boundary-eligible draw of the bank is repaired together in
--     one conformance pass, exactly the group the producer grouped.
--
-- The slices stay transient: the callers pack them into upload buffers (or
-- reference vertex arrays) and nothing expanded outlives the bank operation.
-- Neutral geometry and the model-space matrices the producer already resolved
-- travel in the bank, so no source model is needed.
-- ---------------------------------------------------------------------------

---@class SceneMesh.NativeDecoded
---@field format "g4gx"
---@field vertexCount integer
---@field indexCount integer
---@field vertices number[][]
---@field indices integer[]

---@class SceneMesh.NativeSlice
---@field arena GxGeometryBuffer
---@field vertexOffset integer
---@field vertexCount integer
---@field indexOffset integer
---@field indexCount integer
---@field materialIndex integer
---@field preScaled boolean the decoded positions are already in runtime units

-- The geometry-engine state a bank draw inherits before its first command, or
-- nil when the bank carries none (the commands resolve every vertex
-- themselves). Both replay routes seed exactly this state, so a shape that
-- issues no COLOR/NORMAL keeps the material or carried state the producer
-- compiled against.
---@param draw NativeGxFormat.Draw
---@return { color: number[]?, normal: number[]?, colorSource: integer|nil }|nil
local function seededState(draw)
  if draw.seedColorSource == nil and draw.seedNormal == nil then
    return nil
  end
  return { color = draw.seedColor, normal = draw.seedNormal, colorSource = draw.seedColorSource }
end

-- The draw matrix pre-multiplied by the draw's source-to-runtime scale, so the
-- replay lands directly in runtime units: conformance then repairs the same
-- numeric domain the producer repaired, and packing needs no second scale.
---@param matrix number[]
---@param scale number
---@return number[]
local function scaledMatrix(matrix, scale)
  local out = {}
  for index = 1, 16 do
    out[index] = matrix[index] * scale
  end
  return out
end

---@param draw NativeGxFormat.Draw
---@param arena GxGeometryBuffer
---@param scratch GxDisplayList.Scratch
---@param context unknown?
---@return SceneMesh.NativeSlice
local function decodeStaticSlice(draw, arena, scratch, context)
  local options = {
    arena = arena,
    scratch = scratch,
    collectCommands = false,
    context = context,
    -- The producer refuses to publish a draw whose vertices end without a
    -- resolved color source; the replay holds the same contract, so a bank that
    -- lost its inherited state fails loudly instead of rendering a default.
    requireColorSource = true,
  }
  local scale = draw.positionScale or 1
  options.matrix = draw.matrix and scaledMatrix(draw.matrix, scale) or nil
  if draw.restoreStack ~= nil then
    local scaled = {}
    for slot, slotMatrix in pairs(draw.restoreStack) do
      scaled[slot] = scaledMatrix(slotMatrix, scale)
    end
    options.restoreStack = scaled
  end
  options.initialState = seededState(draw)
  local geom, err = GxDisplayList.decode(draw.commands, options)
  if err ~= nil then
    error(err)
  end
  assert(geom)
  local slice = geom.slice
  return {
    arena = slice.arena,
    vertexOffset = slice.vertexOffset,
    vertexCount = slice.vertexCount,
    indexOffset = slice.indexOffset,
    indexCount = slice.indexCount,
    materialIndex = draw.materialIndex,
    preScaled = true,
  }
end

-- Replay one transform-preserving command stream once, keeping every pose
-- segment it produces. A bank draw carrying a matrix (a billboard's
-- pose-independent post-BB bake) folds it into the vertices exactly like the
-- reference mesh compile; every other segment defers its pose-derived matrix
-- to the draw state its sources name. The inherited color/normal state is
-- seeded the same way.
---@param draw NativeGxFormat.Draw
---@param arena GxGeometryBuffer
---@param scratch GxDisplayList.Scratch
---@param context unknown?
---@return GxDynamicGeometrySlice[]
local function decodeDynamicSegments(draw, arena, scratch, context)
  local geom, err = GxDisplayList.decode(draw.commands, {
    arena = arena,
    scratch = scratch,
    collectCommands = false,
    context = context,
    dynamic = true,
    matrix = draw.matrix,
    initialState = seededState(draw),
    requireColorSource = true,
  })
  if err ~= nil then
    error(err)
  end
  assert(geom)
  return geom.segments
end

-- The identity of one transform-preserving replay: every semantic input that
-- reaches the packed vertices. Two draws of one command stream replay once only
-- when they also share the baked matrix and the inherited engine state; draws
-- that differ in either keep their own replay.
---@param draw NativeGxFormat.Draw
---@return string
local function dynamicReplayKey(draw)
  local parts = { draw.commands }
  if draw.matrix ~= nil then
    for index = 1, 16 do
      parts[#parts + 1] = string.format("%.17g", draw.matrix[index])
    end
  end
  if draw.seedColorSource ~= nil or draw.seedNormal ~= nil then
    parts[#parts + 1] = tostring(draw.seedColorSource)
    for _, component in ipairs(draw.seedColor or {}) do
      parts[#parts + 1] = tostring(component)
    end
    for _, component in ipairs(draw.seedNormal or {}) do
      parts[#parts + 1] = string.format("%.17g", component)
    end
  end
  return table.concat(parts, "\0")
end

--- One segment draw's slice out of its replayed command stream.
---@param draw NativeGxFormat.Draw
---@param segments GxDynamicGeometrySlice[]
---@return SceneMesh.NativeSlice
local function dynamicSlice(draw, segments)
  local segmentIndex = assert(draw.segmentIndex)
  local segment = segments[segmentIndex + 1]
  if not segment then
    Errors.raise(
      "SCENE_MESH_NATIVE_SEGMENT_MISSING",
      "native draw names pose segment " .. tostring(segmentIndex) .. " that its commands do not produce",
      { segmentIndex = segmentIndex }
    )
  end
  if segment.indexCount == 0 then
    Errors.raise("SCENE_MESH_NATIVE_EMPTY_SEGMENT", "native draw names an empty pose segment", {
      segmentIndex = segmentIndex,
    })
  end
  return {
    arena = segment.arena,
    vertexOffset = segment.vertexOffset,
    vertexCount = segment.vertexCount,
    indexOffset = segment.indexOffset,
    indexCount = segment.indexCount,
    materialIndex = draw.materialIndex,
    preScaled = false,
  }
end

--- Replay every draw of one bank into one arena, replaying each distinct decode
--- context exactly once, then repair the bank's terrain group once.
---@param bytes string|love.Data
---@param context unknown?
---@return NativeGxFormat.Bank bank
---@return SceneMesh.NativeSlice[] slices indexed by drawIndex + 1
local function decodeNativeBankSlices(bytes, context)
  local bank, readError = NativeGxFormat.read(bytes)
  if bank == nil then
    error(readError)
  end
  local arena = GxGeometryBuffer.new()
  local scratch = GxDisplayList.newScratch()
  local slices = {}
  local eligible = {}
  local dynamicGroups = {}
  for index, draw in ipairs(bank.draws) do
    local slice
    if draw.segmentIndex == nil then
      slice = decodeStaticSlice(draw, arena, scratch, context)
    else
      local key = dynamicReplayKey(draw)
      local segments = dynamicGroups[key]
      if segments == nil then
        segments = decodeDynamicSegments(draw, arena, scratch, context)
        dynamicGroups[key] = segments
      end
      slice = dynamicSlice(draw, segments)
    end
    slices[index] = slice
    if draw.terrainBoundaryEligible then
      eligible[#eligible + 1] = slice
    end
  end
  if #eligible > 1 then
    TerrainBoundaryConformer.conform(eligible)
  end
  return bank, slices
end

---@class SceneMesh.NativeBank
---@field format "g4gx"
---@field drawCount integer
---@field draws SceneMesh.NativeDecoded[] indexed by drawIndex + 1

---@class SceneMesh.PreparedBank
---@field draws SceneMesh.PreparedMesh[] indexed by drawIndex + 1

-- One draw's slice as render-layout vertex arrays, for the synchronous pool
-- path: the same values the prepared upload buffers carry, in the same order.
---@param draw NativeGxFormat.Draw
---@param slice SceneMesh.NativeSlice
---@param context unknown?
---@return SceneMesh.NativeDecoded
local function decodedDraw(draw, slice, context)
  local arena = slice.arena
  local numeric = assert(arena.numeric)
  local attrib = assert(arena.attrib)
  local indices = assert(arena.indices)
  local vertexCount, indexCount = slice.vertexCount, slice.indexCount
  if vertexCount == 0 then
    SceneDescriptor.meshGeometry({})
  end
  local positionScale = slice.preScaled and 1 or (draw.positionScale or 1)
  local uScale = draw.texWidth and draw.texWidth > 0 and (1 / draw.texWidth) or 1
  local vScale = draw.texHeight and draw.texHeight > 0 and (1 / draw.texHeight) or 1
  local vertices = {}
  for offset = 0, vertexCount - 1 do
    local v = numeric[slice.vertexOffset + offset]
    local a = attrib[slice.vertexOffset + offset]
    local source = a.colorSource
    if source == nil then
      Errors.raise(FieldErrors.MESH_BAD_COLOR_SOURCE, "native draw decoded a vertex without a colour source", {
        source = context,
      })
    end
    vertices[offset + 1] = {
      v.x * positionScale,
      v.y * positionScale,
      v.z * positionScale,
      v.u * uScale,
      v.v * vScale,
      v.nx,
      v.ny,
      v.nz,
      a.r / 255,
      a.g / 255,
      a.b / 255,
      a.a / 255,
      source,
    }
  end
  -- Decoded indices are already zero-based inside the slice (the decoder
  -- stores each vertex's run-relative position), so nothing is rebased here.
  local outIndices = {}
  for offset = 0, indexCount - 1 do
    outIndices[offset + 1] = indices[slice.indexOffset + offset]
  end
  return {
    format = "g4gx",
    vertexCount = vertexCount,
    indexCount = indexCount,
    vertices = vertices,
    indices = outIndices,
  }
end

-- One draw's slice packed straight into the GPU upload buffers: no per-vertex
-- Lua table is created.
---@param draw NativeGxFormat.Draw
---@param slice SceneMesh.NativeSlice
---@param context unknown?
---@return SceneMesh.PreparedMesh
local function packedDraw(draw, slice, context)
  local components = layoutComponents()
  local vertexCount, indexCount = slice.vertexCount, slice.indexCount
  if vertexCount == 0 then
    SceneDescriptor.meshGeometry({})
  end
  local arena = slice.arena
  local numeric = assert(arena.numeric)
  local attrib = assert(arena.attrib)
  local indices = assert(arena.indices)
  local positionScale = slice.preScaled and 1 or (draw.positionScale or 1)
  local uScale = draw.texWidth and draw.texWidth > 0 and (1 / draw.texWidth) or 1
  local vScale = draw.texHeight and draw.texHeight > 0 and (1 / draw.texHeight) or 1
  local indexWidth = vertexCount <= 65535 and 2 or 4
  local vertexData = love.data.newByteData(vertexCount * components * ffi.sizeof("float"))
  local indexData = love.data.newByteData(indexCount * indexWidth)
  local floats = ffi.cast("float *", vertexData:getFFIPointer())
  local minx, miny, minz = math.huge, math.huge, math.huge
  local maxx, maxy, maxz = -math.huge, -math.huge, -math.huge
  for offset = 0, vertexCount - 1 do
    local v = numeric[slice.vertexOffset + offset]
    local a = attrib[slice.vertexOffset + offset]
    local source = a.colorSource
    if source == nil then
      Errors.raise(FieldErrors.MESH_BAD_COLOR_SOURCE, "native draw decoded a vertex without a colour source", {
        source = context,
      })
    end
    local x, y, z = v.x * positionScale, v.y * positionScale, v.z * positionScale
    local base = offset * components
    floats[base] = x
    floats[base + 1] = y
    floats[base + 2] = z
    floats[base + 3] = v.u * uScale
    floats[base + 4] = v.v * vScale
    floats[base + 5] = v.nx
    floats[base + 6] = v.ny
    floats[base + 7] = v.nz
    floats[base + 8] = a.r / 255
    floats[base + 9] = a.g / 255
    floats[base + 10] = a.b / 255
    floats[base + 11] = a.a / 255
    floats[base + 12] = source
    minx = math.min(minx, x)
    maxx = math.max(maxx, x)
    miny = math.min(miny, y)
    maxy = math.max(maxy, y)
    minz = math.min(minz, z)
    maxz = math.max(maxz, z)
  end
  -- Decoded indices are already zero-based inside the slice (the decoder
  -- stores each vertex's run-relative position), so nothing is rebased here.
  if indexWidth == 2 then
    local out = ffi.cast("uint16_t *", indexData:getFFIPointer())
    for offset = 0, indexCount - 1 do
      out[offset] = indices[slice.indexOffset + offset]
    end
  else
    local out = ffi.cast("uint32_t *", indexData:getFFIPointer())
    for offset = 0, indexCount - 1 do
      out[offset] = indices[slice.indexOffset + offset]
    end
  end
  return {
    vertexData = vertexData,
    indexData = indexData,
    vertexCount = vertexCount,
    indexCount = indexCount,
    indexType = indexWidth == 2 and "uint16" or "uint32",
    centerX = (minx + maxx) / 2,
    centerY = (miny + maxy) / 2,
    centerZ = (minz + maxz) / 2,
    minX = minx,
    maxX = maxx,
    minY = miny,
    maxY = maxy,
    minZ = minz,
    maxZ = maxz,
  }
end

-- Every draw of one native model bank as render-layout vertex arrays, for the
-- synchronous pool path: one bank read, one replay per distinct decode context,
-- one terrain repair, then one array per draw.
---@param bytes string|love.Data
---@param context unknown?
---@return SceneMesh.NativeBank
function SceneMesh.decodeNativeBank(bytes, context)
  local bank, slices = decodeNativeBankSlices(bytes, context)
  local draws = {}
  for index = 1, bank.drawCount do
    draws[index] = decodedDraw(bank.draws[index], slices[index], context)
  end
  return { format = "g4gx", drawCount = bank.drawCount, draws = draws }
end

-- Every draw of one native model bank packed into GPU upload buffers, for the
-- background preparation worker: one bank read, one replay per distinct decode
-- context, one terrain repair, then one packet per draw.
---@param bytes string|love.Data
---@param context unknown?
---@return SceneMesh.PreparedBank
function SceneMesh.prepareNativeBank(bytes, context)
  local bank, slices = decodeNativeBankSlices(bytes, context)
  local draws = {}
  for index = 1, bank.drawCount do
    draws[index] = packedDraw(bank.draws[index], slices[index], context)
  end
  return { draws = draws }
end

return SceneMesh
