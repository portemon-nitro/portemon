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
local BattlePartyPages = require("game.hgss.src.battle.BattlePartyPages")
local MonCache = require("libs.assets.src.MonCache")

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
---@field _partySection table<string, unknown>? borrowed battle manifest party section behind page sprite anchors
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
    pageAccept = type(view) == "table" and view.pageAccept or 0,
    press = type(view) == "table" and view.pagePress ~= nil or false,
    cursorActive = type(view) == "table" and view.cursorActive or nil,
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
  -- A stamped wrapper acceptance voices its DECIDE on the input tick
  -- like the decomp Handle call sites, ahead of the gated transition.
  local afterAccept = type(afterView) == "table" and afterView.pageAccept or 0
  if (type(before.pageAccept) == "number" and before.pageAccept or 0) ~= afterAccept then
    self:_play(DECIDE_SOUND)
    return
  end
  -- The release tick applies the gated transition silently: its
  -- DECIDE already voiced on acceptance, matching WaitButtonAnim.
  local afterPress = type(afterView) == "table" and afterView.pagePress ~= nil or false
  if before.press == true and afterPress == false then
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
  -- The first key press only activates the d-pad cursor (TryActivate
  -- voices SELECT); touch deactivation stays silent like DeactivateCursor.
  local afterCursorActive = type(afterView) == "table" and afterView.cursorActive or nil
  if before.cursorActive ~= true and afterCursorActive == true then
    self:_play(SELECT_SOUND)
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
---@field partySection table<string, unknown>? borrowed battle manifest party section behind page sprite anchors
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
  if opts.partySection ~= nil then
    assert(type(opts.partySection) == "table", "the battle manifest party section arrives as a record")
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
    _partySection = opts.partySection,
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
    partySection = self._partySection,
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
          -- Retail holds silently in SWITCH_NO_CANCEL: cancel is the
          -- screen's own permission, not a battle notice, and the cursor
          -- stays where it was instead of rebuilding the picker.
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
          -- Non-cancellable bag holds silently like the party list:
          -- blocking cancel is the screen's own permission, not a notice.
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

-- Resolves the staged window template boxes for one wrapper page:
-- the manifest party section carries the transcribed AddWindow order
-- behind text paint. Each box keeps its template palette bank so ink
-- resolves through the window's own hardware bank (palette 9 for the
-- mon-menu, move, and button windows, palette 13 for labels, values,
-- and bars). Malformed or missing tables resolve to nil and
-- the page keeps its background, sprites, and cursor without text.
---@param self BattleSubflows barrier under resolution
---@param page string wrapper page under resolution
---@return table<integer, table<string, number>>? template boxes in tile units with their palette banks
local function pageWindowBoxes(self, page)
  local key = page == "mon_menu" and "monMenu"
    or page == "summary" and "summary"
    or page == "moves" and "checkMoves"
    or page == "move_detail" and "moveDetail"
    or nil
  if key == nil then
    return nil
  end
  local section = self._partySection --[[@as table<string, unknown>?]]
  if type(section) ~= "table" then
    return nil
  end
  local windows = section.windows --[[@as table<string, unknown>?]]
  local staged = type(windows) == "table" and windows[key] or nil
  if type(staged) ~= "table" then
    return nil
  end
  local boxes = {} ---@type table<integer, table<string, number>>
  for _, template in
    ipairs(staged --[[@as table<integer, table<string, unknown>>]])
  do
    if
      type(template) ~= "table"
      or type(template.left) ~= "number"
      or type(template.top) ~= "number"
      or type(template.width) ~= "number"
      or type(template.height) ~= "number"
      or type(template.palette) ~= "number"
    then
      return nil
    end
    boxes[#boxes + 1] = {
      left = template.left,
      top = template.top,
      width = template.width,
      height = template.height,
      palette = template.palette,
    }
  end
  return boxes
end

-- Buttons behind one wrapper page in BattlePartyButton order for
-- pressed/disabled faces (DrawPageButtons): prev/next page across
-- mons, the page links, the move tabs, and cancel.
local WRAPPER_BUTTONS = {
  mon_menu = { 7, 8, 10, 6 },
  summary = { 12, 13, 11, 6 },
  moves = { 14, 15, 16, 17, 12, 13, 9, 6 },
  move_detail = { 30, 31, 32, 33, 6 },
}

-- Resolves the tile-unit button rects for one wrapper page from the
-- staged manifest table, keyed by decomp button. Malformed or missing
-- tables resolve to nil and the page paints without faces.
---@param self BattleSubflows barrier under resolution
---@param page string wrapper page under resolution
---@return table<integer, table<string, number>>? button rects by decomp button
local function pageButtonRects(self, page)
  local wanted = WRAPPER_BUTTONS[page]
  if wanted == nil then
    return nil
  end
  local section = self._partySection --[[@as table<string, unknown>?]]
  if type(section) ~= "table" then
    return nil
  end
  local staged = section.buttonRects --[[@as table<integer, table<string, unknown>>?]]
  if type(staged) ~= "table" then
    return nil
  end
  local rects = {} ---@type table<integer, table<string, number>>
  for _, button in ipairs(wanted) do
    local rect = staged[button + 1] --[[@as table<string, unknown>?]]
    if
      type(rect) ~= "table"
      or type(rect.x) ~= "number"
      or type(rect.y) ~= "number"
      or type(rect.w) ~= "number"
      or type(rect.h) ~= "number"
    then
      return nil
    end
    rects[button] = { x = rect.x, y = rect.y, w = rect.w, h = rect.h }
  end
  return rects
end

-- Resolves the d-pad cursor boxes for one wrapper page from the staged
-- manifest table, falling back to the pinned decomp transcription.
---@param self BattleSubflows barrier under resolution
---@param page string wrapper page under resolution
---@return table<integer, table<string, unknown>> cursor boxes in page order
local function pageCursorBoxes(self, page)
  return BattlePartyPages.cursorBoxes(page, self._partySection)
end

