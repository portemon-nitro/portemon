-- The only runtime entry point for raw ROM content. Opened over a verified
-- cartridge it derives its file and overlay maps from the cartridge itself
-- and serves bytes straight from the source buffer. It serves file bytes
-- and NARC members lazily by FAT fileId, exact NitroFS source path, or curated
-- alias/symbol, and never caches large payloads globally.
--
-- Transient maps (source path -> fileId, alias/symbol -> resolved NARC) are
-- built once at open() from the cartridge tables. Decoders should prefer
-- explicit readSourcePath.

local Errors = require("libs.errors.src.Errors")
local Narc = require("libs.nds.src.nitro.Narc")
local NdsRom = require("romdump.src.source.NdsRom")
local OverlayCompression = require("libs.nds.src.rom.OverlayCompression")
local HgssArchives = require("romdump.src.config.HgssArchives")

-- Direct-reader identity shapes for the metadata, file index, and overlay
-- index derived from the cartridge at open. These version the reader's own
-- in-memory tables, not any persisted dump.
local METADATA_SCHEMA = 1
local ROMFS_INDEX_SCHEMA = 1
local OVERLAY_INDEX_SCHEMA = 1

---@class RomFs
---@field private _version string
---@field private _metadata table<string, unknown>
local RomFs = {}
RomFs.__index = RomFs

---@class RomFs.Narc
---@field readMember fun(self: RomFs.Narc, memberId: integer): string?, Errors.Error?
---@field memberCount fun(self: RomFs.Narc): integer
---@field memberInfo fun(self: RomFs.Narc, memberId: integer): table<string, unknown>?, Errors.Error?

---@class RomFs.NarcInfo
---@field symbol string
---@field alias string
---@field narcId integer
---@field path string
---@field fileId integer

-- Open over one verified cartridge: the file and overlay maps are derived
-- from the cartridge's own FAT/FNT/overlay tables, and every byte comes
-- straight from the source buffer. The returned reader owns only its maps
-- and a borrowed view of the source, never the shared buffer itself.
local function openDirect(versionId, romSource)
  if type(romSource) ~= "table" or type(romSource.read) ~= "function" or type(romSource.sha1) ~= "function" then
    Errors.raise(
      "ROMFS_BAD_SOURCE",
      "direct open requires a ROM source for version " .. tostring(versionId),
      { version = versionId }
    )
  end
  local rom, romErr = NdsRom.open(romSource)
  if not rom then
    error(romErr, 0)
  end
  assert(rom)
  local versionInfo = rom:versionInfo()
  if versionInfo.id ~= versionId then
    Errors.raise(
      "ROMFS_VERSION_MISMATCH",
      "cartridge " .. versionInfo.id .. " does not match requested version " .. tostring(versionId),
      { version = versionId, cartridgeVersion = versionInfo.id }
    )
  end

  local header = rom:header()
  local map = rom:fileMap()
  local fileCount = rom:fatCount()
  local arm9Overlays, arm7Overlays = rom:arm9Overlays(), rom:arm7Overlays()
  local unmappedCount, totalBytes = 0, 0
  local files, byPath = {}, {}
  for fileId = 0, fileCount - 1 do
    local dest = map[fileId]
    assert(dest, "cartridge map missing fileId " .. fileId)
    files[fileId] = {
      fileId = fileId,
      path = dest.path,
      sourcePath = dest.sourcePath,
      offset = dest.offset,
      size = dest.size,
      kind = dest.kind,
      overlayId = dest.overlayId,
    }
    if dest.sourcePath then
      byPath[dest.sourcePath] = fileId
    end
    if dest.kind == "unmapped" then
      unmappedCount = unmappedCount + 1
    end
    totalBytes = totalBytes + dest.size
  end

  local function overlayTable(list)
    local out = {}
    for _, entry in ipairs(list) do
      out[entry.overlayId] = {
        overlayId = entry.overlayId,
        fileId = entry.fileId,
        ramAddress = entry.ramAddress,
        ramSize = entry.ramSize,
        bssSize = entry.bssSize,
        staticInitStart = entry.staticInitStart,
        staticInitEnd = entry.staticInitEnd,
        flags = entry.flags,
      }
    end
    return out
  end

  return setmetatable({
    _version = versionId,
    _rom = rom,
    _metadata = {
      schema = METADATA_SCHEMA,
      version = versionInfo.id,
      displayName = versionInfo.displayName,
      sha1 = versionInfo.sha1,
      size = rom:size(),
      title = header.title,
      gameCode = header.gameCode,
      makerCode = header.makerCode,
      unitCode = header.unitCode,
      romVersion = header.romVersion,
      headerSize = header.headerSize,
      usedRomSize = header.usedRomSize,
      arm9 = {
        offset = header.arm9.offset,
        size = header.arm9.size,
        entryAddress = header.arm9.entryAddress,
        ramAddress = header.arm9.ramAddress,
      },
      arm7 = {
        offset = header.arm7.offset,
        size = header.arm7.size,
        entryAddress = header.arm7.entryAddress,
        ramAddress = header.arm7.ramAddress,
      },
      fnt = { offset = header.fnt.offset, size = header.fnt.size },
      fat = { offset = header.fat.offset, size = header.fat.size },
      arm9Overlays = { offset = header.arm9Overlays.offset, size = header.arm9Overlays.size },
      arm7Overlays = { offset = header.arm7Overlays.offset, size = header.arm7Overlays.size },
    },
    _index = {
      schema = ROMFS_INDEX_SCHEMA,
      version = versionInfo.id,
      romSha1 = versionInfo.sha1,
      fileCount = fileCount,
      namedFileCount = rom:nitroFs().namedFileCount,
      overlayFileCount = #arm9Overlays + #arm7Overlays,
      unmappedFileCount = unmappedCount,
      totalFileBytes = totalBytes,
      files = files,
    },
    _overlayIndex = {
      schema = OVERLAY_INDEX_SCHEMA,
      arm9 = overlayTable(arm9Overlays),
      arm7 = overlayTable(arm7Overlays),
    },
    _byPath = byPath,
  }, RomFs)
