-- Owns the global save catalog and published GameSave payloads. Reservation,
-- first publication, update, and deletion are serialized through SaveFs and
-- keep catalog visibility authoritative over the games directory.

local Errors = require("libs.errors.src.Errors")
local GameSave = require("libs.hgss.src.save.GameSave")
local GameSaveErrors = require("libs.hgss.src.save.GameSaveErrors")
local SaveFs = require("libs.storage.src.SaveFs")
local StorageErrors = require("libs.storage.src.errors")

local GameSaveStore = {}
GameSaveStore.__index = GameSaveStore

GameSaveStore.CATALOG_SCHEMA = "g4-save-catalog-v1"
GameSaveStore.CATALOG_PATH = "catalog.lua"
GameSaveStore.CATALOG_TEMP_PATH = "catalog.lua.tmp"

local function idForNumber(number)
  return string.format("save-%08d", number)
end

local function numberForId(saveId)
  local number = saveId:match("^save%-(%d+)$")
  if not number then
    return nil
  end
  return tonumber(number)
end

local function isMissing(err)
  return Errors.is(err) and err.code == StorageErrors.SAVE_FILE_MISSING
end

local function catalogError(message, context)
  Errors.raise(GameSaveErrors.GAME_SAVE_CATALOG_INVALID, message, context or {})
end

---@class GameSaveCatalog
---@field schema string
---@field nextId integer
---@field allocatedIds string[]
---@field deletedIds string[]
---@field saveIds string[]

---@param catalog unknown
---@return GameSaveCatalog
local function validateCatalog(catalog)
  if type(catalog) ~= "table" or catalog.schema ~= GameSaveStore.CATALOG_SCHEMA then
    catalogError("save catalog schema is unsupported", { schema = type(catalog) == "table" and catalog.schema or nil })
  end
  if
    type(catalog.nextId) ~= "number"
    or catalog.nextId % 1 ~= 0
    or catalog.nextId < 1
    or catalog.nextId > 0xFFFFFFFF
  then
    catalogError("save catalog next id is invalid", { nextId = catalog.nextId })
  end
  if type(catalog.allocatedIds) ~= "table" then
    catalogError("save catalog id list is required", { field = "allocatedIds" })
  end
  if type(catalog.deletedIds) ~= "table" then
    catalogError("save catalog id list is required", { field = "deletedIds" })
  end
  if type(catalog.saveIds) ~= "table" then
    catalogError("save catalog id list is required", { field = "saveIds" })
  end
  ---@cast catalog GameSaveCatalog
  -- Catalog reads protect addressing and enumeration only: every id list
  -- must be a dense array of safe save ids below nextId so the next
  -- reservation cannot collide with a catalog-known identity, and the
  -- visible list must not name the same save twice. Unknown catalog
  -- fields and nonessential history relationships are preserved, never
  -- corruption: mutations below edit the loaded table in place.
  for _, ids in ipairs({ catalog.allocatedIds, catalog.deletedIds, catalog.saveIds }) do
    for key in pairs(ids) do
      if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > #ids then
        catalogError("save catalog id lists must be contiguous arrays", {})
      end
    end
    for index = 1, #ids do
      local saveId = ids[index]
      local valid, err = GameSave.validateSaveId(saveId)
      if not valid then
        error(err)
      end
      local number = numberForId(saveId)
      if number == nil or number >= catalog.nextId then
        catalogError("save catalog id is outside the allocated range", { saveId = saveId })
      end
    end
  end
  local seen = {}
  for index = 1, #catalog.saveIds do
    local saveId = catalog.saveIds[index]
    if seen[saveId] then
      catalogError("save catalog contains a duplicate id", { saveId = saveId })
    end
    seen[saveId] = true
  end
  return catalog
end

---@return GameSaveCatalog
local function emptyCatalog()
  return { schema = GameSaveStore.CATALOG_SCHEMA, nextId = 1, allocatedIds = {}, deletedIds = {}, saveIds = {} }
end

