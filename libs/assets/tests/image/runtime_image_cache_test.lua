-- Private effective-image derivative format: versioned binary paths, header
-- integrity, and exact pixel round-trips through an isolated cache root.
-- Synthetic fixtures only: every pixel string below is built in Lua, packed
-- through the derivative under test, persisted with CacheFs, reloaded, and
-- unpacked on the CPU back to RGBA tuples.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local Errors = require("libs.errors.src.Errors")
local FakeCache = require("tests.support.FakeCache")

local T = {}

local haveCache, ImageCache = pcall(require, "libs.assets.src.image.RuntimeImageCache")

---@return table the private derivative format owner under test
local function derivativeFormat()
  Assert.isTrue(
    haveCache,
    "the private effective-image derivative path is missing: packing, persisting, "
      .. "reloading, and unpacking an image derivative must survive a round-trip"
  )
  return ImageCache --[[@as table]]
end

local function sha256(text)
  return love.data.hash("sha256", text)
end

local function pixel(r, g, b, a)
  return string.char(r, g, b, a)
end

---@param cache table<string, unknown>|nil
---@return table<string, unknown> cache, table backend
local function isolatedCache(versionId)
  local backend = FakeCache.new()
  return CacheFs.forVersion(versionId or "private-image-derivative-test", backend), backend
end

