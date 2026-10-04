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
local BattleErrors = require("libs.battle.src.errors")
local BattleContext = require("libs.battle.src.BattleContext")
local CaptureContext = require("libs.battle.src.gen4.CaptureContext")
local NativeEffectHandlers = require("libs.battle.src.gen4.behaviors.effects.NativeEffectHandlers")
local PartyUse = require("libs.items.src.PartyUse")
local StatStages = require("libs.battle.src.gen4.StatStages")
local Status = require("libs.battle.src.gen4.Status")

local ItemUse = {}

ItemUse.CONSUMPTION_CHECKPOINT = "item_use"

---@class BattleItemTarget
---@field kind string target vocabulary, combatant for holder use
---@field combatant integer? holder identity for combatant targets

---@class BattleItemChoice
---@field inventoryId string battle inventory owner of the shared stack
---@field item string item key requested from the shared stack
---@field target BattleItemTarget chosen holder
---@field moveSlot integer? zero-based move slot for PP use

---@class BattleItemEffectOperation
---@field kind string operation vocabulary, restore and cure for servings and capture for thrown balls
---@field amount integer? computed restoration of restore operations, nil otherwise
---@field key string? persistent condition removed by cure operations, nil otherwise
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
    no_effect = "the serving would change neither health nor condition",
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

--- Resolves the generated semantic entry for a serving: absent fact
--- maps and absent entries raise missing behavior before anything is
--- consumed. Entries may carry the serving party use beside battle-use
--- riders and held-throw facts; each consumer reads its own facts while
--- genuinely foreign fields still fail.
---@param item string non-ball item key under classification
---@param itemFacts unknown immutable semantic facts by item key under inspection
---@return table<string, unknown> generated fact entry for the serving
local function semanticEntry(item, itemFacts)
  if type(itemFacts) ~= "table" then
    error(BattleErrors.missingBehavior("battle servings read their immutable item facts", { item = item }))
  end
  local entry = (itemFacts --[[@as table<string, unknown>]])[item]
  if type(entry) ~= "table" then
    error(BattleErrors.missingBehavior("battle servings read their immutable item facts", { item = item }))
  end
  for key in
    pairs(entry --[[@as table<string, unknown>]])
  do
    if
      key ~= "partyUse"
      and key ~= "battleUse"
      and key ~= "heldBehavior"
      and key ~= "naturalGift"
      and key ~= "fling"
    then
      error(BattleErrors.missingBehavior("battle item facts carry only their generated facts", { item = item }))
    end
  end
  return entry --[[@as table<string, unknown>]]
end

---@param restore unknown generated restore record under validation
---@param item string non-ball item key under the error context
local function checkRestoreShape(restore, item)
  if restore == nil then
    return
  end
  if type(restore) ~= "table" then
    error(BattleErrors.missingBehavior("battle servings carry their generated restore shape", { item = item }))
  end
  local record = restore --[[@as table<string, unknown>]]
  if record.kind == "full" or record.kind == "half" or record.kind == "quarter" then
    return
  end
  if record.kind == "fixed" then
    local amount = record.amount
    if type(amount) == "number" and amount % 1 == 0 and amount >= 1 then
      return
    end
  end
  error(BattleErrors.missingBehavior("battle servings carry their generated restore shape", { item = item }))
end

---@param partyUse table<string, unknown> generated party-use record under validation
---@param item string non-ball item key under the error context
local function checkMedicineShape(partyUse, item)
  if partyUse.kind ~= "medicine" then
    error(BattleErrors.missingBehavior("the battle models only ordinary living medicine", { item = item }))
  end
  if partyUse.revive ~= "none" then
    error(BattleErrors.missingBehavior("the battle models no revival servings", { item = item }))
  end
  local cures = partyUse.cures
  if cures ~= nil then
    if type(cures) ~= "table" then
      error(BattleErrors.missingBehavior("battle servings carry their generated cure flags", { item = item }))
    end
    for flag, enabled in
      pairs(cures --[[@as table<string, unknown>]])
    do
      if type(flag) ~= "string" or (enabled ~= true and enabled ~= false) then
        error(BattleErrors.missingBehavior("battle servings carry their generated cure flags", { item = item }))
      end
    end
  end
  checkRestoreShape(partyUse.restore, item)
