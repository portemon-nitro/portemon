-- Persistent verified ROM source archives. This owner writes one fixed member,
-- checks the closed stage by reopening it, and rotates canonical/backup files
-- without ever treating an unpublished stage as installed evidence.

local BinaryView = require("libs.codec.src.BinaryView")
local Cartridge = require("libs.nds.src.rom.Cartridge")
local Errors = require("libs.errors.src.Errors")
local GameVersion = require("romdump.src.source.GameVersion")
local NdsRom = require("romdump.src.source.NdsRom")
local RomSource = require("romdump.src.source.RomSource")
local Zip32 = require("libs.codec.src.Zip32")

local RomArchive = {}

local MEMBER = "game.nds"
local ROOT = "roms"
local CANONICAL_SUFFIX = ".zip"
local ICON_SUFFIX = ".png"
local STAGE_SUFFIX = ".new"
local BACKUP_SUFFIX = ".bak"

local MAX_RECORD_BYTES = 0xFFFFFFFF

local ARCHIVE_CODES = {
  WRITE_FAILED = "ROM_ARCHIVE_WRITE_FAILED",
  INVALID = "ROM_ARCHIVE_INVALID",
  PUBLISH_FAILED = "ROM_ARCHIVE_PUBLISH_FAILED",
  ICON_INVALID = "ROM_ICON_INVALID",
  ICON_PUBLISH_FAILED = "ROM_ICON_PUBLISH_FAILED",
  SOURCE_REQUIRED = "ROM_SOURCE_REQUIRED",
}

---@class RomArchive.Prepared
---@field romSha1 string
---@field canonical string
---@field stage string
---@field backup string
---@field consumed boolean

local function archiveFailure(code, message, context)
  return Errors.new(code, message, context or {})
end

---@param romSha1 string
---@param suffix string
---@return string
local function managedPath(romSha1, suffix)
  assert(
    type(romSha1) == "string" and romSha1:match("^[0-9a-f]+$") ~= nil and #romSha1 == 40,
    "managed ROM identity must be lowercase 40-hex"
  )
  return ROOT .. "/" .. romSha1 .. suffix
end

---@param romSha1 string
---@return string
function RomArchive.path(romSha1)
  return managedPath(romSha1, CANONICAL_SUFFIX)
end

---@param romSha1 string
---@return string
function RomArchive.iconPath(romSha1)
  return managedPath(romSha1, ICON_SUFFIX)
end

---@param romSha1 string
---@return string? path
function RomArchive.recoverablePath(romSha1)
  local canonical = RomArchive.path(romSha1)
  if love.filesystem.getInfo(canonical, "file") ~= nil then
    return canonical
  end
  local backup = canonical .. BACKUP_SUFFIX
  if love.filesystem.getInfo(backup, "file") ~= nil then
    return backup
  end
  return nil
end

---@param romSha1 string
---@return RomSource?
---@return Errors.Error?
function RomArchive.open(romSha1)
  local path = RomArchive.recoverablePath(romSha1)
  if path == nil then
    return nil,
      archiveFailure(ARCHIVE_CODES.SOURCE_REQUIRED, "no managed ROM archive is present", { romSha1 = romSha1 })
  end
  return RomSource.fromManagedZip(path, MEMBER)
end

local function exists(path)
  return love.filesystem.getInfo(path) ~= nil
end

local function removeOwned(path)
  if not exists(path) then
    return true
  end
  return love.filesystem.remove(path) == true
end

---@param source string
---@param destination string
---@return boolean
---@return string?
local function renameOwned(source, destination)
  local root = love.filesystem.getSaveDirectory()
  local ok, moved, message = pcall(os.rename, root .. "/" .. source, root .. "/" .. destination)
  if not ok then
    return false, tostring(moved)
  end
  return moved == true, message
end

---@param prepared { stage: string }
---@param parts (string|love.Data)[]
---@return Errors.Error?
local function writeStage(prepared, parts)
  local handle, openError = love.filesystem.newFile(prepared.stage, "w")
  if handle == nil then
    return archiveFailure(ARCHIVE_CODES.WRITE_FAILED, "managed ROM archive could not be opened", {
      path = prepared.stage,
      cause = tostring(openError),
    })
  end
  local ok, failure = pcall(function()
    for _, bytes in ipairs(parts) do
      local length
      if type(bytes) == "string" then
        length = #bytes
      else
        local data = bytes --[[@as love.Data]]
        length = data:getSize()
      end
      local written, message = handle:write(bytes, length)
      if not written then
        Errors.raise(ARCHIVE_CODES.WRITE_FAILED, "managed ROM archive write failed", {
          path = prepared.stage,
          cause = tostring(message),
        })
      end
    end
  end)
  local closed, closeError = handle:close()
  if not closed then
    return archiveFailure(ARCHIVE_CODES.WRITE_FAILED, "managed ROM archive could not be closed", {
      path = prepared.stage,
      cause = tostring(closeError),
    })
  end
  if not ok then
    return Errors.is(failure) and failure
      or archiveFailure(ARCHIVE_CODES.WRITE_FAILED, "managed ROM archive write failed", {
        path = prepared.stage,
        cause = tostring(failure),
      })
  end
  return nil
