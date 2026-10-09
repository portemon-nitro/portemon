-- Battle-local child selection over detached battle data. Voluntary
-- switch, forced replacement, and item-target selection run through
-- actual party screens in selection-only pick context, and bag browsing
-- runs through an actual bag screen in battle context; move learning
-- stays a battle-local typed prompt with no field screen behind it.
-- Each owned screen is driven headlessly: battle forwards one input
-- lane at a time and maps the screen's selection or close record to a
-- bound reply, while the screen's presentation plan is never drawn
-- (children keep rendering through the battle interface and renderer).
-- Children select only: every success copies a kernel-projected choice
-- fragment bound to the opening launch and request, every permitted Back
-- reports a bound cancellation, and stale or foreign input never seals.
-- No live party, bag, or save owner is touched; the kernel executes and
-- the committer publishes. The battle-owned read models translate the
-- frozen snapshots into the service facades the screens require; only
-- slot occupancy and kernel-projected eligibility cross that boundary,
-- and every other display fact stays inert.

local BagCursor = require("libs.hgss.src.items.BagCursor")
local BagScreenState = require("game.hgss.src.field.BagScreenState")
local PartyScreenLayout = require("libs.hgss.src.ui.PartyScreenLayout")
local PartyScreenState = require("game.hgss.src.field.PartyScreenState")
local ScreenTopology = require("libs.ui.src.ScreenTopology")

---@class BattleSubflows
---@field _launchId string owning launch identity
---@field _itemCatalog table<string, unknown>? borrowed immutable item catalog for pocket grouping
---@field _monCatalog table<string, unknown>? borrowed immutable mon catalog for machine display facts
---@field _measureDisplay fun(): table<string, unknown>? borrowed live display facts behind the headless screens
---@field _active string? live child kind: party, bag, target, or learn
---@field _purpose string? selection purpose behind the active child
---@field _cancellable boolean cancel permission behind the active child
---@field _requestId integer open request identity behind the active child
---@field _epoch integer open request epoch behind the active child
---@field _controller string open request controller behind the active child
---@field _pending table<string, unknown>? staged bound result awaiting collection
---@field _notice string? refusal explanation behind the active child
---@field _openOptionsValue table<string, unknown>? decision options behind the active child
---@field _openPartyValue table<integer, table<string, unknown>>? party snapshot behind the active child
---@field _bagEmpty boolean? true while the open bag carries no stock
---@field _partyScreen table<string, unknown>? owned headless party screen behind party or target selection
---@field _slotCombatants table<integer, integer>? stable combatant identity by party slot behind the active screen
---@field _fragments table<integer, table<string, unknown>>? projected fragments by eligible combatant
---@field _stagedItem string? staged battle item behind target selection
---@field _bagState table<string, unknown>? owned headless battle bag screen
---@field _retained table<string, unknown>? inert retained bag screen behind target selection
---@field _learn table<string, unknown>? active learning prompt state
---@field _disposed boolean
local BattleSubflows = {}
BattleSubflows.__index = BattleSubflows

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

---@param catalog table<string, unknown> borrowed immutable item catalog
---@param key string stocked item identity under lookup
---@return table<string, unknown> validated item record
local function catalogItem(catalog, key)
  local lookup = catalog.item --[[@as fun(collab: table<string, unknown>, key: string): table<string, unknown>]]
  assert(type(lookup) == "function", "the item catalog answers item records")
  local record = lookup(catalog, key)
  assert(type(record) == "table", "stocked items resolve through the catalog")
  return record --[[@as table<string, unknown>]]
end

---@param inventory table<string, integer> detached battle stock under adaptation
---@param revision integer snapshot revision under adaptation
---@param itemCatalog table<string, unknown> borrowed immutable item catalog
---@return table<string, unknown> read-only bag reads over the battle snapshot
local function battleBagService(inventory, revision, itemCatalog)
  local service = {}
  function service:pocketItems(pocketKey)
    local slots = {}
    for key, quantity in pairs(inventory) do
      if type(quantity) == "number" and quantity >= 1 then
        local record = catalogItem(itemCatalog, key)
        if record.pocket == pocketKey then
          slots[#slots + 1] = { item = key, quantity = quantity }
        end
      end
    end
    table.sort(slots, function(a, b)
      return a.item < b.item
    end)
    return slots
  end
  function service:catalog()
    return itemCatalog
  end
  function service:registeredItems()
    return {}
  end
  function service:revision()
    return revision
  end
  return service
end

-- The mon catalog facade behind the battle party read model: the
-- borrowed compiled catalog when one is threaded, otherwise a
-- snapshot-backed fallback answering the display facts the party model
-- requires. Selection consumes only slot occupancy and eligibility, so
-- the fallback names records from the snapshot and stays inert.
---@param monCatalog table<string, unknown>? borrowed immutable mon catalog
---@return table<string, unknown> catalog facade for the battle read model
local function readModelCatalog(monCatalog)
  if monCatalog ~= nil then
    return monCatalog
  end
  local catalog = {}
  function catalog:species(key)
    return { name = type(key) == "string" and key or "Unknown", genderRatio = 127 }
  end
  function catalog:item(key)
    if key == "NONE" then
      return { name = "None" }
    end
    return { name = type(key) == "string" and key or "Unknown", pocket = "items" }
  end
  function catalog:iconSelection(_)
    return "battle-party-icon"
  end
  return catalog
end

-- The battle-owned party read model: a live-mon-service facade over the
-- frozen detached snapshot. Slot occupancy, levels, health, holdings,
-- and move identities project from real snapshot facts; personality,
-- condition effects, and cosmetic records synthesize deterministically
-- because selection never consumes them. No live owner is referenced,
-- so switching through the screen can never reorder or heal.
---@param roster table<integer, table<string, unknown>> detached own-party snapshot under modeling
---@param monCatalog table<string, unknown>? borrowed immutable mon catalog
---@return table<string, unknown> live-mon-service facade over the frozen snapshot
local function battleMonService(roster, monCatalog)
  local bySlot = {}
  local count = 0
  for _, record in ipairs(roster) do
    if type(record) == "table" and type(record.slot) == "number" and type(record.combatant) == "number" then
      assert(bySlot[record.slot] == nil, "battle roster slots stay unique")
      bySlot[record.slot] = record
      count = math.max(count, record.slot + 1)
    end
  end
  local catalog = readModelCatalog(monCatalog)
  local service = {}
  function service:partyCount()
    return count
  end
  function service:partyRevision()
    return 1
  end
  function service:partyMon(slot)
    local record = assert(bySlot[slot], "battle party reads address a roster slot")
    local moves = {}
    if type(record.moves) == "table" then
      for _, entry in ipairs(record.moves) do
        if type(entry) == "table" and type(entry.move) == "string" and type(entry.pp) == "number" then
          moves[#moves + 1] = { move = entry.move, pp = entry.pp, ppUps = 0 }
        end
      end
    end
    return {
      species = record.species,
      form = record.form or 0,
      isEgg = false,
      personality = 0,
      nickname = record.name,
      heldItem = record.heldItem or "NONE",
      moves = moves,
      condition = { currentHp = record.hp, effects = {} },
      shinyLeaves = 0,
    }
  end
  function service:partyMonDerived(slot)
    local record = assert(bySlot[slot], "battle party derivation addresses a roster slot")
    return { maxHp = record.maxHp, level = record.level }
  end
  function service:catalog()
    return catalog
  end
  return service
end

---@param roster table<integer, table<string, unknown>> detached own-party snapshot under mapping
---@return table<integer, integer> stable combatant identity by party slot
local function slotCombatants(roster)
  local mapped = {}
  for _, record in ipairs(roster) do
    if type(record) == "table" and type(record.slot) == "number" and type(record.combatant) == "number" then
      mapped[record.slot] = record.combatant
    end
  end
  return mapped
end

-- Static display facts when no host measurement is threaded (detached
-- coverage only): the compact single-surface shape, which classifies
-- cleanly without describing any real display.
---@return table<string, unknown> detached single-surface display facts
local function staticMeasureDisplay()
  local topology = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = 256, height = 192 },
    touch = true,
    role = "world",
  })
  return {
    width = 256,
    height = 192,
    topology = topology,
    pixelRatio = 1,
    signature = "battle-child-headless:compact",
  }
