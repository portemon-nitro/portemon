-- Private event-time playback facts for battle presentation. Native move
-- and lifecycle emitters capture authoritative actor, target, move, and
-- display-checkpoint identities at their mutation point; later playback
-- reads these captured facts instead of searching display order,
-- rereading live state, or replaying combat. The projection is pure over
-- the supplied state, cause, and payload: it draws nothing from the
-- combat or world random streams (particle variation rides a separately
-- hashed visual seed) and never changes damage, order, or legality.
-- Source references: the presentation commands in
-- src/battle/battle_command.c and the player controller in
-- src/battle/battle_controller_player.c.

---@class PresentationFacts
local PresentationFacts = {}

-- Closed visual-route mapping for every event kind the native session
-- emits. Each presentation-material kind names its concrete playback
-- route; the purely bookkeeping acknowledgement keeps its silent route.
-- Kinds outside this table keep their own kind as the route so a future
-- emission still carries an honest identity instead of vanishing.
local FLOW_KEYS = {
  ["move-used"] = "move-use",
  struck = "strike",
  strike = "strike",
  missed = "miss",
  ["move-failed"] = "miss",
  protected = "protect",
  charged = "charge",
  delayed = "delay",
  ["substitute-broke"] = "substitute-break",
  recoil = "recoil",
  drained = "drain",
  healed = "heal",
  tick = "residual-tick",
  faint = "faint",
  fainted = "faint",
  leveled = "level",
  transformed = "transform",
  sketched = "sketch",
  mimicked = "mimic",
  status = "status",
  cured = "cure",
  stage = "stage",
  ["status-gate"] = "status-gate",
  blocked = "status-gate",
  immune = "miss",
  ["multi-hit"] = "multi-hit",
  switch = "switch",
  ["switch-intent"] = "switch-intent",
  ["item-intent"] = "item-intent",
  item = "item",
  flee = "flee",
  acknowledge = "acknowledge",
  join = "join",
  exp = "experience",
  stats = "stats",
  learn = "learn",
  declined = "decline",
  throw = "throw",
  shake = "shake",
  caught = "catch",
  broke_free = "break-free",
}

-- Move-route selections name the executed move identity so playback
-- chooses the exact native route and its parameters. Every other kind
-- carries no route selection.
local MOVE_ROUTES = {
  ["move-used"] = true,
  struck = true,
  missed = true,
  protected = true,
  charged = true,
  delayed = true,
  mimicked = true,
  immune = true,
  ["multi-hit"] = true,
}

---@param kind unknown event kind under route selection
---@return string playback route key for the kind
function PresentationFacts.flowKeyFor(kind)
  if type(kind) == "string" and FLOW_KEYS[kind] ~= nil then
    return FLOW_KEYS[kind] --[[@as string]]
  end
  if type(kind) == "string" and kind ~= "" then
    return kind --[[@as string]]
  end
  return "unknown"
end

---@param kind unknown event kind under route selection
---@param executed unknown executed move identity under route selection
---@return string? route selection, nil when the kind carries none
function PresentationFacts.effectKeyFor(kind, executed)
  if type(kind) ~= "string" or MOVE_ROUTES[kind] ~= true then
    return nil
  end
  if type(executed) ~= "string" or executed == "" then
    return nil
  end
  return executed --[[@as string]]
end

---@param kind unknown event kind under suppression inspection
---@return table<string, boolean>? semantic suppression flags, nil when the action connects
function PresentationFacts.suppressionFor(kind)
  if kind == "missed" then
    return { missed = true }
  end
  if kind == "protected" then
    return { protected = true }
  end
  return nil
end

---@param sequence unknown event sequence ordinal under visual seeding
---@return integer deterministic visual seed scoped to the event identity
function PresentationFacts.visualSeedFor(sequence)
  local ordinal = 0
  if type(sequence) == "number" and sequence % 1 == 0 and sequence >= 0 then
    ordinal = sequence --[[@as integer]]
  end
  -- An independent additive stream: arithmetic over the stable identity
  -- only, so playback variation never advances the combat stream.
  return (ordinal * 1103515245 + 12345) % 2147483648
end

