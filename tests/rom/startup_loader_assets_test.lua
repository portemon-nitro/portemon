-- The startup loader publishes the bounded walking visual set for each ready game.

local Assert = require("tests.support.Assert")
local StartupVisualCompiler = require("romdump.src.digest.startup.StartupVisualCompiler")
local RomSuite = require("tests.rom.support.RomSuite")

local function sourceLoaderCompilesBoundedWalkingVisuals(romFs, versionId)
  local ok, _ = pcall(StartupVisualCompiler.compile, romFs)
  Assert.isFalse(ok, "compiling without a selected pair is rejected")
  for _, badIndex in ipairs({ 0, 33 }) do
    local badOk, _ = pcall(StartupVisualCompiler.compile, romFs, badIndex)
    Assert.isFalse(badOk, "pair index " .. tostring(badIndex) .. " is rejected before any source decode")
  end
end

-- One selected walking pair compiles exactly its own hero and follower and
-- nothing else: the request names the pair before any source decode, the
-- producer decodes only those two field actor sprites, and the bundle
-- carries two transparent atlases with source pivots and no opaque cover.
local FOLLOWER_SPECIES_BY_ORDINAL = { 1, 4, 7, 152, 155, 158, 252, 255, 258, 387, 390, 393, 133, 25, 143, 183 }

local function expectedPairSprites(pairIndex)
  local MonSources = require("romdump.src.config.MonSources")
  local PlayerAvatar = require("romdump.src.catalog.hgss.player_avatar")
  local ordinal = (pairIndex - 1) % 16 + 1
  local gender = pairIndex <= 16 and 0 or 1
  local heroSprite = PlayerAvatar.statesForGender(gender).walking
  local speciesId = FOLLOWER_SPECIES_BY_ORDINAL[ordinal]
  local followerSprite = MonSources.followerSpriteId(speciesId, 0, false)
  Assert.notNil(followerSprite, "follower species " .. speciesId .. " resolves a base source sprite")
  return heroSprite, followerSprite, speciesId
end

local function hasTransparentTexel(pixels)
  for offset = 4, #pixels, 4 do
    if pixels:byte(offset) == 0 then
      return true
    end
  end
  return false
end

local function checkPairVisual(visual, pairIndex, role)
  Assert.equal(visual.render.kind, "atlas", "pair " .. pairIndex .. " " .. role .. " stays a sampled atlas")
  Assert.isTrue(visual.render.frameWidth > 0 and visual.render.frameHeight > 0, "pair " .. pairIndex .. " " .. role .. " keeps its source frame size")
  Assert.isTrue(visual.render.frameCount >= 2, "pair " .. pairIndex .. " " .. role .. " keeps its source frames")
  Assert.equal(visual.pivot.x, 0.5, "pair " .. pairIndex .. " " .. role .. " keeps the source bottom-center pivot")
  Assert.equal(visual.pivot.y, 1, "pair " .. pairIndex .. " " .. role .. " keeps the source bottom-center pivot")
  local walk = visual.directions and visual.directions.east and visual.directions.east.walk
  Assert.notNil(walk, "pair " .. pairIndex .. " " .. role .. " keeps its source east walk clip")
  local seen = {}
  for _, frame in ipairs(walk.frames) do
    seen[frame.frameIndex] = true
  end
  local distinct = 0
  for _ in pairs(seen) do
    distinct = distinct + 1
  end
  Assert.isTrue(distinct >= 2, "pair " .. pairIndex .. " " .. role .. " keeps an animated walk clip")
end

