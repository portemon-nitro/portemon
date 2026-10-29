-- FieldAudioController: the stateful field-audio policy service. Owns the
-- current field map audio record, effective field-music selection (day/night
-- + flag overrides + persisted override), soundplate selection and
-- environmental audio state, and delegating the script audio facade (play,
-- stop, playMusic, etc.) to the composed GameSound instance. It also owns
-- the radio interface teardown transition: closing during ordinary music
-- leaves the surviving radio alive (an unchanged map never replaces the BGM
-- behind it), while untuned, jingle, and commercial exits fade, clear the
-- radio, and restore the field music exactly once.
--
-- Field-music policy:
-- 1. mapHeaderMusic(): day/night selection + flag-based map override
-- 2. effectiveMusic(): persisted override > map-header
-- 3. resetMusic(): map-header only (ignores persisted)
--
-- Soundplate/environment policy:
-- - Selection: iterate source-order records, keep last (highest) match
-- - Active gate: test selected plate's disabledWhenFlag (no fallback if disabled)
-- - Volume ramps: BGM duck + ambient moves via GameSound:moveSequenceVolume
-- - Exit: fade-stop environment, restore BGM to level 128

local FieldMapDataCache = require("libs.assets.src.field.FieldMapDataCache")
local AudioBank = require("libs.assets.src.audio.AudioBank")

---@class FieldAudioControllerOptions
---@field sound GameSound
---@field provider AudioAssetProvider
---@field eventState unknown
---@field fieldPosition fun(): integer, integer
---@field dayNight fun(): "day"|"night"
---@field fieldDataForMap fun(mapId: integer|string): unknown

---@class FieldAudioController
---@field private _sound GameSound
---@field private _provider AudioAssetProvider
---@field private _fieldPosition fun(): integer, integer
---@field private _dayNight fun(): "day"|"night"
---@field private _fieldDataForMap fun(mapId: integer|string): unknown
---@field _currentMap unknown
---@field _fieldMusic integer|nil
---@field _musicOverride integer|nil
---@field _environment { sequence: integer }|nil
---@field _pendingFieldMusicPolicy FieldAudioControllerPendingMusicPolicy|nil
---@field _eventState unknown
---@field _predictionEpoch integer soft-demand round published by prewarm and override transitions
---@field _predictedBankIds integer[] reachable audio bank ids of the current round, ascending
---@field _prewarmMemo table<string, integer[]>
---@field _prewarmMemoOrder string[]
---@field isEffectPlaying fun(self: FieldAudioController, idOrSymbol: integer|string): boolean
---@field isEffectWaitComplete fun(self: FieldAudioController, idOrSymbol: integer|string): boolean
local FieldAudioController = {}
FieldAudioController.__index = FieldAudioController

---@class FieldAudioController.RuntimeMap
---@field fieldData table<string, unknown>

---@class FieldAudioControllerPendingMusicPolicy
---@field sourceMusicId integer
---@field destinationMusicId integer
---@field target integer|nil
---@field durationFrames integer

---@param opts FieldAudioControllerOptions
---@return FieldAudioController
function FieldAudioController.new(opts)
  assert(
    opts
      and opts.sound
      and opts.provider
      and opts.eventState
      and opts.fieldPosition
      and opts.dayNight
      and opts.fieldDataForMap,
    "FieldAudioController requires sound, provider, eventState, fieldPosition, dayNight, and fieldDataForMap"
  )
  assert(type(opts.fieldPosition) == "function", "fieldPosition must be a function")
  return setmetatable({
    _sound = opts.sound,
    _provider = opts.provider,
    _eventState = opts.eventState,
    _fieldPosition = opts.fieldPosition,
    _dayNight = opts.dayNight,
    _fieldDataForMap = opts.fieldDataForMap,
    _currentMap = nil,
    _fieldMusic = nil,
    _musicOverride = nil,
    _environment = nil,
    _pendingFieldMusicPolicy = nil,
    _policySuspendedBy = nil,
    _predictionEpoch = 0,
    _predictedBankIds = {},
    _prewarmMemo = {},
    _prewarmMemoOrder = {},
  }, FieldAudioController)
end

-- Claims the automatic field-music policy for one presented battle
-- lifetime. Suspending deactivates an already playing field soundplate
-- once and prevents subsequent automatic soundplate selection and map
-- music replacement; it never alters the persisted override and never
-- stops the sound-frame pump. Map installation still updates the current
-- map and field-music metadata. Explicit battle and recovery playback
-- (play, stop, playMusic, fades) stays live throughout the hold.
---@param ownerToken unknown non-nil claim identity for the launch lifetime
function FieldAudioController:suspendFieldPolicy(ownerToken)
  assert(ownerToken ~= nil, "field policy suspension requires its owner token")
  local holder = self._policySuspendedBy
  if holder ~= nil then
    assert(holder == ownerToken, "field policy is already suspended by another owner")
    return
  end
  self:_deactivateSoundplate()
  self._policySuspendedBy = ownerToken
