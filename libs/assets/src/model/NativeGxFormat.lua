-- Engine-owned G4GX model bank: one source model's ordered draw list in one
-- compact little-endian file. Each fixed draw record carries the DS
-- display-list command bytes the runtime GX decoder replays, the draw's
-- node/shape/material binding, the transform mode and terrain-boundary
-- eligibility the renderer needs, the texture extent that normalized the UVs,
-- and an optional bounded pose blob holding the draw-time state the producer
-- already resolved (source-independent numbers, never a source pointer or
-- archive identity): the pose-independent matrix a transform-preserving replay
-- bakes, the geometry-engine color/normal state seeded before the commands, and
-- the pose segment the replay keeps. The file stores no triangles: runtime
-- geometry comes from replaying the commands. Pure domain module: no love
-- dependency.

local bit = require("bit")
local BinaryReader = require("libs.codec.src.BinaryReader")
local Errors = require("libs.errors.src.Errors")
local Float32 = require("libs.codec.src.Float32")

local NativeGxFormat = {}

local MAGIC = "G4GX"
local VERSION = 2
-- magic[4], u16 version, u16 reserved, u32 totalBytes, u32 drawCount,
-- u32 drawTableOffset, u32 commandPayloadOffset.
local HEADER_SIZE = 24
-- u32 commandsOffset, u32 commandsLength, u32 poseOffset, u32 poseLength,
-- u32 shapeIndex, u16 nodeIndex, u16 materialIndex, u8 transformMode,
-- u8 flags, u16 texWidth, u16 texHeight, u16 reserved.
local DRAW_RECORD_SIZE = 32
local POSE_HEADER_SIZE = 4
local POSE_MATRIX_SIZE = 64
local POSE_RESTORE_SIZE = 68 -- u16 slot, u16 reserved, 16 * f32
local MAX_RESTORE_SLOTS = 32
local UINT32_MAX = 0xFFFFFFFF

local TRANSFORM_MODES = { static = 0, billboard = 1 }
local TRANSFORM_MODE_NAMES = { [0] = "static", [1] = "billboard" }
local FLAG_TERRAIN_BOUNDARY = 0x01
local POSE_FLAG_MATRIX = 0x01
local POSE_FLAG_SEED = 0x04
local POSE_SEED_SIZE = 4 -- u8 color source plus one, u8 red, u8 green, u8 blue
local POSE_FLAG_SEED_NORMAL = 0x20
local POSE_SEED_NORMAL_SIZE = 12 -- three f32 direction components
local POSE_FLAG_SEGMENT = 0x08
local POSE_SEGMENT_SIZE = 4 -- u16 pose segment index, u16 reserved
local POSE_FLAG_SCALE = 0x10
local POSE_SCALE_SIZE = 4 -- f32 model-space to runtime-unit scale

NativeGxFormat.MAGIC = MAGIC
NativeGxFormat.VERSION = VERSION
NativeGxFormat.HEADER_SIZE = HEADER_SIZE
NativeGxFormat.DRAW_RECORD_SIZE = DRAW_RECORD_SIZE

local function fail(code, message, context)
  Errors.raise(code, message, context)
end

-- A finite integer in the given closed range, or a loud rejection: packed
-- header and record fields are never silently truncated.
local function unsigned(value, limit, name)
  if type(value) ~= "number" or value ~= math.floor(value) or value < 0 or value > limit then
    fail(
      "NATIVE_GX_BAD_FIELD",
      string.format("%s must be an integer in 0..%d, got %s", name, limit, tostring(value)),
      { field = name }
    )
  end
  return value
end

-- A 16-component column-major matrix as the GX decoder consumes it.
local function matrix(value, name)
  if type(value) ~= "table" or #value ~= 16 then
    fail("NATIVE_GX_BAD_FIELD", name .. " must be a 16-component matrix", { field = name })
  end
  for index = 1, 16 do
    local component = value[index]
    if type(component) ~= "number" or component ~= component then
      fail("NATIVE_GX_BAD_FIELD", name .. " has a non-numeric component", { field = name, index = index })
    end
  end
  return value
