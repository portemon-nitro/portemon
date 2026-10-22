-- Private battle child composition module. Builds the concrete child
-- applications behind the battle-local selection barrier with battle-local
-- data and command adapters, delegating to the real application mechanisms:
-- the native Bag application in its battle context, the native Party
-- application in its pick and item-target contexts, the native
-- summary/move-selection presentation in move-pick mode, the existing
-- naming screen controller, and the native evolution presentation state.
-- This module never activates the field application host, never exposes the
-- paused field, and never reuses a field adapter that writes live
-- inventory or party state while a decision is still pending: every service
-- behind a composed child reads a detached battle snapshot, stages reply
-- fragments at most, and refuses live mutation loudly.
--
-- A composed child owns its mutable controller state and any acquired lease;
-- borrowed catalogs stay borrowed. Results report once through takeResult as
-- { identity, kind, choice } where identity binds the opening barrier, kind
-- is accepted/cancelled/failed, and choice is the exact authoritative
-- option/operation payload. An accepted UI row never seals on its own: the
-- barrier still binds kernel fragments, and native controller intents are
-- drained as evidence, never as acceptance.

local BagController = require("libs.hgss.src.ui.BagController")
local BagCursor = require("libs.hgss.src.items.BagCursor")
local BagModel = require("libs.hgss.src.ui.BagModel")
local BagSave = require("libs.hgss.src.save.BagSave")
local NamingScreenController = require("libs.hgss.src.ui.NamingScreenController")
local PartyScreenController = require("libs.hgss.src.ui.PartyScreenController")
local PartyScreenLayout = require("libs.hgss.src.ui.PartyScreenLayout")
local SummaryController = require("libs.hgss.src.ui.SummaryController")

local BattleChildApplications = {}

-- Canonical battle child hit geometry: the six list rows, the footer
-- Back, and the bag pocket steppers share one coordinate space with the
-- rows the battle renderer paints and the battle session hit-tests, so a
-- tap and its paint resolve through the same regions. Row identities stay
-- stable (party:N, bag:N, learn:N, learn:decline); geometry depends only on
-- the row index, never on row content.
local CHILD_ROW = { x = 8, y = 32, width = 240, height = 20 }
local CHILD_BACK = { x = 8, y = 152, width = 80, height = 40 }
local CHILD_LEARN_BACK = { x = 8, y = 172, width = 240, height = 20 }
local CHILD_POCKET_PREV = { x = 96, y = 152, width = 76, height = 40 }
local CHILD_POCKET_NEXT = { x = 176, y = 152, width = 72, height = 40 }

---@param rect table<string, number> canonical hit rectangle under testing
---@param x number tap horizontal position under testing
---@param y number tap vertical position under testing
---@return boolean inside true while the tap lands in the rectangle
local function hitContains(rect, x, y)
  return type(x) == "number"
    and type(y) == "number"
    and x >= rect.x
    and x < rect.x + rect.width
    and y >= rect.y
    and y < rect.y + rect.height
end

---@param index integer one-based row position under mapping
---@return table<string, number> canonical row rectangle
local function rowRect(index)
  return {
    x = CHILD_ROW.x,
    y = CHILD_ROW.y + (index - 1) * CHILD_ROW.height,
    width = CHILD_ROW.width,
    height = CHILD_ROW.height,
  }
end

---@param rect table<string, number> canonical hit rectangle under mapping
---@return table<string, number> rectangle center
local function rectCenter(rect)
  return { x = rect.x + rect.width / 2, y = rect.y + rect.height / 2 }
end

-- Resolves one native party hit target over the canonical modal rows:
-- roster rows select by slot, the footer cancels.
---@param x number tap horizontal position under hit-testing
---@param y number tap vertical position under hit-testing
---@return table<string, unknown>? native hit target, nil outside every control
local function battlePartyHit(x, y)
  for slot = 0, 5 do
    if hitContains(rowRect(slot + 1), x, y) then
      return { kind = "slot", slot = slot }
    end
  end
  if hitContains(CHILD_BACK, x, y) then
    return { kind = "cancel" }
  end
  return nil
end