end

-- Releases a policy hold to its matching owner. A stale token does
-- nothing. With restoreMusic set, the current field policy is restored
-- once through the existing play/stop facade (only when the effective
-- track differs) followed by the normal soundplate update; without it
-- the hold clears silently so a recovery-owned music decision stands.
---@param ownerToken unknown claim identity from suspendFieldPolicy
---@param restoreMusic boolean true to restore the current field policy once
function FieldAudioController:resumeFieldPolicy(ownerToken, restoreMusic)
  if ownerToken == nil or self._policySuspendedBy ~= ownerToken then
    return
  end
  self._policySuspendedBy = nil
  if restoreMusic ~= true then
    return
  end
  local effective = self:effectiveMusic()
  local current = self._sound:currentMusic()
  if effective == nil then
    if current ~= nil then
      self._sound:stopMusic()
    end
  elseif effective ~= current then
    if current ~= nil then
      self._sound:stopMusic()
    end
    self._sound:playMusic(effective)
  end
  self:updateField()
end

-- Returns the map-header music reference: day/night selection + flag-based override.
-- Does NOT apply persisted overrides (those are part of effectiveMusic).
-- Resolves string symbols to numeric IDs using the provider.
-- @param fieldData optional field data; if omitted, uses current map's data
---@param fieldData table<string, unknown>?
---@return integer|nil
function FieldAudioController:mapHeaderMusic(fieldData)
  if fieldData == nil then
    if self._currentMap == nil then
      return nil
    end
    fieldData = self._currentMap.fieldData
  end
  if fieldData == nil or fieldData.music == nil then
    return nil
  end

  -- Start with day/night selection
  local dayNight = self._dayNight()
  local music = fieldData.music
  local sequence = music[dayNight]

  -- Apply flag-based map overrides in source order
  if music.flagOverrides ~= nil then
    for _, override in ipairs(music.flagOverrides) do
      if self._eventState:isFlagSet(override.flagId) then
        sequence = override.sequence
        break
      end
    end
  end

  -- Resolve string symbol to numeric ID
  if sequence ~= nil and type(sequence) == "string" then
    sequence = self._provider:sequence(sequence).id
  end

  return sequence
end

-- Loads a prepared map's selected music metadata without changing playback state.
-- It also publishes one prediction round for the map's reachable audio banks
-- (day/night alternates, flag and traversal overrides, soundplates): the
-- epoch owns soft background demand only, and the sounding music, radio,
-- fades, and cries keep their hard references regardless of the round.
---@param runtimeMap FieldAudioController.RuntimeMap
function FieldAudioController:prewarmMapMusic(runtimeMap)
  local reference = self:mapHeaderMusic(assert(runtimeMap.fieldData))
  if reference == nil then
    return
  end
  local sequence = self._provider:sequence(reference)
  self._provider:bank(sequence.bankId)
  self:_warmPredictedBanks(assert(runtimeMap.fieldData))
end

-- The current prediction round: a monotonically increasing soft-demand
-- identity. Every prewarm or override transition publishes a new round;
-- background deliveries from superseded rounds never publish.
---@return integer
function FieldAudioController:predictionEpoch()
  return self._predictionEpoch
end

