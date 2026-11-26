-- Managed ROM archives are the durable import result. These scenarios run the
-- real importer worker and LÖVE save filesystem, then reopen the published
-- source through the real compiler-pool acquisition boundary.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local Fixture = require("tests.support.ManagedRomFixture")
local CacheFs = require("libs.storage.src.CacheFs")
local SaveFs = require("libs.storage.src.SaveFs")
local SnapshotArchive = require("tests.support.SnapshotArchive")
local ZipBuilder = require("tests.support.ZipBuilder")
local PngReader = require("tests.support.PngReader")
local PngEncoder = require("tests.support.PngEncoder")
local BannerIconFixture = require("tests.support.BannerIconFixture")
local NdsBuilder = require("tests.support.NdsBuilder")
local CompilerPool = require("romdump.src.build.CompilerPool")
local RomArchive = require("romdump.src.source.RomArchive")

local T = {}

local function withPatched(target, field, makePatched, fn)
  local original = target[field]
  target[field] = makePatched(original)
  local ok, err = pcall(fn)
  target[field] = original
  if not ok then
    error(err, 0)
  end
end

local function releaseHandoff(importer)
  local source = importer:takeVerifiedSource()
  Assert.notNil(source, "a completed import offers its verified source once")
  source:release()
  Assert.isNil(importer:takeVerifiedSource(), "the verified source handoff is one-shot")
end

local function acquireSource(fixture)
  local pool = CompilerPool.new({ mode = "interactive" })
  pool:selectGeneration({ versionId = fixture.cart.info.id, generationId = "managed-source-generation" }, 1)
  local held, failure = pool:prepareBootSource(1, true)
  local byteData = pool.sharedSource and pool.sharedSource.byteData or nil
  pool:shutdown()
  local detail = type(failure) == "table" and (failure.code .. ": " .. tostring(failure.message)) or tostring(failure)
  Assert.isTrue(held == true, "managed source acquisition must succeed: " .. detail)
  Assert.notNil(byteData, "the source pool must expose its acquired buffer for review")
  return byteData
end

local function sha1(data)
  local digest = assert(love.data.hash("sha1", data))
  local hex = ""
  for index = 1, #digest do
    hex = hex .. string.format("%02x", digest:byte(index))
  end
  return hex
end

