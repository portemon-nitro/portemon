local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local RomSource = require("romdump.src.source.RomSource")
local NdsRom = require("romdump.src.source.NdsRom")
local ZipBuilder = require("tests.support.ZipBuilder")
local NdsBuilder = require("tests.support.NdsBuilder")
local DumpFixture = require("tests.support.DumpFixture")

-- SHA-1("abc") — the canonical test vector.
local ABC_SHA1 = "a9993e364706816aba3e25717850c26c9cd0d89d"

local T = {}

-- A version catalog that recognizes exactly the given SHA-1 (as DumpFixture does).
local function versionsFor(sha1)
  return {
    forSha1 = function(h)
      return h == sha1 and {} or nil
    end,
  }
end

-- The mount point RomSource mounts zip archives at (exported by RomSource so
-- a leaked mount is directly observable).
local MOUNT_POINT = RomSource.MOUNT_POINT

-- Run fn with target[field] temporarily replaced by makePatched(original),
-- restoring the original in all cases so a failed assertion cannot leak the
-- patch into later tests.
local function withPatched(target, field, makePatched, fn)
  local original = target[field]
  target[field] = makePatched(original)
  local ok, err = pcall(fn)
  target[field] = original
  if not ok then
    error(err, 0)
  end
end

-- One atomically acquired scratch directory per invocation holds this case's
-- fixture file. The platform grants exclusivity; no guessed or shared path is
-- used, and only the acquired root is ever removed.
local function shellQuote(value)
  return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function commandSucceeded(status)
  return status == 0 or status == true
end

local function acquireScratchRoot()
  local handle = assert(io.popen("mktemp -d"), "mktemp -d could not start")
  local path = (handle:read("*l") or ""):gsub("^%s+", ""):gsub("%s+$", "")
  local closed = handle:close()
  assert(commandSucceeded(closed), "mktemp -d did not exit successfully")
  assert(path ~= "", "mktemp -d produced no path")
  return path
end

local function removeOwnedRoot(root)
  assert(root ~= "" and root ~= "/", "refusing to remove an unowned path")
  local status = os.execute("rm -rf -- " .. shellQuote(root))
  assert(commandSucceeded(status), "owned scratch cleanup failed: " .. root)
end

-- Runs fn(root) with a fresh owned scratch root, always releasing exactly
-- that root. A body failure keeps its original error; a cleanup failure
-- after a passing body fails the case.
local function withOwnedRoot(fn)
  local root = acquireScratchRoot()
  local ok, err = pcall(fn, root)
  if ok then
    removeOwnedRoot(root)
    return
  end
  pcall(removeOwnedRoot, root)
  error(err, 0)
end

function T.from_string_reports_size_and_name()
  local s = RomSource.fromString("abcdef", "sample.nds")
  Assert.equal(s:size(), 6)
  Assert.equal(s:displayName(), "sample.nds")
end

function T.read_is_zero_based()
  local s = RomSource.fromString("abcdef")
  Assert.equal(s:read(0, 3), "abc")
  Assert.equal(s:read(3, 3), "def")
end

function T.read_out_of_range_returns_nil_err()
  local s = RomSource.fromString("abc")
  local data, err = s:read(2, 5)
  Assert.isNil(data)
  Assert.notNil(err)
  local d2, e2 = s:read(-1, 1)
  Assert.isNil(d2)
  Assert.notNil(e2)
end

function T.sha1_is_lowercase_hex_and_cached()
  local s = RomSource.fromString("abc")
  local first = s:sha1()
  Assert.equal(first, ABC_SHA1)
  Assert.equal(s:sha1(), first)
end

function T.release_is_idempotent_and_frees_reads()
  local s = RomSource.fromString("abc")
  s:release()
  s:release()
  local data, err = s:read(0, 1)
  Assert.isNil(data)
  Assert.notNil(err)
end

