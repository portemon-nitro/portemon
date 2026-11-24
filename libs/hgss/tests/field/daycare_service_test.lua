-- The Day Care feature service: canonical custody transfer between the party
-- and the stored slots, the source deposit copy shape, growth and price reads
-- that never mutate, withdrawal restoration with crossed-level learning, the
-- deposit statistic, the one committed-step feed, the source form sanitize, and
-- the two reserved yard objects.

local Assert = require("tests.support.Assert")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local DaycareService = require("libs.hgss.src.field.DaycareService")
local DaycareState = require("libs.hgss.src.save.DaycareState")
local Experience = require("libs.mons.src.gen4.Experience")
local GameStats = require("libs.hgss.src.mons.GameStats")
local HgssBagService = require("libs.hgss.src.items.HgssBagService")
local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
local ItemFixture = require("libs.items.tests.item_fixture")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local MonsSave = require("libs.mons.src.MonsSave")
local Party = require("libs.mons.src.Party")

local T = {}

local function speciesRefs(catalog)
  return { species = { CHIKORITA = true, TOTODILE = true, EEVEE = true, PICHU = true, SHEDINJA = true, EGG = true } }
end

local function newMons(catalog, seed)
  local service = HgssMonService.new({
    catalog = catalog,
    bucket = MonsSave.capture(Party.new():capture(), Lcrng.new(seed):capture()),
    profile = CatalogFixture.profile(),
    game = "heartgold",
    language = "english",
    charmap = CatalogFixture.CHARMAP,
    games = CatalogFixture.GAMES,
    languages = CatalogFixture.LANGUAGES,
    items = CatalogFixture.ITEMS,
    balls = CatalogFixture.BALLS,
    mapSection = 7,
    date = CatalogFixture.metDate(),
  })
  return service
end

