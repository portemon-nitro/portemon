-- Source script continuation for battle results. A battle_launch operation
-- starts one pending launch through the injected battle host and suspends
-- the script; each poll observes the host exactly once per completion, and
-- result reads the recorded outcome (or the committer receipt for
-- launchId-only lookups). The task never simulates combat: the host owns
-- the battle lifetime and the committer owns publication, so the script
-- resumes only after the required commit. The same completed launch never
-- records twice: poll guards on the state flag and result is a pure read.
--
-- Host contract (duck-typed; the game application supplies it, tests inject
-- a fake; no battle package is imported here):
--   host:launchBattle(spec) -> launchId string (optional; without it start
--     keeps the caller-supplied launch identity)
--   host:battleStatus(launchId)
--     -> { phase: string, committed: boolean, result: string?,
--          sourceResult: integer? } | nil
-- Without a host, start records the pending launch and poll reports the
-- precise missing-service fault instead of succeeding.

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.script.src.errors")
local HgssBattleCommitter = require("libs.hgss.src.battle.HgssBattleCommitter")

---@class BattleTask
local BattleTask = {}

BattleTask.type = "battle"
BattleTask.version = 1

-- Script-visible outcome codes. A won or caught battle reads back won;
-- every other settled outcome reads back not-won, so scripts can never
-- mistake a draw, loss, or flight for a victory.
BattleTask.SOURCE_WON = 1
BattleTask.SOURCE_NOT_WON = 0

BattleTask.KINDS = { wild = true, trainer = true, scripted = true, scenario = true }

-- Outcome words the host may report. They match the shared battle outcome
-- vocabulary; "pending" and "unresolved" are task-level reads, never host
-- outcomes.
BattleTask.RESULTS = {
  win = true,
  loss = true,
  draw = true,
  flee = true,
  capture = true,
}

-- Completed launch outcomes recorded by poll, keyed by launch identity.
-- This mirrors the committer receipt registry: poll observes the host's
-- committed outcome once and result reads it back without re-running
-- anything. Entries never leave this module.
local COMPLETED = {}

---@param launchId unknown
---@return boolean
local function isLaunchId(launchId)
  return type(launchId) == "string" and launchId ~= ""
end

---@param kind unknown
---@return boolean
local function isKind(kind)
  return kind == nil or BattleTask.KINDS[kind] == true
end

---@param spec unknown
local function checkSpec(spec)
  if type(spec) ~= "table" then
    Errors.raise(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "battle launches require a spec record", {})
  end
  assert(type(spec) == "table", "the spec check reads the launch record")
  -- The launch identity is optional at start: a host that issues
  -- identities supplies it, otherwise the caller does. Persisted task
  -- state always carries one (see validate).
  if spec.launchId ~= nil and not isLaunchId(spec.launchId) then
    Errors.raise(
      ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE,
      "battle launches require a non-empty launch identity",
      { launchId = spec.launchId }
    )
  end
  if not isKind(spec.kind) then
    Errors.raise(
      ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE,
      "battle launches name a known battle kind",
      { kind = spec.kind }
    )
  end
  if spec.details ~= nil and type(spec.details) ~= "table" then
    Errors.raise(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "battle launch details must be a record when present", {})
  end
end

---@param ctx table<string, unknown>
---@return table<string, unknown>?
local function battleHost(ctx)
  if type(ctx) ~= "table" then
    return nil
  end
  local services = ctx.services
  if type(services) ~= "table" then
    return nil
  end
  local host = services.battle
  if type(host) ~= "table" then
    return nil
  end
  return host --[[@as table<string, unknown>]]
end

---@param result unknown
---@return integer script-visible outcome code
local function sourceCode(result)
  if result == "win" or result == "capture" then
    return BattleTask.SOURCE_WON
  end
  return BattleTask.SOURCE_NOT_WON
end

-- Starts one pending launch. When the injected host offers launchBattle the
-- host issues the launch identity (unique per launch instance, so two runs
-- of one script site never share a committer receipt); otherwise the
-- caller-supplied identity stands and the first poll observes the battle
-- the caller drives itself.
---@param spec table<string, unknown>
---@param ctx table<string, unknown>
---@return table<string, unknown> task state
function BattleTask.start(spec, ctx)
  checkSpec(spec)
  assert(type(spec) == "table", "the spec check carries the launch record")
  local host = battleHost(ctx)
  local launchId = spec.launchId
  if host ~= nil and type(host.launchBattle) == "function" then
    local issued = host:launchBattle(spec)
    if not isLaunchId(issued) then
      Errors.raise(
        ScriptErrors.SCRIPT_SERVICE_MISSING,
        "the battle host issued no launch identity",
        { launchId = spec.launchId }
      )
    end
    launchId = issued
  elseif not isLaunchId(launchId) then
    Errors.raise(
      ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE,
      "battle launches require a launch identity without an issuing host",
      { launchId = spec.launchId }
    )
  end
  assert(type(launchId) == "string" and launchId ~= "", "pending launches carry their identity")
  return {
    launchId = launchId,
    kind = spec.kind,
    completed = false,
  }
end

-- The scheduler creation entry: starting a launch is creating its pending
-- task state.
BattleTask.create = BattleTask.start

