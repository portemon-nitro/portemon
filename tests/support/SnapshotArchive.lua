-- Test helper: read a produced snapshot archive the way the next boot would.
-- The archive is mounted as a real ZIP through love.filesystem, its
-- cache-index.lua is parsed with an empty environment, and every declared
-- member is read back, so a scenario asserts on the bytes a later process would
-- actually see. CRC-32 is the unsigned IEEE ZIP value a manifest row carries.

local Assert = require("tests.support.Assert")
local bit = require("bit")

local SnapshotArchive = {}

local CRC_TABLE

local function crcTable()
  if CRC_TABLE == nil then
    CRC_TABLE = {}
    for index = 0, 255 do
      local value = index
      for _ = 1, 8 do
        local mask = -bit.band(value, 1)
        value = bit.bxor(bit.rshift(value, 1), bit.band(0xEDB88320, mask))
      end
      CRC_TABLE[index] = value
    end
  end
  return CRC_TABLE
end

---@param text string
---@return integer unsignedCrc32
function SnapshotArchive.crc32(text)
  local table_ = crcTable()
  local value = 0xFFFFFFFF
  for index = 1, #text do
    local slot = bit.band(bit.bxor(value, text:byte(index)), 0xFF)
    value = bit.bxor(bit.rshift(value, 8), table_[slot])
  end
  -- LuaJIT's bit library answers signed 32-bit values; fold the four bytes back
  -- into the unsigned number a ZIP/CRC field stores.
  local folded = bit.bxor(value, 0xFFFFFFFF)
  return bit.band(folded, 0xFF)
    + bit.band(bit.rshift(folded, 8), 0xFF) * 256
    + bit.band(bit.rshift(folded, 16), 0xFF) * 65536
    + bit.band(bit.rshift(folded, 24), 0xFF) * 16777216
end

---@param path string
function SnapshotArchive.removeTree(path)
  local info = love.filesystem.getInfo(path)
  if info == nil then
    return
  end
  if info.type == "directory" then
    for _, item in ipairs(love.filesystem.getDirectoryItems(path)) do
      SnapshotArchive.removeTree(path .. "/" .. item)
    end
  end
  love.filesystem.remove(path)
end

---@param text string
---@param chunkName string
---@return table
function SnapshotArchive.parseIndex(text, chunkName)
  local chunk = load(text, chunkName or "=cache-index", "t", {})
  if chunk == nil then
    chunk = assert(loadstring(text))
    setfenv(chunk, {})
  end
  return chunk()
end

local mounts = 0

---@param versionId string
---@param fileName string|nil defaults to the canonical cache.zip
---@return table? index parsed manifest
---@return table? members logical path -> member bytes
---@return string? bytes the archive's own bytes
function SnapshotArchive.read(versionId, fileName)
  local path = versionId .. "/" .. (fileName or "cache.zip")
  if love.filesystem.getInfo(path) == nil then
    return nil
  end
  local bytes = assert(love.filesystem.read(path), "the snapshot archive must be readable")
  mounts = mounts + 1
  local mountedAs = "snapshot-archive-" .. mounts
  local fileData = love.filesystem.newFileData(bytes, "snapshot-" .. mounts .. ".zip")
  Assert.isTrue(love.filesystem.mount(fileData, mountedAs), "the snapshot must be a mountable zip")
  local ok, index, members = pcall(function()
    local indexText =
      assert(love.filesystem.read(mountedAs .. "/cache-index.lua"), "the archive must carry its cache-index.lua member")
    local parsed = SnapshotArchive.parseIndex(indexText)
    local readMembers = {}
    for _, entry in ipairs(parsed.entries) do
      readMembers[entry.path] = assert(
        love.filesystem.read(mountedAs .. "/" .. entry.path),
        "a declared member must be present: " .. entry.path
      )
    end
    return parsed, readMembers
  end)
  love.filesystem.unmount(mountedAs)
  if not ok then
    error(index, 0)
  end
  return index, members, bytes
end

---@param index table parsed manifest
---@return string[] manifestPaths
function SnapshotArchive.memberPaths(index)
  local paths = {}
  for position, entry in ipairs(index.entries) do
    paths[position] = entry.path
  end
  return paths
end

---@generic T
---@param list T[]
---@return T[] sortedCopy
function SnapshotArchive.sorted(list)
  local copy = {}
  for position, value in ipairs(list) do
    copy[position] = value
  end
  table.sort(copy)
  return copy
end

return SnapshotArchive
