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
local ResidentArtifactFixture = require("tests.support.ResidentArtifactFixture")
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
  Assert.equal(credits.sceneTransitionTimings[1], 890, "the roll's first scene transition keeps its source frame")
  Assert.equal(
    credits.sceneTransitionTimings[#credits.sceneTransitionTimings],
    4295,
    "the roll's last scene transition keeps its source frame"
  )
  Assert.equal(bundle.sections.registration.messageBank, 180, "the registration text bank is the source one")
  Assert.equal(bundle.sections.showcase.messageBank, 181, "the showcase text bank is the source one")
  -- Realized art lives in the consumed sections, not provenance: the
  -- registration and credit choreography above consumes it, so the runtime
  -- draw contract carries backgrounds, sprite frames, animation tracks and
  -- the cutscene table. No physical archive pointer enters the draw
  -- contract.
  Assert.isNil(
    bundle.sections.registration.backgroundArchive,
    "the registration draw contract carries no physical archive pointer"
  )
  Assert.isNil(
    bundle.sections.showcase.backgroundArchive,
    "the showcase draw contract carries no physical archive pointer"
  )
  Assert.isNil(
    bundle.sections.credits.spriteResources,
    "the credit draw contract carries no sprite pointers until a renderer consumes them"
  )
  local provenanceArt = assert(bundle.provenance.source.registrationArt, "provenance carries registration art")
  Assert.equal(
    provenanceArt.backgroundArchive,
    "NARC_a_1_0_1",
    "provenance names the registration source background archive"
  )
  Assert.isTrue(#provenanceArt.backgroundMembers >= 9, "provenance carries the registration source background members")
  Assert.equal(
    bundle.provenance.source.showcaseArt.backgroundArchive,
    "NARC_a_0_9_7",
    "provenance names the showcase source background archive"
  )
  Assert.equal(credits.screenFlipTimings[1], 890, "the roll's first screen flip keeps its source frame")
  Assert.equal(
    credits.screenFlipTimings[#credits.screenFlipTimings],
    4295,
    "the roll's last screen flip keeps its source frame"
  )
  Assert.equal(bundle.provenance.source.creditSprites.charMember, 1, "provenance names the dancing sprite char member")
  Assert.equal(bundle.provenance.source.creditCutscenes.count, 16, "provenance names the source cutscene count")

  -- Registration application art: individual and whole-party backgrounds,
  -- overworld/follower and twinkle/player sprite frames, per-species
  -- animation scripts with cry delays and pic heights, and the
  -- spotlight/confetti color tables behind the whole-party effects.
  local registration = assert(bundle.sections.registration, "the bundle publishes its registration section")
  Assert.equal(#registration.bgIndiv, 3, "the individual scenes keep their three background layers")
  Assert.equal(#registration.bgWhole, 2, "the whole-party scene keeps its two background layers")
  for _, layer in ipairs(registration.bgIndiv) do
    Assert.isTrue(type(layer.path) == "string", "an individual background layer names its image")
  end
  for _, layer in ipairs(registration.bgWhole) do
    Assert.isTrue(type(layer.path) == "string", "a whole-party background layer names its image")
  end
  Assert.isTrue(#registration.owSmall[0].frames >= 1, "the small follower sprite keeps its frames")
  Assert.isTrue(#registration.owLarge[0].frames >= 1, "the large follower sprite keeps its frames")
  Assert.isTrue(#registration.twinkle[0].frames >= 1, "the twinkle sparkle keeps its frames")
  Assert.isTrue(#registration.playerEthan[0].frames >= 1, "the male player picture keeps its frames")
  Assert.isTrue(#registration.playerLyra[0].frames >= 1, "the female player picture keeps its frames")
  local typhlosion = assert(
    registration.monTracks.TYPHLOSION,
    "the bundle carries per-species animation tracks"
  )
  Assert.isTrue(type(typhlosion.front.cryDelay) == "number", "a front track carries its cry delay")
  Assert.isTrue(type(typhlosion.back.cryDelay) == "number", "a back track carries its cry delay")
  Assert.equal(#typhlosion.front.steps, 10, "a front track carries its ten animation steps")
  Assert.equal(#typhlosion.back.steps, 10, "a back track carries its ten animation steps")
  Assert.isTrue(
    type(typhlosion.heights[0]) == "table" and type(typhlosion.heights[0].male) == "number",
    "a species track carries its picture heights"
  )
  Assert.equal(#registration.spotlightColors, 8, "the bundle carries the source spotlight colors")
  Assert.equal(#registration.confettiColors, 8, "the bundle carries the source confetti colors")

  -- Credit roll choreography: dancing/cloud sprite frames per sequence
  -- and the sixteen cutscenes with their sprite parameters.
  for sequence = 0, 7 do
    local frames = assert(
      credits.danceSequences[sequence] and credits.danceSequences[sequence].frames,
      "dance sequence " .. sequence .. " keeps its frames"
    )
    Assert.isTrue(#frames >= 1, "dance sequence " .. sequence .. " is not empty")
  end
  Assert.equal(#credits.cutscenes, 16, "the roll keeps its sixteen cutscenes")
  local cutsceneParams = 0
  for _, cutscene in ipairs(credits.cutscenes) do
    Assert.isTrue(type(cutscene.uniqueSprites) == "number", "a cutscene names its sprite count")
    for _, param in ipairs(assert(cutscene.params, "a cutscene carries its sprite params")) do
      if type(param.spriteIdx) == "number" then
        cutsceneParams = cutsceneParams + 1
        Assert.isTrue(type(param.activateTime) == "number", "a cutscene sprite names its cue")
      end
    end
  end
  Assert.isTrue(cutsceneParams > 16, "the cutscenes place more than one sprite overall")

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
  Assert.isTrue(
    images > 13,
    "the bundle publishes the registration and choreography art beyond the scene pairs: " .. images
  )

  -- Publish it and admit it back through the strict contract.
  local fs = FakeCache.new()
  local cacheFs = CacheFs.forVersion("soulsilver", fs)
  local marker = ResidentArtifactFixture.publish(cacheFs, "ending", "global", function(artifact)
    return EndingCacheWriter.stage(artifact, bundle)
  end)
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
