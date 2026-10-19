-- Field Continue composes the single authoritative dex owner: production
-- boot restores legacy and missing buckets with their story and profile
-- seeds, keeps a valid v2 bucket authoritative over stale seeds, captures
-- the same owner into saves, and releases borrowed references on
-- teardown. Real headless runtime over the prepared derived cache with
-- the SoulSilver dump; the HeartGold leg reports blocked while its dump
-- stays unavailable. No renderer is ever attached.

local Assert = require("tests.support.Assert")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldRuntime = require("game.hgss.src.field.FieldRuntime")
local GameVersion = require("romdump.src.source.GameVersion")
local PlayTime = require("libs.hgss.src.save.PlayTime")
local RomImporter = require("romdump.src.source.RomImporter")

local T = {}

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

--- Captures the live runtime once its fresh boot reaches a stable save
--- boundary, advancing fixed ticks with a bounded diagnostic budget.
---@param runtime table<string, unknown>
---@return table<string, unknown>
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

local function legacyBucket()
  return {
    schema = "hgss-pokedex-v1",
    stateVersion = 1,
    seen = { "CHIKORITA", "TOTODILE" },
    caught = { "TOTODILE", "SPINDA" },
  }
end

local function currentBucket()
  return {
    schema = "hgss-pokedex-v2",
    stateVersion = 2,
    seen = { "CHIKORITA", "SPINDA" },
    caught = { "SPINDA" },
    flags = {
      dexEnabled = true,
      nationalDex = true,
      enabledInternational = false,
      canDetectForms = true,
    },
    history = {},
    resume = {},
  }
end

local function continueBoot(snapshot, versionId)
  local runtime = nil
  local ok, err = xpcall(function()
    runtime = FieldRuntime.new(snapshot, runtimeOptions())
  end, debug.traceback)
  Assert.isTrue(ok, versionId .. " Continue boots its saved record: " .. tostring(err))
  assert(runtime ~= nil, "a successful Continue owns its runtime")
  Assert.isTrue(runtime.savePublished, "a captured snapshot Continues instead of starting over")
  Assert.notNil(runtime.dexKnowledge, "Continue composes the single dex owner")
  Assert.notNil(runtime.monService, "Continue composes the mon service beside the dex owner")
  return runtime
end

local function checkSaveCapturesOwner(runtime, versionId)
  local snapshot = settleCapture(runtime)
  Assert.deepEqual(
    snapshot.pokedex,
    runtime.dexKnowledge:bucket(),
    versionId .. " save capture persists the same owner state"
  )
end

local function closeRuntime(runtime)
  local ok, err = pcall(function()
    runtime:dispose()
  end)
  Assert.isTrue(ok, "teardown releases the composed runtime: " .. tostring(err))
  Assert.isNil(runtime.pokedexCatalog, "teardown releases the borrowed generated catalog reference")
end

