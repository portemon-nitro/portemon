-- Authored Mail transfers preserve custody across Party, Mailbox and Bag.

local Assert = require("tests.support.Assert")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local ItemFixture = require("libs.items.tests.item_fixture")
local HgssBagService = require("libs.hgss.src.items.HgssBagService")
local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
local Mailbox = require("libs.hgss.src.save.Mailbox")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local MonCatalog = require("libs.mons.src.MonCatalog")
local MonsSave = require("libs.mons.src.MonsSave")
local Party = require("libs.mons.src.Party")
local PcMailActions = require("libs.hgss.src.field.MailActions")
local ItemCatalog = require("libs.items.src.ItemCatalog")

local T = {}

local STATIONERY = {
  "GRASS_MAIL",
  "FLAME_MAIL",
  "BUBBLE_MAIL",
  "BLOOM_MAIL",
  "TUNNEL_MAIL",
  "STEEL_MAIL",
  "HEART_MAIL",
  "SNOW_MAIL",
  "SPACE_MAIL",
  "AIR_MAIL",
  "MOSAIC_MAIL",
  "BRICK_MAIL",
}

local function itemCatalog()
  local root = ItemFixture.buildAssetRoot()
  for type = 0, 11 do
    local nativeId = 137 + type
    root.items["ITEM_" .. nativeId] = nil
    root.items[STATIONERY[type + 1]] = {
      nativeId = nativeId,
      price = 50,
      name = STATIONERY[type + 1],
      nameIndefinite = "a letter",
      namePlural = "letters",
      description = "A written letter.",
      pocket = "mail",
      preventToss = false,
      selectable = true,
      isBall = false,
      friendshipBoost = false,
      icon = STATIONERY[type + 1],
      isHm = false,
      canHold = false,
      heldFormEffect = "none",
      partyUse = { kind = "none" },
    }
  end
  return ItemCatalog.new(root)
end

