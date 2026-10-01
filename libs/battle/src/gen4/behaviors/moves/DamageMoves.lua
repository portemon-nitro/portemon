-- Direct, fixed, and variable damage families: ordinary strikes, fixed and
-- level damage, one-hit knockouts, counter-style reactions, variable
-- power, and multi-hit sequences. Every member binds its own handler, so
-- moves with disjoint mechanics never share one function; members without
-- pinned native parameters run the family canonical sequence, which emits
-- the ordered move event and completes without inventing power, accuracy,
-- or secondary effects. Curated members carry source parameters beside
-- their bodies. Damage arithmetic always travels the staged owner, and
-- per-hit draws, faint stops, and substitute breaks follow source order.
-- Source references: src/battle/battle_command.c and
-- src/battle/overlay_12_0224E4FC.c.

local Accuracy = require("libs.battle.src.gen4.Accuracy")
local BattleRng = require("libs.battle.src.gen4.BattleRng")
local Critical = require("libs.battle.src.gen4.Critical")
local Damage = require("libs.battle.src.gen4.Damage")

---@class DamageMoves
local DamageMoves = {}

-- Reference combat inputs for the staged arithmetic when the frame carries
-- no explicit combat facts. Power derivation stays exact for every
-- curated member; these inputs only fill the level/attack/defense slots
-- the frame protocol does not thread yet.
local REFERENCE_LEVEL = 10
local REFERENCE_ATTACK = 50
local REFERENCE_DEFENSE = 50

-- Pinned native parameters for curated members: power and accuracy are
-- source facts, recoil names its fraction, and focus marks the
-- interrupted-setup gate.
local STRIKERS = {
  TACKLE = { power = 35, accuracy = 95 },
  JUMP_KICK = { power = 85, crash = true },
  HI_JUMP_KICK = { power = 100, crash = true },
  TAKE_DOWN = { power = 90, recoil = "quarter" },
  DOUBLE_EDGE = { power = 120, recoil = "quarter" },
  SUBMISSION = { power = 80, recoil = "quarter" },
  BRAVE_BIRD = { power = 120, recoil = "third" },
  FLARE_BLITZ = { power = 120, recoil = "third" },
  VOLT_TACKLE = { power = 120, recoil = "third" },
  WOOD_HAMMER = { power = 120, recoil = "third" },
  HEAD_SMASH = { power = 150, recoil = "half" },
  STRUGGLE = { power = 50, recoil = "quarter" },
  EXPLOSION = { power = 250, selfKo = true },
  SELFDESTRUCT = { power = 200, selfKo = true },
  FAINT_ATTACK = { power = 60, skipAccuracy = true },
  SWIFT = { power = 60, skipAccuracy = true },
  AERIAL_ACE = { power = 60, skipAccuracy = true },
  SHADOW_PUNCH = { power = 60, skipAccuracy = true },
  MAGNET_BOMB = { power = 60, skipAccuracy = true },
  AURA_SPHERE = { power = 90, skipAccuracy = true },
  SHOCK_WAVE = { power = 60, skipAccuracy = true },
  MAGICAL_LEAF = { power = 60, skipAccuracy = true },
  MACH_PUNCH = { power = 40 },
  QUICK_ATTACK = { power = 40 },
  ICE_SHARD = { power = 40 },
  AQUA_JET = { power = 40 },
  BULLET_PUNCH = { power = 40 },
  SHADOW_SNEAK = { power = 40 },
  VACUUM_WAVE = { power = 40 },
  EXTREME_SPEED = { power = 80 },
  VITAL_THROW = { power = 70 },
  RAPID_SPIN = { power = 20 },
  FOCUS_PUNCH = { power = 150, focus = true },
  DREAM_EATER = { power = 100 },
}

-- Members dealing a fixed amount without staged arithmetic.
local FIXED = {
  SONIC_BOOM = 20,
  DRAGON_RAGE = 40,
}

-- Members whose damage equals the user level once the frame carries it.
local LEVEL_FIXED = {
  SEISMIC_TOSS = true,
  NIGHT_SHADE = true,
}

-- One-hit knockouts: without both combatant levels the source level gate
-- cannot resolve, so these settle as failures instead of guessing.
local OHKO = {
  GUILLOTINE = true,
  HORN_DRILL = true,
  SHEER_COLD = true,
  FISSURE = true,
}

