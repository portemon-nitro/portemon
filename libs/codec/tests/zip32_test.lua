-- The two ZIP producers share only CRC and record bytes. These checks use the
-- standard CRC vector and mount a real archive assembled from those records;
-- filesystem policy and source/cache lifecycle stay with their owners.

local Assert = require("tests.support.Assert")
local BinaryView = require("libs.codec.src.BinaryView")

local T = {}

local function requireZip32()
  local ok, zip32 = pcall(require, "libs.codec.src.Zip32")
  Assert.isTrue(
    ok and type(zip32) == "table",
    "managed and generated-cache archives need shared ZIP CRC and record encoding"
  )
  return zip32
end

function T.crc_and_records_round_trip_through_a_real_zip_mount()
  local Zip32 = requireZip32()
  Assert.keySet(Zip32, "centralRecord,crc32,endRecord,localHeader", "ZIP codec exposes only pure record operations")
  Assert.equal(Zip32.crc32(BinaryView.fromString("123456789")), 0xCBF43926, "IEEE CRC-32 known vector")
  Assert.equal(Zip32.crc32(BinaryView.fromString("")), 0, "empty input has the canonical zero CRC")

  local payload = "managed and cache ZIP record payload"
  local compressed = assert(love.data.compress("data", "deflate", payload, 1))
  local row = {
    path = "game.nds",
    uncompressedSize = #payload,
    unsignedCrc32 = Zip32.crc32(BinaryView.fromString(payload)),
    method = 8,
    compressedSize = compressed:getSize(),
    offset = 0,
  }
  local localHeader = Zip32.localHeader(row)
  local central = Zip32.centralRecord(row)
  local endRecord = Zip32.endRecord(1, #central, #localHeader + compressed:getSize())
  local localView = BinaryView.fromString(localHeader)
  Assert.equal(localView:u32le(0), 0x04034B50)
  Assert.equal(localView:u16le(4), 20)
  Assert.equal(localView:u16le(6), 0x0800, "record keeps the UTF-8 flag")
  Assert.equal(localView:u16le(8), 8)
  Assert.equal(localView:u16le(12), 0x0021, "record keeps the deterministic DOS date")
  Assert.equal(localView:u32le(14), row.unsignedCrc32)
  Assert.equal(localView:u32le(18), row.compressedSize)
  Assert.equal(localView:u32le(22), row.uncompressedSize)
  Assert.equal(localView:u16le(26), #row.path)

  local centralView = BinaryView.fromString(central)
  Assert.equal(centralView:u32le(0), 0x02014B50)
  Assert.equal(centralView:u16le(42), row.offset)
  Assert.equal(centralView:toString(46, #row.path), row.path)
  local endView = BinaryView.fromString(endRecord)
  Assert.equal(endView:u32le(0), 0x06054B50)
  Assert.equal(endView:u16le(8), 1)
  Assert.equal(endView:u16le(10), 1)
  Assert.equal(endView:u32le(12), #central)
  Assert.equal(endView:u32le(16), #localHeader + compressed:getSize())

  local archive = localHeader .. compressed:getString() .. central .. endRecord
  local fileData = love.filesystem.newFileData(archive, "zip32-roundtrip.zip")
  local namespace = "zip32-roundtrip"
  Assert.isNil(love.filesystem.getInfo(namespace), "ZIP round-trip mount must be unowned")
  Assert.isTrue(love.filesystem.mount(fileData, namespace), "encoded records must form a mountable ZIP")
  local ok, result = pcall(function()
    Assert.equal(love.filesystem.read(namespace .. "/game.nds"), payload)
    return true
  end)
  love.filesystem.unmount(fileData:getFilename())
  Assert.isTrue(ok, "encoded ZIP member must reopen: " .. tostring(result))
  Assert.isNil(love.filesystem.getInfo(namespace), "round-trip mount must be released")

  Assert.throws(function()
    Zip32.localHeader({ path = "../unsafe", uncompressedSize = -1 })
  end)
  Assert.throws(function()
    Zip32.endRecord(0x10000, 0, 0)
  end)
end

return { tests = T }
