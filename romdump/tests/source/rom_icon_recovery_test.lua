-- Real background recovery of a verified managed banner. The worker owns only
-- an isolated source snapshot and returns one tiny PNG result; publication and
-- all persistent side effects stay with the caller.

local Assert = require("tests.support.Assert")
local ManagedRomIconFixture = require("tests.support.ManagedRomIconFixture")
local PngReader = require("tests.support.PngReader")
local RomArchive = require("romdump.src.source.RomArchive")
local SaveFs = require("libs.storage.src.SaveFs")
local CacheFs = require("libs.storage.src.CacheFs")
local ZipBuilder = require("tests.support.ZipBuilder")

local T = {}

local function recoveryModule()
  local module = require("romdump.src.source.RomIconRecovery")
  Assert.equal(type(module.start), "function", "recovery must expose one scoped start operation")
  return module
end

local function readIfPresent(path)
  return love.filesystem.getInfo(path) and love.filesystem.read(path) or nil
end

local function waitTerminal(job)
  local deadline = love.timer.getTime() + 20
  while love.timer.getTime() < deadline do
    local state, value, png = job:poll()
    if state ~= nil and state ~= "pending" then
      return state, value, png
    end
    love.timer.sleep(0.002)
  end
  error("timed out waiting for a terminal icon recovery result", 0)
end

