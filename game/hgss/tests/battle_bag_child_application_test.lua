-- Frozen battle-bag acceptance: the in-battle Bag is the retail battle
-- browser (pocket menu, item list, use-item pages), not a generic row
-- projection. A stocked bag opens over detached battle stock, pocket
-- travel and focused item identity follow the retail battle-pocket order,
-- confirming a legal serving stages target selection rather than sealing
-- a reply, cancelling the target restores the resting browser, and the
-- detached stock map is never mutated by browsing. The battle child
-- composition module owns the flow with a bag application receipt on
-- the child view. Live field inventory publication stays with the
-- battle committer; the per-launch completion ledger that proves it is
-- covered by the failure-isolation suite.

local Assert = require("tests.support.Assert")
local ItemFixture = require("libs.items.tests.item_fixture")

local BattleSubflows = require("game.hgss.src.battle.BattleSubflows")

local COMPOSER_MODULE = "game.hgss.src.battle.BattleChildApplications"

local T = {}

---@param catalog table<string, unknown>? borrowed immutable item catalog
---@return table<string, unknown> battle child coordinator under test driving
local function coordinator(catalog)
  return BattleSubflows.new({ launchId = "launch-bag-child", itemCatalog = catalog })
end

---@return table<integer, table<string, unknown>> detached own-party snapshot
local function twoEeveeRoster()
  return {
    { combatant = 1, slot = 0, name = "LEAD", level = 20, hp = 30, maxHp = 30 },
    { combatant = 2, slot = 1, name = "BACK", level = 5, hp = 10, maxHp = 18 },
  }
end

---@param key string staged item identity under projection
---@param holder integer choice target combatant under projection
---@return table<string, unknown> native item choice for the synthetic options
local function itemChoice(key, holder)
  return {
    id = "item:" .. key .. ":" .. tostring(holder),
    role = "item",
    enabled = true,
    reason = "refused",
    display = { item = key },
    choice = {
      actor = { combatant = 1, activation = 5 },
      kind = "item",
      payload = { item = key, target = { kind = "combatant", combatant = holder } },
    },
  }
end

---@return table<string, unknown> detached action options projecting one serving
local function servingOptions()
  return {
    requestId = 7,
    epoch = 3,
    controller = "player",
    kind = "action",
    actors = { { combatant = 1, activation = 5, kind = "action", choices = { itemChoice("POTION", 1) } } },
  }
end

---@param inventory table<string, integer> battle stock under test preparation
---@return table<string, unknown> bag selection intent for the synthetic request
local function bagIntent(inventory)
  return {
    kind = "bag",
    purpose = "bag",
    launchId = "launch-bag-child",
    requestId = 7,
    epoch = 3,
    controller = "player",
    cancellable = true,
    request = { requestId = 7, epoch = 3, controller = "player", kind = "action" },
    options = servingOptions(),
    party = twoEeveeRoster(),
    inventory = inventory,
  }
end

---@param flows table<string, unknown> coordinator under test driving
---@param event table<string, unknown> semantic input under test driving
local function drive(flows, event)
  flows:update({ event })
  flows:tick()
end

-- Settles one gated button press (WaitButtonAnim): frame 1 rebounds
-- to frame 2, then the deferred page transition applies.
---@param flows table<string, unknown> coordinator resting on the open bag child
local function settlePress(flows)
  flows:tick()
  flows:tick()
end

---@param flows table<string, unknown> coordinator resting on the open bag child
local function walkToMedicine(flows)
  Assert.isTrue(flows:activateControl("bagpocket:0"), "the HP/PP pocket takes its tap")
  flows:tick()
  settlePress(flows)
end

