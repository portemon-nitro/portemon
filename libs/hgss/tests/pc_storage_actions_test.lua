-- PC custody actions: source transfers are prepared against the live mon
-- service and publish only after every domain candidate is current.

local Assert = require("tests.support.Assert")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local ItemFixture = require("libs.items.tests.item_fixture")
local HgssBagService = require("libs.hgss.src.items.HgssBagService")
local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local MonsSave = require("libs.mons.src.MonsSave")
local Party = require("libs.mons.src.Party")
local PcStorageActions = require("libs.hgss.src.field.PcStorageActions")

local T = {}

local function services()
  local catalog = CatalogFixture.makeCatalog()
  local mons = HgssMonService.new({
    catalog = catalog,
    bucket = MonsSave.capture(Party.new():capture(), Lcrng.new(0x44444444):capture()),
    profile = CatalogFixture.profile(),
    game = "heartgold",
    language = "english",
    charmap = CatalogFixture.CHARMAP,
    games = CatalogFixture.GAMES,
    languages = CatalogFixture.LANGUAGES,
    items = CatalogFixture.ITEMS,
    balls = CatalogFixture.BALLS,
  })
  local factory = CatalogFixture.makeFactory(0x55555555, catalog)
  Assert.isTrue(mons:addMon(factory:createNormal(CatalogFixture.normalRequest({ species = "CHIKORITA" }))))
  local bag = HgssBagService.new({ catalog = ItemFixture.makeCatalog() })
  return mons, bag
end

local function partyUpdate(mons, slot, change)
  local mon = mons:partyMon(slot)
  change(mon)
  local preparation = assert(mons:preparePartyChanges(mons:partyRevision(), { { slot = slot, mon = mon } }))
  preparation.publish()
end

local function boxUpdate(mons, box, slot, mon)
  local preparation = assert(mons:preparePcChanges({
    partyRevision = mons:partyRevision(),
    boxRevision = mons:boxRevision(),
  }, { boxUpdates = { { box = box, slot = slot, mon = mon } } }))
  preparation.publish()
end

local function authoredMail()
  return {
    schema = "g4-mail-v1",
    type = 0,
    author = { trainerId = 12345, name = "MISTY", gender = 1, language = 2, game = 8 },
    icons = {
      { species = "CHIKORITA", form = 0, palette = 2 },
      false,
      { species = "TOTODILE", form = 0, palette = 1 },
    },
    lines = {
      { template = "mail.line.1", words = { "word.water", false } },
      { template = "mail.line.2", words = { "word.friend", "word.hello" } },
      { template = "mail.line.3", words = { "word.goodbye", false } },
    },
  }
end

function T.deposit_and_withdraw_keep_single_custody_and_apply_route_normalization()
  local mons, bag = services()
  local factory = CatalogFixture.makeFactory(0x66778899, mons:catalog())
  Assert.isTrue(mons:addMon(factory:createNormal(CatalogFixture.normalRequest({ species = "CHIKORITA" }))))
  local original = mons:partyMon(0)
  original.condition.currentHp = 1
  original.moves[1].pp = 1
  original.moves[1].ppUps = 2
  local update = assert(mons:preparePartyChanges(mons:partyRevision(), { { slot = 0, mon = original } }))
  update.publish()
  local before = mons:partyMon(0)
  local actions = PcStorageActions.new({ mons = mons, bag = bag })
  local request = {
    kind = "deposit",
    source = { kind = "party", slot = 0 },
    destination = { kind = "box", box = 0, slot = 0 },
  }

  local preview = actions:preview(request)
  Assert.equal(preview.kind, "allowed")
  Assert.equal(mons:partyCount(), 2, "preview retains source custody")
  Assert.isNil(mons:boxMon(0, 0), "preview leaves the box untouched")
  local committed = actions:commit(preview)
  Assert.equal(committed.kind, "changed")
  Assert.equal(mons:partyCount(), 1)
  local stored = assert(mons:boxMon(0, 0))
  Assert.equal(stored.personality, before.personality)
  Assert.equal(stored.nickname, before.nickname)
  Assert.equal(stored.condition.currentHp, mons:derive(stored).maxHp, "deposit restores derived health")
  Assert.equal(stored.moves[1].pp, 49, "deposit restores PP including the two PP Ups")

  local withdraw = actions:preview({
    kind = "withdraw",
    source = { kind = "box", box = 0, slot = 0 },
    destination = { kind = "party", slot = 1 },
  })
  Assert.equal(actions:commit(withdraw).kind, "changed")
  local returned = mons:partyMon(1)
  Assert.equal(returned.personality, before.personality)
  Assert.equal(returned.condition.currentHp, mons:derive(returned).maxHp)
  Assert.equal(returned.condition.status, 0)
  Assert.equal(mons:partyCount(), 2)
  Assert.isNil(mons:boxMon(0, 0), "withdrawal clears the exact source address")
