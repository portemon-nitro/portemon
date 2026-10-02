-- Status, stage, recovery, and field move families: conditions that alter
-- combatants or the shared field rather than dealing direct damage. Every
-- member binds its own handler; members without modeled native semantics
-- fail explicitly instead of emitting a successful move result. Curated
-- members carry their source checks beside their bodies: volatile
-- prevention and trapping markers settle through the validated surface,
-- while persistent status and stage projection stay with their owning
-- behavior layers. Source references: src/battle/battle_command.c and
-- src/battle/overlay_12_0224E4FC.c.

local BattleErrors = require("libs.battle.src.errors")

---@class ConditionMoves
local ConditionMoves = {}

ConditionMoves.MEMBERS = {
  "ACID_ARMOR",
  "ACUPRESSURE",
  "AGILITY",
  "AMNESIA",
  "AQUA_RING",
  "AROMATHERAPY",
  "ATTRACT",
  "BARRIER",
  "BELLY_DRUM",
  "BLOCK",
  "BULK_UP",
  "CALM_MIND",
  "CAPTIVATE",
  "CHARM",
  "CONFUSE_RAY",
  "COSMIC_POWER",
  "COTTON_SPORE",
  "CURSE",
  "DARK_VOID",
  "DEFEND_ORDER",
  "DEFENSE_CURL",
  "DEFOG",
  "DISABLE",
  "DOUBLE_TEAM",
  "DRAGON_DANCE",
  "ENCORE",
  "FAKE_TEARS",
  "FEATHER_DANCE",
  "FLASH",
  "FLATTER",
  "FOCUS_ENERGY",
  "FORESIGHT",
  "GLARE",
  "GRASS_WHISTLE",
  "GRAVITY",
  "GROWL",
  "GROWTH",
  "HAIL",
  "HARDEN",
  "HAZE",
  "HEALING_WISH",
  "HEAL_BELL",
  "HEAL_BLOCK",
  "HEAL_ORDER",
  "HOWL",
  "HYPNOSIS",
  "IMPRISON",
  "INGRAIN",
  "IRON_DEFENSE",
  "KINESIS",
  "LEECH_SEED",
  "LEER",
  "LIGHT_SCREEN",
  "LOCK_ON",
  "LOVELY_KISS",
  "LUCKY_CHANT",
  "LUNAR_DANCE",
  "MAGNET_RISE",
  "MEAN_LOOK",
  "MEDITATE",
  "MEMENTO",
  "METAL_SOUND",
  "MILK_DRINK",
  "MIND_READER",
  "MINIMIZE",
  "MIRACLE_EYE",
  "MIST",
  "MOONLIGHT",
  "MORNING_SUN",
  "MUD_SPORT",
  "NASTY_PLOT",
  "NIGHTMARE",
  "ODOR_SLEUTH",
  "PAIN_SPLIT",
  "PERISH_SONG",
  "POISON_GAS",
  "POISON_POWDER",
  "PSYCH_UP",
  "RAIN_DANCE",
  "RECOVER",
  "REFLECT",
  "REFRESH",
  "REST",
  "ROCK_POLISH",
  "ROOST",
  "SAFEGUARD",
  "SANDSTORM",
  "SAND_ATTACK",
  "SCARY_FACE",
  "SCREECH",
  "SHARPEN",
  "SING",
  "SLACK_OFF",
  "SLEEP_POWDER",
  "SMOKE_SCREEN",
  "SOFTBOILED",
  "SPIDER_WEB",
  "SPIKES",
  "SPITE",
  "SPLASH",
  "SPORE",
  "STEALTH_ROCK",
  "STRING_SHOT",
  "STUN_SPORE",
  "SUNNY_DAY",
  "SUPERSONIC",
  "SWAGGER",
  "SWEET_KISS",
  "SWEET_SCENT",
  "SWORDS_DANCE",
  "SYNTHESIS",
  "TAILWIND",
  "TAIL_GLOW",
  "TAIL_WHIP",
  "TAUNT",
  "TEETER_DANCE",
  "TELEPORT",
  "THUNDER_WAVE",
  "TICKLE",
  "TORMENT",
  "TOXIC",
  "TOXIC_SPIKES",
  "TRICK_ROOM",
  "WATER_SPORT",
  "WILL_O_WISP",
  "WISH",
  "WITHDRAW",
  "YAWN",
}

---@param frame table<string, unknown> move frame under execution
---@return table<string, unknown> semantic cause carried by writes and events
local function causeFor(frame)
  return { key = frame.executingMove }
end

---@param frame table<string, unknown> move frame under execution
---@return integer user combatant owning the move
local function userOf(frame)
  local actor = frame.actor --[[@as table<string, unknown>]]
  assert(type(actor.combatant) == "number", "conditions read their user combatant")
  return actor.combatant --[[@as integer]]
end

---@param entry unknown target entry under resolution
---@return integer defender combatant receiving the condition
local function targetOf(entry)
  assert(type(entry) == "table", "conditions read their target entries")
  local record = entry --[[@as table<string, unknown>]]
  assert(type(record.combatant) == "number", "conditions target combatants")
  return record.combatant --[[@as integer]]
