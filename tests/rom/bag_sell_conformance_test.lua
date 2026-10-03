-- Source-fidelity proof for the Bag sale presentation: retail Bag member 53
-- supplies a sale-only background, while sale geometry and message roles
-- compile into the strict Bag manifest. Source authority:
-- pret/pokeheartgold@9d8b7591f09b65804da2fb2dfd56f320633e0d36,
-- asm/overlay_15.s (ov15_021FD574, ov15_021FCDE4, ov15_02200300) and
-- files/msgdata/msg/msg_0010.gmm.

local Assert = require("tests.support.Assert")
local BagAssetSchema = require("libs.assets.src.BagAssetSchema")
local BagCache = require("libs.assets.src.BagCache")
local BagSources = require("romdump.src.config.BagSources")
local G2dDecoder = require("romdump.src.digest.ui.G2dDecoder")
local RomSuite = require("tests.rom.support.RomSuite")

local T = {}

local function compile(romFs)
  local BagAssetCompiler = require("romdump.src.digest.ui.BagAssetCompiler")
  local bundle, err = BagAssetCompiler.compile(romFs)
  Assert.notNil(bundle, "the real Bag compiler must compile sale presentation: " .. tostring(err))
  return assert(bundle)
end

function T.sale_background_is_a_distinct_compiled_rom_member(romFs, _)
  local archive = assert(romFs:openNarc("bag_ui"))
  local bytes = assert(archive:readMember(53), "bag_ui member 53 exists in the supplied ROM")
  Assert.notNil(
    G2dDecoder.decodeScreen(bytes, { label = "bag_ui sale quantity screen" }),
    "bag_ui member 53 decodes as the retail sale quantity screen"
  )

  local screenMember = assert(BagSources.screens.saleQuantity, "BagSources names the sale screen")
  Assert.equal(screenMember, 53, "sale uses the retail sale screen member")
  Assert.equal(BagSources.screens.quantityOverlay, 52, "Toss retains its existing quantity screen")

  local bundle = compile(romFs)
  Assert.isTrue(BagAssetSchema.isValidManifest(bundle.manifest), "bag:global preparation requires the current sale schema")
  local compiledPaths = {}
  for _, path in ipairs(BagCache.referencedPaths(bundle.manifest)) do
    compiledPaths[path] = true
    Assert.notNil(bundle.assets[path], "each published bag:global image is compiled: " .. path)
  end
  local seen = {}
  for _, dependency in ipairs(bundle.dependencies.dependencies) do
    seen[dependency.name] = true
  end
  Assert.isTrue(seen["bag_ui:member:53"], "the source compiler consumes member 53")
  Assert.isTrue(seen["bag_ui:member:52"], "the same Bag family retains Toss member 52")

  local sale = assert(bundle.manifest.interactive.sale, "the compiled manifest publishes sale presentation")
  local background = assert(sale.quantityBackground, "sale quantity names its compiled background")
  Assert.isTrue(type(background.image) == "string", "sale background resolves to a generated image")
  Assert.notNil(bundle.assets[background.image], "the member-53 sale image is included in the bundle")
  Assert.isTrue(compiledPaths[background.image], "the sale image is part of the ready bag:global asset closure")
  Assert.isFalse(
    background.image == bundle.manifest.interactive.backgrounds.quantity.items[0].image,
    "sale uses its own surface instead of the Toss quantity surface"
  )

  local digitPositions = assert(sale.digits, "sale quantity publishes digit positions")
  Assert.equal(#digitPositions, 2, "sale uses two digits")
  local controls = assert(sale.controls, "sale quantity publishes source controls")
  Assert.equal(#controls, 4, "sale has four source controls")
  Assert.deepEqual(
    { controls[1].delta, controls[2].delta, controls[3].delta, controls[4].delta },
    { 10, 1, -10, -1 },
    "sale controls use the retail +10, +1, -10, -1 steps"
  )

  for _, name in ipairs({ "confirm", "cancel", "selectedItem", "money", "total", "compactPrompt" }) do
    Assert.notNil(sale[name], "sale publishes " .. name .. " presentation")
  end
  local text = assert(sale.messages, "sale messages compile into their semantic roles")
  for _, role in ipairs({ "notSellable", "quantity", "offer", "result" }) do
    local template = assert(text[role], "sale text includes " .. role)
    Assert.isTrue(#template.segments > 0, "sale " .. role .. " template has compiled content")
  end
end

local suite = RomSuite.fromFacts(T)
suite.metadata.capabilities = { "rom_dump" }
suite.metadata.derivedAssets = { "bag:global" }
return suite
