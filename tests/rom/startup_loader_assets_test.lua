-- The startup loader publishes the bounded walking visual set for each ready game.

local Assert = require("tests.support.Assert")
local StartupVisualCompiler = require("romdump.src.digest.startup.StartupVisualCompiler")
local RomSuite = require("tests.rom.support.RomSuite")

local function sourceLoaderCompilesBoundedWalkingVisuals(romFs, versionId)
  local bundle, err = StartupVisualCompiler.compile(romFs)
  Assert.notNil(bundle, tostring(err))
  Assert.equal(bundle.manifest.versionId, versionId)
  Assert.equal(bundle.manifest.schema, "g4-startup-loader-v1")
  Assert.equal(bundle.manifest.backdrop.width, 256)
  Assert.equal(bundle.manifest.backdrop.height, 192)
  Assert.notNil(bundle.manifest.heroes.ethan)
  Assert.notNil(bundle.manifest.heroes.lyra)
  Assert.isTrue(#bundle.manifest.followers >= 4 and #bundle.manifest.followers <= 8)
  Assert.isTrue(next(bundle.atlases) ~= nil, "walking atlas assets are compiled")
  Assert.equal(#bundle.backdrop.pixels, 256 * 192 * 4)
end

return RomSuite.fromFacts({
  ["source loader compiles bounded walking visuals"] = sourceLoaderCompilesBoundedWalkingVisuals,
})
