-- Private native trainer decision policy for the Generation IV session.
-- Execution follows the pinned opponent model (pret/pokeheartgold
-- src/battle/trainer_ai.c ov10_0221BE20 for scratch initialization,
-- asm/overlay_10_trainer_ai.s ov10_0221BF44 for the singles selector,
-- ov10_0221C038 for the doubles selector, ov10_0221C278 with table
-- ov10_0222B0B4 for program dispatch over the program data at
-- ov10_02220AAC, ov10_022205BC for action order, ov10_022203A4 with the
-- opponent-controller replacement at ov12_02258800 for switching, and
-- ov10_022206B0 for trainer items): usable move slots open at the native
-- baseline with slot-ordered initialization draws whose stored
-- 100-(draw%16) thresholds later commands may read, enabled flag
-- programs run in ascending bit order, doubles evaluates candidate
-- targets through its own selector, the switch gate answers before the
-- item path, items scan ordered source slots, and persistent knowledge
-- plus slot order ride the native session record. Effectiveness resolves
-- through the passed session chart, damage previews reuse the shared
-- staged arithmetic with an explicit roll, and every random branch draws
-- from the caller-owned battle stream in a stable order. Per-evaluation
-- scratch is local and discarded; only the session record persists.

local BattleContext = require("libs.battle.src.BattleContext")
local BattleErrors = require("libs.battle.src.errors")
local BattleState = require("libs.battle.src.BattleState")
local CaptureContext = require("libs.battle.src.gen4.CaptureContext")
local Experience = require("libs.mons.src.gen4.Experience")
local ItemUse = require("libs.battle.src.gen4.ItemUse")
local Personality = require("libs.mons.src.gen4.Personality")
local StatStages = require("libs.battle.src.gen4.StatStages")
local Stats = require("libs.mons.src.gen4.Stats")
local Switching = require("libs.battle.src.gen4.Switching")
local TrainerAiProgram = require("libs.battle.src.gen4.TrainerAiProgram")
local TypeEffectiveness = require("libs.battle.src.gen4.TypeEffectiveness")

---@class TrainerAi
local TrainerAi = {}

-- Usable move slots open at the native baseline; spent and empty slots
-- stay excluded at zero for the struggle path.
TrainerAi.OPENING_SCORE = 100

-- Forward declarations: scoring can run from its pinned boundary before
-- the shared evaluation helpers below are defined.
local initThresholds
local executePrograms
local buildEvaluationFacts

-- Schema mark for the persisted native record.
TrainerAi.MEMORY_VERSION = 1

-- Native flag bits with program data, in dispatch order. The doubles bit
-- is forced by the live battle format in doubles rather than stored passes,
-- but its program is transcribed here like every other supported pass.
local SUPPORTED_BITS = {
  [0] = true,
  [1] = true,
  [2] = true,
  [3] = true,
  [5] = true,
  [6] = true,
  [7] = true,
  [9] = true,
}

-- Live battle formats that route attack evaluation through the doubles
-- selector. Singles spellings stay on the singles path.
local DOUBLE_FORMATS = {
  double = true,
  doubles = true,
}

-- Trapping abilities that hold the exchange at the switch gate.
local TRAPPING_ABILITIES = {
  SHADOW_TAG = true,
  ARENA_TRAP = true,
}

-- Battle-use volatile flags the item policy inspects.
local BATTLE_CURE_FLAGS = { "confusion", "infatuation" }

---@class TrainerAiMove
---@field key string executing move identity, empty for vacant slots
---@field id integer numeric move identity, zero for vacant slots
---@field moveType string semantic move type
---@field power integer compiled move power, zero for status moves
---@field category string physical, special, or status
---@field accuracy integer compiled hit chance
---@field effect integer compiled move effect identity gating routine draws
---@field pp integer? remaining power points, absent when unscouted
---@field basePp integer? compiled maximum power points, absent when unscouted
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

---@class TrainerAiCommandVm
---@field bit integer enabled native flag bit under execution
---@field scores table<integer, integer> native score points under adjustment
---@field thresholds table<integer, integer> stored 100-(draw%16) thresholds in slot order
---@field slots TrainerAiMove[] four native move slots in source order
---@field user TrainerAiStats acting stats and types under scoring
---@field foe TrainerAiStats opposing stats and types under scoring
---@field foeHp integer opposing health bounding the knockout check
---@field bestPower integer strongest usable damaging power bounding the faint check
---@field chart table<string, unknown> session chart resolving directed pairs
---@field stream table<string, unknown> caller-owned battle stream, never drawn by commands

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

---@param value unknown candidate battle stat under evaluation
---@param name string stat being read
---@return integer validated battle stat
local function checkStat(value, name)
  if type(value) ~= "number" or value % 1 ~= 0 or value < 1 then
    error(BattleErrors.missingBehavior("trainer evaluation reads its battle stats", { stat = name }))
  end
  return value
end

