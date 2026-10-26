-- Battle-local child selection over detached battle data. Voluntary
-- switch, forced replacement, bag browsing, item-target picking, and
-- move learning run on one native child controller at a time over the
-- detached snapshots the parent intent carries: the native Party, Bag,
-- and Summary controllers own focus, animation, and terminal results
-- while this barrier retains only request identity, the staged item or
-- learning confirmation, and the open intent behind recomposition.
-- Semantic edges buffer until the accepted source tick, one native
-- controller tick runs per tick, and every success copies a
-- kernel-projected choice fragment bound to the opening launch and
-- request while every permitted Back reports a bound cancellation. Stale
-- or foreign input never seals. No field screen is constructed and no
-- live party, bag, or save owner is touched; the kernel executes and the
-- committer publishes.

local BattleChildApplications = require("game.hgss.src.battle.BattleChildApplications")

---@class BattleSubflows
---@field _launchId string owning launch identity
---@field _itemCatalog table<string, unknown>? borrowed immutable item catalog for pocket grouping
---@field _monCatalog table<string, unknown>? borrowed immutable mon catalog for machine display facts
---@field _battleMenus table<string, unknown>? borrowed native battle menu renderer and manifest services
---@field _active string? live child kind: party, bag, target, move, learn, or naming
---@field _purpose string? selection purpose behind the active child
---@field _cancellable boolean cancel permission behind the active child
---@field _requestId integer open request identity behind the active child
---@field _epoch integer open request epoch behind the active child
---@field _controller string open request controller behind the active child
---@field _pending table<string, unknown>? staged bound result awaiting collection
---@field _notice string? refusal explanation behind the active child
---@field _openOptionsValue table<string, unknown>? decision options behind the active child
---@field _openPartyValue table<integer, table<string, unknown>>? party snapshot behind the active child
---@field _stagedItem string? staged battle item behind target selection
---@field _stagedHolder integer? chosen holder behind Restore PP move selection
---@field _learnConfirm table<string, unknown>? staged learning confirmation behind its explicit confirm
---@field _composed table<string, unknown>? concrete battle child application behind the active child
---@field _queued table<integer, table<string, unknown>> buffered semantic edges behind the next source tick
---@field _intent table<string, unknown>? validated open intent behind recomposition
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

---@param reason string? supplied refusal reason under display
---@return string visible refusal text
local function refusalText(reason)
  if type(reason) == "string" and reason ~= "" then
    if reason == "no_effect" or reason == "invalid_target" then
      return "It won’t do any good to use that!"
    end
    return reason
  end
  return "That choice is unavailable."
end

---@class BattleSubflows.Options
---@field launchId string owning launch identity
---@field itemCatalog table<string, unknown>? borrowed immutable item catalog for pocket grouping
---@field monCatalog table<string, unknown>? borrowed immutable mon catalog for machine display facts
---@field battleMenus table<string, unknown>? borrowed native battle menu renderer and manifest services

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
  if opts.battleMenus ~= nil then
    assert(type(opts.battleMenus) == "table", "native battle menus arrive as a record")
  end
  return setmetatable({
    _launchId = opts.launchId,
    _itemCatalog = opts.itemCatalog,
    _monCatalog = opts.monCatalog,
    _battleMenus = opts.battleMenus,
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
    _stagedItem = nil,
    _stagedHolder = nil,
    _learnConfirm = nil,
    _composed = nil,
    _queued = {},
    _intent = nil,
    _disposed = false,
  }, BattleSubflows)
end

