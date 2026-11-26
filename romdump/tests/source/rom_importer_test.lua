local Assert = require("tests.support.Assert")
local RomBinding = require("romdump.src.source.RomBinding")
local RomImporter = require("romdump.src.source.RomImporter")
local RomSource = require("romdump.src.source.RomSource")
local NdsBuilder = require("tests.support.NdsBuilder")
local DumpFixture = require("tests.support.DumpFixture")
local CacheFs = require("libs.storage.src.CacheFs")
local SaveFs = require("libs.storage.src.SaveFs")
local FakeCache = require("tests.support.FakeCache")
local ManagedRomIconFixture = require("tests.support.ManagedRomIconFixture")
local BannerIconFixture = require("tests.support.BannerIconFixture")
local PngReader = require("tests.support.PngReader")
local ZipBuilder = require("tests.support.ZipBuilder")
local RomArchive = require("romdump.src.source.RomArchive")

local T = {}

local HG = "heartgold/"

local function readIfPresent(path)
  return love.filesystem.getInfo(path) and love.filesystem.read(path) or nil
end

local function installManagedIcon(cart, banner)
  Assert.equal(type(RomArchive.encodeIcon), "function", "verified banner encoding is required")
  Assert.equal(type(RomArchive.publishIcon), "function", "managed sidecar publication is required")
  local bytes = love.data.newByteData(cart.data)
  local prepared = assert(RomArchive.prepare(cart.info, bytes, cart.versions))
  Assert.isTrue(RomArchive.publish(prepared), "managed source setup failed")
  local png = assert(RomArchive.encodeIcon(bytes))
  Assert.isTrue(RomArchive.publishIcon(cart.sha1, png), "managed icon setup failed")
  png:release()
  bytes:release()
  local iconBytes = readIfPresent(RomArchive.iconPath(cart.sha1))
  Assert.notNil(iconBytes, "managed sidecar publication must create the canonical PNG")
  local width, height, rgba = PngReader.rgba(assert(iconBytes))
  Assert.equal(width, 32)
  Assert.equal(height, 32)
  Assert.equal(rgba, banner.rgba)
end

local function editionSnapshot(edition)
  return {
    source = readIfPresent(edition.canonical),
    sourceStage = readIfPresent(edition.stage),
    sourceBackup = readIfPresent(edition.backup),
    icon = readIfPresent(edition.icon),
    iconStage = readIfPresent(edition.iconStage),
    iconBackup = readIfPresent(edition.iconBackup),
  }
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

local function throwsCode(code, fn)
  local err = Assert.throws(fn)
  Assert.equal(err.code, code, "expected " .. code .. ", got " .. tostring(err))
end

