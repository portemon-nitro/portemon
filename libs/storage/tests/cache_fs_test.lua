local Assert = require("tests.support.Assert")
local CacheEnvelope = require("tests.support.CacheEnvelope")
local CacheFs = require("libs.storage.src.CacheFs")
local LuaWriter = require("libs.codec.src.LuaWriter")
local Errors = require("libs.errors.src.Errors")
local StorageErrors = require("libs.storage.src.errors")
local FakeCache = require("tests.support.FakeCache")
local PngWriter = require("libs.assets.src.PngWriter")
local Schema = require("libs.script.src.Schema")
local ConstrainedCache = require("tests.support.ConstrainedCache")
local ArtifactPublisher = require("libs.storage.src.ArtifactPublisher")

local function cache(versionId, backend)
  return CacheFs.forVersion(versionId, backend or FakeCache.new())
end

local function proxyBackends(backend)
  local filesystem = {}
  local function proxy()
    return {
      _filesystem = filesystem,
      write = function(_, path, data)
        return backend:write(path, data)
      end,
      read = function(_, path)
        return backend:read(path)
      end,
      getInfo = function(_, path)
        return backend:getInfo(path)
      end,
      createDirectory = function(_, path)
        return backend:createDirectory(path)
      end,
      remove = function(_, path)
        return backend:remove(path)
      end,
      replace = function(_, sourcePath, destinationPath)
        return backend:replace(sourcePath, destinationPath)
      end,
      getDirectoryItems = function(_, path)
        return backend:getDirectoryItems(path)
      end,
    }
  end
  return proxy(), proxy()
end

local T = {}
local assertAttemptResidueAbsent

local function isManifestTempPath(path)
  return path:match("^heartgold%.__g4publish%.[%w%-_]+%.__g4next$") ~= nil
end

