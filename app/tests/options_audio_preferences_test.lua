-- App-wide master-volume preference: one durable process gain with reversible
-- preview. Boot applies the committed gain before any audio, previews change
-- only the audible gain, commits atomically publish the record, failures keep
-- the previous committed value, and cancellation restores it. Headless: an
-- isolated in-memory save backend and a recording gain applicator stand in
-- for the save directory and the host master volume.

local Assert = require("tests.support.Assert")
local AudioPreferences = require("app.src.AudioPreferences")
local Errors = require("libs.errors.src.Errors")
local SaveFs = require("libs.storage.src.SaveFs")
local StorageErrors = require("libs.storage.src.errors")
local FakeCache = require("tests.support.FakeCache")

local T = {}

local AUTHORITATIVE_PATH = "preferences/audio.lua"
local PENDING_PATH = "preferences/audio.pending.lua"

local function gainRecorder()
  local calls = {}
  local function setGain(gain)
    calls[#calls + 1] = gain
  end
  return setGain, calls
end

local function storageFor(backend)
  return SaveFs.global(backend)
end

local function openPreferences(backend, setGain)
  return AudioPreferences.new({ storage = storageFor(backend), setGain = setGain })
end

local function authoritativeRecord(backend)
  local record, err = storageFor(backend):loadLua(AUTHORITATIVE_PATH)
  Assert.isNil(err, "the authoritative preference file must decode: " .. tostring(err))
  return assert(record, "the authoritative preference file must exist")
end

function T.boot_without_a_saved_preference_applies_eighty_percent_gain()
  local backend = FakeCache.new()
  local setGain, gains = gainRecorder()
  local port = openPreferences(backend, setGain)
  Assert.equal(#gains, 1, "boot applies the gain exactly once before any audio")
  Assert.equal(gains[1], 80 / 100, "an absent preference starts at 80%")
  Assert.equal(port.read(), 80, "read reports the committed percent")
  Assert.isFalse(
    storageFor(backend):exists(AUTHORITATIVE_PATH),
    "booting without a preference must not publish a default file"
  )
end

function T.preview_changes_audible_gain_without_writing()
  local backend = FakeCache.new()
  local setGain, gains = gainRecorder()
  local port = openPreferences(backend, setGain)
  port.preview(0)
  port.preview(100)
  Assert.deepEqual(gains, { 80 / 100, 0 / 100, 100 / 100 }, "previews drive the audible gain in order")
  Assert.equal(port.read(), 80, "a preview never changes the committed value")
  Assert.isFalse(storageFor(backend):exists(AUTHORITATIVE_PATH), "a preview must never touch the disk")
  Assert.isFalse(storageFor(backend):exists(PENDING_PATH), "a preview stages no pending file")
end

function T.commit_persists_sixty_one_percent_across_restart_and_route_switch()
  local backend = FakeCache.new()
  local setGain, gains = gainRecorder()
  local port = openPreferences(backend, setGain)
  port.commit(61)
  Assert.equal(port.read(), 61, "commit updates the committed value")
  Assert.equal(gains[#gains], 61 / 100, "commit ensures the audible preview equals the committed percent")
  local record = authoritativeRecord(backend)
  Assert.equal(record.schema, "portemon-audio-preferences-v1", "the published record carries its schema")
  Assert.equal(record.volumePercent, 61, "the published record carries the committed percent")
  Assert.isFalse(storageFor(backend):exists(PENDING_PATH), "a published commit leaves no pending file behind")
  -- A route switch reuses the same port: no reconstruction, no reread.
  local gainCount = #gains
  Assert.equal(port.read(), 61, "the same port still serves the committed value on another route")
  Assert.equal(#gains, gainCount, "rereading the port performs no gain or IO work")
  -- A restart reloads the committed value and applies its gain first.
  local restartGain, restartGains = gainRecorder()
  local restarted = openPreferences(backend, restartGain)
  Assert.equal(restarted.read(), 61, "the committed value survives a restart")
  Assert.equal(#restartGains, 1, "restart applies the gain exactly once before any audio")
  Assert.equal(restartGains[1], 61 / 100, "restart applies the committed gain")
end

function T.failed_write_keeps_the_previous_committed_volume()
  local backend = FakeCache.new()
  local setGain, gains = gainRecorder()
  local port = openPreferences(backend, setGain)
  port.commit(61)
  backend.write = function()
    return nil, "injected write failure"
  end
  local err = Assert.throws(function()
    port.commit(40)
  end, "a failed publication must propagate")
  Assert.equal(err.code, StorageErrors.SAVE_WRITE_FAILED, "the storage write failure is reused, got " .. tostring(err))
  Assert.equal(port.read(), 61, "a failed publication leaves the committed value unchanged")
  Assert.equal(
    authoritativeRecord(backend).volumePercent,
    61,
    "a failed publication keeps the old authoritative file readable"
  )
  Assert.equal(gains[#gains], 40 / 100, "the audible preview may remain until retry or cancel")
  port.restore()
  Assert.equal(gains[#gains], 61 / 100, "cancel restores the committed gain")
  Assert.equal(port.read(), 61, "cancel leaves the committed value alone")
end

function T.failed_replace_keeps_the_previous_committed_volume()
  local backend = FakeCache.new()
  local _, gains = gainRecorder()
  local setGain = function(gain)
    gains[#gains + 1] = gain
  end
  local port = openPreferences(backend, setGain)
  port.commit(61)
  backend.replace = function()
    return nil, "injected replace failure"
  end
  local err = Assert.throws(function()
    port.commit(40)
  end, "a failed atomic replacement must propagate")
  Assert.equal(
    err.code,
    StorageErrors.SAVE_REPLACE_FAILED,
    "the storage replace failure is reused, got " .. tostring(err)
  )
  Assert.equal(port.read(), 61, "a failed replacement leaves the committed value unchanged")
  Assert.equal(
    authoritativeRecord(backend).volumePercent,
    61,
    "a failed replacement keeps the old authoritative file readable"
  )
end

function T.cancel_restores_the_committed_gain_without_writing()
  local backend = FakeCache.new()
  local setGain, gains = gainRecorder()
  local port = openPreferences(backend, setGain)
  port.commit(61)
  local published = storageFor(backend):read(AUTHORITATIVE_PATH)
  port.preview(100)
  Assert.equal(gains[#gains], 100 / 100, "the preview is audible")
  port.restore()
  Assert.equal(gains[#gains], 61 / 100, "cancel reapplies the committed gain")
  Assert.equal(port.read(), 61, "cancel leaves the committed value alone")
  Assert.equal(storageFor(backend):read(AUTHORITATIVE_PATH), published, "cancel performs no write")
end

function T.present_but_invalid_file_fails_explicitly_and_is_never_overwritten()
  local invalidBodies = {
    "this is not lua",
    "return 5",
    'return { schema = "something-else", volumePercent = 80 }',
    'return { schema = "portemon-audio-preferences-v1", volumePercent = 101 }',
    'return { schema = "portemon-audio-preferences-v1", volumePercent = 8.5 }',
    'return { schema = "portemon-audio-preferences-v1" }',
  }
  for _, body in ipairs(invalidBodies) do
    local backend = FakeCache.new()
    storageFor(backend):write(AUTHORITATIVE_PATH, body)
    local setGain, gains = gainRecorder()
    local err = Assert.throws(function()
      openPreferences(backend, setGain)
    end, "an invalid preference file must fail explicitly: " .. body)
    Assert.isTrue(Errors.is(err), "the failure is a structured error: " .. tostring(err))
    Assert.equal(err.code, "AUDIO_PREFERENCES_INVALID", "the failure names the preference contract")
    Assert.equal(err.context.path, AUTHORITATIVE_PATH, "the failure carries the file path")
    Assert.isTrue(type(err.context.cause) == "string" and err.context.cause ~= "", "the failure carries its cause")
    Assert.equal(#gains, 0, "an invalid file applies no gain: " .. body)
    Assert.equal(
      storageFor(backend):read(AUTHORITATIVE_PATH),
      body,
      "an invalid file is never overwritten as a default: " .. body
    )
  end
end

function T.invalid_percentages_are_rejected_without_side_effects()
  local invalid = { 0 / 0, math.huge, -math.huge, 1.5, -1, 101, "61", true, {} }
  local backend = FakeCache.new()
  local setGain, gains = gainRecorder()
  local port = openPreferences(backend, setGain)
  local gainCount = #gains
  for _, percent in ipairs(invalid) do
    Assert.throws(function()
      port.preview(percent)
    end, "preview must reject " .. tostring(percent))
    Assert.throws(function()
      port.commit(percent)
    end, "commit must reject " .. tostring(percent))
  end
  Assert.throws(function()
    port.preview(nil)
  end, "preview must reject nil")
  Assert.throws(function()
    port.commit(nil)
  end, "commit must reject nil")
  Assert.equal(#gains, gainCount, "rejected percents change no gain")
  Assert.equal(port.read(), 80, "rejected percents change no committed value")
  Assert.isFalse(storageFor(backend):exists(AUTHORITATIVE_PATH), "rejected percents write nothing")
end

function T.unchanged_commit_does_not_rewrite_an_already_valid_file()
  local backend = FakeCache.new()
  local setGain, gains = gainRecorder()
  local port = openPreferences(backend, setGain)
  port.commit(61)
  local published = storageFor(backend):read(AUTHORITATIVE_PATH)
  local writes, replaces = 0, 0
  local originalWrite, originalReplace = backend.write, backend.replace
  backend.write = function(self, path, data)
    writes = writes + 1
    return originalWrite(self, path, data)
  end
  backend.replace = function(self, source, destination)
    replaces = replaces + 1
    return originalReplace(self, source, destination)
  end
  port.commit(61)
  Assert.equal(writes, 0, "an unchanged commit rewrites nothing")
  Assert.equal(replaces, 0, "an unchanged commit replaces nothing")
  Assert.equal(gains[#gains], 61 / 100, "an unchanged commit still ensures the audible gain")
  Assert.equal(storageFor(backend):read(AUTHORITATIVE_PATH), published, "an unchanged commit keeps the published bytes")
end

function T.stale_pending_file_never_overrides_the_authoritative_record()
  local backend = FakeCache.new()
  local setGain, _ = gainRecorder()
  local port = openPreferences(backend, setGain)
  port.commit(61)
  storageFor(backend):write(PENDING_PATH, 'return { schema = "portemon-audio-preferences-v1", volumePercent = 23 }')
  local restartGain, restartGains = gainRecorder()
  local restarted = openPreferences(backend, restartGain)
  Assert.equal(restarted.read(), 61, "a stale pending file never overrides the authoritative record")
  Assert.equal(restartGains[1], 61 / 100, "restart applies the authoritative gain")
  -- A pending file alone (no authoritative record) still boots the default.
  local lonely = FakeCache.new()
  storageFor(lonely):write(PENDING_PATH, 'return { schema = "portemon-audio-preferences-v1", volumePercent = 23 }')
  local lonelyGain, lonelyGains = gainRecorder()
  local fresh = openPreferences(lonely, lonelyGain)
  Assert.equal(fresh.read(), 80, "a lone pending file is not loaded as authoritative")
  Assert.equal(lonelyGains[1], 80 / 100, "a lone pending file boots the default gain")
end

return { tests = T }