function T.stocked_bag_opens_stages_and_cancels_without_touching_detached_stock()
  local catalog = ItemFixture.makeCatalog()
  local flows = coordinator(catalog)
  local inventory = { POTION = 5 }
  Assert.isTrue(flows:open(bagIntent(inventory)), "the stocked bag opens")
  Assert.equal(flows:status().kind, "bag", "the open child is the bag")
  walkToMedicine(flows)
  drive(flows, { type = "confirm" })
  settlePress(flows)
  drive(flows, { type = "confirm" })
  for _ = 1, 8 do
    flows:tick()
  end
  Assert.isNil(flows:takeResult(), "staging the serving seals no reply")
  Assert.isTrue(flows:status().active, "staging keeps the child")
  Assert.equal(flows:status().stagedItem, "POTION", "the staged key is remembered")
  Assert.deepEqual(inventory, { POTION = 5 }, "browsing and staging never mutate the detached stock")
  drive(flows, { type = "cancel" })
  Assert.equal(flows:status().kind, "bag", "cancelling the target restores the resting browser")
  Assert.equal(flows:status().childView.bagPage, "item_list", "the restored browser lists its pocket")
  Assert.isNil(flows:takeResult(), "the restored browser seals nothing on its own")
  drive(flows, { type = "cancel" })
  settlePress(flows)
  Assert.equal(flows:status().childView.bagPage, "pocket_menu", "list cancel returns to the pocket menu")
  Assert.isNil(flows:takeResult(), "the pocket menu seals nothing on its own")
  drive(flows, { type = "cancel" })
  local result = flows:takeResult()
  Assert.notNil(result, "bag cancel stages a result")
  Assert.equal(result.kind, "cancelled", "bag cancel reports a navigation cancellation")
  Assert.equal(result.requestId, 7, "the cancellation answers the open request")
  Assert.equal(result.launchId, "launch-bag-child", "the cancellation answers the open launch")
  flows:dispose()
end

function T.bag_child_is_built_by_the_battle_child_composer()
  local ok, composer = pcall(require, COMPOSER_MODULE)
  Assert.isTrue(ok, "the battle bag child is composed by the battle child module (" .. COMPOSER_MODULE .. ")")
  assert(composer ~= nil, "the composer loads")
end

function T.bag_child_view_carries_the_native_bag_application_receipt()
  local catalog = ItemFixture.makeCatalog()
  local flows = coordinator(catalog)
  Assert.isTrue(flows:open(bagIntent({ POTION = 5 })), "the stocked bag opens")
  walkToMedicine(flows)
  local view = flows:status().childView
  Assert.notNil(view, "the open bag exposes its child view")
  Assert.equal(view.kind, "bag", "the child view names the bag")
  local stocked = false
  for _, row in ipairs(view.rows) do
    if row.label == "Potion" then
      stocked = true
    end
  end
  Assert.isTrue(stocked, "setup: the stocked serving is visible before the receipt check")
  Assert.equal(view.application, "bag", "the bag view carries its native application receipt")
  flows:dispose()
end