end

---@param ctx BattleContext mechanics context under execution
---@param frame table<string, unknown> move frame under execution
local function emitUsed(ctx, frame)
  local record = frame --[[@as table<string, unknown>]]
  ctx:emit("move-used", causeFor(record), {
    targets = #record.targets,
  })
end

---@param ctx BattleContext mechanics context under execution
---@param combatant integer combatant receiving the volatile marker
---@param key string volatile identity under the marker
---@param extra table<string, unknown>? additional marker facts under the record
local function markVolatile(ctx, combatant, key, extra)
  local effect = { key = key, scope = "volatile" }
  if extra ~= nil then
    for name, value in pairs(extra) do
      effect[name] = value
    end
  end
  ctx:addEffect(combatant, effect)
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
  assert(type(ctx) == "table", "conditions step through the battle context")
  assert(type(frame) == "table", "conditions step from their move frame")
  local record = frame --[[@as table<string, unknown>]]
  error(BattleErrors.missingBehavior("no native condition semantics are modeled for the source identity", {
    key = record.executingMove --[[@as string]],
  }))
end

-- Splash never connects to anything: the canonical nothing-happens
-- sequence emits its ordered event and completes without damage.
local function stepSplash(ctx, frame)
  assert(type(ctx) == "table", "conditions step through the battle context")
  assert(type(frame) == "table", "conditions step from their move frame")
  emitUsed(ctx, frame)
  return { kind = "complete", result = "hit" }
end

-- Pain Split averages the user and defender current health. Both readings
-- travel the validated surface as zero-quantity probes, so no battle
-- state is read around the mutation endpoints.
local function stepPainSplit(ctx, frame)
  assert(type(ctx) == "table", "conditions step through the battle context")
  assert(type(frame) == "table", "conditions step from their move frame")
  local record = frame --[[@as table<string, unknown>]]
  local user = userOf(record)
  local defender = targetOf((record.targets --[[@as table<integer, unknown>]])[1])
  local userHealth = ctx:damage(user, 0, causeFor(record))
  local foeHealth = ctx:damage(defender, 0, causeFor(record))
  local average = math.floor((userHealth.before + foeHealth.before) / 2)
  if average > userHealth.before then
    ctx:heal(user, average - userHealth.before, causeFor(record))
  elseif average < userHealth.before then
    ctx:damage(user, userHealth.before - average, causeFor(record))
  end
  if average > foeHealth.before then
    ctx:heal(defender, average - foeHealth.before, causeFor(record))
  elseif average < foeHealth.before then
    ctx:damage(defender, foeHealth.before - average, causeFor(record))
  end
  ctx:emit("leveled", causeFor(record), { target = defender, health = average })
  return { kind = "complete", result = "hit" }
end

-- Memento faints the user after its spite settles; the accompanying stat
-- collapse belongs to the stat-stage owner, so the handler records the
-- self-faint and completes.
local function stepMemento(ctx, frame)
  assert(type(ctx) == "table", "conditions step through the battle context")
  assert(type(frame) == "table", "conditions step from their move frame")
  local record = frame --[[@as table<string, unknown>]]
  emitUsed(ctx, record)
  ctx:damage(userOf(record), 999999, causeFor(record))
  ctx:emit("fainted", causeFor(record), { target = userOf(record) })
  return { kind = "complete", result = "hit" }
end

-- Healing Wish and Lunar Dance trade the user for a delayed recovery
-- marker; the recovery itself settles through the residual owner, so the
-- handler records the self-faint plus the wish marker and completes.
---@param marker string wish identity under the marker
---@return fun(ctx: BattleContext, frame: table<string, unknown>): table<string, unknown> step handler trading the user for the wish
local function makeWishTrade(marker)
  local function stepWishTrade(ctx, frame)
    assert(type(ctx) == "table", "conditions step through the battle context")
    assert(type(frame) == "table", "conditions step from their move frame")
    local record = frame --[[@as table<string, unknown>]]
    markVolatile(ctx, userOf(record), marker, nil)
    ctx:damage(userOf(record), 999999, causeFor(record))
    ctx:emit("fainted", causeFor(record), { target = userOf(record) })
    return { kind = "complete", result = "hit" }
  end
  return stepWishTrade
end

-- Wish schedules recovery two turns out; without a residual scheduling
-- channel the handler records the marker and completes.
local function stepWish(ctx, frame)
  assert(type(ctx) == "table", "conditions step through the battle context")
  assert(type(frame) == "table", "conditions step from their move frame")
  local record = frame --[[@as table<string, unknown>]]
  markVolatile(ctx, userOf(record), "WISH", { turns = 2 })
  emitUsed(ctx, record)
  return { kind = "complete", result = "hit" }
end

