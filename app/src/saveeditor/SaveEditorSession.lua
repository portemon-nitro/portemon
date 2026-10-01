-- Owns one private, validated save-edit transaction.

local Errors = require("libs.errors.src.Errors")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local PlayerData = require("libs.hgss.src.save.PlayerData")
local ScriptSave = require("libs.script.src.ScriptSave")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")

local SaveEditorSession = {}
SaveEditorSession.__index = SaveEditorSession

local ACTIVE_SCRIPT = "SAVE_EDITOR_ACTIVE_SCRIPT"
local CONFLICT = "SAVE_EDITOR_CONFLICT"
local VALUE_INVALID = "SAVE_EDITOR_VALUE_INVALID"
local BUSY = "SAVE_EDITOR_BUSY"
local DRAFT_PENDING = "SAVE_EDITOR_DRAFT_PENDING"

---@class SaveEditorSessionOptions
---@field record table<string, unknown>
---@field context table<string, unknown>
---@field saveStore table<string, unknown>
---@field saveFs SaveFs
---@field validateRecord fun(record: table<string, unknown>): table<string, unknown>?, Errors.Error?
---@field symbols table<string, unknown>?

---@class SaveEditorDirtySections
---@field money boolean
---@field flags boolean

---@class SaveEditorLocationSnapshot
---@field mapId integer
---@field fieldX integer
---@field fieldZ integer
---@field worldY number
---@field surfaceId integer
---@field terrainDependencyHash string
---@field facing string

---@class SaveEditorSnapshot
---@field saveId string
---@field versionId string
---@field playerName string
---@field money integer
---@field flags table<integer, boolean>
---@field location SaveEditorLocationSnapshot
---@field originalLocation SaveEditorLocationSnapshot
---@field dirtySections SaveEditorDirtySections
---@field revision integer

---@class SaveEditorSession
---@field private _baseline table<string, unknown>
---@field private _entryCheckpoint table<string, unknown>
---@field private _money integer
---@field private _events FieldEventState
---@field private _symbols table<string, unknown>
---@field private _saveStore table<string, unknown>
---@field private _saveFs SaveFs
---@field private _validateRecord fun(record: table<string, unknown>): table<string, unknown>?, Errors.Error?
---@field private _revision integer
---@field private _busy boolean
---@field private _backupPublished boolean

local function copy(value)
  if type(value) ~= "table" then
    return value
  end
  local result = {}
  for key, item in pairs(value) do
    result[key] = copy(item)
  end
  return result
end

local function equal(left, right)
  if type(left) ~= type(right) then
    return false
  end
  if type(left) ~= "table" then
    return left == right
  end
  for key, value in pairs(left) do
    if not equal(value, right[key]) then
      return false
    end
  end
  for key in pairs(right) do
    if left[key] == nil then
      return false
    end
  end
  return true
end

---@param value unknown
---@return boolean
local function finiteInteger(value)
  return type(value) == "number"
    and value == value
    and value ~= math.huge
    and value ~= -math.huge
    and value == math.floor(value)
end

---@param code string
---@param message string
---@param context Errors.Context?
---@return table<string, unknown>
local function failure(code, message, context)
  return { ok = false, error = Errors.new(code, message, context) }
end

---@param changed boolean
---@return table<string, unknown>
local function success(changed)
  return { ok = true, changed = changed }
end

---@param record table<string, unknown>
---@return table<string, unknown>
local function eventSnapshot(record)
  local world = record.world --[[@as table<string, unknown>]]
  return { flags = world.flags, vars = world.variables }
end

---@param record table<string, unknown>
---@return SaveEditorLocationSnapshot
local function locationSnapshot(record)
  return {
    mapId = record.mapId --[[@as integer]],
    fieldX = record.fieldX --[[@as integer]],
    fieldZ = record.fieldZ --[[@as integer]],
    worldY = record.worldY --[[@as number]],
    surfaceId = record.surfaceId --[[@as integer]],
    terrainDependencyHash = record.terrainDependencyHash --[[@as string]],
    facing = record.facing --[[@as string]],
  }
end

---@param events FieldEventState
---@return table<integer, boolean>
local function flagsFrom(events)
  return copy(events:serialize().flags)
