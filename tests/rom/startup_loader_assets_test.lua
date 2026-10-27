-- The startup loader publishes one shared bounded walking visual set for each ready game.

local Assert = require("tests.support.Assert")
local StartupVisualCompiler = require("romdump.src.digest.startup.StartupVisualCompiler")
local RomSuite = require("tests.rom.support.RomSuite")

local function hasTransparentTexel(pixels)
  for offset = 4, #pixels, 4 do
    if pixels:byte(offset) == 0 then
      return true
    end
  end
  return false
end

local function sharedCatalogCompilesOnceForEveryPair(romFs, versionId)
  local FieldActorCompiler = require("romdump.src.digest.actor.FieldActorCompiler")
  local StartupAssetCache = require("libs.assets.src.StartupAssetCache")
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
  local ok, bundleOrErr = pcall(StartupVisualCompiler.compile, romFs)
  FieldActorCompiler.compileSprites = realCompileSprites
  Assert.isTrue(ok, "the shared catalog compiles: " .. tostring(bundleOrErr))
  local bundle = bundleOrErr
  Assert.equal(#captured, 1, "the shared catalog decodes through exactly one sprite request")
  Assert.equal(#captured[1], 18, "the shared catalog decodes exactly eighteen source sprites")
  local manifest = bundle.manifest
  Assert.equal(manifest.schema, "g4-startup-walker-v2", "the shared catalog carries the versioned schema")
  Assert.equal(manifest.versionId, versionId, "the shared catalog carries its edition")
  Assert.isNil(manifest.pairIndex, "the shared catalog carries no pair selection")
  Assert.notNil(manifest.heroes, "the shared catalog carries its heroes")
  Assert.notNil(manifest.followers, "the shared catalog carries its followers")
  Assert.notNil(manifest.heroes.ethan, "the shared catalog carries the first hero")
  Assert.notNil(manifest.heroes.lyra, "the shared catalog carries the second hero")
  local followerCount = 0
  for _ in pairs(manifest.followers) do
    followerCount = followerCount + 1
  end
  Assert.equal(followerCount, 16, "the shared catalog carries sixteen followers")
  local atlasCount = 0
  for path, atlas in pairs(bundle.atlases) do
    atlasCount = atlasCount + 1
    Assert.isTrue(
      path:sub(1, #"assets/generated/startup/loader/subjects/") == "assets/generated/startup/loader/subjects/",
      "shared atlas lives under the subject root: " .. tostring(path)
    )
    Assert.isTrue(type(atlas.pixels) == "string" and #atlas.pixels > 0, "shared atlas carries pixels")
    Assert.isTrue(hasTransparentTexel(atlas.pixels), "shared atlas keeps transparent pixels")
  end
  Assert.equal(atlasCount, 18, "the shared catalog stages exactly eighteen atlases")
  for pairIndex = 1, 32 do
    local choice = StartupAssetCache.walkerChoice(pairIndex)
    Assert.notNil(
      manifest.heroes[choice.heroId],
      "pair " .. pairIndex .. " resolves its hero through the shared catalog"
    )
    Assert.notNil(
      manifest.followers[tostring(choice.followerSpeciesId)],
      "pair " .. pairIndex .. " resolves its follower through the shared catalog"
    )
  end
end

return RomSuite.fromFacts({
  ["shared walking catalog compiles once for every pair"] = sharedCatalogCompilesOnceForEveryPair,
})
