-- The selected session's ordered mod packages: the optional
-- `mods/<versionId>/load-order.lua` list, one mounted `ModArchive` per declared
-- basename in low-to-high priority, and the frozen last-wins index every
-- generated asset reader sees. This owner holds metadata and mounts only; it
-- reads no payload at selection, decodes nothing, and never touches the base
-- cache's bytes, completion facts, or files.
--
-- Failure convention: an unreadable or malformed config is MOD_CONFIG_INVALID,
-- a malformed or duplicate-id package is MOD_PACKAGE_INVALID, an identity
-- mismatch is MOD_PACKAGE_INCOMPATIBLE, and a mount that LÖVE refuses is
-- MOD_PACKAGE_MOUNT_FAILED. Any failure unwinds every mount this construction
-- opened before the typed cause escapes, so the App never publishes a partially
-- selected runtime.

local Errors = require("libs.errors.src.Errors")
local ModArchive = require("libs.storage.src.ModArchive")
local ScopedFs = require("libs.storage.src.ScopedFs")
local StorageErrors = require("libs.storage.src.errors")

local CONFIG_FILE = "load-order.lua"
local MAX_CONFIG_BYTES = 64 * 1024
local MAX_PACKAGES = 64
local MAX_BASENAME_BYTES = 128
local BASENAME_PATTERN = "^[A-Za-z0-9][A-Za-z0-9._-]*%.zip$"
local MODS_ROOT = "mods"
local MOUNT_PREFIX = "__portemon_mods"
local pendingRollback = {}

-- The shared confined loader reports its own categories; every unreadable or
-- malformed selection config is one config failure regardless of the stage.
local CONFIG_CODES = {
  FILE_MISSING = StorageErrors.MOD_CONFIG_INVALID,
  READ_FAILED = StorageErrors.MOD_CONFIG_INVALID,
  LUA_PARSE_FAILED = StorageErrors.MOD_CONFIG_INVALID,
  LUA_EVAL_FAILED = StorageErrors.MOD_CONFIG_INVALID,
}

---@class ModPackages.SourceRef
---@field sourceId string selected epoch plus the package that supplies the entry
---@field contentId string the source id plus the logical path
---@field path string logical generated path
---@field size integer declared uncompressed member size
---@field physicalPath string confined mounted member path

---@class ModPackages
---@field versionId string
---@field epoch integer selected runtime epoch these packages belong to
---@field closed boolean
---@field closing boolean
---@field private _winners table<string, ModPackages.SourceRef>
---@field private _owners table<string, ModArchive>
---@field private _archives ModArchive[]
local ModPackages = {}
ModPackages.__index = ModPackages

---@param code string
---@param message string
---@param context Errors.Context?
local function fault(code, message, context)
  Errors.raise(code, message, context)
end

---@param value unknown
---@return boolean
local function isInteger(value)
  return type(value) == "number" and value % 1 == 0
end

-- The observable config path; the user edits this file and nothing else names
-- selection order.
---@param versionId string
---@return string
local function configPath(versionId)
  return MODS_ROOT .. "/" .. versionId .. "/" .. CONFIG_FILE
end

---@param basename unknown
---@return boolean
local function isPackageBasename(basename)
  if type(basename) ~= "string" or #basename < 1 or #basename > MAX_BASENAME_BYTES then
    return false
  end
  if basename:find("[/\\]", 1) ~= nil or basename:find("\0", 1, true) ~= nil then
    return false
  end
  -- The native mount refuses an archive name carrying `..`, so the selection
  -- rejects it as a config failure instead of a later mount failure.
  if basename:find("%.%.") ~= nil then
    return false
  end
  return basename:match(BASENAME_PATTERN) ~= nil
end

-- The optional ordered list: a dense array of unique ZIP basenames declared
-- low-to-high priority, with no extra keys.
---@param value unknown
---@param path string
---@return string[]
local function validateConfig(value, path)
  if type(value) ~= "table" then
    fault(StorageErrors.MOD_CONFIG_INVALID, "the selection config is not a list of package files", { path = path })
  end
  local list = value --[[@as table]]
  local count = 0
  local highest = 0
  for key in pairs(list) do
    if
      not isInteger(key)
      or key --[[@as integer]]
        < 1
    then
      fault(StorageErrors.MOD_CONFIG_INVALID, "the selection config is not an array", {
        path = path,
        field = tostring(key),
      })
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
    fault(StorageErrors.MOD_CONFIG_INVALID, "the selection config is not a dense array", {
      path = path,
      count = count,
    })
  end
  if count > MAX_PACKAGES then
    fault(StorageErrors.MOD_CONFIG_INVALID, "the selection config declares more packages than it may", {
      path = path,
      count = count,
      limit = MAX_PACKAGES,
    })
  end
  local seen = {}
  local basenames = {}
  for index = 1, count do
    local basename = list[index]
    if not isPackageBasename(basename) then
      fault(StorageErrors.MOD_CONFIG_INVALID, "a selected package name is not a safe ZIP basename", {
        path = path,
        package = tostring(basename),
      })
    end
    local name = basename --[[@as string]]
    if seen[name] then
      fault(StorageErrors.MOD_CONFIG_INVALID, "the selection declares one package twice", {
        path = path,
        package = name,
      })
    end
    seen[name] = true
    basenames[index] = name
  end
  return basenames
