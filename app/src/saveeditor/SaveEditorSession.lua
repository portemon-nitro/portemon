-- Owns one private, validated save-edit transaction.

local Errors = require("libs.errors.src.Errors")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local PlayerData = require("libs.hgss.src.save.PlayerData")
local ScriptSave = require("libs.script.src.ScriptSave")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local HgssBagService = require("libs.hgss.src.items.HgssBagService")
local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
local BagSave = require("libs.hgss.src.save.BagSave")
local Party = require("libs.mons.src.Party")
local Mon = require("libs.mons.src.Mon")
local NativeLegality = require("libs.mons.src.gen4.NativeLegality")
local SaveEditorMonDraft = require("app.src.saveeditor.SaveEditorMonDraft")

local SaveEditorSession = {}
SaveEditorSession.__index = SaveEditorSession

local ACTIVE_SCRIPT = "SAVE_EDITOR_ACTIVE_SCRIPT"
local CONFLICT = "SAVE_EDITOR_CONFLICT"
local VALUE_INVALID = "SAVE_EDITOR_VALUE_INVALID"
local BUSY = "SAVE_EDITOR_BUSY"
local DRAFT_PENDING = "SAVE_EDITOR_DRAFT_PENDING"
local STALE_DRAFT = "SAVE_EDITOR_STALE_DRAFT"
local PRESET_INVALID = "SAVE_EDITOR_PRESET_INVALID"
local PRESET_STALE = "SAVE_EDITOR_PRESET_STALE"
local PRESET_UNAVAILABLE = "SAVE_EDITOR_PRESET_UNAVAILABLE"

---@class SaveEditorSessionOptions
---@field record table<string, unknown>
---@field context table<string, unknown>
---@field saveStore table<string, unknown>
---@field saveFs SaveFs
---@field symbols table<string, unknown>?

---@class SaveEditorDirtySections
---@field money boolean
---@field flags boolean
---@field party boolean
---@field bag boolean
---@field location boolean
---@field frame boolean

---@class SaveEditorLocation
---@field mapId integer
---@field fieldX integer
---@field fieldZ integer
---@field worldY number
---@field surfaceId integer
---@field terrainDependencyHash string

---@class SaveEditorSnapshot
---@field saveId string
---@field versionId string
---@field playerName string
---@field money integer
---@field frameIndex integer
---@field flags table<integer, boolean>
---@field location SaveEditorLocation
---@field facing string
---@field originalLocation SaveEditorLocation
---@field dirtySections SaveEditorDirtySections
---@field locationChanged boolean
---@field revision integer

---@class SaveEditorSession
---@field snapshot fun(self: SaveEditorSession): SaveEditorSnapshot
---@field isDirty fun(self: SaveEditorSession): boolean
---@field revision fun(self: SaveEditorSession): integer
---@field partyRevision fun(self: SaveEditorSession): integer
---@field partySnapshot fun(self: SaveEditorSession): { revision: integer, members: { slot0: integer, mon: table<string, unknown> }[] }
---@field bagSnapshot fun(self: SaveEditorSession, pocket: string): { item: string, quantity: integer }[]
---@field beginMonEdit fun(self: SaveEditorSession, slot0: integer): SaveEditorMonDraft?, Errors.Error?
---@field beginMonAdd fun(self: SaveEditorSession, species: string, options: { location: integer, date: table<string, unknown> }): SaveEditorMonDraft?, Errors.Error?
---@field applyMonDraft fun(self: SaveEditorSession, draft: SaveEditorMonDraft): table<string, unknown>
---@field swapPartyMons fun(self: SaveEditorSession, left0: integer, right0: integer): table<string, unknown>
---@field setBagQuantity fun(self: SaveEditorSession, itemKey: string, quantity: integer): table<string, unknown>
---@field setMoney fun(self: SaveEditorSession, value: unknown): table<string, unknown>
---@field setFrameIndex fun(self: SaveEditorSession, value: unknown): table<string, unknown>
---@field setFlag fun(self: SaveEditorSession, name: unknown, value: unknown): table<string, unknown>
---@field setLocation fun(self: SaveEditorSession, placement: SaveEditorLocation): table<string, unknown>
---@field applyPreset fun(self: SaveEditorSession, preset: SaveEditorPresetData, options: table<string, unknown>): table<string, unknown>
---@field save fun(self: SaveEditorSession, hasUnappliedDraft: boolean?): table<string, unknown>
---@field discard fun(self: SaveEditorSession): boolean
---@field discardSection fun(self: SaveEditorSession, section: string): boolean
---@field private _baseline table<string, unknown>
---@field private _entryCheckpoint table<string, unknown>
---@field private _money integer
---@field private _frameIndex integer
---@field private _frameIndexes table<integer, boolean>
---@field private _location SaveEditorLocation
---@field private _facing string
---@field private _events FieldEventState
---@field private _symbols table<string, unknown>
---@field private _saveStore table<string, unknown>
---@field private _saveFs SaveFs
---@field private _revision integer
---@field private _partyRevision integer
---@field private _monService HgssMonService
---@field private _monServiceOptions table<string, unknown>
---@field private _monValidationContext table<string, unknown>
---@field private _bagService HgssBagService
---@field private _drafts table<SaveEditorMonDraft, table<string, unknown>>
---@field private _busy boolean
---@field private _backupPublished boolean
---@field private _readCache { revision: integer, snapshot: SaveEditorSnapshot }?

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

