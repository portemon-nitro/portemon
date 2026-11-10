-- Battle-local child selection: voluntary and forced party choice, battle
-- bag browsing with native-only staging, and roster-bound move learning.
-- Every flow binds its result to the opening launch and request identity,
-- never mutates field services, and never invents a choice the kernel did
-- not project. Synthetic requests, options, roster snapshots, and
-- inventory maps keep the run deterministic without a live battle.

local Assert = require("tests.support.Assert")
local ItemFixture = require("libs.items.tests.item_fixture")

local T = {}

local BattleSubflows = nil

---@return table<string, unknown> the child coordinator under test preparation
local function coordinator(catalog, opts)
  if BattleSubflows == nil then
    BattleSubflows = require("game.hgss.src.battle.BattleSubflows")
  end
  local args = { launchId = "launch-child-unit", itemCatalog = catalog }
  if type(opts) == "table" then
    for key, value in pairs(opts) do
      args[key] = value
    end
  end
  return BattleSubflows.new(args)
end

---@param reserve integer stable combatant identity of the eligible reserve
---@return table<string, unknown> detached action options projecting one reserve switch
local function switchOptions(reserve)
  return {
    requestId = 7,
    epoch = 3,
    controller = "player",
    kind = "action",
    actors = {
      {
        combatant = 1,
        activation = 5,
        kind = "action",
        choices = {
          {
            id = "switch:" .. tostring(reserve),
            role = "switch",
            enabled = true,
            reason = "refused",
            display = { combatant = reserve },
            choice = {
              actor = { combatant = 1, activation = 5 },
              kind = "switch",
              payload = { replacement = reserve },
            },
          },
        },
      },
    },
  }
end

---@return table<string, unknown> detached own-party snapshot with two same-species slots
local function twoEeveeRoster()
  return {
    { combatant = 1, slot = 0, name = "LEAD", level = 20, hp = 30, maxHp = 30 },
    { combatant = 2, slot = 1, name = "BACK", level = 5, hp = 10, maxHp = 18 },
  }
end

---@param opts table<string, unknown> intent overrides under test preparation
---@return table<string, unknown> party selection intent for the synthetic request
local function partyIntent(opts)
  local intent = {
    kind = "party",
    purpose = "switch",
    launchId = "launch-child-unit",
    requestId = 7,
    epoch = 3,
    controller = "player",
    cancellable = true,
    request = { requestId = 7, epoch = 3, controller = "player", kind = "action" },
    options = switchOptions(2),
    party = twoEeveeRoster(),
    inventory = {},
  }
  for key, value in pairs(opts) do
    intent[key] = value
  end
  return intent --[[@as table<string, unknown>]]
end

---@param flows table<string, unknown> coordinator under test driving
---@param event table<string, unknown> semantic input batch under test driving
local function drive(flows, event)
  flows:update({ event })
  flows:tick()
end

-- Settles one gated button press (WaitButtonAnim): frame 1 rebounds
-- to frame 2, then the deferred page transition applies.
local function settlePress(flows)
  flows:tick()
  flows:tick()
end

---@param flows table<string, unknown> coordinator waiting on a bag selection
local function useBagItem(flows)
  drive(flows, { type = "confirm" })
  settlePress(flows)
  drive(flows, { type = "confirm" })
  for _ = 1, 8 do
    flows:tick()
  end
end

---@param flows table<string, unknown> coordinator with a stocked item focused
local function tapBagItem(flows)
  Assert.isTrue(flows:activateControl("bag:0"), "the serving cell takes its native-layout tap")
  flows:tick()
  settlePress(flows)
  flows:tick()
  drive(flows, { type = "confirm" })
  for _ = 1, 8 do
    flows:tick()
  end
end

---@param flows table<string, unknown> coordinator waiting on a party switch
---@param slot integer zero-based party slot to select
local function switchPartyMon(flows, slot)
  local view = flows:status().childView --[[@as table<string, unknown>]]
  if view.focusId ~= "party:" .. tostring(slot) then
    Assert.isTrue(flows:activateControl("party:" .. tostring(slot)), "the requested party slot takes its native tap")
    flows:tick()
  else
    drive(flows, { type = "confirm" })
  end
  local native = flows:status().childView.native --[[@as table<string, unknown>]]
  Assert.equal(native.state, "context", "the selected slot opens its native party action menu")
  drive(flows, { type = "confirm" })
  for _ = 1, 12 do
    flows:tick()
  end
end

function T.voluntary_party_selection_seals_the_projected_reserve_fragment()
  local flows = coordinator()
  local options = switchOptions(2)
  local ok, openErr = flows:open(partyIntent({ options = options }))
  Assert.isTrue(ok, "the voluntary party child opens: " .. tostring(openErr))
  -- Selecting a party member opens the native action menu; Switch alone
  -- submits the projected replacement fragment.
  switchPartyMon(flows, 1)
  local result = flows:takeResult()
  Assert.notNil(result, "confirming the reserve stages its reply")
  Assert.equal(result.kind, "choice", "the reserve stages a choice")
  local reply = result.reply
  Assert.equal(reply.requestId, 7, "the reply answers the open request")
  Assert.equal(reply.epoch, 3, "the reply carries the open epoch")
  Assert.equal(reply.controller, "player", "the reply carries the open controller")
  Assert.equal(reply.launchId, "launch-child-unit", "the reply carries the open launch")
  Assert.deepEqual(reply.choices[1], options.actors[1].choices[1].choice, "the reply copies the projected fragment")
  Assert.isNil(flows:takeResult(), "the staged reply reports once")
  flows:dispose()
end

function T.voluntary_party_cancel_returns_a_bound_cancellation()
  local flows = coordinator()
  Assert.isTrue(flows:open(partyIntent({})), "the voluntary party child opens")
  drive(flows, { type = "cancel" })
  for _ = 1, 12 do
    flows:tick()
  end
  local result = flows:takeResult()
  Assert.notNil(result, "cancel stages a result")
  Assert.equal(result.kind, "cancelled", "cancel reports a navigation cancellation")
  Assert.equal(result.requestId, 7, "the cancellation binds the open request")
  Assert.equal(result.epoch, 3, "the cancellation binds the open epoch")
  Assert.equal(result.controller, "player", "the cancellation binds the open controller")
  flows:dispose()
end

function T.forced_replacement_blocks_every_cancel_path()
  local flows = coordinator()
  Assert.isTrue(flows:open(partyIntent({ purpose = "replacement", cancellable = false })), "forced replacement opens")
  drive(flows, { type = "cancel" })
  Assert.isNil(flows:takeResult(), "keyboard cancel seals nothing")
  Assert.isTrue(flows:status().active, "keyboard cancel keeps the child")
  -- The non-cancellable screen holds silently at its input boundary:
  -- blocking cancel is the screen's own permission, not a battle notice.
  -- Outside and menu edges never reach the selection lane.
  drive(flows, { type = "dismiss" })
  drive(flows, { type = "menu" })
  drive(flows, { type = "pointer_down", pointerId = "probe", x = 10000, y = 10000 })
  drive(flows, { type = "pointer_up", pointerId = "probe", x = 10000, y = 10000 })
  Assert.isNil(flows:takeResult(), "pointer edges seal nothing")
  Assert.isTrue(flows:status().active, "pointer edges keep the child")
  flows:dispose()
end

function T.ineligible_party_slots_stay_unfocusable()
  local flows = coordinator()
  local options = switchOptions(2)
  Assert.isTrue(flows:open(partyIntent({ options = options })), "the voluntary party child opens")
  drive(flows, { type = "confirm" })
  drive(flows, { type = "confirm" })
  for _ = 1, 12 do
    flows:tick()
  end
  Assert.isNil(flows:takeResult(), "the active lead is refused by the native Switch action")
  drive(flows, { type = "confirm" })
  drive(flows, { type = "cancel" })
  for _ = 1, 12 do
    flows:tick()
  end
  switchPartyMon(flows, 1)
  local result = flows:takeResult()
  Assert.notNil(result, "Switch on the eligible reserve stages its fragment")
  Assert.deepEqual(result.reply.choices[1], options.actors[1].choices[1].choice, "the reply names the reserve")
  flows:dispose()
end

function T.party_selection_maps_slots_to_stable_combatants()
  local flows = coordinator()
  -- Array position carries no meaning: the read model binds party
  -- slots, so a roster listed reserve-first still seals the stable
  -- reserve combatant. Focus and rows stay owned by the screen, never
  -- by the child status.
  local roster = {
    { combatant = 2, slot = 1, name = "BACK", level = 5, hp = 10, maxHp = 18 },
    { combatant = 1, slot = 0, name = "LEAD", level = 20, hp = 10, maxHp = 30 },
  }
  local options = switchOptions(2)
  Assert.isTrue(flows:open(partyIntent({ party = roster, options = options })), "the party child opens")
  Assert.isNil(flows:status().rows, "the child status carries no selection rows")
  switchPartyMon(flows, 1)
  local result = flows:takeResult()
  Assert.notNil(result, "confirming the reserve stages its reply")
  Assert.deepEqual(result.reply.choices[1], options.actors[1].choices[1].choice, "the reply names the reserve")
  flows:dispose()
end

