-- Triggered held-item families: consumable and reactive responses
-- with exact event and consumption order. Berries answer low-health,
-- status, and pinch checkpoints; sashes, bands, orbs, and on-hit items
-- answer their own lethal, residual, and damage triggers. Consumption
-- itself is recorded through the held-item history owner, so later use
-- keeps the earlier spend on record for restoring formats. Items with no
-- battle hold effect stay explicitly bound and silent.

local TriggeredItems = {}

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

---@param context table<string, unknown> residual context under handling
---@param holder integer? holder combatant under handling
---@return integer? live health, or nil when unreadable
---@return integer? maximum health, or nil when unreadable
local function holderHealth(context, holder)
  if holder == nil then
    return nil, nil
  end
  local health = context.health
  local limits = context.maxHealth
  if type(health) ~= "table" or type(limits) ~= "table" then
    return nil, nil
  end
  local hp = (health --[[@as table<integer, integer>]])[holder]
  local maxHp = (limits --[[@as table<integer, integer>]])[holder]
  if type(hp) ~= "number" or type(maxHp) ~= "number" then
    return nil, nil
  end
  return hp, maxHp
end

---@param stream unknown candidate battle stream under inspection
---@return boolean true when the stream accepts labeled draws
local function canDraw(stream)
  return type(stream) == "table" and type((stream --[[@as table<string, unknown>]]).nextU16) == "function"
end

-- Pinch-check divisor for the quarter-health berry family. Gluttony
-- holders eat those berries at half health instead, while the
-- half-health flavor family keeps its own gate either way.
local PINCH_DIVISOR = 4
local GLUTTONY_DIVISOR = 2

---@param context table<string, unknown> residual context under handling
---@return integer hp divisor for quarter-family pinch checks
local function pinchDivisor(context)
  if context.ability == "GLUTTONY" then
    return GLUTTONY_DIVISOR
  end
  return PINCH_DIVISOR
end

local HP_BERRY = {
  ORAN_BERRY = true,
  SITRUS_BERRY = true,
  BERRY_JUICE = true,
}

local STATUS_BERRY = {
  CHERI_BERRY = "paralysis",
  CHESTO_BERRY = "sleep",
  PECHA_BERRY = "poison",
  RAWST_BERRY = "burn",
  ASPEAR_BERRY = "freeze",
  PERSIM_BERRY = "confusion",
  LUM_BERRY = "any",
}

local PINCH_RESTORE = {
  FIGY_BERRY = true,
  WIKI_BERRY = true,
  MAGO_BERRY = true,
  AGUAV_BERRY = true,
  IAPAPA_BERRY = true,
}

local PINCH_STAT = {
  LIECHI_BERRY = "attack",
  GANLON_BERRY = "defense",
  SALAC_BERRY = "speed",
  PETAYA_BERRY = "specialAttack",
  APICOT_BERRY = "specialDefense",
  LANSAT_BERRY = "critical",
  STARF_BERRY = "random",
}

local RESIST_BERRY = {
  OCCA_BERRY = "fire",
  PASSHO_BERRY = "water",
  WACAN_BERRY = "electric",
  RINDO_BERRY = "grass",
  YACHE_BERRY = "ice",
  CHOPLE_BERRY = "fighting",
  KEBIA_BERRY = "poison",
  SHUCA_BERRY = "ground",
  COBA_BERRY = "flying",
  PAYAPA_BERRY = "psychic",
  TANGA_BERRY = "bug",
  CHARTI_BERRY = "rock",
  KASIB_BERRY = "ghost",
  HABAN_BERRY = "dragon",
  COLBUR_BERRY = "dark",
  BABIRI_BERRY = "steel",
  CHILAN_BERRY = "normal",
}

local SILENT_BERRY = {
  "RAZZ_BERRY",
  "BLUK_BERRY",
  "NANAB_BERRY",
  "WEPEAR_BERRY",
  "PINAP_BERRY",
  "POMEG_BERRY",
  "KELPSY_BERRY",
  "QUALOT_BERRY",
  "HONDEW_BERRY",
  "GREPA_BERRY",
  "TAMATO_BERRY",
  "CORNN_BERRY",
  "MAGOST_BERRY",
  "RABUTA_BERRY",
  "NOMEL_BERRY",
  "SPELON_BERRY",
  "PAMTRE_BERRY",
  "WATMEL_BERRY",
  "DURIN_BERRY",
  "BELUE_BERRY",
}