---@param options table<string, unknown>
---@param bucket table<string, unknown>
---@return HgssMonService
local function newMonService(options, bucket)
  local serviceOptions = {}
  for key, value in pairs(options) do
    serviceOptions[key] = value
  end
  serviceOptions.bucket = copy(bucket)
  return HgssMonService.new(serviceOptions)
end

---@param record table<string, unknown>
---@return SaveEditorLocation
local function locationSnapshot(record)
  return {
    mapId = record.mapId --[[@as integer]],
    fieldX = record.fieldX --[[@as integer]],
    fieldZ = record.fieldZ --[[@as integer]],
    worldY = record.worldY --[[@as number]],
    surfaceId = record.surfaceId --[[@as integer]],
    terrainDependencyHash = record.terrainDependencyHash --[[@as string]],
  }
end

---@param value unknown
---@return boolean
local function validLocation(value)
  if type(value) ~= "table" then
    return false
  end
  local expected = {
    mapId = true,
    fieldX = true,
    fieldZ = true,
    surfaceId = true,
    worldY = true,
    terrainDependencyHash = true,
  }
  local count = 0
  for key in pairs(value) do
    if expected[key] ~= true then
      return false
    end
    count = count + 1
  end
  return count == 6
    and finiteInteger(value.mapId)
    and value.mapId >= 0
    and value.mapId <= 0xFFFF
    and finiteInteger(value.fieldX)
    and value.fieldX >= 0
    and value.fieldX <= 0xFFFF
    and finiteInteger(value.fieldZ)
    and value.fieldZ >= 0
    and value.fieldZ <= 0xFFFF
    and finiteInteger(value.surfaceId)
    and value.surfaceId >= 0
    and value.surfaceId <= 0xFFFF
    and type(value.worldY) == "number"
    and value.worldY == value.worldY
    and value.worldY ~= math.huge
    and value.worldY ~= -math.huge
    and type(value.terrainDependencyHash) == "string"
    and value.terrainDependencyHash ~= ""
end

---@param left SaveEditorLocation
---@param right SaveEditorLocation
---@return boolean
local function sameLocation(left, right)
  return left.mapId == right.mapId
    and left.fieldX == right.fieldX
    and left.fieldZ == right.fieldZ
    and left.surfaceId == right.surfaceId
    and left.worldY == right.worldY
    and left.terrainDependencyHash == right.terrainDependencyHash
end

---@param candidate table<string, unknown>
---@param location SaveEditorLocation
---@param baseline table<string, unknown>
local function applyLocation(candidate, location, baseline)
  candidate.avatar = copy(baseline.avatar)
  candidate.suppression = copy(baseline.suppression)
  candidate.weatherId = baseline.weatherId
  candidate.audio = copy(baseline.audio)
  candidate.mapId = location.mapId
  candidate.fieldX = location.fieldX
  candidate.fieldZ = location.fieldZ
  candidate.surfaceId = location.surfaceId
  candidate.worldY = location.worldY
  candidate.terrainDependencyHash = location.terrainDependencyHash
  if sameLocation(location, locationSnapshot(baseline)) then
    return
  end

  candidate.avatar = { state = "walking" }
  candidate.suppression = nil
  if location.mapId ~= baseline.mapId then
    candidate.weatherId = nil
    local audio = candidate.audio --[[@as table<string, unknown>]]
    audio.fieldMusicOverride = nil
  end
end

---@param events FieldEventState
---@return table<integer, boolean>
local function flagsFrom(events)
  return copy(events:serialize().flags)
end

---@param left table<integer, boolean>
---@param right table<integer, boolean>
---@return boolean
local function sameFlags(left, right)
  for flagId, value in pairs(left) do
    if (value == true) ~= (right[flagId] == true) then
      return false
    end
  end
  for flagId, value in pairs(right) do
    if (value == true) ~= (left[flagId] == true) then
      return false
    end
  end
  return true
end

---@param left table<integer, integer>
---@param right table<integer, integer>
---@return boolean
local function sameVariables(left, right)
  for varId, value in pairs(left) do
    if value ~= (right[varId] or 0) then
      return false
    end
  end
  for varId, value in pairs(right) do
    if value ~= (left[varId] or 0) then
      return false
    end
  end
  return true
end

