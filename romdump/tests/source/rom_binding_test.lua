-- Persists only the location and identity of a user-owned cartridge so a later
-- boot can find the same ROM again without keeping a copy of its bytes. Every
-- fixture is a synthetic in-memory cartridge plus an in-memory cache; no ROM
-- bytes are committed and no extracted tree is involved.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local GameVersion = require("romdump.src.source.GameVersion")
local NdsBuilder = require("tests.support.NdsBuilder")
local NdsRom = require("romdump.src.source.NdsRom")
local RomSource = require("romdump.src.source.RomSource")

local T = {}

local VERSION_ID = "synthcartridge"
local BINDING_KEY = VERSION_ID .. "/rom-source.lua"
local GAME_CODE = "IXXX"

local function cartridgeSpec(overlayPayload)
  return {
    gameCode = GAME_CODE,
    title = "SYNTH",
    overlays9 = { overlayPayload or "OVERLAY0-DATA" },
    unmapped = { "UNMAPPED-DATA" },
    tree = { files = { { name = "root.bin", content = "ROOT" } }, dirs = {} },
  }
end

local function openCartridge(spec)
  local data = NdsBuilder.build(spec)
  local info = {
    id = VERSION_ID,
    sha1 = RomSource.fromString(data):sha1(),
    gameCode = spec.gameCode or GAME_CODE,
    expectedSize = #data,
  }
  local versions = {
    forSha1 = function(h)
      return h == info.sha1 and info or nil
    end,
    forGameCode = function(c)
      return c == info.gameCode and info or nil
    end,
  }
  local rom, err = NdsRom.open(RomSource.fromString(data), versions)
  Assert.notNil(rom, "synthetic cartridge failed to open: " .. Errors.format(err))
  return data, assert(rom), info
end

-- Temporarily catalogues the synthetic cartridge under VERSION_ID so identity
-- checks that consult the shared version table can recognize it. Restores the
-- table even when the body fails.
local function withCataloguedVersion(info, fn)
  local saved = GameVersion.VERSIONS[VERSION_ID]
  GameVersion.VERSIONS[VERSION_ID] = {
    id = VERSION_ID,
    label = "Synthetic",
    displayName = "Synthetic Cartridge",
    sha1 = info.sha1,
    gameCode = info.gameCode,
    expectedSize = info.expectedSize,
  }
  local ok, err = pcall(fn)
  GameVersion.VERSIONS[VERSION_ID] = saved
  if not ok then
    error(err, 0)
  end
end

local function requireLocationOwner()
  local ok, owner = pcall(require, "romdump.src.source.RomBinding")
  Assert.isTrue(ok, "expected a persisted source-location owner that survives restarts without reopening the ROM")
  owner = assert(owner)
  Assert.isTrue(type(owner.record) == "function", "expected the location owner to validate and replace registrations")
  Assert.isTrue(type(owner.read) == "function", "expected the location owner to report the persisted registration")
  return owner
end

local function freshCache(backend)
  return CacheFs.forVersion(VERSION_ID, backend or FakeCache.new())
end

-- Calls owner.record and normalizes both failure shapes (returned nil plus
-- error, or a raised error) into one (replaced, err) pair.
local function tryRecord(owner, cache, rom, descriptor)
  local results = { pcall(owner.record, cache, rom, descriptor) }
  if not results[1] then
    return false, results[2]
  end
  if results[2] == true then
    return true, nil
  end
  return false, results[3]
end

-- Calls owner.read through pcall so a raising implementation is still reported
-- as a test failure rather than an aborted suite.
local function tryRead(owner, cache, versionId)
  local results = { pcall(owner.read, cache, versionId) }
  if not results[1] then
    return nil, results[2]
  end
  return results[2], results[3]
end

