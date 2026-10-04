-- Validated mechanics mutation surface. Rule and behavior execution
-- receives a context instead of the state table, so every write passes one
-- checked endpoint and carries its semantic cause. The context never escapes
-- execution: callers keep snapshots, views, and events, never this writer.

local BattleErrors = require("libs.battle.src.errors")
local BattleProtocol = require("libs.battle.src.BattleProtocol")
local BattleState = require("libs.battle.src.BattleState")
local StatStages = require("libs.battle.src.gen4.StatStages")
local Status = require("libs.battle.src.gen4.Status")

---@class BattleContext
---@field private _state table<string, unknown>
local BattleContext = {}
BattleContext.__index = BattleContext

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

---@param state table<string, unknown> live battle state, held for one execution only
---@return BattleContext
function BattleContext.wrap(state)
  assert(type(state) == "table", "mechanics execution requires its battle state")
  return setmetatable({ _state = state }, BattleContext)
end

---@param kind string
---@param cause table<string, unknown>
---@param payload table<string, unknown>
---@param audience string?
---@return table<string, unknown> the emitted event
function BattleContext:emit(kind, cause, payload, audience)
  assert(type(kind) == "string" and kind ~= "", "emitted events require their kind")
  assert(type(cause) == "table", "emitted events require their cause")
  assert(type(payload) == "table", "emitted events require their payload record")
  local sequence = self._state.sequence --[[@as integer]] + 1
  self._state.sequence = sequence
  local event = {
    sequence = sequence,
    kind = kind,
    cause = copyValue(cause),
    audience = audience or "public",
    payload = copyValue(payload),
  }
  BattleProtocol.validateEvent(event)
  local outbox = self._state.outbox --[[@as table<integer, table<string, unknown>>]]
  outbox[#outbox + 1] = event
  return event
end

---@param combatantId integer
---@param amount integer
---@param cause table<string, unknown>
---@return table<string, integer> before/after health around the strike
function BattleContext:damage(combatantId, amount, cause)
  assert(type(combatantId) == "number", "damage requires its combatant")
  assert(type(amount) == "number" and amount % 1 == 0 and amount >= 0, "damage amounts stay integral")
  assert(type(cause) == "table", "damage requires its cause")
  local combatant = BattleState.combatant(self._state, combatantId)
  if combatant.active == nil then
    error(BattleErrors.invalidState("strikes land only on active combatants", { combatant = combatantId }))
  end
  local before = combatant.hp --[[@as integer]]
  local after = before - amount --[[@as integer]]
  if after < 0 then
    after = 0
  end
  combatant.hp = after
  return { before = before, after = after }
end

-- Turn-scoped revenge ledger: every staged strike records the damage its
-- taker received from each attacker by category, plus the last damager
-- per category. Revenge, counter, and assurance handlers read it through
-- the per-strike duel facts; the native session resets it when a turn
-- opens. Source references: the turnData physical/special damage arrays
-- and battler-bit masks in src/battle/battle_command.c
-- (CalcRevengeDamageMul, Counter, MirrorCoat) and the defender assurance
-- mask in files/battledata/script/effect_script/effect_script_0231.s.
---@param takerId integer combatant receiving the strike damage
---@param attackerId integer combatant ordering the strike
---@param category string staged damage category selecting the revenge ledger
---@param amount integer damage actually dealt after application
---@return boolean true when the strike entered the turn ledger
function BattleContext:noteDamageTaken(takerId, attackerId, category, amount)
  assert(type(takerId) == "number", "taken damage names its taker")
  assert(type(attackerId) == "number", "taken damage names its attacker")
  assert(category == "physical" or category == "special", "taken damage names its staged category")
  assert(type(amount) == "number" and amount % 1 == 0 and amount >= 0, "taken damage stays integral")
  if amount < 1 then
    return false
  end
  local state = self._state
  if type(state.turnStrikes) ~= "table" then
    state.turnStrikes = {}
  end
  local ledger = state.turnStrikes --[[@as table<integer, table<string, unknown>>]]
  local record = ledger[takerId]
  if type(record) ~= "table" then
    record = { lastPhysical = nil, lastSpecial = nil, amounts = {} }
    ledger[takerId] = record
  end
  local taken = record --[[@as table<string, unknown>]]
  local amounts = taken.amounts --[[@as table<integer, table<string, integer>>]]
  local entry = amounts[attackerId]
  if type(entry) ~= "table" then
    entry = { physical = 0, special = 0 }
    amounts[attackerId] = entry
  end
  local stored = entry --[[@as table<string, integer>]]
  stored[category] = stored[category] --[[@as integer]] + amount
  if category == "physical" then
    taken.lastPhysical = attackerId
  else
    taken.lastSpecial = attackerId
  end
  return true
end

---@param combatantId integer
---@param amount integer
---@param cause table<string, unknown>
---@return table<string, integer> before/after health around the recovery
function BattleContext:heal(combatantId, amount, cause)
  assert(type(combatantId) == "number", "recovery requires its combatant")
  assert(type(amount) == "number" and amount % 1 == 0 and amount >= 0, "recovery amounts stay integral")
  assert(type(cause) == "table", "recovery requires its cause")
  local combatant = BattleState.combatant(self._state, combatantId)
  local before = combatant.hp --[[@as integer]]
  local after = before + amount --[[@as integer]]
  -- Recovery ceilings mirror entryOf: the battle maximum sits above the
  -- entry value whenever the entry arrived wounded.
  local ceiling = combatant.maxHp
  if type(ceiling) ~= "number" then
    ceiling = combatant.entryHp
  end
  if
    after > ceiling --[[@as integer]]
  then
    after = ceiling --[[@as integer]]
  end
  combatant.hp = after
  return { before = before, after = after }
end

-- Battle-local stat stages in native stage law, shared with the state
-- owner so entry reads and stage writes name the same seven keys.
local STAGE_KEYS = { "attack", "defense", "speed", "specialAttack", "specialDefense", "accuracy", "evasion" }

---@param combatantId integer combatant under entry projection
---@return table<string, unknown> detached entry facts for scopes, stages, and health reads
function BattleContext:entryOf(combatantId)
  assert(type(combatantId) == "number", "entry reads require their combatant")
  local combatant = BattleState.combatant(self._state, combatantId)
  local participant = BattleState.participant(self._state, combatant.participant --[[@as integer]])
  local stages = {}
  local carried = combatant.stages
  if type(carried) == "table" then
    local tableCarried = carried --[[@as table<string, integer>]]
    for _, key in ipairs(STAGE_KEYS) do
      local stage = tableCarried[key]
      if type(stage) == "number" and stage % 1 == 0 then
        stages[key] = stage
      else
        stages[key] = 0
      end
    end
  else
    -- Stageless shapes (notably the generic scripted kernel) read as
    -- flat stages so shared strike checkpoints keep one code path.
    for _, key in ipairs(STAGE_KEYS) do
      stages[key] = 0
    end
  end
  -- Recovery ceilings read battle maximum health, which sits above
  -- the entry value whenever the entry arrived wounded; entries that
  -- never projected a maximum keep their entry value.
  local ceiling = combatant.maxHp
  if type(ceiling) ~= "number" then
    ceiling = combatant.entryHp
  end
  local view = {
    side = participant.side,
    position = nil,
    activation = nil,
    stages = stages,
    hp = combatant.hp,
    maxHp = ceiling,
  }
  local active = combatant.active --[[@as table<string, unknown>?]]
  if active ~= nil then
    view.position = active.position
    view.activation = active.activation
  end
  return view
end

---@param combatantId integer combatant under roster projection
---@return integer[] combatant identities sharing the participant roster, in roster order
function BattleContext:rosterOf(combatantId)
  assert(type(combatantId) == "number", "roster reads require their combatant")
  local combatant = BattleState.combatant(self._state, combatantId)
  local participant = BattleState.participant(self._state, combatant.participant --[[@as integer]])
  local roster = {}
  for _, id in
    ipairs(participant.roster --[[@as integer[] ]])
  do
    roster[#roster + 1] = id
  end
  return roster
end

---@return integer[] active combatant identities in battle order
function BattleContext:activeCombatants()
  local actives = {}
  local order = self._state.combatantOrder --[[@as integer[] ]]
  for _, id in ipairs(order) do
    local combatant = BattleState.combatant(self._state, id)
    if combatant.active ~= nil then
      actives[#actives + 1] = id
    end
  end
  return actives
end

---@param combatantId integer combatant owning the stage
---@param stat string stage identity under the write
---@param stage integer clamped stage value to install
---@param cause table<string, unknown> semantic reason ordering the change
---@return table<string, integer> before/after stages around the change
function BattleContext:changeStage(combatantId, stat, stage, cause)
  assert(type(combatantId) == "number", "stage writes require their combatant")
  assert(type(cause) == "table", "stage writes carry their cause")
  local known = false
  for _, key in ipairs(STAGE_KEYS) do
    if key == stat then
      known = true
    end
  end
  if not known then
    error(BattleErrors.invalidState("stage writes name a native stage", { combatant = combatantId }))
  end
  if type(stage) ~= "number" or stage % 1 ~= 0 or stage < StatStages.MIN or stage > StatStages.MAX then
    error(BattleErrors.invalidState("stage writes carry clamped integer stages", { combatant = combatantId }))
  end
  local combatant = BattleState.combatant(self._state, combatantId)
  if combatant.active == nil then
    error(BattleErrors.invalidState("stages change only on active combatants", { combatant = combatantId }))
  end
  local stages = combatant.stages --[[@as table<string, integer>]]
  local before = stages[
    stat --[[@as string]]
  ] --[[@as integer]]
  stages[
    stat --[[@as string]]
  ] = stage --[[@as integer]]
  self:emit("stage", cause, { target = combatantId, stat = stat, before = before, after = stage })
  return { before = before, after = stage }
end

---@param combatantId integer combatant receiving the condition
---@param key string native major condition under application
---@param state table<string, unknown> candidate typed state for the condition
---@param cause table<string, unknown> semantic reason ordering the application
---@return boolean true when the condition was applied
function BattleContext:applyStatus(combatantId, key, state, cause)
  assert(type(combatantId) == "number", "condition writes require their combatant")
  assert(type(cause) == "table", "condition writes carry their cause")
  local combatant = BattleState.combatant(self._state, combatantId)
  if combatant.active == nil then
    return false
  end
  if
    combatant.hp --[[@as integer]]
    <= 0
  then
    return false
  end
  local mon = combatant.mon --[[@as table<string, unknown>]]
  local condition = mon.condition --[[@as table<string, unknown>]]
  local effects = condition.effects --[[@as table<integer, unknown>]]
  if #effects > 0 then
    return false
  end
  Status.apply(mon --[[@as table<string, unknown>]], key, cause, state)
  self:emit("status", cause, { target = combatantId, key = key })
  return true
end

---@param combatantId integer combatant owning the condition
---@param key string native major condition under the cure
---@param cause table<string, unknown> semantic reason ordering the cure
---@return boolean true when a condition was cured
function BattleContext:cureStatus(combatantId, key, cause)
  assert(type(combatantId) == "number", "condition cures require their combatant")
  assert(type(cause) == "table", "condition cures carry their cause")
  local combatant = BattleState.combatant(self._state, combatantId)
  local cured = Status.cure(combatant.mon --[[@as table<string, unknown>]], key)
  if cured then
    self:emit("cured", cause, { target = combatantId, key = key })
  end
  return cured
end

---@param state table<string, unknown> live battle state holding the effect owner
---@return table<string, unknown> live scoped-instance owner held by the state
local function liveBag(state)
  local bag = state.effectBag
  if type(bag) ~= "table" or type(bag.add) ~= "function" then
    error(BattleErrors.invalidState("typed effect writes require the live effect owner", {}))
  end
  return bag --[[@as table<string, unknown>]]
end

---@param definition table<string, unknown> effect definition carrying key, version, validator, timings, and lifecycle
---@param scope table<string, unknown> owner scope the instance attaches to
---@param source table<string, unknown> causal source attributed to the instance
---@param state unknown candidate typed state validated by the definition
---@return table<string, unknown> detached copy of the stored instance
function BattleContext:addBattleEffect(definition, scope, source, state)
  assert(type(definition) == "table", "typed writes require their definition")
  assert(type(scope) == "table", "typed writes require their owner scope")
  assert(type(source) == "table", "typed writes carry their causal source")
  local bag = liveBag(self._state)
  local add = bag.add --[[@as fun(self: table<string, unknown>, definition: table<string, unknown>, scope: table<string, unknown>, source: table<string, unknown>, state: unknown): table<string, unknown>]]
  return add(bag, definition, scope, source, state)
end

-- Side-scoped instances belong to the combatant through its side: a
-- side screen or chant answers for every combatant standing on that
-- side, so removal and queries match side scopes through the entry
-- projection alongside the direct combatant scopes.
---@param state table<string, unknown> live battle state under the scope match
---@param combatantId integer combatant identity owning the instance scope
---@param scope table<string, unknown> candidate instance scope under matching
---@return boolean true when the scope answers for the combatant
local function scopeAnswersFor(state, combatantId, scope)
  if type(scope) ~= "table" then
    return false
  end
  if scope.combatant == combatantId then
    return true
  end
  if scope.kind == "side" then
    local combatant = BattleState.combatant(state, combatantId)
    local participant = BattleState.participant(state, combatant.participant --[[@as integer]])
    return scope.side == participant.side
  end
  return false
end

---@param combatantId integer combatant identity owning the instance scope
---@param key string definition identity under removal
---@return boolean true when a held instance was removed
function BattleContext:removeBattleEffect(combatantId, key)
  assert(type(combatantId) == "number", "effect removal requires their combatant")
  assert(type(key) == "string" and key ~= "", "effect removal requires its key")
  local bag = liveBag(self._state)
  local capture = bag.capture --[[@as fun(self: table<string, unknown>): table<integer, table<string, unknown>>]]
  for _, record in ipairs(capture(bag)) do
    local scope = record.scope --[[@as table<string, unknown>]]
    if record.key == key and scopeAnswersFor(self._state, combatantId, scope) then
      local remove = bag.remove --[[@as fun(self: table<string, unknown>, id: integer): boolean]]
      return remove(bag, record.id --[[@as integer]])
    end
  end
  return false
end

---@param combatantId integer combatant identity owning the instance scope
---@param key string definition identity under the query
---@return boolean true when a live instance names the key on the combatant scope
function BattleContext:hasBattleEffect(combatantId, key)
  assert(type(combatantId) == "number", "effect queries require their combatant")
  assert(type(key) == "string" and key ~= "", "effect queries require their key")
  local bag = liveBag(self._state)
  local capture = bag.capture --[[@as fun(self: table<string, unknown>): table<integer, table<string, unknown>>]]
  for _, record in ipairs(capture(bag)) do
    local scope = record.scope --[[@as table<string, unknown>]]
    if record.key == key and scopeAnswersFor(self._state, combatantId, scope) then
      return true
    end
  end
  return false
end

---@param side integer side identity owning the instance scope
---@param key string definition identity under the query
---@return table<string, unknown>? detached first matching side instance, nil when absent
function BattleContext:sideEffect(side, key)
  assert(type(side) == "number", "side reads require their side")
  assert(type(key) == "string" and key ~= "", "side reads name their definition")
  local bag = liveBag(self._state)
  local capture = bag.capture --[[@as fun(self: table<string, unknown>): table<integer, table<string, unknown>>]]
  for _, record in ipairs(capture(bag)) do
    local scope = record.scope --[[@as table<string, unknown>]]
    if record.key == key and type(scope) == "table" and scope.kind == "side" and scope.side == side then
      local get = bag.get --[[@as fun(self: table<string, unknown>, id: integer): table<string, unknown>?]]
      return get(bag, record.id --[[@as integer]])
    end
  end
  return nil
end

---@param key string definition identity under removal
---@return boolean true when a live field instance was removed
function BattleContext:removeFieldEffect(key)
  assert(type(key) == "string" and key ~= "", "field removal names its definition")
  local bag = liveBag(self._state)
  local capture = bag.capture --[[@as fun(self: table<string, unknown>): table<integer, table<string, unknown>>]]
  for _, record in ipairs(capture(bag)) do
    local scope = record.scope --[[@as table<string, unknown>]]
    if record.key == key and type(scope) == "table" and scope.kind == "field" then
      local remove = bag.remove --[[@as fun(self: table<string, unknown>, id: integer): boolean]]
      return remove(bag, record.id --[[@as integer]])
    end
  end
  return false
end

---@param key string definition identity under the query
---@return table<string, unknown>? detached first matching field instance, nil when absent
function BattleContext:fieldEffect(key)
  assert(type(key) == "string" and key ~= "", "field reads name their definition")
  local bag = liveBag(self._state)
  local capture = bag.capture --[[@as fun(self: table<string, unknown>): table<integer, table<string, unknown>>]]
  for _, record in ipairs(capture(bag)) do
    local scope = record.scope --[[@as table<string, unknown>]]
    if record.key == key and type(scope) == "table" and scope.kind == "field" then
      local get = bag.get --[[@as fun(self: table<string, unknown>, id: integer): table<string, unknown>?]]
      return get(bag, record.id --[[@as integer]])
    end
  end
  return nil
end

---@param combatantId integer combatant identity under the read
---@return string? major condition key on the canonical mon, nil when healthy
function BattleContext:statusOf(combatantId)
  assert(type(combatantId) == "number", "condition reads require their combatant")
  local combatant = BattleState.combatant(self._state, combatantId)
  local mon = combatant.mon --[[@as table<string, unknown>]]
  if type(mon) ~= "table" then
    return nil
  end
  local condition = (mon --[[@as table<string, unknown>]]).condition --[[@as table<string, unknown>?]]
  if type(condition) ~= "table" then
    return nil
  end
  local effects = (condition --[[@as table<string, unknown>]]).effects --[[@as table<integer, unknown>?]]
  if type(effects) ~= "table" then
    return nil
  end
  local current = (effects --[[@as table<integer, unknown>]])[1] --[[@as table<string, unknown>?]]
  if type(current) ~= "table" or type(current.key) ~= "string" then
    return nil
  end
  return current.key --[[@as string]]
end

---@param combatantId integer combatant spending its held item
---@return string? item key spent, nil when the holder carried nothing
function BattleContext:consumeHeldItem(combatantId)
  assert(type(combatantId) == "number", "held consumption names its combatant")
  local combatant = BattleState.combatant(self._state, combatantId)
  local mon = combatant.mon --[[@as table<string, unknown>]]
  assert(type(mon) == "table", "held consumption reads the battle mon")
  local held = mon.heldItem
  if type(held) ~= "string" or held == "" or held == "NONE" then
    return nil
  end
  mon.heldItem = "NONE"
  return held --[[@as string]]
end

---@param combatantId integer combatant identity owning the power-point store
---@param moveKey string move identity losing power points
---@param amount integer power points to remove before the floor
---@return integer power points actually removed
function BattleContext:cutPp(combatantId, moveKey, amount)
  assert(type(combatantId) == "number", "power-point cuts name their combatant")
  assert(type(moveKey) == "string" and moveKey ~= "", "power-point cuts name their move")
  assert(type(amount) == "number" and amount % 1 == 0 and amount >= 0, "power-point cuts carry a count")
  local combatant = BattleState.combatant(self._state, combatantId)
  local mon = combatant.mon --[[@as table<string, unknown>]]
  assert(type(mon) == "table", "power-point cuts read the battle mon")
  local moves = (mon --[[@as table<string, unknown>]]).moves --[[@as table<integer, unknown>]]
  assert(type(moves) == "table", "power-point cuts read the move store")
  for _, entry in ipairs(moves) do
    local record = entry --[[@as table<string, unknown>]]
    if type(record) == "table" and record.move == moveKey then
      local left = record.pp --[[@as integer]]
      assert(type(left) == "number" and left % 1 == 0 and left >= 0, "power-point stores stay integral")
      local cut = amount --[[@as integer]]
      if cut > left then
        cut = left
      end
      record.pp = left - cut
      return cut
    end
  end
  return 0
end

---@param combatantId integer
---@param patch table<string, unknown> battle-local projection overrides
function BattleContext:updateMon(combatantId, patch)
  assert(type(combatantId) == "number", "projection writes require their combatant")
  assert(type(patch) == "table", "projection writes require their patch record")
  local combatant = BattleState.combatant(self._state, combatantId)
  local materialized = combatant.materialized --[[@as table<string, unknown>]]
  for key, value in pairs(patch) do
    if type(key) ~= "string" or key == "" then
      error(BattleErrors.invalidState("projection overrides must be named", { combatant = combatantId }))
    end
    materialized[key] = copyValue(value)
  end
end

---@param frame table<string, unknown> plain continuation frame
function BattleContext:pushFrame(frame)
  assert(type(frame) == "table", "continuation frames must be records")
  if type(frame.kind) ~= "string" or frame.kind == "" then
    error(BattleErrors.invalidState("continuation frames must name their kind", {}))
  end
  if type(frame.version) ~= "number" or frame.version % 1 ~= 0 or frame.version < 1 then
    error(BattleErrors.invalidState("continuation frames must carry a positive version", {}))
  end
  if type(frame.cursor) ~= "string" or frame.cursor == "" then
    error(BattleErrors.invalidState("continuation frames must name their cursor", {}))
  end
  if type(frame.state) ~= "table" then
    error(BattleErrors.invalidState("continuation frames must carry plain state", {}))
  end
  local frames = self._state.frames --[[@as table<integer, table<string, unknown>>]]
  frames[#frames + 1] = copyValue(frame) --[[@as table<string, unknown>]]
end

---@param spec table<string, unknown> decision request under construction
---@return table<string, unknown> the appended request
function BattleContext:requestDecision(spec)
  assert(type(spec) == "table", "decision requests must be records")
  if type(spec.controller) ~= "string" or spec.controller == "" then
    error(BattleErrors.invalidState("decision requests must name their controller", {}))
  end
  if
    type(spec.kind) ~= "string" or not BattleProtocol.isDecisionKind(spec.kind --[[@as string]])
  then
    error(BattleErrors.missingBehavior("decision requests require a registered kind", {
      kind = tostring(spec.kind),
    }))
  end
  if
    type(spec.actors) ~= "table"
    or #spec.actors --[[@as table<integer, unknown>]]
      == 0
  then
    error(BattleErrors.invalidState("decision requests must address at least one actor", {}))
  end
  for _, actor in
    ipairs(spec.actors --[[@as table<integer, unknown>]])
  do
    if type(actor) ~= "table" then
      error(BattleErrors.invalidState("decision requests must address combatant records", {}))
    end
    local record = actor --[[@as table<string, unknown>]]
    if type(record.combatant) ~= "number" then
      error(BattleErrors.invalidState("decision actors must carry combatant and token", {}))
    end
    -- Roster-scoped prompts omit the entry token and bind by combatant
    -- alone; every other batch addresses live entries and keeps its
    -- token. A present token must still be a number.
    if record.activation ~= nil and type(record.activation) ~= "number" then
      error(BattleErrors.invalidState("decision actors must carry combatant and token", {}))
    end
    BattleState.combatant(self._state, record.combatant --[[@as integer]])
  end
  if type(spec.legalChoices) ~= "table" then
    error(BattleErrors.invalidState("decision requests must freeze their legal choice view", {}))
  end
  local pending = self._state.pending --[[@as table<string, unknown>]]
  if pending == nil then
    error(BattleErrors.invalidState("decision requests require an open batch", {}))
  end
  local counter = self._state.requestCounter --[[@as integer]] + 1
  self._state.requestCounter = counter
  local request = {
    requestId = counter,
    epoch = (pending.batch --[[@as table<string, unknown>]]).epoch,
    controller = spec.controller,
    kind = spec.kind,
    actors = copyValue(spec.actors),
    legalChoices = copyValue(spec.legalChoices),
  }
  local batch = pending.batch --[[@as table<string, unknown>]]
  local requests = batch.requests --[[@as table<integer, table<string, unknown>>]]
  requests[#requests + 1] = request
  return request
end

return BattleContext
