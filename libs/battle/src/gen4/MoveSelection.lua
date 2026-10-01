-- Usable-move, forced-action, and obedience checks: selection separates
-- the requested move from the executing move and the power-point owner,
-- prevention gates reject at their source checkpoints without random or
-- power-point side effects, and struggle is an explicit native action for
-- selections with no usable move. Obedience runs at the before-action
-- checkpoint from owner facts and fixed random state, never asking the
-- interface to decide. Source references:
-- src/battle/battle_controller_player.c and src/battle/battle_command.c.

local BattleErrors = require("libs.battle.src.errors")
local BattleRng = require("libs.battle.src.gen4.BattleRng")
local CalledMoves = require("libs.battle.src.gen4.behaviors.moves.CalledMoves")

---@class MoveSelection
local MoveSelection = {}

-- Profile level caps by badge count for traded mons: no badge obeys to
-- 10, two badges to 30, four to 50, six to 70, and a full set to 100.
-- Odd counts hold the lower tier. Used only when the profile carries an
-- explicit badge count; otherwise the profile cap applies directly.
local BADGE_CAPS = {
  [0] = 10,
  [1] = 10,
  [2] = 30,
  [3] = 30,
  [4] = 50,
  [5] = 50,
  [6] = 70,
  [7] = 70,
  [8] = 100,
}

-- Status-category vocabulary blocked by taunt. Damaging moves stay
-- usable; everything here names a non-damaging move identity.
local STATUS_MOVES = {
  TOXIC = true,
  POISON_POWDER = true,
  POISON_GAS = true,
  STUN_SPORE = true,
  SLEEP_POWDER = true,
  SPORE = true,
  THUNDER_WAVE = true,
  GLARE = true,
  LOVELY_KISS = true,
  SING = true,
  HYPNOSIS = true,
  YAWN = true,
  DARK_VOID = true,
  GRASS_WHISTLE = true,
  CONFUSE_RAY = true,
  SUPERSONIC = true,
  SWEET_KISS = true,
  TEETER_DANCE = true,
  FLATTER = true,
  SWAGGER = true,
  ATTRACT = true,
  CAPTIVATE = true,
  WILL_O_WISP = true,
  LEECH_SEED = true,
  CURSE = true,
  NIGHTMARE = true,
  DISABLE = true,
  ENCORE = true,
  TAUNT = true,
  TORMENT = true,
  IMPRISON = true,
  HEAL_BLOCK = true,
  SLEEP_TALK = true,
  FORESIGHT = true,
  ODOR_SLEUTH = true,
  MIRACLE_EYE = true,
  MEAN_LOOK = true,
  SPIDER_WEB = true,
  BLOCK = true,
  SPITE = true,
  DEFOG = true,
  SPLASH = true,
  MEMENTO = true,
  PAIN_SPLIT = true,
  PERISH_SONG = true,
  METRONOME = true,
  ASSIST = true,
  MIRROR_MOVE = true,
  COPYCAT = true,
  ME_FIRST = true,
  NATURE_POWER = true,
  MIMIC = true,
  TRANSFORM = true,
  SKETCH = true,
}

---@param moves unknown persistent move entries under selection
---@param slot integer zero-based move slot under test
---@return table<string, unknown> the move entry owning the slot
local function entryAt(moves, slot)
  if type(moves) ~= "table" then
    error(BattleErrors.input("move selection reads its move entries", {}))
  end
  local entries = moves --[[@as table<integer, unknown>]]
  local entry = entries[slot + 1]
  if type(entry) ~= "table" then
    error(BattleErrors.input("move selection names a known move slot", { slot = slot }))
  end
  return entry --[[@as table<string, unknown>]]
end

---@param inputs table<string, unknown> selection inputs under the choice query
---@return integer chosen zero-based move slot under the query
local function choiceSlot(inputs)
  local choice = inputs.choice
  if type(choice) ~= "table" then
    error(BattleErrors.input("move choices name their move slot", {}))
  end
  local slot = (choice --[[@as table<string, unknown>]]).moveSlot
  if type(slot) ~= "number" or slot % 1 ~= 0 or slot < 0 then
    error(BattleErrors.input("move choices name a non-negative move slot", {}))
  end
  entryAt(inputs.moves, slot --[[@as integer]])
  return slot --[[@as integer]]
end