-- Counts occupied non-egg roster slots behind prev/next paging faces.
---@param self BattleSubflows barrier under counting
---@return integer occupied non-egg roster slot count
local function multiMonCount(self)
  local roster = self:_openParty()
  local count = 0
  for _, record in ipairs(roster) do
    if type(record) == "table" and type(record.slot) == "number" and record.isEgg ~= true then
      count = count + 1
    end
  end
  return count
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

-- Resolves one battle ability key to its catalog description, nil
-- without a catalog or description so rows without one keep shape.
---@param self BattleSubflows barrier under projection
---@param key string ability identity under lookup
---@return string? catalog ability description, nil when unavailable
local function abilityDescription(self, key)
  local catalog = self._monCatalog
  if catalog ~= nil then
    local lookup = catalog.ability --[[@as fun(self: table<string, unknown>, key: string): table<string, unknown>?]]
    if type(lookup) == "function" then
      local ok, record = pcall(lookup, catalog, key)
      if ok and type(record) == "table" then
        local description = record.description --[[@as string?]]
        if type(description) == "string" and description ~= "" then
          return description
        end
      end
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

-- Resolves one roster record to its retail status word for the status
-- icon (battle_party_menu.c ShowStatusIcon over NARC status sprites):
-- faint, sleep, poison, burn, freeze, or paralysis, nil while healthy
-- so healthy mons place no status sprite.
---@param record table<string, unknown> detached roster record under display
---@return string? retail status word, nil when healthy
local function pageStatusWord(record)
  if (tonumber(record.hp) or 0) <= 0 then
    return "faint"
  end
  local condition = type(record.condition) == "string" and record.condition:lower() or ""
  if condition == "sleep" then
    return "sleep"
  elseif condition == "poison" or condition == "bad-poison" or condition == "toxic" then
    return "poison"
  elseif condition == "burn" or condition == "freeze" or condition == "paralysis" then
    return condition
  end
  return nil
end

-- Resolves one roster record to its mon catalog species facts through
-- the borrowed catalog, nil when unanswerable so callers keep their
-- neutral shape instead of inventing display facts.
---@param self BattleSubflows barrier under projection
---@param record table<string, unknown> detached roster record under display
---@return table<string, unknown>? catalog species facts, nil when unanswerable
local function speciesFacts(self, record)
  local species = record.species
  local catalog = self._monCatalog
  if type(species) ~= "string" or type(catalog) ~= "table" then
    return nil
  end
  local lookup = catalog.species --[[@as fun(self: table<string, unknown>, key: string): table<string, unknown>?]]
  if type(lookup) ~= "function" then
    return nil
  end
  local ok, facts = pcall(lookup, catalog, species)
  if not ok or type(facts) ~= "table" then
    return nil
  end
  return facts
end