-- Weight-derived power from the source ladder in
-- src/battle/battle_command.c GetMonWeight brackets: at most 10kg deals
-- 20, 25kg deals 40, 50kg deals 60, 100kg deals 80, 200kg deals 100, and
-- anything heavier deals 120. Needs the defender weight fact.
local WEIGHT = {
  LOW_KICK = true,
  GRASS_KNOT = true,
}

-- Members gated on facts the frame protocol does not thread yet: counter
-- history, hit records, weight or health fractions, and berry or plate
-- identities. They settle as failures rather than dealing guessed damage.
local GATED = {
  COUNTER = true,
  MIRROR_COAT = true,
  METAL_BURST = true,
  BIDE = true,
  REVERSAL = true,
  FLAIL = true,
  CRUSH_GRIP = true,
  WRING_OUT = true,
  PSYWAVE = true,
  TRUMP_CARD = true,
  FLING = true,
  NATURAL_GIFT = true,
  PRESENT = true,
  HIDDEN_POWER = true,
  JUDGMENT = true,
  WEATHER_BALL = true,
  GYRO_BALL = true,
  PUNISHMENT = true,
  ASSURANCE = true,
  PAYBACK = true,
  LAST_RESORT = true,
  BRINE = true,
  FACADE = true,
  AVALANCHE = true,
  REVENGE = true,
  SMELLING_SALT = true,
  WAKE_UP_SLAP = true,
  SNORE = true,
  STOMP = true,
  SUPERPOWER = true,
  CLOSE_COMBAT = true,
  LEAF_STORM = true,
  DRACO_METEOR = true,
  OVERHEAT = true,
  PSYCHO_BOOST = true,
  ERUPTION = true,
  WATER_SPOUT = true,
}

-- Two-to-five-hit members running genuine hit-count sampling with the
-- canonical per-hit sequence.
local MULTI_25 = {
  DOUBLE_SLAP = true,
  COMET_PUNCH = true,
  FURY_ATTACK = true,
  PIN_MISSILE = true,
  SPIKE_CANNON = true,
  BONE_RUSH = true,
  ARM_THRUST = true,
  BULLET_SEED = true,
  ICICLE_SPEAR = true,
  ROCK_BLAST = true,
  DOUBLE_HIT = true,
  TWINEEDLE = true,
  FURY_SWIPES = true,
  BARRAGE = true,
  TRIPLE_KICK = true,
}