-- Joins one field record's map-derived banks with published script-audio
-- sequence symbols into one distinct bank set in stable ascending order:
-- the prediction driver's mapper over published metadata. Unknown
-- references fail loudly; near-map callers isolate that failure per map so
-- one unreadable neighbor never corrupts the current game state.
---@param fieldData table<string, unknown>
---@param scriptSequences string[]? published transitive script-audio symbols
---@return integer[]
function FieldAudioController:predictedBanksFor(fieldData, scriptSequences)
  local seen = {} ---@type table<integer, boolean>
  local ordered = {} ---@type integer[]
  local function note(bankId)
    if not seen[bankId] then
      seen[bankId] = true
      ordered[#ordered + 1] = bankId
    end
  end
  for _, bankId in ipairs(self:_collectPredictedBankIds(fieldData)) do
    note(bankId)
  end
  if type(scriptSequences) == "table" then
    for _, symbol in ipairs(scriptSequences) do
      note(self:_predictedBankId(symbol))
    end
  end
  table.sort(ordered)
  return ordered
end

-- The content-addressed sample keys of one audio bank in closure order,
-- for current-first admission accounting. A malformed closure fails loudly.
---@param bankId integer
---@return string[]
function FieldAudioController:bankSampleKeys(bankId)
  local bank = self._provider:bank(bankId)
  local keys = AudioBank.sampleKeys(bank)
  if keys == nil then
    error("no readable sample closure for audio bank " .. tostring(bankId), 0)
  end
  return keys
end

-- Warms an explicit bank set through the provider without touching
-- playback: the driver's current-first/near-second admission path.
---@param bankIds integer[]
function FieldAudioController:prewarmAudioBanks(bankIds)
  if type(self._provider.prewarmBank) ~= "function" then
    return
  end
  for _, bankId in ipairs(bankIds) do
    self._provider:prewarmBank(bankId)
  end
end

-- Adopts already-ready background sample payloads without blocking.
---@return integer adopted count
function FieldAudioController:drainBackgroundSamples()
  if type(self._provider.drainReadySamples) ~= "function" then
    return 0
  end
  return self._provider:drainReadySamples()
end

-- Trims idle samples oldest-first, shielding the keep set and every live
-- voice. Reports the evicted count; adverse budget overflow stays visible
-- in the provider census instead of cutting audio.
---@param keepKeys string[]|nil current-first protection priority
---@return integer
function FieldAudioController:trimIdleSamples(keepKeys)
  return self._provider:trim(keepKeys)
end

-- Drops background sample interest outside the current predicted set.
---@param predictedSet table<string, boolean>
function FieldAudioController:cancelUnpredictedSamples(predictedSet)
  if type(self._provider.cancelUnpredicted) ~= "function" then
    return
  end
  self._provider:cancelUnpredicted(predictedSet)
end

-- The reachable audio bank ids of the current prediction round, in stable
-- ascending order. A read-only copy: callers must not mutate the round.
---@return integer[]
function FieldAudioController:predictedBankIds()
  local copy = {} ---@type integer[]
  for index, bankId in ipairs(self._predictedBankIds) do
    copy[index] = bankId
  end
  return copy
end

-- Resolves one sequence reference to its bank id through the published
-- audio metadata. An unknown reference fails loudly like any other
-- missing published asset; prediction never synthesizes a bank.
---@param reference integer|string
---@return integer
function FieldAudioController:_predictedBankId(reference)
  local sequence
  if type(reference) == "number" then
    sequence = self._provider:sequence(reference)
  else
    sequence = self._provider:sequence(reference --[[@as string]])
  end
  local bankId = assert(sequence.bankId, "published audio sequence carries its bank identity")
  assert(type(bankId) == "number", "published audio bank identity is numeric")
  return bankId
end

-- Collects the distinct reachable bank ids for one field record, mirroring
-- the producer closure semantics: day and night alternates, flag and
-- traversal overrides, and soundplates. Script-reachable sequences join
-- through the prediction driver, not here.
---@param fieldData table<string, unknown>
---@return integer[]
function FieldAudioController:_collectPredictedBankIds(fieldData)
  local seen = {} ---@type table<integer, boolean>
  local ordered = {} ---@type integer[]
  local function note(reference)
    if reference == nil then
      return
    end
    local bankId = self:_predictedBankId(reference --[[@as integer|string]])
    if not seen[bankId] then
      seen[bankId] = true
      ordered[#ordered + 1] = bankId
    end
  end
  local music = fieldData.music --[[@as table<string, unknown>]]
  if type(music) == "table" then
    note(music.day)
    note(music.night)
    for _, overrides in ipairs({ music.flagOverrides, music.traversalOverrides }) do
      if type(overrides) == "table" then
        for _, override in
          ipairs(overrides --[[@as table[] ]])
        do
          if type(override) == "table" then
            note(override.sequence)
          end
        end
      end
    end
  end
  local soundplates = fieldData.soundplates --[[@as table[]?]]
  if type(soundplates) == "table" then
    for _, plate in ipairs(soundplates) do
      if type(plate) == "table" then
        note(plate.sequence)
      end
    end
  end
  table.sort(ordered)
  return ordered
end

-- Memoizes the reachable-bank walk by record content, day/night band, and
-- flag states. The memo stays bounded; warming itself is idempotent, so a
-- memoized round only skips the metadata walk, never the demand.
---@param fieldData table<string, unknown>
---@return integer[]
function FieldAudioController:_memoizedPredictedBankIds(fieldData)
  local music = fieldData.music --[[@as table<string, unknown>]]
  local parts = {} ---@type string[]
  parts[#parts + 1] = "daynight=" .. tostring(self._dayNight())
  if type(music) == "table" then
    parts[#parts + 1] = "day=" .. tostring(music.day)
    parts[#parts + 1] = "night=" .. tostring(music.night)
    -- Flag overrides resolve exactly like the header policy; traversal
    -- overrides carry their own condition shape (unlessFlagId, possibly
    -- absent for an unconditional rule), which the header policy never
    -- consults, so only numeric conditions are queried here.
    if type(music.flagOverrides) == "table" then
      for _, override in
        ipairs(music.flagOverrides --[[@as table[] ]])
      do
        if type(override) == "table" then
          local set = self._eventState:isFlagSet(override.flagId) == true
          parts[#parts + 1] = tostring(override.sequence) .. (set and ":1" or ":0")
        end
      end
    end
    if type(music.traversalOverrides) == "table" then
      for _, override in
        ipairs(music.traversalOverrides --[[@as table[] ]])
      do
        if type(override) == "table" then
          local marker = tostring(override.sequence)
          if type(override.unlessFlagId) == "number" then
            local set = self._eventState:isFlagSet(override.unlessFlagId) == true
            marker = marker .. (set and ":1" or ":0")
          end
          parts[#parts + 1] = "traversal=" .. marker
        end
      end
    end
  end
  local soundplates = fieldData.soundplates --[[@as table[]?]]
  if type(soundplates) == "table" then
    for _, plate in ipairs(soundplates) do
      if type(plate) == "table" then
        parts[#parts + 1] = "plate=" .. tostring(plate.sequence)
      end
    end
  end
  local memoKey = table.concat(parts, "|")
  local memoized = self._prewarmMemo[memoKey]
  if memoized ~= nil then
    return memoized
  end
  local bankIds = self:_collectPredictedBankIds(fieldData)
  self._prewarmMemo[memoKey] = bankIds
  self._prewarmMemoOrder[#self._prewarmMemoOrder + 1] = memoKey
  while #self._prewarmMemoOrder > 16 do
    local oldest = table.remove(self._prewarmMemoOrder, 1)
    self._prewarmMemo[oldest] = nil
  end
  return bankIds
end

-- Publishes one prediction round for a field record and warms its banks
-- through the provider without touching playback. Providers without a bank
-- prewarm keep the metadata-only behavior, so headless policy composition
-- never decodes a sample.
---@param fieldData table<string, unknown>
function FieldAudioController:_warmPredictedBanks(fieldData)
  if type(self._provider.prewarmBank) ~= "function" then
    return
  end
  local bankIds = self:_memoizedPredictedBankIds(fieldData)
  self._predictionEpoch = self._predictionEpoch + 1
  self._predictedBankIds = bankIds
  for _, bankId in ipairs(bankIds) do
    self._provider:prewarmBank(bankId)
  end
end

-- Publishes one prediction round for a field record as background interest
-- only: missing samples enqueue through the shared queue and nothing
-- decodes synchronously, so map entry, zone transitions, and overrides
-- never pay a decode on the audio path. Providers without background
-- prewarm keep the metadata-only behavior.
---@param fieldData table<string, unknown>
function FieldAudioController:_prefetchPredictedBanks(fieldData)
  if type(self._provider.prewarmBankBackground) ~= "function" then
    return
  end
  local bankIds = self:_memoizedPredictedBankIds(fieldData)
  self._predictionEpoch = self._predictionEpoch + 1
  self._predictedBankIds = bankIds
  for _, bankId in ipairs(bankIds) do
    self._provider:prewarmBankBackground(bankId)
  end
end

-- Returns the effective field music: persisted override > map-header
---@return integer|nil
function FieldAudioController:effectiveMusic()
  if self._musicOverride ~= nil then
    return self._musicOverride
  end
  return self:mapHeaderMusic()
end

-- Plays the map-header music (not effective music; ignores persisted override).
-- This is the source ResetBGM behavior.
function FieldAudioController:resetMusic()
  self._pendingFieldMusicPolicy = nil
  local reference = self:mapHeaderMusic()
  if reference == nil then
    self._sound:stopMusic()
    return
  end
  self._sound:playMusic(reference)
end

-- Sets the persisted field-music override (converts string to numeric ID)
---@param sequenceRef integer|string|nil
function FieldAudioController:setMusicOverride(sequenceRef)
  if sequenceRef ~= nil and type(sequenceRef) == "string" then
    sequenceRef = self._provider:sequence(sequenceRef --[[@as string]]).id
  end
  ---@cast sequenceRef integer|nil
  self._musicOverride = sequenceRef
  -- A new round warms the override bank when a map is already installed;
  -- playback itself still changes only through the entry paths.
  if sequenceRef ~= nil and self._currentMap ~= nil and self._currentMap.fieldData ~= nil then
    self:_prefetchPredictedBanks(self._currentMap.fieldData)
  end
end

-- Clears the persisted override
function FieldAudioController:clearMusicOverride()
  self._musicOverride = nil
end

-- Returns the current persisted override (numeric ID)
---@return integer|nil
function FieldAudioController:musicOverride()
  return self._musicOverride
end

-- Enters a map and optionally plays the effective music
-- Options: { clearMusicOverride, restoredMusicOverride, play }
---@param runtimeMap unknown
---@param options table<string, unknown>|nil
function FieldAudioController:enterMap(runtimeMap, options)
  options = options or {}

  -- The effective music before this entry installs its map, so step 5 can
  -- tell an unchanged field behind surviving radio from an explicit change.
  local previousEffective = self:effectiveMusic()

  -- 1. Deactivate source environment BEFORE replacing state, using old identities
  if self._environment ~= nil then
    local oldSequence = self._environment.sequence
    local oldFieldMusic = self._fieldMusic
    self._sound:stopSequenceWithFade(oldSequence, 10)
    if oldFieldMusic ~= nil then
      self._sound:moveSequenceVolume(oldFieldMusic, 128, 15)
    end
    self._environment = nil
  end

  -- 2. Install new current map
  self._currentMap = runtimeMap

  -- 3. Clear or restore persisted music override
  if options.clearMusicOverride then
    self._musicOverride = nil
  elseif options.restoredMusicOverride ~= nil then
    local override = options.restoredMusicOverride
    if type(override) == "string" then
      override = self._provider:sequence(override --[[@as string]]).id
    end
    ---@cast override integer|nil
    self._musicOverride = override
  end

  -- 4. Compute/store new base _fieldMusic from new map-header policy
  self._fieldMusic = self:mapHeaderMusic()

  -- 5. When play=true, play new effective BGM before ordinary soundplate selection.
  -- A presented battle hold suppresses this automatic playback while map
  -- installation above still lands; explicit battle/recovery playback stays live.
  -- A surviving radio on unchanged music suppresses the replacement too:
  -- the BGM branch would otherwise restart the field music behind it. An
  -- explicit music change still replaces through the BGM branch below.
  if options.play and self._policySuspendedBy ~= nil then
    self:_prefetchPredictedBanks(runtimeMap.fieldData)
    return
  end
  if options.play then
    local effective = self:effectiveMusic()
    local radioLatched = self._sound:currentRadioSequence() ~= nil
    local musicChanged = effective ~= previousEffective
    local radioSurvives = radioLatched and effective ~= nil and not musicChanged
    if not radioSurvives then
      if effective == nil then
        self._sound:stopMusic()
      elseif (musicChanged and radioLatched) or effective ~= self._sound:currentMusic() then
        -- A changed entry takes the BGM branch even when the destination
        -- already matches the reference: the branch stops a radio latched
        -- to another sequence. Without radio the reference comparison alone
        -- decides, so ordinary entries keep their behavior.
        self._sound:playMusic(effective)
      end
    end
  end

  -- 6. Ordinary soundplate selection on map entry, immediately after BGM (the
  -- source FieldMap_Init ordering for initial environmental audio).
  if options.play then
    local fieldX, fieldZ = self._fieldPosition()
    assert(type(fieldX) == "number" and type(fieldZ) == "number", "fieldPosition must return fieldX, fieldZ")
    self:_processSelection(fieldX, fieldZ)
  end
  -- 7. Soft prediction round for the installed map. Playback above is final;
  -- warming only enrolls background demand for the reachable banks.
  if runtimeMap.fieldData ~= nil then
    self:_prefetchPredictedBanks(runtimeMap.fieldData)
  end
end

---@param runtimeMap FieldAudioController.RuntimeMap
function FieldAudioController:enterZone(runtimeMap)
  -- A presented battle hold still installs the destination metadata below
  -- while its automatic replacement stays suppressed; the persisted
  -- override is left for the hold owner to manage.
  if self._policySuspendedBy ~= nil then
    self._currentMap = runtimeMap
    self._fieldMusic = self:mapHeaderMusic(runtimeMap.fieldData)
    self:_prefetchPredictedBanks(runtimeMap.fieldData)
    return
  end
  local currentMusic = self._sound:currentMusic()
  local destinationMusic = self:mapHeaderMusic(runtimeMap.fieldData)
  local changedMusic = currentMusic ~= nil and destinationMusic ~= nil and currentMusic ~= destinationMusic

  if changedMusic then
    local sourceMusicId = assert(currentMusic)
    local destinationMusicId = assert(destinationMusic)
    self._pendingFieldMusicPolicy = {
      sourceMusicId = sourceMusicId,
      destinationMusicId = destinationMusicId,
      target = 128,
      durationFrames = 15,
    }
  else
    self._pendingFieldMusicPolicy = nil
  end

  self:_deactivateSoundplate()
  self._musicOverride = nil
  self._currentMap = runtimeMap
  self._fieldMusic = destinationMusic
  local effective = self:effectiveMusic()
  if effective == nil then
    self._pendingFieldMusicPolicy = nil
    self._sound:stopMusic()
    self:updateField()
  elseif currentMusic == nil then
    self._sound:queueMusicReplacement(effective, 60)
    self:updateField()
  elseif effective == currentMusic then
    self:updateField()
  else
    self:updateField()
    self._sound:queueMusicReplacement(effective, 60)
  end
  self:_prefetchPredictedBanks(runtimeMap.fieldData)
end

-- Pre-fade current BGM if destination map-header differs. When the destination
-- field record is not yet available (sparse cache still compiling it), skip the
-- cosmetic pre-fade; the commit path establishes destination music authoritatively.
---@param destinationMapId integer|string
function FieldAudioController:beginWarp(destinationMapId)
  local destData = self._fieldDataForMap(destinationMapId)
  if destData == nil then
    -- Not-yet-compiled destination record: skip the cosmetic pre-fade;
    -- the commit path establishes destination music authoritatively.
    -- Corrupt records still fail loudly below.
    return
  end
  if type(destData) ~= "table" then
    error("missing field data for destination " .. tostring(destinationMapId))
  end
  if destData.schema ~= FieldMapDataCache.FIELD_SCHEMA then
    error("field data schema mismatch for destination " .. tostring(destinationMapId))
  end
  if destData.mapId == nil then
    error("field data missing mapId for destination " .. tostring(destinationMapId))
  end
  if type(destinationMapId) == "number" and destData.mapId ~= destinationMapId then
    error("field data mapId mismatch for destination " .. tostring(destinationMapId))
  end

  -- Get destination map-header music using same policy as map entry
  local destFieldData = { music = destData.music, soundplates = destData.soundplates }
  local destMusic = self:mapHeaderMusic(destFieldData)

  -- If current BGM differs, start fade to 0 over 40 sound frames
  local currentMusic = self._sound:currentMusic()
  if destMusic ~= currentMusic then
    if currentMusic ~= nil and not self._sound:isMusicFadeActive() then
      self._sound:fadeMusicOut({ target = 0, durationTicks = 40 })
    end
  end
end

-- Internal: process soundplate selection for current coords
---@param fieldX integer
---@param fieldZ integer
function FieldAudioController:_processSelection(fieldX, fieldZ)
  if self._currentMap == nil or self._currentMap.fieldData == nil then
    return
  end

  local fieldData = self._currentMap.fieldData
  if fieldData.soundplates == nil or #fieldData.soundplates == 0 then
    if self._environment ~= nil then
      self:_deactivateSoundplate()
    end
    if self._pendingFieldMusicPolicy ~= nil then
      self._pendingFieldMusicPolicy.target = nil
    end
    return
  end

  local localX = fieldX % 32
  local localZ = fieldZ % 32

  -- Iterate soundplates in source order, keep last matching
  local selectedPlate = nil
  for _, plate in ipairs(fieldData.soundplates) do
    if localX >= plate.x and localX <= plate.xBounds and localZ >= plate.z and localZ <= plate.zBounds then
      selectedPlate = plate
    end
  end

  if selectedPlate ~= nil then
    -- Test disabled flag (no fallback if disabled)
    if selectedPlate.disabledWhenFlag ~= nil and self._eventState:isFlagSet(selectedPlate.disabledWhenFlag) then
      if self._pendingFieldMusicPolicy ~= nil then
        self._pendingFieldMusicPolicy.target = nil
      end
      return
    end

    -- Resolve selected sequence id
    local seqRecord = self._provider:sequence(selectedPlate.sequence)
    local seqId = seqRecord.id

    local shouldStart = self._environment == nil or self._environment.sequence ~= seqId
    if shouldStart then
      if selectedPlate.useFieldMusicBank then
        assert(self._fieldMusic ~= nil, "donor-bank soundplate requires base field music")
        local fieldBgm = self._provider:sequence(self._fieldMusic)
        self._sound:playWithBankOverride(selectedPlate.sequence, fieldBgm.bankId)
      else
        self._sound:play(selectedPlate.sequence)
      end
    end

    self._environment = { sequence = seqId }

    if selectedPlate.bgmTarget ~= nil and self._fieldMusic ~= nil then
      self:_applyOrDeferFieldMusicTarget(selectedPlate.bgmTarget, 15)
    elseif self._pendingFieldMusicPolicy ~= nil then
      self._pendingFieldMusicPolicy.target = nil
    end
    if selectedPlate.ambientTarget ~= nil then
      self._sound:moveSequenceVolume(selectedPlate.sequence, selectedPlate.ambientTarget, 5)
    end
  else
    if self._environment ~= nil then
      self:_deactivateSoundplate()
    end
    if self._pendingFieldMusicPolicy ~= nil then
      self._pendingFieldMusicPolicy.target = nil
    end
  end
end

-- Step-completion soundplate selection (the ordinary path). A presented
-- battle hold suppresses this automatic selection; the sound-frame pump
-- and explicit playback continue through their own owners.
function FieldAudioController:updateField()
  if self._policySuspendedBy ~= nil then
    return
  end
  if self._currentMap == nil or self._currentMap.fieldData == nil then
    return
  end
  local fieldX, fieldZ = self._fieldPosition()
  assert(type(fieldX) == "number" and type(fieldZ) == "number", "fieldPosition must return fieldX, fieldZ")
  self:_processSelection(fieldX, fieldZ)
end

-- Forced soundplate processing for opcode 726: clear identity and process immediately.
function FieldAudioController:processSoundplate()
  self._environment = nil
  if self._currentMap == nil or self._currentMap.fieldData == nil then
    return
  end
  local fieldX, fieldZ = self._fieldPosition()
  assert(type(fieldX) == "number" and type(fieldZ) == "number", "fieldPosition must return fieldX, fieldZ")
  self:_processSelection(fieldX, fieldZ)
end

-- Deactivates the current soundplate: fades environment and restores BGM
function FieldAudioController:_deactivateSoundplate()
  if self._environment == nil then
    return
  end

  self._sound:stopSequenceWithFade(self._environment.sequence, 10)

  if self._fieldMusic ~= nil then
    self:_applyOrDeferFieldMusicTarget(128, 15)
  end

  self._environment = nil
end

-- Applies a soundplate BGM target immediately, or records it while a seamless
-- map replacement still owns the source player's music ramp.
---@param target integer
---@param durationFrames integer
function FieldAudioController:_applyOrDeferFieldMusicTarget(target, durationFrames)
  assert(target >= 0 and target <= 128, "volume target must be an integer in 0..128")
  assert(durationFrames > 0 and durationFrames % 1 == 0, "fader ramp duration must be a positive integer")

  local pending = self._pendingFieldMusicPolicy
  if pending ~= nil then
    pending.target = target
    pending.durationFrames = durationFrames
    return
  end

  if self._fieldMusic ~= nil then
    self._sound:moveSequenceVolume(self._fieldMusic, target, durationFrames)
  end
end

-- Delegates to GameSound:updateSoundFrame() for one ordinary source frame.
function FieldAudioController:updateSoundFrame()
  self._sound:updateSoundFrame()
  local pending = self._pendingFieldMusicPolicy
  if pending ~= nil then
    local current = self._sound:currentMusic()
    if current ~= nil and current == pending.destinationMusicId then
      self._pendingFieldMusicPolicy = nil
      if pending.target ~= nil then
        self._sound:moveSequenceVolume(current, pending.target, pending.durationFrames)
      end
    elseif current ~= pending.sourceMusicId or not self._sound:isMusicFadeActive() then
      self._pendingFieldMusicPolicy = nil
    end
  end
end

-- Script facade delegation to GameSound

---@param idOrSymbol integer|string effect sequence reference under staging
---@return boolean started true once the effect voice starts
function FieldAudioController:play(idOrSymbol)
  return self._sound:play(idOrSymbol)
end

---@param idOrSymbol integer|string effect sequence reference under staging
---@param pan integer signed NNS track-pan offset
---@return boolean started true when the effect voice starts
function FieldAudioController:playPanned(idOrSymbol, pan)
  return self._sound:playPanned(idOrSymbol, pan)
end

---@param idOrSymbol integer|string effect sequence reference under release
---@return boolean stopped true once the stop reaches the engine player
function FieldAudioController:stop(idOrSymbol)
  return self._sound:stop(idOrSymbol)
end

function FieldAudioController:isEffectPlaying(idOrSymbol)
  return self._sound:isEffectPlaying(idOrSymbol)
end

function FieldAudioController:isEffectWaitComplete(idOrSymbol)
  return self._sound:isEffectWaitComplete(idOrSymbol)
end

---@param idOrSymbol integer|string battle-music sequence reference under staging
---@return boolean started true once the battle-music voice starts
function FieldAudioController:playMusic(idOrSymbol)
  self._pendingFieldMusicPolicy = nil
  if self._policySuspendedBy ~= nil and self._sound:currentMusic() ~= nil then
    self._sound:stopMusic()
  end
  return self._sound:playMusic(idOrSymbol)
end

---@return boolean stopped true once the music stop reaches the engine player
function FieldAudioController:stopMusic()
  self._pendingFieldMusicPolicy = nil
  return self._sound:stopMusic()
end

function FieldAudioController:currentMusic()
  return self._sound:currentMusic()
end

function FieldAudioController:currentMapId()
  return self._currentMap and self._currentMap.mapId or nil
end

---@param idOrSymbol integer|string fanfare sequence reference under staging
---@return boolean started true once the fanfare voice starts
function FieldAudioController:playFanfare(idOrSymbol)
  return self._sound:playFanfare(idOrSymbol)
end

function FieldAudioController:isFanfarePlaying()
  return self._sound:isFanfarePlaying()
end

function FieldAudioController:fadeMusicOut(spec)
  self._sound:fadeMusicOut(spec)
end

function FieldAudioController:fadeMusicIn(spec)
  self._pendingFieldMusicPolicy = nil
  self._sound:fadeMusicIn(spec)
end

function FieldAudioController:isMusicFadeActive()
  return self._sound:isMusicFadeActive()
end

function FieldAudioController:temporaryMusic(idOrSymbol)
  self._pendingFieldMusicPolicy = nil
  self._sound:temporaryMusic(idOrSymbol)
end

---@param species integer numeric species identity behind the cry voice
---@param pattern integer cry pattern behind the voice family
---@param form integer? the mon's form; nil plays the species bank
---@param mode integer? Chatot/default-cry routing mode
---@param pan integer? signed NNS track-pan offset
---@param volume integer? initial primary player level
---@param pitch integer? signed NNS track-pitch offset
---@return boolean started true once the cry voice starts
function FieldAudioController:playCry(species, pattern, form, mode, pan, volume, pitch)
  return self._sound:playCry(species, pattern, form, mode, pan, volume, pitch)
end

function FieldAudioController:isCryFinished()
  return self._sound:isCryFinished()
end

-- Radio facade delegation to GameSound. The radio handle and latch stay
-- owned by the audio runtime: interface teardown never releases them, only
-- the explicit stop paths do.

function FieldAudioController:playRadio(sequenceKey)
  return self._sound:playRadio(sequenceKey)
end

function FieldAudioController:stopRadio(fadeFrames)
  self._sound:stopRadio(fadeFrames)
end

function FieldAudioController:pauseRadio()
  self._sound:pauseRadio()
end

function FieldAudioController:resumeRadio()
  self._sound:resumeRadio()
end

function FieldAudioController:currentRadioSequence()
  return self._sound:currentRadioSequence()
end

function FieldAudioController:radioIsPlaying()
  return self._sound:radioIsPlaying()
end

-- Runs the radio interface teardown: closing during ordinary music destroys
-- only the interface state and leaves the surviving radio alive, while an
-- untuned, jingle, or commercial exit fades the recorded BGM handle,
-- clears the radio with its own fade tail, and restores the given field
-- music exactly once through the music service. All three effects land
-- synchronously in source order; the programmed fades keep advancing on
-- the semantic sound timeline, so the transition is complete on return.
---@param args { tuned: boolean?, kind: string?, mapMusic: integer|string }
function FieldAudioController:finishRadioUi(args)
  assert(args ~= nil, "radio interface teardown requires its exit description")
  assert(args.mapMusic ~= nil, "radio interface teardown requires the field music to restore")
  local silent = args.tuned ~= true or args.kind == "jingle" or args.kind == "commercial"
  if not silent then
    return
  end
  self._sound:fadeMusicOut({ target = 0, durationTicks = 4 })
  self._sound:stopRadio(4)
  self:playMusic(args.mapMusic)
end

-- True once the interface teardown transition above has landed. Teardown
-- effects are synchronous, so this holds on return; it exists so callers
-- can poll the transition the same way they poll any audio wait.
---@return boolean
function FieldAudioController:isRadioUiTransitionComplete()
  return true
end

-- Internal field-policy helpers (not script-facing)

function FieldAudioController:moveSequenceVolume(idOrSymbol, target, durationFrames)
  self._sound:moveSequenceVolume(idOrSymbol, target, durationFrames)
end

function FieldAudioController:stopSequenceWithFade(idOrSymbol, durationFrames)
  self._sound:stopSequenceWithFade(idOrSymbol, durationFrames)
end

return FieldAudioController
