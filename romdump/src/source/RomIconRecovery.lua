-- One bounded read-only recovery job for a managed cartridge banner. The worker
-- returns only verified identity and encoded PNG data; the caller owns any
-- sidecar publication after rechecking the current installation.

local Errors = require("libs.errors.src.Errors")
local GameVersion = require("romdump.src.source.GameVersion")

local RomIconRecovery = {}

---@class RomIconRecovery.Job
---@field private _thread (table<string, function>|userdata)?
---@field private _outbox (table<string, function>|userdata)?
---@field private _terminal boolean
---@field private _disposed boolean
local Job = {}
Job.__index = Job

local function bootstrap()
  return [[
local developmentPath, versionId, outbox = ...
package.path = developmentPath
pcall(require, "love.thread")
pcall(require, "love.filesystem")
pcall(require, "love.data")
pcall(require, "love.image")
pcall(require, "love.timer")
local Recovery = require("romdump.src.source.RomIconRecovery")
Recovery.run(versionId, outbox)
]]
end

---@param versionId string
---@param outbox table<string, function>|userdata
function RomIconRecovery.run(versionId, outbox)
  local png
  local ok, failure = pcall(function()
    local RomArchive = require("romdump.src.source.RomArchive")
    local romSha1, encoded, iconError = RomArchive.readManagedIcon(versionId)
    if romSha1 == nil then
      outbox:push({ kind = "failed", diagnostic = Errors.format(iconError) })
      return
    end
    png = encoded
    outbox:push({ kind = "ready", romSha1 = romSha1, png = png })
    png = nil
  end)
  if png ~= nil then
    pcall(png.release, png)
  end
  if not ok then
    outbox:push({ kind = "failed", diagnostic = tostring(failure) })
  end
end

---@param packet table<string, unknown>
---@return string diagnostic
local function failedDiagnostic(packet)
  if type(packet.diagnostic) == "string" and packet.diagnostic ~= "" then
    return packet.diagnostic
  end
  return "managed icon recovery failed without a diagnostic"
end

---@return nil|"pending"|"ready"|"failed" state
---@return string? romSha1 or diagnostic
---@return love.FileData? pngFileData
function Job:poll()
  if self._disposed or self._terminal then
    return nil
  end
  local outbox = assert(self._outbox, "managed icon recovery job is disposed")
  local thread = assert(self._thread, "managed icon recovery job is disposed")
  local packet = outbox:pop()
  if packet == nil and not thread:isRunning() then
    packet = outbox:pop()
    if packet == nil then
      self._terminal = true
      local _, threadError = pcall(thread.getError, thread)
      local diagnostic = type(threadError) == "string" and threadError ~= "" and threadError
        or "managed icon recovery worker ended without a result"
      return "failed", diagnostic
    end
  end
  if packet == nil then
    return "pending"
  end
  if type(packet) ~= "table" or packet.kind == "failed" then
    self._terminal = true
    return "failed", failedDiagnostic(type(packet) == "table" and packet or {})
  end
  if packet.kind ~= "ready" or type(packet.romSha1) ~= "string" or type(packet.png) ~= "userdata" then
    if type(packet) == "table" and type(packet.png) == "userdata" then
      local png = packet.png --[[@as love.FileData]]
      pcall(png.release, png)
    end
    self._terminal = true
    return "failed", "managed icon recovery returned an invalid result"
  end
  self._terminal = true
  return "ready", packet.romSha1, packet.png
end

-- Abandon a still-running recovery without blocking: process exit kills
-- the worker with it. The outbox is still drained so a finished PNG is not
-- leaked when abandon races completion.
function Job:abandon()
  if self._disposed then
    return
  end
  self._disposed = true
  local outbox = assert(self._outbox, "managed icon recovery job is disposed")
  while true do
    local packet = outbox:pop()
    if packet == nil then
      break
    end
    if type(packet) == "table" and type(packet.png) == "userdata" then
      local png = packet.png --[[@as love.FileData]]
      pcall(png.release, png)
    end
  end
  self._thread = nil
  self._outbox = nil
end

function Job:dispose()
  if self._disposed then
    return
  end
  self._disposed = true
  local thread = assert(self._thread, "managed icon recovery job is disposed")
  local outbox = assert(self._outbox, "managed icon recovery job is disposed")
  pcall(thread.wait, thread)
  while true do
    local packet = outbox:pop()
    if packet == nil then
      break
    end
    if type(packet) == "table" and type(packet.png) == "userdata" then
      local png = packet.png --[[@as love.FileData]]
      pcall(png.release, png)
    end
  end
  self._thread = nil
  self._outbox = nil
end

---@param versionId string
---@return RomIconRecovery.Job
function RomIconRecovery.start(versionId)
  assert(GameVersion.VERSIONS[versionId], "unknown version id: " .. tostring(versionId))
  local host = love.thread
  if type(host.newChannel) ~= "function" or type(host.newThread) ~= "function" then
    Errors.raise("ROM_ICON_RECOVERY_UNAVAILABLE", "managed icon recovery needs love.thread", {})
  end
  local outbox = host.newChannel()
  local thread = host.newThread(bootstrap())
  assert(outbox ~= nil and thread ~= nil, "managed icon recovery could not allocate its worker")
  local started, startError = pcall(thread.start, thread, package.path, versionId, outbox)
  if not started or startError == false then
    Errors.raise("ROM_ICON_RECOVERY_UNAVAILABLE", "managed icon recovery worker failed to start", {
      cause = tostring(startError),
    })
  end
  return setmetatable({ _thread = thread, _outbox = outbox, _terminal = false, _disposed = false }, Job)
end

return RomIconRecovery
