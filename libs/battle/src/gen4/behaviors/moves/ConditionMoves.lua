-- Status, stage, recovery, and field move families: conditions that alter
-- combatants or the shared field rather than dealing direct damage. Every
-- member binds its own handler; members without modeled native semantics
-- fail explicitly instead of emitting a successful move result. Curated
-- members carry their source checks beside their bodies: volatile
-- prevention and trapping markers settle through the validated surface,
-- while persistent status and stage projection stay with their owning
-- behavior layers. Source references: src/battle/battle_command.c and
-- src/battle/overlay_12_0224E4FC.c.

local Accuracy = require("libs.battle.src.gen4.Accuracy")
local BattleErrors = require("libs.battle.src.errors")
local BattleRng = require("libs.battle.src.gen4.BattleRng")
local NativeEffectHandlers = require("libs.battle.src.gen4.behaviors.effects.NativeEffectHandlers")
local StatStages = require("libs.battle.src.gen4.StatStages")
local TypeEffectiveness = require("libs.battle.src.gen4.TypeEffectiveness")

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

---@param stream unknown battle stream under the roll
---@return BattleRng the stream once it proves its draw contract
local function checkStream(stream)
  assert(type(stream) == "table", "conditions draw from the battle stream")
  local candidate = stream --[[@as table<string, unknown>]]
  assert(type(candidate.nextU16) == "function", "conditions draw from the battle stream")
  assert(BattleRng.ALGORITHM == "gen4-lcrng", "conditions draw from the native battle stream")
  return stream --[[@as BattleRng]]
end

---@param ctx BattleContext mechanics context under execution
---@param frame table<string, unknown> move frame under execution
---@param defender integer defender combatant under the roll
---@return boolean true when the foe-targeted condition connects
local function foeAccuracy(ctx, frame, defender)
  local record = frame --[[@as table<string, unknown>]]
  local locals = record.locals --[[@as table<string, unknown>]]
  local move = locals.move --[[@as table<string, unknown>?]]
  local accuracy = type(move) == "table" and move.accuracy or nil
  if type(accuracy) ~= "number" or accuracy % 1 ~= 0 then
    error(BattleErrors.missingBehavior("foe-targeted condition moves read their compiled accuracy", {
      key = record.executingMove --[[@as string]],
    }))
  end
  local stream = checkStream(record.stream)
  local userStages = ctx:entryOf(userOf(record)).stages --[[@as table<string, integer>]]
  local targetStages = ctx:entryOf(defender).stages --[[@as table<string, integer>]]
  local resolution = Accuracy.resolve({
    accuracy = accuracy --[[@as integer]],
    target = { kind = "combatant" },
    cause = causeFor(record),
    protected = false,
    accuracyStage = userStages.accuracy,
    evasionStage = targetStages.evasion,
  }, stream)
  if resolution.kind == "hit" then
    return true
  end
  ctx:emit("missed", causeFor(record), { target = defender })
  return false
end

---@class StageSpec
---@field target "user"|"foe"
---@field changes table<integer, table<integer, unknown>> stat/delta pairs under the move

