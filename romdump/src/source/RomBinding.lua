-- The sole owner of one version's persisted source location and identity. It
-- stores only metadata about a user-owned cartridge (never ROM bytes) under
-- `<versionId>/rom-source.lua` through the version cache: a strict seven-key
-- record with an explicit false wherever no durable location or archive
-- member exists. record() replaces the registration atomically only after the
-- cartridge has been verified; a failed validation or a failed rename leaves
-- the previous registration and every derived file untouched. read() never
-- opens the ROM; it only reports the persisted registration.

local Errors = require("libs.errors.src.Errors")
local GameVersion = require("romdump.src.source.GameVersion")
local StorageErrors = require("libs.storage.src.errors")

local RomBinding = {}

RomBinding.PATH = "rom-source.lua"

-- Staging sibling for the atomic stage-then-rename publication. Public so
-- the background import worker's decided binding can be published through
-- the configured cache with the same atomicity without revalidating.
RomBinding.STAGE_PATH = "rom-source.lua.new"

local STAGE_PATH = RomBinding.STAGE_PATH

local EXPECTED_KEYS = {
  schema = true,
  versionId = true,
  romSha1 = true,
  kind = true,
  path = true,
  displayName = true,
  zipEntry = true,
}

local function isNonEmptyString(value)
  return type(value) == "string" and #value > 0
end

-- Archive members stay inside the archive: a relative path without
-- absolute/drive prefixes, dot escapes, backslashes, or NULs. Ordinary
-- nesting and case are kept as-is.
local function isSafeZipEntry(value)
  if type(value) ~= "string" or #value == 0 then
    return false
  end
  if value:find("\0", 1, true) then
    return false
  end
  if value:find("\\", 1, true) then
    return false
  end
  if value:sub(1, 1) == "/" then
    return false
  end
  if value:match("^[A-Za-z]:") then
    return false
  end
  if value:sub(-1) == "/" or value:find("//", 1, true) then
    return false
  end
  for part in value:gmatch("[^/]+") do
    if part == "." or part == ".." then
      return false
    end
  end
  return true
end

local function mismatch(message, context)
  return Errors.new("ROM_BINDING_MISMATCH", message, context)
end

local function corrupt(message, context)
  return Errors.new("ROM_BINDING_CORRUPT", message, context)
end

-- Strict shape check shared by record (before staging) and read: exact keys,
-- exact types, and container/member cross-rules. Identity against the version
-- catalog is checked separately so a shape failure is always corruption.
local function checkShape(binding)
  if type(binding) ~= "table" then
    return corrupt("source registration must be a table", {})
  end
  local count = 0
  for key in pairs(binding) do
    if not EXPECTED_KEYS[key] then
      return corrupt("source registration has an unexpected key", { key = tostring(key) })
    end
    count = count + 1
  end
  if count ~= 7 then
    return corrupt("source registration must carry exactly seven keys", {})
  end
  if binding.schema ~= 1 then
    return corrupt("source registration schema must be 1", { schema = binding.schema })
  end
  if type(binding.versionId) ~= "string" or #binding.versionId == 0 then
    return corrupt("source registration versionId must be a nonempty string", {})
  end
  if type(binding.romSha1) ~= "string" or #binding.romSha1 ~= 40 or not binding.romSha1:match("^[0-9a-f]+$") then
    return corrupt("source registration identity must be lowercase 40-hex", {})
  end
  if binding.kind ~= "nds" and binding.kind ~= "zip" then
    return corrupt("source registration kind must be nds or zip", { kind = binding.kind })
  end
  if binding.path ~= false and not isNonEmptyString(binding.path) then
    return corrupt("source registration path must be a nonempty string or false", {})
  end
  if not isNonEmptyString(binding.displayName) then
    return corrupt("source registration displayName must be a nonempty string", {})
  end
  if binding.zipEntry ~= false and not isNonEmptyString(binding.zipEntry) then
    return corrupt("source registration zipEntry must be a nonempty string or false", {})
  end
  if binding.kind == "nds" and binding.zipEntry ~= false then
    return corrupt("a bare cartridge registration has no archive member", {})
  end
  if binding.kind == "zip" and type(binding.zipEntry) ~= "string" then
    return corrupt("an archive registration must name its selected member", {})
  end
  if binding.kind == "zip" and not isSafeZipEntry(binding.zipEntry) then
    return corrupt("source registration archive member must be a safe relative path", { zipEntry = binding.zipEntry })
  end
  return nil
end

local function checkDescriptor(descriptor)
  if type(descriptor) ~= "table" then
    return mismatch("source descriptor must be a table", {})
  end
  local shapeErr = checkShape({
    schema = 1,
    versionId = "?",
    romSha1 = string.rep("0", 40),
    kind = descriptor.kind,
    path = descriptor.path,
    displayName = descriptor.displayName,
    zipEntry = descriptor.zipEntry,
  })
  if shapeErr then
    return mismatch("invalid source descriptor: " .. shapeErr.message, shapeErr.context)
  end
  return nil