local function pageMonTypes(self, record)
  local facts = speciesFacts(self, record)
  if facts == nil then
    return {}
  end
  local types = {} ---@type string[]
  -- Unit fakes stage `types` on the species facts; the real catalog
  -- nests them per form (`forms[form].types`, see MonCatalog:form).
  local staged = facts.types
  if type(staged) ~= "table" then
    local forms = facts.forms
    if type(forms) == "table" then
      local formIndex = tonumber(record.form) or 0
      local formFacts = forms[formIndex] or forms[0]
      if type(formFacts) == "table" then
        staged = formFacts.types
      end
    end
  end
  if type(staged) == "table" then
    local seen = {} ---@type table<string, boolean>
    for _, key in ipairs(staged) do
      -- Retail ShowMonTypeIcons shows the second icon only when the
      -- types differ: a duplicated entry paints once, never twice.
      if type(key) == "string" and key ~= "" and seen[key] ~= true then
        seen[key] = true
        types[#types + 1] = key
      end
    end
  end
  return types
end

-- Names whether one roster record carries the female gender behind its
-- staged symbol, so paint selects the retail female ink (3,4,0) instead
-- of the male ink (7,8,0) without sniffing the symbol text.
---@param record table<string, unknown> detached roster record under display
---@return boolean female true while the record is female
local function monGenderFemale(record)
  return record.gender == "female"
end

-- Resolves one roster record to its experience-bar fill (DrawExpBar):
-- the experience earned toward the next level over the growth span,
-- empty at the level cap or without answerable growth facts.
---@param self BattleSubflows barrier under projection
---@param record table<string, unknown> detached roster record under display
---@return number current experience earned toward the next level
---@return number max experience span of the current level
local function expBarFill(self, record)
  local level = tonumber(record.level) or 0
  local experience = tonumber(record.experience)
  if level >= 100 or experience == nil then
    return 0, 0
  end
  local facts = speciesFacts(self, record)
  local curveKey = type(facts) == "table" and facts.growthCurve or nil
  local catalog = self._monCatalog
  local curveOf = type(catalog) == "table" and catalog.growthCurve or nil
  if type(curveKey) ~= "string" or type(curveOf) ~= "function" then
    return 0, 0
  end
  local okCurve, curve = pcall(curveOf, catalog, curveKey)
  if not okCurve or type(curve) ~= "table" then
    return 0, 0
  end
  local Experience = require("libs.mons.src.gen4.Experience")
  local okBase, base = pcall(Experience.expFor, curve, level)
  local okNext, following = pcall(Experience.expFor, curve, level + 1)
  if not okBase or not okNext or type(base) ~= "number" or type(following) ~= "number" then
    return 0, 0
  end
  local current = experience - base
  local span = following - base
  if span <= 0 or current <= 0 then
    return 0, 0
  end
  if current > span then
    current = span
  end
  return current, span
end

-- Resolves one roster record to its canonical mon icon selector through
-- the shared MonCache spelling, nil without a species so icon-less
-- records place no icon.
---@param record table<string, unknown> detached roster record under display
---@return string? canonical mon icon selector, nil without a species
local function pageIconKey(record)
  if type(record.species) ~= "string" then
    return nil
  end
  local form = tonumber(record.form) or 0
  return MonCache.iconSelector(record.species, form --[[@as integer]], record.isEgg == true)
end

---@class BattlePageSpriteAnchors
---@field monIcon { x: number, y: number } staged mon icon anchor
---@field statusIcon { x: number, y: number } staged status icon anchor
---@field monMenuIcon { x: number, y: number } staged mon-menu icon anchor
---@field summaryHeldItem { x: number, y: number } staged summary held-item anchor
---@field heldItemDelta { x: number, y: number } staged held-item offset from the mon icon
---@field capsuleDelta { x: number, y: number } staged capsule offset from the mon icon
---@field moveDetailMoveIcon { x: number, y: number } staged move-detail move icon anchor
---@field categoryIcon { x: number, y: number } staged move category icon anchor
---@field summaryTypes table<integer, { x: number, y: number }> staged summary mon-type anchors
---@field checkMovesTypes table<integer, { x: number, y: number }> staged check-moves mon-type anchors
---@field moveDetailTypes table<integer, { x: number, y: number }> staged move-detail mon-type anchors
---@field checkMovesMoves table<integer, { x: number, y: number }> staged check-moves move icon anchors

-- Pinned retail page sprite anchors (battle_party_menu.c
-- ShowMonMenuSprites/ShowSummarySprites/ShowCheckMovesSprites/
-- ShowMoveDetailSprites: mon icon (24,12), status (198,20), mon-menu
-- icon (128,72), mon types (130,16)/(164,16), the held item at the
-- mon-icon delta (8,8) plus the summary anchor (20,132), the capsule at
-- the mon-icon delta (16,8), move-detail move icon (136,48), category
-- icon (24,88), and the gBattlePartyCheckMovesMoveIconPos columns):
-- the manifest path is preferred, this table is the decomp-verified
-- fallback for old caches that predate staged sprite positions, and a
-- unit test pins them equal.
local FALLBACK_POSITIONS = {
  monIcon = { x = 24, y = 12 },
  statusIcon = { x = 198, y = 20 },
  monMenuIcon = { x = 128, y = 72 },
  summaryHeldItem = { x = 20, y = 132 },
  heldItemDelta = { x = 8, y = 8 },
  capsuleDelta = { x = 16, y = 8 },
  moveDetailMoveIcon = { x = 136, y = 48 },
  categoryIcon = { x = 24, y = 88 },
  summaryTypes = { { x = 130, y = 16 }, { x = 164, y = 16 } },
  checkMovesTypes = { { x = 130, y = 16 }, { x = 164, y = 16 } },
  moveDetailTypes = { { x = 130, y = 16 }, { x = 164, y = 16 } },
  checkMovesMoves = { { x = 24, y = 80 }, { x = 152, y = 80 }, { x = 24, y = 128 }, { x = 152, y = 128 } },
} --[[@as BattlePageSpriteAnchors]]

---@param value unknown candidate anchor under validation
---@return boolean valid true while the value carries numeric x and y
local function isAnchor(value)
  return type(value) == "table" and type(value.x) == "number" and type(value.y) == "number"
end

---@param value unknown candidate anchor list under validation
---@param needed integer consumed anchor count under validation
---@return table<integer, { x: number, y: number }>? validated anchor copies, nil when short or malformed
local function anchorList(value, needed)
  if type(value) ~= "table" or #value < needed then
    return nil
  end
  local anchors = {} ---@type table<integer, { x: number, y: number }>
  for index = 1, needed do
    local anchor = value[index] --[[@as { x: number, y: number }?]]
    if not isAnchor(anchor) then
      return nil
    end
    assert(anchor ~= nil, "anchors validate before staging")
    anchors[index] = { x = anchor.x, y = anchor.y }
  end
  return anchors
end

-- Resolves the page sprite anchors from a battle manifest party section:
-- the staged spritePositions table with its per-page mon-type and
-- check-moves move lists plus the fixed icon anchors, copied so the
-- projection never mutates staged cache state. Anything absent or
-- malformed (old caches, partial transcriptions) resolves to nil and the
-- projection keeps its pinned retail fallback instead of inventing geometry.
---@param partySection table<string, unknown>? battle manifest party section under resolution
---@return BattlePageSpriteAnchors? validated page sprite positions, nil while unstaged
local function resolvePositions(partySection)
  if type(partySection) ~= "table" then
    return nil
  end
  local staged = partySection.spritePositions --[[@as table<string, unknown>?]]
  if type(staged) ~= "table" then
    return nil
  end
  local fixed = staged.fixed --[[@as table<string, unknown>?]]
  if type(fixed) ~= "table" then
    return nil
  end
  local anchors = {} ---@type table<string, unknown>
  for _, key in ipairs({
    "monIcon",
    "statusIcon",
    "monMenuIcon",
    "summaryHeldItem",
    "heldItemDelta",
    "capsuleDelta",
    "moveDetailMoveIcon",
    "categoryIcon",
  }) do
    local anchor = fixed[key] --[[@as { x: number, y: number }?]]
    if not isAnchor(anchor) then
      return nil
    end
    assert(anchor ~= nil, "anchors validate before staging")
    anchors[key] = { x = anchor.x, y = anchor.y }
  end
  local lists = {
    summaryTypes = 2,
    checkMovesTypes = 2,
    moveDetailTypes = 2,
    checkMovesMoves = 4,
  }
  for key, needed in pairs(lists) do
    local validated = anchorList(staged[key], needed)
    if validated == nil then
      return nil
    end
    anchors[key] = validated
  end
  return anchors --[[@as BattlePageSpriteAnchors]]
end

-- Resolves the page sprite anchors behind one projection: the staged
-- manifest positions while present, the pinned retail fallback otherwise.
---@param self BattleSubflows barrier under projection
---@return BattlePageSpriteAnchors page sprite positions behind the projection
local function pagePositions(self)
  return resolvePositions(self._partySection) or FALLBACK_POSITIONS
end

-- Shared sprite placements above the summary/move wrapper pages
-- (battle_party_menu.c ShowSummarySprites/ShowCheckMovesSprites/
-- ShowMoveDetailSprites): the staged mon icon, the status icon while
-- ailed, the page's mon type icons, and the held-item icon at the
-- mon-icon delta. Only the summary page shows the second held-item
-- icon at the summary anchor. Unanswerable facts place nothing;
-- missing drawables draw nothing at paint time.
---@param self BattleSubflows barrier under projection
---@param record table<string, unknown> detached roster record under display
---@param positions BattlePageSpriteAnchors page sprite positions under projection
---@param typeAnchors table<integer, { x: number, y: number }> staged mon-type anchors behind the page
---@param summaryAnchor boolean true while the page shows the summary held-item anchor
---@return table<integer, table<string, unknown>> shared sprite placements
local function pageBaseSprites(self, record, positions, typeAnchors, summaryAnchor)
  local sprites = {} ---@type table<integer, table<string, unknown>>
  local iconKey = pageIconKey(record)
  if iconKey ~= nil then
    sprites[#sprites + 1] = { kind = "icon", key = iconKey, x = positions.monIcon.x, y = positions.monIcon.y }
  end
  local status = pageStatusWord(record)
  if status ~= nil then
    sprites[#sprites + 1] = { kind = "status", key = status, x = positions.statusIcon.x, y = positions.statusIcon.y }
  end
  for index, key in ipairs(pageMonTypes(self, record)) do
    local anchor = typeAnchors[index]
    if anchor == nil then
      break
    end
    sprites[#sprites + 1] = { kind = "mon-type", key = key, x = anchor.x, y = anchor.y }
  end
  local held = type(record.heldItem) == "string" and record.heldItem or nil
  if held ~= nil and held ~= "" and held ~= "NONE" then
    sprites[#sprites + 1] = {
      kind = "held-item",
      key = held,
      x = positions.monIcon.x + positions.heldItemDelta.x,
      y = positions.monIcon.y + positions.heldItemDelta.y,
    }
    if summaryAnchor == true then
      sprites[#sprites + 1] = {
        kind = "held-item",
        key = held,
        x = positions.summaryHeldItem.x,
        y = positions.summaryHeldItem.y,
      }
    end
  end
  local capsule = record.capsule
  if type(capsule) == "table" and tonumber(capsule.id) ~= nil and tonumber(capsule.id) ~= 0 then
    sprites[#sprites + 1] = {
      kind = "capsule",
      key = tostring(capsule.id),
      x = positions.monIcon.x + positions.capsuleDelta.x,
      y = positions.monIcon.y + positions.capsuleDelta.y,
    }
  end
  return sprites
end

-- Merges one held move entry with its mon catalog facts for the page
-- model: roster text wins where the roster carries curated display
-- facts, the borrowed catalog fills live gaps (live entries carry
-- only their move key, PP, and PP Ups), and anything unanswerable
-- keeps its neutral default instead of inventing display text.
---@param self BattleSubflows barrier under projection
---@param entry table<string, unknown> detached held move entry under merging
---@return table<string, unknown> merged move display facts
local function pageMoveFacts(self, entry)
  local key = nil
  if type(entry.move) == "string" and entry.move ~= "" then
    key = entry.move
  elseif type(entry.key) == "string" and entry.key ~= "" then
    key = entry.key
  end
  local facts = {
    key = key,
    name = type(entry.name) == "string" and entry.name ~= "" and entry.name or key or "Unknown",
    type = type(entry.type) == "string" and entry.type or nil,
    description = type(entry.description) == "string" and entry.description or nil,
    power = tonumber(entry.power),
    accuracy = tonumber(entry.accuracy),
    category = type(entry.category) == "string" and entry.category or nil,
    pp = tonumber(entry.pp) or 0,
    maxPp = tonumber(entry.maxPp),
  } --[[@as table<string, unknown>]]
  local catalog = self._monCatalog
  if type(key) == "string" and type(catalog) == "table" then
    local lookup = catalog.move --[[@as fun(self: table<string, unknown>, key: string): table<string, unknown>?]]
    if type(lookup) == "function" then
      local ok, record = pcall(lookup, catalog, key)
      if ok and type(record) == "table" then
        if type(record.name) == "string" and record.name ~= "" then
          facts.name = record.name
        end
        if facts.type == nil and type(record.moveType) == "string" then
          facts.type = record.moveType
        end
        if facts.description == nil and type(record.description) == "string" and record.description ~= "" then
          facts.description = record.description
        end
        if facts.power == nil and type(record.power) == "number" then
          facts.power = record.power
        end
        if facts.accuracy == nil and type(record.accuracy) == "number" then
          facts.accuracy = record.accuracy
        end
        if facts.category == nil and type(record.category) == "string" then
          facts.category = record.category
        end
        -- Retail max PP from the catalog base and PP Ups
        -- (moveFacts), falling back to current PP without a catalog.
        if facts.maxPp == nil and type(record.basePp) == "number" then
          local ups = tonumber(entry.ppUps) or 0
          facts.maxPp = record.basePp + math.floor(record.basePp * ups / 5)
        end
      end
    end
  end
  if facts.maxPp == nil then
    facts.maxPp = facts.pp
  end
  return facts
end

-- Projects the retail battle mon-menu page (battle_party_menu.c page 1,
-- PrintMonMenuPage): the centered mon name with its gender symbol, the
-- SHIFT/SUMMARY/CHECK MOVES buttons, and the cancel box. Focus follows
-- the native menu index the controller owns; the page seals nothing
-- itself (SHIFT seals its kernel fragment through the list result).
-- Eggs blank the SUMMARY/CHECK MOVES windows and disable their faces.
---@param self BattleSubflows barrier under projection
---@param shell table<string, unknown> detached child view under filling
---@param native table<string, unknown> native party status under projection
---@param kind string projected child kind under mapping
---@return table<string, unknown> detached mon-menu child view
local function projectMonMenu(self, shell, native, kind)
  local entries = native.menu --[[@as table<integer, table<string, unknown>>]]
  local index = tonumber(native.menuIndex)
  local focusedKind = nil
  if index ~= nil and type(entries) == "table" and type(entries[index]) == "table" then
    focusedKind = entries[index].kind
  end
  -- Decomp Handle order behind the focused entry: SHIFT, SUMMARY,
  -- CHECK MOVES, cancel.
  local cursorMap = { switch = 0, summary = 1, check_moves = 2, quit = 3 } ---@type table<string, integer>
  local cursor = cursorMap[focusedKind]
  if cursor == nil then
    cursor = 0
  end
  local focusMap = { switch = "switch", summary = "summary", check_moves = "moves", quit = "back" }
  local slot = tonumber(native.menuSlot) or 0 --[[@as integer]]
  local record = pageRecord(self, slot) or {}
  local isEgg = record.isEgg == true
  local positions = pagePositions(self)
  shell.pageSlot = slot
  shell.rows = nil
  shell.pageCursor = cursor
  -- The cursor rides the focused box like every wrapper page: touch
  -- deactivation has already confirmed by the time paint runs, so the
  -- retained focus stays visible.
  shell.cursorActive = true
  shell.windowBoxes = pageWindowBoxes(self, "mon_menu")
  shell.pageButtonRects = pageButtonRects(self, "mon_menu")
  shell.pageCursorBoxes = pageCursorBoxes(self, "mon_menu")
  shell.pageIsEgg = isEgg
  -- The armed native press dips its button behind the gated dispatch:
  -- the phases map onto the retail PRESS/HOLD frames.
  local press = type(native.menuPress) == "table" and native.menuPress or nil
  if type(press) == "table" then
    local pressed = type(press.index) == "number" and type(entries) == "table" and entries[press.index] or nil
    local pressedKind = type(pressed) == "table" and pressed.kind or nil
    local button = cursorMap[pressedKind]
    local frame = press.phase == "selected" and 2 or 1
    if button ~= nil then
      shell.pagePress = { button = button, phase = frame }
    else
      shell.pagePress = nil
    end
  else
    shell.pagePress = nil
  end
  -- The child stamps its accept sequence when the press arms, so the
  -- barrier voices DECIDE on acceptance like the decomp Handle call
  -- sites; the release tick stays silent behind the press guard.
  shell.pageAccept = tonumber(native.menuAccept) or 0
  shell.focusId = focusMap[focusedKind] or "switch"
  -- Hit regions in decomp hitbox order with the shared cancel rect
  -- so pointer taps resolve through the same geometry paint uses.
  local regions = {} ---@type table<integer, table<string, unknown>>
  for pos, box in ipairs(BattlePartyPages.hitboxes("mon_menu", self._partySection)) do
    regions[#regions + 1] = {
      id = BattlePartyPages.inputIds("mon_menu")[pos],
      x = box.left,
      y = box.top,
      w = box.right - box.left,
      h = box.bottom - box.top,
    }
  end
  local cancel = BattlePartyPages.CANCEL_RECT
  regions[#regions + 1] =
    { id = "back", x = cancel.left, y = cancel.top, w = cancel.right - cancel.left, h = cancel.bottom - cancel.top }
  shell.pageRegions = regions
  -- Window text roles in PrintMonMenuPage order: the centered name
  -- with its gender symbol, then the three button labels. Eggs carry
  -- no SUMMARY/CHECK MOVES text; the disabled faces paint the intent.
  local windows = {} ---@type table<integer, table<string, unknown>>
  windows[#windows + 1] = { role = "mon-name", text = monRowLabel(self, record, slot) }
  windows[#windows + 1] = {
    role = "mon-gender",
    text = monGenderSub(self, record) or "",
    female = monGenderFemale(record),
  }
  windows[#windows + 1] = { role = "shift-button", text = self:_resolveOr("battle/party/button/shift", "SHIFT") }
  if isEgg then
    windows[#windows + 1] = { role = "summary-button", text = "" }
    windows[#windows + 1] = { role = "moves-button", text = "" }
  else
    windows[#windows + 1] =
      { role = "summary-button", text = self:_resolveOr("battle/party/button/summary", "SUMMARY") }
    windows[#windows + 1] =
      { role = "moves-button", text = self:_resolveOr("battle/party/button/check-moves", "CHECK MOVES") }
  end
  -- The retail refusal message (CanSwitchToSelectedMon) prints over
  -- the mon menu through the message window until acknowledged.
  if type(native.message) == "string" and native.message ~= "" then
    windows[#windows + 1] = { role = "message", text = native.message }
  end
  shell.pageWindows = windows
  -- ShowMonMenuSprites anchors: the mon icon, the held item at the
  -- mon-icon delta, and the capsule at the capsule delta. No
  -- status/type icons ride this page.
  local sprites = {} ---@type table<integer, table<string, unknown>>
  local iconKey = pageIconKey(record)
  if iconKey ~= nil then
    sprites[#sprites + 1] = { kind = "icon", key = iconKey, x = positions.monMenuIcon.x, y = positions.monMenuIcon.y }
  end
  local held = type(record.heldItem) == "string" and record.heldItem or nil
  if held ~= nil and held ~= "" and held ~= "NONE" then
    sprites[#sprites + 1] = {
      kind = "held-item",
      key = held,
      x = positions.monMenuIcon.x + positions.heldItemDelta.x,
      y = positions.monMenuIcon.y + positions.heldItemDelta.y,
    }
  end
  local capsule = record.capsule
  if type(capsule) == "table" and tonumber(capsule.id) ~= nil and tonumber(capsule.id) ~= 0 then
    sprites[#sprites + 1] = {
      kind = "capsule",
      key = tostring(capsule.id),
      x = positions.monMenuIcon.x + positions.capsuleDelta.x,
      y = positions.monMenuIcon.y + positions.capsuleDelta.y,
    }
  end
  shell.pageSprites = sprites
  shell.partyPage = "mon_menu"
  if kind == "target" then
    shell.stagedItem = self._stagedItem
  end
  return shell
end

-- Projects the retail battle summary/check-moves/move-detail pages
-- (battle_party_menu.c pages 2-4) over the detached roster: the retail
-- page model carries the page enum, slot, selected move, window text
-- roles in Print* order with staged msg 0006 text, and sprite placements
-- above. Pages project no invented rows: paint and taps read the page
-- model, and only the list SHIFT seals its kernel fragment.
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
  local positions = pagePositions(self)
  local hp = tonumber(record.hp) or 0
  local maxHp = tonumber(record.maxHp) or 0
  shell.pageSlot = slot
  shell.rows = nil
  -- The numeric cursor, its active flag, and the press dip ride the
  -- native page status: focus, sounds, and paint resolve through the
  -- decomp cursor boxes and button animation behind them.
  local cursor = tonumber(native.pageCursor) or 0
  shell.pageCursor = cursor
  shell.cursorActive = native.cursorActive == true
  shell.pagePress = type(native.pagePress) == "table" and native.pagePress or nil
  -- Accepted wrapper inputs stamp their sequence behind the barrier
  -- DECIDE beat, matching the decomp Handle call sites that voice on
  -- acceptance instead of on the gated transition.
  shell.pageAccept = tonumber(native.pageAccept) or 0
  shell.windowBoxes = pageWindowBoxes(self, page)
  -- Button rects behind pressed/disabled faces and cursor boxes behind
  -- the d-pad cursor: staged manifest geometry, absent without it.
  shell.pageButtonRects = pageButtonRects(self, page)
  shell.pageCursorBoxes = pageCursorBoxes(self, page)
  -- Prev/next paging disables to the single-mon face while only one
  -- occupied non-egg mon exists (HasMultipleNonEggMons).
  shell.pageMultiMon = multiMonCount(self) > 1
  -- Stable focus identity behind the numeric cursor for tick sounds
  -- and hit regions; the raw cursor stays authoritative.
  local ids = BattlePartyPages.inputIds(page)
  shell.focusId = ids[cursor + 1] or (type(native.pageFocus) == "string" and native.pageFocus or nil)
  -- Hit regions in decomp hitbox order with the shared cancel rect
  -- so pointer taps resolve through the same geometry paint uses.
  local regions = {} ---@type table<integer, table<string, unknown>>
  for index, box in ipairs(BattlePartyPages.hitboxes(page, self._partySection)) do
    regions[#regions + 1] = {
      id = ids[index],
      x = box.left,
      y = box.top,
      w = box.right - box.left,
      h = box.bottom - box.top,
    }
  end
  local cancel = BattlePartyPages.CANCEL_RECT
  regions[#regions + 1] =
    { id = "back", x = cancel.left, y = cancel.top, w = cancel.right - cancel.left, h = cancel.bottom - cancel.top }
  shell.pageRegions = regions
  if page == "summary" then
    -- Window text roles in PrintSummaryPage order: mon name and gender,
    -- level and remaining experience, HP counts and bar, the five
    -- battle stats, ability name and description, held item, and the
    -- check-moves button.
    local level = tonumber(record.level) or 0
    local nextExp = tonumber(record.nextExp) or 0
    local windows = {} ---@type table<integer, table<string, unknown>>
    windows[#windows + 1] = { role = "mon-name", text = monRowLabel(self, record, slot) }
    windows[#windows + 1] = {
      role = "mon-gender",
      text = monGenderSub(self, record) or "",
      female = monGenderFemale(record),
    }
    windows[#windows + 1] = { role = "level-label", text = self:_resolveOr("battle/party/stat/level", "Lv.") }
    windows[#windows + 1] = {
      role = "level-value",
      text = self:_resolveOr("battle/party/stat/level-value", tostring(level), { tostring(level) }),
    }
    windows[#windows + 1] = { role = "exp-label", text = self:_resolveOr("battle/party/stat/exp", "NEXT LV") }
    windows[#windows + 1] = {
      role = "exp-value",
      text = self:_resolveOr("battle/party/stat/exp-value", tostring(nextExp), { tostring(nextExp) }),
    }
    -- The experience bar fills behind the staged track (DrawExpBar):
    -- the experience earned toward the next level over its span,
    -- empty at the level cap or without answerable growth facts.
    local expCurrent, expSpan = expBarFill(self, record)
    windows[#windows + 1] = { role = "exp-bar", current = expCurrent, max = expSpan }
    windows[#windows + 1] = { role = "hp-label", text = self:_resolveOr("battle/party/stat/hp", "HP") }
    -- HP prints in three centered parts (PrintHPStat): the current
    -- value right-aligned to the middle, the slash centered, and the
    -- maximum left of it.
    windows[#windows + 1] = {
      role = "hp-value",
      current = self:_resolveOr("battle/party/stat/hp-current", tostring(hp), { tostring(hp) }),
      slash = self:_resolveOr("battle/party/stat/hp-slash", "/"),
      max = self:_resolveOr("battle/party/stat/hp-max", tostring(maxHp), { tostring(maxHp) }),
      text = tostring(hp) .. "/" .. tostring(maxHp),
    }
    windows[#windows + 1] = { role = "hp-bar", current = hp, max = maxHp }
    -- The five battle stats print in retail print order
    -- (PrintAttack/Defense/Speed/SpAttack/SpDefense).
    local stats = {
      { key = "attack", field = "attack", fallback = "ATTACK" },
      { key = "defense", field = "defense", fallback = "DEFENSE" },
      { key = "speed", field = "speed", fallback = "SPEED" },
      { key = "sp-attack", field = "specialAttack", fallback = "SP. ATK" },
      { key = "sp-defense", field = "specialDefense", fallback = "SP. DEF" },
    }
    for _, stat in ipairs(stats) do
      local value = tonumber(record[stat.field]) or 0
      windows[#windows + 1] =
        { role = stat.key .. "-label", text = self:_resolveOr("battle/party/stat/" .. stat.key, stat.fallback) }
      windows[#windows + 1] = {
        role = stat.key .. "-value",
        text = self:_resolveOr("battle/party/stat/" .. stat.key .. "-value", tostring(value), { tostring(value) }),
      }
    end
    local ability = type(record.ability) == "string" and record.ability or nil
    local abilityLabel = ""
    if ability ~= nil and ability ~= "" then
      local display = abilityDisplayName(self, ability)
      abilityLabel = self:_resolveOr("battle/party/ability/name", display, { display })
    end
    windows[#windows + 1] = { role = "ability-name", text = abilityLabel }
    local abilityDesc = ""
    if ability ~= nil and ability ~= "" then
      abilityDesc = abilityDescription(self, ability) or ""
    end
    windows[#windows + 1] = { role = "ability-desc", text = abilityDesc }
    local held = type(record.heldItem) == "string" and record.heldItem or nil
    local itemLabel = self:_resolveOr("battle/party/item/none", "No item held")
    if held ~= nil and held ~= "" and held ~= "NONE" then
      local display = itemDisplayName(self, held)
      itemLabel = self:_resolveOr("battle/party/item/name", display, { display })
    end
    windows[#windows + 1] = { role = "held-item", text = itemLabel }
    windows[#windows + 1] =
      { role = "button", text = self:_resolveOr("battle/party/button/check-moves", "CHECK MOVES") }
    shell.pageWindows = windows
    shell.pageSprites = pageBaseSprites(self, record, positions, positions.summaryTypes, true)
    shell.partyPage = "summary"
  elseif page == "moves" then
    -- Window text roles in PrintCheckMovesPage order: the mon name
    -- with its gender symbol, the four move names with their PP
    -- windows, then the summary button. Retail prints every slot
    -- (MOVE_NONE breaks only the tap); empty slots carry no text
    -- and place no type icon.
    local moves = type(record.moves) == "table" and record.moves or {}
    local windows = {} ---@type table<integer, table<string, unknown>>
    windows[#windows + 1] = { role = "mon-name", text = monRowLabel(self, record, slot) }
    windows[#windows + 1] = {
      role = "mon-gender",
      text = monGenderSub(self, record) or "",
      female = monGenderFemale(record),
    }
    local sprites = pageBaseSprites(self, record, positions, positions.checkMovesTypes, false)
    for moveSlot = 0, 3 do
      local entry = moves[moveSlot + 1]
      if type(entry) == "table" and (entry.move ~= nil or entry.key ~= nil) then
        local facts = pageMoveFacts(self, entry)
        local name = tostring(facts.name)
        windows[#windows + 1] =
          { role = "move-name:" .. tostring(moveSlot), text = self:_resolveOr(moveNameKey(moveSlot), name, { name }) }
        -- Move PP prints in positioned parts (PrintMoveListPP): the PP
        -- label, the current value right-aligned, the slash, and the
        -- maximum, instead of one stacked string.
        windows[#windows + 1] = {
          role = "move-pp:" .. tostring(moveSlot),
          label = self:_resolveOr("battle/party/move/pp", "PP"),
          current = self:_resolveOr("battle/party/move/pp-current", tostring(facts.pp), { tostring(facts.pp) }),
          slash = self:_resolveOr("battle/party/move/pp-slash", "/"),
          max = self:_resolveOr("battle/party/move/pp-max", tostring(facts.maxPp), { tostring(facts.maxPp) }),
          text = tostring(facts.pp) .. "/" .. tostring(facts.maxPp),
          currentCount = facts.pp,
          maxCount = facts.maxPp,
        }
        if type(facts.type) == "string" and facts.type ~= "" then
          local anchor = positions.checkMovesMoves[moveSlot + 1]
          sprites[#sprites + 1] = { kind = "move-type", key = facts.type, x = anchor.x, y = anchor.y }
        end
      else
        windows[#windows + 1] = { role = "move-name:" .. tostring(moveSlot), text = "" }
      end
    end
    windows[#windows + 1] = { role = "button", text = self:_resolveOr("battle/party/button/summary", "SUMMARY") }
    shell.pageWindows = windows
    shell.pageSprites = sprites
    shell.partyPage = "moves"
  else
    -- Retail detail content follows context->selectedMove, not the
    -- cursor: hovering cancel keeps showing the selected move.
    local moveSlot = math.floor(tonumber(native.pageMove) or cursor)
    if moveSlot < 0 or moveSlot > 3 then
      moveSlot = 0
    end
    local moves = type(record.moves) == "table" and record.moves or {}
    local entry = moves[moveSlot + 1]
    local facts = type(entry) == "table" and pageMoveFacts(self, entry) or { name = "Unknown", pp = 0, maxPp = 0 }
    local moveName = tostring(facts.name)
    -- Window text roles in PrintMoveDetailPage order: the move name,
    -- power, accuracy, category, description, and PP parts.
    local windows = {} ---@type table<integer, table<string, unknown>>
    windows[#windows + 1] = { role = "mon-name", text = monRowLabel(self, record, slot) }
    windows[#windows + 1] = {
      role = "mon-gender",
      text = monGenderSub(self, record) or "",
      female = monGenderFemale(record),
    }
    windows[#windows + 1] = { role = "pp-label", text = self:_resolveOr("battle/party/move/pp-label", "PP") }
    windows[#windows + 1] =
      { role = "move-name", text = self:_resolveOr(moveNameKey(moveSlot), moveName, { moveName }) }
    windows[#windows + 1] =
      { role = "accuracy-label", text = self:_resolveOr("battle/party/move/accuracy", "ACCURACY") }
    local powerText = self:_resolveOr("battle/party/move/no-value", "---")
    if facts.power ~= nil and facts.power > 1 then
      powerText = self:_resolveOr("battle/party/move/power-value", tostring(facts.power), { tostring(facts.power) })
    end
    windows[#windows + 1] = { role = "power-value", text = powerText }
    windows[#windows + 1] =
      { role = "category-label", text = self:_resolveOr("battle/party/move/category", "CATEGORY") }
    local accuracyText = self:_resolveOr("battle/party/move/no-value", "---")
    if facts.accuracy ~= nil and facts.accuracy > 0 then
      accuracyText =
        self:_resolveOr("battle/party/move/accuracy-value", tostring(facts.accuracy), { tostring(facts.accuracy) })
    end
    windows[#windows + 1] = { role = "accuracy-value", text = accuracyText }
    windows[#windows + 1] = { role = "power-label", text = self:_resolveOr("battle/party/move/power", "POWER") }
    local category = facts.category
    local categoryKey, categoryFallback
    if category == "physical" then
      categoryKey, categoryFallback = "battle/party/move/category-physical", "PHYSICAL"
    elseif category == "special" then
      categoryKey, categoryFallback = "battle/party/move/category-special", "SPECIAL"
    elseif category == "status" then
      categoryKey, categoryFallback = "battle/party/move/category-status", "STATUS"
    end
    windows[#windows + 1] =
      { role = "category-value", text = categoryKey ~= nil and self:_resolveOr(categoryKey, categoryFallback) or "" }
    -- Retail move detail prints the move description between the
    -- category and the PP (PrintMoveDescription, msg 0749). Windows
    -- without a description carry no text so synthetic rosters without
    -- a catalog keep their shape.
    windows[#windows + 1] =
      { role = "move-desc", text = type(facts.description) == "string" and facts.description or "" }
    windows[#windows + 1] = {
      role = "pp-value",
      current = self:_resolveOr("battle/party/move/pp-current", tostring(facts.pp), { tostring(facts.pp) }),
      slash = self:_resolveOr("battle/party/move/pp-slash", "/"),
      max = self:_resolveOr("battle/party/move/pp-max", tostring(facts.maxPp), { tostring(facts.maxPp) }),
      text = tostring(facts.pp) .. "/" .. tostring(facts.maxPp),
      currentCount = facts.pp,
      maxCount = facts.maxPp,
    }
    shell.pageWindows = windows
    local sprites = pageBaseSprites(self, record, positions, positions.moveDetailTypes, false)
    if type(facts.type) == "string" and facts.type ~= "" then
      sprites[#sprites + 1] =
        { kind = "move-type", key = facts.type, x = positions.moveDetailMoveIcon.x, y = positions.moveDetailMoveIcon.y }
    end
    if type(category) == "string" and category ~= "" then
      sprites[#sprites + 1] =
        { kind = "category", key = category, x = positions.categoryIcon.x, y = positions.categoryIcon.y }
    end
    shell.pageSprites = sprites
    shell.pageMove = moveSlot
    shell.partyPage = "move_detail"
  end
  if kind == "target" then
    shell.stagedItem = self._stagedItem
  end
  return shell
end

-- Projects the native party/target roster for paint and hit
-- regions: the native renderer paints the roster through the staged
-- layout, so the barrier projects no invented rows. Focus follows the
-- native cursor node; only kernel-projected fragments seal, anything
-- else names its refusal through the native controller.
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
    rows = nil,
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
  -- Retail SHIFT refusals show their CanSwitch message over the mon
  -- menu and stay there: the native controller parks in "message" with
  -- its menu retained, so the barrier keeps projecting mon-menu while
  -- the message is up instead of dropping to the list.
  if (native.state == "context" or native.state == "message") and type(native.menu) == "table" then
    return projectMonMenu(self, shell, native, kind)
  end
  shell.partyPage = "list"
  local cursor = native.cursorNode
  if type(cursor) == "number" then
    shell.focusId = "party:" .. tostring(cursor)
  elseif cursor == "cancel" then
    shell.focusId = "back"
  end
  shell.rows = nil
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
  -- Retail Restore PP carries a cancel button back to the party list
  -- (battle_party_menu.c HandleRestorePPInput case 4): taps need the
  -- same back row keyboard B already owns.
  view.rows[#view.rows + 1] = { id = "back", label = "Back", detail = "", enabled = true }
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
      -- Retail learn rows print PP like the move list
      -- (PrintLearnMovePage via PrintMoveListPP).
      local fact = facts[index] --[[@as table<string, unknown>]]
      local pp = tonumber(fact.pp)
      local maxPp = tonumber(fact.maxPp)
      if pp ~= nil then
        if maxPp == nil then
          maxPp = pp
        end
        row.sub = self:_resolveOr("battle/party/move/pp", "PP") .. " " .. tostring(pp) .. "/" .. tostring(maxPp)
      end
    end
    rows[#rows + 1] = row
  end
  rows[#rows + 1] = { id = "learn:decline", label = "Decline", detail = "Keep moves", enabled = true }
  local focusId = nil
  local nativeNotice = nil
  if self._composed ~= nil then
    local ok, native = pcall(self._composed.draw, self._composed, nil)
    if ok and type(native) == "table" and native.open ~= false then
      local moveSlot = native.moveSlot
      if type(moveSlot) == "number" and moveSlot >= 0 and moveSlot <= 3 then
        focusId = "learn:" .. tostring(moveSlot)
      elseif moveSlot == 4 then
        focusId = "learn:decline"
      end
      -- Retail HM guard surfaces its msg 60 text over the list: the
      -- native picker refuses with its protected notice, the barrier
      -- maps that reason to the staged party key.
      local notice = native.notice
      if type(notice) == "table" and notice.reason == "hm" then
        nativeNotice = self:_resolveOr("battle/party/message/hm-forget", "HM moves can’t be forgotten now.")
      end
    end
  end
  local view = {
    kind = "learn",
    purpose = self._purpose,
    interactive = true,
    notice = self._notice or nativeNotice,
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
  -- Wrapper pages validate against the decomp input order: every
  -- stable control identity arms while foreign identities refuse.
  -- Taps on empty move slots arm but stay on the list like retail
  -- MOVE_NONE breaks.
  local wrapper = type(view.partyPage) == "string" and view.partyPage or nil
  if wrapper == "mon_menu" or wrapper == "summary" or wrapper == "moves" or wrapper == "move_detail" then
    for _, knownId in ipairs(BattlePartyPages.inputIds(wrapper)) do
      if knownId == id then
        self._queued[#self._queued + 1] = { type = "tap", id = id }
        return true
      end
    end
    return false
  end
  -- The native renderer paints the roster through the staged layout,
  -- so list taps validate as slot identities the composed child
  -- expands through the same native geometry; unknown ids refuse.
  -- Opening fails closed without a native layout, so an open
  -- party/target child always owns one.
  local known = id == "back"
  if not known and (self._active == "party" or self._active == "target") then
    local slot = tonumber(id:match("^party:(%d+)$") or "")
    if slot ~= nil and slot % 1 == 0 and slot >= 0 and slot <= 5 then
      known = true
    end
  end
  -- Bag, learn, and move rows still project their rows behind
  -- validation; party/target rows are gone with their invented modal.
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
