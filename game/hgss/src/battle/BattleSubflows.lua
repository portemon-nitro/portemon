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

local BattleBagPockets = require("game.hgss.src.battle.BattleBagPockets")
local BattleChildApplications = require("game.hgss.src.battle.BattleChildApplications")

-- Retail bag/party menu sounds (battle_bag_menu.c, battle_party_menu.c
-- PlaySE call sites; battle_dpad_cursor.c voices SELECT on moves).
-- The barrier owns menu feedback: native controllers stay silent so one
-- edge voices exactly once. Heal-effect KAIFUKU voices through the
-- timeline item-use cue, never through this menu barrier.
local DECIDE_SOUND = "SEQ_SE_DP_DECIDE"
local SELECT_SOUND = "SEQ_SE_DP_SELECT"

-- Staged retail messages with a current producer/consumer: no-effect
-- names kernel PartyItemEffects refusals; no-energy names fainted
-- roster rows; bag/party reason vocabulary maps kernel refusal reasons
-- to their staged TryUseItem/CanSwitch messages (battle_bag_menu.c
-- TryUseItem pockets 2/3, battle_party_menu.c CanSwitchToSelectedMon).
-- Unknown reasons pass through unchanged so future kernel reasons stay
-- visible instead of vanishing behind a generic fallback.
local NO_EFFECT_KEY = "battle/narration/item-no-effect"
local NO_ENERGY_KEY = "battle/party/message/no-energy"
local BAG_REASON_KEYS = {
  no_aim_doubles = "battle/bag/message/no-aim-doubles",
  no_room = "battle/bag/message/no-room",
  embargo = "battle/bag/message/embargo",
  no_aim_hidden = "battle/bag/message/no-aim-hidden",
  no_aim_hidden_foe = "battle/bag/message/no-aim-hidden-foe",
  -- Retail trainer-escape refusal (TryUseItem battleUseFunc 3, msg bank
  -- 0040 id 37): Oak's rebuke naming the player.
  no_stealing = "battle/bag/message/no-stealing",
}
local PARTY_REASON_KEYS = {
  already_in_battle = "battle/party/message/already-in-battle",
  no_energy = "battle/party/message/no-energy",
  cant_switch_out = "battle/party/message/cant-switch-out",
  egg = "battle/party/message/egg",
  cant_switch_foe = "battle/party/message/cant-switch-foe",
  no_effect = "battle/party/message/no-effect",
  already_selected = "battle/party/message/already-selected",
  embargo = "battle/party/message/embargo",
}

---@class BattleSubflows
---@field _launchId string owning launch identity
---@field _itemCatalog table<string, unknown>? borrowed immutable item catalog for pocket grouping
---@field _monCatalog table<string, unknown>? borrowed immutable mon catalog for machine display facts
---@field _battleMenus table<string, unknown>? borrowed native battle menu renderer and manifest services
---@field _audioEffect? fun(symbol: string) borrowed battle sound boundary behind menu feedback
---@field _resolveMessage? fun(key: string, subs: table<integer, string>?): string borrowed staged message resolver behind retail text
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
---@field _stagedCursor BagBattleCursor? browser exit cursor behind the staged item
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

---@param key string staged message key under resolution
---@param fallback string current English text while no resolver is borrowed
---@param subs table<integer, string>? source substitutions behind placeholders
---@return string resolved retail text or its fallback
function BattleSubflows:_resolveOr(key, fallback, subs)
  local resolve = self._resolveMessage
  if resolve ~= nil then
    return resolve(key, subs or {})
  end
  return fallback
end

---@param reason string? supplied refusal reason under display
---@param subs table<integer, string>? source substitutions behind placeholders
---@return string visible refusal text
function BattleSubflows:_refusalText(reason, subs)
  if type(reason) == "string" and reason ~= "" then
    if reason == "no_effect" or reason == "invalid_target" then
      return self:_resolveOr(NO_EFFECT_KEY, "It won’t do any good to use that!", subs)
    end
    local bagKey = BAG_REASON_KEYS[reason]
    if bagKey ~= nil then
      return self:_resolveOr(bagKey, reason, subs)
    end
    local partyKey = PARTY_REASON_KEYS[reason]
    if partyKey ~= nil then
      return self:_resolveOr(partyKey, reason, subs)
    end
    return reason
  end
  return "That choice is unavailable."
end

