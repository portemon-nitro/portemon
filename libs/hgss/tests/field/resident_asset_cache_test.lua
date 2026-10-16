-- Unit tests for the shared byte-counted idle lease kernel: one keyed table
-- with recency ordering, single-use borrowing leases, an owner-supplied busy
-- check for natively held resources, and exact-once physical release.
-- Synthetic values only; nothing here touches a ROM or a renderer.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local FieldMessageCache = require("libs.assets.src.field.FieldMessageCache")
local FieldMessageProvider = require("libs.hgss.src.interaction.FieldMessageProvider")

local T = {}

-- Loads the kernel. The kernel module does not exist until bounded idle
-- retention lands, so every test below fails on this message -- naming the
-- missing ownership behavior -- instead of failing the suite load.
local function kernel()
  local ok, mod = pcall(require, "libs.hgss.src.field.ResidentAssetCache")
  Assert.isTrue(ok and type(mod) == "table", "shared byte-counted idle lease kernel is not implemented")
  return mod
end

local function releases()
  local released = {}
  local function onRelease(value)
    released[#released + 1] = value
  end
  return released, onRelease
end

local function statsOf(cache)
  local stats = cache:stats()
  Assert.equal(type(stats), "table", "the kernel reports its byte totals through stats")
  Assert.equal(type(stats.idleBytes), "number", "stats carries the idle byte total")
  Assert.equal(type(stats.pinnedBytes), "number", "stats carries the borrowed byte total")
  return stats
end

function T.evicts_only_the_least_recently_used_idle_entry_under_a_byte_budget()
  local Cache = kernel()
  local released, onRelease = releases()
  local cache = Cache.new({ idleByteLimit = 7, release = onRelease })
  local first = { name = "first" }
  local second = { name = "second" }
  local third = { name = "third" }
  cache:publish("first", first, 2)
  cache:publish("second", second, 3)

  local lease = cache:borrow("first")
  Assert.equal(type(lease), "table", "a borrow hands out an opaque lease object")
  Assert.isTrue(lease ~= first, "a lease is never the borrowed value itself")
  cache:touch("second")
  Assert.isTrue(cache:find("second") == second, "a touched entry stays findable by identity")
  local stats = statsOf(cache)
  Assert.equal(stats.pinnedBytes, 2, "the borrowed entry counts as borrowed bytes")
  Assert.equal(stats.idleBytes, 3, "touching moves recency without moving bytes")

  cache:publish("third", third, 5)
  cache:trim()
  Assert.equal(#released, 1, "one entry leaves under the byte budget")
  Assert.isTrue(released[1] == second, "only the least-recently-used unleased entry is released")
  Assert.isTrue(cache:find("first") == first, "the borrowed entry survives the trim")
  Assert.isNil(cache:find("second"), "the released entry is gone")
  Assert.isTrue(cache:find("third") == third, "the newest idle entry survives the trim")
  stats = statsOf(cache)
  Assert.equal(stats.pinnedBytes, 2, "borrowed bytes are unchanged by the trim")
  Assert.equal(stats.idleBytes, 5, "only the surviving idle entry counts after the trim")

  Assert.isTrue(cache:returnLease(lease), "returning the lease drops its reference")
  stats = statsOf(cache)
  Assert.equal(stats.pinnedBytes, 0, "no borrowed bytes remain after the return")
  Assert.equal(stats.idleBytes, 7, "the returned entry rejoins the idle bytes")
  local again = cache:borrow("first")
  Assert.isTrue(again ~= nil and again ~= lease, "a returned key borrows afresh")
  Assert.isTrue(cache:find("first") == first, "the reborrowed entry is still the same value")
  Assert.isTrue(cache:returnLease(again), "the fresh lease returns cleanly")
  Assert.equal(#released, 1, "the return and reborrow cycle releases nothing further")
end

function T.repeated_returns_of_one_lease_change_nothing_after_the_first()
  local Cache = kernel()
  local released, onRelease = releases()
  local cache = Cache.new({ idleByteLimit = 0, release = onRelease })
  local value = { name = "shared" }
  cache:publish("shared", value, 4)
  local one = cache:borrow("shared")
  local two = cache:borrow("shared")
  Assert.isTrue(one ~= two, "competing borrows of one key hold distinct leases")
  Assert.isTrue(cache:returnLease(one), "the first return drops its reference")
  Assert.isFalse(cache:returnLease(one), "returning the same lease twice reports failure")
  cache:trim()
  Assert.equal(#released, 0, "the still-borrowed entry survives a zero-byte trim")
  Assert.isTrue(cache:find("shared") == value, "the still-borrowed entry stays findable")
  Assert.isTrue(cache:returnLease(two), "the second lease still returns cleanly")
  cache:trim()
  Assert.equal(#released, 1, "the fully returned entry trims exactly once")
  Assert.isTrue(released[1] == value, "the trimmed entry is the published value")
end

function T.a_failing_release_detaches_the_entry_and_rethrows()
  local Cache = kernel()
  local released = {}
  local cache = Cache.new({
    idleByteLimit = 0,
    release = function(value)
      if value.name == "bad" then
        error("release failure", 0)
      end
      released[#released + 1] = value
    end,
  })
  local good = { name = "good" }
  local bad = { name = "bad" }
  cache:publish("good", good, 2)
  cache:publish("bad", bad, 3)
  local err = Assert.throws(function()
    cache:trim()
  end, "a failing release aborts the trim loudly")
  Assert.equal(err, "release failure", "the release failure propagates to the trim caller")
  Assert.equal(#released, 1, "the entry ahead of the failure still releases exactly once")
  Assert.isTrue(released[1] == good, "the entry ahead of the failure is the older idle entry")
  Assert.isNil(cache:find("good"), "the released entry is gone")
  Assert.isNil(cache:find("bad"), "the failed entry detaches instead of lingering")
  local stats = statsOf(cache)
  Assert.equal(stats.idleBytes, 0, "no detached entry counts toward the byte totals")
  cache:trim()
  Assert.equal(#released, 1, "a second trim releases nothing twice")
  cache:clear()
  Assert.equal(#released, 1, "disposal after a failed release releases nothing twice")
end

function T.rejected_publications_never_enter_the_kernel()
  local Cache = kernel()
  local released, onRelease = releases()
  local cache = Cache.new({ idleByteLimit = 64, release = onRelease })
  local value = { name = "kept" }
  cache:publish("kept", value, 2)
  Assert.throws(function()
    cache:publish("kept", { name = "replacement" }, 2)
  end, "a duplicate key never replaces its entry")
  Assert.isTrue(cache:find("kept") == value, "the original entry survives a duplicate publication")
  Assert.throws(function()
    cache:publish("empty", { name = "empty" }, 0)
  end, "a zero byte weight never becomes an entry")
  Assert.isNil(cache:find("empty"), "a rejected zero-weight key stays absent")
  Assert.throws(function()
    cache:publish("negative", { name = "negative" }, -3)
  end, "a negative byte weight never becomes an entry")
  Assert.isNil(cache:find("negative"), "a rejected negative-weight key stays absent")
  Assert.throws(function()
    cache:borrow("absent")
  end, "borrowing an unknown key fails instead of minting a lease")
  Assert.isNil(cache:find("absent"), "a failed borrow leaves no entry behind")
  Assert.equal(#released, 0, "no rejection releases anything")
  local stats = statsOf(cache)
  Assert.equal(stats.idleBytes, 2, "only the admitted entry counts toward the byte totals")
end

function T.disposal_rejects_borrowed_leases_then_releases_each_idle_entry_exactly_once()
  local Cache = kernel()
  local released, onRelease = releases()
  local cache = Cache.new({ idleByteLimit = 64, release = onRelease })
  local first = { name = "first" }
  local second = { name = "second" }
  cache:publish("first", first, 2)
  cache:publish("second", second, 3)
  local lease = cache:borrow("first")
  Assert.throws(function()
    cache:clear()
  end, "disposal with a borrowed lease fails instead of invalidating the borrower")
  Assert.isTrue(cache:find("first") == first, "the refused disposal keeps every entry")
  Assert.isTrue(cache:returnLease(lease), "the borrower still returns its lease after the refused disposal")
  cache:clear()
  Assert.equal(#released, 2, "disposal releases every idle entry")
  local seen = {}
  for _, value in ipairs(released) do
    seen[value.name] = (seen[value.name] or 0) + 1
  end
  Assert.equal(seen.first, 1, "the first entry releases exactly once")
  Assert.equal(seen.second, 1, "the second entry releases exactly once")
  Assert.isNil(cache:find("first"), "disposal empties the kernel")
  Assert.isNil(cache:find("second"), "disposal empties the kernel")
  cache:clear()
  Assert.equal(#released, 2, "a second disposal releases nothing twice")
  local stats = statsOf(cache)
  Assert.equal(stats.idleBytes, 0, "an emptied kernel counts no idle bytes")
  Assert.equal(stats.pinnedBytes, 0, "an emptied kernel counts no borrowed bytes")
end

function T.busy_entries_survive_a_zero_budget_until_they_go_quiet()
  local Cache = kernel()
  local released, onRelease = releases()
  local sounding = true
  local busyValue = { name = "sounding" }
  local quietValue = { name = "quiet" }
  local cache = Cache.new({
    idleByteLimit = 0,
    release = onRelease,
    busy = function(value)
      return value == busyValue and sounding
    end,
  })
  cache:publish("sounding", busyValue, 4)
  cache:publish("quiet", quietValue, 3)
  cache:trim()
  Assert.equal(#released, 1, "a zero budget releases only what is not busy")
  Assert.isTrue(released[1] == quietValue, "the evicted entry is the quiet one")
  Assert.isTrue(cache:find("sounding") == busyValue, "the busy entry survives its own eviction pass")
  cache:trim()
  Assert.equal(#released, 1, "a second pass still takes nothing live")
  sounding = false
  cache:trim()
  Assert.equal(#released, 2, "the quieted entry becomes evictable")
  Assert.isTrue(released[2] == busyValue, "the quieted entry releases exactly once")
  Assert.isNil(cache:find("sounding"), "the released entry is gone")
  local stats = statsOf(cache)
  Assert.equal(stats.idleBytes, 0, "no resident bytes remain after the final trim")
end

local function messageCacheWith(ids)
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  for _, bankId in ipairs(ids) do
    cache:writeLua(FieldMessageCache.bankPath(bankId), {
      schema = FieldMessageCache.SCHEMA,
      bankId = bankId,
      messageCount = 0,
      messages = {},
    })
  end
  return cache
end

function T.borrowed_entries_survive_pressure_like_message_banks()
  -- The message bank owner, used here exactly as shipped and never
  -- redirected: a repeated acquire shares one artifact, a matched release
  -- pair unpins it, and only then does pressure from a new bank evict it.
  local messages = assert(FieldMessageProvider.new(messageCacheWith({ 7, 8 }), { maxCachedBanks = 1 }))
  local bank = assert(messages:acquireBank(7))
  Assert.isTrue(messages:acquireBank(7) == bank, "a second acquire shares the bank artifact")
  messages:releaseBank(7)
  messages:releaseBank(7)
  messages:acquireBank(8)
  Assert.equal(messages:stats().disposals, 1, "pressure evicts the released bank")
  local evicted, err = messages:get(7, 0)
  Assert.isNil(evicted, "the evicted bank is no longer acquired")
  Assert.isTrue(Errors.is(err))
  Assert.equal(err.code, "MESSAGE_BANK_NOT_ACQUIRED")

  -- The lease kernel answers the same pressure the same way: a borrowed
  -- entry survives a trim that takes every unborrowed byte, and each entry
  -- still releases exactly once once its borrower lets go.
  local Cache = kernel()
  local released, onRelease = releases()
  local pressured = Cache.new({ idleByteLimit = 0, release = onRelease })
  local held = { name = "held" }
  local idle = { name = "idle" }
  pressured:publish("held", held, 2)
  pressured:publish("idle", idle, 2)
  local hold = pressured:borrow("held")
  pressured:trim()
  Assert.equal(#released, 1, "pressure takes only the unborrowed entry")
  Assert.isTrue(released[1] == idle, "pressure takes the unborrowed entry")
  Assert.isTrue(pressured:find("held") == held, "the borrowed entry survives pressure")
  Assert.isTrue(pressured:returnLease(hold), "the borrower lets go")
  pressured:trim()
  Assert.equal(#released, 2, "the returned entry trims after its return")
  Assert.isTrue(released[2] == held, "the returned entry is the borrowed value")
end

return { tests = T }