local function sortedKeysOf(files)
  local keys = {}
  for key in pairs(files) do
    keys[#keys + 1] = key
  end
  table.sort(keys)
  return keys
end

local function shellQuote(value)
  return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function commandSucceeded(status)
  return status == 0 or status == true
end

-- One atomically acquired scratch directory per invocation holds this case's
-- reopenable fixture file. Only the acquired root is ever removed.
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

function T.persists_validated_location_and_survives_restart_without_touching_the_rom()
  local owner = requireLocationOwner()
  withOwnedRoot(function(root)
    local backend = FakeCache.new()
    local data, rom, info = openCartridge(cartridgeSpec())
    local romPath = root .. "/game.nds"
    local writer = assert(io.open(romPath, "wb"))
    writer:write(data)
    assert(writer:close())
    withCataloguedVersion(info, function()
      local cache = freshCache(backend)
      local replaced, recordErr = tryRecord(owner, cache, rom, {
        kind = "nds",
        path = romPath,
        displayName = "game.nds",
        zipEntry = false,
      })
      Assert.isTrue(replaced, "expected the validated location to persist; got: " .. tostring(recordErr))

      -- A binding-only restart must not reopen the ROM file at all.
      local restarted = freshCache(backend)
      local realOpen = io.open
      io.open = function()
        error("binding-only restart must not reopen the ROM")
      end
      local binding, readErr = tryRead(owner, restarted, VERSION_ID)
      io.open = realOpen
      Assert.notNil(binding, "expected the persisted location without ROM access; got: " .. tostring(readErr))
      assert(binding)
      Assert.keySet(binding, "displayName,kind,path,romSha1,schema,versionId,zipEntry")
      Assert.equal(binding.schema, 1)
      Assert.equal(binding.versionId, VERSION_ID)
      Assert.equal(binding.romSha1, info.sha1)
      Assert.equal(#binding.romSha1, 40)
      Assert.isTrue(binding.romSha1:match("^%x+$") ~= nil, "identity must be lowercase hex")
      Assert.equal(binding.kind, "nds")
      Assert.equal(binding.path, romPath)
      Assert.equal(binding.displayName, "game.nds")
      Assert.isTrue(binding.zipEntry == false, "a bare cartridge has no archive member")

      -- Only binding metadata may sit under the test cache: no ROM payload.
      Assert.deepEqual(sortedKeysOf(backend.files), { BINDING_KEY })
      for _, value in pairs(backend.files) do
        if type(value) == "string" then
          Assert.isTrue(value:find("OVERLAY0-DATA", 1, true) == nil, "no ROM payload may persist under the cache")
        end
      end
    end)
  end)
end

function T.rejected_replacement_keeps_the_previous_location_and_derived_files()
  local owner = requireLocationOwner()
  local backend = FakeCache.new()
  local cache = freshCache(backend)
  local _, romA, infoA = openCartridge(cartridgeSpec("OVERLAY0-DATA"))
  local _, romB, _ = openCartridge(cartridgeSpec("OTHER-DATA"))
  withCataloguedVersion(infoA, function()
    local replaced, recordErr = tryRecord(owner, cache, romA, {
      kind = "nds",
      path = "/reopenable/game-a.nds",
      displayName = "game-a.nds",
      zipEntry = false,
    })
    Assert.isTrue(replaced, "setup registration failed: " .. tostring(recordErr))
    cache:write("data/generated/peer.lua", "return 1")
    local before = cache:read("rom-source.lua")

    local kept, rejErr = tryRecord(owner, cache, romB, {
      kind = "nds",
      path = "/reopenable/game-b.nds",
      displayName = "game-b.nds",
      zipEntry = false,
    })
    Assert.isFalse(kept, "a mismatching cartridge must not replace the registered location")
    Assert.isTrue(Errors.is(rejErr), "rejection must be a typed error, got: " .. tostring(rejErr))
    Assert.equal(cache:read("rom-source.lua"), before)
    Assert.equal(cache:read("data/generated/peer.lua"), "return 1")
    local binding = tryRead(owner, cache, VERSION_ID)
    Assert.notNil(binding, "the previous registration must stay readable")
    Assert.equal(assert(binding).romSha1, infoA.sha1)
  end)
end

function T.failed_rename_keeps_the_previous_location_and_derived_files()
  local owner = requireLocationOwner()
  local backend = FakeCache.new()
  local cache = freshCache(backend)
  local _, rom, info = openCartridge(cartridgeSpec())
  withCataloguedVersion(info, function()
    local replaced, recordErr = tryRecord(owner, cache, rom, {
      kind = "nds",
      path = "/reopenable/game.nds",
      displayName = "game.nds",
      zipEntry = false,
    })
    Assert.isTrue(replaced, "setup registration failed: " .. tostring(recordErr))
    cache:write("data/generated/peer.lua", "return 1")
    local before = cache:read("rom-source.lua")

    backend.replace = function()
      return nil, "injected rename failure"
    end
    local kept, renameErr = tryRecord(owner, cache, rom, {
      kind = "nds",
      path = "/reopenable/game-moved.nds",
      displayName = "game-moved.nds",
      zipEntry = false,
    })
    Assert.isFalse(kept, "a failed atomic replacement must report failure")
    Assert.notNil(renameErr, "a failed atomic replacement must return its cause")
    Assert.equal(cache:read("rom-source.lua"), before)
    Assert.equal(cache:read("data/generated/peer.lua"), "return 1")
    local binding = tryRead(owner, cache, VERSION_ID)
    Assert.notNil(binding, "the previous registration must stay readable after a failed rename")
    Assert.equal(assert(binding).path, "/reopenable/game.nds")
  end)
end

function T.dropped_file_without_a_stable_path_is_recorded_as_unreopenable()
  local owner = requireLocationOwner()
  local backend = FakeCache.new()
  local _, rom, info = openCartridge(cartridgeSpec())
  withCataloguedVersion(info, function()
    local replaced, recordErr = tryRecord(owner, freshCache(backend), rom, {
      kind = "nds",
      path = false,
      displayName = "dropped.nds",
      zipEntry = false,
    })
    Assert.isTrue(replaced, "expected the unreopenable drop to persist; got: " .. tostring(recordErr))

    local binding, readErr = tryRead(owner, freshCache(backend), VERSION_ID)
    Assert.notNil(binding, "expected the persisted drop registration; got: " .. tostring(readErr))
    assert(binding)
    Assert.isTrue(binding.path == false, "an unreopenable drop must persist an explicit false, not nil or a label")
    Assert.isTrue(binding.zipEntry == false, "a bare drop has no archive member")
    Assert.equal(binding.kind, "nds")
    Assert.equal(binding.displayName, "dropped.nds")
    Assert.deepEqual(sortedKeysOf(backend.files), { BINDING_KEY })
  end)
end

function T.mismatched_container_descriptors_are_rejected()
  local owner = requireLocationOwner()
  local backend = FakeCache.new()
  local cache = freshCache(backend)
  local _, rom, info = openCartridge(cartridgeSpec())
  withCataloguedVersion(info, function()
    local replaced, recordErr = tryRecord(owner, cache, rom, {
      kind = "nds",
      path = "/reopenable/game.nds",
      displayName = "game.nds",
      zipEntry = false,
    })
    Assert.isTrue(replaced, "setup registration failed: " .. tostring(recordErr))
    local before = cache:read("rom-source.lua")

    local badDescriptors = {
      { kind = "nds", path = "/reopenable/game.nds", displayName = "game.nds", zipEntry = "stale/member.nds" },
      { kind = "zip", path = "/reopenable/game.zip", displayName = "game.zip", zipEntry = false },
      { kind = "tape", path = "/reopenable/game.nds", displayName = "game.nds", zipEntry = false },
    }
    for _, descriptor in ipairs(badDescriptors) do
      local kept, rejErr = tryRecord(owner, cache, rom, descriptor)
      Assert.isFalse(kept, "a mismatched container descriptor must not replace the registration")
      Assert.isTrue(Errors.is(rejErr), "descriptor rejection must be typed, got: " .. tostring(rejErr))
      Assert.equal(cache:read("rom-source.lua"), before)
    end
  end)
end

function T.missing_location_is_reported_distinctly_from_a_malformed_record()
  local owner = requireLocationOwner()
  local cache = freshCache()

  local absent, absenceErr = tryRead(owner, cache, VERSION_ID)
  Assert.isNil(absent, "an unregistered version must report absence")
  Assert.isTrue(Errors.is(absenceErr), "absence must be a typed outcome, got: " .. tostring(absenceErr))
  assert(absenceErr)

  cache:write("rom-source.lua", "return { schema = 1, ")
  local truncated, truncatedErr = tryRead(owner, cache, VERSION_ID)
  Assert.isNil(truncated, "a truncated record must not read as a registration")
  Assert.isTrue(Errors.is(truncatedErr), "corruption must be typed, got: " .. tostring(truncatedErr))
  assert(truncatedErr)
  Assert.isTrue(truncatedErr.code ~= absenceErr.code, "absence and corruption need distinct outcomes")

  cache:write(
    "rom-source.lua",
    'return { schema = 1, versionId = "'
      .. VERSION_ID
      .. '", romSha1 = "'
      .. string.rep("a", 40)
      .. '", kind = "nds", path = "/reopenable/game.nds", '
      .. 'displayName = "game.nds", zipEntry = false, extra = 1 }'
  )
  local padded, paddedErr = tryRead(owner, cache, VERSION_ID)
  Assert.isNil(padded, "a record with unexpected keys must not read as a registration")
  Assert.isTrue(Errors.is(paddedErr), "unexpected keys must be typed, got: " .. tostring(paddedErr))
  assert(paddedErr)
  Assert.isTrue(paddedErr.code ~= absenceErr.code, "unexpected keys must not report as absence")
end

function T.zip_registration_round_trips_with_its_selected_member()
  local owner = requireLocationOwner()
  local backend = FakeCache.new()
  local _, rom, info = openCartridge(cartridgeSpec())
  withCataloguedVersion(info, function()
    local replaced, recordErr = tryRecord(owner, freshCache(backend), rom, {
      kind = "zip",
      path = "/reopenable/game.zip",
      displayName = "game.zip",
      zipEntry = "roms/game.nds",
    })
    Assert.isTrue(replaced, "expected the archive registration to persist; got: " .. tostring(recordErr))
    local binding, readErr = tryRead(owner, freshCache(backend), VERSION_ID)
    Assert.notNil(binding, "expected the persisted archive registration; got: " .. tostring(readErr))
    assert(binding)
    Assert.equal(binding.kind, "zip")
    Assert.equal(binding.path, "/reopenable/game.zip")
    Assert.equal(binding.displayName, "game.zip")
    Assert.equal(binding.zipEntry, "roms/game.nds")
    Assert.equal(binding.romSha1, info.sha1)
  end)
end

function T.ephemeral_archive_drop_round_trips_without_a_path()
  local owner = requireLocationOwner()
  local backend = FakeCache.new()
  local _, rom, info = openCartridge(cartridgeSpec())
  withCataloguedVersion(info, function()
    local replaced, recordErr = tryRecord(owner, freshCache(backend), rom, {
      kind = "zip",
      path = false,
      displayName = "dropped.zip",
      zipEntry = "game.nds",
    })
    Assert.isTrue(replaced, "expected the unreopenable archive drop to persist; got: " .. tostring(recordErr))
    local binding, readErr = tryRead(owner, freshCache(backend), VERSION_ID)
    Assert.notNil(binding, "expected the persisted archive drop; got: " .. tostring(readErr))
    assert(binding)
    Assert.isTrue(binding.path == false, "an unreopenable drop must persist an explicit false")
    Assert.equal(binding.zipEntry, "game.nds")
  end)
end

function T.empty_labels_and_blank_locations_are_rejected()
  local owner = requireLocationOwner()
  local backend = FakeCache.new()
  local cache = freshCache(backend)
  local _, rom, info = openCartridge(cartridgeSpec())
  withCataloguedVersion(info, function()
    local replaced, recordErr = tryRecord(owner, cache, rom, {
      kind = "nds",
      path = "/reopenable/game.nds",
      displayName = "game.nds",
      zipEntry = false,
    })
    Assert.isTrue(replaced, "setup registration failed: " .. tostring(recordErr))
    local before = cache:read("rom-source.lua")
    local badDescriptors = {
      { kind = "nds", displayName = "game.nds", zipEntry = false },
      { kind = "nds", path = "", displayName = "game.nds", zipEntry = false },
      { kind = "nds", path = "/reopenable/game.nds", displayName = "", zipEntry = false },
      { kind = "zip", path = "/reopenable/game.zip", displayName = "game.zip", zipEntry = "" },
    }
    for _, descriptor in ipairs(badDescriptors) do
      local kept, rejErr = tryRecord(owner, cache, rom, descriptor)
      Assert.isFalse(kept, "a descriptor without a usable location or label must not persist")
      Assert.isTrue(Errors.is(rejErr), "descriptor rejection must be typed, got: " .. tostring(rejErr))
      Assert.equal(cache:read("rom-source.lua"), before)
    end
  end)
end

function T.record_into_another_version_cache_is_rejected()
  local owner = requireLocationOwner()
  local backend = FakeCache.new()
  local _, rom = openCartridge(cartridgeSpec())
  local other = CacheFs.forVersion("othercartridge", backend)
  local kept, rejErr = tryRecord(owner, other, rom, {
    kind = "nds",
    path = "/reopenable/game.nds",
    displayName = "game.nds",
    zipEntry = false,
  })
  Assert.isFalse(kept, "a cartridge must not register under another version")
  Assert.isTrue(Errors.is(rejErr), "cache mismatch must be typed, got: " .. tostring(rejErr))
  Assert.isNil(next(backend.files), "a rejected registration must write nothing")
end

function T.failed_write_keeps_the_previous_location_and_derived_files()
  local owner = requireLocationOwner()
  local backend = FakeCache.new()
  local cache = freshCache(backend)
  local _, rom, info = openCartridge(cartridgeSpec())
  withCataloguedVersion(info, function()
    local replaced, recordErr = tryRecord(owner, cache, rom, {
      kind = "nds",
      path = "/reopenable/game.nds",
      displayName = "game.nds",
      zipEntry = false,
    })
    Assert.isTrue(replaced, "setup registration failed: " .. tostring(recordErr))
    cache:write("data/generated/peer.lua", "return 1")
    local before = cache:read("rom-source.lua")

    backend.write = function()
      return nil, "injected write failure"
    end
    local kept, writeErr = tryRecord(owner, cache, rom, {
      kind = "nds",
      path = "/reopenable/game-moved.nds",
      displayName = "game-moved.nds",
      zipEntry = false,
    })
    Assert.isFalse(kept, "a failed write must report failure")
    Assert.isTrue(Errors.is(writeErr), "a failed write must be typed, got: " .. tostring(writeErr))
    Assert.equal(cache:read("rom-source.lua"), before)
    Assert.equal(cache:read("data/generated/peer.lua"), "return 1")
  end)
end

function T.denied_record_read_is_source_required_not_corruption()
  local owner = requireLocationOwner()
  local backend = FakeCache.new()
  local _, _, info = openCartridge(cartridgeSpec())
  withCataloguedVersion(info, function()
    local cache = freshCache(backend)
    local absent, absenceErr = tryRead(owner, freshCache(FakeCache.new()), VERSION_ID)
    Assert.isNil(absent)
    Assert.isTrue(Errors.is(absenceErr), "absence must be typed")
    assert(absenceErr)

    cache:write("rom-source.lua", "return { schema = 1, ")
    local realRead = backend.read
    backend.read = function()
      return nil, "denied"
    end
    local denied, deniedErr = tryRead(owner, cache, VERSION_ID)
    backend.read = realRead
    Assert.isNil(denied, "an unreadable record must not read as a registration")
    Assert.isTrue(Errors.is(deniedErr), "an unreadable record must be typed")
    assert(deniedErr)
    Assert.equal(deniedErr.code, absenceErr.code, "an unreadable record asks for a source like a missing one")
  end)
end

function T.non_table_record_is_corruption()
  local owner = requireLocationOwner()
  local absent, absenceErr = tryRead(owner, freshCache(), VERSION_ID)
  Assert.isNil(absent)
  Assert.isTrue(Errors.is(absenceErr), "absence must be typed")
  assert(absenceErr)

  local cache = freshCache()
  cache:write("rom-source.lua", "return 42")
  local value, valueErr = tryRead(owner, cache, VERSION_ID)
  Assert.isNil(value, "a non-table record must not read as a registration")
  Assert.isTrue(Errors.is(valueErr), "a non-table record must be typed")
  assert(valueErr)
  Assert.isTrue(valueErr.code ~= absenceErr.code, "a decoded non-table must not report as absence")
end

return { tests = T }
