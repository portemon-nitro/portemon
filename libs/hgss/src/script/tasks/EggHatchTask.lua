-- Blocks the source script while the care hatch application runs. The task
-- owns the source order around the scene: the field leaves the overworld, the
-- care host runs the scene, the hatch receipt publishes, the optional naming
-- screen reads the player's name, and the field is restored before the script
-- continues. Only the source stage lives in the task state; the live child and
-- the presentation lease belong to the field's care host.
--
-- A cancelled or interrupted application still publishes the receipt exactly
-- once: the hatch claim already converted the mon and spent its statistic, so
-- the payment cannot be replayed and the record must not stay half-hatched.
-- Retail sources (tmp/refs/pokeheartgold): src/hatch_egg_task.c
-- (Task_HatchEggInParty and its state order).

local Errors = require("libs.errors.src.Errors")
local Personality = require("libs.mons.src.gen4.Personality")
local ScriptErrors = require("libs.script.src.errors")

local EggHatchTask = {}
EggHatchTask.type = "egg_hatch"
EggHatchTask.version = 1

-- NAME_SCREEN_POKEMON's glyph limit (POKEMON_NAME_LENGTH).
local NICKNAME_LENGTH = 10

local STAGES = {
  APPLICATION = "application",
  NAMING = "naming",
  RESTORE = "restore",
  COMPLETE = "complete",
}

---@param ctx table<string, unknown>
---@param key string
---@return table<string, unknown>
local function service(ctx, key)
  local value = ctx.services and ctx.services[key]
  if type(value) ~= "table" then
    Errors.raise(ScriptErrors.SCRIPT_SERVICE_MISSING, "the hatch application requires " .. key, {
      scriptId = ctx.instance and ctx.instance.scriptId,
    })
  end
  return value
end

-- The naming subject is the hatched record itself: the species it carries, its
-- form and icon, and the gender its personality derives.
---@param mons table<string, unknown>
---@param slot0 integer
---@return { kind: string, species: integer, form: integer, iconKey: string, gender: string }, string
local function namingSubject(mons, slot0)
  local mon = assert(mons:partyMon(slot0), "the hatched record occupies its slot")
  local catalog = mons:catalog()
  local species = catalog:species(mon.species)
  local gender = Personality.gender(species.genderRatio, assert(mon.personality, "a hatched record carries its personality"))
  return {
    kind = "pokemon",
    species = species.nativeId,
    form = mon.form,
    iconKey = catalog:iconSelection(mon),
    gender = gender,
  }, mon.species
end

---@param spec table<string, unknown>
---@param ctx table<string, unknown>
---@return table<string, unknown>
function EggHatchTask.create(spec, ctx)
  assert(type(spec) == "table", "the hatch application requires its request")
  local care = service(ctx, "pokemonCare")
  local daycare = service(ctx, "daycare")
  local hatch = daycare:activeHatch()
  if hatch == nil then
    Errors.raise(ScriptErrors.FEATURE_UNAVAILABLE, "no Day Care egg is waiting for its hatch application", {
      scriptId = ctx.instance and ctx.instance.scriptId,
    })
  end
  assert(type(hatch) == "table", "the active hatch claim publishes its subject")
  local overworld = service(ctx, "overworld")
  overworld:leave()
  local subject = assert(hatch.subject, "the hatch claim carries its subject")
  care:open({
    kind = "hatch",
    variant = assert(subject.variant, "the hatch subject names its scene"),
    species = assert(subject.speciesId, "the hatch subject carries its native species identity"),
    form = assert(subject.form, "the hatch subject carries its form"),
    nickname = assert(subject.nickname, "the hatch subject carries its default name"),
  })
  return {
    stage = STAGES.APPLICATION,
    slot = assert(hatch.slot, "the hatch claim carries its party slot"),
    namingOpened = false,
    finished = false,
  }
end

-- Publishes the hatch receipt exactly once: the scene's own answer is the
-- source's UPDATE_MON_INFO moment, so the memo, the Dex fact and the original
-- gift call land before the naming screen and before the field reopens.
---@param state table<string, unknown>
---@param ctx table<string, unknown>
local function finishReceipt(state, ctx)
  if state.finished then
    return
  end
  service(ctx, "daycare"):finishHatch()
  state.finished = true
end

---@param state table<string, unknown>
---@param ctx table<string, unknown>
local function closeChild(state, ctx, reason)
  local care = ctx.services and ctx.services.pokemonCare
  if type(care) == "table" and care:isActive() then
    care:cancel(reason)
  end
  state.stage = STAGES.COMPLETE