local function runLegacyJourney(versionId)
  local first = FieldRuntime.new(validEntry(versionId), runtimeOptions())
  local ok, err = xpcall(function()
    first.eventState:setFlag(107)
    local snapshot = settleCapture(first)
    Assert.isTrue(
      snapshot.world.flags[107] == true,
      "production capture carries the story flag seed into the saved record"
    )
    snapshot.playerData.profile.nationalDex = true
    snapshot.pokedex = legacyBucket()
    local runtime = continueBoot(snapshot, versionId)
    local owner = runtime.dexKnowledge
    Assert.isTrue(owner:hasPokedex(), versionId .. " restores dex ownership from the story flag seed")
    Assert.isTrue(owner:hasNationalDex(), versionId .. " restores national ownership from the profile seed")
    Assert.isFalse(owner:hasInternationalDex(), versionId .. " leaves historically absent capabilities disabled")
    Assert.isFalse(owner:canDetectForms(), versionId .. " leaves historically absent capabilities disabled")
    Assert.isTrue(owner:isSeen("SPINDA"), versionId .. " unions legacy caught into seen")
    Assert.deepEqual(
      owner:bucket().seen,
      { "CHIKORITA", "SPINDA", "TOTODILE" },
      versionId .. " canonicalizes the migrated bits"
    )
    Assert.deepEqual(owner:observedGenders("SPINDA"), {}, versionId .. " migrates no invented gender provenance")
    Assert.isNil(owner:firstPersonality("SPINDA"), versionId .. " migrates no invented Spinda personality")
    Assert.deepEqual(owner:resume(), {}, versionId .. " migrates the unset resume mode")
    Assert.isTrue(
      runtime.playerData.profile.nationalDex,
      versionId .. " reconciles the profile compatibility value from the owner"
    )
    checkSaveCapturesOwner(runtime, versionId)
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

local function runMissingJourney(versionId)
  local first = FieldRuntime.new(validEntry(versionId), runtimeOptions())
  local ok, err = xpcall(function()
    local snapshot = settleCapture(first)
    snapshot.playerData.profile.nationalDex = false
    snapshot.pokedex = nil
    local runtime = continueBoot(snapshot, versionId)
    local owner = runtime.dexKnowledge
    Assert.deepEqual(owner:bucket().seen, {}, versionId .. " a missing bucket starts with no seen bits")
    Assert.deepEqual(owner:bucket().caught, {}, versionId .. " a missing bucket starts with no caught bits")
    Assert.isFalse(owner:hasPokedex(), versionId .. " a missing bucket without seeds stays locked")
    Assert.isFalse(owner:hasNationalDex(), versionId .. " a missing bucket without seeds stays locked")
    Assert.deepEqual(owner:resume(), {}, versionId .. " a missing bucket starts with the unset resume")
    checkSaveCapturesOwner(runtime, versionId)
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

local function runCurrentJourney(versionId)
  local first = FieldRuntime.new(validEntry(versionId), runtimeOptions())
  local ok, err = xpcall(function()
    local snapshot = settleCapture(first)
    snapshot.playerData.profile.nationalDex = false
    snapshot.pokedex = currentBucket()
    local runtime = continueBoot(snapshot, versionId)
    local owner = runtime.dexKnowledge
    Assert.isTrue(owner:hasPokedex(), versionId .. " keeps valid v2 ownership without legacy seeds")
    Assert.isTrue(owner:hasNationalDex(), versionId .. " keeps valid v2 national ownership")
    Assert.isFalse(owner:hasInternationalDex(), versionId .. " keeps valid v2 international state authoritative")
    Assert.isTrue(owner:canDetectForms(), versionId .. " keeps valid v2 form detection authoritative")
    Assert.isTrue(
      runtime.playerData.profile.nationalDex,
      versionId .. " reconciles the profile compatibility value from the valid owner"
    )
    Assert.isFalse(
      runtime.eventState:isFlagSet(107),
      versionId .. " never rewrites the story flag from valid v2 ownership"
    )
    Assert.equal(
      owner:bucket().schema,
      "hgss-pokedex-v2",
      versionId .. " persists the current bucket shape through Continue"
    )
    checkSaveCapturesOwner(runtime, versionId)
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

function T.continue_restores_legacy_buckets_with_their_seeds(context)
  for _, versionId in ipairs(requireVersions(context)) do
    runLegacyJourney(versionId)
  end
end

function T.continue_starts_missing_buckets_empty_with_their_seeds(context)
  for _, versionId in ipairs(requireVersions(context)) do
    runMissingJourney(versionId)
  end
end

function T.continue_keeps_valid_v2_authoritative_over_stale_seeds(context)
  for _, versionId in ipairs(requireVersions(context)) do
    runCurrentJourney(versionId)
  end
end

function T.heartgold_continue_leg_stays_blocked_without_a_dump(context)
  if not RomImporter.isReady("heartgold") then
    assert(context ~= nil, "blocked-version reporting needs its runner context")
    context:skip("heartgold dump not owned; the heartgold Continue legs stay blocked")
    return
  end
  runLegacyJourney("heartgold")
  runMissingJourney("heartgold")
  runCurrentJourney("heartgold")
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
