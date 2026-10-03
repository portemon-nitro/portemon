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

-- Native passes choose the winning owned slot without a bound selection
-- record: the grass campaign against the rock-ground foe answers from
-- its middle slot, the reply echoes its request, an identical controller
-- answers identically from the same seed, and repeating the open request
-- returns the recorded reply without further draws.
function T.selects_winning_nonzero_move_slot_from_passes_and_memoizes_reply()
  local Ai = requirePresent(AI_MODULE, "the native controller answers owned requests from its pass facts")
  local knowledge = {
    active = {
      combatant = 1,
      species = "CHIKORITA",
      level = 5,
      hp = 20,
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
    reserves = {},
  }
  local request =
    { requestId = 11, epoch = 0, controller = "ai", kind = "action", actors = { { combatant = 1 } } }
  local controller = Ai.new({ aiPasses = { "ai_pass_0", "ai_pass_1" }, trainerItems = {} })
  local stream = spyStream(FIXED_SEED)
  local reply = controller:decide(request, controller:observe(knowledge), stream)
  Assert.equal(reply.requestId, 11, "replies echo their request identity")
  Assert.equal(reply.epoch, 0, "replies echo their batch epoch")
  Assert.isTrue(type(reply.choices) == "table" and #reply.choices == 1, "one owned actor draws one choice")
  local choice = reply.choices[1]
  Assert.equal(choice.kind, "attack", "the healthy attacker with no reserves answers with a strike")
  Assert.isTrue(type(choice.payload) == "table", "strike choices carry their payload")
  Assert.equal(choice.payload.moveSlot, 1, "the winning grass strike answers from its owned middle slot")
  local draws = #stream:drawLabels()
  local repeated = controller:decide(request, controller:observe(knowledge), stream)
  Assert.deepEqual(repeated, reply, "repeating the open request returns the recorded reply")
  Assert.equal(#stream:drawLabels(), draws, "repeated polls draw nothing further")
  local twin = Ai.new({ aiPasses = { "ai_pass_0", "ai_pass_1" }, trainerItems = {} })
  local twinReply = twin:decide(request, twin:observe(knowledge), spyStream(FIXED_SEED))
  Assert.deepEqual(twinReply, reply, "identical passes answer identically from the same seed")
end

-- Switch and item answers ride the same pass-driven controller: an exposed
-- fire attacker facing a water foe answers with its living grass reserve
-- (never the fainted one), a wounded attacker with stock answers with its
-- stocked cure, and healthy or stockless attackers never invent bag use.
function T.answers_switch_and_item_branches_from_live_roster_and_stock()
  local Ai = requirePresent(AI_MODULE, "the native controller answers owned requests from its pass facts")
  local switchKnowledge = {
    active = {
      combatant = 1,
      species = "CHARMANDER",
      level = 5,
      hp = 18,
      maxHp = 20,
      types = { "fire" },
      moves = {
        { key = "SCRATCH", moveType = "normal", power = 40 },
        { key = "EMBER", moveType = "fire", power = 40 },
      },
    },
    foe = {
      combatant = 2,
      species = "TOTODILE",
      level = 5,
      hp = 14,
      maxHp = 20,
      types = { "water" },
    },
    reserves = {
      { combatant = 3, species = "CHIKORITA", level = 5, hp = 19, maxHp = 19, types = { "grass" } },
      { combatant = 4, species = "TOTODILE", level = 5, hp = 0, maxHp = 21, types = { "water" } },
    },
  }
  local switchRequest =
    { requestId = 21, epoch = 0, controller = "ai", kind = "action", actors = { { combatant = 1 } } }
  local switcher = Ai.new({ aiPasses = { "ai_pass_0", "ai_pass_1" }, trainerItems = {} })
  local switchReply = switcher:decide(switchRequest, switcher:observe(switchKnowledge), spyStream(FIXED_SEED))
  Assert.isTrue(
    type(switchReply.choices) == "table" and #switchReply.choices == 1,
    "one owned actor draws one choice"
  )
  local exchange = switchReply.choices[1]
  Assert.equal(exchange.kind, "switch", "the exposed attacker answers the hostile matchup by exchanging")
  Assert.isTrue(type(exchange.payload) == "table", "exchange choices carry their payload")
  Assert.equal(exchange.payload.replacement, 3, "the living grass reserve answers the water foe")
  Assert.isTrue(exchange.payload.replacement ~= 4, "fainted reserves are never chosen")

  ---@param hp integer current health of the wounded attacker
  ---@return table knowledge projection with no reserves
  local function woundedKnowledge(hp)
    return {
      active = {
        combatant = 1,
        species = "CHIKORITA",
        level = 5,
        hp = hp,
        maxHp = 20,
        types = { "grass" },
        moves = {
          { key = "TACKLE", moveType = "normal", power = 35 },
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
      reserves = {},
    }
  end
  local itemRequest =
    { requestId = 22, epoch = 0, controller = "ai", kind = "action", actors = { { combatant = 1 } } }
  local stocked = Ai.new({ aiPasses = { "ai_pass_0", "ai_pass_1" }, trainerItems = { "POTION" } })
  local cure = stocked:decide(itemRequest, stocked:observe(woundedKnowledge(4)), spyStream(FIXED_SEED))
  Assert.isTrue(type(cure.choices) == "table" and #cure.choices == 1, "one owned actor draws one choice")
  Assert.equal(cure.choices[1].kind, "item", "the wounded attacker with stock answers with its bag")
  Assert.isTrue(type(cure.choices[1].payload) == "table", "bag choices carry their payload")
  Assert.equal(cure.choices[1].payload.item, "POTION", "the stocked cure is the one actually carried")
  local bare = Ai.new({ aiPasses = { "ai_pass_0", "ai_pass_1" }, trainerItems = {} })
  local withoutStock = bare:decide(itemRequest, bare:observe(woundedKnowledge(4)), spyStream(FIXED_SEED))
  Assert.isTrue(
    withoutStock.choices[1].kind ~= "item",
    "attackers without usable items never invent bag stock"
  )
  local healthyRequest =
    { requestId = 23, epoch = 0, controller = "ai", kind = "action", actors = { { combatant = 1 } } }
  local healthy = stocked:decide(healthyRequest, stocked:observe(woundedKnowledge(18)), spyStream(FIXED_SEED))
  Assert.isTrue(healthy.choices[1].kind ~= "item", "healthy attackers decline the bag")
end

-- Generated per-bit evaluations compile in native bit order and consume
-- their program-order draws without moving scores: each generated bit
-- resolves to its evaluation step plus the tiebreak settler, and a
-- multi-bit program preserves ascending bit order through evaluation.
function T.generated_pass_evaluations_compile_in_bit_order()
  local Evaluator = requirePresent(
    EVALUATOR_MODULE,
    "the typed instruction evaluator executes every reachable selection branch"
  )
  local cases = {
    { bit = 2, op = "evaluate_pass_2" },
    { bit = 3, op = "evaluate_pass_3" },
    { bit = 5, op = "evaluate_pass_5" },
    { bit = 6, op = "evaluate_pass_6" },
    { bit = 9, op = "evaluate_pass_9" },
  }
  for _, case in ipairs(cases) do
    local entry = case --[[@as table<string, unknown>]]
    local program = Evaluator.compilePassProgram({ "ai_pass_" .. entry.bit })
    local ops = {}
    for _, instruction in ipairs(program.instructions --[[@as table<integer, table<string, unknown>>]]) do
      ops[#ops + 1] = instruction.op
    end
    Assert.deepEqual(ops, { entry.op, "roll_tiebreak" }, "bit " .. entry.bit .. " evaluates then tiebreaks")
  end
  local combined = Evaluator.compilePassProgram({ "ai_pass_9", "ai_pass_2", "ai_pass_0" })
  local ordered = {}
  for _, instruction in ipairs(combined.instructions --[[@as table<integer, table<string, unknown>>]]) do
    ordered[#ordered + 1] = instruction.op
  end
  Assert.deepEqual(
    ordered,
    { "score_matchup", "check_bad_move", "evaluate_pass_2", "evaluate_pass_9", "roll_tiebreak" },
    "multi-bit programs evaluate in ascending bit order"
  )
  local knowledge = {
    active = {
      combatant = 1,
      species = "CHIKORITA",
      level = 5,
      hp = 20,
      maxHp = 20,
      types = { "grass" },
      moves = {
        { key = "SPLASH", moveType = "normal", power = 0 },
        { key = "GROWL", moveType = "normal", power = 0 },
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
    reserves = {},
  }
  local stream = spyStream(FIXED_SEED)
  local scored = Evaluator.scoreMoves(combined, knowledge, stream)
  for _, entry in ipairs(scored) do
    Assert.equal(entry.score, 0, "evaluation steps move no scoreless scores")
  end
  Assert.deepEqual(
    stream:drawLabels(),
    { "score_matchup", "check_bad_move", "evaluate_pass_2", "evaluate_pass_9", "roll_tiebreak" },
    "evaluation draws follow program order"
  )
end

-- Pass names outside the closed native set fail closed: an unknown bit
-- and a malformed name both raise naming the offending pass instead of
-- answering a fallback move.
function T.unknown_pass_names_fail_closed()
  local Ai = requirePresent(AI_MODULE, "the native controller answers owned requests from its pass facts")
  local errBit = Assert.throws(function()
    Ai.new({ aiPasses = { "ai_pass_4" }, trainerItems = {} })
  end, "passes outside the closed set fail instead of falling back")
  Assert.isTrue(string.find(tostring(errBit), "ai_pass_4", 1, true) ~= nil, "the failure names the unknown pass")
  local errMalformed = Assert.throws(function()
    Ai.new({ aiPasses = { "bogus" }, trainerItems = {} })
  end, "malformed pass names fail instead of falling back")
  Assert.isTrue(
    string.find(tostring(errMalformed), "bogus", 1, true) ~= nil,
    "the failure names the malformed pass"
  )
end

-- Flagless trainers still answer legally without a program: with no
-- scoring pass every owned move ties, so selection draws uniformly from
-- the labeled stream, stays deterministic for a fixed seed, and memoizes
-- the open request without further draws.
function T.flagless_trainers_select_without_scoring_passes()
  local Ai = requirePresent(AI_MODULE, "the native controller answers owned requests from its pass facts")
  local knowledge = mixedKnowledge()
  knowledge.reserves = {}
  local request =
    { requestId = 31, epoch = 0, controller = "ai", kind = "action", actors = { { combatant = 1 } } }
  local controller = Ai.new({ aiPasses = {}, trainerItems = {} })
  local stream = spyStream(FIXED_SEED)
  local reply = controller:decide(request, controller:observe(knowledge), stream)
  Assert.isTrue(type(reply.choices) == "table" and #reply.choices == 1, "one owned actor draws one choice")
  Assert.equal(reply.choices[1].kind, "attack", "the flagless attacker still strikes")
  local slot = reply.choices[1].payload.moveSlot
  Assert.isTrue(slot == 0 or slot == 1 or slot == 2, "the strike names an owned move slot")
  local draws = #stream:drawLabels()
  Assert.isTrue(draws > 0, "the first evaluation draws from the native stream")
  local repeated = controller:decide(request, controller:observe(knowledge), stream)
  Assert.deepEqual(repeated, reply, "repeating the open request returns the recorded reply")
  Assert.equal(#stream:drawLabels(), draws, "repeated polls draw nothing further")
  local twin = Ai.new({ aiPasses = {}, trainerItems = {} })
  Assert.deepEqual(
    twin:decide(request, twin:observe(knowledge), spyStream(FIXED_SEED)),
    reply,
    "identical passes answer identically from the same seed"
  )
end

-- Power-point exhaustion selects the struggle state instead of an
-- invalid slot: fully spent moves answer slot zero for the session to
-- resolve as struggle, while a spent lead move is excluded in favor of
-- a live winning slot.
function T.exhausted_power_points_select_the_struggle_state()
  local Ai = requirePresent(AI_MODULE, "the native controller answers owned requests from its pass facts")
  ---@param moves table[] candidate moves carrying their remaining power points
  ---@return table knowledge projection with no reserves
  local function spentKnowledge(moves)
    return {
      active = {
        combatant = 1,
        species = "CHIKORITA",
        level = 5,
        hp = 20,
        maxHp = 20,
        types = { "grass" },
        moves = moves,
      },
      foe = {
        combatant = 2,
        species = "GEODUDE",
        level = 5,
        hp = 14,
        maxHp = 20,
        types = { "rock", "ground" },
      },
      reserves = {},
    }
  end
  local request =
    { requestId = 41, epoch = 0, controller = "ai", kind = "action", actors = { { combatant = 1 } } }
  local controller = Ai.new({ aiPasses = { "ai_pass_0", "ai_pass_1" }, trainerItems = {} })
  local spent = controller:decide(
    request,
    controller:observe(spentKnowledge({
      { key = "TACKLE", moveType = "normal", power = 35, pp = 0 },
      { key = "RAZOR_LEAF", moveType = "grass", power = 55, pp = 0 },
    })),
    spyStream(FIXED_SEED)
  )
  Assert.equal(spent.choices[1].kind, "attack", "spent attackers still answer with a strike")
  Assert.equal(spent.choices[1].payload.moveSlot, 0, "no usable move selects the struggle state")
  local partialRequest =
    { requestId = 42, epoch = 0, controller = "ai", kind = "action", actors = { { combatant = 1 } } }
  local partial = controller:decide(
    partialRequest,
    controller:observe(spentKnowledge({
      { key = "TACKLE", moveType = "normal", power = 35, pp = 0 },
      { key = "RAZOR_LEAF", moveType = "grass", power = 55, pp = 12 },
    })),
    spyStream(FIXED_SEED)
  )
  Assert.equal(partial.choices[1].payload.moveSlot, 1, "the spent lead is excluded for the live winner")
end

-- Selection adjustments prefer sound finishing moves: a scoreless
-- no-effect strike falls below a status attempt under the bad-move pass,
-- and the most powerful neutral strike wins outright under the
-- faint-seeking pass without needing a tiebreak draw.
function T.selection_adjustments_prefer_sound_finishing_moves()
  local Evaluator = requirePresent(
    EVALUATOR_MODULE,
    "the typed instruction evaluator executes every reachable selection branch"
  )
  local immuneKnowledge = {
    active = {
      combatant = 1,
      species = "CHIKORITA",
      level = 5,
      hp = 20,
      maxHp = 20,
      types = { "grass" },
      moves = {
        { key = "TACKLE", moveType = "normal", power = 35 },
        { key = "SLEEP_POWDER", moveType = "grass", power = 0 },
      },
    },
    foe = {
      combatant = 2,
      species = "GASTLY",
      level = 5,
      hp = 14,
      maxHp = 20,
      types = { "ghost" },
    },
    reserves = {},
  }
  local immune = Evaluator.evaluate(
    programWith({ "score_matchup", "check_bad_move" }),
    immuneKnowledge,
    spyStream(FIXED_SEED)
  )
  Assert.equal(immune.action, "SLEEP_POWDER", "the negated strike falls below the status attempt")
  local powerKnowledge = {
    active = {
      combatant = 1,
      species = "CHARMANDER",
      level = 5,
      hp = 20,
      maxHp = 20,
      types = { "fire" },
      moves = {
        { key = "EMBER", moveType = "fire", power = 40 },
        { key = "SCRATCH", moveType = "normal", power = 60 },
      },
    },
    foe = {
      combatant = 2,
      species = "PIDGEY",
      level = 5,
      hp = 14,
      maxHp = 20,
      types = { "normal", "flying" },
    },
    reserves = {},
  }
  local faint = Evaluator.evaluate(programWith({ "try_to_faint" }), powerKnowledge, spyStream(FIXED_SEED))
  Assert.equal(faint.action, "SCRATCH", "the most powerful strike wins outright")
end

-- Raw perspective views still answer legally without scoring: callers
-- that pass the session view directly get one strike per owned actor
-- from the owned move count, with the visible opposing position as the
-- target and identical memoized replies on repeat polls.
function T.raw_views_answer_legally_without_scoring()
  local Ai = requirePresent(AI_MODULE, "the native controller answers owned requests from its pass facts")
  local view = {
    controller = "ai",
    combatants = {
      { combatant = 1, hp = 20, mon = { moves = { { move = "TACKLE" }, { move = "GROWL" } } } },
    },
    opponents = {
      { combatant = 2, position = 2, hp = 14 },
    },
  }
  local request =
    { requestId = 51, epoch = 0, controller = "ai", kind = "action", actors = { { combatant = 1 } } }
  local controller = Ai.new({ aiPasses = {}, trainerItems = {} })
  local stream = spyStream(FIXED_SEED)
  local reply = controller:decide(request, view, stream)
  Assert.isTrue(type(reply.choices) == "table" and #reply.choices == 1, "one owned actor draws one choice")
  Assert.equal(reply.choices[1].kind, "attack", "view callers still answer with a strike")
  local slot = reply.choices[1].payload.moveSlot
  Assert.isTrue(slot == 0 or slot == 1, "the strike names an owned move slot")
  Assert.equal(reply.choices[1].payload.target.position, 2, "the strike targets the visible position")
  local draws = #stream:drawLabels()
  local repeated = controller:decide(request, view, stream)
  Assert.deepEqual(repeated, reply, "repeating the open request returns the recorded reply")
  Assert.equal(#stream:drawLabels(), draws, "repeated polls draw nothing further")
end

-- Healing choices name their holder and spend finite stock: a wounded
-- attacker with one cure answers with a holder-targeted bag choice that
-- session validation can bind to its inventory, and the next decision
-- after that unit leaves cannot reuse the spent stock. A double-carried
-- cure answers twice before running dry.
function T.healing_choices_target_the_holder_and_spend_finite_stock()
  local Ai = requirePresent(AI_MODULE, "the native controller answers owned requests from its pass facts")
  ---@param hp integer current health of the wounded attacker
  ---@return table knowledge projection with no reserves
  local function woundedKnowledge(hp)
    return {
      active = {
        combatant = 1,
        species = "CHIKORITA",
        level = 5,
        hp = hp,
        maxHp = 20,
        types = { "grass" },
        moves = {
          { key = "TACKLE", moveType = "normal", power = 35 },
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
      reserves = {},
    }
  end
  local single = Ai.new({ aiPasses = { "ai_pass_0", "ai_pass_1" }, trainerItems = { "POTION" } })
  local firstRequest =
    { requestId = 61, epoch = 0, controller = "ai", kind = "action", actors = { { combatant = 1 } } }
  local first = single:decide(firstRequest, single:observe(woundedKnowledge(4)), spyStream(FIXED_SEED))
  Assert.isTrue(type(first.choices) == "table" and #first.choices == 1, "one owned actor draws one choice")
  Assert.equal(first.choices[1].kind, "item", "the wounded attacker with stock answers with its bag")
  Assert.isTrue(type(first.choices[1].payload) == "table", "bag choices carry their payload")
  Assert.equal(first.choices[1].payload.item, "POTION", "the stocked cure is the one actually carried")
  local target = first.choices[1].payload.target
  Assert.isTrue(type(target) == "table", "healing choices name their holder")
  Assert.equal(target.kind, "combatant", "healing targets its holder as a combatant")
  Assert.equal(target.combatant, 1, "healing targets the active holder")
  local secondRequest =
    { requestId = 62, epoch = 0, controller = "ai", kind = "action", actors = { { combatant = 1 } } }
  local second = single:decide(secondRequest, single:observe(woundedKnowledge(4)), spyStream(FIXED_SEED))
  Assert.isTrue(second.choices[1].kind ~= "item", "the spent stock cannot be reused")
  local double = Ai.new({ aiPasses = { "ai_pass_0", "ai_pass_1" }, trainerItems = { "POTION", "POTION" } })
  local doubleFirst = double:decide(
    { requestId = 63, epoch = 0, controller = "ai", kind = "action", actors = { { combatant = 1 } } },
    double:observe(woundedKnowledge(4)),
    spyStream(FIXED_SEED)
  )
  Assert.equal(doubleFirst.choices[1].kind, "item", "the first of two carried cures still heals")
  Assert.equal(doubleFirst.choices[1].payload.target.combatant, 1, "the first cure names the active holder")
  local doubleSecond = double:decide(
    { requestId = 64, epoch = 0, controller = "ai", kind = "action", actors = { { combatant = 1 } } },
    double:observe(woundedKnowledge(4)),
    spyStream(FIXED_SEED)
  )
  Assert.equal(doubleSecond.choices[1].kind, "item", "the second of two carried cures still heals")
  local doubleThird = double:decide(
    { requestId = 65, epoch = 0, controller = "ai", kind = "action", actors = { { combatant = 1 } } },
    double:observe(woundedKnowledge(4)),
    spyStream(FIXED_SEED)
  )
  Assert.isTrue(doubleThird.choices[1].kind ~= "item", "two cures heal exactly twice")
end

return { tests = T }