end

---@param record table<string, unknown>
---@param money integer
---@param events FieldEventState
---@return boolean, boolean
local function dirtyAgainst(record, money, events)
  local playerData = record.playerData --[[@as table<string, unknown>]]
  local profile = playerData.profile --[[@as table<string, unknown>]]
  local world = record.world --[[@as table<string, unknown>]]
  return money ~= profile.money, not equal(events:serialize().flags, world.flags)
end

---@param options SaveEditorSessionOptions
---@return SaveEditorSession?, Errors.Error?
function SaveEditorSession.new(options)
  assert(type(options) == "table", "save editor session options are required")
  local record = options.record
  assert(type(record) == "table", "a canonical save record is required")
  assert(type(record.saveId) == "string" and record.saveId ~= "", "the selected save identity is required")
  assert(type(record.versionId) == "string" and record.versionId ~= "", "the selected version identity is required")
  assert(type(options.context) == "table", "the borrowed version validation context is required")
  assert(type(options.saveStore) == "table", "the global save store is required")
  assert(type(options.saveStore.load) == "function" and type(options.saveStore.save) == "function")
  assert(type(options.saveFs) == "table", "the global save filesystem is required")
  assert(type(options.saveFs.writeLua) == "function" and type(options.saveFs.replace) == "function")
  assert(type(options.validateRecord) == "function", "the complete save validator is required")
  assert(type(record.playerData) == "table" and type(record.world) == "table", "canonical save domains are required")
  local profile = record.playerData.profile
  assert(type(profile) == "table" and finiteInteger(profile.money), "canonical player money is required")
  assert(type(record.world.flags) == "table" and type(record.world.variables) == "table")

  if not ScriptSave.isQuiescent(record.scripts) then
    return nil,
      Errors.new(
        ACTIVE_SCRIPT,
        "Resume and save at a stable point before editing this save.",
        { saveId = record.saveId }
      )
  end

  local baseline = copy(record)
  local events = FieldEventState.new(eventSnapshot(baseline))
  local session = setmetatable({
    _baseline = baseline,
    _entryCheckpoint = copy(baseline),
    _money = profile.money,
    _events = events,
    _symbols = options.symbols or FieldScriptSymbols,
    _saveStore = options.saveStore,
    _saveFs = options.saveFs,
    _validateRecord = options.validateRecord,
    _revision = 0,
    _busy = false,
    _backupPublished = false,
  }, SaveEditorSession)
  return session
end

---@return SaveEditorSnapshot
function SaveEditorSession:snapshot()
  local playerData = self._baseline.playerData --[[@as table<string, unknown>]]
  local profile = playerData.profile --[[@as table<string, unknown>]]
  local baselineLocation = locationSnapshot(self._baseline)
  local dirtyMoney, dirtyFlags = dirtyAgainst(self._baseline, self._money, self._events)
  return {
    saveId = self._baseline.saveId --[[@as string]],
    versionId = self._baseline.versionId --[[@as string]],
    playerName = profile.name --[[@as string]],
    money = self._money,
    flags = flagsFrom(self._events),
    location = copy(baselineLocation),
    originalLocation = copy(baselineLocation),
    dirtySections = { money = dirtyMoney, flags = dirtyFlags },
    revision = self._revision,
  }
end

---@return integer
function SaveEditorSession:revision()
  return self._revision
end

---@return boolean
function SaveEditorSession:isDirty()
  local dirtyMoney, dirtyFlags = dirtyAgainst(self._baseline, self._money, self._events)
  return dirtyMoney or dirtyFlags
end

---@param value unknown
---@return table<string, unknown>
function SaveEditorSession:setMoney(value)
  if self._busy then
    return failure(BUSY, "A save operation is already in progress.", {})
  end
  if not finiteInteger(value) or value < 0 or value > PlayerData.MAX_MONEY then
    return failure(VALUE_INVALID, "Money must be an integer within the game's supported range.", { value = value })
  end
  if value == self._money then
    return success(false)
  end
  self._money = value
  self._revision = self._revision + 1
  return success(true)
end