end

-- A missing config is the base-only game; an existing but unreadable config is
-- an error. The two must stay distinguishable, or a broken selection would look
-- like "no mods".
---@param versionId string
---@return string[]
local function readConfig(versionId)
  local path = configPath(versionId)
  local info = love.filesystem.getInfo(path)
  if info == nil then
    return {}
  end
  if info.type ~= "file" then
    fault(StorageErrors.MOD_CONFIG_INVALID, "the selection config is not a file", { path = path })
  end
  if info.size > MAX_CONFIG_BYTES then
    fault(StorageErrors.MOD_CONFIG_INVALID, "the selection config exceeds its metadata bound", {
      path = path,
      size = info.size,
      limit = MAX_CONFIG_BYTES,
    })
  end
  local filesystem = love.filesystem
  local backend = {
    getInfo = function(_, name)
      if name ~= path then
        return nil
      end
      return filesystem.getInfo(name)
    end,
    read = function(_, name)
      if name ~= path then
        return nil, "selection config outside its version directory"
      end
      return filesystem.read(name)
    end,
  }
  local value, loadErr = ScopedFs.loadChunk(backend, path, path, CONFIG_CODES)
  if value == nil then
    fault(StorageErrors.MOD_CONFIG_INVALID, "the selection config could not be loaded", {
      path = path,
      cause = tostring(loadErr),
    })
  end
  return validateConfig(value, path)
end

