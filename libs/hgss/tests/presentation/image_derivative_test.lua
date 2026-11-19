-- Worker-side effective-image classification and preparation: exact indexed
-- payloads with first-seen palette order, straight RGBA fallback past 256
-- colors, source isolation across edits, private-file rebuilds, and loud
-- source failures. Synthetic PNGs only; every fixture is encoded in-test.
-- Direct classification checks run the worker's pure entry on provided image
-- data, while queue checks prove the same verdicts arrive through a real
-- worker thread as Data payloads the main thread never pixel-scans.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local PngWriter = require("tests.support.PngEncoder")

local T = {}

local haveClassifier, ImageClassifier = pcall(require, "libs.hgss.src.presentation.ImageDerivative")

---@return table the worker-side pixel classifier under test
local function classifier()
  Assert.isTrue(
    haveClassifier,
    "worker-side image classification is missing: effective PNG bytes must classify "
      .. "to indexed or straight RGBA payloads with exact pixels preserved"
  )
  return ImageClassifier --[[@as table]]
end

local function requireQueue()
  local ok, AssetPreparationQueue = pcall(require, "libs.hgss.src.presentation.AssetPreparationQueue")
  Assert.isTrue(ok, "the production asset preparation queue boundary is missing: " .. tostring(AssetPreparationQueue))
  return AssetPreparationQueue --[[@as table]]
end

local function sha256(text)
  return love.data.hash("sha256", text)
end

local function pixel(r, g, b, a)
  return string.char(r, g, b, a)
end