end

local function inertRender(_, _, _) end

---@param event table<string, unknown> session-inverted logical input under passthrough
---@return table<string, unknown> the same event, unmapped
local function passInput(event, _, _)
  return event
end

-- Headless interface cases: every topology resolves to an inert plan
-- carrying only what its controller reads from the canonical content.
-- Keyboard input passes through untouched, and no case reads the bound
-- manifest, so battle supplies inert manifests below without duplicating
-- presentation geometry.
---@param content table<string, unknown> canonical controller content behind the inert plan
---@return table<string, fun(context: table<string, unknown>, view: table<string, unknown>): table<string, unknown>> per-case resolvers
local function headlessCases(content)
  local function inert(_, _)
    return {
      panes = {},
      frames = {},
      content = content,
      inputKey = "battle-headless",
      render = inertRender,
      mapInput = passInput,
    }
  end
  return {
    dualDisplay = inert,
    nativeLike = inert,
    wide = inert,
    tall = inert,
  }
end

---@param cancellable boolean cancel permission behind the party screen
---@return table<string, fun(context: table<string, unknown>, view: table<string, unknown>): table<string, unknown>> per-case resolvers
local function partyHeadlessCases(cancellable)
  return headlessCases({ neighbors = PartyScreenLayout.defaultNeighbors(cancellable) })
end

-- Icon preparation behind the headless party screens: icons are never
-- drawn on the battle path, so preparation reports ready at once and
-- releases trivially instead of borrowing the field icon pipeline.
---@param _ string[] icon keys under immediate preparation
---@return boolean ready
local function readyIcons(_)
  return true
end

local function dropIcons() end

-- The mon catalog behind the headless battle bag when none is
-- threaded: machine-move lookup fails closed exactly like the stocked
-- pre-check below, which keeps machine stock from opening without its
-- catalog before this stub could ever be exercised.
---@return table<string, unknown> fail-closed machine-move catalog
local function stubMonCatalog()
  local catalog = {}
  function catalog:moveByNativeId(_)
    error("battle headless bag resolves no machine moves", 2)
  end
  return catalog
end

local BATTLE_BAG_POCKETS = { "items", "medicine", "balls", "tmhm", "berries", "mail", "battle_items", "key_items" }