---@param moves table<integer, unknown> persistent move entries under selection
---@param prevention table<string, unknown> gate state under selection
---@param slot integer zero-based move slot under the query
---@return integer effective power points for the slot
local function effectivePp(moves, prevention, slot)
  local pinned = prevention.pp
  if
    type(pinned) == "table" and type((pinned --[[@as table<integer, unknown>]])[slot]) == "number"
  then
    return (pinned --[[@as table<integer, integer>]])[slot]
  end
  local entry = moves[slot + 1] --[[@as table<string, unknown>]]
  if type(entry.pp) == "number" then
    return entry.pp --[[@as integer]]
  end
  return 0
end

--- Answers whether the chosen move is usable, naming the prevention gate
--- on rejection. Queries never draw and never spend power points.
---@param inputs table<string, unknown> selection inputs carrying actor, moves, prevention, stream, and choice
---@return table<string, unknown> verdict carrying usable plus the rejection reason
function MoveSelection.choices(inputs)
  assert(type(inputs) == "table", "usable-move checks read their selection inputs")
  local prevention = inputs.prevention
  if type(prevention) ~= "table" then
    error(BattleErrors.input("usable-move checks read their prevention state", {}))
  end
  local gates = prevention --[[@as table<string, unknown>]]
  local moves = inputs.moves --[[@as table<integer, unknown>]]
  local slot = choiceSlot(inputs)
  local entry = moves[slot + 1] --[[@as table<string, unknown>]]
  if effectivePp(moves, gates, slot) <= 0 then
    return { usable = false, reason = "no-pp" }
  end
  local disabled = gates.disabled
  if
    type(disabled) == "table" and (disabled --[[@as table<integer, unknown>]])[slot] == true
  then
    return { usable = false, reason = "disabled" }
  end
  if gates.encore ~= nil and gates.encore ~= slot then
    return { usable = false, reason = "encore" }
  end
  if gates.choiceLock ~= nil and gates.choiceLock ~= slot then
    return { usable = false, reason = "choice-lock" }
  end
  if
    gates.taunt == true and STATUS_MOVES[
      entry.move --[[@as string]]
    ] == true
  then
    return { usable = false, reason = "taunt" }
  end
  local imprisoned = gates.imprisoned
  if
    type(imprisoned) == "table"
    and (imprisoned --[[@as table<string, unknown>]])[
      entry.move --[[@as string]]
    ] == true
  then
    return { usable = false, reason = "imprison" }
  end
  return { usable = true, moveSlot = slot }
end

---@param inputs table<string, unknown> execution inputs under resolution
---@return table<string, unknown> validated execution inputs for the transition
local function checkResolveInputs(inputs)
  assert(type(inputs) == "table", "execution resolution reads its inputs")
  if type(inputs.actor) ~= "table" then
    error(BattleErrors.input("execution resolution names its actor", {}))
  end
  if type(inputs.requestedMove) ~= "string" or inputs.requestedMove == "" then
    error(BattleErrors.input("execution resolution names its requested move", {}))
  end
  if type(inputs.moves) ~= "table" then
    error(BattleErrors.input("execution resolution reads its move entries", {}))
  end
  if type(inputs.stream) ~= "table" then
    error(BattleErrors.input("execution resolution reads its battle stream", {}))
  end
  return inputs
end

--- Resolves the requested selection into its executing plan, keeping the
--- requested move, the executing move, and the power-point owner apart. A
--- called move executes the drawn identity while the owner stays on the
--- calling slot; an empty selection resolves to struggle as an explicit
--- action. Re-resolution preserves an already drawn move instead of
--- drawing again. Rejections raise typed input errors with no
--- random or power-point side effects.
---@param inputs table<string, unknown> execution inputs carrying actor, slots, moves, stream, and calling facts
---@return table<string, unknown> execution plan for the action-to-move transition
function MoveSelection.resolveExecution(inputs)
  local record = checkResolveInputs(inputs)
  if record.requestedMove == "STRUGGLE" then
    local struggle = {}
    for key, value in pairs(record) do
      struggle[key] = value
    end
    struggle.executingMove = "STRUGGLE"
    struggle.ppOwnerSlot = nil
    struggle.calledBy = nil
    return struggle
  end
  local slot = record.requestedSlot
  if slot ~= nil then
    if type(slot) ~= "number" or slot % 1 ~= 0 or slot < 0 then
      error(BattleErrors.input("execution resolution names a non-negative requested slot", {}))
    end
    local entry = entryAt(record.moves, slot --[[@as integer]])
    if entry.move ~= record.requestedMove then
      error(BattleErrors.input("the requested move must own its requested slot", { slot = slot }))
    end
  end
  local plan = {}
  for key, value in pairs(record) do
    plan[key] = value
  end
  if plan.executingMove == nil then
    plan.executingMove = plan.requestedMove
  end
  if record.requestedMove == "SLEEP_TALK" and plan.executingMove == "SLEEP_TALK" then
    local decision = CalledMoves.choose({
      requestedMove = plan.requestedMove,
      executingMove = plan.executingMove,
      stream = plan.stream,
      usable = plan.usable,
    })
    if decision == nil or decision.failed ~= nil then
      error(BattleErrors.input("sleep talk needs a usable move to call", {}))
    end
    plan.executingMove = decision.executingMove
    if plan.calledBy == nil then
      plan.calledBy = "SLEEP_TALK"
    end
  end
  return plan