---@param state table<string, unknown> live battle state under identity resolution
---@param id unknown combatant identity under resolution
---@param activationHint unknown entry token carried by the cause when the battler already left
---@return table<string, unknown>? detached actor record, nil for a non-combatant identity
local function resolveActor(state, id, activationHint)
  if type(id) ~= "number" or id % 1 ~= 0 or id < 1 then
    return nil
  end
  local combatants = state.combatants --[[@as table<integer, table<string, unknown>>?]]
  local record = {
    combatant = id --[[@as integer]],
  } --[[@as table<string, unknown>]]
  local combatant = type(combatants) == "table" and combatants[
    id --[[@as integer]]
  ] or nil
  local active = type(combatant) == "table" and (combatant --[[@as table<string, unknown>]]).active
  if type(active) == "table" then
    local entry = active --[[@as table<string, unknown>]]
    if type(entry.activation) == "number" then
      record.activation = entry.activation
    elseif type(activationHint) == "number" then
      record.activation = activationHint
    end
    if type(entry.position) == "number" then
      record.position = entry.position
    end
    local participantId = (combatant --[[@as table<string, unknown>]]).participant
    local participants = state.participants --[[@as table<integer, table<string, unknown>>?]]
    local participant = type(participants) == "table"
        and type(participantId) == "number"
        and participants[
          participantId --[[@as integer]]
        ]
      or nil
    if
      type(participant) == "table" and type((participant --[[@as table<string, unknown>]]).side) == "number"
    then
      record.side = (participant --[[@as table<string, unknown>]]).side
    end
    return record
  end
  if type(activationHint) == "number" then
    record.activation = activationHint
  end
  return record
end

---@param id unknown combatant identity under target resolution
---@return integer? the identity once it proves a combatant
local function targetIdOf(id)
  if type(id) == "number" and id % 1 == 0 and id >= 1 then
    return id --[[@as integer]]
  end
  return nil
end