---@param name unknown
---@param value unknown
---@return table<string, unknown>
function SaveEditorSession:setFlag(name, value)
  if self._busy then
    return failure(BUSY, "A save operation is already in progress.", {})
  end
  if type(name) ~= "string" or type(value) ~= "boolean" then
    return failure(VALUE_INVALID, "Choose a named field flag and a boolean value.", {})
  end
  local flagsByName = self._symbols.flagsByName
  assert(type(flagsByName) == "table", "flag symbol catalog is required")
  local flagId = flagsByName[name]
  if not finiteInteger(flagId) or flagId < 0 or flagId > 0xFFFF then
    return failure(VALUE_INVALID, "The selected field flag is not in the symbol catalog.", { name = name })
  end
  if self._events:isFlagSet(flagId) == value then
    return success(false)
  end

  local candidate = FieldEventState.new(self._events:serialize())
  if value then
    candidate:setFlag(flagId)
  else
    candidate:clearFlag(flagId)
  end
  local serialized, eventError = FieldEventState.validate(candidate:serialize())
  if serialized == nil then
    return { ok = false, error = assert(eventError) }
  end
  self._events = FieldEventState.new(serialized)
  self._revision = self._revision + 1
  return success(true)
end

---@return table<string, unknown>
function SaveEditorSession:captureCandidate()
  local candidate = copy(self._baseline)
  local playerData = candidate.playerData --[[@as table<string, unknown>]]
  local profile = playerData.profile --[[@as table<string, unknown>]]
  profile.money = self._money
  local world = candidate.world --[[@as table<string, unknown>]]
  world.flags = flagsFrom(self._events)
  return candidate
end

---@param hasUnappliedDraft boolean?
---@return table<string, unknown>
function SaveEditorSession:save(hasUnappliedDraft)
  if self._busy then
    return failure(BUSY, "A save operation is already in progress.", {})
  end
  if hasUnappliedDraft ~= nil then
    assert(type(hasUnappliedDraft) == "boolean", "unapplied draft state must be boolean")
  end
  if hasUnappliedDraft then
    return failure(DRAFT_PENDING, "Apply or cancel the pending edit before saving.", {})
  end
  if not self:isDirty() then
    return success(false)
  end

  self._busy = true
  local ok, result = pcall(function()
    local candidate, validationError = self._validateRecord(self:captureCandidate())
    if candidate == nil then
      if Errors.is(validationError) then
        return { ok = false, error = validationError }
      end
      return failure(VALUE_INVALID, "The edited save did not pass complete validation.", {})
    end

    local current, loadError = self._saveStore:load(self._baseline.saveId)
    if current == nil then
      if Errors.is(loadError) then
        return { ok = false, error = loadError }
      end
      error("save store load returned no record or structured error")
    end
    if not equal(current, self._baseline) then
      return failure(CONFLICT, "This save changed after the editor opened. Reopen it before saving.", {
        saveId = self._baseline.saveId,
      })
    end

    if not self._backupPublished then
      local backupPath = "editor-backups/" .. self._baseline.saveId .. ".lua"
      local temporaryPath = backupPath .. ".tmp"
      local backupOk, backupError = pcall(function()
        self._saveFs:writeLua(temporaryPath, self._entryCheckpoint)
        self._saveFs:replace(temporaryPath, backupPath)
      end)
      if not backupOk then
        pcall(function()
          self._saveFs:remove(temporaryPath)
        end)
        error(backupError)
      end
      self._backupPublished = true
    end

    self._saveStore:save(candidate)
    self._baseline = copy(candidate)
    return success(true)
  end)
  self._busy = false
  if ok then
    return result
  end
  if Errors.is(result) then
    return { ok = false, error = result }
  end
  error(result)
end

---@return boolean
function SaveEditorSession:discard()
  if self._busy then
    return false
  end
  local changed = self:isDirty()
  if not changed then
    return false
  end
  local playerData = self._baseline.playerData --[[@as table<string, unknown>]]
  local profile = playerData.profile --[[@as table<string, unknown>]]
  self._money = profile.money --[[@as integer]]
  self._events = FieldEventState.new(eventSnapshot(self._baseline))
  self._revision = self._revision + 1
  return true
end

return SaveEditorSession