DamageMoves.MEMBERS = {
  "ABSORB",
  "ACID",
  "AERIAL_ACE",
  "AEROBLAST",
  "AIR_CUTTER",
  "AIR_SLASH",
  "ANCIENT_POWER",
  "AQUA_JET",
  "AQUA_TAIL",
  "ARM_THRUST",
  "ASSURANCE",
  "ASTONISH",
  "ATTACK_ORDER",
  "AURA_SPHERE",
  "AURORA_BEAM",
  "AVALANCHE",
  "BARRAGE",
  "BEAT_UP",
  "BIDE",
  "BIND",
  "BITE",
  "BLAZE_KICK",
  "BLIZZARD",
  "BODY_SLAM",
  "BONEMERANG",
  "BONE_CLUB",
  "BONE_RUSH",
  "BRAVE_BIRD",
  "BRICK_BREAK",
  "BRINE",
  "BUBBLE",
  "BUBBLE_BEAM",
  "BUG_BITE",
  "BUG_BUZZ",
  "BULLET_PUNCH",
  "BULLET_SEED",
  "CHARGE_BEAM",
  "CHATTER",
  "CLAMP",
  "CLOSE_COMBAT",
  "COMET_PUNCH",
  "CONFUSION",
  "CONSTRICT",
  "COUNTER",
  "COVET",
  "CRABHAMMER",
  "CROSS_CHOP",
  "CROSS_POISON",
  "CRUNCH",
  "CRUSH_CLAW",
  "CRUSH_GRIP",
  "CUT",
  "DARK_PULSE",
  "DISCHARGE",
  "DIZZY_PUNCH",
  "DOUBLE_EDGE",
  "DOUBLE_HIT",
  "DOUBLE_KICK",
  "DOUBLE_SLAP",
  "DRACO_METEOR",
  "DRAGON_BREATH",
  "DRAGON_CLAW",
  "DRAGON_PULSE",
  "DRAGON_RAGE",
  "DRAGON_RUSH",
  "DRAIN_PUNCH",
  "DREAM_EATER",
  "DRILL_PECK",
  "DYNAMIC_PUNCH",
  "EARTHQUAKE",
  "EARTH_POWER",
  "EGG_BOMB",
  "EMBER",
  "ENDEAVOR",
  "ENERGY_BALL",
  "ERUPTION",
  "EXPLOSION",
  "EXTRASENSORY",
  "EXTREME_SPEED",
  "FACADE",
  "FAINT_ATTACK",
  "FALSE_SWIPE",
  "FEINT",
  "FIRE_BLAST",
  "FIRE_FANG",
  "FIRE_PUNCH",
  "FIRE_SPIN",
  "FISSURE",
  "FLAIL",
  "FLAMETHROWER",
  "FLAME_WHEEL",
  "FLARE_BLITZ",
  "FLASH_CANNON",
  "FLING",
  "FOCUS_BLAST",
  "FORCE_PALM",
  "FRUSTRATION",
  "FURY_ATTACK",
  "FURY_SWIPES",
  "GIGA_DRAIN",
  "GRASS_KNOT",
  "GUILLOTINE",
  "GUNK_SHOT",
  "GUST",
  "GYRO_BALL",
  "HAMMER_ARM",
  "HEADBUTT",
  "HEAD_SMASH",
  "HEAT_WAVE",
  "HIDDEN_POWER",
  "HI_JUMP_KICK",
  "HORN_ATTACK",
  "HORN_DRILL",
  "HYDRO_PUMP",
  "HYPER_FANG",
  "HYPER_VOICE",
  "ICE_BEAM",
  "ICE_FANG",
  "ICE_PUNCH",
  "ICE_SHARD",
  "ICICLE_SPEAR",
  "ICY_WIND",
  "IRON_HEAD",
  "IRON_TAIL",
  "JUDGMENT",
  "JUMP_KICK",
  "KARATE_CHOP",
  "KNOCK_OFF",
  "LAST_RESORT",
  "LAVA_PLUME",
  "LEAF_BLADE",
  "LEAF_STORM",
  "LEECH_LIFE",
  "LICK",
  "LOW_KICK",
  "LUSTER_PURGE",
  "MACH_PUNCH",
  "MAGICAL_LEAF",
  "MAGMA_STORM",
  "MAGNET_BOMB",
  "MAGNITUDE",
  "MEGAHORN",
  "MEGA_DRAIN",
  "MEGA_KICK",
  "MEGA_PUNCH",
  "METAL_BURST",
  "METAL_CLAW",
  "METEOR_MASH",
  "MIRROR_COAT",
  "MIRROR_SHOT",
  "MIST_BALL",
  "MUDDY_WATER",
  "MUD_BOMB",
  "MUD_SHOT",
  "MUD_SLAP",
  "NATURAL_GIFT",
  "NEEDLE_ARM",
  "NIGHT_SHADE",
  "NIGHT_SLASH",
  "OCTAZOOKA",
  "OMINOUS_WIND",
  "OVERHEAT",
  "PAYBACK",
  "PAY_DAY",
  "PECK",
  "PIN_MISSILE",
  "PLUCK",
  "POISON_FANG",
  "POISON_JAB",
  "POISON_STING",
  "POISON_TAIL",
  "POUND",
  "POWDER_SNOW",
  "POWER_GEM",
  "POWER_WHIP",
  "PRESENT",
  "PSYBEAM",
  "PSYCHIC",
  "PSYCHO_BOOST",
  "PSYCHO_CUT",
  "PSYWAVE",
  "PUNISHMENT",
  "QUICK_ATTACK",
  "RAPID_SPIN",
  "RAZOR_LEAF",
  "RETURN",
  "REVENGE",
  "REVERSAL",
  "ROCK_BLAST",
  "ROCK_CLIMB",
  "ROCK_SLIDE",
  "ROCK_SMASH",
  "ROCK_THROW",
  "ROCK_TOMB",
  "ROCK_WRECKER",
  "ROLLING_KICK",
  "SACRED_FIRE",
  "SAND_TOMB",
  "SCRATCH",
  "SECRET_POWER",
  "SEED_BOMB",
  "SEED_FLARE",
  "SEISMIC_TOSS",
  "SELFDESTRUCT",
  "SHADOW_BALL",
  "SHADOW_CLAW",
  "SHADOW_PUNCH",
  "SHADOW_SNEAK",
  "SHEER_COLD",
  "SHOCK_WAVE",
  "SIGNAL_BEAM",
  "SILVER_WIND",
  "SKY_UPPERCUT",
  "SLAM",
  "SLASH",
  "SLUDGE",
  "SLUDGE_BOMB",
  "SMELLING_SALT",
  "SMOG",
  "SNORE",
  "SONIC_BOOM",
  "SPACIAL_REND",
  "SPARK",
  "SPIKE_CANNON",
  "STEEL_WING",
  "STOMP",
  "STONE_EDGE",
  "STRENGTH",
  "STRUGGLE",
  "SUBMISSION",
  "SUPERPOWER",
  "SUPER_FANG",
  "SURF",
  "SWIFT",
  "TACKLE",
  "TAKE_DOWN",
  "THIEF",
  "THUNDER",
  "THUNDERBOLT",
  "THUNDER_FANG",
  "THUNDER_PUNCH",
  "THUNDER_SHOCK",
  "TRIPLE_KICK",
  "TRI_ATTACK",
  "TRUMP_CARD",
  "TWINEEDLE",
  "TWISTER",
  "VACUUM_WAVE",
  "VICE_GRIP",
  "VINE_WHIP",
  "VITAL_THROW",
  "VOLT_TACKLE",
  "WAKE_UP_SLAP",
  "WATERFALL",
  "WATER_GUN",
  "WATER_PULSE",
  "WATER_SPOUT",
  "WEATHER_BALL",
  "WHIRLPOOL",
  "WING_ATTACK",
  "WOOD_HAMMER",
  "WRAP",
  "WRING_OUT",
  "X_SCISSOR",
  "ZAP_CANNON",
  "ZEN_HEADBUTT",
}

