-- Transactional publication for source-indexed encounter palette batches:
-- one staged generation per source identity plus exact palette signature
-- publishes together, an unchanged batch reuses its handles without new
-- uploads, a failed candidate keeps the prior drawables and rolls back
-- exactly once, and launch release retires every owned key exactly once.
-- Synthetic fixtures only; no ROM, graphics, or derived cache required.

local Assert = require("tests.support.Assert")
local Rgb555 = require("libs.codec.src.Rgb555")
local BattlePresentationAssets = require("game.hgss.src.battle.BattlePresentationAssets")
local BattlePresentationManifestFixture = require("tests.support.BattlePresentationManifestFixture")

local T = {}
local SHADOW_REGIONS = BattlePresentationManifestFixture.manifest().pictures.shadow.regions

---@param opts table? heldKeys, failKey
---@return table preparation double owning only the handles it hands out
local function stubAssets(opts)
  opts = opts or {}
  local assets = { failKey = opts.failKey, images = {}, released = {}, uploads = {} }
  function assets.prepare(_)
    return true
  end
  function assets.drawable(_)
    return nil
  end
  function assets.release(key)
    assets.released[key] = (assets.released[key] or 0) + 1
  end
  function assets.paletteImage(uploadKey, ...)
    if assets.failKey ~= nil and uploadKey:find(assets.failKey, 1, true) ~= nil then
      return nil, "probe upload failure"
    end
    local image = { handle = uploadKey, request = { ... } }
    assets.images[uploadKey] = image
    assets.uploads[#assets.uploads + 1] = uploadKey
    return image
  end
  return assets
end

---@param assets table preparation double under driving
---@return table holder under driving
local function holder(assets)
  return BattlePresentationAssets.new({
    assets = assets,
    launchId = "assets-probe",
    sceneKey = "general/plain/day",
    sceneImage = "scene:probe",
    shadowRegions = SHADOW_REGIONS,
  })
end

---@param id string stable source identity under staging
---@return table source-index map with the shared edge-case pixels
local function indexedSource(id)
  return {
    id = id,
    width = 4,
    height = 2,
    pixels = table.concat({
      string.char(0, 0, 0, 255),
      string.char(9, 0, 0, 0),
      string.char(5, 0, 0, 128),
      string.char(3, 0, 0, 255),
      string.char(5, 0, 0, 255),
      string.char(7, 0, 0, 255),
      string.char(0, 200, 77, 255),
      string.char(3, 0, 0, 0),
    }),
  }
end

---@param words table<integer, integer>? RGB555 words keyed by one-based palette slot
---@return string exact 256-slot RGBA8 palette bytes, opaque colors, zeroed gaps
local function paletteBytes(words)
  words = words or {}
  local out = {}
  for slot = 0, 255 do
    local word = words[slot + 1]
    if word == nil then
      out[#out + 1] = "\0\0\0\0"
    else
      local color = Rgb555.decode(word)
      out[#out + 1] = string.char(color.r, color.g, color.b, 255)
    end
  end
  return table.concat(out)
end

local function wordsA()
  return {
    [1] = Rgb555.encode(31, 0, 0),
    [4] = Rgb555.encode(0, 31, 0),
    [6] = Rgb555.encode(0, 31, 0),
    [8] = Rgb555.encode(31, 31, 0),
    [10] = Rgb555.encode(31, 0, 31),
  }
end

local function wordsB()
  return {
    [1] = Rgb555.encode(0, 0, 31),
    [4] = Rgb555.encode(31, 31, 0),
    [6] = Rgb555.encode(31, 31, 0),
    [8] = Rgb555.encode(0, 0, 0),
  }
end

-- Palette generations publish source-indexed batches transactionally: an
-- initial two-source generation publishes sampler handles, an identical
-- batch under new upload keys reuses them without uploading, a changed
-- generation whose second allocation fails keeps the prior drawables and
-- rolls its candidate back exactly once, and the normal failure cleanup
-- plus launch release retire every owned key exactly once.
function T.palette_generations_publish_source_indexed_batches_transactionally()
  local assets = stubAssets({})
  local battle = holder(assets)
  local terrainSource = indexedSource("source-terrain")
  local hudSource = indexedSource("source-hud")
  local terrainPaletteA = paletteBytes(wordsA())
  local hudPaletteA = paletteBytes(wordsB())

  local ok, published = pcall(function()
    return battle:updatePaletteDrawables({
      terrain = { uploadKey = "battle-palette:scene:1", source = terrainSource, palette = terrainPaletteA },
      hud = { uploadKey = "battle-palette:hud:1", source = hudSource, palette = hudPaletteA },
    })
  end)
  Assert.isTrue(
    ok and published == true,
    "palette generations stage immutable source indices with exact palettes behind sampler handles"
  )
  Assert.equal(#assets.uploads, 2, "the initial generation uploads once per visible source")
  local terrainHandle = battle:drawable("terrain")
  local hudHandle = battle:drawable("hud")
  Assert.notNil(terrainHandle, "the terrain key resolves its published handle")
  Assert.notNil(hudHandle, "the hud key resolves its published handle")
  Assert.isTrue(terrainHandle ~= hudHandle, "two visible sources resolve distinct handles")

  ok, published = pcall(function()
    return battle:updatePaletteDrawables({
      terrain = { uploadKey = "battle-palette:scene:2", source = terrainSource, palette = terrainPaletteA },
      hud = { uploadKey = "battle-palette:hud:2", source = hudSource, palette = hudPaletteA },
    })
  end)
  Assert.isTrue(ok and published == true, "an identical batch republishes")
  Assert.equal(#assets.uploads, 2, "an identical batch performs no replacement upload")
  Assert.isTrue(battle:drawable("terrain") == terrainHandle, "an identical batch keeps the terrain handle")
  Assert.isTrue(battle:drawable("hud") == hudHandle, "an identical batch keeps the hud handle")

  assets.failKey = "battle-palette:scene:2"
  local terrainPaletteB = paletteBytes(wordsB())
  local hudPaletteB = paletteBytes(wordsA())
  local staged, failure = battle:updatePaletteDrawables({
    terrain = { uploadKey = "battle-palette:scene:2", source = terrainSource, palette = terrainPaletteB },
    hud = { uploadKey = "battle-palette:hud:2", source = hudSource, palette = hudPaletteB },
  })
  Assert.isFalse(staged, "one failed allocation rejects the replacement generation")
  Assert.isTrue(
    type(failure) == "string" and failure:find("probe upload failure", 1, true) ~= nil,
    "the failure keeps its upload cause"
  )
  Assert.isTrue(battle:drawable("terrain") == terrainHandle, "a failed staging keeps the prior terrain handle")
  Assert.isTrue(battle:drawable("hud") == hudHandle, "a failed staging keeps the prior hud handle")
  local candidateKey = nil
  for _, key in ipairs(assets.uploads) do
    if key:find("battle-palette:hud:2", 1, true) ~= nil then
      candidateKey = key
    end
  end
  Assert.notNil(candidateKey, "the staged hud candidate uploaded before the terrain failure")
  Assert.equal(
    assets.released[
      candidateKey --[[@as string]]
    ],
    1,
    "the staged candidate rolls back exactly once"
  )
  Assert.isNil(assets.released[assets.uploads[1]], "a failed staging never releases the published terrain image")
  Assert.isNil(assets.released[assets.uploads[2]], "a failed staging never releases the published hud image")
  Assert.equal(battle:state(), "failed", "a configured palette upload failure latches the holder")

  Assert.isTrue(battle:updatePaletteDrawables({}), "an empty batch clears after the failure")
  Assert.equal(assets.released[assets.uploads[1]], 1, "clearing retires the retained terrain image exactly once")
  Assert.equal(assets.released[assets.uploads[2]], 1, "clearing retires the retained hud image exactly once")
  Assert.isFalse(battle:drawable("terrain") == terrainHandle, "clearing withdraws the retained terrain handle")
  battle:dispose()
  Assert.equal(assets.released[assets.uploads[1]], 1, "disposal never re-releases the cleared terrain image")
  Assert.equal(assets.released[assets.uploads[2]], 1, "disposal never re-releases the cleared hud image")

  local sharedAssets = stubAssets({})
  local shared = holder(sharedAssets)
  local sharedSource = indexedSource("source-shared")
  Assert.isTrue(
    shared:updatePaletteDrawables({
      first = { uploadKey = "battle-palette:shared:1a", source = sharedSource, palette = terrainPaletteA },
      second = { uploadKey = "battle-palette:shared:1b", source = sharedSource, palette = hudPaletteA },
    }),
    "two keys may share one source identity with distinct palettes"
  )
  shared:dispose()
  for _, key in ipairs(sharedAssets.uploads) do
    Assert.equal(sharedAssets.released[key], 1, "launch release retires owned key exactly once: " .. key)
  end
end

return { tests = T }