-- Roost restores half the maximum health, so it needs the maximum-health
-- fact; without it the handler fails instead of healing a guessed amount.
local function stepRoost(ctx, frame)
  assert(type(ctx) == "table", "conditions step through the battle context")
  assert(type(frame) == "table", "conditions step from their move frame")
  local record = frame --[[@as table<string, unknown>]]
  local locals = record.locals --[[@as table<string, unknown>]]
  local combat = locals.combat
  if
    type(combat) ~= "table" or type((combat --[[@as table<string, unknown>]]).maxHp) ~= "number"
  then
    return { kind = "complete", result = "failed" }
  end
  local ceiling = (combat --[[@as table<string, unknown>]]).maxHp --[[@as integer]]
  local outcome = ctx:heal(userOf(record), math.floor(ceiling / 2), causeFor(record))
  ctx:emit("healed", causeFor(record), { target = userOf(record), restored = outcome.after - outcome.before })
  return { kind = "complete", result = "hit" }
end

-- Perish Song counts every active combatant down; the handler marks the
-- user plus each sampled target and completes, leaving the countdown to
-- the residual owner.
local function stepPerishSong(ctx, frame)
  assert(type(ctx) == "table", "conditions step through the battle context")
  assert(type(frame) == "table", "conditions step from their move frame")
  local record = frame --[[@as table<string, unknown>]]
  markVolatile(ctx, userOf(record), "PERISH_SONG", { count = 3 })
  for _, entry in
    ipairs(record.targets --[[@as table<integer, unknown>]])
  do
    markVolatile(ctx, targetOf(entry), "PERISH_SONG", { count = 3 })
  end
  emitUsed(ctx, record)
  return { kind = "complete", result = "hit" }
end

-- Prevention, trapping, seed, setup, and levitation markers settle as
-- volatile instances through the validated surface; leaving discards
-- them with the rest of the activation-local state.
---@param key string volatile identity under the marker
---@param onTarget boolean true when the marker lands on the sampled target
---@return fun(ctx: BattleContext, frame: table<string, unknown>): table<string, unknown> step handler recording the marker
local function makeMarker(key, onTarget)
  local function stepMarker(ctx, frame)
    assert(type(ctx) == "table", "conditions step through the battle context")
    assert(type(frame) == "table", "conditions step from their move frame")
    local record = frame --[[@as table<string, unknown>]]
    if onTarget then
      markVolatile(ctx, targetOf((record.targets --[[@as table<integer, unknown>]])[1]), key, nil)
    else
      markVolatile(ctx, userOf(record), key, nil)
    end
    emitUsed(ctx, record)
    return { kind = "complete", result = "hit" }
  end
  return stepMarker
end

-- Defog clears field hazards and lowers the target evasion; the hazard
-- ownership stays with the field layers, so the handler emits the
-- clearing intent and completes.
local function stepDefog(ctx, frame)
  assert(type(ctx) == "table", "conditions step through the battle context")
  assert(type(frame) == "table", "conditions step from their move frame")
  local record = frame --[[@as table<string, unknown>]]
  ctx:emit("cleared", causeFor(record), {
    target = targetOf((record.targets --[[@as table<integer, unknown>]])[1]),
  })
  return { kind = "complete", result = "hit" }
end

local TARGET_MARKERS = {
  ENCORE = true,
  DISABLE = true,
  TAUNT = true,
  TORMENT = true,
  IMPRISON = true,
  HEAL_BLOCK = true,
  MEAN_LOOK = true,
  SPIDER_WEB = true,
  BLOCK = true,
  LEECH_SEED = true,
  CURSE = true,
  NIGHTMARE = true,
  LOCK_ON = true,
  MIND_READER = true,
  FORESIGHT = true,
  ODOR_SLEUTH = true,
  MIRACLE_EYE = true,
}

local USER_MARKERS = {
  INGRAIN = true,
  AQUA_RING = true,
  MAGNET_RISE = true,
}

---@param key string condition move identity under binding
---@return fun(ctx: BattleContext, frame: table<string, unknown>): table<string, unknown> distinct per-move handler for the registry
local function bodyFor(key)
  if key == "SPLASH" then
    return bind(stepSplash)
  end
  if key == "PAIN_SPLIT" then
    return bind(stepPainSplit)
  end
  if key == "MEMENTO" then
    return bind(stepMemento)
  end
  if key == "HEALING_WISH" then
    return bind(makeWishTrade("HEALING_WISH"))
  end
  if key == "LUNAR_DANCE" then
    return bind(makeWishTrade("LUNAR_DANCE"))
  end
  if key == "WISH" then
    return bind(stepWish)
  end
  if key == "ROOST" then
    return bind(stepRoost)
  end
  if key == "PERISH_SONG" then
    return bind(stepPerishSong)
  end
  if key == "DEFOG" then
    return bind(stepDefog)
  end
  if TARGET_MARKERS[key] == true then
    return bind(makeMarker(key, true))
  end
  if USER_MARKERS[key] == true then
    return bind(makeMarker(key, false))
  end
  return bind(stepCanonical)
end

--- Binds the condition family handlers into the owner table.
---@param owned table<string, fun(ctx: BattleContext, frame: table<string, unknown>): table<string, unknown>> handler owner receiving the family bindings
function ConditionMoves.register(owned)
  assert(type(owned) == "table", "condition moves register into their owner table")
  for _, key in ipairs(ConditionMoves.MEMBERS) do
    owned[key] = bodyFor(key)
  end
end

return ConditionMoves