--- Restores a quarter of maximum health once the holder drops to half
--- or below; healthy holders keep the item without failing. The
--- announcement carries the exact restoration and the spend, so live
--- checkpoints apply and consume without re-reading the berry identity.
---@param instance table<string, unknown> dispatched effect instance under handling
---@param context table<string, unknown> residual context under handling
---@return table<string, unknown>? recovery announcement, or nil when inapplicable
local function hpBerry(instance, context)
  if HP_BERRY[instance.key] ~= true then
    return nil
  end
  local hp, maxHp = holderHealth(context, holderOf(instance))
  if hp == nil or maxHp == nil then
    return nil
  end
  if
    hp <= 0 or hp * 2 > maxHp --[[@as integer]]
  then
    return nil
  end
  return {
    kind = "trigger",
    key = instance.key,
    combatant = holderOf(instance),
    recovered = true,
    restored = math.floor(maxHp --[[@as integer]] / 4),
    consumed = true,
  }
end

---@param instance table<string, unknown> dispatched effect instance under handling
---@param context table<string, unknown> status context under handling
---@return table<string, unknown>? cure announcement, or nil when inapplicable
local function statusBerry(instance, context)
  local cured = STATUS_BERRY[instance.key]
  if cured == nil then
    return nil
  end
  -- Lum answers volatile confusion beside major status, and Persim
  -- answers the confusion volatile itself: the native scripts read
  -- the confusion flag next to the major condition.
  if cured == "any" then
    local status = context.status
    if type(status) == "string" then
      return { kind = "trigger", key = instance.key, combatant = holderOf(instance), cured = status }
    end
    if context.confusion == true then
      return { kind = "trigger", key = instance.key, combatant = holderOf(instance), cured = "confusion" }
    end
    return nil
  end
  if cured == "confusion" then
    if context.confusion == true or context.status == "confusion" then
      return { kind = "trigger", key = instance.key, combatant = holderOf(instance), cured = "confusion" }
    end
    return nil
  end
  local status = context.status
  if type(status) ~= "string" then
    return nil
  end
  if status ~= cured then
    return nil
  end
  return { kind = "trigger", key = instance.key, combatant = holderOf(instance), cured = status }
end

---@param context table<string, unknown> residual context under handling
---@param stat string boosted stat under the cap check
---@return boolean true when the stat already sits at its stage cap
local function stageMaxed(context, stat)
  local stages = context.statStages
  if type(stages) ~= "table" then
    return false
  end
  local stage = (stages --[[@as table<string, unknown>]])[stat]
  return type(stage) == "number" and stage --[[@as integer]] >= 6
end

-- Pinch order behind the Starf draw: attack, defense, speed, special
-- attack, special defense, matching the native stat-change indices.
local PINCH_ORDER = { "attack", "defense", "speed", "specialAttack", "specialDefense" }

