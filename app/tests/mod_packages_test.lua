-- The selected session's ordered package set: the optional load-order config,
-- bounded metadata only, last-wins resolution at equal logical paths, duplicate
-- and incompatible-selection rejection, rollback of a partially opened set, and
-- a source identity that belongs to one epoch.
--
-- The packages are synthetic ZIPs mounted for real from a test-only version
-- directory, so no prepared cache, user ROM, or other process's selection is
-- involved.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local ModPackageFixture = require("tests.support.ModPackageFixture")
local StorageErrors = require("libs.storage.src.errors")

local T = {}

local VERSION = "modpack-selection"
local IDENTITY = { versionId = VERSION, assetRevision = 19, scriptApi = 1 }
local REPLACED = "data/generated/acceptance/replaced.lua"
local BASE_ONLY = "data/generated/acceptance/base-only.lua"

-- The App-private ordered selection owner. Resolved per test so a missing
-- implementation fails the behavior it owns instead of the suite load.
---@return table
local function modPackages()
  local ok, ModPackages = pcall(require, "app.src.ModPackages")
  Assert.isTrue(
    ok and type(ModPackages) == "table",
    "the selected game must own its ordered package set: " .. tostring(ModPackages)
  )
  return ModPackages --[[@as table]]
end

---@param name string
---@return string
local function storageCode(name)
  local code = StorageErrors[name]
  Assert.notNil(code, "the storage error vocabulary must name " .. name)
  return code
end

local function reset()
  pcall(ModPackageFixture.cleanup, VERSION)
end

---@param basename string
---@param id string
---@param files table<string, string|love.Data>
local function writePackage(basename, id, files)
  ModPackageFixture.writeArchive(VERSION, basename, IDENTITY, { id = id, files = files })
end

-- One opened selection, closed by the caller's teardown.
---@param epoch integer
---@param identity table<string, unknown>?
---@return table
local function openSelection(epoch, identity)
  return modPackages().open(VERSION, identity or IDENTITY, epoch)
end

