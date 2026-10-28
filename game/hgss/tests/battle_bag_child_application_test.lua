-- Frozen battle-bag acceptance: the in-battle Bag must be the native Bag
-- application, not a generic row projection. A stocked bag opens over
-- detached battle stock, pocket travel and focused item identity follow the
-- native pocket order, confirming a legal serving stages target selection
-- rather than sealing a reply, cancelling the target restores the resting
-- browser, and the detached stock map is never mutated by browsing.
--
-- Dependency note: the battle child composition module is missing, so the
-- current child still renders generic bag rows and no native Bag controller
-- owns the flow. The red tests below pin that miss: composition-module
-- ownership and a native application receipt on the child view. Live field
-- inventory publication stays with the battle committer; the per-launch
-- completion ledger that proves it is covered by the failure-isolation
-- suite.

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

---@param flows table<string, unknown> coordinator resting on the open bag child
local function walkToMedicine(flows)
  drive(flows, { type = "navigate", direction = "up" })
  drive(flows, { type = "navigate", direction = "right" })
  drive(flows, { type = "navigate", direction = "down" })
end

function T.stocked_bag_opens_stages_and_cancels_without_touching_detached_stock()
  local catalog = ItemFixture.makeCatalog()
  local flows = coordinator(catalog)
  local inventory = { POTION = 5 }
  Assert.isTrue(flows:open(bagIntent(inventory)), "the stocked bag opens")
  Assert.equal(flows:status().kind, "bag", "the open child is the bag")
  walkToMedicine(flows)
  drive(flows, { type = "confirm" })
  flows:tick()
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
  Assert.isNil(flows:takeResult(), "the restored browser seals nothing on its own")
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
    flows:tick()
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
    Assert.isNil(flows:takeResult(), "the restored browser seals nothing on its own on " .. versionId)
    drive(flows, { type = "cancel" })
    local result = flows:takeResult()
    Assert.notNil(result, "bag cancel stages a result on " .. versionId)
    Assert.equal(result.kind, "cancelled", "bag cancel reports a navigation cancellation on " .. versionId)
    Assert.equal(result.requestId, 7, "the cancellation answers the open request on " .. versionId)
    Assert.equal(result.launchId, "launch-bag-child", "the cancellation answers the open launch on " .. versionId)
    flows:dispose()
  end
end

return {
  tests = T,
  metadata = {
    capabilities = { "rom_dump", "derived_assets" },
    derivedAssets = { "mon-catalog:global", "items:global" },
  },
}
