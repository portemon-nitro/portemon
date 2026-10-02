-- Private native battle lifetime for the HGSS ruleset. This session speaks
-- the shared battle protocol (decision batches, sealed replies, detached
-- views, plain-data snapshots, exactly-once disposal) while every committed
-- choice runs through the native turn owners instead of the generic
-- one-point strike: submitted batches become ordered native actions, strikes
-- execute through the shared move continuation with the combatant facts the
-- records carry and the immutable move facts the session carries, knockouts
-- settle through the faint owner, and each turn
-- closes through the residual and outcome owners. Choices the records
-- cannot back (no usable move entry) execute the explicit struggle action
-- rather than guessing. Live combat projections derive at execution time
-- from the session species facts through the mon domain owners; stage
-- modifiers stay unmodeled. Facts the records cannot back stay absent
-- from the move frames, so executions needing them fail explicitly instead
-- of guessing; residual
-- instances are collected from live effect state once mechanics create that
-- state, so the end-of-turn pass settles empty today. Fainted combatants
-- leave the field and never act again; sides fight short-handed until the
-- round bound or an empty field settles the outcome, matching the generic
-- terminal words the application already maps.

local ActionQueue = require("libs.battle.src.gen4.ActionQueue")
local BattleContext = require("libs.battle.src.BattleContext")
local BattleErrors = require("libs.battle.src.errors")
local BattleProtocol = require("libs.battle.src.BattleProtocol")
local BattleRng = require("libs.battle.src.gen4.BattleRng")
local BattleScenario = require("libs.battle.src.BattleScenario")
local BattleSnapshot = require("libs.battle.src.BattleSnapshot")
local BattleState = require("libs.battle.src.BattleState")
local BattleView = require("libs.battle.src.BattleView")
local Experience = require("libs.mons.src.gen4.Experience")
local Fainting = require("libs.battle.src.gen4.Fainting")
local HgssRuleset = require("libs.battle.src.gen4.HgssRuleset")
local HgssSchedule = require("libs.battle.src.gen4.HgssSchedule")
local MoveExecution = require("libs.battle.src.gen4.MoveExecution")
local NativeFormats = require("libs.battle.src.gen4.formats.NativeFormats")
local Personality = require("libs.mons.src.gen4.Personality")
local Residuals = require("libs.battle.src.gen4.Residuals")
local Stats = require("libs.mons.src.gen4.Stats")
local TurnOrder = require("libs.battle.src.gen4.TurnOrder")

---@alias SpeciesFormFacts table<integer, table<string, unknown>>

---@class HgssSessionExecutor
---@field private _state table<string, unknown>?
---@field private _content table<string, unknown>?
---@field private _admitted string[]
---@field private _moveFacts table<string, table<string, unknown>>
---@field private _speciesFacts table<string, SpeciesFormFacts>
---@field private _ruleset table<string, unknown>?
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

-- Action brackets for turn ordering. Strikes run on the neutral bracket;
-- move-specific priority stays unmodeled, so every strike shares one
-- bracket and stream-drawn ties decide. Exchanges and item use run on the
-- source escape bracket, ahead of any strike. Prompts carry no battlefield
-- effect and share the neutral bracket.
local STRIKE_BRACKET = 0
local ESCAPE_BRACKET = 6

-- Sampled speed while combatant stat projection stays unthreaded: every
-- action shares one neutral speed, so same-bracket pairs always resolve
-- through battle-stream ties in selection order. Deterministic for a fixed
-- seed; speed-accurate ordering arrives with real combatant facts.
local NEUTRAL_SPEED = 0

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
        return copyValue(HgssSessionExecutor.DEFAULT_ACTION_KINDS) --[[@as string[] ]]
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
      return copyValue(HgssSessionExecutor.DEFAULT_ACTION_KINDS) --[[@as string[] ]]
    end
    return copyKinds(kinds)
  end
  error(BattleErrors.missingBehavior("unknown battle format " .. formatKey, { format = formatKey }))
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

---@param mon unknown battle-local mon record under fact sampling
---@param speciesFacts table<string, SpeciesFormFacts> static species facts by species and form
---@return table<string, integer> live level and battle stats for the record
local function projectCombatant(mon, speciesFacts)
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
  return stats
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
---@return integer sampled priority bracket for the action
local function bracketFor(kind)
  if kind == "switch" or kind == "item" then
    return ESCAPE_BRACKET
  end
  return STRIKE_BRACKET
end

