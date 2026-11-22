-- One selected mod package archive: bounded metadata opening over a real mount,
-- confined member descriptors, exact-size member reads, one rollback per failed
-- construction, and an unmount that never claims success it did not get.
--
-- The fixture bytes are synthetic and the version id is a test id, so the suite
-- mounts real ZIPs without touching a prepared cache, the user's ROM, or another
-- process's mods directory.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local ModPackageFixture = require("tests.support.ModPackageFixture")
local StorageErrors = require("libs.storage.src.errors")

local T = {}

-- The storage package's mounted-package owner. Resolved per test so a missing
-- implementation fails the behavior it owns instead of the suite load.
---@return table
local function modArchive()
  local ok, ModArchive = pcall(require, "libs.storage.src.ModArchive")
  Assert.isTrue(
    ok and type(ModArchive) == "table",
    "the storage package must own a disk-mounted package archive: " .. tostring(ModArchive)
  )
  return ModArchive --[[@as table]]
end

local VERSION = "modpack-archive"
local ARCHIVE = "package.zip"

-- The fields a manifest must match, plus the generated member every case can
-- declare.
local IDENTITY = { versionId = VERSION, assetRevision = 19, scriptApi = 1 }

local MOUNT_SEQUENCE = 0
local function nextMountpoint()
  MOUNT_SEQUENCE = MOUNT_SEQUENCE + 1
  return "__portemon_mods/archive-" .. tostring(MOUNT_SEQUENCE)
end

---@param name string
---@return string
local function storageCode(name)
  local code = StorageErrors[name]
  Assert.notNil(code, "the storage error vocabulary must name " .. name)
  return code
end

-- Open one case's archive, closing whatever it opened before the case ends.
---@param spec ModPackageFixture.PackageSpec
---@return table archive
---@return string mountpoint
local function openArchive(spec)
  ModPackageFixture.writeArchive(VERSION, ARCHIVE, IDENTITY, spec)
  local mountpoint = nextMountpoint()
  return modArchive().open(ModPackageFixture.archivePath(VERSION, ARCHIVE), mountpoint, IDENTITY), mountpoint
end

-- Write a package declaring `manifestIdentity` and open it against the
-- installed identity: the supplied manifest identity is what the package
-- claims, never the identity the selected runtime compares against.
---@param spec ModPackageFixture.PackageSpec
---@param manifestIdentity table<string, unknown>?
---@param expectedCode string
---@return Errors.Error
local function expectRejected(spec, manifestIdentity, expectedCode)
  ModPackageFixture.writeArchive(VERSION, ARCHIVE, manifestIdentity or IDENTITY, spec)
  local mountpoint = nextMountpoint()
  local ok, failure = pcall(modArchive().open, ModPackageFixture.archivePath(VERSION, ARCHIVE), mountpoint, IDENTITY)
  Assert.isFalse(ok, "a malformed package must be rejected instead of mounting")
  Assert.isTrue(Errors.is(failure), "a package rejection is a typed error: " .. tostring(failure))
  local error = failure --[[@as Errors.Error]]
  Assert.equal(error.code, expectedCode, "the rejection names its category: " .. tostring(error))
  Assert.isNil(
    love.filesystem.getInfo(mountpoint .. "/mod.lua"),
    "a rejected construction leaves no mount behind: " .. mountpoint
  )
  return error
end

-- Remove what one case wrote, whatever it asserted.
local function reset()
  pcall(ModPackageFixture.cleanup, VERSION)
end

