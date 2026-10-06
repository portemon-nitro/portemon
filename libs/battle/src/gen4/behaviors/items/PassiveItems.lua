-- Passive held-item modifier families: type and stat boosters,
-- choice locks, accuracy and evasion items, and duration or escape
-- items that apply through current effective possession rather than the
-- original held key. Items with no battle hold effect -- field medicine,
-- battle-use goods, evolution goods, machines, key items, and unused
-- identities -- stay explicitly bound and silent, so their genuine
-- absence of effect never looks like an unimplemented binding.

local PassiveItems = {}

---@param instance table<string, unknown> dispatched effect instance under handling
---@return integer? holder combatant owning the instance
local function holderOf(instance)
  local scope = instance.scope
  if type(scope) ~= "table" then
    return nil
  end
  local combatant = (scope --[[@as table<string, unknown>]]).combatant
  if type(combatant) ~= "number" then
    return nil
  end
  return combatant
end

local TYPE_BOOST = {
  SOFT_SAND = { ground = true },
  HARD_STONE = { rock = true },
  MIRACLE_SEED = { grass = true },
  BLACKGLASSES = { dark = true },
  BLACK_BELT = { fighting = true },
  MAGNET = { electric = true },
  MYSTIC_WATER = { water = true },
  SHARP_BEAK = { flying = true },
  POISON_BARB = { poison = true },
  NEVERMELTICE = { ice = true },
  SPELL_TAG = { ghost = true },
  TWISTEDSPOON = { psychic = true },
  CHARCOAL = { fire = true },
  DRAGON_FANG = { dragon = true },
  SILK_SCARF = { normal = true },
  SILVERPOWDER = { bug = true },
  -- Metal Coat doubles as a Steel booster while evolving on trade:
  -- the ROM hold effect is STRENGTHEN_STEEL, so it boosts here
  -- instead of staying silent with the pure evolution goods.
  METAL_COAT = { steel = true },
  SEA_INCENSE = { water = true },
  ODD_INCENSE = { psychic = true },
  ROCK_INCENSE = { rock = true },
  WAVE_INCENSE = { water = true },
  ROSE_INCENSE = { grass = true },
  ADAMANT_ORB = { steel = true, dragon = true },
  LUSTROUS_ORB = { water = true, dragon = true },
  GRISEOUS_ORB = { dragon = true, ghost = true },
  FLAME_PLATE = { fire = true },
  SPLASH_PLATE = { water = true },
  ZAP_PLATE = { electric = true },
  MEADOW_PLATE = { grass = true },
  ICICLE_PLATE = { ice = true },
  FIST_PLATE = { fighting = true },
  TOXIC_PLATE = { poison = true },
  EARTH_PLATE = { ground = true },
  SKY_PLATE = { flying = true },
  MIND_PLATE = { psychic = true },
  INSECT_PLATE = { bug = true },
  STONE_PLATE = { rock = true },
  SPOOKY_PLATE = { ghost = true },
  DRACO_PLATE = { dragon = true },
  DREAD_PLATE = { dark = true },
  IRON_PLATE = { steel = true },
}

local STAT_BOOST = {
  SOUL_DEW = { specialAttack = true, specialDefense = true },
  THICK_CLUB = { attack = true },
  METAL_POWDER = { defense = true },
  QUICK_POWDER = { speed = true },
  DEEPSEATOOTH = { specialAttack = true },
  DEEPSEASCALE = { specialDefense = true },
}

-- Native holders for the species-locked boosters. Every other item
-- answers for any holder; a locked item without holder facts, with an
-- unlisted holder, or (for the origin orb) with a transformed holder
-- stays silent instead of boosting universally.
local SPECIES_LOCKED = {
  SOUL_DEW = { LATIAS = true, LATIOS = true },
  LIGHT_BALL = { PIKACHU = true },
  THICK_CLUB = { CUBONE = true, MAROWAK = true },
  METAL_POWDER = { DITTO = true },
  QUICK_POWDER = { DITTO = true },
  DEEPSEATOOTH = { CLAMPERL = true },
  DEEPSEASCALE = { CLAMPERL = true },
  ADAMANT_ORB = { DIALGA = true },
  LUSTROUS_ORB = { PALKIA = true },
  GRISEOUS_ORB = { GIRATINA = true },
}

