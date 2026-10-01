-- Sole headless battle lifetime and stepping owner. A session holds
-- detached scenario state, one sealed decision batch at a time, a typed
-- continuation stack, and an immutable event outbox. `advance` runs whole
-- semantic operations until the battle waits, ends, or exhausts its
-- operation budget; the budget affects only responsiveness, never turns,
-- draws, or effect order. Replies are validated before anything is stored,
-- so rejected input consumes no randomness, items, or reservations, and
-- sealed peer choices never leak across controllers. Only the scripted
-- decision point executes here; unknown rulesets fail instead of falling
-- back to guessed mechanics.

local BattleContext = require("libs.battle.src.BattleContext")
local BattleErrors = require("libs.battle.src.errors")
local BattleProtocol = require("libs.battle.src.BattleProtocol")
local BattleScenario = require("libs.battle.src.BattleScenario")
local BattleSnapshot = require("libs.battle.src.BattleSnapshot")
local BattleState = require("libs.battle.src.BattleState")
local BattleView = require("libs.battle.src.BattleView")
local NativeFormats = require("libs.battle.src.gen4.formats.NativeFormats")
local Lcrng = require("libs.mons.src.gen4.Lcrng")

---@class BattleSession
---@field private _state table<string, unknown>?
---@field private _content table<string, unknown>?
---@field private _admitted string[]
---@field private _disposed boolean
local BattleSession = {}
BattleSession.__index = BattleSession

-- The one decision vocabulary owned by this kernel. The executable marker
-- names the scripted decision point the application stamps onto its native
-- scenarios; content may resolve additional rulesets for custom formats,
-- which this kernel executes with the same atomic validation, causal
-- events, and deterministic continuations. Formats own the admitted action
-- kinds and per-actor budgets for every one of them.
BattleSession.EXECUTABLE_RULESET = "test:scripted"
BattleSession.DECISION_KIND = "action"

BattleSession.DEFAULT_ACTION_KINDS = { "attack", "switch", "confirm", "item" }

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

-- Resolves the admitted action vocabulary for one format identity.
-- Registered content formats win over native keys: a content-registered
-- policy carries its own admitted kinds (or the standard vocabulary when
-- the registration names none), while a native key additionally proves
-- its topology against the scenario under construction. Anything else is
-- missing behavior naming the unknown key: sessions never run an unknown
-- or misspelled format on a guessed vocabulary.
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
        return copyValue(BattleSession.DEFAULT_ACTION_KINDS) --[[@as string[] ]]
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
      return copyValue(BattleSession.DEFAULT_ACTION_KINDS) --[[@as string[] ]]
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

---@param live table<string, unknown>
---@param content table<string, unknown>
---@param admitted string[] admitted action kinds resolved at construction
---@return BattleSession
local function wrap(live, content, admitted)
  return setmetatable({ _state = live, _content = content, _admitted = admitted, _disposed = false }, BattleSession)
end

---@param scenarioRecord table<string, unknown> detached serializable battle setup
---@param content table<string, unknown> frozen executable battle content
---@return BattleSession
function BattleSession.new(scenarioRecord, content)
  assert(type(scenarioRecord) == "table", "session construction requires its scenario record")
  local validated = BattleScenario.validate(scenarioRecord)
  checkContent(content, validated.ruleset --[[@as string]])
  local admitted = admittedKindsFor(validated.format --[[@as string]], content, validated)
  return wrap(BattleState.create(validated), content --[[@as table<string, unknown>]], admitted)
end

---@param snapshotData unknown interruption capture under validation
---@param content table<string, unknown> frozen executable battle content
---@return BattleSession
function BattleSession.restore(snapshotData, content)
  local live = BattleSnapshot.restore(snapshotData)
  checkContent(content, live.ruleset --[[@as string]])
  local admitted = admittedKindsFor(live.format --[[@as string]], content, nil)
  live.rng = Lcrng.restore(live.rng --[[@as table<string, integer>]])
  checkRestoredShape(live)
  return wrap(live, content, admitted)
end

---@return table<string, unknown> live battle state, failing after disposal
function BattleSession:_live()
  if self._disposed or self._state == nil then
    error(BattleErrors.invalidState("disposed sessions publish nothing further", {}))
  end
  return self._state
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
      kind = BattleSession.DECISION_KIND,
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
    return position.occupant --[[@as integer?]]
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

