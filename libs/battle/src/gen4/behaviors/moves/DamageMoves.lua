-- Direct, fixed, and variable damage families: ordinary strikes, fixed and
-- level damage, one-hit knockouts, counter-style reactions, variable
-- power, and multi-hit sequences. Every member binds its own handler, so
-- moves with disjoint mechanics never share one function; members without
-- modeled native semantics fail explicitly instead of emitting fabricated
-- damage, accuracy, or secondary effects. Curated members carry only their
-- move-specific control rules beside their bodies: strike power and
-- accuracy always arrive in the frame move facts, and combat facts always
-- arrive as real battle-owned projections. Damage arithmetic always
-- travels the staged owner, and per-hit draws, faint stops, and substitute
-- breaks follow source order. Source references:
-- src/battle/battle_command.c and src/battle/overlay_12_0224E4FC.c.

local Accuracy = require("libs.battle.src.gen4.Accuracy")
local BattleErrors = require("libs.battle.src.errors")
local BattleRng = require("libs.battle.src.gen4.BattleRng")
local Critical = require("libs.battle.src.gen4.Critical")
local Damage = require("libs.battle.src.gen4.Damage")
local NativeEffectHandlers = require("libs.battle.src.gen4.behaviors.effects.NativeEffectHandlers")
local StatStages = require("libs.battle.src.gen4.StatStages")
local StagedTypeModifiers = require("libs.battle.src.gen4.behaviors.moves.StagedTypeModifiers")
local TypeEffectiveness = require("libs.battle.src.gen4.TypeEffectiveness")

---@class DamageMoves
local DamageMoves = {}