---@param types unknown candidate semantic types under evaluation
---@return string[] validated semantic types in declared order
local function checkTypes(types)
  if type(types) ~= "table" or #types == 0 then
    error(BattleErrors.missingBehavior("trainer evaluation reads its semantic types", {}))
  end
  local out = {}
  for _, key in
    ipairs(types --[[@as string[] ]])
  do
    if type(key) ~= "string" or key == "" then
      error(BattleErrors.missingBehavior("trainer evaluation reads its semantic types", {}))
    end
    out[#out + 1] = key
  end
  return out
end

---@param stats unknown candidate battle stats under evaluation
---@return TrainerAiStats validated battle stats and types
local function checkFighterStats(stats)
  assert(type(stats) == "table", "evaluation reads explicit battle stats")
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

---@param move unknown candidate move under evaluation
---@return TrainerAiMove validated move facts for scoring
local function checkScoringMove(move)
  assert(type(move) == "table", "evaluation reads explicit move facts")
  local record = move --[[@as table<string, unknown>]]
  if type(record.key) ~= "string" then
    error(BattleErrors.missingBehavior("trainer evaluation reads its move identity", {}))
  end
  if type(record.moveType) ~= "string" or record.moveType == "" then
    error(BattleErrors.missingBehavior("trainer evaluation reads its move type", { key = record.key }))
  end
  if type(record.power) ~= "number" or record.power % 1 ~= 0 or record.power < 0 then
    error(BattleErrors.missingBehavior("trainer evaluation reads its compiled move power", { key = record.key }))
  end
  if type(record.category) ~= "string" or record.category == "" then
    error(BattleErrors.missingBehavior("trainer evaluation reads its move category", { key = record.key }))
  end
  if type(record.accuracy) ~= "number" or record.accuracy % 1 ~= 0 or record.accuracy < 0 then
    error(BattleErrors.missingBehavior("trainer evaluation reads its compiled accuracy", { key = record.key }))
  end
  if type(record.effect) ~= "number" or record.effect % 1 ~= 0 or record.effect < 0 then
    error(BattleErrors.missingBehavior("trainer evaluation reads its compiled move effect", { key = record.key }))
  end
  local id = record.id
  if id == nil then
    id = 0
  end
  if type(id) ~= "number" or id % 1 ~= 0 or id < 0 then
    error(BattleErrors.missingBehavior("trainer evaluation reads its numeric move identity", { key = record.key }))
  end
  if record.key ~= "" and id == 0 then
    error(BattleErrors.missingBehavior("trainer evaluation reads its numeric move identity", { key = record.key }))
  end
  if record.key == "" and id ~= 0 then
    error(BattleErrors.missingBehavior("trainer evaluation reads its numeric move identity", { key = record.key }))
  end
  local pp = record.pp
  if pp ~= nil and (type(pp) ~= "number" or pp % 1 ~= 0 or pp < 0) then
    error(BattleErrors.missingBehavior("trainer evaluation reads its remaining power points", { key = record.key }))
  end
  local basePp = record.basePp
  if basePp ~= nil and (type(basePp) ~= "number" or basePp % 1 ~= 0 or basePp < 0) then
    error(BattleErrors.missingBehavior("trainer evaluation reads its maximum power points", { key = record.key }))
  end
  return {
    key = record.key --[[@as string]],
    id = id --[[@as integer]],
    moveType = record.moveType --[[@as string]],
    power = record.power --[[@as integer]],
    category = record.category --[[@as string]],
    accuracy = record.accuracy --[[@as integer]],
    effect = record.effect --[[@as integer]],
    pp = pp --[[@as integer?]],
    basePp = basePp --[[@as integer?]],
    usable = record.usable == true,
  }
end

---@class TrainerAiScoredSlot
---@field slot integer zero-based native move slot
---@field key string executing move identity, empty for vacant slots
---@field score integer native score points after flag evaluation

--- Builds the source-visible battle facts for program execution from
--- scored slots, staged fighter stats, and explicit evaluation context.
--- The context carries every fact the programs can read (battler
--- health, abilities, items, statuses, stages, parties, history, field);
--- absent facts fail closed when a reached command requires them.
---@param chart table<string, unknown> session chart resolving directed pairs
---@param slots TrainerAiMove[] four native move slots in source order
---@param user TrainerAiStats acting stats and types under scoring
---@param foe TrainerAiStats opposing stats and types under scoring
---@param foeHp integer opposing health bounding the knockout check
---@param firstTurn boolean true while the opening turn gates routine draws
---@param extra table<string, unknown>? explicit evaluation context under test control
---@return table<string, unknown> source-visible battle facts for the executor
function buildEvaluationFacts(chart, slots, user, foe, foeHp, firstTurn, extra)
  local context = extra or {}
  local typeIds = {}
  for key, id in pairs(TrainerAiProgram.TYPE_IDS) do
    typeIds[key] = id
  end
  local function typeId(key, what)
    local id = typeIds[key]
    if id == nil then
      error(BattleErrors.missingBehavior("trainer evaluation reads its semantic types", { fact = what }))
    end
    return id
  end
  local function abilityId(key)
    if key == nil or key == "NONE" or key == "" then
      return 0
    end
    local ids = TrainerAiProgram.ABILITY_IDS --[[@as table<string, integer>]]
    local id = ids[key]
    if id == nil then
      error(BattleErrors.missingBehavior("trainer evaluation reads its ability identity", {}))
    end
    return id
  end
  local moveById = {}
  local moveIdByKey = {}
  for _, slot in ipairs(slots) do
    local checked = checkScoringMove(slot)
    if checked.id ~= 0 then
      moveById[checked.id] = {
        effect = checked.effect,
        power = checked.power,
        moveType = checked.moveType,
        category = checked.category,
        accuracy = checked.accuracy,
        basePp = checked.basePp,
      }
      moveIdByKey[checked.key] = checked.id
    end
  end
  if type(context.moveById) == "table" then
    for id, detail in
      pairs(context.moveById --[[@as table<integer, table<string, unknown>>]])
    do
      if moveById[id] == nil then
        moveById[id] = detail
      end
    end
  end
  if type(context.fullMoveById) == "table" then
    for id, detail in
      pairs(context.fullMoveById --[[@as table<integer, table<string, unknown>>]])
    do
      moveById[id] = detail
    end
  end
  if type(context.fullMoveIdByKey) == "table" then
    for key, id in
      pairs(context.fullMoveIdByKey --[[@as table<string, integer>]])
    do
      moveIdByKey[key] = id
    end
  end
  local function battlerStats(stats, hp, maxHp, extraBattler)
    extraBattler = extraBattler or {}
    local stages = extraBattler.stages or { 6, 6, 6, 6, 6, 6, 6, 6 }
    local neutral = true
    for _, stage in ipairs(stages) do
      if stage ~= 6 then
        neutral = false
        break
      end
    end
    local base = extraBattler.base
    if base == nil then
      if not neutral then
        error(BattleErrors.missingBehavior("trainer evaluation reads its unstaged battle stats", {}))
      end
      base = {
        attack = stats.attack,
        defense = stats.defense,
        specialAttack = stats.specialAttack,
        specialDefense = stats.specialDefense,
      }
    end
    return {
      hp = hp,
      maxHp = maxHp,
      level = stats.level,
      t1 = typeId(stats.types[1], "attacker"),
      t2 = typeId(stats.types[#stats.types], "attacker"),
      ability = abilityId(extraBattler.ability),
      item = extraBattler.item or 0,
      status = extraBattler.status or 0,
      status2 = extraBattler.status2 or 0,
      moveFlags = extraBattler.moveFlags or 0,
      atk = base.attack,
      def = base.defense,
      spa = base.specialAttack,
      spd = base.specialDefense,
      spe = base.speed or 0,
      stages = stages,
      moves = extraBattler.moves or { 0, 0, 0, 0 },
      pp = extraBattler.pp or {},
      gender = extraBattler.gender,
      weightHg = extraBattler.weightHg,
      friendship = extraBattler.friendship,
      ivs = extraBattler.ivs,
      lastMove = extraBattler.lastMove or 0,
      entryMoves = extraBattler.entryMoves,
      entryAbility = extraBattler.entryAbility,
      suppressed = extraBattler.suppressed or false,
      magnetRise = extraBattler.magnetRise or false,
      roosted = extraBattler.roosted or false,
      miracleEye = extraBattler.miracleEye or false,
      foresight = extraBattler.foresight or false,
      flingPower = extraBattler.flingPower,
      w88b1 = extraBattler.w88b1 or 0,
      w88neg = extraBattler.w88neg or false,
    }
  end
  local atkMoves = {}
  local atkPp = {}
  for index, slot in ipairs(slots) do
    local checked = checkScoringMove(slot)
    atkMoves[index] = checked.id
    if checked.pp ~= nil then
      atkPp[index] = checked.pp
    end
  end
  local userBattler = battlerStats(user, context.atkHp or 1, context.atkMaxHp or 1, context.attacker)
  userBattler.moves = atkMoves
  userBattler.pp = atkPp
  local foeBattler = battlerStats(foe, foeHp, context.foeMaxHp or foeHp, context.defender)
  foeBattler.moves = context.foeMoves or { 0, 0, 0, 0 }
  foeBattler.pp = context.foePp or {}
  if type(context.liveAttacker) == "table" then
    userBattler = context.liveAttacker --[[@as table<string, unknown>]]
    userBattler.moves = atkMoves
    if context.liveAttackerPp ~= nil then
      userBattler.pp = context.liveAttackerPp --[[@as table<integer, integer>]]
    else
      userBattler.pp = atkPp
    end
  end
  if type(context.liveTarget) == "table" then
    foeBattler = context.liveTarget --[[@as table<string, unknown>]]
  end
  local round = 1
  if firstTurn ~= true then
    round = 2
  end
  if type(context.round) == "number" then
    round = context.round --[[@as integer]]
  end
  local reverseTypes = {}
  for key, id in pairs(typeIds) do
    reverseTypes[id] = key
  end
  local function pairEffectiveness(moveType, defense)
    local attackKey = reverseTypes[moveType]
    local defendKey = reverseTypes[defense]
    if attackKey == nil or defendKey == nil then
      error(BattleErrors.missingBehavior("trainer evaluation reads its semantic types", {}))
    end
    local resolved = TypeEffectiveness.resolve(chart, attackKey, { defendKey }, {})
    return resolved.numerator, resolved.denominator
  end
  -- Doubles evaluations address all four battler slots with per-candidate
  -- attacker/target identities; every other shape keeps the singles pair.
  local atk = 1
  local tgt = 0
  local battlers = { [0] = foeBattler, [1] = userBattler }
  if type(context.doublesBattlers) == "table" then
    local configured = context.doublesBattlers --[[@as table<string, unknown>]]
    assert(type(configured.atk) == "number", "doubles evaluations name their attacker")
    assert(type(configured.tgt) == "number", "doubles evaluations name their target")
    assert(type(configured.records) == "table", "doubles evaluations carry every battler")
    atk = configured.atk --[[@as integer]]
    tgt = configured.tgt --[[@as integer]]
    battlers = configured.records --[[@as table<integer, table<string, unknown>>]]
  end
  return {
    atk = atk,
    tgt = tgt,
    battlers = battlers,
    moveById = moveById,
    moveIdByKey = moveIdByKey,
    chart = chart,
    pairEffectiveness = pairEffectiveness,
    round = round,
    battleType = context.battleType or 1,
    weatherClass = context.weatherClass or 0,
    airLock = context.airLock or false,
    trickRoom = context.trickRoom or false,
    gravity = context.gravity or false,
    mudSport = context.mudSport or false,
    waterSport = context.waterSport or false,
    reflect = context.reflect or false,
    lightScreen = context.lightScreen or false,
    flowerGiftAtk = context.flowerGiftAtk or false,
    flowerGiftDef = context.flowerGiftDef or false,
    chargeHit = context.chargeHit or false,
    fieldWord = context.fieldWord or 0,
    sideWords = context.sideWords or { [0] = 0, [1] = 0 },
    lastMove = context.lastMove or { [0] = 0, [1] = 0 },
    usedIds = context.usedIds or {},
    parties = context.parties or {},
    partyIndex = context.partyIndex or {},
    partyPartner = context.partyPartner or {},
    liveBattlers = context.liveBattlers or { [0] = true, [1] = true },
    switchIn = context.switchIn or {},
    battlerCount = context.battlerCount or 2,
    lockedMoves = context.lockedMoves or { encore = 0, disable = 0 },
    encoreSlot = context.encoreSlot or {},
    protectMove = context.protectMove or {},
    heldEffects = context.heldEffects or {},
    heldMods = context.heldMods or {},
    naturalGifts = context.naturalGifts or {},
    recycle = context.recycle or {},
  }
end

--- Scores the four native move slots exactly as the source
--- initialization does: usable slots open at the native baseline,
--- unavailable slots stay excluded at zero, and the four initialization
--- draws occur in source slot order with their stored 100-(draw%16)
--- thresholds before enabled flag evaluation. Enabled flags dispatch in
--- ascending bit order with each program evaluating every usable slot;
--- score commands draw nothing, routine draws happen per reached slot,
--- and selection draws separately below.
---@param chart table<string, unknown> session chart resolving directed pairs
---@param slots TrainerAiMove[] four native move slots in source order
---@param user TrainerAiStats acting stats and types under scoring
---@param foe TrainerAiStats opposing stats and types under scoring
---@param foeHp integer opposing health bounding the knockout check
---@param bits integer[] enabled native flag bits in ascending order
---@param firstTurn boolean true while the opening turn gates routine draws
---@param stream table<string, unknown> caller-owned battle stream for decision draws
---@param extra table<string, unknown>? explicit evaluation context under test control
---@return TrainerAiScoredSlot[] scored slots in source slot order
function TrainerAi.scoreSlots(chart, slots, user, foe, foeHp, bits, firstTurn, stream, extra)
  assert(type(chart) == "table", "scoring resolves effectiveness through the session chart")
  assert(type(slots) == "table" and #slots == 4, "scoring covers the four native move slots")
  assert(type(stream) == "table" and type(stream.nextU16) == "function", "scoring draws from the battle stream")
  assert(type(bits) == "table", "scoring dispatches the enabled flag bits")
  assert(type(firstTurn) == "boolean", "scoring names its opening turn for routine draws")
  assert(type(foeHp) == "number" and foeHp % 1 == 0 and foeHp >= 0, "scoring bounds its knockout check")
  for _, slot in ipairs(slots) do
    checkScoringMove(slot)
  end
  checkFighterStats(user)
  checkFighterStats(foe)
  local ordered = {}
  for _, bit in ipairs(bits) do
    assert(type(bit) == "number" and bit % 1 == 0, "enabled flag bits stay numeric")
    ordered[#ordered + 1] = bit
  end
  table.sort(ordered)
  for _, bit in ipairs(ordered) do
    if TrainerAiProgram.ENTRY[bit] == nil then
      error(BattleErrors.missingBehavior("trainer scoring names a transcribed native flag", { flag = bit }))
    end
  end
  local thresholds = initThresholds(stream)
  local facts = buildEvaluationFacts(chart, slots, user, foe, foeHp, firstTurn, extra)
  return executePrograms(facts, slots, ordered, thresholds, stream)
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

---@class TrainerAiTargetBid
---@field target integer live opposing position under evaluation
---@field slot integer zero-based native move slot answering that target
---@field score integer native score points behind the bid

--- Selects the doubles target and move from per-target bids after the
--- source doubles selector (ov10_0221C038): the highest bid wins and
--- equal-top bids break uniformly through exactly one selection draw.
---@param bids TrainerAiTargetBid[] evaluated target bids in position order
---@param stream table<string, unknown> caller-owned battle stream for the selection draw
---@return integer live opposing position answering the strike
---@return integer zero-based native move slot answering the strike
function TrainerAi.selectDoubles(bids, stream)
  assert(type(bids) == "table" and #bids > 0, "doubles selection reads its target bids")
  assert(
    type(stream) == "table" and type(stream.nextU16) == "function",
    "doubles selection draws from the battle stream"
  )
  local top = bids[1].score
  for index = 2, #bids do
    assert(type(bids[index].target) == "number", "target bids name their position")
    assert(type(bids[index].slot) == "number", "target bids name their move slot")
    assert(type(bids[index].score) == "number", "target bids carry their native points")
    if bids[index].score > top then
      top = bids[index].score
    end
  end
  local tied = {}
  for _, bid in ipairs(bids) do
    if bid.score == top then
      tied[#tied + 1] = bid
    end
  end
  assert(#tied > 0, "a top bid always names at least one target")
  local draw = stream:nextU16("doubles_selection", { tied = #tied })
  local winner = tied[(draw % #tied) + 1]
  return winner.target, winner.slot
end

--- Selects the opposing battler in source target order: with more than
--- one live opposing entry one draw chooses uniformly among them in
--- position order, while a lone foe is addressed with no draw.
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

---@param slots unknown candidate ordered item slots under validation
local function checkMemorySlots(slots)
  if type(slots) ~= "table" then
    error(BattleErrors.incompatibleSnapshot("trainer memory carries its ordered item slots", {}))
  end
  local count = 0
  for index, item in
    ipairs(slots --[[@as table<integer, unknown>]])
  do
    count = count + 1
    assert(index == count, "trainer item slots stay ordered")
    if type(item) ~= "string" or item == "" then
      error(BattleErrors.incompatibleSnapshot("trainer item slots name their item", { slot = index }))
    end
  end
  -- Slot positions drive selection, so memory always carries all four:
  -- compact survivor lists from older snapshots are incompatible.
  if count ~= 4 then
    error(BattleErrors.incompatibleSnapshot("trainer memory carries four ordered item slots", { slots = count }))
  end
end

---@param known unknown candidate learned-move record under validation
local function checkKnownMoves(known)
  if type(known) ~= "table" then
    error(BattleErrors.incompatibleSnapshot("trainer memory carries its learned moves", {}))
  end
  for foeId, moves in
    pairs(known --[[@as table<integer, unknown>]])
  do
    if type(foeId) ~= "number" or foeId % 1 ~= 0 or foeId < 1 then
      error(BattleErrors.incompatibleSnapshot("learned moves name their foe", {}))
    end
    if type(moves) ~= "table" then
      error(BattleErrors.incompatibleSnapshot("learned moves carry their move set", { foe = foeId }))
    end
    for key, seen in
      pairs(moves --[[@as table<string, unknown>]])
    do
      if type(key) ~= "string" or key == "" or seen ~= true then
        error(BattleErrors.incompatibleSnapshot("learned moves name their move", { foe = foeId }))
      end
    end
  end
end

--- Validates a restored native trainer record. Snapshots missing the
--- record or carrying a foreign shape are incompatible: these are
--- transient pre-release snapshots with no migration path.
---@param memory unknown restored native trainer record under validation
---@return boolean true for a well-formed current record
function TrainerAi.validateMemory(memory)
  if type(memory) ~= "table" then
    error(BattleErrors.incompatibleSnapshot("native snapshots carry their trainer record", {}))
  end
  local record = memory --[[@as table<string, unknown>]]
  if record.version ~= TrainerAi.MEMORY_VERSION then
    error(BattleErrors.incompatibleSnapshot("trainer records carry their current schema mark", {
      version = tostring(record.version),
    }))
  end
  if type(record.controllers) ~= "table" then
    error(BattleErrors.incompatibleSnapshot("trainer records carry their controller memory", {}))
  end
  for controller, entry in
    pairs(record.controllers --[[@as table<string, unknown>]])
  do
    if type(controller) ~= "string" or controller == "" or type(entry) ~= "table" then
      error(BattleErrors.incompatibleSnapshot("trainer memory names its controller", {}))
    end
    local owned = entry --[[@as table<string, unknown>]]
    checkMemorySlots(owned.slots)
    checkKnownMoves(owned.knownMoves)
    for key, value in pairs(owned) do
      if key ~= "slots" and key ~= "knownMoves" then
        error(BattleErrors.incompatibleSnapshot("trainer memory carries only its slots and knowledge", {
          field = tostring(key),
        }))
      end
      assert(value ~= nil, "trainer memory fields stay present")
    end
  end
  return true
end

---@return string[] fresh gap positions for a trainer without servings
local function emptySlots()
  return { "NONE", "NONE", "NONE", "NONE" }
end

---@param participant table<string, unknown> acting participant owning the roster and stock
---@param state table<string, unknown> live battle state under inspection
---@return string[] ordered trainer item identities for the controller
local function orderedItemSlots(participant, state)
  local context = participant.context
  if type(context) == "table" and type(context.trainerItems) == "table" then
    local ordered = context.trainerItems --[[@as table<integer, unknown>]]
    if #ordered ~= 4 then
      error(BattleErrors.missingBehavior("trainer item order arrives as four source-ordered slots", {
        controller = tostring(participant.controller),
      }))
    end
    local slots = {}
    for index = 1, 4 do
      local item = ordered[index]
      if type(item) ~= "string" or item == "" then
        error(BattleErrors.missingBehavior("trainer item slots name their item", { slot = index }))
      end
      slots[index] = item --[[@as string]]
    end
    return slots
  end
  -- Without source-ordered slots the scan order is unrecoverable:
  -- quantity maps carry no order, so a stocked trainer without
  -- metadata fails closed instead of answering alphabetical stock.
  -- Trainers with no live stock carry four gaps and stay quiet.
  local inventoryId = participant.inventoryId
  if type(inventoryId) ~= "string" then
    return emptySlots()
  end
  local inventories = state.inventories
  if type(inventories) ~= "table" then
    return emptySlots()
  end
  local stock = inventories[inventoryId]
  if type(stock) ~= "table" or type(stock.quantities) ~= "table" then
    return emptySlots()
  end
  for key, units in
    pairs(stock.quantities --[[@as table<string, unknown>]])
  do
    if type(key) == "string" and key ~= "" and type(units) == "number" and units % 1 == 0 and units > 0 then
      error(BattleErrors.missingBehavior("trainer item order arrives as source-ordered slots", {
        controller = tostring(participant.controller),
      }))
    end
  end
  return emptySlots()
end

--- Creates the fresh native trainer record once per native session after
--- generic state construction. Slot order comes from the trainer item
--- context; learned opponent knowledge starts empty and is only ever
--- filled through battle observation, never seeded from records.
---@param state table<string, unknown> live battle state under initialization
---@return table<string, unknown> the initialized native trainer record
function TrainerAi.initializeMemory(state)
  assert(type(state) == "table", "trainer memory initializes from live battle state")
  assert(type(state.participantOrder) == "table", "trainer memory reads its participants")
  local memory = { version = TrainerAi.MEMORY_VERSION, controllers = {} }
  local owned = memory.controllers --[[@as table<string, table<string, unknown>>]]
  for _, participantId in
    ipairs(state.participantOrder --[[@as integer[] ]])
  do
    local participant = BattleState.participant(state, participantId --[[@as integer]])
    local controller = participant.controller
    if type(controller) == "string" and controller:sub(1, 8) == "trainer:" and owned[controller] == nil then
      owned[controller] = { slots = orderedItemSlots(participant, state), knownMoves = {} }
    end
  end
  state.trainerAi = memory
  return memory
end

---@param state table<string, unknown> live battle state under inspection
---@return table<string, table<string, unknown>>? native trainer memory, when present
local function liveMemory(state)
  local memory = state.trainerAi
  if type(memory) ~= "table" then
    return nil
  end
  return memory --[[@as table<string, table<string, unknown>>]]
end

---@param state table<string, unknown> live battle state under inspection
---@param controller string acting trainer controller under memory lookup
---@return table<string, unknown>? controller memory, when the session tracks it
local function controllerMemory(state, controller)
  local memory = liveMemory(state)
  if memory == nil then
    return nil
  end
  local controllers = memory.controllers
  if type(controllers) ~= "table" then
    return nil
  end
  local entry = (controllers --[[@as table<string, unknown>]])[controller]
  if type(entry) ~= "table" then
    return nil
  end
  return entry --[[@as table<string, unknown>]]
end

--- Records an executed strike in every opposing trainer memory. Learned
--- knowledge only ever grows through observation; a fresh entry clears
--- it again at the battler reset boundary.
---@param state table<string, unknown> live battle state under observation
---@param userId integer striking combatant under observation
---@param moveKey string executed move identity under observation
function TrainerAi.observeMove(state, userId, moveKey)
  assert(type(state) == "table", "move observation reads live battle state")
  if type(userId) ~= "number" or userId % 1 ~= 0 or userId < 1 then
    return
  end
  if type(moveKey) ~= "string" or moveKey == "" then
    return
  end
  local memory = liveMemory(state)
  if memory == nil then
    return
  end
  local user = BattleState.combatant(state, userId)
  local userSide = BattleState.participant(state, user.participant --[[@as integer]]).side
  for _, participantId in
    ipairs(state.participantOrder --[[@as integer[] ]])
  do
    local participant = BattleState.participant(state, participantId)
    if participant.side ~= userSide and type(participant.controller) == "string" then
      local entry = controllerMemory(state, participant.controller --[[@as string]])
      if entry ~= nil then
        local known = entry.knownMoves
        if type(known) == "table" then
          local byFoe = known --[[@as table<integer, unknown>]]
          local moves = byFoe[userId]
          if type(moves) ~= "table" then
            moves = {}
            byFoe[userId] = moves
          end
          local moveSet = moves --[[@as table<string, boolean>]]
          moveSet[moveKey] = true
        end
      end
    end
  end
end

--- Clears learned knowledge about an entering combatant in every trainer
--- memory. A new entry fights unknown again while ordered item slots
--- survive; this runs at the source-equivalent battler reset boundary.
---@param state table<string, unknown> live battle state under entry reset
---@param incomingId integer entering combatant under reset
function TrainerAi.noteArrival(state, incomingId)
  assert(type(state) == "table", "entry reset reads live battle state")
  if type(incomingId) ~= "number" or incomingId % 1 ~= 0 or incomingId < 1 then
    return
  end
  local memory = liveMemory(state)
  if memory == nil then
    return
  end
  local controllers = memory.controllers
  if type(controllers) ~= "table" then
    return
  end
  for _, entry in
    pairs(controllers --[[@as table<string, unknown>]])
  do
    if type(entry) == "table" then
      local known = (entry --[[@as table<string, unknown>]]).knownMoves
      if type(known) == "table" then
        local byFoe = known --[[@as table<integer, unknown>]]
        byFoe[incomingId] = nil
      end
    end
  end
end

---@param speciesFacts table<string, table<integer, table<string, unknown>>> static species facts by species and form
---@param mon table<string, unknown> battle mon record under fact sampling
---@return table<string, unknown> static species facts for the record
local function staticFacts(speciesFacts, mon)
  assert(type(speciesFacts) == "table", "evaluation reads the session species facts")
  local species = mon.species
  local form = mon.form
  if type(species) ~= "string" or species == "" or type(form) ~= "number" or form % 1 ~= 0 then
    error(BattleErrors.missingBehavior("trainer evaluation reads its combat facts", { fact = "species" }))
  end
  local byForm = speciesFacts[species]
  local static = type(byForm) == "table" and byForm[form]
  if type(static) ~= "table" then
    error(BattleErrors.missingBehavior("trainer evaluation reads its static species facts", { fact = species }))
  end
  return static --[[@as table<string, unknown>]]
end

---@param mon table<string, unknown> battle mon record under evaluation
---@param stages unknown battle-local stat stages for the entry
---@param speciesFacts table<string, table<integer, table<string, unknown>>> static species facts by species and form
---@return TrainerAiStats level and stage-effective battle stats for evaluation
local function estimateFighter(mon, stages, speciesFacts)
  if type(mon) ~= "table" then
    error(BattleErrors.missingBehavior("trainer evaluation reads its combat facts", { fact = "mon" }))
  end
  local record = mon --[[@as table<string, unknown>]]
  local static = staticFacts(speciesFacts, record)
  if type(static.baseStats) ~= "table" or type(static.growthCurve) ~= "table" or type(static.types) ~= "table" then
    error(BattleErrors.missingBehavior("trainer evaluation reads its static species facts", {
      fact = record.species,
    }))
  end
  local experience = record.experience
  local personality = record.personality
  if type(experience) ~= "number" or experience % 1 ~= 0 or experience < 0 then
    error(BattleErrors.missingBehavior("trainer evaluation reads its combat facts", { fact = "experience" }))
  end
  if type(personality) ~= "number" or personality % 1 ~= 0 or personality < 0 then
    error(BattleErrors.missingBehavior("trainer evaluation reads its combat facts", { fact = "personality" }))
  end
  if type(record.ivs) ~= "table" or type(record.evs) ~= "table" then
    error(BattleErrors.missingBehavior("trainer evaluation reads its combat facts", { fact = "effort" }))
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
    error(BattleErrors.missingBehavior("trainer evaluation reads its battle-local stages", {}))
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
      error(BattleErrors.missingBehavior("trainer evaluation reads its semantic type facts", { fact = "types" }))
    end
    combat.types[#combat.types + 1] = key
  end
  for _, key in ipairs({ "attack", "defense", "specialAttack", "specialDefense" }) do
    local stage = staged[key] or 0
    if type(stage) ~= "number" or stage % 1 ~= 0 or stage < StatStages.MIN or stage > StatStages.MAX then
      error(BattleErrors.missingBehavior("trainer evaluation reads its battle-local stages", {}))
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
    error(BattleErrors.missingBehavior("trainer evaluation reads its move identity", {}))
  end
  local record = moveFacts[key]
  if type(record) ~= "table" then
    error(BattleErrors.missingBehavior("trainer evaluation reads its compiled move facts", { key = key }))
  end
  return record
end

---@param mon table<string, unknown> battle mon record under slot resolution
---@param moveFacts table<string, table<string, unknown>> immutable move facts carried by the session
---@return TrainerAiMove[] four native move slots in source order
local function resolveSlots(mon, moveFacts)
  local entries = mon.moves
  if type(entries) ~= "table" then
    error(BattleErrors.missingBehavior("trainer evaluation reads its move entries", {}))
  end
  local slots = {}
  for index = 1, 4 do
    local entry = entries[index]
    if type(entry) ~= "table" then
      slots[index] = {
        key = "",
        id = 0,
        moveType = "typeless",
        power = 0,
        category = "status",
        accuracy = 0,
        effect = 0,
        pp = 0,
        usable = false,
      }
    else
      local record = entry --[[@as table<string, unknown>]]
      local facts = factsFor(moveFacts, record.move)
      local nativeId = facts.nativeId
      if type(nativeId) ~= "number" or nativeId % 1 ~= 0 or nativeId <= 0 then
        error(BattleErrors.missingBehavior("trainer evaluation reads its numeric move identity", {
          key = record.move,
        }))
      end
      local power = facts.power
      local moveType = facts.moveType
      local category = facts.category
      local accuracy = facts.accuracy
      local effect = facts.effect
      if type(power) ~= "number" or power % 1 ~= 0 or power < 0 then
        error(BattleErrors.missingBehavior("trainer evaluation reads its compiled move power", { key = record.move }))
      end
      if type(effect) ~= "number" or effect % 1 ~= 0 or effect < 0 then
        error(BattleErrors.missingBehavior("trainer evaluation reads its compiled move effect", { key = record.move }))
      end
      if type(moveType) ~= "string" or moveType == "" then
        error(BattleErrors.missingBehavior("trainer evaluation reads its move type", { key = record.move }))
      end
      if type(category) ~= "string" or category == "" then
        error(BattleErrors.missingBehavior("trainer evaluation reads its move category", { key = record.move }))
      end
      if type(accuracy) ~= "number" or accuracy % 1 ~= 0 or accuracy < 0 then
        error(BattleErrors.missingBehavior("trainer evaluation reads its compiled accuracy", { key = record.move }))
      end
      local pp = record.pp
      slots[index] = {
        key = record.move,
        id = nativeId --[[@as integer]],
        moveType = moveType,
        power = power,
        category = category,
        accuracy = accuracy,
        effect = effect --[[@as integer]],
        pp = record.pp,
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

---@param mon unknown battle-local mon record under ability inspection
---@return string? battle ability key, when one is named
local function battleAbility(mon)
  if type(mon) ~= "table" then
    return nil
  end
  local ability = (mon --[[@as table<string, unknown>]]).ability
  if type(ability) ~= "string" or ability == "" or ability == "NONE" then
    return nil
  end
  return ability
end

---@param state table<string, unknown> live battle state under inspection
---@param holderId integer acting combatant under the trap check
---@param holderTypes string[] acting semantic types in declared order
---@param opponents table<integer, table<string, unknown>> live opposing entries in position order
---@return boolean true while effects or opposing abilities hold the exchange
local function switchHeld(state, holderId, holderTypes, opponents)
  if isTrapped(state, holderId) then
    return true
  end
  if BattleContext.wrap(state):hasBattleEffect(holderId, "ingrain") then
    return true
  end
  local steel = false
  for _, key in ipairs(holderTypes) do
    if key == "steel" then
      steel = true
    end
  end
  for _, opposed in ipairs(opponents) do
    local foe = BattleState.combatant(state, opposed.combatant)
    local ability = battleAbility(foe.mon)
    if ability == nil then
      error(BattleErrors.missingBehavior("trainer switch reads its opposing ability", {
        combatant = opposed.combatant,
      }))
    end
    if TRAPPING_ABILITIES[ability] == true then
      return true
    end
    if ability == "MAGNET_PULL" and steel then
      return true
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

---@class TrainerAiReserveFacts
---@field id integer benched combatant identity
---@field stats TrainerAiStats battle stats and types under evaluation
---@field slots TrainerAiMove[] reserve moves in slot order

---@class TrainerAiFoeFacts
---@field id integer opposing combatant identity
---@field position integer opposing position identity
---@field stats TrainerAiStats battle stats and types under evaluation
---@field hp integer opposing health bounding the knockout check

---@param slots TrainerAiMove[] candidate moves in slot order
---@return boolean true with at least one usable slot
local function hasUsable(slots)
  for _, move in ipairs(slots) do
    if move.usable then
      return true
    end
  end
  return false
end

-- Answers the native switch gate (ov10_022203A4) in source order: the
-- perish-song countdown exchanges through post-KO order, then the
-- wonder-guard, ineffective-moves, absorb-ability, and relief helpers
-- exchange on their own branches until the selective-move and stat
-- holds keep the field and the immunity tails close the chain. Branch
-- draws fire only where the source draws, later helpers never run
-- after an exchange, and only a history table predating the session
-- record fails closed at its read instead of guessing stay or switch.
---@param chart table<string, unknown> session chart resolving directed pairs
---@param moveType string attacking type under evaluation
---@param defenderTypes string[] defending types in declared order
---@return boolean true while the matchup is at least doubly effective
local function selectiveAgainst(chart, moveType, defenderTypes)
  local numerator, denominator = combineMultiplier(chart, moveType, defenderTypes)
  return numerator >= 2 * denominator
end

---@param chart table<string, unknown> session chart resolving directed pairs
---@param moveType string attacking type under evaluation
---@param defenderTypes string[] defending types in declared order
---@return boolean true while the matchup is fully immune
local function immuneAgainst(chart, moveType, defenderTypes)
  local numerator, _ = combineMultiplier(chart, moveType, defenderTypes)
  return numerator == 0
end

---@param chart table<string, unknown> session chart resolving directed pairs
---@param moveType string attacking type under evaluation
---@param defenderTypes string[] defending types in declared order
---@return boolean true while the matchup is exactly neutral
local function neutralAgainst(chart, moveType, defenderTypes)
  local numerator, denominator = combineMultiplier(chart, moveType, defenderTypes)
  return numerator == denominator
end

--- Reads whether the perish-song countdown ends the holder this turn.
--- An absent song holds the field; a present song needs its remaining
--- count, which fails closed when the record carries none.
---@param state table<string, unknown> live battle state under inspection
---@param holderId integer acting combatant under the perish check
---@return boolean true while the song ends the holder this turn
local function perishEndsNow(state, holderId)
  local bag = state.effectBag
  if type(bag) ~= "table" or type(bag.capture) ~= "function" then
    error(BattleErrors.missingBehavior("trainer switch reads its perish-song countdown", {
      combatant = holderId,
    }))
  end
  local capture = bag.capture --[[@as fun(self: table<string, unknown>): table<integer, table<string, unknown>>]]
  for _, record in ipairs(capture(bag)) do
    if record.key == "perishsong" then
      local scope = record.scope
      if type(scope) == "table" and scope.combatant == holderId then
        local countdown = record.state
        local turns = type(countdown) == "table" and (countdown --[[@as table<string, unknown>]]).turns or nil
        if type(turns) ~= "number" or turns % 1 ~= 0 then
          error(BattleErrors.missingBehavior("trainer switch reads its perish-song countdown", {
            combatant = holderId,
          }))
        end
        if turns == 0 then
          return true
        end
      end
    end
  end
  return false
end

---@class TrainerAiReceivedHit
---@field move string striking move identity
---@field user integer striking combatant identity

---@class TrainerAiResolvedHit
---@field move string striking move identity
---@field user integer striking combatant identity
---@field moveType string striking move type under the tail probes
---@field power integer striking move power bounding the powerless-coin path
---@field userTypes string[] striking combatant types in declared order

-- Absorb replies keyed by the striking type: only damaging fire, water,
-- and electric strikes open the bench scan, answered by the matching
-- guard ability.
local ABSORB_ABILITY = {
  fire = "FLASH_FIRE",
  water = "WATER_ABSORB",
  electric = "VOLT_ABSORB",
}

--- Reads the last strike received by the holder from the session-owned
--- history. An absent entry means no strike has reached the holder since
--- its arrival or latest action; only a table predating the history
--- fails closed instead of guessing.
---@param state table<string, unknown> live battle state under inspection
---@param holderId integer acting combatant under the history read
---@return TrainerAiReceivedHit? the striking move and its user, nil when never struck
local function receivedHit(state, holderId)
  local ledger = state.lastHits
  if type(ledger) ~= "table" then
    error(BattleErrors.missingBehavior("trainer switch reads its received-hit history", {}))
  end
  local entry = (ledger --[[@as table<integer, unknown>]])[holderId]
  if entry == nil then
    return nil
  end
  if type(entry) ~= "table" then
    error(BattleErrors.missingBehavior("trainer switch reads its received-hit history", {}))
  end
  local record = entry --[[@as table<string, unknown>]]
  if type(record.move) ~= "string" or record.move == "" or type(record.user) ~= "number" then
    error(BattleErrors.missingBehavior("trainer switch reads its received-hit history", {}))
  end
  return {
    move = record.move --[[@as string]],
    user = record.user --[[@as integer]],
  }
end

---@param moveFacts table<string, table<string, unknown>> immutable move facts carried by the session
---@param key string striking move identity under resolution
---@return string striking move type under the tail probes
---@return integer striking move power bounding the powerless-coin path
local function hitMoveFacts(moveFacts, key)
  if key == "STRUGGLE" then
    return "normal", 50
  end
  local record = moveFacts[key]
  if type(record) ~= "table" then
    error(BattleErrors.missingBehavior("trainer evaluation reads its compiled move facts", { key = key }))
  end
  local facts = record --[[@as table<string, unknown>]]
  local moveType = facts.moveType
  local power = facts.power
  if type(moveType) ~= "string" or moveType == "" then
    error(BattleErrors.missingBehavior("trainer evaluation reads its move type", { key = key }))
  end
  if
    type(power) ~= "number"
    or power --[[@as integer]]
      % 1 ~= 0
    or power --[[@as integer]]
      < 0
  then
    error(BattleErrors.missingBehavior("trainer evaluation reads its compiled move power", { key = key }))
  end
  return moveType, --[[@as string]]
    power --[[@as integer]]
end

--- Resolves the holder's received hit into the facts the tails read:
--- the striking type and power plus the striking combatant's live
--- types. A never-struck holder resolves to nil without drawing.
---@param state table<string, unknown> live battle state under inspection
---@param authorities TrainerAiAuthorities session-owned read authorities
---@param holderId integer acting combatant under the history read
---@return TrainerAiResolvedHit? resolved striking facts, nil when never struck
local function resolveReceivedHit(state, authorities, holderId)
  local hit = receivedHit(state, holderId)
  if hit == nil then
    return nil
  end
  local moveType, power = hitMoveFacts(authorities.moveFacts, hit.move --[[@as string]])
  local userCombatant = BattleState.combatant(state, hit.user --[[@as integer]])
  local userTypes = estimateFighter(
    userCombatant.mon --[[@as table<string, unknown>]],
    userCombatant.stages,
    authorities.speciesFacts
  ).types
  return {
    move = hit.move --[[@as string]],
    user = hit.user --[[@as integer]],
    moveType = moveType,
    power = power,
    userTypes = userTypes,
  }
end

-- Answers the absorb-ability tail (ov10_0221FE8C past its head): a guard
-- reply to the striking type exchanges for the first benched guard on
-- an odd branch draw per guard reach. A guard holder, a guardless line,
-- and a miss on every reach all hold the field.
---@param state table<string, unknown> live battle state under inspection
---@param holderAbility string? battle ability carried by the holder
---@param hitMoveType string striking move type under the guard scan
---@param reserves TrainerAiReserveFacts[] living benched reserves in roster order
---@param stream table<string, unknown> caller-owned battle stream for the branch draw
---@return integer? benched combatant answering the threat, nil when the holder stays
local function absorbSwitch(state, holderAbility, hitMoveType, reserves, stream)
  local guard = ABSORB_ABILITY[hitMoveType]
  if guard == nil or holderAbility == guard then
    return nil
  end
  for _, reserve in ipairs(reserves) do
    local ability = battleAbility(BattleState.combatant(state, reserve.id).mon)
    if ability == guard then
      if stream:nextU16("switch_absorb_roll", { reserve = reserve.id }) % 2 == 1 then
        return reserve.id
      end
    end
  end
  return nil
end

-- Answers one immunity/resist tail (ov10_02220010): the last-hit move
-- tests each benched cover for the masked matchup, and each covered
-- reach tests its selective reply against the last-hit user, exchanging
-- on a zero branch-draw remainder. Covers scan in roster order and later
-- reaches never run after an exchange.
---@param chart table<string, unknown> session chart resolving directed pairs
---@param hitMoveType string striking move type under the cover scan
---@param userTypes string[] last-hit user types in declared order
---@param reserves TrainerAiReserveFacts[] living benched reserves in roster order
---@param stream table<string, unknown> caller-owned battle stream for the branch draw
---@param immune boolean true while the tail answers immunity, false for resistance
---@param divisor integer branch-draw divisor closing the exchange
---@return integer? benched combatant answering the threat, nil when the holder stays
local function effectTail(chart, hitMoveType, userTypes, reserves, stream, immune, divisor)
  local label = "switch_immune_roll"
  if not immune then
    label = "switch_resist_roll"
  end
  for _, reserve in ipairs(reserves) do
    local numerator, denominator = combineMultiplier(chart, hitMoveType, reserve.stats.types)
    local covered = numerator == 0
    if not immune then
      covered = numerator > 0 and numerator < denominator
    end
    if covered then
      for _, move in ipairs(reserve.slots) do
        if move.key ~= "" and selectiveAgainst(chart, move.moveType, userTypes) then
          if stream:nextU16(label, { reserve = reserve.id }) % divisor == 0 then
            return reserve.id
          end
        end
      end
    end
  end
  return nil
end

--- Resolves one entry-token history into native move identities in
--- first-use order. An absent entry reads fresh; a present entry must
--- be the ordered sequence the session records, so ledgers predating
--- the order fail closed instead of guessing fresh.
---@param moveIdByKey table<string, integer> native move identities by key
---@param entry unknown distinct-move history under ordered resolution
---@return integer[] native move identities in first-use order
local function orderedUsedIds(moveIdByKey, entry)
  local out = {}
  if entry == nil then
    return out
  end
  if type(entry) ~= "table" then
    error(BattleErrors.missingBehavior("trainer evaluation reads its ordered move history", {}))
  end
  local record = entry --[[@as table<integer, unknown>]]
  local count = 0
  for _, key in ipairs(record) do
    count = count + 1
    if key == "STRUGGLE" then
      out[#out + 1] = 165
    else
      local id = moveIdByKey[key]
      if id == nil then
        error(BattleErrors.missingBehavior("trainer evaluation reads its used move identity", {}))
      end
      out[#out + 1] = id
    end
  end
  for key in pairs(record) do
    if
      type(key) ~= "number"
      or key --[[@as integer]]
        % 1 ~= 0
      or key --[[@as integer]]
        < 1
      or key --[[@as integer]]
        > count
    then
      error(BattleErrors.missingBehavior("trainer evaluation reads its ordered move history", {}))
    end
  end
  return out
end

-- Answers the wonder-guard branch (ov10_0221F62C): outside doubles, a
-- wonder-guard foe no holder strike answers selectively opens the
-- bench scan, and the first selective reserve strike exchanges on a
-- two-in-three branch draw. Scans read move identities, so exhausted
-- slots still count.
---@param chart table<string, unknown> session chart resolving directed pairs
---@param holderSlots TrainerAiMove[] holder moves in slot order
---@param foeTypes string[] opposing battler types in declared order
---@param reserves TrainerAiReserveFacts[] living benched reserves in roster order
---@param stream table<string, unknown> caller-owned battle stream for the branch draw
---@return integer? benched combatant answering the threat, nil when the holder stays
local function wonderGuardSwitch(chart, holderSlots, foeTypes, reserves, stream)
  for _, move in ipairs(holderSlots) do
    if move.key ~= "" and selectiveAgainst(chart, move.moveType, foeTypes) then
      return nil
    end
  end
  for _, reserve in ipairs(reserves) do
    for _, move in ipairs(reserve.slots) do
      if move.key ~= "" and selectiveAgainst(chart, move.moveType, foeTypes) then
        if stream:nextU16("switch_wonder_roll", { reserve = reserve.id }) % 3 < 2 then
          return reserve.id
        end
      end
    end
  end
  return nil
end

-- Answers the ineffective-moves branch (ov10_0221F7F0): at least two
-- damaging holder strikes, every one immune against every scanned foe,
-- open the bench scans. The selective scan exchanges on a
-- two-in-three branch draw per selective reach; the neutral scan
-- exchanges on an even branch draw per neutral reach. Singles scans
-- the lone foe twice, matching the source defender pair.
---@param chart table<string, unknown> session chart resolving directed pairs
---@param holderSlots TrainerAiMove[] holder moves in slot order
---@param foeTypesList string[][] scanned foe types in source defender order
---@param reserves TrainerAiReserveFacts[] living benched reserves in roster order
---@param stream table<string, unknown> caller-owned battle stream for branch draws
---@return integer? benched combatant answering the threat, nil when the holder stays
local function ineffectiveSwitch(chart, holderSlots, foeTypesList, reserves, stream)
  local damaging = 0
  for _, move in ipairs(holderSlots) do
    if move.key ~= "" and move.power > 0 then
      damaging = damaging + 1
      for _, foeTypes in ipairs(foeTypesList) do
        if not immuneAgainst(chart, move.moveType, foeTypes) then
          return nil
        end
      end
    end
  end
  if damaging < 2 then
    return nil
  end
  for _, reserve in ipairs(reserves) do
    for _, move in ipairs(reserve.slots) do
      if move.key ~= "" and move.power > 0 then
        for _, foeTypes in ipairs(foeTypesList) do
          if selectiveAgainst(chart, move.moveType, foeTypes) then
            if stream:nextU16("switch_ineffective_roll", { reserve = reserve.id }) % 3 < 2 then
              return reserve.id
            end
          end
        end
      end
    end
  end
  for _, reserve in ipairs(reserves) do
    for _, move in ipairs(reserve.slots) do
      if move.key ~= "" and move.power > 0 then
        for _, foeTypes in ipairs(foeTypesList) do
          if neutralAgainst(chart, move.moveType, foeTypes) then
            if stream:nextU16("switch_ineffective_roll", { reserve = reserve.id }) % 2 == 0 then
              return reserve.id
            end
          end
        end
      end
    end
  end
  return nil
end

---@param chart table<string, unknown> session chart resolving directed pairs
---@param holderSlots TrainerAiMove[] holder moves in slot order
---@param foeTypesList string[][] scanned foe types in source defender order
---@return boolean true while a holder strike answers a scanned foe selectively
local function hasSelectiveMove(chart, holderSlots, foeTypesList)
  for _, foeTypes in ipairs(foeTypesList) do
    for _, move in ipairs(holderSlots) do
      if move.key ~= "" and selectiveAgainst(chart, move.moveType, foeTypes) then
        return true
      end
    end
  end
  return false
end

-- Answers the selective-move hold (ov10_0221FD34 with a clear stay
-- flag): every selective holder strike holds the field nine times in
-- ten through its own branch draw. Doubles scans the partner after the
-- across slot; singles scans once.
---@param chart table<string, unknown> session chart resolving directed pairs
---@param holderSlots TrainerAiMove[] holder moves in slot order
---@param foeTypesList string[][] scanned foe types in source defender order
---@param stream table<string, unknown> caller-owned battle stream for branch draws
---@return boolean true while the holder keeps the field on coverage
local function selectiveHold(chart, holderSlots, foeTypesList, stream)
  for _, foeTypes in ipairs(foeTypesList) do
    for _, move in ipairs(holderSlots) do
      if move.key ~= "" and selectiveAgainst(chart, move.moveType, foeTypes) then
        if stream:nextU16("switch_stay_roll", {}) % 10 ~= 0 then
          return true
        end
      end
    end
  end
  return false
end

---@param stages table<string, integer> battle-local stages for the entry
---@return boolean true while positive stages sum to four or more
local function heavilyBoosted(stages)
  assert(type(stages) == "table", "the stat hold reads its battle-local stages")
  local boosts = 0
  for _, stat in ipairs({ "attack", "defense", "specialAttack", "specialDefense", "speed", "accuracy", "evasion" }) do
    local stage = (stages --[[@as table<string, unknown>]])[stat] or 0
    if type(stage) ~= "number" or stage % 1 ~= 0 then
      error(BattleErrors.missingBehavior("trainer switch reads its battle-local stages", {}))
    end
    if stage > 0 then
      boosts = boosts + stage
    end
  end
  return boosts >= 4
end

---@class TrainerAiSwitchFacts
---@field holderId integer acting combatant identity
---@field holderSlots TrainerAiMove[] holder moves in slot order
---@field holderHp integer holder health bounding the relief check
---@field holderCeiling integer holder health ceiling bounding the relief check
---@field holderAbility string? holder battle ability, when one is named
---@field holderAsleep boolean true while the holder carries sleep
---@field holderStages table<string, integer> battle-local stages for the entry
---@field doubles boolean true while the live format routes through doubles
---@field reserves TrainerAiReserveFacts[] living benched reserves in roster order
---@field foeTypes string[] primary opposing types in declared order
---@field foeTypesPair string[][] selective-scan defender types in source order
---@field foeTypesDoubled string[][] ineffective-scan defender types in source order
---@field foeWonderGuard boolean true while the primary foe carries wonder guard
---@field foesScanned integer live opposing entries behind the scans
---@field foesHealthy boolean true while every scanned foe still stands

--- Answers the native switch gate from evaluated facts. An empty bench
--- holds the field; every reached branch consumes its own draws in
--- source order and later branches never run after an exchange or a
--- hold.
---@param state table<string, unknown> live battle state under inspection
---@param authorities TrainerAiAuthorities session-owned read authorities
---@param facts TrainerAiSwitchFacts evaluated switch facts for the holder
---@param stream table<string, unknown> caller-owned battle stream for branch draws
---@return integer? benched combatant answering the threat, nil when the holder stays
local function selectReplacement(state, authorities, facts, stream)
  local chart = authorities.chart
  if #facts.reserves == 0 then
    return nil
  end
  if perishEndsNow(state, facts.holderId) then
    return facts.reserves[1].id
  end
  if not facts.doubles and facts.foeWonderGuard then
    local exchange = wonderGuardSwitch(chart, facts.holderSlots, facts.foeTypes, facts.reserves, stream)
    if exchange ~= nil then
      return exchange
    end
  end
  if facts.foesHealthy and (not facts.doubles or facts.foesScanned >= 2) then
    local exchange = ineffectiveSwitch(chart, facts.holderSlots, facts.foeTypesDoubled, facts.reserves, stream)
    if exchange ~= nil then
      return exchange
    end
  end
  local absorbGate = hasSelectiveMove(chart, facts.holderSlots, facts.foeTypesPair)
  if not absorbGate or stream:nextU16("switch_absorb_roll", {}) % 3 == 0 then
    -- Absorb-ability tail (ov10_0221FE8C past its head): a never-struck
    -- holder stays without drawing while a recorded last hit scans the
    -- bench for its guard reply.
    local hit = resolveReceivedHit(state, authorities, facts.holderId)
    if hit ~= nil and hit.power > 0 then
      local exchange = absorbSwitch(state, facts.holderAbility, hit.moveType, facts.reserves, stream)
      if exchange ~= nil then
        return exchange
      end
    end
  end
  if facts.holderAsleep then
    if facts.holderAbility == nil then
      error(BattleErrors.missingBehavior("trainer switch reads its holder ability", {
        combatant = facts.holderId,
      }))
    end
    if facts.holderAbility == "NATURAL_CURE" and facts.holderHp * 2 >= facts.holderCeiling then
      -- Relief branch (ov10_02220270): with never-struck history the
      -- opening and status-move coins decide first, the immunity and
      -- resist tails stay without drawing, and the open coin closes. A
      -- powerless last hit spends only its status-move coin before the
      -- tails; a damaging one probes first and closes on the final coin.
      local hit = resolveReceivedHit(state, authorities, facts.holderId)
      if hit == nil then
        if stream:nextU16("switch_relief_roll", {}) % 2 == 1 then
          return facts.reserves[1].id
        end
        if stream:nextU16("switch_relief_roll", {}) % 2 == 1 then
          return facts.reserves[1].id
        end
        if stream:nextU16("switch_relief_roll", {}) % 2 == 1 then
          return facts.reserves[1].id
        end
      else
        if hit.power == 0 then
          if stream:nextU16("switch_relief_roll", {}) % 2 == 1 then
            return facts.reserves[1].id
          end
        end
        local exchange = effectTail(chart, hit.moveType, hit.userTypes, facts.reserves, stream, true, 1)
        if exchange ~= nil then
          return exchange
        end
        exchange = effectTail(chart, hit.moveType, hit.userTypes, facts.reserves, stream, false, 1)
        if exchange ~= nil then
          return exchange
        end
        if stream:nextU16("switch_relief_roll", {}) % 2 == 1 then
          return facts.reserves[1].id
        end
      end
    end
  end
  if selectiveHold(chart, facts.holderSlots, facts.foeTypesPair, stream) then
    return nil
  end
  if heavilyBoosted(facts.holderStages) then
    return nil
  end
  -- Immunity and resist tails (ov10_02220010 with stay odds 2 and 3):
  -- both key on the last-hit move and its user, staying without drawing
  -- while the holder stands never struck.
  local tail = resolveReceivedHit(state, authorities, facts.holderId)
  if tail ~= nil then
    local exchange = effectTail(chart, tail.moveType, tail.userTypes, facts.reserves, stream, true, 2)
    if exchange ~= nil then
      return exchange
    end
    exchange = effectTail(chart, tail.moveType, tail.userTypes, facts.reserves, stream, false, 3)
    if exchange ~= nil then
      return exchange
    end
  end
  return nil
end

---@param mon unknown battle-local mon record under condition sampling
---@return table<string, boolean> persistent condition keys carried by the holder
local function holderConditions(mon)
  local present = {}
  if type(mon) ~= "table" then
    return present
  end
  local condition = (mon --[[@as table<string, unknown>]]).condition
  if type(condition) ~= "table" then
    return present
  end
  local effects = (condition --[[@as table<string, unknown>]]).effects
  if type(effects) ~= "table" then
    return present
  end
  for _, entry in
    ipairs(effects --[[@as table<integer, unknown>]])
  do
    if type(entry) == "table" then
      local key = (entry --[[@as table<string, unknown>]]).key
      if type(key) == "string" and key ~= "" then
        present[key] = true
      end
    end
  end
  return present
end

---@param combatant table<string, unknown> live combatant under health sampling
---@return integer current health bounding the item check
---@return integer health ceiling bounding the item check
local function holderHealth(combatant)
  local hp = combatant.hp
  local ceiling = combatant.maxHp
  if type(ceiling) ~= "number" then
    ceiling = combatant.entryHp
  end
  if type(hp) ~= "number" or hp % 1 ~= 0 or hp < 0 then
    error(BattleErrors.missingBehavior("trainer decisions read their holder health", {}))
  end
  if type(ceiling) ~= "number" or ceiling % 1 ~= 0 or ceiling < 1 then
    error(BattleErrors.missingBehavior("trainer decisions read their holder health", {}))
  end
  return hp, --[[@as integer]]
    ceiling --[[@as integer]]
end

---@param restore unknown generated restoration record under amount resolution
---@param ceiling integer health ceiling bounding fractional kinds
---@param item string item identity under the error context
---@return integer heal amount bounding the overheal check
local function restoreAmount(restore, ceiling, item)
  if type(restore) ~= "table" then
    error(BattleErrors.missingBehavior("trainer items carry their restoration facts", { item = item }))
  end
  local record = restore --[[@as table<string, unknown>]]
  if record.kind == "fixed" then
    if
      type(record.amount) ~= "number" or record.amount --[[@as integer]]
        % 1 ~= 0
    then
      error(BattleErrors.missingBehavior("trainer items carry their restoration facts", { item = item }))
    end
    return record.amount --[[@as integer]]
  elseif record.kind == "full" then
    return ceiling
  elseif record.kind == "half" then
    return math.floor(ceiling / 2)
  elseif record.kind == "quarter" then
    return math.floor(ceiling / 4)
  end
  error(BattleErrors.missingBehavior("trainer items carry their restoration facts", { item = item }))
end

---@param stages unknown battle-local stat stages under headroom inspection
---@return table<string, integer> validated stages for the holder
local function holderStages(stages)
  if type(stages) ~= "table" then
    error(BattleErrors.missingBehavior("trainer decisions read their battle-local stages", {}))
  end
  local record = stages --[[@as table<string, unknown>]]
  local out = {}
  for _, stat in ipairs({ "attack", "defense", "specialAttack", "specialDefense", "speed", "accuracy" }) do
    local stage = record[stat] or 0
    if type(stage) ~= "number" or stage % 1 ~= 0 then
      error(BattleErrors.missingBehavior("trainer decisions read their battle-local stages", {}))
    end
    out[stat] = stage
  end
  return out
end

-- Reads whether a battle-use serving could change state through the same
-- live battle-local effects execution uses: stage headroom, focus, the
-- side screen, and volatile cures.
---@param entry table<string, unknown> generated fact entry for the serving
---@param holderId integer holder combatant under inspection
---@param stages table<string, integer> validated holder stages
---@param view table<string, unknown> declared battle state under inspection
---@return boolean true while at least one battle-use operation applies
local function battleUseApplies(entry, holderId, stages, view)
  local battleUse = entry.battleUse
  if type(battleUse) ~= "table" then
    error(BattleErrors.missingBehavior("trainer items carry their battle-use facts", {}))
  end
  local riders = battleUse --[[@as table<string, unknown>]]
  local context = BattleContext.wrap(view)
  local flags = riders.stages
  if type(flags) == "table" then
    local decoded = flags --[[@as table<string, unknown>]]
    for _, stat in ipairs({ "attack", "defense", "specialAttack", "specialDefense", "speed", "accuracy" }) do
      if
        type(decoded[stat]) == "number"
        and decoded[stat] --[[@as integer]]
          ~= 0
      then
        local current = stages[stat] or 0
        if current < StatStages.MAX then
          return true
        end
      end
    end
    if
      type(decoded.critical) == "number"
      and decoded.critical --[[@as integer]]
        ~= 0
    then
      if not context:hasBattleEffect(holderId, "focusenergy") then
        return true
      end
    end
  end
  if riders.guardSpec == true then
    local side = context:entryOf(holderId).side --[[@as integer]]
    if context:sideEffect(side, "mist") == nil then
      return true
    end
  end
  local cures = riders.cures
  if type(cures) == "table" then
    for _, flag in ipairs(BATTLE_CURE_FLAGS) do
      if
        (cures --[[@as table<string, unknown>]])[flag] == true and context:hasBattleEffect(holderId, flag)
      then
        return true
      end
    end
  end
  return false
end

-- Checks one trainer item slot against the source item conditions
-- (ov10_022206B0): healing serves below a quarter of health or past an
-- overhealing bound, status cures serve their matching ailment at any
-- health, and battle-use servings apply through live stages, focus,
-- screens, and volatiles. Selection never consumes: quantities move
-- only when the ordinary item action executes.
---@param item string trainer item identity under the policy check
---@param facts table<string, unknown> generated fact entry for the serving
---@param holderId integer holder combatant under the policy check
---@param hp integer holder health bounding the policy check
---@param ceiling integer holder health ceiling bounding the policy check
---@param conditions table<string, boolean> holder persistent conditions under the policy check
---@param stages table<string, integer> validated holder stages under the policy check
---@param view table<string, unknown> declared battle state under the policy check
---@return boolean true while the source policy considers the slot
local function itemPolicyApplies(item, facts, holderId, hp, ceiling, conditions, stages, view)
  -- Servings gated below quarter health precede generic policy: a living
  -- holder under the bound answers regardless of ailments, while a
  -- fainted holder or a holder at or above the bound never does. The
  -- comparison stays in integers with no float threshold. An unknown
  -- gate fails closed instead of answering generically.
  local gate = facts.lowHpOnly
  if gate ~= nil then
    if gate ~= true and gate ~= false then
      error(BattleErrors.missingBehavior("trainer items carry their serving gate", { item = item }))
    end
    if gate then
      return hp > 0 and hp * 4 < ceiling
    end
  end
  local partyUse = facts.partyUse
  if partyUse == nil then
    return false
  end
  if type(partyUse) ~= "table" then
    error(BattleErrors.missingBehavior("trainer items carry their servable use facts", { item = item }))
  end
  local use = partyUse --[[@as table<string, unknown>]]
  if use.kind == "medicine" then
    if hp <= 0 then
      return false
    end
    if use.restore ~= nil then
      local amount = restoreAmount(use.restore, ceiling, item)
      if hp * 4 < ceiling or (ceiling - hp) > amount then
        return true
      end
    end
    if type(use.cures) == "table" then
      for flag, enabled in
        pairs(use.cures --[[@as table<string, unknown>]])
      do
        if enabled == true and conditions[flag] == true then
          return true
        end
      end
    end
    return false
  elseif use.kind == "deferred" then
    return battleUseApplies(facts, holderId, stages, view)
  end
  error(BattleErrors.missingBehavior("trainer items carry their servable use facts", { item = item }))
end

---@param state table<string, unknown> live battle state under inspection
---@param participant table<string, unknown> acting participant owning the inventory
---@return table<string, integer> live trainer stock quantities under inspection
local function trainerStock(state, participant)
  local inventoryId = participant.inventoryId
  if type(inventoryId) ~= "string" then
    error(BattleErrors.missingBehavior("trainer decisions read their session inventory", {}))
  end
  local inventories = state.inventories
  if type(inventories) ~= "table" then
    error(BattleErrors.missingBehavior("trainer decisions read their session inventory", {}))
  end
  local stock = inventories[inventoryId]
  if type(stock) ~= "table" or type(stock.quantities) ~= "table" then
    error(BattleErrors.missingBehavior("trainer decisions read their session inventory", {
      inventory = inventoryId,
    }))
  end
  return stock.quantities --[[@as table<string, integer>]]
end

-- Scans the ordered trainer item slots exactly as the source item
-- policy does (ov10_022206B0): consumed and empty slots never answer,
-- each slot is considered in order against the source conditions, and
-- the first source-selected item is asserted through the effectful
-- planning check before it answers. The planning check is final
-- executability only, never policy.
---@param state table<string, unknown> live battle state under inspection
---@param authorities TrainerAiAuthorities session-owned read authorities
---@param participant table<string, unknown> acting participant owning slots and stock
---@param holderId integer holder combatant under the policy check
---@param taken table<string, integer> same-request servings already answering
---@param view table<string, unknown> declared battle state under planning
---@return string? selected trainer item identity, nil without a serving
local function selectItemSlot(state, authorities, participant, holderId, taken, view)
  local controller = participant.controller
  if type(controller) ~= "string" then
    return nil
  end
  local memory = controllerMemory(state, controller)
  if memory == nil then
    return nil
  end
  local slots = memory.slots
  if type(slots) ~= "table" then
    return nil
  end
  local inventoryId = participant.inventoryId
  if type(inventoryId) ~= "string" then
    return nil
  end
  local stock = trainerStock(state, participant)
  local combatant = BattleState.combatant(state, holderId)
  local hp, ceiling = holderHealth(combatant)
  local conditions = holderConditions(combatant.mon)
  local stages = holderStages(combatant.stages)
  -- Scans the four source positions in order: gap positions never
  -- answer. The source policy clears the selected source slot at
  -- selection (ov10_022206B0): the position becomes the gap sentinel in
  -- persistent memory so later answers never reselect it while later
  -- positions keep their source indices; the taken count keeps reserving
  -- against stock that only moves when the serving executes.
  for index = 1, 4 do
    local item = slots[index]
    if type(item) == "string" and item ~= "NONE" and not CaptureContext.isBall(item) then
      local units = stock[item] or 0
      if (taken[item] or 0) < units then
        local facts = authorities.itemFacts[item]
        if type(facts) ~= "table" then
          error(BattleErrors.missingBehavior("trainer decisions read their compiled item facts", { item = item }))
        end
        if itemPolicyApplies(item, facts, holderId, hp, ceiling, conditions, stages, view) then
          local plan = ItemUse.plan({
            inventoryId = inventoryId,
            item = item,
            target = { kind = "combatant", combatant = holderId },
          }, view, authorities.itemFacts)
          if plan.failureReason == nil then
            taken[item] = (taken[item] or 0) + 1
            slots[index] = "NONE"
            return item
          end
        end
      end
    end
  end
  return nil
end

--- Executes enabled flag programs in ascending bit order through the
--- literal native program executor. Each usable slot runs its bit program
--- with slot-ordered points, stored thresholds, and the caller-owned
--- stream; random commands draw at execution, score changes flow only
--- through translated commands, and unknown behavior fails closed.
---@param facts table<string, unknown> source-visible battle facts under execution
---@param slots TrainerAiMove[] four native move slots in source order
---@param bits integer[] enabled native flag bits in ascending order
---@param thresholds table<integer, integer> stored initialization thresholds in slot order
---@param stream table<string, unknown> caller-owned battle stream for decision draws
---@return TrainerAiScoredSlot[] scored slots in source slot order
function executePrograms(facts, slots, bits, thresholds, stream)
  local points = {}
  for index, move in ipairs(slots) do
    if move.usable then
      points[index] = TrainerAi.OPENING_SCORE
    else
      points[index] = 0
    end
  end
  local scratch = 0
  local aborted = false
  for _, bit in ipairs(bits) do
    if aborted then
      break
    end
    for index, move in ipairs(slots) do
      if move.usable then
        local vm = {
          points = points,
          thresholds = thresholds,
          slot = index - 1,
          cur = move.id,
          scratch = scratch,
          bit = bit,
          facts = facts,
          rng = stream,
        }
        local outcome = TrainerAiProgram.run(vm)
        scratch = vm.scratch
        if outcome == "abort" then
          aborted = true
          break
        end
      end
    end
  end
  local scored = {}
  for index, move in ipairs(slots) do
    scored[index] = { slot = index - 1, key = move.key, score = points[index] }
  end
  return scored
end

---@param stream table<string, unknown> caller-owned battle stream for initialization draws
---@return table<integer, integer> stored 100-(draw%16) thresholds in slot order
function initThresholds(stream)
  assert(type(stream) == "table" and type(stream.nextU16) == "function", "initialization draws stream")
  local thresholds = {}
  for index = 1, 4 do
    local draw = stream:nextU16("score_init_" .. (index - 1), { slot = index - 1 })
    thresholds[index] = 100 - (draw % 16)
  end
  return thresholds
end

---@class TrainerAiActorFacts
---@field combatant table<string, unknown> acting combatant under evaluation
---@field user TrainerAiStats acting stats and types under scoring
---@field slots TrainerAiMove[] acting move slots in source order

---@param authorities TrainerAiAuthorities session-owned read authorities
---@param combatant table<string, unknown> acting combatant under evaluation
---@return TrainerAiActorFacts evaluated actor facts for attack selection
local function actorFacts(authorities, combatant)
  return {
    combatant = combatant,
    user = estimateFighter(combatant.mon --[[@as table<string, unknown>]], combatant.stages, authorities.speciesFacts),
    slots = resolveSlots(combatant.mon --[[@as table<string, unknown>]], authorities.moveFacts),
  }
end

--- Reads whether the opening turn still gates routine draws. The source
--- total-turns counter is zero through the first turn's decisions
--- (ov10_0221C278 programs read it through ov10_0221CB64); the native
--- round counter starts at one and advances per completed turn, so round
--- one is the equivalent gate.
---@param state table<string, unknown> live battle state under inspection
---@return boolean firstTurn true while the opening turn gates routine draws
local function firstTurnOf(state)
  local round = state.round
  if type(round) ~= "number" or round % 1 ~= 0 or round < 1 then
    error(BattleErrors.missingBehavior("trainer evaluation reads its battle round", {}))
  end
  return round == 1
end

-- Persistent condition bits for the status word: sleep presence sets
-- the counter bit, poison/burn/freeze/paralysis set their bits, and
-- toxic sets the bad-poison bit. Only presence feeds boolean branches.
---@param conditions table<string, boolean> persistent holder conditions
---@return integer status word under the bit tests
local function statusWordOf(conditions)
  local word = 0
  if conditions.sleep == true then
    word = word + 1
  end
  if conditions.poison == true then
    word = word + 8
  end
  if conditions.burn == true then
    word = word + 16
  end
  if conditions.freeze == true then
    word = word + 32
  end
  if conditions.paralysis == true then
    word = word + 64
  end
  if conditions.toxic == true then
    word = word + 128
  end
  return word
end

--- Resolves a held item key to its native identity and hold-effect byte
--- through the compiled item facts. Anything less than the full
--- compiled shape answers nil so the caller can fail closed at the
--- reached site instead of guessing here.
---@param authorities TrainerAiAuthorities session-owned read authorities
---@param heldKey string held item key under resolution
---@return integer? native item identity under evaluation, nil without full compiled facts
---@return integer? hold-effect byte under evaluation, nil without full compiled facts
local function heldIdentityOrNil(authorities, heldKey)
  local facts = authorities.itemFacts[heldKey]
  if type(facts) ~= "table" then
    return nil
  end
  local held = (facts --[[@as table<string, unknown>]]).heldBehavior
  if type(held) ~= "table" then
    return nil
  end
  local params = (held --[[@as table<string, unknown>]]).params --[[@as table<string, unknown>]]
  if type(params.nativeId) ~= "number" then
    return nil
  end
  if type(params.holdEffect) ~= "number" then
    return nil
  end
  local nativeId = params.nativeId --[[@as integer]]
  local holdEffect = params.holdEffect --[[@as integer]]
  return nativeId, holdEffect
end

--- Resolves a held item key to its native identity and hold-effect byte
--- through the compiled item facts. A held item without compiled
--- hold-effect facts fails closed instead of guessing.
---@param authorities TrainerAiAuthorities session-owned read authorities
---@param heldKey string held item key under resolution
---@return integer native item identity under evaluation
---@return integer hold-effect byte under evaluation
local function heldIdentity(authorities, heldKey)
  local nativeId, holdEffect = heldIdentityOrNil(authorities, heldKey)
  if nativeId == nil then
    error(BattleErrors.missingBehavior("trainer decisions read their compiled item facts", { item = heldKey }))
  end
  return nativeId, holdEffect --[[@as integer]]
end

--- Builds live program facts for one attack evaluation from battle
--- state: battler health, abilities, items, statuses, stages, parties,
--- history, and field state resolve through the session authorities.
--- Anything the live state does not model fails closed when reached.
---@param state table<string, unknown> live battle state under inspection
---@param authorities TrainerAiAuthorities session-owned read authorities
---@param combatant table<string, unknown> acting combatant under evaluation
---@param moveIdByKey table<string, integer> native move identities by move key
---@param heldEffects table<integer, integer> native hold-effect bytes by native item identity under evaluation
---@return table<string, unknown> live evaluation context for scoring
local function battlerProgramFacts(state, authorities, combatant, moveIdByKey, heldEffects)
  local combatantId = combatant.id --[[@as integer]]
  local function hasVolatile(key)
    local bag = state.effectBag
    if type(bag) ~= "table" or type(bag.capture) ~= "function" then
      return false
    end
    local capture = bag.capture --[[@as fun(self: table<string, unknown>): table<integer, table<string, unknown>>]]
    for _, record in ipairs(capture(bag)) do
      if record.key == key then
        local scope = record.scope
        if type(scope) == "table" and scope.combatant == combatantId then
          return true
        end
      end
    end
    return false
  end
  local mon = combatant.mon --[[@as table<string, unknown>]]
  local speciesFacts = authorities.speciesFacts
  local static = staticFacts(speciesFacts, mon)
  local experience = mon.experience --[[@as integer]]
  local personality = mon.personality --[[@as integer]]
  local level = Experience.level(static.growthCurve --[[@as integer[] ]], experience)
  local nature = Personality.nature(personality)
  local base = Stats.calculate(
    static.baseStats --[[@as table<string, integer>]],
    mon.ivs --[[@as table<string, integer>]],
    mon.evs --[[@as table<string, integer>]],
    level,
    nature
  )
  local stages = combatant.stages
  if type(stages) ~= "table" then
    error(BattleErrors.missingBehavior("trainer evaluation reads its battle-local stages", {}))
  end
  -- The evaluation stage array follows the battle order with its unused
  -- health slot pinned neutral: attack, defense, speed, special attack,
  -- special defense, accuracy, evasion.
  local nativeStages = { 6 }
  for _, key in ipairs({ "attack", "defense", "speed", "specialAttack", "specialDefense", "accuracy", "evasion" }) do
    local stage = (stages --[[@as table<string, integer>]])[key] or 0
    if type(stage) ~= "number" or stage % 1 ~= 0 or stage < StatStages.MIN or stage > StatStages.MAX then
      error(BattleErrors.missingBehavior("trainer evaluation reads its battle-local stages", {}))
    end
    nativeStages[#nativeStages + 1] = stage + 6
  end
  local hp, ceiling = holderHealth(combatant)
  local abilityKey = battleAbility(mon)
  local ability = 0
  if abilityKey ~= nil then
    local ids = TrainerAiProgram.ABILITY_IDS --[[@as table<string, integer>]]
    ability = ids[abilityKey] or -1
    if ability == -1 then
      error(BattleErrors.missingBehavior("trainer evaluation reads its ability identity", {}))
    end
  end
  local item = 0
  local heldKey = mon.heldItem
  if type(heldKey) == "string" and heldKey ~= "" and heldKey ~= "NONE" then
    local nativeId, holdEffect = heldIdentity(authorities, heldKey)
    item = nativeId
    if nativeId ~= 0 then
      heldEffects[nativeId] = holdEffect
    end
  end
  local conditions = holderConditions(mon)
  local status = statusWordOf(conditions)
  local moveIds = {}
  local pps = {}
  local entries = mon.moves
  if type(entries) ~= "table" then
    error(BattleErrors.missingBehavior("trainer evaluation reads its move entries", {}))
  end
  for index = 1, 4 do
    local entry = entries[index]
    if type(entry) == "table" then
      local key = (entry --[[@as table<string, unknown>]]).move --[[@as string]]
      local id = moveIdByKey[key] or 0
      moveIds[index] = id
      local pp = (entry --[[@as table<string, unknown>]]).pp
      if type(pp) == "number" then
        pps[index] = pp
      end
    else
      moveIds[index] = 0
    end
  end
  local t1 = 0
  local t2 = 0
  local typeIds = TrainerAiProgram.TYPE_IDS --[[@as table<string, integer>]]
  local formTypes = static.types --[[@as string[] ]]
  if type(formTypes[1]) == "string" then
    t1 = typeIds[formTypes[1]] or -1
  end
  if type(formTypes[2]) == "string" then
    t2 = typeIds[formTypes[2]] or -1
  else
    t2 = t1
  end
  if t1 == -1 or t2 == -1 then
    error(BattleErrors.missingBehavior("trainer evaluation reads its semantic types", {}))
  end
  local gender = 2
  local ratio = static.genderRatio
  if type(ratio) == "number" then
    local genders = Personality.gender(ratio, personality)
    if genders == "male" then
      gender = 0
    elseif genders == "female" then
      gender = 1
    end
  end
  local weightHg = static.weightHg
  local record = {
    hp = hp,
    maxHp = ceiling,
    level = level,
    t1 = t1,
    t2 = t2,
    ability = ability,
    item = item,
    status = status,
    status2 = 0,
    moveFlags = 0,
    atk = base.attack,
    def = base.defense,
    spa = base.specialAttack,
    spd = base.specialDefense,
    spe = base.speed,
    stages = {
      nativeStages[1],
      nativeStages[2],
      nativeStages[3],
      nativeStages[4],
      nativeStages[5],
      nativeStages[6],
      nativeStages[7],
      nativeStages[8],
    },
    moves = moveIds,
    pp = pps,
    gender = gender,
    weightHg = weightHg,
    friendship = mon.friendship,
    ivs = mon.ivs,
    lastMove = 0,
    entryMoves = { moveIds[1], moveIds[2], moveIds[3], moveIds[4] },
    entryAbility = ability,
    suppressed = hasVolatile("GASTRO_ACID"),
    magnetRise = false,
    roosted = false,
    miracleEye = false,
    foresight = hasVolatile("foresight"),
    flingPower = 0,
    w88b1 = 0,
    w88neg = false,
  }
  -- Move-effect flags from modeled volatiles; unmodeled mechanics never
  -- set them in these battles.
  local flags = 0
  if hasVolatile("GASTRO_ACID") then
    flags = flags + 2097152
  end
  if hasVolatile("charged") then
    flags = flags + 512
  end
  if hasVolatile("leechseed") then
    flags = flags + 4
  end
  if hasVolatile("lockon") then
    flags = flags + 24
  end
  if hasVolatile("perishsong") then
    flags = flags + 32
  end
  if hasVolatile("yawn") then
    flags = flags + 6144
  end
  if hasVolatile("aquaring") then
    flags = flags + 16777216
  end
  -- Magnet Rise, Ingrain, and semi-invulnerable turns are not modeled
  -- here; their bits read clear exactly while the engine never sets
  -- them. Revisit if those mechanics land.
  record.moveFlags = flags
  return record
end

local function moveIdMap(authorities)
  local map = {}
  for key, record in pairs(authorities.moveFacts) do
    local facts = record --[[@as table<string, unknown>]]
    if type(facts.nativeId) == "number" then
      map[key] = facts.nativeId
    end
  end
  map["STRUGGLE"] = 165
  return map
end

local function fullMoveMap(authorities)
  local map = {}
  for _, record in pairs(authorities.moveFacts) do
    local facts = record --[[@as table<string, unknown>]]
    if type(facts.nativeId) == "number" then
      map[
        facts.nativeId --[[@as integer]]
      ] = facts
    end
  end
  return map
end

local function volatilePresent(state, combatantId, key)
  local bag = state.effectBag
  if type(bag) ~= "table" or type(bag.capture) ~= "function" then
    return false
  end
  local capture = bag.capture --[[@as fun(self: table<string, unknown>): table<integer, table<string, unknown>>]]
  for _, record in ipairs(capture(bag)) do
    if record.key == key then
      local scope = record.scope
      if type(scope) == "table" and scope.combatant == combatantId then
        return true
      end
    end
  end
  return false
end

local function volatileMove(state, combatantId, keys)
  local bag = state.effectBag
  if type(bag) ~= "table" or type(bag.capture) ~= "function" then
    return nil
  end
  local capture = bag.capture --[[@as fun(self: table<string, unknown>): table<integer, table<string, unknown>>]]
  for _, record in ipairs(capture(bag)) do
    for _, key in ipairs(keys) do
      if record.key == key then
        local scope = record.scope
        if type(scope) == "table" and scope.combatant == combatantId then
          local instance = record --[[@as table<string, unknown>]]
          local stated = instance.state
          if type(stated) == "table" then
            return (stated --[[@as table<string, unknown>]]).move
          end
          return ""
        end
      end
    end
  end
  return nil
end

--- Projects one party member into its program preview record: health,
--- species, status, and moves resolve as before, while the ability key,
--- individual values, and held identity ride along for the party
--- matchup preview. A held item without full compiled facts keeps its
--- key for the reached-site failure instead of failing the evaluation.
---@param authorities TrainerAiAuthorities session-owned read authorities
---@param member table<string, unknown> live party combatant under projection
---@param heldEffects table<integer, integer> native hold-effect bytes by native item identity under evaluation
---@return table<string, unknown> party member preview record
local function partyMemberFacts(authorities, member, heldEffects)
  local mon = member.mon --[[@as table<string, unknown>]]
  local species = mon.species --[[@as string]]
  local hp = member.hp --[[@as integer]]
  local maxHp = member.maxHp
  if type(maxHp) ~= "number" then
    maxHp = member.entryHp
  end
  local conditions = {}
  if type(mon.condition) == "table" then
    local effects = (mon.condition --[[@as table<string, unknown>]]).effects
    if type(effects) == "table" then
      for _, entry in
        ipairs(effects --[[@as table<integer, unknown>]])
      do
        if
          type(entry) == "table" and type((entry --[[@as table<string, unknown>]]).key) == "string"
        then
          conditions[
            (entry --[[@as table<string, unknown>]]).key --[[@as string]]
          ] = true
        end
      end
    end
  end
  local record = {
    hp = hp,
    maxHp = maxHp,
    species = species,
    status = statusWordOf(conditions),
    moves = mon.moves,
    ability = battleAbility(mon),
    ivs = mon.ivs,
  }
  local heldKey = mon.heldItem
  if type(heldKey) == "string" and heldKey ~= "" and heldKey ~= "NONE" then
    local nativeId, holdEffect = heldIdentityOrNil(authorities, heldKey)
    if nativeId == nil then
      record.heldKey = heldKey
    elseif nativeId ~= 0 then
      record.item = nativeId
      heldEffects[nativeId] = holdEffect --[[@as integer]]
    end
  end
  return record
end

local function buildLiveExtra(state, authorities, combatant, foeCombatant)
  local extra = {} ---@type table<string, unknown>
  extra.round = state.round
  local formatDoubles = DOUBLE_FORMATS[
    state.format --[[@as string]]
  ] == true
  extra.battleType = 1
  if formatDoubles then
    extra.battleType = 3
  end
  extra.battlerCount = 2
  if formatDoubles then
    extra.battlerCount = 4
  end
  extra.liveBattlers = { [0] = true, [1] = true }
  extra.moveIdByKey = moveIdMap(authorities)
  extra.fullMoveById = fullMoveMap(authorities)
  extra.fullMoveIdByKey = extra.moveIdByKey
  extra.heldEffects = {}
  local atkId = combatant.id --[[@as integer]]
  local foeId = foeCombatant.id --[[@as integer]]
  local atkRecord = battlerProgramFacts(state, authorities, combatant, extra.moveIdByKey, extra.heldEffects)
  local foeRecord = battlerProgramFacts(state, authorities, foeCombatant, extra.moveIdByKey, extra.heldEffects)
  atkRecord.suppressed = volatilePresent(state, atkId, "GASTRO_ACID")
  foeRecord.suppressed = volatilePresent(state, foeId, "GASTRO_ACID")
  atkRecord.magnetRise = volatilePresent(state, atkId, "magnetrise")
  foeRecord.magnetRise = volatilePresent(state, foeId, "magnetrise")
  atkRecord.miracleEye = volatilePresent(state, atkId, "miracleeye")
  foeRecord.miracleEye = volatilePresent(state, foeId, "miracleeye")
  atkRecord.foresight = volatilePresent(state, atkId, "foresight")
  foeRecord.foresight = volatilePresent(state, foeId, "foresight")
  atkRecord.moveFlags = 0
  foeRecord.moveFlags = 0
  local function flagFor(combatantId, record)
    local word = 0
    if volatilePresent(state, combatantId, "GASTRO_ACID") then
      word = word + 2097152
    end
    if volatilePresent(state, combatantId, "ingrain") then
      word = word + 1024
    end
    if volatilePresent(state, combatantId, "aquaring") then
      word = word + 16777216
    end
    if volatilePresent(state, combatantId, "magnetrise") then
      word = word + 134217728
    end
    if volatilePresent(state, combatantId, "charged") then
      word = word + 512
    end
    if volatilePresent(state, combatantId, "leechseed") then
      word = word + 4
    end
    if volatilePresent(state, combatantId, "lockon") then
      word = word + 24
    end
    if volatilePresent(state, combatantId, "perishsong") then
      word = word + 32
    end
    if volatilePresent(state, combatantId, "yawn") then
      word = word + 6144
    end
    record.moveFlags = word
  end
  flagFor(atkId, atkRecord)
  flagFor(foeId, foeRecord)
  local function lastMoveId(combatantId)
    local lasts = state.lastMoves
    if type(lasts) ~= "table" then
      return 0
    end
    local key = (lasts --[[@as table<integer, string>]])[combatantId]
    if type(key) ~= "string" then
      return 0
    end
    if key == "STRUGGLE" then
      return 165
    end
    return extra.moveIdByKey[key] or 0
  end
  atkRecord.lastMove = lastMoveId(atkId)
  foeRecord.lastMove = lastMoveId(foeId)
  local function usedList(combatantRef)
    local ledger = state.usedMoves
    if type(ledger) ~= "table" then
      return {}
    end
    local active = combatantRef.active
    local token = nil
    if type(active) == "table" then
      token = active.activation
    end
    if token == nil then
      return {}
    end
    local entry = (ledger --[[@as table<integer, unknown>]])[token]
    return orderedUsedIds(extra.moveIdByKey, entry)
  end
  extra.liveAttacker = atkRecord
  extra.liveTarget = foeRecord
  extra.usedIds = { [0] = usedList(foeCombatant), [1] = usedList(combatant) }
  extra.lastMove = { [0] = foeRecord.lastMove, [1] = atkRecord.lastMove }
  extra.parties = { [0] = {}, [1] = {} }
  extra.partyIndex = {}
  extra.partyPartner = {}
  local function partyFor(battler, combatantRef)
    local participant = BattleState.participant(state, combatantRef.participant --[[@as integer]])
    local members = {}
    local own = 0
    for index, combatantId in
      ipairs(participant.roster --[[@as integer[] ]])
    do
      local member = BattleState.combatant(state, combatantId --[[@as integer]])
      if combatantId == combatantRef.id then
        own = index - 1
      end
      members[#members + 1] = partyMemberFacts(authorities, member, extra.heldEffects)
    end
    extra.parties[battler] = members
    extra.partyIndex[battler] = own
    extra.partyPartner[battler] = 0
  end
  partyFor(1, combatant)
  partyFor(0, foeCombatant)
  local function lockId(combatantId, keys)
    local move = volatileMove(state, combatantId, keys)
    if type(move) ~= "string" or move == "" then
      return 0
    end
    if move == "STRUGGLE" then
      return 165
    end
    local id = extra.moveIdByKey[move]
    if id == nil then
      error(BattleErrors.missingBehavior("trainer evaluation reads its locked move", {}))
    end
    return id
  end
  local atkEncore = volatileMove(state, atkId, { "ENCORE" })
  local atkEncoreSlot = 0
  if type(atkEncore) == "string" and atkEncore ~= "" then
    local entries = combatant.mon --[[@as table<string, unknown>]]
    local moves = entries.moves --[[@as table<integer, unknown>]]
    if type(moves) == "table" then
      for index, entry in ipairs(moves) do
        if
          type(entry) == "table" and (entry --[[@as table<string, unknown>]]).move == atkEncore
        then
          atkEncoreSlot = index - 1
          break
        end
      end
    end
  end
  local foeEncore = volatileMove(state, foeId, { "ENCORE" })
  local foeEncoreSlot = 0
  if type(foeEncore) == "string" and foeEncore ~= "" then
    local entries = foeCombatant.mon --[[@as table<string, unknown>]]
    local moves = entries.moves --[[@as table<integer, unknown>]]
    if type(moves) == "table" then
      for index, entry in ipairs(moves) do
        if
          type(entry) == "table" and (entry --[[@as table<string, unknown>]]).move == foeEncore
        then
          foeEncoreSlot = index - 1
          break
        end
      end
    end
  end
  extra.encoreSlot = { [0] = foeEncoreSlot, [1] = atkEncoreSlot }
  local function protectId(combatantId)
    if volatilePresent(state, combatantId, "PROTECT") then
      return 182
    end
    if volatilePresent(state, combatantId, "DETECT") then
      return 197
    end
    if volatilePresent(state, combatantId, "ENDURE") then
      return 203
    end
    return 0
  end
  extra.protectMove = { [0] = protectId(foeId), [1] = protectId(atkId) }
  extra.lockedMoves = {
    encore = lockId(atkId, { "ENCORE" }),
    disable = lockId(atkId, { "DISABLE" }),
  }
  extra.recycle = {}
  return extra
end

local function evaluateSingles(state, authorities, facts, opponents, bits, stream)
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
    error(BattleErrors.missingBehavior("trainer evaluation reads its opposing health", {}))
  end
  local live = buildLiveExtra(state, authorities, facts.combatant, foe)
  local scored = TrainerAi.scoreSlots(
    authorities.chart,
    facts.slots,
    facts.user,
    foeStats,
    foeHp,
    bits,
    firstTurnOf(state),
    stream,
    live
  )
  local moveSlot = 0
  if hasUsable(facts.slots) then
    moveSlot = TrainerAi.selectMove(scored, stream)
  end
  return {
    kind = "attack",
    payload = { moveSlot = moveSlot, target = { kind = "position", position = foePosition } },
  }
end

--- Builds live program facts for one doubles candidate evaluation: every
--- battler slot carries its live record (absent slots stay absent and read
--- zeroed), parties and histories resolve per battler, and the entry-bit map
--- marks battlers with no live mon available for the switch-in jumps.
---@param state table<string, unknown> live battle state under inspection
---@param authorities TrainerAiAuthorities session-owned read authorities
---@param attacker table<string, unknown> acting combatant under evaluation
---@param byId table<integer, table<string, unknown>> live combatants by battler identity
---@param attackerId integer acting battler identity under evaluation
---@param targetId integer candidate battler identity under evaluation
---@return table<string, unknown> live evaluation context for scoring
local function buildDoublesExtra(state, authorities, attacker, byId, attackerId, targetId)
  local extra = {} ---@type table<string, unknown>
  extra.round = state.round
  extra.battleType = 3
  extra.battlerCount = 4
  extra.moveIdByKey = moveIdMap(authorities)
  extra.fullMoveById = fullMoveMap(authorities)
  extra.fullMoveIdByKey = extra.moveIdByKey
  extra.heldEffects = {}
  local records = {}
  local live = {}
  local switchIn = {}
  local usedIds = {}
  local lasts = {}
  local encoreSlot = {}
  local protectMove = {}
  local parties = {}
  local partyIndex = {}
  local partyPartner = {}
  local function lastMoveId(combatantId)
    local recent = state.lastMoves
    if type(recent) ~= "table" then
      return 0
    end
    local key = (recent --[[@as table<integer, string>]])[combatantId]
    if type(key) ~= "string" then
      return 0
    end
    if key == "STRUGGLE" then
      return 165
    end
    return extra.moveIdByKey[key] or 0
  end
  local function usedList(combatantRef)
    local ledger = state.usedMoves
    if type(ledger) ~= "table" then
      return {}
    end
    local active = combatantRef.active
    local token = nil
    if type(active) == "table" then
      token = active.activation
    end
    if token == nil then
      return {}
    end
    local entry = (ledger --[[@as table<integer, unknown>]])[token]
    return orderedUsedIds(extra.moveIdByKey, entry)
  end
  local function lockId(combatantId, keys)
    local move = volatileMove(state, combatantId, keys)
    if type(move) ~= "string" or move == "" then
      return 0
    end
    if move == "STRUGGLE" then
      return 165
    end
    local id = extra.moveIdByKey[move]
    if id == nil then
      error(BattleErrors.missingBehavior("trainer evaluation reads its locked move", {}))
    end
    return id
  end
  local function protectId(combatantId)
    if volatilePresent(state, combatantId, "PROTECT") then
      return 182
    end
    if volatilePresent(state, combatantId, "DETECT") then
      return 197
    end
    if volatilePresent(state, combatantId, "ENDURE") then
      return 203
    end
    return 0
  end
  local function encoreSlotFor(combatantRef)
    local combatantId = combatantRef.id --[[@as integer]]
    local move = volatileMove(state, combatantId, { "ENCORE" })
    if type(move) ~= "string" or move == "" then
      return 0
    end
    local entries = combatantRef.mon --[[@as table<string, unknown>]]
    local moves = entries.moves --[[@as table<integer, unknown>]]
    if type(moves) == "table" then
      for index, entry in ipairs(moves) do
        if
          type(entry) == "table" and (entry --[[@as table<string, unknown>]]).move == move
        then
          return index - 1
        end
      end
    end
    return 0
  end
  local function partyFor(battler, combatantRef)
    local participant = BattleState.participant(state, combatantRef.participant --[[@as integer]])
    local members = {}
    local own = 0
    for index, combatantId in
      ipairs(participant.roster --[[@as integer[] ]])
    do
      local member = BattleState.combatant(state, combatantId --[[@as integer]])
      if combatantId == combatantRef.id then
        own = index - 1
      end
      members[#members + 1] = partyMemberFacts(authorities, member, extra.heldEffects)
    end
    parties[battler] = members
    partyIndex[battler] = own
    partyPartner[battler] = 0
  end
  for battler = 0, 3 do
    local combatant = byId[battler]
    if combatant ~= nil then
      local combatantId = combatant.id --[[@as integer]]
      local record = battlerProgramFacts(state, authorities, combatant, extra.moveIdByKey, extra.heldEffects)
      record.suppressed = volatilePresent(state, combatantId, "GASTRO_ACID")
      record.magnetRise = volatilePresent(state, combatantId, "magnetrise")
      record.miracleEye = volatilePresent(state, combatantId, "miracleeye")
      record.foresight = volatilePresent(state, combatantId, "foresight")
      local word = 0
      if volatilePresent(state, combatantId, "GASTRO_ACID") then
        word = word + 2097152
      end
      if volatilePresent(state, combatantId, "ingrain") then
        word = word + 1024
      end
      if volatilePresent(state, combatantId, "aquaring") then
        word = word + 16777216
      end
      if volatilePresent(state, combatantId, "magnetrise") then
        word = word + 134217728
      end
      if volatilePresent(state, combatantId, "charged") then
        word = word + 512
      end
      if volatilePresent(state, combatantId, "leechseed") then
        word = word + 4
      end
      if volatilePresent(state, combatantId, "lockon") then
        word = word + 24
      end
      if volatilePresent(state, combatantId, "perishsong") then
        word = word + 32
      end
      if volatilePresent(state, combatantId, "yawn") then
        word = word + 6144
      end
      record.moveFlags = word
      record.lastMove = lastMoveId(combatantId)
      records[battler] = record
      live[battler] = true
      lasts[battler] = record.lastMove
      usedIds[battler] = usedList(combatant)
      encoreSlot[battler] = encoreSlotFor(combatant)
      protectMove[battler] = protectId(combatantId)
      partyFor(battler, combatant)
      local hp = combatant.hp
      if type(hp) == "number" and hp > 0 then
        switchIn[battler] = false
      else
        local participant = BattleState.participant(state, combatant.participant --[[@as integer]])
        switchIn[battler] = #livingReserves(state, participant, {}) == 0
      end
    else
      parties[battler] = {}
      partyIndex[battler] = 0
      partyPartner[battler] = 0
    end
  end
  extra.parties = parties
  extra.partyIndex = partyIndex
  extra.partyPartner = partyPartner
  extra.doublesBattlers = { atk = attackerId, tgt = targetId, records = records }
  extra.liveBattlers = live
  extra.switchIn = switchIn
  extra.usedIds = usedIds
  extra.lastMove = lasts
  extra.encoreSlot = encoreSlot
  extra.protectMove = protectMove
  local attackerIdNumber = attacker.id --[[@as integer]]
  extra.lockedMoves = {
    encore = lockId(attackerIdNumber, { "ENCORE" }),
    disable = lockId(attackerIdNumber, { "DISABLE" }),
  }
  extra.recycle = {}
  return extra
end

-- Evaluates one doubles actor through the doubles selector
-- (ov10_0221C038): the doubles pass joins the enabled flags, battler
-- slots evaluate in source order with dead and self slots excluded, every
-- candidate receives a fresh scratch initialization through the shared
-- scoring path, each candidate bids its winning move, and the highest bid
-- answers with ties broken through one selection draw. Ally slots bid
-- where the source admits them; self-aimed winners retarget to the holder.
---@param authorities TrainerAiAuthorities session-owned read authorities
---@param facts TrainerAiActorFacts acting facts under evaluation
---@param state table<string, unknown> live battle state under inspection
---@param bits integer[] enabled native flag bits in ascending order
---@param stream table<string, unknown> caller-owned battle stream for decision draws
---@return table<string, unknown> attack choice in the shared decision shape
local function evaluateDoubles(authorities, facts, state, bits, stream)
  local firstTurn = firstTurnOf(state)
  local evenIds = {}
  local oddIds = {}
  for _, positionId in
    ipairs(state.positionOrder --[[@as integer[] ]])
  do
    local position = BattleState.position(state, positionId)
    local occupant = position.occupant
    if occupant ~= nil then
      local combatant = BattleState.combatant(state, occupant --[[@as integer]])
      if combatant.active ~= nil then
        local side = BattleState.participant(state, combatant.participant --[[@as integer]]).side
        local entry = { position = positionId, combatant = combatant }
        if side == 1 then
          evenIds[#evenIds + 1] = entry
        else
          oddIds[#oddIds + 1] = entry
        end
      end
    end
  end
  assert(#evenIds <= 2 and #oddIds <= 2, "doubles fields at most two battlers per side")
  local byId = {}
  local positionOf = {}
  local sideOf = {}
  for index, entry in ipairs(evenIds) do
    local id = (index - 1) * 2
    byId[id] = entry.combatant
    positionOf[id] = entry.position
    sideOf[id] = 1
  end
  for index, entry in ipairs(oddIds) do
    local id = (index - 1) * 2 + 1
    byId[id] = entry.combatant
    positionOf[id] = entry.position
    sideOf[id] = 2
  end
  local attacker = nil ---@type integer?
  for id, combatant in pairs(byId) do
    if combatant.id == facts.combatant.id then
      attacker = id
    end
  end
  assert(attacker ~= nil, "doubles attackers hold their battler identity")
  local forced = {}
  local doubles = false
  for _, bit in ipairs(bits) do
    forced[#forced + 1] = bit
    if bit == 7 then
      doubles = true
    end
  end
  if not doubles then
    forced[#forced + 1] = 7
  end
  table.sort(forced)
  -- The normal doubles entry draws its scratch opposing slot and runs
  -- its scratch initialization before candidate traversal: each
  -- candidate overwrites that target and reinitializes, but the leading
  -- draws still advance the shared stream in source order. The draw
  -- always chooses between the two opposing slots even when only one
  -- foe stands, so it never goes through the lone-foe shortcut.
  stream:nextU16("target_foe", { opponents = 2 })
  initThresholds(stream)
  local bids = {}
  for candidate = 0, 3 do
    local target = byId[candidate]
    if candidate ~= attacker and target ~= nil then
      local targetHp = target.hp
      if type(targetHp) ~= "number" or targetHp % 1 ~= 0 or targetHp < 0 then
        error(BattleErrors.missingBehavior("trainer evaluation reads its opposing health", {}))
      end
      local candidateHp = targetHp --[[@as integer]]
      if candidateHp > 0 then
        local targetStats =
          estimateFighter(target.mon --[[@as table<string, unknown>]], target.stages, authorities.speciesFacts)
        local live = buildDoublesExtra(state, authorities, facts.combatant, byId, attacker, candidate)
        local scored = TrainerAi.scoreSlots(
          authorities.chart,
          facts.slots,
          facts.user,
          targetStats,
          candidateHp,
          forced,
          firstTurn,
          stream,
          live
        )
        local moveSlot = 0
        local top = nil
        if hasUsable(facts.slots) then
          moveSlot = TrainerAi.selectMove(scored, stream)
          for _, entry in ipairs(scored) do
            if entry.slot == moveSlot then
              top = entry.score
            end
          end
        end
        assert(top ~= nil or not hasUsable(facts.slots), "winning bids carry their native points")
        bids[#bids + 1] = { target = positionOf[candidate], slot = moveSlot, score = top or 0 }
      end
    end
  end
  assert(#bids > 0, "doubles selection reads its live candidates")
  local target, slot = TrainerAi.selectDoubles(bids, stream)
  local chosen = facts.slots[slot + 1]
  if chosen ~= nil and chosen.usable then
    local active = facts.combatant.active
    assert(type(active) == "table", "doubles holders keep their entry")
    local ownPosition = active.position --[[@as integer]]
    assert(type(ownPosition) == "number", "doubles holders keep their position")
    local detail = authorities.moveFacts[chosen.key]
    if type(detail) ~= "table" then
      error(BattleErrors.missingBehavior("trainer evaluation reads its compiled move facts", {
        key = chosen.key,
      }))
    end
    local range = (detail --[[@as table<string, unknown>]]).range
    if type(range) ~= "number" then
      error(BattleErrors.missingBehavior("trainer evaluation reads its compiled move range", {
        key = chosen.key,
      }))
    end
    -- Single-target user-side winners aimed across the field retarget to
    -- the holder, as do non-ghost Curse winners.
    if range == 512 then
      for id, position in pairs(positionOf) do
        if position == target and sideOf[id] == 1 then
          target = ownPosition --[[@as integer]]
        end
      end
    end
    if chosen.id == 174 then
      local ghost = false
      for _, key in ipairs(facts.user.types) do
        if key == "ghost" then
          ghost = true
        end
      end
      if not ghost then
        target = ownPosition --[[@as integer]]
      end
    end
  end
  return {
    kind = "attack",
    payload = { moveSlot = slot, target = { kind = "position", position = target } },
  }
end

--- Answers one actor of the trainer request from live session state and
--- facts, following the source action order (ov10_022205BC): the switch
--- gate answers first, then the ordered trainer item path, otherwise the
--- attack evaluation. Reads only; battle state, stock, and stream
--- ownership stay with the caller while same-request servings accumulate
--- in the caller-owned taken map.
---@param state table<string, unknown> live battle state under inspection
---@param authorities TrainerAiAuthorities session-owned read authorities
---@param participant table<string, unknown> acting participant owning passes and stock
---@param actor table<string, unknown> addressed actor with its entry token
---@param opponents table<integer, table<string, unknown>> live opposing entries in position order
---@param claimed table<integer, boolean> reserves already answering this request
---@param taken table<string, integer> same-request servings already answering
---@param bits integer[] enabled native flag bits in ascending order
---@param doubles boolean true while the live format routes through doubles
---@param stream table<string, unknown> caller-owned battle stream for decision draws
---@return table<string, unknown> choice in the shared decision shape
local function answerActor(state, authorities, participant, actor, opponents, claimed, taken, bits, doubles, stream)
  local combatant = BattleState.combatant(state, actor.combatant --[[@as integer]])
  local active = combatant.active
  if type(active) ~= "table" or active.activation ~= actor.activation then
    error(BattleErrors.input("locked references die with their entry", { combatant = actor.combatant }))
  end
  local facts = actorFacts(authorities, combatant)
  local holderHp, holderCeiling = holderHealth(combatant)
  if
    not switchHeld(state, actor.combatant --[[@as integer]], facts.user.types, opponents)
  then
    local reserveIds = livingReserves(state, participant, claimed)
    if #reserveIds > 0 then
      local reserves = {}
      for _, reserveId in ipairs(reserveIds) do
        local reserve = BattleState.combatant(state, reserveId)
        reserves[#reserves + 1] = {
          id = reserveId,
          stats = estimateFighter(
            reserve.mon --[[@as table<string, unknown>]],
            reserve.stages,
            authorities.speciesFacts
          ),
          slots = resolveSlots(reserve.mon --[[@as table<string, unknown>]], authorities.moveFacts),
        }
      end
      local foes = {}
      for _, opposed in ipairs(opponents) do
        local foe = BattleState.combatant(state, opposed.combatant)
        local foeHp = foe.hp
        if type(foeHp) ~= "number" or foeHp % 1 ~= 0 or foeHp < 0 then
          error(BattleErrors.missingBehavior("trainer evaluation reads its opposing health", {}))
        end
        foes[#foes + 1] = {
          id = opposed.combatant,
          position = opposed.position,
          stats = estimateFighter(foe.mon --[[@as table<string, unknown>]], foe.stages, authorities.speciesFacts),
          hp = foeHp,
        }
      end
      local conditions = holderConditions(combatant.mon --[[@as table<string, unknown>]])
      local foeTypes = foes[1].stats.types
      local foeTypesPair = { foeTypes }
      if doubles and #foes >= 2 then
        foeTypesPair[#foeTypesPair + 1] = foes[2].stats.types
      end
      local foeTypesDoubled = { foeTypes, foeTypes }
      if doubles and #foes >= 2 then
        foeTypesDoubled = { foeTypes, foes[2].stats.types }
      end
      local foesHealthy = true
      for _, foe in ipairs(foes) do
        if foe.hp <= 0 then
          foesHealthy = false
        end
      end
      local foeMon = BattleState.combatant(state, foes[1].id).mon
      local exchange = selectReplacement(state, authorities, {
        holderId = actor.combatant --[[@as integer]],
        holderSlots = facts.slots,
        holderHp = holderHp,
        holderCeiling = holderCeiling,
        holderAbility = battleAbility(combatant.mon),
        holderAsleep = conditions.sleep == true,
        holderStages = combatant.stages,
        doubles = doubles,
        reserves = reserves,
        foeTypes = foeTypes,
        foeTypesPair = foeTypesPair,
        foeTypesDoubled = foeTypesDoubled,
        foeWonderGuard = battleAbility(foeMon) == "WONDER_GUARD",
        foesScanned = #foes,
        foesHealthy = foesHealthy,
      }, stream)
      if exchange ~= nil then
        local verdict = Switching.eligible({
          reason = "voluntary",
          position = active.position,
          incoming = exchange,
          reserves = reserveIds,
          reserved = {},
          fainted = {},
          trap = nil,
        })
        if not verdict.ok then
          error(BattleErrors.invalidState("selected exchanges stay eligible", { reason = verdict.reason }))
        end
        claimed[exchange] = true
        return { actor = actor, kind = "switch", payload = { replacement = exchange } }
      end
    end
  end
  local serving = selectItemSlot(state, authorities, participant, actor.combatant --[[@as integer]], taken, state)
  if serving ~= nil then
    return {
      actor = actor,
      kind = "item",
      payload = { item = serving, target = { kind = "combatant", combatant = actor.combatant } },
    }
  end
  local attack
  if doubles then
    attack = evaluateDoubles(authorities, facts, state, bits, stream)
  else
    attack = evaluateSingles(state, authorities, facts, opponents, bits, stream)
  end
  attack.actor = actor
  return attack
end

--- Answers the trainer request from live session state and facts. The
--- caller owns request validation, the decision lease, and stream
--- ownership; this resolves opponents from battle topology and returns
--- one ordinary reply for every addressed actor in source order. The
--- taken map carries same-request servings across actors and answers;
--- it is caller-owned pending-reply state, never persisted knowledge.
---@param state table<string, unknown> live battle state under inspection
---@param authorities TrainerAiAuthorities session-owned read authorities
---@param request table<string, unknown> open internal trainer request under verification
---@param stream table<string, unknown> caller-owned battle stream for decision draws
---@param taken table<string, integer> same-request servings already answering
---@return table<string, unknown> reply in the shared decision shape
function TrainerAi.answer(state, authorities, request, stream, taken)
  assert(type(state) == "table", "trainer decisions read live battle state")
  assert(type(authorities) == "table", "trainer decisions read their session authorities")
  assert(type(request) == "table", "trainer decisions answer a pending request")
  assert(
    type(stream) == "table" and type(stream.nextU16) == "function",
    "trainer decisions draw from the battle stream"
  )
  assert(type(taken) == "table", "trainer decisions track their same-request servings")
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
  local doubles = DOUBLE_FORMATS[
    state.format --[[@as string]]
  ] == true
  local claimed = {}
  local choices = {}
  for _, actor in
    ipairs(request.actors --[[@as table<integer, unknown>]])
  do
    local entry = actor --[[@as table<string, unknown>]]
    local combatant = BattleState.combatant(state, entry.combatant --[[@as integer]])
    local participant = BattleState.participant(state, combatant.participant --[[@as integer]])
    local context = participant.context
    if type(context) ~= "table" or type(context.aiPasses) ~= "table" then
      error(BattleErrors.missingBehavior("trainer sides carry their generated pass facts", {
        controller = participant.controller,
      }))
    end
    local bits = TrainerAi.parsePasses(context.aiPasses --[[@as string[] ]])
    choices[#choices + 1] =
      answerActor(state, authorities, participant, entry, opponents, claimed, taken, bits, doubles, stream)
  end
  return {
    requestId = request.requestId,
    epoch = request.epoch,
    controller = request.controller,
    choices = choices,
  }
end

return TrainerAi
