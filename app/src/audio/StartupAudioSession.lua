-- Owns the app's selected-edition title and menu audio lifetime.

local CacheFs = require("libs.storage.src.CacheFs")
local HgssGame = require("game.hgss.src.HgssGame")

---@class StartupAudioComposition
---@field sound table<string, function>
---@field sink table<string, function>|nil

---@class StartupAudioSession
---@field versionId string
---@field titleRecord { crySpeciesId: integer }?
---@field sound table<string, function>|nil
---@field sink table<string, function>|nil
---@field accumulator number
---@field fadeTicks integer|nil
---@field titleStarted boolean
---@field skipNotified boolean
---@field fadeStarted boolean
---@field disposed boolean
---@field diagnostic string|nil
local StartupAudioSession = {}
StartupAudioSession.__index = StartupAudioSession

local FRAMES_PER_SECOND = 30
local MAX_SOURCE_TICKS_PER_UPDATE = 8
local TITLE_THEME = "SEQ_GS_POKEMON_THEME"
local MENU_SELECT = "SEQ_SE_DP_SELECT"
local FADE_TICKS = 60

---@param options { versionId: string, cacheFs: CacheFs?, audioComposition: StartupAudioComposition?, titleRecord: { crySpeciesId: integer }? }
---@return StartupAudioSession
function StartupAudioSession.new(options)
  assert(type(options) == "table", "startup audio requires options")
  assert(type(options.versionId) == "string" and options.versionId ~= "", "startup audio requires a version")
  local cacheFs = options.cacheFs
  local titleRecord = options.titleRecord
  local composition = options.audioComposition
  assert(
    titleRecord == nil or (type(titleRecord) == "table" and type(titleRecord.crySpeciesId) == "number"),
    "startup title audio needs its normalized cry species"
  )
  if composition == nil then
    cacheFs = cacheFs or CacheFs.forVersion(options.versionId)
    composition = HgssGame.newStartupAudio({ cacheFs = cacheFs, outputRate = 32768 }) --[[@as StartupAudioComposition]]
  end
  assert(type(composition) == "table" and type(composition.sound) == "table", "startup audio composition is invalid")
  local sound = composition.sound
  assert(
    type(sound.play) == "function"
      and type(sound.playMusic) == "function"
      and type(sound.playCry) == "function"
      and type(sound.fadeMusicOut) == "function"
      and type(sound.stopMusic) == "function"
      and type(sound.updateSoundFrame) == "function",
    "startup audio needs a usable GameSound"
  )
  local sink = composition.sink
  assert(
    sink == nil or (type(sink) == "table" and type(sink.update) == "function" and type(sink.release) == "function")
  )
  return setmetatable({
    versionId = options.versionId,
    titleRecord = titleRecord,
    sound = sound,
    sink = sink,
    accumulator = 0,
    fadeTicks = nil,
    titleStarted = false,
    skipNotified = false,
    fadeStarted = false,
    disposed = false,
    diagnostic = nil,
  }, StartupAudioSession)
end

function StartupAudioSession:beginTitle()
  if self.disposed or self.titleStarted then
    return
  end
  self.titleStarted = true
  self.sound:playMusic(TITLE_THEME)
end

function StartupAudioSession:notifySkip()
  if self.disposed or self.skipNotified then
    return
  end
  self.skipNotified = true
  local titleRecord = assert(self.titleRecord, "title skip needs its normalized audio record")
  self.sound:playCry(titleRecord.crySpeciesId, 0)
end

function StartupAudioSession:beginFade()
  if self.disposed or self.fadeStarted then
    return
  end
  self.fadeStarted = true
  self.fadeTicks = FADE_TICKS
  self.sound:fadeMusicOut({ target = 0, durationTicks = FADE_TICKS })
end

---@param _ string semantic menu action; all currently map to the source menu select effect
function StartupAudioSession:playMenuCue(_)
  if self.disposed then
    return
  end
  self.sound:play(MENU_SELECT)
end

---@param dt number host frame duration in seconds
function StartupAudioSession:update(dt)
  if self.disposed then
    return
  end
  assert(type(dt) == "number" and dt >= 0, "startup audio update needs a non-negative duration")
  self.accumulator = self.accumulator
    + math.min(dt, MAX_SOURCE_TICKS_PER_UPDATE / FRAMES_PER_SECOND) * FRAMES_PER_SECOND
  local ticks = math.min(math.floor(self.accumulator), MAX_SOURCE_TICKS_PER_UPDATE)
  self.accumulator = self.accumulator - ticks
  for _ = 1, ticks do
    self.sound:updateSoundFrame()
    if self.fadeTicks ~= nil then
      self.fadeTicks = self.fadeTicks - 1
      if self.fadeTicks == 0 then
        self.sound:stopMusic()
        self.fadeTicks = nil
      end
    end
  end
  if self.sink ~= nil then
    local ok, failure = pcall(self.sink.update, self.sink)
    if not ok then
      self.diagnostic = tostring(failure)
      local sink = assert(self.sink)
      self.sink = nil
      pcall(sink.release, sink)
    end
  end
end

function StartupAudioSession:dispose()
  if self.disposed then
    return
  end
  self.disposed = true
  local sound, sink = self.sound, self.sink
  self.sound, self.sink = nil, nil
  if sound ~= nil then
    pcall(sound.stopMusic, sound)
  end
  if sink ~= nil then
    pcall(sink.release, sink)
  end
end

return StartupAudioSession