---@param frame table<string, unknown> move frame under execution
---@return table<string, integer> staged combat inputs for the arithmetic owner
local function combatOf(frame)
  local locals = frame.locals --[[@as table<string, unknown>]]
  local facts = locals.combat
  local level, attack, defense = REFERENCE_LEVEL, REFERENCE_ATTACK, REFERENCE_DEFENSE
  if type(facts) == "table" then
    local record = facts --[[@as table<string, unknown>]]
    if type(record.level) == "number" then
      level = record.level --[[@as integer]]
    end
    if type(record.attack) == "number" then
      attack = record.attack --[[@as integer]]
    end
    if type(record.defense) == "number" then
      defense = record.defense --[[@as integer]]
    end
  end
  return { level = level, attack = attack, defense = defense }
end

---@param stream unknown battle stream under the staged arithmetic
---@return BattleRng the stream once it proves its draw contract
local function checkStream(stream)
  assert(type(stream) == "table", "damage draws from the battle stream")
  local candidate = stream --[[@as table<string, unknown>]]
  assert(type(candidate.nextU16) == "function", "damage draws from the battle stream")
  assert(BattleRng.ALGORITHM == "gen4-lcrng", "damage draws from the native battle stream")
  return stream --[[@as BattleRng]]
end

---@param frame table<string, unknown> move frame under execution
---@return table<string, unknown> semantic cause carried by draws and strikes
local function causeFor(frame)
  return { key = frame.executingMove }
end

---@param frame table<string, unknown> move frame under execution
---@return integer user combatant owning the strike
local function userOf(frame)
  local actor = frame.actor --[[@as table<string, unknown>]]
  assert(type(actor.combatant) == "number", "damage reads its user combatant")
  return actor.combatant --[[@as integer]]
end

---@param entry unknown target entry under resolution
---@return integer defender combatant receiving the hit
local function targetOf(entry)
  assert(type(entry) == "table", "damage reads its target entries")
  local record = entry --[[@as table<string, unknown>]]
  assert(type(record.combatant) == "number", "damage targets combatants")
  return record.combatant --[[@as integer]]
end

---@param ctx BattleContext mechanics context under execution
---@param defender integer defender combatant under the hit
---@return boolean true when a marked substitute absorbed the hit
local function substituteAbsorbs(ctx, defender)
  if ctx:removeEffect(defender, "SUBSTITUTE") then
    return true
  end
  return false
end

---@param ctx BattleContext mechanics context under execution
---@param frame table<string, unknown> move frame under execution
---@param defender integer defender combatant under the hit
---@param amount integer staged damage amount under application
---@return integer damage actually dealt after application
local function applyHit(ctx, frame, defender, amount)
  local outcome = ctx:damage(defender, amount, causeFor(frame))
  return outcome.before - outcome.after
end

---@param ctx BattleContext mechanics context under execution
---@param frame table<string, unknown> move frame under execution
---@param defender integer defender combatant under the hit
---@param hitIndex integer ordinal of the hit in the sequence
---@param amount integer staged damage amount under application
local function emitStruck(ctx, frame, defender, hitIndex, amount)
  ctx:emit("struck", causeFor(frame), { target = defender, hitIndex = hitIndex, damage = amount })
end

