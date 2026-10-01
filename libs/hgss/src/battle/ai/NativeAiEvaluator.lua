-- Typed evaluator for the native trainer selection instructions. The readable
-- selection entry points live in pret/pokeheartgold src/battle/trainer_ai.c
-- (ov10_0221BE20 initializes per-move scores, ov10_0221BEF4 dispatches into
-- the singles/doubles selectors ov10_0221BF44/ov10_0221C038), while the
-- per-move scoring passes themselves execute inside
-- asm/overlay_10_trainer_ai.s. The assembly branches are normalized here
-- into a small closed set of semantic instructions; this evaluator executes
-- exactly that set. It is not the battle move virtual machine and not a
-- general scripting layer: every instruction draws from the battle stream
-- with its own source label, unknown instructions fail instead of falling
-- back to a legal random move, and damage previews never touch the stream.

local Errors = require("libs.errors.src.Errors")

---@class NativeAiEvaluator
local NativeAiEvaluator = {}

-- Closed instruction vocabulary. Each entry names one normalized scoring
-- pass: matchup scoring estimates type effectiveness with same-type attack
-- bonus, residual-risk scoring withholds points from scoreless or exposing
-- attempts, switch/item consideration marks the branches that route into
-- reserve and bag selection, and the tiebreak pass settles exact score ties
-- from the native stream.
local INSTRUCTIONS = {
  "score_matchup",
  "score_residual_risk",
  "consider_switch",
  "consider_item",
  "roll_tiebreak",
}

local KNOWN = {}
for _, op in ipairs(INSTRUCTIONS) do
  KNOWN[op] = true
end

-- Generation-IV attack/defense multipliers used only for selection scoring.
-- The authoritative battle chart stays with the combat arithmetic owner;
-- this local table exists because the evaluator must score from an explicit
-- knowledge projection without importing battle execution. Missing pairs are
-- neutral.
local EFFECTIVENESS = {
  normal = { rock = 0.5, ghost = 0, steel = 0.5 },
  fire = { fire = 0.5, water = 0.5, grass = 2, ice = 2, bug = 2, rock = 0.5, dragon = 0.5, steel = 2 },
  water = { fire = 2, water = 0.5, grass = 0.5, ground = 2, rock = 2, dragon = 0.5 },
  electric = { water = 2, electric = 0.5, grass = 0.5, ground = 0, flying = 2, dragon = 0.5 },
  grass = {
    fire = 0.5,
    water = 2,
    grass = 0.5,
    poison = 0.5,
    ground = 2,
    flying = 0.5,
    bug = 0.5,
    rock = 2,
    dragon = 0.5,
    steel = 0.5,
  },
  ice = { fire = 0.5, water = 0.5, grass = 2, ice = 0.5, ground = 2, flying = 2, dragon = 2, steel = 0.5 },
  fighting = {
    normal = 2,
    ice = 2,
    poison = 0.5,
    flying = 0.5,
    psychic = 0.5,
    bug = 0.5,
    rock = 2,
    ghost = 0,
    dark = 2,
    steel = 2,
  },
  poison = { grass = 2, poison = 0.5, ground = 0.5, rock = 0.5, ghost = 0.5, steel = 0 },
  ground = { fire = 2, electric = 2, grass = 0.5, poison = 2, flying = 0, bug = 0.5, rock = 2, steel = 2 },
  flying = { electric = 0.5, grass = 2, fighting = 2, bug = 2, rock = 0.5, steel = 0.5 },
  psychic = { fighting = 2, poison = 2, psychic = 0.5, dark = 0, steel = 0.5 },
  bug = {
    fire = 0.5,
    grass = 2,
    fighting = 0.5,
    poison = 0.5,
    flying = 0.5,
    psychic = 2,
    ghost = 0.5,
    dark = 2,
    steel = 0.5,
  },
  rock = { fire = 2, ice = 2, fighting = 0.5, ground = 0.5, flying = 2, bug = 2, steel = 0.5 },
  ghost = { normal = 0, psychic = 2, ghost = 2, dark = 0.5, steel = 0.5 },
  dragon = { dragon = 2, steel = 0.5 },
  dark = { fighting = 0.5, psychic = 2, ghost = 2, dark = 0.5, steel = 0.5 },
  steel = { fire = 0.5, water = 0.5, electric = 0.5, ice = 2, rock = 2, steel = 0.5 },
}