---@param instance table<string, unknown> dispatched effect instance under handling
---@param context table<string, unknown> checkpoint context under handling
---@return boolean true when the holder may apply the item
local function holderApplies(instance, context)
  local allowed = SPECIES_LOCKED[instance.key]
  if allowed == nil then
    return true
  end
  local species = context.species
  if type(species) ~= "string" or allowed[species] ~= true then
    return false
  end
  if instance.key == "GRISEOUS_ORB" and context.transformed == true then
    return false
  end
  return true
end

local CHOICE_BOOST = {
  CHOICE_BAND = "attack",
  CHOICE_SPECS = "specialAttack",
  CHOICE_SCARF = "speed",
}

local CRIT_ITEM = {
  SCOPE_LENS = true,
  LUCKY_PUNCH = true,
  STICK = true,
}

local DURATION_ITEM = {
  LIGHT_CLAY = true,
  HEAT_ROCK = true,
  DAMP_ROCK = true,
  SMOOTH_ROCK = true,
  ICY_ROCK = true,
  GRIP_CLAW = true,
}

local ESCAPE_ITEM = {
  SMOKE_BALL = true,
  SHED_SHELL = true,
}

local HEAVY_ITEM = {
  MACHO_BRACE = true,
  IRON_BALL = true,
  -- Every power training item halves Speed while held: the native
  -- speed-halving list names all six beside Macho Brace and Iron Ball.
  POWER_BRACER = true,
  POWER_BELT = true,
  POWER_LENS = true,
  POWER_BAND = true,
  POWER_ANKLET = true,
  POWER_WEIGHT = true,
}

local LAGGING_ITEM = {
  LAGGING_TAIL = true,
  FULL_INCENSE = true,
}

local EVASION_ITEM = {
  BRIGHTPOWDER = true,
  LAX_INCENSE = true,
}

local FIELD_MEDICINE = {
  "POTION",
  "ANTIDOTE",
  "BURN_HEAL",
  "ICE_HEAL",
  "AWAKENING",
  "PARLYZ_HEAL",
  "FULL_RESTORE",
  "MAX_POTION",
  "HYPER_POTION",
  "SUPER_POTION",
  "FULL_HEAL",
  "REVIVE",
  "MAX_REVIVE",
  "FRESH_WATER",
  "SODA_POP",
  "LEMONADE",
  "MOOMOO_MILK",
  "ENERGYPOWDER",
  "ENERGY_ROOT",
  "HEAL_POWDER",
  "REVIVAL_HERB",
  "ETHER",
  "MAX_ETHER",
  "ELIXIR",
  "MAX_ELIXIR",
  "LAVA_COOKIE",
  "SACRED_ASH",
  "HP_UP",
  "PROTEIN",
  "IRON",
  "CARBOS",
  "CALCIUM",
  "RARE_CANDY",
  "PP_UP",
  "ZINC",
  "PP_MAX",
  "OLD_GATEAU",
}

local BATTLE_USE_ONLY = {
  "GUARD_SPEC_",
  "DIRE_HIT",
  "X_ATTACK",
  "X_DEFENSE",
  "X_SPEED",
  "X_ACCURACY",
  "X_SPECIAL",
  "X_SP__DEF",
  "POKE_DOLL",
  "FLUFFY_TAIL",
  "BLUE_FLUTE",
  "YELLOW_FLUTE",
  "RED_FLUTE",
  "BLACK_FLUTE",
  "WHITE_FLUTE",
}

local FIELD_ONLY = {
  "SHOAL_SALT",
  "SHOAL_SHELL",
  "RED_SHARD",
  "BLUE_SHARD",
  "YELLOW_SHARD",
  "GREEN_SHARD",
  "SUPER_REPEL",
  "MAX_REPEL",
  "ESCAPE_ROPE",
  "REPEL",
  "HEART_SCALE",
  "HONEY",
  "TINYMUSHROOM",
  "BIG_MUSHROOM",
  "PEARL",
  "BIG_PEARL",
  "STARDUST",
  "STAR_PIECE",
  "NUGGET",
  "RARE_BONE",
  "GROWTH_MULCH",
  "DAMP_MULCH",
  "STABLE_MULCH",
  "GOOEY_MULCH",
}

