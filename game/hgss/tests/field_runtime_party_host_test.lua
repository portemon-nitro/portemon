-- Script party host lifetime inside the field runtime boot: the host
-- is constructed after the mon service, manifest, and display facts
-- exist, released exactly once in teardown, and a manifest failure
-- fails the boot loudly with no half-built host. ROM-backed cache.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FieldRuntime = require("game.hgss.src.field.FieldRuntime")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local GameVersion = require("romdump.src.source.GameVersion")
local PartyCache = require("libs.assets.src.PartyCache")
local PlayTime = require("libs.hgss.src.save.PlayTime")
local RomImporter = require("romdump.src.source.RomImporter")

local T = {
  metadata = { capabilities = { "rom_dump", "derived_assets" }, derivedAssets = { "field-runtime", "map:64" } },
  tests = {},
}

local function readyVersions()
  local versions = {}
  for _, versionId in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(versionId) then
      local cacheFs = CacheFs.forVersion(versionId)
      local marker = cacheFs:read(PartyCache.markerPath())
      if marker ~= nil and PartyCache.isReady(cacheFs, marker) then
        versions[#versions + 1] = versionId
      end
    end
  end
  return versions
end

local function validEntry(versionId, withBuckets)
  local entry = {
    saveId = "save-00000001",
    versionId = versionId,
    location = {
      mapSymbol = "MAP_NEW_BARK_PLAYER_HOUSE_2F",
      fieldX = 6,
      fieldZ = 6,
      facing = "south",
    },
    playerData = {
      profile = { name = "GOLD", gender = 0, trainerId = 1, money = 3000, badges = 0 },
      options = { textSpeed = "mid", textFrame = 0 },
    },
    fieldTravel = { lastHealSpawn = "SPAWN_NEW_BARK" },
    playTime = PlayTime.new(),
    worldState = FieldEventState.new(),
  }
  if withBuckets ~= false then
    entry.mons = require("tests.support.MonBucket").emptyForVersion(versionId)
    entry.bag = require("libs.hgss.src.save.BagSave").empty()
    entry.fashionCase = require("libs.hgss.src.save.FashionCaseState").empty()
  end
  return entry
end

function T.tests.boot_builds_and_teardown_releases_the_host(context)
  local versions = readyVersions()
  if #versions == 0 then
    if context ~= nil and type(context.hasCapability) == "function" then
      context:skip("requires rom_dump and prepared assets")
    end
    error("party host boot needs a ready versioned cache", 0)
  end
  for _, versionId in ipairs(versions) do
    local runtime = FieldRuntime.new(validEntry(versionId), { presentation = false })
    local host = assert(runtime.partySelection, "boot constructs the script party host")
    Assert.equal(runtime.fashionCase:quantity(0), 0, "boot keeps the live Fashion Case state")
    Assert.isNil(host:status(), "a fresh boot owns no open selection")
    runtime:dispose()
    Assert.isNil(runtime.partySelection, "teardown releases the host field")
    runtime:dispose()
  end
end

function T.tests.manifest_failure_fails_boot_loudly(context)
  local versions = readyVersions()
  if #versions == 0 then
    if context ~= nil and type(context.hasCapability) == "function" then
      context:skip("requires rom_dump and prepared assets")
    end
    error("party host boot needs a ready versioned cache", 0)
  end
  for _, versionId in ipairs(versions) do
    local saved = package.loaded["libs.assets.src.PartyCache"]
    package.loaded["libs.assets.src.PartyCache"] = {
      loadManifest = function(_)
        error("sabotaged party manifest", 0)
      end,
    }
    local ok, err = pcall(function()
      FieldRuntime.new(validEntry(versionId), { presentation = false })
    end)
    package.loaded["libs.assets.src.PartyCache"] = saved
    Assert.isFalse(ok, "a missing party manifest fails the boot loudly")
    Assert.notNil(tostring(err):find("sabotaged party manifest"), "the collaborator failure surfaces")
  end
end

function T.tests.fresh_runtime_disposal_tolerates_no_host()
  local loaded = false
  local originalLoad = FieldRuntime._load
  FieldRuntime._load = function(_)
    loaded = true
  end
  local ok, runtime = pcall(FieldRuntime.new, validEntry("heartgold", false), { presentation = false })
  FieldRuntime._load = originalLoad
  Assert.isTrue(ok, tostring(runtime))
  Assert.isTrue(loaded, "construction runs the load step")
  Assert.isNil(runtime.partySelection, "an unloaded runtime owns no selection")
  runtime:dispose()
  Assert.isNil(runtime.partySelection, "teardown tolerates the absent host")
end

return T
