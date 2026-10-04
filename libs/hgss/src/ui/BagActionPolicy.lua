-- Pure inventory-local action menu projection for the field bag. The menu
-- is a pure function of semantic facts -- the selected item key, its source
-- toss/registerability metadata, the pocket ordering, the pocket occupancy,
-- and the two-slot registration state. It never inspects renderer assets or
-- script opcodes, and it never names actions outside the inventory-local
-- set: toss, manual reorder, register/unregister, and cancel. Out-of-scope
-- item uses stay absent rather than disabled. A full registration omits
-- register: the audited source set offers no replacement selection and the
-- compiled overlays carry no replacement geometry. Pure module: no love,
-- no I/O.

---@class BagActionPolicyFacts
---@field itemKey string? the selected semantic item, nil when nothing is selected
---@field preventToss boolean the source item toss metadata
---@field registerable boolean whether the catalog marks the item field-registerable
---@field registered boolean whether the item currently holds a registration slot
---@field pocketOrdering string the catalog pocket ordering ("manual" or "native_id")
---@field pocketCount integer occupied slots in the selected pocket
---@field registeredCount integer currently occupied registration slots (0..2)

---@class BagActionPolicy
local BagActionPolicy = {}

---@param facts BagActionPolicyFacts
---@return { id: string, enabled: boolean, slot: integer }[]
function BagActionPolicy.actionsFor(facts)
  assert(type(facts) == "table", "the action policy needs its semantic facts")
  assert(
    facts.pocketOrdering == "manual" or facts.pocketOrdering == "native_id",
    "the action policy needs the catalog pocket ordering"
  )
  assert(
    type(facts.pocketCount) == "number" and facts.pocketCount % 1 == 0 and facts.pocketCount >= 0,
    "the action policy needs the pocket occupancy"
  )
  assert(
    type(facts.registeredCount) == "number"
      and facts.registeredCount % 1 == 0
      and facts.registeredCount >= 0
      and facts.registeredCount <= 2,
    "the action policy needs the registration occupancy"
  )
  local actions = {}
  if facts.itemKey ~= nil then
    assert(type(facts.itemKey) == "string" and facts.itemKey ~= "", "a selected action needs its item key")
    assert(type(facts.preventToss) == "boolean", "the action policy needs the source toss metadata")
    assert(type(facts.registerable) == "boolean", "the action policy needs registerability")
    assert(type(facts.registered) == "boolean", "the action policy needs the registration state")
    if facts.registerable then
      if facts.registered then
        actions[#actions + 1] = { id = "unregister", enabled = true, slot = 1 }
      elseif facts.registeredCount < 2 then
        actions[#actions + 1] = { id = "register", enabled = true, slot = 1 }
      end
    elseif not facts.preventToss then
      actions[#actions + 1] = { id = "toss", enabled = true, slot = 1 }
    end
    if facts.pocketOrdering == "manual" then
      actions[#actions + 1] = { id = "move", enabled = true, slot = 3 }
    end
  end
  return actions
end

-- Binds the pure projection to one live inventory service: the returned
-- closure reads the catalog definitions, the pocket occupancy, and the
-- registration list for the view's current selection. Composition owns this
-- binding; the controller only calls the closure with its refreshed view.
---@param service HgssBagService
---@return fun(view: table<string, unknown>): { id: string, enabled: boolean, slot: integer }[]
function BagActionPolicy.forService(service)
  assert(type(service) == "table", "the action policy binding needs the live bag service")
  assert(type(service.catalog) == "function", "the action policy binding needs the item catalog")
  assert(type(service.registeredItems) == "function", "the action policy binding needs registration reads")
  local function resolveForView(view)
    assert(type(view) == "table", "the action policy binding needs the refreshed browse view")
    assert(type(view.pocket) == "string", "the browse view names its pocket")
    local catalog = service:catalog()
    local pocketOrdering = catalog:pocket(view.pocket).ordering
    local registeredList = service:registeredItems()
    local registeredSet = {}
    for _, key in ipairs(registeredList) do
      registeredSet[key] = true
    end
    local selected = view.selected
    local facts = {
      itemKey = nil,
      preventToss = false,
      registerable = false,
      registered = false,
      pocketOrdering = pocketOrdering,
      pocketCount = type(view.slots) == "table" and #view.slots or 0,
      registeredCount = #registeredList,
    }
    if selected ~= nil then
      local itemKey = assert(selected.item, "selected slots carry their item key")
      local definition = catalog:item(itemKey)
      facts.itemKey = itemKey
      facts.preventToss = definition.preventToss == true
      facts.registerable = catalog:isRegisterable(itemKey)
      facts.registered = registeredSet[itemKey] == true
    end
    return BagActionPolicy.actionsFor(facts)
  end
  return resolveForView
end

---@class BagActionFieldFacts
---@field itemKey string? the selected semantic item, nil when nothing is selected
---@field useKind string the catalog party-use kind ("none" when effect-free)
---@field canHold boolean whether the catalog marks the item holdable
---@field isHm boolean whether the catalog marks the item a hidden machine
---@field pocket string? the catalog pocket of the selected item
---@field featureReason string? the stable deferral reason for deferred effects
---@field preventToss boolean the source item toss metadata
---@field registerable boolean whether the catalog marks the item field-registerable
---@field registered boolean whether the item currently holds a registration slot
---@field pocketOrdering string the catalog pocket ordering ("manual" or "native_id")
---@field pocketCount integer occupied slots in the selected pocket
---@field registeredCount integer currently occupied registration slots (0..2)
---@field partyEmpty boolean? true when no party member exists to target (absent means targets assumed)

-- Assembles field-context facts from semantic catalog metadata: the
-- party-use kind, holdability, hidden-machine identity, and any deferred
-- feature reason. No runtime service beyond the static catalog is
-- consulted; capability inference from other owners stays out.
---@param service HgssBagService
---@param itemKey string?
---@return BagActionFieldFacts
function BagActionPolicy.fieldFacts(service, itemKey)
  assert(type(service) == "table", "field facts need the live bag service")
  assert(type(service.catalog) == "function", "field facts need the item catalog")
  assert(type(service.registeredItems) == "function", "field facts need registration reads")
  local catalog = service:catalog()
  local registeredList = service:registeredItems()
  local registeredSet = {}
  for _, key in ipairs(registeredList) do
    registeredSet[key] = true
  end
  -- Pocket occupancy rides the refreshed view, which the field binding
  -- fills in after assembly; the item facts below are view-independent.
  local facts = {
    itemKey = nil,
    useKind = "none",
    canHold = false,
    isHm = false,
    pocket = nil,
    featureReason = nil,
    preventToss = false,
    registerable = false,
    registered = false,
    pocketOrdering = "manual",
    pocketCount = 0,
    registeredCount = #registeredList,
  }
  if itemKey == nil then
    return facts
  end
  assert(type(itemKey) == "string" and itemKey ~= "", "field facts need a selected item key")
  local definition = catalog:item(itemKey)
  local partyUse = definition.partyUse
  local useKind = "none"
  if type(partyUse) == "table" and type(partyUse.kind) == "string" then
    useKind = partyUse.kind
  end
  facts.itemKey = itemKey
  facts.useKind = useKind
  facts.canHold = definition.canHold == true
  facts.isHm = definition.isHm == true
  facts.pocket = definition.pocket
  if useKind == "deferred" and type(partyUse) == "table" then
    facts.featureReason = partyUse.reason
  end
  facts.preventToss = definition.preventToss == true
  facts.registerable = catalog:isRegisterable(itemKey)
  facts.registered = registeredSet[itemKey] == true
  return facts
end

-- Field-context menu: the source Use slot zero and Give slot two over the
-- unchanged inventory slots (register/unregister-or-toss at one, move at
-- three, implicit cancel at four). Use appears for any cataloged party
-- effect including deferred ones, which report later without consuming;
-- Give needs a holdable non-machine non-mail item.
---@param facts BagActionFieldFacts
---@return { id: string, enabled: boolean, slot: integer }[]
function BagActionPolicy.actionsForField(facts)
  assert(type(facts) == "table", "the field policy needs its semantic facts")
  local actions = {}
  -- Target-requiring entries need a party member: with an empty party
  -- the menu offers inventory actions only, never a dead Use or Give.
  local targetsExist = facts.partyEmpty ~= true
  if facts.itemKey ~= nil then
    assert(type(facts.itemKey) == "string" and facts.itemKey ~= "", "a selected action needs its item key")
    assert(type(facts.useKind) == "string", "the field policy needs the party-use kind")
    if targetsExist and facts.useKind ~= "none" then
      actions[#actions + 1] = { id = "use", enabled = true, slot = 0 }
    end
    if targetsExist and facts.canHold == true and facts.isHm ~= true and facts.pocket ~= "mail" then
      actions[#actions + 1] = { id = "give", enabled = true, slot = 2 }
    end
  end
  local inventory = {
    itemKey = facts.itemKey,
    preventToss = facts.preventToss == true,
    registerable = facts.registerable == true,
    registered = facts.registered == true,
    pocketOrdering = facts.pocketOrdering,
    pocketCount = facts.pocketCount,
    registeredCount = facts.registeredCount,
  }
  for _, action in ipairs(BagActionPolicy.actionsFor(inventory)) do
    actions[#actions + 1] = action
  end
  return actions
end

-- Held-item picker eligibility from semantic metadata: hidden machines,
-- key items, and mail never enter a mon's hold slot, while ordinary
-- teachable disks stay giveable. The picker selects directly, so this is
-- a predicate rather than a menu.
---@param facts BagActionFieldFacts
---@return boolean
function BagActionPolicy.isPickable(facts)
  assert(type(facts) == "table", "picker eligibility needs its semantic facts")
  if facts.itemKey == nil then
    return false
  end
  return facts.canHold == true and facts.isHm ~= true and facts.pocket ~= "mail"
end

-- Binds the field projection to one live inventory service: Use and Give
-- resolve from the same semantic catalog reads as the inventory binding.
-- Composition owns this binding; the flow supplies the field context.
-- partyEmpty names an empty target party (no member to use on or give
-- to); nil keeps the historical behavior of offering both entries.
---@param service HgssBagService
---@param partyEmpty boolean?
---@return fun(view: table<string, unknown>): { id: string, enabled: boolean, slot: integer }[]
function BagActionPolicy.forField(service, partyEmpty)
  assert(type(service) == "table", "the field policy binding needs the live bag service")
  assert(type(service.catalog) == "function", "the field policy binding needs the item catalog")
  local function resolveForView(view)
    assert(type(view) == "table", "the field policy binding needs the refreshed browse view")
    assert(type(view.pocket) == "string", "the browse view names its pocket")
    local selected = view.selected
    local itemKey = nil
    if selected ~= nil then
      itemKey = assert(selected.item, "selected slots carry their item key")
    end
    local facts = BagActionPolicy.fieldFacts(service, itemKey)
    facts.pocketOrdering = service:catalog():pocket(view.pocket).ordering
    facts.pocketCount = type(view.slots) == "table" and #view.slots or 0
    facts.partyEmpty = partyEmpty
    return BagActionPolicy.actionsForField(facts)
  end
  return resolveForView
end

return BagActionPolicy