end

function T.stale_joint_item_preview_does_not_change_bag_or_mon()
  local mons, bag = services()
  Assert.isTrue(bag:add("POTION", 1))
  local held = mons:partyMon(0)
  held.heldItem = "POTION"
  local heldPreparation = assert(mons:preparePartyChanges(mons:partyRevision(), { { slot = 0, mon = held } }))
  heldPreparation.publish()
  local actions = PcStorageActions.new({ mons = mons, bag = bag })
  local preview = actions:preview({
    kind = "takeItem",
    source = { kind = "party", slot = 0 },
    item = "POTION",
  })
  Assert.equal(preview.kind, "allowed")
  local beforeMon, beforeBag = mons:partyMon(0), bag:quantity("POTION")
  local external = mons:partyMon(0)
  external.heldItem = "SITRUS_BERRY"
  local changed = assert(mons:preparePartyChanges(mons:partyRevision(), { { slot = 0, mon = external } }))
  changed.publish()

  local result = actions:commit(preview)
  Assert.equal(result.kind, "stale")
  Assert.equal(bag:quantity("POTION"), beforeBag, "stale item transfer retains bag quantity")
  Assert.equal(mons:partyMon(0).heldItem, "SITRUS_BERRY", "stale item transfer keeps external mon change")
  Assert.equal(mons:partyMon(0).personality, beforeMon.personality)
end

function T.party_move_cannot_remove_the_last_usable_mon()
  local mons, bag = services()
  local actions = PcStorageActions.new({ mons = mons, bag = bag })
  local before = mons:partyMon(0)
  local partyRevision, boxRevision = mons:partyRevision(), mons:boxRevision()
  local preview = actions:preview({
    kind = "move",
    source = { kind = "party", slot = 0 },
    destination = { kind = "box", box = 0, slot = 0 },
  })
  Assert.equal(preview.kind, "refused")
  Assert.equal(preview.reason, "last_usable")
  local committed = actions:commit(preview)
  Assert.equal(committed.kind, "refused")
  Assert.equal(committed.reason, "last_usable")
  Assert.equal(mons:partyRevision(), partyRevision)
  Assert.equal(mons:boxRevision(), boxRevision)
  Assert.deepEqual(mons:partyMon(0), before, "refused move leaves party custody intact")
  Assert.isNil(mons:boxMon(0, 0), "refused move leaves destination empty")
end