function T.party_screen_disposes_on_close_and_reopens_cleanly()
  local flows = coordinator()
  Assert.isTrue(flows:open(partyIntent({})), "the first child opens")
  switchPartyMon(flows, 1)
  Assert.notNil(flows:takeResult(), "the first child stages its reply")
  flows:closeChild()
  Assert.isFalse(flows:status().active, "closing settles the child")
  Assert.isNil(flows:takeResult(), "closing seals no late reply")
  local reopened = partyIntent({ requestId = 8, epoch = 9 })
  Assert.isTrue(flows:open(reopened), "the replacement child opens on a fresh screen")
  switchPartyMon(flows, 1)
  local result = flows:takeResult()
  Assert.notNil(result, "the fresh screen stages its reply")
  Assert.equal(result.reply.requestId, 8, "the fresh reply binds the new request")
  Assert.equal(result.reply.epoch, 9, "the fresh reply binds the new epoch")
  flows:dispose()
end

function T.replacement_without_a_legal_reserve_fails_closed()
  local flows = coordinator()
  local empty = {
    requestId = 9,
    epoch = 2,
    controller = "player",
    kind = "replacement",
    actors = { { combatant = 1, activation = 5, kind = "replacement", choices = {} } },
  }
  local ok, openErr = flows:open(partyIntent({
    purpose = "replacement",
    cancellable = false,
    requestId = 9,
    epoch = 2,
    options = empty,
  }))
  Assert.isFalse(ok == true, "no invented reserve ever opens")
  Assert.isTrue(type(openErr) == "string" and openErr ~= "", "the failure names itself")
  Assert.isFalse(flows:status().active, "no child owns input after the failure")
  flows:dispose()
end

---@param key string staged item identity under projection
---@param holder integer choice target combatant under projection
---@param enabled boolean selection legality under projection
---@return table<string, unknown> native item choice for the synthetic options
local function itemChoice(key, holder, enabled)
  return {
    id = "item:" .. key .. ":" .. tostring(holder),
    role = "item",
    enabled = enabled,
    reason = enabled and "refused" or "the attendant blocks its use",
    display = { item = key },
    choice = {
      actor = { combatant = 1, activation = 5 },
      kind = "item",
      payload = { item = key, target = { kind = "combatant", combatant = holder } },
    },
  }
end

---@param choices table<integer, table<string, unknown>> native item choices under projection
---@return table<string, unknown> detached action options carrying the item choices
local function itemOptions(choices)
  return {
    requestId = 7,
    epoch = 3,
    controller = "player",
    kind = "action",
    actors = { { combatant = 1, activation = 5, kind = "action", choices = choices } },
  }
end

---@param inventory table<string, integer> battle stock under test preparation
---@param options table<string, unknown> native options under test preparation
---@return table<string, unknown> bag selection intent for the synthetic request
local function bagIntent(inventory, options)
  return {
    kind = "bag",
    purpose = "bag",
    launchId = "launch-child-unit",
    requestId = 7,
    epoch = 3,
    controller = "player",
    cancellable = true,
    request = { requestId = 7, epoch = 3, controller = "player", kind = "action" },
    options = options,
    party = twoEeveeRoster(),
    inventory = inventory,
  }
end

---@param flows table<string, unknown> coordinator resting on the open bag child
---@param index integer zero-based battle pocket under opening
local function openBattlePocket(flows, index)
  Assert.isTrue(
    flows:activateControl("bagpocket:" .. tostring(index)),
    "the battle pocket takes its tap"
  )
  flows:tick()
  settlePress(flows)
end

---@param flows table<string, unknown> coordinator resting on the open bag child
local function walkToMedicine(flows)
  openBattlePocket(flows, 0)
end

---@param flows table<string, unknown> coordinator resting on the open bag child
local function walkToBalls(flows)
  openBattlePocket(flows, 2)
end

function T.bag_healing_stages_its_target_and_cancels_back_to_the_bag()
  local catalog = ItemFixture.makeCatalog()
  local flows = coordinator(catalog)
  local options = itemOptions({ itemChoice("POTION", 1, true) })
  Assert.isTrue(flows:open(bagIntent({ POTION = 5 }, options)), "the stocked bag opens")
  walkToMedicine(flows)
  useBagItem(flows)
  Assert.isNil(flows:takeResult(), "staging the serving seals no reply")
  Assert.isTrue(flows:status().active, "staging keeps the child")
  Assert.equal(flows:status().stagedItem, "POTION", "the staged key is remembered")
  -- The retained bag answers no input while the target owns the lane.
  drive(flows, { type = "navigate", direction = "down" })
  drive(flows, { type = "navigate", direction = "up" })
  Assert.isNil(flows:takeResult(), "the inert bag seals no reply")
  drive(flows, { type = "cancel" })
  Assert.isNil(flows:takeResult(), "target cancel seals no reply")
  Assert.equal(flows:status().stagedItem, nil, "target cancel drops the staging")
  Assert.equal(flows:status().childView.bagPage, "item_list", "target cancel returns to the item list")
  drive(flows, { type = "cancel" })
  Assert.isNil(flows:takeResult(), "list cancel returns to the pocket menu")
  settlePress(flows)
  Assert.equal(flows:status().childView.bagPage, "pocket_menu", "list cancel returns to the pocket menu")
  drive(flows, { type = "cancel" })
  local result = flows:takeResult()
  Assert.notNil(result, "bag cancel stages a result")
  Assert.equal(result.kind, "cancelled", "bag cancel reports a navigation cancellation")
  flows:dispose()
end

function T.bag_healing_target_confirm_seals_the_native_fragment()
  local catalog = ItemFixture.makeCatalog()
  local flows = coordinator(catalog)
  local potion = itemChoice("POTION", 1, true)
  Assert.isTrue(flows:open(bagIntent({ POTION = 5 }, itemOptions({ potion }))), "the stocked bag opens")
  walkToMedicine(flows)
  useBagItem(flows)
  drive(flows, { type = "confirm" })
  local result = flows:takeResult()
  Assert.notNil(result, "accepting the serving stages its reply")
  Assert.equal(result.kind, "choice", "the serving stages a choice")
  Assert.deepEqual(result.reply.choices[1], potion.choice, "the serving copies the native fragment")
  flows:dispose()
end

---@param holder integer serving holder under projection
---@param moveSlot integer zero-based held move under projection
---@param enabled boolean selection legality under projection
---@return table<string, unknown> native one-move PP choice for the synthetic options
local function etherChoice(holder, moveSlot, enabled)
  local option = itemChoice("ETHER", holder, enabled)
  option.id = option.id .. ":" .. tostring(moveSlot)
  option.reason = enabled and nil or "no_effect"
  option.choice.payload.moveSlot = moveSlot
  return option
end

---@return table<string, unknown> one-move PP bag intent whose lead holds a spent and a full move
local function etherIntent()
  local options = itemOptions({ etherChoice(1, 0, true), etherChoice(1, 1, false) })
  local intent = bagIntent({ ETHER = 2 }, options)
  intent.party[1].moves = {
    { move = "TACKLE", name = "Tackle", pp = 5, maxPp = 35 },
    { move = "GROWL", name = "Growl", pp = 40, maxPp = 40 },
  }
  return intent
end