end

---@param rgbaBytes string
---@return love.FileData?
---@return Errors.Error?
local function encodeRgba(rgbaBytes)
  assert(type(rgbaBytes) == "string" and #rgbaBytes == 4096, "static banner must be 32x32 RGBA")
  local byteData = love.data.newByteData(rgbaBytes)
  local image
  local ok, result = pcall(function()
    -- LÖVE 11.5 accepts ByteData here; the vendored overload declares string.
    local imageDataBytes = byteData --[[@as string]]
    image = love.image.newImageData(32, 32, "rgba8", imageDataBytes)
    return image:encode("png")
  end)
  byteData:release()
  if image then
    image:release()
  end
  if not ok then
    return nil,
      archiveFailure(ARCHIVE_CODES.ICON_INVALID, "static banner could not be encoded", {
        cause = tostring(result),
      })
  end
  if type(result) ~= "userdata" then
    return nil, archiveFailure(ARCHIVE_CODES.ICON_INVALID, "static banner encoder returned no PNG data", {})
  end
  ---@cast result love.FileData
  return result
end

---@param byteData love.Data already verified import bytes
---@return love.FileData?
---@return Errors.Error?
function RomArchive.encodeIcon(byteData)
  assert(type(byteData) == "userdata", "managed icon encoding requires Data")
  ---@cast byteData love.Data
  assert(type(byteData.getSize) == "function", "managed icon encoding requires Data")
  local source = RomSource.fromByteData(byteData, "managed-icon")
  local headerOk, headerOrError = pcall(Cartridge.readHeader, source)
  if not headerOk then
    source:release()
    if Errors.is(headerOrError) then
      return nil, headerOrError
    end
    error(headerOrError, 0)
  end
  local rgba, iconError = Cartridge.readBannerIcon(source, headerOrError)
  source:release()
  if rgba == nil then
    return nil, iconError
  end
  return encodeRgba(rgba)
end

---@param versionId string
---@return string? romSha1
---@return love.FileData? pngFileData
---@return Errors.Error?
function RomArchive.readManagedIcon(versionId)
  local info = GameVersion.info(versionId)
  assert(type(info.sha1) == "string", "managed edition identity is required")
  local romSha1 = info.sha1:lower()
  local path = RomArchive.recoverablePath(romSha1)
  if path == nil then
    return nil,
      nil,
      archiveFailure(ARCHIVE_CODES.SOURCE_REQUIRED, "no managed ROM archive is present", {
        versionId = versionId,
        romSha1 = romSha1,
      })
  end
  local source, sourceError = RomSource.fromManagedZip(path, MEMBER, true)
  if source == nil then
    return nil, nil, sourceError
  end
  local rom, romError = NdsRom.open(source, GameVersion)
  if rom == nil then
    source:release()
    return nil, nil, romError
  end
  local actualInfo = rom:versionInfo()
  if actualInfo.id ~= versionId or actualInfo.sha1:lower() ~= romSha1 then
    rom:release()
    return nil,
      nil,
      archiveFailure(ARCHIVE_CODES.ICON_INVALID, "managed ROM does not match the requested edition", {
        versionId = versionId,
        romSha1 = romSha1,
        actualVersionId = actualInfo.id,
      })
  end
  local rgba, iconError = Cartridge.readBannerIcon(rom, rom:header())
  rom:release()
  if rgba == nil then
    return nil, nil, iconError
  end
  local png, encodeError = encodeRgba(rgba)
  if png == nil then
    return nil, nil, encodeError
  end
  return romSha1, png
end

---@param romSha1 string
---@param pngFileData love.FileData borrowed encoded PNG
---@return true?
---@return Errors.Error?
function RomArchive.publishIcon(romSha1, pngFileData)
  local canonical = RomArchive.iconPath(romSha1)
  assert(type(pngFileData) == "userdata", "managed icon publication requires encoded PNG data")
  ---@cast pngFileData love.FileData
  assert(type(pngFileData.getSize) == "function", "managed icon publication requires encoded PNG data")
  if RomArchive.recoverablePath(romSha1) == nil then
    return nil,
      archiveFailure(ARCHIVE_CODES.SOURCE_REQUIRED, "cannot publish an icon without its managed ROM", {
        romSha1 = romSha1,
      })
  end
  local stage = canonical .. STAGE_SUFFIX
  local backup = canonical .. BACKUP_SUFFIX
  local removed, removeError = removeOwned(stage)
  if not removed then
    return nil,
      archiveFailure(ARCHIVE_CODES.ICON_PUBLISH_FAILED, "abandoned managed icon stage could not be removed", {
        path = stage,
        cause = tostring(removeError),
      })
  end

  if love.filesystem.getInfo(canonical, "file") == nil and love.filesystem.getInfo(backup, "file") ~= nil then
    local restored, restoreError = renameOwned(backup, canonical)
    if not restored then
      return nil,
        archiveFailure(ARCHIVE_CODES.ICON_PUBLISH_FAILED, "previous managed icon backup could not be restored", {
          path = canonical,
          cause = tostring(restoreError),
        })
    end
  end

  local writeError = writeStage({ stage = stage }, { pngFileData })
  if writeError then
    removeOwned(stage)
    return nil, writeError
  end
  if love.filesystem.getInfo(canonical, "file") ~= nil then
    if not removeOwned(backup) then
      removeOwned(stage)
      return nil,
        archiveFailure(ARCHIVE_CODES.ICON_PUBLISH_FAILED, "previous managed icon backup could not be removed", {
          path = backup,
        })
    end
    local moved, moveError = renameOwned(canonical, backup)
    if not moved then
      removeOwned(stage)
      return nil,
        archiveFailure(ARCHIVE_CODES.ICON_PUBLISH_FAILED, "previous managed icon could not be moved aside", {
          path = canonical,
          cause = tostring(moveError),
        })
    end
  end
  local promoted, promoteError = renameOwned(stage, canonical)
  if not promoted then
    if love.filesystem.getInfo(canonical, "file") == nil and love.filesystem.getInfo(backup, "file") ~= nil then
      renameOwned(backup, canonical)
    end
    removeOwned(stage)
    return nil,
      archiveFailure(ARCHIVE_CODES.ICON_PUBLISH_FAILED, "managed icon stage could not be promoted", {
        path = canonical,
        cause = tostring(promoteError),
      })
  end
  -- Readers use the promoted canonical PNG, so a stale backup left by a
  -- failed cleanup is not a publication failure and must not report one.
  removeOwned(backup)
  return true
end

---@param versionInfo table<string, unknown>
---@param byteData love.Data
---@param versions table<string, unknown>
---@return RomArchive.Prepared?
---@return Errors.Error?
function RomArchive.prepare(versionInfo, byteData, versions)
  assert(type(versionInfo) == "table", "managed ROM preparation requires verified version information")
  assert(type(versionInfo.id) == "string" and type(versionInfo.sha1) == "string", "verified ROM identity is required")
  assert(type(byteData) == "userdata", "managed ROM preparation requires Data")
  ---@cast byteData love.Data
  assert(type(byteData.getSize) == "function", "managed ROM preparation requires Data")
  local romSha1 = versionInfo.sha1:lower()
  local canonical = RomArchive.path(romSha1)
  local prepared = {
    romSha1 = romSha1,
    canonical = canonical,
    stage = canonical .. STAGE_SUFFIX,
    backup = canonical .. BACKUP_SUFFIX,
    consumed = false,
  }
  local fs = love.filesystem
  if not exists(ROOT) then
    local created, createError = fs.createDirectory(ROOT)
    if not created then
      return nil,
        archiveFailure(ARCHIVE_CODES.WRITE_FAILED, "managed ROM directory could not be created", {
          path = ROOT,
          cause = tostring(createError),
        })
    end
  end
  local removed, removeError = removeOwned(prepared.stage)
  if not removed then
    return nil,
      archiveFailure(ARCHIVE_CODES.WRITE_FAILED, "abandoned managed ROM stage could not be removed", {
        path = prepared.stage,
        cause = tostring(removeError),
      })
  end

  local size = byteData:getSize()
  if size > MAX_RECORD_BYTES then
    return nil,
      archiveFailure(ARCHIVE_CODES.WRITE_FAILED, "managed ROM exceeds the Zip32 size field", { path = canonical })
  end
  ---@cast size integer
  local ok, failure = pcall(function()
    local crc = Zip32.crc32(BinaryView.fromData(byteData, MEMBER))
    local body = byteData
    local method = 0
    local compressedSize = size
    local compressedOk, compressed = pcall(love.data.compress, "data", "deflate", byteData, 1)
    if not compressedOk or type(compressed) ~= "userdata" then
      error("managed ROM compression failed: " .. tostring(compressed), 0)
    end
    ---@cast compressed love.CompressedData
    local compressedBytes = compressed:getSize()
    ---@cast compressedBytes integer
    if compressedBytes < size then
      body = compressed
      method = 8
      compressedSize = compressedBytes
    end
    if compressedSize > MAX_RECORD_BYTES then
      Errors.raise(ARCHIVE_CODES.WRITE_FAILED, "compressed managed ROM exceeds the Zip32 size field", {
        path = canonical,
      })
    end
    local row = {
      path = MEMBER,
      uncompressedSize = size,
      unsignedCrc32 = crc,
      method = method,
      compressedSize = compressedSize,
      offset = 0,
    }
    local header = Zip32.localHeader(row)
    local directoryOffset = #header + compressedSize
    local central = Zip32.centralRecord({
      path = row.path,
      uncompressedSize = row.uncompressedSize,
      unsignedCrc32 = row.unsignedCrc32,
      method = row.method,
      compressedSize = row.compressedSize,
      offset = 0,
    })
    local writeError = writeStage(prepared, {
      header,
      body,
      central,
      Zip32.endRecord(1, #central, directoryOffset),
    })
    if writeError then
      error(writeError, 0)
    end
  end)
  if not ok then
    removeOwned(prepared.stage)
    return nil,
      Errors.is(failure) and failure or archiveFailure(
        ARCHIVE_CODES.WRITE_FAILED,
        "managed ROM archive could not be written",
        {
          path = prepared.stage,
          cause = tostring(failure),
        }
      )
  end

  local source, openError = RomSource.fromManagedZip(prepared.stage, MEMBER)
  if source == nil then
    removeOwned(prepared.stage)
    return nil,
      archiveFailure(ARCHIVE_CODES.INVALID, "managed ROM stage could not be reopened", {
        path = prepared.stage,
        cause = Errors.format(openError),
      })
  end
  local verified, verifyError = NdsRom.open(source, versions)
  local valid = verified ~= nil
    and verified:versionInfo().id == versionInfo.id
    and verified:versionInfo().sha1:lower() == romSha1
  if verified then
    verified:release()
  else
    source:release()
  end
  if not valid then
    removeOwned(prepared.stage)
    return nil,
      archiveFailure(ARCHIVE_CODES.INVALID, "managed ROM stage failed verification", {
        path = prepared.stage,
        cause = Errors.format(verifyError),
      })
  end
  return prepared
end

---@param prepared RomArchive.Prepared
---@return true?
---@return Errors.Error?
function RomArchive.publish(prepared)
  assert(type(prepared) == "table" and type(prepared.stage) == "string", "publish requires a prepared ROM archive")
  if prepared.consumed then
    return nil, archiveFailure(ARCHIVE_CODES.PUBLISH_FAILED, "managed ROM stage was already consumed", {})
  end
  prepared.consumed = true
  if not exists(prepared.stage) then
    return nil, archiveFailure(ARCHIVE_CODES.PUBLISH_FAILED, "managed ROM stage is missing", { path = prepared.stage })
  end
  if exists(prepared.canonical) then
    if not removeOwned(prepared.backup) then
      removeOwned(prepared.stage)
      return nil,
        archiveFailure(ARCHIVE_CODES.PUBLISH_FAILED, "previous managed ROM backup could not be removed", {
          path = prepared.backup,
        })
    end
    local moved, moveError = renameOwned(prepared.canonical, prepared.backup)
    if not moved then
      removeOwned(prepared.stage)
      return nil,
        archiveFailure(ARCHIVE_CODES.PUBLISH_FAILED, "previous managed ROM could not be moved aside", {
          path = prepared.canonical,
          cause = tostring(moveError),
        })
    end
  end
  local promoted, promoteError = renameOwned(prepared.stage, prepared.canonical)
  if not promoted then
    if exists(prepared.backup) and not exists(prepared.canonical) then
      renameOwned(prepared.backup, prepared.canonical)
    end
    removeOwned(prepared.stage)
    return nil,
      archiveFailure(ARCHIVE_CODES.PUBLISH_FAILED, "managed ROM stage could not be promoted", {
        path = prepared.canonical,
        cause = tostring(promoteError),
      })
  end
  if not removeOwned(prepared.backup) then
    return nil,
      archiveFailure(ARCHIVE_CODES.PUBLISH_FAILED, "the previous managed ROM backup could not be removed", {
        path = prepared.backup,
      })
  end
  return true
end

---@param prepared RomArchive.Prepared
function RomArchive.discard(prepared)
  if prepared.consumed then
    return
  end
  prepared.consumed = true
  removeOwned(prepared.stage)
end

return RomArchive
