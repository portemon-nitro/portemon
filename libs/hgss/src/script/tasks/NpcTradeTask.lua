-- Blocks the source script while the app71 exchange sequence runs. The task owns
-- the source order around the scene: the exchange receipt commits, the field
-- fades out, the overworld leaves, the care host runs the sequence, the field is
-- restored, the field fades back in, and only then does the script continue.
-- Only the source stage and the detached subject pair live in the task state;
-- the live child and the presentation lease belong to the field's care host.
--
-- The receipt is committed before the fade, exactly like the source task's
-- NPCTrade_ReceiveMonToSlot inside NPC_TRADE_TASK_CREATE_ANIM, so a failed or
-- cancelled presentation keeps the received record and never exchanges twice.
-- Retail sources (tmp/refs/pokeheartgold): src/npc_trade_task.c
-- (Task_NPCTrade and its state order).

local Errors = require("libs.errors.src.Errors")
local Personality = require("libs.mons.src.gen4.Personality")
local PokemonCareInterface = require("libs.hgss.src.ui.PokemonCareInterface")
local ScriptErrors = require("libs.script.src.errors")

---@class NpcTradeSubjectRecord
---@field species integer
---@field form integer
---@field nickname string
---@field speciesKey string
---@field gender "male"|"female"
---@field shiny boolean

local NpcTradeTask = {}
NpcTradeTask.type = "npc_trade"
NpcTradeTask.version = 1

-- The standard field fade the source's PaletteFadeUntilFinished and
-- CallTask_FadeFromBlack spend.
local FADE_SPEC = { color = "black", duration = 6, speed = 1 }

local STAGES = {
  FADE_OUT = "fade_out",
  LEAVE = "leave",
  APPLICATION = "application",
  RESTORE = "restore",
  FADE_IN = "fade_in",
  COMPLETE = "complete",
}

---@param ctx table<string, unknown>
---@param key string
---@return table<string, unknown>
local function service(ctx, key)
  local value = ctx.services and ctx.services[key]
  if type(value) ~= "table" then
    Errors.raise(ScriptErrors.SCRIPT_SERVICE_MISSING, "the trade application requires " .. key, {
      scriptId = ctx.instance and ctx.instance.scriptId,
    })
  end
  return value
end

-- The scene presents detached subjects: the species identity it cries and the
-- name the printed lines substitute.
---@param catalog table<string, unknown>
---@param mon table<string, unknown>
---@return NpcTradeSubjectRecord
local function subject(catalog, mon)
  local species = catalog:species(mon.species)
  -- The source buffers the record's own nickname, or its species name when the
  -- record carries none (BufferBoxMonNickname).
  local name = mon.nickname ~= nil and mon.nickname or species.name
  assert(type(name) == "string" and name ~= "", "a trade subject carries its display name")
  -- The source selects the picture through the record's gender and its own
  -- origin identity (GetBoxmonSpriteCharAndPlttNarcIds + the personality's
  -- shiny test); a genderless record reads the male portrait members.
  local gender = Personality.gender(species.genderRatio, mon.personality)
  if gender ~= "female" then
    gender = "male"
  end
  return {
    species = assert(species.nativeId, "a trade subject carries its native species identity"),
    form = mon.form,
    nickname = name,
    speciesKey = assert(species.name, "a trade subject carries its generated species identity"),
    gender = gender,
    shiny = Personality.shiny(assert(mon.origin.trainerId, "a trade subject carries its trainer identity"), mon.personality),
  }
end

-- The source time-of-day backdrop: morning and day share the first surface,
-- evening the second and night the third (NPCTrade_CreateTradeAnim).
---@param ctx table<string, unknown>
---@return string
local function backdropFor(ctx)
  local timeOfDay = service(ctx, "timeOfDay")
  local code = timeOfDay:currentCode()
  if code == 0 or code == 1 then
    return PokemonCareInterface.TRADE_BACKDROPS.day
  end
  if code == 2 then
    return PokemonCareInterface.TRADE_BACKDROPS.evening
  end
  return PokemonCareInterface.TRADE_BACKDROPS.night
end

-- The exchange request the scene opens with, beside the settled receipt.
---@param subjects { outgoing: table<string, unknown>, incoming: table<string, unknown> }
---@param ctx table<string, unknown>
---@return PokemonCareTradeRequest
local function tradeRequest(subjects, ctx)
  local catalog = service(ctx, "mons"):catalog()
  return PokemonCareInterface.assertTradeRequest({
    kind = PokemonCareInterface.KINDS.trade,
    outgoing = subject(catalog, subjects.outgoing),
    incoming = subject(catalog, subjects.incoming),
    playerName = subjects.incoming.origin.trainerName,
    backdrop = backdropFor(ctx),
  })
end

---@param spec table<string, unknown>
---@param ctx table<string, unknown>
---@return table<string, unknown>
function NpcTradeTask.create(spec, ctx)
  assert(type(spec) == "table", "the trade application requires its request")
  local tradeId = spec.tradeId
  local slot = spec.slot
  if type(tradeId) ~= "number" or tradeId % 1 ~= 0 or tradeId < 0 then
    Errors.raise(ScriptErrors.SCRIPT_INVALID_REFERENCE, "the trade application needs its trade identity", {
      scriptId = ctx.instance and ctx.instance.scriptId,
      tradeId = tradeId,
    })
  end
  if type(slot) ~= "number" or slot % 1 ~= 0 or slot < 0 or slot > 5 then
    Errors.raise(ScriptErrors.SCRIPT_INVALID_REFERENCE, "the trade application needs a party position", {
      scriptId = ctx.instance and ctx.instance.scriptId,
      slot = slot,
    })
  end
  service(ctx, "pokemonCare")
  -- The source commits the receipt before the fade: the created record replaces
  -- the selected slot with its Dex and score receipt here, once.
  local subjects = service(ctx, "npcTrade"):exchange(tradeId, slot)
  assert(type(subjects) == "table", "the exchange answers its detached subject pair")
  return {
    stage = STAGES.FADE_OUT,
    tradeId = tradeId,
    slot = slot,
    request = tradeRequest(subjects, ctx),
    fadeStarted = false,
    closed = false,
  }