end

-- The shared poison cure clears either persistent record: the generated
-- poison flag names the cure family while the holder carries the
-- concrete record. Every other cure flag maps one-to-one to its holder
-- record.
---@param flag string generated cure flag under expansion
---@return string[] holder condition keys the flag may clear
local function cureTargets(flag)
  if flag == "poison" then
    return { "poison", "toxic" }
  end
  return { flag }
end

---@param holder unknown holder combatant under inspection
---@return table<string, boolean> persistent condition keys carried by the holder mon
local function holderConditions(holder)
  local present = {} ---@type table<string, boolean>
  if type(holder) ~= "table" then
    return present
  end
  local mon = (holder --[[@as table<string, unknown>]]).mon
  if type(mon) ~= "table" then
    return present
  end
  local condition = (mon --[[@as table<string, unknown>]]).condition
  if type(condition) ~= "table" then
    return present
  end
  local effects = (condition --[[@as table<string, unknown>]]).effects
  if type(effects) ~= "table" then
    return present
  end
  for _, effect in
    ipairs(effects --[[@as table<integer, unknown>]])
  do
    if type(effect) == "table" then
      local key = (effect --[[@as table<string, unknown>]]).key
      if type(key) == "string" then
        present[
          key --[[@as string]]
        ] = true
      end
    end
  end
  return present
end

---@param holder unknown holder combatant under inspection
---@return integer? current health, absent without a numeric record
---@return integer? maximum health, absent without a numeric record
local function holderHealth(holder)
  if type(holder) ~= "table" then
    return nil, nil
  end
  local record = holder --[[@as table<string, unknown>]]
  if type(record.hp) ~= "number" or type(record.maxHp) ~= "number" then
    return nil, nil
  end
  return record.hp, --[[@as integer]]
    record.maxHp --[[@as integer]]
end

-- Battle stage identities the generated battle use may raise, in stable
-- planning order.
local BATTLE_STAGE_ORDER = {
  "attack",
  "defense",
  "specialAttack",
  "specialDefense",
  "speed",
  "accuracy",
  "critical",
}

---@param holder unknown holder combatant under inspection
---@return table<string, integer> battle-local stages, flat when unreadable
local function holderStages(holder)
  if type(holder) ~= "table" then
    return {}
  end
  local stages = (holder --[[@as table<string, unknown>]]).stages
  if type(stages) ~= "table" then
    return {}
  end
  return stages --[[@as table<string, integer>]]
end