local function checkSelectedPair(romFs, versionId, pairIndex)
  local FieldActorCompiler = require("romdump.src.digest.actor.FieldActorCompiler")
  local heroSprite, followerSprite, speciesId = expectedPairSprites(pairIndex)
  local captured = {}
  local realCompileSprites = FieldActorCompiler.compileSprites
  FieldActorCompiler.compileSprites = function(reader, spriteIds)
    local copy = {}
    for index, spriteId in ipairs(spriteIds) do
      copy[index] = spriteId
    end
    captured[#captured + 1] = copy
    return realCompileSprites(reader, spriteIds)
  end
  local ok, bundleOrErr = pcall(StartupVisualCompiler.compile, romFs, pairIndex)
  FieldActorCompiler.compileSprites = realCompileSprites
  Assert.isTrue(ok, "the keyed pair request compiles: " .. tostring(bundleOrErr))
  local bundle = bundleOrErr
  Assert.equal(#captured, 1, "pair " .. pairIndex .. " decodes through exactly one sprite request")
  Assert.equal(#captured[1], 2, "pair " .. pairIndex .. " decodes exactly one hero and one follower sprite")
  local requested = {}
  for _, spriteId in ipairs(captured[1]) do
    requested[spriteId] = true
  end
  Assert.isTrue(requested[heroSprite] == true, "pair " .. pairIndex .. " decodes its own hero sprite")
  Assert.isTrue(requested[followerSprite] == true, "pair " .. pairIndex .. " decodes its own base follower sprite")
  local manifest = bundle.manifest
  Assert.equal(manifest.schema, "g4-startup-walker-v1", "pair " .. pairIndex .. " publishes the keyed pair schema")
  Assert.equal(manifest.versionId, versionId, "pair " .. pairIndex .. " carries its edition")
  Assert.equal(manifest.pairIndex, pairIndex, "pair " .. pairIndex .. " carries its selection")
  Assert.notNil(manifest.hero, "pair " .. pairIndex .. " carries exactly one hero")
  Assert.notNil(manifest.follower, "pair " .. pairIndex .. " carries exactly one follower")
  Assert.isNil(manifest.heroes, "pair " .. pairIndex .. " carries no hero roster")
  Assert.isNil(manifest.followers, "pair " .. pairIndex .. " carries no follower roster")
  Assert.isNil(manifest.backdrop, "pair " .. pairIndex .. " publishes no opaque cover")
  Assert.isNil(bundle.backdrop, "pair " .. pairIndex .. " compiles no opaque cover bytes")
  Assert.equal(manifest.follower.speciesId, speciesId, "pair " .. pairIndex .. " names its follower species")
  checkPairVisual(manifest.hero.visual, pairIndex, "hero")
  checkPairVisual(manifest.follower.visual, pairIndex, "follower")
  local atlasRoot = "assets/generated/startup/loader/pairs/" .. pairIndex .. "/"
  Assert.isTrue(
    manifest.hero.atlasPath:sub(1, #atlasRoot) == atlasRoot,
    "pair " .. pairIndex .. " hero atlas lives under its pair root"
  )
  Assert.isTrue(
    manifest.follower.atlasPath:sub(1, #atlasRoot) == atlasRoot,
    "pair " .. pairIndex .. " follower atlas lives under its pair root"
  )
  local atlasCount = 0
  for path, atlas in pairs(bundle.atlases) do
    atlasCount = atlasCount + 1
    Assert.isTrue(path:sub(1, #atlasRoot) == atlasRoot, "pair " .. pairIndex .. " stages only its own atlases")
    Assert.isTrue(type(atlas.pixels) == "string" and #atlas.pixels > 0, "pair " .. pairIndex .. " atlas carries pixels")
    Assert.isTrue(
      hasTransparentTexel(atlas.pixels),
      "pair " .. pairIndex .. " atlas keeps transparent pixels outside the sprite"
    )
  end
  Assert.equal(atlasCount, 2, "pair " .. pairIndex .. " stages exactly two atlases")
end

local function selectedStartupPairCompilesOnlyItsTwoSprites(romFs, versionId)
  checkSelectedPair(romFs, versionId, 1)
  checkSelectedPair(romFs, versionId, 32)
end

return RomSuite.fromFacts({
  ["source loader compiles bounded walking visuals"] = sourceLoaderCompilesBoundedWalkingVisuals,
  ["selected startup pair compiles only its two walking sprites"] = selectedStartupPairCompilesOnlyItsTwoSprites,
})