-- Common native stage families: self-raised boosts skip the accuracy
-- roll while foe-targeted drops roll compiled accuracy through staged
-- checkpoints. Deltas stay source-defined per move; clamping stays with
-- the stage owner. Moves needing sun, gender, charge, or hit-history
-- facts stay explicitly unmodeled.
local STAGE_MOVES = {
  SWORDS_DANCE = { target = "user", changes = { { "attack", 2 } } },
  HOWL = { target = "user", changes = { { "attack", 1 } } },
  MEDITATE = { target = "user", changes = { { "attack", 1 } } },
  SHARPEN = { target = "user", changes = { { "attack", 1 } } },
  GROWL = { target = "foe", changes = { { "attack", -1 } } },
  CHARM = { target = "foe", changes = { { "attack", -2 } } },
  FEATHER_DANCE = { target = "foe", changes = { { "attack", -2 } } },
  TICKLE = { target = "foe", changes = { { "attack", -1 }, { "defense", -1 } } },
  HARDEN = { target = "user", changes = { { "defense", 1 } } },
  WITHDRAW = { target = "user", changes = { { "defense", 1 } } },
  DEFENSE_CURL = { target = "user", changes = { { "defense", 1 } } },
  IRON_DEFENSE = { target = "user", changes = { { "defense", 2 } } },
  ACID_ARMOR = { target = "user", changes = { { "defense", 2 } } },
  BARRIER = { target = "user", changes = { { "defense", 2 } } },
  LEER = { target = "foe", changes = { { "defense", -1 } } },
  TAIL_WHIP = { target = "foe", changes = { { "defense", -1 } } },
  SCREECH = { target = "foe", changes = { { "defense", -2 } } },
  AGILITY = { target = "user", changes = { { "speed", 2 } } },
  ROCK_POLISH = { target = "user", changes = { { "speed", 2 } } },
  STRING_SHOT = { target = "foe", changes = { { "speed", -1 } } },
  COTTON_SPORE = { target = "foe", changes = { { "speed", -1 } } },
  SCARY_FACE = { target = "foe", changes = { { "speed", -2 } } },
  NASTY_PLOT = { target = "user", changes = { { "specialAttack", 2 } } },
  TAIL_GLOW = { target = "user", changes = { { "specialAttack", 2 } } },
  CALM_MIND = { target = "user", changes = { { "specialAttack", 1 }, { "specialDefense", 1 } } },
  AMNESIA = { target = "user", changes = { { "specialDefense", 2 } } },
  FAKE_TEARS = { target = "foe", changes = { { "specialDefense", -2 } } },
  METAL_SOUND = { target = "foe", changes = { { "specialDefense", -2 } } },
  BULK_UP = { target = "user", changes = { { "attack", 1 }, { "defense", 1 } } },
  DRAGON_DANCE = { target = "user", changes = { { "attack", 1 }, { "speed", 1 } } },
  COSMIC_POWER = { target = "user", changes = { { "defense", 1 }, { "specialDefense", 1 } } },
  DEFEND_ORDER = { target = "user", changes = { { "defense", 1 }, { "specialDefense", 1 } } },
  SAND_ATTACK = { target = "foe", changes = { { "accuracy", -1 } } },
  SMOKE_SCREEN = { target = "foe", changes = { { "accuracy", -1 } } },
  FLASH = { target = "foe", changes = { { "accuracy", -1 } } },
  KINESIS = { target = "foe", changes = { { "accuracy", -1 } } },
  DOUBLE_TEAM = { target = "user", changes = { { "evasion", 1 } } },
  MINIMIZE = { target = "user", changes = { { "evasion", 1 } } },
  SWEET_SCENT = { target = "foe", changes = { { "evasion", -1 } } },
}

---@param spec StageSpec stage family under the move
---@return fun(ctx: BattleContext, frame: table<string, unknown>): table<string, unknown> step handler applying the family
local function makeStage(spec)
  local function stepStage(ctx, frame)
    assert(type(ctx) == "table", "conditions step through the battle context")
    assert(type(frame) == "table", "conditions step from their move frame")
    local record = frame --[[@as table<string, unknown>]]
    local user = userOf(record)
    local target = user
    if spec.target == "foe" then
      target = targetOf((record.targets --[[@as table<integer, unknown>]])[1])
      if not foeAccuracy(ctx, record, target) then
        return { kind = "complete", result = "missed" }
      end
    end
    local current = ctx:entryOf(target).stages --[[@as table<string, integer>]]
    local moved = false
    for _, change in ipairs(spec.changes) do
      local stat = change[1] --[[@as string]]
      local delta = change[2] --[[@as integer]]
      local next = StatStages.change(current[stat] --[[@as integer]], delta)
      if next ~= current[stat] then
        ctx:changeStage(target, stat, next, causeFor(record))
        moved = true
      end
    end
    if not moved then
      return { kind = "complete", result = "failed" }
    end
    emitUsed(ctx, record)
    return { kind = "complete", result = "hit" }
  end
  return stepStage
end

-- Common native major-status moves by applied condition. Sleep carries a
-- stream-drawn duration; toxic starts its counter at zero; every other
-- condition carries no further state. Freeze has no pure-status native
-- setter, so only its gate is wired.
local SLEEP_MOVES = {
  SPORE = true,
  SLEEP_POWDER = true,
  HYPNOSIS = true,
  LOVELY_KISS = true,
  SING = true,
  GRASS_WHISTLE = true,
  DARK_VOID = true,
}