end

-- Command bytes cross as a string or an owned love Data blob; the encoder
-- keeps them byte-identical.
local function byteString(value, name)
  if type(value) == "string" then
    return value
  end
  if type(value) == "table" then
    local getString = value.getString
    if type(getString) == "function" then
      return getString(value)
    end
  end
  fail("NATIVE_GX_BAD_FIELD", name .. " must be bytes", { field = name })
end

local function align4(value)
  return math.floor((value + 3) / 4) * 4
end

local function u16(value)
  return string.char(value % 256, math.floor(value / 256) % 256)
end

local function u32(value)
  return string.char(
    value % 256,
    math.floor(value / 256) % 256,
    math.floor(value / 65536) % 256,
    math.floor(value / 16777216) % 256
  )
end

local function f32(value)
  return u32(Float32.bits(value))
end

local function restoreSlots(draw)
  local restoreStack = draw.restoreStack
  if restoreStack == nil then
    return {}
  end
  if type(restoreStack) ~= "table" then
    fail("NATIVE_GX_BAD_FIELD", "restoreStack must be a table", { field = "restoreStack" })
  end
  local slots = {}
  for slot in pairs(restoreStack) do
    unsigned(slot, MAX_RESTORE_SLOTS - 1, "restoreStack slot")
    slots[#slots + 1] = slot
  end
  table.sort(slots)
  return slots
end

---@class NativeGxFormat.Draw
---@field commands string|BinaryView display-list command bytes
---@field commandSpanId string|nil bank-local identity of the stored command stream the draw replays
---@field nodeIndex integer node the model binds this draw to
---@field materialIndex integer material the draw is submitted with
---@field shapeIndex integer source shape the commands came from
---@field transformMode "static"|"billboard"
---@field terrainBoundaryEligible boolean the draw takes part in boundary repair
---@field texWidth integer|nil UV normalization divisor used for this draw
---@field texHeight integer|nil
---@field matrix number[]|nil tile-space position matrix the producer resolved
---@field restoreStack { [integer]: number[] }|nil GX matrix-stack slots the commands restore
---@field seedColorSource integer|nil geometry-engine color source seeded before the commands (0 literal, 1 normal-lit, 2 field diffuse)
---@field seedColor number[]|nil seeded vertex color as { r, g, b } bytes
---@field seedNormal number[]|nil seeded geometry-engine normal, the direction a shape inherits before issuing one
---@field segmentIndex integer|nil pose segment the runtime keeps from a transform-preserving decode
---@field positionScale number|nil factor the runtime applies to decoded positions (source units to runtime units)

local function poseBytes(draw, slots)
  local hasMatrix = draw.matrix ~= nil
  local hasSeed = draw.seedColorSource ~= nil
  local hasSeedNormal = draw.seedNormal ~= nil
  local hasSegment = draw.segmentIndex ~= nil
  local hasScale = draw.positionScale ~= nil
  if not hasMatrix and not hasSeed and not hasSeedNormal and not hasSegment and not hasScale and #slots == 0 then
    return 0, nil
  end
  local flags = 0
  if hasSeed then
    flags = bit.bor(flags, POSE_FLAG_SEED)
  end
  if hasSeedNormal then
    flags = bit.bor(flags, POSE_FLAG_SEED_NORMAL)
  end
  if hasSegment then
    flags = bit.bor(flags, POSE_FLAG_SEGMENT)
  end
  if hasScale then
    flags = bit.bor(flags, POSE_FLAG_SCALE)
  end
  if hasMatrix then
    flags = bit.bor(flags, POSE_FLAG_MATRIX)
  end
  local chunks = { string.char(flags, #slots, 0, 0) }
  if hasSegment then
    chunks[#chunks + 1] = u16(unsigned(draw.segmentIndex, 0xFFFF, "draw segment index")) .. u16(0)
  end
  if hasScale then
    if type(draw.positionScale) ~= "number" or draw.positionScale ~= draw.positionScale then
      fail("NATIVE_GX_BAD_FIELD", "draw position scale must be a number", {})
    end
    chunks[#chunks + 1] = f32(draw.positionScale)
  end
  if hasSeed then
    local color = draw.seedColor or { 255, 255, 255 }
    chunks[#chunks + 1] = string.char(
      unsigned(draw.seedColorSource, 2, "draw seed color source") + 1,
      unsigned(color[1] or 255, 255, "draw seed red"),
      unsigned(color[2] or 255, 255, "draw seed green"),
      unsigned(color[3] or 255, 255, "draw seed blue")
    )
  end
  if hasSeedNormal then
    local normal = draw.seedNormal
    if type(normal) ~= "table" or #normal ~= 3 then
      fail("NATIVE_GX_BAD_FIELD", "draw seed normal must be three components", { field = "seedNormal" })
    end
    for index = 1, 3 do
      if type(normal[index]) ~= "number" or normal[index] ~= normal[index] then
        fail("NATIVE_GX_BAD_FIELD", "draw seed normal has a non-numeric component", { index = index })
      end
    end
    chunks[#chunks + 1] = f32(normal[1]) .. f32(normal[2]) .. f32(normal[3])
  end
  local function append(values)
    local parts = {}
    for index = 1, 16 do
      parts[index] = f32(values[index])
    end
    chunks[#chunks + 1] = table.concat(parts)
  end
  if hasMatrix then
    append(draw.matrix)
  end
  for _, slot in ipairs(slots) do
    local values = matrix(draw.restoreStack[slot], "restoreStack matrix")
    chunks[#chunks + 1] = u16(slot) .. u16(0)
    append(values)
  end
  local blob = table.concat(chunks)
  return #blob, blob
end

-- Deterministic, bounded encoding of an ordered draw list: fixed header,
-- fixed draw table, then the distinct command spans once each in first-use
-- order, then the pose blobs in draw order. Several draws of one bank
-- legitimately share a command stream (the segments of one transform-preserving
-- dynamic draw, a static shape submitted under two states), so a span is stored
-- and read once per bank. Every offset is derived here, so an unchanged record
-- always produces identical bytes.
---@param record { draws: NativeGxFormat.Draw[] }
---@return string
function NativeGxFormat.encode(record)
  if type(record) ~= "table" or type(record.draws) ~= "table" then
    fail("NATIVE_GX_BAD_RECORD", "the native model bank record needs a draw list", {})
  end
  local draws = record.draws
  local drawCount = #draws
  unsigned(drawCount, UINT32_MAX, "draw count")

  local commandPayloadOffset = align4(HEADER_SIZE + drawCount * DRAW_RECORD_SIZE)
  local prepared = {}
  local spanOffsets = {}
  local uniqueSpans = {}
  local cursor = commandPayloadOffset
  for index, draw in ipairs(draws) do
    if type(draw) ~= "table" then
      fail("NATIVE_GX_BAD_RECORD", "draw " .. index .. " is not a record", { drawIndex = index - 1 })
    end
    local commands = byteString(draw.commands, "draw commands")
    if #commands == 0 then
      fail("NATIVE_GX_BAD_RECORD", "draw " .. index .. " carries no command bytes", { drawIndex = index - 1 })
    end
    local commandsOffset = spanOffsets[commands]
    if commandsOffset == nil then
      commandsOffset = cursor
      spanOffsets[commands] = commandsOffset
      uniqueSpans[#uniqueSpans + 1] = commands
      cursor = cursor + #commands
    end
    local transformMode = draw.transformMode or "static"
    local encodedMode = TRANSFORM_MODES[transformMode]
    if encodedMode == nil then
      fail(
        "NATIVE_GX_BAD_FIELD",
        "draw transform mode is unknown: " .. tostring(transformMode),
        { drawIndex = index - 1 }
      )
    end
    prepared[index] = {
      draw = draw,
      commandsOffset = commandsOffset,
      commandsLength = #commands,
      encodedMode = encodedMode,
      nodeIndex = unsigned(draw.nodeIndex or 0, 0xFFFF, "node index"),
      materialIndex = unsigned(draw.materialIndex or 0, 0xFFFF, "material index"),
      shapeIndex = unsigned(draw.shapeIndex or 0, UINT32_MAX, "shape index"),
      texWidth = unsigned(draw.texWidth or 0, 0xFFFF, "texture width"),
      texHeight = unsigned(draw.texHeight or 0, 0xFFFF, "texture height"),
      terrainBoundaryEligible = draw.terrainBoundaryEligible == true,
    }
  end
  for _, item in ipairs(prepared) do
    local slots = restoreSlots(item.draw)
    local poseLength, pose = poseBytes(item.draw, slots)
    item.poseLength = poseLength
    item.pose = pose
    item.poseOffset = poseLength > 0 and cursor or 0
    cursor = cursor + poseLength
  end

  local chunks =
    { MAGIC, u16(VERSION), u16(0), u32(cursor), u32(drawCount), u32(HEADER_SIZE), u32(commandPayloadOffset) }
  for _, item in ipairs(prepared) do
    chunks[#chunks + 1] = u32(item.commandsOffset)
      .. u32(item.commandsLength)
      .. u32(item.poseOffset)
      .. u32(item.poseLength)
      .. u32(item.shapeIndex)
      .. u16(item.nodeIndex)
      .. u16(item.materialIndex)
      .. string.char(item.encodedMode, item.terrainBoundaryEligible and FLAG_TERRAIN_BOUNDARY or 0)
      .. u16(item.texWidth)
      .. u16(item.texHeight)
      .. u16(0)
  end
  local tableEnd = HEADER_SIZE + drawCount * DRAW_RECORD_SIZE
  if tableEnd < commandPayloadOffset then
    chunks[#chunks + 1] = string.rep("\0", commandPayloadOffset - tableEnd)
  end
  for _, commands in ipairs(uniqueSpans) do
    chunks[#chunks + 1] = commands
  end
  for _, item in ipairs(prepared) do
    if item.pose ~= nil then
      chunks[#chunks + 1] = item.pose
    end
  end
  local encoded = table.concat(chunks)
  assert(#encoded == cursor, "native model bank encoded an unexpected size")
  return encoded
end

---@class NativeGxFormat.Bank
---@field drawCount integer
---@field draws NativeGxFormat.Draw[]

local function readMatrix(reader, offset)
  local values = {}
  for index = 0, 15 do
    values[index + 1] = reader:f32le(offset + index * 4)
  end
  return values
end

-- One draw record. `span(offset, length)` decides whether the command stream is
-- copied into a string (authoring read) or borrowed as a bounded view (runtime
-- replay); the span cache is bank-local, so draws that share one stored stream
-- share one parse and one `commandSpanId`.
---@param reader BinaryReader
---@param recordOffset integer
---@param commandCache table<string, string|BinaryView>
---@param span fun(offset: integer, length: integer): string|BinaryView
---@return NativeGxFormat.Draw
local function readDraw(reader, recordOffset, commandCache, span)
  local commandsOffset = reader:u32le(recordOffset)
  local commandsLength = reader:u32le(recordOffset + 4)
  local poseOffset = reader:u32le(recordOffset + 8)
  local poseLength = reader:u32le(recordOffset + 12)
  local shapeIndex = reader:u32le(recordOffset + 16)
  local nodeIndex = reader:u16le(recordOffset + 20)
  local materialIndex = reader:u16le(recordOffset + 22)
  local transformMode = reader:u8(recordOffset + 24)
  local flags = reader:u8(recordOffset + 25)
  local texWidth = reader:u16le(recordOffset + 26)
  local texHeight = reader:u16le(recordOffset + 28)
  local modeName = TRANSFORM_MODE_NAMES[transformMode]
  if modeName == nil then
    fail("NATIVE_GX_BAD_FIELD", "draw record has an unknown transform mode", { transformMode = transformMode })
  end
  if commandsLength == 0 or commandsLength % 4 ~= 0 then
    fail("NATIVE_GX_BAD_LENGTH", "draw command span is not a whole command word", { length = commandsLength })
  end
  if commandsOffset % 4 ~= 0 then
    fail("NATIVE_GX_BAD_OFFSET", "draw command span is not word aligned", { offset = commandsOffset })
  end
  -- Draws legitimately share one stored command span (see encode); decode the
  -- bytes once per span so a shared stream is copied once, not per draw.
  local spanKey = commandsOffset .. ":" .. commandsLength
  local commands = commandCache[spanKey]
  if commands == nil then
    commands = span(commandsOffset, commandsLength)
    commandCache[spanKey] = commands
  end
  local draw = {
    commands = commands,
    commandSpanId = spanKey,
    nodeIndex = nodeIndex,
    materialIndex = materialIndex,
    shapeIndex = shapeIndex,
    transformMode = modeName,
    terrainBoundaryEligible = bit.band(flags, FLAG_TERRAIN_BOUNDARY) ~= 0,
    texWidth = texWidth,
    texHeight = texHeight,
  }
  if poseLength > 0 then
    if poseOffset % 4 ~= 0 then
      fail("NATIVE_GX_BAD_OFFSET", "draw pose blob is not word aligned", { offset = poseOffset })
    end
    reader:assertRange(poseOffset, poseLength, "draw pose")
    local poseFlags = reader:u8(poseOffset)
    local restoreCount = reader:u8(poseOffset + 1)
    if restoreCount > MAX_RESTORE_SLOTS then
      fail("NATIVE_GX_BAD_FIELD", "draw pose carries too many matrix slots", { count = restoreCount })
    end
    local expected = POSE_HEADER_SIZE
      + (bit.band(poseFlags, POSE_FLAG_SEED) ~= 0 and POSE_SEED_SIZE or 0)
      + (bit.band(poseFlags, POSE_FLAG_SEED_NORMAL) ~= 0 and POSE_SEED_NORMAL_SIZE or 0)
      + (bit.band(poseFlags, POSE_FLAG_SEGMENT) ~= 0 and POSE_SEGMENT_SIZE or 0)
      + (bit.band(poseFlags, POSE_FLAG_SCALE) ~= 0 and POSE_SCALE_SIZE or 0)
      + (bit.band(poseFlags, POSE_FLAG_MATRIX) ~= 0 and POSE_MATRIX_SIZE or 0)
      + restoreCount * POSE_RESTORE_SIZE
    if expected ~= poseLength then
      fail("NATIVE_GX_BAD_LENGTH", "draw pose blob length disagrees with its contents", { length = poseLength })
    end
    local cursor = poseOffset + POSE_HEADER_SIZE
    if bit.band(poseFlags, POSE_FLAG_SEGMENT) ~= 0 then
      draw.segmentIndex = reader:u16le(cursor)
      cursor = cursor + POSE_SEGMENT_SIZE
    end
    if bit.band(poseFlags, POSE_FLAG_SCALE) ~= 0 then
      draw.positionScale = reader:f32le(cursor)
      cursor = cursor + POSE_SCALE_SIZE
    end
    if bit.band(poseFlags, POSE_FLAG_SEED) ~= 0 then
      local colorSourcePlusOne = reader:u8(cursor)
      if colorSourcePlusOne > 3 then
        fail("NATIVE_GX_BAD_FIELD", "draw seed colour source is out of range", { value = colorSourcePlusOne })
      end
      draw.seedColorSource = colorSourcePlusOne > 0 and (colorSourcePlusOne - 1) or nil
      draw.seedColor = { reader:u8(cursor + 1), reader:u8(cursor + 2), reader:u8(cursor + 3) }
      cursor = cursor + POSE_SEED_SIZE
    end
    if bit.band(poseFlags, POSE_FLAG_SEED_NORMAL) ~= 0 then
      draw.seedNormal = { reader:f32le(cursor), reader:f32le(cursor + 4), reader:f32le(cursor + 8) }
      cursor = cursor + POSE_SEED_NORMAL_SIZE
    end
    if bit.band(poseFlags, POSE_FLAG_MATRIX) ~= 0 then
      draw.matrix = readMatrix(reader, cursor)
      cursor = cursor + POSE_MATRIX_SIZE
    end
    if restoreCount > 0 then
      local restoreStack = {}
      for _ = 1, restoreCount do
        local slot = reader:u16le(cursor)
        if slot >= MAX_RESTORE_SLOTS or restoreStack[slot] ~= nil then
          fail("NATIVE_GX_BAD_FIELD", "draw pose repeats or exceeds a matrix slot", { slot = slot })
        end
        restoreStack[slot] = readMatrix(reader, cursor + 4)
        cursor = cursor + POSE_RESTORE_SIZE
      end
      draw.restoreStack = restoreStack
    end
  end
  return draw
end

-- One G4GX parse over any binary source: every header, count and span check is
-- shared, while `span` decides whether command streams are copied (read) or
-- borrowed from the caller's bytes (view). Any malformed field rejects the whole
-- bank; no partially decoded bank is ever returned.
---@param reader BinaryReader
---@param span fun(offset: integer, length: integer): string|BinaryView
---@return NativeGxFormat.Bank|nil bank
---@return Errors.Error|nil error
local function parse(reader, span)
  local length = reader:length()
  if length < HEADER_SIZE then
    fail("NATIVE_GX_BAD_LENGTH", "native model bank is shorter than its header", { size = length })
  end
  local magic = reader:ascii(0, 4)
  if magic ~= MAGIC then
    fail("NATIVE_GX_BAD_MAGIC", "expected " .. MAGIC .. " magic, got " .. magic, { magic = magic })
  end
  local version = reader:u16le(4)
  if version ~= VERSION then
    fail("NATIVE_GX_BAD_VERSION", "unsupported native model bank version " .. version, { version = version })
  end
  local totalBytes = reader:u32le(8)
  local drawCount = reader:u32le(12)
  local drawTableOffset = reader:u32le(16)
  local commandPayloadOffset = reader:u32le(20)
  if totalBytes ~= length then
    fail("NATIVE_GX_BAD_LENGTH", "native model bank length disagrees with its header", {
      declared = totalBytes,
      size = length,
    })
  end
  if drawTableOffset ~= HEADER_SIZE then
    fail("NATIVE_GX_BAD_OFFSET", "native model bank draw table is not where the format puts it", {
      offset = drawTableOffset,
    })
  end
  local tableEnd = drawTableOffset + drawCount * DRAW_RECORD_SIZE
  if tableEnd > commandPayloadOffset or commandPayloadOffset > totalBytes then
    fail("NATIVE_GX_BAD_OFFSET", "native model bank draw table overruns its payload", {
      drawCount = drawCount,
      tableEnd = tableEnd,
      commandPayloadOffset = commandPayloadOffset,
    })
  end
  local draws = {}
  local commandCache = {}
  for index = 1, drawCount do
    draws[index] = readDraw(reader, drawTableOffset + (index - 1) * DRAW_RECORD_SIZE, commandCache, span)
  end
  return { drawCount = drawCount, draws = draws }, nil
end

-- Read one G4GX bank into bounded draw records, copying each command stream for
-- the authoring and tooling consumers that expect strings.
---@param bytes string|love.Data|BinaryView
---@return NativeGxFormat.Bank|nil bank
---@return Errors.Error|nil error
function NativeGxFormat.read(bytes)
  local reader = BinaryReader.new(bytes, "g4gx")
  return parse(reader, function(offset, length)
    return reader:bytes(offset, length)
  end)
end

-- Read one G4GX bank with every command stream borrowed from the caller's own
-- bytes, so runtime replay costs no second native buffer. The parsed draw keeps
-- a bank-local `commandSpanId` for replay grouping; it is never persisted and
-- says nothing about another bank.
---@param data string|love.Data|BinaryView
---@return NativeGxFormat.Bank|nil bank
---@return Errors.Error|nil error
function NativeGxFormat.view(data)
  local reader = BinaryReader.new(data, "g4gx")
  return parse(reader, function(offset, length)
    return reader:view(offset, length, "g4gx commands")
  end)
end

return NativeGxFormat