-- Unambiguous, length-prefixed source identity: the selected epoch, the
-- package's position and declared id/revision. Two packages, revisions, or
-- epochs can never spell the same token.
---@param token string
---@return string
local function frame(token)
  return tostring(#token) .. ":" .. token
end

---@param epoch integer
---@param ordinal integer
---@param id string
---@param revision string
---@return string
local function encodeSourceId(epoch, ordinal, id, revision)
  return "mod/" .. tostring(epoch) .. "/" .. tostring(ordinal) .. "/" .. frame(id) .. frame(revision)
end

---@param sourceId string
---@param path string
---@return string
local function encodeContentId(sourceId, path)
  return sourceId .. "/" .. frame(path)
end

-- Unwind every mount a failed construction opened, newest first, so a rejected
-- selection leaves no package namespace behind. A cleanup failure is attached
-- to the original cause instead of replacing it.
---@param archives ModArchive[]
---@param cause unknown?
---@return ModArchive[] failed archives, kept dense in selection order
local function rollback(archives, cause)
  local cleanup = nil
  local failed = {}
  for index = #archives, 1, -1 do
    local archive = archives[index]
    local closed, failure = pcall(archive.close, archive)
    if not closed then
      failed[#failed + 1] = archive
      if cleanup == nil then
        cleanup = failure
      end
    end
  end
  local remaining = {}
  for index = #failed, 1, -1 do
    remaining[#remaining + 1] = failed[index]
  end
  if cleanup ~= nil and Errors.is(cause) then
    local errorObject = cause --[[@as Errors.Error]]
    errorObject.context.rollback = tostring(cleanup)
  end
  return remaining
end

---@param archives ModArchive[]
local function retainPending(archives)
  for _, archive in ipairs(archives) do
    local found = false
    for _, pending in ipairs(pendingRollback) do
      if pending == archive then
        found = true
        break
      end
    end
    if not found then
      pendingRollback[#pendingRollback + 1] = archive
    end
  end
end

---@param archives ModArchive[]
local function forgetPending(archives)
  local forgotten = {}
  for _, archive in ipairs(archives) do
    forgotten[archive] = true
  end
  for index = #pendingRollback, 1, -1 do
    if forgotten[pendingRollback[index]] then
      table.remove(pendingRollback, index)
    end
  end
end

-- Mount every declared package in order and build the last-wins winner index.
---@param versionId string
---@param identity ModArchive.Identity
---@param epoch integer
---@param basenames string[]
---@param archives ModArchive[]
---@param winners table<string, ModPackages.SourceRef>
---@param owners table<string, ModArchive>
local function selectPackages(versionId, identity, epoch, basenames, archives, winners, owners)
  local ids = {}
  for ordinal, basename in ipairs(basenames) do
    local archivePath = MODS_ROOT .. "/" .. versionId .. "/" .. basename
    local mountpoint = MOUNT_PREFIX .. "/" .. tostring(epoch) .. "/" .. tostring(ordinal)
    local archive = ModArchive.open(archivePath, mountpoint, identity)
    archives[#archives + 1] = archive
    local manifest = archive:manifest()
    if ids[manifest.id] then
      fault(StorageErrors.MOD_PACKAGE_INVALID, "two selected packages claim the same id", {
        package = basename,
        id = manifest.id,
        archivePath = archivePath,
      })
    end
    ids[manifest.id] = true
    local sourceId = encodeSourceId(epoch, ordinal, manifest.id, manifest.revision)
    owners[sourceId] = archive
    for _, file in ipairs(manifest.files) do
      local entry = assert(archive:entry(file.path), "a validated manifest member has its descriptor")
      winners[file.path] = {
        sourceId = sourceId,
        contentId = encodeContentId(sourceId, file.path),
        path = file.path,
        size = entry.size,
        physicalPath = entry.physicalPath,
      }
    end
  end
end

-- Open the selected session's ordered package set. A missing config is a valid
-- empty selection; every construction failure returns one typed error and
-- leaves no mount behind.
---@param versionId string
---@param identity ModArchive.Identity
---@param epoch integer
---@return ModPackages
function ModPackages.open(versionId, identity, epoch)
  if #pendingRollback > 0 then
    pendingRollback = rollback(pendingRollback, nil)
    assert(#pendingRollback == 0, "a previous mod package mount is still closing")
  end
  ScopedFs.validateVersionId(versionId)
  assert(type(identity) == "table", "a selected package set needs the installed cache identity")
  assert(identity.versionId == versionId, "a selected package set validates the version it selects")
  assert(isInteger(epoch), "a selected package set needs its runtime epoch")
  local basenames = readConfig(versionId)
  local archives = {}
  local winners = {}
  local owners = {}
  local opened, failure = pcall(selectPackages, versionId, identity, epoch, basenames, archives, winners, owners)
  if not opened then
    pendingRollback = rollback(archives, failure)
    error(failure, 0)
  end
  return setmetatable({
    versionId = versionId,
    epoch = epoch,
    closed = false,
    closing = false,
    _winners = winners,
    _owners = owners,
    _archives = archives,
  }, ModPackages)
end

-- Resolve one logical generated path from the frozen winner map. No payload is
-- read, no fallback is searched, and a retired set resolves nothing.
---@param path string
---@return ModPackages.SourceRef?
function ModPackages:resolveAsset(path)
  assert(type(path) == "string", "a selected package path must be a string")
  if self.closed or self.closing then
    return nil
  end
  return self._winners[path]
end

-- Winner paths under a prefix, sorted, each once.
---@param prefix string
---@return string[]
function ModPackages:paths(prefix)
  assert(type(prefix) == "string", "a selected package path prefix must be a string")
  if self.closed or self.closing then
    return {}
  end
  local matched = {}
  for path in pairs(self._winners) do
    if prefix == "" or path:sub(1, #prefix) == prefix then
      matched[#matched + 1] = path
    end
  end
  table.sort(matched)
  return matched
end

-- Immediate exact-winner read for transient callers. The reference must belong
-- to this selection and epoch: a retired or foreign source is refused instead
-- of being served from another package at the same logical path.
---@param reference ModPackages.SourceRef
---@return love.Data
function ModPackages:readData(reference)
  assert(type(reference) == "table", "a selected package read requires its source reference")
  local path = tostring(reference.path)
  if self.closed or self.closing then
    fault(StorageErrors.MOD_ASSET_READ_FAILED, "the selected package set is closed", { path = path })
  end
  local expected = self._winners[reference.path]
  if expected == nil or expected.sourceId ~= reference.sourceId or expected.contentId ~= reference.contentId then
    fault(StorageErrors.MOD_ASSET_READ_FAILED, "the source reference does not belong to this selection", {
      path = path,
      sourceId = tostring(reference.sourceId),
    })
  end
  ---@cast expected -nil
  local archive = assert(self._owners[expected.sourceId], "a selected source keeps its package owner")
  return archive:readData(expected.path)
end

-- Unmount in reverse selection order after the App has drained every reader and
-- lease. A failed unmount is a typed teardown failure that keeps its package for
-- the explicit retry; the set only reports success once every mount is gone.
---@return nil
function ModPackages:close()
  if self.closed then
    return nil
  end
  local failure = nil
  local remaining = {}
  local attempted = self._archives
  self.closing = true
  for index = #self._archives, 1, -1 do
    local archive = self._archives[index]
    local closed, closeFailure = pcall(archive.close, archive)
    if not closed then
      remaining[#remaining + 1] = archive
      if failure == nil then
        failure = closeFailure
      end
    end
  end
  self._archives = {}
  for index = #remaining, 1, -1 do
    self._archives[#self._archives + 1] = remaining[index]
  end
  if failure ~= nil then
    retainPending(self._archives)
    error(failure, 0)
  end
  forgetPending(attempted)
  self.closing = false
  self.closed = true
  self._winners = {}
  self._owners = {}
  self._archives = {}
  return nil
end

return ModPackages