local PARALYSIS_MOVES = {
  THUNDER_WAVE = true,
  GLARE = true,
  STUN_SPORE = true,
}

local POISON_MOVES = {
  POISON_GAS = true,
  POISON_POWDER = true,
  POISONPOWDER = true,
}

-- Poison-status moves that poison-type defenders absorb: the session
-- chart already covers steel immunity through its exact pair, but
-- poison-into-poison is a status immunity, not a chart immunity.
local POISON_ABSORBED = {
  TOXIC = true,
  POISON_GAS = true,
  POISON_POWDER = true,
  POISONPOWDER = true,
}

---@param frame table<string, unknown> move frame under execution
---@param defender integer defender combatant under the immunity check
---@return boolean true when the defender absorbs the status move
local function statusImmune(frame, defender)
  local record = frame --[[@as table<string, unknown>]]
  local moveKey = record.executingMove --[[@as string]]
  local locals = record.locals --[[@as table<string, unknown>]]
  local move = locals.move --[[@as table<string, unknown>?]]
  local moveType = type(move) == "table" and move.moveType or nil
  if type(moveType) ~= "string" or moveType == "" then
    error(BattleErrors.missingBehavior("status moves read their compiled move type", { key = moveKey }))
  end
  local defenders = locals.defenderTypes --[[@as table<integer, unknown>?]]
  if type(defenders) ~= "table" then
    error(BattleErrors.missingBehavior("status moves read their semantic defender facts", { key = moveKey }))
  end
  local defenderTypes = (defenders --[[@as table<integer, unknown>]])[defender]
  if type(defenderTypes) ~= "table" then
    error(BattleErrors.missingBehavior("status moves read their semantic defender facts", { key = moveKey }))
  end
  local chart = locals.typeChart
  if
    type(chart) ~= "table" or type((chart --[[@as table<string, unknown>]]).effectiveness) ~= "function"
  then
    error(BattleErrors.missingBehavior("status moves read their session type chart", { key = moveKey }))
  end
  local resolved = TypeEffectiveness.resolve(
    chart --[[@as table<string, unknown>]],
    moveType --[[@as string]],
    defenderTypes --[[@as string[] ]],
    {}
  )
  if resolved.numerator == 0 then
    return true
  end
  if POISON_ABSORBED[moveKey] == true then
    for _, key in
      ipairs(defenderTypes --[[@as string[] ]])
    do
      if key == "poison" then
        return true
      end
    end
  end
  return false
end

---@param status string native major condition under the move
---@return fun(ctx: BattleContext, frame: table<string, unknown>): table<string, unknown> step handler applying the condition
local function makeStatus(status)
  local function stepStatus(ctx, frame)
    assert(type(ctx) == "table", "conditions step through the battle context")
    assert(type(frame) == "table", "conditions step from their move frame")
    local record = frame --[[@as table<string, unknown>]]
    local stream = checkStream(record.stream)
    local applied = false
    local missed = false
    for _, entry in
      ipairs(record.targets --[[@as table<integer, unknown>]])
    do
      local defender = targetOf(entry)
      if statusImmune(record, defender) then
        -- Absorbed targets contribute a failure, never a miss draw.
      elseif ctx:hasBattleEffect(defender, "substitute") then
        -- A marked substitute absorbs the condition outright.
      elseif not foeAccuracy(ctx, record, defender) then
        missed = true
      else
        local state = {}
        if status == "sleep" then
          -- Native sleep lasts two to five turns, drawn once per
          -- application from the labeled battle stream.
          state = { turns = 2 + (stream:nextU16("sleep_turns", causeFor(record)) % 4) }
        elseif status == "toxic" then
          state = { counter = 0 }
        end
        if ctx:applyStatus(defender, status, state, causeFor(record)) then
          applied = true
        end
      end
    end
    if applied then
      emitUsed(ctx, record)
      return { kind = "complete", result = "hit" }
    end
    if missed then
      return { kind = "complete", result = "missed" }
    end
    return { kind = "complete", result = "failed" }
  end
  return stepStatus
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