end

-- The version catalog is injectable so validation and registration agree on
-- exactly the catalog the cartridge was verified against; production passes
-- the shared GameVersion table by default.
local function catalogEntry(versions, versionId)
  if type(versions) == "table" and type(versions.VERSIONS) == "table" then
    return versions.VERSIONS[versionId]
  end
  if type(versions) == "table" and type(versions.info) == "function" then
    local ok, info = pcall(versions.info, versionId)
    if ok and type(info) == "table" then
      return info
    end
    return nil
  end
  return nil
end

local function checkIdentity(versionId, romSha1, versions)
  local canonical = catalogEntry(versions or GameVersion, versionId)
  if not canonical then
    return mismatch("no known version for source registration", { versionId = versionId })
  end
  if type(canonical.sha1) ~= "string" or canonical.sha1:lower() ~= romSha1 then
    return mismatch("source identity does not match the registered version", { versionId = versionId })
  end
  return nil
end

-- Validate and atomically persist the location of an already-verified
-- cartridge. descriptor is {kind, path, displayName, zipEntry} as reported by
-- the accepted source; path is false for bytes that cannot be reopened.
-- versions optionally names the catalog the cartridge was verified against
-- (it must expose either VERSIONS or info); it defaults to GameVersion.
-- Returns true; on any validation or persistence failure returns nil plus a
-- typed error without touching the previous registration.
function RomBinding.record(cache, validatedRom, descriptor, versions)
  assert(cache and validatedRom, "record requires a version cache and a verified cartridge")
  local versionInfo = validatedRom.versionInfo and validatedRom:versionInfo() or nil
  if type(versionInfo) ~= "table" or type(versionInfo.id) ~= "string" or type(versionInfo.sha1) ~= "string" then
    return nil, mismatch("verified cartridge has no usable version identity", {})
  end
  if cache.versionId ~= versionInfo.id then
    return nil,
      mismatch("cartridge version does not match the version cache", {
        versionId = versionInfo.id,
        cacheVersion = cache.versionId,
      })
  end
  local descriptorErr = checkDescriptor(descriptor)
  if descriptorErr then
    return nil, descriptorErr
  end
  local romSha1 = versionInfo.sha1:lower()
  local identityErr = checkIdentity(versionInfo.id, romSha1, versions)
  if identityErr then
    return nil, identityErr
  end
  local binding = {
    schema = 1,
    versionId = versionInfo.id,
    romSha1 = romSha1,
    kind = descriptor.kind,
    path = descriptor.path,
    displayName = descriptor.displayName,
    zipEntry = descriptor.zipEntry,
  }
  local shapeErr = checkShape(binding)
  if shapeErr then
    return nil, shapeErr
  end
  -- Stage beside the live record, then rename over it: a failed write or a
  -- failed rename keeps the previous registration intact.
  local ok, err = pcall(function()
    cache:writeLua(STAGE_PATH, binding)
    cache:replace(STAGE_PATH, RomBinding.PATH)
  end)
  if not ok then
    if Errors.is(err) then
      return nil, err
    end
    error(err, 0)
  end
  return true
end

-- Report the persisted registration without opening the ROM. Missing or
-- unreadable records are source-required (the caller must ask for a source);
-- truncated or misshapen records are corruption; an identity the catalog no
-- longer recognizes is a mismatch. All three are typed and distinct.
-- versions optionally names the catalog the registration is checked against;
-- it defaults to GameVersion.
function RomBinding.read(cache, versionId, versions)
  assert(cache and type(versionId) == "string", "read requires a version cache and a version id")
  local binding, err = cache:loadLua(RomBinding.PATH)
  if binding == nil then
    if err and (err.code == StorageErrors.CACHE_READ_FAILED or err.code == StorageErrors.CACHE_FILE_MISSING) then
      return nil,
        Errors.new("ROM_SOURCE_REQUIRED", "no source registered for version " .. versionId, {
          versionId = versionId,
        })
    end
    if err then
      return nil, corrupt("source registration could not be decoded: " .. err.message, { versionId = versionId })
    end
    return nil, corrupt("source registration decoded to nothing", { versionId = versionId })
  end
  local shapeErr = checkShape(binding)
  if shapeErr then
    return nil, shapeErr
  end
  assert(binding)
  if binding.versionId ~= versionId then
    return nil,
      mismatch("source registration names another version", {
        versionId = versionId,
        recordVersion = binding.versionId,
      })
  end
  local identityErr = checkIdentity(versionId, binding.romSha1, versions)
  if identityErr then
    return nil, identityErr
  end
  return binding
end

return RomBinding