end

-- Open over a verified cartridge is the only supported path: compilers
-- receive their borrowed source view from the pool after a genuine receipt
-- miss, never a cache handle. Anything without a readable source view is a
-- typed bad-source failure, never a fallback to historical extracted files.
function RomFs.open(versionId, romSource)
  local ok, result = pcall(openDirect, versionId, romSource)
  if ok then
    return result
  end
  if Errors.is(result) then
    return nil, result
  end
  error(result)
end

function RomFs:version()
  return self._version
end
function RomFs:metadata()
  return self._metadata
end
function RomFs:fileCount()
  return self._index.fileCount
end

-- Count curated aliases that resolve against this cartridge's FNT (i.e. whose path
-- is present). Derived, not stored, so it always reflects the current manifest.
function RomFs:_resolvedNarcCount()
  local count = 0
  for _, entry in ipairs(HgssArchives.aliasList()) do
    if self._byPath[entry.path] then
      count = count + 1
    end
  end
  return count
end

-- Aggregate counts for diagnostics, drawn straight from the loaded index.
function RomFs:stats()
  local i = self._index
  return {
    fileCount = i.fileCount,
    namedFileCount = i.namedFileCount,
    overlayFileCount = i.overlayFileCount,
    unmappedFileCount = i.unmappedFileCount,
    totalFileBytes = i.totalFileBytes,
    resolvedNarcCount = self:_resolvedNarcCount(),
  }
end

-- Resolve a fileId or an exact NitroFS source path to its index entry.
function RomFs:info(pathOrFileId)
  local fileId = pathOrFileId
  if type(pathOrFileId) == "string" then
    fileId = self._byPath[pathOrFileId]
    if not fileId then
      return nil, Errors.new("ROMFS_PATH_UNKNOWN", "no NitroFS file at " .. pathOrFileId, { sourcePath = pathOrFileId })
    end
  end
  local entry = self._index.files[fileId]
  if not entry then
    return nil, Errors.new("ROMFS_FILE_ID_UNKNOWN", "no file for fileId " .. tostring(fileId), { fileId = fileId })
  end
  return entry
end

function RomFs:pathForFileId(fileId)
  local entry = self._index.files[fileId]
  return entry and entry.path or nil
end

function RomFs:fileIdForPath(sourcePath)
  return self._byPath[sourcePath]
end