function T.from_path_reads_file_bytes()
  local seenRoot = nil
  withOwnedRoot(function(root)
    seenRoot = root
    local path = root .. "/input.nds"
    local writer = assert(io.open(path, "wb"))
    writer:write("abc")
    assert(writer:close())

    local s, err = RomSource.fromPath(path)
    Assert.notNil(s, err and tostring(err))
    assert(s)
    local ok, readErr = pcall(function()
      Assert.equal(s:size(), 3)
      Assert.equal(s:read(0, 3), "abc")
      Assert.equal(s:sha1(), ABC_SHA1)
    end)
    s:release()
    if not ok then
      error(readErr, 0)
    end
  end)
  assert(seenRoot ~= nil, "the owned root must have been acquired")
  Assert.isNil(io.open(seenRoot .. "/input.nds", "r"), "the owned fixture must not survive the case")
end

-- A body failure after acquisition still releases the owned root, and the
-- original failure -- not cleanup -- is what the case reports.
function T.owned_scratch_cleanup_preserves_the_body_failure()
  local seenRoot = nil
  local err = Assert.throws(function()
    withOwnedRoot(function(root)
      seenRoot = root
      local writer = assert(io.open(root .. "/owned.txt", "w"))
      writer:write("owned")
      assert(writer:close())
      error("injected body failure")
    end)
  end)
  Assert.isTrue(tostring(err):find("injected body failure", 1, true) ~= nil, "the original error must survive")
  assert(seenRoot ~= nil, "the owned root must have been acquired")
  Assert.isNil(io.open(seenRoot .. "/owned.txt", "r"), "the owned root must be released after failure")
end

-- A cleanup failure after a passing body fails the case instead of
-- passing silently. The stranded owned root is released by the case itself
-- so the probe leaves no residue.
function T.owned_scratch_reports_cleanup_failure_after_a_passing_body()
  local realExecute = os.execute
  local failedRoot = nil
  local ok, err = pcall(function()
    local thrown = Assert.throws(function()
      withPatched(os, "execute", function()
        return function(command)
          failedRoot = command:match("^rm %-rf %-%- '(.*)'$")
          return false
        end
      end, function()
        withOwnedRoot(function(root)
          local writer = assert(io.open(root .. "/owned.txt", "w"))
          writer:write("owned")
          assert(writer:close())
        end)
      end)
    end)
    Assert.isTrue(tostring(thrown):find("owned scratch cleanup failed", 1, true) ~= nil, "cleanup failure must surface")
  end)
  if failedRoot ~= nil then
    realExecute("rm -rf -- '" .. failedRoot:gsub("'", "'\\''") .. "'")
  end
  if not ok then
    error(err, 0)
  end
end