local function findBackendFile(backend, prefix, suffix)
  for path, data in pairs(backend.files) do
    if path:sub(1, #prefix) == prefix and path:sub(-#suffix) == suffix then
      return data
    end
  end
  return nil
end

function T.prefix_reflects_version()
  Assert.equal(cache("heartgold"):prefix(), "heartgold/")
  Assert.equal(cache("soulsilver"):prefix(), "soulsilver/")
end

-- Version ids are structural path components, not ROM identities: any safe
-- component names its own namespace. Which ids exist is romdump's GameVersion
-- business; generic persistence must not depend on it.
function T.version_ids_are_structural_not_catalogued()
  Assert.equal(cache("custom"):prefix(), "custom/")
  Assert.equal(cache("hg-2"):prefix(), "hg-2/")
end

function T.rejects_unsafe_version_ids()
  Assert.throws(function()
    cache("../escape")
  end)
  Assert.throws(function()
    cache("a/b")
  end)
  Assert.throws(function()
    cache("")
  end)
  Assert.throws(function()
    cache("a\\b")
  end)
end

function T.staging_roots_reject_unsafe_version_ids()
  Assert.throws(function()
    CacheFs.forStaging("../escape")
  end)
  Assert.throws(function()
    CacheFs.forArtifactStage("a/b", "name")
  end)
end

function T.write_lands_under_version_prefix()
  local backend = FakeCache.new()
  cache("heartgold", backend):write("system/header.bin", "HDR")
  Assert.equal(backend.files["heartgold/system/header.bin"], "HDR")
end

function T.read_round_trips_written_bytes()
  local c = cache("heartgold")
  c:write("a/0/4/1", "matrix")
  Assert.equal(c:read("a/0/4/1"), "matrix")
end

-- CacheFs has one opaque write seam for strings and LÖVE Data. A Data value
-- must cross that seam unchanged; converting through getString would both add
-- an avoidable copy and violate the producer's final-allocation ownership.
function T.write_forwards_data_without_string_conversion()
  local payload = "G4M2\0\1\0\255"
  local data = {
    getSize = function()
      return #payload
    end,
    getFFIPointer = function()
      error("the storage path must not inspect the Data pointer")
    end,
    getString = function()
      error("the storage path must not convert Data to a string")
    end,
  }
  local backend = FakeCache.new()
  local c = cache("heartgold", backend)
  c:write("geometry/mesh.g4mesh", data)
  Assert.isTrue(backend.files["heartgold/geometry/mesh.g4mesh"] == data, "Data reaches the backend by identity")
  Assert.isTrue(c:getInfo("geometry/mesh.g4mesh").size == #payload, "Data size remains available to storage")
end

function T.read_missing_returns_nil()
  Assert.isNil(cache("heartgold"):read("nope"))
end

function T.exists_checks_presence_and_type()
  local c = cache("heartgold")
  c:write("romfs/a/0/0/2", "x")
  Assert.isTrue(c:exists("romfs/a/0/0/2"))
  Assert.isTrue(c:exists("romfs/a/0/0/2", "file"))
  Assert.isFalse(c:exists("romfs/a/0/0/2", "directory"))
  Assert.isTrue(c:exists("romfs/a/0/0", "directory"))
  Assert.isFalse(c:exists("absent"))
end

-- write() must materialize the parent chain so the love backend (no implicit
-- mkdir) can land a deeply nested NitroFS file.
function T.write_creates_parent_directories()
  local backend = FakeCache.new()
  cache("heartgold", backend):write("romfs/a/0/0/0", "data")
  Assert.isTrue(backend.dirs["heartgold/romfs/a/0/0"], "parent directory must be created")
end

function T.remove_tree_recursively_clears_subtree()
  local c = cache("heartgold")
  c:write("romfs/a/0/0/0", "0")
  c:write("romfs/a/0/0/1", "1")
  c:write("romfs/data/x", "x")
  c:removeTree("romfs/a")
  Assert.isNil(c:read("romfs/a/0/0/0"))
  Assert.isNil(c:read("romfs/a/0/0/1"))
  Assert.equal(c:read("romfs/data/x"), "x")
end

-- One version's operations must never see or clear another's.
function T.versions_are_isolated()
  local backend = FakeCache.new()
  local hg = cache("heartgold", backend)
  local ss = cache("soulsilver", backend)
  hg:write("marker", "HG")
  ss:write("marker", "SS")
  Assert.equal(hg:read("marker"), "HG")
  Assert.equal(ss:read("marker"), "SS")
  ss:removeTree("")
  Assert.equal(hg:read("marker"), "HG")
  Assert.isNil(ss:read("marker"))
end

function T.rejects_absolute_paths()
  Assert.throws(function()
    cache("heartgold"):write("/etc/passwd", "x")
  end)
end

function T.rejects_drive_letters()
  Assert.throws(function()
    cache("heartgold"):write("C:/x", "x")
  end)
end

function T.rejects_parent_components()
  Assert.throws(function()
    cache("heartgold"):read("../soulsilver/marker")
  end)
  Assert.throws(function()
    cache("heartgold"):read("a/../../b")
  end)
end

function T.rejects_dot_and_nul_components()
  Assert.throws(function()
    cache("heartgold"):read("a/./b")
  end)
  Assert.throws(function()
    cache("heartgold"):read("a\0b")
  end)
end

function T.lua_round_trip_is_deterministic()
  local c = cache("heartgold")
  local value = { schema = 1, files = { [0] = { fileId = 0, size = 12 } } }
  c:writeLua("data/generated/x.lua", value)
  Assert.deepEqual(c:loadLua("data/generated/x.lua"), value)
end

function T.atomic_replace_moves_a_file_over_its_destination()
  local c = cache("heartgold")
  c:write("save/session.lua", "old")
  c:write("save/session.lua.tmp", "new")
  c:replace("save/session.lua.tmp", "save/session.lua")
  Assert.equal(c:read("save/session.lua"), "new")
  Assert.isNil(c:read("save/session.lua.tmp"))
end

function T.load_lua_missing_is_a_missing_file_error()
  local data, err = cache("heartgold"):loadLua("data/generated/absent.lua")
  Assert.isNil(data)
  Assert.isTrue(
    err ~= nil and err.code == StorageErrors.CACHE_FILE_MISSING,
    "expected " .. StorageErrors.CACHE_FILE_MISSING .. ", got " .. tostring(err)
  )
end

-- An actual backend read failure is not a missing cache file: the load
-- boundary must keep the two apart, or corruption of an existing generated
-- file would be silently treated as absence.
function T.load_lua_read_failure_is_not_reclassified_as_missing()
  local backend = FakeCache.new()
  local c = cache("heartgold", backend)
  c:write("data/generated/x.lua", "DATA")
  backend.read = function(_)
    return nil, "injected read failure"
  end
  local data, err = c:loadLua("data/generated/x.lua")
  Assert.isNil(data)
  Assert.isTrue(
    err ~= nil and err.code == StorageErrors.CACHE_READ_FAILED,
    "expected " .. StorageErrors.CACHE_READ_FAILED .. ", got " .. tostring(err)
  )
  Assert.isTrue(
    tostring(err):find("injected read failure", 1, true) ~= nil,
    "the backend read error must survive to the load boundary: " .. tostring(err)
  )
end

-- loadModule evaluates generated script modules under a restricted require
-- allowlist (gen4.script only, matching ScriptLoader's resource loader), not
-- the unrestricted global require/package. The allowlisted happy path is
-- pinned by ScriptCache's readiness tests (script_valid_artifact_is_ready).
function T.load_module_rejects_a_require_of_a_disallowed_module()
  local c = cache("heartgold")
  c:write("data/generated/script/a.b.lua", 'local X = require("libs.errors.src.Errors")\nreturn X\n')
  local data, err = c:loadModule("data/generated/script/a.b.lua")
  Assert.isNil(data, "a module requiring outside the allowlist must fail to load")
  Assert.notNil(err, "a disallowed require must surface as an error")
  Assert.isTrue(Errors.is(err), "the failure must be a structured cache error")
end

-- The package global must not be reachable from a generated module: at best
-- it is a permission hole, at worst a generated module can corrupt the
-- process-wide package tables the allowlist is meant to keep it away from.
function T.load_module_env_does_not_expose_package()
  local c = cache("heartgold")
  c:write("data/generated/script/a.b.lua", "local p = package\nreturn p.path\n")
  local data, err = c:loadModule("data/generated/script/a.b.lua")
  Assert.isNil(data, "the package global must not be reachable from a generated module")
  Assert.notNil(err)
  Assert.isTrue(Errors.is(err), "the failure must be a structured cache error")
end

local function staging(versionId, backend)
  return CacheFs.forStaging(versionId, backend)
end

local function assertPortableRenames(backend)
  Assert.isTrue(#backend.renameLog > 0, "publication must use the backend rename seam")
  for _, entry in ipairs(backend.renameLog) do
    Assert.isFalse(entry.destinationExisted, "rename destination must be absent: " .. entry.destination)
    if entry.sourceType == "directory" then
      Assert.equal(
        entry.sourceParent,
        entry.destinationParent,
        "directory rename must stay within one parent: " .. entry.source .. " -> " .. entry.destination
      )
    end
  end
end

function T.staging_prefix_is_a_sibling_namespace()
  Assert.equal(staging("heartgold"):prefix(), "heartgold.__g4next/")
  Assert.equal(staging("soulsilver"):prefix(), "soulsilver.__g4next/")
  local backend = FakeCache.new()
  staging("heartgold", backend):write("romfs/a/0/0/2", "STAGE-DATA")
  Assert.equal(backend.files["heartgold.__g4next/romfs/a/0/0/2"], "STAGE-DATA")
  Assert.isNil(backend.files["heartgold/romfs/a/0/0/2"], "live root must stay untouched")
end

function T.remove_staged_tree_clears_staging_and_orphaned_old()
  local backend = FakeCache.new()
  local c = cache("heartgold", backend)
  local s = staging("heartgold", backend)
  c:write("romfs/a/0/0/2", "LIVE")
  s:write("romfs/a/0/0/2", "STAGE")
  backend.files["heartgold.__g4old/romfs/x"] = "ORPHAN"
  c:removeStagedTree(s)
  Assert.isNil(backend.files["heartgold.__g4next/romfs/a/0/0/2"], "staging must be cleared")
  Assert.isNil(backend.files["heartgold.__g4old/romfs/x"], "orphaned old root must be cleared")
  Assert.equal(backend.files["heartgold/romfs/a/0/0/2"], "LIVE", "live root must stay untouched")
end

function T.publish_from_stage_replaces_live_root()
  local backend = FakeCache.new()
  local c = cache("heartgold", backend)
  local s = staging("heartgold", backend)
  c:write("romfs/a/0/0/2", "OLD")
  c:write("rom-dump.complete", "OLD-MARKER")
  s:write("romfs/a/0/0/2", "NEW")
  s:write("data/generated/rom_metadata.lua", "NEW-META")
  s:write("rom-dump.complete", "NEW-MARKER")
  c:publishFromStage(s)
  Assert.equal(backend.files["heartgold/romfs/a/0/0/2"], "NEW")
  Assert.equal(backend.files["heartgold/rom-dump.complete"], "NEW-MARKER")
  Assert.equal(backend.files["heartgold/data/generated/rom_metadata.lua"], "NEW-META")
  Assert.isNil(backend.files["heartgold.__g4next/romfs/a/0/0/2"], "staging root must be gone")
  Assert.isNil(backend.dirs["heartgold.__g4next"], "staging root must be gone")
  Assert.isNil(backend.files["heartgold.__g4old/romfs/a/0/0/2"], "previous root must be gone")
end

function T.publish_from_stage_handles_fresh_import()
  local backend = FakeCache.new()
  local c = cache("heartgold", backend)
  local s = staging("heartgold", backend)
  s:write("romfs/a/0/0/2", "FIRST")
  s:write("rom-dump.complete", "MARKER")
  c:publishFromStage(s)
  Assert.equal(backend.files["heartgold/romfs/a/0/0/2"], "FIRST")
  Assert.isNil(backend.files["heartgold.__g4next/romfs/a/0/0/2"])
end

function T.whole_version_publication_remains_direct_and_portable()
  local backend = ConstrainedCache.new()
  local live = cache("heartgold", backend)
  local stage = staging("heartgold", backend)
  live:write("romfs/old.bin", "old")
  live:write("rom-dump.complete", "old-marker")
  stage:write("romfs/new.bin", "new")
  stage:write("rom-dump.complete", "new-marker")

  local ok, err = pcall(function()
    live:publishFromStage(stage)
  end)
  Assert.isTrue(ok, tostring(err))
  Assert.equal(live:read("romfs/new.bin"), "new")
  Assert.equal(live:read("rom-dump.complete"), "new-marker")
  Assert.isNil(backend:getInfo("heartgold.__g4next"))
  Assert.isNil(backend:getInfo("heartgold.__g4old"))
  Assert.isNil(backend:getInfo("staging/heartgold"))
  for path in pairs(backend.files) do
    Assert.isFalse(
      path:find("heartgold.__g4next.", 1, true) ~= nil,
      "whole-version stage must not be copied to an attempt candidate"
    )
  end
  for path in pairs(backend.dirs) do
    Assert.isFalse(
      path:find("heartgold.__g4next.", 1, true) ~= nil,
      "whole-version stage must not be copied to an attempt candidate"
    )
  end
  assertPortableRenames(backend)
end

function T.file_root_publication_moves_aside_existing_file_before_replacement()
  local backend = ConstrainedCache.new()
  local live = cache("heartgold", backend)
  local fileRoot = "data/generated/map-index.lua"
  local first = ArtifactPublisher.begin(live, "map-index", { fileRoot })
  live:write(fileRoot, "old-index")
  first.stage:write(fileRoot, "new-index")

  local ok, err = pcall(function()
    first:publish()
  end)
  Assert.isTrue(ok, tostring(err))
  Assert.equal(live:read(fileRoot), "new-index")
  Assert.isNil(backend:getInfo("heartgold/" .. fileRoot .. ".__g4next"))
  Assert.isNil(backend:getInfo("heartgold/" .. fileRoot .. ".__g4old"))

  local second = ArtifactPublisher.begin(live, "map-index", { fileRoot })
  second.stage:write(fileRoot, "replacement-index")
  local originalReplace = backend.replace
  local failCandidate = true
  backend.replace = function(self, sourcePath, destinationPath)
    local candidatePrefix = "heartgold/" .. fileRoot .. ".__g4next"
    if
      failCandidate
      and (sourcePath == candidatePrefix or sourcePath:sub(1, #candidatePrefix + 1) == candidatePrefix .. ".")
    then
      failCandidate = false
      return false, "injected rename failure"
    end
    return originalReplace(self, sourcePath, destinationPath)
  end
  local publishErr = Assert.throws(function()
    second:publish()
  end)
  Assert.isTrue(Errors.is(publishErr))
  Assert.equal(publishErr.code, StorageErrors.CACHE_REPLACE_FAILED)
  Assert.equal(live:read(fileRoot), "new-index", "failed replacement restores the previous file")
  for _, entries in ipairs({ backend.files, backend.dirs }) do
    for path in pairs(entries) do
      Assert.isFalse(path:find("heartgold/" .. fileRoot .. ".__g4old", 1, true) ~= nil)
    end
  end
  assertPortableRenames(backend)
end

function T.candidate_copy_preserves_nested_files_and_empty_directories()
  local backend = ConstrainedCache.new()
  local live = cache("heartgold", backend)
  local root = "data/generated/field/maps"
  local payload = "persisted\0bytes"
  local tx = ArtifactPublisher.begin(live, "field-maps", { root })
  tx.stage:write(root .. "/nested/value.bin", payload)
  tx.stage:createDirectory(root .. "/empty")

  tx:publish()

  Assert.equal(live:read(root .. "/nested/value.bin"), payload)
  Assert.notNil(backend:getInfo("heartgold/" .. root .. "/empty"))
end

function T.candidate_copy_replaces_a_stale_candidate_tree()
  local backend = FakeCache.new()
  local live = cache("heartgold", backend)
  local root = "data/generated/field/maps"
  local tx = ArtifactPublisher.begin(live, "field-maps", { root })
  backend:write("heartgold/" .. root .. ".__g4next/stale.bin", "stale")
  tx.stage:write(root .. "/current.bin", "current")

  tx:publish()

  Assert.equal(live:read(root .. "/current.bin"), "current")
  Assert.isNil(live:read(root .. "/stale.bin"))
end

-- Candidate preparation moves staged payload instead of copying it:
-- with read/write counters armed, publishing a nested stage performs no
-- payload-byte reads or writes while the live tree gains the exact
-- staged bytes, including empty directories.
function T.staged_publication_moves_candidates_without_copying_payload()
  local backend = ConstrainedCache.new()
  local live = cache("heartgold", backend)
  local root = "data/generated/field/maps"
  local payload = string.rep("persisted-bytes", 64)
  local tx = ArtifactPublisher.begin(live, "move-maps", { root })
  tx.stage:write(root .. "/nested/value.bin", payload)
  tx.stage:createDirectory(root .. "/empty")
  local reads, writes = {}, {}
  local originalRead = backend.read
  local originalWrite = backend.write
  backend.read = function(self, path)
    reads[#reads + 1] = path
    return originalRead(self, path)
  end
  backend.write = function(self, path, data)
    writes[#writes + 1] = path
    return originalWrite(self, path, data)
  end
  local ok, err = pcall(function()
    tx:publish()
  end)
  backend.read = originalRead
  backend.write = originalWrite
  Assert.isTrue(ok, tostring(err))
  for _, path in ipairs(reads) do
    Assert.isFalse(path:find(root, 1, true) ~= nil, "candidate preparation reads no payload bytes: " .. tostring(path))
  end
  for _, path in ipairs(writes) do
    Assert.isFalse(path:find(root, 1, true) ~= nil, "candidate preparation copies no payload bytes: " .. tostring(path))
  end
  Assert.equal(live:read(root .. "/nested/value.bin"), payload, "the moved payload lands intact")
  Assert.notNil(backend:getInfo("heartgold/" .. root .. "/empty"), "empty directories move with the tree")
  Assert.isNil(backend:getInfo("staging/heartgold/move-maps"), "the consumed stage leaves no residue")
  assertAttemptResidueAbsent(backend)
  assertPortableRenames(backend)
end

function T.candidate_move_failure_cleans_partial_candidates_without_touching_live()
  local backend = FakeCache.new()
  local live = cache("heartgold", backend)
  local root = "data/generated/field/maps"
  live:write(root .. "/old.bin", "old")
  local tx = ArtifactPublisher.begin(live, "field-maps", { root })
  tx.stage:write(root .. "/first.bin", "first")
  tx.stage:write(root .. "/second.bin", "second")

  local originalReplace = backend.replace
  backend.replace = function(self, sourcePath, destinationPath)
    if destinationPath:find(".__g4next", 1, true) and destinationPath:find("second.bin", 1, true) then
      return false, "injected candidate move failure"
    end
    return originalReplace(self, sourcePath, destinationPath)
  end

  local err = Assert.throws(function()
    tx:publish()
  end)
  Assert.isTrue(Errors.is(err))
  Assert.equal(err.code, StorageErrors.CACHE_REPLACE_FAILED)
  Assert.equal(live:read(root .. "/old.bin"), "old")
  assertAttemptResidueAbsent(backend)
end

function T.interrupted_old_siblings_are_not_guessed_without_metadata()
  local backend = FakeCache.new()
  local live = cache("heartgold", backend)
  local firstRoot = "data/generated/field/maps"
  local secondRoot = "data/generated/field/cells"
  backend:write("heartgold/" .. firstRoot .. "/partial.bin", "partial")
  backend:write("heartgold/" .. firstRoot .. ".__g4old/previous.bin", "previous-map")
  backend:write("heartgold/" .. secondRoot .. ".__g4old/previous.bin", "previous-cell")

  local tx = ArtifactPublisher.begin(live, "field-world", { firstRoot, secondRoot })
  tx.stage:write(firstRoot .. "/replacement.bin", "replacement")
  tx.stage:write(secondRoot .. "/replacement.bin", "replacement")
  local originalReplace = backend.replace
  backend.replace = function(self, sourcePath, destinationPath)
    local versionPrefix = "heartgold/"
    if
      destinationPath:sub(1, #versionPrefix) == versionPrefix
      and destinationPath:find(".__g4next.", #versionPrefix + 1, true)
    then
      return false, "injected candidate move failure"
    end
    return originalReplace(self, sourcePath, destinationPath)
  end

  local err = Assert.throws(function()
    tx:publish()
  end)
  Assert.isTrue(Errors.is(err))
  Assert.equal(err.code, StorageErrors.CACHE_REPLACE_FAILED)
  Assert.equal(live:read(firstRoot .. "/partial.bin"), "partial")
  Assert.equal(backend.files["heartgold/" .. firstRoot .. ".__g4old/previous.bin"], "previous-map")
  Assert.equal(backend.files["heartgold/" .. secondRoot .. ".__g4old/previous.bin"], "previous-cell")
end

function T.publish_from_stage_restores_previous_root_on_failure()
  local backend = FakeCache.new()
  local c = cache("heartgold", backend)
  local s = staging("heartgold", backend)
  c:write("romfs/a/0/0/2", "OLD")
  c:write("rom-dump.complete", "OLD-MARKER")
  s:write("romfs/a/0/0/2", "NEW")
  s:write("rom-dump.complete", "NEW-MARKER")
  local originalReplace = backend.replace
  backend.replace = function(self, sourcePath, destinationPath)
    if sourcePath == "heartgold.__g4next" then
      error(Errors.new(StorageErrors.CACHE_REPLACE_FAILED, "injected publish failure", { sourcePath = sourcePath }))
    end
    return originalReplace(self, sourcePath, destinationPath)
  end
  local err = Assert.throws(function()
    c:publishFromStage(s)
  end)
  Assert.isTrue(Errors.is(err))
  Assert.equal(err.code, StorageErrors.CACHE_REPLACE_FAILED)
  Assert.equal(backend.files["heartgold/romfs/a/0/0/2"], "OLD", "previous dump must be restored")
  Assert.equal(backend.files["heartgold/rom-dump.complete"], "OLD-MARKER")
  Assert.isNil(backend.files["heartgold.__g4old/romfs/a/0/0/2"], "no orphaned old root after rollback")
end

-- Every mutating operation must translate a backend-reported failure into
-- a structured cache error. Backends may report failure by returning falsy;
-- no wrapper may silently return true, and publication must never report
-- success while a mutation it depends on has failed.

local function throwsCode(code, fn)
  local err = Assert.throws(fn)
  Assert.equal(err.code, code, "expected " .. code .. ", got " .. tostring(err))
end

function T.write_reports_backend_failure()
  local backend = FakeCache.new()
  backend.write = function()
    return false, "injected write failure"
  end
  throwsCode(StorageErrors.CACHE_WRITE_FAILED, function()
    cache("heartgold", backend):write("romfs/a/0/0/2", "data")
  end)
end

function T.write_reports_parent_directory_failure()
  local backend = FakeCache.new()
  backend.createDirectory = function()
    return false, "injected mkdir failure"
  end
  throwsCode(StorageErrors.CACHE_MKDIR_FAILED, function()
    cache("heartgold", backend):write("romfs/a/0/0/2", "data")
  end)
end

function T.create_directory_reports_backend_failure()
  local backend = FakeCache.new()
  backend.createDirectory = function()
    return false, "injected mkdir failure"
  end
  throwsCode(StorageErrors.CACHE_MKDIR_FAILED, function()
    cache("heartgold", backend):createDirectory("romfs/a")
  end)
end

function T.remove_reports_backend_failure()
  local backend = FakeCache.new()
  cache("heartgold", backend):write("romfs/a/0/0/2", "data")
  backend.remove = function()
    return false, "injected remove failure"
  end
  throwsCode(StorageErrors.CACHE_REMOVE_FAILED, function()
    cache("heartgold", backend):remove("romfs/a/0/0/2")
  end)
end

-- Removing an absent path is a no-op, matching _removeTreeAt: the backend is
-- never asked to remove something that does not exist.
function T.remove_absent_path_is_a_noop()
  local backend = FakeCache.new()
  backend.remove = function()
    error("backend must not be asked to remove an absent path")
  end
  Assert.isTrue(cache("heartgold", backend):remove("absent"))
end

function T.remove_tree_reports_backend_failure()
  local backend = FakeCache.new()
  cache("heartgold", backend):write("romfs/a/0/0/2", "data")
  backend.remove = function()
    return false, "injected remove failure"
  end
  throwsCode(StorageErrors.CACHE_REMOVE_FAILED, function()
    cache("heartgold", backend):removeTree("romfs/a")
  end)
end

function T.replace_reports_backend_failure()
  local backend = FakeCache.new()
  local c = cache("heartgold", backend)
  c:write("save/session.lua", "old")
  c:write("save/session.lua.tmp", "new")
  backend.replace = function()
    return false, "injected replace failure"
  end
  throwsCode(StorageErrors.CACHE_REPLACE_FAILED, function()
    c:replace("save/session.lua.tmp", "save/session.lua")
  end)
end

-- A backend-reported failure (falsy return, not a raise) must abort the
-- publish; publication can never report success when a rename failed.
function T.publish_from_stage_reports_aside_failure()
  local backend = FakeCache.new()
  local c = cache("heartgold", backend)
  local s = staging("heartgold", backend)
  c:write("romfs/a/0/0/2", "OLD")
  s:write("romfs/a/0/0/2", "NEW")
  backend.replace = function(self, sourcePath, destinationPath)
    if sourcePath == "heartgold" then
      return false, "injected replace failure"
    end
    return FakeCache.replace(self, sourcePath, destinationPath)
  end
  throwsCode(StorageErrors.CACHE_REPLACE_FAILED, function()
    c:publishFromStage(s)
  end)
  Assert.equal(backend.files["heartgold/romfs/a/0/0/2"], "OLD", "failed aside must leave the live dump in place")
  Assert.isNil(backend.files["heartgold.__g4old/romfs/a/0/0/2"], "nothing may land in the old root")
end

function T.publish_from_stage_restores_previous_root_when_replace_reports_failure()
  local backend = FakeCache.new()
  local c = cache("heartgold", backend)
  local s = staging("heartgold", backend)
  c:write("romfs/a/0/0/2", "OLD")
  c:write("rom-dump.complete", "OLD-MARKER")
  s:write("romfs/a/0/0/2", "NEW")
  s:write("rom-dump.complete", "NEW-MARKER")
  backend.replace = function(self, sourcePath, destinationPath)
    if sourcePath == "heartgold.__g4next" then
      return false, "injected publish failure"
    end
    return FakeCache.replace(self, sourcePath, destinationPath)
  end
  throwsCode(StorageErrors.CACHE_REPLACE_FAILED, function()
    c:publishFromStage(s)
  end)
  Assert.equal(backend.files["heartgold/romfs/a/0/0/2"], "OLD", "previous dump must be restored")
  Assert.equal(backend.files["heartgold/rom-dump.complete"], "OLD-MARKER")
  Assert.isNil(backend.files["heartgold.__g4old/romfs/a/0/0/2"], "no orphaned old root after rollback")
end

-- When the aside restore fails too, the rollback is incomplete: the previous
-- dump stays at the aside root (the only remaining recovery material) and the
-- failure reports both the original publish error and the rollback error.
function T.publish_from_stage_reports_incomplete_rollback()
  local backend = FakeCache.new()
  local c = cache("heartgold", backend)
  local s = staging("heartgold", backend)
  c:write("romfs/a/0/0/2", "OLD")
  c:write("rom-dump.complete", "OLD-MARKER")
  s:write("romfs/a/0/0/2", "NEW")
  s:write("rom-dump.complete", "NEW-MARKER")
  local originalReplace = backend.replace
  backend.replace = function(self, sourcePath, destinationPath)
    if sourcePath == "heartgold.__g4next" then
      return false, "injected publish failure"
    end
    if sourcePath:find("heartgold.__g4old", 1, true) then
      return false, "injected rollback failure"
    end
    return originalReplace(self, sourcePath, destinationPath)
  end
  local err = Assert.throws(function()
    c:publishFromStage(s)
  end)
  Assert.isTrue(Errors.is(err), "an incomplete rollback must surface as a structured error")
  Assert.equal(err.code, StorageErrors.CACHE_PUBLISH_ROLLBACK_INCOMPLETE)
  Assert.isTrue(
    tostring(err.context.cause):match(StorageErrors.CACHE_REPLACE_FAILED),
    "the original publish error is the cause"
  )
  Assert.isTrue(tostring(err.context.rollback):match("injected rollback failure"), "the rollback error is recorded")
  Assert.equal(
    findBackendFile(backend, "heartgold.__g4old", "/romfs/a/0/0/2"),
    "OLD",
    "the aside keeps the last-known-good dump"
  )
  Assert.equal(backend.files["heartgold.__g4next/romfs/a/0/0/2"], "NEW", "the staged dump stays in place")
end

-- A backend-reported failure removing the previous root after the swap must
-- surface as the shared cleanup outcome: the new dump is live, so the failure
-- reports cleanup-failed rather than a failed publication, and the old root is
-- the only recovery material left.
function T.publish_from_stage_reports_cleanup_failure()
  local backend = FakeCache.new()
  local c = cache("heartgold", backend)
  local s = staging("heartgold", backend)
  c:write("romfs/a/0/0/2", "OLD")
  s:write("romfs/a/0/0/2", "NEW")
  local originalRemove = backend.remove
  backend.remove = function(self, path)
    if path:find("heartgold.__g4old", 1, true) then
      return false, "injected cleanup failure"
    end
    return originalRemove(self, path)
  end
  local err = Assert.throws(function()
    c:publishFromStage(s)
  end)
  Assert.isTrue(Errors.is(err), "a cleanup failure must surface as a structured error")
  Assert.equal(err.code, StorageErrors.CACHE_PUBLISH_CLEANUP_FAILED)
  Assert.equal(backend.files["heartgold/romfs/a/0/0/2"], "NEW", "the new dump has landed before cleanup")
  Assert.equal(
    findBackendFile(backend, "heartgold.__g4old", "/romfs/a/0/0/2"),
    "OLD",
    "the old root is the only staging residue"
  )
end

function T.remove_staged_tree_reports_backend_failure()
  local backend = FakeCache.new()
  local c = cache("heartgold", backend)
  local s = staging("heartgold", backend)
  s:write("romfs/a/0/0/2", "STAGE")
  backend.remove = function()
    return false, "injected remove failure"
  end
  throwsCode(StorageErrors.CACHE_REMOVE_FAILED, function()
    c:removeStagedTree(s)
  end)
end

local PUBLISH_MANIFEST = "heartgold.__g4publish.lua"
local PUBLISH_NEXT = "heartgold.__g4publish.__g4next"
local PUBLISH_COMMIT = "heartgold.__g4published"

local function livePath(root)
  return "heartgold/" .. root
end

local function siblingRoot(root, suffix)
  return livePath(root) .. suffix
end

local function writePublicationRecord(backend, roots)
  backend:write(PUBLISH_MANIFEST, LuaWriter.encode({ schema = 1, roots = roots }))
end

local function writeAttemptPublicationRecord(backend, attemptId, roots)
  backend:write(PUBLISH_MANIFEST, LuaWriter.encode({ schema = 2, attemptId = attemptId, roots = roots }))
end

local function attemptSibling(root, suffix, attemptId)
  return siblingRoot(root, suffix .. "." .. attemptId)
end

assertAttemptResidueAbsent = function(backend)
  Assert.isNil(backend:getInfo(PUBLISH_MANIFEST))
  Assert.isNil(backend:getInfo(PUBLISH_NEXT))
  Assert.isNil(backend:getInfo(PUBLISH_COMMIT))
  for _, entries in ipairs({ backend.files, backend.dirs }) do
    for path in pairs(entries) do
      Assert.isFalse(path:find(".__g4publish.", 1, true) ~= nil, "publication journal residue: " .. path)
      Assert.isFalse(path:find(".__g4next.", 1, true) ~= nil, "candidate residue: " .. path)
      Assert.isFalse(path:find(".__g4old.", 1, true) ~= nil, "backup residue: " .. path)
    end
  end
end

function T.journals_manifest_before_file_candidate_materialization()
  local backend = FakeCache.new()
  local live = cache("heartgold", backend)
  local root = "data/generated/map-index.lua"
  live:write(root, "old-index")
  local tx = ArtifactPublisher.begin(live, "map-index", { root })
  tx.stage:write(root, "new-index")

  local observed = false
  local originalReplace = backend.replace
  backend.replace = function(self, sourcePath, destinationPath)
    local candidatePrefix = "heartgold/" .. root .. ".__g4next."
    if not observed and destinationPath:sub(1, #candidatePrefix) == candidatePrefix then
      observed = true
      local attemptId = destinationPath:sub(#candidatePrefix + 1)
      local tempPath = "heartgold.__g4publish." .. attemptId .. ".__g4next"
      local manifestData = self:read(tempPath)
      Assert.notNil(manifestData, "attempt temp manifest must precede candidate materialization")
      local manifest = assert(loadstring(manifestData))()
      Assert.equal(manifest.schema, 2)
      Assert.equal(manifest.attemptId, attemptId)
      Assert.equal(#manifest.roots, 1)
      Assert.equal(manifest.roots[1].path, root)
      Assert.isTrue(manifest.roots[1].hadLive)
      Assert.isNil(self:getInfo("heartgold.__g4publish.lua"))
    end
    return originalReplace(self, sourcePath, destinationPath)
  end

  tx:publish()

  Assert.isTrue(observed, "publication must materialize a file candidate")
  Assert.equal(live:read(root), "new-index")
  assertAttemptResidueAbsent(backend)
end

local function capturePublicationIdentity()
  local backend = FakeCache.new()
  local c = cache("heartgold", backend)
  local root = "data/generated/identity"
  local tx = ArtifactPublisher.begin(c, "publication-identity", { root })
  tx.stage:write(root .. "/value", "new")
  local manifestData
  local commitData
  local originalWrite = backend.write
  backend.write = function(self, path, data)
    if isManifestTempPath(path) then
      manifestData = data
    elseif path == PUBLISH_COMMIT then
      commitData = data
    end
    return originalWrite(self, path, data)
  end
  tx:publish()
  Assert.notNil(manifestData, "publication must write a manifest")
  Assert.notNil(commitData, "publication must write a commit token")
  local manifest = assert(loadstring(manifestData))()
  return { attemptId = manifest.attemptId, commit = commitData }
end

local function assertPublicationResidueAbsent(backend, roots)
  Assert.isNil(backend:getInfo(PUBLISH_MANIFEST))
  Assert.isNil(backend:getInfo(PUBLISH_NEXT))
  Assert.isNil(backend:getInfo(PUBLISH_COMMIT))
  for _, root in ipairs(roots) do
    Assert.isNil(backend:getInfo(siblingRoot(root, ".__g4old")))
    Assert.isNil(backend:getInfo(siblingRoot(root, ".__g4next")))
  end
end

function T.reentrant_recovery_cannot_delete_an_active_manifest_temp()
  local backend = FakeCache.new()
  local backendA, backendB = proxyBackends(backend)
  local c = cache("heartgold", backendA)
  local sibling = cache("heartgold", backendB)
  local root = "data/generated/alpha"
  c:write(root .. "/value", "old")
  local tx = ArtifactPublisher.begin(c, "reentrant-recovery", { root })
  tx.stage:write(root .. "/value", "new")

  local recoveryOk
  local tempRemains
  local originalWrite = backend.write
  backend.write = function(self, path, data)
    local ok, err = originalWrite(self, path, data)
    if ok and path:find(".__g4publish.", 1, true) and path:find(".__g4next", 1, true) then
      recoveryOk = pcall(function()
        sibling:recoverPublication()
      end)
      tempRemains = backend:getInfo(path) ~= nil
    end
    return ok, err
  end

  local ok, err = pcall(function()
    tx:publish()
  end)
  Assert.isTrue(recoveryOk, "a sibling recovery must return without disturbing publication")
  Assert.isTrue(tempRemains, "the active manifest temp must survive sibling recovery")
  Assert.isTrue(ok, tostring(err))
  Assert.equal(c:read(root .. "/value"), "new")
  assertAttemptResidueAbsent(backend)
end

function T.sibling_publication_is_rejected_before_it_can_mutate_live_data()
  local backend = FakeCache.new()
  local backendA, backendB = proxyBackends(backend)
  local first = cache("heartgold", backendA)
  local sibling = cache("heartgold", backendB)
  local otherVersion = cache("soulsilver", backendB)
  local firstRoot = "data/generated/alpha"
  local siblingLiveRoot = "data/generated/beta"
  local otherRoot = "data/generated/gamma"
  first:write(firstRoot .. "/value", "old")

  local firstTx = ArtifactPublisher.begin(first, "first-publication", { firstRoot })
  firstTx.stage:write(firstRoot .. "/value", "new")
  local siblingTx = ArtifactPublisher.begin(sibling, "sibling-publication", { siblingLiveRoot })
  siblingTx.stage:write(siblingLiveRoot .. "/value", "sibling")
  local otherTx = ArtifactPublisher.begin(otherVersion, "independent-publication", { otherRoot })
  otherTx.stage:write(otherRoot .. "/value", "independent")

  local siblingOk
  local siblingErr
  local independentOk
  local triggered = false
  local originalWrite = backend.write
  backend.write = function(self, path, data)
    local ok, err = originalWrite(self, path, data)
    if ok and not triggered and path:find("heartgold%.__g4publish.", 1, false) and path:find(".__g4next", 1, true) then
      triggered = true
      independentOk = pcall(function()
        otherTx:publish()
      end)
      siblingOk, siblingErr = pcall(function()
        siblingTx:publish()
      end)
    end
    return ok, err
  end

  local firstOk, firstErr = pcall(function()
    firstTx:publish()
  end)

  Assert.isTrue(triggered, "the second publication must be attempted during the first")
  Assert.isTrue(independentOk, "different versions sharing a resource must remain independent")
  Assert.isFalse(siblingOk, "a sibling publication must be rejected while the first is active")
  Assert.isTrue(tostring(siblingErr):find("publication is already active", 1, true) ~= nil)
  Assert.isTrue(firstOk, tostring(firstErr))
  Assert.equal(first:read(firstRoot .. "/value"), "new")
  Assert.isNil(sibling:getInfo(siblingLiveRoot))
  Assert.isNil(backend:getInfo("heartgold/data/generated/beta.__g4next"))
  Assert.equal(otherVersion:read(otherRoot .. "/value"), "independent")
  assertAttemptResidueAbsent(backend)
end

function T.uncommitted_attempt_recovery_restores_only_its_owned_roots()
  local backend = FakeCache.new()
  local c = cache("heartgold", backend)
  local roots = { "data/generated/alpha", "data/generated/beta" }
  local attemptA = "attempt-a"
  local attemptB = "attempt-b"

  backend:write(livePath(roots[1]) .. "/value", "alpha-new")
  backend:write(livePath(roots[2]) .. "/value", "beta-new")
  backend:write(attemptSibling(roots[1], ".__g4old", attemptA) .. "/value", "alpha-original")
  backend:write(attemptSibling(roots[1], ".__g4next", attemptA) .. "/value", "alpha-new")
  backend:write(attemptSibling(roots[2], ".__g4next", attemptA) .. "/value", "beta-new")
  backend:write(attemptSibling(roots[1], ".__g4old", attemptB) .. "/value", "foreign-old")
  backend:write(attemptSibling(roots[2], ".__g4next", attemptB) .. "/value", "foreign-next")
  writeAttemptPublicationRecord(backend, attemptA, {
    { path = roots[1], hadLive = true },
    { path = roots[2], hadLive = false },
  })

  c:recoverPublication()

  Assert.equal(c:read(roots[1] .. "/value"), "alpha-original")
  Assert.isNil(c:getInfo(roots[2]))
  Assert.isNil(backend:getInfo(attemptSibling(roots[1], ".__g4old", attemptA)))
  Assert.isNil(backend:getInfo(attemptSibling(roots[1], ".__g4next", attemptA)))
  Assert.isNil(backend:getInfo(attemptSibling(roots[2], ".__g4next", attemptA)))
  Assert.equal(backend.files[attemptSibling(roots[1], ".__g4old", attemptB) .. "/value"], "foreign-old")
  Assert.equal(backend.files[attemptSibling(roots[2], ".__g4next", attemptB) .. "/value"], "foreign-next")

  local replaceCalls = 0
  local removeCalls = 0
  local originalReplace = backend.replace
  local originalRemove = backend.remove
  backend.replace = function(self, sourcePath, destinationPath)
    replaceCalls = replaceCalls + 1
    return originalReplace(self, sourcePath, destinationPath)
  end
  backend.remove = function(self, path)
    removeCalls = removeCalls + 1
    return originalRemove(self, path)
  end
  c:recoverPublication()
  Assert.equal(replaceCalls, 0)
  Assert.equal(removeCalls, 0)
end

function T.commit_identity_preserves_matching_attempt_and_rejects_mismatch()
  local identityA = capturePublicationIdentity()
  local identityB = capturePublicationIdentity()
  local attemptA = identityA.attemptId or "attempt-a"
  local attemptB = identityB.attemptId or "attempt-b"
  Assert.isFalse(attemptA == attemptB, "publication attempts must have distinct identities")

  local roots = { "data/generated/alpha", "data/generated/beta" }
  local matchingBackend = FakeCache.new()
  local matching = cache("heartgold", matchingBackend)
  matchingBackend:write(livePath(roots[1]) .. "/value", "alpha-new")
  matchingBackend:write(livePath(roots[2]) .. "/value", "beta-new")
  matchingBackend:write(attemptSibling(roots[1], ".__g4old", attemptA) .. "/value", "alpha-original")
  matchingBackend:write(attemptSibling(roots[2], ".__g4old", attemptA) .. "/value", "beta-original")
  matchingBackend:write(attemptSibling(roots[1], ".__g4next", attemptA) .. "/value", "alpha-new")
  writeAttemptPublicationRecord(matchingBackend, attemptA, {
    { path = roots[1], hadLive = true },
    { path = roots[2], hadLive = true },
  })
  matchingBackend:write(PUBLISH_COMMIT, identityA.commit)

  matching:recoverPublication()

  Assert.equal(matching:read(roots[1] .. "/value"), "alpha-new")
  Assert.equal(matching:read(roots[2] .. "/value"), "beta-new")
  assertAttemptResidueAbsent(matchingBackend)

  local mismatchBackend = FakeCache.new()
  local mismatch = cache("heartgold", mismatchBackend)
  mismatchBackend:write(livePath(roots[1]) .. "/value", "alpha-new")
  mismatchBackend:write(livePath(roots[2]) .. "/value", "beta-new")
  mismatchBackend:write(attemptSibling(roots[1], ".__g4old", attemptA) .. "/value", "alpha-original")
  mismatchBackend:write(attemptSibling(roots[2], ".__g4old", attemptA) .. "/value", "beta-original")
  writeAttemptPublicationRecord(mismatchBackend, attemptA, {
    { path = roots[1], hadLive = true },
    { path = roots[2], hadLive = true },
  })
  mismatchBackend:write(PUBLISH_COMMIT, identityB.commit)

  local ok, err = pcall(function()
    mismatch:recoverPublication()
  end)
  Assert.isFalse(ok, "a commit for another attempt must not authorize cleanup")
  Assert.isTrue(Errors.is(err))
  Assert.equal(assert(err).code, StorageErrors.CACHE_PUBLISH_ROLLBACK_INCOMPLETE)
  Assert.equal(mismatch:read(roots[1] .. "/value"), "alpha-new")
  Assert.equal(mismatch:read(roots[2] .. "/value"), "beta-new")
  Assert.notNil(mismatchBackend:getInfo(PUBLISH_MANIFEST))
  Assert.notNil(mismatchBackend:getInfo(PUBLISH_COMMIT))
  Assert.equal(mismatchBackend.files[attemptSibling(roots[1], ".__g4old", attemptA) .. "/value"], "alpha-original")
end

function T.legacy_recovery_remains_available_and_new_publications_use_current_metadata()
  local uncommittedBackend = FakeCache.new()
  local uncommitted = cache("heartgold", uncommittedBackend)
  local uncommittedRoots = { "data/generated/alpha", "data/generated/beta" }
  uncommittedBackend:write(siblingRoot(uncommittedRoots[1], ".__g4old") .. "/value", "alpha-original")
  uncommittedBackend:write(livePath(uncommittedRoots[1]) .. "/value", "alpha-new")
  uncommittedBackend:write(livePath(uncommittedRoots[2]) .. "/value", "beta-new")
  writePublicationRecord(uncommittedBackend, {
    { path = uncommittedRoots[1], hadLive = true },
    { path = uncommittedRoots[2], hadLive = false },
  })
  uncommitted:recoverPublication()
  Assert.equal(uncommitted:read(uncommittedRoots[1] .. "/value"), "alpha-original")
  Assert.isNil(uncommitted:getInfo(uncommittedRoots[2]))
  assertPublicationResidueAbsent(uncommittedBackend, uncommittedRoots)

  local committedBackend = FakeCache.new()
  local committed = cache("heartgold", committedBackend)
  local committedRoots = { "data/generated/alpha", "data/generated/beta" }
  committedBackend:write(livePath(committedRoots[1]) .. "/value", "alpha-new")
  committedBackend:write(livePath(committedRoots[2]) .. "/value", "beta-new")
  committedBackend:write(siblingRoot(committedRoots[1], ".__g4old") .. "/value", "alpha-original")
  committedBackend:write(siblingRoot(committedRoots[2], ".__g4old") .. "/value", "beta-original")
  writePublicationRecord(committedBackend, {
    { path = committedRoots[1], hadLive = true },
    { path = committedRoots[2], hadLive = true },
  })
  committedBackend:write(PUBLISH_COMMIT, "g4-cache-publish-v1")
  committed:recoverPublication()
  Assert.equal(committed:read(committedRoots[1] .. "/value"), "alpha-new")
  Assert.equal(committed:read(committedRoots[2] .. "/value"), "beta-new")
  assertPublicationResidueAbsent(committedBackend, committedRoots)

  local backend = FakeCache.new()
  local c = cache("heartgold", backend)
  local root = "data/generated/alpha"
  local tx = ArtifactPublisher.begin(c, "metadata-upgrade", { root })
  tx.stage:write(root .. "/value", "new")
  local manifestData
  local originalWrite = backend.write
  backend.write = function(self, path, data)
    if path:find(".__g4publish.", 1, true) and path:find(".__g4next", 1, true) then
      manifestData = data
    end
    return originalWrite(self, path, data)
  end
  tx:publish()
  Assert.notNil(manifestData)
  local manifest = assert(loadstring(manifestData))()
  Assert.equal(manifest.schema, 2)
  Assert.notNil(manifest.attemptId)
end

function T.prepromotion_orphan_temps_do_not_touch_live_roots()
  local backend = FakeCache.new()
  local c = cache("heartgold", backend)
  local artifactRoot = "data/generated/orphan"
  local artifactAttempt = "orphan-artifact"
  backend:write(livePath(artifactRoot) .. "/value", "live")
  backend:write(attemptSibling(artifactRoot, ".__g4next", artifactAttempt) .. "/value", "staged")
  backend:write(
    "heartgold.__g4publish." .. artifactAttempt .. ".__g4next",
    LuaWriter.encode({
      schema = 2,
      attemptId = artifactAttempt,
      roots = { { path = artifactRoot, hadLive = true } },
    })
  )

  local wholeAttempt = "orphan-whole"
  backend:write("heartgold/romfs/old", "live-whole")
  backend:write("heartgold.__g4next/romfs/stage", "staged-whole")
  backend:write(
    "heartgold.__g4publish." .. wholeAttempt .. ".__g4next",
    LuaWriter.encode({ schema = 2, attemptId = wholeAttempt, roots = { { path = "", hadLive = true } } })
  )

  c:recoverPublication()

  Assert.equal(c:read(artifactRoot .. "/value"), "live")
  Assert.isNil(backend:getInfo(attemptSibling(artifactRoot, ".__g4next", artifactAttempt)))
  Assert.isNil(backend:getInfo("heartgold.__g4publish." .. artifactAttempt .. ".__g4next"))
  Assert.equal(backend.files["heartgold/romfs/old"], "live-whole")
  Assert.equal(backend.files["heartgold.__g4next/romfs/stage"], "staged-whole")
  Assert.isNil(backend:getInfo("heartgold.__g4publish." .. wholeAttempt .. ".__g4next"))
end

function T.partial_phase_one_recovery_preserves_untouched_live_root()
  local backend = FakeCache.new()
  local c = cache("heartgold", backend)
  local roots = { "data/generated/alpha", "data/generated/beta" }
  backend:write(livePath(roots[1]) .. "/value", "alpha-original")
  backend:write(livePath(roots[2]) .. "/value", "beta-original")
  backend:write(siblingRoot(roots[1], ".__g4old") .. "/value", "alpha-original")
  backend:write(siblingRoot(roots[1], ".__g4next") .. "/value", "alpha-new")
  backend:write(siblingRoot(roots[2], ".__g4next") .. "/value", "beta-new")
  writePublicationRecord(backend, {
    { path = roots[1], hadLive = true },
    { path = roots[2], hadLive = true },
  })

  c:recoverPublication()

  Assert.equal(backend.files[livePath(roots[1]) .. "/value"], "alpha-original")
  Assert.equal(backend.files[livePath(roots[2]) .. "/value"], "beta-original")
  assertPublicationResidueAbsent(backend, roots)
end

function T.uncommitted_recovery_restores_original_root_presence()
  local backend = FakeCache.new()
  local c = cache("heartgold", backend)
  local roots = { "data/generated/alpha", "data/generated/beta" }
  backend:write(siblingRoot(roots[1], ".__g4old") .. "/value", "alpha-original")
  backend:write(livePath(roots[1]) .. "/value", "alpha-new")
  backend:write(livePath(roots[2]) .. "/value", "beta-new")
  backend:write(siblingRoot(roots[1], ".__g4next") .. "/value", "alpha-new")
  backend:write(siblingRoot(roots[2], ".__g4next") .. "/value", "beta-new")
  writePublicationRecord(backend, {
    { path = roots[1], hadLive = true },
    { path = roots[2], hadLive = false },
  })

  c:recoverPublication()

  Assert.equal(backend.files[livePath(roots[1]) .. "/value"], "alpha-original")
  Assert.isNil(backend:getInfo(livePath(roots[2])))
  assertPublicationResidueAbsent(backend, roots)
end

function T.committed_recovery_preserves_new_roots_and_cleans_residue()
  local backend = FakeCache.new()
  local c = cache("heartgold", backend)
  local roots = { "data/generated/alpha", "data/generated/beta" }
  backend:write(livePath(roots[1]) .. "/value", "alpha-new")
  backend:write(livePath(roots[2]) .. "/value", "beta-new")
  backend:write(siblingRoot(roots[1], ".__g4old") .. "/value", "alpha-original")
  backend:write(siblingRoot(roots[2], ".__g4old") .. "/value", "beta-original")
  backend:write(siblingRoot(roots[1], ".__g4next") .. "/value", "alpha-new")
  writePublicationRecord(backend, {
    { path = roots[1], hadLive = true },
    { path = roots[2], hadLive = true },
  })
  backend:write(PUBLISH_COMMIT, "g4-cache-publish-v1")

  c:recoverPublication()

  Assert.equal(backend.files[livePath(roots[1]) .. "/value"], "alpha-new")
  Assert.equal(backend.files[livePath(roots[2]) .. "/value"], "beta-new")
  assertPublicationResidueAbsent(backend, roots)
end

function T.malformed_publication_metadata_leaves_live_roots_untouched()
  local backend = FakeCache.new()
  local c = cache("heartgold", backend)
  local roots = { "data/generated/alpha", "data/generated/beta" }
  c:write(roots[1] .. "/value", "alpha-original")
  c:write(roots[2] .. "/value", "beta-original")
  backend:write(PUBLISH_MANIFEST, LuaWriter.encode({ schema = 999, roots = {} }))
  local stage = CacheFs.forArtifactStage("heartgold", "recovery-check", backend)
  stage:write(roots[1] .. "/stale", "stale-stage")

  local ok, err = pcall(function()
    c:recoverPublication()
  end)

  Assert.isFalse(ok, "malformed publication metadata must stop stage initialization")
  Assert.notNil(err)
  Assert.isTrue(Errors.is(err), "malformed publication metadata must raise a structured storage error")
  Assert.equal(c:read(roots[1] .. "/value"), "alpha-original")
  Assert.equal(c:read(roots[2] .. "/value"), "beta-original")
  Assert.equal(backend.files["staging/heartgold/recovery-check/" .. roots[1] .. "/stale"], "stale-stage")

  ArtifactPublisher.begin(c, "recovery-check", roots)
  Assert.isNil(backend.files["staging/heartgold/recovery-check/" .. roots[1] .. "/stale"])
end

function T.empty_publication_manifest_is_structured_and_non_destructive()
  local backend = FakeCache.new()
  local c = cache("heartgold", backend)
  local root = "data/generated/alpha"
  c:write(root .. "/value", "live-original")
  backend:write(siblingRoot(root, ".__g4old") .. "/value", "old-original")
  backend:write(PUBLISH_MANIFEST, "return nil\n")

  local ok, err = pcall(function()
    c:recoverPublication()
  end)

  Assert.isFalse(ok, "an empty publication manifest must stop recovery")
  Assert.notNil(err)
  Assert.isTrue(Errors.is(err), "an empty publication manifest must raise a structured error")
  Assert.equal(assert(err).code, StorageErrors.CACHE_PUBLISH_ROLLBACK_INCOMPLETE)
  Assert.equal(c:read(root .. "/value"), "live-original")
  Assert.equal(backend.files[siblingRoot(root, ".__g4old") .. "/value"], "old-original")
end

function T.recovery_is_safe_to_repeat()
  local uncommittedBackend = FakeCache.new()
  local uncommitted = cache("heartgold", uncommittedBackend)
  local uncommittedRoots = { "data/generated/alpha", "data/generated/beta" }
  uncommittedBackend:write(siblingRoot(uncommittedRoots[1], ".__g4old") .. "/value", "alpha-original")
  uncommittedBackend:write(livePath(uncommittedRoots[2]) .. "/value", "beta-original")
  writePublicationRecord(uncommittedBackend, {
    { path = uncommittedRoots[1], hadLive = true },
    { path = uncommittedRoots[2], hadLive = true },
  })

  uncommitted:recoverPublication()
  local replaceCalls = 0
  local removeCalls = 0
  local writeCalls = 0
  local originalReplace = uncommittedBackend.replace
  local originalRemove = uncommittedBackend.remove
  local originalWrite = uncommittedBackend.write
  uncommittedBackend.replace = function(self, sourcePath, destinationPath)
    replaceCalls = replaceCalls + 1
    return originalReplace(self, sourcePath, destinationPath)
  end
  uncommittedBackend.remove = function(self, path)
    removeCalls = removeCalls + 1
    return originalRemove(self, path)
  end
  uncommittedBackend.write = function(self, path, data)
    writeCalls = writeCalls + 1
    return originalWrite(self, path, data)
  end

  uncommitted:recoverPublication()

  Assert.equal(replaceCalls, 0)
  Assert.equal(removeCalls, 0)
  Assert.equal(writeCalls, 0)
  Assert.equal(uncommittedBackend.files[livePath(uncommittedRoots[1]) .. "/value"], "alpha-original")
  Assert.equal(uncommittedBackend.files[livePath(uncommittedRoots[2]) .. "/value"], "beta-original")

  local committedBackend = FakeCache.new()
  local committed = cache("heartgold", committedBackend)
  local committedRoots = { "data/generated/alpha", "data/generated/beta" }
  committedBackend:write(livePath(committedRoots[1]) .. "/value", "alpha-new")
  committedBackend:write(livePath(committedRoots[2]) .. "/value", "beta-new")
  writePublicationRecord(committedBackend, {
    { path = committedRoots[1], hadLive = true },
    { path = committedRoots[2], hadLive = true },
  })
  committedBackend:write(PUBLISH_COMMIT, "g4-cache-publish-v1")

  committed:recoverPublication()
  replaceCalls = 0
  removeCalls = 0
  writeCalls = 0
  originalReplace = committedBackend.replace
  originalRemove = committedBackend.remove
  originalWrite = committedBackend.write
  committedBackend.replace = function(self, sourcePath, destinationPath)
    replaceCalls = replaceCalls + 1
    return originalReplace(self, sourcePath, destinationPath)
  end
  committedBackend.remove = function(self, path)
    removeCalls = removeCalls + 1
    return originalRemove(self, path)
  end
  committedBackend.write = function(self, path, data)
    writeCalls = writeCalls + 1
    return originalWrite(self, path, data)
  end

  committed:recoverPublication()

  Assert.equal(replaceCalls, 0)
  Assert.equal(removeCalls, 0)
  Assert.equal(writeCalls, 0)
  Assert.equal(committedBackend.files[livePath(committedRoots[1]) .. "/value"], "alpha-new")
  Assert.equal(committedBackend.files[livePath(committedRoots[2]) .. "/value"], "beta-new")
end

function T.manifest_write_failure_does_not_touch_live_roots()
  local backend = FakeCache.new()
  local c = cache("heartgold", backend)
  local root = "data/generated/alpha"
  c:write(root .. "/value", "old")
  local tx = ArtifactPublisher.begin(c, "manifest-write", { root })
  tx.stage:write(root .. "/value", "new")
  local originalWrite = backend.write
  backend.write = function(self, path, data)
    if isManifestTempPath(path) then
      return false, "injected manifest write failure"
    end
    return originalWrite(self, path, data)
  end

  local err = Assert.throws(function()
    tx:publish()
  end)

  Assert.equal(err.code, StorageErrors.CACHE_WRITE_FAILED)
  Assert.equal(c:read(root .. "/value"), "old")
  Assert.isNil(backend:getInfo(PUBLISH_MANIFEST))
  Assert.isNil(backend:getInfo(PUBLISH_NEXT))
  Assert.isNil(backend:getInfo(PUBLISH_COMMIT))
end

function T.manifest_promotion_failure_does_not_touch_live_roots()
  local backend = FakeCache.new()
  local c = cache("heartgold", backend)
  local root = "data/generated/alpha"
  c:write(root .. "/value", "old")
  local tx = ArtifactPublisher.begin(c, "manifest-promotion", { root })
  tx.stage:write(root .. "/value", "new")
  local originalReplace = backend.replace
  backend.replace = function(self, sourcePath, destinationPath)
    if isManifestTempPath(sourcePath) then
      return false, "injected manifest promotion failure"
    end
    return originalReplace(self, sourcePath, destinationPath)
  end

  local err = Assert.throws(function()
    tx:publish()
  end)

  Assert.equal(err.code, StorageErrors.CACHE_REPLACE_FAILED)
  Assert.equal(c:read(root .. "/value"), "old")
  Assert.isNil(backend:getInfo(PUBLISH_MANIFEST))
  Assert.isNil(backend:getInfo(PUBLISH_NEXT))
end

function T.commit_write_failure_rolls_back_the_published_roots()
  local backend = FakeCache.new()
  local c = cache("heartgold", backend)
  local root = "data/generated/alpha"
  c:write(root .. "/value", "old")
  local tx = ArtifactPublisher.begin(c, "commit-write", { root })
  tx.stage:write(root .. "/value", "new")
  local originalWrite = backend.write
  backend.write = function(self, path, data)
    if path == PUBLISH_COMMIT then
      return false, "injected commit write failure"
    end
    return originalWrite(self, path, data)
  end

  local err = Assert.throws(function()
    tx:publish()
  end)

  Assert.equal(err.code, StorageErrors.CACHE_WRITE_FAILED)
  Assert.equal(c:read(root .. "/value"), "old")
  Assert.isNil(backend:getInfo(siblingRoot(root, ".__g4old")))
  Assert.isNil(backend:getInfo(PUBLISH_MANIFEST))
end

function T.cleanup_failure_keeps_committed_metadata_recoverable()
  local backend = FakeCache.new()
  local c = cache("heartgold", backend)
  local root = "data/generated/alpha"
  c:write(root .. "/value", "old")
  local tx = ArtifactPublisher.begin(c, "old-cleanup", { root })
  tx.stage:write(root .. "/value", "new")
  local originalRemove = backend.remove
  backend.remove = function(self, path)
    if path:find(".__g4old", 1, true) then
      return false, "injected old cleanup failure"
    end
    return originalRemove(self, path)
  end

  local err = Assert.throws(function()
    tx:publish()
  end)

  Assert.equal(err.code, StorageErrors.CACHE_PUBLISH_CLEANUP_FAILED)
  Assert.equal(err.context.phase, "recovery-material")
  Assert.equal(c:read(root .. "/value"), "new")
  Assert.notNil(backend:getInfo(PUBLISH_MANIFEST))
  Assert.notNil(backend:getInfo(PUBLISH_COMMIT))
  backend.remove = originalRemove
  c:recoverPublication()
  for _, entries in ipairs({ backend.files, backend.dirs }) do
    for path in pairs(entries) do
      Assert.isFalse(path:find(siblingRoot(root, ".__g4old"), 1, true) ~= nil)
    end
  end
  Assert.isNil(backend:getInfo(PUBLISH_MANIFEST))
  Assert.isNil(backend:getInfo(PUBLISH_COMMIT))
end

function T.manifest_cleanup_failure_leaves_the_commit_boundary_intact()
  local backend = FakeCache.new()
  local c = cache("heartgold", backend)
  local root = "data/generated/alpha"
  c:write(root .. "/value", "old")
  local tx = ArtifactPublisher.begin(c, "manifest-cleanup", { root })
  tx.stage:write(root .. "/value", "new")
  local originalRemove = backend.remove
  backend.remove = function(self, path)
    if path == PUBLISH_MANIFEST then
      return false, "injected manifest cleanup failure"
    end
    return originalRemove(self, path)
  end

  local err = Assert.throws(function()
    tx:publish()
  end)

  Assert.equal(err.code, StorageErrors.CACHE_PUBLISH_CLEANUP_FAILED)
  Assert.equal(c:read(root .. "/value"), "new")
  Assert.notNil(backend:getInfo(PUBLISH_MANIFEST))
  Assert.notNil(backend:getInfo(PUBLISH_COMMIT))
  backend.remove = originalRemove
  c:recoverPublication()
  Assert.isNil(backend:getInfo(PUBLISH_MANIFEST))
  Assert.isNil(backend:getInfo(PUBLISH_COMMIT))
end

function T.commit_cleanup_failure_leaves_commit_only_residue_safe()
  local backend = FakeCache.new()
  local c = cache("heartgold", backend)
  local root = "data/generated/alpha"
  c:write(root .. "/value", "old")
  local tx = ArtifactPublisher.begin(c, "commit-cleanup", { root })
  tx.stage:write(root .. "/value", "new")
  local originalRemove = backend.remove
  backend.remove = function(self, path)
    if path == PUBLISH_COMMIT then
      return false, "injected commit cleanup failure"
    end
    return originalRemove(self, path)
  end

  local err = Assert.throws(function()
    tx:publish()
  end)

  Assert.equal(err.code, StorageErrors.CACHE_PUBLISH_CLEANUP_FAILED)
  Assert.equal(c:read(root .. "/value"), "new")
  Assert.isNil(backend:getInfo(PUBLISH_MANIFEST))
  Assert.notNil(backend:getInfo(PUBLISH_COMMIT))
  backend.remove = originalRemove
  c:recoverPublication()
  Assert.isNil(backend:getInfo(PUBLISH_COMMIT))
end

function T.contradictory_root_metadata_fails_before_live_mutation()
  local backend = FakeCache.new()
  local c = cache("heartgold", backend)
  local root = "data/generated/alpha"
  c:write(root .. "/value", "live")
  backend:write(siblingRoot(root, ".__g4old") .. "/value", "old")
  writePublicationRecord(backend, { { path = root, hadLive = false } })

  local ok, err = pcall(function()
    c:recoverPublication()
  end)

  Assert.isFalse(ok)
  Assert.isTrue(Errors.is(err))
  Assert.equal(assert(err).code, StorageErrors.CACHE_PUBLISH_ROLLBACK_INCOMPLETE)
  Assert.equal(c:read(root .. "/value"), "live")
  Assert.equal(backend.files[siblingRoot(root, ".__g4old") .. "/value"], "old")
end

-- Compressed derived storage: a fake backend carrying faithful host
-- codecs, so the suites pin logical behavior without depending on how
-- production threads the seam.
local function codecCache(versionId)
  local backend = FakeCache.new()
  CacheEnvelope.attachHostCodecs(backend)
  return CacheFs.forVersion(versionId or "heartgold", backend), backend
end

local function backendBytes(backend, versionId, relativePath)
  local physical = backend.files[versionId .. "/" .. relativePath]
  Assert.equal(type(physical), "string", "expected stored bytes at " .. relativePath)
  assert(type(physical) == "string", "stored bytes must be a string")
  return physical
end

-- Representative compressible payloads stay byte-identical through the
-- logical API while landing physically smaller inside the envelope; tiny
-- payloads and files that would not shrink stay raw.
function T.compressible_generated_families_store_smaller_but_read_exactly()
  local c, backend = codecCache()
  local cases = {
    {
      path = "geometry/chunk.g4mesh",
      codec = CacheEnvelope.CODEC_LZ4,
      payload = string.rep("vertex-block-0123456789;", 300),
    },
    {
      path = "geometry/level.g4collision",
      codec = CacheEnvelope.CODEC_LZ4,
      payload = string.rep("collision-cell-0123456789;", 300),
    },
    {
      path = "audio/sample.pcm16le",
      codec = CacheEnvelope.CODEC_ZLIB,
      payload = string.rep("\0\1\2\3sample;", 512),
    },
    {
      path = "data/generated/big.lua",
      codec = CacheEnvelope.CODEC_ZLIB,
      payload = "--" .. string.rep("padding;", 300) .. "\nreturn { answer = 42 }\n",
    },
  }
  for _, case in ipairs(cases) do
    Assert.isTrue(#case.payload >= 1024, "the fixture must clear the wrap threshold: " .. case.path)
    c:write(case.path, case.payload)
    local physical = backendBytes(backend, "heartgold", case.path)
    Assert.isTrue(#physical < #case.payload, "wrapped bytes must save space: " .. case.path)
    Assert.isTrue(CacheEnvelope.isWrapped(physical), "wrapped bytes carry the envelope tag: " .. case.path)
    local header = CacheEnvelope.parse(physical)
    assert(header, "wrapped bytes must parse")
    Assert.equal(header.codec, case.codec, "the codec follows the path family: " .. case.path)
    Assert.equal(header.length, #case.payload, "the header records the logical length: " .. case.path)
    Assert.equal(c:read(case.path), case.payload, "the logical read is exact: " .. case.path)
  end
  Assert.deepEqual(c:loadLua("data/generated/big.lua"), { answer = 42 })

  -- A payload too small to benefit from wrapping stays byte-for-byte raw.
  local tiny = "return { tiny = true }\n"
  c:write("data/generated/small.lua", tiny)
  Assert.equal(backendBytes(backend, "heartgold", "data/generated/small.lua"), tiny)
  Assert.equal(c:read("data/generated/small.lua"), tiny)

  -- A small file that happens to start with the reserved tag must still
  -- round-trip exactly instead of being misread as an envelope.
  local tricky = "PDC1" .. string.rep("q", 64)
  c:write("data/generated/tricky.lua", tricky)
  Assert.equal(c:read("data/generated/tricky.lua"), tricky)
end

-- A damaged envelope is a loud structured decode failure, never a silent
-- raw passthrough and never a missing file.
function T.damaged_envelopes_fail_as_decode_errors_not_absences()
  local c, backend = codecCache()
  local logical = string.rep("audio-sample-block;", 200)
  local good = CacheEnvelope.build(CacheEnvelope.CODEC_ZLIB, logical)
  local function plant(path, physical)
    backend:write("heartgold/" .. path, physical)
  end
  plant("audio/bad-codec.pcm16le", "PDC1" .. string.char(9) .. good:sub(6))
  plant("audio/short.pcm16le", "PDC1" .. string.char(2))
  plant(
    "audio/damaged.pcm16le",
    good:sub(1, -2) .. (good:sub(-1, -1) == "A" and "B" or "A")
  )
  plant("audio/bad-hash.pcm16le", good:sub(1, 9) .. string.rep("\0", 20) .. good:sub(30))
  plant("audio/huge.pcm16le", "PDC1" .. string.char(2) .. "\255\255\255\255" .. string.rep("\0", 20) .. "x")
  plant("data/generated/broken.lua", good:sub(1, -2) .. (good:sub(-1, -1) == "A" and "B" or "A"))
  local damaged = {
    "audio/bad-codec.pcm16le",
    "audio/short.pcm16le",
    "audio/damaged.pcm16le",
    "audio/bad-hash.pcm16le",
    "audio/huge.pcm16le",
  }
  for _, path in ipairs(damaged) do
    local ok, err = pcall(function()
      return c:read(path)
    end)
    Assert.isFalse(ok, "a damaged envelope must raise: " .. path)
    Assert.isTrue(Errors.is(err), "the failure must be structured: " .. tostring(err))
    Assert.equal(err.code, CacheEnvelope.DECODE_FAILED, "the failure names decoding: " .. path)
  end
  local value, loadErr = c:loadLua("data/generated/broken.lua")
  Assert.isNil(value, "a damaged Lua envelope must not evaluate")
  Assert.isTrue(Errors.is(loadErr), "the load failure must be structured")
  Assert.equal(loadErr.code, CacheEnvelope.DECODE_FAILED)

  -- Genuine absence keeps its existing meaning alongside the new failure.
  Assert.isNil(c:read("audio/never-written.pcm16le"))
  local missing, missingErr = c:loadLua("data/generated/absent.lua")
  Assert.isNil(missing)
  Assert.equal(missingErr.code, StorageErrors.CACHE_FILE_MISSING)
end

-- Portable image bytes are never wrapped, and generated script modules keep
-- their restricted require sandbox whether stored raw or wrapped.
function T.png_bytes_stay_native_and_wrapped_modules_keep_the_require_allowlist()
  local c, backend = codecCache()
  local pixels = {}
  for y = 0, 127 do
    for x = 0, 127 do
      pixels[#pixels + 1] = string.char(x % 256, y % 256, (x + y) % 256, 255)
    end
  end
  local png = PngWriter.encode(128, 128, table.concat(pixels))
  Assert.isTrue(#png >= 1024, "the png fixture must clear the wrap threshold")
  c:write("textures/atlas.png", png)
  local physical = backendBytes(backend, "heartgold", "textures/atlas.png")
  Assert.equal(physical, png, "png bytes stay byte-for-byte native")
  Assert.equal(physical:sub(1, 8), "\137PNG\r\n\26\n", "the stored file keeps its png signature")
  Assert.equal(c:read("textures/atlas.png"), png)

  local padding = "--" .. string.rep("padding;", 200) .. "\n"
  local allowedSource = padding .. 'local S = require("gen4.script")\nreturn { api = S.apiVersion, id = "a.b" }\n'
  Assert.isTrue(#allowedSource >= 1024, "the module fixture must clear the wrap threshold")
  c:write("data/generated/script/a.b.lua", allowedSource)
  local wrapped = backendBytes(backend, "heartgold", "data/generated/script/a.b.lua")
  Assert.isTrue(CacheEnvelope.isWrapped(wrapped), "a profitable module is wrapped")
  Assert.isTrue(#wrapped < #allowedSource, "the wrapped module saves space")
  Assert.deepEqual(
    c:loadModule("data/generated/script/a.b.lua"),
    { api = Schema.API_VERSION, id = "a.b" },
    "a wrapped allowlisted module evaluates identically"
  )

  local deniedSource = padding .. 'local X = require("libs.errors.src.Errors")\nreturn X\n'
  c:write("data/generated/script/evil.lua", deniedSource)
  local deniedPhysical = backendBytes(backend, "heartgold", "data/generated/script/evil.lua")
  Assert.isTrue(CacheEnvelope.isWrapped(deniedPhysical), "a profitable denied module is still wrapped")
  local denied, deniedErr = c:loadModule("data/generated/script/evil.lua")
  Assert.isNil(denied, "a module reaching outside the allowlist must fail wrapped or not")
  Assert.isTrue(Errors.is(deniedErr), "the rejection must stay structured")
  Assert.isFalse(
    deniedErr.code == CacheEnvelope.DECODE_FAILED,
    "the rejection is sandbox policy, not a decode failure"
  )
end

-- Deterministic pseudorandom bytes that no codec can shrink: large but
-- incompressible payloads, unknown extensions, and recovery metadata all
-- stay byte-for-byte raw while remaining exactly readable.
function T.unprofitable_inputs_and_foreign_paths_stay_raw()
  local c, backend = codecCache()
  local blocks, prev = {}, "incompressible-seed"
  for _ = 1, 220 do
    prev = love.data.hash("sha1", prev)
    assert(type(prev) == "string" and #prev == 20, "host sha1 must be a 20-byte binary digest")
    blocks[#blocks + 1] = prev
  end
  local noise = table.concat(blocks):sub(1, 4096)
  c:write("geometry/noise.g4mesh", noise)
  Assert.equal(backendBytes(backend, "heartgold", "geometry/noise.g4mesh"), noise)
  Assert.isFalse(CacheEnvelope.isWrapped(backend.files["heartgold/geometry/noise.g4mesh"]))
  Assert.equal(c:read("geometry/noise.g4mesh"), noise)

  local repetitive = string.rep("compressible-block;", 200)
  c:write("data/generated/blob.bin", repetitive)
  Assert.equal(backendBytes(backend, "heartgold", "data/generated/blob.bin"), repetitive)
  Assert.equal(c:read("data/generated/blob.bin"), repetitive)

  local journalish = "--" .. string.rep("journal-padding;", 200) .. "\nreturn { journal = true }\n"
  c:write("data/generated/x.__g4publish.lua", journalish)
  Assert.equal(backendBytes(backend, "heartgold", "data/generated/x.__g4publish.lua"), journalish)
  Assert.equal(c:read("data/generated/x.__g4publish.lua"), journalish)

  c:write("_prepared/result.lua", journalish)
  Assert.equal(backendBytes(backend, "heartgold", "_prepared/result.lua"), journalish)
  Assert.equal(c:read("_prepared/result.lua"), journalish)
end

-- A well-formed envelope under the wrong path family, a header that lies
-- about the decoded length, and a header with no payload all fail as
-- structured decode errors rather than returning damaged bytes.
function T.wrong_family_and_lying_headers_fail_as_decode_errors()
  local c, backend = codecCache()
  local logical = string.rep("family-fixture-block;", 200)
  backend:write("heartgold/audio/family.pcm16le", CacheEnvelope.build(CacheEnvelope.CODEC_LZ4, logical))
  local familyOk, familyErr = pcall(function()
    return c:read("audio/family.pcm16le")
  end)
  Assert.isFalse(familyOk, "an lz4 envelope under a zlib path must raise")
  Assert.isTrue(Errors.is(familyErr))
  Assert.equal(familyErr.code, CacheEnvelope.DECODE_FAILED)

  backend:write("heartgold/geometry/family.g4mesh", CacheEnvelope.build(CacheEnvelope.CODEC_ZLIB, logical))
  local meshOk, meshErr = pcall(function()
    return c:read("geometry/family.g4mesh")
  end)
  Assert.isFalse(meshOk, "a zlib envelope under an lz4 path must raise")
  Assert.isTrue(Errors.is(meshErr))
  Assert.equal(meshErr.code, CacheEnvelope.DECODE_FAILED)

  local compressed = love.data.compress("string", "zlib", logical)
  assert(type(compressed) == "string", "host compression must return a string")
  local digest = love.data.hash("sha1", logical)
  assert(type(digest) == "string" and #digest == 20, "host sha1 must be a 20-byte binary digest")
  local function u32le(value)
    local bytes = {}
    for _ = 1, 4 do
      bytes[#bytes + 1] = string.char(value % 256)
      value = math.floor(value / 256)
    end
    return table.concat(bytes)
  end
  local lying = "PDC1" .. string.char(CacheEnvelope.CODEC_ZLIB) .. u32le(#logical + 7) .. digest .. compressed
  backend:write("heartgold/audio/lying.pcm16le", lying)
  local lyingOk, lyingErr = pcall(function()
    return c:read("audio/lying.pcm16le")
  end)
  Assert.isFalse(lyingOk, "a header lying about the decoded length must raise")
  Assert.isTrue(Errors.is(lyingErr))
  Assert.equal(lyingErr.code, CacheEnvelope.DECODE_FAILED)

  local good = CacheEnvelope.build(CacheEnvelope.CODEC_ZLIB, logical)
  backend:write("heartgold/audio/header-only.pcm16le", good:sub(1, CacheEnvelope.HEADER_SIZE))
  local headerOk, headerErr = pcall(function()
    return c:read("audio/header-only.pcm16le")
  end)
  Assert.isFalse(headerOk, "a header with no payload must raise")
  Assert.isTrue(Errors.is(headerErr))
  Assert.equal(headerErr.code, CacheEnvelope.DECODE_FAILED)
end

-- The restricted require sandbox behaves identically for small unwrapped
-- modules: the physical bytes stay raw and the allowlist still decides.
function T.unwrapped_modules_keep_the_require_allowlist()
  local c, backend = codecCache()
  local allowedSource = 'local S = require("gen4.script")\nreturn { api = S.apiVersion, id = "raw.a" }\n'
  c:write("data/generated/script/raw.lua", allowedSource)
  Assert.equal(backendBytes(backend, "heartgold", "data/generated/script/raw.lua"), allowedSource)
  Assert.deepEqual(
    c:loadModule("data/generated/script/raw.lua"),
    { api = Schema.API_VERSION, id = "raw.a" },
    "an unwrapped allowlisted module evaluates identically"
  )
end

-- A backend without codec callbacks still writes and reads raw generated
-- bytes exactly, but a wrapped physical file is a typed decode failure
-- rather than a misread; tag-colliding raw writes are rejected at write.
function T.backend_without_codecs_keeps_raw_but_refuses_wrapped_reads()
  local backend = FakeCache.new()
  local c = CacheFs.forVersion("heartgold", backend)
  local logical = "--" .. string.rep("codec-less-padding;", 200) .. "\nreturn { plain = true }\n"
  Assert.isTrue(#logical >= 1024, "the fixture must clear the wrap threshold")
  c:write("data/generated/plain.lua", logical)
  Assert.equal(backend.files["heartgold/data/generated/plain.lua"], logical)
  Assert.equal(c:read("data/generated/plain.lua"), logical)
  Assert.deepEqual(c:loadLua("data/generated/plain.lua"), { plain = true })

  local wrappedLogical = string.rep("wrapped-without-codec;", 200)
  backend:write("heartgold/audio/planted.pcm16le", CacheEnvelope.build(CacheEnvelope.CODEC_ZLIB, wrappedLogical))
  local readOk, readErr = pcall(function()
    return c:read("audio/planted.pcm16le")
  end)
  Assert.isFalse(readOk, "a wrapped read without a codec must raise")
  Assert.isTrue(Errors.is(readErr))
  Assert.equal(readErr.code, CacheEnvelope.DECODE_FAILED)

  backend:write("heartgold/data/generated/planted.lua", CacheEnvelope.build(CacheEnvelope.CODEC_ZLIB, logical))
  local value, loadErr = c:loadLua("data/generated/planted.lua")
  Assert.isNil(value, "a wrapped load without a codec must not evaluate")
  Assert.isTrue(Errors.is(loadErr))
  Assert.equal(loadErr.code, CacheEnvelope.DECODE_FAILED)

  local colliding = "PDC1" .. string.rep("q", 64)
  local writeErr = Assert.throws(function()
    c:write("data/generated/colliding.lua", colliding)
  end)
  Assert.isTrue(Errors.is(writeErr))
  Assert.equal(writeErr.code, StorageErrors.CACHE_WRITE_FAILED)
end

-- The physical envelope never exceeds what the decoder can represent: a
-- compressible payload above the decoded-length ceiling is stored raw and
-- reads back byte-identically, while an oversized payload colliding with
-- the envelope tag is refused before any file appears. A planted header
-- lying about its decoded length stays a loud decode failure.
function T.physical_envelopes_stay_within_the_decoder_length_limit()
  local c, backend = codecCache()
  local limit = 64 * 1024 * 1024
  local huge = string.rep("a", limit + 1)
  c:write("audio/huge.pcm16le", huge)
  local physical = backendBytes(backend, "heartgold", "audio/huge.pcm16le")
  Assert.isFalse(
    CacheEnvelope.isWrapped(physical),
    "an oversized payload must stay raw so its own reader accepts it"
  )
  Assert.equal(c:read("audio/huge.pcm16le"), huge, "an oversized raw payload round-trips exactly")
  huge = nil
  physical = nil
  collectgarbage("collect")

  local exact = string.rep("b", limit)
  c:write("audio/exact.pcm16le", exact)
  Assert.equal(c:read("audio/exact.pcm16le"), exact, "a payload exactly at the ceiling stays readable")
  exact = nil
  collectgarbage("collect")

  local colliding = "PDC1" .. string.rep("a", limit - 3)
  local writeErr = Assert.throws(function()
    c:write("audio/colliding.pcm16le", colliding)
  end)
  Assert.isTrue(Errors.is(writeErr))
  Assert.equal(writeErr.code, StorageErrors.CACHE_WRITE_FAILED)
  Assert.isNil(
    c:read("audio/colliding.pcm16le"),
    "a refused oversized write leaves no file behind"
  )
  colliding = nil
  collectgarbage("collect")

  backend:write(
    "heartgold/audio/planted-huge.pcm16le",
    "PDC1" .. string.char(2) .. "\255\255\255\255" .. string.rep("\0", 20) .. "x"
  )
  local readOk, readErr = pcall(function()
    return c:read("audio/planted-huge.pcm16le")
  end)
  Assert.isFalse(readOk, "a planted oversized header must raise")
  Assert.isTrue(Errors.is(readErr))
  Assert.equal(readErr.code, CacheEnvelope.DECODE_FAILED)
end

return { tests = T }