local function assertPartyMoveAttachmentRefused(attachment, expectedReason)
  local mons, bag = services()
  local factory = CatalogFixture.makeFactory(0x66778899, mons:catalog())
  Assert.isTrue(mons:addMon(factory:createNormal(CatalogFixture.normalRequest({ species = "TOTODILE" }))))
  partyUpdate(mons, 0, function(mon)
    if attachment == "mail" then
      mon.mail = authoredMail()
      mon.heldItem = "ITEM_9"
    else
      mon.capsule = { id = 3, seals = {} }
    end
  end)
  local actions = PcStorageActions.new({ mons = mons, bag = bag })
  local partyRevision, boxRevision = mons:partyRevision(), mons:boxRevision()
  local preview = actions:preview({
    kind = "move",
    source = { kind = "party", slot = 0 },
    destination = { kind = "box", box = 0, slot = 0 },
  })

  Assert.equal(preview.kind, "refused")
  Assert.equal(preview.reason, expectedReason)
  local committed = actions:commit(preview)
  Assert.equal(committed.kind, "refused")
  Assert.equal(committed.reason, expectedReason)
  Assert.equal(mons:partyRevision(), partyRevision)
  Assert.equal(mons:boxRevision(), boxRevision)
  Assert.isNil(mons:boxMon(0, 0))
end

function T.party_move_refuses_attached_mail_without_changing_custody()
  assertPartyMoveAttachmentRefused("mail", "mail_attached")
end

function T.party_move_refuses_attached_capsule_without_changing_custody()
  assertPartyMoveAttachmentRefused("capsule", "capsule_attached")
end

function T.cross_domain_swap_checks_party_custody_independent_of_request_direction()
  local cases = {
    { name = "mail", expected = "mail_attached", attachment = "mail" },
    { name = "capsule", expected = "capsule_attached", attachment = "capsule" },
    { name = "last usable against fainted incoming", expected = "last_usable", incoming = "fainted" },
    { name = "last usable against egg incoming", expected = "last_usable", incoming = "egg" },
    { name = "last usable with usable incoming", expected = "allowed", incoming = "usable" },
  }

  for _, case in ipairs(cases) do
    for _, partyIsSource in ipairs({ true, false }) do
      local mons, bag = services()
      if case.incoming ~= nil then
        partyUpdate(mons, 0, function(mon)
          if case.incoming ~= "usable" then
            mon.condition.currentHp = 0
          end
        end)
      else
        local factory = CatalogFixture.makeFactory(0x66778899, mons:catalog())
        Assert.isTrue(mons:addMon(factory:createNormal(CatalogFixture.normalRequest({ species = "TOTODILE" }))))
        partyUpdate(mons, 0, function(mon)
          if case.attachment == "mail" then
            mon.mail = authoredMail()
            mon.heldItem = "ITEM_9"
          else
            mon.capsule = { id = 3, seals = {} }
          end
        end)
      end

      local factory = CatalogFixture.makeFactory(0x778899aa, mons:catalog())
      local boxMon = factory:createNormal(CatalogFixture.normalRequest({ species = "TOTODILE" }))
      if case.incoming == "fainted" then
        boxMon.condition.currentHp = 0
      elseif case.incoming == "egg" then
        boxMon.isEgg = true
        boxMon.condition.currentHp = 0
      end
      boxUpdate(mons, 0, 8, boxMon)

      local partyAddress = { kind = "party", slot = 0 }
      local boxAddress = { kind = "box", box = 0, slot = 8 }
      local request = {
        kind = "swap",
        source = partyIsSource and partyAddress or boxAddress,
        destination = partyIsSource and boxAddress or partyAddress,
      }
      local preview = PcStorageActions.new({ mons = mons, bag = bag }):preview(request)
      local description = case.name .. (partyIsSource and " (Party source)" or " (Box source)")
      if case.expected == "allowed" then
        Assert.equal(preview.kind, "allowed", description)
      else
        Assert.equal(preview.kind, "refused", description)
        Assert.equal(preview.reason, case.expected, description)
      end
    end
  end
end

