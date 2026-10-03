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
-- explicitly instead of guessing; residual
-- instances are collected from live effect state once mechanics create that
-- state, so the end-of-turn pass settles empty today. Eligible knockouts pay
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
local TurnOrder = require("libs.battle.src.gen4.TurnOrder")

---@alias SpeciesFormFacts table<integer, table<string, unknown>>

---@class HgssSessionExecutor
---@field private _state table<string, unknown>?
---@field private _content table<string, unknown>?
---@field private _admitted string[]
---@field private _battleKind string
---@field private _moveFacts table<string, table<string, unknown>>
---@field private _speciesFacts table<string, SpeciesFormFacts>
---@field private _chart table<string, unknown>
---@field private _moneyUpItems table<string, boolean>
---@field private _ruleset table<string, unknown>?
---@field private _commitLearningHandler fun(state: table<string, unknown>)?
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

---@param combatant table<string, unknown> live combatant under fact sampling
---@param speciesFacts table<string, SpeciesFormFacts> static species facts by species and form
---@return table<string, integer> live level and stage-effective battle stats for the entry
local function projectCombatant(combatant, speciesFacts)
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
  -- Battle maximum health travels with the projection so recovery
  -- handlers heal fractions of the true ceiling instead of guessing;
  -- it sits above the entry value whenever the entry arrived wounded.
  local ceiling = combatant.maxHp
  if type(ceiling) ~= "number" then
    ceiling = combatant.entryHp
  end
  stats.maxHp = ceiling --[[@as integer]]
  local stages = combatStages(combatant)
  for _, key in ipairs(STAGED_STATS) do
    stats[key] = StatStages.effective(stats[key] --[[@as integer]], stages[key] --[[@as integer]], key)
  end
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
      local ok, stats = pcall(projectCombatant, combatant, speciesFacts)
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
  local runner = projectCombatant(combatant, speciesFacts).speed
  local runnerOwner = BattleState.participant(state, combatant.participant --[[@as integer]])
  for _, combatantId in
    ipairs(state.combatantOrder --[[@as integer[] ]])
  do
    local other = BattleState.combatant(state, combatantId)
    if other.active ~= nil then
      local owner = BattleState.participant(state, other.participant --[[@as integer]])
      if owner.side ~= runnerOwner.side then
        return runner, projectCombatant(other, speciesFacts).speed
      end
    end
  end
  error(BattleErrors.invalidState("flight reads its opposing entry", {}))
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

---@param attacker table<string, integer> live attacker level and battle stats
---@param defender table<string, integer> live defender level and battle stats
---@param category unknown executing move category selecting the stat pair
---@param moveName string executing move identity under the error context
---@return table<string, integer> move-frame combat facts for the staged arithmetic
local function combatPair(attacker, defender, category, moveName)
  if type(category) ~= "string" then
    error(BattleErrors.missingBehavior("damage reads its move category", { key = moveName }))
  end
  -- Special strikes stage through the special pair; every other category
  -- stages through the physical pair. Non-damaging categories never reach
  -- the staged arithmetic, so their inert pair is real but unread.
  if category == "special" then
    return { level = attacker.level, attack = attacker.specialAttack, defense = defender.specialDefense }
  end
  return { level = attacker.level, attack = attacker.attack, defense = defender.defense }
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

---@param state table<string, unknown> live battle state under the pass
---@return table<string, unknown> live scoped-instance owner held by the state
local function liveEffectBag(state)
  local bag = state.effectBag
  if type(bag) ~= "table" or type(bag.add) ~= "function" then
    error(BattleErrors.invalidState("the native session owns its live effect bag", {}))
  end
  return bag --[[@as table<string, unknown>]]
end

