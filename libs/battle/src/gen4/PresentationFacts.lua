-- Private event-time playback facts for battle presentation. Native move
-- and lifecycle emitters capture authoritative actor, target, move, and
-- display-checkpoint identities at their mutation point; later playback
-- reads these captured facts instead of searching display order,
-- rereading live state, or replaying combat. The projection is pure over
-- the supplied state, cause, and payload: it draws nothing from the
-- combat, world, or visual random streams (visual variation flows only
-- from the screen-owned battle visual stream and the boot SPL stream)
-- and never changes damage, order, or legality.
-- Source references: the presentation commands in
-- src/battle/battle_command.c and the player controller in
-- src/battle/battle_controller_player.c.

---@class PresentationFacts
local PresentationFacts = {}

-- Root authority lives in the producer's semantic facts, never in
-- kind-derived tables: the selector reads event.presentation
-- execution and operation records. No route, phase, or suppression
-- mapping by event kind remains here.

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
  -- Invocation inputs the program reads but mechanics never recomputes
  -- for presentation: frozen strike-law weather and terrain plus the
  -- explicit friendship fact. Absent values stay absent; Flow never
  -- invents them for programs that do not read them.
  if scope ~= nil then
    if scope.weather ~= nil then
      assert(type(scope.weather) == "string", "frozen strike weather stays a named identity")
      local suppressed = scope.weatherSuppressed == true
      move.weather = suppressed and "none" or scope.weather --[[@as string]]
    end
    if scope.terrain ~= nil then
      assert(type(scope.terrain) == "string", "frozen terrain stays a named identity")
      move.terrain = scope.terrain --[[@as string]]
    end
    if scope.friendship ~= nil then
      local friendship = scope.friendship
      assert(
        type(friendship) == "number" and friendship % 1 == 0 and friendship >= 0 and friendship <= 255,
        "frozen friendship stays an unsigned byte"
      )
      move.friendship = friendship --[[@as integer]]
    end
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

-- Semantic weather identities by field-instance key. Overworld
-- environment weather uses the same spellings.
local WEATHER_BY_FIELD_KEY = {
  raindance = "rain",
  sunnyday = "sun",
  sandstorm = "sand",
  hail = "hail",
  fog = "fog",
}

-- Field-condition keys behind the source no-field-conditions
-- predicate. Suppressed weather does not count: the source zeroes
-- the whole field-condition value while suppression holds, so
-- suppressed rain normalizes to none with no conditions, while
-- Gravity alone keeps weather none with conditions present.
local FIELD_CONDITION_KEYS = {
  raindance = true,
  sunnyday = true,
  sandstorm = true,
  hail = true,
  fog = true,
  gravity = true,
  trickroom = true,
}

-- Closed execution-moment vocabulary behind one actual move call.
local EXECUTION_MOMENTS = {
  use = true,
  ["charge-start"] = true,
  ["charge-release"] = true,
  ["bide-release"] = true,
  ["transfer-complete"] = true,
  ["delayed-hit"] = true,
  ["focus-preparation"] = true,
  ["snatch-interception"] = true,
  ["pivot-departure"] = true,
}

-- Closed execution-branch vocabulary behind one actual move call.
local EXECUTION_BRANCHES = {
  default = true,
  ghost = true,
  healing = true,
  ["screens-broken"] = true,
  ["focused-strike"] = true,
}

---@param value unknown candidate plain fact under validation
---@param path string field path behind the diagnostic
local function checkPlain(value, path)
  local kind = type(value)
  if kind == "table" then
    if getmetatable(value) ~= nil then
      error("semantic facts carry no metatables at " .. path)
    end
    for key, item in pairs(value) do
      if type(key) ~= "string" and type(key) ~= "number" then
        error("semantic fact keys stay strings or array indices at " .. path)
      end
      checkPlain(item, path .. "." .. tostring(key))
    end
    return
  end
  if kind == "function" or kind == "thread" or kind == "userdata" then
    error("semantic facts carry no executable state at " .. path)
  end
  if kind == "number" and (value ~= value or math.abs(value) == math.huge) then
    error("semantic facts carry finite numbers at " .. path)
  end
end

