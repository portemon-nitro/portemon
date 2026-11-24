-- The single script-owned care child: one request, one scene, one terminal
-- result. Two closed application kinds exist: the egg hatch scene and the app71
-- trade sequence. The blocking task owns the source lifecycle and the save policy;
-- this host owns only the child handle, its presentation bundle and its result
-- lease. The scene advances on the owning scheduler tick, so the field never
-- steps it, and the renderer only reads its snapshots. Stale handles and
-- presentation failures propagate after cleanup. Game-side leaf: never
-- imported by libs/script.

local EggHatchState = require("game.hgss.src.field.EggHatchState")
local NpcTradeState = require("game.hgss.src.field.NpcTradeState")
local PokemonCareInterface = require("libs.hgss.src.ui.PokemonCareInterface")

---@class PokemonCareScriptHost
---@field private _runtime table<string, unknown> owning field runtime behind the presentation binding
---@field private _nextId integer handle identity counter
---@field private _active { handle: table<string, unknown>, state: table<string, unknown>, lease: table<string, unknown>?, request: table<string, unknown> }? live child
---@field private _last { handle: table<string, unknown>, result: table<string, unknown>? }? retained terminal result behind the just-closed child
---@field private _disposed boolean teardown flag
local PokemonCareScriptHost = {}
PokemonCareScriptHost.__index = PokemonCareScriptHost

---@param args { runtime: table<string, unknown> }
---@return PokemonCareScriptHost
function PokemonCareScriptHost.new(args)
  assert(type(args) == "table", "care host requires its owner")
  assert(type(args.runtime) == "table", "care host borrows its field runtime")
  return setmetatable({
    _runtime = args.runtime,
    _nextId = 0,
    _active = nil,
    _last = nil,
    _disposed = false,
  }, PokemonCareScriptHost)
end

-- Opens the one care child. The presentation lease is acquired through the
-- runtime's binding, which the presented field installs; a headless
-- composition has none, so the scene still runs its source frames and waits
-- while the renderer reports no bundle. A failed acquisition surfaces as the
-- scene's own preparation error instead of a silent blank screen.
---@param request table<string, unknown> the closed application request
---@return table<string, unknown> handle live child identity
function PokemonCareScriptHost:open(request)
  assert(not self._disposed, "disposed care host cannot open a child")
  assert(self._active == nil, "a care application already owns the script modal")
  assert(type(request) == "table", "care applications open from a request record")
  local runtime = self._runtime
  local audio = assert(runtime.audio or (runtime.scriptHosts and runtime.scriptHosts.audio), "care host needs the source audio host")
  self._nextId = self._nextId + 1
  local handle = { id = self._nextId }
  local typed, state
  if request.kind == PokemonCareInterface.KINDS.trade then
    typed = PokemonCareInterface.assertTradeRequest(request)
    state = NpcTradeState.new({ request = typed, audio = audio })
  else
    typed = PokemonCareInterface.assertHatchRequest(request)
    state = EggHatchState.new({
      variant = typed.variant,
      species = typed.species,
      form = typed.form,
      audio = audio,
      hatched = { messageId = 0, frames = 1 },
      question = { messageId = 1, frames = 1 },
    })
  end
  local lease = nil
  if type(runtime.acquirePokemonCarePresentation) == "function" then
    lease = runtime:acquirePokemonCarePresentation(typed)
  end
  self._active = { handle = handle, state = state, lease = lease, request = typed }
  self._last = nil
  return handle
end

---@return table<string, unknown>? handle live child identity when a child is open
function PokemonCareScriptHost:activeHandle()
  local active = self._active
  if active == nil then
    return nil
  end
  return active.handle
end

---@param handle table<string, unknown>
---@return { handle: table<string, unknown>, state: table<string, unknown>, lease: table<string, unknown>?, request: table<string, unknown> }
local function activeFor(self, handle)
  local active = assert(self._active, "no care application is open")
  assert(handle == active.handle, "care application handle is stale or foreign")
  return active
end

