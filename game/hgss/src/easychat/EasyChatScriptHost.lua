-- The single script-owned word editor child: one request, one screen, one
-- terminal result. The task owns the source lifecycle and the save
-- policy; this host owns only the child handle, its readiness, and its
-- result lease. The screen gates its own interaction: the host steps it
-- once per owning scheduler tick, including pending preparation, and
-- forwards the child's own status and input profile. Stale handles and
-- preparation failures propagate after cleanup. Game-side leaf: never
-- imported by libs/script.

local EasyChatComposition = require("game.hgss.src.easychat.EasyChatComposition")

---@class EasyChatScriptHost
---@field private _runtime table<string, unknown> owning field runtime behind the editor factory
---@field private _nextId integer handle identity counter
---@field private _active { handle: table<string, unknown>, screen: table<string, unknown>, result: table<string, unknown>? }? live child
---@field private _last { handle: table<string, unknown>, result: table<string, unknown>? }? retained terminal result behind the just-closed child
---@field private _disposed boolean teardown flag
local EasyChatScriptHost = {}
EasyChatScriptHost.__index = EasyChatScriptHost

---@param args table<string, unknown> { runtime }
---@return EasyChatScriptHost
function EasyChatScriptHost.new(args)
  assert(type(args) == "table", "word editor host requires its owner")
  assert(type(args.runtime) == "table", "word editor host borrows its field runtime")
  return setmetatable({
    _runtime = args.runtime,
    _nextId = 0,
    _active = nil,
    _disposed = false,
  }, EasyChatScriptHost)
end

-- Opens the one script-owned editor child. Exception-safe: a failed open
-- releases what the factory acquired and raises the real cause before any
-- handle exists.
---@param request table<string, unknown> shared-editor open request
---@return table<string, unknown> handle live child identity
function EasyChatScriptHost:open(request)
  assert(not self._disposed, "disposed word editor host cannot open a child")
  assert(self._active == nil, "a word editor already owns the script modal")
  assert(type(request) == "table", "word editor requests are records")
  local ok, screen = pcall(EasyChatComposition.open, self._runtime, request)
  if not ok then
    error(screen, 0)
  end
  assert(type(screen) == "table", "word editor factory returns a child")
  self._nextId = self._nextId + 1
  local handle = { id = self._nextId }
  self._active = { handle = handle, screen = screen, result = nil }
  self._last = nil
  return handle
end

---@return table<string, unknown>? handle live child identity when a child is open
function EasyChatScriptHost:activeHandle()
  local active = self._active
  if active == nil then
    return nil
  end
  return active.handle
end

---@param handle table<string, unknown>
---@return { handle: table<string, unknown>, screen: table<string, unknown> } live child
local function activeFor(self, handle)
  local active = assert(self._active, "no word editor is open")
  assert(handle == active.handle, "word editor handle is stale or foreign")
  return active
end

-- Steps the live child once over the scheduler event batch. A stale
-- handle faults; a failed child releases its screen and propagates the
-- original error, never a synthetic player cancel.
---@param handle table<string, unknown> live child identity
---@param events table[] scheduler UI events
function EasyChatScriptHost:step(handle, events)
  local active = activeFor(self, handle)
  assert(type(events) == "table", "word editor steps the scheduler event batch")
  local screen = active.screen
  local ok, failure = pcall(screen.updateFixed, screen, events)
  if not ok then
    self:close(handle)
    error(failure, 0)
  end
  local status = screen:status()
  if type(status) == "table" and status.preparationError ~= nil then
    self:close(handle)
    error(status.preparationError, 0)
  end
end

-- Reads the terminal result: nil until the exit fade completes, then the
-- detached result. The screen publishes once per open; the host caches
-- that publication and serves it until close, so the owning task and an
-- observer share one terminal read without racing it. Close retains the
-- publication for exactly one post-close read, then reports nothing.
---@param handle table<string, unknown> live or just-closed child identity
---@return table<string, unknown>? terminal editor result
function EasyChatScriptHost:result(handle)
  local active = self._active
  if active ~= nil then
    assert(handle == active.handle, "word editor handle is stale or foreign")
    if active.result == nil then
      active.result = active.screen:takeResult()
    end
    return active.result
  end
  local last = self._last
  if last ~= nil and handle == last.handle then
    self._last = nil
    return last.result
  end
  assert(false, "word editor handle is stale or foreign")
  error("unreachable", 0)
end

-- Releases the child and its lease. Idempotent: closing without a child
-- or with the live handle both succeed exactly once per open. The
-- terminal publication survives for one post-close read.
---@param handle table<string, unknown>? live child identity
function EasyChatScriptHost:close(handle)
  local active = self._active
  if active == nil then
    return
  end
  assert(handle == active.handle, "word editor handle is stale or foreign")
  active.screen:dispose()
  self._active = nil
  self._last = { handle = active.handle, result = active.result }
end

---@return boolean
function EasyChatScriptHost:isActive()
  return self._active ~= nil
end

-- Forwards the live child's status: readiness, view, assets, and any
-- preparation failure the task owns. Status never ticks the child.
---@return table<string, unknown>? child status
function EasyChatScriptHost:status()
  local active = self._active
  if active == nil then
    return nil
  end
  return active.screen:status()
end

-- Forwards the child's own input profile in pending and ready states so
-- the owning session routes the tick's UI events to the scheduler lane.
---@return unknown modal input profile, or nil without a child
function EasyChatScriptHost:activeUiInput()
  local active = self._active
  if active == nil then
    return nil
  end
  return active.screen.uiInput
end

-- Drops the child's pointer capture so a stale release can never answer
-- after focus or input-mode changes.
function EasyChatScriptHost:cancelPointerCapture()
  local active = self._active
  if active ~= nil then
    active.screen:cancelPointerCapture()
  end
end

-- Releases the owned child once for the given reason. Idempotent: a
-- cancelled or already-closed host stays released.
---@param reason string
function EasyChatScriptHost:cancel(reason)
  assert(type(reason) == "string" and reason ~= "", "word editor cancellation requires a reason")
  local active = self._active
  if active ~= nil then
    self:close(active.handle)
  end
end

-- Idempotent teardown: releases the child and refuses further opens.
function EasyChatScriptHost:dispose()
  if self._disposed then
    return
  end
  self._disposed = true
  local active = self._active
  if active ~= nil then
    self:close(active.handle)
  end
end

return EasyChatScriptHost