---@param ctx BattleContext mechanics context under execution
---@param frame table<string, unknown> move frame under execution
---@param defender integer defender combatant under the protection
local function emitProtected(ctx, frame, defender)
  ctx:emit("protected", causeFor(frame), { target = defender })
end

---@param ctx BattleContext mechanics context under execution
---@param frame table<string, unknown> move frame under execution
---@param defender integer defender combatant under the miss
local function emitMissed(ctx, frame, defender)
  ctx:emit("missed", causeFor(frame), { target = defender })
end

---@param ctx BattleContext mechanics context under execution
---@param frame table<string, unknown> move frame under execution
---@param defender integer defender combatant under the strike
---@param power integer curated move power under the staged arithmetic
---@param hitIndex integer ordinal of the hit in the sequence
---@param targetCount integer sampled target count scaling the spread stage
---@return integer damage dealt by this hit
local function stagedHit(ctx, frame, defender, power, hitIndex, targetCount)
  local combat = combatOf(frame)
  local stream = checkStream(frame.stream)
  local critical = Critical.resolve(0, stream, causeFor(frame))
  local result = Damage.calculate({
    level = combat.level,
    power = power,
    attack = combat.attack,
    defense = combat.defense,
    stab = { numerator = 1, denominator = 1 },
    effectiveness = { numerator = 1, denominator = 1 },
    targetCount = targetCount,
    critical = critical.critical,
  }, stream)
  local dealt = applyHit(ctx, frame, defender, result.amount)
  emitStruck(ctx, frame, defender, hitIndex, dealt)
  return dealt
end

---@param ctx BattleContext mechanics context under execution
---@param frame table<string, unknown> move frame under execution
---@param defender integer defender combatant under the strike
---@param accuracy integer? native accuracy percentage, nil skips the roll
---@return boolean true when the strike connects
local function accuracyGate(ctx, frame, defender, accuracy)
  local stream = checkStream(frame.stream)
  local resolution
  if accuracy == nil then
    resolution = Accuracy.resolve({
      target = { kind = "combatant" },
      cause = causeFor(frame),
      protected = false,
      skipCheck = true,
    }, stream)
  else
    resolution = Accuracy.resolve({
      accuracy = accuracy,
      target = { kind = "combatant" },
      cause = causeFor(frame),
      protected = false,
    }, stream)
  end
  if resolution.kind == "hit" then
    return true
  end
  if resolution.kind == "protected" then
    emitProtected(ctx, frame, defender)
  else
    emitMissed(ctx, frame, defender)
  end
  return false
end

---@param ctx BattleContext mechanics context under execution
---@param frame table<string, unknown> move frame under execution
---@param dealt integer total damage dealt by the strike
---@param fraction string recoil fraction name under application
local function applyRecoil(ctx, frame, dealt, fraction)
  local divisor = 4
  if fraction == "third" then
    divisor = 3
  elseif fraction == "half" then
    divisor = 2
  end
  local recoil = math.floor(dealt / divisor)
  if recoil < 1 then
    recoil = 1
  end
  ctx:damage(userOf(frame), recoil, causeFor(frame))
  ctx:emit("recoil", causeFor(frame), { target = userOf(frame), damage = recoil })
end

---@param ctx BattleContext mechanics context under execution
---@param frame table<string, unknown> move frame under execution
---@param dealt integer total damage dealt by the strike
local function applyDrain(ctx, frame, dealt)
  local restored = math.floor(dealt / 2)
  if restored < 1 then
    return
  end
  ctx:heal(userOf(frame), restored, causeFor(frame))
  ctx:emit("drained", causeFor(frame), { target = userOf(frame), restored = restored })
end