function T.cross_domain_swap_normalizes_each_participant_for_its_destination_only()
  local mons, bag = services()
  local factory = CatalogFixture.makeFactory(0x66778899, mons:catalog())
  Assert.isTrue(mons:addMon(factory:createNormal(CatalogFixture.normalRequest({ species = "TOTODILE" }))))
  partyUpdate(mons, 0, function(mon)
    mon.condition.currentHp = 1
    mon.moves[1].pp = 1
    mon.moves[1].ppUps = 2
  end)
  local boxMon = factory:createNormal(CatalogFixture.normalRequest({ species = "TOTODILE" }))
  boxMon.condition.currentHp = 1
  boxMon.condition.status = 1
  boxMon.moves[1].pp = 1
  boxUpdate(mons, 0, 8, boxMon)
  local actions = PcStorageActions.new({ mons = mons, bag = bag })
  local intent = actions:preview({
    kind = "swap",
    source = { kind = "party", slot = 0 },
    destination = { kind = "box", box = 0, slot = 8 },
  })
  Assert.equal(intent.kind, "allowed")
  Assert.equal(actions:commit(intent).kind, "changed")
  local stored = assert(mons:boxMon(0, 8))
  local returned = mons:partyMon(0)
  Assert.equal(stored.condition.currentHp, mons:derive(stored).maxHp)
  Assert.equal(stored.moves[1].pp, 49, "box-bound PP includes the two PP Ups")
  Assert.equal(returned.condition.currentHp, mons:derive(returned).maxHp)
  Assert.equal(returned.condition.status, 0)
  Assert.equal(returned.moves[1].pp, 1, "Party normalization preserves PP")

  local controlMons, controlBag = services()
  local controlFactory = CatalogFixture.makeFactory(0x778899aa, controlMons:catalog())
  local second = controlFactory:createNormal(CatalogFixture.normalRequest({ species = "TOTODILE" }))
  second.condition.currentHp = 1
  second.condition.status = 1
  second.moves[1].pp = 1
  boxUpdate(controlMons, 0, 8, second)
  boxUpdate(controlMons, 0, 9, controlFactory:createNormal(CatalogFixture.normalRequest()))
  local controlActions = PcStorageActions.new({ mons = controlMons, bag = controlBag })
  local sameDomain = controlActions:preview({
    kind = "swap",
    source = { kind = "box", box = 0, slot = 8 },
    destination = { kind = "box", box = 0, slot = 9 },
  })
  Assert.equal(controlActions:commit(sameDomain).kind, "changed")
  Assert.equal(assert(controlMons:boxMon(0, 9)).condition.currentHp, 1, "same-domain swaps keep stored health")
  Assert.equal(assert(controlMons:boxMon(0, 9)).moves[1].pp, 1, "same-domain swaps keep stored PP")
end

local function assertPartyMoveAttachmentRefused(attachment, expectedReason)
  local mons, bag = services()
  local factory = CatalogFixture.makeFactory(0x66778899, mons:catalog())
  Assert.isTrue(mons:addMon(factory:createNormal(CatalogFixture.normalRequest({ species = "TOTODILE" }))))
  partyUpdate(mons, 0, function(mon)
    if attachment == "mail" then
      mon.mail = authoredMail()
      mon.heldItem = "ITEM_9"
    else
      mon.capsule = { id = 3, seals = {} }
    end
  end)
  local actions = PcStorageActions.new({ mons = mons, bag = bag })
  local partyRevision, boxRevision = mons:partyRevision(), mons:boxRevision()
  local preview = actions:preview({
    kind = "move",
    source = { kind = "party", slot = 0 },
    destination = { kind = "box", box = 0, slot = 0 },
  })

  Assert.equal(preview.kind, "refused")
  Assert.equal(preview.reason, expectedReason)
  Assert.equal(mons:partyRevision(), partyRevision)
  Assert.equal(mons:boxRevision(), boxRevision)
  Assert.isNil(mons:boxMon(0, 0))
end

function T.party_move_refuses_attached_mail_without_changing_custody()
  assertPartyMoveAttachmentRefused("mail", "mail_attached")
end

function T.party_move_refuses_attached_capsule_without_changing_custody()
  assertPartyMoveAttachmentRefused("capsule", "capsule_attached")
end