---@param record table<string, unknown>
---@param money integer
---@param events FieldEventState
---@return boolean, boolean
local function dirtyAgainst(record, money, events)
  local playerData = record.playerData --[[@as table<string, unknown>]]
  local profile = playerData.profile --[[@as table<string, unknown>]]
  local world = record.world --[[@as table<string, unknown>]]
  local serialized = events:serialize()
  return money ~= profile.money,
    not sameFlags(serialized.flags, world.flags) or not sameVariables(serialized.vars, world.variables)
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
  local frameIndexes = options.context.frameIndexes
  assert(type(frameIndexes) == "table", "the borrowed version context requires validated dialogue-frame indexes")
  local playerOptions = baseline.playerData.options
  assert(type(playerOptions) == "table", "canonical player options are required")
  local frameIndex = playerOptions.textFrame
  assert(
    finiteInteger(frameIndex) and frameIndexes[frameIndex] == true,
    "the canonical dialogue frame must be valid for this version"
  )
  local events = FieldEventState.new(eventSnapshot(baseline))
  local monCatalog = options.context.monCatalog
  local itemCatalog = options.context.itemCatalog
  assert(monCatalog ~= nil, "the borrowed version context requires a mon catalog")
  assert(itemCatalog ~= nil, "the borrowed version context requires an item catalog")
  local monValidationContext = {
    catalog = monCatalog,
    charmap = assert(options.context.charmap),
    games = HgssMonService.GAMES,
    languages = HgssMonService.LANGUAGES,
  }
  local monProfile = baseline.playerData.profile --[[@as table<string, unknown>]]
  local monServiceOptions = {
    catalog = monCatalog,
    profile = {
      name = monProfile.name,
      gender = monProfile.gender,
      trainerId = monProfile.trainerId,
    },
    game = baseline.versionId,
    language = assert(options.context.language),
    charmap = monValidationContext.charmap,
    games = monValidationContext.games,
    languages = monValidationContext.languages,
  }
  local partyValid, partyError = pcall(Party.validate, baseline.mons.party, monValidationContext)
  if not partyValid then
    if Errors.is(partyError) then
      return nil,
        Errors.new("SAVE_EDITOR_PARTY_INVALID", "The selected save's Party is invalid.", {
          saveId = record.saveId,
          reason = Errors.format(partyError),
        })
    end
    error(partyError, 0)
  end
  local monService = newMonService(monServiceOptions, baseline.mons --[[@as table<string, unknown>]])
  local session = setmetatable({
    _baseline = baseline,
    _entryCheckpoint = copy(baseline),
    _money = profile.money,
    _frameIndex = frameIndex,
    _frameIndexes = frameIndexes,
    _location = locationSnapshot(baseline),
    _facing = baseline.facing --[[@as string]],
    _events = events,
    _symbols = options.symbols or FieldScriptSymbols,
    _saveStore = options.saveStore,
    _saveFs = options.saveFs,
    _revision = 0,
    _partyRevision = 0,
    _monService = monService,
    _monServiceOptions = monServiceOptions,
    _monValidationContext = monValidationContext,
    _bagService = HgssBagService.new({ catalog = itemCatalog, bag = baseline.bag }),
    _drafts = setmetatable({}, { __mode = "k" }),
    _busy = false,
    _backupPublished = false,
    _readCache = nil,
  }, SaveEditorSession)
  return session
end

---@return SaveEditorSnapshot
function SaveEditorSession:snapshot()
  if self._readCache and self._readCache.revision == self._revision then
    return copy(self._readCache.snapshot) --[[@as SaveEditorSnapshot]]
  end
  local playerData = self._baseline.playerData --[[@as table<string, unknown>]]
  local profile = playerData.profile --[[@as table<string, unknown>]]
  local baselineLocation = locationSnapshot(self._baseline)
  local stagedLocation = copy(self._location)
  local locationChanged = not sameLocation(stagedLocation, baselineLocation)
  local dirtyMoney, dirtyFlags = dirtyAgainst(self._baseline, self._money, self._events)
  local partyDirty = not equal(self._monService:capture(), self._baseline.mons)
  local bagDirty = not equal(self._bagService:capture(), self._baseline.bag)
  local snapshot = {
    saveId = self._baseline.saveId --[[@as string]],
    versionId = self._baseline.versionId --[[@as string]],
    playerName = profile.name --[[@as string]],
    money = self._money,
    frameIndex = self._frameIndex,
    flags = flagsFrom(self._events),
    location = stagedLocation,
    facing = self._facing,
    originalLocation = copy(baselineLocation),
    locationChanged = locationChanged,
    dirtySections = {
      money = dirtyMoney,
      frame = self._frameIndex ~= (self._baseline.playerData --[[@as table<string, unknown>]]).options.textFrame,
      flags = dirtyFlags,
      party = partyDirty,
      bag = bagDirty,
      location = locationChanged or self._facing ~= self._baseline.facing,
    },
    revision = self._revision,
  }
  self._readCache = {
    revision = self._revision,
    snapshot = copy(snapshot) --[[@as SaveEditorSnapshot]],
  }
  return snapshot
end

---@return integer
function SaveEditorSession:revision()
  return self._revision
end

---@return integer
function SaveEditorSession:partyRevision()
  return self._partyRevision
end

