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
local NativePassiveBridge = require("libs.battle.src.gen4.NativePassiveBridge")
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
  -- Fixed two-hit strikes share their critical roll across both hits.
  BONEMERANG = { hits = 2, shareCritical = true },
  DOUBLE_KICK = { hits = 2, shareCritical = true },
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
  -- Close combat drops both defenses on a connecting strike.
  CLOSE_COMBAT = {
    secondaries = { { selfStages = { { "defense", -1 }, { "specialDefense", -1 } }, chance = 100 } },
  },
  -- Superpower drops the attacking pair on a connecting strike.
  SUPERPOWER = {
    secondaries = { { selfStages = { { "attack", -1 }, { "defense", -1 } }, chance = 100 } },
  },
  -- Draco meteor, leaf storm, and overheat drop special attack twice on
  -- a connecting strike.
  DRACO_METEOR = { secondaries = { { selfStages = { { "specialAttack", -2 } }, chance = 100 } } },
  LEAF_STORM = { secondaries = { { selfStages = { { "specialAttack", -2 } }, chance = 100 } } },
  OVERHEAT = { secondaries = { { selfStages = { { "specialAttack", -2 } }, chance = 100 } } },
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

-- Members with no modeled native semantics yet: the gated handler raises
-- structured missing behavior naming the move instead of dealing guessed
-- damage, so coverage can never mistake presence for semantics.
local GATED = {
  METAL_BURST = true,
  BIDE = true,
  CRUSH_GRIP = true,
  PSYWAVE = true,
  TRUMP_CARD = true,
  JUDGMENT = true,
  PUNISHMENT = true,
  SMELLING_SALT = true,
  PSYCHO_BOOST = true,
}