---@param instance table<string, unknown> dispatched effect instance under handling
---@param context table<string, unknown> residual context under handling
---@param holder integer holder combatant under handling
---@return table<string, unknown>? pinch announcement, or nil when inapplicable
local function starfBerry(instance, context, holder)
  -- Starf refuses a fully maxed holder, then draws its sharply raised
  -- stat across the stats still below the cap.
  local raised = {} ---@type string[]
  for _, stat in ipairs(PINCH_ORDER) do
    if not stageMaxed(context, stat) then
      raised[#raised + 1] = stat
    end
  end
  if #raised == 0 then
    return nil
  end
  local stream = context.stream
  if not canDraw(stream) then
    return nil
  end
  local draw = (stream --[[@as table<string, unknown>]]).nextU16
  local value = (draw --[[@as fun(self: unknown, label: string, cause: table<string, unknown>): integer]])(
    stream,
    "starf_stat",
    { kind = "held_item", key = instance.key }
  )
  local picked = raised[(value % #raised) + 1]
  return { kind = "trigger", key = instance.key, combatant = holder, stat = picked, stages = "sharply-boosted" }
end

---@param instance table<string, unknown> dispatched effect instance under handling
---@param context table<string, unknown> residual context under handling
---@return table<string, unknown>? pinch announcement, or nil when inapplicable
local function pinchBerry(instance, context)
  local holder = holderOf(instance)
  if holder == nil then
    return nil
  end
  local hp, maxHp = holderHealth(context, holder)
  if hp == nil or maxHp == nil then
    return nil
  end
  if hp <= 0 then
    return nil
  end
  if PINCH_RESTORE[instance.key] == true then
    if
      hp * 2 > maxHp --[[@as integer]]
    then
      return nil
    end
    -- A disliked flavor confuses instead of healing: the native
    -- script runs the dislike branch from personality. The eaten
    -- berry is spent either way.
    if context.dislikedFlavor == true then
      return { kind = "trigger", key = instance.key, combatant = holder, confused = true, consumed = true }
    end
    return {
      kind = "trigger",
      key = instance.key,
      combatant = holder,
      recovered = true,
      restored = math.floor(maxHp --[[@as integer]] / 8),
      consumed = true,
    }
  end
  local stat = PINCH_STAT[instance.key]
  if stat == nil then
    return nil
  end
  if
    hp * pinchDivisor(context) > maxHp --[[@as integer]]
  then
    return nil
  end
  -- Lansat refuses a focused holder; Starf draws its sharply raised
  -- stat; every other stat berry refuses a maxed stat.
  if instance.key == "LANSAT_BERRY" then
    if context.focused == true then
      return nil
    end
    return { kind = "trigger", key = instance.key, combatant = holder, stat = stat, stages = "boosted" }
  end
  if instance.key == "STARF_BERRY" then
    return starfBerry(instance, context, holder)
  end
  if stageMaxed(context, stat) then
    return nil
  end
  return { kind = "trigger", key = instance.key, combatant = holder, stat = stat, stages = "boosted" }
end

---@param instance table<string, unknown> dispatched effect instance under handling
---@param context table<string, unknown> damage context under handling
---@return table<string, unknown>? resistance announcement, or nil when inapplicable
local function resistBerry(instance, context)
  local warded = RESIST_BERRY[instance.key]
  if warded == nil then
    return nil
  end
  -- Chilan answers normal-type hits with no effectiveness gate: the
  -- native weaken-normal script skips the super-effective check the
  -- resist family requires.
  if instance.key == "CHILAN_BERRY" then
    if context.moveType ~= "normal" then
      return nil
    end
    return { kind = "trigger", key = instance.key, combatant = holderOf(instance), resisted = true }
  end
  if context.moveType ~= warded or context.superEffective ~= true then
    return nil
  end
  return { kind = "trigger", key = instance.key, combatant = holderOf(instance), resisted = true }
end

---@param instance table<string, unknown> dispatched effect instance under handling
---@param context table<string, unknown> move context under handling
---@return table<string, unknown>? restore announcement, or nil when inapplicable
local function leppaBerry(instance, context)
  if context.ppZero ~= true then
    return nil
  end
  return { kind = "trigger", key = instance.key, combatant = holderOf(instance), restored = true }
end

---@param instance table<string, unknown> dispatched effect instance under handling
---@param context table<string, unknown> damage context under handling
---@return table<string, unknown>? recovery announcement, or nil when inapplicable
local function enigmaBerry(instance, context)
  if context.superEffective ~= true then
    return nil
  end
  return { kind = "trigger", key = instance.key, combatant = holderOf(instance), recovered = true }
end

---@param instance table<string, unknown> dispatched effect instance under handling
---@param context table<string, unknown> residual context under handling
---@return table<string, unknown>? accuracy announcement, or nil when inapplicable
local function micleBerry(instance, context)
  local hp, maxHp = holderHealth(context, holderOf(instance))
  if hp == nil or maxHp == nil then
    return nil
  end
  if
    hp <= 0 or hp * pinchDivisor(context) > maxHp --[[@as integer]]
  then
    return nil
  end
  -- Micle defers its boost to the following accuracy check: the native
  -- flag multiplies the next move, so the announcement arms the next
  -- check rather than applying an immediate boost.
  return { kind = "trigger", key = instance.key, combatant = holderOf(instance), accuracyNext = true }
end

---@param instance table<string, unknown> dispatched effect instance under handling
---@param context table<string, unknown> move context under handling
---@return table<string, unknown>? priority announcement, or nil when inapplicable
local function custapBerry(instance, context)
  if context.moveUse == nil then
    return nil
  end
  local hp, maxHp = holderHealth(context, holderOf(instance))
  if hp == nil or maxHp == nil then
    return nil
  end
  if
    hp <= 0 or hp * pinchDivisor(context) > maxHp --[[@as integer]]
  then
    return nil
  end
  -- The pinch berry is spent as it moves the holder first: order
  -- checkpoints consume beside reordering, later checkpoints see the
  -- empty holding.
  return { kind = "trigger", key = instance.key, combatant = holderOf(instance), order = "first", consumed = true }
end

---@param instance table<string, unknown> dispatched effect instance under handling
---@param context table<string, unknown> damage context under handling
---@return table<string, unknown>? recoil announcement, or nil when inapplicable
local function jabocaBerry(instance, context)
  if instance.key ~= "JABOCA_BERRY" and instance.key ~= "ROWAP_BERRY" then
    return nil
  end
  if context.dealtDamage ~= true then
    return nil
  end
  if instance.key == "JABOCA_BERRY" and context.split ~= "physical" then
    return nil
  end
  if instance.key == "ROWAP_BERRY" and context.split ~= "special" then
    return nil
  end
  return { kind = "trigger", key = instance.key, combatant = holderOf(instance), recoil = true }
end

--- Recovers a sixteenth of maximum health at the end of the turn while
--- hurt; full health stays silent without failing. The holding
--- persists: only the restoration travels, never a spend.
---@param instance table<string, unknown> dispatched effect instance under handling
---@param context table<string, unknown> residual context under handling
---@return table<string, unknown>? recovery announcement, or nil when inapplicable
local function leftovers(instance, context)
  local hp, maxHp = holderHealth(context, holderOf(instance))
  if hp == nil or maxHp == nil then
    return nil
  end
  if
    hp <= 0 or hp >= maxHp --[[@as integer]]
  then
    return nil
  end
  return {
    kind = "trigger",
    key = instance.key,
    combatant = holderOf(instance),
    recovered = true,
    restored = math.floor(maxHp --[[@as integer]] / 16),
  }
end

---@param instance table<string, unknown> dispatched effect instance under handling
---@param context table<string, unknown> residual context under handling
---@return table<string, unknown>? sludge announcement, or nil when inapplicable
local function blackSludge(instance, context)
  local hp = holderHealth(context, holderOf(instance))
  if
    hp == nil
    or hp --[[@as integer]]
      <= 0
  then
    return nil
  end
  if context.isPoisonType == true then
    local _, maxHp = holderHealth(context, holderOf(instance))
    if
      maxHp == nil
      or hp --[[@as integer]]
        >= maxHp --[[@as integer]]
    then
      return nil
    end
    return { kind = "trigger", key = instance.key, combatant = holderOf(instance), recovered = true }
  end
  return { kind = "trigger", key = instance.key, combatant = holderOf(instance), harmed = true }
end

---@param instance table<string, unknown> dispatched effect instance under handling
---@param context table<string, unknown> damage context under handling
---@return table<string, unknown>? recovery announcement, or nil when inapplicable
local function shellBell(instance, context)
  if context.dealtDamage ~= true then
    return nil
  end
  return { kind = "trigger", key = instance.key, combatant = holderOf(instance), recovered = true }
end

---@param instance table<string, unknown> dispatched effect instance under handling
---@param context table<string, unknown> residual context under handling
---@return table<string, unknown>? barb announcement, or nil when inapplicable
local function stickyBarb(instance, context)
  if context.contact == true then
    return { kind = "trigger", key = instance.key, combatant = holderOf(instance), passesOn = true }
  end
  if context.moveType ~= nil then
    return nil
  end
  local hp = holderHealth(context, holderOf(instance))
  if
    hp == nil
    or hp --[[@as integer]]
      <= 0
  then
    return nil
  end
  return { kind = "trigger", key = instance.key, combatant = holderOf(instance), harmed = true }
end

---@param instance table<string, unknown> dispatched effect instance under handling
---@param context table<string, unknown> residual context under handling
---@return table<string, unknown>? orb announcement, or nil when inapplicable
local function statusOrb(instance, context)
  if context.status ~= nil then
    return nil
  end
  if instance.key == "TOXIC_ORB" then
    return { kind = "trigger", key = instance.key, combatant = holderOf(instance), inflicted = "toxic" }
  end
  if instance.key == "FLAME_ORB" then
    return { kind = "trigger", key = instance.key, combatant = holderOf(instance), inflicted = "burn" }
  end
  return nil
end

---@param instance table<string, unknown> dispatched effect instance under handling
---@param context table<string, unknown> damage context under handling
---@return table<string, unknown>? endurance announcement, or nil when inapplicable
local function focusSash(instance, context)
  if context.lethal ~= true then
    return nil
  end
  local hp, maxHp = holderHealth(context, holderOf(instance))
  if hp == nil or maxHp == nil then
    return nil
  end
  if
    hp --[[@as integer]]
    ~= maxHp --[[@as integer]]
  then
    return nil
  end
  return { kind = "trigger", key = instance.key, combatant = holderOf(instance), endured = true }
end

---@param instance table<string, unknown> dispatched effect instance under handling
---@param context table<string, unknown> damage context under handling
---@return table<string, unknown>? endurance announcement, or nil when inapplicable
local function focusBand(instance, context)
  if context.lethal ~= true then
    return nil
  end
  local stream = context.stream
  if not canDraw(stream) then
    return nil
  end
  local draw = (stream --[[@as table<string, unknown>]]).nextU16
  local value = (draw --[[@as fun(self: unknown, label: string, cause: table<string, unknown>): integer]])(
    stream,
    "focus_band",
    { kind = "held_item", key = instance.key }
  )
  if value >= 6554 then
    return nil
  end
  return { kind = "trigger", key = instance.key, combatant = holderOf(instance), endured = true }
end

---@param instance table<string, unknown> dispatched effect instance under handling
---@param context table<string, unknown> move context under handling
---@return table<string, unknown>? priority announcement, or nil when inapplicable
local function quickClaw(instance, context)
  if context.moveUse == nil then
    return nil
  end
  -- The live turn samples the raw order value before decisions and
  -- hands it here: a supplied sample answers on multiples of five
  -- with no battle draw, so the sorter replays the same order after
  -- save and restore. A missing sample stays silent instead of
  -- drawing late.
  local raw = context.rawOrderRoll
  if type(raw) ~= "number" or raw % 1 ~= 0 or raw < 0 or raw > 65535 then
    return nil
  end
  if raw % 5 ~= 0 then
    return nil
  end
  return { kind = "trigger", key = instance.key, combatant = holderOf(instance), order = "first" }
end

---@param instance table<string, unknown> dispatched effect instance under handling
---@param context table<string, unknown> stat context under handling
---@return table<string, unknown>? herb announcement, or nil when inapplicable
local function whiteHerb(instance, context)
  if context.statsLowered ~= true then
    return nil
  end
  return { kind = "trigger", key = instance.key, combatant = holderOf(instance), restored = true }
end

---@param instance table<string, unknown> dispatched effect instance under handling
---@param context table<string, unknown> status context under handling
---@return table<string, unknown>? herb announcement, or nil when inapplicable
local function mentalHerb(instance, context)
  if context.infatuated ~= true then
    return nil
  end
  return { kind = "trigger", key = instance.key, combatant = holderOf(instance), cured = "infatuation" }
end

---@param instance table<string, unknown> dispatched effect instance under handling
---@param context table<string, unknown> move context under handling
---@return table<string, unknown>? herb announcement, or nil when inapplicable
local function powerHerb(instance, context)
  if context.charging ~= true then
    return nil
  end
  return { kind = "trigger", key = instance.key, combatant = holderOf(instance), charged = "skipped" }
end

---@param instance table<string, unknown> dispatched effect instance under handling
---@param context table<string, unknown> status context under handling
---@return table<string, unknown>? knot announcement, or nil when inapplicable
local function destinyKnot(instance, context)
  if context.infatuation ~= true then
    return nil
  end
  return { kind = "trigger", key = instance.key, combatant = holderOf(instance), reflected = "infatuation" }
end

---@param instance table<string, unknown> dispatched effect instance under handling
---@param context table<string, unknown> damage context under handling
---@return table<string, unknown>? flinch announcement, or nil when inapplicable
local function flinchChance(instance, context)
  -- The flinch chance draws ten percent per damaging hit: a low roll
  -- announces while a high roll -- or no stream at all -- stays silent.
  if context.dealtDamage ~= true then
    return nil
  end
  local stream = context.stream
  if not canDraw(stream) then
    return nil
  end
  local label = "kings_rock"
  if instance.key == "RAZOR_FANG" then
    label = "razor_fang"
  end
  local draw = (stream --[[@as table<string, unknown>]]).nextU16
  local value = (draw --[[@as fun(self: unknown, label: string, cause: table<string, unknown>): integer]])(
    stream,
    label,
    { kind = "held_item", key = instance.key }
  )
  if value >= 6554 then
    return nil
  end
  return { kind = "trigger", key = instance.key, combatant = holderOf(instance), flinchChance = true }
end

---@param instance table<string, unknown> dispatched effect instance under handling
---@param context table<string, unknown> damage context under handling
---@return table<string, unknown>? fang announcement, or nil when inapplicable
local function razorFang(instance, context)
  return flinchChance(instance, context)
end

--- Berries with no battle hold effect stay bound and silent, so coverage
--- distinguishes their genuine absence of effect from an unimplemented
--- binding.
---@param instance table<string, unknown> dispatched effect instance under handling
---@param context table<string, unknown> pass context under handling
---@return nil always silent
local function silentBerry(instance, context)
  assert(type(instance) == "table", "triggered items read their instance")
  assert(type(context) == "table", "triggered items read their pass context")
  return nil
end

--- Binds the consumable and reactive held-item handlers into the owner table.
---@param owned table<string, fun(instance: table<string, unknown>, context: table<string, unknown>): table<string, unknown>?> handler owner receiving the family bindings
function TriggeredItems.register(owned)
  assert(type(owned) == "table", "triggered items register into their owner table")
  for key in pairs(HP_BERRY) do
    owned[key] = hpBerry
  end
  for key in pairs(STATUS_BERRY) do
    owned[key] = statusBerry
  end
  for key in pairs(PINCH_RESTORE) do
    owned[key] = pinchBerry
  end
  for key in pairs(PINCH_STAT) do
    owned[key] = pinchBerry
  end
  for key in pairs(RESIST_BERRY) do
    owned[key] = resistBerry
  end
  for _, key in ipairs(SILENT_BERRY) do
    owned[key] = silentBerry
  end
  owned.LEPPA_BERRY = leppaBerry
  owned.ENIGMA_BERRY = enigmaBerry
  owned.MICLE_BERRY = micleBerry
  owned.CUSTAP_BERRY = custapBerry
  owned.JABOCA_BERRY = jabocaBerry
  owned.ROWAP_BERRY = jabocaBerry
  owned.LEFTOVERS = leftovers
  owned.BLACK_SLUDGE = blackSludge
  owned.SHELL_BELL = shellBell
  owned.STICKY_BARB = stickyBarb
  owned.TOXIC_ORB = statusOrb
  owned.FLAME_ORB = statusOrb
  owned.FOCUS_SASH = focusSash
  owned.FOCUS_BAND = focusBand
  owned.QUICK_CLAW = quickClaw
  owned.WHITE_HERB = whiteHerb
  owned.MENTAL_HERB = mentalHerb
  owned.POWER_HERB = powerHerb
  owned.DESTINY_KNOT = destinyKnot
  owned.KINGS_ROCK = flinchChance
  owned.RAZOR_FANG = razorFang
end

return TriggeredItems
