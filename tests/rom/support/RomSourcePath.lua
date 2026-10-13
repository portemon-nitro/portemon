-- Recovers the host path passed to the test command's `--rom-source <path>`
-- flag for suites that must open a canonical ROM directly through
-- RomSource/NdsRom rather than through the imported derived cache. LOVE
-- preserves the raw process invocation in the global `arg` table, so this
-- reads the exact path the test runner's own Cli.parse already validated,
-- without re-deriving or duplicating that parsing.

local RomSourcePath = {}

-- Open a direct reader over the canonical --rom-source ROM for one version.
-- Returns the reader plus its owning source on success, or nil plus the
-- typed cause: close the reader and release the source when done. The
-- source must outlive the reader; the reader never owns the shared bytes.
---@param versionId string
---@return table? romFs
---@return table|string? sourceOrError owning source on success, cause otherwise
function RomSourcePath.openReader(versionId)
  local path = RomSourcePath.find()
  if path == nil then
    return nil, "this suite needs --rom-source <path>"
  end
  local RomSource = require("romdump.src.source.RomSource")
  local source, sourceErr = RomSource.fromPath(path)
  if source == nil then
    return nil, sourceErr
  end
  local RomFs = require("romdump.src.source.RomFs")
  local fs, fsErr = RomFs.open(versionId, source)
  if fs == nil then
    source:release()
    return nil, fsErr
  end
  return fs, source
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