---@param moveType string
---@param defenderTypes table<integer, string>
---@return number combined multiplier across every defender type
local function effectiveness(moveType, defenderTypes)
  local rows = EFFECTIVENESS[moveType]
  if rows == nil then
    return 1
  end
  local total = 1
  for _, defender in ipairs(defenderTypes) do
    local factor = rows[defender]
    if factor ~= nil then
      total = total * factor
    end
  end
  return total
end

---@param moveType string
---@param userTypes table<integer, string>
---@return number same-type attack bonus
local function stab(moveType, userTypes)
  for _, userType in ipairs(userTypes) do
    if userType == moveType then
      return 1.5
    end
  end
  return 1
end

---@return string[] the closed instruction set in canonical order
function NativeAiEvaluator.supportedInstructions()
  local out = {}
  for _, op in ipairs(INSTRUCTIONS) do
    out[#out + 1] = op
  end
  return out
end

---@param program table<string, unknown> selection program under evaluation
local function assertProgram(program)
  assert(type(program) == "table", "selection programs are records")
  assert(type(program.instructions) == "table", "selection programs carry their instruction list")
  for index, instruction in ipairs(program.instructions) do
    assert(type(instruction) == "table", "selection instruction " .. index .. " is a record")
    if KNOWN[instruction.op] ~= true then
      Errors.raise("AI_UNKNOWN_INSTRUCTION", "selection programs reject instructions outside the closed set", {
        op = tostring(instruction.op),
        index = index,
      })
    end
  end
end

---@param knowledge table<string, unknown> explicit knowledge projection for this request
local function assertKnowledge(knowledge)
  assert(type(knowledge) == "table", "selection reads an explicit knowledge projection")
  assert(type(knowledge.active) == "table", "knowledge names the acting combatant")
  assert(type(knowledge.active.moves) == "table", "knowledge lists the candidate moves")
  assert(type(knowledge.foe) == "table", "knowledge names the opposing combatant")
end

---@param knowledge table<string, unknown>
---@return table[] one numeric score entry per candidate move in input order
local function blankScores(knowledge)
  local scores = {}
  for _, move in ipairs(knowledge.active.moves) do
    assert(type(move) == "table" and type(move.key) == "string", "candidate moves name their move key")
    scores[#scores + 1] = { move = move.key, score = 0 }
  end
  return scores
end

---@param knowledge table<string, unknown>
---@param index integer
---@return number matchup estimate for the indexed candidate
local function matchupScore(knowledge, index)
  local move = knowledge.active.moves[index]
  local power = move.power or 0
  if power <= 0 then
    return 0
  end
  local userTypes = knowledge.active.types or {}
  local foeTypes = knowledge.foe.types or {}
  return power * stab(move.moveType, userTypes) * effectiveness(move.moveType, foeTypes)
end

---@param op string
---@param scores table[]
---@param knowledge table<string, unknown>
---@param stream table<string, unknown> battle stream owned by the caller
---@return integer|nil tiebreak draw when this pass settles ties
local function applyInstruction(op, scores, knowledge, stream)
  local draw = stream:nextU16(op, { instruction = op })
  if op == "score_matchup" then
    for index in ipairs(scores) do
      scores[index].score = matchupScore(knowledge, index)
    end
  elseif op == "score_residual_risk" then
    local hp = knowledge.active.hp or 0
    local maxHp = knowledge.active.maxHp or 0
    if maxHp > 0 and hp * 2 < maxHp then
      for index in ipairs(scores) do
        if (knowledge.active.moves[index].power or 0) <= 0 then
          scores[index].score = scores[index].score - 10
        end
      end
    end
  elseif op == "consider_switch" or op == "consider_item" then
    -- Routing markers for the reserve and bag branches. They consume their
    -- evaluation draw in program order; the branch itself runs through the
    -- dedicated switch/item selectors, never by mutating move scores here.
  elseif op == "roll_tiebreak" then
    return draw
  end
  return nil
end

---@param instructions table[]
---@return table[] instructions in program order
local function orderedInstructions(instructions)
  local ordered = {}
  for _, instruction in ipairs(instructions) do
    ordered[#ordered + 1] = instruction
  end
  table.sort(ordered, function(a, b)
    return (a.order or 0) < (b.order or 0)
  end)
  return ordered
end

---@param program table<string, unknown>
---@param knowledge table<string, unknown>
---@param stream table<string, unknown>
---@return table[] scored moves in candidate order
function NativeAiEvaluator.scoreMoves(program, knowledge, stream)
  assertProgram(program)
  assertKnowledge(knowledge)
  assert(type(stream) == "table" and type(stream.nextU16) == "function", "selection draws from the battle stream")
  local scores = blankScores(knowledge)
  for _, instruction in ipairs(orderedInstructions(program.instructions)) do
    applyInstruction(instruction.op, scores, knowledge, stream)
  end
  return scores
end

---@param program table<string, unknown>
---@param knowledge table<string, unknown>
---@param stream table<string, unknown>
---@return table<string, unknown> selected action with its full score table
function NativeAiEvaluator.evaluate(program, knowledge, stream)
  assertProgram(program)
  assertKnowledge(knowledge)
  assert(type(stream) == "table" and type(stream.nextU16) == "function", "selection draws from the battle stream")
  local scores = blankScores(knowledge)
  local tiebreak = nil
  for _, instruction in ipairs(orderedInstructions(program.instructions)) do
    local draw = applyInstruction(instruction.op, scores, knowledge, stream)
    if instruction.op == "roll_tiebreak" then
      tiebreak = draw
    end
  end
  assert(#scores > 0, "selection programs answer at least one candidate move")
  local best = 1
  for index = 2, #scores do
    if scores[index].score > scores[best].score then
      best = index
    end
  end
  local tied = {}
  for index, entry in ipairs(scores) do
    if entry.score == scores[best].score then
      tied[#tied + 1] = index
    end
  end
  if #tied > 1 and tiebreak ~= nil then
    best = tied[(tiebreak % #tied) + 1]
  end
  return { action = scores[best].move, scores = scores }
end

---@param program table<string, unknown>
---@param knowledge table<string, unknown>
---@param stream table<string, unknown>
---@return table<string, unknown> reserve combatant selected to answer the foe
function NativeAiEvaluator.chooseSwitch(program, knowledge, stream)
  assertProgram(program)
  assertKnowledge(knowledge)
  assert(type(stream) == "table" and type(stream.nextU16) == "function", "selection draws from the battle stream")
  assert(type(knowledge.reserves) == "table", "switch selection lists the reserves")
  stream:nextU16("consider_switch", { branch = "switch" })
  local foeTypes = knowledge.foe.types or {}
  local best = nil
  local bestExposure = nil
  for _, reserve in ipairs(knowledge.reserves) do
    if type(reserve) == "table" and (reserve.hp or 0) > 0 and reserve.combatant ~= nil then
      local exposure = 1
      for _, foeType in ipairs(foeTypes) do
        exposure = exposure * effectiveness(foeType, reserve.types or {})
      end
      if best == nil or exposure < bestExposure then
        best = reserve
        bestExposure = exposure
      end
    end
  end
  if best == nil then
    Errors.raise("AI_NO_SWITCH_TARGET", "switch selection never answers with a fainted reserve", {})
  end
  local answered = best --[[@as table<string, unknown>]]
  return { replacement = answered.combatant }
end

---@param program table<string, unknown>
---@param knowledge table<string, unknown>
---@param stream table<string, unknown>
---@param stock table<string, unknown> trainer items and bag counts backing this trainer
---@return table<string, unknown> selected bag item, empty when no healing applies
function NativeAiEvaluator.chooseItem(program, knowledge, stream, stock)
  assertProgram(program)
  assertKnowledge(knowledge)
  assert(type(stream) == "table" and type(stream.nextU16) == "function", "selection draws from the battle stream")
  assert(type(stock) == "table", "item selection reads the trainer stock")
  stream:nextU16("consider_item", { branch = "item" })
  local hp = knowledge.active.hp or 0
  local maxHp = knowledge.active.maxHp or 0
  if maxHp > 0 and hp * 4 < maxHp then
    local trainerItems = stock.trainerItems or {}
    local bag = stock.bag or {}
    for _, item in ipairs(trainerItems) do
      if type(item) == "string" and (bag[item] or 0) > 0 then
        return { item = item }
      end
    end
  end
  return {}
end

---@param knowledge table<string, unknown>
---@return table[] per-move damage estimates that never touch random state
function NativeAiEvaluator.previewDamage(knowledge)
  assertKnowledge(knowledge)
  local estimates = {}
  for index, move in ipairs(knowledge.active.moves) do
    estimates[#estimates + 1] = { move = move.key, estimate = matchupScore(knowledge, index) }
  end
  return estimates
end

return NativeAiEvaluator