---@param state table<string, unknown>
---@param status table<string, unknown>
local function recordCompletion(state, status)
  if COMPLETED[state.launchId] ~= nil then
    return
  end
  COMPLETED[state.launchId] = {
    result = status.result,
    sourceResult = status.sourceResult,
  }
end

-- Polls the pending launch once. A completed state stays complete without
-- touching the host again; otherwise the host status decides: a committed
-- battle records its outcome exactly once and completes with the
-- script-visible code, while any earlier phase stays pending.
---@param state table<string, unknown>
---@param ctx table<string, unknown>
---@return table<string, unknown> completion record with its outcome code when complete
function BattleTask.poll(state, ctx)
  if type(state) ~= "table" or not isLaunchId(state.launchId) then
    Errors.raise(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "battle task state must carry its launch identity", {})
  end
  assert(type(state) == "table", "the state check carries the task record")
  if state.completed == true then
    return { complete = true, state = state }
  end
  local host = battleHost(ctx)
  if host == nil or type(host.battleStatus) ~= "function" then
    Errors.raise(ScriptErrors.SCRIPT_SERVICE_MISSING, "battle tasks require the battle host", {
      launchId = state.launchId,
    })
  end
  assert(host ~= nil, "the host check carries the battle host")
  local status = host:battleStatus(state.launchId)
  if status == nil then
    Errors.raise(ScriptErrors.SCRIPT_INVALID_REFERENCE, "the battle host knows no such launch", {
      launchId = state.launchId,
    })
  end
  assert(type(status) == "table", "the host answers with a status record")
  if status.error ~= nil then
    Errors.raise(ScriptErrors.SCRIPT_TASK_CALLBACK_FAULT, "the battle application failed", {
      launchId = state.launchId,
      cause = status.error,
    })
  end
  if status.committed ~= true then
    return { complete = false, state = state }
  end
  if type(status.result) ~= "string" or BattleTask.RESULTS[status.result] ~= true then
    Errors.raise(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "committed battles report a known outcome word", {
      launchId = state.launchId,
      result = status.result,
    })
  end
  local code = sourceCode(status.result)
  recordCompletion(state, { result = status.result, sourceResult = code })
  state.completed = true
  state.result = status.result
  state.sourceResult = code
  return { complete = true, state = state, result = code }
end

-- Validates persisted battle task state. Only the launch identity, kind,
-- completion flag, and recorded outcome serialize; the live battle is
-- rebuilt from the launch identity on every poll.
---@param state unknown
---@return Errors.Error? nil when valid
function BattleTask.validate(state)
  if type(state) ~= "table" then
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "battle task state must be a record", {})
  end
  assert(type(state) == "table", "validation reads the task record")
  if not isLaunchId(state.launchId) then
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "battle task state must carry its launch identity", {})
  end
  if not isKind(state.kind) then
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "battle task state names a known battle kind", {
      kind = state.kind,
    })
  end
  if state.completed ~= nil and type(state.completed) ~= "boolean" then
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "battle task completion must be a boolean", {})
  end
  if state.result ~= nil and BattleTask.RESULTS[state.result] ~= true then
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "battle task outcome must be a known word", {
      result = state.result,
    })
  end
  if
    state.sourceResult ~= nil
    and state.sourceResult ~= BattleTask.SOURCE_WON
    and state.sourceResult ~= BattleTask.SOURCE_NOT_WON
  then
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "battle task outcome code must be won or not-won", {
      sourceResult = state.sourceResult,
    })
  end
  return nil
end

-- Reads the source outcome for one launch without running anything. A
-- completed task state reports its recorded words; a bare launch identity
-- consults the committer receipt (commitment without recorded words reads
-- back unresolved); an unknown launch reads back pending. Every path is a
-- pure read: repeated calls never re-run or duplicate the result.
---@param ref { launchId: string, result: string?, sourceResult: integer? }
---@return { launchId: string, result: string, sourceResult: integer?, committed: boolean }
function BattleTask.result(ref)
  if type(ref) ~= "table" or not isLaunchId(ref.launchId) then
    Errors.raise(ScriptErrors.SCRIPT_INVALID_REFERENCE, "battle results require a launch identity", {})
  end
  assert(type(ref) == "table", "the reference check carries the launch identity")
  local recorded = COMPLETED[ref.launchId]
  if recorded ~= nil then
    return {
      launchId = ref.launchId,
      result = recorded.result,
      sourceResult = recorded.sourceResult,
      committed = true,
    }
  end
  if type(ref.result) == "string" and BattleTask.RESULTS[ref.result] == true then
    return {
      launchId = ref.launchId,
      result = ref.result,
      sourceResult = ref.sourceResult,
      committed = true,
    }
  end
  local receipt = HgssBattleCommitter.receipt(ref.launchId)
  if receipt ~= nil then
    return {
      launchId = ref.launchId,
      result = "unresolved",
      sourceResult = BattleTask.SOURCE_NOT_WON,
      committed = receipt.committed == true,
    }
  end
  return {
    launchId = ref.launchId,
    result = "pending",
    sourceResult = BattleTask.SOURCE_NOT_WON,
    committed = false,
  }
end

return BattleTask