end

---@param profile unknown saved player profile facts under the checkpoint
---@return integer obedient level cap for outsiders under the checkpoint
local function obedienceCap(profile)
  if type(profile) ~= "table" then
    error(BattleErrors.input("obedience reads its profile facts", {}))
  end
  local facts = profile --[[@as table<string, unknown>]]
  if type(facts.badges) == "number" then
    local badges = facts.badges --[[@as integer]]
    if badges % 1 ~= 0 or badges < 0 or badges > 8 then
      error(BattleErrors.input("obedience reads an explicit badge count", {}))
    end
    return BADGE_CAPS[badges]
  end
  if type(facts.maxObedientLevel) == "number" then
    return facts.maxObedientLevel --[[@as integer]]
  end
  error(BattleErrors.input("obedience reads its profile level cap", {}))
end

--- Runs the before-action obedience checkpoint from owner and profile
--- facts. Owned and under-cap mons obey without rolling; outsiders above
--- the cap roll fixed random alternatives that never execute the ordered
--- move and never surface a decision request.
---@param inputs table<string, unknown> obedience inputs carrying actor, requested move, origin, level, profile, and stream
---@return table<string, unknown> obedience outcome carrying obeys, the executing move, and its draw trace
function MoveSelection.obey(inputs)
  assert(type(inputs) == "table", "obedience reads its checkpoint inputs")
  if type(inputs.requestedMove) ~= "string" or inputs.requestedMove == "" then
    error(BattleErrors.input("obedience names its requested move", {}))
  end
  if type(inputs.origin) ~= "table" then
    error(BattleErrors.input("obedience reads its mon origin facts", {}))
  end
  if type(inputs.level) ~= "number" then
    error(BattleErrors.input("obedience reads its mon level", {}))
  end
  if type(inputs.stream) ~= "table" then
    error(BattleErrors.input("obedience draws from the battle stream", {}))
  end
  local candidate = inputs.stream --[[@as table<string, unknown>]]
  if type(candidate.nextU16) ~= "function" then
    error(BattleErrors.input("obedience draws from the battle stream", {}))
  end
  assert(BattleRng.ALGORITHM == "gen4-lcrng", "obedience draws from the native battle stream")
  local origin = inputs.origin --[[@as table<string, unknown>]]
  if type(origin.traded) ~= "boolean" then
    error(BattleErrors.input("obedience reads its traded origin fact", {}))
  end
  local stream = inputs.stream --[[@as BattleRng]]
  local requested = inputs.requestedMove --[[@as string]]
  local level = inputs.level --[[@as integer]]
  local draws = {}
  if origin.traded ~= true then
    return { obeys = true, executingMove = requested, draws = draws }
  end
  local cap = obedienceCap(inputs.profile)
  if level <= cap then
    return { obeys = true, executingMove = requested, draws = draws }
  end
  local over = level - cap
  local threshold = 128 + over * 4
  if threshold > 224 then
    threshold = 224
  end
  local roll = stream:nextU16("obedience", { key = "OBEDIENCE" })
  draws[#draws + 1] = { label = "obedience", value = roll }
  if (roll % 256) < threshold then
    return { obeys = true, executingMove = requested, draws = draws }
  end
  local alternative = stream:nextU16("obedience-alternative", { key = "OBEDIENCE" })
  draws[#draws + 1] = { label = "obedience-alternative", value = alternative }
  local flavors = { "loafed", "napping", "wandering" }
  return {
    obeys = false,
    executingMove = requested,
    result = "no-action",
    alternative = flavors[(alternative % #flavors) + 1],
    draws = draws,
  }
end

return MoveSelection
