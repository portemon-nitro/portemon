-- Concrete native battle topology and consequence policies. Each policy
-- owns the alliance layout, per-format action vocabulary, target scoping,
-- and result consequences for one native battle kind, so the generic
-- session never hard-codes a fixed combatant count or a shared consequence
-- table. Controller, party, and inventory authority stay separate facts:
-- allied participants may share a side without ever sharing a roster or an
-- inventory handle, and native party limits are enforced here rather than
-- by a global array bound. Facility and link bindings cover only the
-- battle-level restoration, reward, and legality consequences; owning the
-- surrounding facility progression or networking stays with their owners.

local BattleErrors = require("libs.battle.src.errors")

---@class BattleFormatDefinition
---@field key string format identity this policy binds
---@field stateVersion integer version of the policy shape
---@field actionKinds string[] admitted action vocabulary for the format
---@field validateScenario fun(scenario: table<string, unknown>)
---@field actionBudgets fun(ctx: table<string, unknown>): FormatActionBudget[]
---@field resolveTargets fun(ctx: table<string, unknown>, action: table<string, unknown>): table<string, unknown>
---@field checkOutcome fun(ctx: table<string, unknown>): table<string, unknown>?
---@field resultPolicy BattleResultPolicy
---@field joinPolicy BattleJoinPolicy?

---@class BattleResultPolicy
---@field restoration string party restoration owed once the battle closes
---@field reward string reward handling owed once the battle closes
---@field legality string legality regime the format validates under

---@class BattleJoinPolicy
---@field dynamicJoins boolean true when mid-battle joins may stage
---@field newcomerActsThisTurn boolean true when a joined combatant answers the open batch
---@field boundary string settlement boundary staging a join requires

---@class FormatActionBudget
---@field actor CombatantRef roster identity answering under this budget
---@field allowedActionKinds string[]
---@field count integer

---@class JoinRequest
---@field reason string
---@field participant table<string, unknown>?
---@field combatants table<integer, unknown>[]
---@field positions table<integer, unknown>[]
---@field settlementBoundary string

local NativeFormats = {}

NativeFormats.STATE_VERSION = 1

local STANDARD_KINDS = { "attack", "switch", "confirm", "item" }
local TARGET_KINDS = { position = true, combatant = true, side = true, field = true, none = true }