---@class NativeTurnHandlers
---@field openTurn fun(choices: table<integer, table<string, unknown>>)
---@field executeAction fun(action: table<string, unknown>)
---@field applyResiduals fun()
---@field closeTurn fun()

---@param executor HgssSessionExecutor live native session owning the turn
---@param moveFacts table<string, table<string, unknown>> immutable move facts carried by the session
---@param speciesFacts table<string, SpeciesFormFacts> static species facts carried by the session
---@return NativeTurnHandlers lifecycle handlers bound to the session
local function bindTurnHandlers(executor, moveFacts, speciesFacts)
  ---@param choices table<integer, table<string, unknown>> committed choices in commit order
  local function openTurn(choices)
    local state = executor:_live()
    local stream = state.rng --[[@as table<string, unknown>]]
    assert(type(stream.nextU16) == "function", "native turns draw ties from the battle stream")
    local candidates = {} ---@type table<integer, table<string, unknown>>
    for ordinal, entry in ipairs(choices) do
      local choice = entry.choice --[[@as table<string, unknown>]]
      local actor = choice.actor --[[@as table<string, unknown>]]
      candidates[#candidates + 1] = {
        id = ordinal,
        actor = { combatant = actor.combatant, activation = actor.activation },
        kind = choice.kind,
        payload = copyValue(choice.payload),
        selectedOrdinal = ordinal,
        priority = bracketFor(choice.kind --[[@as string]]),
        speed = NEUTRAL_SPEED,
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
    local event = context:emit("faint", { kind = "faint", combatant = cause.combatant }, {
      combatant = cause.combatant,
      activation = active.activation,
    })
    BattleState.leave(state, active.position --[[@as integer]])
    return event
  end

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
    local outcome = Fainting.step({ queue = state.faints }, { kind = "faint", cursor = "settle" })
    for _, event in ipairs(outcome.events) do
      emitFaint(state, event --[[@as table<string, unknown>]])
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
      projectCombatant(combatant.mon, speciesFacts),
      projectCombatant(defender.mon, speciesFacts),
      category,
      moveName
    )
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
  ---@param action table<string, unknown> queued native action under execution
  ---@param ordinal integer commit order of this action
  local function executeChoice(state, action, ordinal)
    local context = BattleContext.wrap(state)
    local actor = action.actor --[[@as table<string, unknown>]]
    local payload = action.payload --[[@as table<string, unknown>]]
    local cause = {
      kind = "decision",
      controller = action.controller,
      combatant = actor.combatant,
      activation = actor.activation,
    }
    if action.kind == "attack" then
      executeAttack(state, action, ordinal)
    elseif action.kind == "switch" then
      pushCheckedFrame(context, {
        kind = "switch",
        version = 1,
        cursor = "apply",
        state = { combatant = actor.combatant, replacement = payload.replacement },
      })
      local combatant = BattleState.combatant(state, actor.combatant --[[@as integer]])
      local active = combatant.active --[[@as table<string, unknown>]]
      local slot = active.position --[[@as integer]]
      BattleState.leave(state, slot)
      BattleState.enter(state, payload.replacement --[[@as integer]], slot)
      local event = context:emit("switch", cause, {
        position = slot,
        from = actor.combatant,
        to = payload.replacement,
      })
      event.actionId = ordinal
      local frames = state.frames --[[@as table<integer, table<string, unknown>>]]
      frames[#frames] = nil
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
      pushCheckedFrame(context, {
        kind = "action",
        version = 1,
        cursor = "apply",
        state = { combatant = actor.combatant, activation = actor.activation },
      })
      local combatant = BattleState.combatant(state, actor.combatant --[[@as integer]])
      local participant = BattleState.participant(state, combatant.participant --[[@as integer]])
      local inventory = (state.inventories --[[@as table<string, table<string, unknown>>]])[
        participant.inventoryId --[[@as string]]
      ]
      local quantities = inventory.quantities --[[@as table<string, integer>]]
      quantities[
        payload.item --[[@as string]]
      ] = quantities[
        payload.item --[[@as string]]
      ] - 1
      local event = context:emit("item", cause, { item = payload.item, inventory = inventory.id })
      event.actionId = ordinal
      local frames = state.frames --[[@as table<integer, table<string, unknown>>]]
      frames[#frames] = nil
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
    local health = {} ---@type table<integer, integer>
    for _, combatantId in
      ipairs(state.combatantOrder --[[@as integer[] ]])
    do
      local combatant = BattleState.combatant(state, combatantId)
      if combatant.active ~= nil then
        health[combatantId] = combatant.hp --[[@as integer]]
      end
    end
    ---@return table<integer, table<string, unknown>> no residual instances yet
    local function collectNoResiduals()
      return {}
    end
    ---@return table<string, unknown> settled empty pass
    local function invokeEmptyResiduals()
      return { events = {}, done = true, checkpoint = nil }
    end
    local dispatch = { collect = collectNoResiduals, invoke = invokeEmptyResiduals }
    local stream = state.rng --[[@as table<string, unknown>]]
    assert(type(stream.nextU16) == "function", "native residuals draw from the battle stream")
    local outcome = Residuals.step(dispatch, {
      speeds = {},
      health = health,
      stream = stream,
    })
    local context = BattleContext.wrap(state)
    for _, event in ipairs(outcome.events) do
      local record = event --[[@as table<string, unknown>]]
      context:emit(record.kind --[[@as string]], { kind = record.kind }, copyValue(record))
    end
    sweepFaints(state)
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
    state.round = state.round --[[@as integer]] + 1
    if
      state.round --[[@as integer]]
      > state.maxRounds --[[@as integer]]
    then
      state.status = "ended"
      state.outcome = { kind = "scripted_complete", rounds = state.maxRounds }
    else
      state.status = "running"
    end
  end

  return {
    openTurn = openTurn,
    executeAction = executeAction,
    applyResiduals = applyResiduals,
    closeTurn = closeTurn,
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

---@param live table<string, unknown>
---@param content table<string, unknown>
---@param admitted string[] admitted action kinds resolved at construction
---@param moveFacts table<string, table<string, unknown>> immutable move facts carried by the session
---@param speciesFacts table<string, SpeciesFormFacts> static species facts carried by the session
---@return HgssSessionExecutor
local function wrap(live, content, admitted, moveFacts, speciesFacts)
  live.queue = live.queue or {}
  live.schedule = live.schedule or freshSchedule()
  live.faints = live.faints or {}
  return setmetatable({
    _state = live,
    _content = content,
    _admitted = admitted,
    _moveFacts = moveFacts,
    _speciesFacts = speciesFacts,
    _ruleset = nil,
    _finalized = false,
    _disposed = false,
  }, HgssSessionExecutor)
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
  local live = BattleState.create(validated)
  live.rng = BattleRng.new(validated
    .random --[[@as table<string, unknown>]]
    .seed --[[@as integer]])
  local executor = wrap(live, content --[[@as table<string, unknown>]], admitted, moveFacts, speciesFacts)
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
  if type(live.moveFacts) ~= "table" then
    error(BattleErrors.incompatibleSnapshot("native snapshots carry their immutable move facts", {}))
  end
  if type(live.speciesFacts) ~= "table" then
    error(BattleErrors.incompatibleSnapshot("native snapshots carry their static species facts", {}))
  end
  local executor = wrap(
    live,
    content --[[@as table<string, unknown>]],
    admitted,
    live.moveFacts --[[@as table<string, table<string, unknown>>]],
    live.speciesFacts --[[@as table<string, SpeciesFormFacts>]]
  )
  executor:_bindLifecycle()
  return executor
end

--- Binds the native lifecycle to this session. Runs exactly once per
--- session object, matching construction and restoration.
function HgssSessionExecutor:_bindLifecycle()
  assert(self._ruleset == nil, "native lifecycles bind once")
  local ruleset = HgssRuleset.new(bindTurnHandlers(self, self._moveFacts, self._speciesFacts))
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
  while true do
    local due = ruleset:advanceFrame(queue, schedule, stream, stepBudget)
    if due == nil then
      break
    end
    ruleset:handler("executeAction")(due)
  end
  ruleset:handler("applyResiduals")()
  ruleset:handler("closeTurn")()
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
---@param choice table<string, unknown>
---@return table<string, unknown>? input error, or nil when the choice binds
local function checkChoiceBinding(state, choice)
  local actor = choice.actor --[[@as table<string, unknown>]]
  local payload = choice.payload --[[@as table<string, unknown>]]
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
      self:_commitBatch(state, remaining)
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
    local bindingError = checkChoiceBinding(state, choice)
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

---@return table<string, unknown> detached plain interruption capture
function HgssSessionExecutor:capture()
  local state = self:_live()
  local snapshot = BattleSnapshot.capture(state)
  snapshot.queue = copyValue(state.queue)
  snapshot.schedule = copyValue(state.schedule)
  snapshot.faints = copyValue(state.faints)
  snapshot.moveFacts = copyValue(self._moveFacts)
  snapshot.speciesFacts = copyValue(self._speciesFacts)
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