-- Builds the source substitutions behind one kernel refusal reason.
-- Most TryUseItem messages carry no placeholders; the embargo rebuke
-- names the embargoed holder with the Embargo move
-- (battle_bag_menu.c BufferMoveName MOVE_EMBARGO + BufferBoxMonNickname)
-- and the trainer-escape rebuke names the player (BufferPlayersName).
-- Reasons without placeholders take none.
---@param reason string? supplied refusal reason under display
---@return table<integer, string>? source substitutions, nil without placeholders
function BattleSubflows:_refusalSubs(reason)
  if reason == "embargo" then
    local holderName = nil
    local options = self._openOptionsValue
    local actors = type(options) == "table" and options.actors or nil
    local combatant = type(actors) == "table" and type(actors[1]) == "table" and actors[1].combatant or nil
    if type(combatant) == "number" then
      local roster = self._openPartyValue
      if type(roster) == "table" then
        for _, record in ipairs(roster) do
          if type(record) == "table" and record.combatant == combatant then
            local name = record.name
            if type(name) == "string" and name ~= "" then
              holderName = name
            end
            break
          end
        end
      end
    end
    -- assert returns its message beside the value, so the holder binds
    -- first: the substitution list carries exactly the move and the mon.
    local holder = assert(holderName, "embargo refusals name their embargoed holder")
    return { "Embargo", holder }
  end
  if reason == "no_stealing" then
    local intent = self._intent
    local playerName = type(intent) == "table" and intent.playerName or nil
    local player = assert(
      type(playerName) == "string" and playerName ~= "" and playerName or nil,
      "stealing refusals name the player"
    )
    return { player }
  end
  return nil
end

---@param symbol string staged sound symbol under playback
function BattleSubflows:_play(symbol)
  local effect = self._audioEffect
  if effect ~= nil then
    effect(symbol)
  end
end

---@return table<string, unknown> tick sound baseline behind edge detection
function BattleSubflows:_tickSoundBefore()
  local view = self:_projectChildView()
  local page = type(view) == "table" and view.page or nil
  return {
    focus = type(view) == "table" and view.focusId or nil,
    pending = self._pending ~= nil,
    staged = self._stagedItem,
    active = self._active,
    confirm = self._learnConfirm ~= nil,
    bagPage = type(view) == "table" and view.bagPage or nil,
    bagListPage = type(page) == "table" and page.current or nil,
    partyPage = type(view) == "table" and view.partyPage or nil,
    pageSlot = type(view) == "table" and view.pageSlot or nil,
  }
end