local EVOLUTION_GOODS = {
  "SUN_STONE",
  "MOON_STONE",
  "FIRE_STONE",
  "THUNDERSTONE",
  "WATER_STONE",
  "LEAF_STONE",
  "SHINY_STONE",
  "DUSK_STONE",
  "DAWN_STONE",
  "OVAL_STONE",
  "ODD_KEYSTONE",
  "ROOT_FOSSIL",
  "CLAW_FOSSIL",
  "HELIX_FOSSIL",
  "DOME_FOSSIL",
  "OLD_AMBER",
  "ARMOR_FOSSIL",
  "SKULL_FOSSIL",
  "PROTECTOR",
  "ELECTIRIZER",
  "MAGMARIZER",
  "DUBIOUS_DISC",
  "REAPER_CLOTH",
  "DRAGON_SCALE",
  "UPGRADE",
}

local CONTEST_SCARVES = {
  "RED_SCARF",
  "BLUE_SCARF",
  "PINK_SCARF",
  "GREEN_SCARF",
  "YELLOW_SCARF",
}

-- Power training items halve Speed while held (see HEAVY_ITEM above)
-- and add effort bonuses through the effort owner, so they carry no
-- silent binding here: silence would overwrite their speed handler at
-- registration.

local PROGRESSION_ONLY = {
  "EXP__SHARE",
  "LUCKY_EGG",
  "AMULET_COIN",
  "SOOTHE_BELL",
  "LUCK_INCENSE",
  "PURE_INCENSE",
  "CLEANSE_TAG",
  "EVERSTONE",
}

local KEY_ITEMS = {
  "LOOT_SACK",
  "RULE_BOOK",
  "POKE_RADAR",
  "POINT_CARD",
  "JOURNAL",
  "SEAL_CASE",
  "FASHION_CASE",
  "SEAL_BAG",
  "PAL_PAD",
  "WORKS_KEY",
  "OLD_CHARM",
  "GALACTIC_KEY",
  "RED_CHAIN",
  "TOWN_MAP",
  "VS__SEEKER",
  "COIN_CASE",
  "OLD_ROD",
  "GOOD_ROD",
  "SUPER_ROD",
  "SPRAYDUCK",
  "POFFIN_CASE",
  "BICYCLE",
  "SUITE_KEY",
  "OAKS_LETTER",
  "LUNAR_WING",
  "MEMBER_CARD",
  "AZURE_FLUTE",
  "S_S__TICKET",
  "CONTEST_PASS",
  "MAGMA_STONE",
  "PARCEL",
  "COUPON_1",
  "COUPON_2",
  "COUPON_3",
  "STORAGE_KEY",
  "SECRETPOTION",
  "VS__RECORDER",
  "GRACIDEA",
  "SECRET_KEY",
  "APRICORN_BOX",
  "UNOWN_REPORT",
  "BERRY_POTS",
  "DOWSING_MCHN",
  "BLUE_CARD",
  "SLOWPOKETAIL",
  "CLEAR_BELL",
  "CARD_KEY",
  "BASEMENT_KEY",
  "SQUIRTBOTTLE",
  "RED_SCALE",
  "LOST_ITEM",
  "PASS",
  "MACHINE_PART",
  "SILVER_WING",
  "RAINBOW_WING",
  "MYSTERY_EGG",
  "RED_APRICORN",
  "YLW_APRICORN",
  "BLU_APRICORN",
  "GRN_APRICORN",
  "PNK_APRICORN",
  "WHT_APRICORN",
  "BLK_APRICORN",
  "EXPLORER_KIT",
  "PHOTO_ALBUM",
  "GB_SOUNDS",
  "TIDAL_BELL",
  "RAGECANDYBAR",
  "JADE_ORB",
  "LOCK_CAPSULE",
  "RED_ORB",
  "BLUE_ORB",
  "ENIGMA_STONE",
}