function T.cross_domain_swap_checks_party_custody_independent_of_request_direction()
  local cases = {
    { name = "mail", expected = "mail_attached", attachment = "mail" },
    { name = "capsule", expected = "capsule_attached", attachment = "capsule" },
    { name = "last usable against fainted incoming", expected = "last_usable", incoming = "fainted" },
    { name = "last usable against egg incoming", expected = "last_usable", incoming = "egg" },
    { name = "last usable with usable incoming", expected = "allowed", incoming = "usable" },
  }

  for _, case in ipairs(cases) do
    for _, partyIsSource in ipairs({ true, false }) do
      local mons, bag = services()
      if case.incoming ~= nil then
        partyUpdate(mons, 0, function(mon)
          if case.incoming ~= "usable" then
            mon.condition.currentHp = 0
          end
        end)
      else
        local factory = CatalogFixture.makeFactory(0x66778899, mons:catalog())
        Assert.isTrue(mons:addMon(factory:createNormal(CatalogFixture.normalRequest({ species = "TOTODILE" }))))
        partyUpdate(mons, 0, function(mon)
          if case.attachment == "mail" then
            mon.mail = authoredMail()
            mon.heldItem = "ITEM_9"
          else
            mon.capsule = { id = 3, seals = {} }
          end
        end)
      end

      local factory = CatalogFixture.makeFactory(0x778899aa, mons:catalog())
      local boxMon = factory:createNormal(CatalogFixture.normalRequest({ species = "TOTODILE" }))
      if case.incoming == "fainted" then
        boxMon.condition.currentHp = 0
      elseif case.incoming == "egg" then
        boxMon.isEgg = true
        boxMon.condition.currentHp = 0
      end
      boxUpdate(mons, 0, 8, boxMon)

      local partyAddress = { kind = "party", slot = 0 }
      local boxAddress = { kind = "box", box = 0, slot = 8 }
      local request = {
        kind = "swap",
        source = partyIsSource and partyAddress or boxAddress,
        destination = partyIsSource and boxAddress or partyAddress,
      }
      local preview = PcStorageActions.new({ mons = mons, bag = bag }):preview(request)
      local description = case.name .. (partyIsSource and " (Party source)" or " (Box source)")
      if case.expected == "allowed" then
        Assert.equal(preview.kind, "allowed", description)
      else
        Assert.equal(preview.kind, "refused", description)
        Assert.equal(preview.reason, case.expected, description)
      end
    end
  end
end

function T.cross_domain_swap_normalizes_each_participant_for_its_destination_only()
  local mons, bag = services()
  local factory = CatalogFixture.makeFactory(0x66778899, mons:catalog())
  Assert.isTrue(mons:addMon(factory:createNormal(CatalogFixture.normalRequest({ species = "TOTODILE" }))))
  partyUpdate(mons, 0, function(mon)
    mon.condition.currentHp = 1
    mon.moves[1].pp = 1
    mon.moves[1].ppUps = 2
  end)
  local boxMon = factory:createNormal(CatalogFixture.normalRequest({ species = "TOTODILE" }))
  boxMon.condition.currentHp = 1
  boxMon.condition.status = 1
  boxMon.moves[1].pp = 1
  boxUpdate(mons, 0, 8, boxMon)
  local actions = PcStorageActions.new({ mons = mons, bag = bag })
  local intent = actions:preview({
    kind = "swap",
    source = { kind = "party", slot = 0 },
    destination = { kind = "box", box = 0, slot = 8 },
  })
  Assert.equal(intent.kind, "allowed")
  Assert.equal(actions:commit(intent).kind, "changed")
  local stored = assert(mons:boxMon(0, 8))
  local returned = mons:partyMon(0)
  Assert.equal(stored.condition.currentHp, mons:derive(stored).maxHp)
  Assert.equal(stored.moves[1].pp, 49, "box-bound PP includes the two PP Ups")
  Assert.equal(returned.condition.currentHp, mons:derive(returned).maxHp)
  Assert.equal(returned.condition.status, 0)
  Assert.equal(returned.moves[1].pp, 1, "Party normalization preserves PP")

  local controlMons, controlBag = services()
  local controlFactory = CatalogFixture.makeFactory(0x778899aa, controlMons:catalog())
  local second = controlFactory:createNormal(CatalogFixture.normalRequest({ species = "TOTODILE" }))
  second.condition.currentHp = 1
  second.condition.status = 1
  second.moves[1].pp = 1
  boxUpdate(controlMons, 0, 8, second)
  boxUpdate(controlMons, 0, 9, controlFactory:createNormal(CatalogFixture.normalRequest()))
  local controlActions = PcStorageActions.new({ mons = controlMons, bag = controlBag })
  local sameDomain = controlActions:preview({
    kind = "swap",
    source = { kind = "box", box = 0, slot = 8 },
    destination = { kind = "box", box = 0, slot = 9 },
  })
  Assert.equal(controlActions:commit(sameDomain).kind, "changed")
  Assert.equal(assert(controlMons:boxMon(0, 9)).condition.currentHp, 1, "same-domain swaps keep stored health")
  Assert.equal(assert(controlMons:boxMon(0, 9)).moves[1].pp, 1, "same-domain swaps keep stored PP")
