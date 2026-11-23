-- MaterialCompiler: textured materials get a content hash + finalized asset,
-- untextured materials get none, identical texture references deduplicate, and a
-- name the bound pack does not define yields an untextured material plus a
-- reported unresolved binding -- what the DS draws, since no HGSS material stores
-- a texture format or address of its own for a failed bind to fall back on.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local MaterialCompiler = require("romdump.src.digest.model.MaterialCompiler")
local NativeTextureBank = require("libs.assets.src.model.NativeTextureBank")
local TexFixture = require("tests.support.Tex0Fixture")

local T = {}

-- The one compiled bank in a texture accumulator, found by its own magic so
-- the accumulator's internal key spelling stays the producer's.
---@param textures table
---@return string key
---@return string bytes
local function compiledBank(textures)
  local key, value = next(textures)
  Assert.notNil(key, "a bound material produces one texture bank")
  Assert.equal(next(textures, key), nil, "a texture pack compiles to exactly one bank")
  Assert.equal(type(value), "string", "the bank travels as bytes")
  Assert.equal(value:sub(1, 4), "G4TX", "the compiled bank carries the native texture magic")
  return key, value
end

-- One 8x8 palette16 texture "t" (all texels index 1) + palette "p".
local function buildPack()
  return TexFixture.pack({ textures = { "t" }, palettes = { "p" } })
end

local function countKeys(t)
  local n = 0
  for _ in pairs(t) do
    n = n + 1
  end
  return n
end

