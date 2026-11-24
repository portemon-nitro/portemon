-- Bounded ROM-independent launcher cue sources.

local LauncherAssets = require("app.src.launcher.LauncherAssets")

local LauncherAudio = {}
LauncherAudio.__index = LauncherAudio

---@class LauncherAudio
---@field sources table<string, love.Source>
---@field voices string[]
---@field disposed boolean
---@field unavailable boolean
---@field bootFade { elapsed: number, duration: number }?
---@field play fun(self: LauncherAudio, cue: "boot"|"focus"|"confirm"|"back"|"error")
---@field fadeBoot fun(self: LauncherAudio, seconds: number)
---@field update fun(self: LauncherAudio, dt: number)
---@field dispose fun(self: LauncherAudio)

local CUES = { "boot", "focus", "confirm", "back", "error" }
local MAX_VOICES = 4

local function pathFor(cue)
  return "assets/audio/launcher/" .. cue .. ".ogg"
end

---@return LauncherAudio
local function silent()
  return setmetatable({ sources = {}, voices = {}, disposed = false, unavailable = true }, LauncherAudio)
end

---@return LauncherAudio
function LauncherAudio.new()
  local canDecode = type(love.sound) == "table" and type(love.sound.newSoundData) == "function"
  local audio = love.audio
  if type(audio) ~= "table" or type(audio.newSource) ~= "function" then
    for _, cue in ipairs(CUES) do
      local path = pathFor(cue)
      local fileData = LauncherAssets.read(path)
      if fileData == nil then
        error("required launcher audio asset is missing: " .. path, 0)
      end
      local decodedOk, decoded = true, nil
      if canDecode then
        decodedOk, decoded = pcall(love.sound.newSoundData, fileData)
      end
      fileData:release()
      if not decodedOk then
        error("required launcher audio asset is invalid: " .. path .. ": " .. tostring(decoded), 0)
      end
      if decoded ~= nil then
        decoded:release()
      end
    end
    return silent()
  end
  local self = silent()
  for _, cue in ipairs(CUES) do
    local path = pathFor(cue)
    local readOk, fileData = pcall(LauncherAssets.read, path)
    if not readOk then
      self:dispose()
      error(fileData, 0)
    end
    if fileData == nil then
      self:dispose()
      error("required launcher audio asset is missing: " .. path, 0)
    end
    local decodedOk, decoded = true, nil
    if canDecode then
      decodedOk, decoded = pcall(love.sound.newSoundData, fileData)
    end
    if not decodedOk then
      fileData:release()
      self:dispose()
      error("required launcher audio asset is invalid: " .. path .. ": " .. tostring(decoded), 0)
    end
    if decoded ~= nil then
      decoded:release()
    end
    local ok, source = pcall(audio.newSource, fileData, "static")
    fileData:release()
    if not ok then
      self:dispose()
      return silent()
    end
    self.sources[cue] = source
  end
  self.unavailable = false
  return self
end

function LauncherAudio:_stop(cue)
  local source = self.sources[cue]
  if source ~= nil then
    source:stop()
    source:setVolume(1)
  end
  for index = #self.voices, 1, -1 do
    if self.voices[index] == cue then
      table.remove(self.voices, index)
    end
  end
end

---@param cue "boot"|"focus"|"confirm"|"back"|"error"
function LauncherAudio:play(cue)
  if cue ~= "boot" and cue ~= "focus" and cue ~= "confirm" and cue ~= "back" and cue ~= "error" then
    return
  end
  if self.disposed or self.unavailable or self.sources[cue] == nil then
    return
  end
  self:_stop(cue)
  while #self.voices >= MAX_VOICES do
    self:_stop(table.remove(self.voices, 1))
  end
  self.voices[#self.voices + 1] = cue
  self.sources[cue]:play()
end

---@param seconds number
function LauncherAudio:fadeBoot(seconds)
  if self.disposed or self.unavailable then
    return
  end
  assert(type(seconds) == "number" and seconds >= 0, "boot fade duration must be non-negative")
  local source = self.sources.boot
  if source == nil or not source:isPlaying() then
    return
  end
  source:setVolume(1)
  self.bootFade = { elapsed = 0, duration = seconds }
end

---@param dt number
function LauncherAudio:update(dt)
  if self.disposed or self.bootFade == nil or self.unavailable then
    return
  end
  local fade = self.bootFade
  fade.elapsed = fade.elapsed + dt
  local remaining = math.max(0, 1 - fade.elapsed / math.max(fade.duration, 1e-9))
  self.sources.boot:setVolume(remaining)
  if remaining <= 0 then
    self:_stop("boot")
    self.bootFade = nil
  end
end

function LauncherAudio:dispose()
  if self.disposed then
    return
  end
  self.disposed = true
  self.bootFade = nil
  self.voices = {}
  local sources = self.sources
  self.sources = {}
  for _, cue in ipairs(CUES) do
    if sources[cue] ~= nil then
      sources[cue]:release()
    end
  end
end

return LauncherAudio
