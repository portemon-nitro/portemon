-- Blocking HGSS mon nickname input task.

local Errors = require("libs.errors.src.Errors")
local Utf8Glyphs = require("libs.assets.src.Utf8Glyphs")
local MonsErrors = require("libs.mons.src.errors")
local Mon = require("libs.mons.src.Mon")
local Personality = require("libs.mons.src.gen4.Personality")
local ScriptErrors = require("libs.script.src.errors")

local MonNicknameTask = {}
MonNicknameTask.type = "pokemon_nickname_input"
MonNicknameTask.version = 1

---@class MonNicknameTask.MonService
---@field partyCount fun(self: MonNicknameTask.MonService): integer
---@field partyMon fun(self: MonNicknameTask.MonService, slot: integer): table<string, unknown>
---@field catalog fun(self: MonNicknameTask.MonService): MonCatalog
---@field setNickname fun(self: MonNicknameTask.MonService, slot: integer, nickname: string)

---@class MonNicknameTask.NamingHost
---@field isActive fun(self: MonNicknameTask.NamingHost): boolean
---@field open fun(self: MonNicknameTask.NamingHost, spec: table<string, unknown>)
---@field handleInput fun(self: MonNicknameTask.NamingHost, events: table[])
---@field updateFixed fun(self: MonNicknameTask.NamingHost)
---@field status fun(self: MonNicknameTask.NamingHost): { done: boolean, text: string }
---@field close fun(self: MonNicknameTask.NamingHost)

---@param ctx table<string, unknown>
---@param key "mons"
---@return MonNicknameTask.MonService
---@overload fun(ctx: table<string, unknown>, key: "monNaming"): MonNicknameTask.NamingHost
local function service(ctx, key)
  local value = ctx.services and ctx.services[key]
  if value == nil then
    Errors.raise(ScriptErrors.SCRIPT_SERVICE_MISSING, "mon nickname input requires " .. key, {
      scriptId = ctx.instance and ctx.instance.scriptId,
    })
  end
  return value --[[@as MonNicknameTask.MonService|MonNicknameTask.NamingHost]]
end

local function validateSlot(slot, mons)
  if type(slot) ~= "number" or slot % 1 ~= 0 then
    MonsErrors.raise(MonsErrors.SAVE_INVALID, "mon nickname slot must be an integer", { slot = slot })
  end
  if slot == 255 then
    MonsErrors.raise(MonsErrors.SAVE_INVALID, "Bug Contest nickname storage is unsupported", { slot = slot })
  end
  if slot < 0 or slot >= mons:partyCount() then
    MonsErrors.raise(MonsErrors.SAVE_INVALID, "mon nickname slot is outside the party", { slot = slot })
  end
end

---@param spec table<string, unknown>
---@param ctx table<string, unknown>
---@return table<string, unknown>
function MonNicknameTask.create(spec, ctx)
  assert(type(spec) == "table", "mon nickname task requires a spec")
  local mons = service(ctx, "mons")
  local host = service(ctx, "monNaming")
  assert(type(host.isActive) == "function", "mon naming service is incomplete")
  local slot = spec.slot
  validateSlot(slot, mons)
  assert(type(slot) == "number")
  ---@type { species: string, form: integer, nickname: string?, personality: integer }
  local mon = mons:partyMon(slot)
  local catalog = mons:catalog()
  local species = catalog:species(mon.species)
  local gender = Personality.gender(species.genderRatio, assert(mon.personality, "a party mon carries its personality"))
  local subject = {
    kind = "pokemon",
    species = species.nativeId,
    form = mon.form,
    iconKey = catalog:iconSelection(mon),
    gender = gender,
  }
  local initialText = Mon.displayName(mon, catalog)
  return {
    slot = slot,
    initialText = initialText,
    currentText = "",
    subject = subject,
    opened = false,
    closed = false,
  }
end

---@param state table<string, unknown>
---@param ctx table<string, unknown>
---@return table<string, unknown>
function MonNicknameTask.poll(state, ctx)
  local host = service(ctx, "monNaming")
  assert(type(host.isActive) == "function" and type(host.open) == "function", "mon naming host is incomplete")
  local openedThisPoll = false
  if not host:isActive() then
    host:open({
      currentText = assert(state.currentText --[[@as string]]),
      maxLength = 10,
      subject = assert(state.subject --[[@as table<string, unknown>]]),
    })
    state.opened = true
    state.closed = false
    openedThisPoll = true
  end
  local events = (ctx.input or {}).uiEvents or {}
  assert(type(events) == "table", "mon naming UI events must be a table")
  if #events > 0 then
    host:handleInput(events)
  end
  if not openedThisPoll then
    host:updateFixed()
  end
  local status = host:status()
  assert(type(status) == "table", "active mon naming host publishes status")
  assert(type(status.text) == "string" and type(status.done) == "boolean", "mon naming status is valid")
  state.currentText = status.text
  if not status.done then
    return { complete = false, state = state }
  end
  local result = 1
  if status.text:match("^%s*$") == nil and status.text ~= state.initialText then
    service(ctx, "mons"):setNickname(assert(state.slot --[[@as integer]]), status.text)
    result = 0
  end
  host:close()
  state.closed = true
  return { complete = true, state = state, result = result }
end

---@param state table<string, unknown>
---@param reason string
---@param ctx table<string, unknown>|nil
function MonNicknameTask.cancel(state, reason, ctx)
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
function MonNicknameTask.validate(state)
  if type(state) ~= "table" then
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "mon nickname task state must be a record", {})
  end
  if type(state.slot) ~= "number" or state.slot % 1 ~= 0 or state.slot < 0 or state.slot > 5 then
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "mon nickname slot must be 0..5", {})
  end
  if type(state.initialText) ~= "string" or type(state.currentText) ~= "string" then
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "mon nickname task text must be strings", {})
  end
  for _, text in ipairs({ state.initialText, state.currentText }) do
    local count = 0
    for _ in Utf8Glyphs.iter(text) do
      count = count + 1
    end
    if count > 10 then
      return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "mon nickname task text exceeds ten glyphs", {})
    end
  end
  local subject = state.subject
  if
    type(subject) ~= "table"
    or subject.kind ~= "pokemon"
    or type(subject.species) ~= "number"
    or subject.species < 1
    or subject.species % 1 ~= 0
    or type(subject.form) ~= "number"
    or subject.form < 0
    or subject.form % 1 ~= 0
    or type(subject.iconKey) ~= "string"
    or (subject.gender ~= "male" and subject.gender ~= "female" and subject.gender ~= "genderless")
  then
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "mon nickname subject is invalid", {})
  end
  if type(state.opened) ~= "boolean" or type(state.closed) ~= "boolean" then
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "mon nickname task flags must be booleans", {})
  end
  return nil
end

return MonNicknameTask
