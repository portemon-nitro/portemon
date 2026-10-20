-- Persists the last edition that successfully entered the game.

local GameVersion = require("romdump.src.source.GameVersion")

local EditionPreference = {}
local FILE_NAME = "app-edition.lua"
local CONTENT_PATTERN = '^return { schema = 1, versionId = "([%a]+)" }\n?$'
local replaceFile

function EditionPreference.read()
  local content = love.filesystem.read(FILE_NAME)
  if type(content) ~= "string" then
    return nil
  end
  local versionId = content:match(CONTENT_PATTERN)
  if versionId == nil or GameVersion.VERSIONS[versionId] == nil then
    return nil
  end
  return versionId
end

function EditionPreference.recordPlayed(versionId)
  if type(versionId) ~= "string" or GameVersion.VERSIONS[versionId] == nil then
    return false, "unknown game version"
  end

  local directory = love.filesystem.getSaveDirectory()
  local destination = directory .. "/" .. FILE_NAME
  local staging = destination .. ".tmp"
  local file, openError = io.open(staging, "wb")
  if not file then
    return false, openError
  end

  local content = string.format('return { schema = 1, versionId = "%s" }\n', versionId)
  local wrote, writeError = file:write(content)
  local closed, closeError = file:close()
  if not wrote or not closed then
    os.remove(staging)
    return false, writeError or closeError or "could not write edition preference"
  end

  local renamed, renameError = replaceFile(staging, destination)
  if not renamed then
    os.remove(staging)
    return false, renameError or "could not replace edition preference"
  end
  return true
end

replaceFile = function(staging, destination)
  if love.system.getOS() ~= "Windows" then
    return os.rename(staging, destination)
  end

  local ffi = require("ffi")
  pcall(
    ffi.cdef,
    [[
    typedef unsigned short PortemonWideChar;
    int __stdcall MultiByteToWideChar(unsigned int codePage, unsigned long flags,
      const char *input, int inputLength, PortemonWideChar *output, int outputLength);
    int __stdcall MoveFileExW(const PortemonWideChar *existingPath,
      const PortemonWideChar *newPath, unsigned long flags);
  ]]
  )
  local kernelLoaded, kernel = pcall(ffi.load, "kernel32")
  if not kernelLoaded then
    return false, "Windows atomic replace is unavailable"
  end

  local function toWide(path)
    local length = kernel.MultiByteToWideChar(65001, 0, path, -1, nil, 0)
    if length == 0 then
      return nil
    end
    local buffer = ffi.new("PortemonWideChar[?]", length)
    if kernel.MultiByteToWideChar(65001, 0, path, -1, buffer, length) == 0 then
      return nil
    end
    return buffer
  end

  local wideStaging, wideDestination = toWide(staging), toWide(destination)
  if wideStaging == nil or wideDestination == nil then
    return false, "Could not encode the edition preference path"
  end
  if kernel.MoveFileExW(wideStaging, wideDestination, 0x1 + 0x8) == 0 then
    return false, "Could not atomically replace the edition preference"
  end
  return true
end

return EditionPreference
