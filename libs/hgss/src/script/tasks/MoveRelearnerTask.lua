-- Blocks the source script while the move reminder / singleton tutor
-- application runs. The task owns the source order around the lesson -- resolve
-- the detached lesson request, open the care child, run it on the fixed tick,
-- park the source outcome -- and the paired result command owns the native
-- 0/255 answer and its one-time consumption. The screen, its presentation lease
-- and the teaching publication belong to the field's care host and its move
-- tutor owner.
--
-- Retail sources (tmp/refs/pokeheartgold): src/scrcmd_move_relearner.c
-- (ScrCmd_MoveRelearnerInit, ScrCmd_MoveTutorInit,
-- ScrCmd_MoveRelearnerGetResult) and src/move_relearner.c
-- (MoveRelearner_GetEligibleLevelUpMoves).

local Errors = require("libs.errors.src.Errors")
local Personality = require("libs.mons.src.gen4.Personality")
local PokemonCareInterface = require("libs.hgss.src.ui.PokemonCareInterface")
local ScriptErrors = require("libs.script.src.errors")

local MoveRelearnerTask = {}
MoveRelearnerTask.type = "move_relearner"
MoveRelearnerTask.version = 1

-- The parked semantic answer the result command reads exactly once.
MoveRelearnerTask.PARKED_KEY = "__move_relearner"

local STAGES = {
  APPLICATION = "application",
  COMPLETE = "complete",
}

---@param ctx table<string, unknown>
---@param key string
---@return table<string, unknown>
local function service(ctx, key)
  local value = ctx.services and ctx.services[key]
  if type(value) ~= "table" then
    Errors.raise(ScriptErrors.SCRIPT_SERVICE_MISSING, "the reminder application requires " .. key, {
      scriptId = ctx.instance and ctx.instance.scriptId,
    })
  end
  return value
end