-- The supported manifest opens over a disk-backed mount: metadata comes from
-- the manifest member, an indexed member reads back exactly once, and an
-- unlisted member of the same archive stays inaccessible.
function T.supported_package_reads_only_its_indexed_members()
  reset()
  local listed = "data/generated/acceptance/listed.lua"
  local unlisted = "data/generated/acceptance/unlisted.lua"
  local log = ModPackageFixture.newReadLog()
  local mountpoint
  local ok, err = xpcall(function()
    ModPackageFixture.withReadLog(log, function()
      local archive
      archive, mountpoint = openArchive({
        id = "supported",
        revision = "author-7",
        files = { [listed] = "return { listed = true }\n" },
        extra = { [unlisted] = "return { unlisted = true }\n" },
      })
      local manifest = archive:manifest()
      Assert.equal(manifest.id, "supported", "the manifest keeps its package id")
      Assert.equal(manifest.revision, "author-7", "the manifest keeps its author revision")
      Assert.equal(manifest.versionId, VERSION, "the manifest carries the version it targets")
      Assert.equal(#manifest.files, 1, "the manifest declares exactly the supplied members")

      local entry = assert(archive:entry(listed), "an indexed member resolves to its descriptor")
      Assert.equal(entry.path, listed, "the descriptor keeps the logical path")
      Assert.equal(entry.size, #"return { listed = true }\n", "the descriptor keeps the declared size")
      Assert.isTrue(
        type(entry.physicalPath) == "string" and entry.physicalPath:find(mountpoint, 1, true) == 1,
        "the descriptor is confined to the selected mount namespace"
      )
      Assert.deepEqual(archive:paths("data/generated/acceptance"), { listed }, "paths lists indexed members only")
      Assert.isNil(archive:entry(unlisted), "an unlisted member has no descriptor")

      Assert.equal(ModPackageFixture.payloadReadCount(log, listed), 0, "opening a package reads no payload")
      local data = archive:readData(listed)
      Assert.equal(data:getString(), "return { listed = true }\n", "the indexed member reads its own bytes")
      Assert.equal(ModPackageFixture.payloadReadCount(log, listed), 1, "the member is read on request")
      Assert.equal(ModPackageFixture.payloadReadCount(log, unlisted), 0, "the unlisted member is never read")
      local unlistedOk = pcall(function()
        return archive:readData(unlisted)
      end)
      Assert.isFalse(unlistedOk, "reading an unlisted member fails instead of returning archive bytes")

      archive:close()
      Assert.isNil(
        love.filesystem.getInfo(mountpoint .. "/mod.lua"),
        "closing the archive really unmounts its namespace"
      )
      archive:close()
      Assert.isTrue(true, "closing an already closed archive is idempotent")
      local closedOk = pcall(function()
        return archive:readData(listed)
      end)
      Assert.isFalse(closedOk, "a closed archive refuses new reads")
    end)
  end, debug.traceback)
  reset()
  if not ok then
    error(err, 0)
  end
end

-- Identity is checked against the selected cache identity, not against a
-- producer build or a source path.
function T.incompatible_identity_fields_are_rejected_before_the_package_opens()
  reset()
  local path = "data/generated/acceptance/listed.lua"
  local cases = {
    { field = "versionId", value = "modpack-other" },
    { field = "assetRevision", value = IDENTITY.assetRevision + 1 },
    { field = "scriptApi", value = IDENTITY.scriptApi + 1 },
  }
  local ok, err = xpcall(function()
    for _, case in ipairs(cases) do
      local manifestIdentity = {
        versionId = IDENTITY.versionId,
        assetRevision = IDENTITY.assetRevision,
        scriptApi = IDENTITY.scriptApi,
      }
      manifestIdentity[case.field] = case.value
      local failure = expectRejected({
        id = "mismatched-" .. case.field,
        files = { [path] = "return {}\n" },
      }, manifestIdentity, storageCode("MOD_PACKAGE_INCOMPATIBLE"))
      Assert.isTrue(
        tostring(failure):find("mismatched-" .. case.field, 1, true) ~= nil,
        "the incompatibility names the package: " .. tostring(failure)
      )
      ModPackageFixture.removeArchive(VERSION, ARCHIVE)
    end
  end, debug.traceback)
  reset()
  if not ok then
    error(err, 0)
  end
end

-- Every metadata defect the format forbids is rejected while the package is
-- still metadata, including paths that would escape the two generated roots.
function T.malformed_manifests_and_paths_are_rejected()
  reset()
  local function unsupportedSchema()
    return {
      schema = "portemon-mod-v2",
      id = "bad-schema",
      revision = "1",
      versionId = IDENTITY.versionId,
      assetRevision = IDENTITY.assetRevision,
      scriptApi = IDENTITY.scriptApi,
      files = {},
    }
  end
  local function extraKey()
    return {
      schema = ModPackageFixture.SCHEMA,
      id = "extra-key",
      revision = "1",
      versionId = IDENTITY.versionId,
      assetRevision = IDENTITY.assetRevision,
      scriptApi = IDENTITY.scriptApi,
      files = {},
      execute = "mod.lua",
    }
  end
  local function fractionalSize()
    return {
      schema = ModPackageFixture.SCHEMA,
      id = "fractional-size",
      revision = "1",
      versionId = IDENTITY.versionId,
      assetRevision = IDENTITY.assetRevision,
      scriptApi = IDENTITY.scriptApi,
      files = { { path = "data/generated/acceptance/a.lua", size = 1.5 } },
    }
  end
  local function unsortedFiles()
    local first, second = "data/generated/acceptance/b.lua", "data/generated/acceptance/a.lua"
    return {
      schema = ModPackageFixture.SCHEMA,
      id = "unsorted",
      revision = "1",
      versionId = IDENTITY.versionId,
      assetRevision = IDENTITY.assetRevision,
      scriptApi = IDENTITY.scriptApi,
      files = { { path = first, size = 0 }, { path = second, size = 0 } },
    }
  end
  local cases = {
    { id = "bad-schema", manifest = unsupportedSchema(), code = "MOD_PACKAGE_INVALID" },
    { id = "extra-key", manifest = extraKey(), code = "MOD_PACKAGE_INVALID" },
    { id = "fractional-size", manifest = fractionalSize(), code = "MOD_PACKAGE_INVALID" },
    { id = "unsorted", manifest = unsortedFiles(), code = "MOD_PACKAGE_INVALID" },
    {
      id = "traversal",
      manifest = ModPackageFixture.manifest({
        versionId = VERSION,
        id = "traversal",
        assetRevision = IDENTITY.assetRevision,
        scriptApi = IDENTITY.scriptApi,
        paths = { "data/generated/../escape.lua" },
        sizes = { ["data/generated/../escape.lua"] = 0 },
      }),
      code = "MOD_PACKAGE_INVALID",
    },
    {
      id = "outside-roots",
      manifest = ModPackageFixture.manifest({
        versionId = VERSION,
        id = "outside-roots",
        assetRevision = IDENTITY.assetRevision,
        scriptApi = IDENTITY.scriptApi,
        paths = { "saves/heartgold/game.lua" },
        sizes = { ["saves/heartgold/game.lua"] = 0 },
      }),
      code = "MOD_PACKAGE_INVALID",
    },
    {
      id = "base-milestone",
      manifest = ModPackageFixture.manifest({
        versionId = VERSION,
        id = "base-milestone",
        assetRevision = IDENTITY.assetRevision,
        scriptApi = IDENTITY.scriptApi,
        paths = { "data/generated/first-play.lua" },
        sizes = { ["data/generated/first-play.lua"] = 0 },
      }),
      code = "MOD_PACKAGE_INVALID",
    },
    {
      id = "unsafe-package-id",
      manifest = ModPackageFixture.manifest({
        versionId = VERSION,
        id = "Unsafe Id",
        assetRevision = IDENTITY.assetRevision,
        scriptApi = IDENTITY.scriptApi,
        paths = {},
        sizes = {},
      }),
      code = "MOD_PACKAGE_INVALID",
    },
  }
  local ok, err = xpcall(function()
    for _, case in ipairs(cases) do
      local LuaWriter = require("libs.codec.src.LuaWriter")
      expectRejected({
        id = case.id,
        files = {},
        manifest = LuaWriter.encode(case.manifest),
      }, nil, storageCode(case.code))
      ModPackageFixture.removeArchive(VERSION, ARCHIVE)
    end
  end, debug.traceback)
  reset()
  if not ok then
    error(err, 0)
  end
end

-- A declared size that contradicts the mounted member is a package defect
-- caught at selection, and a construction that failed leaves the archive free
-- to be opened again once the package is corrected.
function T.declared_size_must_match_and_a_failed_open_leaves_no_mount()
  reset()
  local path = "data/generated/acceptance/sized.lua"
  local ok, err = xpcall(function()
    ModPackageFixture.writeArchive(VERSION, ARCHIVE, IDENTITY, {
      id = "sized",
      files = { [path] = "0123456789" },
      declaredSizes = { [path] = 4 },
    })
    local mountpoint = nextMountpoint()
    local opened, failure =
      pcall(modArchive().open, ModPackageFixture.archivePath(VERSION, ARCHIVE), mountpoint, IDENTITY)
    Assert.isFalse(opened, "a declared size the archive contradicts must be rejected")
    Assert.isTrue(Errors.is(failure), "the contradiction is a typed package failure: " .. tostring(failure))
    Assert.equal(
      (failure --[[@as Errors.Error]]).code,
      storageCode("MOD_PACKAGE_INVALID"),
      "the contradiction is a metadata defect, not a payload read failure"
    )
    Assert.isNil(
      love.filesystem.getInfo(mountpoint .. "/mod.lua"),
      "the rejected construction unmounted the package it had just mounted"
    )

    ModPackageFixture.removeArchive(VERSION, ARCHIVE)
    local archive = openArchive({ id = "corrected", files = { [path] = "0123456789" } })
    Assert.equal(archive:readData(path):getString(), "0123456789", "the corrected package opens and reads")
    archive:close()
  end, debug.traceback)
  reset()
  if not ok then
    error(err, 0)
  end
end

-- A failed native unmount is reported as a teardown failure and keeps the owner
-- live for the explicit retry; it is never reported as success.
function T.close_reports_an_unmount_failure_and_stays_live()
  reset()
  local path = "data/generated/acceptance/unmount.lua"
  local ok, err = xpcall(function()
    local archive, mountpoint = openArchive({ id = "unmount", files = { [path] = "return {}\n" } })
    local unmount = love.filesystem.unmount
    love.filesystem.unmount = function()
      return false
    end
    local closed, failure = pcall(function()
      archive:close()
    end)
    love.filesystem.unmount = unmount
    Assert.isFalse(closed, "an unmount failure is not reported as a successful close")
    Assert.isTrue(Errors.is(failure), "an unmount failure is a typed teardown failure: " .. tostring(failure))
    Assert.equal(
      (failure --[[@as Errors.Error]]).code,
      storageCode("MOD_PACKAGE_UNMOUNT_FAILED"),
      "the teardown failure names its category"
    )
    Assert.equal(archive:readData(path):getString(), "return {}\n", "the still-mounted owner stays usable")
    archive:close()
    Assert.isNil(love.filesystem.getInfo(mountpoint .. "/mod.lua"), "a later close unmounts for real")
  end, debug.traceback)
  reset()
  if not ok then
    error(err, 0)
  end
end

return { tests = T }
