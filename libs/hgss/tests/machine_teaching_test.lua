-- Machine teaching through real services: compatibility planning over the
-- live mon and bag services, atomic TM/HM publication with revision
-- guards, and picker-return safety. TM use consumes once with source
-- friendship/mood; HM use retains its item; known, incompatible,
-- full, protected, cancelled and stale paths mutate nothing.

local Assert = require("tests.support.Assert")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local ItemFixture = require("libs.items.tests.item_fixture")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local MonCatalog = require("libs.mons.src.MonCatalog")
local MonsSave = require("libs.mons.src.MonsSave")
local Party = require("libs.mons.src.Party")
local PartyActions = require("libs.hgss.src.field.PartyActions")
local MachineTeaching = require("libs.hgss.src.mons.MachineTeaching")

-- The drill under test teaches BULLET_SEED (source move 331): CHIKORITA
-- lists it as compatible while TOTODILE and EEVEE do not. HM01 still
-- teaches CUT (source move 15). No production catalog changes; only this
-- suite's records point the fixture TM at the fixture move.
local BULLET_SEED_NATIVE = 331

local function itemRoot()
  local root = ItemFixture.buildAssetRoot()
  root.items.TM01.tmhmMoveNativeId = BULLET_SEED_NATIVE
  return root
end

local function openServices()
  local ItemCatalog = require("libs.items.src.ItemCatalog")
  local itemCatalog = ItemCatalog.new(itemRoot())
  local catalog = MonCatalog.new(CatalogFixture.buildAssetRoot(), itemCatalog)
  local mons = require("libs.hgss.src.mons.HgssMonService").new({
    catalog = catalog,
    bucket = MonsSave.capture(Party.new():capture(), Lcrng.new(0x33333333):capture()),
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
  local bag = require("libs.hgss.src.items.HgssBagService").new({ catalog = itemCatalog })
  local factory = CatalogFixture.makeFactory(0x44444444, catalog)
  return mons, bag, factory, catalog
end

local function addGifted(mons, factory, species, level)
  local mon = factory:createNormal(CatalogFixture.normalRequest({ species = species, level = level or 1 }))
  Assert.isTrue(mons:addMon(mon), "setup mon must enter the party")
  return mons:partyMon(mons:partyCount() - 1)
end

local function catalogsOf(catalog, bag)
  return { items = bag:catalog(), mons = catalog }
end

local function teachRequest(mons, bag, slot, item, moveSlot, expectedOldMove)
  return {
    kind = "teach_move",
    slot = slot,
    partyRevision = mons:partyRevision(),
    bagRevision = bag:revision(),
    item = item,
    moveSlot = moveSlot,
    expectedOldMove = expectedOldMove,
  }
end

local function moveKeys(mon)
  local keys = {}
  for index, entry in ipairs(assert(mon.moves, "stored mons carry their moves")) do
    keys[index] = entry.move
  end
  return keys
end

local T = {}

function T.free_tm_teaches_with_full_pp_and_single_consumption()
  local mons, bag, factory, catalog = openServices()
  addGifted(mons, factory, "CHIKORITA", 1)
  Assert.isTrue(bag:add("TM01", 2))
  local monRevision = mons:partyRevision()
  local actions = PartyActions.new({ mons = mons, bag = bag })

  local plan = MachineTeaching.plan(
    { mon = mons:partyMon(0), item = "TM01" },
    catalogsOf(catalog, bag),
    { location = 7 }
  )
  Assert.equal(plan.kind, "candidate", "a compatible free slot plans a candidate")
  Assert.equal(plan.move, "BULLET_SEED", "the candidate names the resolved move")
  Assert.equal(plan.moveSlot, 2, "the candidate appends after two learned moves")
  Assert.equal(plan.consumption, 1, "a TM consumes once")

  local monBefore = mons:partyMon(0)
  local friendshipBefore = assert(monBefore.friendship, "setup mons carry friendship")
  local outcome = actions:commit(teachRequest(mons, bag, 0, "TM01"))
  Assert.equal(outcome.kind, "changed", "teaching publishes")
  Assert.equal(mons:partyRevision(), monRevision + 1, "teaching advances one party revision")
  Assert.equal(bag:quantity("TM01"), 1, "one TM is consumed")
  local after = mons:partyMon(0)
  Assert.deepEqual(moveKeys(after), { "TACKLE", "GROWL", "BULLET_SEED" }, "the move appends")
  Assert.equal(after.moves[3].pp, 30, "the entry carries full base power points")
  Assert.equal(after.moves[3].ppUps, 0, "the entry carries no power-point ups")
  Assert.equal(after.friendship, friendshipBefore + 1, "source learning friendship applies once")
  Assert.equal(after.mood, 40, "source learning mood applies once")
end

function T.hm_teaches_without_consumption_and_field_still_requires_its_badge()
  local mons, bag, factory = openServices()
  addGifted(mons, factory, "TOTODILE", 1)
  Assert.isTrue(bag:add("HM01", 1))
  local bagRevision = bag:revision()
  local actions = PartyActions.new({ mons = mons, bag = bag })

  local outcome = actions:commit(teachRequest(mons, bag, 0, "HM01"))
  Assert.equal(outcome.kind, "changed", "compatible HM teaching publishes")
  Assert.equal(bag:quantity("HM01"), 1, "the HM is retained")
  Assert.equal(bag:revision(), bagRevision, "retaining the HM moves no bag revision")
  local after = mons:partyMon(0)
  Assert.equal(after.moves[3].move, "CUT", "the HM move appends")
  Assert.equal(after.moves[3].pp, 30, "the entry carries full base power points")

  local FieldMovePolicy = require("libs.hgss.src.field.FieldMovePolicy")
  local check = FieldMovePolicy.check("cut", { badges = 0 })
  Assert.equal(check.kind, "need_badge", "field use still requires its badge after teaching")
  Assert.equal(check.badge, "hive", "the badge requirement names its source gate")
end

function T.full_moveset_needs_replacement_then_commits_exactly_once()
  local mons, bag, factory = openServices()
  addGifted(mons, factory, "CHIKORITA", 9)
  Assert.equal(#moveKeys(mons:partyMon(0)), 4, "setup carries a full moveset")
  Assert.isTrue(bag:add("TM01", 1))
  local actions = PartyActions.new({ mons = mons, bag = bag })

  Assert.equal(
    actions:preview(teachRequest(mons, bag, 0, "TM01")).kind,
    "needs_replacement",
    "a full set asks for a slot"
  )
  local before = moveKeys(mons:partyMon(0))
  local friendshipBefore = assert(mons:partyMon(0).friendship, "setup mons carry friendship")
  local request = teachRequest(mons, bag, 0, "TM01", 1, before[2])
  local outcome = actions:commit(request)
  Assert.equal(outcome.kind, "changed", "the picker return completes")
  local after = moveKeys(mons:partyMon(0))
  for index = 1, 4 do
    if index == 2 then
      Assert.equal(after[index], "BULLET_SEED", "only the chosen slot changes")
    else
      Assert.equal(after[index], before[index], "every other entry is untouched")
    end
  end
  Assert.equal(mons:partyMon(0).moves[2].ppUps, 0, "power-point ups reset on the taught slot")
  Assert.equal(mons:partyMon(0).moves[2].pp, 30, "power points fill on the taught slot")
  Assert.equal(bag:quantity("TM01"), 0, "the TM is consumed once")
  Assert.equal(mons:partyMon(0).friendship, friendshipBefore + 1, "friendship applies once")
  Assert.equal(mons:partyMon(0).mood, 40, "mood applies once")

  local duplicate = actions:commit(request)
  Assert.equal(duplicate.kind, "stale", "replaying the picker return teaches nothing twice")
  Assert.deepEqual(moveKeys(mons:partyMon(0)), after, "the replay leaves the moveset alone")
  Assert.equal(bag:quantity("TM01"), 0, "the replay consumes nothing")
end

function T.cancelled_and_stale_picker_returns_mutate_nothing()
  local mons, bag, factory = openServices()
  addGifted(mons, factory, "CHIKORITA", 9)
  Assert.isTrue(bag:add("TM01", 1))
  local monBefore = mons:partyMon(0)
  local monRevision = mons:partyRevision()
  local bagRevision = bag:revision()
  local actions = PartyActions.new({ mons = mons, bag = bag })

  Assert.equal(
    actions:preview(teachRequest(mons, bag, 0, "TM01")).kind,
    "needs_replacement",
    "a full set asks for a slot"
  )
  Assert.deepEqual(mons:partyMon(0), monBefore, "asking mutates nothing")
  Assert.equal(mons:partyRevision(), monRevision, "asking moves no revision")

  local before = moveKeys(mons:partyMon(0))
  local staleRequest = teachRequest(mons, bag, 0, "TM01", 0, before[1])
  mons:setMove(0, 0, "TOXIC")
  local drifted = mons:partyRevision()
  local outcome = actions:commit(staleRequest)
  Assert.equal(outcome.kind, "stale", "a drifted picker return is rejected")
  Assert.equal(mons:partyRevision(), drifted, "the rejection publishes nothing")
  Assert.equal(bag:quantity("TM01"), 1, "the rejection consumes nothing")
  Assert.equal(bag:revision(), bagRevision, "the rejection moves no bag revision")
end

function T.known_incompatible_and_egg_paths_refuse_without_mutation()
  local mons, bag, factory, catalog = openServices()
  addGifted(mons, factory, "CHIKORITA", 1)
  addGifted(mons, factory, "TOTODILE", 1)
  local scope = catalogsOf(catalog, bag)

  mons:setMove(0, 0, "BULLET_SEED")
  local known = MachineTeaching.plan({ mon = mons:partyMon(0), item = "TM01" }, scope, { location = 7 })
  Assert.equal(known.kind, "known", "an already-known move refuses before compatibility")

  local foreign = MachineTeaching.plan({ mon = mons:partyMon(1), item = "TM01" }, scope, { location = 7 })
  Assert.equal(foreign.kind, "incompatible", "a form outside the machine list refuses")

  local egg = mons:partyMon(0)
  egg.isEgg = true
  local eggPlan = MachineTeaching.plan({ mon = egg, item = "TM01" }, scope, { location = 7 })
  Assert.equal(eggPlan.kind, "incompatible", "eggs reject the teaching path")

  local monRevision = mons:partyRevision()
  local actions = PartyActions.new({ mons = mons, bag = bag })
  Assert.isTrue(bag:add("TM01", 1), "refusals still need the owned machine")
  Assert.equal(
    actions:preview(teachRequest(mons, bag, 1, "TM01")).kind,
    "incompatible",
    "refusals surface through actions"
  )
  Assert.equal(mons:partyRevision(), monRevision, "refusals publish nothing")
end

function T.hm_slots_refuse_replacement_while_deleteMove_keeps_general_legality()
  local mons, bag, factory, catalog = openServices()
  addGifted(mons, factory, "CHIKORITA", 9)
  mons:setMove(0, 3, "CUT")
  Assert.isTrue(bag:add("TM01", 1))
  local scope = catalogsOf(catalog, bag)

  local refused = MachineTeaching.plan(
    { mon = mons:partyMon(0), item = "TM01", replaceSlot = 3, expectedOldMove = "CUT" },
    scope,
    { location = 7 }
  )
  Assert.equal(refused.kind, "protected", "an HM slot refuses machine replacement")

  local before = moveKeys(mons:partyMon(0))
  local actions = PartyActions.new({ mons = mons, bag = bag })
  local outcome = actions:commit(teachRequest(mons, bag, 0, "TM01", 3, "CUT"))
  Assert.equal(outcome.kind, "protected", "the publication boundary refuses too")
  Assert.deepEqual(moveKeys(mons:partyMon(0)), before, "the refusal preserves the moveset")
  Assert.equal(bag:quantity("TM01"), 1, "the refusal consumes nothing")

  mons:deleteMove(0, 3)
  Assert.equal(#moveKeys(mons:partyMon(0)), 3, "the domain primitive keeps its general legality")
end

function T.teaching_stores_plain_entries_and_grants_no_field_permission()
  local mons, bag, factory = openServices()
  addGifted(mons, factory, "CHIKORITA", 1)
  Assert.isTrue(bag:add("TM01", 1))
  local actions = PartyActions.new({ mons = mons, bag = bag })
  local outcome = actions:commit(teachRequest(mons, bag, 0, "TM01"))
  Assert.equal(outcome.kind, "changed", "teaching publishes")
  local after = mons:partyMon(0)
  Assert.isTrue(#after.moves <= 4, "four slots stay the bound")
  for _, entry in ipairs(assert(after.moves, "stored mons carry their moves")) do
    Assert.equal(type(entry.move), "string", "moves stay semantic keys")
    Assert.isTrue(entry.pp >= 0 and entry.pp <= 40, "power points stay plain counts")
    Assert.isTrue(entry.ppUps >= 0 and entry.ppUps <= 3, "power-point ups stay plain counts")
  end
  local FieldMovePolicy = require("libs.hgss.src.field.FieldMovePolicy")
  Assert.equal(FieldMovePolicy.check("cut", { badges = 0 }).kind, "need_badge", "teaching never marks field permission")
end

return { tests = T }
