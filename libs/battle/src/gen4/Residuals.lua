-- Native residual continuation: one end-of-turn pass over the ordered
-- residual candidates. Each battler walks an explicit controller phase
-- order -- ingrain, aqua ring, ability, consumable holding, gradual
-- holding, leech seed, poison, bad poison, burn, then the remaining mon
-- states -- with field conditions ahead of the first battler and the
-- field-extra states behind the last, through the shared finite
-- dispatch; each committed phase is followed at once by its faint, and a
-- fainted combatant's later phases stay silent while survivors still
-- tick. The pass suspends on an operation budget and restores exactly
-- behind its saved battler and phase cursor, so budgeted suspension and
-- snapshot restore never repeat completed work. Attribution stored on an
-- instance outlives a departed source because dispatch never rewrites it.

local BattleErrors = require("libs.battle.src.errors")
local TurnOrder = require("libs.battle.src.gen4.TurnOrder")

---@class ResidualSpeeds
---@field speeds table<integer, integer> sampled speed per combatant
---@field health table<integer, integer> battle-local health per combatant
---@field stream table<string, unknown>? labeled battle stream for rolled ticks
---@field suppressedIds table<integer, boolean>? instances muted for this pass
---@field resume ResidualFrame? continuation of a suspended pass
---@field turnOrder integer[]? sampled battler order, authoritative when present
---@field trickRoom boolean? speed-dimension sense for derived battler order
---@field nativeTurn integer? current battle turn beside the pass, informational
---@field live ResidualLiveHooks? live battler answers behind the ability, holding, and condition phases

-- Field-condition phase order: the field controller walks reflect, light
-- screen, mist, safeguard, tail wind, lucky chant, wish, rain, sandstorm,
-- sun, hail, fog, then gravity. Only keys with reachable residual
-- instances participate; absent families are skipped, never invented.
local FIELD_STATE_ORDER = {
  reflect = 1,
  lightscreen = 2,
  mist = 3,
  safeguard = 4,
  tailwind = 5,
  luckychant = 6,
  wish = 7,
  raindance = 8,
  sandstorm = 9,
  sunnyday = 10,
  hail = 11,
  gravity = 12,
}

-- Per-battler mon-condition phase order: the mon controller walks ingrain,
-- aqua ring, ability, held item, leftovers recovery, leech seed, poison,
-- bad poison, burn, nightmare, curse, binding, bad dreams, uproar, thrash,
-- disable, encore, lock-on, charge, taunt, magnet rise, heal block,
-- embargo, then yawn. Bad poison travels under the toxic key; slots with
-- no reachable instance never execute. The table below ranks only finite
-- keys for deterministic within-phase dispatch; MON_PHASES is the
-- execution order and carries the ability and holding phases that own no
-- finite key.
local MON_STATE_ORDER = {
  ingrain = 1,
  aquaring = 2,
  leechseed = 3,
  poison = 4,
  toxic = 5,
  burn = 6,
  nightmare = 7,
  curse = 8,
  bind = 9,
  magnetrise = 10,
}

-- Execution order for one battler's mon conditions. Ability, consumable
-- holding, and gradual holding phases have no finite key: the session
-- answers them through its live hooks, while absent hooks leave those
-- phases silent. Poison, bad poison, and burn phases share their slot
-- with the canonical condition tick for the same key.
local MON_PHASES = {
  "ingrain",
  "aquaring",
  "ability",
  "held_item",
  "leftovers",
  "leechseed",
  "poison",
  "toxic",
  "burn",
  "nightmare",
  "curse",
  "bind",
  "magnetrise",
}

-- Finite keys answering inside a battler phase. Keys without a slot here
-- trail the pass as extensions.
local FINITE_MON_PHASE = {
  ingrain = "ingrain",
  aquaring = "aquaring",
  leechseed = "leechseed",
  poison = "poison",
  toxic = "toxic",
  burn = "burn",
  nightmare = "nightmare",
  curse = "curse",
  bind = "bind",
  magnetrise = "magnetrise",
}

-- Canonical affliction key behind each status phase.
local STATUS_PHASE_KEY = {
  poison = "poison",
  toxic = "toxic",
  burn = "burn",
}

-- Field-extra phase order: the extra controller walks future sight,
-- perish song, then trick room.
local EXTRA_STATE_ORDER = {
  futuresight = 1,
  perishsong = 2,
  trickroom = 3,
}