---@param state table<string, unknown>
---@param context table<string, unknown>
---@param choice table<string, unknown>
---@param controller string
---@param ordinal integer commit order of this choice
local function applyChoice(state, context, choice, controller, ordinal)
  local typed = context --[[@as BattleContext]]
  local actor = choice.actor --[[@as table<string, unknown>]]
  local payload = choice.payload --[[@as table<string, unknown>]]
  local cause = {
    kind = "decision",
    controller = controller,
    combatant = actor.combatant,
    activation = actor.activation,
  }
  if choice.kind == "attack" then
    pushCheckedFrame(context, {
      kind = "action",
      version = 1,
      cursor = "apply",
      state = { combatant = actor.combatant, activation = actor.activation },
    })
    local generator = state.rng --[[@as Gen4Lcrng]]
    local roll = generator:nextU16()
    local resolved =
      resolveTarget(state, actor.combatant --[[@as integer]], payload.target --[[@as table<string, unknown>]])
    local eventPayload = {
      moveSlot = payload.moveSlot,
      target = copyValue(payload.target),
      roll = roll,
    }
    if resolved ~= nil then
      local health = typed:damage(resolved, 1, cause)
      eventPayload.resolved = resolved
      eventPayload.before = health.before
      eventPayload.after = health.after
    end
    local event = typed:emit("strike", cause, eventPayload)
    event.actionId = ordinal
    event.hitIndex = 1
  elseif choice.kind == "switch" then
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
    local event = typed:emit("switch", cause, {
      position = slot,
      from = actor.combatant,
      to = payload.replacement,
    })
    event.actionId = ordinal
  elseif choice.kind == "confirm" then
    pushCheckedFrame(context, {
      kind = "action",
      version = 1,
      cursor = "apply",
      state = { combatant = actor.combatant, activation = actor.activation },
    })
    local event = typed:emit("acknowledge", cause, {})
    event.actionId = ordinal
  elseif choice.kind == "item" then
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
    local event = typed:emit("item", cause, { item = payload.item, inventory = inventory.id })
    event.actionId = ordinal
  else
    error(BattleErrors.invalidState("commit met an unvalidated choice", {}))
  end
  local frames = state.frames --[[@as table<integer, table<string, unknown>>]]
  frames[#frames] = nil
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

---@param state table<string, unknown>
local function commitBatch(state)
  local context = BattleContext.wrap(state)
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
  for ordinal, entry in ipairs(ordered) do
    applyChoice(
      state,
      context,
      entry.choice --[[@as table<string, unknown>]],
      entry.controller --[[@as string]],
      ordinal
    )
  end
  local frames = state.frames --[[@as table<integer, table<string, unknown>>]]
  local roundFrame = frames[#frames]
  assert(roundFrame ~= nil and roundFrame.kind == "round", "commit closes its round frame")
  frames[#frames] = nil
  state.pending = nil
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
function BattleSession:advance(operationBudget)
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
    elseif batchComplete(state) then
      if remaining < 1 then
        return { status = "running", events = drainOutbox(state) }
      end
      commitBatch(state)
      remaining = remaining - 1
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
function BattleSession:submit(reply)
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

--- Publishes a staged topology join at its declared settlement boundary.
--- New roster, participant, position, and inventory entries land under this
--- owner exactly once; occupants enter with fresh activation tokens and
--- entry effects, and an open decision batch moves to a new epoch so stale
--- replies cannot retarget the changed topology. Joined combatants wait
--- for the next batch: the open batch keeps its addressed actors.
---@param staged unknown staging record from validated topology preparation
---@return table<string, unknown> join receipt carrying the published identities
function BattleSession:applyJoin(staged)
  local state = self:_live()
  if type(staged) ~= "table" then
    error(BattleErrors.input("joins apply a staged record", {}))
  end
  local join = staged --[[@as table<string, unknown>]]
  if join.version ~= 1 then
    error(BattleErrors.input("staged joins carry the current version", {}))
  end
  if join.targetKind ~= "session" then
    error(BattleErrors.input("scenario assemblies apply at construction, not mid-battle", {}))
  end
  if join.format ~= state.format or join.ruleset ~= state.ruleset then
    error(BattleErrors.input("staged joins must match the session format and ruleset", {}))
  end
  if join.baseCounter ~= state.batchCounter then
    error(BattleErrors.input("stale join staging cannot publish onto a moved battle", {}))
  end
  local newcomers = join.combatants --[[@as table<integer, unknown>]]
  local seats = join.positions --[[@as table<integer, unknown>]]
  assert(type(newcomers) == "table" and type(seats) == "table", "staged joins carry their membership lists")
  local participants = state.participants --[[@as table<integer, table<string, unknown>>]]
  local roster = {} ---@type table<integer, integer>
  local owner = nil ---@type integer?
  if #newcomers > 0 then
    local stagedOwner = join.participant --[[@as table<string, unknown>]]
    assert(type(stagedOwner) == "table", "staged joins name their owning participant")
    owner = stagedOwner.id --[[@as integer]]
    for _, entry in ipairs(newcomers) do
      roster[#roster + 1] = (entry --[[@as table<string, unknown>]]).id --[[@as integer]]
    end
    local known = participants[
      owner --[[@as integer]]
    ]
    if known == nil then
      participants[
        owner --[[@as integer]]
      ] = {
        id = owner,
        side = stagedOwner.side,
        controller = stagedOwner.controller,
        inventoryId = stagedOwner.inventoryId,
        roster = copyValue(roster),
        context = copyValue(stagedOwner.context),
      }
      local participantOrder = state.participantOrder --[[@as integer[] ]]
      participantOrder[#participantOrder + 1] = owner --[[@as integer]]
      local sides = state.sides --[[@as table<integer, table<string, unknown>>]]
      local side = sides[
        stagedOwner.side --[[@as integer]]
      ]
      local members = side.participants --[[@as table<integer, unknown>]]
      members[#members + 1] = owner
    else
      local existing = known.roster --[[@as table<integer, unknown>]]
      for _, id in ipairs(roster) do
        existing[#existing + 1] = id
      end
    end
    local combatants = state.combatants --[[@as table<integer, table<string, unknown>>]]
    local combatantOrder = state.combatantOrder --[[@as integer[] ]]
    for _, entry in ipairs(newcomers) do
      local seed = entry --[[@as table<string, unknown>]]
      local id = seed.id --[[@as integer]]
      local mon = seed.mon --[[@as table<string, unknown>]]
      local hp = (mon.condition --[[@as table<string, unknown>]]).currentHp --[[@as integer]]
      combatants[id] = {
        id = id,
        participant = owner,
        mon = copyValue(mon),
        source = copyValue(seed.source),
        hp = hp,
        entryHp = hp,
        active = nil,
        volatiles = {},
        materialized = {},
      }
      combatantOrder[#combatantOrder + 1] = id
    end
  end
  local positions = state.positions --[[@as table<integer, table<string, unknown>>]]
  local positionOrder = state.positionOrder --[[@as integer[] ]]
  for _, entry in ipairs(seats) do
    local seat = entry --[[@as table<string, unknown>]]
    local id = seat.id --[[@as integer]]
    if positions[id] == nil then
      positions[id] = {
        id = id,
        side = seat.side,
        eligible = copyValue(seat.eligibleParticipants),
        occupant = nil,
        activation = nil,
      }
      positionOrder[#positionOrder + 1] = id
    end
  end
  for _, entry in
    ipairs(join.inventories --[[@as table<integer, unknown>]])
  do
    local inventory = entry --[[@as table<string, unknown>]]
    local owned = state.inventories --[[@as table<string, table<string, unknown>>]]
    owned[
      inventory.id --[[@as string]]
    ] = {
      id = inventory.id,
      owners = copyValue(inventory.owners),
      quantities = copyValue(inventory.quantities),
    }
  end
  local context = BattleContext.wrap(state)
  local placed = {} ---@type table<integer, table<string, integer>>
  for _, entry in ipairs(seats) do
    local seat = entry --[[@as table<string, unknown>]]
    if seat.occupant ~= nil then
      local token = BattleState.enter(state, seat.occupant --[[@as integer]], seat.id --[[@as integer]])
      placed[#placed + 1] = {
        combatant = seat.occupant --[[@as integer]],
        position = seat.id --[[@as integer]],
        activation = token,
      }
      context:emit("join", { kind = "join", reason = join.reason, combatant = seat.occupant }, {
        position = seat.id,
        combatant = seat.occupant,
        activation = token,
      })
    end
  end
  state.batchCounter = state.batchCounter --[[@as integer]] + 1
  if state.pending ~= nil then
    local pending = state.pending --[[@as table<string, unknown>]]
    local batch = pending.batch --[[@as table<string, unknown>]]
    batch.epoch = state.batchCounter
  end
  return {
    combatants = copyValue(roster),
    seats = copyValue(placed),
    epoch = state.batchCounter,
  }
end

---@param controller string
---@return table<string, unknown> detached perspective view
function BattleSession:view(controller)
  self:_live()
  return BattleView.forController(self, controller)
end

---@return table<string, unknown> detached plain interruption capture
function BattleSession:capture()
  local state = self:_live()
  return BattleSnapshot.capture(state)
end

function BattleSession:dispose()
  self._disposed = true
  self._state = nil
  self._content = nil
end

return BattleSession
