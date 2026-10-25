-- Version-scoped source closure for the staged battle presentation:
-- the HeartGold dump stages a versioned manifest with its own
-- identity, complete slot/HUD/picture/audio inventories, and exact
-- scene records, while missing or corrupt scene keys fail closed with
-- context instead of substituting another scene. SoulSilver has no
-- supplied dump, so its leg of the closure is recorded blocked with
-- that evidence. Needs a ready user-owned HeartGold dump with a
-- prepared derived cache, otherwise the HeartGold legs skip.

local Assert = require("tests.support.Assert")

local T = {}

---@param context table test context under driving
---@return string[] ready game version identities
local function readyVersions(context)
  local GameVersion = require("romdump.src.source.GameVersion")
  local RomImporter = require("romdump.src.source.RomImporter")
  local versions = {}
  for _, versionId in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(versionId) then
      versions[#versions + 1] = versionId
    end
  end
  if #versions == 0 then
    context:skip("the versioned closure needs a ready user-owned dump with a derived cache")
  end
  return versions
end

---@param versions string[] ready version identities under inspection
---@param want string version identity under lookup
---@return boolean true once the version is ready
local function hasVersion(versions, want)
  for _, versionId in ipairs(versions) do
    if versionId == want then
      return true
    end
  end
  return false
end

-- The staged global manifest carries its own version identity and the
-- current catalog schema: HeartGold evidence never passes as another
-- version's manifest.
function T.heartgold_manifest_carries_its_versioned_identity(context)
  local versions = readyVersions(context)
  if not hasVersion(versions, "heartgold") then
    context:skip("the HeartGold leg needs its ready user-owned dump with a derived cache")
  end
  local CacheFs = require("libs.storage.src.CacheFs")
  local BattlePresentationCache = require("libs.assets.src.battle.BattlePresentationCache")
  local cacheFs = CacheFs.forVersion("heartgold")
  local manifest = BattlePresentationCache.load(cacheFs)
  Assert.equal(manifest.schema, BattlePresentationCache.MANIFEST_SCHEMA, "heartgold stages the current catalog schema")
  Assert.equal(manifest.version.id, "heartgold", "the staged manifest names its own version")
end

-- The staged inventory holds all six source side-type geometries with
-- both doubled health-box variants and non-empty picture selectors.
function T.heartgold_stages_slot_hud_and_picture_inventories(context)
  local versions = readyVersions(context)
  if not hasVersion(versions, "heartgold") then
    context:skip("the HeartGold leg needs its ready user-owned dump with a derived cache")
  end
  local CacheFs = require("libs.storage.src.CacheFs")
  local BattlePresentationCache = require("libs.assets.src.battle.BattlePresentationCache")
  local manifest = BattlePresentationCache.load(CacheFs.forVersion("heartgold"))
  Assert.equal(#manifest.battlefield.slots, 6, "heartgold stages all six source slot geometries")
  local sideTypes = {}
  for _, row in ipairs(manifest.battlefield.slots) do
    sideTypes[row.sideType] = true
  end
  for sideType = 0, 5 do
    Assert.isTrue(sideTypes[sideType] == true, "heartgold stages side type " .. sideType)
  end
  local doubles = assert(manifest.hud.doubles, "heartgold stages the doubled health-box family")
  for _, corner in ipairs({ "playerLeft", "playerRight", "enemyLeft", "enemyRight" }) do
    Assert.notNil(doubles[corner], "heartgold stages the " .. corner .. " health-box variant")
  end
  Assert.isTrue(
    type(manifest.pictures.selectors) == "table" and next(manifest.pictures.selectors) ~= nil,
    "heartgold stages source picture selectors"
  )
  local roles = assert(manifest.audioRoles, "heartgold stages its audio roles")
  for _, role in ipairs({ "wild", "trainer", "rival", "select", "cries" }) do
    Assert.isTrue(type(roles[role]) == "string", "heartgold stages its " .. role .. " audio role")
  end
end

-- A staged ordinary scene loads with its exact key; a well-formed but
-- unstaged key and a corrupt key both fail closed with context naming
-- the requested key, never a substitute scene.
function T.heartgold_scenes_load_exactly_and_missing_keys_fail_closed(context)
  local versions = readyVersions(context)
  if not hasVersion(versions, "heartgold") then
    context:skip("the HeartGold leg needs its ready user-owned dump with a derived cache")
  end
  local CacheFs = require("libs.storage.src.CacheFs")
  local BattlePresentationCache = require("libs.assets.src.battle.BattlePresentationCache")
  local Sources = require("romdump.src.config.BattlePresentationSources")
  local cacheFs = CacheFs.forVersion("heartgold")
  local record, loadErr = BattlePresentationCache.loadScene(cacheFs, "general/grass/day")
  Assert.notNil(record, "heartgold stages its ordinary grass scene: " .. tostring(loadErr))
  Assert.equal(record.key, "general/grass/day", "the staged scene names exactly its requested key")
  Assert.notNil(Sources.parseSceneKey(record.key), "the staged scene key parses in the source namespaces")
  local missing, missingErr = BattlePresentationCache.loadScene(cacheFs, "general/grass/night")
  Assert.isNil(missing, "an unstaged scene never resolves")
  Assert.isTrue(
    type(missingErr) == "string" and missingErr:find("general/grass/night", 1, true) ~= nil,
    "the missing scene names its requested key: " .. tostring(missingErr)
  )
  local corrupt, corruptErr = BattlePresentationCache.loadScene(cacheFs, "not-a-scene")
  Assert.isNil(corrupt, "a corrupt scene key never resolves")
  Assert.isTrue(type(corruptErr) == "string" and corruptErr ~= "", "the corrupt key fails with context")
end

-- The SoulSilver leg cannot execute without its dump: the supplied
-- archive holds only the HeartGold cartridge, so no SoulSilver
-- manifest, receipt, or resource can be compared. This records the
-- block with that evidence instead of reusing HeartGold file
-- identities for another version.
function T.soulsilver_closure_stays_blocked_without_its_dump(context)
  local versions = readyVersions(context)
  if not hasVersion(versions, "soulsilver") then
    context:skip(
      "BLOCKED: no SoulSilver dump was supplied: the provided archive holds only "
        .. "'Pokemon - HeartGold Version (USA).nds', so the version-scoped manifest, receipt, "
        .. "and resource closure cannot execute for soulsilver and its physical file identities "
        .. "must not be borrowed from the HeartGold evidence"
    )
  end
  local CacheFs = require("libs.storage.src.CacheFs")
  local BattlePresentationCache = require("libs.assets.src.battle.BattlePresentationCache")
  local manifest = BattlePresentationCache.load(CacheFs.forVersion("soulsilver"))
  Assert.equal(manifest.version.id, "soulsilver", "the staged manifest names its own version")
end

return {
  tests = T,
  metadata = {
    capabilities = { "rom_dump" },
    derivedAssets = {
      "battle-presentation:global",
      "battle-scene:general/grass/day",
    },
  },
}