---@class ResidualFrame
---@field kind string
---@field version integer
---@field checkpoint table<string, unknown>? finite-dispatch continuation, absent when the pass finished
---@field fainted integer[] combatants settled before the cursor, in order
---@field battlers integer[]? frozen battler order for a suspended pass, absent on legacy fresh frames
---@field cursor integer? one-based position of the next uncommitted group, past the end when done
---@field battler integer? battler position behind the cursor: 0 for the field preamble, count + 1 for the tail
---@field phase string? phase identity behind the cursor

---@class ResidualLiveHooks
---@field ability fun(combatant: integer): table<string, unknown>? live ability answer, nil when the holder carries none
---@field heldItem fun(combatant: integer): table<string, unknown>? live consumable holding answer, nil when nothing answers
---@field leftovers fun(combatant: integer): table<string, unknown>? live gradual holding answer, nil when nothing answers
---@field condition fun(combatant: integer, key: string): table<string, unknown>? canonical affliction tick, nil when the holder carries another key

---@class ResidualOutcome
---@field events table<string, unknown>[]
---@field done boolean
---@field frame ResidualFrame

---@class ResidualDispatchView
---@field collect fun(self: ResidualDispatchView, timing: string, context: table<string, unknown>): table<integer, table<string, unknown>>
---@field invoke fun(self: ResidualDispatchView, timing: string, context: table<string, unknown>, budget: integer?): table<string, unknown>

local Residuals = {}

Residuals.KIND = "gen4:residuals"
Residuals.VERSION = 1

---@param frame unknown
---@return ResidualFrame
function Residuals.validateFrame(frame)
  if type(frame) ~= "table" then
    error(BattleErrors.incompatibleSnapshot("residual frames are records", {}))
  end
  assert(type(frame) == "table", "residual frame validated above")
  if frame.kind ~= Residuals.KIND then
    error(BattleErrors.incompatibleSnapshot("residual frames carry the native residual identity", {}))
  end
  if frame.version ~= Residuals.VERSION then
    error(BattleErrors.incompatibleSnapshot("residual frames carry the current version", {}))
  end
  if frame.checkpoint ~= nil and type(frame.checkpoint) ~= "table" then
    error(BattleErrors.incompatibleSnapshot("residual frames carry a dispatch continuation or none", {}))
  end
  if type(frame.fainted) ~= "table" then
    error(BattleErrors.incompatibleSnapshot("residual frames carry their settled combatants", {}))
  end
  for index, combatant in ipairs(frame.fainted) do
    if type(combatant) ~= "number" then
      error(BattleErrors.incompatibleSnapshot("residual frames settle combatant identities", { index = index }))
    end
  end
  if frame.battlers ~= nil then
    if type(frame.battlers) ~= "table" then
      error(BattleErrors.incompatibleSnapshot("residual frames freeze their battler order as an array", {}))
    end
    local order = frame.battlers --[[@as table<integer, unknown>]]
    for index = 1, #order do
      local combatant = order[index]
      if type(combatant) ~= "number" or combatant % 1 ~= 0 or combatant < 1 then
        error(BattleErrors.incompatibleSnapshot("residual frames name combatant identities", { index = index }))
      end
    end
  end
  if frame.cursor ~= nil then
    if type(frame.cursor) ~= "number" or frame.cursor % 1 ~= 0 or frame.cursor < 1 then
      error(BattleErrors.incompatibleSnapshot("residual frames cursor their next group", {}))
    end
  end
  if frame.battler ~= nil and type(frame.battler) ~= "number" then
    error(BattleErrors.incompatibleSnapshot("residual frames cursor their battler position", {}))
  end
  if frame.phase ~= nil and type(frame.phase) ~= "string" then
    error(BattleErrors.incompatibleSnapshot("residual frames cursor their phase identity", {}))
  end
  return frame --[[@as ResidualFrame]]
end

