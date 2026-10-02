-- Native trainer controller: binds compiled AI pass facts to the shared
-- decision protocol. Selection policy follows pret/pokeheartgold
-- src/battle/trainer_ai.c: each owned request is answered exactly once in
-- source order, the reply reuses the DecisionReply shape human controllers
-- answer with, and repeated polls while the batch stays open return the
-- recorded reply without further evaluation. The controller observes only
-- its explicit knowledge projection, never sealed peer state or opposing
-- moves and items, so human pacing and hidden details cannot move its
-- answer. Move scoring runs the enabled native passes through the typed
-- instruction evaluator and returns the real owned move slot; switch and
-- item answers ride the same pass program with the live roster and
-- carried stock. Observations arrive either as the projected semantic
-- shape (which enables pass scoring) or, where fact projection is not
-- wired, as a raw perspective view (which selects uniformly among the
-- owned move slots without scoring). Power-point-exhausted moves are
-- excluded from scoring; with no usable move the strike names the
-- struggle state for the session to resolve.

local NativeAiEvaluator = require("libs.hgss.src.battle.ai.NativeAiEvaluator")

---@class HgssTrainerAi
---@field private _program table<string, unknown>
---@field private _items string[]
---@field private _recorded table<string, table<string, unknown>>
local HgssTrainerAi = {}
HgssTrainerAi.__index = HgssTrainerAi

---@param value unknown
---@return unknown detached copy that cannot reach live state
local function copyValue(value)
  if type(value) ~= "table" then
    return value
  end
  local input = value --[[@as table<unknown, unknown>]]
  local out = {}
  for key, item in pairs(input) do
    out[key] = copyValue(item)
  end
  return out
end

-- Projection fields that never cross into a controller observation, even
-- when a caller nests them inside an otherwise public record.
local SEALED_KEYS = { hidden = true, foeMoves = true, foeItem = true, sealedChoices = true }

---@param record table<string, unknown>|nil
---@return table<string, unknown>|nil public copy with sealed fields removed
local function copyPublic(record)
  if record == nil then
    return nil
  end
  assert(type(record) == "table", "projected records stay records")
  local out = {}
  for key, value in pairs(record) do
    if SEALED_KEYS[key] ~= true then
      out[key] = copyValue(value)
    end
  end
  return out
end