-- Two-to-five-hit members sample a genuine hit count, then land every
-- hit through the shared striker with one accuracy check: the first draw
-- picks two or three directly, while higher rolls draw again for two to
-- five, and skill link always strikes five times. Source references:
-- BtlCmd_SetMultiHit in src/battle/battle_command.c and the multi-hit
-- effect scripts in files/battledata/script/effect_script.
local SAMPLED_25 = {
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
  FURY_SWIPES = true,
  BARRAGE = true,
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
  -- Raw stats and signed stages travel beside the staged pair so the
  -- arithmetic owner can ignore unfavorable stages on critical hits;
  -- nothing here pre-folds that selection into a rounded scalar.
  for _, fact in ipairs({ "level", "attack", "defense", "rawAttack", "rawDefense" }) do
    local value = combat[fact]
    if type(value) ~= "number" or value % 1 ~= 0 or value < 1 then
      error(BattleErrors.missingBehavior("damage reads its real combat facts", { key = key, fact = fact }))
    end
  end
  for _, fact in ipairs({ "attackStage", "defenseStage" }) do
    local value = combat[fact]
    if type(value) ~= "number" or value % 1 ~= 0 or value < -6 or value > 6 then
      error(BattleErrors.missingBehavior("damage reads its real combat facts", { key = key, fact = fact }))
    end
  end
  return {
    level = combat.level --[[@as integer]],
    attack = combat.attack --[[@as integer]],
    defense = combat.defense --[[@as integer]],
    rawAttack = combat.rawAttack --[[@as integer]],
    rawDefense = combat.rawDefense --[[@as integer]],
    attackStage = combat.attackStage --[[@as integer]],
    defenseStage = combat.defenseStage --[[@as integer]],
  }
end

-- Strike-law facts the executor projects beside the staged pair: attacker
-- burn and resilience, active field weather with its live suppression,
-- and the striking move category and type. Every fact is validated before
-- the critical draw so a missing fact never spends stream draws.
---@param frame table<string, unknown> move frame under execution
---@param moveTypeOverride string|nil source-computed move type replacing the compiled one
---@return boolean whether the attacker carries burn
---@return boolean whether the attacker carries the resilient ability
---@return string active field weather identity
---@return boolean whether a live ability suppresses weather damage
---@return string striking move category
---@return string striking move type under weather law
---@return boolean whether the strike is the charging grass special case
local function strikeLawOf(frame, moveTypeOverride)
  local record = frame --[[@as table<string, unknown>]]
  local key = record.executingMove --[[@as string]]
  local locals = record.locals --[[@as table<string, unknown>]]
  for _, fact in ipairs({ "burned", "guts", "weather", "weatherSuppressed" }) do
    if locals[fact] == nil then
      error(BattleErrors.missingBehavior("damage reads its real combat facts", { key = key, fact = fact }))
    end
  end
  if type(locals.burned) ~= "boolean" or type(locals.guts) ~= "boolean" then
    error(BattleErrors.missingBehavior("damage reads its real combat facts", { key = key, fact = "burn" }))
  end
  if type(locals.weather) ~= "string" or locals.weather == "" or type(locals.weatherSuppressed) ~= "boolean" then
    error(BattleErrors.missingBehavior("damage reads its real combat facts", { key = key, fact = "weather" }))
  end
  local move = locals.move --[[@as table<string, unknown>]]
  if type(move) ~= "table" then
    error(BattleErrors.missingBehavior("damage reads its immutable move facts", { key = key, fact = "move" }))
  end
  local category = move.category
  if category ~= "physical" and category ~= "special" then
    error(BattleErrors.missingBehavior("damage reads its immutable move facts", { key = key, fact = "category" }))
  end
  local moveType = move.moveType
  if moveTypeOverride ~= nil then
    moveType = moveTypeOverride
  end
  if type(moveType) ~= "string" or moveType == "" then
    error(BattleErrors.missingBehavior("damage reads its immutable move facts", { key = key, fact = "moveType" }))
  end
  return locals.burned, --[[@as boolean]]
    locals.guts, --[[@as boolean]]
    locals.weather, --[[@as string]]
    locals.weatherSuppressed, --[[@as boolean]]
    category, --[[@as string]]
    moveType, --[[@as string]]
    record.executingMove == "SOLAR_BEAM"
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

-- Landed hits bill the live doll before touching health: only connecting
-- damage reaches the doll, so misses never deplete it. A surviving doll
-- keeps its decremented health, a breaking hit removes it without
-- spilling overkill into the body, and later hits in the same sequence
-- re-read the live effect and may reach the opened body.
---@param ctx BattleContext mechanics context under execution
---@param frame table<string, unknown> move frame under execution
---@param defender integer defender combatant under the hit
---@param amount integer staged damage amount under application
---@param hitIndex integer ordinal of the hit in the sequence
---@return boolean true when a live doll absorbed the hit
local function substituteTakesHit(ctx, frame, defender, amount, hitIndex)
  local outcome = ctx:updateBattleEffect(defender, NativeEffectHandlers.definitionFor("substitute"), function(state)
    local remaining = state.hp --[[@as integer]] - amount
    if remaining > 0 then
      return { version = 1, hp = remaining }
    end
    return nil
  end)
  if outcome == nil then
    return false
  end
  if outcome == "removed" then
    ctx:emit("substitute-broke", causeFor(frame), { target = defender, hitIndex = hitIndex })
  else
    emitStruck(ctx, frame, defender, hitIndex, amount)
  end
  return true
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

-- Source-law facts the session threads per strike beside the staged
-- pair: turn interaction for revenge law, stage-effective speeds, defender
-- level and abilities, holder item with throw facts, user individual
-- values, distinct-move history, defender weight, and the beat-up party.
-- Every reader fails loudly on absent facts instead of defaulting.
---@param frame table<string, unknown> move frame under execution
---@return table<string, unknown> validated turn-interaction facts for the strike
local function duelOf(frame)
  local record = frame --[[@as table<string, unknown>]]
  local key = record.executingMove --[[@as string]]
  local locals = record.locals --[[@as table<string, unknown>]]
  local duel = locals.duel
  if type(duel) ~= "table" then
    error(BattleErrors.missingBehavior("revenge law reads its turn-interaction facts", { key = key }))
  end
  local facts = duel --[[@as table<string, unknown>]]
  for _, flag in ipairs({ "foeActed", "foeHurt", "userHurt" }) do
    if type(facts[flag]) ~= "boolean" then
      error(BattleErrors.missingBehavior("revenge law reads its turn-interaction facts", { key = key, fact = flag }))
    end
  end
  for _, answer in ipairs({ "revengePhysical", "revengeSpecial" }) do
    local entry = facts[answer]
    if entry ~= nil then
      if type(entry) ~= "table" then
        error(BattleErrors.missingBehavior("revenge law reads its recorded damager", { key = key, fact = answer }))
      end
      local noted = entry --[[@as table<string, unknown>]]
      if
        type(noted.attacker) ~= "number"
        or type(noted.amount) ~= "number"
        or noted.amount % 1 ~= 0
        or noted.amount < 1
      then
        error(BattleErrors.missingBehavior("revenge law reads its recorded damager", { key = key, fact = answer }))
      end
    end
  end
  return facts
end

---@param frame table<string, unknown> move frame under execution
---@return integer user stage-effective speed under the strike
---@return integer defender stage-effective speed under the strike
local function speedsOf(frame)
  local record = frame --[[@as table<string, unknown>]]
  local key = record.executingMove --[[@as string]]
  local locals = record.locals --[[@as table<string, unknown>]]
  local speeds = locals.speeds
  if type(speeds) ~= "table" then
    error(BattleErrors.missingBehavior("weightless power reads its effective speeds", { key = key }))
  end
  local pair = speeds --[[@as table<string, unknown>]]
  for _, side in ipairs({ "user", "foe" }) do
    local value = pair[side]
    if type(value) ~= "number" or value % 1 ~= 0 or value < 0 then
      error(BattleErrors.missingBehavior("weightless power reads its effective speeds", { key = key, fact = side }))
    end
  end
  return pair.user, --[[@as integer]]
    pair.foe --[[@as integer]]
end

---@param frame table<string, unknown> move frame under execution
---@return integer defender battle level under the strike
local function foeLevelOf(frame)
  local record = frame --[[@as table<string, unknown>]]
  local key = record.executingMove --[[@as string]]
  local locals = record.locals --[[@as table<string, unknown>]]
  local level = locals.foeLevel
  if type(level) ~= "number" or level % 1 ~= 0 or level < 1 then
    error(BattleErrors.missingBehavior("knockout law reads its defender level", { key = key }))
  end
  return level --[[@as integer]]
end

---@param frame table<string, unknown> move frame under execution
---@return table<string, unknown> user and defender ability identities under the strike
local function abilitiesOf(frame)
  local record = frame --[[@as table<string, unknown>]]
  local key = record.executingMove --[[@as string]]
  local locals = record.locals --[[@as table<string, unknown>]]
  local abilities = locals.abilities
  if type(abilities) ~= "table" then
    error(BattleErrors.missingBehavior("ability gates read their battle abilities", { key = key }))
  end
  return abilities --[[@as table<string, unknown>]]
end

---@param frame table<string, unknown> move frame under execution
---@return string? holder item key under the strike, nil when empty-handed
local function heldItemOf(frame)
  local record = frame --[[@as table<string, unknown>]]
  local locals = record.locals --[[@as table<string, unknown>]]
  local held = locals.heldItem
  if held == nil then
    return nil
  end
  if type(held) ~= "string" or held == "" then
    error(BattleErrors.missingBehavior("throw law reads its holder item", {
      key = record.executingMove --[[@as string]],
    }))
  end
  return held --[[@as string]]
end

---@param ability unknown battle ability key carried by the strike facts
---@return string? ability key answering live checkpoints, absent for the sentinel
local function liveAbility(ability)
  if type(ability) ~= "string" or ability == "" or ability == "NONE" then
    return nil
  end
  return ability
end

---@param frame table<string, unknown> move frame under execution
---@return string? user species carried by the strike facts, absent for older frames
local function userSpeciesOf(frame)
  local record = frame --[[@as table<string, unknown>]]
  local locals = record.locals --[[@as table<string, unknown>]]
  local species = locals.userSpecies
  if species == nil then
    return nil
  end
  if type(species) ~= "string" or species == "" then
    error(BattleErrors.missingBehavior("strikes read their user species", {
      key = record.executingMove --[[@as string]],
    }))
  end
  return species --[[@as string]]
end

---@param ctx BattleContext mechanics context under execution
---@param combatant integer holder combatant under the read
---@return integer live entry token scoping the holder instances
local function activationOf(ctx, combatant)
  local entry = ctx:entryOf(combatant)
  if entry.activation == nil then
    error(BattleErrors.invalidState("live strikes scope to an entered holder", { combatant = combatant }))
  end
  return entry.activation --[[@as integer]]
end

-- Effective holding behind move-local item answers: the possessed item
-- unless the striker's own ability or an active Embargo suppresses
-- ordinary effects. Possession itself stays raw for the throw law
-- beside this read.
---@param ctx BattleContext mechanics context under execution
---@param frame table<string, unknown> move frame under execution
---@param user integer user combatant owning the strike
---@return string? effective held-item key answering the strike
local function effectiveItemOf(ctx, frame, user)
  local held = heldItemOf(frame)
  if held == nil then
    return nil
  end
  if abilitiesOf(frame).user == "KLUTZ" or ctx:hasBattleEffect(user, "embargo") then
    return nil
  end
  return held
end

---@param frame table<string, unknown> move frame under execution
---@return table<string, table<string, unknown>> immutable item facts by item key under the strike
local function itemFactsOf(frame)
  local record = frame --[[@as table<string, unknown>]]
  local key = record.executingMove --[[@as string]]
  local locals = record.locals --[[@as table<string, unknown>]]
  local facts = locals.itemFacts
  if type(facts) ~= "table" then
    error(BattleErrors.missingBehavior("throw law reads its immutable item facts", { key = key }))
  end
  return facts --[[@as table<string, table<string, unknown>>]]
end

---@param frame table<string, unknown> move frame under execution
---@return table<string, integer> user individual values under the strike
local function userIvsOf(frame)
  local record = frame --[[@as table<string, unknown>]]
  local key = record.executingMove --[[@as string]]
  local locals = record.locals --[[@as table<string, unknown>]]
  local ivs = locals.userIvs
  if type(ivs) ~= "table" then
    error(BattleErrors.missingBehavior("hidden power reads its user individual values", { key = key }))
  end
  local values = ivs --[[@as table<string, unknown>]]
  for _, stat in ipairs({ "hp", "attack", "defense", "speed", "specialAttack", "specialDefense" }) do
    local value = values[stat]
    if type(value) ~= "number" or value % 1 ~= 0 or value < 0 or value > 31 then
      error(BattleErrors.missingBehavior("hidden power reads its user individual values", { key = key, fact = stat }))
    end
  end
  return values --[[@as table<string, integer>]]
end

---@param used table<integer, string> distinct moves used by this entry in first-use order
---@param move string known move identity under the membership check
---@return boolean true when the entry already used the move
local function usedMove(used, move)
  for _, key in ipairs(used) do
    if key == move then
      return true
    end
  end
  return false
end

---@param frame table<string, unknown> move frame under execution
---@return table<integer, string> distinct moves used by this entry in first-use order
local function usedMovesOf(frame)
  local record = frame --[[@as table<string, unknown>]]
  local key = record.executingMove --[[@as string]]
  local locals = record.locals --[[@as table<string, unknown>]]
  local used = locals.usedMoves
  if type(used) ~= "table" then
    error(BattleErrors.missingBehavior("last resort reads its distinct-move history", { key = key }))
  end
  return used --[[@as table<integer, string>]]
end

---@param frame table<string, unknown> move frame under execution
---@return number defender weight in hectograms under the strike
local function foeWeightHgOf(frame)
  local record = frame --[[@as table<string, unknown>]]
  local key = record.executingMove --[[@as string]]
  local locals = record.locals --[[@as table<string, unknown>]]
  local weight = locals.foeWeightHg
  if type(weight) ~= "number" or weight < 0 then
    error(BattleErrors.missingBehavior("weight law reads its defender weight", { key = key }))
  end
  return weight --[[@as number]]
end

---@param frame table<string, unknown> move frame under execution
---@return table<string, unknown> beat-up party facts under the strike
local function beatupOf(frame)
  local record = frame --[[@as table<string, unknown>]]
  local key = record.executingMove --[[@as string]]
  local locals = record.locals --[[@as table<string, unknown>]]
  local beatup = locals.beatup
  if type(beatup) ~= "table" then
    error(BattleErrors.missingBehavior("beat-up reads its party facts", { key = key }))
  end
  local facts = beatup --[[@as table<string, unknown>]]
  if
    type(facts.defense) ~= "number"
    or facts.defense --[[@as number]]
      < 1
  then
    error(BattleErrors.missingBehavior("beat-up reads its defender base defense", { key = key }))
  end
  if type(facts.members) ~= "table" then
    error(BattleErrors.missingBehavior("beat-up reads its striker party", { key = key }))
  end
  for _, member in
    ipairs(facts.members --[[@as table<integer, unknown>]])
  do
    if type(member) ~= "table" then
      error(BattleErrors.missingBehavior("beat-up reads its striker party", { key = key }))
    end
    local striker = member --[[@as table<string, unknown>]]
    if
      type(striker.attack) ~= "number"
      or striker.attack --[[@as number]]
        < 1
      or type(striker.level) ~= "number"
      or striker.level --[[@as number]]
        % 1 ~= 0
      or striker.level --[[@as number]]
        < 1
    then
      error(BattleErrors.missingBehavior("beat-up reads its striker party", { key = key }))
    end
  end
  return facts
end

-- Records staged strike damage in the turn revenge ledger so later
-- revenge-law handlers answer from the same turn. Skips zero damage and
-- non-staged categories, which never arm revenge, counter, or assurance.
---@param ctx BattleContext mechanics context under execution
---@param frame table<string, unknown> move frame under execution
---@param defender integer defender combatant under the hit
---@param dealt integer damage actually dealt after application
local function noteStrikeDamage(ctx, frame, defender, dealt)
  if dealt < 1 then
    return
  end
  local record = frame --[[@as table<string, unknown>]]
  local locals = record.locals --[[@as table<string, unknown>]]
  local move = locals.move --[[@as table<string, unknown>]]
  local category = move.category
  if category ~= "physical" and category ~= "special" then
    return
  end
  ctx:noteDamageTaken(defender, userOf(frame), category --[[@as string]], dealt)
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
  -- Prevention answers before application through the defender
  -- ability, while reflection answers only an inflicted status
  -- through the same holder afterwards.
  local foeAbility = liveAbility(abilitiesOf(frame).foe)
  if foeAbility ~= nil then
    local ward = NativePassiveBridge.invokeFacts({
      combatant = defender,
      activation = activationOf(ctx, defender),
      ability = foeAbility,
    }, "beforeHit", { statusAttempt = status })
    for _, event in ipairs(ward.events) do
      if
        (event --[[@as table<string, unknown>]]).prevented == true
      then
        return
      end
    end
  end
  local state = {}
  if status == "toxic" then
    state = { counter = 0 }
  end
  if not ctx:applyStatus(defender, status, state, causeFor(record)) then
    return
  end
  if foeAbility ~= nil then
    local mirror = NativePassiveBridge.invokeFacts({
      combatant = defender,
      activation = activationOf(ctx, defender),
      ability = foeAbility,
    }, "afterHit", { inflictedStatus = status })
    for _, event in ipairs(mirror.events) do
      if
        type((event --[[@as table<string, unknown>]]).reflected) == "string"
      then
        ctx:applyStatus(userOf(frame), status, state, causeFor(record))
      end
    end
  end
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

-- Native critical stages for one strike: the curated move bonus, two
-- for a focused user, one for the lens, the claw, and the lucky
-- ability, and two for the species-locked pair, all through the
-- current holder passives. The sniping ability replaces only the
-- surviving multiplier. Wards negate a successful roll only after it
-- is spent, so the check still routes through the resolver and
-- consumes its native draw exactly once.
---@param ctx BattleContext mechanics context under execution
---@param frame table<string, unknown> move frame under execution
---@param user integer user combatant owning the strike
---@param defender integer defender combatant under the strike
---@param params table<string, unknown>? curated strike controls owning the hit
---@param stream BattleRng battle stream owned by the caller
---@return CriticalResult staged critical outcome for the strike
local function strikeCritical(ctx, frame, user, defender, params, stream)
  local controls = params or {}
  local stage = controls.critStage or 0
  if ctx:hasBattleEffect(user, "focusenergy") then
    stage = stage --[[@as integer]] + 2
  end
  local abilities = abilitiesOf(frame)
  local outcome = NativePassiveBridge.invokeFacts({
    combatant = user,
    activation = activationOf(ctx, user),
    ability = liveAbility(abilities.user),
    heldItem = effectiveItemOf(ctx, frame, user),
    species = userSpeciesOf(frame),
  }, "beforeHit", { criticalCheck = true, accuracyCheck = true })
  for _, event in ipairs(outcome.events) do
    local record = event --[[@as table<string, unknown>]]
    if record.critical == "boosted" then
      local bonus = record.stages
      if type(bonus) ~= "number" then
        bonus = 1
      end
      stage = stage --[[@as integer]] + bonus --[[@as integer]]
    elseif record.accuracy == "critical" then
      stage = stage --[[@as integer]] + 1
    end
  end
  ---@type table<string, boolean>?
  local blockers = nil
  if ctx:hasBattleEffect(defender, "luckychant") then
    blockers = { luckyChant = true }
  end
  local foeAbility = liveAbility(abilities.foe)
  if foeAbility ~= nil then
    -- Anti-critical guards answer the recorded hit, so a breaking
    -- attacker pierces them under the existing bypass law.
    local ward = NativePassiveBridge.invokeFacts({
      combatant = defender,
      activation = activationOf(ctx, defender),
      ability = foeAbility,
    }, "beforeHit", { critical = true, hit = { attackerAbility = liveAbility(abilities.user) } })
    for _, event in ipairs(ward.events) do
      if
        (event --[[@as table<string, unknown>]]).critical == "negated"
      then
        if blockers == nil then
          blockers = {}
        end
        blockers.antiCriticalAbility = true
      end
    end
  end
  return Critical.resolve(stage --[[@as integer]], stream, causeFor(frame), abilities.user == "SNIPER", blockers)
end

-- Bare immunity answers block the strike: an answer carrying only its
-- identity, holder, and kind claims no other effect, so wards stop the
-- hit while absorbing or softening answers stay unanswered: no live
-- checkpoint consumes them yet, and the strike continues undiminished.
---@param event unknown dispatched passive answer under inspection
---@param defender integer defender combatant under the strike
---@return boolean true when the answer blocks with no other effect
local function bareImmunity(event, defender)
  if type(event) ~= "table" then
    return false
  end
  local answer = event --[[@as table<string, unknown>]]
  if answer.kind ~= "trigger" or answer.combatant ~= defender or answer.key == nil then
    return false
  end
  local keys = 0
  for _ in pairs(answer) do
    keys = keys + 1
  end
  return keys == 3
end

-- Live immunity behind the defender ability: the canonical handler
-- answers from the strike type, power, and effectiveness, and a bare
-- answer stops the hit before any critical or damage draw.
---@param ctx BattleContext mechanics context under execution
---@param frame table<string, unknown> move frame under execution
---@param defender integer defender combatant under the strike
---@param power integer curated move power under the staged arithmetic
---@param moveType string striking move type under the immunity read
---@param effectiveness table<string, unknown> exact effectiveness rational for the strike
---@return boolean true when the strike is warded off
local function strikeWarded(ctx, frame, defender, power, moveType, effectiveness)
  local foeAbility = liveAbility(abilitiesOf(frame).foe)
  if foeAbility == nil then
    return false
  end
  -- Typeless strikes bypass ability immunities beside the chart: with
  -- no striking type the ward has no effectiveness to answer.
  if moveType == "typeless" then
    return false
  end
  local numerator = effectiveness.numerator
  local denominator = effectiveness.denominator
  local superEffective = type(numerator) == "number"
    and type(denominator) == "number"
    and numerator --[[@as integer]]
      > denominator --[[@as integer]]
  -- The ward answers the recorded hit, so a breaking attacker opens
  -- immunities under the existing bypass law.
  local outcome = NativePassiveBridge.invokeFacts(
    {
      combatant = defender,
      activation = activationOf(ctx, defender),
      ability = foeAbility,
    },
    "beforeHit",
    {
      moveType = moveType,
      movePower = power,
      superEffective = superEffective,
      hit = { attackerAbility = liveAbility(abilitiesOf(frame).user) },
    }
  )
  for _, event in ipairs(outcome.events) do
    if bareImmunity(event, defender) then
      return true
    end
  end
  return false
end

-- Live resistance piercing behind the striking ability: a resisted hit
-- whose ability answers doubles its staged power.
---@param ctx BattleContext mechanics context under execution
---@param frame table<string, unknown> move frame under execution
---@param user integer user combatant owning the strike
---@param power integer curated move power under the staged arithmetic
---@return integer staged power with the piercing answer applied
local function tintedPower(ctx, frame, user, power)
  local userAbility = liveAbility(abilitiesOf(frame).user)
  if userAbility == nil then
    return power
  end
  local outcome = NativePassiveBridge.invokeFacts({
    combatant = user,
    activation = activationOf(ctx, user),
    ability = userAbility,
  }, "beforeHit", { resisted = true })
  for _, event in ipairs(outcome.events) do
    if
      (event --[[@as table<string, unknown>]]).power == "boosted"
    then
      return power * 2
    end
  end
  return power
end

-- Live strike recovery behind the effective holding: a ringing holder
-- recovers an eighth of the damage it dealt. The holding persists.
---@param ctx BattleContext mechanics context under execution
---@param frame table<string, unknown> move frame under execution
---@param user integer user combatant owning the strike
---@param dealt integer damage actually dealt by the hit
local function applyShellBell(ctx, frame, user, dealt)
  if dealt < 1 then
    return
  end
  local abilities = abilitiesOf(frame)
  local outcome = NativePassiveBridge.invokeFacts({
    combatant = user,
    activation = activationOf(ctx, user),
    ability = liveAbility(abilities.user),
    heldItem = effectiveItemOf(ctx, frame, user),
    species = userSpeciesOf(frame),
  }, "afterHit", { dealtDamage = true })
  for _, event in ipairs(outcome.events) do
    if
      (event --[[@as table<string, unknown>]]).recovered == true
    then
      local gain = math.floor(dealt / 8)
      if gain > 0 then
        local healed = ctx:heal(user, gain, causeFor(frame))
        ctx:emit("healed", causeFor(frame), { target = user, restored = healed.after - healed.before })
      end
    end
  end
end

-- Defending-side screen facts behind staged strikes: the physical
-- guard answers physical strikes and the special guard answers special
-- ones, so applicability arrives pre-resolved by category here. The
-- half versus two-thirds mode reads live side occupancy, never the
-- spread target count, and shattering strikes bypass the guard through
-- the existing screen-removing move path. Reads stay read-only; the
-- arithmetic owner keeps every truncation.
local SCREEN_BY_CATEGORY = { physical = "reflect", special = "lightscreen" }

local SCREEN_REMOVING = { BRICK_BREAK = true }

---@param ctx BattleContext mechanics context under execution
---@param side integer defending side identity under the read
---@return integer active combatants standing on the side
local function sideOccupancy(ctx, side)
  local count = 0
  for _, combatant in ipairs(ctx:activeCombatants()) do
    if ctx:entryOf(combatant).side == side then
      count = count + 1
    end
  end
  return count
end

---@param ctx BattleContext mechanics context under execution
---@param frame table<string, unknown> move frame under execution
---@param defender integer defender combatant under the hit
---@param category string striking move category
---@return boolean whether the category-matching guard screens the strike
---@return string half or two-thirds reduction selected by side occupancy
---@return boolean whether the strike shatters screens instead of meeting them
local function screenLawOf(ctx, frame, defender, category)
  local record = frame --[[@as table<string, unknown>]]
  local guard = SCREEN_BY_CATEGORY[category]
  local side = ctx:entryOf(defender).side
  local applies = guard ~= nil and ctx:sideEffect(side, guard) ~= nil
  local reduction = "half"
  if sideOccupancy(ctx, side) > 1 then
    reduction = "two_thirds"
  end
  local removes = SCREEN_REMOVING[
    record.executingMove --[[@as string]]
  ] == true
  return applies, reduction, removes
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
  -- Strike-law facts validate before any draw: a missing fact fails
  -- without spending the critical or damage rolls.
  local burned, guts, weather, weatherSuppressed, category, moveType, solarBeam = strikeLawOf(frame, controls.moveType)
  local screenApplies, screenReduction, removesScreens = screenLawOf(ctx, frame, defender, category)
  local record = frame --[[@as table<string, unknown>]]
  local locals = record.locals --[[@as table<string, unknown>]]
  local stab, effectiveness = StagedTypeModifiers.forStrike(frame, defender, {
    airborne = ctx:hasBattleEffect(defender, "magnetrise"),
    foresight = ctx:hasBattleEffect(defender, "foresight"),
    gravity = locals.gravity == true,
  }, controls.moveType)
  -- Wards stop the hit before any roll; a resisted hit pierces
  -- through the striking ability before the same rolls.
  if strikeWarded(ctx, frame, defender, power, moveType, effectiveness) then
    return 0
  end
  local numerator = effectiveness.numerator
  local denominator = effectiveness.denominator
  if
    type(numerator) == "number"
    and type(denominator) == "number"
    and numerator --[[@as integer]]
      > 0
    and numerator --[[@as integer]]
      < denominator --[[@as integer]]
  then
    power = tintedPower(ctx, frame, userOf(frame), power)
  end
  -- Multi-hit sequences share one critical roll across every hit: the
  -- native scripts roll CalcCrit once per move, then loop CalcDamage.
  -- The shared table memoizes the first roll, which still lands after
  -- the accuracy gate in source order.
  local critical
  if controls.shareCritical == true then
    if controls.critical == nil then
      controls.critical = strikeCritical(ctx, frame, userOf(frame), defender, params, stream)
    end
    critical = controls.critical
  else
    critical = strikeCritical(ctx, frame, userOf(frame), defender, params, stream)
  end
  local result = Damage.calculate({
    level = combat.level,
    power = power,
    attack = combat.attack,
    defense = combat.defense,
    rawAttack = combat.rawAttack,
    rawDefense = combat.rawDefense,
    attackStage = combat.attackStage,
    defenseStage = combat.defenseStage,
    criticalMultiplier = critical.multiplier,
    category = category,
    burned = burned,
    guts = guts,
    stab = stab,
    effectiveness = { numerator = effectiveness.numerator, denominator = effectiveness.denominator },
    effectivenessFactors = effectiveness.factors,
    targetCount = targetCount,
    weather = weather,
    weatherSuppressed = weatherSuppressed,
    moveType = moveType,
    solarBeam = solarBeam,
    screenApplies = screenApplies,
    screenReduction = screenReduction,
    removesScreens = removesScreens,
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
  -- Doll damage still counts as dealt for the strike follow-ups: drain
  -- and recoil answer the inflicted amount, while only bodily harm arms
  -- the revenge ledger.
  if substituteTakesHit(ctx, frame, defender, amount, hitIndex) then
    return amount
  end
  local dealt = applyHit(ctx, frame, defender, amount)
  emitStruck(ctx, frame, defender, hitIndex, dealt)
  noteStrikeDamage(ctx, frame, defender, dealt)
  -- Strike recovery answers the inflicted amount behind the effective
  -- holding once the hit lands.
  applyShellBell(ctx, frame, userOf(frame), dealt)
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
  -- Ordinary recoil answers its source guards: rock head and magic
  -- guard suppress the hit-derived backlash. Struggle never reaches
  -- this owner; it backlashes from user maximum health instead.
  local guards = abilitiesOf(frame)
  if guards.user == "ROCK_HEAD" or guards.user == "MAGIC_GUARD" then
    return
  end
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
---@param moveTypeOverride string|nil source-computed move type replacing the compiled one
---@return integer weakened strike power for the staged arithmetic
local function sportWeakenedPower(ctx, frame, power, moveTypeOverride)
  local record = frame --[[@as table<string, unknown>]]
  local locals = record.locals --[[@as table<string, unknown>]]
  local moveType = moveTypeOverride
  if moveType == nil then
    local move = locals.move --[[@as table<string, unknown>]]
    moveType = move.moveType --[[@as string]]
  end
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
  -- Per-strike controls copy the curated entry: shared-critical
  -- memoization writes back into the controls, which must never leak
  -- across strikes sharing one curated entry.
  local controls = {}
  for key, value in pairs(params or {}) do
    controls[key] = value
  end
  local owned = controls --[[@as table<string, unknown>]]
  local targets = frame.targets --[[@as table<integer, unknown>]]
  local strike = strikeFactsOf(frame)
  local power = strike.power
  if owned.power ~= nil then
    power = owned.power --[[@as integer]]
  end
  power = sportWeakenedPower(ctx, frame, power, owned.moveType --[[@as string?]])
  local accuracy = strike.accuracy
  if owned.accuracyOverride ~= nil then
    accuracy = owned.accuracyOverride --[[@as integer]]
  end
  if owned.skipAccuracy == true then
    accuracy = 0
  end
  local hits = owned.hits or 1
  assert(type(hits) == "number" and hits % 1 == 0 and hits >= 1, "fixed hit counts stay positive integers")
  local connected, dealtTotal = false, 0
  for hitIndex = 1, #targets do
    local defender = targetOf(targets[hitIndex])
    if accuracyGate(ctx, frame, defender, accuracy) then
      for _ = 1, hits --[[@as integer]] do
        dealtTotal = dealtTotal + stagedHit(ctx, frame, defender, power, hitIndex, #targets, owned)
        applySecondaries(ctx, frame, defender, owned.secondaries --[[@as table<integer, table<string, unknown>>?]])
        local health = ctx:damage(defender, 0, causeFor(frame))
        if health.after == 0 then
          break
        end
      end
      connected = true
      if owned.drain == true then
        applyDrain(ctx, frame, dealtTotal)
      end
    elseif owned.crash == true then
      ctx:damage(userOf(frame), 1, causeFor(frame))
    end
    local health = ctx:damage(defender, 0, causeFor(frame))
    if health.after == 0 then
      break
    end
  end
  if owned.recoil ~= nil and dealtTotal > 0 then
    applyRecoil(ctx, frame, dealtTotal, owned.recoil --[[@as string]])
  end
  if owned.selfKo == true then
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
  local record = frame --[[@as table<string, unknown>]]
  error(BattleErrors.missingBehavior("no native damage semantics are modeled for the source identity", {
    key = record.executingMove --[[@as string]],
  }))
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
    if not substituteTakesHit(ctx, record, defender, result.amount, hitIndex) then
      local dealt = applyHit(ctx, record, defender, result.amount)
      emitStruck(ctx, record, defender, hitIndex, dealt)
      noteStrikeDamage(ctx, record, defender, dealt)
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
    local probe = ctx:damage(defender, 0, causeFor(record))
    local amount = math.floor(probe.before / 2)
    if amount < 1 then
      amount = 1
    end
    if not substituteTakesHit(ctx, record, defender, amount, hitIndex) then
      local dealt = applyHit(ctx, record, defender, amount)
      emitStruck(ctx, record, defender, hitIndex, dealt)
      noteStrikeDamage(ctx, record, defender, dealt)
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
  noteStrikeDamage(ctx, record, defender, dealt)
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
    local resolution = Accuracy.resolve(query, stream)
    if resolution.kind == "hit" then
      connected = true
      stagedHit(ctx, record, defender, power, hitIndex, #targets)
    else
      emitMissed(ctx, record, defender)
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

-- Beat Up sends every eligible party member to strike once in roster
-- order: the user always answers while benched mates answer conscious,
-- healthy, and unhatched. One accuracy check gates the sequence, one
-- critical roll serves every hit, immunity is ignored, and each hit
-- scales base attack, compiled power, and level against the defender
-- base defense with the staged 85-100 percent range. Source reference:
-- BtlCmd_BeatUp in src/battle/battle_command.c.
local function stepBeatUp(ctx, frame)
  assert(type(ctx) == "table", "damage steps through the battle context")
  assert(type(frame) == "table", "damage steps from its move frame")
  local record = frame --[[@as table<string, unknown>]]
  local stream = checkStream(record.stream)
  local strike = strikeFactsOf(record)
  local party = beatupOf(record)
  local defender = targetOf((record.targets --[[@as table<integer, unknown>]])[1])
  if not accuracyGate(ctx, record, defender, strike.accuracy) then
    return { kind = "complete", result = "missed" }
  end
  local critical = strikeCritical(ctx, record, userOf(record), defender, {}, stream)
  local targets = record.targets --[[@as table<integer, unknown>]]
  for hitIndex, member in
    ipairs(party.members --[[@as table<integer, unknown>]])
  do
    local striker = member --[[@as table<string, unknown>]]
    local target = targetOf(targets[((hitIndex - 1) % #targets) + 1])
    local level = striker.level --[[@as integer]]
    local amount = math.floor(
      (
        striker.attack --[[@as integer]]
        * strike.power
        * math.floor(level * 2 / 5 + 2)
      ) / party.defense --[[@as integer]]
    )
    amount = math.floor(amount / 50) + 2
    if critical.critical then
      amount = amount * 2
    end
    local percent = 100 - (stream:nextU16("damage_roll", causeFor(record)) % 16)
    amount = math.floor((amount * percent) / 100)
    if amount < 1 then
      amount = 1
    end
    if not substituteTakesHit(ctx, record, target, amount, hitIndex) then
      local dealt = applyHit(ctx, record, target, amount)
      emitStruck(ctx, record, target, hitIndex, dealt)
      noteStrikeDamage(ctx, record, target, dealt)
    end
    if (ctx:damage(target, 0, causeFor(record))).after == 0 then
      break
    end
  end
  return { kind = "complete", result = "hit" }
end

local function sampleMultiHitCount(frame)
  local record = frame --[[@as table<string, unknown>]]
  local abilities = abilitiesOf(record)
  if abilities.user == "SKILL_LINK" then
    return 5
  end
  local stream = checkStream(record.stream)
  local first = stream:nextU16("multi-hit-count", causeFor(record)) % 4
  if first < 2 then
    return first + 2
  end
  return (stream:nextU16("multi-hit-count", causeFor(record)) % 4) + 2
end

---@param secondaries table<integer, table<string, unknown>>|nil secondary specifications rolling per hit
---@return fun(ctx: BattleContext, frame: table<string, unknown>): table<string, unknown> step handler sampling a two-to-five-hit sequence
local function makeSampledHits(secondaries)
  local function stepSampled(ctx, frame)
    assert(type(ctx) == "table", "damage steps through the battle context")
    assert(type(frame) == "table", "damage steps from its move frame")
    local record = frame --[[@as table<string, unknown>]]
    return runStriker(ctx, record, { hits = sampleMultiHitCount(record), secondaries = secondaries })
  end
  return stepSampled
end

-- Triple Kick lands three accuracy-checked kicks with rising power:
-- ten times the kick ordinal, sharing one critical roll. Source
-- reference: files/battledata/script/effect_script/effect_script_0104.s.
local function stepTripleKick(ctx, frame)
  assert(type(ctx) == "table", "damage steps through the battle context")
  assert(type(frame) == "table", "damage steps from its move frame")
  local record = frame --[[@as table<string, unknown>]]
  local strike = strikeFactsOf(record)
  local defender = targetOf((record.targets --[[@as table<integer, unknown>]])[1])
  local connected = false
  local controls = { shareCritical = true }
  for kick = 1, 3 do
    if accuracyGate(ctx, record, defender, strike.accuracy) then
      stagedHit(ctx, record, defender, 10 * kick, kick, 1, controls)
      connected = true
    end
    local health = ctx:damage(defender, 0, causeFor(record))
    if health.after == 0 then
      break
    end
  end
  if not connected then
    return { kind = "complete", result = "missed" }
  end
  return { kind = "complete", result = "hit" }
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
    error(BattleErrors.missingBehavior("damage reads its real combat facts", {
      key = record.executingMove --[[@as string]],
      fact = "level",
    }))
  end
  return runFixed(ctx, record, (combat --[[@as table<string, unknown>]]).level --[[@as integer]])
end

local function stepWeight(ctx, frame)
  assert(type(ctx) == "table", "damage steps through the battle context")
  assert(type(frame) == "table", "damage steps from its move frame")
  local record = frame --[[@as table<string, unknown>]]
  local weightKg = foeWeightHgOf(record) / 10
  local power = 120
  if weightKg <= 10 then
    power = 20
  elseif weightKg <= 25 then
    power = 40
  elseif weightKg <= 50 then
    power = 60
  elseif weightKg <= 100 then
    power = 80
  elseif weightKg <= 200 then
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

---@param frame table<string, unknown> move frame under execution
---@param answered boolean true when the source doubling condition holds
---@return integer staged power for the strike, doubled when answered
local function revengePower(frame, answered)
  local strike = strikeFactsOf(frame)
  if answered then
    return strike.power * 2
  end
  return strike.power
end

-- Revenge and avalanche double their power when the user was struck by
-- its target earlier in the turn, through either staged category.
-- Source references: BtlCmd_CalcRevengeDamageMul in
-- src/battle/battle_command.c and files/battledata/script/effect_script/
-- effect_script_0185.s.
local function stepRevenge(ctx, frame)
  assert(type(ctx) == "table", "damage steps through the battle context")
  assert(type(frame) == "table", "damage steps from its move frame")
  local record = frame --[[@as table<string, unknown>]]
  local defender = targetOf((record.targets --[[@as table<integer, unknown>]])[1])
  local duel = duelOf(record)
  local physical = duel.revengePhysical --[[@as table<string, unknown>?]]
  local special = duel.revengeSpecial --[[@as table<string, unknown>?]]
  local answered = (
    physical ~= nil and (physical --[[@as table<string, unknown>]]).attacker == defender
  ) or (
      special ~= nil and (special --[[@as table<string, unknown>]]).attacker == defender
    )
  return runStriker(ctx, record, { power = revengePower(record, answered) })
end

-- Payback doubles its power when its target already consumed its action
-- this turn, regardless of damage. Source references:
-- BtlCmd_CalcPaybackPower in src/battle/battle_command.c and
-- files/battledata/script/effect_script/effect_script_0230.s.
local function stepPayback(ctx, frame)
  assert(type(ctx) == "table", "damage steps through the battle context")
  assert(type(frame) == "table", "damage steps from its move frame")
  local record = frame --[[@as table<string, unknown>]]
  local duel = duelOf(record)
  return runStriker(ctx, record, {
    power = revengePower(record, duel.foeActed --[[@as boolean]]),
  })
end

-- Assurance doubles its power when its target already took damage this
-- turn, from any recorded staged strike. Source reference:
-- files/battledata/script/effect_script/effect_script_0231.s.
local function stepAssurance(ctx, frame)
  assert(type(ctx) == "table", "damage steps through the battle context")
  assert(type(frame) == "table", "damage steps from its move frame")
  local record = frame --[[@as table<string, unknown>]]
  local duel = duelOf(record)
  return runStriker(ctx, record, {
    power = revengePower(record, duel.foeHurt --[[@as boolean]]),
  })
end

-- Brine doubles its power when the target sits at half health or below:
-- doubling holds exactly when twice the health fits inside the ceiling.
-- Source reference: files/battledata/script/effect_script/
-- effect_script_0221.s.
local function stepBrine(ctx, frame)
  assert(type(ctx) == "table", "damage steps through the battle context")
  assert(type(frame) == "table", "damage steps from its move frame")
  local record = frame --[[@as table<string, unknown>]]
  local defender = targetOf((record.targets --[[@as table<integer, unknown>]])[1])
  local probe = ctx:damage(defender, 0, causeFor(record))
  local ceiling = ctx:entryOf(defender).maxHp --[[@as integer]]
  local answered = probe.before * 2 <= ceiling
  return runStriker(ctx, record, { power = revengePower(record, answered) })
end

-- Facade doubles its power while the user carries burn, poison, or
-- paralysis, matching the native facade-boost status mask. Source
-- references: STATUS_FACADE_BOOST in include/constants/battle.h and
-- files/battledata/script/effect_script/effect_script_0169.s.
local function stepFacade(ctx, frame)
  assert(type(ctx) == "table", "damage steps through the battle context")
  assert(type(frame) == "table", "damage steps from its move frame")
  local record = frame --[[@as table<string, unknown>]]
  local condition = ctx:statusOf(userOf(record))
  local answered = condition == "burn" or condition == "poison" or condition == "toxic" or condition == "paralysis"
  return runStriker(ctx, record, { power = revengePower(record, answered) })
end

-- Counter-style reactions return twice the recorded damage of their
-- staged category from the last live opposing damager, with neutral
-- effectiveness and no accuracy roll or critical: the native scripts set
-- the ignore-effectiveness flag and invoke the reaction directly.
-- Missing or fainted damagers fail. Source references: BtlCmd_Counter
-- and BtlCmd_MirrorCoat in src/battle/battle_command.c with
-- files/battledata/script/effect_script/effect_script_0089.s and
-- effect_script_0144.s.
---@param category string staged category selecting the recorded damage
---@return fun(ctx: BattleContext, frame: table<string, unknown>): table<string, unknown> step handler returning the doubled damage
local function makeReaction(category)
  local function stepReaction(ctx, frame)
    assert(type(ctx) == "table", "damage steps through the battle context")
    assert(type(frame) == "table", "damage steps from its move frame")
    local record = frame --[[@as table<string, unknown>]]
    local duel = duelOf(record)
    local answer = nil
    if category == "physical" then
      answer = duel.revengePhysical
    else
      answer = duel.revengeSpecial
    end
    if type(answer) ~= "table" then
      return { kind = "complete", result = "failed" }
    end
    local noted = answer --[[@as table<string, unknown>]]
    local defender = noted.attacker --[[@as integer]]
    local backlash = noted.amount --[[@as integer]] * 2
    if substituteTakesHit(ctx, record, defender, backlash, 1) then
      return { kind = "complete", result = "hit" }
    end
    local dealt = applyHit(ctx, record, defender, backlash)
    emitStruck(ctx, record, defender, 1, dealt)
    noteStrikeDamage(ctx, record, defender, dealt)
    return { kind = "complete", result = "hit" }
  end
  return stepReaction
end

-- One-hit knockouts resolve outside the staged arithmetic: sturdy
-- answers first, lower-level users fail, locked-on targets fall without
-- a roll, and every other attempt rolls flat percent under the
-- level-plus-accuracy chance with no stage scaling. Damage equals the
-- defender remaining health. Source reference: BtlCmd_TryOHKOMove in
-- src/battle/battle_command.c.
local function stepOhko(ctx, frame)
  assert(type(ctx) == "table", "damage steps through the battle context")
  assert(type(frame) == "table", "damage steps from its move frame")
  local record = frame --[[@as table<string, unknown>]]
  local defender = targetOf((record.targets --[[@as table<integer, unknown>]])[1])
  local combat = combatOf(record)
  local foeLevel = foeLevelOf(record)
  local abilities = abilitiesOf(record)
  local foeAbility = abilities.foe
  if foeAbility == nil or foeAbility == "" then
    error(BattleErrors.missingBehavior("knockout law reads its defender ability", {
      key = record.executingMove --[[@as string]],
    }))
  end
  if foeAbility == "STURDY" then
    return { kind = "complete", result = "failed" }
  end
  if combat.level < foeLevel then
    return { kind = "complete", result = "failed" }
  end
  local strike = strikeFactsOf(record)
  local hitChance = combat.level - foeLevel + strike.accuracy
  if not ctx:hasBattleEffect(defender, "lockon") then
    local stream = checkStream(record.stream)
    if stream:nextU16("ohko_hit", causeFor(record)) % 100 >= hitChance then
      emitMissed(ctx, record, defender)
      return { kind = "complete", result = "missed" }
    end
  end
  local remaining = ctx:damage(defender, 0, causeFor(record)).before
  if substituteTakesHit(ctx, record, defender, remaining, 1) then
    return { kind = "complete", result = "hit" }
  end
  local dealt = applyHit(ctx, record, defender, remaining)
  emitStruck(ctx, record, defender, 1, dealt)
  noteStrikeDamage(ctx, record, defender, dealt)
  return { kind = "complete", result = "hit" }
end

-- Eruption and water spout scale base power with user health: one
-- hundred fifty times health over ceiling, minimum one. Source
-- reference: BtlCmd_CalcHPFalloffPower in src/battle/battle_command.c.
local function stepEruption(ctx, frame)
  assert(type(ctx) == "table", "damage steps through the battle context")
  assert(type(frame) == "table", "damage steps from its move frame")
  local record = frame --[[@as table<string, unknown>]]
  local user = userOf(record)
  local strike = strikeFactsOf(record)
  local probe = ctx:damage(user, 0, causeFor(record))
  local ceiling = ctx:entryOf(user).maxHp --[[@as integer]]
  local power = math.floor((strike.power * probe.before) / ceiling)
  if power < 1 then
    power = 1
  end
  return runStriker(ctx, record, { power = power })
end

-- Flail and reversal climb the native 64th ladder: at most one
-- sixty-fourth deals two hundred, five deals one-fifty, twelve deals
-- one hundred, twenty-one deals eighty, forty-two deals forty, and
-- anything healthier deals twenty. Source references:
-- BtlCmd_CalcFlailPower in src/battle/battle_command.c with
-- sFlailDamageTable.
local FLAIL_LADDER = {
  { 1, 200 },
  { 5, 150 },
  { 12, 100 },
  { 21, 80 },
  { 42, 40 },
}

local function stepFlail(ctx, frame)
  assert(type(ctx) == "table", "damage steps through the battle context")
  assert(type(frame) == "table", "damage steps from its move frame")
  local record = frame --[[@as table<string, unknown>]]
  local user = userOf(record)
  local probe = ctx:damage(user, 0, causeFor(record))
  local ceiling = ctx:entryOf(user).maxHp --[[@as integer]]
  local pixels = math.floor((probe.before * 64) / ceiling)
  if probe.before > 0 and pixels < 1 then
    pixels = 1
  end
  local power = 20
  for _, rung in ipairs(FLAIL_LADDER) do
    if pixels <= rung[1] then
      power = rung[2]
      break
    end
  end
  return runStriker(ctx, record, { power = power })
end

-- Wring out scales with defender health: one plus one-twenty times
-- health over ceiling. Source reference: BtlCmd_CalcWringOutPower in
-- src/battle/battle_command.c.
local function stepWringOut(ctx, frame)
  assert(type(ctx) == "table", "damage steps through the battle context")
  assert(type(frame) == "table", "damage steps from its move frame")
  local record = frame --[[@as table<string, unknown>]]
  local defender = targetOf((record.targets --[[@as table<integer, unknown>]])[1])
  local probe = ctx:damage(defender, 0, causeFor(record))
  local ceiling = ctx:entryOf(defender).maxHp --[[@as integer]]
  local power = 1 + math.floor((120 * probe.before) / ceiling)
  return runStriker(ctx, record, { power = power })
end

-- Gyro Ball scales with the speed ratio: one plus twenty-five times
-- defender speed over user speed, capped at one-fifty. Source reference:
-- BtlCmd_CalcGyroBallPower in src/battle/battle_command.c.
local function stepGyroBall(ctx, frame)
  assert(type(ctx) == "table", "damage steps through the battle context")
  assert(type(frame) == "table", "damage steps from its move frame")
  local record = frame --[[@as table<string, unknown>]]
  local userSpeed, foeSpeed = speedsOf(record)
  if userSpeed < 1 then
    error(BattleErrors.missingBehavior("weightless power reads its effective speeds", {
      key = record.executingMove --[[@as string]],
      fact = "user",
    }))
  end
  local power = 1 + math.floor((25 * foeSpeed) / userSpeed)
  if power > 150 then
    power = 150
  end
  return runStriker(ctx, record, { power = power })
end

-- Hidden Power derives type and power from the user individual
-- values: the low bits index sixteen types past mystery, the second
-- bits scale power from thirty to seventy. Source reference:
-- BtlCmd_CalcHiddenPowerParams in src/battle/battle_command.c.
local HIDDEN_POWER_TYPES = {
  "fighting",
  "flying",
  "poison",
  "ground",
  "rock",
  "bug",
  "ghost",
  "steel",
  "fire",
  "water",
  "grass",
  "electric",
  "psychic",
  "ice",
  "dragon",
  "dark",
}

local function stepHiddenPower(ctx, frame)
  assert(type(ctx) == "table", "damage steps through the battle context")
  assert(type(frame) == "table", "damage steps from its move frame")
  local record = frame --[[@as table<string, unknown>]]
  local ivs = userIvsOf(record)
  local function bit(value, position)
    return math.floor(value / (2 ^ position)) % 2
  end
  local order = { "hp", "attack", "defense", "speed", "specialAttack", "specialDefense" }
  local typeIndex, powerIndex = 0, 0
  for position, stat in ipairs(order) do
    local value = ivs[stat] --[[@as integer]]
    typeIndex = typeIndex + bit(value, 0) * (2 ^ (position - 1))
    powerIndex = powerIndex + bit(value, 1) * (2 ^ (position - 1))
  end
  local power = math.floor((powerIndex * 40) / 63) + 30
  local raw = math.floor((typeIndex * 15) / 63) + 1
  if raw >= 9 then
    raw = raw + 1
  end
  local moveType = nil
  if raw <= 8 then
    moveType = HIDDEN_POWER_TYPES[raw]
  else
    moveType = HIDDEN_POWER_TYPES[raw - 1]
  end
  return runStriker(ctx, record, { power = power, moveType = moveType })
end

-- Present checks accuracy once, then rolls its branch on one byte
-- draw: forty, eighty, or one-twenty power, else healing the target for
-- a quarter of its ceiling with a minimum of one. The damage branches
-- reuse the staged striker without a second accuracy roll. Source
-- references: BtlCmd_Present in src/battle/battle_command.c and
-- files/battledata/script/effect_script/effect_script_0122.s.
local function stepPresent(ctx, frame)
  assert(type(ctx) == "table", "damage steps through the battle context")
  assert(type(frame) == "table", "damage steps from its move frame")
  local record = frame --[[@as table<string, unknown>]]
  local defender = targetOf((record.targets --[[@as table<integer, unknown>]])[1])
  local strike = strikeFactsOf(record)
  if not accuracyGate(ctx, record, defender, strike.accuracy) then
    return { kind = "complete", result = "missed" }
  end
  local stream = checkStream(record.stream)
  local roll = stream:nextU16("present_power", causeFor(record)) % 256
  if roll >= 204 then
    local ceiling = ctx:entryOf(defender).maxHp --[[@as integer]]
    local amount = math.floor(ceiling / 4)
    if amount < 1 then
      amount = 1
    end
    local outcome = ctx:heal(defender, amount, causeFor(record))
    ctx:emit("healed", causeFor(record), { target = defender, restored = outcome.after - outcome.before })
    return { kind = "complete", result = "hit" }
  end
  local power = 40
  if roll >= 178 then
    power = 120
  elseif roll >= 102 then
    power = 80
  end
  return runStriker(ctx, record, { power = power, skipAccuracy = true })
end

-- Snore strikes only while the user sleeps, flinching on its compiled
-- chance otherwise. Source reference:
-- files/battledata/script/effect_script/effect_script_0092.s.
local function stepSnore(ctx, frame)
  assert(type(ctx) == "table", "damage steps through the battle context")
  assert(type(frame) == "table", "damage steps from its move frame")
  local record = frame --[[@as table<string, unknown>]]
  local locals = record.locals --[[@as table<string, unknown>]]
  if locals.userAsleep ~= true then
    return { kind = "complete", result = "failed" }
  end
  return runStriker(ctx, record, { secondaries = { { volatile = "flinch" } } })
end

-- Stomp doubles its power against minimizing targets and flinches on
-- its compiled chance either way. Source reference:
-- files/battledata/script/effect_script/effect_script_0150.s.
local function stepStomp(ctx, frame)
  assert(type(ctx) == "table", "damage steps through the battle context")
  assert(type(frame) == "table", "damage steps from its move frame")
  local record = frame --[[@as table<string, unknown>]]
  local defender = targetOf((record.targets --[[@as table<integer, unknown>]])[1])
  local strike = strikeFactsOf(record)
  local power = strike.power
  if ctx:hasBattleEffect(defender, "minimize") then
    power = power * 2
  end
  return runStriker(ctx, record, { power = power, secondaries = { { volatile = "flinch" } } })
end

-- Wake-up slap doubles against sleeping targets and wakes them on a
-- connecting strike; a live doll absorbs the doubled strike as an HP
-- pool without waking. Source reference:
-- files/battledata/script/effect_script/effect_script_0217.s.
local function stepWakeUpSlap(ctx, frame)
  assert(type(ctx) == "table", "damage steps through the battle context")
  assert(type(frame) == "table", "damage steps from its move frame")
  local record = frame --[[@as table<string, unknown>]]
  local defender = targetOf((record.targets --[[@as table<integer, unknown>]])[1])
  local strike = strikeFactsOf(record)
  local sleeping = ctx:statusOf(defender) == "sleep"
  local walled = ctx:hasBattleEffect(defender, "substitute")
  local power = strike.power
  if sleeping then
    power = power * 2
  end
  local outcome = runStriker(ctx, record, { power = power })
  if outcome.result == "hit" and sleeping and not walled then
    ctx:cureStatus(defender, "sleep", causeFor(record))
  end
  return outcome
end
-- Last Resort connects only when every other known move was used by
-- this entry: single-move holders fail, and any unused known move
-- fails. The distinct-move history keys on the entry token, so
-- withdrawing resets the count. Source reference: BtlCmd_TryLastResort
-- in src/battle/battle_command.c.
local function stepLastResort(ctx, frame)
  assert(type(ctx) == "table", "damage steps through the battle context")
  assert(type(frame) == "table", "damage steps from its move frame")
  local record = frame --[[@as table<string, unknown>]]
  local locals = record.locals --[[@as table<string, unknown>]]
  local known = locals.userMoves
  if type(known) ~= "table" or #known < 2 then
    return { kind = "complete", result = "failed" }
  end
  local used = usedMovesOf(record)
  for _, move in
    ipairs(known --[[@as table<integer, unknown>]])
  do
    if type(move) ~= "string" or move == "" then
      error(BattleErrors.missingBehavior("last resort reads its known moves", {
        key = record.executingMove --[[@as string]],
      }))
    end
    if
      move ~= "LAST_RESORT" and not usedMove(used, move --[[@as string]])
    then
      return { kind = "complete", result = "failed" }
    end
  end
  return runStriker(ctx, record, {})
end

-- Weather Ball doubles its power under field weather and strikes with
-- the weather type: rain water, sand rock, sun fire, hail ice. Calm
-- skies keep the compiled normal typing and base power. Source
-- reference: BtlCmd_CalcWeatherBallParams in src/battle/battle_command.c.
local WEATHER_BALL_TYPES = {
  raindance = "water",
  sandstorm = "rock",
  sunnyday = "fire",
  hail = "ice",
}

local function stepWeatherBall(ctx, frame)
  assert(type(ctx) == "table", "damage steps through the battle context")
  assert(type(frame) == "table", "damage steps from its move frame")
  local record = frame --[[@as table<string, unknown>]]
  local strike = strikeFactsOf(record)
  local power, moveType = strike.power, nil
  for _, weather in ipairs({ "raindance", "sandstorm", "sunnyday", "hail" }) do
    if ctx:fieldEffect(weather) ~= nil then
      power = strike.power * 2
      moveType = WEATHER_BALL_TYPES[weather]
    end
  end
  return runStriker(ctx, record, { power = power, moveType = moveType })
end

-- Natural Gift throws the held berry for its generated throw facts and
-- spends the holder even on a miss; empty or powerless holders fail.
-- Source references: BtlCmd_CalcNaturalGiftParams in
-- src/battle/battle_command.c and files/battledata/script/effect_script/
-- effect_script_0222.s.
local function stepNaturalGift(ctx, frame)
  assert(type(ctx) == "table", "damage steps through the battle context")
  assert(type(frame) == "table", "damage steps from its move frame")
  local record = frame --[[@as table<string, unknown>]]
  local key = record.executingMove --[[@as string]]
  local held = heldItemOf(record)
  if held == nil then
    return { kind = "complete", result = "failed" }
  end
  local facts = itemFactsOf(record)
  local entry = facts[held]
  if type(entry) ~= "table" then
    error(BattleErrors.missingBehavior("throw law reads its holder throw facts", { key = key, item = held }))
  end
  local gift = (entry --[[@as table<string, unknown>]]).naturalGift
  if type(gift) ~= "table" then
    error(BattleErrors.missingBehavior("throw law reads its holder throw facts", { key = key, item = held }))
  end
  local throw = gift --[[@as table<string, unknown>]]
  if
    type(throw.power) ~= "number"
    or throw.power --[[@as number]]
      % 1 ~= 0
    or throw.power --[[@as number]]
      < 1
    or type(throw.type) ~= "string"
    or throw.type --[[@as string]]
      == ""
  then
    return { kind = "complete", result = "failed" }
  end
  local outcome = runStriker(ctx, record, {
    power = throw.power --[[@as integer]],
    moveType = throw.type --[[@as string]],
  })
  ctx:consumeHeldItem(userOf(record))
  return outcome
end

-- Fling throws the held item for its generated fling power and spends
-- the holder even on a miss; powerless holders fail. Badly-poisoning
-- throw effects apply on a connecting hit through the usual substitute,
-- safeguard, and type gates; unmapped throw effects fail loudly.
-- Source references: TryFling in
-- src/battle/overlay_12_0224E4FC.c and files/battledata/script/
-- effect_script/effect_script_0233.s with
-- files/battledata/script/subscript/subscript_0220_Fling.s.
local FLING_EFFECTS = {
  [29] = "toxic",
}

local function stepFling(ctx, frame)
  assert(type(ctx) == "table", "damage steps through the battle context")
  assert(type(frame) == "table", "damage steps from its move frame")
  local record = frame --[[@as table<string, unknown>]]
  local key = record.executingMove --[[@as string]]
  local held = heldItemOf(record)
  if held == nil then
    return { kind = "complete", result = "failed" }
  end
  local facts = itemFactsOf(record)
  local entry = facts[held]
  if type(entry) ~= "table" then
    error(BattleErrors.missingBehavior("throw law reads its holder throw facts", { key = key, item = held }))
  end
  local throw = (entry --[[@as table<string, unknown>]]).fling
  if type(throw) ~= "table" then
    error(BattleErrors.missingBehavior("throw law reads its holder throw facts", { key = key, item = held }))
  end
  local flung = throw --[[@as table<string, unknown>]]
  if
    type(flung.power) ~= "number"
    or flung.power --[[@as number]]
      % 1 ~= 0
    or flung.power --[[@as number]]
      < 1
  then
    return { kind = "complete", result = "failed" }
  end
  if type(flung.effect) ~= "number" then
    error(BattleErrors.missingBehavior("throw law reads its holder fling effect", { key = key, item = held }))
  end
  local effect = FLING_EFFECTS[
    flung.effect --[[@as integer]]
  ]
  if effect == nil then
    error(BattleErrors.missingBehavior("throw law names a modeled fling effect", { key = key, item = held }))
  end
  local outcome = runStriker(ctx, record, {
    power = flung.power --[[@as integer]],
  })
  ctx:consumeHeldItem(userOf(record))
  if outcome.result == "hit" and effect == "toxic" then
    local defender = targetOf((record.targets --[[@as table<integer, unknown>]])[1])
    if not secondariesAllowed(ctx, record, defender) then
      return outcome
    end
    if safeguarded(ctx, defender) then
      return outcome
    end
    local locals = record.locals --[[@as table<string, unknown>]]
    local defenders = locals.defenderTypes --[[@as table<integer, unknown>]]
    if
      not statusTypeImmune(defenders[defender] --[[@as string[] ]], "toxic")
    then
      applySecondaryStatus(ctx, record, defender, "toxic")
    end
  end
  return outcome
end

-- Dream Eater only reaches sleeping targets without a live doll: the
-- source gate fails before any critical or damage work, and the
-- successful strike drains half dealt through the shared drain.
-- Source reference:
-- files/battledata/script/effect_script/effect_script_0008.s.
local function stepDreamEater(ctx, frame)
  assert(type(ctx) == "table", "damage steps through the battle context")
  assert(type(frame) == "table", "damage steps from its move frame")
  local record = frame --[[@as table<string, unknown>]]
  local defender = targetOf((record.targets --[[@as table<integer, unknown>]])[1])
  if ctx:hasBattleEffect(defender, "substitute") then
    return { kind = "complete", result = "failed" }
  end
  if ctx:statusOf(defender) ~= "sleep" then
    return { kind = "complete", result = "failed" }
  end
  return runStriker(ctx, record, { drain = true })
end

-- Struggle backlashes a quarter of user maximum health with no ability
-- suppression: the source computes from attacker maximum, never from
-- dealt damage, and performs no guard check. Source reference:
-- files/battledata/script/subscript/subscript_0043_Struggle.s.
local function stepStruggle(ctx, frame)
  assert(type(ctx) == "table", "damage steps through the battle context")
  assert(type(frame) == "table", "damage steps from its move frame")
  local record = frame --[[@as table<string, unknown>]]
  local outcome = runStriker(ctx, record, {})
  if outcome.result ~= "hit" then
    return outcome
  end
  local user = userOf(record)
  local ceiling = ctx:entryOf(user).maxHp
  if type(ceiling) ~= "number" or ceiling % 1 ~= 0 or ceiling < 1 then
    error(BattleErrors.missingBehavior("struggle reads its battle maximum health", {
      key = record.executingMove --[[@as string]],
      fact = "maxHp",
    }))
  end
  local recoil = math.floor(ceiling --[[@as integer]] / 4)
  if recoil < 1 then
    recoil = 1
  end
  ctx:damage(user, recoil, causeFor(record))
  ctx:emit("recoil", causeFor(record), { target = user, damage = recoil })
  return outcome
end

---@param key string damage move identity under binding
---@return fun(ctx: BattleContext, frame: table<string, unknown>): table<string, unknown> distinct per-move handler for the registry
local function bodyFor(key)
  if key == "BEAT_UP" then
    return bind(stepBeatUp)
  end
  if key == "DREAM_EATER" then
    return bind(stepDreamEater)
  end
  if key == "STRUGGLE" then
    return bind(stepStruggle)
  end
  if key == "LAST_RESORT" then
    return bind(stepLastResort)
  end
  if key == "WEATHER_BALL" then
    return bind(stepWeatherBall)
  end
  if key == "NATURAL_GIFT" then
    return bind(stepNaturalGift)
  end
  if key == "FLING" then
    return bind(stepFling)
  end
  if key == "HIDDEN_POWER" then
    return bind(stepHiddenPower)
  end
  if key == "PRESENT" then
    return bind(stepPresent)
  end
  if key == "SNORE" then
    return bind(stepSnore)
  end
  if key == "STOMP" then
    return bind(stepStomp)
  end
  if key == "WAKE_UP_SLAP" then
    return bind(stepWakeUpSlap)
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
  if key == "REVENGE" or key == "AVALANCHE" then
    return bind(stepRevenge)
  end
  if key == "PAYBACK" then
    return bind(stepPayback)
  end
  if key == "ASSURANCE" then
    return bind(stepAssurance)
  end
  if key == "BRINE" then
    return bind(stepBrine)
  end
  if key == "FACADE" then
    return bind(stepFacade)
  end
  if key == "COUNTER" then
    return bind(makeReaction("physical"))
  end
  if key == "MIRROR_COAT" then
    return bind(makeReaction("special"))
  end
  if key == "ERUPTION" or key == "WATER_SPOUT" then
    return bind(stepEruption)
  end
  if key == "FLAIL" or key == "REVERSAL" then
    return bind(stepFlail)
  end
  if key == "WRING_OUT" then
    return bind(stepWringOut)
  end
  if key == "GYRO_BALL" then
    return bind(stepGyroBall)
  end
  if OHKO[key] == true then
    return bind(stepOhko)
  end
  if GATED[key] == true then
    return bind(stepGated)
  end
  if key == "TRIPLE_KICK" then
    return bind(stepTripleKick)
  end
  if key == "DOUBLE_HIT" then
    return bind(makeStriker({ hits = 2, shareCritical = true }))
  end
  if key == "TWINEEDLE" then
    return bind(makeStriker({ hits = 2, shareCritical = true, secondaries = { { status = "poison" } } }))
  end
  if SAMPLED_25[key] == true then
    return bind(makeSampledHits(nil))
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
