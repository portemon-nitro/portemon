-- Native residual continuation: one end-of-turn pass over the ordered
-- residual candidates. Ticks traverse in controller phase order -- field
-- conditions, then every mon condition for one battler before the next in
-- sampled turn order, then the field-extra states -- through the shared
-- finite dispatch; each killing tick is followed at once by its faint
-- without ending the phase early, and a fainted combatant's later
-- instances stay silent while survivors still tick. The pass suspends on
-- an operation budget and restores exactly behind its saved cursor, so
-- budgeted suspension and snapshot restore never repeat completed work.
-- Attribution stored on an instance outlives a departed source because
-- dispatch never rewrites it.

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
-- no reachable instance never execute.
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

--- Runs the residual pass to completion or to its operation budget, where
--- one unit is one invoked instance. Faint events interleave immediately
--- after their killing tick; restoring mid-pass resumes behind the saved
--- cursor with completed ticks never running twice.
---@param dispatch ResidualDispatchView finite dispatch owning residual collection and liveness
---@param context ResidualSpeeds pass context; resume continues a suspended pass
---@param budget integer? invoked instances this call may spend before yielding
---@return ResidualOutcome pass events with its completion flag and frame
function Residuals.step(dispatch, context, budget)
  assert(type(dispatch) == "table", "residual passes run through the finite dispatch")
  assert(
    type(dispatch.collect) == "function" and type(dispatch.invoke) == "function",
    "residual passes collect and invoke one timing"
  )
  assert(type(context) == "table", "residual passes carry their pass context")
  local health = checkHealth(context)
  local allowance = budget
  if allowance ~= nil then
    assert(
      type(allowance) == "number" and allowance % 1 == 0 and allowance >= 1,
      "residual passes spend a positive operation budget"
    )
  end
  local checkpoint = nil
  local fainted = {}
  local ordered = {}
  local resumeHoldsCursor = false
  if context.resume ~= nil then
    local frame = Residuals.validateFrame(context.resume)
    checkpoint = frame.checkpoint
    for _, combatant in ipairs(frame.fainted) do
      markFainted(health, fainted, ordered, combatant)
    end
    resumeHoldsCursor = frame.checkpoint ~= nil
  end
  for combatant, hp in pairs(health) do
    if type(combatant) == "number" and type(hp) == "number" and hp <= 0 then
      markFainted(health, fainted, ordered, combatant)
    end
  end
  -- The controller phase plan is built once per fresh pass and travels
  -- with the dispatch checkpoint afterwards, so resuming behind a saved
  -- cursor never re-derives battler order or spends another tie draw.
  local ordinals = nil
  local plannedEntries = nil
  if not resumeHoldsCursor then
    plannedEntries = dispatch:collect("residual", context)
    ordinals = planResidualOrder(plannedEntries, residualBattlerOrder(context))
  end
  local suppressed = {}
  local visible = plannedEntries
  if visible == nil then
    visible = dispatch:collect("residual", context)
  end
  for _, entry in ipairs(visible) do
    local instance = entry.instance
    if
      type(instance) == "table"
      and type(instance.scope) == "table"
      and type(instance.scope.combatant) == "number"
      and fainted[instance.scope.combatant] == true
    then
      suppressed[instance.id] = true
    end
  end
  local events = {}
  local done = false
  while (allowance == nil or allowance >= 1) and not done do
    local inner = {
      speeds = context.speeds,
      health = context.health,
      stream = context.stream,
      suppressedIds = suppressed,
      resume = checkpoint,
      orderOrdinal = ordinals,
    }
    local outcome = dispatch:invoke("residual", inner, 1)
    if type(outcome) ~= "table" or type(outcome.events) ~= "table" then
      error(BattleErrors.invalidState("residual passes consume dispatch outcomes", {}))
    end
    for _, event in ipairs(outcome.events) do
      events[#events + 1] = event
    end
    checkpoint = outcome.checkpoint
    done = outcome.done == true
    local order = {} ---@type integer[]
    for combatant in pairs(health) do
      assert(type(combatant) == "number" and combatant % 1 == 0, "residual health is keyed by combatant identity")
      order[#order + 1] = combatant
    end
    local speeds = context.speeds
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
        for _, entry in ipairs(dispatch:collect("residual", context)) do
          local instance = entry.instance
          if
            type(instance) == "table"
            and type(instance.scope) == "table"
            and instance.scope.combatant == combatant
          then
            suppressed[instance.id] = true
          end
        end
      end
    end
    if allowance ~= nil then
      allowance = allowance - 1
    end
  end
  return {
    events = events,
    done = done,
    frame = { kind = Residuals.KIND, version = Residuals.VERSION, checkpoint = checkpoint, fainted = ordered },
  }
end

return Residuals