---@param ctx BattleContext mechanics context under execution
---@param frame table<string, unknown> move frame under execution
---@param params table<string, unknown> curated strike parameters owning the hit
---@return table<string, unknown> terminal execution step for the strike
local function runStriker(ctx, frame, params)
  local targets = frame.targets --[[@as table<integer, unknown>]]
  local power = params.power --[[@as integer]]
  local accuracy = params.accuracy
  local connected, dealtTotal = false, 0
  for hitIndex = 1, #targets do
    local defender = targetOf(targets[hitIndex])
    if substituteAbsorbs(ctx, defender) then
      ctx:emit("substitute-broke", causeFor(frame), { target = defender, hitIndex = hitIndex })
      connected = true
    elseif
      accuracyGate(ctx, frame, defender, accuracy --[[@as integer?]])
    then
      dealtTotal = dealtTotal + stagedHit(ctx, frame, defender, power, hitIndex, #targets)
      connected = true
      if params.drain == true then
        applyDrain(ctx, frame, dealtTotal)
      end
    elseif params.crash == true then
      ctx:damage(userOf(frame), 1, causeFor(frame))
    end
    local health = ctx:damage(defender, 0, causeFor(frame))
    if health.after == 0 then
      break
    end
  end
  if params.recoil ~= nil and dealtTotal > 0 then
    applyRecoil(ctx, frame, dealtTotal, params.recoil --[[@as string]])
  end
  if params.selfKo == true then
    ctx:damage(userOf(frame), 999999, causeFor(frame))
    ctx:emit("fainted", causeFor(frame), { target = userOf(frame) })
  end
  if not connected then
    return { kind = "complete", result = "missed" }
  end
  return { kind = "complete", result = "hit" }
end

---@param params table<string, unknown> curated strike parameters owning the hit
---@return fun(ctx: BattleContext, frame: table<string, unknown>): table<string, unknown> step handler running the strike
local function makeStriker(params)
  local function stepStrike(ctx, frame)
    assert(type(ctx) == "table", "damage steps through the battle context")
    assert(type(frame) == "table", "damage steps from its move frame")
    return runStriker(ctx, frame --[[@as table<string, unknown>]], params)
  end
  return stepStrike
end

---@param handler fun(ctx: BattleContext, frame: table<string, unknown>): table<string, unknown> shared family body under binding
---@return fun(ctx: BattleContext, frame: table<string, unknown>): table<string, unknown> distinct per-move binding over the shared body
local function bind(handler)
  local function stepBound(ctx, frame)
    return handler(ctx, frame)
  end
  return stepBound
end

local function stepCanonical(ctx, frame)
  assert(type(ctx) == "table", "damage steps through the battle context")
  assert(type(frame) == "table", "damage steps from its move frame")
  local record = frame --[[@as table<string, unknown>]]
  ctx:emit("move-used", causeFor(record), {
    targets = #record.targets,
  })
  return { kind = "complete", result = "hit" }
end

local function stepGated(ctx, frame)
  assert(type(ctx) == "table", "damage steps through the battle context")
  assert(type(frame) == "table", "damage steps from its move frame")
  return { kind = "complete", result = "failed" }
end

---@param ctx BattleContext mechanics context under execution
---@param frame table<string, unknown> move frame under execution
---@param amount integer fixed damage amount under application
---@return table<string, unknown> terminal execution step for the fixed strike
local function runFixed(ctx, frame, amount)
  local record = frame --[[@as table<string, unknown>]]
  local stream = checkStream(record.stream)
  local result = Damage.fixed({ amount = amount }, stream)
  local targets = record.targets --[[@as table<integer, unknown>]]
  for hitIndex = 1, #targets do
    local defender = targetOf(targets[hitIndex])
    if not substituteAbsorbs(ctx, defender) then
      local dealt = applyHit(ctx, record, defender, result.amount)
      emitStruck(ctx, record, defender, hitIndex, dealt)
    end
  end
  return { kind = "complete", result = "hit" }
end

---@param amount integer fixed damage amount under the handler
---@return fun(ctx: BattleContext, frame: table<string, unknown>): table<string, unknown> step handler dealing the fixed strike
local function makeFixed(amount)
  local function stepFixed(ctx, frame)
    assert(type(ctx) == "table", "damage steps through the battle context")
    assert(type(frame) == "table", "damage steps from its move frame")
    return runFixed(ctx, frame --[[@as table<string, unknown>]], amount)
  end
  return stepFixed
end

local function stepSuperFang(ctx, frame)
  assert(type(ctx) == "table", "damage steps through the battle context")
  assert(type(frame) == "table", "damage steps from its move frame")
  local record = frame --[[@as table<string, unknown>]]
  local targets = record.targets --[[@as table<integer, unknown>]]
  for hitIndex = 1, #targets do
    local defender = targetOf(targets[hitIndex])
    if not substituteAbsorbs(ctx, defender) then
      local probe = ctx:damage(defender, 0, causeFor(record))
      local amount = math.floor(probe.before / 2)
      if amount < 1 then
        amount = 1
      end
      local dealt = applyHit(ctx, record, defender, amount)
      emitStruck(ctx, record, defender, hitIndex, dealt)
    end
  end
  return { kind = "complete", result = "hit" }
end

local function stepEndeavor(ctx, frame)
  assert(type(ctx) == "table", "damage steps through the battle context")
  assert(type(frame) == "table", "damage steps from its move frame")
  local record = frame --[[@as table<string, unknown>]]
  local user = userOf(record)
  local targets = record.targets --[[@as table<integer, unknown>]]
  local userHealth = ctx:damage(user, 0, causeFor(record))
  local defender = targetOf(targets[1])
  local foeHealth = ctx:damage(defender, 0, causeFor(record))
  if userHealth.before >= foeHealth.before then
    return { kind = "complete", result = "failed" }
  end
  local dealt = applyHit(ctx, record, defender, foeHealth.before - userHealth.before)
  emitStruck(ctx, record, defender, 1, dealt)
  return { kind = "complete", result = "hit" }
end

---@param ctx BattleContext mechanics context under execution
---@param frame table<string, unknown> move frame under execution
---@param power integer friendship-derived power under the staged arithmetic
---@return table<string, unknown> terminal execution step for the strike
local function runFriendship(ctx, frame, power)
  local record = frame --[[@as table<string, unknown>]]
  local stream = checkStream(record.stream)
  local query = {
    accuracy = 100,
    target = { kind = "combatant" },
    cause = causeFor(record),
    protected = false,
  }
  local targets = record.targets --[[@as table<integer, unknown>]]
  local connected = false
  for hitIndex = 1, #targets do
    local defender = targetOf(targets[hitIndex])
    if not substituteAbsorbs(ctx, defender) then
      local resolution = Accuracy.resolve(query, stream)
      if resolution.kind == "hit" then
        connected = true
        stagedHit(ctx, record, defender, power, hitIndex, #targets)
      else
        emitMissed(ctx, record, defender)
      end
    end
  end
  if not connected then
    return { kind = "complete", result = "missed" }
  end
  return { kind = "complete", result = "hit" }
end

---@param sense string friendship sense under derivation, "return" or "frustration"
---@return fun(ctx: BattleContext, frame: table<string, unknown>): table<string, unknown> step handler deriving power from friendship
local function makeFriendship(sense)
  local function stepFriendship(ctx, frame)
    assert(type(ctx) == "table", "damage steps through the battle context")
    assert(type(frame) == "table", "damage steps from its move frame")
    local record = frame --[[@as table<string, unknown>]]
    local locals = record.locals --[[@as table<string, unknown>]]
    local friendship = locals.friendship
    assert(type(friendship) == "number", "friendship moves read their friendship fact")
    local base = friendship --[[@as integer]]
    if sense == "frustration" then
      base = 255 - base
    end
    local power = math.floor((base * 10) / 25)
    if power < 1 then
      power = 1
    end
    return runFriendship(ctx, record, power)
  end
  return stepFriendship
end

local function stepMagnitude(ctx, frame)
  assert(type(ctx) == "table", "damage steps through the battle context")
  assert(type(frame) == "table", "damage steps from its move frame")
  local record = frame --[[@as table<string, unknown>]]
  local stream = checkStream(record.stream)
  local roll = stream:nextU16("magnitude", causeFor(record)) % 100
  local ladder = { 10, 30, 50, 70, 90, 110, 150 }
  local edges = { 5, 15, 35, 65, 85, 95, 100 }
  local power = ladder[#ladder]
  for index, edge in ipairs(edges) do
    if roll < edge then
      power = ladder[index]
      break
    end
  end
  return runStriker(ctx, record, { power = power })
end

local function stepBeatUp(ctx, frame)
  assert(type(ctx) == "table", "damage steps through the battle context")
  assert(type(frame) == "table", "damage steps from its move frame")
  local record = frame --[[@as table<string, unknown>]]
  local stream = checkStream(record.stream)
  local hits = 2 + (stream:nextU16("multi-hit-count", causeFor(record)) % 3)
  local targets = record.targets --[[@as table<integer, unknown>]]
  for hitIndex = 1, hits do
    local defender = targetOf(targets[((hitIndex - 1) % #targets) + 1])
    if substituteAbsorbs(ctx, defender) then
      ctx:emit("substitute-broke", causeFor(record), { target = defender, hitIndex = hitIndex })
    else
      local query = {
        accuracy = 100,
        target = { kind = "combatant" },
        cause = causeFor(record),
        protected = false,
      }
      local resolution = Accuracy.resolve(query, stream)
      if resolution.kind == "hit" then
        stagedHit(ctx, record, defender, 10, hitIndex, #targets)
      else
        emitMissed(ctx, record, defender)
      end
    end
    if (ctx:damage(defender, 0, causeFor(record))).after == 0 then
      break
    end
  end
  return { kind = "complete", result = "hit" }
end

---@param ctx BattleContext mechanics context under execution
---@param frame table<string, unknown> move frame under execution
---@param hits integer sampled hit count under the sequence
---@return table<string, unknown> terminal execution step for the sampled sequence
local function runSampledHits(ctx, frame, hits)
  local record = frame --[[@as table<string, unknown>]]
  local targets = record.targets --[[@as table<integer, unknown>]]
  for hitIndex = 1, hits do
    local defender = targetOf(targets[((hitIndex - 1) % #targets) + 1])
    ctx:emit("hit", causeFor(record), { target = defender, hitIndex = hitIndex, hits = hits })
  end
  return { kind = "complete", result = "hit" }
end

---@return fun(ctx: BattleContext, frame: table<string, unknown>): table<string, unknown> step handler sampling a two-to-five-hit sequence
local function makeSampledHits()
  local function stepSampled(ctx, frame)
    assert(type(ctx) == "table", "damage steps through the battle context")
    assert(type(frame) == "table", "damage steps from its move frame")
    local record = frame --[[@as table<string, unknown>]]
    local stream = checkStream(record.stream)
    local hits = 2 + (stream:nextU16("multi-hit-count", causeFor(record)) % 4)
    return runSampledHits(ctx, record, hits)
  end
  return stepSampled
end

local function stepLevelFixed(ctx, frame)
  assert(type(ctx) == "table", "damage steps through the battle context")
  assert(type(frame) == "table", "damage steps from its move frame")
  local record = frame --[[@as table<string, unknown>]]
  local locals = record.locals --[[@as table<string, unknown>]]
  local combat = locals.combat
  if
    type(combat) ~= "table" or type((combat --[[@as table<string, unknown>]]).level) ~= "number"
  then
    return { kind = "complete", result = "failed" }
  end
  return runFixed(ctx, record, (combat --[[@as table<string, unknown>]]).level --[[@as integer]])
end

local function stepWeight(ctx, frame)
  assert(type(ctx) == "table", "damage steps through the battle context")
  assert(type(frame) == "table", "damage steps from its move frame")
  local record = frame --[[@as table<string, unknown>]]
  local locals = record.locals --[[@as table<string, unknown>]]
  local combat = locals.combat
  if
    type(combat) ~= "table" or type((combat --[[@as table<string, unknown>]]).weightKg) ~= "number"
  then
    return { kind = "complete", result = "failed" }
  end
  local weight = (combat --[[@as table<string, unknown>]]).weightKg --[[@as number]]
  local power = 120
  if weight <= 10 then
    power = 20
  elseif weight <= 25 then
    power = 40
  elseif weight <= 50 then
    power = 60
  elseif weight <= 100 then
    power = 80
  elseif weight <= 200 then
    power = 100
  end
  return runStriker(ctx, record, { power = power })
end

---@param key string damage move identity under binding
---@return fun(ctx: BattleContext, frame: table<string, unknown>): table<string, unknown> distinct per-move handler for the registry
local function bodyFor(key)
  if key == "BEAT_UP" then
    return bind(stepBeatUp)
  end
  if key == "FRUSTRATION" then
    return bind(makeFriendship("frustration"))
  end
  if key == "RETURN" then
    return bind(makeFriendship("return"))
  end
  if key == "MAGNITUDE" then
    return bind(stepMagnitude)
  end
  if key == "SUPER_FANG" then
    return bind(stepSuperFang)
  end
  if key == "ENDEAVOR" then
    return bind(stepEndeavor)
  end
  if FIXED[key] ~= nil then
    return bind(makeFixed(FIXED[key]))
  end
  if LEVEL_FIXED[key] == true then
    return bind(stepLevelFixed)
  end
  if WEIGHT[key] == true then
    return bind(stepWeight)
  end
  if OHKO[key] == true or GATED[key] == true then
    return bind(stepGated)
  end
  if MULTI_25[key] == true then
    return bind(makeSampledHits())
  end
  if STRIKERS[key] ~= nil then
    return bind(makeStriker(STRIKERS[key]))
  end
  return bind(stepCanonical)
end

--- Binds the damage family handlers into the owner table.
---@param owned table<string, fun(ctx: BattleContext, frame: table<string, unknown>): table<string, unknown>> handler owner receiving the family bindings
function DamageMoves.register(owned)
  assert(type(owned) == "table", "damage moves register into their owner table")
  for _, key in ipairs(DamageMoves.MEMBERS) do
    owned[key] = bodyFor(key)
  end
end

return DamageMoves