-- A recording actor owner: the yard objects are presentation, so the service's
-- contract is which specs it installs and clears, in order.
local function newActors()
  local record = { installed = {}, cleared = {} }
  function record:installReservedObject(spec)
    self.installed[#self.installed + 1] = spec
    return "map:" .. tostring(spec.mapId) .. ":object:" .. tostring(spec.numericId)
  end
  function record:clearReservedObject(numericId)
    self.cleared[#self.cleared + 1] = numericId
    return nil
  end
  return record
end

---@return { service: DaycareService, mons: table, bag: table, stats: table, actors: table, catalog: table, state: table }
local function fixture()
  local catalog = CatalogFixture.makeCatalog()
  local mons = newMons(catalog, 0x66666666)
  local factory = CatalogFixture.makeFactory(0x77777777, catalog)
  local bag = HgssBagService.new({ catalog = ItemFixture.makeCatalog() })
  local stats = GameStats.new(speciesRefs(catalog))
  local actors = newActors()
  local state = DaycareState.restore(DaycareState.initial(), function(record)
    return mons:validateStoredMon(record)
  end)
  local service = DaycareService.new({
    state = state,
    mons = mons,
    bag = bag,
    stats = stats,
    actors = actors,
    catalog = catalog,
    currentMap = function()
      return { mapId = 42 }
    end,
  })
  return {
    service = service,
    mons = mons,
    bag = bag,
    stats = stats,
    actors = actors,
    catalog = catalog,
    state = state,
    factory = factory,
  }
end

local function gift(world, overrides)
  local request = CatalogFixture.normalRequest(overrides or { species = "CHIKORITA", level = 5 })
  local mon = world.factory:createNormal(request)
  Assert.isTrue(world.mons:addMon(mon), "the fixture gift joins the party")
  return world.mons:partyCount() - 1
end

function T.deposit_copies_the_parent_and_transfers_custody_once()
  local world = fixture()
  local slot = gift(world, { species = "CHIKORITA", level = 5 })
  local staged = world.mons:partyMon(slot)
  staged.mood = 40
  staged.condition.currentHp = 1
  staged.condition.effects = { { key = "poison", version = 1, state = {} } }
  staged.capsule = { id = 4, seals = { { x = 1, y = 2, graphic = 3 } } }
  local preparation = assert(world.mons:preparePartyChanges(world.mons:partyRevision(), { { slot = slot, mon = staged } }))
  preparation.publish()
  local before = world.mons:partyMon(slot)
  local derived = world.mons:derive(before)

  world.service:deposit(slot)

  Assert.equal(world.mons:partyCount(), 0, "the deposit compacts the live party")
  Assert.equal(world.state:count(), 1)
  local stored = assert(world.state:mon(0))
  Assert.equal(stored.species, "CHIKORITA")
  Assert.equal(stored.mood, 0, "the stored parent takes the source mood")
  Assert.equal(stored.condition.currentHp, derived.maxHp, "the stored parent keeps boxed full health")
  Assert.equal(#stored.condition.effects, 0, "the stored parent keeps no party status")
  Assert.equal(stored.capsule.id, 0, "the stored parent keeps no ball capsule")
  Assert.equal(#stored.capsule.seals, 0)
  Assert.equal(stored.experience, before.experience, "the deposit snapshots the stored experience")
  Assert.equal(world.state:steps(0), 0, "a fresh deposit starts with no stored steps")
  Assert.equal(world.stats:daycareDeposits(), 1, "the deposit counts once")
end

function T.deposit_keeps_the_authored_mail_and_rejects_a_full_day_care()
  local world = fixture()
  local slot = gift(world, { species = "TOTODILE", level = 5 })
  gift(world, { species = "CHIKORITA", level = 5 })
  world.service:deposit(slot)
  world.service:deposit(0)
  Assert.equal(world.state:count(), 2)
  Assert.equal(world.stats:daycareDeposits(), 2)
  local third = gift(world, { species = "EEVEE", level = 5 })
  Assert.throws(function()
    world.service:deposit(third)
  end, "a third parent is refused by the state owner")
  Assert.equal(world.state:count(), 2, "the refusal publishes nothing")
  Assert.equal(world.mons:partyCount(), 1, "the refused parent stays in the party")
end

function T.growth_and_price_reads_never_mutate()
  local world = fixture()
  local slot = gift(world, { species = "CHIKORITA", level = 5 })
  local experience = world.mons:partyMon(slot).experience
  world.service:deposit(slot)
  local revision = world.state:revision()
  local growth = world.service:growth(0)
  Assert.equal(growth.growth, 0, "a fresh parent has grown no level")
  Assert.equal(growth.nickname, "CHIKORITA")
  Assert.equal(growth.bufferedGrowth, "0  ", "the source three-digit left-aligned growth buffer")
  local cost = world.service:withdrawCost(0)
  Assert.equal(cost.price, 100, "the source price is (growth + 1) * 100")
  Assert.equal(cost.bufferedPrice, "100  ", "the source five-digit left-aligned price buffer")
  local stats = assert(world.service:monStats(0))
  Assert.equal(stats.nickname, "CHIKORITA")
  Assert.equal(stats.level, "5  ")
  Assert.equal(world.service:state(), DaycareState.STATE_ONE_MON)
  Assert.equal(world.service:tailMon().species, 152)
  Assert.deepEqual(world.service:storedNicknames(), { [0] = "CHIKORITA", [2] = "RED" })
  Assert.equal(world.state:revision(), revision, "queries never advance custody")
  Assert.equal(world.state:steps(0), 0)
  Assert.equal(world.state:mon(0).experience, experience)
  local empty = world.service:growth(1)
  Assert.equal(empty.growth, 0, "an empty slot answers zero growth")
  Assert.isNil(empty.nickname, "an empty slot buffers nothing")
  Assert.isNil(world.service:monStats(1))
  Assert.equal(world.service:withdrawCost(1).price, 0)
end

function T.withdrawal_restores_the_parent_and_learns_crossed_levels()
  local world = fixture()
  local slot = gift(world, { species = "CHIKORITA", level = 5 })
  -- A full move set of authored identities; the next level offers RAZOR_LEAF.
  local extras = { "TACKLE", "GROWL", "CUT", "TOXIC" }
  for index, key in ipairs(extras) do
    world.mons:setMove(slot, index - 1, key)
  end
  local staged = world.mons:partyMon(slot)
  staged.moves[2].pp = 1
  staged.moves[2].ppUps = 2
  staged.condition.currentHp = 1
  staged.condition.effects = { { key = "poison", version = 1, state = {} } }
  staged.capsule = { id = 6, seals = {} }
  local prepared = assert(world.mons:preparePartyChanges(world.mons:partyRevision(), { { slot = slot, mon = staged } }))
  prepared.publish()
  world.service:deposit(slot)

  local curve = world.catalog:growthCurve(world.catalog:species("CHIKORITA").growthCurve)
  local span = Experience.expFor(curve, 6) - Experience.expFor(curve, 5)
  for _ = 1, span do
    world.service:noteCommittedStep()
  end
  Assert.equal(world.state:steps(0), span, "the feed counts one step per committed step")

  local withdrawn = world.service:withdraw(0)
  Assert.equal(withdrawn.species, 152, "the source species identity answers the caller")
  Assert.equal(world.state:count(), 0, "the withdrawal removes the parent")
  Assert.equal(world.mons:partyCount(), 1)
  local mon = world.mons:partyMon(0)
  Assert.equal(Experience.level(curve, mon.experience), 6, "the stored steps cross one level")
  Assert.equal(mon.condition.currentHp, world.mons:derive(mon).maxHp, "derived full health returns")
  Assert.equal(#mon.condition.effects, 0, "no status condition returns")
  Assert.equal(mon.capsule.id, 0, "no ball capsule returns")
  Assert.equal(#mon.moves, 4, "the full move set stays full")
  Assert.equal(mon.moves[1].move, "GROWL", "the full set drops its first move")
  Assert.equal(mon.moves[2].move, "CUT")
  Assert.equal(mon.moves[3].move, "TOXIC")
  Assert.equal(mon.moves[4].move, "RAZOR_LEAF", "the crossed-level move is appended")
  Assert.equal(mon.moves[1].pp, 1, "the retained move keeps its power points")
  Assert.equal(mon.moves[1].ppUps, 2, "the retained move keeps its power-point ups")
  Assert.equal(mon.moves[4].pp, world.catalog:move("RAZOR_LEAF").basePp)
  Assert.equal(mon.moves[4].ppUps, 0)
  Assert.equal(world.stats:daycareDeposits(), 1, "the withdrawal is not a new deposit")
end

function T.withdrawal_keeps_a_level_100_parent_at_its_ceiling()
  local world = fixture()
  local slot = gift(world, { species = "CHIKORITA", level = 100 })
  local experience = world.mons:partyMon(slot).experience
  world.service:deposit(slot)
  world.service:noteCommittedStep()
  world.service:noteCommittedStep()
  world.service:withdraw(0)
  local mon = world.mons:partyMon(0)
  Assert.equal(mon.experience, experience, "a parent at the ceiling never gains stored steps")
end

function T.withdrawal_appends_a_free_move_when_the_set_has_room()
  local world = fixture()
  local slot = gift(world, { species = "CHIKORITA", level = 5 })
  for index, key in ipairs({ "TACKLE", "GROWL", "CUT" }) do
    world.mons:setMove(slot, index - 1, key)
  end
  world.service:deposit(slot)
  local curve = world.catalog:growthCurve(world.catalog:species("CHIKORITA").growthCurve)
  local span = Experience.expFor(curve, 6) - Experience.expFor(curve, 5)
  for _ = 1, span do
    world.service:noteCommittedStep()
  end
  world.service:withdraw(0)
  local mon = world.mons:partyMon(0)
  Assert.equal(#mon.moves, 4, "a free slot appends instead of dropping a move")
  Assert.equal(mon.moves[1].move, "TACKLE")
  Assert.equal(mon.moves[2].move, "GROWL")
  Assert.equal(mon.moves[3].move, "CUT")
  Assert.equal(mon.moves[4].move, "RAZOR_LEAF")
end

function T.committed_steps_reach_only_occupied_parents()
  local world = fixture()
  world.service:noteCommittedStep()
  Assert.equal(world.state:revision(), 0, "an empty Day Care stages nothing")
  local slot = gift(world, { species = "CHIKORITA", level = 5 })
  gift(world, { species = "TOTODILE", level = 5 })
  world.service:deposit(slot)
  world.service:deposit(0)
  for _ = 1, 3 do
    world.service:noteCommittedStep()
  end
  Assert.deepEqual({ world.state:steps(0), world.state:steps(1) }, { 3, 3 }, "every parent counts each step once")
end

function T.sanitize_answers_the_source_sentinel_and_returns_a_held_orb()
  local world = fixture()
  local slot = gift(world, { species = "EEVEE", level = 5, heldItem = "ITEM_112" })
  Assert.equal(world.bag:quantity("ITEM_112"), 0)
  Assert.equal(world.service:sanitizeMon(0xFF), 0, "the source sentinel answers zero")
  Assert.equal(world.mons:partyMon(slot).heldItem, "ITEM_112", "the sentinel never touches a mon")
  Assert.equal(world.service:sanitizeMon(slot), 0)
  Assert.equal(world.mons:partyMon(slot).heldItem, "NONE", "the held orb leaves the parent")
  Assert.equal(world.bag:quantity("ITEM_112"), 1, "the orb lands in the Bag")
end

-- A refusing Bag owner for the source's one failure branch: the real inventory
-- cannot be filled past its pocket capacity with the fixture's item set, so the
-- refusal is injected at the Bag boundary (the collaborator whose answer this
-- branch reads) while every other call reaches the real service.
---@param bag table<string, unknown> the live Bag service
---@return table<string, unknown>
local function refusingBag(bag)
  local double = {
    catalog = function()
      return bag:catalog()
    end,
    revision = function()
      return bag:revision()
    end,
    quantity = function(_, item)
      return bag:quantity(item)
    end,
    hasSpace = function()
      return false
    end,
    prepareInventoryChanges = function()
      return nil, "bag_full"
    end,
  }
  return double
end

function T.sanitize_leaves_the_parent_and_bag_unchanged_when_the_bag_refuses()
  local world = fixture()
  local slot = gift(world, { species = "EEVEE", level = 5, heldItem = "ITEM_112" })
  local service = DaycareService.new({
    state = world.state,
    mons = world.mons,
    bag = refusingBag(world.bag),
    stats = world.stats,
    actors = world.actors,
    catalog = world.catalog,
    currentMap = function()
      return { mapId = 42 }
    end,
  })
  local before = world.mons:partyMon(slot)
  local revision = world.mons:partyRevision()
  local bagRevision = world.bag:revision()
  Assert.equal(service:sanitizeMon(slot), 255, "a refused Orb answers the source failure")
  Assert.deepEqual(world.mons:partyMon(slot), before, "the parent stays unchanged")
  Assert.equal(world.mons:partyRevision(), revision, "no party publication happened")
  Assert.equal(world.bag:revision(), bagRevision, "no bag publication happened")
end

function T.yard_objects_are_installed_per_occupied_slot_and_cleared_when_empty()
  local world = fixture()
  world.service:updateYardObjects()
  Assert.deepEqual(world.actors.cleared, { 250, 251 }, "an empty Day Care clears both reserved objects")
  Assert.equal(#world.actors.installed, 0)
  local slot = gift(world, { species = "CHIKORITA", level = 5 })
  world.service:deposit(slot)
  world.actors.cleared = {}
  world.service:updateYardObjects()
  Assert.equal(#world.actors.installed, 1, "one parent repaints one reserved object")
  local spec = world.actors.installed[1]
  Assert.equal(spec.numericId, 250)
  Assert.equal(spec.fieldX, 8)
  Assert.equal(spec.fieldZ, 5)
  Assert.equal(spec.facing, "south", "the source direction 1 is south")
  Assert.equal(spec.movementType, "look_north_south_east", "the source movement selector 11")
  Assert.equal(spec.sprite, world.catalog:followerSelection(world.state:mon(0)), "the catalog's own follower selection")
  Assert.equal(spec.visualId, world.catalog:followerSelection(world.state:mon(0)).visualId)
  Assert.deepEqual(world.actors.cleared, { 251 }, "the empty second slot clears its object")
end

function T.service_capture_publishes_only_settled_custody()
  local world = fixture()
  local slot = gift(world, { species = "CHIKORITA", level = 5 })
  world.service:deposit(slot)
  local captured = world.service:capture()
  Assert.equal(captured.schema, DaycareState.SCHEMA)
  Assert.equal(#captured.slots, 1)
  Assert.equal(captured.pendingEggPid, 0)
  Assert.equal(captured.eggCycleCounter, 0)
  Assert.equal(world.service:savedState():count(), 1)
end

return { tests = T }
