-- Native trainer controller: binds immutable selection programs to the shared
-- decision protocol. Selection policy follows pret/pokeheartgold
-- src/battle/trainer_ai.c: each owned request is answered exactly once in
-- source order, the reply reuses the DecisionReply shape human controllers
-- answer with, and repeated polls while the batch stays open return the
-- recorded reply without further evaluation. The controller observes only
-- its explicit knowledge projection, never sealed peer state or opposing
-- moves and items, so human pacing and hidden details cannot move its
-- answer. Full move scoring lives in the typed instruction evaluator and
-- runs on explicit knowledge; this binding issues the evaluator default
-- strike per owned actor through the session view, which carries only
-- source-visible information.

---@class HgssTrainerAi
---@field private _program table<string, unknown>
---@field private _passes table<string, boolean>
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

---@param args { program: table<string, unknown>, aiPasses: string[]|nil }
---@return HgssTrainerAi
function HgssTrainerAi.new(args)
  assert(type(args) == "table", "the trainer controller binds a selection program")
  assert(type(args.program) == "table", "the trainer controller binds a selection program")
  assert(type(args.program.instructions) == "table", "bound programs carry their instruction list")
  local passes = {}
  for _, pass in ipairs(args.aiPasses or {}) do
    assert(type(pass) == "string" and pass ~= "", "enabled selection passes name their pass")
    passes[pass] = true
  end
  return setmetatable({ _program = args.program, _passes = passes, _recorded = {} }, HgssTrainerAi)
end

---@param knowledge table<string, unknown> explicit facts plus sealed details the policy never sees
---@return table<string, unknown> detached observation carrying public facts only
function HgssTrainerAi:observe(knowledge)
  assert(type(knowledge) == "table", "observation projects explicit knowledge")
  return {
    active = copyPublic(knowledge.active),
    foe = copyPublic(knowledge.foe),
    reserves = copyValue(knowledge.reserves),
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
---@return integer retargetable position slot addressed by strikes
local function strikeTarget(observation)
  if type(observation) == "table" and type(observation.opponents) == "table" then
    local first = observation.opponents[1]
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
  stream:nextU16("select_action", { controller = request.controller, request = request.requestId })
  local target = strikeTarget(observation)
  local choices = {}
  for _, actor in ipairs(request.actors) do
    assert(type(actor) == "table", "replies answer actor records")
    choices[#choices + 1] = {
      actor = actor,
      kind = "attack",
      payload = { moveSlot = 0, target = { kind = "position", position = target } },
    }
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
