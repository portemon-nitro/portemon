-- Battle-private effect task factory for normalized battle animations.
-- Native task bodies live in src/battle/battle_anim_effects.c and drive
-- sys tasks through BattleAnimSystem_CreateTaskOfKind (kind 1 counts
-- taskCount, kind 2 counts soundTaskCount); raw visual work uses
-- SysTask_CreateOnMainQueue directly and stays outside both counters.
-- The player schedules work through this factory as
-- Factory.create(kind, args, context, services); unknown kinds fail here
-- instead of returning a timer stand-in. Only the player's
-- voice-completion monitor has a body in this lane; every other native
-- task kind fails closed until its implementation lands.

---@class BattleEffectTasks
local BattleEffectTasks = {}

-- Player-support task kind owned by the animation player contract: it
-- completes exactly when its awaited voice finishes, so the player's
-- sound wait retires on a real audio condition rather than a duration.
-- The spelling matches BattleAnimationPlayer.VOICE_TASK_KIND, which owns
-- the contract string as the sole constructor-side consumer.
BattleEffectTasks.VOICE_MONITOR_KIND = "voice-completion-monitor"

local VALID_TASK_STATES = {
  pending = true,
  running = true,
  complete = true,
  cancelled = true,
}

---@class BattleVoiceMonitor
---@field _voice string awaited voice key owned by one player occurrence
---@field _audio table<string, unknown> narrow audio collaborator behind isFinished
---@field _state string pending, running, complete, or cancelled
---@field _cancelReason string? last cancellation reason under diagnosis
---@field _disposed boolean release has run
local BattleVoiceMonitor = {}
BattleVoiceMonitor.__index = BattleVoiceMonitor

---@param voice string awaited voice key staged by the waiting occurrence
---@param services table<string, unknown> scene, audio, and resource collaborators
---@return BattleVoiceMonitor runnable voice monitor
local function newVoiceMonitor(voice, services)
  assert(type(voice) == "string" and voice ~= "", "voice monitors await a named voice")
  assert(type(services) == "table", "voice monitors read their audio collaborator from services")
  local audio = services.audio --[[@as table<string, unknown>]]
  assert(type(audio) == "table", "voice monitors require their audio collaborator")
  assert(type(audio.isFinished) == "function", "voice monitors require an isFinished audio query")
  return setmetatable({
    _voice = voice,
    _audio = audio,
    _state = "pending",
    _cancelReason = nil,
    _disposed = false,
  }, BattleVoiceMonitor)
end

-- Advances one source tick: completion is the awaited voice finishing,
-- never an elapsed duration. Audio failures propagate so the player can
-- fail the owning occurrence with instruction provenance.
---@param self BattleVoiceMonitor
---@param tick table<string, unknown>? source tick under advancement
function BattleVoiceMonitor:stepSourceTick(tick)
  local _ = tick
  if self._disposed or self._state == "complete" or self._state == "cancelled" then
    return
  end
  self._state = "running"
  local audio = self._audio --[[@as table<string, fun(string): boolean>]]
  if audio.isFinished(self._voice) then
    self._state = "complete"
  end
end

-- Reports the monitor run state for the player's retirement accounting.
-- States are the strings pending, running, complete, and cancelled.
---@param self BattleVoiceMonitor
---@return string
function BattleVoiceMonitor:status()
  assert(VALID_TASK_STATES[self._state] == true, "voice monitors report a known run state")
  return self._state
end

-- Cancels the monitor; completion and cancellation stay separate, so a
-- completed monitor keeps its completion.
---@param self BattleVoiceMonitor
---@param reason string cancellation cause under diagnosis
function BattleVoiceMonitor:cancel(reason)
  if self._state == "complete" then
    return
  end
  self._state = "cancelled"
  self._cancelReason = reason
end

-- Releases the monitor exactly once; the monitor holds no lease, voice,
-- or scene mutation of its own.
---@param self BattleVoiceMonitor
function BattleVoiceMonitor:dispose()
  self._disposed = true
end

-- Constructs one runnable task for a normalized task kind. The player
-- passes its scene, audio, and resource collaborators through services
-- untouched; task bodies own only what services delegate at construction.
---@param kind string normalized task kind scheduled by one instruction
---@param args table<string, unknown>? instruction-derived construction arguments
---@param context table<string, unknown>? occurrence-bound playback context
---@param services table<string, unknown>? scene, audio, and resource collaborators
---@return table<string, unknown> runnable task behind stepSourceTick, status, cancel, dispose
function BattleEffectTasks.create(kind, args, context, services)
  assert(args == nil or type(args) == "table", "task construction carries its arguments as a record")
  assert(context == nil or type(context) == "table", "task construction carries its context as a record")
  if kind == BattleEffectTasks.VOICE_MONITOR_KIND then
    assert(type(args) == "table", "voice monitors carry their awaited voice in args")
    assert(type(services) == "table", "voice monitors require their services record")
    local voice = args.voice --[[@as string]]
    return newVoiceMonitor(voice, services)
  end
  error("BATTLE_EFFECT_TASK_UNKNOWN: no native task implementation for kind " .. tostring(kind), 0)
end

return BattleEffectTasks