-- Read a FAT-backed file by fileId or by exact source path, slicing the
-- recorded FAT range straight out of the cartridge buffer.
function RomFs:read(pathOrFileId)
  local entry, err = self:info(pathOrFileId)
  if not entry then
    return nil, err
  end
  local rom = assert(self._rom, "direct ROM reader owns its cartridge view")
  local ok, data = pcall(function()
    return rom:readFatFile(entry.fileId)
  end)
  if ok then
    return data
  end
  if Errors.is(data) then
    return nil, data
  end
  error(data, 0)
end

function RomFs:readSourcePath(sourcePath)
  assert(type(sourcePath) == "string", "readSourcePath requires a string")
  return self:read(sourcePath)
end

-- Resolve an imported ARM overlay by its CPU and zero-based overlayId. Overlay
-- metadata comes from the generated overlay table; bytes still flow through
-- the ordinary FAT-backed file index.
function RomFs:overlayInfo(cpu, overlayId)
  if cpu ~= "arm9" and cpu ~= "arm7" then
    return nil,
      Errors.new(
        "ROMFS_OVERLAY_UNKNOWN_CPU",
        "unknown overlay CPU " .. tostring(cpu),
        { cpu = cpu, overlayId = overlayId }
      )
  end
  local raw = self._overlayIndex[cpu][overlayId]
  if not raw then
    return nil,
      Errors.new(
        "ROMFS_OVERLAY_UNKNOWN_ID",
        "no " .. cpu .. " overlay for overlayId " .. tostring(overlayId),
        { cpu = cpu, overlayId = overlayId }
      )
  end
  local file = self._index.files[raw.fileId]
  assert(file, "overlay_index references missing fileId " .. tostring(raw.fileId))
  return {
    cpu = cpu,
    overlayId = raw.overlayId,
    fileId = raw.fileId,
    path = file.path,
    ramAddress = raw.ramAddress,
    ramSize = raw.ramSize,
    bssSize = raw.bssSize,
    staticInitStart = raw.staticInitStart,
    staticInitEnd = raw.staticInitEnd,
    flags = raw.flags,
    compressedSize = raw.flags % 16777216,
    isCompressed = math.floor(raw.flags / 16777216) % 2 == 1,
  }
end

function RomFs:readOverlay(cpu, overlayId)
  local info, err = self:overlayInfo(cpu, overlayId)
  if not info then
    return nil, err
  end
  local bytes, readErr = self:read(info.fileId)
  if not bytes then
    return nil,
      Errors.new(
        "ROMFS_OVERLAY_FILE_MISSING",
        "cartridge overlay bytes are missing for fileId " .. info.fileId,
        { cpu = cpu, overlayId = overlayId, fileId = info.fileId, path = info.path, cause = readErr and readErr.code }
      )
  end
  if info.isCompressed then
    local decoded, decodeErr = OverlayCompression.decode(bytes, info.ramSize)
    if not decoded then
      return nil, decodeErr
    end
    bytes = decoded
  end
  return bytes, info
end

-- Resolve a curated alias, version-neutral alias, or raw NARC symbol to a fileId
-- entry, using the checked-in manifest plus this cartridge's FNT path index. Returns
-- nil if the manifest does not know the name or its path is absent from the FNT.
-- No memberCount is included (that requires opening the NARC); openNarc does
-- not need it.
function RomFs:resolvedNarc(symbolOrAlias)
  local ok, entry = pcall(HgssArchives.resolve, symbolOrAlias, self._version)
  if not (ok and entry) then
    return nil
  end
  local fileId = self._byPath[entry.path]
  if not fileId then
    return nil
  end
  return {
    symbol = entry.symbol,
    alias = entry.alias,
    narcId = entry.narcId,
    path = entry.path,
    fileId = fileId,
  }
end

function RomFs:openNarc(symbolOrAlias)
  local entry = self:resolvedNarc(symbolOrAlias)
  if not entry then
    return nil,
      Errors.new("ROMFS_NARC_UNRESOLVED", "no resolved NARC for " .. tostring(symbolOrAlias), { name = symbolOrAlias })
  end
  local data, err = self:read(entry.fileId)
  if not data then
    return nil, err
  end
  return Narc.open(data, entry.path)
end

function RomFs:close()
  -- Drop only per-view state. The cartridge holds a borrowed source view,
  -- so closing never releases the shared buffer its peers may still read.
  self._rom = nil
  self._metadata = nil
  self._index = nil
  self._overlayIndex = nil
  self._byPath = nil
end

return RomFs
