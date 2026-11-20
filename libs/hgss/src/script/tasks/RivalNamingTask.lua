-- Blocking HGSS rival naming input task. The source NameRival command runs
-- the shared field naming screen in rival mode and always accepts its
-- result: an empty entry commits the generated default name the composition
-- resolves from the naming screen's own message bank and a typed entry
-- commits the typed name, so the single accepted name reaches the live
-- player profile.

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

-- The rival naming screen has no nickname-style declined-input result: an
-- empty or all-space entry takes the default name the naming screen stores
-- (`src/naming_screen.c:NamingScreen_SetDefaultName` reads
-- FIRST_DEFAULT_NAME_RIVAL), and the source then stores it without setting
-- `noInput`. The composition resolves that generated text and injects it.

---@class RivalNamingTask.NamingHost
---@field isActive fun(self: RivalNamingTask.NamingHost): boolean
---@field open fun(self: RivalNamingTask.NamingHost, spec: table<string, unknown>)
---@field handleInput fun(self: RivalNamingTask.NamingHost, events: table[])
---@field updateFixed fun(self: RivalNamingTask.NamingHost)
---@field status fun(self: RivalNamingTask.NamingHost): { done: boolean, text: string }
---@field close fun(self: RivalNamingTask.NamingHost)

---@class RivalNamingTask.PlayerFacade
---@field setRivalName fun(self: RivalNamingTask.PlayerFacade, name: string)

-- The generated default name the naming screen stores for an empty entry:
-- the composition resolves the selected edition's message row and returns its
-- text.
---@alias RivalNamingTask.DefaultNameResolver fun(): string

---@param ctx table<string, unknown>
---@param key "player"
---@return RivalNamingTask.PlayerFacade
---@overload fun(ctx: table<string, unknown>, key: "monNaming"): RivalNamingTask.NamingHost
---@overload fun(ctx: table<string, unknown>, key: "rivalDefaultName"): RivalNamingTask.DefaultNameResolver
local function service(ctx, key)
  local value = ctx.services and ctx.services[key]
  if value == nil then
    Errors.raise(ScriptErrors.SCRIPT_SERVICE_MISSING, "rival naming requires " .. key, {
      scriptId = ctx.instance and ctx.instance.scriptId,
    })
  end
  return value --[[@as RivalNamingTask.PlayerFacade|RivalNamingTask.NamingHost|RivalNamingTask.DefaultNameResolver]]
end

local function glyphCount(text)
  local count = 0
  for _ in Utf8Glyphs.iter(text) do
    count = count + 1
  end
  return count
end

-- The source task keeps only its lifetime flags, editing buffer, and the
-- generated default name an empty entry commits; the accepted write lives on
-- the player profile alone.
---@param spec table<string, unknown>
---@param ctx table<string, unknown>
---@return table<string, unknown>
function RivalNamingTask.create(spec, ctx)
  assert(type(spec) == "table", "rival naming task requires a spec")
  local host = service(ctx, "monNaming")
  assert(type(host.isActive) == "function", "rival naming host is incomplete")
  local player = service(ctx, "player")
  assert(type(player.setRivalName) == "function", "rival naming requires the player name writer")
  local resolveDefaultName = service(ctx, "rivalDefaultName")
  assert(type(resolveDefaultName) == "function", "rival naming requires the generated default-name resolver")
  ---@cast resolveDefaultName RivalNamingTask.DefaultNameResolver
  return {
    defaultText = resolveDefaultName(),
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
  -- The rival screen has no declined-input result: an empty or all-space
  -- entry stores the generated default name, any other entry stores the typed
  -- name, and the source reports the untouched zero. The name is published
  -- exactly once.
  local name = status.text
  if name:match("^%s*$") ~= nil then
    name = assert(state.defaultText --[[@as string]])
  end
  service(ctx, "player"):setRivalName(name)
  host:close()
  state.closed = true
  return { complete = true, state = state, result = 0 }
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
  if type(state.defaultText) ~= "string" or type(state.currentText) ~= "string" then
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "rival naming task text must be strings", {})
  end
  for _, text in ipairs({ state.defaultText, state.currentText }) do
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