-- Steps the live child once over the scheduler input snapshot and advances the
-- generated presentation bundle. A failed bundle is reported on the scene's
-- own snapshot instead of aborting the gameplay path.
---@param handle table<string, unknown> live child identity
---@param input table<string, unknown>? scheduler input snapshot
function PokemonCareScriptHost:step(handle, input)
  local active = activeFor(self, handle)
  local lease = active.lease
  if lease ~= nil then
    local ok, outcome = pcall(lease.prepare, lease)
    if not ok then
      active.state:setPresentation(false, tostring(outcome))
    elseif outcome ~= nil then
      if outcome.kind == "ready" then
        active.state:setPresentation(true, nil)
      elseif outcome.kind == "failed" then
        active.state:setPresentation(false, tostring(outcome.error))
      else
        active.state:setPresentation(false, nil)
      end
    end
  end
  active.state:updateFixed(input)
  local presentation = lease ~= nil and lease:presentation() or nil
  if presentation == nil then
    return
  end
  local snapshot = active.state:snapshot()
  if snapshot.kind == PokemonCareInterface.KINDS.hatch then
    local requested = snapshot.particles --[[@as integer[]|nil ]]
    if requested ~= nil and #requested > 0 then
      presentation.renderer:emitParticles(assert(snapshot.variant) --[[@as string]], requested)
    end
    presentation.renderer:updateFixed()
  end
end

-- Reads the terminal result: nil until the scene finished, then the detached
-- answer. The host caches that publication and serves it until close, so the
-- owning task and an observer share one terminal read.
---@param handle table<string, unknown> live or just-closed child identity
---@return table<string, unknown>? terminal scene result
function PokemonCareScriptHost:result(handle)
  local active = self._active
  if active ~= nil then
    assert(handle == active.handle, "care application handle is stale or foreign")
    if not active.state:isDone() then
      return nil
    end
    return active.state:result()
  end
  local last = self._last
  if last ~= nil and handle == last.handle then
    self._last = nil
    return last.result
  end
  assert(false, "care application handle is stale or foreign")
  error("unreachable", 0)
end

-- Releases the child, its scene and its presentation lease. Idempotent:
-- closing without a child or with the live handle both succeed exactly once
-- per open.
---@param handle table<string, unknown>? live child identity
function PokemonCareScriptHost:close(handle)
  local active = self._active
  if active == nil then
    return
  end
  assert(handle == active.handle, "care application handle is stale or foreign")
  local result = active.state:isDone() and active.state:result() or nil
  if active.lease ~= nil then
    active.lease:release()
  end
  active.state:dispose()
  self._active = nil
  self._last = { handle = active.handle, result = result }
end

---@return boolean
function PokemonCareScriptHost:isActive()
  return self._active ~= nil
end

-- A care child owns the field from its open through its close and the receipt
-- publication that follows: no field record may describe the half-applied
-- hatch while it lives.
---@return boolean
function PokemonCareScriptHost:isStableForSave()
  return self._active == nil
end

-- Forwards the live scene's immutable snapshot for drawing. Status never
-- advances the scene.
---@param handle table<string, unknown>? live child identity
---@return table<string, unknown>? scene snapshot
function PokemonCareScriptHost:status(handle)
  local active = self._active
  if active == nil then
    return nil
  end
  if handle ~= nil then
    assert(handle == active.handle, "care application handle is stale or foreign")
  end
  return active.state:snapshot()
end

-- The committed presentation bundle behind the live scene, or nil while it is
-- still pending or unusable.
---@return table<string, unknown>?
function PokemonCareScriptHost:presentation()
  local active = self._active
  if active == nil or active.lease == nil then
    return nil
  end
  return active.lease:presentation()
end

-- The live snapshot the renderer draws, or nil when no child is open.
---@return table<string, unknown>?
function PokemonCareScriptHost:snapshot()
  local active = self._active
  if active == nil then
    return nil
  end
  return active.state:snapshot()
end

-- Releases the owned child once for the given reason. Idempotent.
---@param reason string
function PokemonCareScriptHost:cancel(reason)
  assert(type(reason) == "string" and reason ~= "", "care cancellation requires a reason")
  local active = self._active
  if active ~= nil then
    self:close(active.handle)
  end
end

-- Idempotent teardown: releases the child and refuses further opens.
function PokemonCareScriptHost:dispose()
  if self._disposed then
    return
  end
  self._disposed = true
  local active = self._active
  if active ~= nil then
    self:close(active.handle)
  end
end

return PokemonCareScriptHost
