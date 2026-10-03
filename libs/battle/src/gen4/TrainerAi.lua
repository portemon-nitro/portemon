-- Private native trainer decision policy for the Generation IV session.
-- Transcribes the pinned opponent routines (pret/pokeheartgold
-- src/battle/trainer_ai.c: move-score initialization, target routing into
-- the singles/doubles selectors, per-flag scoring dispatched in ascending
-- bit order through the overlay_10 jump table, and reserve selection after
-- the overlay_12 opponent-controller routine): usable move slots open at
-- the native baseline with slot-ordered initialization draws, doubles
-- behavior derives from session topology through the opposing-entry pool
-- and partner-aware reserve exclusion, switching weighs reserve moves
-- and damage previews, and item choice reads live session stock.
-- Effectiveness resolves through the passed session chart, damage
-- previews reuse the shared staged arithmetic with an explicit roll, and
-- every random branch draws from the caller-owned battle stream in a
-- stable order. Decision state is transient per call: nothing persists
-- across requests and deciding never mutates battle state.

local BattleErrors = require("libs.battle.src.errors")
local BattleState = require("libs.battle.src.BattleState")
local CaptureContext = require("libs.battle.src.gen4.CaptureContext")
local Damage = require("libs.battle.src.gen4.Damage")
local Experience = require("libs.mons.src.gen4.Experience")
local ItemUse = require("libs.battle.src.gen4.ItemUse")
local Personality = require("libs.mons.src.gen4.Personality")
local Stats = require("libs.mons.src.gen4.Stats")
local StatStages = require("libs.battle.src.gen4.StatStages")
local Switching = require("libs.battle.src.gen4.Switching")
local TypeEffectiveness = require("libs.battle.src.gen4.TypeEffectiveness")

---@class TrainerAi
local TrainerAi = {}

-- Usable move slots open at the native baseline; spent and empty slots
-- stay excluded at zero for the struggle path.
TrainerAi.OPENING_SCORE = 100

-- Native flag bits with transcribed scoring behavior, in dispatch order.
-- The doubles bit never appears here: doubles behavior derives from
-- session topology instead of a stored pass.
local SUPPORTED_BITS = {
  [0] = true,
  [1] = true,
  [2] = true,
  [3] = true,
  [5] = true,
  [6] = true,
  [9] = true,
}

---@class TrainerAiMove
---@field key string executing move identity, empty for vacant slots
---@field moveType string semantic move type
---@field power integer compiled move power, zero for status moves
---@field category string physical, special, or status
---@field accuracy integer compiled hit chance
---@field usable boolean false for vacant and power-point-exhausted slots

---@class TrainerAiStats
---@field types string[] semantic combatant types in declared order
---@field level integer battle level
---@field attack integer stage-effective physical attack
---@field defense integer stage-effective physical defense
---@field specialAttack integer stage-effective special attack
---@field specialDefense integer stage-effective special defense

---@class TrainerAiAuthorities
---@field chart table<string, unknown> session chart resolving directed pairs
---@field moveFacts table<string, table<string, unknown>> immutable move facts carried by the session
---@field speciesFacts table<string, table<integer, table<string, unknown>>> static species facts by species and form
---@field itemFacts table<string, table<string, unknown>> immutable item facts carried by the session