---@param instance table<string, unknown> dispatched effect instance under handling
---@param context table<string, unknown> damage context under handling
---@return table<string, unknown>? boost announcement, or nil when inapplicable
local function typeBoost(instance, context)
  local boosted = TYPE_BOOST[instance.key]
  if type(boosted) ~= "table" then
    return nil
  end
  if not holderApplies(instance, context) then
    return nil
  end
  if type(context.moveType) ~= "string" then
    return nil
  end
  if
    (boosted --[[@as table<string, boolean>]])[context.moveType] ~= true
  then
    return nil
  end
  return { kind = "trigger", key = instance.key, combatant = holderOf(instance), power = "boosted" }
end

---@param instance table<string, unknown> dispatched effect instance under handling
---@param context table<string, unknown> stat checkpoint context under handling
---@return table<string, unknown>? boost announcement, or nil when inapplicable
local function statBoost(instance, context)
  local boosted = STAT_BOOST[instance.key]
  if type(boosted) ~= "table" then
    return nil
  end
  if not holderApplies(instance, context) then
    return nil
  end
  -- Soul Dew answers outside the frontier only: frontier formats
  -- suppress both the special attack and the special defense boost.
  if instance.key == "SOUL_DEW" and context.frontier == true then
    return nil
  end
  if type(context.stat) ~= "string" then
    return nil
  end
  if
    (boosted --[[@as table<string, boolean>]])[context.stat] ~= true
  then
    return nil
  end
  return {
    kind = "trigger",
    key = instance.key,
    combatant = holderOf(instance),
    stat = context.stat,
    stages = "boosted",
  }
end

---@param instance table<string, unknown> dispatched effect instance under handling
---@param context table<string, unknown> damage context under handling
---@return table<string, unknown>? boost announcement, or nil when inapplicable
local function pikaPower(instance, context)
  -- Light Ball doubles move power for Pikachu rather than staging
  -- stats: the native strike multiplies power, so the handler
  -- announces power with only the species gate.
  if not holderApplies(instance, context) then
    return nil
  end
  return { kind = "trigger", key = instance.key, combatant = holderOf(instance), power = "boosted" }
end

---@param instance table<string, unknown> dispatched effect instance under handling
---@param context table<string, unknown> move context under handling
---@return table<string, unknown>? lock announcement, or nil when inapplicable
local function choiceLock(instance, context)
  local stat = CHOICE_BOOST[instance.key]
  if stat == nil then
    return nil
  end
  if context.moveUse == nil then
    return nil
  end
  return {
    kind = "trigger",
    key = instance.key,
    combatant = holderOf(instance),
    stat = stat,
    stages = "boosted",
    locked = true,
  }
end

---@param instance table<string, unknown> dispatched effect instance under handling
---@param context table<string, unknown> damage context under handling
---@return table<string, unknown>? recoil announcement, or nil when inapplicable
local function lifeOrb(instance, context)
  if context.dealtDamage ~= true then
    return nil
  end
  return { kind = "trigger", key = instance.key, combatant = holderOf(instance), recoil = true }
end

---@param instance table<string, unknown> dispatched effect instance under handling
---@param context table<string, unknown> damage context under handling
---@return table<string, unknown>? boost announcement, or nil when inapplicable
local function expertBelt(instance, context)
  if context.superEffective ~= true then
    return nil
  end
  return { kind = "trigger", key = instance.key, combatant = holderOf(instance), power = "boosted" }
end

---@param instance table<string, unknown> dispatched effect instance under handling
---@param context table<string, unknown> damage context under handling
---@return table<string, unknown>? boost announcement, or nil when inapplicable
local function muscleBand(instance, context)
  if context.split ~= "physical" then
    return nil
  end
  return { kind = "trigger", key = instance.key, combatant = holderOf(instance), power = "boosted" }
end

---@param instance table<string, unknown> dispatched effect instance under handling
---@param context table<string, unknown> damage context under handling
---@return table<string, unknown>? boost announcement, or nil when inapplicable
local function wiseGlasses(instance, context)
  if context.split ~= "special" then
    return nil
  end
  return { kind = "trigger", key = instance.key, combatant = holderOf(instance), power = "boosted" }
