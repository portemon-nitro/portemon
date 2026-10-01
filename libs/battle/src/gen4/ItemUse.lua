-- Battle Bag item planning and execution over caller-owned battle state.
-- A choice names an inventory owner, an item key, and a combatant holder.
-- Planning validates the choice against declared stock minus outstanding
-- reservations and reports a deterministic consumption checkpoint with
-- its effect operations; it never consumes, books hidden reservations,
-- touches the live Bag, or draws. Execution revalidates the plan against
-- live battle state at the native checkpoint, consumes exactly one unit
-- into the battle-owned ledger, applies the planned operations, and
-- stamps the plan so rerunning it fails. Refused, stale, repeated, and
-- malformed plans raise typed failures with zero ledger, stock, random,
-- or live side effects.

local Errors = require("libs.errors.src.Errors")
local CaptureContext = require("libs.battle.src.gen4.CaptureContext")

local ItemUse = {}

ItemUse.CONSUMPTION_CHECKPOINT = "item_use"
ItemUse.HEAL_AMOUNT = 20

---@class BattleItemTarget
---@field kind string target vocabulary, combatant for holder use
---@field combatant integer? holder identity for combatant targets

---@class BattleItemChoice
---@field inventoryId string battle inventory owner of the shared stack
---@field item string item key requested from the shared stack
---@field target BattleItemTarget chosen holder
---@field moveSlot integer? zero-based move slot for PP use

---@class BattleItemEffectOperation
---@field kind string operation vocabulary, heal for restorative use and capture for thrown balls
---@field amount integer? fixed restoration of heal operations, nil for capture work
---@field target BattleItemTarget holder the operation applies to

---@class ItemUsePlan
---@field item string? requested item key, nil for malformed choices
---@field inventoryId string? requested inventory owner, nil for malformed choices
---@field target BattleItemTarget detached copy of the chosen holder
---@field effectOperations BattleItemEffectOperation[] planned operations, empty when refused
---@field consumptionCheckpoint string checkpoint stamping the later consumption
---@field failureReason string? refusal code, nil for executable plans
---@field executed boolean? exactly-once stamp written by execution

---@param target unknown candidate holder target under inspection
---@return BattleItemTarget detached copy of the holder target
local function copyTarget(target)
  assert(type(target) == "table", "battle item targets travel as records")
  local copied = target --[[@as BattleItemTarget]]
  return { kind = copied.kind, combatant = copied.combatant }
end

---@param view table<string, unknown> declared battle state under inspection
---@param inventoryId string inventory owner under inspection
---@param item string item key under inspection
---@return integer units still plannable after outstanding reservations
local function plannableUnits(view, inventoryId, item)
  local outstanding = view.outstanding
  if type(outstanding) ~= "table" then
    return 0
  end
  local reserved = 0
  for _, plan in
    ipairs(outstanding --[[@as ItemUsePlan[] ]])
  do
    if
      type(plan) == "table"
      and plan --[[@as ItemUsePlan]].failureReason == nil
      and plan --[[@as ItemUsePlan]].inventoryId == inventoryId
      and plan --[[@as ItemUsePlan]].item == item
    then
      reserved = reserved + 1
    end
  end
  return reserved
end