function T.textured_untextured_and_dedup()
  local out = MaterialCompiler.compile({
    { index = 0, name = "m0", textureName = "t", paletteName = "p" },
    { index = 1, name = "m1" }, -- untextured
    { index = 2, name = "m2", textureName = "t", paletteName = "p" }, -- same texture -> dedup
  }, buildPack())

  Assert.equal(#out.materials, 3)
  Assert.equal(type(out.materials[1].texture), "table", "a bound material names its texture bank selector")
  Assert.isNil(out.materials[2].texture)
  Assert.equal(out.materials[1].texture.file, out.materials[3].texture.file)
  Assert.equal(out.materials[1].texture.textureName, "t")
  Assert.equal(out.materials[1].texture.paletteName, "p")
  Assert.equal(countKeys(out.textures), 1) -- deduplicated

  local _, bytes = compiledBank(out.textures)
  local bank = assert(NativeTextureBank.read(bytes))
  Assert.equal(bank.textureCount, 1, "the bank keeps the source texture")
  Assert.equal(bank.paletteCount, 1, "the bank keeps the source palette")
  Assert.isTrue(out.materials[1].alphaUsage.hasOpaque)
  Assert.isFalse(out.materials[1].alphaUsage.hasZero)
  Assert.isFalse(out.materials[1].alphaUsage.hasPartial)
  Assert.equal(out.materials[1].textureFormat, 3)
  Assert.isNil(out.materials[1].alphaMode)
  Assert.isNil(out.materials[1].cullMode)
end

function T.resolved_materials_report_nothing_unresolved()
  local out = MaterialCompiler.compile({ { index = 0, name = "m", textureName = "t", paletteName = "p" } }, buildPack())
  Assert.deepEqual(out.unresolved, {})
end

function T.missing_texture_compiles_untextured_and_is_reported()
  local out = MaterialCompiler.compile(
    { { index = 0, name = "m", textureName = "nope", paletteName = "p" } },
    buildPack(),
    { context = { textureArchive = "map_textures", textureMemberId = 42 } }
  )

  Assert.isNil(out.materials[1].texture)
  Assert.equal(#out.unresolved, 1)
  Assert.equal(out.unresolved[1].material, "m")
  Assert.equal(out.unresolved[1].kind, "texture")
  Assert.equal(out.unresolved[1].name, "nope")
  Assert.equal(out.unresolved[1].source, "map_textures member 42")
  Assert.equal(countKeys(out.textures), 0, "an unresolved bind stages no bank")
end

function T.missing_palette_compiles_untextured_and_is_reported()
  -- Paletted format with no palette name: the texture exists but cannot be
  -- decoded, so the DS has nothing bound either.
  local out = MaterialCompiler.compile({ { index = 0, name = "m", textureName = "t" } }, buildPack())

  Assert.isNil(out.materials[1].texture)
  Assert.equal(#out.unresolved, 1)
  Assert.equal(out.unresolved[1].kind, "palette")
end

function T.an_unresolved_material_keeps_its_wrap_and_flip()
  -- Wrap/flip come from the material's own register, which a failed bind leaves
  -- untouched; only the texture reference is lost.
  local out = MaterialCompiler.compile(
    { { index = 0, name = "m", textureName = "nope", repeatX = true, flipY = true } },
    buildPack()
  )
  Assert.equal(out.materials[1].wrap.x, "repeat")
  Assert.isTrue(out.materials[1].flip.y)
end

function T.one_pack_encodes_one_shared_texture_bank()
  -- The shared bind step: the same source pack resolves to one immutable bank
  -- whatever material asked for it, and the bank carries the named texels and
  -- palette the material selected.
  local pack = buildPack()
  local first = MaterialCompiler.compile({ { index = 0, name = "a", textureName = "t", paletteName = "p" } }, pack)
  local second = MaterialCompiler.compile({ { index = 0, name = "b", textureName = "t", paletteName = "p" } }, pack)
  local firstKey = compiledBank(first.textures)
  local secondKey = compiledBank(second.textures)
  Assert.equal(secondKey, firstKey, "the same source pack keeps one bank identity")

  local bank = assert(NativeTextureBank.read(first.textures[firstKey]))
  local indexed = assert(bank:texture("t"), "the bank resolves the bound texture name")
  Assert.equal(indexed.formatRaw, 3)
  Assert.equal(indexed.width, 8)
  Assert.equal(indexed.height, 8)
  Assert.notNil(bank:palette("p"), "the bank resolves the bound palette name")
end

function T.bank_identity_is_the_pack_content_not_the_material_binding()
  local function keyFor(pack)
    local out = MaterialCompiler.compile({ { index = 0, name = "a", textureName = "t", paletteName = "p" } }, pack)
    return compiledBank(out.textures)
  end

  local firstKey = keyFor(buildPack())
  local otherKey = keyFor(
    TexFixture.pack({ textures = { { name = "t", texel = string.rep(string.char(0x22), 32) } }, palettes = { "p" } })
  )
  Assert.isTrue(otherKey ~= firstKey, "different texel content is a different bank")
end

function T.texture_dimensions_are_rejected_before_rgba_allocation()
  local pack = buildPack()
  pack.textures[1].width = -1
  local ok, result = pcall(function()
    MaterialCompiler.compile({ { index = 0, name = "m", textureName = "t", paletteName = "p" } }, pack)
  end)
  Assert.isFalse(ok)
  Assert.isTrue(Errors.is(result), "invalid dimensions remain structured")
  ---@cast result Errors.Error
  Assert.equal(result.code, "NATIVE_TEX_BAD_FIELD")
end

-- One source texture pack persists as one named texture bank: a material
-- selects a texture name and a palette name independently, so the same
-- texels bound to two palettes stay two visible results of one compact bank
-- instead of two expanded images.
local function nativeTextureBank()
  local ok, mod = pcall(require, "libs.assets.src.model.NativeTextureBank")
  Assert.isTrue(
    ok and type(mod) == "table",
    "the native texture bank format is missing: a 3D material cannot bind compact named texels and palettes"
  )
  Assert.equal(type(mod.read), "function", "the native texture bank format must expose read(bytes)")
  return mod --[[@as table]]
end

---@param value unknown
---@return string
local function bankBytes(value)
  if type(value) == "string" then
    return value
  end
  if type(value) == "table" and value.data ~= nil then
    return bankBytes(value.data)
  end
  Assert.equal(type(value), "userdata", "a texture bank travels as bytes")
  ---@cast value love.Data
  return value:getString()
end

local function twoPalettePack()
  return TexFixture.pack({
    textures = { { name = "t", texel = string.rep(string.char(0x11), 32) }, { name = "d", format = 7 } },
    palettes = {
      { name = "p1", palette = string.rep(string.char(0x1F, 0x00), 16) },
      { name = "p2", palette = string.rep(string.char(0xE0, 0x03), 16) },
    },
  })
end

function T.one_named_texture_bank_serves_every_palette_pairing()
  local out = MaterialCompiler.compile({
    { index = 0, name = "day", textureName = "t", paletteName = "p1" },
    { index = 1, name = "dusk", textureName = "t", paletteName = "p2" },
    { index = 2, name = "plain", textureName = "d" },
  }, twoPalettePack())
  Assert.equal(#out.unresolved, 0, "both palette pairings bind against the source pack")

  local banks = {}
  for key, asset in pairs(out.textures) do
    local bytes = bankBytes(asset)
    Assert.isNil(
      bytes:sub(1, 4) == "\137PNG" and "expanded image" or nil,
      "a 3D texture pack persists one named bank rather than a PNG per material pairing: " .. tostring(key)
    )
    if bytes:sub(1, 4) == "G4TX" then
      banks[#banks + 1] = bytes
    end
  end
  Assert.equal(#banks, 1, "one texture bank is compiled for one source texture pack")

  local day = assert(out.materials[1].texture, "a bound material keeps its texture binding")
  local dusk = assert(out.materials[2].texture, "a bound material keeps its texture binding")
  local plain = assert(out.materials[3].texture, "a bound material keeps its texture binding")
  for label, selector in pairs({ day = day, dusk = dusk, plain = plain }) do
    Assert.equal(type(selector), "table", "a material binds its texture by bank selector (" .. label .. ")")
    Assert.isTrue(
      tostring(selector.file):sub(-5) == ".g4tx",
      "a material selector names the native texture bank (" .. label .. ")"
    )
  end
  Assert.equal(day.file, dusk.file, "two palettes of one texture reference the same physical bank")
  Assert.equal(day.textureName, "t", "the selector keeps the source texture name")
  Assert.equal(day.paletteName, "p1", "the selector keeps the source palette name")
  Assert.equal(dusk.paletteName, "p2", "the same texels resolve through a different named palette")
  Assert.isNil(plain.paletteName, "a direct-colour texture selects no palette")

  local Bank = nativeTextureBank()
  local bank = assert(Bank.read(banks[1]))
  Assert.notNil(bank:texture("t"), "the bank holds the indexed texture")
  Assert.notNil(bank:texture("d"), "the bank holds the direct-colour texture")
  Assert.notNil(bank:palette("p1"), "the bank holds every referenced palette")
  Assert.notNil(bank:palette("p2"), "the bank holds every referenced palette")
  local indexed = assert(out.materials[1], "the indexed material record survives")
  Assert.equal(indexed.textureFormat, 3, "the material keeps its resolved DS texture format")
  Assert.equal(indexed.texWidth, 8, "the material keeps the texture extent used to normalize UVs")
  Assert.equal(indexed.texHeight, 8, "the material keeps the texture extent used to normalize UVs")
  Assert.equal(indexed.wrap.x, "clamp", "the material keeps its sampler wrap state")
  Assert.equal(indexed.flip.x, false, "the material keeps its sampler flip state")
end

return { tests = T }