-- Memento collapses the foe attack and special attack two stages each,
-- then faints the user; the knockout itself settles through faint
-- ownership, so the handler records damage only and never emits the
-- faint. A missed spite costs nothing.
local function stepMemento(ctx, frame)
  assert(type(ctx) == "table", "conditions step through the battle context")
  assert(type(frame) == "table", "conditions step from their move frame")
  local record = frame --[[@as table<string, unknown>]]
  local defender = targetOf((record.targets --[[@as table<integer, unknown>]])[1])
  if not foeAccuracy(ctx, record, defender) then
    return { kind = "complete", result = "missed" }
  end
  local current = ctx:entryOf(defender).stages --[[@as table<string, integer>]]
  for _, stat in ipairs({ "attack", "specialAttack" }) do
    local next = StatStages.change(current[stat] --[[@as integer]], -2)
    if next ~= current[stat] then
      ctx:changeStage(defender, stat, next, causeFor(record))
    end
  end
  emitUsed(ctx, record)
  ctx:damage(userOf(record), 999999, causeFor(record))
  return { kind = "complete", result = "hit" }
end

---@param user integer combatant owning the move
---@return table<string, unknown> causal source attributed to the instance
local function moveSource(user)
  return { kind = "move", combatant = user }
end

---@param ctx BattleContext mechanics context under execution
---@param combatant integer combatant owning the entry under the scope
---@return table<string, unknown> active owner scope pinned to the live entry
local function activeScope(ctx, combatant)
  local entry = ctx:entryOf(combatant)
  if entry.activation == nil then
    error(BattleErrors.invalidState("battle-local effects scope to a live entry", { combatant = combatant }))
  end
  return { kind = "active", combatant = combatant, activation = entry.activation }
end

-- Leech Seed roots the defender: one eighth of maximum health drains
-- every residual pass while the seeder still stands. Re-seeding an
-- already seeded combatant fails.
local function stepLeechSeed(ctx, frame)
  assert(type(ctx) == "table", "conditions step through the battle context")
  assert(type(frame) == "table", "conditions step from their move frame")
  local record = frame --[[@as table<string, unknown>]]
  local defender = targetOf((record.targets --[[@as table<integer, unknown>]])[1])
  if not foeAccuracy(ctx, record, defender) then
    return { kind = "complete", result = "missed" }
  end
  if ctx:hasBattleEffect(defender, "leechseed") then
    return { kind = "complete", result = "failed" }
  end
  ctx:addBattleEffect(
    NativeEffectHandlers.definitionFor("leechseed"),
    activeScope(ctx, defender),
    moveSource(userOf(record)),
    { version = 1 }
  )
  emitUsed(ctx, record)
  return { kind = "complete", result = "hit" }
end

-- Curse splits on the user type: ghost users trade half their maximum
-- health for the foe curse (blocked by a marked substitute, refused on
-- an already cursed foe), while living users trade speed for attack and
-- defense through the stage owner.
local function stepCurse(ctx, frame)
  assert(type(ctx) == "table", "conditions step through the battle context")
  assert(type(frame) == "table", "conditions step from their move frame")
  local record = frame --[[@as table<string, unknown>]]
  local locals = record.locals --[[@as table<string, unknown>]]
  local attackerTypes = locals.attackerTypes
  if type(attackerTypes) ~= "table" or #attackerTypes == 0 then
    error(BattleErrors.missingBehavior("curse reads its semantic attacker facts", {
      key = record.executingMove --[[@as string]],
    }))
  end
  local user = userOf(record)
  local ghost = false
  for _, key in
    ipairs(attackerTypes --[[@as string[] ]])
  do
    if key == "ghost" then
      ghost = true
    end
  end
  if not ghost then
    local current = ctx:entryOf(user).stages --[[@as table<string, integer>]]
    local moved = false
    for _, change in ipairs({ { "speed", -1 }, { "attack", 1 }, { "defense", 1 } }) do
      local stat = change[1] --[[@as string]]
      local next = StatStages.change(current[stat] --[[@as integer]], change[2] --[[@as integer]])
      if next ~= current[stat] then
        ctx:changeStage(user, stat, next, causeFor(record))
        moved = true
      end
    end
    if not moved then
      return { kind = "complete", result = "failed" }
    end
    emitUsed(ctx, record)
    return { kind = "complete", result = "hit" }
  end
  local defender = targetOf((record.targets --[[@as table<integer, unknown>]])[1])
  if ctx:hasBattleEffect(defender, "substitute") or ctx:hasBattleEffect(defender, "curse") then
    return { kind = "complete", result = "failed" }
  end
  local ceiling = ctx:entryOf(user).maxHp --[[@as integer]]
  ctx:addBattleEffect(
    NativeEffectHandlers.definitionFor("curse"),
    activeScope(ctx, defender),
    moveSource(user),
    { version = 1 }
  )
  emitUsed(ctx, record)
  ctx:damage(user, math.floor(ceiling / 2), causeFor(record))
  return { kind = "complete", result = "hit" }