-- Retained prior payload generations per save id. Generation 1 is the
-- newest predecessor; older than 3 is discarded.
local ROLLBACK_GENERATIONS = 3

-- Write-side identity for owner-produced snapshots. Persistence trusts the
-- snapshot beyond storage identity: a table carrying the current schema
-- under a safe save id. Envelope routing and nested semantics stay
-- read-side concerns owned by GameSave.normalize and the restoring
-- domains. Returns the record itself, never a normalized copy.
---@param record unknown
---@return table<string, unknown>
local function checkWriteIdentity(record)
  if type(record) ~= "table" then
    Errors.raise(GameSaveErrors.GAME_SAVE_INVALID, "game save must be a table", {})
  end
  assert(type(record) == "table")
  if record.schema ~= GameSave.SCHEMA then
    Errors.raise(
      GameSaveErrors.GAME_SAVE_SCHEMA_UNSUPPORTED,
      "unsupported game save schema",
      { schema = record.schema }
    )
  end
  local valid, err = GameSave.validateSaveId(record.saveId)
  if not valid then
    error(err)
  end
  return record
end

---@class GameSaveStoreModule
---@field new fun(saveFs: SaveFs): GameSaveStore
---@class GameSaveStore
---@field saveFs SaveFs
---@field private _busy boolean
---@field reserve fun(self: GameSaveStore): string
---@field list fun(self: GameSaveStore): table[]
---@field listMetadata fun(self: GameSaveStore): table[]
---@field load fun(self: GameSaveStore, saveId: string): table<string, unknown>?, Errors.Error?
---@field publishFirst fun(self: GameSaveStore, record: table<string, unknown>): boolean
---@field save fun(self: GameSaveStore, record: table<string, unknown>): boolean
---@field delete fun(self: GameSaveStore, saveId: string): boolean
---@param saveFs SaveFs
---@return GameSaveStore
function GameSaveStore.new(saveFs)
  assert(
    getmetatable(saveFs) == SaveFs and saveFs:prefix() == "saves/" and saveFs.versionId == nil,
    "global GameSave store requires a global SaveFs"
  )
  local store = setmetatable({ saveFs = saveFs, _busy = false }, GameSaveStore)
  ---@cast store GameSaveStore
  return store
end

function GameSaveStore:_mutate(operation)
  assert(not self._busy, "game save mutation is already active")
  self._busy = true
  local ok, first = pcall(operation)
  self._busy = false
  if not ok then
    error(first)
  end
  return first
end

function GameSaveStore:_readCatalog()
  local catalog, err = self.saveFs:loadLua(GameSaveStore.CATALOG_PATH)
  if catalog == nil then
    if isMissing(err) then
      return emptyCatalog()
    end
    if err ~= nil then
      error(err)
    end
    catalogError("save catalog load returned neither a catalog nor an error", {})
  end
  return validateCatalog(catalog)
end

function GameSaveStore:_writeCatalog(catalog)
  local ok, err = pcall(function()
    self.saveFs:writeLua(GameSaveStore.CATALOG_TEMP_PATH, catalog)
    self.saveFs:replace(GameSaveStore.CATALOG_TEMP_PATH, GameSaveStore.CATALOG_PATH)
  end)
  if not ok then
    pcall(function()
      self.saveFs:remove(GameSaveStore.CATALOG_TEMP_PATH)
    end)
    error(err)
  end
end

function GameSaveStore:_gamePath(saveId)
  local valid, err = GameSave.validateSaveId(saveId)
  if not valid then
    error(err)
  end
  valid = assert(valid)
  return "games/" .. saveId .. ".lua"
end

function GameSaveStore:_payloadTempPath(saveId)
  return self:_gamePath(saveId) .. ".tmp"
end

function GameSaveStore:_backupPath(saveId, generation)
  assert(generation >= 1 and generation <= ROLLBACK_GENERATIONS, "rollback generation is out of range")
  return "backups/" .. saveId .. "." .. generation .. ".lua"
end