function T.raw_and_zipped_imports_survive_original_and_cache_removal()
  Fixture.with(function(fixture)
    local completions = {}
    local importer = fixture.host:importer(fixture.cart, function(versionId)
      completions[#completions + 1] = versionId
    end)
    fixture.host.holdValidation = true
    importer:queuePath(fixture.originalPath)
    local session = fixture.host:validationGate(importer)
    Assert.isTrue(importer.progress < 1, "public progress cannot complete before durable publication")
    Assert.isFalse(importer.state == "complete", "validation cannot complete the public import")
    Assert.isNil(love.filesystem.getInfo(fixture.canonical), "validation alone publishes no managed archive")
    session.outbox:releaseValidation()
    fixture.host.holdValidation = false
    fixture.host:finish(importer, "complete")
    Assert.equal(importer:status().versionId, fixture.cart.info.id)
    Assert.equal(#completions, 1)
    releaseHandoff(importer)
    Assert.notNil(love.filesystem.getInfo(fixture.canonical), "COMPLETE must publish the canonical managed archive")
    local first = fixture:managedMembers()
    Assert.deepEqual(first.names, { "game.nds" }, "managed storage contains exactly the selected cartridge")
    Assert.equal(first.bytes, fixture.cart.data)

    Assert.isTrue(os.remove(fixture.originalPath), "the original fixture must be removable after import")
    SaveFs.forVersion(fixture.cart.info.id):write("sentinel.lua", "SAVE-SENTINEL")
    CacheFs.forVersion(fixture.cart.info.id):write("derived/sentinel.lua", "CACHE-SENTINEL")
    local zipped = fixture.host:importer(fixture.cart)
    zipped:queuePath(fixture.archivePath)
    fixture.host:finish(zipped, "complete")
    releaseHandoff(zipped)
    Assert.isNil(love.filesystem.getInfo(fixture.stage), "successful publication leaves no stage")
    Assert.isNil(love.filesystem.getInfo(fixture.backup), "successful replacement leaves no backup")
    local second = fixture:managedMembers()
    Assert.deepEqual(second.names, { "game.nds" }, "ZIP input is repacked rather than copied")
    Assert.equal(second.bytes, fixture.cart.data, "raw and ZIP inputs converge on the same member bytes")
    Assert.equal(SaveFs.forVersion(fixture.cart.info.id):read("sentinel.lua"), "SAVE-SENTINEL")
    Assert.equal(CacheFs.forVersion(fixture.cart.info.id):read("derived/sentinel.lua"), "CACHE-SENTINEL")

    Assert.isTrue(os.remove(fixture.archivePath), "the ZIP original must be removable after import")
    SnapshotArchive.removeTree(fixture.cart.info.id)
    Assert.isNil(
      CacheFs.forVersion(fixture.cart.info.id):read("derived/sentinel.lua"),
      "only the generated cache is deleted"
    )
    Assert.equal(
      SaveFs.forVersion(fixture.cart.info.id):read("sentinel.lua"),
      "SAVE-SENTINEL",
      "cache deletion preserves saves"
    )
    local reopened = acquireSource(fixture)
    local reopenedSha1 = sha1(reopened:getString())
    Assert.equal(reopenedSha1, fixture.cart.sha1, "a fresh source pool reopens the managed ROM without either original")
  end)
end

function T.managed_open_requires_the_exact_one_member_root_listing()
  Fixture.with(function(fixture)
    Assert.isTrue(love.filesystem.createDirectory("roms"), "managed root setup failed")
    local cases = {
      {
        label = "an extra file",
        members = {
          { name = "game.nds", data = fixture.cart.data },
          { name = "notes.txt", data = "unmanaged payload" },
        },
      },
      {
        label = "an extra directory",
        members = {
          { name = "game.nds", data = fixture.cart.data },
          { name = "extras/", data = "" },
        },
      },
    }
    for _, case in ipairs(cases) do
      Assert.isTrue(
        love.filesystem.write(fixture.canonical, ZipBuilder.build(case.members)),
        "managed corruption fixture setup failed"
      )
      local source, failure = RomArchive.open(fixture.cart.sha1)
      Assert.isNil(source, "a managed archive with " .. case.label .. " must not open")
      Assert.isTrue(Errors.is(failure), "the strict root listing reports a typed archive failure")
      Assert.equal(failure.code, "ROM_ARCHIVE_INVALID")
    end
  end)
end

function T.cancel_and_failed_promotion_preserve_the_published_source()
  Fixture.with(function(fixture)
    Assert.isTrue(love.filesystem.createDirectory("roms"), "managed root setup failed")
    local previousBytes = ZipBuilder.build({ { name = "game.nds", data = fixture.cart.data } })
    Assert.isTrue(love.filesystem.write(fixture.canonical, previousBytes), "previous managed source setup failed")
    Assert.equal(type(RomArchive.publishIcon), "function", "managed sidecar publication is required")
    local previousIcon =
      love.filesystem.newFileData(PngEncoder.encode(32, 32, string.rep("\0", 4096)), "previous-icon.png")
    Assert.isTrue(RomArchive.publishIcon(fixture.cart.sha1, previousIcon), "previous managed icon setup failed")
    previousIcon:release()
    local previousIconBytes = love.filesystem.read(fixture.icon)
    SaveFs.forVersion(fixture.cart.info.id):write("sentinel.lua", "SAVE-SENTINEL")
    CacheFs.forVersion(fixture.cart.info.id):write("derived/sentinel.lua", "CACHE-SENTINEL")
    local completions = {}
    fixture.host.holdValidation = true

    local canceled = fixture.host:importer(fixture.cart, function(versionId)
      completions[#completions + 1] = versionId
    end)
    canceled:queuePath(fixture.originalPath)
    local session = fixture.host:validationGate(canceled)
    Assert.notNil(
      love.filesystem.getInfo(fixture.stage),
      "the checked unpublished stage exists before commit authorization"
    )
    canceled:cancelQueued()
    session.outbox:discardValidation()
    fixture.host:finish(canceled, "idle")
    fixture.host:waitFor(function()
      canceled:update()
      return not session.thread:isRunning()
    end, "canceled worker cleanup")
    Assert.equal(
      love.filesystem.read(fixture.canonical),
      previousBytes,
      "cancellation keeps the exact published archive"
    )
    Assert.equal(love.filesystem.read(fixture.icon), previousIconBytes, "cancellation keeps the exact published icon")
    Assert.isNil(love.filesystem.getInfo(fixture.stage), "canceled staging is cleaned")
    Assert.isNil(love.filesystem.getInfo(fixture.backup), "cancellation creates no backup")
    Assert.equal(#completions, 0, "a canceled request cannot navigate through completion")
    Assert.equal(SaveFs.forVersion(fixture.cart.info.id):read("sentinel.lua"), "SAVE-SENTINEL")
    Assert.equal(CacheFs.forVersion(fixture.cart.info.id):read("derived/sentinel.lua"), "CACHE-SENTINEL")

    fixture.host.holdValidation = false
    fixture.host.prelude = [[
local realRename = os.rename
os.rename = function(source, destination)
  if type(source) == "string" and source:match("%.zip%.new$") and type(destination) == "string"
    and destination:match("%.zip$") then
    return false, "injected managed stage promotion failure"
  end
  return realRename(source, destination)
end
]]
    local failed = fixture.host:importer(fixture.cart, function(versionId)
      completions[#completions + 1] = versionId
    end)
    failed:queuePath(fixture.archivePath)
    fixture.host:finish(failed, "error")
    Assert.equal(failed:status().errorCode, "ROM_ARCHIVE_PUBLISH_FAILED", "promotion failure is a typed archive error")
    Assert.equal(#completions, 0, "failed publication never completes or navigates")
    Assert.isNil(failed:takeVerifiedSource(), "failed publication offers no verified handoff")
    Assert.isNil(love.filesystem.getInfo(fixture.stage), "failed publication cleans its stage")
    Assert.equal(SaveFs.forVersion(fixture.cart.info.id):read("sentinel.lua"), "SAVE-SENTINEL")
    Assert.equal(CacheFs.forVersion(fixture.cart.info.id):read("derived/sentinel.lua"), "CACHE-SENTINEL")
    local recoverable = love.filesystem.getInfo(fixture.canonical) and fixture.canonical or fixture.backup
    local recovered = fixture:managedMembers(
      recoverable == fixture.canonical and fixture.cart.sha1 .. ".zip" or fixture.cart.sha1 .. ".zip.bak"
    )
    Assert.deepEqual(recovered.names, { "game.nds" })
    Assert.equal(recovered.bytes, fixture.cart.data, "the previous source remains recoverable after failed promotion")
    Assert.equal(sha1(acquireSource(fixture):getString()), fixture.cart.sha1, "the recoverable source still acquires")
    Assert.equal(
      love.filesystem.read(fixture.icon),
      previousIconBytes,
      "failed source promotion never replaces the icon"
    )
    Assert.isNil(love.filesystem.getInfo(fixture.iconStage), "failed source promotion leaves no icon stage")
  end)
end

function T.recoverable_path_accepts_only_actual_managed_files_without_reading()
  Fixture.with(function(fixture)
    Assert.isTrue(love.filesystem.createDirectory("roms"), "managed root setup failed")
    CacheFs.forVersion(fixture.cart.info.id):write("rom-source.lua", "return { path = '/legacy/game.nds' }")
    SaveFs.forVersion(fixture.cart.info.id):write("sentinel.lua", "SAVE-SENTINEL")
    local reads, mounts, hashes = 0, 0, 0
    withPatched(love.filesystem, "read", function(original)
      return function(...)
        reads = reads + 1
        return original(...)
      end
    end, function()
      withPatched(love.filesystem, "mount", function(original)
        return function(...)
          mounts = mounts + 1
          return original(...)
        end
      end, function()
        withPatched(love.data, "hash", function(original)
          return function(...)
            hashes = hashes + 1
            return original(...)
          end
        end, function()
          Assert.isNil(RomArchive.recoverablePath(fixture.cart.sha1), "a legacy binding is not a managed install")
          Assert.isTrue(love.filesystem.createDirectory(fixture.canonical), "directory fixture setup failed")
          Assert.isTrue(love.filesystem.write(fixture.backup, "BACKUP-SOURCE"), "backup fixture setup failed")
          Assert.equal(
            RomArchive.recoverablePath(fixture.cart.sha1),
            fixture.backup,
            "a directory at the canonical name must not hide a real backup file"
          )
          Assert.isTrue(love.filesystem.remove(fixture.canonical), "directory fixture cleanup failed")
          Assert.isTrue(love.filesystem.write(fixture.canonical, "CANONICAL-SOURCE"), "canonical fixture setup failed")
          Assert.equal(
            RomArchive.recoverablePath(fixture.cart.sha1),
            fixture.canonical,
            "the actual canonical file wins over a backup"
          )
          Assert.isTrue(love.filesystem.remove(fixture.canonical), "canonical fixture cleanup failed")
          Assert.equal(RomArchive.recoverablePath(fixture.cart.sha1), fixture.backup)
        end)
      end)
    end)
    Assert.equal(reads, 0, "the installation fact must not read source bytes")
    Assert.equal(mounts, 0, "the installation fact must not mount an archive")
    Assert.equal(hashes, 0, "the installation fact must not hash a ROM")
    Assert.equal(SaveFs.forVersion(fixture.cart.info.id):read("sentinel.lua"), "SAVE-SENTINEL")
  end, { banner = BannerIconFixture.staticBanner().block })
end

function T.icon_publication_is_content_addressed_optional_and_failure_atomic()
  local banner = BannerIconFixture.staticBanner()
  Fixture.with(function(fixture)
    Assert.equal(type(RomArchive.iconPath), "function", "the archive owner must expose the canonical sidecar path")
    Assert.equal(type(RomArchive.encodeIcon), "function", "the archive owner must encode verified banner bytes")
    Assert.equal(type(RomArchive.publishIcon), "function", "the archive owner must publish encoded sidecars")
    Assert.equal(RomArchive.iconPath(fixture.cart.sha1), fixture.icon)
    Assert.throws(function()
      RomArchive.iconPath("../" .. fixture.cart.sha1)
    end, "sidecar paths must reuse managed identity validation")

    local bytes = love.data.newByteData(fixture.cart.data)
    local png, encodeError = RomArchive.encodeIcon(bytes)
    Assert.isNil(encodeError, "verified synthetic banner encoding must succeed")
    Assert.notNil(png, "encoding returns owned PNG data")
    assert(png)
    Assert.equal(bytes:getString(), fixture.cart.data, "encoding borrows rather than releases the verified ROM buffer")
    local encodedBeforePublication = png:getString()
    local published, publishError = RomArchive.publishIcon(fixture.cart.sha1, png)
    Assert.isNil(published, "an icon cannot be installed before its managed source exists")
    Assert.isTrue(Errors.is(publishError), "missing-source sidecar publication is a typed failure")
    Assert.isNil(love.filesystem.getInfo(fixture.icon), "missing-source publication writes no sidecar")

    Assert.isTrue(love.filesystem.createDirectory("roms"), "managed root setup failed")
    local prepared = assert(RomArchive.prepare(fixture.cart.info, bytes, fixture.cart.versions))
    Assert.isTrue(RomArchive.publish(prepared), "managed source setup failed")
    SaveFs.forVersion(fixture.cart.info.id):write("sentinel.lua", "SAVE-SENTINEL")
    CacheFs.forVersion(fixture.cart.info.id):write("derived/sentinel.lua", "CACHE-SENTINEL")
    local sourceBytes = love.filesystem.read(fixture.canonical)

    published, publishError = RomArchive.publishIcon(fixture.cart.sha1, png)
    Assert.isTrue(published, "sidecar publication failed: " .. tostring(publishError))
    Assert.equal(png:getString(), encodedBeforePublication, "publication borrows the caller's FileData")
    local width, height, rgba = PngReader.rgba(assert(love.filesystem.read(fixture.icon)))
    Assert.equal(width, 32)
    Assert.equal(height, 32)
    Assert.equal(rgba, banner.rgba, "the published PNG carries the exact synthetic static banner")
    local oldIcon = love.filesystem.read(fixture.icon)
    Assert.isNil(love.filesystem.getInfo(fixture.iconStage), "successful publication leaves no sidecar stage")
    Assert.isNil(love.filesystem.getInfo(fixture.iconBackup), "successful replacement leaves no sidecar backup")

    local replacement =
      love.filesystem.newFileData(PngEncoder.encode(32, 32, string.rep("\0", 4096)), "replacement.png")
    withPatched(os, "rename", function(original)
      return function(source, destination)
        if
          type(source) == "string"
          and source:match("%.png%.new$")
          and type(destination) == "string"
          and destination:match("%.png$")
        then
          return false, "injected sidecar promotion failure"
        end
        return original(source, destination)
      end
    end, function()
      local replaced, failure = RomArchive.publishIcon(fixture.cart.sha1, replacement)
      Assert.isNil(replaced, "a failed sidecar replacement cannot report success")
      Assert.isTrue(Errors.is(failure), "sidecar promotion failure is typed")
    end)
    Assert.isNil(love.filesystem.getInfo(fixture.iconStage), "failed promotion cleans its sidecar stage")
    local retained = love.filesystem.getInfo(fixture.icon) and love.filesystem.read(fixture.icon)
      or love.filesystem.getInfo(fixture.iconBackup) and love.filesystem.read(fixture.iconBackup)
    Assert.equal(retained, oldIcon, "failed replacement preserves the prior known-good PNG")
    Assert.equal(
      love.filesystem.read(fixture.canonical),
      sourceBytes,
      "sidecar work never changes managed source bytes"
    )
    Assert.equal(SaveFs.forVersion(fixture.cart.info.id):read("sentinel.lua"), "SAVE-SENTINEL")
    Assert.equal(CacheFs.forVersion(fixture.cart.info.id):read("derived/sentinel.lua"), "CACHE-SENTINEL")

    replacement:release()
    png:release()
    bytes:release()
  end, { banner = banner.block })
end

function T.icon_publication_tolerates_stale_backup_cleanup_after_promotion()
  local banner = BannerIconFixture.staticBanner()
  Fixture.with(function(fixture)
    Assert.isTrue(love.filesystem.createDirectory("roms"), "managed root setup failed")
    local bytes = love.data.newByteData(fixture.cart.data)
    local prepared = assert(RomArchive.prepare(fixture.cart.info, bytes, fixture.cart.versions))
    Assert.isTrue(RomArchive.publish(prepared), "managed source setup failed")
    local sourceBytes = love.filesystem.read(fixture.canonical)
    local original =
      love.filesystem.newFileData(PngEncoder.encode(32, 32, string.rep("\0", 4096)), "original-icon.png")
    Assert.isTrue(RomArchive.publishIcon(fixture.cart.sha1, original), "original icon setup failed")
    original:release()
    local replacement =
      love.filesystem.newFileData(PngEncoder.encode(32, 32, string.rep("\1", 4096)), "replacement-icon.png")
    withPatched(love.filesystem, "remove", function(remove)
      return function(path)
        if path == fixture.iconBackup then
          return false
        end
        return remove(path)
      end
    end, function()
      local published, failure = RomArchive.publishIcon(fixture.cart.sha1, replacement)
      Assert.isTrue(published, "a promoted canonical icon succeeds despite stale backup cleanup: " .. tostring(failure))
      Assert.isNil(failure, "stale backup cleanup is not a publication failure")
      Assert.equal(
        love.filesystem.read(fixture.icon),
        replacement:getString(),
        "the promoted canonical contains the new PNG"
      )
      Assert.notNil(love.filesystem.getInfo(fixture.iconBackup), "the stale backup remains outside the read path")
    end)
    Assert.isNil(love.filesystem.getInfo(fixture.iconStage), "successful publication leaves no stage")
    Assert.equal(love.filesystem.read(fixture.icon), replacement:getString(), "canonical reads survive the patched cleanup")
    Assert.equal(love.filesystem.read(fixture.canonical), sourceBytes, "sidecar work never changes managed source bytes")
    replacement:release()
    bytes:release()
  end, { banner = banner.block })
end

function T.read_managed_icon_verifies_identity_and_never_writes_a_sidecar()
  local banner = BannerIconFixture.staticBanner()
  Fixture.with(function(fixture)
    Assert.equal(type(RomArchive.readManagedIcon), "function", "verified read-only sidecar recovery is required")
    local bytes = love.data.newByteData(fixture.cart.data)
    local prepared = assert(RomArchive.prepare(fixture.cart.info, bytes, fixture.cart.versions))
    Assert.isTrue(RomArchive.publish(prepared))
    local sourceBytes = love.filesystem.read(fixture.canonical)
    local sha1, png, failure = RomArchive.readManagedIcon(fixture.cart.info.id)
    Assert.isNil(failure, "verified managed icon recovery failed")
    Assert.equal(sha1, fixture.cart.sha1)
    Assert.notNil(png)
    assert(png)
    local width, height, rgba = PngReader.rgba(png:getString())
    Assert.equal(width, 32)
    Assert.equal(height, 32)
    Assert.equal(rgba, banner.rgba)
    Assert.isNil(love.filesystem.getInfo(fixture.icon), "the read-only recovery operation must not publish")
    Assert.equal(love.filesystem.read(fixture.canonical), sourceBytes)
    png:release()

    local otherData = NdsBuilder.build(BannerIconFixture.spec("IPGE", banner.block, "MISMATCHED-BANNER"))
    Assert.isTrue(
      love.filesystem.write(fixture.canonical, ZipBuilder.build({ { name = "game.nds", data = otherData } })),
      "mismatched managed source fixture setup failed"
    )
    local mismatchedBytes = love.filesystem.read(fixture.canonical)
    local mismatchedSha, mismatchedPng, mismatchError = RomArchive.readManagedIcon(fixture.cart.info.id)
    Assert.isNil(mismatchedSha, "a mismatched managed source cannot authorize an icon")
    Assert.isNil(mismatchedPng, "identity failure returns no FileData")
    Assert.isTrue(Errors.is(mismatchError), "identity failure is structured")
    Assert.equal(
      love.filesystem.read(fixture.canonical),
      mismatchedBytes,
      "failed recovery never repairs or replaces source"
    )
    bytes:release()
  end, { banner = banner.block })
end

return { tests = T }
