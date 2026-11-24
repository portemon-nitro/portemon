-- Selected-payload scenarios for the hatch presentation compiler: the source
-- art resolves into a strict manifest, the scene's four message lines come from
-- its own bank, the two particle resources compile, and the bundle names every
-- staged image it references. Every fact is decoded from the canonical dump;
-- no commercial payload is committed.

local Assert = require("tests.support.Assert")
local PokemonCareAssetSchema = require("libs.assets.src.PokemonCareAssetSchema")
local PokemonCareCache = require("libs.assets.src.PokemonCareCache")
local RomSuite = require("tests.rom.support.RomSuite")

local T = {}

---@param romFs table
---@return table
local function compiled(romFs)
  local PokemonCareAssetCompiler = require("romdump.src.digest.ui.PokemonCareAssetCompiler")
  local bundle, failure = PokemonCareAssetCompiler.compileHatch(romFs)
  Assert.isNil(failure, "the hatch presentation compiles from the source members: " .. tostring(failure))
  return assert(bundle)
end

function T.hatch_manifest_carries_the_source_scene_surfaces(romFs, _)
  local bundle = compiled(romFs)
  local manifest = bundle.manifest
  Assert.equal(manifest.schema, PokemonCareAssetSchema.HATCH_SCHEMA, "the manifest names its schema")
  Assert.equal(manifest.background.width, 256, "the scene background covers the main screen width")
  -- The source background layer is a 256x256 map; the lower rows stay below
  -- the visible screen and the scene never scrolls them into view.
  Assert.isTrue(manifest.background.height >= 192, "the scene background covers the visible screen height")
  Assert.isTrue(#manifest.egg.frames >= 2, "the egg sprite carries its animation frames")
  Assert.isTrue(#manifest.bars.frames >= 1, "the reveal bars carry their frames")
  for _, group in ipairs({ manifest.egg, manifest.bars }) do
    for _, frame in ipairs(group.frames) do
      Assert.isTrue(frame.width > 0 and frame.height > 0, "every frame has a source extent")
      Assert.isTrue(bundle.assets[frame.image] ~= nil, "every frame has its staged image")
    end
  end
  Assert.isTrue(
    manifest.window.width == 27 * 8 and manifest.window.height == 4 * 8,
    "the message window keeps the source tile geometry"
  )
end

function T.hatch_lines_come_from_the_scene_message_bank(romFs, _)
  local bundle = compiled(romFs)
  local messages = bundle.manifest.messages
  Assert.equal(messages.hatched.id, 0, "the hatch line is the bank's first message")
  Assert.equal(messages.nicknameQuestion.id, 1, "the nickname question is the bank's second message")
  Assert.equal(messages.yes.id, 2, "the yes answer is the bank's third message")
  Assert.equal(messages.no.id, 3, "the no answer is the bank's fourth message")
  Assert.notNil(messages.hatched.text:find("{name}", 1, true), "the hatch line keeps the hatched name in place")
  for _, line in ipairs({ messages.hatched, messages.nicknameQuestion, messages.yes, messages.no }) do
    Assert.isTrue(line.text:match("^%s*$") == nil, "every scene line prints text")
  end
end

function T.hatch_particles_carry_both_scene_resources(romFs, _)
  local bundle = compiled(romFs)
  for _, variant in ipairs({ "egg", "manaphy" }) do
    local set = assert(bundle.manifest.particles[variant], variant .. " particles resolve")
    Assert.isTrue(#set.emitters >= 1, variant .. " particles carry compiled emitters")
    Assert.isTrue(#set.textures >= 1, variant .. " particles carry textures")
    for _, texture in ipairs(set.textures) do
      Assert.isTrue(bundle.assets[texture.image] ~= nil, "every particle texture has its staged image")
    end
  end
end

function T.hatch_bundle_names_every_referenced_image(romFs, _)
  local bundle = compiled(romFs)
  local paths = PokemonCareCache.referencedHatchPaths(bundle.manifest)
  Assert.isTrue(#paths > 0, "the manifest references staged images")
  for _, path in ipairs(paths) do
    Assert.equal(type(bundle.assets[path]), "string", "referenced image " .. path .. " is staged")
  end
  local valid = PokemonCareAssetSchema.isValidHatchManifest(bundle.manifest)
  Assert.isTrue(valid, "the compiled manifest satisfies its strict schema")
end

local suite = RomSuite.fromFacts(T)
suite.metadata.capabilities = { "rom_dump" }
return suite