---@return { revision: integer, members: { slot0: integer, mon: table<string, unknown> }[] }
function SaveEditorSession:partySnapshot()
  local members = {}
  for slot0 = 0, self._monService:partyCount() - 1 do
    members[#members + 1] = { slot0 = slot0, mon = self._monService:partyMon(slot0) }
  end
  return { revision = self._partyRevision, members = members }
end

---@param pocket string
---@return { item: string, quantity: integer }[]
function SaveEditorSession:bagSnapshot(pocket)
  return self._bagService:pocketItems(pocket)
end

---@param slot0 integer
---@return SaveEditorMonDraft? draft
---@return Errors.Error? error
function SaveEditorSession:beginMonEdit(slot0)
  if self._busy then
    return nil, Errors.new(BUSY, "A save operation is already in progress.", {})
  end
  if not finiteInteger(slot0) or slot0 < 0 or slot0 >= self._monService:partyCount() then
    return nil, Errors.new(VALUE_INVALID, "Choose an existing party slot.", { slot = slot0 })
  end
  local draft = SaveEditorMonDraft.new({
    mode = "edit",
    slot0 = slot0,
    basePartyRevision = self._partyRevision,
    record = self._monService:partyMon(slot0),
    context = self._monValidationContext,
  })
  self._drafts[draft] = { kind = "edit", slot0 = slot0, revision = self._partyRevision }
  return draft
end

---@param species string
---@param options { location: integer, date: table<string, unknown> }
---@return SaveEditorMonDraft? draft
---@return Errors.Error? error
function SaveEditorSession:beginMonAdd(species, options)
  assert(type(options) == "table", "new party member requires its staged map section and date")
  if self._busy then
    return nil, Errors.new(BUSY, "A save operation is already in progress.", {})
  end
  if self._monService:partyCount() >= 6 then
    return nil, Errors.new(VALUE_INVALID, "The party already has six members.", {})
  end
  if type(species) ~= "string" or species == "" then
    return nil, Errors.new(VALUE_INVALID, "Choose a catalog species.", {})
  end
  if not finiteInteger(options.location) or type(options.date) ~= "table" then
    return nil, Errors.new(VALUE_INVALID, "New party member requires a valid location and date.", {})
  end

  local candidate = newMonService(self._monServiceOptions, self._monService:capture())
  local ok, added = pcall(function()
    return candidate:giveMon({ species = species, level = 1, location = options.location, date = copy(options.date) })
  end)
  if not ok then
    if Errors.is(added) then
      return nil, added --[[@as Errors.Error]]
    end
    error(added)
  end
  if not added then
    return nil, Errors.new(VALUE_INVALID, "The party could not accept another member.", {})
  end

  local bucket = candidate:capture()
  local slot0 = candidate:partyCount() - 1
  local draft = SaveEditorMonDraft.new({
    mode = "add",
    basePartyRevision = self._partyRevision,
    record = candidate:partyMon(slot0),
    context = self._monValidationContext,
    creationCandidate = bucket,
  })
  self._drafts[draft] = { kind = "add", slot0 = slot0, revision = self._partyRevision }
  return draft
end

---@param draft SaveEditorMonDraft
---@return table<string, unknown>
function SaveEditorSession:applyMonDraft(draft)
  if self._busy then
    return failure(BUSY, "A save operation is already in progress.", {})
  end
  local metadata = self._drafts[draft]
  if metadata == nil then
    return failure(VALUE_INVALID, "The Pokemon draft does not belong to this session.", {})
  end
  if metadata.revision ~= self._partyRevision then
    self._drafts[draft] = nil
    return failure(STALE_DRAFT, "The party changed while this Pokemon draft was open.", {})
  end
  local canonical, validationError = draft:validate()
  if canonical == nil then
    return { ok = false, error = assert(validationError) }
  end

  if metadata.kind == "edit" then
    if
      equal(self._monService:partyMon(metadata.slot0 --[[@as integer]]), canonical)
    then
      self._drafts[draft] = nil
      return success(false)
    end
    local preparation, preparationError = self._monService:preparePartyChanges(
      self._monService:partyRevision(),
      { { slot = metadata.slot0, mon = canonical } }
    )
    if preparation == nil then
      return failure(STALE_DRAFT, "The party changed before this Pokemon could be applied.", {
        reason = preparationError,
      })
    end
    if not preparation.isCurrent() then
      return failure(STALE_DRAFT, "The party changed before this Pokemon could be applied.", {})
    end
    preparation.publish()
  else
    local candidateBucket = assert(draft:creationCandidate(), "Add draft must retain its generated candidate")
    local candidate = newMonService(self._monServiceOptions, candidateBucket)
    local slot0 = candidate:partyCount() - 1
    local preparation, preparationError =
      candidate:preparePartyChanges(candidate:partyRevision(), { { slot = slot0, mon = canonical } })
    if preparation == nil then
      return failure(STALE_DRAFT, "The generated Pokemon candidate is no longer current.", {
        reason = preparationError,
      })
    end
    if not preparation.isCurrent() then
      return failure(STALE_DRAFT, "The generated Pokemon candidate is no longer current.", {})
    end
    preparation.publish()
    self._monService = candidate
  end

  self._drafts[draft] = nil
  self._partyRevision = self._partyRevision + 1
  self._revision = self._revision + 1
  return success(true)
end

---@param left0 integer
---@param right0 integer
---@return table<string, unknown>
function SaveEditorSession:swapPartyMons(left0, right0)
  if self._busy then
    return failure(BUSY, "A save operation is already in progress.", {})
  end
  local count = self._monService:partyCount()
  if
    not finiteInteger(left0)
    or not finiteInteger(right0)
    or left0 < 0
    or right0 < 0
    or left0 >= count
    or right0 >= count
  then
    return failure(VALUE_INVALID, "Choose two existing party slots.", { left = left0, right = right0 })
  end
  if left0 == right0 then
    return success(false)
  end
  self._monService:swapPartyMons(left0, right0)
  self._partyRevision = self._partyRevision + 1
  self._revision = self._revision + 1
  return success(true)
end

---@param itemKey string
---@param quantity integer
---@return table<string, unknown>
function SaveEditorSession:setBagQuantity(itemKey, quantity)
  if self._busy then
    return failure(BUSY, "A save operation is already in progress.", {})
  end
  if type(itemKey) ~= "string" or itemKey == "" or itemKey == "NONE" or not finiteInteger(quantity) or quantity < 0 then
    return failure(VALUE_INVALID, "Choose a catalog item and a non-negative whole quantity.", {})
  end
  local catalog = self._bagService:catalog()
  local itemOk, itemOrError = pcall(function()
    catalog:item(itemKey)
  end)
  if not itemOk then
    if Errors.is(itemOrError) then
      return failure(VALUE_INVALID, "The selected item is not in the catalog.", { item = itemKey })
    end
    error(itemOrError, 0)
  end
  local candidate = HgssBagService.new({ catalog = catalog, bag = self._bagService:capture() })
  local current = candidate:quantity(itemKey)
  if current == quantity then
    return success(false)
  end
  local delta = quantity - current
  local changed
  if delta > 0 then
    changed = candidate:add(itemKey, delta)
  else
    changed = candidate:take(itemKey, -delta)
  end
  if not changed then
    return failure(VALUE_INVALID, "The item quantity exceeds its stack or pocket capacity.", {
      item = itemKey,
      quantity = quantity,
    })
  end
  local validated, validationError = BagSave.validate(candidate:capture(), catalog)
  if validated == nil then
    return { ok = false, error = assert(validationError) }
  end
  self._bagService = HgssBagService.new({ catalog = catalog, bag = validated })
  self._revision = self._revision + 1
  return success(true)
end

---@return boolean
function SaveEditorSession:isDirty()
  local dirty = self:snapshot().dirtySections
  return dirty.money or dirty.frame or dirty.flags or dirty.party or dirty.bag or dirty.location
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

---@param value unknown
---@return table<string, unknown>
function SaveEditorSession:setFrameIndex(value)
  if self._busy then
    return failure(BUSY, "A save operation is already in progress.", {})
  end
  if not finiteInteger(value) or self._frameIndexes[value] ~= true then
    return failure(VALUE_INVALID, "Choose a dialogue frame supported by this game version.", { value = value })
  end
  if value == self._frameIndex then
    return success(false)
  end
  self._frameIndex = value
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

---@class SaveEditorPresetStagingSession
---@field _events FieldEventState
---@field _symbols table<string, unknown>
---@field _bagService HgssBagService
---@field _monService HgssMonService
---@field _monServiceOptions table<string, unknown>
---@field _monValidationContext table<string, unknown>

---@param self SaveEditorPresetStagingSession
---@param preset SaveEditorPresetData
---@return FieldEventState
local function stagePresetEvents(self, preset)
  local eventCandidate = FieldEventState.new(self._events:serialize())
  local flagsByName = self._symbols.flagsByName
  local variablesByName = self._symbols.variablesByName
  assert(type(flagsByName) == "table", "flag symbol catalog is required")
  assert(type(variablesByName) == "table", "variable symbol catalog is required")

  local flagNames = {}
  for name in pairs(preset.flags or {}) do
    flagNames[#flagNames + 1] = name
  end
  table.sort(flagNames)
  for _, name in ipairs(flagNames) do
    local value = preset.flags[name]
    local flagId = flagsByName[name]
    if type(name) ~= "string" or not finiteInteger(flagId) or flagId < 0 or flagId > 0xFFFF then
      error(Errors.new(PRESET_INVALID, "The preset flag is not in the symbol catalog.", { name = name }))
    end
    if type(value) ~= "boolean" then
      error(Errors.new(PRESET_INVALID, "The preset flag value must be boolean.", { name = name }))
    end
    if value then
      eventCandidate:setFlag(flagId)
    else
      eventCandidate:clearFlag(flagId)
    end
  end
  local variableNames = {}
  for name in pairs(preset.variables or {}) do
    variableNames[#variableNames + 1] = name
  end
  table.sort(variableNames)
  for _, name in ipairs(variableNames) do
    local value = preset.variables[name]
    local varId = variablesByName[name]
    if type(name) ~= "string" or not finiteInteger(varId) or varId < 0 or varId > 0xFFFF then
      error(Errors.new(PRESET_INVALID, "The preset variable is not in the symbol catalog.", { name = name }))
    end
    if not finiteInteger(value) or value < 0 or value > 0xFFFF then
      error(Errors.new(PRESET_INVALID, "The preset variable value must be uint16.", { name = name }))
    end
    eventCandidate:setVar(varId, value)
  end
  local serializedEvents, eventError = FieldEventState.validate(eventCandidate:serialize())
  if serializedEvents == nil then
    error(assert(eventError))
  end
  eventCandidate = FieldEventState.new(serializedEvents)

  return eventCandidate
end

---@param self SaveEditorPresetStagingSession
---@param preset SaveEditorPresetData
---@return HgssBagService
local function stagePresetBag(self, preset)
  local bagCandidate = HgssBagService.new({
    catalog = self._bagService:catalog(),
    bag = self._bagService:capture(),
  })
  local itemKeys = {}
  for itemKey in pairs(preset.items or {}) do
    itemKeys[#itemKeys + 1] = itemKey
  end
  table.sort(itemKeys)
  for _, itemKey in ipairs(itemKeys) do
    local minimum = preset.items[itemKey]
    if itemKey == "NONE" then
      error(Errors.new(PRESET_INVALID, "NONE is not a Bag item.", { item = itemKey }))
    end
    local itemOk, itemError = pcall(function()
      bagCandidate:catalog():item(itemKey)
    end)
    if not itemOk then
      if Errors.is(itemError) then
        error(Errors.new(PRESET_INVALID, "The item is not available in the Bag catalog.", {
          item = itemKey,
          reason = Errors.format(itemError),
        }))
      end
      error(itemError, 0)
    end
    if not finiteInteger(minimum) or minimum <= 0 then
      error(Errors.new(PRESET_INVALID, "The item minimum must be a positive integer.", { item = itemKey }))
    end
    local current = bagCandidate:quantity(itemKey)
    if current < minimum and not bagCandidate:add(itemKey, minimum - current) then
      error(Errors.new(PRESET_INVALID, "The requested item minimum exceeds Bag capacity.", {
        item = itemKey,
        quantity = minimum,
      }))
    end
  end
  local validatedBag, bagError = BagSave.validate(bagCandidate:capture(), bagCandidate:catalog())
  if validatedBag == nil then
    error(assert(bagError))
  end
  bagCandidate = HgssBagService.new({ catalog = bagCandidate:catalog(), bag = validatedBag })

  return bagCandidate
end

---@param self SaveEditorPresetStagingSession
---@param preset SaveEditorPresetData
---@param options { metLocation: integer, date: table<string, unknown> }
---@return HgssMonService
local function stagePresetParty(self, preset, options)
  local monCandidate = newMonService(self._monServiceOptions, self._monService:capture())
  local reserved = {}
  local chosenLead
  local function applyMonSpec(spec, path)
    if type(spec) ~= "table" or type(spec.species) ~= "string" or spec.species == "" then
      error(Errors.new(PRESET_INVALID, "A party request requires a species.", { path = path }))
    end
    local slot0
    for candidateSlot = 0, monCandidate:partyCount() - 1 do
      if not reserved[candidateSlot] and monCandidate:partyMon(candidateSlot).species == spec.species then
        slot0 = candidateSlot
        break
      end
    end
    if slot0 == nil then
      if monCandidate:partyCount() >= 6 then
        error(Errors.new(PRESET_INVALID, "The party is full and has no unreserved matching species.", {
          path = path,
          species = spec.species,
        }))
      end
      local added = monCandidate:giveMon({
        species = spec.species,
        level = spec.level or 1,
        location = options.metLocation,
        date = copy(options.date),
      })
      if not added then
        error(Errors.new(PRESET_INVALID, "The party could not accept the requested Pokemon.", {
          path = path,
          species = spec.species,
        }))
      end
      slot0 = monCandidate:partyCount() - 1
    end
    reserved[slot0] = true
    if chosenLead == nil and path == "party.lead" then
      chosenLead = slot0
    end

    local draft = SaveEditorMonDraft.new({
      mode = "edit",
      slot0 = slot0,
      basePartyRevision = monCandidate:partyRevision(),
      record = monCandidate:partyMon(slot0),
      context = self._monValidationContext,
    })
    if spec.level ~= nil and not draft:setLevel(spec.level) then
      error(Errors.new(PRESET_INVALID, "The requested Pokemon level is invalid.", { path = path .. ".level" }))
    end
    if spec.form ~= nil and not draft:setForm(spec.form) then
      error(Errors.new(PRESET_INVALID, "The requested Pokemon form is invalid.", { path = path .. ".form" }))
    end
    if spec.heldItem ~= nil and not draft:setScalar("heldItem", spec.heldItem) then
      error(Errors.new(PRESET_INVALID, "The requested held item is invalid.", { path = path .. ".heldItem" }))
    end
    local updated = draft:record()
    if spec.fatefulEncounter ~= nil then
      updated.fatefulEncounter = spec.fatefulEncounter
    end
    if spec.eggLocation ~= nil then
      local egg = updated.egg --[[@as table<string, unknown>]]
      egg.location = spec.eggLocation
    end
    local valid, canonical = pcall(Mon.validate, updated, self._monValidationContext)
    if not valid then
      if Errors.is(canonical) then
        error(Errors.new(PRESET_INVALID, "The requested Pokemon fields are invalid.", {
          path = path,
          reason = Errors.format(canonical),
        }))
      end
      error(canonical, 0)
    end
    local legal, legality = pcall(NativeLegality.project, canonical, self._monValidationContext)
    if not legal then
      if Errors.is(legality) then
        error(Errors.new(PRESET_INVALID, "The requested Pokemon is not representable.", {
          path = path,
          reason = Errors.format(legality),
        }))
      end
      error(legality, 0)
    end
    local preparation, preparationError =
      monCandidate:preparePartyChanges(monCandidate:partyRevision(), { { slot = slot0, mon = canonical } })
    if preparation == nil or not preparation.isCurrent() then
      error(Errors.new(PRESET_STALE, "The private Party candidate changed during preset staging.", {
        path = path,
        reason = preparationError,
      }))
    end
    preparation.publish()
  end
  if preset.party ~= nil then
    if preset.party.lead ~= nil then
      applyMonSpec(preset.party.lead, "party.lead")
    end
    for index, spec in ipairs(preset.party.contains or {}) do
      applyMonSpec(spec, "party.contains[" .. index .. "]")
    end
    if chosenLead ~= nil and chosenLead ~= 0 then
      monCandidate:swapPartyMons(0, chosenLead)
    end
  end

  return monCandidate
end

---@param preset SaveEditorPresetData
---@param options { expectedRevision: integer, placement?: SaveEditorLocation, metLocation: integer, date: table<string, unknown> }
---@return table<string, unknown>
function SaveEditorSession:applyPreset(preset, options)
  if self._busy then
    return failure(PRESET_UNAVAILABLE, "A save operation is already in progress.", {})
  end
  if type(options) ~= "table" then
    return failure(PRESET_INVALID, "Preset application options are required.", {})
  end
  if not finiteInteger(options.expectedRevision) or options.expectedRevision ~= self._revision then
    return failure(PRESET_STALE, "The staged save changed before the preset could be applied.", {
      expectedRevision = options.expectedRevision,
      actualRevision = self._revision,
    })
  end
  if type(preset) ~= "table" or preset.schema ~= "portemon-save-preset-v1" then
    return failure(PRESET_INVALID, "The preset data is invalid or unsupported.", {})
  end
  if
    type(options.metLocation) ~= "number"
    or not finiteInteger(options.metLocation)
    or type(options.date) ~= "table"
  then
    return failure(PRESET_INVALID, "Preset Pokemon creation requires a valid location and date.", {})
  end
  local requestLocation = preset.location
  if (requestLocation == nil) ~= (options.placement == nil) then
    return failure(PRESET_INVALID, "A resolved placement is required exactly when a preset location is present.", {})
  end
  if requestLocation ~= nil then
    if
      type(requestLocation) ~= "table"
      or type(requestLocation.map) ~= "string"
      or not finiteInteger(requestLocation.x)
      or not finiteInteger(requestLocation.z)
      or not validLocation(options.placement)
      or options.placement.fieldX ~= requestLocation.x
      or options.placement.fieldZ ~= requestLocation.z
    then
      return failure(PRESET_INVALID, "The resolved placement does not match the preset map coordinates.", {
        map = type(requestLocation) == "table" and requestLocation.map or nil,
      })
    end
    local facing = requestLocation.facing
    if facing ~= nil and facing ~= "north" and facing ~= "south" and facing ~= "east" and facing ~= "west" then
      return failure(PRESET_INVALID, "The preset facing is invalid.", { facing = facing })
    end
  end

  local ok, result = pcall(function()
    local eventCandidate = stagePresetEvents(self, preset)
    local bagCandidate = stagePresetBag(self, preset)
    local monCandidate = stagePresetParty(self, preset, options)

    local nextLocation = self._location
    if requestLocation ~= nil and not sameLocation(self._location, options.placement) then
      nextLocation = locationSnapshot(options.placement)
    end
    local nextFacing = requestLocation ~= nil and requestLocation.facing or nil
    if nextFacing == nil then
      nextFacing = self._facing
    end

    local eventsChanged = not equal(eventCandidate:serialize(), self._events:serialize())
    local bagChanged = not equal(bagCandidate:capture(), self._bagService:capture())
    local partyChanged = not equal(monCandidate:capture(), self._monService:capture())
    local locationChanged = not sameLocation(nextLocation, self._location)
    local facingChanged = nextFacing ~= self._facing
    if self._busy then
      error(Errors.new(PRESET_UNAVAILABLE, "A save operation started during preset staging.", {}))
    end
    if self._revision ~= options.expectedRevision then
      error(Errors.new(PRESET_STALE, "The staged save changed during preset staging.", {
        expectedRevision = options.expectedRevision,
        actualRevision = self._revision,
      }))
    end
    local changed = eventsChanged or bagChanged or partyChanged or locationChanged or facingChanged
    if not changed then
      return success(false)
    end
    return {
      changed = true,
      events = eventCandidate,
      bag = bagCandidate,
      party = monCandidate,
      location = nextLocation,
      facing = nextFacing,
      partyChanged = partyChanged,
    }
  end)
  if not ok then
    if Errors.is(result) then
      if result.code == PRESET_INVALID or result.code == PRESET_STALE or result.code == PRESET_UNAVAILABLE then
        return { ok = false, error = result }
      end
      return failure(PRESET_INVALID, "The preset could not be staged.", { reason = Errors.format(result) })
    end
    error(result, 0)
  end
  if result.ok == true then
    return result
  end

  self._events = result.events
  self._bagService = result.bag
  self._monService = result.party
  self._location = result.location
  self._facing = result.facing
  if result.partyChanged then
    self._partyRevision = self._partyRevision + 1
  end
  self._revision = self._revision + 1
  self._readCache = nil
  return success(true)
end

---@param placement SaveEditorLocation
---@return table<string, unknown>
function SaveEditorSession:setLocation(placement)
  if self._busy then
    return failure(BUSY, "A save operation is already in progress.", {})
  end
  if not validLocation(placement) then
    return failure(VALUE_INVALID, "Choose a complete resolved field location.", {})
  end

  ---@type SaveEditorLocation
  local nextLocation = {
    mapId = placement.mapId,
    fieldX = placement.fieldX,
    fieldZ = placement.fieldZ,
    surfaceId = placement.surfaceId,
    worldY = placement.worldY,
    terrainDependencyHash = placement.terrainDependencyHash,
  }
  if sameLocation(self._location, nextLocation) then
    return success(false)
  end

  local candidate = self:captureCandidate()
  applyLocation(candidate, nextLocation, self._baseline)
  self._location = locationSnapshot(candidate)
  self._revision = self._revision + 1
  return success(true)
end

---@return table<string, unknown>
function SaveEditorSession:captureCandidate()
  local candidate = copy(self._baseline)
  local playerData = candidate.playerData --[[@as table<string, unknown>]]
  local profile = playerData.profile --[[@as table<string, unknown>]]
  local playerOptions = playerData.options --[[@as table<string, unknown>]]
  profile.money = self._money
  playerOptions.textFrame = self._frameIndex
  local world = candidate.world --[[@as table<string, unknown>]]
  world.flags = flagsFrom(self._events)
  world.variables = self._events:serialize().vars
  candidate.facing = self._facing
  candidate.mons = self._monService:capture()
  candidate.bag = self._bagService:capture()
  applyLocation(candidate, self._location, self._baseline)
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
    local candidate = self:captureCandidate()

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
    self._location = locationSnapshot(self._baseline)
    self._readCache = nil
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

local SECTION_NAMES = { Location = true, Player = true, Party = true, Bag = true, Progress = true }

---@param section string
---@return boolean changed
local function resetSection(self, section)
  if section == "Player" then
    local playerData = self._baseline.playerData --[[@as table<string, unknown>]]
    local profile = playerData.profile --[[@as table<string, unknown>]]
    local playerOptions = playerData.options --[[@as table<string, unknown>]]
    local changed = self._money ~= profile.money or self._frameIndex ~= playerOptions.textFrame
    self._money = profile.money --[[@as integer]]
    self._frameIndex = playerOptions.textFrame --[[@as integer]]
    return changed
  elseif section == "Progress" then
    local _, dirtyFlags = dirtyAgainst(self._baseline, self._money, self._events)
    if dirtyFlags then
      self._events = FieldEventState.new(eventSnapshot(self._baseline))
      return true
    end
    return false
  elseif section == "Location" then
    if not sameLocation(self._location, locationSnapshot(self._baseline)) or self._facing ~= self._baseline.facing then
      self._location = locationSnapshot(self._baseline)
      self._facing = self._baseline.facing --[[@as string]]
      return true
    end
    return false
  elseif section == "Party" then
    if not equal(self._monService:capture(), self._baseline.mons) then
      self._monService = newMonService(self._monServiceOptions, self._baseline.mons --[[@as table<string, unknown>]])
      return true
    end
    return false
  end
  assert(section == "Bag", "save editor section reset covers every top-level section")
  if not equal(self._bagService:capture(), self._baseline.bag) then
    self._bagService = HgssBagService.new({
      catalog = self._bagService:catalog(),
      bag = self._baseline.bag,
    })
    return true
  end
  return false
end

---@return boolean
function SaveEditorSession:discard()
  if self._busy then
    return false
  end
  if not self:isDirty() then
    self._drafts = setmetatable({}, { __mode = "k" })
    return false
  end
  local partyChanged = resetSection(self, "Party")
  resetSection(self, "Player")
  resetSection(self, "Progress")
  resetSection(self, "Location")
  resetSection(self, "Bag")
  if partyChanged then
    self._partyRevision = self._partyRevision + 1
  end
  self._drafts = setmetatable({}, { __mode = "k" })
  self._revision = self._revision + 1
  return true
end

---@param section string
---@return boolean changed
function SaveEditorSession:discardSection(section)
  assert(SECTION_NAMES[section] == true, "unknown save editor section: " .. tostring(section))
  if self._busy then
    return false
  end
  local changed = resetSection(self, section)
  if section == "Party" and changed then
    self._partyRevision = self._partyRevision + 1
    self._drafts = setmetatable({}, { __mode = "k" })
  end
  if changed then
    self._revision = self._revision + 1
  end
  return changed
end

return SaveEditorSession