---@param args { aiPasses: string[]|nil, trainerItems: string[]|nil, program: table<string, unknown>|nil }
---@return HgssTrainerAi controller bound to its compiled pass facts
function HgssTrainerAi.new(args)
  assert(type(args) == "table", "the trainer controller binds its pass facts")
  local passes = args.aiPasses or {}
  assert(type(passes) == "table", "enabled selection passes arrive as a list")
  local items = args.trainerItems or {}
  assert(type(items) == "table", "carried trainer items arrive as a list")
  local stock = {}
  for index, item in ipairs(items) do
    assert(type(item) == "string" and item ~= "", "carried trainer item " .. index .. " names its item")
    stock[#stock + 1] = item
  end
  -- A supplied selection program is inert: production compilers publish
  -- pass facts, never programs, and decisions run the compiled passes.
  local program = NativeAiEvaluator.compilePassProgram(passes)
  return setmetatable({ _program = program, _items = stock, _recorded = {} }, HgssTrainerAi)
end

---@param knowledge table<string, unknown> explicit facts plus sealed details the policy never sees
---@return table<string, unknown> detached observation carrying public facts only
function HgssTrainerAi:observe(knowledge)
  assert(type(knowledge) == "table", "observation projects explicit knowledge")
  return {
    active = copyPublic(knowledge.active),
    foe = copyPublic(knowledge.foe),
    reserves = copyValue(knowledge.reserves),
    opponents = copyValue(knowledge.opponents),
    actives = copyValue(knowledge.actives),
  }
end

---@param request table<string, unknown> pending decision request owned by this controller
---@return string cache identity binding the reply to its request and epoch
local function replyKey(request)
  assert(type(request) == "table", "controller replies answer pending requests")
  assert(
    type(request.requestId) == "number" and request.requestId % 1 == 0 and request.requestId >= 1,
    "controller replies name a positive request"
  )
  assert(
    type(request.epoch) == "number" and request.epoch % 1 == 0 and request.epoch >= 0,
    "controller replies carry a non-negative batch epoch"
  )
  assert(type(request.controller) == "string" and request.controller ~= "", "replies name their controller")
  assert(type(request.actors) == "table" and #request.actors > 0, "replies answer at least one actor")
  return request.requestId .. ":" .. request.epoch .. ":" .. request.controller
end

---@param observation table<string, unknown> controller observation for this request
---@param index integer|nil one-based actor position under choice
---@return integer retargetable position slot addressed by strikes
local function strikeTarget(observation, index)
  if
    type(observation) == "table"
    and type(observation.foe) == "table"
    and type(observation.foe.position) == "number"
    and observation.foe.position % 1 == 0
    and observation.foe.position >= 1
  then
    return observation.foe.position
  end
  if type(observation) == "table" and type(observation.opponents) == "table" then
    local first = observation.opponents[index or 1]
    if
      type(first) == "table"
      and type(first.position) == "number"
      and first.position % 1 == 0
      and first.position >= 1
    then
      return first.position
    end
  end
  return 1
end

---@param foeTypes table<integer, string>|nil opposing types under exposure
---@param candidateTypes table<integer, string>|nil candidate types under exposure
---@return number combined incoming multiplier against the candidate
local function exposure(foeTypes, candidateTypes)
  local total = 1
  for _, foeType in ipairs(foeTypes or {}) do
    total = total * NativeAiEvaluator.effectiveness(foeType, candidateTypes or {})
  end
  return total
end

---@param request table<string, unknown> pending decision request owned by this controller
---@param view table<string, unknown> raw perspective view without fact projection
---@param stream table<string, unknown> battle stream owned by the caller
---@return table[] one unscored strike per owned actor from the owned move count
function HgssTrainerAi:_unscoredChoices(request, view, stream)
  local choices = {}
  for index, actor in ipairs(request.actors) do
    assert(type(actor) == "table", "replies answer actor records")
    local slots = 1
    for _, entry in ipairs(view.combatants) do
      if
        type(entry) == "table"
        and type(entry.combatant) == "number"
        and entry.combatant == actor.combatant
        and type(entry.mon) == "table"
        and type(entry.mon.moves) == "table"
        and #entry.mon.moves >= 1
      then
        slots = #entry.mon.moves
      end
    end
    local draw = stream:nextU16("unscored_strike", { controller = request.controller, request = request.requestId })
    choices[#choices + 1] = {
      actor = actor,
      kind = "attack",
      payload = { moveSlot = draw % slots, target = { kind = "position", position = strikeTarget(view, index) } },
    }
  end
  return choices
end

---@param active table<string, unknown> acting combatant entry under choice
---@param foe table<string, unknown> opposing combatant entry under choice
---@param stream table<string, unknown> battle stream owned by the caller
---@return table<string, unknown>? bag choice with its carried item, nil when no healing applies
function HgssTrainerAi:_itemChoice(active, foe, stream)
  if #self._items == 0 then
    return nil
  end
  local bag = {}
  for _, item in ipairs(self._items) do
    bag[item] = 1
  end
  local choice = NativeAiEvaluator.chooseItem(
    self._program,
    { active = active, foe = foe },
    stream,
    { trainerItems = self._items, bag = bag }
  )
  if choice.item == nil then
    return nil
  end
  return { kind = "item", payload = { item = choice.item } }
end

---@param active table<string, unknown> acting combatant entry under choice
---@param foe table<string, unknown> opposing combatant entry under choice
---@param reserves table<integer, table<string, unknown>> benched roster entries under choice
---@param stream table<string, unknown> battle stream owned by the caller
---@return table<string, unknown>? exchange choice with its living replacement, nil when holding is sound
function HgssTrainerAi:_switchChoice(active, foe, reserves, stream)
  local foeTypes = nil
  if type(foe) == "table" then
    foeTypes = foe.types
  end
  local activeTypes = nil
  if type(active) == "table" then
    activeTypes = active.types
  end
  local held = exposure(foeTypes, activeTypes)
  local answered = false
  for _, reserve in ipairs(reserves) do
    if type(reserve) == "table" and (reserve.hp or 0) > 0 then
      if exposure(foeTypes, reserve.types) < held then
        answered = true
        break
      end
    end
  end
  if answered ~= true then
    return nil
  end
  local choice =
    NativeAiEvaluator.chooseSwitch(self._program, { active = active, foe = foe, reserves = reserves }, stream)
  return { kind = "switch", payload = { replacement = choice.replacement } }
end

---@param active table<string, unknown> acting combatant entry under choice
---@param foe table<string, unknown> opposing combatant entry under choice
---@param stream table<string, unknown> battle stream owned by the caller
---@return integer zero-based move slot owned by the acting combatant
function HgssTrainerAi:_strikeSlot(active, foe, stream)
  assert(type(active.moves) == "table", "strike selection lists the candidate moves")
  local usable = {}
  local slots = {}
  for index, move in ipairs(active.moves) do
    assert(type(move) == "table" and type(move.key) == "string", "candidate moves name their move key")
    if type(move.pp) ~= "number" or move.pp > 0 then
      usable[#usable + 1] = move
      slots[#slots + 1] = index - 1
    end
  end
  if #usable == 0 then
    -- No usable move names the struggle state for the session to resolve.
    return 0
  end
  local scored = copyValue(active)
  scored.moves = usable
  local decided = NativeAiEvaluator.evaluate(self._program, { active = scored, foe = foe }, stream)
  for position, move in ipairs(usable) do
    if move.key == decided.action then
      return slots[position]
    end
  end
  assert(false, "scoring answers one of its candidate moves")
  return 0
end

--- Later actors in one batch answer with strikes only: the doubles pass
--- flow that would score their switches and items is not projected here.
---@param request table<string, unknown> pending decision request owned by this controller
---@param observation table<string, unknown> projected semantic observation for this request
---@param stream table<string, unknown> battle stream owned by the caller
---@return table[] one pass-driven choice per owned actor
function HgssTrainerAi:_passChoices(request, observation, stream)
  assert(type(observation.active) == "table", "pass decisions read their acting combatant")
  assert(type(observation.foe) == "table", "pass decisions read their opposing combatant")
  local reserves = observation.reserves or {}
  assert(type(reserves) == "table", "pass decisions list their benched reserves")
  local choices = {}
  for index, actor in ipairs(request.actors) do
    assert(type(actor) == "table", "replies answer actor records")
    local active = observation.active
    if index > 1 then
      if type(observation.actives) == "table" and type(observation.actives[index]) == "table" then
        active = observation.actives[index]
      end
    end
    local target = { kind = "position", position = strikeTarget(observation, index) }
    local choice = nil
    if index == 1 then
      choice = self:_itemChoice(active, observation.foe, stream)
        or self:_switchChoice(active, observation.foe, reserves, stream)
    end
    if choice == nil then
      choice = {
        kind = "attack",
        payload = { moveSlot = self:_strikeSlot(active, observation.foe, stream), target = target },
      }
    end
    choice.actor = actor
    choices[#choices + 1] = choice
  end
  return choices
end

---@param request table<string, unknown> pending decision request owned by this controller
---@param observation table<string, unknown> controller observation for this request
---@param stream table<string, unknown> battle stream owned by the caller
---@return table<string, unknown> reply in the shared decision shape
function HgssTrainerAi:decide(request, observation, stream)
  assert(type(observation) == "table", "decisions read their controller observation")
  assert(type(stream) == "table" and type(stream.nextU16) == "function", "decisions draw from the battle stream")
  local key = replyKey(request)
  local recorded = self._recorded[key]
  if recorded ~= nil then
    return recorded
  end
  local choices = nil
  if type(observation.combatants) == "table" and observation.active == nil then
    choices = self:_unscoredChoices(request, observation, stream)
  else
    choices = self:_passChoices(request, observation, stream)
  end
  local reply = {
    requestId = request.requestId,
    epoch = request.epoch,
    controller = request.controller,
    choices = choices,
  }
  self._recorded[key] = reply
  return reply
end

return HgssTrainerAi
