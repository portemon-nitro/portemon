-- The real queued importer's commit gate is the cancellation linearization
-- point. The test host pauses the worker after commit is sent and before the
-- managed archive is published.

local Assert = require("tests.support.Assert")
local ManagedRomIconFixture = require("tests.support.ManagedRomIconFixture")
local RomArchive = require("romdump.src.source.RomArchive")
local RomImporter = require("romdump.src.source.RomImporter")

local T = {}

function T.commit_sent_worker_cannot_be_canceled_and_publishes_only_after_release()
  ManagedRomIconFixture.with(function(fixture)
    local edition = fixture.soulsilver
    fixture.host.holdCommit = true
    local importer = fixture.host:importer(edition.cart, nil, "soulsilver")
    importer:queuePath(edition.originalPath)
    fixture.host:commitGate(importer)
    Assert.isTrue(importer._commitSent)
    Assert.isFalse(importer:status().canCancel, "commit-sent is not cancellable")
    if importer:status().canCancel then
      importer:cancelQueued()
    end
    Assert.isTrue(importer._commitSent, "the App admissibility check leaves publication authorized")
    Assert.isNil(RomArchive.recoverablePath(edition.cart.sha1), "the held worker has not published yet")
    fixture.host:releaseCommit()
    fixture.host:finish(importer, RomImporter.STATES.COMPLETE)
    Assert.notNil(RomArchive.recoverablePath(edition.cart.sha1), "the authorized worker publishes its managed source")
  end)
end

return { tests = T }