local function mail(type)
  return {
    schema = "g4-mail-v1",
    type = type,
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

local function manifest()
  local stationery = {}
  for type = 0, 11 do
    stationery[type] = { itemKey = STATIONERY[type + 1] }
  end
  return { mail = { stationery = stationery } }
end

local function services(mailboxSnapshot)
  local items = itemCatalog()
  local catalog = MonCatalog.new(CatalogFixture.buildAssetRoot(), items)
  local rng = Lcrng.new(0x11223344)
  local bucket = MonsSave.capture(Party.new():capture(), rng:capture(), catalog:fingerprint())
  local mons = HgssMonService.new({
    catalog = catalog,
    bucket = bucket,
    profile = CatalogFixture.profile(),
    game = "heartgold",
    language = "english",
    charmap = CatalogFixture.CHARMAP,
    games = CatalogFixture.GAMES,
    languages = CatalogFixture.LANGUAGES,
    items = CatalogFixture.ITEMS,
    balls = CatalogFixture.BALLS,
  })
  local factory = CatalogFixture.makeFactory(0x55667788, catalog)
  for _, species in ipairs({ "CHIKORITA", "TOTODILE" }) do
    local mon = factory:createNormal(CatalogFixture.normalRequest({ species = species }))
    Assert.isTrue(mons:addMon(mon), "setup adds a real party member")
  end
  local held = mons:partyMon(0)
  held.heldItem = "GRASS_MAIL"
  held.mail = mail(0)
  local prepared = assert(mons:preparePartyChanges(mons:partyRevision(), { { slot = 0, mon = held } }))
  prepared.publish()
  local mailbox = Mailbox.new(mailboxSnapshot)
  local bag = HgssBagService.new({ catalog = items })
  return mons, mailbox, bag, PcMailActions.new({ mons = mons, mailbox = mailbox, bag = bag, manifest = manifest() })
end

local function fullMailbox(letter)
  local slots = {}
  for slot = 1, Mailbox.CAPACITY do
    slots[slot] = letter
  end
  return { schema = Mailbox.SCHEMA, slots = slots }
end

function T.full_mailbox_refuses_party_send_without_changing_party_or_mailbox()
  local letter = mail(0)
  local mons, mailbox, _, actions = services(fullMailbox(letter))
  local before = mons:partyMon(0)
  local mailboxBefore = mailbox:capture()
  local intent = actions:preview({
    kind = "sendPartyToMailbox",
    slot = 0,
    partyRevision = mons:partyRevision(),
    mailboxRevision = mailbox:revision(),
  })

  Assert.equal(intent.kind, "refused", "a full mailbox refuses the send")
  Assert.equal(actions:commit(intent).kind, "refused")
  Assert.deepEqual(mons:partyMon(0), before, "the exact party letter remains held")
  Assert.deepEqual(mailbox:capture(), mailboxBefore, "a full mailbox remains byte-for-byte equivalent")
end

function T.full_bag_distinguishes_stored_mail_discard_from_party_removal_refusal()
  local slots = {}
  for slot = 1, Mailbox.CAPACITY do
    slots[slot] = slot == 1 and mail(0) or false
  end
  local mons, mailbox, bag, actions = services({ schema = Mailbox.SCHEMA, slots = slots })
  for _, itemKey in ipairs(STATIONERY) do
    local quantity = itemKey == "GRASS_MAIL" and 999 or 1
    Assert.isTrue(bag:add(itemKey, quantity), "the Mail pocket carries its full stack capacity")
  end

  local erase = actions:preview({
    kind = "eraseMailboxMessage",
    slot = 0,
    mailboxRevision = mailbox:revision(),
    bagRevision = bag:revision(),
  })
  Assert.equal(erase.kind, "confirm", "stored Mail erasure asks before changing custody")
  Assert.deepEqual(mailbox:get(0), mail(0), "preview leaves the stored letter in place")
  local discarded = actions:commit(erase, true)
  Assert.equal(discarded.kind, "changed", "confirmed stored Mail erasure follows the source discard branch")
  Assert.equal(discarded.outcome, "discarded", "the full-Bag outcome remains explicit")
  Assert.isNil(mailbox:get(0), "the confirmed letter is erased")
  Assert.equal(bag:quantity("FLAME_MAIL"), 1, "the unrelated full-Bag item is retained")
  Assert.equal(bag:quantity("GRASS_MAIL"), 999, "the full stationery stack is retained")

  local partyErase = actions:preview({
    kind = "erasePartyMessage",
    slot = 0,
    partyRevision = mons:partyRevision(),
    bagRevision = bag:revision(),
  })
  Assert.equal(partyErase.kind, "confirm", "party message loss uses a separate confirmation")
  local partyBefore = mons:partyMon(0)
  local refused = actions:commit(partyErase, true)
  Assert.equal(refused.kind, "refused", "party removal refuses when its stationery cannot return to Bag")
  Assert.equal(refused.outcome, "bag_full", "party removal does not inherit stored-Mail discard semantics")
  Assert.deepEqual(mons:partyMon(0), partyBefore, "the party letter survives failed stationery return")
  Assert.equal(bag:quantity("FLAME_MAIL"), 1, "the full Bag remains unchanged")
  Assert.equal(bag:quantity("GRASS_MAIL"), 999, "the full stationery stack remains unchanged")
end

function T.giving_mail_consumes_stationery_and_preserves_the_letter_for_the_selected_mon()
  local stored = mail(3)
  local slots = { stored }
  for slot = 2, Mailbox.CAPACITY do
    slots[slot] = false
  end
  local mons, mailbox, bag, actions = services({ schema = Mailbox.SCHEMA, slots = slots })
  local bagRevision = bag:revision()
  local recipient = mons:partyMon(1)
  Assert.equal(recipient.heldItem, "NONE")
  local intent = actions:preview({
    kind = "giveMailboxMail",
    slot = 0,
    targetSlot = 1,
    mailboxRevision = mailbox:revision(),
    partyRevision = mons:partyRevision(),
    bagRevision = bagRevision,
  })
  Assert.equal(intent.kind, "ready")
  local outcome = actions:commit(intent)
  Assert.equal(outcome.kind, "changed")
  Assert.deepEqual(mailbox:get(0), nil, "the persistent slot clears after the transfer")
  Assert.deepEqual(mons:partyMon(1).mail, stored, "the exact authored letter reaches its selected recipient")
  Assert.equal(mons:partyMon(1).heldItem, "BLOOM_MAIL")
  Assert.equal(bag:revision(), bagRevision, "the stored letter carries its stationery outside Bag")
end

function T.confirmation_and_give_intents_cannot_publish_after_decline_or_recipient_change()
  local stored = mail(0)
  local slots = { stored }
  for slot = 2, Mailbox.CAPACITY do
    slots[slot] = false
  end
  local mons, mailbox, bag, actions = services({ schema = Mailbox.SCHEMA, slots = slots })
  local mailboxBefore, bagBefore = mailbox:capture(), bag:capture()
  local erase = actions:preview({
    kind = "eraseMailboxMessage",
    slot = 0,
    mailboxRevision = mailbox:revision(),
    bagRevision = bag:revision(),
  })
  Assert.equal(erase.kind, "confirm")
  Assert.equal(actions:commit(erase, false).reason, "declined")
  Assert.equal(actions:commit(erase, true).reason, "stale_intent", "a declined confirmation cannot be replayed")
  Assert.deepEqual(mailbox:capture(), mailboxBefore, "declining source confirmation preserves Mailbox custody")
  Assert.deepEqual(bag:capture(), bagBefore, "declining source confirmation preserves stationery inventory")

  local give = actions:preview({
    kind = "giveMailboxMail",
    slot = 0,
    targetSlot = 1,
    mailboxRevision = mailbox:revision(),
    partyRevision = mons:partyRevision(),
    bagRevision = bag:revision(),
  })
  Assert.equal(give.kind, "ready")
  local recipient = mons:partyMon(1)
  recipient.heldItem = "POTION"
  local partyChange = assert(mons:preparePartyChanges(mons:partyRevision(), { { slot = 1, mon = recipient } }))
  partyChange.publish()
  local stale = actions:commit(give)
  Assert.equal(stale.kind, "refused", "a changed recipient invalidates the staged attachment")
  Assert.deepEqual(mailbox:capture(), mailboxBefore, "a stale recipient cannot clear the source slot")
  Assert.equal(mons:partyMon(1).heldItem, "POTION", "a stale recipient retains the intervening held item")
  Assert.deepEqual(mons:partyMon(1).mail, {}, "a stale recipient never receives the authored letter")
end

function T.confirmation_intent_cannot_be_mutated_before_commit()
  local slots = { mail(0) }
  for slot = 2, Mailbox.CAPACITY do
    slots[slot] = false
  end
  local _, mailbox, bag, actions = services({ schema = Mailbox.SCHEMA, slots = slots })
  local mailboxBefore, bagBefore = mailbox:capture(), bag:capture()
  local intent = actions:preview({
    kind = "eraseMailboxMessage",
    slot = 0,
    mailboxRevision = mailbox:revision(),
    bagRevision = bag:revision(),
  })
  intent.letter.author.name = "SPOOFED"
  Assert.equal(actions:commit(intent, true).reason, "stale_intent")
  Assert.deepEqual(mailbox:capture(), mailboxBefore, "mutating a caller-held intent cannot erase Mail")
  Assert.deepEqual(bag:capture(), bagBefore, "mutating a caller-held intent cannot mint stationery")
end

return { tests = T }
