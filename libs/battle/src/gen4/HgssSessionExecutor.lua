-- Private native battle lifetime for the HGSS ruleset. This session speaks
-- the shared battle protocol (decision batches, sealed replies, detached
-- views, plain-data snapshots, exactly-once disposal) while every committed
-- choice runs through the native turn owners instead of the generic
-- one-point strike: submitted batches become ordered native actions, strikes
-- execute through the shared move continuation with the combatant facts the
-- records carry and the immutable move facts the session carries, knockouts
-- settle through the faint owner with ordered reserve replacement, and each
-- turn closes through the residual and outcome owners. Choices the records
-- cannot back (no usable move entry) execute the explicit struggle action
-- rather than guessing. Live combat projections derive at execution time
-- from the session species facts through the mon domain owners: strike
-- priority reads the selected move's compiled priority, Speed samples the
-- stage-adjusted materialized stat, and ordinary damage resolves STAB and
-- effectiveness through the session chart. Facts the records cannot back
-- stay absent from the move frames, so executions needing them fail
-- explicitly instead of guessing; finite effect instances created by
-- mechanics run through the shared dispatcher at their entry,
-- before-action, and residual checkpoints with timing-specific native
-- semantics. Eligible knockouts pay
-- experience, effort, levels, and move learning through the resumable reward
-- owner before replacement or the terminal result: full move sets suspend on
-- a learning prompt until its reply is consumed, and level gains accumulate
-- once for post-battle handling without evolving mid-battle. Fainted combatants
-- leave the field and never act again; sides fight short-handed only while
-- no living reserve can fill the vacated position, and the outcome names
-- the surviving standings once every mandatory replacement resolves.
-- Battles never end by round count: the round counter only sequences turns.

local ActionQueue = require("libs.battle.src.gen4.ActionQueue")
local BattleContext = require("libs.battle.src.BattleContext")
local BattleErrors = require("libs.battle.src.errors")
local BattleProtocol = require("libs.battle.src.BattleProtocol")
local BattleRng = require("libs.battle.src.gen4.BattleRng")
local BattleScenario = require("libs.battle.src.BattleScenario")
local BattleSnapshot = require("libs.battle.src.BattleSnapshot")
local BattleState = require("libs.battle.src.BattleState")
local BattleView = require("libs.battle.src.BattleView")
local Capture = require("libs.battle.src.gen4.Capture")
local CaptureContext = require("libs.battle.src.gen4.CaptureContext")
local EffectBag = require("libs.battle.src.EffectBag")
local EffectDispatch = require("libs.battle.src.EffectDispatch")
local Escape = require("libs.battle.src.gen4.Escape")
local Experience = require("libs.mons.src.gen4.Experience")
local Fainting = require("libs.battle.src.gen4.Fainting")
local HgssRuleset = require("libs.battle.src.gen4.HgssRuleset")
local HgssSchedule = require("libs.battle.src.gen4.HgssSchedule")
local ItemUse = require("libs.battle.src.gen4.ItemUse")
local MoveExecution = require("libs.battle.src.gen4.MoveExecution")
local NativeEffectHandlers = require("libs.battle.src.gen4.behaviors.effects.NativeEffectHandlers")
local NativeFormats = require("libs.battle.src.gen4.formats.NativeFormats")
local NativePassiveBridge = require("libs.battle.src.gen4.NativePassiveBridge")
local OutcomePolicy = require("libs.battle.src.gen4.OutcomePolicy")
local Personality = require("libs.mons.src.gen4.Personality")
local Progression = require("libs.battle.src.gen4.Progression")
local Residuals = require("libs.battle.src.gen4.Residuals")
local StatStages = require("libs.battle.src.gen4.StatStages")
local RewardEffort = require("libs.battle.src.gen4.Effort")
local RewardExperience = require("libs.battle.src.gen4.Experience")
local Stats = require("libs.mons.src.gen4.Stats")
local Status = require("libs.battle.src.gen4.Status")
local Switching = require("libs.battle.src.gen4.Switching")
local TrainerAi = require("libs.battle.src.gen4.TrainerAi")
local TurnOrder = require("libs.battle.src.gen4.TurnOrder")

---@alias SpeciesFormFacts table<integer, table<string, unknown>>

---@class HgssSessionExecutor
---@field private _state table<string, unknown>?
---@field private _content table<string, unknown>?
---@field private _admitted string[]
---@field private _battleKind string
---@field private _moveFacts table<string, table<string, unknown>>
---@field private _speciesFacts table<string, SpeciesFormFacts>
---@field private _itemFacts table<string, table<string, unknown>>
---@field private _chart table<string, unknown>
---@field private _moneyUpItems table<string, boolean>
---@field private _ruleset table<string, unknown>?
---@field private _commitLearningHandler fun(state: table<string, unknown>)?
---@field private _decisionLease boolean?
---@field private _trainerProvisional table<integer, table<string, integer>>
---@field private _finalized boolean
---@field private _disposed boolean
local HgssSessionExecutor = {}
HgssSessionExecutor.__index = HgssSessionExecutor

-- The one native ruleset identity dispatched by the common battle
-- entrypoint. Exact match only: every other bound ruleset keeps the
-- generic executor.
HgssSessionExecutor.RULESET = "hgss:battle"
HgssSessionExecutor.DECISION_KIND = "action"

HgssSessionExecutor.DEFAULT_ACTION_KINDS = { "attack", "switch", "confirm", "item" }

-- Encounter kind selects the flight and capture policy. Production wild
-- encounters run the "wild-single" format while trainer battles run
-- "single"/"double"; an explicit scenario kind wins when present so
-- format overrides never flip the policy, and unknown formats refuse
-- flight and balls rather than guessing wild behavior.
---@param formatKey string format identity owning the encounter
---@param scenarioKind unknown scenario kind carrying the encounter class, when present
---@return string "wild" for runnable wild encounters, "trainer" otherwise
local function battleKindFor(formatKey, scenarioKind)
  if scenarioKind == "wild" or scenarioKind == "trainer" then
    return scenarioKind --[[@as string]]
  end
  if formatKey == "wild-single" then
    return "wild"
  end
  return "trainer"
end

-- Action brackets for turn ordering. Exchanges and item use run on the
-- source escape bracket, ahead of any strike. Strikes never share one
-- bracket: every strike samples the selected move's compiled priority.
-- Prompts carry no battlefield effect and share the neutral bracket.
-- Move-learning prompts suspend faint settlement through the shared
-- decision protocol: one learn_move request carrying the incoming move,
-- the current set, and whether decline is allowed, answered with exactly
-- one confirm choice per addressed recipient reusing the reward vocabulary.
HgssSessionExecutor.LEARN_DECISION_KIND = "learn_move"
if not BattleProtocol.isDecisionKind(HgssSessionExecutor.LEARN_DECISION_KIND) then
  BattleProtocol.registerDecisionKind(HgssSessionExecutor.LEARN_DECISION_KIND, { "confirm" })
end
local ESCAPE_BRACKET = 6

---@param value unknown
---@return unknown
local function copyValue(value)
  if type(value) ~= "table" then
    return value
  end
  local input = value --[[@as table<unknown, unknown>]]
  local out = {}
  for key, item in pairs(input) do
    out[key] = copyValue(item)
  end
  return out
end

---@param frameState unknown
---@return boolean
local function isRoundState(frameState)
  local record = frameState --[[@as table<string, unknown>]]
  return type(frameState) == "table"
    and type(record.round) == "number"
    and record.round --[[@as integer]]
      % 1 == 0
    and record.round --[[@as integer]]
      >= 1
end

---@param frameState unknown
---@return boolean
local function isActionState(frameState)
  local record = frameState --[[@as table<string, unknown>]]
  return type(frameState) == "table" and type(record.combatant) == "number" and type(record.activation) == "number"
end

---@param frameState unknown
---@return boolean
local function isSwitchState(frameState)
  local record = frameState --[[@as table<string, unknown>]]
  return type(frameState) == "table" and type(record.combatant) == "number" and type(record.replacement) == "number"
end

---@param frame table<string, unknown>
local function checkFrameKind(frame)
  local validators = {
    round = isRoundState,
    action = isActionState,
    switch = isSwitchState,
  }
  local known = validators[
    frame.kind --[[@as string]]
  ]
  if known == nil then
    error(BattleErrors.incompatibleSnapshot("continuation frames must name a known kind", {
      kind = tostring(frame.kind),
    }))
  end
  if
    not (known --[[@as fun(state: unknown): boolean]])(frame.state)
  then
    error(BattleErrors.incompatibleSnapshot("continuation frames must carry kind-shaped state", {
      kind = tostring(frame.kind),
    }))
  end
end

---@param content unknown
---@param ruleset string
local function checkContent(content, ruleset)
  if type(content) ~= "table" then
    error(BattleErrors.missingBehavior("sessions require their frozen battle content", { ruleset = ruleset }))
  end
  local contentRecord = content --[[@as table<string, unknown>]]
  local lookup = contentRecord.ruleset
  if type(lookup) ~= "function" then
    error(BattleErrors.missingBehavior("battle content must resolve rulesets", { ruleset = ruleset }))
  end
  local ok = pcall(lookup, contentRecord, ruleset)
  if not ok then
    error(BattleErrors.missingBehavior("battle content must resolve the scenario ruleset", { ruleset = ruleset }))
  end
end

