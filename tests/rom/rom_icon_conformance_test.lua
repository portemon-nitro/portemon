-- ROM conformance for managed static cartridge banners. Each ready private
-- edition runs through the real queued importer and read-only recovery worker;
-- expected pixels come from an independent GBATEK-layout test oracle.

local Assert = require("tests.support.Assert")
local BannerIconFixture = require("tests.support.BannerIconFixture")
local GameVersion = require("romdump.src.source.GameVersion")
local RomArchive = require("romdump.src.source.RomArchive")
local RomImporter = require("romdump.src.source.RomImporter")
local RomSourcePath = require("tests.rom.support.RomSourcePath")
local RomSuite = require("tests.rom.support.RomSuite")
local PngReader = require("tests.support.PngReader")
local SaveFs = require("libs.storage.src.SaveFs")
local CacheFs = require("libs.storage.src.CacheFs")

local T = {}

local function readIfPresent(path)
  return love.filesystem.getInfo(path) and love.filesystem.read(path) or nil
end

local function sha1Hex(data)
  local digest = assert(love.data.hash("sha1", data))
  local hex = {}
  for index = 1, #digest do
    hex[index] = string.format("%02x", digest:byte(index))
  end
  return table.concat(hex)
end

local function fileFingerprint(path)
  local info = love.filesystem.getInfo(path)
  if info == nil then
    return nil
  end
  Assert.equal(info.type, "file")
  local data = assert(love.filesystem.read("data", path))
  local fingerprint = { size = data:getSize(), sha1 = sha1Hex(data) }
  data:release()
  return fingerprint
end

local function dropBytes(name, bytes)
  return {
    open = function()
      return true
    end,
    read = function()
      return bytes
    end,
    close = function()
      return true
    end,
    getFilename = function()
      return name
    end,
  }
end

local function importBytes(versionId, bytes)
  local importer = RomImporter.new({ expectedVersionId = versionId })
  importer:queueDroppedFile(dropBytes(versionId .. ".nds", bytes))
  local thread = assert(importer._queued, "the real import worker must start").thread
  local deadline = love.timer.getTime() + 120
  while love.timer.getTime() < deadline do
    importer:update()
    if importer.state == "complete" or importer.state == "error" then
      break
    end
    love.timer.sleep(0.002)
  end
  Assert.equal(importer.state, "complete", "private import failed: " .. tostring(importer:status().error))
  while thread:isRunning() and love.timer.getTime() < deadline do
    importer:update()
    love.timer.sleep(0.002)
  end
  Assert.isFalse(thread:isRunning(), "the import worker must exit before the next journey")
  local handed = importer:takeVerifiedSource()
  Assert.notNil(handed)
  Assert.equal(handed:sha1(), GameVersion.info(versionId).sha1)
  handed:release()
  Assert.isNil(importer:takeVerifiedSource())
  return importer
end

local function waitRecovery(job)
  local deadline = love.timer.getTime() + 120
  while love.timer.getTime() < deadline do
    local state, romSha1, png = job:poll()
    if state ~= nil and state ~= "pending" then
      return state, romSha1, png
    end
    love.timer.sleep(0.002)
  end
  error("timed out waiting for private banner recovery", 0)
end