-- One-move PP servings ask for their move after the target, like the
-- native Restore PP page: a full move explains it has no effect, Back
-- returns to the target list, and the chosen move seals its fragment.
function T.bag_pp_serving_selects_its_move_before_sealing()
  local catalog = ItemFixture.makeCatalog()
  local flows = coordinator(catalog)
  local intent = etherIntent()
  Assert.isTrue(flows:open(intent), "the stocked bag opens")
  walkToMedicine(flows)
  useBagItem(flows)
  Assert.equal(flows:status().kind, "target", "the serving opens its target list first")
  drive(flows, { type = "confirm" })
  Assert.isNil(flows:takeResult(), "choosing the holder seals no reply")
  local view = flows:status().childView --[[@as table<string, unknown>]]
  Assert.equal(view.kind, "move", "the holder opens its move picker")
  Assert.deepEqual(
    { view.rows[1].label, view.rows[2].label, #view.rows },
    { "Tackle", "Growl", 2 },
    "the picker lists the holder's moves"
  )
  Assert.equal(view.rows[1].sub, "PP 5/35", "move rows show their current PP")
  Assert.equal(view.focusId, "move:0", "the picker opens on the first move")

  drive(flows, { type = "cancel" })
  Assert.isNil(flows:takeResult(), "Back seals no reply")
  Assert.equal(flows:status().kind, "target", "Back returns to the target list")

  drive(flows, { type = "confirm" })
  Assert.equal(flows:status().kind, "move", "the holder reopens its move picker")
  drive(flows, { type = "navigate", direction = "down" })
  drive(flows, { type = "confirm" })
  Assert.isNil(flows:takeResult(), "a full move seals no reply")
  Assert.equal(flows:status().kind, "target", "a full move returns to the target list")
  local native = flows:status().childView.native --[[@as table<string, unknown>]]
  Assert.equal(native.message, "It won’t have any effect.", "the refusal shows the native text")
  drive(flows, { type = "confirm" })
  for _ = 1, 8 do
    flows:tick()
  end

  drive(flows, { type = "confirm" })
  Assert.equal(flows:status().kind, "move", "the acknowledged list reopens the move picker")
  Assert.isTrue(flows:activateControl("move:0"), "the spent move takes its tap")
  flows:tick()
  local result = flows:takeResult()
  Assert.notNil(result, "the spent move stages its reply")
  Assert.equal(result.kind, "choice", "the serving stages a choice")
  Assert.deepEqual(
    result.reply.choices[1],
    intent.options.actors[1].choices[1].choice,
    "the chosen move copies its native fragment"
  )
  flows:dispose()
end

function T.bag_ball_throws_directly_at_the_opposing_holder()
  local catalog = ItemFixture.makeCatalog()
  local flows = coordinator(catalog)
  local ownBall = itemChoice("POKE_BALL", 1, true)
  local foeBall = itemChoice("POKE_BALL", 3, true)
  local options = itemOptions({ ownBall, foeBall })
  Assert.isTrue(flows:open(bagIntent({ POKE_BALL = 1 }, options)), "the stocked bag opens")
  walkToBalls(flows)
  useBagItem(flows)
  local result = flows:takeResult()
  Assert.notNil(result, "throwing the ball stages its reply")
  Assert.deepEqual(result.reply.choices[1], foeBall.choice, "the throw addresses the opposing holder")
  flows:dispose()
end

function T.bag_refused_rows_explain_themselves_without_sealing()
  local catalog = ItemFixture.makeCatalog()
  local flows = coordinator(catalog)
  local refused = itemChoice("POKE_BALL", 1, false)
  Assert.isTrue(flows:open(bagIntent({ POKE_BALL = 5 }, itemOptions({ refused }))), "the stocked bag opens")
  walkToBalls(flows)
  -- The item-list projection carries the refusal: the focused row stays
  -- disabled and names its kernel-projected reason.
  local listedView = flows:status().childView --[[@as table<string, unknown>]]
  Assert.equal(listedView.bagPage, "item_list", "the balls pocket lists")
  Assert.equal(listedView.focusId, "bag:0", "the refused cell keeps its focus")
  local listedRows = listedView.rows --[[@as table<integer, table<string, unknown>>]]
  Assert.equal(listedRows[1].id, "bag:0", "the refused cell still lists first")
  Assert.isFalse(listedRows[1].enabled == true, "the refused cell stays disabled")
  Assert.equal(listedRows[1].reason, "the attendant blocks its use", "the refused row names its kernel reason")
  useBagItem(flows)
  Assert.isNil(flows:takeResult(), "confirming a refused ball seals no reply")
  Assert.isTrue(flows:status().active, "the refusal keeps the child")
  -- Retail TryUseItem answers USE on a refused item with its message
  -- page (ShowMessage, nextState 8), never the use-item confirmation.
  Assert.equal(flows:status().childView.bagPage, "message", "the refusal opens the message page")
  Assert.equal(
    flows:status().childView.notice,
    "the attendant blocks its use",
    "the message names its kernel reason"
  )
  flows:dispose()
end

-- Retail TryUseItem refusals resolve their staged message keys with
-- their source substitution counts: aim/room blocks carry none, the
-- embargo rebuke names the move and the holder, and the trainer-escape
-- rebuke names the player. USE on a refused item opens the message page
-- with that text; acknowledging it returns to the use-item page.
---@param view table<string, unknown> detached bag child view under indexing
---@return table<string, table<string, unknown>> projected rows by stable row identity
local function refusalRowsById(view)
  local rows = view.rows --[[@as table<integer, table<string, unknown>>]]
  local byId = {} ---@type table<string, table<string, unknown>>
  for _, row in ipairs(rows) do
    byId[tostring(row.id)] = row
  end
  return byId
end
function T.bag_try_use_item_refusals_resolve_their_staged_keys()
  local catalog = ItemFixture.makeCatalog()
  local flows = coordinator(catalog, {
    resolveMessage = function(key, subs)
      return "MARKER:" .. tostring(key) .. "#" .. tostring(subs ~= nil and #subs or 0)
    end,
  })
  local function refusedChoice(key, holder, reason)
    return {
      id = "item:" .. key .. ":" .. tostring(holder),
      role = "item",
      enabled = false,
      reason = reason,
      display = { item = key },
      choice = {
        actor = { combatant = 1, activation = 5 },
        kind = "item",
        payload = { item = key, target = { kind = "combatant", combatant = holder } },
      },
    }
  end
  local options = itemOptions({
    refusedChoice("POKE_BALL", 3, "no_aim_doubles"),
    refusedChoice("GREAT_BALL", 3, "no_room"),
    refusedChoice("LUXURY_BALL", 3, "no_aim_hidden"),
    refusedChoice("MASTER_BALL", 3, "no_aim_hidden_foe"),
    refusedChoice("POTION", 1, "embargo"),
    refusedChoice("POKE_DOLL", 1, "no_stealing"),
  })
  local intent = bagIntent({
    POKE_BALL = 1,
    GREAT_BALL = 1,
    LUXURY_BALL = 1,
    MASTER_BALL = 1,
    POTION = 1,
    POKE_DOLL = 1,
  }, options)
  intent.playerName = "RED"
  Assert.isTrue(flows:open(intent), "the refused bag opens")
  walkToBalls(flows)
  local ballView = flows:status().childView --[[@as table<string, unknown>]]
  -- Cells sort by native identity, so expectations map by label.
  local ballReasons = {} ---@type table<string, string?>
  for _, row in ipairs(ballView.rows) do
    ballReasons[tostring(row.label)] = row.reason
  end
  Assert.equal(
    ballReasons.POKE_BALL,
    "MARKER:battle/bag/message/no-aim-doubles#0",
    "doubles aim resolves its staged key"
  )
  Assert.equal(ballReasons.GREAT_BALL, "MARKER:battle/bag/message/no-room#0", "PC room resolves its staged key")
  Assert.equal(
    ballReasons.LUXURY_BALL,
    "MARKER:battle/bag/message/no-aim-hidden#0",
    "hidden aim resolves its staged key"
  )
  Assert.equal(
    ballReasons.MASTER_BALL,
    "MARKER:battle/bag/message/no-aim-hidden-foe#0",
    "hidden-foe aim resolves its staged key"
  )
  useBagItem(flows)
  Assert.isNil(flows:takeResult(), "the refused USE seals no reply")
  Assert.equal(flows:status().childView.bagPage, "message", "the refused USE opens the message page")
  Assert.equal(
    flows:status().childView.notice,
    "MARKER:battle/bag/message/no-room#0",
    "the message names the focused refusal"
  )
  drive(flows, { type = "confirm" })
  Assert.equal(flows:status().childView.bagPage, "use_item", "acknowledging returns to the use item page")
  drive(flows, { type = "cancel" })
  settlePress(flows)
  drive(flows, { type = "cancel" })
  settlePress(flows)
  walkToMedicine(flows)
  local medicineView = flows:status().childView --[[@as table<string, unknown>]]
  local medicineReason = refusalRowsById(medicineView)["bag:0"]
  Assert.equal(
    medicineReason ~= nil and medicineReason.reason or nil,
    "MARKER:battle/bag/message/embargo#2",
    "embargo resolves its staged key with its move and holder, got " .. tostring(medicineReason ~= nil and medicineReason.reason or "no-row")
  )
  drive(flows, { type = "cancel" })
  settlePress(flows)
  openBattlePocket(flows, 3)
  local battleItemsView = flows:status().childView --[[@as table<string, unknown>]]
  Assert.equal(
    refusalRowsById(battleItemsView)["bag:0"].reason,
    "MARKER:battle/bag/message/no-stealing#1",
    "trainer escapes resolve their staged key with the player"
  )
  flows:dispose()
end

-- The trainer-escape rebuke names the player, so an intent without one
-- fails loudly instead of printing a nameless rebuke.
function T.bag_stealing_refusal_without_a_player_fails_closed()
  local catalog = ItemFixture.makeCatalog()
  local flows = coordinator(catalog)
  local options = itemOptions({
    {
      id = "item:POKE_DOLL:1",
      role = "item",
      enabled = false,
      reason = "no_stealing",
      display = { item = "POKE_DOLL" },
      choice = {
        actor = { combatant = 1, activation = 5 },
        kind = "item",
        payload = { item = "POKE_DOLL", target = { kind = "combatant", combatant = 1 } },
      },
    },
  })
  Assert.isTrue(flows:open(bagIntent({ POKE_DOLL = 1 }, options)), "the refused bag opens")
  openBattlePocket(flows, 3)
  local ok, failure = pcall(useBagItem, flows)
  Assert.isFalse(ok == true, "the nameless rebuke never prints")
  Assert.isTrue(
    tostring(failure):find("stealing refusals name the player", 1, true) ~= nil,
    "the failure names its missing player"
  )
  flows:dispose()
end

function T.bag_stock_without_a_catalog_fails_closed()
  local flows = coordinator(nil)
  local options = itemOptions({ itemChoice("POTION", 1, true) })
  local ok, openErr = flows:open(bagIntent({ POTION = 5 }, options))
  Assert.isFalse(ok == true, "stocked pockets never group without their catalog")
  Assert.isTrue(type(openErr) == "string", "the failure names itself")
  flows:dispose()
end

function T.empty_bag_opens_and_cancels()
  -- The native bag application needs its catalog even to render the
  -- empty browser; production always lends it, so the test lends it too.
  local flows = coordinator(ItemFixture.makeCatalog())
  local options = itemOptions({})
  Assert.isTrue(flows:open(bagIntent({}, options)), "the empty bag opens")
  drive(flows, { type = "cancel" })
  local result = flows:takeResult()
  Assert.notNil(result, "bag cancel stages a result")
  Assert.equal(result.kind, "cancelled", "bag cancel reports a navigation cancellation")
  flows:dispose()
end

---@param recipient integer roster-bound learning recipient under test preparation
---@return table<string, unknown> learn request with a full held move set
local function learnRequest(recipient)
  return {
    requestId = 11,
    epoch = 4,
    controller = "player",
    kind = "learn_move",
    incomingMove = "SAND_ATTACK",
    currentMoves = {
      { move = "TACKLE", pp = 35, ppUps = 0 },
      { move = "TAIL_WHIP", pp = 30, ppUps = 0 },
      { move = "GROWL", pp = 40, ppUps = 0 },
      { move = "LEER", pp = 30, ppUps = 0 },
    },
    actors = { { combatant = recipient } },
    canDecline = true,
  }
end

---@param recipient integer roster-bound learning recipient under test preparation
---@return table<string, unknown> native learning options for the held recipient
local function learnOptions(recipient)
  local choices = {}
  for slot = 0, 3 do
    choices[#choices + 1] = {
      id = "learn:replace:" .. tostring(slot),
      role = "learn",
      enabled = true,
      reason = "refused",
      display = { move = "MOVE" .. tostring(slot) },
      choice = {
        actor = { combatant = recipient },
        kind = "confirm",
        payload = { decision = "replace", slot = slot },
      },
    }
  end
  choices[#choices + 1] = {
    id = "learn:decline",
    role = "learn",
    enabled = true,
    reason = "refused",
    display = { decision = "decline" },
    choice = {
      actor = { combatant = recipient },
      kind = "confirm",
      payload = { decision = "decline" },
    },
  }
  return {
    requestId = 11,
    epoch = 4,
    controller = "player",
    kind = "learn_move",
    actors = {
      {
        combatant = recipient,
        kind = "learn_move",
        incomingMove = "SAND_ATTACK",
        currentMoves = learnRequest(recipient).currentMoves,
        choices = choices,
      },
    },
  }
end

---@param recipient integer roster-bound learning recipient under test preparation
---@return table<string, unknown> learning intent for the synthetic request
local function learnIntent(recipient)
  return {
    kind = "learn",
    purpose = "learn",
    launchId = "launch-child-unit",
    requestId = 11,
    epoch = 4,
    controller = "player",
    cancellable = false,
    request = learnRequest(recipient),
    options = learnOptions(recipient),
    party = twoEeveeRoster(),
    inventory = {},
  }
end

function T.learning_replace_confirms_its_roster_bound_fragment()
  local flows = coordinator()
  Assert.isTrue(flows:open(learnIntent(1)), "learning opens for the held recipient")
  drive(flows, { type = "navigate", direction = "down" })
  drive(flows, { type = "navigate", direction = "down" })
  drive(flows, { type = "confirm" })
  Assert.isNil(flows:takeResult(), "selecting a row seals no reply")
  Assert.isTrue(flows:status().active, "selecting a row stays on its confirmation")
  drive(flows, { type = "cancel" })
  Assert.isNil(flows:takeResult(), "rejecting the confirmation seals no reply")
  Assert.isTrue(flows:status().active, "rejecting the confirmation returns to the list")
  drive(flows, { type = "confirm" })
  drive(flows, { type = "confirm" })
  local result = flows:takeResult()
  Assert.notNil(result, "confirming the replace stages its reply")
  local fragment = result.reply.choices[1]
  Assert.deepEqual(fragment.actor, { combatant = 1 }, "the replace binds the roster record without a token")
  Assert.equal(fragment.payload.decision, "replace", "the payload decides replace")
  Assert.equal(fragment.payload.slot, 2, "the payload names the zero-based move slot")
  flows:dispose()
end

function T.learning_back_never_auto_declines()
  local flows = coordinator()
  Assert.isTrue(flows:open(learnIntent(2)), "learning opens for the benched recipient")
  drive(flows, { type = "cancel" })
  Assert.isNil(flows:takeResult(), "backing out of the list never auto-declines")
  Assert.isTrue(flows:status().active, "backing out asks its stop confirmation")
  drive(flows, { type = "cancel" })
  Assert.isNil(flows:takeResult(), "rejecting the stop confirmation seals no reply")
  Assert.isTrue(flows:status().active, "rejecting the stop confirmation returns to the list")
  -- The stop confirmation replaces explicitly: confirming it declines.
  drive(flows, { type = "cancel" })
  drive(flows, { type = "confirm" })
  local result = flows:takeResult()
  Assert.notNil(result, "confirming the stop stages its reply")
  Assert.equal(result.reply.choices[1].payload.decision, "decline", "the stop confirms the decline")
  Assert.deepEqual(result.reply.choices[1].actor, { combatant = 2 }, "the decline binds its recipient")
  flows:dispose()
end

function T.learning_decline_row_confirms_before_sealing()
  local flows = coordinator()
  Assert.isTrue(flows:open(learnIntent(2)), "learning opens for the benched recipient")
  for _ = 1, 4 do
    drive(flows, { type = "navigate", direction = "down" })
  end
  drive(flows, { type = "confirm" })
  Assert.isNil(flows:takeResult(), "selecting decline seals no reply yet")
  drive(flows, { type = "confirm" })
  local result = flows:takeResult()
  Assert.notNil(result, "confirming the decline stages its reply")
  Assert.equal(result.reply.choices[1].payload.decision, "decline", "the decline matches its fragment")
  flows:dispose()
end

function T.consecutive_learning_prompts_stay_separate()
  local flows = coordinator()
  Assert.isTrue(flows:open(learnIntent(1)), "the first prompt opens")
  for _ = 1, 4 do
    drive(flows, { type = "navigate", direction = "down" })
  end
  drive(flows, { type = "confirm" })
  drive(flows, { type = "confirm" })
  local first = flows:takeResult()
  Assert.notNil(first, "the first prompt stages its reply")
  Assert.equal(first.reply.requestId, 11, "the first reply binds the first prompt")
  flows:closeChild()
  local second = learnIntent(2)
  second.requestId = 12
  second.request.requestId = 12
  second.options.requestId = 12
  Assert.isTrue(flows:open(second), "the consecutive prompt opens separately")
  Assert.isTrue(flows:status().active, "the consecutive prompt owns input")
  flows:dispose()
end

function T.stale_results_never_address_a_new_request()
  local flows = coordinator()
  Assert.isTrue(flows:open(partyIntent({})), "the first child opens")
  switchPartyMon(flows, 1)
  local first = flows:takeResult()
  Assert.notNil(first, "the first child stages its reply")
  flows:closeChild()
  Assert.isTrue(flows:open(partyIntent({ requestId = 8, epoch = 9 })), "the replacement child opens")
  Assert.isTrue(first.reply.requestId ~= flows:status().requestId, "the old reply binds the retired request")
  Assert.equal(flows:status().requestId, 8, "the child tracks the current request")
  Assert.equal(flows:status().epoch, 9, "the child tracks the current epoch")
  flows:dispose()
end

function T.children_release_exactly_once_and_hold_no_borrowed_owners()
  local catalog = ItemFixture.makeCatalog()
  local flows = coordinator(catalog)
  Assert.isTrue(flows:open(bagIntent({ POTION = 5 }, itemOptions({ itemChoice("POTION", 1, true) }))), "bag opens")
  flows:dispose()
  flows:dispose()
  Assert.isFalse(flows:status().active, "disposal settles the lifetime")
  Assert.isNil(flows:takeResult(), "late results never resurrect")
  drive(flows, { type = "confirm" })
  Assert.isNil(flows:takeResult(), "input after disposal seals nothing")
  Assert.isTrue(catalog:item("POTION").pocket == "medicine", "the borrowed catalog stays usable")
end

function T.battle_children_ignore_foreign_input_edges()
  local flows = coordinator()
  Assert.isTrue(flows:open(partyIntent({})), "the party child opens")
  drive(flows, { type = "dismiss" })
  drive(flows, { type = "menu" })
  drive(flows, { type = "pointer_down", pointerId = "probe", x = 8, y = 8 })
  drive(flows, { type = "pointer_up", pointerId = "probe", x = 8, y = 8 })
  drive(flows, { type = "pointer_cancel", pointerId = "probe" })
  Assert.isNil(flows:takeResult(), "foreign edges seal nothing")
  Assert.isTrue(flows:status().active, "foreign edges keep the child")
  flows:dispose()
end
---@return table<integer, table<string, unknown>> occupied six-slot roster under test preparation
local function sixSlotRoster()
  local roster = {}
  for slot = 0, 5 do
    roster[#roster + 1] = {
      combatant = slot + 1,
      slot = slot,
      name = "MON" .. tostring(slot),
      level = 20,
      hp = 30,
      maxHp = 30,
    }
  end
  return roster
end

---@param reserve integer stable combatant identity of an eligible reserve
---@return table<string, unknown> native switch choice for the synthetic options
local function reserveChoice(reserve)
  return {
    id = "switch:" .. tostring(reserve),
    role = "switch",
    enabled = true,
    reason = "refused",
    display = { combatant = reserve },
    choice = {
      actor = { combatant = 1, activation = 5 },
      kind = "switch",
      payload = { replacement = reserve },
    },
  }
end

---@return table<string, unknown> detached action options projecting two reserve switches
local function twoReserveOptions()
  return {
    requestId = 7,
    epoch = 3,
    controller = "player",
    kind = "action",
    actors = {
      { combatant = 1, activation = 5, kind = "action", choices = { reserveChoice(2), reserveChoice(5) } },
    },
  }
end

---@return table<string, integer> multi-pocket battle stock under test preparation
local function variedStock()
  return {
    POTION = 5,
    POKE_BALL = 3,
    SOOTHE_BELL = 1,
    CHERI_BERRY = 2,
    ITEM_6 = 1,
    ITEM_12 = 1,
    ITEM_18 = 1,
    ITEM_24 = 1,
    ITEM_30 = 1,
    ITEM_36 = 1,
    ITEM_42 = 1,
  }
end

---@return table<string, unknown> detached action options with two own serving targets
local function twoTargetServingOptions()
  return itemOptions({ itemChoice("POTION", 1, true), itemChoice("POTION", 2, true) })
end

---@param sealed table<string, unknown> staged choice fragment under comparison
---@param choices table<integer, table<string, unknown>> projected native choices under comparison
---@param message string failure context under comparison
local function assertSealedAmong(sealed, choices, message)
  for _, candidate in ipairs(choices) do
    local matches = pcall(Assert.deepEqual, sealed, candidate.choice, message)
    if matches then
      return
    end
  end
  error(message .. " (no projected choice matched)", 0)
end

---@param view table<string, unknown> detached child view under inspection
---@return table<integer, string> visible row labels in order
local function rowLabels(view)
  local rows = view.rows --[[@as table<integer, table<string, unknown>>]]
  local labels = {}
  for _, row in ipairs(rows) do
    labels[#labels + 1] = tostring(row.label)
  end
  return labels
end

function T.party_child_lists_six_stable_rows_with_no_hidden_screens()
  local flows = coordinator()
  local options = twoReserveOptions()
  Assert.isTrue(flows:open(partyIntent({ party = sixSlotRoster(), options = options })), "the six-slot child opens")
  -- No update or tick ran yet: the rows are already answerable.
  local view = flows:status().childView --[[@as table<string, unknown>]]
  Assert.isTrue(view.interactive == true, "the roster answers with no waiting")
  local rows = view.rows --[[@as table<integer, table<string, unknown>>]]
  Assert.equal(#rows, 6, "all six slots list")
  for slot = 0, 5 do
    Assert.equal(rows[slot + 1].id, "party:" .. tostring(slot), "slot keeps its stable row")
  end
  Assert.isTrue(type(view.focusId) == "string", "focus already rests somewhere meaningful")
  -- Edges wait for the accepted source tick. The first confirm opens the
  -- native action menu; Switch on the selected reserve seals the fragment.
  flows:update({ { type = "navigate", direction = "down" } })
  flows:tick()
  flows:update({ { type = "confirm" } })
  Assert.isNil(flows:takeResult(), "the buffered edge seals nothing before its tick")
  flows:tick()
  Assert.equal(flows:status().childView.native.state, "context", "the tick opens the native party action menu")
  drive(flows, { type = "confirm" })
  for _ = 1, 12 do
    flows:tick()
  end
  local result = flows:takeResult()
  Assert.notNil(result, "the accepted tick seals a projected reserve")
  assertSealedAmong(result.reply.choices[1], options.actors[1].choices, "the seal names a projected reserve")
  flows:dispose()
end

function T.party_keys_and_taps_seal_the_same_projected_reserve()
  local options = twoReserveOptions()
  local keyed = coordinator()
  Assert.isTrue(keyed:open(partyIntent({ party = sixSlotRoster(), options = options })), "keys open the roster")
  for _ = 1, 10 do
    local view = keyed:status().childView --[[@as table<string, unknown>]]
    if view.focusId == "party:1" then
      break
    end
    drive(keyed, { type = "navigate", direction = "down" })
  end
  local focused = keyed:status().childView --[[@as table<string, unknown>]]
  Assert.equal(focused.focusId, "party:1", "keys reach the first reserve row")
  switchPartyMon(keyed, 1)
  local keyedResult = keyed:takeResult()
  Assert.notNil(keyedResult, "keys seal the reserve")
  keyed:dispose()
  local tapped = coordinator()
  Assert.isTrue(tapped:open(partyIntent({ party = sixSlotRoster(), options = options })), "taps open the roster")
  switchPartyMon(tapped, 1)
  local tappedResult = tapped:takeResult()
  Assert.notNil(tappedResult, "the tap seals the reserve")
  Assert.deepEqual(
    tappedResult.reply.choices[1],
    keyedResult.reply.choices[1],
    "both input modes seal the same fragment"
  )
  Assert.deepEqual(
    tappedResult.reply.choices[1],
    options.actors[1].choices[1].choice,
    "the sealed fragment copies the projection"
  )
  tapped:dispose()
end

function T.bag_pocket_tabs_match_between_keys_and_pointer()
  local catalog = ItemFixture.makeCatalog()
  local keyed = coordinator(catalog)
  Assert.isTrue(keyed:open(bagIntent(variedStock(), twoTargetServingOptions())), "keys open the stocked bag")
  local opened = keyed:status().childView --[[@as table<string, unknown>]]
  Assert.isTrue(opened.interactive == true, "the bag answers with no waiting")
  Assert.equal(opened.bagPage, "pocket_menu", "the bag opens on its pocket menu")
  Assert.deepEqual(
    opened.pockets,
    { "hp_pp", "status", "balls", "battle_items" },
    "the menu lists the four retail battle pockets"
  )
  Assert.equal(#opened.rows, 6, "the menu shows four pockets plus last-used and back")
  Assert.equal(opened.rows[1].id, "bagpocket:0", "pocket options keep stable rows")
  Assert.equal(opened.focusId, "bagpocket:0", "the menu opens on the first pocket")
  -- Keys open the crowded HP/PP pocket through the menu.
  drive(keyed, { type = "confirm" })
  settlePress(keyed)
  local listed = keyed:status().childView --[[@as table<string, unknown>]]
  Assert.equal(listed.bagPage, "item_list", "confirming a pocket opens its item list")
  Assert.equal(listed.currentPocket, "hp_pp", "the first pocket holds the servings")
  local openedPage = listed.page --[[@as table<string, integer>]]
  Assert.equal(openedPage.count, 2, "the crowded pocket spans two pages")
  -- Keys turn the page at the right edge behind the stepper dip.
  drive(keyed, { type = "navigate", direction = "right" })
  drive(keyed, { type = "navigate", direction = "right" })
  settlePress(keyed)
  local turned = keyed:status().childView --[[@as table<string, unknown>]]
  Assert.equal(turned.page.current, 2, "right at the edge turns the page")
  keyed:closeChild()
  -- Keys hop one pocket over through the menu; pointer takes the same hop.
  Assert.isTrue(keyed:open(bagIntent(variedStock(), twoTargetServingOptions())), "keys reopen the bag")
  drive(keyed, { type = "navigate", direction = "down" })
  drive(keyed, { type = "confirm" })
  settlePress(keyed)
  local keyedView = keyed:status().childView --[[@as table<string, unknown>]]
  Assert.equal(keyedView.currentPocket, "status", "keys reach the status pocket")
  keyed:dispose()
  local tapped = coordinator(catalog)
  Assert.isTrue(tapped:open(bagIntent(variedStock(), twoTargetServingOptions())), "taps open the bag")
  Assert.isTrue(tapped:activateControl("bagpocket:1"), "the status pocket takes its tap")
  tapped:tick()
  settlePress(tapped)
  local tappedView = tapped:status().childView --[[@as table<string, unknown>]]
  Assert.equal(tappedView.currentPocket, keyedView.currentPocket, "both modes land in the same pocket")
  Assert.deepEqual(rowLabels(tappedView), rowLabels(keyedView), "both modes list the same cells")
  tapped:dispose()
end

function T.bag_target_cancel_restores_the_resting_browse_without_spending()
  local catalog = ItemFixture.makeCatalog()
  local flows = coordinator(catalog)
  local options = twoTargetServingOptions()
  Assert.isTrue(flows:open(bagIntent(variedStock(), options)), "the stocked bag opens")
  Assert.isTrue(flows:activateControl("bagpocket:0"), "the HP/PP pocket takes its tap")
  flows:tick()
  settlePress(flows)
  local resting = flows:status().childView --[[@as table<string, unknown>]]
  Assert.equal(resting.currentPocket, "hp_pp", "the browse reaches the serving pocket")
  -- The crowded pocket sorts by native id; walk down to the serving.
  drive(flows, { type = "navigate", direction = "down" })
  resting = flows:status().childView --[[@as table<string, unknown>]]
  Assert.equal(resting.focusId, "bag:2", "the serving cell takes focus")
  local restingPage = resting.page --[[@as table<string, integer>]]
  useBagItem(flows)
  Assert.equal(flows:status().stagedItem, "POTION", "the serving stages")
  Assert.isNil(flows:takeResult(), "staging seals no reply")
  flows:update({ { type = "cancel" } })
  flows:tick()
  Assert.isNil(flows:takeResult(), "target cancel seals no reply")
  Assert.isNil(flows:status().stagedItem, "target cancel drops the staging")
  local returned = flows:status().childView --[[@as table<string, unknown>]]
  Assert.equal(returned.currentPocket, "hp_pp", "cancel keeps the pocket")
  Assert.equal(returned.focusId, resting.focusId, "cancel keeps the focus")
  local returnedPage = returned.page --[[@as table<string, integer>]]
  Assert.equal(returnedPage.current, restingPage.current, "cancel keeps the page")
  Assert.deepEqual(rowLabels(returned), rowLabels(resting), "cancel keeps the listed cells")
  local foundServing = false
  for _, row in
    ipairs(returned.rows --[[@as table<integer, table<string, unknown>>]])
  do
    if row.label == "Potion" then
      Assert.equal(row.sub, "x5", "the serving spends nothing on cancel")
      foundServing = true
    end
  end
  Assert.isTrue(foundServing, "the serving still lists after cancel")
  -- Staging again and accepting seals the exact projected serving.
  useBagItem(flows)
  for _ = 1, 10 do
    local view = flows:status().childView --[[@as table<string, unknown>]]
    if view.focusId == "party:0" then
      break
    end
    drive(flows, { type = "navigate", direction = "down" })
  end
  drive(flows, { type = "confirm" })
  local result = flows:takeResult()
  Assert.notNil(result, "accepting the serving seals its reply")
  Assert.deepEqual(
    result.reply.choices[1],
    options.actors[1].choices[1].choice,
    "the serving copies the projected fragment"
  )
  flows:dispose()
end

function T.refused_throws_and_empty_bags_close_without_hidden_screens()
  local catalog = ItemFixture.makeCatalog()
  local flows = coordinator(catalog)
  local refused = itemChoice("POKE_BALL", 1, false)
  Assert.isTrue(flows:open(bagIntent({ POKE_BALL = 5 }, itemOptions({ refused }))), "the stocked bag opens")
  Assert.isTrue(flows:status().childView.interactive == true, "the bag answers with no waiting")
  Assert.equal(flows:status().childView.bagPage, "pocket_menu", "the bag opens on its pocket menu")
  walkToBalls(flows)
  local listedView = flows:status().childView --[[@as table<string, unknown>]]
  Assert.isFalse(listedView.rows[1].enabled == true, "the refused cell stays disabled")
  Assert.equal(listedView.rows[1].reason, "the attendant blocks its use", "the refused row names its kernel reason")
  drive(flows, { type = "confirm" })
  Assert.isNil(flows:takeResult(), "selecting the refused cell seals no reply")
  settlePress(flows)
  Assert.equal(flows:status().childView.bagPage, "use_item", "selecting opens the use-item page")
  flows:closeChild()
  flows:dispose()
  local empty = coordinator(catalog)
  Assert.isTrue(empty:open(bagIntent({}, itemOptions({}))), "the empty bag opens on its pocket menu")
  Assert.equal(empty:status().childView.bagPage, "pocket_menu", "the empty bag opens on its pocket menu")
  Assert.equal(empty:status().childView.focusId, "bagpocket:0", "the empty menu opens on the first pocket")
  drive(empty, { type = "cancel" })
  local result = empty:takeResult()
  Assert.notNil(result, "empty cancel stages a result")
  Assert.equal(result.kind, "cancelled", "empty cancel reports a navigation cancellation")
  empty:dispose()
end

function T.forced_replacement_restages_whole_replies_after_close()
  local flows = coordinator()
  local options = twoReserveOptions()
  local intent = partyIntent({
    party = sixSlotRoster(),
    options = options,
    purpose = "replacement",
    cancellable = false,
  })
  Assert.isTrue(flows:open(intent), "forced replacement opens")
  drive(flows, { type = "cancel" })
  Assert.isNil(flows:takeResult(), "forced cancel seals nothing")
  for _ = 1, 10 do
    local view = flows:status().childView --[[@as table<string, unknown>]]
    if view.focusId == "party:1" then
      break
    end
    drive(flows, { type = "navigate", direction = "down" })
  end
  -- A doubled confirm edge in one batch still stages exactly one reply:
  -- the accepted tick drains both edges but the native seal reports once.
  switchPartyMon(flows, 1)
  local first = flows:takeResult()
  Assert.notNil(first, "the doubled edge stages its reply")
  Assert.isNil(flows:takeResult(), "the doubled edge stages no second reply")
  Assert.deepEqual(
    first.reply.choices[1],
    options.actors[1].choices[1].choice,
    "the reply copies the projected reserve"
  )
  -- Closing and reopening the same request restages cleanly.
  flows:closeChild()
  Assert.isTrue(flows:open(intent), "the same request restages after close")
  for _ = 1, 10 do
    local view = flows:status().childView --[[@as table<string, unknown>]]
    if view.focusId == "party:4" then
      break
    end
    drive(flows, { type = "navigate", direction = "down" })
  end
  switchPartyMon(flows, 4)
  local restaged = flows:takeResult()
  Assert.notNil(restaged, "the restaged child seals")
  Assert.deepEqual(
    restaged.reply.choices[1],
    options.actors[1].choices[2].choice,
    "the restage names the other projected reserve"
  )
  flows:dispose()
end

function T.learning_stages_every_held_choice_through_keys_and_taps()
  for slot = 0, 3 do
    local flows = coordinator()
    Assert.isTrue(flows:open(learnIntent(1)), "learning opens for the held recipient")
    for _ = 1, slot do
      drive(flows, { type = "navigate", direction = "down" })
    end
    drive(flows, { type = "confirm" })
    Assert.isNil(flows:takeResult(), "staging seals no reply")
    drive(flows, { type = "confirm" })
    local result = flows:takeResult()
    Assert.notNil(result, "confirming seals the replace")
    Assert.equal(result.reply.choices[1].payload.decision, "replace", "the payload decides replace")
    Assert.equal(result.reply.choices[1].payload.slot, slot, "the payload names the zero-based move slot")
    flows:dispose()
  end
  local tapped = coordinator()
  Assert.isTrue(tapped:open(learnIntent(1)), "learning opens for the pointer decline")
  Assert.isTrue(tapped:activateControl("learn:decline"), "the decline row takes the tap")
  tapped:tick()
  Assert.isNil(tapped:takeResult(), "staging decline seals no reply yet")
  Assert.isTrue(tapped:activateControl("confirm"), "the confirmation takes the tap")
  tapped:tick()
  local declined = tapped:takeResult()
  Assert.notNil(declined, "confirming seals the decline")
  Assert.equal(declined.reply.choices[1].payload.decision, "decline", "the tap confirms the decline")
  tapped:dispose()
end

function T.closed_children_drop_stale_pointer_edges()
  local flows = coordinator()
  Assert.isTrue(flows:open(partyIntent({})), "the party child opens")
  flows:update({ { type = "pointer_down", pointerId = "stale", x = 8, y = 8 } })
  flows:closeChild()
  flows:update({ { type = "pointer_up", pointerId = "stale", x = 8, y = 8 } })
  Assert.isNil(flows:takeResult(), "the stale release seals nothing")
  Assert.isFalse(flows:activateControl("party:1"), "taps miss the closed child")
  Assert.isTrue(flows:open(partyIntent({ requestId = 8, epoch = 9 })), "the replacement child opens")
  Assert.isTrue(flows:status().active, "the fresh child owns input")
  flows:dispose()
end

function T.audio_effect_voices_select_on_focus_moves_and_decide_on_seals()
  local catalog = ItemFixture.makeCatalog()
  local plays = {}
  local function audioEffect(symbol)
    plays[#plays + 1] = symbol
  end
  local flows = coordinator(catalog, { audioEffect = audioEffect })
  Assert.isTrue(flows:open(partyIntent({})), "the party child opens")
  local before = flows:status().childView.focusId
  drive(flows, { type = "navigate", direction = "down" })
  local after = flows:status().childView.focusId
  Assert.isTrue(before ~= after, "navigation moves the focus")
  Assert.equal(plays[1], "SEQ_SE_DP_SELECT", "cursor moves voice select")
  switchPartyMon(flows, 1)
  Assert.notNil(flows:takeResult(), "the reserve seals")
  Assert.equal(plays[#plays], "SEQ_SE_DP_DECIDE", "sealing voices decide")
  flows:dispose()
end

function T.resolve_message_replaces_hardcoded_refusals_with_markers()
  local catalog = ItemFixture.makeCatalog()
  local function resolveMessage(key)
    return "MARKER:" .. tostring(key)
  end
  local flows = coordinator(catalog, { resolveMessage = resolveMessage })
  local fainted = {
    { combatant = 1, slot = 0, name = "LEAD", level = 20, hp = 0, maxHp = 30 },
    { combatant = 2, slot = 1, name = "BACK", level = 5, hp = 10, maxHp = 18 },
  }
  local options = switchOptions(2)
  Assert.isTrue(flows:open(partyIntent({ party = fainted, options = options })), "the fainted roster opens")
  local view = flows:status().childView --[[@as table<string, unknown>]]
  local rows = view.rows --[[@as table<integer, table<string, unknown>>]]
  Assert.equal(rows[1].reason, "MARKER:battle/party/message/no-energy", "fainted rows resolve their retail message")
  flows:dispose()
  local refused = coordinator(catalog, { resolveMessage = resolveMessage })
  local noEffectOptions = itemOptions({
    {
      id = "item:POTION:1",
      role = "item",
      enabled = false,
      reason = "no_effect",
      display = { item = "POTION" },
      choice = {
        actor = { combatant = 1, activation = 5 },
        kind = "item",
        payload = { item = "POTION", target = { kind = "combatant", combatant = 1 } },
      },
    },
  })
  Assert.isTrue(refused:open(bagIntent({ POTION = 5 }, noEffectOptions)), "the refused bag opens")
  walkToMedicine(refused)
  local bagView = refused:status().childView --[[@as table<string, unknown>]]
  local bagRows = bagView.rows --[[@as table<integer, table<string, unknown>>]]
  Assert.equal(
    bagRows[1].reason,
    "MARKER:battle/narration/item-no-effect",
    "refused servings resolve their retail message"
  )
  refused:dispose()
end

---@return table<integer, table<string, unknown>> roster with moves on the reserve
local function moveRoster()
  return {
    { combatant = 1, slot = 0, name = "LEAD", level = 20, hp = 30, maxHp = 30 },
    {
      combatant = 2,
      slot = 1,
      name = "BACK",
      level = 5,
      hp = 10,
      maxHp = 18,
      moves = {
        { move = "TACKLE", name = "Tackle", pp = 5, maxPp = 35 },
        { move = "GROWL", name = "Growl", pp = 40, maxPp = 40 },
      },
    },
  }
end

---@return table<integer, table<string, unknown>> roster with summary facts on the lead
local function summaryRoster()
  return {
    {
      combatant = 1,
      slot = 0,
      name = "LEAD",
      level = 20,
      hp = 30,
      maxHp = 30,
      gender = "male",
      ability = "RUN_AWAY",
      heldItem = "POTION",
      attack = 12,
      defense = 10,
      speed = 11,
      specialAttack = 9,
      specialDefense = 10,
      nextExp = 37,
      moves = {
        { move = "TACKLE", name = "Tackle", pp = 35, maxPp = 35, power = 35, accuracy = 100, category = "physical" },
      },
    },
    { combatant = 2, slot = 1, name = "BACK", level = 5, hp = 10, maxHp = 18 },
  }
end

---@param flows table<string, unknown> coordinator under test driving
---@return table<string, unknown> open summary page view
local function openLeadSummary(flows)
  Assert.isTrue(
    flows:open(partyIntent({ party = summaryRoster(), options = switchOptions(2) })),
    "the party opens"
  )
  Assert.isTrue(flows:activateControl("party:0"), "the lead takes its tap")
  flows:tick()
  Assert.equal(flows:status().childView.partyPage, "mon_menu", "selecting a mon opens its menu")
  drive(flows, { type = "navigate", direction = "down" })
  drive(flows, { type = "confirm" })
  for _ = 1, 8 do
    flows:tick()
  end
  local view = flows:status().childView --[[@as table<string, unknown>]]
  Assert.equal(view.partyPage, "summary", "SUMMARY opens the summary page")
  return view
end

---@param view table<string, unknown> projected child view under inspection
---@return table<string, table<string, unknown>> projected rows by stable identity
local function rowsById(view)
  local rows = view.rows --[[@as table<integer, table<string, unknown>>]]
  local byId = {} ---@type table<string, table<string, unknown>>
  for _, row in ipairs(rows) do
    byId[tostring(row.id)] = row
  end
  return byId
end

-- The summary page shows its staged stat block: mon name and gender,
-- level, remaining experience, HP, the five battle stats, ability, and
-- held item resolve through their msg 0006 keys in retail order ahead of
-- the existing navigation rows.
-- The summary page shows its staged stat block: mon name and gender,
-- level, remaining experience, HP, the five battle stats, ability, and
-- held item resolve through their msg 0006 keys in retail order ahead of
-- the existing navigation rows. The counting resolver pins the exact
-- substitution count behind every template key.
function T.party_summary_shows_its_staged_stat_block()
  local catalog = ItemFixture.makeCatalog()
  local flows = coordinator(catalog, {
    resolveMessage = function(key, subs)
      return "MARKER:" .. tostring(key) .. "#" .. tostring(subs ~= nil and #subs or 0)
    end,
  })
  local view = openLeadSummary(flows)
  local rows = view.rows --[[@as table<integer, table<string, unknown>>]]
  local ids = {}
  for _, row in ipairs(rows) do
    ids[#ids + 1] = row.id
  end
  Assert.deepEqual(ids, {
    "summary:mon",
    "summary:level",
    "summary:exp",
    "summary:hp",
    "summary:attack",
    "summary:defense",
    "summary:speed",
    "summary:sp-attack",
    "summary:sp-defense",
    "summary:ability",
    "summary:item",
    "summary:prev",
    "summary:next",
    "summary:moves",
    "back",
  }, "the summary page carries its stat block in retail order")
  local byId = rowsById(view)
  Assert.equal(
    byId["summary:mon"].label,
    "MARKER:battle/party/mon-name/0#1",
    "the mon row resolves its staged name template with its nickname"
  )
  Assert.equal(
    byId["summary:mon"].sub,
    "MARKER:battle/party/gender/male#0",
    "the mon row resolves its staged gender symbol"
  )
  Assert.equal(
    byId["summary:level"].label,
    "MARKER:battle/party/stat/level#0",
    "level resolves its label"
  )
  Assert.equal(
    byId["summary:level"].detail,
    "MARKER:battle/party/stat/level-value#1",
    "level resolves its value with its count"
  )
  Assert.equal(
    byId["summary:exp"].label,
    "MARKER:battle/party/stat/exp#0",
    "remaining experience resolves its label"
  )
  Assert.equal(
    byId["summary:exp"].detail,
    "MARKER:battle/party/stat/exp-value#1",
    "remaining experience resolves its value with its count"
  )
  Assert.equal(
    byId["summary:hp"].label,
    "MARKER:battle/party/stat/hp#0",
    "HP resolves its label"
  )
  Assert.equal(
    byId["summary:hp"].detail,
    "MARKER:battle/party/stat/hp-current#1MARKER:battle/party/stat/hp-slash#0MARKER:battle/party/stat/hp-max#1",
    "HP resolves its current, slash, and maximum parts"
  )
  Assert.equal(
    byId["summary:attack"].label,
    "MARKER:battle/party/stat/attack#0",
    "attack resolves its staged label"
  )
  Assert.equal(
    byId["summary:attack"].detail,
    "MARKER:battle/party/stat/attack-value#1",
    "attack resolves its staged value with its stat"
  )
  Assert.equal(
    byId["summary:speed"].detail,
    "MARKER:battle/party/stat/speed-value#1",
    "speed resolves its staged value with its stat"
  )
  Assert.equal(
    byId["summary:ability"].label,
    "MARKER:battle/party/ability/name#1",
    "ability resolves its staged template with its name"
  )
  Assert.equal(
    byId["summary:item"].label,
    "MARKER:battle/party/item/name#1",
    "the held item resolves its staged template with its name"
  )
  flows:dispose()
end

-- Without a borrowed message resolver the summary rows keep their
-- English fallbacks: names and numbers stay readable while the suite
-- proves the row structure.
function T.party_summary_falls_back_without_a_resolver()
  local flows = coordinator(ItemFixture.makeCatalog())
  local view = openLeadSummary(flows)
  local byId = rowsById(view)
  Assert.equal(byId["summary:mon"].label, "LEAD", "the mon row falls back to its name")
  Assert.equal(byId["summary:mon"].sub, "♂", "the mon row falls back to its gender symbol")
  Assert.equal(byId["summary:level"].label, "Lv.", "level falls back to its retail label")
  Assert.equal(byId["summary:level"].detail, "20", "level falls back to its number")
  Assert.equal(byId["summary:exp"].label, "NEXT LV", "remaining experience falls back to its label")
  Assert.equal(byId["summary:exp"].detail, "37", "remaining experience falls back to its count")
  Assert.equal(byId["summary:hp"].detail, "30/30", "HP falls back to its counts")
  Assert.equal(byId["summary:attack"].label, "ATTACK", "attack falls back to its label")
  Assert.equal(byId["summary:attack"].detail, "12", "attack falls back to its number")
  Assert.equal(byId["summary:sp-defense"].detail, "10", "special defense falls back to its number")
  Assert.equal(byId["summary:ability"].label, "RUN_AWAY", "ability falls back to its key")
  -- The unit coordinator borrows the item catalog but no mon catalog:
  -- the held item resolves through the catalog while the ability keeps
  -- its key.
  Assert.equal(byId["summary:item"].label, "Potion", "the held item resolves through the item catalog")
  flows:dispose()
end

-- The move list names its entries through their staged per-slot
-- templates while keeping the existing PP facts.
function T.party_move_list_labels_resolve_their_staged_names()
  local catalog = ItemFixture.makeCatalog()
  local flows = coordinator(catalog, {
    resolveMessage = function(key, subs)
      return "MARKER:" .. tostring(key) .. "#" .. tostring(subs ~= nil and #subs or 0)
    end,
  })
  local view = openLeadSummary(flows)
  Assert.isTrue(flows:activateControl("summary:moves"), "the summary moves button takes its tap")
  flows:tick()
  local moves = flows:status().childView --[[@as table<string, unknown>]]
  Assert.equal(moves.partyPage, "moves", "CHECK MOVES opens the move list")
  local byId = rowsById(moves)
  Assert.equal(
    byId["move:0"].label,
    "MARKER:battle/party/move-name/0#1",
    "the move resolves its staged per-slot template with its name"
  )
  Assert.equal(
    byId["move:0"].sub,
    "MARKER:battle/party/move/pp#0 35/35",
    "the move keeps its staged PP facts"
  )
  flows:dispose()
end

-- The move-detail page shows its staged words: mon name, move name,
-- power, accuracy, category, and the PP parts through their msg 0006
-- keys.
function T.party_move_detail_shows_its_staged_words()
  local catalog = ItemFixture.makeCatalog()
  local flows = coordinator(catalog, {
    resolveMessage = function(key, subs)
      return "MARKER:" .. tostring(key) .. "#" .. tostring(subs ~= nil and #subs or 0)
    end,
  })
  local view = openLeadSummary(flows)
  Assert.isTrue(flows:activateControl("summary:moves"), "the summary moves button takes its tap")
  flows:tick()
  Assert.isTrue(flows:activateControl("move:0"), "the first move takes its tap")
  flows:tick()
  local detail = flows:status().childView --[[@as table<string, unknown>]]
  Assert.equal(detail.partyPage, "move_detail", "a move opens its detail")
  local byId = rowsById(detail)
  Assert.equal(
    byId["move_detail:mon"].label,
    "MARKER:battle/party/mon-name/0#1",
    "the detail resolves its staged mon-name template"
  )
  Assert.equal(
    byId["move_detail:move"].label,
    "MARKER:battle/party/move-name/0#1",
    "the detail resolves its staged move-name template with its name"
  )
  Assert.equal(
    byId["move_detail:power"].label,
    "MARKER:battle/party/move/power#0",
    "power resolves its staged label"
  )
  Assert.equal(
    byId["move_detail:power"].detail,
    "MARKER:battle/party/move/power-value#1",
    "power resolves its staged value with its count"
  )
  Assert.equal(
    byId["move_detail:accuracy"].detail,
    "MARKER:battle/party/move/accuracy-value#1",
    "accuracy resolves its staged value with its count"
  )
  Assert.equal(
    byId["move_detail:category"].detail,
    "MARKER:battle/party/move/category-physical#0",
    "the category resolves its staged physical word"
  )
  Assert.equal(
    byId["move_detail:pp"].label,
    "MARKER:battle/party/move/pp-label#0",
    "the detail PP resolves its staged header"
  )
  Assert.equal(
    byId["move_detail:pp"].detail,
    "MARKER:battle/party/move/pp-current#1MARKER:battle/party/move/pp-slash#0MARKER:battle/party/move/pp-max#1",
    "the detail PP resolves its current, slash, and maximum parts"
  )
  flows:dispose()
end

-- The last-used shortcut honors the intent: a stocked last-used item
-- enables its row with its icon demand, while an absent or unstocked
-- one stays disabled without sound.
function T.bag_last_used_shortcut_honors_its_intent()
  local catalog = ItemFixture.makeCatalog()
  local flows = coordinator(catalog)
  local intent = bagIntent({ POTION = 5 }, itemOptions({}))
  intent.lastUsed = { item = "POTION", pocket = 0 }
  Assert.isTrue(flows:open(intent), "the stocked last-used bag opens")
  local view = flows:status().childView --[[@as table<string, unknown>]]
  local rows = view.rows --[[@as table<integer, table<string, unknown>>]]
  local lastUsed = nil
  for _, row in ipairs(rows) do
    if row.id == "last_used" then
      lastUsed = row
    end
  end
  Assert.notNil(lastUsed, "the pocket menu carries its last-used row")
  assert(lastUsed ~= nil, "the last-used row resolved")
  Assert.isTrue(lastUsed.enabled, "the stocked shortcut enables its row")
  Assert.isNil(lastUsed.empty, "the stocked shortcut paints its row")
  flows:dispose()
  local bare = coordinator(catalog)
  Assert.isTrue(bare:open(bagIntent({ POTION = 5 }, itemOptions({}))), "the plain bag opens")
  local bareView = bare:status().childView --[[@as table<string, unknown>]]
  local bareRows = bareView.rows --[[@as table<integer, table<string, unknown>>]]
  for _, row in ipairs(bareRows) do
    if row.id == "last_used" then
      Assert.isFalse(row.enabled == true, "no source keeps the shortcut disabled")
    end
  end
  bare:dispose()
end

function T.party_summary_and_check_moves_navigate_without_sealing()
  local catalog = ItemFixture.makeCatalog()
  local plays = {}
  local flows = coordinator(catalog, {
    audioEffect = function(symbol)
      plays[#plays + 1] = symbol
    end,
  })
  Assert.isTrue(flows:open(partyIntent({ party = moveRoster(), options = switchOptions(2) })), "the party opens")
  Assert.isTrue(flows:activateControl("party:1"), "the reserve takes its tap")
  flows:tick()
  Assert.isNil(flows:takeResult(), "opening the mon menu seals nothing")
  local menu = flows:status().childView
  Assert.equal(menu.partyPage, "mon_menu", "selecting a mon opens its menu")
  -- SUMMARY is the second mon-menu entry for non-eggs. The menu press
  -- gate arms and dispatches across ticks, like the native Switch press.
  drive(flows, { type = "navigate", direction = "down" })
  drive(flows, { type = "confirm" })
  for _ = 1, 8 do
    flows:tick()
  end
  Assert.isNil(flows:takeResult(), "SUMMARY seals no reply")
  Assert.equal(flows:status().childView.partyPage, "summary", "SUMMARY opens the summary page")
  Assert.equal(plays[#plays], "SEQ_SE_DP_DECIDE", "opening summary voices decide")
  -- Prev/next mon steps across occupied slots without sealing.
  drive(flows, { type = "navigate", direction = "left" })
  Assert.isNil(flows:takeResult(), "summary paging seals no reply")
  Assert.equal(flows:status().childView.pageSlot, 0, "left steps to the lead mon")
  Assert.equal(plays[#plays], "SEQ_SE_DP_DECIDE", "summary paging voices decide")
  drive(flows, { type = "navigate", direction = "right" })
  Assert.equal(flows:status().childView.pageSlot, 1, "right steps back to the reserve")
  -- CHECK MOVES from the summary page opens the move list.
  Assert.isTrue(flows:activateControl("summary:moves"), "the summary moves button takes its tap")
  flows:tick()
  Assert.isNil(flows:takeResult(), "CHECK MOVES seals no reply")
  Assert.equal(flows:status().childView.partyPage, "moves", "moves opens the move list")
  -- Move detail opens from the move list without sealing.
  Assert.isTrue(flows:activateControl("move:0"), "the first move takes its tap")
  flows:tick()
  Assert.isNil(flows:takeResult(), "move detail seals no reply")
  Assert.equal(flows:status().childView.partyPage, "move_detail", "a move opens its detail")
  drive(flows, { type = "cancel" })
  Assert.equal(flows:status().childView.partyPage, "moves", "detail back returns to the move list")
  Assert.equal(plays[#plays], "SEQ_SE_DP_DECIDE", "detail back voices decide")
  Assert.isTrue(flows:activateControl("moves:summary"), "the moves summary button takes its tap")
  flows:tick()
  Assert.equal(flows:status().childView.partyPage, "summary", "moves summary returns to summary")
  drive(flows, { type = "cancel" })
  Assert.equal(flows:status().childView.partyPage, "mon_menu", "summary back returns to the mon menu")
  Assert.equal(plays[#plays], "SEQ_SE_DP_DECIDE", "summary back voices decide")
  flows:dispose()
end

function T.party_eggs_offer_only_shift_and_back()
  local flows = coordinator()
  local roster = {
    { combatant = 1, slot = 0, name = "LEAD", level = 20, hp = 30, maxHp = 30 },
    { combatant = 2, slot = 1, name = "EGG", level = 5, hp = 10, maxHp = 18, isEgg = true },
  }
  Assert.isTrue(flows:open(partyIntent({ party = roster, options = switchOptions(2) })), "the egg roster opens")
  Assert.isTrue(flows:activateControl("party:1"), "the egg takes its tap")
  flows:tick()
  local menu = flows:status().childView
  Assert.equal(menu.partyPage, "mon_menu", "selecting the egg opens its menu")
  local labels = {}
  for _, row in ipairs(menu.rows) do
    labels[#labels + 1] = row.id
  end
  Assert.deepEqual(labels, { "switch", "back" }, "eggs hide summary and check-moves")
  flows:dispose()
end

-- Retail party-target embargo (battle_party_menu.c TryUseItemOnMon msg 95,
-- battle/party/message/embargo): the chosen mon is refused while its
-- field slot carries Embargo, resetting the selection instead of
-- sealing, while a healthy holder still seals. Subs name the Embargo
-- move and the holder nickname like the bag embargo message.
function T.item_target_embargo_refuses_its_slot_while_healthy_seals()
  local catalog = ItemFixture.makeCatalog()
  local flows = coordinator(catalog, {
    resolveMessage = function(key, subs)
      return "MARKER:" .. tostring(key) .. "#" .. tostring(subs ~= nil and #subs or 0)
    end,
  })
  local options = itemOptions({ itemChoice("POTION", 1, true), itemChoice("POTION", 2, true) })
  local roster = {
    { combatant = 1, slot = 0, name = "LEAD", level = 20, hp = 30, maxHp = 30, embargoed = true },
    { combatant = 2, slot = 1, name = "BACK", level = 5, hp = 10, maxHp = 18 },
  }
  local intent = bagIntent({ POTION = 5 }, options)
  intent.party = roster
  Assert.isTrue(flows:open(intent), "the stocked bag opens")
  walkToMedicine(flows)
  useBagItem(flows)
  Assert.equal(flows:status().kind, "target", "the serving opens its target list")
  -- The embargoed lead refuses with its staged party message instead
  -- of sealing: the picker shows the text over the list and keeps the
  -- target open.
  Assert.isTrue(flows:activateControl("party:0"), "the embargoed slot takes its tap")
  flows:tick()
  flows:tick()
  Assert.isNil(flows:takeResult(), "the embargoed slot seals no reply")
  local refused = flows._composed._target._controller:status()
  Assert.equal(
    refused.message,
    "MARKER:battle/party/message/embargo#2",
    "the embargoed slot names its staged party key with move and holder"
  )
  -- Dismiss the refusal back to the target list, like retail resetting
  -- selectedMon to 6 instead of sealing.
  drive(flows, { type = "confirm" })
  flows:tick()
  -- A healthy holder still seals its kernel fragment.
  Assert.isTrue(flows:activateControl("party:1"), "the healthy slot takes its tap")
  flows:tick()
  flows:tick()
  local result = flows:takeResult()
  Assert.notNil(result, "the healthy slot seals its reply")
  Assert.equal(result.kind, "choice", "the healthy slot stages a choice")
  Assert.equal(result.reply.choices[1].payload.target.combatant, 2, "the healthy fragment names its holder")
  flows:dispose()
end

return { tests = T }