---@param state table<string, unknown> live battle state under field-condition reads
---@return table<integer, string> field-kind condition keys behind the source predicate
local function fieldConditionKeys(state)
  local keys = {} ---@type table<integer, string>
  local bag = state.effectBag
  if type(bag) ~= "table" then
    return keys
  end
  local capture = bag.capture
  if type(capture) ~= "function" then
    return keys
  end
  local ok, records = pcall(capture, bag)
  if not ok or type(records) ~= "table" then
    return keys
  end
  for _, record in ipairs(records) do
    if type(record) == "table" then
      local entry = record --[[@as table<string, unknown>]]
      local scope = entry.scope
      if type(entry.key) == "string" and type(scope) == "table" and scope.kind == "field" then
        keys[#keys + 1] = entry.key --[[@as string]]
      end
    end
  end
  return keys
end

---@param state table<string, unknown> live battle state under identity resolution
---@param scope table<string, unknown>? executing strike scope carrying producer-frozen weather
---@return table<string, unknown> detached semantic battle/battler snapshot
local function captureContext(state, scope)
  local context = {} ---@type table<string, unknown>
  if type(state.format) == "string" and state.format ~= "" then
    context.battleFormat = state.format
  end
  context.isContest = false
  local weather = nil ---@type string?
  local suppressed = false
  local terrain = nil ---@type string?
  if type(scope) == "table" then
    if type(scope.weather) == "string" then
      weather = scope.weather --[[@as string]]
    end
    if scope.weatherSuppressed == true then
      suppressed = true
    end
    if type(scope.terrain) == "string" then
      terrain = scope.terrain --[[@as string]]
    end
  end
  if weather == nil then
    local environment = state.environment
    if type(environment) == "table" then
      local record = environment --[[@as table<string, unknown>]]
      if type(record.weather) == "string" and WEATHER_BY_FIELD_KEY[record.weather] ~= nil then
        weather = record.weather --[[@as string]]
      elseif
        record.weather == "rain"
        or record.weather == "sun"
        or record.weather == "sand"
        or record.weather == "hail"
        or record.weather == "fog"
      then
        weather = record.weather --[[@as string]]
      end
      if terrain == nil and type(record.terrain) == "string" then
        terrain = record.terrain --[[@as string]]
      end
    end
  end
  if weather == nil then
    local instances = fieldConditionKeys(state)
    for _, key in ipairs(instances) do
      local named = WEATHER_BY_FIELD_KEY[key]
      if named ~= nil then
        weather = named
        break
      end
    end
  end
  if type(weather) == "string" then
    context.effectiveWeather = suppressed and "none" or weather
    context.weatherSuppressed = suppressed
  end
  if type(terrain) == "string" then
    context.terrain = terrain
  end
  -- The source zeroes the whole field-condition value while a living
  -- Cloud Nine or Air Lock holder suppresses weather, so suppressed
  -- instances stop counting as conditions.
  local conditions = 0
  for _, key in ipairs(fieldConditionKeys(state)) do
    if FIELD_CONDITION_KEYS[key] == true and not (suppressed and WEATHER_BY_FIELD_KEY[key] ~= nil) then
      conditions = conditions + 1
    end
  end
  context.noFieldConditions = conditions == 0
  local battlers = {} ---@type table<integer, table<string, unknown>>
  local combatants = state.combatants
  if type(combatants) == "table" then
    local ids = {} ---@type integer[]
    for id, combatant in pairs(combatants) do
      if type(id) == "number" and id % 1 == 0 and type(combatant) == "table" then
        ids[#ids + 1] = id --[[@as integer]]
      end
    end
    table.sort(ids)
    local participants = state.participants
    for _, id in ipairs(ids) do
      local combatant = (combatants --[[@as table<integer, table<string, unknown>>]])[id]
      local binding = { combatant = id } ---@type table<string, unknown>
      if type(combatant.participant) == "number" then
        binding.participant = combatant.participant
        if type(participants) == "table" then
          local participant = (participants --[[@as table<integer, table<string, unknown>>]])[
            combatant.participant --[[@as integer]]
          ]
          if type(participant) == "table" and type(participant.side) == "number" then
            binding.side = participant.side
          end
        end
      end
      local active = combatant.active
      if type(active) == "table" then
        local entry = active --[[@as table<string, unknown>]]
        if type(entry.activation) == "number" then
          binding.activation = entry.activation
        end
        if type(entry.position) == "number" then
          binding.position = entry.position
        end
      end
      local substitute = false
      local bag = state.effectBag
      if type(bag) == "table" and type(bag.capture) == "function" then
        local ok, records = pcall(bag.capture, bag)
        if ok and type(records) == "table" then
          for _, record in ipairs(records) do
            if type(record) == "table" then
              local instance = record --[[@as table<string, unknown>]]
              local instanceScope = instance.scope
              if
                instance.key == "substitute"
                and type(instanceScope) == "table"
                and (instanceScope --[[@as table<string, unknown>]]).combatant == id
              then
                substitute = true
                break
              end
            end
          end
        end
      end
      binding.substitute = substitute
      local mon = combatant.mon
      if type(mon) == "table" then
        local appearance = {} ---@type table<string, unknown>
        local known = false
        if type(mon.species) == "string" then
          appearance.species = mon.species
          known = true
        end
        if type(mon.form) == "number" then
          appearance.form = mon.form
          known = true
        end
        if type(mon.personality) == "number" then
          appearance.personality = mon.personality
          known = true
        end
        local origin = mon.origin
        if type(origin) == "table" then
          local trainerId = (origin --[[@as table<string, unknown>]]).trainerId
          if type(trainerId) == "number" then
            appearance.origin = { trainerId = trainerId }
            known = true
          end
        end
        if known then
          binding.appearance = appearance
        end
      end
      battlers[#battlers + 1] = binding
    end
  end
  context.battlers = battlers
  return context
end

-- Semantic role behind one execution participant: a positive
-- combatant with its positive entry token.
---@param value unknown candidate role under validation
---@param path string field path behind the diagnostic
---@return table<string, unknown> detached role
local function checkSemanticRole(value, path)
  if type(value) ~= "table" then
    error("semantic roles stay records at " .. path)
  end
  local record = value --[[@as table<string, unknown>]]
  if type(record.combatant) ~= "number" or record.combatant % 1 ~= 0 or record.combatant < 1 then
    error("semantic roles name a positive combatant at " .. path)
  end
  if type(record.activation) ~= "number" or record.activation % 1 ~= 0 or record.activation < 1 then
    error("semantic execution roles carry a positive entry token at " .. path)
  end
  return { combatant = record.combatant, activation = record.activation }
end

-- Semantic role behind one operation participant: false activation is
-- allowed only for a non-active bag-item beneficiary or EXP recipient.
---@param value unknown candidate role under validation
---@param path string field path behind the diagnostic
---@return table<string, unknown> detached role
local function checkOperationSubject(value, path)
  if type(value) ~= "table" then
    error("semantic operation subjects stay records at " .. path)
  end
  local record = value --[[@as table<string, unknown>]]
  if type(record.combatant) ~= "number" or record.combatant % 1 ~= 0 or record.combatant < 1 then
    error("semantic operation subjects name a positive combatant at " .. path)
  end
  local activation = record.activation
  if activation ~= false then
    if type(activation) ~= "number" or activation % 1 ~= 0 or activation < 1 then
      error("semantic operation subjects carry a positive entry token or false at " .. path)
    end
  end
  return { combatant = record.combatant, activation = activation }
end

---@param value unknown candidate integer under validation
---@param bound integer inclusive upper bound
---@param path string field path behind the diagnostic
---@return integer the validated value
local function checkBoundedInt(value, bound, path)
  if type(value) ~= "number" or value % 1 ~= 0 or value < 0 or value > bound then
    error("semantic facts carry a 0.." .. tostring(bound) .. " integer at " .. path)
  end
  return value --[[@as integer]]
end

---@param value unknown candidate integer under validation
---@param path string field path behind the diagnostic
---@return integer the validated value
local function checkPositiveInt(value, path)
  if type(value) ~= "number" or value % 1 ~= 0 or value < 1 then
    error("semantic facts carry a positive integer at " .. path)
  end
  return value --[[@as integer]]
end

---@param value unknown candidate signed damage under validation
---@param path string field path behind the diagnostic
---@return integer the validated value
local function checkDamage(value, path)
  if type(value) ~= "number" or value % 1 ~= 0 or value < -2147483648 or value > 2147483647 then
    error("semantic execution damage stays a signed 32-bit integer at " .. path)
  end
  return value --[[@as integer]]
end

---@param value unknown candidate move record under execution validation
---@param path string field path behind the diagnostic
---@return table<string, unknown> detached execution moment
local function checkExecution(value, path)
  if type(value) ~= "table" then
    error("semantic execution moments stay records at " .. path)
  end
  local record = value --[[@as table<string, unknown>]]
  if type(record.selectedMove) ~= "string" or record.selectedMove == "" then
    error("semantic execution names its selected move at " .. path)
  end
  if type(record.executedMove) ~= "string" or record.executedMove == "" then
    error("semantic execution names its executed move at " .. path)
  end
  if type(record.moment) ~= "string" or EXECUTION_MOMENTS[record.moment] ~= true then
    error("semantic execution names a closed moment at " .. path)
  end
  if type(record.branch) ~= "string" or EXECUTION_BRANCHES[record.branch] ~= true then
    error("semantic execution names a closed branch at " .. path)
  end
  local out = {
    selectedMove = record.selectedMove,
    executedMove = record.executedMove,
    moment = record.moment,
    branch = record.branch,
    attacker = checkSemanticRole(record.attacker, path .. ".attacker"),
    defender = checkSemanticRole(record.defender, path .. ".defender"),
  } ---@type table<string, unknown>
  if type(record.targets) ~= "table" or #record.targets == 0 then
    error("semantic execution names a nonempty ordered target set at " .. path)
  end
  local targets = {} ---@type table<integer, table<string, unknown>>
  for index, target in ipairs(record.targets) do
    targets[index] = checkSemanticRole(target, path .. ".targets[" .. index .. "]")
  end
  out.targets = targets
  -- Unused damage/power/friendship fields may be absent only for the
  -- Focus Punch preparation moment, whose source call has not
  -- established them; ordinary actual-use moments carry all three.
  local focusPreparation = record.moment == "focus-preparation"
  if record.damage ~= nil or not focusPreparation then
    out.damage = checkDamage(record.damage, path .. ".damage")
  end
  if record.power ~= nil or not focusPreparation then
    out.power = checkBoundedInt(record.power, 65535, path .. ".power")
  end
  if record.friendship ~= nil or not focusPreparation then
    out.friendship = checkBoundedInt(record.friendship, 65535, path .. ".friendship")
  end
  local hasOrdinal = record.hitOrdinal ~= nil
  local hasCount = record.hitCount ~= nil
  local hasCycle = record.hitCycle ~= nil
  if hasOrdinal or hasCount or hasCycle then
    if not (hasOrdinal and hasCount and hasCycle) then
      error("semantic execution hit fields travel together at " .. path)
    end
    local ordinal = checkPositiveInt(record.hitOrdinal, path .. ".hitOrdinal")
    local count = checkPositiveInt(record.hitCount, path .. ".hitCount")
    if ordinal > count then
      error("semantic execution hit ordinals stay within their count at " .. path)
    end
    out.hitOrdinal = ordinal
    out.hitCount = count
    out.hitCycle = checkPositiveInt(record.hitCycle, path .. ".hitCycle")
  end
  if record.costEventSequence ~= nil then
    out.costEventSequence = checkPositiveInt(record.costEventSequence, path .. ".costEventSequence")
  end
  return out
end

-- Closed operation-condition vocabulary.
local OPERATION_CONDITIONS = {
  sleep = true,
  poison = true,
  toxic = true,
  burn = true,
  freeze = true,
  paralysis = true,
  confusion = true,
  infatuation = true,
}

-- Closed applied-item effect vocabulary.
local ITEM_EFFECTS = {
  ["hp-restore"] = true,
  ["status-cure"] = true,
  ["pp-restore"] = true,
  ["confusion-cure"] = true,
  ["all-status-cure"] = true,
  ["stat-boost"] = true,
  ["stat-sharp-boost"] = true,
  ["critical-boost"] = true,
  ["accuracy-boost"] = true,
  ["stat-reset"] = true,
  ["infatuation-cure"] = true,
  ["status-infliction"] = true,
  ["hp-harm"] = true,
  ["order-first"] = true,
  endure = true,
  resist = true,
  recoil = true,
  ["reflect-infatuation"] = true,
  ["skip-charge"] = true,
  mist = true,
  ["focus-energy"] = true,
}

---@param value unknown candidate operation record under validation
---@param path string field path behind the diagnostic
---@return table<string, unknown> detached semantic operation
local function checkOperation(value, path)
  if type(value) ~= "table" then
    error("semantic operations stay records at " .. path)
  end
  local record = value --[[@as table<string, unknown>]]
  if type(record.kind) ~= "string" or record.kind == "" then
    error("semantic operations name their kind at " .. path)
  end
  local kind = record.kind --[[@as string]]
  local out = {
    kind = kind,
    subject = checkOperationSubject(record.subject, path .. ".subject"),
  } ---@type table<string, unknown>
  local source = record.source
  if type(source) ~= "table" then
    error("semantic operations name their source at " .. path)
  end
  local origin = source --[[@as table<string, unknown>]]
  if
    origin.kind ~= "move"
    and origin.kind ~= "ability"
    and origin.kind ~= "item"
    and origin.kind ~= "weather"
    and origin.kind ~= "system"
  then
    error("semantic operation sources stay move, ability, item, weather, or system at " .. path)
  end
  if type(origin.key) ~= "string" or origin.key == "" then
    error("semantic operation sources name their key at " .. path)
  end
  local detachedSource = { kind = origin.kind, key = origin.key } ---@type table<string, unknown>
  if origin.actor ~= nil then
    detachedSource.actor = checkOperationSubject(origin.actor, path .. ".source.actor")
  elseif origin.kind == "move" or origin.kind == "ability" or origin.kind == "item" then
    error("semantic move, ability, and item sources name their actor at " .. path)
  end
  out.source = detachedSource
  if kind == "status-applied" then
    if OPERATION_CONDITIONS[record.condition] ~= true then
      error("semantic status applications name their condition at " .. path)
    end
    out.condition = record.condition
    if record.application ~= "standard" and record.application ~= "rest" then
      error("semantic status applications name standard or rest at " .. path)
    end
    out.application = record.application
    if record.itemEventSequence ~= nil then
      out.itemEventSequence = checkPositiveInt(record.itemEventSequence, path .. ".itemEventSequence")
    end
  elseif kind == "status-gate" then
    local condition = record.condition
    if
      condition ~= "sleep"
      and condition ~= "freeze"
      and condition ~= "paralysis"
      and condition ~= "confusion"
      and condition ~= "infatuation"
    then
      error("semantic status gates name their gate condition at " .. path)
    end
    out.condition = condition
    local outcome = record.outcome
    if
      outcome ~= "passed"
      and outcome ~= "blocked"
      and outcome ~= "self-hit"
      and outcome ~= "expired"
      and outcome ~= "cured"
    then
      error("semantic status gates name their gate outcome at " .. path)
    end
    out.outcome = outcome
  elseif kind == "confusion-applied" then
    if record.itemEventSequence ~= nil then
      out.itemEventSequence = checkPositiveInt(record.itemEventSequence, path .. ".itemEventSequence")
    end
  elseif kind == "stage-changed" then
    local stat = record.stat
    if
      stat ~= "attack"
      and stat ~= "defense"
      and stat ~= "speed"
      and stat ~= "specialAttack"
      and stat ~= "specialDefense"
      and stat ~= "accuracy"
      and stat ~= "evasion"
    then
      error("semantic stage changes name their stat at " .. path)
    end
    out.stat = stat
    for _, field in ipairs({ "before", "after" }) do
      local stage = record[field]
      if type(stage) ~= "number" or stage % 1 ~= 0 or stage < -6 or stage > 6 then
        error("semantic stage changes carry signed -6..6 stages at " .. path .. "." .. field)
      end
      out[field] = stage
    end
    if
      record.method ~= "delta"
      and record.method ~= "maximize"
      and record.method ~= "reset"
      and record.method ~= "copy"
    then
      error("semantic stage changes name their method at " .. path)
    end
    out.method = record.method
    if
      record.profile ~= "standard"
      and record.profile ~= "belly-drum"
      and record.profile ~= "anger-point"
      and record.profile ~= "motor-drive"
      and record.profile ~= "silent"
    then
      error("semantic stage changes name their profile at " .. path)
    end
    out.profile = record.profile
    out.groupFirstSequence = checkPositiveInt(record.groupFirstSequence, path .. ".groupFirstSequence")
    if type(record.feedbackOwner) ~= "boolean" then
      error("semantic stage changes name their feedback owner at " .. path)
    end
    out.feedbackOwner = record.feedbackOwner
  elseif kind == "item-applied" then
    if
      record.channel ~= "held"
      and record.channel ~= "bag"
      and record.channel ~= "thrown"
      and record.channel ~= "eaten"
    then
      error("semantic item applications name their channel at " .. path)
    end
    out.channel = record.channel
    if type(record.itemKey) ~= "string" or record.itemKey == "" then
      error("semantic item applications name their item at " .. path)
    end
    out.itemKey = record.itemKey
    if ITEM_EFFECTS[record.effect] ~= true then
      error("semantic item applications name their effect at " .. path)
    end
    out.effect = record.effect
    out.beneficiary = checkOperationSubject(record.beneficiary, path .. ".beneficiary")
    if type(record.feedbackOwner) ~= "boolean" then
      error("semantic item applications name their feedback owner at " .. path)
    end
    out.feedbackOwner = record.feedbackOwner
    if record.effect == "order-first" then
      if type(record.waitingBattlers) ~= "number" or record.waitingBattlers % 1 ~= 0 or record.waitingBattlers < 0 then
        error("semantic order-first items count their waiting battlers at " .. path)
      end
      out.waitingBattlers = record.waitingBattlers
    end
    if record.condition ~= nil then
      if OPERATION_CONDITIONS[record.condition] ~= true then
        error("semantic item applications name a known condition at " .. path)
      end
      out.condition = record.condition
    end
    if record.stat ~= nil then
      out.stat = record.stat
    end
    for _, field in ipairs({ "beforeStage", "afterStage" }) do
      if record[field] ~= nil then
        local stage = record[field]
        if type(stage) ~= "number" or stage % 1 ~= 0 or stage < -6 or stage > 6 then
          error("semantic item stage facts carry signed -6..6 stages at " .. path .. "." .. field)
        end
        out[field] = stage
      end
    end
  elseif kind == "hp-restored" then
    if
      record.profile ~= "ordinary"
      and record.profile ~= "weather-recovery"
      and record.profile ~= "rest"
      and record.profile ~= "roost"
      and record.profile ~= "present"
      and record.profile ~= "drain"
      and record.profile ~= "absorption"
    then
      error("semantic restorations name their profile at " .. path)
    end
    out.profile = record.profile
  elseif kind == "weather-started" then
    if WEATHER_BY_FIELD_KEY[record.weather] == nil and record.weather ~= "none" then
      local known = record.weather == "rain"
        or record.weather == "sun"
        or record.weather == "sand"
        or record.weather == "hail"
        or record.weather == "fog"
      if not known then
        error("semantic weather starts name their weather at " .. path)
      end
    end
    out.weather = record.weather
    if record.origin ~= "overworld" and record.origin ~= "entry-ability" and record.origin ~= "move" then
      error("semantic weather starts name their origin at " .. path)
    end
    out.origin = record.origin
  elseif kind == "weather-continued" then
    if
      record.weather ~= "rain"
      and record.weather ~= "sun"
      and record.weather ~= "sand"
      and record.weather ~= "hail"
      and record.weather ~= "fog"
    then
      error("semantic weather continuations name their weather at " .. path)
    end
    out.weather = record.weather
    out.passOrdinal = checkPositiveInt(record.passOrdinal, path .. ".passOrdinal")
  elseif kind == "residual" then
    if
      record.effect ~= "poison"
      and record.effect ~= "toxic"
      and record.effect ~= "burn"
      and record.effect ~= "curse"
      and record.effect ~= "nightmare"
      and record.effect ~= "leech-seed"
      and record.effect ~= "bind"
      and record.effect ~= "wish"
      and record.effect ~= "aqua-ring"
      and record.effect ~= "ingrain"
    then
      error("semantic residuals name their effect at " .. path)
    end
    out.effect = record.effect
    if record.effect == "bind" then
      if type(record.bindingMove) ~= "string" or record.bindingMove == "" then
        error("semantic binding residuals name their binding move at " .. path)
      end
      out.bindingMove = record.bindingMove
    end
    if record.effect == "leech-seed" then
      out.beneficiary = checkOperationSubject(record.beneficiary, path .. ".beneficiary")
      if record.transfer ~= "heal" and record.transfer ~= "liquid-ooze" and record.transfer ~= "none" then
        error("semantic leech-seed residuals name their transfer at " .. path)
      end
      out.transfer = record.transfer
    end
  elseif kind == "substitute-created" then
    out.costEventSequence = checkPositiveInt(record.costEventSequence, path .. ".costEventSequence")
  elseif kind == "substitute-hit" then
    if type(record.broken) ~= "boolean" then
      error("semantic substitute hits name their break at " .. path)
    end
    out.broken = record.broken
  elseif kind == "transform-applied" then
    out.donor = checkSemanticRole(record.donor, path .. ".donor")
    local input = record.donorAppearanceInput
    if type(input) ~= "table" then
      error("semantic transform operations carry their donor appearance at " .. path)
    end
    local appearance = input --[[@as table<string, unknown>]]
    if type(appearance.species) ~= "string" or appearance.species == "" then
      error("semantic donor appearance names its species at " .. path)
    end
    if
      type(appearance.form) ~= "number"
      or appearance.form % 1 ~= 0
      or appearance.form < 0
      or appearance.form > 255
    then
      error("semantic donor appearance carries a 0..255 form at " .. path)
    end
    if
      type(appearance.personality) ~= "number"
      or appearance.personality % 1 ~= 0
      or appearance.personality < 0
      or appearance.personality > 4294967295
    then
      error("semantic donor appearance carries its personality at " .. path)
    end
    local donorOrigin = appearance.origin
    if
      type(donorOrigin) ~= "table" or type((donorOrigin --[[@as table<string, unknown>]]).trainerId) ~= "number"
    then
      error("semantic donor appearance carries its origin trainer at " .. path)
    end
    out.donorAppearanceInput = {
      species = appearance.species,
      form = appearance.form,
      personality = appearance.personality,
      origin = {
        trainerId = (donorOrigin --[[@as table<string, unknown>]]).trainerId,
      },
    }
  elseif kind == "switch-ready" then
    if record.reason ~= "u-turn" and record.reason ~= "baton-pass" then
      error("semantic switch readiness names its reason at " .. path)
    end
    out.reason = record.reason
    out.departing = checkSemanticRole(record.departing, path .. ".departing")
    out.position = checkPositiveInt(record.position, path .. ".position")
  elseif kind == "switch-applied" then
    if
      record.reason ~= "ordinary"
      and record.reason ~= "forced"
      and record.reason ~= "u-turn"
      and record.reason ~= "baton-pass"
    then
      error("semantic switch applications name their reason at " .. path)
    end
    out.reason = record.reason
    out.departing = checkSemanticRole(record.departing, path .. ".departing")
    out.incoming = checkSemanticRole(record.incoming, path .. ".incoming")
    if record.reason == "u-turn" or record.reason == "baton-pass" then
      out.readyEventSequence = checkPositiveInt(record.readyEventSequence, path .. ".readyEventSequence")
    end
  elseif kind == "entry-ready" then
    if record.entryKind ~= "opening" and record.entryKind ~= "replacement" then
      error("semantic entry readiness names its entry kind at " .. path)
    end
    out.entryKind = record.entryKind
    if record.entryStage ~= "before-cry" and record.entryStage ~= "after-picture" then
      error("semantic entry readiness names its entry stage at " .. path)
    end
    out.entryStage = record.entryStage
  elseif kind == "experience-awarded" then
    if type(record.active) ~= "boolean" then
      error("semantic experience awards name their recipient activity at " .. path)
    end
    out.active = record.active
    if type(record.boundaries) ~= "table" then
      error("semantic experience awards carry their level boundaries at " .. path)
    end
    local boundaries = {} ---@type table<integer, table<string, unknown>>
    for index, boundary in ipairs(record.boundaries) do
      if type(boundary) ~= "table" then
        error("semantic experience boundaries stay records at " .. path)
      end
      local segment = boundary --[[@as table<string, unknown>]]
      local fromLevel = segment.fromLevel
      local toLevel = segment.toLevel
      if
        type(fromLevel) ~= "number"
        or fromLevel % 1 ~= 0
        or fromLevel < 1
        or fromLevel > 99
        or type(toLevel) ~= "number"
        or toLevel % 1 ~= 0
        or toLevel ~= fromLevel + 1
      then
        error("semantic experience boundaries step one level at " .. path .. "[" .. index .. "]")
      end
      boundaries[index] = {
        fromLevel = fromLevel,
        toLevel = toLevel,
        expSegment = checkPositiveInt(segment.expSegment, path .. ".boundaries[" .. index .. "].expSegment"),
      }
    end
    out.boundaries = boundaries
  elseif kind == "item-escape" then
    if record.itemKey ~= "POKE_DOLL" and record.itemKey ~= "FLUFFY_TAIL" then
      error("semantic item escapes name their escape item at " .. path)
    end
    out.itemKey = record.itemKey
  elseif kind == "health-cost" then
    if
      record.reason ~= "belly-drum"
      and record.reason ~= "ghost-curse"
      and record.reason ~= "substitute"
      and record.reason ~= "healing-wish"
      and record.reason ~= "lunar-dance"
    then
      error("semantic health costs name their reason at " .. path)
    end
    out.reason = record.reason
    if record.relation ~= "follows-owner" and record.relation ~= "precedes-use" then
      error("semantic health costs name their cost relation at " .. path)
    end
    out.relation = record.relation
    if record.relation == "follows-owner" then
      out.ownerEventSequence = checkPositiveInt(record.ownerEventSequence, path .. ".ownerEventSequence")
    end
  else
    error("semantic operations name a closed operation kind at " .. path .. ": " .. tostring(kind))
  end
  return out
end

---@param value unknown candidate health-change list under validation
---@param path string field path behind the diagnostic
---@return table<integer, table<string, unknown>> detached health changes
local function checkHealthChanges(value, path)
  if type(value) ~= "table" then
    error("semantic health changes stay arrays at " .. path)
  end
  local changes = {} ---@type table<integer, table<string, unknown>>
  for index, change in ipairs(value) do
    if type(change) ~= "table" then
      error("semantic health changes stay records at " .. path .. "[" .. index .. "]")
    end
    local record = change --[[@as table<string, unknown>]]
    local entry = {
      combatant = checkPositiveInt(record.combatant, path .. "[" .. index .. "].combatant"),
    } ---@type table<string, unknown>
    if record.activation ~= nil then
      entry.activation = checkPositiveInt(record.activation, path .. "[" .. index .. "].activation")
    end
    for _, field in ipairs({ "before", "after", "maxHp" }) do
      local point = record[field]
      if type(point) ~= "number" or point % 1 ~= 0 or point < 0 then
        error(
          "semantic health changes carry non-negative integer checkpoints at " .. path .. "[" .. index .. "]." .. field
        )
      end
      entry[field] = point
    end
    if record.kind ~= "body" and record.kind ~= "substitute" then
      error("semantic health changes distinguish body from substitute at " .. path .. "[" .. index .. "]")
    end
    entry.kind = record.kind
    changes[index] = entry
  end
  return changes
end

-- Projects the detached semantic presentation facts behind one event:
-- the frozen context snapshot plus the producer's optional execution
-- moment, applied operation, and ordered health changes. Only plain
-- data travels; functions, metatables, and non-finite numbers fail
-- before they can reach the selector. The first changed stat of a
-- source group may omit its group sequence; it fills with the
-- assigned event sequence before validation.
---@param state table<string, unknown> live battle state under context capture
---@param scope table<string, unknown>? executing strike scope carrying producer-frozen inputs
---@param facts table<string, unknown>? optional producer semantic facts
---@param sequence integer? assigned kernel event sequence behind group ownership
---@return table<string, unknown> detached presentation facts
function PresentationFacts.projectPresentation(state, scope, facts, sequence)
  local presentation = { context = captureContext(state, scope) } ---@type table<string, unknown>
  if facts ~= nil then
    if type(facts) ~= "table" then
      error("semantic facts stay records")
    end
    checkPlain(facts, "facts")
    if facts.execution ~= nil then
      presentation.execution = checkExecution(facts.execution, "facts.execution")
    end
    if facts.operation ~= nil then
      local operation = facts.operation --[[@as table<string, unknown>]]
      if operation.kind == "stage-changed" and operation.groupFirstSequence == nil then
        if type(sequence) ~= "number" or sequence % 1 ~= 0 or sequence < 1 then
          error("semantic stage groups fill their group sequence from a positive event sequence")
        end
        -- Fill a detached copy: the producer's input record stays
        -- untouched while validation reads the completed shape.
        local filled = {}
        for key, value in pairs(operation) do
          filled[key] = value
        end
        filled.groupFirstSequence = sequence
        operation = filled --[[@as table<string, unknown>]]
      end
      presentation.operation = checkOperation(operation, "facts.operation")
    end
    if facts.healthChanges ~= nil then
      presentation.healthChanges = checkHealthChanges(facts.healthChanges, "facts.healthChanges")
    end
    local operation = presentation.operation
    if
      type(operation) == "table" and (operation --[[@as table<string, unknown>]]).kind == "health-cost"
    then
      local changes = presentation.healthChanges
      if type(changes) ~= "table" or #changes ~= 1 or changes[1].kind ~= "body" then
        error("semantic health costs carry exactly one body health change")
      end
    end
  end
  return presentation
end

-- Validates one detached presentation projection at an event boundary:
-- the frozen context plus the optional closed execution, operation,
-- and health-change records. Existing events without presentation
-- stay valid.
---@param presentation unknown candidate presentation facts under validation
function PresentationFacts.checkPresentation(presentation)
  if type(presentation) ~= "table" then
    error("battle event presentation stays a record")
  end
  local record = presentation --[[@as table<string, unknown>]]
  if type(record.context) ~= "table" then
    error("battle event presentation carries its frozen context")
  end
  if record.execution ~= nil then
    checkExecution(record.execution, "presentation.execution")
  end
  if record.operation ~= nil then
    checkOperation(record.operation, "presentation.operation")
  end
  if record.healthChanges ~= nil then
    checkHealthChanges(record.healthChanges, "presentation.healthChanges")
  end
end

-- Attaches the immutable playback facts beside the authoritative
-- payload: explicit actor/target identities, executed and selected move
-- identities with phase and hit ordinals, the playback route and its
-- suppression flags, the ordered display checkpoints, and the
-- detached semantic presentation facts the animation selector reads.
-- Existing payload, cause, and observation fields are never rewritten,
-- and present facts are never replaced, so decoration cannot change
-- mechanics, transcripts, or checksums.
---@param state table<string, unknown> live battle state under identity resolution
---@param event table<string, unknown> emitted event under decoration
---@param scope table<string, unknown>? executing strike scope carrying the authoritative user and recipients
---@param facts table<string, unknown>? optional producer semantic facts behind the presentation projection
---@return table<string, unknown> the same event carrying its playback facts
function PresentationFacts.decorate(state, event, scope, facts)
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
  -- No kind-derived route, effect, or suppression writes: root
  -- authority lives in the producer's semantic facts, which the
  -- selector below reads from event.presentation. Legacy descriptive
  -- move, actor, target, and checkpoint facts stay for narration
  -- and topology, but they never select an animation root.
  if event.checkpoints == nil and type(event.observation) == "table" then
    event.checkpoints = PresentationFacts.checkpointsFor(event.observation --[[@as table<string, unknown>]])
  end
  -- Occurrence-derived seeds never enter the animation path: visual
  -- variation flows only from the screen-owned battle visual stream
  -- and the boot SPL stream, never from event identity arithmetic.
  -- A carried seed is stripped before it can reach animation cues.
  event.visualSeed = nil
  event.presentation = PresentationFacts.projectPresentation(state, liveScope, facts, event.sequence)
  return event
end

return PresentationFacts