-- Per-move strike controls beside their bodies: recoil names its
-- fraction, crash marks the miss backlash, selfKo marks the user faint,
-- drain restores half the damage dealt, critStage raises the native
-- critical stage, hits fixes the hit count, and leaveOne caps damage so
-- the target survives with at least one health point. Chance-based
-- secondaries roll the compiled effect chance unless the entry names its
-- own chance: status applies a major condition, volatile marks
-- flinch/confusion/binding presence, foeStages and selfStages move
-- stages, randomStatus draws one condition from its list, and thawSelf
-- cures the user freeze. Strike power, accuracy, and effect chance
-- always arrive in the frame move facts, so nothing here duplicates
-- them. Source references: the move effect scripts in
-- files/battledata/script/effect_script (secondary flags, hit counts,
-- and thaw rules), the secondary subscripts in
-- files/battledata/script/subscript (gating, durations, and fractions),
-- BtlCmd_CheckEffectActivation in src/battle/battle_command.c (the
-- percent roll), BtlCmd_ChangeStatStage (secondary stage gating), and
-- TryCriticalHit in src/battle/overlay_12_0224E4FC.c (critical stages).
local STRIKERS = {
  TACKLE = {},
  JUMP_KICK = { crash = true },
  HI_JUMP_KICK = { crash = true },
  TAKE_DOWN = { recoil = "quarter" },
  DOUBLE_EDGE = { recoil = "quarter" },
  SUBMISSION = { recoil = "quarter" },
  BRAVE_BIRD = { recoil = "third" },
  FLARE_BLITZ = { recoil = "third" },
  VOLT_TACKLE = { recoil = "third" },
  WOOD_HAMMER = { recoil = "third" },
  HEAD_SMASH = { recoil = "half" },
  STRUGGLE = { recoil = "quarter" },
  EXPLOSION = { selfKo = true },
  SELFDESTRUCT = { selfKo = true },
  FAINT_ATTACK = {},
  SWIFT = {},
  AERIAL_ACE = {},
  SHADOW_PUNCH = {},
  MAGNET_BOMB = {},
  AURA_SPHERE = {},
  SHOCK_WAVE = {},
  MAGICAL_LEAF = {},
  MACH_PUNCH = {},
  QUICK_ATTACK = {},
  ICE_SHARD = {},
  AQUA_JET = {},
  BULLET_PUNCH = {},
  SHADOW_SNEAK = {},
  VACUUM_WAVE = {},
  EXTREME_SPEED = {},
  VITAL_THROW = {},
  RAPID_SPIN = {},
  FOCUS_PUNCH = {},
  DREAM_EATER = {},
  -- Ordinary trainer strikes with a plain damage secondary identity.
  AQUA_TAIL = {},
  CUT = {},
  DRAGON_CLAW = {},
  DRILL_PECK = {},
  EGG_BOMB = {},
  HORN_ATTACK = {},
  MEGAHORN = {},
  MEGA_KICK = {},
  MEGA_PUNCH = {},
  PECK = {},
  POUND = {},
  POWER_WHIP = {},
  ROCK_THROW = {},
  SCRATCH = {},
  SEED_BOMB = {},
  SLAM = {},
  STRENGTH = {},
  VICE_GRIP = {},
  VINE_WHIP = {},
  WING_ATTACK = {},
  X_SCISSOR = {},
  DRAGON_PULSE = {},
  HYDRO_PUMP = {},
  POWER_GEM = {},
  WATER_GUN = {},
  -- Semi-invulnerable doubling has no state to key on: charge strikes
  -- resolve in one step, so these land their plain base.
  GUST = {},
  EARTHQUAKE = {},
  SURF = {},
  -- Draining trainer strikes.
  ABSORB = { drain = true },
  GIGA_DRAIN = { drain = true },
  MEGA_DRAIN = { drain = true },
  DRAIN_PUNCH = { drain = true },
  LEECH_LIFE = { drain = true },
  -- Raised critical strikes roll one native stage above the base.
  ATTACK_ORDER = { critStage = 1 },
  CRABHAMMER = { critStage = 1 },
  CROSS_CHOP = { critStage = 1 },
  KARATE_CHOP = { critStage = 1 },
  LEAF_BLADE = { critStage = 1 },
  NIGHT_SLASH = { critStage = 1 },
  PSYCHO_CUT = { critStage = 1 },
  RAZOR_LEAF = { critStage = 1 },
  SHADOW_CLAW = { critStage = 1 },
  SLASH = { critStage = 1 },
  STONE_EDGE = { critStage = 1 },
  AIR_CUTTER = { critStage = 1 },
  BLAZE_KICK = { critStage = 1, secondaries = { { status = "burn" } } },
  CROSS_POISON = { critStage = 1, secondaries = { { status = "poison" } } },
  -- Burn secondaries.
  EMBER = { secondaries = { { status = "burn" } } },
  FIRE_BLAST = { secondaries = { { status = "burn" } } },
  FLAMETHROWER = { secondaries = { { status = "burn" } } },
  HEAT_WAVE = { secondaries = { { status = "burn" } } },
  FIRE_PUNCH = { secondaries = { { status = "burn" } } },
  LAVA_PLUME = { secondaries = { { status = "burn" } } },
  FLAME_WHEEL = { secondaries = { { thawSelf = true, chance = 100 }, { status = "burn" } } },
  -- Freeze secondaries.
  ICE_BEAM = { secondaries = { { status = "freeze" } } },
  ICE_PUNCH = { secondaries = { { status = "freeze" } } },
  -- Paralysis secondaries.
  BODY_SLAM = { secondaries = { { status = "paralysis" } } },
  FORCE_PALM = { secondaries = { { status = "paralysis" } } },
  LICK = { secondaries = { { status = "paralysis" } } },
  SPARK = { secondaries = { { status = "paralysis" } } },
  THUNDERBOLT = { secondaries = { { status = "paralysis" } } },
  THUNDER_SHOCK = { secondaries = { { status = "paralysis" } } },
  THUNDER_PUNCH = { secondaries = { { status = "paralysis" } } },
  DISCHARGE = { secondaries = { { status = "paralysis" } } },
  DRAGON_BREATH = { secondaries = { { status = "paralysis" } } },
  ZAP_CANNON = { secondaries = { { status = "paralysis" } } },
  -- Poison secondaries, including the badly-poisoning fang.
  GUNK_SHOT = { secondaries = { { status = "poison" } } },
  POISON_JAB = { secondaries = { { status = "poison" } } },
  POISON_STING = { secondaries = { { status = "poison" } } },
  SLUDGE = { secondaries = { { status = "poison" } } },
  SLUDGE_BOMB = { secondaries = { { status = "poison" } } },
  SMOG = { secondaries = { { status = "poison" } } },
  POISON_FANG = { secondaries = { { status = "toxic" } } },
  -- Flinch secondaries mark before-action presence.
  ASTONISH = { secondaries = { { volatile = "flinch" } } },
  BITE = { secondaries = { { volatile = "flinch" } } },
  HEADBUTT = { secondaries = { { volatile = "flinch" } } },
  ROCK_SLIDE = { secondaries = { { volatile = "flinch" } } },
  DRAGON_RUSH = { secondaries = { { volatile = "flinch" } } },
  WATERFALL = { secondaries = { { volatile = "flinch" } } },
  ZEN_HEADBUTT = { secondaries = { { volatile = "flinch" } } },
  BONE_CLUB = { secondaries = { { volatile = "flinch" } } },
  HYPER_FANG = { secondaries = { { volatile = "flinch" } } },
  EXTRASENSORY = { secondaries = { { volatile = "flinch" } } },
  AIR_SLASH = { secondaries = { { volatile = "flinch" } } },
  DARK_PULSE = { secondaries = { { volatile = "flinch" } } },
  TWISTER = { secondaries = { { volatile = "flinch" } } },
  -- Confusion secondaries root a two-to-five-turn volatile.
  CONFUSION = { secondaries = { { volatile = "confusion" } } },
  PSYBEAM = { secondaries = { { volatile = "confusion" } } },
  SIGNAL_BEAM = { secondaries = { { volatile = "confusion" } } },
  DIZZY_PUNCH = { secondaries = { { volatile = "confusion" } } },
  WATER_PULSE = { secondaries = { { volatile = "confusion" } } },
  DYNAMIC_PUNCH = { secondaries = { { volatile = "confusion" } } },
  -- Fanged strikes roll their condition and their flinch independently.
  FIRE_FANG = { secondaries = { { status = "burn" }, { volatile = "flinch" } } },
  ICE_FANG = { secondaries = { { status = "freeze" }, { volatile = "flinch" } } },
  THUNDER_FANG = { secondaries = { { status = "paralysis" }, { volatile = "flinch" } } },
  -- Binding strikes trap for three plus zero-to-three turns.
  BIND = { secondaries = { { volatile = "trap", chance = 100 } } },
  CLAMP = { secondaries = { { volatile = "trap", chance = 100 } } },
  SAND_TOMB = { secondaries = { { volatile = "trap", chance = 100 } } },
  WRAP = { secondaries = { { volatile = "trap", chance = 100 } } },
  FIRE_SPIN = { secondaries = { { volatile = "trap", chance = 100 } } },
  WHIRLPOOL = { secondaries = { { volatile = "trap", chance = 100 } } },
  -- Fixed two-hit strikes.
  BONEMERANG = { hits = 2 },
  DOUBLE_KICK = { hits = 2 },
  -- Foe-hindering stage secondaries.
  ACID = { secondaries = { { foeStages = { { "specialDefense", -1 } } } } },
  BUG_BUZZ = { secondaries = { { foeStages = { { "specialDefense", -1 } } } } },
  EARTH_POWER = { secondaries = { { foeStages = { { "specialDefense", -1 } } } } },
  ENERGY_BALL = { secondaries = { { foeStages = { { "specialDefense", -1 } } } } },
  FLASH_CANNON = { secondaries = { { foeStages = { { "specialDefense", -1 } } } } },
  FOCUS_BLAST = { secondaries = { { foeStages = { { "specialDefense", -1 } } } } },
  PSYCHIC = { secondaries = { { foeStages = { { "specialDefense", -1 } } } } },
  SHADOW_BALL = { secondaries = { { foeStages = { { "specialDefense", -1 } } } } },
  AURORA_BEAM = { secondaries = { { foeStages = { { "attack", -1 } } } } },
  CRUNCH = { secondaries = { { foeStages = { { "defense", -1 } } } } },
  CRUSH_CLAW = { secondaries = { { foeStages = { { "defense", -1 } } } } },
  IRON_TAIL = { secondaries = { { foeStages = { { "defense", -1 } } } } },
  MIRROR_SHOT = { secondaries = { { foeStages = { { "accuracy", -1 } } } } },
  MUDDY_WATER = { secondaries = { { foeStages = { { "accuracy", -1 } } } } },
  MUD_BOMB = { secondaries = { { foeStages = { { "accuracy", -1 } } } } },
  OCTAZOOKA = { secondaries = { { foeStages = { { "accuracy", -1 } } } } },
  MUD_SLAP = { secondaries = { { foeStages = { { "accuracy", -1 } } } } },
  BUBBLE = { secondaries = { { foeStages = { { "speed", -1 } } } } },
  BUBBLE_BEAM = { secondaries = { { foeStages = { { "speed", -1 } } } } },
  CONSTRICT = { secondaries = { { foeStages = { { "speed", -1 } } } } },
  ICY_WIND = { secondaries = { { foeStages = { { "speed", -1 } } } } },
  MUD_SHOT = { secondaries = { { foeStages = { { "speed", -1 } } } } },
  ROCK_TOMB = { secondaries = { { foeStages = { { "speed", -1 } } } } },
  -- Self-raising stage secondaries.
  CHARGE_BEAM = { secondaries = { { selfStages = { { "specialAttack", 1 } } } } },
  ANCIENT_POWER = {
    secondaries = {
      {
        selfStages = {
          { "attack", 1 },
          { "defense", 1 },
          { "speed", 1 },
          { "specialAttack", 1 },
          { "specialDefense", 1 },
        },
      },
    },
  },
  OMINOUS_WIND = {
    secondaries = {
      {
        selfStages = {
          { "attack", 1 },
          { "defense", 1 },
          { "speed", 1 },
          { "specialAttack", 1 },
          { "specialDefense", 1 },
        },
      },
    },
  },
  SILVER_WIND = {
    secondaries = {
      {
        selfStages = {
          { "attack", 1 },
          { "defense", 1 },
          { "speed", 1 },
          { "specialAttack", 1 },
          { "specialDefense", 1 },
        },
      },
    },
  },
  METAL_CLAW = { secondaries = { { selfStages = { { "attack", 1 } } } } },
  METEOR_MASH = { secondaries = { { selfStages = { { "attack", 1 } } } } },
  STEEL_WING = { secondaries = { { selfStages = { { "defense", 1 } } } } },
  -- Self-hindering strikes land their drop unconditionally on a hit:
  -- the native script applies it without a chance roll.
  HAMMER_ARM = { secondaries = { { selfStages = { { "speed", -1 } }, chance = 100 } } },
  -- Tri Attack draws one of burn, freeze, or paralysis on its chance.
  TRI_ATTACK = { secondaries = { { randomStatus = { "burn", "freeze", "paralysis" } } } },
  -- Secret Power has no terrain facts in this engine, so its secondary
  -- settles as the standard-battle paralysis outcome.
  SECRET_POWER = { secondaries = { { status = "paralysis" } } },
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
  local record = frame --[[@as table<string, unknown>]]
  local key = record.executingMove --[[@as string]]
  local locals = record.locals --[[@as table<string, unknown>]]
  local facts = locals.combat
  if type(facts) ~= "table" then
    error(BattleErrors.missingBehavior("damage reads its real combat facts", { key = key, fact = "combat" }))
  end
  local combat = facts --[[@as table<string, unknown>]]
  for _, fact in ipairs({ "level", "attack", "defense" }) do
    local value = combat[fact]
    if type(value) ~= "number" or value % 1 ~= 0 or value < 1 then
      error(BattleErrors.missingBehavior("damage reads its real combat facts", { key = key, fact = fact }))
    end
  end
  return {
    level = combat.level --[[@as integer]],
    attack = combat.attack --[[@as integer]],
    defense = combat.defense --[[@as integer]],
  }
end

---@param frame table<string, unknown> move frame under execution
---@return table<string, integer> strike power and accuracy from the immutable move facts
local function strikeFactsOf(frame)
  local record = frame --[[@as table<string, unknown>]]
  local key = record.executingMove --[[@as string]]
  local locals = record.locals --[[@as table<string, unknown>]]
  local facts = locals.move
  if type(facts) ~= "table" then
    error(BattleErrors.missingBehavior("damage reads its immutable move facts", { key = key, fact = "move" }))
  end
  local move = facts --[[@as table<string, unknown>]]
  local power = move.power
  if type(power) ~= "number" or power % 1 ~= 0 or power < 1 then
    error(BattleErrors.missingBehavior("damage reads its immutable move facts", { key = key, fact = "power" }))
  end
  local accuracy = move.accuracy
  if type(accuracy) ~= "number" or accuracy % 1 ~= 0 or accuracy < 0 then
    error(BattleErrors.missingBehavior("damage reads its immutable move facts", { key = key, fact = "accuracy" }))
  end
  return {
    power = power --[[@as integer]],
    accuracy = accuracy --[[@as integer]],
  }
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
  if ctx:removeBattleEffect(defender, "substitute") then
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

-- Secondary effect gating shared by every chance-based strike
-- follow-up: fainted targets take no follow-up, chart-immune targets
-- never trigger, and a marked substitute absorbs the follow-up. Fire,
-- freeze, and poison immunities read defender types directly because
-- the battle chart models them as resistances rather than immunities.
-- Source references: the secondary subscripts in
-- files/battledata/script/subscript (burn, freeze, paralyze, poison,
-- confuse gating) and BtlCmd_ChangeStatStage in
-- src/battle/battle_command.c (substitute blocking secondary drops).
---@param ctx BattleContext mechanics context under execution
---@param frame table<string, unknown> move frame under execution
---@param defender integer defender combatant under the follow-up
---@return boolean true when secondaries may apply to the defender
local function secondariesAllowed(ctx, frame, defender)
  local record = frame --[[@as table<string, unknown>]]
  local health = ctx:damage(defender, 0, causeFor(record))
  if health.after <= 0 then
    return false
  end
  local locals = record.locals --[[@as table<string, unknown>]]
  local move = locals.move --[[@as table<string, unknown>]]
  local moveType = move.moveType --[[@as string]]
  local defenders = locals.defenderTypes --[[@as table<integer, unknown>]]
  local defenderTypes = defenders[defender] --[[@as string[] ]]
  local resolved = TypeEffectiveness.resolve(
    locals.typeChart --[[@as table<string, unknown>]],
    moveType --[[@as string]],
    defenderTypes,
    {}
  )
  if resolved.immune then
    return false
  end
  if ctx:hasBattleEffect(defender, "substitute") then
    return false
  end
  return true
end

---@param defenderTypes string[] semantic defender types under the immunity check
---@param status string major condition under the immunity check
---@return boolean true when the defender type blocks the condition
local function statusTypeImmune(defenderTypes, status)
  for _, defenderType in ipairs(defenderTypes) do
    if status == "burn" and defenderType == "fire" then
      return true
    end
    if status == "freeze" and defenderType == "ice" then
      return true
    end
    if (status == "poison" or status == "toxic") and (defenderType == "poison" or defenderType == "steel") then
      return true
    end
  end
  return false
end

---@param frame table<string, unknown> move frame under execution
---@return integer compiled effect chance for the secondary roll
local function secondaryChanceOf(frame)
  local record = frame --[[@as table<string, unknown>]]
  local locals = record.locals --[[@as table<string, unknown>]]
  local move = locals.move --[[@as table<string, unknown>]]
  local chance = move.effectChance
  if type(chance) ~= "number" or chance % 1 ~= 0 or chance < 0 then
    error(BattleErrors.missingBehavior("secondaries read their compiled effect chance", {
      key = record.executingMove --[[@as string]],
    }))
  end
  return chance --[[@as integer]]
end

---@param stream unknown battle stream under the secondary roll
---@return BattleRng the stream once it proves its draw contract
local function checkSecondaryStream(stream)
  assert(type(stream) == "table", "secondaries draw from the battle stream")
  local candidate = stream --[[@as table<string, unknown>]]
  assert(type(candidate.nextU16) == "function", "secondaries draw from the battle stream")
  assert(BattleRng.ALGORITHM == "gen4-lcrng", "secondaries draw from the native battle stream")
  return stream --[[@as BattleRng]]
end

-- Safeguard and mist gates for secondaries: safeguard absorbs
-- conditions and confusion on the defender side, while mist absorbs
-- foe-targeted stage drops. Source references: the condition
-- subscripts in files/battledata/script/subscript and
-- BtlCmd_ChangeStatStage in src/battle/battle_command.c.
---@param ctx BattleContext mechanics context under execution
---@param defender integer defender combatant under the gate
---@return boolean true when safeguard covers the defender side
local function safeguarded(ctx, defender)
  return ctx:sideEffect(ctx:entryOf(defender).side, "safeguard") ~= nil
end

---@param ctx BattleContext mechanics context under execution
---@param defender integer defender combatant under the gate
---@return boolean true when mist covers the defender side
local function misted(ctx, defender)
  return ctx:sideEffect(ctx:entryOf(defender).side, "mist") ~= nil
end

---@param ctx BattleContext mechanics context under execution
---@param frame table<string, unknown> move frame under execution
---@param defender integer defender combatant under the condition
---@param status string native major condition under application
local function applySecondaryStatus(ctx, frame, defender, status)
  if safeguarded(ctx, defender) then
    return
  end
  local record = frame --[[@as table<string, unknown>]]
  local state = {}
  if status == "toxic" then
    state = { counter = 0 }
  end
  ctx:applyStatus(defender, status, state, causeFor(record))
end

---@param ctx BattleContext mechanics context under execution
---@param combatant integer combatant owning the entry under the scope
---@return table<string, unknown> active owner scope pinned to the live entry
local function secondaryScope(ctx, combatant)
  local entry = ctx:entryOf(combatant)
  if entry.activation == nil then
    error(BattleErrors.invalidState("battle-local secondaries scope to a live entry", { combatant = combatant }))
  end
  return { kind = "active", combatant = combatant, activation = entry.activation }
end

---@param ctx BattleContext mechanics context under execution
---@param defender integer defender combatant under the volatile
local function markSecondaryFlinch(ctx, defender)
  ctx:addBattleEffect(
    NativeEffectHandlers.definitionFor("flinch"),
    secondaryScope(ctx, defender),
    { kind = "move", combatant = defender },
    { version = 1, turns = 1 }
  )
end

---@param ctx BattleContext mechanics context under execution
---@param frame table<string, unknown> move frame under execution
---@param defender integer defender combatant under the volatile
local function markSecondaryConfusion(ctx, frame, defender)
  if ctx:hasBattleEffect(defender, "confusion") then
    return
  end
  if safeguarded(ctx, defender) then
    return
  end
  local stream = checkSecondaryStream(frame.stream)
  local turns = 2 + (stream:nextU16("confusion_turns", causeFor(frame)) % 4)
  ctx:addBattleEffect(
    NativeEffectHandlers.definitionFor("confusion"),
    secondaryScope(ctx, defender),
    { kind = "move", combatant = userOf(frame) },
    { version = 1, turns = turns }
  )
end

---@param ctx BattleContext mechanics context under execution
---@param frame table<string, unknown> move frame under execution
---@param defender integer defender combatant under the volatile
local function markSecondaryTrap(ctx, frame, defender)
  if ctx:hasBattleEffect(defender, "bind") then
    return
  end
  local stream = checkSecondaryStream(frame.stream)
  local turns = 3 + (stream:nextU16("bind_turns", causeFor(frame)) % 4)
  ctx:addBattleEffect(
    NativeEffectHandlers.definitionFor("bind"),
    secondaryScope(ctx, defender),
    { kind = "move", combatant = userOf(frame) },
    { version = 1, turns = turns }
  )
end

---@param ctx BattleContext mechanics context under execution
---@param frame table<string, unknown> move frame under execution
---@param target integer combatant owning the stages under the change
---@param changes table<integer, table<integer, unknown>> stat/delta pairs under the change
local function applySecondaryStages(ctx, frame, target, changes)
  local current = ctx:entryOf(target).stages --[[@as table<string, integer>]]
  for _, change in ipairs(changes) do
    local stat = change[1] --[[@as string]]
    local delta = change[2] --[[@as integer]]
    local next = StatStages.change(current[stat] --[[@as integer]], delta)
    if next ~= current[stat] then
      ctx:changeStage(target, stat, next, causeFor(frame))
      current[stat] = next
    end
  end
end

---@param ctx BattleContext mechanics context under execution
---@param frame table<string, unknown> move frame under execution
---@param defender integer defender combatant under the follow-up
---@param spec table<string, unknown> single secondary specification under the roll
local function applySecondary(ctx, frame, defender, spec)
  local record = frame --[[@as table<string, unknown>]]
  local locals = record.locals --[[@as table<string, unknown>]]
  local chance = spec.chance
  if type(chance) ~= "number" then
    chance = secondaryChanceOf(frame)
  end
  local stream = checkSecondaryStream(frame.stream)
  if
    (stream:nextU16("secondary_effect", causeFor(frame)) % 100) >= chance --[[@as integer]]
  then
    return
  end
  if spec.thawSelf == true then
    ctx:cureStatus(userOf(frame), "freeze", causeFor(frame))
    return
  end
  if type(spec.randomStatus) == "table" then
    local options = spec.randomStatus --[[@as table<integer, string>]]
    local picked = options[(stream:nextU16("secondary_effect", causeFor(frame)) % #options) + 1]
    applySecondaryStatus(ctx, frame, defender, picked --[[@as string]])
    return
  end
  if type(spec.status) == "string" then
    local defenders = locals.defenderTypes --[[@as table<integer, unknown>]]
    local defenderTypes = defenders[defender] --[[@as string[] ]]
    if
      not statusTypeImmune(defenderTypes, spec.status --[[@as string]])
    then
      applySecondaryStatus(ctx, frame, defender, spec.status --[[@as string]])
    end
    return
  end
  if type(spec.foeStages) == "table" then
    if not misted(ctx, defender) then
      applySecondaryStages(ctx, frame, defender, spec.foeStages --[[@as table<integer, table<integer, unknown>>]])
    end
    return
  end
  if type(spec.selfStages) == "table" then
    applySecondaryStages(ctx, frame, userOf(frame), spec.selfStages --[[@as table<integer, table<integer, unknown>>]])
    return
  end
  if spec.volatile == "flinch" then
    markSecondaryFlinch(ctx, defender)
    return
  end
  if spec.volatile == "confusion" then
    markSecondaryConfusion(ctx, frame, defender)
    return
  end
  if spec.volatile == "trap" then
    markSecondaryTrap(ctx, frame, defender)
    return
  end
  error(BattleErrors.missingBehavior("secondaries name a modeled follow-up", {
    key = record.executingMove --[[@as string]],
  }))
end

---@param ctx BattleContext mechanics context under execution
---@param frame table<string, unknown> move frame under execution
---@param defender integer defender combatant under the follow-ups
---@param secondaries table<integer, table<string, unknown>>|nil secondary specifications under the rolls
local function applySecondaries(ctx, frame, defender, secondaries)
  if type(secondaries) ~= "table" then
    return
  end
  if not secondariesAllowed(ctx, frame, defender) then
    return
  end
  for _, spec in ipairs(secondaries) do
    applySecondary(ctx, frame, defender, spec --[[@as table<string, unknown>]])
  end
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

-- Native critical stages for one strike: the curated move bonus plus two
-- for a focused user, suppressed entirely under a lucky chant. Stages
-- follow TryCriticalHit in src/battle/overlay_12_0224E4FC.c, where focus
-- energy contributes two, raised moves contribute one, and the chant
-- blocks the roll on the defender side.
---@param ctx BattleContext mechanics context under execution
---@param frame table<string, unknown> move frame under execution
---@param user integer user combatant owning the strike
---@param defender integer defender combatant under the strike
---@param params table<string, unknown>? curated strike controls owning the hit
---@param stream BattleRng battle stream owned by the caller
---@return CriticalResult staged critical outcome for the strike
local function strikeCritical(ctx, frame, user, defender, params, stream)
  local controls = params or {}
  if ctx:hasBattleEffect(defender, "luckychant") then
    return { critical = false, stage = 0, threshold = Critical.THRESHOLDS[0] }
  end
  local stage = controls.critStage or 0
  if ctx:hasBattleEffect(user, "focusenergy") then
    stage = stage --[[@as integer]] + 2
  end
  return Critical.resolve(stage --[[@as integer]], stream, causeFor(frame))
end

---@param ctx BattleContext mechanics context under execution
---@param frame table<string, unknown> move frame under execution
---@param defender integer defender combatant under the strike
---@param power integer curated move power under the staged arithmetic
---@param hitIndex integer ordinal of the hit in the sequence
---@param targetCount integer sampled target count scaling the spread stage
---@param params table<string, unknown>? curated strike controls owning the hit
---@return integer damage dealt by this hit
local function stagedHit(ctx, frame, defender, power, hitIndex, targetCount, params)
  local controls = params or {}
  local combat = combatOf(frame)
  local stream = checkStream(frame.stream)
  local critical = strikeCritical(ctx, frame, userOf(frame), defender, params, stream)
  local record = frame --[[@as table<string, unknown>]]
  local locals = record.locals --[[@as table<string, unknown>]]
  local stab, effectiveness = StagedTypeModifiers.forStrike(frame, defender, {
    airborne = ctx:hasBattleEffect(defender, "magnetrise"),
    foresight = ctx:hasBattleEffect(defender, "foresight"),
    gravity = locals.gravity == true,
  })
  local result = Damage.calculate({
    level = combat.level,
    power = power,
    attack = combat.attack,
    defense = combat.defense,
    stab = stab,
    effectiveness = effectiveness,
    targetCount = targetCount,
    critical = critical.critical,
  }, stream)
  local amount = result.amount
  if controls.leaveOne == true then
    local remaining = ctx:damage(defender, 0, causeFor(frame)).before
    if amount >= remaining then
      amount = remaining - 1
      if amount < 0 then
        amount = 0
      end
    end
  end
  local dealt = applyHit(ctx, frame, defender, amount)
  emitStruck(ctx, frame, defender, hitIndex, dealt)
  return dealt
end

---@param ctx BattleContext mechanics context under execution
---@param frame table<string, unknown> move frame under execution
---@param defender integer defender combatant under the strike
---@param accuracy integer native accuracy percentage, 0 skips the roll
---@return boolean true when the strike connects
-- Strike accuracy through the native checkpoints: a locked-on target
-- is always struck, identified targets ignore negative evasion, and
-- gravity scales every accuracy by five thirds. Source references:
-- BattleSystem_CheckMoveHit in
-- src/battle/battle_controller_player.c (lock-on bypass, foresight
-- evasion clamp, gravity scaling).
local function accuracyGate(ctx, frame, defender, accuracy)
  local stream = checkStream(frame.stream)
  local userStages = ctx:entryOf(userOf(frame)).stages --[[@as table<string, integer>]]
  local targetStages = ctx:entryOf(defender).stages --[[@as table<string, integer>]]
  local evasionStage = targetStages.evasion
  if evasionStage < 0 and ctx:hasBattleEffect(defender, "foresight") then
    evasionStage = 0
  end
  local stages = {
    accuracyStage = userStages.accuracy,
    evasionStage = evasionStage,
  }
  if ctx:hasBattleEffect(defender, "lockon") then
    accuracy = 0
  end
  local record = frame --[[@as table<string, unknown>]]
  local locals = record.locals --[[@as table<string, unknown>]]
  if locals.gravity == true and type(accuracy) == "number" and accuracy > 0 then
    accuracy = math.floor(accuracy --[[@as integer]] * 10 / 6)
  end
  local resolution
  if accuracy == nil or accuracy == 0 then
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
      accuracyStage = stages.accuracyStage,
      evasionStage = stages.evasionStage,
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

-- Sport-weakened power follows the native damage calculation: halved
-- base power for the weakened type while any entry holds the marker.
-- Source reference: the sport power halving in
-- src/battle/overlay_12_0224E4FC.c.
---@param ctx BattleContext mechanics context under execution
---@param frame table<string, unknown> move frame under execution
---@param power integer curated strike power under the weakening
---@return integer weakened strike power for the staged arithmetic
local function sportWeakenedPower(ctx, frame, power)
  local record = frame --[[@as table<string, unknown>]]
  local locals = record.locals --[[@as table<string, unknown>]]
  local move = locals.move --[[@as table<string, unknown>]]
  local moveType = move.moveType --[[@as string]]
  if moveType ~= "electric" and moveType ~= "fire" then
    return power
  end
  for _, combatant in ipairs(ctx:activeCombatants()) do
    if moveType == "electric" and ctx:hasBattleEffect(combatant, "mudsport") then
      return math.floor(power / 2)
    end
    if moveType == "fire" and ctx:hasBattleEffect(combatant, "watersport") then
      return math.floor(power / 2)
    end
  end
  return power
end

---@param ctx BattleContext mechanics context under execution
---@param frame table<string, unknown> move frame under execution
---@param params table<string, unknown> curated strike controls owning the hit; power stays
--- in the frame move facts unless a move-specific source rule overrides it
---@return table<string, unknown> terminal execution step for the strike
local function runStriker(ctx, frame, params)
  local targets = frame.targets --[[@as table<integer, unknown>]]
  local strike = strikeFactsOf(frame)
  local power = strike.power
  if params.power ~= nil then
    power = params.power --[[@as integer]]
  end
  power = sportWeakenedPower(ctx, frame, power)
  local accuracy = strike.accuracy
  if params.accuracyOverride ~= nil then
    accuracy = params.accuracyOverride --[[@as integer]]
  end
  if params.skipAccuracy == true then
    accuracy = 0
  end
  local hits = params.hits or 1
  assert(type(hits) == "number" and hits % 1 == 0 and hits >= 1, "fixed hit counts stay positive integers")
  local connected, dealtTotal = false, 0
  for hitIndex = 1, #targets do
    local defender = targetOf(targets[hitIndex])
    if substituteAbsorbs(ctx, defender) then
      ctx:emit("substitute-broke", causeFor(frame), { target = defender, hitIndex = hitIndex })
      connected = true
    elseif accuracyGate(ctx, frame, defender, accuracy) then
      for _ = 1, hits --[[@as integer]] do
        dealtTotal = dealtTotal + stagedHit(ctx, frame, defender, power, hitIndex, #targets, params)
        applySecondaries(ctx, frame, defender, params.secondaries --[[@as table<integer, table<string, unknown>>?]])
        local health = ctx:damage(defender, 0, causeFor(frame))
        if health.after == 0 then
          break
        end
      end
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
  error(BattleErrors.missingBehavior("no native damage semantics are modeled for the source identity", {
    key = record.executingMove --[[@as string]],
  }))
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

-- Pay Day scatters five coins per user level on a connecting strike;
-- the session totals the scatter into the battle payout. Source
-- reference: the pay day subscript in
-- files/battledata/script/subscript/subscript_0048_PayDay.s.
local function stepPayday(ctx, frame)
  assert(type(ctx) == "table", "damage steps through the battle context")
  assert(type(frame) == "table", "damage steps from its move frame")
  local record = frame --[[@as table<string, unknown>]]
  local outcome = runStriker(ctx, record, {})
  if outcome.result == "hit" then
    local combat = combatOf(record)
    outcome.payday = 5 * combat.level --[[@as integer]]
  end
  return outcome
end

-- Brick Break lands its strike, then drops the defender side screens
-- whether or not they softened this blow.
local function stepBrickBreak(ctx, frame)
  assert(type(ctx) == "table", "damage steps through the battle context")
  assert(type(frame) == "table", "damage steps from its move frame")
  local record = frame --[[@as table<string, unknown>]]
  local outcome = runStriker(ctx, record, {})
  if outcome.result == "hit" then
    local defender = targetOf((record.targets --[[@as table<integer, unknown>]])[1])
    ctx:removeBattleEffect(defender, "reflect")
    ctx:removeBattleEffect(defender, "lightscreen")
  end
  return outcome
end

-- Item-taking strikes deal their damage, then record the ordered item
-- intent for the inventory owners: stealing, knocking off, and
-- berry-eating settle downstream, never in the live Bag. This follows
-- the identity item-intent contract beside the shared striker.
---@param mode string item operation under the intent
---@return fun(ctx: BattleContext, frame: table<string, unknown>): table<string, unknown> step handler striking then recording
local function makeStealIntent(mode)
  local function stepStealIntent(ctx, frame)
    assert(type(ctx) == "table", "damage steps through the battle context")
    assert(type(frame) == "table", "damage steps from its move frame")
    local record = frame --[[@as table<string, unknown>]]
    local outcome = runStriker(ctx, record, {})
    if outcome.result == "hit" then
      ctx:emit("item-intent", causeFor(record), {
        target = targetOf((record.targets --[[@as table<integer, unknown>]])[1]),
        mode = mode,
      })
    end
    return outcome
  end
  return stepStealIntent
end

-- Feint only strikes a protecting target: without the protection
-- bracket the whole move fails, and with it the bracket breaks first.
-- Source reference: BtlCmd_TryFeint in src/battle/battle_command.c.
local function stepFeint(ctx, frame)
  assert(type(ctx) == "table", "damage steps through the battle context")
  assert(type(frame) == "table", "damage steps from its move frame")
  local record = frame --[[@as table<string, unknown>]]
  local defender = targetOf((record.targets --[[@as table<integer, unknown>]])[1])
  if not ctx:hasBattleEffect(defender, "PROTECT") and not ctx:hasBattleEffect(defender, "DETECT") then
    return { kind = "complete", result = "failed" }
  end
  ctx:removeBattleEffect(defender, "PROTECT")
  ctx:removeBattleEffect(defender, "DETECT")
  return runStriker(ctx, record, {})
end

-- Thunder and Blizzard share one weather-accuracy rule beside their own
-- condition secondary: rain always lands thunder and hail always lands
-- blizzard, while harsh sun halves thunder accuracy. Source references:
-- BattleSystem_CheckMoveHit and BattleSystem_CheckMoveEffect in
-- src/battle/battle_controller_player.c.
---@param params table<string, unknown> curated strike controls owning the hit
---@param rainy string field definition identity always landing the strike
---@param sunny string|nil field definition identity halving the strike
---@return fun(ctx: BattleContext, frame: table<string, unknown>): table<string, unknown> step handler striking under weather law
local function makeWeatherStrike(params, rainy, sunny)
  local function stepWeatherStrike(ctx, frame)
    assert(type(ctx) == "table", "damage steps through the battle context")
    assert(type(frame) == "table", "damage steps from its move frame")
    local record = frame --[[@as table<string, unknown>]]
    local controls = {}
    for key, value in pairs(params) do
      controls[key] = value
    end
    if ctx:fieldEffect(rainy) ~= nil then
      controls.skipAccuracy = true
    elseif sunny ~= nil and ctx:fieldEffect(sunny) ~= nil then
      controls.accuracyOverride = 50
    end
    return runStriker(ctx, record, controls)
  end
  return stepWeatherStrike
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
  if key == "PAY_DAY" then
    return bind(stepPayday)
  end
  if key == "BRICK_BREAK" then
    return bind(stepBrickBreak)
  end
  if key == "KNOCK_OFF" then
    return bind(makeStealIntent("remove"))
  end
  if key == "COVET" then
    return bind(makeStealIntent("steal"))
  end
  if key == "PLUCK" or key == "BUG_BITE" then
    return bind(makeStealIntent("eat"))
  end
  if key == "FALSE_SWIPE" then
    return bind(makeStriker({ leaveOne = true }))
  end
  if key == "FEINT" then
    return bind(stepFeint)
  end
  if key == "THUNDER" then
    return bind(makeWeatherStrike({ secondaries = { { status = "paralysis" } } }, "raindance", "sunnyday"))
  end
  if key == "BLIZZARD" then
    return bind(makeWeatherStrike({ secondaries = { { status = "freeze" } } }, "hail", nil))
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