--- Translates generated pass names to native flag bits in ascending
--- dispatch order. Malformed, unknown, and unsupported names fail closed
--- with structured missing behavior before any draw instead of answering
--- a fallback move. Repeated names collapse to one bit.
---@param aiPasses string[] generated pass names
---@return integer[] native flag bits in ascending order
function TrainerAi.parsePasses(aiPasses)
  assert(type(aiPasses) == "table", "trainer passes arrive as a name list")
  local seen = {}
  local bits = {}
  for index, pass in ipairs(aiPasses) do
    local digits = type(pass) == "string" and pass:match("^ai_pass_(%d+)$") or nil
    local bit = (type(digits) == "string" and tonumber(digits)) or nil
    if bit == nil or SUPPORTED_BITS[bit] ~= true then
      error(BattleErrors.missingBehavior("trainer passes name a supported native flag", {
        pass = tostring(pass),
        index = index,
      }))
    end
    assert(bit ~= nil, "supported pass bits stay numeric")
    if seen[bit] ~= true then
      seen[bit] = true
      bits[#bits + 1] = bit
    end
  end
  table.sort(bits)
  return bits
end

---@param chart table<string, unknown> session chart resolving directed pairs
---@param moveType string attacking type under evaluation
---@param defenderTypes string[] defending types in declared order
---@return integer numerator
---@return integer denominator combined multiplier for the directed pair set
local function combineMultiplier(chart, moveType, defenderTypes)
  local resolved = TypeEffectiveness.resolve(chart, moveType, defenderTypes, {})
  return resolved.numerator, resolved.denominator
end

---@param moveType string attacking type under evaluation
---@param userTypes string[] attacker types in declared order
---@return integer numerator
---@return integer denominator same-type attack bonus
local function stabPair(moveType, userTypes)
  if TypeEffectiveness.stab(moveType, userTypes) then
    return 3, 2
  end
  return 1, 1
end

---@param power integer compiled move power
---@param stabNumerator integer same-type attack bonus numerator
---@param stabDenominator integer same-type attack bonus denominator
---@param effectNumerator integer combined effectiveness numerator
---@param effectDenominator integer combined effectiveness denominator
---@return integer native score points for the matchup
local function matchupPoints(power, stabNumerator, stabDenominator, effectNumerator, effectDenominator)
  return math.floor((power * stabNumerator * effectNumerator) / (stabDenominator * effectDenominator))
end

---@param value unknown candidate battle stat under estimation
---@param name string stat being read
---@return integer validated battle stat
local function checkStat(value, name)
  if type(value) ~= "number" or value % 1 ~= 0 or value < 1 then
    error(BattleErrors.missingBehavior("trainer estimation reads its battle stats", { stat = name }))
  end
  return value
end

---@param types unknown candidate semantic types under estimation
---@return string[] validated semantic types in declared order
local function checkTypes(types)
  if type(types) ~= "table" or #types == 0 then
    error(BattleErrors.missingBehavior("trainer estimation reads its semantic types", {}))
  end
  local out = {}
  for _, key in
    ipairs(types --[[@as string[] ]])
  do
    if type(key) ~= "string" or key == "" then
      error(BattleErrors.missingBehavior("trainer estimation reads its semantic types", {}))
    end
    out[#out + 1] = key
  end
  return out
end

---@param stats unknown candidate battle stats under estimation
---@return TrainerAiStats validated battle stats and types
local function checkFighterStats(stats)
  assert(type(stats) == "table", "estimation reads explicit battle stats")
  local record = stats --[[@as table<string, unknown>]]
  return {
    types = checkTypes(record.types),
    level = checkStat(record.level, "level"),
    attack = checkStat(record.attack, "attack"),
    defense = checkStat(record.defense, "defense"),
    specialAttack = checkStat(record.specialAttack, "specialAttack"),
    specialDefense = checkStat(record.specialDefense, "specialDefense"),
  }
end

---@param move unknown candidate move under estimation
---@return TrainerAiMove validated move facts for scoring
local function checkScoringMove(move)
  assert(type(move) == "table", "estimation reads explicit move facts")
  local record = move --[[@as table<string, unknown>]]
  if type(record.key) ~= "string" then
    error(BattleErrors.missingBehavior("trainer estimation reads its move identity", {}))
  end
  if type(record.moveType) ~= "string" or record.moveType == "" then
    error(BattleErrors.missingBehavior("trainer estimation reads its move type", { key = record.key }))
  end
  if type(record.power) ~= "number" or record.power % 1 ~= 0 or record.power < 0 then
    error(BattleErrors.missingBehavior("trainer estimation reads its compiled move power", { key = record.key }))
  end
  if type(record.category) ~= "string" or record.category == "" then
    error(BattleErrors.missingBehavior("trainer estimation reads its move category", { key = record.key }))
  end
  if type(record.accuracy) ~= "number" or record.accuracy % 1 ~= 0 or record.accuracy < 0 then
    error(BattleErrors.missingBehavior("trainer estimation reads its compiled accuracy", { key = record.key }))
  end
  return {
    key = record.key --[[@as string]],
    moveType = record.moveType --[[@as string]],
    power = record.power --[[@as integer]],
    category = record.category --[[@as string]],
    accuracy = record.accuracy --[[@as integer]],
    usable = record.usable == true,
  }
end

-- Estimates one strike through the shared staged arithmetic with an
-- explicit maximum roll, so previews draw nothing from the decision
-- stream. Only damaging moves preview; callers skip status moves.
---@param chart table<string, unknown> session chart resolving directed pairs
---@param attacker TrainerAiStats attacker stats and types under estimation
---@param move TrainerAiMove damaging move under estimation
---@param defender TrainerAiStats defender stats and types under estimation
---@param stream table<string, unknown> caller-owned battle stream, never drawn by previews
---@return integer estimated damage amount
local function previewDamage(chart, attacker, move, defender, stream)
  assert(move.power > 0, "damage previews estimate damaging moves")
  local effectNumerator, effectDenominator = combineMultiplier(chart, move.moveType, defender.types)
  local stabNumerator, stabDenominator = stabPair(move.moveType, attacker.types)
  local attack = attacker.attack
  local defense = defender.defense
  if move.category == "special" then
    attack = attacker.specialAttack
    defense = defender.specialDefense
  end
  local result = Damage.calculate({
    level = attacker.level,
    power = move.power,
    attack = attack,
    defense = defense,
    stab = { numerator = stabNumerator, denominator = stabDenominator },
    effectiveness = { numerator = effectNumerator, denominator = effectDenominator },
    randomPercent = 100,
  }, stream)
  return result.amount
end

---@param move TrainerAiMove candidate move under the damaging check
---@return boolean true for usable moves with compiled power
local function isDamaging(move)
  return move.usable and move.power > 0
end

---@param chart table<string, unknown> session chart resolving directed pairs
---@param slots TrainerAiMove[] four native move slots in source order
---@param user TrainerAiStats acting stats and types under scoring
---@param foe TrainerAiStats opposing stats and types under scoring
---@param foeHp integer opposing health bounding the faint check
---@param bit integer enabled native flag bit under evaluation
---@param scores table<integer, integer> native score points under adjustment
---@param stream table<string, unknown> caller-owned battle stream for flag draws
local function applyBit(chart, slots, user, foe, foeHp, bit, scores, stream)
  if bit == 0 then
    -- The bad-move check scores every usable slot by its matchup and
    -- withholds points from negated strikes: a move the foe is immune
    -- to falls below scoreless status attempts instead of tying them.
    -- One unconditional flag draw advances the stream in dispatch order.
    stream:nextU16("flag_0", { flag = 0 })
    for index, move in ipairs(slots) do
      if move.usable then
        local effectNumerator, effectDenominator = combineMultiplier(chart, move.moveType, foe.types)
        local stabNumerator, stabDenominator = stabPair(move.moveType, user.types)
        scores[index] = scores[index]
          + matchupPoints(move.power, stabNumerator, stabDenominator, effectNumerator, effectDenominator)
        if effectNumerator == 0 then
          scores[index] = scores[index] - 10
        end
      end
    end
  elseif bit == 1 then
    -- Faint-seeking prefers the finishing blow: damaging moves weaker
    -- than the strongest candidate lose a point, while a doubly
    -- effective strike gains two unless the single routine draw declines
    -- it. That draw is unconditional in dispatch order even without a
    -- doubly-effective candidate; the bonus only ever lands on one.
    local bonusDraw = stream:nextU16("faint_bonus", { flag = 1 })
    local best = 0
    for _, move in ipairs(slots) do
      if isDamaging(move) and move.power > best then
        best = move.power
      end
    end
    local doubles = {}
    for index, move in ipairs(slots) do
      if isDamaging(move) then
        if move.power < best then
          scores[index] = scores[index] - 1
        end
        local effectNumerator, effectDenominator = combineMultiplier(chart, move.moveType, foe.types)
        if effectNumerator == 4 * effectDenominator then
          doubles[#doubles + 1] = index
        end
      end
    end
    if #doubles > 0 and bonusDraw % 100 < 80 then
      for _, index in ipairs(doubles) do
        scores[index] = scores[index] + 2
      end
    end
  elseif bit == 2 then
    -- Effectiveness emphasis favors clearly super-effective strikes and
    -- withholds points from resisted ones; immunities stay with the
    -- bad-move check. One unconditional flag draw advances the stream
    -- in dispatch order.
    stream:nextU16("flag_2", { flag = 2 })
    for index, move in ipairs(slots) do
      if isDamaging(move) then
        local effectNumerator, effectDenominator = combineMultiplier(chart, move.moveType, foe.types)
        if effectNumerator >= 2 * effectDenominator then
          scores[index] = scores[index] + 2
        elseif effectNumerator > 0 and effectNumerator < effectDenominator then
          scores[index] = scores[index] - 2
        end
      end
    end
  elseif bit == 3 then
    -- Same-type preference backs the reliable strike: damaging moves
    -- with the attack bonus gain points while off-type attempts lose one.
    -- One unconditional flag draw advances the stream in dispatch order.
    stream:nextU16("flag_3", { flag = 3 })
    for index, move in ipairs(slots) do
      if isDamaging(move) then
        if TypeEffectiveness.stab(move.moveType, user.types) then
          scores[index] = scores[index] + 2
        else
          scores[index] = scores[index] - 1
        end
      end
    end
  elseif bit == 5 then
    -- Health awareness seeks the knockout: moves whose damage preview
    -- reaches the foe's remaining health gain points for the finish.
    for index, move in ipairs(slots) do
      if isDamaging(move) and previewDamage(chart, user, move, foe, stream) >= foeHp then
        scores[index] = scores[index] + 3
      end
    end
  elseif bit == 6 then
    -- Accuracy preference avoids shaky strikes while a reliable
    -- damaging move exists: low-accuracy attempts lose points.
    local reliable = false
    for _, move in ipairs(slots) do
      if isDamaging(move) and move.accuracy >= 90 then
        reliable = true
        break
      end
    end
    if reliable then
      for index, move in ipairs(slots) do
        if isDamaging(move) and move.accuracy < 90 then
          scores[index] = scores[index] - 2
        end
      end
    end
  elseif bit == 9 then
    -- Unpredictability applies its small bonus deterministically to the
    -- lowest-index usable slot. ESTIMATE: the source routine draws zero
    -- times and its exact retail recipient order is unverified, so no
    -- draw occurs here.
    local usable = {}
    for index, move in ipairs(slots) do
      if move.usable then
        usable[#usable + 1] = index
      end
    end
    if #usable > 0 then
      scores[usable[1]] = scores[usable[1]] + 1
    end
  else
    error(BattleErrors.missingBehavior("trainer scoring names a transcribed native flag", { flag = bit }))
  end
end

---@class TrainerAiScoredSlot
---@field slot integer zero-based native move slot
---@field key string executing move identity, empty for vacant slots
---@field score integer native score points after flag evaluation

--- Scores the four native move slots exactly as the source
--- initialization does: usable slots open at the native baseline,
--- unavailable slots stay excluded at zero, and the four initialization
--- draws occur in source slot order before enabled flag evaluation.
--- Enabled flags dispatch in ascending bit order; each enabled bit 0-3
--- spends one unconditional flag draw in that order. The initialization
--- draws advance the caller-owned stream with no reader anywhere else,
--- matching the source stream shape; final selection draws separately.
---@param chart table<string, unknown> session chart resolving directed pairs
---@param slots TrainerAiMove[] four native move slots in source order
---@param user TrainerAiStats acting stats and types under scoring
---@param foe TrainerAiStats opposing stats and types under scoring
---@param foeHp integer opposing health bounding the faint check
---@param bits integer[] enabled native flag bits in ascending order
---@param stream table<string, unknown> caller-owned battle stream for flag draws
---@return TrainerAiScoredSlot[] scored slots in source slot order
function TrainerAi.scoreSlots(chart, slots, user, foe, foeHp, bits, stream)
  assert(type(chart) == "table", "scoring resolves effectiveness through the session chart")
  assert(type(slots) == "table" and #slots == 4, "scoring covers the four native move slots")
  assert(type(stream) == "table" and type(stream.nextU16) == "function", "scoring draws from the battle stream")
  assert(type(bits) == "table", "scoring dispatches the enabled flag bits")
  assert(type(foeHp) == "number" and foeHp % 1 == 0 and foeHp >= 0, "scoring bounds its faint check")
  local checked = {}
  for _, slot in ipairs(slots) do
    checked[#checked + 1] = checkScoringMove(slot)
  end
  local attacker = checkFighterStats(user)
  local defender = checkFighterStats(foe)
  local scores = {}
  local scored = {}
  for index, move in ipairs(checked) do
    stream:nextU16("score_init_" .. (index - 1), { slot = index - 1 })
    if move.usable then
      scores[index] = TrainerAi.OPENING_SCORE
    else
      scores[index] = 0
    end
    scored[index] = { slot = index - 1, key = move.key, score = 0 }
  end
  for _, bit in ipairs(bits) do
    assert(type(bit) == "number" and bit % 1 == 0, "enabled flag bits stay numeric")
    applyBit(chart, checked, attacker, defender, foeHp, bit, scores, stream)
  end
  for index, entry in ipairs(scored) do
    entry.score = scores[index]
  end
  return scored
end

--- Selects the executing move from scored slots after the source singles
--- selector (ov10_0221BF44): the highest native points win, equal-top
--- ties break uniformly through exactly one selection draw, and a lone
--- leader still spends that draw so the downstream stream never shifts.
---@param scored TrainerAiScoredSlot[] scored slots in source slot order
---@param stream table<string, unknown> caller-owned battle stream for the selection draw
---@return integer zero-based native move slot answering the foe
function TrainerAi.selectMove(scored, stream)
  assert(type(scored) == "table" and #scored > 0, "move selection reads its scored slots")
  assert(type(stream) == "table" and type(stream.nextU16) == "function", "move selection draws from the battle stream")
  local top = scored[1].score
  for index = 2, #scored do
    if scored[index].score > top then
      top = scored[index].score
    end
  end
  local tied = {}
  for _, entry in ipairs(scored) do
    assert(type(entry.score) == "number", "scored slots carry their native points")
    assert(type(entry.slot) == "number", "scored slots carry their native slot")
    if entry.score == top then
      tied[#tied + 1] = entry.slot
    end
  end
  assert(#tied > 0, "a top score always names at least one slot")
  local draw = stream:nextU16("selection_roll", { tied = #tied })
  return tied[(draw % #tied) + 1]
end

--- Selects the opposing battler in source target order: with more than
--- one live opposing entry one flag draw chooses uniformly among them in
--- position order, while a lone foe is addressed with no draw. Two
--- opponents stay deterministic for a fixed seed.
---@param opponents integer[] live opposing combatants in position order
---@param stream table<string, unknown> caller-owned battle stream for the target draw
---@return integer chosen opposing combatant
function TrainerAi.selectTarget(opponents, stream)
  assert(type(opponents) == "table" and #opponents > 0, "target selection reads its opposing entries")
  assert(
    type(stream) == "table" and type(stream.nextU16) == "function",
    "target selection draws from the battle stream"
  )
  for _, combatant in ipairs(opponents) do
    assert(
      type(combatant) == "number" and combatant % 1 == 0 and combatant >= 1,
      "opposing entries name their combatant"
    )
  end
  if #opponents == 1 then
    return opponents[1]
  end
  local draw = stream:nextU16("target_foe", { opponents = #opponents })
  return opponents[(draw % #opponents) + 1]
end

---@class TrainerAiReserveCandidate
---@field id integer benched combatant identity
---@field stats TrainerAiStats battle stats and types under evaluation
---@field moves TrainerAiMove[] candidate moves in slot order

---@param chart table<string, unknown> session chart resolving directed pairs
---@param moves TrainerAiMove[] candidate moves in slot order
---@param stats TrainerAiStats attacker stats and types under preview
---@param foe TrainerAiStats opposing stats and types under preview
---@param stream table<string, unknown> caller-owned battle stream, never drawn by previews
---@return integer best damage preview, zero without a damaging move
local function bestPreview(chart, moves, stats, foe, stream)
  local best = 0
  for _, move in ipairs(moves) do
    if isDamaging(move) then
      local preview = previewDamage(chart, stats, move, foe, stream)
      if preview > best then
        best = preview
      end
    end
  end
  return best
end

---@param chart table<string, unknown> session chart resolving directed pairs
---@param foeMoves TrainerAiMove[] opposing moves in slot order
---@param candidateTypes string[] reserve types in declared order
---@return integer numerator
---@return integer denominator strongest incoming multiplier, neutral without a damaging foe move
local function incomingThreat(chart, foeMoves, candidateTypes)
  local bestNumerator, bestDenominator = 1, 1
  for _, move in ipairs(foeMoves) do
    if isDamaging(move) then
      local numerator, denominator = combineMultiplier(chart, move.moveType, candidateTypes)
      if numerator * bestDenominator > bestNumerator * denominator then
        bestNumerator, bestDenominator = numerator, denominator
      end
    end
  end
  return bestNumerator, bestDenominator
end

---@class TrainerAiRank
---@field damage integer damage class, one with a damaging move and zero without
---@field threatNumerator integer strongest incoming multiplier numerator
---@field threatDenominator integer strongest incoming multiplier denominator
---@field preview integer best damage preview, zero without a damaging move

---@param chart table<string, unknown> session chart resolving directed pairs
---@param stats TrainerAiStats reserve stats and types under ranking
---@param moves TrainerAiMove[] reserve moves in slot order
---@param foe TrainerAiStats opposing stats and types under ranking
---@param foeMoves TrainerAiMove[] opposing moves in slot order
---@param stream table<string, unknown> caller-owned battle stream, never drawn by ranking
---@return TrainerAiRank rank tuple comparing damage class, incoming threat, then preview
local function rankEntry(chart, stats, moves, foe, foeMoves, stream)
  local preview = bestPreview(chart, moves, stats, foe, stream)
  local threatNumerator, threatDenominator = incomingThreat(chart, foeMoves, stats.types)
  return {
    damage = preview > 0 and 1 or 0,
    threatNumerator = threatNumerator,
    threatDenominator = threatDenominator,
    preview = preview,
  }
end

---@param left TrainerAiRank left rank tuple under comparison
---@param right TrainerAiRank right rank tuple under comparison
---@return integer positive when left outranks right, negative when it trails, zero when tied
local function compareRanks(left, right)
  if left.damage ~= right.damage then
    return left.damage - right.damage
  end
  local incoming = right.threatNumerator * left.threatDenominator - left.threatNumerator * right.threatDenominator
  if incoming ~= 0 then
    return incoming
  end
  return left.preview - right.preview
end

--- Chooses the reserve after the source opponent-controller routine:
--- eligibility (living, benched) is the caller's contract, and ranking
--- weighs move and damage checks over exposure alone, so a damaging
--- reserve answers where a harmless one with identical typing cannot.
--- Rank ties resolve deterministically in evaluation order (first-found
--- wins). ESTIMATE: the source switch routine draws zero times and its
--- exact retail tie order is unverified, so ties keep existing order
--- without drawing; without candidates nothing draws and no switch answers.
---@param chart table<string, unknown> session chart resolving directed pairs
---@param candidates TrainerAiReserveCandidate[] living benched reserves in roster order
---@param foe TrainerAiStats opposing stats and types under ranking
---@param foeMoves TrainerAiMove[] opposing moves in slot order
---@param stream table<string, unknown> caller-owned battle stream for the consideration draw
---@return integer? benched combatant answering the foe, nil without candidates
function TrainerAi.chooseReserve(chart, candidates, foe, foeMoves, stream)
  assert(type(chart) == "table", "reserve selection resolves effectiveness through the session chart")
  assert(type(candidates) == "table", "reserve selection reads its eligible reserves")
  assert(
    type(stream) == "table" and type(stream.nextU16) == "function",
    "reserve selection draws from the battle stream"
  )
  if #candidates == 0 then
    return nil
  end
  local defender = checkFighterStats(foe)
  local checkedFoeMoves = {}
  for _, move in ipairs(foeMoves or {}) do
    checkedFoeMoves[#checkedFoeMoves + 1] = checkScoringMove(move)
  end
  local ranked = {}
  for order, candidate in ipairs(candidates) do
    assert(type(candidate) == "table", "reserves carry their combatant record")
    local record = candidate --[[@as table<string, unknown>]]
    if type(record.id) ~= "number" or record.id % 1 ~= 0 or record.id < 1 then
      error(BattleErrors.missingBehavior("reserve selection names its benched combatant", {}))
    end
    local stats = checkFighterStats(record.stats)
    local moves = {}
    for _, move in
      ipairs(record.moves --[[@as table<integer, unknown>]] or {})
    do
      moves[#moves + 1] = checkScoringMove(move)
    end
    ranked[#ranked + 1] = {
      id = record.id --[[@as integer]],
      order = order,
      rank = rankEntry(chart, stats, moves, defender, checkedFoeMoves, stream),
    }
  end
  table.sort(ranked, function(left, right)
    local compared = compareRanks(left.rank, right.rank)
    if compared ~= 0 then
      return compared > 0
    end
    return left.order < right.order
  end)
  return ranked[1].id
end

--- Ranks one roster entry for the switch gate through the same
--- move/damage checks reserve selection uses.
---@param chart table<string, unknown> session chart resolving directed pairs
---@param stats TrainerAiStats entry stats and types under ranking
---@param moves TrainerAiMove[] entry moves in slot order
---@param foe TrainerAiStats opposing stats and types under ranking
---@param foeMoves TrainerAiMove[] opposing moves in slot order
---@param stream table<string, unknown> caller-owned battle stream, never drawn by ranking
---@return TrainerAiRank rank tuple for the entry
function TrainerAi.rankEntry(chart, stats, moves, foe, foeMoves, stream)
  assert(type(chart) == "table", "switch gating resolves effectiveness through the session chart")
  local checkedMoves = {}
  for _, move in ipairs(moves) do
    checkedMoves[#checkedMoves + 1] = checkScoringMove(move)
  end
  local checkedFoeMoves = {}
  for _, move in ipairs(foeMoves) do
    checkedFoeMoves[#checkedFoeMoves + 1] = checkScoringMove(move)
  end
  return rankEntry(chart, checkFighterStats(stats), checkedMoves, checkFighterStats(foe), checkedFoeMoves, stream)
end

--- Compares two rank tuples from rankEntry: positive when the left
--- entry outranks the right, negative when it trails, zero when tied.
---@param left TrainerAiRank left rank tuple under comparison
---@param right TrainerAiRank right rank tuple under comparison
---@return integer rank comparison for the switch gate
function TrainerAi.compareRanks(left, right)
  assert(type(left) == "table" and type(right) == "table", "rank comparison reads two rank tuples")
  return compareRanks(left, right)
end

---@param speciesFacts table<string, table<integer, table<string, unknown>>> static species facts by species and form
---@param mon table<string, unknown> battle mon record under fact sampling
---@return table<string, unknown> static species facts for the record
local function staticFacts(speciesFacts, mon)
  assert(type(speciesFacts) == "table", "estimation reads the session species facts")
  local species = mon.species
  local form = mon.form
  if type(species) ~= "string" or species == "" or type(form) ~= "number" or form % 1 ~= 0 then
    error(BattleErrors.missingBehavior("trainer estimation reads its combat facts", { fact = "species" }))
  end
  local byForm = speciesFacts[species]
  local static = type(byForm) == "table" and byForm[form]
  if type(static) ~= "table" then
    error(BattleErrors.missingBehavior("trainer estimation reads its static species facts", { fact = species }))
  end
  return static --[[@as table<string, unknown>]]
end

---@param mon table<string, unknown> battle mon record under estimation
---@param stages unknown battle-local stat stages for the entry
---@param speciesFacts table<string, table<integer, table<string, unknown>>> static species facts by species and form
---@return TrainerAiStats level and stage-effective battle stats for estimation
local function estimateFighter(mon, stages, speciesFacts)
  if type(mon) ~= "table" then
    error(BattleErrors.missingBehavior("trainer estimation reads its combat facts", { fact = "mon" }))
  end
  local record = mon --[[@as table<string, unknown>]]
  local static = staticFacts(speciesFacts, record)
  if type(static.baseStats) ~= "table" or type(static.growthCurve) ~= "table" or type(static.types) ~= "table" then
    error(BattleErrors.missingBehavior("trainer estimation reads its static species facts", {
      fact = record.species,
    }))
  end
  local experience = record.experience
  local personality = record.personality
  if type(experience) ~= "number" or experience % 1 ~= 0 or experience < 0 then
    error(BattleErrors.missingBehavior("trainer estimation reads its combat facts", { fact = "experience" }))
  end
  if type(personality) ~= "number" or personality % 1 ~= 0 or personality < 0 then
    error(BattleErrors.missingBehavior("trainer estimation reads its combat facts", { fact = "personality" }))
  end
  if type(record.ivs) ~= "table" or type(record.evs) ~= "table" then
    error(BattleErrors.missingBehavior("trainer estimation reads its combat facts", { fact = "effort" }))
  end
  local level = Experience.level(static.growthCurve --[[@as integer[] ]], experience)
  local nature = Personality.nature(personality)
  local stats = Stats.calculate(
    static.baseStats --[[@as table<string, integer>]],
    record.ivs --[[@as table<string, integer>]],
    record.evs --[[@as table<string, integer>]],
    level,
    nature
  )
  if type(stages) ~= "table" then
    error(BattleErrors.missingBehavior("trainer estimation reads its battle-local stages", {}))
  end
  local staged = stages --[[@as table<string, integer>]]
  local combat = {
    level = level,
    types = {} --[[@as string[] ]],
    attack = 0,
    defense = 0,
    specialAttack = 0,
    specialDefense = 0,
  }
  for _, key in
    ipairs(static.types --[[@as string[] ]])
  do
    if type(key) ~= "string" or key == "" then
      error(BattleErrors.missingBehavior("trainer estimation reads its semantic type facts", { fact = "types" }))
    end
    combat.types[#combat.types + 1] = key
  end
  for _, key in ipairs({ "attack", "defense", "specialAttack", "specialDefense" }) do
    local stage = staged[key] or 0
    if type(stage) ~= "number" or stage % 1 ~= 0 or stage < StatStages.MIN or stage > StatStages.MAX then
      error(BattleErrors.missingBehavior("trainer estimation reads its battle-local stages", {}))
    end
    combat[key] = StatStages.effective(stats[key] --[[@as integer]], stage, key)
  end
  return combat
end

---@param moveFacts table<string, table<string, unknown>> immutable move facts carried by the session
---@param key unknown executing move identity under resolution
---@return table<string, unknown> immutable move facts for the identity
local function factsFor(moveFacts, key)
  if type(key) ~= "string" or key == "" then
    error(BattleErrors.missingBehavior("trainer estimation reads its move identity", {}))
  end
  local record = moveFacts[key]
  if type(record) ~= "table" then
    error(BattleErrors.missingBehavior("trainer estimation reads its compiled move facts", { key = key }))
  end
  return record
end

---@param mon table<string, unknown> battle mon record under slot resolution
---@param moveFacts table<string, table<string, unknown>> immutable move facts carried by the session
---@return TrainerAiMove[] four native move slots in source order
local function resolveSlots(mon, moveFacts)
  local entries = mon.moves
  if type(entries) ~= "table" then
    error(BattleErrors.missingBehavior("trainer estimation reads its move entries", {}))
  end
  local slots = {}
  for index = 1, 4 do
    local entry = entries[index]
    if type(entry) ~= "table" then
      slots[index] = { key = "", moveType = "typeless", power = 0, category = "status", accuracy = 0, usable = false }
    else
      local record = entry --[[@as table<string, unknown>]]
      local facts = factsFor(moveFacts, record.move)
      local power = facts.power
      local moveType = facts.moveType
      local category = facts.category
      local accuracy = facts.accuracy
      if type(power) ~= "number" or power % 1 ~= 0 or power < 0 then
        error(BattleErrors.missingBehavior("trainer estimation reads its compiled move power", { key = record.move }))
      end
      if type(moveType) ~= "string" or moveType == "" then
        error(BattleErrors.missingBehavior("trainer estimation reads its move type", { key = record.move }))
      end
      if type(category) ~= "string" or category == "" then
        error(BattleErrors.missingBehavior("trainer estimation reads its move category", { key = record.move }))
      end
      if type(accuracy) ~= "number" or accuracy % 1 ~= 0 or accuracy < 0 then
        error(BattleErrors.missingBehavior("trainer estimation reads its compiled accuracy", { key = record.move }))
      end
      local pp = record.pp
      slots[index] = {
        key = record.move,
        moveType = moveType,
        power = power,
        category = category,
        accuracy = accuracy,
        usable = type(pp) ~= "number" or pp > 0,
      }
    end
  end
  return slots
end

---@param state table<string, unknown> live battle state under inspection
---@param ownSide integer acting side under opponent resolution
---@return table<integer, table<string, unknown>> live opposing entries in position order
local function opposingEntries(state, ownSide)
  local opponents = {}
  for _, positionId in
    ipairs(state.positionOrder --[[@as integer[] ]])
  do
    local position = BattleState.position(state, positionId)
    local occupant = position.occupant
    if occupant ~= nil and position.side ~= ownSide then
      local combatant = BattleState.combatant(state, occupant --[[@as integer]])
      if combatant.active ~= nil then
        opponents[#opponents + 1] = { position = positionId, combatant = occupant }
      end
    end
  end
  return opponents
end

---@param state table<string, unknown> live battle state under inspection
---@param combatantId integer acting combatant under the trap check
---@return boolean true while binding effects hold the combatant down
local function isTrapped(state, combatantId)
  local combatant = BattleState.combatant(state, combatantId)
  local held = combatant.trap
  if type(held) == "table" and held.held == true then
    return true
  end
  local bag = state.effectBag
  if type(bag) == "table" and type(bag.capture) == "function" then
    local capture = bag.capture --[[@as fun(self: table<string, unknown>): table<integer, table<string, unknown>>]]
    for _, record in ipairs(capture(bag)) do
      local scope = record.scope
      if
        (record.key == "bind" or record.key == "trapped")
        and type(scope) == "table"
        and scope.combatant == combatantId
      then
        return true
      end
    end
  end
  return false
end

---@param state table<string, unknown> live battle state under reserve inspection
---@param participant table<string, unknown> acting participant owning the roster
---@param exclude table<integer, boolean> combatants already answering this request
---@return integer[] living benched roster identities in roster order
local function livingReserves(state, participant, exclude)
  local reserves = {}
  for _, combatantId in
    ipairs(participant.roster --[[@as integer[] ]])
  do
    local combatant = BattleState.combatant(state, combatantId --[[@as integer]])
    if
      combatant.active == nil
      and combatant.hp --[[@as integer]]
        > 0
      and not exclude[combatantId]
    then
      reserves[#reserves + 1] = combatantId
    end
  end
  return reserves
end

---@param state table<string, unknown> live battle state under inspection
---@param participant table<string, unknown> acting participant owning the inventory
---@param picked table<string, integer> same-item picks already answering this request
---@return string[] stocked non-ball item keys with live quantity in stable order
local function stockedCandidates(state, participant, picked)
  local inventoryId = participant.inventoryId
  if type(inventoryId) ~= "string" then
    return {}
  end
  local inventories = state.inventories
  if type(inventories) ~= "table" then
    error(BattleErrors.missingBehavior("trainer decisions read their session inventory", {}))
  end
  local stock = inventories[inventoryId]
  if stock == nil then
    error(BattleErrors.missingBehavior("trainer decisions read their session inventory", {
      inventory = inventoryId,
    }))
  end
  local quantities = stock.quantities
  if type(quantities) ~= "table" then
    error(BattleErrors.missingBehavior("trainer decisions read their session inventory", {
      inventory = inventoryId,
    }))
  end
  local keys = {}
  for key, units in
    pairs(quantities --[[@as table<string, integer>]])
  do
    if
      type(key) == "string"
      and key ~= ""
      and type(units) == "number"
      and units - (picked[inventoryId .. ":" .. key] or 0) >= 1
      and not CaptureContext.isBall(key)
    then
      keys[#keys + 1] = key
    end
  end
  table.sort(keys)
  return keys
end

--- Answers one actor of the trainer request from live session state and
--- facts, following the source decision flow: move initialization, target
--- selection, flag dispatch, score selection, switch logic, item
--- decision, and choice construction. Reads only; battle state, stock,
--- and stream ownership stay with the caller.
---@param state table<string, unknown> live battle state under inspection
---@param authorities TrainerAiAuthorities session-owned read authorities
---@param participant table<string, unknown> acting participant owning passes and stock
---@param actor table<string, unknown> addressed actor with its entry token
---@param opponents table<integer, table<string, unknown>> live opposing entries in position order
---@param claimed table<integer, boolean> reserves already answering this request
---@param picked table<string, integer> same-item picks already answering this request
---@param stream table<string, unknown> caller-owned battle stream for decision draws
---@return table<string, unknown> choice in the shared decision shape
local function answerActor(state, authorities, participant, actor, opponents, claimed, picked, stream)
  local combatant = BattleState.combatant(state, actor.combatant --[[@as integer]])
  local active = combatant.active
  if type(active) ~= "table" or active.activation ~= actor.activation then
    error(BattleErrors.input("locked references die with their entry", { combatant = actor.combatant }))
  end
  local context = participant.context
  if type(context) ~= "table" or type(context.aiPasses) ~= "table" then
    error(BattleErrors.missingBehavior("trainer sides carry their generated pass facts", {
      controller = participant.controller,
    }))
  end
  local bits = TrainerAi.parsePasses(context.aiPasses --[[@as string[] ]])
  local user =
    estimateFighter(combatant.mon --[[@as table<string, unknown>]], combatant.stages, authorities.speciesFacts)
  local slots = resolveSlots(combatant.mon --[[@as table<string, unknown>]], authorities.moveFacts)

  local foeIds = {}
  for _, opposed in ipairs(opponents) do
    foeIds[#foeIds + 1] = opposed.combatant
  end
  local foeId = TrainerAi.selectTarget(foeIds, stream)
  local foePosition = 0
  for _, opposed in ipairs(opponents) do
    if opposed.combatant == foeId then
      foePosition = opposed.position
    end
  end
  assert(foePosition >= 1, "selected targets resolve to their position")
  local foe = BattleState.combatant(state, foeId)
  local foeStats = estimateFighter(foe.mon --[[@as table<string, unknown>]], foe.stages, authorities.speciesFacts)
  local foeHp = foe.hp
  if type(foeHp) ~= "number" or foeHp % 1 ~= 0 or foeHp < 0 then
    error(BattleErrors.missingBehavior("trainer estimation reads its opposing health", {}))
  end
  local scored = TrainerAi.scoreSlots(authorities.chart, slots, user, foeStats, foeHp, bits, stream)

  local usable = false
  for _, slot in ipairs(slots) do
    if slot.usable then
      usable = true
      break
    end
  end

  -- Switch logic weighs the benched reserves through the source
  -- move/damage checks: a reserve that strictly outranks the holder
  -- answers, while trapping holds the exchange and an empty bench holds
  -- the field without drawing.
  local exchange = nil
  if
    not isTrapped(state, actor.combatant --[[@as integer]])
  then
    local reserveIds = livingReserves(state, participant, claimed)
    if #reserveIds > 0 then
      local foeMoves = resolveSlots(foe.mon --[[@as table<string, unknown>]], authorities.moveFacts)
      local candidates = {}
      for _, reserveId in ipairs(reserveIds) do
        local reserve = BattleState.combatant(state, reserveId)
        candidates[#candidates + 1] = {
          id = reserveId,
          stats = estimateFighter(
            reserve.mon --[[@as table<string, unknown>]],
            reserve.stages,
            authorities.speciesFacts
          ),
          moves = resolveSlots(reserve.mon --[[@as table<string, unknown>]], authorities.moveFacts),
        }
      end
      local answered = TrainerAi.chooseReserve(authorities.chart, candidates, foeStats, foeMoves, stream)
      if answered ~= nil then
        local holderRank = TrainerAi.rankEntry(authorities.chart, user, slots, foeStats, foeMoves, stream)
        local answerRank = nil
        for _, candidate in ipairs(candidates) do
          if candidate.id == answered then
            answerRank =
              TrainerAi.rankEntry(authorities.chart, candidate.stats, candidate.moves, foeStats, foeMoves, stream)
          end
        end
        if answerRank ~= nil and TrainerAi.compareRanks(answerRank, holderRank) > 0 then
          local verdict = Switching.eligible({
            reason = "voluntary",
            position = active.position,
            incoming = answered,
            reserves = reserveIds,
            reserved = {},
            fainted = {},
            trap = nil,
          })
          if verdict.ok then
            exchange = answered
            claimed[answered] = true
          end
        end
      end
    end
  end

  -- Item decisions read live session stock through the shared serving
  -- planner: only a plannable serving answers, selection never consumes,
  -- and unsupported semantics fail before anything moves.
  local serving = nil
  local hp = combatant.hp
  local ceiling = combatant.maxHp
  if type(ceiling) ~= "number" then
    ceiling = combatant.entryHp
  end
  if type(hp) == "number" and type(ceiling) == "number" and hp >= 1 and hp * 4 < ceiling then
    local inventoryId = participant.inventoryId
    if type(inventoryId) == "string" then
      local plannable = {}
      for _, key in ipairs(stockedCandidates(state, participant, picked)) do
        local plan = ItemUse.plan({
          inventoryId = inventoryId,
          item = key,
          target = { kind = "combatant", combatant = actor.combatant },
        }, {
          inventories = state.inventories,
          combatants = state.combatants,
          outstanding = {},
        }, authorities.itemFacts)
        if plan.failureReason == nil then
          plannable[#plannable + 1] = key
        end
      end
      if #plannable > 0 then
        local draw = stream:nextU16("item_consider", { controller = participant.controller })
        serving = plannable[(draw % #plannable) + 1]
        picked[inventoryId .. ":" .. serving] = (picked[inventoryId .. ":" .. serving] or 0) + 1
      end
    end
  end

  if serving ~= nil then
    return {
      actor = actor,
      kind = "item",
      payload = { item = serving, target = { kind = "combatant", combatant = actor.combatant } },
    }
  end
  if exchange ~= nil then
    return { actor = actor, kind = "switch", payload = { replacement = exchange } }
  end
  -- Score selection takes the highest native points with equal-top ties
  -- broken uniformly through one selection draw (ov10_0221BF44). With
  -- no usable move the strike names the struggle state for the session
  -- to resolve without drawing.
  local moveSlot = 0
  if usable then
    moveSlot = TrainerAi.selectMove(scored, stream)
  end
  return {
    actor = actor,
    kind = "attack",
    payload = { moveSlot = moveSlot, target = { kind = "position", position = foePosition } },
  }
end

--- Answers the trainer request from live session state and facts. The
--- caller owns request validation, the decision lease, and stream
--- ownership; this resolves opponents from battle topology and returns
--- one ordinary reply for every addressed actor in source order.
---@param state table<string, unknown> live battle state under inspection
---@param authorities TrainerAiAuthorities session-owned read authorities
---@param request table<string, unknown> open internal trainer request under verification
---@param stream table<string, unknown> caller-owned battle stream for decision draws
---@return table<string, unknown> reply in the shared decision shape
function TrainerAi.answer(state, authorities, request, stream)
  assert(type(state) == "table", "trainer decisions read live battle state")
  assert(type(authorities) == "table", "trainer decisions read their session authorities")
  assert(type(request) == "table", "trainer decisions answer a pending request")
  assert(
    type(stream) == "table" and type(stream.nextU16) == "function",
    "trainer decisions draw from the battle stream"
  )
  assert(type(request.actors) == "table" and #request.actors > 0, "trainer decisions address at least one actor")
  local owner = authorities --[[@as table<string, unknown>]]
  if
    type(owner.chart) ~= "table"
    or type(owner.moveFacts) ~= "table"
    or type(owner.speciesFacts) ~= "table"
    or type(owner.itemFacts) ~= "table"
  then
    error(BattleErrors.missingBehavior("trainer decisions read their session authorities", {}))
  end
  local first = request.actors[1] --[[@as table<string, unknown>]]
  local firstCombatant = BattleState.combatant(state, first.combatant --[[@as integer]])
  local ownSide = BattleState.participant(state, firstCombatant.participant --[[@as integer]]).side --[[@as integer]]
  local opponents = opposingEntries(state, ownSide)
  if #opponents == 0 then
    error(BattleErrors.missingBehavior("trainer decisions read their opposing entry", {}))
  end
  local claimed = {}
  local picked = {}
  local choices = {}
  for _, actor in
    ipairs(request.actors --[[@as table<integer, unknown>]])
  do
    local entry = actor --[[@as table<string, unknown>]]
    local combatant = BattleState.combatant(state, entry.combatant --[[@as integer]])
    local participant = BattleState.participant(state, combatant.participant --[[@as integer]])
    choices[#choices + 1] = answerActor(state, authorities, participant, entry, opponents, claimed, picked, stream)
  end
  return {
    requestId = request.requestId,
    epoch = request.epoch,
    controller = request.controller,
    choices = choices,
  }
end

return TrainerAi