---@param context ResidualSpeeds
---@return integer[] battler identities in sampled turn order
local function residualBattlerOrder(context)
  if context.turnOrder ~= nil then
    if type(context.turnOrder) ~= "table" then
      error(BattleErrors.invalidState("residual passes sequence explicit battler order as an array", {}))
    end
    local explicit = context.turnOrder --[[@as table<integer, unknown>]]
    local count = 0
    for key in pairs(explicit) do
      if type(key) ~= "number" or key % 1 ~= 0 or key < 1 then
        error(BattleErrors.invalidState("residual battler order carries dense positions", {}))
      end
      count = count + 1
    end
    local order = {} ---@type integer[]
    local seen = {}
    for index = 1, count do
      local combatant = explicit[index]
      if type(combatant) ~= "number" or combatant % 1 ~= 0 or combatant < 1 then
        error(BattleErrors.invalidState("residual battler order names combatant identities", { index = index }))
      end
      if seen[combatant] == true then
        error(BattleErrors.invalidState("residual battler order names each battler once", { index = index }))
      end
      seen[combatant] = true
      order[#order + 1] = combatant
    end
    return order
  end
  local speeds = context.speeds
  if type(speeds) ~= "table" then
    return {}
  end
  local entries = {} ---@type table<integer, table<string, integer>>
  for combatant, speed in
    pairs(speeds --[[@as table<integer, unknown>]])
  do
    if type(combatant) == "number" and type(speed) == "number" then
      entries[#entries + 1] = { id = combatant, speed = speed }
    end
  end
  local stream = context.stream
  if
    type(stream) ~= "table" or type((stream --[[@as table<string, unknown>]]).nextU16) ~= "function"
  then
    error(BattleErrors.invalidState("residual battler ties draw from the battle stream", {}))
  end
  local ordered = TurnOrder.orderResiduals(entries, { trickRoom = context.trickRoom == true }, stream)
  local order = {} ---@type integer[]
  for _, entry in ipairs(ordered) do
    order[#order + 1] = entry.id
  end
  return order
end

---@class PlannedResidual
---@field phase integer controller phase: field, mon, extra, then unknown
---@field primary number battler position or state order within the phase
---@field secondary number state order or collection position within the battler
---@field tertiary integer creation ordinal
---@field id integer residual instance identity

---@param group PlannedResidual[] planned entries under ordering
local function sortPlanned(group)
  table.sort(group, function(a, b)
    if a.phase ~= b.phase then
      return a.phase < b.phase
    end
    if a.primary ~= b.primary then
      return a.primary < b.primary
    end
    if a.secondary ~= b.secondary then
      return a.secondary < b.secondary
    end
    if a.tertiary ~= b.tertiary then
      return a.tertiary < b.tertiary
    end
    return a.id < b.id
  end)
end

---@param instance table<string, unknown> collected residual instance under planning
---@return integer creation ordinal for deterministic same-state order
local function plannedCreated(instance)
  local created = instance.createdOrdinal
  if type(created) ~= "number" or created % 1 ~= 0 then
    error(BattleErrors.invalidState("residual plans read creation ordinals", { key = instance.key }))
  end
  return created --[[@as integer]]
end

---@param collected table<integer, table<string, unknown>> collected residual entries under planning
---@param battlerOrder integer[] battler identities in sampled turn order
---@return table<integer, integer> explicit position per planned instance identity
local function planResidualOrder(collected, battlerOrder)
  local battlerIndex = {}
  for position, combatant in ipairs(battlerOrder) do
    battlerIndex[combatant] = position
  end
  local planned = {} ---@type PlannedResidual[]
  for at, entry in ipairs(collected) do
    local instance = entry.instance --[[@as table<string, unknown>]]
    local key = instance.key --[[@as string]]
    local created = plannedCreated(instance)
    local fieldOrder = FIELD_STATE_ORDER[key]
    if fieldOrder ~= nil then
      planned[#planned + 1] = {
        phase = 1,
        primary = fieldOrder,
        secondary = created,
        tertiary = created,
        id = instance.id --[[@as integer]],
      }
    else
      local monOrder = MON_STATE_ORDER[key]
      if monOrder ~= nil then
        local scope = instance.scope
        if
          type(scope) ~= "table" or type((scope --[[@as table<string, unknown>]]).combatant) ~= "number"
        then
          error(BattleErrors.invalidState("mon-condition residuals scope their battler", { key = key }))
        end
        local combatant = (scope --[[@as table<string, unknown>]]).combatant --[[@as integer]]
        local position = battlerIndex[combatant]
        if position == nil then
          -- Dormant carry-policy instances outlive their entry while
          -- benched; they trail silently until re-anchored instead of
          -- failing the pass their handler already skips.
          planned[#planned + 1] = {
            phase = 4,
            primary = 0,
            secondary = at,
            tertiary = created,
            id = instance.id --[[@as integer]],
          }
        else
          planned[#planned + 1] = {
            phase = 2,
            primary = position,
            secondary = monOrder,
            tertiary = created,
            id = instance.id --[[@as integer]],
          }
        end
      else
        local extraOrder = EXTRA_STATE_ORDER[key]
        if extraOrder ~= nil then
          local tiebreak = math.huge
          local scope = instance.scope
          if type(scope) == "table" then
            local combatant = (scope --[[@as table<string, unknown>]]).combatant
            if type(combatant) == "number" and battlerIndex[combatant] ~= nil then
              tiebreak = battlerIndex[combatant]
            end
          end
          planned[#planned + 1] = {
            phase = 3,
            primary = extraOrder,
            secondary = tiebreak,
            tertiary = created,
            id = instance.id --[[@as integer]],
          }
        else
          -- Extension instances without a native source slot never jump
          -- ahead of a known state; they keep their dispatch fallback
          -- relative order behind every planned entry.
          planned[#planned + 1] = {
            phase = 4,
            primary = 1,
            secondary = at,
            tertiary = created,
            id = instance.id --[[@as integer]],
          }
        end
      end
    end
  end
  sortPlanned(planned)
  local ordinals = {}
  for position, entry in ipairs(planned) do
    ordinals[entry.id] = position
  end
  return ordinals
end

---@param health table<integer, integer>
---@param fainted table<integer, boolean>
---@param ordered integer[] settled combatants in first-seen order
---@param combatant integer newly settled combatant identity
local function markFainted(health, fainted, ordered, combatant)
  if fainted[combatant] == nil then
    fainted[combatant] = true
    ordered[#ordered + 1] = combatant
    health[combatant] = 0
  end
end

---@param context ResidualSpeeds
---@return table<integer, integer> battle-local health under the pass
local function checkHealth(context)
  if type(context.health) ~= "table" then
    error(BattleErrors.invalidState("residual passes read battle-local health", {}))
  end
  return context.health --[[@as table<integer, integer>]]
end

---@param context ResidualSpeeds
---@return ResidualLiveHooks? live battler answers behind the ability, holding, and condition phases
local function checkLiveHooks(context)
  local live = context.live
  if live == nil then
    return nil
  end
  if type(live) ~= "table" then
    error(BattleErrors.invalidState("residual live answers travel as a record", {}))
  end
  local hooks = live --[[@as table<string, unknown>]]
  for _, name in ipairs({ "ability", "heldItem", "leftovers", "condition" }) do
    if type(hooks[name]) ~= "function" then
      error(BattleErrors.invalidState("residual live answers bind every battler phase", { phase = name }))
    end
  end
  return live --[[@as ResidualLiveHooks]]
end

---@param ranks table<string, integer> controller order per state key
---@return string[] state keys in controller order
local function orderedKeys(ranks)
  local keyed = {} ---@type table<integer, { key: string, rank: integer }>
  for key, rank in pairs(ranks) do
    keyed[#keyed + 1] = { key = key, rank = rank }
  end
  table.sort(keyed, function(left, right)
    return left.rank < right.rank
  end)
  local keys = {} ---@type string[]
  for _, entry in ipairs(keyed) do
    keys[#keys + 1] = entry.key
  end
  return keys
end

---@type string[] field-condition keys in controller order
local FIELD_PHASES = orderedKeys(FIELD_STATE_ORDER)

---@type string[] field-extra keys in controller order
local EXTRA_PHASES = orderedKeys(EXTRA_STATE_ORDER)

---@class ResidualGroup
---@field region string field preamble, battler, or tail
---@field battler integer battler position: 0 for the field preamble, count + 1 for the tail
---@field phase string phase identity inside the region

---@param battlers integer[] frozen battler order for the pass
---@return integer group count: field preamble, every battler phase, tail, and the trailing extension slot
local function groupCount(battlers)
  return #FIELD_PHASES + #battlers * #MON_PHASES + #EXTRA_PHASES + 1
end

---@param battlers integer[] frozen battler order for the pass
---@param index integer one-based position of the group
---@return ResidualGroup the group behind the position
local function groupAt(battlers, index)
  assert(type(index) == "number" and index % 1 == 0 and index >= 1, "residual groups cursor from one")
  if index <= #FIELD_PHASES then
    return { region = "field", battler = 0, phase = FIELD_PHASES[index] }
  end
  local monGroups = index - #FIELD_PHASES
  local span = #battlers * #MON_PHASES
  if monGroups <= span then
    local zero = monGroups - 1
    local position = math.floor(zero / #MON_PHASES) + 1
    return { region = "mon", battler = position, phase = MON_PHASES[(zero % #MON_PHASES) + 1] }
  end
  local tailGroups = monGroups - span
  if tailGroups <= #EXTRA_PHASES then
    return { region = "tail", battler = #battlers + 1, phase = EXTRA_PHASES[tailGroups] }
  end
  return { region = "tail", battler = #battlers + 1, phase = "unknown" }
end

---@param instance table<string, unknown> collected residual instance under mapping
---@param battlerIndex table<integer, integer> frozen position per battler identity
---@return boolean true when the instance owns a controller slot this pass
local function mappedInstance(instance, battlerIndex)
  local key = instance.key --[[@as string]]
  if FIELD_STATE_ORDER[key] ~= nil or EXTRA_STATE_ORDER[key] ~= nil then
    return true
  end
  if FINITE_MON_PHASE[key] == nil then
    return false
  end
  local scope = instance.scope
  return type(scope) == "table" and battlerIndex[
    (scope --[[@as table<string, unknown>]]).combatant
  ] ~= nil
end

---@param collected table<integer, table<string, unknown>> collected residual entries under mapping
---@param group ResidualGroup group under execution
---@param battlers integer[] frozen battler order for the pass
---@param battlerIndex table<integer, integer> frozen position per battler identity
---@return table<integer, boolean> collected instance identities answering inside the group
local function groupInstanceIds(collected, group, battlers, battlerIndex)
  local ids = {}
  local holder = nil
  if group.region == "mon" then
    holder = battlers[group.battler]
  end
  for _, entry in ipairs(collected) do
    local instance = entry.instance
    if type(instance) == "table" and type(instance.id) == "number" then
      local key = instance.key --[[@as string]]
      if group.region == "tail" and group.phase == "unknown" then
        if
          not mappedInstance(instance --[[@as table<string, unknown>]], battlerIndex)
        then
          ids[
            instance.id --[[@as integer]]
          ] = true
        end
      elseif group.region == "field" or group.region == "tail" then
        if key == group.phase then
          ids[
            instance.id --[[@as integer]]
          ] = true
        end
      elseif FINITE_MON_PHASE[key] == group.phase then
        local scope = instance.scope
        if
          type(scope) == "table" and (scope --[[@as table<string, unknown>]]).combatant == holder
        then
          ids[
            instance.id --[[@as integer]]
          ] = true
        end
      end
    end
  end
  return ids
end

---@param frame ResidualFrame validated continuation under resume
---@return integer[] frozen battler order for the pass
---@return integer one-based position of the next uncommitted group
local function checkResumeFrame(frame)
  if type(frame.battlers) ~= "table" then
    error(BattleErrors.incompatibleSnapshot("resumed passes carry their frozen battler order", {}))
  end
  if type(frame.cursor) ~= "number" or frame.cursor % 1 ~= 0 or frame.cursor < 1 then
    error(BattleErrors.incompatibleSnapshot("resumed passes cursor their next group", {}))
  end
  if type(frame.battler) ~= "number" or type(frame.phase) ~= "string" then
    error(BattleErrors.incompatibleSnapshot("resumed passes cursor their battler and phase", {}))
  end
  local battlers = {} ---@type integer[]
  for index = 1, #frame.battlers do
    battlers[index] = frame.battlers[index]
  end
  local total = groupCount(battlers)
  if frame.cursor > total + 1 then
    error(BattleErrors.incompatibleSnapshot("resumed passes cursor inside their group plan", {}))
  end
  if frame.cursor <= total then
    local group = groupAt(battlers, frame.cursor --[[@as integer]])
    if group.battler ~= frame.battler or group.phase ~= frame.phase then
      error(BattleErrors.incompatibleSnapshot("resumed passes resume behind their saved cursor", {}))
    end
  end
  return battlers, frame.cursor --[[@as integer]]
end

---@param health table<integer, integer> battle-local health under the pass
---@param speeds table<integer, integer>? sampled speed per combatant
---@param fainted table<integer, boolean> combatants settled before the cursor
---@param ordered integer[] settled combatants in first-seen order
---@param events table<string, unknown>[] pass events under emission
local function scanFaints(health, speeds, fainted, ordered, events)
  local order = {} ---@type integer[]
  for combatant in pairs(health) do
    assert(type(combatant) == "number" and combatant % 1 == 0, "residual health is keyed by combatant identity")
    order[#order + 1] = combatant
  end
  table.sort(order, function(left, right)
    local leftSpeed = 0
    local rightSpeed = 0
    if type(speeds) == "table" then
      if type(speeds[left]) == "number" then
        leftSpeed = speeds[left]
      end
      if type(speeds[right]) == "number" then
        rightSpeed = speeds[right]
      end
    end
    if leftSpeed ~= rightSpeed then
      return leftSpeed > rightSpeed
    end
    return left < right
  end)
  for _, combatant in ipairs(order) do
    local hp = health[combatant]
    if type(hp) == "number" and hp <= 0 and fainted[combatant] == nil then
      markFainted(health, fainted, ordered, combatant)
      events[#events + 1] = { kind = "faint", combatant = combatant }
    end
  end
end

--- Runs the residual pass to completion or to its operation budget, where
--- one unit is one committed battler phase or one invoked finite instance.
--- A fresh pass freezes battler order once; every battler then walks the
--- explicit phase order while field conditions precede the first battler
--- and field-extra states follow the last. Non-applicable phases advance
--- the cursor without emitting events, and faint markers interleave
--- immediately after their killing phase; restoring mid-pass resumes
--- behind the saved battler and phase cursor with completed phases never
--- running twice.
---@param dispatch ResidualDispatchView finite dispatch owning residual collection and liveness
---@param context ResidualSpeeds pass context; resume continues a suspended pass
---@param budget integer? committed phases this call may spend before yielding
---@return ResidualOutcome pass events with its completion flag and frame
function Residuals.step(dispatch, context, budget)
  assert(type(dispatch) == "table", "residual passes run through the finite dispatch")
  assert(
    type(dispatch.collect) == "function" and type(dispatch.invoke) == "function",
    "residual passes collect and invoke one timing"
  )
  assert(type(context) == "table", "residual passes carry their pass context")
  local health = checkHealth(context)
  local live = checkLiveHooks(context)
  local allowance = budget
  if allowance ~= nil then
    assert(
      type(allowance) == "number" and allowance % 1 == 0 and allowance >= 1,
      "residual passes spend a positive operation budget"
    )
  end
  local battlers = {}
  local cursor = 1
  local checkpoint = nil
  local fainted = {}
  local ordered = {}
  if context.resume ~= nil then
    local frame = Residuals.validateFrame(context.resume)
    battlers, cursor = checkResumeFrame(frame)
    checkpoint = frame.checkpoint
    for _, combatant in ipairs(frame.fainted) do
      markFainted(health, fainted, ordered, combatant)
    end
  else
    battlers = residualBattlerOrder(context)
  end
  for combatant, hp in pairs(health) do
    if type(combatant) == "number" and type(hp) == "number" and hp <= 0 then
      markFainted(health, fainted, ordered, combatant)
    end
  end
  -- Collected membership is stable across the pass: handlers mutate
  -- state but never add or remove instances, so every group maps one
  -- fresh collection against the frozen battler order without spending
  -- another tie draw.
  local collected = dispatch:collect("residual", context)
  local ordinals = planResidualOrder(collected, battlers)
  local battlerIndex = {}
  for position, combatant in ipairs(battlers) do
    battlerIndex[combatant] = position
  end
  local total = groupCount(battlers)
  local holderOf = {} ---@type table<integer, integer>
  for _, entry in ipairs(collected) do
    local instance = entry.instance
    if type(instance) == "table" and type(instance.id) == "number" then
      local scope = instance.scope
      if
        type(scope) == "table" and type((scope --[[@as table<string, unknown>]]).combatant) == "number"
      then
        holderOf[
          instance.id --[[@as integer]]
        ] = (scope --[[@as table<string, unknown>]]).combatant --[[@as integer]]
      end
    end
  end
  local events = {}
  local done = cursor > total
  while (allowance == nil or allowance >= 1) and not done do
    local group = groupAt(battlers, cursor)
    local spent = 0
    local invoked = false
    local runnable = true
    if group.region == "mon" then
      local holder = battlers[group.battler]
      local hp = health[holder]
      if type(hp) ~= "number" then
        error(BattleErrors.invalidState("residual passes read battle-local health", { combatant = holder }))
      end
      -- Holders that left the field after settlement never answer
      -- later phases; survivors still tick.
      runnable = hp > 0
    end
    local liveEvents = nil
    if runnable and live ~= nil and group.region == "mon" then
      local holder = battlers[group.battler]
      local answer = nil
      if group.phase == "ability" then
        answer = live.ability(holder)
      elseif group.phase == "held_item" then
        answer = live.heldItem(holder)
      elseif group.phase == "leftovers" then
        answer = live.leftovers(holder)
      elseif STATUS_PHASE_KEY[group.phase] ~= nil then
        answer = live.condition(holder, STATUS_PHASE_KEY[group.phase] --[[@as string]])
      end
      if answer ~= nil then
        if type(answer) ~= "table" or type(answer.events) ~= "table" then
          error(BattleErrors.invalidState("residual live answers carry their events", { phase = group.phase }))
        end
        liveEvents = answer.events --[[@as table<integer, table<string, unknown>>]]
      end
    end
    local outcome = nil
    if runnable then
      local wanted = groupInstanceIds(collected, group, battlers, battlerIndex)
      local usable = false
      for id in pairs(wanted) do
        local scopeHolder = holderOf[id]
        if type(scopeHolder) ~= "number" or fainted[scopeHolder] ~= true then
          usable = true
          break
        end
      end
      if usable or checkpoint ~= nil then
        local suppressed = {}
        for _, entry in ipairs(collected) do
          local instance = entry.instance
          if type(instance) == "table" and type(instance.id) == "number" then
            local id = instance.id --[[@as integer]]
            local scope = instance.scope
            local holderFainted = type(scope) == "table"
              and type((scope --[[@as table<string, unknown>]]).combatant) == "number"
              and fainted[
                  (scope --[[@as table<string, unknown>]]).combatant --[[@as integer]]
                ]
                == true
            if wanted[id] ~= true or holderFainted then
              suppressed[id] = true
            end
          end
        end
        local inner = {
          speeds = context.speeds,
          health = context.health,
          stream = context.stream,
          suppressedIds = suppressed,
          resume = checkpoint,
          orderOrdinal = ordinals,
        }
        outcome = dispatch:invoke("residual", inner, 1)
        if type(outcome) ~= "table" or type(outcome.events) ~= "table" then
          error(BattleErrors.invalidState("residual passes consume dispatch outcomes", {}))
        end
        invoked = true
      end
    end
    local freshEvents = 0
    if liveEvents ~= nil then
      for _, event in ipairs(liveEvents) do
        events[#events + 1] = event
        freshEvents = freshEvents + 1
      end
      spent = spent + 1
    end
    if outcome ~= nil then
      for _, event in ipairs(outcome.events) do
        events[#events + 1] = event
        freshEvents = freshEvents + 1
      end
      checkpoint = outcome.checkpoint
      if outcome.done == true then
        cursor = cursor + 1
      else
        spent = spent + 1
      end
      if outcome.done == true and freshEvents > 0 then
        spent = spent + 1
      end
    else
      cursor = cursor + 1
    end
    if liveEvents ~= nil or invoked then
      scanFaints(health, context.speeds, fainted, ordered, events)
    end
    if allowance ~= nil then
      allowance = allowance - spent
    end
    done = cursor > total
  end
  local closing = groupAt(battlers, math.min(cursor, total))
  local held = {}
  for index, combatant in ipairs(battlers) do
    held[index] = combatant
  end
  return {
    events = events,
    done = done,
    frame = {
      kind = Residuals.KIND,
      version = Residuals.VERSION,
      checkpoint = checkpoint,
      fainted = ordered,
      battlers = held,
      cursor = cursor,
      battler = closing.battler,
      phase = closing.phase,
    },
  }
end

return Residuals
