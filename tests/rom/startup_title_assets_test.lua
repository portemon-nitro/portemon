-- The compiled title keeps its edition-specific legendary and animation channels.

local Assert = require("tests.support.Assert")
local TitleScreenCompiler = require("romdump.src.digest.startup.TitleScreenCompiler")
local StartupAssetCache = require("libs.assets.src.StartupAssetCache")
local RomSuite = require("tests.rom.support.RomSuite")

local function sourceTitleCompilesTheEditionModelAndFourChannels(romFs, versionId)
  local bundle, err = TitleScreenCompiler.compile(romFs, versionId)
  Assert.notNil(bundle, tostring(err))
  Assert.equal(bundle.manifest.versionId, versionId)
  Assert.equal(bundle.manifest.kind, "animated-title")
  Assert.equal(bundle.manifest.sequence, "SEQ_GS_POKEMON_THEME")
  Assert.equal(bundle.manifest.menuSelectSequence, "SEQ_SE_DP_SELECT")
  Assert.equal(bundle.manifest.crySpeciesId, versionId == "heartgold" and 250 or 249)
  Assert.equal(bundle.manifest.prompt.text, "TOUCH TO START")
  Assert.equal(bundle.manifest.prompt.alignment, "center")
  Assert.deepEqual(bundle.manifest.prompt.color, versionId == "heartgold" and {
    foreground = 1,
    shadow = 1,
    background = 0,
  } or { foreground = 2, shadow = 2, background = 0 })
  Assert.equal(bundle.manifest.prompt.flash.initialDelayFrames, 30)
  Assert.equal(bundle.manifest.prompt.flash.initialPhaseFrame, 30)
  Assert.equal(bundle.manifest.prompt.flash.visibleFrames, 30)
  Assert.equal(bundle.manifest.prompt.flash.hiddenFrames, 15)
  Assert.deepEqual(bundle.dependencies.modelMembers, versionId == "heartgold"
    and { 25, 26, 27, 29, 28, 38, 39, 40 }
    or { 20, 21, 22, 23, 24, 41, 42, 43 })
  Assert.equal(bundle.manifest.timeline.camera.movement.unitsPerFrame, 5)
  Assert.equal(#bundle.manifest.timeline.camera.points, 4)
  Assert.equal(bundle.manifest.timeline.titleReveal.durationFrames, 32)
  Assert.equal(bundle.manifest.timeline.start.initialDelayFrames, 30)
  Assert.equal(bundle.manifest.timeline.start.activeDurationFrames, 2340)
  Assert.equal(bundle.manifest.timeline.glow.fadeInSteps, 61)
  Assert.equal(bundle.manifest.timeline.glow.fadeOutSteps, 61)
  Assert.equal(bundle.manifest.timeline.glow.pauseFrames, 21)
  Assert.equal(bundle.manifest.timeline.attachments.model.endFrame, "wrap-to-zero")
  local camera = bundle.manifest.timeline.camera
  Assert.deepEqual(camera.start.position, { 0, 65, 72 })
  Assert.deepEqual(camera.start.target, { 0, 90, 0 })
  Assert.deepEqual(camera.endPosition, versionId == "heartgold" and { 625, 152, 256 } or { 420, 87, 331 })
  Assert.deepEqual(camera.target, { -2, 124, -38 })
  Assert.deepEqual(camera.points, versionId == "heartgold" and {
    { position = { 180, 177, 301 }, durationSeconds = 10 },
    { position = { 335, -293, 296 }, durationSeconds = 5 },
    { position = { 180, 177, 301 }, durationSeconds = 5 },
    { position = { 625, 152, 256 }, durationSeconds = 10 },
  } or {
    { position = { 105, 162, 291 }, durationSeconds = 10 },
    { position = { 395, 432, 191 }, durationSeconds = 5 },
    { position = { 105, 162, 291 }, durationSeconds = 5 },
    { position = { 420, 87, 331 }, durationSeconds = 10 },
  })
  local kinds = { joint = "trs", srt = "texsrt", color = "color" }
  for channel, kind in pairs(kinds) do
    local clip = assert(bundle.manifest.clips[channel], channel .. " title channel is compiled")
    Assert.equal(clip.kind, kind)
    Assert.isTrue(clip.frameCount > 0, channel .. " carries frame count")
    Assert.isTrue(#clip.tracks > 0, channel .. " carries tracks")
    Assert.isTrue(#clip.compiled.targets > 0, channel .. " carries compiled targets")
  end
  -- Retail soulsilver's title PAT0 carries no texture targets, so that
  -- edition omits the pattern channel instead of publishing it trackless.
  local pattern = bundle.manifest.clips.pattern
  if versionId == "heartgold" then
    Assert.equal(assert(pattern, "heartgold title pattern channel is compiled").kind, "pattern")
    Assert.isTrue(#pattern.tracks > 0, "pattern carries tracks")
    Assert.isTrue(#pattern.compiled.targets > 0, "pattern carries compiled targets")
  else
    Assert.isNil(pattern, "soulsilver title has no pattern animation")
  end
  Assert.isTrue(next(bundle.files) ~= nil, "title model resources are staged")
  Assert.equal(bundle.manifest.sparkle.model.kind, "nitro-dynamic")
  Assert.isTrue(bundle.manifest.sparkle.clips.joint ~= nil, "sparkle joint channel is compiled")
  Assert.isTrue(bundle.manifest.sparkle.clips.pattern ~= nil, "sparkle pattern channel is compiled")
  Assert.isTrue(#bundle.manifest.sparkle.clips.joint.tracks > 0, "sparkle joint track is retained")
  Assert.isTrue(#bundle.manifest.sparkle.clips.pattern.tracks > 0, "sparkle pattern track is retained")
  for _, role in ipairs({ "editionLogo", "subscreenLower", "subscreenDecor" }) do
    local surface = assert(bundle.manifest.surfaces[role], role .. " surface is compiled")
    Assert.equal(surface.width, 256)
    Assert.equal(surface.height, 192)
    Assert.isTrue(type(surface.image) == "string" and type(bundle.files[surface.image]) ~= "nil", role .. " PNG is staged")
    Assert.isTrue(type(surface.sourceHash) == "string", role .. " surface records source identity")
    local pngData = love.filesystem.newFileData(bundle.files[surface.image], surface.image)
    local image = love.image.newImageData(pngData)
    Assert.equal(image:getWidth(), 256, role .. " PNG width")
    Assert.equal(image:getHeight(), 192, role .. " PNG height")
  end
  local manifest = {}
  for key, value in pairs(bundle.manifest) do
    manifest[key] = value
  end
  manifest.generationId = "rom-title-readback"
  local readback, readError = StartupAssetCache.loadTitle({
    loadLua = function()
      return manifest
    end,
    exists = function(_, path)
      return bundle.files[path] ~= nil
    end,
  }, versionId)
  Assert.notNil(readback, tostring(readError))
end

return RomSuite.fromFacts({
  ["source title compiles the edition model and four animation channels"] = sourceTitleCompilesTheEditionModelAndFourChannels,
})
