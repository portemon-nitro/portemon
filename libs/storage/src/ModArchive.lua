-- One selected mod package: a disk-backed LÖVE mount of an already confined
-- save-relative ZIP under an App-assigned private namespace, the bounded
-- metadata index parsed from its root `mod.lua`, and exact reads of indexed
-- members. Member payloads stay in the archive until a caller asks for one;
-- this owner keeps no byte cache, knows no generated format, and never reads or
-- writes the base cache's completion facts.
--
-- Failure convention: every malformed package, incompatible identity, failed
-- mount, failed unmount, and failed member read is a structured MOD_* error
-- naming the package and the operation. A construction that fails for a known
-- input reason unmounts before the cause escapes, and `close` never reports
-- success while its mount is still live.

local Errors = require("libs.errors.src.Errors")
local ScopedFs = require("libs.storage.src.ScopedFs")
local StorageErrors = require("libs.storage.src.errors")

local SCHEMA = "portemon-mod-v1"
local MANIFEST_PATH = "mod.lua"
local MAX_MANIFEST_BYTES = 4 * 1024 * 1024
local MAX_ENTRIES = 65534
local MAX_MEMBER_BYTES = 0x7fffffff
local MAX_ID_LENGTH = 64
local MAX_REVISION_BYTES = 128
local MOUNT_ROOT = "__portemon_mods/"

-- The shared confined loader reports its own categories; every malformed
-- manifest is a package-invalid selection failure regardless of which stage
-- noticed it.
local MANIFEST_CODES = {
  FILE_MISSING = StorageErrors.MOD_PACKAGE_INVALID,
  READ_FAILED = StorageErrors.MOD_PACKAGE_INVALID,
  LUA_PARSE_FAILED = StorageErrors.MOD_PACKAGE_INVALID,
  LUA_EVAL_FAILED = StorageErrors.MOD_PACKAGE_INVALID,
}

-- The two published roots a package member may live under.
local GENERATED_ROOTS = { "data/generated", "assets/generated" }

-- Base completion facts stay the base snapshot's own: the completion record,
-- the retired per-job receipt tree, and the retired milestone files they
-- replaced are never package members.
local FORBIDDEN_ROOTS = { "data/generated/jobs" }
local FORBIDDEN_FILES = {
  ["data/generated/build.lua"] = true,
  ["data/generated/bootstrap.lua"] = true,
  ["data/generated/new-game-intro.lua"] = true,
  ["data/generated/field-planning.lua"] = true,
  ["data/generated/field-runtime.lua"] = true,
  ["data/generated/startup-title.lua"] = true,
  ["data/generated/startup-audio.lua"] = true,
  ["data/generated/complete.lua"] = true,
  ["data/generated/first-play.lua"] = true,
}

local MANIFEST_KEYS = {
  schema = true,
  id = true,
  revision = true,
  versionId = true,
  assetRevision = true,
  scriptApi = true,
  files = true,
}

---@class ModArchive.Identity
---@field versionId string
---@field assetRevision integer
---@field scriptApi integer

---@class ModArchive.FileRecord
---@field path string
---@field size integer

---@class ModArchive.Manifest
---@field schema string
---@field id string
---@field revision string
---@field versionId string
---@field assetRevision integer
---@field scriptApi integer
---@field files ModArchive.FileRecord[]

---@class ModArchive.Entry
---@field path string
---@field size integer
---@field physicalPath string

---@class ModArchive
---@field archivePath string save-relative selected ZIP this owner mounted
---@field mountpoint string private namespace the archive is mounted at
---@field private _manifest ModArchive.Manifest
---@field private _entries table<string, ModArchive.Entry>
---@field private _mounted boolean
local ModArchive = {}
ModArchive.__index = ModArchive

---@param code string
---@param archivePath string
---@param message string
---@param context Errors.Context?
local function fault(code, archivePath, message, context)
  ---@type Errors.Context
  local fields = { archivePath = archivePath }
  if context ~= nil then
    for key, value in pairs(context) do
      fields[key] = value
    end
  end
  Errors.raise(code, message, fields)
end

---@param archivePath string
---@param message string
---@param context Errors.Context?
local function invalid(archivePath, message, context)
  fault(StorageErrors.MOD_PACKAGE_INVALID, archivePath, message, context)
end