-- Inert headless bag presentation facts: bag screen construction asserts
-- the manifest carries its hero pane and interactive message, feedback,
-- transition, entry, and prompt records, so battle supplies inert
-- records in exactly those shapes. Nothing here is ever drawn, and the
-- headless cases above never read the manifest.
---@return table<string, unknown> inert headless bag manifest
local function battleBagManifest()
  local states = {}
  for _, pocket in ipairs(BATTLE_BAG_POCKETS) do
    states[#states + 1] =
      { pocket = pocket, pose = "pocket." .. pocket .. ".pose", pattern = "pocket." .. pocket .. ".pattern" }
  end
  local function framingRecord(angleX, angleY, distance, modelY)
    return { angleXDegrees = angleX, angleYDegrees = angleY, distance = distance, modelY = modelY }
  end
  local function pocketRecords(base)
    local records = {}
    for index, pocket in ipairs(BATTLE_BAG_POCKETS) do
      records[pocket] = framingRecord(base + index, base + 2 * index, 100 + 10 * index, 5 + index)
    end
    return records
  end
  return {
    hero = {
      animations = {
        states = states,
        material = { male = "bag.male.material", female = "bag.female.material" },
      },
      presentation = {
        framing = {
          transitionTicks = 7,
          baseline = { male = framingRecord(0, 0, 100, 5), female = framingRecord(1, 1, 110, 6) },
          byGender = { male = pocketRecords(10), female = pocketRecords(20) },
        },
      },
    },
    interactive = {
      text = {
        selectedItem = {
          segments = {
            { kind = "text", value = "The " },
            { kind = "item" },
            { kind = "text", value = " is selected." },
          },
        },
        movePrompt = {
          segments = {
            { kind = "text", value = "Move " },
            { kind = "item" },
            { kind = "text", value = "?" },
          },
        },
        tossConfirm = {
          segments = {
            { kind = "text", value = "Toss " },
            { kind = "quantity" },
            { kind = "text", value = " " },
            { kind = "item" },
            { kind = "text", value = "?" },
          },
        },
        tossResult = {
          segments = {
            { kind = "text", value = "Threw away " },
            { kind = "quantity" },
            { kind = "text", value = " " },
            { kind = "item" },
            { kind = "text", value = "." },
          },
        },
      },
      feedback = { totalTicks = 4 },
      moveTransition = { unchanged = { totalTicks = 3 }, changed = { totalTicks = 5 } },
      selectionEntry = { totalTicks = 3 },
      overlays = {
        tossPrompt = { x = 200, y = 48, shape = "compact", initialSelection = "yes" },
      },
    },
  }
end

-- Inert field-UI facts behind the headless battle bag: the battle
-- context never opens a modal prompt, so the asserted compact shape
-- stays empty.
---@return table<string, unknown> inert field-UI manifest
local function battleUiManifest()
  return { yesNoPrompt = { shapes = { compact = {} } } }
end

---@param reason string? supplied refusal reason under display
---@return string visible refusal text
local function refusalText(reason)
  if type(reason) == "string" and reason ~= "" then
    return reason
  end
  return "That choice is unavailable."
end

---@class BattleSubflows.Options
---@field launchId string owning launch identity
---@field itemCatalog table<string, unknown>? borrowed immutable item catalog for pocket grouping
---@field monCatalog table<string, unknown>? borrowed immutable mon catalog for machine display facts
---@field measureDisplay fun(): table<string, unknown>? borrowed live display facts behind the headless screens

---@param opts BattleSubflows.Options
---@return BattleSubflows
function BattleSubflows.new(opts)
  assert(type(opts) == "table", "battle children require options")
  assert(type(opts.launchId) == "string" and opts.launchId ~= "", "battle children need their launch identity")
  if opts.itemCatalog ~= nil then
    assert(type(opts.itemCatalog) == "table", "the item catalog arrives as a record")
  end
  if opts.monCatalog ~= nil then
    assert(type(opts.monCatalog) == "table", "the mon catalog arrives as a record")
  end
  if opts.measureDisplay ~= nil then
    assert(type(opts.measureDisplay) == "function", "the display facts arrive as a function")
  end
  return setmetatable({
    _launchId = opts.launchId,
    _itemCatalog = opts.itemCatalog,
    _monCatalog = opts.monCatalog,
    _measureDisplay = opts.measureDisplay,
    _active = nil,
    _purpose = nil,
    _cancellable = false,
    _requestId = 0,
    _epoch = 0,
    _controller = "",
    _pending = nil,
    _notice = nil,
    _openOptionsValue = nil,
    _openPartyValue = nil,
    _bagEmpty = nil,
    _partyScreen = nil,
    _slotCombatants = nil,
    _fragments = nil,
    _stagedItem = nil,
    _bagState = nil,
    _retained = nil,
    _learn = nil,
    _disposed = false,
  }, BattleSubflows)
end

---@param intent table<string, unknown> child intent under validation
local function checkIntent(intent)
  assert(type(intent) == "table", "child intents arrive as records")
  assert(
    intent.kind == "party" or intent.kind == "bag" or intent.kind == "learn",
    "child intents name party, bag, or learn"
  )
  assert(type(intent.purpose) == "string" and intent.purpose ~= "", "child intents name their purpose")
  assert(type(intent.launchId) == "string" and intent.launchId ~= "", "child intents carry their launch")
  assert(type(intent.requestId) == "number" and intent.requestId % 1 == 0, "child intents carry their request identity")
  assert(type(intent.epoch) == "number" and intent.epoch % 1 == 0, "child intents carry their epoch")
  assert(type(intent.controller) == "string" and intent.controller ~= "", "child intents carry their controller")
  assert(type(intent.request) == "table", "child intents carry their request")
  assert(type(intent.options) == "table", "child intents carry their options")
  assert(type(intent.party) == "table", "child intents carry their party snapshot")
  assert(type(intent.inventory) == "table", "child intents carry their inventory snapshot")
end

---@param options table<string, unknown> decision options under projection
---@return table<integer, table<string, unknown>> enabled switch fragments by replacement combatant
local function enabledSwitches(options)
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
          and choice.choice.kind == "switch"
          and type(choice.choice.payload) == "table"
          and type(choice.choice.payload.replacement) == "number"
        then
          found[choice.choice.payload.replacement] = choice.choice
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
---@return boolean legality true while a native choice can execute the item
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
            reason = choice.reason --[[@as string]]
          end
        end
      end
    end
  end
  return false, reason
end

-- Settles one owned headless screen before it owns input: the reveal
-- and settle gating runs through empty ticks, then the interactive
-- phase is verified so later input batches always act.
---@param screen table<string, unknown> owned headless screen under settling
---@param what string child kind under settling
local function settleScreen(screen, what)
  for _ = 1, 24 do
    screen:updateFixed({})
  end
  local status = screen:status()
  assert(status.phase == "interactive", "the headless " .. what .. " settles before input")
end

-- Opens one selection-only party screen over the battle read model:
-- the screen owns focus, navigation, and cancel permission through the
-- built pick capabilities, while battle keeps owning request binding
-- and fragment mapping. Construction failures report a reason instead
-- of opening a half-owned selection.
---@param roster table<integer, table<string, unknown>> detached own-party snapshot under opening
---@param eligible table<integer, boolean> eligible combatants under opening
---@param cancellable boolean cancel permission under opening
---@return table<string, unknown>? owned headless party screen, nil on failure
---@return string? failure cause
local function openPartyScreen(self, roster, eligible, cancellable)
  local mapped = slotCombatants(roster)
  local function eligibleSlot(slot)
    return eligible[mapped[slot]] == true
  end
  local measure = self._measureDisplay or staticMeasureDisplay
  local built, screen = pcall(PartyScreenState.new, {
    service = battleMonService(roster, self._monCatalog),
    manifest = {},
    context = "pick",
    selectionOnly = true,
    isEligible = eligibleSlot,
    canCancel = cancellable,
    measureDisplay = measure,
    prepareIcons = readyIcons,
    cancelIconPreparation = dropIcons,
    overrides = partyHeadlessCases(cancellable),
  })
  if not built then
    return nil, tostring(screen)
  end
  local settled, settleErr = pcall(settleScreen, screen, "party")
  if not settled then
    screen:dispose()
    return nil, tostring(settleErr)
  end
  return screen
end

-- Binds one projected fragment to the open launch and request. Fragments
-- are copied, never rebuilt, so the kernel keeps owning their shape.
---@param fragment table<string, unknown> projected choice fragment under binding
---@return table<string, unknown> bound staged reply
function BattleSubflows:_bind(fragment)
  return {
    requestId = self._requestId,
    epoch = self._epoch,
    controller = self._controller,
    launchId = self._launchId,
    choices = { copyValue(fragment) },
  }
end

-- Records the open identity and clears any previous child state. A new
-- open supersedes its predecessor without applying it.
---@param intent table<string, unknown> validated child intent under capture
function BattleSubflows:_capture(intent)
  self:closeChild()
  self._active = intent.kind --[[@as string]]
  self._purpose = intent.purpose --[[@as string]]
  self._cancellable = intent.cancellable == true
  self._requestId = intent.requestId --[[@as integer]]
  self._epoch = intent.epoch --[[@as integer]]
  self._controller = intent.controller --[[@as string]]
  self._openOptionsValue = intent.options --[[@as table<string, unknown>]]
  self._openPartyValue = intent.party --[[@as table<integer, table<string, unknown>>]]
  self._pending = nil
  self._notice = nil
end

---@param intent table<string, unknown> party selection intent under opening
---@return boolean opened
---@return string? failure cause
local function openParty(self, intent)
  local options = intent.options --[[@as table<string, unknown>]]
  local roster = intent.party --[[@as table<integer, table<string, unknown>>]]
  local fragments = enabledSwitches(options)
  local eligible = {}
  for combatant in pairs(fragments) do
    eligible[combatant] = true
  end
  if next(fragments) == nil then
    return false, "no eligible reserve answers the request"
  end
  self:_capture(intent)
  local screen, screenErr = openPartyScreen(self, roster, eligible, self._cancellable)
  if screen == nil then
    self:closeChild()
    return false, screenErr
  end
  self._partyScreen = screen
  self._slotCombatants = slotCombatants(roster)
  self._fragments = fragments
  return true
end

---@param intent table<string, unknown> battle bag intent under opening
---@return boolean opened
---@return string? failure cause
local function openBag(self, intent)
  local inventory = intent.inventory --[[@as table<string, integer>]]
  local stocked = false
  for key, quantity in pairs(inventory) do
    if type(quantity) == "number" and quantity >= 1 then
      stocked = true
      if self._itemCatalog == nil then
        return false, "the stocked bag needs its item catalog"
      end
      local ok, record = pcall(catalogItem, self._itemCatalog, key)
      if not ok then
        return false, "the stocked bag names an unknown item"
      end
      if type(record) == "table" and record.tmhmMoveNativeId ~= nil and self._monCatalog == nil then
        return false, "machine display needs its mon catalog"
      end
    end
  end
  if stocked and self._itemCatalog == nil then
    return false, "the stocked bag needs its item catalog"
  end
  if not stocked then
    self:_capture(intent)
    self._bagState = nil
    self._bagEmpty = true
    return true
  end
  local options = intent.options --[[@as table<string, unknown>]]
  local frozen = options
  local function policyEnabled(itemKey)
    local legal = itemLegality(frozen, itemKey)
    return legal
  end
  local function policyReason(itemKey)
    local _, reason = itemLegality(frozen, itemKey)
    return reason
  end
  local policy = { isEnabled = policyEnabled, reason = policyReason }
  local catalog = assert(self._itemCatalog, "stocked bags resolve their catalog")
  local snapshot = {}
  for key, quantity in pairs(inventory) do
    if type(quantity) == "number" and quantity >= 1 then
      snapshot[key] = quantity
    end
  end
  local service = battleBagService(snapshot, 1, catalog)
  local cursor = BagCursor.new()
  local monCatalog = self._monCatalog or stubMonCatalog()
  local measure = self._measureDisplay or staticMeasureDisplay
  self:_capture(intent)
  local built, screen = pcall(BagScreenState.new, {
    service = service,
    cursor = cursor,
    manifest = battleBagManifest(),
    uiManifest = battleUiManifest(),
    monCatalog = monCatalog,
    heroGender = "male",
    context = "battle",
    battlePolicy = policy,
    measureDisplay = measure,
    textPolicy = { interGlyphDelay = 0, glyphBudget = 64, abAcceleration = false },
    overrides = headlessCases({}),
  })
  if not built then
    local reason = tostring(screen)
    self:closeChild()
    return false, "the battle bag failed to open: " .. reason
  end
  local settled, settleErr = pcall(settleScreen, screen, "bag")
  if not settled then
    screen:dispose()
    self:closeChild()
    return false, "the battle bag failed to open: " .. tostring(settleErr)
  end
  self._bagState = screen
  return true
end

---@param options table<string, unknown> decision options under learning lookup
---@param id string projected learning choice identity under lookup
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

---@param intent table<string, unknown> learning intent under opening
---@return boolean opened
---@return string? failure cause
local function openLearn(self, intent)
  local request = intent.request --[[@as table<string, unknown>]]
  local options = intent.options --[[@as table<string, unknown>]]
  local actors = request.actors --[[@as table<integer, table<string, unknown>>?]]
  if type(actors) ~= "table" or type(actors[1]) ~= "table" or type(actors[1].combatant) ~= "number" then
    return false, "learning prompts address their recipient"
  end
  if actors[1].activation ~= nil then
    return false, "learning answers carry no entry token"
  end
  local moves = request.currentMoves --[[@as table<integer, table<string, unknown>>?]]
  if type(moves) ~= "table" or #moves ~= 4 then
    return false, "learning prompts carry their held move set"
  end
  if type(request.incomingMove) ~= "string" or request.incomingMove == "" then
    return false, "learning prompts name their incoming move"
  end
  local fragments = {}
  for slot = 0, 3 do
    local fragment = learnFragment(options, "learn:replace:" .. tostring(slot))
    if fragment == nil then
      return false, "the held slot stays replaceable"
    end
    fragments[slot] = fragment
  end
  local decline = learnFragment(options, "learn:decline")
  if decline == nil then
    return false, "the prompt stays declinable"
  end
  self:_capture(intent)
  self._learn = {
    recipient = actors[1].combatant,
    incomingMove = request.incomingMove,
    currentMoves = copyValue(moves),
    replace = fragments,
    decline = decline,
    focus = 1,
    confirmation = nil,
  }
  return true
end

---@class BattleSubflows.Intent
---@field kind "party"|"bag"|"learn" child kind under opening
---@field purpose string selection purpose under opening
---@field launchId string owning launch identity under opening
---@field requestId integer open request identity under opening
---@field epoch integer open request epoch under opening
---@field controller string open request controller under opening
---@field cancellable boolean? cancel permission under opening
---@field request table<string, unknown> mirrored open request under opening
---@field options table<string, unknown> decision options under opening
---@field party table<integer, table<string, unknown>> detached own-party snapshot under opening
---@field inventory table<string, integer> detached battle stock under opening

---@param intent BattleSubflows.Intent child intent under opening
---@return boolean opened
---@return string? failure cause
function BattleSubflows:open(intent)
  if self._disposed then
    return false, "the children are disposed"
  end
  local ok, checkErr = pcall(checkIntent, intent)
  if not ok then
    return false, tostring(checkErr)
  end
  if intent.launchId ~= self._launchId then
    return false, "children answer their own launch"
  end
  if intent.kind == "party" then
    return openParty(self, intent)
  elseif intent.kind == "bag" then
    return openBag(self, intent)
  end
  return openLearn(self, intent)
end

-- Cancels target selection back to the retained bag screen without
-- sealing or moving stock. The retained browser keeps its pocket,
-- focus, and counts.
local function cancelTarget(self)
  self._bagState = assert(self._retained, "target cancel reactivates its bag")
  self._retained = nil
  if self._partyScreen ~= nil then
    self._partyScreen:dispose()
    self._partyScreen = nil
  end
  self._active = "bag"
  self._stagedItem = nil
  self._slotCombatants = nil
  self._fragments = nil
  self._notice = nil
end

-- Polls the owned party screen after input: a selection maps its slot
-- back to the projected fragment, while a cancellation either reports
-- its bound cancellation or reactivates the retained bag behind target
-- selection. The screen owns focus and cancel permission; battle keeps
-- owning request binding and result mapping.
local function pollParty(self)
  local screen = assert(self._partyScreen, "party selection polls its screen")
  local result = screen:takeResult()
  if result == nil then
    return
  end
  if result.kind == "selected" then
    local slot = assert(result.slot, "party selections name their slot")
    local combatants = assert(self._slotCombatants, "party selections address their roster")
    local combatant = assert(combatants[slot], "party selections address a roster slot")
    local fragments = assert(self._fragments, "selections map through their fragments")
    local fragment = assert(fragments[combatant], "selections project their fragment")
    self._pending = { kind = "choice", reply = self:_bind(fragment) }
    return
  end
  assert(result.kind == "cancelled", "party screens select or cancel")
  if self._active == "target" then
    cancelTarget(self)
    return
  end
  self._pending = {
    kind = "cancelled",
    requestId = self._requestId,
    epoch = self._epoch,
    controller = self._controller,
    launchId = self._launchId,
  }
end

-- Polls the battle bag screen after input: staged selections map to
-- their native fragment (capture throws directly, servings open target
-- selection), while bag close reports its bound cancellation.
local function pollBag(self)
  local stated = assert(self._bagState, "the bag polls its screen")
  local intent = stated:takeIntent()
  if intent ~= nil then
    assert(intent.kind == "battle_select", "battle selections ride their own intent")
    self:stageItem(assert(intent.item, "battle selections snapshot their item"))
    return
  end
  local result = stated:takeResult()
  if result ~= nil then
    assert(result.kind == "close", "the battle bag only ever closes back")
    self._pending = {
      kind = "cancelled",
      requestId = self._requestId,
      epoch = self._epoch,
      controller = self._controller,
      launchId = self._launchId,
    }
    return
  end
  local view = stated:status()
  if type(view) == "table" and type(view.lowerMessage) == "table" then
    local fullText = view.lowerMessage.fullText
    if type(fullText) == "string" and fullText ~= "" then
      self._notice = fullText
    end
  end
end

---@param allowed table<string, boolean> accepted input edges under routing
---@param event table<string, unknown> semantic input under routing
---@return boolean routed true for lane-owned edges
local function laneEvent(allowed, event)
  return type(event) == "table" and allowed[event.type] == true
end

local BAG_EVENTS = { navigate = true, confirm = true, cancel = true, pointer_cancel = true }
local LIST_EVENTS = { navigate = true, confirm = true, cancel = true }

-- Stages one battle item: capture throws directly at the opposing
-- holder through its native fragment, while servings retain the bag
-- screen and open admitted-target selection on a second party screen.
-- Refused staging explains itself.
---@param itemKey string staged battle item identity under routing
function BattleSubflows:stageItem(itemKey)
  local intentOptions = self:_openOptions()
  local roster = self:_openParty()
  local own = {}
  for _, record in ipairs(roster) do
    if type(record) == "table" and type(record.combatant) == "number" then
      own[record.combatant] = true
    end
  end
  local targets = enabledItemTargets(intentOptions, itemKey)
  local foeFragment = nil
  local ownFragments = {}
  for combatant, fragment in pairs(targets) do
    if own[combatant] then
      ownFragments[combatant] = fragment
    elseif foeFragment == nil then
      foeFragment = fragment
    end
  end
  local catalog = self._itemCatalog
  local isBall = false
  if catalog ~= nil then
    local ok, record = pcall(catalogItem, catalog, itemKey)
    if ok and type(record) == "table" and record.isBall == true then
      isBall = true
    end
  end
  if isBall then
    if foeFragment == nil then
      self._notice = refusalText(nil)
      return
    end
    self._pending = { kind = "choice", reply = self:_bind(foeFragment) }
    return
  end
  local eligible = {}
  for combatant in pairs(ownFragments) do
    eligible[combatant] = true
  end
  if next(ownFragments) == nil then
    self._notice = refusalText(nil)
    return
  end
  local screen, screenErr = openPartyScreen(self, roster, eligible, true)
  assert(screen ~= nil, tostring(screenErr or "target selection opens its screen"))
  self._retained = assert(self._bagState, "target selection retains its bag")
  self._bagState = nil
  self._active = "target"
  self._stagedItem = itemKey
  self._partyScreen = screen
  self._slotCombatants = slotCombatants(roster)
  self._fragments = ownFragments
end

---@return table<string, unknown> decision options behind the active child
function BattleSubflows:_openOptions()
  return self._openOptionsValue
end

---@return table<integer, table<string, unknown>> party snapshot behind the active child
function BattleSubflows:_openParty()
  return self._openPartyValue
end

---@param direction string navigation direction under learning focus
local function moveLearnFocus(self, direction)
  local learn = assert(self._learn, "learning moves its own focus")
  local focus = learn.focus --[[@as integer]]
  if direction == "down" then
    focus = math.min(focus + 1, 5)
  elseif direction == "up" then
    focus = math.max(focus - 1, 1)
  else
    return
  end
  learn.focus = focus
end

-- Confirms the focused learning row: a move stages its replace
-- confirmation, the decline row stages its decline confirmation, and
-- confirming a staged confirmation seals its projected fragment. No path
-- declines without an explicit confirmation.
local function confirmLearn(self)
  local learn = assert(self._learn, "learning confirms its own rows")
  if learn.confirmation == nil then
    local focus = learn.focus --[[@as integer]]
    if focus <= 4 then
      learn.confirmation = { kind = "replace", slot = focus - 1 }
    else
      learn.confirmation = { kind = "decline" }
    end
    return
  end
  local confirmation = learn.confirmation --[[@as table<string, unknown>]]
  if confirmation.kind == "replace" then
    local fragments = learn.replace --[[@as table<integer, table<string, unknown>>]]
    local fragment = assert(fragments[confirmation.slot], "confirmed slots project their fragment")
    self._pending = { kind = "choice", reply = self:_bind(fragment) }
  else
    local decline = assert(learn.decline, "declines project their fragment")
    self._pending = { kind = "choice", reply = self:_bind(decline) }
  end
end

-- Cancels learning without ever auto-declining: backing out of the list
-- opens the explicit stop confirmation, rejecting any confirmation
-- returns to the list with its focus kept.
local function cancelLearn(self)
  local learn = assert(self._learn, "learning cancels its own rows")
  if learn.confirmation == nil then
    learn.confirmation = { kind = "stop" }
    return
  end
  learn.confirmation = nil
end

-- Confirms the stop-learning prompt: only this explicit confirmation
-- declines the prompt without replacing a move.
local function confirmStopLearn(self)
  local learn = assert(self._learn, "stop confirmations decline their prompt")
  local decline = assert(learn.decline, "declines project their fragment")
  self._pending = { kind = "choice", reply = self:_bind(decline) }
end

---@param event table<string, unknown> semantic input under learning routing
local function updateLearn(self, event)
  local learn = assert(self._learn, "learning owns its input lane")
  if event.type == "navigate" then
    if learn.confirmation == nil then
      moveLearnFocus(self, event.direction --[[@as string]])
    end
  elseif event.type == "confirm" then
    if learn.confirmation == nil then
      confirmLearn(self)
    elseif learn.confirmation.kind == "stop" then
      confirmStopLearn(self)
    else
      confirmLearn(self)
    end
  elseif event.type == "cancel" then
    cancelLearn(self)
  elseif event.type == "pointer_cancel" then
    self:cancelPointerCapture()
  end
end

---@param events table<integer, table<string, unknown>> semantic input batch under routing
function BattleSubflows:update(events)
  if self._disposed or self._active == nil or self._pending ~= nil then
    return
  end
  assert(type(events) == "table", "child input arrives as an event list")
  for _, event in ipairs(events) do
    if self._pending ~= nil then
      break
    end
    if type(event) ~= "table" or type(event.type) ~= "string" then
      break
    end
    if self._active == "party" or self._active == "target" then
      if not laneEvent(LIST_EVENTS, event) then
        break
      end
      local screen = assert(self._partyScreen, "the party owns its input lane")
      screen:updateFixed({ event })
      pollParty(self)
    elseif self._active == "bag" then
      if not laneEvent(BAG_EVENTS, event) then
        break
      end
      if event.type == "pointer_cancel" then
        self:cancelPointerCapture()
      elseif self._bagEmpty then
        if event.type == "cancel" then
          self._pending = {
            kind = "cancelled",
            requestId = self._requestId,
            epoch = self._epoch,
            controller = self._controller,
            launchId = self._launchId,
          }
        end
      else
        local stated = assert(self._bagState, "the bag owns its input lane")
        stated:updateFixed({ event })
        pollBag(self)
      end
    elseif self._active == "learn" then
      if not laneEvent(LIST_EVENTS, event) then
        break
      end
      updateLearn(self, event)
    end
  end
end

-- Steps the active child clock without input: the bag screen advances
-- its reveal pacing while party and learning selections hold steady.
-- The retained bag screen stays inert and reads no input.
function BattleSubflows:tick()
  if self._disposed or self._active ~= "bag" or self._pending ~= nil or self._bagEmpty then
    return
  end
  local stated = assert(self._bagState, "the bag owns its clock")
  stated:updateFixed({})
  pollBag(self)
end

---@param entry unknown held move entry under labeling
---@return string visible move wording
local function learnMoveLabel(entry)
  if type(entry) == "table" then
    for _, key in ipairs({ "move", "name", "key" }) do
      local wording = entry[key]
      if type(wording) == "string" and wording ~= "" then
        return wording
      end
    end
  elseif type(entry) == "string" and entry ~= "" then
    return entry
  end
  return "Unknown"
end

-- Detached party/target rows for paint and hit regions: every roster
-- slot lists with its display name, level, health, and eligibility.
-- Only kernel-projected fragments enable a row; anything else names
-- its refusal without submitting. No presentation plan or mutable
-- service crosses this boundary.
---@param self BattleSubflows
---@return table<string, unknown> detached party/target child view
local function partyChildView(self)
  local shell = {
    kind = self._active,
    purpose = self._purpose,
    interactive = false,
    notice = self._notice,
    cancellable = self._cancellable,
    rows = {},
    focusId = nil,
  } --[[@as table<string, unknown>]]
  local screen = self._partyScreen
  if screen == nil then
    return shell
  end
  local ok, stated = pcall(screen.status, screen)
  if not ok or type(stated) ~= "table" then
    return shell
  end
  local view = stated.view --[[@as table<string, unknown>?]]
  if type(view) ~= "table" or type(view.slots) ~= "table" then
    return shell
  end
  local rows = {}
  for slot = 0, 5 do
    local record = view.slots[slot + 1]
    local label = "Empty"
    local sub = nil
    local detail = ""
    local enabled = false
    local reason = nil
    if type(record) == "table" and record.occupied == true then
      local name = record.displayName
      label = tostring(type(name) == "string" and name or "Unknown")
      if type(record.level) == "number" then
        sub = "Lv" .. tostring(record.level)
      end
      local hp = tonumber(record.currentHp) or 0
      local maxHp = tonumber(record.maxHp) or 0
      detail = "HP " .. tostring(hp) .. "/" .. tostring(maxHp)
      local combatants = self._slotCombatants
      local fragments = self._fragments
      local combatant = type(combatants) == "table" and combatants[slot] or nil
      if type(fragments) == "table" and combatant ~= nil and fragments[combatant] ~= nil then
        enabled = true
        detail = detail .. " OK"
      elseif hp <= 0 then
        reason = "It is fainted."
        detail = detail .. " KO"
      else
        reason = refusalText(nil)
      end
    end
    rows[#rows + 1] = {
      id = "party:" .. tostring(slot),
      label = label,
      sub = sub,
      detail = detail,
      enabled = enabled,
      reason = reason,
      occupied = type(record) == "table" and record.occupied == true,
    }
  end
  local focusId = nil
  if type(stated.cursorNode) == "number" then
    focusId = "party:" .. tostring(stated.cursorNode)
  elseif stated.cursorNode == "cancel" then
    focusId = "back"
  end
  shell.rows = rows
  shell.focusId = focusId
  shell.interactive = stated.phase == "interactive"
  return shell
end

-- Detached bag rows for paint and hit regions: the six visible pocket
-- cells with their catalog names, quantities, and kernel legality,
-- plus pocket identity and page facts. Empty cells stay visible but
-- never activate. No presentation plan or mutable service crosses.
---@param self BattleSubflows
---@return table<string, unknown> detached bag child view
local function bagChildView(self)
  if self._bagEmpty == true then
    return {
      kind = "bag",
      purpose = self._purpose,
      interactive = true,
      notice = self._notice or "The bag is empty.",
      cancellable = self._cancellable,
      rows = {},
      focusId = "back",
      pockets = {},
      currentPocket = nil,
      page = { current = 1, count = 1 },
      empty = true,
    } --[[@as table<string, unknown>]]
  end
  local shell = {
    kind = "bag",
    purpose = self._purpose,
    interactive = false,
    notice = self._notice,
    cancellable = self._cancellable,
    rows = {},
    focusId = nil,
  } --[[@as table<string, unknown>]]
  local stated = self._bagState
  if stated == nil then
    return shell
  end
  local ok, status = pcall(stated.status, stated)
  if not ok or type(status) ~= "table" or status.open == false then
    return shell
  end
  local visible = status.visibleSlots
  if type(visible) ~= "table" then
    return shell
  end
  local options = self._openOptionsValue
  if type(options) ~= "table" then
    return shell
  end
  local rows = {}
  for cell = 1, 6 do
    local entry = visible[cell]
    if type(entry) == "table" and entry.empty ~= true and type(entry.item) == "string" then
      local legal, reason = itemLegality(options, entry.item)
      rows[#rows + 1] = {
        id = "bag:" .. tostring(cell - 1),
        label = tostring(entry.name or entry.item),
        sub = "x" .. tostring(entry.quantity or 0),
        detail = legal == true and "OK" or refusalText(reason),
        enabled = legal == true,
        reason = legal == true and nil or refusalText(reason),
      }
    else
      rows[#rows + 1] = {
        id = "bag:" .. tostring(cell - 1),
        label = "Empty",
        detail = "",
        enabled = false,
        empty = true,
      }
    end
  end
  local focusId = nil
  if status.focus == "items" and type(status.focusedVisibleIndex) == "number" then
    focusId = "bag:" .. tostring(status.focusedVisibleIndex)
  elseif status.focus == "cancel" then
    focusId = "back"
  end
  local pockets = {}
  if type(status.pockets) == "table" then
    for _, tab in ipairs(status.pockets) do
      if type(tab) == "table" and type(tab.pocket) == "string" then
        pockets[#pockets + 1] = tab.pocket
      end
    end
  end
  shell.rows = rows
  shell.focusId = focusId
  shell.interactive = status.phase == "interactive"
  shell.pockets = pockets
  shell.currentPocket = status.pocket
  shell.page = copyValue(status.page) or { current = 1, count = 1 }
  if type(status.slots) == "table" then
    shell.stock = #status.slots
  else
    shell.stock = 0
  end
  return shell
end

-- Detached learning rows for paint and hit regions: the four held
-- moves, the decline entry, the focused row, and the staged
-- confirmation. Rows never seal on their own; taps route through the
-- same focus/confirm helpers as keyboard input.
---@param self BattleSubflows
---@return table<string, unknown>? detached learning child view, nil without its prompt
local function learnChildView(self)
  local learn = self._learn
  if learn == nil then
    return nil
  end
  local moves = learn.currentMoves --[[@as table<integer, unknown>]]
  local rows = {}
  for index = 1, 4 do
    rows[#rows + 1] = {
      id = "learn:" .. tostring(index - 1),
      label = learnMoveLabel(moves[index]),
      detail = "Replace",
      enabled = true,
    }
  end
  rows[#rows + 1] = { id = "learn:decline", label = "Decline", detail = "Keep moves", enabled = true }
  local focus = learn.focus --[[@as integer]]
  return {
    kind = "learn",
    purpose = self._purpose,
    interactive = true,
    notice = self._notice,
    cancellable = false,
    rows = rows,
    focusId = focus <= 4 and ("learn:" .. tostring(focus - 1)) or "learn:decline",
    confirmation = copyValue(learn.confirmation),
    incomingMove = learn.incomingMove,
  } --[[@as table<string, unknown>]]
end

---@return table<string, unknown> detached child status for the parent plan
function BattleSubflows:status()
  if self._disposed or self._active == nil then
    return { active = false }
  end
  local record = {
    active = true,
    kind = self._active,
    purpose = self._purpose,
    cancellable = self._cancellable,
    notice = self._notice,
    requestId = self._requestId,
    epoch = self._epoch,
    controller = self._controller,
    launchId = self._launchId,
  } --[[@as table<string, unknown>]]
  if self._stagedItem ~= nil then
    record.stagedItem = self._stagedItem
  end
  if self._learn ~= nil then
    local learn = self._learn --[[@as table<string, unknown>]]
    record.focus = learn.focus
    record.confirmation = copyValue(learn.confirmation)
    record.incomingMove = learn.incomingMove
    record.currentMoves = copyValue(learn.currentMoves)
  end
  record.childView = self:_projectChildView()
  return record
end

-- Projects the detached child view for paint and hit regions from the
-- current native child controller state. Party/target rows read the
-- owned party screen slots, cursor, and projected fragments; bag rows
-- read the owned bag screen pocket window and kernel item policy;
-- learning rows read the staged prompt. Read-only snapshots only.
---@return table<string, unknown>? detached child view, nil while no child owns input
function BattleSubflows:_projectChildView()
  if self._disposed or self._active == nil then
    return nil
  end
  if self._active == "party" or self._active == "target" then
    return partyChildView(self)
  elseif self._active == "bag" then
    return bagChildView(self)
  elseif self._active == "learn" then
    return learnChildView(self)
  end
  return nil
end

---@return boolean interactive true once the party screen publishes its interactive phase
function BattleSubflows:_partyInteractive()
  local screen = self._partyScreen
  if screen == nil then
    return false
  end
  local ok, stated = pcall(screen.status, screen)
  return ok and type(stated) == "table" and stated.phase == "interactive"
end

---@return boolean interactive true once the bag screen publishes its interactive phase
function BattleSubflows:_bagInteractive()
  local stated = self._bagState
  if stated == nil then
    return false
  end
  local ok, status = pcall(stated.status, stated)
  return ok and type(status) == "table" and status.open ~= false and status.phase == "interactive"
end

-- Steps pocket focus through the owned bag screen's own navigation:
-- up to the tab strip, one step sideways across tabs (which switch
-- pockets at once in battle context), then down to the grid. Bounded;
-- the borrowed cursor is never touched directly.
---@param direction string lateral tab travel under stepping: "left" or "right"
local function stepPocket(self, direction)
  local stated = assert(self._bagState, "pocket travel keeps its bag")
  for _ = 1, 12 do
    local status = stated:status()
    if type(status) ~= "table" or status.open == false or status.focus == "tabs" then
      break
    end
    stated:updateFixed({ { type = "navigate", direction = "up" } })
  end
  stated:updateFixed({ { type = "navigate", direction = direction } })
  local status = stated:status()
  if type(status) == "table" and status.open ~= false and status.focus == "tabs" then
    stated:updateFixed({ { type = "navigate", direction = "down" } })
  end
end

---@param id string stable row/control identity under activation
---@return boolean consumed true when the tap belonged to the open child
function BattleSubflows:_activatePartyControl(id)
  if id == "back" then
    if not self._cancellable then
      self._notice = "That choice cannot be cancelled."
      return true
    end
    if not self:_partyInteractive() then
      return true
    end
    self:update({ { type = "cancel" } })
    return true
  end
  local slot = tonumber(id:match("^party:(%d+)$") or "")
  if slot == nil or slot < 0 or slot > 5 then
    return false
  end
  if not self:_partyInteractive() then
    return true
  end
  local combatants = self._slotCombatants
  local fragments = self._fragments
  local combatant = type(combatants) == "table" and combatants[slot] or nil
  local fragment = type(fragments) == "table" and combatant ~= nil and fragments[combatant] or nil
  if fragment ~= nil then
    self._pending = { kind = "choice", reply = self:_bind(fragment) }
    return true
  end
  -- A visibly disabled row explains itself without submitting.
  local hp = nil
  if type(self._openPartyValue) == "table" then
    for _, record in ipairs(self._openPartyValue) do
      if type(record) == "table" and record.slot == slot and type(record.hp) == "number" then
        hp = record.hp
      end
    end
  end
  if hp ~= nil and hp <= 0 then
    self._notice = "It is fainted."
  else
    self._notice = refusalText(nil)
  end
  return true
end

---@param id string stable row/control identity under activation
---@return boolean consumed true when the tap belonged to the open child
function BattleSubflows:_activateBagControl(id)
  if id == "back" then
    if not self._cancellable then
      self._notice = "That choice cannot be cancelled."
      return true
    end
    if self._bagEmpty == true then
      self._pending = {
        kind = "cancelled",
        requestId = self._requestId,
        epoch = self._epoch,
        controller = self._controller,
        launchId = self._launchId,
      }
      return true
    end
    if not self:_bagInteractive() then
      return true
    end
    self:update({ { type = "cancel" } })
    return true
  end
  if self._bagEmpty == true then
    return false
  end
  if id == "pocket_prev" then
    if not self:_bagInteractive() then
      return true
    end
    stepPocket(self, "left")
    return true
  end
  if id == "pocket_next" then
    if not self:_bagInteractive() then
      return true
    end
    stepPocket(self, "right")
    return true
  end
  local cell = tonumber(id:match("^bag:(%d+)$") or "")
  if cell == nil or cell < 0 or cell > 5 then
    return false
  end
  if not self:_bagInteractive() then
    return true
  end
  local stated = assert(self._bagState, "item taps keep their bag")
  local status = stated:status()
  local visible = type(status) == "table" and status.visibleSlots or nil
  local entry = type(visible) == "table" and visible[cell + 1] or nil
  if type(entry) ~= "table" or entry.empty == true or type(entry.item) ~= "string" then
    return true
  end
  local options = self._openOptionsValue
  if type(options) ~= "table" then
    return true
  end
  local legal, reason = itemLegality(options, entry.item)
  if legal == true then
    self:stageItem(entry.item)
  else
    self._notice = refusalText(reason)
  end
  return true
end

---@param id string stable row/control identity under activation
---@return boolean consumed true when the tap belonged to the open child
function BattleSubflows:_activateLearnControl(id)
  local learn = self._learn
  if learn == nil then
    return false
  end
  if id == "back" then
    cancelLearn(self)
    return true
  end
  if id == "confirm" then
    local confirmation = learn.confirmation --[[@as table<string, unknown>?]]
    if confirmation == nil then
      return true
    end
    if confirmation.kind == "stop" then
      confirmStopLearn(self)
    else
      confirmLearn(self)
    end
    return true
  end
  local tapped = nil
  local slot = tonumber(id:match("^learn:(%d+)$") or "")
  if slot ~= nil and slot >= 0 and slot <= 3 then
    tapped = slot
    learn.focus = slot + 1
  elseif id == "learn:decline" then
    tapped = "decline"
    learn.focus = 5
  else
    return false
  end
  -- Taps stage their explicit confirmation without ever sealing on
  -- their own: only the shared confirmation helper seals, exactly
  -- like the keyboard flow. Tapping another row restages instead,
  -- and tapping away from the stop prompt abandons it.
  if tapped == "decline" then
    learn.confirmation = { kind = "decline" }
  else
    learn.confirmation = { kind = "replace", slot = tapped }
  end
  return true
end

-- Routes one tap to the current bound fragments through the existing
-- bind/stage/learn helpers, never a second policy. Party and target
-- rows bind their already projected switch/item fragment, bag item
-- rows stage through the existing item path only while visible and
-- legal, and learn rows share the keyboard focus/confirm helpers. A
-- tap on a visibly disabled row shows its reason without submitting;
-- unknown ids never seal. Premature taps before the child publishes
-- its interactive phase are consumed and dropped, never replayed.
---@param id string stable row/control identity under activation
---@return boolean consumed true when the tap belonged to the open child
function BattleSubflows:activateControl(id)
  if self._disposed or self._active == nil or self._pending ~= nil then
    return false
  end
  assert(type(id) == "string" and id ~= "", "child taps name their control")
  if self._active == "party" or self._active == "target" then
    return self:_activatePartyControl(id)
  elseif self._active == "bag" then
    return self:_activateBagControl(id)
  elseif self._active == "learn" then
    return self:_activateLearnControl(id)
  end
  return false
end

---@return table<string, unknown>? staged bound result, exactly once
function BattleSubflows:takeResult()
  if self._disposed or self._active == nil then
    return nil
  end
  local result = self._pending
  self._pending = nil
  if result ~= nil then
    self._notice = nil
  end
  return result
end

-- Closes the active child and any retained bag screen in reverse
-- ownership order: the target selection screen first, then its retained
-- browser. Staged state clears without sealing.
function BattleSubflows:closeChild()
  if self._partyScreen ~= nil then
    self._partyScreen:dispose()
    self._partyScreen = nil
  end
  self._slotCombatants = nil
  self._fragments = nil
  self._stagedItem = nil
  if self._bagState ~= nil then
    self._bagState:dispose()
    self._bagState = nil
  end
  if self._retained ~= nil then
    self._retained:dispose()
    self._retained = nil
  end
  if self._learn ~= nil then
    self._learn = nil
  end
  self._active = nil
  self._purpose = nil
  self._pending = nil
  self._notice = nil
  self._openOptionsValue = nil
  self._openPartyValue = nil
  self._bagEmpty = nil
end

-- Cancels a held press through the active owner so a stale release never
-- activates after remeasure. Stored request identity and selections stay.
function BattleSubflows:cancelPointerCapture()
  if self._disposed then
    return
  end
  if self._partyScreen ~= nil then
    self._partyScreen:cancelPointerCapture()
  end
  if self._bagState ~= nil then
    self._bagState:cancelPointerCapture()
  end
  if self._retained ~= nil then
    self._retained:cancelPointerCapture()
  end
end

-- Idempotent release of the child lifetime: owned screens release
-- exactly once, staged results clear, and borrowed catalogs stay usable.
function BattleSubflows:dispose()
  if self._disposed then
    return
  end
  self._disposed = true
  self:closeChild()
end

return BattleSubflows