end

---@param instance table<string, unknown> dispatched effect instance under handling
---@param context table<string, unknown> accuracy context under handling
---@return table<string, unknown>? critical announcement, or nil when inapplicable
local function critItem(instance, context)
  if CRIT_ITEM[instance.key] ~= true then
    return nil
  end
  if context.criticalCheck ~= true then
    return nil
  end
  return { kind = "trigger", key = instance.key, combatant = holderOf(instance), critical = "boosted" }
end

---@param instance table<string, unknown> dispatched effect instance under handling
---@param context table<string, unknown> accuracy context under handling
---@return table<string, unknown>? accuracy announcement, or nil when inapplicable
local function wideLens(instance, context)
  if context.accuracyCheck ~= true then
    return nil
  end
  return { kind = "trigger", key = instance.key, combatant = holderOf(instance), accuracy = "boosted" }
end

---@param instance table<string, unknown> dispatched effect instance under handling
---@param context table<string, unknown> accuracy context under handling
---@return table<string, unknown>? accuracy announcement, or nil when inapplicable
local function zoomLens(instance, context)
  if context.accuracyCheck ~= true then
    return nil
  end
  if context.movedLast ~= true then
    return nil
  end
  return { kind = "trigger", key = instance.key, combatant = holderOf(instance), accuracy = "boosted" }
end

---@param instance table<string, unknown> dispatched effect instance under handling
---@param context table<string, unknown> accuracy context under handling
---@return table<string, unknown>? evasion announcement, or nil when inapplicable
local function evasionItem(instance, context)
  if EVASION_ITEM[instance.key] ~= true then
    return nil
  end
  if context.accuracyCheck ~= true then
    return nil
  end
  return { kind = "trigger", key = instance.key, combatant = holderOf(instance), evasion = "boosted" }
end

---@param instance table<string, unknown> dispatched effect instance under handling
---@param context table<string, unknown> stat checkpoint context under handling
---@return table<string, unknown>? weight announcement, or nil when inapplicable
local function heavyItem(instance, context)
  if HEAVY_ITEM[instance.key] ~= true then
    return nil
  end
  if context.stat ~= "speed" then
    return nil
  end
  return { kind = "trigger", key = instance.key, combatant = holderOf(instance), stat = "speed", stages = "halved" }
end

---@param instance table<string, unknown> dispatched effect instance under handling
---@param context table<string, unknown> move context under handling
---@return table<string, unknown>? order announcement, or nil when inapplicable
local function laggingItem(instance, context)
  if LAGGING_ITEM[instance.key] ~= true then
    return nil
  end
  if context.moveUse == nil then
    return nil
  end
  return { kind = "trigger", key = instance.key, combatant = holderOf(instance), order = "last" }
end

---@param instance table<string, unknown> dispatched effect instance under handling
---@param context table<string, unknown> damage context under handling
---@return table<string, unknown>? drain announcement, or nil when inapplicable
local function bigRoot(instance, context)
  -- Big Root boosts stolen health beyond direct drains: leech recovery
  -- answers beside the draining strike through the same boost.
  if context.drain ~= true and context.leech ~= true then
    return nil
  end
  return { kind = "trigger", key = instance.key, combatant = holderOf(instance), drain = "boosted" }
end

---@param instance table<string, unknown> dispatched effect instance under handling
---@param context table<string, unknown> damage context under handling
---@return table<string, unknown>? streak announcement, or nil when inapplicable
local function metronome(instance, context)
  -- The metronome item scales from the second consecutive use: the
  -- first repetition multiplies ten over ten, so only a real streak
  -- boosts.
  local streak = context.consecutiveUses
  if type(streak) ~= "number" or streak < 2 then
    return nil
  end
  return { kind = "trigger", key = instance.key, combatant = holderOf(instance), power = "boosted" }
end

