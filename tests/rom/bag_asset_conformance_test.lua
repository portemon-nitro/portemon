-- ROM smoke for the Bag asset producer and its consumer boundary.

local Assert = require("tests.support.Assert")
local BagAssetCompiler = require("romdump.src.digest.ui.BagAssetCompiler")
local BagAssetSchema = require("libs.assets.src.BagAssetSchema")
local BagCache = require("libs.assets.src.BagCache")
local RomSuite = require("tests.rom.support.RomSuite")

local T = {}

function T.production_bundle_passes_the_consumer_gate_and_resolves_its_assets(romFs, versionId)
  local bundle, err = BagAssetCompiler.compile(romFs)
  Assert.notNil(bundle, "the Bag producer compiles its generated bundle: " .. tostring(err))
  bundle = assert(bundle)
  Assert.isTrue(BagAssetSchema.isValidManifest(bundle.manifest), "the Bag manifest passes its consumer schema")
  Assert.equal(bundle.manifest.schema, BagCache.SCHEMA)

  local paths = assert(BagCache.referencedPaths(bundle.manifest))
  Assert.isTrue(#paths > 0, "the Bag bundle publishes generated assets")
  for _, path in ipairs(paths) do
    Assert.notNil(bundle.assets[path], versionId .. " generated asset resolves: " .. path)
  end
end

-- The retail registration blit lands in item-list windows bound to sub BG
-- palette 11, which the Bag fills with font palette 1 (graphic/font member 8).
function T.registration_markers_use_the_item_list_font_palette(romFs, versionId)
  local G2dDecoder = require("romdump.src.digest.ui.G2dDecoder")
  local BagSources = require("romdump.src.config.BagSources")
  local bundle = assert(BagAssetCompiler.compile(romFs))
  local source = BagSources.registration.fontPalette
  local fontArchive = assert(romFs:openNarc(source.archive))
  local palette = G2dDecoder.decodePalette(assert(fontArchive:readMember(source.member)), { label = "font" })
  local inks = {}
  for index = 2, 16 do
    local color = palette.colors[index]
    inks[color.r * 65536 + color.g * 256 + color.b] = true
  end
  for _, slot in ipairs({ "slot1", "slot2" }) do
    local visual = bundle.manifest.interactive.itemSlots.registration[slot]
    local image = love.image.newImageData(love.filesystem.newFileData(bundle.assets[visual.image], visual.image))
    local opaque = 0
    for y = 0, image:getHeight() - 1 do
      for x = 0, image:getWidth() - 1 do
        local r, g, b, a = image:getPixel(x, y)
        if a > 0 then
          opaque = opaque + 1
          local key = math.floor(r * 255 + 0.5) * 65536 + math.floor(g * 255 + 0.5) * 256 + math.floor(b * 255 + 0.5)
          Assert.isTrue(inks[key] == true, versionId .. " " .. slot .. " marker ink comes from font palette 1")
        end
      end
    end
    Assert.isTrue(opaque > 0, versionId .. " " .. slot .. " marker carries visible ink")
  end
end

local suite = RomSuite.fromFacts(T)
suite.metadata.capabilities = { "rom_dump" }
return suite
