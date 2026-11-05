-- App-owned durable master-volume preference: the one process-wide gain with
-- reversible preview. The record lives under the save directory (never the
-- rebuildable cache) so it survives save and version switches; publication
-- stages a sibling file and atomically replaces the authoritative one. Only
-- the master gain is applied here -- never per-source or per-sample
-- multiplication -- so muting preserves rendering and voice completion.

local Errors = require("libs.errors.src.Errors")
local StorageErrors = require("libs.storage.src.errors")

local AudioPreferences = {}

AudioPreferences.INVALID = "AUDIO_PREFERENCES_INVALID"

local SCHEMA = "portemon-audio-preferences-v1"
local AUTHORITATIVE_PATH = "preferences/audio.lua"
local PENDING_PATH = "preferences/audio.pending.lua"
local DEFAULT_VOLUME = 80

---@class AudioPreferencesPort
---@field read fun(): integer the committed percent, never a preview
---@field preview fun(percent: integer) validate and change the audible gain without disk IO
---@field commit fun(percent: integer) publish the record, then update the committed value
---@field restore fun() reapply the committed gain without disk IO

---@param percent unknown
local function assertValidPercent(percent)
  assert(
    type(percent) == "number"
      and percent == percent
      and percent ~= math.huge
      and percent ~= -math.huge
      and percent % 1 == 0
      and percent >= 0
      and percent <= 100,
    "audio volume percent must be an integer in 0..100"
  )
end

---@param record unknown
---@return string? cause the rejection cause, nil when the record is usable
local function recordCause(record)
  if type(record) ~= "table" then
    return "audio preference must be a record"
  end
  if record.schema ~= SCHEMA then
    return "unsupported audio preference schema"
  end
  local volume = record.volumePercent
  if
    type(volume) ~= "number"
    or volume ~= volume
    or volume == math.huge
    or volume == -math.huge
    or volume % 1 ~= 0
    or volume < 0
    or volume > 100
  then
    return "audio volume percent must be an integer in 0..100"
  end
  return nil
end

---@param storage table<string, unknown> SaveFs-shaped confined persistence
---@return integer committed the stored percent, or the default when absent
local function loadCommitted(storage)
  local record, loadErr = storage:loadLua(AUTHORITATIVE_PATH)
  if record ~= nil then
    local cause = recordCause(record)
    if cause ~= nil then
      Errors.raise(AudioPreferences.INVALID, "stored audio preference is invalid", {
        path = AUTHORITATIVE_PATH,
        cause = cause,
      })
    end
    return record.volumePercent --[[@as integer]]
  end
  if storage:exists(AUTHORITATIVE_PATH) then
    local cause = "empty record"
    if loadErr ~= nil then
      cause = Errors.format(loadErr)
    end
    Errors.raise(AudioPreferences.INVALID, "stored audio preference is invalid", {
      path = AUTHORITATIVE_PATH,
      cause = cause,
    })
  end
  if loadErr ~= nil and (not Errors.is(loadErr) or loadErr.code ~= StorageErrors.SAVE_FILE_MISSING) then
    Errors.raise(AudioPreferences.INVALID, "stored audio preference cannot be read", {
      path = AUTHORITATIVE_PATH,
      cause = Errors.format(loadErr),
    })
  end
  return DEFAULT_VOLUME
end

---@param opts { storage: table<string, unknown>, setGain: fun(gain: number) }
---@return AudioPreferencesPort port dot-call read/preview/commit/restore operations
function AudioPreferences.new(opts)
  assert(type(opts) == "table", "AudioPreferences requires its storage and gain collaborators")
  local storage = assert(opts.storage, "AudioPreferences requires a storage")
  assert(
    type(storage.writeLua) == "function"
      and type(storage.loadLua) == "function"
      and type(storage.replace) == "function"
      and type(storage.exists) == "function",
    "AudioPreferences requires a SaveFs-shaped storage"
  )
  local setGain = opts.setGain
  assert(type(setGain) == "function", "AudioPreferences requires a gain applicator")
  -- The committed percent loads (or defaults) before boot audio exists; the
  -- gain applies here so the first audible output already carries it.
  local committed = loadCommitted(storage)
  setGain(committed / 100)
  local port = {}
  function port.read()
    return committed
  end
  function port.preview(percent)
    assertValidPercent(percent)
    setGain(percent / 100)
  end
  function port.commit(percent)
    assertValidPercent(percent)
    -- The audible preview always matches the selected percent first, so a
    -- later retry or cancel starts from the requested level.
    setGain(percent / 100)
    if percent == committed then
      -- An unchanged commit rewrites nothing while the authoritative file
      -- still decodes; a file that changed underneath still republishes.
      local current = storage:loadLua(AUTHORITATIVE_PATH)
      if recordCause(current) == nil then
        return
      end
    end
    -- The committed value changes only after the atomic publication
    -- succeeds: a failed write or replace propagates the storage layer's
    -- own failure and leaves the previous value (and file) in place.
    storage:writeLua(PENDING_PATH, { schema = SCHEMA, volumePercent = percent })
    storage:replace(PENDING_PATH, AUTHORITATIVE_PATH)
    committed = percent
  end
  function port.restore()
    setGain(committed / 100)
  end
  return port
end

return AudioPreferences
