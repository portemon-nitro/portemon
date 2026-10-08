-- Deterministic logical-field dependency closure over caller-owned field,
-- script and audio metadata. The caller proves its inputs are current
-- before calling: this module performs no cache reads, no requests, no
-- validation and no retained memoization. Unknown references fail loudly
-- with map-scoped diagnostics; incomplete knowledge never reaches this
-- module and is pending membership at the caller, never an empty closure.

---@class LogicalFieldPlan.AudioEntry
---@field bankId integer|nil adopted audio bank for a resolved sequence

---@class LogicalFieldPlan.AudioIndex
---@field sequences table<integer, LogicalFieldPlan.AudioEntry> adopted sequence metadata by numeric id
---@field sequenceBySymbol table<string, integer> adopted sequence id by canonical symbol

---@class LogicalFieldPlan.Dependency
---@field kind string
---@field key string

local LogicalFieldPlan = {}

---@param value unknown
---@return boolean
local function isBankId(value)
  return type(value) == "number"
    and value % 1 == 0
    and (
      value --[[@as integer]]
      >= 0
    )
end

---@param mapId integer
---@param fieldRecord table<string, unknown>
---@return integer messageBankId
---@return integer scriptBankId
local function requiredBanks(mapId, fieldRecord)
  local messageBankId = fieldRecord.messageBankId
  if not isBankId(messageBankId) then
    error("logical field " .. tostring(mapId) .. ": field record has no message bank", 0)
  end
  local scriptBankId = fieldRecord.scriptBankId
  if not isBankId(scriptBankId) then
    error("logical field " .. tostring(mapId) .. ": field record has no script member", 0)
  end
  return messageBankId, --[[@as integer]]
    scriptBankId --[[@as integer]]
end

---@param mapId integer
---@param audioIndex LogicalFieldPlan.AudioIndex
---@param banks table<string, boolean> distinct adopted bank keys observed so far
---@param reference unknown adopted sequence symbol, numeric id or nil
local function addSequenceReference(mapId, audioIndex, banks, reference)
  if reference == nil then
    return
  end
  local sequenceId = reference
  if type(reference) == "string" then
    local resolved = audioIndex.sequenceBySymbol[reference]
    if resolved == nil then
      error("logical field " .. tostring(mapId) .. " has no adopted sequence: " .. reference, 0)
    end
    sequenceId = resolved
  end
  if type(sequenceId) ~= "number" or sequenceId % 1 ~= 0 or sequenceId < 0 then
    error("logical field " .. tostring(mapId) .. " has no adopted sequence: " .. tostring(reference), 0)
  end
  local entry = audioIndex.sequences[
    sequenceId --[[@as integer]]
  ]
  if type(entry) ~= "table" then
    error("logical field " .. tostring(mapId) .. " has no adopted sequence: " .. tostring(reference), 0)
  end
  if not isBankId(entry.bankId) then
    error("logical field " .. tostring(mapId) .. " audio reference resolves to no bank: " .. tostring(reference), 0)
  end
  banks[tostring(entry.bankId)] = true
end

---@param mapId integer
---@param fieldRecord table<string, unknown>
---@param audioIndex LogicalFieldPlan.AudioIndex
---@param banks table<string, boolean> distinct adopted bank keys observed so far
local function addFieldMusic(mapId, fieldRecord, audioIndex, banks)
  local music = fieldRecord.music
  if type(music) ~= "table" then
    return
  end
  addSequenceReference(mapId, audioIndex, banks, music.day)
  addSequenceReference(mapId, audioIndex, banks, music.night)
  local flagOverrides = music.flagOverrides
  if type(flagOverrides) == "table" then
    for _, override in ipairs(flagOverrides) do
      if type(override) == "table" then
        addSequenceReference(mapId, audioIndex, banks, override.sequence)
      end
    end
  end
  local traversalOverrides = music.traversalOverrides
  if type(traversalOverrides) == "table" then
    for _, override in ipairs(traversalOverrides) do
      if type(override) == "table" then
        addSequenceReference(mapId, audioIndex, banks, override.sequence)
      end
    end
  end
end

---@param mapId integer
---@param fieldRecord table<string, unknown>
---@param audioIndex LogicalFieldPlan.AudioIndex
---@param banks table<string, boolean> distinct adopted bank keys observed so far
local function addFieldSoundplates(mapId, fieldRecord, audioIndex, banks)
  local soundplates = fieldRecord.soundplates
  if type(soundplates) ~= "table" then
    return
  end
  for _, plate in ipairs(soundplates) do
    if type(plate) == "table" then
      addSequenceReference(mapId, audioIndex, banks, plate.sequence)
    end
  end
end

---@param mapId integer
---@param fieldRecord table<string, unknown> current field record with message and script bank ids
---@param scriptSequences string[] validated transitive script-audio closure symbols for the script member
---@param audioIndex LogicalFieldPlan.AudioIndex adopted audio sequence metadata
---@return LogicalFieldPlan.Dependency[] canonical fixed members with distinct audio banks in ascending order
function LogicalFieldPlan.members(mapId, fieldRecord, scriptSequences, audioIndex)
  assert(type(mapId) == "number", "logical field closure needs its map id")
  assert(type(fieldRecord) == "table", "logical field closure needs its field record")
  assert(type(scriptSequences) == "table", "logical field closure needs its script sequences")
  assert(type(audioIndex) == "table", "logical field closure needs its adopted audio index")
  local sequences = assert(audioIndex.sequences, "logical field closure needs the adopted sequences")
  assert(type(sequences) == "table", "logical field closure needs the adopted sequences")
  local sequenceBySymbol =
    assert(audioIndex.sequenceBySymbol, "logical field closure needs the adopted sequence symbols")
  assert(type(sequenceBySymbol) == "table", "logical field closure needs the adopted sequence symbols")
  local resolvedIndex = { sequences = sequences, sequenceBySymbol = sequenceBySymbol }
  local messageBankId, scriptBankId = requiredBanks(mapId, fieldRecord)
  local members = {
    { kind = "map-data", key = tostring(mapId) },
    { kind = "message-bank", key = tostring(messageBankId) },
    { kind = "script-member", key = tostring(scriptBankId) },
    { kind = "script-summary", key = "global" },
    { kind = "audio-catalog", key = "global" },
  }
  local banks = {}
  addFieldMusic(mapId, fieldRecord, resolvedIndex, banks)
  addFieldSoundplates(mapId, fieldRecord, resolvedIndex, banks)
  -- Script-reachable audio joins the map-derived banks through the same
  -- adopted sequence resolution, so shared banks collapse and a member
  -- with an explicit empty closure adds nothing.
  for _, symbol in ipairs(scriptSequences) do
    addSequenceReference(mapId, resolvedIndex, banks, symbol)
  end
  local ordered = {}
  for bankKey in pairs(banks) do
    ordered[#ordered + 1] = bankKey
  end
  table.sort(ordered, function(first, second)
    return tonumber(first) < tonumber(second)
  end)
  for _, bankKey in ipairs(ordered) do
    members[#members + 1] = { kind = "audio-bank", key = bankKey }
  end
  return members
end

return LogicalFieldPlan
