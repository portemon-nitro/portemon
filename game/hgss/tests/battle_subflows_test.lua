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
local function coordinator(catalog)
  if BattleSubflows == nil then
    BattleSubflows = require("game.hgss.src.battle.BattleSubflows")
  end
  return BattleSubflows.new({ launchId = "launch-child-unit", itemCatalog = catalog })
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

function T.voluntary_party_selection_seals_the_projected_reserve_fragment()
  local flows = coordinator()
  local options = switchOptions(2)
  local ok, openErr = flows:open(partyIntent({ options = options }))
  Assert.isTrue(ok, "the voluntary party child opens: " .. tostring(openErr))
  -- Focus rests on the eligible reserve, so confirming seals at once and
  -- the reply carries the opening launch and request identity with the
  -- projected fragment untouched.
  drive(flows, { type = "confirm" })
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
  -- Only the eligible reserve leaves the state.
  drive(flows, { type = "confirm" })
  local result = flows:takeResult()
  Assert.notNil(result, "the reserve stages its reply")
  Assert.equal(result.kind, "choice", "the reserve stages a choice")
  flows:dispose()
end

function T.ineligible_party_slots_stay_unfocusable()
  local flows = coordinator()
  local options = switchOptions(2)
  Assert.isTrue(flows:open(partyIntent({ options = options })), "the voluntary party child opens")
  -- The owned screen never rests focus on an inadmissible slot:
  -- stepping up from the eligible reserve holds the reserve, so
  -- confirming still seals the projected reserve fragment and the
  -- active lead can never intercept the choice.
  drive(flows, { type = "navigate", direction = "up" })
  drive(flows, { type = "confirm" })
  local result = flows:takeResult()
  Assert.notNil(result, "confirming seals the eligible reserve")
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
  drive(flows, { type = "confirm" })
  local result = flows:takeResult()
  Assert.notNil(result, "confirming the reserve stages its reply")
  Assert.deepEqual(result.reply.choices[1], options.actors[1].choices[1].choice, "the reply names the reserve")
  flows:dispose()
end

function T.party_screen_disposes_on_close_and_reopens_cleanly()
  local flows = coordinator()
  Assert.isTrue(flows:open(partyIntent({})), "the first child opens")
  drive(flows, { type = "confirm" })
  Assert.notNil(flows:takeResult(), "the first child stages its reply")
  flows:closeChild()
  Assert.isFalse(flows:status().active, "closing settles the child")
  Assert.isNil(flows:takeResult(), "closing seals no late reply")
  local reopened = partyIntent({ requestId = 8, epoch = 9 })
  Assert.isTrue(flows:open(reopened), "the replacement child opens on a fresh screen")
  drive(flows, { type = "confirm" })
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
local function walkToMedicine(flows)
  drive(flows, { type = "navigate", direction = "up" })
  drive(flows, { type = "navigate", direction = "right" })
  drive(flows, { type = "navigate", direction = "down" })
end

---@param flows table<string, unknown> coordinator resting on the open bag child
local function walkToBalls(flows)
  drive(flows, { type = "navigate", direction = "up" })
  drive(flows, { type = "navigate", direction = "right" })
  drive(flows, { type = "navigate", direction = "right" })
  drive(flows, { type = "navigate", direction = "down" })
end

function T.bag_healing_stages_its_target_and_cancels_back_to_the_bag()
  local catalog = ItemFixture.makeCatalog()
  local flows = coordinator(catalog)
  local options = itemOptions({ itemChoice("POTION", 1, true) })
  Assert.isTrue(flows:open(bagIntent({ POTION = 5 }, options)), "the stocked bag opens")
  walkToMedicine(flows)
  drive(flows, { type = "confirm" })
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
  drive(flows, { type = "confirm" })
  drive(flows, { type = "confirm" })
  local result = flows:takeResult()
  Assert.notNil(result, "accepting the serving stages its reply")
  Assert.equal(result.kind, "choice", "the serving stages a choice")
  Assert.deepEqual(result.reply.choices[1], potion.choice, "the serving copies the native fragment")
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
  drive(flows, { type = "confirm" })
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
  drive(flows, { type = "confirm" })
  Assert.isNil(flows:takeResult(), "confirming a refused ball seals no reply")
  Assert.isTrue(flows:status().active, "the refusal keeps the child")
  Assert.isTrue(type(flows:status().notice) == "string", "the refusal names its reason")
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

function T.empty_bag_opens_and_cancels_without_a_catalog()
  local flows = coordinator(nil)
  local options = itemOptions({})
  Assert.isTrue(flows:open(bagIntent({}, options)), "the empty bag needs no catalog")
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
  drive(flows, { type = "confirm" })
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

return { tests = T }