---@param choice unknown candidate item choice under inspection
---@param view unknown candidate declared battle state under inspection
---@return string? refusal code, nil when the choice is executable
local function refusalReason(choice, view)
  if
    type(choice) ~= "table" or type(choice --[[@as BattleItemChoice]].inventoryId) ~= "string"
  then
    return "unknown_inventory"
  end
  local named = choice --[[@as BattleItemChoice]]
  if type(named.item) ~= "string" then
    return "unknown_item"
  end
  if type(view) ~= "table" then
    return "unknown_inventory"
  end
  local declared = view --[[@as table<string, unknown>]]
  if type(declared.inventories) ~= "table" then
    return "unknown_inventory"
  end
  local inventories = declared.inventories --[[@as table<string, unknown>]]
  local stock = inventories[named.inventoryId]
  if type(stock) ~= "table" then
    return "unknown_inventory"
  end
  local quantities = stock --[[@as table<string, unknown>]].quantities
  if type(quantities) ~= "table" then
    return "unknown_inventory"
  end
  local units = (quantities --[[@as table<string, integer>]])[named.item]
  if units == nil then
    return "unknown_item"
  end
  if type(units) ~= "number" then
    return "empty"
  end
  local available = units - plannableUnits(declared, named.inventoryId, named.item)
  if available < 1 then
    return "empty"
  end
  if type(named.target) ~= "table" then
    return "invalid_target"
  end
  local target = named.target --[[@as BattleItemTarget]]
  if target.kind ~= "combatant" or type(target.combatant) ~= "number" then
    return "invalid_target"
  end
  if type(declared.combatants) ~= "table" then
    return "invalid_target"
  end
  local combatants = declared.combatants --[[@as table<integer, unknown>]]
  if
    combatants[
      target.combatant --[[@as integer]]
    ] == nil
  then
    return "invalid_target"
  end
  return nil
end

---@param code string refusal code under report
---@return Errors.Error typed failure carrying the refusal code
local function refusal(code)
  local messages = {
    unknown_inventory = "the battle inventory owner is unknown",
    unknown_item = "the battle inventory carries no such item",
    empty = "the shared stack has no plannable unit left",
    invalid_target = "the chosen holder is not on the field",
    invalid_plan = "battle item plans carry their declared choice",
    already_executed = "battle item plans execute exactly once",
  }
  return Errors.new(code, messages[code] or "the battle item choice is refused", { code = code })
end

--- Validates a choice against declared stock and outstanding plans.
--- Returns true for executable choices, or nil plus the typed refusal.
---@param choice BattleItemChoice candidate item choice under validation
---@param view table<string, unknown> declared battle state under validation
---@return boolean? true when the choice is executable
---@return Errors.Error? typed refusal when the choice cannot execute
function ItemUse.validateChoice(choice, view)
  local reason = refusalReason(choice, view)
  if reason ~= nil then
    return nil, refusal(reason)
  end
  return true
end