-- No config file means the base game with no mounts and no package read.
function T.missing_configuration_selects_no_packages()
  reset()
  local log = ModPackageFixture.newReadLog()
  local ok, err = xpcall(function()
    ModPackageFixture.withReadLog(log, function()
      local set = openSelection(1)
      Assert.isNil(set:resolveAsset(REPLACED), "an empty selection resolves no entry")
      Assert.deepEqual(set:paths("data/generated/acceptance"), {}, "an empty selection lists no names")
      Assert.equal(#log.reads, 0, "an empty selection reads no package file at all")
      set:close()
    end)
  end, debug.traceback)
  reset()
  if not ok then
    error(err, 0)
  end
end

-- Packages are declared low-to-high priority: the last selected package owns an
-- equal logical path, an unselected path stays unowned, and opening the set
-- reads only manifests.
function T.later_packages_win_at_equal_paths_and_no_payload_is_read_at_selection()
  reset()
  local log = ModPackageFixture.newReadLog()
  local ok, err = xpcall(function()
    writePackage("one.zip", "first", { [REPLACED] = "return { owner = 'first' }\n" })
    writePackage("two.zip", "second", {
      [REPLACED] = "return { owner = 'second' }\n",
      [BASE_ONLY] = "return { owner = 'also-second' }\n",
    })
    ModPackageFixture.writeConfig(VERSION, { "one.zip", "two.zip" })
    ModPackageFixture.withReadLog(log, function()
      local set = openSelection(7)
      local winner = assert(set:resolveAsset(REPLACED), "the selection resolves its winner")
      Assert.equal(winner.path, REPLACED, "the winner keeps the logical path")
      Assert.deepEqual(set:paths("data/generated/acceptance"), { BASE_ONLY, REPLACED }, "winners are listed once")
      Assert.equal(
        ModPackageFixture.payloadReadCount(log, REPLACED),
        0,
        "selecting a package reads no payload, only its manifest"
      )
      Assert.equal(ModPackageFixture.payloadReadCount(log, BASE_ONLY), 0, "an unrequested member is never read")
      local data = set:readData(winner)
      Assert.equal(data:getString(), "return { owner = 'second' }\n", "the last declared package supplies the bytes")
      set:close()
    end)

    -- The same two packages in the other order reverse the winner without any
    -- other change.
    ModPackageFixture.writeConfig(VERSION, { "two.zip", "one.zip" })
    ModPackageFixture.withReadLog(log, function()
      local set = openSelection(8)
      local winner = assert(set:resolveAsset(REPLACED), "the reversed selection resolves its winner")
      Assert.equal(
        set:readData(winner):getString(),
        "return { owner = 'first' }\n",
        "reversing the declaration order reverses the winner"
      )
      set:close()
    end)
  end, debug.traceback)
  reset()
  if not ok then
    error(err, 0)
  end
end

-- Duplicate declarations are selection errors: the same basename twice, and two
-- packages that claim one id.
function T.duplicate_basenames_and_ids_are_selection_errors()
  reset()
  local ok, err = xpcall(function()
    writePackage("one.zip", "duplicate-target", { [REPLACED] = "return {}\n" })
    ModPackageFixture.writeConfig(VERSION, { "one.zip", "one.zip" })
    local opened, failure = pcall(openSelection, 9)
    Assert.isFalse(opened, "a basename declared twice is rejected")
    Assert.isTrue(Errors.is(failure), "the duplicate declaration is a typed config failure: " .. tostring(failure))
    Assert.equal(
      (failure --[[@as Errors.Error]]).code,
      storageCode("MOD_CONFIG_INVALID"),
      "the duplicate declaration names the config failure category"
    )

    writePackage("two.zip", "duplicate-target", { [REPLACED] = "return {}\n" })
    ModPackageFixture.writeConfig(VERSION, { "one.zip", "two.zip" })
    opened, failure = pcall(openSelection, 10)
    Assert.isFalse(opened, "two packages claiming one id are rejected")
    Assert.isTrue(Errors.is(failure), "the duplicate id is a typed package failure: " .. tostring(failure))
    Assert.equal(
      (failure --[[@as Errors.Error]]).code,
      storageCode("MOD_PACKAGE_INVALID"),
      "the duplicate id names the package failure category"
    )
    Assert.isTrue(
      tostring(failure):find("duplicate-target", 1, true) ~= nil,
      "the duplicate id failure names the package: " .. tostring(failure)
    )
  end, debug.traceback)
  reset()
  if not ok then
    error(err, 0)
  end
end

-- A later package's failure unwinds the ones already opened, and an
-- incompatible manifest is reported before any mount survives.
function T.a_later_failure_rolls_back_the_packages_already_opened()
  reset()
  local ok, err = xpcall(function()
    writePackage("good.zip", "good", { [REPLACED] = "return {}\n" })
    ModPackageFixture.writeArchive(VERSION, "bad.zip", {
      versionId = VERSION,
      assetRevision = IDENTITY.assetRevision + 1,
      scriptApi = IDENTITY.scriptApi,
    }, {
      id = "incompatible",
      files = { [REPLACED] = "return {}\n" },
    })
    ModPackageFixture.writeConfig(VERSION, { "good.zip", "bad.zip" })
    local epoch = 11
    local opened, failure = pcall(openSelection, epoch)
    Assert.isFalse(opened, "an incompatible package rejects the whole selection")
    Assert.isTrue(Errors.is(failure), "the incompatibility is typed: " .. tostring(failure))
    Assert.equal(
      (failure --[[@as Errors.Error]]).code,
      storageCode("MOD_PACKAGE_INCOMPATIBLE"),
      "the failure names the identity incompatibility"
    )
    for ordinal = 1, 2 do
      Assert.isNil(
        love.filesystem.getInfo("__portemon_mods/" .. tostring(epoch) .. "/" .. tostring(ordinal) .. "/mod.lua"),
        "a rejected selection leaves no mount behind"
      )
    end

    -- The corrected selection opens, so the rollback released every namespace.
    ModPackageFixture.writeConfig(VERSION, { "good.zip" })
    local set = openSelection(epoch + 1)
    Assert.notNil(set:resolveAsset(REPLACED), "the corrected selection opens over the rolled-back set")
    set:close()
  end, debug.traceback)
  reset()
  if not ok then
    error(err, 0)
  end
end

-- A selected source reference belongs to the selection that produced it: a new
-- epoch's set rejects it, and equal logical paths in two epochs are different
-- sources.
function T.a_previous_selections_source_never_enters_a_new_epoch()
  reset()
  local ok, err = xpcall(function()
    writePackage("one.zip", "identity", { [REPLACED] = "return { owner = 'first' }\n" })
    ModPackageFixture.writeConfig(VERSION, { "one.zip" })
    local first = openSelection(21)
    local firstReference = assert(first:resolveAsset(REPLACED), "the first selection resolves its entry")
    first:close()

    local second = openSelection(22)
    local secondReference = assert(second:resolveAsset(REPLACED), "the second selection resolves the same path")
    Assert.isTrue(
      secondReference.sourceId ~= firstReference.sourceId,
      "equal logical paths in two epochs are different sources"
    )
    local read, failure = pcall(function()
      return second:readData(firstReference)
    end)
    Assert.isFalse(read, "a retired selection's reference is refused by the new set")
    if not read then
      Assert.isTrue(Errors.is(failure), "the refusal is typed: " .. tostring(failure))
    end
    Assert.equal(
      second:readData(secondReference):getString(),
      "return { owner = 'first' }\n",
      "the live selection still serves its own bytes"
    )
    second:close()
  end, debug.traceback)
  reset()
  if not ok then
    error(err, 0)
  end
end

function T.close_retains_dense_failed_mounts_and_retries_constructor_rollback()
  reset()
  local originalUnmount = love.filesystem.unmount
  local failedPath = nil
  love.filesystem.unmount = function(path)
    if path == failedPath then
      failedPath = nil
      return false, "injected unmount failure"
    end
    return originalUnmount(path)
  end
  local ok, err = xpcall(function()
    writePackage("one.zip", "one", { [REPLACED] = "return { owner = 'one' }\n" })
    writePackage("two.zip", "two", { [BASE_ONLY] = "return { owner = 'two' }\n" })
    ModPackageFixture.writeConfig(VERSION, { "one.zip", "two.zip" })
    local set = openSelection(31)
    failedPath = ModPackageFixture.archivePath(VERSION, "one.zip")
    local closed = pcall(set.close, set)
    Assert.isFalse(closed, "one failed unmount keeps teardown incomplete")
    Assert.isTrue(set.closing, "a partially unmounted set stops serving new reads")
    Assert.isNil(set:resolveAsset(REPLACED), "a closing package set exposes no mounted sources")
    Assert.equal(#set._archives, 1, "only the failed mount remains in a dense retry list")
    set:close()
    Assert.isTrue(set.closed, "a retry closes the retained mount")

    ModPackageFixture.writeArchive(VERSION, "bad.zip", {
      versionId = VERSION,
      assetRevision = IDENTITY.assetRevision + 1,
      scriptApi = IDENTITY.scriptApi,
    }, {
      id = "bad",
      files = { [REPLACED] = "return {}\n" },
    })
    ModPackageFixture.writeConfig(VERSION, { "one.zip", "bad.zip" })
    failedPath = ModPackageFixture.archivePath(VERSION, "one.zip")
    local opened = pcall(openSelection, 32, IDENTITY)
    Assert.isFalse(opened, "an incompatible package fails after the earlier package mounted")
    Assert.notNil(
      love.filesystem.getInfo("__portemon_mods/32/1/mod.lua"),
      "a rollback failure keeps its mounted archive reachable for retry"
    )
    ModPackageFixture.writeConfig(VERSION, { "one.zip" })
    local recovered = openSelection(33)
    Assert.notNil(recovered:resolveAsset(REPLACED), "a later open retries rollback before mounting")
    Assert.isNil(
      love.filesystem.getInfo("__portemon_mods/32/1/mod.lua"),
      "the failed constructor mount is gone before the replacement opens"
    )
    recovered:close()
  end, debug.traceback)
  love.filesystem.unmount = originalUnmount
  reset()
  if not ok then
    error(err, 0)
  end
end

return { tests = T }
