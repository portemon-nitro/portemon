-- ROM-backed conformance for the League ending bundle: the credit roll's own
-- source frames, page timings and message lines, the six scene backgrounds and
-- "The End" screen rasterized from the credit archive, and the published
-- bundle's own strict index/marker round trip.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local DerivedAssetContract = require("libs.assets.src.DerivedAssetContract")
local EndingAssetCache = require("libs.assets.src.ending.EndingAssetCache")
local EndingAssetCompiler = require("romdump.src.digest.ending.EndingAssetCompiler")
local EndingCacheWriter = require("romdump.src.digest.ending.EndingCacheWriter")
local FakeCache = require("tests.support.FakeCache")
local RomSuite = require("tests.rom.support.RomSuite")

local PNG_MAGIC = "\137PNG\r\n\26\n"

local function testEndingBundle(romFs)
  local bundle = assert(EndingAssetCompiler.compile(romFs))
  local credits = assert(bundle.sections.credits, "the bundle publishes its credit roll")
  Assert.equal(credits.frames, 4976, "the roll keeps the source CREDITS_FRAMES")
  Assert.equal(credits.musicBoxWaitFrames, 380, "The End keeps the source music-box wait")
  Assert.equal(credits.messageBank, 440, "the roll reads the source credit message bank")
  Assert.equal(#credits.scenes, 6, "the roll keeps its six background scenes")
  Assert.equal(#credits.pages, 43, "the roll keeps its source page count")
  local lines = 0
  for _, page in ipairs(credits.pages) do
    lines = lines + #page.lines
  end
  Assert.equal(lines, 251, "the roll keeps every source credit line")
  Assert.equal(
    credits.sceneTransitionTimings[1],
    890,
    "the roll's first scene transition keeps its source frame"
  )
  Assert.equal(
    credits.sceneTransitionTimings[#credits.sceneTransitionTimings],
    4295,
    "the roll's last scene transition keeps its source frame"
  )
  Assert.equal(bundle.sections.registration.messageBank, 180, "the registration text bank is the source one")
  Assert.equal(bundle.sections.showcase.messageBank, 181, "the showcase text bank is the source one")

  -- Every published image is a real PNG in the bundle's own asset root.
  local images = 0
  for path, image in pairs(bundle.images) do
    images = images + 1
    Assert.isTrue(
      path:match("^data/generated/ending/images/%x+%.png$") ~= nil,
      "a bundle image lives under the ending asset root: " .. tostring(path)
    )
    Assert.equal(assert(image.data):sub(1, #PNG_MAGIC), PNG_MAGIC, "a bundle image is a PNG")
  end
  Assert.equal(images, 13, "the roll publishes its six scene pairs and The End")

  -- Publish it and admit it back through the strict contract.
  local fs = FakeCache.new()
  local cacheFs = CacheFs.forVersion("soulsilver", fs)
  local marker = EndingCacheWriter.write(cacheFs, bundle)
  Assert.equal(marker, bundle.marker, "the published marker is the bundle's own")
  Assert.equal(fs:read("soulsilver/" .. EndingAssetCache.markerPath()), marker, "the marker file is published")
  local loaded = EndingAssetCache.load(cacheFs)
  Assert.equal(loaded.signature, bundle.marker, "loading returns the published signature")
  Assert.equal(#loaded.credits.scenes, 6, "loading returns every scene")
  Assert.equal(#loaded.credits.pages, 43, "loading returns every page")
  Assert.isTrue(EndingAssetCache.isReady(cacheFs, marker), "the published bundle is ready")

  -- A bundle that lost one required section is never ready.
  fs:write("soulsilver/data/generated/ending/showcase.lua", "return {}\n")
  Assert.isFalse(EndingAssetCache.isReady(cacheFs, marker), "a section that lost its fields is rejected")
  Assert.isFalse(
    EndingAssetCache.isReady(cacheFs, "ending-cache-v1:" .. bundle.provenance.versionRomSha1 .. ":other"),
    "a foreign marker is rejected"
  )
  Assert.equal(DerivedAssetContract.ending.indexSchema, EndingAssetCache.SCHEMA, "the section owns one schema name")
end

return RomSuite.fromFacts({
  ["the League ending bundle publishes its source roll, backgrounds and text banks"] = testEndingBundle,
})