---@param value unknown
---@return boolean
local function isInteger(value)
  return type(value) == "number" and value % 1 == 0
end

-- A package id begins with a letter or digit and stays inside the locked
-- printable token alphabet; it is unique across one selected set.
---@param id unknown
---@return boolean
local function isPackageId(id)
  if type(id) ~= "string" or #id < 1 or #id > MAX_ID_LENGTH then
    return false
  end
  return id:match("^[a-z0-9][a-z0-9._-]*$") ~= nil
end

-- The author's revision marker: printable ASCII without slash, backslash, NUL,
-- or control bytes. It is not a cryptographic proof and is not compared.
---@param revision unknown
---@return boolean
local function isRevision(revision)
  if type(revision) ~= "string" or #revision < 1 or #revision > MAX_REVISION_BYTES then
    return false
  end
  if revision:find("[^ -~]") ~= nil then
    return false
  end
  return revision:find("[/\\]") == nil
end

-- A member path is a normalized forward-slash relative name strictly below one
-- of the two generated roots.
---@param path string
---@return boolean
local function isConfinedMemberPath(path)
  if path == "" or path:sub(1, 1) == "/" or path:match("^%a:") ~= nil then
    return false
  end
  if path:find("\\", 1, true) ~= nil or path:find("\0", 1, true) ~= nil then
    return false
  end
  for component in (path .. "/"):gmatch("(.-)/") do
    if component == "" or component == "." or component == ".." then
      return false
    end
    if component:find("[%z\1-\31\127]") ~= nil then
      return false
    end
  end
  for _, root in ipairs(GENERATED_ROOTS) do
    if path:sub(1, #root + 1) == root .. "/" and #path > #root + 1 then
      return true
    end
  end
  return false
end

---@param path string
---@return boolean
local function isForbiddenMemberPath(path)
  for _, root in ipairs(FORBIDDEN_ROOTS) do
    if path == root or path:sub(1, #root + 1) == root .. "/" then
      return true
    end
  end
  return FORBIDDEN_FILES[path] == true
end

-- The archive path and mount namespace are already confined by the App; this
-- owner asserts their shape instead of re-deriving the selection policy.
---@param archivePath string
local function assertArchivePath(archivePath)
  assert(type(archivePath) == "string" and archivePath ~= "", "a selected package needs its save-relative archive path")
  assert(
    archivePath:sub(1, 1) ~= "/" and archivePath:match("^%a:") == nil,
    "a selected package archive path is save-relative: " .. archivePath
  )
  assert(
    archivePath:find("\\", 1, true) == nil and archivePath:find("\0", 1, true) == nil,
    "a selected package archive path is a normalized forward-slash path: " .. archivePath
  )
  for component in (archivePath .. "/"):gmatch("(.-)/") do
    assert(
      component ~= "" and component ~= "." and component ~= "..",
      "a selected package archive path has an illegal component: " .. archivePath
    )
  end
end

---@param mountpoint string
local function assertMountpoint(mountpoint)
  assert(
    type(mountpoint) == "string" and mountpoint:sub(1, #MOUNT_ROOT) == MOUNT_ROOT and #mountpoint > #MOUNT_ROOT,
    "a selected package mountpoint is a private namespace below " .. MOUNT_ROOT .. ": " .. tostring(mountpoint)
  )
  assert(
    mountpoint:find("\\", 1, true) == nil and mountpoint:find("\0", 1, true) == nil,
    "a selected package mountpoint is a normalized forward-slash path: " .. mountpoint
  )
  for component in (mountpoint .. "/"):gmatch("(.-)/") do
    assert(
      component ~= "" and component ~= "." and component ~= "..",
      "a selected package mountpoint has an illegal component: " .. mountpoint
    )
  end
end

---@param identity ModArchive.Identity
local function assertIdentity(identity)
  assert(type(identity) == "table", "a selected package needs the installed cache identity")
  assert(type(identity.versionId) == "string" and identity.versionId ~= "", "the package identity names its version")
  assert(isInteger(identity.assetRevision), "the package identity names its asset revision")
  assert(isInteger(identity.scriptApi), "the package identity names its script API")
end

---@param mountpoint string
---@return ScopedFs.Backend
local function mountedBackend(mountpoint)
  local filesystem = love.filesystem
  local function mountedGetInfo(_, path)
    if path:sub(1, #mountpoint) ~= mountpoint then
      return nil
    end
    return filesystem.getInfo(path)
  end
  local function mountedRead(_, path)
    if path:sub(1, #mountpoint) ~= mountpoint then
      return nil, "package member outside its mount namespace"
    end
    return filesystem.read(path)
  end
  return { getInfo = mountedGetInfo, read = mountedRead }
end

-- Read and evaluate the bounded root manifest in the empty environment the
-- shared confined loader uses. Only the data record is read back; the mounted
-- namespace is never searched for another manifest.
---@param mountpoint string
---@param archivePath string
---@return unknown
local function readManifest(mountpoint, archivePath)
  local manifestPath = mountpoint .. "/" .. MANIFEST_PATH
  local info = love.filesystem.getInfo(manifestPath)
  if info == nil or info.type ~= "file" then
    invalid(archivePath, "the package has no root manifest", { path = MANIFEST_PATH })
  end
  ---@cast info -nil
  if info.size > MAX_MANIFEST_BYTES then
    invalid(archivePath, "the package manifest exceeds its metadata bound", {
      path = MANIFEST_PATH,
      size = info.size,
      limit = MAX_MANIFEST_BYTES,
    })
  end
  local value, loadErr = ScopedFs.loadChunk(mountedBackend(mountpoint), manifestPath, MANIFEST_PATH, MANIFEST_CODES)
  if value == nil then
    Errors.raise(StorageErrors.MOD_PACKAGE_INVALID, "the package manifest could not be loaded", {
      archivePath = archivePath,
      path = MANIFEST_PATH,
      cause = tostring(loadErr),
    })
  end
  return value
end

---@param files unknown
---@param archivePath string
---@param id string
---@return ModArchive.FileRecord[]
local function validateFiles(files, archivePath, id)
  if type(files) ~= "table" then
    invalid(archivePath, "the package manifest has no file list", { id = id })
  end
  local list = files --[[@as table]]
  local count = 0
  local highest = 0
  for key in pairs(list) do
    if
      not isInteger(key)
      or key --[[@as integer]]
        < 1
    then
      invalid(archivePath, "the package file list is not an array", { id = id, field = tostring(key) })
    end
    count = count + 1
    if
      key --[[@as integer]]
      > highest
    then
      highest = key --[[@as integer]]
    end
  end
  if count ~= highest then
    invalid(archivePath, "the package file list is not dense", { id = id, count = count })
  end
  if count > MAX_ENTRIES then
    invalid(archivePath, "the package declares more members than its metadata bound allows", {
      id = id,
      count = count,
      limit = MAX_ENTRIES,
    })
  end
  local records = {}
  local previous = nil
  for index = 1, count do
    local record = list[index]
    if type(record) ~= "table" then
      invalid(archivePath, "a package file record is not a record", { id = id, index = index })
    end
    local fields = record --[[@as table<string, unknown>]]
    for key in pairs(fields) do
      if key ~= "path" and key ~= "size" then
        invalid(archivePath, "a package file record carries an unexpected field", { id = id, field = tostring(key) })
      end
    end
    local path = fields.path
    local size = fields.size
    if type(path) ~= "string" then
      invalid(archivePath, "a package file record has no path", { id = id, index = index })
    end
    local memberPath = path --[[@as string]]
    if not isConfinedMemberPath(memberPath) then
      invalid(archivePath, "a package member path is outside the generated roots", { id = id, path = memberPath })
    end
    if isForbiddenMemberPath(memberPath) then
      invalid(archivePath, "a package member path belongs to the base completion facts", { id = id, path = memberPath })
    end
    if
      not isInteger(size)
      or size --[[@as integer]]
        < 0
      or size --[[@as integer]]
        > MAX_MEMBER_BYTES
    then
      invalid(archivePath, "a package member size is outside its domain", {
        id = id,
        path = memberPath,
        size = tostring(size),
      })
    end
    if previous ~= nil and not (previous < memberPath) then
      invalid(archivePath, "the package file list is not sorted and unique", { id = id, path = memberPath })
    end
    previous = memberPath
    records[index] = {
      path = memberPath,
      size = size --[[@as integer]],
    }
  end
  return records
end

-- Validate the exact manifest record against the installed identity. Only the
-- runtime contract fields are compared: these packages target source-
-- independent generated formats, not a producer build or a source path.
---@param value unknown
---@param identity ModArchive.Identity
---@param archivePath string
---@return ModArchive.Manifest
local function validateManifest(value, identity, archivePath)
  if type(value) ~= "table" then
    invalid(archivePath, "the package manifest is not a record")
  end
  local record = value --[[@as table<string, unknown>]]
  for key in pairs(record) do
    if not MANIFEST_KEYS[key] then
      invalid(archivePath, "the package manifest carries an unexpected field", { field = tostring(key) })
    end
  end
  for key in pairs(MANIFEST_KEYS) do
    if record[key] == nil then
      invalid(archivePath, "the package manifest is missing a required field", { field = key })
    end
  end
  if record.schema ~= SCHEMA then
    invalid(archivePath, "the package manifest schema is unsupported", { schema = tostring(record.schema) })
  end
  -- Identity compatibility is reported before the lexical package token: a
  -- package built for another installed runtime contract is the failure the
  -- user has to act on, and the supplied id stays in the failure context.
  local id = tostring(record.id)
  if record.versionId ~= identity.versionId then
    fault(StorageErrors.MOD_PACKAGE_INCOMPATIBLE, archivePath, "the package targets another game version", {
      id = id,
      field = "versionId",
      expected = identity.versionId,
      supplied = tostring(record.versionId),
    })
  end
  if record.assetRevision ~= identity.assetRevision then
    fault(StorageErrors.MOD_PACKAGE_INCOMPATIBLE, archivePath, "the package targets another asset revision", {
      id = id,
      field = "assetRevision",
      expected = identity.assetRevision,
      supplied = tostring(record.assetRevision),
    })
  end
  if record.scriptApi ~= identity.scriptApi then
    fault(StorageErrors.MOD_PACKAGE_INCOMPATIBLE, archivePath, "the package targets another script API", {
      id = id,
      field = "scriptApi",
      expected = identity.scriptApi,
      supplied = tostring(record.scriptApi),
    })
  end
  if not isPackageId(record.id) then
    invalid(archivePath, "the package id is not a valid token", { id = id })
  end
  if not isRevision(record.revision) then
    invalid(archivePath, "the package revision is not a valid token", { id = id })
  end
  return {
    schema = SCHEMA,
    id = id,
    revision = record.revision --[[@as string]],
    versionId = identity.versionId,
    assetRevision = identity.assetRevision,
    scriptApi = identity.scriptApi,
    files = validateFiles(record.files, archivePath, id),
  }
end

-- Every declared member must be an ordinary mounted file whose uncompressed
-- size agrees with the manifest. Nothing is opened or decompressed: this is
-- metadata agreement, not a payload read.
---@param manifest ModArchive.Manifest
---@param mountpoint string
---@param archivePath string
local function assertMembersPresent(manifest, mountpoint, archivePath)
  for _, file in ipairs(manifest.files) do
    local info = love.filesystem.getInfo(mountpoint .. "/" .. file.path)
    if info == nil or info.type ~= "file" then
      invalid(archivePath, "the package archive does not carry a declared member", {
        id = manifest.id,
        path = file.path,
      })
    end
    ---@cast info -nil
    if info.size ~= file.size then
      invalid(archivePath, "a declared member size contradicts the archive", {
        id = manifest.id,
        path = file.path,
        declared = file.size,
        actual = info.size,
      })
    end
  end
end

---@param manifest ModArchive.Manifest
---@param mountpoint string
---@return table<string, ModArchive.Entry>
local function indexEntries(manifest, mountpoint)
  local entries = {}
  for _, file in ipairs(manifest.files) do
    entries[file.path] = {
      path = file.path,
      size = file.size,
      physicalPath = mountpoint .. "/" .. file.path,
    }
  end
  return entries
end

---@param archivePath string
---@param mountpoint string
---@param identity ModArchive.Identity
---@return ModArchive
local function build(archivePath, mountpoint, identity)
  local manifest = validateManifest(readManifest(mountpoint, archivePath), identity, archivePath)
  assertMembersPresent(manifest, mountpoint, archivePath)
  return setmetatable({
    archivePath = archivePath,
    mountpoint = mountpoint,
    _manifest = manifest,
    _entries = indexEntries(manifest, mountpoint),
    _mounted = true,
  }, ModArchive)
end

-- Mount one selected package by its save-relative filename and return its
-- validated metadata index. Any failed construction unmounts before the cause
-- escapes, so a rejected package leaves no namespace behind.
---@param archivePath string
---@param mountpoint string
---@param identity ModArchive.Identity
---@return ModArchive
function ModArchive.open(archivePath, mountpoint, identity)
  assertArchivePath(archivePath)
  assertMountpoint(mountpoint)
  assertIdentity(identity)
  local mounted, result = pcall(love.filesystem.mount, archivePath, mountpoint)
  if not mounted or result ~= true then
    fault(StorageErrors.MOD_PACKAGE_MOUNT_FAILED, archivePath, "the selected package could not be mounted", {
      mountpoint = mountpoint,
      cause = tostring(result),
    })
  end
  local built, archive = pcall(build, archivePath, mountpoint, identity)
  if built then
    return archive --[[@as ModArchive]]
  end
  pcall(love.filesystem.unmount, archivePath)
  error(archive, 0)
end

-- A defensive copy of the validated metadata. Callers may read it freely; the
-- owner keeps the authoritative record, and no member payload is returned.
---@return ModArchive.Manifest
function ModArchive:manifest()
  local source = self._manifest
  local files = {}
  for index, file in ipairs(source.files) do
    files[index] = { path = file.path, size = file.size }
  end
  return {
    schema = source.schema,
    id = source.id,
    revision = source.revision,
    versionId = source.versionId,
    assetRevision = source.assetRevision,
    scriptApi = source.scriptApi,
    files = files,
  }
end

-- One indexed member descriptor, or nil for a member the manifest never
-- listed. An extra archive member stays inaccessible.
---@param path string
---@return ModArchive.Entry?
function ModArchive:entry(path)
  assert(type(path) == "string", "a package member path must be a string")
  return self._entries[path]
end

-- Every indexed logical name under a prefix, sorted, from manifest metadata
-- alone.
---@param prefix string
---@return string[]
function ModArchive:paths(prefix)
  assert(type(prefix) == "string", "a package path prefix must be a string")
  local matched = {}
  for path in pairs(self._entries) do
    if prefix == "" or path:sub(1, #prefix) == prefix then
      matched[#matched + 1] = path
    end
  end
  table.sort(matched)
  return matched
end

-- Read exactly one indexed member through LÖVE's Data-returning API. The
-- actual uncompressed size must agree with the manifest; a member absent from
-- the index is never read, and a closed owner performs no I/O.
---@param path string
---@return love.Data
function ModArchive:readData(path)
  if not self._mounted then
    fault(StorageErrors.MOD_ASSET_READ_FAILED, self.archivePath, "the selected package is no longer mounted", {
      path = tostring(path),
    })
  end
  local entry = type(path) == "string" and self._entries[path] or nil
  if entry == nil then
    fault(StorageErrors.MOD_ASSET_READ_FAILED, self.archivePath, "the package holds no such member", {
      path = tostring(path),
    })
  end
  ---@cast entry -nil
  local data, readErr = love.filesystem.read("data", entry.physicalPath)
  if data == nil then
    fault(StorageErrors.MOD_ASSET_READ_FAILED, self.archivePath, "the selected member could not be read", {
      path = entry.path,
      cause = tostring(readErr),
    })
  end
  ---@cast data love.FileData
  local size = data:getSize()
  if size ~= entry.size then
    fault(StorageErrors.MOD_ASSET_READ_FAILED, self.archivePath, "the selected member size contradicts its manifest", {
      path = entry.path,
      declared = entry.size,
      actual = size,
    })
  end
  return data
end

-- Unmount this package after every reader and lease is gone. Idempotent after
-- a successful unmount; a failed unmount is a typed teardown failure that keeps
-- the owner live for the explicit retry.
---@return nil
function ModArchive:close()
  if not self._mounted then
    return nil
  end
  local unmounted, result = pcall(love.filesystem.unmount, self.archivePath)
  if not unmounted or result ~= true then
    fault(StorageErrors.MOD_PACKAGE_UNMOUNT_FAILED, self.archivePath, "the selected package could not be unmounted", {
      mountpoint = self.mountpoint,
      cause = tostring(result),
    })
  end
  self._mounted = false
  return nil
end

return ModArchive