-- Build a synthetic HGSS ROM plus a version catalog that accepts exactly it under
-- the real "heartgold" identity, so the importer's marker/readiness logic aligns.
-- `now` is static, which disables yielding: a single update() runs to completion.
local function harness(spec)
  local data = NdsBuilder.build(spec or DumpFixture.spec())
  local sha1 = RomSource.fromString(data):sha1()
  local info = {
    id = "heartgold",
    label = "HeartGold",
    displayName = "Pokemon HeartGold",
    sha1 = sha1,
    gameCode = "IPKE",
    expectedSize = #data,
    cachePrefix = "heartgold/",
  }
  local versions = {
    info = function(id)
      return id == "heartgold" and info or nil
    end,
    forSha1 = function(h)
      return h == sha1 and info or nil
    end,
    forGameCode = function(c)
      return c == "IPKE" and info or nil
    end,
  }
  local backend = FakeCache.new()
  local events = {}
  local importer = RomImporter.new({
    versions = versions,
    now = function()
      return 0
    end,
    cacheFactory = function(id)
      return CacheFs.forVersion(id, backend)
    end,
    onComplete = function(id)
      events[#events + 1] = id
    end,
  })
  return { data = data, info = info, versions = versions, backend = backend, importer = importer, events = events }
end

-- Drive update() until the importer reaches a terminal state (or a step cap).
local function runToTerminal(importer)
  for _ = 1, 10000 do
    importer:update()
    if importer.state == "complete" or importer.state == "error" then
      return
    end
  end
  error("importer did not terminate")
end

-- An ever-advancing clock forces a yield at every progress tick, exercising the
-- coroutine-yield-across-pcall path the real import relies on under LuaJIT.
function T.yields_and_still_completes_across_pcall()
  local h = harness()
  local t = 0
  local importer = RomImporter.new({
    versions = h.versions,
    now = function()
      t = t + 1
      return t
    end,
    cacheFactory = function(id)
      return CacheFs.forVersion(id, h.backend)
    end,
  })
  importer:startSource(RomSource.fromString(h.data))
  local ticks = 0
  for _ = 1, 10000 do
    importer:update()
    ticks = ticks + 1
    if importer.state == "complete" or importer.state == "error" then
      break
    end
  end
  Assert.equal(importer.state, "complete")
  Assert.isTrue(ticks > 1, "expected the import to span multiple update() slices")
end

function T.imports_synthetic_rom_to_completion()
  local h = harness()
  h.importer:startSource(RomSource.fromString(h.data, "hg.nds"))
  runToTerminal(h.importer)
  Assert.equal(h.importer.state, "complete")
  Assert.equal(h.importer:status().canCancel, false, "direct synchronous imports are never cancellable queued work")
  Assert.equal(h.importer:status().versionId, "heartgold")
  Assert.equal(h.importer.progress, 1)
  Assert.isTrue(RomImporter.isReady("heartgold", CacheFs.forVersion("heartgold", h.backend), h.versions))
  Assert.equal(h.events[1], "heartgold")
end

function T.targeted_import_rejects_a_different_recognized_edition_before_binding()
  local h = harness()
  h.backend.files[HG .. "existing-binding"] = "KEEP"
  local importer = RomImporter.new({
    versions = h.versions,
    expectedVersionId = "soulsilver",
    now = function()
      return 0
    end,
    cacheFactory = function(id)
      return CacheFs.forVersion(id, h.backend)
    end,
  })

  importer:startSource(RomSource.fromString(h.data, "heartgold.nds"))
  runToTerminal(importer)

  Assert.equal(importer.state, "error")
  Assert.equal(importer:status().errorCode, "ROM_VERSION_MISMATCH")
  Assert.equal(h.backend.files[HG .. "existing-binding"], "KEEP")
  Assert.isNil(h.backend.files["soulsilver/rom-binding.lua"])
  Assert.equal(#h.events, 0)
end

-- Validation (SHA-1/header) must fully precede any cache write (E8-S1), and
-- nothing in the import lifecycle may touch the persistent save namespace.
function T.validation_precedes_cache_cleanup()
  local h = harness()
  -- Pre-seed a marker, a stray file, and a save; an unknown ROM must leave all
  -- of them intact.
  h.backend.files[HG .. "rom-dump.complete"] = "STALE"
  h.backend.files[HG .. "stray"] = "KEEP"
  h.backend.files["saves/heartgold/field-session.lua"] = "SAVE-DATA"
  -- A version catalog that recognizes nothing => NdsRom.open rejects by SHA-1.
  local blind = { info = function() end, forSha1 = function() end, forGameCode = function() end }
  local importer = RomImporter.new({
    versions = blind,
    now = function()
      return 0
    end,
    cacheFactory = function(id)
      return CacheFs.forVersion(id, h.backend)
    end,
  })
  importer:startSource(RomSource.fromString(h.data))
  runToTerminal(importer)
  Assert.equal(importer.state, "error")
  Assert.equal(importer:status().errorCode, "NDS_UNKNOWN_ROM")
  Assert.equal(h.backend.files[HG .. "rom-dump.complete"], "STALE")
  Assert.equal(h.backend.files[HG .. "stray"], "KEEP")
  Assert.equal(h.backend.files["saves/heartgold/field-session.lua"], "SAVE-DATA")
end

-- A dropped non-.nds file is rejected with a friendly error before any read,
-- leaving caches untouched (E8-S3).
function T.rejects_non_nds_drop()
  local importer = RomImporter.new({
    now = function()
      return 0
    end,
  })
  local stub = {
    getFilename = function()
      return "photo.png"
    end,
  }
  importer:filedropped(stub)
  Assert.equal(importer.state, "error")
  Assert.equal(importer:status().errorCode, "IMPORT_NOT_NDS")
end

-- The completion keeps the validated bytes for exactly one controller
-- handoff: a running import offers nothing, the first take after completion
-- receives the shared buffer, and later takes answer nil. The original
-- string source is released on the terminal path.
function T.take_transfers_the_verified_source_exactly_once()
  local h = harness()
  local source = RomSource.fromString(h.data)
  h.importer:startSource(source)
  Assert.isNil(h.importer:takeVerifiedSource(), "a running import offers no handoff yet")
  runToTerminal(h.importer)
  Assert.equal(h.importer.state, "complete")
  local handed = h.importer:takeVerifiedSource()
  Assert.notNil(handed, "completion offers its verified bytes once")
  Assert.equal(handed:sha1(), h.info.sha1, "the handed source keeps its verified identity")
  Assert.isNil(h.importer:takeVerifiedSource(), "the handoff is one-shot")
  -- The original string source is released: further reads fail predictably.
  local bytes, err = source:read(0, 4)
  Assert.isNil(bytes)
  Assert.equal(assert(err).code, "ROM_RELEASED")
end

function T.progress_is_monotonic()
  local h = harness()
  local last = -1
  -- Wrap onProgress by observing status each update.
  h.importer:startSource(RomSource.fromString(h.data))
  for _ = 1, 10000 do
    h.importer:update()
    local p = h.importer.progress or 0
    Assert.isTrue(p >= last, "progress regressed: " .. p .. " < " .. last)
    last = p
    if h.importer.state == "complete" or h.importer.state == "error" then
      break
    end
  end
  Assert.equal(h.importer.state, "complete")
  Assert.equal(last, 1)
end

-- An explicitly supplied ROM always re-registers: re-importing a bound
-- version validates and records its binding again instead of skipping, and
-- the re-registration touches only the binding.
function T.reimport_reregisters_the_source_binding()
  local h = harness()
  h.importer:startSource(RomSource.fromString(h.data))
  runToTerminal(h.importer)
  Assert.notNil(h.importer:status().report)
  local cache = CacheFs.forVersion("heartgold", h.backend)
  local first = assert(cache:loadLua("rom-source.lua"), "the first import records its binding")

  local again = RomImporter.new({
    versions = h.versions,
    now = function()
      return 0
    end,
    cacheFactory = function(id)
      return CacheFs.forVersion(id, h.backend)
    end,
  })
  again:startSource(RomSource.fromString(h.data))
  runToTerminal(again)
  Assert.equal(again.state, "complete")
  Assert.notNil(again:status().report, "a fresh registration always completes")
  Assert.deepEqual(cache:loadLua("rom-source.lua"), first, "re-registering the same ROM keeps its binding")
  for path in pairs(h.backend.files) do
    Assert.isFalse(
      path:find(HG .. "romfs/", 1, true) == 1 or path:find(HG .. "system/", 1, true) == 1,
      "re-registration writes no extracted tree: " .. path
    )
  end
end

-- The extraction rebuild wipes the version cache root; a persisted save in the
-- sibling user-data namespace must survive the full production re-import --
-- including a save of another version, which shares the save root but never the
-- disposable cache root.
function T.reimport_preserves_saves()
  local h = harness()
  SaveFs.forVersion("heartgold", h.backend):write("field-session.lua", "SAVE-DATA")
  SaveFs.forVersion("soulsilver", h.backend):write("field-session.lua", "SS-SAVE")
  h.importer:startSource(RomSource.fromString(h.data))
  runToTerminal(h.importer)
  Assert.equal(h.importer.state, "complete")
  Assert.equal(h.backend.files["saves/heartgold/field-session.lua"], "SAVE-DATA")
  Assert.equal(h.backend.files["saves/soulsilver/field-session.lua"], "SS-SAVE")
  Assert.isTrue(RomImporter.isReady("heartgold", CacheFs.forVersion("heartgold", h.backend), h.versions))
end

-- A re-import that fails validation must leave the previous binding,
-- derived receipts, and saves untouched, and the version stays ready.
function T.failed_reimport_preserves_prior_binding_and_saves()
  local CacheArchive = require("romdump.src.build.CacheArchive")
  local h = harness()
  local cache = CacheFs.forVersion("heartgold", h.backend)
  cache:write(CacheArchive.ARCHIVE_NAME, "prior snapshot bytes")
  SaveFs.forVersion("heartgold", h.backend):write("field-session.lua", "SAVE-DATA")
  h.importer:startSource(RomSource.fromString(h.data))
  runToTerminal(h.importer)
  Assert.equal(h.importer.state, "complete")
  local binding = assert(cache:loadLua("rom-source.lua"), "the first import records its binding")

  -- A well-formed cartridge no catalog recognizes fails closed.
  local other = DumpFixture.spec()
  other.gameCode = "XXXX"
  local again = RomImporter.new({
    versions = h.versions,
    now = function()
      return 0
    end,
    cacheFactory = function(id)
      return CacheFs.forVersion(id, h.backend)
    end,
  })
  again:startSource(RomSource.fromString(NdsBuilder.build(other)))
  runToTerminal(again)

  Assert.equal(again.state, "error", "an unrecognized ROM must fail the import")
  Assert.equal(again:status().errorCode, "NDS_UNKNOWN_ROM", "the failure names its cause")
  Assert.isNil(again:takeVerifiedSource(), "a failed import offers no handoff")
  Assert.deepEqual(cache:loadLua("rom-source.lua"), binding, "a failed re-import keeps its prior binding")
  Assert.equal(
    cache:read(CacheArchive.ARCHIVE_NAME),
    "prior snapshot bytes",
    "a failed re-import keeps its prior snapshot"
  )
  Assert.equal(
    SaveFs.forVersion("heartgold", h.backend):read("field-session.lua"),
    "SAVE-DATA",
    "a failed re-import keeps its saves"
  )
  Assert.isTrue(RomImporter.isReady("heartgold", cache, h.versions), "the version stays ready")
  for path in pairs(h.backend.files) do
    Assert.isFalse(
      path:find(HG .. "romfs/", 1, true) == 1 or path:find(HG .. "system/", 1, true) == 1,
      "a failed re-import writes no extracted tree: " .. path
    )
  end
end

-- A successful import leaves no staging residue: the staged tree is moved into
-- the live root and the staging namespace is gone.
function T.import_leaves_no_staging_residue()
  local h = harness()
  h.importer:startSource(RomSource.fromString(h.data))
  runToTerminal(h.importer)
  Assert.equal(h.importer.state, "complete")
  Assert.isNil(h.backend.files["staging/heartgold/rom-dump.complete"], "staging marker must not survive")
  Assert.isNil(h.backend.dirs["staging/heartgold"], "staging root must be gone")
  Assert.isNil(h.backend.files["staging/heartgold.old/romfs/a/0/0/2"], "no orphaned old root")
end

-- An import that has started but is still running. The active source and
-- coroutine identity are the state the busy rejection must leave untouched.
local function busyImporter()
  local h = harness()
  h.importer:startSource(RomSource.fromString(h.data, "first.nds"))
  Assert.equal(h.importer.state, "reading")
  return h
end

-- While busy, every start API rejects the new request with a structured
-- IMPORT_BUSY error and leaves the active import untouched.
function T.busy_rejects_all_start_apis_unchanged()
  local h = busyImporter()
  local source, co = h.importer._source, h.importer._co
  throwsCode("IMPORT_BUSY", function()
    h.importer:startSource(RomSource.fromString(h.data, "second.nds"))
  end)
  throwsCode("IMPORT_BUSY", function()
    h.importer:startPath("second.nds")
  end)
  throwsCode("IMPORT_BUSY", function()
    h.importer:startDroppedFile({
      getFilename = function()
        return "second.nds"
      end,
    })
  end)
  Assert.equal(h.importer._source, source, "active source must be unchanged")
  Assert.equal(h.importer._co, co, "active coroutine must be unchanged")
  Assert.equal(h.importer.state, "reading")
  runToTerminal(h.importer)
  Assert.equal(h.importer.state, "complete")
  Assert.equal(h.events[1], "heartgold")
end

-- An invalid drop while busy is rejected with IMPORT_BUSY and must NOT route
-- the active importer through _fail (which would release the active source).
function T.busy_invalid_drop_leaves_active_import_unchanged()
  local h = busyImporter()
  throwsCode("IMPORT_BUSY", function()
    h.importer:filedropped({
      getFilename = function()
        return "photo.png"
      end,
    })
  end)
  Assert.equal(h.importer.state, "reading", "busy rejection must not fail the active import")
  Assert.isNil(h.importer._errorCode)
  Assert.notNil(h.importer._source, "active source must remain held")
  runToTerminal(h.importer)
  Assert.equal(h.importer.state, "complete")
  Assert.equal(h.importer:status().versionId, "heartgold")
end

-- Busy rejection never releases the active source; the terminal transition
-- releases it exactly once.
function T.busy_rejection_never_releases_and_terminal_release_is_exactly_once()
  local h = harness()
  local first = RomSource.fromString(h.data, "first.nds")
  local releases = 0
  local baseRelease = first.release
  first.release = function(self)
    releases = releases + 1
    return baseRelease(self)
  end
  h.importer:startSource(first)
  throwsCode("IMPORT_BUSY", function()
    h.importer:startSource(RomSource.fromString(h.data, "second.nds"))
  end)
  throwsCode("IMPORT_BUSY", function()
    h.importer:filedropped({
      getFilename = function()
        return "photo.png"
      end,
    })
  end)
  Assert.equal(releases, 0, "busy rejection must not release the active source")
  runToTerminal(h.importer)
  Assert.equal(h.importer.state, "complete")
  Assert.equal(releases, 1, "the terminal transition must release the source exactly once")
  local bytes, err = first:read(0, 4)
  Assert.isNil(bytes)
  Assert.equal(assert(err).code, "ROM_RELEASED")
end

-- The busy guard must not lock the importer after a terminal state: a
-- completed or failed importer accepts a fresh start (App no longer exercises
-- this — it starts a fresh importer per session — but the restart capability
-- is the importer's own contract).
function T.terminal_importer_accepts_a_fresh_start()
  local h = harness()
  h.importer:startSource(RomSource.fromString(h.data))
  runToTerminal(h.importer)
  Assert.equal(h.importer.state, "complete")
  h.importer:startSource(RomSource.fromString(h.data, "again.nds"))
  Assert.equal(h.importer.state, "reading")
  runToTerminal(h.importer)
  Assert.equal(h.importer.state, "complete")
  Assert.equal(h.events[1], "heartgold")
  Assert.equal(h.events[2], "heartgold")

  h.importer:filedropped({
    getFilename = function()
      return "photo.png"
    end,
  })
  Assert.equal(h.importer.state, "error")
  h.importer:startSource(RomSource.fromString(h.data, "third.nds"))
  Assert.equal(h.importer.state, "reading")
  runToTerminal(h.importer)
  Assert.equal(h.importer.state, "complete")
  Assert.equal(h.events[3], "heartgold")
end

-- The importer's state strings are one named vocabulary: every state the
-- production consumers (App, the import screen, the CLI runner) compare
-- against is exposed as a RomImporter.STATES constant, and every transition
-- lands on one of those named states.
function T.importer_states_are_named_constants()
  for _, name in ipairs({ "IDLE", "READING", "VERIFYING", "REGISTERING", "COMPLETE", "ERROR" }) do
    Assert.equal("string", type(RomImporter.STATES[name]), "RomImporter.STATES." .. name .. " must be a named state")
  end
  local fresh = RomImporter.new({
    now = function()
      return 0
    end,
  })
  Assert.equal(fresh.state, RomImporter.STATES.IDLE)
  fresh:filedropped({
    getFilename = function()
      return "photo.png"
    end,
  })
  Assert.equal(fresh.state, RomImporter.STATES.ERROR)
  local h = harness()
  h.importer:startSource(RomSource.fromString(h.data))
  runToTerminal(h.importer)
  Assert.equal(h.importer.state, RomImporter.STATES.COMPLETE)
end

-- A validated import registers its source and nothing else: the strict
-- binding lands, no extracted tree is written, and the verified bytes are
-- available exactly once for the controller handoff instead of being
-- released unreadably or copied into the cache.
function T.validated_import_records_only_the_source_binding()
  local h = harness()
  h.importer:startSource(RomSource.fromString(h.data, "hg.nds"))
  runToTerminal(h.importer)
  Assert.equal(h.importer.state, "complete")
  local cache = CacheFs.forVersion("heartgold", h.backend)
  local binding = cache:loadLua("rom-source.lua")
  Assert.notNil(binding, "a validated import records its source binding")
  assert(binding, "a validated import records its source binding")
  Assert.equal(binding.versionId, "heartgold")
  Assert.equal(binding.romSha1, h.info.sha1)
  Assert.equal(binding.kind, "nds")
  for path in pairs(h.backend.files) do
    Assert.isFalse(
      path:find(HG .. "romfs/", 1, true) == 1 or path:find(HG .. "system/", 1, true) == 1,
      "validation writes no extracted tree: " .. path
    )
  end
  Assert.isNil(h.backend.files[HG .. "rom-dump.complete"], "validation publishes no dump marker")
  Assert.equal(
    type(h.importer.takeVerifiedSource),
    "function",
    "the importer offers its verified bytes once for the controller handoff"
  )
  local handed = h.importer:takeVerifiedSource()
  Assert.notNil(handed, "the first take receives the verified source")
  Assert.equal(handed:sha1(), h.info.sha1, "the handed source keeps its verified identity")
  Assert.isNil(h.importer:takeVerifiedSource(), "the handoff is one-shot")
end

-- Re-importing the same canonical ROM re-registers without touching
-- prior derived work: receipts, owned assets and saves survive the
-- rebind instead of being wiped with a replaced version root.
function T.same_rom_reimport_keeps_prior_derived_work()
  local h = harness()
  local cache = CacheFs.forVersion("heartgold", h.backend)
  local CacheArchive = require("romdump.src.build.CacheArchive")
  cache:write(CacheArchive.ARCHIVE_NAME, "prior snapshot bytes")
  cache:write("maps/60/complete", "ready")
  SaveFs.forVersion("heartgold", h.backend):write("field-session.lua", "SAVE-DATA")
  h.importer:startSource(RomSource.fromString(h.data, "hg.nds"))
  runToTerminal(h.importer)
  Assert.equal(h.importer.state, "complete")
  Assert.equal(cache:read(CacheArchive.ARCHIVE_NAME), "prior snapshot bytes", "the same-ROM rebind keeps its snapshot")
  Assert.equal(cache:read("maps/60/complete"), "ready", "the same-ROM rebind keeps its owned assets")
  Assert.equal(
    SaveFs.forVersion("heartgold", h.backend):read("field-session.lua"),
    "SAVE-DATA",
    "the same-ROM rebind keeps its saves"
  )
end

-- One atomically acquired scratch directory per invocation holds this case's
-- reopenable fixture file. Only the acquired root is ever removed.
local function shellQuote(value)
  return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function commandSucceeded(status)
  return status == 0 or status == true
end

local function withOwnedRoot(fn)
  local handle = assert(io.popen("mktemp -d"), "mktemp -d could not start")
  local root = (handle:read("*l") or ""):gsub("^%s+", ""):gsub("%s+$", "")
  local closed = handle:close()
  assert(commandSucceeded(closed), "mktemp -d did not exit successfully")
  assert(root ~= "", "mktemp -d produced no path")
  local ok, err = pcall(fn, root)
  if ok then
    local status = os.execute("rm -rf -- " .. shellQuote(root))
    assert(commandSucceeded(status), "owned scratch cleanup failed: " .. root)
    return
  end
  pcall(os.execute, "rm -rf -- " .. shellQuote(root))
  error(err, 0)
end

-- A desktop drop whose reported filename can be reopened keeps that location:
-- the import registers the verified user path, copies no ROM bytes into the
-- cache, and a later process can reopen the same bytes from the binding.
function T.dropped_file_with_reopenable_path_persists_verified_location()
  withOwnedRoot(function(root)
    local h = harness()
    local romPath = root .. "/dropped.nds"
    local writer = assert(io.open(romPath, "wb"))
    writer:write(h.data)
    assert(writer:close())
    local stub = {
      open = function()
        return true
      end,
      read = function()
        return h.data
      end,
      close = function()
        return true
      end,
      getFilename = function()
        return romPath
      end,
    }
    h.importer:startDroppedFile(stub)
    runToTerminal(h.importer)
    Assert.equal(h.importer.state, "complete")
    local cache = CacheFs.forVersion("heartgold", h.backend)
    local binding = cache:loadLua("rom-source.lua")
    Assert.notNil(binding, "a reopenable desktop drop must persist its location")
    assert(binding, "a reopenable desktop drop must persist its location")
    Assert.equal(binding.path, romPath, "the binding must keep the verified user path")
    Assert.equal(binding.kind, "nds")
    Assert.equal(binding.romSha1, h.info.sha1)
    for _, value in pairs(h.backend.files) do
      if type(value) == "string" then
        Assert.isTrue(value:find("OVERLAY0-DATA", 1, true) == nil, "no ROM payload may be copied into the cache")
      end
    end
    local reopened, openErr = RomSource.fromPath(binding.path)
    Assert.notNil(reopened, openErr and tostring(openErr))
    assert(reopened, "the persisted path must reopen")
    local ok, err = pcall(function()
      Assert.equal(reopened:sha1(), h.info.sha1, "the reopened bytes must keep their identity")
      local NdsRom = require("romdump.src.source.NdsRom")
      local rom, romErr = NdsRom.open(reopened, h.versions)
      Assert.notNil(rom, romErr and tostring(romErr))
      assert(rom, "the reopened bytes must validate")
      Assert.equal(rom:versionInfo().id, "heartgold")
      Assert.equal(rom:versionInfo().sha1, h.info.sha1)
    end)
    reopened:release()
    if not ok then
      error(err, 0)
    end
  end)
end

-- A drop the platform will not let the app reopen (a missing file, a mediated
-- URI) still imports its verified bytes for the current session: the binding
-- stays explicitly ephemeral while the one-shot handoff serves the session.
function T.unreopenable_drop_stays_ephemeral_but_usable()
  local h = harness()
  local stub = {
    open = function()
      return true
    end,
    read = function()
      return h.data
    end,
    close = function()
      return true
    end,
    getFilename = function()
      return "/no/such/place/missing.nds"
    end,
  }
  h.importer:startDroppedFile(stub)
  runToTerminal(h.importer)
  Assert.equal(h.importer.state, "complete")
  local binding = CacheFs.forVersion("heartgold", h.backend):loadLua("rom-source.lua")
  Assert.notNil(binding, "an unreopenable drop must still register its identity")
  assert(binding, "an unreopenable drop must still register its identity")
  Assert.isTrue(binding.path == false, "an inaccessible drop must stay explicitly ephemeral")
  Assert.equal(binding.kind, "nds")
  Assert.equal(binding.romSha1, h.info.sha1)
  local handed = h.importer:takeVerifiedSource()
  Assert.notNil(handed, "the valid drop still hands its bytes to the current session")
  assert(handed, "the valid drop still hands its bytes to the current session")
  Assert.equal(handed:sha1(), h.info.sha1)
  Assert.isNil(h.importer:takeVerifiedSource(), "the session handoff is one-shot")
  for _, value in pairs(h.backend.files) do
    if type(value) == "string" then
      Assert.isTrue(value:find("OVERLAY0-DATA", 1, true) == nil, "no ROM payload may be copied into the cache")
    end
  end

  local ZipBuilder = require("tests.support.ZipBuilder")
  local z = harness()
  local zipBytes = ZipBuilder.build({ { name = "game.nds", data = z.data } })
  local zipStub = {
    open = function()
      return true
    end,
    read = function()
      return zipBytes
    end,
    close = function()
      return true
    end,
    getFilename = function()
      return "content://media/document/9.zip"
    end,
  }
  z.importer:startDroppedFile(zipStub)
  runToTerminal(z.importer)
  Assert.equal(z.importer.state, "complete")
  local zipBinding = CacheFs.forVersion("heartgold", z.backend):loadLua("rom-source.lua")
  Assert.notNil(zipBinding, "an unreopenable archive drop must still register")
  assert(zipBinding, "an unreopenable archive drop must still register")
  Assert.isTrue(zipBinding.path == false, "a mediated archive drop must stay explicitly ephemeral")
  Assert.equal(zipBinding.kind, "zip")
  Assert.isTrue(
    type(zipBinding.zipEntry) == "string" and zipBinding.zipEntry:match("%.nds$") ~= nil,
    "the archive drop keeps its selected member"
  )
  local zipHanded = z.importer:takeVerifiedSource()
  Assert.notNil(zipHanded, "the valid archive drop still hands its bytes over")
  assert(zipHanded, "the valid archive drop still hands its bytes over")
  Assert.equal(zipHanded:sha1(), z.info.sha1)
  Assert.isNil(z.importer:takeVerifiedSource(), "the archive handoff is one-shot")
end

-- A drop whose reported filename holds a different valid ROM must not lend
-- its location to the import: the candidate's own bytes validate under
-- another identity, so the binding stays explicitly ephemeral while the
-- dropped bytes still complete the current session.
function T.dropped_candidate_holding_another_rom_stays_ephemeral_but_usable()
  withOwnedRoot(function(root)
    local specA = DumpFixture.spec()
    local dataA = NdsBuilder.build(specA)
    local shaA = RomSource.fromString(dataA):sha1()
    local specB = DumpFixture.spec()
    specB.overlays9 = { "OVERLAY0-DATB" }
    local dataB = NdsBuilder.build(specB)
    Assert.isTrue(dataA ~= dataB, "the candidate must hold different bytes")
    local shaB = RomSource.fromString(dataB):sha1()
    local infoA = {
      id = "heartgold",
      label = "HeartGold",
      displayName = "Pokemon HeartGold",
      sha1 = shaA,
      gameCode = "IPKE",
      expectedSize = #dataA,
      cachePrefix = "heartgold/",
    }
    local infoB = {
      id = "soulsilver",
      label = "SoulSilver",
      displayName = "Pokemon SoulSilver",
      sha1 = shaB,
      gameCode = "IPKE",
      expectedSize = #dataB,
      cachePrefix = "soulsilver/",
    }
    local versions = {
      info = function(id)
        if id == "heartgold" then
          return infoA
        end
        if id == "soulsilver" then
          return infoB
        end
        return nil
      end,
      forSha1 = function(h)
        if h == shaA then
          return infoA
        end
        if h == shaB then
          return infoB
        end
        return nil
      end,
      forGameCode = function()
        return nil
      end,
    }
    local candidatePath = root .. "/other.nds"
    local writer = assert(io.open(candidatePath, "wb"))
    writer:write(dataB)
    assert(writer:close())
    local backend = FakeCache.new()
    local importer = RomImporter.new({
      versions = versions,
      now = function()
        return 0
      end,
      cacheFactory = function(id)
        return CacheFs.forVersion(id, backend)
      end,
    })
    importer:startDroppedFile({
      open = function()
        return true
      end,
      read = function()
        return dataA
      end,
      close = function()
        return true
      end,
      getFilename = function()
        return candidatePath
      end,
    })
    runToTerminal(importer)
    Assert.equal(importer.state, "complete")
    Assert.equal(importer:status().versionId, "heartgold")
    local binding = CacheFs.forVersion("heartgold", backend):loadLua("rom-source.lua")
    Assert.notNil(binding, "the mismatched drop must still register its identity")
    assert(binding, "the mismatched drop must still register its identity")
    Assert.isTrue(binding.path == false, "a candidate holding another ROM must stay explicitly ephemeral")
    Assert.equal(binding.kind, "nds")
    Assert.equal(binding.romSha1, shaA)
    local handed = importer:takeVerifiedSource()
    Assert.notNil(handed, "the valid drop still hands its bytes to the current session")
    assert(handed, "the valid drop still hands its bytes to the current session")
    Assert.equal(handed:sha1(), shaA)
    Assert.isNil(importer:takeVerifiedSource(), "the session handoff is one-shot")
    for _, value in pairs(backend.files) do
      if type(value) == "string" then
        Assert.isTrue(value:find("OVERLAY0-DATA", 1, true) == nil, "no ROM payload may be copied into the cache")
        Assert.isTrue(value:find("OVERLAY0-DATB", 1, true) == nil, "no candidate payload may be copied either")
      end
    end
  end)
end

-- Queued imports validate in a platform worker thread and report back over
-- channels. These scenarios drive that protocol through a deterministic
-- stand-in transport: in-memory FIFO channels plus worker threads whose
-- liveness the test flips. Nothing blocks, sleeps, or spawns OS threads.
local function withQueuedHost(fn)
  local threads, channels, importers = {}, {}, {}
  local function newChannel()
    local values = {}
    local channel = {}
    function channel:push(value)
      values[#values + 1] = value
      return true
    end
    function channel:pop()
      if #values == 0 then
        return nil
      end
      return table.remove(values, 1)
    end
    channels[#channels + 1] = channel
    return channel
  end
  local function newThread(bootstrap)
    local thread = { bootstrap = bootstrap, alive = true, starts = 0 }
    function thread:start(...)
      self.starts = self.starts + 1
      self.args = { ... }
      return true
    end
    function thread:isRunning()
      return self.alive
    end
    function thread:getError()
      return self.threadError
    end
    threads[#threads + 1] = thread
    return thread
  end
  local realLove = assert(rawget(_G, "love"), "queued imports need the platform host")
  local fakeLove = {
    data = realLove.data,
    filesystem = realLove.filesystem,
    timer = realLove.timer,
    thread = { newChannel = newChannel, newThread = newThread },
  }
  local host = { threads = threads, channels = channels }
  function host:watch(importer)
    importers[#importers + 1] = importer
    return importer
  end
  rawset(_G, "love", fakeLove)
  local ok, err = pcall(fn, host)
  -- Retire every owned worker through the real lease rules so a failed
  -- assertion cannot leak a live worker into the next scenario.
  for _, thread in ipairs(threads) do
    thread.alive = false
  end
  for _ = 1, 8 do
    for _, importer in ipairs(importers) do
      pcall(function()
        importer:update()
      end)
    end
    for _, thread in ipairs(threads) do
      thread.alive = false
    end
  end
  for _, channel in ipairs(channels) do
    while channel:pop() ~= nil do
    end
  end
  rawset(_G, "love", realLove)
  if not ok then
    error(err, 0)
  end
end

-- The importer's live worker session. Queued tests read the issued session
-- id out of the worker inbox the importer itself populated, then answer
-- with that id; ids are never invented by the fake.
local function liveSession(importer)
  Assert.notNil(importer._queued, "the import must hold a live worker session")
  return importer._queued
end

local function retireWorkers(host)
  for _, thread in ipairs(host.threads) do
    thread.alive = false
  end
end

local function pump(importer, rounds)
  for _ = 1, rounds do
    importer:update()
  end
end

-- A terminal worker result carrying genuine shared bytes for the session.
local function completePacket(h, sessionId)
  return {
    id = sessionId,
    kind = "complete",
    versionId = h.info.id,
    report = { sha1 = h.info.sha1 },
    sourceName = "synthetic.nds",
    displayName = h.info.displayName,
    byteData = love.data.newByteData(h.data),
  }
end

-- A fresh import must start a worker at once: after the previous worker
-- exited and its outbox drained, no lease may hold the next import back.
-- The probe is canceled and retired before returning.
local function assertLeaseFree(host)
  local probe = harness()
  host:watch(probe.importer)
  probe.importer:queuePath("probe.nds")
  probe.importer:update()
  Assert.isTrue(
    probe.importer:status().stage ~= "waiting",
    "a fresh import must start at once once the old worker exited"
  )
  probe.importer:cancelQueued()
  retireWorkers(host)
  for _, channel in ipairs(host.channels) do
    while channel:pop() ~= nil do
    end
  end
  probe.importer:update()
  Assert.equal(probe.importer.state, "idle")
end

-- A queued import publishes only after the worker validates and the game
-- thread commits: completion fires once, no external binding is written by
-- the queued path, and the shared bytes are offered for exactly one handoff.
function T.queued_import_commits_after_validation_and_hands_its_source_once()
  withQueuedHost(function(host)
    local h = harness()
    host:watch(h.importer)
    h.importer:queuePath("synthetic.nds")
    h.importer:update()
    Assert.equal(h.importer.state, "reading")
    Assert.equal(h.importer:status().canCancel, true, "active pre-commit work is cancellable")
    local session = liveSession(h.importer)
    local sessionId = assert(session.inbox:pop()).id
    Assert.isNil(h.backend.files["heartgold/rom-source.lua"], "queueing alone publishes no binding")
    Assert.isNil(h.importer:takeVerifiedSource(), "a running import offers no handoff yet")
    Assert.equal(#h.events, 0)
    session.outbox:push({ id = sessionId, kind = "status", state = "verifying", progress = 0.25 })
    h.importer:update()
    Assert.equal(h.importer.state, "verifying")
    session.outbox:push({ id = sessionId, kind = "validated" })
    h.importer:update()
    local commit = session.inbox:pop()
    Assert.notNil(commit, "validation must be answered with a commit")
    Assert.equal(commit.id, sessionId)
    Assert.equal(commit.op, "commit")
    Assert.equal(h.importer:status().canCancel, false, "commit authorization ends the cancellable window")
    Assert.isNil(session.inbox:pop(), "exactly one commit authorizes the registration")
    Assert.isNil(h.backend.files["heartgold/rom-source.lua"], "validation alone publishes no binding")
    session.outbox:push(completePacket(h, sessionId))
    h.importer:update()
    Assert.equal(h.importer.state, "complete")
    Assert.equal(h.importer:status().canCancel, false, "terminal imports are not cancellable")
    Assert.equal(#h.events, 1, "completion fires exactly once")
    Assert.equal(h.events[1], "heartgold")
    session.outbox:push(completePacket(h, sessionId))
    pump(h.importer, 2)
    Assert.equal(#h.events, 1, "a repeated late terminal packet cannot complete twice")
    local binding = CacheFs.forVersion("heartgold", h.backend):loadLua(RomBinding.PATH)
    Assert.isNil(binding, "queued completion publishes no external source binding")
    local handed = h.importer:takeVerifiedSource()
    Assert.notNil(handed, "completion offers its verified bytes once")
    Assert.equal(handed:sha1(), h.info.sha1)
    Assert.isNil(h.importer:takeVerifiedSource(), "the handoff is one-shot")
    retireWorkers(host)
    pump(h.importer, 4)
    assertLeaseFree(host)
  end)
end

-- Canceling a queued import retires its worker: the cancel reaches the
-- worker, and late results from the retired session can never publish a
-- binding, complete the import, or hand out bytes.
function T.queued_cancel_drops_late_worker_results_without_publishing()
  withQueuedHost(function(host)
    local h = harness()
    host:watch(h.importer)
    h.importer:queuePath("synthetic.nds")
    h.importer:update()
    local session = liveSession(h.importer)
    local sessionId = assert(session.inbox:pop()).id
    -- A packet for another session never moves the live import.
    session.outbox:push({ id = "not-this-session", kind = "status", state = "verifying", progress = 0.5 })
    session.outbox:push({ id = sessionId, kind = "validated" })
    h.importer:update()
    Assert.equal(h.importer.state, "reading")
    Assert.equal(h.importer.progress, 0, "a stale packet changes no visible progress")
    local commit = session.inbox:pop()
    Assert.notNil(commit, "the live validation is still answered with a commit")
    Assert.equal(commit.op, "commit")
    -- Cancel after the gate authorized the worker: the retired packet must
    -- still be excluded from durable publication and handoff.
    h.importer:cancelQueued()
    Assert.equal(h.importer.state, "idle")
    local cancel = session.inbox:pop()
    Assert.notNil(cancel, "canceling must tell the worker to abandon its session")
    Assert.equal(cancel.id, sessionId)
    Assert.equal(cancel.op, "cancel")
    session.outbox:push(completePacket(h, sessionId))
    session.outbox:push({
      id = sessionId,
      kind = "error",
      errorCode = "ROM_IMPORT_FAILED",
      message = "late",
      context = {},
    })
    session.outbox:push({ id = sessionId, kind = "status", state = "verifying", progress = 0.9 })
    retireWorkers(host)
    pump(h.importer, 5)
    Assert.equal(h.importer.state, "idle", "late packets never revive a retired import")
    Assert.equal(#h.events, 0)
    Assert.isNil(h.backend.files["heartgold/rom-source.lua"], "a retired result publishes no binding")
    Assert.isNil(h.importer:takeVerifiedSource(), "a retired import offers no handoff")
    assertLeaseFree(host)
  end)
end

-- A superseding import never starts a second worker while the canceled
-- first worker is still alive: it waits, then starts with its own session
-- once the old worker exits and drains. Old-session packets stay ignored.
function T.superseding_import_waits_for_the_live_worker_lease()
  withQueuedHost(function(host)
    local first = harness()
    local second = harness()
    host:watch(first.importer)
    host:watch(second.importer)
    first.importer:queuePath("first.nds", "first-session")
    first.importer:update()
    local firstSession = liveSession(first.importer)
    Assert.equal(assert(firstSession.inbox:pop()).id, "first-session")
    Assert.equal(#host.threads, 1)
    first.importer:cancelQueued()
    Assert.equal(first.importer.state, "idle")
    -- The retired worker is still physically alive: the newcomer waits.
    second.importer:queuePath("second.nds", "second-session")
    second.importer:update()
    pump(second.importer, 3)
    Assert.equal(#host.threads, 1, "no second worker starts while the retired one is alive")
    Assert.equal(second.importer:status().stage, "waiting")
    Assert.equal(second.importer:status().canCancel, true, "lease-waiting pre-commit work is cancellable")
    -- Late packets from the retired session are drained, never published.
    firstSession.outbox:push(completePacket(first, "first-session"))
    pump(first.importer, 2)
    Assert.equal(first.importer.state, "idle")
    Assert.equal(#first.events, 0)
    Assert.isNil(first.backend.files["heartgold/rom-source.lua"])
    -- Only once the old worker exits does the waiting import start.
    retireWorkers(host)
    second.importer:update()
    Assert.equal(#host.threads, 2, "the waiting import starts after the old worker exits")
    local secondSession = liveSession(second.importer)
    local request = secondSession.inbox:pop()
    Assert.notNil(request)
    Assert.equal(request.id, "second-session")
    -- An old-session result in the new outbox is ignored; only the live
    -- session's result publishes.
    secondSession.outbox:push(completePacket(second, "first-session"))
    secondSession.outbox:push(completePacket(second, "second-session"))
    second.importer:update()
    Assert.equal(second.importer.state, "complete")
    Assert.equal(#second.events, 1)
    Assert.equal(second.events[1], "heartgold")
    local binding = CacheFs.forVersion("heartgold", second.backend):loadLua(RomBinding.PATH)
    Assert.isNil(binding, "queued completion publishes no external source binding")
    Assert.equal(#first.events, 0, "the retired session never completes")
    Assert.isNil(first.importer:takeVerifiedSource())
    retireWorkers(host)
    pump(second.importer, 4)
    assertLeaseFree(host)
  end)
end

-- A worker that dies without answering earns exactly one retry; a second
-- death fails the import with nothing published. A logical worker error
-- fails at once and never retries.
function T.lost_worker_retries_once_then_fails_while_logic_errors_do_not_retry()
  withQueuedHost(function(host)
    local h = harness()
    host:watch(h.importer)
    h.importer:queuePath("synthetic.nds")
    h.importer:update()
    local firstSession = liveSession(h.importer)
    local firstId = assert(firstSession.inbox:pop()).id
    Assert.equal(#host.threads, 1)
    -- Progress alone is not a result: the worker then dies silently.
    firstSession.outbox:push({ id = firstId, kind = "status", state = "verifying", progress = 0.4 })
    h.importer:update()
    Assert.equal(h.importer.state, "verifying")
    Assert.equal(#h.events, 0)
    firstSession.thread.alive = false
    h.importer:update()
    Assert.equal(#host.threads, 2, "a lost worker earns exactly one retry")
    Assert.isTrue(h.importer:isBusy(), "the retry keeps the import in flight")
    local retrySession = liveSession(h.importer)
    Assert.isTrue(retrySession.thread ~= firstSession.thread, "the retry runs on a new worker")
    local retryId = assert(retrySession.inbox:pop()).id
    Assert.isTrue(retryId ~= firstId, "the retry is a distinct session")
    -- The retry dies too: terminal error, no third worker, nothing published.
    retrySession.thread.alive = false
    h.importer:update()
    Assert.equal(h.importer.state, "error")
    Assert.equal(h.importer:status().errorCode, "IMPORT_WORKER_LOST")
    pump(h.importer, 3)
    Assert.equal(#host.threads, 2, "no third worker ever starts")
    Assert.equal(#h.events, 0)
    Assert.isNil(h.backend.files["heartgold/rom-source.lua"], "a lost worker publishes no binding")
    Assert.isNil(h.importer:takeVerifiedSource(), "a failed import offers no handoff")
    -- A logical worker error fails at once with no retry.
    local failed = harness()
    host:watch(failed.importer)
    failed.importer:queuePath("synthetic.nds")
    failed.importer:update()
    Assert.isTrue(failed.importer:status().stage ~= "waiting", "the freed lease admits the next import")
    local failedSession = liveSession(failed.importer)
    local failedId = assert(failedSession.inbox:pop()).id
    failedSession.outbox:push({
      id = failedId,
      kind = "error",
      errorCode = "NDS_UNKNOWN_ROM",
      message = "the worker rejected the cartridge",
      context = {},
    })
    failed.importer:update()
    Assert.equal(failed.importer.state, "error")
    Assert.equal(failed.importer:status().errorCode, "NDS_UNKNOWN_ROM")
    Assert.equal(#host.threads, 3, "a validation failure starts no retry worker")
    Assert.isNil(failed.backend.files["heartgold/rom-source.lua"])
    Assert.equal(#failed.events, 0)
    retireWorkers(host)
    for _ = 1, 6 do
      h.importer:update()
      failed.importer:update()
    end
    assertLeaseFree(host)
  end)
end

-- Temporary picker files transfer ownership only after the importer accepts
-- them. Rejections leave the caller's file untouched; accepted files are
-- removed by the importer after source closure, including cancellation and
-- synchronous worker-start failure.
local function queueTemporary(importer, path, requestId)
  Assert.equal(
    type(importer.queueTemporaryPath),
    "function",
    "temporary picker input needs an explicit ownership-transfer queue operation"
  )
  return importer:queueTemporaryPath(path, requestId)
end

function T.temporary_path_rejections_and_busy_admission_preserve_caller_ownership()
  local Fixture = require("tests.support.ManagedRomFixture")
  local Errors = require("libs.errors.src.Errors")
  Fixture.with(function(fixture)
    local importer = fixture.host:importer(fixture.cart)
    for _, path in ipairs({
      fixture.originalPath,
      "../original.nds",
      "imports/../original.nds",
      "imports/bad.token.nds",
      "imports/bad\\name.nds",
    }) do
      local accepted, err = queueTemporary(importer, path)
      Assert.isNil(accepted, "unsafe temporary path must be rejected: " .. path)
      Assert.isTrue(Errors.is(err), "unsafe path rejection must be typed")
      Assert.equal(err.code, "ROM_IMPORT_REQUEST_INVALID")
    end
    Assert.isTrue(fixture:originalExists(), "rejection must leave the caller-owned original intact")
    local missing, missingErr = queueTemporary(importer, "imports/missing.nds")
    Assert.isNil(missing)
    Assert.equal(assert(missingErr).code, "ROM_OPEN_FAILED")
    local directoryPath = "imports/directory-" .. fixture.label .. ".nds"
    Assert.isNil(love.filesystem.getInfo(directoryPath), "directory fixture must be unowned")
    Assert.isTrue(love.filesystem.createDirectory(directoryPath), "directory fixture setup failed")
    local directory, directoryErr = queueTemporary(importer, directoryPath)
    Assert.isNil(directory)
    Assert.equal(assert(directoryErr).code, "ROM_OPEN_FAILED")
    Assert.equal(love.filesystem.getInfo(directoryPath).type, "directory")
    Assert.isTrue(love.filesystem.remove(directoryPath), "directory fixture cleanup failed")

    fixture.host.holdValidation = true
    local acceptedPath = fixture:writeTemporary("accepted")
    local busyPath = fixture:writeTemporary("busy")
    Assert.isTrue(
      queueTemporary(importer, acceptedPath, "accepted-session"),
      "an existing safe stage transfers ownership"
    )
    local session = fixture.host:validationGate(importer)
    local busy, busyErr = queueTemporary(importer, busyPath, "busy-session")
    Assert.isNil(busy, "a busy importer rejects a second temporary stage")
    Assert.equal(assert(busyErr).code, "IMPORT_BUSY")
    Assert.notNil(love.filesystem.getInfo(busyPath), "busy rejection keeps caller ownership")
    Assert.notNil(love.filesystem.getInfo(acceptedPath), "the accepted stage remains live while borrowed")
    Assert.equal(importer:status().canCancel, true, "pre-commit temporary work is cancellable")
    importer:cancelQueued()
    session.outbox:discardValidation()
    fixture.host:waitFor(function()
      importer:update()
      return love.filesystem.getInfo(acceptedPath) == nil
    end, "accepted temporary cleanup after cancellation")
    Assert.notNil(love.filesystem.getInfo(busyPath), "only the accepted temporary file may be removed")
    Assert.isTrue(fixture:originalExists(), "the caller-owned original is never deleted")
  end)
end

function T.accepted_temporary_success_and_active_read_cancellation_close_before_removal()
  local Fixture = require("tests.support.ManagedRomFixture")
  Fixture.with(function(fixture)
    local successPath = fixture:writeTemporary("success")
    local success = fixture.host:importer(fixture.cart)
    Assert.isTrue(queueTemporary(success, successPath, "temporary-success"), "temporary success transfers ownership")
    fixture.host:finish(success, "complete")
    Assert.isNil(love.filesystem.getInfo(successPath), "success removes the accepted input after terminal cleanup")
    Assert.notNil(love.filesystem.getInfo(fixture.canonical), "temporary success still publishes managed storage")
    local published = love.filesystem.read(fixture.canonical)
    local handed = success:takeVerifiedSource()
    Assert.notNil(handed)
    handed:release()

    local canceledPath = fixture:writeTemporary("canceled")
    fixture.host.prelude = [[
local testControl = select(4, ...)
local token = "canceled"
local function trace(event)
  outbox:push({ kind = "test-trace", event = event })
end
local realOpen = io.open
io.open = function(path, mode)
  if type(path) == "string" and path:find(token, 1, true) then
    trace("read-started")
    testControl:demand()
  end
  local file, message = realOpen(path, mode)
  if file and type(path) == "string" and path:find(token, 1, true) then
    return setmetatable({}, {
      __index = function(_, key)
        if key == "close" then
          return function()
            local result = file:close()
            trace("source-closed")
            return result
          end
        end
        local member = file[key]
        if type(member) == "function" then
          return function(_, ...)
            return member(file, ...)
          end
        end
        return member
      end,
    })
  end
  return file, message
end
local realRemove = love.filesystem.remove
love.filesystem.remove = function(path)
  local result, message = realRemove(path)
  if type(path) == "string" and path:find(token, 1, true) then
    trace("input-removed")
  end
  return result, message
end
]]
    local canceled = fixture.host:importer(fixture.cart)
    Assert.isTrue(
      queueTemporary(canceled, canceledPath, "temporary-canceled"),
      "active temporary input transfers ownership"
    )
    local thread = assert(canceled._queued, "the real worker must start").thread
    fixture.host:waitFor(function()
      canceled:update()
      return fixture.host.trace[1] ~= nil and fixture.host.trace[1].event == "read-started"
    end, "the worker's active source read")
    Assert.notNil(love.filesystem.getInfo(canceledPath), "an active input remains live while borrowed")
    Assert.equal(canceled:status().canCancel, true)
    canceled:cancelQueued()
    fixture.host.control:push(true)
    fixture.host:waitFor(function()
      canceled:update()
      return not thread:isRunning() and love.filesystem.getInfo(canceledPath) == nil
    end, "active source close and temporary removal")
    local closedAt, removedAt
    for index, event in ipairs(fixture.host.trace) do
      if event.event == "source-closed" then
        closedAt = index
      elseif event.event == "input-removed" then
        removedAt = index
      end
    end
    Assert.notNil(closedAt, "the active source handle must close")
    Assert.notNil(removedAt, "the importer must remove its accepted input")
    Assert.isTrue(closedAt < removedAt, "temporary removal must follow source close")
    Assert.equal(love.filesystem.read(fixture.canonical), published, "active-read cancellation publishes nothing")
    Assert.isTrue(fixture:originalExists(), "cancellation never deletes the caller-owned original")
  end)
end

function T.pending_temporary_cancel_and_worker_start_failure_have_one_owner()
  local Fixture = require("tests.support.ManagedRomFixture")
  Fixture.with(function(fixture)
    fixture.host.holdValidation = true
    local active = fixture.host:importer(fixture.cart)
    active:queuePath(fixture.originalPath)
    local activeSession = fixture.host:validationGate(active)
    Assert.equal(#fixture.host.threads, 1, "one physical import worker is live")

    local pendingPath = fixture:writeTemporary("pending")
    local pending = fixture.host:importer(fixture.cart)
    Assert.isTrue(
      queueTemporary(pending, pendingPath, "pending-session"),
      "a lease-waiting temporary stage transfers ownership"
    )
    pending:update()
    Assert.equal(pending:status().stage, "waiting")
    Assert.equal(#fixture.host.threads, 1, "a pending request starts no second physical worker")
    pending:cancelQueued()
    Assert.isNil(love.filesystem.getInfo(pendingPath), "pending cancellation removes its stage immediately")
    active:cancelQueued()
    activeSession.outbox:discardValidation()
    fixture.host:waitFor(function()
      active:update()
      return not fixture.host.threads[1]:isRunning()
    end, "the prior physical worker exit")

    local failedPath = fixture:writeTemporary("startup-failure")
    fixture.host.failNextStart = true
    local failed = fixture.host:importer(fixture.cart)
    Assert.isTrue(
      queueTemporary(failed, failedPath, "startup-failure"),
      "acceptance remains true after synchronous startup failure"
    )
    Assert.equal(failed.state, "error", "startup failure state: " .. tostring(failed:status().stage))
    Assert.equal(failed:status().errorCode, "IMPORT_WORKER_UNAVAILABLE")
    Assert.isNil(love.filesystem.getInfo(failedPath), "the importer cleans its file after accepted startup failure")
    Assert.equal(#fixture.host.threads, 1, "failed startup creates no physical worker")
    Assert.isTrue(fixture:originalExists(), "startup failure leaves the caller-owned original intact")
  end)
end

function T.lost_temporary_worker_is_not_retried_after_its_file_is_removed()
  local Fixture = require("tests.support.ManagedRomFixture")
  Fixture.with(function(fixture)
    local path = fixture:writeTemporary("worker-lost")
    local ok, err = pcall(function()
      withQueuedHost(function(host)
        local h = harness()
        host:watch(h.importer)
        Assert.isTrue(queueTemporary(h.importer, path, "lost-temporary"), "temporary loss request transfers ownership")
        h.importer:update()
        local session = liveSession(h.importer)
        Assert.equal(assert(session.inbox:pop()).id, "lost-temporary")
        Assert.equal(#host.threads, 1)
        session.thread.alive = false
        h.importer:update()
        Assert.equal(h.importer.state, "error")
        Assert.equal(h.importer:status().errorCode, "IMPORT_WORKER_LOST")
        Assert.equal(#host.threads, 1, "a deleted temporary path is never retried automatically")
        Assert.isNil(love.filesystem.getInfo(path), "terminal worker loss removes the accepted temporary input")
        Assert.equal(#h.events, 0)
        retireWorkers(host)
        pump(h.importer, 4)
        assertLeaseFree(host)
      end)
    end)
    if not ok then
      error(err, 0)
    end
  end)
end

function T.queued_import_publishes_verified_icon_after_commit_and_reuses_its_path()
  ManagedRomIconFixture.with(function(fixture)
    local edition = fixture.heartgold
    local banner = fixture.heartGoldBanner
    SaveFs.forVersion("heartgold"):write("sentinel.lua", "SAVE-SENTINEL")
    CacheFs.forVersion("heartgold"):write("derived/sentinel.lua", "CACHE-SENTINEL")
    fixture.host.holdValidation = true
    local importer = fixture.host:importer(edition.cart, nil, "heartgold")
    importer:queuePath(edition.originalPath)
    local session = fixture.host:validationGate(importer)
    Assert.isNil(love.filesystem.getInfo(edition.canonical), "validation alone publishes no source")
    Assert.isNil(love.filesystem.getInfo(edition.icon), "validation alone publishes no icon")
    Assert.isNil(love.filesystem.getInfo(edition.iconStage), "validation creates no sidecar stage")
    session.outbox:releaseValidation()
    fixture.host.holdValidation = false
    fixture.host:finish(importer, "complete")
    local handed = importer:takeVerifiedSource()
    Assert.notNil(handed, "a completed import still offers its verified source once")
    Assert.equal(handed:sha1(), edition.cart.sha1)
    handed:release()
    Assert.isNil(importer:takeVerifiedSource())
    local members = edition:managedMembers()
    Assert.deepEqual(members.names, { "game.nds" })
    Assert.equal(members.bytes, edition.cart.data)
    local iconBytes = readIfPresent(edition.icon)
    Assert.notNil(iconBytes, "a completed verified import must publish its static banner sidecar")
    local width, height, rgba = PngReader.rgba(assert(iconBytes))
    Assert.equal(width, 32)
    Assert.equal(height, 32)
    Assert.equal(rgba, banner.rgba)
    local firstIcon = readIfPresent(edition.icon)

    local duplicate = fixture.host:importer(edition.cart, nil, "heartgold")
    duplicate:queuePath(edition.originalPath)
    fixture.host:finish(duplicate, "complete")
    local duplicateHandoff = duplicate:takeVerifiedSource()
    Assert.notNil(duplicateHandoff)
    duplicateHandoff:release()
    Assert.equal(readIfPresent(edition.icon), firstIcon, "reimporting one immutable SHA reuses its canonical icon")
    Assert.isNil(love.filesystem.getInfo(edition.iconStage))
    Assert.isNil(love.filesystem.getInfo(edition.iconBackup))
    Assert.equal(SaveFs.forVersion("heartgold"):read("sentinel.lua"), "SAVE-SENTINEL")
    Assert.equal(CacheFs.forVersion("heartgold"):read("derived/sentinel.lua"), "CACHE-SENTINEL")
  end)
end

function T.optional_icon_failure_keeps_source_and_prior_icon_while_cancel_stays_atomic()
  ManagedRomIconFixture.with(function(fixture)
    local edition = fixture.heartgold
    installManagedIcon(edition.cart, fixture.heartGoldBanner)
    local sourceBefore = readIfPresent(edition.canonical)
    local iconBefore = readIfPresent(edition.icon)
    SaveFs.forVersion("heartgold"):write("sentinel.lua", "SAVE-SENTINEL")
    CacheFs.forVersion("heartgold"):write("derived/sentinel.lua", "CACHE-SENTINEL")

    fixture.host.holdValidation = true
    local canceled = fixture.host:importer(edition.cart, nil, "heartgold")
    canceled:queuePath(edition.originalPath)
    local session = fixture.host:validationGate(canceled)
    Assert.notNil(love.filesystem.getInfo(edition.stage), "the prepared source exists before authorization")
    Assert.isNil(love.filesystem.getInfo(edition.iconStage), "precommit work creates no icon stage")
    canceled:cancelQueued()
    session.outbox:discardValidation()
    fixture.host:waitFor(function()
      canceled:update()
      return not session.thread:isRunning()
    end, "canceled import worker exit")
    Assert.equal(readIfPresent(edition.canonical), sourceBefore, "precommit cancellation preserves source")
    Assert.equal(readIfPresent(edition.icon), iconBefore, "precommit cancellation preserves icon")
    Assert.isNil(love.filesystem.getInfo(edition.stage))
    Assert.isNil(love.filesystem.getInfo(edition.iconStage))

    fixture.host.holdValidation = false
    fixture.host.prelude = [[
local realNewFile = love.filesystem.newFile
love.filesystem.newFile = function(path, mode)
  if type(path) == "string" and path:match("%.png%.new$") then
    return nil, "injected sidecar stage failure"
  end
  return realNewFile(path, mode)
end
local realWrite = love.filesystem.write
love.filesystem.write = function(path, ...)
  if type(path) == "string" and path:match("%.png%.new$") then
    return false, "injected sidecar write failure"
  end
  return realWrite(path, ...)
end
]]
    local importer = fixture.host:importer(edition.cart, nil, "heartgold")
    importer:queuePath(edition.archivePath)
    fixture.host:finish(importer, "complete")
    Assert.equal(importer:status().versionId, "heartgold", "optional icon failure cannot fail a verified source")
    local handed = importer:takeVerifiedSource()
    Assert.notNil(handed)
    Assert.equal(handed:sha1(), edition.cart.sha1)
    handed:release()
    Assert.notNil(love.filesystem.getInfo(edition.canonical), "the verified source remains installed")
    Assert.equal(readIfPresent(edition.icon), iconBefore, "failed sidecar replacement preserves the old icon")
    Assert.isNil(love.filesystem.getInfo(edition.iconStage))
    Assert.equal(SaveFs.forVersion("heartgold"):read("sentinel.lua"), "SAVE-SENTINEL")
    Assert.equal(CacheFs.forVersion("heartgold"):read("derived/sentinel.lua"), "CACHE-SENTINEL")
  end)
end

function T.targeted_import_channels_reject_wrong_edition_and_generic_drop_detects()
  ManagedRomIconFixture.with(function(fixture)
    local heartGold = fixture.heartgold
    local soulSilver = fixture.soulsilver
    Assert.equal(type(RomArchive.iconPath), "function", "managed sidecar paths are required")
    installManagedIcon(heartGold.cart, fixture.heartGoldBanner)
    installManagedIcon(soulSilver.cart, fixture.soulSilverBanner)
    for _, versionId in ipairs({ "heartgold", "soulsilver" }) do
      SaveFs.forVersion(versionId):write("sentinel.lua", versionId .. "-SAVE")
      CacheFs.forVersion(versionId):write("derived/sentinel.lua", versionId .. "-CACHE")
    end
    local before = {
      heartgold = editionSnapshot(heartGold),
      soulsilver = editionSnapshot(soulSilver),
    }
    local function assertMismatch(importer)
      fixture.host:finish(importer, "error")
      Assert.equal(importer:status().errorCode, "ROM_VERSION_MISMATCH")
      local failure = assert(importer:status().error)
      Assert.equal(failure.context.expectedVersionId, "heartgold")
      Assert.equal(failure.context.actualVersionId, "soulsilver")
      Assert.isNil(importer:takeVerifiedSource())
      Assert.deepEqual(editionSnapshot(heartGold), before.heartgold, "wrong path target changes no HeartGold data")
      Assert.deepEqual(editionSnapshot(soulSilver), before.soulsilver, "wrong path target changes no SoulSilver data")
    end

    local pathImport = fixture.host:importer(soulSilver.cart, nil, "heartgold")
    pathImport:queuePath(soulSilver.originalPath)
    assertMismatch(pathImport)

    local soulSilverZip = ZipBuilder.build({ { name = "game.nds", data = soulSilver.cart.data } })
    local dropImport = fixture.host:importer({ versions = fixture.catalog }, nil, "heartgold")
    dropImport:queueDroppedFile(dropBytes("heartgold.zip", soulSilverZip))
    assertMismatch(dropImport)

    local temporaryPath = heartGold:writeTemporary("wrong-edition", soulSilver.cart.data)
    local temporaryImport = fixture.host:importer({ versions = fixture.catalog }, nil, "heartgold")
    Assert.isTrue(temporaryImport:queueTemporaryPath(temporaryPath, "wrong-edition-session"))
    assertMismatch(temporaryImport)
    Assert.isNil(love.filesystem.getInfo(temporaryPath), "terminal temporary rejection removes only the accepted stage")

    local correctPath = heartGold:writeTemporary("correct-edition", heartGold.cart.data)
    local correctImport = fixture.host:importer(heartGold.cart, nil, "heartgold")
    Assert.isTrue(correctImport:queueTemporaryPath(correctPath, "correct-edition-session"))
    fixture.host:finish(correctImport, "complete")
    Assert.equal(correctImport:status().versionId, "heartgold")
    Assert.deepEqual(
      editionSnapshot(heartGold),
      before.heartgold,
      "correct targeted import keeps the same source and icon path"
    )
    local correctHandoff = correctImport:takeVerifiedSource()
    Assert.notNil(correctHandoff)
    correctHandoff:release()

    for _, edition in ipairs({ heartGold, soulSilver }) do
      for _, path in ipairs({ edition.canonical, edition.icon }) do
        Assert.isTrue(love.filesystem.remove(path), "generic-drop fixture cleanup failed")
      end
    end
    local mixedZip = ZipBuilder.build({
      { name = "heartgold.nds", data = heartGold.cart.data },
      { name = "soulsilver.nds", data = soulSilver.cart.data },
    })
    local generic = fixture.host:importer({ versions = fixture.catalog })
    generic:queueDroppedFile(dropBytes("mixed.zip", mixedZip))
    fixture.host:finish(generic, "complete")
    local detectedId = generic:status().versionId
    Assert.isTrue(
      detectedId == "heartgold" or detectedId == "soulsilver",
      "generic ZIP detection must choose a supported edition"
    )
    local detected = detectedId == "heartgold" and heartGold or soulSilver
    local expected = detectedId == "heartgold" and fixture.heartGoldBanner or fixture.soulSilverBanner
    Assert.notNil(love.filesystem.getInfo(detected.canonical), "generic detection publishes its detected source")
    local width, height, rgba = PngReader.rgba(assert(readIfPresent(detected.icon)))
    Assert.equal(width, 32)
    Assert.equal(height, 32)
    Assert.equal(rgba, expected.rgba, "the published icon matches the generically detected SHA")
    for _, versionId in ipairs({ "heartgold", "soulsilver" }) do
      Assert.equal(SaveFs.forVersion(versionId):read("sentinel.lua"), versionId .. "-SAVE")
      Assert.equal(CacheFs.forVersion(versionId):read("derived/sentinel.lua"), versionId .. "-CACHE")
    end
  end)
end

return { tests = T }