function T.verified_import_and_read_only_recovery_match_the_private_static_banner(_, versionId)
  Assert.equal(type(RomArchive.iconPath), "function", "the canonical managed sidecar path is required")
  Assert.equal(type(RomArchive.publishIcon), "function", "managed sidecar publication is required")
  Assert.equal(type(RomArchive.readManagedIcon), "function", "verified read-only extraction is required")
  local RomIconRecovery = require("romdump.src.source.RomIconRecovery")
  Assert.equal(type(RomIconRecovery.start), "function", "the background recovery job is required")
  local info = GameVersion.info(versionId)
  local reader, sourceOrError = RomSourcePath.openReader(versionId)
  Assert.notNil(reader, "private source could not open: " .. tostring(sourceOrError))
  assert(reader)
  local source = assert(sourceOrError)
  local romBytes = assert(source:read(0, source:size()))
  source:release()
  reader:close()
  local expectedRgba = BannerIconFixture.expectedRgbaFromRom(romBytes)

  local canonical = RomArchive.path(info.sha1)
  local icon = RomArchive.iconPath(info.sha1)
  local iconStage = icon .. ".new"
  local iconBackup = icon .. ".bak"
  local otherVersionId = versionId == "heartgold" and "soulsilver" or "heartgold"
  local otherInfo = GameVersion.info(otherVersionId)
  local otherCanonical = RomArchive.path(otherInfo.sha1)
  local otherIcon = RomArchive.iconPath(otherInfo.sha1)
  local otherSourceExisted = love.filesystem.getInfo(otherCanonical) ~= nil
  local otherIconExisted = love.filesystem.getInfo(otherIcon) ~= nil
  local otherSourceBefore = fileFingerprint(otherCanonical)
  local otherIconBefore = fileFingerprint(otherIcon)
  local savePath = "banner-icon-sentinel.lua"
  local cachePath = "derived/banner-icon-sentinel.lua"
  local previousIcon = readIfPresent(icon)

  local function assertIconMatches()
    local pngBytes = readIfPresent(icon)
    Assert.notNil(pngBytes, "the canonical sidecar must exist")
    local width, height, rgba = PngReader.rgba(assert(pngBytes))
    Assert.equal(width, 32)
    Assert.equal(height, 32)
    Assert.equal(rgba, expectedRgba, versionId .. " icon pixels must match the private static banner exactly")
  end

  local function assertUnchangedManagedData(sourceFingerprint)
    Assert.deepEqual(fileFingerprint(canonical), sourceFingerprint, "managed source bytes must stay unchanged")
    Assert.deepEqual(fileFingerprint(otherCanonical), otherSourceBefore, "the other edition source must stay unchanged")
    Assert.deepEqual(fileFingerprint(otherIcon), otherIconBefore, "the other edition icon must stay unchanged")
    Assert.equal(SaveFs.forVersion(versionId):read(savePath), versionId .. "-SAVE")
    Assert.equal(CacheFs.forVersion(versionId):read(cachePath), versionId .. "-CACHE")
  end

  local ok, err = pcall(function()
    Assert.isTrue(love.filesystem.createDirectory("roms"), "managed root setup failed")
    for _, path in ipairs({ icon, iconStage, iconBackup }) do
      if love.filesystem.getInfo(path) ~= nil then
        Assert.isTrue(love.filesystem.remove(path), "private sidecar fixture cleanup failed")
      end
    end
    if not otherSourceExisted then
      Assert.isTrue(love.filesystem.write(otherCanonical, "OTHER-EDITION-SOURCE"), "other edition fixture setup failed")
    end
    if not otherIconExisted then
      Assert.isTrue(love.filesystem.write(otherIcon, "OTHER-EDITION-ICON"), "other edition icon setup failed")
    end
    otherSourceBefore = fileFingerprint(otherCanonical)
    otherIconBefore = fileFingerprint(otherIcon)
    SaveFs.forVersion(versionId):write(savePath, versionId .. "-SAVE")
    CacheFs.forVersion(versionId):write(cachePath, versionId .. "-CACHE")

    importBytes(versionId, romBytes)
    assertIconMatches()
    local managed = assert(RomArchive.open(info.sha1))
    Assert.equal(managed:sha1(), info.sha1, "the imported managed archive keeps the exact catalog identity")
    managed:release()
    local firstIcon = readIfPresent(icon)
    importBytes(versionId, romBytes)
    Assert.equal(readIfPresent(icon), firstIcon, "duplicate import reuses the one canonical PNG")
    assertIconMatches()
    local sourceFingerprint = fileFingerprint(canonical)

    Assert.isTrue(love.filesystem.remove(icon), "missing-sidecar fixture setup failed")
    local missingJob = assert(RomIconRecovery.start(versionId))
    local state, romSha1, png = waitRecovery(missingJob)
    Assert.equal(state, "ready")
    Assert.equal(romSha1, info.sha1)
    Assert.notNil(png)
    assert(png)
    local width, height, rgba = PngReader.rgba(png:getString())
    Assert.equal(width, 32)
    Assert.equal(height, 32)
    Assert.equal(rgba, expectedRgba)
    Assert.isNil(missingJob:poll(), "the ready result is delivered once")
    Assert.isNil(readIfPresent(icon), "the read-only worker cannot create a sidecar")
    assertUnchangedManagedData(sourceFingerprint)
    Assert.isTrue(RomArchive.publishIcon(romSha1, png), "the matching recovered PNG can be published")
    png:release()
    missingJob:dispose()
    assertIconMatches()

    Assert.isTrue(love.filesystem.write(icon, "CORRUPT-ICON"), "corrupt-sidecar fixture setup failed")
    local corruptJob = assert(RomIconRecovery.start(versionId))
    local corruptState, corruptSha1, corruptPng = waitRecovery(corruptJob)
    Assert.equal(corruptState, "ready")
    Assert.equal(corruptSha1, info.sha1)
    Assert.notNil(corruptPng)
    assert(corruptPng)
    Assert.equal(readIfPresent(icon), "CORRUPT-ICON", "recovery leaves the corrupt sidecar untouched until publication")
    Assert.isNil(corruptJob:poll())
    assertUnchangedManagedData(sourceFingerprint)
    Assert.isTrue(RomArchive.publishIcon(corruptSha1, corruptPng))
    corruptPng:release()
    corruptJob:dispose()
    assertIconMatches()
  end)

  for _, path in ipairs({ iconStage, iconBackup }) do
    pcall(love.filesystem.remove, path)
  end
  if previousIcon ~= nil then
    pcall(love.filesystem.write, icon, previousIcon)
  else
    pcall(love.filesystem.remove, icon)
  end
  if not otherSourceExisted then
    pcall(love.filesystem.remove, otherCanonical)
  end
  if not otherIconExisted then
    pcall(love.filesystem.remove, otherIcon)
  end
  pcall(SaveFs.forVersion(versionId).remove, SaveFs.forVersion(versionId), savePath)
  pcall(CacheFs.forVersion(versionId).remove, CacheFs.forVersion(versionId), cachePath)
  if not ok then
    error(err, 0)
  end
end

local readyVersions = {}
for _, versionId in ipairs(GameVersion.ORDER) do
  if RomImporter.isReady(versionId) then
    readyVersions[#readyVersions + 1] = versionId
  end
end

return RomSuite.build({
  tests = T,
  readyVersions = readyVersions,
  open = RomSourcePath.openReader,
})
