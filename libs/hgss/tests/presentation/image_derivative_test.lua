-- Worker-side effective-image classification and preparation: exact indexed
-- payloads with first-seen palette order, straight RGBA fallback past 256
-- colors, source isolation across edits, private-file rebuilds, and loud
-- source failures. Synthetic PNGs only; every fixture is encoded in-test.
-- Direct classification checks run the worker's pure entry on provided image
-- data, while queue checks prove the same verdicts arrive through a real
-- worker thread as Data payloads the main thread never pixel-scans.

local Assert = require("tests.support.Assert")
local GeneratedCacheFixture = require("tests.support.GeneratedCacheFixture")
local NativeTextureBank = require("libs.assets.src.model.NativeTextureBank")
local PngWriter = require("tests.support.PngEncoder")
local ResidentAssetCache = require("libs.hgss.src.field.ResidentAssetCache")
local TextureDecoder = require("libs.nds.src.gx.TextureDecoder")

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
---@return GeneratedCacheFixture.ResidentView resident fixture view the worker reads through
-- Fixture payloads live in one resident store the queue reads through, the
-- same reader shape a selected epoch installs: `write` commits a payload with
-- its own content identity and closing retires the whole view.
local function fixtureView(versionId)
  return GeneratedCacheFixture.resident(versionId, {})
end

---@param relative string fixture file below the generated payload root
---@return string logical generated path
local function generated(relative)
  return "assets/generated/" .. relative
end

-- The selected decoded CPU owner and preparation queue this suite exercises.
---@param reader CacheFs selected generated reader
---@return table preparation queue borrowed over its own decoded owner
local function newQueue(reader)
  local decoded = ResidentAssetCache.new({ idleByteLimit = 32 * 1024 * 1024, release = function() end })
  return requireQueue().new(reader, { decoded = decoded })
end

