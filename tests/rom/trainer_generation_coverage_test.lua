-- Trainer generation against the runner-provided dump: the compiled
-- native catalog exposes every party shape with the rival indirection
-- intact, and compiled trainers materialize ordered parties whose class
-- and levels match the compiled record. Each case covers the single
-- version the runner hands it; the runner owns the dump handle, so these
-- cases open and close nothing themselves.

local Assert = require("tests.support.Assert")
local RomSuite = require("tests.rom.support.RomSuite")
local BattleRng = require("libs.battle.src.gen4.BattleRng")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local ItemFixture = require("libs.items.tests.item_fixture")

local T = {}

local FIXED_SEED = 287454020

---@param name string module path under test
---@param behavior string observable behavior the module owns
---@return table the loaded module
local function requirePresent(name, behavior)
  local ok, loaded = pcall(require, name)
  Assert.isTrue(ok, "missing trainer behavior: " .. behavior .. " (" .. name .. ")")
  assert(loaded ~= nil, "the trainer module loads")
  return loaded --[[@as table]]
end

---@param seed integer
---@return table labeled native stream recording every draw site
local function spyStream(seed)
  local inner = BattleRng.new(seed)
  local labels = {}
  local stream = {}
  function stream:nextU16(label, cause)
    labels[#labels + 1] = label
    return inner:nextU16(label, cause)
  end
  function stream:capture()
    return inner:capture()
  end
  function stream:drawLabels()
    local out = {}
    for index, label in ipairs(labels) do
      out[index] = label
    end
    return out
  end
  return stream
end

-- The compiled dump catalog loads through the runtime catalog with every
-- party shape, the rival indirection, and native order intact.
function T.compiled_native_trainers_expose_every_party_shape(romFs, versionId)
  Assert.notNil(romFs, "the party-shape check runs with its ready dump open")
  Assert.isTrue(type(versionId) == "string" and versionId ~= "", "the party-shape check names its version")
  local Catalog =
    requirePresent("libs.hgss.src.battle.HgssTrainerCatalog", "immutable trainer templates resolve runtime content keys")
  local Compiler = require("romdump.src.digest.battle.TrainerCatalogCompiler")
  local compiled = assert(Compiler.compileFromDump(romFs, { versionId = versionId }))
  local catalog = Catalog.new(compiled)
  local keys = {}
  for key in pairs(compiled.trainers) do
    keys[#keys + 1] = key
  end
  table.sort(keys)
  Assert.isTrue(#keys > 0, versionId .. " carries trainer records")
  local seenShapes = {}
  local seenRival = false
  for _, key in ipairs(keys) do
    local template = Catalog.trainer(catalog, key)
    Assert.notNil(template, versionId .. " trainer " .. tostring(key) .. " loads")
    local record = assert(template, "the template loads")
    Assert.isTrue(type(record.party) == "table" and #record.party > 0, "parties keep ordered members")
    for _, member in ipairs(record.party) do
      local shape = (member.moves ~= nil and "moves" or "plain")
        .. "+"
        .. (member.heldItem ~= "NONE" and "item" or "noitem")
      seenShapes[shape] = true
    end
    if record.nameReference ~= nil and record.nameReference.rival == true then
      seenRival = true
    end
  end
  for _, shape in ipairs({ "plain+noitem", "moves+noitem", "plain+item", "moves+item" }) do
    Assert.isTrue(seenShapes[shape] == true, "the native catalog exercises party shape " .. shape)
  end
  Assert.isTrue(seenRival, "the native catalog carries the rival indirection")
end

-- Real compiled trainers resolve through the runtime catalog and
-- materialize valid domain parties whose ordered levels and class match
-- the compiled record exactly; rebuilding under a renamed rival replays
-- every personality, proving the name indirection never enters the party
-- seed.
function T.dump_backed_trainers_materialize_ordered_parties_matching_the_compiled_record(romFs, versionId)
  Assert.notNil(romFs, "trainer materialization runs with its ready dump open")
  Assert.isTrue(type(versionId) == "string" and versionId ~= "", "trainer materialization names its version")
  local Catalog =
    requirePresent("libs.hgss.src.battle.HgssTrainerCatalog", "immutable trainer templates resolve runtime content keys")
  local Factory = requirePresent("libs.hgss.src.battle.HgssTrainerFactory", "source trainer generation builds native parties")
  local Mon = require("libs.mons.src.Mon")
  local MonStats = require("libs.mons.src.gen4.MonStats")
  local MonCatalog = require("libs.mons.src.MonCatalog")
  local MonCatalogCompiler = require("romdump.src.digest.mons.MonCatalogCompiler")
  local MonSources = require("romdump.src.config.MonSources")
  local Compiler = require("romdump.src.digest.battle.TrainerCatalogCompiler")
  local compiled = assert(Compiler.compileFromDump(romFs, { versionId = versionId }))
  local monRoot = assert(MonCatalogCompiler.compileCatalog(romFs, { versionId = versionId }))
  local monCatalog = MonCatalog.new(monRoot, ItemFixture.makeCatalog())
  local domain = {
    catalog = monCatalog,
    charmap = CatalogFixture.CHARMAP,
    games = CatalogFixture.GAMES,
    languages = CatalogFixture.LANGUAGES,
  }
  local catalog = Catalog.new(compiled)
  local factory = Factory.new({
    catalog = catalog,
    monCatalog = monCatalog,
    charmap = CatalogFixture.CHARMAP,
    games = CatalogFixture.GAMES,
    languages = CatalogFixture.LANGUAGES,
    game = versionId,
    language = MonSources.versionLanguages[versionId],
  })
  local keys = {}
  for key in pairs(compiled.trainers) do
    keys[#keys + 1] = key
  end
  table.sort(keys)
  Assert.isTrue(#keys > 0, versionId .. " carries trainer records")
  local samples = {}
  for _, key in ipairs(keys) do
    if #samples < 3 then
      samples[#samples + 1] = key
    end
  end
  local rivalKey = nil
  for _, key in ipairs(keys) do
    local template = Catalog.trainer(catalog, key)
    if template ~= nil and template.nameReference ~= nil and template.nameReference.rival == true then
      rivalKey = key
      break
    end
  end
  if rivalKey ~= nil then
    samples[#samples + 1] = rivalKey
  end
  for _, key in ipairs(samples) do
    local template = assert(Catalog.trainer(catalog, key), versionId .. " trainer " .. key .. " loads")
    local bundle = factory:build({ trainerKey = key, rivalName = "SILVER", rng = spyStream(FIXED_SEED) })
    Assert.equal(bundle.trainerClass, template.trainerClass, "trainer " .. key .. " keeps its native class")
    local mons = assert(bundle.mons, "trainer " .. key .. " materializes its ordered mons")
    Assert.equal(#mons, #template.party, "trainer " .. key .. " keeps every ordered slot")
    for index, mon in ipairs(mons) do
      local ok = pcall(Mon.validate, mon, domain)
      Assert.isTrue(ok, "trainer " .. key .. " slot " .. index .. " validates")
      Assert.equal(
        MonStats.derive(mon, monCatalog).level,
        template.party[index].level,
        "trainer " .. key .. " slot " .. index .. " keeps its compiled level"
      )
    end
    if template.nameReference ~= nil and template.nameReference.rival == true then
      local renamed = factory:build({ trainerKey = key, rivalName = "GARY", rng = spyStream(FIXED_SEED) })
      local renamedMons = assert(renamed.mons, "the renamed rival keeps its ordered mons")
      Assert.equal(renamed.name, "GARY", "the rival name stays an indirection")
      for index, mon in ipairs(mons) do
        Assert.equal(mon.personality, renamedMons[index].personality, "the rival seed ignores the display name")
      end
    end
  end
end

return RomSuite.fromFacts(T)
