-- CacheFs physical-root behavior: version confinement, byte-exact storage,
-- mutation results, and Lua loading. Generated payloads are now resident, so
-- the physical root carries source bindings and explicit tooling only, and it
-- stores exactly the logical bytes it is given -- there is no per-file
-- compression envelope and no staged tree publication.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local Errors = require("libs.errors.src.Errors")
local StorageErrors = require("libs.storage.src.errors")
local FakeCache = require("tests.support.FakeCache")
local ResidentCache = require("libs.storage.src.ResidentCache")

local function cache(versionId, backend)
  return CacheFs.forVersion(versionId, backend or FakeCache.new())
end

local T = {}

function T.prefix_reflects_version()
  Assert.equal(cache("heartgold"):prefix(), "heartgold/")
  Assert.equal(cache("soulsilver"):prefix(), "soulsilver/")
end

-- Version ids are structural path components, not ROM identities: any safe
-- component names its own namespace. Which ids exist is romdump's GameVersion
-- business; generic persistence must not depend on it.

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

-- A resident reader adapts one epoch's compact bytes: it lends the committed
-- Data buffers, reads small metadata as text, evaluates generated Lua and
-- script modules through the shared confined loader, and refuses every
-- mutation because the resident corpus is immutable.
function T.resident_reader_serves_committed_bytes_and_refuses_mutation()
  local store = ResidentCache.new("heartgold", "base:probe")
  local text = "assets/generated/field/30/atlas.png"
  local lua = "data/generated/field/30/scene.lua"
  local luaSource = "return { mapId = 30 }"
  store:commit(store:prepare({
    {
      path = text,
      data = assert(love.data.newByteData("PNGDATA")),
      size = 7,
      sourceId = "base:probe",
      contentId = "probe\0" .. text,
    },
    {
      path = lua,
      data = assert(love.data.newByteData(luaSource)),
      size = #luaSource,
      sourceId = "base:probe",
      contentId = "probe\0" .. lua,
    },
  }))
  local reader = CacheFs.fromStore(store)
  Assert.isTrue(reader:isResident(), "the reader knows it owns no host path")
  Assert.equal(reader.versionId, "heartgold")
  Assert.equal(reader:read(text), "PNGDATA", "small metadata reads as text")
  Assert.equal(reader:readData(text):getString(), "PNGDATA", "the borrowed buffer is the committed one")
  Assert.equal(reader:resolveAsset(text).contentId, "probe\0" .. text, "the reference keeps its content identity")
  Assert.isTrue(reader:exists(text, "file"), "a committed entry exists")
  Assert.isNil(reader:read("assets/generated/field/30/missing.png"), "an absent entry reads as nil")
  Assert.deepEqual(
    reader:getDirectoryItems("assets/generated/field/30"),
    { "atlas.png" },
    "the directory lists its children"
  )
  local scene = assert(reader:loadLua(lua), "generated metadata still loads as Lua")
  Assert.equal(scene.mapId, 30)

  local mutationOk, mutationError = pcall(function()
    reader:write(lua, "return {}")
  end)
  Assert.isFalse(mutationOk, "the resident corpus is immutable")
  Assert.isTrue(tostring(mutationError):find("immutable", 1, true) ~= nil, "the refusal names residency")

  store:close()
  Assert.isNil(reader:read(text), "a revoked view serves nothing new")
end

-- The physical root stores the logical bytes verbatim. A large compressible
-- payload is not wrapped, and a payload that merely begins with the retired
-- envelope tag is ordinary content, not a header to interpret.
function T.physical_root_stores_logical_bytes_unchanged()
  local backend = FakeCache.new()
  local c = cache("heartgold", backend)
  local audio = string.rep("pcm-sample;", 400)
  c:write("assets/generated/audio/bank.pcm16le", audio)
  Assert.equal(backend.files["heartgold/assets/generated/audio/bank.pcm16le"], audio, "no envelope wraps stored bytes")
  Assert.equal(c:read("assets/generated/audio/bank.pcm16le"), audio, "the payload reads back byte-identically")

  local tagged = "PDC1" .. string.rep("q", 64)
  c:write("data/generated/tagged.lua", tagged)
  Assert.equal(backend.files["heartgold/data/generated/tagged.lua"], tagged, "the retired tag is ordinary payload")
  Assert.equal(c:read("data/generated/tagged.lua"), tagged, "a tagged payload is never decoded")
end