--- Plans one battle-only serving from its generated battle use without
--- mutating: nonzero stage flags plan one stage each while headroom
--- lasts, the critical flag plans focus only while the holder carries
--- no focus, the guard flag plans the side screen only while the
--- holder side carries no screen, and true cure flags plan volatile
--- clearing only while the holder carries the volatile. Stages gate on
--- visible headroom while focus, guard, and cures read the same live
--- battle-local effects execution uses, so servings without any
--- applicable effect plan nothing. Servings whose party use is not
--- deferred battle-only, or that carry no battle use, raise missing
--- behavior instead of guessing.
---@param item string non-ball item key under planning
---@param target BattleItemTarget detached holder target under planning
---@param view table<string, unknown> declared battle state under planning
---@param entry table<string, unknown> generated fact entry for the serving
---@return BattleItemEffectOperation[] planned battle operations, empty without effect
local function planBattleServing(item, target, view, entry)
  local partyUse = entry.partyUse --[[@as table<string, unknown>]]
  if partyUse.kind ~= "deferred" then
    error(BattleErrors.missingBehavior("the battle models only ordinary living medicine", { item = item }))
  end
  local battleUse = entry.battleUse
  if type(battleUse) ~= "table" then
    error(BattleErrors.missingBehavior("the battle models only ordinary living medicine", { item = item }))
  end
  local riders = battleUse --[[@as table<string, unknown>]]
  local operations = {} ---@type BattleItemEffectOperation[]
  local combatants = (view --[[@as table<string, unknown>]]).combatants --[[@as table<integer, unknown>]]
  local holder = type(combatants) == "table" and combatants[
    target.combatant --[[@as integer]]
  ] or nil
  local active = type(holder) == "table" and (holder --[[@as table<string, unknown>]]).active ~= nil
  local holderId = target.combatant --[[@as integer]]
  local context = BattleContext.wrap(view)
  local stages = holderStages(holder)
  local flags = riders.stages
  if type(flags) == "table" then
    local decoded = flags --[[@as table<string, integer>]]
    for _, stat in ipairs(BATTLE_STAGE_ORDER) do
      if stat ~= "critical" and type(decoded[stat]) == "number" and decoded[stat] ~= 0 and active then
        local current = stages[stat]
        if type(current) ~= "number" or current < StatStages.MAX then
          operations[#operations + 1] = { kind = "stage", stat = stat, target = copyTarget(target) }
        end
      end
    end
    if type(decoded.critical) == "number" and decoded.critical ~= 0 and active then
      if not context:hasBattleEffect(holderId, "focusenergy") then
        operations[#operations + 1] = { kind = "focus", target = copyTarget(target) }
      end
    end
  end
  if riders.guardSpec == true and active then
    local side = context:entryOf(holderId).side --[[@as integer]]
    if context:sideEffect(side, "mist") == nil then
      operations[#operations + 1] = { kind = "guard", target = copyTarget(target) }
    end
  end
  local cures = riders.cures
  if type(cures) == "table" and active then
    for _, flag in ipairs({ "confusion", "infatuation" }) do
      if
        (cures --[[@as table<string, unknown>]])[flag] == true and context:hasBattleEffect(holderId, flag)
      then
        operations[#operations + 1] = { kind = "cure", key = flag, target = copyTarget(target) }
      end
    end
  end
  return operations
end

--- Plans one serving from its generated semantics without mutating: cure
--- operations name the concrete holder record each true cure flag
--- clears, and restoration carries the exact generated amount. Empty
--- operations report a serving with no effect. Battle-only servings
--- plan their stages, focus, guard, and volatile cures from the
--- generated battle use instead of medicine.
---@param item string non-ball item key under planning
---@param target BattleItemTarget detached holder target under planning
---@param view table<string, unknown> declared battle state under planning
---@param itemFacts table<string, unknown>? immutable semantic facts by item key under planning
---@return BattleItemEffectOperation[] planned serving operations, empty without effect
local function planServing(item, target, view, itemFacts)
  local entry = semanticEntry(item, itemFacts)
  local partyUse = entry.partyUse
  if type(partyUse) ~= "table" then
    error(BattleErrors.missingBehavior("battle servings carry their generated party use", { item = item }))
  end
  local record = partyUse --[[@as table<string, unknown>]]
  if record.kind ~= "medicine" then
    return planBattleServing(item, target, view, entry)
  end
  checkMedicineShape(record, item)
  local operations = {} ---@type BattleItemEffectOperation[]
  local combatants = (view --[[@as table<string, unknown>]]).combatants --[[@as table<integer, unknown>]]
  local holder = type(combatants) == "table" and combatants[
    target.combatant --[[@as integer]]
  ] or nil
  local conditions = holderConditions(holder)
  local cures = partyUse.cures
  if type(cures) == "table" then
    local flags = {} ---@type string[]
    for flag, enabled in
      pairs(cures --[[@as table<string, unknown>]])
    do
      if enabled == true then
        flags[#flags + 1] = flag --[[@as string]]
      end
    end
    table.sort(flags)
    for _, flag in ipairs(flags) do
      for _, key in ipairs(cureTargets(flag)) do
        if conditions[key] == true then
          operations[#operations + 1] = { kind = "cure", key = key, target = copyTarget(target) }
          break
        end
      end
    end
  end
  local hp, maxHp = holderHealth(holder)
  if partyUse.restore ~= nil and hp ~= nil and maxHp ~= nil and hp > 0 and hp < maxHp then
    operations[#operations + 1] = {
      kind = "restore",
      amount = PartyUse.restoreAmount(maxHp, partyUse.restore --[[@as table<string, unknown>]]),
      target = copyTarget(target),
    }
  end
  return operations
end

--- Plans a choice without consuming: executable plans carry the
--- deterministic checkpoint and their effect operations, refused plans
--- carry the refusal code with no operations. Servings classify from the
--- immutable semantic facts: balls keep their capture plan while medicine
--- plans its generated restoration and persistent cures, servings without
--- effect refuse, and absent or unmodeled semantics raise missing
--- behavior. Neither touches live state.
---@param choice BattleItemChoice candidate item choice under planning
---@param view table<string, unknown> declared battle state under planning
---@param itemFacts table<string, unknown>? immutable semantic facts by item key for servings
---@return ItemUsePlan detached plan for the choice
function ItemUse.plan(choice, view, itemFacts)
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
    operations = planServing(item --[[@as string]], target --[[@as BattleItemTarget]], view, itemFacts)
    if #operations == 0 then
      return {
        item = item,
        inventoryId = inventoryId,
        target = target,
        effectOperations = {},
        consumptionCheckpoint = ItemUse.CONSUMPTION_CHECKPOINT,
        failureReason = "no_effect",
      }
    end
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

--- Applies one serving plan to its live holder: restoration heals toward
--- the ceiling while persistent cures remove their named condition
--- through the status owner. Battle operations (stages, focus, guard,
--- volatile cures) apply through their own owner beside this one; unknown
--- operation kinds never execute. Both live health mirrors agree afterwards.
---@param executable ItemUsePlan executable serving plan under execution
---@param holder table<string, unknown> live holder combatant under mutation
---@return integer actual health gained after ceiling capping
local function applyServing(executable, holder)
  local hp = holder.hp
  local maxHp = holder.maxHp
  assert(type(hp) == "number" and type(maxHp) == "number", "servings apply to a recorded holder")
  local gained = 0
  for _, operation in
    ipairs(executable.effectOperations --[[@as BattleItemEffectOperation[] ]])
  do
    local effect = operation --[[@as BattleItemEffectOperation]]
    if effect.kind == "restore" then
      local amount = effect.amount
      assert(type(amount) == "number", "restore operations carry their computed amount")
      local capped = math.min(maxHp --[[@as integer]], hp --[[@as integer]] + amount --[[@as integer]])
      gained = gained + (
          capped - hp --[[@as integer]]
        )
      hp = capped
    elseif effect.kind == "cure" and effect.key ~= "confusion" and effect.key ~= "infatuation" then
      local mon = holder.mon
      if type(mon) ~= "table" then
        error(BattleErrors.invalidState("battle servings cure their holder record", {}))
      end
      Status.cure(mon --[[@as table<string, unknown>]], effect.key --[[@as string]])
    elseif effect.kind ~= "stage" and effect.kind ~= "focus" and effect.kind ~= "guard" and effect.kind ~= "cure" then
      error(refusal("invalid_plan"))
    end
  end
  holder.hp = hp
  local mon = holder.mon
  if type(mon) == "table" then
    local condition = (mon --[[@as table<string, unknown>]]).condition
    if type(condition) == "table" then
      (condition --[[@as table<string, unknown>]]).currentHp = hp
    end
  end
  return gained
end

--- Applies the battle operations of one serving plan through the
--- battle-local owners: stages climb one step through the stage owner,
--- focus roots the focus-energy volatile, guard screens the holder side
--- with mist, and volatile cures lift confusion and infatuation.
--- Already-focused holders and screened sides stay untouched; missing
--- volatiles clear to nothing. Only plans carrying battle operations
--- reach this owner.
---@param executable ItemUsePlan executable serving plan under execution
---@param battle table<string, unknown> battle-owned execution state under mutation
---@param holder table<string, unknown> live holder combatant under mutation
local function applyBattleUse(executable, battle, holder)
  local target = executable.target --[[@as BattleItemTarget]]
  local holderId = target.combatant --[[@as integer]]
  local cause = { kind = "item", item = executable.item, combatant = holderId }
  local context = BattleContext.wrap(battle)
  for _, operation in
    ipairs(executable.effectOperations --[[@as BattleItemEffectOperation[] ]])
  do
    local effect = operation --[[@as BattleItemEffectOperation]]
    if effect.kind == "stage" then
      local stages = holder.stages --[[@as table<string, integer>]]
      local stat = effect.stat --[[@as string]]
      local next = StatStages.change(stages[stat] --[[@as integer]], 1)
      if next ~= stages[stat] then
        context:changeStage(holderId, stat, next, cause)
      end
    elseif effect.kind == "focus" then
      if not context:hasBattleEffect(holderId, "focusenergy") then
        local entry = context:entryOf(holderId)
        if entry.activation == nil then
          error(BattleErrors.invalidState("battle servings focus a live entry", { combatant = holderId }))
        end
        context:addBattleEffect(
          NativeEffectHandlers.definitionFor("focusenergy"),
          { kind = "active", combatant = holderId, activation = entry.activation },
          cause,
          { version = 1 }
        )
      end
    elseif effect.kind == "guard" then
      local side = context:entryOf(holderId).side
      if
        context:sideEffect(side --[[@as integer]], "mist") == nil
      then
        context:addBattleEffect(
          NativeEffectHandlers.definitionFor("mist"),
          { kind = "side", side = side },
          cause,
          { version = 1, turns = 5 }
        )
      end
    elseif effect.kind == "cure" and (effect.key == "confusion" or effect.key == "infatuation") then
      context:removeBattleEffect(holderId, effect.key --[[@as string]])
    end
  end
end

---@param operations table<integer, table<string, unknown>> planned effect operations under inspection
---@return boolean true when at least one operation needs the battle-local owners
local function hasBattleOperations(operations)
  for _, operation in ipairs(operations) do
    local effect = operation --[[@as BattleItemEffectOperation]]
    if
      effect.kind == "stage"
      or effect.kind == "focus"
      or effect.kind == "guard"
      or (effect.kind == "cure" and (effect.key == "confusion" or effect.key == "infatuation"))
    then
      return true
    end
  end
  return false
end

--- Executes a plan exactly once at its checkpoint: one unit leaves battle
--- stock, one delta enters the battle ledger, servings apply their planned
--- restoration and persistent cures to the holder while battle operations
--- apply through the battle-local owners, and the plan is stamped. Ball plans spend the same owned unit
--- and return the capture outcome shape for the capture owner to settle:
--- the session routes ball plans to the capture path with full battle and
--- stream context, which this planner never fabricates. Refused, stale,
--- repeated, and malformed plans raise their typed failure before any
--- mutation.
---@param plan ItemUsePlan executable plan under execution
---@param battle table<string, unknown> battle-owned execution state being consumed
---@param rng table<string, unknown>? accepted battle stream, never drawn by deterministic use
---@return table<string, unknown> execution outcome marking the consumption, the actual restoration, and the holder
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
  local combatants = owned.combatants --[[@as table<integer, table<string, unknown>>]]
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
  local restored = applyServing(executable, holder)
  if
    hasBattleOperations(executable.effectOperations --[[@as table<integer, table<string, unknown>>]])
  then
    applyBattleUse(executable, battle, holder)
  end
  executable.executed = true
  return { consumed = true, restored = restored, target = copyTarget(target) }
end

return ItemUse
