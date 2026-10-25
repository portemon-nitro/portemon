-- Recovers the host path passed to the test command's `--rom-source <path>`
-- flag for suites that must open a canonical ROM directly through
-- RomSource/NdsRom rather than through the imported derived cache. LOVE
-- preserves the raw process invocation in the global `arg` table, so this
-- reads the exact path the test runner's own Cli.parse already validated,
-- without re-deriving or duplicating that parsing. When the flag is absent,
-- a seeded plain run reopens the previously registered exact original
-- path/member for the requested version instead.

local RomSourcePath = {}

-- Opens one validated source and its direct reader, checking the source's
-- canonical identity before the reader ever opens. The caller owns both on
-- success; every failure releases an opened source exactly once.
---@param versionId string
---@param canonicalSha1 string
---@param path string
---@param options table|nil
---@return table? romFs
---@return table|string? sourceOrError owning source on success, cause otherwise
local function openValidated(versionId, canonicalSha1, path, options)
  local RomSource = require("romdump.src.source.RomSource")
  local source, sourceErr = RomSource.fromPath(path, options)
  if source == nil then
    return nil, sourceErr
  end
  local actualSha1 = source:sha1()
  if actualSha1 ~= canonicalSha1 then
    source:release()
    local Errors = require("libs.errors.src.Errors")
    return nil,
      Errors.new(
        "ROM_SOURCE_MISMATCH",
        "source for version " .. versionId .. " does not match the canonical cartridge",
        { versionId = versionId, sha1 = actualSha1 }
      )
  end
  local RomFs = require("romdump.src.source.RomFs")
  local fs, fsErr = RomFs.open(versionId, source)
  if fs == nil then
    source:release()
    return nil, fsErr
  end
  return fs, source
end

-- Open a direct reader over the canonical --rom-source ROM for one version.
-- Returns the reader plus its owning source on success, or nil plus the
-- typed cause: close the reader and release the source when done. The
-- source must outlive the reader; the reader never owns the shared bytes.
---@param versionId string
---@return table? romFs
---@return table|string? sourceOrError owning source on success, cause otherwise
function RomSourcePath.openReader(versionId)
  local GameVersion = require("romdump.src.source.GameVersion")
  local info = GameVersion.info(versionId)
  if info == nil or type(info.sha1) ~= "string" then
    local Errors = require("libs.errors.src.Errors")
    return nil, Errors.new("ROM_SOURCE_MISMATCH", "no known version " .. tostring(versionId), { versionId = versionId })
  end
  local explicit = RomSourcePath.find()
  if explicit ~= nil then
    return openValidated(versionId, info.sha1, explicit, nil)
  end
  local CacheFs = require("libs.storage.src.CacheFs")
  local RomBinding = require("romdump.src.source.RomBinding")
  local binding, bindingErr = RomBinding.read(CacheFs.forVersion(versionId), versionId)
  if binding == nil then
    return nil, bindingErr
  end
  if binding.path == false then
    local Errors = require("libs.errors.src.Errors")
    return nil,
      Errors.new(
        "ROM_SOURCE_REQUIRED",
        "no reopenable source registered for version " .. versionId,
        { versionId = versionId }
      )
  end
  local options = nil
  if binding.kind == "zip" then
    options = { zipEntry = binding.zipEntry }
  end
  return openValidated(versionId, info.sha1, binding.path, options)
end

---@return string|nil
function RomSourcePath.find()
  local raw = _G.arg
  if type(raw) ~= "table" then
    return nil
  end
  for i = 1, #raw do
    if raw[i] == "--rom-source" then
      return raw[i + 1]
    end
  end
  return nil
end

return RomSourcePath