-- The detached lesson request: the ordered eligible list (the source's own
-- level-up answer, or the tutor's single offered move), the subject's known
-- moves and the party revision the lesson was opened at.
---@param request table<string, unknown>
---@param ctx table<string, unknown>
---@return PokemonCareRelearnerRequest
local function lessonRequest(request, ctx)
  local slot = request.slot
  if type(slot) ~= "number" or slot % 1 ~= 0 or slot < 0 or slot > 5 then
    Errors.raise(ScriptErrors.SCRIPT_INVALID_REFERENCE, "the reminder lesson names a party slot", {
      scriptId = ctx.instance and ctx.instance.scriptId,
      slot = slot,
    })
  end
  local mons = service(ctx, "mons")
  local tutor = service(ctx, "moveTutor")
  local catalog = mons:catalog()
  local mon = mons:partyMon(slot)
  local known = {}
  for _, entry in ipairs(assert(mon.moves, "a stored mon carries its moves")) do
    known[#known + 1] = entry.move
  end
  local moves
  if request.mode == PokemonCareInterface.RELEARNER_MODES.tutor then
    moves = { catalog:moveKeyByNativeId(assert(request.move, "a tutor lesson names its offered move")) }
  else
    assert(request.mode == PokemonCareInterface.RELEARNER_MODES.relearn, "the lesson names its source mode")
    moves = tutor:eligibleRelearnMoves(slot)
    if #moves == 0 then
      Errors.raise(ScriptErrors.SCRIPT_INVALID_REFERENCE, "the reminder lesson has no eligible move", {
        scriptId = ctx.instance and ctx.instance.scriptId,
        slot = slot,
      })
    end
  end
  local species = catalog:species(mon.species)
  -- The main screen draws the subject's own portrait: its generated species
  -- identity, form and the gender/palette its personality derives.
  local gender = Personality.gender(species.genderRatio, assert(mon.personality, "a stored mon carries its personality"))
  if gender ~= "female" then
    gender = "male"
  end
  local subject = {
    speciesKey = assert(species.name, "a catalog species carries its generated identity"),
    form = assert(mon.form, "a stored mon carries its form"),
    gender = gender,
    shiny = Personality.shiny(
      assert(mon.origin.trainerId, "a stored mon carries its trainer identity"),
      mon.personality
    ),
  }
  return PokemonCareInterface.assertRelearnerRequest({
    kind = PokemonCareInterface.KINDS.move_relearner,
    mode = request.mode,
    slot = slot,
    revision = mons:partyRevision(),
    nickname = mon.nickname ~= nil and mon.nickname or species.name,
    moves = moves,
    known = known,
    subject = subject,
  })
end

---@param spec table<string, unknown>
---@param ctx table<string, unknown>
---@return table<string, unknown>
function MoveRelearnerTask.create(spec, ctx)
  assert(type(spec) == "table", "the reminder application requires its request")
  local request = spec.request
  if type(request) ~= "table" then
    Errors.raise(ScriptErrors.SCRIPT_INVALID_REFERENCE, "the reminder application requires its lesson", {
      scriptId = ctx.instance and ctx.instance.scriptId,
    })
  end
  local care = service(ctx, "pokemonCare")
  local lesson = lessonRequest(request, ctx)
  care:open(lesson)
  return { stage = STAGES.APPLICATION, slot = lesson.slot, revision = lesson.revision }
end

-- Parks the source outcome: learned only when the application published the
-- selected move.
---@param state table<string, unknown>
---@param ctx table<string, unknown>
---@param result table<string, unknown>
local function parkResult(state, ctx, result)
  local instance = assert(ctx.instance, "the reminder application runs on a script instance")
  assert(type(instance.locals) == "table", "the script instance carries locals")
  instance.locals[MoveRelearnerTask.PARKED_KEY] = { learned = result.learned == true }
  state.stage = STAGES.COMPLETE
end

---@param state table<string, unknown>
---@param ctx table<string, unknown>
---@return table<string, unknown>
function MoveRelearnerTask.poll(state, ctx)
  if state.stage == STAGES.COMPLETE then
    return { complete = true, state = state }
  end
  assert(state.stage == STAGES.APPLICATION, "unknown reminder application stage")
  local care = service(ctx, "pokemonCare")
  local handle = assert(care:activeHandle(), "the reminder application owns its child")
  care:step(handle, ctx.input)
  local result = care:result(handle)
  if result == nil then
    return { complete = false, state = state }
  end
  parkResult(state, ctx, result)
  care:close(handle)
  return { complete = true, state = state }
end

-- A torn-down script closes the lesson without answering: the parked result
-- stays absent, so its result command faults instead of reporting a move the
-- application never published.
---@param state table<string, unknown>
---@param reason string
---@param ctx table<string, unknown>|nil
function MoveRelearnerTask.cancel(state, reason, ctx)
  state.cancelled = reason
  if ctx == nil or state.stage == STAGES.COMPLETE then
    return
  end
  local care = ctx.services and ctx.services.pokemonCare
  if type(care) == "table" and type(care.isActive) == "function" and care:isActive() then
    care:cancel(reason)
  end
  state.stage = STAGES.COMPLETE
end

---@param state unknown
---@return Errors.Error|nil
function MoveRelearnerTask.validate(state)
  if type(state) ~= "table" then
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "reminder task state must be a record", {})
  end
  local typed = state --[[@as table<string, unknown>]]
  if typed.stage ~= STAGES.APPLICATION and typed.stage ~= STAGES.COMPLETE then
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "reminder task stage is invalid", {})
  end
  if type(typed.slot) ~= "number" or typed.slot % 1 ~= 0 or typed.slot < 0 or typed.slot > 5 then
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "reminder task slot must be 0..5", {})
  end
  if type(typed.revision) ~= "number" or typed.revision % 1 ~= 0 then
    return Errors.new(ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE, "reminder task carries its party revision", {})
  end
  return nil
end

return MoveRelearnerTask