-- Ticks persistent poison, burn, and toxic through the same health map
-- the dispatch pass consumes, in sampled Speed order with combatant
-- identity breaking ties. Poison and burn drain one eighth of maximum
-- health; toxic increments its owned counter first (capped at the
-- native fifteen) and drains one sixteenth per counter point. Every
-- tick floors at a minimum of one. Sleep, freeze, and paralysis carry
-- no residual damage; their law lives at the before-action gate.
---@param state table<string, unknown> live battle state under the pass
---@param context table<string, unknown> validated mechanics context under the pass
---@param health table<integer, integer> battle-local health under the pass
---@param speeds table<integer, integer> sampled effective Speed per combatant
---@param ceilings table<integer, integer> battle maximum health per combatant
local function tickPersistentConditions(state, context, health, speeds, ceilings)
  local order = {}
  for combatantId in pairs(health) do
    order[#order + 1] = combatantId
  end
  table.sort(order, function(left, right)
    local leftSpeed = speeds[left] or 0
    local rightSpeed = speeds[right] or 0
    if leftSpeed ~= rightSpeed then
      return leftSpeed > rightSpeed
    end
    return left < right
  end)
  local typed = context --[[@as BattleContext]]
  for _, combatantId in ipairs(order) do
    if health[combatantId] > 0 then
      local combatant = BattleState.combatant(state, combatantId)
      local mon = combatant.mon --[[@as table<string, unknown>]]
      local effects = (mon.condition --[[@as table<string, unknown>]]).effects
      local current = (effects --[[@as table<integer, table<string, unknown>>]])[1]
      if current ~= nil then
        local key = current.key --[[@as string]]
        if key == "poison" or key == "burn" then
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
  -- Taking the field marks knockout-reward participation: switched-in
  -- reserves earn even when they never strike.
  local arrivals = state.participated --[[@as table<integer, boolean>]]
  if type(state.participated) == "table" then
    arrivals[reserveId] = true
  end
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
      local seen = state.participated --[[@as table<integer, boolean>]]
      battlers[#battlers + 1] = {
        combatant = combatantId,
        participated = type(seen) == "table" and seen[combatantId] == true,
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
  local battlerCount, holderCount = 0, 0
  for _, recipient in ipairs(selected) do
    if recipient.kind == "battler" then
      battlerCount = battlerCount + 1
    else
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
    entries[#entries + 1] = {
      combatant = recipient.combatant,
      mon = entryMon,
      expAward = RewardExperience.calculate(knockout, {
        kind = recipient.kind,
        battlers = battlerCount,
        holders = holderCount,
        luckyEgg = entryMon.heldItem == "LUCKY_EGG",
      }),
      evAward = RewardEffort.calculate(evYield, {}),
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

---@param executor HgssSessionExecutor live native session owning the turn
---@param moveFacts table<string, table<string, unknown>> immutable move facts carried by the session
---@param speciesFacts table<string, SpeciesFormFacts> static species facts carried by the session
---@param chart table<string, unknown> session chart view resolving directed effectiveness
---@param moneySet table<string, boolean> held-item keys carrying the money-up effect
---@param battleKind string wild-or-trainer encounter policy selecting flight and capture law
---@return NativeTurnHandlers lifecycle handlers bound to the session
local function bindTurnHandlers(executor, moveFacts, speciesFacts, chart, moneySet, battleKind)
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
    local stream = state.rng --[[@as table<string, unknown>]]
    assert(type(stream.nextU16) == "function", "native turns draw ties from the battle stream")
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
      candidates[#candidates + 1] = {
        id = ordinal,
        actor = { combatant = actor.combatant, activation = actor.activation },
        kind = kind,
        payload = copyValue(choice.payload),
        selectedOrdinal = ordinal,
        priority = priority,
        speed = projectCombatant(combatant, speciesFacts).speed,
      }
      entry.ordinal = ordinal
    end
    local ordered = TurnOrder.buildActions(candidates, { trickRoom = false }, stream)
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

  ---@param state table<string, unknown> live battle state under execution
  ---@param action table<string, unknown> queued native action under execution
  ---@param ordinal integer commit order of this action
  local function executeAttack(state, action, ordinal)
    local context = BattleContext.wrap(state)
    local stream = state.rng --[[@as table<string, unknown>]]
    assert(type(stream.nextU16) == "function", "native strikes draw from the battle stream")
    local actor = action.actor --[[@as table<string, unknown>]]
    local combatant = BattleState.combatant(state, actor.combatant --[[@as integer]])
    -- Persistent status gates every strike at the before-action
    -- checkpoint: blocked actions never start, spend nothing, and draw
    -- nothing beyond the gate's own labeled roll. Switching and item
    -- use bypass the gate, so only the attack branch funnels here.
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
    local payload = action.payload --[[@as table<string, unknown>]]
    local moveName, ownerSlot = resolveMove(combatant.mon, payload.moveSlot)
    local defenderId =
      resolveTarget(state, actor.combatant --[[@as integer]], payload.target --[[@as table<string, unknown>]])
    if defenderId == nil then
      return
    end
    local defender = BattleState.combatant(state, defenderId)
    local moveRecord = moveFacts[moveName]
    local category = type(moveRecord) == "table" and (moveRecord --[[@as table<string, unknown>]]).category or nil
    local facts = combatPair(
      projectCombatant(combatant, speciesFacts),
      projectCombatant(defender, speciesFacts),
      category,
      moveName
    )
    local defenderTypes = {} ---@type table<integer, string[]>
    defenderTypes[defenderId] = combatantTypes(defender, speciesFacts)
    local moves = combatant
      .mon --[[@as table<string, unknown>]]
      .moves
    if type(moves) ~= "table" then
      moves = {}
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
      attackerTypes = combatantTypes(combatant, speciesFacts),
      defenderTypes = defenderTypes,
      typeChart = chart,
      stream = stream,
    }
    local node = MoveExecution.start(inputs)
    local emittedThrough = #state.outbox --[[@as table<integer, table<string, unknown>>]]
    while true do
      node = MoveExecution.step(context, node)
      if type(node) == "table" and node.kind == "complete" and node.frame == nil then
        break
      end
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
    local verdict = Switching.eligible({
      position = slot,
      incoming = payload.replacement,
      reason = "voluntary",
      reserves = reserves,
      reserved = reserved,
      fainted = fainted,
      trap = combatant.trap,
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
      trap = combatant.trap,
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
    -- Voluntary arrivals join the reward participation set, so a reserve
    -- taking the field before the knockout still counts as a recipient.
    local volunteers = state.participated --[[@as table<integer, boolean>]]
    if type(state.participated) == "table" then
      volunteers[
        payload.replacement --[[@as integer]]
      ] = true
    end
    local event = context:emit("switch", cause, {
      position = slot,
      from = actor.combatant,
      to = payload.replacement,
    })
    event.actionId = ordinal
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
    -- here classifies without double-counting the sealed promise.
    local plan = ItemUse.plan(choice, {
      inventories = state.inventories,
      combatants = state.combatants,
      outstanding = {},
    })
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
    ItemUse.execute(plan, state, state.rng --[[@as table<string, unknown>]])
    local event = context:emit("item", cause, { item = payload.item, inventory = inventoryId })
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
    local result = Escape.attempt({
      battleKind = battleKind,
      trapped = combatant.trap,
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
    if action.progress ~= "complete" then
      local queue = state.queue --[[@as table<integer, table<string, unknown>>]]
      ActionQueue.complete(queue, action.id --[[@as integer]])
    end
  end

  local function applyResiduals()
    local state = executor:_live()
    local bag = liveEffectBag(state)
    local health = {} ---@type table<integer, integer>
    local speeds = {} ---@type table<integer, integer>
    local ceilings = {} ---@type table<integer, integer>
    local typeMap = {} ---@type table<integer, string[]>
    local occupants = {} ---@type table<integer, integer>
    for _, combatantId in
      ipairs(state.combatantOrder --[[@as integer[] ]])
    do
      local combatant = BattleState.combatant(state, combatantId)
      if combatant.active ~= nil then
        health[combatantId] = combatant.hp --[[@as integer]]
        speeds[combatantId] = projectCombatant(combatant, speciesFacts).speed
        -- Residual fractions scale to battle maximum health, which sits
        -- above the entry value whenever the entry arrived wounded.
        local ceiling = combatant.maxHp
        if type(ceiling) ~= "number" then
          ceiling = combatant.entryHp
        end
        ceilings[combatantId] = ceiling --[[@as integer]]
        typeMap[combatantId] = combatantTypes(combatant, speciesFacts)
        local active = combatant.active --[[@as table<string, unknown>]]
        occupants[
          active.position --[[@as integer]]
        ] = combatantId
      end
    end
    local stream = state.rng --[[@as table<string, unknown>]]
    assert(type(stream.nextU16) == "function", "native residuals draw from the battle stream")
    local context = BattleContext.wrap(state)
    -- Persistent conditions tick first in sampled Speed order through
    -- the status owner; battle-local instances follow through the
    -- shared finite dispatch over the same health map.
    tickPersistentConditions(state, context, health, speeds, ceilings)
    -- The dispatch owner serves the residual view through named
    -- collection and invocation: the view contract is duck-typed, so
    -- the session adapts method calls to plain view functions.
    local dispatchOwner = EffectDispatch.new(
      bag,
      NativeEffectHandlers.handlersFor({ maxHp = ceilings, types = typeMap, occupants = occupants })
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
    -- Residual faint markers stay internal: committing health first lets
    -- faint settlement emit the single canonical faint per knockout.
    for combatantId, hp in pairs(health) do
      local combatant = BattleState.combatant(state, combatantId)
      local settled = hp --[[@as integer]]
      if settled < 0 then
        settled = 0
      end
      -- The commit never heals past the residual ceiling, so bag and
      -- move recovery earned earlier in the turn survives the pass.
      local ceiling = ceilings[combatantId] --[[@as integer]]
      if settled > ceiling then
        settled = ceiling
      end
      combatant.hp = settled
    end
    -- Expired countdowns leave after their final tick; the zero turn
    -- already fired, so the sweep never drops a pending effect early.
    -- The pass runs to completion synchronously, so no continuation
    -- survives the turn and capture only ever sees settled state.
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
    -- Address the live entry token; benched earners carry no token, so
    -- the stored zero still binds their reply exactly once.
    local token = 0
    if combatant.active ~= nil then
      local active = combatant.active --[[@as table<string, unknown>]]
      token = active.activation --[[@as integer]]
    end
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
      actors = { { combatant = recipientId, activation = token } },
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
    local external = 0
    for _, obligation in ipairs(obligations) do
      if not obligation.internal then
        external = external + 1
      end
    end
    if external > 0 then
      -- Mandatory replacement precedes the next ordinary action batch:
      -- suspend with the replacement batch open instead of sequencing.
      -- The turn frame above already closed; the replacement batch opens
      -- its own below.
      buildReplacementBatch(state, obligations)
      return
    end
    local claimed = {} ---@type table<integer, boolean>
    for _, obligation in ipairs(obligations) do
      local reserves = eligibleReserves(state, obligation.participant --[[@as integer]], claimed)
      assert(#reserves > 0, "internally resolved replacements keep their reserve")
      claimed[reserves[1]] = true
      enterReserve(state, moneySet, obligation, reserves[1])
    end
    settleOutcome(state)
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
---@param moneyUpItems string[] held-item keys carrying the money-up effect, in stable order
---@param battleKind string wild-or-trainer encounter policy selecting flight and capture law
---@return HgssSessionExecutor
local function wrap(live, content, admitted, moveFacts, speciesFacts, moneyUpItems, battleKind)
  live.queue = live.queue or {}
  live.schedule = live.schedule or freshSchedule()
  live.faints = live.faints or {}
  -- Knockout-reward continuations travel beside the faint queue: open
  -- reward children with their battle-owned copies, the send-out set
  -- backing participation, and the accumulated evolution eligibility.
  live.progressionChildren = live.progressionChildren or {}
  live.participated = live.participated or {}
  live.evolutionEligible = live.evolutionEligible or {}
  -- The live effect owner travels with the state like the running
  -- generator: fresh sessions start empty while restored sessions
  -- rebuild their owner from the captured plain records.
  if type(live.effectBag) ~= "table" or type(live.effectBag.add) ~= "function" then
    live.effectBag = EffectBag.new(live.effectBag --[[@as table<integer, unknown>?]])
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
    _chart = sessionChart(content, HgssSessionExecutor.RULESET),
    _moneyUpItems = moneySet,
    _ruleset = nil,
    _finalized = false,
    _disposed = false,
  }, HgssSessionExecutor)
  -- Opening occupants send out with the battle: scan them before the
  -- first turn so a holder in the starting lineup latches immediately.
  for _, positionId in
    ipairs(live.positionOrder --[[@as integer[] ]])
  do
    local occupant = BattleState.position(live, positionId).occupant
    if occupant ~= nil then
      noteEntry(live, moneySet, occupant --[[@as integer]])
      local arrivals = live.participated --[[@as table<integer, boolean>]]
      if type(live.participated) == "table" then
        arrivals[
          occupant --[[@as integer]]
        ] = true
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
    moneyUpItems,
    battleKindFor(validated.format --[[@as string]], validated.kind)
  )
  executor:_bindLifecycle()
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
  if live.participated ~= nil and type(live.participated) ~= "table" then
    error(BattleErrors.incompatibleSnapshot("native snapshots carry their participation set", {}))
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
  local moneyUpItems = checkMoneyUpItems(live)
  local executor = wrap(
    live,
    content --[[@as table<string, unknown>]],
    admitted,
    live.moveFacts --[[@as table<string, table<string, unknown>>]],
    live.speciesFacts --[[@as table<string, SpeciesFormFacts>]],
    moneyUpItems,
    battleKindFor(live.format --[[@as string]], live.kind)
  )
  executor:_bindLifecycle()
  return executor
end

--- Binds the native lifecycle to this session. Runs exactly once per
--- session object, matching construction and restoration.
function HgssSessionExecutor:_bindLifecycle()
  assert(self._ruleset == nil, "native lifecycles bind once")
  local turnHandlers =
    bindTurnHandlers(self, self._moveFacts, self._speciesFacts, self._chart, self._moneyUpItems, self._battleKind)
  local ruleset = HgssRuleset.new(turnHandlers)
  -- The learning continuation closes over the same turn seam but is not
  -- a scheduled lifecycle phase, so the executor holds it directly.
  self._commitLearningHandler = turnHandlers.commitLearning
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
  end
  local frames = state.frames --[[@as table<integer, table<string, unknown>>]]
  local roundFrame = frames[#frames]
  assert(roundFrame ~= nil and roundFrame.kind == "round", "replacement commits its round frame")
  frames[#frames] = nil
  state.pending = nil
  state.queue = {}
  settleOutcome(state)
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
      actor.combatant --[[@as integer]] .. ":" .. actor.activation --[[@as integer]]
    ] = actor
  end
  local seen = {}
  for _, choice in ipairs(choices) do
    local actor = choice.actor --[[@as table<string, unknown>]]
    local key = actor.combatant --[[@as integer]]
      .. ":"
      .. (
        actor.activation --[[@as integer]]
        or 0
      )
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
  if actor.combatant ~= expected.combatant or actor.activation ~= expected.activation then
    return BattleErrors.input("replies must address exactly the requested entries", {})
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
    -- reserves that cannot fight refuse here, before anything moves.
    local reserves = eligibleReserves(state, combatant.participant --[[@as integer]], {})
    local verdict = Switching.eligible({
      position = active.position,
      incoming = payload.replacement,
      reason = "voluntary",
      reserves = reserves,
      reserved = siblingReserves(state, payload.replacement --[[@as integer]]),
      fainted = faintedIds(state),
      trap = combatant.trap,
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
  return true, nil
end

---@param controller string
---@return table<string, unknown> detached perspective view
function HgssSessionExecutor:view(controller)
  self:_live()
  return BattleView.forController(self, controller)
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
  -- send-out participation set, and the accumulated eligibility. The
  -- reward catalog itself is rebuilt from the facts above on restore and
  -- never serialized.
  snapshot.progressionChildren = copyValue(state.progressionChildren)
  snapshot.participated = copyValue(state.participated)
  snapshot.evolutionEligible = copyValue(state.evolutionEligible)
  snapshot.moveFacts = copyValue(self._moveFacts)
  snapshot.speciesFacts = copyValue(self._speciesFacts)
  snapshot.moneyUpItems = copyValue(state.moneyUpItems or {})
  local prizeMoneyValue = state.prizeMoneyValue
  if prizeMoneyValue ~= 1 and prizeMoneyValue ~= 2 then
    error(BattleErrors.invalidState("prize multipliers stay 1 or 2", {}))
  end
  snapshot.prizeMoneyValue = prizeMoneyValue
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