-- A failed acquisition never invokes the body and never removes anything.
function T.owned_scratch_acquisition_failure_removes_nothing()
  local removed = {}
  withPatched(os, "execute", function(original)
    return function(command)
      removed[#removed + 1] = command
      return original(command)
    end
  end, function()
    withPatched(io, "popen", function()
      return function()
        return nil, "injected mktemp failure"
      end
    end, function()
      local err = Assert.throws(function()
        withOwnedRoot(function()
          error("the body must never run without a root")
        end)
      end)
      Assert.isTrue(tostring(err):find("mktemp", 1, true) ~= nil, "acquisition must fail loudly")
    end)
  end)
  Assert.equal(#removed, 0, "a failed acquisition must not remove anything")
end

function T.from_path_missing_returns_nil_err()
  local s, err = RomSource.fromPath("/no/such/file.nds")
  Assert.isNil(s)
  Assert.notNil(err)
end

-- Walks a zip (including nested dirs), skips non-.nds junk, and returns the
-- compatible ROM's bytes.
function T.from_zip_finds_compatible_nds()
  local nds = NdsBuilder.build(DumpFixture.spec())
  local sha1 = RomSource.fromString(nds):sha1()
  local zip = ZipBuilder.build({
    { name = "Vimm's Lair.txt", data = "junk" },
    { name = "roms/Pokemon - HeartGold (USA).nds", data = nds },
  })
  local s, err = RomSource.fromZipData(zip, "rom.zip", versionsFor(sha1))
  Assert.notNil(s, err and tostring(err))
  assert(s)
  Assert.equal(s:size(), #nds)
  Assert.equal(s:sha1(), sha1)
  Assert.isTrue(s:read(0, #nds) == nds, "zip-extracted bytes must match the .nds")
end

-- When several .nds are present, the SHA-1-supported one wins.
function T.from_zip_prefers_supported_nds()
  local good = NdsBuilder.build(DumpFixture.spec())
  local goodSha = RomSource.fromString(good):sha1()
  local zip = ZipBuilder.build({
    { name = "patched.nds", data = "not a real rom" },
    { name = "good.nds", data = good },
  })
  local s = assert(RomSource.fromZipData(zip, "rom.zip", versionsFor(goodSha)))
  Assert.equal(s:sha1(), goodSha)
end

-- No .nds inside → a structured error, not a crash.
function T.from_zip_without_nds_errors()
  local zip = ZipBuilder.build({ { name = "a.txt", data = "x" }, { name = "b.sav", data = "y" } })
  local s, err = RomSource.fromZipData(zip, "rom.zip", versionsFor("none"))
  Assert.isNil(s)
  Assert.equal(assert(err).code, "ZIP_NO_NDS")
end

-- A single unsupported .nds is still returned so NdsRom.open can report its hash.
function T.from_zip_falls_back_to_first_nds()
  local zip = ZipBuilder.build({ { name = "only.nds", data = "unsupported bytes" } })
  local s = assert(RomSource.fromZipData(zip, "rom.zip", versionsFor("none")))
  Assert.equal(s:read(0, 17), "unsupported bytes")
end

-- Dropped files arrive as LÖVE File objects; verify the wiring against a stub.
function T.from_dropped_file_reads_contents()
  local stub = {
    open = function()
      return true
    end,
    read = function()
      return "abc"
    end,
    close = function()
      return true
    end,
    getFilename = function()
      return "dropped.nds"
    end,
  }
  local s = assert(RomSource.fromDroppedFile(stub))
  Assert.equal(s:displayName(), "dropped.nds")
  Assert.equal(s:read(0, 3), "abc")
end

-- A failed read of the dropped file is a structured read error, not an assert
-- from constructing a source with nil bytes.
function T.from_dropped_file_read_failure_returns_structured_error()
  local stub = {
    open = function()
      return true
    end,
    read = function()
      return nil
    end,
    close = function()
      return true
    end,
    getFilename = function()
      return "dropped.nds"
    end,
  }
  local s, err = RomSource.fromDroppedFile(stub)
  Assert.isNil(s)
  Assert.equal(assert(err).code, "ROM_READ_FAILED")
end

-- read() requires finite integer offsets and lengths: fractions, NaN,
-- infinities, negatives, and out-of-range values all return a structured read
-- error instead of reaching string.sub.
function T.read_rejects_fractional_nan_infinite_and_negative_arguments()
  local s = RomSource.fromString("abcdef")
  local invalid = {
    { 0.5, 1 },
    { 0, 0.5 },
    { math.huge, 0 },
    { 0, math.huge },
    { -math.huge, 0 },
    { 0, -math.huge },
    { 0 / 0, 1 },
    { 1, 0 / 0 },
    { -1, 1 },
    { 0, -1 },
    { 3, 4 },
  }
  for _, bad in ipairs(invalid) do
    local label = string.format("offset %s length %s", tostring(bad[1]), tostring(bad[2]))
    local data, err = s:read(bad[1], bad[2])
    Assert.isNil(data, label .. " must not return data")
    Assert.equal(assert(err).code, "ROM_READ_OUT_OF_BOUNDS", label)
  end
  Assert.equal(s:read(0, 6), "abcdef")
  Assert.equal(s:read(4, 2), "ef")
end

-- A failed .nds read inside the zip is a structured error, and the archive is
-- unmounted before the error is returned.
function T.zip_read_failure_returns_structured_error_and_unmounts()
  local zip = ZipBuilder.build({ { name = "only.nds", data = "x" } })
  local s, err
  withPatched(love.filesystem, "read", function()
    return function()
      return nil
    end
  end, function()
    s, err = RomSource.fromZipData(zip, "rom.zip", versionsFor("none"))
  end)
  Assert.isNil(s)
  Assert.equal(assert(err).code, "ZIP_READ_FAILED")
  Assert.isNil(love.filesystem.getInfo(MOUNT_POINT), "mount must be unmounted after the read failure")
end

-- When the recursive traversal itself throws, the archive is still unmounted,
-- and the next import sees only its own zip: a leaked mount would otherwise
-- shadow the new archive and silently serve stale bytes.
function T.zip_traversal_failure_unmounts_the_archive()
  local staleZip = ZipBuilder.build({ { name = "stale.nds", data = "stale bytes" } })
  local good = NdsBuilder.build(DumpFixture.spec())
  local goodSha = RomSource.fromString(good):sha1()
  local goodZip = ZipBuilder.build({ { name = "roms/good.nds", data = good } })

  local ok, err
  withPatched(love.filesystem, "read", function()
    return function()
      error("boom: injected traversal failure")
    end
  end, function()
    ok, err = pcall(RomSource.fromZipData, staleZip, "stale.zip", versionsFor("none"))
  end)
  Assert.isFalse(ok, "the traversal error must propagate")
  Assert.isTrue(tostring(err):match("boom"), "the original error must be rethrown")
  Assert.isNil(love.filesystem.getInfo(MOUNT_POINT), "mount must be unmounted after the thrown traversal")

  local s, err2 = RomSource.fromZipData(goodZip, "good.zip", versionsFor(goodSha))
  Assert.notNil(s, err2 and tostring(err2))
  assert(s)
  Assert.equal(s:sha1(), goodSha, "a leaked mount must not shadow the next import")
end

-- Scanning stops at the first supported candidate: entries after it are never
-- read, so a poisoned later entry cannot fail an import that already matched.
-- (love.filesystem lists zip entries in its own deterministic order; for this
-- exact name pair "good.nds" is listed before "poison.nds".)
function T.zip_scan_stops_at_the_first_supported_candidate()
  local good = NdsBuilder.build(DumpFixture.spec())
  local goodSha = RomSource.fromString(good):sha1()
  local zip = ZipBuilder.build({
    { name = "good.nds", data = good },
    { name = "poison.nds", data = "unsupported" },
  })
  local s, err
  withPatched(love.filesystem, "read", function(read)
    return function(path)
      if path:match("poison") then
        error("must not read entries after the first supported candidate")
      end
      return read(path)
    end
  end, function()
    s, err = RomSource.fromZipData(zip, "rom.zip", versionsFor(goodSha))
  end)
  Assert.notNil(s, err and tostring(err))
  assert(s)
  Assert.equal(s:sha1(), goodSha)
end

-- Only the candidates up to the first supported match are read at all; the
-- rest of the archive is never pulled into memory. ("good.nds" is listed
-- first among these names, so exactly one .nds is read.)
function T.zip_scan_reads_only_candidates_up_to_the_first_supported()
  local good = NdsBuilder.build(DumpFixture.spec())
  local goodSha = RomSource.fromString(good):sha1()
  local zip = ZipBuilder.build({
    { name = "good.nds", data = good },
    { name = "u1.nds", data = "one" },
    { name = "u2.nds", data = "two" },
    { name = "u3.nds", data = "three" },
  })
  local reads = 0
  local s, err
  withPatched(love.filesystem, "read", function(read)
    return function(path)
      reads = reads + 1
      return read(path)
    end
  end, function()
    s, err = RomSource.fromZipData(zip, "rom.zip", versionsFor(goodSha))
  end)
  Assert.notNil(s, err and tostring(err))
  assert(s)
  Assert.equal(reads, 1, "only the matching candidate may be read")
  Assert.equal(s:sha1(), goodSha)
end

-- Unsupported candidates are released as they are replaced; at most the
-- current candidate and the first fallback are retained.
function T.zip_scan_releases_replaced_candidates_and_keeps_one_fallback()
  local created, released = 0, 0
  local zip = ZipBuilder.build({
    { name = "u1.nds", data = "one" },
    { name = "u2.nds", data = "two" },
    { name = "u3.nds", data = "three" },
  })
  local s, err
  withPatched(RomSource, "fromString", function(original)
    return function(data, name)
      created = created + 1
      local source = original(data, name)
      local originalRelease = source.release
      source.release = function(self)
        released = released + 1
        return originalRelease(self)
      end
      return source
    end
  end, function()
    s, err = RomSource.fromZipData(zip, "rom.zip", versionsFor("none"))
  end)
  Assert.notNil(s, err and tostring(err))
  assert(s)
  Assert.equal(created, 3)
  Assert.equal(released, 2, "replaced candidates must be released")
  -- "u1.nds" lists first among these names, so it is the retained fallback.
  Assert.equal(s:read(0, 3), "one", "the first .nds is the retained fallback")
end

-- A view over one immutable shared buffer must present exactly the same
-- identity, size, and slice bytes as a string view over identical bytes, and
-- must hand back the borrowed buffer itself instead of a copy.
local function requireSharedBufferView()
  Assert.isTrue(
    type(RomSource.fromByteData) == "function",
    "expected a shared-buffer source view that presents the same bytes without copying the ROM"
  )
end

local function sharedTestBytes()
  return NdsBuilder.build(DumpFixture.spec())
end

function T.byte_data_view_matches_the_string_view_for_identity_and_slices()
  requireSharedBufferView()
  local data = sharedTestBytes()
  local bytes = love.data.newByteData(data)
  local fromData = RomSource.fromByteData(bytes, "rom.nds")
  local fromString = RomSource.fromString(data, "rom.nds")
  Assert.isTrue(type(fromData.byteData) == "function", "expected the view to hand back its borrowed buffer")
  Assert.equal(fromData:size(), #data)
  Assert.equal(fromData:sha1(), fromString:sha1())
  Assert.equal(fromData:read(0, 4), fromString:read(0, 4))
  Assert.equal(fromData:read(0, #data), data)
  Assert.equal(fromData:read(#data - 3, 3), data:sub(-3))
  Assert.isTrue(fromData:byteData() == bytes, "the view must borrow the shared buffer instead of copying it")
end

function T.byte_data_read_rejects_out_of_range_like_the_string_view()
  requireSharedBufferView()
  local data = sharedTestBytes()
  local fromData = RomSource.fromByteData(love.data.newByteData(data), "rom.nds")
  local fromString = RomSource.fromString(data, "rom.nds")
  local invalid = {
    { -1, 1 },
    { 0, -1 },
    { 0, #data + 1 },
    { #data, 1 },
    { 0.5, 1 },
    { 0, 0.5 },
  }
  for _, bad in ipairs(invalid) do
    local label = string.format("offset %s length %s", tostring(bad[1]), tostring(bad[2]))
    local viewData, viewErr = fromData:read(bad[1], bad[2])
    local stringData, stringErr = fromString:read(bad[1], bad[2])
    Assert.isNil(viewData, label .. " must not return data")
    Assert.isNil(stringData, label .. " must not return data")
    Assert.equal(assert(viewErr).code, "ROM_READ_OUT_OF_BOUNDS", label)
    Assert.equal(assert(stringErr).code, assert(viewErr).code, label)
  end
end

-- Releasing one borrowed view must never release the shared buffer: a peer
-- view over the same buffer keeps reading, while the released view reports
-- the release and no longer hands out the buffer.
function T.releasing_one_borrowed_view_keeps_peer_views_on_the_same_buffer()
  requireSharedBufferView()
  local data = sharedTestBytes()
  local shared = love.data.newByteData(data)
  local first = RomSource.fromByteData(shared, "first.nds")
  local second = RomSource.fromByteData(shared, "second.nds")
  Assert.isTrue(
    type(first.byteData) == "function" and type(second.byteData) == "function",
    "expected both views to hand back their borrowed buffer"
  )
  first:release()
  Assert.equal(second:read(0, 4), data:sub(1, 4))
  Assert.isTrue(second:byteData() == shared, "a peer view must keep the shared buffer after a release")
  local releasedData, releasedErr = first:read(0, 1)
  Assert.isNil(releasedData)
  Assert.equal(assert(releasedErr).code, "ROM_RELEASED")
  local ok = pcall(function()
    return first:byteData()
  end)
  Assert.isFalse(ok, "a released view must no longer hand out the shared buffer")
end

local function requireOrigin()
  local probe = RomSource.fromString("x")
  Assert.isTrue(
    type(probe.origin) == "function",
    "expected every source to describe its container without inventing a location"
  )
end

function T.origin_describes_memory_views_without_inventing_a_location()
  requireSharedBufferView()
  requireOrigin()
  local data = sharedTestBytes()
  local view = RomSource.fromByteData(love.data.newByteData(data), "rom.nds")
  local origin = view:origin()
  Assert.equal(origin.kind, "nds")
  Assert.isTrue(origin.path == false, "a view with no durable location must report an explicit false")
  Assert.isTrue(origin.zipEntry == false, "a bare view has no archive member")
  Assert.equal(origin.displayName, "rom.nds")
  local stringOrigin = RomSource.fromString(data, "label.nds"):origin()
  Assert.equal(stringOrigin.kind, "nds")
  Assert.isTrue(stringOrigin.path == false, "a string view has no durable location")
  Assert.isTrue(stringOrigin.zipEntry == false, "a string view has no archive member")
  Assert.equal(stringOrigin.displayName, "label.nds")
end

function T.origin_reports_filesystem_and_dropped_containers()
  requireOrigin()
  withOwnedRoot(function(root)
    local romPath = root .. "/game.nds"
    local writer = assert(io.open(romPath, "wb"))
    writer:write("abc")
    assert(writer:close())
    local fromPath = assert(RomSource.fromPath(romPath))
    local pathOrigin = fromPath:origin()
    Assert.equal(pathOrigin.kind, "nds")
    Assert.equal(pathOrigin.path, romPath)
    Assert.isTrue(pathOrigin.zipEntry == false, "a bare file has no archive member")
    Assert.equal(pathOrigin.displayName, "game.nds")

    local zipPath = root .. "/game.zip"
    local zipBytes = ZipBuilder.build({ { name = "only.nds", data = "unsupported bytes" } })
    local zipWriter = assert(io.open(zipPath, "wb"))
    zipWriter:write(zipBytes)
    assert(zipWriter:close())
    local fromZip = assert(RomSource.fromPath(zipPath))
    local zipOrigin = fromZip:origin()
    Assert.equal(zipOrigin.kind, "zip")
    Assert.equal(zipOrigin.path, zipPath)
    Assert.isTrue(
      type(zipOrigin.zipEntry) == "string" and zipOrigin.zipEntry:match("%.nds$") ~= nil,
      "a zip source must name its selected member"
    )
    Assert.equal(zipOrigin.displayName, "game.zip")
  end)

  local stub = {
    open = function()
      return true
    end,
    read = function()
      return "abc"
    end,
    close = function()
      return true
    end,
    getFilename = function()
      return "dropped.nds"
    end,
  }
  local dropped = assert(RomSource.fromDroppedFile(stub))
  local droppedOrigin = dropped:origin()
  Assert.equal(droppedOrigin.kind, "nds")
  Assert.isTrue(droppedOrigin.path == false, "a dropped file has no durable location")
  Assert.isTrue(droppedOrigin.zipEntry == false, "a dropped bare file has no archive member")
  Assert.equal(droppedOrigin.displayName, "dropped.nds")
end

function T.byte_data_size_and_identity_survive_release_when_cached()
  requireSharedBufferView()
  local data = sharedTestBytes()
  local view = RomSource.fromByteData(love.data.newByteData(data), "rom.nds")
  local sha1 = view:sha1()
  view:release()
  view:release()
  Assert.equal(view:size(), #data, "a released view keeps its size")
  Assert.equal(view:sha1(), sha1, "a released view keeps its cached identity")
  local _, err = view:read(0, 1)
  Assert.equal(assert(err).code, "ROM_RELEASED")
end

function T.byte_data_zero_length_slice_is_empty()
  requireSharedBufferView()
  local data = sharedTestBytes()
  local view = RomSource.fromByteData(love.data.newByteData(data), "rom.nds")
  Assert.equal(view:read(0, 0), "")
  Assert.equal(view:read(#data, 0), "")
end

function T.string_view_has_no_shared_buffer()
  local view = RomSource.fromString("abcdef", "rom.nds")
  local err = Assert.throws(function()
    view:byteData()
  end)
  Assert.equal(assert(err).code, "ROM_NOT_SHARED")
end

function T.zip_origin_names_a_relative_member()
  requireOrigin()
  local zip = ZipBuilder.build({ { name = "roms/good.nds", data = "unsupported bytes" } })
  local view = assert(RomSource.fromZipData(zip, "rom.zip", versionsFor("none")))
  local origin = view:origin()
  Assert.equal(origin.kind, "zip")
  Assert.isTrue(origin.path == false, "an in-memory archive has no durable location")
  Assert.isTrue(origin.zipEntry:sub(1, 1) ~= "/", "the member must stay a relative path")
  Assert.isTrue(origin.zipEntry:match("%.nds$") ~= nil, "the member must name the selected ROM")
  Assert.equal(origin.displayName, "rom.zip")
end
-- only the winning source survives the scan. ("a1.nds" lists before
-- "good.nds" for these names, so the unsupported candidate becomes the
-- fallback before the match.)
function T.zip_scan_releases_the_fallback_when_a_supported_candidate_wins()
  local good = NdsBuilder.build(DumpFixture.spec())
  local goodSha = RomSource.fromString(good):sha1()
  local created, released = 0, 0
  local zip = ZipBuilder.build({
    { name = "a1.nds", data = "one" },
    { name = "good.nds", data = good },
  })
  local s, err
  withPatched(RomSource, "fromString", function(original)
    return function(data, name)
      created = created + 1
      local source = original(data, name)
      local originalRelease = source.release
      source.release = function(self)
        released = released + 1
        return originalRelease(self)
      end
      return source
    end
  end, function()
    s, err = RomSource.fromZipData(zip, "rom.zip", versionsFor(goodSha))
  end)
  Assert.notNil(s, err and tostring(err))
  assert(s)
  Assert.equal(created, 2)
  Assert.equal(released, 1, "the fallback must be released when a supported candidate wins")
  Assert.equal(s:sha1(), goodSha)
end

-- A saved archive location always reopens its recorded member: the bound
-- entry is served regardless of archive order, a removed entry fails instead
-- of substituting another game, unsafe names never reach the reader, and an
-- exact-member option on a bare cartridge is rejected. Failures leave no
-- mount behind, and the option-less scan keeps its current behavior.
function T.bound_zip_member_reopens_exactly_without_fallback_or_leak()
  withOwnedRoot(function(root)
    local specA = DumpFixture.spec()
    local specB = DumpFixture.spec()
    specB.overlays9 = { "OVERLAY0-DATB" }
    local bytesA = NdsBuilder.build(specA)
    local bytesB = NdsBuilder.build(specB)
    Assert.equal(#bytesA, #bytesB, "the variants must share a size")
    Assert.isTrue(bytesA ~= bytesB, "the variants must differ")
    local shaA = RomSource.fromString(bytesA):sha1()
    local shaB = RomSource.fromString(bytesB):sha1()
    local infoA = { id = "variant-a", sha1 = shaA, gameCode = "IPKE" }
    local infoB = { id = "variant-b", sha1 = shaB, gameCode = "IPKE" }
    local versions = {
      forSha1 = function(hash)
        if hash == shaA then
          return infoA
        end
        if hash == shaB then
          return infoB
        end
        return nil
      end,
      forGameCode = function()
        return nil
      end,
    }
    local zipBytes = ZipBuilder.build({
      { name = "a_first.nds", data = bytesA },
      { name = "z_second.nds", data = bytesB },
    })
    local zipPath = root .. "/game.zip"
    local writer = assert(io.open(zipPath, "wb"))
    writer:write(zipBytes)
    assert(writer:close())

    local exactB, exactErr = RomSource.fromPath(zipPath, { zipEntry = "z_second.nds" })
    Assert.notNil(exactB, "the bound member must open: " .. tostring(exactErr))
    assert(exactB, "the bound member must open")
    local ok, err = pcall(function()
      Assert.equal(exactB:sha1(), shaB, "the bound member must serve its own bytes, not archive order")
      local origin = exactB:origin()
      Assert.equal(origin.kind, "zip")
      Assert.equal(origin.path, zipPath)
      Assert.equal(origin.zipEntry, "z_second.nds")
      local rom, romErr = NdsRom.open(exactB, versions)
      Assert.notNil(rom, romErr and tostring(romErr))
      assert(rom, "the bound member must validate")
      Assert.equal(rom:versionInfo().sha1, shaB)
    end)
    exactB:release()
    if not ok then
      error(err, 0)
    end

    local exactA = assert(RomSource.fromPath(zipPath, { zipEntry = "a_first.nds" }))
    local okA, errA = pcall(function()
      Assert.equal(exactA:sha1(), shaA, "each bound member must serve its own bytes")
    end)
    exactA:release()
    if not okA then
      error(errA, 0)
    end

    local missing, missingErr = RomSource.fromPath(zipPath, { zipEntry = "gone.nds" })
    Assert.isNil(missing, "a removed member must not fall back to another entry")
    Assert.isTrue(Errors.is(missingErr), "a removed member must report a typed error")
    Assert.isNil(love.filesystem.getInfo(MOUNT_POINT), "no mount may leak after member-not-found")

    local unsafe = { "../evil.nds", "a/../b.nds", "a/./b.nds", "/abs/member.nds", "C:/win.nds", "a\\b.nds" }
    for _, member in ipairs(unsafe) do
      local rejected, rejectErr = RomSource.fromPath(zipPath, { zipEntry = member })
      Assert.isNil(rejected, "an unsafe member must never open: " .. member)
      Assert.isTrue(Errors.is(rejectErr), "an unsafe member must report a typed error: " .. member)
    end
    Assert.isNil(love.filesystem.getInfo(MOUNT_POINT), "no mount may leak after unsafe members")

    local barePath = root .. "/bare.nds"
    local bareWriter = assert(io.open(barePath, "wb"))
    bareWriter:write(bytesA)
    assert(bareWriter:close())
    local badBare, badBareErr = RomSource.fromPath(barePath, { zipEntry = "x.nds" })
    Assert.isNil(badBare, "an exact member on a bare cartridge must be rejected")
    Assert.isTrue(Errors.is(badBareErr), "a bare-cartridge member option must report a typed error")

    local legacy = assert(RomSource.fromPath(zipPath), "the option-less scan must keep working")
    local legacySha = legacy:sha1()
    legacy:release()
    Assert.isTrue(legacySha == shaA or legacySha == shaB, "the option-less scan still returns a member")
  end)
end

-- An exact member that names a directory or carries an embedded NUL never
-- opens, and a malformed archive fails the same way with or without the
-- option. Every failure leaves no mount behind.
function T.exact_member_rejects_directories_embedded_nul_and_malformed_archives()
  withOwnedRoot(function(root)
    local zipBytes = ZipBuilder.build({ { name = "roms/game.nds", data = "unsupported bytes" } })
    local zipPath = root .. "/game.zip"
    local writer = assert(io.open(zipPath, "wb"))
    writer:write(zipBytes)
    assert(writer:close())

    local asDir, dirErr = RomSource.fromPath(zipPath, { zipEntry = "roms" })
    Assert.isNil(asDir, "an exact member naming a directory must not open")
    Assert.isTrue(Errors.is(dirErr), "a directory member must report a typed error")
    Assert.isNil(love.filesystem.getInfo(MOUNT_POINT), "no mount may leak after a directory member")

    local nul, nulErr = RomSource.fromPath(zipPath, { zipEntry = "a\0b.nds" })
    Assert.isNil(nul, "an exact member with an embedded NUL must not open")
    Assert.isTrue(Errors.is(nulErr), "an embedded NUL must report a typed error")
    Assert.isNil(love.filesystem.getInfo(MOUNT_POINT), "no mount may leak after an embedded NUL")

    local badPath = root .. "/bad.zip"
    local badWriter = assert(io.open(badPath, "wb"))
    badWriter:write("not a zip at all")
    assert(badWriter:close())
    local badExact, badExactErr = RomSource.fromPath(badPath, { zipEntry = "game.nds" })
    Assert.isNil(badExact, "a malformed archive must not open with an exact member")
    Assert.isTrue(Errors.is(badExactErr), "a malformed archive must report a typed error")
    Assert.isNil(love.filesystem.getInfo(MOUNT_POINT), "no mount may leak after a malformed archive")
    local badScan, badScanErr = RomSource.fromPath(badPath)
    Assert.isNil(badScan, "a malformed archive must not open on the option-less scan either")
    Assert.isTrue(Errors.is(badScanErr), "a malformed archive scan must report a typed error")
    Assert.isNil(love.filesystem.getInfo(MOUNT_POINT), "no mount may leak after a malformed scan")
  end)
end

return { tests = T }
