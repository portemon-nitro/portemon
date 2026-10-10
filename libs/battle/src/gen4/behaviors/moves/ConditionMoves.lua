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

---@param ctx BattleContext mechanics context under execution
---@param frame table<string, unknown> move frame under execution
local function emitUsed(ctx, frame)
  local record = frame --[[@as table<string, unknown>]]
  ctx:emit("move-used", causeFor(record), {
    user = userOf(record),
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
---@field mark string? native volatile marker rooted beside the stages

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
  MINIMIZE = { target = "user", changes = { { "evasion", 1 } }, mark = "minimize" },
  SWEET_SCENT = { target = "foe", changes = { { "evasion", -1 } } },
  GROWTH = { target = "user", changes = { { "specialAttack", 1 } } },
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
    -- Marked stage moves root their native marker beside the stages:
    -- minimizing flags the entry for stomping doubles until it leaves.
    if spec.mark ~= nil then
      ctx:addBattleEffect(
        NativeEffectHandlers.definitionFor(spec.mark --[[@as string]]),
        activeScope(ctx, target),
        moveSource(user),
        { version = 1 }
      )
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

-- Side-state gates shared by the volatile-setting family: safeguard
-- blocks confusion, yawn, and major conditions on the defender side,
-- while mist blocks foe-targeted stage drops. Abilities stay with the
-- passive owners, matching the stage and status families. Source
-- references: the condition subscripts in
-- files/battledata/script/subscript and BtlCmd_ChangeStatStage in
-- src/battle/battle_command.c.
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

-- Foe-targeted accuracy that compiled-zero accuracy skips: self and
-- field moves never roll.
---@param ctx BattleContext mechanics context under execution
---@param frame table<string, unknown> move frame under execution
---@param defender integer defender combatant under the roll
---@return boolean true when the condition connects
local function connects(ctx, frame, defender)
  local record = frame --[[@as table<string, unknown>]]
  local locals = record.locals --[[@as table<string, unknown>]]
  local move = locals.move --[[@as table<string, unknown>?]]
  local accuracy = type(move) == "table" and move.accuracy or nil
  if accuracy == 0 then
    return true
  end
  return foeAccuracy(ctx, record, defender)
end

-- Optional battle facts read without failing: gendered and history
-- moves refuse gracefully when their facts never arrive, matching the
-- no-recorded-move failure instead of crashing the session.
---@param frame table<string, unknown> move frame under execution
---@return table<integer, string>? battle gender facts by combatant identity
local function gendersIn(frame)
  local record = frame --[[@as table<string, unknown>]]
  local locals = record.locals --[[@as table<string, unknown>]]
  local genders = locals.genders
  if type(genders) ~= "table" then
    return nil
  end
  return genders --[[@as table<integer, string>]]
end

---@param frame table<string, unknown> move frame under execution
---@return table<integer, string>? recently executed moves by combatant identity
local function recentMovesIn(frame)
  local record = frame --[[@as table<string, unknown>]]
  local locals = record.locals --[[@as table<string, unknown>]]
  local recent = locals.recentMoves
  if type(recent) ~= "table" then
    return nil
  end
  return recent --[[@as table<integer, string>]]
end

-- Confusion application shared by setters and swaggering moves:
-- already-confused defenders refuse, dolls and safeguard absorb.
---@param ctx BattleContext mechanics context under execution
---@param frame table<string, unknown> move frame under execution
---@param defender integer defender combatant under the volatile
---@return boolean true when confusion landed
local function applyConfusion(ctx, frame, defender)
  if ctx:hasBattleEffect(defender, "confusion") then
    return false
  end
  if ctx:hasBattleEffect(defender, "substitute") then
    return false
  end
  if safeguarded(ctx, defender) then
    return false
  end
  local record = frame --[[@as table<string, unknown>]]
  local stream = checkStream(record.stream)
  local turns = 2 + (stream:nextU16("confusion_turns", causeFor(record)) % 4)
  ctx:addBattleEffect(
    NativeEffectHandlers.definitionFor("confusion"),
    activeScope(ctx, defender),
    moveSource(userOf(record)),
    { version = 1, turns = turns }
  )
  return true
end

-- Confusion-setting strikes root a two-to-five-turn volatile on a
-- connecting hit and refuse the already confused.
local function stepConfuse(ctx, frame)
  assert(type(ctx) == "table", "conditions step through the battle context")
  assert(type(frame) == "table", "conditions step from their move frame")
  local record = frame --[[@as table<string, unknown>]]
  local defender = targetOf((record.targets --[[@as table<integer, unknown>]])[1])
  if not connects(ctx, record, defender) then
    return { kind = "complete", result = "missed" }
  end
  if not applyConfusion(ctx, record, defender) then
    return { kind = "complete", result = "failed" }
  end
  emitUsed(ctx, record)
  return { kind = "complete", result = "hit" }
end

-- Attract infatuates across genders and refuses same genders, the
-- genderless, and the already infatuated. Substitute never blocks it.
-- Source reference: BtlCmd_TryAttract in src/battle/battle_command.c.
local function stepAttract(ctx, frame)
  assert(type(ctx) == "table", "conditions step through the battle context")
  assert(type(frame) == "table", "conditions step from their move frame")
  local record = frame --[[@as table<string, unknown>]]
  local defender = targetOf((record.targets --[[@as table<integer, unknown>]])[1])
  if not connects(ctx, record, defender) then
    return { kind = "complete", result = "missed" }
  end
  local genders = gendersIn(record)
  local userGender = type(genders) == "table" and genders[userOf(record)] or nil
  local foeGender = type(genders) == "table" and genders[defender] or nil
  if
    userGender == nil
    or foeGender == nil
    or userGender == foeGender
    or userGender == "genderless"
    or foeGender == "genderless"
  then
    return { kind = "complete", result = "failed" }
  end
  if ctx:hasBattleEffect(defender, "infatuation") then
    return { kind = "complete", result = "failed" }
  end
  ctx:addBattleEffect(
    NativeEffectHandlers.definitionFor("infatuation"),
    activeScope(ctx, defender),
    moveSource(userOf(record)),
    { version = 1 }
  )
  emitUsed(ctx, record)
  return { kind = "complete", result = "hit" }
end

-- Taunt roots a two-to-four-turn volatile and refuses the already
-- taunted. Source reference: the taunt subscript in
-- files/battledata/script/subscript/subscript_0132_TauntStart.s.
local function stepTaunt(ctx, frame)
  assert(type(ctx) == "table", "conditions step through the battle context")
  assert(type(frame) == "table", "conditions step from their move frame")
  local record = frame --[[@as table<string, unknown>]]
  local defender = targetOf((record.targets --[[@as table<integer, unknown>]])[1])
  if not connects(ctx, record, defender) then
    return { kind = "complete", result = "missed" }
  end
  if ctx:hasBattleEffect(defender, "taunt") then
    return { kind = "complete", result = "failed" }
  end
  local stream = checkStream(record.stream)
  local turns = 2 + (stream:nextU16("taunt_turns", causeFor(record)) % 3)
  ctx:addBattleEffect(
    NativeEffectHandlers.definitionFor("taunt"),
    activeScope(ctx, defender),
    moveSource(userOf(record)),
    { version = 1, turns = turns }
  )
  emitUsed(ctx, record)
  return { kind = "complete", result = "hit" }
end

-- Torment marks until the entry leaves and refuses the already
-- tormented. Source reference: the torment subscript in
-- files/battledata/script/subscript/subscript_0127_TormentStart.s.
local function stepTorment(ctx, frame)
  assert(type(ctx) == "table", "conditions step through the battle context")
  assert(type(frame) == "table", "conditions step from their move frame")
  local record = frame --[[@as table<string, unknown>]]
  local defender = targetOf((record.targets --[[@as table<integer, unknown>]])[1])
  if not connects(ctx, record, defender) then
    return { kind = "complete", result = "missed" }
  end
  if ctx:hasBattleEffect(defender, "torment") then
    return { kind = "complete", result = "failed" }
  end
  ctx:addBattleEffect(
    NativeEffectHandlers.definitionFor("torment"),
    activeScope(ctx, defender),
    moveSource(userOf(record)),
    { version = 1 }
  )
  emitUsed(ctx, record)
  return { kind = "complete", result = "hit" }
end

-- Moves encore can never force, transcribed from IsMoveEncored in
-- src/battle/overlay_12_0224E4FC.c.
local ENCORE_BANNED = {
  TRANSFORM = true,
  MIMIC = true,
  SKETCH = true,
  MIRROR_MOVE = true,
  ENCORE = true,
  STRUGGLE = true,
}

-- Encore forces the recorded last move for three-to-seven turns.
-- Source reference: BtlCmd_TryEncore in src/battle/battle_command.c.
local function stepEncore(ctx, frame)
  assert(type(ctx) == "table", "conditions step through the battle context")
  assert(type(frame) == "table", "conditions step from their move frame")
  local record = frame --[[@as table<string, unknown>]]
  local defender = targetOf((record.targets --[[@as table<integer, unknown>]])[1])
  if not connects(ctx, record, defender) then
    return { kind = "complete", result = "missed" }
  end
  local recentMoves = recentMovesIn(record)
  local recent = type(recentMoves) == "table" and recentMoves[defender] or nil
  if type(recent) ~= "string" or recent == "" or ENCORE_BANNED[recent] == true then
    return { kind = "complete", result = "failed" }
  end
  if ctx:hasBattleEffect(defender, "encore") then
    return { kind = "complete", result = "failed" }
  end
  local stream = checkStream(record.stream)
  local turns = 3 + (stream:nextU16("encore_turns", causeFor(record)) % 5)
  ctx:addBattleEffect(
    NativeEffectHandlers.definitionFor("encore"),
    activeScope(ctx, defender),
    moveSource(userOf(record)),
    { version = 1, turns = turns, move = recent }
  )
  emitUsed(ctx, record)
  return { kind = "complete", result = "hit" }
end

-- Disable refuses the recorded last move for three-to-six turns.
-- Source reference: BtlCmd_TryDisable in src/battle/battle_command.c.
local function stepDisable(ctx, frame)
  assert(type(ctx) == "table", "conditions step through the battle context")
  assert(type(frame) == "table", "conditions step from their move frame")
  local record = frame --[[@as table<string, unknown>]]
  local defender = targetOf((record.targets --[[@as table<integer, unknown>]])[1])
  if not connects(ctx, record, defender) then
    return { kind = "complete", result = "missed" }
  end
  local recentMoves = recentMovesIn(record)
  local recent = type(recentMoves) == "table" and recentMoves[defender] or nil
  if type(recent) ~= "string" or recent == "" then
    return { kind = "complete", result = "failed" }
  end
  if ctx:hasBattleEffect(defender, "disable") then
    return { kind = "complete", result = "failed" }
  end
  local stream = checkStream(record.stream)
  local turns = 3 + (stream:nextU16("disable_turns", causeFor(record)) % 4)
  ctx:addBattleEffect(
    NativeEffectHandlers.definitionFor("disable"),
    activeScope(ctx, defender),
    moveSource(userOf(record)),
    { version = 1, turns = turns, move = recent }
  )
  emitUsed(ctx, record)
  return { kind = "complete", result = "hit" }
end

-- Rest cures into a two-turn sleep with full recovery and refuses at
-- full health or while already asleep. Source reference: the rest
-- subscript in files/battledata/script/subscript/subscript_0055_Rest.s.
local function stepRest(ctx, frame)
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
  if ctx:statusOf(user) == "sleep" then
    return { kind = "complete", result = "failed" }
  end
  local prior = ctx:statusOf(user)
  if prior ~= nil then
    ctx:cureStatus(user, prior, causeFor(record))
  end
  ctx:applyStatus(user, "sleep", { turns = 2 }, causeFor(record))
  local outcome = ctx:heal(user, entry.maxHp --[[@as integer]], causeFor(record))
  ctx:emit("healed", causeFor(record), { target = user, restored = outcome.after - outcome.before })
  emitUsed(ctx, record)
  return { kind = "complete", result = "hit" }
end

-- Dawn healing scales with the field sky: half with no weather, two
-- thirds under harsh sun, one quarter otherwise. Source reference:
-- BtlCmd_WeatherHPRecovery in src/battle/battle_command.c.
local function stepDawnHeal(ctx, frame)
  assert(type(ctx) == "table", "conditions step through the battle context")
  assert(type(frame) == "table", "conditions step from their move frame")
  local record = frame --[[@as table<string, unknown>]]
  local user = userOf(record)
  local entry = ctx:entryOf(user)
  local ceiling = entry.maxHp --[[@as integer]]
  if
    entry.hp --[[@as integer]]
    >= ceiling
  then
    return { kind = "complete", result = "failed" }
  end
  local amount = math.floor(ceiling / 2)
  if ctx:fieldEffect("sunnyday") ~= nil then
    amount = math.floor(ceiling * 20 / 30)
  elseif
    ctx:fieldEffect("raindance") ~= nil
    or ctx:fieldEffect("sandstorm") ~= nil
    or ctx:fieldEffect("hail") ~= nil
  then
    amount = math.floor(ceiling / 4)
  end
  local outcome = ctx:heal(user, amount, causeFor(record))
  ctx:emit("healed", causeFor(record), { target = user, restored = outcome.after - outcome.before })
  emitUsed(ctx, record)
  return { kind = "complete", result = "hit" }
end

-- Belly Drum maximizes attack for half its maximum health and refuses
-- at maximum attack or at half health and below. Source reference: the
-- belly drum subscript in
-- files/battledata/script/subscript/subscript_0120_BellyDrum.s.
local function stepBellyDrum(ctx, frame)
  assert(type(ctx) == "table", "conditions step through the battle context")
  assert(type(frame) == "table", "conditions step from their move frame")
  local record = frame --[[@as table<string, unknown>]]
  local user = userOf(record)
  local entry = ctx:entryOf(user)
  local ceiling = entry.maxHp --[[@as integer]]
  if entry.stages.attack == StatStages.MAX then
    return { kind = "complete", result = "failed" }
  end
  if
    entry.hp --[[@as integer]]
    <= math.floor(ceiling / 2)
  then
    return { kind = "complete", result = "failed" }
  end
  ctx:changeStage(user, "attack", StatStages.MAX, causeFor(record))
  ctx:damage(user, math.floor(ceiling / 2), causeFor(record))
  emitUsed(ctx, record)
  return { kind = "complete", result = "hit" }
end

-- Acupressure raises a random raisable stat by two and refuses the
-- fully maximized entry. Source reference: BtlCmd_BoostRandomStatBy2
-- in src/battle/battle_command.c.
local STAT_WHEEL = { "attack", "defense", "speed", "specialAttack", "specialDefense", "accuracy", "evasion" }

local function stepAcupressure(ctx, frame)
  assert(type(ctx) == "table", "conditions step through the battle context")
  assert(type(frame) == "table", "conditions step from their move frame")
  local record = frame --[[@as table<string, unknown>]]
  local user = userOf(record)
  local current = ctx:entryOf(user).stages --[[@as table<string, integer>]]
  local raisable = {}
  for _, stat in ipairs(STAT_WHEEL) do
    if
      current[stat] --[[@as integer]]
      < StatStages.MAX
    then
      raisable[#raisable + 1] = stat
    end
  end
  if #raisable == 0 then
    return { kind = "complete", result = "failed" }
  end
  local stream = checkStream(record.stream)
  local picked = raisable[(stream:nextU16("acupressure_stat", causeFor(record)) % #raisable) + 1]
  local next = StatStages.change(
    current[
      picked --[[@as string]]
    ] --[[@as integer]],
    2
  )
  ctx:changeStage(user, picked --[[@as string]], next, causeFor(record))
  emitUsed(ctx, record)
  return { kind = "complete", result = "hit" }
end

-- Lock-On and Mind Reader promise the next strike past accuracy; a
-- marked doll absorbs the aim. Source reference: the lock-on subscript
-- in files/battledata/script/subscript/subscript_0079_LockOn.s.
local function stepLockOn(ctx, frame)
  assert(type(ctx) == "table", "conditions step through the battle context")
  assert(type(frame) == "table", "conditions step from their move frame")
  local record = frame --[[@as table<string, unknown>]]
  local defender = targetOf((record.targets --[[@as table<integer, unknown>]])[1])
  if not connects(ctx, record, defender) then
    return { kind = "complete", result = "missed" }
  end
  if ctx:hasBattleEffect(defender, "substitute") then
    return { kind = "complete", result = "failed" }
  end
  ctx:addBattleEffect(
    NativeEffectHandlers.definitionFor("lockon"),
    activeScope(ctx, defender),
    moveSource(userOf(record)),
    { version = 1, attacker = userOf(record) }
  )
  emitUsed(ctx, record)
  return { kind = "complete", result = "hit" }
end

-- Foresight and Odor Sleuth identify the defender unconditionally,
-- dropping ghost immunity for normal and fighting strikes and pinning
-- negative evasion at zero. Source reference: the foresight subscript
-- in files/battledata/script/subscript/subscript_0100_Foresight.s.
local function stepForesight(ctx, frame)
  assert(type(ctx) == "table", "conditions step through the battle context")
  assert(type(frame) == "table", "conditions step from their move frame")
  local record = frame --[[@as table<string, unknown>]]
  local defender = targetOf((record.targets --[[@as table<integer, unknown>]])[1])
  ctx:addBattleEffect(
    NativeEffectHandlers.definitionFor("foresight"),
    activeScope(ctx, defender),
    moveSource(userOf(record)),
    { version = 1 }
  )
  emitUsed(ctx, record)
  return { kind = "complete", result = "hit" }
end

-- Magnet Rise levitates for five turns and refuses the already rising
-- and the rooted.
local function stepMagnetRise(ctx, frame)
  assert(type(ctx) == "table", "conditions step through the battle context")
  assert(type(frame) == "table", "conditions step from their move frame")
  local record = frame --[[@as table<string, unknown>]]
  local user = userOf(record)
  if ctx:hasBattleEffect(user, "magnetrise") or ctx:hasBattleEffect(user, "ingrain") then
    return { kind = "complete", result = "failed" }
  end
  ctx:addBattleEffect(
    NativeEffectHandlers.definitionFor("magnetrise"),
    activeScope(ctx, user),
    moveSource(user),
    { version = 1, turns = 5 }
  )
  emitUsed(ctx, record)
  return { kind = "complete", result = "hit" }
end

-- Tailwind doubles its side speed window for three turns and refuses
-- the duplicate; lucky chant shields its side for five turns and
-- refuses the duplicate.
local function stepTailwind(ctx, frame)
  assert(type(ctx) == "table", "conditions step through the battle context")
  assert(type(frame) == "table", "conditions step from their move frame")
  local record = frame --[[@as table<string, unknown>]]
  local side = ctx:entryOf(userOf(record)).side
  if ctx:sideEffect(side, "tailwind") ~= nil then
    return { kind = "complete", result = "failed" }
  end
  ctx:addBattleEffect(
    NativeEffectHandlers.definitionFor("tailwind"),
    { kind = "side", side = side },
    moveSource(userOf(record)),
    { version = 1, turns = 3 }
  )
  emitUsed(ctx, record)
  return { kind = "complete", result = "hit" }
end

local function stepLuckyChant(ctx, frame)
  assert(type(ctx) == "table", "conditions step through the battle context")
  assert(type(frame) == "table", "conditions step from their move frame")
  local record = frame --[[@as table<string, unknown>]]
  local side = ctx:entryOf(userOf(record)).side
  if ctx:sideEffect(side, "luckychant") ~= nil then
    return { kind = "complete", result = "failed" }
  end
  ctx:addBattleEffect(
    NativeEffectHandlers.definitionFor("luckychant"),
    { kind = "side", side = side },
    moveSource(userOf(record)),
    { version = 1, turns = 5 }
  )
  emitUsed(ctx, record)
  return { kind = "complete", result = "hit" }
end

-- Gravity grounds the field for five turns, dropping rising entries
-- back down, and refuses the duplicate.
local function stepGravity(ctx, frame)
  assert(type(ctx) == "table", "conditions step through the battle context")
  assert(type(frame) == "table", "conditions step from their move frame")
  local record = frame --[[@as table<string, unknown>]]
  if ctx:fieldEffect("gravity") ~= nil then
    return { kind = "complete", result = "failed" }
  end
  ctx:addBattleEffect(
    NativeEffectHandlers.definitionFor("gravity"),
    { kind = "field" },
    moveSource(userOf(record)),
    { version = 1, turns = 5 }
  )
  for _, combatant in ipairs(ctx:activeCombatants()) do
    ctx:removeBattleEffect(combatant, "magnetrise")
  end
  emitUsed(ctx, record)
  return { kind = "complete", result = "hit" }
end

-- Trick Room twists the dimensions for five turns and untwists on
-- reuse. Source reference: the trick room effect script in
-- files/battledata/script/effect_script/effect_script_0259.s.
local function stepTrickRoom(ctx, frame)
  assert(type(ctx) == "table", "conditions step through the battle context")
  assert(type(frame) == "table", "conditions step from their move frame")
  local record = frame --[[@as table<string, unknown>]]
  if ctx:fieldEffect("trickroom") ~= nil then
    ctx:removeFieldEffect("trickroom")
    emitUsed(ctx, record)
    return { kind = "complete", result = "hit" }
  end
  ctx:addBattleEffect(
    NativeEffectHandlers.definitionFor("trickroom"),
    { kind = "field" },
    moveSource(userOf(record)),
    { version = 1, turns = 5 }
  )
  emitUsed(ctx, record)
  return { kind = "complete", result = "hit" }
end

-- Sports weaken their type while the user stands and refuse the
-- duplicate.
local function stepSport(key)
  local function stepSported(ctx, frame)
    assert(type(ctx) == "table", "conditions step through the battle context")
    assert(type(frame) == "table", "conditions step from their move frame")
    local record = frame --[[@as table<string, unknown>]]
    local user = userOf(record)
    if ctx:hasBattleEffect(user, key) then
      return { kind = "complete", result = "failed" }
    end
    local entry = ctx:entryOf(user)
    if entry.activation == nil then
      error(BattleErrors.invalidState("battle-local sports scope to a live entry", {}))
    end
    ctx:addBattleEffect(
      NativeEffectHandlers.definitionFor(key),
      { kind = "active", combatant = user, activation = entry.activation },
      moveSource(user),
      { version = 1 }
    )
    emitUsed(ctx, record)
    return { kind = "complete", result = "hit" }
  end
  return stepSported
end

-- Spite cuts four power points from the recorded last move and refuses
-- without one. Source reference: BtlCmd_TrySpite in
-- src/battle/battle_command.c.
local function stepSpite(ctx, frame)
  assert(type(ctx) == "table", "conditions step through the battle context")
  assert(type(frame) == "table", "conditions step from their move frame")
  local record = frame --[[@as table<string, unknown>]]
  local defender = targetOf((record.targets --[[@as table<integer, unknown>]])[1])
  if not connects(ctx, record, defender) then
    return { kind = "complete", result = "missed" }
  end
  local recentMoves = recentMovesIn(record)
  local recent = type(recentMoves) == "table" and recentMoves[defender] or nil
  if type(recent) ~= "string" or recent == "" then
    return { kind = "complete", result = "failed" }
  end
  if
    ctx:cutPp(defender, recent --[[@as string]], 4) == 0
  then
    return { kind = "complete", result = "failed" }
  end
  emitUsed(ctx, record)
  return { kind = "complete", result = "hit" }
end

-- Teleport fails trainer battles through its battle-kind fact; without
-- a battle-ending surface wild flight stays a documented follow-up.
-- Source reference: the teleport subscript in
-- files/battledata/script/subscript/subscript_0122_Teleport.s.
local function stepTeleport(ctx, frame)
  assert(type(ctx) == "table", "conditions step through the battle context")
  assert(type(frame) == "table", "conditions step from their move frame")
  -- Teleport refuses trainer battles through the battle-kind law, and
  -- wild flight stays refused until a battle-ending surface exists: the
  -- move layer cannot end battles, so refusal is the safe closed
  -- answer in both scopes for now.
  return { kind = "complete", result = "failed" }
end

-- Captivate drops special attack by two for opposite genders and
-- refuses same genders, the genderless, and dolls.
local function stepCaptivate(ctx, frame)
  assert(type(ctx) == "table", "conditions step through the battle context")
  assert(type(frame) == "table", "conditions step from their move frame")
  local record = frame --[[@as table<string, unknown>]]
  local defender = targetOf((record.targets --[[@as table<integer, unknown>]])[1])
  if not connects(ctx, record, defender) then
    return { kind = "complete", result = "missed" }
  end
  local genders = gendersIn(record)
  local userGender = type(genders) == "table" and genders[userOf(record)] or nil
  local foeGender = type(genders) == "table" and genders[defender] or nil
  if
    userGender == nil
    or foeGender == nil
    or userGender == foeGender
    or userGender == "genderless"
    or foeGender == "genderless"
  then
    return { kind = "complete", result = "failed" }
  end
  if ctx:hasBattleEffect(defender, "substitute") then
    return { kind = "complete", result = "failed" }
  end
  if misted(ctx, defender) then
    return { kind = "complete", result = "failed" }
  end
  local current = ctx:entryOf(defender).stages --[[@as table<string, integer>]]
  local next = StatStages.change(current.specialAttack --[[@as integer]], -2)
  if next == current.specialAttack then
    return { kind = "complete", result = "failed" }
  end
  ctx:changeStage(defender, "specialAttack", next, causeFor(record))
  emitUsed(ctx, record)
  return { kind = "complete", result = "hit" }
end

-- Swagger sharpens attack by two while confusing, flatter sharpens
-- special attack by one while confusing, and teeter dance confuses.
-- Already-maxed attackers skip the climb but still dance; already
-- confused defenders skip the dance but still climb. Source references:
-- the swagger and flatter subscripts in
-- files/battledata/script/subscript.
local function swaggerLike(spec)
  local function stepSwaggerLike(ctx, frame)
    assert(type(ctx) == "table", "conditions step through the battle context")
    assert(type(frame) == "table", "conditions step from their move frame")
    local record = frame --[[@as table<string, unknown>]]
    local defender = targetOf((record.targets --[[@as table<integer, unknown>]])[1])
    if not connects(ctx, record, defender) then
      return { kind = "complete", result = "missed" }
    end
    if ctx:hasBattleEffect(defender, "substitute") then
      return { kind = "complete", result = "failed" }
    end
    if misted(ctx, defender) then
      return { kind = "complete", result = "failed" }
    end
    local climbed = false
    if spec.stat ~= nil then
      local current = ctx:entryOf(defender).stages --[[@as table<string, integer>]]
      local stat = spec.stat --[[@as string]]
      local next = StatStages.change(current[stat] --[[@as integer]], spec.delta --[[@as integer]])
      if next ~= current[stat] then
        ctx:changeStage(defender, stat, next, causeFor(record))
        climbed = true
      end
    end
    local danced = applyConfusion(ctx, record, defender)
    if not climbed and not danced then
      return { kind = "complete", result = "failed" }
    end
    emitUsed(ctx, record)
    return { kind = "complete", result = "hit" }
  end
  return stepSwaggerLike
end

-- Focus energy sharpens later strikes until the entry leaves and
-- refuses the already focused.
local function stepFocusEnergy(ctx, frame)
  assert(type(ctx) == "table", "conditions step through the battle context")
  assert(type(frame) == "table", "conditions step from their move frame")
  local record = frame --[[@as table<string, unknown>]]
  local user = userOf(record)
  if ctx:hasBattleEffect(user, "focusenergy") then
    return { kind = "complete", result = "failed" }
  end
  ctx:addBattleEffect(
    NativeEffectHandlers.definitionFor("focusenergy"),
    activeScope(ctx, user),
    moveSource(user),
    { version = 1 }
  )
  emitUsed(ctx, record)
  return { kind = "complete", result = "hit" }
end

-- Ingrain roots healing on the user while holding it down.
local function stepIngrain(ctx, frame)
  assert(type(ctx) == "table", "conditions step through the battle context")
  assert(type(frame) == "table", "conditions step from their move frame")
  local record = frame --[[@as table<string, unknown>]]
  local user = userOf(record)
  if ctx:hasBattleEffect(user, "ingrain") or ctx:hasBattleEffect(user, "trapped") then
    return { kind = "complete", result = "failed" }
  end
  ctx:addBattleEffect(
    NativeEffectHandlers.definitionFor("ingrain"),
    activeScope(ctx, user),
    moveSource(user),
    { version = 1 }
  )
  ctx:addBattleEffect(
    NativeEffectHandlers.definitionFor("trapped"),
    activeScope(ctx, user),
    moveSource(user),
    { version = 1 }
  )
  emitUsed(ctx, record)
  return { kind = "complete", result = "hit" }
end

-- Yawn drowses healthy, unshielded defenders; the drowsiness counts
-- the defender actions down to sleep through the before-action timing.
local function stepYawn(ctx, frame)
  assert(type(ctx) == "table", "conditions step through the battle context")
  assert(type(frame) == "table", "conditions step from their move frame")
  local record = frame --[[@as table<string, unknown>]]
  local defender = targetOf((record.targets --[[@as table<integer, unknown>]])[1])
  if not connects(ctx, record, defender) then
    return { kind = "complete", result = "missed" }
  end
  if ctx:statusOf(defender) ~= nil then
    return { kind = "complete", result = "failed" }
  end
  if ctx:hasBattleEffect(defender, "substitute") then
    return { kind = "complete", result = "failed" }
  end
  if safeguarded(ctx, defender) then
    return { kind = "complete", result = "failed" }
  end
  if ctx:hasBattleEffect(defender, "yawn") then
    return { kind = "complete", result = "failed" }
  end
  ctx:addBattleEffect(
    NativeEffectHandlers.definitionFor("yawn"),
    activeScope(ctx, defender),
    moveSource(userOf(record)),
    { version = 1, turns = 2 }
  )
  emitUsed(ctx, record)
  return { kind = "complete", result = "hit" }
end

-- Hazard layers settle on the foe side: spikes stack to three,
-- toxic spikes stack to two, and stealth rock settles once. Duplicates
-- refuse. Source references: BtlCmd_TrySpikes, BtlCmd_TryToxicSpikes,
-- and BtlCmd_CheckStealthRock in src/battle/battle_command.c.
---@param ctx BattleContext mechanics context under execution
---@param frame table<string, unknown> move frame under execution
---@param defender integer defender combatant addressing the foe side
---@param key string hazard definition identity under the layers
---@param limit integer maximum layers on the side
---@return boolean true when another layer settled
local function layHazard(ctx, frame, defender, key, limit)
  local record = frame --[[@as table<string, unknown>]]
  local user = userOf(record)
  local side = ctx:entryOf(defender).side
  if side == ctx:entryOf(user).side then
    error(BattleErrors.invalidState("hazards settle on the foe side", {}))
  end
  local standing = ctx:sideEffect(side, key)
  local layers = 0
  if standing ~= nil then
    layers = (standing --[[@as table<string, unknown>]])
      .state --[[@as table<string, unknown>]]
      .layers --[[@as integer]]
  end
  if layers >= limit then
    return false
  end
  if standing ~= nil then
    ctx:removeBattleEffect(defender, key)
  end
  ctx:addBattleEffect(
    NativeEffectHandlers.definitionFor(key),
    { kind = "side", side = side },
    moveSource(user),
    { version = 1, layers = layers + 1 }
  )
  return true
end

local function stepSpikes(ctx, frame)
  assert(type(ctx) == "table", "conditions step through the battle context")
  assert(type(frame) == "table", "conditions step from their move frame")
  local record = frame --[[@as table<string, unknown>]]
  local defender = targetOf((record.targets --[[@as table<integer, unknown>]])[1])
  if not layHazard(ctx, record, defender, "spikes", 3) then
    return { kind = "complete", result = "failed" }
  end
  emitUsed(ctx, record)
  return { kind = "complete", result = "hit" }
end

local function stepToxicSpikes(ctx, frame)
  assert(type(ctx) == "table", "conditions step through the battle context")
  assert(type(frame) == "table", "conditions step from their move frame")
  local record = frame --[[@as table<string, unknown>]]
  local defender = targetOf((record.targets --[[@as table<integer, unknown>]])[1])
  if not layHazard(ctx, record, defender, "toxicspikes", 2) then
    return { kind = "complete", result = "failed" }
  end
  emitUsed(ctx, record)
  return { kind = "complete", result = "hit" }
end

local function stepStealthRock(ctx, frame)
  assert(type(ctx) == "table", "conditions step through the battle context")
  assert(type(frame) == "table", "conditions step from their move frame")
  local record = frame --[[@as table<string, unknown>]]
  local user = userOf(record)
  local defender = targetOf((record.targets --[[@as table<integer, unknown>]])[1])
  local side = ctx:entryOf(defender).side
  if side == ctx:entryOf(user).side then
    error(BattleErrors.invalidState("hazards settle on the foe side", {}))
  end
  if ctx:sideEffect(side, "stealthrock") ~= nil then
    return { kind = "complete", result = "failed" }
  end
  ctx:addBattleEffect(
    NativeEffectHandlers.definitionFor("stealthrock"),
    { kind = "side", side = side },
    moveSource(user),
    { version = 1 }
  )
  emitUsed(ctx, record)
  return { kind = "complete", result = "hit" }
end

-- Trapping moves hold the defender while refusing ghosts through the
-- chart, dolls, and the already trapped. Source reference: the mean
-- look subscript in
-- files/battledata/script/subscript/subscript_0086_MeanLook.s.
local function stepTrapHold(ctx, frame)
  assert(type(ctx) == "table", "conditions step through the battle context")
  assert(type(frame) == "table", "conditions step from their move frame")
  local record = frame --[[@as table<string, unknown>]]
  local defender = targetOf((record.targets --[[@as table<integer, unknown>]])[1])
  if not connects(ctx, record, defender) then
    return { kind = "complete", result = "missed" }
  end
  if statusImmune(record, defender) then
    return { kind = "complete", result = "failed" }
  end
  if ctx:hasBattleEffect(defender, "substitute") then
    return { kind = "complete", result = "failed" }
  end
  if ctx:hasBattleEffect(defender, "trapped") or ctx:hasBattleEffect(defender, "bind") then
    return { kind = "complete", result = "failed" }
  end
  ctx:addBattleEffect(
    NativeEffectHandlers.definitionFor("trapped"),
    activeScope(ctx, defender),
    moveSource(userOf(record)),
    { version = 1 }
  )
  emitUsed(ctx, record)
  return { kind = "complete", result = "hit" }
end

-- Nightmare roots quarter-maximum residual damage on sleeping
-- defenders behind a doll check.
local function stepNightmare(ctx, frame)
  assert(type(ctx) == "table", "conditions step through the battle context")
  assert(type(frame) == "table", "conditions step from their move frame")
  local record = frame --[[@as table<string, unknown>]]
  local defender = targetOf((record.targets --[[@as table<integer, unknown>]])[1])
  if not connects(ctx, record, defender) then
    return { kind = "complete", result = "missed" }
  end
  if ctx:statusOf(defender) ~= "sleep" then
    return { kind = "complete", result = "failed" }
  end
  if ctx:hasBattleEffect(defender, "substitute") then
    return { kind = "complete", result = "failed" }
  end
  if ctx:hasBattleEffect(defender, "nightmare") then
    return { kind = "complete", result = "failed" }
  end
  ctx:addBattleEffect(
    NativeEffectHandlers.definitionFor("nightmare"),
    activeScope(ctx, defender),
    moveSource(userOf(record)),
    { version = 1, turns = 1 }
  )
  emitUsed(ctx, record)
  return { kind = "complete", result = "hit" }
end

-- Closed condition bindings: one definition per bound move, assembled in
-- the same precedence the long selection chain used. A step entry names
-- its shared body; a build entry produces a fresh configured handler per
-- move, so aliases share behavior but never wrapper identity. The table
-- rejects duplicate authored identities instead of replacing them, and
-- registration wraps a fresh handler for each member in member order.
---@class ConditionBinding
---@field step fun(ctx: BattleContext, frame: table<string, unknown>): table<string, unknown> | nil shared body under a fresh wrapper
---@field build (fun(): fun(ctx: BattleContext, frame: table<string, unknown>): table<string, unknown>) | nil factory producing a fresh handler per move

---@type table<string, ConditionBinding>
local BINDINGS = {}

---@param key string condition move identity under definition
---@param entry ConditionBinding binding definition for the move
local function define(key, entry)
  assert(type(key) == "string" and key ~= "", "condition bindings carry their move identity")
  assert(type(entry) == "table", "condition bindings carry their definition")
  if BINDINGS[key] ~= nil then
    error(BattleErrors.invalidState("condition bindings carry each move identity once", { key = key }))
  end
  BINDINGS[key] = entry
end

---@param screen string screen identity under the move
---@return ConditionBinding binding definition producing a fresh screen handler per move
local function screenBinding(screen)
  local function buildScreen()
    return makeScreen(screen)
  end
  return { build = buildScreen }
end

---@param sky string weather identity under the move
---@return ConditionBinding binding definition producing a fresh weather handler per move
local function weatherBinding(sky)
  local function buildSky()
    return makeWeather(sky)
  end
  return { build = buildSky }
end

---@param status string major condition under the move
---@return ConditionBinding binding definition producing a fresh status handler per move
local function statusBinding(status)
  local function buildStatus()
    return makeStatus(status)
  end
  return { build = buildStatus }
end

---@param spec StageSpec stage family under the move
---@return ConditionBinding binding definition producing a fresh stage handler per move
local function stageBinding(spec)
  local function buildStage()
    return makeStage(spec)
  end
  return { build = buildStage }
end

---@param arena string sport identity under the move
---@return ConditionBinding binding definition producing a fresh sport handler per move
local function sportBinding(arena)
  local function buildSport()
    return stepSport(arena)
  end
  return { build = buildSport }
end

---@param spec table<string, unknown> confusion shape under the move
---@return ConditionBinding binding definition producing a fresh confusion handler per move
local function swaggerBinding(spec)
  local function buildSwagger()
    return swaggerLike(spec)
  end
  return { build = buildSwagger }
end

define("SPLASH", { step = stepSplash })
define("PAIN_SPLIT", { step = stepPainSplit })
define("MEMENTO", { step = stepMemento })
define("WISH", { step = stepWish })
define("ROOST", { step = stepRoost })
define("PERISH_SONG", { step = stepPerishSong })
define("LEECH_SEED", { step = stepLeechSeed })
define("CURSE", { step = stepCurse })
define("AQUA_RING", { step = stepAquaRing })
define("REFLECT", screenBinding("reflect"))
define("LIGHT_SCREEN", screenBinding("lightscreen"))
define("SAFEGUARD", screenBinding("safeguard"))
define("MIST", screenBinding("mist"))
define("RAIN_DANCE", weatherBinding("raindance"))
define("SUNNY_DAY", weatherBinding("sunnyday"))
define("SANDSTORM", weatherBinding("sandstorm"))
define("HAIL", weatherBinding("hail"))
define("RECOVER", { step = stepRecover })
define("SOFTBOILED", { step = stepRecover })
define("MILK_DRINK", { step = stepRecover })
define("SLACK_OFF", { step = stepRecover })
define("HEAL_ORDER", { step = stepRecover })
define("REFRESH", { step = stepRefresh })
define("HEAL_BELL", { step = stepHealBell })
define("AROMATHERAPY", { step = stepHealBell })
define("PSYCH_UP", { step = stepPsychUp })
define("HAZE", { step = stepHaze })

for key, spec in pairs(STAGE_MOVES) do
  local stageKey = key
  local stageSpec = spec
  define(stageKey, stageBinding(stageSpec))
end

for key in pairs(SLEEP_MOVES) do
  define(key, statusBinding("sleep"))
end

for key in pairs(PARALYSIS_MOVES) do
  define(key, statusBinding("paralysis"))
end

for key in pairs(POISON_MOVES) do
  define(key, statusBinding("poison"))
end

define("TOXIC", statusBinding("toxic"))
define("WILL_O_WISP", statusBinding("burn"))
define("CONFUSE_RAY", { step = stepConfuse })
define("SUPERSONIC", { step = stepConfuse })
define("SWEET_KISS", { step = stepConfuse })
define("ATTRACT", { step = stepAttract })
define("TAUNT", { step = stepTaunt })
define("TORMENT", { step = stepTorment })
define("ENCORE", { step = stepEncore })
define("DISABLE", { step = stepDisable })
define("YAWN", { step = stepYawn })
define("NIGHTMARE", { step = stepNightmare })
define("SPIKES", { step = stepSpikes })
define("TOXIC_SPIKES", { step = stepToxicSpikes })
define("STEALTH_ROCK", { step = stepStealthRock })
define("MEAN_LOOK", { step = stepTrapHold })
define("SPIDER_WEB", { step = stepTrapHold })
define("REST", { step = stepRest })
define("MOONLIGHT", { step = stepDawnHeal })
define("SYNTHESIS", { step = stepDawnHeal })
define("BELLY_DRUM", { step = stepBellyDrum })
define("ACUPRESSURE", { step = stepAcupressure })
define("LOCK_ON", { step = stepLockOn })
define("MIND_READER", { step = stepLockOn })
define("FORESIGHT", { step = stepForesight })
define("ODOR_SLEUTH", { step = stepForesight })
define("MAGNET_RISE", { step = stepMagnetRise })
define("TAILWIND", { step = stepTailwind })
define("LUCKY_CHANT", { step = stepLuckyChant })
define("GRAVITY", { step = stepGravity })
define("TRICK_ROOM", { step = stepTrickRoom })
define("MUD_SPORT", sportBinding("mudsport"))
define("WATER_SPORT", sportBinding("watersport"))
define("SPITE", { step = stepSpite })
define("TELEPORT", { step = stepTeleport })
define("CAPTIVATE", { step = stepCaptivate })
define("SWAGGER", swaggerBinding({ stat = "attack", delta = 2 }))
define("FLATTER", swaggerBinding({ stat = "specialAttack", delta = 1 }))
define("TEETER_DANCE", swaggerBinding({}))
define("FOCUS_ENERGY", { step = stepFocusEnergy })
define("INGRAIN", { step = stepIngrain })

-- Members without an authored binding keep the explicit unmodeled
-- failure; identities outside the family never gain a handler here.
local CANONICAL = {}
for _, key in ipairs(ConditionMoves.MEMBERS) do
  if BINDINGS[key] == nil then
    CANONICAL[key] = true
  end
end

---@param key string condition move identity under binding
---@return fun(ctx: BattleContext, frame: table<string, unknown>): table<string, unknown> distinct per-move handler for the registry
local function bodyFor(key)
  local entry = BINDINGS[key]
  if entry ~= nil then
    local step = entry.step
    if step ~= nil then
      return bind(step)
    end
    local build = entry.build
    assert(build ~= nil, "condition bindings carry either a step or a factory")
    return bind(build())
  end
  if CANONICAL[key] == true then
    return bind(stepCanonical)
  end
  error(BattleErrors.invalidState("condition bindings admit only their family members", { key = key }))
end

--- Binds the condition family handlers into the owner table.
---@param owned table<string, fun(ctx: BattleContext, frame: table<string, unknown>): table<string, unknown>> handler owner receiving the family bindings
function ConditionMoves.register(owned)
  assert(type(owned) == "table", "condition moves register into their owner table")
  local seen = {}
  for _, key in ipairs(ConditionMoves.MEMBERS) do
    if seen[key] ~= nil then
      error(BattleErrors.invalidState("condition moves register each member once", { key = key }))
    end
    seen[key] = true
    owned[key] = bodyFor(key)
  end
end

return ConditionMoves
