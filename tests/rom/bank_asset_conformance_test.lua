-- ROM-gated bank keypad bundle: the production compiler reads the retail
-- number-entry archive and publishes the composited layer, the sprite atlas,
-- the source key geometry and the three button labels through the generated
-- contract. A stale or partial bundle fails readiness.

local Assert = require("tests.support.Assert")
local BankAssetSchema = require("libs.assets.src.BankAssetSchema")
local BankAssetCompiler = require("romdump.src.digest.ui.BankAssetCompiler")
local BankCache = require("libs.assets.src.BankCache")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local ResidentArtifactFixture = require("tests.support.ResidentArtifactFixture")
local RomSuite = require("tests.rom.support.RomSuite")

local T = {}

T["the compiled keypad keeps the source geometry, labels and sprite frames"] = function(romFs)
  local bundle = assert(BankAssetCompiler.compile(romFs))
  local manifest = assert(BankAssetSchema.validate(bundle.manifest))

  Assert.equal(manifest.display.width, 256, "the keypad paints the 256-pixel bottom display")
  Assert.equal(manifest.display.height, 192, "the keypad paints the 192-pixel bottom display")
  Assert.deepEqual(manifest.labels, { back = "BACK", confirm = "CONFIRM", quit = "QUIT" }, "bank 196 supplies the buttons")
  Assert.equal(manifest.timing.blinkFirstTicks, 4, "the first blink frame holds four ticks")
  Assert.equal(manifest.timing.blinkSecondTicks, 2, "the second blink frame holds two ticks")
  Assert.equal(manifest.timing.maxDigits, 6, "the entry keeps the source six cells")

  -- sRodata.padHitboxes: five 48-pixel columns from x 8 and two rows from y 56.
  for digit = 0, 9 do
    local cell = manifest.keys.digits[digit + 1]
    local column = digit % 5
    local row = (digit - column) / 5
    Assert.equal(cell.x, 8 + column * 48, "digit " .. digit .. " keeps its source column")
    Assert.equal(cell.y, 56 + row * 48, "digit " .. digit .. " keeps its source row")
    Assert.equal(cell.width, 48, "digit " .. digit .. " keeps its source width")
  end
  for _, action in ipairs(manifest.keys.actions) do
    Assert.equal(action.y, 160, "the " .. action.key .. " button sits on the action row")
  end
  Assert.equal(#manifest.keys.dpad, 13, "the dpad grid carries the source positions")

  -- The layer covers the display, the atlas holds every sprite frame, and each
  -- frame's pixel size comes from the source cell.
  Assert.isTrue(manifest.layer.width >= 256 and manifest.layer.height >= 192, "the layer covers the display")
  Assert.equal(#manifest.sprites.digits, 10, "the digit glyph set carries ten frames")
  for digit = 0, 9 do
    local frame = manifest.sprites.digits[digit + 1]
    Assert.equal(frame.digit, digit, "the frame names its digit")
    Assert.equal(frame.image, manifest.sprites.atlas, "every digit rides the one atlas")
    Assert.isTrue(frame.width > 0 and frame.height > 0, "digit " .. digit .. " has real pixels")
  end
  Assert.isTrue(manifest.sprites.cursor.width > 0, "the pad cursor has real pixels")
  Assert.isTrue(manifest.sprites.underline.width > 0, "the entry underline has real pixels")

  -- Provenance names the source archive members and both generated contracts.
  local provenance = bundle.provenance
  Assert.equal(provenance.cacheFormat, BankCache.FORMAT, "the bundle carries its cache format")
  Assert.equal(provenance.schema, BankCache.SCHEMA, "the bundle carries its manifest schema")
  local roles = {}
  for _, dependency in ipairs(provenance.dependencies) do
    local role = dependency.role
    if type(role) == "string" then
      roles[role] = dependency.sha1
    end
  end
  for _, role in
    ipairs({ "bg-char", "bg-palette", "bg-screen", "pad-char", "pad-cell", "digit-char", "digit-animation", "button-labels" })
  do
    Assert.isTrue(roles[role] ~= nil, "provenance names the " .. role .. " member")
  end
  Assert.equal(bundle.marker, BankCache.marker(provenance.versionRomSha1, provenance.dependencyHash))
end

T["a published bundle is ready and a cold cache is not"] = function(romFs)
  local bundle = assert(BankAssetCompiler.compile(romFs))
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  Assert.isFalse(BankCache.isReady(cache, bundle.marker), "a cold cache is never ready")
  local BankCacheWriter = require("romdump.src.digest.ui.BankCacheWriter")
  ResidentArtifactFixture.publish(cache, "bank", "global", function(artifact)
    return BankCacheWriter.stage(artifact, bundle)
  end)
  Assert.isTrue(BankCache.isReady(cache, bundle.marker), "the published bundle is ready")
  Assert.isFalse(BankCache.isReady(cache, bundle.marker .. "-stale"), "a stale marker is never ready")

  local loaded = BankCache.loadManifest(cache)
  Assert.deepEqual(loaded.labels, bundle.manifest.labels, "the runtime loads the published labels")
end

return RomSuite.fromFacts(T)