end

-- Perish Song counts every sampled combatant down from three through
-- the shared countdown; already counted entries keep their own clock.
local function stepPerishSong(ctx, frame)
  assert(type(ctx) == "table", "conditions step through the battle context")
  assert(type(frame) == "table", "conditions step from their move frame")
  local record = frame --[[@as table<string, unknown>]]
  local counted = false
  local candidates = { userOf(record) }
  for _, entry in
    ipairs(record.targets --[[@as table<integer, unknown>]])
  do
    candidates[#candidates + 1] = targetOf(entry)
  end
  for _, combatant in ipairs(candidates) do
    if not ctx:hasBattleEffect(combatant, "perishsong") then
      ctx:addBattleEffect(
        NativeEffectHandlers.definitionFor("perishsong"),
        activeScope(ctx, combatant),
        moveSource(userOf(record)),
        { version = 1, turns = 3 }
      )
      counted = true
    end
  end
  if not counted then
    return { kind = "complete", result = "failed" }
  end
  emitUsed(ctx, record)
  return { kind = "complete", result = "hit" }
end

-- Wish schedules recovery two turns out on the user position, so the
-- delayed slot outlives its occupant through the position transfer
-- policy. Re-wishing replaces the pending slot.
local function stepWish(ctx, frame)
  assert(type(ctx) == "table", "conditions step through the battle context")
  assert(type(frame) == "table", "conditions step from their move frame")
  local record = frame --[[@as table<string, unknown>]]
  local position = ctx:entryOf(userOf(record)).position
  if position == nil then
    error(BattleErrors.invalidState("delayed recovery scopes to a live position", {}))
  end
  ctx:addBattleEffect(
    NativeEffectHandlers.definitionFor("wish"),
    { kind = "position", position = position },
    moveSource(userOf(record)),
    { version = 1, turns = 2 }
  )
  emitUsed(ctx, record)
  return { kind = "complete", result = "hit" }
end

-- Side screens and mist settle one five-turn instance on the user side;
-- replacement stacking keeps a single live instance per key.
---@param key string battle-local definition identity under the screen
---@return fun(ctx: BattleContext, frame: table<string, unknown>): table<string, unknown> step handler raising the screen
local function makeScreen(key)
  local function stepScreen(ctx, frame)
    assert(type(ctx) == "table", "conditions step through the battle context")
    assert(type(frame) == "table", "conditions step from their move frame")
    local record = frame --[[@as table<string, unknown>]]
    ctx:addBattleEffect(
      NativeEffectHandlers.definitionFor(key),
      { kind = "side", side = ctx:entryOf(userOf(record)).side },
      moveSource(userOf(record)),
      { version = 1, turns = 5 }
    )
    emitUsed(ctx, record)
    return { kind = "complete", result = "hit" }
  end
  return stepScreen
end

-- Native weather settles one five-turn field instance; replacement
-- stacking keeps a single live weather system.
---@param key string battle-local definition identity under the weather
---@return fun(ctx: BattleContext, frame: table<string, unknown>): table<string, unknown> step handler starting the weather
local function makeWeather(key)
  local function stepWeather(ctx, frame)
    assert(type(ctx) == "table", "conditions step through the battle context")
    assert(type(frame) == "table", "conditions step from their move frame")
    local record = frame --[[@as table<string, unknown>]]
    ctx:addBattleEffect(
      NativeEffectHandlers.definitionFor(key),
      { kind = "field" },
      moveSource(userOf(record)),
      { version = 1, turns = 5 }
    )
    emitUsed(ctx, record)
    return { kind = "complete", result = "hit" }
  end
  return stepWeather
end

-- Aqua Ring roots recovery on the user entry: one sixteenth of maximum
-- health every residual pass until the entry leaves.
local function stepAquaRing(ctx, frame)
  assert(type(ctx) == "table", "conditions step through the battle context")
  assert(type(frame) == "table", "conditions step from their move frame")
  local record = frame --[[@as table<string, unknown>]]
  local user = userOf(record)
  if ctx:hasBattleEffect(user, "aquaring") then
    return { kind = "complete", result = "failed" }
  end
  ctx:addBattleEffect(
    NativeEffectHandlers.definitionFor("aquaring"),
    activeScope(ctx, user),
    moveSource(user),
    { version = 1 }
  )
  emitUsed(ctx, record)
  return { kind = "complete", result = "hit" }
end

-- Flat half-maximum recovery. Full health refuses without effect; the
-- weather-scaled dawn trio stays explicitly unmodeled.
local function stepRecover(ctx, frame)
  assert(type(ctx) == "table", "conditions step through the battle context")
  assert(type(frame) == "table", "conditions step from their move frame")
  local record = frame --[[@as table<string, unknown>]]
  local user = userOf(record)
  local entry = ctx:entryOf(user)
  if
    entry.hp --[[@as integer]]
    >= entry.maxHp --[[@as integer]]
  then
    return { kind = "complete", result = "failed" }
  end
  local outcome = ctx:heal(user, math.floor(entry.maxHp --[[@as integer]] / 2), causeFor(record))
  ctx:emit("healed", causeFor(record), { target = user, restored = outcome.after - outcome.before })
  emitUsed(ctx, record)
  return { kind = "complete", result = "hit" }
end

-- Roost restores half the battle maximum health through the entry
-- projection, like the flat recovery family. Full health refuses without
-- effect. The grounded-landing type suppression is not yet implemented
-- and is not claimed here.
local function stepRoost(ctx, frame)
  assert(type(ctx) == "table", "conditions step through the battle context")
  assert(type(frame) == "table", "conditions step from their move frame")
  local record = frame --[[@as table<string, unknown>]]
  local user = userOf(record)
  local entry = ctx:entryOf(user)
  if
    entry.hp --[[@as integer]]
    >= entry.maxHp --[[@as integer]]
  then
    return { kind = "complete", result = "failed" }
  end
  local outcome = ctx:heal(user, math.floor(entry.maxHp --[[@as integer]] / 2), causeFor(record))
  ctx:emit("healed", causeFor(record), { target = user, restored = outcome.after - outcome.before })
  return { kind = "complete", result = "hit" }
end

-- Refresh cures the user major condition through the status owner;
-- a healthy user refuses without effect.
local function stepRefresh(ctx, frame)
  assert(type(ctx) == "table", "conditions step through the battle context")
  assert(type(frame) == "table", "conditions step from their move frame")
  local record = frame --[[@as table<string, unknown>]]
  local user = userOf(record)
  local cured = false
  for _, key in ipairs({ "sleep", "poison", "burn", "freeze", "paralysis", "toxic" }) do
    if ctx:cureStatus(user, key, causeFor(record)) then
      cured = true
    end
  end
  if not cured then
    return { kind = "complete", result = "failed" }
  end
  emitUsed(ctx, record)
  return { kind = "complete", result = "hit" }
end

-- Party-wide chimes cure every roster condition through the status
-- owner; a healthy party refuses without effect.
local function stepHealBell(ctx, frame)
  assert(type(ctx) == "table", "conditions step through the battle context")
  assert(type(frame) == "table", "conditions step from their move frame")
  local record = frame --[[@as table<string, unknown>]]
  local cured = false
  for _, combatant in ipairs(ctx:rosterOf(userOf(record))) do
    for _, key in ipairs({ "sleep", "poison", "burn", "freeze", "paralysis", "toxic" }) do
      if ctx:cureStatus(combatant, key, causeFor(record)) then
        cured = true
      end
    end
  end
  if not cured then
    return { kind = "complete", result = "failed" }
  end
  emitUsed(ctx, record)
  return { kind = "complete", result = "hit" }
end

-- Psych Up copies the sampled target stages onto the user entry through
-- the stage owner; identical entries refuse without effect.
local function stepPsychUp(ctx, frame)
  assert(type(ctx) == "table", "conditions step through the battle context")
  assert(type(frame) == "table", "conditions step from their move frame")
  local record = frame --[[@as table<string, unknown>]]
  local user = userOf(record)
  local defender = targetOf((record.targets --[[@as table<integer, unknown>]])[1])
  local mine = ctx:entryOf(user).stages --[[@as table<string, integer>]]
  local theirs = ctx:entryOf(defender).stages --[[@as table<string, integer>]]
  local copied = false
  for _, stat in ipairs({ "attack", "defense", "speed", "specialAttack", "specialDefense", "accuracy", "evasion" }) do
    if mine[stat] ~= theirs[stat] then
      ctx:changeStage(user, stat, theirs[stat] --[[@as integer]], causeFor(record))
      copied = true
    end
  end
  if not copied then
    return { kind = "complete", result = "failed" }
  end
  emitUsed(ctx, record)
  return { kind = "complete", result = "hit" }
end

-- Haze resets every active entry to flat stages through the stage
-- owner; a flat field refuses without effect.
local function stepHaze(ctx, frame)
  assert(type(ctx) == "table", "conditions step through the battle context")
  assert(type(frame) == "table", "conditions step from their move frame")
  local record = frame --[[@as table<string, unknown>]]
  local cleared = false
  for _, combatant in ipairs(ctx:activeCombatants()) do
    local stages = ctx:entryOf(combatant).stages --[[@as table<string, integer>]]
    for _, stat in ipairs({ "attack", "defense", "speed", "specialAttack", "specialDefense", "accuracy", "evasion" }) do
      if stages[stat] ~= 0 then
        ctx:changeStage(combatant, stat, 0, causeFor(record))
        cleared = true
      end
    end
  end
  if not cleared then
    return { kind = "complete", result = "failed" }
  end
  emitUsed(ctx, record)
  return { kind = "complete", result = "hit" }
end

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
  if key == "WISH" then
    return bind(stepWish)
  end
  if key == "ROOST" then
    return bind(stepRoost)
  end
  if key == "PERISH_SONG" then
    return bind(stepPerishSong)
  end
  if key == "LEECH_SEED" then
    return bind(stepLeechSeed)
  end
  if key == "CURSE" then
    return bind(stepCurse)
  end
  if key == "AQUA_RING" then
    return bind(stepAquaRing)
  end
  if key == "REFLECT" then
    return bind(makeScreen("reflect"))
  end
  if key == "LIGHT_SCREEN" then
    return bind(makeScreen("lightscreen"))
  end
  if key == "SAFEGUARD" then
    return bind(makeScreen("safeguard"))
  end
  if key == "MIST" then
    return bind(makeScreen("mist"))
  end
  if key == "RAIN_DANCE" then
    return bind(makeWeather("raindance"))
  end
  if key == "SUNNY_DAY" then
    return bind(makeWeather("sunnyday"))
  end
  if key == "SANDSTORM" then
    return bind(makeWeather("sandstorm"))
  end
  if key == "HAIL" then
    return bind(makeWeather("hail"))
  end
  if key == "RECOVER" or key == "SOFTBOILED" or key == "MILK_DRINK" or key == "SLACK_OFF" or key == "HEAL_ORDER" then
    return bind(stepRecover)
  end
  if key == "REFRESH" then
    return bind(stepRefresh)
  end
  if key == "HEAL_BELL" or key == "AROMATHERAPY" then
    return bind(stepHealBell)
  end
  if key == "PSYCH_UP" then
    return bind(stepPsychUp)
  end
  if key == "HAZE" then
    return bind(stepHaze)
  end
  if STAGE_MOVES[key] ~= nil then
    return bind(makeStage(STAGE_MOVES[key]))
  end
  if SLEEP_MOVES[key] == true then
    return bind(makeStatus("sleep"))
  end
  if PARALYSIS_MOVES[key] == true then
    return bind(makeStatus("paralysis"))
  end
  if POISON_MOVES[key] == true then
    return bind(makeStatus("poison"))
  end
  if key == "TOXIC" then
    return bind(makeStatus("toxic"))
  end
  if key == "WILL_O_WISP" then
    return bind(makeStatus("burn"))
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