---@param kinds string[]
---@return string[] a detached copy of the admitted vocabulary
local function copyKinds(kinds)
  local out = {}
  for _, kind in ipairs(kinds) do
    out[#out + 1] = kind
  end
  return out
end

---@param scenario unknown battle setup record under validation
---@param format string format key reporting the violation
---@return table<string, unknown> the scenario as a record
local function checkRecord(scenario, format)
  if type(scenario) ~= "table" then
    error(BattleErrors.input(format .. " scenarios must be records", { format = format }))
  end
  local record = scenario --[[@as table<string, unknown>]]
  for _, field in ipairs({ "sides", "participants", "positions" }) do
    if type(record[field]) ~= "table" then
      error(BattleErrors.input(format .. " scenarios must carry " .. field, { format = format }))
    end
  end
  return record
end

---@param scenario table<string, unknown> battle setup record under validation
---@return table<integer, integer> occupied positions per side
---@return integer total occupied positions
local function occupiedBySide(scenario)
  local counts = {}
  local total = 0
  for _, entry in
    ipairs(scenario.positions --[[@as table<integer, unknown>]])
  do
    local position = entry --[[@as table<string, unknown>]]
    if position.occupant ~= nil then
      local side = position.side --[[@as integer]]
      counts[side] = (counts[side] or 0) + 1
      total = total + 1
    end
  end
  return counts, total
end

---@param scenario table<string, unknown> battle setup record under validation
---@param format string format key reporting the violation
---@param perSide integer occupied positions every side must hold
---@param sideCount integer sides the layout must declare
local function requireEvenField(scenario, format, perSide, sideCount)
  local sides = scenario.sides --[[@as table<integer, unknown>]]
  if #sides ~= sideCount then
    error(BattleErrors.input(format .. " declares exactly " .. sideCount .. " sides", { format = format }))
  end
  local counts, total = occupiedBySide(scenario)
  if total ~= perSide * sideCount then
    error(
      BattleErrors.input(
        format .. " holds " .. perSide .. " active combatant(s) per side",
        { format = format, total = total }
      )
    )
  end
  for _, entry in ipairs(sides) do
    local side = entry --[[@as table<string, unknown>]]
    if
      (
        counts[
          side.id --[[@as integer]]
        ] or 0
      ) ~= perSide
    then
      error(BattleErrors.input(format .. " keeps every side at " .. perSide .. " active slot(s)", {
        format = format,
        side = side.id,
      }))
    end
  end
end

---@param scenario table<string, unknown> battle setup record under validation
---@param format string format key reporting the violation
local function requireSeparatedInventories(scenario, format)
  local seen = {}
  for _, entry in
    ipairs(scenario.participants --[[@as table<integer, unknown>]])
  do
    local participant = entry --[[@as table<string, unknown>]]
    local inventoryId = participant.inventoryId
    if inventoryId ~= nil then
      assert(type(inventoryId) == "string", "participant inventory handles are named")
      if seen[inventoryId] ~= nil then
        error(BattleErrors.input(format .. " never shares one inventory across participants", {
          format = format,
          inventory = inventoryId,
        }))
      end
      seen[inventoryId] = participant.id
    end
  end
end

---@param scenario table<string, unknown> battle setup record under validation
---@return boolean true when some side fields at least two participants
local function hasAllianceSide(scenario)
  for _, entry in
    ipairs(scenario.sides --[[@as table<integer, unknown>]])
  do
    local side = entry --[[@as table<string, unknown>]]
    local members = side.participants --[[@as table<integer, unknown>]]
    if #members >= 2 then
      return true
    end
  end
  return false
end

---@param raw unknown battle setup record under validation
local function validateSinglesField(raw)
  local scenario = checkRecord(raw, "singles")
  requireEvenField(scenario, "singles", 1, 2)
  requireSeparatedInventories(scenario, "singles")
end

---@param raw unknown battle setup record under validation
local function validateDoublesField(raw)
  local scenario = checkRecord(raw, "doubles")
  requireEvenField(scenario, "doubles", 2, 2)
  requireSeparatedInventories(scenario, "doubles")
end

---@param raw unknown battle setup record under validation
local function validateMultiField(raw)
  local scenario = checkRecord(raw, "multi")
  if not hasAllianceSide(scenario) then
    error(BattleErrors.input("multi fields an allied side of at least two participants", { format = "multi" }))
  end
  requireSeparatedInventories(scenario, "multi")
  local counts, total = occupiedBySide(scenario)
  if total < 3 then
    error(BattleErrors.input("multi holds at least three active combatants", { format = "multi", total = total }))
  end
  for side, count in pairs(counts) do
    if count < 1 then
      error(BattleErrors.input("multi keeps every side active", { format = "multi", side = side }))
    end
  end
end

---@param raw unknown battle setup record under validation
local function validatePartnerField(raw)
  local scenario = checkRecord(raw, "partner")
  local record = checkRecord(scenario, "partner")
  local sides = record.sides --[[@as table<integer, unknown>]]
  if #sides ~= 2 then
    error(BattleErrors.input("partner declares exactly 2 sides", { format = "partner" }))
  end
  local first = sides[1] --[[@as table<string, unknown>]]
  if
    #first.participants --[[@as table<integer, unknown>]]
    ~= 2
  then
    error(BattleErrors.input("partner fields the player pair on the first side", { format = "partner" }))
  end
  requireEvenField(record, "partner", 2, 2)
  requireSeparatedInventories(record, "partner")
end

---@param raw unknown battle setup record under validation
local function validateFacilityField(raw)
  local scenario = checkRecord(raw, "facility")
  requireEvenField(scenario, "facility", 1, 2)
  requireSeparatedInventories(scenario, "facility")
end

---@param raw unknown battle setup record under validation
local function validateLinkField(raw)
  local scenario = checkRecord(raw, "link")
  requireEvenField(scenario, "link", 1, 2)
  requireSeparatedInventories(scenario, "link")
end

---@param raw unknown battle setup record under validation
local function validateRaidField(raw)
  local scenario = checkRecord(raw, "raid")
  local sides = scenario.sides --[[@as table<integer, unknown>]]
  if #sides ~= 2 then
    error(BattleErrors.input("raid declares exactly 2 sides", { format = "raid" }))
  end
  requireSeparatedInventories(scenario, "raid")
  local counts, total = occupiedBySide(scenario)
  if total < 5 then
    error(
      BattleErrors.input("raid fields at least five simultaneous active combatants", { format = "raid", total = total })
    )
  end
  local smallest, largest = total, 0
  local smallSides = 0
  for _, entry in ipairs(sides) do
    local side = entry --[[@as table<string, unknown>]]
    local count = counts[
      side.id --[[@as integer]]
    ] or 0
    if count < smallest then
      smallest = count
    end
    if count > largest then
      largest = count
    end
    if count == 1 then
      smallSides = smallSides + 1
    end
  end
  if smallest == largest or smallSides ~= 1 then
    error(BattleErrors.input("raid opposes one lone boss side asymmetrically", { format = "raid" }))
  end
end

---@param key string format identity under construction
---@param validate fun(raw: unknown) topology validation owning the format layout
---@param resultPolicy BattleResultPolicy consequence policy bound to the format
---@param joinPolicy BattleJoinPolicy join policy bound to the format
---@param actionKinds string[]? admitted action vocabulary, standard when absent
---@return BattleFormatDefinition the concrete native format policy
local function defineFormat(key, validate, resultPolicy, joinPolicy, actionKinds)
  local kinds = copyKinds(actionKinds or STANDARD_KINDS)
  local policy = {
    key = key,
    stateVersion = NativeFormats.STATE_VERSION,
    actionKinds = kinds,
  }
  ---@param raw unknown battle setup record under validation
  local function validateScenario(raw)
    validate(raw)
  end
  ---@param ctx table<string, unknown> budget context carrying actors and extra boss actions
  ---@return FormatActionBudget[] one explicit budget per addressed actor
  local function actionBudgets(ctx)
    assert(type(ctx) == "table", key .. " budgets require their context")
    local actors = ctx.actors
    if actors == nil then
      return {}
    end
    assert(type(actors) == "table", key .. " budgets address an actor array")
    local extra = ctx.extraActions
    if extra ~= nil then
      assert(type(extra) == "table", key .. " boss budgets arrive as a record")
    end
    local budgets = {}
    for _, entry in
      ipairs(actors --[[@as table<integer, unknown>]])
    do
      local actor = entry --[[@as table<string, unknown>]]
      assert(type(actor.combatant) == "number", key .. " budgets name their combatant")
      local bonus = 0
      if extra ~= nil then
        bonus = extra[
          actor.combatant --[[@as integer]]
        ] or 0
        assert(type(bonus) == "number" and bonus % 1 == 0 and bonus >= 0, key .. " bonus actions stay integral")
      end
      budgets[#budgets + 1] = {
        actor = { combatant = actor.combatant, activation = actor.activation },
        allowedActionKinds = copyKinds(kinds),
        count = 1 + bonus,
      }
    end
    return budgets
  end
  ---@param _ table<string, unknown> format context, unused by native scoping
  ---@param action table<string, unknown> battle action carrying its target
  ---@return table<string, unknown> the format-level target plan
  local function resolveTargets(_, action)
    assert(type(action) == "table", key .. " target resolution requires its action")
    local target = (action --[[@as table<string, unknown>]]).target
    if type(target) ~= "table" then
      error(BattleErrors.input(key .. " actions must carry their target", { format = key }))
    end
    local kind = (target --[[@as table<string, unknown>]]).kind
    if
      TARGET_KINDS[
        kind --[[@as string]]
      ] == nil
    then
      error(BattleErrors.input(key .. " actions must name a known target kind", { format = key }))
    end
    local plan = { scope = kind, target = {} }
    for name, value in
      pairs(target --[[@as table<string, unknown>]])
    do
      plan.target[name] = value
    end
    return plan
  end
  ---@param _ table<string, unknown> format context, unused by native terminal rules
  ---@return table<string, unknown>? no native format ends a battle by itself
  local function checkOutcome(_)
    return nil
  end
  policy.validateScenario = validateScenario
  policy.actionBudgets = actionBudgets
  policy.resolveTargets = resolveTargets
  policy.checkOutcome = checkOutcome
  policy.resultPolicy = resultPolicy
  policy.joinPolicy = joinPolicy
  return policy --[[@as BattleFormatDefinition]]
end

---@return table<string, BattleFormatDefinition> fresh native policy bindings
local function buildPolicies()
  return {
    singles = defineFormat("singles", validateSinglesField, {
      restoration = "full",
      reward = "standard",
      legality = "standard",
    }, { dynamicJoins = false, newcomerActsThisTurn = false, boundary = "none" }),
    doubles = defineFormat("doubles", validateDoublesField, {
      restoration = "full",
      reward = "standard",
      legality = "doubles",
    }, { dynamicJoins = false, newcomerActsThisTurn = false, boundary = "none" }),
    multi = defineFormat("multi", validateMultiField, {
      restoration = "full",
      reward = "shared",
      legality = "multi",
    }, { dynamicJoins = false, newcomerActsThisTurn = false, boundary = "none" }),
    partner = defineFormat("partner", validatePartnerField, {
      restoration = "full",
      reward = "shared",
      legality = "partner",
    }, { dynamicJoins = false, newcomerActsThisTurn = false, boundary = "none" }),
    facility = defineFormat("facility", validateFacilityField, {
      restoration = "facility",
      reward = "facility",
      legality = "facility",
    }, { dynamicJoins = false, newcomerActsThisTurn = false, boundary = "none" }),
    link = defineFormat("link", validateLinkField, {
      restoration = "full",
      reward = "none",
      legality = "link",
    }, { dynamicJoins = false, newcomerActsThisTurn = false, boundary = "none" }),
    raid = defineFormat("raid", validateRaidField, {
      restoration = "full",
      reward = "raid",
      legality = "raid",
    }, { dynamicJoins = true, newcomerActsThisTurn = false, boundary = "round-end" }),
  }
end

local POLICIES = buildPolicies()

--- Binds the concrete native topology and consequence policies. The
--- returned table maps each native format key to its policy; wrappers are
--- fresh per call while the policies themselves stay canonical.
---@return table<string, BattleFormatDefinition> native policies keyed by format key
function NativeFormats.register()
  local bound = {}
  for key, policy in pairs(POLICIES) do
    bound[key] = policy
  end
  return bound
end

--- Resolves the native policy bound for the format key.
---@param key string format identity under lookup
---@return BattleFormatDefinition the policy bound for the key
function NativeFormats.policyFor(key)
  if type(key) ~= "string" then
    error(BattleErrors.input("native formats resolve through string keys", {}))
  end
  local policy = POLICIES[key]
  if policy == nil then
    error(BattleErrors.missingBehavior("unknown native format " .. key, { format = key }))
  end
  return policy
end

--- Validates a detached scenario against the named native topology and
--- consequence policy. Returns true when the layout validates and raises
--- otherwise; invalid layouts never run silently.
---@param key string native format identity under validation
---@param scenario unknown detached battle setup record under validation
---@return boolean true when the scenario validates under the policy
function NativeFormats.validateScenario(key, scenario)
  NativeFormats.policyFor(key).validateScenario(scenario)
  return true
end

return NativeFormats