end

---@param state table<string, unknown>
---@param ctx table<string, unknown>
---@return table<string, unknown>
local function pollApplication(state, ctx)
  local care = service(ctx, "pokemonCare")
  local handle = assert(care:activeHandle(), "the hatch application owns its child")
  care:step(handle, ctx.input)
  local result = care:result(handle)
  if result == nil then
    return { complete = false, state = state }
  end
  care:close(handle)
  finishReceipt(state, ctx)
  if result.wantToName then
    state.stage = STAGES.NAMING
    return { complete = false, state = state }
  end
  state.stage = STAGES.RESTORE
  return { complete = false, state = state }
end

---@param state table<string, unknown>
---@param ctx table<string, unknown>
---@return table<string, unknown>
local function pollNaming(state, ctx)
  local naming = service(ctx, "monNaming")
  local mons = service(ctx, "mons")
  local slot0 = assert(state.slot --[[@as integer]], "the hatch names its own party slot")
  if state.namingOpened ~= true then
    local subject = namingSubject(mons, slot0)
    naming:open({
      currentText = "",
      maxLength = NICKNAME_LENGTH,
      subject = subject,
    })
    state.namingOpened = true
    return { complete = false, state = state }
  end
  local input = ctx.input or {}
  local events = input.uiEvents or {}
  assert(type(events) == "table", "the naming screen consumes scheduler UI events")
  if #events > 0 then
    naming:handleInput(events)
  else
    naming:updateFixed()
  end
  local status = naming:status()
  assert(type(status) == "table", "the active naming screen publishes its status")
  if not status.done then
    return { complete = false, state = state }
  end
  -- The source keeps the default species name when the player submits nothing.
  if type(status.text) == "string" and status.text:match("^%s*$") == nil then
    mons:setNickname(slot0, status.text)
  end
  naming:close()
  state.stage = STAGES.RESTORE
  return { complete = false, state = state }
end

---@param state table<string, unknown>
---@param ctx table<string, unknown>
---@return table<string, unknown>
function EggHatchTask.poll(state, ctx)
  if state.stage == STAGES.APPLICATION then
    return pollApplication(state, ctx)
  end
  if state.stage == STAGES.NAMING then
    return pollNaming(state, ctx)
  end
  assert(state.stage == STAGES.RESTORE or state.stage == STAGES.COMPLETE, "unknown hatch stage")
  service(ctx, "daycare"):releaseHatch()
  service(ctx, "overworld"):restore()
  state.stage = STAGES.COMPLETE
  return { complete = true, state = state, result = nil }
end

-- An interrupted application still finishes its receipt once and restores the
-- field: the converted mon and the spent count are already committed, so the
-- torn-down child must not leave the record half-published or the overworld
-- absent.
---@param state table<string, unknown>
---@param reason string
---@param ctx table<string, unknown>|nil
function EggHatchTask.cancel(state, reason, ctx)
  state.cancelled = reason
  if ctx == nil or state.stage == STAGES.COMPLETE then
    return
  end
  finishReceipt(state, ctx)
  closeChild(state, ctx, reason)
  local daycare = ctx.services and ctx.services.daycare
  if type(daycare) == "table" and type(daycare.releaseHatch) == "function" then
    daycare:releaseHatch()
  end
  local overworld = ctx.services and ctx.services.overworld
  if type(overworld) == "table" then
    local phase = overworld:phase()
    if phase == "absent" or phase == "leaving" then
      if phase == "leaving" then
        overworld:updateFixed()
      end
      overworld:restore()
    end
  end
end

---@param state unknown
---@return Errors.Error|nil
function EggHatchTask.validate(state)
  if type(state) ~= "table" then
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "hatch task state must be a record", {})
  end
  local typed = state --[[@as table<string, unknown>]]
  if
    typed.stage ~= STAGES.APPLICATION
    and typed.stage ~= STAGES.NAMING
    and typed.stage ~= STAGES.RESTORE
    and typed.stage ~= STAGES.COMPLETE
  then
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "hatch task stage is invalid", {})
  end
  if type(typed.slot) ~= "number" or typed.slot % 1 ~= 0 or typed.slot < 0 or typed.slot > 5 then
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "hatch task slot must be 0..5", {})
  end
  if type(typed.namingOpened) ~= "boolean" or type(typed.finished) ~= "boolean" then
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "hatch task flags must be booleans", {})
  end
  return nil
end

return EggHatchTask