end

---@param screen table<string, unknown>
---@param direction "out"|"in"
local function startFade(screen, direction)
  screen:startFade({
    direction = direction,
    color = FADE_SPEC.color,
    duration = FADE_SPEC.duration,
    speed = FADE_SPEC.speed,
    screenScope = "main",
  })
end

-- Opens the sequence child once the field left the overworld. The host owns the
-- child; the scene advances on this poll and never on drawing.
---@param state table<string, unknown>
---@param ctx table<string, unknown>
local function openApplication(state, ctx)
  service(ctx, "pokemonCare"):open(state.request)
  state.stage = STAGES.APPLICATION
end

---@param state table<string, unknown>
---@param ctx table<string, unknown>
local function pollApplication(state, ctx)
  local care = service(ctx, "pokemonCare")
  local handle = assert(care:activeHandle(), "the trade application owns its child")
  care:step(handle, ctx.input)
  local result = care:result(handle)
  if result == nil then
    return { complete = false, state = state }
  end
  care:close(handle)
  state.closed = true
  state.stage = STAGES.RESTORE
  return { complete = false, state = state }
end

---@param state table<string, unknown>
---@param ctx table<string, unknown>
---@return table<string, unknown>
function NpcTradeTask.poll(state, ctx)
  local stage = state.stage
  if stage == STAGES.APPLICATION then
    return pollApplication(state, ctx)
  end
  if stage == STAGES.FADE_OUT then
    local screen = service(ctx, "screen")
    if state.fadeStarted ~= true then
      startFade(screen, "out")
      state.fadeStarted = true
      return { complete = false, state = state }
    end
    if not screen:fadeDone() then
      return { complete = false, state = state }
    end
    state.fadeStarted = false
    state.stage = STAGES.LEAVE
    return { complete = false, state = state }
  end
  if stage == STAGES.LEAVE then
    service(ctx, "overworld"):leave()
    openApplication(state, ctx)
    return { complete = false, state = state }
  end
  if stage == STAGES.RESTORE then
    service(ctx, "overworld"):restore()
    state.stage = STAGES.FADE_IN
    return { complete = false, state = state }
  end
  if stage == STAGES.FADE_IN then
    local screen = service(ctx, "screen")
    if state.fadeStarted ~= true then
      startFade(screen, "in")
      state.fadeStarted = true
      return { complete = false, state = state }
    end
    if not screen:fadeDone() then
      return { complete = false, state = state }
    end
    state.fadeStarted = false
    state.stage = STAGES.COMPLETE
    return { complete = false, state = state }
  end
  assert(stage == STAGES.COMPLETE, "unknown trade stage")
  state.stage = STAGES.COMPLETE
  return { complete = true, state = state, result = nil }
end

-- An interrupted application keeps the receipt it already committed and still
-- returns the field: the exchanged record, its Dex entry and its score are
-- final, so the torn-down child must not leave the overworld absent or the
-- sequence half-owned.
---@param state table<string, unknown>
---@param reason string
---@param ctx table<string, unknown>|nil
function NpcTradeTask.cancel(state, reason, ctx)
  state.cancelled = reason
  if ctx == nil or state.stage == STAGES.COMPLETE then
    return
  end
  local care = ctx.services and ctx.services.pokemonCare
  if type(care) == "table" and type(care.isActive) == "function" and care:isActive() then
    care:cancel(reason)
    state.closed = true
  end
  local overworld = ctx.services and ctx.services.overworld
  if type(overworld) == "table" and type(overworld.phase) == "function" then
    local phase = overworld:phase()
    if phase == "leaving" then
      overworld:updateFixed()
      phase = overworld:phase()
    end
    if phase == "absent" then
      overworld:restore()
    end
  end
  state.stage = STAGES.COMPLETE
end

---@param state unknown
---@return Errors.Error|nil
function NpcTradeTask.validate(state)
  if type(state) ~= "table" then
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "trade task state must be a record", {})
  end
  local typed = state --[[@as table<string, unknown>]]
  local known = false
  for _, stage in pairs(STAGES) do
    if typed.stage == stage then
      known = true
    end
  end
  if not known then
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "trade task stage is invalid", {})
  end
  if type(typed.tradeId) ~= "number" or typed.tradeId % 1 ~= 0 or typed.tradeId < 0 then
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "trade task identity must be a source trade id", {})
  end
  if type(typed.slot) ~= "number" or typed.slot % 1 ~= 0 or typed.slot < 0 or typed.slot > 5 then
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "trade task slot must be 0..5", {})
  end
  if type(typed.request) ~= "table" then
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "trade task carries its scene request", {})
  end
  if type(typed.fadeStarted) ~= "boolean" or type(typed.closed) ~= "boolean" then
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "trade task flags must be booleans", {})
  end
  return nil
end

return NpcTradeTask
