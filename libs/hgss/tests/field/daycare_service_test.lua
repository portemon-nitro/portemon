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
local Personality = require("libs.mons.src.gen4.Personality")
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

-- A recording phone owner: the Day-Care call is one trigger flag on the
-- companion state, so the fixture observes the raise without a phone app.
local function newPhone()
  local record = { raised = {}, eggTriggerKey = "gear.trigger.5" }
  record.state = {
    setTrigger = function(_, key, active)
      record.raised[#record.raised + 1] = { key = key, active = active }
    end,
  }
  return record
end

-- The compiled care tables for the fixture species: the egg species each
-- mother resolves to, the offspring egg moves, and the source incense pairs.
local function newCare()
  return {
    eggSpecies = {
      CHIKORITA = "CHIKORITA",
      TOTODILE = "TOTODILE",
      EEVEE = "EEVEE",
      PICHU = "PICHU",
      SHEDINJA = "SHEDINJA",
    },
    eggMoves = { EEVEE = { "TOXIC" } },
    incense = { { baby = "MUNCHLAX", item = "FULL_INCENSE", parent = "SNORLAX" } },
  }
end

-- The service's injected source draws: a mutable scripted linear value list
-- and one mutable 32-bit personality, so a step check is deterministic and the
-- fixture can observe exactly how many values were consumed.
local function newDraws()
  local draws = { values = {}, lcCalls = 0, mtCalls = 0, personality = 0x12345678 }
  function draws.lc()
    draws.lcCalls = draws.lcCalls + 1
    return draws.values[draws.lcCalls] or 0
  end
  function draws.mt()
    draws.mtCalls = draws.mtCalls + 1
    return draws.personality
  end
  return draws
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
  local phone = newPhone()
  local draws = newDraws()
  local care = newCare()
  local function newService(bagService)
    return DaycareService.new({
      state = state,
      mons = mons,
      bag = bagService,
      stats = stats,
      actors = actors,
      catalog = catalog,
      care = care,
      profile = CatalogFixture.profile(),
      date = function()
        return CatalogFixture.metDate()
      end,
      lc = draws.lc,
      mt = draws.mt,
      phone = phone,
      currentMap = function()
        return { mapId = 42 }
      end,
    })
  end
  return {
    service = newService(bag),
    makeService = newService,
    mons = mons,
    bag = bag,
    stats = stats,
    actors = actors,
    catalog = catalog,
    care = care,
    phone = phone,
    draws = draws,
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
  Assert.equal(world.state:count(), 0, "an empty Day Care holds no parent")
  Assert.equal(world.state:eggCycleCounter(), 1, "the source cycle counter advances on every processed step")
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
  local service = world.makeService(refusingBag(world.bag))
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

-- Stages one live party record through the canonical party publication, so the
-- deposit copies the edited identity.
---@param world table
---@param slot integer
---@param change fun(mon: table)
local function stageMon(world, slot, change)
  local mon = world.mons:partyMon(slot)
  change(mon)
  local prepared = assert(world.mons:preparePartyChanges(world.mons:partyRevision(), { { slot = slot, mon = mon } }))
  prepared.publish()
end

---@param ratio integer
---@param gender string
---@return integer
local function personalityFor(ratio, gender)
  for candidate = 0, 800 do
    if Personality.gender(ratio, candidate) == gender then
      return candidate
    end
  end
  error("no personality resolves " .. gender, 0)
end

-- Deposits one gender-staged pair of the named species.
---@param world table
---@param first { species: string, gender: string, trainerId: integer?, moves: string[]?, ivs: table? }
---@param second { species: string, gender: string, trainerId: integer?, moves: string[]?, ivs: table? }
local function depositPair(world, first, second)
  for _, spec in ipairs({ first, second }) do
    local slot = gift(world, { species = spec.species, level = 20 })
    stageMon(world, slot, function(mon)
      local ratio = world.catalog:species(spec.species).genderRatio
      mon.personality = personalityFor(ratio, spec.gender)
      if spec.trainerId ~= nil then
        mon.origin.trainerId = spec.trainerId
      end
      if spec.moves ~= nil then
        local moves = {}
        for index, key in ipairs(spec.moves) do
          moves[index] = { move = key, pp = world.catalog:move(key).basePp, ppUps = 0 }
        end
        mon.moves = moves
      end
      if spec.ivs ~= nil then
        mon.ivs = spec.ivs
      end
      mon.condition = { currentHp = world.mons:derive(mon).maxHp, effects = {} }
    end)
    world.service:deposit(slot)
  end
end

function T.compatibility_categories_come_from_the_stored_parents()
  local world = fixture()
  depositPair(world, { species = "CHIKORITA", gender = "female" }, { species = "CHIKORITA", gender = "male" })
  Assert.equal(world.service:compatibility(), 50, "the same species and one trainer identity is medium")
  Assert.equal(world.service:compatibilityCategory(), 1, "medium compatibility reports one")

  local other = fixture()
  depositPair(other, { species = "CHIKORITA", gender = "female" }, {
    species = "CHIKORITA",
    gender = "male",
    trainerId = CatalogFixture.profile().trainerId + 1,
  })
  Assert.equal(other.service:compatibility(), 70, "the same species across trainer identities is maximum")
  Assert.equal(other.service:compatibilityCategory(), 0, "maximum compatibility reports zero")

  local low = fixture()
  depositPair(low, { species = "CHIKORITA", gender = "female" }, { species = "TOTODILE", gender = "male" })
  Assert.equal(low.service:compatibilityCategory(), 2, "different species and one identity is low")

  local none = fixture()
  depositPair(none, { species = "CHIKORITA", gender = "female" }, { species = "PICHU", gender = "male" })
  Assert.equal(none.service:compatibilityCategory(), 3, "an undiscovered partner is incompatible")
end

function T.a_step_check_stores_only_the_pending_identity()
  local world = fixture()
  depositPair(world, { species = "CHIKORITA", gender = "female" }, { species = "CHIKORITA", gender = "male" })
  for _ = 1, 254 do
    world.service:noteCommittedStep()
  end
  Assert.equal(world.state:steps(0), 254, "each committed step advances the first parent")
  Assert.equal(world.state:pendingEggPid(), 0, "no check runs before the source step")
  Assert.equal(world.draws.lcCalls, 0, "no draw precedes the source step")
  Assert.equal(world.mons:partyCount(), 0, "no Egg exists before the check")

  world.service:noteCommittedStep()
  Assert.equal(world.state:steps(0), 255, "the check lands on the 255th stored step")
  Assert.equal(world.draws.lcCalls, 1, "the check draws exactly one compatibility value")
  Assert.equal(world.state:pendingEggPid(), 0x12345678, "a successful check stores the pending personality")
  Assert.equal(world.mons:partyCount(), 0, "the check builds no finished Egg")
  Assert.equal(world.state:count(), 2, "the check keeps both parents in care")
  Assert.deepEqual(
    world.phone.raised,
    { { key = "gear.trigger.5", active = true } },
    "a successful check raises the durable Day-Care call"
  )
  Assert.isTrue(world.service:hasEgg(), "the pending identity answers the source egg query")
  Assert.equal(world.state:eggCycleCounter(), 0, "the 255th counter value completes its own cycle")
end

function T.a_failed_check_stores_nothing_and_still_draws_once()
  local world = fixture()
  depositPair(world, { species = "CHIKORITA", gender = "female" }, { species = "TOTODILE", gender = "male" })
  world.draws.values = { 0xFFFF }
  for _ = 1, 255 do
    world.service:noteCommittedStep()
  end
  Assert.equal(world.draws.lcCalls, 1, "an incompatible roll still draws its value")
  Assert.equal(world.state:pendingEggPid(), 0, "a failed roll stores no identity")
  Assert.equal(#world.phone.raised, 0, "a failed roll raises no call")
end

function T.the_cycle_counter_follows_the_source_date()
  local world = fixture()
  depositPair(world, { species = "CHIKORITA", gender = "female" }, { species = "CHIKORITA", gender = "male" })
  Assert.isTrue(world.mons:giveEgg({ species = "PICHU", locationOffset = 14 }), "the party takes one Egg")
  Assert.isTrue(world.mons:giveEgg({ species = "PICHU", locationOffset = 14 }), "the party takes a second Egg")
  for slot = 0, 1 do
    stageMon(world, slot, function(mon)
      mon.friendship = 9
    end)
  end
  world.service:noteCommittedStep()
  Assert.equal(world.state:eggCycleCounter(), 1, "an ordinary date keeps counting toward its threshold")
  for _ = 2, 255 do
    world.service:noteCommittedStep()
  end
  Assert.equal(world.state:eggCycleCounter(), 0, "the full cycle completes and resets")
  Assert.equal(world.mons:partyMon(0).friendship, 8, "a completed cycle decrements the party Egg")
  Assert.equal(world.mons:partyMon(1).friendship, 8, "every party Egg loses the same decrement")
end

function T.egg_collection_appends_the_resolved_egg_and_clears_the_identity()
  local world = fixture()
  depositPair(world, {
    species = "CHIKORITA",
    gender = "female",
    moves = { "GROWL", "RAZOR_LEAF", "SYNTHESIS" },
    ivs = { hp = 31, attack = 31, defense = 31, speed = 31, specialAttack = 31, specialDefense = 31 },
  }, {
    species = "CHIKORITA",
    gender = "male",
    moves = { "TACKLE", "TOXIC", "SYNTHESIS" },
    ivs = { hp = 0, attack = 0, defense = 0, speed = 0, specialAttack = 0, specialDefense = 0 },
  })
  for _ = 1, 255 do
    world.service:noteCommittedStep()
  end
  local pending = world.state:pendingEggPid()
  Assert.isTrue(pending ~= 0, "the source step produced an identity")
  local drawnBefore = world.draws.lcCalls
  local generatorBefore = world.mons:capture().rng.calls

  Assert.isTrue(world.service:receiveEgg(), "the party takes the generated Egg")
  Assert.equal(world.mons:partyCount(), 1, "the collection appends one mon")
  local mon = world.mons:partyMon(0)
  Assert.isTrue(mon.isEgg == true, "the appended record is an unhatched Egg")
  Assert.equal(mon.experience, 0, "the Egg enters at level one")
  Assert.equal(mon.species, "CHIKORITA", "the offspring resolves through the care tables")
  Assert.equal(mon.personality, pending, "the stored identity becomes the Egg's own personality")
  Assert.equal(mon.heldItem, "NONE", "a generated Egg holds nothing")
  Assert.equal(world.state:pendingEggPid(), 0, "the collection clears the pending identity")
  Assert.equal(world.state:eggCycleCounter(), 0, "the collection clears the cycle progress with it")
  Assert.equal(world.state:count(), 2, "the collection keeps both parents in care")
  Assert.equal(
    world.draws.lcCalls,
    drawnBefore,
    "the collection spends no step-check draw"
  )
  Assert.equal(
    world.mons:capture().rng.calls - generatorBefore,
    8,
    "the collection draws the two initial values, three stat indices, and their parent choices"
  )
  local inherited = 0
  for _, key in ipairs({ "hp", "attack", "defense", "speed", "specialAttack", "specialDefense" }) do
    if mon.ivs[key] == 31 or mon.ivs[key] == 0 then
      inherited = inherited + 1
    end
  end
  Assert.equal(inherited, 3, "exactly three distinct individual values are inherited")
  Assert.equal(mon.moves[1].move, "TACKLE", "the level-one default opens the inherited move set")
  Assert.equal(mon.moves[2].move, "GROWL", "the second level-one default follows")
  Assert.equal(mon.moves[3].move, "TOXIC", "the father's compatible machine comes next")
  Assert.equal(mon.moves[4].move, "SYNTHESIS", "the shared learn-up move closes the set")
  Assert.isFalse(world.service:hasEgg(), "no identity waits after the collection")
end

function T.egg_collection_refuses_a_full_party_and_duplicate_configuration()
  local world = fixture()
  depositPair(world, { species = "CHIKORITA", gender = "female" }, { species = "CHIKORITA", gender = "male" })
  for _ = 1, 255 do
    world.service:noteCommittedStep()
  end
  for _ = 1, Party.MAX do
    Assert.isTrue(world.mons:giveMon({ species = "CHIKORITA", level = 5, form = 0, heldItem = "NONE" }))
  end
  local drawnBefore = world.draws.lcCalls
  Assert.isFalse(world.service:receiveEgg(), "a full party takes no egg")
  Assert.equal(world.draws.lcCalls, drawnBefore, "a refused collection draws nothing")
  Assert.equal(world.mons:partyCount(), Party.MAX, "the full party stays as it was")
  Assert.isTrue(world.state:pendingEggPid() ~= 0, "the refusal keeps the pending identity")
end

function T.egg_reset_clears_the_identity_and_progress_together()
  local world = fixture()
  depositPair(world, { species = "CHIKORITA", gender = "female" }, { species = "CHIKORITA", gender = "male" })
  for _ = 1, 255 do
    world.service:noteCommittedStep()
  end
  Assert.isTrue(world.state:pendingEggPid() ~= 0, "the source step produced an identity")
  world.service:resetEgg()
  Assert.equal(world.state:pendingEggPid(), 0, "the source reset clears the identity")
  Assert.equal(world.state:eggCycleCounter(), 0, "the source reset clears the cycle progress")
  Assert.equal(world.state:count(), 2, "the reset keeps both parents")
  Assert.isFalse(world.service:hasEgg(), "nothing waits after the reset")
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