-- First-seen palette order over raw RGBA tuples, zero-based indexes: the
-- exact contract the indexed representation promises its unpacked bytes.
---@param pixels string concatenated row-major RGBA tuples
---@return string palette, string indexes
local function firstSeenPalette(pixels)
  local order = {}
  local seen = {}
  for offset = 1, #pixels, 4 do
    local tuple = pixels:sub(offset, offset + 3)
    if seen[tuple] == nil then
      seen[tuple] = #order
      order[#order + 1] = tuple
    end
  end
  local indexes = {}
  for offset = 1, #pixels, 4 do
    indexes[#indexes + 1] = string.char(seen[pixels:sub(offset, offset + 3)])
  end
  return table.concat(order), table.concat(indexes)
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
---@return table entry ready to encode as an indexed derivative
local function indexedEntry(width, height, pixels)
  local palette, indexes = firstSeenPalette(pixels)
  return {
    sourceHash = sha256(pixels),
    pixelHash = sha256(pixels),
    width = width,
    height = height,
    kind = "r8",
    colors = math.floor(#palette / 4),
    index = indexes,
    palette = palette,
  }
end

-- Test-side CPU inverse of the indexed representation: every index byte
-- selects one four-byte RGBA tuple from the palette.
---@param entry table decoded derivative entry
---@return string concatenated row-major RGBA bytes
local function unpackIndexed(entry)
  local out = {}
  for offset = 1, #entry.index do
    local slot = string.byte(entry.index, offset)
    out[#out + 1] = entry.palette:sub(slot * 4 + 1, slot * 4 + 4)
  end
  return table.concat(out)
end

local function distinctTuples(count)
  local tuples = {}
  for index = 0, count - 1 do
    tuples[#tuples + 1] = pixel(index % 256, math.floor(index / 256), (index * 5 + 1) % 256, 255)
  end
  return tuples
end

function T.keeps_every_byte_of_small_palettes_through_store_and_reload()
  local Format = derivativeFormat()
  for _, colors in ipairs({ 1, 2, 3, 16 }) do
    local width, height = 2 * colors + 1, 3
    local pixels = cycledPixels(width, height, distinctTuples(colors))
    local entry = indexedEntry(width, height, pixels)
    local cache = isolatedCache()
    local path = Format.pathFor(entry.sourceHash, Format.FORMAT_VERSION)
    Format.store(cache, path, Format.encode(entry))
    local first = Format.load(cache, path)
    local second = Format.load(cache, path)
    Assert.equal(unpackIndexed(first), pixels, "every RGBA tuple survives for " .. colors .. " colors")
    Assert.equal(first.pixelHash, entry.pixelHash, "the pixel identity is preserved")
    Assert.equal(Format.encode(second), Format.encode(first), "derivative bytes are deterministic")
    Assert.equal(second.pixelHash, first.pixelHash, "repeated loads reuse the same derivative")
  end
end

function T.preserves_transparent_rgb_distinctions_and_fractional_alpha()
  local Format = derivativeFormat()
  local tuples = {
    pixel(10, 20, 30, 0),
    pixel(0, 0, 0, 0),
    pixel(10, 20, 31, 0),
    pixel(40, 50, 60, 1),
    pixel(70, 80, 90, 128),
    pixel(100, 110, 120, 254),
  }
  local width, height = 3, 5
  local pixels = cycledPixels(width, height, tuples)
  local entry = indexedEntry(width, height, pixels)
  Assert.equal(entry.colors, 6, "transparent RGB variants and fractional alphas stay distinct")
  local expectedPalette, expectedIndexes = firstSeenPalette(pixels)
  Assert.equal(entry.palette, expectedPalette, "the palette follows first-seen row-major order")
  Assert.equal(entry.index, expectedIndexes, "indexes select first-seen slots")
  local cache = isolatedCache()
  local path = Format.pathFor(entry.sourceHash, Format.FORMAT_VERSION)
  Format.store(cache, path, Format.encode(entry))
  local reloaded = Format.load(cache, path)
  Assert.equal(unpackIndexed(reloaded), pixels, "alpha-zero RGB and fractional alpha round-trip exactly")
end

function T.round_trips_a_full_256_color_palette_exactly()
  local Format = derivativeFormat()
  local tuples = distinctTuples(256)
  local width, height = 17, 16
  local pixels = cycledPixels(width, height, tuples)
  local entry = indexedEntry(width, height, pixels)
  Assert.equal(entry.colors, 256, "all 256 tuples are kept")
  local cache = isolatedCache()
  local path = Format.pathFor(entry.sourceHash, Format.FORMAT_VERSION)
  Format.store(cache, path, Format.encode(entry))
  local reloaded = Format.load(cache, path)
  Assert.equal(reloaded.kind, "r8", "256 colors still pack as indexed")
  Assert.equal(#reloaded.index, width * height, "one index byte per pixel")
  Assert.equal(#reloaded.palette, 256 * 4, "four exact RGBA bytes per palette slot")
  Assert.equal(unpackIndexed(reloaded), pixels, "every tuple of a full palette round-trips")
end

function T.round_trips_257_colors_as_unindexed_rgba()
  local Format = derivativeFormat()
  local tuples = distinctTuples(257)
  local width, height = 19, 15
  local pixels = cycledPixels(width, height, tuples)
  local entry = {
    sourceHash = sha256(pixels),
    pixelHash = sha256(pixels),
    width = width,
    height = height,
    kind = "rgba8",
    colors = 0,
    index = pixels,
    palette = "",
  }
  local cache = isolatedCache()
  local path = Format.pathFor(entry.sourceHash, Format.FORMAT_VERSION)
  Format.store(cache, path, Format.encode(entry))
  local reloaded = Format.load(cache, path)
  Assert.equal(reloaded.kind, "rgba8", "257 colors fall back to straight RGBA")
  Assert.equal(reloaded.index, pixels, "straight RGBA keeps every byte without a palette")
  Assert.equal(reloaded.pixelHash, entry.pixelHash, "the pixel identity is preserved")
end

function T.paths_isolate_sources_and_format_versions()
  local Format = derivativeFormat()
  local first = Format.pathFor(sha256("first-effective-bytes"), Format.FORMAT_VERSION)
  Assert.equal(first, Format.pathFor(sha256("first-effective-bytes"), Format.FORMAT_VERSION), "paths are deterministic")
  Assert.isTrue(
    first ~= Format.pathFor(sha256("second-effective-bytes"), Format.FORMAT_VERSION),
    "changed effective sources resolve independently"
  )
  Assert.isTrue(
    first ~= Format.pathFor(sha256("first-effective-bytes"), Format.FORMAT_VERSION + 1),
    "format versions resolve independently"
  )
  Assert.isTrue(first:sub(1, 1) ~= "/" and first:find("%.%.", 1, true) == nil, "paths stay confined")
  Assert.isTrue(first:find("_private", 1, true) ~= nil, "derivatives live under the disposable private root")
end

function T.pixel_hash_binds_all_four_channels()
  local Format = derivativeFormat()
  local opaque = pixel(10, 20, 30, 255) .. pixel(10, 20, 30, 255)
  local transparentVariant = pixel(10, 20, 30, 0) .. pixel(10, 20, 31, 0)
  Assert.isTrue(sha256(opaque) ~= sha256(transparentVariant), "alpha-zero RGB differences change the hash")
  local entry = indexedEntry(2, 1, transparentVariant)
  Assert.equal(entry.pixelHash, sha256(transparentVariant), "the pixel hash covers the raw RGBA bytes")
  local cache = isolatedCache()
  local path = Format.pathFor(entry.sourceHash, Format.FORMAT_VERSION)
  Format.store(cache, path, Format.encode(entry))
  Assert.equal(Format.load(cache, path).pixelHash, entry.pixelHash, "the hash survives the round-trip")
end

function T.changed_sources_keep_independent_derivatives()
  local Format = derivativeFormat()
  local before = cycledPixels(3, 3, distinctTuples(2))
  local after = cycledPixels(3, 3, distinctTuples(3))
  local cache = isolatedCache()
  local beforeEntry = indexedEntry(3, 3, before)
  local beforePath = Format.pathFor(beforeEntry.sourceHash, Format.FORMAT_VERSION)
  Format.store(cache, beforePath, Format.encode(beforeEntry))
  local afterEntry = indexedEntry(3, 3, after)
  local afterPath = Format.pathFor(afterEntry.sourceHash, Format.FORMAT_VERSION)
  Assert.isTrue(beforePath ~= afterPath, "the edited source resolves away from the original")
  Format.store(cache, afterPath, Format.encode(afterEntry))
  Assert.equal(
    unpackIndexed(Format.load(cache, beforePath)),
    before,
    "storing the edited derivative leaves the other one valid"
  )
  Assert.equal(unpackIndexed(Format.load(cache, afterPath)), after, "the edited source reads back exactly")
end

function T.rebuilt_derivative_replaces_a_corrupted_private_file()
  local Format = derivativeFormat()
  local pixels = cycledPixels(5, 3, distinctTuples(4))
  local trustedPng = "trusted-png-bytes"
  local cache = isolatedCache()
  cache:write("textures/icon.png", trustedPng)
  local entry = indexedEntry(5, 3, pixels)
  local path = Format.pathFor(entry.sourceHash, Format.FORMAT_VERSION)
  Format.store(cache, path, Format.encode(entry))
  local valid = cache:read(path)
  cache:write(path, valid:sub(1, math.floor(#valid / 2)))
  local ok, err = pcall(Format.load, cache, path)
  Assert.isTrue(not ok, "a truncated private derivative must not load")
  Assert.isTrue(Errors.is(err), "truncation reports a structured failure")
  Format.store(cache, path, Format.encode(entry))
  Assert.equal(unpackIndexed(Format.load(cache, path)), pixels, "the private file rebuilds exactly")
  Assert.equal(cache:read("textures/icon.png"), trustedPng, "rebuilding never touches the trusted source")
end

function T.failed_writes_keep_the_previous_valid_derivative()
  local Format = derivativeFormat()
  local pixels = cycledPixels(4, 4, distinctTuples(3))
  local entry = indexedEntry(4, 4, pixels)
  local shared = FakeCache.new()
  local good = CacheFs.forVersion("private-image-derivative-test", shared)
  -- Reads and directory probes delegate to the shared table; only writes
  -- report failure, so the failed publication below overlaps live data.
  local failingBackend = setmetatable({ files = shared.files, dirs = shared.dirs }, {
    __index = function(_, key)
      if key == "write" then
        return function()
          return false
        end
      end
      return FakeCache[key]
    end,
  })
  local failing = CacheFs.forVersion("private-image-derivative-test", failingBackend)
  local path = Format.pathFor(entry.sourceHash, Format.FORMAT_VERSION)
  Format.store(good, path, Format.encode(entry))
  local ok, err = pcall(Format.store, failing, path, Format.encode(entry))
  Assert.isTrue(not ok, "an unsuccessful private write must surface")
  Assert.isTrue(Errors.is(err), "the write failure is structured")
  Assert.equal(
    unpackIndexed(Format.load(good, path)),
    pixels,
    "the previously published derivative survives the failed write"
  )
end

function T.loading_a_missing_derivative_reports_absence_for_rebuild()
  local Format = derivativeFormat()
  local cache = isolatedCache()
  Assert.isNil(
    Format.load(cache, Format.pathFor(sha256("never-stored"), Format.FORMAT_VERSION)),
    "a missing private derivative rebuilds instead of failing"
  )
end

function T.rejects_truncated_tampered_and_misidentified_bytes()
  local Format = derivativeFormat()
  local entry = indexedEntry(3, 2, cycledPixels(3, 2, distinctTuples(3)))
  local valid = Format.encode(entry)
  local cache = isolatedCache()
  local path = Format.pathFor(entry.sourceHash, Format.FORMAT_VERSION)
  local function rejects(bytes, reason)
    local ok, err = pcall(Format.decode, bytes)
    Assert.isTrue(not ok, "malformed derivative bytes must not decode: " .. reason)
    Assert.isTrue(Errors.is(err), "malformation reports a structured failure: " .. reason)
    Assert.equal(err.code, "IMAGE_DERIVATIVE_CORRUPT", "corruption keeps its failure code: " .. reason)
  end
  ---@param position integer 1-based byte offset to flip
  ---@return string bytes with one altered byte
  local function flippedAt(position)
    local altered = (valid:byte(position) + 1) % 256
    return valid:sub(1, position - 1) .. string.char(altered) .. valid:sub(position + 1)
  end
  local paletteEnd = #valid - 4
  local paletteStart = paletteEnd - #entry.palette + 1
  local indexEnd = paletteStart - 1
  local indexStart = indexEnd - #entry.index + 1
  rejects(valid:sub(1, #valid - 1), "truncation")
  rejects(valid .. "Z", "appended trailer byte")
  rejects("X" .. valid:sub(2), "wrong magic")
  rejects(valid:sub(1, 4) .. "Z" .. valid:sub(6), "tampered header byte")
  rejects(valid:sub(1, #valid - 4) .. "ZZZZ", "tampered payload tail")
  rejects(flippedAt(indexEnd), "changed last index byte")
  rejects(flippedAt(paletteEnd), "changed last palette byte")
  rejects(flippedAt(indexStart), "changed first index byte")
  local declaredByte = valid:byte(19)
  rejects(
    valid:sub(1, 18) .. string.char((declaredByte + 1) % 256) .. valid:sub(20),
    "declared payload length disagrees"
  )
  local badKind = {
    sourceHash = entry.sourceHash,
    pixelHash = entry.pixelHash,
    width = 3,
    height = 2,
    kind = "r16",
    colors = 3,
    index = entry.index,
    palette = entry.palette,
  }
  Assert.isTrue(not pcall(Format.encode, badKind), "an unknown representation must not encode")
  local oversizedPalette = {
    sourceHash = entry.sourceHash,
    pixelHash = entry.pixelHash,
    width = 3,
    height = 2,
    kind = "r8",
    colors = 257,
    index = entry.index,
    palette = string.rep("P", 257 * 4),
  }
  Assert.isTrue(not pcall(Format.encode, oversizedPalette), "a palette past 256 slots must not encode")
  local mismatched = {
    sourceHash = entry.sourceHash,
    pixelHash = entry.pixelHash,
    width = 3,
    height = 2,
    kind = "r8",
    colors = 3,
    index = "short",
    palette = entry.palette,
  }
  Assert.isTrue(not pcall(Format.encode, mismatched), "an index that disagrees with dimensions must not encode")
  local overflow = {
    sourceHash = entry.sourceHash,
    pixelHash = entry.pixelHash,
    width = 2 ^ 30,
    height = 2 ^ 30,
    kind = "r8",
    colors = 3,
    index = entry.index,
    palette = entry.palette,
  }
  Assert.isTrue(not pcall(Format.encode, overflow), "dimension products must be validated before allocation")
  Assert.isTrue(not pcall(Format.encode, {
    sourceHash = entry.sourceHash,
    pixelHash = entry.pixelHash,
    width = 0,
    height = 2,
    kind = "r8",
    colors = 3,
    index = entry.index,
    palette = entry.palette,
  }), "empty dimensions must not encode")
  cache:write(path, "not-a-derivative")
  local ok, err = pcall(Format.load, cache, path)
  Assert.isTrue(not ok, "a foreign file at a derivative path must not load")
  Assert.isTrue(Errors.is(err), "the foreign file reports a structured failure")
end

function T.reencoding_a_decoded_derivative_returns_the_exact_bytes()
  local Format = derivativeFormat()
  local tuples = {
    pixel(0, 0, 0, 0),
    pixel(255, 255, 255, 255),
    pixel(0, 255, 0, 128),
    pixel(255, 0, 255, 1),
  }
  local width, height = 4, 3
  local pixels = cycledPixels(width, height, tuples)
  local indexed = indexedEntry(width, height, pixels)
  local validIndexed = Format.encode(indexed)
  Assert.equal(Format.encode(Format.decode(validIndexed)), validIndexed, "indexed decode then re-encode is byte-identical")
  local reloaded = Format.decode(validIndexed)
  Assert.equal(reloaded.index, indexed.index, "index bytes survive, including embedded zeros")
  Assert.equal(reloaded.palette, indexed.palette, "palette bytes survive, including 0x00 and 0xFF")
  local straight = {
    sourceHash = sha256(pixels),
    pixelHash = sha256(pixels),
    width = width,
    height = height,
    kind = "rgba8",
    colors = 0,
    index = pixels,
    palette = "",
  }
  local validStraight = Format.encode(straight)
  Assert.equal(Format.encode(Format.decode(validStraight)), validStraight, "straight decode then re-encode is byte-identical")
  Assert.equal(Format.decode(validStraight).index, pixels, "straight RGBA keeps every 0x00 and 0xFF byte")
end

function T.publishing_leaves_no_staging_residue_and_cleans_up()
  local Format = derivativeFormat()
  local pixels = cycledPixels(3, 3, distinctTuples(2))
  local entry = indexedEntry(3, 3, pixels)
  local cache = isolatedCache()
  local path = Format.pathFor(entry.sourceHash, Format.FORMAT_VERSION)
  local parent = path:match("^(.*)/[^/]+$") or ""
  Format.store(cache, path, Format.encode(entry))
  local items = cache:getDirectoryItems(parent)
  Assert.equal(#items, 1, "publication leaves exactly the derivative file behind")
  Assert.equal(items[1], path:match("[^/]+$"), "the surviving file is the derivative itself")
  Assert.equal(
    unpackIndexed(Format.load(cache, path)),
    unpackIndexed(Format.load(cache, path)),
    "the published derivative is stably reusable"
  )
  cache:removeTree(parent)
  Assert.isNil(Format.load(cache, path), "removing the private tree returns the path to rebuildable")
end

return { tests = T }