---@param width integer
---@param height integer
---@param tuples string[] distinct RGBA tuples, cycled row-major
---@return string concatenated row-major RGBA bytes
local function cycledPixels(width, height, tuples)
  local out = {}
  for index = 0, width * height - 1 do
    out[#out + 1] = tuples[(index % #tuples) + 1]
  end
  return table.concat(out)
end

---@param width integer
---@param height integer
---@param pixels string concatenated row-major RGBA bytes
---@return string deterministic PNG bytes
local function encodePng(width, height, pixels)
  return PngWriter.encode(width, height, pixels)
end

---@param png string PNG bytes
---@param name string FileData name for decoding
---@return table decoded RGBA image data
local function decodeImage(png, name)
  return love.image.newImageData(love.filesystem.newFileData(png, name))
end

---@param value unknown
---@return string raw bytes of a Data payload
local function dataBytes(value)
  Assert.equal(type(value), "userdata", "bulk pixel payloads cross as love Data")
  Assert.isTrue(
    type(value.getString) == "function" and type(value.getSize) == "function",
    "payloads expose the Data byte contract"
  )
  return value:getString()
end

-- Test-side CPU inverse of a classified record: indexed payloads select
-- four-byte RGBA tuples from the palette, straight payloads are raw RGBA.
-- Worker records carry love Data payloads; validated cache entries decoded
-- by the love-free format carry the same bytes as plain strings.
---@param record table classifier/worker result
---@return string concatenated row-major RGBA bytes
local function unpackRecord(record)
  if record.kind == "r8" then
    local palette = dataBytes(record.paletteData)
    local indexes = dataBytes(record.indexData)
    local out = {}
    for offset = 1, #indexes do
      local slot = string.byte(indexes, offset)
      out[#out + 1] = palette:sub(slot * 4 + 1, slot * 4 + 4)
    end
    return table.concat(out)
  end
  Assert.equal(record.kind, "rgba8", "representations are indexed or straight RGBA")
  return dataBytes(record.indexData)
end

---@param record table classifier/worker result
local function assertBulkTransit(record)
  for key, value in pairs(record) do
    Assert.isTrue(type(value) ~= "table", "no per-pixel Lua tables cross the worker boundary: " .. tostring(key))
  end
  Assert.isNil(record.image, "preparation never realizes a GPU image")
  Assert.isNil(record.mesh, "preparation never realizes a GPU mesh")
  Assert.isNil(record.imageData, "preparation answers with packed payloads, not decoded images")
end

---@param versionId string
---@return table versioned file-backed cache the worker thread can also read
local function fileBackedCache(versionId)
  return CacheFs.forVersion(versionId)
end

---@param queue table
---@param logicalPath string
---@return table payload transferred exactly once
local function demandImage(queue, logicalPath)
  local token = queue:request("image-derivative", logicalPath, "demand")
  return queue:wait(token)
end

function T.small_palettes_pack_to_indexed_payloads_with_first_seen_order()
  local Classify = classifier()
  local opaque = pixel(200, 10, 20, 255)
  local transparent = pixel(10, 200, 30, 0)
  local fractional = pixel(10, 20, 30, 128)
  local pixels = opaque
    .. transparent
    .. fractional
    .. opaque
    .. transparent
    .. fractional
    .. opaque
    .. transparent
    .. fractional
    .. opaque
    .. transparent
    .. fractional
  local image = decodeImage(encodePng(4, 3, pixels), "small-palette.png")
  local record = Classify.classify(image)
  Assert.equal(record.kind, "r8", "three colors pack as indexed")
  Assert.equal(record.width, 4, "the record carries decoded dimensions")
  Assert.equal(record.height, 3, "the record carries decoded dimensions")
  Assert.equal(record.colors, 3, "transparent and fractional variants stay distinct")
  Assert.equal(record.pixelHash, sha256(pixels), "the pixel hash covers the exact RGBA bytes")
  Assert.equal(
    dataBytes(record.paletteData),
    opaque .. transparent .. fractional,
    "the palette follows first-seen row-major order with exact RGBA bytes"
  )
  Assert.equal(
    dataBytes(record.indexData),
    string.char(0, 1, 2, 0, 1, 2, 0, 1, 2, 0, 1, 2),
    "one zero-based index byte per pixel"
  )
  Assert.equal(unpackRecord(record), pixels, "the packed payload inverts byte-for-byte")
  assertBulkTransit(record)
end

function T.full_256_color_image_stays_indexed_while_257_colors_fall_back_to_rgba()
  local Classify = classifier()
  local base = {}
  for index = 0, 256 do
    base[#base + 1] = pixel(index % 256, math.floor(index / 256), 7, 255)
  end
  local eligibleTuples = {}
  for index = 1, 256 do
    eligibleTuples[#eligibleTuples + 1] = base[index]
  end
  local eligible = cycledPixels(17, 16, eligibleTuples)
  local eligibleRecord = Classify.classify(decodeImage(encodePng(17, 16, eligible), "eligible-256.png"))
  Assert.equal(eligibleRecord.kind, "r8", "256 colors still pack as indexed")
  Assert.equal(unpackRecord(eligibleRecord), eligible, "a full palette round-trips exactly")

  local crowded = {}
  for index = 1, #base do
    crowded[#crowded + 1] = base[index]
  end
  crowded[1] = pixel(10, 20, 30, 0)
  crowded[2] = pixel(0, 0, 0, 0)
  crowded[3] = pixel(40, 50, 60, 128)
  crowded[4] = pixel(70, 80, 90, 1)
  local crowdedPixels = cycledPixels(18, 15, crowded)
  local crowdedImage = decodeImage(encodePng(18, 15, crowdedPixels), "crowded-257.png")
  local first = Classify.classify(crowdedImage)
  local second = Classify.classify(crowdedImage)
  Assert.equal(first.kind, "rgba8", "257 colors always fall back to straight RGBA")
  Assert.equal(second.kind, "rgba8", "repeated classification agrees without per-request variance")
  Assert.equal(dataBytes(first.indexData), dataBytes(second.indexData), "fallback bytes are deterministic")
  Assert.isTrue(first.paletteData == nil or dataBytes(first.paletteData) == "", "the fallback retains no stale palette")
  Assert.equal(#dataBytes(first.indexData), 18 * 15 * 4, "straight payloads carry four bytes per pixel")
  Assert.equal(unpackRecord(first), crowdedPixels, "fallback keeps exact alpha and transparent RGB for every pixel")
  assertBulkTransit(first)
end

function T.oversized_icon_like_image_classifies_to_rgba_through_the_worker()
  local AssetPreparationQueue = requireQueue()
  local tuples = {}
  for index = 0, 299 do
    tuples[#tuples + 1] = pixel(index % 256, math.floor(index / 256), 9, 255)
  end
  local pixels = cycledPixels(48, 48, tuples)
  local cache = fileBackedCache("image-derivative-icon-test")
  local runOk, runErr = pcall(function()
    cache:write("icons/crowded.png", encodePng(48, 48, pixels))
    local queue = AssetPreparationQueue.new(cache)
    local first = demandImage(queue, "icons/crowded.png")
    queue:release()
    local later = AssetPreparationQueue.new(cache)
    local second = demandImage(later, "icons/crowded.png")
    later:release()
    Assert.equal(first.kind, "rgba8", "an icon-sized image past 256 tuples classifies to straight RGBA")
    Assert.equal(unpackRecord(first), pixels, "the worker payload recovers every pixel exactly")
    Assert.equal(
      dataBytes(second.indexData),
      dataBytes(first.indexData),
      "a later worker reads the same PNG to the same pixels"
    )
    assertBulkTransit(first)
  end)
  cache:removeTree("")
  if not runOk then
    error(runErr, 0)
  end
end

function T.edited_sources_reclassify_while_untouched_sources_keep_their_derivatives()
  local AssetPreparationQueue = requireQueue()
  local firstPng = encodePng(4, 4, cycledPixels(4, 4, { pixel(255, 0, 0, 255), pixel(0, 0, 255, 0) }))
  local editedPng =
    encodePng(4, 4, cycledPixels(4, 4, { pixel(255, 0, 0, 255), pixel(0, 255, 0, 128), pixel(0, 0, 0, 0) }))
  local firstPixels = cycledPixels(4, 4, { pixel(255, 0, 0, 255), pixel(0, 0, 255, 0) })
  local editedPixels = cycledPixels(4, 4, { pixel(255, 0, 0, 255), pixel(0, 255, 0, 128), pixel(0, 0, 0, 0) })
  local cache = fileBackedCache("image-derivative-isolation-test")
  local runOk, runErr = pcall(function()
    cache:write("sprites/a.png", firstPng)
    cache:write("sprites/b.png", firstPng)
    local queue = AssetPreparationQueue.new(cache)
    local aBefore = demandImage(queue, "sprites/a.png")
    local bBefore = demandImage(queue, "sprites/b.png")
    queue:release()
    Assert.equal(aBefore.kind, "r8", "two-color sources pack as indexed")
    Assert.equal(unpackRecord(aBefore), firstPixels, "the first source reads back exactly")
    cache:write("sprites/a.png", editedPng)
    local later = AssetPreparationQueue.new(cache)
    local aAfter = demandImage(later, "sprites/a.png")
    local bAfter = demandImage(later, "sprites/b.png")
    later:release()
    Assert.isTrue(aAfter.pixelHash ~= aBefore.pixelHash, "only the changed image reclassifies")
    Assert.equal(unpackRecord(aAfter), editedPixels, "the edited source reads back exactly")
    Assert.equal(bAfter.pixelHash, bBefore.pixelHash, "the untouched path keeps its pixel identity")
    Assert.equal(
      dataBytes(bAfter.indexData),
      dataBytes(bBefore.indexData),
      "the untouched image classifies identically across the edit"
    )
    assertBulkTransit(aAfter)
  end)
  cache:removeTree("")
  if not runOk then
    error(runErr, 0)
  end
end

function T.unreadable_sources_fail_loudly_without_substitution()
  local AssetPreparationQueue = requireQueue()
  local cache = fileBackedCache("image-derivative-failure-test")
  local runOk, runErr = pcall(function()
    cache:write("sprites/good.png", encodePng(2, 2, pixel(9, 9, 9, 255):rep(4)))
    cache:write("sprites/garbage.png", "not-a-png")
    local queue = AssetPreparationQueue.new(cache)
    local garbageToken = queue:request("image-derivative", "sprites/garbage.png", "demand")
    local missingToken = queue:request("image-derivative", "sprites/absent.png", "demand")
    local status, cause = queue:poll(garbageToken)
    if status == "pending" then
      local ok, err = pcall(queue.wait, queue, garbageToken)
      Assert.isTrue(not ok, "corrupted sources fail instead of substituting bytes: " .. tostring(err))
    else
      Assert.equal(status, "failed", "corrupted sources report failure")
      Assert.notNil(cause, "the failure carries a cause")
    end
    local ok, err = pcall(queue.wait, queue, missingToken)
    Assert.isTrue(not ok, "missing sources fail instead of substituting bytes: " .. tostring(err))
    local recovered = demandImage(queue, "sprites/good.png")
    Assert.equal(
      unpackRecord(recovered),
      pixel(9, 9, 9, 255):rep(4),
      "the queue keeps serving valid sources after failures"
    )
    queue:release()
  end)
  cache:removeTree("")
  if not runOk then
    error(runErr, 0)
  end
end

function T.derivative_requests_share_queue_lifecycle_and_leave_no_gpu_objects()
  local AssetPreparationQueue = requireQueue()
  local pixels = cycledPixels(3, 2, { pixel(11, 22, 33, 255), pixel(44, 55, 66, 0) })
  local cache = fileBackedCache("image-derivative-lifecycle-test")
  local runOk, runErr = pcall(function()
    cache:write("sprites/lifecycle.png", encodePng(3, 2, pixels))
    local queue = AssetPreparationQueue.new(cache)
    local background = queue:request("image-derivative", "sprites/lifecycle.png", "prefetch")
    queue:promote(background, "demand")
    local cancelled = queue:request("image-derivative", "sprites/lifecycle.png", "prefetch")
    queue:cancel(cancelled)
    local status = queue:poll(background)
    Assert.isTrue(status ~= nil, "promoted derivative work reports a lifecycle state")
    local payload = queue:wait(background)
    Assert.equal(unpackRecord(payload), pixels, "promoted work still delivers exact pixels")
    local watched = queue:request("image-derivative", "sprites/lifecycle.png", "demand")
    local watchStatus = queue:poll(watched)
    Assert.isTrue(watchStatus ~= nil, "repeated interest in one source reports a lifecycle state")
    queue:cancel(watched)
    assertBulkTransit(payload)
    queue:release()
    queue:release()
    local ok, err = pcall(queue.request, queue, "image-derivative", "sprites/lifecycle.png", "demand")
    Assert.isTrue(not ok, "a released queue accepts no further derivative work: " .. tostring(err))
  end)
  cache:removeTree("")
  if not runOk then
    error(runErr, 0)
  end
end

-- Every file under one versioned cache root, so a scenario can prove that
-- preparation created no persistent companion beside the source PNG.
---@param cache table
---@param relative string
---@return string[]
local function listCacheFiles(cache, relative)
  local found = {}
  for _, name in ipairs(cache:getDirectoryItems(relative)) do
    local child = relative == "" and name or relative .. "/" .. name
    local info = cache:getInfo(child)
    if info ~= nil and info.type == "directory" then
      for _, nested in ipairs(listCacheFiles(cache, child)) do
        found[#found + 1] = nested
      end
    elseif info ~= nil then
      found[#found + 1] = child
    end
  end
  table.sort(found)
  return found
end

-- A generated PNG is the only persistent image asset: warming it classifies
-- the decoded pixels into the existing GPU-upload payload shape and leaves no
-- private image-derivative file behind, so a later worker generation reads the
-- same PNG again instead of trusting a second on-disk copy.
function T.warm_png_preparation_persists_no_image_derivative()
  local AssetPreparationQueue = requireQueue()
  local pixels = cycledPixels(4, 3, { pixel(200, 10, 20, 255), pixel(10, 200, 30, 0), pixel(5, 6, 7, 128) })
  local sourcePng = encodePng(4, 3, pixels)
  local cache = fileBackedCache("image-derivative-warm-png-test")
  local runOk, runErr = pcall(function()
    cache:write("sprites/warm.png", sourcePng)
    Assert.deepEqual(listCacheFiles(cache, ""), { "sprites/warm.png" }, "the cache starts with its PNG only")

    local firstQueue = AssetPreparationQueue.new(cache)
    local first = demandImage(firstQueue, "sprites/warm.png")
    firstQueue:release()
    Assert.equal(unpackRecord(first), pixels, "the warm PNG alone yields the exact GPU-upload pixels")
    Assert.deepEqual(
      listCacheFiles(cache, ""),
      { "sprites/warm.png" },
      "preparing a PNG writes no persistent image derivative beside it"
    )

    local secondQueue = AssetPreparationQueue.new(cache)
    local second = demandImage(secondQueue, "sprites/warm.png")
    secondQueue:release()
    Assert.equal(unpackRecord(second), pixels, "a later worker generation reads the same PNG to the same pixels")
    Assert.equal(second.kind, first.kind, "classification stays stable across worker generations")
    Assert.deepEqual(
      listCacheFiles(cache, ""),
      { "sprites/warm.png" },
      "repeated preparation keeps the PNG as the only persistent image asset"
    )
    Assert.equal(cache:read("sprites/warm.png"), sourcePng, "preparation never rewrites the generated PNG")
  end)
  cache:removeTree("")
  if not runOk then
    error(runErr, 0)
  end
end

return { tests = T }