-- Resolves one native battle-bag hit target over the canonical modal
-- rows: visible cells name their visible cell, the footer cancels, and
-- the pocket steppers name the neighboring pocket.
---@param x number tap horizontal position under hit-testing
---@param y number tap vertical position under hit-testing
---@param status table<string, unknown> native bag status under hit-testing
---@return table<string, unknown>? native hit target, nil outside every control
local function battleBagHit(x, y, status)
  for cell = 0, 5 do
    if hitContains(rowRect(cell + 1), x, y) then
      return { kind = "item", visibleIndex = cell }
    end
  end
  if hitContains(CHILD_BACK, x, y) then
    return { kind = "cancel" }
  end
  local order = BagSave.POCKET_ORDER
  local at = nil
  if type(status) == "table" then
    for position, pocketKey in ipairs(order) do
      if pocketKey == status.pocket then
        at = position
      end
    end
  end
  if at ~= nil then
    if hitContains(CHILD_POCKET_PREV, x, y) then
      return { kind = "pocket", pocket = order[((at - 2) % #order) + 1] }
    end
    if hitContains(CHILD_POCKET_NEXT, x, y) then
      return { kind = "pocket", pocket = order[(at % #order) + 1] }
    end
  end
  return nil
end

-- Resolves one native learning hit target over the canonical modal rows:
-- held rows select by move index while the fifth row and the footer
-- both decline through the shared cancel path.
---@param x number tap horizontal position under hit-testing
---@param y number tap vertical position under hit-testing
---@return table<string, unknown>? native hit target, nil outside every control
local function battleLearnHit(x, y)
  for index = 0, 3 do
    if hitContains(rowRect(index + 1), x, y) then
      return { kind = "move", index = index }
    end
  end
  if hitContains(rowRect(5), x, y) then
    return { kind = "return" }
  end
  if hitContains(CHILD_LEARN_BACK, x, y) then
    return { kind = "return" }
  end
  return nil
end

-- Maps one stable battle row/control identity to its canonical tap
-- center for pointer synthesis. Unknown identities map to nothing so a
-- foreign tap can never arm controller state.
---@param kind string composed child kind under mapping
---@param id string stable row/control identity under mapping
---@return table<string, number>? tap center, nil for unknown identities
local function battleTapPoint(kind, id)
  if kind == "party" or kind == "target" then
    local slot = tonumber(id:match("^party:(%d+)$") or "")
    if slot ~= nil and slot % 1 == 0 and slot >= 0 and slot <= 5 then
      return rectCenter(rowRect(math.floor(slot) + 1))
    end
    if id == "back" then
      return rectCenter(CHILD_BACK)
    end
    return nil
  end
  if kind == "bag" then
    local cell = tonumber(id:match("^bag:(%d+)$") or "")
    if cell ~= nil and cell % 1 == 0 and cell >= 0 and cell <= 5 then
      return rectCenter(rowRect(math.floor(cell) + 1))
    end
    if id == "back" then
      return rectCenter(CHILD_BACK)
    end
    if id == "pocket_prev" then
      return rectCenter(CHILD_POCKET_PREV)
    end
    if id == "pocket_next" then
      return rectCenter(CHILD_POCKET_NEXT)
    end
    return nil
  end
  if kind == "learn" then
    local slot = tonumber(id:match("^learn:(%d+)$") or "")
    if slot ~= nil and slot % 1 == 0 and slot >= 0 and slot <= 3 then
      return rectCenter(rowRect(math.floor(slot) + 1))
    end
    if id == "learn:decline" then
      return rectCenter(rowRect(5))
    end
    if id == "back" then
      return rectCenter(CHILD_LEARN_BACK)
    end
    return nil
  end
  return nil
end

-- Expands barrier taps into synthetic matched pointer pairs at their
-- canonical centers so keyboard and pointer travel the same native
-- controller actions. Unknown identities drop without arming anything.
---@param kind string composed child kind under expansion
---@param events table<integer, table<string, unknown>> semantic input batch under expansion
---@return table<integer, table<string, unknown>> batch with taps expanded to pointer pairs
local function expandTaps(kind, events)
  local expanded = {}
  local taps = 0
  for _, event in ipairs(events) do
    if type(event) == "table" and event.type == "tap" and type(event.id) == "string" then
      local point = battleTapPoint(kind, event.id)
      if point ~= nil then
        taps = taps + 1
        local pointerId = "battle-tap:" .. tostring(taps)
        expanded[#expanded + 1] = { type = "pointer_down", pointerId = pointerId, x = point.x, y = point.y }
        expanded[#expanded + 1] = { type = "pointer_up", pointerId = pointerId, x = point.x, y = point.y }
      end
    else
      expanded[#expanded + 1] = event
    end
  end
  return expanded
end

BattleChildApplications.KINDS = { party = true, bag = true, learn = true, naming = true, evolution = true }

BattleChildApplications.RECEIPTS = {
  party = "party",
  bag = "bag",
  learn = "summary",
  naming = "naming",
  evolution = "evolution",
}

-- The battle-local default keyboard map covers printable ASCII so the
-- native naming grid stays fully operable without the generated font. A
-- caller carrying the generated font charmap injects it through services
-- and the injected map wins.
---@return table<string, integer>
local function defaultCharmap()
  local map = {}
  for code = string.byte(" "), string.byte("~") do
    map[string.char(code)] = code
  end
  return map
end

-- Silent naming sound boundary while battle threads no audio through
-- child services: naming still composes (the controller requires a
-- boundary) until battle provides its own effect function.
local function silentNamingEffect() end

---@param value unknown
---@return unknown detached copy without shared mutable state
local function copyValue(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for key, item in pairs(value) do
    out[key] = copyValue(item)
  end
  return out
end

-- Binds one projected fragment to the opening barrier. Fragments are
-- copied, never rebuilt, so the kernel keeps owning their shape.
---@param identity table<string, unknown> opening barrier identity under binding
---@param fragment table<string, unknown> projected choice fragment under binding
---@return table<string, unknown> bound staged reply
local function bindFragment(identity, fragment)
  return {
    requestId = identity.requestId,
    epoch = identity.epoch,
    controller = identity.controller,
    launchId = identity.launchId,
    choices = { copyValue(fragment) },
  }
end

-- Reports the one-shot child result bound to the opening barrier. The
-- first take wins; every later take reports nil.
---@param child table<string, unknown> composed child under reporting
---@param kind string result kind under reporting
---@param choice table<string, unknown>? authoritative payload, nil for cancellations
---@return table<string, unknown>? bound result, nil once consumed
local function takeChildResult(child, kind, choice)
  if child._taken then
    return nil
  end
  child._taken = true
  local result = {
    kind = kind,
    requestId = child._identity.requestId,
    epoch = child._identity.epoch,
    controller = child._identity.controller,
    launchId = child._identity.launchId,
  }
  if kind == "choice" then
    result.reply = bindFragment(child._identity, assert(choice, "choices carry their fragment"))
  end
  return result
end

---@param intent table<string, unknown> child intent under validation
---@return table<string, unknown> opening barrier identity
local function checkIdentity(intent)
  assert(type(intent) == "table", "child intents arrive as records")
  assert(
    intent.kind == "party"
      or intent.kind == "bag"
      or intent.kind == "learn"
      or intent.kind == "naming"
      or intent.kind == "evolution",
    "child intents name party, bag, learn, naming, or evolution"
  )
  assert(type(intent.launchId) == "string" and intent.launchId ~= "", "child intents carry their launch")
  assert(type(intent.requestId) == "number" and intent.requestId % 1 == 0, "child intents carry their request identity")
  assert(type(intent.epoch) == "number" and intent.epoch % 1 == 0, "child intents carry their epoch")
  assert(type(intent.controller) == "string" and intent.controller ~= "", "child intents carry their controller")
  return {
    kind = intent.kind,
    launchId = intent.launchId,
    requestId = intent.requestId,
    epoch = intent.epoch,
    controller = intent.controller,
  }
end

---@param options table<string, unknown> decision options under projection
---@return table<integer, table<integer, table<string, unknown>>> enabled switch fragments by actor combatant then replacement
local function enabledSwitches(options)
  local found = {}
  if type(options.actors) ~= "table" then
    return found
  end
  for _, actor in ipairs(options.actors) do
    if type(actor) == "table" and type(actor.combatant) == "number" and type(actor.choices) == "table" then
      local byReplacement = found[actor.combatant]
      if byReplacement == nil then
        byReplacement = {}
        found[actor.combatant] = byReplacement
      end
      for _, choice in ipairs(actor.choices) do
        if
          type(choice) == "table"
          and choice.enabled == true
          and type(choice.choice) == "table"
          and choice.choice.kind == "switch"
          and type(choice.choice.payload) == "table"
          and type(choice.choice.payload.replacement) == "number"
        then
          byReplacement[choice.choice.payload.replacement] = choice.choice
        end
      end
    end
  end
  return found
end

---@param options table<string, unknown> decision options under projection
---@param key string staged item identity under projection
---@return table<integer, table<string, unknown>> enabled item fragments by target combatant
local function enabledItemTargets(options, key)
  local found = {}
  if type(options.actors) ~= "table" then
    return found
  end
  for _, actor in ipairs(options.actors) do
    if type(actor) == "table" and type(actor.choices) == "table" then
      for _, choice in ipairs(actor.choices) do
        if
          type(choice) == "table"
          and choice.enabled == true
          and type(choice.choice) == "table"
          and choice.choice.kind == "item"
          and type(choice.choice.payload) == "table"
          and choice.choice.payload.item == key
          and type(choice.choice.payload.target) == "table"
          and type(choice.choice.payload.target.combatant) == "number"
        then
          found[choice.choice.payload.target.combatant] = choice.choice
        end
      end
    end
  end
  return found
end

---@param options table<string, unknown> decision options under projection
---@param key string stocked item identity under projection
---@return boolean legal true while a native choice can execute the item
---@return string? first native refusal reason, nil while selectable
local function itemLegality(options, key)
  local reason = nil
  if type(options.actors) ~= "table" then
    return false, nil
  end
  for _, actor in ipairs(options.actors) do
    if type(actor) == "table" and type(actor.choices) == "table" then
      for _, choice in ipairs(actor.choices) do
        if
          type(choice) == "table"
          and type(choice.choice) == "table"
          and choice.choice.kind == "item"
          and type(choice.choice.payload) == "table"
          and choice.choice.payload.item == key
        then
          if choice.enabled == true then
            return true, nil
          end
          if reason == nil and type(choice.reason) == "string" then
            reason = choice.reason
          end
        end
      end
    end
  end
  return false, reason
end

-- Battle-local bag service over the detached stock: pocket reads project
-- the detached inventory through the borrowed item catalog, the revision
-- stays fixed for the child lifetime, and registrations are empty because
-- battle browsing never claims a registration slot.
---@param inventory table<string, integer> detached battle stock under projection
---@param itemCatalog table<string, unknown>? borrowed immutable item catalog
---@return table<string, unknown> battle-local bag service
local function battleBagService(inventory, itemCatalog)
  assert(type(inventory) == "table", "the battle bag reads its detached stock")
  local service = {}
  function service:catalog()
    return assert(itemCatalog, "the stocked bag needs its item catalog")
  end
  function service:revision()
    return 1
  end
  function service:registeredItems()
    return {}
  end
  function service:pocketItems(pocket)
    local catalog = self:catalog()
    local out = {}
    for key, quantity in pairs(inventory) do
      if type(quantity) == "number" and quantity >= 1 then
        local lookup = catalog.item --[[@as fun(collab: table<string, unknown>, key: string): table<string, unknown>]]
        assert(type(lookup) == "function", "the item catalog answers item records")
        local definition = lookup(catalog, key)
        assert(type(definition) == "table", "stocked items resolve through the catalog")
        if definition.pocket == pocket then
          out[#out + 1] = { item = key, quantity = quantity }
        end
      end
    end
    table.sort(out, function(a, b)
      return a.item < b.item
    end)
    return out
  end
  return service
end

-- Battle-local bag mutation commands: battle children stage reply fragments
-- and never mutate stock, so every mutation entry fails loudly instead of
-- reaching a live owner. The failure itself is the isolation proof.
---@return table<string, fun(...): boolean> refusing battle-local bag commands
local function refusingBagCommands()
  local function refuse()
    error("battle children never mutate live stock", 0)
  end
  return { toss = refuse, move = refuse, register = refuse, unregister = refuse }
end

-- Battle-local party facts model over the detached roster: slot occupancy
-- comes from the snapshot, eligibility from the authoritative kernel
-- fragments, and health/status from the snapshot health. The controller
-- navigates, selects, and refuses through these facts; live party state is
-- never consulted.
---@param roster table<integer, table<string, unknown>> detached own-party snapshot under projection
---@param eligible table<integer, boolean> eligible combatants under projection
---@return table<string, unknown> battle-local party facts model
local function battlePartyModel(roster, eligible)
  local function refreshModel()
    local slots = {}
    for slot = 0, 5 do
      slots[slot + 1] = { occupied = false, eligible = false }
    end
    for _, record in ipairs(roster) do
      if type(record) == "table" and type(record.slot) == "number" and type(record.combatant) == "number" then
        assert(slots[record.slot + 1] ~= nil, "battle roster slots stay unique")
        local fainted = (tonumber(record.hp) or 0) <= 0
        slots[record.slot + 1] = {
          occupied = true,
          eligible = eligible[record.combatant] == true,
          combatant = record.combatant,
          displayName = type(record.name) == "string" and record.name or "Unknown",
          level = record.level,
          currentHp = tonumber(record.hp) or 0,
          maxHp = tonumber(record.maxHp) or 0,
          status = fainted and "faint" or "ok",
        }
      end
    end
    return { revision = 1, slots = slots }
  end
  return { refresh = refreshModel }
end

-- Battle-local summary facts model over the staged learning prompt: the
-- four held rows carry their staged move, PP, and upgrade facts with the
-- incoming move flagged, in slot order. The move-pick presentation
-- navigates and selects through these facts; no live mon is ever edited.
---@param prompt table<string, unknown> staged learning prompt under projection
---@return table<string, unknown> battle-local summary facts model
---@return table<integer, table<string, unknown>> held-move fact rows in slot order
local function battleSummaryModel(prompt)
  local moves = assert(prompt.currentMoves, "learning prompts carry their held move set")
  assert(type(moves) == "table" and #moves == 4, "learning prompts carry four held moves")
  local incoming = prompt.incomingMove
  local rows = {}
  for slot = 1, 4 do
    local entry = moves[slot]
    assert(type(entry) == "table", "held moves arrive as records")
    rows[slot] = {
      kind = "move",
      slot = slot - 1,
      move = entry.move,
      pp = entry.pp,
      ppUps = entry.ppUps,
      incoming = entry.move == incoming,
    }
  end
  local function refreshModel(_)
    return { revision = 1, slotCount = 1, moves = copyValue(rows), incomingMove = incoming }
  end
  local model = { refresh = refreshModel }
  return model, rows
end

-- Resolves one projected learning fragment by choice identity. Stale or
-- refused identities resolve to nil so no invented reply can seal.
---@param options table<string, unknown> decision options under translation
---@param id string projected learning choice identity under translation
---@return table<string, unknown>? projected choice fragment, nil when absent or refused
local function learnFragment(options, id)
  if type(options.actors) ~= "table" then
    return nil
  end
  for _, actor in ipairs(options.actors) do
    if type(actor) == "table" and type(actor.choices) == "table" then
      for _, choice in ipairs(actor.choices) do
        if type(choice) == "table" and choice.id == id and choice.enabled == true then
          return choice.choice --[[@as table<string, unknown>]]
        end
      end
    end
  end
  return nil
end

---@param kind string composed child kind under construction
---@param intent table<string, unknown> validated child intent under construction
---@return table<string, unknown> bound barrier identity shared by the child
local function childIdentity(kind, intent)
  return {
    kind = kind,
    launchId = intent.launchId,
    requestId = intent.requestId,
    epoch = intent.epoch,
    controller = intent.controller,
  }
end

-- Routes one semantic edge batch to a real application controller. Only
-- the barrier-owned semantic edges travel: navigation, confirmation,
-- cancellation, pointer-capture release, and the barrier-synthesized tap
-- pointer pairs at canonical modal centers. Raw pointer press topology
-- stays with the barrier so a held or stale press can never arm
-- controller state; the controllers observe only matched synthetic pairs.
---@param controller table<string, unknown> real application controller under stepping
---@param events table<integer, table<string, unknown>> semantic input batch under routing
local function routeSemantic(controller, events)
  local batch = {}
  for _, event in ipairs(events) do
    if type(event) == "table" and type(event.type) == "string" then
      if
        event.type == "navigate"
        or event.type == "confirm"
        or event.type == "cancel"
        or event.type == "pointer_cancel"
        or event.type == "pointer_down"
        or event.type == "pointer_up"
      then
        batch[#batch + 1] = event
      end
    else
      break
    end
  end
  if #batch == 0 then
    return
  end
  if type(controller.applyEvent) == "function" then
    local apply = controller.applyEvent --[[@as fun(self: table<string, unknown>, event: table<string, unknown>)]]
    for _, event in ipairs(batch) do
      if event.type == "pointer_cancel" then
        apply(controller, event)
      else
        apply(controller, event)
      end
    end
    return
  end
  local step = controller.updateFixed --[[@as fun(self: table<string, unknown>, events: table<integer, table<string, unknown>>)]]
  assert(type(step) == "function", "composed controllers step their semantic batch")
  step(controller, batch)
end

---@param controller table<string, unknown> real application controller under draining
---@return table<string, unknown>? drained native intent, nil when the controller staged nothing
local function drainIntent(controller)
  local take = controller.takeIntent
  if type(take) ~= "function" then
    return nil
  end
  local emit = take --[[@as fun(self: table<string, unknown>): table<string, unknown>?]]
  return emit(controller)
end

---@param controller table<string, unknown> real application controller under draining
---@return table<string, unknown>? drained native result, nil when the controller sealed nothing
local function drainResult(controller)
  local take = controller.takeResult
  if type(take) ~= "function" then
    return nil
  end
  local emit = take --[[@as fun(self: table<string, unknown>): table<string, unknown>?]]
  return emit(controller)
end

-- Harvests one-shot native evidence into the child stash without
-- translating it: the barrier binds authoritative kernel fragments while
-- native intents and results stay observable exactly as the application
-- owners sealed them. The stash keeps the latest evidence per slot.
---@param child table<string, unknown> composed child under harvesting
---@param controller table<string, unknown>? real application controller under harvesting
local function harvest(child, controller)
  if controller == nil then
    return
  end
  local intent = drainIntent(controller)
  if intent ~= nil then
    child._nativeIntent = intent
  end
  local result = drainResult(controller)
  if result ~= nil then
    child._nativeResult = result
  end
end

-- Composes the native Bag application in its battle context over the
-- detached stock. The kernel item policy drives the native refusal path;
-- stock mutation entries refuse loudly. Target selection composes the
-- native Party application in its item-target context on demand: the
-- retained bag browser keeps its pocket, focus, scroll, and counts while
-- the target picker owns input, and cancelling the target disposes only
-- the target picker.
---@param intent table<string, unknown> validated bag intent under composition
---@param services table<string, unknown> borrowed battle services under composition
---@return table<string, unknown>? composed bag child
---@return string? failure cause
local function openBagChild(intent, services)
  assert(type(intent.inventory) == "table", "bag children carry their detached stock")
  assert(type(intent.options) == "table", "bag children carry their decision options")
  local options = intent.options --[[@as table<string, unknown>]]
  local service = battleBagService(intent.inventory --[[@as table<string, integer>]], services.itemCatalog)
  local cursor = BagCursor.new()
  local function refreshModel()
    return BagModel.build(service, cursor, services.monCatalog)
  end
  local model = { refresh = refreshModel }
  local function policyEnabled(itemKey)
    local legal, _ = itemLegality(options, itemKey)
    return legal
  end
  local function policyReason(itemKey)
    local _, reason = itemLegality(options, itemKey)
    return reason
  end
  local policy = { isEnabled = policyEnabled, reason = policyReason }
  local function emptyLayout()
    return { hitTest = battleBagHit }
  end
  local function noFieldActions()
    return {}
  end
  local ok, controller = pcall(BagController.new, {
    model = model,
    cursor = cursor,
    resolveLayout = emptyLayout,
    commands = refusingBagCommands(),
    resolveActions = noFieldActions,
    context = "battle",
    battlePolicy = policy,
  })
  if not ok then
    return nil, tostring(controller)
  end
  local identity = childIdentity("bag", intent)
  local child = {
    _kind = "bag",
    _identity = identity,
    _application = BattleChildApplications.RECEIPTS.bag,
    _controller = controller,
    _options = options,
    _party = intent.party,
    _target = nil,
    _nativeIntent = nil,
    _nativeResult = nil,
    _targetIntent = nil,
    _targetResult = nil,
    _taken = false,
    _disposed = false,
  }
  -- Opens native item-target selection for one staged serving: a second
  -- Party application in its item-target context over the detached roster,
  -- gated by the kernel item fragments for the staged key. The retained
  -- bag browser is untouched.
  ---@param itemKey string staged battle item identity under targeting
  function child:openTarget(itemKey)
    assert(type(itemKey) == "string" and itemKey ~= "", "target selection stages its item")
    self:closeTarget()
    local roster = assert(self._party, "target selection reads the detached roster")
    assert(type(roster) == "table", "target selection reads the detached roster")
    local targets = enabledItemTargets(self._options, itemKey)
    local eligible = {}
    for combatant in pairs(targets) do
      eligible[combatant] = true
    end
    local target, targetErr = BattleChildApplications.openTargetPicker(roster, eligible, itemKey, services)
    if target == nil then
      error(targetErr, 0)
    end
    self._target = target
  end
  -- Disposes only the target picker, keeping the retained bag browser.
  -- A disposed picker owns no input and seals nothing, so its pending
  -- evidence clears with it instead of leaking into the next picker.
  function child:closeTarget()
    if self._target ~= nil then
      self._target:dispose()
      self._target = nil
    end
    self._targetIntent = nil
    self._targetResult = nil
  end
  ---@param events table<integer, table<string, unknown>> semantic input batch under routing
  function child:input(events)
    if self._disposed or self._taken then
      return
    end
    if self._target ~= nil then
      local targetController = self._target._controller
      routeSemantic(targetController, expandTaps("target", events))
      local targetIntent = drainIntent(targetController)
      if targetIntent ~= nil then
        self._targetIntent = targetIntent
      end
      local targetResult = drainResult(targetController)
      if targetResult ~= nil then
        self._targetResult = targetResult
      end
      return
    end
    routeSemantic(self._controller, expandTaps("bag", events))
    harvest(self, self._controller)
  end
  ---@param _ integer source ticks under stepping (event-stepped controllers keep no clock)
  function child:stepSourceTick(_) end
  ---@param _ table<string, unknown>? borrowed display facts (the returned record is renderer-agnostic data)
  ---@return table<string, unknown> drawable bag record from the native application
  function child:draw(_)
    local view = self._controller:status()
    assert(type(view) == "table", "the native bag projects its drawable record")
    return view
  end
  -- Reports the native application receipt for the overlay currently
  -- owning input: the item-target picker is a Party application, the
  -- resting browser is the Bag application.
  ---@return string native application receipt
  function child:application()
    if self._target ~= nil then
      return BattleChildApplications.RECEIPTS.party
    end
    return self._application
  end
  ---@return table<string, unknown> child status with its application receipt
  function child:status()
    return {
      active = not self._disposed,
      kind = "bag",
      application = self._application,
      native = self._nativeIntent or self._nativeResult,
    }
  end
  -- Drains one native battle selection intent without sealing: the item
  -- identity and its service revision snapshot for the owning barrier to
  -- translate against the current kernel fragments.
  ---@return table<string, unknown>? battle selection intent, nil when the browser staged nothing
  function child:takeBagIntent()
    harvest(self, self._controller)
    local stashed = self._nativeIntent
    self._nativeIntent = nil
    if type(stashed) == "table" and stashed.kind == "battle_select" and type(stashed.item) == "string" then
      return stashed
    end
    return nil
  end
  -- Drains one native browser close without sealing: a closed empty or
  -- cancelled browser reports its navigation cancellation exactly once.
  ---@return table<string, unknown>? browser close report, nil while the browser stays open
  function child:takeBagClose()
    harvest(self, self._controller)
    local result = self._nativeResult
    self._nativeResult = nil
    if type(result) == "table" and result.kind == "closed" then
      return { kind = "closed" }
    end
    return nil
  end
  -- Drains one native item-target outcome without sealing: a compatible
  -- target reports its slot and item while a cancelled picker reports
  -- its navigation cancellation. Exactly once per native seal.
  ---@return table<string, unknown>? target outcome, nil while the picker stays open
  function child:takeTargetOutcome()
    if self._target == nil then
      return nil
    end
    local stashed = self._targetIntent
    self._targetIntent = nil
    if type(stashed) == "table" and stashed.kind == "use_item" and type(stashed.slot) == "number" then
      return { kind = "use_item", slot = stashed.slot, item = stashed.item }
    end
    local result = self._targetResult
    self._targetResult = nil
    if type(result) == "table" and result.kind == "cancelled" then
      return { kind = "cancelled" }
    end
    return nil
  end
  ---@return table<string, unknown>? native target picker status, nil without its picker
  function child:targetStatus()
    if self._target == nil then
      return nil
    end
    return self._target._controller:status()
  end
  ---@return table<string, unknown>? bound result, exactly once
  function child:takeResult()
    harvest(self, self._controller)
    local result = self._nativeResult
    if type(result) == "table" and result.kind == "closed" then
      return takeChildResult(self, "cancelled")
    end
    return nil
  end
  function child:dispose()
    if self._disposed then
      return
    end
    self._disposed = true
    -- Disposal discards pending native evidence: a disposed child owns no
    -- input and seals nothing, so stale intents never report afterwards.
    self._nativeIntent = nil
    self._nativeResult = nil
    self:closeTarget()
    self._controller:dispose()
  end
  return child
end

-- Composes one native Party target picker in its item-target context over
-- the detached roster. The kernel item fragments for the staged serving
-- own eligibility through the injected action policy; the picker stages
-- value-only intents and never touches live party state.
---@param roster table<integer, table<string, unknown>> detached own-party snapshot under composition
---@param eligible table<integer, boolean> eligible combatants under composition
---@param itemKey string staged battle item identity under composition
---@param services table<string, unknown> borrowed battle services under composition
---@return table<string, unknown>? composed target picker
---@return string? failure cause
function BattleChildApplications.openTargetPicker(roster, eligible, itemKey, services)
  assert(type(roster) == "table", "target pickers read the detached roster")
  assert(type(itemKey) == "string" and itemKey ~= "", "target pickers stage their item")
  local model = battlePartyModel(roster, eligible)
  local function evaluateTarget(record, _)
    assert(type(record) == "table", "target evaluation reads its slot record")
    if eligible[record.combatant] == true then
      return { compatible = true }
    end
    return { compatible = false, note = "That choice is unavailable." }
  end
  local policy = { evaluateTarget = evaluateTarget }
  local function targetLayout()
    return { neighbors = PartyScreenLayout.defaultNeighbors(true), hitTest = battlePartyHit }
  end
  local _ = services
  local ok, controller = pcall(PartyScreenController.new, {
    context = "item_target",
    model = model,
    layout = targetLayout,
    item = { key = itemKey, bagRevision = 1 },
    allowCancel = true,
    actionPolicy = policy,
  })
  if not ok then
    return nil, tostring(controller)
  end
  local picker = { _controller = controller, _disposed = false }
  ---@param events table<integer, table<string, unknown>> semantic input batch under routing
  function picker:input(events)
    if not self._disposed then
      routeSemantic(self._controller, events)
    end
  end
  ---@param events table<integer, table<string, unknown>> semantic input batch under stepping
  function picker:updateFixed(events)
    if not self._disposed then
      self._controller:updateFixed(events)
    end
  end
  function picker:dispose()
    if not self._disposed then
      self._disposed = true
      self._controller:dispose()
    end
  end
  return picker
end

-- Composes the native Party application in its pick context over the
-- detached roster. Eligibility comes from the authoritative kernel switch
-- fragments; the picker seals value-only selection results and never
-- touches live party state.
---@param intent table<string, unknown> validated party intent under composition
---@param services table<string, unknown> borrowed battle services under composition
---@return table<string, unknown>? composed party child
---@return string? failure cause
local function openPartyChild(intent, services)
  assert(type(intent.options) == "table", "party children carry their decision options")
  assert(type(intent.party) == "table", "party children carry their detached roster")
  local options = intent.options --[[@as table<string, unknown>]]
  local switches = enabledSwitches(options)
  if next(switches) == nil then
    return nil, "no eligible reserve answers the request"
  end
  local eligible = {}
  for _, byReplacement in pairs(switches) do
    for combatant in pairs(byReplacement) do
      eligible[combatant] = true
    end
  end
  local _ = services
  local model = battlePartyModel(intent.party --[[@as table<integer, table<string, unknown>>]], eligible)
  local function pickLayout()
    return {
      neighbors = PartyScreenLayout.defaultNeighbors(intent.cancellable == true),
      hitTest = battlePartyHit,
    }
  end
  local ok, controller = pcall(PartyScreenController.new, {
    context = "pick",
    model = model,
    layout = pickLayout,
    allowCancel = intent.cancellable == true,
  })
  if not ok then
    return nil, tostring(controller)
  end
  local identity = childIdentity("party", intent)
  local child = {
    _kind = "party",
    _identity = identity,
    _application = BattleChildApplications.RECEIPTS.party,
    _controller = controller,
    _options = options,
    _nativeIntent = nil,
    _nativeResult = nil,
    _taken = false,
    _disposed = false,
  }
  ---@param events table<integer, table<string, unknown>> semantic input batch under routing
  function child:input(events)
    if self._disposed or self._taken then
      return
    end
    routeSemantic(self._controller, expandTaps("party", events))
    harvest(self, self._controller)
  end
  ---@param _ integer source ticks under stepping (event-stepped controllers keep no clock)
  function child:stepSourceTick(_) end
  ---@param _ table<string, unknown>? borrowed display facts (the returned record is renderer-agnostic data)
  ---@return table<string, unknown> drawable party record from the native application
  function child:draw(_)
    local view = self._controller:status()
    assert(type(view) == "table", "the native party projects its drawable record")
    return view
  end
  ---@return string native application receipt
  function child:application()
    return self._application
  end
  ---@return table<string, unknown> child status with its application receipt
  function child:status()
    return {
      active = not self._disposed,
      kind = "party",
      application = self._application,
      native = self._nativeIntent or self._nativeResult,
    }
  end
  -- Translates one native selection result into the authoritative switch
  -- fragment it names. Stale slots (no kernel fragment) translate to nil
  -- so no invented reply can seal.
  ---@param slot integer native roster slot under translation
  ---@return table<string, unknown>? authoritative switch fragment, nil when stale
  function child:translateSelection(slot)
    local roster = intent.party --[[@as table<integer, table<string, unknown>>]]
    local combatant = nil
    for _, record in ipairs(roster) do
      if type(record) == "table" and record.slot == slot and type(record.combatant) == "number" then
        combatant = record.combatant
        break
      end
    end
    if combatant == nil then
      return nil
    end
    local actors = options.actors --[[@as table<integer, table<string, unknown>>?]]
    if type(actors) ~= "table" then
      return nil
    end
    for _, actor in ipairs(actors) do
      if type(actor) == "table" and type(actor.choices) == "table" then
        for _, choice in ipairs(actor.choices) do
          if
            type(choice) == "table"
            and choice.enabled == true
            and type(choice.choice) == "table"
            and choice.choice.kind == "switch"
            and type(choice.choice.payload) == "table"
            and choice.choice.payload.replacement == combatant
          then
            return choice.choice --[[@as table<string, unknown>]]
          end
        end
      end
    end
    return nil
  end
  ---@return table<string, unknown>? bound result, exactly once
  function child:takeResult()
    harvest(self, self._controller)
    local result = self._nativeResult
    if type(result) ~= "table" then
      return nil
    end
    if result.kind == "selected" and type(result.slot) == "number" then
      local fragment = self:translateSelection(result.slot)
      if fragment ~= nil then
        return takeChildResult(self, "choice", fragment)
      end
      return nil
    end
    if result.kind == "cancelled" then
      return takeChildResult(self, "cancelled")
    end
    return nil
  end
  function child:dispose()
    if self._disposed then
      return
    end
    self._disposed = true
    -- Disposal discards pending native evidence: a disposed child owns no
    -- input and seals nothing, so stale intents never report afterwards.
    self._nativeIntent = nil
    self._nativeResult = nil
    self._controller:dispose()
  end
  return child
end

-- Composes the native summary/move-selection presentation in move-pick
-- mode over the staged learning prompt. The facts model projects the same
-- held-move facts the presentation navigates; move_pick mode never
-- reorders, so the held set cannot mutate through selection. Held-move
-- detail facts stay readable through moveFacts for the barrier view.
-- Composes the native summary/move-selection presentation in move-pick
-- mode over one staged learning prompt. The facts model projects the
-- same held-move facts the presentation navigates; move_pick mode never
-- reorders, so the held set cannot mutate through selection. Shared by
-- the battle-action learning child and the post-battle evolution child,
-- which carries no kernel fragments and answers its own domain instead.
---@param prompt table<string, unknown> staged learning prompt under composition
---@return table<string, unknown>? composed move picker
---@return string? failure cause
local function composeLearnPicker(prompt)
  assert(type(prompt) == "table", "learning pickers carry their staged prompt")
  local model, _ = battleSummaryModel(prompt)
  local function summaryLayout()
    return { hitTest = battleLearnHit }
  end
  local ok, controller = pcall(SummaryController.new, {
    mode = "move_pick",
    model = model,
    resolveLayout = summaryLayout,
    -- Move-pick mode never reorders and samples no live navigation: both
    -- collaborators stay explicitly absent, which the controller asserts.
    reorderMoves = nil,
    readNavigation = nil,
    -- Battle learning borrows the picker's fifth keep-moves row through
    -- the machine replacement context: the native row cancels instead of
    -- sealing, and the barrier interprets that cancel as decline intent
    -- while every other cancel stays a stop question. Held rows seal
    -- their move selection natively exactly like the machine flow.
    request = {
      kind = "learn",
      context = "replace_machine",
      prospectiveMove = prompt.incomingMove,
      incomingMove = prompt.incomingMove,
    },
  })
  if not ok then
    return nil, tostring(controller)
  end
  return controller
end

-- Drains one native move-picker outcome without sealing: a selected
-- row reports its move slot while a cancelled picker reports the
-- focused row it cancelled from. Exactly once per native seal.
---@param result table<string, unknown>? drained native picker result under parsing
---@param lastFocus integer focused move slot before the draining batch
---@return table<string, unknown>? picker outcome, nil while the picker stays open
local function parsePickerOutcome(result, lastFocus)
  if type(result) ~= "table" then
    return nil
  end
  if result.kind == "move_selected" and type(result.moveSlot) == "number" then
    return { kind = "move_selected", moveSlot = result.moveSlot, focus = result.moveSlot }
  end
  if result.kind == "cancelled" then
    return { kind = "cancelled", focus = lastFocus }
  end
  return nil
end

---@param intent table<string, unknown> validated learning intent under composition
---@param services table<string, unknown> borrowed battle services under composition
---@return table<string, unknown>? composed learning child
---@return string? failure cause
local function openLearnChild(intent, services)
  local request = assert(intent.request, "learning children carry their staged prompt")
  assert(type(request) == "table", "learning children carry their staged prompt")
  assert(type(intent.options) == "table", "learning children carry their decision options")
  local _, rows = battleSummaryModel(request --[[@as table<string, unknown>]])
  local _ = services
  local controller, controllerErr = composeLearnPicker(request --[[@as table<string, unknown>]])
  if controller == nil then
    return nil, controllerErr
  end
  local identity = childIdentity("learn", intent)
  local options = intent.options --[[@as table<string, unknown>]]
  local child = {
    _kind = "learn",
    _identity = identity,
    _application = BattleChildApplications.RECEIPTS.learn,
    _controller = controller,
    _facts = rows,
    _options = options,
    _nativeIntent = nil,
    _nativeResult = nil,
    _lastFocus = 0,
    _taken = false,
    _disposed = false,
  }
  ---@return table<integer, table<string, unknown>> held-move detail facts in slot order
  function child:moveFacts()
    return copyValue(self._facts)
  end
  ---@param events table<integer, table<string, unknown>> semantic input batch under routing
  function child:input(events)
    if self._disposed or self._taken then
      return
    end
    -- Snapshot the picker focus before the batch runs: a terminal cancel
    -- closes the controller, so the barrier interprets that cancel
    -- against the row the picker showed when the batch arrived.
    local before = self._controller:status()
    if type(before) == "table" and before.open ~= false then
      self._lastFocus = before.moveSlot
    end
    routeSemantic(self._controller, expandTaps("learn", events))
    harvest(self, self._controller)
  end
  -- Drains one native move-picker outcome without sealing: a selected
  -- row reports its move slot while a cancelled picker reports the
  -- focused row it cancelled from. Exactly once per native seal.
  ---@return table<string, unknown>? picker outcome, nil while the picker stays open
  function child:takeLearnOutcome()
    harvest(self, self._controller)
    local result = self._nativeResult
    self._nativeResult = nil
    return parsePickerOutcome(result, self._lastFocus)
  end
  ---@param _ integer source ticks under stepping (event-stepped controllers keep no clock)
  function child:stepSourceTick(_) end
  ---@param _ table<string, unknown>? borrowed display facts (the returned record is renderer-agnostic data)
  ---@return table<string, unknown> drawable summary record from the native presentation
  function child:draw(_)
    local view = self._controller:status()
    assert(type(view) == "table", "the native summary projects its drawable record")
    return view
  end
  ---@return string native application receipt
  function child:application()
    return self._application
  end
  ---@return table<string, unknown> child status with its application receipt
  function child:status()
    return {
      active = not self._disposed,
      kind = "learn",
      application = self._application,
      native = self._nativeIntent or self._nativeResult,
    }
  end
  -- Translates one native move selection into the authoritative learning
  -- fragment it names: held slots bind their replace identity, the
  -- decline row binds its decline identity. Anything else translates to
  -- nil so no invented reply can seal.
  ---@param moveSlot integer native move slot under translation (0..3 held, 4 decline)
  ---@return table<string, unknown>? authoritative learning fragment, nil when stale
  function child:translateSelection(moveSlot)
    if type(moveSlot) ~= "number" or moveSlot % 1 ~= 0 then
      return nil
    end
    if moveSlot >= 0 and moveSlot <= 3 then
      return learnFragment(self._options, "learn:replace:" .. tostring(moveSlot))
    end
    if moveSlot == 4 then
      return learnFragment(self._options, "learn:decline")
    end
    return nil
  end
  ---@return table<string, unknown>? bound result, exactly once
  function child:takeResult()
    harvest(self, self._controller)
    local result = self._nativeResult
    if type(result) ~= "table" then
      return nil
    end
    if result.kind == "move_selected" and type(result.moveSlot) == "number" then
      local fragment = self:translateSelection(result.moveSlot)
      if fragment ~= nil then
        return takeChildResult(self, "choice", fragment)
      end
      return nil
    end
    if result.kind == "cancelled" then
      return takeChildResult(self, "cancelled")
    end
    return nil
  end
  function child:dispose()
    if self._disposed then
      return
    end
    self._disposed = true
    -- Disposal discards pending native evidence: a disposed child owns no
    -- input and seals nothing, so stale intents never report afterwards.
    self._nativeIntent = nil
    self._nativeResult = nil
    self._controller:dispose()
  end
  return child
end

-- Composes the existing naming screen for a captured subject. The subject
-- is the authoritative battle capture record the completion caller stages:
-- without it the real controller cannot name a species and the child
-- fails its boundary instead of inventing one. Text starts from the empty
-- default; the sealed text reports through takeResult exactly once.
---@param intent table<string, unknown> validated naming intent under composition
---@param services table<string, unknown> borrowed battle services under composition
---@return table<string, unknown>? composed naming child
---@return string? failure cause
local function openNamingChild(intent, services)
  local subject = intent.subject
  if type(subject) ~= "table" then
    return nil, "capture naming carries its committed subject"
  end
  if type(subject.species) ~= "number" or subject.species % 1 ~= 0 or subject.species <= 0 then
    return nil, "capture naming subjects name their species"
  end
  local charmap = services.charmap
  if charmap == nil then
    charmap = defaultCharmap()
  end
  assert(type(charmap) == "table", "capture naming maps its keyboard glyphs")
  local effect = services.effect
  if effect == nil then
    effect = silentNamingEffect
  end
  local namingSubject = { kind = "pokemon", species = subject.species }
  if subject.form ~= nil then
    namingSubject.form = subject.form
  end
  local ok, controller = pcall(NamingScreenController.new, {
    kind = "pokemon",
    maxLength = 10,
    initialText = "",
    charmap = charmap,
    subject = namingSubject,
    effect = effect,
  })
  if not ok then
    return nil, tostring(controller)
  end
  local identity = childIdentity("naming", intent)
  local child = {
    _kind = "naming",
    _identity = identity,
    _application = BattleChildApplications.RECEIPTS.naming,
    _controller = controller,
    _cancellable = intent.cancellable == true,
    _concluded = false,
    _disposed = false,
  }
  -- Routes one semantic edge batch to the native naming controller. Text
  -- and keyboard-cell edges travel beside navigation, confirmation, and
  -- cancellation; pointer press topology stays with the barrier.
  ---@param events table<integer, table<string, unknown>> semantic input batch under routing
  function child:input(events)
    if self._disposed or self._concluded then
      return
    end
    for _, event in ipairs(events) do
      if self._concluded then
        break
      end
      if type(event) ~= "table" or type(event.type) ~= "string" then
        break
      end
      if
        event.type == "navigate"
        or event.type == "confirm"
        or event.type == "cancel"
        or event.type == "text"
        or event.type == "name_cell"
        or event.type == "name_control"
        or event.type == "pointer_cancel"
      then
        if event.type == "cancel" and self._cancellable then
          self._concluded = "cancelled"
        else
          self._controller:applyEvent(event)
        end
      end
    end
  end
  ---@param tick integer source tick under stepping (advances the naming presentation clocks)
  function child:stepSourceTick(tick)
    if not self._disposed then
      self._controller:updateFixed(tick or 1)
    end
  end
  ---@param _ table<string, unknown>? borrowed display facts (the returned record is renderer-agnostic data)
  ---@return table<string, unknown> drawable naming record from the native screen
  function child:draw(_)
    local view = self._controller:snapshot()
    assert(type(view) == "table", "the native naming screen projects its drawable record")
    return view
  end
  ---@return string native application receipt
  function child:application()
    return self._application
  end
  ---@return table<string, unknown> child status with its application receipt
  function child:status()
    return {
      active = not self._disposed,
      kind = "naming",
      application = self._application,
      text = self._controller:text(),
    }
  end
  ---@return string current staged text (never seals on read)
  function child:namingText()
    return self._controller:text()
  end
  ---@return table<string, unknown>? bound result, exactly once
  function child:takeResult()
    if self._concluded == "cancelled" then
      self._concluded = true
      return {
        kind = "cancelled",
        requestId = self._identity.requestId,
        epoch = self._identity.epoch,
        controller = self._identity.controller,
        launchId = self._identity.launchId,
      }
    end
    if self._concluded then
      return nil
    end
    local sealed = self._controller:result()
    if type(sealed) ~= "table" or sealed.kind ~= "submit" then
      return nil
    end
    self._concluded = true
    return {
      kind = "choice",
      requestId = self._identity.requestId,
      epoch = self._identity.epoch,
      controller = self._identity.controller,
      launchId = self._identity.launchId,
      choice = { kind = "nickname", text = sealed.text },
    }
  end
  function child:dispose()
    self._disposed = true
  end
  return child
end

-- Adapts one staged learned-move prompt into held-move fact rows for the
-- native move picker: committed move points ride the subject record
-- while silently filled slots carry their exact catalog base points.
---@param prompt table<string, unknown> staged learned-move prompt under adaptation
---@param subject table<string, unknown> committed subject carrying its held move points
---@param catalog table<string, unknown> borrowed immutable mon catalog
---@return table<string, unknown> picker-shaped prompt with fact rows and the incoming move
local function learnFactsFor(prompt, subject, catalog)
  assert(type(prompt.currentMoves) == "table", "learning prompts carry their held move set")
  local held = {}
  for _, entry in ipairs(subject.moves or {}) do
    if type(entry) == "table" and type(entry.move) == "string" then
      held[entry.move] = entry
    end
  end
  local moveOf = catalog.move --[[@as fun(self: table<string, unknown>, key: string): table<string, unknown>]]
  assert(type(moveOf) == "function", "learning facts resolve through the mon catalog")
  local rows = {}
  for _, key in
    ipairs(prompt.currentMoves --[[@as table<integer, string>]])
  do
    assert(type(key) == "string" and key ~= "", "held moves name their move identity")
    local known = held[key]
    if known ~= nil then
      rows[#rows + 1] = { move = key, pp = known.pp, ppUps = known.ppUps }
    else
      local definition = moveOf(catalog, key)
      assert(type(definition) == "table", "filled moves resolve through the mon catalog")
      rows[#rows + 1] = { move = key, pp = definition.basePp, ppUps = 0 }
    end
  end
  return { currentMoves = rows, incomingMove = prompt.move }
end

-- Composes the native evolution presentation state for a committed
-- subject behind the full frozen trigger context: the detached subject,
-- its party slot, and the launch-frozen clock, party, and inventory
-- facts the domain needs. Eligibility, planning, and transformation
-- stay with the evolution domain; the state owns the native
-- animation/cry/message/input sequence, and each pending learned move
-- pauses on the same native Summary picker the battle-action learning
-- child uses. The child owns its state and picker leases and releases
-- both exactly once; results report once as a typed completion answer.
---@param intent table<string, unknown> validated evolution intent under composition
---@param services table<string, unknown> borrowed battle services under composition
---@return table<string, unknown>? composed evolution child
---@return string? failure cause
local function openEvolutionChild(intent, services)
  local EvolutionState = require("game.hgss.src.battle.BattleEvolutionState")
  local mon = intent.subject
  if type(mon) ~= "table" then
    return nil, "evolution children carry their committed subject"
  end
  local triggerContext = intent.context
  if type(triggerContext) ~= "table" then
    return nil, "evolution children carry their full trigger context"
  end
  if type(triggerContext.trigger) ~= "table" then
    return nil, "evolution children carry their trigger identity"
  end
  -- The frozen launch clock rides the context untouched: a missing
  -- clock fails here instead of inventing a default behind the domain.
  if type(triggerContext.timeOfDay) ~= "string" or triggerContext.timeOfDay == "" then
    return nil, "evolution children carry their frozen time of day"
  end
  local catalog = services.monCatalog
  if catalog == nil then
    return nil, "evolution children need their mon catalog"
  end
  local context = {}
  for key, value in pairs(triggerContext) do
    context[key] = copyValue(value)
  end
  if context.party == nil then
    context.party = {}
  end
  if context.inventory == nil then
    context.inventory = {}
  end
  local ok, state = pcall(EvolutionState.new, {
    mon = copyValue(mon),
    context = context,
    catalog = catalog,
  })
  if not ok then
    return nil, tostring(state)
  end
  local subject = copyValue(mon) --[[@as table<string, unknown>]]
  local identity = childIdentity("evolution", intent)
  local child = {
    _kind = "evolution",
    _identity = identity,
    _application = BattleChildApplications.RECEIPTS.evolution,
    _state = state,
    _subject = subject,
    _catalog = catalog,
    _picker = nil,
    _lastFocus = 0,
    _taken = false,
    _disposed = false,
  }
  -- Opens the native Summary picker for the pending learned move. The
  -- opening consumes its edge: the picker starts from its entry focus
  -- with no armed press and no staged outcome.
  ---@return string? failure cause, nil while the picker owns learning input
  function child:_ensurePicker()
    if self._picker ~= nil then
      return nil
    end
    local prompt = self._state:learnPrompt()
    if prompt == nil then
      return nil
    end
    local adapted = learnFactsFor(prompt, self._subject, self._catalog)
    local picker, pickerErr = composeLearnPicker(adapted)
    if picker == nil then
      return "evolution learning failed for launch " .. tostring(self._identity.launchId) .. ": " .. tostring(pickerErr)
    end
    self._picker = picker
    return nil
  end
  -- Drains one sealed picker outcome into the staged learning answer: a
  -- held row replaces its slot while any cancellation declines the
  -- incoming move. Exactly once per native seal.
  function child:_drainPicker()
    local picker = self._picker
    if picker == nil then
      return
    end
    local drain = picker.takeResult --[[@as fun(self: table<string, unknown>): table<string, unknown>?]]
    local outcome = parsePickerOutcome(drain(picker), self._lastFocus)
    if outcome == nil then
      return
    end
    if outcome.kind == "move_selected" then
      self._state:answerLearn({ choice = "replace", slot = outcome.moveSlot })
    else
      self._state:answerLearn({ choice = "decline" })
    end
    picker:dispose()
    self._picker = nil
  end
  ---@param events table<integer, table<string, unknown>> semantic input batch under routing
  function child:input(events)
    if self._disposed or self._taken then
      return
    end
    local pickerErr = self:_ensurePicker()
    if pickerErr ~= nil then
      error(pickerErr, 0)
    end
    local picker = self._picker
    if picker ~= nil then
      local before = picker:status()
      if type(before) == "table" and before.open ~= false then
        self._lastFocus = before.moveSlot
      end
      routeSemantic(picker, expandTaps("learn", events))
      self:_drainPicker()
      return
    end
    self._state:input(events)
  end
  ---@param tick integer source tick under stepping
  function child:stepSourceTick(tick)
    if self._disposed or self._taken then
      return
    end
    local pickerErr = self:_ensurePicker()
    if pickerErr ~= nil then
      error(pickerErr, 0)
    end
    -- The picker is event-stepped and keeps no clock; only the
    -- animation state advances on source ticks.
    if self._picker == nil then
      self._state:stepSourceTick(tick)
    end
  end
  ---@param _ table<string, unknown>? borrowed display facts (the returned record is renderer-agnostic data)
  ---@return table<string, unknown> drawable evolution record from the native presentation or picker
  function child:draw(_)
    local picker = self._picker
    if picker ~= nil then
      local view = picker:status()
      assert(type(view) == "table", "the native summary projects its drawable record")
      return view
    end
    return self._state:draw()
  end
  ---@return string native application receipt
  function child:application()
    return self._application
  end
  ---@return table<string, unknown> child status with its application receipt
  function child:status()
    local inner = self._state:status()
    assert(type(inner) == "table", "the evolution state reports its status")
    inner.application = self._application
    return inner
  end
  ---@return table<integer, table<string, unknown>> sequenced effect requests in order (read-only evidence)
  function child:effects()
    return self._state:effects()
  end
  ---@return table<string, unknown>? pending learned-move prompt, nil outside the learning pause
  function child:learnPrompt()
    return self._state:learnPrompt()
  end
  ---@return table<string, unknown>? bound typed result, exactly once
  function child:takeResult()
    if self._taken then
      return nil
    end
    local settled = self._state:takeResult()
    if settled == nil then
      return nil
    end
    assert(type(settled) == "table", "the evolution state settles its result")
    self._taken = true
    local choice = assert(settled.choice, "evolution results carry their choice")
    local bound = {
      requestId = self._identity.requestId,
      epoch = self._identity.epoch,
      controller = self._identity.controller,
      launchId = self._identity.launchId,
    } --[[@as table<string, unknown>]]
    if choice.evolved == true then
      bound.kind = "evolution_complete"
      bound.staged = copyValue(assert(choice.staged, "completed evolutions carry their staged result"))
    else
      bound.kind = "evolution_cancelled"
      bound.reason = choice.reason
    end
    return bound
  end
  function child:dispose()
    if self._disposed then
      return
    end
    self._disposed = true
    -- Disposal releases both leases exactly once: a disposed child owns
    -- no input and seals nothing, so stale learning never reports
    -- afterwards.
    local picker = self._picker
    self._picker = nil
    if picker ~= nil then
      picker:dispose()
    end
    self._state:dispose()
  end
  return child
end

---@class BattleChildApplications.Services
---@field itemCatalog table<string, unknown>? borrowed immutable item catalog
---@field monCatalog table<string, unknown>? borrowed immutable mon catalog
---@field charmap table<string, integer>? injected generated font charmap for naming
---@field effect fun(sequence: string)? injected sound boundary for naming; silent when the host provides none

-- Opens the concrete child application for one barrier identity over
-- battle-local data and command adapters. The initiating input terminates
-- at the barrier: every composed controller starts from its entry state
-- with no armed press and no staged intent, so opening consumes the edge
-- that opened it. A composition failure reports its boundary and owns
-- nothing.
---@param intent table<string, unknown> child intent under composition
---@param services table<string, unknown>? borrowed battle services under composition
---@return table<string, unknown>? composed child application
---@return string? failure cause
function BattleChildApplications.open(intent, services)
  local ok, identity = pcall(checkIdentity, intent)
  if not ok then
    return nil, tostring(identity)
  end
  local owned = services or {}
  assert(type(owned) == "table", "battle child services arrive as a record")
  if identity.kind == "party" then
    return openPartyChild(intent, owned)
  elseif identity.kind == "bag" then
    return openBagChild(intent, owned)
  elseif identity.kind == "learn" then
    return openLearnChild(intent, owned)
  elseif identity.kind == "naming" then
    return openNamingChild(intent, owned)
  end
  return openEvolutionChild(intent, owned)
end

return BattleChildApplications