---@param intent table<string, unknown> child intent under validation
local function checkIntent(intent)
  assert(type(intent) == "table", "child intents arrive as records")
  assert(
    intent.kind == "party" or intent.kind == "bag" or intent.kind == "learn" or intent.kind == "naming",
    "child intents name party, bag, learn, or naming"
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
---@param key string staged item identity under projection
---@param combatant integer chosen holder under projection
---@return table<integer, table<string, unknown>> enabled one-move PP fragments by zero-based move slot
local function enabledItemMoves(options, key, combatant)
  local found = {}
  for _, actor in ipairs(options.actors or {}) do
    for _, choice in ipairs(type(actor) == "table" and actor.choices or {}) do
      local fragment = type(choice) == "table" and choice.choice or nil
      local payload = type(fragment) == "table" and fragment.payload or nil
      if
        type(fragment) == "table"
        and choice.enabled == true
        and type(payload) == "table"
        and fragment.kind == "item"
        and payload.item == key
        and type(payload.target) == "table"
        and payload.target.combatant == combatant
        and type(payload.moveSlot) == "number"
      then
        found[payload.moveSlot] = fragment
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
-- open supersedes its predecessor without applying it. The validated
-- intent stays behind recomposition so a refused cancel can rebuild the
-- same native picker without inventing a request.
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
  self._intent = intent
  self._pending = nil
  self._notice = nil
  self._stagedItem = nil
  self._stagedHolder = nil
  self._learnConfirm = nil
  self._queued = {}
end

---@return table<string, unknown> decision options behind the active child
function BattleSubflows:_openOptions()
  return assert(self._openOptionsValue, "options travel with the active child")
end

---@return table<integer, table<string, unknown>> party snapshot behind the active child
function BattleSubflows:_openParty()
  return assert(self._openPartyValue, "the party snapshot travels with the active child")
end

-- Composes the concrete child application before the barrier captures:
-- a composition failure reports its boundary with prior state untouched.
-- The initiating input terminates at the barrier: the composed child
-- starts from its entry state, so opening consumes the edge that opened
-- it and the edge can never confirm an unintended choice.
---@param intent table<string, unknown> child intent under composition
---@return table<string, unknown>? composed child application
---@return string? failure cause
local function composeChild(self, intent)
  return BattleChildApplications.open(intent, {
    itemCatalog = self._itemCatalog,
    monCatalog = self._monCatalog,
    battleMenus = self._battleMenus,
  })
end

-- Rebuilds the same native picker after a refused cancel closed it: the
-- barrier disposes the sealed controller and composes a fresh one over
-- the stored open intent, so the child keeps owning input with its
-- request identity intact.
function BattleSubflows:_reopenComposed()
  local intent = assert(self._intent, "reopen keeps its open intent")
  local child, childErr = composeChild(self, intent)
  if child == nil then
    self._notice = tostring(childErr or "the child failed to reopen")
    return
  end
  if self._composed ~= nil then
    self._composed:dispose()
  end
  self._composed = child
end

---@param intent table<string, unknown> party selection intent under opening
---@return boolean opened
---@return string? failure cause
local function openParty(self, intent)
  local child, childErr = composeChild(self, intent)
  if child == nil then
    return false, childErr
  end
  self:_capture(intent)
  self._composed = child
  return true
end

---@param intent table<string, unknown> battle bag intent under opening
---@return boolean opened
---@return string? failure cause
local function openBag(self, intent)
  local child, childErr = composeChild(self, intent)
  if child == nil then
    return false, childErr
  end
  self:_capture(intent)
  self._composed = child
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
  for slot = 0, 3 do
    if learnFragment(options, "learn:replace:" .. tostring(slot)) == nil then
      return false, "the held slot stays replaceable"
    end
  end
  if learnFragment(options, "learn:decline") == nil then
    return false, "the prompt stays declinable"
  end
  local child, childErr = composeChild(self, intent)
  if child == nil then
    return false, childErr
  end
  self:_capture(intent)
  self._composed = child
  return true
end

---@param intent table<string, unknown> naming intent under opening
---@return boolean opened
---@return string? failure cause
local function openNaming(self, intent)
  local child, childErr = composeChild(self, intent)
  if child == nil then
    return false, childErr
  end
  self:_capture(intent)
  self._composed = child
  return true
end

---@class BattleSubflows.Intent
---@field kind "party"|"bag"|"learn"|"naming" child kind under opening
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
  -- Children select for their addressed entries: bag, learning, and
  -- naming answer exactly one addressed entry while party batches open
  -- per addressed actor without superseding. Every addressed entry stays
  -- authoritative here instead of unioning fragments across entries.
  local actors = intent.options.actors --[[@as table<integer, table<string, unknown>>?]]
  if type(actors) ~= "table" or #actors < 1 then
    return false, "children answer their addressed entries"
  end
  for _, actor in ipairs(actors) do
    if type(actor) ~= "table" then
      return false, "children answer their addressed entries"
    end
  end
  if intent.kind ~= "party" and #actors ~= 1 then
    return false, "children answer exactly one addressed entry"
  end
  if intent.kind == "party" then
    return openParty(self, intent)
  elseif intent.kind == "bag" then
    return openBag(self, intent)
  elseif intent.kind == "learn" then
    return openLearn(self, intent)
  end
  return openNaming(self, intent)
end

---@param allowed table<string, boolean> accepted input edges under routing
---@param event table<string, unknown> semantic input under routing
---@return boolean routed true for lane-owned edges
local function laneEvent(allowed, event)
  return type(event) == "table" and allowed[event.type] == true
end

local BAG_EVENTS = {
  navigate = true,
  confirm = true,
  cancel = true,
  pointer_cancel = true,
  pointer_down = true,
  pointer_up = true,
}
local LIST_EVENTS =
  { navigate = true, confirm = true, cancel = true, pointer_cancel = true, pointer_down = true, pointer_up = true }
local NAMING_EVENTS = {
  navigate = true,
  confirm = true,
  cancel = true,
  pointer_cancel = true,
  text = true,
  name_cell = true,
  name_control = true,
}

-- Stages one battle item from the native browser selection: capture
-- throws directly through its opposing-holder fragment, while servings
-- open admitted-target selection on the native item-target picker beside
-- the retained browser. Refused staging explains itself.
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
  local ownCount = 0
  for combatant, fragment in pairs(targets) do
    if own[combatant] then
      ownCount = ownCount + 1
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
  if ownCount == 0 then
    self._notice = refusalText(nil)
    return
  end
  self._stagedItem = itemKey
  self._active = "target"
  self._notice = nil
  -- The composed bag child opens the native item-target picker beside
  -- the retained browser. A target composition failure unwinds to the
  -- resting browser with its refusal instead of half-opening selection.
  local composed = assert(self._composed, "target selection keeps its composed child")
  local ok, targetErr = pcall(composed.openTarget, composed, itemKey)
  if not ok then
    self._active = "bag"
    self._stagedItem = nil
    self._notice = tostring(targetErr or "target selection stays unavailable")
  end
end

-- Stages one item-target choice from the native target picker outcome:
-- the tapped slot translates against the current options, so only a
-- kernel-projected serving for the addressed roster seals.
---@param slot integer native roster slot under staging
---@param itemKey string staged battle item identity under staging
function BattleSubflows:_stageTarget(slot, itemKey)
  local roster = self:_openParty()
  local combatant = nil
  for _, record in ipairs(roster) do
    if type(record) == "table" and record.slot == slot and type(record.combatant) == "number" then
      combatant = record.combatant
      break
    end
  end
  local fragment = nil
  if combatant ~= nil then
    fragment = enabledItemTargets(self:_openOptions(), itemKey)[combatant]
  end
  if fragment == nil then
    self._notice = "The selection expired."
    return
  end
  if fragment.payload.moveSlot ~= nil then
    -- One-move PP servings name their move on the native Restore PP page
    -- before anything seals.
    local composed = assert(self._composed, "move selection keeps its composed child")
    composed:openMove(slot)
    self._stagedHolder = combatant
    self._active = "move"
    return
  end
  self._pending = { kind = "choice", reply = self:_bind(fragment) }
end

-- Stages one Restore PP outcome: an effective move seals its projected
-- fragment, a move without effect explains itself over the target list,
-- and Back returns to that list.
---@param outcome table<string, unknown> drained native move outcome
function BattleSubflows:_stageMove(outcome)
  local composed = assert(self._composed, "move selection keeps its composed child")
  if outcome.kind == "move_selected" then
    local fragment = enabledItemMoves(
      self:_openOptions(),
      assert(self._stagedItem, "move selection keeps its staged item"),
      assert(self._stagedHolder, "move selection keeps its staged holder")
    )[outcome.moveSlot]
    if fragment ~= nil then
      self._pending = { kind = "choice", reply = self:_bind(fragment) }
      return
    end
    composed:closeMove("It won’t have any effect.")
  else
    composed:closeMove(nil)
  end
  self._stagedHolder = nil
  self._active = "target"
end

-- Queues one semantic input batch behind the next accepted source tick.
-- Nothing steps here: the single native controller tick runs in tick(),
-- so input and tick never advance the same controller twice.
---@param events table<integer, table<string, unknown>> semantic input batch under buffering
function BattleSubflows:update(events)
  if self._disposed or self._active == nil or self._pending ~= nil then
    return
  end
  assert(type(events) == "table", "child input arrives as an event list")
  local allowed = LIST_EVENTS
  if self._active == "bag" or self._active == "target" then
    allowed = BAG_EVENTS
  elseif self._active == "naming" then
    allowed = NAMING_EVENTS
  end
  for _, event in ipairs(events) do
    if type(event) ~= "table" or type(event.type) ~= "string" then
      break
    end
    if not laneEvent(allowed, event) then
      break
    end
    self._queued[#self._queued + 1] = event
  end
end

-- Runs the single native controller tick: flushes the buffered batch
-- through the one composed child, advances its presentation clock once,
-- then drains only its final native outcomes into staged barrier results.
-- A staged learning confirmation owns its barrier edges instead: the
-- native picker already sealed, so confirm seals the stored fragment and
-- cancel rebuilds the native list.
function BattleSubflows:tick()
  if self._disposed or self._active == nil then
    self._queued = {}
    return
  end
  if self._pending ~= nil then
    self._queued = {}
    return
  end
  local composed = assert(self._composed, "the active child keeps its composed child")
  if self._active == "naming" then
    if #self._queued > 0 then
      composed:input(self._queued)
    end
    self._queued = {}
    composed:stepSourceTick(1)
    return
  end
  if self._learnConfirm ~= nil then
    for _, event in ipairs(self._queued) do
      if self._pending ~= nil then
        break
      end
      if type(event) == "table" and event.type == "confirm" then
        local confirmation = self._learnConfirm --[[@as table<string, unknown>]]
        self._learnConfirm = nil
        self._pending = {
          kind = "choice",
          reply = self:_bind(assert(confirmation.fragment, "confirmations carry their fragment")),
        }
      elseif type(event) == "table" and event.type == "cancel" then
        -- Rejecting the confirmation returns to the native list with its
        -- focus restored. The rebuilt picker opens on its first row and
        -- the native picker resolves one action per tick, so the barrier
        -- walks it back to the staged row with one edge per step inside
        -- this same tick; no user edge is duplicated and later ticks
        -- resume the single-tick path.
        local confirmation = self._learnConfirm --[[@as table<string, unknown>]]
        local focus = tonumber(confirmation.focus) or 0
        self._learnConfirm = nil
        self:_reopenComposed()
        local fresh = self._composed
        if fresh ~= nil then
          local target = math.min(math.max(math.floor(focus), 0), 4)
          local stepped = 0
          while stepped < target do
            fresh:input({ { type = "navigate", direction = "down" } })
            stepped = stepped + 1
          end
        end
      end
    end
    self._queued = {}
    return
  end
  if #self._queued > 0 then
    composed:input(self._queued)
    self._queued = {}
  end
  composed:stepSourceTick(1)
  if self._active == "party" then
    local result = composed:takeResult()
    if result ~= nil then
      if result.kind == "choice" then
        self._pending = result
      elseif result.kind == "cancelled" then
        if self._cancellable then
          self._pending = result
        else
          self._notice = "That choice cannot be cancelled."
          self:_reopenComposed()
        end
      end
    end
  elseif self._active == "bag" then
    local intent = composed:takeBagIntent()
    if intent ~= nil then
      self:stageItem(intent.item --[[@as string]])
    end
    if self._pending == nil and self._active == "bag" then
      local close = composed:takeBagClose()
      if close ~= nil then
        if self._cancellable then
          self._pending = {
            kind = "cancelled",
            requestId = self._requestId,
            epoch = self._epoch,
            controller = self._controller,
            launchId = self._launchId,
          }
        else
          self._notice = "That choice cannot be cancelled."
        end
      end
    end
  elseif self._active == "target" then
    local outcome = composed:takeTargetOutcome()
    if outcome ~= nil then
      if outcome.kind == "use_item" then
        self:_stageTarget(outcome.slot --[[@as integer]], outcome.item --[[@as string]])
      elseif outcome.kind == "cancelled" then
        composed:closeTarget()
        self._active = "bag"
        self._stagedItem = nil
        self._notice = nil
      end
    end
  elseif self._active == "move" then
    local outcome = composed:takeMoveOutcome()
    if outcome ~= nil then
      self:_stageMove(outcome)
    end
  elseif self._active == "learn" then
    local outcome = composed:takeLearnOutcome()
    if outcome ~= nil then
      if outcome.kind == "move_selected" then
        local fragment = composed:translateSelection(outcome.moveSlot --[[@as integer]])
        if fragment ~= nil then
          self._learnConfirm = {
            kind = "replace",
            slot = outcome.moveSlot,
            focus = outcome.moveSlot,
            fragment = fragment,
          }
        else
          self._notice = "The selection expired."
        end
      elseif outcome.kind == "cancelled" then
        local decline = composed:translateSelection(4)
        if outcome.focus == 4 and decline ~= nil then
          self._learnConfirm = { kind = "decline", focus = 4, fragment = decline }
        else
          local stop = learnFragment(self:_openOptions(), "learn:decline")
          if stop ~= nil then
            self._learnConfirm = { kind = "stop", focus = outcome.focus, fragment = stop }
          else
            self._notice = "The selection expired."
          end
        end
      end
    end
  end
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

-- Projects the native party/target roster rows for paint and hit
-- regions: the native controller status carries slot occupancy, kernel
-- eligibility, and focus while the barrier only maps them onto the
-- existing modal rows. Only kernel-projected fragments enable a row;
-- anything else names its refusal without submitting.
---@param native table<string, unknown> native party status record under projection
---@param kind string projected child kind under mapping
---@return table<string, unknown> detached party/target child view
local function projectRosterRows(self, native, kind)
  local shell = {
    kind = kind,
    purpose = self._purpose,
    interactive = true,
    notice = self._notice,
    cancellable = self._cancellable,
    rows = {},
    focusId = nil,
    native = native,
  } --[[@as table<string, unknown>]]
  local view = type(native) == "table" and native.view or nil
  if type(native) ~= "table" or native.open == false or type(view) ~= "table" then
    if self._composed ~= nil then
      shell.application = self._composed:application()
    end
    return shell
  end
  if self._composed ~= nil then
    shell.application = self._composed:application()
  end
  local slots = view.slots --[[@as table<integer, table<string, unknown>>]]
  local rows = {}
  for slot = 0, 5 do
    local record = slots[slot + 1]
    local label = "Empty"
    local sub = nil
    local detail = ""
    local enabled = false
    local reason = nil
    local occupied = false
    if type(record) == "table" and record.occupied == true then
      occupied = true
      local name = record.displayName
      label = tostring(type(name) == "string" and name ~= "" and name or "Unknown")
      if type(record.level) == "number" then
        sub = "Lv" .. tostring(record.level)
      end
      local hp = tonumber(record.currentHp) or 0
      local maxHp = tonumber(record.maxHp) or 0
      detail = "HP " .. tostring(hp) .. "/" .. tostring(maxHp)
      if record.eligible == true then
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
      occupied = occupied,
    }
  end
  local cursor = native.cursorNode
  if type(cursor) == "number" then
    shell.focusId = "party:" .. tostring(cursor)
  elseif cursor == "cancel" then
    shell.focusId = "back"
  end
  shell.rows = rows
  if kind == "target" then
    shell.stagedItem = self._stagedItem
  end
  return shell
end

-- Projects the native bag browser rows for paint and hit regions: the
-- six visible pocket cells with their catalog names, quantities, and
-- kernel legality, plus pocket identity and page facts read from the
-- native status. Empty cells stay visible but never activate.
---@param native table<string, unknown> native bag status record under projection
---@return table<string, unknown> detached bag child view
local function projectBagRows(self, native)
  if type(native) ~= "table" or native.open == false then
    local shell = {
      kind = "bag",
      purpose = self._purpose,
      interactive = true,
      notice = self._notice,
      cancellable = self._cancellable,
      rows = {},
      focusId = nil,
      native = native,
    } --[[@as table<string, unknown>]]
    if self._composed ~= nil then
      shell.application = self._composed:application()
    end
    return shell
  end
  local slots = native.slots --[[@as table<integer, table<string, unknown>>?]]
  if slots == nil or #slots == 0 then
    return {
      kind = "bag",
      purpose = self._purpose,
      interactive = true,
      notice = self._notice or "The bag is empty.",
      cancellable = self._cancellable,
      rows = {},
      focusId = "back",
      native = native,
      pockets = {},
      currentPocket = nil,
      page = { current = 1, count = 1 },
      empty = true,
    } --[[@as table<string, unknown>]]
  end
  local options = self:_openOptions()
  local cells = native.visibleSlots --[[@as table<integer, table<string, unknown>>?]]
  local rows = {}
  for cell = 1, 6 do
    local entry = type(cells) == "table" and cells[cell] or nil
    if type(entry) == "table" and entry.empty ~= true then
      local key = entry.item
      assert(type(key) == "string", "stocked cells carry their item key")
      local legal, reason = itemLegality(options, key)
      rows[#rows + 1] = {
        id = "bag:" .. tostring(cell - 1),
        label = tostring(entry.name or key),
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
  local focused = native.focusedVisibleIndex
  if type(focused) == "number" then
    focusId = "bag:" .. tostring(focused)
  elseif native.focus == "cancel" then
    focusId = "back"
  end
  local pockets = {}
  if type(native.pockets) == "table" then
    for _, tab in
      ipairs(native.pockets --[[@as table<integer, table<string, unknown>>]])
    do
      if type(tab) == "table" and type(tab.pocket) == "string" then
        pockets[#pockets + 1] = tab.pocket
      end
    end
  end
  local view = {
    kind = "bag",
    purpose = self._purpose,
    interactive = true,
    notice = self._notice,
    cancellable = self._cancellable,
    rows = rows,
    focusId = focusId,
    native = native,
    pockets = pockets,
    currentPocket = native.pocket,
    page = copyValue(native.page) or { current = 1, count = 1 },
    stock = #slots,
  } --[[@as table<string, unknown>]]
  if self._composed ~= nil then
    view.application = self._composed:application()
  end
  return view
end

-- Projects the native Restore PP rows for paint and hit regions: each
-- held move with its PP, the native picker focus, and the holder name.
---@param native table<string, unknown> native move picker status under projection
---@return table<string, unknown> detached move child view
local function projectMoveRows(self, native)
  local view = {
    kind = "move",
    purpose = self._purpose,
    interactive = true,
    notice = self._notice,
    cancellable = true,
    rows = {},
    focusId = nil,
    stagedItem = self._stagedItem,
    holderName = native.holderName,
  } --[[@as table<string, unknown>]]
  if native.open == false then
    return view
  end
  local facts = native.facts --[[@as table<string, unknown>]]
  for _, row in
    ipairs(facts.moves --[[@as table<integer, table<string, unknown>>]])
  do
    if row.kind == "move" then
      view.rows[#view.rows + 1] = {
        id = "move:" .. tostring(row.moveSlot),
        label = tostring(row.name or row.key),
        sub = "PP " .. tostring(row.pp) .. "/" .. tostring(row.maxPp),
        detail = "",
        enabled = true,
      }
    end
  end
  if type(native.moveSlot) == "number" then
    view.focusId = "move:" .. tostring(native.moveSlot)
  end
  if self._composed ~= nil then
    view.application = self._composed:application()
  end
  return view
end

-- Projects the native learning rows for paint and hit regions: the four
-- held moves from the staged prompt, the decline entry, the native
-- picker focus, and the staged barrier confirmation. Rows never seal on
-- their own; taps route through the same native focus as keyboard input.
---@return table<string, unknown>? detached learning child view, nil without its prompt
local function projectLearnRows(self)
  local intent = assert(self._intent, "learning projects its open intent")
  local request = intent.request --[[@as table<string, unknown>]]
  local moves = request.currentMoves --[[@as table<integer, unknown>]]
  -- Held-move detail facts come from the composed native summary owner:
  -- the same battle-local facts model the move-pick presentation
  -- navigates. The decline row carries no held facts.
  local facts = nil
  if self._composed ~= nil then
    local moveFacts = self._composed.moveFacts
    if type(moveFacts) == "function" then
      local ok, held = pcall(moveFacts, self._composed)
      if ok and type(held) == "table" then
        facts = held
      end
    end
  end
  local rows = {}
  for index = 1, 4 do
    local row = {
      id = "learn:" .. tostring(index - 1),
      label = learnMoveLabel(moves[index]),
      detail = "Replace",
      enabled = true,
    } --[[@as table<string, unknown>]]
    if type(facts) == "table" and type(facts[index]) == "table" then
      row.facts = facts[index]
    end
    rows[#rows + 1] = row
  end
  rows[#rows + 1] = { id = "learn:decline", label = "Decline", detail = "Keep moves", enabled = true }
  local focusId = nil
  if self._composed ~= nil then
    local ok, native = pcall(self._composed.draw, self._composed, nil)
    if ok and type(native) == "table" and native.open ~= false then
      local moveSlot = native.moveSlot
      if type(moveSlot) == "number" and moveSlot >= 0 and moveSlot <= 3 then
        focusId = "learn:" .. tostring(moveSlot)
      elseif moveSlot == 4 then
        focusId = "learn:decline"
      end
    end
  end
  local view = {
    kind = "learn",
    purpose = self._purpose,
    interactive = true,
    notice = self._notice,
    cancellable = false,
    rows = rows,
    focusId = focusId,
    confirmation = copyValue(self._learnConfirm),
    incomingMove = request.incomingMove,
  } --[[@as table<string, unknown>]]
  if self._composed ~= nil then
    view.application = self._composed:application()
  end
  return view
end

-- Detached naming child view for paint and hit regions: the native naming
-- screen kind with its application receipt, the staged text (never sealed
-- by reading), and the barrier identity. Taps route through the same
-- control mapping as keyboard input.
---@return table<string, unknown>? detached naming child view, nil without its composed child
local function namingChildView(self)
  local child = self._composed
  if child == nil then
    return nil
  end
  local text = ""
  local namingText = child.namingText
  if type(namingText) == "function" then
    local ok, staged = pcall(namingText, child)
    if ok and type(staged) == "string" then
      text = staged
    end
  end
  return {
    kind = "naming",
    purpose = self._purpose,
    interactive = true,
    notice = self._notice,
    cancellable = self._cancellable,
    rows = {},
    focusId = nil,
    text = text,
    application = child:application(),
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
  if self._active == "learn" then
    record.confirmation = copyValue(self._learnConfirm)
    local intent = self._intent
    if type(intent) == "table" and type(intent.request) == "table" then
      local request = intent.request --[[@as table<string, unknown>]]
      record.incomingMove = request.incomingMove
      record.currentMoves = copyValue(request.currentMoves)
    end
    if self._composed ~= nil then
      local ok, native = pcall(self._composed.draw, self._composed, nil)
      if ok and type(native) == "table" and native.open ~= false then
        record.focus = native.moveSlot
      end
    end
  end
  if self._active == "naming" and self._composed ~= nil then
    local namingText = self._composed.namingText
    if type(namingText) == "function" then
      local ok, staged = pcall(namingText, self._composed)
      if ok and type(staged) == "string" then
        record.stagedText = staged
      end
    end
  end
  record.childView = self:_projectChildView()
  return record
end

-- Projects the detached child view for paint and hit regions from the
-- native controller status. Party/target rows read the native roster
-- status with its focus and kernel eligibility; bag rows read the native
-- pocket window and kernel item policy; learning rows read the native
-- picker focus with the staged prompt. Read-only snapshots only.
---@return table<string, unknown>? detached child view, nil while no child owns input
function BattleSubflows:_projectChildView()
  if self._disposed or self._active == nil then
    return nil
  end
  if self._composed == nil then
    return nil
  end
  if self._active == "party" then
    local ok, native = pcall(self._composed.draw, self._composed, nil)
    if not ok then
      return nil
    end
    return projectRosterRows(self, native --[[@as table<string, unknown>]], "party")
  elseif self._active == "target" then
    local native = self._composed:targetStatus()
    if native == nil then
      return nil
    end
    return projectRosterRows(self, native, "target")
  elseif self._active == "bag" then
    local ok, native = pcall(self._composed.draw, self._composed, nil)
    if not ok then
      return nil
    end
    return projectBagRows(self, native --[[@as table<string, unknown>]])
  elseif self._active == "move" then
    local native = self._composed:moveStatus()
    if native == nil then
      return nil
    end
    return projectMoveRows(self, native)
  elseif self._active == "learn" then
    return projectLearnRows(self)
  elseif self._active == "naming" then
    return namingChildView(self)
  end
  return nil
end

-- Routes one tap to the native controller through the barrier tap queue:
-- the tap validates against the projected rows, then the next source
-- tick synthesizes its matched pointer pair at the same canonical center
-- the paint and hit-testing share. A tap on a visibly disabled row shows
-- its reason through the next projection without submitting; unknown ids
-- never seal.
---@param id string stable row/control identity under activation
---@return boolean consumed true when the tap belonged to the open child
function BattleSubflows:activateControl(id)
  if self._disposed or self._active == nil or self._pending ~= nil then
    return false
  end
  assert(type(id) == "string" and id ~= "", "child taps name their control")
  if self._active == "naming" then
    if
      id ~= "upper"
      and id ~= "lower"
      and id ~= "symbols"
      and id ~= "back"
      and id ~= "ok"
      and id:sub(1, 6) ~= "glyph:"
    then
      return false
    end
    self._queued[#self._queued + 1] = { type = "name_control", id = id }
    return true
  end
  -- The staged learning confirmation owns its barrier edges: confirm
  -- seals the stored fragment while Back rebuilds the native list.
  if self._learnConfirm ~= nil then
    if id == "confirm" then
      self._queued[#self._queued + 1] = { type = "confirm" }
      return true
    end
    if id == "back" then
      self._queued[#self._queued + 1] = { type = "cancel" }
      return true
    end
    return false
  end
  local view = self:_projectChildView()
  if view == nil then
    return false
  end
  local known = id == "back"
  if not known and type(view.rows) == "table" then
    for _, row in
      ipairs(view.rows --[[@as table<integer, table<string, unknown>>]])
    do
      if type(row) == "table" and row.id == id then
        known = true
        break
      end
    end
  end
  if not known and self._active == "bag" and (id == "pocket_prev" or id == "pocket_next") then
    known = view.empty ~= true
  end
  if not known then
    return false
  end
  self._queued[#self._queued + 1] = { type = "tap", id = id }
  return true
end

-- Routes a touch through the active native layout. The barrier owns only
-- the pointer pair; the Bag or Party controller resolves its coordinates
-- against the generated source hit geometry.
---@param x number native logical touch coordinate
---@param y number native logical touch coordinate
---@return boolean consumed true while a pointer-owning child is open
function BattleSubflows:activatePoint(x, y)
  if self._disposed or self._active == nil or self._pending ~= nil then
    return false
  end
  assert(type(x) == "number" and type(y) == "number", "native menu taps carry logical coordinates")
  self._queued[#self._queued + 1] = { type = "pointer_down", pointerId = "battle-native-tap", x = x, y = y }
  self._queued[#self._queued + 1] = { type = "pointer_up", pointerId = "battle-native-tap", x = x, y = y }
  return true
end

---@return table<string, unknown>? staged bound result, exactly once
function BattleSubflows:takeResult()
  if self._disposed or self._active == nil then
    return nil
  end
  -- The naming child owns its result through the composed native screen:
  -- submitting seals the entered text once and a permitted cancel reports
  -- its bound cancellation once.
  if self._active == "naming" then
    local child = assert(self._composed, "naming takes its composed result")
    return child:takeResult()
  end
  local result = self._pending
  self._pending = nil
  if result ~= nil then
    self._notice = nil
  end
  return result
end

-- Closes the active child and drops its buffered edges. Closing only
-- clears references without sealing. The composed child disposes exactly
-- once: borrowed catalogs stay usable while owned controller state
-- releases. Staged state clears without sealing.
function BattleSubflows:closeChild()
  if self._composed ~= nil then
    self._composed:dispose()
    self._composed = nil
  end
  self._stagedItem = nil
  self._learnConfirm = nil
  self._queued = {}
  self._intent = nil
  self._active = nil
  self._purpose = nil
  self._pending = nil
  self._notice = nil
  self._openOptionsValue = nil
  self._openPartyValue = nil
end

-- Cancels a held press through the single controller tick path: queued
-- taps drop (press topology belongs to the barrier, so a remeasure
-- invalidates the armed activation) while the release edge itself buffers
-- behind the next accepted tick. The battle keeps no held-press state of
-- its own: press arming lives with the parent, and stored request
-- identity stays put.
function BattleSubflows:cancelPointerCapture()
  if self._disposed or self._active == nil or self._pending ~= nil then
    return
  end
  local kept = {}
  for _, event in ipairs(self._queued) do
    if type(event) ~= "table" or event.type ~= "tap" then
      kept[#kept + 1] = event
    end
  end
  self._queued = kept
  self._queued[#self._queued + 1] = { type = "pointer_cancel" }
end

-- Idempotent release of the child lifetime: staged results clear, and
-- borrowed catalogs stay usable.
function BattleSubflows:dispose()
  if self._disposed then
    return
  end
  self._disposed = true
  self:closeChild()
end

return BattleSubflows
