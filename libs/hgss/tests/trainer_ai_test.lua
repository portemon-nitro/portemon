-- Native trainer selection: enabled scoring passes run in source order over
-- an explicit knowledge projection, damage previews never touch the
-- execution stream, switch and item choices follow the same evaluator, the
-- instruction set stays closed at compilation, and the policy sees only
-- its projection. Vectors are fixed here from the native selection
-- branches; nothing is produced by the modules under test.

local Assert = require("tests.support.Assert")
local BattleRng = require("libs.battle.src.gen4.BattleRng")

local AI_MODULE = "libs.hgss.src.battle.HgssTrainerAi"
local EVALUATOR_MODULE = "libs.hgss.src.battle.ai.NativeAiEvaluator"
local CATALOG_MODULE = "libs.hgss.src.battle.HgssTrainerCatalog"

local T = {}

local FIXED_SEED = 984260731

---@param name string module path under test
---@param behavior string observable behavior the module owns
---@return table the loaded module
local function requirePresent(name, behavior)
  local ok, loaded = pcall(require, name)
  Assert.isTrue(ok, "missing selection behavior: " .. behavior .. " (" .. name .. ")")
  assert(loaded ~= nil, "the selection module loads")
  return loaded --[[@as table]]
end

---@param seed integer
---@return table labeled native stream recording every draw site
local function spyStream(seed)
  local inner = BattleRng.new(seed)
  local labels = {}
  local stream = {}
  function stream:nextU16(label, cause)
    labels[#labels + 1] = label
    return inner:nextU16(label, cause)
  end
  function stream:capture()
    return inner:capture()
  end
  function stream:drawLabels()
    local out = {}
    for index, label in ipairs(labels) do
      out[index] = label
    end
    return out
  end
  return stream
end

---@return table knowledge with public facts plus hidden peer details
local function mixedKnowledge()
  return {
    active = {
      combatant = 1,
      species = "CHIKORITA",
      level = 5,
      hp = 18,
      maxHp = 20,
      types = { "grass" },
      moves = {
        { key = "TACKLE", moveType = "normal", power = 35 },
        { key = "RAZOR_LEAF", moveType = "grass", power = 55 },
        { key = "POISONPOWDER", moveType = "poison", power = 0 },
      },
    },
    foe = {
      combatant = 2,
      species = "GEODUDE",
      level = 5,
      hp = 14,
      maxHp = 20,
      types = { "rock", "ground" },
    },
    reserves = {
      { combatant = 3, species = "PIDGEY", level = 5, hp = 19, maxHp = 19, types = { "normal", "flying" } },
      { combatant = 4, species = "TOTODILE", level = 5, hp = 0, maxHp = 21, types = { "water" } },
    },
    hidden = {
      foeMoves = { "ROCK_THROW", "DEFENSE_CURL" },
      foeItem = "ORAN_BERRY",
      sealedChoices = { { kind = "attack", payload = {} } },
    },
  }
end

---@param ops string[]|nil instruction operations for the program
---@return table selection program with a fixed revision
local function programWith(ops)
  local instructions = {}
  for index, op in ipairs(ops or { "score_matchup", "score_residual_risk", "roll_tiebreak" }) do
    instructions[#instructions + 1] = { op = op, order = index }
  end
  return {
    key = "youngster_opening",
    revision = "native-1",
    instructions = instructions,
    entryPoints = { action = 1, switch = 1, item = 1 },
  }
end

-- Enabled passes score every move in program order: the grass campaign
-- against the rock-ground foe prefers its super-effective strike over the
-- resisted normal strike and the scoreless status attempt, evaluation
-- follows instruction order, and draws carry source labels.
function T.enabled_passes_score_and_select_in_source_order()
  local Evaluator = requirePresent(
    EVALUATOR_MODULE,
    "the typed instruction evaluator executes every reachable selection branch"
  )
  Assert.isTrue(type(Evaluator.evaluate) == "function", "the evaluator runs whole programs")
  Assert.isTrue(type(Evaluator.scoreMoves) == "function", "the evaluator scores move lists")
  local stream = spyStream(FIXED_SEED)
  local scored = Evaluator.scoreMoves(programWith(), mixedKnowledge(), stream)
  Assert.isTrue(type(scored) == "table" and #scored == 3, "every candidate move carries a score")
  local byKey = {}
  for _, entry in ipairs(scored) do
    Assert.isTrue(type(entry.score) == "number", "scores stay numeric")
    byKey[entry.move] = entry.score
  end
  Assert.isTrue(byKey["RAZOR_LEAF"] > byKey["TACKLE"], "super-effective outscores resisted")
  Assert.isTrue(byKey["TACKLE"] > byKey["POISONPOWDER"], "damaging outscores the scoreless status attempt")
  local decided = Evaluator.evaluate(programWith(), mixedKnowledge(), spyStream(FIXED_SEED))
  Assert.equal(decided.action, "RAZOR_LEAF", "evaluation selects the winning score")
  Assert.deepEqual(
    stream:drawLabels(),
    { "score_matchup", "score_residual_risk", "roll_tiebreak" },
    "evaluation draws follow program order with source labels"
  )
end

-- Every supported instruction executes without falling back: each declared
-- operation evaluates its fixture branch, and the supported set is stable
-- across reads so runtime cannot invent new operations.
function T.every_supported_instruction_executes_without_fallback()
  local Evaluator = requirePresent(
    EVALUATOR_MODULE,
    "the typed instruction evaluator executes every reachable selection branch"
  )
  Assert.isTrue(type(Evaluator.supportedInstructions) == "function", "the instruction set is enumerable")
  local supported = Evaluator.supportedInstructions()
  Assert.isTrue(type(supported) == "table" and #supported > 0, "the closed set names its instructions")
  Assert.deepEqual(Evaluator.supportedInstructions(), supported, "the instruction set is stable across reads")
  local allowed = {}
  for _, op in ipairs(supported) do
    allowed[op] = true
  end
  for _, op in ipairs(supported) do
    local result = Evaluator.evaluate(programWith({ op }), mixedKnowledge(), spyStream(FIXED_SEED))
    Assert.notNil(result, "operation " .. op .. " evaluates instead of falling back")
    Assert.isNil(result.fallback, "operation " .. op .. " never marks a fallback choice")
  end
  Assert.isTrue(allowed["score_matchup"] == true, "matchup scoring belongs to the closed set")
  Assert.isTrue(allowed["roll_tiebreak"] == true, "tie breaking belongs to the closed set")
end

-- Unknown instructions fail closed: evaluation raises instead of answering
-- a legal random move, and scoring always covers every input move.
function T.unknown_instructions_fail_closed()
  local Evaluator = requirePresent(
    EVALUATOR_MODULE,
    "the typed instruction evaluator executes every reachable selection branch"
  )
  Assert.throws(function()
    Evaluator.evaluate(programWith({ "invented_operation" }), mixedKnowledge(), spyStream(FIXED_SEED))
  end, "instructions outside the closed set fail instead of falling back")
  local scored = Evaluator.scoreMoves(programWith(), mixedKnowledge(), spyStream(FIXED_SEED))
  Assert.equal(#scored, 3, "scoring covers every input move with no silent drop")
  for _, entry in ipairs(scored) do
    Assert.isTrue(type(entry.move) == "string", "scored entries name their move")
    Assert.isTrue(type(entry.score) == "number", "scored entries carry numeric scores")
  end
end

-- Mixed teams drive switch and item choice through the same evaluator: the
-- flying reserve answers the rock-ground foe, fainted reserves are never
-- chosen, and an item-capable trainer heals at low health while declining
-- otherwise. Draws stay on the native stream in source order.
function T.switching_and_item_choices_use_mixed_teams()
  local Evaluator = requirePresent(
    EVALUATOR_MODULE,
    "the typed instruction evaluator executes every reachable selection branch"
  )
  Assert.isTrue(type(Evaluator.chooseSwitch) == "function", "the evaluator owns switch choice")
  Assert.isTrue(type(Evaluator.chooseItem) == "function", "the evaluator owns item choice")
  local knowledge = mixedKnowledge()
  local stream = spyStream(FIXED_SEED)
  local switchChoice = Evaluator.chooseSwitch(programWith(), knowledge, stream)
  Assert.equal(switchChoice.replacement, 3, "the flying reserve answers the rock-ground foe")
  local lowHealth = mixedKnowledge()
  lowHealth.active.hp = 4
  local itemChoice = Evaluator.chooseItem(
    programWith(),
    lowHealth,
    spyStream(FIXED_SEED),
    { trainerItems = { "POTION" }, bag = { POTION = 2 } }
  )
  Assert.equal(itemChoice.item, "POTION", "low health with stock heals")
  local healthy = Evaluator.chooseItem(
    programWith(),
    mixedKnowledge(),
    spyStream(FIXED_SEED),
    { trainerItems = { "POTION" }, bag = { POTION = 2 } }
  )
  Assert.isNil(healthy.item, "healthy fighters decline the bag")
  local empty = Evaluator.chooseItem(
    programWith(),
    lowHealth,
    spyStream(FIXED_SEED),
    { trainerItems = {}, bag = {} }
  )
  Assert.isNil(empty.item, "trainers without usable items never invent one")
  Assert.deepEqual(
    stream:drawLabels()[1],
    "consider_switch",
    "switch evaluation opens with its source-labeled draw"
  )
end

-- The policy observes only its projection: hidden foe moves, items, and
-- sealed peer choices never reach the decision, while debug reads stay a
-- separate privileged entrypoint.
function T.observation_projection_hides_private_information()
  local Ai = requirePresent(AI_MODULE, "the native controller binds flags and programs to decisions")
  Assert.isTrue(type(Ai.new) == "function", "the controller constructs from its program binding")
  Assert.isTrue(type(Ai.observe) == "function", "the controller exposes its knowledge projection")
  Assert.isTrue(type(Ai.decide) == "function", "the controller answers owned requests")
  local controller = Ai.new({ program = programWith(), aiPasses = { "ai_pass_0" } })
  local projection = controller:observe(mixedKnowledge())
  Assert.isNil(projection.hidden, "sealed knowledge never enters the projection")
  Assert.isNil(projection.foeMoves, "foe moves never enter the projection")
  Assert.isNil(projection.foeItem, "foe items never enter the projection")
  local request = { requestId = 7, epoch = 3, controller = "ai", kind = "action", actors = { { combatant = 1 } } }
  local firstKnowledge = mixedKnowledge()
  local secondKnowledge = mixedKnowledge()
  secondKnowledge.hidden.foeMoves = { "EXPLOSION", "HYPER_BEAM" }
  secondKnowledge.hidden.sealedChoices = { { kind = "switch", payload = {} } }
  local first = controller:decide(request, controller:observe(firstKnowledge), spyStream(FIXED_SEED))
  local second = controller:decide(request, controller:observe(secondKnowledge), spyStream(FIXED_SEED))
  Assert.deepEqual(second.choices, first.choices, "hidden details cannot move the decision")
  Assert.equal(first.requestId, 7, "replies echo their request identity")
  Assert.equal(first.epoch, 3, "replies echo their batch epoch")
  Assert.equal(first.controller, "ai", "replies name their controller")
end

-- Preview calculations never consume execution randomness: scoring the same
-- projection twice draws identically, and a preview pass leaves the stream
-- position untouched.
function T.preview_calculations_never_consume_execution_randomness()
  local Evaluator = requirePresent(
    EVALUATOR_MODULE,
    "the typed instruction evaluator executes every reachable selection branch"
  )
  local firstStream = spyStream(FIXED_SEED)
  local first = Evaluator.scoreMoves(programWith(), mixedKnowledge(), firstStream)
  local secondStream = spyStream(FIXED_SEED)
  local second = Evaluator.scoreMoves(programWith(), mixedKnowledge(), secondStream)
  Assert.deepEqual(second, first, "identical projections score identically")
  Assert.deepEqual(secondStream:drawLabels(), firstStream:drawLabels(), "identical projections draw identically")
  local previewStream = spyStream(FIXED_SEED)
  local before = previewStream:capture()
  if type(Evaluator.previewDamage) == "function" then
    Evaluator.previewDamage(mixedKnowledge(), previewStream)
  end
  Assert.deepEqual(previewStream:capture(), before, "damage previews leave the execution stream untouched")
end

return { tests = T }
