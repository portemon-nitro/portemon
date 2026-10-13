local Assert = require("tests.support.Assert")
local RomImporter = require("romdump.src.source.RomImporter")
local RomSource = require("romdump.src.source.RomSource")
local NdsBuilder = require("tests.support.NdsBuilder")
local DumpFixture = require("tests.support.DumpFixture")
local CacheFs = require("libs.storage.src.CacheFs")
local SaveFs = require("libs.storage.src.SaveFs")
local FakeCache = require("tests.support.FakeCache")

local T = {}

local HG = "heartgold/"

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
  Assert.equal(h.importer:status().versionId, "heartgold")
  Assert.equal(h.importer.progress, 1)
  Assert.isTrue(RomImporter.isReady("heartgold", CacheFs.forVersion("heartgold", h.backend), h.versions))
  Assert.equal(h.events[1], "heartgold")
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
  Assert.deepEqual(
    cache:loadLua("rom-source.lua"),
    first,
    "re-registering the same ROM keeps its binding"
  )
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
  local ArtifactState = require("romdump.src.build.ArtifactState")
  local h = harness()
  local cache = CacheFs.forVersion("heartgold", h.backend)
  local generation = "failed-rebind-generation"
  cache:writeLua(ArtifactState.path("field-font", "global"), {
    schema = ArtifactState.RECEIPT_SCHEMA,
    generationId = generation,
    kind = "field-font",
    key = "global",
    marker = "prior-receipt",
  })
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
  Assert.notNil(
    cache:loadLua(ArtifactState.path("field-font", "global")),
    "a failed re-import keeps its prior receipts"
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
  local ArtifactState = require("romdump.src.build.ArtifactState")
  local generation = "rebind-generation"
  cache:writeLua(ArtifactState.path("field-font", "global"), {
    schema = ArtifactState.RECEIPT_SCHEMA,
    generationId = generation,
    kind = "field-font",
    key = "global",
    marker = "prior-receipt",
  })
  cache:write("maps/60/complete", "ready")
  SaveFs.forVersion("heartgold", h.backend):write("field-session.lua", "SAVE-DATA")
  h.importer:startSource(RomSource.fromString(h.data, "hg.nds"))
  runToTerminal(h.importer)
  Assert.equal(h.importer.state, "complete")
  local receipt = cache:loadLua(ArtifactState.path("field-font", "global"))
  Assert.notNil(receipt, "the same-ROM rebind keeps its prior receipts")
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

return { tests = T }
