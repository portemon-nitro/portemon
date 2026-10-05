-- Owns one private, validated save-edit transaction.

local Errors = require("libs.errors.src.Errors")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local PlayerData = require("libs.hgss.src.save.PlayerData")
local ScriptSave = require("libs.script.src.ScriptSave")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local HgssBagService = require("libs.hgss.src.items.HgssBagService")
local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
local BagSave = require("libs.hgss.src.save.BagSave")
local SaveEditorMonDraft = require("app.src.saveeditor.SaveEditorMonDraft")

local SaveEditorSession = {}
SaveEditorSession.__index = SaveEditorSession

local ACTIVE_SCRIPT = "SAVE_EDITOR_ACTIVE_SCRIPT"
local CONFLICT = "SAVE_EDITOR_CONFLICT"
local VALUE_INVALID = "SAVE_EDITOR_VALUE_INVALID"
local BUSY = "SAVE_EDITOR_BUSY"
local DRAFT_PENDING = "SAVE_EDITOR_DRAFT_PENDING"
local STALE_DRAFT = "SAVE_EDITOR_STALE_DRAFT"

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
---@field originalLocation SaveEditorLocation
---@field dirtySections SaveEditorDirtySections
---@field locationChanged boolean
---@field revision integer

---@class SaveEditorSession
---@field snapshot fun(self: SaveEditorSession): SaveEditorSnapshot
---@field isDirty fun(self: SaveEditorSession): boolean
---@field partyRevision fun(self: SaveEditorSession): integer
---@field partySnapshot fun(self: SaveEditorSession): { revision: integer, members: { slot0: integer, mon: table<string, unknown> }[] }
---@field bagSnapshot fun(self: SaveEditorSession, pocket: string): { item: string, quantity: integer }[]
---@field beginMonEdit fun(self: SaveEditorSession, slot0: integer): SaveEditorMonDraft?, Errors.Error?
---@field beginMonAdd fun(self: SaveEditorSession, species: string, options: { location: integer, date: table<string, unknown> }): SaveEditorMonDraft?, Errors.Error?
---@field applyMonDraft fun(self: SaveEditorSession, draft: SaveEditorMonDraft): table<string, unknown>
---@field removePartyMon fun(self: SaveEditorSession, slot0: integer): table<string, unknown>
---@field swapPartyMons fun(self: SaveEditorSession, left0: integer, right0: integer): table<string, unknown>
---@field setBagQuantity fun(self: SaveEditorSession, itemKey: string, quantity: integer): table<string, unknown>
---@field setMoney fun(self: SaveEditorSession, value: unknown): table<string, unknown>
---@field setFrameIndex fun(self: SaveEditorSession, value: unknown): table<string, unknown>
---@field setFlag fun(self: SaveEditorSession, name: unknown, value: unknown): table<string, unknown>
---@field setLocation fun(self: SaveEditorSession, placement: SaveEditorLocation): table<string, unknown>
---@field save fun(self: SaveEditorSession, hasUnappliedDraft: boolean?): table<string, unknown>
---@field discard fun(self: SaveEditorSession): boolean
---@field private _baseline table<string, unknown>
---@field private _entryCheckpoint table<string, unknown>
---@field private _money integer
---@field private _frameIndex integer
---@field private _frameIndexes table<integer, boolean>
---@field private _location SaveEditorLocation
---@field private _events FieldEventState
---@field private _symbols table<string, unknown>
---@field private _saveStore table<string, unknown>
---@field private _saveFs SaveFs
---@field private _validateRecord fun(record: table<string, unknown>): table<string, unknown>?, Errors.Error?
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
  local monService = newMonService(monServiceOptions, baseline.mons --[[@as table<string, unknown>]])
  local session = setmetatable({
    _baseline = baseline,
    _entryCheckpoint = copy(baseline),
    _money = profile.money,
    _frameIndex = frameIndex,
    _frameIndexes = frameIndexes,
    _location = locationSnapshot(baseline),
    _events = events,
    _symbols = options.symbols or FieldScriptSymbols,
    _saveStore = options.saveStore,
    _saveFs = options.saveFs,
    _validateRecord = options.validateRecord,
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
    originalLocation = copy(baselineLocation),
    locationChanged = locationChanged,
    dirtySections = {
      money = dirtyMoney,
      frame = self._frameIndex ~= (self._baseline.playerData --[[@as table<string, unknown>]]).options.textFrame,
      flags = dirtyFlags,
      party = partyDirty,
      bag = bagDirty,
      location = locationChanged,
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

---@param slot0 integer
---@return table<string, unknown>
function SaveEditorSession:removePartyMon(slot0)
  if self._busy then
    return failure(BUSY, "A save operation is already in progress.", {})
  end
  if not finiteInteger(slot0) or slot0 < 0 or slot0 >= self._monService:partyCount() then
    return failure(VALUE_INVALID, "Choose an existing party slot.", { slot = slot0 })
  end
  self._monService:removeMon(slot0)
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
  local validated, validationError = self._validateRecord(candidate)
  if validated == nil then
    if Errors.is(validationError) then
      return { ok = false, error = validationError }
    end
    return failure(VALUE_INVALID, "The destination did not pass complete save validation.", {})
  end

  self._location = locationSnapshot(validated)
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

---@return boolean
function SaveEditorSession:discard()
  if self._busy then
    return false
  end
  local changed = self:isDirty()
  if not changed then
    self._drafts = setmetatable({}, { __mode = "k" })
    return false
  end
  local playerData = self._baseline.playerData --[[@as table<string, unknown>]]
  local profile = playerData.profile --[[@as table<string, unknown>]]
  self._money = profile.money --[[@as integer]]
  local playerOptions = playerData.options --[[@as table<string, unknown>]]
  self._frameIndex = playerOptions.textFrame --[[@as integer]]
  self._location = locationSnapshot(self._baseline)
  self._events = FieldEventState.new(eventSnapshot(self._baseline))
  if not equal(self._monService:capture(), self._baseline.mons) then
    self._monService = newMonService(self._monServiceOptions, self._baseline.mons --[[@as table<string, unknown>]])
    self._partyRevision = self._partyRevision + 1
  end
  if not equal(self._bagService:capture(), self._baseline.bag) then
    self._bagService = HgssBagService.new({
      catalog = self._bagService:catalog(),
      bag = self._baseline.bag,
    })
  end
  self._drafts = setmetatable({}, { __mode = "k" })
  self._revision = self._revision + 1
  return true
end

return SaveEditorSession