-- The read shape a selected session's package set exposes to the overlay: a
-- winner resolves to a disk source reference with no resident bytes, and one
-- immediate read serves transient callers. The ordered selection itself belongs
-- to its own owner and the acceptance scenario; this fake supplies only the
-- three read operations the overlay is allowed to use, and counts payload reads
-- so a test can prove base bytes are never copied.
---@param members table<string, string> package payloads by logical path
---@param sourceId string
---@return table
local function packageSet(members, sourceId)
  local reads = { payload = 0 }
  local set = { reads = reads }
  function set:resolveAsset(path)
    local bytes = members[path]
    if bytes == nil then
      return nil
    end
    return {
      path = path,
      size = #bytes,
      sourceId = sourceId,
      contentId = sourceId .. "\0" .. path,
      physicalPath = "__package/" .. path,
    }
  end
  function set:paths(prefix)
    local listed = {}
    for path in pairs(members) do
      if path:sub(1, #prefix) == prefix then
        listed[#listed + 1] = path
      end
    end
    table.sort(listed)
    return listed
  end
  function set:readData(reference)
    reads.payload = reads.payload + 1
    local bytes = assert(members[reference.path], "a selected read must name an indexed member")
    return assert(love.data.newByteData(bytes))
  end
  function set:close()
    set.closed = true
  end
  return set
end

-- A selected view overlays one ordered package set on the resident base reader:
-- every read method observes the same winner, an unselected path borrows the
-- base entry unchanged, directory enumeration unions the two layers, and
-- mutations stay forbidden.
function T.selected_overlay_serves_one_winner_and_borrows_base_bytes()
  local store = ResidentCache.new("heartgold", "base:overlay")
  local baseOnly = "data/generated/field/30/scene.lua"
  local replacedLua = "data/generated/field/30/collision.lua"
  local replacedAsset = "assets/generated/field/30/atlas.png"
  local function baseEntry(path, text)
    return {
      path = path,
      data = assert(love.data.newByteData(text)),
      size = #text,
      sourceId = "base:overlay",
      contentId = "overlay\0" .. path,
    }
  end
  store:commit(store:prepare({
    baseEntry(baseOnly, "return { mapId = 30 }"),
    baseEntry(replacedLua, "return { baseCollision = true }"),
    baseEntry(replacedAsset, "BASE-PNG"),
  }))
  local base = CacheFs.fromStore(store)
  local packages = packageSet({
    [replacedLua] = "return { packageCollision = true }",
    [replacedAsset] = "PACKAGE-PNG",
  }, "package:overlay")
  local selected = base:withPackages(packages)
  Assert.isTrue(selected.versionId == base.versionId, "the overlay keeps the selected version")
  Assert.isTrue(selected ~= base, "the overlay is its own read view")
  Assert.isTrue(
    selected:resolveAsset(baseOnly) == base:resolveAsset(baseOnly),
    "an unselected path borrows the base entry itself, never a copy"
  )
  local winner = assert(selected:resolveAsset(replacedAsset), "a selected path resolves to its winner")
  Assert.isNil(winner.data, "the winner is a disk source, not resident bytes")
  Assert.equal(winner.contentId, "package:overlay\0" .. replacedAsset, "the winner keeps its source identity")
  Assert.equal(selected:read(replacedAsset), "PACKAGE-PNG", "a convenience read selects the winner")
  Assert.equal(packages.reads.payload, 1, "selecting the winner reads exactly one package payload")
  Assert.equal(selected:read(baseOnly), "return { mapId = 30 }", "an unselected read stays on the base bytes")
  Assert.equal(packages.reads.payload, 1, "an unselected read never touches the package set")
  Assert.equal(selected:readData(baseOnly):getString(), "return { mapId = 30 }", "borrowed base bytes stay readable")
  Assert.isTrue(selected:exists(replacedAsset, "file"), "a selected entry exists")
  Assert.isTrue(selected:exists(baseOnly, "file"), "a base entry still exists")
  Assert.deepEqual(
    selected:getDirectoryItems("assets/generated/field/30"),
    { "atlas.png" },
    "directory enumeration returns unique direct children across both layers"
  )
  Assert.deepEqual(
    selected:getDirectoryItems("data/generated/field/30"),
    { "collision.lua", "scene.lua" },
    "the union lists both a package winner and a base-only child once"
  )
  Assert.equal(packages.reads.payload, 1, "enumeration reads no payload")
  local collision = assert(selected:loadLua(replacedLua), "a generated Lua member loads through the overlay")
  Assert.isTrue(collision.packageCollision == true, "the loaded member is the package's, not the base's")
  Assert.equal(packages.reads.payload, 2, "loading one selected member reads it once")
  local moduleOk = pcall(function()
    return selected:loadModule(replacedLua)
  end)
  Assert.isTrue(moduleOk or packages.reads.payload == 3, "module loading selects the same winner")

  local mutationOk, mutationError = pcall(function()
    selected:write(replacedLua, "return {}")
  end)
  Assert.isFalse(mutationOk, "a selected view is read-only")
  Assert.isTrue(tostring(mutationError):find("immutable", 1, true) ~= nil, "the refusal names residency")
  packages.closed = true
  packages.resolveAsset = function()
    error("a closed selected view must not consult its package set", 0)
  end
  store:close()
  Assert.isNil(selected:resolveAsset(baseOnly), "a retired base entry is no longer served")
end

return { tests = T }