---@param queue table
---@param logicalPath string
---@return table payload transferred exactly once
local function demandImage(queue, logicalPath)
  local token = queue:request("image-derivative", logicalPath, "demand")
  return assert(queue:wait(token)).value.payload
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
  local tuples = {}
  for index = 0, 299 do
    tuples[#tuples + 1] = pixel(index % 256, math.floor(index / 256), 9, 255)
  end
  local pixels = cycledPixels(48, 48, tuples)
  local view = fixtureView("image-derivative-icon-test")
  local runOk, runErr = pcall(function()
    GeneratedCacheFixture.put(view, generated("icons/crowded.png"), encodePng(48, 48, pixels))
    local queue = newQueue(view.reader)
    local first = demandImage(queue, generated("icons/crowded.png"))
    queue:release()
    local later = newQueue(view.reader)
    local second = demandImage(later, generated("icons/crowded.png"))
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
  GeneratedCacheFixture.close(view)
  if not runOk then
    error(runErr, 0)
  end
end

function T.edited_sources_reclassify_while_untouched_sources_keep_their_derivatives()
  local firstPng = encodePng(4, 4, cycledPixels(4, 4, { pixel(255, 0, 0, 255), pixel(0, 0, 255, 0) }))
  local editedPng =
    encodePng(4, 4, cycledPixels(4, 4, { pixel(255, 0, 0, 255), pixel(0, 255, 0, 128), pixel(0, 0, 0, 0) }))
  local firstPixels = cycledPixels(4, 4, { pixel(255, 0, 0, 255), pixel(0, 0, 255, 0) })
  local editedPixels = cycledPixels(4, 4, { pixel(255, 0, 0, 255), pixel(0, 255, 0, 128), pixel(0, 0, 0, 0) })
  local view = fixtureView("image-derivative-isolation-test")
  local runOk, runErr = pcall(function()
    GeneratedCacheFixture.put(view, generated("sprites/a.png"), firstPng)
    GeneratedCacheFixture.put(view, generated("sprites/b.png"), firstPng)
    local queue = newQueue(view.reader)
    local aBefore = demandImage(queue, generated("sprites/a.png"))
    local bBefore = demandImage(queue, generated("sprites/b.png"))
    queue:release()
    Assert.equal(aBefore.kind, "r8", "two-color sources pack as indexed")
    Assert.equal(unpackRecord(aBefore), firstPixels, "the first source reads back exactly")
    GeneratedCacheFixture.put(view, generated("sprites/a.png"), editedPng)
    local later = newQueue(view.reader)
    local aAfter = demandImage(later, generated("sprites/a.png"))
    local bAfter = demandImage(later, generated("sprites/b.png"))
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
  GeneratedCacheFixture.close(view)
  if not runOk then
    error(runErr, 0)
  end
end

function T.unreadable_sources_fail_loudly_without_substitution()
  local view = fixtureView("image-derivative-failure-test")
  local runOk, runErr = pcall(function()
    GeneratedCacheFixture.put(view, generated("sprites/good.png"), encodePng(2, 2, pixel(9, 9, 9, 255):rep(4)))
    GeneratedCacheFixture.put(view, generated("sprites/garbage.png"), "not-a-png")
    local queue = newQueue(view.reader)
    local garbageToken = queue:request("image-derivative", generated("sprites/garbage.png"), "demand")
    -- A path the installed view does not carry is refused when it is
    -- requested: the queue resolves its immutable reference before any job.
    local missingOk, missingErr =
      pcall(queue.request, queue, "image-derivative", generated("sprites/absent.png"), "demand")
    Assert.isFalse(missingOk, "missing sources fail instead of substituting bytes")
    Assert.isTrue(
      tostring(missingErr):find(generated("sprites/absent.png"), 1, true) ~= nil,
      "the missing source is named in its failure: " .. tostring(missingErr)
    )
    local status, cause = queue:poll(garbageToken)
    if status == "pending" then
      local ok, err = pcall(queue.wait, queue, garbageToken)
      Assert.isTrue(not ok, "corrupted sources fail instead of substituting bytes: " .. tostring(err))
    else
      Assert.equal(status, "failed", "corrupted sources report failure")
      Assert.notNil(cause, "the failure carries a cause")
    end
    local recovered = demandImage(queue, generated("sprites/good.png"))
    Assert.equal(
      unpackRecord(recovered),
      pixel(9, 9, 9, 255):rep(4),
      "the queue keeps serving valid sources after failures"
    )
    queue:release()
  end)
  GeneratedCacheFixture.close(view)
  if not runOk then
    error(runErr, 0)
  end
end

function T.derivative_requests_share_queue_lifecycle_and_leave_no_gpu_objects()
  local pixels = cycledPixels(3, 2, { pixel(11, 22, 33, 255), pixel(44, 55, 66, 0) })
  local view = fixtureView("image-derivative-lifecycle-test")
  local runOk, runErr = pcall(function()
    GeneratedCacheFixture.put(view, generated("sprites/lifecycle.png"), encodePng(3, 2, pixels))
    local queue = newQueue(view.reader)
    local background = queue:request("image-derivative", generated("sprites/lifecycle.png"), "prefetch")
    queue:promote(background, "demand")
    local cancelled = queue:request("image-derivative", generated("sprites/lifecycle.png"), "prefetch")
    queue:cancel(cancelled)
    local status = queue:poll(background)
    Assert.isTrue(status ~= nil, "promoted derivative work reports a lifecycle state")
    local payload = assert(queue:wait(background)).value.payload
    Assert.equal(unpackRecord(payload), pixels, "promoted work still delivers exact pixels")
    local watched = queue:request("image-derivative", generated("sprites/lifecycle.png"), "demand")
    local watchStatus = queue:poll(watched)
    Assert.isTrue(watchStatus ~= nil, "repeated interest in one source reports a lifecycle state")
    queue:cancel(watched)
    assertBulkTransit(payload)
    queue:release()
    queue:release()
    local ok, err = pcall(queue.request, queue, "image-derivative", generated("sprites/lifecycle.png"), "demand")
    Assert.isTrue(not ok, "a released queue accepts no further derivative work: " .. tostring(err))
  end)
  GeneratedCacheFixture.close(view)
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
  local pixels = cycledPixels(4, 3, { pixel(200, 10, 20, 255), pixel(10, 200, 30, 0), pixel(5, 6, 7, 128) })
  local sourcePng = encodePng(4, 3, pixels)
  local view = fixtureView("image-derivative-warm-png-test")
  local runOk, runErr = pcall(function()
    GeneratedCacheFixture.put(view, generated("sprites/warm.png"), sourcePng)
    Assert.deepEqual(
      listCacheFiles(view.reader, ""),
      { generated("sprites/warm.png") },
      "the cache starts with its PNG only"
    )

    local firstQueue = newQueue(view.reader)
    local first = demandImage(firstQueue, generated("sprites/warm.png"))
    firstQueue:release()
    Assert.equal(unpackRecord(first), pixels, "the warm PNG alone yields the exact GPU-upload pixels")
    Assert.deepEqual(
      listCacheFiles(view.reader, ""),
      { generated("sprites/warm.png") },
      "preparing a PNG writes no persistent image derivative beside it"
    )

    local secondQueue = newQueue(view.reader)
    local second = demandImage(secondQueue, generated("sprites/warm.png"))
    secondQueue:release()
    Assert.equal(unpackRecord(second), pixels, "a later worker generation reads the same PNG to the same pixels")
    Assert.equal(second.kind, first.kind, "classification stays stable across worker generations")
    Assert.deepEqual(
      listCacheFiles(view.reader, ""),
      { generated("sprites/warm.png") },
      "repeated preparation keeps the PNG as the only persistent image asset"
    )
    Assert.equal(
      view.reader:read(generated("sprites/warm.png")),
      sourcePng,
      "preparation never rewrites the generated PNG"
    )
  end)
  GeneratedCacheFixture.close(view)
  if not runOk then
    error(runErr, 0)
  end
end

-- One 8x8 format-3 (16-color) texture record whose low palette slots carry
-- the selected colors.
---@param name string
---@param texels string byte-exact 4bpp texels for 64 pixels
---@param color0Transparent boolean
---@return NativeTextureBank.Texture
local function indexedTexture(name, texels, color0Transparent)
  return {
    name = name,
    formatRaw = 3,
    width = 8,
    height = 8,
    color0Transparent = color0Transparent,
    texels = texels,
  }
end

---@param words integer[] BGR555 palette words for the leading slots
---@return string 16-slot little-endian palette payload
local function palettePayload(words)
  local out = {}
  for slot = 1, 16 do
    local word = words[slot] or 0
    out[#out + 1] = string.char(word % 256, math.floor(word / 256))
  end
  return table.concat(out)
end

---@param bank NativeTextureBank.Bank
---@param textureName string
---@param paletteName string
---@return string row-major RGBA bytes of one texture/palette selection
local function decodeSelection(bank, textureName, paletteName)
  local texture = assert(bank:texture(textureName), "texture bank has texture " .. textureName)
  local palette = assert(bank:palette(paletteName), "texture bank has palette " .. paletteName)
  local decoded = TextureDecoder.decode({
    format = texture.formatRaw,
    width = texture.width,
    height = texture.height,
    color0Transparent = texture.color0Transparent,
    texel = texture.texels,
    palette = palette.data,
  }, { name = texture.name })
  return decoded.pixels
end

-- The queue identifies native texture work by source identity plus selected
-- names, so several selections of one bank arrive as separate worker jobs. Each
-- job parses the bytes of the identity it resolved, the worker keeps no parsed
-- bank between jobs, and a selection is never served from another bank's parse.
-- Replacing the bank's payload changes its content identity, so the next
-- selection resolves and parses the replacement instead of reusing the earlier
-- parse.
function T.native_texture_selections_parse_only_their_own_resolved_bank()
  local bankPath = "assets/generated/textures/selection-bank.g4tx"
  local otherPath = "assets/generated/textures/replacement-bank.g4tx"
  local view = fixtureView("image-derivative-native-texture-bank-test")
  local runOk, runErr = pcall(function()
    local firstBytes = NativeTextureBank.encode({
      textures = {
        indexedTexture("t0", string.char(0x10):rep(32), false),
        indexedTexture("t1", string.char(0x32):rep(32), true),
      },
      palettes = {
        { name = "p0", data = palettePayload({ 0x001F, 0x03E0, 0x7C00, 0x7FFF }) },
        { name = "p1", data = palettePayload({ 0x4210, 0x0C63, 0x6318, 0x2108 }) },
      },
    })
    local rewrittenBytes = NativeTextureBank.encode({
      textures = {
        indexedTexture("t0", string.char(0x21):rep(32), false),
        indexedTexture("t1", string.char(0x03):rep(32), true),
      },
      palettes = {
        { name = "p0", data = palettePayload({ 0x5AD6, 0x2D6B, 0x14A5, 0x77BD }) },
        { name = "p1", data = palettePayload({ 0x7C1F, 0x03FF, 0x7FE0, 0x0010 }) },
      },
    })
    -- The other bank names the same texture and palette as the first, so a key
    -- that forgot the bank file would serve the wrong texels.
    local otherBytes = NativeTextureBank.encode({
      textures = { indexedTexture("t0", string.char(0x03):rep(32), false) },
      palettes = { { name = "p0", data = palettePayload({ 0x0842, 0x7FE0, 0x03FF }) } },
    })
    GeneratedCacheFixture.put(view, bankPath, firstBytes)
    GeneratedCacheFixture.put(view, otherPath, otherBytes)
    local firstBank = assert(NativeTextureBank.read(firstBytes))
    local expectedSecond = decodeSelection(firstBank, "t1", "p1")
    Assert.isTrue(
      expectedSecond ~= decodeSelection(assert(NativeTextureBank.read(rewrittenBytes)), "t1", "p1"),
      "the rewritten bank decodes to different texels, so a fresh read would be visible"
    )

    local queue = newQueue(view.reader)
    local first = assert(
      queue:wait(queue:request("g4tx", { file = bankPath, textureName = "t0", paletteName = "p0" }, "demand"))
    ).value.payload
    Assert.equal(unpackRecord(first), decodeSelection(firstBank, "t0", "p0"), "a selection yields its own texels")
    Assert.equal(first.width, 8, "the selection reports its texture width")
    Assert.equal(first.height, 8, "the selection reports its texture height")

    GeneratedCacheFixture.put(view, bankPath, rewrittenBytes)
    local second = assert(
      queue:wait(queue:request("g4tx", { file = bankPath, textureName = "t1", paletteName = "p1" }, "demand"))
    ).value.payload
    Assert.equal(
      unpackRecord(second),
      decodeSelection(assert(NativeTextureBank.read(rewrittenBytes)), "t1", "p1"),
      "a later selection parses the bank bytes of the identity it resolved"
    )
    Assert.isTrue(second.pixelHash ~= first.pixelHash, "each selection keeps its own pixel identity")

    local other = assert(
      queue:wait(queue:request("g4tx", { file = otherPath, textureName = "t0", paletteName = "p0" }, "demand"))
    ).value.payload
    Assert.equal(
      unpackRecord(other),
      decodeSelection(assert(NativeTextureBank.read(otherBytes)), "t0", "p0"),
      "a different bank path replaces the reused parse and decodes its own texels"
    )
    Assert.deepEqual(
      listCacheFiles(view.reader, ""),
      { otherPath, bankPath },
      "native texture preparation writes no persistent parse or derivative"
    )
    queue:release()
  end)
  GeneratedCacheFixture.close(view)
  if not runOk then
    error(runErr, 0)
  end
end

return { tests = T }