---@param instance table<string, unknown> dispatched effect instance under handling
---@param context table<string, unknown> field context under handling
---@return table<string, unknown>? duration announcement, or nil when inapplicable
local function durationItem(instance, context)
  if DURATION_ITEM[instance.key] ~= true then
    return nil
  end
  if context.fieldEffectStart ~= true then
    return nil
  end
  return { kind = "trigger", key = instance.key, combatant = holderOf(instance), duration = "extended" }
end

---@param instance table<string, unknown> dispatched effect instance under handling
---@param context table<string, unknown> escape context under handling
---@return table<string, unknown>? escape announcement, or nil when inapplicable
local function escapeItem(instance, context)
  if ESCAPE_ITEM[instance.key] ~= true then
    return nil
  end
  if context.flee ~= true then
    return nil
  end
  return { kind = "trigger", key = instance.key, combatant = holderOf(instance), escape = "assured" }
end

--- Items with no battle hold effect stay bound and silent, so coverage
--- distinguishes their genuine absence of effect from an unimplemented
--- binding.
---@param instance table<string, unknown> dispatched effect instance under handling
---@param context table<string, unknown> pass context under handling
---@return nil always silent
local function silentItem(instance, context)
  assert(type(instance) == "table", "passive items read their instance")
  assert(type(context) == "table", "passive items read their pass context")
  return nil
end

---@param owned table<string, fun(instance: table<string, unknown>, context: table<string, unknown>): table<string, unknown>?> handler owner receiving the family bindings
---@param keys string[] item keys sharing one handler
---@param handler fun(instance: table<string, unknown>, context: table<string, unknown>): table<string, unknown>? shared handler for the group
local function bindGroup(owned, keys, handler)
  for _, key in ipairs(keys) do
    owned[key] = handler
  end
end

--- Binds the held-item modifier handlers into the owner table.
---@param owned table<string, fun(instance: table<string, unknown>, context: table<string, unknown>): table<string, unknown>?> handler owner receiving the family bindings
function PassiveItems.register(owned)
  assert(type(owned) == "table", "passive items register into their owner table")
  for key in pairs(TYPE_BOOST) do
    owned[key] = typeBoost
  end
  for key in pairs(STAT_BOOST) do
    owned[key] = statBoost
  end
  for key in pairs(CHOICE_BOOST) do
    owned[key] = choiceLock
  end
  for key in pairs(CRIT_ITEM) do
    owned[key] = critItem
  end
  for key in pairs(DURATION_ITEM) do
    owned[key] = durationItem
  end
  for key in pairs(ESCAPE_ITEM) do
    owned[key] = escapeItem
  end
  for key in pairs(HEAVY_ITEM) do
    owned[key] = heavyItem
  end
  for key in pairs(LAGGING_ITEM) do
    owned[key] = laggingItem
  end
  for key in pairs(EVASION_ITEM) do
    owned[key] = evasionItem
  end
  owned.LIFE_ORB = lifeOrb
  owned.LIGHT_BALL = pikaPower
  owned.EXPERT_BELT = expertBelt
  owned.MUSCLE_BAND = muscleBand
  owned.WISE_GLASSES = wiseGlasses
  owned.WIDE_LENS = wideLens
  owned.ZOOM_LENS = zoomLens
  owned.BIG_ROOT = bigRoot
  owned.METRONOME = metronome
  bindGroup(owned, FIELD_MEDICINE, silentItem)
  bindGroup(owned, BATTLE_USE_ONLY, silentItem)
  bindGroup(owned, FIELD_ONLY, silentItem)
  bindGroup(owned, EVOLUTION_GOODS, silentItem)
  bindGroup(owned, CONTEST_SCARVES, silentItem)
  bindGroup(owned, PROGRESSION_ONLY, silentItem)
  bindGroup(owned, KEY_ITEMS, silentItem)
  for machine = 1, 92 do
    owned[string.format("TM%02d", machine)] = silentItem
  end
  for machine = 1, 8 do
    owned[string.format("HM%02d", machine)] = silentItem
  end
  for card = 1, 27 do
    owned[string.format("DATA_CARD_%02d", card)] = silentItem
  end
  owned.NONE = silentItem
  for unused = 113, 134 do
    owned["UNUSED_" .. unused] = silentItem
  end
end

return PassiveItems
