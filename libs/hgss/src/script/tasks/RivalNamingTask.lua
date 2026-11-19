-- Blocking HGSS rival naming input task. The source NameRival command runs
-- the shared field naming screen in rival mode and reports the native
-- no-input result; only an accepted name reaches the live player profile.

local Errors = require("libs.errors.src.Errors")
local PlayerData = require("libs.hgss.src.save.PlayerData")
local ScriptErrors = require("libs.script.src.errors")
local Utf8Glyphs = require("libs.assets.src.Utf8Glyphs")

local RivalNamingTask = {}
RivalNamingTask.type = "rival_naming"
RivalNamingTask.version = 1

-- Retail `src/scrcmd_c.c::ScrCmd_NameRival` names the rival with
-- PLAYER_NAME_LENGTH, so the rival screen shares the player name limit.
local MAX_RIVAL_NAME_GLYPHS = PlayerData.MAX_NAME_GLYPHS

---@class RivalNamingTask.NamingHost
---@field isActive fun(self: RivalNamingTask.NamingHost): boolean
---@field open fun(self: RivalNamingTask.NamingHost, spec: table<string, unknown>)
---@field handleInput fun(self: RivalNamingTask.NamingHost, events: table[])
---@field updateFixed fun(self: RivalNamingTask.NamingHost)
---@field status fun(self: RivalNamingTask.NamingHost): { done: boolean, text: string }
---@field close fun(self: RivalNamingTask.NamingHost)

---@class RivalNamingTask.PlayerFacade
---@field rivalName fun(self: RivalNamingTask.PlayerFacade): string
---@field setRivalName fun(self: RivalNamingTask.PlayerFacade, name: string)

---@param ctx table<string, unknown>
---@param key "player"
---@return RivalNamingTask.PlayerFacade
---@overload fun(ctx: table<string, unknown>, key: "monNaming"): RivalNamingTask.NamingHost
local function service(ctx, key)
  local value = ctx.services and ctx.services[key]
  if value == nil then
    Errors.raise(ScriptErrors.SCRIPT_SERVICE_MISSING, "rival naming requires " .. key, {
      scriptId = ctx.instance and ctx.instance.scriptId,
    })
  end
  return value --[[@as RivalNamingTask.PlayerFacade|RivalNamingTask.NamingHost]]
end

local function glyphCount(text)
  local count = 0
  for _ in Utf8Glyphs.iter(text) do
    count = count + 1
  end
  return count
end

-- The source task keeps only its lifetime flags and editing buffer: the
-- opening name and the accepted write live on the player profile.
---@param spec table<string, unknown>
---@param ctx table<string, unknown>
---@return table<string, unknown>
function RivalNamingTask.create(spec, ctx)
  assert(type(spec) == "table", "rival naming task requires a spec")
  local host = service(ctx, "monNaming")
  assert(type(host.isActive) == "function", "rival naming host is incomplete")
  local player = service(ctx, "player")
  assert(type(player.rivalName) == "function", "rival naming requires the player name reader")
  return {
    initialText = player:rivalName(),
    currentText = "",
    opened = false,
    closed = false,
  }
end

---@param state table<string, unknown>
---@param ctx table<string, unknown>
---@return table<string, unknown>
function RivalNamingTask.poll(state, ctx)
  local host = service(ctx, "monNaming")
  assert(type(host.isActive) == "function" and type(host.open) == "function", "rival naming host is incomplete")
  local openedThisPoll = false
  if not host:isActive() then
    host:open({
      kind = "rival",
      currentText = assert(state.currentText --[[@as string]]),
      maxLength = MAX_RIVAL_NAME_GLYPHS,
      subject = { kind = "rival" },
    })
    state.opened = true
    state.closed = false
    openedThisPoll = true
  end
  local events = (ctx.input or {}).uiEvents or {}
  assert(type(events) == "table", "rival naming UI events must be a table")
  if #events > 0 then
    host:handleInput(events)
  end
  if not openedThisPoll then
    host:updateFixed()
  end
  local status = host:status()
  assert(type(status) == "table", "active rival naming host publishes status")
  assert(type(status.text) == "string" and type(status.done) == "boolean", "rival naming status is valid")
  state.currentText = status.text
  if not status.done then
    return { complete = false, state = state }
  end
  -- The native result is the no-input flag: blank or unchanged input keeps
  -- the previously stored rival name and reports 1, an accepted name is
  -- published once and reports 0.
  local result = 1
  if status.text:match("^%s*$") == nil and status.text ~= state.initialText then
    service(ctx, "player"):setRivalName(status.text)
    result = 0
  end
  host:close()
  state.closed = true
  return { complete = true, state = state, result = result }
end

---@param state table<string, unknown>
---@param reason string
---@param ctx table<string, unknown>|nil
function RivalNamingTask.cancel(state, reason, ctx)
  state.cancelled = reason
  if ctx == nil or state.closed then
    return
  end
  local host = ctx.services and ctx.services.monNaming
  if host ~= nil and host:isActive() then
    host:close()
  end
  state.closed = true
end

---@param state table<string, unknown>
---@return Errors.Error|nil
function RivalNamingTask.validate(state)
  if type(state) ~= "table" then
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "rival naming task state must be a record", {})
  end
  if type(state.initialText) ~= "string" or type(state.currentText) ~= "string" then
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "rival naming task text must be strings", {})
  end
  for _, text in ipairs({ state.initialText, state.currentText }) do
    if glyphCount(text) > MAX_RIVAL_NAME_GLYPHS then
      return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "rival naming task text exceeds seven glyphs", {})
    end
  end
  if type(state.opened) ~= "boolean" or type(state.closed) ~= "boolean" then
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "rival naming task flags must be booleans", {})
  end
  return nil
end

return RivalNamingTask