--- Plans a choice without consuming: executable plans carry the
--- deterministic checkpoint and their effect operations, refused plans
--- carry the refusal code with no operations. Neither touches live state.
---@param choice BattleItemChoice candidate item choice under planning
---@param view table<string, unknown> declared battle state under planning
---@return ItemUsePlan detached plan for the choice
function ItemUse.plan(choice, view)
  local named = choice
  local item = nil
  local inventoryId = nil
  if type(named) == "table" then
    local specified = named --[[@as BattleItemChoice]]
    item = specified.item
    inventoryId = specified.inventoryId
  end
  local target = {}
  if
    type(named) == "table" and type(named --[[@as BattleItemChoice]].target) == "table"
  then
    target = copyTarget(named --[[@as BattleItemChoice]].target)
  end
  local reason = refusalReason(choice, view)
  if reason ~= nil then
    return {
      item = item,
      inventoryId = inventoryId,
      target = target,
      effectOperations = {},
      consumptionCheckpoint = ItemUse.CONSUMPTION_CHECKPOINT,
      failureReason = reason,
    }
  end
  local operations = {} ---@type BattleItemEffectOperation[]
  if CaptureContext.isBall(item) then
    operations[#operations + 1] = { kind = "capture", target = copyTarget(target) }
  else
    operations[#operations + 1] = { kind = "heal", amount = ItemUse.HEAL_AMOUNT, target = copyTarget(target) }
  end
  return {
    item = item,
    inventoryId = inventoryId,
    target = target,
    effectOperations = operations,
    consumptionCheckpoint = ItemUse.CONSUMPTION_CHECKPOINT,
    failureReason = nil,
  }
end

---@param plan unknown candidate plan under execution
---@param battle unknown candidate battle-owned execution state
---@return table<string, unknown> battle inventory stock record under execution
local function checkStock(plan, battle)
  local executable = plan --[[@as ItemUsePlan]]
  assert(type(battle) == "table", "battle item execution owns its battle state")
  local owned = battle --[[@as table<string, unknown>]]
  assert(type(owned.inventories) == "table", "battle item execution owns its battle stock")
  local inventories = owned.inventories --[[@as table<string, unknown>]]
  local stock = inventories[
    executable.inventoryId --[[@as string]]
  ]
  if type(stock) ~= "table" then
    error(refusal("unknown_inventory"))
  end
  return stock --[[@as table<string, unknown>]]
end

--- Executes a plan exactly once at its checkpoint: one unit leaves battle
--- stock, one delta enters the battle ledger, the holder recovers for heal
--- plans, and the plan is stamped. Ball plans spend the same owned unit
--- and return the capture outcome shape for the capture owner to settle:
--- the session routes ball plans to the capture path with full battle and
--- stream context, which this planner never fabricates. Refused, stale,
--- repeated, and malformed plans raise their typed failure before any
--- mutation.
---@param plan ItemUsePlan executable plan under execution
---@param battle table<string, unknown> battle-owned execution state being consumed
---@param rng table<string, unknown>? accepted battle stream, never drawn by deterministic use
---@return table<string, unknown> execution outcome marking the consumption and, for balls, the capture outcome
function ItemUse.execute(plan, battle, rng)
  assert(rng == nil or type(rng) == "table", "battle item execution accepts the battle stream")
  if type(plan) ~= "table" then
    error(refusal("invalid_plan"))
  end
  local executable = plan --[[@as ItemUsePlan]]
  if type(executable.item) ~= "string" or type(executable.inventoryId) ~= "string" then
    error(refusal("invalid_plan"))
  end
  if executable.failureReason ~= nil then
    error(refusal(executable.failureReason))
  end
  if executable.executed == true then
    error(refusal("already_executed"))
  end
  local stock = checkStock(plan, battle)
  local quantities = stock.quantities
  if type(quantities) ~= "table" then
    error(refusal("unknown_inventory"))
  end
  local units = (quantities --[[@as table<string, integer>]])[
    executable.item --[[@as string]]
  ]
  if units == nil then
    error(refusal("unknown_item"))
  end
  if type(units) ~= "number" or units < 1 then
    error(refusal("empty"))
  end
  local owned = battle --[[@as table<string, unknown>]]
  if type(executable.target) ~= "table" then
    error(refusal("invalid_target"))
  end
  local target = executable.target --[[@as BattleItemTarget]]
  if target.kind ~= "combatant" or type(target.combatant) ~= "number" then
    error(refusal("invalid_target"))
  end
  if type(owned.combatants) ~= "table" then
    error(refusal("invalid_target"))
  end
  local combatants = owned.combatants --[[@as table<integer, table<string, integer>>]]
  local holder = combatants[
    target.combatant --[[@as integer]]
  ]
  if type(holder) ~= "table" then
    error(refusal("invalid_target"))
  end
  if type(holder.hp) ~= "number" or type(holder.maxHp) ~= "number" or holder.hp <= 0 then
    error(refusal("invalid_target"))
  end
  assert(type(owned.ledger) == "table", "battle item execution owns its outcome ledger")
  local ledger = owned.ledger; --[[@as table<integer, table<string, unknown>>]]
  (quantities --[[@as table<string, integer>]])[
    executable.item --[[@as string]]
  ] = units - 1
  ledger[#ledger + 1] = {
    inventoryId = executable.inventoryId,
    item = executable.item,
    delta = -1,
    checkpoint = executable.consumptionCheckpoint,
  }
  if CaptureContext.isBall(executable.item) then
    executable.executed = true
    return { consumed = true, result = { ball = executable.item, target = target.combatant } }
  end
  holder.hp = math.min(holder.maxHp, holder.hp + ItemUse.HEAL_AMOUNT)
  executable.executed = true
  return { consumed = true }
end

return ItemUse