end

function T.swap_items_transfers_held_items_between_party_and_box_without_bag_changes()
  local mons, bag = services()
  local factory = CatalogFixture.makeFactory(0x778899aa, mons:catalog())
  Assert.isTrue(mons:addMon(factory:createNormal(CatalogFixture.normalRequest({ species = "CHIKORITA" }))))
  local partyMon = mons:partyMon(0)
  partyMon.heldItem = "POTION"
  local preparation = assert(mons:preparePartyChanges(mons:partyRevision(), { { slot = 0, mon = partyMon } }))
  preparation.publish()
  local boxMon = factory:createNormal(CatalogFixture.normalRequest({ species = "CHIKORITA" }))
  boxMon.heldItem = "SITRUS_BERRY"
  local storage = assert(mons:preparePcChanges({
    partyRevision = mons:partyRevision(),
    boxRevision = mons:boxRevision(),
  }, { boxUpdates = { { box = 0, slot = 8, mon = boxMon } } }))
  storage.publish()

  local actions = PcStorageActions.new({ mons = mons, bag = bag })
  local beforeBag = bag:revision()
  local intent = actions:preview({
    kind = "swapItems",
    source = { kind = "party", slot = 0 },
    destination = { kind = "box", box = 0, slot = 8 },
  })
  Assert.equal(intent.kind, "allowed")
  Assert.equal(mons:partyMon(0).heldItem, "POTION", "preview retains the source item")
  Assert.equal(assert(mons:boxMon(0, 8)).heldItem, "SITRUS_BERRY", "preview retains the destination item")
  Assert.isTrue(bag:add("POTION", 1))

  Assert.equal(actions:commit(intent).kind, "changed")
  Assert.equal(mons:partyMon(0).heldItem, "SITRUS_BERRY")
  Assert.equal(assert(mons:boxMon(0, 8)).heldItem, "POTION")
  Assert.equal(bag:quantity("POTION"), 1, "held-item swap does not publish a Bag change")
  Assert.isTrue(bag:revision() > beforeBag, "an unrelated Bag change does not stale a mon-only swap")
end

function T.griseous_orb_cannot_be_given_to_a_non_giratina()
  local mons, bag = services()
  Assert.isTrue(bag:add("ITEM_112", 1))
  local actions = PcStorageActions.new({ mons = mons, bag = bag })
  local beforeMon, beforeBag = mons:partyMon(0), bag:quantity("ITEM_112")
  local intent = actions:preview({
    kind = "giveItem",
    source = { kind = "party", slot = 0 },
    item = "ITEM_112",
  })
  Assert.equal(intent.kind, "refused")
  Assert.equal(intent.reason, "griseous_orb")
  Assert.deepEqual(mons:partyMon(0), beforeMon)
  Assert.equal(bag:quantity("ITEM_112"), beforeBag)
end

return { tests = T }