---@param before table<string, unknown> tick sound baseline under comparison
function BattleSubflows:_emitTickSounds(before)
  if self._audioEffect == nil then
    return
  end
  local afterView = self:_projectChildView()
  local afterFocus = type(afterView) == "table" and afterView.focusId or nil
  local afterPending = self._pending ~= nil
  local afterStaged = self._stagedItem
  local afterActive = self._active
  local afterConfirm = self._learnConfirm ~= nil
  local afterBagPage = type(afterView) == "table" and afterView.bagPage or nil
  local afterPage = type(afterView) == "table" and afterView.page or nil
  local afterBagListPage = type(afterPage) == "table" and afterPage.current or nil
  local afterPartyPage = type(afterView) == "table" and afterView.partyPage or nil
  local afterPageSlot = type(afterView) == "table" and afterView.pageSlot or nil
  if before.pending == false and afterPending == true then
    self:_play(DECIDE_SOUND)
    return
  end
  if before.staged == nil and afterStaged ~= nil then
    self:_play(DECIDE_SOUND)
    return
  end
  if before.confirm ~= afterConfirm then
    self:_play(DECIDE_SOUND)
    return
  end
  if before.active ~= afterActive then
    self:_play(DECIDE_SOUND)
    return
  end
  if before.bagPage ~= afterBagPage then
    self:_play(DECIDE_SOUND)
    return
  end
  -- Turning the item-list page voices DECIDE like any page change
  -- (ChangeItemPage follows the pressed stepper's button animation).
  if before.bagListPage ~= afterBagListPage then
    self:_play(DECIDE_SOUND)
    return
  end
  if before.partyPage ~= afterPartyPage then
    self:_play(DECIDE_SOUND)
    return
  end
  if before.pageSlot ~= afterPageSlot then
    self:_play(DECIDE_SOUND)
    return
  end
  if before.focus ~= afterFocus then
    self:_play(SELECT_SOUND)
  end
end

---@class BattleSubflows.Options
---@field launchId string owning launch identity
---@field itemCatalog table<string, unknown>? borrowed immutable item catalog for pocket grouping
---@field monCatalog table<string, unknown>? borrowed immutable mon catalog for machine display facts
---@field battleMenus table<string, unknown>? borrowed native battle menu renderer and manifest services
---@field audioEffect? fun(symbol: string) borrowed battle sound boundary behind menu feedback
---@field resolveMessage? fun(key: string, subs: table<integer, string>?): string borrowed staged message resolver behind retail text

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
  if opts.audioEffect ~= nil then
    assert(type(opts.audioEffect) == "function", "battle menu feedback arrives as a function")
  end
  if opts.resolveMessage ~= nil then
    assert(type(opts.resolveMessage) == "function", "battle message resolution arrives as a function")
  end
  return setmetatable({
    _launchId = opts.launchId,
    _itemCatalog = opts.itemCatalog,
    _monCatalog = opts.monCatalog,
    _battleMenus = opts.battleMenus,
    _audioEffect = opts.audioEffect,
    _resolveMessage = opts.resolveMessage,
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
    _stagedCursor = nil,
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
  if intent.kind == "bag" and intent.battleCursor ~= nil then
    local saved = intent.battleCursor --[[@as table<string, unknown>]]
    assert(type(saved) == "table", "bag intents carry their battle cursor as a record")
    assert(
      type(saved.pocket) == "number" and saved.pocket % 1 == 0 and saved.pocket >= 0 and saved.pocket <= 3,
      "bag intents name their battle pocket"
    )
    assert(type(saved.pages) == "table", "bag intents carry their battle pages")
    assert(type(saved.positions) == "table", "bag intents carry their battle cells")
  end
  if intent.kind == "bag" and intent.slotOrder ~= nil then
    assert(type(intent.slotOrder) == "table", "bag intents carry their slot order as a sequence")
  end
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
    resolveMessage = self._resolveMessage,
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

-- Stages one battle item from the native browser selection: refused
-- items explain themselves on the retail message page (TryUseItem
-- ShowMessage, nextState 8) instead of sealing or opening targets;
-- capture throws seal directly through their opposing-holder fragment,
-- while servings open admitted-target selection on the native
-- item-target picker beside the retained browser.
---@param itemKey string staged battle item identity under routing
---@param cursor BagBattleCursor? browser exit cursor behind the sealed item under routing
function BattleSubflows:stageItem(itemKey, cursor)
  local intentOptions = self:_openOptions()
  -- Kernel-projected refusals surface before anything seals: the message
  -- page carries the staged retail text with its source substitutions.
  local legal, refusal = itemLegality(intentOptions, itemKey)
  if legal ~= true then
    local composed = assert(self._composed, "refusals keep their composed child")
    composed:showMessage(self:_refusalText(refusal, self:_refusalSubs(refusal)))
    self._notice = nil
    return
  end
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
      local composed = assert(self._composed, "refusals keep their composed child")
      composed:showMessage(self:_refusalText(nil))
      return
    end
    self._pending = { kind = "choice", reply = self:_bind(foeFragment) }
    -- A sealed throw stores the browser exit cursor for the next
    -- opening (BattleBagMenu_Exit writes cursor state on selection).
    if type(cursor) == "table" then
      self._pending.cursor = copyValue(cursor)
    end
    return
  end
  if ownCount == 0 then
    local composed = assert(self._composed, "refusals keep their composed child")
    composed:showMessage(self:_refusalText(nil))
    return
  end
  self._stagedItem = itemKey
  self._stagedCursor = type(cursor) == "table" and copyValue(cursor) or nil
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
    self._stagedCursor = nil
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
  local holderName = nil
  local holderEmbargoed = false
  for _, record in ipairs(roster) do
    if type(record) == "table" and record.slot == slot and type(record.combatant) == "number" then
      combatant = record.combatant
      if type(record.name) == "string" and record.name ~= "" then
        holderName = record.name
      end
      holderEmbargoed = record.embargoed == true
      break
    end
  end
  -- Retail party-target embargo (battle_party_menu.c TryUseItemOnMon
  -- msg 95, battle/party/message/embargo): the chosen mon is refused
  -- while its field slot carries Embargo, resetting the selection
  -- instead of sealing. Subs name the Embargo move and the holder
  -- nickname like the bag embargo message; the picker shows the text
  -- over the list and restores its origin.
  if holderEmbargoed then
    local composed = assert(self._composed, "embargo refusals keep their composed child")
    local holder = assert(holderName, "embargo refusals name their embargoed holder")
    composed:refuseTarget(self:_resolveOr("battle/party/message/embargo", "embargo", { "Embargo", holder }))
    return
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
  -- A sealed serving stores the browser exit cursor for the next
  -- opening; the staged copy clears so a later seal cannot reuse it.
  if self._stagedCursor ~= nil then
    self._pending.cursor = self._stagedCursor
    self._stagedCursor = nil
  end
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
      if self._stagedCursor ~= nil then
        self._pending.cursor = self._stagedCursor
        self._stagedCursor = nil
      end
      return
    end
    composed:closeMove(self:_resolveOr(NO_EFFECT_KEY, "It won’t have any effect."))
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
  local before = self:_tickSoundBefore()
  if self._active == "naming" then
    if #self._queued > 0 then
      composed:input(self._queued)
    end
    self._queued = {}
    composed:stepSourceTick(1)
    self:_emitTickSounds(before)
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
    self:_emitTickSounds(before)
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
      self:stageItem(intent.item --[[@as string]], intent.cursor --[[@as table?]])
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
        self._stagedCursor = nil
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
  self:_emitTickSounds(before)
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

-- Projects the retail battle mon-menu rows (battle_party_menu.c
-- PrintMonMenuPage): SHIFT always, SUMMARY and CHECK MOVES for non-eggs,
-- and back. Focus follows the native menu index; rows never seal.
---@param self BattleSubflows barrier under projection
---@param shell table<string, unknown> detached child view under filling
---@param native table<string, unknown> native party status under projection
---@param kind string projected child kind under mapping
---@return table<string, unknown> detached mon-menu child view
local function projectMonMenu(self, shell, native, kind)
  local entries = native.menu --[[@as table<integer, table<string, unknown>>]]
  local rows = {}
  for _, entry in ipairs(entries) do
    if type(entry) == "table" and type(entry.kind) == "string" then
      local id = nil
      if entry.kind == "switch" then
        id = "switch"
      elseif entry.kind == "summary" then
        id = "summary"
      elseif entry.kind == "check_moves" then
        id = "moves"
      elseif entry.kind == "quit" then
        id = "back"
      end
      if id ~= nil then
        rows[#rows + 1] = {
          id = id,
          label = tostring(entry.label or id),
          detail = "",
          enabled = true,
        }
      end
    end
  end
  local focusId = nil
  local index = tonumber(native.menuIndex)
  if index ~= nil and type(entries[index]) == "table" then
    local focused = entries[index].kind
    if focused == "switch" then
      focusId = "switch"
    elseif focused == "summary" then
      focusId = "summary"
    elseif focused == "check_moves" then
      focusId = "moves"
    elseif focused == "quit" then
      focusId = "back"
    end
  end
  shell.rows = rows
  shell.focusId = focusId
  shell.partyPage = "mon_menu"
  if kind == "target" then
    shell.stagedItem = self._stagedItem
  end
  return shell
end

-- Finds one detached roster record by slot for page facts.
---@param self BattleSubflows barrier under projection
---@param slot integer roster slot under lookup
---@return table<string, unknown>? detached roster record
local function pageRecord(self, slot)
  local roster = self:_openParty()
  for _, record in ipairs(roster) do
    if type(record) == "table" and record.slot == slot then
      return record
    end
  end
  return nil
end

-- Resolves one battle ability key to its catalog display name, falling
-- back to the key itself when no catalog (or name) answers.
---@param self BattleSubflows barrier under projection
---@param key string ability identity under display
---@return string display name for the staged ability template
local function abilityDisplayName(self, key)
  local catalog = self._monCatalog
  if catalog ~= nil then
    local lookup = catalog.ability --[[@as fun(self: table<string, unknown>, key: string): table<string, unknown>?]]
    if type(lookup) == "function" then
      local ok, record = pcall(lookup, catalog, key)
      if ok and type(record) == "table" then
        local name = record.name --[[@as string?]]
        if type(name) == "string" and name ~= "" then
          return name
        end
      end
    end
  end
  return key
end

-- Resolves one held item key to its catalog display name, falling back
-- to the key itself when no catalog (or name) answers.
---@param self BattleSubflows barrier under projection
---@param key string held item identity under display
---@return string display name for the staged item template
local function itemDisplayName(self, key)
  local catalog = self._itemCatalog
  if catalog ~= nil then
    local ok, record = pcall(catalogItem, catalog, key)
    if ok and type(record) == "table" then
      local name = record.name --[[@as string?]]
      if type(name) == "string" and name ~= "" then
        return name
      end
    end
  end
  return key
end

-- Names the staged mon-name template for one roster slot
-- (sBattlePartyMonNameMsgIds indexed by slot): slots outside the
-- six-mon roster fall back to the lead template instead of naming an
-- unstaged key.
---@param slot integer roster slot under display
---@return string staged mon-name key for the slot
local function monNameKey(slot)
  if slot < 0 or slot > 5 then
    return "battle/party/mon-name/0"
  end
  return "battle/party/mon-name/" .. tostring(slot)
end

-- Names the staged move-name template for one held move slot
-- (sBattlePartyMoveNameMsgIds indexed by move slot).
---@param moveSlot integer held move slot under display
---@return string staged move-name key for the slot
local function moveNameKey(moveSlot)
  if moveSlot < 0 or moveSlot > 4 then
    return "battle/party/move-name/0"
  end
  return "battle/party/move-name/" .. tostring(moveSlot)
end

-- Suffixes one wrapper mon row with its staged gender symbol, like the
-- retail name printers; genderless and unknown records print no symbol.
-- The symbol rides the row sub so each staged print keeps its own font
-- and window colors at paint time.
---@param self BattleSubflows barrier under projection
---@param record table<string, unknown> detached roster record under display
---@return string? staged gender symbol for the row sub, nil without a binary gender
local function monGenderSub(self, record)
  if record.gender == "male" then
    return self:_resolveOr("battle/party/gender/male", "♂")
  end
  if record.gender == "female" then
    return self:_resolveOr("battle/party/gender/female", "♀")
  end
  return nil
end

-- Labels one wrapper mon row through its staged per-slot nickname
-- template.
---@param self BattleSubflows barrier under projection
---@param record table<string, unknown> detached roster record under display
---@param slot integer roster slot under display
---@return string staged mon row label
local function monRowLabel(self, record, slot)
  local name = tostring(type(record.name) == "string" and record.name ~= "" and record.name or "Unknown")
  return self:_resolveOr(monNameKey(slot), name, { name })
end

-- Projects the retail battle summary/check-moves/move-detail rows
-- (battle_party_menu.c pages 2-4) over the detached roster: the staged
-- stat block, move names, and move-detail words with prev/next
-- navigation and back controls. Pages never seal; only the list SHIFT
-- seals its kernel fragment.
---@param self BattleSubflows barrier under projection
---@param shell table<string, unknown> detached child view under filling
---@param native table<string, unknown> native page status under projection
---@param kind string projected child kind under mapping
---@param page string wrapper page under projection
---@return table<string, unknown> detached page child view
local function projectPartyPage(self, shell, native, kind, page)
  local rawSlot = tonumber(native.pageSlot) or 0
  assert(rawSlot % 1 == 0, "page slots stay integral")
  local slot = rawSlot --[[@as integer]]
  local record = pageRecord(self, slot) or {}
  local hp = tonumber(record.hp) or 0
  local maxHp = tonumber(record.maxHp) or 0
  shell.pageSlot = slot
  if page == "summary" then
    local level = tonumber(record.level) or 0
    local nextExp = tonumber(record.nextExp) or 0
    local rows = {
      {
        id = "summary:mon",
        label = monRowLabel(self, record, slot),
        sub = monGenderSub(self, record),
        detail = "",
        enabled = false,
      },
      {
        id = "summary:level",
        label = self:_resolveOr("battle/party/stat/level", "Lv."),
        detail = self:_resolveOr("battle/party/stat/level-value", tostring(level), { tostring(level) }),
        enabled = false,
      },
      {
        id = "summary:exp",
        label = self:_resolveOr("battle/party/stat/exp", "NEXT LV"),
        detail = self:_resolveOr("battle/party/stat/exp-value", tostring(nextExp), { tostring(nextExp) }),
        enabled = false,
      },
      {
        id = "summary:hp",
        label = self:_resolveOr("battle/party/stat/hp", "HP"),
        detail = self:_resolveOr("battle/party/stat/hp-current", tostring(hp), { tostring(hp) })
          .. self:_resolveOr("battle/party/stat/hp-slash", "/")
          .. self:_resolveOr("battle/party/stat/hp-max", tostring(maxHp), { tostring(maxHp) }),
        enabled = false,
      },
    }
    -- The five battle stats print in retail print order
    -- (PrintAttack/Defense/Speed/SpAttack/SpDefense).
    local stats = {
      { id = "summary:attack", key = "attack", field = "attack", fallback = "ATTACK" },
      { id = "summary:defense", key = "defense", field = "defense", fallback = "DEFENSE" },
      { id = "summary:speed", key = "speed", field = "speed", fallback = "SPEED" },
      { id = "summary:sp-attack", key = "sp-attack", field = "specialAttack", fallback = "SP. ATK" },
      { id = "summary:sp-defense", key = "sp-defense", field = "specialDefense", fallback = "SP. DEF" },
    }
    for _, stat in ipairs(stats) do
      local value = tonumber(record[stat.field]) or 0
      rows[#rows + 1] = {
        id = stat.id,
        label = self:_resolveOr("battle/party/stat/" .. stat.key, stat.fallback),
        detail = self:_resolveOr("battle/party/stat/" .. stat.key .. "-value", tostring(value), { tostring(value) }),
        enabled = false,
      }
    end
    local ability = type(record.ability) == "string" and record.ability or nil
    local abilityLabel = ""
    if ability ~= nil and ability ~= "" then
      local display = abilityDisplayName(self, ability)
      abilityLabel = self:_resolveOr("battle/party/ability/name", display, { display })
    end
    rows[#rows + 1] = { id = "summary:ability", label = abilityLabel, detail = "", enabled = false }
    local held = type(record.heldItem) == "string" and record.heldItem or nil
    local itemLabel = self:_resolveOr("battle/party/item/none", "No item held")
    if held ~= nil and held ~= "" and held ~= "NONE" then
      local display = itemDisplayName(self, held)
      itemLabel = self:_resolveOr("battle/party/item/name", display, { display })
    end
    rows[#rows + 1] = { id = "summary:item", label = itemLabel, detail = "", enabled = false }
    rows[#rows + 1] = { id = "summary:prev", label = "PREV", detail = "", enabled = true }
    rows[#rows + 1] = { id = "summary:next", label = "NEXT", detail = "", enabled = true }
    rows[#rows + 1] = {
      id = "summary:moves",
      label = self:_resolveOr("battle/party/button/check-moves", "CHECK MOVES"),
      detail = "",
      enabled = true,
    }
    rows[#rows + 1] = { id = "back", label = "Back", detail = "", enabled = true }
    shell.rows = rows
    shell.focusId = type(native.pageFocus) == "string" and native.pageFocus or "summary:moves"
    shell.partyPage = "summary"
  elseif page == "moves" then
    local rows = {}
    local moves = type(record.moves) == "table" and record.moves or {}
    for moveSlot = 0, 3 do
      local entry = moves[moveSlot + 1]
      if type(entry) == "table" then
        local name = tostring(entry.name or entry.move or "Unknown")
        rows[#rows + 1] = {
          id = "move:" .. tostring(moveSlot),
          label = self:_resolveOr(moveNameKey(moveSlot), name, { name }),
          sub = self:_resolveOr("battle/party/move/pp", "PP") .. " " .. tostring(entry.pp or 0) .. "/" .. tostring(
            entry.maxPp or 0
          ),
          detail = "",
          enabled = true,
        }
      else
        rows[#rows + 1] =
          { id = "move:" .. tostring(moveSlot), label = "Empty", detail = "", enabled = false, empty = true }
      end
    end
    rows[#rows + 1] = { id = "moves:prev", label = "PREV", detail = "", enabled = true }
    rows[#rows + 1] = { id = "moves:next", label = "NEXT", detail = "", enabled = true }
    rows[#rows + 1] = {
      id = "moves:summary",
      label = self:_resolveOr("battle/party/button/summary", "SUMMARY"),
      detail = "",
      enabled = true,
    }
    rows[#rows + 1] = { id = "back", label = "Back", detail = "", enabled = true }
    shell.rows = rows
    shell.focusId = type(native.pageFocus) == "string" and native.pageFocus or "move:0"
    shell.partyPage = "moves"
  else
    local rawMove = tonumber(native.pageMove) or 0
    local moveSlot = math.floor(rawMove)
    if moveSlot < 0 or moveSlot > 3 then
      moveSlot = 0
    end
    local moves = type(record.moves) == "table" and record.moves or {}
    local entry = moves[moveSlot + 1]
    local moveName = tostring(type(entry) == "table" and (entry.name or entry.move) or "Unknown")
    local rows = {
      {
        id = "move_detail:mon",
        label = monRowLabel(self, record, slot),
        sub = monGenderSub(self, record),
        detail = "",
        enabled = false,
      },
      {
        id = "move_detail:move",
        label = self:_resolveOr(moveNameKey(moveSlot), moveName, { moveName }),
        detail = "",
        enabled = false,
      },
    }
    local power = type(entry) == "table" and tonumber(entry.power) or nil
    local powerDetail = self:_resolveOr("battle/party/move/no-value", "---")
    if power ~= nil and power > 1 then
      powerDetail = self:_resolveOr("battle/party/move/power-value", tostring(power), { tostring(power) })
    end
    rows[#rows + 1] = {
      id = "move_detail:power",
      label = self:_resolveOr("battle/party/move/power", "POWER"),
      detail = powerDetail,
      enabled = false,
    }
    local accuracy = type(entry) == "table" and tonumber(entry.accuracy) or nil
    local accuracyDetail = self:_resolveOr("battle/party/move/no-value", "---")
    if accuracy ~= nil and accuracy > 0 then
      accuracyDetail = self:_resolveOr("battle/party/move/accuracy-value", tostring(accuracy), { tostring(accuracy) })
    end
    rows[#rows + 1] = {
      id = "move_detail:accuracy",
      label = self:_resolveOr("battle/party/move/accuracy", "ACCURACY"),
      detail = accuracyDetail,
      enabled = false,
    }
    local categoryKey, categoryFallback = nil, ""
    local category = type(entry) == "table" and entry.category or nil
    if category == "physical" then
      categoryKey, categoryFallback = "battle/party/move/category-physical", "PHYSICAL"
    elseif category == "special" then
      categoryKey, categoryFallback = "battle/party/move/category-special", "SPECIAL"
    elseif category == "status" then
      categoryKey, categoryFallback = "battle/party/move/category-status", "STATUS"
    end
    rows[#rows + 1] = {
      id = "move_detail:category",
      label = self:_resolveOr("battle/party/move/category", "CATEGORY"),
      detail = categoryKey ~= nil and self:_resolveOr(categoryKey, categoryFallback) or "",
      enabled = false,
    }
    local pp = type(entry) == "table" and tonumber(entry.pp) or 0
    local maxPp = type(entry) == "table" and tonumber(entry.maxPp) or 0
    rows[#rows + 1] = {
      id = "move_detail:pp",
      label = self:_resolveOr("battle/party/move/pp-label", "PP"),
      detail = self:_resolveOr("battle/party/move/pp-current", tostring(pp), { tostring(pp) })
        .. self:_resolveOr("battle/party/move/pp-slash", "/")
        .. self:_resolveOr("battle/party/move/pp-max", tostring(maxPp), { tostring(maxPp) }),
      enabled = false,
    }
    rows[#rows + 1] = { id = "back", label = "Back", detail = "", enabled = true }
    shell.rows = rows
    shell.focusId = "back"
    shell.partyPage = "move_detail"
  end
  if kind == "target" then
    shell.stagedItem = self._stagedItem
  end
  return shell
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
  local wrapperPage = type(native.page) == "string" and native.page or nil
  if wrapperPage == "summary" or wrapperPage == "moves" or wrapperPage == "move_detail" then
    return projectPartyPage(self, shell, native, kind, wrapperPage)
  end
  if native.state == "context" and type(native.menu) == "table" then
    return projectMonMenu(self, shell, native, kind)
  end
  shell.partyPage = "list"
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
      detail = self:_resolveOr("battle/party/stat/hp", "HP") .. " " .. tostring(hp) .. "/" .. tostring(maxHp)
      if record.eligible == true then
        enabled = true
        detail = detail .. " OK"
      elseif hp <= 0 then
        reason = self:_resolveOr(NO_ENERGY_KEY, "It is fainted.", { label })
        detail = detail .. " KO"
      else
        reason = self:_refusalText(nil)
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

-- Projects the retail battle-bag browser rows for paint and hit
-- regions: the pocket-menu options, the six visible item-list cells with
-- their catalog names, quantities, and kernel legality, or the use-item
-- confirmation, plus pocket identity and page facts read from the native
-- status. Empty cells stay visible but never activate.
---@param pocketKey string? battle pocket key under lookup
---@return integer pocket index for the retail list-title table
local function pocketIndexFor(pocketKey)
  for index, key in ipairs(BattleBagPockets.POCKET_KEYS) do
    if key == pocketKey then
      return index
    end
  end
  return 1
end

-- Resolves the retail item-list pocket title lines (PrintPocketName):
-- HP/PP and STATUS pockets print two lines, BALLS and BATTLE ITEMS one.
---@param self table<string, unknown> coordinator under resolution
---@param pocketKey string? battle pocket key under resolution
---@return table<integer, string> staged title lines in print order
local function pocketTitleLines(self, pocketKey)
  local index = pocketIndexFor(pocketKey)
  local keys = BattleBagPockets.LIST_TITLE_KEYS[index] or { "battle/bag/list-pocket/hp-pp" }
  local lines = {}
  for _, key in ipairs(keys) do
    lines[#lines + 1] = self:_resolveOr(key, tostring(pocketKey or "?"))
  end
  return lines
end

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
  if #pockets == 0 then
    for _, key in ipairs(BattleBagPockets.POCKET_KEYS) do
      pockets[#pockets + 1] = key
    end
  end
  local bagPage = type(native.bagPage) == "string" and native.bagPage or "item_list"
  if bagPage == "pocket_menu" then
    local rows = {}
    for pocket = 0, 3 do
      local key = BattleBagPockets.POCKET_KEYS[pocket + 1]
      local labelKey = BattleBagPockets.POCKET_LABEL_KEYS[pocket + 1]
      local subKey = nil
      if pocket == 0 then
        subKey = "battle/bag/pocket/restore"
      elseif pocket == 1 then
        subKey = "battle/bag/pocket/healers"
      end
      local label = self:_resolveOr(labelKey, key)
      local sub = nil
      if subKey ~= nil then
        sub = self:_resolveOr(subKey, nil)
      end
      rows[#rows + 1] = {
        id = "bagpocket:" .. tostring(pocket),
        label = label,
        sub = sub,
        detail = "",
        enabled = true,
      }
    end
    local lastUsed = native.lastUsed
    if type(lastUsed) == "table" and type(lastUsed.item) == "string" then
      -- Retail last-used shortcut prints only msg 0005/00008
      -- (PrintPocketMenuPage window 4); the staged item icon names
      -- the item, never a text sub.
      rows[#rows + 1] = {
        id = "last_used",
        label = self:_resolveOr("battle/bag/last-used", "LAST USED"),
        detail = "",
        enabled = true,
      }
    else
      rows[#rows + 1] = {
        id = "last_used",
        label = self:_resolveOr("battle/bag/last-used", "LAST USED"),
        detail = "",
        enabled = false,
        empty = true,
      }
    end
    -- Retail cancel is a graphic X in the page art (no window text):
    -- the hit region still cancels, but the row carries no label.
    rows[#rows + 1] = {
      id = "back",
      label = "",
      detail = "",
      enabled = true,
    }
    local focus = tonumber(native.focusedMenuIndex) or 0
    local focusId = "bagpocket:" .. tostring(math.min(math.max(focus, 0), 3))
    if focus == 4 then
      focusId = "last_used"
    elseif focus == 5 then
      focusId = "back"
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
      currentPocket = nil,
      page = { current = 1, count = 1 },
      bagPage = "pocket_menu",
      stock = tonumber(native.stock) or 0,
    } --[[@as table<string, unknown>]]
    if self._composed ~= nil then
      view.application = self._composed:application()
    end
    return view
  end
  if bagPage == "use_item" or bagPage == "message" then
    local useItem = native.useItem
    local rows = {}
    if type(useItem) == "table" and type(useItem.item) == "string" then
      rows[#rows + 1] = {
        id = "bag:0",
        label = tostring(useItem.name or useItem.item),
        sub = "x" .. tostring(useItem.quantity or 0),
        -- Retail use-item info (PrintUseItemPage): the item
        -- description rides its own window through GetItemDesc.
        detail = type(useItem.description) == "string" and useItem.description or "",
        enabled = false,
      }
    end
    rows[#rows + 1] = {
      id = "use",
      label = self:_resolveOr("battle/bag/use", "USE"),
      detail = "",
      enabled = bagPage == "use_item",
    }
    local focusId = "use"
    -- The message page keeps the USE focus: ShowMessage never reseats
    -- the d-pad cursor, it only borrows the window for the refusal.
    if native.useFocus == "back" then
      focusId = "back"
    end
    local view = {
      kind = "bag",
      purpose = self._purpose,
      interactive = true,
      notice = self._notice or (type(native.message) == "string" and native.message or nil),
      cancellable = self._cancellable,
      rows = rows,
      focusId = focusId,
      native = native,
      pockets = pockets,
      currentPocket = native.pocket,
      page = copyValue(native.page) or { current = 1, count = 1 },
      bagPage = bagPage,
      stock = tonumber(native.stock) or 0,
    } --[[@as table<string, unknown>]]
    if self._composed ~= nil then
      view.application = self._composed:application()
    end
    return view
  end
  -- Retail empty pockets still list their page: six cleared cells
  -- with disabled faces, the pocket title, and the 1/1 counter
  -- (SortItemsIntoPockets leaves the page count at 1, DrawPageButtons
  -- repaints empty cells disabled). No black modal ever replaces it.
  local options = self:_openOptions()
  local cells = native.visibleSlots --[[@as table<integer, table<string, unknown>>?]]
  local rows = {}
  for cell = 1, 6 do
    local entry = type(cells) == "table" and cells[cell] or nil
    if type(entry) == "table" and entry.empty ~= true then
      local key = entry.item
      assert(type(key) == "string", "stocked cells carry their item key")
      -- Retail cells print only the name and quantity; legality
      -- refuses on USE through the message page (TryUseItem), never
      -- inline. The kernel reason stays staged for the barrier.
      local legal, reason = itemLegality(options, key)
      local subs = self:_refusalSubs(reason)
      rows[#rows + 1] = {
        id = "bag:" .. tostring(cell - 1),
        label = tostring(entry.name or key),
        sub = "x" .. tostring(entry.quantity or 0),
        detail = "",
        enabled = legal == true,
        reason = legal == true and nil or self:_refusalText(reason, subs),
      }
    else
      -- Retail clears empty cell windows and paints the disabled
      -- button face: no text rides the row.
      rows[#rows + 1] = {
        id = "bag:" .. tostring(cell - 1),
        label = "",
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
    -- Retail list header (PrintPocketName msg 22-27): the staged
    -- pocket title rides its own bottom-bar window apart from the
    -- cells, so paint reads its lines here instead of the raw pocket
    -- key. Pockets 0-1 print two lines (22+23, 24+25); balls and
    -- battle items print one (26, 27).
    pocketLines = pocketTitleLines(self, native.pocket),
    page = copyValue(native.page) or { current = 1, count = 1 },
    bagPage = "item_list",
    stock = type(native.slots) == "table" and #native.slots or 0,
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
        sub = self:_resolveOr("battle/party/move/pp", "PP") .. " " .. tostring(row.pp) .. "/" .. tostring(row.maxPp),
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
  if not known and self._active == "bag" then
    if id == "page_prev" or id == "page_next" or id == "use" then
      known = view.empty ~= true
    end
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
  self._stagedCursor = nil
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
