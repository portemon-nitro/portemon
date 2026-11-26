-- Owns the original ROM bytes and hides how they were obtained. Only this
-- module, NdsRom, and the compiler pool may hold the full ROM string. The canonical
-- ROM is 128 MiB and kept as one Lua string in v1 (not a byte table); a
-- streaming backend can replace this later without changing callers.
--
-- Infrastructure module: fromPath uses io (arbitrary absolute paths are outside
-- love.filesystem's sandbox) and sha1 uses love.data.hash.

local Errors = require("libs.errors.src.Errors")
local GameVersion = require("romdump.src.source.GameVersion")

---@class RomSource
---@field data string?
---@field name string
---@field private _bytes love.Data?
---@field private _sha1 string?
---@field private _size integer?
---@field _candidatePath string?
---@field _origin { kind: string, path: string|false, zipEntry: string|false, displayName: string }
local RomSource = {}
RomSource.__index = RomSource

local function toHex(bin)
  local out = {}
  for i = 1, #bin do
    out[i] = string.format("%02x", bin:byte(i))
  end
  return table.concat(out)
end

local function basename(path)
  return (path:gsub("\\", "/"):match("([^/]+)$")) or path
end

---@param data string
---@param displayName string?
---@return RomSource
function RomSource.fromString(data, displayName)
  assert(type(data) == "string", "RomSource requires string data")
  local name = displayName or "rom"
  return setmetatable({
    data = data,
    name = name,
    _sha1 = nil,
    _origin = { kind = "nds", path = false, zipEntry = false, displayName = name },
  }, RomSource)
end

-- A borrowed view over one immutable shared buffer. The view never owns the
-- buffer: release() only forgets the reference so peer views keep reading.
-- Callers that need the buffer itself (for channel handoff) use byteData().
---@param byteData love.Data
---@param displayName string?
---@return RomSource
function RomSource.fromByteData(byteData, displayName)
  assert(type(byteData) == "userdata", "RomSource requires shared buffer data")
  ---@cast byteData love.Data
  assert(type(byteData.getSize) == "function", "RomSource requires shared buffer data")
  local name = displayName or "rom"
  return setmetatable({
    _bytes = byteData,
    name = name,
    _sha1 = nil,
    _size = nil,
    _origin = { kind = "nds", path = false, zipEntry = false, displayName = name },
  }, RomSource)
end

local function isZip(name)
  return name:lower():match("%.zip$") ~= nil
end

-- Mount a zip in memory and locate one usable .nds entry. Candidates are
-- inspected one at a time: the first entry whose SHA-1 matches a supported
-- version wins; otherwise the first .nds is returned as a fallback so NdsRom
-- can report a precise unknown-ROM error. At most the current candidate and
-- one fallback candidate are retained at once, and the mount is always
-- unmounted, including when traversal raises.
--
-- love.filesystem.mount accepts FileData (11.0+), so arbitrary-path archives
-- never touch disk.
-- The mount point is exported at this owner boundary (the module that mounts);
-- the test suite references it to observe leaked mounts.
RomSource.MOUNT_POINT = "g4-romzip"

-- A requested or persisted archive member must stay inside the archive: a
-- relative path without absolute/drive prefixes, dot escapes, backslashes,
-- or NULs. Ordinary nesting and case are kept as-is.
local function isSafeZipMember(member)
  if type(member) ~= "string" or #member == 0 then
    return false
  end
  if member:find("\0", 1, true) then
    return false
  end
  if member:find("\\", 1, true) then
    return false
  end
  if member:sub(1, 1) == "/" then
    return false
  end
  if member:match("^[A-Za-z]:") then
    return false
  end
  if member:sub(-1) == "/" or member:find("//", 1, true) then
    return false
  end
  for part in member:gmatch("[^/]+") do
    if part == "." or part == ".." then
      return false
    end
  end
  return true
end

local managedMountSequence = 0

-- Managed opens never overlap for one archive, but each Lua state can open a
-- different archive. The shared clock plus a live-namespace check gives each
-- short mount a process-unique identity.
---@param fs love.filesystem
---@return string
local function nextManagedMountIdentity(fs)
  while true do
    managedMountSequence = managedMountSequence + 1
    local stamp = math.floor(love.timer.getTime() * 1000000)
    local identity = string.format("managed-rom-%d-%d", stamp, managedMountSequence)
    if fs.getInfo(identity) == nil then
      return identity
    end
  end
end

-- Read one exact root member from a physical save-relative archive. Managed
-- archives have the fixed one-member root listing; the compressed file is mounted
-- in place and never copied into a Lua string. The returned Data-backed source
-- outlives the mount, which is released on every path.
---@param relativePath string
---@param exactMember string
---@param snapshot boolean? mount an isolated native Data snapshot instead of the physical archive
---@return RomSource?
---@return Errors.Error?
function RomSource.fromManagedZip(relativePath, exactMember, snapshot)
  if not isSafeZipMember(relativePath) then
    return nil,
      Errors.new(
        "ROM_ARCHIVE_INVALID",
        "managed archive path is not a safe save-relative path",
        { path = tostring(relativePath) }
      )
  end
  if not isSafeZipMember(exactMember) then
    return nil,
      Errors.new(
        "ROM_ARCHIVE_INVALID",
        "managed archive member is unsafe",
        { path = relativePath, entry = tostring(exactMember) }
      )
  end
  local fs = love.filesystem
  local info = fs.getInfo(relativePath)
  if info == nil then
    return nil, Errors.new("ROM_ARCHIVE_INVALID", "managed archive is missing", { path = relativePath })
  end
  if info.type ~= "file" then
    return nil, Errors.new("ROM_ARCHIVE_INVALID", "managed archive is not a file", { path = relativePath })
  end
  local namespace = nextManagedMountIdentity(fs)
  local mountedArchive
  local mountName = relativePath
  local unmountName = relativePath
  local mounted
  local function releaseMount()
    fs.unmount(unmountName)
  end
  if snapshot or not relativePath:lower():match("%.zip$") then
    -- A repair reads one immutable Data snapshot under its own namespace, so
    -- a compiler's physical mount of the same archive remains independent.
    -- PHYSFS also needs a .zip name for checked .zip.new stages.
    local data, readError = fs.read("data", relativePath)
    if data == nil then
      return nil,
        Errors.new("ROM_ARCHIVE_INVALID", "managed archive could not be read", {
          path = relativePath,
          cause = tostring(readError),
        })
    end
    if snapshot then
      mountName = namespace
    else
      mountName = relativePath:lower():match("%.zip$") and relativePath or (relativePath .. ".zip")
    end
    unmountName = snapshot and namespace or mountName
    ---@cast data love.FileData
    mountedArchive = fs.newFileData(data, mountName)
    data:release()
    mounted = fs.mount(mountedArchive, namespace)
  else
    mounted = fs.mount(relativePath, namespace)
  end
  if not mounted then
    releaseMount()
    if mountedArchive then
      mountedArchive:release()
    end
    return nil, Errors.new("ROM_ARCHIVE_INVALID", "managed archive could not be mounted", { path = relativePath })
  end
  local found
  local failure
  local ok, lookupErr = pcall(function()
    local entries = fs.getDirectoryItems(namespace)
    if #entries ~= 1 or entries[1] ~= exactMember then
      failure = Errors.new("ROM_ARCHIVE_INVALID", "managed archive must contain exactly one root member", {
        path = relativePath,
        entries = entries,
      })
      return
    end
    local full = namespace .. "/" .. exactMember
    local memberInfo = fs.getInfo(full)
    if memberInfo == nil then
      failure = Errors.new("ROM_ARCHIVE_INVALID", "managed archive member is missing", {
        path = relativePath,
        entry = exactMember,
      })
      return
    end
    if memberInfo.type ~= "file" then
      failure = Errors.new("ROM_ARCHIVE_INVALID", "managed archive member is not a file", {
        path = relativePath,
        entry = exactMember,
      })
      return
    end
    local data = fs.read("data", full)
    if data == nil then
      failure = Errors.new("ROM_ARCHIVE_INVALID", "managed archive member could not be read", {
        path = relativePath,
        entry = exactMember,
      })
      return
    end
    ---@cast data love.FileData
    found = RomSource.fromByteData(data, basename(relativePath) .. ":" .. exactMember)
    found._origin = {
      kind = "zip",
      path = relativePath,
      zipEntry = exactMember,
      displayName = basename(relativePath),
    }
  end)
  releaseMount()
  if mountedArchive then
    mountedArchive:release()
  end
  if not ok then
    if Errors.is(lookupErr) then
      return nil, lookupErr
    end
    return nil,
      Errors.new("ROM_ARCHIVE_INVALID", "managed archive could not be read", {
        path = relativePath,
        cause = tostring(lookupErr),
      })
  end
  if failure then
    return nil, failure
  end
  return found
end

-- Read exactly one member from an in-memory zip. Missing, non-file, or
-- unreadable members fail without scanning for a replacement, and the mount
-- is always released, including when lookup raises.
local function findExactMember(zipBytes, zipName, exactMember)
  local fd = love.filesystem.newFileData(zipBytes, "romzip.zip")
  love.filesystem.unmount(fd:getFilename()) -- clear any stale mount from a prior import
  if not love.filesystem.mount(fd, RomSource.MOUNT_POINT) then
    return nil, Errors.new("ZIP_MOUNT_FAILED", "could not read zip: " .. zipName, { name = zipName })
  end
  local full = RomSource.MOUNT_POINT .. "/" .. exactMember
  local found
  local failure
  local ok, lookupErr = pcall(function()
    local info = love.filesystem.getInfo(full)
    if not info then
      failure =
        Errors.new("ZIP_ENTRY_MISSING", "archive member not found: " .. full, { name = zipName, entry = exactMember })
      return
    end
    if info.type ~= "file" then
      failure = Errors.new(
        "ZIP_ENTRY_MISSING",
        "archive member is not a file: " .. full,
        { name = zipName, entry = exactMember }
      )
      return
    end
    local bytes = love.filesystem.read(full)
    if not bytes then
      failure = Errors.new("ZIP_READ_FAILED", "could not read .nds entry: " .. full, { name = zipName, entry = full })
      return
    end
    found = RomSource.fromString(bytes, zipName .. ":" .. exactMember)
    found._origin = { kind = "zip", path = false, zipEntry = exactMember, displayName = zipName }
  end)
  love.filesystem.unmount(fd:getFilename())
  if not ok then
    if Errors.is(lookupErr) then
      return nil, lookupErr
    end
    error(lookupErr, 0)
  end
  if failure then
    return nil, failure
  end
  return found
end

local function findNdsCandidate(zipBytes, zipName, versions, exactMember)
  if exactMember ~= nil then
    if not isSafeZipMember(exactMember) then
      return nil,
        Errors.new(
          "ZIP_ENTRY_UNSAFE",
          "unsafe archive member: " .. zipName .. ":" .. tostring(exactMember),
          { name = zipName, entry = tostring(exactMember) }
        )
    end
    return findExactMember(zipBytes, zipName, exactMember)
  end
  local fd = love.filesystem.newFileData(zipBytes, "romzip.zip")
  love.filesystem.unmount(fd:getFilename()) -- clear any stale mount from a prior import
  if not love.filesystem.mount(fd, RomSource.MOUNT_POINT) then
    return nil, Errors.new("ZIP_MOUNT_FAILED", "could not read zip: " .. zipName, { name = zipName })
  end

  local found
  local ok, walkErr = pcall(function()
    local fallback
    local function walk(dir)
      for _, item in ipairs(love.filesystem.getDirectoryItems(dir)) do
        if found then
          return
        end
        local full = dir .. "/" .. item
        local info = love.filesystem.getInfo(full)
        if info and info.type == "directory" then
          walk(full)
        elseif item:lower():match("%.nds$") then
          local bytes = love.filesystem.read(full)
          if not bytes then
            Errors.raise("ZIP_READ_FAILED", "could not read .nds entry: " .. full, { name = zipName, entry = full })
          end
          local member = full:sub(#RomSource.MOUNT_POINT + 2)
          local candidate = RomSource.fromString(bytes, zipName .. ":" .. member)
          candidate._origin = { kind = "zip", path = false, zipEntry = member, displayName = zipName }
          if versions.forSha1(candidate:sha1()) then
            if fallback then
              fallback:release()
            end
            found = candidate
          elseif fallback then
            candidate:release()
          else
            fallback = candidate
          end
        end
      end
    end
    walk(RomSource.MOUNT_POINT)
    found = found or fallback
  end)
  love.filesystem.unmount(fd:getFilename())
  if not ok then
    if Errors.is(walkErr) then
      return nil, walkErr
    end
    error(walkErr, 0)
  end
  return found
end

-- Pick a usable .nds from a zip: prefer one whose SHA-1 matches a supported
-- version; otherwise fall back to the first .nds so NdsRom.open still reports a
-- precise unknown-ROM error (with the computed hash) for diagnosis. With an
-- exact member, open precisely that entry and never substitute another one.
function RomSource.fromZipData(zipBytes, displayName, versions, exactMember)
  versions = versions or GameVersion
  local source, err = findNdsCandidate(zipBytes, displayName, versions, exactMember)
  if not source then
    if err then
      return nil, err
    end
    return nil, Errors.new("ZIP_NO_NDS", "no .nds ROM found in " .. displayName, { name = displayName })
  end
  return source
end

--- Open a ROM from an arbitrary host path. With `{ zipEntry = member }` on a
--- `.zip` path, open exactly that member; the option is invalid elsewhere.
function RomSource.fromPath(path, options)
  local exactMember = options and options.zipEntry or nil
  if exactMember ~= nil and not isZip(path) then
    return nil,
      Errors.new(
        "ROM_INVALID_OPTION",
        "archive member selection needs a .zip path: " .. tostring(path),
        { path = tostring(path) }
      )
  end
  local file, ioErr = io.open(path, "rb")
  if not file then
    return nil, Errors.new("ROM_OPEN_FAILED", ioErr or "could not open file", { path = path })
  end
  local data = file:read("*a")
  file:close()
  if not data then
    return nil, Errors.new("ROM_READ_FAILED", "could not read file", { path = path })
  end
  if isZip(path) then
    local zipped, zipErr = RomSource.fromZipData(data, basename(path), nil, exactMember)
    if zipped then
      zipped._origin.path = path
    end
    return zipped, zipErr
  end
  local source = RomSource.fromString(data, basename(path))
  source._origin.path = path
  return source
end

function RomSource.fromDroppedFile(droppedFile)
  assert(droppedFile, "dropped file is required")
  local ok, openErr = droppedFile:open("r")
  if not ok then
    return nil, Errors.new("ROM_OPEN_FAILED", tostring(openErr), { name = droppedFile:getFilename() })
  end
  local data = droppedFile:read()
  droppedFile:close()
  if not data then
    return nil, Errors.new("ROM_READ_FAILED", "could not read dropped file", { name = droppedFile:getFilename() })
  end
  local name = droppedFile:getFilename()
  local source, zipErr
  if isZip(name) then
    source, zipErr = RomSource.fromZipData(data, basename(name))
  else
    source = RomSource.fromString(data, basename(name))
  end
  if source then
    -- The reported filename is only a candidate reopen location: it stays
    -- private until the importer proves the same canonical bytes there.
    source._candidatePath = name
  end
  return source, zipErr
end

-- The dropped filename as a candidate reopen location, or nil when this
-- source was not dropped. Never a durable location on its own: only a
-- verified candidate may be persisted.
function RomSource:reopenCandidatePath()
  if type(self._candidatePath) == "string" and #self._candidatePath > 0 then
    return self._candidatePath
  end
  return nil
end

local function isNonNegativeInteger(value)
  return type(value) == "number" and value >= 0 and value == math.floor(value) and value < math.huge
end

function RomSource:size()
  if self.data then
    return #self.data
  end
  if self._bytes then
    return self._bytes:getSize()
  end
  return self._size or 0
end

---@return love.Data
function RomSource:byteData()
  if self._bytes then
    return self._bytes
  end
  if self.data then
    Errors.raise("ROM_NOT_SHARED", "string-backed source has no shared buffer", { name = self.name })
  end
  Errors.raise("ROM_RELEASED", "ROM source has been released", {})
  error("unreachable", 0)
end

-- The verified container/member identity behind this view: the exact
-- reopenable filesystem location (or false when the bytes cannot be
-- reopened, as for memory views and dropped files), never inferred from
-- the display label. Returns a fresh table on every call.
function RomSource:origin()
  local source = self._origin or { kind = "nds", path = false, zipEntry = false, displayName = self.name }
  return {
    kind = source.kind,
    path = source.path,
    zipEntry = source.zipEntry,
    displayName = source.displayName,
  }
end

function RomSource:read(offset, length)
  if not self.data and not self._bytes then
    return nil, Errors.new("ROM_RELEASED", "ROM source has been released", {})
  end
  local size = self:size()
  if not isNonNegativeInteger(offset) or not isNonNegativeInteger(length) or offset + length > size then
    return nil,
      Errors.new("ROM_READ_OUT_OF_BOUNDS", "read outside ROM bounds", { offset = offset, length = length, size = size })
  end
  if self.data then
    return string.sub(self.data, offset + 1, offset + length)
  end
  if length == 0 then
    return ""
  end
  -- 11.5 has no ranged Data:getString: view the slice, then read it whole.
  return love.data.newDataView(self._bytes, offset, length):getString()
end

function RomSource:sha1()
  if not self._sha1 then
    local backing = self.data or self._bytes
    assert(backing, "cannot hash a released ROM source")
    self._sha1 = toHex(love.data.hash("sha1", backing))
  end
  return self._sha1
end

function RomSource:displayName()
  return self.name
end

function RomSource:release()
  if self.data then
    self._size = #self.data
  elseif self._bytes and not self._size then
    local size = self._bytes:getSize()
    ---@cast size integer
    self._size = size
  end
  -- Borrowed views only forget their reference: the shared buffer itself is
  -- never released here, so peer views keep reading after one view closes.
  self.data = nil
  self._bytes = nil
end

return RomSource
