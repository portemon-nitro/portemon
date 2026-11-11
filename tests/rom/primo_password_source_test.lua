-- Password and avatar source conformance against the user-owned dump:
-- the compiled word-editor family carries the full ordered password
-- bank and the sixteen avatar rows, every password word resolves
-- through the real compiled dictionary, and the research fixture
-- phrases decode to their exact rewards behind the visible trainer
-- identity through the production script service. Source word
-- identities only, never copied dump bytes or commercial text.

local Assert = require("tests.support.Assert")
local RomSuite = require("tests.rom.support.RomSuite")

local T = {}

-- Source password phrases behind the visible trainer identity below.
local TRAINER_ID = 12345
local FIXTURES = {
  { words = { 1007, 1048, 1050, 1064 }, wallpaper = 0 },
  { words = { 1299, 1369, 981, 1331 }, wallpaper = 7 },
  { words = { 1150, 1413, 1134, 1152 }, egg = 8 },
  { words = { 1084, 1320, 1354, 1410 }, egg = 9 },
  { words = { 1132, 1308, 1007, 1077 }, egg = 10 },
}

---@param romFs table dump reader
---@param versionId string
---@return table shared word catalog compiled from the dump
local function compiledCatalog(romFs, versionId)
  local Compiler = require("romdump.src.digest.ui.EasyChatCompiler")
  local MonCatalogCompiler = require("romdump.src.digest.mons.MonCatalogCompiler")
  local ItemFixture = require("libs.items.tests.item_fixture")
  local MonCatalog = require("libs.mons.src.MonCatalog")
  local monRoot = assert(
    MonCatalogCompiler.compileCatalog(romFs, { versionId = versionId }),
    versionId .. " compiles its mon catalog for the species join"
  )
  local monCatalog = MonCatalog.new(monRoot, ItemFixture.makeCatalog())
  local data, dataErr = Compiler.compileData(romFs, versionId, monCatalog)
  Assert.notNil(data, versionId .. " compiles its word editor data: " .. tostring(dataErr))
  assert(data ~= nil, "compiled data asserted above")
  local Catalog = require("libs.hgss.src.ui.EasyChatCatalog")
  return Catalog.new(data)
end

---@param profile table live player profile
---@return table service instance behind the compiled catalog
local function serviceBehind(catalog, profile)
  local Service = require("game.hgss.src.easychat.EasyChatScriptService")
  local State = require("libs.hgss.src.save.EasyChatState")
  local unlocks = { false, false, false, false, false, false, false, false }
  local mons = {}
  function mons:boxBonusUnlocks()
    local copy = {}
    for index = 1, 8 do
      copy[index] = unlocks[index]
    end
    return copy
  end
  function mons:partyRevision()
    return 1
  end
  function mons:boxRevision()
    return 1
  end
  function mons:preparePcChanges(_, changes)
    for index = 1, 8 do
      unlocks[index] = changes.bonusUnlocks[index]
    end
    return {
      publish = function() end,
    }
  end
  local random = {}
  function random:lc(_)
    error("password checks consume no random draws", 0)
  end
  return Service.new({
    catalog = catalog,
    state = State.restore(nil, "english", catalog),
    profile = profile,
    mons = mons,
    world = {},
    random = random,
    messageProvider = {
      acquireBank = function()
        return nil, "unused"
      end,
      releaseBank = function() end,
    },
  })
end

---@param trainerId integer
---@param gender integer
---@return table live profile stub
local function profile(trainerId, gender)
  return {
    name = "GOLD",
    rivalName = "Silver",
    gender = gender,
    trainerId = trainerId,
    money = 3000,
    badges = {},
    nationalDex = false,
    runningShoes = false,
    runningShoesLock = false,
  }
end

-- The compiled family keeps the full ordered password bank: every entry
-- resolves through the real compiled dictionary, so no password word is
-- withheld from selection by a compilation gap.
function T.compiled_password_bank_resolves_through_the_dictionary(romFs, versionId)
  local catalog = compiledCatalog(romFs, versionId)
  local bank = assert(catalog.primoWords, versionId .. " keeps its password word order")
  Assert.equal(#bank, 351, versionId .. " keeps the full password word order")
  for _, word in ipairs(bank) do
    local tokens = catalog:wordTokens(word)
    Assert.isTrue(#tokens > 0, versionId .. " password word " .. word .. " resolves its display fragments")
  end
end

-- The fixture phrases decode to their exact rewards through the real
-- service and the dump-compiled bank; the opposite family and a
-- different visible identity reject them.
function T.fixture_phrases_decode_to_their_research_rewards(romFs, versionId)
  local catalog = compiledCatalog(romFs, versionId)
  local owned = serviceBehind(catalog, profile(TRAINER_ID, 0))
  for _, fixture in ipairs(FIXTURES) do
    if fixture.wallpaper ~= nil then
      Assert.equal(
        owned:checkPrimoWallpaper(fixture.words),
        fixture.wallpaper + 1,
        versionId .. " the wallpaper phrase reports its one-based slot"
      )
      Assert.equal(owned:checkPrimoEgg(fixture.words), 255, versionId .. " the wallpaper phrase stays invalid for eggs")
    else
      Assert.equal(
        owned:checkPrimoEgg(fixture.words),
        fixture.egg,
        versionId .. " the egg phrase answers its one-time code"
      )
      Assert.equal(
        owned:checkPrimoWallpaper(fixture.words),
        255,
        versionId .. " the egg phrase stays invalid for wallpapers"
      )
    end
  end
  local other = serviceBehind(catalog, profile(12346, 0))
  Assert.equal(
    other:checkPrimoEgg(FIXTURES[3].words),
    255,
    versionId .. " a different visible identity rejects the egg phrase"
  )
end

-- The compiled avatar tables resolve the offered choices for both
-- halves without withholding rows.
function T.compiled_avatar_tables_resolve_both_gender_halves(romFs, versionId)
  local catalog = compiledCatalog(romFs, versionId)
  local avatars = assert(catalog.unionAvatars, versionId .. " keeps its avatar tables")
  Assert.equal(#avatars.choices, 8, versionId .. " keeps all eight choice rows")
  Assert.equal(#avatars.rows, 16, versionId .. " keeps all sixteen attribute rows")
  for _, gender in ipairs({ 0, 1 }) do
    local owned = serviceBehind(catalog, profile(TRAINER_ID, gender))
    local offered = owned:unionAvatarChoices()
    Assert.equal(#offered, 4, versionId .. " the selector offers four choices")
    for _, record in ipairs(offered) do
      Assert.isTrue(
        type(record.spriteId) == "number" and type(record.classId) == "number",
        versionId .. " the offered records carry their sprite and class"
      )
    end
    Assert.isTrue(type(owned:unionAvatarClass()) == "number", versionId .. " the saved row answers its class")
  end
end

local suite = RomSuite.fromFacts(T)
suite.metadata.tags = { "easychat" }
return suite