---@param kinds unknown candidate admitted vocabulary under copy
---@return string[] detached admitted action kinds
local function copyKinds(kinds)
  assert(type(kinds) == "table", "admitted vocabularies stay arrays")
  local admitted = {} ---@type string[]
  for _, kind in
    ipairs(kinds --[[@as string[] ]])
  do
    assert(type(kind) == "string" and kind ~= "", "admitted action kinds stay named")
    admitted[#admitted + 1] = kind
  end
  assert(#admitted > 0, "admitted vocabularies stay non-empty")
  return admitted
end

-- Wild encounters admit flight beside the standard vocabulary.
-- Explicitly registered vocabularies are never rewritten: only the
-- standard fallback gains the run action, and only for wild battles.
---@param formatKey string format identity owning the admitted action vocabulary
---@param validated table<string, unknown>? detached scenario under construction for native topology proof
---@return string[] standard admitted action kinds for the encounter kind
local function defaultKindsFor(formatKey, validated)
  local kinds = copyKinds(HgssSessionExecutor.DEFAULT_ACTION_KINDS)
  local scenarioKind = validated ~= nil and validated.kind or nil
  if battleKindFor(formatKey, scenarioKind) == "wild" then
    kinds[#kinds + 1] = "run"
  end
  return kinds
end

---@param formatKey string format identity owning the admitted action vocabulary
---@param content table<string, unknown> frozen executable battle content
---@param validated table<string, unknown>? detached scenario under construction for native topology proof
---@return string[] admitted action kinds for the decision batches
local function admittedKindsFor(formatKey, content, validated)
  local contentRecord = content --[[@as table<string, unknown>]]
  local lookup = contentRecord.format
  if type(lookup) == "function" then
    local okCustom, custom = pcall(lookup, contentRecord, formatKey)
    if okCustom and type(custom) == "table" then
      local kinds = (custom --[[@as table<string, unknown>]]).actionKinds
      if kinds == nil then
        return defaultKindsFor(formatKey, validated)
      end
      return copyKinds(kinds)
    end
  end
  local okNative, policy = pcall(NativeFormats.policyFor, formatKey)
  if okNative and type(policy) == "table" then
    if validated ~= nil then
      NativeFormats.validateScenario(formatKey, validated)
    end
    local kinds = (policy --[[@as table<string, unknown>]]).actionKinds
    if kinds == nil then
      return defaultKindsFor(formatKey, validated)
    end
    return copyKinds(kinds)
  end
  error(BattleErrors.missingBehavior("unknown battle format " .. formatKey, { format = formatKey }))
end

---@param value unknown
---@return boolean
local function isPositiveInt(value)
  return type(value) == "number" and value == value and value % 1 == 0 and value >= 1 and value <= 9007199254740991
end

---@param replacement unknown open replacement continuation under validation
local function checkReplacementShape(replacement)
  if type(replacement) ~= "table" then
    error(BattleErrors.incompatibleSnapshot("replacement continuations must be records", {}))
  end
  local obligations = (replacement --[[@as table<string, unknown>]]).obligations
  if type(obligations) ~= "table" then
    error(BattleErrors.incompatibleSnapshot("replacement continuations must carry their obligations", {}))
  end
  for index = 1, #obligations --[[@as table<integer, unknown>]] do
    local entry = (obligations --[[@as table<integer, unknown>]])[index]
    if type(entry) ~= "table" then
      error(BattleErrors.incompatibleSnapshot("replacement obligations must be records", { index = index }))
    end
    local obligation = entry --[[@as table<string, unknown>]]
    for _, field in ipairs({ "combatant", "activation", "position", "participant", "side" }) do
      if not isPositiveInt(obligation[field]) then
        error(BattleErrors.incompatibleSnapshot("replacement obligations must name their " .. field, {
          index = index,
        }))
      end
    end
    if type(obligation.controller) ~= "string" or obligation.controller == "" then
      error(BattleErrors.incompatibleSnapshot("replacement obligations must name their controller", {
        index = index,
      }))
    end
    if type(obligation.internal) ~= "boolean" then
      error(BattleErrors.incompatibleSnapshot("replacement obligations must mark internal resolution", {
        index = index,
      }))
    end
  end
end

---@param state table<string, unknown>
local function checkRestoredShape(state)
  local frames = state.frames --[[@as table<integer, table<string, unknown>>]]
  for _, frame in ipairs(frames) do
    checkFrameKind(frame)
  end
  if state.status == "waiting" then
    if state.pending == nil then
      error(BattleErrors.incompatibleSnapshot("waiting snapshots must carry their batch", {}))
    end
    if #frames ~= 1 or frames[1].kind ~= "round" then
      error(BattleErrors.incompatibleSnapshot("waiting snapshots hold one round frame", {}))
    end
    local pending = state.pending --[[@as table<string, unknown>]]
    if pending.replacement ~= nil then
      checkReplacementShape(pending.replacement)
    end
    -- Learning suspensions hold the same obligation shape aside while
    -- the recipient answers: replacement work resumes after the reply.
    if pending.learning ~= nil then
      checkReplacementShape(pending.learning --[[@as table<string, unknown>]])
    end
  elseif state.status == "running" then
    if state.pending ~= nil then
      error(BattleErrors.incompatibleSnapshot("running snapshots carry no batch", {}))
    end
    if #frames ~= 0 then
      error(BattleErrors.incompatibleSnapshot("running snapshots hold no frames", {}))
    end
  end
end

---@return table<string, unknown> fresh native schedule frame at its opening boundary
local function freshSchedule()
  return {
    kind = HgssSchedule.KIND,
    version = HgssSchedule.VERSION,
    cursor = "opening",
    currentActionId = nil,
    residualCursor = nil,
    pendingFaints = {},
  }
end

---@param state table<string, unknown>
---@return table<integer, table<string, unknown>> pending requests in batch order
local function batchRequests(state)
  local pending = state.pending --[[@as table<string, unknown>]]
  local batch = pending.batch --[[@as table<string, unknown>]]
  return batch.requests --[[@as table<integer, table<string, unknown>>]]
end

---@param state table<string, unknown>
---@return boolean true once every open request holds a stored reply
local function batchComplete(state)
  local pending = state.pending --[[@as table<string, unknown>]]
  local submitted = pending.submitted --[[@as table<integer, table<string, unknown>>]]
  for _, request in ipairs(batchRequests(state)) do
    if
      submitted[
        request.requestId --[[@as integer]]
      ] == nil
    then
      return false
    end
  end
  return true
end

---@param state table<string, unknown>
---@return table<integer, table<string, unknown>> drained events in sequence order
local function drainOutbox(state)
  local outbox = state.outbox --[[@as table<integer, table<string, unknown>>]]
  local flushed = {}
  for _, event in ipairs(outbox) do
    flushed[#flushed + 1] = event
  end
  state.outbox = {}
  return flushed
end

---@param state table<string, unknown>
---@return table<string, unknown> detached open batch without sealed replies
local function openBatchView(state)
  local pending = state.pending --[[@as table<string, unknown>]]
  return copyValue(pending.batch) --[[@as table<string, unknown>]]
end

---@param context table<string, unknown>
---@param frame table<string, unknown>
local function pushCheckedFrame(context, frame)
  checkFrameKind(frame)
  local typed = context --[[@as BattleContext]]
  typed:pushFrame(frame)
end

---@param state table<string, unknown>
---@param admitted string[] admitted action kinds resolved at construction
local function buildBatch(state, admitted)
  local context = BattleContext.wrap(state)
  local counter = state.batchCounter --[[@as integer]] + 1
  state.batchCounter = counter
  state.pending = {
    batch = { id = counter, epoch = counter, requests = {} },
    submitted = {},
    reserved = { replacements = {}, items = {} },
  }
  local byController = {}
  local controllerOrder = {}
  for _, participantId in
    ipairs(state.participantOrder --[[@as integer[] ]])
  do
    local participant = BattleState.participant(state, participantId)
    local controller = participant.controller --[[@as string]]
    for _, combatantId in
      ipairs(participant.roster --[[@as integer[] ]])
    do
      local combatant = BattleState.combatant(state, combatantId)
      if combatant.active ~= nil then
        if byController[controller] == nil then
          byController[controller] = {}
          controllerOrder[#controllerOrder + 1] = controller
        end
        local active = combatant.active --[[@as table<string, unknown>]]
        local actors = byController[controller]
        actors[#actors + 1] = { combatant = combatantId, activation = active.activation }
      end
    end
  end
  if #controllerOrder == 0 then
    state.pending = nil
    state.status = "ended"
    state.outcome = {
      kind = "no_actors",
      rounds = state.round --[[@as integer]] - 1,
      evolutionEligible = copyValue(state.evolutionEligible),
    }
    return
  end
  -- Source-timed order randomness is sampled before decisions are
  -- requested: four raw values in canonical battler-position order over
  -- the fixed four-slot loop, stored as plain data on the open batch so
  -- capture and restore replay the same order without resampling.
  local stream = state.rng --[[@as table<string, unknown>]]
  assert(type(stream.nextU16) == "function", "ordinary batches sample order before requests")
  local rolls = {} ---@type table<integer, integer>
  for position = 1, 4 do
    rolls[position] = (
      stream.nextU16 --[[@as fun(self: unknown, label: string, cause: table<string, unknown>): integer]]
    )(stream, "quick_claw", { kind = "order_sample", position = position })
  end
  (state.pending --[[@as table<string, unknown>]]).nativeOrderRolls = rolls
  pushCheckedFrame(context, {
    kind = "round",
    version = 1,
    cursor = "awaiting_replies",
    state = { round = state.round },
  })
  for _, controller in ipairs(controllerOrder) do
    context:requestDecision({
      controller = controller,
      kind = HgssSessionExecutor.DECISION_KIND,
      actors = byController[controller],
      legalChoices = { kinds = admitted },
    })
  end
  state.status = "waiting"
end

---@param state table<string, unknown>
---@param combatantId integer
---@param target table<string, unknown>
---@return integer? resolved combatant taking the strike, if the reference still binds
local function resolveTarget(state, combatantId, target)
  local kind = target.kind
  if kind == "position" then
    local position = (state.positions --[[@as table<integer, table<string, unknown>>]])[
      target.position --[[@as integer]]
    ]
    if position == nil then
      return nil
    end
    local occupant = position.occupant --[[@as integer?]]
    if occupant == nil then
      return nil
    end
    local combatant = BattleState.combatant(state, occupant)
    if combatant.active == nil then
      return nil
    end
    return occupant
  elseif kind == "combatant" then
    local combatant = (state.combatants --[[@as table<integer, table<string, unknown>>]])[
      target.combatant --[[@as integer]]
    ]
    if combatant == nil or combatant.active == nil then
      return nil
    end
    if target.activation ~= nil then
      local active = combatant.active --[[@as table<string, unknown>]]
      if active.activation ~= target.activation then
        return nil
      end
    end
    return target.combatant --[[@as integer]]
  elseif kind == "side" or kind == "field" or kind == "none" then
    return nil
  else
    error(BattleErrors.invalidState("strike resolution met an unknown target", { combatant = combatantId }))
  end
end

---@param mon unknown battle-local mon record under move resolution
---@param moveSlot unknown zero-based move slot under resolution
---@return string move identity to execute
---@return integer? power-point slot owning the execution, absent for struggle
local function resolveMove(mon, moveSlot)
  if type(mon) == "table" and type(moveSlot) == "number" and moveSlot % 1 == 0 and moveSlot >= 0 then
    local moves = (mon --[[@as table<string, unknown>]]).moves
    if type(moves) == "table" then
      local entry = (moves --[[@as table<integer, unknown>]])[
        moveSlot --[[@as integer]] + 1
      ]
      if type(entry) == "table" then
        local record = entry --[[@as table<string, unknown>]]
        if
          type(record.move) == "string"
          and record.move ~= ""
          and type(record.pp) == "number"
          and record.pp --[[@as integer]]
            % 1 == 0
          and record.pp --[[@as integer]]
            >= 1
        then
          return record.move, --[[@as string]]
            moveSlot --[[@as integer]]
        end
      end
    end
  end
  return "STRUGGLE", nil
end

-- Battle stats carrying a stage law: attack, defense, speed, and the
-- special pair sample through their battle-local stage, while accuracy
-- and evasion stages gate their own checkpoint later.
local STAGED_STATS = { "attack", "defense", "speed", "specialAttack", "specialDefense" }

-- Every stage key an entry carries, including the gating pair.
local STAGE_KEYS = { "attack", "defense", "speed", "specialAttack", "specialDefense", "accuracy", "evasion" }

---@param mon unknown battle-local mon record under fact sampling
---@param speciesFacts table<string, SpeciesFormFacts> static species facts by species and form
---@return table<string, unknown> static species facts for the record
local function staticFacts(mon, speciesFacts)
  if type(mon) ~= "table" then
    error(BattleErrors.missingBehavior("damage reads its real combat facts", { fact = "mon" }))
  end
  local record = mon --[[@as table<string, unknown>]]
  local species = record.species
  if type(species) ~= "string" or species == "" then
    error(BattleErrors.missingBehavior("damage reads its real combat facts", { fact = "species" }))
  end
  local form = record.form
  if type(form) ~= "number" or form % 1 ~= 0 then
    error(BattleErrors.missingBehavior("damage reads its real combat facts", { fact = "form" }))
  end
  local byForm = speciesFacts[
    species --[[@as string]]
  ]
  local static = type(byForm) == "table"
    and (byForm --[[@as table<integer, table<string, unknown>>]])[
      form --[[@as integer]]
    ]
  if type(static) ~= "table" then
    error(BattleErrors.missingBehavior("damage reads its static species facts", {
      fact = species --[[@as string]],
    }))
  end
  local facts = static --[[@as table<string, unknown>]]
  if type(facts.baseStats) ~= "table" or type(facts.growthCurve) ~= "table" then
    error(BattleErrors.missingBehavior("damage reads its static species facts", {
      fact = species --[[@as string]],
    }))
  end
  return facts
end

---@param combatant table<string, unknown> live combatant under projection
---@return table<string, integer> battle-local stat stages for the entry
local function combatStages(combatant)
  local stages = combatant.stages
  if type(stages) ~= "table" then
    error(BattleErrors.invalidState("entries carry their battle-local stages", {}))
  end
  local record = stages --[[@as table<string, unknown>]]
  for _, key in ipairs(STAGE_KEYS) do
    local stage = record[key]
    if type(stage) ~= "number" or stage % 1 ~= 0 or stage < StatStages.MIN or stage > StatStages.MAX then
      error(BattleErrors.invalidState("entries carry clamped integer stages", {}))
    end
  end
  return record --[[@as table<string, integer>]]
end

---@param mon unknown battle-local mon record under inspection
---@return string? persistent condition key, when one is present
local function persistentCondition(mon)
  if type(mon) ~= "table" then
    return nil
  end
  local condition = (mon --[[@as table<string, unknown>]]).condition
  if type(condition) ~= "table" then
    return nil
  end
  local effects = (condition --[[@as table<string, unknown>]]).effects
  if type(effects) ~= "table" then
    return nil
  end
  local current = (effects --[[@as table<integer, unknown>]])[1]
  if type(current) ~= "table" then
    return nil
  end
  local key = (current --[[@as table<string, unknown>]]).key
  if type(key) ~= "string" then
    return nil
  end
  return key
end

---@param mon unknown battle-local mon record carrying ability and condition
---@return string? battle ability key, when one is named
---@return string? persistent condition key, when one is present
local function statusFacts(mon)
  if type(mon) ~= "table" then
    return nil, nil
  end
  local record = mon --[[@as table<string, unknown>]]
  local ability = nil
  if type(record.ability) == "string" and record.ability ~= "" then
    ability = record.ability --[[@as string]]
  end
  return ability, persistentCondition(record)
end

-- Applies the native Speed interaction for persistent conditions: a holder
-- whose passive answers the Speed checkpoint while statused keeps that
-- passive ratio, while any other paralyzed holder drops to a quarter
-- through truncating division. Ability meaning stays in the passive
-- families; this checkpoint only orders the arithmetic.
---@param speed integer stage-effective Speed under adjustment
---@param combatantId integer holder combatant under the checkpoint
---@param mon unknown battle-local mon record carrying ability and condition
---@param bridge NativePassiveBridge live passive composition for the holder
---@return integer effective battle Speed
local function statusAdjustedSpeed(speed, combatantId, mon, bridge)
  local _, conditionKey = statusFacts(mon)
  local boost = bridge:statRatio(combatantId, "speed", conditionKey ~= nil, nil)
  if boost ~= nil then
    return math.floor((speed * boost.numerator) / boost.denominator)
  end
  if conditionKey == "paralysis" then
    return math.floor(speed / 4)
  end
  return speed
end

-- Applies the native physical-attack interaction for abilities answering
-- the attack checkpoint while statused (the resilient boost being the
-- current case): the holder keeps that passive ratio. Burn itself never
-- reshapes the attack stat here; the canonical damage owner halves
-- post-division damage instead. Ability meaning stays in the passive
-- families.
---@param attacker table<string, integer> live attacker level and battle stats under adjustment
---@param combatantId integer holder combatant under the checkpoint
---@param mon unknown battle-local mon record carrying ability and condition
---@param category unknown executing move category selecting the split
---@param bridge NativePassiveBridge live passive composition for the holder
local function statusAdjustedAttack(attacker, combatantId, mon, category, bridge)
  if category ~= "physical" then
    return
  end
  local _, conditionKey = statusFacts(mon)
  local boost = bridge:statRatio(combatantId, "attack", conditionKey ~= nil, "physical")
  if boost ~= nil then
    attacker.attack = math.floor((attacker.attack * boost.numerator) / boost.denominator)
  end
end

-- Applies the native defense interaction for abilities answering the
-- defense checkpoint while statused (the scale mail being the current
-- case): the holder keeps that passive ratio on the staged category
-- stat. Ability meaning stays in the passive families.
---@param defender table<string, integer> live defender level and battle stats under adjustment
---@param combatantId integer holder combatant under the checkpoint
---@param mon unknown battle-local mon record carrying ability and condition
---@param category unknown executing move category selecting the split
---@param bridge NativePassiveBridge live passive composition for the holder
local function statusAdjustedDefense(defender, combatantId, mon, category, bridge)
  local stat = nil
  if category == "physical" then
    stat = "defense"
  elseif category == "special" then
    stat = "specialDefense"
  end
  if stat == nil then
    return
  end
  local _, conditionKey = statusFacts(mon)
  local boost = bridge:statRatio(combatantId, stat --[[@as string]], conditionKey ~= nil, nil)
  if boost ~= nil then
    defender[
      stat --[[@as string]]
    ] = math.floor(
      (
        defender[
          stat --[[@as string]]
        ] * boost.numerator
      ) / boost.denominator
    )
  end
end

-- Native held items halving battle Speed: Macho Brace, Iron Ball, and
-- all six power training items. Source reference:
-- sSpeedHalvingItemEffects in src/battle/overlay_12_0224E4FC.c.
local SPEED_HALVING_ITEMS = {
  MACHO_BRACE = true,
  IRON_BALL = true,
  POWER_BRACER = true,
  POWER_BELT = true,
  POWER_LENS = true,
  POWER_BAND = true,
  POWER_ANKLET = true,
  POWER_WEIGHT = true,
}

-- Applies the native held-item Speed interaction in source order over the
-- split possession reads: the eight speed-halving items halve from raw
-- possession even under suppression, while Choice Scarf and Quick Powder
-- answer only through the effective holding. Item meaning stays in the
-- passive families; this checkpoint only orders the arithmetic ahead of
-- the persistent-condition checkpoint.
---@param speed integer stage-effective Speed under adjustment
---@param rawItem string? possessed held-item key regardless of suppression
---@param effectiveItem string? held-item key visible to ordinary effects
---@param species string? holder species gating the powder doubling
---@return integer item-adjusted battle Speed
local function itemAdjustedSpeed(speed, rawItem, effectiveItem, species)
  if rawItem ~= nil and SPEED_HALVING_ITEMS[rawItem] == true then
    speed = math.floor(speed / 2)
  end
  if effectiveItem == "CHOICE_SCARF" then
    speed = math.floor((speed * 15) / 10)
  end
  if effectiveItem == "QUICK_POWDER" and species == "DITTO" then
    speed = speed * 2
  end
  return speed
end

---@param combatant table<string, unknown> live combatant under fact sampling
---@param speciesFacts table<string, SpeciesFormFacts> static species facts by species and form
---@return string[] detached semantic types for the entry
local function combatantTypes(combatant, speciesFacts)
  local mon = combatant.mon
  if type(mon) ~= "table" then
    error(BattleErrors.missingBehavior("damage reads its real combat facts", { fact = "mon" }))
  end
  local facts = staticFacts(mon, speciesFacts)
  local declared = facts.types
  if type(declared) ~= "table" or #declared == 0 then
    error(BattleErrors.missingBehavior("damage reads its semantic type facts", { fact = "types" }))
  end
  local types = {} ---@type string[]
  for _, key in
    ipairs(declared --[[@as string[] ]])
  do
    if type(key) ~= "string" or key == "" then
      error(BattleErrors.missingBehavior("damage reads its semantic type facts", { fact = "types" }))
    end
    types[#types + 1] = key
  end
  return types
end

---@param moveFacts table<string, table<string, unknown>> immutable move facts carried by the session
---@param moveName string executing move identity under ordering
---@return integer compiled move priority for the strike
local function movePriority(moveFacts, moveName)
  local record = moveFacts[moveName]
  if type(record) ~= "table" then
    error(BattleErrors.missingBehavior("ordering reads its compiled move priority", { key = moveName }))
  end
  local priority = (record --[[@as table<string, unknown>]]).priority
  if type(priority) ~= "number" or priority % 1 ~= 0 then
    error(BattleErrors.missingBehavior("ordering reads its compiled move priority", { key = moveName }))
  end
  return priority --[[@as integer]]
end

---@param moveFacts table<string, table<string, unknown>> immutable move facts carried by the session
---@param moveName string pending move identity under gating
---@return integer compiled move power for the gate, zero for status moves
local function movePower(moveFacts, moveName)
  local record = moveFacts[moveName]
  if type(record) ~= "table" then
    error(BattleErrors.missingBehavior("gating reads its compiled move power", { key = moveName }))
  end
  local power = (record --[[@as table<string, unknown>]]).power
  if type(power) ~= "number" or power % 1 ~= 0 or power < 0 then
    error(BattleErrors.missingBehavior("gating reads its compiled move power", { key = moveName }))
  end
  return power --[[@as integer]]
end

---@param attacker table<string, integer> live attacker level and battle stats
---@param attackerRaw table<string, integer> live attacker level and raw battle stats
---@param attackerStages table<string, integer> live attacker battle-local stages
---@param defender table<string, integer> live defender level and battle stats
---@param defenderRaw table<string, integer> live defender level and raw battle stats
---@param defenderStages table<string, integer> live defender battle-local stages
---@param category unknown executing move category selecting the stat pair
---@param moveName string executing move identity under the error context
---@return table<string, integer> move-frame combat facts for the staged arithmetic
local function combatPair(
  attacker,
  attackerRaw,
  attackerStages,
  defender,
  defenderRaw,
  defenderStages,
  category,
  moveName
)
  if type(category) ~= "string" then
    error(BattleErrors.missingBehavior("damage reads its move category", { key = moveName }))
  end
  -- Special strikes stage through the special pair; every other category
  -- stages through the physical pair. Non-damaging categories never reach
  -- the staged arithmetic, so their inert pair is real but unread. Raw
  -- stats and signed stages travel beside the staged pair so critical
  -- hits can ignore unfavorable stages without a second calculator.
  local attackKey, defenseKey = "attack", "defense"
  if category == "special" then
    attackKey, defenseKey = "specialAttack", "specialDefense"
  end
  return {
    level = attacker.level,
    attack = attacker[attackKey],
    defense = defender[defenseKey],
    rawAttack = attackerRaw[attackKey],
    rawDefense = defenderRaw[defenseKey],
    attackStage = attackerStages[attackKey],
    defenseStage = defenderStages[defenseKey],
  }
end

-- Per-strike source-law facts behind one owner so the turn closure
-- spends a single upvalue: turn interaction for revenge law and the
-- beat-up party. Revenge answers damage from its own target through the
-- recorded damager; counter answers only a live opposing damager.
-- Source references: BtlCmd_CalcPaybackPower,
-- BtlCmd_CalcRevengeDamageMul, BtlCmd_Counter, BtlCmd_MirrorCoat, and
-- BtlCmd_BeatUp in src/battle/battle_command.c.
local StrikeFacts = {}

---@param state table<string, unknown> live battle state under inspection
---@param userId integer striking combatant under the facts
---@param foeId integer targeted combatant under the facts
---@return table<string, unknown> duel facts for the strike frame
function StrikeFacts.duel(state, userId, foeId)
  local acted = state.turnActed
  if type(acted) ~= "table" then
    acted = {}
  end
  local strikes = state.turnStrikes
  if type(strikes) ~= "table" then
    strikes = {}
  end
  local marked = acted --[[@as table<integer, boolean>]]
  local ledger = strikes --[[@as table<integer, table<string, unknown>>]]
  local userSide =
    BattleState.participant(state, BattleState.combatant(state, userId).participant --[[@as integer]]).side
  local function hurt(combatantId)
    local record = ledger[combatantId]
    if type(record) ~= "table" then
      return false
    end
    local amounts = (record --[[@as table<string, unknown>]]).amounts
    if type(amounts) ~= "table" then
      return false
    end
    for _, entry in
      pairs(amounts --[[@as table<integer, unknown>]])
    do
      if type(entry) == "table" then
        local taken = entry --[[@as table<string, integer>]]
        if (taken.physical or 0) > 0 or (taken.special or 0) > 0 then
          return true
        end
      end
    end
    return false
  end
  local function revenge(lastKey, category)
    local record = ledger[userId]
    if type(record) ~= "table" then
      return nil
    end
    local attackerId = (record --[[@as table<string, unknown>]])[lastKey]
    if type(attackerId) ~= "number" then
      return nil
    end
    local amounts = (record --[[@as table<string, unknown>]]).amounts
    if type(amounts) ~= "table" then
      return nil
    end
    local entry = (amounts --[[@as table<integer, unknown>]])[
      attackerId --[[@as integer]]
    ]
    if type(entry) ~= "table" then
      return nil
    end
    local amount = (entry --[[@as table<string, integer>]])[category]
    if type(amount) ~= "number" or amount < 1 then
      return nil
    end
    local attacker = BattleState.combatant(state, attackerId --[[@as integer]])
    if
      attacker.active == nil
      or attacker.hp --[[@as integer]]
        <= 0
    then
      return nil
    end
    local side = BattleState.participant(state, attacker.participant --[[@as integer]]).side
    if side == userSide then
      return nil
    end
    return { attacker = attackerId, amount = amount }
  end
  return {
    foeActed = marked[foeId] == true,
    foeHurt = hurt(foeId),
    userHurt = hurt(userId),
    revengePhysical = revenge("lastPhysical", "physical"),
    revengeSpecial = revenge("lastSpecial", "special"),
  }
end

-- Beat Up party facts: the defender base defense plus the eligible
-- strikers in roster order, each with its base attack and battle level.
-- The user always answers, even while statused; benched mates answer only
-- conscious, healthy, and unhatched. Source reference: BtlCmd_BeatUp in
-- src/battle/battle_command.c.
---@param state table<string, unknown> live battle state under inspection
---@param combatant table<string, unknown> striking combatant under the facts
---@param defender table<string, unknown> targeted combatant under the facts
---@param speciesFacts table<string, unknown> static species facts carried by the session
---@return table<string, unknown> beat-up facts for the strike frame
function StrikeFacts.beatup(state, combatant, defender, speciesFacts)
  local defenderFacts = staticFacts(defender.mon, speciesFacts)
  local defenderBase = (defenderFacts --[[@as table<string, unknown>]]).baseStats
  if
    type(defenderBase) ~= "table" or type((defenderBase --[[@as table<string, integer>]]).defense) ~= "number"
  then
    error(BattleErrors.missingBehavior("beat-up reads its defender base defense", { fact = "defense" }))
  end
  local participant = BattleState.participant(state, combatant.participant --[[@as integer]])
  local members = {} ---@type table<integer, table<string, integer>>
  for _, combatantId in
    ipairs(participant.roster --[[@as table<integer, integer>]])
  do
    local mate = BattleState.combatant(state, combatantId --[[@as integer]])
    local mon = mate.mon
    local eligible = combatantId == combatant.id
    if not eligible and type(mon) == "table" then
      local record = mon --[[@as table<string, unknown>]]
      if
        mate.hp --[[@as integer]]
          > 0
        and persistentCondition(mon) == nil
        and record.isEgg ~= true
      then
        eligible = true
      end
    end
    if eligible then
      local facts = staticFacts(mon, speciesFacts)
      local owned = facts --[[@as table<string, unknown>]]
      local base = owned.baseStats
      if
        type(base) ~= "table" or type((base --[[@as table<string, integer>]]).attack) ~= "number"
      then
        error(BattleErrors.missingBehavior("beat-up reads its striker base attack", { fact = "attack" }))
      end
      local record = mon --[[@as table<string, unknown>]]
      local experience = record.experience
      if type(experience) ~= "number" then
        error(BattleErrors.missingBehavior("beat-up reads its striker experience", { fact = "experience" }))
      end
      local level = Experience.level(owned.growthCurve --[[@as integer[] ]], experience --[[@as integer]])
      members[#members + 1] = {
        attack = (base --[[@as table<string, integer>]]).attack --[[@as integer]],
        level = level,
      }
    end
  end
  return {
    defense = (defenderBase --[[@as table<string, integer>]]).defense --[[@as integer]],
    members = members,
  }
end

---@param kind string committed choice class under ordering
---@return integer sampled priority bracket for non-strike actions
local function bracketFor(kind)
  if kind == "switch" or kind == "item" or kind == "run" then
    return ESCAPE_BRACKET
  end
  return 0
end

---@param validated table<string, unknown> detached validated battle setup under construction
---@return string[] held-item keys carrying the money-up effect, in stable order
local function checkMoneyUpItems(validated)
  local declared = validated.moneyUpItems
  if declared == nil then
    return {}
  end
  if type(declared) ~= "table" then
    error(BattleErrors.missingBehavior("sessions carry their money-up items as an array", {
      ruleset = tostring(validated.ruleset),
    }))
  end
  local keys = {} ---@type string[]
  for _, key in
    ipairs(declared --[[@as table<integer, unknown>]])
  do
    if type(key) ~= "string" or key == "" then
      error(BattleErrors.missingBehavior("money-up items name their item key", {
        ruleset = tostring(validated.ruleset),
      }))
    end
    keys[#keys + 1] = key --[[@as string]]
  end
  table.sort(keys)
  return keys
end

-- Scans one entering combatant for the money-up hold effect. The latch
-- only ever moves 1 -> 2: once any sent-out battler carries the effect,
-- the multiplier persists for the battle even if that holder later
-- leaves, faints, or loses the item.
---@param live table<string, unknown> live battle state under entry settlement
---@param moneySet table<string, boolean> held-item keys carrying the money-up effect
---@param combatantId integer entering combatant under inspection
local function noteEntry(live, moneySet, combatantId)
  local combatant = BattleState.combatant(live, combatantId)
  local mon = combatant.mon
  local held = type(mon) == "table" and (mon --[[@as table<string, unknown>]]).heldItem or nil
  if type(held) == "string" and moneySet[held] == true then
    live.prizeMoneyValue = 2
  end
end

-- Knockout-reward participation belongs to one opposing entry: each enemy
-- combatant keys its own record by roster identity, pinning the entry
-- token it entered on and the player-side combatants sent out against it.
-- Leaving never erases a record; a later entry with a fresh token
-- replaces it, and opening the reward for the pinned entry consumes it.
---@param state table<string, unknown> live battle state under entry settlement
---@param enemyId integer entering enemy combatant identity
local function noteEnemyEntry(state, enemyId)
  local combatant = BattleState.combatant(state, enemyId)
  local active = combatant.active --[[@as table<string, unknown>]]
  assert(active ~= nil, "reward participation tracks entered opponents")
  local records = state.rewardParticipation --[[@as table<integer, table<string, unknown>>]]
  assert(type(state.rewardParticipation) == "table", "reward participation travels as enemy-keyed records")
  local participants = {} ---@type table<integer, boolean>
  for _, combatantId in
    ipairs(state.combatantOrder --[[@as integer[] ]])
  do
    local candidate = BattleState.combatant(state, combatantId)
    local owner = BattleState.participant(state, candidate.participant --[[@as integer]])
    if
      owner.side == 1
      and candidate.active ~= nil
      and candidate.hp --[[@as integer]]
        > 0
    then
      participants[combatantId] = true
    end
  end
  records[enemyId] = { activation = active.activation, combatants = participants }
end

-- A player-side arrival joins every currently active enemy entry: the
-- entering combatant counts against each foe it now faces, while records
-- whose token no longer matches the field are reseeded from the current
-- occupants instead of inheriting stale credit.
---@param state table<string, unknown> live battle state under entry settlement
---@param playerId integer entering player combatant identity
local function notePlayerEntry(state, playerId)
  local records = state.rewardParticipation --[[@as table<integer, table<string, unknown>>]]
  assert(type(state.rewardParticipation) == "table", "reward participation travels as enemy-keyed records")
  for _, combatantId in
    ipairs(state.combatantOrder --[[@as integer[] ]])
  do
    local candidate = BattleState.combatant(state, combatantId)
    local owner = BattleState.participant(state, candidate.participant --[[@as integer]])
    if owner.side ~= 1 and candidate.active ~= nil then
      local entry = candidate.active --[[@as table<string, unknown>]]
      local record = records[combatantId]
      if type(record) ~= "table" or record.activation ~= entry.activation then
        noteEnemyEntry(state, combatantId)
        record = records[combatantId]
      end
      assert(type(record) == "table", "active opponents carry their participation record")
      local members = record.combatants --[[@as table<integer, boolean>]]
      members[playerId] = true
    end
  end
end

-- Every field arrival feeds the per-opponent participation records on its
-- own side: opponents open a fresh record seeded from the active
-- player side, while player arrivals join each active enemy record.
---@param state table<string, unknown> live battle state under entry settlement
---@param combatantId integer entering combatant identity
local function noteBattleEntry(state, combatantId)
  local combatant = BattleState.combatant(state, combatantId)
  local owner = BattleState.participant(state, combatant.participant --[[@as integer]])
  if owner.side == 1 then
    notePlayerEntry(state, combatantId)
  else
    noteEnemyEntry(state, combatantId)
  end
end

---@param state table<string, unknown> live battle state under the pass
---@return table<string, unknown> live scoped-instance owner held by the state
local function liveEffectBag(state)
  local bag = state.effectBag
  if type(bag) ~= "table" or type(bag.add) ~= "function" then
    error(BattleErrors.invalidState("the native session owns its live effect bag", {}))
  end
  return bag --[[@as table<string, unknown>]]
end

---@param combatant table<string, unknown> live combatant under fact sampling
---@param speciesFacts table<string, SpeciesFormFacts> static species facts by species and form
---@return table<string, integer> live level and raw battle stats before stages
---@return table<string, integer> battle-local stat stages for the entry
local function unstagedCombatant(combatant, speciesFacts)
  local mon = combatant.mon
  if type(mon) ~= "table" then
    error(BattleErrors.missingBehavior("damage reads its real combat facts", { fact = "mon" }))
  end
  local facts = staticFacts(mon, speciesFacts)
  local record = mon --[[@as table<string, unknown>]]
  local experience = record.experience
  if type(experience) ~= "number" or experience % 1 ~= 0 or experience < 0 then
    error(BattleErrors.missingBehavior("damage reads its real combat facts", { fact = "experience" }))
  end
  local personality = record.personality
  if type(personality) ~= "number" or personality % 1 ~= 0 or personality < 0 then
    error(BattleErrors.missingBehavior("damage reads its real combat facts", { fact = "personality" }))
  end
  for _, field in ipairs({ "ivs", "evs" }) do
    if type(record[field]) ~= "table" then
      error(BattleErrors.missingBehavior("damage reads its real combat facts", { fact = field }))
    end
  end
  local level = Experience.level(facts.growthCurve --[[@as integer[] ]], experience --[[@as integer]])
  local nature = Personality.nature(personality --[[@as integer]])
  local stats = Stats.calculate(
    facts.baseStats --[[@as table<string, integer>]],
    record.ivs --[[@as table<string, integer>]],
    record.evs --[[@as table<string, integer>]],
    level,
    nature
  )
  stats.level = level
  -- Species weight rides the projection for weight-law strikes: the
  -- zukan table carries hectograms per species, and Low Kick and Grass
  -- Knot read kilograms. Absent weights stay absent and fail loudly in
  -- their handler instead of guessing.
  stats.weightHg = facts.weightHg
  return stats, combatStages(combatant)
end

---@param combatant table<string, unknown> live combatant under fact sampling
---@param speciesFacts table<string, SpeciesFormFacts> static species facts by species and form
---@param bridge NativePassiveBridge live passive composition for the holder
---@return table<string, integer> live level and stage-effective battle stats for the entry
local function projectCombatant(combatant, speciesFacts, bridge)
  local stats, stages = unstagedCombatant(combatant, speciesFacts)
  -- Battle maximum health travels with the projection so recovery
  -- handlers heal fractions of the true ceiling instead of guessing;
  -- it sits above the entry value whenever the entry arrived wounded.
  local ceiling = combatant.maxHp
  if type(ceiling) ~= "number" then
    ceiling = combatant.entryHp
  end
  stats.maxHp = ceiling --[[@as integer]]
  for _, key in ipairs(STAGED_STATS) do
    stats[key] = StatStages.effective(stats[key] --[[@as integer]], stages[key] --[[@as integer]], key)
  end
  -- Persistent conditions reshape effective Speed at this checkpoint:
  -- paralysis quarters unless the holder's passive answers instead.
  -- Held items reshape it first, in native order, over the split
  -- possession reads.
  assert(type(bridge) == "table", "combat projections read their passive bridge")
  local species = nil
  if type(combatant.mon) == "table" then
    local monRecord = combatant.mon --[[@as table<string, unknown>]]
    if type(monRecord.species) == "string" then
      species = monRecord.species --[[@as string]]
    end
  end
  local itemSpeed = itemAdjustedSpeed(
    stats.speed --[[@as integer]],
    bridge:rawHeldItem(combatant.id --[[@as integer]]),
    bridge:effectiveHeldItem(combatant.id --[[@as integer]]),
    species
  )
  stats.speed = statusAdjustedSpeed(itemSpeed, combatant.id --[[@as integer]], combatant.mon, bridge)
  return stats
end

-- Backfills each combatant's battle maximum health from the same
-- effective projection strikes sample. Facts the records cannot back
-- stay absent: sessions that cannot project keep the missing maximum
-- and fail explicitly where bag or capture law reads it.
---@param live table<string, unknown> live battle state under maximum-health backfill
---@param speciesFacts table<string, SpeciesFormFacts> static species facts carried by the session
local function ensureEntryHealth(live, speciesFacts)
  for _, combatantId in
    ipairs(live.combatantOrder --[[@as integer[] ]])
  do
    local combatant = BattleState.combatant(live, combatantId)
    if combatant.maxHp == nil and type(speciesFacts) == "table" then
      local ok, stats = pcall(projectCombatant, combatant, speciesFacts, NativePassiveBridge.wrap(live))
      if ok and type(stats) == "table" then
        combatant.maxHp = stats.hp
      end
    end
  end
end

---@param state table<string, unknown> live battle state under speed sampling
---@param combatant table<string, unknown> running combatant under speed sampling
---@param speciesFacts table<string, SpeciesFormFacts> static species facts carried by the session
---@return integer runner effective speed
---@return integer opposing entry effective speed
local function stagedEscapeSpeeds(state, combatant, speciesFacts)
  local bridge = NativePassiveBridge.wrap(state)
  local runner = projectCombatant(combatant, speciesFacts, bridge).speed
  local runnerOwner = BattleState.participant(state, combatant.participant --[[@as integer]])
  for _, combatantId in
    ipairs(state.combatantOrder --[[@as integer[] ]])
  do
    local other = BattleState.combatant(state, combatantId)
    if other.active ~= nil then
      local owner = BattleState.participant(state, other.participant --[[@as integer]])
      if owner.side ~= runnerOwner.side then
        return runner, projectCombatant(other, speciesFacts, bridge).speed
      end
    end
  end
  error(BattleErrors.invalidState("flight reads its opposing entry", {}))
end

---@class TimingSample
---@field health table<integer, integer> battle-local health per active combatant
---@field speeds table<integer, integer> sampled effective Speed per active combatant
---@field ceilings table<integer, integer> battle maximum health per active combatant
---@field typeMap table<integer, string[]> semantic types per active combatant
---@field occupants table<integer, integer> active combatant per position
---@field stats table<integer, table<string, integer>> live level and battle stats per active combatant
---@field sides table<integer, integer> owning side per active combatant

-- Samples the per-entry facts every finite timing pass consumes over the
-- same projections strikes use: stage-effective stats, semantic types,
-- battle maximum health, and position occupancy. Fractions scale to battle
-- maximum health, which sits above the entry value whenever the entry
-- arrived wounded.
---@param state table<string, unknown> live battle state under sampling
---@param speciesFacts table<string, SpeciesFormFacts> static species facts carried by the session
---@return TimingSample sampled facts for the timing passes
local function sampleTimingState(state, speciesFacts)
  local health = {} ---@type table<integer, integer>
  local speeds = {} ---@type table<integer, integer>
  local ceilings = {} ---@type table<integer, integer>
  local typeMap = {} ---@type table<integer, string[]>
  local occupants = {} ---@type table<integer, integer>
  local stats = {} ---@type table<integer, table<string, integer>>
  local sides = {} ---@type table<integer, integer>
  local bridge = NativePassiveBridge.wrap(state)
  for _, combatantId in
    ipairs(state.combatantOrder --[[@as integer[] ]])
  do
    local combatant = BattleState.combatant(state, combatantId)
    if combatant.active ~= nil then
      local projected = projectCombatant(combatant, speciesFacts, bridge)
      health[combatantId] = combatant.hp --[[@as integer]]
      speeds[combatantId] = projected.speed
      local ceiling = combatant.maxHp
      if type(ceiling) ~= "number" then
        ceiling = combatant.entryHp
      end
      ceilings[combatantId] = ceiling --[[@as integer]]
      typeMap[combatantId] = combatantTypes(combatant, speciesFacts)
      stats[combatantId] = { level = projected.level, attack = projected.attack, defense = projected.defense }
      sides[combatantId] = BattleState.participant(state, combatant.participant --[[@as integer]]).side
      --[[@as integer]]
      local active = combatant.active --[[@as table<string, unknown>]]
      occupants[
        active.position --[[@as integer]]
      ] = combatantId
    end
  end
  return {
    health = health,
    speeds = speeds,
    ceilings = ceilings,
    typeMap = typeMap,
    occupants = occupants,
    stats = stats,
    sides = sides,
  }
end

-- Commits battle-local health with the residual ceiling law: the commit
-- never heals past the ceiling, so recovery earned earlier survives the
-- pass, and damage floors at zero for faint settlement.
---@param state table<string, unknown> live battle state under the commit
---@param health table<integer, integer> battle-local health under the pass
---@param ceilings table<integer, integer> battle maximum health per combatant
local function commitTimingHealth(state, health, ceilings)
  for combatantId, hp in pairs(health) do
    local combatant = BattleState.combatant(state, combatantId)
    local settled = hp --[[@as integer]]
    if settled < 0 then
      settled = 0
    end
    local ceiling = ceilings[combatantId] --[[@as integer]]
    if settled > ceiling then
      settled = ceiling
    end
    combatant.hp = settled
  end
end

-- Expired countdowns leave after their final tick; the zero turn already
-- fired, so the sweep never drops a pending effect early.
---@param state table<string, unknown> live battle state under the sweep
local function sweepExpiredEffects(state)
  local bag = liveEffectBag(state)
  for _, record in ipairs(bag:capture()) do
    local instanceState = record.state --[[@as table<string, unknown>]]
    if
      type(instanceState.turns) == "number"
      and instanceState.turns --[[@as integer]]
        <= 0
    then
      bag:remove(record.id --[[@as integer]])
    end
  end
end

-- Per-action move-frame facts threaded from live battle state so the
-- shared continuation resolves called moves, friendship strikes, and
-- history and gender law from the same facts production battles carry:
-- usable and party move keys, the copied incoming strike, the recent
-- move record, battle genders, the sleeping flag, and friendship.
-- Histories record requested moves (the slot spent power points), and
-- gender facts stay absent when the static facts carry no ratio.
---@param mon table<string, unknown> battle mon record under the move list
---@return string[] move keys in store order
local function moveKeysOf(mon)
  local moves = mon.moves
  if type(moves) ~= "table" then
    return {}
  end
  local keys = {} ---@type string[]
  for _, entry in
    ipairs(moves --[[@as table<integer, unknown>]])
  do
    local record = entry --[[@as table<string, unknown>]]
    if type(record) == "table" and type(record.move) == "string" and record.move ~= "" then
      keys[#keys + 1] = record.move --[[@as string]]
    end
  end
  return keys
end

---@param mon table<string, unknown> battle mon record under the usable list
---@return string[] move keys with remaining power points
local function usableKeysOf(mon)
  local moves = mon.moves
  if type(moves) ~= "table" then
    return {}
  end
  local keys = {} ---@type string[]
  for _, entry in
    ipairs(moves --[[@as table<integer, unknown>]])
  do
    local record = entry --[[@as table<string, unknown>]]
    if type(record) == "table" and type(record.move) == "string" and type(record.pp) == "number" and record.pp > 0 then
      keys[#keys + 1] = record.move --[[@as string]]
    end
  end
  return keys
end

---@param state table<string, unknown> live battle state under the party read
---@param combatant table<string, unknown> acting combatant under the party read
---@return string[] benched roster-mate move keys for assist draws
local function benchKeysOf(state, combatant)
  local participant = BattleState.participant(state, combatant.participant --[[@as integer]])
  local keys = {} ---@type string[]
  for _, combatantId in
    ipairs(participant.roster --[[@as table<integer, integer>]])
  do
    if combatantId ~= combatant.id then
      local mate = BattleState.combatant(state, combatantId --[[@as integer]])
      local mon = mate.mon
      if type(mon) == "table" then
        for _, key in
          ipairs(moveKeysOf(mon --[[@as table<string, unknown>]]))
        do
          keys[#keys + 1] = key
        end
      end
    end
  end
  return keys
end

---@param mon table<string, unknown> battle mon record under the gender read
---@param speciesFacts table<string, SpeciesFormFacts> static species facts by species and form
---@return string? battle gender, or nil without a ratio
local function genderOf(mon, speciesFacts)
  local ok, facts = pcall(staticFacts, mon, speciesFacts)
  if not ok or type(facts) ~= "table" then
    return nil
  end
  local ratio = (facts --[[@as table<string, unknown>]]).genderRatio
  if type(ratio) ~= "number" or type(mon.personality) ~= "number" then
    return nil
  end
  return Personality.gender(ratio --[[@as integer]], mon.personality --[[@as integer]])
end

---@param mon table<string, unknown> battle mon record under the sleep read
---@return boolean true when the canonical mon sleeps
local function asleepOf(mon)
  local condition = mon.condition
  if type(condition) ~= "table" then
    return false
  end
  local effects = (condition --[[@as table<string, unknown>]]).effects
  if type(effects) ~= "table" then
    return false
  end
  local current = (effects --[[@as table<integer, unknown>]])[1]
  return type(current) == "table" and (current --[[@as table<string, unknown>]]).key == "sleep"
end

---@param state table<string, unknown> live battle state under the effect read
---@param key string field definition identity under the query
---@return boolean true when a live field instance names the key
local function fieldActive(state, key)
  local bag = liveEffectBag(state)
  for _, record in ipairs(bag:capture()) do
    local entry = record --[[@as table<string, unknown>]]
    local scope = entry.scope --[[@as table<string, unknown>]]
    if entry.key == key and type(scope) == "table" and scope.kind == "field" then
      return true
    end
  end
  return false
end

-- Active field weather identity for strike damage: exactly one live
-- field instance can name the sky, otherwise skies stay clear. The
-- instance itself is never consumed here; suppression only neutralizes
-- the damage law.
---@param state table<string, unknown> live battle state under the weather read
---@return string active weather identity for the strike facts
local function activeWeather(state)
  if fieldActive(state, "raindance") then
    return "rain"
  end
  if fieldActive(state, "sunnyday") then
    return "sun"
  end
  if fieldActive(state, "sandstorm") then
    return "sand"
  end
  if fieldActive(state, "hail") then
    return "hail"
  end
  return "none"
end

-- Weather suppression samples living active holders: a conscious
-- cloud-nine or air-lock entry neutralizes damage weather for the whole
-- field without deleting the weather instance.
---@param state table<string, unknown> live battle state under the suppression read
---@return boolean true when a live ability suppresses weather damage
local function weatherSuppressed(state)
  for _, combatantId in
    ipairs(state.combatantOrder --[[@as integer[] ]])
  do
    local combatant = BattleState.combatant(state, combatantId)
    if
      combatant.active ~= nil
      and type(combatant.hp) == "number"
      and combatant.hp --[[@as integer]]
        > 0
    then
      local mon = combatant.mon --[[@as table<string, unknown>]]
      local ability = mon.ability
      if ability == "CLOUD_NINE" or ability == "AIR_LOCK" then
        return true
      end
    end
  end
  return false
end

-- Single strike-facts projection for one executed strike: staged and raw
-- stats with signed stages, ability reshaping of the staged attack, and
-- the immutable burn/resilience/weather facts the canonical damage owner
-- applies at its own truncating checkpoints. Burn never reshapes the
-- attack stat here; the arithmetic owner halves post-division damage.
---@param state table<string, unknown> live battle state under fact sampling
---@param combatant table<string, unknown> live striking combatant under sampling
---@param defender table<string, unknown> live defending combatant under sampling
---@param speciesFacts table<string, SpeciesFormFacts> static species facts carried by the session
---@param category unknown executing move category selecting the stat pair
---@param moveName string executing move identity under the error context
---@return table<string, unknown> strike-local combat and law facts for the move frame
local function strikeCombatFacts(state, combatant, defender, speciesFacts, category, moveName)
  local bridge = NativePassiveBridge.wrap(state)
  local attackerStats = projectCombatant(combatant, speciesFacts, bridge)
  local attackerRaw, attackerStages = unstagedCombatant(combatant, speciesFacts)
  statusAdjustedAttack(attackerStats, combatant.id --[[@as integer]], combatant.mon, category, bridge)
  local defenderStats = projectCombatant(defender, speciesFacts, bridge)
  local defenderRaw, defenderStages = unstagedCombatant(defender, speciesFacts)
  statusAdjustedDefense(defenderStats, defender.id --[[@as integer]], defender.mon, category, bridge)
  local attackerAbility, attackerCondition = statusFacts(combatant.mon)
  return {
    facts = combatPair(
      attackerStats,
      attackerRaw,
      attackerStages,
      defenderStats,
      defenderRaw,
      defenderStages,
      category,
      moveName
    ),
    attackerStats = attackerStats,
    defenderStats = defenderStats,
    attackerAbility = attackerAbility,
    attackerCondition = attackerCondition,
    weather = activeWeather(state),
    weatherSuppressed = weatherSuppressed(state),
  }
end

---@param state table<string, unknown> live battle state under the effect read
---@param side integer side identity under the query
---@param key string side definition identity under the query
---@return boolean true when a live side instance names the key
local function sideActive(state, side, key)
  local bag = liveEffectBag(state)
  for _, record in ipairs(bag:capture()) do
    local entry = record --[[@as table<string, unknown>]]
    local scope = entry.scope --[[@as table<string, unknown>]]
    if entry.key == key and type(scope) == "table" and scope.kind == "side" and scope.side == side then
      return true
    end
  end
  return false
end

-- Hazard entries strike only grounded arrivals: flying types and
-- magnet-rise levitation avoid spikes-family layers while gravity holds
-- every arrival down. The check mirrors the strike immunity inputs
-- without borrowing strike semantics: hazards price the arrival, not a
-- directed strike.
---@param state table<string, unknown> live battle state under the entry read
---@param entrant integer arriving combatant identity
---@param types string[] entrant semantic types under the arrival
---@return boolean true when layers price the arrival
local function entrantGrounded(state, entrant, types)
  assert(type(types) == "table", "hazard entries read their entrant types")
  local airborne = false
  for _, key in ipairs(types) do
    if key == "flying" then
      airborne = true
    end
  end
  if airborne ~= true then
    local bag = liveEffectBag(state)
    for _, record in ipairs(bag:capture()) do
      local entry = record --[[@as table<string, unknown>]]
      local scope = entry.scope --[[@as table<string, unknown>]]
      if entry.key == "magnetrise" and type(scope) == "table" and scope.combatant == entrant then
        airborne = true
      end
    end
  end
  if airborne ~= true then
    return true
  end
  return fieldActive(state, "gravity")
end

---@param state table<string, unknown> live battle state under the trap read
---@param combatantId integer combatant identity under the trap read
---@return table<string, unknown>? held trap query when a volatile binds the entry
local function volatileTrapOf(state, combatantId)
  local bag = liveEffectBag(state)
  for _, record in ipairs(bag:capture()) do
    local entry = record --[[@as table<string, unknown>]]
    local scope = entry.scope --[[@as table<string, unknown>]]
    if
      (entry.key == "bind" or entry.key == "trapped")
      and type(scope) == "table"
      and scope.combatant == combatantId
    then
      return { held = true }
    end
  end
  return nil
end

-- Replaces one poisoned holder's tick through the bridge when its
-- ability answers the poison: the restoration lands on the shared
-- battle-local health map under the ceiling. Berries and persistent
-- holdings never answer here; the turn recovery pass below owns them,
-- so no holding heals twice.
---@param state table<string, unknown> live battle state under the pass
---@param context table<string, unknown> session context owning the residual writes
---@param health table<integer, integer> battle-local health under the pass
---@param ceilings table<integer, integer> battle maximum health per combatant
---@param combatantId integer holder combatant under the checkpoint
---@return boolean true when the ability replaced the poison tick
local function replacePoisonTick(state, context, health, ceilings, combatantId)
  local outcome = NativePassiveBridge.wrap(state):invoke("residual", combatantId, {
    status = "poison",
    weather = activeWeather(state),
  })
  local typed = context --[[@as BattleContext]]
  for _, event in ipairs(outcome.events) do
    local record = event --[[@as table<string, unknown>]]
    if type(record.restored) == "number" and record.answersPoisonTick == true then
      local ceiling = ceilings[combatantId] --[[@as integer]]
      local before = health[combatantId] --[[@as integer]]
      local after = before + record.restored --[[@as integer]]
      if after > ceiling then
        after = ceiling
      end
      health[combatantId] = after
      typed:emit("healed", { kind = "residual", key = record.key }, {
        target = combatantId,
        restored = after - before,
      })
      return true
    end
  end
  return false
end

-- Ticks persistent poison, burn, and toxic through the same health map
-- the dispatch pass consumes, walking the sampled battler order the
-- residual owner nests instances under. Poison and burn drain one eighth of maximum
-- health; toxic increments its owned counter first (capped at the
-- native fifteen) and drains one sixteenth per counter point. Every
-- tick floors at a minimum of one. Sleep, freeze, and paralysis carry
-- no residual damage; their law lives at the before-action gate.
---@param state table<string, unknown> live battle state under the pass
---@param context table<string, unknown> session context owning status writes
---@param health table<integer, integer> battle-local health under the pass
---@param turnOrder integer[] sampled battler order for the pass
---@param ceilings table<integer, integer> battle maximum health per combatant
local function tickPersistentConditions(state, context, health, turnOrder, ceilings)
  -- Status ticks walk the same sampled battler order the residual owner
  -- nests instances under. The identity-ordered tail only covers health
  -- entries missing from the sampled order, so the pass never depends
  -- on hash iteration order.
  local sequenced = {} ---@type integer[]
  local seen = {}
  for _, combatantId in ipairs(turnOrder) do
    if health[combatantId] ~= nil and seen[combatantId] == nil then
      seen[combatantId] = true
      sequenced[#sequenced + 1] = combatantId
    end
  end
  local tail = {} ---@type integer[]
  for combatantId in pairs(health) do
    if type(combatantId) == "number" and seen[combatantId] == nil then
      tail[#tail + 1] = combatantId
    end
  end
  table.sort(tail)
  for _, combatantId in ipairs(tail) do
    seen[combatantId] = true
    sequenced[#sequenced + 1] = combatantId
  end
  local typed = context --[[@as BattleContext]]
  for _, combatantId in ipairs(sequenced) do
    if health[combatantId] > 0 then
      local combatant = BattleState.combatant(state, combatantId)
      local mon = combatant.mon --[[@as table<string, unknown>]]
      local effects = (mon.condition --[[@as table<string, unknown>]]).effects
      local current = (effects --[[@as table<integer, table<string, unknown>>]])[1]
      if current ~= nil then
        local key = current.key --[[@as string]]
        if key == "poison" then
          -- A poisoned healer recovers through its ability instead of
          -- draining; every other poisoned holder drains below.
          if not replacePoisonTick(state, context, health, ceilings, combatantId) then
            local damage = math.floor(ceilings[combatantId] --[[@as integer]] / 8)
            if damage < 1 then
              damage = 1
            end
            health[combatantId] = health[combatantId] - damage
            typed:emit("tick", { kind = "residual", key = key }, {
              combatant = combatantId,
              key = key,
              amount = damage,
            })
          end
        elseif key == "burn" then
          local damage = math.floor(ceilings[combatantId] --[[@as integer]] / 8)
          if damage < 1 then
            damage = 1
          end
          health[combatantId] = health[combatantId] - damage
          typed:emit("tick", { kind = "residual", key = key }, {
            combatant = combatantId,
            key = key,
            amount = damage,
          })
        elseif key == "toxic" then
          local counter = (current.state --[[@as table<string, unknown>]]).counter --[[@as integer]] + 1
          if counter > 15 then
            counter = 15
          end
          current.state = { counter = counter }
          local damage = math.floor(ceilings[combatantId] --[[@as integer]] / 16) * counter
          if damage < 1 then
            damage = 1
          end
          health[combatantId] = health[combatantId] - damage
          typed:emit("tick", { kind = "residual", key = key }, {
            combatant = combatantId,
            key = key,
            amount = damage,
          })
        end
      end
    end
  end
end

---@param state table<string, unknown> live battle state under reserve inspection
---@return table<integer, integer> living benched roster members pooled across participants
local function pooledReserves(state)
  local pooled = {} ---@type table<integer, integer>
  for _, combatantId in
    ipairs(state.combatantOrder --[[@as integer[] ]])
  do
    local combatant = BattleState.combatant(state, combatantId)
    if
      combatant.active == nil
      and combatant.hp --[[@as integer]]
        > 0
    then
      pooled[#pooled + 1] = combatantId
    end
  end
  return pooled
end

---@param state table<string, unknown> live battle state under reserve inspection
---@param participantId integer roster owner under inspection
---@param claimed table<integer, boolean> reserves already promised to earlier obligations
---@return integer[] living benched reserves in declared roster order
local function eligibleReserves(state, participantId, claimed)
  local participant = BattleState.participant(state, participantId)
  local eligible = {} ---@type integer[]
  for _, combatantId in
    ipairs(participant.roster --[[@as integer[] ]])
  do
    local combatant = BattleState.combatant(state, combatantId)
    if
      combatant.active == nil
      and combatant.hp --[[@as integer]]
        > 0
      and not claimed[combatantId]
    then
      eligible[#eligible + 1] = combatantId
    end
  end
  return eligible
end

-- Reserves promised to sibling positions in the open batch, leaving out
-- the choice's own promise. The exchange owner refuses a shared reserve
-- twice, so voluntary switches prove the same reservation gate faint
-- replacements already prove.
---@param state table<string, unknown> live battle state under reservation inspection
---@param except integer? the choice's own promised reserve, never a sibling conflict
---@return integer[] sibling-promised reserves in ascending order
local function siblingReserves(state, except)
  local promised = {} ---@type integer[]
  local pending = state.pending --[[@as table<string, unknown>?]]
  if type(pending) == "table" then
    local reserved = pending.reserved --[[@as table<string, unknown>?]]
    if type(reserved) == "table" and type(reserved.replacements) == "table" then
      for reserve in
        pairs(reserved.replacements --[[@as table<integer, integer>]])
      do
        if reserve ~= except then
          promised[#promised + 1] = reserve
        end
      end
    end
  end
  table.sort(promised)
  return promised
end

---@param state table<string, unknown> live battle state under faint inspection
---@return integer[] roster identities with no health left
local function faintedIds(state)
  local fainted = {} ---@type integer[]
  for _, combatantId in
    ipairs(state.combatantOrder --[[@as integer[] ]])
  do
    local combatant = BattleState.combatant(state, combatantId)
    if
      combatant.hp --[[@as integer]]
      <= 0
    then
      fainted[#fainted + 1] = combatantId
    end
  end
  return fainted
end

-- Closes a battle that ends mid-turn through flight or capture. The
-- round frame closes here so no residual pass or outcome resettlement
-- can resurrect the decided result. Earned evolution eligibility rides
-- along exactly as it does on faint-decided terminals, since earlier
-- knockouts keep their rewards when the battle ends by flight or throw.
---@param state table<string, unknown> live battle state under early terminal settlement
---@param outcome table<string, unknown> terminal marker for the early result
local function endBattleEarly(state, outcome)
  state.status = "ended"
  state.outcome = outcome
  state.outcome.evolutionEligible = copyValue(state.evolutionEligible)
end

---@param obligation table<string, unknown> faint replacement obligation under resolution
---@return boolean true when the bereaved side answers through the decision protocol
local function isExternalObligation(obligation)
  -- The externally-directed side is side one: every production scenario
  -- seats the player participant there, so bereaved opponents resolve
  -- deterministically in roster order while the player side chooses.
  return obligation.side == 1
end

---@param state table<string, unknown> live battle state under replacement
---@param outgoing integer departing combatant identity
---@param incoming integer arriving combatant identity
---@param activation integer entry token of the incoming occupant
local function settleEntry(state, outgoing, incoming, activation)
  -- Replacement clears outgoing activation-local instances per
  -- definition lifecycle while carry-policy state follows its combatant
  -- dormant, restarts the outgoing toxic counter, and re-anchors the
  -- incoming entry's own carried state. Persistent conditions otherwise
  -- survive untouched and stages already reset at entry.
  TrainerAi.noteArrival(state, incoming)
  -- Arrivals clear their own received-hit record, matching the native
  -- switch-in reset: later decisions read only strikes received since
  -- this entry.
  local arrivals = state.lastHits --[[@as table<integer, unknown>?]]
  if type(arrivals) == "table" then
    arrivals[
      incoming --[[@as integer]]
    ] = nil
  end
  local bag = liveEffectBag(state)
  local departed = BattleState.combatant(state, outgoing).mon --[[@as table<string, unknown>]]
  Status.switchReset(departed, bag, outgoing, activation)
  local arriving = BattleState.combatant(state, incoming).mon --[[@as table<string, unknown>]]
  Status.switchReset(arriving, bag, incoming, activation)
end

---@param state table<string, unknown> live battle state under replacement
---@param moneySet table<string, boolean> held-item keys carrying the money-up effect
---@param obligation table<string, unknown> faint replacement obligation under resolution
---@param reserveId integer arriving roster member entering the vacated position
local function enterReserve(state, moneySet, obligation, reserveId)
  local eligible = Switching.eligible({
    position = obligation.position,
    incoming = reserveId,
    reason = "faint",
    reserves = eligibleReserves(state, obligation.participant --[[@as integer]], {}),
    reserved = {},
    fainted = { obligation.combatant },
  })
  if not eligible.ok then
    error(BattleErrors.invalidState("faint replacements must stay eligible", {
      reason = tostring(eligible.reason),
    }))
  end
  local frame = Switching.start({
    position = obligation.position,
    outgoing = { combatant = obligation.combatant, activation = obligation.activation },
    incoming = reserveId,
    reason = "faint",
    reserves = eligibleReserves(state, obligation.participant --[[@as integer]], {}),
    reserved = {},
    fainted = { obligation.combatant },
  })
  local stepped = Switching.step({}, frame)
  assert(stepped.done == true, "faint replacement exchanges settle without interception")
  local activation = BattleState.enter(state, reserveId, obligation.position --[[@as integer]])
  settleEntry(state, obligation.combatant --[[@as integer]], reserveId, activation)
  -- Replacements send out under the money-up scan: the latch only ever
  -- moves 1 -> 2 and never resets when the holder leaves.
  noteEntry(state, moneySet, reserveId)
  -- Taking the field marks knockout-reward participation against every
  -- foe the arrival now faces, or opens a fresh record for an arriving
  -- foe seeded from the active player side.
  noteBattleEntry(state, reserveId)
  local context = BattleContext.wrap(state)
  context:emit("switch", {
    kind = "faint",
    combatant = obligation.combatant,
    activation = obligation.activation,
  }, {
    position = obligation.position,
    from = obligation.combatant,
    to = reserveId,
  })
end

---@param state table<string, unknown> live battle state under terminal evaluation
---@return table<integer, table<string, unknown>> side standings for the terminal result selector
local function sideStandings(state)
  local standings = {} ---@type table<integer, table<string, unknown>>
  for _, sideId in
    ipairs(state.sideOrder --[[@as integer[] ]])
  do
    local standing = 0
    for _, combatantId in
      ipairs(state.combatantOrder --[[@as integer[] ]])
    do
      local combatant = BattleState.combatant(state, combatantId)
      local participant = BattleState.participant(state, combatant.participant --[[@as integer]])
      if
        participant.side == sideId
        and combatant.hp --[[@as integer]]
          > 0
      then
        standing = standing + 1
      end
    end
    standings[#standings + 1] = { id = sideId, standing = standing, fled = false }
  end
  return standings
end

---@param state table<string, unknown> live battle state under terminal evaluation
local function settleOutcome(state)
  local result = OutcomePolicy.evaluate({
    sides = sideStandings(state),
    pendingReplacements = 0,
    captured = {},
  })
  if result == nil then
    state.round = state.round --[[@as integer]] + 1
    state.status = "running"
  else
    -- Terminal standings decide: the application maps the surviving
    -- health to its win/loss/draw words from this terminal marker. Level
    -- gains accumulated through knockout rewards ride along once for
    -- post-battle handling; nothing evolves mid-battle.
    state.status = "ended"
    state.outcome = {
      kind = "no_actors",
      rounds = state.round,
      evolutionEligible = copyValue(state.evolutionEligible),
    }
  end
end

---@class RewardRecipientCursor
---@field combatant integer roster identity earning the reward
---@field monIndex integer position of the battle-owned copy inside the reward child
---@field opportunities table<integer, table<string, unknown>> ordered learning chances
---@field cursor integer learning cursor inside the chances
---@field touched boolean whether the award facts were reported
---@field expAward integer landed experience
---@field maxHpBefore integer previous health maximum
---@field maxHpAfter integer recalculated health maximum

---@class RewardFrame
---@field kind string reward identity
---@field defeated table<string, unknown> knocked-out entry the reward answers
---@field recipients table<integer, RewardRecipientCursor> recipient cursors in award order
---@field recipientIndex integer recipient cursor inside the recipients
---@field pending table<string, unknown>? outstanding learning prompt, when one waits

---@class RewardChild
---@field defeated table<string, unknown> knocked-out entry the reward answers
---@field mons table<integer, table<string, unknown>> current detached battle-owned copies
---@field frame RewardFrame resumable reward frame
---@field evolutionEligible table<integer, integer> recipients that gained a level
---@field done boolean whether the child drained fully

---@class RewardCatalog
---@field species fun(self: RewardCatalog, key: string): table<string, unknown>
---@field growthCurve fun(self: RewardCatalog, key: string): table<integer, integer>
---@field form fun(self: RewardCatalog, speciesKey: string, form: integer): table<string, unknown>
---@field move fun(self: RewardCatalog, key: string): table<string, unknown>

-- Minimal catalog over the immutable session facts for the resumable
-- reward owner: growth curves, base stats, learnsets, base experience
-- yields, effort yields, and base power points resolve through the
-- scenario facts while every lookup failure stays an explicit missing
-- fact. The facade is rebuilt from plain facts on every construction and
-- restoration and never enters snapshots.
---@param speciesFacts table<string, SpeciesFormFacts> static species facts carried by the session
---@param moveFacts table<string, table<string, unknown>> immutable move facts carried by the session
---@return RewardCatalog reward-only catalog over session facts
local function rewardCatalogFor(speciesFacts, moveFacts)
  assert(type(speciesFacts) == "table", "reward work reads the static species facts")
  assert(type(moveFacts) == "table", "reward work reads the immutable move facts")
  local catalog = {}
  ---@param key string species identity under lookup
  ---@return table<string, unknown> species record carrying its opaque curve identity
  local function catalogSpecies(_, key)
    if type(speciesFacts[key]) ~= "table" then
      error(BattleErrors.missingBehavior("reward work needs the species facts", { species = tostring(key) }))
    end
    return { growthCurve = key }
  end
  ---@param key string opaque curve identity from the species record
  ---@return table<integer, integer> growth curve table for the species
  local function catalogGrowthCurve(_, key)
    local curve = nil
    local bucket = speciesFacts[key]
    if type(bucket) == "table" then
      for _, static in pairs(bucket) do
        if type(static) == "table" then
          curve = static.growthCurve
          break
        end
      end
    end
    if type(curve) ~= "table" then
      error(BattleErrors.missingBehavior("reward work needs the growth curve", { species = tostring(key) }))
    end
    return curve
  end
  ---@param speciesKey string species identity under lookup
  ---@param form integer form index under lookup
  ---@return table<string, unknown> form record carrying stats, learnset, and yields
  local function catalogForm(_, speciesKey, form)
    local bucket = speciesFacts[speciesKey]
    local static = type(bucket) == "table" and bucket[form] or nil
    if type(static) ~= "table" then
      error(BattleErrors.missingBehavior("reward work needs the form facts", { species = tostring(speciesKey) }))
    end
    local record = static
    if type(record.baseStats) ~= "table" or type(record.growthCurve) ~= "table" then
      error(
        BattleErrors.missingBehavior(
          "reward work needs base stats and the growth curve",
          { species = tostring(speciesKey) }
        )
      )
    end
    if type(record.levelUpMoves) ~= "table" then
      error(BattleErrors.missingBehavior("reward work needs the form learnset", { species = tostring(speciesKey) }))
    end
    return record
  end
  ---@param key string move identity under lookup
  ---@return table<string, unknown> move record carrying its base power points
  local function catalogMove(_, key)
    local definition = moveFacts[key]
    if type(definition) ~= "table" then
      error(BattleErrors.missingBehavior("reward work needs the move facts", { move = tostring(key) }))
    end
    if type(definition.basePp) ~= "number" then
      error(BattleErrors.missingBehavior("reward work needs the move base power points", { move = tostring(key) }))
    end
    return definition
  end
  catalog.species = catalogSpecies
  catalog.growthCurve = catalogGrowthCurve
  catalog.form = catalogForm
  catalog.move = catalogMove
  return catalog --[[@as RewardCatalog]]
end

local EV_STAT_KEYS = { "hp", "attack", "defense", "speed", "specialAttack", "specialDefense" }

---@param yield unknown knockout effort yield under validation
---@return table<string, integer> validated six-stat yield
local function checkEvYield(yield)
  if type(yield) ~= "table" then
    error(BattleErrors.missingBehavior("reward work needs the defeated effort yield", {}))
  end
  local record = yield --[[@as table<string, integer>]]
  for _, stat in ipairs(EV_STAT_KEYS) do
    if type(record[stat]) ~= "number" or record[stat] % 1 ~= 0 or record[stat] < 0 then
      error(BattleErrors.missingBehavior("reward work needs a six-stat effort yield", { stat = stat }))
    end
  end
  return record
end

---@param state table<string, unknown> live battle state under reward work
---@param combatantId integer recipient identity under lookup
---@return table<string, unknown>? freshest unstepped reward copy, when one is open
local function inflightRewardMon(state, combatantId)
  local children = state.progressionChildren --[[@as table<integer, RewardChild>?]]
  if type(children) ~= "table" then
    return nil
  end
  local freshest = nil
  for _, child in ipairs(children) do
    if child.done ~= true then
      for _, recipient in ipairs(child.frame.recipients) do
        if recipient.combatant == combatantId then
          freshest = child.mons[recipient.monIndex]
        end
      end
    end
  end
  return freshest
end

---@param state table<string, unknown> live battle state under reward work
---@return boolean true when the enemy side answers to a trainer controller
local function trainerBattleFor(state)
  -- The application trainer factory seats enemy participants behind the
  -- "trainer:" controller prefix while wild encounters answer as "wild".
  for _, participantId in
    ipairs(state.participantOrder --[[@as integer[] ]])
  do
    local participant = BattleState.participant(state, participantId)
    if participant.side ~= 1 and type(participant.controller) == "string" then
      local controller = participant.controller --[[@as string]]
      if controller:sub(1, 8) == "trainer:" then
        return true
      end
    end
  end
  return false
end

--- Reads the current player reward identity from the recipient roster
--- context: the trainer facts the production scenario copies at
--- construction for traded and foreign award classification. A
--- production-marked context must carry complete facts and fails when
--- they are missing or half-wired; an unmarked context without facts
--- belongs to a self-contained synthetic session and classifies as
--- locally owned, while an unmarked context with complete facts still
--- classifies from them. Half-wired facts fail instead of guessing, so
--- only complete or empty unmarked identities flow into arithmetic.
---@param state table<string, unknown> live battle state under reward work
---@param combatantId integer recipient identity under reward
---@return table<string, unknown>? detached current player reward identity, or nil when the session carries none
local function playerRewardIdentity(state, combatantId)
  local combatant = BattleState.combatant(state, combatantId)
  local owner = BattleState.participant(state, combatant.participant --[[@as integer]])
  local context = owner.context --[[@as table<string, unknown>]]
  assert(type(owner.context) == "table", "reward work reads the recipient roster context")
  local marked = context.productionPlayer == true
  local trainerId = context.trainerId
  local trainerName = context.trainerName
  local language = context.language
  if trainerId == nil and trainerName == nil and language == nil then
    if marked then
      error(BattleErrors.missingBehavior("reward work needs the current player identity", {
        combatant = combatantId,
      }))
    end
    return nil
  end
  if
    type(trainerId) ~= "number"
    or trainerId --[[@as integer]]
      % 1 ~= 0
    or trainerId --[[@as integer]]
      < 0
    or type(trainerName) ~= "string"
    or trainerName == ""
    or type(language) ~= "string"
    or language == ""
  then
    error(BattleErrors.missingBehavior("reward work needs the current player identity", {
      combatant = combatantId,
    }))
  end
  return { trainerId = trainerId, trainerName = trainerName, language = language }
end

--- Classifies one recipient award from its battle-owned origin against
--- the current player identity: a mismatched trainer identity trades,
--- and a traded mon from another language earns the foreign rate instead
--- of the same-language trade lift. Sessions without player facts keep
--- every award local.
---@param identity table<string, unknown>? current player reward identity, or nil for self-contained sessions
---@param mon table<string, unknown> recipient battle-owned mon carrying its origin
---@return boolean traded
---@return boolean foreign
local function tradeFlags(identity, mon)
  if identity == nil then
    return false, false
  end
  local origin = mon.origin --[[@as table<string, unknown>]]
  assert(type(mon.origin) == "table", "reward work reads the recipient origin")
  assert(type(origin.language) == "string" and origin.language ~= "", "reward work reads the recipient language")
  local traded = origin.trainerId ~= identity.trainerId or origin.trainerName ~= identity.trainerName
  return traded, traded and origin.language ~= identity.language
end

---@param state table<string, unknown> live battle state under reward work
---@param catalog RewardCatalog reward catalog over session facts
---@param defeatedId integer knocked-out roster identity under reward
---@param defeatedActivation integer knocked-out entry token under reward
---@return table<string, unknown>? reward start input, or nil when nothing is owed
local function buildRewardInput(state, catalog, defeatedId, defeatedActivation)
  local defeated = BattleState.combatant(state, defeatedId)
  local foeParticipant = BattleState.participant(state, defeated.participant --[[@as integer]])
  if foeParticipant.side == 1 then
    return nil
  end
  local foeMon = defeated.mon --[[@as table<string, unknown>]]
  if type(defeated.mon) ~= "table" then
    error(BattleErrors.missingBehavior("reward work reads the defeated mon", { combatant = defeatedId }))
  end
  local foeForm = catalog:form(foeMon.species --[[@as string]], foeMon.form --[[@as integer]])
  local baseYield = foeForm.baseExpYield
  if type(baseYield) ~= "number" or baseYield % 1 ~= 0 or baseYield < 0 then
    error(BattleErrors.missingBehavior("reward work needs the defeated base yield", { combatant = defeatedId }))
  end
  local evYield = checkEvYield(foeForm.evYield)
  local foeSpecies = catalog:species(foeMon.species --[[@as string]])
  local foeLevel =
    Experience.level(catalog:growthCurve(foeSpecies.growthCurve --[[@as string]]), foeMon.experience --[[@as integer]])
  -- Rewards read the defeated entry's own participant set: a stale token
  -- or a missing record never falls back to battle-global credit.
  local records = state.rewardParticipation --[[@as table<integer, table<string, unknown>>]]
  assert(type(state.rewardParticipation) == "table", "reward work reads per-opponent participation")
  local record = records[defeatedId]
  if type(record) ~= "table" or record.activation ~= defeatedActivation then
    error(BattleErrors.invalidState("reward work pins the defeated entry", { combatant = defeatedId }))
  end
  local participants = record.combatants --[[@as table<integer, boolean>]]
  assert(type(record.combatants) == "table", "reward work reads the defeated participant set")
  local battlers = {}
  for _, combatantId in
    ipairs(state.combatantOrder --[[@as integer[] ]])
  do
    local combatant = BattleState.combatant(state, combatantId)
    local owner = BattleState.participant(state, combatant.participant --[[@as integer]])
    if owner.side == 1 then
      assert(type(combatant.mon) == "table", "reward work reads recipient mons")
      local source = inflightRewardMon(state, combatantId) or combatant.mon --[[@as table<string, unknown>]]
      local recipientSpecies = catalog:species(source.species --[[@as string]])
      local level = Experience.level(
        catalog:growthCurve(recipientSpecies.growthCurve --[[@as string]]),
        source.experience --[[@as integer]]
      )
      battlers[#battlers + 1] = {
        combatant = combatantId,
        participated = participants[combatantId] == true,
        expShare = source.heldItem == "EXP__SHARE",
        fainted = combatant.hp --[[@as integer]] <= 0,
        isEgg = source.isEgg == true,
        level = level,
      }
    end
  end
  local selected = RewardExperience.recipients({ battlers = battlers })
  if #selected == 0 then
    return nil
  end
  -- Participant and holder counts stay independent: a participating
  -- holder feeds both denominators and later earns both portions.
  local battlerCount, holderCount = 0, 0
  for _, recipient in ipairs(selected) do
    if recipient.participated == true then
      battlerCount = battlerCount + 1
    end
    if recipient.share == true then
      holderCount = holderCount + 1
    end
  end
  local knockout = { baseYield = baseYield, level = foeLevel, trainerBattle = trainerBattleFor(state) }
  local entries = {}
  for _, recipient in ipairs(selected) do
    local combatant = BattleState.combatant(state, recipient.combatant)
    local chained = inflightRewardMon(state, recipient.combatant)
    local entryMon = copyValue(chained or combatant.mon) --[[@as table<string, unknown>]]
    if chained == nil then
      entryMon.hp = combatant.hp
    end
    local traded, foreign = tradeFlags(playerRewardIdentity(state, recipient.combatant), entryMon)
    -- The stored condition byte travels as an explicit doubling mark:
    -- only a numeric nonzero byte doubles while zero stages flat. The
    -- carried item stays raw; battle item suppression never reaches
    -- this post-knockout award.
    local pokerusByte = entryMon.pokerus
    if type(pokerusByte) ~= "number" then
      error(BattleErrors.invalidState("effort rewards read a stored pokerus byte", {}))
    end
    local hasPokerus = pokerusByte ~= 0
    local effortModifiers = RewardEffort.modifiersFor(entryMon.heldItem, hasPokerus)
    entries[#entries + 1] = {
      combatant = recipient.combatant,
      mon = entryMon,
      expAward = RewardExperience.calculate(knockout, {
        battlers = battlerCount,
        holders = holderCount,
        participated = recipient.participated,
        share = recipient.share,
        luckyEgg = entryMon.heldItem == "LUCKY_EGG",
        traded = traded,
        foreign = foreign,
      }),
      evAward = RewardEffort.calculate(evYield, effortModifiers),
    }
  end
  return {
    defeated = { combatant = defeatedId, activation = defeatedActivation },
    entries = entries,
    catalog = catalog,
  }
end

---@param state table<string, unknown> live battle state under faint settlement
---@param catalog RewardCatalog reward catalog over session facts
---@param record table<string, unknown> settled faint record under reward
---@return table<string, unknown> plain reward summary for the faint outcome
local function startRewardChild(state, catalog, record)
  local target = record.target --[[@as table<string, unknown>]]
  local summary = { combatant = target.combatant, rewarded = false }
  local input =
    buildRewardInput(state, catalog, target.combatant --[[@as integer]], target.activation --[[@as integer]])
  -- The defeated entry's participant set is spent once its reward opens:
  -- the opened child carries fixed entries, so later entries of the same
  -- identity start fresh and snapshots never retain spent credit.
  local records = state.rewardParticipation --[[@as table<integer, table<string, unknown>>]]
  if type(state.rewardParticipation) == "table" then
    records[
      target.combatant --[[@as integer]]
    ] = nil
  end
  if input == nil then
    return summary
  end
  local opened = Progression.start(input)
  local children = state.progressionChildren --[[@as table<integer, RewardChild>]]
  assert(type(state.progressionChildren) == "table", "reward children travel as an array")
  children[#children + 1] = {
    defeated = opened.frame.defeated,
    mons = opened.flow.mons,
    frame = opened.frame,
    evolutionEligible = opened.flow.evolutionEligible,
    done = false,
  }
  local eligible = state.evolutionEligible --[[@as table<integer, integer>]]
  assert(type(state.evolutionEligible) == "table", "evolution eligibility travels as an array")
  for _, combatantId in ipairs(opened.flow.evolutionEligible) do
    local known = false
    for _, seen in ipairs(eligible) do
      if seen == combatantId then
        known = true
      end
    end
    if not known then
      eligible[#eligible + 1] = combatantId
    end
  end
  summary.rewarded = true
  return summary
end

---@param state table<string, unknown> live battle state under reward work
---@param child RewardChild reward child under synchronization
local function syncRewardMons(state, child)
  for _, recipient in ipairs(child.frame.recipients) do
    local mon = child.mons[recipient.monIndex]
    assert(type(mon) == "table", "reward recipients name a battle-owned mon")
    local synced = copyValue(mon) --[[@as table<string, unknown>]]
    child.mons[recipient.monIndex] = synced
    local combatant = BattleState.combatant(state, recipient.combatant)
    -- Rewards earned while alive survive later knocks in the same turn,
    -- but the battle health never revives: a recipient that fell after
    -- its award keeps zero health with its gains on the record.
    if
      type(synced.hp) == "number"
      and combatant.hp --[[@as integer]]
        > 0
    then
      combatant.hp = synced.hp --[[@as integer]]
    end
    -- The reward owner tracks health on a working top-level field the
    -- persistent mon schema forbids: fold it into the condition and drop
    -- it before the copy reaches battle state.
    if type(synced.condition) == "table" then
      synced
        .condition --[[@as table<string, unknown>]]
        .currentHp = combatant.hp
    end
    synced.hp = nil
    combatant.mon = synced
  end
end

---@class NativeTurnHandlers
---@field openTurn fun(choices: table<integer, table<string, unknown>>)
---@field executeAction fun(action: table<string, unknown>)
---@field applyResiduals fun()
---@field closeTurn fun()
---@field commitLearning fun(state: table<string, unknown>)
---@field settleEntryTiming fun(state: table<string, unknown>, entrant: integer)
---@field settlePostReplacement fun(state: table<string, unknown>)

---@param executor HgssSessionExecutor live native session owning the turn
---@param moveFacts table<string, table<string, unknown>> immutable move facts carried by the session
---@param speciesFacts table<string, SpeciesFormFacts> static species facts carried by the session
---@param itemFacts table<string, table<string, unknown>> immutable item facts carried by the session
---@param chart table<string, unknown> session chart view resolving directed effectiveness
---@param moneySet table<string, boolean> held-item keys carrying the money-up effect
---@param battleKind string wild-or-trainer encounter policy selecting flight and capture law
---@return NativeTurnHandlers lifecycle handlers bound to the session
local function bindTurnHandlers(executor, moveFacts, speciesFacts, itemFacts, chart, moneySet, battleKind)
  -- The resumable reward owner resolves its levels, stats, learnsets,
  -- and yields through the immutable session facts on every faint,
  -- rebuilt here from the same tables the snapshots carry.
  local rewardCatalog = rewardCatalogFor(speciesFacts, moveFacts)
  -- Ordered replacement obligations settled by the faint owner during
  -- the open turn, enriched with live topology facts as each knockout
  -- leaves the field. Reset when a turn opens and drained once when it
  -- closes; reward suspension carries the drained list, never a
  -- rebuild of it.
  local pendingFaintObligations = {} ---@type table<integer, table<string, unknown>>
  ---@param choices table<integer, table<string, unknown>> committed choices in commit order
  local function openTurn(choices)
    local state = executor:_live()
    pendingFaintObligations = {}
    -- Revenge ledgers reset with the turn: damage taken and actions
    -- consumed belong to the turn being ordered, while the distinct-move
    -- history behind Last Resort accumulates until entries turn over.
    state.turnStrikes = {}
    state.turnActed = {}
    local stream = state.rng --[[@as table<string, unknown>]]
    assert(type(stream.nextU16) == "function", "native turns draw ties from the battle stream")
    -- The bridge stays function-local: the turn seam already holds the
    -- maximum chunk references, so nested checkpoints require the
    -- private composition beside the chunk require instead.
    local Bridge = require("libs.battle.src.gen4.NativePassiveBridge")
    local bridge = Bridge.wrap(state)
    local candidates = {} ---@type table<integer, table<string, unknown>>
    for ordinal, entry in ipairs(choices) do
      local choice = entry.choice --[[@as table<string, unknown>]]
      local actor = choice.actor --[[@as table<string, unknown>]]
      local kind = choice.kind --[[@as string]]
      local combatant = BattleState.combatant(state, actor.combatant --[[@as integer]])
      local priority = bracketFor(kind)
      if kind == "attack" then
        local payload = choice.payload --[[@as table<string, unknown>]]
        local moveName = resolveMove(combatant.mon, payload.moveSlot)
        priority = movePriority(moveFacts, moveName)
      end
      local speed = projectCombatant(combatant, speciesFacts, bridge).speed
      -- Tailwind doubles its side sampled speed at order time.
      local participant = BattleState.participant(state, combatant.participant --[[@as integer]])
      if
        sideActive(state, participant.side --[[@as integer]], "tailwind")
      then
        speed = speed * 2
      end
      -- Live ordering facts stage with the candidate: the stored
      -- pre-turn sample maps through the holder position, early-order
      -- holdings read it with no draw, pinch holdings read live
      -- health, and a spent ordering holding is consumed here so later
      -- checkpoints see the empty holding. Invalid sample shape fails
      -- before sorting instead of resampling the stream.
      local pending = state.pending --[[@as table<string, unknown>]]
      local rolls = pending.nativeOrderRolls
      if type(rolls) ~= "table" then
        error(BattleErrors.incompatibleSnapshot("open batches carry their pre-turn order samples", {}))
      end
      for index = 1, 4 do
        local sample = (rolls --[[@as table<integer, unknown>]])[index]
        if type(sample) ~= "number" or sample % 1 ~= 0 or sample < 0 or sample > 65535 then
          error(BattleErrors.incompatibleSnapshot("pre-turn order samples stay raw 16-bit values", { index = index }))
        end
      end
      local liveEntry = combatant.active
      if type(liveEntry) ~= "table" then
        error(BattleErrors.invalidState("ordering stages only entered actors", {}))
      end
      local position = (liveEntry --[[@as table<string, unknown>]]).position --[[@as integer]]
      local roll = (rolls --[[@as table<integer, integer>]])[position]
      if type(roll) ~= "number" then
        roll = (rolls --[[@as table<integer, integer>]])[((position - 1) % 4) + 1]
      end
      local orderContext = { actionCheck = true, berryCheck = true, rawOrderRoll = roll }
      if kind == "attack" then
        orderContext.moveUse = { user = actor.combatant }
      end
      local order = bridge:orderFacts(actor.combatant --[[@as integer]], orderContext)
      if order.consume == true then
        BattleContext.wrap(state):consumeHeldItem(actor.combatant --[[@as integer]])
      end
      local boosted, lowered, stalled = order.first, order.last, order.stall
      candidates[#candidates + 1] = {
        id = ordinal,
        actor = { combatant = actor.combatant, activation = actor.activation },
        kind = kind,
        payload = copyValue(choice.payload),
        selectedOrdinal = ordinal,
        priority = priority,
        speed = speed,
        boostedPriority = boosted,
        loweredPriority = lowered,
        stall = stalled,
      }
      entry.ordinal = ordinal
    end
    -- Trick Room reverses only the speed dimension while its field
    -- instance stands.
    local ordered = TurnOrder.buildActions(candidates, { trickRoom = fieldActive(state, "trickroom") }, stream)
    local queue = state.queue --[[@as table<integer, table<string, unknown>>]]
    for _, action in ipairs(ordered) do
      local staged = action --[[@as table<string, unknown>]]
      for _, entry in ipairs(choices) do
        local choice = entry.choice --[[@as table<string, unknown>]]
        local actor = choice.actor --[[@as table<string, unknown>]]
        local stagedActor = staged.actor --[[@as table<string, unknown>]]
        if
          actor.combatant == stagedActor.combatant
          and actor.activation == stagedActor.activation
          and staged.selectedOrdinal == entry.ordinal
        then
          staged.controller = entry.controller
        end
      end
      if staged.kind == "run" then
        -- Flight odds compare the committed matchup: both speeds freeze
        -- here, so a mid-turn arrival never rewrites the staged escape.
        local runner = BattleState.combatant(state, staged.actor.combatant --[[@as integer]])
        local player, enemy = stagedEscapeSpeeds(state, runner, speciesFacts)
        staged.escapeSpeeds = { player = player, enemy = enemy }
      end
      ActionQueue.enqueue(queue, action)
    end
  end

  ---@param state table<string, unknown> live battle state under faint settlement
  ---@param cause table<string, unknown> semantic reason that ordered the knockout
  ---@return table<string, unknown> the emitted faint event
  local function emitFaint(state, cause)
    local context = BattleContext.wrap(state)
    local combatant = BattleState.combatant(state, cause.combatant --[[@as integer]])
    local active = combatant.active --[[@as table<string, unknown>]]
    local position = active.position --[[@as integer]]
    local event = context:emit("faint", { kind = "faint", combatant = cause.combatant }, {
      combatant = cause.combatant,
      activation = active.activation,
      position = position,
    })
    BattleState.leave(state, position)
    return event
  end

  --- Settles newly zero-HP actives in detection order: each knockout
  --- emits once, leaves its position, and banks its enriched replacement
  --- obligation for turn-end replacement work.
  ---@param state table<string, unknown> live battle state under faint settlement
  local function sweepFaints(state)
    local detected = false
    for _, combatantId in
      ipairs(state.combatantOrder --[[@as integer[] ]])
    do
      local combatant = BattleState.combatant(state, combatantId)
      if
        combatant.active ~= nil
        and combatant.hp --[[@as integer]]
          <= 0
      then
        local active = combatant.active --[[@as table<string, unknown>]]
        local faints = state.faints --[[@as table<integer, table<string, unknown>>]]
        Fainting.detect(faints, {
          combatant = combatantId,
          activation = active.activation,
        }, { kind = "faint", combatant = combatantId }, #faints + 1)
        detected = true
      end
    end
    if not detected then
      return
    end
    local function spawnRewardChild(record)
      return startRewardChild(state, rewardCatalog, record)
    end
    local outcome = Fainting.step({
      queue = state.faints,
      reserves = pooledReserves(state),
      progression = spawnRewardChild,
    }, { kind = "faint", cursor = "settle" })
    -- The faint owner names every ordered replacement obligation; the
    -- session only attaches the live topology facts each knockout needs
    -- at replacement time. Vacated positions come from the emitted
    -- faint payloads, keyed by fainted entry, so enrichment can never
    -- create, drop, or reorder obligations.
    local vacated = {} ---@type table<string, integer>
    for _, event in ipairs(outcome.events) do
      local record = event --[[@as table<string, unknown>]]
      local emitted = emitFaint(state, record)
      local payload = emitted.payload --[[@as table<string, unknown>]]
      vacated[
        record.combatant --[[@as integer]] .. ":" .. payload.activation --[[@as integer]]
      ] =
        payload.position --[[@as integer]]
    end
    for _, minimal in ipairs(outcome.replacements) do
      local entry = minimal --[[@as table<string, unknown>]]
      local combatantId = entry.combatant --[[@as integer]]
      local entryToken = entry.activation --[[@as integer]]
      local position = vacated[combatantId .. ":" .. entryToken]
      if position == nil then
        error(BattleErrors.invalidState("faint obligations bind a vacated position", {
          combatant = combatantId,
        }))
      end
      local combatant = BattleState.combatant(state, combatantId)
      local participant = BattleState.participant(state, combatant.participant --[[@as integer]])
      local obligation = {
        combatant = combatantId,
        activation = entryToken,
        position = position,
        participant = participant.id,
        controller = participant.controller,
        side = participant.side,
        internal = false,
      }
      obligation.internal = not isExternalObligation(obligation)
      pendingFaintObligations[#pendingFaintObligations + 1] = obligation
    end
  end

  -- Invokes one named finite timing through the shared dispatcher over
  -- the live bag: entry once an arrival is established, beforeAction for
  -- a due actor. Handler mutations commit through the residual health
  -- path, expired countdowns sweep, and faint settlement follows before
  -- later schedule work assumes the actor remains alive. Before-action
  -- handlers deny the action through the pass-context flag, and only the
  -- actor's own instances participate; the pending strike identity and
  -- power gate the selection constraints, and drowsy arrivals sleep
  -- through the status owner. Entry hazards strike only the entrant
  -- through their handler-side scoping, price grounding through the
  -- entry facts, write toxic arrivals through the status owner, and
  -- absorb through the hazard clearer. Returns the blocking
  -- effect key, if any.
  ---@param state table<string, unknown> live battle state under the timing
  ---@param timing string finite timing under invocation
  ---@param target integer combatant entering or acting under the timing
  ---@param pending table<string, unknown>? pending strike identity and power for before-action gates
  ---@return string? blocking effect key when a before-action handler denied the action
  local function invokeTiming(state, timing, target, pending)
    local bag = liveEffectBag(state)
    local sample = sampleTimingState(state, speciesFacts)
    local view = BattleContext.wrap(state)
    ---@type table<string, unknown>
    local context = { speeds = sample.speeds, health = sample.health, stream = state.rng }
    -- Major-condition writes go through the status owner so exclusivity,
    -- activity, and health guards hold exactly as on the move path; the
    -- resulting status event joins the pass events below.
    local function writeStatus(combatant, key, conditionState)
      return view:applyStatus(combatant, key, conditionState, { kind = timing })
    end
    local dispatchOwner ---@type table<string, unknown>
    if timing == "entry" then
      context.applyStatus = writeStatus
      -- Poison arrivals absorb their own side layers: the clearer drops
      -- the side instance mid-pass so later entries face clean ground.
      local function clearHazard()
        local side = sample.sides[target]
        for _, record in ipairs(bag:capture()) do
          local entry = record --[[@as table<string, unknown>]]
          local scope = entry.scope --[[@as table<string, unknown>]]
          if entry.key == "toxicspikes" and type(scope) == "table" and scope.kind == "side" and scope.side == side then
            return bag:remove(record.id --[[@as integer]])
          end
        end
        return false
      end
      context.clearHazard = clearHazard
      dispatchOwner = EffectDispatch.new(
        bag,
        NativeEffectHandlers.handlersFor({
          maxHp = sample.ceilings,
          types = sample.typeMap,
          occupants = sample.occupants,
          sides = sample.sides,
          entrant = target,
          grounded = entrantGrounded(state, target, sample.typeMap[target]),
          chart = chart,
        }, timing)
      )
    elseif timing == "beforeAction" then
      assert(type(pending) == "table", "before-action passes carry their pending strike")
      context.move = (pending --[[@as table<string, unknown>]]).move
      context.power = (pending --[[@as table<string, unknown>]]).power
      context.applyStatus = writeStatus
      local entry = BattleState.combatant(state, target).active --[[@as table<string, unknown>?]]
      local activation = nil
      if entry ~= nil then
        activation = entry.activation
      end
      local suppressed = {} ---@type table<integer, boolean>
      for _, record in ipairs(bag:capture()) do
        local scope = record.scope
        if
          type(scope) ~= "table"
          or scope.combatant ~= target
          or (scope.activation ~= nil and scope.activation ~= activation)
        then
          suppressed[
            record.id --[[@as integer]]
          ] = true
        end
      end
      context.suppressedIds = suppressed
      dispatchOwner = EffectDispatch.new(
        bag,
        NativeEffectHandlers.handlersFor({
          maxHp = sample.ceilings,
          types = sample.typeMap,
          occupants = sample.occupants,
          stats = sample.stats,
        }, timing)
      )
    else
      error(BattleErrors.invalidState("the native session invokes only entry and before-action timings", {
        timing = timing,
      }))
    end
    local outcome = dispatchOwner:invoke(timing --[[@as string]], context)
    for _, event in
      ipairs(outcome.events --[[@as table<integer, table<string, unknown>>]])
    do
      local record = event --[[@as table<string, unknown>]]
      if
        record.kind --[[@as string]]
        ~= "faint"
      then
        view:emit(record.kind --[[@as string]], { kind = record.kind }, copyValue(record))
      end
    end
    commitTimingHealth(state, sample.health, sample.ceilings)
    sweepExpiredEffects(state)
    sweepFaints(state)
    return context.blockedBy --[[@as string?]]
  end

  ---@param state table<string, unknown> live battle state under execution
  ---@param action table<string, unknown> queued native action under execution
  ---@param ordinal integer commit order of this action
  local function executeAttack(state, action, ordinal)
    local context = BattleContext.wrap(state)
    local stream = state.rng --[[@as table<string, unknown>]]
    assert(type(stream.nextU16) == "function", "native strikes draw from the battle stream")
    local actor = action.actor --[[@as table<string, unknown>]]
    local combatant = BattleState.combatant(state, actor.combatant --[[@as integer]])
    -- Finite volatile effects gate the strike before persistent status:
    -- a denied action never starts, spends nothing, and draws nothing
    -- beyond the timing's own labeled rolls. Switching and item use
    -- bypass the gate, so only the attack branch funnels here. The
    -- pending strike identity and power are resolved first so the
    -- selection constraints gate the same strike the path would execute.
    local payload = action.payload --[[@as table<string, unknown>]]
    local moveName, ownerSlot = resolveMove(combatant.mon, payload.moveSlot)
    local pendingPower = movePower(moveFacts, moveName)
    if
      invokeTiming(state, "beforeAction", actor.combatant --[[@as integer]], { move = moveName, power = pendingPower })
      ~= nil
    then
      return
    end
    -- Persistent status gates every strike at the before-action
    -- checkpoint: blocked actions never start, spend nothing, and draw
    -- nothing beyond the gate's own labeled roll.
    local gate = Status.beforeAction(
      combatant.mon --[[@as table<string, unknown>]],
      stream --[[@as table<string, unknown>]],
      { kind = "status-gate", combatant = actor.combatant }
    )
    if gate.event ~= nil then
      context:emit("status-gate", { kind = "status-gate", combatant = actor.combatant }, {
        combatant = actor.combatant,
        key = gate.event.key,
        outcome = gate.event.outcome,
      })
    end
    if not gate.acts then
      return
    end
    -- Executed strikes reveal their move to every opposing trainer
    -- memory; a fresh entry clears that knowledge again at arrival.
    -- Routed through the executor so the turn closure keeps its
    -- upvalue budget.
    executor:_observeTrainerMove(state, actor.combatant --[[@as integer]], moveName)
    local defenderId =
      resolveTarget(state, actor.combatant --[[@as integer]], payload.target --[[@as table<string, unknown>]])
    if defenderId == nil then
      return
    end
    local defender = BattleState.combatant(state, defenderId)
    local moveRecord = moveFacts[moveName]
    local category = type(moveRecord) == "table" and (moveRecord --[[@as table<string, unknown>]]).category or nil
    -- One strike-facts projection keeps the turn closure inside its
    -- upvalue budget: raw and staged stats, ability reshaping, burn,
    -- resilience, and field weather arrive together.
    local strike = strikeCombatFacts(state, combatant, defender, speciesFacts, category, moveName)
    local facts = strike.facts
    local attackerStats = strike.attackerStats
    local defenderStats = strike.defenderStats
    local attackerAbility = strike.attackerAbility
    local attackerCondition = strike.attackerCondition
    local defenderTypes = {} ---@type table<integer, string[]>
    defenderTypes[defenderId] = combatantTypes(defender, speciesFacts)
    local moves = combatant
      .mon --[[@as table<string, unknown>]]
      .moves
    if type(moves) ~= "table" then
      moves = {}
    end
    local userMon = combatant.mon --[[@as table<string, unknown>]]
    local foeMon = defender.mon --[[@as table<string, unknown>]]
    local recentMoves = state.lastMoves
    if type(recentMoves) ~= "table" then
      recentMoves = {}
    end
    -- Source-law facts the strike frame carries beside the staged pair:
    -- turn interaction for revenge-law handlers, stage-effective speeds
    -- for weightless power, defender level and weight for knockout and
    -- falloff law, abilities for sturdy and skill-link gates, the holder
    -- item with its immutable throw facts, user individual values for
    -- hidden power, the distinct-move history for last resort, and the
    -- beat-up party. Absent facts fail in their handler, never default.
    local heldItem = nil
    if type(userMon.heldItem) == "string" and userMon.heldItem ~= "" and userMon.heldItem ~= "NONE" then
      heldItem = userMon.heldItem
    end
    -- The user species travels for species-gated holder answers behind
    -- live strikes; readers fail closed when older frames omit it.
    local userSpecies = nil
    if type(userMon.species) == "string" and userMon.species ~= "" then
      userSpecies = userMon.species
    end
    local userIvs = nil
    if type(userMon.ivs) == "table" then
      userIvs = copyValue(userMon.ivs)
    end
    local usedMoves = {}
    if type(state.usedMoves) == "table" then
      local recorded = (state.usedMoves --[[@as table<integer, unknown>]])[
        actor.activation --[[@as integer]]
      ]
      if type(recorded) == "table" then
        usedMoves = copyValue(recorded)
      end
    end
    local genders = {}
    local userGender = genderOf(userMon, speciesFacts)
    if userGender ~= nil then
      genders[
        actor.combatant --[[@as integer]]
      ] = userGender
    end
    local foeGender = genderOf(foeMon, speciesFacts)
    if foeGender ~= nil then
      genders[defenderId] = foeGender
    end
    local inputs = {
      actionId = action.id,
      actor = { combatant = actor.combatant, activation = actor.activation },
      requestedMove = moveName,
      executingMove = moveName,
      ppOwnerSlot = ownerSlot,
      calledBy = nil,
      selectedTarget = copyValue(payload.target),
      targets = { { combatant = defenderId } },
      moves = moves,
      moveFacts = moveFacts,
      combat = facts,
      burned = attackerCondition == "burn",
      guts = attackerAbility == "GUTS",
      weather = strike.weather,
      weatherSuppressed = strike.weatherSuppressed,
      attackerTypes = combatantTypes(combatant, speciesFacts),
      defenderTypes = defenderTypes,
      typeChart = chart,
      stream = stream,
      friendship = userMon.friendship,
      usable = usableKeysOf(userMon),
      party = benchKeysOf(state, combatant),
      userMoves = moveKeysOf(userMon),
      copiedMove = recentMoves[defenderId],
      recentMoves = copyValue(recentMoves),
      genders = genders,
      userAsleep = asleepOf(userMon),
      duel = StrikeFacts.duel(state, actor.combatant --[[@as integer]], defenderId),
      speeds = { user = attackerStats.speed, foe = defenderStats.speed },
      foeLevel = defenderStats.level,
      abilities = { user = userMon.ability, foe = foeMon.ability },
      heldItem = heldItem,
      userSpecies = userSpecies,
      userIvs = userIvs,
      itemFacts = itemFacts,
      usedMoves = usedMoves,
      foeWeightHg = defenderStats.weightHg,
      beatup = StrikeFacts.beatup(state, combatant, defender, speciesFacts),
    }
    local node = MoveExecution.start(inputs)
    if type(node) == "table" and node.locals ~= nil then
      local started = node.locals --[[@as table<string, unknown>]]
      if started.failed == nil and type(node.requestedMove) == "string" then
        if type(state.lastMoves) ~= "table" then
          state.lastMoves = {}
        end
        (state.lastMoves --[[@as table<integer, string>]])[
          actor.combatant --[[@as integer]]
        ] =
          node.requestedMove --[[@as string]]
        -- Received-hit history behind the trainer switch tails keys on
        -- the struck combatant: the striking move and its user record
        -- exactly once per executed strike, mirroring the native
        -- moveNoHit pair, whether or not the strike later lands.
        if type(state.lastHits) ~= "table" then
          state.lastHits = {}
        end
        (state.lastHits --[[@as table<integer, table<string, unknown>>]])[
          defenderId --[[@as integer]]
        ] =
          {
            move = node.requestedMove --[[@as string]],
            user = actor.combatant --[[@as integer]],
          }
        -- Distinct-move history behind Last Resort and the trainer
        -- history reads keys on the entry token in first-use order, so
        -- withdrawing resets the count like the native lastResortMoves.
        -- Struggle records harmlessly beside real moves.
        if type(state.usedMoves) ~= "table" then
          state.usedMoves = {}
        end
        local ledger = state.usedMoves --[[@as table<integer, table<integer, string>>]]
        local entry = ledger[
          actor.activation --[[@as integer]]
        ]
        if type(entry) ~= "table" then
          entry = {}
          ledger[
            actor.activation --[[@as integer]]
          ] = entry
        end
        local seen = false
        for _, key in ipairs(entry) do
          if
            key == node.requestedMove --[[@as string]]
          then
            seen = true
            break
          end
        end
        if not seen then
          entry[#entry + 1] = node.requestedMove --[[@as string]]
        end
      end
    end
    local emittedThrough = #state.outbox --[[@as table<integer, table<string, unknown>>]]
    while true do
      node = MoveExecution.step(context, node)
      if type(node) == "table" and node.kind == "complete" and node.frame == nil then
        break
      end
    end
    -- Scattered pay day coins total into the battle payout through the
    -- move outcome; the committer scales and caps the scatter.
    if type(node) == "table" and type(node.payday) == "number" then
      state.paydayScattered = (
        state.paydayScattered --[[@as integer?]]
        or 0
      ) + node.payday --[[@as integer]]
    end
    -- Tag this action's move events with its commit ordinal so shared
    -- presentation keeps one stable per-action order.
    local outbox = state.outbox --[[@as table<integer, table<string, unknown>>]]
    for index = emittedThrough + 1, #outbox do
      local event = outbox[index]
      if event.actionId == nil then
        event.actionId = ordinal
      end
    end
    sweepFaints(state)
  end

  ---@param state table<string, unknown> live battle state under execution
  ---@param context table<string, unknown> validated mutation surface emitting the exchange
  ---@param action table<string, unknown> queued native action under execution
  ---@param ordinal integer commit order of this action
  ---@param cause table<string, unknown> semantic reason carried by the emitted event
  local function executeSwitch(state, context, action, ordinal, cause)
    local actor = action.actor --[[@as table<string, unknown>]]
    local payload = action.payload --[[@as table<string, unknown>]]
    local combatant = BattleState.combatant(state, actor.combatant --[[@as integer]])
    local active = combatant.active --[[@as table<string, unknown>]]
    local slot = active.position --[[@as integer]]
    local reserves = eligibleReserves(state, combatant.participant --[[@as integer]], {})
    local reserved = siblingReserves(state, payload.replacement --[[@as integer]])
    local fainted = faintedIds(state)
    local held = combatant.trap
    if held == nil then
      held = volatileTrapOf(state, actor.combatant --[[@as integer]])
    end
    -- An effective shell slips trapping for the voluntary departure:
    -- the native shell bypasses the trap check while a suppressed one
    -- holds, so the flag travels beside the trap.
    local Bridge = require("libs.battle.src.gen4.NativePassiveBridge")
    local shedShell = Bridge.wrap(state):effectiveHeldItem(actor.combatant --[[@as integer]]) == "SHED_SHELL"
    local verdict = Switching.eligible({
      position = slot,
      incoming = payload.replacement,
      reason = "voluntary",
      reserves = reserves,
      reserved = reserved,
      fainted = fainted,
      trap = held,
      shedShell = shedShell,
    })
    if not verdict.ok then
      error(BattleErrors.invalidState("committed exchanges stay eligible", { reason = verdict.reason }))
    end
    local frame = Switching.start({
      position = slot,
      outgoing = { combatant = actor.combatant, activation = actor.activation },
      incoming = payload.replacement,
      reason = "voluntary",
      reserves = reserves,
      reserved = reserved,
      fainted = fainted,
      trap = held,
      shedShell = shedShell,
    })
    local stepped = Switching.step({}, frame)
    assert(stepped.done == true, "voluntary exchanges settle without interception")
    BattleState.leave(state, slot)
    local activation = BattleState.enter(state, payload.replacement --[[@as integer]], slot)
    -- Voluntary replacement clears outgoing activation-local instances
    -- per definition lifecycle and resets the outgoing toxic counter.
    settleEntry(state, actor.combatant --[[@as integer]], payload.replacement --[[@as integer]], activation)
    -- Replacements send out under the money-up scan: the latch only
    -- ever moves 1 -> 2 and never resets when the holder leaves.
    noteEntry(state, moneySet, payload.replacement --[[@as integer]])
    -- Voluntary arrivals join the reward participation of every foe they
    -- now face, so a reserve taking the field before the knockout still
    -- counts as a recipient; arriving foes open their own fresh record.
    noteBattleEntry(state, payload.replacement --[[@as integer]])
    local event = context:emit("switch", cause, {
      position = slot,
      from = actor.combatant,
      to = payload.replacement,
    })
    event.actionId = ordinal
    -- The arrival runs its entry pass before it may act: a hazard faint
    -- queues through ordinary faint ownership for the turn-close drain.
    invokeTiming(state, "entry", payload.replacement --[[@as integer]])
  end

  ---@param state table<string, unknown> live battle state under execution
  ---@param context table<string, unknown> validated mutation surface emitting the throw
  ---@param action table<string, unknown> queued native action under execution
  ---@param plan table<string, unknown> executable bag plan naming the thrown ball
  ---@param choice table<string, unknown> validated bag choice carrying the target
  ---@param ordinal integer commit order of this action
  ---@param cause table<string, unknown> semantic reason carried by the emitted events
  local function executeBall(state, context, action, plan, choice, ordinal, cause)
    if battleKind ~= "wild" then
      error(BattleErrors.invalidState("committed throws keep their wild encounter kind", {}))
    end
    local actor = action.actor --[[@as table<string, unknown>]]
    local target = choice.target --[[@as table<string, unknown>]]
    local planRecord = plan --[[@as table<string, unknown>]]
    local outcome = Capture.execute({
      actor = actor.combatant,
      inventoryId = choice.inventoryId,
      ball = planRecord.item,
      target = { combatant = target.combatant },
    }, state, state.rng --[[@as table<string, unknown>]])
    local ledger = state.captures --[[@as table<integer, table<string, unknown>>]]
    ledger[#ledger + 1] = copyValue(outcome.result)
    for _, emitted in ipairs(outcome.events) do
      local record = emitted --[[@as table<string, unknown>]]
      local detail = {} ---@type table<string, unknown>
      for name, value in pairs(record) do
        if name ~= "kind" then
          detail[name] = copyValue(value)
        end
      end
      local event = context:emit(record.kind --[[@as string]], cause, detail)
      event.actionId = ordinal
    end
    if outcome.result.success == true then
      endBattleEarly(state, { kind = "captured", rounds = state.round })
    end
  end

  ---@param state table<string, unknown> live battle state under execution
  ---@param context table<string, unknown> validated mutation surface emitting the bag use
  ---@param action table<string, unknown> queued native action under execution
  ---@param ordinal integer commit order of this action
  ---@param cause table<string, unknown> semantic reason carried by the emitted event
  local function executeItem(state, context, action, ordinal, cause)
    local actor = action.actor --[[@as table<string, unknown>]]
    local payload = action.payload --[[@as table<string, unknown>]]
    local combatant = BattleState.combatant(state, actor.combatant --[[@as integer]])
    local participant = BattleState.participant(state, combatant.participant --[[@as integer]])
    local inventoryId = participant.inventoryId --[[@as string]]
    if type(inventoryId) ~= "string" or inventoryId == "" then
      error(BattleErrors.invalidState("committed bag use keeps its declared inventory", {}))
    end
    local holder = payload.target --[[@as table<string, unknown>]]
    assert(type(holder) == "table", "committed bag use keeps its validated holder")
    local choice = {
      inventoryId = inventoryId,
      item = payload.item,
      target = { kind = "combatant", combatant = holder.combatant },
    }
    -- Reservations were accounted when the reply was sealed, so planning
    -- here classifies against the live battle state without double-counting
    -- the sealed promise. Servings read the immutable session item facts;
    -- balls never reach them. The live state carries the battle-local
    -- effects battle-only servings gate on, so no reduced view travels here.
    local plan = ItemUse.plan(choice, state, itemFacts)
    if plan.failureReason ~= nil then
      -- The holder left the field after the reply was sealed: the
      -- serving is refused with no stock, ledger, draw, or health
      -- effect. Planning draws nothing, so the stream is untouched.
      local refused = context:emit("item", cause, {
        item = payload.item,
        inventory = inventoryId,
        refused = plan.failureReason,
      })
      refused.actionId = ordinal
      return
    end
    if CaptureContext.isBall(plan.item) then
      executeBall(state, context, action, plan, choice, ordinal, cause)
      return
    end
    local holderState = (state.combatants --[[@as table<integer, table<string, unknown>>]])[
      holder.combatant --[[@as integer]]
    ]
    if
      type(holderState) ~= "table"
      or holderState.hp --[[@as integer]]
        <= 0
    then
      local faintedHolder = context:emit("item", cause, {
        item = payload.item,
        inventory = inventoryId,
        refused = "invalid_target",
      })
      faintedHolder.actionId = ordinal
      return
    end
    if type(holderState.maxHp) ~= "number" then
      error(BattleErrors.missingBehavior("bag use reads its holder maximum health", {}))
    end
    local outcome = ItemUse.execute(plan, state, state.rng --[[@as table<string, unknown>]])
    local event = context:emit("item", cause, {
      item = payload.item,
      inventory = inventoryId,
      target = copyValue(outcome.target),
      restored = outcome.restored,
    })
    event.actionId = ordinal
  end

  ---@param state table<string, unknown> live battle state under execution
  ---@param context table<string, unknown> validated mutation surface emitting the flight
  ---@param action table<string, unknown> queued native action under execution
  ---@param ordinal integer commit order of this action
  ---@param cause table<string, unknown> semantic reason carried by the emitted event
  local function executeRun(state, context, action, ordinal, cause)
    local actor = action.actor --[[@as table<string, unknown>]]
    local staged = action.escapeSpeeds --[[@as table<string, unknown>?]]
    if type(staged) ~= "table" or type(staged.player) ~= "number" or type(staged.enemy) ~= "number" then
      error(BattleErrors.invalidState("flight carries its staged speeds", {}))
    end
    local combatant = BattleState.combatant(state, actor.combatant --[[@as integer]])
    -- Binding and trapping volatiles hold like scenario-seeded traps.
    local trap = combatant.trap
    if trap == nil then
      trap = volatileTrapOf(state, actor.combatant --[[@as integer]])
    end
    -- Assured flight answers through the live passives before any trap
    -- or odds: an effective Smoke Ball or the running ability leaves
    -- outright while suppressed holdings fall back to the odds roll, so
    -- neither holds the runner.
    local assured = false
    local Bridge = require("libs.battle.src.gen4.NativePassiveBridge")
    local flight = Bridge.wrap(state):invoke("beforeAction", actor.combatant --[[@as integer]], {
      flee = true,
      actionCheck = true,
    })
    for _, event in ipairs(flight.events) do
      if
        (event --[[@as table<string, unknown>]]).escape == "assured"
      then
        assured = true
      end
    end
    if assured then
      trap = nil
    end
    local result = Escape.attempt({
      battleKind = battleKind,
      trapped = trap,
      guaranteed = assured,
      speeds = { player = staged.player, enemy = staged.enemy },
      attempts = state.escapeAttempts,
      stream = state.rng,
    })
    if result.escaped == true then
      local fled = context:emit("flee", cause, {
        combatant = actor.combatant,
        activation = actor.activation,
        escaped = true,
        reason = result.reason,
        attempts = result.attempts,
      })
      fled.actionId = ordinal
      endBattleEarly(state, { kind = "escaped", rounds = state.round })
      return
    end
    state.escapeAttempts = result.attempts
    local held = context:emit("flee", cause, {
      combatant = actor.combatant,
      activation = actor.activation,
      escaped = false,
      reason = result.reason,
      attempts = result.attempts,
    })
    held.actionId = ordinal
  end

  ---@param state table<string, unknown> live battle state under execution
  ---@param action table<string, unknown> queued native action under execution
  ---@param ordinal integer commit order of this action
  local function executeChoice(state, action, ordinal)
    local context = BattleContext.wrap(state)
    local actor = action.actor --[[@as table<string, unknown>]]
    local cause = {
      kind = "decision",
      controller = action.controller,
      combatant = actor.combatant,
      activation = actor.activation,
    }
    if action.kind == "attack" then
      executeAttack(state, action, ordinal)
    elseif action.kind == "switch" then
      executeSwitch(state, context, action, ordinal, cause)
    elseif action.kind == "confirm" then
      pushCheckedFrame(context, {
        kind = "action",
        version = 1,
        cursor = "apply",
        state = { combatant = actor.combatant, activation = actor.activation },
      })
      local event = context:emit("acknowledge", cause, {})
      event.actionId = ordinal
      local frames = state.frames --[[@as table<integer, table<string, unknown>>]]
      frames[#frames] = nil
    elseif action.kind == "item" then
      executeItem(state, context, action, ordinal, cause)
    elseif action.kind == "run" then
      executeRun(state, context, action, ordinal, cause)
    else
      error(BattleErrors.invalidState("commit met an unvalidated choice", {}))
    end
  end

  ---@param action table<string, unknown> queued native action under execution
  local function executeAction(action)
    local state = executor:_live()
    local staged = action.actor --[[@as table<string, unknown>]]
    local combatant = BattleState.combatant(state, staged.combatant --[[@as integer]])
    local entry = combatant.active --[[@as table<string, unknown>?]]
    if entry == nil or entry.activation ~= staged.activation then
      -- Knockouts earlier in the round retire later actions: a stale actor
      -- never acts, spends nothing, and draws nothing.
      if action.progress ~= "complete" then
        local queue = state.queue --[[@as table<integer, table<string, unknown>>]]
        ActionQueue.complete(queue, action.id --[[@as integer]])
      end
      return
    end
    executeChoice(state, action, action.selectedOrdinal --[[@as integer]])
    -- Consumed actions mark their actor: later strikes in the same turn
    -- read payback order from this ledger, matching the native
    -- already-acted command. Stale actors never reach this mark.
    -- Acting also clears the actor's own received-hit record, matching
    -- the native end-of-action cleanup: later decisions read only
    -- strikes received since this action.
    if type(state.turnActed) ~= "table" then
      state.turnActed = {}
    end
    local acted = state.turnActed --[[@as table<integer, boolean>]]
    acted[
      staged.combatant --[[@as integer]]
    ] = true
    local received = state.lastHits --[[@as table<integer, unknown>?]]
    if type(received) == "table" then
      received[
        staged.combatant --[[@as integer]]
      ] = nil
    end
    if action.progress ~= "complete" then
      local queue = state.queue --[[@as table<integer, table<string, unknown>>]]
      ActionQueue.complete(queue, action.id --[[@as integer]])
    end
  end

  local function applyResiduals()
    local state = executor:_live()
    local bag = liveEffectBag(state)
    local sample = sampleTimingState(state, speciesFacts)
    local health = sample.health
    local speeds = sample.speeds
    local ceilings = sample.ceilings
    local typeMap = sample.typeMap
    local occupants = sample.occupants
    -- Nightmare watches sleep through these per-pass facts because the
    -- residual context carries no mon records.
    local slept = {} ---@type table<integer, boolean>
    for _, combatantId in
      ipairs(state.combatantOrder --[[@as integer[] ]])
    do
      local combatant = BattleState.combatant(state, combatantId)
      if
        combatant.active ~= nil and asleepOf(combatant.mon --[[@as table<string, unknown>]])
      then
        slept[combatantId] = true
      end
    end
    local stream = state.rng --[[@as table<string, unknown>]]
    assert(type(stream.nextU16) == "function", "native residuals draw from the battle stream")
    -- The per-battler mon phase walks this sampled order: persistent
    -- conditions tick through it below, and the residual owner nests
    -- battle-local instances under it, so both paths share one speed
    -- sequence without spending a second tie draw.
    local turnEntries = {} ---@type table<integer, { id: integer, speed: integer }>
    for combatant, speed in pairs(speeds) do
      turnEntries[#turnEntries + 1] = { id = combatant, speed = speed }
    end
    local turnOrder = {}
    for _, entry in
      ipairs(TurnOrder.orderResiduals(turnEntries, { trickRoom = fieldActive(state, "trickroom") }, stream))
    do
      turnOrder[#turnOrder + 1] = entry.id
    end
    local context = BattleContext.wrap(state)
    -- Persistent conditions tick first in sampled turn order through
    -- the status owner; battle-local instances follow through the
    -- shared finite dispatch over the same health map.
    tickPersistentConditions(state, context, health, turnOrder, ceilings)
    -- The dispatch owner serves the residual view through named
    -- collection and invocation: the view contract is duck-typed, so
    -- the session adapts method calls to plain view functions.
    local dispatchOwner = EffectDispatch.new(
      bag,
      NativeEffectHandlers.handlersFor(
        { maxHp = ceilings, types = typeMap, occupants = occupants, slept = slept },
        "residual"
      )
    )
    local function collectResiduals(_, timing, passContext)
      return dispatchOwner:collect(timing --[[@as string]], passContext --[[@as table<string, unknown>]])
    end
    local function invokeResiduals(_, timing, passContext, budget)
      return dispatchOwner:invoke(
        timing --[[@as string]],
        passContext --[[@as table<string, unknown>]],
        budget --[[@as integer?]]
      )
    end
    local outcome = Residuals.step({ collect = collectResiduals, invoke = invokeResiduals }, {
      speeds = speeds,
      health = health,
      stream = stream,
      turnOrder = turnOrder,
      trickRoom = fieldActive(state, "trickroom"),
      nativeTurn = BattleState.nativeTurn(state),
    })
    for _, event in ipairs(outcome.events) do
      local record = event --[[@as table<string, unknown>]]
      if
        record.kind --[[@as string]]
        ~= "faint"
      then
        context:emit(record.kind --[[@as string]], { kind = record.kind }, copyValue(record))
      end
    end
    -- Innate recovery closes the turn in sampled battler order:
    -- pinch holdings restore and spend, persistent holdings restore,
    -- and every answer lands on the same health map the commit caps.
    -- The bridge stays function-local beside the turn seam's chunk
    -- reference ceiling.
    local Bridge = require("libs.battle.src.gen4.NativePassiveBridge")
    for _, combatantId in ipairs(turnOrder) do
      if health[combatantId] ~= nil and health[combatantId] > 0 then
        local combatant = BattleState.combatant(state, combatantId)
        if combatant.active ~= nil then
          local recovery = Bridge.wrap(state):invoke("residual", combatantId, {
            status = context:statusOf(combatantId),
            weather = activeWeather(state),
          })
          for _, event in ipairs(recovery.events) do
            local record = event --[[@as table<string, unknown>]]
            if type(record.restored) == "number" and record.recovered == true and record.answersPoisonTick ~= true then
              local ceiling = ceilings[combatantId] --[[@as integer]]
              local before = health[combatantId] --[[@as integer]]
              local after = before + record.restored --[[@as integer]]
              if after > ceiling then
                after = ceiling
              end
              health[combatantId] = after
              context:emit("healed", { kind = "residual", key = record.key }, {
                target = combatantId,
                restored = after - before,
              })
            end
            if record.consumed == true then
              context:consumeHeldItem(combatantId)
            end
          end
        end
      end
    end
    -- Residual faint markers stay internal: committing health first lets
    -- faint settlement emit the single canonical faint per knockout.
    -- The pass runs to completion synchronously, so no continuation
    -- survives the turn and capture only ever sees settled state.
    commitTimingHealth(state, health, ceilings)
    sweepExpiredEffects(state)
    sweepFaints(state)
  end

  -- Drains this turn's enriched faint obligations in settlement order:
  -- each fainted entry with a living benched reserve owes one
  -- replacement while faints with no reserve contribute to defeat.
  -- Reserves promise once across same-roster obligations.
  ---@param state table<string, unknown> live battle state under replacement work
  ---@return table<integer, table<string, unknown>> ordered replacement obligations
  local function drainObligations(state)
    local settled = pendingFaintObligations
    pendingFaintObligations = {}
    local obligations = {} ---@type table<integer, table<string, unknown>>
    local claimed = {} ---@type table<integer, boolean>
    for _, fainted in ipairs(settled) do
      local entry = fainted --[[@as table<string, unknown>]]
      local reserves = eligibleReserves(state, entry.participant --[[@as integer]], claimed)
      if #reserves > 0 then
        claimed[reserves[1]] = true
        obligations[#obligations + 1] = fainted
      end
    end
    return obligations
  end

  ---@param state table<string, unknown> live battle state under replacement work
  ---@param obligations table<integer, table<string, unknown>> ordered replacement obligations
  local function buildReplacementBatch(state, obligations)
    local context = BattleContext.wrap(state)
    local counter = state.batchCounter --[[@as integer]] + 1
    state.batchCounter = counter
    local stored = {} ---@type table<integer, table<string, unknown>>
    for _, obligation in ipairs(obligations) do
      stored[#stored + 1] = {
        combatant = obligation.combatant,
        activation = obligation.activation,
        position = obligation.position,
        participant = obligation.participant,
        controller = obligation.controller,
        side = obligation.side,
        internal = obligation.internal,
      }
    end
    state.pending = {
      batch = { id = counter, epoch = counter, requests = {} },
      submitted = {},
      reserved = { replacements = {}, items = {} },
      replacement = { obligations = stored },
    }
    pushCheckedFrame(context, {
      kind = "round",
      version = 1,
      cursor = "awaiting_replies",
      state = { round = state.round },
    })
    local byController = {} ---@type table<string, table<integer, table<string, unknown>>>
    local controllerOrder = {} ---@type string[]
    for _, participantId in
      ipairs(state.participantOrder --[[@as integer[] ]])
    do
      for _, obligation in ipairs(obligations) do
        if obligation.participant == participantId and not obligation.internal then
          local controller = obligation.controller --[[@as string]]
          if byController[controller] == nil then
            byController[controller] = {}
            controllerOrder[#controllerOrder + 1] = controller
          end
          local actors = byController[controller]
          actors[#actors + 1] = { combatant = obligation.combatant, activation = obligation.activation }
        end
      end
    end
    for _, controller in ipairs(controllerOrder) do
      context:requestDecision({
        controller = controller,
        kind = HgssSessionExecutor.DECISION_KIND,
        actors = byController[controller],
        legalChoices = { kinds = { "switch" } },
      })
    end
    state.status = "waiting"
  end

  --- Publishes one reward-owner event through the session stream,
  --- keeping the recipient and award facts on the event itself beside
  --- the payload.
  ---@param state table<string, unknown> live battle state under reward work
  ---@param child RewardChild reward child owning the event
  ---@param event table<string, unknown> reward-owner event under publication
  local function emitRewardEvent(state, child, event)
    local payload = {}
    for key, value in pairs(event) do
      if key ~= "kind" then
        payload[key] = copyValue(value)
      end
    end
    local defeated = child.defeated --[[@as table<string, unknown>]]
    local emitted =
      BattleContext.wrap(state)
        :emit(event.kind --[[@as string]], { kind = "progression", combatant = defeated.combatant }, payload)
    for key, value in pairs(payload) do
      emitted[key] = value
    end
  end

  --- Suspends faint settlement on one move-learning prompt: the
  --- recipient side answers through the decision protocol while
  --- replacement and outcome work waits on the stored obligations.
  ---@param state table<string, unknown> live battle state under reward work
  ---@param child RewardChild reward child owning the prompt
  ---@param request table<string, unknown> learning prompt from the reward owner
  ---@param obligations table<integer, table<string, unknown>> deferred replacement obligations
  local function buildLearningBatch(state, child, request, obligations)
    local context = BattleContext.wrap(state)
    local recipientId = request.combatant --[[@as integer]]
    local recipientFrame = nil
    for _, cursor in ipairs(child.frame.recipients) do
      if cursor.combatant == recipientId then
        recipientFrame = cursor
      end
    end
    assert(recipientFrame ~= nil, "learning prompts address a reward recipient")
    local mon = child.mons[
      recipientFrame.monIndex --[[@as integer]]
    ] --[[@as table<string, unknown>]]
    assert(type(mon) == "table", "learning prompts read the recipient mon")
    local moves = {}
    for _, entry in
      ipairs(mon.moves --[[@as table<integer, table<string, unknown>>]])
    do
      moves[#moves + 1] = { move = entry.move, pp = entry.pp, ppUps = entry.ppUps }
    end
    local combatant = BattleState.combatant(state, recipientId)
    local owner = BattleState.participant(state, combatant.participant --[[@as integer]])
    -- Learning addresses the roster record, never the live entry: the
    -- actor carries its combatant alone with no entry token, whether the
    -- recipient is active or benched, and the reply must match it back
    -- without one.
    local counter = state.batchCounter --[[@as integer]] + 1
    state.batchCounter = counter
    state.pending = {
      batch = { id = counter, epoch = counter, requests = {} },
      submitted = {},
      reserved = { replacements = {}, items = {} },
      learning = { obligations = obligations },
    }
    pushCheckedFrame(context, {
      kind = "round",
      version = 1,
      cursor = "awaiting_replies",
      state = { round = state.round },
    })
    local issued = context:requestDecision({
      controller = owner.controller,
      kind = HgssSessionExecutor.LEARN_DECISION_KIND,
      actors = { { combatant = recipientId } },
      legalChoices = { kinds = { "confirm" } },
    })
    -- The protocol envelope carries only the decision identity; the
    -- learning facts ride the request beside it for the controller.
    issued.incomingMove = request.incomingMove
    issued.currentMoves = moves
    issued.canDecline = true
    state.status = "waiting"
  end

  --- Steps every open reward child in faint order, publishing its events
  --- and synchronizing its battle copies. The first learning prompt
  --- suspends the session with the deferred obligations held aside;
  --- completion returns true with every child done.
  ---@param state table<string, unknown> live battle state under reward work
  ---@param obligations table<integer, table<string, unknown>> deferred replacement obligations
  ---@return boolean true when every reward child is done
  local function drainRewardChildren(state, obligations)
    local children = state.progressionChildren --[[@as table<integer, RewardChild>]]
    assert(type(state.progressionChildren) == "table", "reward children travel as an array")
    for _, child in ipairs(children) do
      if not child.done then
        local flow = { mons = child.mons, catalog = rewardCatalog, evolutionEligible = child.evolutionEligible }
        local result = Progression.step(flow, child.frame --[[@as table<string, unknown>]], nil)
        child.frame = result.frame --[[@as RewardFrame]]
        for _, event in
          ipairs(result.events --[[@as table<integer, table<string, unknown>>]])
        do
          emitRewardEvent(state, child, event)
        end
        syncRewardMons(state, child)
        if result.request ~= nil then
          buildLearningBatch(state, child, result.request --[[@as table<string, unknown>]], obligations)
          return false
        end
        child.done = true
      end
    end
    return true
  end

  --- Finishes the turn once every reward child is done: mandatory
  --- replacements precede the next ordinary action batch, and the
  --- terminal result follows only after every replacement resolves.
  ---@param state table<string, unknown> live battle state under turn close
  ---@param obligations table<integer, table<string, unknown>> ordered replacement obligations
  local function finishTurn(state, obligations)
    local pending = obligations
    local external = 0
    while true do
      external = 0
      for _, obligation in ipairs(pending) do
        if not obligation.internal then
          external = external + 1
        end
      end
      if external > 0 then
        -- Mandatory replacement precedes the next ordinary action batch:
        -- suspend with the replacement batch open instead of sequencing.
        -- The turn frame above already closed; the replacement batch opens
        -- its own below.
        buildReplacementBatch(state, pending)
        return
      end
      local claimed = {} ---@type table<integer, boolean>
      for _, obligation in ipairs(pending) do
        local reserves = eligibleReserves(state, obligation.participant --[[@as integer]], claimed)
        assert(#reserves > 0, "internally resolved replacements keep their reserve")
        claimed[reserves[1]] = true
        enterReserve(state, moneySet, obligation, reserves[1])
        -- The arrival runs its entry pass before it may act: a hazard
        -- faint queues through ordinary faint ownership for the drain below.
        invokeTiming(state, "entry", reserves[1])
      end
      local fresh = drainObligations(state)
      if #fresh == 0 then
        break
      end
      if not drainRewardChildren(state, fresh) then
        return
      end
      state.progressionChildren = {}
      pending = fresh
    end
    settleOutcome(state)
  end

  -- Runs one arrival's entry pass with faint settlement for commit-time
  -- replacement work, which lives outside this turn seam.
  ---@param state table<string, unknown> live battle state under replacement work
  ---@param entrant integer arriving combatant under the entry pass
  local function settleEntryTiming(state, entrant)
    invokeTiming(state, "entry", entrant)
  end

  -- Settles replacements after a commit-time entry pass: hazard faints
  -- queued by the entrant's arrival drain through rewards into mandatory
  -- replacement or the terminal result, exactly like the turn-close tail.
  ---@param state table<string, unknown> live battle state under replacement work
  local function settlePostReplacement(state)
    local obligations = drainObligations(state)
    if not drainRewardChildren(state, obligations) then
      return
    end
    state.progressionChildren = {}
    finishTurn(state, obligations)
  end

  local function closeTurn()
    local state = executor:_live()
    local frames = state.frames --[[@as table<integer, table<string, unknown>>]]
    local roundFrame = frames[#frames]
    assert(roundFrame ~= nil and roundFrame.kind == "round", "commit closes its round frame")
    frames[#frames] = nil
    state.pending = nil
    -- The turn queue drained fully: every staged action completed, so the
    -- next turn stages into a fresh queue instead of reusing identities.
    state.queue = {}
    local obligations = drainObligations(state)
    -- Knockout rewards settle before mandatory replacement or the
    -- terminal result: the first learning prompt suspends the turn here
    -- with the computed obligations held aside.
    if not drainRewardChildren(state, obligations) then
      return
    end
    state.progressionChildren = {}
    finishTurn(state, obligations)
  end

  --- Consumes one stored learning reply, then drains forward: another
  --- prompt suspends again while completion resumes the deferred
  --- replacement and outcome work.
  ---@param state table<string, unknown> live battle state under reward work
  local function commitLearning(state)
    local pending = state.pending --[[@as table<string, unknown>]]
    assert(type(state.pending) == "table" and type(pending.learning) == "table", "learning commits over its own batch")
    local learning = pending.learning --[[@as table<string, unknown>]]
    local obligations = learning.obligations --[[@as table<integer, table<string, unknown>>]]
    local requests = batchRequests(state)
    assert(#requests == 1, "learning batches suspend on one prompt")
    local submitted = pending.submitted --[[@as table<integer, table<string, unknown>>]]
    local reply = submitted[
      requests[1].requestId --[[@as integer]]
    ]
    assert(type(reply) == "table", "learning commits only with its reply stored")
    local choices = reply.choices --[[@as table<integer, table<string, unknown>>]]
    assert(type(reply.choices) == "table" and #choices == 1, "learning replies answer their recipient once")
    local choice = choices[1]
    local payload = choice.payload --[[@as table<string, unknown>]]
    local actor = choice.actor --[[@as table<string, unknown>]]
    local children = state.progressionChildren --[[@as table<integer, RewardChild>]]
    local child = nil
    for _, candidate in ipairs(children) do
      if not candidate.done and candidate.frame.pending ~= nil then
        child = candidate
      end
    end
    assert(child ~= nil, "learning replies consume an open prompt")
    local flow = { mons = child.mons, catalog = rewardCatalog, evolutionEligible = child.evolutionEligible }
    local result = Progression.step(flow, child.frame --[[@as table<string, unknown>]], {
      combatant = actor.combatant,
      decision = payload.decision,
      slot = payload.slot,
    })
    child.frame = result.frame --[[@as RewardFrame]]
    for _, event in
      ipairs(result.events --[[@as table<integer, table<string, unknown>>]])
    do
      emitRewardEvent(state, child, event)
    end
    syncRewardMons(state, child)
    if result.request ~= nil then
      buildLearningBatch(state, child, result.request --[[@as table<string, unknown>]], obligations)
      return
    end
    child.done = true
    if not drainRewardChildren(state, obligations) then
      return
    end
    state.progressionChildren = {}
    local spent = state.pending
    finishTurn(state, obligations)
    if state.pending == spent and state.status == "running" then
      -- Resolving the carried obligations opened no replacement batch
      -- and the battle runs on: drop the spent learning batch so the
      -- advance loop builds the next action batch instead of committing
      -- this one a second time.
      state.pending = nil
    end
  end

  return {
    openTurn = openTurn,
    executeAction = executeAction,
    applyResiduals = applyResiduals,
    closeTurn = closeTurn,
    commitLearning = commitLearning,
    settleEntryTiming = settleEntryTiming,
    settlePostReplacement = settlePostReplacement,
  }
end

---@param validated table<string, unknown> detached validated battle setup under construction
---@return table<string, table<string, unknown>> immutable move facts carried by the session
local function checkMoveFacts(validated)
  if type(validated.moveFacts) ~= "table" then
    error(BattleErrors.missingBehavior("sessions require their immutable move facts", {
      ruleset = tostring(validated.ruleset),
    }))
  end
  return validated.moveFacts --[[@as table<string, table<string, unknown>>]]
end

---@param facts table<string, unknown> immutable item facts under entry validation
---@param raise fun(message: string, context: table<string, unknown>): table<string, unknown> error factory for malformed entries
local function checkItemEntries(facts, raise)
  for key, entry in pairs(facts) do
    if type(key) ~= "string" or key == "" then
      error(raise("session item facts name their item key", {}))
    end
    if type(entry) ~= "table" then
      error(raise("session item facts carry their party use", { item = tostring(key) }))
    end
    local record = entry --[[@as table<string, unknown>]]
    -- Served items plan from their party use; held-only entries carry
    -- throw facts without one and never plan. Held items without throw
    -- facts still project their canonical held behavior for trainer
    -- checks, so a held-behavior record alone is a complete generated
    -- fact family. Either shape carries at least one generated fact
    -- family, and held behavior is never interpreted by planning.
    if
      type(record.partyUse) ~= "table"
      and type(record.naturalGift) ~= "table"
      and type(record.fling) ~= "table"
      and type(record.heldBehavior) ~= "table"
    then
      error(raise("session item facts carry their generated facts", { item = tostring(key) }))
    end
    for field in pairs(record) do
      if
        field ~= "partyUse"
        and field ~= "battleUse"
        and field ~= "naturalGift"
        and field ~= "fling"
        and field ~= "heldBehavior"
        and field ~= "lowHpOnly"
      then
        error(raise("session item facts carry only their generated facts", { item = tostring(key) }))
      end
    end
  end
end

---@param validated table<string, unknown> detached validated battle setup under construction
---@return table<string, table<string, unknown>> immutable item facts carried by the session
local function checkItemFacts(validated)
  local facts = validated.itemFacts
  if facts == nil then
    return {}
  end
  if type(facts) ~= "table" then
    error(BattleErrors.missingBehavior("sessions require their immutable item facts", {
      ruleset = tostring(validated.ruleset),
    }))
  end
  checkItemEntries(facts --[[@as table<string, unknown>]], function(message, context)
    return BattleErrors.missingBehavior(message, context)
  end)
  return facts --[[@as table<string, table<string, unknown>>]]
end

---@param validated table<string, unknown> detached validated battle setup under construction
---@return table<string, SpeciesFormFacts> static species facts carried by the session
local function checkSpeciesFacts(validated)
  if type(validated.speciesFacts) ~= "table" then
    error(BattleErrors.missingBehavior("sessions require their static species facts", {
      ruleset = tostring(validated.ruleset),
    }))
  end
  return validated.speciesFacts --[[@as table<string, SpeciesFormFacts>]]
end

---@param content table<string, unknown> frozen executable battle content
---@param ruleset string native ruleset owning the session chart
---@return table<string, unknown> isolated chart view over the composition type matrix
local function sessionChart(content, ruleset)
  local lookup = content.typeChart
  if type(lookup) ~= "function" then
    error(BattleErrors.missingBehavior("sessions require their session type chart", { ruleset = ruleset }))
  end
  local ok, chart = pcall(lookup, content, ruleset)
  if not ok or type(chart) ~= "table" then
    error(BattleErrors.missingBehavior("sessions require their session type chart", { ruleset = ruleset }))
  end
  return chart --[[@as table<string, unknown>]]
end

---@param live table<string, unknown>
---@param content table<string, unknown>
---@param admitted string[] admitted action kinds resolved at construction
---@param moveFacts table<string, table<string, unknown>> immutable move facts carried by the session
---@param speciesFacts table<string, SpeciesFormFacts> static species facts carried by the session
---@param itemFacts table<string, table<string, unknown>> immutable item facts carried by the session
---@param moneyUpItems string[] held-item keys carrying the money-up effect, in stable order
---@param battleKind string wild-or-trainer encounter policy selecting flight and capture law
---@param seedParticipation boolean true for fresh sessions whose opening field seeds reward records; restored sessions keep their snapshot records untouched
---@return HgssSessionExecutor
local function wrap(
  live,
  content,
  admitted,
  moveFacts,
  speciesFacts,
  itemFacts,
  moneyUpItems,
  battleKind,
  seedParticipation
)
  live.queue = live.queue or {}
  live.schedule = live.schedule or freshSchedule()
  live.faints = live.faints or {}
  -- Knockout-reward continuations travel beside the faint queue: open
  -- reward children with their battle-owned copies, the per-opponent
  -- participation records keyed by enemy entry, and the accumulated
  -- evolution eligibility.
  live.progressionChildren = live.progressionChildren or {}
  live.rewardParticipation = live.rewardParticipation or {}
  live.evolutionEligible = live.evolutionEligible or {}
  -- The live effect owner travels with the state like the running
  -- generator: fresh sessions arrive with their empty owner while restored
  -- sessions carry only the plain captured records, so the owner rebuilds
  -- from those records.
  if type(live.effectBag) ~= "table" or type(live.effectBag.add) ~= "function" then
    live.effectBag = EffectBag.new(live.effects --[[@as table<integer, unknown>?]])
  end
  live.moneyUpItems = copyValue(moneyUpItems or {})
  if live.escapeAttempts == nil then
    live.escapeAttempts = 0
  end
  assert(
    type(live.escapeAttempts) == "number" and live.escapeAttempts --[[@as integer]] % 1 == 0,
    "escape attempts stay counted"
  )
  if live.captures == nil then
    live.captures = {}
  end
  assert(type(live.captures) == "table", "capture results stay ledgered")
  if live.captureSeq == nil then
    live.captureSeq = 0
  end
  assert(
    type(live.captureSeq) == "number" and live.captureSeq --[[@as integer]] % 1 == 0,
    "capture identities stay counted"
  )
  if live.ledger == nil then
    live.ledger = {}
  end
  assert(type(live.ledger) == "table", "bag and throw consumption stays ledgered")
  if live.turnStrikes == nil then
    live.turnStrikes = {}
  end
  if live.turnActed == nil then
    live.turnActed = {}
  end
  if live.usedMoves == nil then
    live.usedMoves = {}
  end
  -- Received-hit history opens empty beside the turn ledgers: an empty
  -- table means never-struck, while only a state predating the record
  -- fails the trainer read closed.
  if live.lastHits == nil then
    live.lastHits = {}
  end
  ensureEntryHealth(live, speciesFacts)
  if live.prizeMoneyValue == nil then
    live.prizeMoneyValue = 1
  elseif live.prizeMoneyValue ~= 1 and live.prizeMoneyValue ~= 2 then
    error(BattleErrors.invalidState("prize multipliers stay 1 or 2", {}))
  end
  local moneySet = {} ---@type table<string, boolean>
  for _, key in ipairs(moneyUpItems or {}) do
    moneySet[
      key --[[@as string]]
    ] = true
  end
  local executor = setmetatable({
    _state = live,
    _content = content,
    _admitted = admitted,
    _battleKind = battleKind,
    _moveFacts = moveFacts,
    _speciesFacts = speciesFacts,
    _itemFacts = itemFacts,
    _chart = sessionChart(content, HgssSessionExecutor.RULESET),
    _moneyUpItems = moneySet,
    _ruleset = nil,
    _trainerProvisional = {},
    _finalized = false,
    _disposed = false,
  }, HgssSessionExecutor)
  -- Opening occupants send out with the battle: scan them before the
  -- first turn so a holder in the starting lineup latches immediately
  -- and every opening foe seeds its participant set from the field.
  for _, positionId in
    ipairs(live.positionOrder --[[@as integer[] ]])
  do
    local occupant = BattleState.position(live, positionId).occupant
    if occupant ~= nil then
      noteEntry(live, moneySet, occupant --[[@as integer]])
      -- Restored sessions keep their snapshot participation records:
      -- reseeding from the mid-battle field would drop credit earned by
      -- entries that already fainted or left, which leaving never erases.
      if seedParticipation then
        noteBattleEntry(live, occupant --[[@as integer]])
      end
    end
  end
  return executor
end

---@param scenarioRecord table<string, unknown> detached serializable battle setup
---@param content table<string, unknown> frozen executable battle content
---@return HgssSessionExecutor
function HgssSessionExecutor.new(scenarioRecord, content)
  assert(type(scenarioRecord) == "table", "session construction requires its scenario record")
  local validated = BattleScenario.validate(scenarioRecord)
  if validated.ruleset ~= HgssSessionExecutor.RULESET then
    error(BattleErrors.missingBehavior("the native session owns only its native ruleset", {
      ruleset = tostring(validated.ruleset),
    }))
  end
  checkContent(content, validated.ruleset --[[@as string]])
  local admitted = admittedKindsFor(validated.format --[[@as string]], content, validated)
  local moveFacts = checkMoveFacts(validated)
  local speciesFacts = checkSpeciesFacts(validated)
  local itemFacts = checkItemFacts(validated)
  local moneyUpItems = checkMoneyUpItems(validated)
  local live = BattleState.create(validated)
  live.rng = BattleRng.new(validated
    .random --[[@as table<string, unknown>]]
    .seed --[[@as integer]])
  local executor = wrap(
    live,
    content --[[@as table<string, unknown>]],
    admitted,
    moveFacts,
    speciesFacts,
    itemFacts,
    moneyUpItems,
    battleKindFor(validated.format --[[@as string]], validated.kind),
    true
  )
  executor:_bindLifecycle()
  -- Fresh sessions open with zeroed trainer memory beside the generic
  -- state before the first decision.
  TrainerAi.initializeMemory(live)
  -- Opening occupants enter with the battle, so their entry turns stamp
  -- here before the first decision exactly like later reserves stamp at
  -- the entry boundary. This runs unconditionally: the effect-timing
  -- pass below may skip an empty bag, but battle facts never skip.
  for _, positionId in
    ipairs(live.positionOrder --[[@as integer[] ]])
  do
    local occupant = BattleState.position(live, positionId --[[@as integer]]).occupant
    if occupant ~= nil then
      TrainerAi.noteArrival(live, occupant --[[@as integer]])
    end
  end
  -- Opening occupants receive their entry pass exactly once through the
  -- same arrival helper as later reserves. Fresh sessions start with an
  -- empty bag, so the pass is skipped until mechanics create instances;
  -- construction never projects combatants it does not dispatch over.
  local openingBag = liveEffectBag(live)
  if #openingBag:capture() > 0 then
    local settleOpening = executor._settleEntryTiming
    assert(type(settleOpening) == "function", "opening entries run through the bound timing seam")
    for _, positionId in
      ipairs(live.positionOrder --[[@as integer[] ]])
    do
      local occupant = BattleState.position(live, positionId --[[@as integer]]).occupant
      if occupant ~= nil then
        settleOpening(live, occupant --[[@as integer]])
      end
    end
  end
  return executor
end

---@param snapshotData unknown interruption capture under validation
---@param content table<string, unknown> frozen executable battle content
---@return HgssSessionExecutor
function HgssSessionExecutor.restore(snapshotData, content)
  local live = BattleSnapshot.restore(snapshotData)
  if live.ruleset ~= HgssSessionExecutor.RULESET then
    error(BattleErrors.incompatibleSnapshot("the native session restores only its native ruleset", {
      ruleset = tostring(live.ruleset),
    }))
  end
  checkContent(content, live.ruleset --[[@as string]])
  local admitted = admittedKindsFor(live.format --[[@as string]], content, nil)
  if type(live.rng) ~= "table" or live.rng.algorithm ~= BattleRng.ALGORITHM then
    error(BattleErrors.incompatibleSnapshot("native snapshots carry the native stream identity", {}))
  end
  live.rng = BattleRng.restore(live.rng --[[@as table<string, integer>]])
  checkRestoredShape(live)
  if live.queue ~= nil and type(live.queue) ~= "table" then
    error(BattleErrors.incompatibleSnapshot("native snapshots carry their queued actions", {}))
  end
  if live.schedule ~= nil then
    local ok = pcall(HgssSchedule.validateFrame, live.schedule)
    if not ok then
      error(BattleErrors.incompatibleSnapshot("native snapshots carry their schedule frame", {}))
    end
  end
  if live.faints ~= nil and type(live.faints) ~= "table" then
    error(BattleErrors.incompatibleSnapshot("native snapshots carry their faint queue", {}))
  end
  if live.progressionChildren ~= nil then
    if type(live.progressionChildren) ~= "table" then
      error(BattleErrors.incompatibleSnapshot("native snapshots carry their reward children", {}))
    end
    for _, child in
      ipairs(live.progressionChildren --[[@as table<integer, unknown>]])
    do
      if type(child) ~= "table" then
        error(BattleErrors.incompatibleSnapshot("reward children must be records", {}))
      end
      local record = child --[[@as table<string, unknown>]]
      local defeated = record.defeated --[[@as table<string, unknown>]]
      if
        type(record.defeated) ~= "table"
        or not isPositiveInt(defeated.combatant)
        or not isPositiveInt(defeated.activation)
      then
        error(BattleErrors.incompatibleSnapshot("reward children must name their defeated entry", {}))
      end
      if type(record.mons) ~= "table" then
        error(BattleErrors.incompatibleSnapshot("reward children must carry their battle-owned copies", {}))
      end
      if record.done ~= true and record.done ~= false then
        error(BattleErrors.incompatibleSnapshot("reward children must mark their completion", {}))
      end
      if type(record.evolutionEligible) ~= "table" then
        error(BattleErrors.incompatibleSnapshot("reward children must carry their eligibility", {}))
      end
      local ok, frameErr = pcall(Progression.validateFrame, record.frame)
      if not ok then
        error(BattleErrors.incompatibleSnapshot("reward children must carry a valid reward frame", {
          detail = tostring(frameErr),
        }))
      end
    end
  end
  if live.participated ~= nil then
    error(BattleErrors.incompatibleSnapshot("native snapshots carry per-opponent reward participation", {}))
  end
  if live.rewardParticipation ~= nil then
    if type(live.rewardParticipation) ~= "table" then
      error(BattleErrors.incompatibleSnapshot("native snapshots carry their reward participation", {}))
    end
    for enemyId, entry in
      pairs(live.rewardParticipation --[[@as table<integer, unknown>]])
    do
      if not isPositiveInt(enemyId) or type(entry) ~= "table" then
        error(BattleErrors.incompatibleSnapshot("reward participation names enemy records", {}))
      end
      local entryRecord = entry --[[@as table<string, unknown>]]
      if not isPositiveInt(entryRecord.activation) or type(entryRecord.combatants) ~= "table" then
        error(BattleErrors.incompatibleSnapshot("reward participation pins the defeated entry", {}))
      end
      for battlerId, marked in
        pairs(entryRecord.combatants --[[@as table<integer, unknown>]])
      do
        if not isPositiveInt(battlerId) or marked ~= true then
          error(BattleErrors.incompatibleSnapshot("reward participation marks sent-out battlers", {}))
        end
      end
    end
  end
  if live.evolutionEligible ~= nil then
    if type(live.evolutionEligible) ~= "table" then
      error(BattleErrors.incompatibleSnapshot("native snapshots carry their evolution eligibility", {}))
    end
    for _, combatantId in
      ipairs(live.evolutionEligible --[[@as table<integer, unknown>]])
    do
      if not isPositiveInt(combatantId) then
        error(BattleErrors.incompatibleSnapshot("evolution eligibility names combatants", {}))
      end
    end
  end
  if type(live.moveFacts) ~= "table" then
    error(BattleErrors.incompatibleSnapshot("native snapshots carry their immutable move facts", {}))
  end
  if type(live.speciesFacts) ~= "table" then
    error(BattleErrors.incompatibleSnapshot("native snapshots carry their static species facts", {}))
  end
  if live.itemFacts == nil then
    live.itemFacts = {}
  end
  if type(live.itemFacts) ~= "table" then
    error(BattleErrors.incompatibleSnapshot("native snapshots carry their immutable item facts", {}))
  end
  checkItemEntries(live.itemFacts --[[@as table<string, unknown>]], function(message, context)
    return BattleErrors.incompatibleSnapshot(message, context)
  end)
  local moneyUpItems = checkMoneyUpItems(live)
  local executor = wrap(
    live,
    content --[[@as table<string, unknown>]],
    admitted,
    live.moveFacts --[[@as table<string, table<string, unknown>>]],
    live.speciesFacts --[[@as table<string, SpeciesFormFacts>]],
    live.itemFacts --[[@as table<string, table<string, unknown>>]],
    moneyUpItems,
    battleKindFor(live.format --[[@as string]], live.kind),
    false
  )
  executor:_bindLifecycle()
  -- Restored sessions require the persisted trainer record and reuse
  -- it untouched; snapshots missing or corrupting it are incompatible
  -- with no migration path.
  if live.trainerAi == nil then
    error(BattleErrors.incompatibleSnapshot("native snapshots carry their trainer record", {}))
  else
    TrainerAi.validateMemory(live.trainerAi --[[@as table<string, unknown>]])
  end
  return executor
end

--- Binds the native lifecycle to this session. Runs exactly once per
--- session object, matching construction and restoration.
function HgssSessionExecutor:_bindLifecycle()
  assert(self._ruleset == nil, "native lifecycles bind once")
  local turnHandlers = bindTurnHandlers(
    self,
    self._moveFacts,
    self._speciesFacts,
    self._itemFacts,
    self._chart,
    self._moneyUpItems,
    self._battleKind
  )
  local ruleset = HgssRuleset.new(turnHandlers)
  -- The learning continuation closes over the same turn seam but is not
  -- a scheduled lifecycle phase, so the executor holds it directly.
  self._commitLearningHandler = turnHandlers.commitLearning
  -- Entry timing and post-replacement settlement close over the same
  -- seam for commit-time replacement work outside the turn handlers.
  self._settleEntryTiming = turnHandlers.settleEntryTiming
  self._settlePostReplacement = turnHandlers.settlePostReplacement
  self._ruleset = ruleset
  ruleset:initialize(self)
end

---@return table<string, unknown> live battle state, failing after disposal
function HgssSessionExecutor:_live()
  if self._disposed or self._state == nil then
    error(BattleErrors.invalidState("disposed sessions publish nothing further", {}))
  end
  return self._state
end

function HgssSessionExecutor:_finalizeOnce()
  if not self._finalized then
    self._finalized = true
    local ruleset = self._ruleset --[[@as table<string, unknown>]]
    if ruleset ~= nil then
      local finalize = ruleset.finalize --[[@as fun(self: table<string, unknown>): boolean]]
      finalize(ruleset)
    end
  end
end

---@param a table<string, unknown>
---@param b table<string, unknown>
---@return boolean true when a commits before b
local function byCommitOrder(a, b)
  local actorA = (a.choice --[[@as table<string, unknown>]]).actor --[[@as table<string, unknown>]]
  local actorB = (b.choice --[[@as table<string, unknown>]]).actor --[[@as table<string, unknown>]]
  local combatA = actorA.combatant --[[@as integer]]
  local combatB = actorB.combatant --[[@as integer]]
  if combatA ~= combatB then
    return combatA < combatB
  end
  local requestA = a.requestId --[[@as integer]]
  local requestB = b.requestId --[[@as integer]]
  return requestA < requestB
end

---@param state table<string, unknown> live battle state under commit
---@param allowance integer? operations the current advance may still spend
function HgssSessionExecutor:_commitBatch(state, allowance)
  local pending = state.pending --[[@as table<string, unknown>]]
  assert(pending.replacement == nil, "replacement batches commit through their own path")
  local submitted = pending.submitted --[[@as table<integer, table<string, unknown>>]]
  local ordered = {}
  for _, request in ipairs(batchRequests(state)) do
    local reply = submitted[
      request.requestId --[[@as integer]]
    ]
    assert(reply ~= nil, "commit runs only over complete batches")
    for _, choice in
      ipairs((reply --[[@as table<string, unknown>]]).choices --[[@as table<integer, unknown>]])
    do
      ordered[#ordered + 1] = {
        choice = choice,
        controller = request.controller,
        requestId = request.requestId,
      }
    end
  end
  table.sort(ordered, byCommitOrder)
  local ruleset = self._ruleset --[[@as HgssRuleset]]
  ruleset:handler("openTurn")(ordered)
  local stepBudget = allowance
  if stepBudget == nil then
    stepBudget = 1024
  end
  local queue = state.queue --[[@as table<integer, table<string, unknown>>]]
  local schedule = state.schedule --[[@as table<string, unknown>]]
  local stream = state.rng --[[@as table<string, unknown>]]
  assert(type(stream.nextU16) == "function", "native turns draw from the battle stream")
  while state.status ~= "ended" do
    local due = ruleset:advanceFrame(queue, schedule, stream, stepBudget)
    if due == nil then
      break
    end
    ruleset:handler("executeAction")(due)
  end
  if state.status == "ended" then
    -- Flight and capture close the battle mid-turn: the round frame
    -- closes here so no residual pass or outcome resettlement can
    -- resurrect the decided result, and queued strikes never land.
    local frames = state.frames --[[@as table<integer, table<string, unknown>>]]
    local roundFrame = frames[#frames]
    assert(roundFrame ~= nil and roundFrame.kind == "round", "early terminals close their round frame")
    frames[#frames] = nil
    state.pending = nil
    state.queue = {}
    return
  end
  ruleset:handler("applyResiduals")()
  ruleset:handler("closeTurn")()
end

---@param state table<string, unknown> live battle state under learning commit
function HgssSessionExecutor:_commitLearning(state)
  local commit = self._commitLearningHandler
  assert(type(commit) == "function", "learning commits after lifecycle binding")
  commit(state)
end

---@param state table<string, unknown> live battle state under replacement commit
function HgssSessionExecutor:_commitReplacement(state)
  local pending = state.pending --[[@as table<string, unknown>]]
  local replacement = pending.replacement --[[@as table<string, unknown>]]
  local obligations = replacement.obligations --[[@as table<integer, table<string, unknown>>]]
  local submitted = pending.submitted --[[@as table<integer, table<string, unknown>>]]
  -- Index externally chosen arrivals by fainted combatant. Replies were
  -- validated on submit and suspension stages no intervening mechanics,
  -- so every open obligation answers exactly once here.
  local picks = {} ---@type table<integer, integer>
  for _, request in ipairs(batchRequests(state)) do
    local reply = submitted[
      request.requestId --[[@as integer]]
    ]
    assert(reply ~= nil, "replacement commits only over complete batches")
    for _, choice in
      ipairs((reply --[[@as table<string, unknown>]]).choices --[[@as table<integer, unknown>]])
    do
      local entry = choice --[[@as table<string, unknown>]]
      local actor = entry.actor --[[@as table<string, unknown>]]
      local payload = entry.payload --[[@as table<string, unknown>]]
      assert(picks[
        actor.combatant --[[@as integer]]
      ] == nil, "replacements answer once per fainted entry")
      picks[
        actor.combatant --[[@as integer]]
      ] = payload.replacement --[[@as integer]]
    end
  end
  local claimed = {} ---@type table<integer, boolean>
  for _, obligation in ipairs(obligations) do
    local reserve ---@type integer
    if obligation.internal then
      local reserves = eligibleReserves(state, obligation.participant --[[@as integer]], claimed)
      assert(#reserves > 0, "held internal replacements keep their reserve")
      reserve = reserves[1]
    else
      local picked = picks[
        obligation.combatant --[[@as integer]]
      ]
      assert(picked ~= nil, "open replacements commit only with every reply stored")
      local live = eligibleReserves(state, obligation.participant --[[@as integer]], claimed)
      local held = false
      for _, candidate in ipairs(live) do
        if candidate == picked then
          held = true
        end
      end
      assert(held, "replacement replies hold their reserve through suspension")
      reserve = picked
    end
    claimed[reserve] = true
    enterReserve(state, self._moneyUpItems, obligation, reserve)
    local settleArrival = self._settleEntryTiming
    assert(type(settleArrival) == "function", "replacement entries run through the bound timing seam")
    settleArrival(state, reserve)
  end
  local frames = state.frames --[[@as table<integer, table<string, unknown>>]]
  local roundFrame = frames[#frames]
  assert(roundFrame ~= nil and roundFrame.kind == "round", "replacement commits its round frame")
  frames[#frames] = nil
  state.pending = nil
  state.queue = {}
  -- An arrival's entry pass banks hazard faints with the faint owner:
  -- drain them through rewards into replacement or the terminal result
  -- instead of settling an outcome over a vacant position. The drain is
  -- unconditional because it is a no-op without queued faints: empty
  -- obligations run no rewards and fall through to the same outcome.
  local settleReplacements = self._settlePostReplacement
  assert(type(settleReplacements) == "function", "hazard faints drain through the bound turn seam")
  settleReplacements(state)
end

--- Canonicalizes one reply actor for equality bookkeeping: roster-scoped
--- prompts omit the entry token, so absence matches absence on both
--- sides of the comparison without ever writing a zero into protocol
--- data. Live-entry batches always carry tokens on both sides.
---@param combatant integer addressed roster identity
---@param activation integer? addressed entry token, when the prompt is entry-scoped
---@return string
local function actorKey(combatant, activation)
  return combatant .. ":" .. (activation or "")
end

---@param state table<string, unknown>
---@param request table<string, unknown>
---@param reply table<string, unknown>
---@return table<string, unknown>? input error, or nil when the reply stores
local function checkReplyContext(state, request, reply)
  local pending = state.pending --[[@as table<string, unknown>]]
  local batch = pending.batch --[[@as table<string, unknown>]]
  if reply.controller ~= request.controller then
    return BattleErrors.input("controllers answer only their own requests", {
      request = request.requestId,
    })
  end
  if reply.epoch ~= batch.epoch then
    return BattleErrors.input("replies must carry their batch epoch", { request = request.requestId })
  end
  local submitted = pending.submitted --[[@as table<integer, table<string, unknown>>]]
  if
    submitted[
      request.requestId --[[@as integer]]
    ] ~= nil
  then
    return BattleErrors.input("duplicate replies cannot answer twice", { request = request.requestId })
  end
  local actors = request.actors --[[@as table<integer, table<string, unknown>>]]
  local choices = reply.choices --[[@as table<integer, table<string, unknown>>]]
  if #choices ~= #actors then
    return BattleErrors.input("replies must answer every addressed actor exactly once", {
      request = request.requestId,
    })
  end
  local expected = {}
  for _, actor in ipairs(actors) do
    expected[
      actorKey(actor.combatant --[[@as integer]], actor.activation --[[@as integer?]])
    ] = actor
  end
  local seen = {}
  for _, choice in ipairs(choices) do
    local actor = choice.actor --[[@as table<string, unknown>]]
    local key = actorKey(actor.combatant --[[@as integer]], actor.activation --[[@as integer?]])
    if expected[key] == nil or seen[key] ~= nil then
      return BattleErrors.input("replies must address exactly the requested entries", {
        request = request.requestId,
      })
    end
    seen[key] = true
  end
  return nil
end

---@param state table<string, unknown>
---@return table<integer, table<string, unknown>> every choice already stored in this batch
local function replyChoices(state)
  local pending = state.pending --[[@as table<string, unknown>]]
  local submitted = pending.submitted --[[@as table<integer, table<string, unknown>>]]
  local out = {}
  for _, reply in pairs(submitted) do
    for _, choice in
      ipairs((reply --[[@as table<string, unknown>]]).choices --[[@as table<integer, unknown>]])
    do
      out[#out + 1] = choice --[[@as table<string, unknown>]]
    end
  end
  return out
end

---@param state table<string, unknown>
---@param replacement table<string, unknown> open replacement continuation
---@param choice table<string, unknown>
---@return table<string, unknown>? input error, or nil when the replacement binds
local function checkReplacementBinding(state, replacement, choice)
  local actor = choice.actor --[[@as table<string, unknown>]]
  local payload = choice.payload --[[@as table<string, unknown>]]
  local obligations = replacement.obligations --[[@as table<integer, table<string, unknown>>]]
  local wanted = nil
  for _, obligation in ipairs(obligations) do
    if
      not obligation.internal
      and obligation.combatant == actor.combatant
      and obligation.activation == actor.activation
    then
      wanted = obligation
    end
  end
  if wanted == nil then
    return BattleErrors.input("replies must address exactly the requested entries", {})
  end
  if choice.kind ~= "switch" then
    return BattleErrors.input("replacements answer with switches", {})
  end
  local reserve = (state.combatants --[[@as table<integer, table<string, unknown>>]])[
    payload.replacement --[[@as integer]]
  ]
  if reserve == nil then
    return BattleErrors.input("replacements must name a declared combatant", {})
  end
  if reserve.participant ~= wanted.participant then
    return BattleErrors.input("replacements must share the actor roster", {})
  end
  if reserve.active ~= nil then
    return BattleErrors.input("replacements must start benched", {})
  end
  if
    reserve.hp --[[@as integer]]
    <= 0
  then
    return BattleErrors.input("replacements must be living", {})
  end
  local pending = state.pending --[[@as table<string, unknown>]]
  local reserved = pending.reserved --[[@as table<string, unknown>]]
  local taken = (reserved.replacements --[[@as table<integer, integer>]])[
    payload.replacement --[[@as integer]]
  ]
  if taken ~= nil then
    return BattleErrors.input("replacements are reserved once per batch", {})
  end
  for _, other in ipairs((replyChoices(state))) do
    if other.kind == "switch" and other.payload.replacement == payload.replacement then
      return BattleErrors.input("replacements are reserved once per batch", {})
    end
  end
  return nil
end

--- Validates one learning reply against the open prompt without
--- touching the reward child: unknown decisions, stray slots, and
--- mismatched actors fail as input errors with the continuation held.
---@param state table<string, unknown> live battle state under reply validation
---@param choice table<string, unknown> learning reply choice under validation
---@return table<string, unknown>? input error, or nil when the reply binds
local function checkLearningBinding(state, choice)
  local child = nil
  local children = state.progressionChildren --[[@as table<integer, RewardChild>]]
  if type(state.progressionChildren) == "table" then
    for _, candidate in ipairs(children) do
      if not candidate.done and candidate.frame.pending ~= nil then
        child = candidate
      end
    end
  end
  if child == nil then
    return BattleErrors.input("learning replies require an open prompt", {})
  end
  local requests = batchRequests(state)
  if #requests ~= 1 then
    return BattleErrors.input("learning batches suspend on one prompt", {})
  end
  local addressed = requests[1].actors --[[@as table<integer, table<string, unknown>>]]
  if type(requests[1].actors) ~= "table" or #addressed ~= 1 then
    return BattleErrors.input("learning prompts address their recipient once", {})
  end
  local actor = choice.actor --[[@as table<string, unknown>]]
  local expected = addressed[1]
  if actor.combatant ~= expected.combatant then
    return BattleErrors.input("replies must address exactly the requested entries", {})
  end
  -- Learning binds the roster record: the reply carries its combatant
  -- alone, and any supplied entry token fails instead of locking the
  -- decision to a live entry that may come and go.
  if actor.activation ~= nil or expected.activation ~= nil then
    return BattleErrors.input("learning replies carry no entry token", {})
  end
  if choice.kind ~= "confirm" then
    return BattleErrors.input("learning replies confirm the prompt", {})
  end
  local payload = choice.payload --[[@as table<string, unknown>]]
  local decision = payload.decision
  if decision ~= "replace" and decision ~= "decline" then
    return BattleErrors.input("learning replies decide replace or decline", {})
  end
  if decision == "decline" then
    return nil
  end
  local slot = payload.slot
  if type(slot) ~= "number" or slot % 1 ~= 0 or slot < 0 then
    return BattleErrors.input("replacements name a zero-based move slot", {})
  end
  local recipient = nil
  for _, cursor in ipairs(child.frame.recipients) do
    if cursor.combatant == actor.combatant then
      recipient = cursor
    end
  end
  if recipient == nil then
    return BattleErrors.input("learning replies address their recipient", {})
  end
  local mon = child.mons[
    recipient.monIndex --[[@as integer]]
  ] --[[@as table<string, unknown>]]
  if type(mon) ~= "table" or type(mon.moves) ~= "table" then
    return BattleErrors.input("learning replies address a held move set", {})
  end
  if
    slot >= #mon.moves --[[@as table<integer, unknown>]]
  then
    return BattleErrors.input("replacements name a held zero-based move slot", {})
  end
  return nil
end

---@param state table<string, unknown>
---@param choice table<string, unknown>
---@param admitted string[] admitted action kinds resolved at construction
---@param battleKind string wild-or-trainer encounter policy selecting flight and capture law
---@return table<string, unknown>? input error, or nil when the choice binds
local function checkChoiceBinding(state, choice, admitted, battleKind)
  local actor = choice.actor --[[@as table<string, unknown>]]
  local payload = choice.payload --[[@as table<string, unknown>]]
  local openBatch = state.pending --[[@as table<string, unknown>]]
  if openBatch ~= nil and openBatch.learning ~= nil then
    -- Learning batches address reward recipients through their prompt:
    -- the live-entry binding below cannot hold, so prompts bind instead.
    return checkLearningBinding(state, choice)
  end
  if openBatch ~= nil and openBatch.replacement ~= nil then
    -- Replacement batches address fainted entries: the live-entry binding
    -- below cannot hold, so obligations bind instead. Stale pre-faint
    -- actions still fail here when they name no open obligation.
    return checkReplacementBinding(state, openBatch.replacement --[[@as table<string, unknown>]], choice)
  end
  local combatant = BattleState.combatant(state, actor.combatant --[[@as integer]])
  local active = combatant.active --[[@as table<string, unknown>]]
  if active == nil or active.activation ~= actor.activation then
    return BattleErrors.input("locked references die with their entry", {
      combatant = actor.combatant,
    })
  end
  if choice.kind == "attack" then
    local target = payload.target --[[@as table<string, unknown>]]
    if target.kind == "position" then
      if
        (state.positions --[[@as table<integer, table<string, unknown>>]])[
          target.position --[[@as integer]]
        ] == nil
      then
        return BattleErrors.input("strikes must name a declared position", {})
      end
    elseif target.kind == "combatant" then
      if
        (state.combatants --[[@as table<integer, table<string, unknown>>]])[
          target.combatant --[[@as integer]]
        ] == nil
      then
        return BattleErrors.input("strikes must name a declared combatant", {})
      end
    elseif target.kind == "side" then
      if
        (state.sides --[[@as table<integer, table<string, unknown>>]])[
          target.side --[[@as integer]]
        ] == nil
      then
        return BattleErrors.input("strikes must name a declared side", {})
      end
    end
  elseif choice.kind == "switch" then
    local replacement = (state.combatants --[[@as table<integer, table<string, unknown>>]])[
      payload.replacement --[[@as integer]]
    ]
    if replacement == nil then
      return BattleErrors.input("replacements must name a declared combatant", {})
    end
    if replacement.participant ~= combatant.participant then
      return BattleErrors.input("replacements must share the actor roster", {})
    end
    if replacement.active ~= nil then
      return BattleErrors.input("replacements must start benched", {})
    end
    local pending = state.pending --[[@as table<string, unknown>]]
    local reserved = pending.reserved --[[@as table<string, unknown>]]
    local taken = (reserved.replacements --[[@as table<integer, integer>]])[
      payload.replacement --[[@as integer]]
    ]
    if taken ~= nil then
      return BattleErrors.input("replacements are reserved once per batch", {})
    end
    for _, other in ipairs((replyChoices(state))) do
      if other.kind == "switch" and other.payload.replacement == payload.replacement then
        return BattleErrors.input("replacements are reserved once per batch", {})
      end
    end
    -- Voluntary exchanges bind through the exchange owner: trapping and
    -- reserves that cannot fight refuse here, before anything moves. An
    -- effective shell slips trapping for the departure, so the flag
    -- travels beside the trap.
    local reserves = eligibleReserves(state, combatant.participant --[[@as integer]], {})
    local heldChoice = combatant.trap
    if heldChoice == nil then
      heldChoice = volatileTrapOf(state, combatant.id --[[@as integer]])
    end
    local verdict = Switching.eligible({
      position = active.position,
      incoming = payload.replacement,
      reason = "voluntary",
      reserves = reserves,
      reserved = siblingReserves(state, payload.replacement --[[@as integer]]),
      fainted = faintedIds(state),
      trap = heldChoice,
      shedShell = NativePassiveBridge.wrap(state):effectiveHeldItem(combatant.id --[[@as integer]]) == "SHED_SHELL",
    })
    if not verdict.ok then
      return BattleErrors.input("the exchange is not eligible", { reason = verdict.reason })
    end
  elseif choice.kind == "item" then
    local participant = BattleState.participant(state, combatant.participant --[[@as integer]])
    if participant.inventoryId == nil then
      return BattleErrors.input("item use requires a declared inventory", {})
    end
    local inventory = (state.inventories --[[@as table<string, table<string, unknown>>]])[
      participant.inventoryId --[[@as string]]
    ]
    if inventory == nil then
      return BattleErrors.input("item use requires a known inventory", {})
    end
    local quantities = inventory.quantities --[[@as table<string, integer>]]
    local stock = quantities[
      payload.item --[[@as string]]
    ] or 0
    local pending = state.pending --[[@as table<string, unknown>]]
    local reserved = pending.reserved --[[@as table<string, unknown>]]
    local held = reserved.items --[[@as table<string, table<string, integer>>]]
    local claimed = 0
    if
      held[
        participant.inventoryId --[[@as string]]
      ] ~= nil
    then
      claimed = held[
        participant.inventoryId --[[@as string]]
      ][
        payload.item --[[@as string]]
      ] or 0
    end
    if stock - claimed < 1 then
      return BattleErrors.input("item use requires reserved stock", { item = payload.item })
    end
    if
      CaptureContext.isBall(payload.item --[[@as string]]) and battleKind ~= "wild"
    then
      return BattleErrors.input("thrown balls refuse trainer battles", {})
    end
    -- Bag choices bind through the item owner: unknown stock, spent
    -- stacks, and holders that are not on the field refuse here with the
    -- stock untouched.
    local holder = payload.target --[[@as table<string, unknown>?]]
    local outstanding = {} ---@type table<integer, table<string, unknown>>
    for _ = 1, claimed do
      outstanding[#outstanding + 1] = { inventoryId = participant.inventoryId, item = payload.item }
    end
    local okChoice, refusal = ItemUse.validateChoice({
      inventoryId = participant.inventoryId,
      item = payload.item,
      target = {
        kind = "combatant",
        combatant = type(holder) == "table" and holder.combatant or nil,
      },
    }, {
      inventories = state.inventories,
      combatants = state.combatants,
      outstanding = outstanding,
    })
    if okChoice == nil then
      local reason = refusal ~= nil and refusal.code or "refused"
      return BattleErrors.input("the battle item choice is refused", { reason = reason })
    end
  elseif choice.kind == "run" then
    local allowed = false
    for _, kind in ipairs(admitted) do
      if kind == "run" then
        allowed = true
      end
    end
    if not allowed then
      return BattleErrors.input("the admitted vocabulary names no flight", {})
    end
    if battleKind ~= "wild" then
      return BattleErrors.input("flight refuses trainer battles", {})
    end
  end
  return nil
end

---@param operationBudget integer? operations this call may spend before yielding
---@return table<string, unknown> battle frame at an atomic boundary
function HgssSessionExecutor:advance(operationBudget)
  local state = self:_live()
  local budget = operationBudget
  if budget == nil then
    budget = 1024
  end
  assert(
    type(budget) == "number" and budget --[[@as integer]] % 1 == 0 and budget --[[@as integer]] >= 1,
    "advance budgets stay positive integers"
  )
  local remaining = budget --[[@as integer]]
  while true do
    if state.status == "ended" then
      self:_finalizeOnce()
      return {
        status = "ended",
        events = drainOutbox(state),
        outcome = copyValue(state.outcome),
      }
    end
    if state.pending == nil then
      if remaining < 1 then
        return { status = "running", events = drainOutbox(state) }
      end
      buildBatch(state, self._admitted)
      remaining = remaining - 1
      if state.pending == nil and state.status == "ended" then
        self:_finalizeOnce()
      end
    elseif batchComplete(state) then
      if remaining < 1 then
        return { status = "running", events = drainOutbox(state) }
      end
      local completed = state.pending --[[@as table<string, unknown>]]
      if completed.replacement ~= nil then
        self:_commitReplacement(state)
      elseif completed.learning ~= nil then
        self:_commitLearning(state)
      else
        self:_commitBatch(state, remaining)
      end
      remaining = remaining - 1
      if state.pending == nil and state.status == "ended" then
        self:_finalizeOnce()
      end
      if state.pending == nil and state.status == "running" then
        -- The commit closed the round; the next batch builds under the same
        -- operation so every positive budget settles at a boundary.
        if remaining < 1 then
          remaining = 1
        end
      end
    else
      return { status = state.status, events = drainOutbox(state), request = openBatchView(state) }
    end
    if state.pending ~= nil and not batchComplete(state) then
      return { status = state.status, events = drainOutbox(state), request = openBatchView(state) }
    end
  end
end

---@param reply table<string, unknown> sealed controller reply
---@return boolean stored
---@return table<string, unknown>? input error when the reply is rejected
function HgssSessionExecutor:submit(reply)
  local state = self:_live()
  if type(reply) ~= "table" or type(reply.requestId) ~= "number" then
    return false, BattleErrors.input("decision replies must name a positive request", {})
  end
  if state.status ~= "waiting" or state.pending == nil then
    return false, BattleErrors.input("replies require an open decision batch", {})
  end
  local wanted = nil
  for _, request in ipairs(batchRequests(state)) do
    if request.requestId == reply.requestId then
      wanted = request
    end
  end
  if wanted == nil then
    return false, BattleErrors.input("replies must answer an open request", {})
  end
  local ok, validated = pcall(BattleProtocol.validateReply, reply, wanted.kind --[[@as string]])
  if not ok then
    return false, validated --[[@as table<string, unknown>]]
  end
  local stored = validated --[[@as table<string, unknown>]]
  local contextError = checkReplyContext(state, wanted, stored)
  if contextError ~= nil then
    return false, contextError
  end
  for _, choice in
    ipairs(stored.choices --[[@as table<integer, table<string, unknown>>]])
  do
    local bindingError = checkChoiceBinding(state, choice, self._admitted, self._battleKind)
    if bindingError ~= nil then
      return false, bindingError
    end
  end
  local pending = state.pending --[[@as table<string, unknown>]]
  local submitted = pending.submitted --[[@as table<integer, table<string, unknown>>]]
  local reserved = pending.reserved --[[@as table<string, unknown>]]
  for _, choice in
    ipairs(stored.choices --[[@as table<integer, table<string, unknown>>]])
  do
    local payload = choice.payload --[[@as table<string, unknown>]]
    if choice.kind == "switch" then
      local taken = reserved.replacements --[[@as table<integer, integer>]]
      taken[
        payload.replacement --[[@as integer]]
      ] = wanted.requestId --[[@as integer]]
    elseif choice.kind == "item" then
      local actor = choice.actor --[[@as table<string, unknown>]]
      local combatant = BattleState.combatant(state, actor.combatant --[[@as integer]])
      local participant = BattleState.participant(state, combatant.participant --[[@as integer]])
      local held = reserved.items --[[@as table<string, table<string, integer>>]]
      local inventoryId = participant.inventoryId --[[@as string]]
      if held[inventoryId] == nil then
        held[inventoryId] = {}
      end
      held[inventoryId][
        payload.item --[[@as string]]
      ] = (
        held[inventoryId][
          payload.item --[[@as string]]
        ] or 0
      ) + 1
    end
  end
  submitted[
    wanted.requestId --[[@as integer]]
  ] = copyValue(stored) --[[@as table<string, unknown>]]
  -- Committed replies retire their pending trainer servings: later
  -- answers decide against executed stock instead of the proposal.
  self._trainerProvisional[
    wanted.requestId --[[@as integer]]
  ] = nil
  return true, nil
end

---@param controller string
---@return table<string, unknown> detached perspective view
function HgssSessionExecutor:view(controller)
  self:_live()
  return BattleView.forController(self, controller)
end

-- Runs one internal opponent decision against the session battle stream.
-- The request must exactly match an open wild/trainer request of the
-- current batch; the callback receives an ephemeral stream proxy that
-- forwards labeled draws to the battle RNG and dies when the callback
-- returns. The lease is synchronous and non-reentrant: a second lease
-- while one is active, a stale or external request, a disposed session,
-- or any proxy use after return raises before drawing. This seam exists
-- only for the application opponent-controller broker; it is not a
-- public random API.
---@param request table<string, unknown> open internal opponent request under verification
---@param callback fun(stream: table<string, unknown>): table<string, unknown> decision work under the lease
---@return table<string, unknown> callback result
function HgssSessionExecutor:withDecisionStream(request, callback)
  local state = self:_live()
  assert(type(request) == "table", "decision leases answer a pending request")
  assert(type(callback) == "function", "decision leases run their callback")
  assert(type(request.controller) == "string" and request.controller ~= "", "decision leases name their controller")
  if self._decisionLease == true then
    error(BattleErrors.invalidState("opponent decision streams never nest", {}))
  end
  if state.status ~= "waiting" or state.pending == nil then
    error(BattleErrors.invalidState("opponent decisions answer an open batch", {}))
  end
  local pending = state.pending --[[@as table<string, unknown>]]
  local batch = pending.batch --[[@as table<string, unknown>]]
  local wanted = nil
  for _, candidate in
    ipairs(batch.requests --[[@as table<integer, table<string, unknown>>]])
  do
    if candidate.requestId == request.requestId and candidate.controller == request.controller then
      wanted = candidate
    end
  end
  if wanted == nil or request.epoch ~= batch.epoch then
    error(BattleErrors.input("decision leases answer only their open request", {
      request = tostring(request.requestId),
    }))
  end
  -- Internal opponent controllers are the wild fighter and the generated
  -- trainer sides; the scenario factory owns those controller names and
  -- every other controller answers through the external reply path.
  local controller = request.controller --[[@as string]]
  local internal = controller == "wild" or controller:sub(1, 8) == "trainer:"
  if not internal then
    error(BattleErrors.input("decision leases never serve external controllers", {
      controller = tostring(request.controller),
    }))
  end
  local rng = state.rng --[[@as table<string, unknown>]]
  if type(rng) ~= "table" or type(rng.nextU16) ~= "function" then
    error(BattleErrors.invalidState("decision leases draw from the battle stream", {}))
  end
  self._decisionLease = true
  local alive = true
  local function leaseNextU16(_, label, cause)
    if not alive then
      error(BattleErrors.invalidState("decision streams die with their callback", {}))
    end
    assert(type(label) == "string" and label ~= "", "labeled draws name their call site")
    assert(type(cause) == "table", "labeled draws carry their semantic cause")
    return (rng --[[@as BattleRng]]):nextU16(label, cause)
  end
  local proxy = { nextU16 = leaseNextU16 }
  local ok, result = pcall(callback, proxy)
  alive = false
  self._decisionLease = false
  if not ok then
    error(result, 0)
  end
  return result --[[@as table<string, unknown>]]
end

--- Records an executed strike in opposing trainer memories. Private
--- lifecycle plumbing keeping the turn closure inside its upvalue
--- budget; behavior lives in the trainer policy owner.
---@param state table<string, unknown> live battle state under observation
---@param userId integer striking combatant under observation
---@param moveKey string executed move identity under observation
function HgssSessionExecutor:_observeTrainerMove(state, userId, moveKey)
  TrainerAi.observeMove(state, userId, moveKey)
end

-- Answers the exact open trainer request from native session state.
-- The request must name a trainer controller and match the current
-- batch exactly like the decision-lease path requires; the native
-- trainer policy then decides synchronously from session state, facts,
-- chart, inventory, topology, and the battle stream, returning an
-- ordinary reply for submission. The lease ends on success and on
-- error before anything propagates. This seam exists only for the
-- application trainer broker; wild opponents keep their own path.
---@param request table<string, unknown> open internal trainer request under verification
---@return table<string, unknown> reply in the shared decision shape
function HgssSessionExecutor:answerTrainer(request)
  assert(type(request) == "table", "trainer answers address a pending request")
  local controller = request.controller
  if type(controller) ~= "string" or controller:sub(1, 8) ~= "trainer:" then
    error(BattleErrors.input("trainer answers address only trainer requests", {
      controller = tostring(request.controller),
    }))
  end
  local state = self:_live()
  local authorities = {
    chart = self._chart,
    moveFacts = self._moveFacts,
    speciesFacts = self._speciesFacts,
    itemFacts = self._itemFacts,
  }
  -- Same-request servings accumulate in executor-owned pending-reply
  -- state: answering twice without submitting never serves one slot
  -- twice, while capture and restore observe only committed memory.
  -- The map is entered inside the lease so rejected requests fail
  -- before any bookkeeping exists.
  return self:withDecisionStream(request, function(stream)
    local taken = self._trainerProvisional[
      request.requestId --[[@as integer]]
    ]
    if type(taken) ~= "table" then
      taken = {}
      self._trainerProvisional[
        request.requestId --[[@as integer]]
      ] = taken
    end
    return TrainerAi.answer(state, authorities, request, stream, taken)
  end)
end

----@return table<string, unknown> detached plain interruption capture
function HgssSessionExecutor:capture()
  local state = self:_live()
  local snapshot = BattleSnapshot.capture(state)
  snapshot.queue = copyValue(state.queue)
  snapshot.schedule = copyValue(state.schedule)
  snapshot.faints = copyValue(state.faints)
  -- Reward continuations ride as plain frame plus semantic facts: the
  -- detached battle-owned copies with their resumable frames, the
  -- per-opponent participation records, and the accumulated eligibility. The
  -- reward catalog itself is rebuilt from the facts above on restore and
  -- never serialized.
  snapshot.progressionChildren = copyValue(state.progressionChildren)
  snapshot.rewardParticipation = copyValue(state.rewardParticipation)
  snapshot.evolutionEligible = copyValue(state.evolutionEligible)
  snapshot.moveFacts = copyValue(self._moveFacts)
  snapshot.speciesFacts = copyValue(self._speciesFacts)
  snapshot.itemFacts = copyValue(self._itemFacts)
  snapshot.moneyUpItems = copyValue(state.moneyUpItems or {})
  -- Trainer knowledge and slot order ride as a detached plain record
  -- beside the other native extensions; generic snapshot code never
  -- interprets it.
  snapshot.trainerAi = copyValue(state.trainerAi)
  local prizeMoneyValue = state.prizeMoneyValue
  if prizeMoneyValue ~= 1 and prizeMoneyValue ~= 2 then
    error(BattleErrors.invalidState("prize multipliers stay 1 or 2", {}))
  end
  snapshot.prizeMoneyValue = prizeMoneyValue
  -- Scattered pay day coins ride the snapshot like the prize
  -- multiplier so interruption never loses the running total.
  local scattered = state.paydayScattered or 0
  assert(type(scattered) == "number" and scattered % 1 == 0 and scattered >= 0, "scattered coins stay counted")
  snapshot.paydayScattered = scattered
  BattleSnapshot.validate(snapshot)
  return snapshot
end

function HgssSessionExecutor:dispose()
  if self._disposed then
    return
  end
  self:_finalizeOnce()
  self._disposed = true
  self._state = nil
  self._content = nil
  self._ruleset = nil
end

return HgssSessionExecutor
