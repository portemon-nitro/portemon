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
local CompilerPool = require("romdump.src.build.CompilerPool")
local RomArchive = require("romdump.src.source.RomArchive")

local T = {}

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
  end)
end

return { tests = T }