local function withRecoveryHost(options, fn)
  options = options or {}
  local realNewThread = love.thread.newThread
  local threads = {}
  local host = { threads = threads }
  love.thread.newThread = function(code)
    if options.catalog ~= nil then
      local injected = string.format(
        [[
local GameVersion = require("romdump.src.source.GameVersion")
GameVersion.VERSIONS.heartgold = {
  id = "heartgold",
  label = "Synthetic HeartGold",
  displayName = "Synthetic HeartGold",
  sha1 = %q,
  gameCode = "IPKE",
  expectedSize = %d,
  cachePrefix = "heartgold/",
}
GameVersion.VERSIONS.soulsilver = {
  id = "soulsilver",
  label = "Synthetic SoulSilver",
  displayName = "Synthetic SoulSilver",
  sha1 = %q,
  gameCode = "IPGE",
  expectedSize = %d,
  cachePrefix = "soulsilver/",
}
]],
        options.catalog.VERSIONS.heartgold.sha1,
        options.catalog.VERSIONS.heartgold.expectedSize,
        options.catalog.VERSIONS.soulsilver.sha1,
        options.catalog.VERSIONS.soulsilver.expectedSize
      )
      local firstLineEnd = assert(code:find("\n", 1, true), "recovery bootstrap must install its worker search path")
      code = code:sub(1, firstLineEnd) .. injected .. code:sub(firstLineEnd + 1)
    elseif options.failWorker then
      code = "-- recovery worker stopped without a result\n"
    end
    local raw = assert(realNewThread(code))
    local thread = { raw = raw }
    function thread:start(...)
      local result = self.raw:start(...)
      if result ~= false then
        threads[#threads + 1] = self
      end
      return result
    end
    function thread:isRunning()
      return self.raw:isRunning()
    end
    function thread:getError()
      if options.failWorker then
        return "injected recovery worker failure"
      end
      return self.raw:getError()
    end
    function thread:wait()
      return self.raw:wait()
    end
    function thread:kill(reason)
      return self.raw:kill(reason)
    end
    return thread
  end
  local ok, err = pcall(fn, host)
  love.thread.newThread = realNewThread
  for _, thread in ipairs(threads) do
    local deadline = love.timer.getTime() + 2
    while thread:isRunning() and love.timer.getTime() < deadline do
      love.timer.sleep(0.002)
    end
    if thread:isRunning() then
      pcall(thread.kill, thread, "icon recovery test cleanup")
    end
    pcall(thread.wait, thread)
  end
  if not ok then
    error(err, 0)
  end
  return host
end

function T.recovery_returns_one_verified_png_without_mutating_managed_data()
  local Recovery = recoveryModule()
  ManagedRomIconFixture.with(function(fixture)
    Assert.equal(type(RomArchive.readManagedIcon), "function", "verified read-only extraction is required")
    Assert.equal(type(RomArchive.publishIcon), "function", "caller-owned sidecar publication is required")
    local edition = fixture.heartgold
    local bytes = love.data.newByteData(edition.cart.data)
    local prepared = assert(RomArchive.prepare(edition.cart.info, bytes, edition.cart.versions))
    Assert.isTrue(RomArchive.publish(prepared))
    bytes:release()
    local saveRoot = assert(love.filesystem.getSaveDirectory())
    Assert.isTrue(
      os.rename(saveRoot .. "/" .. edition.canonical, saveRoot .. "/" .. edition.backup),
      "backup-only managed source setup failed"
    )
    local sourceBefore = readIfPresent(edition.backup)
    Assert.isTrue(
      love.filesystem.write(fixture.soulsilver.canonical, "OTHER-EDITION-SOURCE"),
      "other edition setup failed"
    )
    Assert.isTrue(
      love.filesystem.write(fixture.soulsilver.icon, "OTHER-EDITION-ICON"),
      "other edition icon setup failed"
    )
    SaveFs.forVersion("heartgold"):write("sentinel.lua", "SAVE-SENTINEL")
    CacheFs.forVersion("heartgold"):write("derived/sentinel.lua", "CACHE-SENTINEL")

    local job
    withRecoveryHost({ catalog = fixture.catalog }, function()
      job = assert(Recovery.start("heartgold"))
      local state, romSha1, png = waitTerminal(job)
      Assert.equal(state, "ready")
      Assert.equal(romSha1, edition.cart.sha1)
      Assert.notNil(png, "a ready recovery result owns one encoded PNG")
      assert(png)
      local width, height, rgba = PngReader.rgba(png:getString())
      Assert.equal(width, 32)
      Assert.equal(height, 32)
      Assert.equal(rgba, fixture.heartGoldBanner.rgba)
      Assert.isNil(job:poll(), "a terminal result is delivered exactly once")
      Assert.equal(
        readIfPresent(edition.backup),
        sourceBefore,
        "recovery never rewrites or recompresses managed source"
      )
      Assert.isNil(readIfPresent(edition.canonical), "read-only recovery does not promote a source")
      Assert.isNil(readIfPresent(edition.icon), "the worker cannot publish its sidecar")
      Assert.equal(readIfPresent(fixture.soulsilver.canonical), "OTHER-EDITION-SOURCE")
      Assert.equal(readIfPresent(fixture.soulsilver.icon), "OTHER-EDITION-ICON")
      Assert.equal(SaveFs.forVersion("heartgold"):read("sentinel.lua"), "SAVE-SENTINEL")
      Assert.equal(CacheFs.forVersion("heartgold"):read("derived/sentinel.lua"), "CACHE-SENTINEL")

      Assert.isTrue(RomArchive.publishIcon(romSha1, png), "the caller can publish the matching recovered PNG")
      local publishedWidth, publishedHeight, publishedRgba = PngReader.rgba(assert(readIfPresent(edition.icon)))
      Assert.equal(publishedWidth, width)
      Assert.equal(publishedHeight, height)
      Assert.equal(publishedRgba, rgba)
      png:release()
      job:dispose()
      job:dispose()
      Assert.isNil(job:poll(), "disposal cannot redeliver a consumed result")
    end)
    assert(job, "the recovery job must be started")

    local otherData = fixture.soulsilver.cart.data
    Assert.isTrue(
      love.filesystem.write(edition.backup, ZipBuilder.build({ { name = "game.nds", data = otherData } })),
      "mismatched source setup failed"
    )
    local mismatchedBefore = readIfPresent(edition.backup)
    local publishedBefore = readIfPresent(edition.icon)
    withRecoveryHost({ catalog = fixture.catalog }, function()
      local failedJob = assert(Recovery.start("heartgold"))
      local state, diagnostic, png = waitTerminal(failedJob)
      Assert.equal(state, "failed")
      Assert.notNil(diagnostic, "identity failure returns a diagnostic")
      Assert.isNil(png, "failed recovery returns no FileData")
      Assert.isNil(failedJob:poll(), "failure is also a one-shot terminal result")
      Assert.equal(readIfPresent(edition.backup), mismatchedBefore)
      Assert.equal(readIfPresent(edition.icon), publishedBefore)
      failedJob:dispose()
    end)

    withRecoveryHost({ catalog = fixture.catalog }, function()
      local disposedJob = assert(Recovery.start("heartgold"))
      disposedJob:dispose()
      Assert.isNil(disposedJob:poll(), "dispose before consumption drops the result")
    end)

    Assert.isTrue(love.filesystem.remove(edition.backup), "missing-source fixture setup failed")
    withRecoveryHost({ catalog = fixture.catalog }, function()
      local missingJob = assert(Recovery.start("heartgold"))
      local missingState, diagnostic, png = waitTerminal(missingJob)
      Assert.equal(missingState, "failed")
      Assert.notNil(diagnostic)
      Assert.isNil(png)
      Assert.isNil(missingJob:poll())
      Assert.equal(readIfPresent(edition.icon), publishedBefore, "missing-source recovery keeps the published icon")
      missingJob:dispose()
    end)
  end)
end

function T.unknown_edition_is_rejected_before_a_worker_starts()
  local Recovery = recoveryModule()
  withRecoveryHost({}, function(host)
    Assert.throws(function()
      Recovery.start("unknown-edition")
    end, "recovery accepts only supported edition identities")
    Assert.equal(#host.threads, 0, "an unknown edition must not allocate a worker")
  end)
end

function T.worker_failure_is_one_terminal_diagnostic_without_data()
  local Recovery = recoveryModule()
  withRecoveryHost({ failWorker = true }, function(host)
    local job = assert(Recovery.start("heartgold"))
    local state, diagnostic, png = waitTerminal(job)
    Assert.equal(state, "failed")
    Assert.notNil(diagnostic)
    Assert.isTrue(tostring(diagnostic):find("injected recovery worker failure", 1, true) ~= nil)
    Assert.isNil(png)
    Assert.isNil(job:poll(), "a worker error cannot be delivered twice")
    job:dispose()
    job:dispose()
    Assert.equal(#host.threads, 1, "one scoped recovery creates exactly one worker")
    Assert.isFalse(host.threads[1]:isRunning(), "terminal cleanup leaves no live recovery worker")
  end)
end

return { tests = T }
