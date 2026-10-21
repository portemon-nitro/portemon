-- Production acquisition, grant, save, and Continue: a received
-- selected starter records its caught fact before the dex grant, later
-- gifts add their own species, form, and language history, the
-- source-shaped grant operations enable the owner with their
-- compatibility writes, and a saved record Continues with identical
-- party specimens, history, flags, and menu visibility. Real headless
-- runtime over the prepared derived cache with the SoulSilver dump;
-- the HeartGold leg reports blocked while its dump stays unavailable.
-- No renderer is ever attached.

local Assert = require("tests.support.Assert")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldRuntime = require("game.hgss.src.field.FieldRuntime")
local GameVersion = require("romdump.src.source.GameVersion")
local PlayTime = require("libs.hgss.src.save.PlayTime")
local RomImporter = require("romdump.src.source.RomImporter")
local Runtime = require("libs.script.src.Runtime")
local RuntimeValues = require("libs.hgss.src.script.RuntimeValues")

local T = {}

local SERVICE_MODULE = "game.hgss.src.pokedex.PokedexScriptService"
local MAP = "MAP_NEW_BARK_PLAYER_HOUSE_2F"

local function runtimeOptions()
  local Fixture = require("tests.support.FieldStatePresentationFixture")
  return { presentation = false, derivedAssets = Fixture.iconHost().derivedAssets }
end

local function validEntry(versionId)
  return {
    saveId = "save-00000001",
    versionId = versionId,
    location = {
      mapSymbol = MAP,
      fieldX = 6,
      fieldZ = 6,
      facing = "south",
    },
    playerData = {
      profile = {
        name = "GOLD",
        rivalName = "Silver",
        gender = 0,
        trainerId = 1,
        money = 3000,
        badges = 0,
        nationalDex = false,
        runningShoes = false,
        runningShoesLock = false,
      },
      options = { textSpeed = "mid", textFrame = 0 },
    },
    fieldTravel = { lastHealSpawn = "SPAWN_NEW_BARK" },
    fashionCase = require("libs.hgss.src.save.FashionCaseState").empty(),
    playTime = PlayTime.new(),
    worldState = FieldEventState.new(),
    mons = require("tests.support.MonBucket").emptyForVersion(versionId),
    bag = require("libs.hgss.src.save.BagSave").empty(),
    mart = require("libs.hgss.src.save.MartSave").empty(),
  }
end