function GameSaveStore:_backupTempPath(saveId, generation)
  return self:_backupPath(saveId, generation) .. ".tmp"
end

-- Reads the exact stored bytes that one update must preserve: the current
-- payload followed by the prior first and second generations. Raw bytes
-- travel untouched so history tolerates payloads the runtime no longer
-- parses. A missing current payload for a catalog-listed save is a
-- persistence failure; a missing prior generation only means its
-- destination must be absent after rotation.
---@param saveId string
---@param payloadPath string
---@return (string?)[]
function GameSaveStore:_readPredecessorBytes(saveId, payloadPath)
  local predecessors = {}
  local sources = { payloadPath }
  for generation = 1, ROLLBACK_GENERATIONS - 1 do
    sources[#sources + 1] = self:_backupPath(saveId, generation)
  end
  for index, source in ipairs(sources) do
    local bytes = self:_readRawOrNil(source)
    if bytes == nil and index == 1 then
      Errors.raise(GameSaveErrors.GAME_SAVE_NOT_PUBLISHED, "save payload is missing", { saveId = saveId })
    end
    predecessors[index] = bytes
  end
  return predecessors
end

-- Reads exact stored bytes, or nil when the file is absent. Existence is
-- probed first because backends report a missing file either as absent or
-- as a read error; a file that exists but cannot be read stays a
-- structured read failure, matching the load boundary.
---@param path string
---@return string?
function GameSaveStore:_readRawOrNil(path)
  if not self.saveFs.backend:getInfo(self.saveFs:resolve(path)) then
    return nil
  end
  local bytes, readErr = self.saveFs:read(path)
  if bytes == nil then
    Errors.raise(StorageErrors.SAVE_READ_FAILED, "save predecessor read failed", {
      path = path,
      cause = readErr,
    })
  end
  return bytes
end

-- Read-side normalization for catalog-listed payloads. Full envelope
-- migration and routing checks run here on load; writes never call this.
function GameSaveStore:_normalizeRecord(record, expectedSaveId)
  local normalized, err = GameSave.normalize(record)
  if not normalized then
    error(err)
  end
  normalized = assert(normalized)
  if expectedSaveId ~= nil and normalized.saveId ~= expectedSaveId then
    Errors.raise(GameSaveErrors.GAME_SAVE_SAVE_ID_MISMATCH, "game save id does not match its catalog identity", {
      expected = expectedSaveId,
      actual = normalized.saveId,
    })
  end
  return normalized
end

function GameSaveStore:_isListed(catalog, saveId)
  for index = 1, #catalog.saveIds do
    if catalog.saveIds[index] == saveId then
      return index
    end
  end
  return nil
end

function GameSaveStore:_isReserved(catalog, saveId)
  for _, allocatedId in ipairs(catalog.allocatedIds) do
    if allocatedId == saveId then
      for _, deletedId in ipairs(catalog.deletedIds) do
        if deletedId == saveId then
          return false
        end
      end
      return not self:_isListed(catalog, saveId)
    end
  end
  return false
end

function GameSaveStore:_loadPublished(saveId)
  local record, err = self.saveFs:loadLua(self:_gamePath(saveId))
  if record == nil and err ~= nil then
    error(err)
  end
  return self:_normalizeRecord(record --[[@as table]], saveId)
end

-- Reads one payload's display envelope without normalization: the raw
-- record is loaded as stored and only GameSave.metadata runs over it. No
-- generated cache is touched. A catalog-listed id whose payload carries
-- another id is a mismatch.
---@param saveId string
---@return table<string, unknown>
function GameSaveStore:_loadEnvelope(saveId)
  local record, err = self.saveFs:loadLua(self:_gamePath(saveId))
  if record == nil then
    if err ~= nil then
      error(err)
    end
    Errors.raise(GameSaveErrors.GAME_SAVE_NOT_PUBLISHED, "save payload is missing", { saveId = saveId })
  end
  assert(type(record) == "table")
  local envelope, envelopeErr = GameSave.metadata(record)
  if envelope == nil then
    error(assert(envelopeErr))
  end
  if envelope.saveId ~= saveId then
    Errors.raise(GameSaveErrors.GAME_SAVE_SAVE_ID_MISMATCH, "game save id does not match its catalog identity", {
      expected = saveId,
      actual = envelope.saveId,
    })
  end
  return envelope
end

---@return string
function GameSaveStore:reserve()
  local saveId = self:_mutate(function()
    local catalog = self:_readCatalog()
    if catalog.nextId >= 0xFFFFFFFF then
      catalogError("save catalog allocation is exhausted", { nextId = catalog.nextId })
    end
    local saveId = idForNumber(catalog.nextId)
    catalog.nextId = catalog.nextId + 1
    catalog.allocatedIds[#catalog.allocatedIds + 1] = saveId
    self:_writeCatalog(catalog)
    return saveId
  end)
  return saveId
end

---@return table[]
function GameSaveStore:list()
  local catalog = self:_readCatalog()
  local entries = {}
  for index = #catalog.saveIds, 1, -1 do
    local saveId = catalog.saveIds[index]
    local ok, recordOrError = pcall(function()
      return self:_loadPublished(saveId)
    end)
    if ok then
      local record = assert(recordOrError --[[@as table]])
      entries[#entries + 1] = {
        saveId = saveId,
        versionId = record.versionId,
        playerData = record.playerData,
        playTimeSeconds = record.playTimeSeconds,
      }
    elseif Errors.is(recordOrError) then
      entries[#entries + 1] = { saveId = saveId, error = recordOrError }
    else
      error(recordOrError)
    end
  end
  return entries
end

-- Metadata-only listing for menu cards: validates the catalog and each
-- payload's display envelope without normalizing records and without
-- reading generated caches. A listed envelope is not thereby loadable.
-- Ordering and per-entry error reporting match list().
---@return table[]
function GameSaveStore:listMetadata()
  local catalog = self:_readCatalog()
  local entries = {}
  for index = #catalog.saveIds, 1, -1 do
    local saveId = catalog.saveIds[index]
    local ok, envelopeOrError = pcall(function()
      return self:_loadEnvelope(saveId)
    end)
    if ok then
      entries[#entries + 1] = assert(envelopeOrError --[[@as table]])
    elseif Errors.is(envelopeOrError) then
      entries[#entries + 1] = { saveId = saveId, error = envelopeOrError }
    else
      error(envelopeOrError)
    end
  end
  return entries
end

---@param saveId string
---@return table<string, unknown>|nil, Errors.Error?
function GameSaveStore:load(saveId)
  local valid, idErr = GameSave.validateSaveId(saveId)
  if not valid then
    return nil, idErr
  end
  local catalog = self:_readCatalog()
  if not self:_isListed(catalog, saveId) then
    Errors.raise(GameSaveErrors.GAME_SAVE_NOT_PUBLISHED, "save id is not catalog-visible", { saveId = saveId })
  end
  local ok, recordOrError = pcall(function()
    return self:_loadPublished(saveId)
  end)
  if ok then
    return recordOrError
  end
  error(recordOrError)
end

---@param record table<string, unknown>
---@return boolean
function GameSaveStore:publishFirst(record)
  return self:_mutate(function()
    local catalog = self:_readCatalog()
    local valid = checkWriteIdentity(record)
    if self:_isListed(catalog, valid.saveId) then
      Errors.raise(
        GameSaveErrors.GAME_SAVE_ALREADY_PUBLISHED,
        "game save is already catalog-visible",
        { saveId = valid.saveId }
      )
    end
    if not self:_isReserved(catalog, valid.saveId) then
      Errors.raise(GameSaveErrors.GAME_SAVE_NOT_RESERVED, "game save id was not reserved", { saveId = valid.saveId })
    end
    -- A first publication has no prior checkpoint to protect. The owner
    -- snapshot is staged before it is moved into place, and catalog
    -- visibility is published only after that move succeeds.
    local payloadPath = self:_gamePath(valid.saveId)
    local temporaryPath = self:_payloadTempPath(valid.saveId)
    local payloadOk, payloadErr = pcall(function()
      self.saveFs:writeLua(temporaryPath, valid)
      self.saveFs:replace(temporaryPath, payloadPath)
    end)
    if not payloadOk then
      -- The first payload has no previous checkpoint to restore. Remove any
      -- staged residue and rethrow the original failure; catalog visibility
      -- remains unchanged and a failed payload move cannot publish a file.
      pcall(function()
        self.saveFs:remove(temporaryPath)
      end)
      error(payloadErr)
    end
    -- Visible saves enumerate in stored order: a first publication
    -- appends its reserved id without proving any historical position.
    table.insert(catalog.saveIds, valid.saveId)
    self:_writeCatalog(catalog)
    return true
  end)
end

---@param record table<string, unknown>
---@return boolean
function GameSaveStore:save(record)
  return self:_mutate(function()
    local catalog = self:_readCatalog()
    local valid = checkWriteIdentity(record)
    if not self:_isListed(catalog, valid.saveId) then
      Errors.raise(
        GameSaveErrors.GAME_SAVE_NOT_PUBLISHED,
        "game save is not catalog-visible",
        { saveId = valid.saveId }
      )
    end
    local saveId = valid.saveId
    local payloadPath = self:_gamePath(saveId)
    local temporaryPath = self:_payloadTempPath(saveId)
    -- Stage the new current payload first so a serialization failure
    -- cannot disturb the authoritative current or its history. Rollback
    -- generations commit oldest-to-newest and the current replacement
    -- moves last; any failure before that final move leaves the prior
    -- current payload authoritative.
    local ok, err = pcall(function()
      self.saveFs:writeLua(temporaryPath, valid)
      local predecessors = self:_readPredecessorBytes(saveId, payloadPath)
      for generation = 1, ROLLBACK_GENERATIONS do
        if predecessors[generation] ~= nil then
          self.saveFs:write(self:_backupTempPath(saveId, generation), assert(predecessors[generation]))
        end
      end
      for generation = ROLLBACK_GENERATIONS, 1, -1 do
        if predecessors[generation] ~= nil then
          self.saveFs:replace(self:_backupTempPath(saveId, generation), self:_backupPath(saveId, generation))
        else
          self.saveFs:remove(self:_backupPath(saveId, generation))
        end
      end
      self.saveFs:replace(temporaryPath, payloadPath)
    end)
    if not ok then
      -- Best-effort temp cleanup; the originating failure propagates.
      -- Committed rollback files already hold only previously published
      -- bytes, never the staged snapshot.
      pcall(function()
        self.saveFs:remove(temporaryPath)
      end)
      for generation = 1, ROLLBACK_GENERATIONS do
        pcall(function()
          self.saveFs:remove(self:_backupTempPath(saveId, generation))
        end)
      end
      error(err)
    end
    return true
  end)
end

---@param saveId string
---@return boolean
function GameSaveStore:delete(saveId)
  local valid, idErr = GameSave.validateSaveId(saveId)
  if not valid then
    error(idErr)
  end
  return self:_mutate(function()
    local catalog = self:_readCatalog()
    local index = self:_isListed(catalog, saveId)
    if index then
      table.remove(catalog.saveIds, index)
      catalog.deletedIds[#catalog.deletedIds + 1] = saveId
      self:_writeCatalog(catalog)
    end
    -- Catalog removal is the logical commit. A failed cleanup leaves an
    -- invisible orphan, never a visible entry with a deliberately destroyed
    -- payload; the cleanup error still reaches the caller.
    self.saveFs:remove(self:_gamePath(saveId))
    self.saveFs:remove(self:_payloadTempPath(saveId))
    for generation = 1, ROLLBACK_GENERATIONS do
      self.saveFs:remove(self:_backupPath(saveId, generation))
      self.saveFs:remove(self:_backupTempPath(saveId, generation))
    end
    return true
  end)
end

return GameSaveStore