---@param state table<string, unknown> live battle state under identity resolution
---@param kind unknown event kind selecting the actor rule
---@param cause table<string, unknown> semantic cause carrying the ordering combatant
---@param payload table<string, unknown> event payload carrying the subject identities
---@param scope table<string, unknown>? executing strike scope carrying the authoritative user
---@return table<integer, table<string, unknown>> ordered detached actor records
local function actorsFor(state, kind, cause, payload, scope)
  local out = {} ---@type table<integer, table<string, unknown>>
  local hint = nil
  if type(cause.activation) == "number" then
    hint = cause.activation --[[@as integer]]
  end
  -- A replacement names its arrival: the incoming battler owns the
  -- reveal while the departure keeps the withdrawal below.
  if kind == "switch" then
    local incoming = targetIdOf(payload.to)
    if incoming ~= nil then
      local record = resolveActor(state, incoming, nil)
      if record ~= nil then
        out[#out + 1] = record
        return out
      end
    end
  end
  local id = nil
  if
    scope ~= nil
    and type(scope.actor) == "table"
    and type((scope.actor --[[@as table<string, unknown>]]).combatant) == "number"
  then
    id = (scope.actor --[[@as table<string, unknown>]]).combatant --[[@as integer]]
  elseif type(cause.combatant) == "number" then
    id = cause.combatant --[[@as integer]]
  elseif type(payload.user) == "number" then
    id = payload.user --[[@as integer]]
  elseif type(payload.combatant) == "number" then
    id = payload.combatant --[[@as integer]]
  elseif type(payload.target) == "number" then
    id = payload.target --[[@as integer]]
  elseif type(payload.from) == "number" then
    id = payload.from --[[@as integer]]
  end
  if id ~= nil then
    local record = resolveActor(state, id, hint)
    if record ~= nil then
      out[#out + 1] = record
    end
  end
  return out
end

---@param targets table<integer, table<string, unknown>> ordered target records under collection
---@param state table<string, unknown> live battle state under identity resolution
---@param id unknown combatant identity under collection
---@param activationHint unknown? entry token carried by the cause when the battler already left
local function collectTarget(targets, state, id, activationHint)
  local resolved = targetIdOf(id)
  if resolved == nil then
    return
  end
  local record = resolveActor(state, resolved, activationHint)
  if record ~= nil then
    targets[#targets + 1] = record
  end
end

---@param state table<string, unknown> live battle state under identity resolution
---@param kind unknown event kind selecting the target rule
---@param cause table<string, unknown> semantic cause carrying the ordering combatant
---@param payload table<string, unknown> event payload carrying the subject identities
---@param scope table<string, unknown>? executing strike scope carrying the sampled recipients
---@return table<integer, table<string, unknown>> ordered detached target records
local function targetsFor(state, kind, cause, payload, scope)
  local out = {} ---@type table<integer, table<string, unknown>>
  -- A replacement retires its departure: the prior occupant keeps the
  -- withdrawal while the arrival above owns the reveal. The departure
  -- already left, so its token travels on the cause beside the payload.
  if kind == "switch" then
    local hint = nil
    if type(cause.activation) == "number" then
      hint = cause.activation --[[@as integer]]
    end
    collectTarget(out, state, payload.from, hint)
    return out
  end
  if type(payload.target) == "number" then
    collectTarget(out, state, payload.target)
    return out
  end
  if
    type(payload.target) == "table" and type((payload.target --[[@as table<string, unknown>]]).combatant) == "number"
  then
    collectTarget(out, state, (payload.target --[[@as table<string, unknown>]]).combatant)
    return out
  end
  -- A move use without a single payload target (spread and self moves
  -- publish a recipient count there) names its sampled recipients from
  -- the executing scope; anything else stays targetless.
  if scope ~= nil and type(scope.targets) == "table" then
    for _, entry in
      ipairs(scope.targets --[[@as table<integer, unknown>]])
    do
      if
        type(entry) == "table" and type((entry --[[@as table<string, unknown>]]).combatant) == "number"
      then
        collectTarget(out, state, (entry --[[@as table<string, unknown>]]).combatant)
      end
    end
    return out
  end
  if type(payload.to) == "number" then
    collectTarget(out, state, payload.to)
    return out
  end
  if type(payload.combatant) == "number" then
    collectTarget(out, state, payload.combatant)
    return out
  end
  if type(payload.user) == "number" then
    collectTarget(out, state, payload.user)
    return out
  end
  if type(payload.resolved) == "number" then
    collectTarget(out, state, payload.resolved)
    return out
  end
  return out
end

---@param cause table<string, unknown> semantic cause carrying the executed move identity
---@param kind unknown event kind selecting the phase fact
---@param scope table<string, unknown>? executing strike scope carrying the requested move
---@param payload table<string, unknown> event-time semantic data
---@return table<string, unknown>? detached move facts, nil for non-move causes
local function moveFor(cause, kind, scope, payload)
  if type(cause.key) ~= "string" or cause.key == "" then
    return nil
  end
  local selected = cause.key --[[@as string]]
  local executed = cause.key --[[@as string]]
  if scope ~= nil then
    if type(scope.requestedMove) == "string" and scope.requestedMove ~= "" then
      selected = scope.requestedMove --[[@as string]]
    end
    if type(scope.executingMove) == "string" and scope.executingMove ~= "" then
      executed = scope.executingMove --[[@as string]]
    end
  end
  local move = {
    selected = selected,
    executed = executed,
    phase = kind == "charged" and "charge" or "direct",
  } --[[@as table<string, unknown>]]
  -- The resolved variable power snapshots only for its own execution:
  -- the pinned scope already proved its executing identity above, so
  -- the value rides beside the move pair as a detached number. Scopes
  -- without a resolved value omit the fact; malformed values fail
  -- loudly instead of publishing a guess.
  if scope ~= nil and scope.animationPower ~= nil then
    local resolved = scope.animationPower
    assert(
      type(resolved) == "number" and resolved % 1 == 0 and resolved >= 0 and resolved <= 65535,
      "resolved move power stays an unsigned sixteen-bit integer"
    )
    move.power = resolved --[[@as integer]]
  end
  if kind == "struck" then
    -- Sequence ordinals come from the move interpreter, so each target's
    -- multi-hit chain starts at one and carries its actual connected total.
    local ordinal = payload.sequenceHitIndex or payload.hitIndex or 1
    local total = payload.sequenceHitTotal or ordinal
    assert(type(ordinal) == "number" and ordinal % 1 == 0 and ordinal >= 1, "strike ordinals stay one-based")
    assert(type(total) == "number" and total % 1 == 0 and total >= ordinal, "strike totals cover their ordinal")
    move.hitOrdinal = ordinal
    move.hitCount = total
  end
  return move
end

---@param observation table<string, unknown> event-time checkpoint projection under ordering
---@return table<integer, table<string, unknown>> ordered displayed checkpoints with health facts
function PresentationFacts.checkpointsFor(observation)
  local out = {} ---@type table<integer, table<string, unknown>>
  if type(observation) ~= "table" then
    return out
  end
  local entries = (observation --[[@as table<string, unknown>]]).combatants
  if type(entries) ~= "table" then
    return out
  end
  local ids = {} ---@type integer[]
  for id, record in
    pairs(entries --[[@as table<integer, unknown>]])
  do
    if type(id) == "number" and type(record) == "table" then
      ids[#ids + 1] = id --[[@as integer]]
    end
  end
  table.sort(ids)
  for _, id in ipairs(ids) do
    local record = (entries --[[@as table<integer, table<string, unknown>>]])[id]
    if type(record.hp) == "number" and type(record.maxHp) == "number" then
      local point = {
        combatant = id,
        hp = record.hp,
        maxHp = record.maxHp,
      } --[[@as table<string, unknown>]]
      if type(record.position) == "number" then
        point.position = record.position
      end
      if type(record.activation) == "number" then
        point.activation = record.activation
      end
      if type(record.side) == "number" then
        point.side = record.side
      end
      if type(record.condition) == "string" then
        point.condition = record.condition
      end
      out[#out + 1] = point
    end
  end
  return out
end

-- Attaches the immutable playback facts beside the authoritative
-- payload: explicit actor/target identities, executed and selected move
-- identities with phase and hit ordinals, the playback route and its
-- suppression flags, the ordered display checkpoints, and the
-- independent visual seed. Existing payload, cause, and observation
-- fields are never rewritten, and present facts are never replaced, so
-- decoration cannot change mechanics, transcripts, or checksums.
---@param state table<string, unknown> live battle state under identity resolution
---@param event table<string, unknown> emitted event under decoration
---@param scope table<string, unknown>? executing strike scope carrying the authoritative user and recipients
---@return table<string, unknown> the same event carrying its playback facts
function PresentationFacts.decorate(state, event, scope)
  if type(state) ~= "table" or type(event) ~= "table" then
    return event
  end
  local kind = event.kind
  local cause = event.cause
  if type(cause) ~= "table" then
    cause = {}
  else
    cause = cause --[[@as table<string, unknown>]]
  end
  local payload = event.payload
  if type(payload) ~= "table" then
    payload = {}
  else
    payload = payload --[[@as table<string, unknown>]]
  end
  -- Move-ordered causes name their ordering move identity beside the
  -- lifecycle kind vocabulary, so every variant carries a typed cause
  -- without touching draws or the payload.
  if type(cause.key) == "string" and type(cause.kind) ~= "string" then
    cause.kind = "move"
  end
  -- The executing scope answers only for its own move: a stale scope
  -- from an earlier strike never lends its user to another move.
  local liveScope = nil
  if
    type(scope) == "table"
    and type(cause.key) == "string"
    and (scope --[[@as table<string, unknown>]]).executingMove == cause.key
  then
    liveScope = scope --[[@as table<string, unknown>]]
  end
  if event.actors == nil then
    event.actors = actorsFor(state, kind, cause, payload, liveScope)
  end
  if event.targets == nil then
    event.targets = targetsFor(state, kind, cause, payload, liveScope)
  end
  if event.move == nil then
    local move = moveFor(cause, kind, liveScope, payload)
    if move ~= nil then
      event.move = move
    end
  end
  if event.flowKey == nil then
    event.flowKey = PresentationFacts.flowKeyFor(kind)
  end
  if event.effectKey == nil then
    local executed = nil
    if type(event.move) == "table" then
      local move = event.move --[[@as table<string, unknown>]]
      if type(move.executed) == "string" then
        executed = move.executed --[[@as string]]
      end
    end
    local effect = PresentationFacts.effectKeyFor(kind, executed)
    if effect ~= nil then
      event.effectKey = effect
    end
  end
  if event.suppression == nil then
    local suppression = PresentationFacts.suppressionFor(kind)
    if suppression ~= nil then
      event.suppression = suppression
    end
  end
  if event.checkpoints == nil and type(event.observation) == "table" then
    event.checkpoints = PresentationFacts.checkpointsFor(event.observation --[[@as table<string, unknown>]])
  end
  if event.visualSeed == nil and type(event.sequence) == "number" then
    event.visualSeed = PresentationFacts.visualSeedFor(event.sequence)
  end
  return event
end

return PresentationFacts