local function readyVersions()
  local versions = {}
  for _, versionId in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(versionId) then
      versions[#versions + 1] = versionId
    end
  end
  return versions
end

local function requireVersions(context)
  local versions = readyVersions()
  if #versions == 0 then
    if context ~= nil and type(context.hasCapability) == "function" then
      context:skip("requires rom_dump and prepared assets")
    end
    error("production field boot needs a ready versioned cache", 0)
  end
  return versions
end

local function settleCapture(runtime)
  local capture = assert(runtime.captureGameSave, "field runtime captures its own save")
  for _ = 1, 600 do
    local snapshot = capture(runtime)
    if snapshot ~= nil then
      return snapshot
    end
    runtime:update(1 / 30)
  end
  error("a fresh production boot never reaches a stable save boundary", 0)
end

local function continueBoot(snapshot, versionId)
  local runtime = nil
  local ok, err = xpcall(function()
    runtime = FieldRuntime.new(snapshot, runtimeOptions())
  end, debug.traceback)
  Assert.isTrue(ok, versionId .. " Continue boots its saved record: " .. tostring(err))
  assert(runtime ~= nil, "a successful Continue owns its runtime")
  Assert.isTrue(runtime.savePublished, "a captured snapshot Continues instead of starting over")
  return runtime
end

local function closeRuntime(runtime)
  local ok, err = pcall(function()
    runtime:dispose()
  end)
  Assert.isTrue(ok, "teardown releases the composed runtime: " .. tostring(err))
end

local function deepCopy(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for key, item in pairs(value) do
    out[key] = deepCopy(item)
  end
  return out
end

local function specimenIdentity(mon)
  return {
    species = mon.species,
    form = mon.form,
    personality = mon.personality,
    language = mon.origin.language,
  }
end

local function var(id)
  return { value = "var", id = id }
end

local function scriptRun(runtime, service)
  local stored = {}
  local host = {
    vars = stored,
    getVar = function(self, id)
      return self.vars[id]
    end,
    setVar = function(self, id, value)
      self.vars[id] = value
    end,
  }
  return {
    instance = { scriptId = "receipt-and-continue-fixture", locals = {}, textArgs = {} },
    services = { mons = runtime.monService, pokedex = service, world = host },
    semantics = RuntimeValues,
  }
end

local function requireScriptService()
  local ok, service = pcall(require, SERVICE_MODULE)
  Assert.isTrue(ok, "the field script composition owns the dex grant service")
  return assert(service)
end

local function runReceiptJourney(versionId)
  local first = FieldRuntime.new(validEntry(versionId), runtimeOptions())
  local ok, err = xpcall(function()
    local monService = assert(first.monService, "the runtime composes its mon service")
    local owner = assert(first.dexKnowledge, "the runtime composes the single dex owner")
    Assert.isFalse(owner:hasPokedex(), versionId .. " starts with the dex locked")
    Assert.isTrue(
      type(monService.receiveMon) == "function",
      versionId .. " receives selected starters through explicit receipt"
    )

    local candidate = monService:buildStarter("TOTODILE")
    local callsBefore = monService:capture().rng.calls
    Assert.isTrue(monService:receiveMon(candidate), versionId .. " receives the selected starter")
    Assert.equal(monService:partyCount(), 1, versionId .. " inserts the selected candidate")
    Assert.deepEqual(
      specimenIdentity(monService:partyMon(0)),
      specimenIdentity(candidate),
      versionId .. " keeps the exact admitted starter identity"
    )
    Assert.equal(monService:capture().rng.calls, callsBefore, versionId .. " never rerolls the admitted starter")
    Assert.isTrue(owner:isCaught("TOTODILE"), versionId .. " retains the pre-grant acquisition as history")

    Assert.isTrue(
      monService:giveMon({ species = "CHIKORITA", level = 5, heldItem = "NONE", form = 0 }),
      versionId .. " receives the follow-up gift"
    )
    Assert.isTrue(owner:isCaught("CHIKORITA"), versionId .. " records the gift capture")
    Assert.isTrue(
      monService:giveMon({ species = "ROTOM", level = 5, heldItem = "NONE", form = 1 }),
      versionId .. " receives the form-varied gift"
    )
    Assert.equal(monService:partyMon(2).form, 1, versionId .. " keeps the admitted appliance form")
    Assert.isTrue(owner:isCaught("ROTOM"), versionId .. " records the form-varied capture")

    local foreign = deepCopy(monService:partyMon(0))
    foreign.origin.language = "french"
    Assert.isTrue(monService:receiveMon(foreign), versionId .. " receives the foreign duplicate")
    Assert.deepEqual(
      owner:caughtLanguages("TOTODILE"),
      { "english", "french" },
      versionId .. " adds language history without duplicating the species"
    )
    Assert.isTrue(
      owner:hasInternationalDex(),
      versionId .. " enables the international capability from the foreign capture"
    )
    Assert.equal(monService:partyCount(), 4, versionId .. " holds every received mon")

    local ScriptService = requireScriptService()
    local service = ScriptService.new({
      dex = owner,
      catalog = assert(first.pokedexCatalog, "the runtime borrows the generated dex catalog"),
      profile = first.playerData.profile,
      eventState = first.eventState,
    })
    local run = scriptRun(first, service)
    Assert.equal(
      Runtime.executeNode({ op = "give_pokedex" }, run),
      Runtime.OUTCOME_CONTINUE,
      versionId .. " executes the dex grant"
    )
    Assert.isTrue(owner:hasPokedex(), versionId .. " enables the dex through the grant")
    Assert.isTrue(
      first.eventState:isFlagSet(107),
      versionId .. " writes the story compatibility flag through the grant"
    )
    Assert.equal(
      Runtime.executeNode({ op = "national_pokedex", action = "enable", result = var("VAR_RESULT") }, run),
      Runtime.OUTCOME_CONTINUE,
      versionId .. " executes the national enable"
    )
    Assert.isTrue(owner:hasNationalDex(), versionId .. " enables national ownership")
    Assert.isTrue(first.playerData.profile.nationalDex, versionId .. " keeps the profile compatibility value coherent")

    local identities = {}
    for slot = 0, monService:partyCount() - 1 do
      identities[slot] = specimenIdentity(monService:partyMon(slot))
    end
    local bucketBefore = deepCopy(owner:bucket())
    local snapshot = settleCapture(first)
    Assert.deepEqual(snapshot.pokedex, bucketBefore, versionId .. " save capture persists the owner state")

    local runtime = continueBoot(snapshot, versionId)
    local continuedOwner = assert(runtime.dexKnowledge, "Continue recomposes the dex owner")
    local continuedMons = assert(runtime.monService, "Continue recomposes the mon service")
    Assert.deepEqual(
      continuedOwner:bucket(),
      bucketBefore,
      versionId .. " Continue restores the exact history and flags"
    )
    Assert.equal(continuedMons:partyCount(), 4, versionId .. " Continue restores every received mon")
    for slot = 0, 3 do
      Assert.deepEqual(
        specimenIdentity(continuedMons:partyMon(slot)),
        identities[slot],
        versionId .. " Continue keeps slot " .. slot .. " identity"
      )
    end
    Assert.deepEqual(
      continuedOwner:caughtLanguages("TOTODILE"),
      { "english", "french" },
      versionId .. " Continue preserves language acquisition order"
    )
    Assert.deepEqual(continuedOwner:resume(), {}, versionId .. " resume stays unset without the browser")
    Assert.isTrue(
      continuedOwner:hasPokedex() and continuedOwner:hasNationalDex(),
      versionId .. " Continue preserves both ownership flags"
    )
    Assert.isTrue(
      runtime.playerData.profile.nationalDex,
      versionId .. " Continue keeps the profile compatibility value coherent"
    )
    Assert.isTrue(runtime.eventState:isFlagSet(107), versionId .. " Continue preserves the story compatibility flag")
    local continuedSnapshot = settleCapture(runtime)
    Assert.deepEqual(
      continuedSnapshot.pokedex,
      bucketBefore,
      versionId .. " no Continue path duplicates or scans history back"
    )
    closeRuntime(runtime)
  end, debug.traceback)
  local closeOk, closeErr = pcall(function()
    first:dispose()
  end)
  if ok and not closeOk then
    ok, err = false, closeErr
  end
  if not ok then
    error(err, 0)
  end
end

function T.received_mons_grants_and_save_survive_continue(context)
  for _, versionId in ipairs(requireVersions(context)) do
    runReceiptJourney(versionId)
  end
end

function T.heartgold_receipt_leg_stays_blocked_without_a_dump(context)
  if not RomImporter.isReady("heartgold") then
    assert(context ~= nil, "blocked-version reporting needs its runner context")
    context:skip("heartgold dump not owned; the heartgold receipt legs stay blocked")
    return
  end
  runReceiptJourney("heartgold")
end

return {
  tests = T,
  metadata = {
    capabilities = { "rom_dump", "derived_assets" },
    derivedAssets = {
      "field-runtime",
      "map:64",
      "map-data:64",
      "trainers:global",
      "encounters:global",
      "audio-bank:702",
      "pokedex-data:global",
    },
    tags = { "pokedex" },
  },
}