-- Every ready version replays the frozen stocked-bag flow through its own
-- owned item catalog: the real catalog stocks the same POTION key, pocket
-- travel lands on the same staged serving, and staging plus cancelling
-- seal the identical receipts without touching the detached stock. The
-- catalog comes from the versioned cache, never from a shared fallback,
-- so a version skew in item identities fails here instead of hiding
-- behind the synthetic fixture.
function T.versioned_item_catalogs_replay_the_stocked_bag_flow(context)
  local GameVersion = require("romdump.src.source.GameVersion")
  local RomImporter = require("romdump.src.source.RomImporter")
  local MonBucket = require("tests.support.MonBucket")
  local versions = {}
  for _, versionId in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(versionId) then
      versions[#versions + 1] = versionId
    end
  end
  if #versions == 0 then
    context:skip("the versioned bag flow needs a ready user-owned dump with a derived cache")
  end
  for _, versionId in ipairs(versions) do
    local _, items = MonBucket.openCatalogs(versionId)
    local stocked, stockErr = pcall(function()
      return items:item("POTION")
    end)
    Assert.isTrue(stocked, "the owned " .. versionId .. " catalog stocks POTION: " .. tostring(stockErr))
    local flows = BattleSubflows.new({ launchId = "launch-bag-child", itemCatalog = items })
    local inventory = { POTION = 5 }
    Assert.isTrue(flows:open(bagIntent(inventory)), "the stocked bag opens on " .. versionId)
    walkToMedicine(flows)
    local view = flows:status().childView
    Assert.notNil(view, "the open bag exposes its child view on " .. versionId)
    Assert.equal(view.application, "bag", "the bag view carries its native application receipt on " .. versionId)
    drive(flows, { type = "confirm" })
    settlePress(flows)
    drive(flows, { type = "confirm" })
    for _ = 1, 8 do
      flows:tick()
    end
    Assert.isNil(flows:takeResult(), "staging the serving seals no reply on " .. versionId)
    local staged = flows:status()
    Assert.equal(
      staged.stagedItem,
      "POTION",
      "the staged key is remembered on " .. versionId
        .. ")"
    )
    Assert.deepEqual(inventory, { POTION = 5 }, "browsing never mutates the detached stock on " .. versionId)
    drive(flows, { type = "cancel" })
    Assert.equal(flows:status().childView.bagPage, "item_list", "the restored browser lists on " .. versionId)
    Assert.isNil(flows:takeResult(), "the restored browser seals nothing on its own on " .. versionId)
    drive(flows, { type = "cancel" })
    settlePress(flows)
    Assert.isNil(flows:takeResult(), "the pocket menu seals nothing on its own on " .. versionId)
    drive(flows, { type = "cancel" })
    local result = flows:takeResult()
    Assert.notNil(result, "bag cancel stages a result on " .. versionId)
    Assert.equal(result.kind, "cancelled", "bag cancel reports a navigation cancellation on " .. versionId)
    Assert.equal(result.requestId, 7, "the cancellation answers the open request on " .. versionId)
    Assert.equal(result.launchId, "launch-bag-child", "the cancellation answers the open launch on " .. versionId)
    flows:dispose()
  end
end

-- Retail catching-tutorial auto-play (battle_bag_menu.c RunTutorial):
-- the lesson finger owns the bag behind intent.isTutorial, so finger
-- touches advance balls → first cell → USE while navigation and cancel
-- are ignored, the finger centers on its per-page spot, and the lesson
-- throw seals its kernel fragment. Interactive browsers keep taking
-- input (covered above).
function T.tutorial_bag_auto_plays_behind_the_finger()
  local BattleBagPockets = require("game.hgss.src.battle.BattleBagPockets")
  local catalog = ItemFixture.makeCatalog()
  local flows = coordinator(catalog)
  local ballChoice = itemChoice("POKE_BALL", 3)
  local intent = bagIntent({ POKE_BALL = 1 })
  intent.options = {
    requestId = 7,
    epoch = 3,
    controller = "player",
    kind = "action",
    actors = { { combatant = 1, activation = 5, kind = "action", choices = { ballChoice } } },
  }
  intent.isTutorial = true
  Assert.isTrue(flows:open(intent), "the lesson bag opens")
  local function fingerSpot()
    local native = flows:status().childView.native
    Assert.isTrue(native.tutorial == true, "the lesson browser marks its tutorial")
    local finger = BattleBagPockets.fingerDraw(native)
    Assert.notNil(finger, "the lesson finger draws")
    return finger
  end
  Assert.equal(flows:status().childView.bagPage, "pocket_menu", "the lesson opens on the pocket menu")
  Assert.deepEqual(
    { x = fingerSpot().x, y = fingerSpot().y },
    { x = 192, y = 24 },
    "the finger starts over the balls button"
  )
  drive(flows, { type = "navigate", direction = "right" })
  Assert.equal(
    flows:status().childView.focusId,
    "bagpocket:0",
    "navigation never moves the lesson finger"
  )
  drive(flows, { type = "cancel" })
  Assert.isNil(flows:takeResult(), "cancel never leaves the lesson")
  Assert.equal(flows:status().childView.bagPage, "pocket_menu", "cancel keeps the pocket menu")
  drive(flows, { type = "confirm" })
  Assert.equal(
    flows:status().childView.bagPage,
    "pocket_menu",
    "confirm keys never advance the lesson (retail reads only the finger)"
  )
  Assert.isTrue(flows:activateControl("bagpocket:2"), "the finger touch taps the balls button")
  flows:tick()
  settlePress(flows)
  Assert.equal(flows:status().childView.bagPage, "item_list", "the first touch opens the balls pocket")
  Assert.deepEqual(
    { x = fingerSpot().x, y = fingerSpot().y },
    { x = 64, y = 16 },
    "the finger follows to the first cell"
  )
  Assert.isTrue(flows:activateControl("bag:0"), "the finger touch taps the first cell")
  flows:tick()
  settlePress(flows)
  Assert.equal(flows:status().childView.bagPage, "use_item", "the second touch opens the use page")
  Assert.deepEqual(
    { x = fingerSpot().x, y = fingerSpot().y },
    { x = 104, y = 152 },
    "the finger follows to USE"
  )
  Assert.isTrue(flows:activateControl("use"), "the finger touch taps USE")
  flows:tick()
  Assert.deepEqual(
    flows:status().childView.native.anim,
    { button = 15, frame = 1 },
    "USE stages its dip fire-and-forget behind the intent"
  )
  local result = flows:takeResult()
  Assert.notNil(result, "the lesson touch seals its throw")
  Assert.equal(result.kind, "choice", "the lesson throw stages a choice")
  Assert.deepEqual(result.reply.choices[1], ballChoice.choice, "the throw copies its kernel fragment")
  flows:dispose()
end

-- Retail press dip (WaitButtonAnim): a gated press shows frame 1,
-- rebounds to frame 2, then applies its page transition; every edge in
-- between is dropped. USE fires its intent at once instead.
function T.gated_presses_wait_out_the_dip_before_turning()
  local catalog = ItemFixture.makeCatalog()
  local flows = coordinator(catalog)
  Assert.isTrue(flows:open(bagIntent({ POTION = 1 })), "the stocked bag opens")
  Assert.isTrue(flows:activateControl("bagpocket:0"), "the HP/PP pocket takes its tap")
  flows:tick()
  Assert.deepEqual(
    flows:status().childView.native.anim,
    { button = 0, frame = 1 },
    "the press dips its button on frame 1"
  )
  Assert.equal(flows:status().childView.bagPage, "pocket_menu", "frame 1 keeps the old page")
  drive(flows, { type = "navigate", direction = "down" })
  Assert.deepEqual(
    flows:status().childView.native.anim,
    { button = 0, frame = 2 },
    "the dip rebounds to frame 2 while the edge drops"
  )
  Assert.equal(flows:status().childView.bagPage, "pocket_menu", "dropped edges never turn the page")
  flows:tick()
  Assert.isNil(flows:status().childView.native.anim, "the rebound lifts the gate")
  Assert.equal(flows:status().childView.bagPage, "item_list", "the transition applies after the dip")
  flows:dispose()
end

-- Retail cursor visibility (BattleDpadCursor active flag): hidden until
-- the first key press, cleared again by touch.
function T.cursor_hides_until_keys_and_clears_on_touch()
  local catalog = ItemFixture.makeCatalog()
  local flows = coordinator(catalog)
  Assert.isTrue(flows:open(bagIntent({ POTION = 1 })), "the stocked bag opens")
  Assert.isFalse(flows:status().childView.native.cursorActive, "fresh browsers hide the cursor")
  drive(flows, { type = "navigate", direction = "right" })
  Assert.isTrue(flows:status().childView.native.cursorActive, "the first key shows the cursor")
  Assert.isTrue(flows:activateControl("bagpocket:2"), "touch takes the balls pocket")
  flows:tick()
  Assert.isFalse(
    flows:status().childView.native.cursorActive,
    "touch clears the cursor while the tap still travels"
  )
  settlePress(flows)
  Assert.equal(flows:status().childView.bagPage, "item_list", "the touch still turns the page")
  flows:dispose()
end

-- Retail use-item cursor (sBattleBagPage2CursorBoxes): USE holds
-- up/down and Back holds up/down; only left/right toggles.
function T.use_item_dpad_holds_vertical_motion()
  local catalog = ItemFixture.makeCatalog()
  local flows = coordinator(catalog)
  local intent = bagIntent({ POTION = 1 })
  Assert.isTrue(flows:open(intent), "the stocked bag opens")
  Assert.isTrue(flows:activateControl("bagpocket:0"), "the HP/PP pocket takes its tap")
  flows:tick()
  settlePress(flows)
  Assert.isTrue(flows:activateControl("bag:0"), "the cell takes its tap")
  flows:tick()
  settlePress(flows)
  Assert.equal(flows:status().childView.bagPage, "use_item", "the cell opens its use page")
  Assert.equal(flows:status().childView.focusId, "use", "USE starts focused")
  drive(flows, { type = "navigate", direction = "up" })
  Assert.equal(flows:status().childView.focusId, "use", "up holds USE")
  drive(flows, { type = "navigate", direction = "down" })
  Assert.equal(flows:status().childView.focusId, "use", "down holds USE")
  drive(flows, { type = "navigate", direction = "right" })
  Assert.equal(flows:status().childView.focusId, "back", "right toggles to Back")
  drive(flows, { type = "navigate", direction = "up" })
  Assert.equal(flows:status().childView.focusId, "back", "up holds Back")
  drive(flows, { type = "navigate", direction = "left" })
  Assert.equal(flows:status().childView.focusId, "use", "left toggles to USE")
  flows:dispose()
end

return {
  tests = T,
  metadata = {
    capabilities = { "rom_dump", "derived_assets" },
    derivedAssets = { "mon-catalog:global", "items:global" },
  },
}
